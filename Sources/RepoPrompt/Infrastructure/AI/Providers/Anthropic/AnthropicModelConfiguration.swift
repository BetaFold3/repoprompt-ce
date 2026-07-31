import Foundation

enum AnthropicEffort: String, CaseIterable, Codable {
    case low
    case medium
    case high
    case xhigh
    case max
}

enum AnthropicThinkingConfiguration: Equatable {
    case none
    case enabled(budgetTokens: Int)
    case adaptive

    var suppressesSamplingParameters: Bool {
        self != .none
    }
}

enum AnthropicModelConfigurationError: Error, Equatable {
    case unsupportedEffort(modelID: String, effort: AnthropicEffort)
    case insufficientMaxTokens(modelID: String, budgetTokens: Int, maxTokens: Int)
}

struct AnthropicModelConfiguration: Equatable {
    static let claudeOpus5ModelID = "claude-opus-5"

    let apiModelID: String
    let thinking: AnthropicThinkingConfiguration
    let effort: AnthropicEffort?
    let defaultMaxTokens: Int?

    static func resolve(
        modelID: String,
        effort requestedEffort: AnthropicEffort? = nil
    ) throws -> AnthropicModelConfiguration {
        let legacy = legacyThinkingConfiguration(for: modelID)

        if legacy.baseModelID == claudeOpus5ModelID {
            return AnthropicModelConfiguration(
                apiModelID: claudeOpus5ModelID,
                thinking: .adaptive,
                effort: requestedEffort ?? .high,
                defaultMaxTokens: nil
            )
        }

        if let requestedEffort {
            throw AnthropicModelConfigurationError.unsupportedEffort(
                modelID: legacy.baseModelID,
                effort: requestedEffort
            )
        }

        return AnthropicModelConfiguration(
            apiModelID: legacy.baseModelID,
            thinking: legacy.thinking,
            effort: nil,
            defaultMaxTokens: legacy.defaultMaxTokens
        )
    }

    private static func legacyThinkingConfiguration(
        for modelID: String
    ) -> (baseModelID: String, thinking: AnthropicThinkingConfiguration, defaultMaxTokens: Int?) {
        if modelID.hasSuffix("-thinking-max") {
            return (
                String(modelID.dropLast("-thinking-max".count)),
                .enabled(budgetTokens: 32000),
                64000
            )
        }

        if modelID.hasSuffix("-thinking") {
            let baseModelID = String(modelID.dropLast("-thinking".count))
            return (
                baseModelID,
                .enabled(budgetTokens: 16000),
                baseModelID.contains("opus") ? 32000 : 64000
            )
        }

        return (modelID, .none, nil)
    }
}
