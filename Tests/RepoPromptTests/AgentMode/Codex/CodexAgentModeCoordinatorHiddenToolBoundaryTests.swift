import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorHiddenToolBoundaryTests: XCTestCase {
    func testHiddenSetStatusBetweenCompletedAssistantItemsStillProducesTwoAssistantRows() async {
        let controller = HiddenToolBoundaryFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let firstScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-a"
        )
        let secondScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-b"
        )
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "A", scope: firstScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: firstScope, text: "A")),
            session: session
        )
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolCall(
            invocationID: invocationID,
            toolName: "set_status",
            session: session
        )
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolResult(
            invocationID: invocationID,
            toolName: "set_status",
            resultJSON: #"{"ok":true}"#,
            isError: false,
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "B", scope: secondScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        await viewModel.test_codexCoordinator.test_forcePendingCodexTerminalSettleTimeout(session: session)

        XCTAssertEqual(assistantTexts(in: session), ["A", "B"])
        XCTAssertFalse(session.items.contains { $0.toolName == "set_status" })
    }

    func testHiddenSetStatusMidStreamFlushesBufferedDeltaWithoutCreatingNewAssistantSegment() async {
        let controller = HiddenToolBoundaryFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("A"), session: session)
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolCall(
            invocationID: invocationID,
            toolName: "set_status",
            session: session
        )
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolResult(
            invocationID: invocationID,
            toolName: "set_status",
            resultJSON: #"{"ok":true}"#,
            isError: false,
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("B"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        XCTAssertEqual(assistantTexts(in: session), ["AB"])
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.isStreaming), [true])
        XCTAssertFalse(session.items.contains { $0.toolName == "set_status" })
    }

    func testVisibleTrackerToolStillSealsAssistantBoundaryAroundToolRow() async {
        let controller = HiddenToolBoundaryFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("A"), session: session)
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolCall(
            invocationID: invocationID,
            toolName: "apply_edits",
            session: session
        )
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolResult(
            invocationID: invocationID,
            toolName: "apply_edits",
            resultJSON: #"{"ok":true}"#,
            isError: false,
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("B"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        XCTAssertEqual(assistantTexts(in: session), ["A", "B"])
        XCTAssertEqual(
            session.items.map(\.kind),
            [.assistant, .toolResult, .assistant]
        )
        XCTAssertEqual(session.items[1].toolName, "apply_edits")
    }

    func testHiddenWaitForNextUserInstructionFlushesBufferedDeltaWhenSessionParks() async {
        let controller = HiddenToolBoundaryFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("A"), session: session)
        viewModel.test_codexCoordinator.test_handleCodexTrackerToolCall(
            invocationID: invocationID,
            toolName: "wait_for_next_user_instruction",
            session: session
        )

        XCTAssertEqual(assistantTexts(in: session), ["A"])
        XCTAssertEqual(session.pendingAssistantDelta, "")
        XCTAssertFalse(session.items.contains { $0.toolName == "wait_for_next_user_instruction" })

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("B"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        XCTAssertEqual(assistantTexts(in: session), ["AB"])
    }

    private func makeViewModel(
        controller: HiddenToolBoundaryFakeCodexController
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexStallWatchdogPollIntervalNanos: 10_000_000,
            testCodexStallWatchdogProbeThreshold: 0.02,
            testCodexStallWatchdogRecoveryThreshold: 0.02
        )
        viewModel.test_initializeRunService()
        return viewModel
    }

    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: HiddenToolBoundaryFakeCodexController,
        runID: UUID = UUID()
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexHiddenToolBoundary")
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

    private func assistantTexts(in session: AgentModeViewModel.TabSession) -> [String] {
        session.items.filter { $0.kind == .assistant }.map(\.text)
    }
}

private final class HiddenToolBoundaryFakeCodexController: CodexSessionControlling {
    private let snapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"]
    ) {
        snapshotStatus = snapshot
        snapshotActiveTurnIDs = activeTurnIDs
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
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
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
    func sendUserTurn(
        text: String,
        images: [AgentImageAttachment],
        model: String?,
        reasoningEffort: String?
    ) async throws {}

    func sendUserTurn(
        text: String,
        images: [AgentImageAttachment],
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws {}

    func startUserTurn(
        text: String,
        images: [AgentImageAttachment],
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "hidden-tool-boundary")
    }

    func steerUserTurn(
        text: String,
        images: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _ status: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func pendingTurnFailure(
        turnID: String?
    ) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(
        turnID: String?,
        failure: CodexNativeSessionController.TurnFailure
    ) async {}

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
