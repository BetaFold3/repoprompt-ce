import Foundation
import XCTest

final class GatewayRemoteHostCatalogFixtureTests: XCTestCase {
    func testCapturedListAgentsFixtureHasClientCatalogShape() throws {
        let data = try Data(contentsOf: fixtureURL())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let taskLabels = try XCTUnwrap(object["task_labels"] as? [[String: Any]])
        let agents = try XCTUnwrap(object["agents"] as? [[String: Any]])

        XCTAssertFalse(taskLabels.isEmpty)
        XCTAssertFalse(agents.isEmpty)
        for label in taskLabels {
            XCTAssertNotNil(label["label"] as? String)
            XCTAssertNotNil(label["model_id"] as? String)
            XCTAssertNotNil(label["name"] as? String)
        }
        var agentWithModelID = false
        for agent in agents {
            XCTAssertNotNil(agent["name"] as? String)
            XCTAssertNotNil(agent["available"] as? Bool)
            XCTAssertNotNil(agent["capabilities"] as? [String])
            let models = try XCTUnwrap(agent["models"] as? [[String: Any]])
            if !models.isEmpty {
                let hasModelID = models.contains { ($0["model_id"] as? String)?.isEmpty == false }
                XCTAssertTrue(hasModelID, "Non-empty captured agent catalogs should expose model_id targets")
                agentWithModelID = agentWithModelID || hasModelID
            }
        }
        XCTAssertTrue(agentWithModelID, "Captured fixture should include at least one concrete model_id target")
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentMode/Fixtures/RemoteHostCatalog/agent_manage_list_agents_response.json")
    }
}
