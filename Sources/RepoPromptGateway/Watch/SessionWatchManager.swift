import Foundation
import Logging
import MCP
import RepoPromptRemoteWire

private enum SessionWatchError: Error, Equatable, CustomStringConvertible {
    case pairedAppLinkUnavailable(String)
    case toolCallFailed(String)

    var description: String {
        switch self {
        case let .pairedAppLinkUnavailable(deviceID):
            "No paired-device app link is available for \(deviceID); observation is paused."
        case let .toolCallFailed(message):
            "agent_run tool call failed: \(message)"
        }
    }
}

actor SessionWatchManager {
    private struct DeviceState {
        var sinks: [UUID: any RemoteFrameSink] = [:]
        var watchedSessionIDs: Set<String> = []
        var activeWaitSessionIDs: Set<String> = []
        var waitTask: Task<Void, Never>?
        var waitTaskID: UUID?
        /// Whether the device has a registered Web Push subscription; refreshed on
        /// subscribe, sink removal, and explicit push (un)subscription changes.
        var pushEligible = false
    }

    private let appLink: AppLinkSession
    private let appLinkPool: AppLinkPool?
    private let pushNotifier: (any RemotePushNotifying)?
    private let logger: Logger
    private let waitTimeoutSeconds: TimeInterval
    private let pollRefreshSeconds: TimeInterval
    private var devices: [String: DeviceState] = [:]
    private var seqByDeviceSession: [String: UInt64] = [:]
    /// Last wake kind pushed per (device, session); prevents duplicate pushes for
    /// the same wake-worthy state while allowing a fresh push after re-arm.
    private var lastPushKindByDeviceSession: [String: String] = [:]
    /// Last forwarded interaction resolution per (device, session); snapshots carry
    /// the most recent resolution on every wait/poll response, so forward each
    /// distinct resolution as an `interaction_resolved` frame exactly once.
    private var lastResolutionKeyByDeviceSession: [String: String] = [:]
    private var appLinkStateTask: Task<Void, Never>?

    init(
        appLink: AppLinkSession,
        appLinkPool: AppLinkPool? = nil,
        pushNotifier: (any RemotePushNotifying)? = nil,
        logger: Logger = Logger(label: "com.repoprompt.gateway.watch"),
        waitTimeoutSeconds: TimeInterval = 30,
        pollRefreshSeconds: TimeInterval = 5
    ) {
        self.appLink = appLink
        self.appLinkPool = appLinkPool
        self.pushNotifier = pushNotifier
        self.logger = logger
        self.waitTimeoutSeconds = waitTimeoutSeconds
        self.pollRefreshSeconds = pollRefreshSeconds
    }

    /// Paired devices observe through their own bootstrap app leg when one exists.
    /// A `remote:*` device must never borrow the default gateway-principal link; if
    /// its per-device link is missing, observation pauses until the link returns.
    private func appLink(forDevice deviceID: String) async throws -> AppLinkSession {
        if let appLinkPool, let session = await appLinkPool.session(forDevice: deviceID) {
            return session
        }
        if deviceID == RemoteGatewayRuntime.phase0DeviceID || !deviceID.hasPrefix("remote:") {
            return appLink
        }
        throw SessionWatchError.pairedAppLinkUnavailable(deviceID)
    }

    func start() {
        guard appLinkStateTask == nil else { return }
        appLinkStateTask = Task { [weak self] in
            guard let self else { return }
            for await state in appLink.stateEvents {
                await handleAppLinkState(state)
            }
        }
    }

    func shutdown() {
        appLinkStateTask?.cancel()
        appLinkStateTask = nil
        for deviceID in Array(devices.keys) {
            cancelWaitTask(deviceID: deviceID)
        }
        devices.removeAll()
    }

    func registerSink(deviceID: String, sinkID: UUID, sink: any RemoteFrameSink) {
        var state = devices[deviceID] ?? DeviceState()
        state.sinks[sinkID] = sink
        devices[deviceID] = state
    }

    func removeSink(deviceID: String, sinkID: UUID) async {
        guard var state = devices[deviceID] else { return }
        state.sinks.removeValue(forKey: sinkID)
        if state.sinks.isEmpty, state.watchedSessionIDs.isEmpty {
            state.waitTask?.cancel()
            devices.removeValue(forKey: deviceID)
            return
        }
        devices[deviceID] = state
        // The wake-push contract requires watching sessions for DISCONNECTED
        // devices that hold a push subscription, so refresh eligibility before
        // deciding whether the wait loop keeps running without sinks.
        await refreshPushEligibility(deviceID: deviceID)
        ensureWaitLoop(deviceID: deviceID)
    }

    func subscribe(
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink,
        sessionIDs requestedSessionIDs: [String]
    ) async {
        registerSink(deviceID: deviceID, sinkID: sinkID, sink: sink)
        await refreshPushEligibility(deviceID: deviceID)
        for sessionID in requestedSessionIDs {
            await validateAndAddSession(deviceID: deviceID, sessionID: sessionID)
        }
        ensureWaitLoop(deviceID: deviceID)
    }

    func unsubscribe(deviceID: String, sessionIDs: [String]) {
        guard var state = devices[deviceID] else { return }
        for sessionID in sessionIDs {
            state.watchedSessionIDs.remove(sessionID)
            state.activeWaitSessionIDs.remove(sessionID)
        }
        devices[deviceID] = state
        ensureWaitLoop(deviceID: deviceID)
    }

    func teardownDevice(deviceID: String, reason: String, message: String) async {
        guard let state = devices.removeValue(forKey: deviceID) else { return }
        state.waitTask?.cancel()
        for sessionID in state.watchedSessionIDs {
            let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
            seqByDeviceSession.removeValue(forKey: key)
            lastPushKindByDeviceSession.removeValue(forKey: key)
            lastResolutionKeyByDeviceSession.removeValue(forKey: key)
        }
        let frame = RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string(reason),
                "message": .string(message)
            ])
        )
        for sink in state.sinks.values {
            await sink.send(frame)
            await sink.close()
        }
    }

    func rearm(deviceID: String, sessionID: String?) {
        guard let sessionID, var state = devices[deviceID], state.watchedSessionIDs.contains(sessionID) else {
            return
        }
        state.activeWaitSessionIDs.insert(sessionID)
        devices[deviceID] = state
        // The session left its wake-worthy state via respond/steer; the next
        // wake-worthy transition should push again for a disconnected device.
        lastPushKindByDeviceSession.removeValue(forKey: deviceSessionKey(deviceID: deviceID, sessionID: sessionID))
        ensureWaitLoop(deviceID: deviceID)
    }

    /// Called when a device's push subscription is added or removed so wait-loop
    /// scheduling reflects the new wake eligibility immediately.
    func pushEligibilityChanged(deviceID: String) async {
        await refreshPushEligibility(deviceID: deviceID)
        ensureWaitLoop(deviceID: deviceID)
    }

    private func refreshPushEligibility(deviceID: String) async {
        guard let pushNotifier else { return }
        let eligible = await pushNotifier.isPushEligible(deviceID: deviceID)
        guard var state = devices[deviceID] else { return }
        state.pushEligible = eligible
        devices[deviceID] = state
    }

    func pollCatchUp(deviceID: String) async {
        guard let state = devices[deviceID] else { return }
        for sessionID in state.watchedSessionIDs.sorted() {
            await validateAndAddSession(deviceID: deviceID, sessionID: sessionID)
        }
        ensureWaitLoop(deviceID: deviceID)
    }

    func nextSeq(deviceID: String, sessionID: String) -> UInt64 {
        let key = "\(deviceID)\u{0}\(sessionID)"
        let next = (seqByDeviceSession[key] ?? 0) + 1
        seqByDeviceSession[key] = next
        return next
    }

    private func validateAndAddSession(deviceID: String, sessionID: String) async {
        do {
            let snapshots = try await poll(deviceID: deviceID, sessionIDs: [sessionID])
            guard let snapshot = snapshots.first else {
                // No parseable snapshot is NOT authoritative expiry: the app may be
                // mid-workspace-switch or returned a partial/odd-shaped response.
                // Only an explicit `status == "expired"` snapshot may expire a session.
                logger.debug("Pausing remote subscription \(sessionID): poll returned no parseable snapshot")
                markSessionPendingObservation(deviceID: deviceID, sessionID: sessionID)
                scheduleWaitLoopRetry(deviceID: deviceID)
                return
            }
            guard !snapshot.isExpired else {
                await emitExpired(deviceID: deviceID, sessionID: sessionID)
                return
            }
            var state = devices[deviceID] ?? DeviceState()
            state.watchedSessionIDs.insert(snapshot.sessionID)
            if snapshot.isActionable || snapshot.isTerminal {
                state.activeWaitSessionIDs.remove(snapshot.sessionID)
            } else {
                state.activeWaitSessionIDs.insert(snapshot.sessionID)
            }
            devices[deviceID] = state
            await emitSnapshot(deviceID: deviceID, snapshot: snapshot)
        } catch let error as SessionWatchError {
            logger.debug("Pausing remote subscription \(sessionID): \(error.description)")
            markSessionPendingObservation(deviceID: deviceID, sessionID: sessionID)
            scheduleWaitLoopRetry(deviceID: deviceID)
        } catch {
            logger.debug("Pausing remote subscription \(sessionID) after app-link/tool error: \(String(describing: error))")
            await pauseObservationAfterToolError(deviceID: deviceID, sessionID: sessionID, error: error)
        }
    }

    private func markSessionPendingObservation(deviceID: String, sessionID: String) {
        var state = devices[deviceID] ?? DeviceState()
        state.watchedSessionIDs.insert(sessionID)
        state.activeWaitSessionIDs.insert(sessionID)
        devices[deviceID] = state
    }

    private func pauseObservationAfterToolError(deviceID: String, sessionID: String, error: Error) async {
        if await appLinkReconnectBudgetExhausted(deviceID: deviceID) {
            await emitChannelClosing(deviceID: deviceID, reason: "app_link_failed", message: String(describing: error))
            return
        }
        markSessionPendingObservation(deviceID: deviceID, sessionID: sessionID)
        scheduleWaitLoopRetry(deviceID: deviceID)
    }

    private func ensureWaitLoop(deviceID: String) {
        guard var state = devices[deviceID] else { return }
        if state.waitTask?.isCancelled == true {
            state.waitTask = nil
            state.waitTaskID = nil
        }
        // Wake-push semantics: a disconnected device with a push subscription keeps
        // its wait loop so wake-worthy transitions can trigger Web Push.
        let shouldRun = !state.activeWaitSessionIDs.isEmpty && (!state.sinks.isEmpty || state.pushEligible)
        if !shouldRun {
            state.waitTask?.cancel()
            state.waitTask = nil
            devices[deviceID] = state
            return
        }
        guard state.waitTask == nil else {
            devices[deviceID] = state
            return
        }
        let waitTaskID = UUID()
        state.waitTaskID = waitTaskID
        state.waitTask = Task { [weak self] in
            await self?.runWaitLoop(deviceID: deviceID, taskID: waitTaskID)
        }
        devices[deviceID] = state
    }

    private func cancelWaitTask(deviceID: String) {
        devices[deviceID]?.waitTask?.cancel()
        devices[deviceID]?.waitTask = nil
        devices[deviceID]?.waitTaskID = nil
    }

    private func runWaitLoop(deviceID: String, taskID: UUID) async {
        defer {
            clearWaitTask(deviceID: deviceID, taskID: taskID)
        }
        while !Task.isCancelled {
            guard let state = devices[deviceID],
                  !state.activeWaitSessionIDs.isEmpty,
                  !state.sinks.isEmpty || state.pushEligible
            else { return }
            let sessionIDs = state.activeWaitSessionIDs.sorted()
            do {
                let value = try await callAgentRunWait(deviceID: deviceID, sessionIDs: sessionIDs)
                let snapshots = RemoteSessionSnapshot.extractSnapshots(from: value)
                if snapshots.isEmpty {
                    try await Task.sleep(for: .milliseconds(Int64((pollRefreshSeconds * 1000).rounded(.up))))
                    continue
                }
                for snapshot in snapshots {
                    await handleWaitSnapshot(deviceID: deviceID, snapshot: snapshot)
                }
            } catch is CancellationError {
                return
            } catch let error as SessionWatchError {
                logger.debug("Pausing remote wait loop for \(deviceID): \(error.description)")
                scheduleWaitLoopRetry(deviceID: deviceID)
                return
            } catch {
                logger.debug("Remote wait loop paused for \(deviceID) after app-link/tool error: \(String(describing: error))")
                if await appLinkReconnectBudgetExhausted(deviceID: deviceID) {
                    await emitChannelClosing(deviceID: deviceID, reason: "app_link_failed", message: String(describing: error))
                } else {
                    scheduleWaitLoopRetry(deviceID: deviceID)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func clearWaitTask(deviceID: String, taskID: UUID) {
        guard var state = devices[deviceID], state.waitTaskID == taskID else { return }
        state.waitTask = nil
        state.waitTaskID = nil
        devices[deviceID] = state
    }

    private func scheduleWaitLoopRetry(deviceID: String, delay: TimeInterval? = nil) {
        let retryDelay = max(0.05, delay ?? pollRefreshSeconds)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64((retryDelay * 1000).rounded(.up))))
            await self?.retryWaitLoopIfStillWatched(deviceID: deviceID)
        }
    }

    private func retryWaitLoopIfStillWatched(deviceID: String) {
        ensureWaitLoop(deviceID: deviceID)
    }

    private func appLinkReconnectBudgetExhausted(deviceID: String) async -> Bool {
        do {
            let link = try await appLink(forDevice: deviceID)
            if case .failed = await link.currentState() {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    private func handleWaitSnapshot(deviceID: String, snapshot: RemoteSessionSnapshot) async {
        guard var state = devices[deviceID] else { return }
        if snapshot.isExpired {
            state.watchedSessionIDs.remove(snapshot.sessionID)
            state.activeWaitSessionIDs.remove(snapshot.sessionID)
            devices[deviceID] = state
            await emitExpired(deviceID: deviceID, sessionID: snapshot.sessionID)
            return
        }
        if snapshot.isActionable || snapshot.isTerminal {
            state.activeWaitSessionIDs.remove(snapshot.sessionID)
        } else if state.watchedSessionIDs.contains(snapshot.sessionID) {
            state.activeWaitSessionIDs.insert(snapshot.sessionID)
        }
        devices[deviceID] = state
        await emitSnapshot(deviceID: deviceID, snapshot: snapshot)
    }

    private func handleAppLinkState(_ state: AppLinkState) async {
        switch state {
        case let .disconnected(reason), let .reconnecting(_, reason):
            for deviceID in devices.keys.sorted() {
                cancelWaitTask(deviceID: deviceID)
                logger.debug("Pausing remote wait loop for \(deviceID) while app link reconnects: \(reason)")
                scheduleWaitLoopRetry(deviceID: deviceID)
            }
        case let .closing(reason, message):
            // M6.3: graceful app-announced teardown — forward `channel_closing`
            // BEFORE the transport drop arrives so remote clients can distinguish
            // an orderly shutdown from an abrupt link loss.
            for deviceID in devices.keys.sorted() {
                cancelWaitTask(deviceID: deviceID)
                await emitChannelClosing(
                    deviceID: deviceID,
                    reason: reason,
                    message: message ?? "The RepoPrompt app MCP channel is closing."
                )
            }
        case .connected, .reconnected:
            for deviceID in devices.keys.sorted() {
                await pollCatchUp(deviceID: deviceID)
            }
        case let .failed(reason):
            for deviceID in devices.keys.sorted() {
                cancelWaitTask(deviceID: deviceID)
                await emitChannelClosing(deviceID: deviceID, reason: "app_link_failed", message: reason)
            }
        }
    }

    private func poll(deviceID: String, sessionIDs: [String]) async throws -> [RemoteSessionSnapshot] {
        let value = try await callAgentRunPoll(deviceID: deviceID, sessionIDs: sessionIDs)
        return RemoteSessionSnapshot.extractSnapshots(from: value)
    }

    private func callAgentRunPoll(deviceID: String, sessionIDs: [String]) async throws -> JSONValue {
        let args: [String: Value] = if sessionIDs.count == 1 {
            [
                "op": .string("poll"),
                "_rawJSON": .bool(true),
                "session_id": .string(sessionIDs[0])
            ]
        } else {
            [
                "op": .string("poll"),
                "_rawJSON": .bool(true),
                "session_ids": .array(sessionIDs.map(Value.string))
            ]
        }
        let result = try await appLink(forDevice: deviceID).callTool(name: "agent_run", arguments: args, timeout: 15)
        let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
        if result.isError == true {
            // Tool-level errors are retryable observation pauses, never expiry.
            throw SessionWatchError.toolCallFailed(Self.toolErrorMessage(from: payload))
        }
        return payload
    }

    private func callAgentRunWait(deviceID: String, sessionIDs: [String]) async throws -> JSONValue {
        let args: [String: Value] = if sessionIDs.count == 1 {
            [
                "op": .string("wait"),
                "_rawJSON": .bool(true),
                "session_id": .string(sessionIDs[0]),
                "timeout": .double(waitTimeoutSeconds)
            ]
        } else {
            [
                "op": .string("wait"),
                "_rawJSON": .bool(true),
                "session_ids": .array(sessionIDs.map(Value.string)),
                "timeout": .double(waitTimeoutSeconds)
            ]
        }
        let result = try await appLink(forDevice: deviceID)
            .callTool(name: "agent_run", arguments: args, timeout: waitTimeoutSeconds + 5)
        let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
        if result.isError == true {
            // Tool-level errors are retryable observation pauses, never expiry.
            throw SessionWatchError.toolCallFailed(Self.toolErrorMessage(from: payload))
        }
        return payload
    }

    private static func toolErrorMessage(from payload: JSONValue) -> String {
        payload.objectValue?["error"]?.stringValue
            ?? payload.objectValue?["message"]?.stringValue
            ?? payload.objectValue?["text"]?.stringValue
            ?? "agent_run returned an error result"
    }

    private func emitSnapshot(deviceID: String, snapshot: RemoteSessionSnapshot) async {
        if snapshot.isExpired {
            await emitExpired(deviceID: deviceID, sessionID: snapshot.sessionID)
            return
        }
        await emitInteractionResolvedIfNeeded(deviceID: deviceID, snapshot: snapshot)
        let type = snapshot.isTerminal ? "session_terminal" : "session_update"
        let frame = RemoteServerFrame(
            type: type,
            sessionID: snapshot.sessionID,
            seq: nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID),
            payload: snapshot.payload
        )
        await broadcast(frame, deviceID: deviceID)
        await maybePushWake(deviceID: deviceID, snapshot: snapshot)
    }

    /// Wake-only push semantics (M5): push fires only when the device is
    /// DISCONNECTED (no live WS sinks) and only for wake-worthy transitions
    /// (`waiting_for_input` or a terminal state). The payload carries identifiers
    /// only; all state is fetched after wake via WS catch-up.
    private func maybePushWake(deviceID: String, snapshot: RemoteSessionSnapshot) async {
        guard let pushNotifier else { return }
        let key = deviceSessionKey(deviceID: deviceID, sessionID: snapshot.sessionID)
        let kind: WebPushWakePayload.Kind? = if snapshot.isActionable {
            .waitingForInput
        } else if snapshot.isTerminal {
            .sessionTerminal
        } else {
            nil
        }
        guard let kind else {
            // Non-wake-worthy state clears dedupe so the next transition pushes.
            lastPushKindByDeviceSession.removeValue(forKey: key)
            return
        }
        guard devices[deviceID]?.sinks.isEmpty ?? true else { return }
        guard lastPushKindByDeviceSession[key] != kind.rawValue else { return }
        guard await pushNotifier.isPushEligible(deviceID: deviceID) else { return }
        lastPushKindByDeviceSession[key] = kind.rawValue
        let interactionID = kind == .waitingForInput
            ? snapshot.payload.objectValue?["interaction_id"]?.stringValue
            : nil
        await pushNotifier.sendWake(
            deviceID: deviceID,
            payload: WebPushWakePayload(
                kind: kind,
                sessionID: snapshot.sessionID,
                interactionID: interactionID
            )
        )
    }

    private func deviceSessionKey(deviceID: String, sessionID: String) -> String {
        "\(deviceID)\u{0}\(sessionID)"
    }

    /// M6.2: forwards `_meta.interaction_resolved` from a wait/poll snapshot as a
    /// dedicated `interaction_resolved` frame. `resolved_by` distinguishes the
    /// resolving actor (`remote:<device8>`, a CLI client identity, or `user`).
    private func emitInteractionResolvedIfNeeded(deviceID: String, snapshot: RemoteSessionSnapshot) async {
        guard let resolution = snapshot.payload.objectValue?["_meta"]?.objectValue?["interaction_resolved"]?.objectValue,
              let interactionID = resolution["interaction_id"]?.stringValue
        else { return }
        let resolvedAt = resolution["resolved_at"]?.stringValue ?? ""
        let dedupeKey = "\(interactionID)\u{0}\(resolvedAt)"
        let key = deviceSessionKey(deviceID: deviceID, sessionID: snapshot.sessionID)
        guard lastResolutionKeyByDeviceSession[key] != dedupeKey else { return }
        lastResolutionKeyByDeviceSession[key] = dedupeKey
        var payload: [String: JSONValue] = [
            "session_id": .string(snapshot.sessionID),
            "interaction_id": .string(interactionID)
        ]
        if let resolvedBy = resolution["resolved_by"] {
            payload["resolved_by"] = resolvedBy
        }
        if let resolvedAtValue = resolution["resolved_at"] {
            payload["resolved_at"] = resolvedAtValue
        }
        let frame = RemoteServerFrame(
            type: "interaction_resolved",
            sessionID: snapshot.sessionID,
            seq: nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID),
            payload: .object(payload)
        )
        await broadcast(frame, deviceID: deviceID)
    }

    private func emitExpired(deviceID: String, sessionID: String) async {
        let frame = RemoteServerFrame(
            type: "session_expired",
            sessionID: sessionID,
            seq: nextSeq(deviceID: deviceID, sessionID: sessionID),
            payload: .object([
                "session_id": .string(sessionID),
                "status": .string("expired")
            ])
        )
        await broadcast(frame, deviceID: deviceID)
    }

    private func emitChannelClosing(deviceID: String, reason: String, message: String) async {
        let frame = RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string(reason),
                "message": .string(message)
            ])
        )
        await broadcast(frame, deviceID: deviceID)
    }

    private func broadcast(_ frame: RemoteServerFrame, deviceID: String) async {
        guard let state = devices[deviceID] else { return }
        for sink in state.sinks.values {
            await sink.send(frame)
        }
    }
}

struct RemoteSessionSnapshot: Equatable {
    let sessionID: String
    let status: String
    let payload: JSONValue

    var isActionable: Bool {
        status == "waiting_for_input"
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled"].contains(status)
    }

    var isExpired: Bool {
        status == "expired"
    }

    static func extractSnapshots(from value: JSONValue) -> [RemoteSessionSnapshot] {
        if let object = value.objectValue,
           let snapshots = object["snapshots"]?.arrayValue
        {
            return snapshots.compactMap(snapshot(from:))
        }
        if let snapshot = snapshot(from: value) {
            return [snapshot]
        }
        return []
    }

    private static func snapshot(from value: JSONValue) -> RemoteSessionSnapshot? {
        guard let object = value.objectValue,
              let sessionID = object["session_id"]?.stringValue,
              let status = object["status"]?.stringValue
        else { return nil }
        return RemoteSessionSnapshot(sessionID: sessionID, status: status, payload: value)
    }
}
