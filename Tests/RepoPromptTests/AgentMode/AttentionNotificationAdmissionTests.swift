import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Outbound attention-notification admission seam (Telegram attention contract, Slice 2):
/// Direction 1 kill conditions with stub delivery and deterministic pre-admission fences. Every
/// result here is stub/fixture evidence; nothing is sent over a network.
@MainActor
final class AttentionNotificationAdmissionTests: XCTestCase {
    // MARK: - Kill: queued successor chains

    /// A scheduled follow-up defers the original completion's decision until its start returns. Once
    /// the follow-up took over, the original is no longer current whether the observation lands
    /// after the start or only after the successor already completed; repeated observations add
    /// nothing.
    func testQueuedFollowUpChainNotifiesOnlyTheFinalTurnWithItsOwnText() async throws {
        enum Observation: String, CaseIterable {
            case afterSuccessorStarted, afterSuccessorCompleted
        }
        for observation in Observation.allCases {
            let fixture = makeFixture()
            var followUps: [String] = []
            var afterStart: AgentModeRunService.Hooks.FollowUpStartObservation?
            let barrier = makeBarrier(fixture.vm, startFollowUpRun: { _, text, observe in
                followUps.append(text)
                afterStart = observe
            })
            let root = makeSession(fixture.vm)
            root.session.pendingInstructions = ["second"]

            let first = beginTurn(root.session, user: "first", assistant: "Intermediate answer A")
            let firstCommit = await barrier.commit(completedRequest(root.session, first, supportsFollowUp: true))
            let firstRevision = try XCTUnwrap(firstCommit)
            XCTAssertEqual(firstRevision.successorKind, .relatedFollowUp, observation.rawValue)
            XCTAssertEqual(followUps, ["second"], observation.rawValue)
            let observeFirstStart = try XCTUnwrap(afterStart, "A scheduled follow-up carries its start observation")
            let firstKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)
            XCTAssertNil(fixture.admission.records[firstKey], "Nothing is decided before the start returns")
            XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty, observation.rawValue)

            // The follow-up turn starts (as `startAgentRun` would run it).
            let second = beginTurn(root.session, user: "second", assistant: "Final answer B")
            let secondKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: second.attemptID)
            if observation == .afterSuccessorStarted {
                observeFirstStart()
                observeFirstStart()
                let record = try await waitForRecord(fixture.admission, firstKey)
                XCTAssertEqual(record, .suppressed(.eventNoLongerCurrent), observation.rawValue)
            }
            _ = await barrier.commit(completedRequest(root.session, second, supportsFollowUp: true))
            try await waitForRecord(fixture.admission, secondKey) { $0 == .delivered(.sent) }
            if observation == .afterSuccessorCompleted {
                observeFirstStart()
                observeFirstStart()
                let record = try await waitForRecord(fixture.admission, firstKey)
                XCTAssertEqual(record, .suppressed(.eventNoLongerCurrent), observation.rawValue)
            }
            observeFirstStart()

            XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty, observation.rawValue)
            XCTAssertEqual(fixture.admission.records[firstKey], .suppressed(.eventNoLongerCurrent), observation.rawValue)
            let events = await fixture.delivery.events
            XCTAssertEqual(events.map(\.key), [secondKey], observation.rawValue)
            XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Final answer B"), observation.rawValue)
            XCTAssertEqual(events.first?.sessionName, fixture.vm.resolvedSessionDisplayName(for: root.tabID))
        }
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

    /// A selected follow-up refused before ownership leaves the completed turn settled idle, so its
    /// deferred notification is decided after the actual start returns: sent exactly once with that
    /// turn's text, or suppressed when enablement, configuration, or binding changed in the deferred
    /// window or the user was active at the event. This is a refusal fixture, not a real deletion:
    /// the existing internal removal reservation makes the production `startAgentRun` refuse before
    /// ownership; no removal operation runs.
    func testSelectedFollowUpRefusedBeforeOwnershipNotifiesTheSettledCompletionOnce() async throws {
        enum DeferredChange: String, CaseIterable {
            case none, disabled, configurationReplaced, rebound, userActiveAtEvent
        }
        for change in DeferredChange.allCases {
            let fixture = makeFixture(idleSeconds: { change == .userActiveAtEvent ? 10 : nil })
            let root = makeSession(fixture.vm)
            // Codex uses the fixture's no-op stub, so even a regressed refusal launches no provider.
            root.session.selectedAgent = .codexExec
            root.session.pendingInstructions = ["queued follow-up"]
            let ownership = beginTurn(root.session, user: "first", assistant: "Answer before the refused follow-up")
            let commit = await fixture.vm.test_terminalCommitBarrier()
                .commit(completedRequest(root.session, ownership, supportsFollowUp: true))
            let revision = try XCTUnwrap(commit)
            let key = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: ownership.attemptID)
            XCTAssertEqual(revision.successorKind, .relatedFollowUp, change.rawValue)
            XCTAssertTrue(root.session.mcpFollowUpRunPending, "The queued start has not run yet")
            XCTAssertNil(fixture.admission.records[key], "Nothing is decided before the start returns")

            switch change {
            case .none, .userActiveAtEvent:
                break
            case .disabled:
                fixture.admission.setEnabled(false)
            case .configurationReplaced:
                fixture.admission.setDeliveryConfiguration(StubDelivery(mode: .succeed))
            case .rebound:
                root.session.testInstallPersistentSessionBinding(sessionID: UUID())
            }
            let reservation = UUID()
            fixture.vm.reservedComposeTabIDs[root.tabID] = reservation
            defer {
                if fixture.vm.reservedComposeTabIDs[root.tabID] == reservation {
                    fixture.vm.reservedComposeTabIDs.removeValue(forKey: root.tabID)
                }
            }

            // Only the returned start submits the capture, so a decided record proves it ran.
            let record = try await waitForRecord(fixture.admission, key) { $0 != .admitted }
            fixture.vm.reservedComposeTabIDs.removeValue(forKey: root.tabID)

            // Refusal: the start returned without taking over the completed turn.
            XCTAssertFalse(root.session.mcpFollowUpRunPending, change.rawValue)
            XCTAssertEqual(root.session.runState, .completed, change.rawValue)
            XCTAssertNil(root.session.activeRunOwnership, change.rawValue)
            XCTAssertTrue(root.session.pendingInstructions.isEmpty, change.rawValue)
            XCTAssertTrue(root.session.codexFallbackQueue.isEmpty, change.rawValue)
            XCTAssertEqual(root.session.lastTerminalCommitRevision?.commitID, revision.commitID, change.rawValue)
            XCTAssertTrue(fixture.vm.sessions[root.tabID] === root.session, change.rawValue)

            let events = await fixture.delivery.events
            switch change {
            case .none:
                XCTAssertEqual(record, .delivered(.sent))
                XCTAssertEqual(events.map(\.key), [key])
                XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Answer before the refused follow-up"))
                XCTAssertEqual(events.first?.sessionName, fixture.vm.resolvedSessionDisplayName(for: root.tabID))
            case .disabled:
                XCTAssertEqual(record, .suppressed(.enableChanged))
                XCTAssertTrue(events.isEmpty)
            case .configurationReplaced:
                XCTAssertEqual(record, .suppressed(.configurationChanged))
                XCTAssertTrue(events.isEmpty)
            case .rebound:
                XCTAssertEqual(record, .suppressed(.eventNoLongerCurrent))
                XCTAssertTrue(events.isEmpty)
            case .userActiveAtEvent:
                XCTAssertEqual(record, .suppressed(.userActive))
                XCTAssertTrue(events.isEmpty)
            }
        }
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

    /// Exercises the pending-key and record guards directly (terminal-barrier duplicate recovery
    /// never re-captures): one capture submitted twice is queued once before any asynchronous work,
    /// reaches the held fence once, and delivers once; a replay after the recorded outcome is never
    /// queued, never reaches the fence, and never delivers again.
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
        XCTAssertEqual(fixture.admission.pendingEventKeys, [key], "The duplicate is rejected before any asynchronous work")
        XCTAssertEqual(fixture.admission.activeEventKey, key)
        try await waitForPauses(fence, 1)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(fence.pauseCount, 1, "Only one submission reaches the fence")
        XCTAssertNil(fixture.admission.records[key], "The submission is held before admission")

        fence.release()
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
        XCTAssertEqual(fence.passedCount, 1)
        XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty, "The recorded outcome releases the key")
        XCTAssertNil(fixture.admission.activeEventKey)
        var attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 1)

        fixture.admission.submit(capture)
        XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty, "A replay after the outcome is never queued")
        XCTAssertNil(fixture.admission.activeEventKey)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(fence.pauseCount, 1, "A replay after the outcome never schedules admission")
        attempts = await fixture.delivery.events.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fixture.admission.records[key], .delivered(.sent))
    }

    // MARK: - Eligibility and production wiring

    func testProductionBarrierDeliversColdStartedRootOnceAcrossRepeatedTerminalPublication() async throws {
        let fixture = makeFixture()
        let barrier = fixture.vm.test_terminalCommitBarrier()
        // Fixture root (loaded flag set by `makeSession`); real cold restore is covered by
        // `testColdRestoredWorkspaceTabRootNotifiesCompletionAndQuestion`.
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
        XCTAssertFalse(AttentionNotificationAdmission.shared.isEnabled)
        XCTAssertNil(AttentionNotificationAdmission.shared.delivery, "Production configures no sender")

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

    /// Over the paced Telegram path with a stub HTTP client: a hanging request holds later
    /// notifications only (serialized delivery), never the commit, the actual successor start,
    /// question installation or its timeout. The successor runs through the production barrier and
    /// `startAgentRun` on the no-op Codex stub (no provider process). Events queued behind the hanging
    /// head are stale when it releases and never post.
    func testHangingDeliveryNeverDelaysCommitSuccessorQuestionInstallationOrTimeout() async throws {
        let clock = ManualPacingClock()
        let http = PacedStubHTTPClient(replies: [.hang(then: .fail(PacedTelegramTestSupport.leakyURLError(.timedOut)))])
        let pacer = TelegramAttentionPacer(clock: clock.pacingClock)
        let codex = LifecycleRecorder()
        let fixture = makeFixture(
            configuredDelivery: PacedTelegramTestSupport.delivery(http: http, pacer: pacer),
            codexRecorder: codex
        )
        addTeardownBlock { http.releaseHangs() }
        let barrier = fixture.vm.test_terminalCommitBarrier()
        let root = makeSession(fixture.vm)
        root.session.selectedAgent = .codexExec

        // Turn 1 settles idle and its single POST hangs.
        let first = beginTurn(root.session, user: "one", assistant: "first")
        _ = await barrier.commit(completedRequest(root.session, first, supportsFollowUp: true))
        try await waitUntil("the first POST to start") { http.requestCount == 1 }
        let firstKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: first.attemptID)
        XCTAssertEqual(fixture.admission.records[firstKey], .admitted)
        XCTAssertEqual(fixture.admission.activeEventKey, firstKey)

        // Turn 2 commits and its queued successor actually starts while turn 1's request still hangs.
        root.session.pendingInstructions = ["three"]
        let second = beginTurn(root.session, user: "two", assistant: "second")
        let revision = await barrier.commit(completedRequest(root.session, second, supportsFollowUp: true))
        XCTAssertEqual(revision?.successorKind, .relatedFollowUp)
        XCTAssertFalse(root.session.terminalCommitInProgress)
        let secondKey = AttentionNotificationEventKey.turnCompleted(sessionID: root.sessionID, attemptID: second.attemptID)
        XCTAssertNil(fixture.admission.records[secondKey], "Decided only after the successor start returns")
        try await waitUntil("the successor to reach the stub provider") { codex.contains("codex:send") }
        try await waitUntil("the returned successor start to submit turn 2 behind the hanging head") {
            fixture.admission.pendingEventKeys.contains(secondKey)
        }
        XCTAssertTrue(root.session.runState.isActive, "The successor took over the session")
        XCTAssertNotNil(root.session.activeRunOwnership)
        XCTAssertNotEqual(root.session.activeRunOwnership?.attemptID, second.attemptID)
        XCTAssertEqual(http.requestCount, 1)
        XCTAssertEqual(fixture.admission.records[firstKey], .admitted)
        XCTAssertEqual(fixture.admission.activeEventKey, firstKey)
        XCTAssertNil(fixture.admission.records[secondKey])

        // A question installs and is queued behind the hanging head; its timeout completes.
        let interaction = makeInteraction(timeoutSeconds: 60)
        let questionKey = AttentionNotificationEventKey.question(sessionID: root.sessionID, interactionID: interaction.id)
        let task = Task { try await fixture.vm.askUser(tabID: root.tabID, interaction: interaction) }
        try await waitUntil("the question to queue behind the hanging head") {
            fixture.admission.pendingEventKeys.contains(questionKey)
        }
        XCTAssertEqual(root.session.pendingAskUser?.interaction.id, interaction.id)
        XCTAssertEqual(fixture.admission.activeEventKey, firstKey)
        XCTAssertNil(fixture.admission.records[questionKey])
        fixture.vm.schedulePendingAskUserTimeout(
            for: root.session,
            interactionID: interaction.id,
            timeoutSeconds: 0,
            startedAt: Date()
        )
        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertEqual(fixture.admission.records[firstKey], .admitted)
        XCTAssertEqual(http.requestCount, 1, "Nothing else posts while the head hangs")

        http.releaseHangs()
        try await waitForRecord(fixture.admission, firstKey) { $0 == .delivered(.unknown) }
        let secondRecord = try await waitForRecord(fixture.admission, secondKey)
        XCTAssertEqual(secondRecord, .suppressed(.eventNoLongerCurrent), "The started successor took over turn 2")
        let questionRecord = try await waitForRecord(fixture.admission, questionKey)
        XCTAssertEqual(questionRecord, .suppressed(.eventNoLongerCurrent), "The stale queued question never posts")
        XCTAssertEqual(http.requestCount, 1, "One attempt for the hanging event; none for stale queued events")
        XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty)
        XCTAssertNil(fixture.admission.activeEventKey)
    }

    /// Over the paced Telegram path with a stub HTTP client: the queue head waits in first-message
    /// pacing before admission; a question resolved, a run ended, a rebind, a disable, or a
    /// configuration replacement/removal during that wait yields zero POSTs on any configuration.
    func testQuestionChangedWhilePacingBeforeAdmissionNeverPostsOverHTTP() async throws {
        enum Change: String, CaseIterable {
            case answered, skipped, timedOut, cancelledByRunEnd, rebound, disabled, configurationReplaced, configurationRemoved
        }
        for change in Change.allCases {
            let clock = ManualPacingClock(holdsWaits: true)
            let http = PacedStubHTTPClient()
            let replacementHTTP = PacedStubHTTPClient()
            let pacer = TelegramAttentionPacer(clock: clock.pacingClock)
            // An earlier request was just initiated, so the next head must wait before admission.
            await pacer.markRequestInitiated(spacing: TelegramAttentionPacer.privateChatSpacing)
            let fixture = makeFixture(configuredDelivery: PacedTelegramTestSupport.delivery(http: http, pacer: pacer))
            addTeardownBlock {
                clock.releaseWaits()
                http.releaseHangs()
            }
            let root = makeSession(fixture.vm)
            let ownership = beginTurn(root.session, user: "ask", assistant: nil)
            let interaction = makeInteraction(timeoutSeconds: 60)
            let key = AttentionNotificationEventKey.question(sessionID: root.sessionID, interactionID: interaction.id)
            let task = Task { try await fixture.vm.askUser(tabID: root.tabID, interaction: interaction) }
            try await waitUntil("\(change): the head to wait in pacing") { clock.waits.count == 1 }
            XCTAssertEqual(fixture.admission.activeEventKey, key, change.rawValue)
            XCTAssertNil(fixture.admission.records[key], change.rawValue)

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
                fixture.vm.schedulePendingAskUserTimeout(
                    for: root.session,
                    interactionID: interaction.id,
                    timeoutSeconds: 0,
                    startedAt: Date()
                )
                let response = try await task.value
                XCTAssertTrue(response.timedOut, change.rawValue)
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
                XCTAssertNil(root.session.pendingAskUser, change.rawValue)
                _ = try? await task.value
            case .rebound:
                root.session.testInstallPersistentSessionBinding(sessionID: UUID())
            case .disabled:
                fixture.admission.setEnabled(false)
                expected = .enableChanged
            case .configurationReplaced:
                fixture.admission.setDeliveryConfiguration(PacedTelegramTestSupport.delivery(
                    http: replacementHTTP,
                    pacer: pacer,
                    token: PacedTelegramTestSupport.replacementToken
                ))
                expected = .configurationChanged
            case .configurationRemoved:
                fixture.admission.setDeliveryConfiguration(nil)
                expected = .configurationChanged
            }
            clock.releaseWaits()

            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(expected), change.rawValue)
            XCTAssertEqual(http.requestCount, 0, change.rawValue)
            XCTAssertEqual(replacementHTTP.requestCount, 0, "\(change): an old capture never uses new credentials")
            XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty, change.rawValue)
            XCTAssertNil(fixture.admission.activeEventKey, change.rawValue)

            if root.session.pendingAskUser?.interaction.id == interaction.id {
                fixture.vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
                _ = try? await task.value
            }
        }
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

    // MARK: - Production-constructed roots and projected children (Slice 5)

    /// A root restored on a cold window: a second view model restores the workspace compose tab
    /// through `ensureSessionReady`, which binds the tab's durable session from the workspace and
    /// hydrates it from the temporary store. Lineage and eligibility come from production state
    /// only; nothing here sets parent or loaded flags.
    func testColdRestoredWorkspaceTabRootNotifiesCompletionAndQuestion() async throws {
        let storageURL = try makeTemporaryStore()
        let workspace = makeStoreWorkspace(storageURL)
        let sessionID: UUID
        do {
            let writer = makeStoreViewModel(windowID: 5501, storageURL: storageURL)
            writer.test_establishPersistenceWorkspace(workspace)
            let writerTabID = UUID()
            writer.test_setCurrentTabIDOverride(writerTabID)
            let source = try await writer.ensureSessionReady(tabID: writerTabID)
            sessionID = try XCTUnwrap(writer.ensureSessionBoundToTab(source))
            source.appendItem(.user("Earlier question"))
            source.appendItem(.assistant("Earlier answer"))
            let saved = await writer.flushSave(for: writerTabID)
            XCTAssertTrue(saved)
        }

        let tabID = UUID()
        var restoredWorkspace = workspace
        restoredWorkspace.composeTabs = [ComposeTabState(id: tabID, name: "Restored root", activeAgentSessionID: sessionID)]
        restoredWorkspace.activeComposeTabID = tabID
        let restored = makeStoreViewModel(windowID: 5502, storageURL: storageURL)
        let wired = wireWorkspace(restored, workspace: restoredWorkspace)
        let attention = installAdmission(on: restored)
        let session = try await restored.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        XCTAssertTrue(session.items.contains { $0.text == "Earlier answer" }, "Hydrated from the store")
        XCTAssertEqual(restored.mcpDelegationLineage(for: session), .resolved(depth: 0))

        let ownership = beginTurn(session, user: "Continue", assistant: "Restored root answer")
        _ = await restored.test_terminalCommitBarrier().commit(completedRequest(session, ownership))
        let completionKey = AttentionNotificationEventKey.turnCompleted(sessionID: sessionID, attemptID: ownership.attemptID)
        try await waitForRecord(attention.admission, completionKey) { $0 == .delivered(.sent) }

        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task { try await restored.askUser(tabID: tabID, interaction: interaction) }
        let questionKey = AttentionNotificationEventKey.question(sessionID: sessionID, interactionID: interaction.id)
        try await waitForRecord(attention.admission, questionKey) { $0 == .delivered(.sent) }
        restored.skipAskUser(tabID: tabID, interactionID: interaction.id)
        _ = try await task.value

        let events = await attention.delivery.events
        XCTAssertEqual(events.map(\.key), [completionKey, questionKey])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Restored root answer"))
        XCTAssertEqual(events.map(\.workspaceName), ["Attention Store", "Attention Store"])
        let restoredName = restored.resolvedSessionDisplayName(for: tabID)
        XCTAssertFalse(restoredName.isEmpty)
        XCTAssertEqual(events.map(\.sessionName), [restoredName, restoredName])
        withExtendedLifetime(wired) {}
    }

    /// A UI handoff destination is a root as soon as `prepareHandoffHeadless` returns, before any
    /// readiness call. The UI's local handoff (`performHandoff` in `AgentModeViewModel+Handoff.swift`)
    /// calls `prepareHandoffToNewTab(sourceTabID:...)`, which calls this same `prepareHandoffHeadless`
    /// and then only foregrounds the destination tab.
    func testUIHandoffDestinationIsARootThatNotifiesItsCompletion() async throws {
        let storageURL = try makeTemporaryStore()
        let sourceTabID = UUID()
        let sourceSessionID = UUID()
        let workspace = makeStoreWorkspace(
            storageURL,
            composeTabs: [ComposeTabState(id: sourceTabID, name: "Source", activeAgentSessionID: sourceSessionID)]
        )
        let vm = makeStoreViewModel(windowID: 5511, storageURL: storageURL)
        let wired = wireWorkspace(vm, workspace: workspace)
        let attention = installAdmission(on: vm)
        let source = try await vm.ensureSessionReady(tabID: sourceTabID)
        XCTAssertEqual(source.activeAgentSessionID, sourceSessionID)
        source.appendItem(.user("Source question"))
        source.appendItem(.assistant("Source answer"))

        let destinationTabID = try await vm.prepareHandoffHeadless(
            sourceTabID: sourceTabID,
            upToItemID: nil,
            destinationAgent: source.selectedAgent,
            destinationModelRaw: source.selectedModelRaw,
            destinationReasoningEffortRaw: source.selectedReasoningEffortRaw
        )
        let destination = try XCTUnwrap(vm.sessions[destinationTabID])
        let destinationSessionID = try XCTUnwrap(destination.activeAgentSessionID)
        XCTAssertNotEqual(destinationSessionID, sourceSessionID)
        // Root straight from the production handoff, without a test-added readiness step.
        XCTAssertEqual(vm.mcpDelegationLineage(for: destination), .resolved(depth: 0))
        XCTAssertTrue(vm.isAttentionNotificationRoot(destination))
        let ready = try await vm.ensureSessionReady(tabID: destinationTabID)
        XCTAssertTrue(ready === destination)
        XCTAssertEqual(vm.mcpDelegationLineage(for: destination), .resolved(depth: 0))

        let ownership = beginTurn(destination, user: "Continue after handoff", assistant: "Handoff answer")
        _ = await vm.test_terminalCommitBarrier().commit(completedRequest(destination, ownership))
        let key = AttentionNotificationEventKey.turnCompleted(sessionID: destinationSessionID, attemptID: ownership.attemptID)
        try await waitForRecord(attention.admission, key) { $0 == .delivered(.sent) }
        let events = await attention.delivery.events
        XCTAssertEqual(events.map(\.key), [key])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Handoff answer"))
        XCTAssertEqual(events.first?.workspaceName, "Attention Store")
        let destinationName = vm.resolvedSessionDisplayName(for: destinationTabID)
        XCTAssertFalse(destinationName.isEmpty)
        XCTAssertEqual(events.first?.sessionName, destinationName)
        withExtendedLifetime(wired) {}
    }

    /// The production scheduled-send path (install, then Send now through the coordinator; no timer
    /// fires) accepts the dispatch with a stubbed run start, and the completion comes from a test
    /// attempt on the same session object: it stays an eligible root and that completion notifies.
    /// The install passes the `isNewSessionStart` the composer computes for a never-sent session.
    func testScheduledSendDispatchedRootNotifiesItsCompletion() async throws {
        let storageURL = try makeTemporaryStore()
        let vm = makeStoreViewModel(windowID: 5521, storageURL: storageURL)
        vm.test_establishPersistenceWorkspace(makeStoreWorkspace(storageURL))
        let attention = installAdmission(on: vm)
        let tabID = UUID()
        vm.test_setCurrentTabIDOverride(tabID)
        let session = try await vm.ensureSessionReady(tabID: tabID)
        let sessionID = try XCTUnwrap(vm.ensureSessionBoundToTab(session))
        let now = Date()
        // The deadline never fires on its own (sleep ends immediately): only Send now dispatches.
        let coordinator = AgentScheduledSendCoordinator(clock: SchedulerClock(
            now: { now },
            sleepUntil: { _ in throw CancellationError() },
            probe: { .none }
        ))
        vm.attachScheduledSendCoordinator(coordinator)
        addTeardownBlock { @MainActor in vm.detachScheduledSendCoordinator() }
        vm.scheduledDispatchRunStarter = { _, _, _, _ in .sent }

        // As `executeComposerScheduleAttempt` computes it for an existing session.
        let isNewSessionStart = AgentModeViewModel.sessionIsUntouchedForScheduling(session)
        XCTAssertTrue(isNewSessionStart, "A never-sent session schedules as a new session start")
        let scheduleID = try await vm.installScheduledSend(
            text: "Scheduled turn",
            on: session,
            notBefore: now.addingTimeInterval(3600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: isNewSessionStart
        ).get()
        let refusal = await vm.sendScheduledSendNow(tabID: tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
        XCTAssertNil(refusal)
        try await waitUntil("scheduled dispatch accepted") { session.lastScheduledDispatch?.scheduleID == scheduleID }
        XCTAssertTrue(session.items.contains { $0.kind == .user && $0.text == "Scheduled turn" })
        XCTAssertEqual(vm.mcpDelegationLineage(for: session), .resolved(depth: 0))

        let ownership = beginTurn(session, user: nil, assistant: "Scheduled answer")
        _ = await vm.test_terminalCommitBarrier().commit(completedRequest(session, ownership))
        let key = AttentionNotificationEventKey.turnCompleted(sessionID: sessionID, attemptID: ownership.attemptID)
        try await waitForRecord(attention.admission, key) { $0 == .delivered(.sent) }
        let events = await attention.delivery.events
        XCTAssertEqual(events.map(\.key), [key])
        XCTAssertEqual(events.first?.content, .turnCompleted(finalAssistantText: "Scheduled answer"))
    }

    /// A remote child materialized by the production projection records its local parent, so its
    /// lineage is depth 1 and it is not an attention root. This exercises the local terminal-commit
    /// and `askUser` authorities on the projected record only; real remote event dispatch
    /// (`applyRunState`) is not covered here. Neither its completion nor its question is admitted.
    func testProjectedRemoteChildCompletionAndQuestionAreNeverAdmitted() async throws {
        let storageURL = try makeTemporaryStore()
        let parentTabID = UUID()
        let parentSessionID = UUID()
        let workspace = makeStoreWorkspace(
            storageURL,
            composeTabs: [ComposeTabState(id: parentTabID, name: "Remote parent", activeAgentSessionID: parentSessionID)]
        )
        let vm = makeStoreViewModel(windowID: 5531, storageURL: storageURL)
        let wired = wireWorkspace(vm, workspace: workspace)
        let attention = installAdmission(on: vm)
        let parent = try await vm.ensureSessionReady(tabID: parentTabID)
        let parentBinding = AgentSessionRemoteHostBinding(
            hostID: "host-attention",
            hostDisplayName: "Studio Mac",
            remoteSessionID: UUID().uuidString
        )
        parent.remoteHost = parentBinding
        XCTAssertEqual(vm.mcpDelegationLineage(for: parent), .resolved(depth: 0))

        let childRemoteID = UUID()
        let materialized = await vm.materializeRemoteChildSession(
            RemoteAgentSessionDescriptor(
                sessionID: childRemoteID.uuidString,
                name: "Remote worker",
                stateRaw: "idle",
                agentKindRaw: AgentProviderKind.codexExec.rawValue,
                parentSessionID: parentBinding.remoteSessionID
            ),
            parentSession: parent,
            parentRemoteHost: parentBinding
        )
        let child = try XCTUnwrap(materialized)
        XCTAssertEqual(child.activeAgentSessionID, childRemoteID)
        XCTAssertEqual(child.parentSessionID, parentSessionID, "The projection records the local parent")
        XCTAssertEqual(vm.mcpDelegationLineage(for: child), .resolved(depth: 1))
        XCTAssertFalse(vm.isAttentionNotificationRoot(child))
        XCTAssertEqual(vm.delegatedQuestionAudience(for: child, provenance: .unverified), .user)

        // A question during the turn, then the turn completes. The terminal commit cancels the
        // pending question locally, so no remote-host response path is involved.
        let ownership = beginTurn(child, user: "remote", assistant: "Remote child answer")
        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        let record = try await waitForRecord(
            attention.admission,
            .question(sessionID: childRemoteID, interactionID: interaction.id)
        )
        XCTAssertEqual(record, .suppressed(.ineligibleSession))

        _ = await vm.test_terminalCommitBarrier().commit(completedRequest(child, ownership))
        XCTAssertEqual(
            attention.admission.records[.turnCompleted(sessionID: childRemoteID, attemptID: ownership.attemptID)],
            .suppressed(.ineligibleSession)
        )
        do {
            _ = try await task.value
            XCTFail("The terminal commit cancels the pending question")
        } catch is CancellationError {}
        let attempts = await attention.delivery.events.count
        XCTAssertEqual(attempts, 0)
        withExtendedLifetime(wired) {}
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

    /// `configuredDelivery` replaces the stub delivery (then `Fixture.delivery` records nothing).
    /// Codex runs use the no-op stub controller; `codexRecorder` observes its provider sends.
    private func makeFixture(
        delivery: StubDelivery = StubDelivery(mode: .succeed),
        configuredDelivery: (any AttentionNotificationDelivering)? = nil,
        fence: AdmissionFence? = nil,
        idleSeconds: @escaping @MainActor () -> TimeInterval? = { nil },
        codexRecorder: LifecycleRecorder = LifecycleRecorder()
    ) -> Fixture {
        let vm = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: codexRecorder)
            }
        )
        let admission = AttentionNotificationAdmission(environment: .init(
            delivery: configuredDelivery ?? delivery,
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
        user: String?,
        assistant: String?
    ) -> AgentRunOwnership {
        if session.runID == nil {
            session.runID = UUID()
        }
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.attention")
        if let user {
            session.appendItem(.user(user, sequenceIndex: session.nextSequenceIndex))
        }
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
    /// other hooks are inert so follow-up starts are only recorded (a test models the start and
    /// invokes its observation).
    private func makeBarrier(
        _ vm: AgentModeViewModel,
        startFollowUpRun: @escaping (UUID, String, AgentModeRunService.Hooks.FollowUpStartObservation?) -> Void = { _, _, _ in }
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
            settleAttentionTurnCompletion: { [weak vm] session, revision, capture, providerSuccessorDeclined, genericFollowUpScheduled in
                vm?.settleAttentionTurnCompletion(
                    for: session,
                    revision: revision,
                    capture: capture,
                    providerSuccessorDeclined: providerSuccessorDeclined,
                    genericFollowUpScheduled: genericFollowUpScheduled
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

    /// Stub-delivery admission on a view model built by a production-path fixture.
    private func installAdmission(
        on vm: AgentModeViewModel
    ) -> (admission: AttentionNotificationAdmission, delivery: StubDelivery) {
        let delivery = StubDelivery(mode: .succeed)
        let admission = AttentionNotificationAdmission(environment: .init(
            delivery: delivery,
            idleSeconds: { nil },
            beforeAdmission: { _ in }
        ))
        admission.setEnabled(true)
        vm.attentionNotificationAdmission = admission
        addTeardownBlock { @MainActor in
            for (tabID, session) in vm.sessions {
                if let interactionID = session.pendingAskUser?.interaction.id {
                    vm.skipAskUser(tabID: tabID, interactionID: interactionID)
                }
            }
        }
        return (admission, delivery)
    }

    private func makeTemporaryStore() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionNotificationAdmissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeStoreWorkspace(_ storageURL: URL, composeTabs: [ComposeTabState] = []) -> WorkspaceModel {
        WorkspaceModel(
            name: "Attention Store",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL,
            ephemeralFlag: true,
            composeTabs: composeTabs,
            activeComposeTabID: composeTabs.first?.id
        )
    }

    private func makeStoreViewModel(windowID: Int, storageURL: URL) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )
    }

    private struct WiredWorkspace {
        let manager: WorkspaceManagerViewModel
        let prompt: PromptViewModel
    }

    /// Active workspace, compose tabs, and persistence target wired as a window would.
    private func wireWorkspace(_ vm: AgentModeViewModel, workspace: WorkspaceModel) -> WiredWorkspace {
        let (manager, prompt) = makeWorkspaceManager(workspaces: [workspace])
        prompt.attachWorkspaceManager(manager)
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        vm.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: manager)
        vm.test_establishPersistenceWorkspace(workspace)
        return WiredWorkspace(manager: manager, prompt: prompt)
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
