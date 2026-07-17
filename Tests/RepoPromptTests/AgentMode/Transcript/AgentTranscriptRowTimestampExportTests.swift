import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

/// Wire contract for opt-in per-row `ts` timestamp attributes in the spartan
/// `get_log` transcript XML (remote-client transcript timestamp fidelity).
final class AgentTranscriptRowTimestampExportTests: XCTestCase {
    private static let userDate = Date(timeIntervalSince1970: 1_752_717_279.25)
    private static let toolDate = Date(timeIntervalSince1970: 1_752_717_400.125)
    private static let assistantDate = Date(timeIntervalSince1970: 1_752_717_601.5)

    func testSpartanLogXMLRowTimestampOptInEmissionContract() throws {
        let transcript = try makeTimestampedTranscript()

        let defaultXML = AgentTranscriptIO.buildSpartanLogXML(from: transcript)
        XCTAssertFalse(defaultXML.contains(" ts=\""), "default output must stay byte-identical: \(defaultXML)")

        let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript, includeRowTimestamps: true)
        // Epoch-second attributes with POSIX dot decimal separator, millisecond precision.
        XCTAssertTrue(xml.contains("<user ts=\"1752717279.250\">Prompt</user>"), xml)
        XCTAssertTrue(xml.contains("<tool_call name=\"context_builder\" ts=\"1752717400.125\">"), xml)
        XCTAssertTrue(xml.contains("<assistant ts=\"1752717601.500\">Done.</assistant>"), xml)
        // The folded tool_result carries no ts; the client folds it into the call row.
        XCTAssertTrue(xml.contains("<tool_result name=\"context_builder\" status=\"success\"/>"), xml)
    }

    func testMergedConsecutiveSystemRowsKeepFirstRowTimestamp() {
        let firstSystemDate = Date(timeIntervalSince1970: 1_752_717_300.125)
        let secondSystemDate = Date(timeIntervalSince1970: 1_752_717_301.5)
        let items: [AgentChatItem] = [
            AgentChatItem(timestamp: Self.userDate, kind: .user, text: "Prompt", sequenceIndex: 0),
            AgentChatItem(timestamp: firstSystemDate, kind: .system, text: "first note", sequenceIndex: 1),
            AgentChatItem(timestamp: secondSystemDate, kind: .system, text: "second note", sequenceIndex: 2),
            AgentChatItem(timestamp: Self.assistantDate, kind: .assistant, text: "Done.", sequenceIndex: 3)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: 4,
            compact: false
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript, includeRowTimestamps: true)

        // Consecutive system rows merge into one tag that keeps the FIRST row's ts.
        XCTAssertTrue(xml.contains("<system ts=\"1752717300.125\">first note\nsecond note</system>"), xml)
        XCTAssertFalse(xml.contains("1752717301.500"), xml)
    }

    func testRowTimestampsRoundTripFromHostTranscriptToProjectedItems() throws {
        let transcript = try makeTimestampedTranscript()
        let timestampedXML = AgentTranscriptIO.buildSpartanLogXML(from: transcript, includeRowTimestamps: true)
        let legacyXML = AgentTranscriptIO.buildSpartanLogXML(from: transcript)

        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-roundtrip")
        let timestamped = projector.projectGetLogResponse(logPayload(xml: timestampedXML)).items
        let legacy = projector.projectGetLogResponse(logPayload(xml: legacyXML)).items

        XCTAssertEqual(timestamped.map(\.kind), [.user, .toolCall, .assistant])
        XCTAssertEqual(timestamped.map(\.timestamp), [Self.userDate, Self.toolDate, Self.assistantDate])
        // Identity is unchanged by the ts upgrade so mixed-version pages merge, not duplicate.
        XCTAssertEqual(timestamped.map(\.id), legacy.map(\.id))
    }

    private func makeTimestampedTranscript() throws -> AgentTranscript {
        let invocationID = UUID()
        let argsJSON = try jsonString(["message": "Inspect context"])
        let items: [AgentChatItem] = [
            AgentChatItem(timestamp: Self.userDate, kind: .user, text: "Prompt", sequenceIndex: 0),
            AgentChatItem(
                timestamp: Self.toolDate,
                kind: .toolCall,
                text: "Using tool: context_builder",
                toolName: "context_builder",
                toolInvocationID: invocationID,
                toolArgsJSON: argsJSON,
                sequenceIndex: 1
            ),
            AgentChatItem(
                timestamp: Self.toolDate,
                kind: .toolResult,
                text: "{\"status\":\"completed\"}",
                toolName: "context_builder",
                toolInvocationID: invocationID,
                toolArgsJSON: argsJSON,
                toolResultJSON: "{\"status\":\"completed\"}",
                toolIsError: false,
                sequenceIndex: 2
            ),
            AgentChatItem(timestamp: Self.assistantDate, kind: .assistant, text: "Done.", sequenceIndex: 3)
        ]
        return AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: 4,
            compact: false
        )
    }

    private func logPayload(xml: String) -> JSONValue {
        .object([
            "turn_offset": .int(0),
            "turn_limit": .int(20),
            "returned_turn_count": .int(1),
            "total_turns": .int(1),
            "transcript_xml": .string(xml)
        ])
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
