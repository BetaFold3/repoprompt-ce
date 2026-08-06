import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentPreviewLinkRouterTests: XCTestCase {
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
