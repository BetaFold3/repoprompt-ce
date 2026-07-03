import Foundation
@testable import RepoPromptApp
import XCTest

/// M4 dashboard attribution: `remote:<device8>` connections render the paired
/// device's display name where available, without hiding the device ID.
final class GatewayRemoteDashboardNamingTests: XCTestCase {
    private func makeConnection(
        clientName: String,
        remoteDeviceDisplayName: String?
    ) -> MCPService.DashboardConnection {
        MCPService.DashboardConnection(
            id: UUID(),
            clientName: clientName,
            windowID: nil,
            transport: .filesystem,
            state: .ready,
            createdAt: Date(),
            lastToolCallAt: nil,
            totalToolCalls: 0,
            idleSeconds: nil,
            hasInFlightCalls: false,
            activeToolScope: nil,
            activeToolScopes: [],
            sessionKey: nil,
            remoteDeviceDisplayName: remoteDeviceDisplayName
        )
    }

    func testRemoteDeviceRendersDisplayNameWithDeviceID() {
        let connection = makeConnection(
            clientName: "remote:1a2b3c4d",
            remoteDeviceDisplayName: "Tuan's iPhone"
        )
        XCTAssertEqual(connection.displayClientName, "Tuan's iPhone (remote:1a2b3c4d)")
    }

    func testRemoteDeviceWithoutRegistryEntryFallsBackToClientName() {
        let connection = makeConnection(clientName: "remote:1a2b3c4d", remoteDeviceDisplayName: nil)
        XCTAssertEqual(connection.displayClientName, "remote:1a2b3c4d")

        let blankName = makeConnection(clientName: "remote:1a2b3c4d", remoteDeviceDisplayName: "")
        XCTAssertEqual(blankName.displayClientName, "remote:1a2b3c4d")

        let duplicateName = makeConnection(
            clientName: "remote:1a2b3c4d",
            remoteDeviceDisplayName: "remote:1a2b3c4d"
        )
        XCTAssertEqual(duplicateName.displayClientName, "remote:1a2b3c4d")
    }

    func testNonRemoteClientNamesAreUntouched() {
        let connection = makeConnection(clientName: "claude-code", remoteDeviceDisplayName: nil)
        XCTAssertEqual(connection.displayClientName, "claude-code")
    }

    func testDisplayNameResolutionOnlyConsultsRegistryForRemoteNames() {
        var lookedUp: [String] = []
        let resolved = MCPService.DashboardConnection.remoteDeviceDisplayName(
            forClientName: "remote:1a2b3c4d",
            lookup: { clientName in
                lookedUp.append(clientName)
                return "Tuan's iPhone"
            }
        )
        XCTAssertEqual(resolved, "Tuan's iPhone")
        XCTAssertEqual(lookedUp, ["remote:1a2b3c4d"])

        let nonRemote = MCPService.DashboardConnection.remoteDeviceDisplayName(
            forClientName: "claude-code",
            lookup: { _ in
                XCTFail("Non-remote client names must not hit the pairing registry")
                return nil
            }
        )
        XCTAssertNil(nonRemote)
    }
}
