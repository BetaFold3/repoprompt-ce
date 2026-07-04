@testable import RepoPromptApp
import XCTest

final class RemoteHostCatalogTests: XCTestCase {
    func testCapturedListAgentsFixtureDecodesRemoteCatalog() throws {
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(contentsOf: fixtureURL()))

        XCTAssertFalse(catalog.isDegraded)
        XCTAssertGreaterThan(catalog.agents.count, 1)
        XCTAssertGreaterThan(catalog.taskLabels.count, 0)

        let codexAgent = try XCTUnwrap(catalog.agents.first { $0.name == "Codex CLI" })
        XCTAssertTrue(codexAgent.available)
        XCTAssertEqual(codexAgent.defaultModelID, "codexExec:default")
        XCTAssertTrue(codexAgent.capabilities.contains("agent_conversation_send"))

        let codexLow = try XCTUnwrap(codexAgent.models.first { $0.modelID == "codexExec:gpt-5.5-low" })
        XCTAssertEqual(codexLow.name, "Codex CLI GPT-5.5 Low")
        XCTAssertEqual(codexLow.reasoningEffort, "low")
        XCTAssertEqual(catalog.displayName(forModelID: codexLow.modelID), codexLow.name)
        XCTAssertEqual(catalog.reasoningEffort(forModelID: codexLow.modelID), "low")
        XCTAssertEqual(RemoteHostAgentCatalog.agentKind(forModelID: codexLow.modelID), .codexExec)

        let exploreLabel = try XCTUnwrap(catalog.taskLabels.first { $0.label == "explore" })
        XCTAssertEqual(exploreLabel.modelID, "codexExec:gpt-5.5-medium")
        XCTAssertEqual(catalog.displayName(forModelID: exploreLabel.modelID), "Codex CLI GPT-5.5 Medium")
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart("  \(exploreLabel.modelID)  "), exploreLabel.modelID)
    }

    func testDegradedCatalogUsesHostDefaultAndOmitsStartModelID() {
        let degraded = RemoteHostAgentCatalog.degraded

        XCTAssertTrue(degraded.isDegraded)
        XCTAssertEqual(degraded.agents, [.hostDefault])
        XCTAssertTrue(degraded.selectableAgents.isEmpty)
        XCTAssertEqual(degraded.displayName(forModelID: nil), RemoteHostAgentCatalog.hostDefaultDisplayName)
        XCTAssertEqual(
            degraded.displayName(forModelID: RemoteHostAgentCatalog.hostDefaultModelID),
            RemoteHostAgentCatalog.hostDefaultDisplayName
        )
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(nil))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(""))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("  "))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(RemoteHostAgentCatalog.hostDefaultModelID))
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart(" codexExec:gpt-5.5-low "), "codexExec:gpt-5.5-low")
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentMode/Fixtures/RemoteHostCatalog/agent_manage_list_agents_response.json")
    }
}
