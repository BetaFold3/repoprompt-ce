import Foundation

extension Notification.Name {
    static let ohMyPiThinkingCapabilitiesDidChange = Notification.Name(
        "RepoPrompt.ohMyPiThinkingCapabilitiesDidChange"
    )
}

struct OhMyPiThinkingCapabilityOption: Codable, Equatable {
    let value: String
    let displayName: String
}

struct OhMyPiThinkingCapabilitySnapshot: Codable, Equatable {
    let modelID: String
    let configID: String
    let category: String
    let orderedOptions: [OhMyPiThinkingCapabilityOption]
    let ompVersion: String
    let observedAt: Date

    var advertisedCapabilities: OhMyPiThinkingAdvertisedCapabilities {
        OhMyPiThinkingAdvertisedCapabilities(
            options: orderedOptions.map {
                OhMyPiThinkingAdvertisedOption(value: $0.value, displayName: $0.displayName)
            },
            isAuthoritative: true
        )
    }
}

struct OhMyPiThinkingCapabilityStore: @unchecked Sendable {
    struct Document: Codable, Equatable {
        let schemaVersion: Int
        let records: [OhMyPiThinkingCapabilitySnapshot]
    }

    static let schemaVersion = 1
    static let fileName = "omp-thinking-capabilities-v1.json"
    private static let transactionLock = NSLock()

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func standard(fileManager: FileManager = .default) -> OhMyPiThinkingCapabilityStore {
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return OhMyPiThinkingCapabilityStore(
            fileURL: supportDirectory
                .appendingPathComponent("RepoPrompt CE", isDirectory: true)
                .appendingPathComponent(fileName),
            fileManager: fileManager
        )
    }

    func load() -> [String: OhMyPiThinkingCapabilitySnapshot] {
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["schemaVersion"] as? Int == Self.schemaVersion,
              let rawRecords = dictionary["records"] as? [Any]
        else {
            return [:]
        }

        var result: [String: OhMyPiThinkingCapabilitySnapshot] = [:]
        for rawRecord in rawRecords {
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
                  let record = try? Self.decoder.decode(
                      OhMyPiThinkingCapabilitySnapshot.self,
                      from: recordData
                  ),
                  Self.isValid(record),
                  result[record.modelID] == nil
            else { continue }
            result[record.modelID] = record
        }
        return result
    }

    func save(_ recordsByModelID: [String: OhMyPiThinkingCapabilitySnapshot]) {
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }
        let records = recordsByModelID.values
            .filter(Self.isValid)
            .sorted { $0.modelID < $1.modelID }
        let document = Document(schemaVersion: Self.schemaVersion, records: records)
        guard let data = try? Self.encoder.encode(document) else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Capability persistence is an optimization. Runtime selection must not fail with it.
        }
    }

    func remove() {
        Self.transactionLock.lock()
        defer { Self.transactionLock.unlock() }
        try? fileManager.removeItem(at: fileURL)
    }

    private static func isValid(_ record: OhMyPiThinkingCapabilitySnapshot) -> Bool {
        guard !record.modelID.isEmpty,
              record.configID == ACPConfigOptionKey.ohMyPiThinking.configID,
              record.category == ACPConfigOptionKey.ohMyPiThinking.category,
              !record.ompVersion.isEmpty,
              !record.orderedOptions.isEmpty
        else {
            return false
        }
        var values = Set<String>()
        return record.orderedOptions.allSatisfy {
            !$0.value.isEmpty && !$0.displayName.isEmpty && values.insert($0.value).inserted
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

final class OhMyPiThinkingCapabilityRegistry: @unchecked Sendable {
    static let shared = OhMyPiThinkingCapabilityRegistry()

    private let lock = NSLock()
    private let store: OhMyPiThinkingCapabilityStore
    private var liveByModelID: [String: OhMyPiThinkingCapabilitySnapshot] = [:]
    private var persistedByModelID: [String: OhMyPiThinkingCapabilitySnapshot] = [:]
    private var warmTask: Task<[String: OhMyPiThinkingCapabilitySnapshot], Never>?
    private var didWarmStore = false
    private var warmGeneration: UInt64 = 0
    private var recentlyInvalidatedModelIDs: Set<String> = []

    init(store: OhMyPiThinkingCapabilityStore = .standard()) {
        self.store = store
    }

    func snapshot(for exactModelID: String) -> OhMyPiThinkingCapabilitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return liveByModelID[exactModelID] ?? persistedByModelID[exactModelID]
    }

    func snapshotAfterWarmingStore(
        for exactModelID: String
    ) async -> OhMyPiThinkingCapabilitySnapshot? {
        if let snapshot = snapshot(for: exactModelID) { return snapshot }
        await warmStandardStoreIfNeeded()
        return snapshot(for: exactModelID)
    }

    func warmStandardStoreIfNeeded() async {
        let state = lock.withLock { () -> (
            alreadyWarm: Bool,
            task: Task<[String: OhMyPiThinkingCapabilitySnapshot], Never>?,
            generation: UInt64
        ) in
            if didWarmStore {
                return (true, nil, warmGeneration)
            }
            if let warmTask {
                return (false, warmTask, warmGeneration)
            }
            let store = store
            let newTask = Task.detached(priority: .utility) { store.load() }
            warmTask = newTask
            return (false, newTask, warmGeneration)
        }
        guard !state.alreadyWarm, let task = state.task else { return }
        let loaded = await task.value
        let currentVersion = OhMyPiRuntimeVersionRegistry.shared.currentVersion
        let filtered = currentVersion.map { version in
            loaded.filter { $0.value.ompVersion == version }
        } ?? loaded
        let removedIDs = Set(loaded.keys).subtracting(filtered.keys)
        let shouldRewrite = filtered.count != loaded.count
        let didApply = lock.withLock { () -> Bool in
            guard state.generation == warmGeneration else { return false }
            persistedByModelID = filtered
            recentlyInvalidatedModelIDs.formUnion(removedIDs)
            didWarmStore = true
            warmTask = nil
            if shouldRewrite {
                store.save(mergedRecordsLocked())
            }
            return true
        }
        guard didApply, shouldRewrite else { return }
        NotificationCenter.default.post(
            name: .ohMyPiThinkingCapabilitiesDidChange,
            object: self
        )
    }

    @discardableResult
    func record(
        _ record: OhMyPiThinkingCapabilityRecord,
        ompVersion: String? = OhMyPiRuntimeVersionRegistry.shared.currentVersion,
        observedAt: Date = Date()
    ) -> Bool {
        let didChange = recordWithoutNotification(
            record,
            ompVersion: ompVersion,
            observedAt: observedAt
        )
        if didChange { postCapabilitiesDidChange() }
        return didChange
    }

    @discardableResult
    func recordWithoutNotification(
        _ record: OhMyPiThinkingCapabilityRecord,
        ompVersion: String?,
        observedAt: Date = Date()
    ) -> Bool {
        let version = ompVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = record.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !modelID.isEmpty else { return false }
        let options = record.orderedOptions.enumerated().map { index, value in
            let displayName = record.optionDisplayNames.indices.contains(index)
                ? record.optionDisplayNames[index]
                : value
            return OhMyPiThinkingCapabilityOption(value: value, displayName: displayName)
        }
        let snapshot = OhMyPiThinkingCapabilitySnapshot(
            modelID: modelID,
            configID: record.configID,
            category: record.category,
            orderedOptions: options,
            ompVersion: version,
            observedAt: observedAt
        )
        guard !options.isEmpty,
              options.allSatisfy({ !$0.value.isEmpty && !$0.displayName.isEmpty }),
              Set(options.map(\.value)).count == options.count,
              snapshot.configID == ACPConfigOptionKey.ohMyPiThinking.configID,
              snapshot.category == ACPConfigOptionKey.ohMyPiThinking.category
        else { return false }

        lock.lock()
        let removedVersionMismatch = removeVersionMismatchesLocked(currentVersion: version)
        let existing = liveByModelID[modelID] ?? persistedByModelID[modelID]
        let isOlderObservation = existing.map { $0.observedAt > snapshot.observedAt } ?? false
        let didChange = !isOlderObservation && existing != snapshot
        if didChange {
            liveByModelID[modelID] = snapshot
            persistedByModelID[modelID] = snapshot
            recentlyInvalidatedModelIDs.remove(modelID)
        }
        guard didChange || removedVersionMismatch else {
            lock.unlock()
            return false
        }
        store.save(mergedRecordsLocked())
        lock.unlock()
        return true
    }

    @discardableResult
    func invalidateWithoutNotification(forRuntimeVersion ompVersion: String) -> Bool {
        let version = ompVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return false }
        lock.lock()
        let didChange = removeVersionMismatchesLocked(currentVersion: version)
        if didChange {
            store.save(mergedRecordsLocked())
        }
        lock.unlock()
        return didChange
    }

    func postCapabilitiesDidChange() {
        NotificationCenter.default.post(name: .ohMyPiThinkingCapabilitiesDidChange, object: self)
    }

    func reset() {
        lock.lock()
        liveByModelID.removeAll()
        persistedByModelID.removeAll()
        warmTask?.cancel()
        warmTask = nil
        didWarmStore = false
        recentlyInvalidatedModelIDs.removeAll()
        warmGeneration &+= 1
        store.remove()
        lock.unlock()
        NotificationCenter.default.post(name: .ohMyPiThinkingCapabilitiesDidChange, object: self)
    }

    func recentlyInvalidatedIDs() -> Set<String> {
        lock.withLock { recentlyInvalidatedModelIDs }
    }

    private func removeVersionMismatchesLocked(currentVersion: String) -> Bool {
        let removedIDs = Set(liveByModelID.filter { $0.value.ompVersion != currentVersion }.keys)
            .union(persistedByModelID.filter { $0.value.ompVersion != currentVersion }.keys)
        liveByModelID = liveByModelID.filter { $0.value.ompVersion == currentVersion }
        persistedByModelID = persistedByModelID.filter { $0.value.ompVersion == currentVersion }
        recentlyInvalidatedModelIDs.formUnion(removedIDs)
        return !removedIDs.isEmpty
    }

    private func mergedRecordsLocked() -> [String: OhMyPiThinkingCapabilitySnapshot] {
        persistedByModelID.merging(liveByModelID) { _, live in live }
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_clearMemoryPreservingStore() {
            lock.lock()
            liveByModelID.removeAll()
            persistedByModelID.removeAll()
            warmTask?.cancel()
            warmTask = nil
            didWarmStore = false
            warmGeneration &+= 1
            lock.unlock()
        }
    #endif
}

final class OhMyPiRuntimeVersionRegistry: @unchecked Sendable {
    static let shared = OhMyPiRuntimeVersionRegistry(
        capabilityRegistry: .shared
    )

    private let lock = NSLock()
    private let capabilityRegistry: OhMyPiThinkingCapabilityRegistry
    private var storedVersion: String?

    #if DEBUG
        private var conditionalRecordBarrier: (@Sendable () -> Void)?
    #endif

    init(capabilityRegistry: OhMyPiThinkingCapabilityRegistry = .shared) {
        self.capabilityRegistry = capabilityRegistry
    }

    var currentVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedVersion
    }

    @discardableResult
    func observe(_ components: [Int]) -> String {
        let version = components.map(String.init).joined(separator: ".")
        lock.lock()
        let didChange = storedVersion != version
        storedVersion = version
        let capabilitiesChanged = didChange
            ? capabilityRegistry.invalidateWithoutNotification(forRuntimeVersion: version)
            : false
        lock.unlock()
        if capabilitiesChanged {
            capabilityRegistry.postCapabilitiesDidChange()
        }
        return version
    }

    @discardableResult
    func recordCapabilityIfCurrent(
        _ record: OhMyPiThinkingCapabilityRecord,
        expectedVersion: String
    ) -> Bool {
        lock.lock()
        guard storedVersion == expectedVersion else {
            lock.unlock()
            return false
        }
        #if DEBUG
            conditionalRecordBarrier?()
        #endif
        let didChange = capabilityRegistry.recordWithoutNotification(
            record,
            ompVersion: expectedVersion
        )
        lock.unlock()
        if didChange {
            capabilityRegistry.postCapabilitiesDidChange()
        }
        return didChange
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_reset() {
            lock.withLock {
                storedVersion = nil
                conditionalRecordBarrier = nil
            }
        }

        @_spi(TestSupport)
        public func test_setConditionalRecordBarrier(
            _ barrier: (@Sendable () -> Void)?
        ) {
            lock.withLock { conditionalRecordBarrier = barrier }
        }
    #endif
}
