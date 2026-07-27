import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Regression coverage for the fork-staged remote session incident
/// (2026-07-27): a live, never-run session with no MCP control context and no
/// session-index entry must not be reported as `expired` by `agent_run` poll —
/// the remote gateway watch relays that verbatim as `session_expired` and the
/// paired client marks the freshly forked tab failed.
@MainActor
final class AgentRunLiveSessionFallbackTests: XCTestCase {
    func testPollFallsBackToLiveUnregisteredSessionInsteadOfExpired() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(window: window, viewModel: viewModel)

        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertNil(viewModel.sessionIndex[sessionID])

        let poll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        let object = try XCTUnwrap(poll.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        let statusText = try XCTUnwrap(object["status_text"]?.stringValue)
        XCTAssertTrue(
            statusText.contains("no active control handle"),
            "Unexpected status text: \(statusText)"
        )
        XCTAssertEqual(
            object["session"]?.objectValue?["context_id"]?.stringValue,
            session.tabID.uuidString
        )
    }

    func testPollStillReportsExpiredForUnknownSession() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(window: window, viewModel: viewModel)

        let poll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(UUID().uuidString)
        ])
        XCTAssertEqual(
            poll.objectValue?["status"]?.stringValue,
            AgentRunMCPSnapshot.Status.expired.rawValue
        )
    }

    func testActiveUnregisteredRunStateCollapsesToCompletedWithLastRecordedState() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(window: window, viewModel: viewModel)

        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running

        let poll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        let object = try XCTUnwrap(poll.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        let statusText = try XCTUnwrap(object["status_text"]?.stringValue)
        XCTAssertTrue(
            statusText.contains("last recorded state: running"),
            "Unexpected status text: \(statusText)"
        )
    }

    func testCancelOnUnregisteredLiveSessionReportsNotActiveInsteadOfExpiredHandle() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(window: window, viewModel: viewModel)

        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)

        do {
            _ = try await service.execute(args: [
                "op": .string("cancel"),
                "session_id": .string(sessionID.uuidString)
            ])
            XCTFail("Expected cancel on an unregistered live session to throw")
        } catch let error as MCPError {
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("not currently active"),
                "Unexpected cancel error: \(description)"
            )
        }
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func makeViewModel(windowID: Int) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LiveFallbackStubCodexController() }
        )
    }

    private func makeService(window: WindowState, viewModel: AgentModeViewModel) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-live-fallback-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by live fallback tests")
            }
        )
        service.testAgentModeViewModel = viewModel
        return service
    }
}

private final class LiveFallbackStubCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "live-fallback-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "live-fallback-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "live-fallback-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "live-fallback-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
