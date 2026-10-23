import Foundation

// Step 4d3b (lossless restart Phase 4; inactive, default-off, no production caller): live identity
// for the one observed Claude output shape (O19: one dispatched turn whose single-text-block
// assistant envelope and success result are attributed to that dispatch's own outbound user message
// and agree). The app does not request user-message replay; a replay, when present, is only exact
// corroboration. Scope and boundaries:
// docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d3.md.
//
// The native controller classifies EVERY raw stdout payload of a qualified producer, from the exact
// bytes it fed the translator and before any translated result is suppressed. A positive
// classification only marks the one translated `content` result of a complete single-text assistant
// envelope with the deterministic row identity and complete-envelope proof the history reader
// derives (`ClaudeSessionHistoryReader.singleTextAssistantRow`); the canonical owner inserts that row
// and its ledger entry together. Any unrecognized, unsupported or contradicting payload disqualifies
// the producer for the rest of its launch, and the owner then invalidates its Claude proofs.
// Recognition is an allowlist of observed shapes; it is not a claim that other shapes are benign,
// and launch eligibility is not installed-profile qualification.

/// Why a producer stopped qualifying (diagnostic only; never persisted).
package enum ClaudeLiveTranscriptDisqualification: String, Equatable {
    case malformedPayload
    /// An undecodable stdout line (any recovery path may follow).
    case malformedLine
    case unsupportedPayload
    case semanticMarker
    case sessionMismatch
    case unsupportedLifecycle
    case unsupportedRateLimit
    case unsupportedUserReplay
    case unsupportedAssistant
    /// An assistant envelope outside an owned dispatch (or a second one in a turn).
    case unownedAssistant
    /// A consumed-user attribution that is not exactly the dispatch's outbound message.
    case attributionMismatch
    /// An unreplayed dispatch's assistant without affirmative consumed-user attribution.
    case unattributedAssistant
    /// The translated results do not carry exactly the envelope's one text.
    case translationMismatch
    case unsupportedResult
    case resultTextMismatch
    /// A user message written without a recorded outbound identity.
    case unidentifiedOutbound
    /// A user message written while an earlier dispatch had no success result yet.
    case overlappingOutbound
    /// A launch installed while an earlier launch's stdout EOF tail was still draining.
    case launchDuringDrain
}

/// The identity and proof of one qualified complete assistant text: exactly what the history reader
/// projects for the same native entry.
package struct ClaudeLiveTranscriptCompleteText: Equatable {
    package let nativeSessionID: String
    package let nativeEntryID: String
    package let localItemID: UUID
    package let text: String
    package let envelopeDigest: String

    /// The ledger key (normalized native row key) of this row.
    package var ledgerKey: String {
        AgentSessionProviderHistoryRecovery.rowKey(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: ClaudeSessionHistoryReader.RowKind.assistantText.rawValue,
            ordinal: 0
        )
    }

    /// The ledger entry recording this row's identity and proof (no import receipt or cursor).
    package var ledgerItem: AgentSessionProviderHistoryRecovery.NativeItem {
        AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            rowKindRaw: ClaudeSessionHistoryReader.RowKind.assistantText.rawValue,
            ordinal: 0,
            localItemID: localItemID,
            envelopeDigest: envelopeDigest
        )
    }

    /// Whether the stored ID and digest are exactly the history reader's projection of this native
    /// entry and text, so the row and its ledger entry can never disagree.
    package var matchesProjection: Bool {
        guard let row = ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            text: text
        ) else { return false }
        return row.localItemID == localItemID && row.envelopeDigest == envelopeDigest
    }

    /// The canonical row, built by the same projection an import uses (complete, never streaming).
    package var canonicalItem: AgentChatItem? {
        ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: nativeEntryID,
            text: text
        ).flatMap(ClaudeSessionHistoryReader.item(for:))
    }
}

/// Transient evidence a qualified Claude producer attaches to a core stream result. Never encoded,
/// logged or persisted; `nil` on every result of a disabled or ineligible producer.
package struct ClaudeLiveTranscriptEvidence: Equatable {
    package enum Kind: Equatable {
        /// Rides on the envelope's one translated `content` result (never a second copy).
        case completeText(ClaudeLiveTranscriptCompleteText)
        /// A success result whose text equals the turn's qualified assistant text: the owner must
        /// hold exactly that identified row with a valid proof.
        case resultAgreement(localItemID: UUID, text: String)
        /// The producer no longer qualifies (sticky for its launch).
        case disqualified(ClaudeLiveTranscriptDisqualification)
    }

    /// The process launch whose stdout carried the payload.
    package let producerLaunchToken: UUID
    package let kind: Kind
}

extension AIStreamResult {
    /// A metadata-only carrier for evidence with no translated result to ride on (or none that
    /// survives suppression): lifecycle type, no text, no usage, never a turn boundary.
    static func claudeLiveTranscriptEvidenceCarrier(_ evidence: ClaudeLiveTranscriptEvidence) -> AIStreamResult {
        var result = AIStreamResult(type: lifecycleType, text: nil)
        result.claudeLiveTranscriptEvidence = evidence
        return result
    }
}

/// What one classified payload contributes.
package enum ClaudeLiveTranscriptOutcome: Equatable {
    /// Recognized and benign: nothing to carry.
    case benign
    /// Attach to the translated result at `index` (its one `content` result).
    case attach(index: Int, ClaudeLiveTranscriptEvidence)
    /// Emit once as a metadata-only carrier, before the payload's translated results.
    case standalone(ClaudeLiveTranscriptEvidence)
}

/// Qualification state of one producer (process launch). Owned by the native controller; created
/// only when that launch's stdout reader is installed, so a consumer reset, a new turn, `system/init`
/// or a router change never resets it. Monotonic: once disqualified it never qualifies again.
package struct ClaudeLiveTranscriptProducerState {
    package enum Eligibility: Equatable {
        /// The launch identity is not known yet: payloads are classified (disqualification sticks)
        /// but nothing is emitted and nothing qualifies.
        case pending
        case eligible
    }

    private enum Turn: Equatable {
        case idle
        /// An identified outbound message was written; `replayed` once its exact replay was seen.
        case dispatched(uuid: UUID, text: String, replayed: Bool)
        /// The dispatch's qualified answer (the outbound identity is kept for its result).
        case answered(ClaudeLiveTranscriptCompleteText, outbound: UUID)
    }

    package let launchToken: UUID
    package private(set) var eligibility: Eligibility = .pending
    package private(set) var disqualification: ClaudeLiveTranscriptDisqualification?
    /// The first native session ID this producer reported; every later one must equal it.
    private var nativeSessionID: String?
    private var turn: Turn = .idle

    /// Payload types after which a disqualified producer repeats its refusal, so an owner whose
    /// consumer missed the first carrier (a reset events stream) still hears it before any later
    /// turn's output.
    private static let stickyTypes: Set<String> = ["user", "assistant", "result"]
    private static let lifecycleKeys: Set<String> = ["command_uuid", "session_id", "state", "type", "uuid"]
    private static let initKeys: Set<String> = [
        "additional_directories", "agents", "analytics_disabled", "apiKeySource", "capabilities", "claude_code_version",
        "cwd", "fast_mode_disabled_reason", "fast_mode_state", "mcp_servers", "messaging_socket_path", "model",
        "original_cwd", "output_style", "per_turn_effort_active", "permissionMode", "plugins", "product_feedback_disabled",
        "session_id", "skills", "slash_commands", "subtype", "tools", "type", "user_message_uuids", "uuid", "view_mode"
    ]
    private static let resultKeys: Set<String> = [
        "api_error_status", "duration_api_ms", "duration_ms", "fast_mode_disabled_reason", "fast_mode_state",
        "first_content_frame_ms", "first_request_input_tokens", "is_error", "modelUsage", "num_turns", "permission_denials",
        "queued_turn_count", "request_sent_wall_ms", "result", "result_index", "safety_stops", "session_id", "stop_reason",
        "subagent_stats", "subtype", "terminal_reason", "time_to_request_ms", "total_cost_usd", "ttft_ms", "ttft_stream_ms",
        "type", "usage", "user_message_uuid", "user_message_uuids", "uuid"
    ]
    private static let lifecycleStates: Set<String> = ["queued", "started", "completed"]
    private static let rateLimitKeys: Set<String> = ["type", "session_id", "uuid", "rate_limit_info"]
    private static let rateLimitInfoKeys: Set<String> = [
        "status", "rateLimitType", "overageStatus", "overageDisabledReason", "isUsingOverage", "resetsAt",
        "unifiedWindows"
    ]
    private static let replayKeys: Set<String> = [
        "isReplay", "message", "parent_tool_use_id", "session_id", "timestamp", "type", "uuid"
    ]
    private static let assistantKeys: Set<String> = [
        "message", "parent_tool_use_id", "request_id", "session_id", "timestamp", "type", "user_message_uuid",
        "user_message_uuids", "uuid"
    ]
    private static let assistantMessageKeys: Set<String> = [
        "content", "id", "model", "role", "type", "usage", "input_transformations", "container",
        "context_management", "diagnostics", "stop_details", "stop_reason", "stop_sequence"
    ]
    /// Observed only as `null`; any value is an unrecognized semantic shape.
    private static let assistantMessageNullKeys = [
        "container", "context_management", "diagnostics", "stop_details", "stop_reason", "stop_sequence"
    ]

    package init(launchToken: UUID) {
        self.launchToken = launchToken
    }

    /// The launch identity was resolved eligible (automatic command, default backend, no routing
    /// overrides) with the injected qualification enabled.
    package mutating func markEligible() {
        eligibility = .eligible
    }

    package mutating func disqualify(_ reason: ClaudeLiveTranscriptDisqualification) {
        if disqualification == nil { disqualification = reason }
    }

    /// A user message was successfully written. Only a message carrying its recorded outbound UUID,
    /// sent while no earlier dispatch is open, can own a qualified answer.
    package mutating func noteOutbound(uuid: UUID?, text: String) {
        guard disqualification == nil else { return }
        guard let uuid else {
            disqualify(.unidentifiedOutbound)
            return
        }
        guard turn == .idle else {
            disqualify(.overlappingOutbound)
            return
        }
        turn = .dispatched(uuid: uuid, text: text, replayed: false)
    }

    /// Classifies one raw stdout payload (`envelope`: the exact bytes fed to the translator) against
    /// its translated results. `turnInFlight`: the controller owns an outstanding dispatch.
    package mutating func classify(
        envelope: Data,
        translated: [AIStreamResult],
        turnInFlight: Bool
    ) -> ClaudeLiveTranscriptOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? NSDictionary,
              let type = object["type"] as? String
        else { return disqualified(.malformedPayload) }
        if let existing = disqualification {
            return Self.stickyTypes.contains(type) ? .standalone(evidence(.disqualified(existing))) : .benign
        }
        if ClaudeSessionHistoryReader.semanticMarker(in: object) != nil
            || (object["message"] as? NSDictionary).flatMap(ClaudeSessionHistoryReader.semanticMarker(in:)) != nil
        {
            return disqualified(.semanticMarker)
        }
        if let value = object["session_id"] {
            guard let session = value as? String, !session.isEmpty, nativeSessionID == nil || nativeSessionID == session
            else { return disqualified(.sessionMismatch) }
            nativeSessionID = session
        }
        switch type {
        case "command_lifecycle":
            return isRecognizedLifecycle(object) ? .benign : disqualified(.unsupportedLifecycle)
        case "system":
            return isRecognizedInit(object) ? .benign : disqualified(.unsupportedPayload)
        case "rate_limit_event":
            return isAllowedRateLimit(object) ? .benign : disqualified(.unsupportedRateLimit)
        case "user":
            return classifyReplay(object)
        case "assistant":
            return classifyAssistant(object, translated: translated, turnInFlight: turnInFlight)
        case "result":
            return classifyResult(object)
        default:
            return disqualified(.unsupportedPayload)
        }
    }

    // MARK: Shapes

    private func isRecognizedLifecycle(_ object: NSDictionary) -> Bool {
        guard Self.keys(object).isSubset(of: Self.lifecycleKeys),
              let state = object["state"] as? String, Self.lifecycleStates.contains(state)
        else { return false }
        return ["command_uuid", "uuid"].allSatisfy { object[$0] == nil || object[$0] is String }
    }

    /// `system/init` with only its known keys (values are ordinary metadata, not validated further).
    private func isRecognizedInit(_ object: NSDictionary) -> Bool {
        (object["subtype"] as? String) == "init" && Self.keys(object).isSubset(of: Self.initKeys)
    }

    private func isAllowedRateLimit(_ object: NSDictionary) -> Bool {
        guard Self.keys(object).isSubset(of: Self.rateLimitKeys),
              let info = object["rate_limit_info"] as? NSDictionary,
              Self.keys(info).isSubset(of: Self.rateLimitInfoKeys)
        else { return false }
        return (info["status"] as? String) == "allowed"
    }

    /// Optional corroboration: an exact replay of the open dispatch's outbound message.
    private mutating func classifyReplay(_ object: NSDictionary) -> ClaudeLiveTranscriptOutcome {
        guard case let .dispatched(outboundUUID, outboundText, replayed: false) = turn,
              Self.keys(object).isSubset(of: Self.replayKeys),
              (object["isReplay"] as? Bool) == true,
              Self.isNull(object["parent_tool_use_id"]),
              object["timestamp"] == nil || object["timestamp"] is String,
              let replayUUID = (object["uuid"] as? String).flatMap(UUID.init(uuidString:)),
              replayUUID == outboundUUID,
              let message = object["message"] as? NSDictionary,
              Self.keys(message).isSubset(of: ["role", "content"]),
              (message["role"] as? String) == "user",
              (message["content"] as? String) == outboundText
        else { return disqualified(.unsupportedUserReplay) }
        turn = .dispatched(uuid: outboundUUID, text: outboundText, replayed: true)
        return .benign
    }

    /// Consumed-user attribution of an envelope: `nil` when it carries none; `true` only when every
    /// provided attribute names exactly `outbound` (`user_message_uuids` exactly that singleton).
    private static func attribution(_ object: NSDictionary, outbound: UUID) -> Bool? {
        let single = object["user_message_uuid"]
        let list = object["user_message_uuids"]
        guard single != nil || list != nil else { return nil }
        if let single {
            guard let value = single as? String, UUID(uuidString: value) == outbound else { return false }
        }
        if let list {
            guard let values = list as? [Any], values.count == 1, let value = values[0] as? String,
                  UUID(uuidString: value) == outbound
            else { return false }
        }
        return true
    }

    private mutating func classifyAssistant(
        _ object: NSDictionary,
        translated: [AIStreamResult],
        turnInFlight: Bool
    ) -> ClaudeLiveTranscriptOutcome {
        guard eligibility == .eligible, turnInFlight, case let .dispatched(outbound, _, replayed) = turn, let nativeSessionID else {
            return disqualified(.unownedAssistant)
        }
        // Ownership is the recorded outbound identity: provided attribution must name exactly it, and
        // without a replay it must be provided (never a latest-message guess).
        switch Self.attribution(object, outbound: outbound) {
        case false?:
            return disqualified(.attributionMismatch)
        case nil where !replayed:
            return disqualified(.unattributedAssistant)
        default:
            break
        }
        guard Self.keys(object).isSubset(of: Self.assistantKeys),
              object["session_id"] is String,
              Self.isNull(object["parent_tool_use_id"]),
              ["request_id", "timestamp"].allSatisfy({ object[$0] == nil || object[$0] is String }),
              let entryID = object["uuid"] as? String, !entryID.isEmpty,
              let message = object["message"] as? NSDictionary,
              Self.keys(message).isSubset(of: Self.assistantMessageKeys),
              (message["role"] as? String) == "assistant",
              let messageID = message["id"] as? String, !messageID.isEmpty,
              ["model", "type"].allSatisfy({ message[$0] == nil || message[$0] is String }),
              message["usage"] == nil || message["usage"] is NSDictionary,
              message["input_transformations"] == nil || (message["input_transformations"] as? [Any])?.isEmpty == true,
              Self.assistantMessageNullKeys.allSatisfy({ Self.isNull(message[$0]) }),
              let content = message["content"] as? [Any], content.count == 1,
              let block = content[0] as? NSDictionary,
              Self.keys(block) == ["type", "text"],
              (block["type"] as? String) == "text",
              let text = block["text"] as? String, !text.isEmpty
        else { return disqualified(.unsupportedAssistant) }
        // The envelope's one translated `content` result, carrying exactly its text; only its usage
        // companion may accompany it.
        let carriers = translated.indices.filter { translated[$0].type != "usage" }
        guard carriers.count == 1, translated[carriers[0]].type == "content", translated[carriers[0]].text == text
        else { return disqualified(.translationMismatch) }
        guard let row = ClaudeSessionHistoryReader.singleTextAssistantRow(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            text: text
        ), let localItemID = row.localItemID
        else { return disqualified(.unsupportedAssistant) }
        let complete = ClaudeLiveTranscriptCompleteText(
            nativeSessionID: nativeSessionID,
            nativeEntryID: entryID,
            localItemID: localItemID,
            text: text,
            envelopeDigest: row.envelopeDigest
        )
        turn = .answered(complete, outbound: outbound)
        return .attach(index: carriers[0], evidence(.completeText(complete)))
    }

    private mutating func classifyResult(_ object: NSDictionary) -> ClaudeLiveTranscriptOutcome {
        guard Self.keys(object).isSubset(of: Self.resultKeys),
              (object["subtype"] as? String) == "success",
              (object["is_error"] as? Bool) == false,
              object["session_id"] is String,
              let text = object["result"] as? String,
              Self.isNull(object["api_error_status"]),
              object["permission_denials"] == nil || (object["permission_denials"] as? [Any])?.isEmpty == true,
              object["terminal_reason"] == nil || (object["terminal_reason"] as? String) == "completed",
              object["stop_reason"] == nil || (object["stop_reason"] as? String) == "end_turn",
              object["safety_stops"] == nil || Self.isZero(object["safety_stops"])
        else { return disqualified(.unsupportedResult) }
        // Exact agreement with this turn's qualified assistant, whatever the translator forwards.
        guard case let .answered(complete, outbound) = turn, complete.text == text else {
            return disqualified(.resultTextMismatch)
        }
        if Self.attribution(object, outbound: outbound) == false {
            return disqualified(.attributionMismatch)
        }
        turn = .idle
        return .standalone(evidence(.resultAgreement(localItemID: complete.localItemID, text: text)))
    }

    // MARK: Helpers

    private mutating func disqualified(_ reason: ClaudeLiveTranscriptDisqualification) -> ClaudeLiveTranscriptOutcome {
        disqualify(reason)
        return .standalone(evidence(.disqualified(disqualification ?? reason)))
    }

    private func evidence(_ kind: ClaudeLiveTranscriptEvidence.Kind) -> ClaudeLiveTranscriptEvidence {
        ClaudeLiveTranscriptEvidence(producerLaunchToken: launchToken, kind: kind)
    }

    private static func keys(_ object: NSDictionary) -> Set<String> {
        Set(object.allKeys.compactMap { $0 as? String })
    }

    private static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    /// A JSON integer zero (never a boolean).
    private static func isZero(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 0 && number.doubleValue == 0
    }
}
