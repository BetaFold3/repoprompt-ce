import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Step 4d3b (inactive, default-off): the producer-owned classifier of Claude live output and the
/// native controller's monotonic qualification latch. Fixtures mirror the allowlisted O19 live shapes
/// recorded in the Phase 4d3 evidence notes (one dispatched turn: replayed user message, one
/// single-text assistant envelope, success result). Fixture-backed only: this is not qualification
/// of Claude's live format.
final class ClaudeLiveTranscriptQualificationTests: XCTestCase {
    private typealias State = ClaudeLiveTranscriptProducerState

    private let session = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let prompt = "Reply with exactly: ALPHA-7"
    private let reply = "ALPHA-7"

    // MARK: Payload fixtures

    private func systemInit() -> [String: Any] {
        ["type": "system", "subtype": "init", "session_id": session, "claude_code_version": "2.1.268", "tools": [], "uuid": UUID().uuidString]
    }

    private func lifecycle(_ state: String) -> [String: Any] {
        ["type": "command_lifecycle", "command_uuid": UUID().uuidString, "session_id": session, "state": state, "uuid": UUID().uuidString]
    }

    private func rateLimit(status: String = "allowed") -> [String: Any] {
        [
            "type": "rate_limit_event",
            "session_id": session,
            "uuid": UUID().uuidString,
            "rate_limit_info": ["status": status, "rateLimitType": "five_hour", "resetsAt": 1_800_000_000, "isUsingOverage": false]
        ]
    }

    private func replay(_ outbound: UUID, text: String? = nil) -> [String: Any] {
        [
            "type": "user",
            "isReplay": true,
            "message": ["role": "user", "content": text ?? prompt],
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "timestamp": "2026-10-23T00:00:00.000Z",
            "uuid": outbound.uuidString.lowercased()
        ]
    }

    /// `attributedTo`: the consumed-user attribution the current app's (no-replay) output carries.
    private func assistant(
        entry: String = "a1",
        content: [[String: Any]]? = nil,
        text: String? = nil,
        attributedTo outbound: UUID? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": "msg_\(entry)",
                "type": "message",
                "role": "assistant",
                "model": "claude-sonnet-5",
                "content": content ?? [["type": "text", "text": text ?? reply]],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 4, "output_tokens": 3]
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
            "session_id": session,
            "request_id": "req_\(entry)",
            "uuid": entry
        ]
        if let outbound { attribute(&payload, to: outbound) }
        return payload
    }

    private func attribute(_ payload: inout [String: Any], to outbound: UUID) {
        payload["user_message_uuid"] = outbound.uuidString.lowercased()
        payload["user_message_uuids"] = [outbound.uuidString.lowercased()]
    }

    /// `attributedTo`: the current app's success result (attribution plus its terminal markers).
    private func result(
        _ text: String? = nil,
        subtype: String = "success",
        isError: Bool = false,
        attributedTo outbound: UUID? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "result", "subtype": subtype, "is_error": isError, "result": text ?? reply, "session_id": session,
            "uuid": UUID().uuidString, "num_turns": 1, "permission_denials": [],
            "usage": ["input_tokens": 4, "output_tokens": 3]
        ]
        if let outbound {
            attribute(&payload, to: outbound)
            payload["terminal_reason"] = "completed"
            payload["stop_reason"] = "end_turn"
            payload["safety_stops"] = 0
        }
        return payload
    }

    private func data(_ payload: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: payload)
    }

    private func content(_ text: String) -> AIStreamResult {
        AIStreamResult(type: "content", text: text)
    }

    private func eligibleState(token: UUID = UUID()) -> State {
        var state = State(launchToken: token)
        state.markEligible()
        return state
    }

    /// Drives the benign prefix of one O19 turn up to the replay.
    private func replayed(_ state: inout State, outbound: UUID = UUID()) {
        for payload in [systemInit(), lifecycle("queued"), rateLimit()] {
            XCTAssertEqual(state.classify(envelope: data(payload), translated: [], turnInFlight: false), .benign)
        }
        state.noteOutbound(uuid: outbound, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(lifecycle("started")), translated: [], turnInFlight: true), .benign)
        XCTAssertEqual(state.classify(envelope: data(replay(outbound)), translated: [], turnInFlight: true), .benign)
    }

    private func disqualification(_ outcome: ClaudeLiveTranscriptOutcome) -> ClaudeLiveTranscriptDisqualification? {
        guard case let .standalone(evidence) = outcome, case let .disqualified(reason) = evidence.kind else { return nil }
        return reason
    }

    // MARK: Pure classifier

    /// The O19 turn attaches exactly once to the envelope's one `content` result, with the history
    /// reader's deterministic ID and complete-envelope proof; the success result agrees; a second
    /// dispatched turn qualifies the same way.
    func testO19TurnAttachesOnceWithTheReadersIdentityAndResultAgrees() throws {
        let token = UUID()
        var state = eligibleState(token: token)
        replayed(&state)
        let usage = AIStreamResult(type: "usage", text: nil)
        let outcome = state.classify(envelope: data(assistant()), translated: [usage, content(reply)], turnInFlight: true)
        guard case let .attach(index, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("expected an attachment, got \(outcome)")
        }
        XCTAssertEqual(index, 1, "the content result, never the usage companion")
        XCTAssertEqual(evidence.producerLaunchToken, token)
        let row = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: session, nativeEntryID: "a1", text: reply))
        XCTAssertEqual(complete.localItemID, row.localItemID)
        XCTAssertEqual(complete.envelopeDigest, row.envelopeDigest)
        XCTAssertEqual(complete.nativeSessionID, session)
        XCTAssertEqual(complete.nativeEntryID, "a1")
        XCTAssertEqual(complete.text, reply)
        XCTAssertEqual(complete.ledgerItem.key, complete.ledgerKey)
        XCTAssertEqual(complete.ledgerItem.envelopeDigest, row.envelopeDigest)
        XCTAssertEqual(complete.ledgerItem.localItemID, row.localItemID)
        let item = try XCTUnwrap(complete.canonicalItem)
        XCTAssertEqual(item.id, complete.localItemID)
        XCTAssertEqual(item.kind, .assistant)
        XCTAssertEqual(item.text, reply)
        XCTAssertFalse(item.isStreaming)

        let agreement = state.classify(envelope: data(result()), translated: [], turnInFlight: true)
        XCTAssertEqual(agreement, .standalone(.init(producerLaunchToken: token, kind: .resultAgreement(localItemID: complete.localItemID, text: reply))))
        XCTAssertEqual(state.classify(envelope: data(lifecycle("completed")), translated: [], turnInFlight: false), .benign)

        // A later dispatched turn of the same producer.
        let next = UUID()
        state.noteOutbound(uuid: next, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(replay(next)), translated: [], turnInFlight: true), .benign)
        guard case .attach = state.classify(envelope: data(assistant(entry: "a2")), translated: [content(reply)], turnInFlight: true) else {
            return XCTFail("the second turn qualifies")
        }
        XCTAssertNil(state.disqualification)
    }

    /// Every unrecognized, unsupported or contradicting payload disqualifies, including payloads whose
    /// translated results are empty or would be suppressed.
    func testUnsupportedShapesDisqualifyWithTheirReason() {
        typealias Case = (String, ClaudeLiveTranscriptDisqualification, (inout State) -> ClaudeLiveTranscriptOutcome)
        let cases: [Case] = [
            ("unknown type, empty translation", .unsupportedPayload, { state in
                state.classify(envelope: self.data(["type": "stream_event", "session_id": self.session, "event": [:]]), translated: [], turnInFlight: true)
            }),
            ("suppressed system task", .unsupportedPayload, { state in
                state.classify(
                    envelope: self.data(["type": "system", "subtype": "task_started", "session_id": self.session, "task_id": "t1"]),
                    translated: [AIStreamResult(type: "system", text: "Task started: t1")],
                    turnInFlight: true
                )
            }),
            ("compact boundary", .unsupportedPayload, { state in
                state.classify(envelope: self.data(["type": "system", "subtype": "compact_boundary", "session_id": self.session]), translated: [], turnInFlight: true)
            }),
            ("lifecycle state", .unsupportedLifecycle, { state in
                state.classify(envelope: self.data(self.lifecycle("failed")), translated: [], turnInFlight: true)
            }),
            ("lifecycle extra key", .unsupportedLifecycle, { state in
                var payload = self.lifecycle("queued")
                payload["error"] = "x"
                return state.classify(envelope: self.data(payload), translated: [], turnInFlight: true)
            }),
            ("rate limit status", .unsupportedRateLimit, { state in
                state.classify(envelope: self.data(self.rateLimit(status: "rejected")), translated: [], turnInFlight: true)
            }),
            ("semantic marker", .semanticMarker, { state in
                var payload = self.assistant()
                payload["supersedes"] = "a0"
                return state.classify(envelope: self.data(payload), translated: [self.content(self.reply)], turnInFlight: true)
            }),
            ("session mismatch", .sessionMismatch, { state in
                var payload = self.lifecycle("completed")
                payload["session_id"] = "other"
                return state.classify(envelope: self.data(payload), translated: [], turnInFlight: true)
            }),
            ("replay of another message", .unsupportedUserReplay, { state in
                state.classify(envelope: self.data(self.replay(UUID())), translated: [], turnInFlight: true)
            }),
            ("tool use block", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "tool_use", "id": "t", "name": "Read", "input": [:]]])),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("thinking block", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "thinking", "thinking": "x", "signature": "s"]])),
                    translated: [],
                    turnInFlight: true
                )
            }),
            ("multiblock", .unsupportedAssistant, { state in
                state.classify(
                    envelope: self.data(self.assistant(content: [["type": "text", "text": "A"], ["type": "text", "text": "B"]])),
                    translated: [self.content("A"), self.content("B")],
                    turnInFlight: true
                )
            }),
            ("non-null stop reason", .unsupportedAssistant, { state in
                var payload = self.assistant()
                var message = payload["message"] as! [String: Any]
                message["stop_reason"] = "end_turn"
                payload["message"] = message
                return state.classify(envelope: self.data(payload), translated: [self.content(self.reply)], turnInFlight: true)
            }),
            ("translation without the text", .translationMismatch, { state in
                state.classify(envelope: self.data(self.assistant()), translated: [], turnInFlight: true)
            }),
            ("no owned dispatch", .unownedAssistant, { state in
                state.classify(envelope: self.data(self.assistant()), translated: [self.content(self.reply)], turnInFlight: false)
            }),
            ("error result", .unsupportedResult, { state in
                state.classify(envelope: self.data(self.result(subtype: "error_during_execution", isError: true)), translated: [], turnInFlight: true)
            }),
            ("result before an answer", .resultTextMismatch, { state in
                state.classify(envelope: self.data(self.result()), translated: [], turnInFlight: true)
            }),
            ("malformed payload", .malformedPayload, { state in
                state.classify(envelope: Data("[1]".utf8), translated: [], turnInFlight: true)
            })
        ]
        for (name, reason, classify) in cases {
            var state = eligibleState()
            replayed(&state)
            XCTAssertEqual(disqualification(classify(&state)), reason, name)
            XCTAssertEqual(state.disqualification, reason, name)
        }

        // A result whose text differs from the qualified answer, and the outbound-side refusals.
        var state = eligibleState()
        replayed(&state)
        _ = state.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true)
        XCTAssertEqual(disqualification(state.classify(envelope: data(result("ALPHA-8")), translated: [], turnInFlight: true)), .resultTextMismatch)
        var unidentified = eligibleState()
        unidentified.noteOutbound(uuid: nil, text: prompt)
        XCTAssertEqual(unidentified.disqualification, .unidentifiedOutbound)
        var overlapping = eligibleState()
        overlapping.noteOutbound(uuid: UUID(), text: prompt)
        overlapping.noteOutbound(uuid: UUID(), text: "steer")
        XCTAssertEqual(overlapping.disqualification, .overlappingOutbound)
        // An assistant before the launch identity is known never qualifies.
        var pending = State(launchToken: UUID())
        pending.noteOutbound(uuid: UUID(), text: prompt)
        XCTAssertEqual(disqualification(pending.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true)), .unownedAssistant)
    }

    /// The current app requests no user-message replay: an unreplayed dispatch qualifies only through
    /// affirmative consumed-user attribution naming exactly its outbound message (assistant and
    /// result), never a latest-message guess. Contradicting attribution refuses, replayed or not.
    func testUnreplayedDispatchQualifiesOnlyWithExactConsumedUserAttribution() {
        let token = UUID()
        var state = eligibleState(token: token)
        let outbound = UUID()
        XCTAssertEqual(state.classify(envelope: data(systemInit()), translated: [], turnInFlight: false), .benign)
        state.noteOutbound(uuid: outbound, text: prompt)
        XCTAssertEqual(state.classify(envelope: data(lifecycle("started")), translated: [], turnInFlight: true), .benign)
        let outcome = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true)
        guard case let .attach(_, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("the current app shape qualifies, got \(outcome)")
        }
        XCTAssertEqual(
            state.classify(envelope: data(result(attributedTo: outbound)), translated: [], turnInFlight: true),
            .standalone(.init(producerLaunchToken: token, kind: .resultAgreement(localItemID: complete.localItemID, text: reply)))
        )
        XCTAssertNil(state.disqualification)

        typealias Case = (String, ClaudeLiveTranscriptDisqualification, Bool, (UUID) -> [String: Any])
        let other = UUID()
        let assistantCases: [Case] = [
            ("no replay and no attribution", .unattributedAssistant, false, { _ in self.assistant() }),
            ("another message", .attributionMismatch, false, { _ in self.assistant(attributedTo: other) }),
            ("replayed but contradicting", .attributionMismatch, true, { _ in self.assistant(attributedTo: other) }),
            ("user_message_uuid contradicting", .attributionMismatch, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                payload["user_message_uuid"] = other.uuidString
                return payload
            }),
            ("more than the singleton", .attributionMismatch, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                payload["user_message_uuids"] = [outbound.uuidString, other.uuidString]
                return payload
            }),
            ("nonempty input transformations", .unsupportedAssistant, false, { outbound in
                var payload = self.assistant(attributedTo: outbound)
                var message = payload["message"] as? [String: Any] ?? [:]
                message["input_transformations"] = [["type": "x"]]
                payload["message"] = message
                return payload
            })
        ]
        for (name, reason, replay, makePayload) in assistantCases {
            var state = eligibleState()
            let outbound = UUID()
            state.noteOutbound(uuid: outbound, text: prompt)
            if replay {
                XCTAssertEqual(state.classify(envelope: data(self.replay(outbound)), translated: [], turnInFlight: true), .benign, name)
            }
            let outcome = state.classify(envelope: data(makePayload(outbound)), translated: [content(reply)], turnInFlight: true)
            XCTAssertEqual(disqualification(outcome), reason, name)
        }

        // Result markers and attribution: unknown keys and other values refuse.
        let resultCases: [(String, ClaudeLiveTranscriptDisqualification, (UUID) -> [String: Any])] = [
            ("contradicting attribution", .attributionMismatch, { _ in self.result(attributedTo: other) }),
            ("unknown key", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["compaction"] = true
                return payload
            }),
            ("terminal reason", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["terminal_reason"] = "max_turns"
                return payload
            }),
            ("stop reason", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["stop_reason"] = "max_tokens"
                return payload
            }),
            ("safety stops", .unsupportedResult, { outbound in
                var payload = self.result(attributedTo: outbound)
                payload["safety_stops"] = 1
                return payload
            })
        ]
        for (name, reason, makePayload) in resultCases {
            var state = eligibleState()
            let outbound = UUID()
            state.noteOutbound(uuid: outbound, text: prompt)
            guard case .attach = state.classify(envelope: data(assistant(attributedTo: outbound)), translated: [content(reply)], turnInFlight: true) else {
                return XCTFail(name)
            }
            XCTAssertEqual(disqualification(state.classify(envelope: data(makePayload(outbound)), translated: [], turnInFlight: true)), reason, name)
        }

        // An unknown `system/init` key refuses.
        var initState = eligibleState()
        var unknownInit = systemInit()
        unknownInit["compact_metadata"] = true
        XCTAssertEqual(disqualification(initState.classify(envelope: data(unknownInit), translated: [], turnInFlight: false)), .unsupportedPayload)
    }

    /// Monotonic: once disqualified, a valid turn never qualifies again; the first reason sticks and is
    /// repeated only on user/assistant/result payloads.
    func testDisqualificationIsStickyAndNeverRequalifies() {
        let token = UUID()
        var state = eligibleState(token: token)
        XCTAssertEqual(disqualification(state.classify(envelope: data(["type": "mystery"]), translated: [], turnInFlight: false)), .unsupportedPayload)
        state.markEligible()
        for payload in [systemInit(), lifecycle("queued"), rateLimit(status: "rejected")] {
            XCTAssertEqual(state.classify(envelope: data(payload), translated: [], turnInFlight: false), .benign)
        }
        let outbound = UUID()
        state.noteOutbound(uuid: outbound, text: prompt)
        let sticky = ClaudeLiveTranscriptOutcome.standalone(.init(producerLaunchToken: token, kind: .disqualified(.unsupportedPayload)))
        XCTAssertEqual(state.classify(envelope: data(replay(outbound)), translated: [], turnInFlight: true), sticky)
        XCTAssertEqual(state.classify(envelope: data(assistant()), translated: [content(reply)], turnInFlight: true), sticky)
        XCTAssertEqual(state.classify(envelope: data(result()), translated: [], turnInFlight: true), sticky)
        XCTAssertEqual(state.disqualification, .unsupportedPayload)
    }

    // MARK: Native controller

    private func makeController(enabled: Bool) throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared,
            liveTranscriptQualificationEnabled: enabled
        )
    }

    /// Every stream result emitted since the last drain (a marker bounds the buffered stream).
    /// The controller's events subscription, read through the runtime protocol as the runner reads it
    /// (a direct `await` call on the actor would bind the protocol extension's async defaults).
    private final class EventsReader {
        let runtime: any NativeAgentRuntimeControlling
        let generation: UInt64?
        private var iterator: AsyncStream<NativeAgentRuntimeEvent>.AsyncIterator

        init(_ controller: ClaudeNativeProcessSessionController) async {
            runtime = controller
            let subscription = await runtime.eventsSubscription()
            generation = subscription.generation
            iterator = subscription.events.makeAsyncIterator()
        }

        /// Every stream result emitted since the last drain, bounded by an in-band marker.
        func drain(file: StaticString = #filePath, line: UInt = #line) async -> [AIStreamResult] {
            let marker = UUID()
            let markerGeneration = await runtime.emitEventMarker(marker)
            guard markerGeneration != nil, markerGeneration == generation else {
                XCTFail("the marker went to another events stream (\(String(describing: markerGeneration)))", file: file, line: line)
                return []
            }
            var results: [AIStreamResult] = []
            while let event = await iterator.next() {
                if case let .marker(id) = event, id == marker { return results }
                if case let .stream(result) = event { results.append(result) }
            }
            XCTFail("the events stream ended before the marker", file: file, line: line)
            return results
        }

        /// Every stream result until the events stream ends (stdout EOF finishes it).
        func drainToEnd() async -> [AIStreamResult] {
            var results: [AIStreamResult] = []
            while let event = await iterator.next() {
                if case let .stream(result) = event { results.append(result) }
            }
            return results
        }
    }

    /// One O19 turn of the current app (standard flags: no user-message replay; consumed-user
    /// attribution on the assistant and result) through the production `handleStreamPayload` path of
    /// a synthetic launch.
    private func runTurn(
        _ controller: ClaudeNativeProcessSessionController,
        outbound: UUID = UUID(),
        entry: String = "a1"
    ) async {
        await controller.test_registerSyntheticDispatch()
        await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
        let payloads = [
            lifecycle("started"), assistant(entry: entry, attributedTo: outbound), rateLimit(),
            result(attributedTo: outbound), lifecycle("completed")
        ]
        for payload in payloads {
            await controller.test_handleStreamPayload(payload)
        }
    }

    private func transcriptSignature(_ results: [AIStreamResult]) -> [String] {
        results.map { "\($0.type)|\($0.text ?? "<nil>")" }
    }

    private func evidenceCarriers(_ results: [AIStreamResult]) -> [ClaudeLiveTranscriptEvidence] {
        results.filter { $0.type == AIStreamResult.lifecycleType && $0.text == nil }.compactMap(\.claudeLiveTranscriptEvidence)
    }

    /// Gate OFF, and an ineligible launch with the gate ON, emit exactly the legacy results with no
    /// evidence; an eligible launch emits the same results in the same order, plus metadata-only
    /// carriers and the one attachment.
    func testGateOffAndIneligibleLaunchesMatchLegacyOutputAndEligibleAddsOnlyEvidence() async throws {
        func run(enabled: Bool, provenance: ClaudeNativeProcessSessionController.CommandProvenance) async throws -> [AIStreamResult] {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch(commandProvenance: provenance)
            await controller.test_handleStreamPayload(systemInit())
            await runTurn(controller)
            let results = await reader.drain()
            let state = await controller.test_liveTranscriptQualification()
            if enabled, provenance == .automaticResolved {
                XCTAssertEqual(state?.eligibility, .eligible)
            } else {
                XCTAssertNil(state, "no state for a disabled or ineligible producer")
            }
            return results
        }
        let off = try await run(enabled: false, provenance: .automaticResolved)
        XCTAssertFalse(off.isEmpty)
        XCTAssertTrue(off.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        let ineligible = try await run(enabled: true, provenance: .configuredOverride)
        XCTAssertEqual(transcriptSignature(ineligible), transcriptSignature(off))
        XCTAssertTrue(ineligible.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })

        let eligible = try await run(enabled: true, provenance: .automaticResolved)
        let carriers = evidenceCarriers(eligible)
        let withoutCarriers = eligible.filter { !($0.type == AIStreamResult.lifecycleType && $0.text == nil && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(transcriptSignature(withoutCarriers), transcriptSignature(off), "the same results, order and finalization")
        let attached = eligible.filter { $0.type == "content" && $0.claudeLiveTranscriptEvidence != nil }
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(eligible.count { $0.type == "content" }, off.count { $0.type == "content" }, "content is never duplicated")
        guard case let .completeText(complete) = attached.first?.claudeLiveTranscriptEvidence?.kind else {
            return XCTFail("expected complete text")
        }
        XCTAssertEqual(complete.text, reply)
        XCTAssertEqual(carriers.map(\.kind), [.resultAgreement(localItemID: complete.localItemID, text: reply)])
        for carrier in eligible where carrier.claudeLiveTranscriptEvidence != nil && carrier.type == AIStreamResult.lifecycleType {
            XCTAssertNil(carrier.usageObservation)
            XCTAssertNil(carrier.promptTokens)
            XCTAssertNil(carrier.stopReason)
        }
    }

    /// A payload with empty or suppressed translated output still delivers its disqualification as a
    /// metadata-only carrier; a malformed stdout line disqualifies through the production line path.
    func testEmptySuppressedAndMalformedOutputDeliverDisqualification() async throws {
        let controller = try makeController(enabled: true)
        let reader = await EventsReader(controller)
        await controller.test_beginSyntheticUsageLaunch()
        await controller.test_handleStreamPayload(["type": "system", "subtype": "task_started", "session_id": session, "task_id": "t1"])
        let suppressed = await reader.drain()
        XCTAssertEqual(evidenceCarriers(suppressed).map(\.kind), [.disqualified(.unsupportedPayload)])
        XCTAssertEqual(suppressed.count, 1, "the suppressed result itself never surfaces; only the carrier does")

        let second = try makeController(enabled: true)
        let secondReader = await EventsReader(second)
        await second.test_beginSyntheticUsageLaunch()
        await second.test_handleStreamPayload(["type": "mystery_event", "session_id": session])
        let empty = await secondReader.drain()
        XCTAssertEqual(evidenceCarriers(empty).map(\.kind), [.disqualified(.unsupportedPayload)])

        // A direct disqualification (no payload of its own) is delivered at once, once, even when no
        // later payload arrives.
        let third = try makeController(enabled: true)
        let thirdReader = await EventsReader(third)
        await third.test_beginSyntheticUsageLaunch()
        await third.test_handleLine(Data("{not json".utf8))
        let state = await third.test_liveTranscriptQualification()
        XCTAssertEqual(state?.disqualification, .malformedLine)
        let direct = await thirdReader.drain()
        XCTAssertEqual(evidenceCarriers(direct).map(\.kind), [.disqualified(.malformedLine)])
        await third.test_noteLiveTranscriptOutbound(uuid: nil, text: prompt)
        let repeated = await thirdReader.drain()
        XCTAssertTrue(evidenceCarriers(repeated).isEmpty, "a later direct disqualification adds no second carrier")

        for overlapping in [false, true] {
            let controller = try makeController(enabled: true)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch()
            if overlapping { await controller.test_noteLiveTranscriptOutbound(uuid: UUID(), text: prompt) }
            await controller.test_noteLiveTranscriptOutbound(uuid: overlapping ? UUID() : nil, text: prompt)
            let carriers = await reader.drain()
            XCTAssertEqual(
                evidenceCarriers(carriers).map(\.kind),
                [.disqualified(overlapping ? .overlappingOutbound : .unidentifiedOutbound)]
            )
        }

        // Disabled and ineligible producers emit nothing for the same direct disqualification.
        for (enabled, provenance) in [(false, ClaudeNativeProcessSessionController.CommandProvenance.automaticResolved), (true, .configuredOverride)] {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            await controller.test_beginSyntheticUsageLaunch(commandProvenance: provenance)
            await controller.test_handleLine(Data("{not json".utf8))
            await controller.test_noteLiveTranscriptOutbound(uuid: nil, text: prompt)
            let results = await reader.drain()
            XCTAssertTrue(results.allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        }
    }

    /// The exited launch's buffered stdout tail (a final record without a newline) is classified while
    /// its EOF drains it: a result contradicting the qualified assistant is refused on the events
    /// stream before the stream ends, and the producer is retired. Gate OFF, the same tail yields the
    /// same results in the same order with no evidence.
    func testEOFDrainedTailIsClassifiedBeforeTheProducerRetires() async throws {
        func run(enabled: Bool) async throws -> (beforeEOF: [AIStreamResult], afterEOF: [AIStreamResult]) {
            let controller = try makeController(enabled: enabled)
            let reader = await EventsReader(controller)
            let launch = await controller.test_beginSyntheticUsageLaunch()
            await controller.test_handleStreamPayload(systemInit())
            let outbound = UUID()
            await controller.test_registerSyntheticDispatch()
            await controller.test_noteLiveTranscriptOutbound(uuid: outbound, text: prompt)
            await controller.test_handleStreamPayload(lifecycle("started"))
            await controller.test_handleStreamPayload(assistant(attributedTo: outbound))
            let tail = try JSONSerialization.data(withJSONObject: result("CONTRADICTION", attributedTo: outbound))
            await controller.test_handleStdoutChunk(tail, launchToken: launch.token)
            let beforeEOF = await reader.drain()
            await controller.test_handleStdoutEOF(launchToken: launch.token)
            let afterEOF = await reader.drainToEnd()
            let retired = await controller.test_liveTranscriptQualification()
            XCTAssertNil(retired, "no producer state survives its EOF drain")
            return (beforeEOF, afterEOF)
        }
        let off = try await run(enabled: false)
        XCTAssertTrue((off.beforeEOF + off.afterEOF).allSatisfy { $0.claudeLiveTranscriptEvidence == nil })
        XCTAssertFalse(off.afterEOF.isEmpty, "the tail is translated")

        let on = try await run(enabled: true)
        XCTAssertEqual(
            on.beforeEOF.count { if case .completeText = $0.claudeLiveTranscriptEvidence?.kind { true } else { false } }, 1,
            "the assistant qualified before EOF"
        )
        XCTAssertTrue(evidenceCarriers(on.beforeEOF).isEmpty, "the unterminated tail is not classified before EOF")
        XCTAssertEqual(evidenceCarriers(on.afterEOF).map(\.kind), [.disqualified(.resultTextMismatch)])
        let withoutCarriers = on.afterEOF.filter { !($0.type == AIStreamResult.lifecycleType && $0.claudeLiveTranscriptEvidence != nil) }
        XCTAssertEqual(transcriptSignature(withoutCarriers), transcriptSignature(off.afterEOF), "gate-off results and order")
    }

    /// The latch belongs to the producer: a consumer reset and later turns never requalify it, a stale
    /// launch's stdout never touches the current one, and only a newly installed launch starts fresh.
    func testLatchSurvivesConsumerResetAndTurnsAndOnlyANewLaunchResetsIt() async throws {
        let controller = try makeController(enabled: true)
        let first = await controller.test_beginSyntheticUsageLaunch()
        await controller.test_handleStreamPayload(systemInit())
        await controller.test_handleStreamPayload(["type": "mystery_event", "session_id": session])
        await controller.resetEventsStreamForNewRun()
        let reader = await EventsReader(controller)
        await runTurn(controller)
        let later = await reader.drain()
        XCTAssertTrue(later.allSatisfy { result in
            guard let evidence = result.claudeLiveTranscriptEvidence else { return true }
            return evidence.kind == .disqualified(.unsupportedPayload) && result.type == AIStreamResult.lifecycleType
        }, "no attachment or agreement after disqualification")
        XCTAssertEqual(evidenceCarriers(later).count, 2, "repeated on the assistant and the result")
        let latched = await controller.test_liveTranscriptQualification()
        XCTAssertEqual(latched?.launchToken, first.token)
        XCTAssertEqual(latched?.disqualification, .unsupportedPayload)

        // A new launch installs a fresh producer; the old launch's stdout is dropped.
        let second = await controller.test_beginSyntheticUsageLaunch()
        let fresh = await controller.test_liveTranscriptQualification()
        XCTAssertEqual(fresh?.launchToken, second.token)
        XCTAssertNil(fresh?.disqualification)
        XCTAssertEqual(fresh?.eligibility, .eligible)
        let staleLine = try JSONSerialization.data(withJSONObject: ["type": "mystery_event", "session_id": session]) + Data([0x0A])
        await controller.test_handleStdoutChunk(staleLine, launchToken: first.token)
        await controller.test_handleStdoutChunk(Data("{broken\n".utf8), launchToken: first.token)
        let afterStale = await controller.test_liveTranscriptQualification()
        XCTAssertNil(afterStale?.disqualification, "a stale producer never stamps the replacement launch")
        await controller.test_handleStreamPayload(systemInit())
        await runTurn(controller)
        let qualified = await reader.drain()
        XCTAssertEqual(qualified.count { if case .completeText = $0.claudeLiveTranscriptEvidence?.kind { true } else { false } }, 1)
    }
}
