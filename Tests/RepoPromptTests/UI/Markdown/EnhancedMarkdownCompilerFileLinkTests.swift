import AppKit
import Markdown
@testable import RepoPromptApp
import XCTest

final class EnhancedMarkdownCompilerFileLinkTests: XCTestCase {
    func testDisabledDetectionIsAttributeIdenticalToHistoricalDefault() throws {
        let document = Document(parsing: "See docs/report.md and \u{60}notes/My Plan.html\u{60}.")

        var historical = EnhancedMarkdownCompiler()
        let expected = historical.attributedString(from: document)

        var disabled = EnhancedMarkdownCompiler()
        disabled.detectsMarkdownFilePaths = false
        let actual = disabled.attributedString(from: document)

        XCTAssertTrue(actual.isEqual(to: expected))
        for path in ["docs/report.md", "notes/My Plan.html"] {
            let offset = try utf16Offset(of: path, in: actual)
            XCTAssertNil(actual.attribute(.link, at: offset, effectiveRange: nil))
            XCTAssertNil(actual.attribute(.markdownRawLink, at: offset, effectiveRange: nil))
            XCTAssertNil(actual.attribute(.markdownDetectedFileLink, at: offset, effectiveRange: nil))
        }
    }

    func testEnabledDetectionDecoratesProseAndWholeInlineCodeWithProvenance() throws {
        let source = "See docs/report.md and \u{60}notes/My Plan.html\u{60}."
        var compiler = EnhancedMarkdownCompiler()
        compiler.detectsMarkdownFilePaths = true
        let output = compiler.attributedString(from: Document(parsing: source))

        for path in ["docs/report.md", "notes/My Plan.html"] {
            let offset = try utf16Offset(of: path, in: output)
            XCTAssertEqual(output.attribute(.markdownRawLink, at: offset, effectiveRange: nil) as? String, path)
            XCTAssertEqual(output.attribute(.link, at: offset, effectiveRange: nil) as? String, path)
            XCTAssertNotNil(output.attribute(.markdownDetectedFileLink, at: offset, effectiveRange: nil))
            XCTAssertEqual(output.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, .linkColor)
            XCTAssertEqual(output.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        }
    }

    func testAuthoredLinkLabelRemainsAuthoredWithoutDetectedMarker() throws {
        var compiler = EnhancedMarkdownCompiler()
        compiler.detectsMarkdownFilePaths = true
        let output = compiler.attributedString(
            from: Document(parsing: "[see docs/report.html](https://example.com)")
        )
        let utf16Offset = try utf16Offset(of: "docs/report.html", in: output)

        XCTAssertNil(output.attribute(.markdownDetectedFileLink, at: utf16Offset, effectiveRange: nil))
        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: utf16Offset, effectiveRange: nil) as? String,
            "https://example.com"
        )
    }

    func testFencedCodeIsNotDetected() throws {
        var compiler = EnhancedMarkdownCompiler()
        compiler.detectsMarkdownFilePaths = true
        let output = compiler.attributedString(from: Document(parsing: "~~~\ndocs/report.md\n~~~"))
        let offset = try utf16Offset(of: "docs/report.md", in: output)

        XCTAssertNil(output.attribute(.link, at: offset, effectiveRange: nil))
        XCTAssertNil(output.attribute(.markdownDetectedFileLink, at: offset, effectiveRange: nil))
    }

    @MainActor
    func testDetectedMarkerSwallowsUnparseableLinkClick() {
        let rawLink = "slack://channel.md:12"
        let attributed = NSMutableAttributedString(string: rawLink)
        attributed.addAttributes([
            .link: rawLink,
            .markdownRawLink: rawLink,
            .markdownDetectedFileLink: true
        ], range: NSRange(location: 0, length: attributed.length))
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)

        let coordinator = MarkdownTextViewCoordinator()
        XCTAssertTrue(coordinator.textView(textView, clickedOnLink: rawLink, at: 0))
    }

    private func utf16Offset(of needle: String, in output: NSAttributedString) throws -> Int {
        let range = try XCTUnwrap(output.string.range(of: needle))
        let index = try XCTUnwrap(range.lowerBound.samePosition(in: output.string.utf16))
        return output.string.utf16.distance(from: output.string.utf16.startIndex, to: index)
    }
}
