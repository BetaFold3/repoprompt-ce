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

    func testToolResultFoldsIntoPrecedingToolCallAndSettlesCard() throws {
        let items = project(xml: """
        <transcript>
        <tool_call name="read_file">{"path":"README.md"}</tool_call>
        <tool_result name="read_file" status="success"/>
        </transcript>
        """)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.toolName, "read_file")
        XCTAssertNotNil(item.toolResultJSON)
        XCTAssertEqual(item.toolIsError, false)
        XCTAssertNotEqual(ToolCallCardStateResolver.status(for: item), .running)
    }

    func testToolCallWithoutToolResultRemainsRunning() throws {
        let item = try XCTUnwrap(project(xml: #"<tool_call name="read_file"/>"#).first)

        XCTAssertNil(item.toolResultJSON)
        XCTAssertNil(item.toolIsError)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .running)
    }

    func testToolResultDoesNotConsumeSequenceIndex() {
        let withResult = project(xml: """
        <user>Start</user>
        <tool_call name="read_file"/>
        <tool_result status="success" name="read_file" extra="ignored"/>
        <assistant>Done</assistant>
        """)
        let withoutResult = project(xml: """
        <user>Start</user>
        <tool_call name="read_file"/>
        <assistant>Done</assistant>
        """)

        XCTAssertEqual(withResult.map(\.kind), withoutResult.map(\.kind))
        XCTAssertEqual(withResult.map(\.sequenceIndex), withoutResult.map(\.sequenceIndex))
        XCTAssertEqual(withResult.map(\.id), withoutResult.map(\.id))
        XCTAssertNotNil(withResult.first { $0.kind == .toolCall }?.toolResultJSON)
        XCTAssertNil(withoutResult.first { $0.kind == .toolCall }?.toolResultJSON)
    }

    func testUnmatchedToolResultIsIgnored() {
        let items = project(xml: """
        <tool_call name="read_file"/>
        <tool_result name="write_file" status="success"/>
        <assistant>Done</assistant>
        """)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items.first { $0.kind == .toolCall }?.toolResultJSON)
    }

    func testUnknownToolResultJSONFallsBackToRunning() {
        let item = AgentChatItem(
            kind: .toolCall,
            text: "Using tool: read_file",
            toolName: "read_file",
            toolResultJSON: #"{"status":"unknown"}"#,
            toolIsError: nil
        )

        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .running)
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
