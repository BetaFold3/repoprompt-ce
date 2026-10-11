import Foundation

package struct PairedHostRecord: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Stable host trust key: `sha256:<64 lowercase hex>` of `hostPublicKey`.
    package var id: String
    /// Host display name from the pairing payload/hello, user-renamable by later UI.
    package var displayName: String
    package var gatewayURL: URL
    /// Pinned host P-256 signing public key rawRepresentation.
    var hostPublicKey: Data
    /// This client's per-host device ID, derived from its per-host public key.
    package var deviceID: String
    /// Raw granted scope strings. UI may map known values through `RemoteScope`.
    package var grantedScopes: Set<String>
    package var pairedAt: Date
    package var lastConnectedAt: Date?
    /// Best-effort persisted signer floor. N3's signer uses `max(last + 1, now_ms)`.
    var lastCounter: UInt64
    package var revokedByHostAt: Date?

    init(
        schemaVersion: Int = PairedHostRecord.currentSchemaVersion,
        id: String,
        displayName: String,
        gatewayURL: URL,
        hostPublicKey: Data,
        deviceID: String,
        grantedScopes: Set<String>,
        pairedAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        lastCounter: UInt64 = 0,
        revokedByHostAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.gatewayURL = gatewayURL
        self.hostPublicKey = hostPublicKey
        self.deviceID = deviceID
        self.grantedScopes = grantedScopes
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
        self.lastCounter = lastCounter
        self.revokedByHostAt = revokedByHostAt
    }

    package var isRevokedByHost: Bool {
        revokedByHostAt != nil
    }
}

struct PairedHostRegistryFile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var hosts: [PairedHostRecord]

    init(
        schemaVersion: Int = PairedHostRegistryFile.currentSchemaVersion,
        hosts: [PairedHostRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
    }
}
