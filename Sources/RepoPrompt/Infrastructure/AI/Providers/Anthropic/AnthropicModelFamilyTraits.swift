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

        // Phase 1b only requires a segment boundary; Phase 3 adds the stricter numeric grammar.
        if let family = anchoredFamilies.first(where: {
            modelID == $0.anchor || modelID.hasPrefix("\($0.anchor)-")
        }) {
            return family.traits
        }

        return legacy
    }

    private static let legacy = AnthropicModelFamilyTraits(
        requestShape: .legacy,
        defaultMaxTokens: nil,
        knownContextWindowTokens: nil,
        knownMaxOutputTokens: nil
    )

    private static let adaptiveEffort = AnthropicModelFamilyTraits(
        requestShape: .adaptiveEffort,
        defaultMaxTokens: nil,
        knownContextWindowTokens: nil,
        knownMaxOutputTokens: nil
    )

    private static let fable5 = AnthropicModelFamilyTraits(
        requestShape: .adaptiveEffort,
        // Anthropic's Fable migration guidance uses 16K at high effort to leave room for adaptive thinking.
        defaultMaxTokens: 16000,
        knownContextWindowTokens: 1_000_000,
        knownMaxOutputTokens: 128_000
    )

    private static let exactOverrides: [String: AnthropicModelFamilyTraits] = [
        "claude-opus-5": adaptiveEffort
    ]

    private static let anchoredFamilies: [(anchor: String, traits: AnthropicModelFamilyTraits)] = [
        ("claude-fable-5", fable5),
        // Keep Sonnet 5 legacy until the plan's U3 live API contract probe is complete.
        ("claude-sonnet-5", legacy)
    ]
}
