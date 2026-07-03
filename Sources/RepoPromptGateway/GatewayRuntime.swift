import Foundation
import Logging
import MCP

protocol RemoteFrameSink: Sendable {
    func send(_ frame: RemoteServerFrame) async
    func close() async
}

actor RemoteGatewayRuntime {
    static let phase0DeviceID = "phase0:static-token"

    private let appLink: AppLinkSession
    private let appLinkPool: AppLinkPool?
    private let ledger: CommandLedger
    private let watchManager: SessionWatchManager
    private let auditLog: RemoteAuditLog?
    private let logger: Logger
    private let defaultBindingState: RemoteGatewayBindingState
    private let pushSubscriptionStore: WebPushSubscriptionStore?
    private let now: @Sendable () -> Date

    init(
        appLink: AppLinkSession,
        ledger: CommandLedger,
        watchManager: SessionWatchManager,
        auditLog: RemoteAuditLog?,
        logger: Logger = Logger(label: "com.repoprompt.gateway.runtime"),
        bindingState: RemoteGatewayBindingState = .bound,
        appLinkPool: AppLinkPool? = nil,
        pushSubscriptionStore: WebPushSubscriptionStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appLink = appLink
        self.appLinkPool = appLinkPool
        self.ledger = ledger
        self.watchManager = watchManager
        self.auditLog = auditLog
        self.logger = logger
        defaultBindingState = bindingState
        self.pushSubscriptionStore = pushSubscriptionStore
        self.now = now
    }

    func registerSink(deviceID: String, sinkID: UUID, sink: any RemoteFrameSink) async {
        await watchManager.registerSink(deviceID: deviceID, sinkID: sinkID, sink: sink)
    }

    func removeSink(deviceID: String, sinkID: UUID) async {
        await watchManager.removeSink(deviceID: deviceID, sinkID: sinkID)
    }

    func teardownRevokedDevice(deviceID: String, reason: String = "device_revoked") async {
        await watchManager.teardownDevice(
            deviceID: deviceID,
            reason: reason,
            message: "This remote device is no longer trusted by the RepoPrompt app."
        )
    }

    func handle(
        _ frame: RemoteClientFrame,
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink
    ) async -> RemoteServerFrame? {
        switch frame.type {
        case "hello":
            .helloAck()
        case "ping":
            RemoteServerFrame(
                type: "pong",
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: frame.payload ?? .object([:])
            )
        case "subscribe":
            await handleSubscribe(frame, deviceID: deviceID, sinkID: sinkID, sink: sink)
        case "unsubscribe":
            await handleUnsubscribe(frame, deviceID: deviceID)
        case "push_subscribe":
            await handlePushSubscribe(frame, deviceID: deviceID)
        case "push_unsubscribe":
            await handlePushUnsubscribe(frame, deviceID: deviceID)
        default:
            await handleToolMappedCommand(frame, deviceID: deviceID)
        }
    }

    private func handleSubscribe(
        _ frame: RemoteClientFrame,
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink
    ) async -> RemoteServerFrame {
        // M6.6: subscription is an observation op — an unbound multi-window
        // connection must get a structured binding_required, not a silent
        // per-session failure from the catch-up poll.
        if let bindingError = await observationBindingError(deviceID: deviceID) {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: bindingError.code)
            return await .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: bindingError.code,
                message: bindingError.description,
                details: bindingErrorDetails(code: bindingError.code, existing: nil, deviceID: deviceID)
            )
        }
        do {
            let ids = try sessionIDs(from: frame)
            await watchManager.subscribe(deviceID: deviceID, sinkID: sinkID, sink: sink, sessionIDs: ids)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            return .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "subscribed_session_ids": .array(ids.map(JSONValue.string))
                ])
            )
        } catch let error as RemoteCommandTranslatorError {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: error.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: error.code,
                message: error.description
            )
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "subscribe_failed")
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "subscribe_failed",
                message: String(describing: error)
            )
        }
    }

    private func handleUnsubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        if let bindingError = await observationBindingError(deviceID: deviceID) {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: bindingError.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: bindingError.code,
                message: bindingError.description
            )
        }
        do {
            let ids = try sessionIDs(from: frame)
            await watchManager.unsubscribe(deviceID: deviceID, sessionIDs: ids)
            // Validate once after removal so unsubscribe remains a thin app-tool
            // translation without inventing an app-side remote control plane.
            _ = try? await callTranslatedTool(for: frame, deviceID: deviceID)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            return .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "unsubscribed_session_ids": .array(ids.map(JSONValue.string))
                ])
            )
        } catch let error as RemoteCommandTranslatorError {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: error.code)
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: error.code,
                message: error.description
            )
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "unsubscribe_failed")
            return .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "unsubscribe_failed",
                message: String(describing: error)
            )
        }
    }

    /// Gateway-owned Web Push registration for the authenticated device. The
    /// subscription is keyed by the connection's device ID (never a client-chosen
    /// ID) and is removed again on unsubscribe, revocation, or endpoint expiry.
    private func handlePushSubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let pushSubscriptionStore else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_unavailable")
            return .commandError(
                requestID: frame.requestID,
                code: "push_unavailable",
                message: "Web Push is not available on this gateway."
            )
        }
        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        guard let subscriptionValue = frame.payload?.objectValue?["subscription"],
              let subscription = WebPushSubscription.parse(from: subscriptionValue, nowMs: nowMs)
        else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "invalid_push_subscription")
            return .commandError(
                requestID: frame.requestID,
                code: "invalid_push_subscription",
                message: "payload.subscription must be {endpoint, keys: {p256dh, auth}} with an HTTPS endpoint."
            )
        }
        do {
            try pushSubscriptionStore.setSubscription(subscription, forDevice: deviceID)
        } catch {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_subscription_persist_failed")
            return .commandError(
                requestID: frame.requestID,
                code: "push_subscription_persist_failed",
                message: String(describing: error)
            )
        }
        await watchManager.pushEligibilityChanged(deviceID: deviceID)
        audit(frame: frame, deviceID: deviceID, outcome: "success")
        return .commandResult(
            requestID: frame.requestID,
            payload: .object(["status": .string("subscribed")])
        )
    }

    private func handlePushUnsubscribe(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let pushSubscriptionStore else {
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: "push_unavailable")
            return .commandError(
                requestID: frame.requestID,
                code: "push_unavailable",
                message: "Web Push is not available on this gateway."
            )
        }
        let removed = (try? pushSubscriptionStore.removeSubscription(forDevice: deviceID)) ?? false
        await watchManager.pushEligibilityChanged(deviceID: deviceID)
        audit(frame: frame, deviceID: deviceID, outcome: "success")
        return .commandResult(
            requestID: frame.requestID,
            payload: .object(["status": .string(removed ? "unsubscribed" : "not_subscribed")])
        )
    }

    private func handleToolMappedCommand(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        if RemoteWireProtocol.mutatingClientFrameTypes.contains(frame.type) {
            return await handleMutatingCommand(frame, deviceID: deviceID)
        }
        do {
            let payload = try await callTranslatedTool(for: frame, deviceID: deviceID)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            return .commandResult(requestID: frame.requestID, sessionID: frame.sessionID, payload: payload)
        } catch {
            let mapped = mapError(error, frame: frame)
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: mapped.code)
            return await .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: mapped.code,
                message: mapped.message,
                details: bindingErrorDetails(code: mapped.code, existing: mapped.details, deviceID: deviceID)
            )
        }
    }

    private func handleMutatingCommand(_ frame: RemoteClientFrame, deviceID: String) async -> RemoteServerFrame {
        guard let requestID = frame.requestID else {
            return .commandError(
                requestID: nil,
                sessionID: frame.sessionID,
                code: "missing_request_id",
                message: "request_id is required for mutating commands."
            )
        }
        let key = CommandLedger.Key(deviceID: deviceID, requestID: requestID)
        let fingerprint: CommandLedger.CommandFingerprint
        do {
            fingerprint = try RemoteWireProtocol.commandFingerprint(for: frame)
        } catch {
            return .commandError(
                requestID: requestID,
                sessionID: frame.sessionID,
                code: "fingerprint_failed",
                message: String(describing: error)
            )
        }

        switch await ledger.begin(key: key, fingerprint: fingerprint) {
        case .new:
            break
        case let .duplicate(outcome):
            audit(frame: frame, deviceID: deviceID, outcome: "duplicate", code: outcome.auditCode)
            return responseFrame(for: outcome, frame: frame)
        case .inFlight:
            audit(frame: frame, deviceID: deviceID, outcome: "in_flight", code: "in_flight")
            return .commandResult(
                requestID: requestID,
                sessionID: frame.sessionID,
                payload: .object([
                    "status": .string("in_flight"),
                    "message": .string("The original command is still in flight; poll/get_log for state if needed.")
                ])
            )
        case let .conflict(existing):
            audit(frame: frame, deviceID: deviceID, outcome: "conflict", code: "request_id_conflict")
            return .commandError(
                requestID: requestID,
                sessionID: frame.sessionID,
                code: "request_id_conflict",
                message: "request_id was already used for a different \(existing.operation) payload.",
                details: .object([
                    "existing_operation": .string(existing.operation),
                    "existing_fingerprint": .string(existing.canonicalPayloadSHA256)
                ])
            )
        case let .persistenceFailed(outcome):
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: outcome.auditCode)
            return responseFrame(for: outcome, frame: frame)
        }

        let outcome: CommandLedger.RecordedOutcome
        do {
            let payload = try await callTranslatedTool(for: frame, deviceID: deviceID)
            outcome = .success(payload)
            await ledger.complete(key: key, outcome: outcome)
            audit(frame: frame, deviceID: deviceID, outcome: "success")
            if frame.type == "steer" || frame.type == "respond" {
                await watchManager.rearm(deviceID: deviceID, sessionID: frame.sessionID)
            }
            return .commandResult(requestID: requestID, sessionID: frame.sessionID, payload: payload)
        } catch {
            outcome = ledgerOutcome(for: error, frame: frame)
            await ledger.complete(key: key, outcome: outcome)
            audit(frame: frame, deviceID: deviceID, outcome: "failure", code: outcome.auditCode)
            // M6.6: binding errors on start carry the eligible windows so remote
            // clients can render an explicit start-target picker.
            if case let .failure(code, message) = outcome,
               code == "binding_required" || code == "ambiguous_start_target"
            {
                return await .commandError(
                    requestID: requestID,
                    sessionID: frame.sessionID,
                    code: code,
                    message: message,
                    details: bindingErrorDetails(code: code, existing: nil, deviceID: deviceID)
                )
            }
            return responseFrame(for: outcome, frame: frame)
        }
    }

    private func callTranslatedTool(for frame: RemoteClientFrame, deviceID: String) async throws -> JSONValue {
        let (link, bindingState) = try await resolveAppLink(deviceID: deviceID)
        let translator = RemoteCommandTranslator(bindingState: bindingState)
        let toolCall = try translator.translate(frame)
        let result = try await link.callTool(
            name: toolCall.toolName,
            arguments: toolCall.arguments,
            timeout: toolCall.timeout
        )
        let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
        if result.isError == true {
            let runtimeError = RemoteGatewayRuntimeError.appToolError(payload: payload)
            if runtimeError.code(frame: frame) == "binding_required" {
                await appLinkPool?.refreshBindingState(forDevice: deviceID)
            }
            throw runtimeError
        }
        return payload
    }

    /// Paired devices route through their own bootstrap app leg (`remote:<device8>`)
    /// with the pool's bind-at-connect state; the phase0 static-token device keeps the
    /// default gateway app leg.
    private func resolveAppLink(deviceID: String) async throws -> (AppLinkSession, RemoteGatewayBindingState) {
        if let appLinkPool, let session = await appLinkPool.session(forDevice: deviceID) {
            let bindingState = await appLinkPool.bindingState(forDevice: deviceID)
            if case .bound = bindingState {
                return (session, bindingState)
            }
            let refreshed = await appLinkPool.refreshBindingState(forDevice: deviceID) ?? bindingState
            return (session, refreshed)
        }
        if deviceID == Self.phase0DeviceID || !deviceID.hasPrefix("remote:") {
            return (appLink, defaultBindingState)
        }
        throw RemoteGatewayRuntimeError.deviceAppLinkUnavailable(deviceID: deviceID)
    }

    /// M6.6: observation ops (subscribe/unsubscribe and the wait/poll they arm)
    /// on an unbound multi-window connection fail with `binding_required`.
    private func observationBindingError(deviceID: String) async -> RemoteCommandTranslatorError? {
        let resolved: (AppLinkSession, RemoteGatewayBindingState)
        do {
            resolved = try await resolveAppLink(deviceID: deviceID)
        } catch RemoteGatewayRuntimeError.deviceAppLinkUnavailable {
            return nil
        } catch {
            return nil
        }
        let bindingState = resolved.1
        switch bindingState {
        case .bound:
            return nil
        case let .bindingRequired(message):
            return .bindingRequired(message)
        case let .ambiguousStartTarget(message):
            return .bindingRequired(message)
        }
    }

    /// M6.6: enriches binding errors with the eligible windows so remote clients
    /// can render an explicit start-target picker. Best-effort — a gateway-internal
    /// `bind_context op=list` on the device's app leg; failures degrade to the
    /// plain error without details.
    private func bindingErrorDetails(code: String, existing: JSONValue?, deviceID: String) async -> JSONValue? {
        guard code == "binding_required" || code == "ambiguous_start_target" else { return existing }
        guard let windows = await eligibleStartTargetWindows(deviceID: deviceID) else { return existing }
        var object = existing?.objectValue ?? [:]
        object["windows"] = windows
        return .object(object)
    }

    private func eligibleStartTargetWindows(deviceID: String) async -> JSONValue? {
        guard let (link, _) = try? await resolveAppLink(deviceID: deviceID) else { return nil }
        guard let result = try? await link.callTool(
            name: "bind_context",
            arguments: ["op": .string("list"), "_rawJSON": .bool(true)],
            timeout: 10
        ), result.isError != true,
        let payload = try? RemoteMCPToolResultCodec.jsonValue(from: result),
        let windows = payload.objectValue?["windows"]?.arrayValue
        else { return nil }
        let summaries: [JSONValue] = windows.compactMap { window in
            guard let object = window.objectValue, let windowID = object["window_id"] else { return nil }
            var summary: [String: JSONValue] = ["window_id": windowID]
            if let workspace = object["workspace"]?.objectValue {
                if let workspaceID = workspace["id"] { summary["workspace_id"] = workspaceID }
                if let workspaceName = workspace["name"] { summary["workspace_name"] = workspaceName }
            }
            return .object(summary)
        }
        guard !summaries.isEmpty else { return nil }
        return .array(summaries)
    }

    private func responseFrame(for outcome: CommandLedger.RecordedOutcome, frame: RemoteClientFrame) -> RemoteServerFrame {
        switch outcome {
        case .success:
            .commandResult(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                payload: outcome.responsePayload
            )
        case let .failure(code, message):
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: code,
                message: message
            )
        case .interactionAlreadyResolved:
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "interaction_already_resolved",
                message: "The interaction was already resolved; poll/get_log for authoritative state.",
                details: outcome.responsePayload
            )
        case .inDoubt:
            .commandError(
                requestID: frame.requestID,
                sessionID: frame.sessionID,
                code: "in_doubt",
                message: "The command is in doubt after app-link loss or gateway recovery; poll/get_log for authoritative state."
            )
        }
    }

    private func ledgerOutcome(for error: Error, frame: RemoteClientFrame) -> CommandLedger.RecordedOutcome {
        if let appLinkError = error as? AppLinkError {
            switch appLinkError {
            case .toolCallTimedOut, .appLinkLost:
                return .inDoubt
            default:
                break
            }
        }
        if frame.type == "respond",
           let interactionID = frame.payload?.objectValue?["interaction_id"]?.stringValue,
           isInteractionAlreadyResolved(error)
        {
            return .interactionAlreadyResolved(interactionID: interactionID)
        }
        let mapped = mapError(error, frame: frame)
        return .failure(code: mapped.code, message: mapped.message)
    }

    private func mapError(_ error: Error, frame: RemoteClientFrame) -> (code: String, message: String, details: JSONValue?) {
        if let error = error as? RemoteCommandTranslatorError {
            return (error.code, error.description, nil)
        }
        if let error = error as? RemoteWireProtocolError {
            return (error.code, error.description, nil)
        }
        if let error = error as? AppLinkError {
            switch error {
            case .notConnected:
                return ("app_link_unavailable", error.description, nil)
            case .toolCallTimedOut:
                return ("tool_call_timeout", error.description, nil)
            case .appLinkLost:
                return ("app_link_lost", error.description, nil)
            default:
                return ("app_link_error", error.description, nil)
            }
        }
        if let runtimeError = error as? RemoteGatewayRuntimeError {
            return (runtimeError.code(frame: frame), runtimeError.message, runtimeError.details)
        }
        return ("command_failed", String(describing: error), nil)
    }

    private func isInteractionAlreadyResolved(_ error: Error) -> Bool {
        let message: String = if let runtimeError = error as? RemoteGatewayRuntimeError {
            runtimeError.message
        } else {
            String(describing: error)
        }
        let normalized = message.lowercased()
        return normalized.contains("already resolved")
            || normalized.contains("no pending interaction")
            || normalized.contains("not pending")
            || normalized.contains("interaction") && normalized.contains("stale")
    }

    private func sessionIDs(from frame: RemoteClientFrame) throws -> [String] {
        if let sessionID = frame.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return [sessionID]
        }
        if let values = frame.payload?.objectValue?["session_ids"]?.arrayValue {
            let ids = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !ids.isEmpty { return ids }
        }
        throw RemoteCommandTranslatorError.missingSessionID(frame.type)
    }

    private func audit(
        frame: RemoteClientFrame,
        deviceID: String,
        outcome: String,
        code: String? = nil
    ) {
        auditLog?.recordBestEffort(RemoteAuditRecord(
            deviceID: deviceID,
            requestID: frame.requestID,
            op: frame.type,
            sessionID: frame.sessionID,
            outcome: outcome,
            code: code
        ))
    }
}

enum RemoteGatewayRuntimeError: Error, Equatable {
    case appToolError(payload: JSONValue)
    case deviceAppLinkUnavailable(deviceID: String)

    var message: String {
        switch self {
        case let .appToolError(payload):
            if let object = payload.objectValue {
                if let error = object["error"]?.stringValue { return error }
                if let message = object["message"]?.stringValue { return message }
            }
            return "App tool returned an error."
        case let .deviceAppLinkUnavailable(deviceID):
            return "Device app link \(deviceID) is not active; remote commands are paused until it reconnects."
        }
    }

    var details: JSONValue? {
        switch self {
        case let .appToolError(payload):
            payload
        case let .deviceAppLinkUnavailable(deviceID):
            .object(["device_id": .string(deviceID)])
        }
    }

    func code(frame: RemoteClientFrame) -> String {
        switch self {
        case let .appToolError(payload):
            if let code = payload.objectValue?["code"]?.stringValue {
                return code
            }
            let normalized = message.lowercased()
            if normalized.contains("bind") && normalized.contains("window") {
                return "binding_required"
            }
            if frame.type == "start", normalized.contains("ambiguous") || normalized.contains("multiple") {
                return "ambiguous_start_target"
            }
            if normalized.contains("session"), normalized.contains("not found") || normalized.contains("no longer active") {
                return "session_expired"
            }
            return "app_tool_error"
        case .deviceAppLinkUnavailable:
            return "app_link_unavailable"
        }
    }
}
