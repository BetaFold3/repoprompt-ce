import CryptoKit
import Foundation

/// Canonical v1 device-challenge payload for the pairing proof.
public struct RemotePairingDeviceChallengeV1: Equatable, Sendable {
    public let pairingID: UUID
    public let challenge: String
    public let deviceID: String
    public let displayName: String
    public let publicKeyRawRepresentation: Data
    public let scopes: Set<String>

    public init(
        pairingID: UUID,
        challenge: String,
        deviceID: String,
        displayName: String,
        publicKeyRawRepresentation: Data,
        scopes: Set<String>
    ) {
        self.pairingID = pairingID
        self.challenge = challenge
        self.deviceID = deviceID
        self.displayName = displayName
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
        self.scopes = scopes
    }

    public var canonicalPayload: Data {
        RemotePairingProof.canonicalDeviceChallengePayload(self)
    }
}

public enum RemotePairingProof {
    public static let deviceChallengeContext = "RepoPromptRemotePairingDeviceChallengeV1"

    /// Byte-for-byte mirror of the host app's
    /// `RemotePairingCrypto.canonicalDeviceChallengePayload`. Keep both functions
    /// in lockstep when the v1 pairing proof contract changes.
    public static func canonicalDeviceChallengePayload(_ payload: RemotePairingDeviceChallengeV1) -> Data {
        canonicalLines([
            deviceChallengeContext,
            payload.pairingID.uuidString.lowercased(),
            payload.challenge,
            payload.deviceID,
            payload.displayName,
            payload.publicKeyRawRepresentation.base64EncodedString(),
            payload.scopes.sorted().joined(separator: ",")
        ])
    }

    public static func signDeviceChallenge(
        _ payload: RemotePairingDeviceChallengeV1,
        deviceSigner: P256.Signing.PrivateKey
    ) throws -> Data {
        try deviceSigner.signature(for: canonicalDeviceChallengePayload(payload)).rawRepresentation
    }

    public static func verifyDeviceChallenge(
        _ payload: RemotePairingDeviceChallengeV1,
        signature signatureRawRepresentation: Data
    ) throws -> Bool {
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: payload.publicKeyRawRepresentation)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureRawRepresentation)
        return publicKey.isValidSignature(signature, for: canonicalDeviceChallengePayload(payload))
    }

    private static func canonicalLines(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
