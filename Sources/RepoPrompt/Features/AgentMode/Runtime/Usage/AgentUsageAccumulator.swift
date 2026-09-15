import Foundation

// MARK: - Qualification and input contracts

/// Monetary/token accounting policy under which an accumulator may mutate numeric state.
///
/// - `.unqualified`: live events are routed for lifecycle bookkeeping only and can never change
///   totals, checkpoints or coverage claims, nor create records (test/diagnostic policy).
/// - `.qualified(contractID:)`: explicit **test-only** fixture; every execution is qualified at
///   `beginExecution` under that contract. Production wiring never selects it.
/// - `.executionVerified`: production policy. Each execution is individually resolved through
///   `resolveExecutionQualification` from actual launch/runtime evidence
///   (`ClaudeNativeUsageContract`). Nothing materializes for an awaiting or blocked execution.
enum AgentUsageQualification: Equatable {
    case unqualified
    case qualified(contractID: String)
    case executionVerified

    /// The qualification production Claude wiring selects: every execution is verified from its
    /// own launch and runtime evidence (Oracle decision 2026-09-15, normal builds).
    static var productionClaude: AgentUsageQualification {
        .executionVerified
    }

    var contractID: String? {
        if case let .qualified(contractID) = self {
            return contractID
        }
        return nil
    }
}

/// Why an execution can never (or can no longer) charge accounting. Terminal for that launch.
enum AgentUsageExecutionBlockReason: Equatable {
    case unqualifiedContract
    case unsupportedRuntime(String)
    case unsupportedLaunchMode(String)
    case runtimeVersionConflict
    case attributionDesynchronized(String)
    case unsupportedCounterBoundary(String)
    case unsupportedQueueSemantics(String)
    case resultBeforeQualification

    var description: String {
        switch self {
        case .unqualifiedContract:
            "live accounting is not qualified for this build"
        case let .unsupportedRuntime(detail):
            "the installed runtime is not qualified (\(detail))"
        case let .unsupportedLaunchMode(detail):
            "this launch mode is not qualified (\(detail))"
        case .runtimeVersionConflict:
            "the runtime reported conflicting versions in one process"
        case let .attributionDesynchronized(detail):
            "dispatch/result ownership could not be proven (\(detail))"
        case let .unsupportedCounterBoundary(detail):
            "an unqualified counter boundary occurred (\(detail))"
        case let .unsupportedQueueSemantics(detail):
            "queue semantics are not qualified (\(detail))"
        case .resultBeforeQualification:
            "a result arrived before the runtime was qualified"
        }
    }
}

/// Per-execution authorization state. Only `.qualified` may materialize or mutate numeric state.
enum AgentUsageExecutionVerdict: Equatable {
    case awaiting
    case qualified(contractID: String, baseline: AgentUsageSegmentBaseline)
    case blocked(AgentUsageExecutionBlockReason)

    var isQualified: Bool {
        if case .qualified = self { return true }
        return false
    }

    var contractID: String? {
        if case let .qualified(contractID, _) = self { return contractID }
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
    /// The runtime's cumulative-cost cadence is not established for this execution (token
    /// observations only): no monetary checkpoint is ever accepted on its segment.
    case unsupported
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
    /// Runtime-established terminal outcome of the turn this result closes. `nil` means the
    /// runtime reported ordinary completion; an original cancellation/error result that still
    /// carries usage finalizes its turn as `.interrupted` while keeping its accepted totals.
    var terminalOutcome: AgentProviderUsageRecord.TurnOutcome?
    /// Native child (subagent) activity was observed for this turn. The parent's cumulative cost
    /// already includes it and is accepted once; the result's token triple is not provably
    /// main-loop scope, so it is excluded from the cache-hit share (turn coverage partial).
    var childActivityObserved: Bool

    init(
        observation: AgentProviderUsageObservation,
        reportedCost: Decimal? = nil,
        executionID: UUID,
        turnID: UUID?,
        attribution: AgentUsageObservationAttribution,
        hasOriginalResultAuthority: Bool = false,
        terminalOutcome: AgentProviderUsageRecord.TurnOutcome? = nil,
        childActivityObserved: Bool = false
    ) {
        self.observation = observation
        self.reportedCost = reportedCost
        self.executionID = executionID
        self.turnID = turnID
        self.attribution = attribution
        self.hasOriginalResultAuthority = hasOriginalResultAuthority
        self.terminalOutcome = terminalOutcome
        self.childActivityObserved = childActivityObserved
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
    /// The active execution has no qualified verdict yet (awaiting runtime evidence).
    case executionNotQualified
    /// The active execution is terminally blocked for accounting.
    case executionBlocked
    /// Production-shaped accounting is result-only: request-scope snapshots (message start/delta,
    /// assistant usage) are not attributed to turns under `.executionVerified` (plan §2.10).
    case requestScopeUnsupported
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
    /// The execution qualified for token observations only; cumulative cost is unavailable there.
    case monetaryScopeUnsupported
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

/// Live-only cache-hit measurement for the latest provider request. This is deliberately separate
/// from persisted turn/result aggregates: it is never encoded, hydrated, or used by session cost.
struct AgentUsageLatestRequestCacheHit: Equatable {
    enum Source: Hashable {
        case claudeAssistant
        case codexLast
    }

    var source: Source
    var executionID: UUID
    var turnID: String?
    var requestID: String?
    var share: AgentUsageCacheHitShare?
    /// Exact availability/coverage explanation derived from the counters or lifecycle event that
    /// produced this state. It must not guess at a historical cause.
    var detail: String
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
    static let childActivityDiagnostic = "native child activity: result usage is not separable main-loop scope and is excluded from the cache-hit share"

    let ownerSessionID: UUID
    let qualification: AgentUsageQualification
    private(set) var eligibility: AgentUsageEligibility
    private(set) var hydratedPersist: AgentProviderUsagePersist?
    /// Owned record; the Codex extension in `CodexUsageAccounting.swift` mutates it through the
    /// same revision bump, so the setter is module-visible rather than file-private.
    var record: AgentProviderUsageRecord?
    /// Increments on every accepted mutation of `record`; hydration is refused once non-zero.
    private(set) var ownedRevision: UInt64 = 0
    /// Increments only for live-only latest-request presentation changes. Callers combine it
    /// with `ownedRevision` to refresh CH without treating presentation as a persisted mutation.
    private(set) var presentationRevision: UInt64 = 0
    private(set) var hasPriorHistory: Bool
    private(set) var activeExecutionID: UUID?
    private(set) var activeProviderSessionID: String?
    /// Authorization state of the active execution; `nil` when no execution is active.
    private(set) var executionVerdict: AgentUsageExecutionVerdict?
    private var resetGeneration: Int = 0
    private var registeredTurnIDs: Set<UUID> = []
    /// Successful dispatches, in dispatch order, that were registered before the execution was
    /// qualified. They are backfilled as open turns exactly once when a qualified verdict lands.
    private var awaitingDispatchOrder: [UUID] = []
    /// Under `.executionVerified`, hydrated mid-run lifecycle state is left untouched until this
    /// owner performs its first owned materialization, at which point it is retired as interrupted.
    private var pendingHydratedRetirement = false
    /// In-memory per-turn request snapshots (never persisted), keyed by request identity.
    private var requestSnapshotsByTurn: [UUID: [String: AgentProviderUsageObservation]] = [:]
    /// Live latest-request readouts, isolated per provider and intentionally absent from persistence.
    /// Draining one provider can never clobber the other provider's current presentation.
    private var latestRequestCacheHitBySource: [AgentUsageLatestRequestCacheHit.Source: AgentUsageLatestRequestCacheHit] = [:]
    /// Every Claude request identity seen in this execution, including requests with no usage. The
    /// set stays execution-scoped so cross-turn replays remain rejected; only the current request's
    /// observation is retained, bounding counter-snapshot retention to one request.
    private var seenClaudeRequestIDs: Set<String> = []
    private var latestClaudeRequestID: String?
    private var latestClaudeRequestObservation: AgentProviderUsageObservation?
    private var acceptedResultIDs: Set<String> = []
    /// Codex counter-interval ownership (plan §4.1); intervals persist on the shared record.
    var codexState = CodexUsageAccountingState()

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
            // `.unqualified` can never own a mutation (`ownedRevision` stays 0), so hydrated raw
            // bytes remain authoritative there; only `.executionVerified` rewrites after owning one.
            if let record, ownedRevision > 0, case .executionVerified = qualification { return .record(record) }
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
        pendingHydratedRetirement = false
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
        switch qualification {
        case .qualified:
            Self.retireAbandonedLifecycleState(in: &restored, activeExecutionID: nil)
        case .executionVerified:
            // Hydrated bytes stay authoritative until an owned mutation rewrites the record.
            pendingHydratedRetirement = Self.hasAbandonedLifecycleState(restored)
        case .unqualified:
            break
        }
        record = restored
        acceptedResultIDs = Set(restored.turns.compactMap(\.acceptedResultID))
        resetGeneration = restored.claudeSegments.map(\.resetGeneration).max() ?? 0
    }

    /// Crash/mid-run persisted state has no live execution behind it any more: retire it as
    /// explicitly incomplete without touching accepted amounts or identities.
    private static func hasAbandonedLifecycleState(_ record: AgentProviderUsageRecord) -> Bool {
        record.turns.contains { $0.outcome == .open } || record.claudeSegments.contains { $0.state == .open }
    }

    /// Retires `.open` turns/segments that belong to a disposed execution. The active execution's
    /// own in-flight state (when retirement runs at its first owned mutation) is never touched.
    private static func retireAbandonedLifecycleState(
        in record: inout AgentProviderUsageRecord,
        activeExecutionID: UUID?
    ) {
        for index in record.turns.indices
            where record.turns[index].outcome == .open && record.turns[index].executionID != activeExecutionID
        {
            record.turns[index].outcome = .interrupted
            record.turns[index].coverage = .partial
            record.turns[index].diagnostic = restoredWithoutTerminalResultDiagnostic
        }
        for index in record.claudeSegments.indices
            where record.claudeSegments[index].state == .open && record.claudeSegments[index].executionID != activeExecutionID
        {
            record.claudeSegments[index].state = .closed
            record.claudeSegments[index].coverage = .partial
        }
    }

    // MARK: Lifecycle identity

    /// Registers a fresh execution (native process/query) identity with an immediately known
    /// baseline. Any previous execution is disposed and its open segment closed. Identity is
    /// tracked regardless of qualification; numeric state is only materialized when the execution
    /// is qualified: immediately under the test-only `.qualified` policy, never under
    /// `.unqualified`, and only after `resolveExecutionQualification` under `.executionVerified`
    /// (the supplied baseline is ignored there because the contract resolver owns it).
    mutating func beginExecution(
        executionID: UUID,
        providerSessionID: String?,
        baseline: AgentUsageSegmentBaseline,
        at now: Date
    ) {
        let verdict: AgentUsageExecutionVerdict = switch qualification {
        case let .qualified(contractID): .qualified(contractID: contractID, baseline: baseline)
        case .unqualified: .blocked(.unqualifiedContract)
        case .executionVerified: .awaiting
        }
        beginExecution(executionID: executionID, providerSessionID: providerSessionID, verdict: verdict, at: now)
    }

    /// Registers a fresh execution whose contract is not established yet. Dispatches registered
    /// while awaiting are retained in order and backfilled when the verdict becomes qualified.
    /// The test-only `.qualified` policy qualifies every execution at begin (unknown baseline,
    /// because the launch shape is not an accumulator input) exactly as `beginExecution` does.
    mutating func beginAwaitingExecution(
        executionID: UUID,
        providerSessionID: String?,
        at now: Date
    ) {
        let verdict: AgentUsageExecutionVerdict = switch qualification {
        case .unqualified: .blocked(.unqualifiedContract)
        case let .qualified(contractID): .qualified(contractID: contractID, baseline: .unknown)
        case .executionVerified: .awaiting
        }
        beginExecution(executionID: executionID, providerSessionID: providerSessionID, verdict: verdict, at: now)
    }

    private mutating func beginExecution(
        executionID: UUID,
        providerSessionID: String?,
        verdict: AgentUsageExecutionVerdict,
        at now: Date
    ) {
        if activeExecutionID != nil {
            endExecution(activeExecutionID, outcome: .interrupted)
        }
        resetLatestRequestCacheHit(source: .claudeAssistant)
        seenClaudeRequestIDs.removeAll()
        latestClaudeRequestID = nil
        latestClaudeRequestObservation = nil
        activeExecutionID = executionID
        activeProviderSessionID = providerSessionID
        executionVerdict = verdict
        registeredTurnIDs.removeAll()
        awaitingDispatchOrder.removeAll()
        requestSnapshotsByTurn.removeAll()
        guard case let .qualified(contractID, baseline) = verdict, canMutate else { return }
        materializeRecordIfNeeded(at: now)
        _ = openSegment(baseline: baseline, contractID: contractID)
    }

    /// Applies runtime evidence to the active execution. `.awaiting` → `.qualified` materializes
    /// the record, opens the segment and backfills still-open dispatches in their original order.
    /// `.awaiting` → `.blocked` and `.qualified` → `.blocked` are terminal for the launch: accepted
    /// amounts and identities are preserved, an open monetary segment is suspended as partial, and
    /// every later input for this execution is rejected. Verdicts never buffer results for later
    /// charging, and a blocked verdict is never lifted.
    @discardableResult
    mutating func resolveExecutionQualification(
        executionID: UUID,
        verdict: AgentUsageExecutionVerdict,
        at now: Date
    ) -> AgentUsageIngestOutcome {
        guard executionID == activeExecutionID, let current = executionVerdict else {
            return .rejected(.disposedExecution)
        }
        if case .unqualified = qualification {
            executionVerdict = .blocked(.unqualifiedContract)
            return .rejected(.unqualifiedContract)
        }
        switch (current, verdict) {
        case (.blocked, _):
            return .rejected(.executionBlocked)
        case (_, .awaiting):
            return current.isQualified ? .accepted : .rejected(.executionNotQualified)
        case let (.awaiting, .qualified(contractID, baseline)):
            executionVerdict = verdict
            guard eligibility == .eligible else { return .rejected(.ineligibleOwner) }
            materializeRecordIfNeeded(at: now)
            guard openSegment(baseline: baseline, contractID: contractID) else {
                awaitingDispatchOrder.removeAll()
                bumpRevision()
                return .rejected(.executionBlocked)
            }
            let backfill = awaitingDispatchOrder
            awaitingDispatchOrder.removeAll()
            for turnID in backfill where registeredTurnIDs.contains(turnID) {
                appendOpenTurn(turnID)
            }
            bumpRevision()
            return .accepted
        case (.qualified, .qualified):
            return .accepted
        case let (.awaiting, .blocked(reason)):
            blockAwaitingExecution(reason)
            return .rejected(.executionBlocked)
        case let (.qualified, .blocked(reason)):
            executionVerdict = .blocked(reason)
            markLatestClaudeRequestBlocked(reason)
            if canMutateRecord, let index = openSegmentIndex {
                record?.claudeSegments[index].state = .suspended
                if record?.claudeSegments[index].coverage != .unavailable {
                    record?.claudeSegments[index].coverage = .partial
                }
                bumpRevision()
            }
            return .rejected(.executionBlocked)
        }
    }

    /// Terminal block of an awaiting execution. Dispatched work it can never charge marks an
    /// existing owned record as carrying unmeasured history (an owned mutation); nothing is
    /// materialized for a session that has no record.
    private mutating func blockAwaitingExecution(_ reason: AgentUsageExecutionBlockReason) {
        executionVerdict = .blocked(reason)
        markLatestClaudeRequestBlocked(reason)
        let hadDispatches = !awaitingDispatchOrder.isEmpty || !registeredTurnIDs.isEmpty
        awaitingDispatchOrder.removeAll()
        guard hadDispatches else { return }
        markUnmeasuredHistoryForUnchargedDispatch()
    }

    private mutating func markLatestClaudeRequestBlocked(_ reason: AgentUsageExecutionBlockReason) {
        guard var latest = latestRequestCacheHit(for: .claudeAssistant) else { return }
        latest.share = nil
        latest.detail = "Unavailable: latest-request CH is not shown because \(reason.description)."
        setLatestRequestCacheHit(latest)
    }

    /// Provider-bound work was dispatched on an execution that can never account for it (blocked,
    /// or closed/ended while still awaiting its verdict): an owned record must say so rather than
    /// keep claiming complete coverage (plan §4, OracleB P1#5). Nothing is materialized for a
    /// session without a record.
    private mutating func markUnmeasuredHistoryForUnchargedDispatch() {
        guard record != nil, qualification != .unqualified, eligibility == .eligible,
              record?.hasUnmeasuredHistory == false
        else { return }
        record?.hasUnmeasuredHistory = true
        bumpRevision()
    }

    /// Human-readable explanation of why the active execution is not charging, or `nil` when it
    /// is qualified or no execution is active.
    var executionQualificationDiagnostic: String? {
        switch executionVerdict {
        case nil, .qualified?:
            nil
        case .awaiting?:
            "the runtime has not reported its version yet"
        case let .blocked(reason)?:
            reason.description
        }
    }

    /// Whether provider-bound work was dispatched on an execution that cannot charge it.
    var hasUnchargedDispatchedWork: Bool {
        guard let executionVerdict, !executionVerdict.isQualified else { return false }
        return !registeredTurnIDs.isEmpty || !awaitingDispatchOrder.isEmpty
    }

    /// Explains why the active execution records token observations but no cumulative cost, or
    /// `nil` when cost is tracked (or no execution is active).
    var monetaryScopeDiagnostic: String? {
        guard let contractID = executionVerdict?.contractID,
              let index = currentSegmentIndex,
              record?.claudeSegments[index].coverage == .unavailable
        else { return nil }
        let version = ClaudeNativeUsageContract.isTokensOnlyContractID(contractID)
            ? String(contractID.dropFirst(ClaudeNativeUsageContract.tokensOnlyContractPrefix.count))
            : contractID
        return "provider-reported cost is not established for claude_code_version \(version); only token usage is counted"
    }

    /// Number of finalized turns whose result usage was excluded because native child activity
    /// made its main-loop scope unprovable.
    var childActivityTurnCount: Int {
        record?.turns.count(where: { $0.outcome != .open && $0.diagnostic?.contains(Self.childActivityDiagnostic) == true }) ?? 0
    }

    /// Ends the given execution. Open turns become interrupted/partial; the open segment closes,
    /// partial when dispatched work after its latest accepted checkpoint has no monetary coverage.
    mutating func endExecution(_ executionID: UUID?, outcome: AgentProviderUsageRecord.TurnOutcome = .interrupted) {
        guard let executionID, executionID == activeExecutionID else { return }
        if case .awaiting? = executionVerdict, !registeredTurnIDs.isEmpty || !awaitingDispatchOrder.isEmpty {
            // The execution ended (crash, EOF, teardown) before its verdict: dispatched turns can
            // never be measured, so coverage is explicitly incomplete.
            markUnmeasuredHistoryForUnchargedDispatch()
        }
        if canMutateRecord, record != nil {
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
        executionVerdict = nil
        registeredTurnIDs.removeAll()
        awaitingDispatchOrder.removeAll()
        requestSnapshotsByTurn.removeAll()
        seenClaudeRequestIDs.removeAll()
        latestClaudeRequestID = nil
        latestClaudeRequestObservation = nil
        resetLatestRequestCacheHit(source: .claudeAssistant)
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
        guard let contractID = executionVerdict?.contractID else { return .rejected(.executionNotQualified) }
        guard openSegment(baseline: .verifiedZero, contractID: contractID) else { return .rejected(.executionBlocked) }
        return .accepted
    }

    /// Registers a provider-bound turn at actual dispatch. Rejected for disposed executions.
    /// Re-registering an already registered turn is idempotent and keeps its in-flight snapshots.
    /// While the execution is awaiting its verdict the dispatch is retained in order and accepted
    /// provisionally; a blocked execution registers identity only and marks existing accounting
    /// as carrying unmeasured history.
    @discardableResult
    mutating func registerTurn(_ turnID: UUID, executionID: UUID) -> AgentUsageIngestOutcome {
        guard executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        // The production gate never touches persisted accounting, not even coverage flags: the
        // hydrated representation and `ownedRevision == 0` must survive every dispatch.
        guard qualification != .unqualified else { return .rejected(.unqualifiedContract) }
        let alreadyRegistered = registeredTurnIDs.contains(turnID)
        // Re-delivered dispatch evidence for a turn this execution already finalized (a controller
        // resubscription bootstraps its new subscriber with the current launch's evidence): not a
        // new dispatch, so no second summary is opened (review R2, OracleA P1#3).
        if !alreadyRegistered,
           record?.turns.contains(where: { $0.executionID == executionID && $0.turnID == turnID && $0.outcome != .open }) == true
        {
            return .accepted
        }
        registeredTurnIDs.insert(turnID)
        if !alreadyRegistered {
            requestSnapshotsByTurn[turnID] = [:]
            latestClaudeRequestID = nil
            latestClaudeRequestObservation = nil
            setLatestRequestCacheHit(.init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: nil,
                share: nil,
                detail: Self.latestClaudeAwaitingUsageDetail
            ))
        }
        if let rejection = mutationRejection {
            switch executionVerdict {
            case .awaiting? where eligibility == .eligible:
                if !awaitingDispatchOrder.contains(turnID) {
                    awaitingDispatchOrder.append(turnID)
                }
                return .accepted
            case let .blocked(reason)?:
                markLatestClaudeRequestBlocked(reason)
                if !alreadyRegistered, record != nil, eligibility == .eligible,
                   record?.hasUnmeasuredHistory == false
                {
                    record?.hasUnmeasuredHistory = true
                    bumpRevision()
                }
                return .rejected(rejection)
            default:
                return .rejected(rejection)
            }
        }
        guard record != nil else { return .rejected(.ineligibleOwner) }
        guard !alreadyRegistered else { return .accepted }
        appendOpenTurn(turnID)
        bumpRevision()
        return .accepted
    }

    private mutating func appendOpenTurn(_ turnID: UUID) {
        guard let executionID = activeExecutionID else { return }
        let segmentIndex = currentSegmentIndex ?? max(0, (record?.claudeSegments.count ?? 1) - 1)
        let turn = AgentProviderUsageRecord.TurnSummary(
            executionID: executionID,
            segmentIndex: segmentIndex,
            turnID: turnID,
            outcome: .open,
            coverage: .unavailable
        )
        record?.turns.append(turn)
    }

    /// Closes a registered turn that ended without (or after) an authoritative result. Lifecycle
    /// retirement of a summary created while qualified is allowed even after the execution was
    /// blocked (no blocked usage is accepted; the summary just stops being `.open`).
    @discardableResult
    mutating func closeTurn(_ turnID: UUID, outcome: AgentProviderUsageRecord.TurnOutcome) -> AgentUsageIngestOutcome {
        guard registeredTurnIDs.contains(turnID) else { return .rejected(.unregisteredTurn) }
        registeredTurnIDs.remove(turnID)
        awaitingDispatchOrder.removeAll { $0 == turnID }
        if case .awaiting? = executionVerdict {
            // Closed (interrupted/failed) before the verdict arrived: this turn will never be
            // backfilled or measured.
            markUnmeasuredHistoryForUnchargedDispatch()
        }
        guard canMutateRecord else {
            requestSnapshotsByTurn.removeValue(forKey: turnID)
            return .rejected(mutationRejection ?? .ineligibleOwner)
        }
        closeTurnUnchecked(turnID, outcome: outcome)
        if var latest = latestRequestCacheHit(for: .claudeAssistant),
           latest.turnID == turnID.uuidString,
           latest.detail == Self.latestClaudeAwaitingUsageDetail
        {
            latest.detail = "Unavailable: the latest Claude turn ended without a main-loop assistant usage report."
            setLatestRequestCacheHit(latest)
        }
        return .accepted
    }

    // MARK: Latest-request presentation

    private static let latestClaudeAwaitingUsageDetail =
        "Unavailable: the latest Claude turn has not reported main-loop assistant usage yet."

    /// Accepts only a live, execution-bound, registered main-line assistant request. The caller
    /// supplies the Anthropic message ID rather than the envelope UUID because one API request may
    /// be repeated across multiple assistant content/tool chunks. This state never feeds the
    /// persisted turn subtotal or cumulative cost checkpoint.
    @discardableResult
    mutating func observeLatestClaudeRequest(
        observation: AgentProviderUsageObservation?,
        requestID: String?,
        executionID: UUID,
        turnID: UUID
    ) -> AgentUsageIngestOutcome {
        guard qualification != .unqualified else { return .rejected(.unqualifiedContract) }
        guard eligibility == .eligible else { return .rejected(.ineligibleOwner) }
        guard executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        guard case .qualified? = executionVerdict else {
            if case let .blocked(reason)? = executionVerdict {
                markLatestClaudeRequestBlocked(reason)
            }
            return .rejected(executionVerdict == nil ? .disposedExecution : .executionNotQualified)
        }
        guard registeredTurnIDs.contains(turnID) else { return .rejected(.unregisteredTurn) }
        if let observation {
            guard observation.source == .assistant, observation.parentToolUseID == nil else {
                return .rejected(.unverifiedAttribution)
            }
        }

        guard let identity = requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty
        else {
            latestClaudeRequestID = nil
            latestClaudeRequestObservation = nil
            setLatestRequestCacheHit(.init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: nil,
                share: nil,
                detail: "Unavailable: the latest main-loop Claude assistant event had no stable message identity, so it cannot be treated as current request usage."
            ))
            return .rejected(.unidentifiedObservation)
        }

        if latestClaudeRequestID == identity {
            if let observation {
                latestClaudeRequestObservation = latestClaudeRequestObservation.map {
                    Self.merge(existing: $0, with: observation)
                } ?? observation
            }
        } else {
            guard seenClaudeRequestIDs.insert(identity).inserted else {
                return .rejected(.replayedOrSynthetic)
            }
            latestClaudeRequestID = identity
            latestClaudeRequestObservation = observation
        }

        setLatestRequestCacheHit(Self.claudeLatestRequestProjection(
            observation: latestClaudeRequestObservation,
            requestID: identity,
            executionID: executionID,
            turnID: turnID
        ))
        return .accepted
    }

    /// The latest request is a transient live fact. Provider switches can still retain the other
    /// provider's ledger, but they cannot project that provider's request state.
    func latestRequestCacheHit(for source: AgentUsageLatestRequestCacheHit.Source) -> AgentUsageLatestRequestCacheHit? {
        guard let latest = latestRequestCacheHitBySource[source] else { return nil }
        let currentExecution = source == .claudeAssistant ? activeExecutionID : codexState.activeExecutionID
        guard latest.executionID == currentExecution else { return nil }
        return latest
    }

    mutating func setLatestRequestCacheHit(_ next: AgentUsageLatestRequestCacheHit) {
        guard latestRequestCacheHitBySource[next.source] != next else { return }
        latestRequestCacheHitBySource[next.source] = next
        presentationRevision &+= 1
    }

    mutating func resetLatestRequestCacheHit(source: AgentUsageLatestRequestCacheHit.Source) {
        guard latestRequestCacheHitBySource.removeValue(forKey: source) != nil else { return }
        presentationRevision &+= 1
    }

    private static func claudeLatestRequestProjection(
        observation: AgentProviderUsageObservation?,
        requestID: String,
        executionID: UUID,
        turnID: UUID
    ) -> AgentUsageLatestRequestCacheHit {
        guard let observation else {
            return .init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: requestID,
                share: nil,
                detail: "Unavailable: Claude's latest main-loop assistant request did not include a usage object."
            )
        }
        let fields: [(String, Int?)] = [
            ("input", observation.inputTokens),
            ("cache-read", observation.cacheReadInputTokens),
            ("cache-creation", observation.cacheCreationInputTokens)
        ]
        let missing = fields.compactMap { $0.1 == nil ? $0.0 : nil }
        guard missing.isEmpty,
              let input = observation.inputTokens,
              let read = observation.cacheReadInputTokens,
              let creation = observation.cacheCreationInputTokens
        else {
            return .init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: requestID,
                share: nil,
                detail: "Unavailable: Claude's latest main-loop assistant usage omitted \(missing.joined(separator: ", ")) counter\(missing.count == 1 ? "" : "s")."
            )
        }
        guard input >= 0, read >= 0, creation >= 0 else {
            return .init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: requestID,
                share: nil,
                detail: "Unavailable: Claude's latest main-loop assistant usage contained an invalid negative counter."
            )
        }
        let (partial, overflow1) = Int64(input).addingReportingOverflow(Int64(read))
        let (denominator, overflow2) = partial.addingReportingOverflow(Int64(creation))
        guard !overflow1, !overflow2 else {
            return .init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: requestID,
                share: nil,
                detail: "Unavailable: Claude's latest main-loop assistant input counters overflowed while calculating CH."
            )
        }
        guard denominator > 0 else {
            return .init(
                source: .claudeAssistant,
                executionID: executionID,
                turnID: turnID.uuidString,
                requestID: requestID,
                share: nil,
                detail: "Unavailable: Claude reported a zero input denominator for the latest main-loop assistant request; CH is undefined, not 0%."
            )
        }
        return .init(
            source: .claudeAssistant,
            executionID: executionID,
            turnID: turnID.uuidString,
            requestID: requestID,
            share: .init(ratio: Decimal(read) / Decimal(denominator), coverage: .complete),
            detail: "Complete: Claude reported input, cache-read, and cache-creation counters for the latest live main-loop assistant request."
        )
    }

    // MARK: Observation

    /// Ingests one provider observation. Request-scope observations are snapshot upserts kept in
    /// memory; an accepted authoritative result replaces the turn subtotal and records its
    /// identity, and independently advances the cumulative monetary checkpoint when eligible.
    @discardableResult
    mutating func observe(_ input: AgentUsageObservationInput) -> AgentUsageIngestOutcome {
        guard qualification != .unqualified else { return .rejected(.unqualifiedContract) }
        guard eligibility == .eligible else { return .rejected(.ineligibleOwner) }
        guard input.executionID == activeExecutionID else { return .rejected(.disposedExecution) }
        switch executionVerdict {
        case .qualified?:
            break
        case .awaiting?:
            // Results are never buffered for later charging: a result before qualification
            // proves the launch cannot be attributed and blocks it.
            if input.observation.source == .result {
                blockAwaitingExecution(.resultBeforeQualification)
            }
            return .rejected(.executionNotQualified)
        case .blocked?:
            return .rejected(.executionBlocked)
        case nil:
            return .rejected(.disposedExecution)
        }
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
            // Quarantined fixture-only path: production-shaped accounting is result-only, so no
            // request is ever attributed to a dispatch ordinal (plan §2.10).
            guard case .qualified = qualification else { return .rejected(.requestScopeUnsupported) }
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
                outcome: input.terminalOutcome ?? .completed,
                monetaryDiagnostic: monetaryRejection.map { "monetary checkpoint rejected: \($0)" },
                childActivityObserved: input.childActivityObserved
            )
            if var latest = latestRequestCacheHit(for: .claudeAssistant),
               latest.turnID == turnID.uuidString,
               latest.detail == Self.latestClaudeAwaitingUsageDetail
            {
                latest.detail = "Unavailable: the latest Claude turn ended without a main-loop assistant usage report."
                setLatestRequestCacheHit(latest)
            }
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

    /// Whether the record may be mutated for lifecycle closure regardless of the current
    /// verdict: a blocked-after-qualified execution still closes its own turns and segment.
    private var canMutateRecord: Bool {
        guard qualification != .unqualified, eligibility == .eligible else { return false }
        switch executionVerdict {
        case .qualified?, .blocked?: return record != nil
        case .awaiting?, nil: return false
        }
    }

    /// Policy is checked before owner eligibility, then the execution verdict.
    private var mutationRejection: AgentUsageIngestRejection? {
        guard qualification != .unqualified else { return .unqualifiedContract }
        guard eligibility == .eligible else { return .ineligibleOwner }
        switch executionVerdict {
        case .qualified?: return nil
        case .awaiting?: return .executionNotQualified
        case .blocked?: return .executionBlocked
        case nil: return .disposedExecution
        }
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

    /// Every owned mutation passes through here. The first owned mutation of a hydrated record
    /// under `.executionVerified` also retires abandoned mid-run lifecycle state, so a record is
    /// never rewritten with stale `.open` turns/segments beside live ones.
    mutating func bumpRevision() {
        if pendingHydratedRetirement, record != nil {
            Self.retireAbandonedLifecycleState(in: &record!, activeExecutionID: activeExecutionID)
            pendingHydratedRetirement = false
        }
        ownedRevision &+= 1
    }

    /// Whether the record still carries hydrated `.open` turns/segments from a disposed execution.
    var hasAbandonedHydratedLifecycleState: Bool {
        guard let record else { return false }
        return record.turns.contains { $0.outcome == .open && $0.executionID != activeExecutionID }
            || record.claudeSegments.contains { $0.state == .open && $0.executionID != activeExecutionID }
    }

    mutating func materializeRecordIfNeeded(at now: Date) {
        guard record == nil else { return }
        record = .init(
            originSessionID: ownerSessionID,
            trackingStartedAt: now,
            hasUnmeasuredHistory: hasPriorHistory
        )
        bumpRevision()
    }

    /// Opens the monetary segment for the active execution, or continues one already persisted
    /// for the same execution and reset generation. Returns `false` when the execution had to be
    /// blocked instead.
    ///
    /// Continuation happens when hydration replaced the accumulator while the same process stayed
    /// attached (route activation, late hydration): the persisted checkpoint (baseline and latest
    /// cumulative) is the truth for this process, so reopening a zero baseline would count the
    /// earlier cumulative amount again (OracleA P0#3 / OracleB P1#1). The segment's still-open
    /// turns are re-registered so their results can land and lifecycle closure can retire them. A
    /// persisted segment for this execution that is no longer open cannot be continued and its
    /// identity cannot be reused, so the execution is blocked (fail-closed).
    private mutating func openSegment(baseline: AgentUsageSegmentBaseline, contractID: String) -> Bool {
        guard let executionID = activeExecutionID else { return false }
        if let existing = record?.claudeSegments.lastIndex(where: { $0.executionID == executionID && $0.resetGeneration == resetGeneration }) {
            guard record?.claudeSegments[existing].state == .open else {
                executionVerdict = .blocked(.attributionDesynchronized("a persisted segment for this execution is already closed"))
                return false
            }
            for turn in record?.turns ?? [] where turn.executionID == executionID && turn.segmentIndex == existing && turn.outcome == .open {
                registeredTurnIDs.insert(turn.turnID)
                requestSnapshotsByTurn[turn.turnID] = [:]
            }
            return true
        }
        let coverage: AgentProviderUsageRecord.Coverage = switch baseline {
        case .verifiedZero: .complete
        case .unknown: .partial
        case .unsupported: .unavailable
        }
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
            coverage: coverage
        )
        record?.claudeSegments.append(segment)
        if baseline == .unknown {
            // Unknown inherited cumulative: prior money is unmeasured (prospective baseline).
            record?.hasUnmeasuredHistory = true
        }
        bumpRevision()
        return true
    }

    /// Closes a segment. Dispatched work after the latest accepted cumulative checkpoint (or with
    /// no checkpoint at all) has no monetary coverage, so the segment becomes partial while its
    /// accepted amount is preserved. A later checkpoint accepted before closing covers earlier gaps.
    private mutating func closeSegment(at index: Int) {
        guard let record, record.claudeSegments.indices.contains(index) else { return }
        var segment = record.claudeSegments[index]
        segment.state = .closed
        if segment.coverage != .unavailable, Self.segmentHasUncoveredWork(segment, at: index, in: record) {
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
        guard segment.coverage != .unavailable else { return .rejected(.monetaryScopeUnsupported) }
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
        outcome: AgentProviderUsageRecord.TurnOutcome,
        monetaryDiagnostic: String?,
        childActivityObserved: Bool = false
    ) {
        guard let current = record, let turnIndex = current.turns.lastIndex(where: { $0.turnID == turnID }) else { return }
        var turn = current.turns[turnIndex]
        let snapshots = requestSnapshotsByTurn[turnID] ?? [:]
        turn.acceptedResultID = resultID
        turn.observedRequestCount = snapshots.isEmpty ? nil : snapshots.count
        let hasResultCounts = result.inputTokens != nil || result.outputTokens != nil
            || result.cacheReadInputTokens != nil || result.cacheCreationInputTokens != nil
        var diagnostics: [String] = []
        if childActivityObserved {
            // Parent-inclusive cost was accepted above; the token triple is not provably main-loop
            // scope, so it is excluded rather than presented as a complete main-loop interval.
            turn.inputTokens = nil
            turn.outputTokens = nil
            turn.cacheReadInputTokens = nil
            turn.cacheCreationInputTokens = nil
            turn.coverage = .partial
            diagnostics.append(Self.childActivityDiagnostic)
        } else if hasResultCounts {
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
        if outcome == .interrupted {
            diagnostics.append("original result reported \(result.resultSubtype ?? "interruption")")
        }
        turn.diagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")
        turn.outcome = outcome == .open ? .completed : outcome
        record?.turns[turnIndex] = turn
        registeredTurnIDs.remove(turnID)
        awaitingDispatchOrder.removeAll { $0 == turnID }
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
            resultIsError: update.resultIsError ?? existing.resultIsError,
            resultIndex: update.resultIndex ?? existing.resultIndex,
            queuedTurnCount: update.queuedTurnCount ?? existing.queuedTurnCount
        )
    }
}
