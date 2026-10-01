import Foundation
@testable import RepoPromptApp
import XCTest

/// Pins the native Claude "Compacting context" running-status release: a nil-text `status`
/// stream result clears only the exact compaction-owned transport label, and never touches
/// newer transport labels, reasoning labels, stale runs, or non-native agents.
@MainActor
final class ClaudeCompactionRunningStatusTests: XCTestCase {
    private static let compactingLine = #"{"type":"system","subtype":"status","status":"compacting","session_id":"s-1"}"#
    /// Terminal payload shape from the captured `2.1.268-compact.jsonl` fixture.
    private static let terminalStatusLine = #"{"type":"system","subtype":"status","status":null,"compact_result":"<redacted>","compact_error":"Not enough messages to compact.","session_id":"s-1"}"#
    private var approvalSetupTeardowns: [() async -> Void] = []

    override func tearDown() async throws {
        let teardowns = approvalSetupTeardowns
        approvalSetupTeardowns.removeAll()
        for teardown in teardowns {
            await teardown()
        }
        try await super.tearDown()
    }

    private static let compactBoundaryLine = #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":327303},"session_id":"s-1"}"#

    func testTranslatorCompactingLabelThenReleaseClearsTextAndSource() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let compacting = translate(Self.compactingLine)
        XCTAssertEqual(compacting.map(\.type), ["status"])
        let label = try XCTUnwrap(compacting.first?.text)

        await send(compacting, harness)
        // Canonical pin: the view model shows exactly the translator's label as a transport status.
        XCTAssertEqual(harness.session.runningStatusText, label)
        XCTAssertEqual(harness.session.runningStatusSource, .transport)

        let release = translate(Self.terminalStatusLine)
        XCTAssertEqual(release.map(\.type), ["status"])
        XCTAssertNil(release.first?.text)

        harness.viewModel.test_flushPendingUIRefresh()
        let bindingUpdates = harness.viewModel.test_updateBindingsCallCount
        await send(release, harness)
        harness.viewModel.test_flushPendingUIRefresh()

        XCTAssertNil(harness.session.runningStatusText)
        XCTAssertNil(harness.session.runningStatusSource)
        XCTAssertGreaterThan(harness.viewModel.test_updateBindingsCallCount, bindingUpdates)
    }

    func testCompactBoundaryReleaseClearsAndDuplicateReleaseIsNoOp() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        await send(translate(Self.compactingLine), harness)
        XCTAssertNotNil(harness.session.runningStatusText)

        let boundary = translate(Self.compactBoundaryLine)
        XCTAssertEqual(boundary.map(\.type), ["status", "system"])
        XCTAssertNil(boundary.first?.text)
        await send(boundary, harness)

        XCTAssertNil(harness.session.runningStatusText)
        XCTAssertNil(harness.session.runningStatusSource)

        try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
        try await assertReleaseIsNoOp(harness, release: [boundary[0]])
    }

    func testReleaseLeavesNewerOrNonCompactionTransportLabelsUnchanged() async throws {
        let harness = try await makeHarness(agent: .claudeCode)

        // A real progress event after compaction began wins over the later release.
        await send(translate(Self.compactingLine), harness)
        await send([AIStreamResult(type: "tool_progress", text: "Running Bash")], harness)
        XCTAssertEqual(harness.session.runningStatusText, "Running Bash")
        try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
        XCTAssertEqual(harness.session.runningStatusText, "Running Bash")
        XCTAssertEqual(harness.session.runningStatusSource, .transport)

        await send([AIStreamResult(type: "task_progress", text: "Indexing files")], harness)
        XCTAssertEqual(harness.session.runningStatusText, "Indexing files")
        try await assertReleaseIsNoOp(harness, release: translate(Self.compactBoundaryLine).filter { $0.type == "status" })
        XCTAssertEqual(harness.session.runningStatusText, "Indexing files")

        // Other transport labels, including a near-miss of the canonical text, are never cleared.
        for label in ["Thinking…", "Authenticating", "Compacting context — 50%", "compacting context"] {
            harness.session.setRunningStatus(label, source: .transport)
            try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
            XCTAssertEqual(harness.session.runningStatusText, label)
            XCTAssertEqual(harness.session.runningStatusSource, .transport)
        }
    }

    func testReleaseLeavesReasoningLabelAndPendingReasoningStateUntouched() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        let session = harness.session
        let label = try XCTUnwrap(translate(Self.compactingLine).first?.text)
        let flushTask = Task<Void, Never> {}
        defer { flushTask.cancel() }

        for reasoningLabel in ["Planning the edit", label] {
            session.setRunningStatus(reasoningLabel, source: .reasoning)
            session.claudeReasoningStatusBuffer = "buffered reasoning"
            session.claudeReasoningStatusPendingText = "pending preview"
            session.claudeReasoningStatusFlushTask = flushTask

            try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))

            XCTAssertEqual(session.runningStatusText, reasoningLabel)
            XCTAssertEqual(session.runningStatusSource, .reasoning)
            XCTAssertEqual(session.claudeReasoningStatusBuffer, "buffered reasoning")
            XCTAssertEqual(session.claudeReasoningStatusPendingText, "pending preview")
            XCTAssertNotNil(session.claudeReasoningStatusFlushTask)
            XCTAssertFalse(flushTask.isCancelled)
        }
        session.claudeReasoningStatusFlushTask = nil
    }

    func testReleaseWithNothingShownDoesNotUpdateBindings() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        XCTAssertNil(harness.session.runningStatusText)

        try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
        try await assertReleaseIsNoOp(harness, release: translate(Self.compactBoundaryLine).filter { $0.type == "status" })
        XCTAssertNil(harness.session.runningStatusText)
        XCTAssertNil(harness.session.runningStatusSource)
    }

    func testStaleRunOrAttemptReleaseIsRejected() async throws {
        let harness = try await makeHarness(agent: .claudeCode)
        await send(translate(Self.compactingLine), harness)
        let label = harness.session.runningStatusText
        XCTAssertNotNil(label)
        let release = translate(Self.terminalStatusLine)

        try await assertReleaseIsNoOp(harness, release: release, runID: UUID())
        XCTAssertEqual(harness.session.runningStatusText, label)

        try await assertReleaseIsNoOp(harness, release: release, runAttemptID: UUID())
        XCTAssertEqual(harness.session.runningStatusText, label)

        // A superseded attempt of the same run is rejected too.
        let staleAttemptID = harness.runAttemptID
        harness.session.beginRunAttempt(source: "test.claudeCompactionStatus.next")
        XCTAssertNotEqual(harness.session.activeRunAttemptID, staleAttemptID)
        try await assertReleaseIsNoOp(harness, release: release, runAttemptID: staleAttemptID)
        XCTAssertEqual(harness.session.runningStatusText, label)
        XCTAssertEqual(harness.session.runningStatusSource, .transport)
    }

    func testClaudeCompatibleNativeAgentsClearCompactionLabel() async throws {
        for agent in [AgentProviderKind.claudeCodeGLM, .kimiCode, .customClaudeCompatible] {
            XCTAssertTrue(agent.usesClaudeNativeRuntime, "\(agent)")
            let harness = try await makeHarness(agent: agent)
            await send(translate(Self.compactingLine), harness)
            XCTAssertEqual(harness.session.runningStatusSource, .transport, "\(agent)")
            XCTAssertNotNil(harness.session.runningStatusText, "\(agent)")

            await send(translate(Self.terminalStatusLine), harness)
            XCTAssertNil(harness.session.runningStatusText, "\(agent)")
            XCTAssertNil(harness.session.runningStatusSource, "\(agent)")

            try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
        }
    }

    func testNonNativeAgentReleaseLeavesCompactingLabelUnchanged() async throws {
        let agent = AgentProviderKind.openCode
        XCTAssertFalse(agent.usesClaudeNativeRuntime)
        let harness = try await makeHarness(agent: agent)
        let label = try XCTUnwrap(translate(Self.compactingLine).first?.text)
        await send([AIStreamResult(type: "status", text: label)], harness)
        XCTAssertEqual(harness.session.runningStatusText, label)
        XCTAssertEqual(harness.session.runningStatusSource, .transport)

        try await assertReleaseIsNoOp(harness, release: translate(Self.terminalStatusLine))
        XCTAssertEqual(harness.session.runningStatusText, label)
        XCTAssertEqual(harness.session.runningStatusSource, .transport)
    }

    // MARK: - Helpers

    private struct Harness {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let runID: UUID
        let runAttemptID: UUID
        /// The session-owned apply_edits approval setup task, held at the store's initial-setup hook.
        let approvalSetupTask: Task<Void, Never>
    }

    private func makeHarness(agent: AgentProviderKind) async throws -> Harness {
        // Session creation starts a session-owned apply_edits approval subscription task whose
        // snapshot deliveries each request an urgent full UI refresh. That is unrelated to running
        // status, so the harness uses an isolated store whose existing DEBUG initial-setup hook holds
        // the setup before any snapshot is yielded. The session keeps owning the held task, so its
        // `applyEditsApprovalSubscriptionTask == nil` guard never re-creates a subscription, and
        // teardown explicitly cancels, releases, and awaits it.
        let approvalStore = ApplyEditsApprovalStore()
        let approvalSetupGate = ApprovalSetupGate()
        await approvalStore.test_setInitialSetupHook { _ in
            await approvalSetupGate.hold()
        }
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            applyEditsApprovalStore: approvalStore,
            codexControllerFactory: { _, _, _, _, _, _ in CompactionStatusNoopCodexController() }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        let approvalSetupTask = try XCTUnwrap(session.applyEditsApprovalSubscriptionTask)
        approvalSetupTeardowns.append { [session] in
            // Cancel before releasing so the resumed setup observes cancellation and installs nothing.
            approvalSetupTask.cancel()
            approvalSetupGate.release()
            await approvalSetupTask.value
            XCTAssertNil(session.applyEditsApprovalSubscriptionTask)
            XCTAssertNil(session.applyEditsApprovalSubscriptionID)
            await approvalStore.test_setInitialSetupHook(nil)
        }
        session.selectedAgent = agent
        let runID = UUID()
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.claudeCompactionStatus")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        viewModel.test_flushPendingUIRefresh()
        return Harness(
            viewModel: viewModel,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            approvalSetupTask: approvalSetupTask
        )
    }

    /// Runs each line through the app translator facade, which wraps the provider package
    /// translator and the package-to-app bridge, so the view model sees production output.
    private func translate(_ line: String) -> [AIStreamResult] {
        var translator = ClaudeSDKNDJSONTranslator()
        return translator.parseNDJSONLine(Data(line.utf8))
    }

    private func send(
        _ results: [AIStreamResult],
        _ harness: Harness,
        runID: UUID? = nil,
        runAttemptID: UUID? = nil
    ) async {
        for result in results {
            await harness.viewModel.test_handleStreamResult(
                result,
                session: harness.session,
                runID: runID ?? harness.runID,
                runAttemptID: runAttemptID ?? harness.runAttemptID
            )
        }
    }

    /// Harness isolation precondition: the session still owns the original held approval setup
    /// task and no subscription was installed, so no approval snapshot can drive a refresh.
    private func assertApprovalSetupStillHeld(
        _ harness: Harness,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(
            harness.session.applyEditsApprovalSubscriptionTask,
            harness.approvalSetupTask,
            "approval setup task replaced",
            file: file,
            line: line
        )
        XCTAssertNil(harness.session.applyEditsApprovalSubscriptionID, "approval subscription installed", file: file, line: line)
    }

    /// Asserts a release leaves running status untouched and publishes no binding update,
    /// using the existing UI-refresh flush seam and binding-sync counters.
    private func assertReleaseIsNoOp(
        _ harness: Harness,
        release: [AIStreamResult],
        runID: UUID? = nil,
        runAttemptID: UUID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertFalse(release.isEmpty, file: file, line: line)
        XCTAssertTrue(release.allSatisfy { $0.type == "status" && $0.text == nil }, file: file, line: line)
        let viewModel = harness.viewModel
        assertApprovalSetupStillHeld(harness, file: file, line: line)
        viewModel.test_flushPendingUIRefresh()
        let text = harness.session.runningStatusText
        let source = harness.session.runningStatusSource
        let updateBindingsCount = viewModel.test_updateBindingsCallCount
        let runInteractionSyncCount = viewModel.test_syncRunInteractionCallCount

        await send(release, harness, runID: runID, runAttemptID: runAttemptID)
        viewModel.test_flushPendingUIRefresh()
        assertApprovalSetupStillHeld(harness, file: file, line: line)

        XCTAssertEqual(harness.session.runningStatusText, text, file: file, line: line)
        XCTAssertEqual(harness.session.runningStatusSource, source, file: file, line: line)
        XCTAssertEqual(viewModel.test_updateBindingsCallCount, updateBindingsCount, "updateBindings", file: file, line: line)
        XCTAssertEqual(viewModel.test_syncRunInteractionCallCount, runInteractionSyncCount, "runInteractionSync", file: file, line: line)
    }
}

/// Holds the isolated approval store's initial setup until teardown releases it. A release that
/// precedes `hold()` makes later holds return immediately.
@MainActor
private final class ApprovalSetupGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class CompactionStatusNoopCodexController: CodexSessionControlling {
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
