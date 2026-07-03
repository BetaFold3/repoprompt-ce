import Darwin
import Foundation

enum RemoteHostRegistryError: Error, Equatable {
    case missing
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case unreadable
    case invalidRegistry
    case writeFailed(String)
    case hostNotFound(String)
}

final class RemoteHostRegistry: @unchecked Sendable {
    static let shared = RemoteHostRegistry()

    static let directoryComponents = ["RepoPrompt CE", "RemoteControl"]
    static let fileName = "remote-hosts-v1.json"

    let url: URL

    private let fileManager: FileManager
    private let expectedOwnerID: UInt32
    private let lock = NSRecursiveLock()

    init(
        url: URL? = nil,
        fileManager: FileManager = .default,
        expectedOwnerID: UInt32 = getuid()
    ) {
        self.url = url ?? Self.defaultURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.expectedOwnerID = expectedOwnerID
    }

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return directoryComponents.reduce(base) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }
        .appendingPathComponent(fileName, isDirectory: false)
    }

    var hasHosts: Bool {
        (try? registry().hosts.isEmpty) == false
    }

    func registry() throws -> PairedHostRegistryFile {
        try withLock {
            switch Self.load(from: url, expectedOwnerID: expectedOwnerID) {
            case let .success(registry):
                return registry
            case let .failure(error):
                guard error == .missing else { throw error }
                return PairedHostRegistryFile()
            }
        }
    }

    func listHosts() throws -> [PairedHostRecord] {
        try registry().hosts.sorted { lhs, rhs in
            if lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedSame {
                return lhs.id < rhs.id
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func host(id: String) throws -> PairedHostRecord? {
        try registry().hosts.first { $0.id == id }
    }

    func upsertHost(_ record: PairedHostRecord) throws {
        try withLock {
            var registry = try registry()
            registry.hosts.removeAll { $0.id == record.id }
            registry.hosts.append(record)
            try save(registry)
        }
    }

    @discardableResult
    func removeHost(id: String) throws -> PairedHostRecord? {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let removed = registry.hosts.remove(at: index)
            try save(registry)
            return removed
        }
    }

    @discardableResult
    func renameHost(id: String, displayName: String) throws -> PairedHostRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == id }) else {
                throw RemoteHostRegistryError.hostNotFound(id)
            }
            registry.hosts[index].displayName = displayName
            try save(registry)
            return registry.hosts[index]
        }
    }

    @discardableResult
    func updateGatewayURL(hostID: String, gatewayURL: URL) throws -> PairedHostRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == hostID }) else {
                throw RemoteHostRegistryError.hostNotFound(hostID)
            }
            registry.hosts[index].gatewayURL = gatewayURL
            try save(registry)
            return registry.hosts[index]
        }
    }

    @discardableResult
    func updateLastCounter(hostID: String, counter: UInt64) throws -> PairedHostRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == hostID }) else {
                throw RemoteHostRegistryError.hostNotFound(hostID)
            }
            registry.hosts[index].lastCounter = max(registry.hosts[index].lastCounter, counter)
            try save(registry)
            return registry.hosts[index]
        }
    }

    @discardableResult
    func updateLastConnected(hostID: String, at date: Date = Date()) throws -> PairedHostRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == hostID }) else {
                throw RemoteHostRegistryError.hostNotFound(hostID)
            }
            registry.hosts[index].lastConnectedAt = date
            try save(registry)
            return registry.hosts[index]
        }
    }

    @discardableResult
    func markRevokedByHost(hostID: String, at date: Date = Date()) throws -> PairedHostRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.hosts.firstIndex(where: { $0.id == hostID }) else {
                throw RemoteHostRegistryError.hostNotFound(hostID)
            }
            registry.hosts[index].revokedByHostAt = date
            try save(registry)
            return registry.hosts[index]
        }
    }

    func save(_ registry: PairedHostRegistryFile) throws {
        try withLock {
            guard Self.validateRegistry(registry) else {
                throw RemoteHostRegistryError.invalidRegistry
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
            } catch let error as RemoteHostRegistryError {
                throw error
            } catch {
                throw RemoteHostRegistryError.writeFailed(error.localizedDescription)
            }
        }
    }

    static func load(
        from url: URL,
        expectedOwnerID: UInt32 = getuid()
    ) -> Result<PairedHostRegistryFile, RemoteHostRegistryError> {
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
        guard let registry = try? JSONDecoder().decode(PairedHostRegistryFile.self, from: data),
              validateRegistry(registry)
        else {
            return .failure(.invalidRegistry)
        }
        return .success(registry)
    }

    static func validateRegistry(_ registry: PairedHostRegistryFile) -> Bool {
        guard registry.schemaVersion == PairedHostRegistryFile.currentSchemaVersion else {
            return false
        }
        var seenIDs: Set<String> = []
        for host in registry.hosts {
            guard validateHostRecord(host), !seenIDs.contains(host.id) else {
                return false
            }
            seenIDs.insert(host.id)
        }
        return true
    }

    static func validateHostRecord(_ record: PairedHostRecord) -> Bool {
        guard record.schemaVersion == PairedHostRecord.currentSchemaVersion,
              isValidHostFingerprint(record.id),
              !record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isValidGatewayURL(record.gatewayURL),
              RemotePairingIdentityStore.isValidDeviceID(record.deviceID),
              !record.grantedScopes.isEmpty,
              record.grantedScopes.allSatisfy({ scope in
                  scope.trimmingCharacters(in: .whitespacesAndNewlines) == scope && !scope.isEmpty
              }),
              let computedFingerprint = RemotePairingCrypto.fingerprint(forRawPublicKey: record.hostPublicKey),
              computedFingerprint == record.id
        else {
            return false
        }
        return true
    }

    static func isValidGatewayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !(url.host(percentEncoded: false)?.isEmpty ?? true)
    }

    static func isValidHostFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        guard digest.count == 64 else { return false }
        return digest.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 97 ... 102: // 0-9, a-f
                true
            default:
                false
            }
        }
    }

    static func hostFingerprintShort(_ value: String) -> String? {
        guard isValidHostFingerprint(value) else { return nil }
        return String(value.dropFirst("sha256:".count).prefix(8))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
