import AppKit
import Markdown
@testable import RepoPromptApp
import XCTest

final class EnhancedMarkdownCompilerImageTests: XCTestCase {
    func testNilImageHookIsEquivalentToTheHistoricalDefaultOutput() {
        let source = "Before ![Diagram](images/diagram.png) after."
        let document = Document(parsing: source)

        var historical = EnhancedMarkdownCompiler()
        historical.fontSize = 14
        let expected = historical.attributedString(from: document)

        var explicitNil = EnhancedMarkdownCompiler()
        explicitNil.fontSize = 14
        explicitNil.imageProvider = nil
        let actual = explicitNil.attributedString(from: document)

        XCTAssertTrue(actual.isEqual(to: expected))
        XCTAssertEqual(actual.string, "Before Diagram (images/diagram.png) after.")
    }

    func testOptInHookCanReturnAnAttachmentRun() {
        let source = "![Diagram](images/diagram.png)"
        let document = Document(parsing: source)
        var compiler = EnhancedMarkdownCompiler()
        compiler.maximumImageDisplayWidth = 321
        compiler.imageProvider = EnhancedMarkdownImageProvider { request in
            let result = NSMutableAttributedString(attachment: NSTextAttachment())
            result.addAttribute(
                .markdownRawLink,
                value: "\(request.source)|\(request.altText)|\(request.maximumDisplayWidth)|\(request.fontSize)",
                range: NSRange(location: 0, length: result.length)
            )
            return result
        }

        let output = compiler.attributedString(from: document)
        XCTAssertEqual(
            output.attribute(.markdownRawLink, at: 0, effectiveRange: nil) as? String,
            "images/diagram.png|Diagram|321.0|16.0"
        )
        XCTAssertNotNil(output.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testHookPassthroughKeepsHTTPImagesAsLinksWithoutFetching() throws {
        let document = Document(parsing: "![Remote](https://example.com/image.png)")
        var compiler = EnhancedMarkdownCompiler()
        compiler.imageProvider = EnhancedMarkdownImageProvider { _ in nil }

        let output = compiler.attributedString(from: document)
        XCTAssertEqual(output.string, "Remote (example.com)")
        let link = try XCTUnwrap(output.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/image.png")
    }
}
