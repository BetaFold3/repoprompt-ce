import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Phase 1b provider-handoff adapter (Claude native, ACP, headless) over the shared dispatch
/// evidence, against a real temporary recovery store behind the real DataService gate.
@MainActor
final class AgentProviderHandoffTests: XCTestCase {
    func testBeginWithOwnershipRecordsRunAttemptBeforeDispatch() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-run-attempt")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("steer")
        let ownership = session.beginRunAttempt(source: "test.handoff")

        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: UUID()
        ).get()

        XCTAssertTrue(handoff.isDurable)
        XCTAssertEqual(handoff.runAttemptID, ownership.attemptID)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .dispatching)
        let hasRunAttempt = await fixture.hasRunAttempt(ownership.attemptID)
        XCTAssertTrue(hasRunAttempt, "The existing run attempt is recorded before the dispatch")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.map(\.runAttemptID), [ownership.attemptID])
    }

    func testScopeEndingBeforeHandoffSettlesSameIntentBackToQueue() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-no-handoff")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("never sent")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        ).get()

        handoff.settleIfUnresolved()
        let failures = await handoff.evidence.settled()

        XCTAssertEqual(failures, [])
        XCTAssertEqual(handoff.observation, .notHandedOff)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.intentID, identity.intentID, "The same intent is kept, never a new one")
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    func testNoHandoffAfterBoundaryEnteredRecordsUncertaintyNotQueue() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-started-unknown")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("maybe sent")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        ).get()

        XCTAssertTrue(handoff.enterProviderBoundary(in: session))
        handoff.noteNoHandoff()
        handoff.settleIfUnresolved()
        _ = await handoff.evidence.settled()

        XCTAssertEqual(handoff.observation, .deliveryUnknown)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .deliveryUnknown, "An entered boundary is never a retryable queue entry")

        // Late affirmative evidence refines the uncertainty; nothing downgrades it afterwards.
        handoff.noteAccepted()
        handoff.settleIfUnresolved()
        handoff.noteDeliveryUnknown()
        _ = await handoff.evidence.settled()
        let accepted = await fixture.intent(identity)
        XCTAssertEqual(accepted?.deliveryState, .providerAccepted)
    }

    func testProvenNotWrittenAfterBoundarySettlesBackToQueue() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-proven-not-written")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("write refused")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        ).get()

        XCTAssertTrue(handoff.enterProviderBoundary(in: session))
        handoff.noteProvenNotWritten(message: "process not running")
        handoff.settleIfUnresolved()
        _ = await handoff.evidence.settled()

        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    /// ACP coalesced steering: every constituent commits atomically in the given order, and the
    /// deferred run-attempt attachment links each one to the same existing run attempt.
    func testCoalescedBatchKeepsConstituentOrderAndAttachesEachToRunAttempt() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-acp-batch")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let first = try await fixture.queuedIdentity("first")
        let second = try await fixture.queuedIdentity("second")
        let third = try await fixture.queuedIdentity("third")
        let ordered = [second, first, third]

        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: ordered,
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertEqual(handoff.evidence.receipts.map(\.intent.intentID), ordered.map(\.intentID))
        // Step 4d1: the baseline identity keeps every constituent's user item, in dispatch order,
        // and states completeness explicitly (all three named, distinct).
        let baselineIdentity = try XCTUnwrap(handoff.dispatchBaselineIdentity)
        let orderedUserItems = ordered.compactMap(\.userItemID)
        XCTAssertEqual(orderedUserItems.count, ordered.count)
        XCTAssertEqual(baselineIdentity.userItemIDs, orderedUserItems)
        XCTAssertTrue(baselineIdentity.hasCompleteUserItems)

        let ownership = session.beginRunAttempt(source: "test.acpBatch")
        let attached = await handoff.attachRunAttempt(ownership: ownership, processRunID: UUID(), session: session)
        guard case .success = attached else {
            return XCTFail("Expected attachment to succeed, got \(attached)")
        }
        XCTAssertEqual(handoff.runAttemptID, ownership.attemptID)
        for identity in ordered {
            let intent = await fixture.intent(identity)
            XCTAssertEqual(intent?.deliveryState, .dispatching)
            let attempts = await fixture.attempts(for: identity)
            XCTAssertEqual(attempts.map(\.runAttemptID), [ownership.attemptID])
        }

        // A second attempt cannot take over an already-attached handoff.
        let other = session.beginRunAttempt(source: "test.acpBatch.other")
        let conflicting = await handoff.attachRunAttempt(ownership: other, processRunID: nil, session: session)
        guard case .failure = conflicting else {
            return XCTFail("Expected a conflicting attachment to fail")
        }
    }

    func testRetiredLaneRefusesDispatchWithoutWriting() async throws {
        let fixture = try await RecoveryLaneFixture.make("handoff-retired")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("held")
        await fixture.coordinator.releaseLane(fixture.lane).value
        let ownership = session.beginRunAttempt(source: "test.retired")

        let result = await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: nil
        )

        guard case .failure(.refused(.laneRetired)) = result else {
            return XCTFail("Expected laneRetired refusal, got \(result)")
        }
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
        let attempts = await fixture.attempts(for: identity)
        XCTAssertTrue(attempts.isEmpty)
        let hasRunAttempt = await fixture.hasRunAttempt(ownership.attemptID)
        XCTAssertFalse(hasRunAttempt, "A refused dispatch records no run attempt")
    }

    func testUntrackedInputIsRefusedUnderMandatoryAdmission() async {
        let session = AgentTabSession(tabID: UUID())
        let identity = AgentQueuedInputIdentity.inactiveForTesting(in: session)
        session.recoveryAdmissionMode = .mandatory

        let result = await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: session.beginRunAttempt(source: "test.mandatory"),
            processRunID: nil
        )

        guard case .failure(.refused(.untrackedInput)) = result else {
            return XCTFail("Expected untracked refusal, got \(result)")
        }
    }

    func testHeadlessStreamAcceptanceRequiresModelOutput() {
        XCTAssertTrue(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "content", text: "hi")))
        XCTAssertTrue(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "content", text: nil, reasoning: "r")))
        XCTAssertTrue(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "tool_call", text: nil)))
        XCTAssertFalse(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "content", text: "")))
        XCTAssertFalse(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: AIStreamResult.lifecycleType, text: "started")))
        XCTAssertFalse(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "error", text: "boom")))
        XCTAssertFalse(AgentProviderHandoff.streamResultProvesProviderAcceptance(AIStreamResult(type: "usage", text: nil, promptTokens: 10)))
    }

    func testACPPromptWriteObservationRecordsOnlyTheWriteAndForwards() {
        let downstream = ACPPromptWriteObservation(forwarding: nil)
        let observation = ACPPromptWriteObservation(forwarding: downstream.onSubmitted)
        XCTAssertFalse(observation.wasWritten, "Building the request is not a write")
        XCTAssertFalse(downstream.wasWritten)
        observation.onSubmitted()
        XCTAssertTrue(observation.wasWritten)
        XCTAssertTrue(downstream.wasWritten, "The existing delegated-question acknowledgement still fires")
    }
}

// MARK: - Route-level evidence (lifecycle harness)

@MainActor
extension AgentModeRunServiceLifecycleTests {
    /// Review R1 B N2: a non-Codex start that fails before any runner owns its input (the workspace
    /// path can't be resolved) still returns `nil`, which callers read as "runner admitted". The
    /// explicit recovery action its input carries ends anyway: fenced (nothing was committed), it
    /// settles not handed off instead of holding the session forever, and its intent stays queued.
    func testNonCodexStartupFailureBeforeAnyRunnerSettlesTheCarriedRecoveryAction() async throws {
        let fixture = try await RecoveryLaneFixture.make("r1-n2-startup-failure")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let harness = makeHarness(recorder: recorder, workspacePathProvider: { _ in throw LifecycleTestError.workspaceMissing })
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let lane = fixture.lane
        let request = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: AgentRecoveryCardKey(
                kind: .run,
                incarnationID: lane.binding.incarnationID,
                transcriptResetGeneration: lane.binding.transcriptResetGeneration,
                entityID: UUID().uuidString
            ),
            kind: .continueWithText,
            expectedRevision: nil,
            sourceRunAttemptID: nil,
            target: AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1"),
            text: AgentRecoveryActionRequest.defaultContinuationText,
            plannedUserItemID: UUID(),
            supersedesActionID: nil,
            confirmsUncertainPriorDelivery: false
        )
        guard case let .acquired(authorization) = fixture.coordinator.beginRecoveryAction(request, lane: lane) else {
            return XCTFail("expected the action hold")
        }
        let plannedItemID = try XCTUnwrap(authorization.plannedUserItemID)
        let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: plannedItemID,
            origin: .followUp,
            target: .session,
            original: RecoveryTestSupport.content("continue"),
            actionAuthorization: authorization
        )).get()
        let identity = AgentQueuedInputIdentity(receipt: admitted.receipt, actionAuthorization: authorization)

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "continue",
            initialMessageForRun: "continue",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome, "unchanged: a pre-runner startup failure still returns nil")
        XCTAssertEqual(session.runState, .failed)
        XCTAssertFalse(recorder.contains(prefix: "factory:"), "no provider was created")

        // Bounded polling only detects a regression (a forever hold); the exact settlement is the proof.
        final class Observed {
            var settlement: AgentRecoveryActionSettlement?
        }
        let observed = Observed()
        let observer = Task { @MainActor in
            observed.settlement = await fixture.coordinator.awaitRecoveryActionSettlement(authorization)
        }
        let settled = await RecoveryTestSupport.eventually { observed.settlement != nil }
        XCTAssertTrue(settled, "the carried action settles; it never holds the session forever")
        guard settled else {
            fixture.coordinator.endRecoveryAction(authorization)
            return
        }
        _ = await observer.value
        XCTAssertEqual(observed.settlement, .notHandedOff(nil))
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued, "nothing was committed or sent")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertTrue(attempts.isEmpty)
        let intentID = try XCTUnwrap(identity.intentID)
        let late = await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: nil),
            authorization: .liveQueue,
            action: authorization
        )
        guard case .failure(.refused(.recoveryActionInProgress)) = late else {
            return XCTFail("the ended submission's token is revoked, got \(late)")
        }
        fixture.coordinator.endRecoveryAction(authorization)
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 0)
    }

    func testStartRunDispatchRefusalStartsNoRunAndNoProviderHandoff() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-refused")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("refused")
        session.recoveryAdmissionMode = .mandatory
        // The lane retires (owner replaced) before dispatch: the commit is refused.
        await fixture.coordinator.releaseLane(fixture.lane).value

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "refused",
            initialMessageForRun: "refused",
            attachments: [],
            inputConstituents: [identity]
        )

        XCTAssertEqual(outcome, .stale(reason: AgentModeRunService.recoveryDispatchRefusedReason))
        XCTAssertNil(session.activeRunAttemptID, "No run attempt may begin")
        XCTAssertNil(session.agentTask)
        XCTAssertFalse(recorder.contains("factory:claude"))
        XCTAssertFalse(recorder.contains("claude:send"))
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    func testStartRunUntrackedInputUnderMandatoryAdmissionNeverReachesProvider() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let untracked = AgentQueuedInputIdentity.inactiveForTesting(in: session)
        session.recoveryAdmissionMode = .mandatory

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "legacy",
            initialMessageForRun: "legacy",
            attachments: [],
            inputConstituents: [untracked]
        )

        XCTAssertEqual(outcome, .stale(reason: AgentModeRunService.recoveryDispatchRefusedReason))
        XCTAssertNil(session.activeRunAttemptID)
        XCTAssertFalse(recorder.contains("claude:send"))
    }

    /// The durable Claude start: dispatch committed before the runner, run attempt attached before
    /// the controller write, the write itself is not acceptance, and only the turn's own
    /// `.completed` result accepts.
    func testClaudeDurableStartAttachesRunAttemptAndAcceptsOnlyOnTurnCompletion() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-accept")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "ok")
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("hello")
        session.recoveryAdmissionMode = .mandatory

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "hello",
            initialMessageForRun: "hello",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome)
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        let agentTask = session.agentTask
        _ = await controller.waitForPendingTurnCompletion()

        let written = await fixture.intent(identity)
        XCTAssertEqual(written?.deliveryState, .dispatching, "A successful write is not acceptance")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.map(\.runAttemptID), [runAttemptID])
        let hasRunAttempt = await fixture.hasRunAttempt(runAttemptID)
        XCTAssertTrue(hasRunAttempt)

        await controller.emitPendingTurnCompletion()
        await agentTask?.value
        let accepted = await fixture.waitForIntent(identity, state: .providerAccepted)
        XCTAssertEqual(accepted?.deliveryState, .providerAccepted)
    }

    /// A Claude write whose turn ends without its own `.completed` result stays uncertain.
    func testClaudeWrittenTurnCancelledLeavesDeliveryUnknown() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-unknown")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "partial")
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("cancel me")
        session.recoveryAdmissionMode = .mandatory

        _ = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "cancel me",
            initialMessageForRun: "cancel me",
            attachments: [],
            inputConstituents: [identity]
        )
        let agentTask = session.agentTask
        let turnID = await controller.waitForPendingTurnCompletion()
        await controller.emitCancelledTurnCompletion(turnID: turnID)
        await agentTask?.value

        let unknown = await fixture.waitForIntent(identity, state: .deliveryUnknown)
        XCTAssertEqual(unknown?.deliveryState, .deliveryUnknown, "A written turn without its own completion is never requeued")
    }

    /// The central Claude send seam never sends a handoff under a different run attempt than the
    /// one it was recorded against; the same intent returns to `queued`.
    func testClaudeSendSeamRefusesStaleRunAttemptWithZeroWrites() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-stale")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: fixture.sessionID))
        session.recoveryLane = fixture.lane
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("steer")
        // Begin the attempt after binding so its ownership carries this lane's session ID.
        let ownership = session.beginRunAttempt(source: "test.bound")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: session.runID
        ).get()

        // The run attempt changes after the dispatch commit (post-await staleness).
        session.beginRunAttempt(source: "test.successor")
        let sent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "steer",
            attachments: [],
            handoff: handoff
        )
        _ = await handoff.evidence.settled()

        XCTAssertFalse(sent)
        XCTAssertFalse(recorder.contains("claude:send"), "No provider write may happen")
        XCTAssertEqual(handoff.observation, .notHandedOff)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    /// An injected recovery store write failure at the dispatch commit blocks the send. The commit
    /// is deferred until after provider preparation (adopted plan §5), so the runner is admitted and
    /// the session prepared, but nothing reaches the provider: no write, no delivery attempt, the
    /// same intent stays `queued`, and it is presented as held with the failure's explanation.
    func testStartRunDispatchWriteFailureNeverReachesProviderAndKeepsInputSaved() async throws {
        let fixture = try await FailableRecoveryLaneFixture.make("route-write-failure")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "never")
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("write fails")
        let intentID = try XCTUnwrap(identity.intentID)
        session.recoveryAdmissionMode = .mandatory
        fixture.failures.shouldFailWrites = true

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "write fails",
            initialMessageForRun: "write fails",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome, "Validation passes; the dispatch commit happens in the runner")
        await session.agentTask?.value

        XCTAssertFalse(recorder.contains("claude:send"))
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty)
        let heldReason = fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID]
        XCTAssertNotNil(heldReason, "The blocked input is presented as held")
        XCTAssertTrue(
            session.items.contains { $0.kind == .error && $0.text == heldReason },
            "The transcript explains why it was not sent"
        )
        fixture.failures.shouldFailWrites = false
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.intentID, identity.intentID)
        XCTAssertEqual(intent?.deliveryState, .queued)
        let attempts = await fixture.attempts(for: identity)
        XCTAssertTrue(attempts.isEmpty, "The failed write recorded no delivery attempt")
    }

    /// A written Claude turn whose run attempt ended (delivery unknown) is still accepted by that
    /// same turn's late `.completed` from the writing controller, and only that turn: a successor
    /// attempt's handoff is untouched, and the same turn ID from another controller is ignored.
    func testClaudeLateCompletionRefinesEndedAttemptToAcceptedWithoutTouchingSuccessor() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-late-accept")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "ok")
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: fixture.sessionID))
        session.recoveryLane = fixture.lane
        harness.host.test_installLiveSession(session)
        let coordinator = harness.host.claudeCoordinator

        let first = try await fixture.queuedIdentity("first")
        let firstOwnership = session.beginRunAttempt(source: "test.first")
        let firstHandoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [first],
            ownership: firstOwnership,
            processRunID: session.runID
        ).get()
        let firstSent = await coordinator.sendClaudeNativeMessage(
            session: session,
            text: "first",
            attachments: [],
            handoff: firstHandoff
        )
        XCTAssertTrue(firstSent)
        let firstTurnID = await controller.waitForPendingTurnCompletion()

        // The first attempt finalizes without its turn's completion: uncertain, still associated.
        coordinator.settleWrittenDispatchHandoffs(tabID: session.tabID, runAttemptID: firstOwnership.attemptID)
        let unknown = await fixture.waitForIntent(first, state: .deliveryUnknown)
        XCTAssertEqual(unknown?.deliveryState, .deliveryUnknown)
        XCTAssertEqual(coordinator.test_writtenDispatchHandoffCount, 1)

        // A successor attempt writes its own message on the same controller.
        let second = try await fixture.queuedIdentity("second")
        let secondOwnership = session.beginRunAttempt(source: "test.successor")
        let secondHandoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [second],
            ownership: secondOwnership,
            processRunID: session.runID
        ).get()
        let secondSent = await coordinator.sendClaudeNativeMessage(
            session: session,
            text: "second",
            attachments: [],
            handoff: secondHandoff
        )
        XCTAssertTrue(secondSent)
        let secondTurnID = await controller.waitForPendingTurnCompletion()
        XCTAssertNotEqual(secondTurnID, firstTurnID)

        // The same turn ID reported by a different controller is not this write's evidence.
        coordinator.noteClaudeTurnCompleted(turnID: firstTurnID, status: .completed, isEmittedBy: { _ in false })
        _ = await firstHandoff.evidence.settled()
        XCTAssertEqual(firstHandoff.observation, .deliveryUnknown)

        // The writing controller's late completion of that same turn refines it to accepted.
        coordinator.noteClaudeTurnCompleted(turnID: firstTurnID, status: .completed, isEmittedBy: { $0 === controller })
        _ = await firstHandoff.evidence.settled()
        XCTAssertEqual(firstHandoff.observation, .accepted)
        let accepted = await fixture.intent(first)
        XCTAssertEqual(accepted?.deliveryState, .providerAccepted)
        let successor = await fixture.intent(second)
        XCTAssertEqual(successor?.deliveryState, .dispatching, "The successor's delivery is unchanged")
        XCTAssertEqual(secondHandoff.observation, .open)
        let successorAttempts = await fixture.attempts(for: second)
        XCTAssertEqual(successorAttempts.map(\.runAttemptID), [secondOwnership.attemptID])
        XCTAssertEqual(coordinator.test_writtenDispatchHandoffCount, 1, "Only the successor's write is still tracked")

        // Once no router can deliver the controller's events, the association ends (unknown).
        coordinator.releaseWrittenDispatchHandoffs(tabID: session.tabID) { _ in false }
        XCTAssertEqual(coordinator.test_writtenDispatchHandoffCount, 0)
        coordinator.noteClaudeTurnCompleted(turnID: secondTurnID, status: .completed, isEmittedBy: { $0 === controller })
        _ = await secondHandoff.evidence.settled()
        XCTAssertEqual(secondHandoff.observation, .deliveryUnknown)
        let released = await fixture.intent(second)
        XCTAssertEqual(released?.deliveryState, .deliveryUnknown)
    }

    /// End to end through the event router: the run is cancelled after the write while its router
    /// reads the controller's stream (its attempt finalizes as delivery-unknown), then the same
    /// controller's late `.completed` for that turn arrives as between-run output and refines the
    /// stored intent to accepted.
    ///
    /// The run subscribes its router only after the send; a cancellation before that subscription
    /// leaves the detached controller's stream unread until the controller is shut down, so this
    /// test first waits until the run's router delivered the write's own output.
    func testClaudeLateCompletionAfterCancelledRunIsAcceptedThroughTheRouter() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-late-router")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "partial")
        let harness = makeHarness(
            recorder: recorder,
            claudeController: controller,
            handleHeadlessStreamResult: { result in
                if result.type == "assistant", let text = result.text {
                    recorder.record("run-stream:\(text)")
                }
            },
            autoSignalACPRouting: true
        )
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("late")
        session.recoveryAdmissionMode = .mandatory

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "late",
            initialMessageForRun: "late",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome)
        let agentTask = session.agentTask
        let turnID = await controller.waitForPendingTurnCompletion()
        // Precondition: the run's router consumes this controller's stream (it delivered the
        // write's own output to the run).
        for _ in 0 ..< 300 where !recorder.contains("run-stream:partial") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(recorder.contains("run-stream:partial"), "The run's router must be reading the stream before the cancel")

        await harness.service.cancelRun(tabID: session.tabID, session: session, cause: .userCancel)
        await agentTask?.value
        let unknown = await fixture.waitForIntent(identity, state: .deliveryUnknown)
        XCTAssertEqual(unknown?.deliveryState, .deliveryUnknown, "The ended attempt never proved acceptance")

        await controller.emitCompletedTurnCompletion(turnID: turnID)
        let accepted = await fixture.waitForIntent(identity, state: .providerAccepted)
        XCTAssertEqual(accepted?.deliveryState, .providerAccepted)
        XCTAssertEqual(accepted?.intentID, identity.intentID)
    }

    /// Uncertain durable delivery neither replays (didSend false) nor consumes (didSend true) the
    /// staged input; untracked input keeps its legacy outcome.
    func testStagedInputDispositionHoldsUncertainDurableDelivery() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-staged-input")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()

        let notStarted = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [fixture.queuedIdentity("a")],
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertEqual(notStarted.stagedInputDisposition(sent: false), .notSent)

        let uncertain = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [fixture.queuedIdentity("b")],
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertTrue(uncertain.enterProviderBoundary(in: session))
        XCTAssertEqual(uncertain.stagedInputDisposition(sent: false), .deliveryUnknown, "Started but unresolved")
        uncertain.noteDeliveryUnknown()
        XCTAssertEqual(uncertain.stagedInputDisposition(sent: false), .deliveryUnknown)
        XCTAssertEqual(uncertain.stagedInputDisposition(sent: true), .sent)

        let provenNotWritten = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [fixture.queuedIdentity("c")],
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertTrue(provenNotWritten.enterProviderBoundary(in: session))
        provenNotWritten.noteProvenNotWritten()
        XCTAssertEqual(provenNotWritten.stagedInputDisposition(sent: false), .notSent)

        let legacySession = AgentTabSession(tabID: UUID())
        let legacy = await AgentProviderHandoff.inactiveForTesting(in: legacySession)
        XCTAssertTrue(legacy.enterProviderBoundary(in: legacySession))
        legacy.noteDeliveryUnknown()
        XCTAssertEqual(legacy.stagedInputDisposition(sent: false), .notSent, "Inactive admission keeps its legacy outcome")
        for handoff in [notStarted, uncertain, provenNotWritten] {
            handoff.settleIfUnresolved()
            _ = await handoff.evidence.settled()
        }
    }

    /// A controller send failure that is not proven pre-write leaves the intent uncertain.
    func testClaudeAmbiguousSendFailureRecordsDeliveryUnknown() async throws {
        let fixture = try await RecoveryLaneFixture.make("route-claude-send-failure")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, failSend: true)
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: fixture.sessionID))
        session.recoveryLane = fixture.lane
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("ambiguous")
        let ownership = session.beginRunAttempt(source: "test.bound")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: session.runID
        ).get()

        let sent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "ambiguous",
            attachments: [],
            handoff: handoff
        )
        _ = await handoff.evidence.settled()

        XCTAssertFalse(sent)
        XCTAssertTrue(recorder.contains("claude:send"))
        XCTAssertEqual(handoff.observation, .deliveryUnknown)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .deliveryUnknown)
    }

    // MARK: R06 lane and reset freeze at dispatch

    /// A dispatch commit is refused while reset preparation froze the lane.
    func testDispatchIsRefusedWhileResetPreparationFreezesLane() async throws {
        let fixture = try await RecoveryLaneFixture.make("r06-dispatch-refused-frozen")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("frozen")
        guard case .success = await fixture.lane.prepareForTranscriptReset() else {
            return XCTFail("Reset preparation of an idle lane succeeds")
        }
        defer { fixture.lane.endTranscriptResetPreparation() }

        let begun = await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        )

        guard case .failure(.refused(.resetPreparationInProgress)) = begun else {
            return XCTFail("Expected a reset-preparation refusal, got \(begun)")
        }
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued, "Nothing was committed")
    }

    /// Reset preparation that starts while a dispatch commit is in flight joins it (drain), and the
    /// commit that lands under the freeze is settled back to `queued` and never handed off.
    func testResetPreparationJoinsInFlightDispatchCommitWhichSettlesWithoutHandoff() async throws {
        let fixture = try await RecoveryLaneFixture.make("r06-dispatch-joins-reset-drain")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("in flight")
        let lane = fixture.lane

        // Hold the lane's transaction gate so the dispatch commit suspends inside the drain.
        let gate = DispatchCommitGate()
        let holder = Task { _ = await lane.transaction { _, _ in await gate.waitOnce() } }
        let gateHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(gateHeld)
        let dispatch = Task {
            await AgentProviderHandoff.begin(session: session, constituents: [identity], ownership: nil, processRunID: nil)
        }
        let inFlight = await RecoveryTestSupport.eventually { lane.hasInFlightAdmissions }
        XCTAssertTrue(inFlight, "The dispatch commit is in flight")
        let reset = Task { await lane.prepareForTranscriptReset() }
        let frozen = await RecoveryTestSupport.eventually { lane.isResetPreparationActive }
        XCTAssertTrue(frozen)

        gate.release()
        _ = await holder.value
        let begun = await dispatch.value
        let prepared = await reset.value
        defer { lane.endTranscriptResetPreparation() }

        guard case .failure(.dispatchStaleAfterCommit(settledToQueue: true)) = begun else {
            return XCTFail("The commit landing under the freeze is stale and settled, got \(begun)")
        }
        guard case .success = prepared else {
            return XCTFail("Reset preparation completes after joining the dispatch, got \(prepared)")
        }
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued, "The same intent is back in the queue, never sent")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.count, 1, "The committed attempt is kept as pre-handoff evidence")
    }

    /// A committed dispatch whose lane froze before the provider boundary is never handed off: the
    /// final synchronous check settles it back to `queued` and releases its staged input.
    func testFinalProviderBoundaryCheckRefusesHandoffAfterResetFreeze() async throws {
        let fixture = try await RecoveryLaneFixture.make("r06-final-boundary")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("committed then frozen")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: nil,
            processRunID: nil
        ).get()
        guard case .success = await fixture.lane.prepareForTranscriptReset() else {
            return XCTFail("Reset preparation succeeds")
        }
        defer { fixture.lane.endTranscriptResetPreparation() }

        XCTAssertFalse(handoff.enterProviderBoundary(in: session), "No handoff once the lane is frozen")
        handoff.settleIfUnresolved()
        _ = await handoff.evidence.settled()

        XCTAssertEqual(handoff.observation, .notHandedOff)
        XCTAssertEqual(handoff.stagedInputDisposition(sent: false), .notSent)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    /// The Claude route runs the final check: a lane frozen after the commit never reaches the
    /// controller's send.
    func testClaudeRouteDoesNotSendWhenLaneFrozeAfterDispatchCommit() async throws {
        let fixture = try await RecoveryLaneFixture.make("r06-claude-route")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: fixture.sessionID))
        session.recoveryLane = fixture.lane
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("frozen before send")
        let ownership = session.beginRunAttempt(source: "test.bound")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: session.runID
        ).get()
        guard case .success = await fixture.lane.prepareForTranscriptReset() else {
            return XCTFail("Reset preparation succeeds")
        }
        defer { fixture.lane.endTranscriptResetPreparation() }

        let sent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "frozen before send",
            attachments: [],
            handoff: handoff
        )
        _ = await handoff.evidence.settled()

        XCTAssertFalse(sent)
        XCTAssertFalse(recorder.contains("claude:send"), "The provider was never called")
        XCTAssertEqual(handoff.observation, .notHandedOff)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
    }

    // MARK: R03 deferred dispatch commit (adopted plan §5)

    /// A pending-handoff payload that the Claude session preparation leaves for this send is
    /// staged, its exact snapshot attached to the still-`queued` carrier, and only then is the
    /// dispatch committed; the write carries exactly the recorded prefix. The store refuses an
    /// attach once any delivery attempt exists, so an attached snapshot next to the dispatching
    /// attempt proves the order.
    func testClaudeDurableStartAttachesPreparationPrefixToQueuedCarrierBeforeDispatchCommit() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-claude-prefix")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "ok")
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("hello")
        session.recoveryAdmissionMode = .mandatory
        let payloadID = UUID()
        session.pendingHandoff = AgentPendingHandoffState(payload: "CLAUDE-HISTORY", payloadID: payloadID)

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "hello",
            initialMessageForRun: "hello",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome)
        let agentTask = session.agentTask
        _ = await controller.waitForPendingTurnCompletion()

        let sent = await controller.recordedSentMessages()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent.first?.contains("CLAUDE-HISTORY\n\nhello") == true, "The write carries the attached prefix")
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .dispatching)
        XCTAssertEqual(intent?.pendingHandoff?.payloadID, payloadID)
        XCTAssertEqual(intent?.pendingHandoff?.prependedText, "CLAUDE-HISTORY\n\n")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.count, 1)

        await controller.emitPendingTurnCompletion()
        await agentTask?.value
        let accepted = await fixture.waitForIntent(identity, state: .providerAccepted)
        XCTAssertEqual(accepted?.deliveryState, .providerAccepted)
    }

    /// If the prefix cannot be attached to the carrier before the commit, the send is blocked: no
    /// provider write, no delivery attempt, the intent stays `queued` with its saved input, it is
    /// held with an explanation, and the payload is released for a later send — never sent without
    /// its history.
    func testClaudeDurableStartIsBlockedWithInputSavedWhenItsPrefixCannotBeAttached() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-claude-blocked")
        defer { fixture.tearDown() }
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder, emittedAssistantTextOnSend: "never")
        let harness = makeHarness(recorder: recorder, claudeController: controller, autoSignalACPRouting: true)
        let session = fixture.boundTabSession()
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("needs history")
        let intentID = try XCTUnwrap(identity.intentID)
        session.recoveryAdmissionMode = .mandatory
        // The carrier already records a different prefix, so this payload's snapshot cannot attach.
        let recorded = AgentRecoveryPendingHandoffSnapshot(
            payloadID: UUID(),
            payload: "OTHER",
            createdAt: nil,
            sourceItemID: nil,
            prependedText: "OTHER\n\n"
        )
        guard case .success = await fixture.lane.attachPendingHandoff(intentID: intentID, snapshot: recorded) else {
            return XCTFail("Attaching to a queued intent succeeds")
        }
        session.pendingHandoff = AgentPendingHandoffState(payload: "CLAUDE-HISTORY", payloadID: UUID())

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "needs history",
            initialMessageForRun: "needs history",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome)
        await session.agentTask?.value

        XCTAssertFalse(recorder.contains("claude:send"), "Never sent without its handoff")
        let sent = await controller.recordedSentMessages()
        XCTAssertTrue(sent.isEmpty)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
        XCTAssertEqual(intent?.pendingHandoff, recorded, "The recorded snapshot is never replaced")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(
            fixture.coordinator.heldIntentSessions[fixture.sessionID]?.reasons[intentID],
            AgentPendingHandoffDispatchStaging.blockedReason
        )
        XCTAssertTrue(session.items.contains { $0.text == AgentPendingHandoffDispatchStaging.blockedReason })
        XCTAssertEqual(session.pendingHandoff.payload, "CLAUDE-HISTORY", "The payload stays pending")
        // The harness's stage-outcome hook records instead of releasing: its stage is reported as
        // not sent (released for a later send), never as sent.
        XCTAssertTrue(recorder.contains("handoff:false"), "Its stage was released")
        XCTAssertFalse(recorder.contains("handoff:true"))
    }

    /// ACP `session/load` fails and the runner falls back to a new session: the recovery handoff
    /// created by that fallback is staged, attached to the still-`queued` carrier, and then the
    /// dispatch is committed in `runPromptTurn`; the prompt carries exactly that prefix.
    func testACPLoadFallbackRecoveryHandoffIsAttachedToCarrierBeforeDispatchCommit() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-acp-fallback")
        defer { fixture.tearDown() }
        let workspace = try RecoveryTestSupport.makeTemporaryRoot("r03-acp-fallback-workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let recordURL = workspace.appendingPathComponent("acp-record.jsonl")
        let provider = try R03LoadFallbackACPProvider(
            commandPath: R03LoadFallbackACPProvider.writeScript(in: workspace).path,
            environment: ["ACP_RECORD_PATH": recordURL.path]
        )
        let recorder = LifecycleRecorder()
        let payloadID = UUID()
        let harness = makeHarness(
            recorder: recorder,
            workspacePathProvider: { _ in workspace.path },
            acpProviderFactory: { _, _ in provider },
            stageResumeRecoveryHandoffIfNeeded: { session in
                recorder.record("stage-resume-recovery")
                session.pendingHandoff = AgentPendingHandoffState(payload: "RECOVERY-HISTORY", payloadID: payloadID)
            },
            stagesDurablePendingHandoffThroughHost: true
        )
        let session = fixture.boundTabSession()
        session.selectedAgent = .cursor
        session.providerSessionID = "stale-session-id"
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity("hello")
        session.recoveryAdmissionMode = .mandatory

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "hello",
            initialMessageForRun: "hello",
            attachments: [],
            inputConstituents: [identity]
        )
        XCTAssertNil(outcome)
        await session.agentTask?.value

        XCTAssertTrue(recorder.contains("stage-resume-recovery"), "The load failure fell back to a new session")
        let prompts = R03LoadFallbackACPProvider.recordedPromptTexts(at: recordURL)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.contains("RECOVERY-HISTORY\n\nhello") == true, "The prompt carries the attached prefix")
        let intent = await fixture.waitForIntent(identity, state: .providerAccepted)
        XCTAssertEqual(intent?.deliveryState, .providerAccepted)
        XCTAssertEqual(intent?.pendingHandoff?.payloadID, payloadID)
        XCTAssertEqual(intent?.pendingHandoff?.prependedText, "RECOVERY-HISTORY\n\n")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.count, 1)
    }
}

// MARK: Phase 4 pre-byte baseline admission (coordinator → host → managed write)

/// Records the host's baseline admissions for the coordinator composition tests; an optional gate
/// holds the admission (a slow baseline commit) and `result` is the host's verdict.
@MainActor
private final class BaselineAdmissionProbe {
    var identities: [AgentDispatchBaselineIdentity?] = []
    var claims: [AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage?] = []
    var owners: [AgentRuntimeSessionScope] = []
    var result = AgentRuntimeWriteAdmission.admittedWithoutIdentity
    /// When set, admits with the received claim's UUID (a newly committed claim).
    var mintsReceivedClaim = false
    var gate: LifecycleAsyncGate?
}

@MainActor
extension AgentModeRunServiceLifecycleTests {
    private struct BaselineRoute {
        let fixture: RecoveryLaneFixture
        let recorder: LifecycleRecorder
        let controller: LifecycleFakeNativeController
        let harness: LifecycleHarness
        let session: AgentTabSession
        let identity: AgentQueuedInputIdentity
        let ownership: AgentRunOwnership
        let handoff: AgentProviderHandoff
        let probe: BaselineAdmissionProbe

        func send(_ text: String) async -> Bool {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: text,
                attachments: [],
                handoff: handoff
            )
        }
    }

    /// The existing route harness with a managed-transport fake (evaluates the task-local write
    /// admission before its recorded write) and the host's baseline admission observed.
    private func makeBaselineRoute(_ name: String, text: String, eligible: Bool = false) async throws -> BaselineRoute {
        let fixture = try await RecoveryLaneFixture.make(name)
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            invokesWriteAdmission: true,
            outboundIdentityEligible: eligible
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: fixture.sessionID))
        session.recoveryLane = fixture.lane
        harness.host.test_installLiveSession(session)
        let identity = try await fixture.queuedIdentity(text)
        let ownership = session.beginRunAttempt(source: "test.baseline")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: session.runID
        ).get()
        let probe = BaselineAdmissionProbe()
        harness.host.test_claudeDispatchBaselineAdmission = { [probe, recorder] identity, claim, _ in
            probe.identities.append(identity)
            probe.claims.append(claim)
            probe.owners.append(AgentRuntimeOperationOwner.current)
            recorder.record("host:baseline")
            if let gate = probe.gate {
                await gate.arriveAndWait()
            }
            if probe.mintsReceivedClaim, let claim {
                return .admitted(outboundUserMessageUUID: claim.uuid)
            }
            return probe.result
        }
        return BaselineRoute(
            fixture: fixture,
            recorder: recorder,
            controller: controller,
            harness: harness,
            session: session,
            identity: identity,
            ownership: ownership,
            handoff: handoff,
            probe: probe
        )
    }

    /// A slow baseline commit holds the write: nothing reaches the provider until the host admits.
    func testClaudeBaselineAdmissionHoldsTheWriteUntilItsCommitIsReleased() async throws {
        let route = try await makeBaselineRoute("p4-baseline-delayed", text: "held")
        defer { route.fixture.tearDown() }
        let gate = LifecycleAsyncGate()
        route.probe.gate = gate

        let sending = Task { await route.send("held") }
        await gate.waitUntilArrived()

        XCTAssertTrue(route.recorder.contains("claude:admission"))
        XCTAssertTrue(route.recorder.contains("host:baseline"), "The coordinator's admission reached the host")
        XCTAssertFalse(route.recorder.contains("claude:send"), "Zero bytes while the baseline is pending")
        let sentWhileHeld = await route.controller.recordedSentMessages()
        XCTAssertTrue(sentWhileHeld.isEmpty)

        await gate.release()
        let sent = await sending.value

        XCTAssertTrue(sent)
        let events = route.recorder.events
        let baselineIndex = try XCTUnwrap(events.firstIndex(of: "host:baseline"))
        let writeIndex = try XCTUnwrap(events.firstIndex(of: "claude:send"))
        XCTAssertLessThan(baselineIndex, writeIndex, "The baseline admission precedes the write")
        let sentAfterRelease = await route.controller.recordedSentMessages()
        XCTAssertEqual(sentAfterRelease.count, 1)
        XCTAssertEqual(route.probe.identities.count, 1, "One admission per write")
    }

    /// A baseline that cannot be committed refuses the write: zero bytes, a proven non-write (the
    /// same intent back to `queued`, not handed off), and the refusal is explained.
    func testClaudeBaselineCommitFailureRefusesTheWriteAsProvenNotWritten() async throws {
        let route = try await makeBaselineRoute("p4-baseline-refused", text: "refused", eligible: true)
        defer { route.fixture.tearDown() }
        route.probe.result = .denied

        let sent = await route.send("refused")
        _ = await route.handoff.evidence.settled()

        XCTAssertFalse(sent)
        XCTAssertTrue(route.recorder.contains("claude:admission-refused"))
        XCTAssertFalse(route.recorder.contains("claude:send"), "No provider write")
        let sentMessages = await route.controller.recordedSentMessages()
        XCTAssertTrue(sentMessages.isEmpty)
        XCTAssertEqual(route.handoff.observation, .notHandedOff)
        let intent = await route.fixture.intent(route.identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
        XCTAssertTrue(
            route.session.items.contains { $0.kind == .error && $0.text == ClaudeAgentModeCoordinator.dispatchBaselineRefusedText },
            "The transcript explains the pre-send refusal"
        )
    }

    /// Supersession or cancellation while the baseline is pending writes nothing even though the
    /// host then admits: the coordinator revalidates after the await, and the managed write checks
    /// cancellation after the admission.
    func testClaudeBaselineAdmissionSupersededOrCancelledWhileAwaitingWritesNothing() async throws {
        enum Cut: CaseIterable { case superseded, cancelled }
        for cut in Cut.allCases {
            let route = try await makeBaselineRoute("p4-baseline-\(cut)", text: "\(cut)", eligible: true)
            defer { route.fixture.tearDown() }
            let gate = LifecycleAsyncGate()
            route.probe.gate = gate
            // The host even mints a claim: a stale or cancelled write still sends zero bytes.
            route.probe.mintsReceivedClaim = true

            let sending = Task { await route.send("\(cut)") }
            await gate.waitUntilArrived()
            switch cut {
            case .superseded:
                route.session.beginRunAttempt(source: "test.successor")
            case .cancelled:
                sending.cancel()
            }
            await gate.release()
            let sent = await sending.value
            _ = await route.handoff.evidence.settled()

            XCTAssertFalse(sent, "\(cut)")
            XCTAssertTrue(
                route.recorder.contains(cut == .superseded ? "claude:admission-refused" : "claude:admission-cancelled"),
                "\(cut): \(route.recorder.events)"
            )
            XCTAssertFalse(route.recorder.contains("claude:send"), "\(cut): no provider write")
            let sentMessages = await route.controller.recordedSentMessages()
            XCTAssertTrue(sentMessages.isEmpty, "\(cut)")
            let frames = await route.controller.recordedUserFrames()
            XCTAssertTrue(frames.isEmpty, "\(cut): zero bytes")
            XCTAssertEqual(route.handoff.observation, .notHandedOff, "\(cut)")
            let intent = await route.fixture.intent(route.identity)
            XCTAssertEqual(intent?.deliveryState, .queued, "\(cut)")
            XCTAssertFalse(
                route.session.items.contains { $0.text == ClaudeAgentModeCoordinator.dispatchBaselineRefusedText },
                "\(cut): the host admitted; this is not a baseline refusal"
            )
        }
    }

    /// The host receives exactly the committed dispatch's immutable identity (first delivery
    /// attempt, its run attempt, its user items), and the admission runs under the owner scope the
    /// dispatch captured.
    func testClaudeBaselineAdmissionReceivesTheExactCommittedDispatchIdentityAndOwner() async throws {
        let route = try await makeBaselineRoute("p4-baseline-identity", text: "identity")
        defer { route.fixture.tearDown() }
        let expectedOwner = route.session.runtimeSessionScope

        let sent = await route.send("identity")

        XCTAssertTrue(sent)
        let attempts = await route.fixture.attempts(for: route.identity)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempts.count, 1)
        let expected = AgentDispatchBaselineIdentity(
            dispatchID: attempt.attemptID,
            runAttemptID: route.ownership.attemptID,
            userItemIDs: [attempt.userItemID],
            hasCompleteUserItems: true
        )
        XCTAssertEqual(route.probe.identities, [expected])
        XCTAssertEqual(route.handoff.dispatchBaselineIdentity, expected, "The identity is immutable after the write")
        XCTAssertNotEqual(expectedOwner, .unavailable, "The bound session has a managed scope")
        XCTAssertEqual(route.probe.owners, [expectedOwner], "The host's admission runs under the captured owner")
        let controllerOwners = await route.controller.recordedAdmissionOwners()
        XCTAssertEqual(controllerOwners, [expectedOwner])
    }

    /// Step 4d1: an eligible transport's single admission hands the host the claim fixed before any
    /// await (the dispatch's own ID and the digest of exactly the provider-bound text it writes); the
    /// frame carries that UUID only because this admission returned it.
    func testClaudeOutboundIdentityRidesOnlyOnTheAdmissionThatCommittedItsClaim() async throws {
        let route = try await makeBaselineRoute("p4d1-outbound-claim", text: "claimed", eligible: true)
        defer { route.fixture.tearDown() }
        route.probe.mintsReceivedClaim = true

        let sent = await route.send("claimed")

        XCTAssertTrue(sent)
        let attempts = await route.fixture.attempts(for: route.identity)
        let dispatchID = try XCTUnwrap(attempts.first?.attemptID)
        let sentMessages = await route.controller.recordedSentMessages()
        let providerBoundText = try XCTUnwrap(sentMessages.first)
        XCTAssertEqual(sentMessages.count, 1)
        XCTAssertEqual(
            route.probe.claims,
            [.init(uuid: dispatchID, providerBoundText: providerBoundText)],
            "one admission; the claim is the dispatch ID over the exact provider-bound text"
        )
        let frames = await route.controller.recordedUserFrames()
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(frames.first)) as? [String: Any])
        XCTAssertEqual(frame["uuid"] as? String, dispatchID.uuidString.lowercased())
        let content = (frame["message"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, providerBoundText, "the digested text is the encoded text")
    }

    /// An ineligible transport offers no claim and writes the legacy frame, and an admission that
    /// minted nothing (re-entered / already recorded) omits the UUID even for an eligible one.
    func testClaudeOutboundIdentityIsOmittedWithoutAnEligibleLaunchOrANewClaim() async throws {
        let ineligible = try await makeBaselineRoute("p4d1-outbound-ineligible", text: "plain", eligible: false)
        defer { ineligible.fixture.tearDown() }
        ineligible.probe.mintsReceivedClaim = true
        let ineligibleSent = await ineligible.send("plain")
        XCTAssertTrue(ineligibleSent)
        XCTAssertEqual(ineligible.probe.claims, [nil], "no claim is offered for an ineligible launch")
        let ineligibleFrames = await ineligible.controller.recordedUserFrames()
        let plainFrame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ineligibleFrames.first)) as? [String: Any])
        XCTAssertNil(plainFrame["uuid"])

        let recorded = try await makeBaselineRoute("p4d1-outbound-recorded", text: "again", eligible: true)
        defer { recorded.fixture.tearDown() }
        recorded.probe.result = .admittedWithoutIdentity
        let recordedSent = await recorded.send("again")
        XCTAssertTrue(recordedSent)
        XCTAssertEqual(recorded.probe.claims.count, 1)
        XCTAssertNotNil(recorded.probe.claims.first ?? nil, "the claim was offered")
        let recordedFrames = await recorded.controller.recordedUserFrames()
        let retryFrame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recordedFrames.first)) as? [String: Any])
        XCTAssertNil(retryFrame["uuid"], "no new claim committed by this admission: no UUID, never a fresh one")
    }
}

// MARK: R03 deferred dispatch commit (unit)

extension AgentProviderHandoffTests {
    /// A run-start handoff writes nothing until `commitDispatch`, which attaches the noted snapshot
    /// to the still-`queued` carrier first and then commits under the bound run attempt.
    func testDeferredRunStartCommitsOnlyAfterAttachingItsNotedPrefix() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-deferred-commit")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("carrier")
        let handoff = try AgentProviderHandoff.prepareRunStart(session: session, constituents: [identity]).get()
        let ownership = session.beginRunAttempt(source: "test.deferred")

        guard case .success = await handoff.attachRunAttempt(ownership: ownership, processRunID: UUID(), session: session) else {
            return XCTFail("Binding a deferred handoff to its run attempt succeeds")
        }
        XCTAssertFalse(handoff.isCommitted)
        let beforeCommit = await fixture.attempts(for: identity)
        XCTAssertTrue(beforeCommit.isEmpty, "Nothing is written before the commit")
        let hasRunAttemptBeforeCommit = await fixture.hasRunAttempt(ownership.attemptID)
        XCTAssertFalse(hasRunAttemptBeforeCommit)

        let snapshot = AgentRecoveryPendingHandoffSnapshot(
            payloadID: UUID(),
            payload: "HISTORY",
            createdAt: nil,
            sourceItemID: nil,
            prependedText: "HISTORY\n\n"
        )
        handoff.notePendingHandoff(snapshot)
        guard case .success = await handoff.commitDispatch(session: session) else {
            return XCTFail("The deferred commit succeeds")
        }

        XCTAssertTrue(handoff.isCommitted)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.pendingHandoff, snapshot)
        XCTAssertEqual(intent?.deliveryState, .dispatching)
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.map(\.runAttemptID), [ownership.attemptID])
        XCTAssertTrue(handoff.enterProviderBoundary(in: session))
        handoff.noteAccepted()
        _ = await handoff.evidence.settled()
    }

    /// A deferred handoff that never committed reports no handoff and writes nothing; a provider
    /// boundary is refused before its commit.
    func testDeferredRunStartRefusesProviderBoundaryBeforeCommit() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-deferred-boundary")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let identity = try await fixture.queuedIdentity("uncommitted")
        let handoff = try AgentProviderHandoff.prepareRunStart(session: session, constituents: [identity]).get()

        XCTAssertFalse(handoff.enterProviderBoundary(in: session), "Uncommitted input never reaches a provider")
        XCTAssertEqual(handoff.observation, .notHandedOff)
        guard case .failure(.alreadySettled) = await handoff.commitDispatch(session: session) else {
            return XCTFail("A settled deferred handoff is never committed")
        }
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued)
        let attempts = await fixture.attempts(for: identity)
        XCTAssertTrue(attempts.isEmpty)
    }

    /// A payload created after a durable commit (late bootstrap) is detected; one that was already
    /// pending at the commit (retained for a later send) is not.
    func testPendingHandoffCreatedAfterCommitIsDistinguishedFromARetainedPayload() async throws {
        let fixture = try await RecoveryLaneFixture.make("r03-late-payload")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()

        let committed = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [fixture.queuedIdentity("no payload at commit")],
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertFalse(committed.pendingHandoffCreatedAfterCommit(in: session))
        session.pendingHandoff = AgentPendingHandoffState(payload: "LATE", payloadID: UUID())
        XCTAssertTrue(committed.pendingHandoffCreatedAfterCommit(in: session), "Late bootstrap payload")

        let retained = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [fixture.queuedIdentity("payload retained at commit")],
            ownership: nil,
            processRunID: nil
        ).get()
        XCTAssertFalse(retained.pendingHandoffCreatedAfterCommit(in: session), "Retained for a later send")

        for handoff in [committed, retained] {
            handoff.settleIfUnresolved()
            _ = await handoff.evidence.settled()
        }
    }
}

/// ACP provider whose session configuration loads the persisted session (so a failing
/// `session/load` exercises the runner's fallback to a new session).
private struct R03LoadFallbackACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID = .cursor
    let commandPath: String
    let environment: [String: String]

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: .cursor,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID, !resume.isEmpty {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }

    /// Fake ACP server: `session/load` always fails ("session not found"), `session/new` succeeds,
    /// and every `session/prompt` is recorded and answered with `end_turn`.
    static func writeScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("r03_load_fallback_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            record(method, params)
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/load":
                respond(request.get("id"), error={"code": -32602, "message": "session not found: " + str(params.get("sessionId"))})
            elif method == "session/new":
                respond(request.get("id"), {"sessionId": "r03-fresh-session"})
            elif method == "session/prompt":
                respond(request.get("id"), {"stopReason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 1}})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// The text blocks of every recorded `session/prompt`, in order.
    static func recordedPromptTexts(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["method"] as? String == "session/prompt",
                  let params = object["params"] as? [String: Any],
                  let blocks = params["prompt"] as? [[String: Any]]
            else { return nil }
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
    }
}

/// Suspends one lane transaction until released (holds the session's recovery gate).
@MainActor
private final class DispatchCommitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    private(set) var isWaiting = false

    func waitOnce() async {
        guard !used else { return }
        used = true
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
