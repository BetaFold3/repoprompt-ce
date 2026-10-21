import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Mandatory lossless-restart scheduled dispatch on non-Codex providers (R2/R9). The injected starter
/// reproduces the run service's non-Codex evidence contract against the linked intent: `dispatching`
/// is committed before the provider, the start returns before acceptance (Claude/ACP accept on the
/// provider's response), and acceptance or a proven non-handoff is written afterwards.
@MainActor
final class AgentScheduledSendNonCodexMandatoryTests: XCTestCase {
    func testClaudeScheduledSendCommitsIntentFirstAndTransfersOnlyAfterAffirmativeAcceptance() async throws {
        let harness = try await makeHarness(windowID: 4801, agent: .claudeCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            await probe.observeHandoff(harness)
            guard let evidence = await probe.beginEvidence(harness) else { return .failed(message: "no evidence") }
            probe.evidence = evidence
            // The run starts; acceptance arrives later with the provider's response.
            harness.session.runID = UUID()
            harness.session.runState = .running
            return nil
        }

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Run the Claude tests", probe: probe)

        XCTAssertEqual(probe.intentsAtHandoff.count, 1, "The scheduled intent is committed before the provider start")
        XCTAssertEqual(probe.intentsAtHandoff.first?.origin, .scheduled)
        XCTAssertEqual(probe.intentsAtHandoff.first?.deliveryState, .queued)
        XCTAssertEqual(probe.intentsAtHandoff.first?.userItemID, attempt.itemID, "The intent owns the bubble's item")
        XCTAssertEqual(probe.userItemIDsAtHandoff, [attempt.itemID], "The bubble is appended before the provider start")

        // Dispatch returned while the intent is still `dispatching`: held, never confirmed or transferred.
        try await harness.waitUntil("hold awaits provider evidence") {
            harness.coordinator.transferHold(scheduleID: scheduleID)?.reason == .awaitingProviderEvidence
                && !harness.session.isScheduledDispatchInFlight
        }
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertNil(harness.session.lastScheduledDispatch)
        XCTAssertNil(harness.coordinator.recoveryStatus(sessionID: harness.sessionID))
        let dispatchingIntent = try await harness.singleIntent()
        XCTAssertEqual(dispatchingIntent.deliveryState, .dispatching)

        // Run ends before the late evidence write lands: the hold keeps waiting.
        harness.session.runState = .completed
        let evidence = try XCTUnwrap(probe.evidence)
        evidence.noteAccepted()
        let failures = await evidence.settled()
        XCTAssertTrue(failures.isEmpty)
        let acceptedIntent = try await harness.singleIntent()
        XCTAssertEqual(acceptedIntent.deliveryState, .providerAccepted)

        try await harness.waitUntil("transfer completes as provider acceptance") {
            harness.session.lastScheduledDispatch != nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertEqual(receipt.kind, .providerAccepted)
        XCTAssertEqual(receipt.scheduleID, scheduleID)
        XCTAssertEqual(receipt.attemptID, attempt.attemptID)
        XCTAssertNil(harness.session.scheduledSend, "The pending schedule is cleared by the transfer")
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1, "The bubble is kept")
        XCTAssertEqual(probe.startCount, 1, "Never re-driven")
    }

    func testOpenCodeProvenNoHandoffTransfersAsSavedInQueueNeverAcceptance() async throws {
        let harness = try await makeHarness(windowID: 4802, agent: .openCode)
        let probe = StarterProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            await probe.observeHandoff(harness)
            guard let evidence = await probe.beginEvidence(harness) else { return .failed(message: "no evidence") }
            // The post-commit freshness check failed before the provider boundary: settle back to queue.
            evidence.noteNoHandoff(message: "target changed")
            _ = await evidence.settled()
            return .stale(reason: "target changed")
        }

        let (scheduleID, attempt) = try await harness.fireSchedule(text: "Summarize the ACP log", probe: probe)

        XCTAssertEqual(probe.intentsAtHandoff.map(\.deliveryState), [.queued], "Committed before the provider start")
        try await harness.waitUntil("transfer completes as saved input") {
            harness.session.lastScheduledDispatch != nil
        }
        let intent = try await harness.singleIntent()
        XCTAssertEqual(intent.deliveryState, .queued)
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertFalse(receipt.isProviderAccepted, "A queued intent is saved input, never delivery evidence")
        XCTAssertEqual(receipt.queueLink, AgentScheduledSendQueueLink(intentID: intent.intentID, userItemID: attempt.itemID))
        XCTAssertEqual(receipt.scheduleID, scheduleID)
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertNil(harness.coordinator.transferHold(scheduleID: scheduleID))
        XCTAssertEqual(harness.session.items.count { $0.id == attempt.itemID }, 1, "The queued intent's bubble is kept")
        XCTAssertEqual(probe.startCount, 1)
    }

    // MARK: - Harness

    @MainActor
    private final class StarterProbe {
        var startCount = 0
        var intentsAtHandoff: [AgentRecoveryIntent] = []
        var userItemIDsAtHandoff: [UUID] = []
        var attemptAtHandoff: AgentScheduledSendPersist.Attempt?
        var evidence: AgentRecoveryDispatchEvidence?

        func observeHandoff(_ harness: Harness) async {
            startCount += 1
            attemptAtHandoff = harness.session.pendingScheduledSendRecord?.attempt
            intentsAtHandoff = await harness.intents()
            userItemIDsAtHandoff = harness.session.items.filter { $0.kind == .user && $0.text != "Earlier turn" }.map(\.id)
        }

        /// The run service's before-handoff step for the linked intent (`dispatching` committed).
        func beginEvidence(_ harness: Harness) async -> AgentRecoveryDispatchEvidence? {
            guard let lane = harness.session.recoveryLane,
                  let intentID = intentsAtHandoff.first?.intentID,
                  case let .success(receipt) = await lane.issueQueueReceipt(intentID: intentID),
                  case let .success(evidence) = await AgentRecoveryDispatchEvidence.begin(
                      session: harness.session,
                      constituents: [AgentQueuedInputIdentity(receipt: receipt)],
                      runAttemptID: nil
                  )
            else { return nil }
            return evidence
        }
    }

    private struct Timeout: Error {}

    @MainActor
    private struct Harness {
        let viewModel: AgentModeViewModel
        let coordinator: AgentScheduledSendCoordinator
        let clock: FakeSchedulerClock
        let session: AgentTabSession
        let lane: AgentRecoverySessionLane

        var sessionID: UUID {
            lane.sessionID
        }

        func intents() async -> [AgentRecoveryIntent] {
            await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        }

        func singleIntent() async throws -> AgentRecoveryIntent {
            let intents = await intents()
            XCTAssertEqual(intents.count, 1)
            return try XCTUnwrap(intents.first)
        }

        func waitUntil(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
            for _ in 0 ..< 400 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for \(label)")
            throw Timeout()
        }

        /// Installs a schedule, fires it, and returns once its single dispatch finished.
        func fireSchedule(text: String, probe: StarterProbe) async throws -> (UUID, AgentScheduledSendPersist.Attempt) {
            let notBefore = clock.now.addingTimeInterval(60)
            let scheduleID = try await viewModel.installScheduledSend(
                text: text,
                on: session,
                notBefore: notBefore,
                runAlongsideOtherSessions: false,
                isNewSessionStart: false
            ).get()
            clock.advance(to: notBefore.addingTimeInterval(1))
            try await waitUntil("scheduled attempt dispatched") {
                probe.startCount == 1 && !session.isScheduledDispatchInFlight
            }
            return try (scheduleID, XCTUnwrap(probe.attemptAtHandoff))
        }
    }

    private func makeHarness(windowID: Int, agent: AgentProviderKind) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentScheduledSendNonCodexWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentScheduledSendNonCodexStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = AgentRecoveryStore(rootURL: recoveryRoot)
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let recoveryCoordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        recoveryCoordinator.startIfNeeded()
        guard await recoveryCoordinator.awaitStartup() == .ready else { throw RecoveryLaneFixtureError.startupNotReady }

        let workspace = WorkspaceModel(
            name: "Scheduled Non-Codex Recovery",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(recoveryCoordinator, admissionMode: .mandatory)
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
        session.selectedAgent = agent

        // The first save claims the session's lane.
        session.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(session.recoveryLane, "The first save claims the session's lane")

        let clock = FakeSchedulerClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        viewModel.attachScheduledSendCoordinator(coordinator)
        return Harness(viewModel: viewModel, coordinator: coordinator, clock: clock, session: session, lane: lane)
    }
}

/// Deterministic scheduler clock: sleepers resume only when the test advances time.
@MainActor
private final class FakeSchedulerClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []

    init(now: Date) {
        self.now = now
    }

    var clock: SchedulerClock {
        SchedulerClock(
            now: { [weak self] in
                self?.now ?? .distantPast
            },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await sleep(until: deadline)
            },
            probe: { .none }
        )
    }

    func advance(to date: Date) {
        now = max(now, date)
        let ready = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    private func sleep(until deadline: Date) async throws {
        if deadline <= now { return }
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }
}
