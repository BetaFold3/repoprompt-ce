import CryptoKit
import Foundation
import RepoPromptRemoteWire
import XCTest

final class RemoteDiscoveryWireTests: XCTestCase {
    func testBuildChannelsAndStrictOriginsAreIsolated() throws {
        XCTAssertEqual(RemoteControlBuildChannel.release.fixedPort, 47391)
        XCTAssertEqual(RemoteControlBuildChannel.debug.fixedPort, 47392)
        XCTAssertEqual(RemoteControlBuildChannel.release.urlScheme, "repoprompt-ce")
        XCTAssertEqual(RemoteControlBuildChannel.debug.urlScheme, "repoprompt-ce-debug")

        let release = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .release)
        XCTAssertEqual(release.string, "http://100.64.0.8:47391")
        XCTAssertNoThrow(try release.validateDirectTailscale(channel: .release))
        XCTAssertThrowsError(try release.validateDirectTailscale(channel: .debug))
        XCTAssertThrowsError(try RemoteGatewayOrigin(string: "http://user@100.64.0.8:47391"))
        XCTAssertThrowsError(try RemoteGatewayOrigin(string: "http://100.64.0.8:47391/path"))
        XCTAssertThrowsError(try RemoteGatewayOrigin(string: "http://100.64.0.8"))
    }

    func testSignedDiscoveryVerifiesAndRejectsWrongOriginAndSignature() throws {
        let signer = P256.Signing.PrivateKey()
        let request = try RemoteDiscoveryRequest(
            nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            channel: .release
        )
        let origin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .release)
        let response = try RemoteDiscoveryResponse(
            request: request,
            origin: origin,
            hostPublicKey: signer.publicKey.rawRepresentation,
            hostFingerprint: "sha256:" + RemoteWireProtocol.sha256Hex(of: signer.publicKey.rawRepresentation),
            hostName: "Studio",
            bundleID: "com.pvncher.repoprompt.ce",
            marketingVersion: "1.0",
            buildVersion: "1",
            approvalContext: "approval-context",
            issuedAtMs: 1_000_000,
            expiresAtMs: 1_060_000,
            hostSigner: signer
        )

        XCTAssertNoThrow(try RemoteDiscoveryVerifier.verify(
            response,
            request: request,
            expectedOrigin: origin,
            nowMs: 1_030_000
        ))
        let wrongOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.9", channel: .release)
        XCTAssertThrowsError(try RemoteDiscoveryVerifier.verify(
            response,
            request: request,
            expectedOrigin: wrongOrigin,
            nowMs: 1_030_000
        )) { XCTAssertEqual($0 as? RemoteDiscoveryError, .originMismatch) }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let tampered = try JSONDecoder().decode(
            RemoteDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try RemoteDiscoveryVerifier.verify(
            tampered,
            request: request,
            expectedOrigin: origin,
            nowMs: 1_030_000
        )) { XCTAssertEqual($0 as? RemoteDiscoveryError, .invalidSignature) }
    }
}
