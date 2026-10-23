import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
extension AgentModeRunServiceLifecycleTests {
    /// Regression for received background output remaining buffered after the per-run consumer exits.
    /// Output produced between runs must reach the transcript immediately, under the turn that was
    /// current when it arrived, and exactly once.
    func testClaudeBackgroundOutputAppearsWithoutNewSendAndKeepsOriginalTurn() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let originalUser = AgentChatItem.user("Build in the background", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(originalUser)
        let controller = try BackgroundTranscriptController()
        addTeardownBlock { await controller.shutdown() }
        let backgroundText = "Background build passed"
        let deliveredBeforeNudge = expectation(description: "Background output reaches transcript without another send")
        var host: AgentModeViewModel?
        var backgroundDeliveryUserIDs: [UUID?] = []
        // Observes every delivered result, whether a run consumed it or it arrived between runs.
        let observeDelivery: (AIStreamResult) -> Void = { result in
            if result.type == "content", result.text == backgroundText {
                backgroundDeliveryUserIDs.append(session.items.last(where: { $0.kind == .user })?.id)
            }
            if result.type == "message_stop",
               session.items.contains(where: { $0.kind == .assistant && $0.text == backgroundText }),
               session.items.last(where: { $0.kind == .user })?.id == originalUser.id
            {
                deliveredBeforeNudge.fulfill()
            }
        }
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
                observeDelivery(result)
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                guard let host else { return }
                await host.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                observeDelivery(result)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        // The fake launch/send boundary drives the real controller, translator, event stream,
        // integrated runner, terminal barrier, and view-model stream handler. No subprocess or API.
        _ = await harness.service.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: originalUser.text, initialMessageForRun: originalUser.text,
            attachments: []
        )
        let firstTask = try XCTUnwrap(session.agentTask)
        await firstTask.value
        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.agentTask)
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["Waiting for background build"])
        let originalRunID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: originalRunID) }
        let sendsBeforeBackground = await controller.sentMessages
        XCTAssertEqual(sendsBeforeBackground, [originalUser.text])

        // Model the incident: a background task resumes the same provider process after its
        // successful result. Awaiting injection proves translation/yield completed, not delivery.
        await controller.emitResponse(backgroundText)
        let delivery = await XCTWaiter.fulfillment(of: [deliveredBeforeNudge], timeout: 1)
        XCTAssertEqual(
            delivery, .completed,
            "Already-received background output must not require a user nudge to reach the transcript."
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["Waiting for background build", backgroundText],
            "Background output must be present before another user message is appended."
        )

        // Continue after the red assertions to distinguish buffering from dropped output and
        // check ownership. The old message must never be inserted after this newer user row.
        let nudge = AgentChatItem.user("What is the latest progress?", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(nudge)
        _ = await harness.service.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: nudge.text, initialMessageForRun: nudge.text,
            attachments: []
        )
        let secondTask = try XCTUnwrap(session.agentTask)
        await secondTask.value
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(session.runID, originalRunID, "The successful run must reuse the provider process identity.")
        let sentMessages = await controller.sentMessages
        XCTAssertEqual(sentMessages, [originalUser.text, nudge.text])
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["Waiting for background build", backgroundText, "Current progress answer"],
            "The background message must survive exactly once, independently of the new answer."
        )
        let backgroundIndex = try XCTUnwrap(session.items.firstIndex { $0.kind == .assistant && $0.text == backgroundText })
        let nudgeIndex = try XCTUnwrap(session.items.firstIndex { $0.id == nudge.id })
        XCTAssertLessThan(backgroundIndex, nudgeIndex, "Old output must remain with the original user turn.")
        XCTAssertEqual(backgroundDeliveryUserIDs, [originalUser.id])
    }

    /// The process exits after a run's message was sent but before the run subscribed: the run's
    /// failure is on the finished stream and `eventsSubscription` returns a new, empty stream. The
    /// run must still observe its failure instead of waiting on a stream nothing will write to.
    func testClaudeRunObservesProcessExitThatEndedStreamBeforeItSubscribed() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .processExits)
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        let firstUser = AgentChatItem.user("First", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(firstUser)
        _ = await harness.service.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: firstUser.text, initialMessageForRun: firstUser.text,
            attachments: []
        )
        let firstTask = try XCTUnwrap(session.agentTask)
        await firstTask.value
        XCTAssertEqual(session.runState, .completed)
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }

        let secondUser = AgentChatItem.user("Second", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(secondUser)
        _ = await harness.service.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: secondUser.text, initialMessageForRun: secondUser.text,
            attachments: []
        )
        let secondTask = try XCTUnwrap(session.agentTask)
        let settled = expectation(description: "Run ends after the process exited")
        Task {
            await secondTask.value
            settled.fulfill()
        }
        let outcome = await XCTWaiter.fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(outcome, .completed, "The run must observe the failure emitted before its stream ended.")
        XCTAssertEqual(session.runState, .failed)
        XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text == "Claude process exited unexpectedly." })
        XCTAssertEqual(session.lastTerminalCommitRevision?.cause, .providerProcessLost, "Review A F06: typed process loss")
    }

    /// Review A F06: a turn the provider itself reports failed (its process still running) ends the
    /// run as an ordinary failure, never as provider-process loss.
    func testClaudeProviderReportedFailureStaysOrdinary() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .providerReportsFailure)
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }
        for text in ["First", "Second"] {
            let user = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(user)
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            try await XCTUnwrap(session.agentTask).value
            if let runID = session.runID {
                addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }
            }
        }
        XCTAssertEqual(session.runState, .failed)
        XCTAssertEqual(session.lastTerminalCommitRevision?.cause, .ordinary)
    }

    /// The run's stream ends after carrying part of its output and its turn continues on a new
    /// stream: the reused old router is only a prefix, and the run must finish on the new stream
    /// instead of failing as "ended unexpectedly" while its answer stays buffered.
    func testClaudeRunContinuesOnSubscribedStreamAfterReusedRouterEnds() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .streamReplaced)
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        for text in ["First", "Second"] {
            let user = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(user)
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            let settled = expectation(description: "Run \(text) ends")
            Task {
                await task.value
                settled.fulfill()
            }
            let outcome = await XCTWaiter.fulfillment(of: [settled], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Run \(text) must not wait forever.")
            XCTAssertEqual(session.runState, .completed, "Run \(text) must complete.")
        }
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }
        let assistantText = session.items.filter { $0.kind == .assistant }.map(\.text).joined(separator: "|")
        XCTAssertTrue(assistantText.contains("Real answer"), "The answer on the new stream must be shown: \(assistantText)")
        XCTAssertFalse(session.items.contains { $0.kind == .error }, "The run must not fail as ended unexpectedly.")
    }

    /// A background message whose end never reached the background path (the process exited, or
    /// the user sent mid-message) never takes later background output: it starts a new row below
    /// the newer prompt and the run's answer instead of continuing or replacing the old row. The old
    /// message may precede the newer prompt or arrive below it (during the run's startup), and the
    /// later output may come from the same process, whose stream the run took over, or from a
    /// relaunched one.
    func testClaudeBackgroundOutputAfterNewerPromptNeverResumesOldBackgroundRow() async {
        for oldOutputAfterNewerPrompt in [false, true] {
            for laterOutputIsFinalContent in [false, true] {
                for sameStream in [true, false] {
                    let oldStream = UUID()
                    await assertLaterBackgroundOutputStartsNewRow(
                        oldOutputAfterNewerPrompt: oldOutputAfterNewerPrompt,
                        laterOutputIsFinalContent: laterOutputIsFinalContent,
                        oldSource: oldStream,
                        newSource: sameStream ? oldStream : UUID()
                    )
                }
            }
        }
    }

    private func assertLaterBackgroundOutputStartsNewRow(
        oldOutputAfterNewerPrompt: Bool,
        laterOutputIsFinalContent: Bool,
        oldSource: UUID,
        newSource: UUID
    ) async {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.appendItem(AgentChatItem.user("First", sequenceIndex: session.nextSequenceIndex))

        func background(_ type: String, _ text: String, source: UUID) async {
            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: type, text: text), sourceID: source, session: session
            )
        }
        let newerPrompt = AgentChatItem.user("Second", sequenceIndex: session.nextSequenceIndex)
        // The old background message never ends on the background path.
        if oldOutputAfterNewerPrompt {
            session.appendItem(newerPrompt)
            await background("content", "partial from old process", source: oldSource)
        } else {
            await background("content", "partial from old process", source: oldSource)
            session.appendItem(newerPrompt)
        }
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        let attemptID = session.beginRunAttempt(source: "test.newerPromptBoundary").attemptID
        // The runner's takeover hook: the run reads the later output's stream.
        harness.host.endBackgroundMessage(fromSource: newSource, session: session)
        for (type, text) in [("content", "Run answer"), ("final_content", "Run answer"), ("message_stop", "")] {
            await harness.host.test_handleStreamResult(
                AIStreamResult(type: type, text: text), session: session, runID: runID, runAttemptID: attemptID
            )
        }
        harness.host.flushPendingAssistantDelta(session)
        // The barrier's `finalizeStreamingItems` hook at the run's terminal commit.
        harness.host.finalizeStreamingItems(in: session)

        await background(
            laterOutputIsFinalContent ? "final_content" : "content",
            "new background answer",
            source: newSource
        )
        await background("message_stop", "", source: newSource)

        let label = "afterPrompt: \(oldOutputAfterNewerPrompt), final: \(laterOutputIsFinalContent), "
            + "sameStream: \(newSource == oldSource)"
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["partial from old process", "Run answer", "new background answer"],
            label
        )
        let newRowIndex = session.items.firstIndex { $0.text == "new background answer" }
        let promptIndex = session.items.firstIndex { $0.id == newerPrompt.id }
        XCTAssertGreaterThan(newRowIndex ?? -1, promptIndex ?? Int.max, label)
    }

    /// Two streams can deliver between-run output at once (a draining router of a replaced stream
    /// and the current one). Each stream's message keeps its own current row: another stream's
    /// rows, segment ends and errors neither split, end nor shadow it.
    func testClaudeInterleavedBackgroundStreamsKeepTheirOwnRows() async {
        for interleaved in ["error", "content"] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            var host: AgentModeViewModel?
            let harness = makeHarness(
                recorder: LifecycleRecorder(),
                flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
            )
            host = harness.host
            harness.host.test_installLiveSession(session)
            defer { harness.host.clearPendingAssistantDelta(session) }
            session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))
            let newStream = UUID()
            let oldStream = UUID()
            func background(_ type: String, _ text: String, source: UUID) async {
                await harness.host.test_handleBackgroundNativeStreamResult(
                    AIStreamResult(type: type, text: text), sourceID: source, session: session
                )
            }

            await background("content", "partial", source: newStream)
            await background(interleaved, "old process output", source: oldStream)
            await background("message_stop", "", source: oldStream)
            let newRow = session.items.first { $0.text == "partial" }
            XCTAssertEqual(newRow?.isStreaming, true, "\(interleaved): another stream's end must not end it.")
            await background("content", " more", source: newStream)
            await background("final_content", "authoritative answer", source: newStream)
            await background("message_stop", "", source: newStream)

            let expectedAssistantTexts = interleaved == "content"
                ? ["authoritative answer", "old process output"]
                : ["authoritative answer"]
            XCTAssertEqual(
                session.items.filter { $0.kind == .assistant }.map(\.text),
                expectedAssistantTexts,
                interleaved
            )
            XCTAssertEqual(session.items.count(where: { $0.text == "old process output" }), 1, interleaved)
            XCTAssertTrue(session.backgroundCurrentAssistantRowIDs.isEmpty, interleaved)
        }
    }

    /// A background message that arrived below a newer prompt, before its run took over the same
    /// process's stream, ends at that takeover: the stream's later between-run output starts a new
    /// row below the run's answer instead of replacing the old row above it.
    func testClaudeRunTakeoverEndsSameStreamBackgroundMessage() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .answersOnSameStream)
        let oldPartialDelivered = expectation(description: "Old background partial is delivered")
        let laterOutputDelivered = expectation(description: "Later background output is delivered")
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                if result.text == "partial from old process" { oldPartialDelivered.fulfill() }
                if result.text == "new background answer" { laterOutputDelivered.fulfill() }
            },
            endBackgroundNativeMessage: { sourceID in
                host?.endBackgroundMessage(fromSource: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        func run(_ user: AgentChatItem) async throws {
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            await task.value
            XCTAssertEqual(session.runState, .completed, "Run \(user.text) must complete.")
            // The barrier's `finalizeStreamingItems` hook, a no-op in this harness.
            harness.host.finalizeStreamingItems(in: session)
        }
        let first = AgentChatItem.user("First", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(first)
        try await run(first)

        // The user sends while a background message streams: its text lands below the new prompt
        // before the run's marker, and its end belongs to the run.
        let second = AgentChatItem.user("Second", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(second)
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "partial from old process")))
        let partialOutcome = await XCTWaiter.fulfillment(of: [oldPartialDelivered], timeout: 2)
        XCTAssertEqual(partialOutcome, .completed)
        try await run(second)
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }

        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "final_content", text: "new background answer")))
        let laterOutcome = await XCTWaiter.fulfillment(of: [laterOutputDelivered], timeout: 2)
        XCTAssertEqual(laterOutcome, .completed)
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["First answer", "partial from old process", "Run answer", "new background answer"]
        )
    }

    /// An approval request from before a run's marker is handed to that run, but the stream is not
    /// the run's yet: the background message's output after the request still reaches its row, so
    /// its authoritative `final_content` replaces its partial instead of duplicating it.
    func testClaudeHandedOverApprovalDoesNotEndSameStreamBackgroundMessage() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .answersOnSameStream)
        let partialDelivered = expectation(description: "Background partial is delivered")
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                if result.text == "partial" { partialDelivered.fulfill() }
            },
            endBackgroundNativeMessage: { sourceID in
                host?.endBackgroundMessage(fromSource: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        func run(_ user: AgentChatItem) async throws {
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            await task.value
            // The barrier's `finalizeStreamingItems` hook, a no-op in this harness.
            harness.host.finalizeStreamingItems(in: session)
        }
        let first = AgentChatItem.user("First", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(first)
        try await run(first)
        XCTAssertEqual(session.runState, .completed)

        // Before B's marker the background message streams, asks for approval (held for the next
        // consuming run), and ends with its authoritative text.
        let second = AgentChatItem.user("Second", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(second)
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "partial")))
        let partialOutcome = await XCTWaiter.fulfillment(of: [partialDelivered], timeout: 2)
        XCTAssertEqual(partialOutcome, .completed)
        await controller.emitBetweenRuns(.approvalRequest(AgentApprovalRequest(
            requestID: .claudeControl("handed-over"),
            method: "can_use_tool",
            kind: .commandExecution,
            threadID: "thread",
            turnID: "handed-over",
            itemID: "handed-over"
        )))
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "final_content", text: "authoritative")))
        try await run(second)
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }

        XCTAssertEqual(session.pendingApproval?.requestID, .claudeControl("handed-over"))
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["First answer", "authoritative", "Run answer"]
        )
    }

    /// A replaced stream still draining shows its output, but its `message_stop` never overwrites
    /// the provider session ID the tab's current stream (a newer launch) persisted.
    func testClaudeReplacedStreamDoesNotOverwriteProviderSessionIDBetweenRuns() async {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        let currentStream = UUID()
        let replacedStream = UUID()
        session.claudeAuthoritativeEventSourceID = currentStream
        session.providerSessionID = "newer-launch"

        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "content", text: "old output"), sourceID: replacedStream, session: session
        )
        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "message_stop", text: "", providerSessionID: "older-launch"),
            sourceID: replacedStream, session: session
        )
        XCTAssertEqual(session.providerSessionID, "newer-launch")
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["old output"])

        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "message_stop", text: "", providerSessionID: "current-launch"),
            sourceID: currentStream, session: session
        )
        XCTAssertEqual(session.providerSessionID, "current-launch")
    }

    /// Between-run output keeps one source per event stream: output of the same stream shares it,
    /// and output of a replacement stream (a relaunched provider) never does.
    func testClaudeBetweenRunOutputCarriesItsStreamsSource() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .streamReplaced)
        var sourcesByText: [String: UUID] = [:]
        let firstStreamDelivered = expectation(description: "First-stream output is delivered")
        let secondStreamDelivered = expectation(description: "Second-stream output is delivered")
        let afterCurrentInitDelivered = expectation(description: "Output after the current init is delivered")
        let afterStaleInitDelivered = expectation(description: "Output after the stale init is delivered")
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                guard let text = result.text, !text.isEmpty else { return }
                sourcesByText[text] = sourceID
                if text == "first stream b" { firstStreamDelivered.fulfill() }
                if text == "second stream" { secondStreamDelivered.fulfill() }
                if text == "after current init" { afterCurrentInitDelivered.fulfill() }
                if text == "after stale init" { afterStaleInitDelivered.fulfill() }
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        func run(_ text: String) async throws {
            let user = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(user)
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            await task.value
            XCTAssertEqual(session.runState, .completed, "Run \(text) must complete.")
        }
        try await run("First")
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "first stream a")))
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "message_stop", text: "")))
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "first stream b")))
        let firstOutcome = await XCTWaiter.fulfillment(of: [firstStreamDelivered], timeout: 2)
        XCTAssertEqual(firstOutcome, .completed)
        // The second send replaces the stream, as a relaunch inside the send path would.
        try await run("Second")
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "second stream")))
        let secondOutcome = await XCTWaiter.fulfillment(of: [secondStreamDelivered], timeout: 2)
        XCTAssertEqual(secondOutcome, .completed)
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }

        let firstSource = try XCTUnwrap(sourcesByText["first stream a"])
        XCTAssertEqual(sourcesByText["first stream b"], firstSource)
        let secondSource = try XCTUnwrap(sourcesByText["second stream"])
        XCTAssertNotEqual(firstSource, secondSource)
        let backgroundTexts = session.items.filter { session.backgroundRowIDs.contains($0.id) }.map(\.text)
        XCTAssertEqual(backgroundTexts, ["first stream a", "first stream b", "second stream"])
        XCTAssertEqual(session.claudeAuthoritativeEventSourceID, secondSource, "The current stream is authoritative.")

        func runtimeInit(_ sessionID: String) -> NativeAgentRuntimeEvent {
            .runtimeInit(.init(sessionID: sessionID, tools: [], mcpServerStatuses: [:], initializeResponse: nil))
        }
        // The current stream's runtime init updates the provider session ID between runs...
        await controller.emitBetweenRuns(runtimeInit("current-launch"))
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "after current init")))
        let currentInitOutcome = await XCTWaiter.fulfillment(of: [afterCurrentInitDelivered], timeout: 2)
        XCTAssertEqual(currentInitOutcome, .completed)
        XCTAssertEqual(session.providerSessionID, "current-launch")
        // ...a stream that is no longer the tab's current one (a newer launch replaced it) only shows output.
        session.claudeAuthoritativeEventSourceID = UUID()
        await controller.emitBetweenRuns(runtimeInit("stale-launch"))
        await controller.emitBetweenRuns(.stream(AIStreamResult(type: "content", text: "after stale init")))
        let staleInitOutcome = await XCTWaiter.fulfillment(of: [afterStaleInitDelivered], timeout: 2)
        XCTAssertEqual(staleInitOutcome, .completed)
        XCTAssertEqual(session.providerSessionID, "current-launch")
    }

    /// A run-owned runtime error shows the run's text received before it above the error row.
    func testClaudeRunTextBufferedBeforeRuntimeErrorIsShownAboveIt() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        let controller = StreamLifecycleFakeController(secondSend: .contentThenProcessExits)
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        for text in ["First", "Second"] {
            let user = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(user)
            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            let settled = expectation(description: "Run \(text) ends")
            Task {
                await task.value
                settled.fulfill()
            }
            let outcome = await XCTWaiter.fulfillment(of: [settled], timeout: 2)
            XCTAssertEqual(outcome, .completed, "Run \(text) must not wait forever.")
            // The harness's barrier hook does not finalize rows; apply the production finalization.
            harness.host.finalizeStreamingItems(in: session)
        }
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }
        XCTAssertEqual(session.runState, .failed)
        let partialIndex = try XCTUnwrap(
            session.items.firstIndex { $0.kind == .assistant && $0.text == "Partial answer" },
            "\(session.items.map { "\($0.kind):\($0.text)" })"
        )
        let errorIndex = try XCTUnwrap(session.items.firstIndex { $0.kind == .error })
        XCTAssertLessThan(partialIndex, errorIndex, "Text received before the error must be shown above it.")
    }

    /// A runtime error read between runs is delivered through the background stream path, so its
    /// row is recorded as between-run output instead of being appended as the next run's boundary.
    func testClaudeBetweenRunRuntimeErrorIsRecordedAsBackgroundRow() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        // Only one send happens here, so the fixture's second-send behavior is unused.
        let controller = StreamLifecycleFakeController(secondSend: .streamReplaced)
        let errorText = "Claude process exited unexpectedly."
        let errorDelivered = expectation(description: "Between-run runtime error reaches the background path")
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            claudeControllerFactory: { _, _, _, _ in controller },
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
            handleHeadlessStreamResult: { result in
                guard let host, let runID = session.runID,
                      let attemptID = session.activeRunAttemptID else { return }
                await host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            },
            handleBackgroundNativeStreamResult: { result, sourceID in
                await host?.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                if result.type == "error", result.text == errorText {
                    errorDelivered.fulfill()
                }
            },
            autoSignalACPRouting: true
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer {
            session.agentTask?.cancel()
            harness.host.clearPendingAssistantDelta(session)
        }

        let user = AgentChatItem.user("First", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(user)
        _ = await harness.service.startRun(
            tabID: session.tabID, session: session,
            initialUserMessage: user.text, initialMessageForRun: user.text,
            attachments: []
        )
        let task = try XCTUnwrap(session.agentTask)
        await task.value
        XCTAssertEqual(session.runState, .completed)
        let runID = try XCTUnwrap(session.runID)
        addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }

        await controller.emitBetweenRuns(.error("  \(errorText)\n"))
        let outcome = await XCTWaiter.fulfillment(of: [errorDelivered], timeout: 2)
        XCTAssertEqual(outcome, .completed, "The trimmed error must be delivered through the background path.")
        let errorRows = session.items.filter { $0.kind == .error && $0.text == errorText }
        XCTAssertEqual(errorRows.count, 1)
        XCTAssertTrue(errorRows.allSatisfy { session.backgroundRowIDs.contains($0.id) })
        XCTAssertEqual(session.runState, .completed, "Between-run errors change no run state.")
    }

    /// Background output can arrive while a newer run shows its own status; it must not clear it.
    func testClaudeBackgroundOutputLeavesActiveRunStatusUntouched() async {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.runState = .running
        session.setRunningStatus("Thinking…", source: .transport)

        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "content", text: "Background"), session: session
        )
        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "final_content", text: "Background"), session: session
        )
        await harness.host.test_handleBackgroundNativeStreamResult(
            AIStreamResult(type: "message_stop", text: ""), session: session
        )

        XCTAssertEqual(session.runningStatusText, "Thinking…")
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["Background"])
    }

    /// Background `final_content` replaces its own message's row even after an interleaved system
    /// row ended that row's streaming segment, and never an earlier turn's answer.
    func testClaudeBackgroundFinalContentReplacesOwnRowAcrossSystemRowButNotEarlierAnswer() async {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(AgentChatItem.assistant("Earlier answer", sequenceIndex: session.nextSequenceIndex))

        func deliver(_ type: String, _ text: String) async {
            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: type, text: text), session: session
            )
        }
        await deliver("content", "partial")
        await deliver("system", "interleaved notice")
        await deliver("content", " remainder")
        await deliver("final_content", "authoritative")
        await deliver("message_stop", "")
        // A later background message without streamed content must not overwrite either answer.
        await deliver("final_content", "next message")
        await deliver("message_stop", "")

        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["Earlier answer", "authoritative", "next message"]
        )
        XCTAssertTrue(session.backgroundCurrentAssistantRowIDs.isEmpty)
    }

    /// A run's terminal finalization (which ends every streaming row) can land inside a background
    /// message delivered by a draining router. That message's further text and authoritative
    /// `final_content` still go to its own row instead of duplicating it.
    func testClaudeBackgroundMessageKeepsItsRowAcrossRunTerminalFinalization() async {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))

        func background(_ type: String, _ text: String) async {
            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: type, text: text), session: session
            )
        }
        await background("content", "partial")
        // The terminal commit barrier's `finalizeStreamingItems` hook for a run committing now.
        harness.host.finalizeStreamingItems(in: session)
        await background("content", " more")
        harness.host.finalizeStreamingItems(in: session)
        await background("final_content", "authoritative answer")
        await background("message_stop", "")
        // The ended message's row is not continued by the next background message.
        await background("content", "next message")
        await background("message_stop", "")

        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["authoritative answer", "next message"]
        )
        XCTAssertTrue(session.backgroundCurrentAssistantRowIDs.isEmpty)
    }

    /// Background output delivered while a run streams (a replaced stream's router draining held
    /// output) neither ends the run's streaming row nor is continued by it — also when the background
    /// segment end arrives before any background row exists, and across the other delivery's system
    /// rows in either direction.
    func testClaudeBackgroundSegmentEndDoesNotSplitActiveRunsStreamingRow() async {
        struct Step {
            let isRun: Bool
            let type: String
            let text: String
        }
        let backgroundSystemRowBetweenRunDeltas = [
            Step(isRun: true, type: "content", text: "Hel"),
            Step(isRun: false, type: "system", text: "interleaved notice"),
            Step(isRun: true, type: "content", text: "lo"),
            Step(isRun: true, type: "final_content", text: "Hello")
        ]
        let runSystemRowBetweenBackgroundDeltas = [
            Step(isRun: false, type: "content", text: "late"),
            Step(isRun: true, type: "system", text: "run notice"),
            Step(isRun: false, type: "content", text: " output"),
            Step(isRun: false, type: "final_content", text: "late output"),
            Step(isRun: false, type: "message_stop", text: ""),
            Step(isRun: true, type: "content", text: "Hello")
        ]
        let backgroundErrorRowBetweenRunDeltas = [
            Step(isRun: true, type: "content", text: "Hel"),
            Step(isRun: false, type: "error", text: "Claude process exited unexpectedly."),
            Step(isRun: true, type: "content", text: "lo"),
            Step(isRun: true, type: "final_content", text: "Hello")
        ]
        let cases: [(name: String, steps: [Step], expected: [String])] = [
            ("background system row between run deltas", backgroundSystemRowBetweenRunDeltas, ["Hello"]),
            ("background error row between run deltas", backgroundErrorRowBetweenRunDeltas, ["Hello"]),
            ("run system row between background deltas", runSystemRowBetweenBackgroundDeltas, ["late output", "Hello"])
        ]
        for testCase in cases {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            var host: AgentModeViewModel?
            let harness = makeHarness(
                recorder: LifecycleRecorder(),
                flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
            )
            host = harness.host
            harness.host.test_installLiveSession(session)
            defer { harness.host.clearPendingAssistantDelta(session) }
            let runID = UUID()
            session.runID = runID
            session.runState = .running
            let attemptID = session.beginRunAttempt(source: "test.interleavedSystemRows").attemptID
            session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))
            for step in testCase.steps {
                let result = AIStreamResult(type: step.type, text: step.text)
                if step.isRun {
                    await harness.host.test_handleStreamResult(
                        result, session: session, runID: runID, runAttemptID: attemptID
                    )
                } else {
                    await harness.host.test_handleBackgroundNativeStreamResult(result, session: session)
                }
            }
            harness.host.flushPendingAssistantDelta(session)
            XCTAssertEqual(
                session.items.filter { $0.kind == .assistant }.map(\.text),
                testCase.expected,
                testCase.name
            )
        }
        for backgroundHasContent in [true, false] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            var host: AgentModeViewModel?
            let harness = makeHarness(
                recorder: LifecycleRecorder(),
                flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
            )
            host = harness.host
            harness.host.test_installLiveSession(session)
            defer { harness.host.clearPendingAssistantDelta(session) }
            let runID = UUID()
            session.runID = runID
            session.runState = .running
            let attemptID = session.beginRunAttempt(source: "test.interleavedSegments").attemptID
            session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))

            func run(_ type: String, _ text: String) async {
                await harness.host.test_handleStreamResult(
                    AIStreamResult(type: type, text: text), session: session, runID: runID, runAttemptID: attemptID
                )
            }
            func background(_ type: String, _ text: String) async {
                await harness.host.test_handleBackgroundNativeStreamResult(
                    AIStreamResult(type: type, text: text), session: session
                )
            }
            await run("content", "Hel")
            if backgroundHasContent {
                await background("content", "late output")
            }
            await background("message_stop", "")
            await run("content", "lo")
            await run("final_content", "Hello")

            XCTAssertEqual(
                session.items.filter { $0.kind == .assistant }.map(\.text),
                backgroundHasContent ? ["Hello", "late output"] : ["Hello"],
                "backgroundHasContent: \(backgroundHasContent)"
            )
        }
    }

    /// Between-run output that landed below a run's user row (before the run's start marker) is
    /// neither continued nor replaced by that run's own text.
    func testClaudeRunNeverMergesIntoOrReplacesBackgroundRowBelowItsUserRow() async {
        for backgroundMessageStopped in [false, true] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            var host: AgentModeViewModel?
            let harness = makeHarness(
                recorder: LifecycleRecorder(),
                flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
            )
            host = harness.host
            harness.host.test_installLiveSession(session)
            defer { harness.host.clearPendingAssistantDelta(session) }
            let runID = UUID()
            session.runID = runID
            session.runState = .running
            let attemptID = session.beginRunAttempt(source: "test.backgroundRowIsolation").attemptID
            session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))

            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: "content", text: "old output"), session: session
            )
            if backgroundMessageStopped {
                await harness.host.test_handleBackgroundNativeStreamResult(
                    AIStreamResult(type: "message_stop", text: ""), session: session
                )
            }
            // A still-streaming background row must not absorb the run's text; a finished one must
            // not be taken as the run's answer by a final_content without streamed text.
            let runResults = backgroundMessageStopped
                ? [AIStreamResult(type: "final_content", text: "run answer")]
                : [
                    AIStreamResult(type: "content", text: "run text"),
                    AIStreamResult(type: "final_content", text: "run answer")
                ]
            for result in runResults {
                await harness.host.test_handleStreamResult(
                    result, session: session, runID: runID, runAttemptID: attemptID
                )
            }

            XCTAssertEqual(
                session.items.filter { $0.kind == .assistant }.map(\.text),
                ["old output", "run answer"],
                "background message stopped: \(backgroundMessageStopped)"
            )
        }
    }

    /// Step 4d3a: marks `ids` as the local items of Claude history rows with no envelope digest (a
    /// missing digest still protects them).
    private func associateWithClaudeHistory(_ ids: [UUID], session: AgentTabSession) {
        session.providerHistoryRecovery = AgentSessionProviderHistoryRecovery(nativeItems: ids.enumerated().map { index, id in
            .init(
                providerRaw: "claude",
                nativeSessionID: "conv-1",
                nativeEntryID: "a\(index)",
                rowKindRaw: "assistantText",
                ordinal: 0,
                localItemID: id
            )
        })
        XCTAssertTrue(session.providerHistoryRecovery?.nativeItems.allSatisfy { $0.envelopeDigest == nil } ?? false)
    }

    /// Step 4d3a: a row associated to Claude's history is never extended by live text. The run's
    /// streamed delta and a between-run delta each start a new row; the associated rows keep their
    /// IDs and text.
    func testClaudeLiveDeltasNeverExtendAProviderHistoryAssociatedRow() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        let attemptID = session.beginRunAttempt(source: "test.associatedDeltas").attemptID
        func run(_ type: String, _ text: String) async {
            await harness.host.test_handleStreamResult(
                AIStreamResult(type: type, text: text), session: session, runID: runID, runAttemptID: attemptID
            )
            harness.host.flushPendingAssistantDelta(session)
        }
        func background(_ type: String, _ text: String) async {
            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: type, text: text), session: session
            )
        }

        await run("content", "live")
        let runRow = try XCTUnwrap(session.items.last)
        XCTAssertEqual(runRow.kind, .assistant)
        XCTAssertTrue(runRow.isStreaming)
        associateWithClaudeHistory([runRow.id], session: session)
        await run("content", " more")
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["live", " more"])
        XCTAssertEqual(session.items.first { $0.kind == .assistant }?.id, runRow.id)

        await background("content", "between")
        let backgroundRow = try XCTUnwrap(session.items.last)
        XCTAssertEqual(session.backgroundCurrentAssistantRowIDs[nil], backgroundRow.id)
        associateWithClaudeHistory([runRow.id, backgroundRow.id], session: session)
        await background("content", " runs")
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["live", " more", "between", " runs"])
        XCTAssertEqual(session.items.first { $0.text == "between" }?.id, backgroundRow.id)
        XCTAssertEqual(session.backgroundCurrentAssistantRowIDs[nil], session.items.last?.id, "the new row is the message's row")
    }

    /// Step 4d3a: `final_content` keeps its existing target selection, but a target associated to
    /// Claude's history is never rewritten: equal text leaves it unchanged with no duplicate, other
    /// text appends a new visible row. The background message's row pointer is still retired.
    func testClaudeFinalContentNeverRewritesAProviderHistoryAssociatedRow() async throws {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        defer { harness.host.clearPendingAssistantDelta(session) }
        session.appendItem(AgentChatItem.user("Question", sequenceIndex: session.nextSequenceIndex))
        let imported = AgentChatItem.assistant("ALPHA-7", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(imported)
        associateWithClaudeHistory([imported.id], session: session)
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        let attemptID = session.beginRunAttempt(source: "test.associatedFinalContent").attemptID
        func run(_ type: String, _ text: String) async {
            await harness.host.test_handleStreamResult(
                AIStreamResult(type: type, text: text), session: session, runID: runID, runAttemptID: attemptID
            )
        }
        func background(_ type: String, _ text: String) async {
            await harness.host.test_handleBackgroundNativeStreamResult(
                AIStreamResult(type: type, text: text), session: session
            )
        }

        // Active run: the selected target is the associated row.
        let before = session.items
        await run("final_content", "ALPHA-7")
        XCTAssertEqual(session.items.map(\.id), before.map(\.id), "equal text: no duplicate")
        XCTAssertEqual(session.items.map(\.text), before.map(\.text), "equal text: unchanged")
        await run("final_content", "ALPHA-8")
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["ALPHA-7", "ALPHA-8"])
        XCTAssertEqual(session.items.first { $0.kind == .assistant }?.id, imported.id, "the associated row is preserved")

        // Background message: its current row is associated.
        session.runState = .completed
        await background("content", "between")
        let backgroundRow = try XCTUnwrap(session.items.last)
        associateWithClaudeHistory([imported.id, backgroundRow.id], session: session)
        let beforeEqual = session.items.map(\.id)
        await background("final_content", "between")
        XCTAssertEqual(session.items.map(\.id), beforeEqual, "equal text: no duplicate")
        XCTAssertEqual(session.items.last?.text, "between")
        XCTAssertTrue(session.backgroundCurrentAssistantRowIDs.isEmpty, "the background pointer is retired")
        await background("message_stop", "")

        await background("content", "next")
        let nextRow = try XCTUnwrap(session.items.last)
        associateWithClaudeHistory([imported.id, backgroundRow.id, nextRow.id], session: session)
        await background("final_content", "authoritative")
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["ALPHA-7", "ALPHA-8", "between", "next", "authoritative"]
        )
        XCTAssertEqual(session.items.first { $0.text == "next" }?.id, nextRow.id, "the associated row is preserved")
        XCTAssertTrue(session.backgroundCurrentAssistantRowIDs.isEmpty, "the background pointer is retired")
    }

    // MARK: Step 4d3b canonical owner of qualified live output (inactive)

    private func liveComplete(_ entry: String, text: String, conversation: String = "conv-1") throws -> ClaudeLiveTranscriptCompleteText {
        let row = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: conversation, nativeEntryID: entry, text: text))
        return try ClaudeLiveTranscriptCompleteText(
            nativeSessionID: conversation,
            nativeEntryID: entry,
            localItemID: XCTUnwrap(row.localItemID),
            text: text,
            envelopeDigest: row.envelopeDigest
        )
    }

    /// The translated `content` result carrying complete-text evidence, as the producer attaches it.
    private func carried(_ complete: ClaudeLiveTranscriptCompleteText, producer: UUID) -> AIStreamResult {
        var result = AIStreamResult(type: "content", text: complete.text)
        result.claudeLiveTranscriptEvidence = .init(producerLaunchToken: producer, kind: .completeText(complete))
        return result
    }

    /// A metadata-only carrier.
    private func carrier(_ kind: ClaudeLiveTranscriptEvidence.Kind, producer: UUID) -> AIStreamResult {
        var result = AIStreamResult(type: AIStreamResult.lifecycleType, text: nil)
        result.claudeLiveTranscriptEvidence = .init(producerLaunchToken: producer, kind: kind)
        return result
    }

    /// The harness is returned so its run service stays alive for the test's duration.
    private func makeLiveOwnerSession() -> (AgentTabSession, LifecycleHarness, UUID, UUID) {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        var host: AgentModeViewModel?
        let harness = makeHarness(
            recorder: LifecycleRecorder(),
            flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) }
        )
        host = harness.host
        harness.host.test_installLiveSession(session)
        session.appendItem(AgentChatItem.user("Reply with exactly: ALPHA-7", sequenceIndex: session.nextSequenceIndex))
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        let attemptID = session.beginRunAttempt(source: "test.liveOwner").attemptID
        return (session, harness, runID, attemptID)
    }

    /// Step 4d3b: an accepted complete text flushes older buffered run text, then appends the reader's
    /// canonical row (non-streaming, deterministic ID) and its ledger entry together; a duplicate is a
    /// no-op; a later equal `final_content` and an agreeing result change nothing. A changed text under
    /// the same key preserves the old row, shows the incoming text unidentified, refuses the producer
    /// and invalidates every Claude proof; a proof is never healed by a new producer.
    func testClaudeLiveCompleteTextInsertsCanonicalRowOnceAndConflictsInvalidateProofs() async throws {
        let (session, harness, runID, attemptID) = makeLiveOwnerSession()
        let host = harness.host
        defer {
            host.clearPendingAssistantDelta(session)
            withExtendedLifetime(harness) {}
        }
        func run(_ result: AIStreamResult) async {
            await host.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
        }
        let producer = UUID()
        let complete = try liveComplete("a1", text: "ALPHA-7")

        await run(AIStreamResult(type: "content", text: "Earlier"))
        XCTAssertEqual(session.pendingAssistantDelta, "Earlier", "buffered generic text")
        session.isDirty = false
        await run(carried(complete, producer: producer))
        XCTAssertEqual(session.pendingAssistantDelta, "")
        XCTAssertEqual(session.items.map(\.kind), [.user, .assistant, .assistant])
        XCTAssertEqual(session.items[1].text, "Earlier", "the older buffer is materialized first")
        XCTAssertFalse(session.items[1].isStreaming, "and its segment ended")
        let canonical = try XCTUnwrap(session.items.last)
        XCTAssertEqual(canonical.id, complete.localItemID)
        XCTAssertEqual(canonical.text, "ALPHA-7")
        XCTAssertFalse(canonical.isStreaming)
        XCTAssertEqual(session.providerHistoryRecovery?.nativeItems, [complete.ledgerItem])
        XCTAssertNil(session.providerHistoryRecovery?.lastImportCommit, "no import receipt")
        XCTAssertTrue(session.isDirty)

        let snapshot = session.items
        let ledger = session.providerHistoryRecovery
        await run(carried(complete, producer: producer))
        await run(AIStreamResult(type: "final_content", text: "ALPHA-7"))
        await run(carrier(.resultAgreement(localItemID: complete.localItemID, text: "ALPHA-7"), producer: producer))
        host.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items, snapshot, "duplicate, equal final text and agreement are no-ops")
        XCTAssertEqual(session.providerHistoryRecovery, ledger)
        XCTAssertFalse(session.claudeLiveTranscriptRefusedProducers.contains(producer))

        // Changed text under the same native key: preserved, displayed unidentified, refused.
        let changed = try liveComplete("a1", text: "ALPHA-8")
        await run(carried(changed, producer: producer))
        host.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items.first { $0.id == complete.localItemID }?.text, "ALPHA-7", "the old row is preserved")
        XCTAssertEqual(session.items.last?.text, "ALPHA-8")
        XCTAssertNotEqual(session.items.last?.id, changed.localItemID, "the incoming text is unidentified")
        XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(producer))
        let invalidated = try XCTUnwrap(session.providerHistoryRecovery?.nativeItems.first)
        XCTAssertNil(invalidated.envelopeDigest, "the proof is invalidated")
        XCTAssertEqual(invalidated.key, complete.ledgerKey, "key and local item are kept")
        XCTAssertEqual(invalidated.localItemID, complete.localItemID)
        // Legacy display behavior, not under test here: without ending the segment, the next refused
        // (unidentified) complete text would merge into this still-streaming legacy row.
        host.endActiveAssistantSegment(session)

        // A new producer never heals the conversation: its complete text shows unidentified.
        let later = try liveComplete("a2", text: "BRAVO")
        await run(carried(later, producer: UUID()))
        host.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items.last?.text, "BRAVO")
        XCTAssertNotEqual(session.items.last?.id, later.localItemID)
        XCTAssertEqual(session.providerHistoryRecovery?.nativeItems.count, 1, "no new ledger entry")
        XCTAssertNil(session.providerHistoryRecovery?.nativeItems.first?.envelopeDigest, "never healed")
    }

    /// Step 4d3b: disqualification (or a disagreeing result, a background complete text, or an ID
    /// collision) refuses the producer and clears every Claude proof, typed and raw, keeping keys,
    /// local items, other members, rows and receipts; a refused producer never qualifies later.
    func testClaudeLiveRefusalsInvalidateProofsAndRefusedProducersNeverRequalify() async throws {
        let (session, harness, runID, attemptID) = makeLiveOwnerSession()
        let host = harness.host
        defer {
            host.clearPendingAssistantDelta(session)
            withExtendedLifetime(harness) {}
        }
        func run(_ result: AIStreamResult) async {
            await host.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
        }
        let receipt = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: UUID(), providerRaw: "claude", conversationID: "conv-1", committedAt: Date(), rowCount: 0, target: nil
        )
        let proven = AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: "claude", nativeSessionID: "conv-0", nativeEntryID: "p1", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "a", count: 64), extras: ["future": .bool(true)]
        )
        let malformed = AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: "claude", nativeSessionID: "conv-0", nativeEntryID: "p2", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), extras: ["envelopeDigest": .string("NOT-HEX"), "future": .bool(true)]
        )
        let codex = AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: "codex", nativeSessionID: "t1", nativeEntryID: "i1", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "b", count: 64)
        )
        session.providerHistoryRecovery = AgentSessionProviderHistoryRecovery(
            nativeItems: [proven, malformed, codex], lastImportCommit: receipt, extras: ["ledgerFuture": .string("kept")]
        )
        let itemsBefore = session.items
        session.isDirty = false

        let producer = UUID()
        await run(carrier(.disqualified(.unsupportedPayload), producer: producer))
        XCTAssertEqual(session.items, itemsBefore, "no transcript change")
        XCTAssertTrue(session.isDirty, "a ledger-only change is marked dirty")
        let ledger = try XCTUnwrap(session.providerHistoryRecovery)
        XCTAssertEqual(ledger.nativeItems.map(\.key), [proven.key, malformed.key, codex.key])
        XCTAssertEqual(ledger.nativeItems.map(\.localItemID), [proven.localItemID, malformed.localItemID, codex.localItemID])
        XCTAssertEqual(ledger.nativeItems.map(\.envelopeDigest), [nil, nil, codex.envelopeDigest], "Codex rows untouched")
        XCTAssertEqual(ledger.nativeItems[0].extras, ["future": .bool(true)])
        XCTAssertEqual(ledger.nativeItems[1].extras, ["future": .bool(true)], "the raw proof member is cleared too")
        XCTAssertEqual(ledger.lastImportCommit, receipt)
        XCTAssertEqual(ledger.extras, ["ledgerFuture": .string("kept")])

        // The refused producer never qualifies, even in a conversation with no proofless row.
        let fresh = try liveComplete("f1", text: "FRESH", conversation: "conv-2")
        await run(carried(fresh, producer: producer))
        host.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items.last?.text, "FRESH")
        XCTAssertNotEqual(session.items.last?.id, fresh.localItemID)
        XCTAssertFalse(session.providerHistoryRecovery?.nativeItems.contains { $0.nativeSessionID == "conv-2" } ?? true)

        // A disagreeing result refuses its producer (here: no identified row exists).
        let second = UUID()
        await run(carrier(.resultAgreement(localItemID: UUID(), text: "X"), producer: second))
        XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(second))

        // A background complete text is never accepted: shown as background output and refused.
        let third = UUID()
        let between = try liveComplete("b1", text: "BETWEEN", conversation: "conv-3")
        await host.test_handleBackgroundNativeStreamResult(carried(between, producer: third), session: session)
        XCTAssertEqual(session.items.last?.text, "BETWEEN")
        XCTAssertNotEqual(session.items.last?.id, between.localItemID)
        XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(third))

        // A local row already holding the deterministic ID without its ledger entry is a collision.
        let fourth = UUID()
        let colliding = try liveComplete("c1", text: "COLLIDE", conversation: "conv-4")
        session.appendItem(AgentChatItem.assistant("Other").replacingID(colliding.localItemID))
        await run(carried(colliding, producer: fourth))
        host.flushPendingAssistantDelta(session)
        XCTAssertEqual(session.items.first { $0.id == colliding.localItemID }?.text, "Other", "the old row is preserved")
        XCTAssertEqual(session.items.last?.text, "COLLIDE")
        XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(fourth))
        XCTAssertFalse(session.providerHistoryRecovery?.nativeItems.contains { $0.nativeSessionID == "conv-4" } ?? true)
    }

    /// Step 4d3b (review B F5/F6): a complete text whose ID or digest is not the reader's projection of
    /// its entry, or whose conversation is not the tab's known Claude conversation, is refused: no row
    /// or ledger entry, the text shows unidentified. The exact projection is then accepted.
    func testClaudeLiveCompleteTextMustBeTheReadersProjectionForTheTabsConversation() async throws {
        let (session, harness, runID, attemptID) = makeLiveOwnerSession()
        let host = harness.host
        defer {
            host.clearPendingAssistantDelta(session)
            withExtendedLifetime(harness) {}
        }
        func run(_ result: AIStreamResult) async {
            await host.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
        }
        session.providerSessionID = "conv-1"
        let exact = try liveComplete("a1", text: "ALPHA-7")
        let cases: [(String, ClaudeLiveTranscriptCompleteText)] = try [
            ("another local ID", ClaudeLiveTranscriptCompleteText(
                nativeSessionID: exact.nativeSessionID, nativeEntryID: exact.nativeEntryID, localItemID: UUID(),
                text: exact.text, envelopeDigest: exact.envelopeDigest
            )),
            ("another digest", ClaudeLiveTranscriptCompleteText(
                nativeSessionID: exact.nativeSessionID, nativeEntryID: exact.nativeEntryID, localItemID: exact.localItemID,
                text: exact.text, envelopeDigest: String(repeating: "c", count: 64)
            )),
            ("another conversation", liveComplete("a1", text: "ALPHA-7", conversation: "conv-9"))
        ]
        for (name, complete) in cases {
            let producer = UUID()
            await run(carried(complete, producer: producer))
            host.flushPendingAssistantDelta(session)
            host.endActiveAssistantSegment(session)
            XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(producer), name)
            XCTAssertNil(session.providerHistoryRecovery, name)
            XCTAssertFalse(session.items.contains { $0.id == complete.localItemID }, name)
            XCTAssertEqual(session.items.last?.text, "ALPHA-7", "\(name): shown unidentified")
        }
        await run(carried(exact, producer: UUID()))
        XCTAssertEqual(session.items.last?.id, exact.localItemID)
        XCTAssertEqual(session.providerHistoryRecovery?.nativeItems, [exact.ledgerItem])
    }

    /// Step 4d3b (inactive; review A R1/R2 and B F4): through the real controller, translator, events
    /// stream, integrated runner, run service and view-model handler, an eligible producer's qualified
    /// turn inserts the canonical row with its proof while its carriers leave the run undisturbed.
    /// Afterwards, between runs, a direct disqualification with no later payload (an undecodable line)
    /// or a contradicting stdout tail drained at EOF reaches the owner and invalidates the proof.
    func testClaudeLiveEvidenceReachesTheOwnerThroughTheRunServiceAndLaterRefusalsInvalidateProofs() async throws {
        for refusal in ["undecodable line", "EOF tail"] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            let user = AgentChatItem.user("Reply with exactly: ALPHA-7", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(user)
            let controller = try BackgroundTranscriptController(liveTranscriptQualification: true)
            addTeardownBlock { await controller.shutdown() }
            let refused = expectation(description: "the refusal reaches the owner (\(refusal))")
            var host: AgentModeViewModel?
            let harness = makeHarness(
                recorder: LifecycleRecorder(),
                claudeControllerFactory: { _, _, _, _ in controller },
                flushPendingAssistantDelta: { host?.flushPendingAssistantDelta($0) },
                handleHeadlessStreamResult: { result in
                    guard let host, let runID = session.runID,
                          let attemptID = session.activeRunAttemptID else { return }
                    await host.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
                },
                handleBackgroundNativeStreamResult: { result, sourceID in
                    guard let host else { return }
                    await host.test_handleBackgroundNativeStreamResult(result, sourceID: sourceID, session: session)
                    if case .disqualified = result.claudeLiveTranscriptEvidence?.kind { refused.fulfill() }
                },
                autoSignalACPRouting: true
            )
            host = harness.host
            harness.host.test_installLiveSession(session)
            defer {
                session.agentTask?.cancel()
                harness.host.clearPendingAssistantDelta(session)
            }

            _ = await harness.service.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: user.text, initialMessageForRun: user.text,
                attachments: []
            )
            let task = try XCTUnwrap(session.agentTask)
            await task.value
            let runID = try XCTUnwrap(session.runID)
            addTeardownBlock { await MCPRoutingWaiter.cleanup(runID: runID) }
            XCTAssertEqual(session.runState, .completed, refusal)
            let ledgerItem = try XCTUnwrap(session.providerHistoryRecovery?.nativeItems.first, refusal)
            XCTAssertEqual(session.providerHistoryRecovery?.nativeItems.count, 1, refusal)
            XCTAssertNotNil(ledgerItem.envelopeDigest, refusal)
            let row = try XCTUnwrap(session.items.first { $0.id == ledgerItem.localItemID }, refusal)
            XCTAssertEqual(row.kind, .assistant)
            XCTAssertFalse(row.isStreaming)
            XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["ALPHA-7"], "carriers add no rows")
            XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.isEmpty, "the result agreed")

            if refusal == "undecodable line" {
                await controller.deliverUndecodableLine()
            } else {
                try await controller.deliverStdoutTailThenEOF(BackgroundTranscriptController.qualifiedResult("CONTRADICTION", outbound: UUID()))
            }
            let delivery = await XCTWaiter.fulfillment(of: [refused], timeout: 1)
            XCTAssertEqual(delivery, .completed, refusal)
            let invalidated = try XCTUnwrap(session.providerHistoryRecovery?.nativeItems.first, refusal)
            XCTAssertNil(invalidated.envelopeDigest, "\(refusal): the proof is invalidated")
            XCTAssertEqual(invalidated.localItemID, ledgerItem.localItemID, refusal)
            let launchToken = await controller.liveLaunchToken
            let producer = try XCTUnwrap(launchToken, refusal)
            XCTAssertTrue(session.claudeLiveTranscriptRefusedProducers.contains(producer), refusal)
        }
    }
}

/// Fake runtime whose events stream ends during the second send. Like the real controller, it
/// replaces a stream only after finishing it, and creates the new one on the next subscription.
private actor StreamLifecycleFakeController: NativeAgentRuntimeControlling {
    enum SecondSend {
        /// The process exits after receiving the message: stdout EOF fails the in-flight turn and
        /// finishes the stream.
        case processExits
        /// The stream is finished after carrying part of the run's output, and the turn continues
        /// on a new stream (for example a relaunch inside the send path).
        case streamReplaced
        /// The run receives part of its answer, then the process exits.
        case contentThenProcessExits
        /// The run is answered on the same stream, by the same process.
        case answersOnSameStream
        /// The provider reports the run's turn failed; the process keeps running (ordinary).
        case providerReportsFailure
    }

    /// Turns this fake failed by process exit, as the real controller records them on EOF.
    private var processLostTurnIDs: Set<UUID> = []

    func turnEndedByProcessLoss(_ turnID: UUID) -> Bool {
        processLostTurnIDs.remove(turnID) != nil
    }

    private let secondSend: SecondSend
    private var stream: AsyncStream<NativeAgentRuntimeEvent>
    private var continuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
    private var generation: UInt64 = 0
    private var sentCount = 0

    init(secondSend: SecondSend) {
        self.secondSend = secondSend
        let (stream, continuation) = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() {
        guard continuation == nil else { return }
        let (stream, continuation) = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
        generation += 1
    }

    func resetEventsStreamForNewRun() {
        continuation?.finish()
        continuation = nil
        ensureEventsStreamReady()
    }

    func eventsSubscription() -> NativeAgentRuntimeEventsSubscription {
        ensureEventsStreamReady()
        return NativeAgentRuntimeEventsSubscription(events: stream, generation: generation)
    }

    func emitEventMarker(_ id: UUID) -> UInt64? {
        guard let continuation else { return nil }
        continuation.yield(.marker(id))
        return generation
    }

    /// Yields an event on the current stream outside any send (between runs).
    func emitBetweenRuns(_ event: NativeAgentRuntimeEvent) {
        continuation?.yield(event)
    }

    func startOrResume(
        existingSessionID _: String?, model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?, systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        await currentSessionRef()
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "process-exit-fixture")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_: String) async throws -> UUID {
        sentCount += 1
        let turnID = UUID()
        if sentCount == 1 {
            continuation?.yield(.stream(AIStreamResult(type: "content", text: "First answer")))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .completed))
            return turnID
        }
        switch secondSend {
        case .processExits:
            processLostTurnIDs.insert(turnID)
            continuation?.yield(.error("Claude process exited unexpectedly."))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .failed))
            continuation?.finish()
            continuation = nil
        case .contentThenProcessExits:
            processLostTurnIDs.insert(turnID)
            continuation?.yield(.stream(AIStreamResult(type: "content", text: "Partial answer")))
            continuation?.yield(.error("Claude process exited unexpectedly."))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .failed))
            continuation?.finish()
            continuation = nil
        case .answersOnSameStream:
            continuation?.yield(.stream(AIStreamResult(type: "content", text: "Run answer")))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .completed))
        case .providerReportsFailure:
            continuation?.yield(.error("Model refused the request."))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .failed))
        case .streamReplaced:
            continuation?.yield(.stream(AIStreamResult(type: "content", text: "Before restart")))
            continuation?.finish()
            continuation = nil
            ensureEventsStreamReady()
            continuation?.yield(.stream(AIStreamResult(type: "content", text: "Real answer")))
            continuation?.yield(.turnCompleted(turnID: turnID, status: .completed))
        }
        return turnID
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        continuation?.finish()
        continuation = nil
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}

/// Only provider launch/control and user-message writes are faked. All inbound events and their
/// buffering/turn-completion behavior belong to the real Claude controller, not a copied model.
private actor BackgroundTranscriptController: NativeAgentRuntimeControlling {
    private let controller: ClaudeNativeProcessSessionController
    private let qualifiesLiveTranscript: Bool
    private(set) var sentMessages: [String] = []
    /// Step 4d3b: the eligible synthetic launch standing in for the spawned process.
    private(set) var liveLaunchToken: UUID?
    private static let fixtureSessionID = "background-transcript-fixture"

    init(liveTranscriptQualification: Bool = false) throws {
        qualifiesLiveTranscript = liveTranscriptQualification
        controller = try ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared,
            liveTranscriptQualificationEnabled: liveTranscriptQualification
        )
    }

    /// The current app's success result attributed to `outbound` (Step 4d3b O19 shape).
    static func qualifiedResult(_ text: String, outbound: UUID) -> [String: Any] {
        [
            "type": "result", "subtype": "success", "is_error": false, "result": text,
            "session_id": fixtureSessionID, "uuid": UUID().uuidString, "num_turns": 1, "permission_denials": [Any](),
            "terminal_reason": "completed", "stop_reason": "end_turn", "safety_stops": 0,
            "user_message_uuid": outbound.uuidString.lowercased(), "user_message_uuids": [outbound.uuidString.lowercased()]
        ]
    }

    /// Step 4d3b: one O19 turn of the current app (no replay; consumed-user attribution) from an
    /// eligible synthetic launch, with the outbound identity the real write notes.
    private func sendQualified(_ text: String) async -> UUID {
        if liveLaunchToken == nil {
            liveLaunchToken = await controller.test_beginSyntheticUsageLaunch().token
        }
        let turnID = await controller.test_beginTurnTracking()
        let outbound = UUID()
        await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: text)
        let entry = UUID().uuidString.lowercased()
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "message": [
                "id": "msg_\(entry)", "type": "message", "role": "assistant", "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "ALPHA-7"]],
                "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 4, "output_tokens": 3]
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": Self.fixtureSessionID,
            "request_id": "req_\(entry)",
            "uuid": entry,
            "user_message_uuid": outbound.uuidString.lowercased(),
            "user_message_uuids": [outbound.uuidString.lowercased()]
        ])
        await controller.test_handleStreamPayload(Self.qualifiedResult("ALPHA-7", outbound: outbound))
        return turnID
    }

    /// An undecodable stdout line through the production line path (no later payload).
    func deliverUndecodableLine() async {
        await controller.test_handleLine(Data("{not json".utf8))
    }

    /// A final stdout record without its newline, then the launch's stdout EOF.
    func deliverStdoutTailThenEOF(_ payload: [String: Any]) async throws {
        guard let liveLaunchToken else { return }
        try await controller.test_handleStdoutChunk(JSONSerialization.data(withJSONObject: payload), launchToken: liveLaunchToken)
        await controller.test_handleStdoutEOF(launchToken: liveLaunchToken)
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        get async { await controller.hasTurnInFlight }
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async { await controller.events }
    }

    func ensureEventsStreamReady() async {
        await controller.ensureEventsStreamReady()
    }

    func resetEventsStreamForNewRun() async {
        await controller.resetEventsStreamForNewRun()
    }

    func eventsSubscription() async -> NativeAgentRuntimeEventsSubscription {
        await controller.eventsSubscription()
    }

    func emitEventMarker(_ id: UUID) async -> UInt64? {
        await controller.emitEventMarker(id)
    }

    func startOrResume(
        existingSessionID _: String?, model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?, systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        await currentSessionRef()
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "background-transcript-fixture")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        if qualifiesLiveTranscript { return await sendQualified(text) }
        let turnID = await controller.test_beginTurnTracking()
        await emitResponse(sentMessages.count == 1 ? "Waiting for background build" : "Current progress answer")
        return turnID
    }

    func emitResponse(_ text: String) async {
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "background-transcript-fixture",
            "uuid": UUID().uuidString,
            "message": [
                "id": UUID().uuidString,
                "role": "assistant",
                "content": [["type": "text", "text": text]]
            ] as [String: Any]
        ])
        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "success",
            "session_id": "background-transcript-fixture",
            "uuid": UUID().uuidString,
            "result": text,
            "stop_reason": "end_turn"
        ])
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        await controller.shutdown()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}
