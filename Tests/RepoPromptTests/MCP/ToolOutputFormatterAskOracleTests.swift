import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class ToolOutputFormatterAskOracleTests: XCTestCase {
    func testPendingResultRoundTripsCanonicalProgressAndNoResponse() throws {
        let value: Value = .object([
            "operation_id": .string("operation-pending"),
            "status": .string("pending"),
            "ok": .bool(true),
            "chat_id": .string("oracle-chat"),
            "mode": .string("chat"),
            "pending": .object([
                "reason": .string("polled"),
                "stream_state": .string("queued"),
                "elapsed_seconds": .int(4),
                "progress": .object([
                    "queue_position": .int(0)
                ])
            ]),
            "wait_policy": .object([
                "mode": .string("poll"),
                "timeout_seconds": .int(0)
            ]),
            "resume": .object([
                "op": .string("wait"),
                "operation_ids": .array([.string("operation-pending")])
            ])
        ])

        let roundTripped = try roundTrippedValue(value)

        XCTAssertEqual(roundTripped, value)
        XCTAssertNil(roundTripped.objectValue?["response"])
        XCTAssertEqual(
            roundTripped.objectValue?["pending"]?.objectValue?["progress"]?.objectValue?["queue_position"]?.intValue,
            0
        )
    }

    func testMixedBatchRoundTripsStableIndexesAndTerminalReplyBytes() throws {
        let response = "First line\n`code fence marker`\nLast line"
        let value: Value = .object([
            "results": .array([
                .object([
                    "index": .int(2),
                    "operation_id": .string("operation-completed"),
                    "status": .string("completed"),
                    "ok": .bool(true),
                    "chat_id": .string("completed-chat"),
                    "mode": .string("chat"),
                    "model_selection": .string("explicit"),
                    "model_preset_id": .string("preset-b"),
                    "model_preset_name": .string("OracleB"),
                    "response": .string(response)
                ]),
                .object([
                    "index": .int(5),
                    "operation_id": .string("operation-pending"),
                    "status": .string("pending"),
                    "pending": .object([
                        "reason": .string("timed_out"),
                        "stream_state": .string("streaming"),
                        "progress": .object([
                            "output_chars": .int(17),
                            "last_activity_seconds_ago": .int(1)
                        ])
                    ])
                ]),
                .object([
                    "index": .int(8),
                    "operation_id": .string("operation-failed"),
                    "status": .string("failed"),
                    "ok": .bool(false),
                    "consultation_started": .bool(false),
                    "error": .object([
                        "code": .string("not_started_owner_inactive"),
                        "message": .string("owner inactive")
                    ])
                ])
            ]),
            "wait": .object([
                "result": .string("timed_out"),
                "pending_operation_ids": .array([.string("operation-pending")])
            ]),
            "wait_policy": .object([
                "mode": .string("automatic"),
                "timeout_seconds": .int(600),
                "parent_family": .string("Codex")
            ]),
            "resume": .object([
                "op": .string("wait"),
                "operation_ids": .array([.string("operation-pending")])
            ])
        ])

        let roundTripped = try roundTrippedValue(value)
        let results = try XCTUnwrap(roundTripped.objectValue?["results"]?.arrayValue)

        XCTAssertEqual(roundTripped, value)
        XCTAssertEqual(results.compactMap { $0.objectValue?["index"]?.intValue }, [2, 5, 8])
        XCTAssertEqual(results.first?.objectValue?["response"]?.stringValue, response)
    }

    func testEmptyWaitAndCancelErrorEnvelopesRoundTripLosslessly() throws {
        let emptyWait: Value = .object([
            "results": .array([]),
            "wait": .object([
                "result": .string("completed"),
                "pending_operation_ids": .array([])
            ]),
            "wait_policy": .object([
                "mode": .string("poll"),
                "timeout_seconds": .int(0)
            ])
        ])
        let cancelAndError: Value = .object([
            "results": .array([
                .object([
                    "index": .int(3),
                    "operation_id": .string("operation-cancelled"),
                    "cancel": .string("requested")
                ]),
                .object([
                    "index": .int(9),
                    "operation_id": .string("operation-unknown"),
                    "status": .string("unknown"),
                    "error": .object([
                        "code": .string("oracle_operation_not_found"),
                        "message": .string("operation not found")
                    ])
                ])
            ]),
            "note": .string("Cancellation requested."),
            "resume": .object([
                "op": .string("wait"),
                "operation_ids": .array([.string("operation-cancelled")])
            ])
        ])

        XCTAssertEqual(try roundTrippedValue(emptyWait), emptyWait)
        XCTAssertEqual(try roundTrippedValue(cancelAndError), cancelAndError)
    }

    func testLegacyTerminalResultKeepsMarkdownPresentation() throws {
        let response = "Legacy reply\nwith `backticks`"
        let value: Value = .object([
            "chat_id": .string("legacy-chat"),
            "mode": .string("chat"),
            "model_preset_id": .string("preset-b"),
            "model_preset_name": .string("OracleB"),
            "response": .string(response),
            "ok": .bool(true)
        ])

        let blocks = ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_oracle",
            args: [:],
            result: value,
            emitResources: false
        )
        let text = try onlyText(blocks)

        XCTAssertTrue(text.hasPrefix("## Ask Oracle ✅"), text)
        XCTAssertTrue(text.contains("- **Chat**: `legacy-chat` | **Mode**: chat"), text)
        XCTAssertTrue(text.contains("### Response\n\(response)"), text)
        XCTAssertEqual(text.components(separatedBy: response).count - 1, 1)
    }

    private func roundTrippedValue(_ value: Value) throws -> Value {
        let blocks = ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_oracle",
            args: [:],
            result: value,
            emitResources: false
        )
        let text = try onlyText(blocks)
        XCTAssertEqual(text, ToolOutputFormatter.rawJSONString(value))
        return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }

    private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = block else {
            XCTFail("Expected one text content block")
            return ""
        }
        return text
    }
}
