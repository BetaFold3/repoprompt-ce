@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteTranscriptProjectorTests: XCTestCase {
    func testEmptyTranscriptWrapperProducesNoItems() {
        XCTAssertTrue(project(xml: "<transcript></transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript>\n  </transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript/>").isEmpty)
    }

    func testUnparsedTranscriptWrapperPreservesStrippedContentAsSystemItem() throws {
        let items = project(xml: "<transcript>unparsed text</transcript>")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "unparsed text")
    }

    func testBareGarbagePreservesContentAsSystemItem() throws {
        let items = project(xml: "hello")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "hello")
    }

    func testNormalUserAndAssistantTagsStillParse() {
        let items = project(xml: "<transcript><user>Hello</user><assistant>Hi there</assistant></transcript>")

        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["Hello", "Hi there"])
    }

    func testUpsertingPreservesNewerExistingTimestampForDeterministicID() throws {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-upsert-existing")
        let projected = try XCTUnwrap(projector.projectGetLogResponse(.object([
            "turn_offset": .int(0),
            "returned_turn_count": .int(1),
            "total_turns": .int(1),
            "transcript_xml": .string("<user>Hello remote</user>")
        ])).items.first)
        let existingTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = AgentChatItem(
            id: projected.id,
            timestamp: existingTimestamp,
            kind: .user,
            text: "Optimistic text",
            sequenceIndex: projected.sequenceIndex
        )

        let merged = projector.upserting([projected], into: [existing])
        let item = try XCTUnwrap(merged.first)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(item.id, projected.id)
        XCTAssertEqual(item.timestamp, existingTimestamp)
        XCTAssertEqual(item.text, projected.text)
    }

    func testUpsertingUsesNewerProjectedTimestampForDeterministicID() throws {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-upsert-projected")
        let itemID = UUID()
        let existing = AgentChatItem(
            id: itemID,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .user,
            text: "Old text",
            sequenceIndex: 0
        )
        let projectedTimestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let projected = AgentChatItem(
            id: itemID,
            timestamp: projectedTimestamp,
            kind: .user,
            text: "New wire text",
            sequenceIndex: 0
        )

        let merged = projector.upserting([projected], into: [existing])
        let item = try XCTUnwrap(merged.first)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.timestamp, projectedTimestamp)
        XCTAssertEqual(item.text, projected.text)
    }

    private func project(xml: String) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-test")
            .projectGetLogResponse(.object([
                "turn_offset": .int(0),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ]))
            .items
    }
}
