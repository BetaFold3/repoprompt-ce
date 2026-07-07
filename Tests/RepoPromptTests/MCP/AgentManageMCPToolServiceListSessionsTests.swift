import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentManageMCPToolServiceListSessionsTests: XCTestCase {
    func testListSessionsExplicitParentSessionIDReturnsMatchingChildren() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let parentID = UUID()
        let otherParentID = UUID()
        let matchingChildID = try await installSession(on: window, parentSessionID: parentID, state: .running)
        _ = try await installSession(on: window, parentSessionID: otherParentID, state: .running)
        _ = try await installSession(on: window, parentSessionID: nil, state: .completed)
        let service = makeService(window: window)

        let value = try await service.execute(args: [
            "op": .string("list_sessions"),
            "parent_session_id": .string(parentID.uuidString),
            "limit": .int(10)
        ])

        let sessions = try XCTUnwrap(value.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 1)
        let child = try XCTUnwrap(sessions.first?.objectValue)
        XCTAssertEqual(child["session_id"]?.stringValue, matchingChildID.uuidString)
        XCTAssertEqual(child["parent_session_id"]?.stringValue, parentID.uuidString)
    }

    func testListSessionsExplicitParentDoesNotWidenConnectionScopedParent() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let scopedParentID = UUID()
        let requestedParentID = UUID()
        _ = try await installSession(on: window, parentSessionID: requestedParentID, state: .running)
        _ = try await installSession(on: window, parentSessionID: scopedParentID, state: .running)
        let service = makeService(window: window, scopedParentSessionID: scopedParentID)

        let value = try await service.execute(args: [
            "op": .string("list_sessions"),
            "parent_session_id": .string(requestedParentID.uuidString)
        ])

        let sessions = try XCTUnwrap(value.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 0)
    }

    func testListSessionsUsesMetadataParentScopeWhenArgAbsent() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let scopedParentID = UUID()
        let otherParentID = UUID()
        let matchingChildID = try await installSession(on: window, parentSessionID: scopedParentID, state: .running)
        _ = try await installSession(on: window, parentSessionID: otherParentID, state: .running)
        let service = makeService(window: window, scopedParentSessionID: scopedParentID)

        let value = try await service.execute(args: [
            "op": .string("list_sessions")
        ])

        let sessions = try XCTUnwrap(value.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.objectValue?["session_id"]?.stringValue, matchingChildID.uuidString)
        XCTAssertEqual(sessions.first?.objectValue?["parent_session_id"]?.stringValue, scopedParentID.uuidString)
    }

    private func installSession(
        on window: WindowState,
        parentSessionID: UUID?,
        state: AgentSessionRunState
    ) async throws -> UUID {
        let sessionID = UUID()
        let tabID = UUID()
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.parentSessionID = parentSessionID
        session.runState = state
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "codex"
        return sessionID
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "List Sessions \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageListSessionsTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        scopedParentSessionID: UUID? = nil
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "list-sessions-parent-filter-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in scopedParentSessionID },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }
}
