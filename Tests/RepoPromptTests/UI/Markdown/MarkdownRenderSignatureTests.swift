@testable import RepoPromptApp
import SwiftUI
import XCTest

final class MarkdownRenderSignatureTests: XCTestCase {
    func testPolicyDifferenceBreaksSameConfigurationAndAppendOnlyReuse() {
        let previous = signature(text: "Hello", detectsMarkdownFilePaths: false)
        let requested = signature(text: "Hello world", detectsMarkdownFilePaths: true)

        XCTAssertFalse(requested.hasSameRenderingConfiguration(as: previous))
        XCTAssertFalse(requested.isAppendOnlyRelative(to: previous))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: previous, requested: requested))
    }

    func testEqualPolicyPreservesAppendOnlyReuse() {
        let previous = signature(text: "Hello", detectsMarkdownFilePaths: true)
        let requested = signature(text: "Hello world", detectsMarkdownFilePaths: true)

        XCTAssertTrue(requested.hasSameRenderingConfiguration(as: previous))
        XCTAssertTrue(requested.isAppendOnlyRelative(to: previous))
        XCTAssertNotNil(MarkdownStreamingAppendDelta.between(previous: previous, requested: requested))
    }

    @MainActor
    func testMarkdownTextViewEqualityIncludesDetectionPolicy() {
        let disabled = MarkdownTextView(text: "docs/report.md", detectsMarkdownFilePaths: false)
        let enabled = MarkdownTextView(text: "docs/report.md", detectsMarkdownFilePaths: true)
        let same = MarkdownTextView(text: "docs/report.md", detectsMarkdownFilePaths: true)

        XCTAssertNotEqual(disabled, enabled)
        XCTAssertEqual(enabled, same)
    }

    private func signature(text: String, detectsMarkdownFilePaths: Bool) -> MarkdownRenderSignature {
        MarkdownRenderSignature(
            text: text,
            fontSize: 14,
            forceTextColor: nil,
            useMonospaced: false,
            detectsMarkdownFilePaths: detectsMarkdownFilePaths,
            codeFontFaceIdentity: "system"
        )
    }
}
