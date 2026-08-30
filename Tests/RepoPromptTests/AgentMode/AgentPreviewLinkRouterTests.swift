import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentPreviewLinkRouterTests: XCTestCase {
    func testTranscriptFileURLRoundTripsReservedPathCharacters() throws {
        let candidates = [
            "docs/report.md",
            "docs/My Report.html",
            "docs/報告.md",
            "docs/100%.md",
            "docs/50%20off.md",
            "docs/report#draft.md",
            "docs/C++.md",
            "../docs/report.md:12"
        ]

        for candidate in candidates {
            let url = try XCTUnwrap(AgentPreviewLinkRouter.transcriptFileURL(for: candidate))
            let queryPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "path" })?
                .value

            XCTAssertEqual(url.host, "transcript-file", candidate)
            XCTAssertEqual(queryPath, candidate, candidate)
            XCTAssertEqual(AgentPreviewLinkRouter.candidateFilePath(from: url), candidate, candidate)
        }
    }

    func testTranscriptFileNamespaceRejectsMalformedReservedURLsAndPreservesLegacyHostPaths() throws {
        let missingQuery = try XCTUnwrap(URL(string: "repoprompt-preview://transcript-file"))
        let emptyPath = try XCTUnwrap(URL(string: "repoprompt-preview://transcript-file?path="))
        let missingPathItem = try XCTUnwrap(
            URL(string: "repoprompt-preview://transcript-file?other=docs/report.md")
        )
        let uppercaseMissingPath = try XCTUnwrap(URL(string: "repoprompt-preview://TRANSCRIPT-FILE"))
        let legacyHostPath = try XCTUnwrap(
            URL(string: "repoprompt-preview://transcript-file/legacy/report.md")
        )

        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: missingQuery))
        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: emptyPath))
        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: missingPathItem))
        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: uppercaseMissingPath))
        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: legacyHostPath),
            "/transcript-file/legacy/report.md"
        )
    }

    func testTranscriptFileTargetStripsLineSuffixWithoutPercentRedecoding() throws {
        let lineURL = try XCTUnwrap(
            AgentPreviewLinkRouter.transcriptFileURL(for: "../docs/report.md:12")
        )
        let percentURL = try XCTUnwrap(
            AgentPreviewLinkRouter.transcriptFileURL(for: "docs/50%20off.md")
        )

        let lineTarget = try XCTUnwrap(AgentPreviewLinkRouter.transcriptFileTarget(from: lineURL))
        let percentTarget = try XCTUnwrap(AgentPreviewLinkRouter.transcriptFileTarget(from: percentURL))

        XCTAssertEqual(lineTarget.normalizedPath, "../docs/report.md")
        XCTAssertEqual(lineTarget.lineNumber, 12)
        XCTAssertEqual(percentTarget.normalizedPath, "docs/50%20off.md")
        XCTAssertNil(percentTarget.lineNumber)
        XCTAssertTrue(lineTarget.isAutoDetected)
        XCTAssertTrue(percentTarget.isAutoDetected)
    }

    func testTripleSlashURLExtractsAbsolutePath() throws {
        let url = try XCTUnwrap(
            URL(string: "repoprompt-preview:///Users/tnguyen/docs/report.html")
        )

        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: url),
            "/Users/tnguyen/docs/report.html"
        )
    }

    func testHostFormRestoresSwallowedFirstPathComponent() throws {
        let url = try XCTUnwrap(
            URL(string: "repoprompt-preview://Users/tnguyen/docs/report.html")
        )

        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: url),
            "/Users/tnguyen/docs/report.html"
        )
    }

    func testPercentEncodedPathIsDecoded() throws {
        let url = try XCTUnwrap(
            URL(string: "repoprompt-preview:///Users/tnguyen/My%20Reports/report%20one.html")
        )

        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: url),
            "/Users/tnguyen/My Reports/report one.html"
        )
    }

    func testCaseInsensitiveSchemeIsAccepted() throws {
        let url = try XCTUnwrap(
            URL(string: "REPOPROMPT-PREVIEW:///Users/tnguyen/docs/report.html")
        )

        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: url),
            "/Users/tnguyen/docs/report.html"
        )
    }

    func testTraversalShapedPathsPassThroughUnchanged() throws {
        let plainURL = try XCTUnwrap(
            URL(string: "repoprompt-preview:///root/../etc/passwd")
        )
        let encodedURL = try XCTUnwrap(
            URL(string: "repoprompt-preview:///root/%2e%2e/etc/passwd")
        )

        // The router only decodes transport syntax; AgentChangesArtifactLinkResolver and
        // logical-root matching enforce workspace containment downstream.
        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: plainURL),
            "/root/../etc/passwd"
        )
        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: encodedURL),
            "/root/../etc/passwd"
        )
    }

    func testQueryAndFragmentAreDropped() throws {
        let url = try XCTUnwrap(
            URL(string: "repoprompt-preview:///Users/tnguyen/docs/report.html?mode=raw#section")
        )

        XCTAssertEqual(
            AgentPreviewLinkRouter.candidateFilePath(from: url),
            "/Users/tnguyen/docs/report.html"
        )
    }

    func testUnsupportedSchemeAndEmptyPathReturnNil() throws {
        let webURL = try XCTUnwrap(URL(string: "https://example.com/report.html"))
        let emptyPreviewURL = try XCTUnwrap(URL(string: "repoprompt-preview:"))

        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: webURL))
        XCTAssertNil(AgentPreviewLinkRouter.candidateFilePath(from: emptyPreviewURL))
    }
}
