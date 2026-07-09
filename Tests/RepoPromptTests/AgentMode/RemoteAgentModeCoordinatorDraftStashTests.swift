@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentModeCoordinatorDraftStashTests: XCTestCase {
    @MainActor
    func testDraftStashMergesIntoReAppliedQuestionWithEmptyDrafts() async throws {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "wire-question", currentQuestionIndex: 1)
        let connection = DraftStashConnection(pollPayload: Self.questionSnapshot(interactionID: "wire-question"))
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let pump = pumpEvents(from: controller, into: fixture)
        defer { pump.cancel() }

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: makeRestorable(interactionID: "wire-question", pendingAskUser: pending),
            controller: controller
        )
        try await waitUntil { fixture.session.pendingAskUser?.interaction.remoteInteractionID == "wire-question" }

        let restored = try XCTUnwrap(fixture.session.pendingAskUser)
        XCTAssertEqual(restored.currentQuestionIndex, 1)
        XCTAssertEqual(restored.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        XCTAssertEqual(restored.draftsByQuestionID["second"]?.customResponse, "draft text")
    }

    @MainActor
    func testDraftStashIsOneShot() async throws {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "wire-question", currentQuestionIndex: 1)
        let connection = DraftStashConnection(pollPayload: Self.questionSnapshot(interactionID: "wire-question"))
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let pump = pumpEvents(from: controller, into: fixture)
        defer { pump.cancel() }

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: makeRestorable(interactionID: "wire-question", pendingAskUser: pending),
            controller: controller
        )
        try await waitUntil { fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels == ["A"] }
        fixture.session.pendingAskUser = nil

        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )

        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
        XCTAssertEqual(fixture.session.pendingAskUser?.currentQuestionIndex, 0)
    }

    @MainActor
    func testDraftStashClearedByDifferentInteraction() async {
        let fixture = await makeFixture()
        let release = await suspendWithStash(fixture: fixture, interactionID: "wire-question")
        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "other-question", pending: makeFreshPendingAskUser(remoteInteractionID: "other-question")),
            statusText: nil,
            to: fixture.session
        )
        release.session.runState = .completed
        await release.finish()

        fixture.session.pendingAskUser = nil
        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
    }

    @MainActor
    func testDraftStashClearedByOtherInteractionKind() async {
        let fixture = await makeFixture()
        let release = await suspendWithStash(fixture: fixture, interactionID: "wire-question")
        fixture.coordinator.applyRunState(
            .waitingForApproval,
            pendingInteraction: .approval(interactionID: "approval", request: makeApprovalRequest(interactionID: "approval")),
            statusText: nil,
            to: fixture.session
        )
        release.session.runState = .completed
        await release.finish()

        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
    }

    @MainActor
    func testDraftStashClearedWhenPendingInteractionNil() async {
        let fixture = await makeFixture()
        let release = await suspendWithStash(fixture: fixture, interactionID: "wire-question")
        fixture.coordinator.applyRunState(.running, pendingInteraction: nil, statusText: nil, to: fixture.session)
        release.session.runState = .completed
        await release.finish()

        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
    }

    @MainActor
    func testDraftStashClearedOnTerminal() async {
        let fixture = await makeFixture()
        let release = await suspendWithStash(fixture: fixture, interactionID: "wire-question")
        fixture.coordinator.test_applyTerminal(status: "completed", to: fixture.session)
        await release.finish()

        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
    }

    @MainActor
    func testDraftStashNotMergedWhenIncomingDraftsHaveContent() async {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "wire-question", currentQuestionIndex: 1)
        let incoming = makePendingAskUser(remoteInteractionID: "wire-question", firstDraft: AgentAskUserDraft(selectedOptionLabels: ["B"]))
        let connection = DraftStashConnection(pollPayload: Self.emptyLogPayload(), suspendsSubscribe: true)
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let task = Task { await fixture.coordinator.recoverFromRespondFailure(tabID: fixture.tabID, restorable: makeRestorable(interactionID: "wire-question", pendingAskUser: pending), controller: controller) }
        await connection.waitUntilSubscribeStarted()

        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: incoming),
            statusText: nil,
            to: fixture.session
        )
        fixture.session.runState = .completed
        await connection.releaseSubscribe(throwing: DraftStashStubError())
        await task.value

        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, ["B"])
        XCTAssertEqual(fixture.session.pendingAskUser?.currentQuestionIndex, 0)
    }

    @MainActor
    func testDraftStashClampsIndexAndDropsUnknownQuestionIDs() async throws {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "wire-question", currentQuestionIndex: 99, includeUnknownDraft: true)
        let connection = DraftStashConnection(pollPayload: Self.questionSnapshot(interactionID: "wire-question", includeSecondQuestion: false))
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let pump = pumpEvents(from: controller, into: fixture)
        defer { pump.cancel() }

        await fixture.coordinator.recoverFromRespondFailure(
            tabID: fixture.tabID,
            restorable: makeRestorable(interactionID: "wire-question", pendingAskUser: pending),
            controller: controller
        )
        try await waitUntil { fixture.session.pendingAskUser?.interaction.remoteInteractionID == "wire-question" }

        let restored = try XCTUnwrap(fixture.session.pendingAskUser)
        XCTAssertEqual(restored.currentQuestionIndex, 0)
        XCTAssertEqual(restored.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        XCTAssertNil(restored.draftsByQuestionID["unknown"])
        XCTAssertNil(restored.draftsByQuestionID["second"])
    }

    @MainActor
    func testLocalRestoreConsumesStash() async {
        let fixture = await makeFixture()
        let pending = makePendingAskUser(remoteInteractionID: "wire-question", currentQuestionIndex: 1)
        let connection = DraftStashConnection(pollPayload: Self.emptyLogPayload(), suspendsSubscribe: true)
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let task = Task { await fixture.coordinator.recoverFromRespondFailure(tabID: fixture.tabID, restorable: makeRestorable(interactionID: "wire-question", pendingAskUser: pending), controller: controller) }
        await connection.waitUntilSubscribeStarted()
        await connection.releaseSubscribe(throwing: DraftStashStubError())
        await task.value

        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, ["A"])
        fixture.session.pendingAskUser = nil
        fixture.coordinator.applyRunState(
            .waitingForQuestion,
            pendingInteraction: .question(interactionID: "wire-question", pending: makeFreshPendingAskUser(remoteInteractionID: "wire-question")),
            statusText: nil,
            to: fixture.session
        )
        XCTAssertEqual(fixture.session.pendingAskUser?.draftsByQuestionID["first"]?.selectedOptionLabels, [])
    }

    @MainActor
    private func makeFixture() async -> DraftStashFixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in DraftStashNoopCodexController() }
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        session.remoteHost = makeBinding(remoteSessionID: "remote-session")
        let coordinator = RemoteAgentModeCoordinator()
        coordinator.attach(viewModel: viewModel)
        return DraftStashFixture(tabID: tabID, viewModel: viewModel, session: session, coordinator: coordinator)
    }

    @MainActor
    private func pumpEvents(from controller: RemoteAgentSessionController, into fixture: DraftStashFixture) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in controller.events {
                switch event {
                case let .runState(runState, pendingInteraction, statusText):
                    fixture.coordinator.applyRunState(runState, pendingInteraction: pendingInteraction, statusText: statusText, to: fixture.session)
                case let .terminal(status):
                    fixture.coordinator.test_applyTerminal(status: status, to: fixture.session)
                case .sessionExpired:
                    fixture.coordinator.test_handleEvent(.sessionExpired, tabID: fixture.tabID)
                default:
                    break
                }
            }
        }
    }

    @MainActor
    private func suspendWithStash(fixture: DraftStashFixture, interactionID: String) async -> SuspendedRecover {
        let connection = DraftStashConnection(pollPayload: Self.emptyLogPayload(), suspendsSubscribe: true)
        let controller = RemoteAgentSessionController(binding: makeBinding(remoteSessionID: "remote-session"), connection: connection)
        let pending = makePendingAskUser(remoteInteractionID: interactionID, currentQuestionIndex: 1)
        let task = Task { await fixture.coordinator.recoverFromRespondFailure(tabID: fixture.tabID, restorable: makeRestorable(interactionID: interactionID, pendingAskUser: pending), controller: controller) }
        await connection.waitUntilSubscribeStarted()
        return SuspendedRecover(connection: connection, task: task, session: fixture.session)
    }

    private func makePendingAskUser(
        remoteInteractionID: String,
        currentQuestionIndex: Int = 0,
        firstDraft: AgentAskUserDraft = AgentAskUserDraft(selectedOptionLabels: ["A"]),
        secondDraft: AgentAskUserDraft = AgentAskUserDraft(customResponse: "draft text"),
        includeUnknownDraft: Bool = false
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
        drafts["first"] = firstDraft
        drafts["second"] = secondDraft
        if includeUnknownDraft {
            drafts["unknown"] = AgentAskUserDraft(customResponse: "drop me")
        }
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: drafts,
            currentQuestionIndex: currentQuestionIndex
        )
    }

    private func makeFreshPendingAskUser(remoteInteractionID: String) -> AgentAskUserPendingState {
        makePendingAskUser(
            remoteInteractionID: remoteInteractionID,
            firstDraft: AgentAskUserDraft(),
            secondDraft: AgentAskUserDraft()
        )
    }

    private func makeRestorable(
        interactionID: String,
        pendingAskUser: AgentAskUserPendingState
    ) -> RemoteAgentModeCoordinator.RestorableInteractionState {
        RemoteAgentModeCoordinator.RestorableInteractionState(
            interactionID: interactionID,
            priorRunState: .waitingForQuestion,
            pendingApproval: nil,
            pendingAskUser: pendingAskUser,
            pendingUserInputRequest: nil,
            pendingMCPElicitationRequest: nil
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

    private func makeBinding(remoteSessionID: String) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: "host-id",
            hostDisplayName: "Remote Host",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: 0,
            nextLogOffset: 0
        )
    }

    private static func questionSnapshot(interactionID: String, includeSecondQuestion: Bool = true) -> JSONValue {
        var fields: [JSONValue] = [
            .object([
                "id": .string("first"),
                "prompt": .string("Choose one"),
                "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])])
            ])
        ]
        if includeSecondQuestion {
            fields.append(.object([
                "id": .string("second"),
                "prompt": .string("Explain"),
                "is_other": .bool(true)
            ]))
        }
        return .object([
            "session_id": .string("remote-session"),
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string(interactionID),
                "kind": .string("question"),
                "response_type": .string("structured"),
                "fields": .array(fields)
            ])
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

    private struct DraftStashFixture {
        let tabID: UUID
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let coordinator: RemoteAgentModeCoordinator
    }

    private struct SuspendedRecover {
        let connection: DraftStashConnection
        let task: Task<Void, Never>
        let session: AgentModeViewModel.TabSession

        func finish() async {
            await connection.releaseSubscribe(throwing: DraftStashStubError())
            await task.value
        }
    }
}

private struct DraftStashStubError: Error {}

private actor DraftStashConnection: RemoteAgentSessionConnection {
    private let pollPayload: JSONValue
    private let suspendsSubscribe: Bool
    private var subscribeStarted = false
    private var subscribeContinuation: CheckedContinuation<Void, Error>?

    init(pollPayload: JSONValue, suspendsSubscribe: Bool = false) {
        self.pollPayload = pollPayload
        self.suspendsSubscribe = suspendsSubscribe
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        switch frame.type {
        case "poll":
            pollPayload
        case "get_log":
            RemoteAgentModeCoordinatorDraftStashTests.emptyLogPayload()
        default:
            .object([:])
        }
    }

    func ensureConnected() async throws {}

    func subscribe(sessionIDs _: [String]) async throws {
        subscribeStarted = true
        guard suspendsSubscribe else { return }
        try await withCheckedThrowingContinuation { continuation in
            subscribeContinuation = continuation
        }
    }

    func unsubscribe(sessionIDs _: [String]) async throws {}

    func waitUntilSubscribeStarted() async {
        while !subscribeStarted {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func releaseSubscribe(throwing error: Error? = nil) {
        guard let continuation = subscribeContinuation else { return }
        subscribeContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private final class DraftStashNoopCodexController: CodexSessionControlling {
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
