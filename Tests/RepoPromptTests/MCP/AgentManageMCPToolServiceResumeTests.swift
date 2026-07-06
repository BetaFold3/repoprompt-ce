import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentManageMCPToolServiceResumeTests: XCTestCase {
    func testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let initialConnectionID = UUID()
        let resumedConnectionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: initialConnectionID,
            taskLabelKind: .pair,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.resume.initial")
        session.runState = .running
        viewModel.publishMCPStateChange(for: session)

        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        let initialCursor = AgentRunSessionStore.WaitCursor(
            registration: initialContext.registration,
            epoch: initialEpoch
        )
        let originalWait = Task {
            await AgentRunSessionStore.waitUntilInteresting(
                cursor: initialCursor,
                timeoutSeconds: 1
            )
        }
        try await waitForAgentRunSessionStoreWaiter(registration: initialContext.registration)

        let service = makeService(window: window, connectionID: resumedConnectionID)
        _ = try await service.execute(args: [
            "op": .string("resume_session"),
            "session_id": .string(sessionID.uuidString)
        ])

        let resumedContext = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(resumedContext.activationID, initialContext.activationID)
        XCTAssertEqual(resumedContext.registration, initialContext.registration)
        XCTAssertEqual(resumedContext.taskLabelKind, .pair)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, initialContext.registration)

        session.runState = .cancelled
        try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        let steeredContext = try XCTUnwrap(session.mcpControlContext)
        let steeredEpoch = try XCTUnwrap(steeredContext.currentEpoch)
        XCTAssertEqual(steeredContext.registration, initialContext.registration)
        XCTAssertEqual(steeredEpoch.transitionKind, .steering)

        let firstDisposition = await originalWait.value
        XCTAssertEqual(firstDisposition, .epochAdvanced(steeredEpoch, .steering))

        let steeredCursor = AgentRunSessionStore.WaitCursor(
            registration: initialContext.registration,
            epoch: steeredEpoch
        )
        let steeredWait = Task {
            await AgentRunSessionStore.waitUntilInteresting(
                cursor: steeredCursor,
                timeoutSeconds: 1
            )
        }
        try await waitForAgentRunSessionStoreWaiter(registration: initialContext.registration)
        let cancelled = makeSnapshot(sessionID: sessionID, status: .cancelled)
        await AgentRunSessionStore.signalSnapshot(cancelled, cursor: steeredCursor)
        let terminalDisposition = await steeredWait.value
        XCTAssertEqual(terminalDisposition, .snapshotReady(cancelled))

        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testGetLogReportsOnlyLeadingCompletedTurns() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let service = makeService(window: window, connectionID: UUID())

        session.runState = .running
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [.user("Prompt", sequenceIndex: 0)],
            terminalState: .running,
            compact: false
        )
        let runningResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(runningResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(runningResult.objectValue?["returned_turn_count"]?.intValue, 1)

        session.runState = .completed
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Reply", sequenceIndex: 1)
            ],
            terminalState: .completed,
            compact: false
        )
        let completedResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(completedResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(completedResult.objectValue?["returned_turn_count"]?.intValue, 1)

        session.runState = .running
        var staleMiddleTranscript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Reply", sequenceIndex: 1),
                .user("Follow-up", sequenceIndex: 2)
            ],
            terminalState: .running,
            compact: false
        )
        staleMiddleTranscript.turns[0].terminalState = .running
        session.transcript = staleMiddleTranscript
        let staleMiddleResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(staleMiddleResult.objectValue?["completed_turn_count"]?.intValue, 1)
        XCTAssertEqual(staleMiddleResult.objectValue?["returned_turn_count"]?.intValue, 2)

        session.runState = .waitingForUser
        session.transcript = AgentTranscriptIO.buildTranscript(
            from: [
                .user("Prompt", sequenceIndex: 0),
                .assistant("Need input", sequenceIndex: 1)
            ],
            terminalState: .waitingForUser,
            compact: false
        )
        let waitingResult = try await service.execute(args: [
            "op": .string("get_log"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(waitingResult.objectValue?["completed_turn_count"]?.intValue, 0)
        XCTAssertEqual(waitingResult.objectValue?["returned_turn_count"]?.intValue, 1)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Resume Ownership \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageResumeOwnershipTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        connectionID: UUID
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "resume-ownership-regression",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Pair Session",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: "buffered assistant text",
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: status == .cancelled ? .cancelled : nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}
