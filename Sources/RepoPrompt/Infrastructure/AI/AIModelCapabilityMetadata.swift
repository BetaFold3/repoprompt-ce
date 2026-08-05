import Foundation

/// Neutral token-budget metadata for a resolved `AIModel`.
/// Numbers only — never includes model identity, family, or vendor names.
enum AIModelCapabilityMetadata {
    enum WindowSource: String, Equatable {
        case exact
        case providerFallback = "provider_fallback"
    }

    struct Snapshot: Equatable {
        let contextWindowTokens: Int?
        let maxOutputTokens: Int?
        let windowSource: WindowSource?

        static let empty = Snapshot(
            contextWindowTokens: nil,
            maxOutputTokens: nil,
            windowSource: nil
        )

        var exactContextWindowTokens: Int? {
            windowSource == .exact ? contextWindowTokens : nil
        }
    }

    static func resolve(for model: AIModel) -> Snapshot {
        if case let .openAIServiceTierVariant(base, _) = model {
            return resolve(for: base)
        }
        let window = contextWindowMetadata(for: model)
        return Snapshot(
            contextWindowTokens: window.tokens,
            maxOutputTokens: model.maxTokens,
            windowSource: window.source
        )
    }

    /// Exact context window when known, otherwise a provider fallback used only for
    /// internal capability planning. Callers must consult `windowSource` before exposing
    /// or enforcing a limit.
    static func contextWindowTokens(for model: AIModel) -> Int? {
        resolve(for: model).contextWindowTokens
    }

    static func safeUsagePercentage(
        inputTokens: Int,
        contextWindowTokens: Int
    ) -> Int? {
        guard contextWindowTokens > 0 else { return nil }
        let percentage = (
            Double(max(0, inputTokens)) / Double(contextWindowTokens) * 100.0
        ).rounded()
        guard percentage.isFinite else { return Int.max }
        if percentage >= Double(Int.max) {
            return Int.max
        }
        return max(0, Int(percentage))
    }

    private static func contextWindowMetadata(
        for model: AIModel
    ) -> (tokens: Int?, source: WindowSource?) {
        if case let .openAIServiceTierVariant(base, _) = model {
            return contextWindowMetadata(for: base)
        }

        switch model {
        case .claude5Opus:
            return (1_000_000, .exact)
        case let .claudeCodeModel(specifier):
            if let resolved = AgentModel.resolvedModel(
                forRaw: specifier,
                agentKind: .claudeCode
            ) {
                return (resolved.contextWindowTokens, .exact)
            }
            return (200_000, .providerFallback)
        case .geminiFlashLatest, .gemini2flashlite, .geminiProLatest,
             .geminiFlash2, .geminiFlash25, .geminiFlash25LitePreview,
             .geminiFlashThinking, .geminiPro25, .gemini3p1ProPreview,
             .gemini3FlashPreview, .openrouterGeminiFlash,
             .openrouterGeminiPro, .openrouterGeminiPro25:
            return (1_000_000, .exact)
        case .openrouterClaude4Sonnet, .openrouterClaude4Opus:
            return (200_000, .exact)
        case .ollama, .openrouterCustom, .openaiCustom, .openaiCustomResponses,
             .openaiCustomReasoning, .openAIConfigured, .anthropicCustom,
             .geminiCustom, .deepseekCustom, .fireworksCustom, .azureCustom,
             .grokCustom, .groqCustom, .zaiCustom, .codexCustom,
             .openCodeCustom, .cursorCustom, .customProvider, .customProviderUser:
            return (nil, nil)
        default:
            break
        }
        return providerDefaultContextWindow(for: model.providerType)
    }

    private static func providerDefaultContextWindow(
        for provider: AIProviderType
    ) -> (tokens: Int?, source: WindowSource?) {
        let tokens: Int? = switch provider {
        case .anthropic, .claudeCode:
            200_000
        case .openAI, .azure, .codex:
            128_000
        case .gemini:
            1_000_000
        case .openRouter, .deepseek, .fireworks, .grok, .groq, .zAI, .openCode, .cursor:
            128_000
        case .ollama, .customProvider:
            nil
        }
        return (tokens, tokens == nil ? nil : .providerFallback)
    }
}
