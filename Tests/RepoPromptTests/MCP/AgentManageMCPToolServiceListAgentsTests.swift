import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentManageMCPToolServiceListAgentsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        #if DEBUG
            await OMPQualificationSharedGateTestIsolation.shared.acquire()
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #endif
    }

    override func tearDown() async throws {
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
            await OMPQualificationSharedGateTestIsolation.shared.release()
        #endif
        try await super.tearDown()
    }

    func testListAgentsModelEntriesIncludeStructuredRemotePickerFields() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.isOpenCodeConnected = true
        let service = makeService(window: window)

        let value = try await service.execute(args: ["op": .string("list_agents")])

        let object = try XCTUnwrap(value.objectValue)
        let agents = try XCTUnwrap(object["agents"]?.arrayValue)
        XCTAssertFalse(agents.isEmpty)

        let modelObjects = agents.flatMap { agentValue -> [[String: Value]] in
            let models = agentValue.objectValue?["models"]?.arrayValue ?? []
            return models.compactMap(\.objectValue)
        }
        let structuredModel = try XCTUnwrap(modelObjects.first { model in
            model["model_id"]?.stringValue?.isEmpty == false
                && model["agent_id"]?.stringValue?.isEmpty == false
                && model["base_model_id"]?.stringValue?.isEmpty == false
                && model["model_display_name"]?.stringValue?.isEmpty == false
        })

        XCTAssertNotNil(structuredModel["name"]?.stringValue)
        XCTAssertNotNil(structuredModel["is_default"]?.boolValue)

        let effortModel = try XCTUnwrap(modelObjects.first { model in
            model["effort"]?.stringValue?.isEmpty == false
                && model["effort_display_name"]?.stringValue?.isEmpty == false
        })
        XCTAssertEqual(effortModel["reasoning_effort"]?.stringValue, effortModel["effort"]?.stringValue)
        XCTAssertNotEqual(effortModel["name"]?.stringValue, effortModel["model_display_name"]?.stringValue)
    }

    func testFirstQualificationListAgentsAdvertisesOnlyOhMyPiDefaultSentinel() async throws {
        #if DEBUG
            let window = try await makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try OhMyPiAgentModeSmokeGate.shared.acquireForTesting()

            let value = try await makeService(window: window).execute(args: ["op": .string("list_agents")])
            let agents = try XCTUnwrap(value.objectValue?["agents"]?.arrayValue)
            let ohMyPi = try XCTUnwrap(agents.compactMap(\.objectValue).first { agent in
                agent["models"]?.arrayValue?.contains { model in
                    model.objectValue?["agent_id"]?.stringValue == AgentProviderKind.ohMyPi.rawValue
                } == true
            })
            XCTAssertEqual(ohMyPi["name"]?.stringValue, "Oh My Pi")
            XCTAssertEqual(ohMyPi["available"]?.boolValue, true)
            let models = try XCTUnwrap(ohMyPi["models"]?.arrayValue).compactMap(\.objectValue)
            XCTAssertEqual(models.count, 1)
            XCTAssertEqual(models[0]["model_id"]?.stringValue, "ohMyPi:default")
            XCTAssertEqual(ohMyPi["default_model_id"]?.stringValue, "ohMyPi:default")
        #else
            throw XCTSkip("OMP qualification discovery is DEBUG-only")
        #endif
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "List Agents \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageListAgentsTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "list-agents-shape-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }
}
