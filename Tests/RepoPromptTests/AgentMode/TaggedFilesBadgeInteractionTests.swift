import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class TaggedFilesBadgeInteractionTests: XCTestCase {
    func testSinglePreviewableAttachmentUsesButtonAndOpensRelativePath() async throws {
        let attachment = AgentTaggedFileAttachment(
            relativePath: "docs/canonical#report%20final.md",
            displayName: "presentation-name.pdf"
        )
        let nonPreviewable = AgentTaggedFileAttachment(
            relativePath: "docs/archive.pdf",
            displayName: "Archive"
        )
        let targets = TaggedFilesBadgeInteraction.previewTargets(
            in: [attachment, nonPreviewable]
        )

        XCTAssertEqual(TaggedFilesBadgeInteraction.kind(for: targets), .button)
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(target.displayName, "presentation-name.pdf")
        XCTAssertEqual(target.target.normalizedPath, attachment.relativePath)

        var openedRawDestination: String?
        var openedNormalizedPath: String?
        let opener = MarkdownFileLinkOpener { linkTarget in
            openedRawDestination = linkTarget.rawDestination
            openedNormalizedPath = linkTarget.normalizedPath
            return true
        }

        let didOpen = await TaggedFilesBadgeInteraction.open(target, using: opener)

        XCTAssertTrue(didOpen)
        XCTAssertEqual(openedRawDestination, attachment.relativePath)
        XCTAssertEqual(openedNormalizedPath, attachment.relativePath)
        XCTAssertNotEqual(openedRawDestination, attachment.displayName)
    }

    func testSeveralPreviewableAttachmentsUseMenuAndExcludeNonPreviewableAttachments() {
        let markdown = AgentTaggedFileAttachment(
            relativePath: "docs/guide.md",
            displayName: "Guide"
        )
        let nonPreviewable = AgentTaggedFileAttachment(
            relativePath: "docs/archive.pdf",
            displayName: "Archive"
        )
        let html = AgentTaggedFileAttachment(
            relativePath: "site/index.HTML",
            displayName: "Site"
        )

        let targets = TaggedFilesBadgeInteraction.previewTargets(
            in: [markdown, nonPreviewable, html]
        )

        XCTAssertEqual(TaggedFilesBadgeInteraction.kind(for: targets), .menu)
        XCTAssertEqual(
            targets.map(\.target.rawDestination),
            [markdown.relativePath, html.relativePath]
        )
    }

    func testNonPreviewableAttachmentsRemainInert() {
        let attachments = [
            AgentTaggedFileAttachment(relativePath: "Sources/App.swift", displayName: "App.swift"),
            AgentTaggedFileAttachment(relativePath: "docs/archive.pdf", displayName: "archive.pdf")
        ]

        let targets = TaggedFilesBadgeInteraction.previewTargets(in: attachments)

        XCTAssertEqual(TaggedFilesBadgeInteraction.kind(for: targets), .none)
        XCTAssertTrue(targets.isEmpty)
    }
}
