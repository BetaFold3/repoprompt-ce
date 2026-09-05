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

struct APIModelCatalogModelDescriptor: Codable, Equatable {
    let id: String
    let shutdownDate: Date?
}

struct APIModelCatalogSnapshot: Codable, Equatable {
    let scope: APIModelCatalogScope
    let modelIDs: [String]
    let refreshedAt: Date
    let generation: UInt64
    let models: [APIModelCatalogModelDescriptor]

    init(
        scope: APIModelCatalogScope,
        modelIDs: [String],
        refreshedAt: Date,
        generation: UInt64,
        models: [APIModelCatalogModelDescriptor] = []
    ) {
        self.scope = scope
        self.modelIDs = modelIDs
        self.refreshedAt = refreshedAt
        self.generation = generation
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case scope, modelIDs, refreshedAt, generation, models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(APIModelCatalogScope.self, forKey: .scope)
        modelIDs = try container.decode([String].self, forKey: .modelIDs)
        refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
        generation = try container.decode(UInt64.self, forKey: .generation)
        models = try container.decodeIfPresent([APIModelCatalogModelDescriptor].self, forKey: .models) ?? []
    }
}

struct APIModelCatalogRefreshFailure: Equatable {
    enum Reason: Equatable {
        case requestFailed
        case emptyResponse
    }

    let reason: Reason
    let failedAt: Date

    var message: String {
        switch reason {
        case .requestFailed:
            "Model discovery failed. Try refreshing again."
        case .emptyResponse:
            "The model endpoint returned no usable model IDs."
        }
    }
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

struct APIModelCatalogRefreshPayload {
    let modelIDs: [String]
    let models: [APIModelCatalogModelDescriptor]
    let acceptsEmptyResponse: Bool
    let acceptedCommit: (@Sendable () async -> Void)?

    init(
        modelIDs: [String],
        models: [APIModelCatalogModelDescriptor] = [],
        acceptsEmptyResponse: Bool = false,
        acceptedCommit: (@Sendable () async -> Void)? = nil
    ) {
        self.modelIDs = modelIDs
        self.models = models
        self.acceptsEmptyResponse = acceptsEmptyResponse
        self.acceptedCommit = acceptedCommit
    }
}

actor APIModelCatalog {
    typealias Clock = @Sendable () -> Date
    typealias Loader = @Sendable (APIModelCatalogScope) async throws -> [String]
    typealias PayloadLoader = @Sendable (APIModelCatalogScope) async throws -> APIModelCatalogRefreshPayload

    private struct Entry {
        var generation: UInt64 = 0
        var snapshot: APIModelCatalogSnapshot?
        var didLoadStorage = false
        var loadTask: Task<APIModelCatalogSnapshot?, Never>?
        var refreshTask: Task<APIModelCatalogSnapshot?, Never>?
        var refreshFailure: APIModelCatalogRefreshFailure?
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

    func refreshFailure(for scope: APIModelCatalogScope) -> APIModelCatalogRefreshFailure? {
        entries[scope]?.refreshFailure
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

    func snapshots(
        for scope: APIModelCatalogScope,
        payloadLoader: @escaping PayloadLoader
    ) -> AsyncStream<APIModelCatalogSnapshot> {
        AsyncStream { continuation in
            let producer = Task {
                let cached = await self.cachedSnapshot(for: scope)
                if let cached {
                    continuation.yield(cached)
                }

                let refreshed = await self.refresh(for: scope, payloadLoader: payloadLoader)
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
        let loader = requestedLoader ?? defaultLoader
        guard let loader else {
            return entries[scope]?.snapshot
        }
        return await refresh(for: scope) { scope in
            let modelIDs = try await loader(scope)
            return APIModelCatalogRefreshPayload(modelIDs: modelIDs)
        }
    }

    @discardableResult
    func refresh(
        for scope: APIModelCatalogScope,
        payloadLoader: @escaping PayloadLoader
    ) async -> APIModelCatalogSnapshot? {
        _ = await ensureCachedSnapshotLoaded(for: scope)
        if let refreshTask = entries[scope]?.refreshTask {
            return await refreshTask.value
        }

        var entry = entries[scope] ?? Entry()
        entry.generation &+= 1
        let generation = entry.generation
        let task = Task { [weak self] in
            do {
                let payload = try await payloadLoader(scope)
                return await self?.completeRefresh(
                    for: scope,
                    generation: generation,
                    payload: payload
                )
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else {
                    return await self?.completeCancelledRefresh(for: scope, generation: generation)
                }
                return await self?.completeRefreshFailure(
                    for: scope,
                    generation: generation,
                    reason: .requestFailed
                )
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
        entry.refreshFailure = nil
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

        if let stored, stored.scope == scope {
            let acceptedModelIDs = normalizedModelIDs(stored.modelIDs)
            entry.snapshot = APIModelCatalogSnapshot(
                scope: scope,
                modelIDs: acceptedModelIDs,
                refreshedAt: stored.refreshedAt,
                generation: generation,
                models: normalizedDescriptors(
                    stored.models,
                    acceptedModelIDs: Set(acceptedModelIDs)
                )
            )
        }
        entries[scope] = entry
        return entry.snapshot
    }

    private func completeRefresh(
        for scope: APIModelCatalogScope,
        generation: UInt64,
        payload: APIModelCatalogRefreshPayload
    ) async -> APIModelCatalogSnapshot? {
        guard entries[scope]?.generation == generation else {
            return entries[scope]?.snapshot
        }

        let normalizedModelIDs = normalizedModelIDs(payload.modelIDs)
        let acceptedModelIDs: [String]
        if !normalizedModelIDs.isEmpty {
            acceptedModelIDs = normalizedModelIDs
        } else if payload.acceptsEmptyResponse, payload.modelIDs.isEmpty {
            acceptedModelIDs = []
        } else {
            return completeRefreshFailure(
                for: scope,
                generation: generation,
                reason: .emptyResponse
            )
        }

        let snapshot = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: acceptedModelIDs,
            refreshedAt: clock(),
            generation: generation,
            models: normalizedDescriptors(payload.models, acceptedModelIDs: Set(acceptedModelIDs))
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
        entry.refreshFailure = nil
        entries[scope] = entry
        await payload.acceptedCommit?()
        return snapshot
    }

    private func completeRefreshFailure(
        for scope: APIModelCatalogScope,
        generation: UInt64,
        reason: APIModelCatalogRefreshFailure.Reason
    ) -> APIModelCatalogSnapshot? {
        guard var entry = entries[scope], entry.generation == generation else {
            return entries[scope]?.snapshot
        }
        entry.refreshTask = nil
        entry.refreshFailure = APIModelCatalogRefreshFailure(reason: reason, failedAt: clock())
        entries[scope] = entry
        return entry.snapshot
    }

    private func completeCancelledRefresh(
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

    private func normalizedDescriptors(
        _ descriptors: [APIModelCatalogModelDescriptor],
        acceptedModelIDs: Set<String>
    ) -> [APIModelCatalogModelDescriptor] {
        var seen = Set<String>()
        return descriptors.compactMap { descriptor in
            guard let modelID = normalizedModelID(descriptor.id),
                  acceptedModelIDs.contains(modelID),
                  seen.insert(modelID).inserted
            else {
                return nil
            }
            return APIModelCatalogModelDescriptor(
                id: modelID,
                shutdownDate: descriptor.shutdownDate
            )
        }.sorted { $0.id < $1.id }
    }

    private func normalizedModelIDs(_ rawModelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return rawModelIDs.compactMap { rawValue in
            guard let modelID = normalizedModelID(rawValue),
                  seen.insert(modelID).inserted
            else {
                return nil
            }
            return modelID
        }.sorted()
    }

    private func normalizedModelID(_ rawValue: String) -> String? {
        let modelID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              modelID.utf8.count <= 512,
              !modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return modelID
    }
}
