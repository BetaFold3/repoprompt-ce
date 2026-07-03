import Foundation

// M7 contract DTOs intentionally spell out Sendable even when SwiftFormat's
// redundantSendable rule could infer it for internal value types.
// swiftformat:disable redundantSendable

/// Contract-only interface for a future WAN relay transport.
///
/// M7 deliberately defines only the client boundary used by the gateway or a
/// native companion. It does not include a runtime conformer, networking stack,
/// relay discovery, or credential minting logic.
protocol RemoteRelayClient: Sendable {
    /// Connects to a relay endpoint using relay-transport credentials only.
    ///
    /// The relay credential authenticates this client to the relay service for
    /// reachability/fanout. It is not a RepoPrompt pairing ticket, scope grant,
    /// or device approval, and must not be treated as one by implementations.
    func connect(endpoint: URL, credential: RelayCredential) async throws

    /// Sends an already encrypted envelope to the relay.
    ///
    /// Implementations must not inspect or transform `ciphertext`; the relay
    /// security boundary permits metadata routing only.
    func send(_ envelope: EncryptedRelayEnvelope) async throws

    /// Stream of already encrypted envelopes received from the relay.
    var inbound: AsyncThrowingStream<EncryptedRelayEnvelope, Error> { get }

    /// Disconnects from the relay with a local diagnostic reason.
    func disconnect(reason: String) async
}

/// Opaque credential used only for relay transport admission.
///
/// RepoPrompt trust remains app-owned: this credential cannot mint tickets,
/// grant scopes, approve devices, or replace paired-device verification.
struct RelayCredential: Codable, Equatable, Sendable {
    let credentialID: String
    let secret: Data
    let expiresAt: Date?

    init(credentialID: String, secret: Data, expiresAt: Date? = nil) {
        self.credentialID = credentialID
        self.secret = secret
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case secret
        case expiresAt = "expires_at"
    }
}

/// End-to-end encrypted relay payload.
///
/// `channelID`, `senderDeviceID`, and `recipientID` are relay-visible routing
/// metadata. `nonce` and `ciphertext` are produced by the host/device E2E layer
/// before the envelope reaches a relay client implementation.
struct EncryptedRelayEnvelope: Codable, Equatable, Sendable {
    let channelID: String
    let senderDeviceID: String
    let recipientID: String
    let nonce: Data
    let ciphertext: Data

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case senderDeviceID = "sender_device_id"
        case recipientID = "recipient_id"
        case nonce
        case ciphertext
    }
}
