import Foundation
@testable import RepoPromptApp
import XCTest

/// Contract for the per-tab artifact index.
///
/// Two things matter here: the order the panel reads artifacts in, and the promise that feeding the
/// index an unchanged transcript costs nothing. Agent sessions publish their item array on every
/// streaming tick, so an index that re-parsed every payload each time would make the panel a tax on
/// the whole transcript.
@MainActor
final class AgentSessionArtifactIndexTests: XCTestCase {
    private typealias Fixtures = AgentEditToolPayloadFixtures

    // MARK: - Ordering

    func testNewestToolResultsComeFirstWhilePayloadOrderSurvivesWithinOne() {
        let index = AgentSessionArtifactIndex()

        index.ingest([
            chatter("Write me two reports and then a summary."),
            patchResult(adding: ["docs/first.md", "docs/second.md"], secondsFromStart: 1),
            patchResult(adding: ["docs/summary.html"], secondsFromStart: 2)
        ])

        XCTAssertEqual(
            index.artifacts.map(\.path),
            ["docs/summary.html", "docs/first.md", "docs/second.md"],
            "newest tool result first, but the files inside one result keep the order the agent wrote them"
        )
    }

    func testATranscriptWithoutWritesHasNoArtifacts() {
        let index = AgentSessionArtifactIndex()

        index.ingest([
            chatter("What does this file do?"),
            Fixtures.readFileResult.item(),
            Fixtures.editModifiedSwiftWithBothDiffs.item()
        ])

        XCTAssertTrue(index.artifacts.isEmpty)
    }

    // MARK: - Incremental behavior

    func testUnchangedTranscriptsAreNotDecodedAgain() {
        let index = AgentSessionArtifactIndex()
        let items = [
            chatter("Go."),
            patchResult(adding: ["docs/first.md"], secondsFromStart: 1),
            Fixtures.editModifiedSwiftWithBothDiffs.item()
        ]

        index.ingest(items)
        let afterFirstPass = index.payloadDecodeCount

        index.ingest(items)
        index.ingest(items)

        XCTAssertEqual(afterFirstPass, 2, "both edit results decode once; the plain message never does")
        XCTAssertEqual(index.payloadDecodeCount, afterFirstPass, "re-ingesting the same items must be free")
        XCTAssertEqual(index.artifacts.map(\.path), ["docs/first.md"])
    }

    func testAppendingOneToolResultOnlyDecodesThatResult() {
        let index = AgentSessionArtifactIndex()
        let existing = [
            patchResult(adding: ["docs/first.md"], secondsFromStart: 1),
            patchResult(adding: ["docs/second.md"], secondsFromStart: 2)
        ]
        index.ingest(existing)
        let afterExisting = index.payloadDecodeCount

        index.ingest(existing + [patchResult(adding: ["docs/third.md"], secondsFromStart: 3)])

        XCTAssertEqual(index.payloadDecodeCount, afterExisting + 1)
        XCTAssertEqual(index.artifacts.map(\.path), ["docs/third.md", "docs/second.md", "docs/first.md"])
    }

    /// A streaming file change is rewritten in place: same item, new payload, new answer.
    func testAToolResultRewrittenInPlaceIsDecodedAgain() {
        let index = AgentSessionArtifactIndex()
        let itemID = UUID()

        index.ingest([patchResult(adding: ["docs/streaming.md"], status: "running", id: itemID)])
        XCTAssertTrue(index.artifacts.isEmpty, "nothing is offered while the write is still in flight")
        let afterStreaming = index.payloadDecodeCount

        index.ingest([patchResult(adding: ["docs/streaming.md"], status: "completed", id: itemID)])

        XCTAssertEqual(index.payloadDecodeCount, afterStreaming + 1)
        XCTAssertEqual(index.artifacts.map(\.path), ["docs/streaming.md"])
    }

    func testArtifactsAreDroppedWhenTheirItemLeavesTheTranscript() {
        let index = AgentSessionArtifactIndex()
        let kept = patchResult(adding: ["docs/kept.md"], secondsFromStart: 1)
        let removed = patchResult(adding: ["docs/removed.md"], secondsFromStart: 2)

        index.ingest([kept, removed])
        XCTAssertEqual(index.artifacts.count, 2)

        index.ingest([kept])

        XCTAssertEqual(index.artifacts.map(\.path), ["docs/kept.md"])
    }

    func testResetClearsEverything() {
        let index = AgentSessionArtifactIndex()
        index.ingest([patchResult(adding: ["docs/first.md"], secondsFromStart: 1)])

        index.reset()

        XCTAssertTrue(index.artifacts.isEmpty)
    }

    // MARK: - Banner selection

    func testTheBannerCandidateIsTheNewestArtifactThatHasNotBeenDismissed() throws {
        let index = AgentSessionArtifactIndex()
        index.ingest([
            patchResult(adding: ["docs/first.md"], secondsFromStart: 1),
            patchResult(adding: ["docs/second.md"], secondsFromStart: 2)
        ])

        let newest = try XCTUnwrap(index.newestArtifact(excludingDismissed: []))
        XCTAssertEqual(newest.path, "docs/second.md")

        let afterDismissingNewest = try XCTUnwrap(index.newestArtifact(excludingDismissed: [newest.id]))
        XCTAssertEqual(afterDismissingNewest.path, "docs/first.md")

        XCTAssertNil(
            index.newestArtifact(excludingDismissed: [newest.id, afterDismissingNewest.id]),
            "with every candidate dismissed the banner stays away"
        )
    }

    /// Dismissal is keyed to the artifact, so a later write of the same document offers itself again.
    func testWritingADismissedDocumentAgainOffersItAgain() throws {
        let index = AgentSessionArtifactIndex()
        let firstWrite = patchResult(adding: ["docs/report.md"], secondsFromStart: 1)
        index.ingest([firstWrite])
        let dismissed = try XCTUnwrap(index.newestArtifact(excludingDismissed: []))

        index.ingest([firstWrite, patchResult(adding: ["docs/report.md"], secondsFromStart: 2)])

        let candidate = try XCTUnwrap(index.newestArtifact(excludingDismissed: [dismissed.id]))
        XCTAssertEqual(candidate.path, "docs/report.md")
        XCTAssertNotEqual(candidate.id, dismissed.id, "a second write of the same document is a new offer")
    }

    // MARK: - Helpers

    private let sessionStart = Date(timeIntervalSince1970: 1_754_000_000)

    private func chatter(_ text: String) -> AgentChatItem {
        AgentChatItem(timestamp: sessionStart, kind: .assistant, text: text)
    }

    private func patchResult(
        adding paths: [String],
        status: String = "completed",
        id: UUID = UUID(),
        secondsFromStart: TimeInterval = 0
    ) -> AgentChatItem {
        let encodedChanges = paths
            .map { #"{"path":"\#($0)","kind":"add","diff":""}"# }
            .joined(separator: ",")
        let resultJSON = #"{"status":"\#(status)","change_count":\#(paths.count),"changes":[\#(encodedChanges)]}"#

        return AgentChatItem(
            id: id,
            timestamp: sessionStart.addingTimeInterval(secondsFromStart),
            kind: .toolResult,
            text: resultJSON,
            toolName: "apply_patch",
            toolResultJSON: resultJSON
        )
    }
}
