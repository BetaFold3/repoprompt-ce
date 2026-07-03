import CryptoKit
import Foundation

/// App-minted one-time remote connection ticket.
///
/// The canonical signing payload mirrors the app's `RemotePairingCrypto.canonicalTicketPayload`
/// exactly; dates travel as canonical epoch milliseconds so signature verification never
/// depends on floating-point date round-trips.
public struct RemoteTicket: Equatable, Sendable {
    public static let canonicalContext = "RepoPromptRemoteConnectionTicketV1"
    public static let maximumTTLMilliseconds: Int64 = 60000

    public let ticketID: UUID
    public let deviceID: String
    public let scopes: Set<String>
    public let issuedAtMs: Int64
    public let expiresAtMs: Int64
    public let hostFingerprint: String
    public let hostSignature: Data

    public init(
        ticketID: UUID,
        deviceID: String,
        scopes: Set<String>,
        issuedAtMs: Int64,
        expiresAtMs: Int64,
        hostFingerprint: String,
        hostSignature: Data
    ) {
        self.ticketID = ticketID
        self.deviceID = deviceID
        self.scopes = scopes
        self.issuedAtMs = issuedAtMs
        self.expiresAtMs = expiresAtMs
        self.hostFingerprint = hostFingerprint
        self.hostSignature = hostSignature
    }

    public static func parse(from value: JSONValue) throws -> RemoteTicket {
        guard let object = value.objectValue,
              let ticketIDRaw = object["ticket_id"]?.stringValue,
              let ticketID = UUID(uuidString: ticketIDRaw),
              let deviceID = object["device_id"]?.stringValue, !deviceID.isEmpty,
              let scopeValues = object["scopes"]?.arrayValue,
              let hostFingerprint = object["host_fingerprint"]?.stringValue,
              let signatureRaw = object["host_signature"]?.stringValue,
              let hostSignature = Data(base64Encoded: signatureRaw)
        else {
            throw RemoteTicketError.invalidTicket("Missing required ticket fields.")
        }
        let scopes = Set(scopeValues.compactMap(\.stringValue))
        guard scopes.count == scopeValues.count, !scopes.isEmpty else {
            throw RemoteTicketError.invalidTicket("Ticket scopes must be non-empty strings.")
        }
        guard let issuedAtMs = milliseconds(object, msKey: "issued_at_ms", isoKey: "issued_at"),
              let expiresAtMs = milliseconds(object, msKey: "expires_at_ms", isoKey: "expires_at")
        else {
            throw RemoteTicketError.invalidTicket("Missing ticket issued/expiry timestamps.")
        }
        return RemoteTicket(
            ticketID: ticketID,
            deviceID: deviceID,
            scopes: scopes,
            issuedAtMs: issuedAtMs,
            expiresAtMs: expiresAtMs,
            hostFingerprint: hostFingerprint,
            hostSignature: hostSignature
        )
    }

    /// Mirrors `RemotePairingCrypto.canonicalTicketPayload` byte-for-byte.
    public var canonicalPayload: Data {
        let lines = [
            Self.canonicalContext,
            ticketID.uuidString.lowercased(),
            deviceID,
            scopes.sorted().joined(separator: ","),
            String(issuedAtMs),
            String(expiresAtMs),
            hostFingerprint
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public var jsonValue: JSONValue {
        .object([
            "ticket_id": .string(ticketID.uuidString.lowercased()),
            "device_id": .string(deviceID),
            "scopes": .array(scopes.sorted().map(JSONValue.string)),
            "issued_at_ms": .int(Int(issuedAtMs)),
            "expires_at_ms": .int(Int(expiresAtMs)),
            "host_fingerprint": .string(hostFingerprint),
            "host_signature": .string(hostSignature.base64EncodedString())
        ])
    }

    /// Verifies the host signature, lifetime, expiry, and host-key fingerprint pin.
    ///
    /// The device ID and scopes are signed as part of `canonicalPayload`; callers that
    /// require a specific device or scope set should compare those fields after this
    /// cryptographic check succeeds.
    public func verify(hostPublicKeyRaw: Data, nowMs: Int64) throws {
        guard expiresAtMs > nowMs else {
            throw RemoteTicketError.ticketExpired
        }
        guard expiresAtMs > issuedAtMs,
              expiresAtMs - issuedAtMs <= Self.maximumTTLMilliseconds
        else {
            throw RemoteTicketError.invalidTicketLifetime
        }

        let hostPublicKey: P256.Signing.PublicKey
        do {
            hostPublicKey = try P256.Signing.PublicKey(rawRepresentation: hostPublicKeyRaw)
        } catch {
            throw RemoteTicketError.invalidHostPublicKey
        }

        let expectedFingerprint = Self.fingerprint(forRawPublicKey: hostPublicKey.rawRepresentation)
        guard hostFingerprint == expectedFingerprint else {
            throw RemoteTicketError.hostFingerprintMismatch
        }

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: hostSignature)
        } catch {
            throw RemoteTicketError.invalidTicketSignature
        }
        guard hostPublicKey.isValidSignature(signature, for: canonicalPayload) else {
            throw RemoteTicketError.invalidTicketSignature
        }
    }

    private static func milliseconds(_ object: [String: JSONValue], msKey: String, isoKey: String) -> Int64? {
        if let ms = object[msKey]?.intValue {
            return Int64(ms)
        }
        guard let iso = object[isoKey]?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: iso)
        }()
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func fingerprint(forRawPublicKey rawRepresentation: Data) -> String {
        let hex = SHA256.hash(data: rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }
}

public enum RemoteTicketError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTicket(String)
    case invalidHostPublicKey
    case ticketExpired
    case invalidTicketLifetime
    case invalidTicketSignature
    case hostFingerprintMismatch

    public var description: String {
        switch self {
        case let .invalidTicket(message):
            "Invalid remote connection ticket: \(message)"
        case .invalidHostPublicKey:
            "Host public key is invalid."
        case .ticketExpired:
            "The remote connection ticket has expired."
        case .invalidTicketLifetime:
            "The remote connection ticket lifetime is invalid (must be positive and at most 60s)."
        case .invalidTicketSignature:
            "The remote connection ticket host signature is invalid."
        case .hostFingerprintMismatch:
            "The remote connection ticket host fingerprint does not match the pinned host key."
        }
    }
}
