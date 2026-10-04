import Foundation

/// Failed-Oracle diagnosability (Oracle failure inspection plan, Patch B).
///
/// One pure, synchronous, non-throwing projection shared by transcript persistence
/// (`AgentToolResultPersistencePolicy`) and the Oracle tool card, so a live card and the same
/// card after a transcript reload cannot diverge. It holds no sessions, view models,
/// operation-store references, or caches.
///
/// Diagnostic selection is deterministic: the first failure diagnostic in source order, by
/// priority — (1) a structured `errors[]` entry with a non-empty message; (2) the lowest-index
/// failed lane of a lane envelope; (3) the top-level `error` (string or `{code,message}`,
/// including the `is_error`/`code`/`error` tool-error shapes); (4) raw non-JSON text, only when
/// trusted status establishes failure. A `code` is copied only from a structured field and never
/// derived from free text. Successful response text never becomes an error.
enum OracleToolResultInspection {
    /// Up to four retained diagnostics: the primary one plus up to three more.
    static let maxRetainedDiagnostics = 4
    static let primaryMessageMaxBytes = 512
    static let shortenedPrimaryMessageMaxBytes = 256
    static let secondaryMessageMaxBytes = 160
    static let codeMaxBytes = 80
    static let chatIDMaxBytes = 64
    static let summaryTextMaxBytes = 160
    static let summaryTextPrefix = "Failed: "
    /// Appended to text cut at a UTF-8 boundary; included in every byte bound.
    static let truncationMarker = "…"

    static let recognizedModes: Set<String> = ["chat", "plan", "review"]

    enum Key {
        static let errors = "errors"
        static let errorCount = "error_count"
        static let errorTruncated = "error_truncated"
        static let laneCount = "lane_count"
        static let failedCount = "failed_count"
        static let nonterminalCount = "nonterminal_count"
        static let summaryText = "summary_text"
        static let summaryOnly = "summary_only"
        static let mode = "mode"
        static let status = "status"
        static let index = "index"
        static let chatID = "chat_id"
        /// A retained diagnostic's lane chat identity. Distinct from the root `chat_id`, so an
        /// explicitly scoped lane route never competes with authoritative root routing; the
        /// routing policy still counts it against identity-free latest-chat fallback.
        static let laneChatID = AgentOracleAuthoritativeChatIDPolicy.scopedLaneChatIDKey
        /// A saved summary's record of the Oracle's own outcome when the invocation `status` is a
        /// failure but the Oracle result is not (see `InvocationFailureOutcome`).
        static let oracleOutcome = "oracle_outcome"
        static let code = "code"
        static let message = "message"
        static let results = "results"
    }

    /// One retained diagnostic: redacted and byte-bounded. `index`/`laneChatID` identify a failed
    /// lane of a lane envelope; neither is ever parsed from message text. `laneChatID` is only an
    /// explicitly scoped lane route; it never replaces the result's authoritative root chat ID.
    struct Diagnostic: Equatable {
        var index: Int?
        var laneChatID: String?
        var code: String?
        var message: String
    }

    /// Lane counts computed from the original envelope. `nonterminalCount` describes lanes that
    /// were unfinished *when recorded*; it never claims current state.
    struct LaneCounts: Equatable {
        let laneCount: Int
        let failedCount: Int
        let nonterminalCount: Int
    }

    struct Failure: Equatable {
        /// Redacted, bounded, at most `maxRetainedDiagnostics`; entry 0 is the primary diagnostic.
        let diagnostics: [Diagnostic]
        /// Original diagnostic count, computed before truncation (0 when none was retained or found).
        let errorCount: Int
        /// True when text, a code, or additional diagnostics were omitted.
        let isTruncated: Bool
        /// True when the primary message itself was cut.
        let primaryMessageTruncated: Bool
        let laneCounts: LaneCounts?
        /// True when the inspected payload is an already-saved transcript summary.
        let isSavedSummary: Bool

        var primary: Diagnostic? {
            diagnostics.first
        }

        /// First non-empty line of the primary (already redacted) message.
        var headline: String? {
            guard let message = primary?.message else { return nil }
            return message
                .split(separator: "\n", omittingEmptySubsequences: true)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }

        /// `Failed: ` plus the headline, bounded to `summaryTextMaxBytes`.
        var summaryText: String? {
            headline.map {
                OracleToolResultInspection.truncatedUTF8(
                    OracleToolResultInspection.summaryTextPrefix + $0,
                    maxBytes: OracleToolResultInspection.summaryTextMaxBytes
                ).text
            }
        }

        /// Diagnostics that existed but were not retained.
        var omittedDiagnosticCount: Int {
            max(0, errorCount - diagnostics.count)
        }
    }

    enum LaneState: Equatable {
        case completed
        case cancelled
        case failed
        case nonterminal
    }

    /// The Oracle's own outcome when the trusted invocation status is a failure but the Oracle
    /// result itself is not: it was still unfinished, or cancelled, when recorded. A saved summary
    /// keeps the invocation `status` as it was and records this as `oracle_outcome` beside it.
    enum InvocationFailureOutcome: String, Equatable {
        case nonterminal
        case cancelled
    }

    /// The shared classification of an Oracle result.
    enum Classification: Equatable {
        case failed(Failure)
        /// The trusted invocation status says failed, but the Oracle result was unfinished or
        /// cancelled, so it is not an Oracle failure.
        case invocationFailureOnly(InvocationFailureOutcome)
        case notFailed

        var failure: Failure? {
            if case let .failed(failure) = self {
                return failure
            }
            return nil
        }
    }

    // MARK: - Inspection

    /// Inspects a raw or already-summarized Oracle tool result. Returns `nil` unless the result
    /// failed; pending-only and cancelled-only results are not failures.
    ///
    /// - Parameters:
    ///   - resultJSON: the tool result payload (`toolResultJSON`); may be plain text.
    ///   - text: the rendered item text, consulted when `resultJSON` is empty.
    ///   - toolIsError: the trusted provider error flag. It does not establish failure when the
    ///     trusted status is cancelled or still pending/running.
    ///   - statusWord: the trusted normalized execution status word.
    static func inspect(
        resultJSON: String?,
        text: String?,
        toolIsError: Bool?,
        statusWord: String?
    ) -> Failure? {
        classify(resultJSON: resultJSON, text: text, toolIsError: toolIsError, statusWord: statusWord).failure
    }

    /// The full classification behind `inspect`, including the Oracle's own outcome when a trusted
    /// invocation failure is not an Oracle failure. Same parameters as `inspect`.
    static func classify(
        resultJSON: String?,
        text: String?,
        toolIsError: Bool?,
        statusWord: String?
    ) -> Classification {
        let trustedFailure = isTrustedFailure(toolIsError: toolIsError, statusWord: statusWord)
        let candidates = [resultJSON, text].compactMap(nonEmptyTrimmed)
        for candidate in candidates {
            if let object = ToolRawJSON.object(from: candidate) {
                return classify(object: object, trustedFailure: trustedFailure, depth: 0)
            }
        }
        guard trustedFailure, let rawText = candidates.first else { return .notFailed }
        // Only raw *non-JSON* text is a diagnostic; an unrecognized JSON value is not.
        if isJSONValue(rawText) {
            return .failed(makeFailure(raw: [], laneCounts: nil, storedErrorCount: nil, storedTruncated: false, isSavedSummary: false))
        }
        return .failed(makeFailure(
            raw: [RawDiagnostic(message: rawText)],
            laneCounts: nil,
            storedErrorCount: nil,
            storedTruncated: false,
            isSavedSummary: false
        ))
    }

    /// Inspects an already-decoded result object (the persistence policy's raw object).
    static func inspect(object: [String: Any], toolIsError: Bool?, statusWord: String?) -> Failure? {
        classify(object: object, toolIsError: toolIsError, statusWord: statusWord).failure
    }

    static func classify(object: [String: Any], toolIsError: Bool?, statusWord: String?) -> Classification {
        classify(
            object: object,
            trustedFailure: isTrustedFailure(toolIsError: toolIsError, statusWord: statusWord),
            depth: 0
        )
    }

    static func isTrustedFailure(toolIsError: Bool?, statusWord: String?) -> Bool {
        let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(statusWord)
        if normalized == "failed" {
            return true
        }
        guard toolIsError == true else { return false }
        switch normalized {
        case "cancelled", "pending", "running":
            return false
        default:
            return true
        }
    }

    private static func classify(
        object: [String: Any],
        trustedFailure: Bool,
        depth: Int
    ) -> Classification {
        // A saved summary's recorded Oracle outcome outranks its invocation `status`. Persistence
        // writes it only without failure fields, and keeps writing it on every re-save.
        if let outcome = savedInvocationFailureOutcome(object) {
            return .invocationFailureOnly(outcome)
        }
        // A live Cursor ACP tool result wraps the actual tool output; a saved summary is read as is.
        if depth == 0,
           object["acp_status"] is String,
           bool(object, keys: [Key.summaryOnly, "summaryOnly"]) != true
        {
            return classifyCursorACP(object, trustedFailure: trustedFailure)
        }
        // An MCP content envelope (`content[].text`) whose text is the actual tool error.
        if depth < 2, let contentText = mcpContentText(object) {
            let envelopeFailure = trustedFailure || bool(object, keys: ["is_error", "isError"]) == true
            if let nested = ToolRawJSON.object(from: contentText) {
                return classify(object: nested, trustedFailure: envelopeFailure, depth: depth + 1)
            }
            guard envelopeFailure else { return .notFailed }
            return .failed(makeFailure(
                raw: [RawDiagnostic(message: contentText)],
                laneCounts: nil,
                storedErrorCount: nil,
                storedTruncated: false,
                isSavedSummary: false
            ))
        }

        let lanes = (object[Key.results] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        if !lanes.isEmpty {
            let states = lanes.map(laneState)
            let counts = LaneCounts(
                laneCount: lanes.count,
                failedCount: states.count(where: { $0 == .failed }),
                nonterminalCount: states.count(where: { $0 == .nonterminal })
            )
            // An invocation-level error alone (the trusted flag or a bare `message`) is a failure
            // only when every lane is terminal and at least one completed, mirroring the single
            // result rule; it never makes an envelope with unfinished lanes terminal.
            let invocationFailureIsTerminal = trustedFailure
                && counts.nonterminalCount == 0
                && states.contains(.completed)
            let structured = structuredErrorDiagnostics(object)
            let topLevel = topLevelErrorDiagnostic(object, allowMessageKey: invocationFailureIsTerminal)
            guard counts.failedCount > 0 || !structured.isEmpty || topLevel != nil || invocationFailureIsTerminal else {
                // No lane failed and no lane is completed with the others terminal: under a
                // trusted invocation failure the Oracle outcome is unfinished, or else every
                // lane was cancelled.
                guard trustedFailure else { return .notFailed }
                return .invocationFailureOnly(counts.nonterminalCount > 0 ? .nonterminal : .cancelled)
            }
            let failedLanes = zip(lanes, states).enumerated()
                .filter { $0.element.1 == .failed }
                .map { (position: $0.offset, lane: $0.element.0) }
                .sorted { lhs, rhs in
                    let lhsIndex = int(lhs.lane, keys: [Key.index]) ?? Int.max
                    let rhsIndex = int(rhs.lane, keys: [Key.index]) ?? Int.max
                    return lhsIndex == rhsIndex ? lhs.position < rhs.position : lhsIndex < rhsIndex
                }
            // Each failed lane contributes its first diagnostic, tagged with its lane identity
            // (kept beside any root `chat_id` under the distinct `lane_chat_id` key). Its other
            // diagnostics are not retained but still count toward the original error count.
            let perLaneDiagnostics = failedLanes.map { laneDiagnostics($0.lane) }
            let omittedLaneDiagnosticCount = perLaneDiagnostics.reduce(0) { $0 + max(0, $1.count - 1) }
            return .failed(makeFailure(
                raw: structured + perLaneDiagnostics.compactMap(\.first) + (topLevel.map { [$0] } ?? []),
                omittedBeforeRetention: omittedLaneDiagnosticCount,
                laneCounts: counts,
                storedErrorCount: int(object, keys: [Key.errorCount]),
                storedTruncated: bool(object, keys: [Key.errorTruncated]) == true,
                isSavedSummary: bool(object, keys: [Key.summaryOnly, "summaryOnly"]) == true
            ))
        }

        let isSavedSummary = bool(object, keys: [Key.summaryOnly, "summaryOnly"]) == true
        // Same classification as the card (`OracleToolCardPresentation.state`): a non-terminal
        // status word such as `success` with retained `errors[]` is failed, so live and reloaded
        // cards agree. Output without a failure signal is untouched.
        let state = laneState(object)
        guard state == .failed || (trustedFailure && state == .completed) else {
            guard trustedFailure else { return .notFailed }
            switch state {
            case .nonterminal:
                return .invocationFailureOnly(.nonterminal)
            case .cancelled:
                return .invocationFailureOnly(.cancelled)
            case .completed, .failed:
                return .notFailed
            }
        }
        let structured = structuredErrorDiagnostics(object)
        let topLevel = topLevelErrorDiagnostic(object, allowMessageKey: true)
        return .failed(makeFailure(
            raw: structured + (topLevel.map { [$0] } ?? []),
            laneCounts: storedLaneCounts(object),
            storedErrorCount: int(object, keys: [Key.errorCount]),
            storedTruncated: bool(object, keys: [Key.errorTruncated]) == true,
            isSavedSummary: isSavedSummary
        ))
    }

    /// A saved summary's `oracle_outcome`; never read from a live result.
    private static func savedInvocationFailureOutcome(_ object: [String: Any]) -> InvocationFailureOutcome? {
        guard bool(object, keys: [Key.summaryOnly, "summaryOnly"]) == true,
              let raw = string(object, keys: [Key.oracleOutcome])
        else {
            return nil
        }
        return InvocationFailureOutcome(rawValue: raw)
    }

    /// Cursor ACP: the ACP status (or the trusted status) establishes failure for the wrapped
    /// `rawOutput`, which is inspected like any other Oracle result, so a still-pending or
    /// cancelled Oracle result inside a failed ACP call is not a failure. Without a usable
    /// `rawOutput`, the ACP content text is the diagnostic.
    private static func classifyCursorACP(_ object: [String: Any], trustedFailure: Bool) -> Classification {
        let failed = trustedFailure || laneState(object) == .failed
        if let output = object["rawOutput"] as? [String: Any], !output.isEmpty {
            return classify(object: output, trustedFailure: failed, depth: 1)
        }
        let outputText = nonEmptyTrimmed(object["rawOutput"] as? String) ?? cursorACPContentText(object["content"])
        if let outputText, let nested = ToolRawJSON.object(from: outputText) {
            return classify(object: nested, trustedFailure: failed, depth: 1)
        }
        guard failed else { return .notFailed }
        let raw = outputText.flatMap { isJSONValue($0) ? nil : RawDiagnostic(message: $0) }
        return .failed(makeFailure(
            raw: raw.map { [$0] } ?? [],
            laneCounts: nil,
            storedErrorCount: nil,
            storedTruncated: false,
            isSavedSummary: false
        ))
    }

    /// Text of Cursor ACP `content` entries (`{text}` or `{content: {text}}`), in order.
    private static func cursorACPContentText(_ value: Any?) -> String? {
        guard let entries = value as? [Any] else { return nil }
        let texts = entries.compactMap { element -> String? in
            guard let entry = element as? [String: Any] else { return nil }
            return nonEmptyTrimmed(entry["text"] as? String)
                ?? nonEmptyTrimmed((entry["content"] as? [String: Any])?["text"] as? String)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Lane classification shared with `OracleToolCardLanePresentation`: terminal status is
    /// authoritative; otherwise an explicit failure signal, then nonterminal markers.
    static func laneState(_ lane: [String: Any]) -> LaneState {
        switch string(lane, keys: [Key.status])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "ready":
            return .completed
        case "cancelled":
            return .cancelled
        case "failed", "unknown", "delivery_failed":
            return .failed
        default:
            break
        }
        if bool(lane, keys: ["ok"]) == false
            || hasErrorValue(lane["error"])
            || hasNonEmptyErrors(lane[Key.errors])
            || bool(lane, keys: ["is_error", "isError"]) == true
            || (int(lane, keys: [Key.failedCount]) ?? 0) > 0
        {
            return .failed
        }
        let pending = lane["pending"] as? [String: Any]
        let streamState = string(pending, keys: ["stream_state"])?.lowercased()
        if string(lane, keys: ["cancel"])?.lowercased() == "requested"
            || streamState == "cancelling"
            || streamState == "queued"
            || streamState == "starting"
        {
            return .nonterminal
        }
        switch string(lane, keys: [Key.status])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "running", "starting", "cancelling":
            return .nonterminal
        default:
            return .completed
        }
    }

    // MARK: - Persistence

    /// Adds the failure fields to an Oracle summary object and returns the encoded JSON within
    /// `maxBytes`. Shedding order: drop diagnostics 1–3; shorten the primary message to 256 bytes;
    /// drop its code; keep only status, counts, a short primary diagnostic and its bounded
    /// identity; finally the minimal status object with `summary_text`. `results` is never
    /// persisted, so a reloaded card cannot fabricate a lane from an empty array.
    static func boundedFailureSummaryJSON(
        base: [String: Any],
        failure: Failure,
        argumentMode: String?,
        statusWord: String,
        normalizedToolName: String?,
        maxBytes: Int
    ) -> String {
        var prepared = base
        prepared.removeValue(forKey: Key.results)
        if nonEmptyTrimmed(prepared[Key.mode] as? String) == nil,
           let argumentMode = recognizedMode(argumentMode)
        {
            prepared[Key.mode] = argumentMode
        }
        if let summaryText = failure.summaryText {
            prepared[Key.summaryText] = summaryText
        }

        func summaryObject(
            from source: [String: Any],
            diagnostics: [Diagnostic],
            truncated: Bool
        ) -> [String: Any] {
            var object = source
            if diagnostics.isEmpty {
                object.removeValue(forKey: Key.errors)
            } else {
                object[Key.errors] = diagnostics.map(diagnosticObject)
            }
            if failure.errorCount > 0 {
                object[Key.errorCount] = failure.errorCount
            }
            if truncated {
                object[Key.errorTruncated] = true
            } else {
                object.removeValue(forKey: Key.errorTruncated)
            }
            if let counts = failure.laneCounts {
                object[Key.laneCount] = counts.laneCount
                object[Key.failedCount] = counts.failedCount
                object[Key.nonterminalCount] = counts.nonterminalCount
            }
            return object
        }

        func fitting(_ object: [String: Any]) -> String? {
            guard let json = encode(object), json.utf8.count <= maxBytes else { return nil }
            return json
        }

        var diagnostics = failure.diagnostics
        var truncated = failure.isTruncated
        if let json = fitting(summaryObject(from: prepared, diagnostics: diagnostics, truncated: truncated)) {
            return json
        }
        if diagnostics.count > 1 {
            diagnostics = Array(diagnostics.prefix(1))
            truncated = true
            if let json = fitting(summaryObject(from: prepared, diagnostics: diagnostics, truncated: truncated)) {
                return json
            }
        }
        if var primary = diagnostics.first {
            let shortened = boundedRedactedText(primary.message, maxBytes: shortenedPrimaryMessageMaxBytes)
            if shortened.wasTruncated {
                primary.message = shortened.text
                truncated = true
                diagnostics = [primary]
                if let json = fitting(summaryObject(from: prepared, diagnostics: diagnostics, truncated: truncated)) {
                    return json
                }
            }
            if primary.code != nil {
                primary.code = nil
                truncated = true
                diagnostics = [primary]
                if let json = fitting(summaryObject(from: prepared, diagnostics: diagnostics, truncated: truncated)) {
                    return json
                }
            }
        }
        // Status, counts, a short primary diagnostic, and its bounded identity.
        var minimal: [String: Any] = [
            Key.status: statusWord,
            Key.summaryOnly: true
        ]
        for key in [Key.mode, Key.summaryText] {
            if let value = prepared[key] {
                minimal[key] = value
            }
        }
        if let chatID = sanitizedChatID(prepared[Key.chatID] as? String) {
            minimal[Key.chatID] = chatID
        }
        if let json = fitting(summaryObject(from: minimal, diagnostics: diagnostics, truncated: truncated)) {
            return json
        }
        return AgentToolResultPersistencePolicy.minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            summaryText: failure.summaryText
        )
    }

    /// The recognized Oracle mode from actual call arguments; no other argument is copied.
    static func recognizedMode(fromArgumentsJSON argsJSON: String?) -> String? {
        guard let object = ToolRawJSON.object(from: argsJSON) else { return nil }
        return recognizedMode(object[Key.mode] as? String)
    }

    static func recognizedMode(_ raw: String?) -> String? {
        guard let mode = nonEmptyTrimmed(raw)?.lowercased(), recognizedModes.contains(mode) else { return nil }
        return mode
    }

    // MARK: - Bounded text

    /// Cuts `text` at a grapheme (and therefore UTF-8) boundary so the result, including the
    /// truncation marker, never exceeds `maxBytes`. Text already within bounds is returned
    /// unchanged, which keeps re-truncation a fixed point.
    static func truncatedUTF8(_ text: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        let budget = max(0, maxBytes - truncationMarker.utf8.count)
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= budget else { break }
            result.append(character)
            used += size
        }
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return (result + truncationMarker, true)
    }

    /// Bounds text that is already redacted. A cut can leave a fragment (a partial placeholder
    /// or URL parameter) that the scrubber would rewrite on a later pass, so the cut backs off
    /// until the stored text is itself a redaction fixed point. Re-sanitizing a saved summary
    /// therefore never changes it.
    static func boundedRedactedText(_ redacted: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
        let cut = truncatedUTF8(redacted, maxBytes: maxBytes)
        guard cut.wasTruncated else { return cut }
        var body = String(cut.text.dropLast(truncationMarker.count))
        var attempts = 0
        while !body.isEmpty {
            let candidate = body + truncationMarker
            if OracleDiagnosticRedactor.redact(candidate) == candidate {
                return (candidate, true)
            }
            attempts += 1
            if attempts <= 32 {
                body.removeLast()
            } else if let space = body.lastIndex(where: \.isWhitespace) {
                body = String(body[..<space])
            } else {
                body.removeLast(max(1, body.count / 2))
            }
            while let last = body.last, last.isWhitespace {
                body.removeLast()
            }
        }
        return (truncationMarker, true)
    }

    // MARK: - Diagnostic extraction

    private struct RawDiagnostic {
        var index: Int?
        var laneChatID: String?
        var code: String?
        var message: String
    }

    /// - Parameter omittedBeforeRetention: diagnostics that exist in the source but were not
    ///   passed as candidates (additional errors of a failed lane); they count toward the
    ///   original error count and mark the failure truncated.
    private static func makeFailure(
        raw: [RawDiagnostic],
        omittedBeforeRetention: Int = 0,
        laneCounts: LaneCounts?,
        storedErrorCount: Int?,
        storedTruncated: Bool,
        isSavedSummary: Bool
    ) -> Failure {
        var truncated = storedTruncated || raw.count > maxRetainedDiagnostics || omittedBeforeRetention > 0
        var primaryTruncated = false
        var diagnostics: [Diagnostic] = []
        for rawDiagnostic in raw {
            guard diagnostics.count < maxRetainedDiagnostics else { break }
            let redacted = OracleDiagnosticRedactor.redact(rawDiagnostic.message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !redacted.isEmpty else { continue }
            let limit = diagnostics.isEmpty ? primaryMessageMaxBytes : secondaryMessageMaxBytes
            let bounded = boundedRedactedText(redacted, maxBytes: limit)
            if bounded.wasTruncated {
                truncated = true
                if diagnostics.isEmpty {
                    primaryTruncated = true
                }
            }
            let code = sanitizedCode(rawDiagnostic.code)
            if rawDiagnostic.code != nil, code == nil {
                truncated = true
            }
            diagnostics.append(Diagnostic(
                index: rawDiagnostic.index.flatMap { $0 >= 0 ? $0 : nil },
                laneChatID: sanitizedChatID(rawDiagnostic.laneChatID),
                code: code,
                message: bounded.text
            ))
        }
        if isSavedSummary, storedTruncated, diagnostics.first?.message.hasSuffix(truncationMarker) == true {
            primaryTruncated = true
        }
        return Failure(
            diagnostics: diagnostics,
            errorCount: max(raw.count + max(0, omittedBeforeRetention), storedErrorCount ?? 0),
            isTruncated: truncated,
            primaryMessageTruncated: primaryTruncated,
            laneCounts: laneCounts,
            isSavedSummary: isSavedSummary
        )
    }

    /// Structured `errors[]` entries in source order: strings, or objects carrying a message
    /// (and optionally a structured code and lane identity, as persisted summaries do). A lane
    /// identity is read only from the structured `lane_chat_id` (persisted) or entry `chat_id`.
    private static func structuredErrorDiagnostics(_ object: [String: Any]) -> [RawDiagnostic] {
        guard let entries = object[Key.errors] as? [Any] else { return [] }
        return entries.compactMap { entry in
            if let message = nonEmptyTrimmed(entry as? String) {
                return RawDiagnostic(message: message)
            }
            guard let entryObject = entry as? [String: Any],
                  let message = nonEmptyTrimmed(string(entryObject, keys: [Key.message, "error"]))
            else {
                return nil
            }
            return RawDiagnostic(
                index: int(entryObject, keys: [Key.index]),
                laneChatID: string(entryObject, keys: [Key.laneChatID, Key.chatID]),
                code: structuredCode(entryObject[Key.code]),
                message: message
            )
        }
    }

    /// The top-level `error` as a string (with a sibling structured `code`) or `{code,message}`.
    /// A bare top-level `message` (provider error objects) is only read when failure is
    /// otherwise established, so ordinary response fields never become errors.
    private static func topLevelErrorDiagnostic(
        _ object: [String: Any],
        allowMessageKey: Bool
    ) -> RawDiagnostic? {
        if let message = nonEmptyTrimmed(object["error"] as? String) {
            return RawDiagnostic(code: structuredCode(object[Key.code]), message: message)
        }
        if let errorObject = object["error"] as? [String: Any] {
            let code = structuredCode(errorObject[Key.code]) ?? structuredCode(object[Key.code])
            if let message = nonEmptyTrimmed(string(errorObject, keys: [Key.message])) ?? code {
                return RawDiagnostic(code: code, message: message)
            }
        }
        if allowMessageKey,
           object["response"] == nil,
           let message = nonEmptyTrimmed(object[Key.message] as? String)
        {
            return RawDiagnostic(code: structuredCode(object[Key.code]), message: message)
        }
        return nil
    }

    /// Every diagnostic of a failed lane in source order (`errors[]`, then `error`), each tagged
    /// with the lane's stable index and structured chat ID.
    private static func laneDiagnostics(_ lane: [String: Any]) -> [RawDiagnostic] {
        let index = int(lane, keys: [Key.index])
        let laneChatID = string(lane, keys: [Key.chatID])
        let topLevel = topLevelErrorDiagnostic(lane, allowMessageKey: false)
        return (structuredErrorDiagnostics(lane) + (topLevel.map { [$0] } ?? [])).map { diagnostic in
            var tagged = diagnostic
            tagged.index = index
            tagged.laneChatID = laneChatID
            return tagged
        }
    }

    private static func storedLaneCounts(_ object: [String: Any]) -> LaneCounts? {
        guard let laneCount = int(object, keys: [Key.laneCount]),
              let failedCount = int(object, keys: [Key.failedCount]),
              let nonterminalCount = int(object, keys: [Key.nonterminalCount])
        else {
            return nil
        }
        return LaneCounts(laneCount: laneCount, failedCount: failedCount, nonterminalCount: nonterminalCount)
    }

    /// Text of an MCP `content[]` envelope that carries no Oracle result keys of its own.
    private static func mcpContentText(_ object: [String: Any]) -> String? {
        guard let content = object["content"] as? [Any],
              object[Key.status] == nil,
              object[Key.results] == nil,
              object["error"] == nil,
              object[Key.errors] == nil,
              object["response"] == nil
        else {
            return nil
        }
        let texts = content.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            return nonEmptyTrimmed(block["text"] as? String)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func hasErrorValue(_ value: Any?) -> Bool {
        if let string = value as? String {
            return nonEmptyTrimmed(string) != nil
        }
        if let object = value as? [String: Any] {
            return nonEmptyTrimmed(string(object, keys: [Key.message])) != nil
                || structuredCode(object[Key.code]) != nil
        }
        return false
    }

    private static func hasNonEmptyErrors(_ value: Any?) -> Bool {
        guard let entries = value as? [Any] else { return false }
        return !entries.isEmpty
    }

    // MARK: - Field sanitizers

    /// A structured code: a string or integer field, never text-derived.
    private static func structuredCode(_ value: Any?) -> String? {
        if let string = value as? String {
            return nonEmptyTrimmed(string)
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    private static let codeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:/-"
    )
    private static let chatIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    /// Codes are identifiers: omitted (never truncated) when long or not identifier-shaped.
    static func sanitizedCode(_ raw: String?) -> String? {
        guard let code = nonEmptyTrimmed(raw),
              code.utf8.count <= codeMaxBytes,
              code.unicodeScalars.allSatisfy(codeCharacters.contains),
              OracleDiagnosticRedactor.redact(code) == code
        else {
            return nil
        }
        return code
    }

    static func sanitizedChatID(_ raw: String?) -> String? {
        guard let chatID = nonEmptyTrimmed(raw),
              chatID.utf8.count <= chatIDMaxBytes,
              chatID.unicodeScalars.allSatisfy(chatIDCharacters.contains)
        else {
            return nil
        }
        return chatID
    }

    private static func diagnosticObject(_ diagnostic: Diagnostic) -> [String: Any] {
        var object: [String: Any] = [Key.message: diagnostic.message]
        if let index = diagnostic.index {
            object[Key.index] = index
        }
        if let laneChatID = diagnostic.laneChatID {
            object[Key.laneChatID] = laneChatID
        }
        if let code = diagnostic.code {
            object[Key.code] = code
        }
        return object
    }

    // MARK: - JSON helpers

    /// Same serialization as the persistence policy (sorted keys), so byte bounds match storage.
    private static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isJSONValue(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func string(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func int(_ object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return number.intValue
            }
        }
        return nil
    }

    private static func bool(_ object: [String: Any]?, keys: [String]) -> Bool? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
        }
        return nil
    }
}

/// Oracle-local diagnostic scrubber (plan B2). No existing repository scrubber removes URL
/// userinfo and query/fragment values and strips control characters, so this one is minimal
/// and owned here. It removes bearer/authorization values, recognized API-key formats, and
/// secret-named assignments; strips URL userinfo and query/fragment values; and strips control
/// and format characters except newline and tab.
///
/// Every rule finds its sensitive ranges in the same text before anything is replaced, and each
/// run of overlapping or touching ranges becomes one placeholder. So no rule can erase a
/// delimiter another rule depends on: when URL userinfo contains an assignment or a quote, the
/// userinfo and everything the assignment covered are removed together. A pass repeats until
/// the text stops changing, which makes redaction idempotent.
///
/// A secret-named value that opens a quote (double, single, or JSON-escaped `\"` or `\'`) has
/// no extent the scrubber can trust. The quote may be unterminated, escaped, mismatched, broken
/// by a line, or closed by a later assignment's quote, and a backslash escape may hide a nested
/// key. So everything from the first such opening delimiter to the end of the diagnostic is
/// removed, and the delimiter is repeated after the placeholder unless another range removed
/// it. Unquoted values end at whitespace or a delimiter. URL userinfo runs from `://` to the
/// last `@` before whitespace, `/`, `?` or `#`, even across quotes.
///
/// A diagnostic longer than `maxScannedBytes` is never scanned: it becomes the placeholder whole,
/// before normalization or any regex runs, so unsanitized text is never truncated to fit. This
/// bounds the scanning work, which can be quadratic (URL scheme detection on dotted text).
/// Redaction also fails closed when matching fails internally (ICU's backtracking limit, which
/// no diagnostic within the bound has been found to reach) or the passes do not settle within
/// `maxPasses`. Callers redact the full text first and truncate afterwards, so a cut can never
/// split a token the scrubber would have recognized. Free-form provider text cannot be
/// guaranteed secret-free; field allowlisting and bounded retention are the primary protections.
enum OracleDiagnosticRedactor {
    static let placeholder = "<redacted>"
    /// The longest diagnostic, in UTF-8 bytes, that is scanned: eight times the 512-byte primary
    /// diagnostic that is persisted. A UTF-8 byte count is never smaller than the UTF-16 length
    /// the regexes scan, and normalization only removes characters.
    static let maxScannedBytes = 4096
    /// A second pass usually only confirms the first; a later pass removes what the rewritten
    /// text newly matches, such as a URL that now runs through a placeholder.
    private static let maxPasses = 8

    static func redact(_ text: String) -> String {
        guard text.utf8.count <= maxScannedBytes else { return placeholder }
        var current = strippingControlCharacters(text)
        for _ in 0 ..< maxPasses {
            guard let next = redactionPass(current) else { return placeholder }
            if next == current {
                return current
            }
            current = next
        }
        return placeholder
    }

    private struct Rule {
        let regex: NSRegularExpression
        /// The capture group holding the sensitive text; 0 is the whole match.
        let group: Int

        init(_ pattern: String, group: Int = 0) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.group = group
        }
    }

    /// Finds every sensitive range in `text` and replaces each merged run with one placeholder;
    /// `nil` when matching failed internally.
    private static func redactionPass(_ text: String) -> String? {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        guard let quotedValues = allMatches(of: quotedValueRegex, in: text) else { return nil }
        let quotedValue = quotedValues.first
        if let quotedValue {
            ranges.append(quotedValue.range(at: 4))
        }
        for rule in rules {
            guard let matches = allMatches(of: rule.regex, in: text) else { return nil }
            ranges += matches.map { $0.range(at: rule.group) }
        }
        guard let urls = allMatches(of: urlRegex, in: text) else { return nil }
        for url in urls {
            ranges += urlQueryAndFragmentRanges(of: url.range, in: nsText)
        }
        return rendering(nsText, removing: ranges, quotedValue: quotedValue)
    }

    private static func rendering(_ text: NSString, removing ranges: [NSRange], quotedValue: NSTextCheckingResult?) -> String {
        var runs: [NSRange] = []
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { $0.location < $1.location }
        for range in sorted {
            if let last = runs.last, range.location <= NSMaxRange(last) {
                runs[runs.count - 1] = NSUnionRange(last, range)
            } else {
                runs.append(range)
            }
        }
        var result = ""
        var cursor = 0
        for run in runs {
            result += text.substring(with: NSRange(location: cursor, length: run.location - cursor))
            result += placeholder
            cursor = NSMaxRange(run)
        }
        result += text.substring(from: cursor)
        // The quoted value runs to the end of the text; repeat its opening delimiter after it.
        if let quotedValue {
            let opener = quotedValue.range(at: 3)
            if !runs.contains(where: { NSIntersectionRange($0, opener).length > 0 }) {
                if quotedValue.range(at: 4).length == 0 {
                    result += placeholder
                }
                result += text.substring(with: opener)
            }
        }
        return result
    }

    /// Every match in source order, or `nil` when matching failed internally (for example, ICU's
    /// backtracking limit), which `NSRegularExpression` otherwise reports as no match.
    private static func allMatches(of regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult]? {
        var matches: [NSTextCheckingResult] = []
        var failed = false
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: .reportCompletion, range: range) { match, flags, _ in
            if flags.contains(.internalError) {
                failed = true
            }
            if let match {
                matches.append(match)
            }
        }
        return failed ? nil : matches
    }

    /// A secret-named key. It starts at a word start, so a long unbroken token is scanned once
    /// rather than from every position, and it must end at the secret word, so counters such as
    /// `max_output_tokens` are left intact.
    private static let secretKeyCore =
        #"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]*(?:api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|secret[_\-]?key|client[_\-]?secret|password|passwd|passphrase|secret|token|credentials?|cookie|authorization)(?:[_\-](?:value|string))?(?![A-Za-z0-9_\-])"#
    private static let secretKeyPattern = "(" + secretKeyCore + ")"
    /// The key's optional closing quote (plain or JSON-escaped) and the assignment.
    private static let assignmentPattern = #"((?:\\?["'])?\s*[:=]\s*)"#

    /// From the first secret-named value that opens a quote (`"`, `'`, `\"` or `\'`), everything
    /// is removed. Group 3 is the opening delimiter and group 4 the removed value.
    private static let quotedValueRegex = try! NSRegularExpression(
        pattern: "(?i)" + secretKeyPattern + assignmentPattern + #"(\\?["'])([\s\S]*)"#
    )

    private static let rules: [Rule] = [
        // Authorization header values, with or without a scheme word.
        Rule(
            #"(?i)\b((?:proxy-)?authorization)(["']?\s*[:=]\s*["']?)((?:(?:bearer|basic|token|digest|negotiate)\s+)?(?!<)[^\s"',;}\]]+)"#,
            group: 3
        ),
        // A credential, not an English word: it must contain a digit or a token symbol.
        Rule(#"(?i)\b(?:bearer|basic)\s+((?=[A-Za-z0-9._~+/=\-]*[0-9+/=])[A-Za-z0-9._~+/=\-]{6,})"#, group: 1),
        // Recognized API-key and token formats.
        Rule(#"sk-ant-[A-Za-z0-9_\-]{8,}"#),
        Rule(#"\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{16,}"#),
        Rule(#"\bAIza[0-9A-Za-z_\-]{30,}"#),
        Rule(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#),
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        Rule(#"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
        Rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16,}"#),
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        // Unquoted secret-named values (`api_key=…`, `token: …`). A value starting with a plain
        // or escaped quote belongs to `quotedValueRegex`.
        Rule("(?i)" + secretKeyPattern + assignmentPattern + #"((?!\\?["'])[^\s"',;&}\]]+)"#, group: 3),
        // URL userinfo, up to the last `@` of the authority. It is not cut at a quote, so a quote
        // inside a password cannot end it early.
        Rule(#"://([^\s/?#]*)@"#, group: 1)
    ]

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z][A-Za-z0-9+.\-]*://(?:[^\s"'<>]|<redacted>)+"#
    )

    /// The query values and the fragment of one URL, in the text's coordinates: a parameter's
    /// value after `=`, a parameter without `=` whole, and a non-empty fragment. Scheme, host,
    /// path, and parameter names stay readable.
    private static func urlQueryAndFragmentRanges(of url: NSRange, in text: NSString) -> [NSRange] {
        let separator = text.range(of: "://", options: .literal, range: url)
        guard separator.location != NSNotFound else { return [] }
        let restStart = NSMaxRange(separator)
        let urlEnd = NSMaxRange(url)
        var ranges: [NSRange] = []
        var queryEnd = urlEnd
        let hash = text.range(of: "#", options: .literal, range: NSRange(location: restStart, length: urlEnd - restStart))
        if hash.location != NSNotFound {
            if NSMaxRange(hash) < urlEnd {
                ranges.append(NSRange(location: NSMaxRange(hash), length: urlEnd - NSMaxRange(hash)))
            }
            queryEnd = hash.location
        }
        let question = text.range(of: "?", options: .literal, range: NSRange(location: restStart, length: queryEnd - restStart))
        guard question.location != NSNotFound else { return ranges }
        var parameterStart = NSMaxRange(question)
        while true {
            let ampersand = text.range(
                of: "&",
                options: .literal,
                range: NSRange(location: parameterStart, length: queryEnd - parameterStart)
            )
            let parameterEnd = ampersand.location == NSNotFound ? queryEnd : ampersand.location
            if parameterEnd > parameterStart {
                let parameter = NSRange(location: parameterStart, length: parameterEnd - parameterStart)
                let equals = text.range(of: "=", options: .literal, range: parameter)
                if equals.location == NSNotFound {
                    ranges.append(parameter)
                } else if NSMaxRange(equals) < parameterEnd {
                    ranges.append(NSRange(location: NSMaxRange(equals), length: parameterEnd - NSMaxRange(equals)))
                }
            }
            guard ampersand.location != NSNotFound else { break }
            parameterStart = NSMaxRange(ampersand)
        }
        return ranges
    }

    /// Normalizes line endings and strips control/format characters except newline and tab.
    private static func strippingControlCharacters(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if scalar == "\n" || scalar == "\t" {
                    scalars.append(scalar)
                }
            case .format, .lineSeparator, .paragraphSeparator:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
