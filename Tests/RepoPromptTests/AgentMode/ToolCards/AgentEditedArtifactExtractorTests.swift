import Foundation
@testable import RepoPromptApp
import XCTest

/// Contract for turning edit facts into session artifacts.
///
/// The filter is the whole feature: a document the agent *wrote* is worth surfacing, a file it
/// merely edited is not, and a write that never landed is worse than useless because it would send
/// the reader to a document that is not there.
final class AgentEditedArtifactExtractorTests: XCTestCase {
    private typealias Fixtures = AgentEditToolPayloadFixtures

    private let timestamp = Date(timeIntervalSince1970: 1_754_000_000)

    // MARK: - What qualifies

    func testCreatedAndOverwrittenDocumentsQualifyWhileModificationsDoNot() {
        let created = AgentEditedArtifactExtractor.artifacts(for: Fixtures.editCreatedMarkdown.item())
        XCTAssertEqual(created.map(\.path), ["/Users/dev/project/docs/impl-report.md"])
        XCTAssertEqual(created.first?.disposition, .created)
        XCTAssertEqual(created.first?.kind, .markdown)
        XCTAssertEqual(created.first?.toolKind, .applyEdits)

        let overwritten = AgentEditedArtifactExtractor.artifacts(for: Fixtures.editOverwrittenHTMLRelativePath.item())
        XCTAssertEqual(overwritten.map(\.path), ["docs/coverage.html"])
        XCTAssertEqual(overwritten.first?.kind, .html)

        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.editModifiedSwiftWithBothDiffs.item()).isEmpty
        )
    }

    /// A patch that touches many files contributes only the documents it authored.
    func testOnlyAuthoredDocumentsSurviveAMixedPatch() {
        let artifacts = AgentEditedArtifactExtractor.artifacts(for: Fixtures.patchMixedChanges.item())

        XCTAssertEqual(
            artifacts.map(\.path),
            ["docs/plan.md"],
            "an updated markdown file, a deleted one, and a source file are all noise here"
        )
        XCTAssertEqual(artifacts.first?.disposition, .created)
    }

    func testOnlyMarkdownAndHTMLExtensionsQualify() {
        let accepted = [
            "docs/report.md",
            "docs/report.markdown",
            "docs/report.html",
            "docs/report.htm",
            "docs/REPORT.MD"
        ]
        let rejected = [
            "Sources/App/Runner.swift",
            "docs/report.txt",
            "docs/report.json",
            "docs/report.mdx",
            "docs/report",
            "docs/md"
        ]

        let artifacts = AgentEditedArtifactExtractor.artifacts(
            for: patchItem(adding: accepted + rejected)
        )

        XCTAssertEqual(artifacts.map(\.path), accepted)
        XCTAssertEqual(
            artifacts.map(\.kind),
            [.markdown, .markdown, .html, .html, .markdown]
        )
    }

    func testDeletedDocumentsAreNotArtifacts() {
        let artifacts = AgentEditedArtifactExtractor.artifacts(
            for: patchItem(changes: [(path: "docs/gone.md", kind: "delete")])
        )
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testFailedAndStillStreamingWritesProduceNoArtifacts() {
        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.editFailedMarkdown.item()).isEmpty,
            "a failed edit wrote nothing"
        )
        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.patchRunningMarkdown.item()).isEmpty,
            "a streaming patch may not have reached disk yet"
        )
        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.patchDeclinedMarkdown.item()).isEmpty,
            "a declined patch was never applied"
        )
        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.nativeFailed.item()).isEmpty
        )
    }

    /// A compacted transcript keeps the flags even after the diff bodies are dropped, so artifacts
    /// must survive a session that was persisted and reloaded.
    func testCompactedPayloadsStillYieldArtifacts() {
        let fromSummaryOnlyEdit = AgentEditedArtifactExtractor.artifacts(
            for: Fixtures.editSummaryOnlyCreatedMarkdown.item()
        )
        XCTAssertEqual(fromSummaryOnlyEdit.map(\.path), ["docs/design-notes.md"])

        let fromSummaryOnlyPatch = AgentEditedArtifactExtractor.artifacts(
            for: Fixtures.patchSummaryOnlyAliasedToolName.item()
        )
        XCTAssertEqual(fromSummaryOnlyPatch.map(\.path), ["docs/report.html"])
    }

    func testNativeEditCreationsQualifyAndPlainNativeEditsDoNot() {
        XCTAssertEqual(
            AgentEditedArtifactExtractor.artifacts(for: Fixtures.nativeCreatedMarkdown.item()).map(\.path),
            ["docs/cursor-report.md"]
        )
        XCTAssertTrue(
            AgentEditedArtifactExtractor.artifacts(
                for: Fixtures.nativeModifiedWithPersistedTruncatedDiff.item()
            ).isEmpty
        )
    }

    func testNonEditToolResultsProduceNoArtifacts() {
        XCTAssertTrue(AgentEditedArtifactExtractor.artifacts(for: Fixtures.readFileResult.item()).isEmpty)
    }

    // MARK: - Records

    func testArtifactsPreservePayloadOrderAndCarryTheirItemIdentity() {
        let itemID = UUID()
        let item = patchItem(
            adding: ["docs/first.md", "docs/second.html", "docs/third.md"],
            id: itemID
        )

        let artifacts = AgentEditedArtifactExtractor.artifacts(for: item)

        XCTAssertEqual(artifacts.map(\.path), ["docs/first.md", "docs/second.html", "docs/third.md"])
        XCTAssertEqual(artifacts.map(\.fileName), ["first.md", "second.html", "third.md"])
        for artifact in artifacts {
            XCTAssertEqual(artifact.toolItemID, itemID)
            XCTAssertEqual(artifact.createdAt, timestamp)
            XCTAssertEqual(artifact.toolKind, .applyPatch)
        }
    }

    func testArtifactIdentityIsStableAcrossDecodesAndDistinctPerChange() {
        let item = patchItem(adding: ["docs/first.md", "docs/second.md"])

        let first = AgentEditedArtifactExtractor.artifacts(for: item)
        let second = AgentEditedArtifactExtractor.artifacts(for: item)

        XCTAssertEqual(first.map(\.id), second.map(\.id), "a re-decode must not invent new identities")
        XCTAssertEqual(Set(first.map(\.id)).count, 2, "two written documents are two artifacts")
        XCTAssertEqual(first, second)
    }

    /// The same document written twice in one session is two separate offers, newest one wins later.
    func testTheSameDocumentWrittenByTwoToolCallsGetsTwoIdentities() {
        let firstWrite = patchItem(adding: ["docs/report.md"])
        let secondWrite = patchItem(adding: ["docs/report.md"])

        let firstID = AgentEditedArtifactExtractor.artifacts(for: firstWrite).first?.id
        let secondID = AgentEditedArtifactExtractor.artifacts(for: secondWrite).first?.id

        XCTAssertNotNil(firstID)
        XCTAssertNotEqual(firstID, secondID)
    }

    // MARK: - Helpers

    private func patchItem(
        adding paths: [String],
        id: UUID = UUID(),
        timestamp: Date? = nil
    ) -> AgentChatItem {
        patchItem(changes: paths.map { (path: $0, kind: "add") }, id: id, timestamp: timestamp)
    }

    private func patchItem(
        changes: [(path: String, kind: String)],
        id: UUID = UUID(),
        timestamp: Date? = nil
    ) -> AgentChatItem {
        let encodedChanges = changes
            .map { #"{"path":"\#($0.path)","kind":"\#($0.kind)","diff":""}"# }
            .joined(separator: ",")
        let resultJSON = #"{"status":"completed","change_count":\#(changes.count),"changes":[\#(encodedChanges)]}"#

        return AgentChatItem(
            id: id,
            timestamp: timestamp ?? self.timestamp,
            kind: .toolResult,
            text: resultJSON,
            toolName: "apply_patch",
            toolResultJSON: resultJSON
        )
    }
}
