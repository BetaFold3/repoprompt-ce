import Foundation
import Logging
import MCP
import RepoPromptRemoteWire

enum AppLinkPoolError: Error, Equatable, CustomStringConvertible {
    /// The app rejected the per-device bootstrap connection because of connection
    /// capacity. Must surface to the remote client as `channel_closing {reason}`.
    case connectionCapacity(code: String, reason: String)
    case connectFailed(String)

    var code: String {
        switch self {
        case let .connectionCapacity(code, _): code
        case .connectFailed: "app_link_unavailable"
        }
    }

    var description: String {
        switch self {
        case let .connectionCapacity(code, reason):
            "The app rejected the device link (\(code)): \(reason)"
        case let .connectFailed(message):
            "Could not open the device app link: \(message)"
        }
    }
}

/// Maintains one bootstrap MCP `AppLinkSession` per paired device with
/// `clientName = "remote:<device8>"` (the paired device ID), binding each link to a
/// window at connect time and tearing links down on revocation.
actor AppLinkPool {
    struct BindingProbeResult: Equatable {
        let state: RemoteGatewayBindingState
        let refreshOnNextResolve: Bool

        static func known(_ state: RemoteGatewayBindingState) -> BindingProbeResult {
            BindingProbeResult(state: state, refreshOnNextResolve: false)
        }

        static let bound = BindingProbeResult.known(.bound)

        static func bindingRequired(_ message: String) -> BindingProbeResult {
            .known(.bindingRequired(message))
        }

        static func ambiguousStartTarget(_ message: String) -> BindingProbeResult {
            .known(.ambiguousStartTarget(message))
        }

        static let unknown = BindingProbeResult(state: .bound, refreshOnNextResolve: true)
    }

    typealias BindingProbe = @Sendable (AppLinkSession) async -> BindingProbeResult
    typealias MonotonicNow = @Sendable () -> TimeInterval

    static let defaultInitialBindingProbeTimeout: TimeInterval = 10
    static let defaultRefreshBindingProbeTimeout: TimeInterval = 2
    static let defaultUnknownBindingRefreshCooldown: TimeInterval = 4

    struct DeviceLink {
        let session: AppLinkSession
        var bindingState: RemoteGatewayBindingState
        var refreshBindingStateOnNextResolve: Bool
        var lastUnknownBindingProbeAt: TimeInterval?
    }

    private struct InFlightConnect {
        let id: UUID
        let task: Task<DeviceLink, Error>
    }

    private static let capacityErrorCodes: Set<String> = [
        "connection_limit_reached",
        "capacity_exceeded"
    ]

    private let configuration: GatewayConfiguration
    private let connector: any AppLinkConnecting
    private let bindingProbe: BindingProbe
    private let refreshBindingProbe: BindingProbe
    private let unknownBindingRefreshCooldown: TimeInterval
    private let now: MonotonicNow
    private let logger: Logger
    private var links: [String: DeviceLink] = [:]
    private var inFlightConnects: [String: InFlightConnect] = [:]

    init(
        configuration: GatewayConfiguration,
        logger: Logger = Logger(label: "com.repoprompt.gateway.applinkpool"),
        connector: (any AppLinkConnecting)? = nil,
        bindingProbe: BindingProbe? = nil,
        refreshBindingProbe: BindingProbe? = nil,
        unknownBindingRefreshCooldown: TimeInterval = AppLinkPool.defaultUnknownBindingRefreshCooldown,
        now: @escaping MonotonicNow = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.configuration = configuration
        self.connector = connector ?? GatewayBootstrapMCPConnector()
        self.logger = logger
        if let bindingProbe {
            self.bindingProbe = bindingProbe
            self.refreshBindingProbe = refreshBindingProbe ?? bindingProbe
        } else {
            self.bindingProbe = { session in
                await AppLinkPool.defaultBindingProbe(
                    session: session,
                    timeout: AppLinkPool.defaultInitialBindingProbeTimeout
                )
            }
            self.refreshBindingProbe = refreshBindingProbe ?? { session in
                await AppLinkPool.defaultBindingProbe(
                    session: session,
                    timeout: AppLinkPool.defaultRefreshBindingProbeTimeout
                )
            }
        }
        self.unknownBindingRefreshCooldown = unknownBindingRefreshCooldown
        self.now = now
    }

    /// Every per-device link is named after the paired device: `clientName = "remote:<device8>"`.
    private func makeSession(forDevice deviceID: String) -> AppLinkSession {
        AppLinkSession(
            config: configuration,
            clientName: deviceID,
            connector: connector,
            logger: Logger(label: "com.repoprompt.gateway.applink.\(deviceID)"),
            maximumReconnectAttempts: configuration.appLinkMaximumReconnectAttempts
        )
    }

    var activeDeviceIDs: [String] {
        links.keys.sorted()
    }

    func session(forDevice deviceID: String) -> AppLinkSession? {
        links[deviceID]?.session
    }

    func bindingState(forDevice deviceID: String) -> RemoteGatewayBindingState {
        links[deviceID]?.bindingState ?? .bound
    }

    func bindingStateRequiresRefresh(forDevice deviceID: String) -> Bool {
        guard let link = links[deviceID], link.refreshBindingStateOnNextResolve else { return false }
        guard unknownBindingRefreshCooldown > 0,
              let lastUnknownBindingProbeAt = link.lastUnknownBindingProbeAt
        else { return true }
        return now() - lastUnknownBindingProbeAt >= unknownBindingRefreshCooldown
    }

    @discardableResult
    func refreshBindingState(forDevice deviceID: String) async -> RemoteGatewayBindingState? {
        guard var link = links[deviceID] else { return nil }
        let refreshed = await refreshBindingProbe(link.session)
        applyBindingProbeResult(refreshed, to: &link)
        links[deviceID] = link
        logBindingState(refreshed.state, deviceID: deviceID)
        return refreshed.state
    }

    private func applyBindingProbeResult(_ result: BindingProbeResult, to link: inout DeviceLink) {
        link.bindingState = result.state
        link.refreshBindingStateOnNextResolve = result.refreshOnNextResolve
        link.lastUnknownBindingProbeAt = result.refreshOnNextResolve ? now() : nil
    }

    private func logBindingState(_ state: RemoteGatewayBindingState, deviceID: String) {
        if case let .bindingRequired(message) = state {
            logger.notice("Device link \(deviceID) requires explicit window binding: \(message)")
        }
    }

    /// Returns the existing per-device link or opens a new one. New links connect
    /// eagerly so bootstrap capacity rejections surface to the caller, then bind to a
    /// window: single-window auto-binds app-side; multi-window ambiguity is recorded as
    /// `binding_required` until an explicit selection is made.
    @discardableResult
    func ensureLink(forDevice deviceID: String) async throws -> AppLinkSession {
        if let existing = links[deviceID] {
            let state = await existing.session.currentState()
            if case .failed = state {
                links.removeValue(forKey: deviceID)
                await existing.session.shutdown()
            } else {
                if case .disconnected = state {
                    await existing.session.start()
                }
                return existing.session
            }
        }
        if let inFlight = inFlightConnects[deviceID] {
            return try await completeConnect(inFlight, forDevice: deviceID)
        }
        let inFlight = startConnect(forDevice: deviceID)
        inFlightConnects[deviceID] = inFlight
        return try await completeConnect(inFlight, forDevice: deviceID)
    }

    private func startConnect(forDevice deviceID: String) -> InFlightConnect {
        let session = makeSession(forDevice: deviceID)
        let bindingProbe = bindingProbe
        let task = Task<DeviceLink, Error> {
            do {
                try Task.checkCancellation()
                try await session.connect()
                try Task.checkCancellation()
                let bindingState = await bindingProbe(session)
                return DeviceLink(
                    session: session,
                    bindingState: bindingState.state,
                    refreshBindingStateOnNextResolve: bindingState.refreshOnNextResolve,
                    lastUnknownBindingProbeAt: nil
                )
            } catch let error as AppLinkError {
                await session.shutdown()
                if case let .handshakeRejected(errorCode, reason) = error,
                   let errorCode,
                   Self.capacityErrorCodes.contains(errorCode)
                {
                    throw AppLinkPoolError.connectionCapacity(
                        code: errorCode,
                        reason: reason ?? "The app is at connection capacity."
                    )
                }
                throw AppLinkPoolError.connectFailed(String(describing: error))
            } catch is CancellationError {
                await session.shutdown()
                throw AppLinkPoolError.connectFailed("Device link admission was cancelled.")
            } catch {
                await session.shutdown()
                throw AppLinkPoolError.connectFailed(String(describing: error))
            }
        }
        return InFlightConnect(id: UUID(), task: task)
    }

    private func completeConnect(_ inFlight: InFlightConnect, forDevice deviceID: String) async throws -> AppLinkSession {
        do {
            var link = try await inFlight.task.value
            if link.refreshBindingStateOnNextResolve {
                link.lastUnknownBindingProbeAt = now()
            }
            if let existing = links[deviceID] {
                if existing.session !== link.session {
                    await link.session.shutdown()
                }
                if inFlightConnects[deviceID]?.id == inFlight.id {
                    inFlightConnects.removeValue(forKey: deviceID)
                }
                return existing.session
            }
            guard inFlightConnects[deviceID]?.id == inFlight.id else {
                await link.session.shutdown()
                throw AppLinkPoolError.connectFailed("Device link admission was cancelled.")
            }
            inFlightConnects.removeValue(forKey: deviceID)
            links[deviceID] = link
            logBindingState(link.bindingState, deviceID: deviceID)
            return link.session
        } catch {
            if inFlightConnects[deviceID]?.id == inFlight.id {
                inFlightConnects.removeValue(forKey: deviceID)
            }
            throw error
        }
    }

    func setBindingState(
        _ state: RemoteGatewayBindingState,
        forDevice deviceID: String,
        refreshOnNextResolve: Bool = false
    ) {
        guard var link = links[deviceID] else { return }
        link.bindingState = state
        link.refreshBindingStateOnNextResolve = refreshOnNextResolve
        link.lastUnknownBindingProbeAt = refreshOnNextResolve ? now() : nil
        links[deviceID] = link
    }

    /// Tears down the device link (used on revocation and shutdown).
    @discardableResult
    func teardown(deviceID: String) async -> Bool {
        let inFlight = inFlightConnects.removeValue(forKey: deviceID)
        inFlight?.task.cancel()
        guard let link = links.removeValue(forKey: deviceID) else { return inFlight != nil }
        await link.session.shutdown()
        return true
    }

    /// Applies a trust snapshot: tears down links for revoked or unpaired devices.
    /// Returns the device IDs that were torn down so callers can audit the outcome.
    func applyTrustSnapshot(_ snapshot: GatewayTrustSnapshot) async -> [String] {
        var tornDown: [String] = []
        for deviceID in links.keys.sorted() {
            let device = snapshot.devices[deviceID]
            if device == nil || device?.isRevoked == true {
                if await teardown(deviceID: deviceID) {
                    tornDown.append(deviceID)
                }
            }
        }
        return tornDown
    }

    func shutdownAll() async {
        for deviceID in links.keys.sorted() {
            await teardown(deviceID: deviceID)
        }
    }

    /// Default bind-at-connect probe: ask the app-wide binding surface for this
    /// connection's actual binding. Transport failures are unknown (permissive for
    /// current routing, but re-probed on the next resolve) rather than durable bound.
    static func defaultBindingProbe(
        session: AppLinkSession,
        timeout: TimeInterval = AppLinkPool.defaultInitialBindingProbeTimeout
    ) async -> BindingProbeResult {
        do {
            let result = try await session.callTool(
                name: "bind_context",
                arguments: ["op": .string("list"), "_rawJSON": .bool(true)],
                timeout: timeout
            )
            guard result.isError == true else {
                return bindingProbeResult(fromSuccessfulBindContextList: result)
            }
            let payload = (try? RemoteMCPToolResultCodec.jsonValue(from: result))?.objectValue
            let message = payload?["error"]?.stringValue
                ?? payload?["message"]?.stringValue
                ?? payload?["text"]?.stringValue
                ?? "The app link is not bound to a window."
            let normalized = message.lowercased()
            if normalized.contains("window"), normalized.contains("bind") || normalized.contains("select") {
                return .bindingRequired(message)
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    private static func bindingProbeResult(fromSuccessfulBindContextList result: MCPToolResult) -> BindingProbeResult {
        guard let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
              let object = payload.objectValue
        else { return .unknown }

        if let binding = object["binding"]?.objectValue {
            let bindingKind = binding["binding_kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? binding["state"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let windowID = binding["window_id"]?.intValue
            if windowID != nil, bindingKind == "window" || bindingKind == "window_only" || bindingKind == "tab_context" {
                return .bound
            }
        }

        guard let windows = object["windows"]?.arrayValue else { return .unknown }
        let eligibleWindowCount = windows.reduce(0) { count, value in
            guard value.objectValue?["window_id"]?.intValue != nil else { return count }
            return count + 1
        }
        if eligibleWindowCount == 1 {
            return .bound
        }
        if eligibleWindowCount > 1 {
            return .bindingRequired("Multiple RepoPrompt windows are open; bind this connection to a window before remote operations.")
        }
        return .unknown
    }
}
