@testable import RepoPromptApp
import XCTest

final class AnthropicRequestPlanTests: XCTestCase {
    func testClaudeOpus5UsesExactAPIIDAndAdaptiveThinkingForEverySupportedEffort() throws {
        for effort in AnthropicEffort.allCases {
            let configuration = try AnthropicModelConfiguration.resolve(
                modelID: "claude-opus-5",
                effort: effort
            )

            XCTAssertEqual(configuration.apiModelID, "claude-opus-5")
            XCTAssertEqual(configuration.thinking, .adaptive)
            XCTAssertEqual(configuration.effort, effort)
        }
    }

    func testClaudeOpus5DefaultsToHighEffortAndOmitsSampling() throws {
        let plan = try AnthropicRequestPlan.resolve(
            modelID: "claude-opus-5",
            requestedMaxTokens: nil,
            fallbackMaxTokens: 4096,
            temperature: 0.4
        )

        XCTAssertEqual(plan.modelID, "claude-opus-5")
        XCTAssertEqual(plan.maxTokens, 4096)
        XCTAssertEqual(plan.thinking, .adaptive)
        XCTAssertEqual(plan.effort, .high)
        XCTAssertNil(plan.temperature)
    }

    func testFable5FamilyUsesAdaptiveThinkingWithDefaultAndRequestedEffort() throws {
        for modelID in [
            "claude-fable-5",
            "claude-fable-5-1",
            "claude-fable-5-2-20260902"
        ] {
            let defaultConfiguration = try AnthropicModelConfiguration.resolve(modelID: modelID)
            XCTAssertEqual(defaultConfiguration.apiModelID, modelID)
            XCTAssertEqual(defaultConfiguration.thinking, .adaptive)
            XCTAssertEqual(defaultConfiguration.effort, .high)
            XCTAssertEqual(defaultConfiguration.defaultMaxTokens, 16000)

            let requestPlan = try AnthropicRequestPlan.resolve(
                modelID: modelID,
                requestedMaxTokens: nil,
                fallbackMaxTokens: 4096,
                temperature: nil
            )
            XCTAssertEqual(requestPlan.maxTokens, 16000)

            let requestedConfiguration = try AnthropicModelConfiguration.resolve(
                modelID: modelID,
                effort: .max
            )
            XCTAssertEqual(requestedConfiguration.effort, .max)
        }
    }

    func testFable5LegacyThinkingSuffixIsStrippedBeforeAdaptiveClassification() throws {
        let configuration = try AnthropicModelConfiguration.resolve(
            modelID: "claude-fable-5-1-thinking-max",
            effort: .xhigh
        )

        XCTAssertEqual(configuration.apiModelID, "claude-fable-5-1")
        XCTAssertEqual(configuration.thinking, .adaptive)
        XCTAssertEqual(configuration.effort, .xhigh)
        XCTAssertEqual(configuration.defaultMaxTokens, 16000)
    }

    func testMalformedFableLookalikesAndSonnet5FamilyRemainLegacy() throws {
        for modelID in [
            "claude-fable-50",
            "claude-fable-5-2-preview",
            "claude-sonnet-5",
            "claude-sonnet-5-1"
        ] {
            let plan = try AnthropicRequestPlan.resolve(
                modelID: modelID,
                requestedMaxTokens: nil,
                fallbackMaxTokens: 4096,
                temperature: 0.4
            )

            XCTAssertEqual(plan.modelID, modelID)
            XCTAssertEqual(plan.thinking, .none)
            XCTAssertNil(plan.effort)
            XCTAssertEqual(plan.temperature, 0.4)
        }
    }

    func testLegacyThinkingSuffixBehaviorIsPreserved() throws {
        let opusPlan = try AnthropicRequestPlan.resolve(
            modelID: "claude-opus-4-6-thinking",
            requestedMaxTokens: nil,
            fallbackMaxTokens: 4096,
            temperature: 0.4
        )
        XCTAssertEqual(opusPlan.modelID, "claude-opus-4-6")
        XCTAssertEqual(opusPlan.maxTokens, 32000)
        XCTAssertEqual(opusPlan.thinking, .enabled(budgetTokens: 16000))
        XCTAssertNil(opusPlan.effort)
        XCTAssertNil(opusPlan.temperature)

        let maxPlan = try AnthropicRequestPlan.resolve(
            modelID: "claude-sonnet-4-5-20250929-thinking-max",
            requestedMaxTokens: nil,
            fallbackMaxTokens: 4096,
            temperature: 0.4
        )
        XCTAssertEqual(maxPlan.modelID, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(maxPlan.maxTokens, 64000)
        XCTAssertEqual(maxPlan.thinking, .enabled(budgetTokens: 32000))
        XCTAssertNil(maxPlan.effort)
        XCTAssertNil(maxPlan.temperature)
    }

    func testEffortIsRejectedForModelsWithoutEffortSupport() {
        XCTAssertThrowsError(
            try AnthropicModelConfiguration.resolve(
                modelID: "claude-opus-4-6",
                effort: .max
            )
        ) { error in
            XCTAssertEqual(
                error as? AnthropicModelConfigurationError,
                .unsupportedEffort(modelID: "claude-opus-4-6", effort: .max)
            )
        }
    }

    func testLegacyThinkingRejectsMaxTokensAtOrBelowBudget() {
        XCTAssertThrowsError(
            try AnthropicRequestPlan.resolve(
                modelID: "claude-opus-4-6-thinking",
                requestedMaxTokens: 4096,
                fallbackMaxTokens: 4096,
                temperature: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AnthropicModelConfigurationError,
                .insufficientMaxTokens(
                    modelID: "claude-opus-4-6",
                    budgetTokens: 16000,
                    maxTokens: 4096
                )
            )
        }
    }

    func testFable51RequestEncodingUsesAdaptiveEffortAndOmitsSampling() throws {
        let plan = try AnthropicRequestPlan.resolve(
            modelID: "claude-fable-5-1",
            requestedMaxTokens: 12345,
            fallbackMaxTokens: 4096,
            temperature: 0.7,
            effort: .xhigh
        )
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: [AnthropicRequestMessage(role: .user, content: "Hello")],
            system: [AnthropicSystemBlock(text: "System")],
            stream: true
        )

        let json = try jsonObject(for: payload)
        XCTAssertEqual(json["model"] as? String, "claude-fable-5-1")
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_k"])
        XCTAssertNil(json["top_p"])

        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "xhigh")
    }

    func testFable5KnownMaxOutputCeilingRejectsExactRequestedValueAboveLimit() {
        XCTAssertThrowsError(
            try AnthropicRequestPlan.resolve(
                modelID: "claude-fable-5-1",
                requestedMaxTokens: 128_001,
                fallbackMaxTokens: 4096,
                temperature: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AnthropicModelConfigurationError,
                .maxTokensExceedsKnownLimit(
                    modelID: "claude-fable-5-1",
                    requested: 128_001,
                    limit: 128_000
                )
            )
        }
    }

    func testAnthropicCustomFable51UsesExactKnownCapabilities() {
        let metadata = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-fable-5-1")
        )

        XCTAssertEqual(metadata.contextWindowTokens, 1_000_000)
        XCTAssertEqual(metadata.maxOutputTokens, 128_000)
        XCTAssertEqual(metadata.windowSource, .exact)
    }

    func testAnthropicCustomCapabilityMetadataPrefersRegistryExactTokensBeforeTraits() {
        let store = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(store.replace(with: [
            AnthropicDiscoveredModel(
                id: "claude-fable-5-1",
                displayName: "Fable 5.1",
                maxInputTokens: 900_000,
                maxOutputTokens: 64000
            ),
            AnthropicDiscoveredModel(id: "claude-fable-5-3")
        ]))

        let registryBacked = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-fable-5-1"),
            store: store
        )
        XCTAssertEqual(registryBacked.contextWindowTokens, 900_000)
        XCTAssertEqual(registryBacked.windowSource, .exact)
        XCTAssertEqual(registryBacked.maxOutputTokens, 64000)

        // A discovered ID without token metadata falls back to family traits
        // (Fable is the only API-verified family carrying known limits).
        let traitsFallback = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-fable-5-3"),
            store: store
        )
        XCTAssertEqual(traitsFallback.contextWindowTokens, 1_000_000)
        XCTAssertEqual(traitsFallback.windowSource, .exact)

        // Undiscovered non-family IDs keep the existing unknown-window contract.
        let unknown = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-mystery-9"),
            store: store
        )
        XCTAssertNil(unknown.contextWindowTokens)
        XCTAssertNil(unknown.windowSource)
    }

    func testClaudeCodeDynamicPointReleaseCapabilityMetadataUsesFamilyWindow() {
        let dynamic = AIModelCapabilityMetadata.resolve(
            for: .claudeCodeModel(specifier: "claude-fable-5-2:xhigh")
        )
        XCTAssertEqual(dynamic.contextWindowTokens, 1_000_000)
        XCTAssertEqual(dynamic.windowSource, .exact)

        let lookalike = AIModelCapabilityMetadata.resolve(
            for: .claudeCodeModel(specifier: "claude-fable-50")
        )
        XCTAssertEqual(lookalike.contextWindowTokens, 200_000)
        XCTAssertEqual(lookalike.windowSource, .providerFallback)
    }

    func testSonnetAndOpusAPIKnownMetadataStayUnknownUntilProbeWhileClaudeCodeKeepsFamilyWindow() {
        // .anthropicCustom Sonnet without registry corroboration stays unknown
        // on the API path until the plan's U3 live contract probe.
        let unknownSonnet = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-sonnet-5"),
            store: AnthropicDiscoveredModelStore.transient()
        )
        XCTAssertNil(unknownSonnet.contextWindowTokens)
        XCTAssertNil(unknownSonnet.windowSource)

        // Exact registry tokens win once the official API corroborates them.
        let store = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(store.replace(with: [
            AnthropicDiscoveredModel(
                id: "claude-sonnet-5-2",
                maxInputTokens: 1_000_000,
                maxOutputTokens: 64000
            )
        ]))
        let registryBacked = AIModelCapabilityMetadata.resolve(
            for: .anthropicCustom(name: "claude-sonnet-5-2"),
            store: store
        )
        XCTAssertEqual(registryBacked.contextWindowTokens, 1_000_000)
        XCTAssertEqual(registryBacked.windowSource, .exact)
        XCTAssertEqual(registryBacked.maxOutputTokens, 64000)

        // The Claude Code path keeps the known 1M family window — CLI metadata
        // is decoupled from API-known metadata.
        let cli = AIModelCapabilityMetadata.resolve(
            for: .claudeCodeModel(specifier: "claude-sonnet-5-2:high"),
            store: AnthropicDiscoveredModelStore.transient()
        )
        XCTAssertEqual(cli.contextWindowTokens, 1_000_000)
        XCTAssertEqual(cli.windowSource, .exact)

        // Opus keeps adaptive request shaping with pre-Phase-3 nil API-known
        // limits; Fable's verified fallback is untouched.
        let opusTraits = AnthropicModelFamilyTraits.resolve(modelID: "claude-opus-5")
        XCTAssertEqual(opusTraits.requestShape, .adaptiveEffort)
        XCTAssertNil(opusTraits.knownContextWindowTokens)
        XCTAssertNil(opusTraits.knownMaxOutputTokens)

        let sonnetTraits = AnthropicModelFamilyTraits.resolve(modelID: "claude-sonnet-5-2")
        XCTAssertEqual(sonnetTraits.requestShape, .legacy)
        XCTAssertNil(sonnetTraits.knownContextWindowTokens)
        XCTAssertNil(sonnetTraits.knownMaxOutputTokens)

        let fableTraits = AnthropicModelFamilyTraits.resolve(modelID: "claude-fable-5-1")
        XCTAssertEqual(fableTraits.knownContextWindowTokens, 1_000_000)
        XCTAssertEqual(fableTraits.knownMaxOutputTokens, 128_000)
    }

    func testAnthropicRefusalTerminalClassificationIsTypedAndModelSpecific() {
        XCTAssertNil(
            AnthropicProviderResponseError.classifyTerminal(
                stopReason: "end_turn",
                modelID: "claude-fable-5-1"
            )
        )
        XCTAssertEqual(
            AnthropicProviderResponseError.classifyTerminal(
                stopReason: "refusal",
                modelID: "claude-fable-5-1"
            ),
            .refusal(modelID: "claude-fable-5-1")
        )
    }

    func testOpus5RequestEncodingUsesCurrentFieldsAndOmitsIncompatibleSampling() throws {
        let plan = try AnthropicRequestPlan.resolve(
            modelID: "claude-opus-5",
            requestedMaxTokens: 12345,
            fallbackMaxTokens: 4096,
            temperature: 0.7,
            effort: .xhigh
        )
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: [AnthropicRequestMessage(role: .user, content: "Hello")],
            system: [AnthropicSystemBlock(text: "System")],
            stream: true
        )

        let json = try jsonObject(for: payload)
        XCTAssertEqual(json["model"] as? String, "claude-opus-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 12345)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_k"])
        XCTAssertNil(json["top_p"])

        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "xhigh")
    }

    func testNonThinkingRequestRetainsTemperatureAndOmitsThinkingFields() throws {
        let plan = try AnthropicRequestPlan.resolve(
            modelID: "claude-haiku-4-5",
            requestedMaxTokens: nil,
            fallbackMaxTokens: 4096,
            temperature: 0.2
        )
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: [AnthropicRequestMessage(role: .user, content: "Hello")],
            system: [AnthropicSystemBlock(text: "System")],
            stream: false
        )

        let json = try jsonObject(for: payload)
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["output_config"])
    }

    func testRequestEncoderMatchesPinnedSDKHeadersAndMessagesEndpoint() throws {
        let plan = try AnthropicRequestPlan.resolve(
            modelID: "claude-opus-5",
            requestedMaxTokens: 4096,
            fallbackMaxTokens: 4096,
            temperature: nil
        )
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: [AnthropicRequestMessage(role: .user, content: "Hello")],
            system: [AnthropicSystemBlock(text: "System")],
            stream: false
        )
        let encoder = AnthropicRequestEncoder(
            apiKey: "test-key",
            betaHeaders: ["messages-2023-12-15", "output-128k-2025-02-19"]
        )

        let request = try encoder.makeRequest(payload)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-beta"),
            "messages-2023-12-15,output-128k-2025-02-19"
        )
    }

    private func jsonObject(for value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
