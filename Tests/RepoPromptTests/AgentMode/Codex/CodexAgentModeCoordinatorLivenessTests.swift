import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorLivenessTests: XCTestCase {
    func testActiveThreadSnapshotCountsAsWatchdogLivenessAndReconcilesWaitingFlags() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: ["waiting_for_user_input"]))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let waitingStatus = "Codex reports it is waiting for user input…"

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)

        try await waitUntil {
            controller.readSnapshotCountSync() > 0 && session.runningStatusText == waitingStatus
        }

        XCTAssertEqual(session.runningStatusText, waitingStatus)
        XCTAssertFalse(session.items.contains { item in
            item.kind == .error && item.text.contains("Repo Prompt thinks Codex has stalled")
        })
    }

    func testStructuredLivenessAdvancesLifecycleWithoutTranscriptRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items
        let previousSequence = session.activeRunLiveness?.lastAcceptedSequence ?? 0

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .livenessActivity(.init(
                kind: .mcpToolProgress,
                method: "item/mcpToolCall/progress",
                threadID: "fake",
                turnID: "turn",
                itemID: "item",
                activeFlags: ["waiting_for_user_input"],
                message: "progress"
            )),
            session: session
        )

        XCTAssertEqual(session.items, baselineItems)
        XCTAssertGreaterThan(session.activeRunLiveness?.lastAcceptedSequence ?? 0, previousSequence)
        XCTAssertEqual(session.activeRunLiveness?.stage, .running)
        XCTAssertEqual(session.runningStatusText, "Codex reports it is waiting for user input…")
        XCTAssertEqual(session.runState, .running)
    }

    func testUnmatchedCompletionOnlyWebResultPreservesArgsForPersistenceAndReplay() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let invocationID = UUID()
        let argsJSON = #"{"action":"find_in_page","url":"https://example.com/docs","pattern":"install"}"#
        let resultJSON = #"{"status":"completed","match_count":2}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "search",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: false
            ),
            session: session
        )

        let item = try XCTUnwrap(session.items.last)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.toolInvocationID, invocationID)
        XCTAssertEqual(item.toolArgsJSON, argsJSON)
        let livePresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "search")
        )
        XCTAssertEqual(livePresentation.title, "Find In Page")

        let persisted = AgentChatItemPersist(from: item)
        let restored = persisted.toItem()
        XCTAssertEqual(restored.toolInvocationID, invocationID)
        let restoredPresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: restored, normalizedToolName: "search")
        )
        XCTAssertEqual(restoredPresentation.title, "Find In Page")
        XCTAssertEqual(restoredPresentation.detailText, "2 matches")
    }

    func testStructuredRetryAndMissingMetadataFallbackRemainActiveWithoutRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "provider retry",
                willRetry: true,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.activeRunLiveness?.retryIntent, .providerManaged)
        XCTAssertEqual(session.items, baselineItems)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "Reconnecting... legacy payload",
                willRetry: nil,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testStructuredFailedCompletionUsesOneTerminalCommitAndPreservesTail() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("assistant tail"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "authoritative provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "duplicate provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .error("Codex transport closed unexpectedly."),
            session: session
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.activeRunOwnership)
        let revision = session.lastTerminalCommitRevision
        XCTAssertNotNil(revision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision?.providerDrainGeneration, session.providerTerminalDrainGeneration)
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .error }.map(\.kind),
            [.assistant, .error]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .error }.map(\.text),
            ["authoritative provider error"]
        )
    }

    func testTurnCompletionCoalescesBufferedAssistantTailBeforeTerminalSeal() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))
        let commandInvocationID = UUID()
        session.appendItem(.toolResult(
            name: "bash",
            invocationID: commandInvocationID,
            argsJSON: "{}",
            resultJSON: #"{"status":"completed"}"#,
            isError: false,
            sequenceIndex: session.nextSequenceIndex
        ))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        let streamingPrefix = try XCTUnwrap(session.items.last)
        XCTAssertEqual(streamingPrefix.kind, .assistant)
        XCTAssertEqual(streamingPrefix.text, "answer")
        XCTAssertTrue(streamingPrefix.isStreaming)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("."),
            session: session
        )
        XCTAssertEqual(session.pendingAssistantDelta, ".")
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        session.pendingCommandRunningByKey["terminal-test"] = .init(
            invocationID: commandInvocationID,
            processID: nil,
            appendedOutput: nil,
            sealsAssistantBoundary: false
        )
        session.pendingCommandRunningFlushTask = Task {}
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer."])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
        XCTAssertNil(session.pendingCommandRunningFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(revision.terminalState, .completed)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(revision.assistantDeltaFlushGeneration, session.assistantDeltaFlushGeneration)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
    }

    func testTurnCompletionWaitsForLateAssistantCompletionBeforeTerminalCommit() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "partial final summary is complete")),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final summary is complete"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
    }

    func testAssistantCompletionBeforeTurnCompletionUsesFastTerminalPath() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "partial final summary is complete")),
            session: session
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final summary is complete"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testTurnCompletionSettleTimeoutCommitsPartialAssistantWithoutHanging() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))

        await viewModel.test_codexCoordinator.test_forcePendingCodexTerminalSettleTimeout(session: session)

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testTurnStartedDuringAssistantSettleCommitsPendingTerminalBeforeNewTurn() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "next-turn"),
            session: session
        )

        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
    }

    func testDifferentTurnCompletionDuringAssistantSettleCommitsPendingTerminal() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let runID = try XCTUnwrap(session.runID)
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "next-turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        session.codexRoutingObservedTurnID = "next-turn"

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "next-turn", status: .completed),
            session: session
        )

        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
    }

    func testSettleScopeRejectsMatchingItemFromDifferentThread() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let previousSequence = session.activeRunLiveness?.lastAcceptedSequence ?? 0

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .livenessActivity(.init(
                kind: .mcpToolProgress,
                method: "item/mcpToolCall/progress",
                threadID: "different-thread",
                turnID: scope.turnID,
                itemID: scope.itemID,
                activeFlags: ["waiting_for_user_input"],
                message: "stale progress"
            )),
            session: session
        )

        XCTAssertEqual(session.activeRunLiveness?.lastAcceptedSequence ?? 0, previousSequence)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
    }

    func testInterruptedTurnCompletionBypassesAssistantSettle() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-final"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "partial final su", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .interrupted),
            session: session
        )

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertFalse(viewModel.test_codexCoordinator.test_hasPendingCodexTerminalSettle(tabID: session.tabID))
        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["partial final su"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .cancelled)
    }

    func testCanonicalAssistantCompletionReconcilesNoDeltaExactPrefixUTF8DuplicateAndEmpty() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: noDeltaScope, text: "no delta")),
            session: session
        )

        let exactScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-exact"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "exact", scope: exactScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: exactScope, text: "exact")),
            session: session
        )

        let prefixScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-prefix"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "answer", scope: prefixScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: prefixScope, text: "answer.")),
            session: session
        )

        let utf8Scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-utf8"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "👨", scope: utf8Scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let utf8Completion = CodexNativeSessionController.AssistantCompletionPayload(
            scope: utf8Scope,
            text: "👨‍👩‍👧"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )

        let removedScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-empty"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "remove me", scope: removedScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: removedScope, text: "")),
            session: session
        )

        let assistants = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.map(\.text), ["no delta", "exact", "answer.", "👨‍👩‍👧"])
        XCTAssertTrue(assistants.allSatisfy { !$0.isStreaming })
        XCTAssertNil(session.codexAssistantRowIDByScope[removedScope])
    }

    func testCanonicalAssistantCompletionFlushesEarlierPendingScopeFirst() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let firstScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-first"
        )
        let secondScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-second"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "first", scope: firstScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: secondScope, text: "second")),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["first", "second"])
        XCTAssertTrue(assistantItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalAssistantNonPrefixCompletionReplacesMappedRowAcrossToolBoundary() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-tool"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "draft response", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let originalRowID = try XCTUnwrap(session.items.last?.id)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "final response")),
            session: session
        )

        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items[0].id, originalRowID)
        XCTAssertEqual(session.items[0].kind, .assistant)
        XCTAssertEqual(session.items[0].text, "final response")
        XCTAssertFalse(session.items[0].isStreaming)
        XCTAssertEqual(session.items[1].kind, .toolCall)
    }

    func testCanonicalMCPResultOnlyDoesNotOverwriteDifferentInvocation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let firstInvocationID = UUID()
        let resultOnlyInvocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(
                name: "lookup",
                invocationID: firstInvocationID,
                argsJSON: #"{"query":"first"}"#
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "lookup",
                invocationID: resultOnlyInvocationID,
                argsJSON: #"{"query":"second"}"#,
                resultJSON: #"{"content":"second result"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.map(\.kind), [.toolCall, .toolResult])
        XCTAssertEqual(toolItems.map(\.toolInvocationID), [firstInvocationID, resultOnlyInvocationID])
    }

    func testMismatchedBashMirrorInvocationStillReconcilesRunningRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let startedInvocationID = UUID()
        let completedInvocationID = UUID()
        let argsJSON = #"{"command":"printf probe"}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "bash", invocationID: startedInvocationID, argsJSON: argsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: startedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"inProgress","processId":"probe-1","delta":"running"}"#,
                isError: false
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: completedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"completed","processId":"probe-1","aggregatedOutput":"done"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.count, 1)
        XCTAssertEqual(toolItems.first?.toolInvocationID, completedInvocationID)
    }

    func testReasoningSealsEarlierPendingAssistantBeforeMaterializing() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let assistantScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-reasoning"
        )
        let reasoningScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-after-assistant"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "assistant first", scope: assistantScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "draft reasoning",
                kind: .summary,
                itemID: reasoningScope.itemID,
                groupID: "summary:\(reasoningScope.itemID):0",
                index: 0,
                scope: reasoningScope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: reasoningScope,
                summary: ["final reasoning"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.kind),
            [.assistant, .thinking]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.text),
            ["assistant first", "final reasoning"]
        )
    }

    func testCanonicalReasoningCompletionMaterializesReplacesAndRemovesSegments() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-item"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Draft summary",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):0",
                index: 0,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "orphan body",
                kind: .text,
                itemID: scope.itemID,
                groupID: "text:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        XCTAssertEqual(session.items.count(where: { $0.kind == .thinking }), 2)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["Final summary"],
                content: ["Final body"]
            )),
            session: session
        )

        var thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(thinkingItems.map(\.text), ["Final summary\n\nFinal body"])
        XCTAssertEqual(thinkingItems.map(\.isStreaming), [false])
        XCTAssertEqual(Set(session.codexReasoningSegmentsByKey.keys), ["reasoning:reasoning-item:0"])

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: noDeltaScope,
                summary: ["First", "Second"],
                content: ["Body one", "Body two"]
            )),
            session: session
        )

        thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(
            thinkingItems.map(\.text),
            ["Final summary\n\nFinal body", "First\n\nBody one", "Second\n\nBody two"]
        )
        XCTAssertTrue(thinkingItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalReasoningCompletionInsertsMissingLowerIndexBeforeStreamedRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-partial"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Second draft",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["First", "Second"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking }.map(\.text),
            ["First", "Second"]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking || $0.kind == .toolCall }.map(\.kind),
            [.thinking, .thinking, .toolCall]
        )
    }

    func testCancellationClearsCanonicalAssistantAndReasoningReconciliationState() {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-item"
        )
        let rowID = UUID()
        session.pendingCodexAssistantScope = scope
        session.codexAssistantRowIDByScope[scope] = rowID
        session.activeReasoningItemID = rowID
        session.reasoningItemIDsByGroupID["reasoning-group"] = rowID
        session.codexReasoningSegmentsByKey["reasoning:reasoning-item:0"] = .init(
            summaryMarkdown: "draft",
            transcriptItemID: rowID
        )

        viewModel.test_codexCoordinator.drainCodexTerminalBuffersForCancellation(session)

        XCTAssertNil(session.pendingCodexAssistantScope)
        XCTAssertTrue(session.codexAssistantRowIDByScope.isEmpty)
        XCTAssertNil(session.activeReasoningItemID)
        XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty)
        XCTAssertTrue(session.codexReasoningSegmentsByKey.isEmpty)
    }

    func testTurnCompletionClearsEmptyScheduledAssistantFlushBeforeBarrier() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))

        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("answer", session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("", session: session)

        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
    }

    func testStaleStructuredScopeIsIgnored() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items
        let baselineLiveness = session.activeRunLiveness

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "old-turn",
                itemID: "old-item"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness, baselineLiveness)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testScopedErrorWithoutAuthoritativeIdentityFailsClosed() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        let baselineItems = session.items
        let baselineOwnership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "untrusted-routing-turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, baselineOwnership)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testWatchdogPauseRemainsRunningAndDoesNotAppendTranscriptFailure() async throws {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            session.codexWatchdogState.isPausedAfterWarning
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.items.count, baselineItems.count + 1)
        XCTAssertEqual(session.items.last?.kind, .assistant)
        XCTAssertEqual(session.items.last?.text, "progress")
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertEqual(session.runningStatusText, "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume.")
    }

    func testWatchdogFlushesCachedExplicitErrorWhenProbeFindsNoActiveTurn() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            pendingTurnFailure: .init(message: "explicit watchdog error")
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("progress"),
            session: session
        )

        try await waitUntil {
            session.runState == .failed
        }

        XCTAssertEqual(session.items.filter { $0.kind == .error }.map(\.text), [
            "explicit watchdog error"
        ])
        let remainingFailure = await controller.pendingTurnFailure(turnID: "turn")
        XCTAssertNil(remainingFailure)
        XCTAssertNotEqual(
            session.runningStatusText,
            "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume."
        )
    }

    func testPendingRequestUserInputSuppressesWatchdogAndPreservesQueue() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let pending = makeUserInputRequest(id: "pending")
        let queued = makeUserInputRequest(id: "queued")
        session.pendingUserInputRequest = pending
        session.queuedUserInputRequests = [queued]

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.readSnapshotCountSync(), 0)
        XCTAssertEqual(session.pendingUserInputRequest?.requestID, pending.requestID)
        XCTAssertEqual(session.queuedUserInputRequests.map(\.requestID), [queued.requestID])
    }

    func testInactiveCommandRunningOutputWithoutAnchorCreatesMinimalAnchorOnly() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        _ = await viewModel.ensureSessionReady(tabID: activeTabID)
        let session = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        session.selectedAgent = .codexExec
        session.runState = .running
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: "inactive-123",
                appendedOutput: "inactive first chunk\n"
            )),
            session: session
        )

        try await waitUntil {
            session.bashLiveExecutionByKey.values.first?.parsedResult.output?.contains("inactive first chunk") == true
        }
        let bashItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
        XCTAssertFalse(bashItem.toolResultJSON?.contains("inactive first chunk") == true)
        XCTAssertFalse(bashItem.text.contains("inactive first chunk"))
    }

    func testStaleCompletionBeforeObservedStartPreservesPendingTurnThenMatchingTurnFinalizes() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "stale-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "current-turn"),
            session: session
        )

        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "current-turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "current-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedNonNilCompletionAfterStartPreservesCurrentCorrelation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "different-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedStartCannotReplaceAuthoritativeIdentityAndDuplicateIsIdempotent() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let originalIdentity = session.codexAuthoritativeActiveTurn

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "different-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)
        XCTAssertEqual(session.runState, .running)
    }

    func testNilCompletionAfterIdentifiedStartCompletesCurrentTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        // Accounting (review R2, OracleA P1#2): the identified turn is dispatched and bound, and the
        // nil-ID completion that legitimately terminates it must close the known accounting turn.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn"), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "the correlated identified turn ended without usage: unmeasured now, not at some later teardown")
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.turnID, "turn")
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        // A provably owned late report for that turn still replaces its marker.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(codexUsageEvent(1, turn: "turn", codexTotal(1000, 100, 10)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 1)
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
    }

    func testNilStartFollowedByNilCompletionCompletesAnonymousTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user
        // Accounting (review R2): the dispatch behind an anonymous start can never be bound; its
        // nil-ID completion marks it unmeasured once, without a second "never bound" marker later.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexAnonymousActiveTurn?.turnKind, .user)
        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "dispatched work ended without any establishable identity")
        XCTAssertNil(session.usageAccounting?.record?.codexIntervals?.last?.turnID)
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.last?.diagnostic, AgentUsageAccumulator.codexUnmeasuredAnonymousTurnDiagnostic)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "the anonymous dispatch was consumed by its marker")
    }

    func testNilCompletionWithoutObservedStartIsRejectedAndPreservesPendingTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user
        // Accounting (review R2): a completion the correlation rejects is not this session's turn,
        // so the still-pending dispatch keeps its pricing basis for the start that follows.
        enableCodexUsageAccounting(session)
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0, "a rejected completion leaves accounting untouched")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "late-turn"), session: session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(codexUsageEvent(1, turn: "late-turn", codexTotal(1000, 100, 10)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 1)
        XCTAssertEqual(session.usageAccounting?.record?.codexIntervals?.first?.turnID, "late-turn")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.lower, Decimal(string: "0.0017325"), "the pending basis survived the rejected completion and priced the bound turn")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
    }

    /// Review R3 (OracleA P1): dispatch registration precedes the provider send, but only the
    /// controller's typed local preflight error proves the request never reached the transport.
    /// That exact ticket is withdrawn without manufacturing an unmeasured marker.
    func testFailedCodexTurnStartWithdrawsItsUsageDispatchWithoutAnUnmeasuredMarker() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexTurnStartPreflightError.invalidInput("test fixture rejected before transport submission")
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0, "a proven pre-send failure is not unmeasured work")

        // The next dispatch on the same generation finds nothing pending to mark as "never bound",
        // and is itself tracked normally (bound, awaited, marked when it ends without usage).
        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 0)
        let coordinator = viewModel.test_codexCoordinator
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-2"), session: session)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "turn-2", status: .interrupted), session: session)
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.map(\.turnID), ["turn-2"])
        XCTAssertNil(accounting.record?.semanticViolation)
    }

    /// Review R3 (OracleA P1): an anonymous `turn/started` is acceptance evidence even though it
    /// cannot bind the dispatch to a turn identity. A later JSON-RPC request error must not erase
    /// the pending usage obligation; execution teardown records it as unmeasured.
    func testAnonymousStartBeforeRequestErrorPreservesUsageObligation() async throws {
        let rejection = CodexAppServerClient.RequestFailure(
            method: "turn/start",
            code: -32000,
            message: "server error after anonymous turn/start",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexAppServerClient.ClientError.requestFailed(rejection)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)
        controller.setStartUserTurnBeforeResult {
            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
                .turnStarted(turnID: nil),
                session: session
            )
        }
        defer { controller.setStartUserTurnBeforeResult(nil) }

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        session.endCodexUsageExecution(reason: "test-anonymous-start-before-error")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    /// Review R3 (OracleA P1): cancellation can race after the request write, so a missing receipt
    /// is delivery-unknown rather than proof of rejection. Terminal teardown must retain the
    /// potentially incurred work as one unmeasured obligation.
    func testCancelledTurnStartWithoutReceiptPreservesUsageObligation() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CancellationError()
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .cancelled)
        session.endCodexUsageExecution(reason: "test-cancelled-start")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    /// Review R3 (OracleA P1): the app-server client synthesizes `requestFailed` for a local
    /// timeout, so method=turn/start without a receipt remains delivery-unknown. Execution teardown
    /// must retain one unmeasured obligation rather than treating the error as server rejection.
    func testTimedOutTurnStartWithoutReceiptPreservesUsageObligation() async throws {
        let timeout = CodexAppServerClient.RequestFailure(
            method: "turn/start",
            code: nil,
            message: "Request timed out after 1.0s",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startError: CodexAppServerClient.ClientError.requestFailed(timeout)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        enableCodexUsageAccounting(session)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .failed = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        session.endCodexUsageExecution(reason: "test-timed-out-start")
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(accounting.record?.codexIntervals?.count, 1)
        XCTAssertNil(accounting.record?.codexIntervals?.first?.turnID)
        XCTAssertEqual(
            accounting.record?.codexIntervals?.first?.diagnostic,
            AgentUsageAccumulator.codexUnmeasuredDispatchDiagnostic
        )
    }

    func testActiveCodexNativeSendUsesRealAgentRunDrainBeforeSending() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let waitTask = harness.startWait()
            try await harness.waitUntilBlocked()

            let ordering = CodexDrainSendOrderingRecorder()
            let controller = LivenessFakeCodexController(
                snapshot: .active(activeFlags: []),
                onSendUserTurn: { ordering.recordSend() }
            )
            let viewModel = makeViewModel(controller: controller) { runID, source in
                XCTAssertEqual(runID, harness.parentRunID)
                XCTAssertEqual(source, "codex-native-active-send")
                let drained = await harness.drain(source: source)
                ordering.recordDrainCompletion(
                    succeeded: drained,
                    activeScopeCount: harness.activeScopeCount()
                )
                return drained
            }
            let session = preparedCodexSession(
                in: viewModel,
                controller: controller,
                runID: harness.parentRunID
            )
            session.codexRoutingObservedTurnID = "routing-hint-only"

            let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
            let interruptedValue = try await waitTask.value
            let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
            let completions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            let orderingSnapshot = ordering.snapshot()

            XCTAssertEqual(outcome, .sent)
            XCTAssertEqual(
                interruptedObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertEqual(controller.startUserTurnCountSync(), 0)
            XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
            XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
            XCTAssertTrue(orderingSnapshot.drainSucceeded)
            XCTAssertEqual(orderingSnapshot.activeScopeCountAtDrainCompletion, 0)
            XCTAssertTrue(orderingSnapshot.sendObservedAfterDrain)
            XCTAssertEqual(harness.activeScopeCount(), 0)
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(completions.first?.result, "interrupted_by_steering")
            XCTAssertTrue(registrationRemainsActive)
        }
    }

    func testActiveCodexNativeSendFailsWithoutSendingWhenAgentRunDrainFails() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _ in false }
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertTrue(message.contains("agent_run.wait"))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
    }

    func testInactiveCodexNativeSendStartsTurnWithoutInstallingLifecycleIdentity() async {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
    }

    func testActiveCodexNativeSendWithoutExactIdentityQueuesWithoutStarting() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = "routing-only-turn"

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .queuedFallback(_, .activeWithoutAuthoritativeIdentity) = outcome else {
            return XCTFail("Expected missing-identity fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    func testTypedSteerRejectionReturnsFallbackWithoutReplacingAuthoritativeIdentity() async {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let identity = session.codexAuthoritativeActiveTurn

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .queuedFallback(_, .noActiveTurn(failure: failure)) = outcome else {
            return XCTFail("Expected no-active fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
        XCTAssertEqual(session.codexAuthoritativeActiveTurn, identity)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    func testManualTypedFallbackKeepsOptimisticBubbleAndDraft() async throws {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        viewModel.storeDraftText(for: session.tabID, "restore me")

        let result = viewModel.submitUserTurn(text: "restore me", tabID: session.tabID)

        XCTAssertEqual(result, .submitted)
        try await waitUntil {
            controller.steerUserTurnIDsSync() == ["turn"]
                && session.codexFallbackQueue.count == 1
        }
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["restore me"])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "restore me")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
    }

    func testAcceptedSteerRemainsSentWhenMatchingTurnCompletesBeforeReceiptResumes() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerDelayNanos: 50_000_000
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }
        try await waitUntil {
            controller.steerUserTurnIDsSync() == ["turn"]
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(session.runState, .completed)
    }

    // MARK: - Usage accounting lifecycle (plan §4.1)

    /// Coordinator lifecycle: a dispatched turn that ends (interrupted) without any usage
    /// notification is unmeasured work, a provably owned late notification still lands, and
    /// session shutdown marks a still-open dispatched turn before the controller generation rotates.
    func testDispatchedCodexTurnEndingWithoutUsageIsUnmeasuredAcrossInterruptLateUsageAndShutdown() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: UUID()))
        session.codexPricingProvider = OpenAIPricingStore.transient(
            transport: NoNetworkPricingTransport(),
            isNetworkPermitted: { false }
        )
        // The fixture pre-assigns the thread identity the fake controller reports. For accounting
        // this generation must be the one that created the thread (verified zero baseline); a
        // thread that already existed would be resumed and its first checkpoint only prospective.
        let preparedThreadID = session.codexConversationID
        session.codexConversationID = nil
        session.beginCodexUsageExecutionIfNeeded()
        session.codexConversationID = preparedThreadID
        let coordinator = viewModel.test_codexCoordinator
        func total(_ input: Int, _ cached: Int, _ output: Int) -> CodexUsageObservation.Counters {
            .init(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0, totalTokens: input + output)
        }
        func usage(_ ordinal: Int, turn: String, _ counters: CodexUsageObservation.Counters) -> CodexNativeSessionController.Event {
            .usageObservation(.init(threadID: "fake", turnID: turn, turnAttribution: .notified, ordinal: ordinal, last: counters, total: counters, modelContextWindow: 258_400))
        }

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn"), session: session)
        await coordinator.test_handleCodexNativeEvent(usage(1, turn: "turn", total(1000, 100, 10)), session: session)
        let accounting = try XCTUnwrap(session.usageAccounting)
        XCTAssertEqual(accounting.codexSessionCostEstimate?.coverage, .complete)
        XCTAssertEqual(accounting.codexUnmeasuredWorkCount, 0)

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-2"), session: session)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "turn-2", status: .interrupted), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1)
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .partial)
        // Bundled seed rates for gpt-5.3-codex ($1.75 / $0.175 / $14.00 per million):
        // 900 ordinary × 1.75 + 100 cached × 0.175 + 10 output × 14 = 1732.5 → $0.0017325.
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.lower, Decimal(string: "0.0017325"), "accepted amounts are retained")

        await coordinator.test_handleCodexNativeEvent(usage(2, turn: "turn-2", total(2000, 200, 20)), session: session)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 0, "a provably owned late observation replaces the marker")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .complete)
        XCTAssertEqual(session.usageAccounting?.codexIntervalCount, 2)

        session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex")
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "turn-3"), session: session)
        let generationBeforeShutdown = session.codexControllerGeneration
        await coordinator.shutdownCodexSession(session)
        XCTAssertNotEqual(session.codexControllerGeneration, generationBeforeShutdown)
        XCTAssertEqual(session.usageAccounting?.codexUnmeasuredWorkCount, 1, "shutdown marks the still-open dispatched turn before the generation rotates")
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate?.coverage, .partial)
        XCTAssertNil(session.usageAccounting?.record?.semanticViolation)
        let projection = AgentRuntimeSidebarViewModel.ProviderUsageSnapshot.projected(
            selectedAgent: .codexExec,
            accounting: session.usageAccounting,
            expectedOwnerSessionID: session.activeAgentSessionID
        )
        XCTAssertTrue(projection.presentation.readoutText.hasSuffix(" partial"))
        XCTAssertTrue(
            try XCTUnwrap(projection.coverageDetail)
                .contains(AgentUsageAccumulator.codexUnmeasuredTurnDiagnostic)
        )
    }

    /// Enables fixture-local Codex usage accounting without mutating the prepared run's persistent
    /// binding, with offline pricing and a fresh-thread origin for the generation the fixture
    /// pre-assigned its thread to (an existing thread would start prospectively).
    private func enableCodexUsageAccounting(_ session: AgentModeViewModel.TabSession) {
        // Install accounting directly so this focused fixture does not mutate the persistent binding
        // after `beginRunAttempt`; doing so would intentionally stale the run ownership under test.
        session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: UUID(),
            persisted: nil,
            hasPriorHistory: false,
            qualification: .productionClaude
        )
        session.codexPricingProvider = OpenAIPricingStore.transient(
            transport: NoNetworkPricingTransport(),
            isNetworkPermitted: { false }
        )
        let preparedThreadID = session.codexConversationID
        session.codexConversationID = nil
        session.beginCodexUsageExecutionIfNeeded()
        session.codexConversationID = preparedThreadID
    }

    private func codexTotal(_ input: Int, _ cached: Int, _ output: Int) -> CodexUsageObservation.Counters {
        .init(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0, totalTokens: input + output)
    }

    private func codexUsageEvent(_ ordinal: Int, turn: String, _ counters: CodexUsageObservation.Counters) -> CodexNativeSessionController.Event {
        .usageObservation(.init(threadID: "fake", turnID: turn, turnAttribution: .notified, ordinal: ordinal, last: counters, total: counters, modelContextWindow: 258_400))
    }

    private func makeViewModel(
        controller: LivenessFakeCodexController,
        drain: AgentModeViewModel.CodexAgentRunWaitDrain? = nil
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexActiveAgentRunWaitDrain: drain,
            testCodexStallWatchdogPollIntervalNanos: 10_000_000,
            testCodexStallWatchdogProbeThreshold: 0.02,
            testCodexStallWatchdogRecoveryThreshold: 0.02
        )
        viewModel.test_initializeRunService()
        return viewModel
    }

    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: LivenessFakeCodexController,
        runID: UUID = UUID()
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexLiveness")
        session.codexController = controller
        session.codexConversationID = "fake"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        return session
    }

    private func makeUserInputRequest(id: String) -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string(id),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            questions: [
                AgentRequestUserInputQuestion(
                    id: "question",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: [AgentRequestUserInputOption(label: "Yes", description: "Continue")]
                )
            ]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class CodexDrainSendOrderingRecorder: @unchecked Sendable {
    struct Snapshot {
        let drainSucceeded: Bool
        let activeScopeCountAtDrainCompletion: Int?
        let sendObservedAfterDrain: Bool
    }

    private let lock = NSLock()
    private var drainSucceeded = false
    private var activeScopeCountAtDrainCompletion: Int?
    private var sendObservedAfterDrain = false

    func recordDrainCompletion(succeeded: Bool, activeScopeCount: Int) {
        lock.lock()
        drainSucceeded = succeeded
        activeScopeCountAtDrainCompletion = activeScopeCount
        lock.unlock()
    }

    func recordSend() {
        lock.lock()
        sendObservedAfterDrain = drainSucceeded && activeScopeCountAtDrainCompletion == 0
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            drainSucceeded: drainSucceeded,
            activeScopeCountAtDrainCompletion: activeScopeCountAtDrainCompletion,
            sendObservedAfterDrain: sendObservedAfterDrain
        )
        lock.unlock()
        return snapshot
    }
}

/// Pricing transport that must never be reached: the lifecycle test disables network use.
private struct NoNetworkPricingTransport: OpenAIPricingDocumentTransport {
    func fetch(_ request: URLRequest, maximumBodyBytes: Int) async throws -> OpenAIPricingTransportResponse {
        throw OpenAIPricingTransportError.networkNotPermitted
    }
}

private final class LivenessFakeCodexController: CodexSessionControlling {
    private var readSnapshotCount = 0
    private var startUserTurnCount = 0
    private var steerUserTurnIDs: [String] = []
    private let snapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]
    private let onSendUserTurn: (() -> Void)?
    private let startError: Error?
    private var startUserTurnBeforeResult: (() async -> Void)?
    private let steerError: Error?
    private let steerDelayNanos: UInt64
    private var pendingTurnFailure: CodexNativeSessionController.TurnFailure?

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"],
        onSendUserTurn: (() -> Void)? = nil,
        startError: Error? = nil,
        steerError: Error? = nil,
        steerDelayNanos: UInt64 = 0,
        pendingTurnFailure: CodexNativeSessionController.TurnFailure? = nil
    ) {
        snapshotStatus = snapshot
        snapshotActiveTurnIDs = activeTurnIDs
        self.onSendUserTurn = onSendUserTurn
        self.startError = startError
        self.steerError = steerError
        self.steerDelayNanos = steerDelayNanos
        self.pendingTurnFailure = pendingTurnFailure
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func readSnapshotCountSync() -> Int {
        readSnapshotCount
    }

    func startUserTurnCountSync() -> Int {
        startUserTurnCount
    }

    func setStartUserTurnBeforeResult(_ operation: (() async -> Void)?) {
        startUserTurnBeforeResult = operation
    }

    func steerUserTurnIDsSync() -> [String] {
        steerUserTurnIDs
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        readSnapshotCount += 1
        return CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshotStatus,
            currentTurnID: snapshotActiveTurnIDs.first,
            activeTurnIDs: snapshotActiveTurnIDs,
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {
        recordSendUserTurn()
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        recordSendUserTurn()
        startUserTurnCount += 1
        if let startUserTurnBeforeResult {
            await startUserTurnBeforeResult()
        }
        if let startError {
            throw startError
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "liveness-submission-\(startUserTurnCount)")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        recordSendUserTurn()
        steerUserTurnIDs.append(expectedTurnID)
        if let steerError {
            throw steerError
        }
        if steerDelayNanos > 0 {
            try await Task.sleep(nanoseconds: steerDelayNanos)
        }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    private func recordSendUserTurn() {
        onSendUserTurn?()
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func pendingTurnFailure(
        turnID _: String?
    ) async -> CodexNativeSessionController.TurnFailure? {
        pendingTurnFailure
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure: CodexNativeSessionController.TurnFailure
    ) async {
        if pendingTurnFailure == failure {
            pendingTurnFailure = nil
        }
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
