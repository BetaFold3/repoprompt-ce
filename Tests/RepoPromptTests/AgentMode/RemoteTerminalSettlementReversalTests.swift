@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemoteTerminalSettlementReversalTests: XCTestCase {
    @MainActor
    func testSettleAndRevertSyntheticTerminalSettlement() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-settle-revert")
        session.runState = .running
        session.appendItem(.toolCall(name: "context_builder", argsJSON: nil))

        coordinator.test_applyTerminal(status: "completed", to: session)

        var item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertNotNil(item.toolResultJSON)
        XCTAssertTrue(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))
        XCTAssertEqual(item.toolIsError, false)

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.runState, .running)
        XCTAssertNil(item.toolResultJSON)
        XCTAssertNil(item.toolIsError)
    }

    @MainActor
    func testIncidentTerminalRunningCyclesOnlyCarrySyntheticMarkersWhileTerminal() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-cycle")
        session.runState = .running
        session.appendItem(.toolCall(name: "context_builder", argsJSON: nil))

        for _ in 0 ..< 2 {
            coordinator.test_applyTerminal(status: "completed", to: session)
            var item = try XCTUnwrap(session.items.first)
            XCTAssertEqual(session.runState, .completed)
            XCTAssertTrue(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))

            coordinator.test_applyRunState(.running, statusText: nil, to: session)
            item = try XCTUnwrap(session.items.first)
            XCTAssertEqual(session.runState, .running)
            XCTAssertNil(item.toolResultJSON)
            XCTAssertNil(item.toolIsError)
            XCTAssertFalse(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))
        }

        coordinator.test_applyTerminal(status: "completed", to: session)
        let finalItem = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertTrue(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(finalItem.toolResultJSON))
    }

    @MainActor
    func testTerminalToActiveRevertsSyntheticSettlementWithoutCoordinatorMemory() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-reattach")
        session.runState = .completed
        session.appendItem(AgentChatItem(
            kind: .toolCall,
            text: "Using tool: context_builder",
            toolName: "context_builder",
            toolResultJSON: AgentToolResultPersistencePolicy.syntheticSettlementResultJSON(
                statusWord: "completed",
                normalizedToolName: "context_builder"
            ),
            toolIsError: false
        ))

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        let item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.runState, .running)
        XCTAssertNil(item.toolResultJSON)
        XCTAssertNil(item.toolIsError)
    }

    @MainActor
    func testRunningToRunningWithoutSyntheticTrackingDoesNotScanOrClearRealResult() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-running-running")
        let realJSON = AgentToolResultPersistencePolicy.minimalResultJSON(
            statusWord: "success",
            normalizedToolName: "context_builder"
        )
        session.runState = .running
        session.appendItem(AgentChatItem(
            kind: .toolCall,
            text: "Using tool: context_builder",
            toolName: "context_builder",
            toolResultJSON: realJSON,
            toolIsError: false
        ))
        var scanCount = 0
        coordinator.test_setSyntheticSettlementRevertScanObserver { _ in
            scanCount += 1
        }

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        let item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(scanCount, 0)
        XCTAssertEqual(item.toolResultJSON, realJSON)
        XCTAssertEqual(item.toolIsError, false)
    }

    @MainActor
    func testRealResultsAreUntouchedByTerminalAndActiveRevert() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-real-result")
        let realJSON = AgentToolResultPersistencePolicy.minimalResultJSON(
            statusWord: "success",
            normalizedToolName: "context_builder"
        )
        session.runState = .running
        session.appendItem(AgentChatItem(
            kind: .toolCall,
            text: "Using tool: context_builder",
            toolName: "context_builder",
            toolResultJSON: realJSON,
            toolIsError: false
        ))

        coordinator.test_applyTerminal(status: "completed", to: session)
        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        let item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(item.toolResultJSON, realJSON)
        XCTAssertFalse(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))
        XCTAssertEqual(item.toolIsError, false)
    }

    @MainActor
    func testTerminalTranscriptRowsResettlePathMarksSyntheticAndRunningReverts() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-resettle")
        let tool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-resettle").first)

        coordinator.test_applyTerminal(status: "completed", to: session)
        coordinator.test_applyTranscriptRows([tool], to: session)

        var item = try XCTUnwrap(session.items.first)
        XCTAssertTrue(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))
        XCTAssertEqual(item.toolIsError, false)

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        item = try XCTUnwrap(session.items.first)
        XCTAssertNil(item.toolResultJSON)
        XCTAssertNil(item.toolIsError)
    }

    @MainActor
    func testHostResultOverwritesSyntheticAndActiveRevertDoesNotClearRealResult() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-overwrite")
        let tool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-overwrite").first)
        let realJSON = AgentToolResultPersistencePolicy.minimalResultJSON(
            statusWord: "success",
            normalizedToolName: "context_builder"
        )
        var hostResult = tool
        hostResult.toolResultJSON = realJSON
        hostResult.toolIsError = false

        coordinator.test_applyTranscriptRows([tool], to: session)
        coordinator.test_applyTerminal(status: "completed", to: session)
        XCTAssertTrue(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(session.items.first?.toolResultJSON))

        coordinator.test_applyTranscriptRows([hostResult], to: session)
        var item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(item.id, tool.id)
        XCTAssertEqual(item.toolResultJSON, realJSON)
        XCTAssertFalse(AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(item.toolResultJSON))

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        item = try XCTUnwrap(session.items.first)
        XCTAssertEqual(item.toolResultJSON, realJSON)
        XCTAssertEqual(item.toolIsError, false)
    }

    @MainActor
    func testConsecutiveTerminalDiscoveryDebouncesUntilRunningRearmsImmediacy() async {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in NoopCodexController() }
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.remoteHost = makeBinding(remoteSessionID: "remote-discovery")
        let coordinator = RemoteAgentModeCoordinator()
        coordinator.attach(viewModel: viewModel)
        var immediates: [Bool] = []
        coordinator.test_setChildDiscoveryRequestObserver { observedTabID, immediate in
            guard observedTabID == tabID else { return }
            immediates.append(immediate)
        }

        coordinator.test_handleEvent(.terminal(status: "completed"), tabID: tabID)
        coordinator.test_handleEvent(.terminal(status: "completed"), tabID: tabID)
        coordinator.test_handleEvent(.runState(.running, pendingInteraction: nil, statusText: nil), tabID: tabID)
        coordinator.test_handleEvent(.terminal(status: "completed"), tabID: tabID)

        XCTAssertEqual(immediates, [true, false, true])
    }

    @MainActor
    private func makeSession(remoteSessionID: String) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.remoteHost = makeBinding(remoteSessionID: remoteSessionID)
        return session
    }

    private func project(xml: String, sessionID: String) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: sessionID)
            .projectGetLogResponse(logPayload(offset: 0, returned: 1, total: 1, xml: xml, completed: 1))
            .items
    }

    private func logPayload(offset: Int, returned: Int, total: Int, xml: String, completed: Int? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turn_offset": .int(offset),
            "turn_limit": .int(20),
            "returned_turn_count": .int(returned),
            "total_turns": .int(total),
            "transcript_xml": .string(xml)
        ]
        if let completed { payload["completed_turn_count"] = .int(completed) }
        return .object(payload)
    }

    private func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: 0,
            nextLogOffset: 0
        )
    }
}

private final class NoopCodexController: CodexSessionControlling {
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

    func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil, runtimeStatus: .idle, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: nil)
    }

    func startUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(text _: String, images _: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
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
