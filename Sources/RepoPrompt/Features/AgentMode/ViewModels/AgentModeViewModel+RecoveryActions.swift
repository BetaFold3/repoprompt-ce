import Foundation
import RepoPromptAgentCore

// Lossless restart Phase 4 explicit recovery actions in the window view model (phase4-plan
// "Durable action association", "History ledger", "Exact transaction boundary").
//
// Every choice goes through `AgentRecoveryActionRunner` (gate → durable reservation → fence →
// the EXISTING normal dispatch, once → durable outcome). Nothing here adds a second send path:
// continuations are new ordinary user input admitted by `submitUserTurnAdmittingRecoveryInput`
// under the action's planned user item ID; Send saved hands the single claimed saved intent to
// `submitUserTurn` under a store-issued queue receipt. History reconciliation commits rows, the
// native-ID ledger and the import receipt in ONE owner session save before the recovery cursor's
// compare-and-swap. Production keeps every action OFF (`AgentRecoveryActionQualification.production`),
// so none of these row actions is offered until live acceptance qualifies it.

extension AgentModeViewModel {
    /// One recovery item and one choice on it (the stable-request key).
    struct RecoveryActionSlot: Hashable {
        let item: AgentRecoveryCardKey
        let kindRaw: String
    }

    /// A previous launch's open action shown on an item (joined, never re-performed).
    struct RecoveryPriorAction: Equatable {
        let actionID: UUID
        let join: AgentRecoveryActionJoin

        /// Its join proves nothing was handed off, so any explicit new choice may replace it.
        var isProvenNotHandedOff: Bool {
            switch join {
            case .notDispatched, .notHandedOff: true
            case .dispatchEvidence, .unknown, .resolved: false
            }
        }
    }

    /// R7 default continuation text (shown editable in the card before the choice).
    static let recoveryContinueDefaultText = AgentRecoveryActionRequest.defaultContinuationText
    static let recoveryActionStaleText = "This session changed. Review the item and choose again."
    /// A recovery continuation that could not be durably admitted (it never falls back to an
    /// untracked submit of the composer's state).
    static let recoveryReservedPayloadUnadmittedMessage =
        "The continuation couldn't be saved before sending. Nothing was sent."
    /// Shown in the continuation editor when an earlier choice may have reached the agent; sending
    /// from that editor is the explicit confirmation.
    static let recoveryUncertainPriorWarning =
        "An earlier choice on this item, made before RepoPrompt restarted, may have reached the agent. Check the conversation first. Sending starts a new continuation; the earlier one is not retried."

    // MARK: Row actions (all gated OFF in production)

    /// Explicit recovery choices offered on a run row of the open session. A continuation is offered
    /// only for an interruption (review B F4) of the lane's own reset generation that no action
    /// resolved yet (B F3b) and whose input was handed off (A P1-06: a never-delivered run's saved
    /// message is the route). Reconcile stays available. The runner re-checks all of it durably.
    func recoveryRunActions(
        session: AgentTabSession?,
        status: AgentRecoveryInterruptedTurn.Status,
        facts: AgentRecoveryCatalogActionFacts
    ) -> [AgentRecoveryListRowProps.Action] {
        guard let session else { return [] }
        var actions: [AgentRecoveryListRowProps.Action] = []
        let sameGeneration = facts.runTranscriptResetGeneration.map { generation in
            session.recoveryLane.map { $0.binding.transcriptResetGeneration == generation } ?? false
        } ?? true
        let continuable = status.isInterruption && !facts.resolvedByAction && !facts.runNeverHandedOff && sameGeneration
        if continuable, recoveryActionRunner.isAvailable(.continueWithText) { actions.append(.continueTurn) }
        if recoveryActionRunner.isAvailable(.reconcileOnly), recoveryActionTarget(for: session).providerConversationID != nil {
            actions.append(.reconcileHistory)
        }
        if continuable, recoveryActionRunner.isAvailable(.continueInNewConversation),
           let unavailable = session.recoveryResumeUnavailableConversationID,
           unavailable == session.providerSessionID
        {
            actions.append(.continueInNewConversation)
        }
        return actions
    }

    /// Send saved on a queued intent row of the open session.
    func recoveryIntentActions(
        _ intent: AgentRecoveryIntent,
        facts: AgentRecoveryCatalogActionFacts = .init()
    ) -> [AgentRecoveryListRowProps.Action] {
        guard !facts.resolvedByAction, recoveryActionRunner.isAvailable(.sendSaved),
              intent.deliveryState == .queued,
              intent.pendingHandoff == nil,
              intent.scheduleReference == nil,
              intent.target.liveRun == nil
        else { return [] }
        return [.sendSaved]
    }

    /// Answer as input on a saved question row whose partial answer is non-empty.
    func recoveryQuestionActions(
        _ snapshot: AgentRecoveryQuestionSnapshot,
        facts: AgentRecoveryCatalogActionFacts = .init()
    ) -> [AgentRecoveryListRowProps.Action] {
        guard !facts.resolvedByAction, recoveryActionRunner.isAvailable(.questionAnswerAsInput),
              snapshot.items.contains(where: { !($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return [] }
        return [.answerAsInput]
    }

    // MARK: Perform

    /// Warning for the continuation editor of `key` when a previous launch's open action with
    /// uncertain delivery holds it.
    func recoveryPriorActionWarning(for key: AgentRecoveryCardKey?) -> String? {
        guard let key, let prior = recoveryPriorActionsByItem[key], !prior.isProvenNotHandedOff else { return nil }
        return Self.recoveryUncertainPriorWarning
    }

    /// Performs one explicit recovery choice for a row. Returns the row's inline failure text, or
    /// `nil` once the choice was performed (or found already performed). `continuationText` is the
    /// card's edited continuation (frozen into the reservation exactly as given);
    /// `acknowledgedWarning` is the uncertain-prior warning the editor showed when the user sent.
    func performRecoveryResumeAction(
        rowID: String,
        action: AgentRecoveryListRowProps.Action,
        continuationText: String? = nil,
        acknowledgedWarning: String? = nil
    ) async -> String? {
        guard let item = recoveryListCatalogItem(rowID), let sessionID = item.sessionID else {
            return "This item is no longer available."
        }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to continue it."
        }
        guard let key = item.acknowledgement?.key else { return "This item can't be continued." }
        let target = recoveryActionTarget(for: session)
        let kind: AgentRecoveryActionKind
        var text: String?
        var sourceIntentIDs: [UUID] = []
        var sourceRunAttemptID: UUID?
        var sourceInteractionID: UUID?
        var codexTurnID: String?
        var runTurnID: UUID?
        switch (action, item.payload) {
        case let (.continueTurn, payload), let (.reconcileHistory, payload), let (.continueInNewConversation, payload):
            guard let run = Self.recoveryRunReference(payload) else { return "This item can't be continued." }
            sourceRunAttemptID = run.runAttemptID
            runTurnID = run.turnID
            codexTurnID = run.turnID.flatMap { turnID in
                session.transcript.turns.first { $0.id == turnID }?.responseSpans.last { $0.providerTurnID != nil }?.providerTurnID
            }
            switch action {
            case .continueTurn:
                kind = .continueWithText
                text = continuationText ?? Self.recoveryContinueDefaultText
            case .reconcileHistory:
                kind = .reconcileOnly
            default:
                kind = .continueInNewConversation
                text = continuationText ?? Self.recoveryContinueDefaultText
            }
        case let (.sendSaved, .intent(intent, _)):
            kind = .sendSaved
            sourceIntentIDs = [intent.intentID]
        case let (.answerAsInput, .question(snapshot, _)):
            kind = .questionAnswerAsInput
            sourceInteractionID = snapshot.interactionID
            sourceRunAttemptID = snapshot.runAttemptID
            text = snapshot.composerText
        default:
            return "This choice doesn't apply to this item."
        }
        let expectedRevision: AgentRecoveryRecordRevision?
        switch await lane.readRecord() {
        case let .success(.supported(record)):
            expectedRevision = record.revision
        case .success(.absent):
            expectedRevision = nil
        case .success(.preserved):
            return "This session's recovery data is unreadable and is kept unchanged."
        case let .failure(failure):
            return "This session's recovery data couldn't be read (\(failure))."
        }
        // A previous launch's open action, already shown: this explicit choice names it. Uncertain
        // delivery admits only a continuation sent from the editor that showed the warning.
        var supersedesActionID: UUID?
        var confirmsUncertainPrior = false
        if let prior = recoveryPriorActionsByItem[key] {
            if prior.isProvenNotHandedOff {
                supersedesActionID = prior.actionID
            } else if kind.mayFollowUncertainPriorAction, acknowledgedWarning == Self.recoveryUncertainPriorWarning {
                supersedesActionID = prior.actionID
                confirmsUncertainPrior = true
            } else {
                return Self.recoveryPriorActionText(prior.join)
            }
        }
        let slot = RecoveryActionSlot(item: key, kindRaw: kind.rawValue)
        // A repeat joins only an identical choice; edited text or a different replacement target
        // is a new explicit choice with a new action ID.
        let cached = recoveryActionRequestsBySlot[slot].flatMap { cached in
            cached.text == text && cached.supersedesActionID == supersedesActionID
                && cached.confirmsUncertainPriorDelivery == confirmsUncertainPrior ? cached : nil
        }
        let request = cached ?? AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: kind,
            expectedRevision: expectedRevision,
            sourceIntentIDs: sourceIntentIDs,
            sourceRunAttemptID: sourceRunAttemptID,
            sourceInteractionID: sourceInteractionID,
            target: target,
            text: text,
            plannedUserItemID: kind.dispatches && kind != .sendSaved ? UUID() : nil,
            supersedesActionID: supersedesActionID,
            confirmsUncertainPriorDelivery: confirmsUncertainPrior
        )
        recoveryActionRequestsBySlot[slot] = request
        let performers = recoveryActionPerformers(
            kind: kind,
            session: session,
            lane: lane,
            codexTurnID: codexTurnID,
            runTurnID: runTurnID
        )
        let result = await recoveryActionRunner.perform(request, lane: lane, performers: performers)
        // The session's action hold ended: automatic work it paused is re-evaluated.
        scheduledSendCoordinator?.recordDidChange()
        refreshRecoveryListUI()
        switch result {
        case let .disabled(message), let .refused(message):
            recoveryActionRequestsBySlot[slot] = nil
            return message
        case let .priorAction(priorID, join):
            recoveryActionRequestsBySlot[slot] = nil
            recoveryPriorActionsByItem[key] = RecoveryPriorAction(actionID: priorID, join: join)
            refreshRecoveryListUI()
            return Self.recoveryPriorActionText(join)
        case let .joined(join):
            return Self.recoveryActionJoinText(join)
        case let .completed(outcome, reason):
            recoveryActionRequestsBySlot[slot] = nil
            recoveryPriorActionsByItem[key] = nil
            switch outcome {
            case .dispatched, .importedUnconfirmed:
                return nil
            case .notDispatched:
                return reason ?? "Nothing was sent."
            case .importedCompleted:
                return reason
            }
        case let .outcomeUnrecorded(outcome, _):
            recoveryActionRequestsBySlot[slot] = nil
            return outcome == .notDispatched
                ? "Nothing was sent, but that couldn't be recorded."
                : "The choice was performed, but its result couldn't be recorded. Check the conversation before choosing again."
        }
    }

    /// The provider conversation a choice is decided against (fenced at every await).
    func recoveryActionTarget(for session: AgentTabSession) -> AgentRecoveryActionTarget {
        let conversationID = session.selectedAgent == .codexExec ? session.codexConversationID : session.providerSessionID
        return AgentRecoveryActionTarget(providerKindRaw: session.selectedAgent.rawValue, providerConversationID: conversationID)
    }

    /// Lifecycle + target fence: the same tab, live lane, incarnation, reset generation, and (unless
    /// the choice is the explicit new conversation, which retires the target itself) target.
    func recoveryActionStillCurrent(
        _ action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        checksTarget: Bool = true
    ) -> Bool {
        guard sessions[session.tabID] === session,
              session.recoveryLane === lane,
              !lane.isRetired,
              lane.binding.incarnationID == action.incarnationID,
              lane.binding.transcriptResetGeneration == action.transcriptResetGeneration
        else { return false }
        return !checksTarget || recoveryActionTarget(for: session).matches(action.target)
    }

    // MARK: Performers

    private func recoveryActionPerformers(
        kind: AgentRecoveryActionKind,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        codexTurnID: String?,
        runTurnID: UUID?
    ) -> AgentRecoveryActionPerformers {
        var reconcile: (@MainActor (AgentRecoveryAction) async -> AgentRecoveryReconcileResult)?
        // R7 step 2: continuations reconcile first (the runner runs it only when history
        // reconciliation is qualified). Only providers with a history mechanism (Claude, Codex)
        // reconcile; for any other provider there is nothing to observe, so a continuation follows
        // its ordinary path and Reconcile reports history unavailable.
        let reconcilesProviderHistory = session.selectedAgent == .claudeCode || session.selectedAgent == .codexExec
        if reconcilesProviderHistory, kind == .reconcileOnly || kind.reconcilesBeforeDispatch {
            reconcile = { @MainActor [weak self] (action: AgentRecoveryAction) async -> AgentRecoveryReconcileResult in
                guard let self else { return .blocked(AgentModeViewModel.recoveryActionStaleText) }
                return await reconcileRecoveryHistory(
                    action,
                    session: session,
                    lane: lane,
                    codexTurnID: codexTurnID,
                    runTurnID: runTurnID
                )
            }
        }
        let dispatch: @MainActor (AgentRecoveryAction, AgentRecoveryActionAuthorization) async -> AgentRecoveryDispatchResult = {
            @MainActor [weak self] action, authorization in
            guard let self else { return .notDispatched(AgentModeViewModel.recoveryActionStaleText) }
            return await dispatchRecoveryAction(action, authorization: authorization, session: session, lane: lane)
        }
        return AgentRecoveryActionPerformers(reconcile: reconcile, dispatch: dispatch)
    }

    private func dispatchRecoveryAction(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        switch action.kind {
        case .sendSaved?:
            await dispatchRecoverySavedIntent(action, authorization: authorization, session: session, lane: lane)
        case .continueWithText?, .questionAnswerAsInput?, .continueInNewConversation?:
            await dispatchRecoveryContinuation(action, authorization: authorization, session: session, lane: lane)
        case .reconcileOnly?, nil:
            .notDispatched("Nothing is sent for this choice.")
        }
    }

    /// A continuation: a new editable user message through normal admission and dispatch, shown
    /// under the action's planned user item. Same-conversation Claude dispatch suppresses the
    /// implicit fresh-conversation fallback; the explicit new-conversation choice retires the
    /// failed conversation first (existing reset detach), never implicitly.
    private func dispatchRecoveryContinuation(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        guard let text = action.text, let userItemID = action.plannedUserItemID else {
            return .notDispatched("The message has no identity.")
        }
        guard recoveryActionStillCurrent(action, session: session, lane: lane) else {
            return .notDispatched(Self.recoveryActionStaleText)
        }
        if let blocked = newWorkBlockedMessage(for: session) { return .notDispatched(blocked) }
        guard !session.runState.isActive else { return .notDispatched("The session is working. Wait for it to finish.") }
        let conversationID = action.target.providerConversationID
        let isNewConversation = action.kind == .continueInNewConversation
        let usesClaude = session.selectedAgent.usesClaudeNativeRuntime
        if isNewConversation {
            guard usesClaude,
                  let conversationID,
                  session.recoveryResumeUnavailableConversationID == conversationID,
                  session.providerSessionID == conversationID
            else {
                return .notDispatched("The previous conversation can no longer be replaced. Review the item again.")
            }
            claudeCoordinator.prepareForConversationResetSync(session)
            session.providerSessionID = nil
            session.recoveryResumeFallbackSuppressedConversationID = nil
            session.recoveryResumeUnavailableConversationID = nil
            session.isDirty = true
        } else if usesClaude, let conversationID {
            session.recoveryResumeFallbackSuppressedConversationID = conversationID
        }
        let result = await submitUserTurnAdmittingRecoveryInput(
            text: text,
            tabID: session.tabID,
            origin: .followUp,
            userItemID: userItemID,
            reservedPayloadOnly: true,
            actionAuthorization: authorization,
            isStillCurrent: { [weak self] in
                self?.recoveryActionStillCurrent(action, session: session, lane: lane, checksTarget: !isNewConversation) ?? false
            }
        )
        switch result {
        case .submitted:
            return .dispatched
        case .scheduled:
            return .notDispatched("The message was scheduled instead of sent.")
        case let .blocked(message):
            if !isNewConversation, session.recoveryResumeFallbackSuppressedConversationID == conversationID {
                session.recoveryResumeFallbackSuppressedConversationID = nil
            }
            return .notDispatched(message.isEmpty ? "The message couldn't be sent." : message)
        }
    }

    /// Where Send saved finds its intent's deterministic bubble (review A P1-06).
    enum RecoverySavedIntentBubble: Equatable {
        /// Not shown anywhere (canonical transcript or working suffix): appended once.
        case absent
        /// Shown exactly as the saved payload would show it, and the conversation's latest user
        /// message: reused unchanged, the new run attaches to its turn.
        case shown(AgentChatItem)
        /// Shown, but not provably this payload's bubble or not attachable: nothing is sent.
        case refused(String)
    }

    static let recoverySavedBubbleMismatchText =
        "The message shown in the conversation differs from the saved message. Edit it to send it."
    static let recoverySavedBubbleNotLatestText =
        "Newer messages follow this saved message. Sending it without duplicating or moving its original bubble isn’t supported yet. Nothing was sent. You can edit it as a new message."

    /// Resolves the saved intent's deterministic bubble from the canonical transcript (request
    /// anchors and mid-turn user activities, including compacted history out of the working
    /// suffix) and the working suffix. Every occurrence must be a user item consistent with the
    /// saved payload's bubble (text, image IDs, tagged-file IDs, workflow); several suffix copies
    /// are ambiguous. A shown bubble is reusable only as the latest user message, so the new run
    /// attaches to its own turn rather than to a later one.
    func recoverySavedIntentBubble(
        userItemID: UUID,
        session: AgentTabSession,
        trimmedText: String,
        attachments: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?
    ) -> RecoverySavedIntentBubble {
        var canonical: [AgentChatItem] = []
        var latestOtherUserSequence: Int?
        func noteOtherUser(_ id: UUID, _ sequenceIndex: Int) {
            guard id != userItemID else { return }
            latestOtherUserSequence = max(latestOtherUserSequence ?? sequenceIndex, sequenceIndex)
        }
        for turn in session.transcript.turns {
            if let request = turn.request {
                if request.id == userItemID {
                    canonical.append(request.toItem())
                } else {
                    noteOtherUser(request.id, request.sequenceIndex)
                }
            }
            for span in turn.responseSpans {
                for activity in span.activities where activity.id == userItemID || activity.itemKind == .user {
                    if activity.id == userItemID {
                        canonical.append(activity.toItem())
                    } else {
                        noteOtherUser(activity.id, activity.sequenceIndex)
                    }
                }
            }
        }
        var suffix: [AgentChatItem] = []
        for item in session.items {
            if item.id == userItemID {
                suffix.append(item)
            } else if item.kind == .user {
                noteOtherUser(item.id, item.sequenceIndex)
            }
        }
        guard !canonical.isEmpty || !suffix.isEmpty else { return .absent }
        guard suffix.count <= 1 else { return .refused(Self.recoverySavedBubbleMismatchText) }
        let expectedText = Self.userBubbleText(
            trimmedText: trimmedText,
            attachments: attachments,
            taggedFiles: taggedFiles,
            workflow: workflow
        )
        let expectedImageIDs = attachments.map(\.id)
        let expectedTaggedIDs = taggedFiles.map(\.id)
        for item in canonical + suffix {
            guard item.kind == .user,
                  item.text == expectedText,
                  item.attachments.map(\.id) == expectedImageIDs,
                  item.taggedFileAttachments.map(\.id) == expectedTaggedIDs,
                  item.workflow?.id == workflow?.id
            else {
                return .refused(Self.recoverySavedBubbleMismatchText)
            }
        }
        // The working suffix copy is the live bubble; a canonical-only bubble is shown from history.
        guard let shown = suffix.first ?? canonical.first else { return .absent }
        if let latestOtherUserSequence, latestOtherUserSequence > shown.sequenceIndex {
            return .refused(Self.recoverySavedBubbleNotLatestText)
        }
        return .shown(shown)
    }

    /// Send saved: the one saved intent the reservation claimed, handed to normal dispatch under a
    /// store-issued queue receipt carrying the action's coordinator-issued authorization. Refused
    /// (kept, never withdrawn) when it carries a pending handoff or any earlier attempt may have
    /// delivered it (no uncertain-delivery retry); Edit stays available for those. An already
    /// shown bubble is reused by the normal submit path (`appendPreparedUserTurn`), never
    /// duplicated (review A P1-06).
    private func dispatchRecoverySavedIntent(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        guard action.sourceIntentIDs.count == 1, let intentID = action.sourceIntentIDs.first else {
            return .notDispatched("Send one saved message at a time.")
        }
        guard recoveryActionStillCurrent(action, session: session, lane: lane) else {
            return .notDispatched(Self.recoveryActionStaleText)
        }
        if let blocked = newWorkBlockedMessage(for: session) { return .notDispatched(blocked) }
        guard !session.runState.isActive else { return .notDispatched("The session is working. Wait for it to finish.") }
        guard case let .success(.supported(record)) = await lane.readRecord(), let intent = record.intent(id: intentID) else {
            return .notDispatched("The saved message couldn't be read.")
        }
        guard intent.pendingHandoff == nil else {
            return .notDispatched("This message carries earlier conversation history. Edit it to send it.")
        }
        // No uncertain-delivery retry: only a queued intent whose every earlier attempt is
        // conclusively not delivered may be sent again (its shown bubble is then reused).
        guard intent.deliveryState == .queued,
              AgentColdRestoreInterruptionContext.unacceptedDelivery(
                  state: intent.deliveryState,
                  attempts: record.attempts(forIntent: intentID)
              ) == .notSent
        else {
            return .notDispatched("This message may already have been delivered. Check the conversation, then edit it to send it again.")
        }
        var images: [AgentImageAttachment] = []
        for reference in intent.payload.images {
            guard let attachment = lane.store.attachment(for: reference, sessionID: lane.sessionID) else {
                return .notDispatched("An attachment of the saved message is missing. Edit it to send it.")
            }
            images.append(attachment)
        }
        let receipt: AgentRecoveryQueueReceipt
        switch await lane.issueQueueReceipt(intentID: intentID) {
        case let .success(value):
            receipt = value
        case let .failure(failure):
            return .notDispatched("The saved message can't be sent now (\(Self.recoveryListDescription(of: failure))).")
        }
        guard recoveryActionStillCurrent(action, session: session, lane: lane), !session.runState.isActive else {
            return .notDispatched(Self.recoveryActionStaleText)
        }
        let admitted = AdmittedUserTurnInput(
            identity: AgentQueuedInputIdentity(receipt: receipt, actionAuthorization: authorization),
            content: intent.payload,
            attachments: images,
            taggedFiles: intent.payload.taggedFiles.map(\.attachment),
            workflow: intent.payload.workflow?.definition,
            interviewFirst: intent.payload.interviewFirst,
            consumesComposer: false
        )
        switch submitUserTurn(text: intent.payload.text, tabID: session.tabID, codexAttemptID: nil, admitted: admitted) {
        case .submitted:
            return .dispatched
        case .scheduled:
            return .notDispatched("The message was scheduled instead of sent.")
        case let .blocked(message):
            return .notDispatched(message.isEmpty ? "The saved message couldn't be sent." : message)
        }
    }

    /// Review A P1-01: an action payload is only started as a local run; never queued behind a live
    /// run or sent through a remote host.
    static let recoveryActionSessionBusyMessage =
        "The session is working. Wait for it to finish, then choose again."

    /// Review A P1-01: a run start that provably handed the action's payload off to nothing ends its
    /// submission (revoked: a later queue drain or retry can never use the token). Codex
    /// `queuedFallback` is restart-held, not handoff, and `nil` means the runtime changed before
    /// send started. A sent, delivery-unknown, or admitted (non-Codex `nil`) start settles through
    /// its dispatch evidence or provider handoff instead.
    func noteRecoveryActionStartReturned(
        _ identity: AgentQueuedInputIdentity,
        outcome: CodexAgentModeCoordinator.NativeSendOutcome?,
        isCodex: Bool
    ) {
        guard let authorization = identity.actionAuthorization else { return }
        let ended: Bool = if isCodex {
            switch outcome {
            case .queuedFallback?, .stale?, .failed?, .cancelled?, nil:
                true
            case .sent?, .deliveryUnknown?:
                false
            }
        } else {
            Self.runStartDidNotHandOff(outcome)
        }
        guard ended else { return }
        let reason: String? = switch outcome {
        case let .stale(reason)?: reason
        case let .failed(message)?: message
        case .queuedFallback?: "The message was held instead of sent."
        default: nil
        }
        recoveryCoordinator?.noteRecoveryActionSubmissionEnded(authorization, reason: reason)
    }

    // MARK: Dispatch baseline (pre-send history position)

    /// Outcome of one Claude dispatch's pre-byte baseline admission.
    enum RecoveryDispatchBaselineAdmission: Equatable {
        /// Not qualified (production), not Claude, or no durable dispatch: nothing read or written.
        case notCaptured
        /// This dispatch already has its recorded boundary (a re-entered admission).
        case alreadyRecorded
        /// Captured, committed in a zero-row session receipt, then the cursor was seeded if absent.
        case committed
        /// No boundary can be taken before the bytes; recorded, and the ordinary send proceeds.
        case unsupported(String)
        /// The enabled baseline could not be persisted (or the session changed): zero bytes.
        case refused(String)

        var admitsWrite: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    func admitClaudeDispatchBaseline(_ identity: AgentDispatchBaselineIdentity?, session: AgentTabSession) async -> Bool {
        #if DEBUG
            if let override = test_claudeDispatchBaselineAdmission {
                return await override(identity, session)
            }
        #endif
        return await captureClaudeDispatchBaseline(identity, session: session).admitsWrite
    }

    /// Captures the dispatch's pre-send boundary (validated `.baseline` read off the main actor),
    /// commits it as a zero-row import receipt through ONE owner session save, verifies that exact
    /// receipt committed, and only then seeds the recovery cursor (compare-and-swap on "none"). A
    /// boundary is per dispatch and immutable; a missing conversation identity or history location
    /// is recorded as unsupported (never backfilled later) and the send proceeds ordinarily.
    func captureClaudeDispatchBaseline(
        _ identity: AgentDispatchBaselineIdentity?,
        session: AgentTabSession
    ) async -> RecoveryDispatchBaselineAdmission {
        // Production OFF: zero history reads, zero extra writes, ordinary send behavior.
        guard recoveryActionRunner.capturesDispatchBaselines, session.selectedAgent == .claudeCode else { return .notCaptured }
        guard let identity, let lane = session.recoveryLane, !lane.isRetired else { return .notCaptured }
        let generation = lane.binding.transcriptResetGeneration
        func stillCurrent(_ conversationID: String?) -> Bool {
            sessions[session.tabID] === session && session.recoveryLane === lane && !lane.isRetired
                && lane.binding.transcriptResetGeneration == generation
                && session.providerSessionID == conversationID
        }
        if let existing = session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID) {
            guard existing.status == .captured, let commitID = existing.baselineCommitID,
                  session.pendingHistoryImportCommit?.importID == commitID
            else { return .alreadyRecorded }
            // Its receipt is still pending from an earlier admission: it must commit before bytes.
            return await commitPendingBaselineReceipt(commitID, session: session)
                ? .alreadyRecorded
                : .refused("The pre-send history position couldn't be saved.")
        }
        func recordUnsupported(_ reason: String, conversationID: String?) -> RecoveryDispatchBaselineAdmission {
            var ledger = session.providerHistoryRecovery ?? AgentSessionProviderHistoryRecovery()
            ledger.dispatchBaselines.append(.init(
                dispatchID: identity.dispatchID,
                runAttemptID: identity.runAttemptID,
                transcriptResetGeneration: generation,
                providerRaw: ClaudeSessionHistoryReader.providerRaw,
                conversationID: conversationID,
                userItemIDs: identity.userItemIDs,
                file: nil,
                completeLineOffset: 0,
                baselineCommitID: nil,
                profileName: ClaudeSessionHistoryReader.profileName,
                status: .unsupported(reason),
                recordedAt: Date()
            ))
            session.providerHistoryRecovery = ledger
            session.isDirty = true
            scheduleSave(for: session.tabID)
            return .unsupported(reason)
        }
        guard let conversationID = session.providerSessionID, !conversationID.isEmpty else {
            return recordUnsupported("no Claude conversation identity before sending", conversationID: nil)
        }
        let roots = await recoveryClaudeHistoryRoots(conversationID: conversationID)
        guard stillCurrent(conversationID) else { return .refused(Self.recoveryActionStaleText) }
        guard !roots.isEmpty else {
            return recordUnsupported("Claude history location unknown", conversationID: conversationID)
        }
        let read = await Self.readClaudeHistory(RecoveryHistoryReadInput(
            conversationID: conversationID,
            roots: roots,
            mode: .baseline,
            ledger: nil
        ))
        guard stillCurrent(conversationID) else { return .refused(Self.recoveryActionStaleText) }
        let candidate: ClaudeSessionHistoryReader.Candidate
        switch read {
        case let .candidate(value):
            candidate = value
        case let .unavailable(reason):
            return recordUnsupported(Self.recoveryHistoryText(reason), conversationID: conversationID)
        case .unsupported:
            return recordUnsupported("Claude history contains records this version doesn't support", conversationID: conversationID)
        }
        // A pending receipt (a reset or an earlier import still saving) is flushed first; one
        // that cannot commit leaves no room for this boundary: zero bytes.
        if session.pendingTranscriptResetReceipt != nil || session.pendingHistoryImportCommit != nil {
            _ = await saveSession(for: session.tabID)
            guard stillCurrent(conversationID),
                  session.pendingTranscriptResetReceipt == nil,
                  session.pendingHistoryImportCommit == nil
            else { return .refused("An earlier save of this session is still pending.") }
        }
        let commitID = UUID()
        let now = Date()
        let receipt = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: commitID,
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            conversationID: conversationID,
            committedAt: now,
            rowCount: 0
        )
        let baseline = AgentSessionProviderHistoryRecovery.DispatchBaseline(
            dispatchID: identity.dispatchID,
            runAttemptID: identity.runAttemptID,
            transcriptResetGeneration: generation,
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            conversationID: conversationID,
            userItemIDs: identity.userItemIDs,
            file: candidate.file,
            completeLineOffset: candidate.completeLineOffset,
            baselineCommitID: commitID,
            profileName: ClaudeSessionHistoryReader.profileName,
            status: .captured,
            recordedAt: now
        )
        var ledger = session.providerHistoryRecovery ?? AgentSessionProviderHistoryRecovery()
        ledger.dispatchBaselines.append(baseline)
        ledger.lastImportCommit = receipt
        session.providerHistoryRecovery = ledger
        session.pendingHistoryImportCommit = receipt
        guard await commitPendingBaselineReceipt(commitID, session: session) else {
            // The receipt stays pending for the next owner save (a pre-byte boundary of a write that
            // never happened is harmless); the cursor did not move and nothing is sent.
            return .refused("The pre-send history position couldn't be saved.")
        }
        guard stillCurrent(conversationID), let cursor = baseline.cursor else {
            return .refused(Self.recoveryActionStaleText)
        }
        // Cursor second, and only when none exists: the session baseline is the authority.
        _ = await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor)
        return .committed
    }

    /// A zero-row baseline receipt is a real commit: saved through the owner save path and verified.
    private func commitPendingBaselineReceipt(_ commitID: UUID, session: AgentTabSession) async -> Bool {
        for _ in 0 ..< 2 {
            session.isDirty = true
            _ = await saveSession(for: session.tabID)
            if session.committedHistoryImportID == commitID { return true }
            guard session.pendingHistoryImportCommit?.importID == commitID else { return false }
        }
        return false
    }

    // MARK: History-only reconciliation

    /// Reads the provider's own record of the conversation (off the main actor), validates the
    /// whole candidate, then merges inert rows + native-ID ledger + import receipt through ONE owner
    /// session save; only after that save committed this receipt does the recovery cursor advance
    /// (compare-and-swap on the previous import). Never dispatches and never confirms Claude
    /// completion. Every failure is `.blocked` (never "nothing new", review A P1-02); a confirmed
    /// expected-turn completion survives a failed row save or a session change after the read
    /// (A P1-03 / B F2).
    func reconcileRecoveryHistory(
        _ action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        codexTurnID: String?,
        runTurnID: UUID? = nil
    ) async -> AgentRecoveryReconcileResult {
        guard recoveryActionStillCurrent(action, session: session, lane: lane) else {
            return .blocked(Self.recoveryActionStaleText)
        }
        guard let conversationID = action.target.providerConversationID else {
            return .blocked("No provider conversation is recorded for this session, so its history can't be checked.")
        }
        guard !session.runState.isActive else { return .blocked("The session is working. Reconcile after it finishes.") }
        guard session.pendingTranscriptResetReceipt == nil, session.pendingHistoryImportCommit == nil else {
            return .blocked("An earlier save of this session is still pending. Try again shortly.")
        }
        let record: AgentRecoveryRecord?
        switch await lane.readRecord() {
        case let .success(.supported(value)):
            record = value
        case .success(.absent):
            record = nil
        default:
            return .blocked("This session's recovery data couldn't be read.")
        }
        let ledgerAtStart = session.providerHistoryRecovery
        // Claude: the interrupted attempt's OWN pre-send baseline (its earliest dispatch) is the only
        // starting boundary; the conversation-level cursor is never a fallback. Checked before any read.
        var claudeBaseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?
        if session.selectedAgent == .claudeCode {
            claudeBaseline = action.sourceRunAttemptID.flatMap { ledgerAtStart?.firstDispatchBaseline(runAttemptID: $0) }
            if let refusal = AgentProviderHistoryAssociationPreflight.baselineRefusal(
                baseline: claudeBaseline,
                hasUnreadableBaselines: !(ledgerAtStart?.unreadableDispatchBaselines.isEmpty ?? true),
                expectedRunAttemptID: action.sourceRunAttemptID,
                providerRaw: ClaudeSessionHistoryReader.providerRaw,
                conversationID: conversationID,
                transcriptResetGeneration: lane.binding.transcriptResetGeneration
            ) {
                return .associationUnavailable(refusal, Self.recoveryAssociationText(refusal))
            }
        }
        let observation: AgentProviderHistoryObservation
        switch await recoveryHistoryObservation(
            action: action,
            session: session,
            lane: lane,
            conversationID: conversationID,
            claudeBoundary: claudeBaseline?.cursor,
            ledger: ledgerAtStart,
            codexTurnID: codexTurnID
        ) {
        case let .success(value):
            observation = value
        case let .failure(failure):
            // Only a successful observation that proved nothing (Codex has no usable record of the
            // turn) lets a continuation follow; every other failure blocks it.
            return failure.isUnconfirmedObservation ? .nothingImported(failure.message) : .blocked(failure.message)
        }
        // Completion counts only for the expected turn of the action's own source run attempt. It
        // is decided from the observation itself, independently of whether any row can be saved.
        let completion: AgentRecoveryReconcileCompletion = if observation.completionConfirmed,
                                                              let runAttemptID = action.sourceRunAttemptID
        {
            .confirmed(runAttemptID: runAttemptID)
        } else {
            .unconfirmed
        }
        // History-only merge: revalidated on the main actor against an unchanged session.
        guard recoveryActionStillCurrent(action, session: session, lane: lane),
              !session.runState.isActive,
              session.pendingTranscriptResetReceipt == nil,
              session.pendingHistoryImportCommit == nil,
              session.providerHistoryRecovery == ledgerAtStart
        else {
            return .blocked("The session changed while its history was read. Nothing was imported.", completion: completion)
        }
        let canonical = AgentProviderHistoryCanonicalView(transcript: session.transcript, suffixItems: session.items)
        // Claude: canonical import needs explicit native ↔ canonical associations (canonical turns,
        // compacted ones included, plus the mutable suffix). This build has none for normal live
        // conversations, so it refuses with zero changes and no cursor movement.
        if session.selectedAgent == .claudeCode,
           let refusal = AgentProviderHistoryAssociationPreflight.check(
               observation: observation,
               baseline: claudeBaseline,
               hasUnreadableBaselines: !(ledgerAtStart?.unreadableDispatchBaselines.isEmpty ?? true),
               expectedRunAttemptID: action.sourceRunAttemptID,
               transcriptResetGeneration: lane.binding.transcriptResetGeneration,
               canonical: canonical,
               ledger: ledgerAtStart
           )
        {
            return .associationUnavailable(refusal, Self.recoveryAssociationText(refusal))
        }
        // Codex: no native → canonical mapping exists for live Codex items, so rows that could
        // overlap output already in the conversation are withheld entirely (zero rows, zero writes,
        // no cursor movement); a confirmed completion stays honest (review A P1-04 / B F1).
        if session.selectedAgent == .codexExec {
            let turnUserItemIDs = Set(runTurnID.flatMap { turnID in
                session.transcript.turns.first { $0.id == turnID }?.request.map { [$0.id] }
            } ?? [])
            if AgentProviderHistoryAssociationPreflight.codexOverlapRefusal(
                observation: observation,
                turnUserItemIDs: turnUserItemIDs,
                canonical: canonical,
                ledger: ledgerAtStart
            ) != nil {
                if case .confirmed = completion { return .imported(completion: completion, rowCount: 0) }
                return .nothingImported(Self.recoveryCodexOverlapText)
            }
        }
        let previousCursor = record?.historyCursor(providerRaw: observation.provider.rawValue, conversationID: conversationID)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: Set(session.items.map(\.id)),
            ledger: ledgerAtStart,
            previousCursor: previousCursor,
            importID: UUID(),
            now: Date()
        )
        guard !plan.appendedItems.isEmpty || plan.ledger.nativeItems.count != (ledgerAtStart?.nativeItems.count ?? 0) else {
            if case .confirmed = completion { return .imported(completion: completion, rowCount: 0) }
            return .nothingImported("The provider has no new history for this conversation.")
        }
        session.providerHistoryRecovery = plan.ledger
        session.pendingHistoryImportCommit = plan.importCommit
        for item in plan.appendedItems {
            session.appendItem(item)
        }
        session.isDirty = true
        _ = await saveSession(for: session.tabID)
        guard session.committedHistoryImportID == plan.importID else {
            // The rows and receipt stay pending for the next owner save; the cursor did not move,
            // so a later reconcile rescans and the ledger keeps it idempotent. A confirmed
            // completion still stops a continuation.
            if case .confirmed = completion {
                return .blocked(
                    "The interrupted turn had already finished, but its recovered output couldn't be saved yet. Nothing was sent.",
                    completion: completion
                )
            }
            return .blocked("The recovered history couldn't be saved yet. Its position was not advanced. Nothing was sent.")
        }
        // Cursor second. A lost cursor commit is safe: the next import rescans and deduplicates.
        _ = await lane.commitHistoryCursor(expectedPreviousImportID: plan.previousImportID, cursor: plan.cursor)
        return .imported(completion: completion, rowCount: plan.appendedItems.count)
    }

    private struct RecoveryHistoryFailure: Error {
        let message: String
        /// The observation itself succeeded but proved nothing (not a failure of the check).
        var isUnconfirmedObservation = false
    }

    static let recoveryCodexOverlapText =
        "Codex's record of the turn overlaps output already shown in this conversation, so nothing was imported."

    /// Immutable reader inputs handed off the main actor (value types, never mutated).
    private struct RecoveryHistoryReadInput: @unchecked Sendable {
        let conversationID: String
        let roots: [URL]
        let mode: ClaudeSessionHistoryReader.Mode
        let ledger: AgentSessionProviderHistoryRecovery?
    }

    private nonisolated static func readClaudeHistory(_ input: RecoveryHistoryReadInput) async -> ClaudeSessionHistoryReader.Result {
        ClaudeSessionHistoryReader.read(
            nativeSessionID: input.conversationID,
            projectsDirectories: input.roots,
            mode: input.mode,
            ledger: input.ledger
        )
    }

    /// The `projects` roots under the Claude homes the registry recorded for this conversation's
    /// own runtimes (never the app environment or a guessed default). Empty = location unknown.
    private func recoveryClaudeHistoryRoots(conversationID: String) async -> [URL] {
        #if DEBUG
            test_recoveryClaudeHistoryAccessCount += 1
        #endif
        let homes: [String]
        #if DEBUG
            if let override = test_recoveryClaudeHistoryHomes {
                homes = await override(conversationID)
            } else {
                homes = await recoveryHistoryRegistry?.claudeProviderHomes(conversationID: conversationID) ?? []
            }
        #else
            homes = await recoveryHistoryRegistry?.claudeProviderHomes(conversationID: conversationID) ?? []
        #endif
        return homes.filter { !$0.isEmpty }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        }
    }

    private func recoveryHistoryObservation(
        action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        conversationID: String,
        claudeBoundary: AgentRecoveryHistoryCursor?,
        ledger: AgentSessionProviderHistoryRecovery?,
        codexTurnID: String?
    ) async -> Result<AgentProviderHistoryObservation, RecoveryHistoryFailure> {
        switch session.selectedAgent {
        case .codexExec:
            guard let codexTurnID else {
                return .failure(RecoveryHistoryFailure(message: "The interrupted Codex turn wasn't identified, so its history can't be matched."))
            }
            do {
                // The coordinator owns the observation transport: it borrows a compatible live
                // controller or creates (and joins the shutdown of) a temporary one after a cold
                // relaunch. The session's run, controller and event handling are never touched.
                let observed = try await codexCoordinator.observeRecovery(
                    session: session,
                    actionID: action.actionID,
                    threadID: conversationID,
                    expectedTurnID: codexTurnID,
                    sourceRunAttemptID: action.sourceRunAttemptID,
                    timeout: 15,
                    isCurrent: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return recoveryActionStillCurrent(action, session: session, lane: lane)
                    }
                )
                guard let observation = CodexRecoveryAdapter.historyObservation(observed) else {
                    return .failure(RecoveryHistoryFailure(
                        message: "Codex has no matching record of the interrupted turn.",
                        isUnconfirmedObservation: true
                    ))
                }
                return .success(observation)
            } catch {
                return .failure(RecoveryHistoryFailure(message: Self.recoveryCodexObservationText(error)))
            }
        case .claudeCode:
            guard let cursor = claudeBoundary else {
                return .failure(RecoveryHistoryFailure(message: Self.recoveryAssociationText(.baselineUnavailable)))
            }
            let roots = await recoveryClaudeHistoryRoots(conversationID: conversationID)
            guard !roots.isEmpty else {
                return .failure(RecoveryHistoryFailure(message: "Claude's history location for this conversation is unknown."))
            }
            let input = RecoveryHistoryReadInput(
                conversationID: conversationID,
                roots: roots,
                mode: .importAfter(cursor),
                ledger: ledger
            )
            switch await Self.readClaudeHistory(input) {
            case let .candidate(candidate):
                return .success(ClaudeSessionHistoryReader.observation(candidate))
            case let .unavailable(reason):
                return .failure(RecoveryHistoryFailure(message: Self.recoveryHistoryText(reason)))
            case .unsupported:
                return .failure(RecoveryHistoryFailure(
                    message: "Claude's history contains records this version doesn't support. Nothing was imported."
                ))
            }
        default:
            return .failure(RecoveryHistoryFailure(message: "History reconciliation isn't supported for this provider."))
        }
    }

    // MARK: Text

    static func recoveryHistoryText(_ reason: ClaudeSessionHistoryReader.Unavailable) -> String {
        switch reason {
        case .invalidSessionID:
            "The saved conversation identity isn't valid."
        case .notFound:
            "Claude's history for this conversation wasn't found."
        case .ambiguous:
            "More than one Claude history file matches this conversation, so none was chosen."
        case .unreadable:
            "Claude's history file couldn't be read."
        case .tooLarge:
            "Claude's history file is too large to check."
        case .unstableFile:
            "Claude's history file changed while it was read. Try again."
        case .baselineRequired:
            "No history position was saved before the interrupted run, so its history can't be matched safely."
        case .baselineLost:
            "Claude's history file was replaced and the previous position can't be located."
        case .inspectionFailed:
            "Claude's history location couldn't be checked, so its contents are unknown."
        case .partialTrailingRecord:
            "Claude's history ends in an incomplete record, so no safe position could be taken."
        }
    }

    static func recoveryCodexObservationText(_ error: Error) -> String {
        switch error as? CodexRecoveryObservationError {
        case .registeredTransportRequired:
            "Codex history can't be checked safely in this build. Nothing was imported."
        case .staleContext, .staleTransportGeneration:
            "The session or Codex connection changed while its history was read. Nothing was imported."
        case .sessionBusy:
            "The session is working. Reconcile after it finishes."
        case .missingIdentity:
            "The interrupted Codex turn wasn't identified, so its history can't be matched."
        case .unsupported, nil:
            "Codex history couldn't be read. Nothing was imported."
        }
    }

    static func recoveryAssociationText(_ refusal: AgentProviderHistoryAssociationRefusal) -> String {
        switch refusal {
        case .baselineUnavailable:
            "No history position was saved before the interrupted run, so its history can't be matched safely. Nothing was imported."
        case .baselineTargetMismatch:
            "The saved history position doesn't belong to this conversation and run. Nothing was imported."
        case .nativeUserAssociationUnavailable, .canonicalOutputAssociationUnavailable:
            "The pre-send history position was saved, but this build cannot safely match Claude's history to messages already in this conversation. Nothing was imported."
        }
    }

    /// A previous launch's open action, shown before any new choice replaces it.
    static func recoveryPriorActionText(_ join: AgentRecoveryActionJoin) -> String {
        switch join {
        case .notDispatched:
            "An earlier choice on this item, made before RepoPrompt restarted, didn't send anything. It is kept. Choose again to replace it."
        case .notHandedOff:
            "An earlier choice on this item, made before RepoPrompt restarted, saved a message that wasn't sent. It stays listed. Choose again to replace the choice."
        case .dispatchEvidence, .unknown, .resolved:
            "An earlier choice on this item, made before RepoPrompt restarted, may have reached the agent; its status is unknown. Check the conversation. Only a new continuation you confirm can follow it."
        }
    }

    static func recoveryActionJoinText(_ join: AgentRecoveryActionJoin) -> String? {
        switch join {
        case let .resolved(outcome):
            outcome.kind == .notDispatched ? (outcome.reason ?? "Nothing was sent.") : nil
        case .notDispatched:
            "An earlier choice on this item didn't send anything. It is kept for review."
        case .notHandedOff:
            "An earlier choice on this item saved a message that wasn't sent. Review it in the list."
        case .dispatchEvidence:
            "An earlier choice on this item was interrupted; its delivery status is unknown. Check the conversation before choosing again."
        case .unknown:
            "An earlier choice on this item can't be checked by this version."
        }
    }

    /// Run identity of a run row (interrupted turn, recorded outcome, or recovery-only run).
    private static func recoveryRunReference(_ payload: AgentRecoveryCatalogPayload) -> (runAttemptID: UUID?, turnID: UUID?)? {
        switch payload {
        case let .turn(turn):
            (turn.interruption.runAttemptID, turn.turnID)
        case let .outcomeTurn(outcome):
            (outcome.runAttempt.runAttemptID, outcome.turnID)
        case let .recoveryOnlyRun(attempt):
            (attempt.runAttemptID, attempt.transcriptTurnID)
        default:
            nil
        }
    }
}
