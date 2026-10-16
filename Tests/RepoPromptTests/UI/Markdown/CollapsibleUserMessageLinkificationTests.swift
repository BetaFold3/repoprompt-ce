import AppKit
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class CollapsibleUserMessageLinkificationTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)

    func testEnabledOutputsDecorateOnlyDetectorMatchesWithReservedLinks() throws {
        let displayText = "See docs/report.md and ../notes/đặc-tả.html:12 now."
        let matches = MarkdownFilePathLinkDetector.proseMatches(in: displayText)
        XCTAssertEqual(matches.map(\.path), ["docs/report.md", "../notes/đặc-tả.html:12"])

        let swiftUI = CollapsibleUserMessageLinkification.swiftUIAttributedString(
            displayText,
            enabled: true
        )
        let appKit = CollapsibleUserMessageLinkification.appKitAttributedString(
            displayText,
            font: font,
            enabled: true
        )

        XCTAssertEqual(String(swiftUI.characters), displayText)
        XCTAssertEqual(appKit.string, displayText)

        let swiftUILinks = swiftUI.runs.compactMap { run -> (String, URL)? in
            guard let url = run.link else { return nil }
            return (String(swiftUI[run.range].characters), url)
        }
        XCTAssertEqual(swiftUILinks.map(\.0), matches.map(\.path))
        for (link, match) in zip(swiftUILinks, matches) {
            XCTAssertEqual(ReservedTranscriptFileURLCodec.path(from: link.1), match.path)
        }

        var appKitLinkRanges: [NSRange] = []
        appKit.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: appKit.length)
        ) { value, range, _ in
            guard value != nil else { return }
            appKitLinkRanges.append(range)
        }
        XCTAssertEqual(appKitLinkRanges, matches.map(\.range))

        for match in matches {
            let offset = match.range.location
            let link = try XCTUnwrap(appKit.attribute(.link, at: offset, effectiveRange: nil) as? URL)
            XCTAssertEqual(ReservedTranscriptFileURLCodec.path(from: link), match.path)
            XCTAssertEqual(appKit.attribute(.markdownRawLink, at: offset, effectiveRange: nil) as? String, match.path)
            XCTAssertEqual(appKit.attribute(.markdownDetectedFileLink, at: offset, effectiveRange: nil) as? Bool, true)
            XCTAssertEqual(appKit.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, .linkColor)
            XCTAssertEqual(
                appKit.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int,
                NSUnderlineStyle.single.rawValue
            )
        }

        XCTAssertNil(appKit.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(appKit.attribute(.markdownRawLink, at: 0, effectiveRange: nil))
        XCTAssertNil(appKit.attribute(.markdownDetectedFileLink, at: 0, effectiveRange: nil))
    }

    func testRejectedURLMDXAndMidTokenContentRemainUnlinked() {
        let displayText = [
            "https://example.com/docs/report.html",
            "docs/report.mdx",
            "docs/report.md/more"
        ].joined(separator: " ")

        let swiftUI = CollapsibleUserMessageLinkification.swiftUIAttributedString(
            displayText,
            enabled: true
        )
        let appKit = CollapsibleUserMessageLinkification.appKitAttributedString(
            displayText,
            font: font,
            enabled: true
        )

        XCTAssertEqual(String(swiftUI.characters), displayText)
        XCTAssertEqual(appKit.string, displayText)
        XCTAssertTrue(MarkdownFilePathLinkDetector.proseMatches(in: displayText).isEmpty)
        XCTAssertTrue(swiftUI.runs.allSatisfy { $0.link == nil })
        assertNoAppKitLinkAttributes(appKit)
    }

    func testCollapsedPrefixDoesNotManufactureLinkFromHiddenTokenContinuation() {
        let displayText = String(repeating: "x", count: 485) + " docs/report.md"
        let sourceText = displayText + "/more"

        XCTAssertEqual(displayText.count, 500)
        XCTAssertEqual(
            MarkdownFilePathLinkDetector.proseMatches(in: displayText).map(\.path),
            ["docs/report.md"]
        )
        XCTAssertTrue(MarkdownFilePathLinkDetector.proseMatches(in: sourceText).isEmpty)

        let swiftUI = CollapsibleUserMessageLinkification.swiftUIAttributedString(
            displayText,
            sourceText: sourceText,
            enabled: true
        )
        let appKit = CollapsibleUserMessageLinkification.appKitAttributedString(
            displayText,
            sourceText: sourceText,
            font: font,
            enabled: true
        )

        XCTAssertTrue(swiftUI.runs.allSatisfy { $0.link == nil })
        assertNoAppKitLinkAttributes(appKit)
    }

    @MainActor
    func testExpandedDetectedLinkClickPreservesPercentShapedFilename() async throws {
        let path = "docs/50%20off.md"
        let attributed = CollapsibleUserMessageLinkification.appKitAttributedString(
            path,
            font: font,
            enabled: true
        )
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)

        var openedTarget: MarkdownFileLinkTarget?
        let opened = expectation(description: "Detected link routed through opener")
        let coordinator = MarkdownTextViewCoordinator()
        coordinator.opener = MarkdownFileLinkOpener { target in
            openedTarget = target
            opened.fulfill()
            return true
        }

        let link = try XCTUnwrap(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertTrue(coordinator.textView(textView, clickedOnLink: link, at: 0))
        await fulfillment(of: [opened], timeout: 1)

        XCTAssertEqual(openedTarget?.normalizedPath, path)
        XCTAssertTrue(openedTarget?.isAutoDetected == true)
    }

    func testDefaultDisabledOutputsRemainPlain() {
        let displayText = "See docs/report.md and notes/plan.html."

        let swiftUI = CollapsibleUserMessageLinkification.swiftUIAttributedString(displayText)
        let appKit = CollapsibleUserMessageLinkification.appKitAttributedString(
            displayText,
            font: font
        )

        XCTAssertEqual(String(swiftUI.characters), displayText)
        XCTAssertEqual(appKit.string, displayText)
        XCTAssertTrue(swiftUI.runs.allSatisfy { $0.link == nil })
        assertNoAppKitLinkAttributes(appKit)
    }

    func testBoundedDisplayedPrefixScanMatchesUnboundedScanForTargetedCuts() {
        let pad = String(repeating: "w", count: 7) + " "
        let sources = [
            pad + "README.md.x more README.md tail",
            pad + "README.md.\nmore",
            pad + "README.md.\r\nx docs/a.md",
            pad + "docs/report.md:123 and notes/plan.html:7, done",
            pad + "docs/report.md: next.md:12a x.md:99",
            String(repeating: "a", count: 600) + ".md " + String(repeating: "b", count: 50),
            pad + String(repeating: "c/", count: 200) + "deep.md, " + String(repeating: "d", count: 300),
            pad + "../notes/đặc-tả.html:12 😀 x.md 👩‍💻 y.htm 🇺🇸 z.markdown",
            pad + "e\u{0301}.md \u{0301}a.md b.md\u{0301} c.MD! d.Md? e.md) f.md] g.md} h.md; i.md, j.md.",
            pad + "a.md\u{0301} later.md",
            pad + "a.md\u{0301} later text without needles",
            pad + "let ys = xs.map(f) // see foo.h and bar.hpp, a.max video.mov clip.mp4 x.m then docs/notes.md",
            pad + "let ys = xs.map(f) // see foo.h and bar.hpp, a.max video.mov clip.mp4 x.m and nothing else",
            pad + "xs.map(f) foo.h " + String(repeating: "filler ", count: 30) + "README.md",
            pad + "xs.map(f) foo.h " + String(repeating: "filler ", count: 30) + "README.txt",
            pad + "tab\ta.md\u{00A0}b.md\u{3000}c.md\u{2028}d.md\u{0085}e.md\u{000B}f.md",
            pad + "https://example.com/a.md a.mdx a.md/more ~/x.md ./y.md ../z.md /abs.md",
            pad + "x.mar\u{212A}down y.HTML z.htm.",
            pad + "ends with path.md",
            pad + "ends with path.md ",
            pad + "ends with path.md  ",
            pad + "ends.md \r\n",
            "no extension candidates here at all, just words and more words"
        ]
        var tally = ComparisonTally()
        for source in sources {
            let utf16Length = source.utf16.count
            for characterCount in 0 ... source.count + 1 {
                let displayText = String(source.prefix(characterCount))
                tally.record(assertMatchesUnboundedOrAcceptedDivergence(displayText: displayText, sourceText: source))
            }
            for displayedLength in 0 ... utf16Length + 1 {
                let displayText = String(repeating: "x", count: displayedLength)
                tally.record(assertMatchesUnboundedOrAcceptedDivergence(displayText: displayText, sourceText: source))
            }
        }
        XCTAssertGreaterThan(tally.boundedCount, 500, "Targeted cuts must exercise the bounded prefix path")
        XCTAssertGreaterThan(tally.nonEmptyCount, 100, "Targeted cuts must include displayed matches")
        XCTAssertGreaterThan(tally.acceptedDivergenceCount, 0, "Targeted cuts must reach the accepted divergence")
    }

    func testBoundedDisplayedPrefixScanMatchesUnboundedScanForSeededRandomText() {
        let fragments = [
            "README.md", "README.md.x", ".md", ".MD", ".Md", "docs/report.md", "a.md:123", ":123", ":", "12",
            "notes/plan.html", "x.htm", "y.markdown", "Z.HTML", ".mar\u{212A}down", "a.mdx", "a.md/more",
            "https://x.com/a.md", "../", "./", "~/", "/", "#", ".", ",", ";", "!", "?", ")", "]", "}", "(",
            "\"", "'", "`", "<", "md", "html", "m", "h", "x", "_", "-", "xxxxxxxxxxxxxxxx",
            " ", " ", " ", "\n", "\r\n", "\t", "\u{00A0}", "\u{3000}", "\u{2028}", "\u{0085}", "\u{000B}",
            "é", "e\u{0301}", "\u{0301}", "đặc-tả", "😀", "👩‍💻", "🇺🇸", "中文", "\u{200D}",
            ".map(", "foo.h", ".hpp", ".max", ".mov", ".mp4", ".m", ".H"
        ]
        var generator = SeededGenerator(seed: 0xD6C0_11A9_5ED5_CA17)
        var tally = ComparisonTally()
        for _ in 0 ..< 1500 {
            let fragmentCount = Int.random(in: 1 ... 60, using: &generator)
            var source = ""
            for _ in 0 ..< fragmentCount {
                source += fragments.randomElement(using: &generator)!
            }
            if Int.random(in: 0 ..< 10, using: &generator) == 0 {
                source += String(repeating: "q", count: Int.random(in: 1 ... 400, using: &generator))
            }
            let utf16Length = source.utf16.count
            for probe in 0 ..< 8 {
                let displayText = if probe.isMultiple(of: 2) {
                    String(source.prefix(Int.random(in: 0 ... source.count + 1, using: &generator)))
                } else {
                    String(repeating: "x", count: Int.random(in: 0 ... utf16Length + 1, using: &generator))
                }
                tally.record(assertMatchesUnboundedOrAcceptedDivergence(displayText: displayText, sourceText: source))
            }
        }
        XCTAssertGreaterThan(tally.boundedCount, 3000, "Random cuts must exercise the bounded prefix path")
        XCTAssertGreaterThan(tally.nonEmptyCount, 1000, "Random cuts must include displayed matches")
    }

    func testDisplayedPathWithCombiningMarkLinksOnlyWhenBoundedPrefixPassesPrecheck() {
        let pad = String(repeating: "w", count: 7) + " "
        let displayedPath = pad + "a.md\u{0301}"
        for suffix in [" later.md tail", " later text tail"] {
            let source = displayedPath + suffix
            // Accepted divergence: the old full-text scan linked `a.md` whenever a supported path
            // appeared anywhere later; the bounded scan depends only on its own prefix.
            XCTAssertEqual(
                unboundedDisplayedMatches(displayText: displayedPath, sourceText: source).map(\.path),
                suffix.contains(".md") ? ["a.md"] : [],
                suffix
            )
            XCTAssertTrue(
                CollapsibleUserMessageLinkification.matches(in: displayedPath, sourceText: source).isEmpty,
                suffix
            )
        }

        // A recognizable needle inside the bounded prefix lets the combining-mark path link too.
        let source = pad + "a.md\u{0301} b.md later tail"
        let displayText = pad + "a.md\u{0301} b.md"
        XCTAssertEqual(
            CollapsibleUserMessageLinkification.matches(in: displayText, sourceText: source).map(\.path),
            ["a.md", "b.md"]
        )
        XCTAssertEqual(
            CollapsibleUserMessageLinkification.matches(in: displayText, sourceText: source),
            unboundedDisplayedMatches(displayText: displayText, sourceText: source)
        )
    }

    func testBoundedDetectionPrefixCutsAfterWhitespaceWithoutSplittingCharacters() throws {
        let source = "ab.md \u{1F600}tail and more"
        let bounded = try XCTUnwrap(
            CollapsibleUserMessageLinkification.boundedDetection(of: source, displayedUTF16Length: 2)
        )
        // Whitespace at 5; the cut at 7 would split the emoji's surrogate pair, so it widens to 8.
        XCTAssertEqual(bounded.prefix, "ab.md \u{1F600}")
        XCTAssertEqual(bounded.whitespaceOffset, 5)
        XCTAssertNil(CollapsibleUserMessageLinkification.boundedDetection(of: source, displayedUTF16Length: 99))
        XCTAssertNil(CollapsibleUserMessageLinkification.boundedDetection(of: "abc.md x", displayedUTF16Length: 1))
        XCTAssertNil(CollapsibleUserMessageLinkification.boundedDetection(
            of: String(repeating: "z", count: 40) + ".md",
            displayedUTF16Length: 5
        ))
    }

    private enum ComparisonOutcome {
        case unboundedPath(isEmpty: Bool)
        case boundedEqual(isEmpty: Bool)
        case acceptedDivergence
    }

    private struct ComparisonTally {
        var boundedCount = 0
        var nonEmptyCount = 0
        var acceptedDivergenceCount = 0

        mutating func record(_ outcome: ComparisonOutcome) {
            switch outcome {
            case let .unboundedPath(isEmpty):
                nonEmptyCount += isEmpty ? 0 : 1
            case let .boundedEqual(isEmpty):
                boundedCount += 1
                nonEmptyCount += isEmpty ? 0 : 1
            case .acceptedDivergence:
                boundedCount += 1
                acceptedDivergenceCount += 1
            }
        }
    }

    /// Asserts the bounded result equals the old unbounded one, except for the accepted divergence:
    /// the bounded prefix fails the needle precheck, so nothing links, while every displayed match the
    /// full text links ends inside a composed character sequence (for example `x.md` + combining mark).
    private func assertMatchesUnboundedOrAcceptedDivergence(
        displayText: String,
        sourceText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ComparisonOutcome {
        let actual = CollapsibleUserMessageLinkification.matches(in: displayText, sourceText: sourceText)
        let expected = unboundedDisplayedMatches(displayText: displayText, sourceText: sourceText)
        let context = "displayed \(displayText.utf16.count) in \(sourceText.debugDescription)"
        guard let bounded = CollapsibleUserMessageLinkification.boundedDetection(
            of: sourceText,
            displayedUTF16Length: displayText.utf16.count
        ) else {
            XCTAssertEqual(actual, expected, context, file: file, line: line)
            return .unboundedPath(isEmpty: expected.isEmpty)
        }
        if actual == expected {
            return .boundedEqual(isEmpty: expected.isEmpty)
        }
        let source = sourceText as NSString
        let isAcceptedDivergence = actual.isEmpty
            && !MarkdownFilePathLinkDetector.containsSupportedExtension(in: bounded.prefix)
            && expected.allSatisfy { match in
                let end = NSMaxRange(match.range)
                return end < source.length && source.rangeOfComposedCharacterSequence(at: end).location < end
            }
        XCTAssertTrue(isAcceptedDivergence, "unexpected divergence: \(actual) vs \(expected); \(context)", file: file, line: line)
        return .acceptedDivergence
    }

    /// The pre-bounding behavior: detect over the whole source, then keep displayed matches.
    private func unboundedDisplayedMatches(
        displayText: String,
        sourceText: String
    ) -> [MarkdownFilePathLinkDetector.Match] {
        let displayedUTF16Length = displayText.utf16.count
        return MarkdownFilePathLinkDetector.proseMatches(in: sourceText).filter {
            NSMaxRange($0.range) <= displayedUTF16Length &&
                Range($0.range, in: displayText) != nil
        }
    }

    private func assertNoAppKitLinkAttributes(
        _ attributedString: NSAttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for key in [
            NSAttributedString.Key.link,
            .markdownRawLink,
            .markdownDetectedFileLink
        ] {
            attributedString.enumerateAttribute(
                key,
                in: NSRange(location: 0, length: attributedString.length)
            ) { value, range, _ in
                XCTAssertNil(value, "\(key.rawValue) unexpectedly set at \(range)", file: file, line: line)
            }
        }
    }
}

/// SplitMix64: deterministic across runs and platforms.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
