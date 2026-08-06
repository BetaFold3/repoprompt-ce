import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorBracketModelIDTests: XCTestCase {
    func testObservedCorpusParseComposeRoundTrips() throws {
        let cases: [(raw: String, base: String, params: [CursorBracketModelID.Parameter], hasBracket: Bool)] = [
            (
                "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]",
                "gpt-5.6-sol",
                [
                    .init(key: "context", value: "272k"),
                    .init(key: "reasoning", value: "medium"),
                    .init(key: "fast", value: "false")
                ],
                true
            ),
            (
                "grok-4.5[effort=high,fast=true]",
                "grok-4.5",
                [
                    .init(key: "effort", value: "high"),
                    .init(key: "fast", value: "true")
                ],
                true
            ),
            (
                "composer-2.5[fast=true]",
                "composer-2.5",
                [.init(key: "fast", value: "true")],
                true
            ),
            ("gemini-2.5-flash[]", "gemini-2.5-flash", [], true),
            ("default[]", "default", [], true),
            ("gpt-5.6-sol", "gpt-5.6-sol", [], false),
            ("default", "default", [], false)
        ]

        for testCase in cases {
            let parsed = try XCTUnwrap(CursorBracketModelID.parse(testCase.raw), testCase.raw)
            XCTAssertEqual(parsed.base, testCase.base, testCase.raw)
            XCTAssertEqual(parsed.params, testCase.params, testCase.raw)
            XCTAssertEqual(parsed.hasBracket, testCase.hasBracket, testCase.raw)

            let composed = try XCTUnwrap(
                CursorBracketModelID.compose(base: parsed.base, params: parsed.params),
                testCase.raw
            )
            let expected = testCase.hasBracket ? testCase.raw : "\(testCase.raw)[]"
            XCTAssertEqual(composed, expected, testCase.raw)
        }
    }

    func testParseTrimsOuterWhitespace() throws {
        let parsed = try XCTUnwrap(
            CursorBracketModelID.parse("  gpt-5.6-sol [ context = 272k , reasoning = medium ]  ")
        )

        XCTAssertEqual(parsed.base, "gpt-5.6-sol")
        XCTAssertEqual(
            parsed.params,
            [
                .init(key: "context", value: "272k"),
                .init(key: "reasoning", value: "medium")
            ]
        )
        XCTAssertTrue(parsed.hasBracket)
    }

    func testMalformedInputsAreRejected() {
        let malformed = [
            "gpt-5.6-sol[reasoning=high",
            "gpt-5.6-sol[reasoning=[high]]",
            "gpt-5.6-sol[reasoning=high]trailing",
            "gpt-5.6-sol[=high]",
            "gpt-5.6-sol[reasoning=]",
            "gpt-5.6-sol[reasoning=high,reasoning=low]",
            "gpt-5.6-sol[reasoning=high,Reasoning=low]",
            "[]",
            "gpt-5.6-sol[=]",
            "gpt-5.6-sol[reasoning=high=extra]",
            "gpt-5.6-sol[reasoning=high,]",
            "gpt-5.6-sol]"
        ]

        for raw in malformed {
            XCTAssertNil(CursorBracketModelID.parse(raw), raw)
        }
    }

    func testComposeMovesFastLastAndRejectsUnrepresentableInput() throws {
        let composed = try XCTUnwrap(
            CursorBracketModelID.compose(
                base: " gpt-5.6-sol ",
                params: [
                    .init(key: "Fast", value: " true "),
                    .init(key: " context ", value: " 1m "),
                    .init(key: "reasoning", value: "high")
                ]
            )
        )
        XCTAssertEqual(composed, "gpt-5.6-sol[context=1m,reasoning=high,Fast=true]")

        let invalidParameters = [
            CursorBracketModelID.Parameter(key: "reasoning", value: "high,fast=true"),
            CursorBracketModelID.Parameter(key: "reasoning", value: "high=extra"),
            CursorBracketModelID.Parameter(key: "reasoning", value: "[high]"),
            CursorBracketModelID.Parameter(key: "reasoning]", value: "high")
        ]
        for parameter in invalidParameters {
            XCTAssertNil(
                CursorBracketModelID.compose(base: "gpt-5.6-sol", params: [parameter]),
                "\(parameter)"
            )
        }

        XCTAssertNil(
            CursorBracketModelID.compose(
                base: "gpt-5.6-sol",
                params: [
                    .init(key: "fast", value: "true"),
                    .init(key: "FAST", value: "false")
                ]
            )
        )
    }

    func testCursorPrefixHelperStripsAtMostOnePrefix() {
        XCTAssertEqual(
            CursorBracketModelID.strippingCursorPrefix(
                " cursor:gpt-5.6-sol[reasoning=medium,fast=false] "
            ),
            "gpt-5.6-sol[reasoning=medium,fast=false]"
        )
        XCTAssertEqual(CursorBracketModelID.strippingCursorPrefix("default[]"), "default[]")
        XCTAssertEqual(
            CursorBracketModelID.strippingCursorPrefix("cursor:cursor:default[]"),
            "cursor:default[]"
        )
    }

    func testKillSwitchDefaultsOnAndReadsOverride() throws {
        let suiteName = "CursorBracketModelIDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(CursorParameterizedModels.isEnabled(defaults: defaults))
        defaults.set(false, forKey: CursorParameterizedModels.userDefaultsKey)
        XCTAssertFalse(CursorParameterizedModels.isEnabled(defaults: defaults))
        defaults.set(true, forKey: CursorParameterizedModels.userDefaultsKey)
        XCTAssertTrue(CursorParameterizedModels.isEnabled(defaults: defaults))
    }
}
