import Combine
import Foundation
import MCP

// SEARCH-HELPER: ask_oracle, oracle operation, operation_id, op:"wait", op:"cancel", pending, steering wake, request_id

/// Execution receipts and delivery state for bounded, resumable `ask_oracle` consultations
/// (Oracle resumable wait plan §3.3).
///
/// The store is owned once per `OracleViewModel` and lives exactly as long as the streams it
/// observes. It owns *receipts* (identity, owner scope, frozen finalization request), the
/// *phase projection* written by exactly one completion observer per operation, the
/// first-writer-wins terminal-reason stamp, single-flight delivery, tombstones, and the park
/// primitive used by `op:"wait"`. It never owns or cancels a query, never duplicates stream
/// state, and is never persisted: relaunch loses it by design.
@MainActor
final class OracleMCPOperationStore: ObservableObject {
    // MARK: - Public types

    enum Phase: String, Equatable {
        case starting
        case running
        case cancelling
        case ready
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .ready, .failed, .cancelled: true
            case .starting, .running, .cancelling: false
            }
        }
    }

    enum DeliveryState: String, Equatable {
        case undelivered
        case delivering
        case delivered
    }

    /// Terminal-reason stamp minted from the Oracle stream lifecycle. `completed` is never
    /// stamped: the observer classifies an absent stamp on a finalized message as completion.
    enum TerminalReason: String, Equatable {
        case cancelled
        case failed
    }

    /// Owner scope frozen at registration. Session-owned operations match on the durable
    /// `agentSessionID` across run rotation; run-only operations require the exact run.
    struct OwnerScope: Equatable {
        let tabID: UUID
        let agentSessionID: UUID?
        let runID: UUID?
        /// Attribution only; never consulted by the owner rule.
        let originatingRunID: UUID?

        init(tabID: UUID, agentSessionID: UUID?, runID: UUID?, originatingRunID: UUID? = nil) {
            self.tabID = tabID
            self.agentSessionID = agentSessionID
            self.runID = runID
            self.originatingRunID = originatingRunID ?? runID
        }

        /// One authority: the extracted pure rule plus a tab check, `allowUnownedLegacy:false`.
        @MainActor
        func admits(caller: OwnerScope) -> Bool {
            guard caller.tabID == tabID else { return false }
            return OracleViewModel.oracleOwnerMatches(
                ownerSessionID: agentSessionID,
                ownerRunID: runID,
                callerSessionID: caller.agentSessionID,
                callerRunID: caller.runID,
                allowUnownedLegacy: false
            )
        }
    }

    /// Presentation frozen at send and finalized exactly once per operation (plan §3.5).
    struct FinalizationRequest: Equatable {
        let mode: String
        let message: String
        let responseMode: OracleResponseMode
        let exportResponse: Bool
        let exportDestination: OracleExportDestination?

        var requestsExport: Bool {
            exportResponse || responseMode != .full
        }
    }

    /// Explicit duplicate-spend key (plan §3.9): caller-supplied `request_id` scoped to the
    /// authenticated durable owner (or exact run) plus tab.
    struct RequestKey: Hashable {
        let tabID: UUID
        let agentSessionID: UUID?
        let runID: UUID?
        let requestID: UUID

        init(owner: OwnerScope, requestID: UUID) {
            tabID = owner.tabID
            agentSessionID = owner.agentSessionID
            runID = owner.agentSessionID == nil ? owner.runID : nil
            self.requestID = requestID
        }
    }

    enum ReserveOutcome: Equatable {
        case reserved(UUID)
        /// Same key, identical intent: observe the existing handle; nothing is spent.
        case existing(UUID)
    }

    enum WaitOutcome: String, Equatable {
        case settled
        case steering
        case polled
        case deadline
        case cancelled
    }

    /// Invocation-owned wake source (an `OracleMCPWaitScope` in `MCPServerViewModel`).
    /// The store never learns run identity; it only observes a sticky flag and a wake callback.
    struct ExternalWake {
        let isRequested: @MainActor () -> Bool
        let subscribe: @MainActor (_ onWake: @escaping @MainActor () -> Void) -> Void
        let unsubscribe: @MainActor () -> Void
    }

    enum Lookup: Equatable {
        case found(Snapshot)
        case expired(Tombstone)
        case notFound
    }

    /// Value copy of one operation for wire building and cards.
    struct Snapshot: Equatable {
        let operationID: UUID
        let phase: Phase
        let delivery: DeliveryState
        let createdAt: Date
        let terminalAt: Date?
        let deliveredAt: Date?
        let chatID: UUID?
        let chatShortID: String?
        let queryID: UUID?
        let owner: OwnerScope
        let finalization: FinalizationRequest
        let terminalReason: TerminalReason?
        let requestID: UUID?
        let modelPresetName: String?
        let cancelRequested: Bool
    }

    /// Card-facing summary (plan §3.11). Published on phase/delivery transitions only.
    struct Summary: Equatable {
        let operationID: UUID
        let phase: Phase
        let delivery: DeliveryState
        let createdAt: Date
        let terminalAt: Date?
        let deliveredAt: Date?
        let chatID: UUID?
        let chatShortID: String?
        let chatName: String?
        let queryID: UUID?
        let mode: String
        let modelPresetName: String?
        let terminalReason: TerminalReason?

        var isTerminal: Bool {
            phase.isTerminal
        }

        /// The parent has received the final result (delivered exactly once, cached for replay).
        var isCollected: Bool {
            delivery == .delivered
        }

        /// Registration → terminal (or now while still running).
        func elapsed(at now: Date = Date()) -> TimeInterval {
            max(0, (terminalAt ?? now).timeIntervalSince(createdAt))
        }
    }

    struct Tombstone: Equatable {
        let operationID: UUID
        let owner: OwnerScope
        let chatShortID: String?
        let requestKey: RequestKey?
        let intentDigest: String?
        let evictedAt: Date
    }

    /// Message-side authority reads performed by the completion observer.
    enum MessageState: Equatable {
        case missing
        case finalized
        case notFinalized
    }

    struct Dependencies {
        var waitUntilMessageFinalised: @Sendable (_ queryID: UUID) async throws -> Void
        var messageState: @MainActor (_ queryID: UUID) -> MessageState
        var captureReply: @MainActor (_ ticket: OracleViewModel.OracleMCPSendTicket) throws -> [String: Value]
        var unpinSession: @MainActor (_ chatID: UUID) -> Void
        var chatName: @MainActor (_ chatID: UUID) -> String?
        var now: @MainActor () -> Date

        init(
            waitUntilMessageFinalised: @escaping @Sendable (_ queryID: UUID) async throws -> Void,
            messageState: @escaping @MainActor (_ queryID: UUID) -> MessageState,
            captureReply: @escaping @MainActor (_ ticket: OracleViewModel.OracleMCPSendTicket) throws -> [String: Value],
            unpinSession: @escaping @MainActor (_ chatID: UUID) -> Void,
            chatName: @escaping @MainActor (_ chatID: UUID) -> String? = { _ in nil },
            now: @escaping @MainActor () -> Date = { Date() }
        ) {
            self.waitUntilMessageFinalised = waitUntilMessageFinalised
            self.messageState = messageState
            self.captureReply = captureReply
            self.unpinSession = unpinSession
            self.chatName = chatName
            self.now = now
        }
    }

    // MARK: - Limits (plan §3.3)

    static let deliveredRetentionSeconds: TimeInterval = 1800
    static let undeliveredRetentionSeconds: TimeInterval = 24 * 60 * 60
    static let maxTerminalRecords = 128
    static let maxTombstones = 512

    // MARK: - Private state

    private enum Delivery {
        case undelivered
        case delivering(Task<[String: Value], Error>)
        case delivered([String: Value], Date)

        var state: DeliveryState {
            switch self {
            case .undelivered: .undelivered
            case .delivering: .delivering
            case .delivered: .delivered
            }
        }
    }

    private final class Record {
        let operationID: UUID
        let createdAt: Date
        let owner: OwnerScope
        var finalization: FinalizationRequest
        var requestKey: RequestKey?
        var intentDigest: String?
        var phase: Phase = .starting
        var chatID: UUID?
        var chatShortID: String?
        var queryID: UUID?
        var ticket: OracleViewModel.OracleMCPSendTicket?
        var ownsPin = false
        var terminalReason: TerminalReason?
        var terminalDetail: String?
        var terminalAt: Date?
        var cancelRequested = false
        var rawReply: [String: Value]?
        var startupRejection: ChatToolError?
        var rejectedRequestKeyWasReleased = false
        var delivery: Delivery = .undelivered
        var startupTask: Task<ChatToolError?, Never>?
        var completionTask: Task<Void, Never>?

        init(
            operationID: UUID,
            createdAt: Date,
            owner: OwnerScope,
            finalization: FinalizationRequest,
            requestKey: RequestKey?,
            intentDigest: String?
        ) {
            self.operationID = operationID
            self.createdAt = createdAt
            self.owner = owner
            self.finalization = finalization
            self.requestKey = requestKey
            self.intentDigest = intentDigest
        }
    }

    private struct UsedRequestKey {
        let operationID: UUID
        let chatShortID: String?
        let intentDigest: String?
    }

    private struct Waiter {
        let id: UUID
        let operationIDs: [UUID]
        let continuation: CheckedContinuation<WaitOutcome, Never>
        var deadlineTask: Task<Void, Never>?
        let externalWake: ExternalWake?
    }

    private let dependencies: Dependencies
    private var records: [UUID: Record] = [:]
    private var creationOrder: [UUID] = []
    private var recordIDByQueryID: [UUID: UUID] = [:]
    private var recordIDByRequestKey: [RequestKey: UUID] = [:]
    /// Store-lifetime spend markers. Tombstone compaction must never make a used key reusable.
    private var usedRequestKeys: [RequestKey: UsedRequestKey] = [:]
    private var tombstones: [UUID: Tombstone] = [:]
    private var tombstoneOrder: [UUID] = []
    private var tombstoneByRequestKey: [RequestKey: UUID] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var isTornDown = false

    /// Bumped on phase and delivery transitions only — never per streamed token.
    @Published private(set) var phaseRevision: Int = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Registration and binding

    /// Reserves a `starting` receipt synchronously (plan §3.9). With a `requestKey`, an
    /// identical intentDigest observes the existing handle, a different one throws before any
    /// mutation, and an evicted key throws `oracle_operation_expired`.
    func reserve(
        owner: OwnerScope,
        finalization: FinalizationRequest,
        requestKey: RequestKey? = nil,
        intentDigest: String? = nil
    ) throws -> ReserveOutcome {
        purge()
        if let requestKey {
            if let existingID = recordIDByRequestKey[requestKey], let existing = records[existingID] {
                guard existing.intentDigest == intentDigest else {
                    throw ChatToolError.invalidParams(
                        "request_id \(requestKey.requestID.uuidString) was already used for a different consultation (operation_id \(existingID.uuidString)). Use a fresh request_id for a new question, or omit request_id."
                    )
                }
                return .existing(existingID)
            }
            if let tombstoneID = tombstoneByRequestKey[requestKey], let tombstone = tombstones[tombstoneID] {
                throw ChatToolError.oracleOperationExpired(
                    "request_id \(requestKey.requestID.uuidString) refers to an evicted operation \(tombstoneID.uuidString). Do not resend; read the chat with oracle_chat_log\(tombstone.chatShortID.map { " (chat_id \($0))" } ?? "").",
                    details: ["operation_id": tombstoneID.uuidString]
                )
            }
            if let used = usedRequestKeys[requestKey] {
                guard used.intentDigest == intentDigest else {
                    throw ChatToolError.invalidParams(
                        "request_id \(requestKey.requestID.uuidString) was already used for a different consultation (operation_id \(used.operationID.uuidString)). Use a fresh request_id for a new question, or omit request_id."
                    )
                }
                throw ChatToolError.oracleOperationExpired(
                    "request_id \(requestKey.requestID.uuidString) refers to an evicted operation \(used.operationID.uuidString). Do not resend; read the chat with oracle_chat_log\(used.chatShortID.map { " (chat_id \($0))" } ?? "").",
                    details: ["operation_id": used.operationID.uuidString]
                )
            }
        }
        let operationID = UUID()
        let record = Record(
            operationID: operationID,
            createdAt: dependencies.now(),
            owner: owner,
            finalization: finalization,
            requestKey: requestKey,
            intentDigest: intentDigest
        )
        records[operationID] = record
        creationOrder.append(operationID)
        if let requestKey {
            recordIDByRequestKey[requestKey] = operationID
        }
        bumpRevision()
        return .reserved(operationID)
    }

    /// Removes a receipt whose start was rejected before any chat or query existed. The same
    /// `request_id` may then be retried; nothing was spent.
    func discardUnstarted(_ operationID: UUID) {
        guard let record = records[operationID], record.phase == .starting, record.queryID == nil else { return }
        record.startupTask = nil
        remove(record, tombstone: false)
        bumpRevision()
        // Missing records count as settled; wake observers parked on this starting receipt.
        resumeWaitersSettled(by: operationID)
    }

    /// Publishes a pre-send rejection to every observer that already received or joined this
    /// handle. No consultation was accepted, so the request key is released for a real retry
    /// while the operation ID remains deliverable with the original structured error.
    func rejectStartup(_ operationID: UUID, error: ChatToolError) {
        guard let record = records[operationID], record.phase == .starting, record.queryID == nil else { return }
        if let requestKey = record.requestKey, recordIDByRequestKey[requestKey] == operationID {
            recordIDByRequestKey.removeValue(forKey: requestKey)
            record.rejectedRequestKeyWasReleased = true
        }
        record.requestKey = nil
        record.intentDigest = nil
        record.startupTask = nil
        record.startupRejection = error
        record.terminalReason = .failed
        record.terminalDetail = "startup_rejected"
        record.terminalAt = dependencies.now()
        record.phase = .failed
        bumpRevision()
        resumeWaitersSettled(by: operationID)
    }

    func updateFinalization(_ operationID: UUID, finalization: FinalizationRequest) {
        guard let record = records[operationID], record.phase == .starting else { return }
        record.finalization = finalization
    }

    func installStartupTask(_ operationID: UUID, task: Task<ChatToolError?, Never>) {
        guard let record = records[operationID], record.phase == .starting else {
            task.cancel()
            return
        }
        record.startupTask = task
    }

    func finishStartupTask(_ operationID: UUID) {
        records[operationID]?.startupTask = nil
    }

    /// The only startup outcome an attached originator must throw instead of delivering a lane.
    /// Bound operation completion is independent of any remaining post-bind startup work.
    func startupRejection(for operationID: UUID) -> ChatToolError? {
        records[operationID]?.startupRejection
    }

    /// Binds the accepted send at the first synchronous point after `.started` (plan §3.4).
    /// Transfers the ticket's single pin to the operation and spawns the one completion
    /// observer that will write the terminal phase.
    func bind(
        _ operationID: UUID,
        ticket: OracleViewModel.OracleMCPSendTicket,
        chatShortID: String?
    ) {
        guard let record = records[operationID], record.phase == .starting, record.queryID == nil else {
            // Unknown or already bound: the caller keeps the pin it holds.
            return
        }
        record.phase = .running
        record.chatID = ticket.chatID
        record.chatShortID = chatShortID
        record.queryID = ticket.queryID
        record.ticket = ticket
        record.ownsPin = true
        recordIDByQueryID[ticket.queryID] = operationID
        if let requestKey = record.requestKey {
            usedRequestKeys[requestKey] = UsedRequestKey(
                operationID: operationID,
                chatShortID: chatShortID,
                intentDigest: record.intentDigest
            )
        }
        let queryID = ticket.queryID
        let waitUntilMessageFinalised = dependencies.waitUntilMessageFinalised
        record.completionTask = Task { @MainActor [weak self] in
            var observerCancelled = false
            do {
                try await waitUntilMessageFinalised(queryID)
            } catch {
                observerCancelled = true
            }
            if Task.isCancelled {
                observerCancelled = true
            }
            self?.completeObservation(operationID, observerCancelled: observerCancelled)
        }
        bumpRevision()
    }

    // MARK: - Stream lifecycle inputs

    /// First-writer-wins terminal-reason stamp (plan §3.8). No-op for unbound queries, so
    /// UI-only sends accumulate nothing. Never writes the phase; the observer does.
    func noteStreamTerminal(queryID: UUID, reason: TerminalReason, detail: String? = nil) {
        guard let operationID = recordIDByQueryID[queryID], let record = records[operationID] else { return }
        guard record.terminalReason == nil, !record.phase.isTerminal else { return }
        record.terminalReason = reason
        record.terminalDetail = detail
    }

    /// Atomically claims the one allowed stop attempt before any suspension. Terminal and
    /// already-cancelling operations reject the claim.
    func beginCancelRequest(_ operationID: UUID) -> Bool {
        guard let record = records[operationID], record.phase == .running else { return false }
        record.phase = .cancelling
        record.cancelRequested = true
        bumpRevision()
        return true
    }

    /// Restores a rejected stop attempt only when completion has not already won.
    func cancelRequestRejected(_ operationID: UUID) {
        guard let record = records[operationID], record.phase == .cancelling else { return }
        record.phase = .running
        record.cancelRequested = false
        bumpRevision()
    }

    /// Compatibility wrapper for existing lifecycle call sites.
    func noteCancelRequested(_ operationID: UUID) {
        _ = beginCancelRequest(operationID)
    }

    // MARK: - Reads

    func snapshot(_ operationID: UUID) -> Snapshot? {
        records[operationID].map(makeSnapshot)
    }

    /// Immutable reply context captured at bind; feeds `modelIdentityFields` for pending stubs.
    func replyContext(_ operationID: UUID) -> OracleViewModel.OracleMCPSendReplyContext? {
        records[operationID]?.ticket?.replyContext
    }

    func lookup(_ operationID: UUID, caller: OwnerScope) -> Lookup {
        if let record = records[operationID] {
            return record.owner.admits(caller: caller) ? .found(makeSnapshot(record)) : .notFound
        }
        if let tombstone = tombstones[operationID] {
            return tombstone.owner.admits(caller: caller) ? .expired(tombstone) : .notFound
        }
        return .notFound
    }

    /// Creation-ordered operations the caller owns whose final result has not been delivered
    /// (the post-compaction recovery path for `op:"wait"` without IDs).
    func undeliveredOperationIDs(owner caller: OwnerScope) -> [UUID] {
        purge()
        return creationOrder.compactMap { id -> UUID? in
            guard let record = records[id], record.owner.admits(caller: caller) else { return nil }
            if case .delivered = record.delivery { return nil }
            return id
        }
    }

    /// Non-terminal operations the caller owns, creation order.
    func runningOperationIDs(owner caller: OwnerScope) -> [UUID] {
        creationOrder.compactMap { id -> UUID? in
            guard let record = records[id], record.owner.admits(caller: caller), !record.phase.isTerminal else { return nil }
            return id
        }
    }

    /// Non-terminal operations in a tab, regardless of owner (used by busy/cap rejection text).
    func runningOperationIDs(inTab tabID: UUID?) -> [UUID] {
        guard let tabID else { return [] }
        return creationOrder.compactMap { id -> UUID? in
            guard let record = records[id], record.owner.tabID == tabID, !record.phase.isTerminal else { return nil }
            return id
        }
    }

    /// Non-terminal operations bound to one chat.
    func runningOperationIDs(chatID: UUID) -> [UUID] {
        creationOrder.compactMap { id -> UUID? in
            guard let record = records[id], record.chatID == chatID, !record.phase.isTerminal else { return nil }
            return id
        }
    }

    func allSettled(_ operationIDs: [UUID]) -> Bool {
        operationIDs.allSatisfy { records[$0]?.phase.isTerminal ?? true }
    }

    func elapsedSeconds(for operationID: UUID) -> Int? {
        guard let record = records[operationID] else { return nil }
        return Int(max(0, (record.terminalAt ?? dependencies.now()).timeIntervalSince(record.createdAt)))
    }

    func summary(for operationID: UUID) -> Summary? {
        guard let record = records[operationID] else { return nil }
        return Summary(
            operationID: record.operationID,
            phase: record.phase,
            delivery: record.delivery.state,
            createdAt: record.createdAt,
            terminalAt: record.terminalAt,
            deliveredAt: deliveredAt(record),
            chatID: record.chatID,
            chatShortID: record.chatShortID,
            chatName: record.chatID.flatMap { dependencies.chatName($0) },
            queryID: record.queryID,
            mode: record.finalization.mode,
            modelPresetName: record.ticket?.replyContext.modelPresetName,
            terminalReason: record.terminalReason
        )
    }

    func summary(forOperationIDString raw: String) -> Summary? {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return summary(for: id)
    }

    // MARK: - Park primitive (plan §3.6)

    /// Parks until every requested operation is terminal, the external wake fires, the
    /// deadline passes, or the task is cancelled. A same-turn double-check resumes immediately
    /// when any of those already holds; `timeoutSeconds <= 0` never parks. Removing the waiter
    /// record is the exactly-once resume token.
    func awaitSettlement(
        of operationIDs: [UUID],
        timeoutSeconds: TimeInterval,
        externalWake: ExternalWake?
    ) async -> WaitOutcome {
        if allSettled(operationIDs) { return .settled }
        if externalWake?.isRequested() == true { return .steering }
        if timeoutSeconds <= 0 { return .polled }
        if Task.isCancelled { return .cancelled }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
                if allSettled(operationIDs) {
                    continuation.resume(returning: .settled)
                    return
                }
                if externalWake?.isRequested() == true {
                    continuation.resume(returning: .steering)
                    return
                }
                if isTornDown {
                    continuation.resume(returning: .cancelled)
                    return
                }
                var waiter = Waiter(
                    id: waiterID,
                    operationIDs: operationIDs,
                    continuation: continuation,
                    deadlineTask: nil,
                    externalWake: externalWake
                )
                waiter.deadlineTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    self?.resumeWaiter(waiterID, outcome: .deadline)
                }
                waiters[waiterID] = waiter
                externalWake?.subscribe { [weak self] in
                    self?.resumeWaiter(waiterID, outcome: .steering)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiter(waiterID, outcome: .cancelled)
            }
        }
    }

    private func resumeWaiter(_ waiterID: UUID, outcome: WaitOutcome) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.deadlineTask?.cancel()
        waiter.externalWake?.unsubscribe()
        // Completion beats wake: a settled set is reported as settled whatever woke us.
        let effective: WaitOutcome = allSettled(waiter.operationIDs) ? .settled : outcome
        waiter.continuation.resume(returning: effective)
    }

    private func resumeWaitersSettled(by operationID: UUID) {
        for waiter in Array(waiters.values) where waiter.operationIDs.contains(operationID) {
            if allSettled(waiter.operationIDs) {
                resumeWaiter(waiter.id, outcome: .settled)
            }
        }
    }

    // MARK: - Completion observer (plan §3.5)

    private func completeObservation(_ operationID: UUID, observerCancelled: Bool) {
        guard let record = records[operationID], !record.phase.isTerminal else { return }
        let terminalPhase: Phase
        var detail = record.terminalDetail
        if observerCancelled {
            terminalPhase = .failed
            detail = "observer_cancelled"
            if record.terminalReason == nil { record.terminalReason = .failed }
        } else if let reason = record.terminalReason {
            terminalPhase = reason == .cancelled ? .cancelled : .failed
        } else if let queryID = record.queryID {
            switch dependencies.messageState(queryID) {
            case .finalized:
                terminalPhase = .ready
            case .missing:
                terminalPhase = .failed
                detail = "message_missing"
                record.terminalReason = .failed
            case .notFinalized:
                terminalPhase = .failed
                detail = "finalization_unobserved"
                record.terminalReason = .failed
            }
        } else {
            terminalPhase = .failed
            detail = "query_unbound"
            record.terminalReason = .failed
        }

        if let ticket = record.ticket {
            record.rawReply = try? dependencies.captureReply(ticket)
        }
        if record.ownsPin, let chatID = record.chatID {
            record.ownsPin = false
            dependencies.unpinSession(chatID)
        }
        record.terminalDetail = detail
        record.terminalAt = dependencies.now()
        record.phase = terminalPhase
        record.completionTask = nil
        bumpRevision()
        resumeWaitersSettled(by: operationID)
    }

    // MARK: - Delivery (plan §3.5)

    /// Base lane for a terminal operation before presentation. Completed lanes are the raw
    /// reply plus `status`/`operation_id`; cancelled and failed lanes never carry `response`.
    func baseLane(_ operationID: UUID) -> [String: Value]? {
        guard let record = records[operationID], record.phase.isTerminal else { return nil }
        return makeBaseLane(record)
    }

    /// Single-flight delivery: returns the cached result, awaits an in-progress delivery, or
    /// runs `finalize` exactly once for a completed lane. Cancelled and failed lanes are never
    /// finalized (no export). A throw reverts to `undelivered` for retry.
    func deliver(
        _ operationID: UUID,
        finalize: @escaping @MainActor (_ result: inout [String: Value], _ request: FinalizationRequest) async throws -> Void
    ) async throws -> [String: Value] {
        guard let record = records[operationID] else {
            throw ChatToolError.oracleOperationNotFound("operation \(operationID.uuidString) is unknown")
        }
        guard record.phase.isTerminal else {
            throw ChatToolError.internalError("operation \(operationID.uuidString) is not terminal")
        }
        switch record.delivery {
        case let .delivered(result, _):
            return result
        case let .delivering(task):
            return try await task.value
        case .undelivered:
            let base = makeBaseLane(record)
            let request = record.finalization
            let shouldFinalize = record.phase == .ready
            let task = Task<[String: Value], Error> { @MainActor in
                var result = base
                if shouldFinalize {
                    try await finalize(&result, request)
                }
                return result
            }
            record.delivery = .delivering(task)
            bumpRevision()
            do {
                let result = try await task.value
                // Re-read: eviction or teardown may have removed the record while finalizing.
                if let current = records[operationID] {
                    current.delivery = .delivered(result, dependencies.now())
                    bumpRevision()
                }
                return result
            } catch {
                if let current = records[operationID] {
                    current.delivery = .undelivered
                    bumpRevision()
                }
                throw error
            }
        }
    }

    // MARK: - Lifetime (plan §3.3)

    /// Lazy purge at register/wait entry: delivered results are kept 1 800 s for replay,
    /// undelivered terminal records 24 h, and at most 128 terminal records (evict oldest
    /// delivered first, never active work). Compact tombstones survive eviction.
    func purge(now: Date? = nil) {
        let now = now ?? dependencies.now()
        var evicted: [Record] = []
        for id in creationOrder {
            guard let record = records[id], record.phase.isTerminal else { continue }
            switch record.delivery {
            case let .delivered(_, at):
                if now.timeIntervalSince(at) > Self.deliveredRetentionSeconds {
                    evicted.append(record)
                }
            case .undelivered, .delivering:
                if now.timeIntervalSince(record.terminalAt ?? record.createdAt) > Self.undeliveredRetentionSeconds {
                    evicted.append(record)
                }
            }
        }
        for record in evicted {
            remove(record, tombstone: true, now: now)
        }

        var terminal = creationOrder.compactMap { id -> Record? in
            guard let record = records[id], record.phase.isTerminal else { return nil }
            return record
        }
        if terminal.count > Self.maxTerminalRecords {
            // Oldest delivered first, then oldest undelivered.
            terminal.sort { lhs, rhs in
                let lhsDelivered = lhs.delivery.state == .delivered
                let rhsDelivered = rhs.delivery.state == .delivered
                if lhsDelivered != rhsDelivered { return lhsDelivered }
                return lhs.createdAt < rhs.createdAt
            }
            let overflow = terminal.count - Self.maxTerminalRecords
            for record in terminal.prefix(overflow) {
                remove(record, tombstone: true, now: now)
            }
        }
        if !evicted.isEmpty || terminal.count > Self.maxTerminalRecords {
            bumpRevision()
        }
    }

    private func remove(_ record: Record, tombstone: Bool, now: Date? = nil) {
        records.removeValue(forKey: record.operationID)
        creationOrder.removeAll { $0 == record.operationID }
        if let queryID = record.queryID {
            recordIDByQueryID.removeValue(forKey: queryID)
        }
        if let requestKey = record.requestKey {
            recordIDByRequestKey.removeValue(forKey: requestKey)
        }
        record.startupTask?.cancel()
        record.completionTask?.cancel()
        if record.ownsPin, let chatID = record.chatID {
            record.ownsPin = false
            dependencies.unpinSession(chatID)
        }
        guard tombstone else { return }
        let stone = Tombstone(
            operationID: record.operationID,
            owner: record.owner,
            chatShortID: record.chatShortID,
            requestKey: record.requestKey,
            intentDigest: record.intentDigest,
            evictedAt: now ?? dependencies.now()
        )
        tombstones[record.operationID] = stone
        tombstoneOrder.append(record.operationID)
        if let requestKey = record.requestKey {
            tombstoneByRequestKey[requestKey] = record.operationID
        }
        while tombstoneOrder.count > Self.maxTombstones {
            let oldest = tombstoneOrder.removeFirst()
            if let removed = tombstones.removeValue(forKey: oldest), let key = removed.requestKey,
               tombstoneByRequestKey[key] == oldest
            {
                tombstoneByRequestKey.removeValue(forKey: key)
            }
        }
    }

    /// Cancels every completion observer and resumes parked waiters. Streams are untouched.
    func teardown() {
        isTornDown = true
        for record in records.values {
            record.startupTask?.cancel()
            record.startupTask = nil
            record.completionTask?.cancel()
            record.completionTask = nil
        }
        for waiterID in Array(waiters.keys) {
            resumeWaiter(waiterID, outcome: .cancelled)
        }
    }

    // MARK: - Helpers

    private func bumpRevision() {
        phaseRevision &+= 1
    }

    private func deliveredAt(_ record: Record) -> Date? {
        if case let .delivered(_, at) = record.delivery { return at }
        return nil
    }

    private func makeSnapshot(_ record: Record) -> Snapshot {
        Snapshot(
            operationID: record.operationID,
            phase: record.phase,
            delivery: record.delivery.state,
            createdAt: record.createdAt,
            terminalAt: record.terminalAt,
            deliveredAt: deliveredAt(record),
            chatID: record.chatID,
            chatShortID: record.chatShortID,
            queryID: record.queryID,
            owner: record.owner,
            finalization: record.finalization,
            terminalReason: record.terminalReason,
            requestID: record.requestKey?.requestID,
            modelPresetName: record.ticket?.replyContext.modelPresetName,
            cancelRequested: record.cancelRequested
        )
    }

    private func makeBaseLane(_ record: Record) -> [String: Value] {
        var lane: [String: Value] = record.rawReply ?? [:]
        lane["operation_id"] = .string(record.operationID.uuidString)
        if lane["chat_id"] == nil, let chatShortID = record.chatShortID {
            lane["chat_id"] = .string(chatShortID)
        }
        if let queryID = record.queryID {
            lane["query_id"] = .string(queryID.uuidString)
        }
        if lane["mode"] == nil {
            lane["mode"] = .string(record.finalization.mode)
        }
        switch record.phase {
        case .ready:
            lane["status"] = .string("completed")
        case .cancelled, .failed:
            let partial = lane.removeValue(forKey: "response")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lane["ok"] = .bool(false)
            lane["status"] = .string(record.phase.rawValue)
            if let partial, !partial.isEmpty {
                lane["partial_response"] = .string(partial)
            }
            if record.finalization.requestsExport {
                lane["export_skipped"] = .string(record.phase.rawValue)
            }
            if let rejection = record.startupRejection {
                var errorObject: [String: Value] = [
                    "code": .string(rejection.code.rawValue),
                    "message": .string(rejection.message)
                ]
                if let details = rejection.details {
                    errorObject["details"] = .object(details.mapValues(Value.string))
                }
                lane["error"] = .object(errorObject)
                lane["consultation_started"] = .bool(false)
                if record.rejectedRequestKeyWasReleased {
                    lane["request_id_reusable"] = .bool(true)
                }
            } else {
                let code = record.phase == .cancelled ? "oracle_cancelled" : "oracle_stream_failed"
                var message = record.phase == .cancelled
                    ? "The Oracle consultation was cancelled before it completed."
                    : "The Oracle stream failed before it completed."
                if let detail = record.terminalDetail {
                    message += " (\(detail))"
                }
                lane["error"] = .object(["code": .string(code), "message": .string(message)])
            }
        case .starting, .running, .cancelling:
            break
        }
        return lane
    }

    // MARK: - DEBUG accessors

    #if DEBUG
        func test_recordCount() -> Int {
            records.count
        }

        func test_tombstoneCount() -> Int {
            tombstones.count
        }

        func test_usedRequestKeyCount() -> Int {
            usedRequestKeys.count
        }

        func test_usedRequestIntentDigests() -> [String] {
            usedRequestKeys.values.compactMap(\.intentDigest)
        }

        /// Production-shaped DEBUG start stub used by MCP worktree fixtures.
        func test_bindCompleted(
            _ operationID: UUID,
            ticket: OracleViewModel.OracleMCPSendTicket,
            chatShortID: String?,
            result: [String: Value]
        ) {
            guard let record = records[operationID], record.phase == .starting else { return }
            record.phase = .ready
            record.chatID = ticket.chatID
            record.chatShortID = chatShortID
            record.queryID = ticket.queryID
            record.ticket = ticket
            record.rawReply = result
            record.terminalAt = dependencies.now()
            record.startupTask = nil
            recordIDByQueryID[ticket.queryID] = operationID
            if let requestKey = record.requestKey {
                usedRequestKeys[requestKey] = UsedRequestKey(
                    operationID: operationID,
                    chatShortID: chatShortID,
                    intentDigest: record.intentDigest
                )
            }
            bumpRevision()
            resumeWaitersSettled(by: operationID)
        }

        func test_waiterCount() -> Int {
            waiters.count
        }

        func test_ownsPin(_ operationID: UUID) -> Bool {
            records[operationID]?.ownsPin ?? false
        }

        func test_terminalReason(_ operationID: UUID) -> TerminalReason? {
            records[operationID]?.terminalReason
        }

        func test_terminalDetail(_ operationID: UUID) -> String? {
            records[operationID]?.terminalDetail
        }

        func test_hasCompletionObserver(_ operationID: UUID) -> Bool {
            records[operationID]?.completionTask != nil
        }

        func test_creationOrder() -> [UUID] {
            creationOrder
        }
    #endif
}
