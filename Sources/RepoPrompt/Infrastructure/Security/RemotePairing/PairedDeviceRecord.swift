import Foundation

struct WebPushSubscriptionRecord: Codable, Equatable {
    var endpoint: String
    var p256dh: String
    var auth: String
    var createdAt: Date

    init(endpoint: String, p256dh: String, auth: String, createdAt: Date = Date()) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.createdAt = createdAt
    }
}

struct PairedDeviceRecord: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    var displayName: String
    var publicKeyRawRepresentation: Data
    var scopes: Set<RemoteScope>
    var createdAt: Date
    var lastSeenAt: Date?
    var revokedAt: Date?
    var counterFloor: UInt64
    var pushSubscription: WebPushSubscriptionRecord?

    init(
        schemaVersion: Int = PairedDeviceRecord.currentSchemaVersion,
        id: String,
        displayName: String,
        publicKeyRawRepresentation: Data,
        scopes: Set<RemoteScope>,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil,
        counterFloor: UInt64 = 0,
        pushSubscription: WebPushSubscriptionRecord? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.counterFloor = counterFloor
        self.pushSubscription = pushSubscription
    }

    var isRevoked: Bool {
        revokedAt != nil
    }

    var publicKeyFingerprint: String? {
        RemotePairingCrypto.fingerprint(forRawPublicKey: publicKeyRawRepresentation)
    }
}

struct PairedDeviceRegistry: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var hostPublicKeyFingerprint: String
    var devices: [PairedDeviceRecord]

    init(
        schemaVersion: Int = PairedDeviceRegistry.currentSchemaVersion,
        hostPublicKeyFingerprint: String,
        devices: [PairedDeviceRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hostPublicKeyFingerprint = hostPublicKeyFingerprint
        self.devices = devices
    }
}

struct RemoteHostPublicKeyInfo: Equatable {
    var rawRepresentation: Data
    var fingerprint: String
}
