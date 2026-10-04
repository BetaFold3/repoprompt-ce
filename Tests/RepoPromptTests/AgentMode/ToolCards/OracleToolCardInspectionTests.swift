@testable import RepoPromptApp
import XCTest

/// Oracle failure inspection plan, Patch B (B4): failed-only Oracle card presentation.
final class OracleToolCardInspectionTests: XCTestCase {
    private let openContext = AgentOracleOpenContext(windowID: 3, workspaceID: UUID(), tabID: UUID())

    func testFailedOracleCardSubtitleIsTheRedactedHeadline() throws {
        let item = AgentChatItem.toolResult(
            name: "ask_oracle",
            resultJSON: "MCP error -32602: Invalid params: Authorization: Bearer abc.def-123\nretry later",
            isError: true
        )
        let presentation = try XCTUnwrap(OracleFailureCardPresentation(item: item))
        XCTAssertFalse(presentation.subtitle.isEmpty)
        XCTAssertEqual(presentation.subtitle, "MCP error -32602: Invalid params: Authorization: <redacted>")
        XCTAssertFalse(presentation.detailsUnavailable)
        XCTAssertEqual(
            presentation.failure.primary?.message,
            "MCP error -32602: Invalid params: Authorization: <redacted>\nretry later"
        )
        XCTAssertFalse(presentation.showsTruncationNote)
        XCTAssertNil(presentation.laneSummary)
        XCTAssertNil(presentation.omittedSummary)
    }

    func testFailedCardDisclosesDetailsWithoutAChatID() throws {
        let raw = jsonString(["is_error": true, "code": "oracle_model_required", "error": "new_chat:true requires model"])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: raw))
        let presentation = try XCTUnwrap(OracleFailureCardPresentation(item: item))
        XCTAssertFalse(presentation.detailsUnavailable, "Disclosure does not depend on a routable chat")
        XCTAssertEqual(presentation.subtitle, "new_chat:true requires model")
        try XCTAssertEqual(
            OracleFailureCardPresentation.diagnosticLabel(XCTUnwrap(presentation.failure.primary)),
            "oracle_model_required"
        )
    }

    func testOpenOracleRoutingIsSeparateFromDiagnosticText() throws {
        let routed = jsonString([
            "ok": false,
            "status": "failed",
            "chat_id": "chat-open",
            "error": ["code": "oracle_stream_failed", "message": "stream failed"]
        ])
        let routedItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: routed, isError: true)
        XCTAssertNotNil(OracleFailureCardPresentation(item: routedItem))
        let userInfo = try XCTUnwrap(AgentOracleToolRouting.operationPopoverUserInfo(
            openContext: openContext,
            chatID: AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: routed)
        ))
        XCTAssertEqual(userInfo["chatID"] as? String, "chat-open")

        // A chat ID mentioned only in diagnostic text never establishes routing identity.
        let unrouted = jsonString(["is_error": true, "error": "chat_id: fake-chat could not be opened"])
        let unroutedItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: unrouted, isError: true)
        let presentation = try XCTUnwrap(OracleFailureCardPresentation(item: unroutedItem))
        XCTAssertNil(presentation.failure.primary?.laneChatID)
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: unrouted))
        XCTAssertNil(AgentOracleToolRouting.operationPopoverUserInfo(
            openContext: openContext,
            chatID: AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: unrouted)
        ))
    }

    func testLaneFailureInsideCompletedWaitEnvelopeShowsAsFailed() throws {
        let raw = jsonString([
            "results": [
                [
                    "index": 0,
                    "status": "completed",
                    "operation_id": "11111111-1111-1111-1111-111111111111",
                    "chat_id": "lane-0",
                    "response": "done"
                ],
                [
                    "index": 1,
                    "ok": false,
                    "status": "failed",
                    "operation_id": "22222222-2222-2222-2222-222222222222",
                    "chat_id": "lane-1",
                    "error": ["code": "oracle_stream_failed", "message": "Lane one stream failed"]
                ]
            ],
            "wait": ["result": "completed_with_errors", "pending_operation_ids": []]
        ])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: false)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: raw))
        XCTAssertEqual(
            OracleToolCardPresentation(dto: dto, resultObject: ToolJSON.structuredResultObject(from: raw)).state,
            .failed
        )
        let presentation = try XCTUnwrap(OracleFailureCardPresentation(item: item))
        XCTAssertEqual(presentation.subtitle, "1 of 2 failed • Lane one stream failed")
        XCTAssertEqual(presentation.laneSummary, "1 of 2 lanes failed")
        XCTAssertEqual(presentation.failure.primary?.laneChatID, "lane-1")
        try XCTAssertEqual(
            OracleFailureCardPresentation.diagnosticLabel(XCTUnwrap(presentation.failure.primary)),
            "Lane 1 • oracle_stream_failed"
        )
        XCTAssertNotNil(AgentOracleToolRouting.operationPopoverUserInfo(
            openContext: openContext,
            chatID: presentation.failure.primary?.laneChatID
        ), "A structured lane chat ID can open that lane's chat")
    }

    /// The card's DTO lane classifier and the shared projection's dictionary classifier encode
    /// the same rules; any drift in one fails here.
    func testLaneClassifiersAgreeAcrossSharedLaneFixtures() throws {
        let fixtures: [(name: String, lane: [String: Any])] = [
            ("completed", ["status": "completed", "response": "done"]),
            ("ready", ["status": "ready"]),
            ("cancelled with echoed error", ["ok": false, "status": "cancelled", "error": ["code": "oracle_cancelled", "message": "cancelled"]]),
            ("failed", ["status": "failed"]),
            ("unknown", ["status": "unknown"]),
            ("delivery failed", ["status": "delivery_failed", "error": "lost"]),
            ("ok false", ["ok": false]),
            ("string error", ["status": "success", "error": "boom"]),
            ("structured error", ["error": ["code": "oracle_provider_error", "message": "boom"]]),
            ("code-only error", ["error": ["code": "oracle_provider_error"]]),
            ("blank error", ["status": "success", "error": "  "]),
            ("success with errors", ["status": "success", "errors": ["boom"]]),
            ("terminal status wins over cancel echo", ["status": "completed", "cancel": "requested"]),
            ("cancel requested", ["status": "running", "cancel": "requested"]),
            ("stream cancelling", ["pending": ["stream_state": "cancelling"]]),
            ("queued", ["status": "pending", "pending": ["stream_state": "queued"]]),
            ("starting stream", ["pending": ["stream_state": "starting"]]),
            ("streaming", ["status": "pending", "pending": ["stream_state": "streaming"]]),
            ("pending", ["status": "pending"]),
            ("running", ["status": "running"]),
            ("starting", ["status": "starting"]),
            ("cancelling", ["status": "cancelling"]),
            ("no status", ["response": "done"])
        ]
        for fixture in fixtures {
            let dto = try XCTUnwrap(
                ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: jsonString(fixture.lane)),
                fixture.name
            )
            let expected: OracleToolResultInspection.LaneState = switch OracleToolCardLanePresentation(dto: dto).state {
            case .completed: .completed
            case .cancelled: .cancelled
            case .failed: .failed
            case .queued, .preparing, .pending, .cancelling: .nonterminal
            }
            XCTAssertEqual(OracleToolResultInspection.laneState(fixture.lane), expected, fixture.name)
        }

        // `is_error` and `failed_count` are dictionary-only failure signals (the DTO has no such
        // fields); the shared projection still renders the failed card for them.
        let flagged = jsonString([
            "results": [["index": 0, "status": "success", "is_error": true, "chat_id": "lane-0"]],
            "wait": ["result": "completed", "pending_operation_ids": []]
        ])
        XCTAssertNotNil(OracleFailureCardPresentation(
            item: AgentChatItem.toolResult(name: "ask_oracle", resultJSON: flagged, isError: false)
        ))
    }

    func testLegacyResultsWithNothingRetainedSayErrorDetailsUnavailable() throws {
        let legacy = #"{"chat_id":"legacy-chat","status":"failed","summary_only":true,"summary_text":"ask_oracle • failed"}"#
        let legacyItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: legacy, isError: true)
        let saved = try XCTUnwrap(OracleFailureCardPresentation(item: legacyItem))
        XCTAssertTrue(saved.detailsUnavailable)
        XCTAssertEqual(saved.subtitle, OracleFailureCardPresentation.unavailableHeadline)
        XCTAssertEqual(saved.subtitle, "Error details unavailable")
        XCTAssertEqual(saved.unavailableExplanation, "The saved transcript did not keep this Oracle call's error details.")
        XCTAssertEqual(
            AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: legacy),
            "legacy-chat",
            "Open Oracle stays available for legacy failed cards"
        )

        let bare = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: #"{"status":"failed"}"#, isError: true)
        let live = try XCTUnwrap(OracleFailureCardPresentation(item: bare))
        XCTAssertTrue(live.detailsUnavailable)
        XCTAssertEqual(live.unavailableExplanation, "This Oracle result did not include error details.")
    }

    func testSuccessPendingAndCancelledCardsStayStatic() {
        let rows: [(name: String, raw: String, isError: Bool?)] = [
            ("success", jsonString(["status": "success", "chat_id": "chat-1", "mode": "chat", "response": "done"]), false),
            ("completed", jsonString(["status": "completed", "chat_id": "chat-1", "response": "done"]), false),
            ("pending", jsonString(["status": "pending", "operation_id": UUID().uuidString, "pending": ["stream_state": "streaming"]]), false),
            ("queued", jsonString(["status": "pending", "operation_id": UUID().uuidString, "pending": ["stream_state": "queued"]]), false),
            ("cancelling", jsonString(["status": "pending", "cancel": "requested", "operation_id": UUID().uuidString]), false),
            (
                "cancelled",
                jsonString([
                    "ok": false,
                    "status": "cancelled",
                    "operation_id": UUID().uuidString,
                    "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
                ]),
                true
            )
        ]
        for row in rows {
            let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: row.raw, isError: row.isError)
            XCTAssertNil(OracleFailureCardPresentation(item: item), row.name)
        }
    }

    func testTranscriptRowIdentityIsStableAcrossPendingToFailed() {
        let invocationID = UUID()
        let user = AgentChatItem(kind: .user, text: "Please review the change", sequenceIndex: 0)
        let call = AgentChatItem.toolCall(
            name: "ask_oracle",
            invocationID: invocationID,
            argsJSON: jsonString(["message": "review", "mode": "review"]),
            sequenceIndex: 1
        )
        let pending = AgentChatItem.toolResult(
            name: "ask_oracle",
            invocationID: invocationID,
            resultJSON: jsonString([
                "status": "pending",
                "operation_id": "44444444-4444-4444-4444-444444444444",
                "pending": ["stream_state": "streaming"]
            ]),
            isError: false,
            sequenceIndex: 2
        )
        var failed = pending
        let failedJSON = jsonString([
            "ok": false,
            "status": "failed",
            "operation_id": "44444444-4444-4444-4444-444444444444",
            "error": ["code": "oracle_stream_failed", "message": "stream failed"]
        ])
        failed.toolResultJSON = failedJSON
        failed.text = failedJSON
        failed.toolIsError = true

        XCTAssertNil(OracleFailureCardPresentation(item: pending))
        XCTAssertNotNil(OracleFailureCardPresentation(item: failed))
        XCTAssertEqual(failed.id, pending.id)

        let pendingBlocks = AgentTranscriptProjectionBuilder.blocks(
            for: AgentTranscriptIO.buildTranscript(from: [user, call, pending])
        )
        let failedBlocks = AgentTranscriptProjectionBuilder.blocks(
            for: AgentTranscriptIO.buildTranscript(from: [user, call, failed])
        )
        XCTAssertEqual(pendingBlocks.map(\.id), failedBlocks.map(\.id))
        XCTAssertEqual(
            pendingBlocks.flatMap { $0.rows.map(\.id) },
            failedBlocks.flatMap { $0.rows.map(\.id) }
        )
        let pendingRowID = pendingBlocks.flatMap(\.rows)
            .first { $0.kind == .toolResult && $0.toolName == "ask_oracle" }?.id
        let failedRowID = failedBlocks.flatMap(\.rows)
            .first { $0.kind == .toolResult && $0.toolName == "ask_oracle" }?.id
        XCTAssertNotNil(failedRowID)
        XCTAssertEqual(pendingRowID, failedRowID, "The transcript row keeps .id(item.id) across the status change")
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
