@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentModeCoordinatorSubmitResponseWiringTests: XCTestCase {
    @MainActor
    func testRespondCommandErrorTriggersRecoveryAndRestoresCard() async throws {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(currentQuestionIndex: 1)
        fixture.session.pendingAskUser = pending
        fixture.session.runState = .waitingForQuestion
        let connection = StubRemoteConnection(script: [
            "respond": [.failure(StubCommandError())],
            "subscribe": [.failure(StubCommandError())]
        ])
        installController(connection: connection, fixture: fixture)

        fixture.coordinator.submitAskUserResponse(
            session: fixture.session,
            interactionID: "wire-question",
            response: makeResponse()
        )

        try await waitUntil { fixture.session.pendingAskUser != nil }
        let restored = try XCTUnwrap(fixture.session.pendingAskUser)
        XCTAssertEqual(restored.currentQuestionIndex, 1)
        XCTAssertEqual(restored.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        XCTAssertEqual(restored.draftsByQuestionID["second"]?.customResponse, "draft text")
        XCTAssertNil(fixture.session.runningStatusText)
        XCTAssertTrue(fixture.session.items.contains { item in
            item.kind == .system && item.text.hasPrefix("Remote response failed")
        })
    }

    @MainActor
    func testRespondCommandErrorWithSuccessfulResyncMergesStashedDrafts() async throws {
        let fixture = await makeFixture()
        fixture.session.pendingAskUser = makePendingAskUser(currentQuestionIndex: 1)
        fixture.session.runState = .waitingForQuestion
        let connection = StubRemoteConnection(script: [
            "respond": [.failure(StubCommandError())],
            "subscribe": [.success(.object([:]))],
            "poll": [.success(Self.questionSnapshot())],
            "get_log": [.success(Self.emptyLogPayload())]
        ])
        installController(connection: connection, fixture: fixture)

        fixture.coordinator.submitAskUserResponse(
            session: fixture.session,
            interactionID: "wire-question",
            response: makeResponse()
        )

        try await waitUntil { fixture.session.pendingAskUser?.interaction.remoteInteractionID == "wire-question" }
        let restored = try XCTUnwrap(fixture.session.pendingAskUser)
        XCTAssertEqual(restored.currentQuestionIndex, 1)
        XCTAssertEqual(restored.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        XCTAssertEqual(restored.draftsByQuestionID["second"]?.customResponse, "draft text")
    }

    @MainActor
    func testRespondSuccessDoesNotRestoreOrAppendFailureMessage() async throws {
        let fixture = await makeFixture()
        fixture.session.pendingAskUser = makePendingAskUser(currentQuestionIndex: 1)
        fixture.session.runState = .waitingForQuestion
        let connection = StubRemoteConnection(script: [
            "respond": [.success(Self.runningSnapshot())],
            "poll": [.success(Self.runningSnapshot())],
            "get_log": [.success(Self.emptyLogPayload())]
        ])
        installController(connection: connection, fixture: fixture)

        fixture.coordinator.submitAskUserResponse(
            session: fixture.session,
            interactionID: "wire-question",
            response: makeResponse()
        )

        try await waitUntil { fixture.session.pendingAskUser == nil && fixture.session.runState == .running }
        XCTAssertFalse(fixture.session.items.contains { item in
            item.kind == .system && item.text.hasPrefix("Remote response failed")
        })
    }

    @MainActor
    func testRespondAlreadyResolvedDoesNotRestoreCard() async throws {
        let fixture = await makeFixture()
        fixture.session.pendingAskUser = makePendingAskUser(currentQuestionIndex: 1)
        fixture.session.runState = .waitingForQuestion
        let alreadyResolved = RemoteClientError.interactionAlreadyResolved(.init(
            code: "interaction_already_resolved",
            message: "Already resolved"
        ))
        let connection = StubRemoteConnection(script: [
            "respond": [.failure(alreadyResolved)],
            "poll": [.success(Self.runningSnapshot())],
            "get_log": [.success(Self.emptyLogPayload())]
        ])
        installController(connection: connection, fixture: fixture)

        fixture.coordinator.submitAskUserResponse(
            session: fixture.session,
            interactionID: "wire-question",
            response: makeResponse()
        )

        try await waitUntil { fixture.session.pendingAskUser == nil }
        try await waitUntil { fixture.session.runningStatusText?.hasPrefix("Sending response to ") != true }
        XCTAssertFalse(fixture.session.items.contains { item in
            item.kind == .system && item.text.hasPrefix("Remote response failed")
        })
    }

    @MainActor
    private func makeFixture() async -> SubmitResponseFixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in SubmitResponseNoopCodexController() }
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.remoteHost = makeBinding()
        let coordinator = RemoteAgentModeCoordinator()
        coordinator.attach(viewModel: viewModel)
        return SubmitResponseFixture(tabID: tabID, viewModel: viewModel, session: session, coordinator: coordinator)
    }

    @MainActor
    private func installController(connection: StubRemoteConnection, fixture: SubmitResponseFixture) {
        let controller = RemoteAgentSessionController(binding: makeBinding(), connection: connection)
        fixture.coordinator.test_installController(controller, for: fixture.session, hostID: "host-id")
    }

    private func makePendingAskUser(currentQuestionIndex: Int = 0) -> AgentAskUserPendingState {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            remoteInteractionID: "wire-question",
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

    private func makeResponse() -> AgentAskUserResponse {
        AgentAskUserResponse(
            answersByQuestionID: [
                "first": AgentAskUserAnswer(answers: ["A"], selectedOptions: ["A"], customResponse: nil, skipped: false),
                "second": AgentAskUserAnswer(answers: ["draft text"], selectedOptions: [], customResponse: "draft text", skipped: false)
            ],
            timedOut: false,
            skipped: false,
            elapsedSeconds: 1
        )
    }

    private func makeBinding() -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: "host-id",
            hostDisplayName: "Remote Host",
            remoteSessionID: "remote-session",
            lastAppliedSeq: 0,
            nextLogOffset: 0
        )
    }

    private static func questionSnapshot() -> JSONValue {
        .object([
            "session_id": .string("remote-session"),
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string("wire-question"),
                "kind": .string("question"),
                "response_type": .string("structured"),
                "fields": .array([
                    .object([
                        "id": .string("first"),
                        "prompt": .string("Choose one"),
                        "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])])
                    ]),
                    .object([
                        "id": .string("second"),
                        "prompt": .string("Explain"),
                        "is_other": .bool(true)
                    ])
                ])
            ])
        ])
    }

    fileprivate static func runningSnapshot() -> JSONValue {
        .object([
            "session_id": .string("remote-session"),
            "status": .string("running")
        ])
    }

    fileprivate static func emptyLogPayload() -> JSONValue {
        .object([
            "session_id": .string("remote-session"),
            "turn_offset": .int(0),
            "turn_limit": .int(20),
            "returned_turn_count": .int(0),
            "total_turns": .int(0),
            "transcript_xml": .string("<transcript/>")
        ])
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private struct SubmitResponseFixture {
        let tabID: UUID
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let coordinator: RemoteAgentModeCoordinator
    }
}

private struct StubCommandError: Error {}

private actor StubRemoteConnection: RemoteAgentSessionConnection {
    enum ScriptResult {
        case success(JSONValue)
        case failure(Error)
    }

    private var script: [String: [ScriptResult]]
    private(set) var frames: [RemoteClientFrame] = []

    init(script: [String: [ScriptResult]]) {
        self.script = script
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        guard var queue = script[frame.type], !queue.isEmpty else {
            switch frame.type {
            case "poll":
                return RemoteAgentModeCoordinatorSubmitResponseWiringTests.runningSnapshot()
            case "get_log":
                return RemoteAgentModeCoordinatorSubmitResponseWiringTests.emptyLogPayload()
            default:
                return .object([:])
            }
        }
        let result = queue.removeFirst()
        script[frame.type] = queue
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }

    func ensureConnected() async throws {}

    func subscribe(sessionIDs _: [String]) async throws {
        guard var queue = script["subscribe"], !queue.isEmpty else { return }
        let result = queue.removeFirst()
        script["subscribe"] = queue
        if case let .failure(error) = result {
            throw error
        }
    }

    func unsubscribe(sessionIDs _: [String]) async throws {}
}

private final class SubmitResponseNoopCodexController: CodexSessionControlling {
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
