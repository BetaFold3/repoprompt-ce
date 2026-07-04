import CryptoKit
import Foundation
import RepoPromptRemoteWire

struct RemoteHostConnectionHTTPResponse: Equatable {
    var statusCode: Int
    var data: Data
}

protocol RemoteHostConnectionHTTPTransport: Sendable {
    func postJSON(
        to url: URL,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> RemoteHostConnectionHTTPResponse
}

struct URLSessionRemoteHostConnectionHTTPTransport: RemoteHostConnectionHTTPTransport, @unchecked Sendable {
    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postJSON(
        to url: URL,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> RemoteHostConnectionHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteClientError.transport("Ticket endpoint returned a non-HTTP response.")
        }
        return RemoteHostConnectionHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

struct RemoteHostConnectionTestResult: Equatable {
    var hostID: String
    var hostName: String?
    var scopes: Set<String>
    var pongPayload: JSONValue
}

actor RemoteHostConnection {
    enum State: Equatable {
        case idle
        case mintingTicket
        case connecting
        case connected(scopes: Set<String>)
        case degraded(code: String, retryAt: Date)
        case revoked
    }

    static let ticketTimeout: TimeInterval = 20
    static let connectTimeout: TimeInterval = 10
    static let commandTimeout: TimeInterval = 30
    static let initialReconnectBackoff: TimeInterval = 0.5
    static let maximumReconnectBackoff: TimeInterval = 30

    nonisolated let inboundFrames: AsyncStream<RemoteServerFrame>
    nonisolated let stateEvents: AsyncStream<State>

    let hostID: String

    private let registry: RemoteHostRegistry
    private let keyStore: RemoteClientKeyStore
    private let httpTransport: any RemoteHostConnectionHTTPTransport
    private let webSocketSession: URLSession
    private let now: @Sendable () -> Date

    private let inboundContinuation: AsyncStream<RemoteServerFrame>.Continuation
    private let stateContinuation: AsyncStream<State>.Continuation

    private var state: State = .idle
    private var webSocketTask: URLSessionWebSocketTask?
    private var signer: RemoteFrameSigner?
    private var readTask: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingCommands: [String: PendingCommand] = [:]
    private var desiredSubscriptions: Set<String> = []
    private var connectedHostName: String?
    private var connectedScopes: Set<String> = []
    private var reconnectBackoff = RemoteHostConnection.initialReconnectBackoff

    init(
        hostID: String,
        registry: RemoteHostRegistry = .shared,
        keyStore: RemoteClientKeyStore = .shared,
        httpTransport: any RemoteHostConnectionHTTPTransport = URLSessionRemoteHostConnectionHTTPTransport(),
        webSocketSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hostID = hostID
        self.registry = registry
        self.keyStore = keyStore
        self.httpTransport = httpTransport
        self.webSocketSession = webSocketSession
        self.now = now

        let inbound = AsyncStream.makeStream(of: RemoteServerFrame.self)
        inboundFrames = inbound.stream
        inboundContinuation = inbound.continuation

        let states = AsyncStream.makeStream(of: State.self)
        stateEvents = states.stream
        stateContinuation = states.continuation
        stateContinuation.yield(.idle)
    }

    deinit {
        inboundContinuation.finish()
        stateContinuation.finish()
        readTask?.cancel()
        reconnectTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }

    func currentState() -> State {
        state
    }

    func ensureConnected() async throws {
        if case .connected = state, webSocketTask != nil {
            return
        }
        if case .revoked = state {
            throw RemoteClientError.hostRevoked(hostID)
        }
        if let connectTask {
            try await connectTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw RemoteClientError.connectionClosed }
            try await openConnectionWithImmediateRetries()
        }
        connectTask = task
        do {
            try await task.value
            connectTask = nil
        } catch {
            connectTask = nil
            throw error
        }
    }

    func command(_ frame: RemoteClientFrame, timeout: TimeInterval = RemoteHostConnection.commandTimeout) async throws -> JSONValue {
        try await ensureConnected()
        return try await sendConnectedCommand(frame, timeout: timeout)
    }

    func supportsAgentCatalog() async throws -> Bool {
        // The catalog capability is learned from hello_ack.host_name, so this is
        // intentionally connect-on-demand. Empty/whitespace names degrade with
        // older hosts instead of attempting an uncorrelatable list_agents probe.
        try await ensureConnected()
        return connectedHostName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func subscribe(sessionIDs: [String]) async throws {
        let normalized = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return }
        desiredSubscriptions.formUnion(normalized)
        try await ensureConnected()
        _ = try await sendSubscribeCommand(sessionIDs: desiredSubscriptions.sorted())
    }

    func testConnection(timeout: TimeInterval = RemoteHostConnection.connectTimeout) async throws -> RemoteHostConnectionTestResult {
        do {
            try await ensureConnected()
            let pongPayload: JSONValue = .object([
                "probe": .string("settings_test_connection"),
                "host_id": .string(hostID)
            ])
            let response = try await command(
                RemoteClientFrame(
                    type: "ping",
                    requestID: Self.makeRequestID(prefix: "ping"),
                    payload: pongPayload
                ),
                timeout: timeout
            )
            let result = RemoteHostConnectionTestResult(
                hostID: hostID,
                hostName: connectedHostName,
                scopes: connectedScopes,
                pongPayload: response
            )
            await disconnect()
            return result
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        readTask?.cancel()
        readTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        signer = nil
        connectedScopes = []
        connectedHostName = nil
        failAllPending(with: RemoteClientError.connectionClosed)
        transition(to: .idle)
    }

    #if DEBUG
        func handleServerFrameForTesting(_ frame: RemoteServerFrame) async {
            await handleIncomingFrame(frame)
        }
    #endif

    // MARK: - Connect

    private func openConnectionWithImmediateRetries() async throws {
        var retriedTicket = false
        var retriedCounter = false

        while true {
            do {
                try await openConnectionOnce()
                return
            } catch let error as RemoteClientError {
                if case .revoked = error {
                    markRevoked()
                    throw error
                }
                if let commandError = error.commandError {
                    switch commandError.code {
                    case "ticket_expired", "ticket_already_used" where !retriedTicket:
                        retriedTicket = true
                        continue
                    case "counter_replayed" where !retriedCounter:
                        retriedCounter = true
                        persistCounter(UInt64(max(0, currentEpochMilliseconds(date: now()))) + 1)
                        continue
                    case "device_revoked", "unknown_device":
                        markRevoked()
                        throw RemoteClientError.revoked(commandError)
                    default:
                        break
                    }
                }
                throw error
            }
        }
    }

    private func openConnectionOnce() async throws {
        let record = try currentHostRecord()
        guard record.revokedByHostAt == nil else {
            transition(to: .revoked)
            throw RemoteClientError.hostRevoked(hostID)
        }

        transition(to: .mintingTicket)
        let ticket = try await mintTicket(for: record)

        guard ticket.deviceID == record.deviceID else {
            throw RemoteClientError.security("Ticket device ID did not match the paired host record.")
        }
        guard ticket.hostFingerprint == record.id else {
            throw RemoteClientError.security("Ticket host fingerprint did not match the pinned host fingerprint.")
        }
        guard ticket.scopes.isSubset(of: record.grantedScopes) else {
            throw RemoteClientError.security("Ticket scopes exceeded the granted paired-host scopes.")
        }

        let signingMaterial: P256.Signing.PrivateKey
        do {
            signingMaterial = try keyStore.privateKey(forHostID: record.id)
        } catch RemoteClientKeyStoreError.missingKey {
            throw RemoteClientError.missingDeviceKey(record.id)
        } catch {
            throw error
        }

        var localSigner = RemoteFrameSigner(
            deviceSigner: signingMaterial,
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            lastCounter: record.lastCounter
        )
        let webSocketURL = try Self.webSocketURL(for: record.gatewayURL)
        let task = webSocketSession.webSocketTask(with: webSocketURL)
        transition(to: .connecting)
        task.resume()

        do {
            let hello = RemoteClientFrame(
                type: "hello",
                payload: .object(["ticket": ticket.jsonValue])
            )
            let signedHello = try localSigner.sign(hello, nowMs: currentEpochMilliseconds(date: now()))
            persistCounter(signedHello.signature.counter)
            try await send(signedHello.data, over: task)

            let response = try await receiveServerFrame(over: task, timeout: Self.connectTimeout)
            switch response.type {
            case "hello_ack":
                try handleHelloAck(response, expectedRecord: record, task: task, signer: localSigner)
            case "command_error":
                throw try Self.clientError(fromCommandErrorFrame: response)
            case "channel_closing":
                throw clientError(fromChannelClosingFrame: response)
            default:
                throw RemoteClientError.protocolViolation("Expected hello_ack, got \(response.type).")
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            signer = nil
            if case .revoked = state {
                throw error
            }
            if let remoteError = error as? RemoteClientError {
                throw remoteError
            }
            throw RemoteClientError.transport(String(describing: error))
        }

        if !desiredSubscriptions.isEmpty {
            do {
                _ = try await sendSubscribeCommand(sessionIDs: desiredSubscriptions.sorted())
            } catch {
                await disconnect()
                throw error
            }
        }
    }

    private func handleHelloAck(
        _ frame: RemoteServerFrame,
        expectedRecord record: PairedHostRecord,
        task: URLSessionWebSocketTask,
        signer localSigner: RemoteFrameSigner
    ) throws {
        let payload = frame.payload?.objectValue ?? [:]
        if let deviceID = payload["device_id"]?.stringValue, deviceID != record.deviceID {
            throw RemoteClientError.security("hello_ack device ID did not match the paired host record.")
        }
        let scopes = Set(payload["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? Array(record.grantedScopes))
        webSocketTask = task
        signer = localSigner
        connectedScopes = scopes
        connectedHostName = payload["host_name"]?.stringValue
        reconnectBackoff = Self.initialReconnectBackoff
        _ = try? registry.updateLastConnected(hostID: record.id, at: now())
        transition(to: .connected(scopes: scopes))
        startReadLoop(for: task)
    }

    private func mintTicket(for record: PairedHostRecord) async throws -> RemoteTicket {
        let response: RemoteHostConnectionHTTPResponse
        do {
            response = try await httpTransport.postJSON(
                to: Self.endpoint(base: record.gatewayURL, pathComponents: ["api", "ticket"]),
                body: [
                    "device_id": .string(record.deviceID),
                    "scopes": .array(record.grantedScopes.sorted().map(JSONValue.string)),
                    "ttl_seconds": .int(Int(RemoteTicket.maximumTTLMilliseconds / 1000))
                ],
                timeout: Self.ticketTimeout
            )
        } catch let error as RemoteClientError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw RemoteClientError.timeout(operation: "ticket mint", seconds: Self.ticketTimeout)
        } catch {
            throw RemoteClientError.transport(error.localizedDescription)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw ticketHTTPError(response)
        }

        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: response.data)
        } catch {
            throw RemoteClientError.invalidTicket("Ticket endpoint returned malformed JSON.")
        }
        guard let ticketValue = root.objectValue?["ticket"] else {
            throw RemoteClientError.invalidTicket("Ticket endpoint did not include a ticket object.")
        }
        do {
            let ticket = try RemoteTicket.parse(from: ticketValue)
            try ticket.verify(hostPublicKeyRaw: record.hostPublicKey, nowMs: currentEpochMilliseconds(date: now()))
            return ticket
        } catch let error as RemoteTicketError {
            throw RemoteClientError.invalidTicket(error.description)
        }
    }

    private func ticketHTTPError(_ response: RemoteHostConnectionHTTPResponse) -> RemoteClientError {
        let object = try? JSONDecoder().decode(JSONValue.self, from: response.data).objectValue
        let code = object?["code"]?.stringValue
        let message = object?["error"]?.stringValue
            ?? object?["message"]?.stringValue
            ?? object?["text"]?.stringValue
            ?? "Ticket endpoint returned HTTP \(response.statusCode)."
        if response.statusCode == 429 || code == "rate_limited" {
            return .rateLimited(message: message)
        }
        if message.localizedCaseInsensitiveContains("revoked") {
            let error = RemoteCommandError(code: "device_revoked", message: message, details: nil)
            markRevoked()
            return .revoked(error)
        }
        if message.localizedCaseInsensitiveContains("no paired device") {
            let error = RemoteCommandError(code: "unknown_device", message: message, details: nil)
            markRevoked()
            return .revoked(error)
        }
        return .transport(message)
    }

    private func currentHostRecord() throws -> PairedHostRecord {
        guard registry.hasHosts else {
            throw RemoteClientError.hostNotFound(hostID)
        }
        guard let record = try registry.host(id: hostID) else {
            throw RemoteClientError.hostNotFound(hostID)
        }
        return record
    }

    // MARK: - Commands

    private func sendSubscribeCommand(sessionIDs: [String]) async throws -> JSONValue {
        try await sendConnectedCommand(
            RemoteClientFrame(
                type: "subscribe",
                requestID: Self.makeRequestID(prefix: "sub"),
                payload: .object([
                    "session_ids": .array(sessionIDs.map(JSONValue.string))
                ])
            ),
            timeout: Self.commandTimeout
        )
    }

    private func sendConnectedCommand(_ frame: RemoteClientFrame, timeout: TimeInterval) async throws -> JSONValue {
        guard let task = webSocketTask, var localSigner = signer else {
            throw RemoteClientError.connectionClosed
        }
        let requestID = frame.requestID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? frame.requestID!
            : Self.makeRequestID(prefix: frame.type)
        let frameWithRequestID = RemoteClientFrame(
            v: frame.v,
            type: frame.type,
            requestID: requestID,
            sessionID: frame.sessionID,
            payload: frame.payload,
            clientTime: frame.clientTime,
            sig: frame.sig
        )
        let signed: RemoteSignedFrame
        do {
            signed = try localSigner.sign(frameWithRequestID, nowMs: currentEpochMilliseconds(date: now()))
        } catch {
            throw RemoteClientError.transport(String(describing: error))
        }
        signer = localSigner
        persistCounter(signed.signature.counter)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Self.sleep(seconds: timeout)
                        await self?.timeoutPendingCommand(
                            requestID: requestID,
                            operation: frame.type,
                            timeout: timeout
                        )
                    } catch {
                        // Cancellation is expected once the command resolves.
                    }
                }
                pendingCommands[requestID] = PendingCommand(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    do {
                        try await task.send(.string(String(decoding: signed.data, as: UTF8.self)))
                    } catch {
                        await self?.failPendingCommand(
                            requestID: requestID,
                            with: RemoteClientError.transport(error.localizedDescription)
                        )
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPendingCommand(requestID: requestID, with: RemoteClientError.connectionClosed)
            }
        }
    }

    private func completePendingCommand(requestID: String, payload: JSONValue) {
        guard let pending = pendingCommands.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: payload)
    }

    private func failPendingCommand(requestID: String, with error: Error) {
        guard let pending = pendingCommands.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func timeoutPendingCommand(requestID: String, operation: String, timeout: TimeInterval) {
        failPendingCommand(
            requestID: requestID,
            with: RemoteClientError.timeout(operation: operation, seconds: timeout)
        )
    }

    private func failAllPending(with error: Error) {
        let pending = pendingCommands
        pendingCommands.removeAll()
        for command in pending.values {
            command.timeoutTask.cancel()
            command.continuation.resume(throwing: error)
        }
    }

    // MARK: - Read loop

    private func startReadLoop(for task: URLSessionWebSocketTask) {
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            await readLoop(task: task)
        }
    }

    private func readLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let frame = try await receiveServerFrame(over: task, timeout: nil)
                await handleIncomingFrame(frame)
            } catch {
                await handleReadLoopTermination(error)
                return
            }
        }
    }

    private func handleIncomingFrame(_ frame: RemoteServerFrame) async {
        guard RemoteWireProtocol.serverFrameTypes.contains(frame.type) else {
            // Additive-evolution rule: unknown server frames are ignored.
            return
        }

        switch frame.type {
        case "command_result":
            if let requestID = frame.requestID {
                completePendingCommand(requestID: requestID, payload: frame.payload ?? .null)
            }
        case "pong":
            if let requestID = frame.requestID {
                completePendingCommand(requestID: requestID, payload: frame.payload ?? .object([:]))
            }
        case "command_error":
            do {
                let error = try Self.clientError(fromCommandErrorFrame: frame)
                if let requestID = frame.requestID, pendingCommands[requestID] != nil {
                    failPendingCommand(requestID: requestID, with: error)
                } else {
                    handleUncorrelatedCommandError(error)
                }
            } catch {
                if let requestID = frame.requestID, pendingCommands[requestID] != nil {
                    failPendingCommand(requestID: requestID, with: error)
                }
            }
        case "channel_closing":
            let error = clientError(fromChannelClosingFrame: frame)
            if case .revoked = error {
                markRevoked()
            } else {
                let code = error.commandError?.code ?? "channel_closing"
                transition(to: .degraded(code: code, retryAt: now().addingTimeInterval(reconnectBackoff)))
                scheduleReconnectIfNeeded(reason: code)
            }
            failAllPending(with: error)
        default:
            inboundContinuation.yield(frame)
        }
    }

    private func handleUncorrelatedCommandError(_ error: RemoteClientError) {
        guard let commandError = error.commandError else { return }
        switch commandError.code {
        case "device_revoked", "unknown_device":
            markRevoked()
            failAllPending(with: error)
        case "counter_replayed":
            persistCounter(UInt64(max(0, currentEpochMilliseconds(date: now()))) + 1)
            transition(to: .degraded(code: commandError.code, retryAt: now().addingTimeInterval(reconnectBackoff)))
            failAllPending(with: error)
            scheduleReconnectIfNeeded(reason: commandError.code)
        case "unsupported_frame_type":
            // Unknown/unmatched server-side command errors can arrive for probes from
            // older hosts. They are intentionally uncorrelated and safe to ignore here.
            return
        default:
            return
        }
    }

    private func handleReadLoopTermination(_ error: Error) async {
        if Task.isCancelled { return }
        if case .revoked = state { return }
        webSocketTask = nil
        signer = nil
        connectedScopes = []
        connectedHostName = nil
        failAllPending(with: RemoteClientError.connectionClosed)
        guard !desiredSubscriptions.isEmpty else {
            transition(to: .idle)
            return
        }
        let code: String = if let remoteError = error as? RemoteClientError, let commandError = remoteError.commandError {
            commandError.code
        } else {
            "transport_closed"
        }
        scheduleReconnectIfNeeded(reason: code)
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard reconnectTask == nil, !desiredSubscriptions.isEmpty else { return }
        let delay = reconnectBackoff
        reconnectBackoff = min(reconnectBackoff * 2, Self.maximumReconnectBackoff)
        transition(to: .degraded(code: reason, retryAt: now().addingTimeInterval(delay)))
        reconnectTask = Task { [weak self] in
            do {
                try await Self.sleep(seconds: delay)
            } catch {
                return
            }
            await self?.retryAfterBackoff()
        }
    }

    private func retryAfterBackoff() async {
        reconnectTask = nil
        guard !desiredSubscriptions.isEmpty else {
            transition(to: .idle)
            return
        }
        do {
            try await ensureConnected()
        } catch {
            if case .revoked = state { return }
            let reason = (error as? RemoteClientError)?.commandError?.code ?? "reconnect_failed"
            scheduleReconnectIfNeeded(reason: reason)
        }
    }

    // MARK: - Revocation / counters / state

    private func markRevoked() {
        _ = try? registry.markRevokedByHost(hostID: hostID, at: now())
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        signer = nil
        connectedScopes = []
        connectedHostName = nil
        failAllPending(with: RemoteClientError.hostRevoked(hostID))
        transition(to: .revoked)
    }

    private func persistCounter(_ counter: UInt64) {
        _ = try? registry.updateLastCounter(hostID: hostID, counter: counter)
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        stateContinuation.yield(newState)
    }

    // MARK: - Wire helpers

    private func send(_ data: Data, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveServerFrame(
        over task: URLSessionWebSocketTask,
        timeout: TimeInterval?
    ) async throws -> RemoteServerFrame {
        let message: URLSessionWebSocketTask.Message = if let timeout {
            try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await task.receive()
                }
                group.addTask {
                    try await Self.sleep(seconds: timeout)
                    throw RemoteClientError.timeout(operation: "receive", seconds: timeout)
                }
                guard let first = try await group.next() else {
                    throw RemoteClientError.connectionClosed
                }
                group.cancelAll()
                return first
            }
        } else {
            try await task.receive()
        }
        let data: Data = switch message {
        case let .string(text):
            Data(text.utf8)
        case let .data(payload):
            payload
        @unknown default:
            Data()
        }
        do {
            return try RemoteWireProtocol.decodeServerFrame(from: data)
        } catch {
            throw RemoteClientError.protocolViolation(String(describing: error))
        }
    }

    private static func clientError(fromCommandErrorFrame frame: RemoteServerFrame) throws -> RemoteClientError {
        guard let object = frame.payload?.objectValue,
              let code = object["code"]?.stringValue
        else {
            throw RemoteClientError.protocolViolation("command_error missing code.")
        }
        let message = object["message"]?.stringValue ?? code
        return RemoteClientError.fromCommandError(
            code: code,
            message: message,
            details: object["details"]
        )
    }

    private func clientError(fromChannelClosingFrame frame: RemoteServerFrame) -> RemoteClientError {
        let object = frame.payload?.objectValue ?? [:]
        let reason = object["reason"]?.stringValue ?? "channel_closing"
        let message = object["message"]?.stringValue ?? reason
        return RemoteClientError.fromCommandError(code: reason, message: message, details: frame.payload)
    }

    private static func endpoint(base: URL, pathComponents: [String]) -> URL {
        pathComponents.reduce(base) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func webSocketURL(for gatewayURL: URL) throws -> URL {
        guard var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else {
            throw RemoteClientError.protocolViolation("Gateway URL is invalid.")
        }
        switch scheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            throw RemoteClientError.protocolViolation("Gateway URL must use http or https.")
        }
        let trimmedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = trimmedPath.isEmpty ? "/ws" : "/\(trimmedPath)/ws"
        components.percentEncodedQuery = nil
        guard let url = components.url else {
            throw RemoteClientError.protocolViolation("Could not build gateway WebSocket URL.")
        }
        return url
    }

    private static func makeRequestID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct PendingCommand {
    let continuation: CheckedContinuation<JSONValue, Error>
    let timeoutTask: Task<Void, Never>
}
