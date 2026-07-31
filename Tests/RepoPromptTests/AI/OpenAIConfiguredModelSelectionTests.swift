import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIConfiguredModelSelectionTests: XCTestCase {
    func testVersionedRawCodecIsStrictAndRoundTrips() throws {
        let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .pro,
            reasoningEffort: .high
        ))

        XCTAssertEqual(
            selection.rawValue,
            "openai_api_selection_v1__gpt-5.6-sol__pro__high"
        )
        XCTAssertEqual(OpenAIConfiguredModelSelection(rawValue: selection.rawValue), selection)

        XCTAssertNil(OpenAIConfiguredModelSelection(rawValue: " openai_api_selection_v1__gpt-5.6-sol__pro__high"))
        XCTAssertNil(OpenAIConfiguredModelSelection(rawValue: "openai_api_selection_v2__gpt-5.6-sol__pro__high"))
        XCTAssertNil(OpenAIConfiguredModelSelection(rawValue: "openai_api_selection_v1__gpt-5.6-sol__PRO__high"))
        XCTAssertNil(OpenAIConfiguredModelSelection(rawValue: "openai_api_selection_v1__gpt-5.6-sol__pro__ultra"))
        XCTAssertNil(OpenAIConfiguredModelSelection(rawValue: "openai_api_selection_v1__gpt-5.6-sol__pro"))
    }

    func testCapabilitySelectionPreservesMinimalEffortAndNonStreamingRouting() throws {
        let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-future-minimal",
            reasoningMode: .standard,
            reasoningEffort: .minimal,
            supportsStreaming: false
        ))

        XCTAssertEqual(
            selection.rawValue,
            "openai_api_selection_v2__gpt-future-minimal__standard__minimal__completion"
        )
        let model = AIModel.openAIConfigured(selection: selection)
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
        XCTAssertFalse(model.canStream)
    }

    func testNoneAndMaxSelectionsRoundTripAcrossCodecsAndPersistence() throws {
        for effort in [CodexReasoningEffort.none, .max] {
            let legacySelection = try XCTUnwrap(OpenAIConfiguredModelSelection(
                modelID: "gpt-5.6-sol",
                reasoningMode: .pro,
                reasoningEffort: effort
            ))
            XCTAssertEqual(
                legacySelection.rawValue,
                "openai_api_selection_v1__gpt-5.6-sol__pro__\(effort.rawValue)"
            )
            XCTAssertEqual(
                OpenAIConfiguredModelSelection(rawValue: legacySelection.rawValue),
                legacySelection
            )

            let capabilitySelection = try XCTUnwrap(OpenAIConfiguredModelSelection(
                modelID: "gpt-5.6-sol",
                reasoningMode: .standard,
                reasoningEffort: effort,
                supportsStreaming: false
            ))
            XCTAssertEqual(
                capabilitySelection.rawValue,
                "openai_api_selection_v2__gpt-5.6-sol__standard__\(effort.rawValue)__completion"
            )
            XCTAssertEqual(
                OpenAIConfiguredModelSelection(rawValue: capabilitySelection.rawValue),
                capabilitySelection
            )

            for selection in [legacySelection, capabilitySelection] {
                let model = AIModel.openAIConfigured(selection: selection)
                XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)

                let data = try JSONEncoder().encode(ModelPreset(name: effort.displayName, model: model))
                let decoded = try JSONDecoder().decode(ModelPreset.self, from: data)
                XCTAssertEqual(decoded.modelString, model.rawValue)
                XCTAssertEqual(decoded.model, model)
            }
        }
    }

    func testPickerSelectionsExposeSixEffortsUnderBothIndependentModes() {
        let selections = OpenAIConfiguredModelSelection.pickerSelections(modelID: "gpt-5.6-sol")

        XCTAssertEqual(selections.count, 12)
        XCTAssertEqual(
            selections.map { "\($0.reasoningMode.rawValue):\($0.reasoningEffort.rawValue)" },
            [
                "standard:none", "standard:low", "standard:medium",
                "standard:high", "standard:xhigh", "standard:max",
                "pro:none", "pro:low", "pro:medium",
                "pro:high", "pro:xhigh", "pro:max"
            ]
        )
        XCTAssertFalse(selections.contains { $0.reasoningEffort == .minimal })
        XCTAssertTrue(selections.allSatisfy { $0.supportsStreaming == nil })
    }

    func testPickerCatalogExposesGPT56SolAndConfiguredRawSurvivesReparse() throws {
        XCTAssertTrue(AIModel.modelsForProvider(.openAI).contains(.gpt56Sol))
        XCTAssertEqual(AIModel.gpt56Sol.rawValue, "gpt-5.6-sol")
        XCTAssertEqual(AIModel.gpt56Sol.modelName, "gpt-5.6-sol")

        let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: AIModel.gpt56Sol.modelName,
            reasoningMode: .standard,
            reasoningEffort: .xhigh
        ))
        let configured = AIModel.openAIConfigured(selection: selection)

        XCTAssertEqual(AIModel.fromModelName(configured.rawValue), configured)
        XCTAssertEqual(configured.modelName, "gpt-5.6-sol")
        XCTAssertEqual(
            AIModel.fromModelName(configured.modelName),
            .gpt56Sol,
            "Provider modelName intentionally identifies the wire model; persistence must use rawValue"
        )
    }

    func testPresetAndBackgroundJobPreserveConfiguredRawSelection() throws {
        let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .pro,
            reasoningEffort: .xhigh
        ))
        let model = AIModel.openAIConfigured(selection: selection)

        let presetData = try JSONEncoder().encode(ModelPreset(name: "sol-pro", model: model))
        let decodedPreset = try JSONDecoder().decode(ModelPreset.self, from: presetData)
        XCTAssertEqual(decodedPreset.modelString, model.rawValue)
        XCTAssertEqual(decodedPreset.model, model)

        let session = ChatSession(name: "Sol Pro", preferredAIModel: model.rawValue)
        let sessionData = try JSONEncoder().encode(session)
        let decodedSession = try JSONDecoder().decode(ChatSession.self, from: sessionData)
        XCTAssertEqual(decodedSession.preferredAIModel, model.rawValue)
        XCTAssertEqual(decodedSession.preferredAIModel.flatMap(AIModel.fromModelName), model)

        let job = BackgroundResponseJob(
            id: "resp_test",
            provider: .openAI,
            model: model,
            createdAt: Date(timeIntervalSince1970: 1000),
            status: .queued
        )
        let jobData = try JSONEncoder().encode(job)
        let decodedJob = try JSONDecoder().decode(BackgroundResponseJob.self, from: jobData)
        XCTAssertEqual(decodedJob.model.rawValue, model.rawValue)
        XCTAssertEqual(decodedJob.model, model)
    }

    func testServiceTierWrapperPreservesConfiguredSelectionRaw() throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "openAIShowServiceTierVariants")
        defaults.set(true, forKey: "openAIShowServiceTierVariants")
        defer {
            if let prior {
                defaults.set(prior, forKey: "openAIShowServiceTierVariants")
            } else {
                defaults.removeObject(forKey: "openAIShowServiceTierVariants")
            }
        }

        let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .pro,
            reasoningEffort: .max
        ))
        let configured = AIModel.openAIConfigured(selection: selection)
        let tiered = AIModel.openAIServiceTierVariant(base: configured, tier: "flex")

        XCTAssertEqual(AIModel.fromModelName(tiered.rawValue), tiered)
        XCTAssertEqual(tiered.openAIServiceTierBase, configured)
        XCTAssertEqual(tiered.openAIServiceTierOverride, "flex")
        XCTAssertEqual(AIModel.rawValueWithoutOpenAIServiceTier(tiered.rawValue), configured.rawValue)
    }

    func testProAndStandardRequestBodiesSharePlanButEncodeModeIndependently() throws {
        let input = AIMessage(systemPrompt: "System", userMessage: "Hello").openAIResponsesInput()
        let deliveries: [OpenAIResponseRequestPlan.Delivery] = [.foreground, .stream, .background]

        let proSelection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .pro,
            reasoningEffort: .high
        ))
        let proModel = AIModel.openAIServiceTierVariant(
            base: .openAIConfigured(selection: proSelection),
            tier: "flex"
        )
        let proPlan = OpenAIResponseRequestPlan.make(model: proModel, defaultServiceTier: "auto")
        XCTAssertEqual(proPlan.baseModel, .openAIConfigured(selection: proSelection))

        for delivery in deliveries {
            let parameters = proPlan.parameters(
                input: input,
                instructions: "System",
                maxOutputTokens: nil,
                delivery: delivery
            )
            let body = try jsonObject(proPlan.encodedBody(for: parameters))
            let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])

            XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
            XCTAssertEqual(body["service_tier"] as? String, "flex")
            XCTAssertEqual(reasoning["effort"] as? String, "high")
            XCTAssertEqual(reasoning["mode"] as? String, "pro")
            if delivery == .background {
                XCTAssertEqual(body["background"] as? Bool, true)
            } else {
                XCTAssertNil(body["background"])
            }
            XCTAssertEqual(body["stream"] as? Bool, delivery == .stream)
        }

        let standardSelection = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .standard,
            reasoningEffort: .low
        ))
        let standardPlan = OpenAIResponseRequestPlan.make(
            model: .openAIConfigured(selection: standardSelection),
            defaultServiceTier: "auto"
        )
        let standardParameters = standardPlan.parameters(
            input: input,
            instructions: nil,
            maxOutputTokens: nil,
            delivery: .foreground
        )
        let standardBody = try jsonObject(standardPlan.encodedBody(for: standardParameters))
        let standardReasoning = try XCTUnwrap(standardBody["reasoning"] as? [String: Any])

        XCTAssertEqual(standardBody["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(standardReasoning["effort"] as? String, "low")
        XCTAssertNil(standardReasoning["mode"])

        let provider = OpenAIProvider(apiKey: "test-key")
        XCTAssertNil(provider.resolvedResponseMaxTokens(for: proModel, override: nil))
        XCTAssertEqual(provider.resolvedResponseMaxTokens(for: proModel, override: 4096), 4096)

        let backgroundParameters = provider.buildForegroundResponseParameters(
            AIMessage(systemPrompt: "System", userMessage: "Hello"),
            model: proModel,
            maxTokens: 4096,
            stream: false
        )
        let backgroundBody = try jsonObject(JSONEncoder().encode(backgroundParameters))
        XCTAssertEqual(
            backgroundBody["max_output_tokens"] as? Int,
            4096,
            "Explicit caller caps must survive while synthesized defaults remain omitted"
        )
    }

    func testNoneAndMaxEffortsEncodeIndependentlyFromModeForAllDeliveries() throws {
        let input = AIMessage(systemPrompt: "System", userMessage: "Hello").openAIResponsesInput()
        let deliveries: [OpenAIResponseRequestPlan.Delivery] = [.foreground, .stream, .background]

        for mode in OpenAIReasoningMode.allCases {
            for effort in [CodexReasoningEffort.none, .max] {
                let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
                    modelID: "gpt-5.6-sol",
                    reasoningMode: mode,
                    reasoningEffort: effort
                ))
                let model = AIModel.openAIServiceTierVariant(
                    base: .openAIConfigured(selection: selection),
                    tier: "flex"
                )
                let plan = OpenAIResponseRequestPlan.make(model: model, defaultServiceTier: "auto")

                for delivery in deliveries {
                    let parameters = plan.parameters(
                        input: input,
                        instructions: "System",
                        maxOutputTokens: nil,
                        delivery: delivery
                    )
                    let body = try jsonObject(plan.encodedBody(for: parameters))
                    let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])

                    XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
                    XCTAssertEqual(body["service_tier"] as? String, "flex")
                    XCTAssertEqual(reasoning["effort"] as? String, effort.rawValue)
                    if mode == .pro {
                        XCTAssertEqual(reasoning["mode"] as? String, "pro")
                    } else {
                        XCTAssertNil(reasoning["mode"])
                    }
                    XCTAssertEqual(body["stream"] as? Bool, delivery == .stream)
                    XCTAssertEqual(body["background"] as? Bool, delivery == .background ? true : nil)
                }
            }
        }
    }

    func testHistoricalProModelIDsRemainLiteralWireModels() {
        let cases: [(AIModel, String)] = [
            (.gpt5Pro, "gpt-5.2-pro"),
            (.gpt5ProXHigh, "gpt-5.2-pro"),
            (.gpt54Pro, "gpt-5.4-pro"),
            (.gpt54ProXHigh, "gpt-5.4-pro")
        ]

        for (model, expectedModelID) in cases {
            let plan = OpenAIResponseRequestPlan.make(model: model, defaultServiceTier: nil)
            XCTAssertEqual(plan.modelID, expectedModelID)
            XCTAssertNil(plan.reasoningMode)
            XCTAssertFalse(plan.requiresProviderEncoding)
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
