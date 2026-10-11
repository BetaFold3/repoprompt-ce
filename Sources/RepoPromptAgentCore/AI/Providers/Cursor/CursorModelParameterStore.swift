import Foundation

final class CursorModelParameterStore: @unchecked Sendable {
    struct Snapshot: Equatable {
        let updatedAt: Date
        let models: [String: [CursorModelParameterCatalog.ParameterSpec]]
    }

    static let storageKey = "CursorModelParameterCatalogV1"

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let updatedAt: Date
        let models: [ModelRecord]
    }

    private struct ModelRecord: Codable {
        let base: String
        let parameters: [ParameterRecord]
    }

    private struct ParameterRecord: Codable {
        let id: String
        let category: String
        let defaultValue: String
        let options: [OptionRecord]
        let description: String?
    }

    private struct OptionRecord: Codable {
        let value: String
        let name: String
    }

    private let defaults: UserDefaults
    private let cleanupSuiteName: String?
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cleanupSuiteName = nil
    }

    private init(defaults: UserDefaults, cleanupSuiteName: String) {
        self.defaults = defaults
        self.cleanupSuiteName = cleanupSuiteName
    }

    deinit {
        if let cleanupSuiteName {
            defaults.removePersistentDomain(forName: cleanupSuiteName)
        }
    }

    static func transient() -> CursorModelParameterStore {
        let suiteName = "CursorModelParameterStore.Transient.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated Cursor model parameter defaults")
        }
        return CursorModelParameterStore(
            defaults: defaults,
            cleanupSuiteName: suiteName
        )
    }

    func load() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: Self.storageKey),
              let version = try? JSONDecoder().decode(VersionProbe.self, from: data),
              version.schemaVersion == 1,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let models = Self.catalogModels(from: envelope.models),
              !models.isEmpty
        else {
            return nil
        }
        return Snapshot(updatedAt: envelope.updatedAt, models: models)
    }

    @discardableResult
    func save(
        _ models: [String: [CursorModelParameterCatalog.ParameterSpec]],
        updatedAt: Date = Date()
    ) -> Bool {
        guard let records = Self.canonicalRecords(from: models), !records.isEmpty else {
            return false
        }

        let envelope = Envelope(schemaVersion: 1, updatedAt: updatedAt, models: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope) else { return false }

        lock.lock()
        defaults.set(data, forKey: Self.storageKey)
        lock.unlock()
        return true
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: Self.storageKey),
              let version = try? JSONDecoder().decode(VersionProbe.self, from: data),
              version.schemaVersion == 1,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              Self.catalogModels(from: envelope.models) != nil
        else {
            return
        }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func canonicalRecords(
        from models: [String: [CursorModelParameterCatalog.ParameterSpec]]
    ) -> [ModelRecord]? {
        var records: [ModelRecord] = []
        var seenBases = Set<String>()

        for (rawBase, parameters) in models {
            let base = CursorModelParameterCatalog.normalizedBase(rawBase)
            guard !base.isEmpty, seenBases.insert(base).inserted else { return nil }
            records.append(ModelRecord(
                base: base,
                parameters: parameters.map { parameter in
                    ParameterRecord(
                        id: parameter.id,
                        category: parameter.category,
                        defaultValue: parameter.defaultValue,
                        options: parameter.options.map {
                            OptionRecord(value: $0.value, name: $0.name)
                        },
                        description: parameter.description
                    )
                }
            ))
        }

        guard let canonicalModels = catalogModels(from: records) else { return nil }
        return canonicalModels.map { base, parameters in
            ModelRecord(
                base: base,
                parameters: parameters.map { parameter in
                    ParameterRecord(
                        id: parameter.id,
                        category: parameter.category,
                        defaultValue: parameter.defaultValue,
                        options: parameter.options.map {
                            OptionRecord(value: $0.value, name: $0.name)
                        },
                        description: parameter.description
                    )
                }
            )
        }.sorted { $0.base < $1.base }
    }

    private static func catalogModels(
        from records: [ModelRecord]
    ) -> [String: [CursorModelParameterCatalog.ParameterSpec]]? {
        var models: [String: [CursorModelParameterCatalog.ParameterSpec]] = [:]

        for record in records {
            let base = CursorModelParameterCatalog.normalizedBase(record.base)
            guard !base.isEmpty, models[base] == nil else { return nil }

            var seenIDs = Set<String>()
            var parameters: [CursorModelParameterCatalog.ParameterSpec] = []
            for parameter in record.parameters {
                let id = parameter.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let category = parameter.category.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultValue = parameter.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty,
                      !category.isEmpty,
                      !defaultValue.isEmpty,
                      seenIDs.insert(id.lowercased()).inserted
                else {
                    return nil
                }

                var seenValues = Set<String>()
                var options: [CursorModelParameterCatalog.Option] = []
                for option in parameter.options {
                    let value = option.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty,
                          !name.isEmpty,
                          seenValues.insert(value).inserted
                    else {
                        return nil
                    }
                    options.append(.init(value: value, name: name))
                }
                guard !options.isEmpty, options.contains(where: { $0.value == defaultValue }) else {
                    return nil
                }

                let description = parameter.description?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parameters.append(.init(
                    id: id,
                    category: category,
                    defaultValue: defaultValue,
                    options: options,
                    description: description?.isEmpty == true ? nil : description
                ))
            }
            models[base] = parameters
        }
        return models
    }
}
