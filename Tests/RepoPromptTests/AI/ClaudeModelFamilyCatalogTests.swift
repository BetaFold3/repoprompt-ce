@testable import RepoPromptApp
import XCTest

final class ClaudeModelFamilyCatalogTests: XCTestCase {
    func testAnchorAllowlistAndFamilyMetadataAreCentralized() throws {
        XCTAssertEqual(
            ClaudeModelFamilyCatalog.families.map(\.anchor),
            ["claude-fable-5", "claude-opus-5", "claude-sonnet-5"]
        )

        let fable = try XCTUnwrap(
            ClaudeModelFamilyCatalog.family(for: "claude-fable-5")
        )
        XCTAssertEqual(fable.supportedEfforts, [.low, .medium, .high, .max, .xhigh])
        XCTAssertTrue(fable.xhighEligible)
        XCTAssertEqual(fable.contextWindowTokens, 1_000_000)
        XCTAssertEqual(fable.apiKnownContextWindowTokens, 1_000_000)
        XCTAssertEqual(fable.apiKnownMaxOutputTokens, 128_000)
        XCTAssertEqual(fable.defaultMaxTokens, 16000)
        XCTAssertEqual(fable.apiRequestShape, .adaptiveEffort)

        // Opus preserves pre-Phase-3 nil API-known limits; Sonnet stays
        // API-unverified until the plan's U3 live probe. Both keep the known
        // 1M Claude Code window — CLI and API-known metadata are decoupled.
        let opus = try XCTUnwrap(
            ClaudeModelFamilyCatalog.family(for: "claude-opus-5")
        )
        XCTAssertEqual(opus.contextWindowTokens, 1_000_000)
        XCTAssertNil(opus.apiKnownContextWindowTokens)
        XCTAssertNil(opus.apiKnownMaxOutputTokens)
        XCTAssertEqual(opus.apiRequestShape, .adaptiveEffort)

        let sonnet = try XCTUnwrap(
            ClaudeModelFamilyCatalog.family(for: "claude-sonnet-5")
        )
        XCTAssertEqual(sonnet.contextWindowTokens, 1_000_000)
        XCTAssertNil(sonnet.apiKnownContextWindowTokens)
        XCTAssertNil(sonnet.apiKnownMaxOutputTokens)
        XCTAssertEqual(sonnet.apiRequestShape, .legacy)
    }

    func testStrictPointReleaseGrammarAcceptsNumericSameMajorIDs() throws {
        let fable = try XCTUnwrap(
            ClaudeModelFamilyCatalog.pointRelease("claude-fable-5-2")
        )
        XCTAssertEqual(fable.family.id, .fable)
        XCTAssertEqual(fable.minor, 2)
        XCTAssertNil(fable.dateSuffix)
        XCTAssertEqual(fable.rawModelID, "claude-fable-5-2")
        XCTAssertEqual(fable.generatedDisplayName, "Fable 5.2")

        let dated = try XCTUnwrap(
            ClaudeModelFamilyCatalog.pointRelease("claude-opus-5-12-20260902")
        )
        XCTAssertEqual(dated.family.id, .opus)
        XCTAssertEqual(dated.minor, 12)
        XCTAssertEqual(dated.dateSuffix, "20260902")
        XCTAssertEqual(dated.generatedDisplayName, "Opus 5.12 (20260902)")

        // Deliberate, stable grammar consequence: the minor is required and
        // components are numeric, so a bare date-like trailing component is a
        // (large) numeric minor — never a dated anchor release.
        let dateLikeMinor = try XCTUnwrap(
            ClaudeModelFamilyCatalog.pointRelease("claude-fable-5-20260101")
        )
        XCTAssertEqual(dateLikeMinor.minor, 20_260_101)
        XCTAssertNil(dateLikeMinor.dateSuffix)
        XCTAssertEqual(dateLikeMinor.generatedDisplayName, "Fable 5.20260101")

        XCTAssertEqual(
            ClaudeModelFamilyCatalog.family(for: "claude-sonnet-5-3")?.id,
            .sonnet
        )
    }

    func testStrictPointReleaseGrammarRejectsLookalikesAndMalformedIDs() {
        let rejected = [
            "claude-fable-5",
            "claude-fable-50",
            "claude-fable-6-1",
            "claude-fable-5-preview",
            "claude-fable-5-1-preview",
            "claude-fable-5-1-beta",
            "claude-fable-5-1-thinking",
            "claude-fable-5-1-2026090",
            "claude-fable-5-1-202609020",
            "claude-fable-5-1-2026a902",
            "claude-fable-5-1-20260902-extra",
            "claude-fable-5-1-",
            "claude-fable-5--20260902",
            "prefix-claude-fable-5-1",
            "claude-fable-5-١"
        ]

        for modelID in rejected {
            XCTAssertNil(
                ClaudeModelFamilyCatalog.pointRelease(modelID),
                "Expected rejection for \(modelID)"
            )
        }
    }

    func testPointReleaseOrderingIsNumericThenDateThenRaw() {
        let raws = [
            "claude-fable-5-2",
            "claude-fable-5-10",
            "claude-fable-5-2-20260901",
            "claude-fable-5-2-20260902"
        ]
        let releases = raws.compactMap(ClaudeModelFamilyCatalog.pointRelease)

        XCTAssertEqual(
            releases.sorted(by: ClaudeModelFamilyCatalog.pointReleasePrecedes)
                .map(\.rawModelID),
            [
                "claude-fable-5-10",
                "claude-fable-5-2-20260902",
                "claude-fable-5-2-20260901",
                "claude-fable-5-2"
            ]
        )
    }

    func testAnthropicTraitsUseStrictGrammarAndKeepSonnetFamilyLegacy() {
        XCTAssertEqual(
            AnthropicModelFamilyTraits.resolve(modelID: "claude-fable-5-2")
                .requestShape,
            .adaptiveEffort
        )
        XCTAssertEqual(
            AnthropicModelFamilyTraits.resolve(modelID: "claude-opus-5-2-20260902")
                .requestShape,
            .adaptiveEffort
        )

        for modelID in [
            "claude-fable-5-2-preview",
            "claude-fable-50",
            "claude-opus-5-thinking",
            "claude-sonnet-5",
            "claude-sonnet-5-2"
        ] {
            XCTAssertEqual(
                AnthropicModelFamilyTraits.resolve(modelID: modelID).requestShape,
                .legacy,
                "Expected legacy shaping for \(modelID)"
            )
        }
    }
}
