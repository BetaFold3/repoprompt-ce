import Foundation

// MARK: - Qualification and input contracts

/// Monetary/token accounting contract under which an accumulator may mutate numeric state.
///
/// Production installs `productionClaude`, which is unqualified while installed-runtime gate G1
/// remains closed: live events are still routed through the accumulator for lifecycle bookkeeping
/// but can never change totals, checkpoints, coverage claims, or create records. Tests supply an
/// explicit `.qualified(contractID:)` fixture through the same API; production wiring never does.
enum AgentUsageQualification: Equatable {
    case unqualified
    case qualified(contractID: String)

    /// The only qualification production Claude wiring may select. G1 closed → unqualified.
    static var productionClaude: AgentUsageQualification {
        .unqualified
    }

    var contractID: String? {
        if case let .qualified(contractID) = self {
            return contractID
        }
        return nil
    }
}

/// Attribution of an observation to the live execution. Only `.live` can be charged; production
/// cannot establish it today (original-result markers, pending queues and first-after-dispatch
/// ordering are not proof), so it passes `.unverified`.
enum AgentUsageObservationAttribution: Equatable {
    case live
    case replay
    case synthetic
    case unverified
}

/// Known monetary baseline for a new execution segment.
enum AgentUsageSegmentBaseline: Equatable {
    /// A positively verified query-start contract: cumulative cost starts at zero.
    case verifiedZero
    /// Resume/reopen with unknown prior cumulative: first accepted amount is not charged.
    case unknown
}

struct AgentUsageObservationInput: Equatable {
    var observation: AgentProviderUsageObservation
    /// Raw cumulative provider-reported cost carried by the result, exact decimal.
    var reportedCost: Decimal?
    var executionID: UUID
    var turnID: UUID?
    var attribution: AgentUsageObservationAttribution
    /// Whether the delivering runtime proved this is the original (non-replayed) result payload.
    var hasOriginalResultAuthority: Bool

    init(
        observation: AgentProviderUsageObservation,
        reportedCost: Decimal? = nil,
        executionID: UUID,
        turnID: UUID?,
        attribution: AgentUsageObservationAttribution,
        hasOriginalResultAuthority: Bool = false
    ) {
        self.observation = observation
        self.reportedCost = reportedCost
        self.executionID = executionID
        self.turnID = turnID
        self.attribution = attribution
        self.hasOriginalResultAuthority = hasOriginalResultAuthority
    }

    /// Exact decimal from a provider-reported double. Uses the shortest round-trip text (which may
    /// use exponent notation for tiny or huge values), never a binary expansion; non-finite,
    /// negative, or unrepresentable values are unavailable.
    static func exactCost(fromReported cost: Double?) -> Decimal? {
        guard let cost, cost.isFinite, cost >= 0 else { return nil }
        let text = String(cost)
        guard let sourceCanonical = AgentProviderUsageJSONScanner.canonicalNumber(Array(text.utf8)) else {
            return nil
        }
        let parts = text.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let significand = Decimal(string: String(first)) else { return nil }
        let candidate: Decimal
        if parts.count == 2 {
            var exponentText = String(parts[1])
            if exponentText.hasPrefix("+") {
                exponentText.removeFirst()
            }
            guard let exponent = Int(exponentText) else { return nil }
            candidate = Decimal(sign: .plus, exponent: exponent, significand: significand)
        } else {
            candidate = significand
        }
        guard candidate.isFinite,
              let encoded = try? JSONEncoder().encode(candidate),
              AgentProviderUsageJSONScanner.canonicalNumber([UInt8](encoded)) == sourceCanonical
        else {
            return nil
        }
        return candidate
    }
}

// MARK: - Outcomes and projections

enum AgentUsageIngestRejection: Equatable {
    case unqualifiedContract
    case ineligibleOwner
    case disposedExecution
    case unregisteredTurn
    case unverifiedAttribution
    case replayedOrSynthetic
    case missingResultAuthority
    case unidentifiedObservation
    case duplicateResult
    case crossedResetBoundary
    case unexplainedDecrease
    case segmentSuspended
    case invalidCost
}

enum AgentUsageIngestOutcome: Equatable {
    case accepted
    /// The authoritative result's token totals and identity were accepted, but its monetary
    /// checkpoint was rejected for the given reason (token and money contracts are independent).
    case acceptedWithMonetaryRejection(AgentUsageIngestRejection)
    case rejected(AgentUsageIngestRejection)
}

enum AgentUsageEligibility: Equatable {
    case eligible
    case opaquePersistedValue
    case foreignOrigin(UUID)
}

struct AgentUsageCacheHitShare: Equatable {
    /// `sum(cache read) / sum(uncached input + cache read + cache creation)` over validated turns.
    var ratio: Decimal
    var coverage: AgentProviderUsageRecord.Coverage
}

struct AgentUsageCostEstimate: Equatable {
    var amount: Decimal
    var currency: String
    var coverage: AgentProviderUsageRecord.Coverage
}

// MARK: - Accumulator

/// Owner-keyed accounting state for one persistent Agent Mode session.
///
/// Lifecycle: `beginExecution` → `registerTurn` (at actual provider dispatch) → `observe` →
/// `closeTurn` / `endExecution`. Every numeric mutation requires a qualified contract, an eligible
/// owner, an active execution, a registered turn, live attribution and (for results) original
/// authority. Rejected inputs never change persisted accounting. The accumulator is a value type
/// kept under its session owner's isolation; there is no separate mutation queue.
///
/// Hydration normalization: under a qualified contract, a record restored with lifecycle state
/// still `.open` (a save that happened mid-execution before a crash) has those turns retired as
/// interrupted/partial and those segments closed as partial. Accepted amounts and identities are
/// never changed by this, and it is not counted as an owned mutation (`ownedRevision` stays 0).
/// Under an unqualified contract the hydrated record is returned exactly as loaded.
struct AgentUsageAccumulator: Equatable {
    static let claudeProviderName = "claude"
    static let claudeCurrency = "USD"
    static let restoredWithoutTerminalResultDiagnostic = "restored without terminal result"

    let ownerSessionID: UUID
    let qualification: AgentUsageQualification
    private(set) var eligibility: AgentUsageEligibility
    private(set) var hydratedPersist: AgentProviderUsagePersist?
    private(set) var record: AgentProviderUsageRecord?
    /// Increments on every accepted mutation of `record`; hydration is refused once non-zero.
    private(set) var ownedRevision: UInt64 = 0
    private(set) var hasPriorHistory: Bool
    private(set) var activeExecutionID: UUID?
    private(set) var activeProviderSessionID: String?
    private var resetGeneration: Int = 0
    private var registeredTurnIDs: Set<UUID> = []
    /// In-memory per-turn request snapshots (never persisted), keyed by request identity.
    private var requestSnapshotsByTurn: [UUID: [String: AgentProviderUsageObservation]] = [:]
    private var acceptedResultIDs: Set<String> = []

    init(
        ownerSessionID: UUID,
        persisted: AgentProviderUsagePersist?,
        hasPriorHistory: Bool,
        qualification: AgentUsageQualification
    ) {
        self.ownerSessionID = ownerSessionID
        self.qualification = qualification
        self.hasPriorHistory = hasPriorHistory
        hydratedPersist = persisted
        eligibility = .eligible
        record = nil
        applyHydratedState(persisted)
    }

    /// Persisted representation for the next save. Absent stays absent; opaque and foreign values
    /// are returned exactly as hydrated. Raw persisted bytes stay authoritative until this owner
    /// holds a qualified view: unqualified accounting returns exactly what was loaded even for a
    /// supported record, while a qualified owner persists its validated (and, after a mid-run
    /// save, normalized) typed record.
    var persistedRepresentation: AgentProviderUsagePersist? {
        switch eligibility {
        case .eligible:
            if let record, case .qualified = qualification { return .record(record) }
            return hydratedPersist ?? record.map { .record($0) }
        case .opaquePersistedValue, .foreignOrigin:
            return hydratedPersist
        }
    }

    // MARK: Hydration

    /// Applies persisted state loaded after construction. Refused when this owner already holds
    /// newer accepted mutations, so a late hydration cannot overwrite live state.
    @discardableResult
    mutating func applyHydration(_ persisted: AgentProviderUsagePersist?, hasPriorHistory: Bool) -> Bool {
        guard ownedRevision == 0 else { return false }
        hydratedPersist = persisted
        self.hasPriorHistory = hasPriorHistory
        record = nil
        eligibility = .eligible
        applyHydratedState(persisted)
        return true
    }

    private mutating func applyHydratedState(_ persisted: AgentProviderUsagePersist?) {
        // Identity derived from a previous hydration must not leak into this one.
        acceptedResultIDs.removeAll()
        resetGeneration = 0
        switch persisted {
        case nil:
            break
        case let .opaque(raw)?:
            // Raw bytes stay authoritative; a validated lossless v1 view may still seed accounting.
            guard let hydrated = raw.losslessRecord() else {
                eligibility = .opaquePersistedValue
                return
            }
            restoreHydratedRecord(hydrated)
        case let .record(hydrated)?:
            restoreHydratedRecord(hydrated)
        }
    }

    private mutating func restoreHydratedRecord(_ hydrated: AgentProviderUsageRecord) {
        guard hydrated.originSessionID == ownerSessionID else {
            eligibility = .foreignOrigin(hydrated.originSessionID)
            return
        }
        var restored = hydrated
        if case .qualified = qualification {
            Self.retireAbandonedLifecycleState(in: &restored)
        }
        record = restored
        acceptedResultIDs = Set(restored.turns.compactMap(\.acceptedResultID))
        resetGeneration = restored.claudeSegments.map(\.resetGeneration).max() ?? 0
    }

    /// Crash/mid-run persisted state has no live execution behind it any more: retire it as
    /// explicitly incomplete without touching accepted amounts or identities.
    private static func retireAbandonedLifecycleState(in record: inout AgentProviderUsageRecord) {
        for index in record.turns.indices where record.turns[index].outcome == .open {
            record.turns[index].outcome = .interrupted
            record.turns[index].coverage = .partial
            record.turns[index].diagnostic = restoredWithoutTerminalResultDiagnostic
        }
        for index in record.claudeSegments.indices where record.claudeSegments[index].state == .open {
            record.claudeSegments[index].state = .closed
            record.claudeSegments[index].coverage = .partial
        }
    }

    // MARK: Lifecycle identity

    /// Registers a fresh execution (native process/query) identity. Any previous execution is
    /// disposed and its open segment closed. Identity is tracked regardless of qualification;
    /// numeric state is only materialized under a qualified contract.
    mutating func beginExecution(
        executionID: UUID,
        providerSessionID: String?,
        baseline: AgentUsageSegmentBaseline,
        at now: Date
    ) {
        if activeExecutionID != nil {
            endExecution(activeExecutionID, outcome: .interrupted)
        }
        activeExecutionID = executionID
        activeProviderSessionID = providerSessionID
        registeredTurnIDs.removeAll()
        requestSnapshotsByTurn.removeAll()
        guard canMutate else { return }
        materializeRecordIfNeeded(at: now)
        openSegment(baseline: baseline)
    }

    /// Ends the given execution. Open turns become interrupted/partial; the open segment closes,
    /// partial when dispatched work after its latest accepted checkpoint has no monetary coverage.
    mutating func endExecution(_ executionID: UUID?, outcome: AgentProviderUsageRecord.TurnOutcome = .interrupted) {
        guard let executionID, executionID == activeExecutionID else { return }
        if canMutate, record != nil {
            for turnID in registeredTurnIDs {
                closeTurnUnchecked(turnID, outcome: outcome)
            }
            if let index = openSegmentIndex {
                closeSegment(at: index)
                bumpRevision()
            }
        }
        activeExecutionID = nil
        activeProviderSessionID = nil
        registeredTurnIDs.removeAll()
        requestSnapshotsByTurn.removeAll()
    }

    /// Records a positively verified reset boundary: closes the open segment and opens a new one
    /// with a verified zero baseline. Counter drops, compaction and MCP epoch changes are not resets.
    /// Outstanding turns stay bound to their original segment; their later results retain token
    /// identity but cannot attribute a monetary checkpoint across the closed reset boundary.
    @discardableResult
    mutating func noteVerifiedReset(executionID: UUID) -> AgentUsageIngestOutcome {
        if let rejection = mutationRejection { return .rejected(rejection) }
        guard executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        guard record != nil else { return .rejected(.ineligibleOwner) }
        if let index = openSegmentIndex {
            closeSegment(at: index)
        }
        resetGeneration += 1
        openSegment(baseline: .verifiedZero)
        return .accepted
    }

    /// Registers a provider-bound turn at actual dispatch. Rejected for disposed executions.
    /// Re-registering an already registered turn is idempotent and keeps its in-flight snapshots.
    @discardableResult
    mutating func registerTurn(_ turnID: UUID, executionID: UUID) -> AgentUsageIngestOutcome {
        guard executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        let alreadyRegistered = registeredTurnIDs.contains(turnID)
        registeredTurnIDs.insert(turnID)
        if !alreadyRegistered {
            requestSnapshotsByTurn[turnID] = [:]
        }
        if let rejection = mutationRejection { return .rejected(rejection) }
        guard record != nil else { return .rejected(.ineligibleOwner) }
        guard !alreadyRegistered else { return .accepted }
        let segmentIndex = currentSegmentIndex ?? max(0, (record?.claudeSegments.count ?? 1) - 1)
        let turn = AgentProviderUsageRecord.TurnSummary(
            executionID: executionID,
            segmentIndex: segmentIndex,
            turnID: turnID,
            outcome: .open,
            coverage: .unavailable
        )
        record?.turns.append(turn)
        bumpRevision()
        return .accepted
    }

    /// Closes a registered turn that ended without (or after) an authoritative result.
    @discardableResult
    mutating func closeTurn(_ turnID: UUID, outcome: AgentProviderUsageRecord.TurnOutcome) -> AgentUsageIngestOutcome {
        guard registeredTurnIDs.contains(turnID) else { return .rejected(.unregisteredTurn) }
        registeredTurnIDs.remove(turnID)
        guard canMutate, record != nil else {
            requestSnapshotsByTurn.removeValue(forKey: turnID)
            return .rejected(mutationRejection ?? .ineligibleOwner)
        }
        closeTurnUnchecked(turnID, outcome: outcome)
        return .accepted
    }

    // MARK: Observation

    /// Ingests one provider observation. Request-scope observations are snapshot upserts kept in
    /// memory; an accepted authoritative result replaces the turn subtotal and records its
    /// identity, and independently advances the cumulative monetary checkpoint when eligible.
    @discardableResult
    mutating func observe(_ input: AgentUsageObservationInput) -> AgentUsageIngestOutcome {
        guard case .qualified = qualification else { return .rejected(.unqualifiedContract) }
        guard eligibility == .eligible else { return .rejected(.ineligibleOwner) }
        guard input.executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        switch input.attribution {
        case .live: break
        case .replay, .synthetic: return .rejected(.replayedOrSynthetic)
        case .unverified: return .rejected(.unverifiedAttribution)
        }
        let observation = input.observation
        // A re-delivered accepted result identity is a duplicate even after its turn finalized.
        if observation.source == .result,
           let resultID = observation.envelopeID ?? observation.requestID,
           acceptedResultIDs.contains(resultID)
        {
            return .rejected(.duplicateResult)
        }
        guard let turnID = input.turnID, registeredTurnIDs.contains(turnID) else {
            return .rejected(.unregisteredTurn)
        }
        guard record != nil else { return .rejected(.ineligibleOwner) }

        switch observation.source {
        case .messageStart, .messageDelta, .assistant:
            guard let key = observation.requestID ?? observation.envelopeID else {
                return .rejected(.unidentifiedObservation)
            }
            let merged = Self.merge(existing: requestSnapshotsByTurn[turnID]?[key], with: observation)
            requestSnapshotsByTurn[turnID, default: [:]][key] = merged
            return .accepted
        case .result:
            guard input.hasOriginalResultAuthority else { return .rejected(.missingResultAuthority) }
            guard let resultID = observation.envelopeID ?? observation.requestID else {
                return .rejected(.unidentifiedObservation)
            }
            var monetaryRejection: AgentUsageIngestRejection?
            if let cost = input.reportedCost {
                if !cost.isFinite || cost < 0 {
                    monetaryRejection = .invalidCost
                } else if case let .rejected(reason) = acceptCumulativeCost(
                    cost,
                    resultID: resultID,
                    turnID: turnID
                ) {
                    monetaryRejection = reason
                }
            }
            acceptedResultIDs.insert(resultID)
            finalizeTurn(
                turnID,
                with: observation,
                resultID: resultID,
                monetaryDiagnostic: monetaryRejection.map { "monetary checkpoint rejected: \($0)" }
            )
            bumpRevision()
            if let monetaryRejection {
                return .acceptedWithMonetaryRejection(monetaryRejection)
            }
            return .accepted
        }
    }

    // MARK: Projections

    /// Token-weighted cache-hit share over turns with complete main-loop input triples.
    /// A zero denominator or an overflowing sum is unavailable (`nil`).
    var cacheHitShare: AgentUsageCacheHitShare? {
        guard let record else { return nil }
        var read: Int64 = 0
        var denominator: Int64 = 0
        var contributingTurns = 0
        var excludedTurns = 0
        for turn in record.turns where turn.outcome != .open {
            guard let input = turn.inputTokens,
                  let cacheRead = turn.cacheReadInputTokens,
                  let cacheCreation = turn.cacheCreationInputTokens,
                  input >= 0, cacheRead >= 0, cacheCreation >= 0
            else {
                excludedTurns += 1
                continue
            }
            let (partial, overflow1) = input.addingReportingOverflow(cacheRead)
            let (total, overflow2) = partial.addingReportingOverflow(cacheCreation)
            let (nextDenominator, overflow3) = denominator.addingReportingOverflow(total)
            let (nextRead, overflow4) = read.addingReportingOverflow(cacheRead)
            guard !overflow1, !overflow2, !overflow3, !overflow4 else { return nil }
            denominator = nextDenominator
            read = nextRead
            contributingTurns += 1
        }
        guard contributingTurns > 0, denominator > 0 else { return nil }
        let complete = excludedTurns == 0 && !record.hasUnmeasuredHistory
            && record.turns.allSatisfy { $0.outcome == .open || $0.coverage == .complete }
        return .init(
            ratio: Decimal(read) / Decimal(denominator),
            coverage: complete ? .complete : .partial
        )
    }

    /// Sum of disjoint owned segment contributions (`latest accepted cumulative − baseline`).
    var sessionCostEstimate: AgentUsageCostEstimate? {
        guard let record else { return nil }
        var total = Decimal(0)
        var contributing = 0
        var partial = record.hasUnmeasuredHistory
        for segment in record.claudeSegments {
            if let contribution = segment.contribution {
                total += contribution
                contributing += 1
            }
            if segment.coverage != .complete || segment.state == .suspended {
                partial = true
            }
        }
        guard contributing > 0 else { return nil }
        return .init(amount: total, currency: Self.claudeCurrency, coverage: partial ? .partial : .complete)
    }

    // MARK: - Private

    private var canMutate: Bool {
        mutationRejection == nil
    }

    /// Qualification is checked before owner eligibility.
    private var mutationRejection: AgentUsageIngestRejection? {
        guard case .qualified = qualification else { return .unqualifiedContract }
        guard eligibility == .eligible else { return .ineligibleOwner }
        return nil
    }

    /// Segment belonging to the active execution and current reset generation, in any state.
    /// Restored or disposed segments are never candidates.
    private var currentSegmentIndex: Int? {
        guard let activeExecutionID, let record else { return nil }
        return record.claudeSegments.lastIndex {
            $0.executionID == activeExecutionID && $0.resetGeneration == resetGeneration
        }
    }

    /// `currentSegmentIndex` when that segment is still open for monetary checkpoints.
    private var openSegmentIndex: Int? {
        guard let index = currentSegmentIndex, record?.claudeSegments[index].state == .open else { return nil }
        return index
    }

    private mutating func bumpRevision() {
        ownedRevision &+= 1
    }

    private mutating func materializeRecordIfNeeded(at now: Date) {
        guard record == nil else { return }
        record = .init(
            originSessionID: ownerSessionID,
            trackingStartedAt: now,
            hasUnmeasuredHistory: hasPriorHistory
        )
        bumpRevision()
    }

    private mutating func openSegment(baseline: AgentUsageSegmentBaseline) {
        guard let executionID = activeExecutionID, let contractID = qualification.contractID else { return }
        let segment = AgentProviderUsageRecord.ClaudeMonetarySegment(
            contractID: contractID,
            provider: Self.claudeProviderName,
            providerSessionID: activeProviderSessionID,
            executionID: executionID,
            resetGeneration: resetGeneration,
            baseline: baseline == .verifiedZero ? 0 : nil,
            latestCumulative: nil,
            currency: Self.claudeCurrency,
            acceptedResultID: nil,
            acceptedResultOrder: 0,
            state: .open,
            coverage: baseline == .verifiedZero ? .complete : .partial
        )
        record?.claudeSegments.append(segment)
        if baseline == .unknown {
            record?.hasUnmeasuredHistory = true
        }
        bumpRevision()
    }

    /// Closes a segment. Dispatched work after the latest accepted cumulative checkpoint (or with
    /// no checkpoint at all) has no monetary coverage, so the segment becomes partial while its
    /// accepted amount is preserved. A later checkpoint accepted before closing covers earlier gaps.
    private mutating func closeSegment(at index: Int) {
        guard let record, record.claudeSegments.indices.contains(index) else { return }
        var segment = record.claudeSegments[index]
        segment.state = .closed
        if Self.segmentHasUncoveredWork(segment, at: index, in: record) {
            segment.coverage = .partial
        }
        self.record?.claudeSegments[index] = segment
    }

    private static func segmentHasUncoveredWork(
        _ segment: AgentProviderUsageRecord.ClaudeMonetarySegment,
        at index: Int,
        in record: AgentProviderUsageRecord
    ) -> Bool {
        let turns = record.turns.filter { $0.executionID == segment.executionID && $0.segmentIndex == index }
        guard !turns.isEmpty else { return false }
        if turns.contains(where: { $0.outcome == .open }) {
            return true
        }
        guard let acceptedResultID = segment.acceptedResultID,
              let coveredIndex = turns.lastIndex(where: { $0.acceptedResultID == acceptedResultID })
        else {
            return true
        }
        return coveredIndex < turns.count - 1
    }

    private mutating func acceptCumulativeCost(
        _ cost: Decimal,
        resultID: String,
        turnID: UUID
    ) -> AgentUsageIngestOutcome {
        guard let current = record,
              let turnSegmentIndex = current.turns.last(where: { $0.turnID == turnID })?.segmentIndex
        else {
            return .rejected(.unregisteredTurn)
        }
        guard let index = currentSegmentIndex else { return .rejected(.segmentSuspended) }
        guard turnSegmentIndex == index else {
            if current.claudeSegments.indices.contains(turnSegmentIndex) {
                record?.claudeSegments[turnSegmentIndex].coverage = .partial
            }
            return .rejected(.crossedResetBoundary)
        }
        guard current.claudeSegments[index].state == .open else { return .rejected(.segmentSuspended) }
        var segment = current.claudeSegments[index]
        if segment.baseline == nil {
            // Unknown resumed baseline: the first observed cumulative amount is not new spend.
            segment.baseline = cost
        }
        if let latest = segment.latestCumulative, cost < latest {
            segment.state = .suspended
            segment.coverage = .partial
            record?.claudeSegments[index] = segment
            return .rejected(.unexplainedDecrease)
        }
        segment.latestCumulative = cost
        segment.acceptedResultID = resultID
        segment.acceptedResultOrder += 1
        record?.claudeSegments[index] = segment
        return .accepted
    }

    private mutating func finalizeTurn(
        _ turnID: UUID,
        with result: AgentProviderUsageObservation,
        resultID: String,
        monetaryDiagnostic: String?
    ) {
        guard let current = record, let turnIndex = current.turns.lastIndex(where: { $0.turnID == turnID }) else { return }
        var turn = current.turns[turnIndex]
        let snapshots = requestSnapshotsByTurn[turnID] ?? [:]
        turn.acceptedResultID = resultID
        turn.observedRequestCount = snapshots.isEmpty ? nil : snapshots.count
        let hasResultCounts = result.inputTokens != nil || result.outputTokens != nil
            || result.cacheReadInputTokens != nil || result.cacheCreationInputTokens != nil
        var diagnostics: [String] = []
        if hasResultCounts {
            // Authoritative result totals replace, never add to, request subtotals.
            turn.inputTokens = result.inputTokens.map(Int64.init)
            turn.outputTokens = result.outputTokens.map(Int64.init)
            turn.cacheReadInputTokens = result.cacheReadInputTokens.map(Int64.init)
            turn.cacheCreationInputTokens = result.cacheCreationInputTokens.map(Int64.init)
            let complete = turn.inputTokens != nil && turn.cacheReadInputTokens != nil
                && turn.cacheCreationInputTokens != nil
            turn.coverage = complete ? .complete : .partial
            if !complete {
                diagnostics.append("result omitted input components")
            }
        } else {
            // Cost-only result: keep the clearly partial main-loop subtotal.
            Self.applySubtotal(from: snapshots, to: &turn)
            turn.coverage = .partial
            diagnostics.append("result carried no token counts")
        }
        if let monetaryDiagnostic {
            diagnostics.append(monetaryDiagnostic)
        }
        turn.diagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")
        turn.outcome = .completed
        record?.turns[turnIndex] = turn
        registeredTurnIDs.remove(turnID)
        requestSnapshotsByTurn.removeValue(forKey: turnID)
    }

    private mutating func closeTurnUnchecked(_ turnID: UUID, outcome: AgentProviderUsageRecord.TurnOutcome) {
        defer {
            registeredTurnIDs.remove(turnID)
            requestSnapshotsByTurn.removeValue(forKey: turnID)
        }
        guard let current = record,
              let turnIndex = current.turns.lastIndex(where: { $0.turnID == turnID }),
              current.turns[turnIndex].outcome == .open
        else { return }
        var turn = current.turns[turnIndex]
        let snapshots = requestSnapshotsByTurn[turnID] ?? [:]
        Self.applySubtotal(from: snapshots, to: &turn)
        turn.observedRequestCount = snapshots.isEmpty ? nil : snapshots.count
        turn.outcome = outcome == .open ? .interrupted : outcome
        turn.coverage = .partial
        turn.diagnostic = "turn closed without an authoritative result"
        record?.turns[turnIndex] = turn
        bumpRevision()
    }

    /// Partial main-loop subtotal from deduplicated request snapshots. A component is only
    /// available when every contributing request reported it; missing values are never treated
    /// as zero, so mixed-completeness requests cannot manufacture a usable cache triple.
    private static func applySubtotal(
        from snapshots: [String: AgentProviderUsageObservation],
        to turn: inout AgentProviderUsageRecord.TurnSummary
    ) {
        let mainLoop = snapshots.values.filter { $0.parentToolUseID == nil }
        guard !mainLoop.isEmpty else { return }
        turn.inputTokens = sum(mainLoop.map(\.inputTokens))
        turn.outputTokens = sum(mainLoop.map(\.outputTokens))
        turn.cacheReadInputTokens = sum(mainLoop.map(\.cacheReadInputTokens))
        turn.cacheCreationInputTokens = sum(mainLoop.map(\.cacheCreationInputTokens))
    }

    /// Sum that is unavailable when any contributor is missing or the total overflows.
    private static func sum(_ values: [Int?]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard let value else { return nil }
            let (next, overflow) = total.addingReportingOverflow(Int64(value))
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func merge(
        existing: AgentProviderUsageObservation?,
        with update: AgentProviderUsageObservation
    ) -> AgentProviderUsageObservation {
        guard let existing else { return update }
        return .init(
            source: update.source,
            inputTokens: update.inputTokens ?? existing.inputTokens,
            outputTokens: update.outputTokens ?? existing.outputTokens,
            cacheReadInputTokens: update.cacheReadInputTokens ?? existing.cacheReadInputTokens,
            cacheCreationInputTokens: update.cacheCreationInputTokens ?? existing.cacheCreationInputTokens,
            model: update.model ?? existing.model,
            envelopeID: update.envelopeID ?? existing.envelopeID,
            requestID: update.requestID ?? existing.requestID,
            parentToolUseID: update.parentToolUseID ?? existing.parentToolUseID,
            resultSubtype: update.resultSubtype ?? existing.resultSubtype,
            resultIsError: update.resultIsError ?? existing.resultIsError
        )
    }
}
