import CryptoKit
import Foundation

protocol RemoteClientKeychainStoring: Sendable {
    func get(for key: String, accessMode: KeychainAccessMode) throws -> String
    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws
    func delete(for key: String, accessMode: KeychainAccessMode) throws
}

extension KeychainService: RemoteClientKeychainStoring {}

enum RemoteClientKeyStoreError: Error, Equatable {
    case invalidHostID(String)
    case missingKey(String)
    case invalidPrivateKey
    case keychainUnavailable(String)
}

final class RemoteClientKeyStore: @unchecked Sendable {
    static let shared = RemoteClientKeyStore()

    static var accountPrefix: String {
        RemoteControlStorageNamespace.clientKeyAccountPrefix()
    }

    private let keychain: RemoteClientKeychainStoring
    private let accessMode: KeychainAccessMode
    private let lock = NSRecursiveLock()

    init(
        keychain: RemoteClientKeychainStoring = KeychainService.officialV2Shared,
        accessMode: KeychainAccessMode = .nonInteractive(reason: .backgroundAvailabilityCheck)
    ) {
        self.keychain = keychain
        self.accessMode = accessMode
    }

    func privateKey(forHostID hostID: String) throws -> P256.Signing.PrivateKey {
        try withLock {
            let account = try Self.account(forHostID: hostID)
            do {
                let encoded = try keychain.get(for: account, accessMode: accessMode)
                guard let data = Data(base64Encoded: encoded) else {
                    throw RemoteClientKeyStoreError.invalidPrivateKey
                }
                return try P256.Signing.PrivateKey(rawRepresentation: data)
            } catch KeychainService.KeychainError.itemNotFound {
                throw RemoteClientKeyStoreError.missingKey(hostID)
            } catch let error as RemoteClientKeyStoreError {
                throw error
            } catch is CryptoKitError {
                throw RemoteClientKeyStoreError.invalidPrivateKey
            } catch {
                throw RemoteClientKeyStoreError.keychainUnavailable(error.localizedDescription)
            }
        }
    }

    func publicKey(forHostID hostID: String) throws -> P256.Signing.PublicKey {
        try privateKey(forHostID: hostID).publicKey
    }

    /// Loads the stored device key for a host or creates and saves one when missing.
    ///
    /// The key intentionally persists across failed or abandoned pairing attempts so
    /// the deviceID stays stable across retries; `deleteKey` (forgetHost) is the
    /// cleanup path.
    @discardableResult
    func loadOrCreateKey(forHostID hostID: String) throws -> P256.Signing.PrivateKey {
        try withLock {
            do {
                return try privateKey(forHostID: hostID)
            } catch RemoteClientKeyStoreError.missingKey {
                let key = P256.Signing.PrivateKey()
                try save(key, forHostID: hostID)
                return key
            }
        }
    }

    func save(_ privateKey: P256.Signing.PrivateKey, forHostID hostID: String) throws {
        try withLock {
            let account = try Self.account(forHostID: hostID)
            do {
                try keychain.save(
                    privateKey.rawRepresentation.base64EncodedString(),
                    for: account,
                    accessMode: accessMode
                )
            } catch let error as RemoteClientKeyStoreError {
                throw error
            } catch {
                throw RemoteClientKeyStoreError.keychainUnavailable(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func generateAndSaveKey(forHostID hostID: String) throws -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        try save(key, forHostID: hostID)
        return key
    }

    func deleteKey(forHostID hostID: String) throws {
        try withLock {
            let account = try Self.account(forHostID: hostID)
            do {
                try keychain.delete(for: account, accessMode: accessMode)
            } catch let error as RemoteClientKeyStoreError {
                throw error
            } catch {
                throw RemoteClientKeyStoreError.keychainUnavailable(error.localizedDescription)
            }
        }
    }

    static func account(forHostID hostID: String) throws -> String {
        guard RemoteHostRegistry.isValidHostFingerprint(hostID) else {
            throw RemoteClientKeyStoreError.invalidHostID(hostID)
        }
        let fullDigest = String(hostID.dropFirst("sha256:".count))
        return accountPrefix + fullDigest
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
