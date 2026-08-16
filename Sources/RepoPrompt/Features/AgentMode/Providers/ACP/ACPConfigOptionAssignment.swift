import Foundation

/// A typed ACP configuration selector owned by one provider.
///
/// Keeping provider ownership and wire metadata on the key prevents provider-specific
/// values from being silently forwarded to another ACP runtime.
enum ACPConfigOptionKey: String, Equatable {
    case ohMyPiThinking

    var configID: String {
        switch self {
        case .ohMyPiThinking:
            "thinking"
        }
    }

    var category: String {
        switch self {
        case .ohMyPiThinking:
            "thought_level"
        }
    }

    var allowedProviderID: ACPProviderID {
        switch self {
        case .ohMyPiThinking:
            .ohMyPi
        }
    }
}

struct ACPConfigOptionAssignment: Equatable {
    let key: ACPConfigOptionKey
    let value: String

    var configID: String {
        key.configID
    }

    var category: String {
        key.category
    }

    static func ohMyPiThinking(_ value: String) -> ACPConfigOptionAssignment {
        ACPConfigOptionAssignment(key: .ohMyPiThinking, value: value)
    }

    static func validate(
        _ assignments: [ACPConfigOptionAssignment],
        for providerID: ACPProviderID
    ) throws {
        var seenKeys = Set<ACPConfigOptionKey>()
        for assignment in assignments {
            guard assignment.key.allowedProviderID == providerID else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Internal configuration error: ACP option '\(assignment.configID)' is only valid for \(assignment.key.allowedProviderID.rawValue), not \(providerID.rawValue)."
                )
            }
            guard !assignment.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Internal configuration error: ACP option '\(assignment.configID)' has an empty value."
                )
            }
            guard seenKeys.insert(assignment.key).inserted else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Internal configuration error: ACP option '\(assignment.configID)' was assigned more than once."
                )
            }
        }
    }
}

/// Sequence-authoritative OMP capability observation. T5 can inject a publisher without
/// making this seam a second persistence authority.
struct OhMyPiThinkingCapabilityRecord: Equatable {
    let modelID: String
    let configID: String
    let category: String
    let orderedOptions: [String]
    let optionDisplayNames: [String]

    init(
        modelID: String,
        configID: String,
        category: String,
        orderedOptions: [String],
        optionDisplayNames: [String]? = nil
    ) {
        self.modelID = modelID
        self.configID = configID
        self.category = category
        self.orderedOptions = orderedOptions
        self.optionDisplayNames = optionDisplayNames ?? orderedOptions
    }
}

typealias OhMyPiThinkingCapabilityPublisher = @Sendable (OhMyPiThinkingCapabilityRecord) -> Void
