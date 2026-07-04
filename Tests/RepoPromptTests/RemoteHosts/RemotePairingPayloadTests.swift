import CryptoKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class RemotePairingPayloadTests: XCTestCase {
    func testParsesValidPayloadAndPreservesEditableGatewayURL() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let json = try RemoteHostTestSupport.pairingPayloadJSON(hostSigner: hostSigner, hostName: "Mac Studio")

        let payload = try RemotePairingPayload.parse(json)

        XCTAssertEqual(payload.kind, RemotePairingPayload.expectedKind)
        XCTAssertEqual(payload.windowID, 7)
        XCTAssertEqual(payload.hostFingerprint, RemotePairingCrypto.fingerprint(for: hostSigner.publicKey))
        XCTAssertEqual(payload.hostPublicKey, hostSigner.publicKey.rawRepresentation)
        XCTAssertEqual(payload.hostDisplayName, "Mac Studio")

        let edited = try payload.withGatewayURL(XCTUnwrap(URL(string: "https://studio.tailnet.ts.net:9876")))
        XCTAssertEqual(edited.gatewayURL.absoluteString, "https://studio.tailnet.ts.net:9876")
        XCTAssertEqual(edited.hostFingerprint, payload.hostFingerprint)
    }

    func testFallsBackToFingerprintShortWhenHostNameMissing() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let payload = try RemotePairingPayload.parse(
            RemoteHostTestSupport.pairingPayloadJSON(hostSigner: hostSigner, hostName: nil)
        )

        XCTAssertEqual(payload.hostDisplayName, "Remote Host \(payload.fingerprintShort)")
    }

    func testRejectsFingerprintMismatch() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let otherHostSigner = P256.Signing.PrivateKey()
        let object: [String: Any] = [
            "v": 1,
            "kind": "repoprompt_remote_pairing",
            "gateway_url": "https://studio.tailnet.example:8765",
            "host_public_key": hostSigner.publicKey.rawRepresentation.base64EncodedString(),
            "host_fingerprint": RemotePairingCrypto.fingerprint(for: otherHostSigner.publicKey)
        ]
        let json = try String(decoding: RemoteHostTestSupport.jsonData(object), as: UTF8.self)

        XCTAssertThrowsError(try RemotePairingPayload.parse(json)) { error in
            guard case .fingerprintMismatch = error as? RemotePairingPayloadError else {
                XCTFail("Expected fingerprint mismatch, got \(error)")
                return
            }
        }
    }

    func testRejectsInvalidKindAndNonCanonicalFingerprint() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let invalidKind: [String: Any] = [
            "v": 1,
            "kind": "other",
            "gateway_url": "https://studio.tailnet.example:8765",
            "host_public_key": hostSigner.publicKey.rawRepresentation.base64EncodedString(),
            "host_fingerprint": RemotePairingCrypto.fingerprint(for: hostSigner.publicKey)
        ]
        XCTAssertThrowsError(try RemotePairingPayload.parse(RemoteHostTestSupport.jsonData(invalidKind))) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .invalidKind("other"))
        }

        let upper = RemotePairingCrypto.fingerprint(for: hostSigner.publicKey).uppercased()
        let invalidFingerprint: [String: Any] = [
            "v": 1,
            "kind": "repoprompt_remote_pairing",
            "gateway_url": "https://studio.tailnet.example:8765",
            "host_public_key": hostSigner.publicKey.rawRepresentation.base64EncodedString(),
            "host_fingerprint": upper
        ]
        XCTAssertThrowsError(try RemotePairingPayload.parse(RemoteHostTestSupport.jsonData(invalidFingerprint))) { error in
            XCTAssertEqual(error as? RemotePairingPayloadError, .invalidHostFingerprint(upper))
        }
    }
}
