@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemoteTranscriptProjectionTests: XCTestCase {
    func testActualGetLogTranscriptXMLShapeProjectsDeterministicallyAndUpsertsIdempotently() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-1")
        let payload: JSONValue = .object([
            "session_id": .string("remote-session-1"),
            "turn_offset": .int(7),
            "turn_limit": .int(20),
            "returned_turn_count": .int(2),
            "total_turns": .int(9),
            "transcript_xml": .string("""
            <user>Build the thing</user>
            <assistant>I'll inspect the workspace.</assistant>
            <tool_call name="read_file">{"path":"Package.swift"}</tool_call>
            <system>Detached run started.</system>
            <error>Transient warning</error>
            """)
        ])

        let first = projector.projectGetLogResponse(payload)
        let second = projector.projectGetLogResponse(payload)

        XCTAssertEqual(first.sessionID, "remote-session-1")
        XCTAssertEqual(first.turnOffset, 7)
        XCTAssertEqual(first.turnLimit, 20)
        XCTAssertEqual(first.returnedTurnCount, 2)
        XCTAssertEqual(first.totalTurns, 9)
        XCTAssertEqual(first.nextLogOffset, 9)
        XCTAssertEqual(first.items.map(\.kind), [.user, .assistant, .toolCall, .system, .error])
        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id), "Projection IDs must be restart-safe")
        XCTAssertEqual(first.items[2].toolName, "read_file")
        XCTAssertEqual(first.items[2].toolArgsJSON, "{\"path\":\"Package.swift\"}")

        let upsertedOnce = projector.upserting(first.items, into: [])
        let upsertedTwice = projector.upserting(second.items, into: upsertedOnce)
        XCTAssertEqual(upsertedTwice.count, first.items.count)
        XCTAssertEqual(upsertedTwice.map(\.id), first.items.map(\.id))
    }

    func testGetLogTranscriptXMLDecodesEntities() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-entities")
        let page = projector.projectGetLogResponse(.object([
            "session_id": .string("remote-session-entities"),
            "turn_offset": .int(1),
            "turn_limit": .int(20),
            "returned_turn_count": .int(1),
            "total_turns": .int(1),
            "transcript_xml": .string("""
            <user>Use &lt;tag&gt; &amp; keep &quot;quotes&quot;</user>
            <tool_call name="shell&amp;exec">{&quot;arg&quot;:&quot;&lt;value&gt;&quot;}</tool_call>
            """)
        ]))

        XCTAssertEqual(page.items[0].text, "Use <tag> & keep \"quotes\"")
        XCTAssertEqual(page.items[1].toolName, "shell&exec")
        XCTAssertEqual(page.items[1].toolArgsJSON, "{\"arg\":\"<value>\"}")
    }

    func testSnapshotProjectionMapsActualInteractionSchemaToPendingSurfaces() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-2")

        let approval = projector.projectSnapshot(.object([
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string("wire-approval-1"),
                "kind": .string("approval"),
                "response_type": .string("decision"),
                "title": .string("Approve command"),
                "prompt": .string("Run ls?"),
                "details": .array([
                    .object(["label": .string("Command"), "value": .string("ls"), "is_code": .bool(true)])
                ])
            ])
        ]))
        XCTAssertEqual(approval.runState, .waitingForApproval)
        guard case let .approval(approvalInteractionID, approvalRequest)? = approval.pendingInteraction else {
            return XCTFail("Expected approval interaction")
        }
        XCTAssertEqual(approvalInteractionID, "wire-approval-1")
        XCTAssertEqual(approvalRequest.requestID.displayValue, "remote:wire-approval-1")
        XCTAssertEqual(approvalRequest.command, "ls")

        let question = projector.projectSnapshot(.object([
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string("wire-question-1"),
                "kind": .string("question"),
                "response_type": .string("choice"),
                "title": .string("Pick one"),
                "prompt": .string("Which option?"),
                "options": .array([
                    .object(["label": .string("A"), "description": .string("Alpha")]),
                    .object(["label": .string("B")])
                ])
            ])
        ]))
        XCTAssertEqual(question.runState, .waitingForQuestion)
        guard case let .question(questionInteractionID, pendingQuestion)? = question.pendingInteraction else {
            return XCTFail("Expected question interaction")
        }
        XCTAssertEqual(questionInteractionID, "wire-question-1")
        XCTAssertEqual(pendingQuestion.interaction.remoteInteractionID, "wire-question-1")
        XCTAssertEqual(pendingQuestion.interaction.questions.first?.optionLabels, ["A", "B"])
        XCTAssertFalse(pendingQuestion.interaction.questions.first?.allowsCustom ?? true)

        let userInput = projector.projectSnapshot(.object([
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string("wire-input-1"),
                "kind": .string("user_input"),
                "response_type": .string("structured"),
                "fields": .array([
                    .object([
                        "id": .string("path"),
                        "header": .string("Path"),
                        "prompt": .string("Enter a path"),
                        "options": .array([.object(["label": .string("/tmp")])])
                    ])
                ])
            ])
        ]))
        guard case let .userInput(userInputInteractionID, userInputRequest)? = userInput.pendingInteraction else {
            return XCTFail("Expected user_input interaction")
        }
        XCTAssertEqual(userInputInteractionID, "wire-input-1")
        XCTAssertEqual(userInputRequest.remoteInteractionID, "wire-input-1")
        XCTAssertEqual(userInputRequest.requestID.displayValue, "remote:wire-input-1")
        XCTAssertEqual(userInputRequest.questions.first?.id, "path")

        let elicitation = projector.projectSnapshot(.object([
            "status": .string("waiting_for_input"),
            "interaction": .object([
                "id": .string("wire-elicitation-1"),
                "kind": .string("mcp_elicitation"),
                "response_type": .string("elicitation"),
                "title": .string("MCP Elicitation"),
                "prompt": .string("Provide value")
            ])
        ]))
        guard case let .mcpElicitation(elicitationInteractionID, elicitationRequest)? = elicitation.pendingInteraction else {
            return XCTFail("Expected MCP elicitation interaction")
        }
        XCTAssertEqual(elicitationInteractionID, "wire-elicitation-1")
        XCTAssertEqual(elicitationRequest.remoteInteractionID, "wire-elicitation-1")
        XCTAssertEqual(elicitationRequest.requestID.displayValue, "remote:wire-elicitation-1")
    }

    func testSnapshotProjectionTreatsSessionExpiredAsAuthoritativeTerminalOnlyFromHostSignals() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-3")

        let running = projector.projectSnapshot(.object(["status": .string("running")]))
        XCTAssertFalse(running.isExpired)
        XCTAssertNil(running.terminalStatus)
        XCTAssertEqual(running.runState, .running)

        let expiredStatus = projector.projectSnapshot(.object(["status": .string("expired")]))
        XCTAssertTrue(expiredStatus.isExpired)
        XCTAssertEqual(expiredStatus.terminalStatus, "expired")
        XCTAssertEqual(expiredStatus.runState, .failed)

        let expiredFrame = projector.projectSnapshot(.object(["status": .string("running")]), frameType: "session_expired")
        XCTAssertTrue(expiredFrame.isExpired)
        XCTAssertEqual(expiredFrame.terminalStatus, "expired")
    }

    func testRemoteInteractionResponsePayloadUsesWireInteractionID() throws {
        let response = AgentAskUserResponse(
            answersByQuestionID: [
                "choice": AgentAskUserAnswer(
                    answers: ["A"],
                    selectedOptions: ["A"],
                    customResponse: nil,
                    skipped: false
                )
            ],
            timedOut: false,
            skipped: false,
            elapsedSeconds: 3
        )

        let wire = RemoteInteractionResponsePayload
            .askUser(response)
            .wirePayload(interactionID: "wire-question-1")
        let object = try XCTUnwrap(wire.objectValue)
        XCTAssertEqual(object["interaction_id"]?.stringValue, "wire-question-1")
        let answers = try XCTUnwrap(object["answers"]?.objectValue)
        XCTAssertNotNil(answers["choice"]?.objectValue)
    }
}
