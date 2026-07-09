@testable import RepoPrompt
import XCTest

final class RemoteAgentModeCoordinatorRespondRecoveryTests: XCTestCase {
    @MainActor
    func testRespondFailureRestoresPendingAskUserWithDrafts() async throws {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "old-question", currentQuestionIndex: 1)
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(
            interactionID: "old-question",
            priorRunState: .waitingForQuestion,
            pendingAskUser: pending
        )

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        let restored = try XCTUnwrap(fixture.session.pendingAskUser)
        XCTAssertEqual(restored.interaction.remoteInteractionID, "old-question")
        XCTAssertEqual(restored.currentQuestionIndex, 1)
        XCTAssertEqual(restored.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        XCTAssertEqual(restored.draftsByQuestionID["second"]?.customResponse, "draft text")
        XCTAssertEqual(fixture.session.runState, .waitingForQuestion)
        XCTAssertNil(fixture.session.runningStatusText)
    }

    @MainActor
    func testRespondFailureSkipsRestoreWhenNewInteractionArrived() async {
        let fixture = await makeFixture()
        let oldPending = makePendingAskUser(remoteInteractionID: "old-question")
        let newPending = makePendingAskUser(remoteInteractionID: "new-question")
        fixture.session.pendingAskUser = newPending
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(
            interactionID: "old-question",
            priorRunState: .waitingForQuestion,
            pendingAskUser: oldPending
        )

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        XCTAssertEqual(fixture.session.pendingAskUser?.interaction.remoteInteractionID, "new-question")
        XCTAssertEqual(fixture.session.runState, .waitingForQuestion)
        XCTAssertNil(fixture.session.runningStatusText)
    }

    @MainActor
    func testRespondFailureSkipsRestoreAfterTerminalState() async {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "old-question")
        fixture.session.runState = .completed
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(
            interactionID: "old-question",
            priorRunState: .waitingForQuestion,
            pendingAskUser: pending
        )

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        XCTAssertNil(fixture.session.pendingAskUser)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertNil(fixture.session.runningStatusText)
    }

    @MainActor
    func testRespondFailureClearsSendingTransportStatus() async {
        let fixture = await makeFixture()
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(interactionID: "status-only", priorRunState: .running)

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        XCTAssertNil(fixture.session.runningStatusText)
        XCTAssertEqual(fixture.session.runState, .running)
    }

    @MainActor
    func testRespondFailureRestoresPendingApproval() async {
        let fixture = await makeFixture()
        let approval = makeApprovalRequest(interactionID: "approval-1")
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(
            interactionID: "approval-1",
            priorRunState: .waitingForApproval,
            pendingApproval: approval
        )

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        XCTAssertEqual(fixture.session.pendingApproval, approval)
        XCTAssertEqual(fixture.session.runState, .waitingForApproval)
        XCTAssertNil(fixture.session.runningStatusText)
    }

    @MainActor
    func testRedundantInteractionResolvedPreservesHostRunningStatus() async {
        let fixture = await makeFixture()
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Thinking…", source: .transport)

        fixture.coordinator.clearResolvedInteraction(
            tabID: fixture.tabID,
            interactionID: "whatever",
            resolvedBy: nil
        )

        XCTAssertEqual(fixture.session.runningStatusText, "Thinking…")
        XCTAssertEqual(fixture.session.runningStatusSource, .transport)
    }

    @MainActor
    func testInteractionResolvedClearsSendingResponsePlaceholder() async {
        let fixture = await makeFixture()
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)

        fixture.coordinator.clearResolvedInteraction(
            tabID: fixture.tabID,
            interactionID: "whatever",
            resolvedBy: nil
        )

        XCTAssertNil(fixture.session.runningStatusText)
        XCTAssertNil(fixture.session.runningStatusSource)
    }

    @MainActor
    func testRespondFailureRestoresPendingUserInputAndElicitation() async {
        let fixture = await makeFixture()
        let userInput = makeUserInputRequest(interactionID: "user-input-1")
        let elicitation = makeMCPElicitationRequest(interactionID: "elicitation-1")
        fixture.session.runState = .running
        fixture.session.setRunningStatus("Sending response to remote host…", source: .transport)
        let restorable = makeRestorable(
            interactionID: "user-input-1",
            priorRunState: .waitingForApproval,
            pendingUserInputRequest: userInput,
            pendingMCPElicitationRequest: elicitation
        )

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: restorable,
            controller: nil
        )

        XCTAssertEqual(fixture.session.pendingUserInputRequest, userInput)
        XCTAssertEqual(fixture.session.pendingMCPElicitationRequest, elicitation)
        XCTAssertEqual(fixture.session.runState, .waitingForApproval)
        XCTAssertNil(fixture.session.runningStatusText)
    }

    @MainActor
    private func makeFixture() async -> RecoveryFixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RecoveryNoopCodexController() }
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let coordinator = RemoteAgentModeCoordinator()
        coordinator.attach(viewModel: viewModel)
        return RecoveryFixture(tabID: tabID, viewModel: viewModel, session: session, coordinator: coordinator)
    }

    private func makePendingAskUser(
        remoteInteractionID: String,
        currentQuestionIndex: Int = 0
    ) -> AgentAskUserPendingState {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            remoteInteractionID: remoteInteractionID,
            questions: [
                AgentAskUserQuestion(
                    id: "first",
                    question: "Choose one",
                    options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
                    allowsCustom: false
                ),
                AgentAskUserQuestion(id: "second", question: "Explain", allowsCustom: true)
            ]
        )
        var drafts = interaction.emptyDrafts()
        drafts["first"] = AgentAskUserDraft(selectedOptionLabels: ["A"])
        drafts["second"] = AgentAskUserDraft(customResponse: "draft text")
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: drafts,
            currentQuestionIndex: currentQuestionIndex
        )
    }

    private func makeApprovalRequest(interactionID: String) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .remoteGateway(interactionID: interactionID),
            method: "remote_gateway.approval",
            kind: .commandExecution,
            threadID: "remote-session",
            turnID: interactionID,
            itemID: interactionID,
            reason: "Run command?",
            command: "echo ok"
        )
    }

    private func makeUserInputRequest(interactionID: String) -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            remoteInteractionID: interactionID,
            requestID: .string("remote:\(interactionID)"),
            method: "remote_gateway.user_input",
            threadID: "remote-session",
            turnID: interactionID,
            itemID: interactionID,
            questions: [
                AgentRequestUserInputQuestion(
                    id: "path",
                    header: "Path",
                    question: "Enter a path",
                    isOther: true,
                    isSecret: false,
                    options: []
                )
            ]
        )
    }

    private func makeMCPElicitationRequest(interactionID: String) -> AgentMCPElicitationRequest {
        AgentMCPElicitationRequest(
            remoteInteractionID: interactionID,
            requestID: .string("remote:\(interactionID)"),
            method: "remote_gateway.mcp_elicitation",
            threadID: "remote-session",
            turnID: interactionID,
            itemID: interactionID,
            title: "MCP Elicitation",
            prompt: "Provide value",
            rawParamsJSON: "{}"
        )
    }

    private func makeRestorable(
        interactionID: String,
        priorRunState: AgentSessionRunState,
        pendingApproval: AgentApprovalRequest? = nil,
        pendingAskUser: AgentAskUserPendingState? = nil,
        pendingUserInputRequest: AgentRequestUserInputRequest? = nil,
        pendingMCPElicitationRequest: AgentMCPElicitationRequest? = nil
    ) -> RemoteAgentModeCoordinator.RestorableInteractionState {
        RemoteAgentModeCoordinator.RestorableInteractionState(
            interactionID: interactionID,
            priorRunState: priorRunState,
            pendingApproval: pendingApproval,
            pendingAskUser: pendingAskUser,
            pendingUserInputRequest: pendingUserInputRequest,
            pendingMCPElicitationRequest: pendingMCPElicitationRequest
        )
    }

    private struct RecoveryFixture {
        let tabID: UUID
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let coordinator: RemoteAgentModeCoordinator
    }
}

private final class RecoveryNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
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

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
