import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentPreviewMarkdownImageProviderTests: XCTestCase {
    func testResolvesDocumentRelativeImagesInsideTheCheckoutAndRejectsLexicalEscape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let imageURL = fixture.rootURL.appendingPathComponent("assets/image.png")
        try Data([0, 1, 2]).write(to: imageURL)
        let provider = AgentPreviewMarkdownImageProvider(document: fixture.document)

        XCTAssertEqual(
            provider.resolve(source: "../assets/image.png"),
            .local(imageURL.resolvingSymlinksInPath().standardizedFileURL)
        )
        XCTAssertEqual(provider.resolve(source: "../../outside.png"), .rejected(.outsideScope))
        XCTAssertEqual(provider.resolve(source: "/etc/passwd"), .rejected(.absolutePath))
    }

    func testSymlinkEscapingCheckoutIsRejectedButInRootSymlinkIsAllowed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let manager = FileManager.default

        let insideImage = fixture.rootURL.appendingPathComponent("assets/inside.png")
        try Data([1]).write(to: insideImage)
        let insideLink = fixture.rootURL.appendingPathComponent("inside-link")
        try manager.createSymbolicLink(
            at: insideLink,
            withDestinationURL: fixture.rootURL.appendingPathComponent("assets")
        )

        let outsideDirectory = fixture.containerURL.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data([2]).write(to: outsideDirectory.appendingPathComponent("secret.png"))
        let escapeLink = fixture.rootURL.appendingPathComponent("escape-link")
        try manager.createSymbolicLink(at: escapeLink, withDestinationURL: outsideDirectory)

        let provider = AgentPreviewMarkdownImageProvider(document: fixture.document)
        XCTAssertEqual(
            provider.resolve(source: "../inside-link/inside.png"),
            .local(insideImage.resolvingSymlinksInPath().standardizedFileURL)
        )
        XCTAssertEqual(
            provider.resolve(source: "../escape-link/secret.png"),
            .rejected(.outsideScope)
        )
    }

    func testByteCapIsCheckedBeforeImageDecode() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let imageURL = fixture.rootURL.appendingPathComponent("assets/large.png")
        try Data(repeating: 7, count: 5).write(to: imageURL)
        let exactURL = fixture.rootURL.appendingPathComponent("assets/exact.png")
        let exactData = Data(repeating: 3, count: 4)
        try exactData.write(to: exactURL)
        let provider = AgentPreviewMarkdownImageProvider(
            document: fixture.document,
            maximumBytes: 4
        )

        XCTAssertEqual(
            provider.loadData(source: "../assets/exact.png"),
            .loaded(exactData, exactURL.standardizedFileURL)
        )
        XCTAssertEqual(
            provider.loadData(source: "../assets/large.png"),
            .tooLarge(byteCount: 5)
        )
    }

    func testHTTPSourceIsPassthroughAndNeverReadAsLocalData() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let provider = AgentPreviewMarkdownImageProvider(document: fixture.document)
        let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))

        XCTAssertEqual(provider.resolve(source: url.absoluteString), .external(url))
        XCTAssertEqual(provider.loadData(source: url.absoluteString), .external(url))
        XCTAssertNil(provider.enhancedProvider().attributedImage(EnhancedMarkdownImageRequest(
            source: url.absoluteString,
            altText: "Remote",
            maximumDisplayWidth: 300,
            fontSize: 14
        )))
    }

    private func makeFixture() throws -> Fixture {
        let manager = FileManager.default
        let containerURL = manager.temporaryDirectory
            .appendingPathComponent("AgentPreviewMarkdownImageProviderTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = containerURL.appendingPathComponent("checkout", isDirectory: true)
        try manager.createDirectory(
            at: rootURL.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: rootURL.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        let documentURL = rootURL.appendingPathComponent("notes/report.md")
        try Data("# Report".utf8).write(to: documentURL)
        let reference = PreviewDocumentReference(
            rootID: UUID(),
            relativePath: "notes/report.md"
        )
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let document = AgentPreviewResolvedDocument(
            reference: reference,
            rootName: "checkout",
            checkoutRootURL: resolvedRoot,
            fileURL: documentURL.resolvingSymlinksInPath().standardizedFileURL,
            kind: .markdown
        )
        return Fixture(containerURL: containerURL, rootURL: resolvedRoot, document: document)
    }

    private struct Fixture {
        let containerURL: URL
        let rootURL: URL
        let document: AgentPreviewResolvedDocument
    }
}
