// Runner-side adapter over the shared Phase 1b dispatch-evidence contract
// (`AgentRecoveryDispatchEvidence`) for the Claude native, ACP, and headless provider routes.
//
// It adds only what a runner needs around one provider handoff:
// - recording/attaching the existing run attempt (`AgentRunOwnership.attemptID`) before the
//   provider is invoked;
// - remembering whether the provider boundary was actually entered, so a scope that ends without
//   reaching it settles the same intents back to `queued` (`noteNoHandoff`), while a scope that
//   did reach it without affirmative provider evidence records `deliveryUnknown`. A no-handoff
//   report after the boundary was entered is downgraded to uncertainty, never to a retryable
//   queue entry.
//
// Acceptance is reported only by the route-specific affirmative provider evidence (Claude: the
// expected turn's `turnCompleted(.completed)`; ACP: the `session/prompt` response; headless: model
// output on the provider stream). Transport writes, stream creation, `didSend`, and run start are
// never acceptance.

import Foundation

@MainActor
final class AgentProviderHandoff {
    /// Committed dispatch evidence; `nil` while a run-start handoff is still deferred.
    private var committedEvidence: AgentRecoveryDispatchEvidence?
    /// Input this handoff carries (validated; all durable or all untracked).
    private let constituents: [AgentQueuedInputIdentity]
    /// Observation of a deferred handoff (nothing written: its intents stay `queued`).
    private var deferredObservation: AgentRecoveryDispatchEvidence.Observation = .open
    /// Run attempt a deferred handoff commits under (`attachRunAttempt`).
    private var boundOwnership: AgentRunOwnership?
    private var boundProcessRunID: UUID?
    /// Exact pending-handoff snapshot the provider text prepends, not yet attached to its carrier.
    private var unattachedPendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    /// The provider boundary (transport write / provider call) was entered.
    private(set) var handoffStarted = false
    /// Run attempt this handoff's delivery attempts are recorded against.
    private(set) var runAttemptID: UUID?
    /// Staged next-turn input riding on this handoff's provider text.
    private(set) var carriedStagedInput = AgentCarriedStagedInput()
    /// The one stage-delivery outcome reported for `carriedStagedInput` (see `reportStagedInput`).
    private(set) var reportedStagedInputDisposition: AgentStagedInputDisposition?
    private var stagedInputReporter: ((AgentCarriedStagedInput, AgentStagedInputDisposition) -> Void)?

    private init(evidence: AgentRecoveryDispatchEvidence, constituents: [AgentQueuedInputIdentity], runAttemptID: UUID?) {
        committedEvidence = evidence
        self.constituents = constituents
        self.runAttemptID = runAttemptID
    }

    private init(deferred constituents: [AgentQueuedInputIdentity]) {
        self.constituents = constituents
    }

    /// The committed dispatch evidence (a committed handoff only; tests and diagnostics).
    var evidence: AgentRecoveryDispatchEvidence {
        guard let committedEvidence else {
            preconditionFailure("AgentProviderHandoff.evidence read before its dispatch was committed")
        }
        return committedEvidence
    }

    /// Whether the dispatch commit was written (always true for `begin`; set by `commitDispatch`
    /// for a deferred run-start handoff).
    var isCommitted: Bool {
        committedEvidence != nil
    }

    var isDurable: Bool {
        committedEvidence?.isDurable ?? constituents.allSatisfy(\.isDurable)
    }

    var observation: AgentRecoveryDispatchEvidence.Observation {
        committedEvidence?.observation ?? deferredObservation
    }

    /// Immutable identity of a committed durable dispatch (Phase 4 history baseline): its first
    /// delivery attempt ID, run attempt, and ordered local user items. `nil` when untracked or not
    /// yet committed (no durable dispatch exists to bind a baseline to).
    var dispatchBaselineIdentity: AgentDispatchBaselineIdentity? {
        guard let evidence = committedEvidence, evidence.isDurable, let first = evidence.receipts.first else {
            return nil
        }
        return AgentDispatchBaselineIdentity(
            dispatchID: first.attemptID,
            runAttemptID: runAttemptID,
            userItemIDs: constituents.compactMap(\.userItemID)
        )
    }

    /// Run-start handoff (adopted plan §5): validated now, committed later by `commitDispatch`,
    /// after provider preparation/bootstrap that can create the pending-handoff prefix and once
    /// that exact prefix is attached to the still-`queued` carrier. Nothing is written here.
    static func prepareRunStart(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity]
    ) -> Result<AgentProviderHandoff, AgentRecoveryAdmissionFailure> {
        if let refusal = AgentRecoveryDispatchEvidence.dispatchRefusal(session: session, constituents: constituents) {
            return .failure(refusal)
        }
        let handoff = AgentProviderHandoff(deferred: constituents)
        if handoff.isDurable {
            handoff.heldLane = session.recoveryLane
        }
        return .success(handoff)
    }

    /// Before-handoff step. With `ownership`, the existing run attempt is recorded first (durable
    /// input only) and every delivery attempt carries its ID. Without it (common pre-runner gate),
    /// the runner attaches the run attempt via `attachRunAttempt` before invoking the provider.
    /// The caller re-runs its own synchronous freshness checks after this returns.
    static func begin(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity],
        ownership: AgentRunOwnership?,
        processRunID: UUID?,
        authorization: AgentRecoveryDispatchAuthorization = .liveQueue
    ) async -> Result<AgentProviderHandoff, AgentRecoveryAdmissionFailure> {
        let result = if let ownership {
            await AgentRecoveryDispatchEvidence.begin(
                session: session,
                constituents: constituents,
                ownership: ownership,
                processRunID: processRunID,
                authorization: authorization
            )
        } else {
            await AgentRecoveryDispatchEvidence.begin(
                session: session,
                constituents: constituents,
                runAttemptID: nil,
                authorization: authorization
            )
        }
        return result.map {
            let handoff = AgentProviderHandoff(evidence: $0, constituents: constituents, runAttemptID: ownership?.attemptID)
            handoff.recordPendingHandoffAtCommit(session)
            return handoff
        }
    }

    /// The session's stageable pending-handoff payload when this handoff's dispatch was committed.
    /// That payload was retained for a later send (not carried by this input); any other one was
    /// created after the commit.
    private var stageablePayloadAtCommit: String?

    private func recordPendingHandoffAtCommit(_ session: AgentTabSession) {
        stageablePayloadAtCommit = session.pendingHandoff.hasStageablePayload ? session.pendingHandoff.payload : nil
    }

    /// Whether preparation created a pending-handoff payload after this durable input's dispatch
    /// commit (late bootstrap work): sending would deliver the input without the history its new
    /// conversation needs, while its intent records no prefix. The caller blocks the send.
    func pendingHandoffCreatedAfterCommit(in session: AgentTabSession) -> Bool {
        guard isDurable, isCommitted, session.pendingHandoff.hasStageablePayload else { return false }
        return session.pendingHandoff.payload != stageablePayloadAtCommit
    }

    /// Why a dispatch commit did not happen. The caller must not hand off; the input stays saved.
    enum CommitFailure: Error, Equatable {
        /// A deferred handoff was never bound to its run attempt.
        case runAttemptNotBound
        /// The pending-handoff prefix could not be attached to the carrier intent.
        case pendingHandoffNotAttached(AgentRecoveryControllerFailure)
        /// A prefix was staged after this handoff's dispatch was already committed (late bootstrap
        /// work): sending would deliver a prefix its durable intent does not record.
        case pendingHandoffAfterCommit
        /// The deferred handoff was already settled (no handoff) before its commit.
        case alreadySettled
        case dispatch(AgentRecoveryAdmissionFailure)
        /// The pending-handoff prefix could not be staged with a durable payload ID.
        case pendingHandoffNotSaved

        /// User-facing explanation; the input stays saved in every case.
        var userText: String {
            switch self {
            case .pendingHandoffNotAttached, .pendingHandoffAfterCommit, .pendingHandoffNotSaved:
                AgentPendingHandoffDispatchStaging.blockedReason
            case .runAttemptNotBound, .alreadySettled:
                AgentProviderHandoff.sessionChangedBeforeHandoffMessage
            case let .dispatch(failure):
                failure.dispatchFailureText
            }
        }
    }

    /// The exact pending-handoff snapshot this handoff's provider text prepends. A deferred durable
    /// handoff attaches it to its carrier before committing; a committed one cannot carry it
    /// (`commitDispatch` then fails). Untracked input records nothing.
    func notePendingHandoff(_ snapshot: AgentRecoveryPendingHandoffSnapshot) {
        guard isDurable else { return }
        unattachedPendingHandoff = snapshot
    }

    /// The dispatch commit, immediately before the route's final checks (adopted plan §5 order:
    /// stage payload → attach to the queued carrier → ensure the run attempt and commit
    /// `dispatching` → final check → handoff). A committed handoff succeeds unless a prefix was
    /// noted after its commit.
    func commitDispatch(session: AgentTabSession) async -> Result<Void, CommitFailure> {
        if committedEvidence != nil {
            return unattachedPendingHandoff == nil ? .success(()) : .failure(.pendingHandoffAfterCommit)
        }
        guard deferredObservation == .open else { return .failure(.alreadySettled) }
        guard let ownership = boundOwnership else { return .failure(.runAttemptNotBound) }
        // Attach and commit through the lane that validated this input; never a successor lane.
        let issuingLaneIsCurrent = { [weak self] in
            guard let self, isDurable else { return true }
            return heldLane != nil && session.recoveryLane === heldLane
        }
        if let snapshot = unattachedPendingHandoff {
            guard let carrierID = constituents.first?.intentID, issuingLaneIsCurrent(), let lane = heldLane else {
                return .failure(.pendingHandoffNotAttached(.retired))
            }
            if case let .failure(failure) = await lane.attachPendingHandoff(intentID: carrierID, snapshot: snapshot) {
                return .failure(.pendingHandoffNotAttached(failure))
            }
            unattachedPendingHandoff = nil
        }
        guard issuingLaneIsCurrent() else { return .failure(.dispatch(.refused(.laneRetired))) }
        switch await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: constituents,
            ownership: ownership,
            processRunID: boundProcessRunID
        ) {
        case let .failure(failure):
            return .failure(.dispatch(failure))
        case let .success(evidence):
            committedEvidence = evidence
            runAttemptID = ownership.attemptID
            recordPendingHandoffAtCommit(session)
            return .success(())
        }
    }

    /// Records the run attempt and attaches every durable delivery attempt to it. Untracked
    /// handoffs and already-attached ones succeed without writing. On failure the caller must not
    /// hand off (report `noteNoHandoff`).
    func attachRunAttempt(
        ownership: AgentRunOwnership,
        processRunID: UUID?,
        session: AgentTabSession
    ) async -> Result<Void, AgentRecoveryControllerFailure> {
        guard let evidence = committedEvidence else {
            // Deferred: bind only; `commitDispatch` records the run attempt and dispatch together.
            if let boundOwnership, boundOwnership.attemptID != ownership.attemptID {
                return .failure(.store(.runAttemptConflict(ownership.attemptID)))
            }
            boundOwnership = ownership
            boundProcessRunID = processRunID
            runAttemptID = ownership.attemptID
            return .success(())
        }
        guard evidence.isDurable else {
            // Untracked (inactive admission): nothing to write; the attempt still scopes the send.
            if runAttemptID == nil {
                runAttemptID = ownership.attemptID
            }
            return .success(())
        }
        if let runAttemptID {
            return runAttemptID == ownership.attemptID
                ? .success(())
                : .failure(.store(.runAttemptConflict(ownership.attemptID)))
        }
        guard let binding = evidence.receipts.first?.intent.binding,
              let lane = session.recoveryLane,
              lane.binding == binding
        else {
            return .failure(.retired)
        }
        guard AgentRecoveryDispatchEvidence.ownershipIsCompatible(ownership, with: session) else {
            return .failure(.store(.runAttemptConflict(ownership.attemptID)))
        }
        if case let .failure(failure) = await lane.ensureRunAttempt(
            ownership: ownership,
            processRunID: processRunID,
            transcriptTurnID: constituents.first?.userItemID
        ) {
            return .failure(failure)
        }
        for receipt in evidence.receipts {
            if case let .failure(failure) = await lane.attachDeliveryAttempt(
                attemptID: receipt.attemptID,
                ownership: ownership
            ) {
                return .failure(failure)
            }
        }
        runAttemptID = ownership.attemptID
        return .success(())
    }

    /// The final physical-handoff check (R06). Call immediately before the provider boundary, with
    /// no suspension between it and the provider call. `false` when the dispatching lane retired or
    /// reset preparation froze it since the commit: the same intents are settled back to `queued`
    /// (pre-handoff), the carried staged input is released, and the caller must not hand off.
    func enterProviderBoundary(in session: AgentTabSession) -> Bool {
        guard let evidence = committedEvidence, unattachedPendingHandoff == nil,
              evidence.isValidForHandoff(in: session)
        else {
            // Never hand off uncommitted input, or a prefix its durable intent does not record.
            noteNoHandoff(message: Self.sessionChangedBeforeHandoffMessage)
            reportStagedInput(stagedInputDisposition(sent: false))
            return false
        }
        handoffStarted = true
        evidence.noteHandoffBegan()
        return true
    }

    /// Affirmative provider acceptance (refines uncertainty; never downgraded). Late acceptance also
    /// settles the exact staged input this handoff carried as sent.
    func noteAccepted() {
        guard let evidence = committedEvidence else { return }
        evidence.noteAccepted()
        reportStagedInput(.sent)
    }

    func noteDeliveryUnknown() {
        guard let evidence = committedEvidence else {
            // Uncommitted input never reached a provider boundary.
            noteDeferredOutcome(.notHandedOff)
            return
        }
        evidence.noteDeliveryUnknown()
    }

    /// Proven pre-handoff only: once the boundary was entered this records uncertainty instead.
    func noteNoHandoff(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff)
            return
        }
        if handoffStarted {
            evidence.noteDeliveryUnknown()
        } else {
            evidence.noteNoHandoff(message: message)
        }
    }

    /// A deferred handoff wrote nothing: its intents are still `queued` with no attempt.
    private func noteDeferredOutcome(_ outcome: AgentRecoveryDispatchEvidence.Observation) {
        guard deferredObservation == .open else { return }
        deferredObservation = outcome
        // No commit can follow a settled deferred handoff (`commitDispatch` refuses it): an explicit
        // recovery action carried here is fenced and settles as not handed off.
        if outcome != .open, let action = constituents.first?.actionAuthorization {
            heldLane?.recoveryCoordinator?.noteRecoveryActionSubmissionEnded(action)
        }
    }

    /// Held-input reason for a run's own input that is not re-queued after its run ended. Neutral on
    /// delivery: the presented delivery state says whether it may have reached the agent.
    static let runEndedHoldReason = "Its run ended, so it is no longer queued."

    /// The runner drops this handoff's input without re-projecting it; its durable intents are
    /// presented as held input (see `AgentRecoveryDispatchEvidence.holdForUser`).
    func holdForUser(reason: String = AgentProviderHandoff.runEndedHoldReason) {
        // One explanation per handoff: the first (most specific) reason wins.
        guard !heldForUser else { return }
        heldForUser = true
        guard let evidence = committedEvidence else {
            let intentIDs = constituents.compactMap(\.intentID)
            guard !intentIDs.isEmpty, let heldLane else { return }
            heldLane.noteProjectionRemoved(intentIDs: intentIDs, reason: reason)
            return
        }
        evidence.holdForUser(reason: reason)
    }

    /// Lane a deferred handoff's held input is presented through (the lane that validated it).
    private weak var heldLane: AgentRecoverySessionLane?
    private var heldForUser = false

    /// A dispatch commit (or the pending-handoff staging before it) failed: nothing was handed off,
    /// the carried staged input is released, and the durable input is presented as held with the
    /// failure's explanation. Its intents stay saved (`queued` before a commit).
    func blockBeforeHandoff(_ failure: CommitFailure) {
        noteNoHandoff(message: failure.userText)
        reportStagedInput(stagedInputDisposition(sent: false))
        holdForUser(reason: failure.userText)
    }

    /// The boundary was entered but the provider's documented contract proves the input was never
    /// written (Claude: thrown before the stdin write; ACP: thrown without `onSubmitted`).
    func noteProvenNotWritten(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff)
            return
        }
        evidence.noteNoHandoff(message: message)
    }

    /// Verified provider rejection.
    func noteRejected(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.rejected)
            return
        }
        evidence.noteRejected(message: message)
    }

    /// End of the handoff's owning scope: never reached the provider → no handoff; reached it with
    /// no recorded outcome → delivery unknown. Recorded outcomes are left untouched.
    func settleIfUnresolved() {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff)
            reportStagedInput(stagedInputDisposition(sent: false))
            return
        }
        if evidence.observation == .open {
            if handoffStarted {
                evidence.noteDeliveryUnknown()
            } else {
                evidence.noteNoHandoff()
            }
        }
        // Staged input never left without an outcome: the scope's final evidence classifies it.
        reportStagedInput(stagedInputDisposition(sent: false))
    }

    /// End of a run's own initial-input scope (the runner was admitted, so no caller re-queues it):
    /// settles like `settleIfUnresolved`, then presents input that provably never reached the
    /// provider (or was verifiably rejected, both back in `queued`) as held input (F5). Uncertain
    /// or accepted input is not re-presented here.
    func settleRunInputScope() {
        settleIfUnresolved()
        switch observation {
        case .notHandedOff, .rejected:
            holdForUser()
        case .open, .accepted, .deliveryUnknown:
            break
        }
    }

    // MARK: Staged next-turn input

    /// Installs the receiver of this handoff's staged-input outcomes (once; later calls are ignored).
    func installStagedInputReporter(
        _ reporter: @escaping (AgentCarriedStagedInput, AgentStagedInputDisposition) -> Void
    ) {
        guard stagedInputReporter == nil else { return }
        stagedInputReporter = reporter
    }

    /// Records staged input that rides on this handoff's provider text (the first stage of each kind
    /// wins). A stage added after an outcome was already reported receives that outcome now.
    func carryStagedInput(_ input: AgentCarriedStagedInput) {
        var added = AgentCarriedStagedInput()
        if let stage = input.pendingHandoffStage, carriedStagedInput.pendingHandoffStage == nil {
            carriedStagedInput.pendingHandoffStage = stage
            added.pendingHandoffStage = stage
        }
        if let stageID = input.delegatedQuestionStageID, carriedStagedInput.delegatedQuestionStageID == nil {
            carriedStagedInput.delegatedQuestionStageID = stageID
            added.delegatedQuestionStageID = stageID
        }
        guard !added.isEmpty, let reported = reportedStagedInputDisposition else { return }
        stagedInputReporter?(added, reported)
    }

    /// Reports the stage-delivery outcome of the carried staged input. Duplicates are ignored, `.sent`
    /// is final, uncertainty may later resolve either way, and a verified `.notSent` only yields to
    /// late affirmative acceptance. Exact-stage identity keeps any late report away from newer stages.
    func reportStagedInput(_ disposition: AgentStagedInputDisposition) {
        switch (reportedStagedInputDisposition, disposition) {
        case (nil, _), (.deliveryUnknown?, .sent), (.deliveryUnknown?, .notSent), (.notSent?, .sent):
            break
        default:
            return
        }
        reportedStagedInputDisposition = disposition
        guard !carriedStagedInput.isEmpty else { return }
        stagedInputReporter?(carriedStagedInput, disposition)
    }

    /// Reports the staged-input outcome after a send attempt (`sent`: the route's stage-delivery
    /// boundary was reached) from this handoff's evidence.
    func settleStagedInput(sent: Bool) {
        reportStagedInput(stagedInputDisposition(sent: sent))
    }

    /// User-facing text for a committed dispatch whose lane retired or froze before handoff.
    static let sessionChangedBeforeHandoffMessage =
        "This message was not sent because the session changed before it was handed off. It stays saved."

    /// User-facing text for a dispatch that could not be committed before handoff.
    static func dispatchFailureText(_ failure: AgentRecoveryAdmissionFailure) -> String {
        failure.dispatchFailureText
    }

    /// Headless provider streams: model output proves the provider processed the input. Stream
    /// creation, lifecycle, usage, and error results do not.
    static func streamResultProvesProviderAcceptance(_ result: AIStreamResult) -> Bool {
        switch result.type {
        case "content", "reasoning":
            let hasText = !(result.text ?? "").isEmpty
            let hasReasoning = !(result.reasoning ?? "").isEmpty
            return hasText || hasReasoning
        case "tool_call":
            return true
        default:
            return false
        }
    }
}

/// What a send attempt means for staged next-turn input that rode on one handoff (the tab's staged
/// pending-handoff payload and delegated child-question notices). These are stage-delivery boundary
/// semantics, not provider acceptance: an intent's durable delivery state advances only on
/// route-specific affirmative acceptance evidence.
package enum AgentStagedInputDisposition: Equatable {
    /// The route's established stage-delivery boundary was reached (or acceptance was affirmed):
    /// consume or acknowledge that exact stage. Never downgraded by a later outcome.
    case sent
    /// Verified non-handoff, or a rejection proving the staged input was not delivered: release it
    /// for a later send.
    case notSent
    /// The provider boundary was entered without proof either way. Neither consumed nor released:
    /// replaying could deliver it twice, consuming could lose it.
    case deliveryUnknown
}

extension AgentProviderHandoff {
    /// Untracked input (explicit inactive admission) keeps its legacy two-way outcome.
    func stagedInputDisposition(sent: Bool) -> AgentStagedInputDisposition {
        if sent || observation == .accepted {
            return .sent
        }
        guard isDurable, handoffStarted else { return .notSent }
        switch observation {
        case .notHandedOff, .rejected:
            return .notSent
        case .open, .deliveryUnknown, .accepted:
            return .deliveryUnknown
        }
    }
}

/// Staged next-turn input carried by one provider input: the tab's staged pending-handoff payload
/// (exact stage) and/or the delegated child-question notice stage.
package struct AgentCarriedStagedInput: Equatable {
    package var pendingHandoffStage: AgentPendingHandoffStage?
    package var delegatedQuestionStageID: UUID?

    package init(pendingHandoffStage: AgentPendingHandoffStage? = nil, delegatedQuestionStageID: UUID? = nil) {
        self.pendingHandoffStage = pendingHandoffStage
        self.delegatedQuestionStageID = delegatedQuestionStageID
    }

    package var isEmpty: Bool {
        pendingHandoffStage == nil && delegatedQuestionStageID == nil
    }
}

/// A pending-handoff stage prepared for a durable dispatch (adopted plan §5): the snapshot is
/// attached to the carrier by `AgentProviderHandoff.commitDispatch` before the dispatch commit.
package enum AgentPendingHandoffDispatchStaging {
    /// Nothing was staged; the text is sent unchanged.
    case none
    /// Staged, with a durable payload ID and the exact prefix this send prepends.
    case staged(AgentStagedProviderText, AgentRecoveryPendingHandoffSnapshot)
    /// The payload ID could not be saved; the stage was released and the send must not proceed.
    case failed

    /// Why a durable send was blocked because its conversation handoff could not be made part of
    /// its saved input before dispatch. Shown to the user; the input stays saved.
    package static let blockedReason = "This message was not sent: the conversation history it needs could not be saved with it. The message stays saved."
}

/// Provider-facing text plus the exact pending-handoff stage its assembly created (nil when this
/// assembly prepended nothing, e.g. the payload was already staged or held elsewhere).
package struct AgentStagedProviderText: Equatable {
    package let text: String
    package let pendingHandoffStage: AgentPendingHandoffStage?
    /// Set when this durable send must not proceed: its pending-handoff prefix could not be made
    /// part of its intent before dispatch (adopted plan §5). The input stays saved; nothing staged.
    package let blockedReason: String?

    package init(text: String, pendingHandoffStage: AgentPendingHandoffStage? = nil, blockedReason: String? = nil) {
        self.text = text
        self.pendingHandoffStage = pendingHandoffStage
        self.blockedReason = blockedReason
    }
}

extension AgentModeRunService.Hooks {
    /// Delivers both staged-input kinds' exact-stage outcome. A nil stage of either kind is a no-op
    /// for that kind's owner.
    @MainActor
    func recordStagedInputOutcome(
        _ session: AgentTabSession,
        _ input: AgentCarriedStagedInput,
        _ disposition: AgentStagedInputDisposition
    ) {
        recordPendingHandoffSendOutcome(session, input.pendingHandoffStage, disposition)
        if input.delegatedQuestionStageID != nil {
            recordDelegatedQuestionNoticeSendOutcome(session, input.delegatedQuestionStageID, disposition)
        }
    }

    /// Binds `input` to `handoff`: every later outcome of the handoff (explicit send outcome, late
    /// acceptance, or end-of-scope settlement) settles exactly these stages, once.
    @MainActor
    func carryStagedInput(_ input: AgentCarriedStagedInput, on handoff: AgentProviderHandoff, session: AgentTabSession) {
        handoff.installStagedInputReporter { [weak session] carried, disposition in
            guard let session else { return }
            recordStagedInputOutcome(session, carried, disposition)
        }
        handoff.carryStagedInput(input)
    }

    /// Settles the staged input `handoff` carries after a provider send attempt (`sent`: the
    /// route's stage-delivery boundary was reached). An uncertain durable delivery reports
    /// `.deliveryUnknown`: the stages are neither consumed nor released.
    @MainActor
    func recordStagedInputSendOutcome(handoff: AgentProviderHandoff, sent: Bool) {
        handoff.settleStagedInput(sent: sent)
    }
}

/// Observes ACP `ACPAgentSessionController.prompt`'s `onSubmitted` callback, which runs once on the
/// controller actor immediately after the `session/prompt` request was written and never when
/// building or writing it failed. It proves the write only — not acceptance.
final class ACPPromptWriteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var written = false
    private let forward: (@Sendable () -> Void)?

    init(forwarding forward: (@Sendable () -> Void)? = nil) {
        self.forward = forward
    }

    var onSubmitted: @Sendable () -> Void {
        { [self] in
            lock.withLock { written = true }
            forward?()
        }
    }

    var wasWritten: Bool {
        lock.withLock { written }
    }
}
