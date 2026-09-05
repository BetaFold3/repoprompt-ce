import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexTurnCheckpointLedgerTests: XCTestCase {
    func testSameCETurnRecordingReplacesInProgressCandidate() {
        let turnID = UUID()
        let firstDate = Date(timeIntervalSinceReferenceDate: 1)
        let replacementDate = Date(timeIntervalSinceReferenceDate: 2)
        var ledger = CodexTurnCheckpointLedger(threadID: "thread")
        ledger.record(turnID: turnID, codexTurnID: "first", recordedAt: firstDate)
        ledger.record(turnID: turnID, codexTurnID: "replacement", recordedAt: replacementDate)

        XCTAssertEqual(ledger.entries, [
            CodexTurnCheckpoint(
                turnID: turnID,
                codexTurnID: "replacement",
                status: .inProgress,
                sideEffect: nil,
                recordedAt: replacementDate
            )
        ])
    }

    func testThreadBindingInvalidatesMismatchAndPreservesMatch() {
        let checkpoint = makeCheckpoint(turnID: UUID(), codexTurnID: "turn")
        var ledger = CodexTurnCheckpointLedger(threadID: "thread", entries: [checkpoint])

        ledger.bind(to: "thread")
        XCTAssertEqual(ledger.entries, [checkpoint])

        ledger.bind(to: "replacement")
        XCTAssertEqual(ledger.threadID, "replacement")
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertNil(ledger.matching(threadID: "thread"))
    }

    func testPruningRetainsOnlyTranscriptTurnIDs() {
        let retained = UUID()
        var ledger = CodexTurnCheckpointLedger(
            threadID: "thread",
            entries: [
                makeCheckpoint(turnID: retained, codexTurnID: "one"),
                makeCheckpoint(turnID: UUID(), codexTurnID: "two")
            ]
        )

        ledger.prune(retaining: [retained])

        XCTAssertEqual(ledger.entries.map(\.turnID), [retained])
    }

    func testTerminalTransitionRequiresMatchingInProgressCandidate() {
        let turnID = UUID()
        var ledger = CodexTurnCheckpointLedger(
            threadID: "thread",
            entries: [makeCheckpoint(turnID: turnID, codexTurnID: "replacement")]
        )

        XCTAssertFalse(ledger.transition(
            turnID: turnID,
            codexTurnID: "stale",
            to: .completed,
            sideEffect: .readOnly
        ))
        XCTAssertTrue(ledger.transition(
            turnID: turnID,
            codexTurnID: "replacement",
            to: .cancelled,
            sideEffect: .unknown
        ))
        XCTAssertFalse(ledger.transition(
            turnID: turnID,
            codexTurnID: "replacement",
            to: .failed,
            sideEffect: .unknown
        ))
        XCTAssertEqual(ledger.entries.first?.status, .cancelled)
        XCTAssertEqual(ledger.entries.first?.sideEffect, .unknown)
    }

    func testSideEffectClassificationMatrix() {
        let trustedPrefix = "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__"
        let cases: [(String, AgentTranscriptTurn, CodexTurnCheckpoint.SideEffect)] = [
            ("no tools", makeTurn(), .readOnly),
            ("trusted read", makeTurn(executions: [
                makeExecution(name: trustedPrefix + "read_file", result: #"{"status":"success"}"#)
            ]), .readOnly),
            ("plain read lacks trusted identity", makeTurn(executions: [
                makeExecution(name: "read_file", result: #"{"status":"success"}"#)
            ]), .unknown),
            ("failed read", makeTurn(executions: [
                makeExecution(name: trustedPrefix + "file_search", result: #"{"status":"failed"}"#, status: .failed)
            ]), .unknown),
            ("successful status with explicit error flag", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "read_file",
                    result: #"{"status":"completed","isError":true}"#
                )
            ]), .unknown),
            ("mutation has conflicting structured outcome", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "apply_edits",
                    args: #"{"path":"Sources/A.swift"}"#,
                    result: #"{"status":"completed","success":false}"#
                )
            ]), .unknown),
            ("summary-only read", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "get_file_tree",
                    result: #"{"status":"success"}"#,
                    summaryOnly: true
                )
            ]), .unknown),
            ("shell", makeTurn(executions: [
                makeExecution(name: "exec_command", result: #"{"status":"success"}"#)
            ]), .unknown),
            ("mutation without affirmative result", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "apply_edits",
                    args: #"{"path":"Sources/A.swift"}"#,
                    result: #"{"message":"done"}"#
                )
            ]), .unknown),
            ("whitespace-only mutation path stays unknown", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "apply_edits",
                    args: #"{"path":"   "}"#,
                    result: #"{"status":"success"}"#
                )
            ]), .unknown),
            ("dot-only mutation path stays unknown", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "apply_edits",
                    args: #"{"path":"."}"#,
                    result: #"{"status":"success"}"#
                )
            ]), .unknown),
            ("affirmative edits normalize paths", makeTurn(executions: [
                makeExecution(
                    name: trustedPrefix + "apply_edits",
                    args: #"{"path":"./Sources/../Sources/A.swift"}"#,
                    result: #"{"status":"success"}"#
                ),
                makeExecution(
                    name: trustedPrefix + "file_actions",
                    args: #"{"action":"move","path":"Sources/A.swift","new_path":"Sources/B.swift"}"#,
                    result: #"{"isError":false}"#
                )
            ]), .modified(paths: ["Sources/A.swift", "Sources/B.swift"])),
            ("compacted", makeTurn(retentionTier: .summary), .unknown)
        ]

        for (name, turn, expected) in cases {
            XCTAssertEqual(CodexTurnSideEffectClassifier.classify(turn: turn), expected, name)
        }
    }

    func testPersistenceRoundTripAndLegacyDecodeKeepVersionSeven() throws {
        let turnID = UUID()
        let ledger = CodexTurnCheckpointLedger(
            threadID: "thread",
            entries: [makeCheckpoint(turnID: turnID, codexTurnID: "native")]
        )
        let session = AgentSession(codexConversationID: "thread", codexTurnCheckpoints: ledger)

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.codexTurnCheckpoints, ledger)

        let legacy = """
        {
          "id": "00000000-0000-4000-8000-000000000001",
          "serializationVersion": 7,
          "name": "Legacy",
          "savedAt": 0,
          "autoEditEnabled": true
        }
        """
        let legacyDecoded = try JSONDecoder().decode(AgentSession.self, from: Data(legacy.utf8))
        XCTAssertEqual(legacyDecoded.serializationVersion, 7)
        XCTAssertNil(legacyDecoded.codexTurnCheckpoints)
    }

    private func makeCheckpoint(turnID: UUID, codexTurnID: String) -> CodexTurnCheckpoint {
        CodexTurnCheckpoint(
            turnID: turnID,
            codexTurnID: codexTurnID,
            status: .inProgress,
            sideEffect: nil,
            recordedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private func makeExecution(
        name: String,
        args: String? = nil,
        result: String,
        status: AgentTranscriptToolStatus = .success,
        summaryOnly: Bool = false
    ) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: UUID().uuidString,
            toolName: name,
            invocationID: UUID(),
            argsJSON: args,
            resultJSON: result,
            toolIsError: status == .failed,
            status: status,
            summaryOnly: summaryOnly
        )
    }

    private func makeTurn(
        executions: [AgentTranscriptToolExecution] = [],
        retentionTier: AgentTranscriptRetentionTier = .full
    ) -> AgentTranscriptTurn {
        let activities = executions.enumerated().map { index, execution in
            AgentTranscriptActivity(
                id: UUID(),
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                sequenceIndex: index,
                role: .toolExecution,
                itemKind: .toolResult,
                text: "",
                toolExecution: execution
            )
        }
        return AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    completedAt: Date(timeIntervalSinceReferenceDate: 1),
                    activities: activities
                )
            ],
            retentionTier: retentionTier,
            terminalState: .completed,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            completedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }
}
