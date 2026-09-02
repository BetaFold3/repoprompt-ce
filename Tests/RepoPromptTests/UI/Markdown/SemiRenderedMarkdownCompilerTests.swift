import AppKit
import Foundation
import Markdown
@testable import RepoPromptApp
import XCTest

/// Contract tests for the semi-rendered Markdown decorator.
///
/// The load-bearing contract is `output.string == source`: the Preview panel
/// promises that selecting and copying rendered Markdown yields the original
/// document byte-for-byte. Placement assertions use a probe theme whose colours
/// are all distinct, so "the marker was tinted" cannot pass by accident just
/// because two semantic colours happen to be the same in the shipping theme.
final class SemiRenderedMarkdownCompilerTests: XCTestCase {
    private static let baseFontSize: CGFloat = 14

    private static let probeTheme = SemiRenderedMarkdownTheme(
        bodyColor: .systemBlue,
        markerColor: .systemRed,
        quoteColor: .systemGreen,
        linkColor: .systemOrange,
        linkChromeColor: .systemPurple,
        codeColor: .systemBrown
    )

    // MARK: - The invariant

    func testOutputStringEqualsTheSourceForEveryCorpusDocument() {
        for document in SemiRenderedMarkdownCorpus.documents {
            let output = render(document.text)
            XCTAssertEqual(
                output.string,
                document.text,
                "\(document.name): the decorator must never add, drop, or reorder a character"
            )
            XCTAssertEqual(
                output.length,
                (document.text as NSString).length,
                "\(document.name): UTF-16 length must match the source exactly"
            )
        }
    }

    func testRandomizedMarkdownPreservesTheSourceAndLeavesNoUnstyledOrInvalidRanges() {
        // Deterministic: a fixed seed means a failure reproduces exactly from
        // the reported iteration index.
        var generator = MarkdownFuzzGenerator(seed: 0x5350_4C49_544D_4958)
        let iterations = 400

        for iteration in 0 ..< iterations {
            let source = iteration.isMultiple(of: 2)
                ? SemiRenderedMarkdownFuzz.synthesizedDocument(using: &generator)
                : SemiRenderedMarkdownFuzz.mutatedCorpusDocument(using: &generator)

            let output = render(source)

            XCTAssertEqual(
                output.string,
                source,
                "iteration \(iteration): invariant violated for source \(source.debugDescription)"
            )

            let full = NSRange(location: 0, length: output.length)
            guard full.length > 0 else { continue }

            var unstyledFontLength = 0
            output.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                XCTAssertTrue(
                    range.location >= 0 && NSMaxRange(range) <= output.length,
                    "iteration \(iteration): attribute run escaped the string"
                )
                if !(value is NSFont) {
                    unstyledFontLength += range.length
                }
            }
            XCTAssertEqual(unstyledFontLength, 0, "iteration \(iteration): every character needs a font")

            var unstyledColorLength = 0
            output.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
                if !(value is NSColor) {
                    unstyledColorLength += range.length
                }
            }
            XCTAssertEqual(unstyledColorLength, 0, "iteration \(iteration): every character needs a colour")
        }
    }

    // MARK: - Typography

    func testHeadingsUseTheSharedTypographicScaleAndQuietTheirMarkers() {
        let source = "# One\n\n## Two\n\n### Three\n\n#### Four\n\nBody text.\n"
        let output = render(source)

        // Ratios mirror EnhancedMarkdownCompiler so both renderers read as one
        // product: 1.8 / 1.5 / 1.3 / 1.15 of the 14pt body size.
        let expected: [(text: String, size: CGFloat)] = [
            ("One", 25.2),
            ("Two", 21.0),
            ("Three", 18.2),
            ("Four", 16.1)
        ]
        for (text, size) in expected {
            let font = fontAt(output, indexOf: text, in: source)
            XCTAssertEqual(font?.pointSize ?? 0, size, accuracy: 0.01, "\(text) heading size")
            XCTAssertTrue(
                font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                "\(text) heading content stays bold"
            )
        }

        // The leading hash keeps the heading's size but drops to regular weight
        // and the marker tint, so it reads as structure rather than content.
        let hashIndex = 0
        let hashFont = font(output, at: hashIndex)
        XCTAssertEqual(hashFont?.pointSize ?? 0, 25.2, accuracy: 0.01)
        XCTAssertFalse(hashFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
        XCTAssertEqual(color(output, at: hashIndex), Self.probeTheme.markerColor)

        XCTAssertEqual(
            colorAt(output, indexOf: "One", in: source),
            Self.probeTheme.bodyColor,
            "heading text keeps body colour"
        )
        XCTAssertEqual(
            fontAt(output, indexOf: "Body text.", in: source)?.pointSize ?? 0,
            Self.baseFontSize,
            accuracy: 0.01
        )
    }

    func testShippingThemeKeepsMarkersVisiblyDistinctFromBodyText() {
        let theme = SemiRenderedMarkdownTheme.standard
        XCTAssertEqual(theme.bodyColor, .textColor)
        XCTAssertEqual(theme.markerColor, .secondaryLabelColor)
        XCTAssertNotEqual(
            theme.markerColor,
            theme.bodyColor,
            "markers must be tinted away from body text, not merely present"
        )

        let source = "# Heading\n"
        let output = SemiRenderedMarkdownCompiler(
            fontSize: Self.baseFontSize,
            theme: .standard
        ).attributedString(for: source)
        XCTAssertEqual(output.string, source)
        XCTAssertEqual(color(output, at: 0), NSColor.secondaryLabelColor)
    }

    // MARK: - Inline constructs

    func testInlineDelimitersStyleTheirContentAndTintTheirMarkers() {
        let source = "Lead **bold** and *slant* and ~~gone~~ and `code` end.\n"
        let output = render(source)

        let boldFont = fontAt(output, indexOf: "bold", in: source)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        let firstAsterisk = (source as NSString).range(of: "**").location
        XCTAssertEqual(color(output, at: firstAsterisk), Self.probeTheme.markerColor)
        XCTAssertFalse(
            font(output, at: firstAsterisk)?.fontDescriptor.symbolicTraits.contains(.bold) ?? true,
            "the ** delimiters stay at content weight, not bold"
        )

        let italicFont = fontAt(output, indexOf: "slant", in: source)
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)

        let struckIndex = (source as NSString).range(of: "gone").location
        XCTAssertEqual(
            output.attribute(.strikethroughStyle, at: struckIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        let tildeIndex = (source as NSString).range(of: "~~").location
        XCTAssertNil(
            output.attribute(.strikethroughStyle, at: tildeIndex, effectiveRange: nil),
            "the ~~ delimiters are not themselves struck through"
        )
        XCTAssertEqual(color(output, at: tildeIndex), Self.probeTheme.markerColor)

        let codeIndex = (source as NSString).range(of: "code").location
        XCTAssertEqual(font(output, at: codeIndex), Self.monospacedProbeFont)
        XCTAssertEqual(color(output, at: codeIndex), Self.probeTheme.codeColor)
        XCTAssertNotNil(output.attribute(.inlineCode, at: codeIndex, effectiveRange: nil))
        let backtickIndex = (source as NSString).range(of: "`code`").location
        XCTAssertEqual(color(output, at: backtickIndex), Self.probeTheme.markerColor)
    }

    func testLinksColourTheirLabelAndDimTheirSurroundingChrome() {
        let source = "See [the docs](https://example.com/page) now.\n"
        let output = render(source)
        let nsSource = source as NSString

        let bracketIndex = nsSource.range(of: "[the docs]").location
        XCTAssertEqual(color(output, at: bracketIndex), Self.probeTheme.linkChromeColor)

        let labelIndex = nsSource.range(of: "the docs").location
        XCTAssertEqual(color(output, at: labelIndex), Self.probeTheme.linkColor)
        XCTAssertEqual(
            output.attribute(.underlineStyle, at: labelIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        let destinationIndex = nsSource.range(of: "https://example.com/page").location
        XCTAssertEqual(color(output, at: destinationIndex), Self.probeTheme.linkChromeColor)

        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: labelIndex, effectiveRange: nil) as? String,
            "https://example.com/page"
        )
        XCTAssertEqual(
            (output.attribute(.link, at: labelIndex, effectiveRange: nil) as? URL)?.absoluteString,
            "https://example.com/page"
        )
    }

    // MARK: - Blocks

    func testFencedCodeKeepsItsFencesVisibleAndMonospacesItsContents() {
        let source = "Intro.\n\n```swift\nlet answer = 42\n```\n\nOutro.\n"
        let output = render(source)
        let nsSource = source as NSString

        let contentIndex = nsSource.range(of: "let answer").location
        XCTAssertEqual(font(output, at: contentIndex), Self.monospacedProbeFont)

        let openingFenceIndex = nsSource.range(of: "```swift").location
        XCTAssertEqual(
            color(output, at: openingFenceIndex),
            Self.probeTheme.markerColor,
            "the opening fence and its info string are chrome"
        )
        let closingFenceIndex = nsSource.range(of: "```\n\nOutro").location
        XCTAssertEqual(color(output, at: closingFenceIndex), Self.probeTheme.markerColor)

        XCTAssertNotNil(
            output.attribute(.codeBlockSource, at: contentIndex, effectiveRange: nil),
            "the block is tagged so the text view can draw its background"
        )

        // Prose on either side is untouched by the code styling.
        XCTAssertEqual(fontAt(output, indexOf: "Intro.", in: source)?.pointSize ?? 0, Self.baseFontSize)
        XCTAssertNil(
            output.attribute(
                .codeBlockSource,
                at: nsSource.range(of: "Outro.").location,
                effectiveRange: nil
            )
        )
    }

    func testCodeBlockBackgroundDoesNotOverlapAdjacentProse() {
        let source = "Intro.\n```swift\ncode\n```\nOutro.\n"
        let output = render(source)
        let nsSource = source as NSString
        let textStorage = NSTextStorage(attributedString: output)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var codeSourceRange = NSRange(location: NSNotFound, length: 0)
        let openingFenceIndex = nsSource.range(of: "```swift").location
        XCTAssertNotNil(
            output.attribute(
                .codeBlockSource,
                at: openingFenceIndex,
                effectiveRange: &codeSourceRange
            )
        )
        guard codeSourceRange.location != NSNotFound else { return }

        let codeGlyphRange = layoutManager.glyphRange(
            forCharacterRange: codeSourceRange,
            actualCharacterRange: nil
        )
        var codeLineFragmentRect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: codeGlyphRange) { lineRect, _, _, _, _ in
            codeLineFragmentRect = codeLineFragmentRect.union(lineRect)
        }
        let blockBackgroundRect = codeLineFragmentRect.insetBy(dx: -6, dy: -6)

        func usedRect(for characterRange: NSRange) -> NSRect {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var result = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                result = result.union(usedRect)
            }
            return result
        }

        let introUsedRect = usedRect(for: nsSource.range(of: "Intro."))
        let outroUsedRect = usedRect(for: nsSource.range(of: "Outro."))
        XCTAssertFalse(
            blockBackgroundRect.intersects(introUsedRect) || blockBackgroundRect.intersects(outroUsedRect),
            "blockBackgroundRect=\(blockBackgroundRect), introUsedRect=\(introUsedRect), "
                + "outroUsedRect=\(outroUsedRect)"
        )
    }

    func testFencedCodeDirectlyAfterProseAddsLeadingBoundarySpacing() {
        let source = "Intro.\n```swift\ncode\n```\n"
        let output = render(source)
        let nsSource = source as NSString
        let introParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "Intro.").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let openingFenceParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "```swift").location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertNotNil(introParagraph)
        XCTAssertGreaterThanOrEqual(introParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertNotNil(openingFenceParagraph)
        XCTAssertEqual(openingFenceParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(openingFenceParagraph?.paragraphSpacing, 0)
        XCTAssertEqual(output.string, source)
    }

    func testFencedCodeDirectlyBeforeProseAddsTrailingBoundarySpacing() {
        let source = "```swift\ncode\n```\nOutro.\n"
        let output = render(source)
        let nsSource = source as NSString
        let closingFenceParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "```\nOutro.").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let outroParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "Outro.").location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertNotNil(closingFenceParagraph)
        XCTAssertEqual(closingFenceParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(closingFenceParagraph?.paragraphSpacing, 0)
        XCTAssertNotNil(outroParagraph)
        XCTAssertGreaterThanOrEqual(outroParagraph?.paragraphSpacingBefore ?? 0, 6)
        XCTAssertEqual(output.string, source)
    }

    func testBlankLineSeparatedFencedCodeKeepsExistingBoundarySpacing() {
        let source = "Intro.\n\n```swift\ncode\n```\n\nOutro.\n"
        let output = render(source)
        let nsSource = source as NSString
        let openingFenceIndex = nsSource.range(of: "```swift").location
        let closingFenceIndex = nsSource.range(of: "```\n\nOutro.").location
        let openingParagraph = output.attribute(
            .paragraphStyle,
            at: openingFenceIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let closingParagraph = output.attribute(
            .paragraphStyle,
            at: closingFenceIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertNotNil(openingParagraph)
        XCTAssertNotNil(closingParagraph)
        XCTAssertEqual(openingParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(openingParagraph?.paragraphSpacing, 0)
        XCTAssertEqual(closingParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(closingParagraph?.paragraphSpacing, 0)
    }

    func testFencedCodeInsideListPreservesIndentWhileAddingBoundarySpacing() {
        let source = "- item\n  ```\n  code\n  ```\n  tail\n"
        let output = render(source)
        let nsSource = source as NSString
        let itemParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "item").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let tailParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "tail").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let openingFenceParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "  ```").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let closingFenceParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "  ```\n  tail").location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertGreaterThanOrEqual(itemParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertGreaterThan(itemParagraph?.headIndent ?? 0, 0)
        XCTAssertGreaterThanOrEqual(tailParagraph?.paragraphSpacingBefore ?? 0, 6)
        XCTAssertGreaterThan(tailParagraph?.headIndent ?? 0, 0)
        XCTAssertEqual(openingFenceParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(openingFenceParagraph?.paragraphSpacing, 0)
        XCTAssertEqual(closingFenceParagraph?.paragraphSpacingBefore, 0)
        XCTAssertEqual(closingFenceParagraph?.paragraphSpacing, 0)
    }

    func testIndentedCodeDirectlyBeforeProseAddsTrailingBoundarySpacing() {
        let source = "    code\nOutro.\n"
        let output = render(source)
        let nsSource = source as NSString
        let codeParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "code").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let outroParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "Outro.").location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertEqual(codeParagraph?.paragraphSpacing, 0)
        XCTAssertGreaterThanOrEqual(outroParagraph?.paragraphSpacingBefore ?? 0, 6)
        XCTAssertEqual(output.string, source)
    }

    func testBackToBackFencedCodeBlocksDoNotAddSpacingToFenceLines() {
        let source = "```first\none\n```\n```second\ntwo\n```\n"
        let output = render(source)
        let nsSource = source as NSString
        let fenceIndices = [
            nsSource.range(of: "```first").location,
            nsSource.range(of: "```\n```second").location,
            nsSource.range(of: "```second").location,
            nsSource.range(of: "```\n", options: .backwards).location
        ]

        for fenceIndex in fenceIndices {
            let paragraph = output.attribute(
                .paragraphStyle,
                at: fenceIndex,
                effectiveRange: nil
            ) as? NSParagraphStyle
            XCTAssertNotNil(paragraph)
            XCTAssertEqual(paragraph?.paragraphSpacingBefore, 0)
            XCTAssertEqual(paragraph?.paragraphSpacing, 0)
        }
        XCTAssertEqual(output.string, source)
    }

    func testBlockQuoteNestedFencePreservesNeighborIndentsWithSpacing() {
        let source = "> before\n> ```\n> code\n> ```\n> after\n"
        let output = render(source)
        let nsSource = source as NSString
        let beforeParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "before").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let afterParagraph = output.attribute(
            .paragraphStyle,
            at: nsSource.range(of: "after").location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertGreaterThanOrEqual(beforeParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertGreaterThan(beforeParagraph?.headIndent ?? 0, 0)
        XCTAssertGreaterThanOrEqual(afterParagraph?.paragraphSpacingBefore ?? 0, 6)
        XCTAssertGreaterThan(afterParagraph?.headIndent ?? 0, 0)
        XCTAssertEqual(output.string, source)
    }

    func testCRLFCodeBlockSpacingCoversNeighborParagraphTerminator() {
        let source = "Intro.\r\n```swift\r\ncode\r\n```\r\nOutro.\r\n"
        let output = render(source)
        let nsSource = source as NSString
        let introRange = nsSource.range(of: "Intro.")
        let introParagraphRange = nsSource.paragraphRange(for: introRange)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let introParagraph = output.attribute(
            .paragraphStyle,
            at: introRange.location,
            effectiveRange: &effectiveRange
        ) as? NSParagraphStyle

        XCTAssertGreaterThanOrEqual(introParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertEqual(NSIntersectionRange(effectiveRange, introParagraphRange), introParagraphRange)
        let carriageReturnIndex = NSMaxRange(introParagraphRange) - 2
        let lineFeedIndex = NSMaxRange(introParagraphRange) - 1
        let carriageReturnParagraph = output.attribute(
            .paragraphStyle,
            at: carriageReturnIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let lineFeedParagraph = output.attribute(
            .paragraphStyle,
            at: lineFeedIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertGreaterThanOrEqual(carriageReturnParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertGreaterThanOrEqual(lineFeedParagraph?.paragraphSpacing ?? 0, 6)
        XCTAssertEqual(output.string, source)
    }

    func testQuotesAndListsTintTheirMarkersAndHangTheirWrappedLines() {
        let source = "> quoted line\n> still quoted\n\n- first item\n- second item\n\n1. ordered one\n"
        let output = render(source)
        let nsSource = source as NSString

        let quotedIndex = nsSource.range(of: "quoted line").location
        XCTAssertEqual(color(output, at: quotedIndex), Self.probeTheme.quoteColor)
        let quoteMarkerIndex = nsSource.range(of: ">").location
        XCTAssertEqual(color(output, at: quoteMarkerIndex), Self.probeTheme.markerColor)
        let quoteParagraph = output.attribute(
            .paragraphStyle,
            at: quotedIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertGreaterThan(quoteParagraph?.headIndent ?? 0, 0, "wrapped quote lines hang past the >")

        let bulletIndex = nsSource.range(of: "- first item").location
        XCTAssertEqual(color(output, at: bulletIndex), Self.probeTheme.markerColor)
        let itemIndex = nsSource.range(of: "first item").location
        XCTAssertEqual(
            color(output, at: itemIndex),
            Self.probeTheme.bodyColor,
            "list content keeps body colour; only the bullet is tinted"
        )
        let listParagraph = output.attribute(
            .paragraphStyle,
            at: itemIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertGreaterThan(listParagraph?.headIndent ?? 0, 0)

        let orderedMarkerIndex = nsSource.range(of: "1.").location
        XCTAssertEqual(color(output, at: orderedMarkerIndex), Self.probeTheme.markerColor)
    }

    func testTablesStayPlainMonospacedTextWithNoTextTableBlocks() {
        let source = "| Name | Count |\n| --- | ---: |\n| alpha | 1 |\n| beta | 2 |\n"
        let output = render(source)
        let nsSource = source as NSString

        XCTAssertEqual(output.string, source)

        // NSTextTable would relayout cell text and break the round trip, so the
        // renderer must never install one.
        var textTableBlocks = 0
        output.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: output.length),
            options: []
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            textTableBlocks += style.textBlocks.count(where: { $0 is NSTextTableBlock })
        }
        XCTAssertEqual(textTableBlocks, 0)

        XCTAssertEqual(
            fontAt(output, indexOf: "alpha", in: source),
            Self.monospacedProbeFont,
            "monospacing preserves the author's own column alignment"
        )
        XCTAssertEqual(color(output, at: 0), Self.probeTheme.markerColor, "leading pipe is a marker")
        let delimiterIndex = nsSource.range(of: "| --- | ---: |").location
        XCTAssertEqual(color(output, at: delimiterIndex + 2), Self.probeTheme.markerColor)
        XCTAssertTrue(
            fontAt(output, indexOf: "Name", in: source)?
                .fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "header row is emphasised without leaving monospace"
        )
    }

    // MARK: - Wiki links

    func testWikiLinksCarryTheirRawTargetAndAreSkippedInsideCodeSpans() {
        let source = "See [[Design Notes|the design]] and [[Plain]] and `[[not a link]]` here.\n"
        let output = render(source)
        let nsSource = source as NSString

        let aliasIndex = nsSource.range(of: "the design").location
        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: aliasIndex, effectiveRange: nil) as? String,
            "Design Notes",
            "the unresolved target travels with the span for a later resolution step"
        )
        XCTAssertEqual(color(output, at: aliasIndex), Self.probeTheme.linkColor)
        XCTAssertEqual(
            output.attribute(.underlineStyle, at: aliasIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        let openingBracketIndex = nsSource.range(of: "[[Design").location
        XCTAssertEqual(color(output, at: openingBracketIndex), Self.probeTheme.linkChromeColor)
        let targetIndex = nsSource.range(of: "Design Notes|").location
        XCTAssertEqual(
            color(output, at: targetIndex),
            Self.probeTheme.linkChromeColor,
            "an aliased target is chrome; the alias is the label"
        )

        let plainIndex = nsSource.range(of: "Plain").location
        XCTAssertEqual(color(output, at: plainIndex), Self.probeTheme.linkColor)
        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: plainIndex, effectiveRange: nil) as? String,
            "Plain"
        )

        let inCodeIndex = nsSource.range(of: "not a link").location
        XCTAssertNil(
            output.attribute(.markdownRawLink, at: inCodeIndex, effectiveRange: nil),
            "a wiki link inside a code span stays literal text"
        )
        XCTAssertEqual(font(output, at: inCodeIndex), Self.monospacedProbeFont)
    }

    func testObsidianEmbedsStayVerbatimAndCarryEmbedLinkStyling() {
        let source = "Image ![[assets/diagram|Architecture]] and note ![[Design Note]].\n"
        let output = render(source)
        let nsSource = source as NSString

        XCTAssertEqual(output.string, source)
        let imageBang = nsSource.range(of: "![[assets").location
        let imageLabel = nsSource.range(of: "Architecture").location
        XCTAssertNotNil(output.attribute(.markdownObsidianEmbed, at: imageBang, effectiveRange: nil))
        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: imageLabel, effectiveRange: nil) as? String,
            "assets/diagram"
        )
        XCTAssertEqual(color(output, at: imageLabel), Self.probeTheme.linkColor)
        XCTAssertEqual(color(output, at: imageBang), Self.probeTheme.linkChromeColor)

        let noteLabel = nsSource.range(of: "Design Note").location
        XCTAssertNotNil(output.attribute(.markdownObsidianEmbed, at: noteLabel, effectiveRange: nil))
    }

    // MARK: - Degenerate input

    func testDegenerateAndMalformedDocumentsRoundTripWithoutSpuriousDecoration() {
        let cases: [(name: String, source: String)] = [
            ("empty", ""),
            ("newlines only", "\n\n\n"),
            ("crlf only", "\r\n\r\n"),
            ("unclosed strong", "text **unclosed here\n"),
            ("unclosed fence", "```swift\nlet x = 1\n"),
            ("unterminated wiki link", "see [[unterminated and more\n"),
            ("bare brackets", "[[]] and [[|]] and ]]\n"),
            ("pipes without a table", "| not | a | table |\n"),
            ("deep quote", String(repeating: "> ", count: 24) + "deep\n"),
            ("no trailing newline", "# Heading without newline"),
            ("lone carriage returns", "# A\rbody\rmore")
        ]

        for testCase in cases {
            let output = render(testCase.source)
            XCTAssertEqual(output.string, testCase.source, "\(testCase.name): invariant")
        }

        // An unterminated wiki link must not attach a raw link to anything.
        let unterminated = render("see [[unterminated and more\n")
        var rawLinkRuns = 0
        unterminated.enumerateAttribute(
            .markdownRawLink,
            in: NSRange(location: 0, length: unterminated.length),
            options: []
        ) { value, _, _ in
            if value != nil { rawLinkRuns += 1 }
        }
        XCTAssertEqual(rawLinkRuns, 0)

        // An empty wiki target is not a link either.
        let empty = render("[[]] and [[|]]\n")
        XCTAssertNil(empty.attribute(.markdownRawLink, at: 0, effectiveRange: nil))
    }

    // MARK: - Helpers

    private static var monospacedProbeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)
    }

    private func render(_ source: String) -> NSAttributedString {
        SemiRenderedMarkdownCompiler(
            fontSize: Self.baseFontSize,
            theme: Self.probeTheme
        ).attributedString(for: source)
    }

    private func font(_ output: NSAttributedString, at index: Int) -> NSFont? {
        guard index >= 0, index < output.length else { return nil }
        return output.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private func color(_ output: NSAttributedString, at index: Int) -> NSColor? {
        guard index >= 0, index < output.length else { return nil }
        return output.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func fontAt(_ output: NSAttributedString, indexOf substring: String, in source: String) -> NSFont? {
        let range = (source as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return font(output, at: range.location)
    }

    private func colorAt(_ output: NSAttributedString, indexOf substring: String, in source: String) -> NSColor? {
        let range = (source as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return color(output, at: range.location)
    }
}

// MARK: - Corpus

enum SemiRenderedMarkdownCorpus {
    static let documents: [(name: String, text: String)] = [
        ("empty", ""),
        ("plain paragraph", "Just a sentence with no markup at all.\n"),
        ("kitchen sink", """
        # Release Notes

        Intro paragraph with **bold**, *italic*, `inline code`, ~~struck~~ and a
        [link](https://example.com/docs) plus a [[Wiki Target|wiki alias]].

        ## Details

        - first bullet
        - second bullet with a very long trailing clause that will wrap in any
          reasonable panel width
          - nested bullet
        1. ordered
        2. also ordered

        > A quotation that runs
        > across two source lines.

        ```swift
        struct Example {
            let value: Int
        }
        ```

        | Column | Meaning |
        | --- | ---: |
        | a | first |
        | b | second |

        ---

        Closing paragraph.

        """),
        ("crlf kitchen sink", """
        # Release Notes\r
        \r
        Body with **bold** and `code`.\r
        \r
        - bullet one\r
        - bullet two\r
        \r
        ```text\r
        fenced content\r
        ```\r
        """),
        ("unicode heavy", """
        # 見出し 😀

        Paragraph with 漢字, e\u{0301}mojis 🚀🚀, and **強調** plus `co\u{0301}de`.

        - 項目 😀
        - e\u{0301}le\u{0301}ment

        > 引用 🚀

        """),
        ("setext and breaks", """
        Setext Title
        ============

        Secondary
        ---------

        ***

        Text with an ![image](assets/pic.png) and <b>raw html</b>.

        """),
        ("nested containers", """
        > outer quote
        > > inner quote
        > > - quoted bullet
        >
        > back to outer

        - item
          > quote inside a list item
          ```
          code inside a list item
          ```

        """),
        ("no trailing newline", "# Final heading\n\nLast paragraph without a newline"),
        ("only a fence", "```\nliteral\n```"),
        ("wiki and code collision", "A [[Real Link]] then `[[literal]]` then [[Other|alias]].\n"),
        ("hard tabs", "-\titem after a tab\n\n\tindented code block\n\n| a\t| b |\n| --- | --- |\n"),
        ("reference and autolink", """
        Text with an autolink <https://example.com> and a [reference][ref].

        [ref]: https://example.com/reference

        """)
    ]
}

// MARK: - Fuzzing

/// Deterministic SplitMix64. Seeded explicitly so a failing iteration is
/// reproducible rather than a one-off.
struct MarkdownFuzzGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SemiRenderedMarkdownFuzz {
    /// Tokens chosen so random concatenation lands on the delimiter-scanning
    /// edges: unbalanced runs, half-open fences, brackets, pipes, tabs, CRLF
    /// and multi-byte scalars.
    private static let tokens = [
        "#", "##", "######", "**", "*", "_", "__", "~~", "`", "``", "```",
        "```swift", "~~~", ">", "- ", "+ ", "1. ", "12) ", "[", "]", "(", ")",
        "[[", "]]", "|", "---", ":---", "![", "<b>", "</b>", "\\", "!", ".",
        "\n", "\n\n", "\r\n", "\t", "    ", " ", "word", "longer phrase",
        "😀", "漢字", "e\u{0301}", "𝔘", "https://example.com", "a|b"
    ]

    /// Keeps fuzz documents small enough that 400 parse-and-render rounds stay
    /// in the fast tier.
    private static let maximumMutatedLength = 8000

    static func synthesizedDocument(using generator: inout MarkdownFuzzGenerator) -> String {
        let count = Int.random(in: 5 ... 60, using: &generator)
        var text = ""
        for _ in 0 ..< count {
            text += tokens.randomElement(using: &generator) ?? " "
        }
        return text
    }

    static func mutatedCorpusDocument(using generator: inout MarkdownFuzzGenerator) -> String {
        let seedText = SemiRenderedMarkdownCorpus.documents
            .randomElement(using: &generator)?.text ?? ""
        var characters = Array(seedText)
        let mutations = Int.random(in: 1 ... 8, using: &generator)

        for _ in 0 ..< mutations {
            guard !characters.isEmpty else {
                characters = Array(tokens.randomElement(using: &generator) ?? " ")
                continue
            }
            switch Int.random(in: 0 ... 2, using: &generator) {
            case 0:
                characters.remove(at: Int.random(in: 0 ..< characters.count, using: &generator))
            case 1:
                let insertion = tokens.randomElement(using: &generator) ?? " "
                let at = Int.random(in: 0 ... characters.count, using: &generator)
                characters.insert(contentsOf: Array(insertion), at: at)
            default:
                guard characters.count < maximumMutatedLength else { continue }
                let lower = Int.random(in: 0 ..< characters.count, using: &generator)
                let upperBound = min(lower + 64, characters.count)
                let upper = Int.random(in: lower ..< upperBound, using: &generator)
                let slice = Array(characters[lower ... upper])
                characters.insert(contentsOf: slice, at: lower)
            }
        }
        return String(characters)
    }
}
