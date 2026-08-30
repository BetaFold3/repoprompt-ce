import AppKit
import Foundation
@testable import RepoPromptApp
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
