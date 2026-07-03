import Foundation
@testable import RepoPromptApp
import XCTest

/// Plan §6.5: `remote:<device8>` client-identity namespace with strict
/// per-device policy isolation.
final class MCPClientIdentityTests: XCTestCase {
    // MARK: - remoteDeviceID(from:)

    func testRemoteDeviceIDExtraction() {
        XCTAssertEqual(MCPClientIdentity.remoteDeviceID(from: "remote:aaaa1111"), "aaaa1111")
        XCTAssertEqual(MCPClientIdentity.remoteDeviceID(from: "  Remote:AAAA1111  "), "aaaa1111", "Normalization trims and lowercases")
        XCTAssertNil(MCPClientIdentity.remoteDeviceID(from: "remote:"), "Empty device is not a device identity")
        XCTAssertNil(MCPClientIdentity.remoteDeviceID(from: "remote:*"), "The wildcard is not a device identity")
        XCTAssertNil(MCPClientIdentity.remoteDeviceID(from: "claude-code"))
        XCTAssertNil(MCPClientIdentity.remoteDeviceID(from: nil))
    }

    // MARK: - isRemoteClient(_:)

    func testIsRemoteClient() {
        XCTAssertTrue(MCPClientIdentity.isRemoteClient("remote:aaaa1111"))
        XCTAssertTrue(MCPClientIdentity.isRemoteClient("remote:*"), "The explicit wildcard lives in the remote namespace")
        XCTAssertFalse(MCPClientIdentity.isRemoteClient("remote:"), "Bare prefix is not a remote identity")
        XCTAssertFalse(MCPClientIdentity.isRemoteClient("claude-code"))
        XCTAssertFalse(MCPClientIdentity.isRemoteClient("remotely-interesting"))
        XCTAssertFalse(MCPClientIdentity.isRemoteClient(nil))
    }

    // MARK: - No family widening for remote identities

    func testRemoteIdentitiesHaveNoCanonicalFamily() {
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("remote:aaaa1111"))
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("remote:*"))
        XCTAssertEqual(
            MCPClientIdentity.storageKey("remote:aaaa1111"),
            "remote:aaaa1111",
            "Remote identities keep their exact namespaced key"
        )
    }

    // MARK: - matches(_:_:) per-device isolation

    func testPerDeviceIsolationBetweenRemoteIdentities() {
        XCTAssertTrue(MCPClientIdentity.matches("remote:aaaa1111", "remote:aaaa1111"))
        XCTAssertFalse(
            MCPClientIdentity.matches("remote:aaaa1111", "remote:bbbb2222"),
            "A policy for one device must never approve another device"
        )
        XCTAssertFalse(MCPClientIdentity.matches("remote:aaaa1111", "claude-code"))
        XCTAssertFalse(MCPClientIdentity.matches("claude-code", "remote:aaaa1111"))
    }

    func testExplicitAllRemoteWildcardMatchesOnlyRemoteIdentities() {
        XCTAssertTrue(MCPClientIdentity.matches("remote:*", "remote:aaaa1111"))
        XCTAssertTrue(MCPClientIdentity.matches("remote:aaaa1111", "remote:*"), "Wildcard matching is symmetric")
        XCTAssertTrue(MCPClientIdentity.matches("remote:*", "remote:*"))
        XCTAssertFalse(MCPClientIdentity.matches("remote:*", "claude-code"))
        XCTAssertFalse(MCPClientIdentity.matches("remote:*", "repoprompt-cli"))
        XCTAssertFalse(MCPClientIdentity.matches("remote:*", nil))
    }

    func testExistingFamilyMatchingIsUnaffectedByRemoteNamespace() {
        XCTAssertTrue(MCPClientIdentity.matches("Claude Code", "claude-code"))
        XCTAssertTrue(MCPClientIdentity.matches("codex-mcp-client", "Codex MCP Client v2"))
        XCTAssertFalse(MCPClientIdentity.matches("Claude Code", "codex-mcp-client"))
    }

    // MARK: - Workspace approval policy isolation (plan §6.5)

    func testWorkspaceApprovalPoliciesStayIsolatedPerDevice() {
        var settings = WorkspaceApprovalSettings()
        settings.clientPolicies["remote:aaaa1111"] = WorkspaceApprovalClientPolicy(
            clientID: "remote:aaaa1111",
            allowedOperations: [.createWorkspace]
        )

        XCTAssertTrue(settings.shouldAutoApprove(operation: .createWorkspace, clientID: "remote:aaaa1111"))
        XCTAssertFalse(
            settings.shouldAutoApprove(operation: .createWorkspace, clientID: "remote:bbbb2222"),
            "remote:aaaa1111 policy must not auto-approve remote:bbbb2222"
        )
        XCTAssertFalse(settings.shouldAutoApprove(operation: .createWorkspace, clientID: "claude-code"))
    }

    func testAllRemotePolicyRequiresExplicitWildcard() {
        var settings = WorkspaceApprovalSettings()
        settings.clientPolicies["remote:*"] = WorkspaceApprovalClientPolicy(
            clientID: "remote:*",
            allowedOperations: [.createWorkspace]
        )

        XCTAssertTrue(settings.shouldAutoApprove(operation: .createWorkspace, clientID: "remote:aaaa1111"))
        XCTAssertTrue(settings.shouldAutoApprove(operation: .createWorkspace, clientID: "remote:bbbb2222"))
        XCTAssertFalse(
            settings.shouldAutoApprove(operation: .createWorkspace, clientID: "claude-code"),
            "The remote wildcard must not leak outside the remote namespace"
        )
    }
}
