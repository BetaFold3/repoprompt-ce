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

    func testRowTimestampAttributesParseAcrossRowKindsWithSyntheticFallback() {
        let items = project(xml: """
        <transcript>
        <user ts="1752717279.250">Hello</user>
        <assistant ts="1752717601.500">Hi there</assistant>
        <system ts="1752717602.750">note</system>
        <error ts="1752717603.125">boom</error>
        <tool_call name="read_file" ts="1752717604.250"/>
        <tool_call name="apply_edits" ts="1752717605.500">{"path":"a.swift"}</tool_call>
        <assistant>legacy row without ts</assistant>
        <assistant ts="nan">non-finite ts row</assistant>
        <assistant ts="inf">infinite ts row</assistant>
        </transcript>
        """)

        XCTAssertEqual(
            items.map(\.kind),
            [.user, .assistant, .system, .error, .toolCall, .toolCall, .assistant, .assistant, .assistant]
        )
        XCTAssertEqual(items[0].timestamp, Date(timeIntervalSince1970: 1_752_717_279.25))
        XCTAssertEqual(items[1].timestamp, Date(timeIntervalSince1970: 1_752_717_601.5))
        XCTAssertEqual(items[2].timestamp, Date(timeIntervalSince1970: 1_752_717_602.75))
        XCTAssertEqual(items[3].timestamp, Date(timeIntervalSince1970: 1_752_717_603.125))
        XCTAssertEqual(items[4].timestamp, Date(timeIntervalSince1970: 1_752_717_604.25))
        XCTAssertEqual(items[4].toolName, "read_file")
        XCTAssertEqual(items[5].timestamp, Date(timeIntervalSince1970: 1_752_717_605.5))
        XCTAssertEqual(items[5].toolArgsJSON, #"{"path":"a.swift"}"#)
        // Rows without a wire ts keep the legacy synthetic sequence-index date.
        XCTAssertEqual(items[6].timestamp, Date(timeIntervalSince1970: TimeInterval(items[6].sequenceIndex)))
        // Non-finite ts values ("nan"/"inf" parse as valid TimeIntervals) must not poison
        // max-merge or persistence; they fall back to the synthetic date.
        XCTAssertEqual(items[7].timestamp, Date(timeIntervalSince1970: TimeInterval(items[7].sequenceIndex)))
        XCTAssertEqual(items[8].timestamp, Date(timeIntervalSince1970: TimeInterval(items[8].sequenceIndex)))
    }

    func testWireTimestampedRowsKeepLegacyDeterministicIDsAndUpsertHealsSyntheticDates() {
        let legacy = project(xml: "<user>Hello</user>\n<assistant>Hi</assistant>")
        let timestamped = project(
            xml: "<user ts=\"1752717279.250\">Hello</user>\n<assistant ts=\"1752717601.500\">Hi</assistant>"
        )

        // The wire ts must not participate in row identity, so legacy and upgraded
        // projections of the same row merge instead of duplicating.
        XCTAssertEqual(legacy.map(\.id), timestamped.map(\.id))

        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-test")
        let healed = projector.upserting(timestamped, into: legacy)

        XCTAssertEqual(healed.map(\.id), legacy.map(\.id))
        XCTAssertEqual(healed.map(\.timestamp), [
            Date(timeIntervalSince1970: 1_752_717_279.25),
            Date(timeIntervalSince1970: 1_752_717_601.5)
        ])
    }

    func testHostRowIDAttributesMapToClientItemsWithoutChangingLegacyProjection() {
        let userHostRowID = UUID()
        let toolHostRowID = UUID()
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-host-row-ids")
        let legacyXML = """
        <user>Hello</user>
        <tool_call name="read_file"/>
        <assistant>Done</assistant>
        <error>Failed</error>
        """
        let upgradedXML = """
        <user id="\(userHostRowID.uuidString)">Hello</user>
        <tool_call name="read_file" id="\(toolHostRowID.uuidString)"/>
        <assistant>Done</assistant>
        <error id="not-a-uuid">Failed</error>
        """
        func payload(xml: String) -> JSONValue {
            .object([
                "turn_offset": .int(0),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ])
        }

        let legacy = projector.projectGetLogResponse(payload(xml: legacyXML))
        let upgraded = projector.projectGetLogResponse(payload(xml: upgradedXML))

        XCTAssertEqual(upgraded.items, legacy.items)
        XCTAssertTrue(legacy.hostRowIDByClientItemID.isEmpty)
        XCTAssertEqual(upgraded.hostRowIDByClientItemID, [
            upgraded.items[0].id: userHostRowID,
            upgraded.items[1].id: toolHostRowID
        ])
        XCTAssertNil(upgraded.hostRowIDByClientItemID[upgraded.items[2].id])
        XCTAssertNil(upgraded.hostRowIDByClientItemID[upgraded.items[3].id])
    }

    func testProjectSnapshotParsesAgentReasoningEffort() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-effort")

        XCTAssertEqual(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini"),
                "reasoning_effort": .string("  high  ")
            ])
        ])).agentReasoningEffortRaw, "high")
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini")
            ])
        ])).agentReasoningEffortRaw)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini"),
                "reasoning_effort": .string("  \n\t ")
            ])
        ])).agentReasoningEffortRaw)
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
