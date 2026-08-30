import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

final class ToolResultMarkdownLinkifierTests: XCTestCase {
    func testCanonicalToolBodyDetectsBareAndInlineCodePaths() {
        let source = """
        read_file: `docs/Guide.md`
        file_search: Sources/Feature/Page.html:42
        """

        let matches = ToolResultMarkdownLinkifier.matches(in: source)

        XCTAssertEqual(matches.map(\.path), [
            "docs/Guide.md",
            "Sources/Feature/Page.html:42"
        ])
        for match in matches {
            XCTAssertEqual((source as NSString).substring(with: match.range), match.path)
        }
    }

    func testAuthoredLinkDescendantsRemainSuppressed() {
        let source = "[docs/ignored.md](https://example.com) and docs/visible.md"

        XCTAssertEqual(
            ToolResultMarkdownLinkifier.matches(in: source).map(\.path),
            ["docs/visible.md"]
        )
    }

    func testUnicodePrefixKeepsExactVerbatimSourceRanges() {
        let source = "😀 前置 `docs/規格.md` and 資料/報告.html"
        let matches = ToolResultMarkdownLinkifier.matches(in: source)

        XCTAssertEqual(matches.map(\.path), ["docs/規格.md", "資料/報告.html"])
        for match in matches {
            XCTAssertEqual((source as NSString).substring(with: match.range), match.path)
        }
    }

    func testFencedToolContentRemainsUnlinked() {
        let source = """
        Outside docs/visible.md
        ```json
        {"path":"docs/hidden.md"}
        ```
        ~~~diff
        Sources/Hidden/Page.html
        ~~~
            docs/indented.md
        """

        XCTAssertEqual(
            ToolResultMarkdownLinkifier.matches(in: source).map(\.path),
            ["docs/visible.md"]
        )
    }

    func testDefaultOffFlagKeepsOtherPlainTextSurfacesUnchanged() {
        let source = "docs/report.md"

        XCTAssertTrue(
            ToolScrollableMarkdownTextView.detectedFileLinks(
                in: source,
                enabled: false
            ).isEmpty
        )
        XCTAssertEqual(
            ToolScrollableMarkdownTextView.detectedFileLinks(
                in: source,
                enabled: true
            ).map(\.path),
            [source]
        )
        XCTAssertTrue(MarkdownFilePathLinkDetector.containsSupportedExtension(in: "DOCS/REPORT.MD"))
        XCTAssertFalse(MarkdownFilePathLinkDetector.containsSupportedExtension(in: "docs/report.txt"))
        XCTAssertTrue(ToolResultMarkdownLinkifier.matches(in: "plain tool output").isEmpty)

        let toolView = ToolScrollableMarkdownTextView(text: source, maxHeight: 100)
        XCTAssertFalse(toolView.detectsMarkdownFilePaths)
        let textKitView = TextKitView(text: .constant(source))
        XCTAssertTrue(textKitView.detectedMarkdownFileLinks.isEmpty)
        XCTAssertNil(textKitView.markdownFileLinkOpener)
    }

    @MainActor
    func testFirstResponderNonEditableUpdateKeepsVisibleTextAndLinksAligned() throws {
        let oldText = "docs/old.md"
        let newText = "docs/new.html"
        let oldMatches = ToolResultMarkdownLinkifier.matches(in: oldText)
        let newMatches = ToolResultMarkdownLinkifier.matches(in: newText)
        let opener = MarkdownFileLinkOpener { _ in true }
        let initialView = TextKitView(
            text: .constant(oldText),
            isEditable: false,
            detectedMarkdownFileLinks: oldMatches,
            markdownFileLinkOpener: opener
        )
        let coordinator = TextKitView.Coordinator(initialView)
        let scrollView = NSScrollView()
        let textView = ScrollTrackingTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        scrollView.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.string = oldText
        let initialStorage = try XCTUnwrap(textView.textStorage)
        TextKitView.decorateDetectedMarkdownFileLinks(oldMatches, in: initialStorage)
        coordinator.appliedDetectedMarkdownFileLinks = oldMatches

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(textView.window?.firstResponder === textView)

        let updatedView = TextKitView(
            text: .constant(newText),
            isEditable: false,
            detectedMarkdownFileLinks: newMatches,
            markdownFileLinkOpener: opener
        )
        updatedView.updateNSView(scrollView, coordinator: coordinator)

        XCTAssertEqual(textView.string, newText)
        XCTAssertEqual(textView.scrollRangeToVisibleCallCount, 0)
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertEqual(storage.attribute(.markdownRawLink, at: 0, effectiveRange: nil) as? String, newText)
        XCTAssertEqual(
            storage.attribute(.markdownDetectedFileLink, at: 0, effectiveRange: nil) as? Bool,
            true
        )
        XCTAssertEqual(coordinator.appliedDetectedMarkdownFileLinks, newMatches)

        let noOpenerView = TextKitView(
            text: .constant(newText),
            isEditable: false,
            detectedMarkdownFileLinks: newMatches
        )
        noOpenerView.updateNSView(scrollView, coordinator: coordinator)
        XCTAssertNil(storage.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.markdownRawLink, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.markdownDetectedFileLink, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
        XCTAssertTrue(coordinator.appliedDetectedMarkdownFileLinks.isEmpty)
    }

    @MainActor
    func testLinkedPayloadUpdateToPlainTextClearsMetadataAndRestoresPlainStyling() throws {
        let oldText = "docs/old.md"
        let newText = "plain text!"
        XCTAssertEqual(oldText.utf16.count, newText.utf16.count)
        let fixture = try makeLinkedUpdateFixture(text: oldText)
        let updatedView = TextKitView(
            text: .constant(newText),
            isEditable: false,
            detectedMarkdownFileLinks: ToolResultMarkdownLinkifier.matches(in: newText),
            markdownFileLinkOpener: fixture.opener
        )

        updatedView.updateNSView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertEqual(fixture.textView.string, newText)
        let storage = try XCTUnwrap(fixture.textView.textStorage)
        assertNoDetectedLinkMetadata(in: storage)
        for offset in 0 ..< storage.length {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, .textColor)
            XCTAssertEqual(storage.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int, 0)
        }
    }

    @MainActor
    func testLinkedPayloadUpdateToMixedTextAttributesOnlyCurrentExactMatch() throws {
        let oldText = "docs/old-report.md"
        let newText = "x docs/new.md tail"
        XCTAssertEqual(oldText.utf16.count, newText.utf16.count)
        let fixture = try makeLinkedUpdateFixture(text: oldText)
        let newMatches = ToolResultMarkdownLinkifier.matches(in: newText)
        XCTAssertEqual(newMatches.count, 1)
        let currentMatch = try XCTUnwrap(newMatches.first)
        let updatedView = TextKitView(
            text: .constant(newText),
            isEditable: false,
            detectedMarkdownFileLinks: newMatches,
            markdownFileLinkOpener: fixture.opener
        )

        updatedView.updateNSView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertEqual(fixture.textView.string, newText)
        let storage = try XCTUnwrap(fixture.textView.textStorage)
        for offset in 0 ..< storage.length {
            let isCurrentMatch = NSLocationInRange(offset, currentMatch.range)
            XCTAssertEqual(storage.attribute(.link, at: offset, effectiveRange: nil) as? String, isCurrentMatch ? currentMatch.path : nil)
            XCTAssertEqual(storage.attribute(.markdownRawLink, at: offset, effectiveRange: nil) as? String, isCurrentMatch ? currentMatch.path : nil)
            XCTAssertEqual(
                storage.attribute(.markdownDetectedFileLink, at: offset, effectiveRange: nil) as? Bool,
                isCurrentMatch ? Optional(true) : nil
            )
        }
        XCTAssertEqual(fixture.coordinator.appliedDetectedMarkdownFileLinks, newMatches)
    }

    @MainActor
    func testDetectedToolBodyPathRoutesThroughExistingOpenerWithProvenance() async {
        let source = "docs/report.md"
        let matches = ToolResultMarkdownLinkifier.matches(in: source)
        let storage = NSMutableAttributedString(string: source)
        TextKitView.decorateDetectedMarkdownFileLinks(matches, in: storage)

        var openedTarget: MarkdownFileLinkTarget?
        let opened = expectation(description: "Detected path opened")
        let opener = MarkdownFileLinkOpener { target in
            openedTarget = target
            opened.fulfill()
            return true
        }
        let view = TextKitView(
            text: .constant(source),
            isEditable: false,
            detectedMarkdownFileLinks: matches,
            markdownFileLinkOpener: opener
        )
        let coordinator = TextKitView.Coordinator(view)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(storage)

        XCTAssertTrue(
            coordinator.textView(
                textView,
                clickedOnLink: source,
                at: 0
            )
        )
        await fulfillment(of: [opened], timeout: 1)

        XCTAssertEqual(openedTarget?.normalizedPath, source)
        XCTAssertEqual(openedTarget?.isAutoDetected, true)
        XCTAssertEqual(
            storage.attribute(.markdownDetectedFileLink, at: 0, effectiveRange: nil) as? Bool,
            true
        )
    }

    @MainActor
    private final class ScrollTrackingTextView: NSTextView {
        private(set) var scrollRangeToVisibleCallCount = 0

        override func scrollRangeToVisible(_ range: NSRange) {
            scrollRangeToVisibleCallCount += 1
            super.scrollRangeToVisible(range)
        }
    }

    @MainActor
    private func makeLinkedUpdateFixture(text: String) throws -> (
        coordinator: TextKitView.Coordinator,
        scrollView: NSScrollView,
        textView: NSTextView,
        opener: MarkdownFileLinkOpener
    ) {
        let matches = ToolResultMarkdownLinkifier.matches(in: text)
        let opener = MarkdownFileLinkOpener { _ in true }
        let view = TextKitView(
            text: .constant(text),
            isEditable: false,
            detectedMarkdownFileLinks: matches,
            markdownFileLinkOpener: opener
        )
        let coordinator = TextKitView.Coordinator(view)
        let scrollView = NSTextView.scrollableTextView()
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.string = text
        let storage = try XCTUnwrap(textView.textStorage)
        TextKitView.decorateDetectedMarkdownFileLinks(matches, in: storage)
        coordinator.appliedDetectedMarkdownFileLinks = matches
        return (coordinator, scrollView, textView, opener)
    }

    private func assertNoDetectedLinkMetadata(in storage: NSAttributedString) {
        for key in [
            NSAttributedString.Key.link,
            .markdownRawLink,
            .markdownDetectedFileLink
        ] {
            storage.enumerateAttribute(
                key,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                XCTAssertNil(value, "Unexpected attribute: \(key.rawValue)")
            }
        }
    }
}
