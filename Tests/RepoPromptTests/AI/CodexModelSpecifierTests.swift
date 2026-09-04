@testable import RepoPromptApp
import XCTest

final class CodexModelSpecifierTests: XCTestCase {
    func testCapabilityAwareLongestBaseGrammarAndCLIArguments() {
        let seed = CodexModelCapabilitySnapshot.seedOnly
        let observed = CodexModelCapabilitySnapshot(capabilities: [
            .init(
                base: "gpt-daybreak-blue-latest",
                efforts: [.low, .max, .ultra],
                speedTiers: []
            ),
            .init(base: "gpt-5.1-codex", efforts: [.max], speedTiers: []),
            .init(base: "gpt-5.1-codex-max", efforts: [], speedTiers: [])
        ])

        let cases: [(String, CodexModelCapabilitySnapshot, String, CodexReasoningEffort?)] = [
            ("gpt-5.6-sol-max", seed, "gpt-5.6-sol", .max),
            ("gpt-5.6-sol-maximum", seed, "gpt-5.6-sol", .max),
            ("gpt-5.1-codex-max", seed, "gpt-5.1-codex-max", nil),
            ("gpt-5.1-codex-max-low", seed, "gpt-5.1-codex-max", .low),
            ("gpt-daybreak-blue-latest-ultra", observed, "gpt-daybreak-blue-latest", .ultra),
            ("gpt-6-astra-max", seed, "gpt-6-astra-max", nil),
            ("gpt-5.1-codex-max", observed, "gpt-5.1-codex-max", nil)
        ]
        for (raw, capabilities, base, effort) in cases {
            let parsed = CodexModelSpecifier(raw: raw, capabilities: capabilities)
            XCTAssertEqual(parsed.baseModel, base, raw)
            XCTAssertEqual(parsed.reasoningEffort, effort, raw)
        }

        let daybreak = CodexModelSpecifier(
            raw: "gpt-daybreak-blue-latest-ultra",
            capabilities: observed
        )
        XCTAssertEqual(daybreak.cliModelArgs, ["--model", "gpt-daybreak-blue-latest"])
        XCTAssertEqual(daybreak.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=ultra"])

        let exactMaxBase = CodexModelSpecifier(raw: "gpt-5.1-codex-max", capabilities: observed)
        XCTAssertEqual(exactMaxBase.cliModelArgs, ["--model", "gpt-5.1-codex-max"])
        XCTAssertEqual(exactMaxBase.cliReasoningConfigArgs, [])
    }

    func testFastRequestShapingUsesInjectedCapabilitySnapshot() {
        let eligible = CodexModelCapabilitySnapshot(capabilities: [
            .init(base: "hermetic-model", efforts: [], speedTiers: ["fast"])
        ])
        let ineligible = CodexModelCapabilitySnapshot(capabilities: [
            .init(base: "hermetic-model", efforts: [], speedTiers: [])
        ])

        let fast = CodexModelSpecifier(raw: "hermetic-model-fast", capabilities: eligible)
        XCTAssertEqual(fast.cliModelArgs, ["--model", "hermetic-model"])
        XCTAssertEqual(fast.cliServiceTierConfigArgs, ["-c", "service_tier=fast"])
        XCTAssertEqual(fast.appServerModelParam, "hermetic-model")
        XCTAssertEqual(fast.appServerServiceTierParam, "fast")

        let degraded = CodexModelSpecifier(raw: "hermetic-model-fast", capabilities: ineligible)
        XCTAssertEqual(degraded.cliModelArgs, ["--model", "hermetic-model"])
        XCTAssertEqual(degraded.cliServiceTierConfigArgs, [])
        XCTAssertEqual(degraded.appServerModelParam, "hermetic-model")
        XCTAssertNil(degraded.appServerServiceTierParam)
    }
}
