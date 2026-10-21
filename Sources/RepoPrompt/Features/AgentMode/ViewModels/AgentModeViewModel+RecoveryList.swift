import Foundation
import RepoPromptAgentCore

// Lossless-restart Phase 1b basic recovery list: held recovered input (View / Edit / Remove),
// crash holds, interrupted turns, held schedule transfers, and unknown recovery status, backed by
// the recovery coordinator's authoritative startup results (closed sessions included). Opening a
// row never starts a provider; every action revalidates the session's lane, lifecycle, and the
// durable record before it writes, and a row disappears only after its action committed.

extension AgentModeViewModel {
    // MARK: Props

    func recoveryListProps(forActiveSession activeSession: AgentTabSession?) -> AgentRecoveryListProps? {
        if let failure = recoveryCompositionFailure {
            return AgentRecoveryListProps(
                status: .failed("Interrupted-work recovery is unavailable (\(failure)). Sending stays paused."),
                rows: [],
                canRetry: false
            )
        }
        guard let coordinator = recoveryCoordinator else { return nil }
        let status: AgentRecoveryListProps.Status = switch coordinator.startupState {
        case .notStarted, .loading:
            .loading
        case .ready:
            .ready
        case let .failed(message):
            .failed("Interrupted work could not be checked: \(message). Sending stays paused until this succeeds.")
        }
        let rows = status == .ready ? recoveryListRows(coordinator: coordinator, activeSession: activeSession) : []
        let canRetry = if case .failed = status { recoveryStartupRetry != nil } else { false }
        let props = AgentRecoveryListProps(status: status, rows: rows, canRetry: canRetry)
        return props.isEmpty ? nil : props
    }

    private func recoveryListRows(
        coordinator: AgentRecoveryCoordinator,
        activeSession: AgentTabSession?
    ) -> [AgentRecoveryListRowProps] {
        let workspaceID = persistenceWorkspace?.id
        let activeSessionID = activeSession?.activeAgentSessionID
        var rows: [AgentRecoveryListRowProps] = []
        func append(
            _ id: String,
            sessionID: UUID?,
            name: String,
            title: String,
            detail: String,
            text: String? = nil,
            attachmentNames: [String] = [],
            actions: [AgentRecoveryListRowProps.Action] = [],
            confirmation: String? = nil
        ) {
            let state = recoveryListRowStates[id]
            guard state != .resolved else { return }
            let error: String? = if case let .failed(message)? = state { message } else { nil }
            rows.append(AgentRecoveryListRowProps(
                id: id,
                sessionID: sessionID,
                sessionName: name,
                title: title,
                detail: detail,
                text: text,
                attachmentNames: attachmentNames,
                actions: actions,
                isWorking: state == .working,
                error: error,
                confirmation: confirmation
            ))
        }
        let currentInstanceID = coordinator.store.appInstanceID
        /// Held input of one session from its current record (the startup snapshot overlaid with
        /// later commits). Earlier-launch intents that need a decision are listed; this launch's
        /// intents when held (their projection was removed), stale-marked, or uncertain after their
        /// run ended. Any other one is still projected by a live queue or an active run.
        func appendIntentRows(
            sessionID: UUID,
            name: String,
            record: AgentRecoveryRecord,
            currentGeneration: UInt64,
            isActive: Bool,
            isRemote: Bool = false,
            openAction: [AgentRecoveryListRowProps.Action]
        ) {
            let key = sessionID.uuidString
            let heldReasons = coordinator.heldIntents(sessionID: sessionID, incarnationID: record.incarnationID)
            for intent in record.intents where Self.recoveryListShowsIntent(intent) {
                let isEarlierLaunch = intent.appInstanceID != currentInstanceID
                let heldReason = heldReasons[intent.intentID]
                    ?? (isEarlierLaunch ? nil : AgentRecoveryCoordinator.uncertainInputHoldReason(intent, in: record))
                guard isEarlierLaunch || heldReason != nil || intent.staleTargetMarkedAt != nil else { continue }
                let sameGeneration = intent.transcriptResetGeneration == currentGeneration
                var detail = isRemote && intent.deliveryState == .deliveryUnknown
                    ? Self.recoveryListRemoteUncertainty
                    : Self.recoveryListCertainty(of: intent.deliveryState, earlierLaunch: isEarlierLaunch)
                if let heldReason {
                    detail += " \(heldReason)"
                } else if !isEarlierLaunch {
                    detail += " \(AgentRecoverySessionLane.sessionChangedHoldReason)"
                }
                if !sameGeneration {
                    detail += " It was written before the conversation was cleared, so it can't be moved into it."
                }
                let actions: [AgentRecoveryListRowProps.Action] = isActive
                    ? Self.recoveryListIntentActions(intent.deliveryState, sameGeneration: sameGeneration)
                    : openAction
                append(
                    "intent-\(key)-\(intent.intentID.uuidString)",
                    sessionID: sessionID,
                    name: name,
                    title: Self.recoveryListTitle(of: intent.deliveryState),
                    detail: detail,
                    text: intent.payload.text,
                    attachmentNames: Self.recoveryListAttachmentNames(intent.payload),
                    actions: actions
                )
            }
        }
        /// R4: questions that were pending when an earlier launch shut down. Historical text only:
        /// the old request is never resumed; its text can be copied into an empty message box.
        func appendQuestionRows(
            sessionID: UUID,
            name: String,
            record: AgentRecoveryRecord,
            isActive: Bool,
            openAction: [AgentRecoveryListRowProps.Action]
        ) {
            let earlier = record.questions.filter { $0.appInstanceID != currentInstanceID }
            guard !earlier.isEmpty else { return }
            let liveIsEmpty: Bool = {
                guard isActive, let session = activeSession, let lane = session.recoveryLane else { return false }
                return recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)?.isEmpty ?? false
            }()
            for snapshot in earlier {
                let actions: [AgentRecoveryListRowProps.Action] = isActive
                    ? (liveIsEmpty ? [.restoreDraft, .discardDraft] : [.discardDraft])
                    : openAction
                append(
                    Self.recoveryListQuestionRowID(sessionID: sessionID, interactionID: snapshot.interactionID),
                    sessionID: sessionID,
                    name: name,
                    title: "Unanswered question",
                    detail: liveIsEmpty || !isActive
                        ? "The agent was waiting for an answer when RepoPrompt closed. That request has ended; you can copy the question and any partial answer into the message box."
                        : "The agent was waiting for an answer when RepoPrompt closed. That request has ended. Clear the message box to copy it there, or dismiss it.",
                    text: snapshot.composerText,
                    actions: actions
                )
            }
        }
        var listedSessionIDs: Set<UUID> = []

        for failure in coordinator.reconciliation.workspaceFailures where failure.workspaceID == workspaceID {
            append(
                "workspace-\(failure.workspaceID.uuidString)",
                sessionID: nil,
                name: "This workspace",
                title: "Interrupted work could not be checked",
                detail: "\(failure.reason) Sending and scheduling in this workspace stay paused."
            )
        }

        for resolution in coordinator.reconciliation.sessions {
            // This workspace's sessions; a session without an established destination is listed
            // in every workspace (it may belong to any of them).
            guard resolution.workspaceID == nil || resolution.workspaceID == workspaceID else { continue }
            let sessionID = resolution.sessionID
            let key = sessionID.uuidString
            let name = resolution.sessionName ?? "Session \(key.prefix(8))"
            let isActive = sessionID == activeSessionID
            let openAction: [AgentRecoveryListRowProps.Action] = isActive || resolution.composeTabID == nil ? [] : [.open]
            switch resolution.classification {
            case .idle, .tombstoned:
                continue
            case let .nonactionable(reason):
                append(
                    "status-\(key)",
                    sessionID: sessionID,
                    name: name,
                    title: "Recovery status unknown",
                    detail: "\(Self.recoveryListDescription(of: reason)) Its saved data is kept unchanged; sending to it stays paused."
                )
                continue
            case .duplicateDestination:
                append(
                    "status-\(key)",
                    sessionID: sessionID,
                    name: name,
                    title: "Recovery status unknown",
                    detail: "More than one workspace holds this session, so recovery can't choose one. Sending to it stays paused."
                )
                continue
            case .noDestination:
                append(
                    "status-\(key)",
                    sessionID: sessionID,
                    name: name,
                    title: "Recovery status unknown",
                    detail: "Recovered messages exist for a session whose saved conversation wasn't found. They are kept unchanged."
                )
                continue
            case .actionable:
                break
            }
            guard let binding = resolution.binding else { continue }

            if let hold = coordinator.crashHold(for: sessionID), coordinator.blockingCrashHold(for: binding) != nil {
                append(
                    "crash-\(key)",
                    sessionID: sessionID,
                    name: name,
                    title: "The previous run may still be running",
                    detail: hold.previousExitProvenClean
                        ? "RepoPrompt closed while this session was working. Sending to it is paused until you confirm the previous run has stopped."
                        : "RepoPrompt quit unexpectedly while this session was working. Sending to it is paused until you confirm the previous run has stopped.",
                    actions: [.confirmStopped] + openAction
                )
            }

            if case let .held(message) = resolution.scheduleTransfer,
               coordinator.restrictions.sessionRestriction(sessionID) != nil
            {
                append(
                    "transfer-\(key)",
                    sessionID: sessionID,
                    name: name,
                    title: "Scheduled message held",
                    detail: "\(message) It won't be sent until this is resolved.",
                    actions: [.cancelSchedule] + openAction,
                    confirmation: "Cancel this pending schedule? The message stays listed with its delivery unconfirmed; it won't be sent again automatically."
                )
            }

            for turn in resolution.interruptedTurns {
                let title = switch turn.status {
                case .interrupted:
                    "Turn interrupted"
                case .completedTailMayBeMissing:
                    "Completed while RepoPrompt was closed"
                }
                let detail = switch turn.status {
                case .interrupted:
                    "\(Self.recoveryListDescription(of: turn.interruption.reason)) The saved conversation stops where it was interrupted."
                case .completedTailMayBeMissing:
                    "The run finished, but the end of its transcript may be missing."
                }
                append(
                    "turn-\(key)-\(turn.turnID.uuidString)",
                    sessionID: sessionID,
                    name: name,
                    title: title,
                    detail: detail,
                    actions: [.hide] + openAction
                )
            }

            // R1a: a run whose turn was never saved is still listed from its recovery evidence. A
            // finished run (R09) shows its recorded outcome; it holds nothing.
            for attempt in resolution.recoveryOnlyRunAttempts {
                let (title, detail) = Self.recoveryOnlyRunRowText(attempt)
                append(
                    "run-\(key)-\(attempt.runAttemptID.uuidString)",
                    sessionID: sessionID,
                    name: name,
                    title: title,
                    detail: detail,
                    actions: [.hide] + openAction
                )
            }

            listedSessionIDs.insert(sessionID)
            guard let record = recoveryListCurrentRecord(
                coordinator: coordinator,
                sessionID: sessionID,
                startup: resolution.record?.record,
                incarnationID: binding.incarnationID
            ) else { continue }
            appendIntentRows(
                sessionID: sessionID,
                name: name,
                record: record,
                currentGeneration: recoveryListLiveLane(sessionID: sessionID)?.binding.transcriptResetGeneration
                    ?? max(binding.transcriptResetGeneration, record.transcriptResetGeneration),
                isActive: isActive,
                isRemote: resolution.remoteHostID != nil,
                openAction: openAction
            )
            appendQuestionRows(
                sessionID: sessionID,
                name: name,
                record: record,
                isActive: isActive,
                openAction: openAction
            )
        }

        // This launch's held input of sessions absent from the startup results (created this
        // launch, or first written since), from any owner or window of this workspace.
        for (sessionID, held) in coordinator.heldIntentSessions.sorted(by: { $0.key.uuidString < $1.key.uuidString })
            where !listedSessionIDs.contains(sessionID) && held.workspaceID == workspaceID
        {
            guard case let .supported(record)? = coordinator.liveRecordState(for: sessionID),
                  record.incarnationID == held.incarnationID
            else { continue }
            appendIntentRows(
                sessionID: sessionID,
                name: recoveryListSessionName(sessionID),
                record: record,
                currentGeneration: recoveryListLiveLane(sessionID: sessionID)?.binding.transcriptResetGeneration
                    ?? record.transcriptResetGeneration,
                isActive: sessionID == activeSessionID,
                openAction: []
            )
        }

        // Composer recovery state of this window's sessions (held or unsaved drafts, failures).
        let tabSessions = sessions.values.sorted { lhs, rhs in
            if (lhs === activeSession) != (rhs === activeSession) { return lhs === activeSession }
            return lhs.tabID.uuidString < rhs.tabID.uuidString
        }
        for session in tabSessions {
            appendComposerRows(for: session, coordinator: coordinator, append: append)
        }

        // Unsaved input of a released lane whose owner went away (no lane inherited it yet).
        for (sessionID, ownerless) in coordinator.ownerlessUnsavedInputs.sorted(by: { $0.key.uuidString < $1.key.uuidString })
            where ownerless.workspaceID == workspaceID && coordinator.lane(for: sessionID) == nil
        {
            guard let entry = ownerless.inputs.first else { continue }
            // R02: a restored draft whose rollback is still owed is saved, but only an open session
            // can resolve it (durably); it offers no discard here.
            let awaitsRollback = entry.restoreRollback != nil
            append(
                "draft-ownerless-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))",
                sessionID: sessionID,
                name: recoveryListSessionName(sessionID),
                title: awaitsRollback ? "Restored draft" : "Unsaved draft",
                detail: awaitsRollback
                    ? "Its tab closed before this restored draft could be put back\(Self.recoveryListFailureSuffix(entry.failure)). It is kept. Open the session to resolve it."
                    : "Its tab closed before this draft could be saved\(Self.recoveryListFailureSuffix(entry.failure)). Open the session to restore it, or discard it.",
                text: entry.content.text,
                attachmentNames: Self.recoveryListAttachmentNames(entry.content),
                actions: awaitsRollback ? [] : [.discardDraft],
                confirmation: awaitsRollback ? nil : "Discard this unsaved draft? This can't be undone."
            )
        }
        return rows
    }

    private typealias RecoveryListAppend = (
        _ id: String,
        _ sessionID: UUID?,
        _ name: String,
        _ title: String,
        _ detail: String,
        _ text: String?,
        _ attachmentNames: [String],
        _ actions: [AgentRecoveryListRowProps.Action],
        _ confirmation: String?
    ) -> Void

    /// Held composer, unsaved predecessor input, composer save/restore failures, and owner
    /// preparation failures of one tab. Restore is offered only into an empty message box; Discard
    /// always asks first and keeps (and saves) current typing.
    private func appendComposerRows(
        for session: AgentTabSession,
        coordinator: AgentRecoveryCoordinator,
        append: RecoveryListAppend
    ) {
        let name = resolvedSessionDisplayName(for: session.tabID)
        if let failure = coordinator.composerPreparation(for: session)?.failure {
            append(
                "draft-prep-\(session.tabID.uuidString)",
                session.activeAgentSessionID,
                name,
                "Message box not saved yet",
                "Your current text couldn't be prepared for saving (\(Self.recoveryListDescription(of: failure))). It is still in the message box.",
                nil,
                [],
                [.retrySave],
                nil
            )
        }
        guard let lane = session.recoveryLane, !lane.isRetired else { return }
        let sessionID = lane.sessionID
        let liveIsEmpty = recoveryInputContent(for: session, store: lane.store, sessionID: sessionID)?.isEmpty ?? false
        switch lane.composerState {
        case let .held(snapshot):
            append(
                Self.recoveryListHeldDraftRowID(sessionID: sessionID, revision: snapshot.revision),
                sessionID,
                name,
                "Draft from before the conversation was cleared",
                liveIsEmpty
                    ? "It was kept when the conversation was cleared. Restore it into the message box, or discard it."
                    : "The message box has new text, so it can't be restored now; both are kept. Discarding it saves your current text.",
                snapshot.content.text,
                Self.recoveryListAttachmentNames(snapshot.content),
                liveIsEmpty ? [.restoreDraft, .discardDraft] : [.discardDraft],
                liveIsEmpty
                    ? "Discard the draft from before the conversation was cleared? This can't be undone."
                    : "Discard the draft from before the conversation was cleared and save your current text?"
            )
        case let .restoreFailed(failure):
            append(
                "draft-restorefail-\(sessionID.uuidString)",
                sessionID,
                name,
                "Saved draft couldn't be loaded",
                "\(Self.recoveryListDescription(of: failure)) It is kept unchanged; sending from the message box stays paused until it loads.",
                nil,
                [],
                [.retrySave],
                nil
            )
        case .unrestored, .restoring, .ready:
            break
        }
        if let entry = lane.unsavedPredecessorInputs.first {
            let count = lane.unsavedPredecessorInputs.count
            let suffix = Self.recoveryListFailureSuffix(entry.failure)
            let choice = liveIsEmpty
                ? "Restore it into the message box, or discard it."
                : "Clear the message box to restore it, or discard it."
            append(
                "draft-unsaved-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))",
                sessionID,
                name,
                count == 1 ? "Unsaved draft" : "Unsaved draft (1 of \(count))",
                "This draft couldn't be saved\(suffix). \(choice) Sending in this session is paused until it is resolved.",
                entry.content.text,
                Self.recoveryListAttachmentNames(entry.content),
                liveIsEmpty ? [.restoreDraft, .discardDraft] : [.discardDraft],
                "Discard this unsaved draft? This can't be undone."
            )
        }
        if let failure = lane.composer.lastWriteFailure {
            if case .store(.heldComposerUnresolved) = failure {
                // Presented by the held-draft row: writes resume once it is resolved.
            } else {
                append(
                    "draft-savefail-\(sessionID.uuidString)",
                    sessionID,
                    name,
                    "Message box not saved",
                    "Your latest text couldn't be saved (\(Self.recoveryListDescription(of: failure))). It is still in the message box.",
                    nil,
                    [],
                    [.retrySave],
                    nil
                )
            }
        }
    }

    /// The session's record as currently committed: the latest commit published since composition,
    /// else the startup snapshot. `nil` for a removed record or another incarnation.
    private func recoveryListCurrentRecord(
        coordinator: AgentRecoveryCoordinator,
        sessionID: UUID,
        startup: AgentRecoveryRecord?,
        incarnationID: UUID
    ) -> AgentRecoveryRecord? {
        guard let live = coordinator.liveRecordState(for: sessionID) else { return startup }
        switch live {
        case let .supported(record):
            return record.incarnationID == incarnationID ? record : nil
        case .absent:
            return nil
        }
    }

    /// This window's tab owning `sessionID` with a live lane, if any.
    private func recoveryListTabSession(sessionID: UUID) -> AgentTabSession? {
        sessions.values.first { session in
            guard let lane = session.recoveryLane else { return false }
            return !lane.isRetired && lane.sessionID == sessionID
        }
    }

    private func recoveryListLiveLane(sessionID: UUID) -> AgentRecoverySessionLane? {
        recoveryCoordinator?.lane(for: sessionID)
    }

    private func recoveryListSessionName(_ sessionID: UUID) -> String {
        if let session = recoveryListTabSession(sessionID: sessionID) {
            return resolvedSessionDisplayName(for: session.tabID)
        }
        if let name = recoveryCoordinator?.reconciliation.resolution(for: sessionID)?.sessionName {
            return name
        }
        return "Session \(sessionID.uuidString.prefix(8))"
    }

    static func recoveryListQuestionRowID(sessionID: UUID, interactionID: UUID) -> String {
        "question-\(sessionID.uuidString)-\(interactionID.uuidString)"
    }

    static func recoveryListHeldDraftRowID(sessionID: UUID, revision: AgentRecoveryComposerRevision) -> String {
        "draft-held-\(sessionID.uuidString)-\(recoveryListToken(String(describing: revision)))"
    }

    /// Identity of one displayed unsaved entry within this process (row IDs carry it, so an action
    /// applies only to exactly the entry that was shown).
    static func recoveryListFingerprint(_ entry: AgentRecoveryUnsavedComposerInput) -> String {
        recoveryListToken(String(describing: entry))
    }

    private static func recoveryListToken(_ value: String) -> String {
        var hasher = Hasher()
        hasher.combine(value)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }

    private static func recoveryListAttachmentNames(_ content: AgentRecoveryInputContent) -> [String] {
        content.images.map { $0.title ?? $0.managedFileName ?? "Image" } + content.taggedFiles.map(\.displayName)
    }

    private static func recoveryListFailureSuffix(_ failure: AgentRecoveryControllerFailure?) -> String {
        failure.map { " (\(recoveryListDescription(of: $0)))" } ?? ""
    }

    private static func recoveryListDescription(of failure: AgentRecoveryControllerFailure) -> String {
        switch failure {
        case let .store(error):
            "saving failed: \(error)"
        case let .lifecycleRejected(reason):
            "the session changed: \(reason)"
        case .retired:
            "the session moved to another tab or window"
        case .noHeldComposer, .heldInputChanged:
            "it changed while it was being saved"
        case .liveComposerHasUnsavedContent:
            "the message box has newer text"
        case .composerChangedDuringRestore:
            "the message box changed while the draft was being restored"
        }
    }

    private static func recoveryListDescription(of failure: AgentRecoveryComposerPreparationFailure) -> String {
        switch failure {
        case let .authorityUnavailable(reason):
            "the session isn't ready: \(reason)"
        case .ownerReplaced:
            "the tab changed"
        case let .imagePromotionFailed(reason):
            "an image couldn't be saved: \(reason)"
        }
    }

    /// Actions the store can honour (F-12): Edit moves the text into the message box and withdraws
    /// the intent, so it is offered only for input that was never delivered (`queued`, `failed`);
    /// possibly delivered input (`deliveryUnknown`) can only be removed; a handoff still in progress
    /// (`dispatching`) is view-only.
    private static func recoveryListIntentActions(
        _ state: AgentRecoveryDeliveryState,
        sameGeneration: Bool
    ) -> [AgentRecoveryListRowProps.Action] {
        switch state {
        case .queued, .failed:
            sameGeneration ? [.edit, .remove] : [.remove]
        case .deliveryUnknown:
            [.remove]
        case .dispatching, .providerAccepted, .withdrawn:
            []
        }
    }

    /// Held input that may still need a user decision. Accepted and withdrawn intents need none.
    private static func recoveryListShowsIntent(_ intent: AgentRecoveryIntent) -> Bool {
        switch intent.deliveryState {
        case .queued, .dispatching, .deliveryUnknown, .failed:
            true
        case .providerAccepted, .withdrawn:
            false
        }
    }

    private static func recoveryListTitle(of state: AgentRecoveryDeliveryState) -> String {
        switch state {
        case .queued:
            "Saved message, not sent"
        case .failed:
            "Message not sent"
        case .dispatching, .deliveryUnknown:
            "Message may have been delivered"
        case .providerAccepted:
            "Message delivered"
        case .withdrawn:
            "Message removed"
        }
    }

    /// F-3: a remote session's host-RPC response is not provider evidence. Never "not sent".
    static let recoveryListRemoteUncertainty =
        "The host received the command; provider delivery is unconfirmed. Retrying may duplicate it."

    private static func recoveryListCertainty(of state: AgentRecoveryDeliveryState, earlierLaunch: Bool) -> String {
        switch state {
        case .queued:
            earlierLaunch
                ? "It was saved before RepoPrompt closed and was never handed to the agent."
                : "It is saved and was never handed to the agent."
        case .failed:
            "Sending it failed; it was not delivered."
        case .dispatching, .deliveryUnknown:
            earlierLaunch
                ? "RepoPrompt closed while sending it. Sending it again could deliver it twice."
                : "Sending it started but wasn't confirmed. Sending it again could deliver it twice."
        case .providerAccepted:
            "The agent received it."
        case .withdrawn:
            "You removed it."
        }
    }

    /// Row text for a run attempt the saved transcript does not represent. A finished run states
    /// its recorded outcome and that its transcript turn is missing; it is never shown as running.
    static func recoveryOnlyRunRowText(_ attempt: AgentRecoveryRunAttempt) -> (title: String, detail: String) {
        guard let terminal = attempt.terminal else {
            return (
                "Run interrupted before it was saved",
                "A run started but its turn was not saved before RepoPrompt stopped. Its output may be missing."
            )
        }
        let outcome = switch terminal.terminalState {
        case .completed: "The run completed"
        case .cancelled: "The run was stopped"
        case .failed: "The run failed"
        default: "The run ended"
        }
        return (
            "Run finished, but its turn wasn't saved",
            "\(outcome), but its turn was not saved before RepoPrompt stopped. Its output is missing from the conversation."
        )
    }

    private static func recoveryListDescription(of reason: AgentTranscriptTurnInterruption.Reason) -> String {
        switch reason {
        case .appCrash:
            "RepoPrompt quit unexpectedly during this turn."
        case .appQuit:
            "RepoPrompt was quit during this turn."
        case .windowClose:
            "The window was closed during this turn."
        case .safeRestart:
            "RepoPrompt restarted during this turn."
        case .providerProcessLost:
            "The agent process stopped during this turn."
        case .unknown:
            "RepoPrompt closed during this turn; the cause is unknown."
        }
    }

    private static func recoveryListDescription(of reason: AgentSessionRecoveryNonactionableReason) -> String {
        switch reason {
        case .sessionFileUnavailable:
            "The saved conversation couldn't be found."
        case .authorityMismatch:
            "The recovered data doesn't match the saved conversation."
        case .authorityUnreadable:
            "The saved conversation couldn't be read."
        case .unreadableRecord:
            "The recovered data couldn't be read."
        }
    }

    // MARK: Actions

    /// Performs one row action; failures stay visible inline on the row (repeat the action to retry).
    func performRecoveryListAction(rowID: String, action: AgentRecoveryListRowProps.Action) async {
        guard recoveryListRowStates[rowID] != .working else { return }
        recoveryListRowStates[rowID] = .working
        refreshRecoveryListUI()
        let failure: String? = switch action {
        case .edit:
            await editRecoveredIntent(rowID: rowID)
        case .remove:
            await removeRecoveredIntent(rowID: rowID)
        case .open:
            await openRecoveryListSession(rowID: rowID)
        case .confirmStopped:
            await confirmRecoveryCrashHold(rowID: rowID)
        case .hide:
            nil
        case .restoreDraft:
            await resolveRecoveryListDraft(rowID: rowID, choice: .restoreToComposer)
        case .discardDraft:
            await resolveRecoveryListDraft(rowID: rowID, choice: .discard)
        case .retrySave:
            await retryRecoveryListSave(rowID: rowID)
        case .cancelSchedule:
            await cancelRecoveryScheduleTransfer(rowID: rowID)
        }
        if let failure {
            recoveryListRowStates[rowID] = .failed(failure)
        } else {
            // Draft rows are backed by live state and leave once it is resolved; their IDs may
            // recur (a later failure), so they are never marked resolved.
            let conditionBacked = action == .open || rowID.hasPrefix(Self.recoveryListDraftRowPrefix)
            recoveryListRowStates[rowID] = conditionBacked ? nil : .resolved
        }
        refreshRecoveryListUI()
    }

    static let recoveryListDraftRowPrefix = "draft-"

    /// The session UUID following `prefix` in a draft row ID (`draft-<kind>-<UUID>[-<token>]`).
    private func recoveryListDraftRowID(_ rowID: String, kind: String) -> UUID? {
        let prefix = "\(Self.recoveryListDraftRowPrefix)\(kind)-"
        guard rowID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(prefix.count).prefix(36)))
    }

    /// Restore / Discard of exactly the displayed held draft, unsaved predecessor draft, or ownerless
    /// draft. The row ID carries the displayed revision or entry identity; a changed draft is never
    /// resolved in its place.
    private func resolveRecoveryListDraft(rowID: String, choice: AgentRecoveryHeldComposerChoice) async -> String? {
        if rowID.hasPrefix("question-") {
            return await resolveRecoveryListQuestion(rowID: rowID, choice: choice)
        }
        let changed = "This draft changed. Review it again."
        if let sessionID = recoveryListDraftRowID(rowID, kind: "ownerless") {
            guard choice == .discard,
                  let coordinator = recoveryCoordinator,
                  let entry = coordinator.ownerlessUnsavedInputs[sessionID]?.inputs.first,
                  rowID == "draft-ownerless-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))"
            else { return changed }
            return coordinator.discardOwnerlessUnsavedInput(sessionID: sessionID, expected: entry) ? nil : changed
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "held") {
            guard let session = recoveryListTabSession(sessionID: sessionID),
                  let lane = session.recoveryLane,
                  case let .held(snapshot) = lane.composerState,
                  rowID == Self.recoveryListHeldDraftRowID(sessionID: sessionID, revision: snapshot.revision)
            else { return changed }
            switch await resolveHeldRecoveryComposer(choice, expectedHeldRevision: snapshot.revision, for: session) {
            case .success:
                return nil
            case let .failure(failure):
                return Self.recoveryListDraftFailureText(failure)
            }
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "unsaved") {
            guard let session = recoveryListTabSession(sessionID: sessionID),
                  let lane = session.recoveryLane,
                  let entry = lane.unsavedPredecessorInputs.first,
                  rowID == "draft-unsaved-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))"
            else { return changed }
            let liveIsEmpty = recoveryInputContent(for: session, store: lane.store, sessionID: sessionID)?.isEmpty ?? false
            switch await lane.resolveUnsavedPredecessorInput(choice, expected: entry, liveComposerIsEmpty: liveIsEmpty) {
            case let .failure(failure):
                return Self.recoveryListDraftFailureText(failure)
            case let .success(content):
                guard session.recoveryLane === lane else { return nil }
                if let content {
                    // Already forwarded to the lane as its live composer; shown without a new edit.
                    applyRecoveredComposer(content, lane: lane, to: session)
                } else {
                    // Current typing (kept) is forwarded again now that admission can reopen.
                    recoveryComposerDidMutate(session: session)
                }
                return nil
            }
        }
        return changed
    }

    /// R4: copies an earlier launch's unanswered question into the empty message box (saved first),
    /// or dismisses it. Never resumes the old request; the snapshot is removed only afterwards.
    private func resolveRecoveryListQuestion(rowID: String, choice: AgentRecoveryHeldComposerChoice) async -> String? {
        let ids = rowID.dropFirst("question-".count)
        guard ids.count == 73,
              let sessionID = UUID(uuidString: String(ids.prefix(36))),
              let interactionID = UUID(uuidString: String(ids.suffix(36)))
        else { return "This question is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to use this question."
        }
        let questions: [AgentRecoveryQuestionSnapshot]
        switch await lane.readRecord() {
        case let .failure(failure):
            return "The saved question couldn't be read (\(failure)). Nothing was changed."
        case let .success(state):
            switch state {
            case .preserved:
                return "The saved question data is unreadable and is kept unchanged."
            case .absent:
                return nil
            case let .supported(record):
                questions = record.questions
            }
        }
        guard let snapshot = questions.first(where: { $0.interactionID == interactionID }) else { return nil }
        if choice == .restoreToComposer {
            guard session.recoveryLane === lane, !lane.isRetired,
                  recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)?.isEmpty == true
            else {
                return "Clear the message box first. Your current text and this question are both kept."
            }
            applyRecoveredComposer(AgentRecoveryInputContent(text: snapshot.composerText), lane: lane, to: session)
            recoveryComposerDidMutate(session: session)
            if case let .failed(failure) = await lane.flushComposer() {
                return "The question was copied into the message box but couldn't be saved (\(Self.recoveryListDescription(of: failure))). It is still listed here."
            }
        }
        if case let .failure(failure) = await lane.updateQuestionSnapshots(.init(removing: [interactionID])) {
            return "The question couldn't be removed from this list (\(Self.recoveryListDescription(of: failure)))."
        }
        return nil
    }

    private static func recoveryListDraftFailureText(_ failure: AgentRecoveryControllerFailure) -> String {
        switch failure {
        case .liveComposerHasUnsavedContent:
            "Clear the message box first. Your current text and this draft are both kept."
        case .composerChangedDuringRestore:
            "The message box changed while restoring, so the draft was kept as it was. Your current text and this draft are both kept."
        case .heldInputChanged, .noHeldComposer:
            "This draft changed. Review it again."
        default:
            "The draft couldn't be updated (\(recoveryListDescription(of: failure))). Nothing was discarded."
        }
    }

    /// Retry save (write failure), retry load (restore failure), or restart preparation.
    private func retryRecoveryListSave(rowID: String) async -> String? {
        if let tabIDString = rowID.hasPrefix("draft-prep-") ? String(rowID.dropFirst("draft-prep-".count)) : nil {
            guard let tabID = UUID(uuidString: tabIDString), let session = sessions[tabID] else {
                return "This tab is no longer open."
            }
            recoveryComposerDidMutate(session: session)
            return nil
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "restorefail") {
            guard let session = recoveryListTabSession(sessionID: sessionID) else { return "This session is no longer open here." }
            if case let .failed(failure) = await retryRecoveryComposerRestore(for: session) {
                return "The saved draft still couldn't be loaded (\(Self.recoveryListDescription(of: failure)))."
            }
            return nil
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "savefail") {
            guard let session = recoveryListTabSession(sessionID: sessionID), let lane = session.recoveryLane else {
                return "This session is no longer open here."
            }
            // Re-forward the live composer so its current content is what is written.
            recoveryComposerDidMutate(session: session)
            if case let .failed(failure) = await lane.flushComposer() {
                return "The message box still couldn't be saved (\(Self.recoveryListDescription(of: failure))). Your text is still there."
            }
            return nil
        }
        return nil
    }

    func retryRecoveryStartup() {
        recoveryStartupRetry?()
        refreshRecoveryListUI()
    }

    func refreshRecoveryListUI() {
        for tabID in sessions.keys {
            syncComposerUIState(tabID: tabID)
        }
    }

    /// The session and intent named by an `intent-<session>-<intent>` row (startup results or this
    /// launch's held input).
    private func recoveryListIntentRow(_ rowID: String) -> (sessionID: UUID, intentID: UUID)? {
        let parts = rowID.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "intent", recoveryCoordinator != nil else { return nil }
        // "<session UUID>-<intent UUID>": both are 36 characters.
        let ids = parts[1]
        guard ids.count == 73,
              let sessionID = UUID(uuidString: String(ids.prefix(36))),
              let intentID = UUID(uuidString: String(ids.suffix(36)))
        else { return nil }
        return (sessionID, intentID)
    }

    private func recoveryListSessionID(_ rowID: String) -> UUID? {
        guard let dash = rowID.firstIndex(of: "-") else { return nil }
        return UUID(uuidString: String(rowID[rowID.index(after: dash)...].prefix(36)))
    }

    /// The open session's live lane, revalidated against the row's session and (for startup rows)
    /// the startup lifecycle. The lane's own record read validates everything else.
    private func recoveryListLane(sessionID: UUID) -> (AgentTabSession, AgentRecoverySessionLane)? {
        guard let session = activeSession,
              session.activeAgentSessionID == sessionID,
              let lane = session.recoveryLane,
              !lane.isRetired,
              lane.sessionID == sessionID
        else { return nil }
        if let resolution = recoveryCoordinator?.reconciliation.resolution(for: sessionID),
           let startupBinding = resolution.binding,
           startupBinding.incarnationID != lane.binding.incarnationID
        {
            return nil
        }
        return (session, lane)
    }

    private enum RecoveredIntentLookup {
        /// The record could not be read or is preserved; nothing may be changed.
        case unavailable(String)
        /// The intent no longer needs a decision (already resolved elsewhere).
        case settled
        case current(AgentRecoveryIntent)
    }

    /// The intent as currently recorded (never the startup snapshot) when it still needs a decision.
    private func currentRecoveredIntent(
        _ intentID: UUID,
        lane: AgentRecoverySessionLane
    ) async -> RecoveredIntentLookup {
        switch await lane.readRecord() {
        case let .failure(failure):
            return .unavailable("The saved message couldn't be read (\(failure)). Nothing was changed.")
        case let .success(state):
            switch state {
            case .preserved:
                return .unavailable("The saved message data is unreadable and is kept unchanged.")
            case .absent:
                return .settled
            case let .supported(record):
                guard let intent = record.intent(id: intentID), Self.recoveryListShowsIntent(intent) else { return .settled }
                return .current(intent)
            }
        }
    }

    /// R04: how Edit keeps a carrier's exact pending-handoff association.
    enum RecoveryEditPendingHandoffPlan: Equatable {
        /// The session already holds exactly this payload (same identity and text).
        case reuse
        /// The session holds no payload: restore the snapshot through the session save first.
        case restore
        /// The session holds a different payload: refuse, changing neither.
        case conflict
    }

    static func recoveryEditPendingHandoffPlan(
        _ snapshot: AgentRecoveryPendingHandoffSnapshot,
        session pending: AgentPendingHandoffState
    ) -> RecoveryEditPendingHandoffPlan {
        guard pending.hasPayload else { return .restore }
        return pending.payloadID == snapshot.payloadID && pending.payload == snapshot.payload ? .reuse : .conflict
    }

    /// Edit: moves the held input into this session's empty composer (written durably first), then
    /// withdraws the original. Newer typing is never replaced, and input from another reset
    /// generation is never adopted into the current conversation. Only a withdrawable intent
    /// (`queued`, `failed`) is edited. R04: an intent carrying a pending-handoff snapshot keeps that
    /// exact association — an identical session payload is reused, an absent one is restored and
    /// saved before anything else changes, a conflicting one refuses with nothing changed — and the
    /// pending-handoff join reruns after the withdrawal, so the next explicit send inherits the
    /// prefix once (never pasted into the user's text, never a second bubble).
    private func editRecoveredIntent(rowID: String) async -> String? {
        guard let (sessionID, intentID) = recoveryListIntentRow(rowID) else { return "This message is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to edit its message."
        }
        let intent: AgentRecoveryIntent
        switch await currentRecoveredIntent(intentID, lane: lane) {
        case let .unavailable(message):
            return message
        case .settled:
            return nil
        case let .current(value):
            intent = value
        }
        guard intent.transcriptResetGeneration == lane.binding.transcriptResetGeneration else {
            return "This message was written before the conversation was cleared, so it can't be moved into it. You can still view or remove it."
        }
        guard intent.deliveryState == .queued || intent.deliveryState == .failed else {
            return "This message may already have been delivered, so it can only be viewed or removed."
        }
        func composerIsEmpty() -> Bool {
            session.recoveryLane === lane && !lane.isRetired
                && recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)?.isEmpty == true
        }
        guard composerIsEmpty() else {
            return "Clear the message box first. Your current text and this saved message are both kept."
        }
        if let snapshot = intent.pendingHandoff {
            switch Self.recoveryEditPendingHandoffPlan(snapshot, session: session.pendingHandoff) {
            case .reuse:
                break
            case .conflict:
                return "This message carries earlier conversation history that differs from the history waiting in this session. Nothing was changed."
            case .restore:
                // Restored only while every carrier of this payload provably delivered nothing: a
                // sibling's accepted or uncertain delivery may already have consumed it.
                let recordState = await lane.readRecord()
                let join = Self.pendingHandoffRecoveryJoin(payloadID: snapshot.payloadID, recordState: recordState)
                guard join == .carriedByIntent else {
                    return "The conversation history this message carries may already have been delivered, so it can't be moved into the message box. You can still view or remove it."
                }
                guard composerIsEmpty(), !session.pendingHandoff.hasPayload else {
                    return "The session changed. The original message is still saved here."
                }
                let previous = session.pendingHandoff
                var restored = AgentPendingHandoffState(
                    payload: snapshot.payload,
                    createdAt: snapshot.createdAt?.date,
                    sourceItemID: snapshot.sourceItemID,
                    payloadID: snapshot.payloadID
                )
                // Still carried by the queued intent until it is withdrawn below.
                restored.deliveryHold = .recoveryCarriedByIntent
                session.pendingHandoff = restored
                session.isDirty = true
                guard await saveSession(for: session.tabID) else {
                    if session.pendingHandoff == restored { session.pendingHandoff = previous }
                    return "The conversation history this message carries couldn't be saved. Nothing was changed."
                }
                guard session.pendingHandoff.payloadID == snapshot.payloadID else {
                    return "The session changed. The original message is still saved here."
                }
            }
        }
        guard composerIsEmpty() else {
            return "Clear the message box first. Your current text and this saved message are both kept."
        }
        applyRecoveredComposer(intent.payload, lane: lane, to: session)
        guard let placed = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID),
              placed.text == intent.payload.text,
              placed.images.count == intent.payload.images.count,
              placed.taggedFiles.count == intent.payload.taggedFiles.count
        else {
            return "The saved message couldn't be placed into the message box (an attachment is missing). It is still saved here."
        }
        // The composer is written under this lane before the original is withdrawn.
        recoveryComposerDidMutate(session: session)
        if case let .failed(failure) = await lane.flushComposer() {
            return "The message box couldn't be saved (\(failure)). The original message is still saved here."
        }
        guard session.recoveryLane === lane, !lane.isRetired else {
            return "The session changed. The original message is still saved here."
        }
        if case let .failure(failure) = await lane.withdraw(intentID: intentID) {
            return "The message was moved into the message box, but the original couldn't be removed (\(failure))."
        }
        await awaitPendingHandoffRecoveryJoin(for: session)
        return nil
    }

    /// Remove: commits the withdrawal before the row disappears. Accepted evidence is never erased
    /// (the store refuses withdrawal after acceptance or during a possible handoff).
    private func removeRecoveredIntent(rowID: String) async -> String? {
        guard let (sessionID, intentID) = recoveryListIntentRow(rowID) else { return "This message is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to remove its message."
        }
        switch await currentRecoveredIntent(intentID, lane: lane) {
        case let .unavailable(message):
            return message
        case .settled:
            return nil
        case .current:
            break
        }
        if case let .failure(failure) = await lane.withdraw(intentID: intentID) {
            return "The message couldn't be removed (\(failure)). It is still saved."
        }
        // A withdrawn carrier no longer reserves its pending-handoff payload.
        if session.recoveryLane === lane {
            await awaitPendingHandoffRecoveryJoin(for: session)
        }
        return nil
    }

    /// R10 "Cancel pending schedule": opens the session when needed, then cancels its held transfer
    /// through its owner (decision committed, then the exact schedule cleared). The linked message's
    /// own uncertain delivery stays presented; nothing is resent.
    private func cancelRecoveryScheduleTransfer(rowID: String) async -> String? {
        guard recoveryCoordinator != nil, let sessionID = recoveryListSessionID(rowID) else { return nil }
        if recoveryListTabSession(sessionID: sessionID) == nil, let failure = await openRecoveryListSession(rowID: rowID) {
            return failure
        }
        guard let session = recoveryListTabSession(sessionID: sessionID) else {
            return "Open this session to cancel its pending schedule."
        }
        return await cancelHeldScheduledSendTransfer(session: session, sessionID: sessionID)
    }

    /// "It stopped": durably acknowledges exactly the displayed hold through the session's lane (F-2),
    /// opening the session first when no lane is live. The row stays until the commit succeeds.
    private func confirmRecoveryCrashHold(rowID: String) async -> String? {
        guard let coordinator = recoveryCoordinator,
              let sessionID = recoveryListSessionID(rowID),
              let hold = coordinator.crashHold(for: sessionID)
        else { return nil }
        if coordinator.lane(for: sessionID) == nil, let failure = await openRecoveryListSession(rowID: rowID) {
            return failure
        }
        guard let lane = coordinator.lane(for: sessionID), !lane.isRetired else {
            return "Open this session to confirm the previous run has stopped."
        }
        return await coordinator.confirmCrashHold(hold, lane: lane)
            ? nil
            : "The confirmation couldn't be saved, or the session's status changed. Review it again."
    }

    /// Opens the row's session tab (switch or unstash) without starting anything.
    private func openRecoveryListSession(rowID: String) async -> String? {
        guard let coordinator = recoveryCoordinator,
              let sessionID = recoveryListSessionID(rowID),
              let tabID = coordinator.reconciliation.resolution(for: sessionID)?.composeTabID,
              let promptManager
        else { return "This session can't be opened from here. Open it from the sidebar." }
        if promptManager.currentComposeTabs.contains(where: { $0.id == tabID }) {
            await promptManager.switchComposeTab(tabID)
        } else if promptManager.currentStashedTabs.contains(where: { $0.id == tabID }) {
            await promptManager.unstashTab(tabID)
        } else {
            return "This session can't be opened from here. Open it from the sidebar."
        }
        _ = await ensureHydrated(tabID: tabID)
        return nil
    }
}
