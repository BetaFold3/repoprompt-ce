import Foundation

struct AnthropicModelFamilyTraits: Equatable {
    enum RequestShape: Equatable {
        case adaptiveEffort
        case legacy
    }

    let requestShape: RequestShape
    let defaultMaxTokens: Int?
    let knownContextWindowTokens: Int?
    let knownMaxOutputTokens: Int?

    static func resolve(modelID: String) -> AnthropicModelFamilyTraits {
        if let exact = exactOverrides[modelID] {
            return exact
        }
        if let family = ClaudeModelFamilyCatalog.family(for: modelID) {
            return traits(for: family)
        }
        return legacy
    }

    private static func traits(
        for family: ClaudeModelFamilyCatalog.Family
    ) -> AnthropicModelFamilyTraits {
        let requestShape: RequestShape = switch family.apiRequestShape {
        case .adaptiveEffort: .adaptiveEffort
        case .legacy: .legacy
        }
        return AnthropicModelFamilyTraits(
            requestShape: requestShape,
            defaultMaxTokens: family.defaultMaxTokens,
            // API-known metadata only: the family's CLI context window is a
            // separate fact and must never leak into API-path capability claims.
            knownContextWindowTokens: family.apiKnownContextWindowTokens,
            knownMaxOutputTokens: family.apiKnownMaxOutputTokens
        )
    }

    private static let legacy = AnthropicModelFamilyTraits(
        requestShape: .legacy,
        defaultMaxTokens: nil,
        knownContextWindowTokens: nil,
        knownMaxOutputTokens: nil
    )

    /// Exact full-model-ID rows are consulted before the family grammar and
    /// always win. Keep this empty until a live contract divergence requires
    /// pinning one exact model; the intended one-line override form is e.g.:
    /// `"claude-fable-5-3": AnthropicModelFamilyTraits(requestShape: .legacy,
    /// defaultMaxTokens: nil, knownContextWindowTokens: 1_000_000,
    /// knownMaxOutputTokens: 128_000)`.
    private static let exactOverrides: [String: AnthropicModelFamilyTraits] = [:]
}
