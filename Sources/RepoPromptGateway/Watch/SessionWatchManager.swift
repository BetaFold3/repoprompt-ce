import CryptoKit
import Foundation
import Logging
import MCP
import RepoPromptRemoteWire

private enum SessionWatchError: Error, Equatable {
    case observationFailure(RemoteObservationFailureReason)
}

actor SessionWatchManager {
    typealias WindowResolver = @Sendable (_ deviceID: String, _ sessionID: String) async -> Int?
    typealias WaitDeadlineSleep = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias WaitRetrySleep = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias WindowRecovery = @Sendable (
        _ deviceID: String,
        _ sessionID: String,
        _ invalidate: Bool
    ) async -> Int?

    struct ObservationFailureBudgets {
        let routingUnavailable: Int
        let linkUnavailable: Int
        let toolFailure: Int
        let invalidSnapshot: Int

        init(
            routingUnavailable: Int = 2,
            linkUnavailable: Int = 2,
            toolFailure: Int = 3,
            invalidSnapshot: Int = 2
        ) {
            self.routingUnavailable = max(1, routingUnavailable)
            self.linkUnavailable = max(1, linkUnavailable)
            self.toolFailure = max(1, toolFailure)
            self.invalidSnapshot = max(1, invalidSnapshot)
        }

        func limit(for reason: RemoteObservationFailureReason) -> Int {
            switch reason {
            case .routingUnavailable: routingUnavailable
            case .linkUnavailable: linkUnavailable
            case .toolFailure: toolFailure
            case .invalidSnapshot: invalidSnapshot
            }
        }
    }

    struct SubscriptionValidation {
        let deviceID: String
        let sinkID: UUID
        let sessionTokens: [String: UUID]

        var sessionIDs: [String] {
            sessionTokens.keys.sorted()
        }
    }

    private struct DeviceState {
        var sinks: [UUID: any RemoteFrameSink] = [:]
        var watchedSessionIDs: Set<String> = []
        var subscriptionTokenBySessionID: [String: UUID] = [:]
        var activeWaitSessionIDs: Set<String> = []
        var parkedActionableSessionIDs: Set<String> = []
        var parkedTerminalSessionIDs: Set<String> = []
        var waitTask: Task<Void, Never>?
        var waitTaskID: UUID?
        var revalidationTask: Task<Void, Never>?
        var revalidationTaskID: UUID?
        /// Whether the device has a registered Web Push subscription; refreshed on
        /// subscribe, sink removal, and explicit push (un)subscription changes.
        var pushEligible = false
    }

    private struct ObservationHealthState {
        let token: UUID
        var counts: [RemoteObservationFailureReason: Int] = [:]
        var failureEmitted = false
        var routingRecoveryAttempted = false
    }

    private struct RoutingRecoveryFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct WaitCycle {
        let id: UUID
        let owningTaskID: UUID
        let sessionTokens: [String: UUID]
        let watchdogTask: Task<Void, Never>
    }

    private struct QuarantinedTerminal {
        let id: UUID
        let snapshot: RemoteSessionSnapshot
        let task: Task<Void, Never>
    }

    private struct TerminalFingerprint: Equatable {
        var transcriptItemCount: Int?
        var updatedAt: String?

        var isEmpty: Bool {
            transcriptItemCount == nil && updatedAt == nil
        }
    }

    private enum EmissionTrigger: String {
        case subscribe
        case pollCatchUp
        case waitLoop
        case revalidation
        case quarantine
    }

    private typealias CatchUpSink = (sinkID: UUID, sink: any RemoteFrameSink)

    private let appLink: AppLinkSession
    private let appLinkPool: AppLinkPool?
    private let pushNotifier: (any RemotePushNotifying)?
    private let logger: Logger
    private let sequenceEpoch: String
    private let waitTimeoutSeconds: TimeInterval
    private let waitWatchdogMarginSeconds: TimeInterval
    private let waitDeadlineSleep: WaitDeadlineSleep
    private let waitRetrySleep: WaitRetrySleep
    private let pollRefreshSeconds: TimeInterval
    private let revalidationIntervalSeconds: TimeInterval
    private let terminalQuarantineSeconds: TimeInterval
    private let observationFailureBudgets: ObservationFailureBudgets
    private var windowResolver: WindowResolver?
    private var windowRecovery: WindowRecovery?
    private var devices: [String: DeviceState] = [:]
    private var seqByDeviceSession: [String: UInt64] = [:]
    /// Last wake kind pushed per (device, session); prevents duplicate pushes for
    /// the same wake-worthy state while allowing a fresh push after re-arm.
    private var lastPushKindByDeviceSession: [String: String] = [:]
    /// Last forwarded interaction resolution per (device, session); snapshots carry
    /// the most recent resolution on every wait/poll response, so forward each
    /// distinct resolution as an `interaction_resolved` frame exactly once.
    private var lastResolutionKeyByDeviceSession: [String: String] = [:]
    private var lastEmittedIsTerminalByDeviceSession: [String: Bool] = [:]
    private var lastEmittedTerminalFingerprintByDeviceSession: [String: TerminalFingerprint] = [:]
    private var pendingTerminalQuarantineByDeviceSession: [String: QuarantinedTerminal] = [:]
    private var observationHealthByDeviceSession: [String: ObservationHealthState] = [:]
    private var routingRecoveryByDeviceSession: [String: RoutingRecoveryFlight] = [:]
    private var waitCycleByDevice: [String: WaitCycle] = [:]
    private var appLinkStateTask: Task<Void, Never>?

    init(
        appLink: AppLinkSession,
        appLinkPool: AppLinkPool? = nil,
        pushNotifier: (any RemotePushNotifying)? = nil,
        windowResolver: WindowResolver? = nil,
        logger: Logger = Logger(label: "com.repoprompt.gateway.watch"),
        sequenceEpoch: String = UUID().uuidString.lowercased(),
        waitTimeoutSeconds: TimeInterval = 30,
        waitWatchdogMarginSeconds: TimeInterval = 10,
        waitDeadlineSleep: @escaping WaitDeadlineSleep = { seconds in
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
        },
        waitRetrySleep: @escaping WaitRetrySleep = { seconds in
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
        },
        pollRefreshSeconds: TimeInterval = 5,
        revalidationIntervalSeconds: TimeInterval = 30,
        terminalQuarantineSeconds: TimeInterval = 5,
        observationFailureBudgets: ObservationFailureBudgets = ObservationFailureBudgets()
    ) {
        self.appLink = appLink
        self.appLinkPool = appLinkPool
        self.pushNotifier = pushNotifier
        self.windowResolver = windowResolver
        self.logger = logger
        self.sequenceEpoch = sequenceEpoch
        self.waitTimeoutSeconds = waitTimeoutSeconds
        // The app call allows its transport up to waitTimeoutSeconds + 5; keep the
        // independent watchdog strictly outside that allowance so it cannot win early.
        self.waitWatchdogMarginSeconds = max(5.001, waitWatchdogMarginSeconds)
        self.waitDeadlineSleep = waitDeadlineSleep
        self.waitRetrySleep = waitRetrySleep
        self.pollRefreshSeconds = pollRefreshSeconds
        self.revalidationIntervalSeconds = revalidationIntervalSeconds
        self.terminalQuarantineSeconds = terminalQuarantineSeconds
        self.observationFailureBudgets = observationFailureBudgets
    }

    func setWindowResolver(_ resolver: WindowResolver?) {
        windowResolver = resolver
    }

    func setObservationRouting(
        windowResolver: WindowResolver?,
        windowRecovery: WindowRecovery?
    ) {
        self.windowResolver = windowResolver
        self.windowRecovery = windowRecovery
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
        throw SessionWatchError.observationFailure(.linkUnavailable)
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
            cancelRevalidationTask(deviceID: deviceID)
        }
        for quarantine in pendingTerminalQuarantineByDeviceSession.values {
            quarantine.task.cancel()
        }
        pendingTerminalQuarantineByDeviceSession.removeAll()
        for recovery in routingRecoveryByDeviceSession.values {
            recovery.task.cancel()
        }
        routingRecoveryByDeviceSession.removeAll()
        for cycle in waitCycleByDevice.values {
            cycle.watchdogTask.cancel()
        }
        waitCycleByDevice.removeAll()
        observationHealthByDeviceSession.removeAll()
        lastEmittedIsTerminalByDeviceSession.removeAll()
        lastEmittedTerminalFingerprintByDeviceSession.removeAll()
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
            state.revalidationTask?.cancel()
            cancelWaitCycle(deviceID: deviceID)
            devices.removeValue(forKey: deviceID)
            return
        }
        devices[deviceID] = state
        // The wake-push contract requires watching sessions for DISCONNECTED
        // devices that hold a push subscription, so refresh eligibility before
        // deciding whether the wait loop keeps running without sinks.
        await refreshPushEligibility(deviceID: deviceID)
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
    }

    /// Registers observation intent without polling or emitting. Production callers
    /// send the correlated subscribe result before starting the returned validation.
    func registerSubscription(
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink,
        sessionIDs requestedSessionIDs: [String]
    ) -> SubscriptionValidation {
        var state = devices[deviceID] ?? DeviceState()
        state.sinks[sinkID] = sink
        var sessionTokens: [String: UUID] = [:]
        for requestedSessionID in requestedSessionIDs {
            let sessionID = normalizedSessionID(requestedSessionID)
            guard !sessionID.isEmpty else { continue }
            let token = state.subscriptionTokenBySessionID[sessionID] ?? UUID()
            state.watchedSessionIDs.insert(sessionID)
            state.subscriptionTokenBySessionID[sessionID] = token
            sessionTokens[sessionID] = token
        }
        devices[deviceID] = state
        return SubscriptionValidation(deviceID: deviceID, sinkID: sinkID, sessionTokens: sessionTokens)
    }

    /// Performs the host validation/catch-up work for a registered subscription.
    /// The session token is rechecked after suspension so unsubscribe/expiry wins.
    /// Sink loss only disables targeted catch-up; device observation still starts.
    func validateSubscription(_ validation: SubscriptionValidation) async {
        await refreshPushEligibility(deviceID: validation.deviceID)
        for sessionID in validation.sessionIDs {
            guard let token = validation.sessionTokens[sessionID],
                  isCurrentSubscription(
                      deviceID: validation.deviceID,
                      sessionID: sessionID,
                      token: token
                  )
            else { continue }
            logger.info("watch validation started device_id=\(boundedLogIdentifier(validation.deviceID)) session_id=\(boundedLogIdentifier(sessionID)) stage=subscribe")
            await validateAndAddSession(
                deviceID: validation.deviceID,
                sessionID: sessionID,
                trigger: .subscribe,
                catchUpSinkID: validation.sinkID,
                subscriptionToken: token
            )
        }
        ensureWaitLoop(deviceID: validation.deviceID)
        ensureRevalidationLoop(deviceID: validation.deviceID)
    }

    /// Test/internal convenience retaining the original register-and-validate behavior.
    func subscribe(
        deviceID: String,
        sinkID: UUID,
        sink: any RemoteFrameSink,
        sessionIDs requestedSessionIDs: [String]
    ) async {
        let validation = registerSubscription(
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink,
            sessionIDs: requestedSessionIDs
        )
        await validateSubscription(validation)
    }

    func unsubscribe(deviceID: String, sessionIDs: [String]) {
        guard var state = devices[deviceID] else { return }
        for sessionID in sessionIDs {
            state.watchedSessionIDs.remove(sessionID)
            state.subscriptionTokenBySessionID.removeValue(forKey: sessionID)
            state.activeWaitSessionIDs.remove(sessionID)
            state.parkedActionableSessionIDs.remove(sessionID)
            state.parkedTerminalSessionIDs.remove(sessionID)
            clearTerminalObservationState(deviceID: deviceID, sessionID: sessionID)
            clearObservationHealth(deviceID: deviceID, sessionID: sessionID)
        }
        devices[deviceID] = state
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
    }

    func teardownDevice(deviceID: String, reason: String, message: String) async {
        guard let state = devices.removeValue(forKey: deviceID) else { return }
        state.waitTask?.cancel()
        state.revalidationTask?.cancel()
        cancelWaitCycle(deviceID: deviceID)
        for sessionID in state.watchedSessionIDs {
            let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
            lastPushKindByDeviceSession.removeValue(forKey: key)
            lastResolutionKeyByDeviceSession.removeValue(forKey: key)
            lastEmittedIsTerminalByDeviceSession.removeValue(forKey: key)
            lastEmittedTerminalFingerprintByDeviceSession.removeValue(forKey: key)
            if let quarantine = pendingTerminalQuarantineByDeviceSession.removeValue(forKey: key) {
                quarantine.task.cancel()
            }
            clearObservationHealth(deviceID: deviceID, sessionID: sessionID)
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
        logger.debug(
            "watch_accountability event=rearm outcome=rearm trigger=steer device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID))"
        )
        state.parkedActionableSessionIDs.remove(sessionID)
        state.parkedTerminalSessionIDs.remove(sessionID)
        state.activeWaitSessionIDs.insert(sessionID)
        devices[deviceID] = state
        // The session left its wake-worthy state via respond/steer; the next
        // wake-worthy transition should push again for a disconnected device.
        lastPushKindByDeviceSession.removeValue(forKey: deviceSessionKey(deviceID: deviceID, sessionID: sessionID))
        preserveObservationHealthForRearm(deviceID: deviceID, sessionID: sessionID)
        // A steer/respond opens a new observation epoch for this session: cancel
        // any pending completed-terminal quarantine and drop terminal-emission
        // dedupe state so a stale pre-mutation `completed` snapshot can never be
        // emitted (or suppress a fresh truthful terminal) after the mutation's
        // run starts. Fork-staged sessions hit the quarantine deterministically
        // via the unregistered-live-session `completed` projection.
        clearTerminalObservationState(deviceID: deviceID, sessionID: sessionID)
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
    }

    /// Called when a device's push subscription is added or removed so wait-loop
    /// scheduling reflects the new wake eligibility immediately.
    func pushEligibilityChanged(deviceID: String) async {
        await refreshPushEligibility(deviceID: deviceID)
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
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
        for sessionID in state.watchedSessionIDs.sorted()
            where !hasExhaustedRoutingEpoch(deviceID: deviceID, sessionID: sessionID)
        {
            await validateAndAddSession(deviceID: deviceID, sessionID: sessionID, trigger: .pollCatchUp)
        }
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
    }

    func nextSeq(deviceID: String, sessionID: String) -> UInt64 {
        let key = "\(deviceID)\u{0}\(sessionID)"
        let next = (seqByDeviceSession[key] ?? 0) + 1
        seqByDeviceSession[key] = next
        return next
    }

    private func validateAndAddSession(
        deviceID: String,
        sessionID: String,
        trigger: EmissionTrigger,
        catchUpSinkID: UUID? = nil,
        subscriptionToken: UUID? = nil,
        exhaustRoutingFailure: Bool = false
    ) async {
        guard isCurrentSubscription(
            deviceID: deviceID,
            sessionID: sessionID,
            token: subscriptionToken
        ) else { return }
        do {
            let snapshots = try await poll(deviceID: deviceID, sessionIDs: [sessionID])
            guard isCurrentSubscription(
                deviceID: deviceID,
                sessionID: sessionID,
                token: subscriptionToken
            ) else { return }
            let requestedSessionID = normalizedSessionID(sessionID)
            let requestedMatchKey = canonicalSessionMatchKey(requestedSessionID)
            guard var snapshot = snapshots.first(where: {
                canonicalSessionMatchKey($0.sessionID) == requestedMatchKey
            }) else {
                await pauseObservation(
                    deviceID: deviceID,
                    sessionID: sessionID,
                    token: subscriptionToken,
                    reason: .invalidSnapshot
                )
                return
            }
            if snapshot.sessionID != requestedSessionID {
                var payload = snapshot.payload.objectValue ?? [:]
                payload["session_id"] = .string(requestedSessionID)
                snapshot = RemoteSessionSnapshot(
                    sessionID: requestedSessionID,
                    status: snapshot.status,
                    payload: .object(payload)
                )
            }
            let catchUpSink = catchUpSinkID.flatMap { sinkID in
                subscriptionToken.flatMap { token in
                    currentCatchUpSink(
                        deviceID: deviceID,
                        sinkID: sinkID,
                        sessionID: sessionID,
                        token: token
                    )
                }
            }
            guard !snapshot.isExpired else {
                await emitSnapshot(deviceID: deviceID, snapshot: snapshot, trigger: trigger, catchUpSink: catchUpSink)
                return
            }
            guard isCurrentSubscription(
                deviceID: deviceID,
                sessionID: sessionID,
                token: subscriptionToken
            ) else { return }
            clearObservationHealthAfterSuccess(deviceID: deviceID, sessionID: sessionID, token: subscriptionToken)
            await emitSnapshot(deviceID: deviceID, snapshot: snapshot, trigger: trigger, catchUpSink: catchUpSink)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSubscription(
                deviceID: deviceID,
                sessionID: sessionID,
                token: subscriptionToken
            ) else { return }
            let reason = observationFailureReason(for: error)
            await pauseObservation(
                deviceID: deviceID,
                sessionID: sessionID,
                token: subscriptionToken,
                reason: reason,
                exhaustBudget: exhaustRoutingFailure && reason == .routingUnavailable
            )
        }
    }

    private func currentCatchUpSink(
        deviceID: String,
        sinkID: UUID,
        sessionID: String,
        token: UUID
    ) -> CatchUpSink? {
        guard let state = devices[deviceID],
              state.watchedSessionIDs.contains(sessionID),
              state.subscriptionTokenBySessionID[sessionID] == token,
              let sink = state.sinks[sinkID]
        else { return nil }
        return (sinkID: sinkID, sink: sink)
    }

    private func isCurrentSubscription(
        deviceID: String,
        sessionID: String,
        token: UUID?
    ) -> Bool {
        guard let state = devices[deviceID],
              state.watchedSessionIDs.contains(sessionID)
        else { return false }
        guard let token else { return true }
        return state.subscriptionTokenBySessionID[sessionID] == token
    }

    private func currentSubscriptionToken(
        deviceID: String,
        sessionID: String,
        expected: UUID?
    ) -> UUID? {
        guard let state = devices[deviceID],
              state.watchedSessionIDs.contains(sessionID),
              let current = state.subscriptionTokenBySessionID[sessionID],
              expected == nil || expected == current
        else { return nil }
        return current
    }

    private func recordObservationFailure(
        deviceID: String,
        sessionID: String,
        token: UUID,
        reason: RemoteObservationFailureReason,
        exhaustBudget: Bool = false
    ) async {
        guard currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: token) != nil else {
            return
        }
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        var health = observationHealthByDeviceSession[key]
        if health?.token != token {
            health = ObservationHealthState(token: token)
        }
        guard var health else { return }
        let priorCount = health.counts[reason] ?? 0
        let limit = observationFailureBudgets.limit(for: reason)
        let count = exhaustBudget ? max(priorCount + 1, limit) : priorCount + 1
        health.counts[reason] = count
        let shouldEmit = count >= limit && !health.failureEmitted
        if shouldEmit {
            health.failureEmitted = true
        }
        observationHealthByDeviceSession[key] = health
        let accountingOutcome = shouldEmit ? "exhausted" : "transition"
        logger.debug(
            "watch_accountability event=failure_accounting outcome=\(accountingOutcome) reason=\(reason.rawValue) device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) attempt=\(count) attempt_limit=\(limit)"
        )
        if priorCount == 0 {
            logger.notice(
                "observation event=issue outcome=\(reason.rawValue) device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) attempt=\(count) attempt_limit=\(limit)"
            )
        } else {
            logger.debug(
                "observation event=retry outcome=\(reason.rawValue) device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) attempt=\(count) attempt_limit=\(limit)"
            )
        }
        guard shouldEmit,
              currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: token) != nil
        else { return }
        let frame = RemoteServerFrame.observationFailure(
            sessionID: sessionID,
            reason: reason,
            attempt: count,
            attemptLimit: limit,
            seq: nextSeq(deviceID: deviceID, sessionID: sessionID),
            seqEpoch: sequenceEpoch
        )
        await broadcast(frame, deviceID: deviceID)
        logger.notice(
            "watch_accountability event=failure_accounting outcome=emitted reason=\(reason.rawValue) device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) attempt=\(count) attempt_limit=\(limit) frame_type=observation_failure seq=\(frame.seq.map(String.init) ?? "-") seq_epoch=\(boundedLogIdentifier(sequenceEpoch))"
        )
        logger.notice(
            "observation event=exhaustion outcome=emitted device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) reason=\(reason.rawValue)"
        )
    }

    private func clearObservationHealthAfterSuccess(
        deviceID: String,
        sessionID: String,
        token: UUID?
    ) {
        guard currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: token) != nil else {
            return
        }
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        let wasUnhealthy = observationHealthByDeviceSession[key] != nil
        clearObservationHealth(deviceID: deviceID, sessionID: sessionID)
        if wasUnhealthy {
            logger.notice(
                "observation event=return outcome=healthy device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID))"
            )
        } else {
            logger.debug(
                "observation event=return outcome=success device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID))"
            )
        }
    }

    private func hasExhaustedRoutingEpoch(deviceID: String, sessionID: String) -> Bool {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        guard let health = observationHealthByDeviceSession[key],
              health.failureEmitted,
              health.routingRecoveryAttempted
        else { return false }
        return (health.counts[.routingUnavailable] ?? 0) >= observationFailureBudgets.routingUnavailable
    }

    private func clearObservationHealth(deviceID: String, sessionID: String) {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        observationHealthByDeviceSession.removeValue(forKey: key)
        if let recovery = routingRecoveryByDeviceSession.removeValue(forKey: key) {
            recovery.task.cancel()
        }
    }

    private func preserveObservationHealthForRearm(deviceID: String, sessionID: String) {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        guard var health = observationHealthByDeviceSession[key],
              currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: health.token) != nil
        else { return }
        health.failureEmitted = false
        observationHealthByDeviceSession[key] = health
    }

    private func scheduleRoutingRecovery(
        deviceID: String,
        sessionID: String,
        token: UUID,
        invalidate: Bool
    ) {
        guard let windowRecovery,
              currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: token) != nil
        else { return }
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        var health = observationHealthByDeviceSession[key]
        if health?.token != token {
            health = ObservationHealthState(token: token)
        }
        guard var health, !health.routingRecoveryAttempted else { return }
        health.routingRecoveryAttempted = true
        observationHealthByDeviceSession[key] = health
        let recoveryID = UUID()
        logger.notice(
            "observation event=affinity_recovery outcome=issued device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID))"
        )
        let task = Task { [weak self] in
            let windowID = await windowRecovery(deviceID, sessionID, invalidate)
            guard !Task.isCancelled else { return }
            await self?.finishRoutingRecovery(
                deviceID: deviceID,
                sessionID: sessionID,
                token: token,
                recoveryID: recoveryID,
                windowID: windowID
            )
        }
        routingRecoveryByDeviceSession[key] = RoutingRecoveryFlight(id: recoveryID, task: task)
    }

    private func finishRoutingRecovery(
        deviceID: String,
        sessionID: String,
        token: UUID,
        recoveryID: UUID,
        windowID: Int?
    ) async {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        guard routingRecoveryByDeviceSession[key]?.id == recoveryID else { return }
        routingRecoveryByDeviceSession.removeValue(forKey: key)
        guard currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: token) != nil else {
            return
        }
        guard windowID != nil else {
            await recordObservationFailure(
                deviceID: deviceID,
                sessionID: sessionID,
                token: token,
                reason: .routingUnavailable,
                exhaustBudget: true
            )
            ensureWaitLoop(deviceID: deviceID)
            return
        }
        logger.notice(
            "observation event=affinity_recovery outcome=recovered device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) window_id=\(windowID.map(String.init) ?? "none")"
        )
        await validateAndAddSession(
            deviceID: deviceID,
            sessionID: sessionID,
            trigger: .pollCatchUp,
            subscriptionToken: token,
            exhaustRoutingFailure: true
        )
        ensureWaitLoop(deviceID: deviceID)
    }

    private func observationFailureReason(for error: Error) -> RemoteObservationFailureReason {
        if let error = error as? SessionWatchError,
           case let .observationFailure(reason) = error
        {
            return reason
        }
        if error is AppLinkError {
            return .linkUnavailable
        }
        return .toolFailure
    }

    private func normalizedSessionID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalSessionMatchKey(_ value: String) -> String {
        let normalized = normalizedSessionID(value)
        guard let uuid = UUID(uuidString: normalized) else { return normalized }
        return uuid.uuidString.lowercased()
    }

    private func boundedLogIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "id_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func suspendSessionForRoutingRecovery(deviceID: String, sessionID: String) {
        guard var state = devices[deviceID], state.watchedSessionIDs.contains(sessionID) else { return }
        state.activeWaitSessionIDs.remove(sessionID)
        state.parkedActionableSessionIDs.remove(sessionID)
        state.parkedTerminalSessionIDs.remove(sessionID)
        devices[deviceID] = state
    }

    private func markSessionPendingObservation(deviceID: String, sessionID: String) {
        logger.debug("watch mark_pending_observation device=\(boundedLogIdentifier(deviceID)) session=\(boundedLogIdentifier(sessionID))")
        guard var state = devices[deviceID], state.watchedSessionIDs.contains(sessionID) else { return }
        state.parkedActionableSessionIDs.remove(sessionID)
        state.parkedTerminalSessionIDs.remove(sessionID)
        state.activeWaitSessionIDs.insert(sessionID)
        devices[deviceID] = state
    }

    private func unparkOnExitFromActionable(state: inout DeviceState, deviceID: String, sessionID: String) {
        guard state.parkedActionableSessionIDs.remove(sessionID) != nil else { return }
        lastPushKindByDeviceSession.removeValue(forKey: deviceSessionKey(deviceID: deviceID, sessionID: sessionID))
    }

    private func pauseObservation(
        deviceID: String,
        sessionID: String,
        token: UUID?,
        reason: RemoteObservationFailureReason,
        exhaustBudget: Bool = false
    ) async {
        guard let currentToken = currentSubscriptionToken(
            deviceID: deviceID,
            sessionID: sessionID,
            expected: token
        ) else { return }
        if reason == .linkUnavailable, await appLinkReconnectBudgetExhausted(deviceID: deviceID) {
            await emitChannelClosing(
                deviceID: deviceID,
                reason: "app_link_failed",
                message: "The paired app link exhausted its reconnect budget."
            )
            return
        }
        if reason == .routingUnavailable {
            suspendSessionForRoutingRecovery(deviceID: deviceID, sessionID: sessionID)
        } else {
            markSessionPendingObservation(deviceID: deviceID, sessionID: sessionID)
        }
        await recordObservationFailure(
            deviceID: deviceID,
            sessionID: sessionID,
            token: currentToken,
            reason: reason,
            exhaustBudget: exhaustBudget
        )
        if reason == .routingUnavailable, !exhaustBudget {
            scheduleRoutingRecovery(
                deviceID: deviceID,
                sessionID: sessionID,
                token: currentToken,
                invalidate: true
            )
        } else {
            scheduleWaitLoopRetry(deviceID: deviceID)
        }
    }

    private func beginWaitCycle(
        deviceID: String,
        taskID: UUID,
        sessionTokens: [String: UUID]
    ) -> UUID {
        cancelWaitCycle(deviceID: deviceID)
        let cycleID = UUID()
        let deadlineSeconds = waitTimeoutSeconds + waitWatchdogMarginSeconds
        let deadlineSleep = waitDeadlineSleep
        let watchdogTask = Task { [weak self] in
            do {
                try await deadlineSleep(deadlineSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireWaitCycle(deviceID: deviceID, cycleID: cycleID)
        }
        waitCycleByDevice[deviceID] = WaitCycle(
            id: cycleID,
            owningTaskID: taskID,
            sessionTokens: sessionTokens,
            watchdogTask: watchdogTask
        )
        return cycleID
    }

    private func endWaitCycle(deviceID: String, cycleID: UUID) {
        guard let cycle = waitCycleByDevice[deviceID], cycle.id == cycleID else { return }
        cycle.watchdogTask.cancel()
        waitCycleByDevice.removeValue(forKey: deviceID)
    }

    private func cancelWaitCycle(deviceID: String) {
        guard let cycle = waitCycleByDevice.removeValue(forKey: deviceID) else { return }
        cycle.watchdogTask.cancel()
    }

    private func expireWaitCycle(deviceID: String, cycleID: UUID) async {
        guard let cycle = waitCycleByDevice[deviceID],
              cycle.id == cycleID,
              var state = devices[deviceID],
              state.waitTaskID == cycle.owningTaskID
        else { return }
        waitCycleByDevice.removeValue(forKey: deviceID)
        state.waitTask?.cancel()
        state.waitTask = nil
        state.waitTaskID = nil
        devices[deviceID] = state
        let durationMilliseconds = Int64(((waitTimeoutSeconds + waitWatchdogMarginSeconds) * 1000).rounded(.up))
        logger.notice(
            "watch_accountability event=wait_deadline outcome=deadline_exceeded duration_ms=\(durationMilliseconds) device_id=\(boundedLogIdentifier(deviceID)) correlation_id=\(boundedLogIdentifier(cycleID.uuidString))"
        )
        for sessionID in cycle.sessionTokens.keys.sorted() {
            guard let token = cycle.sessionTokens[sessionID] else { continue }
            await pauseObservation(
                deviceID: deviceID,
                sessionID: sessionID,
                token: token,
                reason: .toolFailure
            )
        }
        ensureWaitLoop(deviceID: deviceID)
    }

    private func ensureWaitLoop(deviceID: String) {
        guard var state = devices[deviceID] else { return }
        if state.waitTask?.isCancelled == true {
            state.waitTask = nil
            state.waitTaskID = nil
            cancelWaitCycle(deviceID: deviceID)
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
        cancelWaitCycle(deviceID: deviceID)
    }

    private func ensureRevalidationLoop(deviceID: String) {
        guard var state = devices[deviceID] else { return }
        if state.revalidationTask?.isCancelled == true {
            state.revalidationTask = nil
            state.revalidationTaskID = nil
        }
        let shouldRun = !(state.parkedActionableSessionIDs.isEmpty && state.parkedTerminalSessionIDs.isEmpty)
            && (!state.sinks.isEmpty || state.pushEligible)
        if !shouldRun {
            state.revalidationTask?.cancel()
            state.revalidationTask = nil
            state.revalidationTaskID = nil
            devices[deviceID] = state
            return
        }
        guard state.revalidationTask == nil else {
            devices[deviceID] = state
            return
        }
        let taskID = UUID()
        state.revalidationTaskID = taskID
        state.revalidationTask = Task { [weak self] in
            await self?.runRevalidationLoop(deviceID: deviceID, taskID: taskID)
        }
        devices[deviceID] = state
    }

    private func cancelRevalidationTask(deviceID: String) {
        devices[deviceID]?.revalidationTask?.cancel()
        devices[deviceID]?.revalidationTask = nil
        devices[deviceID]?.revalidationTaskID = nil
    }

    private func runRevalidationLoop(deviceID: String, taskID: UUID) async {
        defer {
            clearRevalidationTask(deviceID: deviceID, taskID: taskID)
        }
        let intervalMilliseconds = Int64((max(0.01, revalidationIntervalSeconds) * 1000).rounded(.up))
        while !Task.isCancelled {
            guard let state = devices[deviceID],
                  !(state.parkedActionableSessionIDs.isEmpty && state.parkedTerminalSessionIDs.isEmpty),
                  !state.sinks.isEmpty || state.pushEligible
            else { return }
            try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            guard !Task.isCancelled,
                  let current = devices[deviceID],
                  current.revalidationTaskID == taskID
            else { return }
            let sessionIDs = current.parkedActionableSessionIDs.union(current.parkedTerminalSessionIDs).sorted()
            for sessionID in sessionIDs {
                await validateAndAddSession(deviceID: deviceID, sessionID: sessionID, trigger: .revalidation)
            }
            ensureWaitLoop(deviceID: deviceID)
        }
    }

    private func clearRevalidationTask(deviceID: String, taskID: UUID) {
        guard var state = devices[deviceID], state.revalidationTaskID == taskID else { return }
        state.revalidationTask = nil
        state.revalidationTaskID = nil
        devices[deviceID] = state
    }

    private func runWaitLoop(deviceID: String, taskID: UUID) async {
        var shouldRearmAfterExit = false
        defer {
            clearWaitTask(deviceID: deviceID, taskID: taskID, rearm: shouldRearmAfterExit)
        }
        while !Task.isCancelled {
            guard let state = devices[deviceID],
                  !state.activeWaitSessionIDs.isEmpty,
                  !state.sinks.isEmpty || state.pushEligible
            else { return }
            let sessionIDs = state.activeWaitSessionIDs.sorted()
            do {
                let waitResult = try await waitAndHandlePartitions(
                    deviceID: deviceID,
                    sessionIDs: sessionIDs,
                    taskID: taskID,
                    includeStatusUpdates: !state.sinks.isEmpty
                )
                switch waitResult {
                case .snapshots:
                    break
                case .retryScheduled:
                    return
                case .rearmImmediately:
                    shouldRearmAfterExit = true
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                logger.notice(
                    "observation event=return outcome=loop_error device_id=\(boundedLogIdentifier(deviceID))"
                )
                scheduleWaitLoopRetry(deviceID: deviceID)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func clearWaitTask(deviceID: String, taskID: UUID, rearm: Bool) {
        guard var state = devices[deviceID], state.waitTaskID == taskID else { return }
        cancelWaitCycle(deviceID: deviceID)
        state.waitTask = nil
        state.waitTaskID = nil
        devices[deviceID] = state
        if rearm {
            ensureWaitLoop(deviceID: deviceID)
        }
    }

    private func scheduleWaitLoopRetry(deviceID: String, delay: TimeInterval? = nil) {
        let retryDelay = max(0.05, delay ?? pollRefreshSeconds)
        let retrySleep = waitRetrySleep
        Task { [weak self] in
            do {
                try await retrySleep(retryDelay)
            } catch {
                return
            }
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
        await emitSnapshot(deviceID: deviceID, snapshot: snapshot, trigger: .waitLoop)
        ensureWaitLoop(deviceID: deviceID)
        ensureRevalidationLoop(deviceID: deviceID)
    }

    private func handleAppLinkState(_ state: AppLinkState) async {
        let defaultLinkDeviceIDs = devices.keys.sorted().filter(usesDefaultAppLink)
        switch state {
        case .disconnected, .reconnecting:
            for deviceID in defaultLinkDeviceIDs {
                cancelWaitTask(deviceID: deviceID)
                logger.notice(
                    "observation event=paired_link_recovery outcome=reconnecting device_id=\(boundedLogIdentifier(deviceID))"
                )
                scheduleWaitLoopRetry(deviceID: deviceID)
            }
        case let .closing(reason, message):
            for deviceID in devices.keys.sorted() {
                cancelWaitTask(deviceID: deviceID)
                await emitChannelClosing(
                    deviceID: deviceID,
                    reason: reason,
                    message: message ?? "The RepoPrompt app MCP channel is closing."
                )
            }
        case .connected, .reconnected:
            for deviceID in defaultLinkDeviceIDs {
                logger.notice(
                    "observation event=paired_link_recovery outcome=recovered device_id=\(boundedLogIdentifier(deviceID))"
                )
                await pollCatchUp(deviceID: deviceID)
            }
        case .failed:
            for deviceID in defaultLinkDeviceIDs {
                cancelWaitTask(deviceID: deviceID)
                await emitChannelClosing(
                    deviceID: deviceID,
                    reason: "app_link_failed",
                    message: "The app link exhausted its reconnect budget."
                )
            }
        }
    }

    private func usesDefaultAppLink(_ deviceID: String) -> Bool {
        deviceID == RemoteGatewayRuntime.phase0DeviceID || !deviceID.hasPrefix("remote:")
    }

    private func poll(deviceID: String, sessionIDs: [String]) async throws -> [RemoteSessionSnapshot] {
        let value = try await callAgentRunPoll(deviceID: deviceID, sessionIDs: sessionIDs)
        return RemoteSessionSnapshot.extractSnapshots(from: value)
    }

    private enum WaitPartitionResult: Equatable {
        case snapshots
        case retryScheduled
        case rearmImmediately
    }

    private struct SessionWindowPartition {
        let windowID: Int?
        let sessionTokens: [String: UUID]

        var sessionIDs: [String] {
            sessionTokens.keys.sorted()
        }
    }

    private enum WaitGroupOutcome {
        case success(sessionTokens: [String: UUID], payload: JSONValue)
        case failure(sessionTokens: [String: UUID], reason: RemoteObservationFailureReason)
    }

    private func waitAndHandlePartitions(
        deviceID: String,
        sessionIDs: [String],
        taskID: UUID,
        includeStatusUpdates: Bool
    ) async throws -> WaitPartitionResult {
        let partitions = await partitions(deviceID: deviceID, sessionIDs: sessionIDs)
        guard !partitions.isEmpty else { return .rearmImmediately }
        let cycleSessionTokens = partitions.reduce(into: [String: UUID]()) { tokens, partition in
            tokens.merge(partition.sessionTokens) { current, _ in current }
        }
        let cycleID = beginWaitCycle(
            deviceID: deviceID,
            taskID: taskID,
            sessionTokens: cycleSessionTokens
        )
        defer { endWaitCycle(deviceID: deviceID, cycleID: cycleID) }
        var sawMatchedSnapshot = false
        var retryScheduled = false
        var shouldRearmImmediately = false

        await withTaskGroup(of: WaitGroupOutcome.self) { group in
            for partition in partitions {
                group.addTask {
                    do {
                        let payload = try await self.callAgentRunWaitPartition(
                            deviceID: deviceID,
                            sessionIDs: partition.sessionIDs,
                            windowID: partition.windowID,
                            includeStatusUpdates: includeStatusUpdates
                        )
                        return .success(sessionTokens: partition.sessionTokens, payload: payload)
                    } catch {
                        return await .failure(
                            sessionTokens: partition.sessionTokens,
                            reason: self.observationFailureReason(for: error)
                        )
                    }
                }
            }

            while let outcome = await group.next() {
                guard devices[deviceID]?.waitTaskID == taskID else {
                    group.cancelAll()
                    return
                }
                switch outcome {
                case let .success(sessionTokens, payload):
                    let snapshots = RemoteSessionSnapshot.extractSnapshots(from: payload)
                    let tokensByMatchKey = sessionTokens.keys.sorted().reduce(
                        into: [String: [(sessionID: String, token: UUID)]]()
                    ) { lookup, sessionID in
                        guard let token = sessionTokens[sessionID] else { return }
                        lookup[canonicalSessionMatchKey(sessionID), default: []].append((sessionID, token))
                    }
                    var matchedCurrentCount = 0
                    for snapshot in snapshots {
                        let matchKey = canonicalSessionMatchKey(snapshot.sessionID)
                        guard let matches = tokensByMatchKey[matchKey] else { continue }
                        for match in matches {
                            guard currentSubscriptionToken(
                                deviceID: deviceID,
                                sessionID: match.sessionID,
                                expected: match.token
                            ) != nil else { continue }
                            var subscribedSnapshot = snapshot
                            if subscribedSnapshot.sessionID != match.sessionID {
                                var rewrittenPayload = subscribedSnapshot.payload.objectValue ?? [:]
                                rewrittenPayload["session_id"] = .string(match.sessionID)
                                subscribedSnapshot = RemoteSessionSnapshot(
                                    sessionID: match.sessionID,
                                    status: subscribedSnapshot.status,
                                    payload: .object(rewrittenPayload)
                                )
                            }
                            matchedCurrentCount += 1
                            clearObservationHealthAfterSuccess(
                                deviceID: deviceID,
                                sessionID: match.sessionID,
                                token: match.token
                            )
                            await handleWaitSnapshot(deviceID: deviceID, snapshot: subscribedSnapshot)
                        }
                    }
                    if matchedCurrentCount > 0 {
                        sawMatchedSnapshot = true
                        logger.debug(
                            "watch_accountability event=wait_disposition outcome=accepted device_id=\(boundedLogIdentifier(deviceID)) correlation_id=\(boundedLogIdentifier(cycleID.uuidString))"
                        )
                    } else {
                        retryScheduled = true
                        let returnedRowCount = payload.objectValue?["snapshots"]?.arrayValue?.count
                            ?? (payload.objectValue == nil ? 0 : 1)
                        let disposition = returnedRowCount == 0 ? "empty" : "rejected"
                        logger.notice(
                            "watch_accountability event=wait_disposition outcome=\(disposition) reason=invalid_snapshot device_id=\(boundedLogIdentifier(deviceID)) correlation_id=\(boundedLogIdentifier(cycleID.uuidString))"
                        )
                        for sessionID in sessionTokens.keys.sorted() {
                            guard let token = sessionTokens[sessionID] else { continue }
                            await pauseObservation(
                                deviceID: deviceID,
                                sessionID: sessionID,
                                token: token,
                                reason: .invalidSnapshot
                            )
                        }
                    }
                case let .failure(sessionTokens, reason):
                    shouldRearmImmediately = true
                    for (sessionID, token) in sessionTokens {
                        await pauseObservation(
                            deviceID: deviceID,
                            sessionID: sessionID,
                            token: token,
                            reason: reason
                        )
                    }
                }
            }
        }

        if shouldRearmImmediately {
            return .rearmImmediately
        }
        if retryScheduled {
            return .retryScheduled
        }
        return sawMatchedSnapshot ? .snapshots : .rearmImmediately
    }

    private func callAgentRunPoll(deviceID: String, sessionIDs: [String]) async throws -> JSONValue {
        let partitions = await partitions(deviceID: deviceID, sessionIDs: sessionIDs)
        guard !partitions.isEmpty else {
            throw SessionWatchError.observationFailure(.routingUnavailable)
        }
        if partitions.count == 1 {
            return try await callAgentRunPollPartition(
                deviceID: deviceID,
                sessionIDs: partitions[0].sessionIDs,
                windowID: partitions[0].windowID
            )
        }
        var snapshots: [JSONValue] = []
        for partition in partitions {
            let payload = try await callAgentRunPollPartition(
                deviceID: deviceID,
                sessionIDs: partition.sessionIDs,
                windowID: partition.windowID
            )
            snapshots.append(contentsOf: RemoteSessionSnapshot.extractSnapshots(from: payload).map(\.payload))
        }
        return .object(["snapshots": .array(snapshots)])
    }

    private func callAgentRunPollPartition(deviceID: String, sessionIDs: [String], windowID: Int?) async throws -> JSONValue {
        let args = agentRunSessionArgs(op: "poll", sessionIDs: sessionIDs, windowID: windowID)
        logger.debug(
            "observation event=issue operation=poll device_id=\(boundedLogIdentifier(deviceID)) session_count=\(sessionIDs.count) window_id=\(windowID.map(String.init) ?? "none")"
        )
        var didLogReturn = false
        do {
            let result = try await appLink(forDevice: deviceID).callTool(name: "agent_run", arguments: args, timeout: 15)
            let payload: JSONValue
            do {
                payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
            } catch {
                throw SessionWatchError.observationFailure(.invalidSnapshot)
            }
            let outcome = result.isError == true ? "tool_error" : "success"
            logger.debug(
                "observation event=return operation=poll device_id=\(boundedLogIdentifier(deviceID)) session_count=\(sessionIDs.count) window_id=\(windowID.map(String.init) ?? "none") outcome=\(outcome)"
            )
            didLogReturn = true
            if result.isError == true {
                throw SessionWatchError.observationFailure(Self.toolFailureReason(from: payload))
            }
            return payload
        } catch {
            if !didLogReturn {
                logger.debug(
                    "observation event=return operation=poll device_id=\(boundedLogIdentifier(deviceID)) session_count=\(sessionIDs.count) window_id=\(windowID.map(String.init) ?? "none") outcome=error"
                )
            }
            throw error
        }
    }

    private func callAgentRunWait(
        deviceID: String,
        sessionIDs: [String],
        includeStatusUpdates: Bool = false
    ) async throws -> JSONValue {
        let partitions = await partitions(deviceID: deviceID, sessionIDs: sessionIDs)
        guard !partitions.isEmpty else {
            throw SessionWatchError.observationFailure(.routingUnavailable)
        }
        if partitions.count == 1 {
            return try await callAgentRunWaitPartition(
                deviceID: deviceID,
                sessionIDs: partitions[0].sessionIDs,
                windowID: partitions[0].windowID,
                includeStatusUpdates: includeStatusUpdates
            )
        }
        var snapshots: [JSONValue] = []
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for partition in partitions {
                group.addTask {
                    try await self.callAgentRunWaitPartition(
                        deviceID: deviceID,
                        sessionIDs: partition.sessionIDs,
                        windowID: partition.windowID,
                        includeStatusUpdates: includeStatusUpdates
                    )
                }
            }
            for try await payload in group {
                snapshots.append(contentsOf: RemoteSessionSnapshot.extractSnapshots(from: payload).map(\.payload))
            }
        }
        return .object(["snapshots": .array(snapshots)])
    }

    private func callAgentRunWaitPartition(
        deviceID: String,
        sessionIDs: [String],
        windowID: Int?,
        includeStatusUpdates: Bool
    ) async throws -> JSONValue {
        var args = agentRunSessionArgs(op: "wait", sessionIDs: sessionIDs, windowID: windowID)
        args["timeout"] = .double(waitTimeoutSeconds)
        if includeStatusUpdates {
            args["include_status_updates"] = .bool(true)
        }
        logger.debug(
            "observation event=issue operation=wait device_id=\(boundedLogIdentifier(deviceID)) session_count=\(sessionIDs.count) window_id=\(windowID.map(String.init) ?? "none")"
        )
        let result = try await appLink(forDevice: deviceID)
            .callTool(name: "agent_run", arguments: args, timeout: waitTimeoutSeconds + 5)
        let payload: JSONValue
        do {
            payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
        } catch {
            throw SessionWatchError.observationFailure(.invalidSnapshot)
        }
        logger.debug(
            "observation event=return operation=wait device_id=\(boundedLogIdentifier(deviceID)) session_count=\(sessionIDs.count) window_id=\(windowID.map(String.init) ?? "none") outcome=\(result.isError == true ? "tool_error" : "success")"
        )
        if result.isError == true {
            throw SessionWatchError.observationFailure(Self.toolFailureReason(from: payload))
        }
        return payload
    }

    private func partitions(deviceID: String, sessionIDs: [String]) async -> [SessionWindowPartition] {
        guard let windowResolver else {
            let tokens = Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { sessionID in
                currentSubscriptionToken(deviceID: deviceID, sessionID: sessionID, expected: nil)
                    .map { (sessionID, $0) }
            })
            return tokens.isEmpty ? [] : [SessionWindowPartition(windowID: nil, sessionTokens: tokens)]
        }
        var byWindow: [Int: [String: UUID]] = [:]
        for sessionID in sessionIDs {
            guard let token = currentSubscriptionToken(
                deviceID: deviceID,
                sessionID: sessionID,
                expected: nil
            ) else { continue }
            if let windowID = await windowResolver(deviceID, sessionID) {
                byWindow[windowID, default: [:]][sessionID] = token
            } else {
                scheduleRoutingRecovery(
                    deviceID: deviceID,
                    sessionID: sessionID,
                    token: token,
                    invalidate: false
                )
            }
        }
        return byWindow.keys.sorted().map {
            SessionWindowPartition(windowID: $0, sessionTokens: byWindow[$0] ?? [:])
        }
    }

    private func agentRunSessionArgs(op: String, sessionIDs: [String], windowID: Int?) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string(op),
            "_rawJSON": .bool(true)
        ]
        if sessionIDs.count == 1 {
            args["session_id"] = .string(sessionIDs[0])
        } else {
            args["session_ids"] = .array(sessionIDs.map(Value.string))
        }
        if let windowID {
            args["_windowID"] = .int(windowID)
        }
        return args
    }

    private static func toolFailureReason(from payload: JSONValue) -> RemoteObservationFailureReason {
        let object = payload.objectValue
        let code = object?["code"]?.stringValue?.lowercased() ?? ""
        let category = object?["error"]?.stringValue?.lowercased()
            ?? object?["message"]?.stringValue?.lowercased()
            ?? ""
        let routingCodes = ["binding_required", "ambiguous_start_target"]
        if routingCodes.contains(code)
            || category.contains("binding_required")
            || category.contains("multiple window")
            || category.contains("window-only")
            || category.contains("bound to the target window")
        {
            return .routingUnavailable
        }
        return .toolFailure
    }

    private func emitSnapshot(
        deviceID: String,
        snapshot: RemoteSessionSnapshot,
        trigger: EmissionTrigger,
        catchUpSink: CatchUpSink? = nil
    ) async {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: snapshot.sessionID)
        if snapshot.isExpired {
            logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "session_expired", seq: nil)
            await emitExpired(deviceID: deviceID, sessionID: snapshot.sessionID)
            return
        }

        if !snapshot.isTerminal {
            if pendingTerminalQuarantineByDeviceSession[key] != nil {
                cancelPendingTerminalQuarantine(deviceID: deviceID, sessionID: snapshot.sessionID)
                logEmission(
                    deviceID: deviceID,
                    sessionID: snapshot.sessionID,
                    trigger: trigger,
                    status: snapshot.status,
                    type: "held",
                    seq: nil,
                    suffix: " reason=quarantine_superseded"
                )
            }
            guard recordNonTerminalObservation(deviceID: deviceID, snapshot: snapshot) else {
                logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "suppressed", seq: nil, suffix: " reason=unwatched")
                return
            }
            await emitInteractionResolvedIfNeeded(deviceID: deviceID, snapshot: snapshot)
            let seq = nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID)
            let frame = RemoteServerFrame(
                type: "session_update",
                sessionID: snapshot.sessionID,
                seq: seq,
                seqEpoch: sequenceEpoch,
                payload: snapshot.payload
            )
            await broadcast(frame, deviceID: deviceID)
            lastEmittedIsTerminalByDeviceSession[key] = false
            // A stale terminal fingerprint across an active interlude is harmless:
            // the next terminal takes the fresh-emission path and overwrites it.
            logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "session_update", seq: seq)
            await maybePushWake(deviceID: deviceID, snapshot: snapshot)
            return
        }

        guard recordTerminalObservation(deviceID: deviceID, sessionID: snapshot.sessionID) else {
            logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "suppressed", seq: nil, suffix: " reason=unwatched")
            return
        }

        if pendingTerminalQuarantineByDeviceSession[key] != nil {
            logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "held", seq: nil, suffix: " reason=quarantine_pending")
            return
        }

        let quarantineEnabled = terminalQuarantineSeconds > 0
        if snapshot.status == "completed",
           quarantineEnabled,
           trigger != .quarantine,
           lastEmittedIsTerminalByDeviceSession[key] != true
        {
            if holdCompletedTerminalForQuarantine(deviceID: deviceID, snapshot: snapshot, trigger: trigger) {
                return
            }
        }

        if lastEmittedIsTerminalByDeviceSession[key] == true {
            let fingerprint = terminalFingerprint(from: snapshot)
            if evaluateTerminalReemitAdoptingBaseline(forKey: key, newFingerprint: fingerprint) {
                await emitInteractionResolvedIfNeeded(deviceID: deviceID, snapshot: snapshot)
                let seq = nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID)
                let frame = RemoteServerFrame(
                    type: "session_terminal",
                    sessionID: snapshot.sessionID,
                    seq: seq,
                    seqEpoch: sequenceEpoch,
                    payload: snapshot.payload
                )
                await broadcast(frame, deviceID: deviceID)
                logEmission(
                    deviceID: deviceID,
                    sessionID: snapshot.sessionID,
                    trigger: trigger,
                    status: snapshot.status,
                    type: "session_terminal",
                    seq: seq,
                    suffix: " reason=fingerprint_changed"
                )
                // Changed terminal content is a fresh wake-worthy transition; clear push dedupe.
                lastPushKindByDeviceSession.removeValue(forKey: key)
                await maybePushWake(deviceID: deviceID, snapshot: snapshot)
                return
            }
            if let catchUpSink {
                let seq = nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID)
                let frame = RemoteServerFrame(
                    type: "session_terminal",
                    sessionID: snapshot.sessionID,
                    seq: seq,
                    seqEpoch: sequenceEpoch,
                    payload: snapshot.payload
                )
                await catchUpSink.sink.send(frame)
                logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "targeted_catchup", seq: seq)
            } else {
                logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "suppressed", seq: nil, suffix: " suppressed=true")
            }
            return
        }

        await emitInteractionResolvedIfNeeded(deviceID: deviceID, snapshot: snapshot)
        let seq = nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID)
        let frame = RemoteServerFrame(
            type: "session_terminal",
            sessionID: snapshot.sessionID,
            seq: seq,
            seqEpoch: sequenceEpoch,
            payload: snapshot.payload
        )
        await broadcast(frame, deviceID: deviceID)
        lastEmittedIsTerminalByDeviceSession[key] = true
        lastEmittedTerminalFingerprintByDeviceSession[key] = terminalFingerprint(from: snapshot)
        logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "session_terminal", seq: seq)
        await maybePushWake(deviceID: deviceID, snapshot: snapshot)
    }

    private func terminalFingerprint(from snapshot: RemoteSessionSnapshot) -> TerminalFingerprint {
        let object = snapshot.payload.objectValue
        let countValue = object?["transcript_item_count"]
        let transcriptItemCount: Int? = if let intValue = countValue?.intValue {
            intValue
        } else if case let .double(doubleValue)? = countValue,
                  doubleValue.isFinite,
                  let truncatedValue = Int(exactly: doubleValue.rounded(.towardZero))
        {
            truncatedValue
        } else {
            nil
        }
        return TerminalFingerprint(
            transcriptItemCount: transcriptItemCount,
            updatedAt: object?["updated_at"]?.stringValue
        )
    }

    /// Evaluates whether a terminal snapshot should re-emit, adopting the
    /// first non-empty fingerprint as a silent baseline and merging newly available
    /// components into stored state without forgetting absent components.
    private func evaluateTerminalReemitAdoptingBaseline(
        forKey key: String,
        newFingerprint: TerminalFingerprint
    ) -> Bool {
        guard !newFingerprint.isEmpty else { return false }
        guard let storedFingerprint = lastEmittedTerminalFingerprintByDeviceSession[key],
              !storedFingerprint.isEmpty
        else {
            lastEmittedTerminalFingerprintByDeviceSession[key] = newFingerprint
            return false
        }
        let transcriptItemCountChanged = storedFingerprint.transcriptItemCount
            .flatMap { storedCount in
                newFingerprint.transcriptItemCount.map { $0 != storedCount }
            } ?? false
        let updatedAtChanged = storedFingerprint.updatedAt
            .flatMap { storedUpdatedAt in
                newFingerprint.updatedAt.map { $0 != storedUpdatedAt }
            } ?? false
        let mergedFingerprint = TerminalFingerprint(
            transcriptItemCount: newFingerprint.transcriptItemCount ?? storedFingerprint.transcriptItemCount,
            updatedAt: newFingerprint.updatedAt ?? storedFingerprint.updatedAt
        )
        lastEmittedTerminalFingerprintByDeviceSession[key] = mergedFingerprint
        return transcriptItemCountChanged || updatedAtChanged
    }

    private func recordNonTerminalObservation(deviceID: String, snapshot: RemoteSessionSnapshot) -> Bool {
        guard var state = devices[deviceID], state.watchedSessionIDs.contains(snapshot.sessionID) else { return false }
        state.parkedTerminalSessionIDs.remove(snapshot.sessionID)
        if snapshot.isActionable {
            state.activeWaitSessionIDs.remove(snapshot.sessionID)
            state.parkedActionableSessionIDs.insert(snapshot.sessionID)
        } else {
            state.activeWaitSessionIDs.insert(snapshot.sessionID)
            unparkOnExitFromActionable(state: &state, deviceID: deviceID, sessionID: snapshot.sessionID)
        }
        devices[deviceID] = state
        return true
    }

    private func recordTerminalObservation(deviceID: String, sessionID: String) -> Bool {
        guard var state = devices[deviceID] else { return true }
        guard state.watchedSessionIDs.contains(sessionID) else { return false }
        state.activeWaitSessionIDs.remove(sessionID)
        state.parkedActionableSessionIDs.remove(sessionID)
        state.parkedTerminalSessionIDs.insert(sessionID)
        devices[deviceID] = state
        return true
    }

    private func holdCompletedTerminalForQuarantine(deviceID: String, snapshot: RemoteSessionSnapshot, trigger: EmissionTrigger) -> Bool {
        guard var state = devices[deviceID] else {
            logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "held", seq: nil, suffix: " reason=device_missing_fallthrough")
            return false
        }
        state.activeWaitSessionIDs.remove(snapshot.sessionID)
        state.parkedActionableSessionIDs.remove(snapshot.sessionID)
        state.parkedTerminalSessionIDs.remove(snapshot.sessionID)
        devices[deviceID] = state

        let key = deviceSessionKey(deviceID: deviceID, sessionID: snapshot.sessionID)
        let milliseconds = Int64((terminalQuarantineSeconds * 1000).rounded(.up))
        let quarantineID = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            await self?.resolveTerminalQuarantine(
                deviceID: deviceID,
                sessionID: snapshot.sessionID,
                quarantineID: quarantineID
            )
        }
        pendingTerminalQuarantineByDeviceSession[key] = QuarantinedTerminal(id: quarantineID, snapshot: snapshot, task: task)
        logEmission(deviceID: deviceID, sessionID: snapshot.sessionID, trigger: trigger, status: snapshot.status, type: "held", seq: nil)
        return true
    }

    /// Confirms or supersedes a quarantined completed terminal after the hold
    /// window. The map entry intentionally stays present across the
    /// confirm-poll suspension and every emission is fenced on the quarantine
    /// identity: a steer/respond `rearm` (or any supersession) that clears or
    /// replaces the entry mid-await suppresses the stale pre-mutation
    /// `completed` snapshot instead of emitting it after the new run has
    /// started. Fork-staged sessions reach this path deterministically now
    /// that unregistered live sessions project as `completed` instead of
    /// expired, so a first steer inside the hold window must invalidate here.
    private func resolveTerminalQuarantine(deviceID: String, sessionID: String, quarantineID: UUID) async {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        guard let quarantine = pendingTerminalQuarantineByDeviceSession[key],
              quarantine.id == quarantineID
        else { return }
        guard devices[deviceID]?.watchedSessionIDs.contains(sessionID) == true else {
            pendingTerminalQuarantineByDeviceSession.removeValue(forKey: key)
            logEmission(deviceID: deviceID, sessionID: sessionID, trigger: .quarantine, status: quarantine.snapshot.status, type: "suppressed", seq: nil, suffix: " reason=unwatched")
            return
        }
        defer {
            ensureWaitLoop(deviceID: deviceID)
            ensureRevalidationLoop(deviceID: deviceID)
        }
        var confirmed: RemoteSessionSnapshot?
        var confirmFailed = false
        do {
            confirmed = try await poll(deviceID: deviceID, sessionIDs: [sessionID]).first
        } catch {
            confirmFailed = true
        }
        guard pendingTerminalQuarantineByDeviceSession[key]?.id == quarantineID else {
            logEmission(deviceID: deviceID, sessionID: sessionID, trigger: .quarantine, status: quarantine.snapshot.status, type: "suppressed", seq: nil, suffix: " reason=quarantine_superseded")
            return
        }
        pendingTerminalQuarantineByDeviceSession.removeValue(forKey: key)
        guard let confirmed else {
            let reason = confirmFailed ? "confirm_poll_failed" : "confirm_poll_missing"
            logEmission(deviceID: deviceID, sessionID: sessionID, trigger: .quarantine, status: quarantine.snapshot.status, type: "held", seq: nil, suffix: " reason=\(reason)")
            await emitSnapshot(deviceID: deviceID, snapshot: quarantine.snapshot, trigger: .quarantine)
            return
        }
        await emitSnapshot(deviceID: deviceID, snapshot: confirmed, trigger: .quarantine)
    }

    private func cancelPendingTerminalQuarantine(deviceID: String, sessionID: String) {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        if let quarantine = pendingTerminalQuarantineByDeviceSession.removeValue(forKey: key) {
            quarantine.task.cancel()
        }
    }

    private func clearTerminalObservationState(deviceID: String, sessionID: String) {
        let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
        lastEmittedIsTerminalByDeviceSession.removeValue(forKey: key)
        lastEmittedTerminalFingerprintByDeviceSession.removeValue(forKey: key)
        cancelPendingTerminalQuarantine(deviceID: deviceID, sessionID: sessionID)
    }

    private func logEmission(
        deviceID: String,
        sessionID: String,
        trigger: EmissionTrigger,
        status _: String,
        type: String,
        seq: UInt64?,
        suffix _: String = ""
    ) {
        let outcome = ["held", "suppressed"].contains(type) ? type : "emitted"
        logger.debug(
            "watch_accountability event=snapshot_emission outcome=\(outcome) device_id=\(boundedLogIdentifier(deviceID)) session_id=\(boundedLogIdentifier(sessionID)) frame_type=\(type) seq=\(seq.map(String.init) ?? "-") seq_epoch=\(boundedLogIdentifier(sequenceEpoch)) trigger=\(trigger.rawValue)"
        )
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
            seqEpoch: sequenceEpoch,
            payload: .object(payload)
        )
        await broadcast(frame, deviceID: deviceID)
    }

    private func emitExpired(deviceID: String, sessionID: String) async {
        if var state = devices[deviceID] {
            state.watchedSessionIDs.remove(sessionID)
            state.subscriptionTokenBySessionID.removeValue(forKey: sessionID)
            state.activeWaitSessionIDs.remove(sessionID)
            state.parkedActionableSessionIDs.remove(sessionID)
            state.parkedTerminalSessionIDs.remove(sessionID)
            clearTerminalObservationState(deviceID: deviceID, sessionID: sessionID)
            clearObservationHealth(deviceID: deviceID, sessionID: sessionID)
            devices[deviceID] = state
            ensureWaitLoop(deviceID: deviceID)
            ensureRevalidationLoop(deviceID: deviceID)
        }
        lastPushKindByDeviceSession.removeValue(forKey: deviceSessionKey(deviceID: deviceID, sessionID: sessionID))
        lastResolutionKeyByDeviceSession.removeValue(forKey: deviceSessionKey(deviceID: deviceID, sessionID: sessionID))
        let frame = RemoteServerFrame(
            type: "session_expired",
            sessionID: sessionID,
            seq: nextSeq(deviceID: deviceID, sessionID: sessionID),
            seqEpoch: sequenceEpoch,
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

    #if DEBUG
        func debugTerminalState(deviceID: String, sessionID: String) -> (
            watched: Bool,
            activeWait: Bool,
            parkedTerminal: Bool,
            pendingQuarantine: Bool,
            lastEmittedIsTerminal: Bool?,
            lastEmittedTerminalTranscriptItemCount: Int?,
            lastEmittedTerminalUpdatedAt: String?
        ) {
            let state = devices[deviceID]
            let key = deviceSessionKey(deviceID: deviceID, sessionID: sessionID)
            return (
                watched: state?.watchedSessionIDs.contains(sessionID) ?? false,
                activeWait: state?.activeWaitSessionIDs.contains(sessionID) ?? false,
                parkedTerminal: state?.parkedTerminalSessionIDs.contains(sessionID) ?? false,
                pendingQuarantine: pendingTerminalQuarantineByDeviceSession[key] != nil,
                lastEmittedIsTerminal: lastEmittedIsTerminalByDeviceSession[key],
                lastEmittedTerminalTranscriptItemCount: lastEmittedTerminalFingerprintByDeviceSession[key]?.transcriptItemCount,
                lastEmittedTerminalUpdatedAt: lastEmittedTerminalFingerprintByDeviceSession[key]?.updatedAt
            )
        }
    #endif
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
