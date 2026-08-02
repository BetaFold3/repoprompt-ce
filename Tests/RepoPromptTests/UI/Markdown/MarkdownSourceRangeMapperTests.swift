import Foundation
import Markdown
@testable import RepoPromptApp
import XCTest

/// Pins the swift-markdown source-position semantics that
/// `MarkdownSourceRangeMapper` depends on. The right-utility-panel plan called
/// out Unicode/CRLF column semantics as an unverified assumption, so these
/// tests assert the raw `SourceLocation` numbers as well as the mapped
/// `NSRange`s: if a future swift-markdown bump changes the convention the
/// column assertions fail loudly instead of silently shifting decorations.
final class MarkdownSourceRangeMapperTests: XCTestCase {
    // MARK: - Column semantics

    func testColumnsAreOneBasedUTF8ByteOffsetsWithinTheirLine() throws {
        // Byte columns: 😀 = 1...4, " " = 5, 漢 = 6...8, " " = 9, "e" = 10,
        // U+0301 = 11...12, " " = 13, so "**bold**" occupies bytes 14...21.
        let source = "😀 漢 e\u{0301} **bold** and `co\u{0301}de` tail"
        let mapper = MarkdownSourceRangeMapper(source: source)
        let document = Document(parsing: source, options: [.disableSmartOpts])

        let strong = try XCTUnwrap(MarkdownTestNodes.first(Strong.self, in: document))
        let strongRange = try XCTUnwrap(strong.range)
        XCTAssertEqual(strongRange.lowerBound.line, 1)
        XCTAssertEqual(strongRange.lowerBound.column, 14, "start column counts UTF-8 bytes, not characters")
        XCTAssertEqual(strongRange.upperBound.column, 22, "end column is exclusive: 14 + 8 delimiter/content bytes")

        let mappedStrong = try XCTUnwrap(mapper.nsRange(for: strongRange))
        XCTAssertEqual(mappedStrong, NSRange(location: 8, length: 8))
        XCTAssertEqual((source as NSString).substring(with: mappedStrong), "**bold**")

        // The inline code span is the sharpest case: 8 UTF-8 bytes but only 7
        // UTF-16 units, because the combining acute is 2 bytes and 1 unit.
        let code = try XCTUnwrap(MarkdownTestNodes.first(InlineCode.self, in: document))
        let codeRange = try XCTUnwrap(code.range)
        XCTAssertEqual(codeRange.lowerBound.column, 27)
        XCTAssertEqual(codeRange.upperBound.column, 35, "8 UTF-8 bytes wide")

        let mappedCode = try XCTUnwrap(mapper.nsRange(for: codeRange))
        XCTAssertEqual(mappedCode, NSRange(location: 21, length: 7), "7 UTF-16 units wide")
        XCTAssertEqual((source as NSString).substring(with: mappedCode), "`co\u{0301}de`")
    }

    func testEveryMappedNodeRangeReproducesItsOwnSourceTextAcrossUnicodeForms() {
        let cases: [(name: String, source: String, marked: String)] = [
            ("emoji", "🚀🚀 **go** 🚀", "**go**"),
            ("cjk", "漢字テスト **強調** 漢字", "**強調**"),
            ("combining", "e\u{0301}e\u{0301} *sla\u{0301}nt* e\u{0301}", "*sla\u{0301}nt*"),
            ("astral-mix", "𝔘𝔫𝔦 `co𝔡e` 𝔘", "`co𝔡e`"),
            ("tabs", "a\tb **c** \td", "**c**")
        ]

        for testCase in cases {
            let mapper = MarkdownSourceRangeMapper(source: testCase.source)
            let document = Document(parsing: testCase.source, options: [.disableSmartOpts])
            let node = MarkdownTestNodes.firstInlineWithRange(in: document) { markup in
                markup is Strong || markup is Emphasis || markup is InlineCode
            }
            guard let node, let range = node.range, let mapped = mapper.nsRange(for: range) else {
                XCTFail("\(testCase.name): expected a mappable inline node")
                continue
            }
            XCTAssertEqual(
                (testCase.source as NSString).substring(with: mapped),
                testCase.marked,
                "\(testCase.name): mapped range must reproduce the verbatim delimited span"
            )
        }
    }

    func testTabIsASingleByteColumnInsideAParagraph() throws {
        // "a" = 1, tab = 2, "b" = 3, " " = 4 so "**c**" starts at byte 5 even
        // though the tab renders four columns wide.
        let source = "a\tb **c** \td"
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let strong = try XCTUnwrap(MarkdownTestNodes.first(Strong.self, in: document))
        let range = try XCTUnwrap(strong.range)

        XCTAssertEqual(range.lowerBound.column, 5)
        XCTAssertEqual(range.upperBound.column, 10)

        let mapper = MarkdownSourceRangeMapper(source: source)
        XCTAssertEqual(mapper.nsRange(for: range), NSRange(location: 4, length: 5))
    }

    // MARK: - Line endings

    func testCRLFSourcesMapToTheSameSpansAsLFSources() throws {
        let lfSource = "# Title\n\nBody with **bold** text.\n"
        let crlfSource = "# Title\r\n\r\nBody with **bold** text.\r\n"

        let lfStrong = try XCTUnwrap(
            MarkdownTestNodes.first(Strong.self, in: Document(parsing: lfSource, options: [.disableSmartOpts]))
        )
        let crlfStrong = try XCTUnwrap(
            MarkdownTestNodes.first(Strong.self, in: Document(parsing: crlfSource, options: [.disableSmartOpts]))
        )
        let lfRange = try XCTUnwrap(lfStrong.range)
        let crlfRange = try XCTUnwrap(crlfStrong.range)

        XCTAssertEqual(lfRange.lowerBound.line, crlfRange.lowerBound.line)
        XCTAssertEqual(
            lfRange.lowerBound.column,
            crlfRange.lowerBound.column,
            "the carriage return is stripped before columns are measured"
        )

        let crlfMapper = MarkdownSourceRangeMapper(source: crlfSource)
        let mapped = try XCTUnwrap(crlfMapper.nsRange(for: crlfRange))
        XCTAssertEqual((crlfSource as NSString).substring(with: mapped), "**bold**")

        // A line's content range must stop before the carriage return so a
        // whole-line decoration never paints the terminator.
        let headingLine = try XCTUnwrap(crlfMapper.lineContentRange(line: 1))
        XCTAssertEqual((crlfSource as NSString).substring(with: headingLine), "# Title")
    }

    func testBareCarriageReturnStartsANewLineJustAsCMarkTreatsIt() throws {
        let source = "# A\rtext body"
        let mapper = MarkdownSourceRangeMapper(source: source)

        XCTAssertEqual(mapper.lineCount, 2)
        let firstLine = try XCTUnwrap(mapper.lineContentRange(line: 1))
        let secondLine = try XCTUnwrap(mapper.lineContentRange(line: 2))
        XCTAssertEqual((source as NSString).substring(with: firstLine), "# A")
        XCTAssertEqual((source as NSString).substring(with: secondLine), "text body")

        let document = Document(parsing: source, options: [.disableSmartOpts])
        let heading = try XCTUnwrap(MarkdownTestNodes.first(Heading.self, in: document))
        let headingRange = try XCTUnwrap(heading.range)
        XCTAssertEqual(headingRange.lowerBound.line, 1)
        let mapped = try XCTUnwrap(mapper.nsRange(for: headingRange))
        XCTAssertEqual((source as NSString).substring(with: mapped), "# A")
    }

    // MARK: - Boundaries

    func testEmptyDocumentExposesOneEmptyLineAndRejectsEverythingBeyondIt() {
        let mapper = MarkdownSourceRangeMapper(source: "")

        XCTAssertEqual(mapper.utf16Length, 0)
        XCTAssertEqual(mapper.lineCount, 1)
        XCTAssertEqual(mapper.lineContentRange(line: 1), NSRange(location: 0, length: 0))
        XCTAssertEqual(mapper.utf16Offset(line: 1, utf8Column: 1), 0)
        XCTAssertNil(mapper.utf16Offset(line: 1, utf8Column: 2))
        XCTAssertNil(mapper.utf16Offset(line: 2, utf8Column: 1))
        XCTAssertNil(mapper.lineContentRange(line: 2))
    }

    func testFinalLineWithoutATrailingNewlineIsFullyAddressable() throws {
        let withoutNewline = "alpha\nomega"
        let withNewline = "alpha\nomega\n"

        let bare = MarkdownSourceRangeMapper(source: withoutNewline)
        XCTAssertEqual(bare.lineCount, 2)
        let lastLine = try XCTUnwrap(bare.lineContentRange(line: 2))
        XCTAssertEqual((withoutNewline as NSString).substring(with: lastLine), "omega")
        XCTAssertEqual(bare.utf16Offset(line: 2, utf8Column: 6), withoutNewline.utf16.count)
        XCTAssertNil(bare.utf16Offset(line: 2, utf8Column: 7))

        // A trailing terminator adds an addressable empty final line, matching
        // cmark's line numbering.
        let terminated = MarkdownSourceRangeMapper(source: withNewline)
        XCTAssertEqual(terminated.lineCount, 3)
        XCTAssertEqual(terminated.lineContentRange(line: 3), NSRange(location: 12, length: 0))
    }

    func testUnmappablePositionsReturnNilRatherThanAWrongRange() {
        let source = "one\ntwo"
        let mapper = MarkdownSourceRangeMapper(source: source)

        XCTAssertNil(mapper.utf16Offset(line: 0, utf8Column: 1), "lines are 1-based")
        XCTAssertNil(mapper.utf16Offset(line: 1, utf8Column: 0), "columns are 1-based")
        XCTAssertNil(mapper.utf16Offset(line: 3, utf8Column: 1))
        XCTAssertNil(mapper.utf16Offset(line: 1, utf8Column: 5), "column beyond the exclusive line end")

        let inverted = SourceLocation(line: 2, column: 3, source: nil)
            ..< SourceLocation(line: 2, column: 3, source: nil)
        XCTAssertEqual(mapper.nsRange(for: inverted), NSRange(location: 6, length: 0))

        let unmappable = SourceLocation(line: 1, column: 1, source: nil)
            ..< SourceLocation(line: 9, column: 1, source: nil)
        XCTAssertNil(mapper.nsRange(for: unmappable))
    }

    func testMultiLineNodeRangesSpanFromTheirFirstLineToTheirLastLine() throws {
        let source = "intro\n\n> quoted one\n> quoted two\n\nafter"
        let mapper = MarkdownSourceRangeMapper(source: source)
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let quote = try XCTUnwrap(MarkdownTestNodes.first(BlockQuote.self, in: document))
        let quoteRange = try XCTUnwrap(quote.range)
        let mapped = try XCTUnwrap(mapper.nsRange(for: quoteRange))

        XCTAssertEqual(
            (source as NSString).substring(with: mapped),
            "> quoted one\n> quoted two"
        )
    }
}

// MARK: - Shared node lookup helpers

enum MarkdownTestNodes {
    static func first<T: Markup>(_ type: T.Type, in root: Markup) -> T? {
        if let match = root as? T {
            return match
        }
        for child in root.children {
            if let match = first(type, in: child) {
                return match
            }
        }
        return nil
    }

    static func firstInlineWithRange(
        in root: Markup,
        where predicate: (Markup) -> Bool
    ) -> Markup? {
        if predicate(root), root.range != nil {
            return root
        }
        for child in root.children {
            if let match = firstInlineWithRange(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    static func all(in root: Markup) -> [Markup] {
        var result: [Markup] = [root]
        for child in root.children {
            result.append(contentsOf: all(in: child))
        }
        return result
    }
}
