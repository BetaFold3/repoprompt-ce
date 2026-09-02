import Foundation

// Explicit because the persisted catalog moves between refresh tasks and synchronized readers.
// swiftformat:disable:next redundantSendable
struct AnthropicModelCatalogV1: Codable, Equatable, Sendable {
    let version: Int
    let fetchedAt: Date
    let models: [AnthropicDiscoveredModel]
}

extension Notification.Name {
    static let anthropicDiscoveredModelStoreDidChange =
        Notification.Name("AnthropicDiscoveredModelStoreDidChange")
}

final class AnthropicDiscoveredModelStore: @unchecked Sendable {
    // swiftformat:disable:next redundantSendable
    struct Snapshot: Equatable, Sendable {
        let fetchedAt: Date
        let models: [AnthropicDiscoveredModel]
    }

    static let storageKey = "AnthropicModelCatalogV1"
    static let shared = AnthropicDiscoveredModelStore(defaults: .standard)

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private let defaults: UserDefaults
    private let cleanupSuiteName: String?
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var storedSnapshot: Snapshot?
    private var storedRevision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        cleanupSuiteName = nil
        self.notificationCenter = notificationCenter
        storedSnapshot = Self.loadSnapshot(from: defaults)
        if storedSnapshot != nil {
            storedRevision = 1
        }
    }

    private init(
        defaults: UserDefaults,
        cleanupSuiteName: String,
        notificationCenter: NotificationCenter
    ) {
        self.defaults = defaults
        self.cleanupSuiteName = cleanupSuiteName
        self.notificationCenter = notificationCenter
        storedSnapshot = Self.loadSnapshot(from: defaults)
        if storedSnapshot != nil {
            storedRevision = 1
        }
    }

    deinit {
        if let cleanupSuiteName {
            defaults.removePersistentDomain(forName: cleanupSuiteName)
        }
    }

    static func transient(
        notificationCenter: NotificationCenter = .default
    ) -> AnthropicDiscoveredModelStore {
        let suiteName = "AnthropicDiscoveredModelStore.Transient.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated Anthropic model catalog defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return AnthropicDiscoveredModelStore(
            defaults: defaults,
            cleanupSuiteName: suiteName,
            notificationCenter: notificationCenter
        )
    }

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    var models: [AnthropicDiscoveredModel] {
        snapshot?.models ?? []
    }

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedRevision
    }

    @discardableResult
    func replace(
        with models: [AnthropicDiscoveredModel],
        fetchedAt: Date = Date()
    ) -> Bool {
        guard let canonicalModels = AnthropicDiscoveredModelValidation
            .canonicalizedPreservingOrder(models)?
            .sorted(by: { $0.id < $1.id })
        else {
            return false
        }

        let envelope = AnthropicModelCatalogV1(
            version: 1,
            fetchedAt: fetchedAt,
            models: canonicalModels
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope) else {
            return false
        }

        let nextSnapshot = Snapshot(fetchedAt: fetchedAt, models: canonicalModels)
        lock.lock()
        let dataChanged = storedSnapshot?.models != canonicalModels
        defaults.set(data, forKey: Self.storageKey)
        storedSnapshot = nextSnapshot
        if dataChanged {
            storedRevision &+= 1
        }
        lock.unlock()

        if dataChanged {
            postChangeNotificationOnMainQueue()
        }
        return true
    }

    private func postChangeNotificationOnMainQueue() {
        let post = { [notificationCenter] in
            notificationCenter.post(
                name: .anthropicDiscoveredModelStoreDidChange,
                object: self
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> Snapshot? {
        guard let data = defaults.data(forKey: storageKey),
              let version = try? JSONDecoder().decode(VersionProbe.self, from: data),
              version.version == 1,
              let envelope = try? JSONDecoder().decode(AnthropicModelCatalogV1.self, from: data),
              let models = AnthropicDiscoveredModelValidation
              .canonicalizedPreservingOrder(envelope.models)?
              .sorted(by: { $0.id < $1.id })
        else {
            return nil
        }
        return Snapshot(fetchedAt: envelope.fetchedAt, models: models)
    }
}
