import CryptoKit
import Foundation

/// Gateway-owned VAPID signing keypair for Web Push (RFC 8292).
///
/// VAPID keys authenticate the gateway to browser push services. They are
/// operational gateway keys, not device credentials minted by the app; the app's
/// host signing key never leaves the app keychain and is unrelated to this key.
///
/// Persistence rules (M5):
/// - the key file lives under the gateway app-support root with 0600 permissions,
/// - insecure permissions or ownership fail closed on load,
/// - a corrupt or non-P256 key fails closed on load.
final class VAPIDKeyStore: @unchecked Sendable {
    static let currentSchemaVersion = 1

    private struct StoredKey: Codable {
        let schemaVersion: Int
        let privateKeyBase64: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case privateKeyBase64 = "private_key"
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var cachedKey: P256.Signing.PrivateKey?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the persisted VAPID key, generating and persisting a new one when the
    /// key file does not exist yet. Existing files are validated (regular file,
    /// owner, 0600) before their contents are trusted.
    func loadOrCreate() throws -> P256.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey {
            return cachedKey
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let key = try loadLocked()
            cachedKey = key
            return key
        }
        let key = P256.Signing.PrivateKey()
        try persistLocked(key)
        cachedKey = key
        return key
    }

    /// Loads the persisted VAPID key, failing closed when the file is missing,
    /// insecurely permissioned, or corrupt.
    func load() throws -> P256.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        let key = try loadLocked()
        cachedKey = key
        return key
    }

    /// Uncompressed P-256 public key point (65 bytes), base64url-encoded without
    /// padding — the exact `applicationServerKey` format browsers expect.
    static func publicKeyBase64URL(for key: P256.Signing.PrivateKey) -> String {
        WebPushBase64URL.encode(key.publicKey.x963Representation)
    }

    private func loadLocked() throws -> P256.Signing.PrivateKey {
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GatewayPersistenceError.loadFailed(String(describing: error))
        }
        let stored: StoredKey
        do {
            stored = try JSONDecoder().decode(StoredKey.self, from: data)
        } catch {
            throw GatewayPersistenceError.loadFailed("Corrupt VAPID key file: \(String(describing: error))")
        }
        guard stored.schemaVersion == Self.currentSchemaVersion else {
            throw GatewayPersistenceError.loadFailed("Unsupported VAPID key schema version \(stored.schemaVersion).")
        }
        guard let raw = Data(base64Encoded: stored.privateKeyBase64),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        else {
            throw GatewayPersistenceError.loadFailed("VAPID key file does not contain a valid P-256 private key.")
        }
        return key
    }

    private func persistLocked(_ key: P256.Signing.PrivateKey) throws {
        try GatewayFileSecurity.ensureSecureDirectory(at: fileURL.deletingLastPathComponent())
        let stored = StoredKey(
            schemaVersion: Self.currentSchemaVersion,
            privateKeyBase64: key.rawRepresentation.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(stored)
        } catch {
            throw GatewayPersistenceError.appendFailed(String(describing: error))
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try GatewayFileSecurity.setMode(0o600, path: fileURL.path)
        } catch let error as GatewayPersistenceError {
            throw error
        } catch {
            throw GatewayPersistenceError.cannotCreateFile(fileURL.path)
        }
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
    }
}

/// Base64url helpers shared by the gateway Web Push components.
enum WebPushBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
