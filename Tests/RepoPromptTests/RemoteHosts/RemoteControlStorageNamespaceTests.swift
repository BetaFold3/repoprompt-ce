@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteControlStorageNamespaceTests: XCTestCase {
    func testReleaseAndDebugTrustRuntimeAndKeyAccountsAreDisjoint() {
        let releaseRoot = RemoteControlStorageNamespace.rootURL(channel: .release)
        let debugRoot = RemoteControlStorageNamespace.rootURL(channel: .debug)

        XCTAssertNotEqual(releaseRoot, debugRoot)
        XCTAssertTrue(releaseRoot.path.hasSuffix("/RemoteControl/release"))
        XCTAssertTrue(debugRoot.path.hasSuffix("/RemoteControl/debug"))
        XCTAssertNotEqual(
            RemoteControlStorageNamespace.gatewayRuntimeRootURL(channel: .release),
            RemoteControlStorageNamespace.gatewayRuntimeRootURL(channel: .debug)
        )
        XCTAssertNotEqual(
            RemoteControlStorageNamespace.hostSigningKeyAccount(channel: .release),
            RemoteControlStorageNamespace.hostSigningKeyAccount(channel: .debug)
        )
        XCTAssertNotEqual(
            RemoteControlStorageNamespace.clientKeyAccountPrefix(channel: .release),
            RemoteControlStorageNamespace.clientKeyAccountPrefix(channel: .debug)
        )
    }

    func testClientKeyAccountUsesFullHostDigest() throws {
        let hostID = "sha256:" + String(repeating: "a", count: 64)
        let account = try RemoteClientKeyStore.account(forHostID: hostID)
        XCTAssertTrue(account.hasSuffix(String(repeating: "a", count: 64)))
        XCTAssertTrue(account.contains("-\(RemoteControlBuildIdentity.current.channel.storageNamespace)-"))
    }
}
