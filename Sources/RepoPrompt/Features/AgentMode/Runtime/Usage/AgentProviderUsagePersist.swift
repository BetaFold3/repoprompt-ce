import Foundation

// MARK: - Raw persisted value

/// Exact bytes of the session envelope's `providerUsage` JSON value (plan §3.3 amendment).
///
/// This is the authoritative on-disk representation: numbers keep their original lexeme (any
/// significand length, any exponent), unknown members, nested member order and duplicate nested
/// keys all survive because the value is never reconstructed. Equality is byte equality. A typed
/// v1 view is derived on demand (`losslessRecord()`) and never replaces these bytes unless a
/// qualified accumulator mutation produces a new owned record.
struct AgentProviderUsageRawValue: Equatable {
    /// Exactly one syntactically valid JSON value with no surrounding whitespace.
    let data: Data

    static let null = AgentProviderUsageRawValue(unchecked: Data("null".utf8))

    /// Validates JSON syntax (numbers stay lexemes) and keeps the exact value bytes.
    init(validating data: Data) throws {
        self.data = try AgentProviderUsageJSONScanner.validatedValue(in: data)
    }

    init(validating text: String) throws {
        try self.init(validating: Data(text.utf8))
    }

    /// For scanner output that is already known to be exactly one validated value.
    init(unchecked data: Data) {
        self.data = data
    }

    var isNull: Bool {
        data == Self.null.data
    }

    var text: String {
        String(decoding: data, as: UTF8.self)
    }

    /// Validated v1 typed view, or `nil` when a typed projection would not reproduce these bytes.
    ///
    /// Projection requires all of: strict v1 decoding (unknown members anywhere reject), the v1
    /// semantic invariants (`AgentProviderUsageRecord.semanticViolation == nil`), and an exact
    /// lexeme-level comparison between the raw value and the re-encoded record. `Decimal` round-trip
    /// equality is never used as proof; a significand beyond `Decimal` precision or an exponent
    /// outside its range simply fails the comparison and the value stays opaque.
    func losslessRecord() -> AgentProviderUsageRecord? {
        guard let rawShape = AgentProviderUsageJSONScanner.shape(of: data) else { return nil }
        guard let record = try? JSONDecoder().decode(AgentProviderUsageRecord.self, from: data),
              record.semanticViolation == nil,
              let reencoded = try? JSONEncoder().encode(record),
              AgentProviderUsageJSONScanner.shape(of: reencoded) == rawShape
        else {
            return nil
        }
        return record
    }
}

// MARK: - Typed v1 record

/// Supported v1 accounting record. Decoding is strict: any unknown member at any level throws, so
/// a raw value carrying future members can never be silently narrowed to this type.
struct AgentProviderUsageRecord: Codable, Equatable {
    static let supportedSchemaVersion = 1
    static let supportedProviders: Set<String> = ["claude"]
    static let supportedCurrencies: Set<String> = ["USD"]

    enum Coverage: String, Codable, Equatable {
        case complete
        case partial
        case unavailable
    }

    enum TurnOutcome: String, Codable, Equatable {
        case open
        case completed
        case interrupted
    }

    enum SegmentState: String, Codable, Equatable {
        case open
        case closed
        case suspended
    }

    /// Identity-bearing per-turn summary. Request-level history is intentionally not persisted.
    struct TurnSummary: Codable, Equatable {
        var executionID: UUID
        var segmentIndex: Int
        var turnID: UUID
        var acceptedResultID: String?
        var inputTokens: Int64?
        var outputTokens: Int64?
        var cacheReadInputTokens: Int64?
        var cacheCreationInputTokens: Int64?
        var observedRequestCount: Int?
        var outcome: TurnOutcome
        var coverage: Coverage
        var diagnostic: String?

        init(
            executionID: UUID,
            segmentIndex: Int,
            turnID: UUID,
            acceptedResultID: String? = nil,
            inputTokens: Int64? = nil,
            outputTokens: Int64? = nil,
            cacheReadInputTokens: Int64? = nil,
            cacheCreationInputTokens: Int64? = nil,
            observedRequestCount: Int? = nil,
            outcome: TurnOutcome,
            coverage: Coverage,
            diagnostic: String? = nil
        ) {
            self.executionID = executionID
            self.segmentIndex = segmentIndex
            self.turnID = turnID
            self.acceptedResultID = acceptedResultID
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.observedRequestCount = observedRequestCount
            self.outcome = outcome
            self.coverage = coverage
            self.diagnostic = diagnostic
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case executionID, segmentIndex, turnID, acceptedResultID, inputTokens, outputTokens
            case cacheReadInputTokens, cacheCreationInputTokens, observedRequestCount, outcome, coverage, diagnostic
        }

        init(from decoder: Decoder) throws {
            try AgentProviderUsageStrictDecoding.rejectUnknownMembers(in: decoder, known: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            executionID = try container.decode(UUID.self, forKey: .executionID)
            segmentIndex = try container.decode(Int.self, forKey: .segmentIndex)
            turnID = try container.decode(UUID.self, forKey: .turnID)
            acceptedResultID = try container.decodeIfPresent(String.self, forKey: .acceptedResultID)
            inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens)
            outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens)
            cacheReadInputTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens)
            cacheCreationInputTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens)
            observedRequestCount = try container.decodeIfPresent(Int.self, forKey: .observedRequestCount)
            outcome = try container.decode(TurnOutcome.self, forKey: .outcome)
            coverage = try container.decode(Coverage.self, forKey: .coverage)
            diagnostic = try container.decodeIfPresent(String.self, forKey: .diagnostic)
        }
    }

    /// Claude cumulative provider-reported cost checkpoint for one (execution, reset generation).
    struct ClaudeMonetarySegment: Codable, Equatable {
        var contractID: String
        var provider: String
        var providerSessionID: String?
        var executionID: UUID
        var resetGeneration: Int
        var baseline: Decimal?
        var latestCumulative: Decimal?
        var currency: String
        var acceptedResultID: String?
        var acceptedResultOrder: Int
        var state: SegmentState
        var coverage: Coverage

        init(
            contractID: String,
            provider: String,
            providerSessionID: String?,
            executionID: UUID,
            resetGeneration: Int,
            baseline: Decimal?,
            latestCumulative: Decimal?,
            currency: String,
            acceptedResultID: String?,
            acceptedResultOrder: Int,
            state: SegmentState,
            coverage: Coverage
        ) {
            self.contractID = contractID
            self.provider = provider
            self.providerSessionID = providerSessionID
            self.executionID = executionID
            self.resetGeneration = resetGeneration
            self.baseline = baseline
            self.latestCumulative = latestCumulative
            self.currency = currency
            self.acceptedResultID = acceptedResultID
            self.acceptedResultOrder = acceptedResultOrder
            self.state = state
            self.coverage = coverage
        }

        /// Contribution of this segment to the session estimate, or `nil` when unknown.
        var contribution: Decimal? {
            guard let baseline, let latestCumulative else { return nil }
            return latestCumulative - baseline
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case contractID, provider, providerSessionID, executionID, resetGeneration, baseline
            case latestCumulative, currency, acceptedResultID, acceptedResultOrder, state, coverage
        }

        init(from decoder: Decoder) throws {
            try AgentProviderUsageStrictDecoding.rejectUnknownMembers(in: decoder, known: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contractID = try container.decode(String.self, forKey: .contractID)
            provider = try container.decode(String.self, forKey: .provider)
            providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
            executionID = try container.decode(UUID.self, forKey: .executionID)
            resetGeneration = try container.decode(Int.self, forKey: .resetGeneration)
            baseline = try container.decodeIfPresent(Decimal.self, forKey: .baseline)
            latestCumulative = try container.decodeIfPresent(Decimal.self, forKey: .latestCumulative)
            currency = try container.decode(String.self, forKey: .currency)
            acceptedResultID = try container.decodeIfPresent(String.self, forKey: .acceptedResultID)
            acceptedResultOrder = try container.decode(Int.self, forKey: .acceptedResultOrder)
            state = try container.decode(SegmentState.self, forKey: .state)
            coverage = try container.decode(Coverage.self, forKey: .coverage)
        }
    }

    var schemaVersion: Int
    var originSessionID: UUID
    /// Milliseconds since the Unix epoch; stored as an integer to keep persistence lossless.
    var trackingStartedAtMilliseconds: Int64
    var hasUnmeasuredHistory: Bool
    var turns: [TurnSummary]
    var claudeSegments: [ClaudeMonetarySegment]

    init(
        originSessionID: UUID,
        trackingStartedAt: Date,
        hasUnmeasuredHistory: Bool,
        turns: [TurnSummary] = [],
        claudeSegments: [ClaudeMonetarySegment] = []
    ) {
        schemaVersion = Self.supportedSchemaVersion
        self.originSessionID = originSessionID
        trackingStartedAtMilliseconds = Int64((trackingStartedAt.timeIntervalSince1970 * 1000).rounded())
        self.hasUnmeasuredHistory = hasUnmeasuredHistory
        self.turns = turns
        self.claudeSegments = claudeSegments
    }

    var trackingStartedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(trackingStartedAtMilliseconds) / 1000)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, originSessionID, trackingStartedAtMilliseconds, hasUnmeasuredHistory, turns, claudeSegments
    }

    init(from decoder: Decoder) throws {
        try AgentProviderUsageStrictDecoding.rejectUnknownMembers(in: decoder, known: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        originSessionID = try container.decode(UUID.self, forKey: .originSessionID)
        trackingStartedAtMilliseconds = try container.decode(Int64.self, forKey: .trackingStartedAtMilliseconds)
        hasUnmeasuredHistory = try container.decode(Bool.self, forKey: .hasUnmeasuredHistory)
        turns = try container.decode([TurnSummary].self, forKey: .turns)
        claudeSegments = try container.decode([ClaudeMonetarySegment].self, forKey: .claudeSegments)
    }

    // MARK: Semantic validation

    /// First violated v1 accounting invariant, or `nil` when the record is semantically valid.
    ///
    /// Persistence never repairs a violating record: the raw value stays opaque and is written back
    /// verbatim. Lifecycle states such as `.open` are valid persisted states (a mid-run save); the
    /// accumulator, not persistence, decides how to retire them.
    var semanticViolation: String? {
        guard schemaVersion == Self.supportedSchemaVersion else { return "unsupported schemaVersion \(schemaVersion)" }
        guard trackingStartedAtMilliseconds >= 0 else { return "negative trackingStartedAtMilliseconds" }

        var seenSegmentIdentities: Set<String> = []
        for (index, segment) in claudeSegments.enumerated() {
            guard !segment.contractID.isEmpty else { return "claudeSegments[\(index)] has an empty contractID" }
            guard Self.supportedProviders.contains(segment.provider) else {
                return "claudeSegments[\(index)] has unsupported provider '\(segment.provider)'"
            }
            guard Self.supportedCurrencies.contains(segment.currency) else {
                return "claudeSegments[\(index)] has unsupported currency '\(segment.currency)'"
            }
            guard segment.resetGeneration >= 0 else { return "claudeSegments[\(index)] has a negative resetGeneration" }
            guard segment.acceptedResultOrder >= 0 else { return "claudeSegments[\(index)] has a negative acceptedResultOrder" }
            if let baseline = segment.baseline {
                guard !baseline.isNaN, baseline >= 0 else { return "claudeSegments[\(index)] has an invalid baseline" }
            }
            if let latest = segment.latestCumulative {
                guard !latest.isNaN, latest >= 0 else { return "claudeSegments[\(index)] has an invalid latestCumulative" }
            }
            if let baseline = segment.baseline, let latest = segment.latestCumulative, latest < baseline {
                return "claudeSegments[\(index)] latestCumulative is below its baseline"
            }
            let identity = "\(segment.executionID.uuidString)#\(segment.resetGeneration)"
            guard seenSegmentIdentities.insert(identity).inserted else {
                return "claudeSegments[\(index)] duplicates execution/resetGeneration identity"
            }
        }

        var seenTurnIDs: Set<UUID> = []
        var seenAcceptedResultIDs: Set<String> = []
        var turnsBySegment: [Int: [TurnSummary]] = [:]
        for (index, turn) in turns.enumerated() {
            guard seenTurnIDs.insert(turn.turnID).inserted else { return "turns[\(index)] duplicates turnID" }
            if let acceptedResultID = turn.acceptedResultID,
               !seenAcceptedResultIDs.insert(acceptedResultID).inserted
            {
                return "turns[\(index)] duplicates acceptedResultID"
            }
            guard claudeSegments.indices.contains(turn.segmentIndex) else {
                return "turns[\(index)] references missing segmentIndex \(turn.segmentIndex)"
            }
            guard claudeSegments[turn.segmentIndex].executionID == turn.executionID else {
                return "turns[\(index)] executionID does not match its segment"
            }
            turnsBySegment[turn.segmentIndex, default: []].append(turn)
            for (label, value) in [
                ("inputTokens", turn.inputTokens),
                ("outputTokens", turn.outputTokens),
                ("cacheReadInputTokens", turn.cacheReadInputTokens),
                ("cacheCreationInputTokens", turn.cacheCreationInputTokens)
            ] {
                if let value, value < 0 { return "turns[\(index)] has a negative \(label)" }
            }
            if let count = turn.observedRequestCount, count < 0 { return "turns[\(index)] has a negative observedRequestCount" }
        }

        for (segmentIndex, segment) in claudeSegments.enumerated() {
            let segmentTurns = turnsBySegment[segmentIndex] ?? []
            if let acceptedResultID = segment.acceptedResultID,
               !segmentTurns.contains(where: { $0.acceptedResultID == acceptedResultID })
            {
                return "claudeSegments[\(segmentIndex)] acceptedResultID does not reference a turn in its execution/segment"
            }
            if segment.state == .closed, segment.coverage == .complete, !segmentTurns.isEmpty {
                guard segment.baseline != nil, segment.latestCumulative != nil else {
                    return "claudeSegments[\(segmentIndex)] complete coverage has no usable monetary checkpoint"
                }
                guard let acceptedResultID = segment.acceptedResultID,
                      segmentTurns.last?.acceptedResultID == acceptedResultID
                else {
                    return "claudeSegments[\(segmentIndex)] complete coverage does not cover its terminal turn"
                }
            }
        }
        return nil
    }

    /// JSON representability of the owned record (a `Decimal.nan` cannot be serialized).
    fileprivate var encodingViolation: String? {
        for (index, segment) in claudeSegments.enumerated() {
            if segment.baseline?.isNaN == true { return "claudeSegments[\(index)].baseline is NaN" }
            if segment.latestCumulative?.isNaN == true { return "claudeSegments[\(index)].latestCumulative is NaN" }
        }
        return nil
    }
}

private enum AgentProviderUsageStrictDecoding {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func rejectUnknownMembers(in decoder: Decoder, known: [some CodingKey]) throws {
        let knownNames = Set(known.map(\.stringValue))
        let probe = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = probe.allKeys.map(\.stringValue).first(where: { !knownNames.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "providerUsage v1 record has unknown member '\(unknown)'"
            ))
        }
    }
}

// MARK: - Preservation contract

/// Field-local preservation state for `AgentSession.providerUsage`.
///
/// - `record`: an owned typed record produced in-process by qualified accounting. It is serialized
///   from the typed value.
/// - `opaque`: raw persisted bytes, authoritative as loaded. They are written back verbatim through
///   `AgentSessionDataCodec` and never mutated by accounting. A validated v1 view may be derived
///   (`record`), but only a qualified accumulator mutation replaces the bytes with a typed record;
///   unqualified accounting always persists the original bytes.
///
/// Absence is represented by `nil` on the session and means "unavailable", not measured zero.
///
/// Direct `Codable` boundary: persisted session data must go through `AgentSessionDataCodec`,
/// which is the only path that captures and re-inserts raw bytes. Generic `Decoder`/`Encoder`
/// support is limited to the provably lossless subset — explicit `null` and strict, semantically
/// valid typed v1 records — and fails explicitly (never silently narrows, nulls or omits) outside it.
enum AgentProviderUsagePersist: Equatable {
    case record(AgentProviderUsageRecord)
    case opaque(AgentProviderUsageRawValue)

    /// Typed v1 view: the owned record, or the raw value's validated lossless projection.
    var record: AgentProviderUsageRecord? {
        switch self {
        case let .record(record):
            record
        case let .opaque(raw):
            raw.losslessRecord()
        }
    }

    /// Raw persisted bytes when this value was captured from disk.
    var rawValue: AgentProviderUsageRawValue? {
        if case let .opaque(raw) = self { return raw }
        return nil
    }

    /// Serialized JSON value for the envelope member. Throws instead of substituting any fallback.
    func encodedJSONValue(using encoder: JSONEncoder) throws -> Data {
        switch self {
        case let .record(record):
            if let violation = record.encodingViolation {
                throw EncodingError.invalidValue(record, .init(
                    codingPath: [],
                    debugDescription: "providerUsage record is not representable: \(violation)"
                ))
            }
            return try encoder.encode(record)
        case let .opaque(raw):
            return raw.data
        }
    }
}

extension AgentProviderUsagePersist: Codable {
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .opaque(.null)
            return
        }
        let record: AgentProviderUsageRecord
        do {
            record = try AgentProviderUsageRecord(from: decoder)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "providerUsage is outside the directly decodable lossless v1 subset; persisted session data must be decoded through AgentSessionDataCodec",
                underlyingError: error
            ))
        }
        if let violation = record.semanticViolation {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "providerUsage v1 record failed semantic validation (\(violation)); persisted session data must be decoded through AgentSessionDataCodec"
            ))
        }
        self = .record(record)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .record(record):
            if let violation = record.encodingViolation {
                throw EncodingError.invalidValue(record, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "providerUsage record is not representable: \(violation)"
                ))
            }
            try record.encode(to: encoder)
        case let .opaque(raw):
            guard raw.isNull else {
                throw EncodingError.invalidValue(raw, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "raw providerUsage bytes cannot be re-serialized through a generic Encoder; encode the session through AgentSessionDataCodec"
                ))
            }
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}
