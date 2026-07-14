import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemotePairingPayloadTests: XCTestCase {
    func testVerifiedPayloadPreservesStrictOriginAndApprovalContext() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let origin = try RemoteGatewayOrigin(string: "http://100.64.0.8:47391")

        let payload = try RemotePairingPayload(
            gatewayOrigin: origin,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            hostName: "Mac Studio",
            approvalContext: "fresh-context"
        )

        XCTAssertEqual(payload.gatewayOrigin, origin)
        XCTAssertEqual(payload.gatewayURL.absoluteString, "http://100.64.0.8:47391")
        XCTAssertEqual(payload.hostDisplayName, "Mac Studio")
        XCTAssertEqual(payload.approvalContext, "fresh-context")
    }

    func testFallsBackToFingerprintShortWhenHostNameMissing() throws {
        let payload = try RemoteHostTestSupport.pairingPayload(hostName: nil)
        XCTAssertEqual(payload.hostDisplayName, "Remote Host \(payload.fingerprintShort)")
    }

    func testRejectsFingerprintMismatch() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let otherHostSigner = P256.Signing.PrivateKey()

        XCTAssertThrowsError(try RemotePairingPayload(
            gatewayOrigin: RemoteGatewayOrigin(string: "http://100.64.0.8:47391"),
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: RemotePairingCrypto.fingerprint(for: otherHostSigner.publicKey),
            approvalContext: "context"
        )) { error in
            guard case .fingerprintMismatch = error as? RemotePairingPayloadError else {
                XCTFail("Expected fingerprint mismatch, got \(error)")
                return
            }
        }
    }

    func testRejectsInvalidKindFingerprintAndMissingContext() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let origin = try RemoteGatewayOrigin(string: "http://100.64.0.8:47391")
        let fingerprint = RemotePairingCrypto.fingerprint(for: hostSigner.publicKey)

        XCTAssertThrowsError(try RemotePairingPayload(
            kind: "other",
            gatewayOrigin: origin,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint,
            approvalContext: "context"
        )) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .invalidKind("other"))
        }

        XCTAssertThrowsError(try RemotePairingPayload(
            gatewayOrigin: origin,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint.uppercased(),
            approvalContext: "context"
        )) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .invalidHostFingerprint(fingerprint.uppercased()))
        }

        XCTAssertThrowsError(try RemotePairingPayload(
            gatewayOrigin: origin,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint,
            approvalContext: "  "
        )) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .missingApprovalContext)
        }
    }
}
