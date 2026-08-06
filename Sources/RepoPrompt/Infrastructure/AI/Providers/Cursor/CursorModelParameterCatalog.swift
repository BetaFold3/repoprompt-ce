import Foundation

extension Notification.Name {
    static let cursorModelParameterCatalogDidChange = Notification.Name(
        "RepoPromptCursorModelParameterCatalogDidChange"
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

    static let shared = CursorModelParameterCatalog()

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var parametersByBase: [String: [ParameterSpec]] = [:]

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func parameterSpecs(forModel rawModel: String) -> [ParameterSpec]? {
        let base = Self.normalizedBase(rawModel)
        lock.lock()
        defer { lock.unlock() }
        return parametersByBase[base]
    }

    func currentSnapshot() -> [String: [ParameterSpec]] {
        lock.lock()
        defer { lock.unlock() }
        return parametersByBase
    }

    @discardableResult
    func test_restoreSnapshot(_ snapshot: [String: [ParameterSpec]]) -> Bool {
        replace(with: snapshot)
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
    func apply(response: Any) -> Bool {
        switch Self.parse(response: response) {
        case let .valid(parsed):
            replace(with: parsed)
        case .malformed:
            replace(with: [:])
        }
    }

    @discardableResult
    func clearForMethodNotFound() -> Bool {
        replace(with: [:])
    }

    private func replace(with updated: [String: [ParameterSpec]]) -> Bool {
        lock.lock()
        let didChange = parametersByBase != updated
        if didChange {
            parametersByBase = updated
        }
        lock.unlock()

        if didChange {
            notificationCenter.post(name: .cursorModelParameterCatalogDidChange, object: self)
        }
        return didChange
    }

    private enum ParseResult {
        case valid([String: [ParameterSpec]])
        case malformed
    }

    private static func parse(response: Any) -> ParseResult {
        let rawModels: [Any]
        if let models = response as? [Any] {
            rawModels = models
        } else if let object = response as? [String: Any],
                  let models = object["models"] as? [Any]
        {
            rawModels = models
        } else {
            return .malformed
        }

        var parsed: [String: [ParameterSpec]] = [:]
        var parsedModelCount = 0
        for rawModel in rawModels {
            guard let model = rawModel as? [String: Any],
                  let rawBase = nonemptyString(model["value"]),
                  parsed[normalizedBase(rawBase)] == nil,
                  let rawConfigOptions = model["configOptions"] as? [Any]
            else {
                continue
            }

            parsedModelCount += 1
            let specs = rawConfigOptions.compactMap(parseParameterSpec)
            parsed[normalizedBase(rawBase)] = specs
        }
        guard rawModels.isEmpty || parsedModelCount > 0 else {
            return .malformed
        }
        return .valid(parsed)
    }

    private static func parseParameterSpec(_ raw: Any) -> ParameterSpec? {
        guard let object = raw as? [String: Any],
              object["type"] as? String == "select",
              let id = nonemptyString(object["id"]),
              let category = nonemptyString(object["category"]),
              let defaultValue = nonemptyString(object["currentValue"]),
              let rawOptions = object["options"] as? [Any]
        else {
            return nil
        }

        let options = rawOptions.compactMap { rawOption -> Option? in
            guard let option = rawOption as? [String: Any],
                  let value = nonemptyString(option["value"]),
                  let name = nonemptyString(option["name"])
            else {
                return nil
            }
            return Option(value: value, name: name)
        }
        guard !options.isEmpty else { return nil }

        return ParameterSpec(
            id: id,
            category: category,
            defaultValue: defaultValue,
            options: options,
            description: nonemptyString(object["description"])
        )
    }

    private static func normalizedBase(_ raw: String) -> String {
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
