import Foundation

/// Destination-owned Oh My Pi thinking selections keyed by the exact upstream wire model ID.
///
/// Key absence is the Default state and sends no thinking configuration. Reads never update
/// recency; only explicit writes replace `updatedAt`.
struct OhMyPiThinkingSelections: Codable, Equatable {
    struct ThinkingChoice: Codable, Equatable {
        let value: String
        let updatedAt: Date

        init(value: String, updatedAt: Date) {
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    static let maximumEntryCount = 32
    static let empty = OhMyPiThinkingSelections()

    private(set) var entries: [String: ThinkingChoice]

    init(entries: [String: ThinkingChoice] = [:]) {
        self.entries = Self.bounded(entries)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var count: Int {
        entries.count
    }

    var nilIfEmpty: OhMyPiThinkingSelections? {
        isEmpty ? nil : self
    }

    subscript(exactWireModelID: String) -> ThinkingChoice? {
        entries[exactWireModelID]
    }

    func value(for exactWireModelID: String) -> String? {
        entries[exactWireModelID]?.value
    }

    func assignment(for exactWireModelID: String) -> ACPConfigOptionAssignment? {
        value(for: exactWireModelID).map(ACPConfigOptionAssignment.ohMyPiThinking)
    }

    /// Applies an explicit user write. Passing nil clears the exact model entry.
    ///
    /// Neither the model ID nor value is normalized; exact upstream identity is preserved.
    mutating func setValue(
        _ value: String?,
        for exactWireModelID: String,
        updatedAt: Date = Date()
    ) {
        guard let value else {
            entries[exactWireModelID] = nil
            return
        }
        entries[exactWireModelID] = ThinkingChoice(value: value, updatedAt: updatedAt)
        entries = Self.bounded(entries)
    }

    mutating func removeValue(for exactWireModelID: String) {
        entries[exactWireModelID] = nil
    }

    private static func bounded(
        _ entries: [String: ThinkingChoice]
    ) -> [String: ThinkingChoice] {
        guard entries.count > maximumEntryCount else { return entries }
        let evictionOrder = entries.sorted { lhs, rhs in
            if lhs.value.updatedAt != rhs.value.updatedAt {
                return lhs.value.updatedAt < rhs.value.updatedAt
            }
            return lhs.key < rhs.key
        }
        let evictedKeys = Set(evictionOrder.prefix(entries.count - maximumEntryCount).map(\.key))
        return entries.filter { !evictedKeys.contains($0.key) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        entries = try Self.bounded(container.decode([String: ThinkingChoice].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    static func decodeIfPresent<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> OhMyPiThinkingSelections {
        try container.decodeIfPresent(OhMyPiThinkingSelections.self, forKey: key) ?? .empty
    }

    func encodeIfNonEmpty<Key: CodingKey>(
        to container: inout KeyedEncodingContainer<Key>,
        forKey key: Key
    ) throws {
        guard !isEmpty else { return }
        try container.encode(self, forKey: key)
    }
}

enum OhMyPiCanonicalModelIdentity {
    static func exactWireID(
        for rawModelID: String,
        snapshot: ACPDiscoveredSessionModels? = AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi)
    ) -> String? {
        let trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }
        return snapshot?.option(matching: trimmed)?.rawValue ?? trimmed
    }

    static func exactWireID(for model: AIModel) -> String? {
        guard case let .ohMyPiCustom(rawModelID) = model else { return nil }
        return exactWireID(for: rawModelID)
    }
}

enum OhMyPiThinkingExecutionEligibility {
    static func allowsAssignment(
        for exactWireModelID: String,
        snapshot: ACPDiscoveredSessionModels? = AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi)
    ) -> Bool {
        guard let snapshot else { return true }
        let projection = OhMyPiModelMenuProjector.project(snapshot.options.enumerated().map { index, option in
            OhMyPiModelMenuProjector.Input(
                sourceID: String(index),
                wireID: option.rawValue,
                displayName: option.displayName
            )
        })
        let matchingLeaves = projection.allLeaves.filter { $0.wireID == exactWireModelID }
        guard matchingLeaves.count == 1, let leaf = matchingLeaves.first else {
            return true
        }
        return leaf.allowsThinkingAccessory
    }
}

extension OhMyPiThinkingSelections {
    func assignments(for model: AIModel) -> [ACPConfigOptionAssignment] {
        guard let exactWireModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: model),
              OhMyPiThinkingExecutionEligibility.allowsAssignment(for: exactWireModelID),
              let assignment = assignment(for: exactWireModelID)
        else {
            return []
        }
        return [assignment]
    }

    func executionMetadata(for model: AIModel) -> AIMessageExecutionMetadata {
        AIMessageExecutionMetadata(additionalACPConfigOptionValues: assignments(for: model))
    }
}

/// Advertised thinking option identity used by destination-intent resolution.
///
/// Display names are presentation only. Checkmarks always resolve by exact raw value, so two
/// options may share a display name without becoming ambiguous.
struct OhMyPiThinkingAdvertisedOption: Equatable {
    let value: String
    let displayName: String
}

struct OhMyPiThinkingAdvertisedCapabilities: Equatable {
    let options: [OhMyPiThinkingAdvertisedOption]
    let isAuthoritative: Bool
}

/// Checkmark/warning intent derived solely from destination state and capability input.
enum OhMyPiThinkingDestinationIntent: Equatable {
    case defaultSelection
    case advertised(optionIndex: Int, value: String)
    case unavailable(rawValue: String)
    case capabilityUnknown(rawValue: String)

    static func resolve(
        choice: OhMyPiThinkingSelections.ThinkingChoice?,
        capabilities: OhMyPiThinkingAdvertisedCapabilities?
    ) -> OhMyPiThinkingDestinationIntent {
        guard let choice else { return .defaultSelection }
        guard let capabilities else {
            return .capabilityUnknown(rawValue: choice.value)
        }
        if let index = capabilities.options.firstIndex(where: { $0.value == choice.value }) {
            return .advertised(optionIndex: index, value: choice.value)
        }
        if capabilities.isAuthoritative {
            return .unavailable(rawValue: choice.value)
        }
        return .capabilityUnknown(rawValue: choice.value)
    }
}
