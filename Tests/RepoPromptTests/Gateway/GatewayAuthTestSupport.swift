import CryptoKit
import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire

/// Shared helpers for M4 gateway ticket/signature/scope tests.
enum GatewayAuthTestSupport {
    struct TestDeviceIdentity {
        let signer: P256.Signing.PrivateKey
        let deviceID: String

        var publicKeyRaw: Data {
            signer.publicKey.rawRepresentation
        }
    }

    static func makeDevice(deviceID: String = "remote:abcd1234") -> TestDeviceIdentity {
        TestDeviceIdentity(signer: P256.Signing.PrivateKey(), deviceID: deviceID)
    }

    static func fingerprint(_ key: P256.Signing.PublicKey) -> String {
        let hex = SHA256.hash(data: key.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }

    static func trustSnapshot(
        hostSigner: P256.Signing.PrivateKey,
        devices: [(identity: TestDeviceIdentity, revoked: Bool)],
        counterFloor: UInt64 = 0
    ) -> GatewayTrustSnapshot {
        var map: [String: GatewayTrustedDevice] = [:]
        for (identity, revoked) in devices {
            map[identity.deviceID] = GatewayTrustedDevice(
                deviceID: identity.deviceID,
                displayName: "Device \(identity.deviceID)",
                publicKeyRawRepresentation: identity.publicKeyRaw,
                isRevoked: revoked,
                counterFloor: counterFloor
            )
        }
        return GatewayTrustSnapshot(
            hostPublicKeyRawRepresentation: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint(hostSigner.publicKey),
            devices: map
        )
    }

    static func mintTicket(
        hostSigner: P256.Signing.PrivateKey,
        deviceID: String,
        scopes: Set<String>,
        issuedAt: Date = Date(),
        ttlMs: Int64 = 30000,
        ticketID: UUID = UUID()
    ) throws -> RemoteTicket {
        let issuedAtMs = Int64((issuedAt.timeIntervalSince1970 * 1000).rounded(.down))
        let unsigned = RemoteTicket(
            ticketID: ticketID,
            deviceID: deviceID,
            scopes: scopes,
            issuedAtMs: issuedAtMs,
            expiresAtMs: issuedAtMs + ttlMs,
            hostFingerprint: fingerprint(hostSigner.publicKey),
            hostSignature: Data()
        )
        let signature = try hostSigner.signature(for: unsigned.canonicalPayload).rawRepresentation
        return RemoteTicket(
            ticketID: unsigned.ticketID,
            deviceID: unsigned.deviceID,
            scopes: unsigned.scopes,
            issuedAtMs: unsigned.issuedAtMs,
            expiresAtMs: unsigned.expiresAtMs,
            hostFingerprint: unsigned.hostFingerprint,
            hostSignature: signature
        )
    }

    static func frameObject(
        type: String,
        requestID: String? = nil,
        sessionID: String? = nil,
        payload: JSONValue? = nil
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "v": .int(RemoteWireProtocol.version),
            "type": .string(type)
        ]
        if let requestID { object["request_id"] = .string(requestID) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        if let payload { object["payload"] = payload }
        return object
    }

    static func helloObject(ticketJSON: JSONValue) -> [String: JSONValue] {
        frameObject(type: "hello", payload: .object(["ticket": ticketJSON]))
    }

    /// Signs the frame object with the device key over the canonical M4 signing payload
    /// and returns the serialized frame bytes as sent on the wire.
    static func signedFrameData(
        object baseObject: [String: JSONValue],
        ticketID: UUID,
        deviceID: String,
        counter: UInt64,
        deviceKey: P256.Signing.PrivateKey,
        algorithm: String = RemoteFrameSignature.requiredAlgorithm,
        tamperAfterSigning: ((inout [String: JSONValue]) -> Void)? = nil
    ) throws -> Data {
        var object = baseObject
        let frameHashHex = try RemoteWireProtocol.sha256Hex(
            of: RemoteWireProtocol.canonicalData(for: .object(object))
        )
        let signingPayload = RemoteWireProtocol.frameSigningPayload(
            ticketID: ticketID,
            deviceID: deviceID,
            counter: counter,
            frameHashHex: frameHashHex
        )
        let signature = try deviceKey.signature(for: signingPayload).rawRepresentation
        object["sig"] = .object([
            "ticket_id": .string(ticketID.uuidString.lowercased()),
            "device_id": .string(deviceID),
            "counter": .int(Int(counter)),
            "algorithm": .string(algorithm),
            "signature": .string(signature.base64EncodedString())
        ])
        tamperAfterSigning?(&object)
        return try RemoteWireProtocol.canonicalData(for: .object(object))
    }

    static func unsignedFrameData(object: [String: JSONValue]) throws -> Data {
        try RemoteWireProtocol.canonicalData(for: .object(object))
    }

    static func decodeFrame(_ data: Data) throws -> RemoteClientFrame {
        try RemoteWireProtocol.decodeClientFrame(from: data)
    }

    static func makeUsedTicketStore(root: URL) throws -> UsedTicketStore {
        try UsedTicketStore(
            fileURL: root
                .appendingPathComponent("auth", isDirectory: true)
                .appendingPathComponent("used-tickets-v1.jsonl")
        )
    }
}
