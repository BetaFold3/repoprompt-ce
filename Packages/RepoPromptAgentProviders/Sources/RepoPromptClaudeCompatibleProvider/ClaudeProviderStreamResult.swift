import Foundation

/// Optional-preserving raw usage observation parsed from one Claude SDK envelope.
///
/// This companion keeps what the provider actually reported, separately from the legacy
/// normalized `promptTokens`/`completionTokens`/`contextUsedTokens` projection:
/// - Every count is optional. Missing means "not reported"; it is never coerced to zero.
/// - Negative, fractional, boolean, non-finite or overflowing counts are unavailable (`nil`).
/// - Identity fields are copied from the raw envelope only when present. Nothing is inferred
///   from stream position or from a global "latest main message" slot.
/// - The Anthropic message id (`message.id`) is not duplicated here; the carrying
///   `ClaudeProviderStreamResult.contentMessageID` holds it for `usage`/result carriers.
/// - The raw cumulative cost stays on `ClaudeProviderStreamResult.cost`; it is not duplicated here.
public struct ClaudeProviderUsageObservation: Sendable, Equatable {
    /// Envelope that produced the observation.
    public enum Source: String, Sendable, Equatable {
        /// `stream_event` with `event.type == "message_start"`.
        case messageStart = "message_start"
        /// `stream_event` with `event.type == "message_delta"`.
        case messageDelta = "message_delta"
        /// Top-level `assistant`/`message` envelope carrying `message.usage`.
        case assistant
        /// Terminal `result` envelope carrying aggregate `usage`.
        case result
    }

    public let source: Source
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    /// Reported model (`message.model`) when the envelope carries one.
    public let model: String?
    /// Top-level SDK envelope `uuid` when present.
    public let envelopeID: String?
    /// Literal top-level `request_id` when present; distinct from `envelopeID` and `message.id`.
    public let requestID: String?
    /// Non-null `parent_tool_use_id` marks a sidechain/subagent observation.
    public let parentToolUseID: String?
    /// `result.subtype` (lower-cased, trimmed) for `.result` observations.
    public let resultSubtype: String?
    /// `result.is_error` for `.result` observations when reported.
    public let resultIsError: Bool?
    /// Literal `result_index` for `.result` observations: the provider's zero-based dispatch
    /// ordinal within its process. Transport evidence only; ownership is decided in core.
    public let resultIndex: Int?
    /// Literal `queued_turn_count` for `.result` observations when reported.
    public let queuedTurnCount: Int?

    public init(
        source: Source,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        model: String? = nil,
        envelopeID: String? = nil,
        requestID: String? = nil,
        parentToolUseID: String? = nil,
        resultSubtype: String? = nil,
        resultIsError: Bool? = nil,
        resultIndex: Int? = nil,
        queuedTurnCount: Int? = nil
    ) {
        self.source = source
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.model = model
        self.envelopeID = envelopeID
        self.requestID = requestID
        self.parentToolUseID = parentToolUseID
        self.resultSubtype = resultSubtype
        self.resultIsError = resultIsError
        self.resultIndex = resultIndex
        self.queuedTurnCount = queuedTurnCount
    }
}

/// Provider-owned stream/result DTO emitted by the Claude-compatible translator.
/// RepoPrompt core adapters map this to app-specific stream models.
public struct ClaudeProviderStreamResult: Sendable, Equatable {
    public static let lifecycleType = "lifecycle"

    public let type: String
    public let text: String?
    public let reasoning: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?
    public let toolName: String?
    public let toolArgs: String?
    public let toolOutput: String?
    public let toolInvocationID: UUID?
    public let toolResultJSON: String?
    public let toolArgsJSON: String?
    public let toolIsError: Bool?
    public let providerSessionID: String?
    public let stopReason: String?
    public let modelContextWindow: Int?
    public let contextUsedTokens: Int?
    /// For `content` results: provider chunk message id (unset by the Claude translator). For
    /// `usage` carriers only: the Anthropic `message.id` the observation belongs to (lane-resolved
    /// for `message_delta`), or `nil` when unidentified. Result `message_stop` carriers leave it nil.
    public let contentMessageID: String?
    /// Raw usage observation companion for `usage` and result `message_stop` results.
    public let usageObservation: ClaudeProviderUsageObservation?

    public init(
        type: String,
        text: String?,
        reasoning: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolOutput: String? = nil,
        toolInvocationID: UUID? = nil,
        toolResultJSON: String? = nil,
        toolArgsJSON: String? = nil,
        toolIsError: Bool? = nil,
        providerSessionID: String? = nil,
        stopReason: String? = nil,
        modelContextWindow: Int? = nil,
        contextUsedTokens: Int? = nil,
        contentMessageID: String? = nil,
        usageObservation: ClaudeProviderUsageObservation? = nil
    ) {
        self.type = type
        self.text = text
        self.reasoning = reasoning
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolOutput = toolOutput
        self.toolInvocationID = toolInvocationID
        self.toolResultJSON = toolResultJSON
        self.toolArgsJSON = toolArgsJSON
        self.toolIsError = toolIsError
        self.providerSessionID = providerSessionID
        self.stopReason = stopReason
        self.modelContextWindow = modelContextWindow
        self.contextUsedTokens = contextUsedTokens
        self.contentMessageID = contentMessageID
        self.usageObservation = usageObservation
    }
}
