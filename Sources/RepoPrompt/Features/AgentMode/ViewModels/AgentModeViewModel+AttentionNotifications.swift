import Foundation

// Agent Mode adapter for outbound attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Direction 1).
//
// Captures root turn completions at terminal commit (admitted only after successor selection
// settled with no provider successor, or after a scheduled generic follow-up's start returned and the
// completion is still the current settled-idle event) and root `ask_user` questions after routing
// and timeout scheduling (admitted only while that exact interaction is still pending). Reuses the
// live delegation lineage, MCP control, question audience, terminal-text, and question-rendering
// authorities; it never changes them, never awaits, and never mutates run or question state.

@MainActor
extension AgentModeViewModel {
    /// A root session the user drives: durable identity, no MCP control context, and a live
    /// lineage that resolves to depth 0. Children at any depth (including orphaned children whose
    /// questions fall back to the user), Knowledge workers, unknown or conflicting lineage, and
    /// MCP-controlled roots are excluded. Events come only from the executing host's local hooks (its
    /// terminal commit barrier and `askUser`), so Telegram is configured on the Mac that runs the
    /// session. An observing client's projected remote session is updated from the remote transport,
    /// never through those hooks, so nothing is captured or proxied for it there.
    func isAttentionNotificationRoot(_ session: TabSession) -> Bool {
        guard session.activeAgentSessionID != nil,
              !isMCPControlled(tabID: session.tabID),
              session.mcpControlContext == nil
        else { return false }
        return mcpDelegationLineage(for: session) == .resolved(depth: 0)
    }

    // MARK: - Turn completion

    func captureAttentionTurnCompletion(
        for session: TabSession,
        revision: AgentRunTerminalCommitRevision
    ) -> AttentionNotificationAdmission.Capture? {
        let admission = attentionNotificationAdmission
        guard admission.acceptsCaptures,
              revision.terminalState == .completed,
              let sessionID = session.activeAgentSessionID
        else { return nil }
        let key = AttentionNotificationEventKey.turnCompleted(
            sessionID: sessionID,
            attemptID: revision.ownership.attemptID
        )
        guard isAttentionNotificationRoot(session) else {
            admission.suppress(key, reason: .ineligibleSession)
            return nil
        }
        let event = AttentionNotificationEvent(
            key: key,
            workspaceName: attentionNotificationWorkspaceName(forTabID: session.tabID),
            sessionName: resolvedSessionDisplayName(for: session.tabID),
            content: .turnCompleted(
                finalAssistantText: attentionTurnCompletionText(for: session, attemptID: revision.ownership.attemptID)
            )
        )
        let sessionFence = attentionNotificationSessionFence(for: session, sessionID: sessionID)
        let commitID = revision.commitID
        return admission.makeCapture(event: event) { [weak self, weak session] in
            guard let self, let session, sessionFence(self, session) else { return false }
            // Still this exact completed commit and settled idle: no newer commit or run attempt,
            // no follow-up queued after capture, and no ACP steering handoff still in flight.
            return session.lastTerminalCommitRevision?.commitID == commitID
                && !session.terminalCommitInProgress
                && session.runState == .completed
                && session.activeRunOwnership == nil
                && session.pendingInstructions.isEmpty
                && session.codexFallbackQueue.isEmpty
                && !attentionCompletionAwaitsACPHandoff(session)
        }
    }

    func settleAttentionTurnCompletion(
        for session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        capture: AttentionNotificationAdmission.Capture,
        providerSuccessorDeclined: Bool,
        genericFollowUpScheduled: Bool
    ) -> AgentModeRunService.Hooks.FollowUpStartObservation? {
        let admission = attentionNotificationAdmission
        // A generic follow-up actually handed to its start: decide only after that start returns.
        // A follow-up that took over makes this capture no longer current (newer attempt or
        // commit); one refused before ownership leaves this completion settled idle, so it sends,
        // or is held while an ACP steering handoff is still outstanding. Nothing is recorded until then.
        if genericFollowUpScheduled, revision.successorKind != nil, revision.providerSuccessorID == nil {
            return { [weak self, weak session] in
                guard let self, let session else { return }
                submitOrDeferAttentionCompletion(capture, for: session)
            }
        }
        // Preserve the existing fail-closed decision for a selected but unscheduled generic
        // follow-up; it has no after-start observation. Provider successors suppress this
        // completion unless they explicitly declined after accepted publication, in which case
        // admission still re-checks settled idle.
        let successorTookOver = revision.successorKind != nil
            && !(providerSuccessorDeclined && revision.providerSuccessorID != nil)
        guard !successorTookOver else {
            admission.suppress(capture.event.key, reason: .successorTookOver)
            return nil
        }
        submitOrDeferAttentionCompletion(capture, for: session)
        return nil
    }

    /// This attempt's own final assistant text, read once at its terminal commit through the shared
    /// terminal assembler: the source suffix starting at the attempt's sequence floor, or at the
    /// earlier row its final content replaced (keeping the rows after it as separators). Nil when
    /// the attempt's provenance is missing (cleared by a transcript reset) or belongs to another
    /// attempt. Between-run (background) rows are never part of it, even when they landed after
    /// the attempt's user row.
    private func attentionTurnCompletionText(for session: TabSession, attemptID: UUID) -> String? {
        guard let provenance = session.attentionTextProvenance, provenance.attemptID == attemptID else {
            return nil
        }
        let backgroundRowIDs = session.backgroundRowIDs
        let ordered = session.items.filter { !backgroundRowIDs.contains($0.id) }.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let start = provenance.rewrittenPreBoundaryAssistantRowID
            .flatMap { rowID in ordered.firstIndex(where: { $0.id == rowID }) }
            ?? ordered.firstIndex(where: { $0.sequenceIndex >= provenance.minimumSourceSequenceIndex })
            ?? ordered.endIndex
        return AgentTranscriptIO.terminalAssistantResponseText(from: Array(ordered[start...]))
    }

    // MARK: - ACP steering handoff

    /// Queued ACP steering, an active flush, or an observed follow-up start that has not returned
    /// can still hand a settled completion to a later attempt.
    private func attentionCompletionAwaitsACPHandoff(_ session: TabSession) -> Bool {
        !session.pendingACPSteeringInstructions.isEmpty
            || session.acpSteeringFlushTask != nil
            || !session.attentionOutstandingFollowUpStartIDs.isEmpty
    }

    /// Submits now, or holds this session's single candidate outside the admission queue until the
    /// ACP handoff progressed. A newer completion replaces (and decides) an older held one.
    private func submitOrDeferAttentionCompletion(
        _ capture: AttentionNotificationAdmission.Capture,
        for session: TabSession
    ) {
        let admission = attentionNotificationAdmission
        guard attentionCompletionAwaitsACPHandoff(session) else {
            admission.submit(capture)
            return
        }
        if let held = session.attentionDeferredCompletion, held.event.key != capture.event.key {
            admission.suppress(held.event.key, reason: .eventNoLongerCurrent)
        }
        session.attentionDeferredCompletion = capture
    }

    /// Re-evaluates the held completion after ACP handoff work progressed: once nothing can still
    /// hand it to a later attempt, it is submitted (admission re-checks it is still current).
    func attentionCompletionProgress(for session: TabSession) {
        guard let capture = session.attentionDeferredCompletion,
              !attentionCompletionAwaitsACPHandoff(session)
        else { return }
        session.attentionDeferredCompletion = nil
        attentionNotificationAdmission.submit(capture)
    }

    /// Transcript reset (clear chat, route activation, hydration): a held completion is no longer
    /// current, so it is decided now. Notification-only; outstanding start observations are kept.
    func discardAttentionDeferredCompletion(for session: TabSession) {
        guard let held = session.attentionDeferredCompletion else { return }
        session.attentionDeferredCompletion = nil
        attentionNotificationAdmission.suppress(held.event.key, reason: .eventNoLongerCurrent)
    }

    /// Registers one ACP-steering follow-up start. The returned observation, called after the start
    /// returns (started, refused, or failed), releases it and re-evaluates; repeats are no-ops.
    func beginAttentionFollowUpObservation(
        for session: TabSession
    ) -> AgentModeRunService.Hooks.FollowUpStartObservation {
        let startID = UUID()
        session.attentionOutstandingFollowUpStartIDs.insert(startID)
        return { [weak self, weak session] in
            guard let session, session.attentionOutstandingFollowUpStartIDs.remove(startID) != nil else { return }
            self?.attentionCompletionProgress(for: session)
        }
    }

    // MARK: - ask_user

    /// Called synchronously inside `askUser` after audience routing and timeout scheduling.
    func captureAttentionQuestion(
        for session: TabSession,
        interactionID: UUID,
        audience: AgentDelegatedQuestionAudience
    ) {
        let admission = attentionNotificationAdmission
        guard admission.acceptsCaptures,
              let sessionID = session.activeAgentSessionID,
              let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil
        else { return }
        let key = AttentionNotificationEventKey.question(sessionID: sessionID, interactionID: interactionID)
        guard audience == .user, isAttentionNotificationRoot(session) else {
            admission.suppress(key, reason: .ineligibleSession)
            return
        }
        let sessionName = resolvedSessionDisplayName(for: session.tabID)
        let payload = AgentDelegatedQuestionNoticePayload(
            childSessionID: sessionID,
            childSessionName: sessionName,
            interaction: pending.interaction
        )
        let event = AttentionNotificationEvent(
            key: key,
            workspaceName: attentionNotificationWorkspaceName(forTabID: session.tabID),
            sessionName: sessionName,
            content: .question(contentLines: Self.attentionQuestionContentLines(payload))
        )
        let sessionFence = attentionNotificationSessionFence(for: session, sessionID: sessionID)
        let capture = admission.makeCapture(event: event) { [weak self, weak session] in
            guard let self, let session, sessionFence(self, session) else { return false }
            // Answered, skipped, timed out, cancelled, or replaced questions are never sent.
            return session.pendingAskUser?.interaction.id == interactionID
                && session.askUserContinuation != nil
        }
        admission.submit(capture)
    }

    /// Shared question rendering (`AgentDelegatedQuestionNoticePayload.contentLines`) plus explicit
    /// per-question `allows_multiple` / `allows_custom` flags, which the shared selection wording
    /// does not expose for free-form questions. Notification content only.
    static func attentionQuestionContentLines(_ payload: AgentDelegatedQuestionNoticePayload) -> [String] {
        // Title, context, and the "Questions:" header.
        var lines = AgentDelegatedQuestionNoticePayload.contentLines(
            title: payload.title,
            context: payload.context,
            questions: []
        )
        for (index, question) in payload.questions.enumerated() {
            var questionLines = AgentDelegatedQuestionNoticePayload.contentLines(
                title: nil,
                context: nil,
                questions: [question]
            ).dropFirst() // the per-call "Questions:" header
            if let first = questionLines.first, first.hasPrefix("1. ") {
                questionLines[questionLines.startIndex] = "\(index + 1). " + first.dropFirst(3)
            }
            lines.append(contentsOf: questionLines)
            lines.append("   Flags: allows_multiple=\(question.allowsMultiple); allows_custom=\(question.allowsCustom)")
        }
        return lines
    }

    // MARK: - Shared fences

    /// Same live tab object, same settled binding generation and durable identity, and still an
    /// eligible root (MCP control or lineage changes after capture fail closed).
    private func attentionNotificationSessionFence(
        for session: TabSession,
        sessionID: UUID
    ) -> @MainActor (AgentModeViewModel, TabSession) -> Bool {
        let tabID = session.tabID
        let sessionIdentity = ObjectIdentifier(session)
        let bindingGeneration = session.bindingTransitionGeneration
        return { viewModel, current in
            guard let live = viewModel.sessions[tabID],
                  ObjectIdentifier(live) == sessionIdentity,
                  live === current,
                  !current.bindingTransitionInProgress,
                  current.bindingTransitionGeneration == bindingGeneration,
                  current.activeAgentSessionID == sessionID
            else { return false }
            return viewModel.isAttentionNotificationRoot(current)
        }
    }

    /// The loaded workspace that owns the tab (active workspace first), independent of which
    /// workspace is active now. Read-only; never activates or persists anything.
    private func attentionNotificationWorkspaceName(forTabID tabID: UUID) -> String? {
        guard let workspaceManager else { return nil }
        let candidates = [workspaceManager.activeWorkspace].compactMap(\.self) + workspaceManager.workspaces
        return candidates.first { workspace in
            workspace.composeTabs.contains(where: { $0.id == tabID })
                || workspace.stashedTabs.contains(where: { $0.tab.id == tabID })
        }?.name
    }
}
