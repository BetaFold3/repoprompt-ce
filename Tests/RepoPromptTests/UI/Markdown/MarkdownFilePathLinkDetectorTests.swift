import Foundation
@testable import RepoPromptApp
import XCTest

final class MarkdownFilePathLinkDetectorTests: XCTestCase {
    func testProsePositiveMatrixPreservesExactPathsAndSentencePunctuation() {
        let cases: [(String, String)] = [
            ("See report.md now", "report.md"),
            ("See docs/report.html now", "docs/report.html"),
            ("Open README.markdown", "README.markdown"),
            ("Open ~/notes/plan.md", "~/notes/plan.md"),
            ("Open /tmp/report.htm", "/tmp/report.htm"),
            ("Open ../docs/report.md:12", "../docs/report.md:12"),
            ("Sentence docs/report.md, next.", "docs/report.md"),
            ("Open report.md.", "report.md"),
            ("See report.html:12.", "report.html:12"),
            ("Open DOCS/REPORT.HTML", "DOCS/REPORT.HTML"),
            ("Open tài-liệu/đặc-tả.md", "tài-liệu/đặc-tả.md")
        ]

        for (source, expected) in cases {
            XCTAssertEqual(
                MarkdownFilePathLinkDetector.proseMatches(in: source).map(\.path),
                [expected],
                source
            )
        }
    }

    func testProseRejectsURLsUnsupportedSuffixesAndMidTokenMatches() {
        let rejected = [
            "https://example.com/docs/report.md",
            "//example.com/docs/report.md",
            "docs/issue#12.md",
            "docs/report.mdx",
            "docs/report.md.bak",
            "checksum.md5",
            "docs/report.md/more"
        ]

        for source in rejected {
            XCTAssertTrue(MarkdownFilePathLinkDetector.proseMatches(in: source).isEmpty, source)
        }
    }

    func testInlineCodeRequiresOneTrimmedSingleLinePathAndAllowsInternalSpaces() {
        let padded = MarkdownFilePathLinkDetector.inlineCodeMatch(in: "  docs/My Report.md  ")
        XCTAssertEqual(padded?.path, "docs/My Report.md")
        XCTAssertEqual(padded?.range, NSRange(location: 2, length: "docs/My Report.md".utf16.count))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: "docs/one.md\ndocs/two.md"))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: "https://example.com/report.md"))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: "//example.com/docs/report.md"))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: "slack://channel.md:12"))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: "docs/issue#12.md"))
        XCTAssertNil(MarkdownFilePathLinkDetector.inlineCodeMatch(in: String(repeating: "a", count: 510) + ".md"))
    }

    func testSupportedExtensionsStayInParityWithAgentSessionArtifactKind() {
        let candidates = ["md", "markdown", "html", "htm", "MD", "MARKDOWN", "HTML", "HTM", "mdx", "txt"]
        for candidate in candidates {
            XCTAssertEqual(
                MarkdownFilePathLinkDetector.supportedExtensions.contains(candidate.lowercased()),
                AgentSessionArtifactKind(fileExtension: candidate) != nil,
                candidate
            )
        }

        for fileExtension in MarkdownFilePathLinkDetector.supportedExtensions {
            let path = "report.\(fileExtension)"
            XCTAssertEqual(MarkdownFilePathLinkDetector.proseMatches(in: path).map(\.path), [path])
            let uppercasePath = "report.\(fileExtension.uppercased())"
            XCTAssertEqual(MarkdownFilePathLinkDetector.proseMatches(in: uppercasePath).map(\.path), [uppercasePath])
        }
    }

    func testLargeNoMatchAndManyMatchInputsStayBounded() {
        let noMatch = String(repeating: "ordinary transcript text without file suffixes. ", count: 20000)
        let manyMatch = (0 ..< 5000).map { "docs/report-\($0).md" }.joined(separator: " ")

        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(MarkdownFilePathLinkDetector.proseMatches(in: noMatch).isEmpty)
        XCTAssertEqual(MarkdownFilePathLinkDetector.proseMatches(in: manyMatch).count, 5000)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 2.0)
    }
}
