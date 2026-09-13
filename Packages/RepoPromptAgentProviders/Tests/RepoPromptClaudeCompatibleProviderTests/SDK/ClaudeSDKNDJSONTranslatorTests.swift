import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {
    func testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "usage": [
                    "input_tokens": 7,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 5,
                    "cache_creation_input_tokens": 2
                ],
                "content": [
                    ["type": "text", "text": "Hello"],
                    [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "mcp__RepoPromptCE__read_file",
                        "input": ["path": "Sources/App.swift"]
                    ]
                ]
            ]
        ])

        let results = translator.parseNDJSONLine(line)

        XCTAssertEqual(results.map(\.type), ["usage", "content", "tool_call"])
        guard results.count == 3 else { return }
        XCTAssertEqual(results[0].promptTokens, 7)
        XCTAssertEqual(results[0].completionTokens, 3)
        XCTAssertEqual(results[0].contextUsedTokens, 14)
        XCTAssertEqual(results[1].text, "Hello")
        XCTAssertEqual(results[2].toolName, "mcp__RepoPromptCE__read_file")
        let invocationID = try XCTUnwrap(results[2].toolInvocationID)
        XCTAssertEqual(try jsonObject(from: results[2].toolArgsJSON), ["path": "Sources/App.swift"])

        let resultLine = jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])
        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(resultLine).first)
        XCTAssertEqual(toolResult.type, "tool_result")
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
        XCTAssertEqual(toolResult.toolOutput, "contents")
        XCTAssertEqual(toolResult.toolInvocationID, invocationID)
        XCTAssertNil(toolResult.toolIsError, "Host-owned tool result errors are tracked by the host completion handler, not inferred here.")
    }

    func testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage() throws {
        var translator = ClaudeSDKNDJSONTranslator()

        let initResults = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "init",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(initResults.map(\.type), [ClaudeProviderStreamResult.lifecycleType])
        XCTAssertEqual(translator.cliSessionID, "claude-session-1")

        let usage = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_start",
                "message": [
                    "usage": [
                        "inputTokens": 4,
                        "outputTokens": 0,
                        "cacheReadInputTokens": 6
                    ]
                ]
            ]
        ]))
        XCTAssertEqual(usage.first?.type, "usage")
        XCTAssertEqual(usage.first?.contextUsedTokens, 10)

        let delta = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"]
            ]
        ]))
        XCTAssertEqual(delta.first?.type, "content")
        XCTAssertEqual(delta.first?.text, "partial")

        let stop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 4, "output_tokens": 9]
            ]
        ]))
        XCTAssertEqual(stop.map(\.type), ["usage", "message_stop"])
        XCTAssertEqual(stop.last?.stopReason, "end_turn")

        let cancelled = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": "claude-session-2",
            "is_error": true,
            "errors": ["Request was aborted by user"],
            "stop_reason": "cancelled",
            "usage": ["input_tokens": 11, "output_tokens": 0],
            "total_cost_usd": 0.12
        ]))
        XCTAssertEqual(cancelled.map(\.type), ["message_stop"])
        let cancelledStop = try XCTUnwrap(cancelled.first)
        XCTAssertEqual(cancelledStop.providerSessionID, "claude-session-2")
        XCTAssertEqual(cancelledStop.promptTokens, 11)
        XCTAssertEqual(cancelledStop.completionTokens, 0)
        XCTAssertEqual(cancelledStop.cost, 0.12)
        XCTAssertEqual(cancelledStop.stopReason, "cancelled")
        XCTAssertEqual(translator.cliSessionID, "claude-session-2")
    }

    // MARK: - Optional-preserving usage observation transport

    func testUsageObservationTablePreservesRawCountsIdentityAndSourcesWithoutZeroSubstitution() throws {
        struct Case {
            let name: String
            let line: [String: Any]
            let expectedTypes: [String]
            let expectedLegacy: (prompt: Int?, completion: Int?, context: Int?)
            let expectedMessageID: String?
            let expected: ClaudeProviderUsageObservation?
        }
        let mainStart: [String: Any] = [
            "type": "stream_event",
            "uuid": "env-start-main",
            "request_id": "req-start-main",
            "parent_tool_use_id": NSNull(),
            "event": [
                "type": "message_start",
                "message": [
                    "id": "msg_main",
                    "model": "claude-opus-4-8",
                    "usage": ["input_tokens": 10, "output_tokens": 0, "cache_read_input_tokens": 90, "cache_creation_input_tokens": 5]
                ]
            ]
        ]
        let cases: [Case] = [
            Case(
                name: "message_start preserves cache split, model, and distinct uuid/request_id/message.id",
                line: mainStart,
                expectedTypes: ["usage"],
                expectedLegacy: (10, 0, 105),
                expectedMessageID: "msg_main",
                expected: ClaudeProviderUsageObservation(
                    source: .messageStart,
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheReadInputTokens: 90,
                    cacheCreationInputTokens: 5,
                    model: "claude-opus-4-8",
                    envelopeID: "env-start-main",
                    requestID: "req-start-main"
                )
            ),
            Case(
                name: "missing counts stay nil while legacy normalizes to zero",
                line: [
                    "type": "stream_event",
                    "uuid": "env-delta-missing",
                    "request_id": "req-delta-missing",
                    "event": ["type": "message_delta", "usage": ["output_tokens": 4]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (0, 4, nil),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(
                    source: .messageDelta,
                    outputTokens: 4,
                    envelopeID: "env-delta-missing",
                    requestID: "req-delta-missing"
                )
            ),
            Case(
                name: "explicit zero counts are observed as zero, not missing",
                line: [
                    "type": "assistant",
                    "uuid": "env-zero",
                    "request_id": "req-zero",
                    "message": ["id": "msg_zero", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (0, 0, 0),
                expectedMessageID: "msg_zero",
                expected: ClaudeProviderUsageObservation(
                    source: .assistant,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadInputTokens: 0,
                    cacheCreationInputTokens: 0,
                    model: "claude-sonnet-4-6",
                    envelopeID: "env-zero",
                    requestID: "req-zero"
                )
            ),
            Case(
                name: "negative, fractional, bool and non-finite counts are unavailable; legacy still bridges bool true to 1",
                line: [
                    "type": "assistant",
                    "message": ["usage": ["input_tokens": -7, "output_tokens": 2.5, "cache_read_input_tokens": true, "cache_creation_input_tokens": "inf"]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (0, 0, 1),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(source: .assistant)
            ),
            Case(
                name: "overflowing count is unavailable rather than saturated",
                line: [
                    "type": "assistant",
                    "message": ["usage": ["input_tokens": 3, "output_tokens": "99999999999999999999999"]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (3, 0, 3),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(source: .assistant, inputTokens: 3)
            ),
            Case(
                name: "identified sidechain assistant carries parent tool id and its own message id",
                line: [
                    "type": "assistant",
                    "uuid": "env-side",
                    "request_id": "req-side",
                    "parent_tool_use_id": "toolu_parent",
                    "message": ["id": "msg_side", "model": "claude-haiku-4-5", "usage": ["input_tokens": 1, "output_tokens": 2]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (1, 2, 1),
                expectedMessageID: "msg_side",
                expected: ClaudeProviderUsageObservation(
                    source: .assistant,
                    inputTokens: 1,
                    outputTokens: 2,
                    model: "claude-haiku-4-5",
                    envelopeID: "env-side",
                    requestID: "req-side",
                    parentToolUseID: "toolu_parent"
                )
            ),
            Case(
                name: "result attaches subtype, error evidence and envelope id; legacy context stays nil",
                line: [
                    "type": "result",
                    "uuid": "env-result",
                    "request_id": "req-result",
                    "subtype": " Success ",
                    "is_error": false,
                    "session_id": "s-obs",
                    "usage": ["input_tokens": 11, "output_tokens": 6, "cache_read_input_tokens": 40],
                    "total_cost_usd": 0.42
                ],
                expectedTypes: ["message_stop"],
                expectedLegacy: (11, 6, nil),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(
                    source: .result,
                    inputTokens: 11,
                    outputTokens: 6,
                    cacheReadInputTokens: 40,
                    envelopeID: "env-result",
                    requestID: "req-result",
                    resultSubtype: "success",
                    resultIsError: false
                )
            ),
            Case(
                name: "cost-only error result still carries evidence with nil counts",
                line: [
                    "type": "result",
                    "uuid": "env-result-err",
                    "subtype": "error_max_turns",
                    "is_error": true,
                    "total_cost_usd": 0.05
                ],
                expectedTypes: ["message_stop"],
                expectedLegacy: (nil, nil, nil),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(
                    source: .result,
                    envelopeID: "env-result-err",
                    resultSubtype: "error_max_turns",
                    resultIsError: true
                )
            ),
            Case(
                name: "near-integer and negative-underflow strings are unavailable, never rounded; plain digit strings count",
                line: [
                    "type": "assistant",
                    "message": ["usage": ["input_tokens": "1.0000000000000001", "output_tokens": "-1e-400", "cache_read_input_tokens": "1.0", "cache_creation_input_tokens": "12"]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (1, 0, 14),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(source: .assistant, cacheCreationInputTokens: 12)
            ),
            Case(
                name: "ordinary numeric zero and nonzero counts are observed exactly",
                line: [
                    "type": "assistant",
                    "message": ["usage": ["input_tokens": 0, "output_tokens": 42, "cache_read_input_tokens": "0", "cache_creation_input_tokens": "7"]]
                ],
                expectedTypes: ["usage"],
                expectedLegacy: (0, 42, 7),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(source: .assistant, inputTokens: 0, outputTokens: 42, cacheReadInputTokens: 0, cacheCreationInputTokens: 7)
            ),
            Case(
                name: "whitespace-only result subtype is not reported",
                line: ["type": "result", "subtype": "   ", "usage": ["input_tokens": 1]],
                expectedTypes: ["message_stop"],
                expectedLegacy: (1, 0, nil),
                expectedMessageID: nil,
                expected: ClaudeProviderUsageObservation(source: .result, inputTokens: 1)
            ),
            Case(
                name: "usage dictionary without any usage field emits nothing",
                line: ["type": "assistant", "message": ["usage": ["service_tier": "standard"], "content": []]],
                expectedTypes: [],
                expectedLegacy: (nil, nil, nil),
                expectedMessageID: nil,
                expected: nil
            )
        ]

        for testCase in cases {
            var translator = ClaudeSDKNDJSONTranslator()
            let results = translator.parseNDJSONLine(jsonLine(testCase.line))
            XCTAssertEqual(results.map(\.type), testCase.expectedTypes, testCase.name)
            guard let carrier = results.first(where: { $0.type == "usage" || $0.type == "message_stop" }) else {
                XCTAssertNil(testCase.expected, testCase.name)
                continue
            }
            XCTAssertEqual(carrier.promptTokens, testCase.expectedLegacy.prompt, "\(testCase.name): legacy prompt")
            XCTAssertEqual(carrier.completionTokens, testCase.expectedLegacy.completion, "\(testCase.name): legacy completion")
            XCTAssertEqual(carrier.contextUsedTokens, testCase.expectedLegacy.context, "\(testCase.name): legacy context")
            XCTAssertEqual(carrier.contentMessageID, testCase.expectedMessageID, "\(testCase.name): message.id rides on the carrier")
            XCTAssertEqual(carrier.usageObservation, testCase.expected, testCase.name)
            // Non-carrier results (content/tool) never gain a message id from the translator.
            for other in results where other.type != "usage" && other.type != "message_stop" {
                XCTAssertNil(other.contentMessageID, "\(testCase.name): legacy content identity unchanged")
                XCTAssertNil(other.usageObservation, testCase.name)
            }
        }

        // Raw cost stays on the existing field and is not duplicated into the observation.
        var translator = ClaudeSDKNDJSONTranslator()
        let costResult = try XCTUnwrap(translator.parseNDJSONLine(jsonLine(cases[6].line)).first)
        XCTAssertEqual(costResult.cost, 0.42)
        XCTAssertNil(costResult.contextUsedTokens)

        // The DTO stream path (`parseStreamPayload`) rejects booleans and fractions the same way.
        var payloadTranslator = ClaudeSDKNDJSONTranslator()
        let payloadResults = payloadTranslator.parseStreamPayload([
            "type": .string("assistant"),
            "message": .object(["usage": .object([
                "input_tokens": .bool(true),
                "output_tokens": .integer(3),
                "cache_read_input_tokens": .double(2.5),
                "cache_creation_input_tokens": .double(4)
            ])])
        ])
        let payloadCarrier = try XCTUnwrap(payloadResults.first)
        XCTAssertEqual(payloadCarrier.type, "usage")
        // Legacy stays untouched on this path too: `foundationObject()` yields a native Swift `Bool`,
        // which `numberToInt` does not bridge (unlike the NDJSON path's CFBoolean NSNumber → 1),
        // so the legacy projection normalizes the missing input to 0. The observation rejects the
        // boolean either way.
        XCTAssertEqual(payloadCarrier.promptTokens, 0, "legacy bool handling unchanged on the payload path")
        XCTAssertEqual(payloadCarrier.completionTokens, 3)
        XCTAssertEqual(
            payloadCarrier.usageObservation,
            ClaudeProviderUsageObservation(source: .assistant, outputTokens: 3, cacheCreationInputTokens: 4)
        )
    }

    func testMessageDeltaObservationInheritsLaneMessageIDAndUnidentifiedSidechainStaysUnassigned() {
        var translator = ClaudeSDKNDJSONTranslator()
        func line(_ eventType: String, parent: Any? = nil, message: [String: Any]? = nil, usage: [String: Any]? = nil, uuid: String? = nil, requestID: String? = nil) -> Data {
            var event: [String: Any] = ["type": eventType]
            if let message { event["message"] = message }
            if let usage { event["usage"] = usage }
            var envelope: [String: Any] = ["type": "stream_event", "event": event]
            if let parent { envelope["parent_tool_use_id"] = parent }
            if let uuid { envelope["uuid"] = uuid }
            if let requestID { envelope["request_id"] = requestID }
            return jsonLine(envelope)
        }
        func delta(parent: Any? = nil, uuid: String? = nil, requestID: String? = nil) -> ClaudeProviderStreamResult? {
            translator.parseNDJSONLine(line("message_delta", parent: parent, usage: ["output_tokens": 1], uuid: uuid, requestID: requestID)).first
        }

        // Main lane opens with msg_main; a main delta inherits it while its own uuid and
        // request_id stay distinct from the inherited message id.
        _ = translator.parseNDJSONLine(line("message_start", message: ["id": "msg_main", "usage": ["input_tokens": 5]], uuid: "u-start", requestID: "req-start"))
        let mainDelta = delta(uuid: "u-d1", requestID: "req-d1")
        XCTAssertEqual(mainDelta?.contentMessageID, "msg_main")
        XCTAssertEqual(mainDelta?.usageObservation?.envelopeID, "u-d1")
        XCTAssertEqual(mainDelta?.usageObservation?.requestID, "req-d1")
        XCTAssertNil(mainDelta?.usageObservation?.parentToolUseID)

        // A sidechain delta whose lane never opened must not borrow the main message id.
        let unopenedSidechain = delta(parent: "toolu_unopened", uuid: "u-side", requestID: "req-side")
        XCTAssertEqual(unopenedSidechain?.usageObservation?.parentToolUseID, "toolu_unopened")
        XCTAssertEqual(unopenedSidechain?.usageObservation?.requestID, "req-side")
        XCTAssertNil(unopenedSidechain?.contentMessageID)

        // A sidechain delta with an unidentifiable (non-string, non-null) parent is unassigned
        // and does not open or read the main lane.
        let ambiguous = delta(parent: ["nested": "object"])
        XCTAssertNil(ambiguous?.usageObservation?.parentToolUseID)
        XCTAssertNil(ambiguous?.contentMessageID)
        XCTAssertEqual(delta()?.contentMessageID, "msg_main", "main lane unaffected by ambiguous sidechain")

        // Blank/whitespace non-null parents are unassigned: a blank-parent delta never inherits
        // the main message, and blank-parent start/stop can neither overwrite nor close the main lane.
        for blank in ["", "   ", "\n\t"] {
            let blankDelta = delta(parent: blank)
            XCTAssertNil(blankDelta?.usageObservation?.parentToolUseID, "blank parent \(blank.debugDescription)")
            XCTAssertNil(blankDelta?.contentMessageID, "blank parent \(blank.debugDescription) must not inherit msg_main")
            _ = translator.parseNDJSONLine(line("message_start", parent: blank, message: ["id": "msg_blank", "usage": ["input_tokens": 1]]))
            XCTAssertEqual(delta()?.contentMessageID, "msg_main", "blank-parent start must not overwrite the main lane")
            XCTAssertNil(delta(parent: blank)?.contentMessageID, "blank-parent start opens no lane")
            _ = translator.parseNDJSONLine(line("message_stop", parent: blank))
            XCTAssertEqual(delta()?.contentMessageID, "msg_main", "blank-parent stop must not close the main lane")
        }
        // Explicit JSON null parent keeps main-lane semantics.
        XCTAssertEqual(delta(parent: NSNull())?.contentMessageID, "msg_main")
        XCTAssertNil(delta(parent: NSNull())?.usageObservation?.parentToolUseID)

        // An identified sidechain lane opens independently and only its own deltas inherit it.
        _ = translator.parseNDJSONLine(line("message_start", parent: "toolu_side", message: ["id": "msg_side", "usage": ["input_tokens": 2]]))
        XCTAssertEqual(delta(parent: "toolu_side")?.contentMessageID, "msg_side")
        XCTAssertEqual(delta()?.contentMessageID, "msg_main")
        XCTAssertNil(delta(parent: "toolu_other")?.contentMessageID)

        // message_stop closes only its lane; a start without an id closes the lane too.
        _ = translator.parseNDJSONLine(line("message_stop", parent: "toolu_side"))
        XCTAssertNil(delta(parent: "toolu_side")?.contentMessageID)
        XCTAssertEqual(delta()?.contentMessageID, "msg_main")
        _ = translator.parseNDJSONLine(line("message_start", message: ["usage": ["input_tokens": 1]]))
        XCTAssertNil(delta()?.contentMessageID)

        // A new stream init and an explicit reset both clear open lanes.
        _ = translator.parseNDJSONLine(line("message_start", message: ["id": "msg_next", "usage": ["input_tokens": 1]]))
        XCTAssertEqual(delta()?.contentMessageID, "msg_next")
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "session_id": "s-new"]))
        XCTAssertNil(delta()?.contentMessageID)
        _ = translator.parseNDJSONLine(line("message_start", message: ["id": "msg_reset", "usage": ["input_tokens": 1]]))
        XCTAssertEqual(delta()?.contentMessageID, "msg_reset")
        translator.resetMainModelTracking()
        XCTAssertNil(delta()?.contentMessageID)

        // Legacy content deltas never gain a message id from lane tracking.
        _ = translator.parseNDJSONLine(line("message_start", message: ["id": "msg_content", "usage": ["input_tokens": 1]]))
        let content = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "hi"]]
        ])).first
        XCTAssertEqual(content?.type, "content")
        XCTAssertNil(content?.contentMessageID)
        XCTAssertNil(content?.usageObservation)
    }

    // MARK: - Main-model attribution for modelUsage context windows

    func testModelUsageMainModelAttributionSelectsInitTrackedWindowOverBackgroundHaiku() {
        // Init anchors the exact modelUsage key; the background Haiku entry is
        // unreachable by strategy regardless of dictionary iteration order.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "system", "subtype": "init",
            "session_id": "s1", "model": "claude-opus-4-8[1m]"
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ])
        XCTAssertEqual(window, 1_000_000)
    }

    func testAssistantFallbackNormalizedMatchResolvesMainWindow() {
        // With tracking unset, a top-level assistant base id anchors
        // tracking and resolves via the normalized-equality (bracket-stripped) tier.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "hi"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000)
    }

    func testInitTrackedExactIDIsNotOverwrittenByLaterAssistantModel() {
        // Assistant sets tracking only when unset, so an init-tracked exact
        // id wins over a later assistant model. If the assistant had retargeted tracking to the
        // sonnet id, the sonnet 200K entry would have been selected instead.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-5", "content": [["type": "text", "text": "hi"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-sonnet-4-5": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000, "init-tracked exact id must win; assistant model must not retarget tracking")
    }

    func testStickyMainWindowSurvivesBackgroundOnlyEvent() {
        // A matched main window stays sticky through a later Haiku-only event.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 1_000_000)
        let sticky = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(sticky, 1_000_000, "background-only event must not downgrade the sticky main window")
    }

    func testNoPriorMatchFallsBackToDeterministicMaxAcrossEntries() {
        // With no tracking anchor and no prior match, selection is the
        // deterministic MAX across entries, never a blind first-positive.
        var translator = ClaudeSDKNDJSONTranslator()
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-unknown-background": ["contextWindow": 300_000]
        ])
        XCTAssertEqual(window, 300_000)
    }

    func testHaikuAsMainModelResolvesTwoHundredKViaExactMatch() {
        // Haiku-as-main resolves via the general exact-match path, no special case.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 200_000)
    }

    func testSidechainAssistantEventDoesNotRetargetMainModelTracking() {
        // A sidechain/subagent assistant event (non-null parent_tool_use_id) must not
        // anchor tracking; the following top-level assistant anchors the real main model.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_subagent_1",
            "message": ["model": "claude-haiku-4-5-20251001", "content": [["type": "text", "text": "sub"]]]
        ]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "main"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000, "sidechain assistant must not retarget tracking to the subagent model")
    }

    func testFreshStreamInitReanchorsFromCleanStateAndReinitOverwritesTracking() {
        // A fresh translator whose init model is Haiku resolves 200K even when a larger
        // background window is present (no prior-stream leak); a subsequent new init re-anchors.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000, "init Haiku must anchor 200K even when a larger background window is present")
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000, "a new init must re-anchor tracking to the new main model")
    }

    func testResetMainModelTrackingReanchorsAfterLiveModelSwitchAndPreservesSessionAndToolMaps() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "system", "subtype": "init", "session_id": "s-live", "model": "claude-opus-4-8[1m]"
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 1_000_000)
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": "toolu_reset_survives",
                    "name": "mcp__RepoPromptCE__read_file",
                    "input": ["path": "README.md"]
                ]]
            ]
        ]))

        let sessionIDBeforeReset = translator.cliSessionID
        translator.resetMainModelTracking()
        XCTAssertEqual(translator.cliSessionID, sessionIDBeforeReset)
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-6", "content": [["type": "text", "text": "main"]]]
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 200_000)

        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_reset_survives",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])).first)
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
    }

    func testPostResetSidechainAssistantDoesNotAnchorBeforeNextTopLevelAssistant() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000)

        translator.resetMainModelTracking()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_subagent_2",
            "message": ["model": "claude-haiku-4-5-20251001", "content": [["type": "text", "text": "sub"]]]
        ]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-6", "content": [["type": "text", "text": "main"]]]
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 200_000)
    }

    func testPostResetResultBeforeAnchorUsesDeterministicMaxNotStaleStickyWindow() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000)

        translator.resetMainModelTracking()
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 300_000)
    }

    func testPrefixBoundaryRejectsAdjacentNumericPrefixFalseMatch() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-1"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-10": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 300_000)
    }

    func testPrefixBoundaryAcceptsDatedKeyWithDashDelimiter() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testPrefixBoundaryAcceptsTrackedDatedModelAgainstBaseKey() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testPrefixBoundaryCandidateTierUsesDeterministicMaxWithoutGlobalFallthrough() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 300_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 300_000)
    }

    func testAgreeingPrefixCandidatesBeatUnrelatedLargerGlobalEntry() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testNormalizedEqualityTierPrecedesLargerBoundaryPrefixCandidate() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[tracked]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[200k]": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-opus-4-8-20260101": ["contextWindow": 2_000_000]
        ]), 1_000_000)
    }

    func testAmbiguousCandidateTierResolutionUpdatesStickyForBackgroundFollowUp() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 200_000]
        ]), 200_000)
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    private func modelContextWindow(
        from translator: inout ClaudeSDKNDJSONTranslator,
        modelUsage: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        let results = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "session_id": "s-result",
            "modelUsage": modelUsage
        ], file: file, line: line))
        return results.first(where: { $0.type == "message_stop" })?.modelContextWindow
    }

    private func jsonObject(from jsonString: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let value = try XCTUnwrap(jsonString, file: file, line: line)
        let data = Data(value.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String], file: file, line: line)
    }

    private func jsonLine(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            XCTFail("Invalid JSON fixture", file: file, line: line)
            return Data()
        }
        return data
    }
}
