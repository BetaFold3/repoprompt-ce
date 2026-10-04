@testable import RepoPromptApp
import XCTest

/// Oracle failure inspection plan, Patch B (B1–B3, B5): the shared failure projection, its
/// redaction, and the bounded persisted failure summary.
final class OracleToolResultInspectionTests: XCTestCase {
    // MARK: - Sanitize → persist → decode

    func testPlainTextFailureRoundTripsRedactedDiagnosticWithoutFreeTextCode() throws {
        let secret = syntheticCredential("sk", "proj", "ABCDEFGHIJKLMNOPQRSTUVWX1234", separator: "-")
        let raw = "MCP error -32602: Invalid params: oracle_model_required: pass model. key \(secret)\nsecond line"
        for toolName in ["ask_oracle", "oracle_send"] {
            let item = AgentChatItem.toolResult(
                name: toolName,
                argsJSON: jsonString(["mode": "review", "message": "please review", "new_chat": true]),
                resultJSON: raw,
                isError: true
            )
            let live = try XCTUnwrap(OracleFailureCardPresentation(item: item), toolName)
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
            XCTAssertLessThanOrEqual(
                summary.resultJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                toolName
            )
            XCTAssertFalse(summary.resultJSON.contains(secret), toolName)

            let object = try decodedObject(summary.resultJSON)
            let errors = try XCTUnwrap(object["errors"] as? [[String: Any]], toolName)
            XCTAssertEqual(errors.count, 1, toolName)
            let expectedMessage = "MCP error -32602: Invalid params: oracle_model_required: pass model. key <redacted>\nsecond line"
            XCTAssertEqual(errors[0]["message"] as? String, expectedMessage, toolName)
            XCTAssertNil(errors[0]["code"], "A code is never derived from free text, \(toolName)")
            XCTAssertEqual(object["error_count"] as? Int, 1, toolName)
            XCTAssertNil(object["error_truncated"], toolName)
            XCTAssertEqual(
                object["summary_text"] as? String,
                "Failed: MCP error -32602: Invalid params: oracle_model_required: pass model. key <redacted>",
                toolName
            )
            XCTAssertEqual(object["mode"] as? String, "review", "Recognized mode from the actual arguments, \(toolName)")
            XCTAssertNil(object["message"], "No other argument is copied, \(toolName)")
            XCTAssertNil(object["new_chat"], toolName)
            XCTAssertNil(object["results"], toolName)

            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: summary.resultJSON))
            XCTAssertEqual(dto.errors, [expectedMessage], toolName)
            XCTAssertNil(dto.results, toolName)

            let restored = AgentChatItemPersist(from: item).toItem()
            XCTAssertEqual(restored.toolResultJSON, summary.resultJSON, toolName)
            let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: restored), toolName)
            XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics, toolName)
            XCTAssertEqual(reloaded.subtitle, live.subtitle, toolName)
            XCTAssertEqual(
                live.subtitle,
                "MCP error -32602: Invalid params: oracle_model_required: pass model. key <redacted>",
                toolName
            )
        }
    }

    func testToolErrorShapesKeepOnlyStructuredCodes() throws {
        let longCode = String(repeating: "c", count: OracleToolResultInspection.codeMaxBytes + 1)
        let boundaryCode = String(repeating: "d", count: OracleToolResultInspection.codeMaxBytes)
        let rows: [(name: String, raw: String, isError: Bool?, code: String?, message: String, truncated: Bool)] = [
            (
                "executionContractToolErrorResult",
                jsonString(["is_error": true, "code": "oracle_model_required", "error": "new_chat:true requires model"]),
                true,
                "oracle_model_required",
                "new_chat:true requires model",
                false
            ),
            (
                "toolErrorResult",
                jsonString(["is_error": true, "error": "Error: oracle_model_required: pass model"]),
                true,
                nil,
                "Error: oracle_model_required: pass model",
                false
            ),
            (
                "ok:false error object",
                jsonString([
                    "ok": false,
                    "status": "failed",
                    "chat_id": "chat-7",
                    "error": ["code": "oracle_stream_failed", "message": "The Oracle consultation failed."]
                ]),
                false,
                "oracle_stream_failed",
                "The Oracle consultation failed.",
                false
            ),
            (
                "Codex message object",
                jsonString(["message": "Codex transport closed before the reply"]),
                true,
                nil,
                "Codex transport closed before the reply",
                false
            ),
            (
                "MCP content envelope with structured error",
                jsonString([
                    "content": [[
                        "type": "text",
                        "text": jsonString(["is_error": true, "code": "oracle_busy", "error": "Oracle is busy"])
                    ]],
                    "isError": true
                ]),
                true,
                "oracle_busy",
                "Oracle is busy",
                false
            ),
            (
                "MCP content envelope with plain text",
                jsonString([
                    "content": [["type": "text", "text": "MCP error -32602: Invalid params: boom"]],
                    "isError": true
                ]),
                true,
                nil,
                "MCP error -32602: Invalid params: boom",
                false
            ),
            (
                "over-long code is omitted, never truncated",
                jsonString(["is_error": true, "code": longCode, "error": "long code"]),
                true,
                nil,
                "long code",
                true
            ),
            (
                "code at the byte bound is kept",
                jsonString(["is_error": true, "code": boundaryCode, "error": "boundary code"]),
                true,
                boundaryCode,
                "boundary code",
                false
            ),
            (
                "non-identifier code is omitted",
                jsonString(["is_error": true, "code": "not a code", "error": "spaced code"]),
                true,
                nil,
                "spaced code",
                true
            )
        ]
        for row in rows {
            let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: row.raw, isError: row.isError)
            let live = try XCTUnwrap(OracleFailureCardPresentation(item: item), row.name)
            XCTAssertEqual(live.failure.primary?.code, row.code, row.name)
            XCTAssertEqual(live.failure.primary?.message, row.message, row.name)

            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), row.name)
            let object = try decodedObject(summary.resultJSON)
            let errors = try XCTUnwrap(object["errors"] as? [[String: Any]], row.name)
            XCTAssertEqual(errors.first?["code"] as? String, row.code, row.name)
            XCTAssertEqual(errors.first?["message"] as? String, row.message, row.name)
            XCTAssertEqual(object["error_count"] as? Int, 1, row.name)
            XCTAssertEqual(object["error_truncated"] as? Bool, row.truncated ? true : nil, row.name)
            XCTAssertEqual(object["summary_text"] as? String, "Failed: \(row.message)", row.name)
            XCTAssertFalse(summary.resultJSON.contains(longCode), row.name)
        }
        XCTAssertEqual(
            AgentOracleAuthoritativeChatIDPolicy.extract(
                fromSerializedJSON: AgentChatItemPersist(
                    from: AgentChatItem.toolResult(name: "ask_oracle", resultJSON: rows[2].raw, isError: false)
                ).toItem().toolResultJSON
            ),
            "chat-7",
            "chat_id keeps powering Open Oracle after reload"
        )
    }

    func testDiagnosticSelectionSkipsEmptyEntriesAndRetainsUpToFourInSourceOrder() throws {
        let raw = jsonString([
            "status": "failed",
            "errors": [
                "",
                "   ",
                ["message": ""],
                "first real error",
                ["code": "second_code", "message": "second error"],
                "third error",
                "fourth error",
                "fifth error"
            ]
        ])
        let failure = try XCTUnwrap(OracleToolResultInspection.inspect(
            resultJSON: raw,
            text: nil,
            toolIsError: true,
            statusWord: "failed"
        ))
        XCTAssertEqual(failure.diagnostics.map(\.message), ["first real error", "second error", "third error", "fourth error"])
        XCTAssertEqual(failure.diagnostics.map(\.code), [nil, "second_code", nil, nil])
        XCTAssertEqual(failure.errorCount, 5)
        XCTAssertEqual(failure.omittedDiagnosticCount, 1)
        XCTAssertTrue(failure.isTruncated)
        XCTAssertFalse(failure.primaryMessageTruncated)
        XCTAssertEqual(failure.summaryText, "Failed: first real error")

        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        let object = try decodedObject(XCTUnwrap(AgentChatItemPersist(from: item).toItem().toolResultJSON))
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertEqual(errors.compactMap { $0["message"] as? String }, ["first real error", "second error", "third error", "fourth error"])
        XCTAssertEqual(object["error_count"] as? Int, 5)
        XCTAssertEqual(object["error_truncated"] as? Bool, true)

        let secondaryRaw = jsonString([
            "status": "failed",
            "errors": ["primary", String(repeating: "s", count: 400)]
        ])
        let secondary = try XCTUnwrap(OracleToolResultInspection.inspect(
            resultJSON: secondaryRaw,
            text: nil,
            toolIsError: nil,
            statusWord: nil
        ))
        XCTAssertLessThanOrEqual(
            secondary.diagnostics[1].message.utf8.count,
            OracleToolResultInspection.secondaryMessageMaxBytes
        )
        XCTAssertTrue(secondary.diagnostics[1].message.hasSuffix(OracleToolResultInspection.truncationMarker))
        XCTAssertTrue(secondary.isTruncated)
        XCTAssertFalse(secondary.primaryMessageTruncated)
    }

    func testRedactionRunsBeforeTruncationForSecretStraddlingTheCut() throws {
        let secretBody = syntheticCredential("QWERTYUIOPASDFGHJKLZ", "XCVBNM123456")
        let prefix = String(repeating: "x ", count: 248)
        let raw = prefix + "sk-proj-" + secretBody + " " + String(repeating: "y", count: 100)
        XCTAssertGreaterThan(raw.utf8.count, OracleToolResultInspection.primaryMessageMaxBytes)

        // Truncating first would leave a fragment the scrubber no longer recognizes.
        let naive = OracleToolResultInspection.truncatedUTF8(
            raw,
            maxBytes: OracleToolResultInspection.primaryMessageMaxBytes
        ).text
        XCTAssertTrue(OracleDiagnosticRedactor.redact(naive).contains("sk-proj-"))

        let failure = try XCTUnwrap(OracleToolResultInspection.inspect(
            resultJSON: raw,
            text: nil,
            toolIsError: true,
            statusWord: "failed"
        ))
        let message = try XCTUnwrap(failure.primary?.message)
        XCTAssertFalse(message.contains("sk-proj-"))
        XCTAssertFalse(message.contains(String(secretBody.prefix(4))))
        XCTAssertTrue(message.contains(OracleDiagnosticRedactor.placeholder))
        XCTAssertTrue(message.hasSuffix(OracleToolResultInspection.truncationMarker))
        XCTAssertLessThanOrEqual(message.utf8.count, OracleToolResultInspection.primaryMessageMaxBytes)
        XCTAssertTrue(failure.primaryMessageTruncated)
        XCTAssertTrue(failure.isTruncated)

        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        let persisted = try XCTUnwrap(AgentChatItemPersist(from: item).toItem().toolResultJSON)
        XCTAssertFalse(persisted.contains("sk-proj-"))
        XCTAssertFalse(persisted.contains(String(secretBody.prefix(4))))
        XCTAssertEqual(try decodedObject(persisted)["error_truncated"] as? Bool, true)
        let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: AgentChatItemPersist(from: item).toItem()))
        XCTAssertTrue(reloaded.showsTruncationNote, "A saved, cut primary message keeps its truncation note")
    }

    func testEncodedFailureSummaryStaysWithinBudgetWithUnicodeAndEscaping() throws {
        let hostile = "\"\\/é🙂漢\u{0007}\u{200B}\t"
        let raw = jsonString([
            "status": "failed",
            "chat_id": "chat-unicode",
            "mode": "review",
            "model_source": "preset",
            "model_preset_id": "11111111-2222-3333-4444-555555555555",
            "model_preset_name": String(repeating: "预设", count: 40),
            "model_selection": "explicit",
            "errors": (0 ..< 6).map { index in
                ["code": "oracle_error_\(index)", "message": String(repeating: hostile, count: 120)]
            }
        ])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
        XCTAssertLessThanOrEqual(
            summary.resultJSON.utf8.count,
            AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes
        )
        let object = try decodedObject(summary.resultJSON)
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertFalse(errors.isEmpty)
        let primary = try XCTUnwrap(errors[0]["message"] as? String)
        XCTAssertLessThanOrEqual(primary.utf8.count, OracleToolResultInspection.primaryMessageMaxBytes)
        XCTAssertFalse(primary.contains("\u{0007}"), "Control characters are stripped")
        XCTAssertFalse(primary.contains("\u{200B}"), "Format characters are stripped")
        XCTAssertTrue(primary.contains("🙂漢"), "Unicode is kept whole at grapheme boundaries")
        for entry in errors.dropFirst() {
            let message = try XCTUnwrap(entry["message"] as? String)
            XCTAssertLessThanOrEqual(message.utf8.count, OracleToolResultInspection.secondaryMessageMaxBytes)
        }
        XCTAssertEqual(object["error_count"] as? Int, 6)
        XCTAssertEqual(object["error_truncated"] as? Bool, true)
        XCTAssertEqual(object["chat_id"] as? String, "chat-unicode")
        let summaryText = try XCTUnwrap(object["summary_text"] as? String)
        XCTAssertTrue(summaryText.hasPrefix(OracleToolResultInspection.summaryTextPrefix))
        XCTAssertLessThanOrEqual(summaryText.utf8.count, OracleToolResultInspection.summaryTextMaxBytes)

        let restored = AgentChatItemPersist(from: item).toItem()
        XCTAssertEqual(AgentChatItemPersist(from: restored).toItem().toolResultJSON, restored.toolResultJSON)
    }

    func testFailureSummaryShedsInDocumentedOrder() throws {
        let primaryMessage = String(repeating: "primary diagnostic text ", count: 17)
        XCTAssertGreaterThan(primaryMessage.utf8.count, OracleToolResultInspection.shortenedPrimaryMessageMaxBytes)
        let raw = jsonString([
            "status": "failed",
            "errors": [
                ["code": "oracle_stream_failed", "message": primaryMessage],
                "second error",
                "third error",
                "fourth error"
            ]
        ])
        let failure = try XCTUnwrap(OracleToolResultInspection.inspect(
            resultJSON: raw,
            text: nil,
            toolIsError: true,
            statusWord: "failed"
        ))
        let base: [String: Any] = [
            "status": "failed",
            "summary_only": true,
            "chat_id": "chat-shed",
            "mode": "review",
            "model_preset_name": "OracleA",
            "model_selection": "explicit",
            "has_response": false
        ]
        func shed(_ maxBytes: Int) throws -> (json: String, object: [String: Any]) {
            let json = OracleToolResultInspection.boundedFailureSummaryJSON(
                base: base,
                failure: failure,
                argumentMode: nil,
                statusWord: "failed",
                normalizedToolName: "ask_oracle",
                maxBytes: maxBytes
            )
            return try (json, decodedObject(json))
        }
        func entries(_ object: [String: Any]) -> [[String: Any]] {
            object["errors"] as? [[String: Any]] ?? []
        }

        let full = try shed(Int.max)
        XCTAssertEqual(entries(full.object).count, 4)
        XCTAssertNil(full.object["error_truncated"])

        let primaryOnly = try shed(full.json.utf8.count - 1)
        XCTAssertLessThan(primaryOnly.json.utf8.count, full.json.utf8.count)
        XCTAssertEqual(entries(primaryOnly.object).count, 1, "Diagnostics 1–3 are dropped first")
        XCTAssertEqual(entries(primaryOnly.object).first?["code"] as? String, "oracle_stream_failed")
        XCTAssertEqual(primaryOnly.object["error_truncated"] as? Bool, true)
        XCTAssertEqual(primaryOnly.object["error_count"] as? Int, 4)

        let shortened = try shed(primaryOnly.json.utf8.count - 1)
        let shortenedMessage = try XCTUnwrap(entries(shortened.object).first?["message"] as? String)
        XCTAssertLessThanOrEqual(shortenedMessage.utf8.count, OracleToolResultInspection.shortenedPrimaryMessageMaxBytes)
        XCTAssertEqual(entries(shortened.object).first?["code"] as? String, "oracle_stream_failed", "Then the message shortens")

        let codeless = try shed(shortened.json.utf8.count - 1)
        XCTAssertEqual(entries(codeless.object).count, 1)
        XCTAssertNil(entries(codeless.object).first?["code"], "Then the code is dropped")
        XCTAssertEqual(codeless.object["model_preset_name"] as? String, "OracleA")

        let minimal = try shed(codeless.json.utf8.count - 1)
        XCTAssertEqual(entries(minimal.object).count, 1, "The minimal stage keeps a short primary diagnostic")
        XCTAssertEqual(minimal.object["chat_id"] as? String, "chat-shed", "and its bounded identity")
        XCTAssertNil(minimal.object["model_preset_name"])
        XCTAssertEqual(minimal.object["error_count"] as? Int, 4)
        XCTAssertEqual(minimal.object["summary_text"] as? String, failure.summaryText)

        let fallback = try shed(minimal.json.utf8.count - 1)
        XCTAssertNil(fallback.object["errors"], "Finally the minimal status object")
        XCTAssertEqual(fallback.object["summary_text"] as? String, failure.summaryText)
        XCTAssertEqual(fallback.object["status"] as? String, "failed")

        for stage in [full, primaryOnly, shortened, codeless, minimal, fallback] {
            XCTAssertNil(stage.object["results"])
        }
    }

    // MARK: - Unchanged outputs

    func testSuccessfulOracleSummaryIsByteIdenticalGolden() throws {
        let raw = jsonString([
            "status": "success",
            "chat_id": "chat-123",
            "mode": "review",
            "ui_model_id": "provider-model-id",
            "ui_model_name": "Resolved Provider Model",
            "model_selection": "explicit",
            "model_source": "preset",
            "model_preset_id": "11111111-2222-3333-4444-555555555555",
            "model_preset_name": "Claude_Fable_xhigh",
            "response": "done",
            "diffs": [["path": "File.swift", "diff": "-old\n+new"]]
        ])
        let golden = #"{"chat_id":"chat-123","diff_count":1,"has_response":true,"mode":"review","model_preset_id":"11111111-2222-3333-4444-555555555555","model_preset_name":"Claude_Fable_xhigh","model_selection":"explicit","model_source":"preset","status":"success","summary_only":true,"summary_text":"review • Claude_Fable_xhigh • 1 diff"}"#
        for toolName in ["ask_oracle", "oracle_send"] {
            let item = AgentChatItem.toolResult(name: toolName, resultJSON: raw, isError: false)
            XCTAssertNil(OracleFailureCardPresentation(item: item), toolName)
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
            XCTAssertEqual(summary.resultJSON, golden, toolName)
            XCTAssertEqual(AgentChatItemPersist(from: item).toItem().toolResultJSON, golden, toolName)
        }
    }

    func testPendingAndCancelledOnlyResultsGainNothing() throws {
        let failureKeys = ["errors", "error_truncated", "lane_count", "failed_count", "nonterminal_count"]
        let rows: [(name: String, raw: String, isError: Bool?, golden: String?)] = [
            (
                "pending",
                jsonString([
                    "status": "pending",
                    "operation_id": "11111111-1111-1111-1111-111111111111",
                    "chat_id": "pending-chat",
                    "mode": "plan",
                    "pending": ["reason": "timed_out", "stream_state": "streaming", "elapsed_seconds": 181]
                ]),
                false,
                #"{"chat_id":"pending-chat","mode":"plan","status":"pending","summary_only":true,"summary_text":"plan • pending-chat"}"#
            ),
            (
                "cancelled with error flag",
                jsonString([
                    "ok": false,
                    "status": "cancelled",
                    "operation_id": "55555555-5555-5555-5555-555555555555",
                    "chat_id": "cancelled-chat",
                    "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
                ]),
                true,
                #"{"chat_id":"cancelled-chat","status":"cancelled","summary_only":true,"summary_text":"cancelled-chat"}"#
            ),
            (
                "envelope with only pending and cancelled lanes",
                jsonString([
                    "results": [
                        [
                            "index": 0,
                            "status": "pending",
                            "operation_id": "22222222-2222-2222-2222-222222222222",
                            "chat_id": "pending-chat",
                            "pending": ["stream_state": "queued"]
                        ],
                        [
                            "index": 1,
                            "ok": false,
                            "status": "cancelled",
                            "operation_id": "33333333-3333-3333-3333-333333333333",
                            "chat_id": "cancelled-chat",
                            "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
                        ]
                    ],
                    "wait": ["result": "polled", "pending_operation_ids": ["22222222-2222-2222-2222-222222222222"]]
                ]),
                false,
                nil
            ),
            (
                "invocation error flag on an envelope whose lanes are all still pending",
                jsonString([
                    "results": [
                        [
                            "index": 0,
                            "status": "pending",
                            "operation_id": "77777777-7777-7777-7777-777777777770",
                            "chat_id": "pending-chat-0",
                            "pending": ["stream_state": "streaming"]
                        ],
                        [
                            "index": 1,
                            "status": "running",
                            "operation_id": "77777777-7777-7777-7777-777777777771",
                            "chat_id": "pending-chat-1"
                        ]
                    ],
                    "wait": ["result": "timed_out", "pending_operation_ids": ["77777777-7777-7777-7777-777777777770"]]
                ]),
                true,
                nil
            ),
            (
                "invocation error flag on an envelope with only cancelled lanes",
                jsonString([
                    "results": [[
                        "index": 0,
                        "ok": false,
                        "status": "cancelled",
                        "operation_id": "88888888-8888-8888-8888-888888888888",
                        "chat_id": "cancelled-chat",
                        "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
                    ]],
                    "note": "Cancelled."
                ]),
                true,
                nil
            )
        ]
        for row in rows {
            let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: row.raw, isError: row.isError)
            XCTAssertNil(OracleFailureCardPresentation(item: item), row.name)
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), row.name)
            let object = try decodedObject(summary.resultJSON)
            for key in failureKeys {
                XCTAssertNil(object[key], "\(row.name): \(key)")
            }
            XCTAssertFalse((object["summary_text"] as? String)?.hasPrefix("Failed:") == true, row.name)
            XCTAssertNil(object["pending"], row.name)
            XCTAssertNil(object["results"], row.name)
            for transient in ["operation_id", "elapsed_seconds", "stream_state", "progress"] {
                XCTAssertFalse(summary.resultJSON.contains(transient), "\(row.name): \(transient) is not kept at rest")
            }
            if let golden = row.golden {
                XCTAssertEqual(summary.resultJSON, golden, row.name)
            }
        }
        XCTAssertNil(
            OracleToolResultInspection.inspect(resultJSON: "Cancelled by user", text: nil, toolIsError: true, statusWord: "cancelled"),
            "An error flag on a cancelled call is not a failure"
        )
        XCTAssertNil(
            OracleToolResultInspection.inspect(resultJSON: "still running", text: nil, toolIsError: true, statusWord: "running"),
            "An invocation error never marks a still-running Oracle terminal"
        )
        XCTAssertNil(
            OracleToolResultInspection.inspect(
                resultJSON: jsonString(["status": "completed", "response": "The error: was handled"]),
                text: nil,
                toolIsError: false,
                statusWord: "success"
            ),
            "Successful response text never becomes an error"
        )
    }

    // MARK: - Fixed point, lanes, identity, notices

    func testResanitizationIsAFixedPoint() {
        let fixtures: [(name: String, raw: String, isError: Bool?)] = [
            ("plain text", "Error: provider rejected https://user:pw@example.com/v1?key=abc#frag", true),
            (
                "structured errors",
                jsonString(["status": "failed", "errors": (0 ..< 6).map { "error \($0) " + String(repeating: "é", count: 120) }]),
                true
            ),
            ("lane envelope", laneEnvelopeJSON(), false),
            (
                "oversized hostile",
                jsonString([
                    "status": "failed",
                    "chat_id": "chat-fixed",
                    "errors": (0 ..< 5).map { _ in String(repeating: "\"\\/🙂 token=abcdef ", count: 60) }
                ]),
                true
            )
        ]
        for fixture in fixtures {
            let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: fixture.raw, isError: fixture.isError)
            let once = AgentChatItemPersist(from: item).toItem()
            let twice = AgentChatItemPersist(from: once).toItem()
            let thrice = AgentChatItemPersist(from: twice).toItem()
            XCTAssertNotNil(OracleFailureCardPresentation(item: once), fixture.name)
            XCTAssertEqual(once.toolResultJSON, twice.toolResultJSON, fixture.name)
            XCTAssertEqual(twice.toolResultJSON, thrice.toolResultJSON, fixture.name)
            XCTAssertEqual(
                AgentToolResultPersistencePolicy.persistedToolResultSummary(for: once)?.resultJSON,
                once.toolResultJSON,
                fixture.name
            )
        }
    }

    func testLaneEnvelopeRetainsFourDiagnosticsWithLaneIdentityAndHistoricalCounts() throws {
        let raw = laneEnvelopeJSON()
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: false)
        let liveDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: raw))
        XCTAssertEqual(
            OracleToolCardPresentation(dto: liveDTO, resultObject: ToolJSON.structuredResultObject(from: raw)).state,
            .failed
        )
        let live = try XCTUnwrap(OracleFailureCardPresentation(item: item))
        XCTAssertEqual(live.failure.diagnostics.map(\.index), [1, 3, 4, 5])
        XCTAssertEqual(live.failure.diagnostics.map(\.laneChatID), ["lane-1", nil, "lane-4", "lane-5"])
        XCTAssertEqual(live.failure.diagnostics.map(\.code), ["oracle_stream_failed", nil, nil, "oracle_provider_error"])
        XCTAssertEqual(live.failure.diagnostics.map(\.message), [
            "Lane one stream failed\nstack line",
            "Lane three provider rejected the request",
            "Lane four delivery failed",
            "Lane five failed"
        ])
        XCTAssertEqual(
            live.failure.laneCounts,
            OracleToolResultInspection.LaneCounts(laneCount: 8, failedCount: 5, nonterminalCount: 1)
        )
        XCTAssertEqual(live.failure.errorCount, 5)
        XCTAssertEqual(live.subtitle, "5 of 8 failed • Lane one stream failed")
        XCTAssertEqual(live.laneSummary, "5 of 8 lanes failed; 1 unfinished when recorded")
        XCTAssertEqual(live.omittedSummary, "1 more error was not retained")

        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        let object = try decodedObject(summary.resultJSON)
        XCTAssertNil(object["results"], "An empty or partial lane array is never persisted")
        XCTAssertEqual(object["lane_count"] as? Int, 8)
        XCTAssertEqual(object["failed_count"] as? Int, 5)
        XCTAssertEqual(object["nonterminal_count"] as? Int, 1)
        XCTAssertEqual(object["error_count"] as? Int, 5)
        XCTAssertEqual(object["error_truncated"] as? Bool, true)
        XCTAssertEqual(object["summary_text"] as? String, "Failed: Lane one stream failed")
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertEqual(errors.compactMap { $0["index"] as? Int }, [1, 3, 4, 5])
        XCTAssertEqual(errors.map { $0["lane_chat_id"] as? String }, ["lane-1", nil, "lane-4", "lane-5"])
        XCTAssertTrue(errors.allSatisfy { $0["chat_id"] == nil }, "Lane identity never uses the root chat_id key")
        XCTAssertNil(object["pending"])
        for transient in ["operation_id", "elapsed_seconds", "stream_state", "progress"] {
            XCTAssertFalse(summary.resultJSON.contains(transient), transient)
        }

        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: summary.resultJSON))
        XCTAssertNil(dto.results, "No lane is fabricated from an empty array")
        XCTAssertEqual(dto.errors?.count, 4)

        let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: AgentChatItemPersist(from: item).toItem()))
        XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics)
        XCTAssertEqual(reloaded.subtitle, live.subtitle)
        XCTAssertEqual(reloaded.laneSummary, live.laneSummary)
        XCTAssertEqual(reloaded.omittedSummary, live.omittedSummary)

        // A root chat_id stays authoritative and failed-lane identities are kept beside it under
        // the explicitly scoped `lane_chat_id` key, so each retained failure can open its lane.
        var rooted = try decodedObject(raw)
        rooted["chat_id"] = "root-chat"
        let rootedItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: jsonString(rooted), isError: false)
        let rootedLive = try XCTUnwrap(OracleFailureCardPresentation(item: rootedItem))
        XCTAssertEqual(rootedLive.failure.diagnostics.map(\.laneChatID), ["lane-1", nil, "lane-4", "lane-5"])
        let rootedRestored = AgentChatItemPersist(from: rootedItem).toItem()
        let rootedJSON = try XCTUnwrap(rootedRestored.toolResultJSON)
        let rootedObject = try decodedObject(rootedJSON)
        XCTAssertEqual(rootedObject["chat_id"] as? String, "root-chat")
        let rootedErrors = try XCTUnwrap(rootedObject["errors"] as? [[String: Any]])
        XCTAssertEqual(rootedErrors.map { $0["lane_chat_id"] as? String }, ["lane-1", nil, "lane-4", "lane-5"])
        XCTAssertTrue(rootedErrors.allSatisfy { $0["chat_id"] == nil })
        XCTAssertEqual(
            AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: rootedJSON),
            "root-chat",
            "Root routing authority is unchanged by retained lane identities"
        )
        let rootedReloaded = try XCTUnwrap(OracleFailureCardPresentation(item: rootedRestored))
        XCTAssertEqual(rootedReloaded.failure.diagnostics, rootedLive.failure.diagnostics)
        XCTAssertEqual(AgentChatItemPersist(from: rootedRestored).toItem().toolResultJSON, rootedJSON, "Fixed point")
    }

    func testAdditionalLaneDiagnosticsCountTowardOriginalErrorCount() throws {
        let raw = jsonString([
            "results": [
                [
                    "index": 0,
                    "ok": false,
                    "status": "failed",
                    "chat_id": "lane-0",
                    "errors": ["first lane-zero error", "", "second lane-zero error", "third lane-zero error"],
                    "error": ["code": "oracle_provider_error", "message": "lane-zero summary error"]
                ],
                [
                    "index": 1,
                    "ok": false,
                    "status": "failed",
                    "chat_id": "lane-1",
                    "error": "lane-one error"
                ],
                ["index": 2, "status": "completed", "chat_id": "lane-2", "response": "done"]
            ],
            "wait": ["result": "completed_with_errors", "pending_operation_ids": []]
        ])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: false)
        let live = try XCTUnwrap(OracleFailureCardPresentation(item: item))
        XCTAssertEqual(live.failure.diagnostics.map(\.message), ["first lane-zero error", "lane-one error"])
        XCTAssertEqual(live.failure.diagnostics.map(\.index), [0, 1])
        XCTAssertEqual(live.failure.errorCount, 5, "Every non-empty lane diagnostic counts before retention")
        XCTAssertTrue(live.failure.isTruncated)
        XCTAssertEqual(live.omittedSummary, "3 more errors were not retained")

        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
        let object = try decodedObject(summary.resultJSON)
        XCTAssertEqual(object["error_count"] as? Int, 5)
        XCTAssertEqual(object["error_truncated"] as? Bool, true)
        XCTAssertEqual((object["errors"] as? [Any])?.count, 2)
        for omitted in ["second lane-zero error", "third lane-zero error", "lane-zero summary error"] {
            XCTAssertFalse(summary.resultJSON.contains(omitted), omitted)
        }

        let restored = AgentChatItemPersist(from: item).toItem()
        let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: restored))
        XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics)
        XCTAssertEqual(reloaded.failure.errorCount, 5)
        XCTAssertEqual(reloaded.omittedSummary, live.omittedSummary)
        XCTAssertEqual(AgentChatItemPersist(from: restored).toItem().toolResultJSON, restored.toolResultJSON)
    }

    // MARK: - Cursor ACP

    func testCursorACPOracleFailureRoundTripsRedactedDiagnostics() throws {
        let oracleError: [String: Any] = [
            "ok": false,
            "status": "failed",
            "chat_id": "cursor-chat",
            "error": [
                "code": "oracle_stream_failed",
                "message": #"Provider rejected password="correct horse battery staple" for this request"#
            ]
        ]
        let oracleErrorText = jsonString(oracleError)
        let rawOutputs: [(name: String, rawOutput: Any)] = [
            ("Oracle error object", oracleError),
            ("MCP content envelope", ["content": [["type": "text", "text": oracleErrorText]], "isError": true]),
            ("serialized text", oracleErrorText)
        ]
        for toolName in ["ask_oracle", "oracle_send"] {
            for fixture in rawOutputs {
                let label = "\(toolName): \(fixture.name)"
                let events = CursorACPEventNormalizer.normalize([
                    "sessionUpdate": "tool_call_update",
                    "status": "failed",
                    "toolCallId": "oracle-failure-\(toolName)",
                    "toolName": toolName,
                    "kind": "other",
                    "title": "Tool result",
                    "rawInput": ["mode": "review", "message": "please review", "new_chat": true],
                    "rawOutput": fixture.rawOutput
                ])
                guard case let .stream(result) = try XCTUnwrap(events.first, label) else {
                    return XCTFail("Expected a normalized Cursor ACP stream event, \(label)")
                }
                let raw = try XCTUnwrap(result.toolResultJSON, label)
                let item = AgentChatItem.toolResult(name: toolName, resultJSON: raw, isError: nil)
                let live = try XCTUnwrap(OracleFailureCardPresentation(item: item), label)
                let expectedMessage = #"Provider rejected password="<redacted>""#
                XCTAssertEqual(live.failure.primary?.message, expectedMessage, label)
                XCTAssertEqual(live.failure.primary?.code, "oracle_stream_failed", label)

                let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), label)
                XCTAssertLessThanOrEqual(
                    summary.resultJSON.utf8.count,
                    AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                    label
                )
                for fragment in ["correct", "horse", "battery", "staple", "for this request", "please review"] {
                    XCTAssertFalse(summary.resultJSON.contains(fragment), "\(label): \(fragment)")
                }
                let object = try decodedObject(summary.resultJSON)
                XCTAssertEqual(object["acp_status"] as? String, "failed", label)
                XCTAssertEqual(object["mode"] as? String, "review", label)
                XCTAssertNil(object["rawOutput"], label)
                XCTAssertEqual(object["summary_text"] as? String, "Failed: \(expectedMessage)", label)

                let restored = AgentChatItemPersist(from: item).toItem()
                XCTAssertEqual(restored.toolResultJSON, summary.resultJSON, label)
                let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: restored), label)
                XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics, label)
                XCTAssertEqual(reloaded.subtitle, live.subtitle, label)
                XCTAssertFalse(reloaded.detailsUnavailable, label)
                XCTAssertEqual(AgentChatItemPersist(from: restored).toItem().toolResultJSON, restored.toolResultJSON, label)
            }
        }

        // A failed ACP call whose wrapped Oracle result is still pending is not a failure.
        let pendingEvents = CursorACPEventNormalizer.normalize([
            "sessionUpdate": "tool_call_update",
            "status": "failed",
            "toolCallId": "oracle-pending",
            "toolName": "ask_oracle",
            "kind": "other",
            "rawOutput": [
                "status": "pending",
                "operation_id": "66666666-6666-6666-6666-666666666666",
                "pending": ["stream_state": "streaming"]
            ]
        ])
        guard case let .stream(pendingResult) = try XCTUnwrap(pendingEvents.first) else {
            return XCTFail("Expected a normalized Cursor ACP stream event")
        }
        let pendingRaw = try XCTUnwrap(pendingResult.toolResultJSON)
        let pendingItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: pendingRaw, isError: nil)
        XCTAssertNil(OracleFailureCardPresentation(item: pendingItem))
    }

    // MARK: - Quoted credentials

    func testQuotedCredentialsLeaveNoFragmentsAfterPersistAndReload() throws {
        // Text before the first secret-named value that opens a quote is kept; everything from
        // its opening delimiter onward is removed, even when the quote looks closed.
        let scenarios: [(name: String, text: String, expected: String, fragments: [String])] = [
            ("double quotes", #"password="correct horse" after"#, #"password="<redacted>""#, ["correct", "horse", "after"]),
            ("leading space", #"passphrase=" battery staple" after"#, #"passphrase="<redacted>""#, ["battery", "staple", "after"]),
            (
                "escaped quotes",
                #""client_secret": "charlie \"delta\" echo", after"#,
                #""client_secret": "<redacted>""#,
                ["charlie", "delta", "echo", "after"]
            ),
            (
                "JSON-escaped delimiters",
                #"upstream {\"api_key\": \"foxtrot golf\"} after"#,
                #"upstream {\"api_key\": \"<redacted>\""#,
                ["foxtrot", "golf", "after"]
            ),
            ("single quotes", #"token='hotel india' after"#, #"token='<redacted>'"#, ["hotel", "india", "after"]),
            ("authorization", #"authorization: "Bearer juliet kilo" after"#, #"authorization: "<redacted>""#, ["juliet", "kilo", "after"]),
            ("unterminated across lines", "password=\"lima\nmike\nnovember", #"password="<redacted>""#, ["lima", "mike", "november"]),
            ("line break before the close", "'secret': 'oscar\npapa' quebec", "'secret': '<redacted>'", ["oscar", "papa", "quebec"]),
            ("CRLF", "password=\"romeo\r\nsierra\"\r\ntango", #"password="<redacted>""#, ["romeo", "sierra", "tango"]),
            (
                "JSON-escaped line break",
                #"upstream {\"access_key\": \"uniform"# + "\n" + #"victor\"} whiskey"#,
                #"upstream {\"access_key\": \"<redacted>\""#,
                ["uniform", "victor", "whiskey"]
            ),
            (
                "later bare-key secret on the next line",
                "password=\"xray\ntoken=\"yankee\" zulu",
                #"password="<redacted>""#,
                ["xray", "yankee", "zulu"]
            ),
            ("cross-paired on one line", #"secret: 'amber token: 'bronze' cobalt"#, "secret: '<redacted>'", ["amber", "bronze", "cobalt"]),
            ("mismatched delimiters", #"password="denim' token='ember'"#, #"password="<redacted>""#, ["denim", "ember"]),
            ("escaped closing delimiter", #"password="fennel\" token="garnet""#, #"password="<redacted>""#, ["fennel", "garnet"]),
            ("closed by a key's quote", #"password="hazel token": "indigo""#, #"password="<redacted>""#, ["hazel", "indigo"]),
            (
                "nested unterminated value",
                "'password': 'jasper\"api_key\": \"khaki'\nlemon",
                "'password': '<redacted>'",
                ["jasper", "khaki", "lemon"]
            ),
            ("later unquoted secret", "password=\"maroon\ntoken=olive", #"password="<redacted>""#, ["maroon", "olive"]),
            (
                "key hidden by an escape, next line",
                "secret='nutmeg \\password=\"ochre'\npewter",
                "secret='<redacted>'",
                ["nutmeg", "ochre", "pewter"]
            ),
            (
                "key hidden by an escape, same line",
                "secret=\"quartz \\token='russet\" saffron",
                "secret=\"<redacted>\"",
                ["quartz", "russet", "saffron"]
            ),
            ("escaped single quotes", #"password=\'sepia tawny\' walnut"#, #"password=\'<redacted>\'"#, ["sepia", "tawny", "walnut"]),
            (
                "JSON-escaped opener in a URL",
                "see https://example.com/p?password=\\\"jade\nkelp",
                #"see https://example.com/p?password=<redacted>"<redacted>"#,
                ["jade", "kelp"]
            ),
            // URL userinfo overlapping a secret-named assignment (OracleA R4-01).
            (
                "URL userinfo hiding an assignment",
                "fetch https://alice:alpha;token=bravo@example.com/path failed",
                "fetch https://<redacted> failed",
                ["alice", "alpha", "bravo"]
            ),
            (
                "assignment inside URL userinfo",
                "fetch https://alice:token=bravo;alpha@example.com/path failed",
                "fetch https://<redacted>@example.com/path failed",
                ["alice", "alpha", "bravo"]
            ),
            (
                "quoted assignment inside URL userinfo",
                #"fetch https://alice:alpha;token="bravo"@example.com/path failed"#,
                "fetch https://<redacted>",
                ["alice", "alpha", "bravo"]
            ),
            (
                "single-quoted assignment inside URL userinfo",
                "fetch https://alice:alpha;token='bravo'@example.com/path failed",
                "fetch https://<redacted>",
                ["alice", "alpha", "bravo"]
            )
        ]
        let prefix = "Oracle request failed: "
        for scenario in scenarios {
            let message = prefix + scenario.text
            let fixtures: [(name: String, raw: String, isError: Bool?)] = [
                ("plain text", message, true),
                ("structured error", jsonString(["status": "failed", "error": ["code": "oracle_provider_error", "message": message]]), true),
                ("errors array", jsonString(["status": "failed", "errors": [message, "second: \(message)"]]), true),
                (
                    "lane envelope",
                    jsonString([
                        "results": [["index": 0, "ok": false, "status": "failed", "chat_id": "lane-0", "error": message]],
                        "wait": ["result": "completed_with_errors", "pending_operation_ids": []]
                    ]),
                    false
                )
            ]
            for toolName in ["ask_oracle", "oracle_send"] {
                let cursorACP = try cursorACPResultJSON(
                    toolName: toolName,
                    status: "failed",
                    rawOutput: ["ok": false, "status": "failed", "error": ["code": "oracle_provider_error", "message": message]]
                )
                for fixture in fixtures + [(name: "Cursor ACP wrapper", raw: cursorACP, isError: nil)] {
                    let label = "\(scenario.name), \(toolName), \(fixture.name)"
                    let item = AgentChatItem.toolResult(name: toolName, resultJSON: fixture.raw, isError: fixture.isError)
                    let live = try XCTUnwrap(OracleFailureCardPresentation(item: item), label)
                    XCTAssertEqual(live.failure.diagnostics.first?.message, prefix + scenario.expected, label)
                    let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), label)
                    let restored = AgentChatItemPersist(from: item).toItem()
                    let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: restored), label)
                    let rendered = reloaded.failure.diagnostics.map(\.message) + [reloaded.subtitle]
                    for fragment in scenario.fragments {
                        XCTAssertFalse(summary.resultJSON.contains(fragment), "\(label): persisted \(fragment)")
                        XCTAssertFalse(rendered.contains { $0.contains(fragment) }, "\(label): reloaded \(fragment)")
                        XCTAssertFalse(
                            live.failure.diagnostics.contains { $0.message.contains(fragment) },
                            "\(label): live \(fragment)"
                        )
                    }
                    XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics, label)
                    XCTAssertEqual(AgentChatItemPersist(from: restored).toItem().toolResultJSON, restored.toolResultJSON, label)
                }
            }
        }
    }

    func testLongUnbrokenTokenIsRedactedInLinearTime() {
        // Secret-named keys start at a word start; trying one at every position of an unbroken
        // token took about 0.9 s per rule for two 1,300-character tokens in ICU (about 21 s for
        // one of 8,000 characters).
        // The three tokens fill the scanned-size bound, so they are scanned, not rejected whole.
        let token = String(repeating: "a1", count: 673)
        let text = "Oracle request failed: \(token) api_key=value \(token) password=\"value\" \(token)"
        XCTAssertEqual(text.utf8.count, OracleDiagnosticRedactor.maxScannedBytes - 2)
        let clock = ContinuousClock()
        var redacted = ""
        let elapsed = clock.measure {
            redacted = OracleDiagnosticRedactor.redact(text)
        }
        XCTAssertEqual(redacted, "Oracle request failed: \(token) api_key=<redacted> \(token) password=\"<redacted>\"")
        XCTAssertLessThan(elapsed, .seconds(2), "Tokens within the bound must not be scanned quadratically")
    }

    func testRedactionScansDiagnosticsUpToTheByteBoundExactly() {
        XCTAssertEqual(OracleDiagnosticRedactor.maxScannedBytes, 4096)
        // A dotted quoted tail is the slowest known input: URL scheme detection is quadratic on
        // dotted text, and the tail is scanned before it is removed.
        let prefix = "Oracle request failed: password=\""
        func diagnostic(tailBytes: Int) -> String {
            prefix + String(String(repeating: "a.", count: tailBytes / 2 + 1).prefix(tailBytes)) + "\""
        }
        let tailBytes = OracleDiagnosticRedactor.maxScannedBytes - prefix.utf8.count - 1
        let atBound = diagnostic(tailBytes: tailBytes)
        XCTAssertEqual(atBound.utf8.count, OracleDiagnosticRedactor.maxScannedBytes)
        let clock = ContinuousClock()
        var redacted = ""
        let elapsed = clock.measure {
            redacted = OracleDiagnosticRedactor.redact(atBound)
        }
        XCTAssertEqual(redacted, #"Oracle request failed: password="<redacted>""#)
        XCTAssertEqual(OracleDiagnosticRedactor.redact(redacted), redacted, "Idempotent at the bound")
        XCTAssertLessThan(elapsed, .seconds(2), "A diagnostic at the bound is scanned within a small budget")

        // One byte more is not scanned, and neither is a two-byte character that keeps the
        // UTF-16 length at the bound: the bound counts UTF-8 bytes.
        let overByOne = diagnostic(tailBytes: tailBytes + 1)
        XCTAssertEqual(overByOne.utf8.count, OracleDiagnosticRedactor.maxScannedBytes + 1)
        XCTAssertEqual(OracleDiagnosticRedactor.redact(overByOne), OracleDiagnosticRedactor.placeholder)
        let multibyte = atBound.replacingOccurrences(of: "Oracle", with: "Oracl\u{E9}")
        XCTAssertEqual(multibyte.utf16.count, OracleDiagnosticRedactor.maxScannedBytes)
        XCTAssertEqual(multibyte.utf8.count, OracleDiagnosticRedactor.maxScannedBytes + 1)
        XCTAssertEqual(OracleDiagnosticRedactor.redact(multibyte), OracleDiagnosticRedactor.placeholder)
    }

    func testOversizedDiagnosticIsRedactedWholeThroughReload() throws {
        // Above the scanned-size bound, the whole diagnostic becomes the placeholder before any
        // regex runs; unsanitized text is never truncated to fit. OracleA R5-01: R5 scanned this
        // dotted quoted tail with URL scheme detection, which is quadratic on dotted text. The
        // 1,000,000-character URL also exceeds ICU's backtracking limit (about 330,000).
        let dottedTail = "Oracle request failed: password=\"" + String(repeating: "a.", count: 65536) + "\""
        let longURL = "Oracle request failed: https://example.com/kilo" + String(repeating: "/", count: 1_000_000) + "lima"
        let messages: [(name: String, text: String, fragments: [String])] = [
            ("dotted quoted tail", dottedTail, ["a.a.a.a.", "request failed"]),
            ("long URL", longURL, ["kilo", "lima", "example.com"])
        ]
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for message in messages {
                XCTAssertEqual(OracleDiagnosticRedactor.redact(message.text), OracleDiagnosticRedactor.placeholder, message.name)
                let fixtures: [(name: String, raw: String)] = [
                    ("plain text", message.text),
                    (
                        "structured error",
                        jsonString(["status": "failed", "error": ["code": "oracle_provider_error", "message": message.text]])
                    )
                ]
                for toolName in ["ask_oracle", "oracle_send"] {
                    for fixture in fixtures {
                        let label = "\(message.name), \(toolName), \(fixture.name)"
                        let item = AgentChatItem.toolResult(name: toolName, resultJSON: fixture.raw, isError: true)
                        let live = try XCTUnwrap(OracleFailureCardPresentation(item: item), label)
                        XCTAssertEqual(live.failure.diagnostics.map(\.message), [OracleDiagnosticRedactor.placeholder], label)
                        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), label)
                        let restored = AgentChatItemPersist(from: item).toItem()
                        let reloaded = try XCTUnwrap(OracleFailureCardPresentation(item: restored), label)
                        for fragment in message.fragments {
                            XCTAssertFalse(summary.resultJSON.contains(fragment), "\(label): persisted \(fragment)")
                            XCTAssertFalse(
                                (reloaded.failure.diagnostics.map(\.message) + [reloaded.subtitle]).contains { $0.contains(fragment) },
                                "\(label): reloaded \(fragment)"
                            )
                        }
                        XCTAssertEqual(reloaded.failure.diagnostics, live.failure.diagnostics, label)
                        XCTAssertEqual(AgentChatItemPersist(from: restored).toItem().toolResultJSON, restored.toolResultJSON, label)
                    }
                }
            }
        }
        XCTAssertLessThan(elapsed, .seconds(5), "An oversized diagnostic is rejected without scanning it")
    }

    // MARK: - Routing identity

    func testScopedLaneChatIDsBlockLatestFallbackWithoutInvalidatingRootChatID() throws {
        // A lane-only failure has no root route and never allows identity-free latest fallback,
        // live (nested lane `chat_id`) or reloaded (`lane_chat_id`).
        let raw = laneEnvelopeJSON()
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: false)
        let saved = try XCTUnwrap(AgentChatItemPersist(from: item).toItem().toolResultJSON)
        XCTAssertTrue(saved.contains(#""lane_chat_id""#))
        for (label, json) in [("live", raw), ("reloaded", saved)] {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: json), label)
            XCTAssertFalse(AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: json), label)
        }

        // Beside a root chat_id, lane routes leave root authority unchanged and still rule out
        // latest fallback.
        var rooted = try decodedObject(raw)
        rooted["chat_id"] = "root-chat"
        let rootedItem = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: jsonString(rooted), isError: false)
        let rootedSaved = try XCTUnwrap(AgentChatItemPersist(from: rootedItem).toItem().toolResultJSON)
        XCTAssertTrue(rootedSaved.contains(#""lane_chat_id""#))
        XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: rootedSaved), "root-chat")
        XCTAssertFalse(AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: rootedSaved))

        let rows: [(name: String, payload: [String: Any], root: String?, allowsLatestFallback: Bool)] = [
            ("lane routes only", ["status": "failed", "errors": [["message": "m", "lane_chat_id": "lane-1"]]], nil, false),
            (
                "root beside lane routes",
                ["chat_id": "root-chat", "errors": [["message": "m", "lane_chat_id": "lane-1"]]],
                "root-chat",
                false
            ),
            ("top-level lane route", ["status": "failed", "lane_chat_id": "lane-1"], nil, false),
            ("root only", ["chat_id": "root-chat"], "root-chat", false),
            ("nested chat_id still refuses the root", ["chat_id": "root-chat", "results": [["chat_id": "lane-1"]]], nil, false),
            ("no identity", ["status": "failed", "errors": [["message": "m"]]], nil, true)
        ]
        for row in rows {
            let json = jsonString(row.payload)
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: row.payload), row.root, row.name)
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: json), row.root, row.name)
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: json),
                row.allowsLatestFallback,
                row.name
            )
        }
    }

    // MARK: - Invocation status vs Oracle outcome

    func testFailedInvocationKeepsOracleOutcomeBesideInvocationStatusThroughReload() throws {
        let pendingLane: [String: Any] = [
            "index": 0,
            "status": "pending",
            "operation_id": "99999999-0000-0000-0000-000000000000",
            "chat_id": "lane-pending",
            "pending": ["reason": "timed_out", "stream_state": "streaming"]
        ]
        let runningLane: [String: Any] = [
            "index": 1,
            "status": "running",
            "operation_id": "99999999-0000-0000-0000-000000000001",
            "chat_id": "lane-running"
        ]
        let completedLane: [String: Any] = ["index": 2, "status": "completed", "chat_id": "lane-done", "response": "done"]
        let cancelledLane: [String: Any] = [
            "index": 3,
            "ok": false,
            "status": "cancelled",
            "chat_id": "lane-cancelled",
            "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
        ]
        let wait: [String: Any] = ["result": "timed_out", "pending_operation_ids": ["99999999-0000-0000-0000-000000000000"]]
        let unfinished: [String: Any] = ["results": [pendingLane, runningLane], "wait": wait]
        let mixed: [String: Any] = ["results": [completedLane, pendingLane], "wait": wait]
        let cancelledOnly: [String: Any] = ["results": [cancelledLane], "note": "Cancelled."]
        let singlePending: [String: Any] = [
            "status": "pending",
            "operation_id": "99999999-0000-0000-0000-000000000009",
            "chat_id": "single-pending",
            "pending": ["reason": "timed_out", "stream_state": "streaming"]
        ]
        let failureKeys = ["errors", "error_count", "error_truncated", "lane_count", "failed_count", "nonterminal_count"]

        for toolName in ["ask_oracle", "oracle_send"] {
            let fixtures: [(name: String, raw: String, isError: Bool?, outcome: OracleToolResultInspection.InvocationFailureOutcome)] = try [
                ("error flag, all lanes unfinished", jsonString(unfinished), true, .nonterminal),
                ("error flag, completed and unfinished lanes", jsonString(mixed), true, .nonterminal),
                ("error flag, cancelled lanes only", jsonString(cancelledOnly), true, .cancelled),
                ("failed ACP, unfinished result", cursorACPResultJSON(toolName: toolName, status: "failed", rawOutput: singlePending), nil, .nonterminal),
                ("failed ACP, completed and unfinished lanes", cursorACPResultJSON(toolName: toolName, status: "failed", rawOutput: mixed), nil, .nonterminal),
                ("failed ACP, cancelled lanes only", cursorACPResultJSON(toolName: toolName, status: "failed", rawOutput: cancelledOnly), nil, .cancelled)
            ]
            for fixture in fixtures {
                let label = "\(toolName): \(fixture.name)"
                let item = AgentChatItem.toolResult(name: toolName, resultJSON: fixture.raw, isError: fixture.isError)
                XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: item), .failed, "\(label): the invocation failed")
                XCTAssertEqual(classification(of: item), .invocationFailureOnly(fixture.outcome), label)
                XCTAssertNil(OracleFailureCardPresentation(item: item), "\(label): live card is not a failed card")

                let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item), label)
                let object = try decodedObject(summary.resultJSON)
                XCTAssertEqual(object["status"] as? String, "failed", "\(label): the invocation status is kept as it was")
                XCTAssertEqual(object["oracle_outcome"] as? String, fixture.outcome.rawValue, "\(label): the Oracle outcome sits beside it")
                XCTAssertEqual(object["summary_only"] as? Bool, true, label)
                for key in failureKeys + ["results"] {
                    XCTAssertNil(object[key], "\(label): \(key)")
                }
                XCTAssertFalse((object["summary_text"] as? String)?.hasPrefix("Failed:") == true, label)

                let restored = AgentChatItemPersist(from: item).toItem()
                XCTAssertEqual(restored.toolResultJSON, summary.resultJSON, label)
                XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), .failed, "\(label): reload keeps the invocation status")
                XCTAssertEqual(classification(of: restored), .invocationFailureOnly(fixture.outcome), label)
                XCTAssertNil(OracleFailureCardPresentation(item: restored), "\(label): reloaded card is not a failed card")
                XCTAssertEqual(
                    AgentChatItemPersist(from: restored).toItem().toolResultJSON,
                    restored.toolResultJSON,
                    "\(label): fixed point"
                )
            }

            // The Oracle's own status word already states the outcome: nothing is added.
            let pendingItem = AgentChatItem.toolResult(name: toolName, resultJSON: jsonString(singlePending), isError: true)
            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: pendingItem), .pending, toolName)
            XCTAssertEqual(classification(of: pendingItem), .notFailed, toolName)
            let pendingObject = try decodedObject(XCTUnwrap(AgentChatItemPersist(from: pendingItem).toItem().toolResultJSON))
            XCTAssertEqual(pendingObject["status"] as? String, "pending", toolName)
            XCTAssertNil(pendingObject["oracle_outcome"], toolName)

            // A terminal Oracle outcome under a failed invocation stays a failure, live and reloaded.
            let completedItem = AgentChatItem.toolResult(
                name: toolName,
                resultJSON: jsonString(["results": [completedLane], "wait": ["result": "completed", "pending_operation_ids": []]]),
                isError: true
            )
            XCTAssertNotNil(OracleFailureCardPresentation(item: completedItem), toolName)
            let completedRestored = AgentChatItemPersist(from: completedItem).toItem()
            let completedObject = try decodedObject(XCTUnwrap(completedRestored.toolResultJSON))
            XCTAssertEqual(completedObject["status"] as? String, "failed", toolName)
            XCTAssertNil(completedObject["oracle_outcome"], toolName)
            XCTAssertNotNil(OracleFailureCardPresentation(item: completedRestored), toolName)
        }
    }

    func testFailurePreservesPresetIdentityRule() throws {
        let raw = jsonString([
            "status": "failed",
            "chat_id": "chat-9",
            "mode": "review",
            "model_source": "preset",
            "model_preset_id": "11111111-2222-3333-4444-555555555555",
            "model_preset_name": "OracleA",
            "model_selection": "explicit",
            "model_id": "provider-model-id",
            "model_name": "Provider Model",
            "ui_model_id": "ui-provider-model-id",
            "ui_model_name": "UI Provider Model",
            "error": ["code": "oracle_stream_failed", "message": "stream failed"]
        ])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
        let object = try decodedObject(summary.resultJSON)
        XCTAssertEqual(object["model_preset_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(object["model_preset_name"] as? String, "OracleA")
        XCTAssertEqual(object["model_selection"] as? String, "explicit")
        XCTAssertEqual(object["model_source"] as? String, "preset")
        XCTAssertNil(object["model_id"], "Preset-sourced results keep the preset identity only")
        XCTAssertNil(object["model_name"])
        XCTAssertFalse(summary.resultJSON.contains("ui-provider-model-id"))
        XCTAssertFalse(summary.resultJSON.contains("UI Provider Model"))
        XCTAssertEqual(object["chat_id"] as? String, "chat-9")
        XCTAssertEqual(object["summary_text"] as? String, "Failed: stream failed")
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertEqual(errors.first?["code"] as? String, "oracle_stream_failed")
        XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: summary.resultJSON), "chat-9")
    }

    func testDelegatedNoticesSurviveFailureSummary() throws {
        let notices: [[String: String]] = [[
            "kind": "delegated_question",
            "child_session_id": UUID().uuidString,
            "interaction_id": UUID().uuidString,
            "text": "Which branch should I use?"
        ]]
        let raw = jsonString([
            "status": "failed",
            "error": "Oracle provider rejected the request",
            AgentDelegatedQuestionNoticeWire.resultKey: notices
        ])
        let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: true)
        let once = AgentChatItemPersist(from: item).toItem()
        let object = try decodedObject(XCTUnwrap(once.toolResultJSON))
        XCTAssertEqual(object[AgentDelegatedQuestionNoticeWire.resultKey] as? [[String: String]], notices)
        let errors = try XCTUnwrap(object["errors"] as? [[String: Any]])
        XCTAssertEqual(errors.first?["message"] as? String, "Oracle provider rejected the request")
        XCTAssertEqual(object["summary_text"] as? String, "Failed: Oracle provider rejected the request")
        XCTAssertEqual(AgentChatItemPersist(from: once).toItem().toolResultJSON, once.toolResultJSON)
    }

    // MARK: - Redactor

    func testRedactorRemovesCredentialsURLSecretsAndControlCharacters() {
        let rows: [(input: String, expected: String)] = [
            ("Authorization: Bearer abc.def-123", "Authorization: <redacted>"),
            ("\"authorization\": \"Basic dXNlcjpwYXNz\"", "\"authorization\": \"<redacted>\""),
            ("retry with bearer 0123456789abcdef", "retry with bearer <redacted>"),
            ("Basic authentication failed", "Basic authentication failed"),
            ("key sk-ant-api03-abcdefghijklmnop", "key <redacted>"),
            ("key sk-proj-ABCDEFGHIJKLMNOPQRSTUV", "key <redacted>"),
            ("key " + syntheticCredential("AIza", "SyA1234567890abcdefghijklmnopqrstuv"), "key <redacted>"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789", "token <redacted>"),
            ("aws AKIAIOSFODNN7EXAMPLE", "aws <redacted>"),
            (
                "jwt " + syntheticCredential("eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "dozjgNryP4J3jVmNHl0w5N", separator: "."),
                "jwt <redacted>"
            ),
            ("password=hunter2 and api_key: xyz123", "password=<redacted> and api_key: <redacted>"),
            ("\"client_secret\": \"s3cr3t\"", "\"client_secret\": \"<redacted>\""),
            // From the first secret-named value that opens a quote, the rest of the text is
            // removed, even when the quote looks closed: whitespace, a leading space, escaped
            // quotes, JSON-escaped delimiters, single quotes, and later assignments.
            (#"password="correct horse battery staple" next"#, #"password="<redacted>""#),
            (#"password=" alpha beta""#, #"password="<redacted>""#),
            (#""password": "alpha \"beta\" gamma", "model": "gpt""#, #""password": "<redacted>""#),
            (#"{\"password\": \"alpha beta\", \"model\": \"m\"}"#, #"{\"password\": \"<redacted>\""#),
            (#"{\"token\": \"a\\\"b c\"}"#, #"{\"token\": \"<redacted>\""#),
            (#"'passphrase': 'it\'s a long secret'"#, #"'passphrase': '<redacted>'"#),
            (#"secret = 'x y'"#, #"secret = '<redacted>'"#),
            (#"authorization: "Bearer abc def""#, #"authorization: "<redacted>""#),
            (#"note "password": "x", then token: "y". done"#, #"note "password": "<redacted>""#),
            (#"password="" token="B""#, #"password="<redacted>""#),
            (#"password="a\\" token="B""#, #"password="<redacted>""#),
            // Unterminated, broken by a line break (LF or CRLF), closed only by an escaped
            // delimiter, mismatched, or apparently closed by a following assignment's quote.
            (#"password="unterminated value with spaces"#, #"password="<redacted>""#),
            ("password=\"alpha\nbravo", "password=\"<redacted>\""),
            ("token='alpha\nnext line", "token='<redacted>'"),
            ("password=\"alpha\nbravo\" next", "password=\"<redacted>\""),
            ("'secret': 'alpha\nbravo'\nmodel: m", "'secret': '<redacted>'"),
            (
                #"{\"token\": \"alpha"# + "\n" + #"bravo\", \"model\": \"m\"}"#,
                #"{\"token\": \"<redacted>\""#
            ),
            (#""password": "alpha \"x\""# + "\n" + #"bravo", "model": "gpt""#, #""password": "<redacted>""#),
            ("authorization=\"Bearer alpha\nbravo\" done", "authorization=\"<redacted>\""),
            ("password=\"alpha\r\nbravo\r\ncharlie\"", "password=\"<redacted>\""),
            ("password=\"A\ntoken=\"B\" x", "password=\"<redacted>\""),
            ("password=\"A\r\ntoken=\"B\" x", "password=\"<redacted>\""),
            ("secret: 'A\ntoken: 'B'", "secret: '<redacted>'"),
            ("password=\"A\ntoken=B", "password=\"<redacted>\""),
            (#"password="A token="B" x"#, #"password="<redacted>""#),
            (#"secret='A token='B' x"#, #"secret='<redacted>'"#),
            (#"password="A token": "B""#, #"password="<redacted>""#),
            (#"password="A "x" token="B""#, #"password="<redacted>""#),
            (#"password="A' token='B'"#, #"password="<redacted>""#),
            (#"password='A" token="B""#, #"password='<redacted>'"#),
            (#"password="a\" token="B""#, #"password="<redacted>""#),
            ("password=\"a\\\"\ntoken=\"B\"", "password=\"<redacted>\""),
            (#"{\"password\": \"A token=\"B\"}"#, #"{\"password\": \"<redacted>\""#),
            ("'password': 'A\"api_key\": \"B'\nC", "'password': '<redacted>'"),
            (#"token="YWJjZA==" next"#, #"token="<redacted>""#),
            // A backslash before a nested key cannot hide it (OracleA ORI-01), in any delimiter.
            ("secret='alpha \\password=\"bravo'\ncharlie", "secret='<redacted>'"),
            ("secret='alpha \\password=\"bravo' charlie", "secret='<redacted>'"),
            ("secret=\"alpha \\token='bravo\"\ncharlie", "secret=\"<redacted>\""),
            (#"{\"secret\": \"alpha \password='bravo\" charlie\"}"#, #"{\"secret\": \"<redacted>\""#),
            // An escaped single quote opens a value too.
            (#"password=\'alpha bravo\' next"#, #"password=\'<redacted>\'"#),
            // Every rule finds its ranges in the same text, so a URL never hides a key.
            ("see https://example.com/p?password=\\\"alpha\nbravo", #"see https://example.com/p?password=<redacted>"<redacted>"#),
            ("GET https://example.com/p?token: alpha next", "GET https://example.com/p?<redacted> <redacted> next"),
            (#"\"token\": 12345, next"#, #"\"token\": <redacted>, next"#),
            ("max_output_tokens=4096 exceeded", "max_output_tokens=4096 exceeded"),
            (
                "fetch https://user:pw@example.com/v1/chat?key=abc&flag&empty=#frag failed",
                "fetch https://<redacted>@example.com/v1/chat?key=<redacted>&<redacted>&empty=#<redacted> failed"
            ),
            // URL userinfo overlapping an assignment (OracleA R4-01): the overlapping ranges are
            // removed together, whichever comes first; a quote inside userinfo removes the rest.
            ("fetch https://alice:alpha;token=bravo@example.com/path failed", "fetch https://<redacted> failed"),
            ("fetch https://alice:token=bravo;alpha@example.com/path failed", "fetch https://<redacted>@example.com/path failed"),
            (#"fetch https://alice:alpha;token="bravo"@example.com/path failed"#, "fetch https://<redacted>"),
            ("fetch https://alice:alpha;token='bravo'@example.com/path failed", "fetch https://<redacted>"),
            (#"fetch https://alice:alpha;token=\"bravo\"@example.com/path failed"#, "fetch https://<redacted>"),
            ("https://token:abc@example.com/x", "https://<redacted>"),
            ("token=https://alice:alpha@example.com/path failed", "token=<redacted> failed"),
            (#"password="https://alice:alpha@example.com/path" failed"#, #"password="<redacted>""#),
            ("https://h/token=x?a=SECRET&b=2 done", "https://h/token=<redacted>&b=<redacted> done"),
            // Later passes (OracleB R5-01): a URL ended by a quote in its userinfo is read again
            // through the userinfo placeholder, and a removed `/` exposes userinfo to its `@`.
            ("https://o'brien:pw@h/?p=1 x", "https://<redacted>@h/?p=<redacted> x"),
            ("https://token=a/b;c@d", "https://<redacted>@d"),
            ("a\u{0007}b\u{200B}c\r\nd\te", "abc\nd\te")
        ]
        for row in rows {
            let redacted = OracleDiagnosticRedactor.redact(row.input)
            XCTAssertEqual(redacted, row.expected, row.input)
            XCTAssertEqual(OracleDiagnosticRedactor.redact(redacted), redacted, "Idempotent: \(row.input)")
        }
    }

    func testBoundedRedactedTextIsAFixedPointAtEveryCut() {
        let redacted = OracleDiagnosticRedactor.redact(
            String(repeating: "see https://example.com/p?token=secretvalue&b=2#frag and password=abc ", count: 6)
        )
        for maxBytes in stride(from: 8, through: 300, by: 1) {
            let bounded = OracleToolResultInspection.boundedRedactedText(redacted, maxBytes: maxBytes)
            XCTAssertLessThanOrEqual(bounded.text.utf8.count, maxBytes, "\(maxBytes)")
            XCTAssertEqual(OracleDiagnosticRedactor.redact(bounded.text), bounded.text, "\(maxBytes)")
            XCTAssertEqual(
                OracleToolResultInspection.boundedRedactedText(bounded.text, maxBytes: maxBytes).text,
                bounded.text,
                "Re-bounding is a fixed point at \(maxBytes)"
            )
        }
    }

    // MARK: - Helpers

    /// A synthetic credential-shaped fixture, joined from pieces at runtime so the repository
    /// secret scan never sees a complete credential literal. The runtime value is unchanged.
    private func syntheticCredential(_ pieces: String..., separator: String = "") -> String {
        pieces.joined(separator: separator)
    }

    private func laneEnvelopeJSON() -> String {
        let lanes: [[String: Any]] = [
            [
                "index": 5,
                "ok": false,
                "status": "failed",
                "operation_id": "55555555-0000-0000-0000-000000000005",
                "chat_id": "lane-5",
                "error": ["code": "oracle_provider_error", "message": "Lane five failed"]
            ],
            [
                "index": 0,
                "status": "completed",
                "operation_id": "55555555-0000-0000-0000-000000000000",
                "chat_id": "lane-0",
                "response": "done"
            ],
            [
                "index": 3,
                "ok": false,
                "status": "failed",
                "operation_id": "55555555-0000-0000-0000-000000000003",
                "errors": ["", "Lane three provider rejected the request"]
            ],
            [
                "index": 1,
                "ok": false,
                "status": "failed",
                "operation_id": "55555555-0000-0000-0000-000000000001",
                "chat_id": "lane-1",
                "error": ["code": "oracle_stream_failed", "message": "Lane one stream failed\nstack line"]
            ],
            [
                "index": 6,
                "ok": false,
                "status": "cancelled",
                "operation_id": "55555555-0000-0000-0000-000000000006",
                "chat_id": "lane-6",
                "error": ["code": "oracle_cancelled", "message": "The Oracle consultation was cancelled."]
            ],
            [
                "index": 2,
                "status": "pending",
                "operation_id": "55555555-0000-0000-0000-000000000002",
                "chat_id": "lane-2",
                "pending": ["reason": "timed_out", "stream_state": "streaming", "elapsed_seconds": 12]
            ],
            [
                "index": 4,
                "ok": false,
                "status": "delivery_failed",
                "operation_id": "55555555-0000-0000-0000-000000000004",
                "chat_id": "lane-4",
                "error": "Lane four delivery failed"
            ],
            [
                "index": 7,
                "ok": false,
                "status": "failed",
                "operation_id": "55555555-0000-0000-0000-000000000007",
                "chat_id": "lane-7",
                "error": ["code": "oracle_stream_failed", "message": "Lane seven failed"]
            ]
        ]
        return jsonString([
            "results": lanes,
            "wait": ["result": "completed_with_errors", "pending_operation_ids": []]
        ])
    }

    private func classification(of item: AgentChatItem) -> OracleToolResultInspection.Classification {
        OracleToolResultInspection.classify(
            resultJSON: item.toolResultJSON,
            text: item.text,
            toolIsError: item.toolIsError,
            statusWord: AgentTranscriptToolStatusSemantics.persistedStatusWord(
                from: AgentTranscriptToolNormalizer.status(for: item)
            )
        )
    }

    /// A live Cursor ACP tool result, normalized exactly as the provider stream delivers it.
    private func cursorACPResultJSON(
        toolName: String,
        status: String,
        rawOutput: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let events = CursorACPEventNormalizer.normalize([
            "sessionUpdate": "tool_call_update",
            "status": status,
            "toolCallId": "oracle-\(toolName)",
            "toolName": toolName,
            "kind": "other",
            "title": "Tool result",
            "rawInput": ["mode": "review"],
            "rawOutput": rawOutput
        ])
        guard case let .stream(result) = try XCTUnwrap(events.first, file: file, line: line) else {
            XCTFail("Expected a normalized Cursor ACP stream event", file: file, line: line)
            return ""
        }
        return try XCTUnwrap(result.toolResultJSON, file: file, line: line)
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func decodedObject(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }
}
