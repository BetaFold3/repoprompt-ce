@testable import RepoPromptApp
import XCTest

final class MCPBootstrapConnectionHealthPolicyTests: XCTestCase {
    func testGatewayLinksReceiveDefaultKeepaliveWhenGlobalKeepaliveDisabled() {
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: "repoprompt-gateway",
                configuredSeconds: 0
            ),
            15
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedHealthMonitorSleepSecondsForTesting(
                clientName: "repoprompt-gateway",
                configuredSeconds: 0
            ),
            15
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: "remote:daaf74ea",
                configuredSeconds: 0
            ),
            15
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedHealthMonitorSleepSecondsForTesting(
                clientName: "remote:daaf74ea",
                configuredSeconds: 0
            ),
            15
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: "rpce-cli-debug",
                configuredSeconds: 0
            ),
            0
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedHealthMonitorSleepSecondsForTesting(
                clientName: "rpce-cli-debug",
                configuredSeconds: 0
            ),
            30
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: nil,
                configuredSeconds: 0
            ),
            0
        )
    }

    func testExplicitKeepaliveOverridesGatewayDefault() {
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: "remote:daaf74ea",
                configuredSeconds: 42
            ),
            42
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedHealthMonitorSleepSecondsForTesting(
                clientName: "remote:daaf74ea",
                configuredSeconds: 42
            ),
            30
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedKeepaliveSecondsForTesting(
                clientName: "rpce-cli-debug",
                configuredSeconds: 42
            ),
            42
        )
        XCTAssertEqual(
            BootstrapSocketConnectionManager.debugResolvedHealthMonitorSleepSecondsForTesting(
                clientName: "rpce-cli-debug",
                configuredSeconds: 10
            ),
            10
        )
    }
}
