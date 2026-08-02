import Foundation
import Markdown
@testable import RepoPromptApp
import XCTest

final class MarkdownOutlineExtractorTests: XCTestCase {
    func testExtractsOnlyH1ThroughH4WithHierarchyTitlesAndSourceOffsets() {
        let source = """
        # One

        ## Two

        ### *Styled* three

        #### Four

        ##### Hidden
        """

        let headings = MarkdownOutlineExtractor.headings(in: source)
        XCTAssertEqual(headings.map(\.level), [1, 2, 3, 4])
        XCTAssertEqual(headings.map(\.title), ["One", "Two", "Styled three", "Four"])
        XCTAssertEqual(
            headings.map(\.sourceOffset),
            ["# One", "## Two", "### *Styled* three", "#### Four"].map {
                (source as NSString).range(of: $0).location
            }
        )
    }

    func testDuplicateHeadingsKeepDistinctStableSourceOrderIDsAcrossCRLF() {
        let source = "# Top\r\n\r\n## Repeat\r\n\r\n## Repeat\r\n"
        let headings = MarkdownOutlineExtractor.headings(in: source)

        XCTAssertEqual(headings.map(\.id), [0, 1, 2])
        XCTAssertEqual(headings.map(\.title), ["Top", "Repeat", "Repeat"])
        let firstRepeat = (source as NSString).range(of: "## Repeat")
        let secondSearch = NSRange(
            location: NSMaxRange(firstRepeat),
            length: (source as NSString).length - NSMaxRange(firstRepeat)
        )
        let secondRepeat = (source as NSString).range(of: "## Repeat", options: [], range: secondSearch)
        XCTAssertEqual(headings.map(\.sourceOffset), [0, firstRepeat.location, secondRepeat.location])
    }

    func testRenderedAnchorMappingUsesCompilerMetadataThroughDuplicateAndEarlierBodyText() throws {
        let source = "Repeat appears in the intro.\n\n# Top\n\n## Repeat\n\nbody\n\n## Repeat"
        var defaultCompiler = EnhancedMarkdownCompiler()
        let defaultRendered = defaultCompiler.attributedString(from: Document(parsing: source))
        XCTAssertNil(defaultRendered.attribute(
            .markdownHeadingAnchor,
            at: (defaultRendered.string as NSString).range(of: "Top").location,
            effectiveRange: nil
        ))

        var compiler = EnhancedMarkdownCompiler()
        compiler.indexesHeadingsForNavigation = true
        let rendered = compiler.attributedString(from: Document(parsing: source))

        let offsets = RenderedMarkdownHeadingAnchorMapper.offsets(in: rendered)
        let topOffset = try XCTUnwrap(offsets[0])
        let firstRepeatOffset = try XCTUnwrap(offsets[1])
        let secondRepeatOffset = try XCTUnwrap(offsets[2])

        XCTAssertEqual((rendered.string as NSString).substring(from: topOffset).prefix(3), "Top")
        XCTAssertEqual(
            (rendered.string as NSString).substring(from: firstRepeatOffset).prefix(6),
            "Repeat"
        )
        XCTAssertEqual(
            (rendered.string as NSString).substring(from: secondRepeatOffset).prefix(6),
            "Repeat"
        )
        XCTAssertGreaterThan(firstRepeatOffset, (rendered.string as NSString).range(of: "Repeat").location)
        XCTAssertGreaterThan(secondRepeatOffset, firstRepeatOffset)
    }
}
