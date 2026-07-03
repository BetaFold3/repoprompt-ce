import Foundation
import Logging
import MCP

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
    typealias BindingProbe = @Sendable (AppLinkSession) async -> RemoteGatewayBindingState

    struct DeviceLink {
        let session: AppLinkSession
        var bindingState: RemoteGatewayBindingState
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
    private let logger: Logger
    private var links: [String: DeviceLink] = [:]
    private var inFlightConnects: [String: InFlightConnect] = [:]

    init(
        configuration: GatewayConfiguration,
        logger: Logger = Logger(label: "com.repoprompt.gateway.applinkpool"),
        connector: (any AppLinkConnecting)? = nil,
        bindingProbe: BindingProbe? = nil
    ) {
        self.configuration = configuration
        self.connector = connector ?? GatewayBootstrapMCPConnector()
        self.logger = logger
        self.bindingProbe = bindingProbe ?? { session in
            await AppLinkPool.defaultBindingProbe(session: session)
        }
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

    @discardableResult
    func refreshBindingState(forDevice deviceID: String) async -> RemoteGatewayBindingState? {
        guard var link = links[deviceID] else { return nil }
        let refreshed = await bindingProbe(link.session)
        link.bindingState = refreshed
        links[deviceID] = link
        logBindingState(refreshed, deviceID: deviceID)
        return refreshed
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
                return DeviceLink(session: session, bindingState: bindingState)
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
            let link = try await inFlight.task.value
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

    func setBindingState(_ state: RemoteGatewayBindingState, forDevice deviceID: String) {
        guard var link = links[deviceID] else { return }
        link.bindingState = state
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

    /// Default bind-at-connect probe: issue a benign window-scoped call so the app
    /// auto-binds in single-window mode; a structured bind/window failure marks the
    /// link `binding_required` until an explicit selection exists.
    static func defaultBindingProbe(session: AppLinkSession) async -> RemoteGatewayBindingState {
        do {
            let result = try await session.callTool(
                name: "agent_manage",
                arguments: [
                    "op": .string("list_sessions"),
                    "limit": .int(1),
                    "_rawJSON": .bool(true)
                ],
                timeout: 10
            )
            guard result.isError == true else {
                return .bound
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
            return .bound
        } catch {
            // Transport-level probe failures are not binding ambiguity; later
            // operations surface their own app-link errors.
            return .bound
        }
    }
}
