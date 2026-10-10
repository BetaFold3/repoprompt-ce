import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Outbound attention-notification admission seam (Telegram attention contract, Slice 2):
/// Direction 1 kill conditions with stub delivery and deterministic pre-admission fences. Every
/// result here is stub/fixture evidence; nothing is sent over a network.
@MainActor
final class AttentionNotificationAdmissionTests: XCTestCase {
    // MARK: - Kill: queued successor chains

    func testQueuedFollowUpChainNotifiesOnlyTheFinalTurnWithItsOwnText() async throws {
        let fixture = makeFixture()
        var followUps: [String] = []
        let barrier = makeBarrier(fixture.vm, startFollowUpRun: { _, text in followUps.append(text) })
        let root = makeSession(fixture.vm)
        root.session.pendingInstructions = ["second"]

        let first = beginTurn(root.session, user: "first", assistant: "Intermediate answer A")
        let firstCommit = await barrier.commit(completedRequest(root.session, first, supportsFollowUp: true))
        let firstRevision = try XCTUnwrap(firstCommit)
        XCTAssertEqual(firstRevision.successorKind, .relatedFollowUp)
        XCTAssertEqual(followUps, ["second"])
        let firstKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)
        XCTAssertEqual(fixture.admission.records[firstKey], .suppressed(.successorTookOver))

        // The follow-up turn (as `startAgentRun` would run it) settles idle.
        let second = beginTurn(root.session, user: "second", assistant: "Final answer B")
        _ = await barrier.commit(completedRequest(root.session, second, supportsFollowUp: true))

        try await waitForAttempts(fixture.delivery, 1)
        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [.turnCompleted(sessionID: root.sessionID, attemptID: second.attemptID)])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Final answer B"))
        XCTAssertEqual(events.first?.sessionName, fixture.vm.resolvedSessionDisplayName(for: root.tabID))
        try await waitForRecord(fixture.admission, events[0].key) { $0 == .delivered(.sent) }
    }

    func testProviderSuccessorChainNotifiesOnlyTheSettledSuccessorTurn() async throws {
        let fixture = makeFixture()
        let barrier = makeBarrier(fixture.vm)
        let root = makeSession(fixture.vm)
        var consumed = 0
        let successor = AgentRunTerminalCommitBarrier.ProviderSuccessor(
            id: UUID(),
            transitionKind: .relatedFollowUp,
            consumeAfterPublication: { _, _ in
                consumed += 1
                return true
            }
        )

        let first = beginTurn(root.session, user: "first", assistant: "Intermediate provider answer")
        _ = await barrier.commit(completedRequest(root.session, first, providerSuccessor: successor))
        XCTAssertEqual(consumed, 1)
        XCTAssertEqual(
            fixture.admission.records[.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)],
            .suppressed(.successorTookOver)
        )

        let second = beginTurn(root.session, user: "queued", assistant: "Provider successor final")
        _ = await barrier.commit(completedRequest(root.session, second))

        try await waitForAttempts(fixture.delivery, 1)
        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [.turnCompleted(sessionID: root.sessionID, attemptID: second.attemptID)])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Provider successor final"))
    }

    /// A provider successor offered at commit but declined after an accepted publication never
    /// starts: the session settles idle on this completion, so it notifies (OracleB F1).
    func testDeclinedProviderSuccessorStillNotifiesTheSettledCompletion() async throws {
        let fixture = makeFixture()
        let barrier = makeBarrier(fixture.vm)
        let root = makeSession(fixture.vm)
        var offered = 0
        let successor = AgentRunTerminalCommitBarrier.ProviderSuccessor(
            id: UUID(),
            transitionKind: .relatedFollowUp,
            consumeAfterPublication: { _, _ in
                offered += 1
                return false
            }
        )

        let ownership = beginTurn(root.session, user: "go", assistant: "Final answer, no successor")
        let commit = await barrier.commit(completedRequest(root.session, ownership, providerSuccessor: successor))
        let revision = try XCTUnwrap(commit)
        XCTAssertEqual(revision.successorKind, .relatedFollowUp, "The successor was selected at commit")
        XCTAssertEqual(offered, 1)
        XCTAssertEqual(root.session.runState, .completed)
        XCTAssertNil(root.session.activeRunOwnership)

        let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [key])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Final answer, no successor"))
    }

    /// A completion without new assistant text never carries an earlier turn's text, and long final
    /// text is captured whole (splitting belongs to the transport) (OracleB F2).
    func testCompletionTextIsOnlyThatTurnsFinalTextAndLongTextIsCapturedWhole() async throws {
        let fixture = makeFixture()
        let barrier = makeBarrier(fixture.vm)
        let root = makeSession(fixture.vm)

        let longText = String(repeating: "0123456789", count: 2000) + " END"
        let first = beginTurn(root.session, user: "long", assistant: longText)
        _ = await barrier.commit(completedRequest(root.session, first))
        let firstKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)
        try await waitForRecord(fixture.admission, firstKey) { $0 == .delivered(.sent) }

        let second = beginTurn(root.session, user: "silent", assistant: nil)
        _ = await barrier.commit(completedRequest(root.session, second))
        let secondKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: second.attemptID)
        try await waitForRecord(fixture.admission, secondKey) { $0 == .delivered(.sent) }

        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [firstKey, secondKey])
        guard case let .turnCompleted(firstText)? = events.first?.content else {
            return XCTFail("Expected completion content")
        }
        XCTAssertEqual(firstText?.count, longText.count)
        XCTAssertEqual(firstText, longText)
        XCTAssertEqual(events.last?.content, .turnCompleted(finalAssistantText: nil))
    }

    /// The workspace name comes from the loaded workspace that owns the tab, not whichever
    /// workspace is active at the event (OracleB F3). No activation or persistence runs here.
    func testWorkspaceNameIsTheOwningWorkspaceEvenWhenAnotherIsActive() async throws {
        let fixture = makeFixture()
        let barrier = makeBarrier(fixture.vm)
        let root = makeSession(fixture.vm)
        let storage = FileManager.default.temporaryDirectory
        let owning = WorkspaceModel(
            name: "Owning Workspace",
            repoPaths: [storage.path],
            customStoragePath: storage,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: root.tabID, name: "Root tab")],
            activeComposeTabID: root.tabID
        )
        let other = WorkspaceModel(
            name: "Other Workspace",
            repoPaths: [storage.path],
            customStoragePath: storage,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: UUID(), name: "Other tab")]
        )
        let (manager, prompt) = makeWorkspaceManager(workspaces: [owning, other])
        fixture.vm.workspaceManager = manager

        var keys: [AttentionNotificationEventKey] = []
        for active in [owning, other] {
            manager.activeWorkspace = active
            let ownership = beginTurn(root.session, user: "go", assistant: "answer in \(active.name)")
            _ = await barrier.commit(completedRequest(root.session, ownership))
            let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
            try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
            keys.append(key)
        }

        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), keys)
        XCTAssertEqual(events.map(\.workspaceName), ["Owning Workspace", "Owning Workspace"])
        withExtendedLifetime((manager, prompt)) {}
    }

    /// A follow-up queued, or a new run attempt begun, after capture but before admission means the
    /// session did not settle idle on that completion.
    func testCompletionChangedWhilePausedBeforeAdmissionIsNeverDelivered() async throws {
        let scenarios: [(name: String, mutate: (AgentModeViewModel.TabSession) -> Void)] = [
            ("follow-up queued", { $0.pendingInstructions.append("late follow-up") }),
            ("new run attempt", { session in
                session.runState = .running
                session.beginRunAttempt(source: "test.attention.newAttempt")
            }),
            ("non-completed state", { $0.runState = .idle })
        ]
        for scenario in scenarios {
            let fence = AdmissionFence()
            let fixture = makeFixture(fence: fence)
            let barrier = makeBarrier(fixture.vm)
            let root = makeSession(fixture.vm)
            let ownership = beginTurn(root.session, user: "go", assistant: "done")
            _ = await barrier.commit(completedRequest(root.session, ownership))
            try await waitForPauses(fence, 1)

            scenario.mutate(root.session)
            fence.release()

            let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(.eventNoLongerCurrent), scenario.name)
            let attempts = await fixture.delivery.events.count
            XCTAssertEqual(attempts, 0, scenario.name)
        }
    }

    // MARK: - Kill: question resolved/rebound/disabled while paused before admission

    func testQuestionChangedWhilePausedBeforeAdmissionIsNeverDelivered() async throws {
        enum Change: String, CaseIterable {
            case answered, skipped, timedOut, cancelledByRunEnd, rebound, mcpControlled, disabled, disabledAndReenabled
        }
        for change in Change.allCases {
            let fence = AdmissionFence()
            let fixture = makeFixture(fence: fence)
            let root = makeSession(fixture.vm)
            let ownership = beginTurn(root.session, user: "ask", assistant: nil)
            let interaction = makeInteraction(timeoutSeconds: 60)
            let task = Task { try await fixture.vm.askUser(tabID: root.tabID, interaction: interaction) }
            try await waitForPauses(fence, 1)
            XCTAssertEqual(root.session.pendingAskUser?.interaction.id, interaction.id, change.rawValue)
            XCTAssertNotNil(
                root.session.pendingAskUser?.timeoutStartedAt,
                "\(change): the pending question carries its timeout start timestamp at capture"
            )

            var expected = AttentionNotificationSuppression.eventNoLongerCurrent
            switch change {
            case .answered:
                try fixture.vm.submitAskUserResponse(
                    tabID: root.tabID,
                    interactionID: interaction.id,
                    draftsByQuestionID: ["choice": AgentAskUserDraft(selectedOptionLabels: ["A"])]
                )
                _ = try await task.value
            case .skipped:
                fixture.vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
                _ = try await task.value
            case .timedOut:
                // Fire the production timeout path now, while admission is held, instead of racing
                // a short wall-clock timeout against the fence.
                fixture.vm.schedulePendingAskUserTimeout(
                    for: root.session,
                    interactionID: interaction.id,
                    timeoutSeconds: 0,
                    startedAt: Date()
                )
                try await waitUntil("question \(interaction.id) to time out") {
                    root.session.pendingAskUser?.interaction.id != interaction.id
                }
                let response = try await task.value
                XCTAssertTrue(response.timedOut)
            case .cancelledByRunEnd:
                _ = await fixture.vm.test_terminalCommitBarrier().commit(.init(
                    session: root.session,
                    ownership: ownership,
                    expectedRunID: root.session.runID,
                    terminalState: .cancelled,
                    source: "test.attention.cancel",
                    attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: false,
                    supportsFollowUp: false,
                    notifyTurnComplete: false
                ))
                XCTAssertNil(root.session.pendingAskUser)
                do {
                    _ = try await task.value
                    XCTFail("A question cancelled by the run end throws")
                } catch {}
            case .rebound:
                root.session.testInstallPersistentSessionBinding(sessionID: UUID())
            case .mcpControlled:
                fixture.vm.test_setMCPControlledTabIDs([root.tabID])
            case .disabled:
                fixture.admission.setEnabled(false)
                expected = .enableChanged
            case .disabledAndReenabled:
                fixture.admission.setEnabled(false)
                fixture.admission.setEnabled(true)
                expected = .enableChanged
            }
            fence.release()

            let key = AttentionNotificationEventKey.question(sessionID: root.sessionID, interactionID: interaction.id)
            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(expected), change.rawValue)
            let attempts = await fixture.delivery.events.count
            XCTAssertEqual(attempts, 0, change.rawValue)

            if root.session.pendingAskUser?.interaction.id == interaction.id {
                fixture.vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
                _ = try? await task.value
            }
        }
    }

    func testRootQuestionDeliversOnceWithEveryQuestionOptionAndExplicitFlags() async throws {
        let fence = AdmissionFence()
        let fixture = makeFixture(fence: fence)
        let root = makeSession(fixture.vm)
        let interaction = AgentAskUserInteraction(
            title: "Release plan",
            context: "Rollout constraints",
            timeoutSeconds: 60,
            questions: [
                AgentAskUserQuestion(
                    id: "strategy",
                    header: "Strategy",
                    question: "Which strategies?",
                    context: "Pick carefully",
                    options: [
                        AgentAskUserOption(label: "Canary", description: "One percent first"),
                        AgentAskUserOption(label: "Blue-green")
                    ],
                    allowsMultiple: true,
                    allowsCustom: false
                ),
                AgentAskUserQuestion(id: "notes", question: "Any notes?", allowsMultiple: false, allowsCustom: true),
                AgentAskUserQuestion(id: "risks", question: "List risks?", allowsMultiple: true, allowsCustom: true)
            ]
        )
        let task = Task { try await fixture.vm.askUser(tabID: root.tabID, interaction: interaction) }
        try await waitForPauses(fence, 1)
        fence.release()
        try await waitForAttempts(fixture.delivery, 1)

        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [.question(sessionID: root.sessionID, interactionID: interaction.id)])
        guard case let .question(lines)? = events.first?.content else {
            return XCTFail("Expected question content")
        }
        XCTAssertEqual(lines, [
            "Title: Release plan",
            "Context: Rollout constraints",
            "Questions:",
            "1. [id `strategy`] Strategy: Which strategies?",
            "   Context: Pick carefully",
            "   Selection: choose any number of options; custom answer not allowed",
            "   - Canary — One percent first",
            "   - Blue-green",
            "   Flags: allows_multiple=true; allows_custom=false",
            "2. [id `notes`] Any notes?",
            "   Selection: free-form answer; custom answer allowed",
            "   Flags: allows_multiple=false; allows_custom=true",
            "3. [id `risks`] List risks?",
            "   Selection: free-form answer; custom answer allowed",
            "   Flags: allows_multiple=true; allows_custom=true"
        ])

        fixture.vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
        _ = try await task.value
        try await waitForRecord(fixture.admission, events[0].key) { $0 == .delivered(.sent) }
        let attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 1)
    }

    func testChildOrphanAndMCPControlledQuestionsAreNeverDelivered() async throws {
        let fixture = makeFixture()
        // Orphaned controlled child: its parent is not live, so the question falls back to the user.
        let orphan = makeSession(fixture.vm, parent: UUID(), controlled: true)
        fixture.vm.test_setMCPControlledTabIDs([orphan.tabID])
        // Uncontrolled child (control expired) and a verified externally controlled root.
        let parent = makeSession(fixture.vm)
        let child = makeSession(fixture.vm, parent: parent.sessionID)
        let connectionID = UUID()
        let externalRoot = makeSession(fixture.vm, controlled: true, originatingConnectionID: connectionID)
        fixture.vm.test_setMCPControlledTabIDs([orphan.tabID, externalRoot.tabID])

        // Orphan with no MCP control context at all: its parent is simply not live.
        let uncontrolledOrphan = makeSession(fixture.vm, parent: UUID())

        let cases: [(LiveSession, AgentDelegatedQuestionControllerProvenance)] = [
            (orphan, .unverified),
            (uncontrolledOrphan, .unverified),
            (child, .unverified),
            (externalRoot, .init(verifiedNonAgentModeConnectionID: connectionID))
        ]
        for (live, provenance) in cases {
            let interaction = makeInteraction(timeoutSeconds: 60)
            let task = Task {
                try await fixture.vm.askUser(tabID: live.tabID, interaction: interaction, controllerProvenance: provenance)
            }
            let key = AttentionNotificationEventKey.question(sessionID: live.sessionID, interactionID: interaction.id)
            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(.ineligibleSession))
            fixture.vm.skipAskUser(tabID: live.tabID, interactionID: interaction.id)
            _ = try await task.value
        }
        XCTAssertEqual(orphanRouting(fixture.vm, orphan), .userFallback)
        let attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - Kill: at-most-once admission

    /// Exercises the admission record guard directly (terminal-barrier duplicate recovery never
    /// re-captures): one capture submitted twice behind the held fence delivers once, and a replay
    /// after the recorded outcome never reaches the fence or delivery again.
    func testSameCaptureSubmittedTwiceBehindFenceDeliversOnceAndReplayIsIgnored() async throws {
        let fence = AdmissionFence()
        let fixture = makeFixture(fence: fence)
        let key = AttentionNotificationEventKey.turnCompleted(sessionID: UUID(), attemptID: UUID())
        let capture = fixture.admission.makeCapture(
            event: AttentionNotificationEvent(
                key: key,
                workspaceName: "Workspace",
                sessionName: "Root",
                content: .turnCompleted(finalAssistantText: "done")
            ),
            isStillCurrent: { true }
        )

        fixture.admission.submit(capture)
        fixture.admission.submit(capture)
        try await waitForPauses(fence, 2)
        XCTAssertNil(fixture.admission.records[key], "Both submissions are held before admission")

        fence.release()
        // Each held submission admits synchronously right after passing the fence.
        try await waitUntil("both held submissions to reach admission") { fence.passedCount == 2 }
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
        var attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 1)

        fixture.admission.submit(capture)
        XCTAssertFalse(fixture.admission.admit(capture), "A replay after the outcome is never admitted")
        XCTAssertEqual(fixture.admission.records[key], .delivered(.sent))
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(fence.pauseCount, 2, "A replay after the outcome never schedules admission")
        attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fixture.admission.records[key], .delivered(.sent))
    }

    // MARK: - Eligibility and production wiring

    func testProductionBarrierDeliversColdStartedRootOnceAcrossRepeatedTerminalPublication() async throws {
        let fixture = makeFixture()
        let barrier = fixture.vm.test_terminalCommitBarrier()
        // A cold-started UI root: hydrated from disk, parentless, with no index entry.
        let root = makeSession(fixture.vm)
        XCTAssertEqual(fixture.vm.mcpDelegationLineage(for: root.session), .resolved(depth: 0))
        let ownership = beginTurn(root.session, user: "go", assistant: "Cold root answer")
        let request = completedRequest(root.session, ownership)

        _ = await barrier.commit(request)
        try await waitForAttempts(fixture.delivery, 1)
        let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }

        // Repeated terminal publication for the same ownership goes through duplicate recovery.
        _ = await barrier.commit(request)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [key])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Cold root answer"))
        XCTAssertEqual(fixture.admission.records.count, 1)
    }

    func testIneligibleOrUnfinishedCompletionsAreNeverDelivered() async throws {
        let fixture = makeFixture()
        let barrier = makeBarrier(fixture.vm)

        let parent = makeSession(fixture.vm)
        let child = makeSession(fixture.vm, parent: parent.sessionID)
        let controlledRoot = makeSession(fixture.vm, controlled: true, originatingConnectionID: UUID(), forceControlContext: true)
        fixture.vm.test_setMCPControlledTabIDs([controlledRoot.tabID])
        let knowledgeRoot = makeSession(fixture.vm, profile: .knowledge)
        let knowledgeWorker = makeSession(fixture.vm, parent: knowledgeRoot.sessionID, profile: .knowledge)
        // Unknown lineage: a second live record claims a parent nobody knows.
        let unknownLineage = makeSession(fixture.vm)
        let unknownClaim = try XCTUnwrap(fixture.vm.session(for: UUID(), createIfNeeded: true))
        unknownClaim.testInstallPersistentSessionBinding(sessionID: unknownLineage.sessionID)
        unknownClaim.parentSessionID = UUID()
        // Conflicting lineage: two live records claim different parents.
        let conflicting = makeSession(fixture.vm, parent: parent.sessionID)
        let conflictingClaim = try XCTUnwrap(fixture.vm.session(for: UUID(), createIfNeeded: true))
        conflictingClaim.testInstallPersistentSessionBinding(sessionID: conflicting.sessionID)
        conflictingClaim.parentSessionID = knowledgeRoot.sessionID
        // Unhydrated parentless record: lineage unknown, fails closed.
        let unhydrated = makeSession(fixture.vm, hydrated: false)
        // Orphan with no MCP control context: its parent is not live.
        let uncontrolledOrphan = makeSession(fixture.vm, parent: UUID())

        for live in [child, controlledRoot, knowledgeWorker, unknownLineage, conflicting, unhydrated, uncontrolledOrphan] {
            let ownership = beginTurn(live.session, user: "go", assistant: "ineligible")
            _ = await barrier.commit(completedRequest(live.session, ownership))
            XCTAssertEqual(
                fixture.admission.records[.turnCompleted(sessionID: live.sessionID, attemptID: ownership.attemptID)],
                .suppressed(.ineligibleSession)
            )
        }

        // Cancelled, failed, and non-notifying turns of an eligible root capture nothing.
        let root = makeSession(fixture.vm)
        for (state, notify) in [(AgentSessionRunState.cancelled, true), (.failed, true), (.completed, false)] {
            let ownership = beginTurn(root.session, user: "go", assistant: "partial")
            _ = await barrier.commit(completedRequest(root.session, ownership, state: state, notify: notify))
            XCTAssertNil(fixture.admission.records[.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)])
        }

        // A user-driven Knowledge root is a root.
        let ownership = beginTurn(knowledgeRoot.session, user: "research", assistant: "Knowledge answer")
        _ = await barrier.commit(completedRequest(knowledgeRoot.session, ownership))
        try await waitForAttempts(fixture.delivery, 1)
        let events = await fixture.delivery.events
        XCTAssertEqual(events.map(\.key), [.turnCompleted(sessionID: knowledgeRoot.sessionID, attemptID: ownership.attemptID)])
    }

    func testDisabledByDefaultAndIdleThreshold() async throws {
        XCTAssertFalse(AttentionNotificationAdmission.shared.acceptsCaptures, "Production stays disabled with no delivery")

        for (idle, expected) in [(TimeInterval(10), AttentionNotificationAdmission.Record.suppressed(.userActive)), (301, .delivered(.sent))] {
            let fixture = makeFixture(idleSeconds: { idle })
            let barrier = makeBarrier(fixture.vm)
            let root = makeSession(fixture.vm)
            let ownership = beginTurn(root.session, user: "go", assistant: "answer")
            _ = await barrier.commit(completedRequest(root.session, ownership))
            let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
            let record = try await waitForRecord(fixture.admission, key) { $0 != .admitted }
            XCTAssertEqual(record, expected, "idle \(idle)")
        }
    }

    // MARK: - Hanging and failing delivery

    func testHangingDeliveryNeverDelaysCommitSuccessorQuestionInstallationOrTimeout() async throws {
        let delivery = StubDelivery(mode: .hang)
        let fixture = makeFixture(delivery: delivery)
        var followUps: [String] = []
        let barrier = makeBarrier(fixture.vm, startFollowUpRun: { _, text in followUps.append(text) })
        let root = makeSession(fixture.vm)

        // Turn 1 settles idle and its delivery hangs.
        let first = beginTurn(root.session, user: "one", assistant: "first")
        _ = await barrier.commit(completedRequest(root.session, first, supportsFollowUp: true))
        try await waitForAttempts(delivery, 1)
        let firstKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)
        XCTAssertEqual(fixture.admission.records[firstKey], .admitted)

        // Turn 2 commits and starts its queued successor while turn 1's delivery still hangs.
        root.session.pendingInstructions = ["three"]
        let second = beginTurn(root.session, user: "two", assistant: "second")
        let revision = await barrier.commit(completedRequest(root.session, second, supportsFollowUp: true))
        XCTAssertNotNil(revision)
        XCTAssertEqual(followUps, ["three"])
        XCTAssertFalse(root.session.terminalCommitInProgress)

        // A question installs and its timeout completes while its own delivery remains fenced.
        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task { try await fixture.vm.askUser(tabID: root.tabID, interaction: interaction) }
        try await waitForAttempts(delivery, 2)
        XCTAssertEqual(root.session.pendingAskUser?.interaction.id, interaction.id)
        fixture.vm.schedulePendingAskUserTimeout(
            for: root.session,
            interactionID: interaction.id,
            timeoutSeconds: 0,
            startedAt: Date()
        )
        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertEqual(fixture.admission.records[firstKey], .admitted)

        await delivery.releaseHang()
        try await waitForRecord(fixture.admission, firstKey) { $0 == .delivered(.unknown) }
    }

    func testFailingDeliveryRecordsOneFailedAttemptWithoutRetry() async throws {
        let delivery = StubDelivery(mode: .fail)
        let fixture = makeFixture(delivery: delivery)
        let barrier = makeBarrier(fixture.vm)
        let root = makeSession(fixture.vm)
        let ownership = beginTurn(root.session, user: "go", assistant: "answer")
        let request = completedRequest(root.session, ownership)
        _ = await barrier.commit(request)

        let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.failed) }
        XCTAssertEqual(fixture.admission.lastDeliveryOutcome, .failed)
        _ = await barrier.commit(request)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let attempts = await delivery.events.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fixture.admission.records[key], .delivered(.failed))
    }

    // MARK: - Helpers

    private struct Fixture {
        let vm: AgentModeViewModel
        let admission: AttentionNotificationAdmission
        let delivery: StubDelivery
    }

    private struct LiveSession {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
    }

    private func makeFixture(
        delivery: StubDelivery = StubDelivery(mode: .succeed),
        fence: AdmissionFence? = nil,
        idleSeconds: @escaping @MainActor () -> TimeInterval? = { nil }
    ) -> Fixture {
        let vm = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )
        let admission = AttentionNotificationAdmission(environment: .init(
            delivery: delivery,
            idleSeconds: idleSeconds,
            beforeAdmission: { key in await fence?.pause(key) }
        ))
        admission.setEnabled(true)
        vm.attentionNotificationAdmission = admission
        // Failure cleanup: a bounded wait that fails throws mid-test, so release anything a test
        // could leave held — hung deliveries, fenced admissions, and still-pending questions.
        addTeardownBlock { @MainActor in
            await delivery.releaseHang()
            fence?.release()
            for (tabID, session) in vm.sessions {
                if let interactionID = session.pendingAskUser?.interaction.id {
                    vm.skipAskUser(tabID: tabID, interactionID: interactionID)
                }
            }
        }
        return Fixture(vm: vm, admission: admission, delivery: delivery)
    }

    private func makeSession(
        _ vm: AgentModeViewModel,
        parent: UUID? = nil,
        controlled: Bool = false,
        originatingConnectionID: UUID? = nil,
        forceControlContext: Bool = false,
        hydrated: Bool = true,
        profile: AgentSessionProfile = .standard
    ) -> LiveSession {
        let tabID = UUID()
        let sessionID = UUID()
        let session = vm.session(for: tabID, createIfNeeded: true)!
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parent
        session.hasLoadedPersistedState = hydrated
        if profile != .standard {
            XCTAssertTrue(session.adoptSessionProfile(profile))
        }
        if controlled, parent != nil || originatingConnectionID != nil || forceControlContext {
            session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: originatingConnectionID,
                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: originatingConnectionID),
                suppressUserNotifications: true,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: false,
                taskLabelKind: .engineer
            )
        }
        return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
    }

    /// Starts one run attempt with its user message and (optionally) its assistant reply.
    @discardableResult
    private func beginTurn(
        _ session: AgentModeViewModel.TabSession,
        user: String,
        assistant: String?
    ) -> AgentRunOwnership {
        if session.runID == nil {
            session.runID = UUID()
        }
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.attention")
        session.appendItem(.user(user, sequenceIndex: session.nextSequenceIndex))
        if let assistant {
            session.appendItem(.assistant(assistant, sequenceIndex: session.nextSequenceIndex))
        }
        return ownership
    }

    private func completedRequest(
        _ session: AgentModeViewModel.TabSession,
        _ ownership: AgentRunOwnership,
        state: AgentSessionRunState = .completed,
        notify: Bool = true,
        supportsFollowUp: Bool = false,
        providerSuccessor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = nil
    ) -> AgentRunTerminalCommitBarrier.Request {
        AgentRunTerminalCommitBarrier.Request(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: state,
            source: "test.attention",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false,
            supportsFollowUp: supportsFollowUp,
            providerSuccessor: providerSuccessor,
            notifyTurnComplete: notify
        )
    }

    /// A real terminal commit barrier whose attention hooks are the production view-model adapter;
    /// other hooks are inert so follow-up starts are only recorded.
    private func makeBarrier(
        _ vm: AgentModeViewModel,
        startFollowUpRun: @escaping (UUID, String) -> Void = { _, _ in }
    ) -> AgentRunTerminalCommitBarrier {
        AgentRunTerminalCommitBarrier(hooks: AgentModeRunService.Hooks(
            estimateRuntimeTokens: { $0.count },
            addUserInputTokensToActiveNonCodexTurn: { _, _ in },
            startNonCodexTurnAccountingIfNeeded: { _, _ in },
            reserveAttachmentsForTurn: { _, _ in nil },
            markAttachmentsConsumed: { _, _ in },
            stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
            consumeDeferredAttachmentCleanup: { _, _ in },
            finalizeAttachmentsForTurn: { _, _, _, _ in },
            finalizeAbandonedAttachmentsForTurn: { _ in },
            setAgentRunActive: { _, _ in },
            updateBindings: { _ in },
            requestUIRefresh: { _, _ in },
            scheduleSave: { _ in },
            notifyAgentTurnComplete: { _ in },
            handleHeadlessStreamResult: { _, _, _, _ in },
            buildHeadlessAgentMessage: { _, text, _, _ in AgentMessage(userMessage: text) },
            finalizeStreamingItems: { _ in },
            finalizePendingToolCalls: { _, _ in },
            finalizePendingToolCallsWithUpperBound: { _, _, _ in },
            finalizeNonCodexTurnUsage: { _, _, _, _ in },
            cancelPendingQuestion: { _ in },
            cancelPendingApproval: { _ in },
            cancelPendingApplyEditsReview: { _, _ in },
            cancelPendingWorktreeMergeReview: { _, _ in },
            flushPendingAssistantDelta: { _ in },
            clearPendingAssistantDelta: { _ in },
            prepareTerminalPublication: { _ in },
            makeTerminalPublicationEnvelope: { _, _, _, _ in nil },
            publishTerminalCommit: { _, _, _ in .accepted(successorEpoch: nil) },
            startFollowUpRun: startFollowUpRun,
            restoreDraftText: { _, _, _, _ in },
            augmentUserMessageForProviderSend: { text, _, _, _ in text },
            stageResumeRecoveryHandoffIfNeeded: { _ in },
            prependPendingHandoffIfNeeded: { text, _ in text },
            recordPendingHandoffSendOutcome: { _, _ in },
            signalMCPInstructionDelivered: { _ in },
            captureAttentionTurnCompletion: { [weak vm] session, revision in
                vm?.captureAttentionTurnCompletion(for: session, revision: revision)
            },
            settleAttentionTurnCompletion: { [weak vm] session, revision, capture, providerSuccessorDeclined in
                vm?.settleAttentionTurnCompletion(
                    for: session,
                    revision: revision,
                    capture: capture,
                    providerSuccessorDeclined: providerSuccessorDeclined
                )
            }
        ))
    }

    /// A loaded workspace manager with no initial activation (no listeners on the test view model).
    private func makeWorkspaceManager(
        workspaces: [WorkspaceModel]
    ) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.workspaces = workspaces
        return (manager, prompt)
    }

    private func makeInteraction(timeoutSeconds: TimeInterval) -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            timeoutSeconds: timeoutSeconds,
            questions: [
                AgentAskUserQuestion(
                    id: "choice",
                    question: "Which option?",
                    options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
                    allowsCustom: true
                )
            ]
        )
    }

    private func orphanRouting(_ vm: AgentModeViewModel, _ orphan: LiveSession) -> AgentDelegatedQuestionAudience {
        vm.delegatedQuestionAudience(for: orphan.session, provenance: .unverified)
    }

    /// Bounded, cancellation-aware wait (main-actor yields, no sleeps). On timeout or cancellation
    /// it fails with `description` and throws; the fixture teardown releases anything still held.
    private func waitUntil(
        _ description: @autoclosure () -> String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            if Task.isCancelled || clock.now >= deadline {
                let reason = Task.isCancelled ? "Cancelled" : "Timed out"
                XCTFail("\(reason) waiting for \(description())", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    /// Waits until admission has decided `key` (and the decision matches).
    @discardableResult
    private func waitForRecord(
        _ admission: AttentionNotificationAdmission,
        _ key: AttentionNotificationEventKey,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching: (AttentionNotificationAdmission.Record) -> Bool = { _ in true }
    ) async throws -> AttentionNotificationAdmission.Record {
        var last: AttentionNotificationAdmission.Record?
        try await waitUntil("admission record \(key); last \(String(describing: last))", file: file, line: line) {
            last = admission.records[key]
            return last.map(matching) ?? false
        }
        return try XCTUnwrap(last, file: file, line: line)
    }

    private func waitForAttempts(
        _ delivery: StubDelivery,
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var seen = 0
        try await waitUntil("\(count) delivery attempt(s); saw \(seen)", file: file, line: line) {
            seen = await delivery.events.count
            return seen >= count
        }
    }

    private func waitForPauses(
        _ fence: AdmissionFence,
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil("\(count) held admission(s); saw \(fence.pauseCount)", file: file, line: line) {
            fence.pauseCount >= count
        }
    }
}

/// Stub delivery: records every attempt and returns a fixed outcome, or hangs until released.
private actor StubDelivery: AttentionNotificationDelivering {
    enum Mode {
        case succeed
        case fail
        case hang
    }

    let mode: Mode
    private(set) var events: [AttentionNotificationEvent] = []
    private var hung: [CheckedContinuation<Void, Never>] = []
    private var hangReleased = false

    init(mode: Mode) {
        self.mode = mode
    }

    func deliver(_ event: AttentionNotificationEvent) async -> AttentionNotificationDeliveryOutcome {
        events.append(event)
        switch mode {
        case .succeed:
            return .sent
        case .fail:
            return .failed
        case .hang:
            if !hangReleased {
                await withCheckedContinuation { hung.append($0) }
            }
            return .unknown
        }
    }

    func releaseHang() {
        hangReleased = true
        hung.forEach { $0.resume() }
        hung.removeAll()
    }
}

/// Deterministic pre-admission fence: holds every admission until released; once released, later
/// admissions pass straight through.
@MainActor
private final class AdmissionFence {
    private var paused: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    /// Admissions that reached the fence.
    private(set) var pauseCount = 0
    /// Admissions that passed the fence; each admits synchronously right after.
    private(set) var passedCount = 0

    func pause(_: AttentionNotificationEventKey) async {
        pauseCount += 1
        if !isReleased {
            await withCheckedContinuation { paused.append($0) }
        }
        passedCount += 1
    }

    func release() {
        isReleased = true
        paused.forEach { $0.resume() }
        paused.removeAll()
    }
}
