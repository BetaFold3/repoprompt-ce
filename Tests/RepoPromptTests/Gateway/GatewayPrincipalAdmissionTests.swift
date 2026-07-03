@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class GatewayPrincipalAdmissionTests: XCTestCase {
        func testLaunchScopedCredentialMarksGatewayPrincipal() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principal = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: "launch-secret"
            )

            XCTAssertEqual(principal, .gateway)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        func testClientNameClaimAloneDoesNotMarkGatewayPrincipal() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principalFromMissingCredential = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: nil
            )
            XCTAssertEqual(principalFromMissingCredential, .standard)

            let forgedConnectionID = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: forgedConnectionID,
                clientName: "repoprompt-gateway",
                principal: .standard
            )

            let storedPrincipal = await manager.debugConnectionPrincipalForTesting(forgedConnectionID)
            let isGateway = await manager.isGatewayPrincipalConnection(forgedConnectionID)
            XCTAssertEqual(storedPrincipal, .standard)
            XCTAssertFalse(isGateway)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        func testInvalidGatewayCredentialIsRejectedByAdmissionDecision() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principal = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: "wrong-secret"
            )

            XCTAssertNil(principal)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        // MARK: - M4 connection-approval routing

        /// Pairing consent is the authorization event: a gateway-principal-carried
        /// `remote:<device8>` link auto-admits with no per-connection approval prompt,
        /// on connect and on reconnect alike.
        func testGatewayCarriedRemoteDeviceLinkAutoAdmitsWithoutPrompt() async {
            for _ in 0 ..< 2 { // connect, then reconnect
                let route = await ServerController.connectionApprovalRoute(
                    clientName: "remote:1a2b3c4d",
                    autoApproveAllClients: false,
                    isGatewayPrincipal: true,
                    isVerifiedBundledRepoPromptCLI: {
                        XCTFail("Gateway principal must not reach CLI verification")
                        return false
                    },
                    isAllowListed: {
                        XCTFail("Gateway principal must not consult the allow-list")
                        return false
                    }
                )
                XCTAssertEqual(route, .autoApproveGatewayPrincipal)
            }
        }

        func testRemoteDeviceNameWithoutGatewayPrincipalStillPrompts() async {
            let route = await ServerController.connectionApprovalRoute(
                clientName: "remote:1a2b3c4d",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { false }
            )
            XCTAssertEqual(route, .promptUser)
        }

        func testApprovalRouteOrderingContract() async {
            // Global auto-approve wins over everything.
            let globalRoute = await ServerController.connectionApprovalRoute(
                clientName: "remote:1a2b3c4d",
                autoApproveAllClients: true,
                isGatewayPrincipal: true,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { false }
            )
            XCTAssertEqual(globalRoute, .autoApproveAllClients)

            // RepoPrompt CLI names require executable verification and never use the allow-list.
            let unverifiedCLIRoute = await ServerController.connectionApprovalRoute(
                clientName: "RepoPrompt CLI",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: {
                    XCTFail("RepoPrompt CLI names must not consult the allow-list")
                    return true
                }
            )
            XCTAssertEqual(unverifiedCLIRoute, .promptUserUnverifiedRepoPromptCLI)

            let verifiedCLIRoute = await ServerController.connectionApprovalRoute(
                clientName: "RepoPrompt CLI",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { true },
                isAllowListed: { false }
            )
            XCTAssertEqual(verifiedCLIRoute, .autoApproveVerifiedRepoPromptCLI)

            // Allow-listed non-CLI clients auto-approve; unknown clients prompt.
            let allowListedRoute = await ServerController.connectionApprovalRoute(
                clientName: "some-agent",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { true }
            )
            XCTAssertEqual(allowListedRoute, .autoApproveAllowListed)
        }
    }
#endif
