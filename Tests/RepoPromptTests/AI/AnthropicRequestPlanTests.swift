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
