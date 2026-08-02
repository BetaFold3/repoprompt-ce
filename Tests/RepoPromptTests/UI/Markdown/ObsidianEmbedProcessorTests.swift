import Foundation
@testable import RepoPromptApp
import XCTest

final class ObsidianEmbedProcessorTests: XCTestCase {
    func testParserRecognizesAliasesAndSkipsInlineAndFencedCode() throws {
        let source = """
        Before ![[assets/diagram|Architecture]] and `![[inline-code]]`.

        ```md
        ![[fenced-code]]
        ```
        """

        let embeds = ObsidianEmbedParser.embeds(in: source)
        let embed = try XCTUnwrap(embeds.first)
        XCTAssertEqual(embeds.count, 1)
        XCTAssertEqual(embed.reference.target, "assets/diagram")
        XCTAssertEqual(embed.reference.alias, "Architecture")
        XCTAssertEqual((source as NSString).substring(with: embed.sourceRange), "![[assets/diagram|Architecture]]")
    }

    func testRenderedRewriteUsesImageInferenceAndAPathRelativeToTheDocument() {
        let resolver = WikiLinkResolver(rootRelativePaths: [
            "notes/report.md",
            "assets/diagram.png"
        ])

        let output = ObsidianEmbedProcessor.renderedMarkdown(
            from: "Image: ![[assets/diagram|Architecture]]",
            resolver: resolver,
            documentRelativePath: "notes/report.md"
        )

        XCTAssertEqual(output, "Image: ![Architecture](../assets/diagram.png)")
    }

    func testNonImageEmbedBecomesAnExplicitInlineNoteLink() {
        let resolver = WikiLinkResolver(rootRelativePaths: [
            "notes/report.md",
            "notes/Design Notes.md"
        ])

        let output = ObsidianEmbedProcessor.renderedMarkdown(
            from: "See ![[notes/Design Notes#Rollout|the plan]].",
            resolver: resolver,
            documentRelativePath: "notes/report.md"
        )

        XCTAssertEqual(
            output,
            "See [Embedded note: the plan](notes/Design%20Notes.md#Rollout)."
        )
    }

    func testUnsafeEmbedStaysLiteralAndMissingSafeTargetStaysNavigable() {
        let resolver = WikiLinkResolver(rootRelativePaths: [])
        let source = "Unsafe ![[../escape]]; missing ![[Future Note|future]]."

        let output = ObsidianEmbedProcessor.renderedMarkdown(
            from: source,
            resolver: resolver,
            documentRelativePath: "notes/report.md"
        )

        XCTAssertEqual(
            output,
            "Unsafe ![[../escape]]; missing [Embedded note: future](Future%20Note)."
        )
    }
}
