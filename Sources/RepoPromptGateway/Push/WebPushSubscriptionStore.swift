import Foundation

/// A browser `PushSubscription` registered by a paired device over its
/// authenticated WebSocket connection.
struct WebPushSubscription: Codable, Equatable {
    /// Push service endpoint URL for the subscription.
    let endpoint: String
    /// User-agent P-256 ECDH public key (base64url, uncompressed 65-byte point).
    let p256dh: String
    /// User-agent 16-byte authentication secret (base64url).
    let auth: String
    let createdAtMs: Int64

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case p256dh
        case auth
        case createdAtMs = "created_at_ms"
    }

    /// Parses the standard `PushSubscription.toJSON()` shape:
    /// `{endpoint, keys: {p256dh, auth}}`.
    static func parse(from value: JSONValue, nowMs: Int64) -> WebPushSubscription? {
        guard let object = value.objectValue,
              let endpoint = object["endpoint"]?.stringValue,
              let endpointURL = URL(string: endpoint),
              endpointURL.scheme?.lowercased() == "https",
              let keys = object["keys"]?.objectValue,
              let p256dh = keys["p256dh"]?.stringValue, !p256dh.isEmpty,
              let auth = keys["auth"]?.stringValue, !auth.isEmpty
        else {
            return nil
        }
        return WebPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth, createdAtMs: nowMs)
    }
}

/// Gateway-owned store of Web Push subscriptions keyed by paired device ID.
///
/// Persistence rules (M5):
/// - the store file lives under the gateway app-support root with 0600 permissions,
/// - subscriptions are removed when the device is revoked or unpaired,
/// - a corrupt store fails closed on load.
final class WebPushSubscriptionStore: @unchecked Sendable {
    static let currentSchemaVersion = 1

    private struct StoredSubscriptions: Codable {
        let schemaVersion: Int
        let subscriptions: [String: WebPushSubscription]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case subscriptions
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var subscriptions: [String: WebPushSubscription] = [:]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try GatewayFileSecurity.ensureSecureDirectory(at: fileURL.deletingLastPathComponent())
        try GatewayFileSecurity.ensureSecureFile(at: fileURL)
        try loadLocked()
    }

    func subscription(forDevice deviceID: String) -> WebPushSubscription? {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[deviceID]
    }

    func hasSubscription(forDevice deviceID: String) -> Bool {
        subscription(forDevice: deviceID) != nil
    }

    var deviceIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.keys.sorted()
    }

    func setSubscription(_ subscription: WebPushSubscription, forDevice deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = subscriptions
        updated[deviceID] = subscription
        try persistLocked(updated)
        subscriptions = updated
    }

    /// Removes the device's subscription. Called on explicit unsubscribe, on push
    /// endpoint expiry (404/410), and on device revocation/unpairing.
    @discardableResult
    func removeSubscription(forDevice deviceID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard subscriptions[deviceID] != nil else { return false }
        var updated = subscriptions
        updated.removeValue(forKey: deviceID)
        try persistLocked(updated)
        subscriptions = updated
        return true
    }

    private func loadLocked() throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GatewayPersistenceError.loadFailed(String(describing: error))
        }
        guard !data.isEmpty else {
            subscriptions = [:]
            return
        }
        let stored: StoredSubscriptions
        do {
            stored = try JSONDecoder().decode(StoredSubscriptions.self, from: data)
        } catch {
            throw GatewayPersistenceError.loadFailed("Corrupt push subscription store: \(String(describing: error))")
        }
        guard stored.schemaVersion == Self.currentSchemaVersion else {
            throw GatewayPersistenceError.loadFailed("Unsupported push subscription schema version \(stored.schemaVersion).")
        }
        subscriptions = stored.subscriptions
    }

    private func persistLocked(_ updated: [String: WebPushSubscription]) throws {
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(StoredSubscriptions(
                schemaVersion: Self.currentSchemaVersion,
                subscriptions: updated
            ))
        } catch {
            throw GatewayPersistenceError.appendFailed(String(describing: error))
        }
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            try GatewayFileSecurity.setMode(0o600, path: temporaryURL.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            try GatewayFileSecurity.setMode(0o600, path: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw GatewayPersistenceError.appendFailed("Could not persist push subscriptions: \(String(describing: error))")
        }
    }
}
