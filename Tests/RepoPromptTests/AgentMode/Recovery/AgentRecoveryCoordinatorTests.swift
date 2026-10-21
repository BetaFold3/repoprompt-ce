@testable import RepoPromptAgentCore
import XCTest

/// Recovery composition (lossless restart Phase 1b, inactive in production): the coordinator, its
/// startup barrier and launch mark, crash holds, one lane per durable session, restore-before-edits,
/// and explicit held-composer resolution. Every store, DataService, tombstone root, and workspace is
/// an injected temporary directory behind the real `AgentSessionDataService` gate.
@MainActor
final class AgentRecoveryCoordinatorTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private struct Workspace: AgentWorkspaceStorageReference {
        let id = UUID()
        let name = "Recovery Coordinator"
        let customStoragePath: URL?
    }

    private final class Owner {}

    /// Controllable reconciliation step: optionally fails, optionally suspends until released.
    @MainActor
    private final class ReconcileProbe {
        var failure: Error?
        var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        var suspends = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var arrived = false

        func run(_: AgentRecoveryStartupReport) async throws {
            calls += 1
            if suspends {
                arrived = true
                arrival?.resume()
                arrival = nil
                await withCheckedContinuation { gate = $0 }
            }
            if let failure { throw failure }
        }

        func waitUntilSuspended() async {
            guard !arrived else { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private struct ReconcileFailure: Error {}

    private var root: URL!
    private var recoveryRoot: URL!
    private var workspace: Workspace!
    private var failures: RecoveryStoreWriteFailureSwitch!

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryCoordinatorTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        workspace = Workspace(customStoragePath: root.appendingPathComponent("workspace", isDirectory: true))
        failures = RecoveryStoreWriteFailureSwitch()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Fixtures

    private func makeStore(instance: UUID = UUID()) -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: instance, fileOperations: failures.fileOperations())
    }

    private func makeService(store: AgentRecoveryStore) -> AgentSessionDataService {
        AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
    }

    /// Timers never fire on their own; tests flush explicitly.
    private func makeCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        probe: ReconcileProbe? = nil
    ) throws -> AgentRecoveryCoordinator {
        let probe = probe ?? ReconcileProbe()
        // The production sweep over this test's single workspace.
        let destination = AgentRecoveryWorkspaceDestination(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath
        )
        return try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { report in
                try await probe.run(report)
                return await AgentRecoveryStartupSweep.run(
                    inventory: AgentRecoveryWorkspaceInventory(workspaces: [destination]),
                    entries: report.discovered,
                    dataService: service
                )
            },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
    }

    /// Composer deadlines on a controllable clock: sleeps resume only when the test fires them, and
    /// the coordinator's first-unsaved instants use the same clock.
    private func timedCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        clock: RecoveryTestClock,
        sleeper: RecoveryManualSleeper
    ) async throws -> AgentRecoveryCoordinator {
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { try await sleeper.sleep(until: $0) },
                    clockNow: { clock.now }
                )
            },
            clockNow: { clock.now }
        )
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    @MainActor
    private final class LaneBox {
        var lane: AgentRecoverySessionLane?
    }

    private func startedCoordinator(
        store: AgentRecoveryStore,
        service: AgentSessionDataService
    ) async throws -> AgentRecoveryCoordinator {
        let coordinator = try makeCoordinator(store: store, service: service)
        coordinator.startIfNeeded()
        let state = await coordinator.awaitStartup()
        XCTAssertEqual(state, .ready)
        return coordinator
    }

    private func makeSession(_ service: AgentSessionDataService) async throws -> AgentSessionEditableLoad {
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Recovery"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
    }

    private func resetTranscript(
        _ service: AgentSessionDataService,
        _ load: AgentSessionEditableLoad
    ) async throws -> AgentSessionSaveCommit {
        try await service.saveAgentSession(
            load.session.withItems([]),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: AgentSessionTranscriptResetReceipt(id: UUID()),
            fileCreationPolicy: .requireExisting,
            persistenceState: load.persistenceState
        )
    }

    private func admission(
        _ lane: AgentRecoverySessionLane,
        _ text: String,
        origin: AgentRecoveryIntentOrigin = .mcp
    ) -> AgentRecoveryAdmission {
        AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: origin,
            target: .session,
            original: Support.content(text)
        )
    }

    private func storedComposerText(_ store: AgentRecoveryStore, _ sessionID: UUID) async -> String? {
        await store.read(sessionID: sessionID).record?.composer?.content.text
    }

    private func assertRefused(
        _ result: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>,
        _ expected: AgentRecoveryAdmissionRefusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(.refused(refusal)) = result else {
            return XCTFail("expected refusal \(expected), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(refusal, expected, file: file, line: line)
    }

    // MARK: Composition

    func testCompositionRejectsDataServiceBackedByAnotherStore() throws {
        let store = makeStore()
        let other = AgentRecoveryStore(rootURL: root.appendingPathComponent("other/v1", isDirectory: true))
        XCTAssertThrowsError(try makeCoordinator(store: store, service: makeService(store: other))) { error in
            XCTAssertEqual(error as? AgentRecoveryCompositionError, .dataServiceStoreMismatch)
        }
        XCTAssertThrowsError(try makeCoordinator(store: store, service: AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true)
        )))
    }

    // MARK: Startup barrier and launch state

    func testAdmissionStaysClosedUntilStartupIsReady() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.suspends = true
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)

        // Never started: closed, nothing written.
        let early = await lane.admitQueued(admission(lane, "early"))
        assertRefused(early, .startupNotReady)
        let beforeStart = await store.read(sessionID: load.session.id)
        XCTAssertEqual(beforeStart, .absent)

        coordinator.startIfNeeded()
        await probe.waitUntilSuspended()
        XCTAssertEqual(coordinator.startupState, .loading)
        let pending = Task { await lane.admitQueued(self.admission(lane, "waits for barrier")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let whileLoading = await store.read(sessionID: load.session.id)
        XCTAssertEqual(whileLoading, .absent, "admission waits on the startup barrier")
        probe.release()
        guard case let .success(admitted) = await pending.value else {
            return XCTFail("admission should open once startup is ready")
        }
        XCTAssertEqual(admitted.receipt.intent.deliveryState, .queued)
        XCTAssertNil(admitted.submittedComposerRevision)
    }

    func testReconciliationFailureKeepsAdmissionClosedUntilRetrySucceeds() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.failure = ReconcileFailure()
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        coordinator.startIfNeeded()
        guard case .failed = await coordinator.awaitStartup() else {
            return XCTFail("reconciliation failure must fail startup")
        }
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let refused = await lane.admitQueued(admission(lane, "refused"))
        guard case .failure(.refused(.startupFailed)) = refused else {
            return XCTFail("expected startupFailed, got \(refused)")
        }
        let afterFailure = await store.read(sessionID: load.session.id)
        XCTAssertEqual(afterFailure, .absent)

        probe.failure = nil
        coordinator.retryStartup()
        let retried = await coordinator.awaitStartup()
        XCTAssertEqual(retried, .ready)
        XCTAssertEqual(probe.calls, 2)
        guard case .success = await lane.admitQueued(admission(lane, "after retry")) else {
            return XCTFail("admission opens after a successful retry")
        }
    }

    func testUnwritableLaunchMarkFailsStartupClosed() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        failures.shouldFailWrites = true
        let coordinator = try makeCoordinator(store: store, service: service)
        coordinator.startIfNeeded()
        guard case .failed = await coordinator.awaitStartup() else {
            return XCTFail("an unwritable launch mark must fail startup")
        }
        failures.shouldFailWrites = false
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let refused = await lane.admitQueued(admission(lane, "refused"))
        guard case .failure(.refused(.startupFailed)) = refused else {
            return XCTFail("expected startupFailed, got \(refused)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.launchStateFileURL.path))
        let record = await store.read(sessionID: load.session.id)
        XCTAssertEqual(record, .absent)
    }

    func testPreviousLaunchMarkIsReadBeforeReplacementAndClassifiedUnclean() async throws {
        let previousInstance = UUID()
        let previousStore = makeStore(instance: previousInstance)
        _ = try await previousStore.recordCurrentLaunchRunning()

        let currentInstance = UUID()
        let store = makeStore(instance: currentInstance)
        let coordinator = try await startedCoordinator(store: store, service: makeService(store: store))
        let report = try XCTUnwrap(coordinator.startupReport)
        guard case let .mark(previous) = report.previousLaunch else {
            return XCTFail("expected the previous mark, got \(report.previousLaunch)")
        }
        XCTAssertEqual(previous.appInstanceID, previousInstance)
        XCTAssertEqual(previous.state, .running)
        XCTAssertFalse(report.previousLaunch.provesCleanExit(currentInstanceID: currentInstance))
        XCTAssertEqual(report.currentLaunch.appInstanceID, currentInstance)
        XCTAssertEqual(report.currentLaunch.state, .running)
        let onDisk = await store.readLaunchMark()
        XCTAssertEqual(onDisk, .mark(report.currentLaunch), "this launch's unclean mark replaced the previous one")
    }

    func testMissingOrUnreadableLaunchMarkIsConservativelyUnclean() async throws {
        let instance = UUID()
        let store = makeStore(instance: instance)
        let missing = await store.readLaunchMark()
        XCTAssertEqual(missing, .none)
        XCTAssertFalse(missing.provesCleanExit(currentInstanceID: instance))

        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":2}".utf8).write(to: store.launchStateFileURL)
        let unreadable = await store.readLaunchMark()
        guard case .unreadable = unreadable else {
            return XCTFail("future or malformed marks are unreadable, got \(unreadable)")
        }
        XCTAssertFalse(unreadable.provesCleanExit(currentInstanceID: instance))
    }

    // MARK: Crash holds

    func testPreviousInstanceOpenEvidenceHoldsAdmissionUntilExplicitConfirmation() async throws {
        let previousStore = makeStore(instance: UUID())
        let previousService = makeService(store: previousStore)
        let load = try await makeSession(previousService)
        let previousGate = try previousService.recoveryLifecycleGate(for: load.persistenceState)
        let ownership = Support.ownership(sessionID: load.session.id)
        let submission = Support.submission("in flight at crash")
        let attemptID = UUID()
        try await previousGate.performRecoveryTransaction {
            _ = try await previousStore.ensureRunAttempt(
                binding: previousGate.binding, expectedRevision: nil, ownership: ownership,
                processRunID: nil, transcriptTurnID: nil
            )
            _ = try await previousStore.commitDispatchingIntent(
                binding: previousGate.binding,
                expectedRevision: previousStore.currentRevision(sessionID: load.session.id),
                submission: submission,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: ownership.attemptID),
                consumption: nil
            )
        }

        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let hold = try XCTUnwrap(coordinator.crashHold(for: load.session.id))
        XCTAssertEqual(hold.uncertainRunAttemptIDs, [ownership.attemptID])
        XCTAssertEqual(hold.uncertainIntentIDs, [submission.intentID])
        XCTAssertFalse(hold.previousExitProvenClean)

        // After relaunch the session is reloaded through this launch's service (fresh stamp).
        let reloaded = try await service.loadAgentSessionForEditing(id: load.session.id, for: workspace)
        let relaunchState = try XCTUnwrap(reloaded?.persistenceState)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: relaunchState)
        let beforeRevision = await store.read(sessionID: load.session.id).record?.revision
        let blocked = await lane.admitQueued(admission(lane, "blocked"))
        assertRefused(blocked, .crashHeld(hold))
        let dispatch = await lane.beginDispatch(
            intentID: submission.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()),
            authorization: .explicitUserAction
        )
        guard case .failure(.refused(.crashHeld)) = dispatch else {
            return XCTFail("every route checks the crash hold, got \(dispatch)")
        }
        let unchanged = await store.read(sessionID: load.session.id).record?.revision
        XCTAssertEqual(unchanged, beforeRevision, "refusals write nothing")

        let stale = AgentRecoveryCrashHold(
            sessionID: hold.sessionID,
            incarnationID: hold.incarnationID,
            transcriptResetGeneration: hold.transcriptResetGeneration,
            uncertainRunAttemptIDs: [UUID()],
            uncertainIntentIDs: hold.uncertainIntentIDs,
            previousExitProvenClean: false
        )
        let staleConfirmed = await coordinator.confirmCrashHold(stale, lane: lane)
        XCTAssertFalse(staleConfirmed, "confirmation binds the exact uncertain attempts")
        XCTAssertNotNil(coordinator.blockingCrashHold(for: lane.binding))
        let staleRecord = await store.read(sessionID: load.session.id).record
        XCTAssertNil(staleRecord?.crashHoldAcknowledgement, "A stale confirmation writes nothing")
        let holdConfirmed = await coordinator.confirmCrashHold(hold, lane: lane)
        XCTAssertTrue(holdConfirmed)
        XCTAssertNil(coordinator.blockingCrashHold(for: lane.binding))
        // F-2: the acknowledgement is durable and exact.
        let acknowledgedRead = await store.read(sessionID: load.session.id)
        let acknowledged = try XCTUnwrap(acknowledgedRead.record)
        let acknowledgement = try XCTUnwrap(acknowledged.crashHoldAcknowledgement)
        XCTAssertTrue(hold.isCovered(by: acknowledgement))
        XCTAssertEqual(acknowledgement.runAttemptIDs, [ownership.attemptID])
        XCTAssertEqual(acknowledgement.intentIDs, [submission.intentID])
        XCTAssertEqual(acknowledged.runAttempt(id: ownership.attemptID)?.terminal, nil, "No run outcome is invented")
        let confirmed = await lane.admitQueued(admission(lane, "after confirmation"))
        guard case .success = confirmed else {
            return XCTFail("admission opens after explicit confirmation, got \(confirmed)")
        }
        // Confirmation is not a retry: the uncertain intent keeps its state.
        let intent = await store.read(sessionID: load.session.id).record?.intent(id: submission.intentID)
        XCTAssertEqual(intent?.deliveryState, .dispatching)

        // A later launch with the identical uncertainty does not ask again; changed uncertainty is
        // not covered by this decision.
        let nextStore = makeStore(instance: UUID())
        let nextCoordinator = try await startedCoordinator(store: nextStore, service: makeService(store: nextStore))
        let nextHold = try XCTUnwrap(nextCoordinator.crashHold(for: load.session.id), "The evidence is still presented")
        XCTAssertEqual(nextHold.uncertainRunAttemptIDs, hold.uncertainRunAttemptIDs)
        XCTAssertEqual(nextHold.uncertainIntentIDs, hold.uncertainIntentIDs)
        XCTAssertNil(nextCoordinator.blockingCrashHold(for: lane.binding), "The identical hold stays acknowledged")
        let widened = AgentRecoveryCrashHold(
            sessionID: hold.sessionID,
            incarnationID: hold.incarnationID,
            transcriptResetGeneration: hold.transcriptResetGeneration,
            uncertainRunAttemptIDs: hold.uncertainRunAttemptIDs.union([UUID()]),
            uncertainIntentIDs: hold.uncertainIntentIDs,
            previousExitProvenClean: false
        )
        XCTAssertFalse(widened.isCovered(by: acknowledgement), "Additional uncertainty needs another confirmation")
    }

    // MARK: Lane ownership

    func testOneLanePerDurableSessionRetiresPredecessorAfterFlushingIt() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let firstOwner = Owner()
        let first = try coordinator.claimLane(owner: firstOwner, persistenceState: load.persistenceState)
        XCTAssertTrue(try coordinator.claimLane(owner: firstOwner, persistenceState: load.persistenceState) === first)
        _ = await first.restoreComposer()
        XCTAssertNotNil(first.composerDidChange(Support.content("typed by the first owner")))

        let secondOwner = Owner()
        let second = try coordinator.claimLane(owner: secondOwner, persistenceState: load.persistenceState)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isRetired, "retired synchronously before the replacement is returned")
        XCTAssertTrue(coordinator.lane(for: load.session.id) === second)
        XCTAssertNil(first.composerDidChange(Support.content("late edit")))
        let late = await first.admitQueued(admission(first, "late"))
        assertRefused(late, .laneRetired)

        // The successor restores only after the predecessor's pending composer was flushed.
        let restored = await second.restoreComposer()
        let storedComposer = await store.read(sessionID: load.session.id).record?.composer
        XCTAssertEqual(restored, .restored(storedComposer))
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "typed by the first owner")
        let flushAfterRetire = await first.flushComposer()
        XCTAssertEqual(flushAfterRetire, .nothingPending)
    }

    func testRetirementDuringBarrierAwaitRefusesWithoutWriting() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let probe = ReconcileProbe()
        probe.suspends = true
        let coordinator = try makeCoordinator(store: store, service: service, probe: probe)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        coordinator.startIfNeeded()
        await probe.waitUntilSuspended()
        let pending = Task { await first.admitQueued(self.admission(first, "target lost during await")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        _ = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        probe.release()
        let lost = await pending.value
        assertRefused(lost, .laneRetired)
        let record = await store.read(sessionID: load.session.id)
        XCTAssertEqual(record, .absent)
    }

    func testResetYieldsNewLaneAndOldGenerationLaneCannotWrite() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("old generation draft"))
        guard case .committed = await old.flushComposer() else {
            return XCTFail("the old generation draft is stored before the reset")
        }
        let reset = try await resetTranscript(service, load)
        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        XCTAssertTrue(old.isRetired)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1)
        let outcome = await fresh.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("the old-generation composer is held, got \(outcome)")
        }
        XCTAssertEqual(held.content.text, "old generation draft")
        XCTAssertEqual(fresh.composerState, .held(held))
    }

    // MARK: Unsaved input across owner replacement

    /// Fixture 1: replacement during restore. The predecessor's buffered input reaches disk before
    /// its controller retires, the successor's newer typing wins afterward, and a healthy hand-over
    /// leaves no failure entry.
    func testReplacementDuringRestoreWritesBufferedInputAndSuccessorTypingWinsAfterward() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let pendingRestore = Task { await first.restoreComposer() }
        XCTAssertNil(first.composerDidChange(Support.content("typed while restore was in flight")), "buffered")
        XCTAssertNotNil(first.bufferedFirstUnsavedAt, "the buffered input owns its first-unsaved instant")

        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(second.composerDidChange(Support.content("successor typing")), "successor buffers behind the hand-over")
        let firstRestore = await pendingRestore.value
        XCTAssertEqual(firstRestore, .failed(.retired))
        let restored = await second.restoreComposer()
        XCTAssertEqual(restored, .superseded, "the predecessor snapshot never replaces successor typing")
        XCTAssertTrue(second.unsavedPredecessorInputs.isEmpty, "a successful hand-over leaves no failure entry")
        XCTAssertTrue(first.composer.isRetired)
        XCTAssertFalse(first.composer.hasPendingChanges)
        let handedOver = await storedComposerText(store, load.session.id)
        XCTAssertEqual(handedOver, "typed while restore was in flight", "written before the predecessor retired")

        guard case .committed = await second.flushComposer() else {
            return XCTFail("the successor writes against the handed-over baseline")
        }
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "successor typing")
        guard case .success = await second.admitQueued(admission(second, "after hand-over")) else {
            return XCTFail("admission is open after a healthy hand-over")
        }
    }

    func testPredecessorFlushFailureSurvivesReplacementWithItsErrorAndKeepsSuccessorTyping() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        // A current-launch intent whose live projection was removed is presented as held input.
        guard case let .success(heldAdmission) = await first.admitQueued(admission(first, "no longer queued")) else {
            return XCTFail("admission is open")
        }
        let heldIntentID = heldAdmission.receipt.intent.intentID
        first.noteProjectionRemoved(intentIDs: [heldIntentID], reason: "its run ended")
        failures.shouldFailWrites = true
        XCTAssertNotNil(first.composerDidChange(Support.content("unsaved before replacement")))

        // Another owner (for example another window) takes the session over.
        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertEqual(second.heldIntents[heldIntentID], "its run ended", "ownership transfer never hides held input")
        let refused = await second.admitQueued(admission(second, "blocked"))
        assertRefused(refused, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(second.unsavedPredecessorInputs.first)
        XCTAssertEqual(inherited.content.text, "unsaved before replacement")
        XCTAssertEqual(inherited.binding, first.binding)
        XCTAssertNotNil(inherited.failure, "the predecessor's write failure stays visible")

        failures.shouldFailWrites = false
        _ = await second.restoreComposer()
        second.composerDidChange(Support.content("successor typing"))
        let overwrite = await second.resolveUnsavedPredecessorInput(
            .restoreToComposer,
            expected: inherited,
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(overwrite, .failure(.liveComposerHasUnsavedContent), "never overwrites successor typing")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited], "kept until resolved")
        let notDisplayed = AgentRecoveryUnsavedComposerInput(
            binding: inherited.binding,
            content: Support.content("something else"),
            failure: inherited.failure
        )
        let wrongEntry = await second.resolveUnsavedPredecessorInput(.discard, expected: notDisplayed, liveComposerIsEmpty: false)
        XCTAssertEqual(wrongEntry, .failure(.heldInputChanged), "only the exact displayed payload is discarded")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited])
        let discarded = await second.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        _ = await second.flushComposer()
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "successor typing")

        // The owner goes away with input it could not save: published with no lane (never kept
        // only inside a parked retirement), then inherited and presented by the next owner.
        failures.shouldFailWrites = true
        second.composerDidChange(Support.content("unsaved when the tab closed"))
        await coordinator.releaseLane(second).value
        XCTAssertNil(coordinator.lane(for: load.session.id))
        let ownerless = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[load.session.id])
        XCTAssertEqual(ownerless.workspaceID, workspace.id)
        XCTAssertEqual(ownerless.inputs.map(\.content.text), ["unsaved when the tab closed"])
        XCTAssertNotNil(ownerless.inputs.first?.failure, "the persistence failure stays visible")
        XCTAssertEqual(
            coordinator.heldIntents(sessionID: load.session.id, incarnationID: first.binding.incarnationID)[heldIntentID],
            "its run ended",
            "held input stays visible while no lane owns the session"
        )
        failures.shouldFailWrites = false

        let third = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[load.session.id], "the next owner presents it instead")
        _ = await third.restoreComposer()
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["unsaved when the tab closed"])
        XCTAssertEqual(third.heldIntents[heldIntentID], "its run ended", "a same-launch reclaim never hides held input")

        // Resolving the held intent (withdrawal commit) retires its presentation.
        let reclaimed = try XCTUnwrap(third.unsavedPredecessorInputs.first)
        _ = await third.resolveUnsavedPredecessorInput(.discard, expected: reclaimed, liveComposerIsEmpty: true)
        guard case .success = await third.withdraw(intentID: heldIntentID) else {
            return XCTFail("the held intent can be withdrawn")
        }
        for _ in 0 ..< 500 where third.heldIntents[heldIntentID] != nil {
            await Task.yield()
        }
        XCTAssertNil(third.heldIntents[heldIntentID], "withdrawn input needs no decision")
    }

    func testDiscardedOwnerlessInputIsNeverInheritedByTheNextOwner() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        failures.shouldFailWrites = true
        first.composerDidChange(Support.content("unsaved when the tab closed"))
        await coordinator.releaseLane(first).value
        failures.shouldFailWrites = false
        let entry = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[load.session.id]?.inputs.first)
        let stale = AgentRecoveryUnsavedComposerInput(binding: entry.binding, content: Support.content("other"), failure: nil)
        XCTAssertFalse(coordinator.discardOwnerlessUnsavedInput(sessionID: load.session.id, expected: stale))
        XCTAssertTrue(coordinator.discardOwnerlessUnsavedInput(sessionID: load.session.id, expected: entry))
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[load.session.id])

        let next = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await next.restoreComposer()
        XCTAssertTrue(next.unsavedPredecessorInputs.isEmpty, "an explicitly discarded payload never comes back")
        guard case .success = await next.admitQueued(admission(next, "after discard")) else {
            return XCTFail("admission is open after the explicit discard")
        }
    }

    func testResetKeepsOldGenerationUnsavedInputWithoutWritingItUnderEitherAuthority() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("old generation, never flushed"))
        let reset = try await resetTranscript(service, load)

        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let refused = await fresh.admitQueued(admission(fresh, "blocked"))
        assertRefused(refused, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(fresh.unsavedPredecessorInputs.first)
        XCTAssertEqual(inherited.content.text, "old generation, never flushed")
        XCTAssertEqual(inherited.binding.transcriptResetGeneration, 0)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1)
        let restored = await fresh.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        let stored = await store.read(sessionID: load.session.id).record?.composer
        XCTAssertNil(stored, "not flushed by the retired authority nor carried into the new generation")
        _ = await fresh.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: true)
        guard case .success = await fresh.admitQueued(admission(fresh, "after discard")) else {
            return XCTFail("admission reopens after explicit discard")
        }
    }

    /// Fixture 2: reset preparation. A failed preservation write vetoes the reset and keeps the
    /// input usable; a successful retry freezes admission, the reset commits once, and the written
    /// old-generation composer is held (never adopted) by the new generation.
    func testResetPreparationVetoesOnWriteFailureAndRetryResetsOnceLeavingTheOldComposerHeld() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        failures.shouldFailWrites = true
        XCTAssertNotNil(old.composerDidChange(Support.content("draft before reset")))

        let vetoed = await old.prepareForTranscriptReset()
        guard case .failure(.composerNotPersisted(.some)) = vetoed else {
            return XCTFail("a failed preservation write vetoes the reset, got \(vetoed)")
        }
        XCTAssertFalse(old.isResetPreparationActive, "a veto reopens admission")
        XCTAssertFalse(old.isRetired)
        XCTAssertEqual(old.composer.pendingContent?.text, "draft before reset", "the input stays usable")
        XCTAssertNotNil(old.composer.lastWriteFailure, "the failure stays visible")
        XCTAssertEqual(coordinator.lane(for: load.session.id)?.binding.transcriptResetGeneration, 0)

        failures.shouldFailWrites = false
        guard case .success = await old.prepareForTranscriptReset() else {
            return XCTFail("the retry preserves the composer")
        }
        XCTAssertTrue(old.isResetPreparationActive)
        let frozen = await old.admitQueued(admission(old, "during reset"))
        assertRefused(frozen, .resetPreparationInProgress)
        let preserved = await storedComposerText(store, load.session.id)
        XCTAssertEqual(preserved, "draft before reset", "written under the old generation before it advances")

        let reset = try await resetTranscript(service, load)
        let fresh = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        XCTAssertTrue(old.isRetired)
        XCTAssertEqual(fresh.binding.transcriptResetGeneration, 1, "the generation advanced exactly once")
        let outcome = await fresh.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("the preserved composer is held, never adopted, got \(outcome)")
        }
        XCTAssertEqual(held.content.text, "draft before reset")
        XCTAssertTrue(fresh.unsavedPredecessorInputs.isEmpty, "nothing is retained only in memory")
        guard case .failure(.laneRetired) = await old.prepareForTranscriptReset() else {
            return XCTFail("the committed reset is not prepared twice")
        }
    }

    /// Fixture 3: first draft with an image. Delayed creation and promotion coalesce later typing
    /// into one obligation, authority comes from normal exclusive creation, and the write is due at
    /// the original first mutation plus 2 seconds.
    func testFirstDraftWithImageCoalescesThroughDelayedCreationAndPromotionAndKeepsTheOriginalDeadline() async throws {
        let clock = RecoveryTestClock()
        let sleeper = RecoveryManualSleeper()
        let store = makeStore()
        let service = makeService(store: store)
        let coordinator = try await timedCoordinator(store: store, service: service, clock: clock, sleeper: sleeper)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let imageSource = try Support.makeImageSource(in: sources)
        let owner = Owner()
        let t0 = clock.now

        // First typing in an unsaved tab: the image is not representable yet, the obligation is not.
        let obligation = coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: nil)
        XCTAssertEqual(obligation.firstUnsavedAt, t0)
        let creation = RecoveryGateLatch()
        let box = LaneBox()
        let started = coordinator.startComposerPreparation(owner: owner) { [self] _ in
            await creation.pause()
            guard let load = try? await makeSession(service),
                  let lane = try? coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
            else { return .authorityUnavailable("creation") }
            box.lane = lane
            let image: AgentRecoveryImageReference
            do {
                image = try await store.importManagedImage(sessionID: lane.sessionID, sourceURL: imageSource)
            } catch {
                return .imagePromotionFailed(String(describing: error))
            }
            let content = Support.content("caption typed while preparing", images: [image])
            if case let .failure(failure) = coordinator.completeComposerPreparation(owner: owner, forwardingTo: lane, content: content) {
                return failure
            }
            return nil
        }
        XCTAssertTrue(started)
        await creation.waitUntilPaused()

        clock.advance(by: .milliseconds(1500))
        let coalesced = coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: nil)
        XCTAssertTrue(coalesced === obligation, "later typing joins the same obligation")
        XCTAssertEqual(coalesced.firstUnsavedAt, t0, "coalescing never moves the first-unsaved instant")
        let duplicate = coordinator.startComposerPreparation(owner: owner) { _ in
            XCTFail("one preparation per owner")
            return nil
        }
        XCTAssertFalse(duplicate)

        await creation.open()
        let preparation = try XCTUnwrap(obligation.preparationTask)
        await preparation.value
        XCTAssertNil(obligation.failure)
        XCTAssertNil(coordinator.composerPreparation(for: owner), "handed to the lane")
        let lane = try XCTUnwrap(box.lane)
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0, "buffered behind restore under the original instant")
        let record = await store.read(sessionID: lane.sessionID)
        XCTAssertNil(record.record?.composer, "not written before its deadline")

        let restored = await lane.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        XCTAssertEqual(lane.composer.maximumDelayDeadline, t0 + AgentRecoveryComposerPersistenceController.maximumDelay)
        let armed = await Support.eventually { await sleeper.pendingDeadlines.contains(t0 + AgentRecoveryComposerPersistenceController.maximumDelay) }
        XCTAssertTrue(armed, "the 2-second bound runs from the first mutation, not from preparation")
        await sleeper.fire(through: t0 + AgentRecoveryComposerPersistenceController.maximumDelay)
        let written = await Support.eventually { await self.storedComposerText(store, lane.sessionID) == "caption typed while preparing" }
        XCTAssertTrue(written)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.images.count, 1, "the promoted image is part of the snapshot")
    }

    /// Fixture 4: delayed restore and a late owner completion. The replacement's buffered typing
    /// keeps its own original deadline (written at once when overdue, no restarted bound); the late
    /// completion never adopts into the replacement and keeps its payload with a visible failure.
    func testDelayedRestoreKeepsTheDeadlineAndLateOwnerCompletionNeverAdoptsIntoTheReplacement() async throws {
        let clock = RecoveryTestClock()
        let sleeper = RecoveryManualSleeper()
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await timedCoordinator(store: store, service: service, clock: clock, sleeper: sleeper)
        let original = Owner()
        let replacement = Owner()
        let t0 = clock.now

        coordinator.recordComposerMutationAwaitingPreparation(owner: original, content: Support.content("typed by the original owner"))
        let late = RecoveryGateLatch()
        coordinator.startComposerPreparation(owner: original) { _ in
            await late.pause()
            guard let current = coordinator.lane(for: load.session.id) else { return .ownerReplaced }
            if case let .failure(failure) = coordinator.completeComposerPreparation(
                owner: original,
                forwardingTo: current,
                content: Support.content("typed by the original owner")
            ) {
                return failure
            }
            return nil
        }
        await late.waitUntilPaused()

        let lane = try coordinator.claimLane(owner: replacement, persistenceState: load.persistenceState)
        clock.advance(by: .seconds(1))
        XCTAssertNil(lane.composerDidChange(Support.content("replacement typing")), "buffered until restore")
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0 + .seconds(1))

        await late.open()
        let obligation = try XCTUnwrap(coordinator.composerPreparation(for: original))
        await obligation.preparationTask?.value
        XCTAssertEqual(obligation.failure, .ownerReplaced, "the late completion is a visible failure")
        XCTAssertEqual(obligation.latestContent?.text, "typed by the original owner", "its payload is retained")
        XCTAssertEqual(obligation.firstUnsavedAt, t0)
        XCTAssertEqual(lane.bufferedFirstUnsavedAt, t0 + .seconds(1), "no stale adoption into the replacement")

        // The restore is delayed past the replacement's own 2-second bound.
        clock.advance(by: .milliseconds(2500))
        let restored = await lane.restoreComposer()
        XCTAssertEqual(restored, .superseded)
        let written = await Support.eventually { await self.storedComposerText(store, load.session.id) == "replacement typing" }
        XCTAssertTrue(written, "an overdue obligation is written at once")
        let requested = await sleeper.requestedDeadlines
        XCTAssertFalse(
            requested.contains(clock.now + AgentRecoveryComposerPersistenceController.maximumDelay),
            "the deadline is never restarted after the delayed restore"
        )
        XCTAssertNotNil(coordinator.composerPreparation(for: original), "kept until explicitly resolved")
    }

    // MARK: Restore before edits

    func testTypingBeforeRestoreIsBufferedAndSupersedesTheStoredComposer() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("durable draft"))
        _ = await seed.flushComposer()

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        XCTAssertNil(lane.composerDidChange(Support.content("newer typing")), "buffered until restore")
        let outcome = await lane.restoreComposer()
        XCTAssertEqual(outcome, .superseded, "restore never overwrites newer typing")
        guard case .committed = await lane.flushComposer() else {
            return XCTFail("buffered typing is written after the restore")
        }
        let storedText = await storedComposerText(store, load.session.id)
        XCTAssertEqual(storedText, "newer typing")
    }

    func testSubmissionCapturedBeforeRestoreConsumesOnlyItsOwnContent() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("stored before relaunch"))
        _ = await seed.flushComposer()

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let token = lane.beginComposerSubmission(Support.content("submitted"))
        XCTAssertNil(token.revision)
        lane.composerDidChange(Support.content("typed after submit"))
        let admissionValue = AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .composer,
            target: .session,
            original: token.content
        )
        guard case let .success(admitted) = await lane.admitQueued(admissionValue, composerToken: token) else {
            return XCTFail("composer submission should commit")
        }
        XCTAssertEqual(admitted.submittedComposerRevision, token.revision)
        XCTAssertNotNil(token.revision)
        XCTAssertTrue(admitted.receipt.intent.composerConsumed, "the stored older composer was consumed")
        _ = await lane.flushComposer()
        let state = await store.read(sessionID: load.session.id)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.intent(id: admissionValue.intentID)?.payload.text, "submitted")
        XCTAssertEqual(record.composer?.content.text, "typed after submit", "later typing is never consumed")
    }

    // MARK: Held composer resolution

    private func heldLane() async throws -> (AgentRecoveryStore, AgentRecoverySessionLane, AgentRecoveryComposerSnapshot) {
        let fixture = try await heldLaneWithGate()
        return (fixture.store, fixture.lane, fixture.held)
    }

    /// A held-composer lane plus the session's real DataService recovery gate (for holding it).
    private func heldLaneWithGate() async throws -> (
        store: AgentRecoveryStore,
        lane: AgentRecoverySessionLane,
        held: AgentRecoveryComposerSnapshot,
        gate: any AgentRecoveryLifecycleGate
    ) {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        guard case let .heldForOtherGeneration(held) = await lane.restoreComposer() else {
            throw XCTSkip("fixture did not produce a held composer")
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        return (store, lane, held, gate)
    }

    func testHeldComposerIsNeverReplacedImplicitlyAndDiscardWritesLiveTyping() async throws {
        let (store, lane, held) = try await heldLane()
        lane.composerDidChange(Support.content("live typing"))
        let blocked = await lane.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = blocked else {
            return XCTFail("ordinary writes refuse to replace held input, got \(blocked)")
        }
        let unresolved = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(unresolved, held)

        let restoreRefused = await lane.resolveHeldComposer(
            .restoreToComposer,
            expectedHeldRevision: held.revision,
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(restoreRefused, .failure(.liveComposerHasUnsavedContent))
        let notDisplayed = await lane.resolveHeldComposer(
            .discard,
            expectedHeldRevision: AgentRecoveryComposerRevision.make(),
            liveComposerIsEmpty: false
        )
        XCTAssertEqual(notDisplayed, .failure(.heldInputChanged), "only the exact displayed held draft is resolved")
        let stillHeld = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stillHeld, held, "a refused resolution changes nothing")

        let discarded = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        XCTAssertEqual(lane.composerState, .ready)
        XCTAssertNil(lane.composer.lastWriteFailure)
        XCTAssertFalse(lane.composer.hasPendingChanges, "the live typing was stored by the discard itself")
        let state = await store.read(sessionID: lane.sessionID)
        let stored = try XCTUnwrap(state.record?.composer)
        XCTAssertEqual(stored.content.text, "live typing")
        XCTAssertEqual(stored.transcriptResetGeneration, 1)
    }

    func testRestoreHeldComposerMovesItIntoTheCurrentGenerationExplicitly() async throws {
        let (store, lane, held) = try await heldLane()
        let result = await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        guard case let .success(restored?) = result else {
            return XCTFail("expected restored content, got \(result)")
        }
        XCTAssertEqual(restored.content, held.content)
        XCTAssertEqual(restored.transcriptResetGeneration, 1)
        XCTAssertNotEqual(restored.revision, held.revision)
        XCTAssertEqual(lane.composer.liveRevision, restored.revision)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, restored)

        // Later edits write against the adopted revision.
        lane.composerDidChange(Support.content("edited after restore"))
        guard case .committed = await lane.flushComposer() else {
            return XCTFail("edits after restoring held input write normally")
        }
        let again = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        XCTAssertEqual(again, .failure(.noHeldComposer))
    }

    /// Restore freeze at the lane through the real session gate: a change while the restore waits
    /// for the gate wins the message box, the held draft stays stored and presented (nothing is
    /// memory-only beyond ordinary typing), and the explicit Discard then stores the typing.
    func testTypingWhileHeldRestoreWaitsForTheSessionGateKeepsTheHeldDraftDurable() async throws {
        let fixture = try await heldLaneWithGate()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await fixture.gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        lane.composerDidChange(Support.content("typed during restore"))
        await latch.open()
        try await holder.value
        let result = await resolution.value

        XCTAssertEqual(result, .failure(.composerChangedDuringRestore))
        XCTAssertEqual(lane.composerState, .held(held), "the held draft is still presented")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty, "no draft is left memory-only")
        XCTAssertTrue(lane.composer.hasPendingChanges, "the typing stays in the message box")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let discarded = await lane.resolveHeldComposer(.discard, expectedHeldRevision: held.revision, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        let afterDiscard = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(afterDiscard?.content.text, "typed during restore")
        XCTAssertEqual(lane.composerState, .ready)
    }

    // MARK: R02: failed rollback of a raced held restore across owners

    private struct FailedRollbackFixture {
        let store: AgentRecoveryStore
        let coordinator: AgentRecoveryCoordinator
        let persistenceState: AgentSessionPersistenceState
        let lane: AgentRecoverySessionLane
        let held: AgentRecoveryComposerSnapshot
        let protected: AgentRecoveryUnsavedComposerInput
        let gate: AgentSessionRecoveryLifecycleGate
    }

    /// A held draft is restored, a change lands right after the restore commit, and the rollback
    /// write fails (storage keeps failing until the test clears it). The restored draft is durable as
    /// the current composer and its visible copy carries the rollback obligation.
    private func laneWithFailedHeldRestoreRollback() async throws -> FailedRollbackFixture {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            XCTFail("expected a held composer, got \(outcome)")
            throw ReconcileFailure()
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        let fence = try XCTUnwrap(lane.composer.activeResolutionFence)
        let failureSwitch = try XCTUnwrap(failures)
        store.commitPublisher.setHandler { _ in
            // Only the restore commit: the change lands after it, and storage then fails.
            guard !failureSwitch.shouldFailWrites else { return }
            fence.noteComposerMutation()
            failureSwitch.shouldFailWrites = true
        }
        await latch.open()
        try await holder.value
        let result = await resolution.value
        store.commitPublisher.setHandler(nil)

        XCTAssertEqual(result, .success(nil), "the unreverted restore is kept visible, not adopted")
        let protected = try XCTUnwrap(lane.unsavedPredecessorInputs.first)
        XCTAssertEqual(protected.content, held.content)
        XCTAssertNotNil(protected.restoreRollback, "the visible copy carries the owed rollback")
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "the original draft is durable as the restored composer")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
        return FailedRollbackFixture(
            store: store,
            coordinator: coordinator,
            persistenceState: reset.persistenceState,
            lane: lane,
            held: held,
            protected: protected,
            gate: gate
        )
    }

    /// R02 same-binding hand-over: another owner claims the session while the rollback write still
    /// fails. The successor adopts the obligation; its typing never replaces the restored draft; once
    /// storage recovers its next flush rolls back, the draft is held again, the successor typing stays
    /// pending, and a relaunched store reads the original draft.
    func testSameBindingHandOverKeepsAFailedRollbackProtectedUntilTheSuccessorRollsItBack() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, held) = (fixture.store, fixture.held)
        fixture.lane.composerDidChange(Support.content("newer typing"))

        let second = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await second.restoreComposer()
        XCTAssertTrue(second.composer.isRestoredDraftAwaitingRollback, "the successor adopted the rollback obligation")
        XCTAssertEqual(second.unsavedPredecessorInputs.first, fixture.protected)
        XCTAssertEqual(second.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"], "newer typing stays visible")
        var stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")

        second.composerDidChange(Support.content("successor typing"))
        let failing = await second.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        XCTAssertNotNil(second.composer.lastWriteFailure, "the failure is visible for Retry")
        stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "successor typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await second.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("the successor rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(second.composerState, .held(held), "the draft is presented once, as held")
        XCTAssertFalse(second.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(second.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        XCTAssertTrue(second.composer.hasPendingChanges, "the successor typing stays in the message box")
        stored = await store.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: second.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02 ownerless release and reclaim: the released lane's protected copy is published but cannot
    /// be discarded without a lane; the reclaiming lane adopts the obligation. Its explicit Discard is
    /// durable: while storage fails nothing is resolved (entry, protection, and stored copy kept,
    /// admission still blocked); once it commits the live typing replaces the copy and admission opens.
    func testOwnerlessReclaimKeepsAFailedRollbackProtectedAndDiscardResolvesItDurably() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator) = (fixture.store, fixture.coordinator)
        let sessionID = fixture.lane.sessionID
        await coordinator.releaseLane(fixture.lane).value
        let ownerless = try XCTUnwrap(coordinator.ownerlessUnsavedInputs[sessionID])
        XCTAssertEqual(ownerless.inputs, [fixture.protected])
        XCTAssertFalse(
            coordinator.discardOwnerlessUnsavedInput(sessionID: sessionID, expected: fixture.protected),
            "only a lane resolves the protected copy, durably"
        )

        let reclaimed = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await reclaimed.restoreComposer()
        XCTAssertNil(coordinator.ownerlessUnsavedInputs[sessionID])
        XCTAssertTrue(reclaimed.composer.isRestoredDraftAwaitingRollback, "the reclaiming lane adopted the obligation")
        XCTAssertEqual(reclaimed.unsavedPredecessorInputs, [fixture.protected])
        reclaimed.composerDidChange(Support.content("reclaimed typing"))

        let refused = await reclaimed.resolveUnsavedPredecessorInput(.discard, expected: fixture.protected, liveComposerIsEmpty: false)
        guard case .failure(.store) = refused else {
            return XCTFail("a discard that cannot be written resolves nothing, got \(refused)")
        }
        XCTAssertEqual(reclaimed.unsavedPredecessorInputs, [fixture.protected], "the copy stays until its resolution is durable")
        XCTAssertTrue(reclaimed.composer.isRestoredDraftAwaitingRollback)
        var stored = await store.read(sessionID: sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")
        let blocked = await reclaimed.admitQueued(admission(reclaimed, "blocked"))
        assertRefused(blocked, .unsavedPredecessorInput)

        failures.shouldFailWrites = false
        let discarded = await reclaimed.resolveUnsavedPredecessorInput(.discard, expected: fixture.protected, liveComposerIsEmpty: false)
        XCTAssertEqual(discarded, .success(nil))
        XCTAssertTrue(reclaimed.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(reclaimed.composer.isRestoredDraftAwaitingRollback)
        stored = await store.read(sessionID: sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "reclaimed typing", "the discard stored the live typing in its place")
        guard case .success = await reclaimed.admitQueued(admission(reclaimed, "after resolution")) else {
            return XCTFail("admission opens once the resolution is durable")
        }
    }

    /// R02: Restore of the protected copy into the empty composer is durable before protection ends;
    /// a failed write keeps the entry, the protection, and the stored copy.
    func testRestoringAProtectedCopyIntoTheComposerIsDurableBeforeProtectionEnds() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane) = (fixture.store, fixture.lane)
        let refused = await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        guard case .failure(.store) = refused else {
            return XCTFail("a restore that cannot be written resolves nothing, got \(refused)")
        }
        XCTAssertEqual(lane.unsavedPredecessorInputs, [fixture.protected])
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(lane.composer.pendingContent?.text ?? "", "", "the live composer is left empty as shown")

        failures.shouldFailWrites = false
        let restored = await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        XCTAssertEqual(restored, .success(fixture.held.content))
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertFalse(lane.composer.hasPendingChanges, "the placed draft is durable as the live composer")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content, fixture.held.content)
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
    }

    /// R02 rapid same-binding chain A→B→C while the rollback write still fails: B is replaced before
    /// its predecessor settlement runs (no suspension between the claims), so B is a transit-only,
    /// already-retired owner. B must still forward the obligation; C adopts it, C's typing never
    /// replaces the original, and once storage recovers C rolls back and the original is held again.
    func testRapidThreeOwnerChainForwardsAFailedRollbackThroughATransitOnlyOwner() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator, held) = (fixture.store, fixture.coordinator, fixture.held)
        fixture.lane.composerDidChange(Support.content("newer typing"))

        let transit = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        let third = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        XCTAssertTrue(transit.isRetired, "B retired before its predecessor settlement could run")

        _ = await third.restoreComposer()
        XCTAssertTrue(third.composer.isRestoredDraftAwaitingRollback, "C adopted the obligation forwarded through B")
        XCTAssertEqual(third.unsavedPredecessorInputs.first, fixture.protected)
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"], "newer typing stays visible")

        third.composerDidChange(Support.content("third owner typing"))
        let failing = await third.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        var stored = await store.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "C's typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await third.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("C rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(third.composerState, .held(held))
        XCTAssertFalse(third.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(third.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        XCTAssertTrue(third.composer.hasPendingChanges, "C's typing stays in the message box")
        stored = await store.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: third.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02-R1 in-flight transfer: a successor claims the session while the held restore (and so its
    /// failing rollback) is still in flight. The retired lane never appends the protected copy, so its
    /// retirement must carry the obligation created during that resolution; the successor adopts it,
    /// its typing never replaces the original, and once storage recovers the original is held again.
    func testSuccessorClaimedWhileAHeldRestoreIsInFlightInheritsItsFailedRollback() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let owner = Owner()
        let old = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        _ = await old.restoreComposer()
        old.composerDidChange(Support.content("held draft"))
        _ = await old.flushComposer()
        let reset = try await resetTranscript(service, load)
        let lane = try coordinator.claimLane(owner: owner, persistenceState: reset.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case let .heldForOtherGeneration(held) = outcome else {
            return XCTFail("expected a held composer, got \(outcome)")
        }
        let gate = try service.recoveryLifecycleGate(for: reset.persistenceState)
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let resolution = Task { @MainActor in
            await lane.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision, liveComposerIsEmpty: true)
        }
        let armed = await Support.eventually { lane.composer.activeResolutionFence != nil }
        XCTAssertTrue(armed, "the restore passed its checks and waits for the gate")
        let fence = try XCTUnwrap(lane.composer.activeResolutionFence)
        let failureSwitch = try XCTUnwrap(failures)
        store.commitPublisher.setHandler { _ in
            guard !failureSwitch.shouldFailWrites else { return }
            fence.noteComposerMutation()
            failureSwitch.shouldFailWrites = true
        }

        let successor = try coordinator.claimLane(owner: Owner(), persistenceState: reset.persistenceState)
        XCTAssertTrue(lane.isRetired, "the original lane retired while its restore is in flight")
        await latch.open()
        try await holder.value
        _ = await resolution.value
        store.commitPublisher.setHandler(nil)
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "the restore committed and its rollback failed")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)

        _ = await successor.restoreComposer()
        XCTAssertTrue(successor.composer.isRestoredDraftAwaitingRollback, "the in-flight obligation reached the successor")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["held draft"])
        XCTAssertEqual(successor.unsavedPredecessorInputs.first?.restoreRollback, successor.composer.outstandingRestoreRollback)

        successor.composerDidChange(Support.content("successor typing"))
        let failing = await successor.flushComposer()
        guard case .failed(.store) = failing else {
            return XCTFail("the retried rollback fails on storage and nothing is written, got \(failing)")
        }
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft", "successor typing never replaces the protected draft")

        failures.shouldFailWrites = false
        let recovered = await successor.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = recovered else {
            return XCTFail("the successor rolls back first; its typing waits behind the held draft, got \(recovered)")
        }
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertTrue(successor.unsavedPredecessorInputs.isEmpty)
        XCTAssertEqual(successor.composer.pendingContent?.text, "successor typing")
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// Starts a protected Restore whose placement write is captured and then suspended on the held
    /// gate (the controller clears its write deadline when it captures the snapshot), changes the
    /// composer (newer typing by default), runs `beforeRelease`, and releases the gate.
    private func restoreProtectedCopyWithTypingDuringItsWrite(
        _ fixture: FailedRollbackFixture,
        change: @MainActor (AgentRecoverySessionLane) -> Void = { $0.composerDidChange(Support.content("newer typing")) },
        beforeRelease: @MainActor () -> Void = {}
    ) async throws -> Result<AgentRecoveryInputContent?, AgentRecoveryControllerFailure> {
        let lane = fixture.lane
        let gate = fixture.gate
        let latch = RecoveryGateLatch()
        let holder = Task {
            try await gate.performRecoveryTransaction { await latch.pause() }
        }
        await latch.waitUntilPaused()
        let restore = Task { @MainActor in
            await lane.resolveUnsavedPredecessorInput(.restoreToComposer, expected: fixture.protected, liveComposerIsEmpty: true)
        }
        let placed = await Support.eventually { lane.composer.pendingContent == fixture.held.content }
        XCTAssertTrue(placed, "the placement is staged")
        let suspended = await Support.eventually { lane.composer.maximumDelayDeadline == nil }
        XCTAssertTrue(suspended, "the placement write captured its snapshot and waits for the gate")
        change(lane)
        beforeRelease()
        await latch.open()
        try await holder.value
        return await restore.value
    }

    /// R02-R2, failed write: newer typing during the suspended placement write is never cleared; the
    /// protection and the stored original stay; a handover after storage recovers keeps both.
    func testNewerTypingDuringAFailedProtectedRestoreWriteSurvivesRetryAndHandOver() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture)
        guard case .failure(.store) = result else {
            return XCTFail("the placement write fails on storage, got \(result)")
        }
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing", "a failure never clears newer typing")
        XCTAssertEqual(lane.unsavedPredecessorInputs, [fixture.protected])
        XCTAssertTrue(lane.composer.isRestoredDraftAwaitingRollback)
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "held draft")

        failures.shouldFailWrites = false
        let successor = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composerState, .held(held), "the retiring flush rolled the original back to the held slot")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"], "the newer typing is handed over")
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
    }

    /// R02-R2, committed write: newer typing during the suspended placement write never yields
    /// success or a stale placement; the committed placement goes back to the held slot, the typing
    /// stays pending, and a retry and a handover keep both.
    func testNewerTypingDuringACommittedProtectedRestoreWriteNeverAdoptsTheStalePlacement() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture)
        XCTAssertEqual(result, .failure(.composerChangedDuringRestore), "no stale placement is returned")
        XCTAssertEqual(lane.composerState, .held(held), "the original is held again")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)

        let retried = await lane.flushComposer()
        guard case .failed(.store(.heldComposerUnresolved)) = retried else {
            return XCTFail("the typing waits behind the held draft, got \(retried)")
        }
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        let successor = try fixture.coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    /// R02-R2 fence: an image awaiting promotion (not representable, so no new live revision) during
    /// the suspended placement write still trips the placement fence. The committed placement is put
    /// back, no stale placement is returned, and the pending attachment obligation is kept.
    func testUnrepresentableChangeDuringAProtectedRestoreWriteNeverAdoptsTheStalePlacement() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, lane, held) = (fixture.store, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture, change: { $0.composerContentUnrepresentable() })
        XCTAssertEqual(result, .failure(.composerChangedDuringRestore), "no stale placement is returned")
        XCTAssertEqual(lane.composerState, .held(held), "the original is held again")
        XCTAssertTrue(lane.unsavedPredecessorInputs.isEmpty)
        XCTAssertFalse(lane.composer.isRestoredDraftAwaitingRollback)
        XCTAssertTrue(lane.hasUnrepresentableComposerEdit, "the pending attachment obligation is kept")
        XCTAssertEqual(lane.composer.pendingContent?.text ?? "", "", "the never-placed content is not left pending")
        let stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(persisted, held)
    }

    /// R02-R2 (B R3-2): the placement commits, typing raced it, and the put-back fails. The committed
    /// placement becomes the protected revision (a new obligation) carried by the visible copy and
    /// across a hand-over; once storage recovers the successor rolls it back to the held slot.
    func testCommittedPlacementWhosePutBackFailsStaysProtectedAcrossHandOver() async throws {
        let fixture = try await laneWithFailedHeldRestoreRollback()
        let (store, coordinator, lane, held) = (fixture.store, fixture.coordinator, fixture.lane, fixture.held)
        failures.shouldFailWrites = false
        let failureSwitch = try XCTUnwrap(failures)
        let result = try await restoreProtectedCopyWithTypingDuringItsWrite(fixture, beforeRelease: {
            store.commitPublisher.setHandler { _ in
                // Only the placement commit: storage fails for the put-back that follows.
                failureSwitch.shouldFailWrites = true
            }
        })
        store.commitPublisher.setHandler(nil)
        guard case .failure(.store) = result else {
            return XCTFail("the put-back fails on storage, got \(result)")
        }
        let renewed = try XCTUnwrap(lane.composer.outstandingRestoreRollback, "the committed placement is protected")
        XCTAssertNotEqual(renewed, fixture.protected.restoreRollback)
        XCTAssertEqual(lane.unsavedPredecessorInputs.map(\.restoreRollback), [renewed], "the visible copy carries the new obligation")
        XCTAssertEqual(lane.composer.pendingContent?.text, "newer typing")
        var stored = await store.read(sessionID: lane.sessionID).record?.composer
        XCTAssertEqual(stored?.revision, renewed.restoredRevision, "the placement is the stored protected revision")
        XCTAssertEqual(stored?.content, held.content)

        let successor = try coordinator.claimLane(owner: Owner(), persistenceState: fixture.persistenceState)
        _ = await successor.restoreComposer()
        XCTAssertEqual(successor.composer.outstandingRestoreRollback, renewed, "the successor adopted the new obligation")
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["held draft", "newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored?.revision, renewed.restoredRevision)

        failures.shouldFailWrites = false
        let recovered = await successor.flushComposer()
        XCTAssertEqual(recovered, .nothingPending, "the rollback succeeds with nothing pending in the successor")
        XCTAssertEqual(successor.composerState, .held(held))
        XCTAssertEqual(successor.unsavedPredecessorInputs.map(\.content.text), ["newer typing"])
        stored = await store.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(stored, held)
        let relaunched = AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let persisted = await relaunched.read(sessionID: successor.sessionID).record?.composer
        XCTAssertEqual(persisted, held, "the reconstructed record still holds the original draft")
    }

    // MARK: Deleted sessions

    // MARK: Shutdown (R4 two-stage quit / window close)

    private func questionSnapshot(
        _ store: AgentRecoveryStore,
        secretAnswer: String? = nil
    ) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: UUID(),
            kind: .userInput,
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: store.appInstanceID,
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            title: "Deploy?",
            message: nil,
            items: [
                AgentRecoveryQuestionItem(
                    questionID: "target",
                    header: "Target",
                    text: "Which environment?",
                    options: ["staging", "production"],
                    isSecret: false,
                    answer: "staging"
                ),
                AgentRecoveryQuestionItem(
                    questionID: "token",
                    header: nil,
                    text: "Paste the token",
                    options: [],
                    isSecret: true,
                    answer: secretAnswer
                )
            ]
        )
    }

    /// Scoped admission refusal on every route (queued, direct, dispatch commit, handoff): only the
    /// covered owner is frozen, an app-wide freeze covers lanes claimed later, and ending the freeze
    /// (Stage A Cancel) reopens everything.
    func testShutdownFreezeRefusesEveryRouteForCoveredOwnersOnlyAndCancelReopens() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let loadA = try await makeSession(service)
        let loadB = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let ownerA = Owner()
        let ownerB = Owner()
        let laneA = try coordinator.claimLane(owner: ownerA, persistenceState: loadA.persistenceState)
        let laneB = try coordinator.claimLane(owner: ownerB, persistenceState: loadB.persistenceState)
        _ = await laneA.restoreComposer()
        _ = await laneB.restoreComposer()
        guard case let .success(queued) = await laneA.admitQueued(admission(laneA, "queued before the freeze")) else {
            return XCTFail("admission is open before the freeze")
        }
        let dispatch = [AgentRecoveryDispatchRequest(
            intentID: queued.receipt.intent.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID())
        )]

        let token = coordinator.beginShutdownFreeze(scope: .owners([ObjectIdentifier(ownerA)]))
        XCTAssertTrue(laneA.isShutdownFrozen)
        XCTAssertFalse(laneB.isShutdownFrozen, "a window close freezes only its own owners")
        let frozenQueued = await laneA.admitQueued(admission(laneA, "queued"))
        assertRefused(frozenQueued, .shutdownInProgress)
        let direct = await laneA.admitDirect(admission(laneA, "direct"), attempt: AgentRecoveryAttemptStart(attemptID: UUID()))
        guard case .failure(.refused(.shutdownInProgress)) = direct else {
            return XCTFail("direct admission is refused while frozen, got \(direct)")
        }
        let frozenDispatch = await laneA.beginDispatches(dispatch, authorization: .liveQueue)
        guard case .failure(.refused(.shutdownInProgress)) = frozenDispatch else {
            return XCTFail("a dispatch commit is refused while frozen, got \(frozenDispatch)")
        }
        XCTAssertFalse(laneA.isValidForHandoff, "no provider handoff while frozen")
        XCTAssertTrue(laneB.isValidForHandoff)
        guard case .success = await laneB.admitQueued(admission(laneB, "other window")) else {
            return XCTFail("an unaffected owner keeps admitting")
        }

        coordinator.endShutdownFreeze(token)
        XCTAssertFalse(laneA.isShutdownFrozen)
        XCTAssertTrue(laneA.isValidForHandoff)
        guard case .success = await laneA.admitQueued(admission(laneA, "after cancel")) else {
            return XCTFail("Cancel reopens admission")
        }
        guard case .success = await laneA.beginDispatches(dispatch, authorization: .liveQueue) else {
            return XCTFail("Cancel reopens dispatch commits")
        }

        let appToken = coordinator.beginShutdownFreeze(scope: .application)
        let loadC = try await makeSession(service)
        let laneC = try coordinator.claimLane(owner: Owner(), persistenceState: loadC.persistenceState)
        XCTAssertTrue(laneB.isShutdownFrozen)
        XCTAssertTrue(laneC.isShutdownFrozen, "an app quit also covers lanes claimed after it began")
        coordinator.endShutdownFreeze(appToken)
        XCTAssertFalse(coordinator.hasShutdownFreeze)
    }

    /// Stage A vetoes on input an unsaved predecessor holds only in memory, leaves the lane usable,
    /// and on success writes the composer, the pending-question snapshots (never a secret answer),
    /// and the run's shutdown reason (the first reason is kept across attempts).
    func testShutdownPreparationVetoesUnsavedPredecessorThenPersistsQuestionsAndRunReason() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let first = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await first.restoreComposer()
        failures.shouldFailWrites = true
        XCTAssertNotNil(first.composerDidChange(Support.content("unsaved before replacement")))
        let second = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        // Joins the predecessor's (failing) hand-over flush.
        let blocked = await second.admitQueued(admission(second, "blocked"))
        assertRefused(blocked, .unsavedPredecessorInput)
        let inherited = try XCTUnwrap(second.unsavedPredecessorInputs.first)
        failures.shouldFailWrites = false
        _ = await second.restoreComposer()

        let vetoed = await second.prepareForShutdown(questions: .init(upserting: [questionSnapshot(store)]), run: nil)
        guard case .failure(.composer(.unsavedPredecessorInput)) = vetoed else {
            return XCTFail("input held only in memory vetoes Stage A, got \(vetoed)")
        }
        XCTAssertFalse(second.isRetired, "a veto leaves the lane usable")
        XCTAssertEqual(second.unsavedPredecessorInputs, [inherited])
        let afterVeto = await store.read(sessionID: load.session.id).record?.questions ?? []
        XCTAssertTrue(afterVeto.isEmpty, "nothing after the veto was written")

        _ = await second.resolveUnsavedPredecessorInput(.discard, expected: inherited, liveComposerIsEmpty: true)
        second.composerDidChange(Support.content("typed before quitting"))
        let snapshot = questionSnapshot(store, secretAnswer: "s3cr3t")
        XCTAssertNil(snapshot.items[1].answer, "a secret answer is structurally absent")
        let ownership = Support.ownership(sessionID: load.session.id)
        let run = AgentRecoverySessionLane.ShutdownRunEvidence(
            ownership: ownership,
            processRunID: nil,
            reason: .windowClose,
            lastConfirmedActivityAt: nil
        )
        guard case .success = await second.prepareForShutdown(questions: .init(upserting: [snapshot]), run: run) else {
            return XCTFail("Stage A succeeds once nothing is held only in memory")
        }
        let prepared = await store.read(sessionID: load.session.id).record
        let record = try XCTUnwrap(prepared)
        XCTAssertEqual(record.composer?.content.text, "typed before quitting")
        XCTAssertEqual(record.questions, [snapshot])
        XCTAssertEqual(record.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .windowClose)
        XCTAssertNil(record.runAttempt(id: ownership.attemptID)?.terminal, "a shutdown reason is not a stop")

        // A later attempt (window close cancelled, then app quit) keeps the first reason.
        let laterRun = AgentRecoverySessionLane.ShutdownRunEvidence(
            ownership: ownership,
            processRunID: nil,
            reason: .appQuit,
            lastConfirmedActivityAt: nil
        )
        let resolved = AgentRecoveryStore.QuestionSnapshotUpdate(removing: [snapshot.interactionID])
        guard case .success = await second.prepareForShutdown(questions: resolved, run: laterRun) else {
            return XCTFail("a repeated preparation succeeds")
        }
        let repeatedRecord = await store.read(sessionID: load.session.id).record
        let repeated = try XCTUnwrap(repeatedRecord)
        XCTAssertEqual(repeated.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .windowClose)
        XCTAssertTrue(repeated.questions.isEmpty, "a resolved question is removed by its interaction ID")
        guard case .success = await second.admitQueued(admission(second, "still usable")) else {
            return XCTFail("preparation never retires the lane or keeps admission closed")
        }
    }

    /// R4-01: question writes name exact interactions. A question another owner preserved, from an
    /// earlier launch or from a window closed earlier in this same launch (its snapshot carries
    /// this launch's instance ID), survives a reopened owner's preparation without live questions.
    /// Only an exact removal (live resolution, the recovery list) erases a snapshot; re-upserting a
    /// stored question replaces it in place and reports it as already stored.
    func testQuestionWritesNameExactInteractionsAndKeepOtherOwnersSnapshots() async throws {
        let previousStore = makeStore(instance: UUID())
        let previousService = makeService(store: previousStore)
        let load = try await makeSession(previousService)
        let previousGate = try previousService.recoveryLifecycleGate(for: load.persistenceState)
        let earlier = questionSnapshot(previousStore)
        try await previousGate.performRecoveryTransaction {
            _ = try await previousStore.updateQuestionSnapshots(
                binding: previousGate.binding,
                expectedRevision: previousStore.currentRevision(sessionID: load.session.id),
                update: .init(upserting: [earlier])
            )
        }

        let store = makeStore(instance: UUID())
        let service = makeService(store: store)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let reloaded = try await service.loadAgentSessionForEditing(id: load.session.id, for: workspace)
        let persistenceState = try XCTUnwrap(reloaded?.persistenceState)
        let closedOwner = try coordinator.claimLane(owner: Owner(), persistenceState: persistenceState)
        _ = await closedOwner.restoreComposer()

        // A window of this launch preserves its live question, then closes.
        let closed = questionSnapshot(store)
        guard case let .success(alreadyStored) = await closedOwner.prepareForShutdown(
            questions: .init(upserting: [closed]),
            run: nil
        ) else {
            return XCTFail("the closing window's preparation succeeds")
        }
        XCTAssertEqual(alreadyStored, [])
        XCTAssertEqual(closed.appInstanceID, store.appInstanceID, "the closed window's snapshot is this launch's")

        // The session reopens in another window of the same launch, with no live question.
        let reopened = try coordinator.claimLane(owner: Owner(), persistenceState: persistenceState)
        _ = await reopened.restoreComposer()
        guard case .success = await reopened.prepareForShutdown(questions: .init(), run: nil) else {
            return XCTFail("preparation without live questions succeeds")
        }
        var stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, closed], "no live question erases neither launch's preserved question")

        let live = questionSnapshot(store)
        guard case let .success(newlyStored) = await reopened.prepareForShutdown(
            questions: .init(upserting: [live]),
            run: nil
        ) else {
            return XCTFail("preparation with a live question succeeds")
        }
        XCTAssertEqual(newlyStored, [], "a new live question is not already stored")
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, closed, live])

        var revised = closed
        revised.extras["revision"] = .string("2")
        guard case let .success(restored) = await reopened.prepareForShutdown(
            questions: .init(upserting: [revised]),
            run: nil
        ) else {
            return XCTFail("re-upserting a stored question succeeds")
        }
        XCTAssertEqual(restored, [closed.interactionID], "a re-upserted question is reported as already stored")
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, revised, live], "replaced in place")

        // Live resolution removes exactly its interaction.
        guard case .success = await reopened.updateQuestionSnapshots(.init(removing: [live.interactionID])) else {
            return XCTFail("live refresh succeeds")
        }
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [earlier, revised])

        // The recovery list removes exactly the question it resolved.
        guard case .success = await reopened.updateQuestionSnapshots(.init(removing: [earlier.interactionID])) else {
            return XCTFail("the recovery list removes its question")
        }
        stored = await store.read(sessionID: load.session.id).record?.questions
        XCTAssertEqual(stored, [revised])
    }

    /// Question snapshots round-trip through a fresh store; a secret answer stored on disk makes the
    /// record unreadable instead of being adopted.
    func testQuestionSnapshotsRoundTripAndAStoredSecretAnswerIsUnreadable() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await lane.restoreComposer()
        var snapshot = questionSnapshot(store)
        snapshot.extras["futureField"] = .string("kept")
        guard case .success = await lane.updateQuestionSnapshots(.init(upserting: [snapshot])) else {
            return XCTFail("question snapshots are written")
        }
        let reread = await makeStore().read(sessionID: load.session.id).record
        XCTAssertEqual(reread?.questions, [snapshot], "unknown fields and every item survive a round trip")

        let fileURL = store.recordFileURL(sessionID: load.session.id)
        let data = try Data(contentsOf: fileURL)
        guard case .success = AgentRecoveryRecordCodec.decode(data, expectedSessionID: load.session.id) else {
            return XCTFail("the written record decodes")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        var items = try XCTUnwrap(questions[0]["items"] as? [[String: Any]])
        XCTAssertNil(items[1]["answer"], "no secret answer was written")
        items[1]["answer"] = "leaked"
        questions[0]["items"] = items
        object["questions"] = questions
        let tampered = try JSONSerialization.data(withJSONObject: object)
        guard case .failure = AgentRecoveryRecordCodec.decode(tampered, expectedSessionID: load.session.id) else {
            return XCTFail("a stored secret answer is never adopted")
        }
    }

    func testDeletedSessionNeverRestoresOrAdmits() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        let load = try await makeSession(service)
        let coordinator = try await startedCoordinator(store: store, service: service)
        let seed = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        _ = await seed.restoreComposer()
        seed.composerDidChange(Support.content("draft before deletion"))
        _ = await seed.flushComposer()

        let deletion = try AgentSessionDeletionCandidate(
            composeTabID: XCTUnwrap(load.session.composeTabID),
            persistenceState: load.persistenceState
        )
        let deleted = try await service.deleteAgentSession(ifCurrent: deletion, for: workspace)
        XCTAssertEqual(deleted, .deleted)

        let lane = try coordinator.claimLane(owner: Owner(), persistenceState: load.persistenceState)
        let outcome = await lane.restoreComposer()
        guard case .failed(.lifecycleRejected) = outcome else {
            return XCTFail("a tombstoned session never restores, got \(outcome)")
        }
        let refused = await lane.admitQueued(admission(lane, "after deletion"))
        guard case .failure(.commitFailed(.lifecycleRejected)) = refused else {
            return XCTFail("a tombstoned session never admits, got \(refused)")
        }
    }
}
