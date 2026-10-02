import Foundation

// Delegated `ask_user` escalation (docs/context/plans/2026-10-02-oracle-errors-and-delegated-ask-user-plan.md §6;
// owning contract: docs/context/agent-mcp-delegation-depth.md "Delegated questions").
//
// A child's `pendingAskUser` plus its continuation stay the single authority for question
// content, drafts, the timeout, and resolution. This file only keeps a runtime-only notice
// registry keyed by (child session, interaction) that decides when the immediate parent
// agent learns about the question:
// - parent blocked in a covering `agent_run` wait → existing actionable snapshot, acknowledged at handoff;
// - parent blocked in another bounded wait → early wake (`delegatedQuestionPending`);
// - parent busy → next eligible RepoPrompt MCP tool result (`MCPServerViewModel.runTool`);
// - parent idle → banner/badge, then a labeled runtime block in the next turn's first input.
// Nothing here starts a turn, steers, interrupts a tool, or answers a question.

/// Runtime-only notice registry stored on `AgentModeViewModel` (never persisted).
struct AgentDelegatedQuestionNoticeRegistry {
    struct Record: Equatable {
        let key: AgentDelegatedQuestionNoticeKey
        let childTabID: UUID
        /// Immediate parent's durable session ID (resolved once through the reconciled lookup).
        let parentSessionID: UUID
        /// Parent tab observed at registration; only used to cheaply gate reconcile triggers.
        let parentTabID: UUID
        let askedAt: Date
        /// Parent run IDs each delivery was stamped with.
        var deliveredRunIDs: Set<UUID> = []
        /// Set once a delivery reached the parent model; an acknowledged notice is never re-delivered.
        var acknowledged = false
        /// Parent tab whose next-turn input carries this notice while the send outcome is pending.
        var stagedParentTabID: UUID?
        /// Parent runs already woken for this notice (wake de-duplication only; not a delivery).
        var wokenRunIDs: Set<UUID> = []
        /// Tool-result handoff holding this notice while its result travels to the transport.
        /// Reserved notices are neither deliverable elsewhere nor acknowledged until the
        /// reservation commits (result handed off) or releases (cancelled/failed before handoff).
        var reservationID: UUID?
    }

    struct StagedTurnNotice: Equatable {
        enum Phase: Equatable {
            /// `startAgentRun` is still assembling or starting the run; only its own settle step
            /// (or the provider send outcome) may resolve the stage.
            case startInFlight
            /// The run started; the provider send outcome is still pending. Rolled back if the
            /// parent run stops without reporting one.
            case awaitingSendOutcome
        }

        let stageID: UUID
        let keys: Set<AgentDelegatedQuestionNoticeKey>
        let text: String
        var phase: Phase = .startInFlight
    }

    struct Reservation: Equatable {
        let parentRunID: UUID
        let keys: Set<AgentDelegatedQuestionNoticeKey>
    }

    var records: [AgentDelegatedQuestionNoticeKey: Record] = [:]
    /// Next-turn notices staged into a parent's provider input, keyed by parent tab.
    var stagedTurnNoticesByParentTabID: [UUID: StagedTurnNotice] = [:]
    /// Open tool-result handoffs, keyed by reservation ID.
    var reservations: [UUID: Reservation] = [:]
    var isReconciling = false

    var isEmpty: Bool {
        records.isEmpty && stagedTurnNoticesByParentTabID.isEmpty && reservations.isEmpty
    }

    func isDeliverable(_ record: Record, toRunID runID: UUID) -> Bool {
        !record.acknowledged
            && record.stagedParentTabID == nil
            && record.reservationID == nil
            && !record.deliveredRunIDs.contains(runID)
    }
}

/// One tool-result handoff of delegated-question notices (plan §6.2). The payloads are attached
/// to exactly one result; the notices stay pending until the reservation commits (the result was
/// handed to the transport) or releases (cancelled or failed before handoff).
struct AgentDelegatedQuestionNoticeReservation: Equatable {
    let id: UUID
    let parentRunID: UUID
    /// Notices to attach to the result (empty when only covered keys were reserved).
    let payloads: [AgentDelegatedQuestionNoticePayload]
    /// Notices already visible in the result itself (an `agent_run` question snapshot);
    /// acknowledged on commit without duplicating their text.
    let coveredKeys: Set<AgentDelegatedQuestionNoticeKey>
}

/// One parent-banner row per pending child question (plan §6.5). Never an answer surface.
struct AgentDelegatedQuestionBannerRow: Equatable, Identifiable {
    enum Status: Equatable {
        /// The parent model has seen the notice.
        case delivered
        /// The parent is running; the notice rides on its next eligible RepoPrompt tool result.
        case awaitingNextToolResult
        /// The parent is idle; the notice is included in its next turn.
        case waitingForNextTurn
    }

    let childTabID: UUID
    let key: AgentDelegatedQuestionNoticeKey
    let childTitle: String
    let status: Status

    var id: AgentDelegatedQuestionNoticeKey {
        key
    }

    var text: String {
        let base = "Child agent '\(childTitle)' asked a question"
        switch status {
        case .delivered:
            return base + " — delivered"
        case .awaitingNextToolResult:
            return base + " — delivering with this agent's next tool result"
        case .waitingForNextTurn:
            return base + " — waiting for this agent's next turn"
        }
    }
}

struct AgentDelegatedQuestionBannerActions {
    /// Selects the child tab after verifying the question is still pending; returns an error
    /// message otherwise. Never answers anything.
    let openChild: (_ row: AgentDelegatedQuestionBannerRow) async -> String?
}

/// Sidebar legibility for delegated questions, resolved by durable session ID (plan §6.5).
struct AgentDelegatedQuestionSidebarAttention: Equatable {
    enum OwnQuestion: Equatable {
        case waitingOnParentAgent
        case needsUserAnswer
    }

    /// Pending child questions addressed to this session as the parent agent.
    var pendingChildQuestionCount = 0
    /// Of those, how many the parent model has not seen yet.
    var undeliveredChildQuestionCount = 0
    /// This session's own pending question routing, when delegated.
    var ownQuestion: OwnQuestion?

    var isEmpty: Bool {
        pendingChildQuestionCount == 0 && ownQuestion == nil
    }

    var tooltipText: String {
        var parts: [String] = []
        switch ownQuestion {
        case .waitingOnParentAgent:
            parts.append("Waiting on parent agent")
        case .needsUserAnswer:
            parts.append("Needs your answer")
        case nil:
            break
        }
        if pendingChildQuestionCount > 0 {
            let noun = pendingChildQuestionCount == 1 ? "child question" : "child questions"
            var text = "\(pendingChildQuestionCount) pending \(noun)"
            if undeliveredChildQuestionCount > 0 {
                text += " (\(undeliveredChildQuestionCount) not yet delivered)"
            }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
extension AgentModeViewModel {
    static let delegatedQuestionWakeSource = "delegated-question"

    // MARK: - Audience

    /// Reconciled audience for `session`'s `ask_user` (plan §6.1). Reuses the delegation lineage
    /// lookups; never guesses a parent. Remote-host projections are out of scope (unchanged).
    func delegatedQuestionAudience(
        for session: TabSession,
        provenance: AgentDelegatedQuestionControllerProvenance
    ) -> AgentDelegatedQuestionAudience {
        let isControlled = isMCPControlled(tabID: session.tabID)
        guard session.remoteHost == nil else { return .user }
        guard let sessionID = session.activeAgentSessionID else {
            return isControlled ? .userFallback : .user
        }
        let parentLookup = mcpDelegationParentLookup(sessionID: sessionID)
        let parentIsLive: Bool = if case let .parent(parentSessionID) = parentLookup {
            liveDelegatedQuestionParent(parentSessionID: parentSessionID) != nil
        } else {
            false
        }
        return AgentDelegatedQuestionAudience.resolve(.init(
            isMCPControlled: isControlled,
            parentLookup: parentLookup,
            lineage: mcpDelegationLineage(for: session),
            parentIsLive: parentIsLive,
            controllerVerifiedNonAgentMode: provenance.verifies(
                currentControllerConnectionID: session.mcpControlContext?.originatingConnectionID
            )
        ))
    }

    /// The single live local record bound to `parentSessionID`; ambiguous bindings are not live.
    func liveDelegatedQuestionParent(parentSessionID: UUID) -> TabSession? {
        let matches = sessions.values.filter {
            $0.activeAgentSessionID == parentSessionID && $0.remoteHost == nil
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Controlling connection of an MCP-controlled tab, used to verify an external controller.
    func mcpControllerConnectionID(tabID: UUID) -> UUID? {
        sessions[tabID]?.mcpControlContext?.originatingConnectionID
    }

    // MARK: - Install and reconcile

    /// Called synchronously once `pendingAskUser` and the continuation exist. Returns the audience;
    /// the caller starts the normal timeout unless the audience pauses it.
    @discardableResult
    func installDelegatedQuestionRouting(
        for session: TabSession,
        interactionID: UUID,
        provenance: AgentDelegatedQuestionControllerProvenance
    ) -> AgentDelegatedQuestionAudience {
        guard var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil
        else {
            return .user
        }
        let audience = delegatedQuestionAudience(for: session, provenance: provenance)
        switch audience {
        case .user, .externalController:
            return audience
        case .userFallback:
            pending.delegatedRouting = .userFallback
            session.pendingAskUser = pending
        case let .parentAgent(parentSessionID):
            guard let childSessionID = session.activeAgentSessionID,
                  let parent = liveDelegatedQuestionParent(parentSessionID: parentSessionID)
            else {
                pending.delegatedRouting = .userFallback
                session.pendingAskUser = pending
                publishDelegatedQuestionChange(childTabIDs: [session.tabID])
                return .userFallback
            }
            pending.delegatedRouting = .awaitingParentAgent
            session.pendingAskUser = pending
            // No timeout runs while the parent chain owns the question (§6.4).
            invalidatePendingAskUserTimeout(for: session)
            let key = AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interactionID)
            delegatedQuestionNotices.records[key] = AgentDelegatedQuestionNoticeRegistry.Record(
                key: key,
                childTabID: session.tabID,
                parentSessionID: parentSessionID,
                parentTabID: parent.tabID,
                askedAt: pending.interaction.askedAt
            )
        }
        publishDelegatedQuestionChange(childTabIDs: [session.tabID])
        wakeParentsForDelegatedQuestionsIfNeeded()
        return audience
    }

    /// Synchronous lifecycle reconcile (§6.2): drops records whose question resolved or whose
    /// child went away, falls back to the user with a fresh timeout when the parent route is no
    /// longer valid, and wakes parents with deliverable notices. Idempotent and cheap when empty.
    func reconcileDelegatedQuestionNotices(trigger: String) {
        guard !delegatedQuestionNotices.isEmpty, !delegatedQuestionNotices.isReconciling else { return }
        delegatedQuestionNotices.isReconciling = true
        defer { delegatedQuestionNotices.isReconciling = false }

        var changedChildTabIDs = Set<UUID>()
        var changed = false
        for (key, record) in delegatedQuestionNotices.records {
            guard let child = delegatedQuestionPendingChild(for: record),
                  var pending = child.pendingAskUser
            else {
                delegatedQuestionNotices.records.removeValue(forKey: key)
                changed = true
                continue
            }
            let audience = delegatedQuestionAudience(for: child, provenance: .unverified)
            if case let .parentAgent(parentSessionID) = audience, parentSessionID == record.parentSessionID {
                continue
            }
            // The parent route is gone: the user answers in the child tab, with a fresh timeout
            // from now (§6.4). The route never re-pauses afterwards.
            delegatedQuestionNotices.records.removeValue(forKey: key)
            pending.delegatedRouting = .userFallback
            child.pendingAskUser = pending
            schedulePendingAskUserTimeout(
                for: child,
                interactionID: key.interactionID,
                timeoutSeconds: pending.interaction.timeoutSeconds,
                startedAt: Date()
            )
            Self.steeringDebugLog("[DelegatedQuestion] fallback to user trigger=\(trigger) child=\(key.childSessionID) interaction=\(key.interactionID)")
            changedChildTabIDs.insert(child.tabID)
            changed = true
        }
        for (parentTabID, staged) in delegatedQuestionNotices.stagedTurnNoticesByParentTabID {
            // A stage whose parent tab is gone, or whose started run stopped without reporting a
            // send outcome, never reached the model: release it so the notice stays deliverable.
            let parent = sessions[parentTabID]
            let runStoppedWithoutOutcome = staged.phase == .awaitingSendOutcome
                && parent?.runState.isActive != true
            guard parent == nil || runStoppedWithoutOutcome else { continue }
            rollBackStagedDelegatedQuestionNotices(staged, parentTabID: parentTabID)
            changed = true
        }
        for (reservationID, reservation) in delegatedQuestionNotices.reservations {
            // A tool-result handoff that can no longer reach its run (the run ended or changed, or
            // every reserved question resolved) is released rather than left pending forever.
            let holdsLiveRecord = reservation.keys.contains {
                delegatedQuestionNotices.records[$0]?.reservationID == reservationID
            }
            let runIsActive = delegatedQuestionParentSession(forRunID: reservation.parentRunID)?.runState.isActive == true
            guard !holdsLiveRecord || !runIsActive else { continue }
            delegatedQuestionNotices.reservations.removeValue(forKey: reservationID)
            releaseDelegatedQuestionReservationKeys(reservation, reservationID: reservationID)
            changed = true
        }
        if changed {
            publishDelegatedQuestionChange(childTabIDs: changedChildTabIDs)
        }
        wakeParentsForDelegatedQuestionsIfNeeded()
    }

    /// Cheap relevance gate for high-frequency binding updates.
    func reconcileDelegatedQuestionNoticesIfRelevant(to session: TabSession) {
        guard !delegatedQuestionNotices.isEmpty, !delegatedQuestionNotices.isReconciling else { return }
        let tabID = session.tabID
        let sessionID = session.activeAgentSessionID
        let isRelevant = delegatedQuestionNotices.records.values.contains { record in
            record.childTabID == tabID || record.parentTabID == tabID || record.parentSessionID == sessionID
        } || delegatedQuestionNotices.stagedTurnNoticesByParentTabID[tabID] != nil
        guard isRelevant else { return }
        reconcileDelegatedQuestionNotices(trigger: "bindings")
    }

    private func delegatedQuestionPendingChild(
        for record: AgentDelegatedQuestionNoticeRegistry.Record
    ) -> TabSession? {
        guard let child = sessions[record.childTabID],
              child.activeAgentSessionID == record.key.childSessionID,
              child.remoteHost == nil,
              let pending = child.pendingAskUser,
              pending.interaction.id == record.key.interactionID,
              child.askUserContinuation != nil
        else {
            return nil
        }
        return child
    }

    private func delegatedQuestionChildName(_ child: TabSession, childSessionID: UUID) -> String {
        if let name = workspaceManager?.composeTabName(with: child.tabID) {
            return name
        }
        if let name = ownerValidatedSessionIndex[childSessionID]?.name {
            return name
        }
        return "Agent Session"
    }

    private func delegatedQuestionPayload(
        for record: AgentDelegatedQuestionNoticeRegistry.Record
    ) -> AgentDelegatedQuestionNoticePayload? {
        guard let child = delegatedQuestionPendingChild(for: record),
              let pending = child.pendingAskUser
        else {
            return nil
        }
        return AgentDelegatedQuestionNoticePayload(
            childSessionID: record.key.childSessionID,
            childSessionName: delegatedQuestionChildName(child, childSessionID: record.key.childSessionID),
            interaction: pending.interaction
        )
    }

    private func delegatedQuestionRecordsSorted(
        parentSessionID: UUID
    ) -> [AgentDelegatedQuestionNoticeRegistry.Record] {
        delegatedQuestionNotices.records.values
            .filter { $0.parentSessionID == parentSessionID }
            .sorted { lhs, rhs in
                if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
                return lhs.key.interactionID.uuidString < rhs.key.interactionID.uuidString
            }
    }

    /// The live parent record whose active run is `runID` and whose identity is a notice parent.
    private func delegatedQuestionParentSession(forRunID runID: UUID) -> TabSession? {
        let matches = sessions.values.filter { $0.runID == runID && $0.remoteHost == nil }
        guard matches.count == 1, let parent = matches.first,
              let parentSessionID = parent.activeAgentSessionID,
              liveDelegatedQuestionParent(parentSessionID: parentSessionID) === parent
        else {
            return nil
        }
        return parent
    }

    // MARK: - Wake (§6.2 "Wake early")

    /// Wakes every bounded wait owned by a parent's active run once per (notice, run).
    private func wakeParentsForDelegatedQuestionsIfNeeded() {
        var runIDsToWake = Set<UUID>()
        for (key, record) in delegatedQuestionNotices.records {
            guard let parent = liveDelegatedQuestionParent(parentSessionID: record.parentSessionID),
                  let runID = parent.runID,
                  delegatedQuestionNotices.isDeliverable(record, toRunID: runID),
                  !record.wokenRunIDs.contains(runID)
            else {
                continue
            }
            delegatedQuestionNotices.records[key]?.wokenRunIDs.insert(runID)
            runIDsToWake.insert(runID)
        }
        for runID in runIDsToWake {
            Self.steeringDebugLog("[DelegatedQuestion] wake parent run runID=\(runID)")
            Task { @MainActor [weak self] in
                await self?.wakeMCPWaitersForDelegatedQuestion(parentRunID: runID)
            }
        }
    }

    // MARK: - MCP handoff API (called by MCPServerViewModel / AgentRunMCPToolService)

    /// True when a pending child question addressed to the parent whose active run is
    /// `parentRunID` has not been delivered to (or acknowledged by) that run. Children in
    /// `excludingChildSessionIDs` (already covered by the caller's wait) are ignored.
    func mcpHasDeliverableDelegatedQuestionNotices(
        parentRunID: UUID,
        excludingChildSessionIDs: Set<UUID>
    ) -> Bool {
        guard !delegatedQuestionNotices.records.isEmpty,
              let parent = delegatedQuestionParentSession(forRunID: parentRunID),
              let parentSessionID = parent.activeAgentSessionID
        else {
            return false
        }
        return delegatedQuestionNotices.records.values.contains { record in
            record.parentSessionID == parentSessionID
                && !excludingChildSessionIDs.contains(record.key.childSessionID)
                && delegatedQuestionNotices.isDeliverable(record, toRunID: parentRunID)
                && delegatedQuestionPendingChild(for: record) != nil
        }
    }

    /// Reserves the notices for one tool result being returned to `parentRunID` (plan §6.2).
    /// Revalidates the parent run and each pending interaction immediately before handoff.
    /// `coveredKeys` (questions already visible in the result) are reserved without a payload;
    /// every other deliverable notice is reserved and its payload returned for attachment.
    /// Nothing is acknowledged here: the caller commits once the result is handed to the
    /// transport and releases on cancellation or failure, so cancellation never consumes a notice.
    func mcpReserveDelegatedQuestionNotices(
        parentRunID: UUID,
        coveredKeys: Set<AgentDelegatedQuestionNoticeKey>
    ) -> AgentDelegatedQuestionNoticeReservation? {
        guard !delegatedQuestionNotices.records.isEmpty,
              let parent = delegatedQuestionParentSession(forRunID: parentRunID),
              let parentSessionID = parent.activeAgentSessionID
        else {
            return nil
        }
        var payloads: [AgentDelegatedQuestionNoticePayload] = []
        var reservedCoveredKeys = Set<AgentDelegatedQuestionNoticeKey>()
        var keys = Set<AgentDelegatedQuestionNoticeKey>()
        for record in delegatedQuestionRecordsSorted(parentSessionID: parentSessionID) {
            let key = record.key
            if coveredKeys.contains(key) {
                guard record.stagedParentTabID == nil,
                      record.reservationID == nil,
                      !record.acknowledged || !record.deliveredRunIDs.contains(parentRunID),
                      delegatedQuestionPendingChild(for: record) != nil
                else {
                    continue
                }
                reservedCoveredKeys.insert(key)
                keys.insert(key)
                continue
            }
            guard delegatedQuestionNotices.isDeliverable(record, toRunID: parentRunID),
                  let payload = delegatedQuestionPayload(for: record)
            else {
                continue
            }
            payloads.append(payload)
            keys.insert(key)
        }
        guard !keys.isEmpty else { return nil }
        let reservationID = UUID()
        for key in keys {
            delegatedQuestionNotices.records[key]?.reservationID = reservationID
        }
        delegatedQuestionNotices.reservations[reservationID] = .init(parentRunID: parentRunID, keys: keys)
        Self.steeringDebugLog("[DelegatedQuestion] reserve id=\(reservationID) parentRunID=\(parentRunID) attached=\(payloads.count) covered=\(reservedCoveredKeys.count)")
        return AgentDelegatedQuestionNoticeReservation(
            id: reservationID,
            parentRunID: parentRunID,
            payloads: payloads,
            coveredKeys: reservedCoveredKeys
        )
    }

    /// The reserved result was handed to the transport: stamp the parent run and acknowledge.
    /// Unknown or already-resolved reservations are a no-op (the question may have resolved).
    func mcpCommitDelegatedQuestionNoticeReservation(_ reservationID: UUID) {
        guard let reservation = delegatedQuestionNotices.reservations.removeValue(forKey: reservationID) else { return }
        for key in reservation.keys where delegatedQuestionNotices.records[key]?.reservationID == reservationID {
            delegatedQuestionNotices.records[key]?.reservationID = nil
            delegatedQuestionNotices.records[key]?.deliveredRunIDs.insert(reservation.parentRunID)
            delegatedQuestionNotices.records[key]?.acknowledged = true
        }
        Self.steeringDebugLog("[DelegatedQuestion] commit id=\(reservationID) parentRunID=\(reservation.parentRunID) notices=\(reservation.keys.count)")
        publishDelegatedQuestionChange(childTabIDs: [])
    }

    /// The reserved result was cancelled or failed before handoff: the notices become deliverable
    /// again (to the same run) and a still-waiting parent may be woken again.
    func mcpReleaseDelegatedQuestionNoticeReservation(_ reservationID: UUID) {
        guard let reservation = delegatedQuestionNotices.reservations.removeValue(forKey: reservationID) else { return }
        releaseDelegatedQuestionReservationKeys(reservation, reservationID: reservationID)
        Self.steeringDebugLog("[DelegatedQuestion] release id=\(reservationID) parentRunID=\(reservation.parentRunID) notices=\(reservation.keys.count)")
        publishDelegatedQuestionChange(childTabIDs: [])
        wakeParentsForDelegatedQuestionsIfNeeded()
    }

    private func releaseDelegatedQuestionReservationKeys(
        _ reservation: AgentDelegatedQuestionNoticeRegistry.Reservation,
        reservationID: UUID
    ) {
        for key in reservation.keys where delegatedQuestionNotices.records[key]?.reservationID == reservationID {
            delegatedQuestionNotices.records[key]?.reservationID = nil
            delegatedQuestionNotices.records[key]?.wokenRunIDs.remove(reservation.parentRunID)
        }
    }

    /// Reserve and immediately commit, for callers without a transport handoff boundary.
    /// Callers must attach every returned payload to the returned result.
    func mcpHandOffDelegatedQuestionNotices(
        parentRunID: UUID,
        coveredKeys: Set<AgentDelegatedQuestionNoticeKey>
    ) -> [AgentDelegatedQuestionNoticePayload] {
        guard let reservation = mcpReserveDelegatedQuestionNotices(parentRunID: parentRunID, coveredKeys: coveredKeys) else {
            return []
        }
        mcpCommitDelegatedQuestionNoticeReservation(reservation.id)
        return reservation.payloads
    }

    // MARK: - Idle parent: next turn's first input (§6.2, owner decision 2)

    /// Prepends a labeled runtime notice block to the provider-facing first input of a parent's
    /// next turn. The user's message text and transcript item are never modified. The notices
    /// stay unacknowledged until `recordDelegatedQuestionNoticeSendOutcome` confirms the send.
    func stageDelegatedQuestionNoticesForTurnInput(_ text: String, session: TabSession) -> String {
        guard !delegatedQuestionNotices.records.isEmpty || delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] != nil else {
            return text
        }
        // A new first-input assembly supersedes an unresolved earlier stage for this tab.
        if let stale = delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] {
            rollBackStagedDelegatedQuestionNotices(stale, parentTabID: session.tabID)
        }
        guard session.remoteHost == nil,
              let parentSessionID = session.activeAgentSessionID,
              liveDelegatedQuestionParent(parentSessionID: parentSessionID) === session
        else {
            return text
        }
        let runID = session.runID
        var keys = Set<AgentDelegatedQuestionNoticeKey>()
        var payloads: [AgentDelegatedQuestionNoticePayload] = []
        for record in delegatedQuestionRecordsSorted(parentSessionID: parentSessionID) {
            guard !record.acknowledged,
                  record.stagedParentTabID == nil,
                  runID.map({ !record.deliveredRunIDs.contains($0) }) ?? true,
                  let payload = delegatedQuestionPayload(for: record)
            else {
                continue
            }
            keys.insert(record.key)
            payloads.append(payload)
        }
        guard let noticeText = AgentDelegatedQuestionNoticeWire.renderedText(for: payloads) else {
            return text
        }
        for key in keys {
            delegatedQuestionNotices.records[key]?.stagedParentTabID = session.tabID
        }
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] = .init(
            stageID: UUID(),
            keys: keys,
            text: noticeText
        )
        publishDelegatedQuestionChange(childTabIDs: [])
        return Self.delegatedQuestionTurnInput(noticeText: noticeText, providerText: text)
    }

    /// Identity of the stage currently held for `tabID`, captured by `startAgentRun` right after
    /// staging so its settle step only ever resolves its own stage.
    func delegatedQuestionTurnStageID(forTabID tabID: UUID) -> UUID? {
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID[tabID]?.stageID
    }

    /// Settles a next-turn stage once `runService.startRun` has returned. A stage the provider send
    /// outcome already committed or rolled back is gone. Otherwise a start that reported no send,
    /// or left the run inactive (failed, cancelled, stale, or refused before the provider), rolls
    /// the stage back so the notice stays deliverable; an active run still owes its send outcome,
    /// and reconcile rolls the stage back if that run stops without reporting one.
    func settleDelegatedQuestionTurnStageAfterRunStart(
        _ stageID: UUID?,
        session: TabSession,
        startReportedNoSend: Bool
    ) {
        guard let stageID,
              var staged = delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID],
              staged.stageID == stageID,
              staged.phase == .startInFlight
        else {
            return
        }
        guard !startReportedNoSend, session.runState.isActive else {
            rollBackStagedDelegatedQuestionNotices(staged, parentTabID: session.tabID)
            Self.steeringDebugLog("[DelegatedQuestion] next-turn stage released after start without send tab=\(session.tabID)")
            publishDelegatedQuestionChange(childTabIDs: [])
            wakeParentsForDelegatedQuestionsIfNeeded()
            return
        }
        staged.phase = .awaitingSendOutcome
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] = staged
    }

    static func delegatedQuestionTurnInput(noticeText: String, providerText: String) -> String {
        "<repoprompt_runtime_notice kind=\"delegated_child_questions\">\n\(noticeText)\n</repoprompt_runtime_notice>\n\n\(providerText)"
    }

    /// Commits (stamp with the parent's run, acknowledge, persist a labeled note) or rolls back
    /// the staged next-turn notices once the provider send outcome is known.
    func recordDelegatedQuestionNoticeSendOutcome(for session: TabSession, didSend: Bool) {
        guard let staged = delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] else { return }
        guard didSend else {
            rollBackStagedDelegatedQuestionNotices(staged, parentTabID: session.tabID)
            publishDelegatedQuestionChange(childTabIDs: [])
            return
        }
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID.removeValue(forKey: session.tabID)
        let runID = session.runID
        for key in staged.keys {
            guard var record = delegatedQuestionNotices.records[key],
                  record.stagedParentTabID == session.tabID
            else {
                continue
            }
            record.stagedParentTabID = nil
            if let runID {
                record.deliveredRunIDs.insert(runID)
            }
            record.acknowledged = true
            delegatedQuestionNotices.records[key] = record
        }
        // Persist what the model saw as a labeled, ID-bearing runtime note. Live state stays in
        // the child's pendingAskUser, so this note is never read back as current state.
        session.appendItem(.system(staged.text, sequenceIndex: session.nextSequenceIndex))
        session.isDirty = true
        scheduleSave(for: session.tabID)
        Self.steeringDebugLog("[DelegatedQuestion] next-turn input delivered tab=\(session.tabID) notices=\(staged.keys.count) runID=\(runID?.uuidString ?? "nil")")
        publishDelegatedQuestionChange(childTabIDs: [])
        requestUIRefresh(tabID: session.tabID)
    }

    /// Stage and commit in one step for inputs delivered synchronously to a waiting provider
    /// (instruction-continuation resume and queued instructions).
    func deliverDelegatedQuestionNoticesWithImmediateInput(_ text: String, session: TabSession) -> String {
        let staged = stageDelegatedQuestionNoticesForTurnInput(text, session: session)
        recordDelegatedQuestionNoticeSendOutcome(for: session, didSend: true)
        return staged
    }

    private func rollBackStagedDelegatedQuestionNotices(
        _ staged: AgentDelegatedQuestionNoticeRegistry.StagedTurnNotice,
        parentTabID: UUID
    ) {
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID.removeValue(forKey: parentTabID)
        for key in staged.keys where delegatedQuestionNotices.records[key]?.stagedParentTabID == parentTabID {
            delegatedQuestionNotices.records[key]?.stagedParentTabID = nil
        }
    }

    // MARK: - Presentation (§6.5)

    func delegatedQuestionBannerRows(forParentTabID tabID: UUID?) -> [AgentDelegatedQuestionBannerRow] {
        guard let tabID,
              !delegatedQuestionNotices.records.isEmpty,
              let parent = sessions[tabID],
              let parentSessionID = parent.activeAgentSessionID
        else {
            return []
        }
        let isParentRunning = parent.runState.isActive && parent.runState != .waitingForUser
        return delegatedQuestionRecordsSorted(parentSessionID: parentSessionID).compactMap { record in
            guard let child = delegatedQuestionPendingChild(for: record) else { return nil }
            let status: AgentDelegatedQuestionBannerRow.Status = if record.acknowledged {
                .delivered
            } else if isParentRunning {
                .awaitingNextToolResult
            } else {
                .waitingForNextTurn
            }
            return AgentDelegatedQuestionBannerRow(
                childTabID: record.childTabID,
                key: record.key,
                childTitle: delegatedQuestionChildName(child, childSessionID: record.key.childSessionID),
                status: status
            )
        }
    }

    func delegatedQuestionSidebarAttentionBySessionID() -> [UUID: AgentDelegatedQuestionSidebarAttention] {
        var result: [UUID: AgentDelegatedQuestionSidebarAttention] = [:]
        for record in delegatedQuestionNotices.records.values where delegatedQuestionPendingChild(for: record) != nil {
            var attention = result[record.parentSessionID] ?? AgentDelegatedQuestionSidebarAttention()
            attention.pendingChildQuestionCount += 1
            if !record.acknowledged {
                attention.undeliveredChildQuestionCount += 1
            }
            result[record.parentSessionID] = attention
        }
        for session in sessions.values {
            guard let sessionID = session.activeAgentSessionID,
                  let pending = session.pendingAskUser
            else {
                continue
            }
            let ownQuestion: AgentDelegatedQuestionSidebarAttention.OwnQuestion? = switch pending.delegatedRouting {
            case .direct:
                nil
            case .awaitingParentAgent:
                .waitingOnParentAgent
            case .userFallback:
                .needsUserAnswer
            }
            guard let ownQuestion else { continue }
            var attention = result[sessionID] ?? AgentDelegatedQuestionSidebarAttention()
            attention.ownQuestion = ownQuestion
            result[sessionID] = attention
        }
        return result
    }

    /// Banner **Open** action: selects the child tab only while its question is still pending.
    func openDelegatedQuestionChild(_ row: AgentDelegatedQuestionBannerRow) async -> String? {
        guard let child = sessions[row.childTabID],
              child.activeAgentSessionID == row.key.childSessionID,
              child.pendingAskUser?.interaction.id == row.key.interactionID
        else {
            return "That child question is no longer pending."
        }
        await promptManager?.switchComposeTab(row.childTabID)
        return nil
    }

    private func publishDelegatedQuestionChange(childTabIDs: Set<UUID>) {
        for tabID in childTabIDs {
            guard let child = sessions[tabID] else { continue }
            updateBindingsFromSession(child)
            requestUIRefresh(tabID: tabID)
        }
        syncSidebarUIState(refresh: true, reason: .delegatedQuestion)
        syncComposerUIState()
    }
}
