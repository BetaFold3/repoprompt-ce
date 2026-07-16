import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTranscriptStandaloneToolSpartanExportTests: XCTestCase {
    func testSpartanLogXMLEmitsFailedNonSpawnPreviewForPlainTextErrorWhileHandoffOmitsIt() throws {
        let transcript = try makeStandaloneToolTranscript(
            toolName: "context_builder",
            resultJSON: "Error: MCPToolExecutionCancelledError()",
            toolIsError: true
        )

        let spartanXML = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(spartanXML.contains("<tool_call name=\"context_builder\""))
        XCTAssertTrue(spartanXML.contains("<tool_result name=\"context_builder\" status=\"failed\"/>"))

        let handoffXML = AgentTranscriptIO.buildForkTranscriptXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertFalse(handoffXML.contains("<tool_call name=\"context_builder\""))
        XCTAssertFalse(handoffXML.contains("<tool_result name=\"context_builder\""))
    }

    func testSpartanLogXMLEmitsFailedNonSpawnPreviewForCancelledJSONResult() throws {
        let transcript = try makeStandaloneToolTranscript(
            toolName: "context_builder",
            resultJSON: jsonString(["status": "cancelled"]),
            toolIsError: true
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"context_builder\""))
        XCTAssertTrue(xml.contains("<tool_result name=\"context_builder\" status=\"failed\"/>"))
    }

    func testSpartanLogXMLStillEmitsFailedSpawnFamilyStandalonePreview() throws {
        let transcript = try makeStandaloneToolTranscript(
            toolName: "agent_run",
            resultJSON: jsonString([
                "session_id": "child-failed-standalone-1",
                "status": "failed"
            ]),
            toolIsError: true
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"agent_run\""))
        XCTAssertTrue(xml.contains("<tool_result name=\"agent_run\" status=\"failed\"/>"))
    }

    func testSpartanLogXMLKeepsCompletedNonSpawnPreviewSuccess() throws {
        let transcript = try makeStandaloneToolTranscript(
            toolName: "context_builder",
            resultJSON: jsonString(["status": "completed"]),
            toolIsError: false
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"context_builder\""))
        XCTAssertTrue(xml.contains("<tool_result name=\"context_builder\" status=\"success\"/>"))
    }

    func testSpartanLogXMLInFlightStandaloneToolCallDoesNotEmitToolResult() throws {
        let transcript = try makeInFlightToolCallTranscript(toolName: "context_builder")

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"context_builder\""))
        XCTAssertFalse(xml.contains("<tool_result name=\"context_builder\""))
    }

    #if DEBUG
        func testForkTranscriptToolResultStatusWordContract() {
            XCTAssertNil(AgentTranscriptIO.debugForkTranscriptToolResultStatusWordForTesting(
                from: .pending,
                toolIsError: nil
            ))
            XCTAssertNil(AgentTranscriptIO.debugForkTranscriptToolResultStatusWordForTesting(
                from: .running,
                toolIsError: nil
            ))
            XCTAssertEqual(
                AgentTranscriptIO.debugForkTranscriptToolResultStatusWordForTesting(
                    from: .unknown,
                    toolIsError: nil
                ),
                "success"
            )
            XCTAssertEqual(
                AgentTranscriptIO.debugForkTranscriptToolResultStatusWordForTesting(
                    from: .unknown,
                    toolIsError: true
                ),
                "failed"
            )
        }
    #endif

    func testSpartanLogXMLInfersSuccessForPlainTextStatuslessToolResultWithoutErrorFlag() throws {
        let transcript = try makeStandaloneToolTranscript(
            toolName: "context_builder",
            resultJSON: "plain text completion payload",
            toolIsError: nil
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"context_builder\""))
        XCTAssertTrue(xml.contains("<tool_result name=\"context_builder\" status=\"success\"/>"))
    }

    private func makeStandaloneToolTranscript(
        toolName: String,
        resultJSON: String,
        toolIsError: Bool?
    ) throws -> AgentTranscript {
        let invocationID = UUID()
        let argsJSON = try jsonString(["message": "Inspect context"])
        let items: [AgentChatItem] = [
            .user("Run a standalone tool", sequenceIndex: 0),
            .toolCall(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: 1
            ),
            .toolResult(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: toolIsError,
                sequenceIndex: 2
            ),
            .assistant("Done.", sequenceIndex: 3)
        ]
        return AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: 4,
            compact: false
        )
    }

    private func makeInFlightToolCallTranscript(toolName: String) throws -> AgentTranscript {
        let invocationID = UUID()
        let argsJSON = try jsonString(["message": "Keep running"])
        let items: [AgentChatItem] = [
            .user("Run a standalone tool", sequenceIndex: 0),
            .toolCall(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: 1
            )
        ]
        return AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .running,
            nextSequenceIndex: 2,
            compact: false
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
