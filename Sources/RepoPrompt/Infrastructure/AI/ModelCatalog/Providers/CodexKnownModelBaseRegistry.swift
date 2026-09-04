import Foundation

struct CodexModelCapabilitySnapshot: Equatable {
    struct Capability: Equatable {
        let base: String
        let efforts: Set<CodexReasoningEffort>
        let speedTiers: Set<String>
    }

    let capabilitiesByBase: [String: Capability]
    let knownBasesLongestFirst: [Capability]

    init(capabilities: [Capability]) {
        var values: [String: Capability] = [:]
        for capability in capabilities {
            let normalizedBase = capability.base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedBase.isEmpty else { continue }
            values[normalizedBase] = Capability(
                base: capability.base.trimmingCharacters(in: .whitespacesAndNewlines),
                efforts: capability.efforts,
                speedTiers: Set(capability.speedTiers.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty })
            )
        }
        capabilitiesByBase = values
        knownBasesLongestFirst = values.values.sorted {
            if $0.base.count != $1.base.count {
                return $0.base.count > $1.base.count
            }
            return $0.base.localizedCaseInsensitiveCompare($1.base) == .orderedAscending
        }
    }

    func capability(forBase base: String) -> Capability? {
        capabilitiesByBase[base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    static var shared: CodexModelCapabilitySnapshot {
        CodexKnownModelBaseRegistry.shared.capabilitySnapshot()
    }

    static let seedOnly = CodexModelCapabilitySnapshot(
        capabilities: CodexKnownModelBaseRegistry.seedEntries.map(\.capability)
    )
}

struct CodexKnownModelServiceTier: Codable, Hashable {
    let id: String
    let name: String
    let description: String
}

struct CodexKnownModelBaseEntry: Codable, Hashable {
    enum Source: String, Codable {
        case seed
        case observed
    }

    let base: String
    let efforts: [String]
    let additionalSpeedTiers: [String]
    let serviceTiers: [CodexKnownModelServiceTier]
    let source: Source
    let lastSeen: Date?

    fileprivate var capability: CodexModelCapabilitySnapshot.Capability {
        CodexModelCapabilitySnapshot.Capability(
            base: base,
            efforts: Set(efforts.compactMap(CodexReasoningEffort.parse)),
            speedTiers: Set(additionalSpeedTiers)
        )
    }
}

final class CodexKnownModelBaseRegistry {
    static let shared = CodexKnownModelBaseRegistry()
    static let schemaVersion = 1
    static let maximumEntryCount = 2048
    static let storageKey = "CodexKnownModelBases"

    fileprivate static let seedEntries: [CodexKnownModelBaseEntry] = {
        let definitions: [(String, [String], [String])] = [
            ("gpt-5.6", ["max", "ultra"], []),
            ("gpt-5.6-sol", ["max", "ultra"], ["fast"]),
            ("gpt-5.6-terra", ["max", "ultra"], ["fast"]),
            ("gpt-5.6-luna", ["max"], ["fast"]),
            ("gpt-5.5", [], ["fast"]),
            ("gpt-5.4", [], ["fast"]),
            ("gpt-5.4-mini", [], []),
            ("gpt-5.3-codex", [], []),
            ("gpt-5.2", [], []),
            ("gpt-5.1-mini", [], []),
            ("gpt-5.1-codex-mini", [], []),
            ("gpt-5.1-codex-max", [], [])
        ]
        return definitions.map { base, efforts, speedTiers in
            CodexKnownModelBaseEntry(
                base: base,
                efforts: efforts,
                additionalSpeedTiers: speedTiers,
                serviceTiers: [],
                source: .seed,
                lastSeen: nil
            )
        }
    }()

    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [CodexKnownModelBaseEntry]
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let allowsPersistence: Bool
    private var entriesByBase: [String: CodexKnownModelBaseEntry]
    private var cachedSnapshot: CodexModelCapabilitySnapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let seed = Dictionary(uniqueKeysWithValues: Self.seedEntries.map {
            ($0.base.lowercased(), $0)
        })
        let initialEntries: [String: CodexKnownModelBaseEntry]
        let permitsPersistence: Bool

        if let data = defaults.data(forKey: Self.storageKey) {
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.schemaVersion == Self.schemaVersion
            {
                var loaded = seed
                for entry in envelope.entries {
                    let key = entry.base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !key.isEmpty else { continue }
                    loaded[key] = Self.canonicalEntry(entry)
                }
                initialEntries = Self.boundedEntries(loaded)
                permitsPersistence = true
            } else {
                initialEntries = seed
                permitsPersistence = false
            }
        } else {
            var migrated = seed
            for record in CodexDynamicModelStore.load(defaults: defaults) {
                let key = record.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }
                migrated[key] = Self.mergedObservedEntry(
                    from: record,
                    previous: migrated[key],
                    seenAt: nil
                )
            }
            initialEntries = Self.boundedEntries(migrated)
            permitsPersistence = true
        }

        entriesByBase = initialEntries
        cachedSnapshot = Self.snapshot(from: initialEntries)
        allowsPersistence = permitsPersistence
    }

    func capabilitySnapshot() -> CodexModelCapabilitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cachedSnapshot
    }

    func entries() -> [CodexKnownModelBaseEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByBase.values.sorted {
            $0.base.localizedCaseInsensitiveCompare($1.base) == .orderedAscending
        }
    }

    func unionObserved(records: [CodexDynamicModelRecord], seenAt: Date = Date()) {
        guard !records.isEmpty else { return }
        lock.lock()
        var updated = entriesByBase
        for record in records {
            let key = record.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            updated[key] = Self.mergedObservedEntry(
                from: record,
                previous: updated[key],
                seenAt: seenAt
            )
        }
        updated = Self.boundedEntries(updated)
        entriesByBase = updated
        cachedSnapshot = Self.snapshot(from: updated)
        lock.unlock()
        if allowsPersistence {
            Self.persist(updated, defaults: defaults)
        }
    }

    private static func mergedObservedEntry(
        from record: CodexDynamicModelRecord,
        previous: CodexKnownModelBaseEntry?,
        seenAt: Date?
    ) -> CodexKnownModelBaseEntry {
        let base = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let observedEfforts = Set(record.supportedReasoningEfforts.map(\.reasoningEffort))
        let efforts = Set(previous?.efforts ?? []).union(observedEfforts)
        let speedTiers = record.hasAdditionalSpeedTiersEvidence
            ? record.additionalSpeedTiers
            : previous?.additionalSpeedTiers ?? []
        let serviceTiers = record.hasServiceTiersEvidence
            ? record.serviceTiers.map {
                CodexKnownModelServiceTier(id: $0.id, name: $0.name, description: $0.description)
            }
            : previous?.serviceTiers ?? []
        return canonicalEntry(CodexKnownModelBaseEntry(
            base: base,
            efforts: Array(efforts),
            additionalSpeedTiers: speedTiers,
            serviceTiers: serviceTiers,
            source: .observed,
            lastSeen: seenAt
        ))
    }

    private static func snapshot(
        from entries: [String: CodexKnownModelBaseEntry]
    ) -> CodexModelCapabilitySnapshot {
        CodexModelCapabilitySnapshot(capabilities: entries.values.map(\.capability))
    }

    private static func canonicalEntry(_ entry: CodexKnownModelBaseEntry) -> CodexKnownModelBaseEntry {
        let efforts = Set(entry.efforts.compactMap(CodexReasoningEffort.parse).map(\.rawValue))
        let speedTiers = Set(entry.additionalSpeedTiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        var serviceTiersByID: [String: CodexKnownModelServiceTier] = [:]
        for tier in entry.serviceTiers {
            let id = tier.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { continue }
            serviceTiersByID[id] = CodexKnownModelServiceTier(
                id: id,
                name: tier.name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: tier.description.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return CodexKnownModelBaseEntry(
            base: entry.base.trimmingCharacters(in: .whitespacesAndNewlines),
            efforts: CodexReasoningEffort.displayOrder.map(\.rawValue).filter(efforts.contains),
            additionalSpeedTiers: speedTiers.sorted(),
            serviceTiers: serviceTiersByID.values.sorted { $0.id < $1.id },
            source: entry.source,
            lastSeen: entry.lastSeen
        )
    }

    private static func boundedEntries(
        _ entries: [String: CodexKnownModelBaseEntry]
    ) -> [String: CodexKnownModelBaseEntry] {
        guard entries.count > maximumEntryCount else { return entries }
        let seedKeys = Set(seedEntries.map { $0.base.lowercased() })
        let observed = entries.filter { !seedKeys.contains($0.key) }.sorted {
            ($0.value.lastSeen ?? .distantPast) > ($1.value.lastSeen ?? .distantPast)
        }
        var output = entries.filter { seedKeys.contains($0.key) }
        for (key, value) in observed.prefix(maximumEntryCount - output.count) {
            output[key] = value
        }
        return output
    }

    private static func persist(
        _ entries: [String: CodexKnownModelBaseEntry],
        defaults: UserDefaults
    ) {
        let ordered = entries.values.sorted {
            $0.base.localizedCaseInsensitiveCompare($1.base) == .orderedAscending
        }
        guard let data = try? JSONEncoder().encode(
            Envelope(schemaVersion: schemaVersion, entries: ordered)
        ) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
