import CryptoKit
import Foundation
@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemotePairingProofCompatTests: XCTestCase {
    func testRemoteWireProofVerifiesUnderHostRemotePairingCrypto() throws {
        let deviceKey = P256.Signing.PrivateKey()
        let pairingID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let scopes: Set<String> = [
            RemoteScope.interactionsRespond.rawValue,
            RemoteScope.sessionsObserve.rawValue,
            RemoteScope.sessionsOperate.rawValue
        ]
        let wirePayload = try RemotePairingDeviceChallengeV1(
            pairingID: pairingID,
            challenge: "fixed-challenge",
            deviceID: RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation),
            displayName: "Client MacBook",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: scopes
        )
        let signature = try RemotePairingProof.signDeviceChallenge(wirePayload, deviceSigner: deviceKey)
        let hostPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: wirePayload.challenge,
            deviceID: wirePayload.deviceID,
            displayName: wirePayload.displayName,
            publicKeyRawRepresentation: wirePayload.publicKeyRawRepresentation,
            scopes: Set(scopes.compactMap(RemoteScope.init(rawValue:)))
        )

        XCTAssertEqual(wirePayload.canonicalPayload, RemotePairingCrypto.canonicalDeviceChallengePayload(hostPayload))
        XCTAssertNoThrow(try RemotePairingCrypto.verifyDeviceChallenge(payload: hostPayload, signature: signature))
    }
}
