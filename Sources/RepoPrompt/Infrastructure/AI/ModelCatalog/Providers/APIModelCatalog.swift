import CryptoKit
import Foundation

struct APIModelCatalogScope: Codable, Hashable {
    let providerID: String
    let normalizedEndpoint: String
    let keyFingerprint: String

    init?(providerID: String, endpoint: String, apiKey: String) {
        guard let providerID = Self.normalizedProviderID(providerID),
              let normalizedEndpoint = Self.normalizeEndpoint(endpoint),
              let keyFingerprint = Self.fingerprint(apiKey: apiKey)
        else {
            return nil
        }
        self.providerID = providerID
        self.normalizedEndpoint = normalizedEndpoint
        self.keyFingerprint = keyFingerprint
    }

    init?(providerID: String, endpoint: URL, apiKey: String) {
        self.init(providerID: providerID, endpoint: endpoint.absoluteString, apiKey: apiKey)
    }

    static func normalizeEndpoint(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path
        return components.string
    }

    private static func normalizedProviderID(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard normalized.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return normalized
    }

    private static func fingerprint(apiKey: String) -> String? {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct APIModelCatalogSnapshot: Codable, Equatable {
    let scope: APIModelCatalogScope
    let modelIDs: [String]
    let refreshedAt: Date
    let generation: UInt64
}

protocol APIModelCatalogStorage: Sendable {
    func load(for scope: APIModelCatalogScope) async throws -> APIModelCatalogSnapshot?
    func save(_ snapshot: APIModelCatalogSnapshot) async throws
    func remove(for scope: APIModelCatalogScope) async throws
}

struct TransientAPIModelCatalogStorage: APIModelCatalogStorage {
    func load(for scope: APIModelCatalogScope) async throws -> APIModelCatalogSnapshot? {
        nil
    }

    func save(_ snapshot: APIModelCatalogSnapshot) async throws {}

    func remove(for scope: APIModelCatalogScope) async throws {}
}

actor APIModelCatalogFileStorage: APIModelCatalogStorage {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(for scope: APIModelCatalogScope) async throws -> APIModelCatalogSnapshot? {
        let data = try Data(contentsOf: fileURL(for: scope), options: [.mappedIfSafe])
        let snapshot = try JSONDecoder().decode(APIModelCatalogSnapshot.self, from: data)
        return snapshot.scope == scope ? snapshot : nil
    }

    func save(_ snapshot: APIModelCatalogSnapshot) async throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL(for: snapshot.scope), options: [.atomic])
    }

    func remove(for scope: APIModelCatalogScope) async throws {
        let url = fileURL(for: scope)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for scope: APIModelCatalogScope) -> URL {
        let identity = [
            scope.providerID,
            scope.normalizedEndpoint,
            scope.keyFingerprint
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent("api-model-catalog-\(digest).json")
    }
}

actor APIModelCatalog {
    typealias Clock = @Sendable () -> Date
    typealias Loader = @Sendable (APIModelCatalogScope) async throws -> [String]

    private struct Entry {
        var generation: UInt64 = 0
        var snapshot: APIModelCatalogSnapshot?
        var didLoadStorage = false
        var loadTask: Task<APIModelCatalogSnapshot?, Never>?
        var refreshTask: Task<APIModelCatalogSnapshot?, Never>?
    }

    private struct StorageMutation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let clock: Clock
    private let defaultLoader: Loader?
    private let storage: any APIModelCatalogStorage
    private var entries: [APIModelCatalogScope: Entry] = [:]
    private var storageMutations: [APIModelCatalogScope: StorageMutation] = [:]

    init(
        clock: @escaping Clock = { Date() },
        loader: Loader? = nil,
        storage: any APIModelCatalogStorage = TransientAPIModelCatalogStorage()
    ) {
        self.clock = clock
        defaultLoader = loader
        self.storage = storage
    }

    func cachedSnapshot(for scope: APIModelCatalogScope) async -> APIModelCatalogSnapshot? {
        await ensureCachedSnapshotLoaded(for: scope)
    }

    func snapshots(
        for scope: APIModelCatalogScope,
        loader: Loader? = nil
    ) -> AsyncStream<APIModelCatalogSnapshot> {
        AsyncStream { continuation in
            let producer = Task {
                let cached = await self.cachedSnapshot(for: scope)
                if let cached {
                    continuation.yield(cached)
                }

                let refreshed = await self.refresh(for: scope, loader: loader)
                if let refreshed, refreshed != cached {
                    continuation.yield(refreshed)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    @discardableResult
    func refresh(
        for scope: APIModelCatalogScope,
        loader requestedLoader: Loader? = nil
    ) async -> APIModelCatalogSnapshot? {
        _ = await ensureCachedSnapshotLoaded(for: scope)
        if let refreshTask = entries[scope]?.refreshTask {
            return await refreshTask.value
        }
        guard let loader = requestedLoader ?? defaultLoader else {
            return entries[scope]?.snapshot
        }

        var entry = entries[scope] ?? Entry()
        entry.generation &+= 1
        let generation = entry.generation
        let task = Task { [weak self] in
            do {
                let modelIDs = try await loader(scope)
                return await self?.completeRefresh(
                    for: scope,
                    generation: generation,
                    loadedModelIDs: modelIDs
                )
            } catch {
                return await self?.completeRefreshFailure(for: scope, generation: generation)
            }
        }
        entry.refreshTask = task
        entries[scope] = entry
        return await task.value
    }

    func invalidate(_ scope: APIModelCatalogScope) async {
        var entry = entries[scope] ?? Entry()
        entry.generation &+= 1
        entry.loadTask?.cancel()
        entry.refreshTask?.cancel()
        entry.snapshot = nil
        entry.didLoadStorage = true
        entry.loadTask = nil
        entry.refreshTask = nil
        entries[scope] = entry
        let storage = storage
        await enqueueStorageMutation(for: scope) {
            try? await storage.remove(for: scope)
        }
    }

    private func ensureCachedSnapshotLoaded(
        for scope: APIModelCatalogScope
    ) async -> APIModelCatalogSnapshot? {
        if let entry = entries[scope], entry.didLoadStorage {
            return entry.snapshot
        }
        if let loadTask = entries[scope]?.loadTask {
            return await loadTask.value
        }

        var entry = entries[scope] ?? Entry()
        let generation = entry.generation
        let storage = storage
        let task = Task { [weak self] in
            let stored = try? await storage.load(for: scope)
            return await self?.completeStorageLoad(
                stored,
                for: scope,
                generation: generation
            )
        }
        entry.loadTask = task
        entries[scope] = entry
        return await task.value
    }

    private func completeStorageLoad(
        _ stored: APIModelCatalogSnapshot?,
        for scope: APIModelCatalogScope,
        generation: UInt64
    ) -> APIModelCatalogSnapshot? {
        guard var entry = entries[scope], entry.generation == generation else {
            return entries[scope]?.snapshot
        }
        entry.didLoadStorage = true
        entry.loadTask = nil

        if let stored,
           stored.scope == scope,
           !normalizedModelIDs(stored.modelIDs).isEmpty
        {
            entry.snapshot = APIModelCatalogSnapshot(
                scope: scope,
                modelIDs: normalizedModelIDs(stored.modelIDs),
                refreshedAt: stored.refreshedAt,
                generation: generation
            )
        }
        entries[scope] = entry
        return entry.snapshot
    }

    private func completeRefresh(
        for scope: APIModelCatalogScope,
        generation: UInt64,
        loadedModelIDs: [String]
    ) async -> APIModelCatalogSnapshot? {
        guard entries[scope]?.generation == generation else {
            return entries[scope]?.snapshot
        }

        let modelIDs = normalizedModelIDs(loadedModelIDs)
        guard !modelIDs.isEmpty else {
            return completeRefreshFailure(for: scope, generation: generation)
        }

        let snapshot = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: modelIDs,
            refreshedAt: clock(),
            generation: generation
        )
        let storage = storage
        await enqueueStorageMutation(for: scope) {
            try? await storage.save(snapshot)
        }

        guard var entry = entries[scope], entry.generation == generation else {
            return entries[scope]?.snapshot
        }
        entry.snapshot = snapshot
        entry.didLoadStorage = true
        entry.refreshTask = nil
        entries[scope] = entry
        return snapshot
    }

    private func completeRefreshFailure(
        for scope: APIModelCatalogScope,
        generation: UInt64
    ) -> APIModelCatalogSnapshot? {
        guard var entry = entries[scope], entry.generation == generation else {
            return entries[scope]?.snapshot
        }
        entry.refreshTask = nil
        entries[scope] = entry
        return entry.snapshot
    }

    private func enqueueStorageMutation(
        for scope: APIModelCatalogScope,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let previous = storageMutations[scope]?.task
        let id = UUID()
        let task = Task {
            if let previous {
                await previous.value
            }
            await operation()
        }
        storageMutations[scope] = StorageMutation(id: id, task: task)
        await task.value
        if storageMutations[scope]?.id == id {
            storageMutations[scope] = nil
        }
    }

    private func normalizedModelIDs(_ rawModelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return rawModelIDs.compactMap { rawValue in
            let modelID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty,
                  modelID.utf8.count <= 512,
                  !modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(modelID).inserted
            else {
                return nil
            }
            return modelID
        }.sorted()
    }
}
