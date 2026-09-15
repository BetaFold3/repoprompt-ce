import Foundation

/// Optional-preserving raw token-usage companion for one `thread/tokenUsage/updated` notification
/// (plan §4.1). Missing counters stay `nil` (never zero). The installed v2 schema requires
/// `threadId`, `turnId`, `last` and `total`; `cacheWriteInputTokens` is optional (schema default 0)
/// and is preserved exactly as delivered, so absent and zero remain distinguishable downstream.
/// `.tokenUsage(AgentContextUsage)` and context behaviour are unchanged by this companion.
struct CodexUsageObservation: Equatable {
    struct Counters: Equatable {
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var cacheWriteInputTokens: Int?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        var totalTokens: Int?

        static let zero = Counters(inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)

        var isEmpty: Bool {
            inputTokens == nil && cachedInputTokens == nil && cacheWriteInputTokens == nil
                && outputTokens == nil && reasoningOutputTokens == nil && totalTokens == nil
        }
    }

    enum TurnAttribution: String, Equatable {
        /// The notification carried the turn identity (required by the installed v2 schema).
        case notified
        /// No turn identity on the wire; the controller's routing "current turn" is a diagnostic
        /// guess and never authoritative monetary ownership.
        case inferredCurrentTurn
        case unknown
    }

    let threadID: String?
    let turnID: String?
    let turnAttribution: TurnAttribution
    /// Per-controller monotonic delivery ordinal (ownership/ordering evidence).
    let ordinal: Int
    let last: Counters?
    let total: Counters?
    let modelContextWindow: Int?
}

/// `model/rerouted` (installed v2 schema: `fromModel`, `toModel`, `reason`, `threadId`, `turnId`).
/// A known reroute without a corresponding usage boundary makes the affected turn's cost
/// partial/unpriced; it never reprices a whole turn.
struct CodexModelReroute: Equatable {
    let threadID: String?
    let turnID: String?
    let fromModel: String
    let toModel: String
    let reason: String?
}

enum CodexUsageObservationParser {
    static func observation(
        from params: [String: Any],
        tokenUsage: [String: Any],
        threadID: String?,
        notifiedTurnID: String?,
        routingCurrentTurnID: String?,
        ordinal: Int
    ) -> CodexUsageObservation {
        let turnID: String?
        let attribution: CodexUsageObservation.TurnAttribution
        if let notified = trimmed(notifiedTurnID) {
            turnID = notified
            attribution = .notified
        } else if let inferred = trimmed(routingCurrentTurnID) {
            turnID = inferred
            attribution = .inferredCurrentTurn
        } else {
            turnID = nil
            attribution = .unknown
        }
        let last = breakdown(in: tokenUsage, keys: ["last", "lastTokenUsage", "last_token_usage"])
        let total = breakdown(in: tokenUsage, keys: ["total", "totalTokenUsage", "total_token_usage"])
        let contextWindow = integer(tokenUsage["modelContextWindow"])
            ?? integer(tokenUsage["model_context_window"])
            ?? integer(tokenUsage["contextWindow"])
            ?? integer(tokenUsage["context_window"])
        _ = params
        return CodexUsageObservation(
            threadID: trimmed(threadID),
            turnID: turnID,
            turnAttribution: attribution,
            ordinal: ordinal,
            last: last.map(counters(from:)),
            total: total.map(counters(from:)),
            modelContextWindow: contextWindow
        )
    }

    static func reroute(from params: [String: Any], threadID: String?, turnID: String?) -> CodexModelReroute? {
        guard let fromModel = trimmed(params["fromModel"] as? String ?? params["from_model"] as? String),
              let toModel = trimmed(params["toModel"] as? String ?? params["to_model"] as? String)
        else { return nil }
        return CodexModelReroute(
            threadID: trimmed(threadID),
            turnID: trimmed(turnID),
            fromModel: fromModel,
            toModel: toModel,
            reason: trimmed(params["reason"] as? String)
        )
    }

    static func counters(from usage: [String: Any]) -> CodexUsageObservation.Counters {
        CodexUsageObservation.Counters(
            inputTokens: integer(usage["inputTokens"]) ?? integer(usage["input_tokens"]),
            cachedInputTokens: integer(usage["cachedInputTokens"]) ?? integer(usage["cached_input_tokens"]),
            cacheWriteInputTokens: integer(usage["cacheWriteInputTokens"]) ?? integer(usage["cache_write_input_tokens"]),
            outputTokens: integer(usage["outputTokens"]) ?? integer(usage["output_tokens"]),
            reasoningOutputTokens: integer(usage["reasoningOutputTokens"]) ?? integer(usage["reasoning_output_tokens"]),
            totalTokens: integer(usage["totalTokens"]) ?? integer(usage["total_tokens"])
        )
    }

    private static func breakdown(in tokenUsage: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = tokenUsage[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    /// Integral numbers only; booleans, fractions and non-numeric strings are not counters.
    ///
    /// The `NSNumber` class check runs before any integer bridging: JSONSerialization decodes
    /// `true`/`false` as CFBoolean `NSNumber`s that would otherwise bridge to `1`/`0`.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) < 9.007e15 else { return nil }
            return Int(double)
        }
        switch value {
        case let number as Int:
            return number
        case let number as Int64:
            return Int(exactly: number)
        case let text as String:
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
