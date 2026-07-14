import CryptoKit
import Darwin
import Foundation
import RepoPromptRemoteWire

protocol RemotePairingKeychainStoring: Sendable {
    func get(for key: String, accessMode: KeychainAccessMode) throws -> String
    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws
}

extension KeychainService: RemotePairingKeychainStoring {}

enum RemotePairingIdentityStoreError: Error, Equatable {
    case missing
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case unreadable
    case invalidRegistry
    case invalidHostKey
    case keychainUnavailable(String)
    case writeFailed(String)
    case deviceNotFound(String)
}

final class RemotePairingIdentityStore: @unchecked Sendable {
    static let shared = RemotePairingIdentityStore()

    static let directoryComponents = RemoteControlStorageNamespace.rootComponents
    static let fileName = "paired-devices-v1.json"
    static var hostSigningKeyAccount: String {
        RemoteControlStorageNamespace.hostSigningKeyAccount()
    }

    let url: URL

    private let fileManager: FileManager
    private let expectedOwnerID: UInt32
    private let keychain: RemotePairingKeychainStoring
    private let lock = NSRecursiveLock()
    /// Sidebar/dashboard render-time callers can otherwise pay Keychain + lstat + JSON decode per row.
    /// The app is the only in-process writer and all mutations funnel through save(_:);
    /// the gateway only reads this file out-of-process. Trade-off: writes from another app
    /// instance stay invisible until an in-process save() — the pre-cache behavior re-read the
    /// file per call and was eventually consistent; the supported model is a single app instance.
    private var cachedRegistry: PairedDeviceRegistry?

    init(
        url: URL? = nil,
        fileManager: FileManager = .default,
        expectedOwnerID: UInt32 = getuid(),
        keychain: RemotePairingKeychainStoring = KeychainService.officialV2Shared
    ) {
        self.url = url ?? Self.defaultURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.expectedOwnerID = expectedOwnerID
        self.keychain = keychain
    }

    static func defaultURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        RemoteControlStorageNamespace.pairedDevicesURL(channel: channel, fileManager: fileManager)
    }

    func hostPublicKeyInfo() throws -> RemoteHostPublicKeyInfo {
        try withLock {
            let key = try hostPrivateKeyLocked()
            let publicKey = key.publicKey
            return RemoteHostPublicKeyInfo(
                rawRepresentation: publicKey.rawRepresentation,
                fingerprint: RemotePairingCrypto.fingerprint(for: publicKey)
            )
        }
    }

    func hostSigningPrivateKey() throws -> P256.Signing.PrivateKey {
        try withLock { try hostPrivateKeyLocked() }
    }

    func registry() throws -> PairedDeviceRegistry {
        try withLock {
            if let cachedRegistry {
                return cachedRegistry
            }

            let hostFingerprint = try hostPublicKeyInfo().fingerprint
            switch Self.load(from: url, expectedOwnerID: expectedOwnerID) {
            case let .success(registry):
                guard registry.hostPublicKeyFingerprint == hostFingerprint else {
                    throw RemotePairingIdentityStoreError.invalidRegistry
                }
                cachedRegistry = registry
                return registry
            case let .failure(error):
                guard error == .missing else { throw error }
                let registry = PairedDeviceRegistry(hostPublicKeyFingerprint: hostFingerprint, devices: [])
                cachedRegistry = registry
                return registry
            }
        }
    }

    func listDevices(includeRevoked: Bool = true) throws -> [PairedDeviceRecord] {
        let devices = try registry().devices.sorted { lhs, rhs in
            lhs.createdAt < rhs.createdAt
        }
        return includeRevoked ? devices : devices.filter { !$0.isRevoked }
    }

    func device(id: String) throws -> PairedDeviceRecord? {
        try registry().devices.first { $0.id == id }
    }

    func upsertDevice(_ record: PairedDeviceRecord) throws {
        try withLock {
            var registry = try registry()
            registry.devices.removeAll { $0.id == record.id }
            registry.devices.append(record)
            try save(registry)
        }
    }

    @discardableResult
    func upsertDevicePreservingCounterFloor(_ record: PairedDeviceRecord) throws -> PairedDeviceRecord {
        try withLock {
            var registry = try registry()
            let existingCounterFloor = registry.devices.first { $0.id == record.id }?.counterFloor ?? 0
            var updated = record
            updated.counterFloor = max(existingCounterFloor, record.counterFloor)
            registry.devices.removeAll { $0.id == record.id }
            registry.devices.append(updated)
            try save(registry)
            return updated
        }
    }

    @discardableResult
    func revokeDevice(id: String, revokedAt: Date = Date()) throws -> PairedDeviceRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.devices.firstIndex(where: { $0.id == id }) else {
                throw RemotePairingIdentityStoreError.deviceNotFound(id)
            }
            registry.devices[index].revokedAt = revokedAt
            registry.devices[index].pushSubscription = nil
            try save(registry)
            return registry.devices[index]
        }
    }

    func updateLastSeen(deviceID: String, at date: Date = Date()) throws {
        try withLock {
            var registry = try registry()
            guard let index = registry.devices.firstIndex(where: { $0.id == deviceID }) else {
                throw RemotePairingIdentityStoreError.deviceNotFound(deviceID)
            }
            registry.devices[index].lastSeenAt = date
            try save(registry)
        }
    }

    func save(_ registry: PairedDeviceRegistry) throws {
        try withLock {
            guard Self.validateRegistry(registry) else {
                throw RemotePairingIdentityStoreError.invalidRegistry
            }
            let parent = url.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(registry)
                try data.write(to: url, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                // The just-written registry passed validateRegistry above and is now the
                // on-disk state; installing it avoids a full Keychain + load + decode miss
                // on the next read (updateLastSeen fires on connection activity).
                cachedRegistry = registry
            } catch {
                cachedRegistry = nil
                throw RemotePairingIdentityStoreError.writeFailed(error.localizedDescription)
            }
        }
    }

    static func load(
        from url: URL,
        expectedOwnerID: UInt32 = getuid()
    ) -> Result<PairedDeviceRegistry, RemotePairingIdentityStoreError> {
        var fileStatus = Darwin.stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .failure(errno == ENOENT ? .missing : .unreadable)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            return .failure(.notRegularFile)
        }
        guard fileStatus.st_uid == expectedOwnerID else {
            return .failure(.wrongOwner)
        }
        guard fileStatus.st_mode & 0o077 == 0 else {
            return .failure(.insecurePermissions)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.unreadable)
        }
        guard let registry = try? JSONDecoder().decode(PairedDeviceRegistry.self, from: data),
              validateRegistry(registry)
        else {
            return .failure(.invalidRegistry)
        }
        return .success(registry)
    }

    static func validateRegistry(_ registry: PairedDeviceRegistry) -> Bool {
        guard registry.schemaVersion == PairedDeviceRegistry.currentSchemaVersion,
              RemotePairingCrypto.isValidFingerprint(registry.hostPublicKeyFingerprint)
        else {
            return false
        }

        var seenIDs: Set<String> = []
        for device in registry.devices {
            guard validateDeviceRecord(device), !seenIDs.contains(device.id) else {
                return false
            }
            seenIDs.insert(device.id)
        }
        return true
    }

    static func validateDeviceRecord(_ record: PairedDeviceRecord) -> Bool {
        guard record.schemaVersion == PairedDeviceRecord.currentSchemaVersion,
              isValidDeviceID(record.id),
              !record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.scopes.isEmpty,
              RemotePairingCrypto.fingerprint(forRawPublicKey: record.publicKeyRawRepresentation) != nil
        else {
            return false
        }
        return true
    }

    static func isValidDeviceID(_ id: String) -> Bool {
        guard id.hasPrefix("remote:") else { return false }
        let suffix = id.dropFirst("remote:".count)
        guard (8 ... 64).contains(suffix.count) else { return false }
        return suffix.allSatisfy { character in
            character.isHexDigit && String(character).lowercased() == String(character)
        }
    }

    private func hostPrivateKeyLocked() throws -> P256.Signing.PrivateKey {
        do {
            let encoded = try keychain.get(
                for: Self.hostSigningKeyAccount,
                accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
            )
            guard let data = Data(base64Encoded: encoded) else {
                throw RemotePairingIdentityStoreError.invalidHostKey
            }
            return try RemotePairingCrypto.hostPrivateKey(rawRepresentation: data)
        } catch KeychainService.KeychainError.itemNotFound {
            let key = P256.Signing.PrivateKey()
            do {
                try keychain.save(
                    key.rawRepresentation.base64EncodedString(),
                    for: Self.hostSigningKeyAccount,
                    accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
                )
            } catch {
                throw RemotePairingIdentityStoreError.keychainUnavailable(error.localizedDescription)
            }
            return key
        } catch let error as RemotePairingIdentityStoreError {
            throw error
        } catch RemotePairingCryptoError.invalidPrivateKey {
            throw RemotePairingIdentityStoreError.invalidHostKey
        } catch {
            throw RemotePairingIdentityStoreError.keychainUnavailable(error.localizedDescription)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
