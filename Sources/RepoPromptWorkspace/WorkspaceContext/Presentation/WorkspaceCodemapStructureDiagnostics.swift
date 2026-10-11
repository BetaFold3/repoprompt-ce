import Foundation
import OSLog

/// Opt-in, privacy-safe diagnostics for one code-structure presentation invocation.
///
/// Activation is process-wide and diagnostic-only: the launched process must have
/// `REPOPROMPT_CODE_STRUCTURE_DIAGNOSTICS=1` in its environment or the exact
/// `--codemap-structure-diagnostics` launch argument. When disabled nothing is recorded or emitted.
///
/// When enabled, each `structurePresentation` invocation keeps an operation-local trace (at most
/// ``WorkspaceCodemapStructureDiagnosticRecord/maximumCheckpointCount`` checkpoints plus an
/// independently kept terminal result and dropped-checkpoint count) and emits one terminal record
/// through OSLog subsystem `com.repoprompt.codemap`, category `structure-diagnostics`. Every line
/// of a record carries the same process-local emission number (`rec=`) plus `part=`/`parts=`, and
/// every line, including the summary, stays within the record's line bound. Join rule: group lines
/// by process and `rec`, order by `part`, concatenate the space-separated bodies, then rejoin any
/// consecutive `frag=<i>,<n>:` pieces into the single token they split.
///
/// Privacy contract: records contain only fixed code strings, integers, and booleans. They never
/// contain paths, root names, UUIDs, tickets, keys, digests, rendered content, reflected values,
/// or error descriptions. Codes are constructible only by the classifier in this file.
enum WorkspaceCodemapStructureDiagnostics {
    typealias Sink = @Sendable (WorkspaceCodemapStructureDiagnosticRecord) -> Void

    static let environmentKey = "REPOPROMPT_CODE_STRUCTURE_DIAGNOSTICS"
    static let launchArgument = "--codemap-structure-diagnostics"
    static let processSink: Sink? = sink(
        environment: ProcessInfo.processInfo.environment,
        arguments: ProcessInfo.processInfo.arguments
    )

    private static let logger = Logger(subsystem: "com.repoprompt.codemap", category: "structure-diagnostics")

    static func isEnabled(environment: [String: String], arguments: [String]) -> Bool {
        environment[environmentKey] == "1" || arguments.contains(launchArgument)
    }

    static func sink(environment: [String: String], arguments: [String]) -> Sink? {
        guard isEnabled(environment: environment, arguments: arguments) else { return nil }
        return emitter(sequence: .process) { line in
            logger.notice("\(line, privacy: .public)")
        }
    }

    /// Writes each record as its bounded log lines, all tagged with one fresh emission number so
    /// parts of concurrently emitted records stay joinable even when their lines interleave.
    static func emitter(
        sequence: WorkspaceCodemapStructureDiagnosticEmissionSequence,
        write: @escaping @Sendable (String) -> Void
    ) -> Sink {
        { record in
            let emission = sequence.next()
            for line in record.logLines(emissionSequence: emission) {
                write(line)
            }
        }
    }
}

/// Process-local, monotonically increasing emission numbers starting at 1. Instrumentation-only
/// shared state: nothing in publication, recovery, or lifecycle code reads it.
final class WorkspaceCodemapStructureDiagnosticEmissionSequence: @unchecked Sendable {
    static let process = WorkspaceCodemapStructureDiagnosticEmissionSequence()

    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            last &+= 1
            return last
        }
    }
}

/// A fixed diagnostic code such as `publication.traversal.graph`. Only this file can create one.
struct WorkspaceCodemapStructureDiagnosticCode: Hashable, Comparable, CustomStringConvertible {
    let rawValue: String

    fileprivate init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    fileprivate init(_ prefix: String, _ child: Self) {
        rawValue = prefix + "." + child.rawValue
    }

    var description: String {
        rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum WorkspaceCodemapStructureDiagnosticPhase: String, Equatable {
    case attemptBegin = "attempt_begin"
    case seedAdmission = "seed_admission"
    case seedCandidates = "seed_candidates"
    case seedDemand = "seed_demand"
    case projection
    case projectionRootSessionRetry = "projection_root_session_retry"
    case initialTraversal = "initial_traversal"
    case targetDemand = "target_demand"
    case targetTraversal = "target_traversal"
    case presentationCandidates = "presentation_candidates"
    case freezeRender = "freeze_render"
    case attemptResult = "attempt_result"
    case publicationHook = "publication_hook"
    case revalidation
    case cleanup
}

enum WorkspaceCodemapStructureDiagnosticDetail: Equatable {
    enum Key: String, Equatable {
        case admitted
        case candidates
        case issues
        case ready
        case pending
        case unavailable
        case resets
        case targets
        case roots
        case queries
        case ordered
        case bundles
        case freezeUnavailable = "freeze_unavailable"
        case renderUnavailable = "render_unavailable"
        case entries
        case durationMilliseconds = "duration_ms"
        case limitExceeded = "limit_exceeded"
        case deadlineReached = "deadline_reached"
        case roundLimitReached = "round_limit_reached"
        case receipt
        case unrestartable
    }

    case count(Key, Int)
    case flag(Key, Bool)

    fileprivate var serialized: String {
        switch self {
        case let .count(key, value): "\(key.rawValue)=\(max(0, value))"
        case let .flag(key, value): "\(key.rawValue)=\(value)"
        }
    }
}

struct WorkspaceCodemapStructureDiagnosticCheckpoint: Equatable {
    let attempt: Int
    let phase: WorkspaceCodemapStructureDiagnosticPhase
    let elapsedMilliseconds: Int
    let code: WorkspaceCodemapStructureDiagnosticCode?
    let details: [WorkspaceCodemapStructureDiagnosticDetail]

    fileprivate var serialized: String {
        var token = "a\(max(0, attempt)).\(phase.rawValue)@\(max(0, elapsedMilliseconds))"
        if let code { token += ":" + code.rawValue }
        if !details.isEmpty {
            token += "{" + details.map(\.serialized).joined(separator: ",") + "}"
        }
        return token
    }
}

/// What `structurePresentation` actually returned or threw.
enum WorkspaceCodemapStructureDiagnosticTerminalDisposition: String, Equatable {
    case publishedFastPath = "published_fast_path"
    case revalidatedCurrent = "revalidated_current"
    case attemptPresentationWithoutReceipt = "attempt_presentation_without_receipt"
    case staleAfterAttempt = "stale_after_attempt"
    case unrestartableAfterAttempt = "unrestartable_after_attempt"
    case staleAfterRevalidation = "stale_after_revalidation"
    case staleAfterReceiptlessRevocation = "stale_after_receiptless_revocation"
    case attemptsExhausted = "attempts_exhausted"
    case cancelled
    case threw
    /// Defensive: a return path that did not classify itself.
    case unclassified
}

struct WorkspaceCodemapStructureDiagnosticTerminal: Equatable {
    let disposition: WorkspaceCodemapStructureDiagnosticTerminalDisposition
    let outcome: WorkspaceCodemapStructureDiagnosticCode?
    let staleReason: WorkspaceCodemapStructureDiagnosticCode?
    let issueCodes: [WorkspaceCodemapStructureDiagnosticCode]
    let droppedIssueCodeCount: Int
    let elapsedMilliseconds: Int
    let attemptsStarted: Int
    let finalAttempt: Int?
    let finalPhase: WorkspaceCodemapStructureDiagnosticPhase?
    let deadlinePassed: Bool
    let cancelled: Bool
}

struct WorkspaceCodemapStructureDiagnosticRecord: Equatable {
    static let schemaVersion = 1
    static let maximumCheckpointCount = 64
    static let maximumIssueCodeCount = 8
    static let defaultMaximumLineBytes = 900
    /// Smallest supported line bound; smaller requested bounds are raised to this value.
    static let minimumLineBytes = 192

    let direction: WorkspaceCodemapStructureDiagnosticCode
    let requestedSeedCount: Int
    let maximumAttemptCount: Int
    let totalWaitLimitMilliseconds: Int
    let checkpoints: [WorkspaceCodemapStructureDiagnosticCheckpoint]
    let droppedCheckpointCount: Int
    let terminal: WorkspaceCodemapStructureDiagnosticTerminal

    /// The record's space-free tokens in emission order: terminal summary fields (counters and
    /// dropped counts first), then one `issue=` token per kept issue code, then one `cp=` token per
    /// kept checkpoint.
    var tokens: [String] {
        var tokens = [
            "elapsed_ms=\(max(0, terminal.elapsedMilliseconds))",
            "terminal=\(terminal.disposition.rawValue)",
            "outcome=\(terminal.outcome?.rawValue ?? "none")",
            "stale=\(terminal.staleReason?.rawValue ?? "none")",
            "attempts=\(max(0, terminal.attemptsStarted))",
            "final_attempt=\(terminal.finalAttempt.map { String(max(0, $0)) } ?? "none")",
            "final_phase=\(terminal.finalPhase?.rawValue ?? "none")",
            "deadline_passed=\(terminal.deadlinePassed)",
            "cancelled=\(terminal.cancelled)",
            "checkpoints=\(checkpoints.count)",
            "checkpoints_dropped=\(max(0, droppedCheckpointCount))",
            "issues=\(terminal.issueCodes.count)",
            "issues_dropped=\(max(0, terminal.droppedIssueCodeCount))",
            "direction=\(direction.rawValue)",
            "seeds=\(max(0, requestedSeedCount))",
            "max_attempts=\(max(0, maximumAttemptCount))",
            "wait_limit_ms=\(max(0, totalWaitLimitMilliseconds))"
        ]
        tokens += terminal.issueCodes.map { "issue=" + $0.rawValue }
        tokens += checkpoints.map { "cp=" + $0.serialized }
        return tokens
    }

    /// The record as numbered log lines, each at most `max(maximumLineBytes, minimumLineBytes)`
    /// UTF-8 bytes, including the header. Every line starts with
    /// `code_structure_diagnostics schema=<v> rec=<emissionSequence> part=<i> parts=<n>` followed by
    /// whole tokens; a token too long for one line is split into consecutive `frag=<i>,<n>:` pieces.
    func logLines(emissionSequence: UInt64, maximumLineBytes: Int = defaultMaximumLineBytes) -> [String] {
        let lineLimit = max(maximumLineBytes, Self.minimumLineBytes)
        let recordTokens = tokens
        var partDigits = 3
        while true {
            let widestPart = String(repeating: "9", count: partDigits)
            let headerBytes = Self.header(emissionSequence: emissionSequence, part: widestPart, parts: widestPart)
                .utf8.count
            let bodies = Self.pack(recordTokens, bodyLimit: lineLimit - headerBytes - 1)
            let partCount = String(bodies.count)
            guard partCount.utf8.count > partDigits else {
                return bodies.enumerated().map { index, body in
                    Self.header(emissionSequence: emissionSequence, part: String(index + 1), parts: partCount)
                        + " " + body
                }
            }
            partDigits = partCount.utf8.count
        }
    }

    private static func header(emissionSequence: UInt64, part: String, parts: String) -> String {
        "code_structure_diagnostics schema=\(schemaVersion) rec=\(emissionSequence) part=\(part) parts=\(parts)"
    }

    /// Greedily packs whole tokens (or fragments) into space-separated bodies within `bodyLimit`.
    private static func pack(_ tokens: [String], bodyLimit: Int) -> [String] {
        var bodies: [String] = []
        var current = ""
        for token in tokens {
            for piece in fragments(of: token, bodyLimit: bodyLimit) {
                if current.isEmpty {
                    current = piece
                } else if current.utf8.count + 1 + piece.utf8.count <= bodyLimit {
                    current += " " + piece
                } else {
                    bodies.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { bodies.append(current) }
        return bodies
    }

    /// The token itself when it fits `bodyLimit`; otherwise ordered `frag=<i>,<n>:<chunk>` pieces,
    /// each within `bodyLimit`, whose chunks concatenate back to the token.
    private static func fragments(of token: String, bodyLimit: Int) -> [String] {
        guard token.utf8.count > bodyLimit else { return [token] }
        var countDigits = 1
        while true {
            let prefixBytes = "frag=,:".utf8.count + 2 * countDigits
            let chunks = chunked(token, maximumBytes: max(1, bodyLimit - prefixBytes))
            let count = String(chunks.count)
            guard count.utf8.count > countDigits else {
                return chunks.enumerated().map { index, chunk in
                    "frag=\(index + 1),\(count):" + chunk
                }
            }
            countDigits = count.utf8.count
        }
    }

    private static func chunked(_ token: String, maximumBytes: Int) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var chunkBytes = 0
        for character in token {
            let characterBytes = character.utf8.count
            if !chunk.isEmpty, chunkBytes + characterBytes > maximumBytes {
                chunks.append(chunk)
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(character)
            chunkBytes += characterBytes
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
}

/// Operation-local, sequential trace. Owned by one `structurePresentation` invocation and passed
/// through its attempt flow by `inout`; it has no shared state, tasks, locks, or actor hops.
struct WorkspaceCodemapStructureDiagnosticTrace {
    let isEnabled: Bool
    private let started: ContinuousClock.Instant
    private let direction: WorkspaceCodemapStructureDiagnosticCode
    private let requestedSeedCount: Int
    private let maximumAttemptCount: Int
    private let totalWaitLimitMilliseconds: Int
    private var deadline: ContinuousClock.Instant?
    private(set) var checkpoints: [WorkspaceCodemapStructureDiagnosticCheckpoint] = []
    private(set) var droppedCheckpointCount = 0
    private var attemptsStarted = 0
    private var currentAttempt: Int?
    private var finalPhase: WorkspaceCodemapStructureDiagnosticPhase?
    private var disposition: WorkspaceCodemapStructureDiagnosticTerminalDisposition?

    init(
        isEnabled: Bool,
        direction: WorkspaceCodemapStructureTraversalDirection?,
        requestedSeedCount: Int,
        maximumAttemptCount: Int,
        totalWait: Duration
    ) {
        self.isEnabled = isEnabled
        started = ContinuousClock.now
        self.direction = WorkspaceCodemapStructureDiagnosticClassifier.code(for: direction)
        self.requestedSeedCount = requestedSeedCount
        self.maximumAttemptCount = maximumAttemptCount
        totalWaitLimitMilliseconds = Self.milliseconds(totalWait)
    }

    mutating func setDeadline(_ deadline: ContinuousClock.Instant) {
        guard isEnabled else { return }
        self.deadline = deadline
    }

    mutating func beginAttempt(_ attempt: Int) {
        guard isEnabled else { return }
        attemptsStarted += 1
        currentAttempt = attempt
        append(.attemptBegin, code: nil, details: [])
    }

    mutating func record(
        _ phase: WorkspaceCodemapStructureDiagnosticPhase,
        code: @autoclosure () -> WorkspaceCodemapStructureDiagnosticCode? = nil,
        details: @autoclosure () -> [WorkspaceCodemapStructureDiagnosticDetail] = []
    ) {
        guard isEnabled else { return }
        append(phase, code: code(), details: details())
    }

    /// A start instant for a later ``recordDuration(_:since:code:)``; nil when disabled.
    func mark() -> ContinuousClock.Instant? {
        isEnabled ? ContinuousClock.now : nil
    }

    mutating func recordDuration(
        _ phase: WorkspaceCodemapStructureDiagnosticPhase,
        since start: ContinuousClock.Instant?,
        code: @autoclosure () -> WorkspaceCodemapStructureDiagnosticCode? = nil
    ) {
        guard isEnabled, let start else { return }
        let duration = Self.milliseconds(start.duration(to: ContinuousClock.now))
        append(phase, code: code(), details: [.count(.durationMilliseconds, duration)])
    }

    mutating func decide(_ disposition: WorkspaceCodemapStructureDiagnosticTerminalDisposition) {
        guard isEnabled else { return }
        self.disposition = disposition
    }

    func finish(returning presentation: WorkspaceCodemapStructurePresentation) -> WorkspaceCodemapStructureDiagnosticRecord? {
        guard isEnabled else { return nil }
        var uniqueIssueCodes = Set<WorkspaceCodemapStructureDiagnosticCode>()
        var staleReason: WorkspaceCodemapStructureDiagnosticCode?
        for issue in presentation.issues {
            uniqueIssueCodes.insert(WorkspaceCodemapStructureDiagnosticClassifier.code(for: issue))
            if staleReason == nil, case let .publicationStale(reason) = issue {
                staleReason = WorkspaceCodemapStructureDiagnosticClassifier.code(for: reason)
            }
        }
        let sortedIssueCodes = uniqueIssueCodes.sorted()
        return makeRecord(
            disposition: disposition ?? .unclassified,
            outcome: WorkspaceCodemapStructureDiagnosticClassifier.code(for: presentation.outcome),
            staleReason: staleReason,
            issueCodes: Array(sortedIssueCodes.prefix(WorkspaceCodemapStructureDiagnosticRecord.maximumIssueCodeCount)),
            droppedIssueCodeCount: max(
                0,
                sortedIssueCodes.count - WorkspaceCodemapStructureDiagnosticRecord.maximumIssueCodeCount
            )
        )
    }

    /// Classifies a thrown error by type only; its description is never recorded.
    func finish(throwing error: any Error) -> WorkspaceCodemapStructureDiagnosticRecord? {
        guard isEnabled else { return nil }
        return makeRecord(
            disposition: error is CancellationError ? .cancelled : .threw,
            outcome: nil,
            staleReason: nil,
            issueCodes: [],
            droppedIssueCodeCount: 0
        )
    }

    private mutating func append(
        _ phase: WorkspaceCodemapStructureDiagnosticPhase,
        code: WorkspaceCodemapStructureDiagnosticCode?,
        details: [WorkspaceCodemapStructureDiagnosticDetail]
    ) {
        finalPhase = phase
        guard checkpoints.count < WorkspaceCodemapStructureDiagnosticRecord.maximumCheckpointCount else {
            droppedCheckpointCount += 1
            return
        }
        checkpoints.append(WorkspaceCodemapStructureDiagnosticCheckpoint(
            attempt: currentAttempt ?? 0,
            phase: phase,
            elapsedMilliseconds: Self.milliseconds(started.duration(to: ContinuousClock.now)),
            code: code,
            details: details
        ))
    }

    private func makeRecord(
        disposition: WorkspaceCodemapStructureDiagnosticTerminalDisposition,
        outcome: WorkspaceCodemapStructureDiagnosticCode?,
        staleReason: WorkspaceCodemapStructureDiagnosticCode?,
        issueCodes: [WorkspaceCodemapStructureDiagnosticCode],
        droppedIssueCodeCount: Int
    ) -> WorkspaceCodemapStructureDiagnosticRecord {
        let now = ContinuousClock.now
        return WorkspaceCodemapStructureDiagnosticRecord(
            direction: direction,
            requestedSeedCount: requestedSeedCount,
            maximumAttemptCount: maximumAttemptCount,
            totalWaitLimitMilliseconds: totalWaitLimitMilliseconds,
            checkpoints: checkpoints,
            droppedCheckpointCount: droppedCheckpointCount,
            terminal: WorkspaceCodemapStructureDiagnosticTerminal(
                disposition: disposition,
                outcome: outcome,
                staleReason: staleReason,
                issueCodes: issueCodes,
                droppedIssueCodeCount: droppedIssueCodeCount,
                elapsedMilliseconds: Self.milliseconds(started.duration(to: now)),
                attemptsStarted: attemptsStarted,
                finalAttempt: currentAttempt,
                finalPhase: finalPhase,
                deadlinePassed: deadline.map { now >= $0 } ?? false,
                cancelled: Task.isCancelled
            )
        )
    }

    static func milliseconds(_ duration: Duration) -> Int {
        guard duration > .zero else { return 0 }
        let components = duration.components
        let (secondMilliseconds, overflow) = Int(clamping: components.seconds).multipliedReportingOverflow(by: 1000)
        guard !overflow else { return .max }
        let (total, sumOverflow) = secondMilliseconds.addingReportingOverflow(
            Int(clamping: components.attoseconds / 1_000_000_000_000_000)
        )
        return sumOverflow ? .max : total
    }
}

/// Explicit, exhaustive mapping from existing typed reasons to fixed codes. Identifying associated
/// values (epochs, file IDs, tickets, keys, paths) are discarded; nothing is reflected.
enum WorkspaceCodemapStructureDiagnosticClassifier {
    typealias Code = WorkspaceCodemapStructureDiagnosticCode

    /// The coordinator's projection readiness result, without its private payloads.
    enum ProjectionWait {
        case ready
        case busy
        case timeout
        case unavailable(WorkspaceCodemapProjectionDemandUnavailableReason)
        case stale
        case cancelled
    }

    static func code(for direction: WorkspaceCodemapStructureTraversalDirection?) -> Code {
        switch direction {
        case nil: Code("none")
        case .referencedDefinitions: Code("referenced_definitions")
        case .referrers: Code("referrers")
        case .both: Code("both")
        }
    }

    static func code(for outcome: WorkspaceCodemapStructureOutcome) -> Code {
        switch outcome {
        case .ready: Code("ready")
        case .partial: Code("partial")
        case .pending: Code("pending")
        case .busy: Code("busy")
        case .timeout: Code("timeout")
        case .unavailable: Code("unavailable")
        case .stale: Code("stale")
        case .budget: Code("budget")
        }
    }

    static func code(for reason: WorkspaceCodemapStructurePublicationStaleReason) -> Code {
        switch reason {
        case let .presentation(presentation):
            Code("publication.presentation", code(forPresentationStale: presentation))
        case let .traversal(traversal):
            Code("publication.traversal", code(for: traversal))
        case .output:
            Code("publication.output")
        }
    }

    static func code(for disposition: WorkspaceCodemapStructurePublicationDisposition) -> Code {
        switch disposition {
        case .current: Code("current")
        case let .stale(reason): code(for: reason)
        }
    }

    static func code(for preparation: WorkspaceCodemapProjectionRootSessionRetryPreparation) -> Code {
        switch preparation {
        case .prepared: Code("prepared")
        case .stale: Code("stale")
        case .deadlineReached: Code("deadline_reached")
        case .cancelled: Code("cancelled")
        }
    }

    static func code(for wait: ProjectionWait) -> Code {
        switch wait {
        case .ready: Code("ready")
        case .busy: Code("busy")
        case .timeout: Code("timeout")
        case let .unavailable(reason): Code("unavailable", code(for: reason))
        case .stale: Code("stale")
        case .cancelled: Code("cancelled")
        }
    }

    static func code(for disposition: WorkspaceCodemapStructureTraversalDisposition) -> Code {
        switch disposition {
        case .readyPartial: Code("ready_partial")
        case let .pending(reason): Code("pending", code(for: reason))
        case let .unavailable(reason): Code("unavailable", code(for: reason))
        case let .stale(reason): Code("stale", code(for: reason))
        case let .budget(_, reason): Code("budget", code(for: reason))
        case .cancelled: Code("cancelled")
        }
    }

    static func code(for issue: WorkspaceCodemapStructureIssue) -> Code {
        switch issue {
        case let .candidate(candidate): Code("candidate", code(for: candidate))
        case .artifactPending: Code("artifact_pending")
        case let .artifactUnavailable(_, reason): Code("artifact_unavailable", code(for: reason))
        case let .traversalPartial(reason): Code("traversal_partial", code(for: reason))
        case let .traversalPending(reason): Code("traversal_pending", code(for: reason))
        case let .traversalUnavailable(reason): Code("traversal_unavailable", code(for: reason))
        case let .traversalStale(reason): Code("traversal_stale", code(for: reason))
        case let .traversalBudget(reason): Code("traversal_budget", code(for: reason))
        case .busy: Code("busy")
        case .readinessTimeout: Code("readiness_timeout")
        case let .projectionUnavailable(reason, _): Code("projection_unavailable", code(for: reason))
        case let .projectionBudget(budget): Code("projection_budget", code(for: budget.dimension))
        case let .freezeUnavailable(_, reason): Code("freeze_unavailable", code(for: reason))
        case let .renderUnavailable(_, reason): Code("render_unavailable", code(for: reason))
        case .fileLimit: Code("file_limit")
        case .seedDemandLimit: Code("seed_demand_limit")
        case .tokenLimit: Code("token_limit")
        case let .publicationStale(reason): code(for: reason)
        }
    }

    private static func code(forPresentationStale reason: WorkspaceCodemapOperationPublicationStaleReason) -> Code {
        switch reason {
        case .rootScope: Code("root_scope")
        case .rootEpoch: Code("root_epoch")
        case .catalog: Code("catalog")
        case .demand: Code("demand")
        case .bundle: Code("bundle")
        case let .automatic(automatic): Code("automatic", code(for: automatic))
        }
    }

    private static func code(for reason: WorkspaceCodemapAutomaticSelectionStaleReason) -> Code {
        switch reason {
        case .rootEpochNotCurrent: Code("root_epoch_not_current")
        case .rootScopeChanged: Code("root_scope_changed")
        case .sourceStateChanged: Code("source_state_changed")
        case .sourceCatalogGeneration: Code("source_catalog_generation")
        case .targetStateChanged: Code("target_state_changed")
        case .coverageProof: Code("coverage_proof")
        case let .graph(graph): Code("graph", code(for: graph))
        case .publicationReceipt: Code("publication_receipt")
        }
    }

    private static func code(for reason: WorkspaceCodemapStoreSelectionGraphQueryStaleReason) -> Code {
        switch reason {
        case .currentness: Code("currentness")
        case let .runtime(_, runtime): Code("runtime", code(for: runtime))
        }
    }

    private static func code(for reason: WorkspaceCodemapStructureTraversalStaleReason) -> Code {
        switch reason {
        case .rootEpoch: Code("root_epoch")
        case .graph: Code("graph")
        case .seed: Code("seed")
        }
    }

    private static func code(for reason: WorkspaceCodemapStructureTraversalPendingReason) -> Code {
        switch reason {
        case .graphRebuilding: Code("graph_rebuilding")
        case .graphBusy: Code("graph_busy")
        }
    }

    private static func code(for reason: WorkspaceCodemapStructureTraversalUnavailableReason) -> Code {
        switch reason {
        case .emptySeeds: Code("empty_seeds")
        case .foreignRootEpoch: Code("foreign_root_epoch")
        case .duplicateSeedConflict: Code("duplicate_seed_conflict")
        case .seedNotReady: Code("seed_not_ready")
        case .graphNotBuilt: Code("graph_not_built")
        case .invalidGraphResult: Code("invalid_graph_result")
        case let .definitionUniverse(_, coverage): Code("definition_universe", code(for: coverage))
        case let .runtime(_, runtime): Code("runtime", code(for: runtime))
        }
    }

    private static func code(for coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage) -> Code {
        switch coverage {
        case .complete: Code("complete")
        case .incomplete: Code("incomplete")
        case .busy: Code("busy")
        case let .budget(dimension, _, _): Code("budget", code(for: dimension))
        case .unavailable: Code("unavailable")
        }
    }

    private static func code(for reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason) -> Code {
        switch reason {
        case .notBuilt: Code("not_built")
        case .rebuilding: Code("rebuilding")
        case .staleCurrentness: Code("stale_currentness")
        case let .actorAdmissionRejected(busy): Code("actor_admission_rejected", code(for: busy))
        case let .processAdmissionRejected(busy): Code("process_admission_rejected", code(for: busy))
        case .cancelled: Code("cancelled")
        case .budgetExceeded: Code("budget_exceeded")
        case let .outputBudgetExceeded(dimension): Code("output_budget_exceeded", code(for: dimension))
        case .invalidSnapshot: Code("invalid_snapshot")
        case let .explicitRootUnavailable(external): Code("explicit_root_unavailable", code(for: external))
        case .invalidQuery: Code("invalid_query")
        }
    }

    private static func code(for reason: WorkspaceCodemapSelectionGraphRuntimeBusyReason) -> Code {
        switch reason {
        case .actorActiveRebuildLimit: Code("actor_active_rebuild_limit")
        case .actorReservedBindingLimit: Code("actor_reserved_binding_limit")
        case let .processAdmission(busy): Code("process_admission", code(for: busy))
        }
    }

    private static func code(for reason: CodeMapSelectionGraphAdmissionBusyReason) -> Code {
        switch reason {
        case .activeReservationCountLimit: Code("active_reservation_count_limit")
        case .reservedBindingCountLimit: Code("reserved_binding_count_limit")
        }
    }

    private static func code(for dimension: WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudgetDimension) -> Code {
        switch dimension {
        case .resolvedTargets: Code("resolved_targets")
        case .resolutions: Code("resolutions")
        case .referenceFailures: Code("reference_failures")
        case .bytes: Code("bytes")
        }
    }

    private static func code(for reason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason) -> Code {
        switch reason {
        case .rootUnloaded: Code("root_unloaded")
        case .authorityRevoked: Code("authority_revoked")
        }
    }

    private static func code(for reason: WorkspaceCodemapStructureTraversalBudgetReason) -> Code {
        switch reason {
        case .rootLimit: Code("root_limit")
        case .nodeLimit: Code("node_limit")
        case .edgeLimit: Code("edge_limit")
        case .byteLimit: Code("byte_limit")
        case .accountingOverflow: Code("accounting_overflow")
        case let .runtime(_, dimension): Code("runtime", code(for: dimension))
        }
    }

    private static func code(for dimension: WorkspaceCodemapSelectionGraphRuntimeStructureBudgetDimension) -> Code {
        switch dimension {
        case .nodes: Code("nodes")
        case .edges: Code("edges")
        case .bytes: Code("bytes")
        }
    }

    private static func code(for reason: WorkspaceCodemapStructureTraversalPartialReason) -> Code {
        switch reason {
        case .definitionUniverseIncomplete: Code("definition_universe_incomplete")
        case .referenceFailuresPresent: Code("reference_failures_present")
        }
    }

    private static func code(for reason: WorkspaceCodemapProjectionDemandUnavailableReason) -> Code {
        switch reason {
        case .rootNotRegistered: Code("root_not_registered")
        case .capabilityUnavailable: Code("capability_unavailable")
        case .repositoryAuthorityChanged: Code("repository_authority_changed")
        case .generationMismatch: Code("generation_mismatch")
        case let .projectionBudget(budget): Code("projection_budget", code(for: budget.dimension))
        }
    }

    private static func code(for dimension: WorkspaceCodemapProjectionBudgetDimension) -> Code {
        switch dimension {
        case .catalogEntries: Code("catalog_entries")
        case .catalogPathBytes: Code("catalog_path_bytes")
        case .activeBatches: Code("active_batches")
        case .retainedSourceBytes: Code("retained_source_bytes")
        case .retainedProjectionBytes: Code("retained_projection_bytes")
        case .stagedGraphBytes: Code("staged_graph_bytes")
        case let .residentGraph(size): Code("resident_graph", code(for: size))
        case .queuedManifestMutationBytes: Code("queued_manifest_mutation_bytes")
        }
    }

    private static func code(for dimension: WorkspaceCodemapSelectionGraphSizeDimension) -> Code {
        switch dimension {
        case .nodes: Code("nodes")
        case .postings: Code("postings")
        case .edges: Code("edges")
        case .bytes: Code("bytes")
        }
    }

    private static func code(for reason: WorkspaceCodemapArtifactDemandUnavailableReason) -> Code {
        switch reason {
        case .rootNotLoaded: Code("root_not_loaded")
        case .fileNotCataloged: Code("file_not_cataloged")
        case .unsupportedFileType: Code("unsupported_file_type")
        case let .gitTerminal(terminal): Code("git_terminal", code(for: terminal))
        case let .gitTransient(transient): Code("git_transient", code(for: transient))
        case let .demandUnavailable(demand): Code("demand_unavailable", code(for: demand))
        case .busy: Code("busy")
        case let .rejected(rejection): Code("rejected", code(for: rejection))
        case .routeConflict: Code("route_conflict")
        case .registrationFailed: Code("registration_failed")
        case .runtimeFailure: Code("runtime_failure")
        case .runtimeFailureParked: Code("runtime_failure_parked")
        case .staleCurrentness: Code("stale_currentness")
        case .cancelled: Code("cancelled")
        }
    }

    /// Every binding rejection keeps its own leaf; the coordinator's recovery choice
    /// (`WorkspaceCodemapArtifactDemandRecovery`) depends on exactly this distinction.
    private static func code(for rejection: WorkspaceCodemapBindingDemandRejection) -> Code {
        switch rejection {
        case .rootNotRegistered: Code("root_not_registered")
        case .capabilityUnavailable: Code("capability_unavailable")
        case .rootEpochMismatch: Code("root_epoch_mismatch")
        case .rootPathMismatch: Code("root_path_mismatch")
        case .invalidIdentity: Code("invalid_identity")
        case .catalogGenerationMismatch: Code("catalog_generation_mismatch")
        case .requestGenerationInvalid: Code("request_generation_invalid")
        case .stalePathGeneration: Code("stale_path_generation")
        case .staleIngressGeneration: Code("stale_ingress_generation")
        case .languageMismatch: Code("language_mismatch")
        case .classificationMismatch: Code("classification_mismatch")
        case .sourceAuthorityUnavailable: Code("source_authority_unavailable")
        case .repositoryAuthorityChanged: Code("repository_authority_changed")
        case let .overlayRejected(overlay): Code("overlay_rejected", code(for: overlay))
        case .staleCompletion: Code("stale_completion")
        }
    }

    private static func code(for rejection: WorkspaceCodemapLiveDemandRejection) -> Code {
        switch rejection {
        case .rootNotRegistered: Code("root_not_registered")
        case .rootAuthorityInvalid: Code("root_authority_invalid")
        case .rootEpochMismatch: Code("root_epoch_mismatch")
        case .catalogGenerationMismatch: Code("catalog_generation_mismatch")
        case .repositoryAuthorityMismatch: Code("repository_authority_mismatch")
        case .invalidToken: Code("invalid_token")
        case .pathOutsideRoot: Code("path_outside_root")
        case .staleRequestGeneration: Code("stale_request_generation")
        case .requestGenerationConflict: Code("request_generation_conflict")
        case .admissionReservationInvalid: Code("admission_reservation_invalid")
        }
    }

    private static func code(for reason: WorkspaceCodemapGitTerminalUnavailableReason) -> Code {
        switch reason {
        case .nonGit: Code("non_git")
        case .bareRepository: Code("bare_repository")
        case .unsupportedObjectFormat: Code("unsupported_object_format")
        case .unsupportedGit: Code("unsupported_git")
        case .invalidLayout: Code("invalid_layout")
        case .invalidLoadedRootContainment: Code("invalid_loaded_root_containment")
        case .namespaceUnavailable: Code("namespace_unavailable")
        case .rootEpochBindingMismatch: Code("root_epoch_binding_mismatch")
        case .releasedRootEpoch: Code("released_root_epoch")
        }
    }

    private static func code(for reason: WorkspaceCodemapGitTransientUnavailableReason) -> Code {
        switch reason {
        case .gitProcessUnavailable: Code("git_process_unavailable")
        case .repositoryChanging: Code("repository_changing")
        case .permissionFailure: Code("permission_failure")
        case .runtimeUnavailable: Code("runtime_unavailable")
        }
    }

    private static func code(for reason: WorkspaceCodemapBindingDemandUnavailableReason) -> Code {
        switch reason {
        case .unsupportedFileType: Code("unsupported_file_type")
        case .missing: Code("missing")
        case .securityExcluded: Code("security_excluded")
        case .nonRegular: Code("non_regular")
        case .oversized: Code("oversized")
        case .transient: Code("transient")
        case let .terminalArtifact(outcome): Code("terminal_artifact", code(for: outcome))
        }
    }

    private static func code(for outcome: WorkspaceCodemapLiveArtifactOutcome) -> Code {
        switch outcome {
        case .ready: Code("ready")
        case .readyNoSymbols: Code("ready_no_symbols")
        case .oversize: Code("oversize")
        case .decodeFailed: Code("decode_failed")
        case .parseFailed: Code("parse_failed")
        }
    }

    private static func code(for reason: WorkspaceCodemapPresentationFreezeUnavailableReason) -> Code {
        switch reason {
        case .emptyRequest: Code("empty_request")
        case .entryLimitExceeded: Code("entry_limit_exceeded")
        case .retainedBundleLimitExceeded: Code("retained_bundle_limit_exceeded")
        case .duplicateFileID: Code("duplicate_file_id")
        case .mixedRootEpoch: Code("mixed_root_epoch")
        case .pending: Code("pending")
        case let .demandUnavailable(_, demand): Code("demand_unavailable", code(for: demand))
        case .logicalPathMismatch: Code("logical_path_mismatch")
        case .staleCurrentness: Code("stale_currentness")
        case .handleRevoked: Code("handle_revoked")
        }
    }

    private static func code(for reason: WorkspaceCodemapPresentationRenderUnavailableReason) -> Code {
        switch reason {
        case .bundleNotRetained: Code("bundle_not_retained")
        case .bundleMetadataMismatch: Code("bundle_metadata_mismatch")
        case .staleCurrentness: Code("stale_currentness")
        case .handleRevoked: Code("handle_revoked")
        case .noRenderableCodemap: Code("no_renderable_codemap")
        }
    }

    private static func code(for issue: WorkspaceCodemapOperationCandidateIssue) -> Code {
        switch issue {
        case .fileNotCataloged: Code("file_not_cataloged")
        case .fileOutsideRootScope: Code("file_outside_root_scope")
        case .logicalPathUnavailable: Code("logical_path_unavailable")
        case .incompleteRootSet: Code("incomplete_root_set")
        }
    }
}
