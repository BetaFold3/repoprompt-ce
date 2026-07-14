import CryptoKit
import Foundation
import Security

struct BeginPairingResult: Codable, Equatable {
    let pairingID: UUID
    let challenge: String
    let hostPublicKey: Data
    let hostFingerprint: String
    let expiresAt: Date
}

struct RemoteConnectionTicket: Codable, Equatable {
    let ticketID: UUID
    let deviceID: String
    let scopes: Set<RemoteScope>
    let issuedAt: Date
    let expiresAt: Date
    let hostFingerprint: String
    var hostSignature: Data
}

struct RemotePairingChallenge: Identifiable, Equatable {
    let pairingID: UUID
    let challenge: String
    let createdAt: Date
    let expiresAt: Date
    let approvalContext: RemotePairingApprovalContext?
    var consumedAt: Date?

    var id: UUID {
        pairingID
    }
}

struct RemotePairingDeviceProofPayload: Equatable {
    let pairingID: UUID
    let challenge: String
    let deviceID: String
    let displayName: String
    let publicKeyRawRepresentation: Data
    let scopes: Set<RemoteScope>
}

enum RemotePairingCryptoError: Error, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case signatureVerificationFailed
    case invalidTicketLifetime
    case expiredTicket
    case expiredChallenge
    case challengeAlreadyUsed
    case challengeNotFound
    case randomGenerationFailed(OSStatus)
}

enum RemotePairingCrypto {
    static let maximumPairingChallengeTTL: TimeInterval = 60
    static let maximumTicketTTL: TimeInterval = 60

    static func hostPrivateKey(rawRepresentation: Data) throws -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw RemotePairingCryptoError.invalidPrivateKey
        }
    }

    static func publicKey(rawRepresentation: Data) throws -> P256.Signing.PublicKey {
        do {
            return try P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
        } catch {
            throw RemotePairingCryptoError.invalidPublicKey
        }
    }

    static func fingerprint(for publicKey: P256.Signing.PublicKey) -> String {
        fingerprint(forRawPublicKey: publicKey.rawRepresentation) ?? "sha256:invalid"
    }

    static func fingerprint(forRawPublicKey rawRepresentation: Data) -> String? {
        guard (try? P256.Signing.PublicKey(rawRepresentation: rawRepresentation)) != nil else {
            return nil
        }
        let hex = SHA256.hash(data: rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }

    static func isValidFingerprint(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256" else { return false }
        let digest = parts[1]
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    static func deviceID(forRawPublicKey rawRepresentation: Data) throws -> String {
        guard let fingerprint = fingerprint(forRawPublicKey: rawRepresentation),
              let digest = fingerprint.split(separator: ":").last
        else {
            throw RemotePairingCryptoError.invalidPublicKey
        }
        return "remote:\(digest.prefix(8))"
    }

    static func randomChallenge(byteCount: Int = 32) throws -> String {
        precondition(byteCount > 0)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemotePairingCryptoError.randomGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func signTicket(
        ticketID: UUID = UUID(),
        deviceID: String,
        scopes: Set<RemoteScope>,
        issuedAt: Date,
        expiresAt: Date,
        hostFingerprint: String,
        hostSigner: P256.Signing.PrivateKey
    ) throws -> RemoteConnectionTicket {
        guard expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= maximumTicketTTL
        else {
            throw RemotePairingCryptoError.invalidTicketLifetime
        }
        var ticket = RemoteConnectionTicket(
            ticketID: ticketID,
            deviceID: deviceID,
            scopes: scopes,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            hostFingerprint: hostFingerprint,
            hostSignature: Data()
        )
        ticket.hostSignature = try hostSigner.signature(for: canonicalTicketPayload(ticket)).rawRepresentation
        return ticket
    }

    static func verifyTicket(
        _ ticket: RemoteConnectionTicket,
        hostPublicKey: P256.Signing.PublicKey,
        now: Date = Date()
    ) throws {
        guard ticket.expiresAt > now else {
            throw RemotePairingCryptoError.expiredTicket
        }
        guard ticket.expiresAt > ticket.issuedAt,
              ticket.expiresAt.timeIntervalSince(ticket.issuedAt) <= maximumTicketTTL
        else {
            throw RemotePairingCryptoError.invalidTicketLifetime
        }
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: ticket.hostSignature)
        } catch {
            throw RemotePairingCryptoError.invalidSignature
        }
        guard hostPublicKey.isValidSignature(signature, for: canonicalTicketPayload(ticket)) else {
            throw RemotePairingCryptoError.signatureVerificationFailed
        }
    }

    static func signDeviceChallenge(
        payload: RemotePairingDeviceProofPayload,
        deviceSigner: P256.Signing.PrivateKey
    ) throws -> Data {
        try deviceSigner.signature(for: canonicalDeviceChallengePayload(payload)).rawRepresentation
    }

    static func verifyDeviceChallenge(
        payload: RemotePairingDeviceProofPayload,
        signature signatureRawRepresentation: Data
    ) throws {
        let publicKey = try publicKey(rawRepresentation: payload.publicKeyRawRepresentation)
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureRawRepresentation)
        } catch {
            throw RemotePairingCryptoError.invalidSignature
        }
        guard publicKey.isValidSignature(signature, for: canonicalDeviceChallengePayload(payload)) else {
            throw RemotePairingCryptoError.signatureVerificationFailed
        }
    }

    static func canonicalTicketPayload(_ ticket: RemoteConnectionTicket) -> Data {
        canonicalLines([
            "RepoPromptRemoteConnectionTicketV1",
            ticket.ticketID.uuidString.lowercased(),
            ticket.deviceID,
            ticket.scopes.map(\.rawValue).sorted().joined(separator: ","),
            String(canonicalMilliseconds(ticket.issuedAt)),
            String(canonicalMilliseconds(ticket.expiresAt)),
            ticket.hostFingerprint
        ])
    }

    /// Byte-for-byte mirror of `RemotePairingProof.canonicalDeviceChallengePayload`
    /// in `RepoPromptRemoteWire`. Keep both functions in lockstep when the v1
    /// pairing proof contract changes.
    static func canonicalDeviceChallengePayload(_ payload: RemotePairingDeviceProofPayload) -> Data {
        canonicalLines([
            "RepoPromptRemotePairingDeviceChallengeV1",
            payload.pairingID.uuidString.lowercased(),
            payload.challenge,
            payload.deviceID,
            payload.displayName,
            payload.publicKeyRawRepresentation.base64EncodedString(),
            payload.scopes.map(\.rawValue).sorted().joined(separator: ",")
        ])
    }

    /// Canonical epoch-millisecond conversion used by every signed payload. Internal so
    /// ticket serialization can expose the exact signed values (`issued_at_ms` /
    /// `expires_at_ms`) without a lossy ISO-8601 round-trip.
    static func canonicalMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func canonicalLines(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

actor RemotePairingChallengeStore {
    static let shared = RemotePairingChallengeStore()

    typealias ChallengeGenerator = @Sendable () throws -> String

    private var challenges: [UUID: RemotePairingChallenge] = [:]
    private let challengeGenerator: ChallengeGenerator

    init(challengeGenerator: @escaping ChallengeGenerator = { try RemotePairingCrypto.randomChallenge() }) {
        self.challengeGenerator = challengeGenerator
    }

    func issue(
        now: Date = Date(),
        ttl: TimeInterval = RemotePairingCrypto.maximumPairingChallengeTTL,
        approvalContext: RemotePairingApprovalContext? = nil,
        expiresAtLimit: Date? = nil
    ) throws -> RemotePairingChallenge {
        prune(now: now)
        let resolvedTTL = min(max(ttl, 1), RemotePairingCrypto.maximumPairingChallengeTTL)
        let requestedExpiration = now.addingTimeInterval(resolvedTTL)
        let expiresAt = expiresAtLimit.map { min(requestedExpiration, $0) } ?? requestedExpiration
        guard expiresAt > now else { throw RemotePairingCryptoError.expiredChallenge }
        let challenge = try RemotePairingChallenge(
            pairingID: UUID(),
            challenge: challengeGenerator(),
            createdAt: now,
            expiresAt: expiresAt,
            approvalContext: approvalContext,
            consumedAt: nil
        )
        challenges[challenge.pairingID] = challenge
        return challenge
    }

    func consume(pairingID: UUID, now: Date = Date()) throws -> RemotePairingChallenge {
        guard var challenge = challenges[pairingID] else {
            throw RemotePairingCryptoError.challengeNotFound
        }
        guard challenge.consumedAt == nil else {
            throw RemotePairingCryptoError.challengeAlreadyUsed
        }
        guard challenge.expiresAt > now else {
            challenges[pairingID] = nil
            prune(now: now)
            throw RemotePairingCryptoError.expiredChallenge
        }
        prune(now: now)
        let unconsumed = challenge
        challenge.consumedAt = now
        challenges[pairingID] = challenge
        return unconsumed
    }

    func challenge(pairingID: UUID) -> RemotePairingChallenge? {
        challenges[pairingID]
    }

    func resetForTesting() {
        challenges.removeAll()
    }

    private func prune(now: Date) {
        challenges = challenges.filter { _, challenge in
            challenge.expiresAt > now
        }
    }
}
