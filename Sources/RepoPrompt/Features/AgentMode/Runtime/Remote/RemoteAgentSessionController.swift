import Foundation
import RepoPromptRemoteWire

protocol RemoteAgentSessionConnection: Sendable {
    func command(_ frame: RemoteClientFrame, timeout: TimeInterval) async throws -> JSONValue
    func ensureConnected() async throws
    func subscribe(sessionIDs: [String]) async throws
}

extension RemoteAgentSessionConnection {
    func command(_ frame: RemoteClientFrame) async throws -> JSONValue {
        try await command(frame, timeout: RemoteHostConnection.commandTimeout)
    }
}

extension RemoteHostConnection: RemoteAgentSessionConnection {}

struct RemoteChannelState: Equatable {
    enum Kind: Equatable {
        case connected
        case degraded(reason: String)
        case revoked
    }

    var kind: Kind
}

enum RemoteSessionEvent: Equatable {
    case transcriptRows([AgentChatItem])
    case runState(AgentSessionRunState, pendingInteraction: RemotePendingInteraction?)
    case interactionResolved(interactionID: String, resolvedBy: String?)
    case sessionExpired
    case terminal(status: String)
    case channel(RemoteChannelState)
    case systemMessage(String)
    case metadata(agentKindRaw: String?, modelRaw: String?, sessionName: String?)
    case binding(AgentSessionRemoteHostBinding)
}

actor RemoteAgentSessionController {
    nonisolated let events: AsyncStream<RemoteSessionEvent>

    private let hostID: String
    private let hostDisplayName: String
    private let connection: any RemoteAgentSessionConnection
    private let eventsContinuation: AsyncStream<RemoteSessionEvent>.Continuation
    private var remoteSessionID: String?
    private var lastAppliedSeq: UInt64
    private var nextLogOffset: Int
    private var projector: RemoteTranscriptProjector?
    private var scheduledLogCatchUpTask: Task<Void, Never>?
    private var scheduledLogCatchUpDirty = false
    private var isShutdown = false

    init(
        binding: AgentSessionRemoteHostBinding,
        connection: any RemoteAgentSessionConnection
    ) {
        hostID = binding.hostID
        hostDisplayName = binding.hostDisplayName
        remoteSessionID = binding.remoteSessionID.isEmpty ? nil : binding.remoteSessionID
        lastAppliedSeq = binding.lastAppliedSeq
        nextLogOffset = binding.nextLogOffset
        self.connection = connection
        if !binding.remoteSessionID.isEmpty {
            projector = RemoteTranscriptProjector(remoteSessionID: binding.remoteSessionID)
        }
        var continuation: AsyncStream<RemoteSessionEvent>.Continuation!
        events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        scheduledLogCatchUpTask?.cancel()
        eventsContinuation.finish()
    }

    func start(
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        windowID: Int?,
        workspaceID: String?
    ) async throws -> String {
        try ensureNotShutdown()
        var payload: [String: JSONValue] = [
            "message": .string(message),
            "detach": .bool(true)
        ]
        if let modelSelectionRaw, !modelSelectionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["model_id"] = .string(modelSelectionRaw)
        }
        if let sessionName, !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["session_name"] = .string(sessionName)
        }
        if let windowID { payload["window_id"] = .int(windowID) }
        if let workspaceID, !workspaceID.isEmpty { payload["workspace_id"] = .string(workspaceID) }
        let frame = RemoteClientFrame(
            type: "start",
            requestID: makeRequestID(prefix: "start"),
            payload: .object(payload)
        )
        let response = try await commandWithTransportRetry(frame, operation: "start", mayRetryTransportLoss: true)
        let sessionID = try Self.remoteSessionID(from: response)
        if sessionID != remoteSessionID {
            lastAppliedSeq = 0
            nextLogOffset = 0
            scheduledLogCatchUpDirty = false
        }
        remoteSessionID = sessionID
        projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        emitBinding()
        try await connection.subscribe(sessionIDs: [sessionID])
        applySnapshot(response, frameType: "session_update")
        try await catchUpFromHost()
        return sessionID
    }

    func steer(_ text: String) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        let frame = RemoteClientFrame(
            type: "steer",
            requestID: makeRequestID(prefix: "steer"),
            sessionID: sessionID,
            payload: .object(["message": .string(text)])
        )
        let response = try await commandWithTransportRetry(frame, operation: "steer", mayRetryTransportLoss: true)
        applySnapshot(response, frameType: "session_update")
        try await catchUpFromHost()
    }

    func respond(interactionID: String, payload: RemoteInteractionResponsePayload) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        let frame = RemoteClientFrame(
            type: "respond",
            requestID: makeRequestID(prefix: "respond"),
            sessionID: sessionID,
            payload: payload.wirePayload(interactionID: interactionID)
        )
        do {
            let response = try await commandWithTransportRetry(frame, operation: "respond", mayRetryTransportLoss: true)
            applySnapshot(response, frameType: "session_update")
            try await catchUpFromHost()
        } catch RemoteClientError.interactionAlreadyResolved {
            eventsContinuation.yield(.interactionResolved(interactionID: interactionID, resolvedBy: nil))
            try await catchUpFromHost()
        }
    }

    func cancel() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        let frame = RemoteClientFrame(
            type: "cancel",
            requestID: makeRequestID(prefix: "cancel"),
            sessionID: sessionID,
            payload: .object([:])
        )
        let response = try await commandWithTransportRetry(frame, operation: "cancel", mayRetryTransportLoss: true)
        applySnapshot(response, frameType: "session_terminal")
        try await catchUpFromHost()
    }

    func attachAndCatchUp() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        if projector == nil {
            projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        }
        try await connection.subscribe(sessionIDs: [sessionID])
        try await catchUpFromHost()
    }

    func currentBinding() -> AgentSessionRemoteHostBinding? {
        guard let remoteSessionID else { return nil }
        return AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: hostDisplayName,
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            nextLogOffset: nextLogOffset
        )
    }

    func handleInboundFrame(_ frame: RemoteServerFrame) async {
        guard !isShutdown else { return }
        guard frame.sessionID == nil || frame.sessionID == remoteSessionID else { return }
        if let seq = frame.seq {
            if seq <= lastAppliedSeq { return }
            if seq > lastAppliedSeq + 1 {
                try? await catchUpFromHost()
            }
            lastAppliedSeq = max(lastAppliedSeq, seq)
            emitBinding()
        }
        switch frame.type {
        case "session_update":
            if let payload = frame.payload {
                applySnapshot(payload, frameType: frame.type)
                scheduleLogCatchUp()
            }
        case "session_terminal":
            if let payload = frame.payload {
                applySnapshot(payload, frameType: frame.type)
                scheduleLogCatchUp()
            }
        case "session_expired":
            eventsContinuation.yield(.sessionExpired)
            eventsContinuation.yield(.terminal(status: "expired"))
        case "interaction_resolved":
            let object = frame.payload?.objectValue ?? [:]
            let interactionID = object["interaction_id"]?.stringValue ?? ""
            guard !interactionID.isEmpty else { return }
            eventsContinuation.yield(.interactionResolved(
                interactionID: interactionID,
                resolvedBy: object["resolved_by"]?.stringValue
            ))
        default:
            break
        }
    }

    func handleConnectionState(_ state: RemoteHostConnection.State) {
        guard !isShutdown else { return }
        switch state {
        case .connected:
            eventsContinuation.yield(.channel(.init(kind: .connected)))
        case let .degraded(code, _):
            eventsContinuation.yield(.channel(.init(kind: .degraded(reason: code))))
        case .revoked:
            eventsContinuation.yield(.channel(.init(kind: .revoked)))
        case .idle, .mintingTicket, .connecting:
            break
        }
    }

    private func commandWithTransportRetry(
        _ frame: RemoteClientFrame,
        operation _: String,
        mayRetryTransportLoss: Bool
    ) async throws -> JSONValue {
        do {
            return try await connection.command(frame)
        } catch let error as RemoteClientError {
            switch error {
            case .inDoubt:
                eventsContinuation.yield(.systemMessage("Command outcome uncertain — re-synced from host."))
                try? await catchUpFromHost()
                throw error
            case .connectionClosed, .transport, .timeout:
                guard mayRetryTransportLoss else { throw error }
                try await connection.ensureConnected()
                return try await connection.command(frame)
            default:
                throw error
            }
        }
    }

    private func catchUpFromHost() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        let poll = RemoteClientFrame(
            type: "poll",
            requestID: makeRequestID(prefix: "poll"),
            sessionID: sessionID,
            payload: .object(["timeout": .int(0)])
        )
        do {
            let snapshot = try await connection.command(poll)
            applySnapshot(snapshot, frameType: "session_update")
        } catch RemoteClientError.sessionExpired {
            eventsContinuation.yield(.sessionExpired)
            return
        }

        try await pageLogsFromHost()
    }

    private func pageLogsFromHost() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        var keepPaging = true
        while keepPaging {
            try ensureNotShutdown()
            let previousOffset = nextLogOffset
            let logFrame = RemoteClientFrame(
                type: "get_log",
                requestID: makeRequestID(prefix: "log"),
                sessionID: sessionID,
                payload: .object([
                    "offset": .int(nextLogOffset),
                    "limit": .int(20)
                ])
            )
            let pagePayload = try await connection.command(logFrame)
            guard let page = projector?.projectGetLogResponse(pagePayload) else { return }
            if !page.items.isEmpty {
                eventsContinuation.yield(.transcriptRows(page.items))
            }
            nextLogOffset = max(nextLogOffset, page.nextLogOffset)
            emitBinding()
            keepPaging = page.returnedTurnCount > 0
                && nextLogOffset < page.totalTurns
                && nextLogOffset > previousOffset
            if page.returnedTurnCount > 0, nextLogOffset <= previousOffset {
                eventsContinuation.yield(.systemMessage("Remote log page did not advance; stopped catch-up paging."))
            }
        }
    }

    private func scheduleLogCatchUp() {
        guard !isShutdown, remoteSessionID != nil else { return }
        scheduledLogCatchUpDirty = true
        guard scheduledLogCatchUpTask == nil else { return }
        scheduledLogCatchUpTask = Task {
            while self.scheduledLogCatchUpDirty, !self.isShutdown {
                self.scheduledLogCatchUpDirty = false
                try? await self.pageLogsFromHost()
            }
            self.scheduledLogCatchUpTask = nil
        }
    }

    private func applySnapshot(_ payload: JSONValue, frameType: String?) {
        guard !isShutdown else { return }
        guard let projection = projector?.projectSnapshot(payload, frameType: frameType) else { return }
        if projection.agentKindRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || projection.agentModelRaw != nil
            || projection.sessionName != nil
        {
            eventsContinuation.yield(.metadata(
                agentKindRaw: projection.agentKindRaw,
                modelRaw: projection.agentModelRaw,
                sessionName: projection.sessionName
            ))
        }
        eventsContinuation.yield(.runState(projection.runState, pendingInteraction: projection.pendingInteraction))
        if let resolved = Self.interactionResolution(from: payload) {
            eventsContinuation.yield(.interactionResolved(
                interactionID: resolved.interactionID,
                resolvedBy: resolved.resolvedBy
            ))
        }
        if projection.isExpired {
            eventsContinuation.yield(.sessionExpired)
        }
        if let terminalStatus = projection.terminalStatus {
            eventsContinuation.yield(.terminal(status: terminalStatus))
        }
    }

    private func emitBinding() {
        guard !isShutdown, let binding = currentBinding() else { return }
        eventsContinuation.yield(.binding(binding))
    }

    private func makeRequestID(prefix: String) -> String {
        "rpce-n5-\(prefix)-\(UUID().uuidString)"
    }

    private func ensureNotShutdown() throws {
        if isShutdown {
            throw RemoteClientError.protocolViolation("Remote controller is shut down.")
        }
    }

    private func missingSessionError() -> RemoteClientError {
        .sessionExpired(.init(code: "missing_session", message: "Remote session is not attached."))
    }

    private static func remoteSessionID(from payload: JSONValue) throws -> String {
        guard let object = payload.objectValue else {
            throw RemoteClientError.protocolViolation("agent_run start did not return an object payload.")
        }
        if let sessionID = object["session_id"]?.stringValue,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionID
        }
        if let sessionID = object["session"]?.objectValue?["id"]?.stringValue,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionID
        }
        throw RemoteClientError.protocolViolation("agent_run start response did not include session_id.")
    }

    private static func interactionResolution(from payload: JSONValue) -> (interactionID: String, resolvedBy: String?)? {
        guard let meta = payload.objectValue?["_meta"]?.objectValue,
              let resolved = meta["interaction_resolved"]?.objectValue,
              let interactionID = resolved["interaction_id"]?.stringValue,
              !interactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (interactionID, resolved["resolved_by"]?.stringValue)
    }
}
