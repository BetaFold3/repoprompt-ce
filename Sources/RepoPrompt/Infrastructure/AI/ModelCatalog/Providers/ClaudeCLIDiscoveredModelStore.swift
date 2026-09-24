import Foundation

extension Notification.Name {
    static let claudeCLIModelCatalogDidChange = Notification.Name("ClaudeCLIModelCatalogDidChange")
}

/// CLI provenance never enters the native Anthropic API registry.
/// Persisted data stays inactive until the current CLI account has been verified.
final class ClaudeCLIDiscoveredModelStore: @unchecked Sendable {
    struct Snapshot: Codable, Equatable {
        let version: Int
        let scope: String
        let fetchedAt: Date
        let modelIDs: [String]
    }

    static let shared = ClaudeCLIDiscoveredModelStore(defaults: .standard)
    static let storageKey = "ClaudeCLIModelCatalogV1"

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var cached: Snapshot?
    private var active: Snapshot?
    private var storedRevision: UInt64 = 0

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           data.count <= 1_048_576,
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.version == 1,
           !snapshot.scope.isEmpty,
           Self.canonicalIDs(snapshot.modelIDs) == snapshot.modelIDs
        {
            cached = snapshot
        }
    }

    var revisionedModels: (revision: UInt64, modelIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (storedRevision, active?.modelIDs ?? [])
    }

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock()
        let changed = active != nil
        active = nil
        if changed { storedRevision &+= 1 }
        lock.unlock()
        if changed { notify() }
    }

    /// Account verification is separate from model availability. Never call from disk hydration.
    func activate(scope: String) {
        lock.lock()
        let next = cached?.scope == scope ? cached : nil
        let changed = active?.scope != next?.scope || active?.modelIDs != next?.modelIDs
        active = next
        if changed { storedRevision &+= 1 }
        lock.unlock()
        if changed { notify() }
    }

    @discardableResult
    func replace(modelIDs: [String], scope: String?, fetchedAt: Date = Date()) -> Bool {
        guard let ids = Self.canonicalIDs(modelIDs) else { return false }
        let next = Snapshot(version: 1, scope: scope ?? "", fetchedAt: fetchedAt, modelIDs: ids)
        guard let data = try? JSONEncoder().encode(next) else { return false }
        lock.lock()
        let changed = active?.scope != next.scope || active?.modelIDs != next.modelIDs
        active = next
        if let scope, !scope.isEmpty {
            cached = next
            defaults?.set(data, forKey: Self.storageKey)
        }
        if changed { storedRevision &+= 1 }
        lock.unlock()
        if changed { notify() }
        return true
    }

    private static func canonicalIDs(_ ids: [String]) -> [String]? {
        guard ids.count <= 1024,
              ids.allSatisfy({ $0.utf8.count <= 256 && ClaudeModelFamilyCatalog.cliPointRelease($0) != nil })
        else { return nil }
        return Array(Set(ids)).sorted()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .claudeCLIModelCatalogDidChange, object: self)
        }
    }
}
