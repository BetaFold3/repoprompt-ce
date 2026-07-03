import CryptoKit
import Foundation
import Logging

typealias PushSender =
    P256.Signing.PrivateKey

// MARK: - Wake payload

/// Identifier-only Web Push wake payload (M5 hard security rule).
///
/// The encoded payload contains exactly `{v, kind, session_id, interaction_id?}`.
/// No prompt text, transcript text, file path, workspace path, model name, or
/// approval context is allowed; all state is fetched after wake via WS catch-up.
/// `WebPushPayloadTests` fails if additional fields are introduced.
struct WebPushWakePayload: Equatable {
    static let version = 1

    enum Kind: String {
        case waitingForInput = "waiting_for_input"
        case sessionTerminal = "session_terminal"
    }

    let kind: Kind
    let sessionID: String
    let interactionID: String?

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "v": .int(Self.version),
            "kind": .string(kind.rawValue),
            "session_id": .string(sessionID)
        ]
        if let interactionID {
            object["interaction_id"] = .string(interactionID)
        }
        return .object(object)
    }

    func encoded() throws -> Data {
        try RemoteWireProtocol.canonicalData(for: jsonValue)
    }
}

// MARK: - Seams

/// Push seam used by `SessionWatchManager`: wake-only semantics for devices that
/// are currently disconnected from the gateway WebSocket.
protocol RemotePushNotifying: Sendable {
    func isPushEligible(deviceID: String) async -> Bool
    func sendWake(deviceID: String, payload: WebPushWakePayload) async
}

/// Outbound HTTPS seam so tests can stub push-service delivery.
protocol WebPushHTTPClient: Sendable {
    func post(to url: URL, headers: [(name: String, value: String)], body: Data) async throws -> Int
}

/// Foundation URLSession-backed push delivery (no additional dependency).
struct URLSessionWebPushHTTPClient: WebPushHTTPClient {
    var session: URLSession = .shared

    func post(to url: URL, headers: [(name: String, value: String)], body: Data) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebPushError.invalidResponse
        }
        return httpResponse.statusCode
    }
}

enum WebPushError: Error, Equatable, CustomStringConvertible {
    case invalidSubscriptionKeys
    case invalidEndpoint
    case invalidResponse
    case encryptionFailed(String)
    case jwtSigningFailed(String)

    var description: String {
        switch self {
        case .invalidSubscriptionKeys:
            "The push subscription keys are not valid base64url P-256/auth material."
        case .invalidEndpoint:
            "The push subscription endpoint is not a valid HTTPS URL."
        case .invalidResponse:
            "The push service returned a non-HTTP response."
        case let .encryptionFailed(message):
            "Web Push payload encryption failed: \(message)"
        case let .jwtSigningFailed(message):
            "VAPID JWT signing failed: \(message)"
        }
    }
}

// MARK: - Crypto (RFC 8291 / RFC 8292)

enum WebPushCrypto {
    static let recordSize: UInt32 = 4096
    static let keyInfoPrefix = "WebPush: info"
    static let cekInfo = "Content-Encoding: aes128gcm"
    static let nonceInfo = "Content-Encoding: nonce"

    /// RFC 8291 `aes128gcm` encryption of a push payload.
    ///
    /// - Parameters:
    ///   - plaintext: the payload to protect (identifier-only wake payload).
    ///   - userAgentPublicKey: subscription `p256dh` key (uncompressed 65-byte point).
    ///   - authSecret: subscription `auth` secret (16 bytes).
    ///   - applicationServerAgreementIdentity: ephemeral ECDH key; injectable for the
    ///     RFC 8291 Appendix A test vector, freshly generated per message otherwise.
    ///   - salt: 16-byte salt; injectable for the test vector.
    /// - Returns: the full `aes128gcm` body: header || ciphertext || tag.
    static func encrypt(
        plaintext: Data,
        userAgentPublicKey: Data,
        authSecret: Data,
        applicationServerAgreementIdentity: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data? = nil
    ) throws -> Data {
        let uaPublicKey: P256.KeyAgreement.PublicKey
        do {
            uaPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: userAgentPublicKey)
        } catch {
            throw WebPushError.invalidSubscriptionKeys
        }
        guard authSecret.count == 16 else {
            throw WebPushError.invalidSubscriptionKeys
        }
        let saltBytes = try salt ?? randomBytes(count: 16)
        guard saltBytes.count == 16 else {
            throw WebPushError.encryptionFailed("Salt must be exactly 16 bytes.")
        }

        let asPublicKeyX963 = applicationServerAgreementIdentity.publicKey.x963Representation
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try applicationServerAgreementIdentity.sharedSecretFromKeyAgreement(with: uaPublicKey)
        } catch {
            throw WebPushError.encryptionFailed(String(describing: error))
        }

        // IKM = HKDF-SHA256(salt=auth_secret, ikm=ecdh_secret,
        //                   info="WebPush: info"||0x00||ua_public||as_public, len=32)
        var keyInfo = Data(keyInfoPrefix.utf8)
        keyInfo.append(0x00)
        keyInfo.append(userAgentPublicKey)
        keyInfo.append(asPublicKeyX963)
        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: keyInfo,
            outputByteCount: 32
        )

        // CEK = HKDF-SHA256(salt, IKM, "Content-Encoding: aes128gcm"||0x00, 16)
        // NONCE = HKDF-SHA256(salt, IKM, "Content-Encoding: nonce"||0x00, 12)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: saltBytes,
            info: Data(cekInfo.utf8) + [0x00],
            outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: saltBytes,
            info: Data(nonceInfo.utf8) + [0x00],
            outputByteCount: 12
        )
        let nonceData = nonceKey.withUnsafeBytes { Data($0) }

        // Single last record: plaintext || 0x02 padding delimiter (RFC 8188/8291).
        var record = plaintext
        record.append(0x02)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(record, using: cek, nonce: AES.GCM.Nonce(data: nonceData))
        } catch {
            throw WebPushError.encryptionFailed(String(describing: error))
        }

        // aes128gcm header: salt(16) || rs(4, big-endian) || idlen(1) || keyid(as_public, 65)
        var body = saltBytes
        withUnsafeBytes(of: recordSize.bigEndian) { body.append(contentsOf: $0) }
        body.append(UInt8(asPublicKeyX963.count))
        body.append(asPublicKeyX963)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// RFC 8292 VAPID JWT (ES256): header `{"typ":"JWT","alg":"ES256"}`, claims
    /// `{aud, exp, sub}` where `aud` is the push-service origin.
    static func vapidJWT(
        audience: String,
        subject: String,
        expiration: Date,
        pushSender: PushSender
    ) throws -> String {
        let header = #"{"alg":"ES256","typ":"JWT"}"#
        let claims: JSONValue = .object([
            "aud": .string(audience),
            "exp": .int(Int(expiration.timeIntervalSince1970)),
            "sub": .string(subject)
        ])
        let claimsData: Data
        do {
            claimsData = try RemoteWireProtocol.canonicalData(for: claims)
        } catch {
            throw WebPushError.jwtSigningFailed(String(describing: error))
        }
        let signingInput = WebPushBase64URL.encode(Data(header.utf8)) + "." + WebPushBase64URL.encode(claimsData)
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try pushSender.signature(for: Data(signingInput.utf8))
        } catch {
            throw WebPushError.jwtSigningFailed(String(describing: error))
        }
        // JWS ES256 uses the raw 64-byte r||s representation.
        return signingInput + "." + WebPushBase64URL.encode(signature.rawRepresentation)
    }

    /// `Authorization: vapid t=<jwt>, k=<base64url uncompressed public key>`
    static func vapidAuthorizationHeader(
        endpoint: URL,
        subject: String,
        expiration: Date,
        pushSender: PushSender
    ) throws -> String {
        guard let audience = pushServiceOrigin(for: endpoint) else {
            throw WebPushError.invalidEndpoint
        }
        let jwt = try vapidJWT(
            audience: audience,
            subject: subject,
            expiration: expiration,
            pushSender: pushSender
        )
        let publicKey = WebPushBase64URL.encode(pushSender.publicKey.x963Representation)
        return "vapid t=\(jwt), k=\(publicKey)"
    }

    /// Push-service origin used as the VAPID `aud` claim: scheme://host[:port].
    static func pushServiceOrigin(for endpoint: URL) -> String? {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https",
              let host = endpoint.host
        else {
            return nil
        }
        if let port = endpoint.port, port != 443 {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func randomBytes(count: Int) throws -> Data {
        // CryptoKit's CSPRNG-backed key generation doubles as a secure random source.
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

// MARK: - Service

/// Sends identifier-only wake notifications to disconnected paired devices over
/// Web Push (RFC 8030/8291/8292) using CryptoKit and Foundation only.
actor WebPushService: RemotePushNotifying {
    static let defaultSubject = "https://github.com/repoprompt"
    static let ttlSeconds = 3600
    static let jwtLifetime: TimeInterval = 12 * 60 * 60

    private let pushSender: PushSender
    private let subscriptionStore: WebPushSubscriptionStore
    private let httpClient: any WebPushHTTPClient
    private let subject: String
    private let auditLog: RemoteAuditLog?
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        pushSender: PushSender,
        subscriptionStore: WebPushSubscriptionStore,
        httpClient: any WebPushHTTPClient = URLSessionWebPushHTTPClient(),
        subject: String = WebPushService.defaultSubject,
        auditLog: RemoteAuditLog? = nil,
        logger: Logger = Logger(label: "com.repoprompt.gateway.webpush"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pushSender = pushSender
        self.subscriptionStore = subscriptionStore
        self.httpClient = httpClient
        self.subject = subject
        self.auditLog = auditLog
        self.logger = logger
        self.now = now
    }

    var vapidPublicKeyBase64URL: String {
        VAPIDKeyStore.publicKeyBase64URL(for: pushSender)
    }

    func isPushEligible(deviceID: String) -> Bool {
        subscriptionStore.hasSubscription(forDevice: deviceID)
    }

    /// Best-effort wake delivery. Never throws: push is a wake hint, not a data
    /// channel, and failures must not affect command or observation processing.
    func sendWake(deviceID: String, payload: WebPushWakePayload) async {
        guard let subscription = subscriptionStore.subscription(forDevice: deviceID) else { return }
        do {
            let status = try await send(payload: payload, to: subscription)
            if status == 404 || status == 410 {
                // The push service says the subscription is gone; drop it.
                try? subscriptionStore.removeSubscription(forDevice: deviceID)
                audit(deviceID: deviceID, payload: payload, outcome: "subscription_gone", code: "http_\(status)")
                return
            }
            guard (200 ..< 300).contains(status) else {
                audit(deviceID: deviceID, payload: payload, outcome: "failure", code: "http_\(status)")
                return
            }
            audit(deviceID: deviceID, payload: payload, outcome: "success", code: nil)
        } catch {
            logger.debug("Web Push send failed for \(deviceID): \(String(describing: error))")
            audit(deviceID: deviceID, payload: payload, outcome: "failure", code: "send_failed")
        }
    }

    private func send(payload: WebPushWakePayload, to subscription: WebPushSubscription) async throws -> Int {
        guard let endpoint = URL(string: subscription.endpoint),
              endpoint.scheme?.lowercased() == "https"
        else {
            throw WebPushError.invalidEndpoint
        }
        guard let uaPublicKey = WebPushBase64URL.decode(subscription.p256dh),
              let authSecret = WebPushBase64URL.decode(subscription.auth)
        else {
            throw WebPushError.invalidSubscriptionKeys
        }
        let body = try WebPushCrypto.encrypt(
            plaintext: payload.encoded(),
            userAgentPublicKey: uaPublicKey,
            authSecret: authSecret
        )
        let authorization = try WebPushCrypto.vapidAuthorizationHeader(
            endpoint: endpoint,
            subject: subject,
            expiration: now().addingTimeInterval(Self.jwtLifetime),
            pushSender: pushSender
        )
        let headers: [(name: String, value: String)] = [
            ("Authorization", authorization),
            ("Content-Encoding", "aes128gcm"),
            ("Content-Type", "application/octet-stream"),
            ("TTL", String(Self.ttlSeconds)),
            ("Urgency", "high")
        ]
        return try await httpClient.post(to: endpoint, headers: headers, body: body)
    }

    private func audit(deviceID: String, payload: WebPushWakePayload, outcome: String, code: String?) {
        auditLog?.recordBestEffort(RemoteAuditRecord(
            deviceID: deviceID,
            requestID: nil,
            op: "push_wake_\(payload.kind.rawValue)",
            sessionID: payload.sessionID,
            outcome: outcome,
            code: code
        ))
    }
}
