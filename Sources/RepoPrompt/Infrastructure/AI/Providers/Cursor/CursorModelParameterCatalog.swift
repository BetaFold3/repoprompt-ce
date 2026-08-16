import Foundation

extension Notification.Name {
    static let cursorModelParameterCatalogDidChange = Notification.Name(
        "RepoPromptCursorModelParameterCatalogDidChange"
    )
    static let cursorModelParameterCatalogStatusDidChange = Notification.Name(
        "RepoPromptCursorModelParameterCatalogStatusDidChange"
    )
}

final class CursorModelParameterCatalog: @unchecked Sendable {
    struct Option: Equatable {
        let value: String
        let name: String
    }

    struct ParameterSpec: Equatable {
        let id: String
        let category: String
        let defaultValue: String
        let options: [Option]
        let description: String?
    }

    enum ApplyResult: Equatable {
        case applied(didChange: Bool)
        case rejectedMalformed
    }

    enum FailureKind: String, Equatable {
        case authentication
        case timeout
        case malformedResponse
        case discovery
        case `extension`
    }

    enum State: Equatable {
        case idle
        case cached
        case refreshing
        case live
        case stale(FailureKind)
        case unsupported
        case disabled
    }

    struct Status: Equatable {
        let state: State
        let hasUsableCatalog: Bool
        let lastSuccessfulRefresh: Date?
        let lastAttempt: Date?
    }

    static let shared = CursorModelParameterCatalog(
        store: CursorModelParameterStore(defaults: .standard)
    )

    private let lock = NSLock()
    private let mutationLock = NSLock()
    private let hydrationLock = NSLock()
    private let notificationCenter: NotificationCenter
    private let store: CursorModelParameterStore
    private var parametersByBase: [String: [ParameterSpec]] = [:]
    private var statusSnapshot = Status(
        state: .idle,
        hasUsableCatalog: false,
        lastSuccessfulRefresh: nil,
        lastAttempt: nil
    )
    private var isHydrated = false

    init(
        store: CursorModelParameterStore = .transient(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
    }

    func hydrateSynchronously() {
        hydrationLock.lock()
        defer { hydrationLock.unlock() }

        lock.lock()
        let alreadyHydrated = isHydrated
        lock.unlock()
        guard !alreadyHydrated else { return }

        if let stored = store.load() {
            _ = replace(
                with: stored.models,
                persist: false,
                updatedAt: stored.updatedAt,
                statusState: .cached,
                successfulRefresh: stored.updatedAt,
                attempt: nil,
                markHydrated: true,
                shouldPostNotifications: false
            )
        } else {
            lock.lock()
            isHydrated = true
            lock.unlock()
        }
    }

    func parameterSpecs(forModel rawModel: String) -> [ParameterSpec]? {
        hydrateSynchronously()
        let base = Self.normalizedBase(rawModel)
        lock.lock()
        defer { lock.unlock() }
        return parametersByBase[base]
    }

    func currentSnapshot() -> [String: [ParameterSpec]] {
        hydrateSynchronously()
        lock.lock()
        defer { lock.unlock() }
        return parametersByBase
    }

    func status() -> Status {
        hydrateSynchronously()
        lock.lock()
        defer { lock.unlock() }
        return statusSnapshot
    }

    @discardableResult
    func test_restoreSnapshot(_ snapshot: [String: [ParameterSpec]]) -> Bool {
        hydrationLock.lock()

        lock.lock()
        let previousStatus = statusSnapshot
        lock.unlock()

        let didChange = replace(
            with: snapshot,
            persist: false,
            updatedAt: nil,
            statusState: nil,
            successfulRefresh: nil,
            attempt: nil,
            markHydrated: true,
            shouldPostNotifications: false
        )

        lock.lock()
        let statusDidChange = statusSnapshot != previousStatus
        lock.unlock()

        hydrationLock.unlock()
        postNotifications(
            dataDidChange: didChange,
            statusDidChange: statusDidChange
        )
        return didChange
    }

    func uniqueThoughtLevelParameterSpec(forModel rawModel: String) -> ParameterSpec? {
        let matches = parameterSpecs(forModel: rawModel)?
            .filter { $0.category == "thought_level" } ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func uniqueThoughtLevelParameterID(forModel rawModel: String) -> String? {
        uniqueThoughtLevelParameterSpec(forModel: rawModel)?.id
    }

    @discardableResult
    func apply(response: Any) -> ApplyResult {
        hydrateSynchronously()
        let attemptedAt = Date()

        switch Self.parse(response: response) {
        case let .valid(parsed):
            let didChange = replace(
                with: parsed,
                persist: true,
                updatedAt: attemptedAt,
                statusState: .live,
                successfulRefresh: attemptedAt,
                attempt: attemptedAt
            )
            return .applied(didChange: didChange)
        case .malformed:
            markStale(.malformedResponse, at: attemptedAt)
            return .rejectedMalformed
        }
    }

    @discardableResult
    func clearForMethodNotFound(at attemptedAt: Date = Date()) -> Bool {
        hydrateSynchronously()
        return replace(
            with: [:],
            persist: true,
            updatedAt: attemptedAt,
            statusState: .unsupported,
            successfulRefresh: nil,
            attempt: attemptedAt
        )
    }

    func markRefreshing(at attemptedAt: Date = Date()) {
        transitionStatus(to: .refreshing, attempt: attemptedAt)
    }

    func markLive(at refreshedAt: Date = Date()) {
        transitionStatus(
            to: .live,
            successfulRefresh: refreshedAt,
            attempt: refreshedAt
        )
    }

    func markStale(_ kind: FailureKind, at attemptedAt: Date = Date()) {
        transitionStatus(to: .stale(kind), attempt: attemptedAt)
    }

    func markUnsupported(at attemptedAt: Date = Date()) {
        transitionStatus(to: .unsupported, attempt: attemptedAt)
    }

    func markDisabled() {
        transitionStatus(to: .disabled)
    }

    func markIdle() {
        transitionStatus(to: .idle)
    }

    private func replace(
        with updated: [String: [ParameterSpec]],
        persist: Bool,
        updatedAt: Date?,
        statusState: State?,
        successfulRefresh: Date?,
        attempt: Date?,
        markHydrated: Bool = false,
        shouldPostNotifications: Bool = true
    ) -> Bool {
        mutationLock.lock()

        lock.lock()
        let dataDidChange = parametersByBase != updated
        if dataDidChange {
            parametersByBase = updated
        }
        if markHydrated {
            isHydrated = true
        }

        let updatedStatus = Status(
            state: statusState ?? statusSnapshot.state,
            hasUsableCatalog: !updated.isEmpty,
            lastSuccessfulRefresh: successfulRefresh ?? statusSnapshot.lastSuccessfulRefresh,
            lastAttempt: attempt ?? statusSnapshot.lastAttempt
        )
        let statusDidChange = statusSnapshot != updatedStatus
        if statusDidChange {
            statusSnapshot = updatedStatus
        }
        lock.unlock()

        if persist {
            if updated.isEmpty {
                store.clear()
            } else {
                _ = store.save(updated, updatedAt: updatedAt ?? Date())
            }
        }

        mutationLock.unlock()

        if shouldPostNotifications {
            postNotifications(
                dataDidChange: dataDidChange,
                statusDidChange: statusDidChange
            )
        }
        return dataDidChange
    }

    private func transitionStatus(
        to state: State,
        successfulRefresh: Date? = nil,
        attempt: Date? = nil
    ) {
        hydrateSynchronously()
        mutationLock.lock()

        lock.lock()
        let updated = Status(
            state: state,
            hasUsableCatalog: !parametersByBase.isEmpty,
            lastSuccessfulRefresh: successfulRefresh ?? statusSnapshot.lastSuccessfulRefresh,
            lastAttempt: attempt ?? statusSnapshot.lastAttempt
        )
        let didChange = statusSnapshot != updated
        if didChange {
            statusSnapshot = updated
        }
        lock.unlock()

        mutationLock.unlock()

        if didChange {
            notificationCenter.post(
                name: .cursorModelParameterCatalogStatusDidChange,
                object: self
            )
        }
    }

    private func postNotifications(dataDidChange: Bool, statusDidChange: Bool) {
        if dataDidChange {
            notificationCenter.post(name: .cursorModelParameterCatalogDidChange, object: self)
        }
        if statusDidChange {
            notificationCenter.post(
                name: .cursorModelParameterCatalogStatusDidChange,
                object: self
            )
        }
    }

    private enum ParseResult {
        case valid([String: [ParameterSpec]])
        case malformed
    }

    private enum ParameterParseResult {
        case select(ParameterSpec)
        case skip
        case malformed
    }

    private static func parse(response: Any) -> ParseResult {
        let rawModels: [Any]
        if let models = response as? [Any] {
            rawModels = models
        } else if let object = response as? [String: Any],
                  let modelsValue = object["models"],
                  let models = modelsValue as? [Any]
        {
            rawModels = models
        } else {
            return .malformed
        }

        var parsed: [String: [ParameterSpec]] = [:]
        for rawModel in rawModels {
            guard let model = rawModel as? [String: Any],
                  let rawBase = nonemptyString(model["value"])
            else {
                return .malformed
            }

            let base = normalizedBase(rawBase)
            guard !base.isEmpty, parsed[base] == nil else {
                return .malformed
            }

            let rawConfigOptions: [Any]
            if let configOptions = model["configOptions"] {
                guard let options = configOptions as? [Any] else {
                    return .malformed
                }
                rawConfigOptions = options
            } else {
                rawConfigOptions = []
            }

            var specs: [ParameterSpec] = []
            var selectIDs = Set<String>()
            for rawOption in rawConfigOptions {
                switch parseParameterSpec(rawOption) {
                case let .select(spec):
                    guard selectIDs.insert(spec.id.lowercased()).inserted else {
                        return .malformed
                    }
                    specs.append(spec)
                case .skip:
                    continue
                case .malformed:
                    return .malformed
                }
            }
            parsed[base] = specs
        }
        return .valid(parsed)
    }

    private static func parseParameterSpec(_ raw: Any) -> ParameterParseResult {
        guard let object = raw as? [String: Any],
              let type = nonemptyString(object["type"])
        else {
            return .malformed
        }
        guard type == "select" else { return .skip }

        guard let id = nonemptyString(object["id"]),
              let category = nonemptyString(object["category"]),
              let defaultValue = nonemptyString(object["currentValue"]),
              let rawOptions = object["options"] as? [Any]
        else {
            return .malformed
        }

        if let rawDescription = object["description"], !(rawDescription is String) {
            return .malformed
        }

        var options: [Option] = []
        var optionValues = Set<String>()
        for rawOption in rawOptions {
            guard let option = rawOption as? [String: Any],
                  let value = nonemptyString(option["value"]),
                  let name = nonemptyString(option["name"]),
                  optionValues.insert(value).inserted
            else {
                return .malformed
            }
            options.append(Option(value: value, name: name))
        }
        guard !options.isEmpty, options.contains(where: { $0.value == defaultValue }) else {
            return .malformed
        }

        return .select(ParameterSpec(
            id: id,
            category: category,
            defaultValue: defaultValue,
            options: options,
            description: nonemptyString(object["description"])
        ))
    }

    static func normalizedBase(_ raw: String) -> String {
        let stripped = CursorBracketModelID.strippingCursorPrefix(raw)
        return (CursorBracketModelID.parse(stripped)?.base ?? stripped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
