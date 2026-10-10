import Foundation

// Agent Mode adapter for outbound attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Direction 1).
//
// Captures root turn completions at terminal commit (admitted only after successor selection
// settled with no follow-up or provider successor) and root `ask_user` questions after routing
// and timeout scheduling (admitted only while that exact interaction is still pending). Reuses the
// live delegation lineage, MCP control, question audience, terminal-text, and question-rendering
// authorities; it never changes them, never awaits, and never mutates run or question state.

@MainActor
extension AgentModeViewModel {
    /// A root session the user drives: durable identity, no MCP control context, and a live
    /// lineage that resolves to depth 0. Children at any depth (including orphaned children whose
    /// questions fall back to the user), Knowledge workers, unknown or conflicting lineage, and
    /// MCP-controlled roots are excluded. A remote host binding alone does not exclude a root: the
    /// local terminal commit and `askUser` remain the event authorities.
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
                finalAssistantText: mcpResolvedAssistantPreview(session: session, status: .completed)
            )
        )
        let sessionFence = attentionNotificationSessionFence(for: session, sessionID: sessionID)
        let commitID = revision.commitID
        return admission.makeCapture(event: event) { [weak self, weak session] in
            guard let self, let session, sessionFence(self, session) else { return false }
            // Still this exact completed commit and settled idle: no newer commit or run attempt,
            // and no follow-up queued after capture.
            return session.lastTerminalCommitRevision?.commitID == commitID
                && !session.terminalCommitInProgress
                && session.runState == .completed
                && session.activeRunOwnership == nil
                && session.pendingInstructions.isEmpty
                && session.codexFallbackQueue.isEmpty
        }
    }

    func settleAttentionTurnCompletion(
        for session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        capture: AttentionNotificationAdmission.Capture,
        providerSuccessorDeclined: Bool
    ) {
        // A queued follow-up or provider successor selected at this commit means the session did
        // not settle idle; that successor's own completion is the event. A provider successor that
        // declined after an accepted publication never started, so this completion still counts
        // (admission re-checks settled idle). A generic follow-up selected but aborted before its
        // run starts stays silent.
        let successorTookOver = revision.successorKind != nil
            && !(providerSuccessorDeclined && revision.providerSuccessorID != nil)
        guard !successorTookOver else {
            attentionNotificationAdmission.suppress(capture.event.key, reason: .successorTookOver)
            return
        }
        attentionNotificationAdmission.submit(capture)
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
