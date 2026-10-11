import Foundation
import RepoPromptPlatform

package enum ClaudeCodeCompatibleBackendID: String, CaseIterable, Codable, Hashable {
    case glmZAI
    case kimi
    case custom

    package var defaultDisplayName: String {
        switch self {
        case .glmZAI:
            "CC Zai"
        case .kimi:
            "CC Moonshot"
        case .custom:
            "CC Custom"
        }
    }

    var secureStorageAccount: SecureStorageAccount {
        switch self {
        case .glmZAI:
            .zAIAPI
        case .kimi:
            .claudeCompatibleKimiAPIKey
        case .custom:
            .claudeCompatibleCustomAPIKey
        }
    }

    package var defaultPreset: ClaudeCodeCompatibleBackendConfig {
        switch self {
        case .glmZAI:
            ClaudeCodeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.z.ai/api/anthropic",
                auth: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping(
                    ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
                        haiku: "glm-4.5-air",
                        sonnet: "glm-5.2[1m]",
                        opus: "glm-5.2[1m]"
                    )
                )
            )
        case .kimi:
            ClaudeCodeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.kimi.com/coding/",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        case .custom:
            ClaudeCodeCompatibleBackendConfig(
                id: self,
                isEnabled: false,
                displayName: defaultDisplayName,
                baseURL: "",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        }
    }
}

package struct ClaudeCodeCompatibleBackendConfig: Codable, Equatable {
    package enum Auth: Codable, Equatable {
        case anthropicAPIKey
        case anthropicAuthToken

        var environmentVariableName: String {
            switch self {
            case .anthropicAPIKey:
                "ANTHROPIC_API_KEY"
            case .anthropicAuthToken:
                "ANTHROPIC_AUTH_TOKEN"
            }
        }
    }

    package enum ModelBehavior: Codable, Equatable {
        case noModel
        case claudeSlotMapping(ClaudeSlotMapping)
    }

    package struct ClaudeSlotMapping: Codable, Equatable {
        package var haiku: String
        package var sonnet: String
        package var opus: String

        package init(
            haiku: String,
            sonnet: String,
            opus: String
        ) {
            self.haiku = haiku
            self.sonnet = sonnet
            self.opus = opus
        }

        package var normalized: ClaudeSlotMapping {
            ClaudeSlotMapping(
                haiku: haiku.trimmingCharacters(in: .whitespacesAndNewlines),
                sonnet: sonnet.trimmingCharacters(in: .whitespacesAndNewlines),
                opus: opus.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var isValid: Bool {
            let mapping = normalized
            return !mapping.haiku.isEmpty && !mapping.sonnet.isEmpty && !mapping.opus.isEmpty
        }
    }

    package var id: ClaudeCodeCompatibleBackendID
    package var isEnabled: Bool
    package var displayName: String
    package var baseURL: String
    package var auth: Auth
    package var modelBehavior: ModelBehavior
    var updatedAt: Date?

    package var normalizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id.defaultDisplayName }
        return trimmed
    }

    var normalizedBaseURL: String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        return trimmed
    }

    package var normalized: ClaudeCodeCompatibleBackendConfig {
        var copy = self
        copy.displayName = normalizedDisplayName
        copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .claudeSlotMapping(mapping) = modelBehavior {
            copy.modelBehavior = .claudeSlotMapping(mapping.normalized)
        }
        return copy
    }

    package var isValid: Bool {
        guard normalizedBaseURL != nil else { return false }
        switch modelBehavior {
        case .noModel:
            return true
        case let .claudeSlotMapping(mapping):
            return mapping.isValid
        }
    }
}
