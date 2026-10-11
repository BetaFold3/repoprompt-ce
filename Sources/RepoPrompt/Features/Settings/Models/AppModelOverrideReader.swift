import Foundation
import RepoPromptAgentCore

/// App-owned `AIModelOverrideReading` backed by `ModelOverridesSettings`.
///
/// Stateless: every lookup reads `ModelOverridesSettings.shared` at call time, so the
/// singleton's lazy first-access load happens exactly where the lookup happens.
struct AppModelOverrideReader: AIModelOverrideReading {
    func streamOverride(for modelRaw: String) -> Bool? {
        ModelOverridesSettings.shared.streamOverride(for: modelRaw)
    }

    func responsesOverride(for modelRaw: String) -> Bool? {
        ModelOverridesSettings.shared.responsesOverride(for: modelRaw)
    }

    func temperatureOverride(for modelRaw: String) -> Double? {
        ModelOverridesSettings.shared.temperatureOverride(for: modelRaw)
    }
}

// MARK: - App convenience wrappers (current names/signatures)

extension AIModel {
    /// App wrapper over `usesResponsesAPI(overrides:)` using the settings-backed reader.
    var usesResponsesAPI: Bool {
        usesResponsesAPI(overrides: AppModelOverrideReader())
    }

    /// App wrapper over `canStream(overrides:)` using the settings-backed reader.
    var canStream: Bool {
        canStream(overrides: AppModelOverrideReader())
    }

    /// App wrapper over `resolveTemperature(explicitTemperature:includeOverrides:overrides:)`.
    func resolveTemperature(explicitTemperature: Double? = nil, includeOverrides: Bool = true) -> Double? {
        resolveTemperature(
            explicitTemperature: explicitTemperature,
            includeOverrides: includeOverrides,
            overrides: AppModelOverrideReader()
        )
    }
}

extension AIMessage {
    /// App wrapper over `effectiveTemperature(for:overrides:)` using the settings-backed reader.
    func effectiveTemperature(for model: AIModel) -> Double? {
        effectiveTemperature(for: model, overrides: AppModelOverrideReader())
    }
}
