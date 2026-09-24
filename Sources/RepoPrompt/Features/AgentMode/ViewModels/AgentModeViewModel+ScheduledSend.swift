import Combine
import Foundation

// MARK: - VM ↔ UI contract (Agent Mode scheduled sends, plan §3.3/§3.4)

//
// UI entry points (all `@MainActor`, called from `AgentInputBar` through `AgentScheduledSendActions`):
//   • `executeComposerScheduleAttempt(text:notBefore:runAlongsideOtherSessions:claim:)`
//       → `.scheduled(id:)` after the record is durably saved, otherwise `.blocked(message:)`.
//   • `updateScheduledSend(tabID:scheduleID:text:notBefore:runAlongsideOtherSessions:)`
//   • `cancelScheduledSend(tabID:scheduleID:)`
//   • `sendScheduledSendNow(tabID:scheduleID:runAlongsideOtherSessions:)`
//   • `discardUnreadableScheduledSend(tabID:)`
//       → `nil` on success, otherwise a user-facing message.
// Props inputs: `TabSession.scheduledSend`, `scheduledSendPendingFinalization`,
// `scheduledSendBusyState(tabID:)`, `canScheduleSend(tabID:session:)`,
// `scheduleTargetIsNewSessionStart(tabID:session:)`.
// Message marker: `AgentChatItem.scheduledSend` is stamped only after provider acceptance
// (`startAgentRun` outcome `.sent` / `.queuedFallback`), so a non-nil provenance always means "Sent".
//
// Persistence rules: the ordinary session save never mutates the on-disk schedule members of an
// existing file. Every schedule change goes through `AgentSessionDataService.mutateScheduledSend`
// (CAS on `updatedAt`). Complete schedule actions are serialized per session
// (`runScheduledSendAction`) so reads, writes, rollbacks, and attachment cleanup of one action
// never interleave with another.
//
// Acceptance ownership (plan P1.3): before the guarded provider handoff the view model captures a
// DataService-issued recovery context (pinned file/folder, deletion generation, canonical
// snapshot) and the coordinator reserves process ownership inside the final gate
// (`authorizeProviderHandoff`). On acceptance the immutable payload (attempt, receipt, stamped
// item, context) is transferred synchronously (`reportAcceptance`); the coordinator's single
// bounded worker owns the durable commit (`finalizeScheduledSend(recovery:)`), including
// reconstruction after accidental file loss and settlement after explicit deletion. This view
// model only projects the coordinator's status (`scheduledSendPendingFinalization`), adopts the
// file on terminal states, and forwards the persistence-only "Retry saving" action. It never
// retries persistence, restores `.dispatching`, or re-drives the provider for an accepted attempt.

typealias ScheduledDispatchRunStarter = @MainActor (
    _ tabID: UUID,
    _ providerText: String,
    _ attachments: [AgentImageAttachment],
    _ taggedFileAttachments: [AgentTaggedFileAttachment]
) async -> CodexAgentModeCoordinator.NativeSendOutcome?

extension Notification.Name {
    /// Posted after this process durably committed a schedule mutation or finalization.
    /// `userInfo["sessionID"]` is the `AgentSession.id`; `userInfo["windowID"]` the poster.
    static let agentScheduledSendDidCommit = Notification.Name("AgentModeViewModel.agentScheduledSendDidCommit")
}

/// Shared timing rules for the composer control and the banner editors.
enum AgentScheduledSendTiming {
    static let step: TimeInterval = 15 * 60
    static let maxDelay: TimeInterval = 24 * 60 * 60
    static let quickPickOffsets: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]
    static let customStepCountRange = 1 ... Int(maxDelay / step)
    /// Tolerance for edits made a few seconds before the picked time elapses.
    static let pastGraceInterval: TimeInterval = 60

    static func customDelay(stepCount: Int) -> TimeInterval {
        let clampedStepCount = min(
            max(stepCount, customStepCountRange.lowerBound),
            customStepCountRange.upperBound
        )
        return TimeInterval(clampedStepCount) * step
    }

    static func customDelayMinutes(stepCount: Int) -> Int {
        Int(customDelay(stepCount: stepCount) / 60)
    }

    static func customNotBefore(stepCount: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(customDelay(stepCount: stepCount))
    }

    static func editorRange(originalNotBefore: Date, now: Date = Date()) -> ClosedRange<Date> {
        min(originalNotBefore, now) ... max(originalNotBefore, now.addingTimeInterval(maxDelay))
    }

    static func validationMessage(for notBefore: Date, now: Date = Date()) -> String? {
        if notBefore < now.addingTimeInterval(-pastGraceInterval) {
            return "Choose a time in the future for the scheduled message."
        }
        if notBefore > now.addingTimeInterval(maxDelay) {
            return "Scheduled messages can be delayed by at most 24 hours."
        }
        return nil
    }
}

extension AgentModeViewModel {
    // MARK: - Coordinator attachment and triggers

    func attachScheduledSendCoordinator(_ coordinator: AgentScheduledSendCoordinator) {
        if let scheduledSendCoordinator, scheduledSendCoordinator === coordinator,
           scheduledSendHostRegistrationID != nil
        {
            return
        }
        detachScheduledSendCoordinator()
        scheduledSendCoordinator = coordinator
        scheduledSendHostRegistrationID = coordinator.register(self)
        scheduledSendCommitObserver = NotificationCenter.default.publisher(for: .agentScheduledSendDidCommit)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let sessionID = notification.userInfo?["sessionID"] as? UUID
                else { return }
                // A process-owned commit has no window identity; every matching host refreshes.
                let posterWindowID = notification.userInfo?["windowID"] as? Int
                handleForeignScheduledSendCommit(sessionID: sessionID, posterWindowID: posterWindowID)
            }
        scheduledSendRecoveryObserver = NotificationCenter.default.publisher(for: .agentScheduledSendRecoveryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let sessionID = notification.userInfo?["sessionID"] as? UUID
                else { return }
                let kind = (notification.userInfo?["changeKind"] as? String)
                    .flatMap(AgentScheduledSendRecoveryChangeKind.init(rawValue:))
                switch kind {
                case .committed?, .explicitlyDeleted?:
                    // Durable terminal state written by the process worker (no window identity):
                    // every host projecting this session adopts the file.
                    handleForeignScheduledSendCommit(sessionID: sessionID, posterWindowID: nil)
                case .reserved?, .accepted?, .saving?, .waitingToRetry?, .needsAttention?, .released?, nil:
                    guard let session = sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) else { return }
                    reconcileScheduledSendRecoveryProjection(for: session)
                }
            }
        scheduledSendPendingConfirmationObserver = NotificationCenter.default.publisher(for: .agentScheduledSendPendingConfirmationDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
                for session in sessions.values where session.activeAgentSessionID == sessionID {
                    syncComposerUIState(tabID: session.tabID)
                }
            }
        scheduledSendDeletionObserver = NotificationCenter.default.publisher(for: .agentSessionDeletionDidCommit)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
                // Explicit deletion committed under the persistence gate invalidates every peer
                // projection of that durable session; no schedule writer may recreate the file.
                for session in sessions.values where session.activeAgentSessionID == sessionID {
                    handleDurableSessionDeleted(session, sessionID: sessionID)
                }
            }
        // Presentation of process-retained attempts is rebuilt from coordinator-owned values.
        for session in sessions.values {
            adoptScheduledSendRecoveryProjection(for: session)
        }
    }

    func detachScheduledSendCoordinator() {
        if let scheduledSendCoordinator, let scheduledSendHostRegistrationID {
            scheduledSendCoordinator.unregister(registrationID: scheduledSendHostRegistrationID)
        }
        scheduledSendHostRegistrationID = nil
        scheduledSendCoordinator = nil
        scheduledSendCommitObserver?.cancel()
        scheduledSendCommitObserver = nil
        scheduledSendRecoveryObserver?.cancel()
        scheduledSendRecoveryObserver = nil
        scheduledSendDeletionObserver?.cancel()
        scheduledSendDeletionObserver = nil
        scheduledSendPendingConfirmationObserver?.cancel()
        scheduledSendPendingConfirmationObserver = nil
    }

    func notifyScheduledSendRunStateChanged(for session: TabSession) {
        guard let coordinator = scheduledSendCoordinator,
              let sessionID = session.activeAgentSessionID
        else { return }
        // Terminal publications may clear `runID` around the state change; the last observed run
        // identity is the evidence the coordinator matches against its captured run.
        let runID = session.runID ?? (session.runState.isActive ? nil : session.lastObservedRunID)
        coordinator.runStateDidChange(
            sessionID: sessionID,
            runID: runID,
            state: session.runState
        )
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [session.tabID])
    }

    func notifyScheduledSendHydrationCompleted(for session: TabSession) {
        scheduledSendCoordinator?.recordDidChange()
        reconcileScheduledSendRecoveryProjection(for: session)
    }

    /// Change-detected busy trigger: any busy-to-idle boundary (run bookkeeping, queue drain,
    /// reservation release, composer claim release) re-evaluates the coordinator.
    func notifyScheduledSendBusyStateMayHaveChanged(tabIDs: Set<UUID>) {
        guard let coordinator = scheduledSendCoordinator else { return }
        var changed = false
        for tabID in tabIDs {
            guard let session = sessions[tabID] else { continue }
            let state = scheduledSendBusyState(tabID: tabID)
            if session.lastReportedScheduledSendBusyState != state {
                session.lastReportedScheduledSendBusyState = state
                changed = true
            }
        }
        if changed {
            coordinator.recordDidChange()
        }
    }

    private func notifyScheduledSendRecordChanged() {
        scheduledSendCoordinator?.recordDidChange()
    }

    private func postScheduledSendCommitNotification(sessionID: UUID) {
        NotificationCenter.default.post(
            name: .agentScheduledSendDidCommit,
            object: nil,
            userInfo: ["sessionID": sessionID, "windowID": scheduledSendWindowID]
        )
    }

    private func handleForeignScheduledSendCommit(sessionID: UUID, posterWindowID: Int?) {
        if let posterWindowID, posterWindowID == scheduledSendWindowID { return }
        if let session = sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) {
            if session.scheduledSendPendingFinalization != nil {
                reconcileScheduledSendRecoveryProjection(for: session)
            } else {
                refreshScheduledSendProjection(for: session)
            }
        } else if ownerValidatedSessionIndex[sessionID] != nil {
            // Index-only placeholder: refresh its discovery summary from the authoritative file.
            Task { @MainActor [weak self] in
                await self?.refreshIndexScheduledSendSummaryFromDisk(sessionID: sessionID)
            }
        }
    }

    /// Re-projects a session after another writer committed: hydrated sessions resync from disk,
    /// unhydrated ones hydrate (which installs the authoritative record). Never touches a
    /// session that owns a live attempt.
    private func refreshScheduledSendProjection(for session: TabSession) {
        guard !session.ownsLiveScheduledAttempt else { return }
        if session.hasLoadedPersistedState {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await runScheduledSendAction(on: session) {
                    _ = await self.resyncScheduledSendFromDisk(session: session)
                }
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await ensureHydrated(tabID: session.tabID)
                scheduledSendCoordinator?.recordDidChange()
            }
        }
    }

    private func refreshIndexScheduledSendSummaryFromDisk(sessionID: UUID) async {
        guard let workspace = persistenceWorkspace,
              let owner = sessionIndexStore.sessionIndexOwner,
              owner.workspaceID == workspace.id,
              sessionIndexStore.isOwnerCurrent(owner),
              ownerValidatedSessionIndex[sessionID] != nil
        else { return }
        let storagePath = workspace.customStoragePath
        // The index-only refresh needs header fields, not a full transcript decode.
        guard let record = try? await dataService.metadataRecordForSessionID(sessionID, for: workspace),
              record.id == sessionID,
              sessionIndexStore.isOwnerCurrent(owner),
              persistenceWorkspace?.id == workspace.id,
              persistenceWorkspace?.customStoragePath == storagePath,
              var entry = ownerValidatedSessionIndex[sessionID]
        else { return }
        guard entry.scheduledSendSummary != record.scheduledSendSummary
            || entry.lastScheduledDispatch != record.lastScheduledDispatch
        else { return }
        entry.scheduledSendSummary = record.scheduledSendSummary
        entry.lastScheduledDispatch = record.lastScheduledDispatch
        applyLocalSessionIndexUpsert(entry)
        scheduledSendCoordinator?.recordDidChange()
    }

    // MARK: - Action serialization

    /// Runs one complete schedule action for `session` after every earlier action finished.
    func runScheduledSendAction<T>(
        on session: TabSession,
        _ body: @escaping @MainActor () async -> T
    ) async -> T {
        let previous = session.scheduledSendActionTask
        let box = ScheduledSendActionResultBox<T>()
        let task = Task<Void, Never> { @MainActor in
            _ = await previous?.value
            box.value = await body()
        }
        session.scheduledSendActionTask = task
        await task.value
        if session.scheduledSendActionTask == task {
            session.scheduledSendActionTask = nil
        }
        return box.value!
    }

    // MARK: - Composer scheduling

    /// Whether the composer may schedule for this tab (local, unscheduled, not MCP-controlled).
    func canScheduleSend(tabID: UUID?, session: TabSession?) -> Bool {
        guard let tabID else { return false }
        if let session {
            guard session.remoteHost == nil,
                  session.staleResetRecovery == nil,
                  session.scheduledSend == nil,
                  session.scheduledSendPendingFinalization == nil,
                  session.mcpControlContext == nil
            else { return false }
        }
        return !isMCPControlled(tabID: tabID) && !workspaceSwitchInFlight
    }

    /// Semantic "first prompt" predicate shared by the composer control and the schedule
    /// implementation: a tab without a linked session, or a linked session that never carried a
    /// turn, schedules a workspace-gated new-session start (plan §1 item 4).
    func scheduleTargetIsNewSessionStart(tabID: UUID?, session: TabSession?) -> Bool {
        guard let tabID else { return false }
        guard hasLinkedAgentSession(for: tabID) else { return true }
        guard let session else { return false }
        return Self.sessionIsUntouchedForScheduling(session)
    }

    static func sessionIsUntouchedForScheduling(_ session: TabSession) -> Bool {
        session.items.isEmpty
            && session.transcript.turns.isEmpty
            && !session.hasSentFirstMessage
            && session.providerSessionID == nil
            && !session.runState.isActive
            && session.runID == nil
    }

    /// Schedules the composer draft instead of sending it. Mirrors `executeComposerSubmitAttempt`
    /// routing (existing session or fresh destination tab), including initial worktree preparation,
    /// but never touches the send paths.
    @discardableResult
    func executeComposerScheduleAttempt(
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        claim: AgentComposerSubmitClaim
    ) async -> UserTurnSubmissionResult {
        await executeComposerScheduleAttempt(
            text: text,
            notBefore: notBefore,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            claim: claim,
            createAndActivateSessionTab: { [weak self] in
                await self?.createAndActivateSessionTab()
            }
        )
    }

    @discardableResult
    func executeComposerScheduleAttempt(
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        claim: AgentComposerSubmitClaim,
        createAndActivateSessionTab: () async -> UUID?
    ) async -> UserTurnSubmissionResult {
        let target = claim.attempt.target
        let sourceSession = claim.sourceSession
        guard composerSubmitClaimIsCurrent(claim) else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        defer {
            releaseComposerSubmitClaim(claim)
        }
        if let timingMessage = AgentScheduledSendTiming.validationMessage(for: notBefore) {
            return .blocked(message: timingMessage)
        }

        switch target.route {
        case .existingAgentSession:
            guard let preparedSession = try? await ensureSessionReady(tabID: target.tabID) else {
                return .blocked(message: Self.composeTabRemovalInProgressMessage)
            }
            guard preparedSession === sourceSession,
                  composerSubmitClaimIsCurrent(claim)
            else {
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let blockedMessage = newWorkBlockedMessage(for: preparedSession) {
                return .blocked(message: blockedMessage)
            }
            if let rejectionReason = submitTargetRejectionReason(
                target,
                session: preparedSession,
                validateSubmissionToken: false
            ) {
                logRejectedSubmitTarget(target, session: preparedSession, reason: rejectionReason)
                resyncAfterRejectedSubmitTarget(target)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            let pendingState = Self.pendingUserTurnState(from: preparedSession)
            if let initialLocation = target.expectedInitialStartLocation,
               initialLocation != .local,
               pendingState.initialStartLocation == initialLocation
            {
                let sourceSnapshot = FirstSendSourceSnapshot(
                    session: preparedSession,
                    fallbackSelectedAgent: selectedAgent,
                    fallbackSelectedModelRaw: selectedModelRaw,
                    fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                    fallbackAutoEditEnabled: autoEditEnabled
                )
                preparedSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: target.tabID)
                syncStatusPillsUIState()
                defer {
                    preparedSession.isPreparingInitialWorktree = false
                    if target.tabID == currentTabID {
                        syncComposerUIState(tabID: target.tabID)
                        syncStatusPillsUIState()
                    }
                }
                if let blocked = preflightInitialUserTurn(text: text, session: preparedSession) {
                    return blocked
                }
                do {
                    try await prepareInitialExecutionLocation(initialLocation, for: preparedSession) {
                        !Task.isCancelled
                            && self.composerSubmitClaimIsCurrent(claim)
                            && self.sessions[target.tabID] === preparedSession
                            && sourceSnapshot.matches(self.sessions[target.tabID])
                            && Self.pendingUserTurnState(from: preparedSession) == pendingState
                    }
                } catch {
                    return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                guard !Task.isCancelled,
                      composerSubmitClaimIsCurrent(claim),
                      sessions[target.tabID] === preparedSession,
                      sourceSnapshot.matches(sessions[target.tabID]),
                      Self.pendingUserTurnState(from: preparedSession) == pendingState
                else {
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
                preparedSession.pendingInitialStartLocation = .local
                if target.tabID == currentTabID {
                    applySessionToBindings(preparedSession)
                }
            } else {
                guard preparedSession.pendingInitialStartLocation == .local else {
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
            }
            let isNewSessionStart = Self.sessionIsUntouchedForScheduling(preparedSession)
            switch await installScheduledSend(
                text: text,
                on: preparedSession,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: isNewSessionStart
            ) {
            case let .success(scheduleID):
                clearComposerDraftIfUnchanged(for: claim)
                return .scheduled(id: scheduleID)
            case let .failure(failure):
                return .blocked(message: failure.message)
            }

        case .createAgentSessionFromSourceTab:
            let pendingState = Self.pendingUserTurnState(from: sourceSession)
            guard pendingState.remoteHost == nil else {
                return .blocked(message: Self.scheduledSendRemoteUnsupportedMessage)
            }
            let sourceSnapshot = FirstSendSourceSnapshot(
                session: sourceSession,
                fallbackSelectedAgent: selectedAgent,
                fallbackSelectedModelRaw: selectedModelRaw,
                fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                fallbackAutoEditEnabled: autoEditEnabled
            )
            let preparesExecutionLocation = pendingState.initialStartLocation != .local
            if preparesExecutionLocation {
                sourceSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: target.tabID)
                syncStatusPillsUIState()
            }
            defer {
                if preparesExecutionLocation {
                    sourceSession.isPreparingInitialWorktree = false
                    if target.tabID == currentTabID {
                        syncComposerUIState(tabID: target.tabID)
                        syncStatusPillsUIState()
                    }
                }
            }
            guard let destinationTabID = await createAndActivateSessionTab() else {
                return .blocked(message: "Failed to create a new agent session.")
            }
            guard !Task.isCancelled,
                  composerSubmitClaimIsCurrent(claim),
                  sessions[target.tabID] === sourceSession,
                  sourceSnapshot.matches(sessions[target.tabID]),
                  destinationTabID != target.tabID
            else {
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard let destinationSession = session(for: destinationTabID, createIfNeeded: true),
                  isFreshFirstSendDestination(destinationSession)
            else {
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: "Failed to create a new agent session.")
            }
            if preparesExecutionLocation {
                destinationSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: destinationTabID)
            }
            defer {
                if preparesExecutionLocation {
                    destinationSession.isPreparingInitialWorktree = false
                    if destinationTabID == currentTabID {
                        syncComposerUIState(tabID: destinationTabID)
                    }
                }
            }
            sourceSnapshot.applySessionSettings(to: destinationSession)
            installPendingUserTurnState(pendingState, on: destinationSession)
            if let blocked = preflightInitialUserTurn(text: text, session: destinationSession) {
                clearPendingUserTurnState(on: destinationSession)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return blocked
            }
            if preparesExecutionLocation {
                do {
                    try await prepareInitialExecutionLocation(pendingState.initialStartLocation, for: destinationSession) {
                        !Task.isCancelled
                            && self.composerSubmitClaimIsCurrent(claim)
                            && self.sessions[destinationTabID] === destinationSession
                            && self.sessions[target.tabID] === sourceSession
                            && sourceSnapshot.matches(self.sessions[target.tabID])
                            && Self.pendingUserTurnState(from: destinationSession) == pendingState
                    }
                } catch {
                    clearPendingUserTurnState(on: destinationSession)
                    await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                    return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                guard !Task.isCancelled,
                      composerSubmitClaimIsCurrent(claim),
                      sessions[destinationTabID] === destinationSession,
                      sessions[target.tabID] === sourceSession,
                      sourceSnapshot.matches(sessions[target.tabID]),
                      Self.pendingUserTurnState(from: destinationSession) == pendingState
                else {
                    clearPendingUserTurnState(on: destinationSession)
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
            }
            destinationSession.pendingInitialStartLocation = .local
            switch await installScheduledSend(
                text: text,
                on: destinationSession,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: true
            ) {
            case let .success(scheduleID):
                // The destination now owns the attachments and workflow; the source tab keeps
                // its (now sessionless) composer state cleared exactly like a first send.
                clearPendingUserTurnState(on: sourceSession)
                clearComposerDraftIfUnchanged(for: claim)
                if destinationTabID == currentTabID {
                    applySessionToBindings(destinationSession)
                }
                return .scheduled(id: scheduleID)
            case let .failure(failure):
                clearPendingUserTurnState(on: destinationSession)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: failure.message)
            }
        }
    }

    struct ScheduledSendInstallFailure: Error, Equatable {
        let message: String
    }

    /// Freezes the session's pending composer state (text, attachments, workflow, interview
    /// flag) into a new scheduled-send record and saves it durably before reporting success.
    /// On failure the pending state is restored untouched so the draft is never lost. Runs as a
    /// serialized schedule action; banner actions queued behind it observe the committed result.
    func installScheduledSend(
        text: String,
        on session: TabSession,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        isNewSessionStart: Bool
    ) async -> Result<UUID, ScheduledSendInstallFailure> {
        await runScheduledSendAction(on: session) { [self] in
            await performInstallScheduledSend(
                text: text,
                on: session,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: isNewSessionStart
            )
        }
    }

    private func performInstallScheduledSend(
        text: String,
        on session: TabSession,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        isNewSessionStart: Bool
    ) async -> Result<UUID, ScheduledSendInstallFailure> {
        let tabID = session.tabID
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.remoteHost == nil else {
            return .failure(.init(message: Self.scheduledSendRemoteUnsupportedMessage))
        }
        if let blockedMessage = newWorkBlockedMessage(for: session) {
            return .failure(.init(message: blockedMessage))
        }
        guard session.mcpControlContext == nil, !isMCPControlled(tabID: tabID) else {
            return .failure(.init(message: "This session is controlled by an MCP client and can't schedule messages."))
        }
        guard session.scheduledSend == nil, session.scheduledSendPendingFinalization == nil else {
            return .failure(.init(message: "This session already has a scheduled message. Edit or cancel it first."))
        }
        guard let workspaceID = persistenceWorkspace?.id else {
            return .failure(.init(message: "Open a workspace before scheduling a message."))
        }
        if let blocked = preflightInitialUserTurn(text: trimmedText, session: session),
           case let .blocked(message) = blocked
        {
            return .failure(.init(message: message.isEmpty ? "Type a message or add an attachment before scheduling." : message))
        }
        guard resolvedNativeSlashCommand(in: trimmedText, session: session) == nil else {
            return .failure(.init(message: "Native slash commands can't be scheduled. Send them directly instead."))
        }

        let attachments = session.pendingImageAttachments
        let taggedFiles = session.pendingTaggedFileAttachments
        let selectedWorkflowSnapshot = session.selectedWorkflow
        let bubbleWorkflow: AgentWorkflowDefinition? = if let selectedWorkflowSnapshot {
            selectedWorkflowSnapshot
        } else {
            resolvedSlashSkillInvocations(in: trimmedText).first?.definition.asBubbleWorkflowDefinition()
        }
        let consumesInterviewFirst = interviewFirst && Self.sessionQualifiesForInterviewFirst(session)
        let now = Date()
        let record = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            notBefore: notBefore,
            state: .scheduled,
            confirmationReason: nil,
            rawText: trimmedText,
            attachments: attachments,
            taggedFileAttachments: taggedFiles,
            workflow: bubbleWorkflow,
            interviewFirst: consumesInterviewFirst,
            isNewSessionStart: isNewSessionStart,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )

        // Move (never copy) the pending composer state into the record.
        session.pendingImageAttachments.removeAll()
        session.pendingTaggedFileAttachments.removeAll()
        session.selectedWorkflow = nil
        if tabID == currentTabID {
            selectedWorkflow = nil
        }
        if consumesInterviewFirst {
            interviewFirst = false
        }
        session.scheduledSend = .v1(record)
        session.scheduledSendWorkspaceID = workspaceID
        session.isDirty = true
        updateBindingsFromSession(session)
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()

        let persisted = await commitScheduledSend(
            session: session,
            member: .v1(record),
            expectedUpdatedAt: session.scheduledSendPersistedUpdatedAt
        )
        guard persisted else {
            // Rollback is owned by this action: restore the exact frozen state; never touch files.
            if session.pendingScheduledSendRecord?.id == record.id {
                session.scheduledSend = nil
                session.scheduledSendWorkspaceID = nil
            }
            session.pendingImageAttachments = attachments
            session.pendingTaggedFileAttachments = taggedFiles
            session.selectedWorkflow = selectedWorkflowSnapshot
            if tabID == currentTabID {
                selectedWorkflow = selectedWorkflowSnapshot
            }
            if consumesInterviewFirst {
                interviewFirst = true
            }
            updateBindingsFromSession(session)
            syncComposerUIState(tabID: tabID)
            syncStatusPillsUIState()
            return .failure(.init(message: "The scheduled message could not be saved. Please try again."))
        }
        if isNewSessionStart,
           AgentSessionTitleNaming.isDefaultSessionTitle(resolvedSessionDisplayName(for: tabID)),
           let derivedName = AgentSessionTitleNaming.derivedSessionName(from: trimmedText)
        {
            renameSession(tabID: tabID, to: derivedName)
        }
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncSidebarUIState(refresh: true, reason: .sessionIndex)
        notifyScheduledSendRecordChanged()
        return .success(record.id)
    }

    static let scheduledSendRemoteUnsupportedMessage =
        "Scheduled messages aren't available for remote-host sessions yet."

    // MARK: - Banner actions

    func updateScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        removingImageAttachmentIDs: Set<UUID> = [],
        removingTaggedFileAttachmentIDs: Set<UUID> = []
    ) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        let token = session.activeAgentSessionID.flatMap { sessionID in
            scheduledSendCoordinator?.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        }
        defer { if let token { scheduledSendCoordinator?.releaseUserSupersession(token) } }
        return await runScheduledSendAction(on: session) { [self] in
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let retainedAttachments = record.attachments.filter {
                !removingImageAttachmentIDs.contains($0.id)
            }
            let retainedTaggedFiles = record.taggedFileAttachments.filter {
                !removingTaggedFileAttachmentIDs.contains($0.id)
            }
            guard !trimmedText.isEmpty || !retainedAttachments.isEmpty || !retainedTaggedFiles.isEmpty else {
                return "Type a message or keep an attachment before saving the scheduled message."
            }
            if let timingMessage = AgentScheduledSendTiming.validationMessage(for: notBefore) {
                return timingMessage
            }
            guard resolvedNativeSlashCommand(in: trimmedText, session: session) == nil else {
                return "Native slash commands can't be scheduled. Send them directly instead."
            }
            let removedAttachments = record.attachments.filter {
                removingImageAttachmentIDs.contains($0.id)
            }
            var updated = record
            updated.rawText = trimmedText
            updated.attachments = retainedAttachments
            updated.taggedFileAttachments = retainedTaggedFiles
            updated.notBefore = notBefore
            updated.runAlongsideOtherSessions = runAlongsideOtherSessions
            updated.state = .scheduled
            updated.confirmationReason = nil
            updated.lastFailureMessage = nil
            updated.firstEligibleAt = nil
            updated.updatedAt = Date()
            if let message = await commitScheduledSendChange(updated, previous: record, session: session) {
                return message
            }
            clearScheduledSendAttachmentFiles(
                removedAttachments.filter { removed in
                    !retainedAttachments.contains { retained in
                        Self.scheduledAttachmentLocalPath(retained)
                            == Self.scheduledAttachmentLocalPath(removed)
                    }
                }
            )
            if let token,
               scheduledSendCoordinator?.completeUserSupersession(token, committedRevision: session.scheduledSendPersistedUpdatedAt) == false
            {
                // The user's edit is durable, but a newer clock/wake decision still blocks
                // automatic sending until it is confirmed.
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendConfirmationChangedMessage
            }
            return nil
        }
    }

    func cancelScheduledSend(tabID: UUID, scheduleID: UUID) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        let token = session.activeAgentSessionID.flatMap { sessionID in
            scheduledSendCoordinator?.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        }
        defer { if let token { scheduledSendCoordinator?.releaseUserSupersession(token) } }
        return await runScheduledSendAction(on: session) { [self] in
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            let expected = session.scheduledSendPersistedUpdatedAt
            session.scheduledSend = nil
            session.isDirty = true
            syncComposerUIState(tabID: tabID)
            let persisted = await commitScheduledSend(session: session, member: nil, expectedUpdatedAt: expected)
            guard persisted else {
                if session.scheduledSend == nil, session.scheduledSendPersistedUpdatedAt == expected {
                    session.scheduledSend = .v1(record)
                    syncComposerUIState(tabID: tabID)
                }
                return "The scheduled message could not be cancelled. Please try again."
            }
            // This action owned the record; nothing else references these managed files.
            clearScheduledSendAttachmentFiles(record.attachments)
            session.scheduledSendWorkspaceID = nil
            if let token {
                // A cancelled schedule no longer requires confirmation; a newer decision (if any)
                // is retired with the schedule on the next evaluation.
                _ = scheduledSendCoordinator?.completeUserSupersession(token, committedRevision: nil)
            }
            if let itemID = record.attempt?.itemID {
                removeUnsentScheduledUserItem(id: itemID, from: session)
            }
            updateLocalSessionIndexScheduledSendSummary(for: session)
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            notifyScheduledSendRecordChanged()
            return nil
        }
    }

    /// Confirms a pending, needs-confirmation, or failed record and asks the coordinator to
    /// dispatch it as soon as the busy gate allows. The original `notBefore` is kept for the
    /// message marker (plan §6, minor points).
    func sendScheduledSendNow(
        tabID: UUID,
        scheduleID: UUID,
        runAlongsideOtherSessions: Bool
    ) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        guard let coordinator = scheduledSendCoordinator, let sessionID = session.activeAgentSessionID else {
            return "Scheduled sending is unavailable in this window."
        }
        // User supersession of any pending clock/wake confirmation decision: reserved before the
        // serialized action, consumed only after the durable revision is known. Any coordinator
        // write outstanding for this durable session (possibly on another host) is drained
        // first, outside this tab's serializer, and the durable revision is refreshed from disk so
        // consent is never installed for a revision an older write is about to replace.
        let token = coordinator.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        defer { coordinator.releaseUserSupersession(token) }
        await coordinator.drainOutstandingHostMutation(sessionID: sessionID)
        return await runScheduledSendAction(on: session) { [self] in
            guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                return Self.scheduledSendMissingMessage
            }
            await coordinator.drainOutstandingHostMutation(sessionID: sessionID)
            // The durable revision is established, never assumed: consent is installed only for a
            // revision this action verified after the drain. A missing or unreadable file is a
            // retryable refusal (the token is released, the pending decision stays), and a binding
            // that changed across any await ends the action without claiming success.
            let resync = await resyncScheduledSendFromDisk(session: session)
            guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                return Self.scheduledSendMissingMessage
            }
            switch resync {
            case .adopted:
                break
            case .staleOwner:
                return Self.scheduledSendMissingMessage
            case .fileMissing, .readFailed:
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendVerificationFailedMessage
            }
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            if record.runAlongsideOtherSessions != runAlongsideOtherSessions {
                var updated = record
                updated.runAlongsideOtherSessions = runAlongsideOtherSessions
                updated.updatedAt = Date()
                if let message = await commitScheduledSendChange(updated, previous: record, session: session) {
                    return message
                }
                guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                    return Self.scheduledSendMissingMessage
                }
            }
            // Consent targets exactly the verified projected revision.
            guard let committedRevision = session.scheduledSendPersistedUpdatedAt,
                  let verifiedRecord = session.pendingScheduledSendRecord,
                  verifiedRecord.id == scheduleID,
                  verifiedRecord.updatedAt == committedRevision
            else {
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendVerificationFailedMessage
            }
            guard coordinator.completeUserSupersession(token, committedRevision: committedRevision) else {
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendConfirmationChangedMessage
            }
            coordinator.confirmAndSendNow(
                scheduleID: scheduleID,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                committedRevision: committedRevision
            )
            syncComposerUIState(tabID: tabID)
            return nil
        }
    }

    static let scheduledSendConfirmationChangedMessage =
        "The system clock or wake state changed again. Review the scheduled message and confirm it once more."

    /// Send now could not establish the saved revision it would confirm (missing or unreadable
    /// session file after the drain). Retryable: no consent was installed and nothing was sent.
    static let scheduledSendVerificationFailedMessage =
        "The scheduled message couldn't be verified against the saved session. Please try again."

    /// Discards a persisted scheduled-send member this build cannot read (plan §3.1). The CAS
    /// compares the semantic JSON value so a member replaced by another writer is never dropped.
    func discardUnreadableScheduledSend(tabID: UUID) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        return await runScheduledSendAction(on: session) { [self] in
            guard case let .unreadable(jsonValue)? = session.scheduledSend else {
                return Self.scheduledSendMissingMessage
            }
            guard let workspace = persistenceWorkspace,
                  let sessionID = ensureSessionBoundToTab(session),
                  let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace)
            else {
                return "The scheduled message could not be discarded. Please try again."
            }
            do {
                _ = try await dataService.mutateScheduledSend(
                    sessionID: sessionID,
                    for: workspace,
                    persistenceStamp: persistenceState.stamp,
                    mutation: .discardUnreadable(expected: jsonValue)
                )
            } catch AgentScheduledSendMutationError.staleExpectedScheduledSendMember {
                await resyncScheduledSendFromDisk(session: session)
                return "The scheduled message changed elsewhere. Check the session again."
            } catch AgentScheduledSendMutationError.sessionNotFound {
                // Nothing durable holds the member; dropping it locally is complete.
            } catch {
                return "The scheduled message could not be discarded. Please try again."
            }
            session.scheduledSend = nil
            session.scheduledSendPersistedUpdatedAt = nil
            session.scheduledSendWorkspaceID = nil
            session.isDirty = true
            syncComposerUIState(tabID: tabID)
            updateLocalSessionIndexScheduledSendSummary(for: session)
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            postScheduledSendCommitNotification(sessionID: sessionID)
            notifyScheduledSendRecordChanged()
            return nil
        }
    }

    private static let scheduledSendMissingMessage = "This scheduled message no longer exists."
    private static let scheduledSendDispatchingMessage = "This scheduled message is being sent right now."

    private func commitScheduledSendChange(
        _ updated: AgentScheduledSendPersist,
        previous: AgentScheduledSendPersist,
        session: TabSession
    ) async -> String? {
        let expected = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(updated)
        session.isDirty = true
        syncComposerUIState(tabID: session.tabID)
        let persisted = await commitScheduledSend(session: session, member: .v1(updated), expectedUpdatedAt: expected)
        guard persisted else {
            if session.pendingScheduledSendRecord == updated, session.scheduledSendPersistedUpdatedAt == expected {
                session.scheduledSend = .v1(previous)
                syncComposerUIState(tabID: session.tabID)
            }
            return "The scheduled message could not be saved. Please try again."
        }
        updateLocalSessionIndexScheduledSendSummary(for: session)
        notifyScheduledSendRecordChanged()
        return nil
    }

    // MARK: - Persistence lifetime (captured state)

    /// Returns this tab's captured persistence state for `sessionID`. State enters a tab only
    /// through the paired hydration load (`applyPersistedHydration`), this owner's own commits, or
    /// create-only preparation for a session that has never been persisted. An incarnation that
    /// exists on disk but was not hydrated by this tab is not adoptable here, and a revoked
    /// lifetime is never re-acquired.
    func ensurePersistenceState(
        for session: TabSession,
        sessionID: UUID,
        workspace: WorkspaceModel,
        context: SessionPersistenceContext? = nil
    ) async -> AgentSessionPersistenceState? {
        guard context == nil || (
            context?.workspaceID == workspace.id
                && context.map { self.sessionPersistenceContextIsCurrent($0) } == true
        ) else { return nil }
        if let state = session.persistenceState(for: sessionID), state.stamp.workspaceID == workspace.id {
            return state
        }
        guard session.persistenceRevokedSessionID != sessionID,
              session.persistedIncarnationSessionID != sessionID
        else { return nil }
        #if DEBUG
            if let hook = test_initialPersistencePreparationHook {
                await hook(session)
            }
        #endif
        guard context == nil || context.map({ self.sessionPersistenceContextIsCurrent($0) }) == true else {
            return nil
        }
        let prepared: AgentSessionPersistenceState
        do {
            prepared = try await dataService.prepareInitialAgentSessionPersistence(sessionID: sessionID, for: workspace)
        } catch AgentScheduledSendMutationError.sessionAlreadyExists {
            // Not this tab's incarnation: ownership comes only from a paired hydration load.
            return nil
        } catch {
            print("[AgentModeVM][Persistence] could not prepare initial persistence state: \(error)")
            return nil
        }
        guard context == nil || context.map({ self.sessionPersistenceContextIsCurrent($0) }) == true,
              sessions[session.tabID] === session,
              session.activeAgentSessionID == sessionID,
              session.persistenceRevokedSessionID != sessionID
        else { return nil }
        if let existing = session.persistenceState(for: sessionID) {
            // A concurrent capture already established ownership; never replace it.
            return existing
        }
        session.persistenceState = prepared
        return prepared
    }

    // MARK: - Persistence (CAS)

    /// Commits an immutable desired schedule member for `session` through the data service CAS.
    /// `expectedUpdatedAt` is the on-disk revision this action observed; the first durable write
    /// of a session that has no file yet falls back to a full save (which writes supplied schedule
    /// fields only on creation) and then re-runs the CAS. The persistence target is pinned to the
    /// workspace that owns the schedule.
    @discardableResult
    func commitScheduledSend(
        session: TabSession,
        member: AgentScheduledSendMember?,
        expectedUpdatedAt: Date?,
        completedDispatch: AgentScheduledSendProvenance? = nil
    ) async -> Bool {
        if case .committed = await commitScheduledSendDetailed(
            session: session,
            member: member,
            expectedUpdatedAt: expectedUpdatedAt,
            completedDispatch: completedDispatch
        ) {
            return true
        }
        return false
    }

    /// Precise outcome of one durable schedule commit: the coordinator's acknowledged mutations
    /// distinguish a real commit from conflict, unavailability, deletion, and write failure.
    func commitScheduledSendDetailed(
        session: TabSession,
        member: AgentScheduledSendMember?,
        expectedUpdatedAt: Date?,
        completedDispatch: AgentScheduledSendProvenance? = nil
    ) async -> AgentScheduledSendHostMutationOutcome {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return .committed(committedUpdatedAt: nil) }
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let sessionID = ensureSessionBoundToTab(session)
        else { return .unavailable }

        let mutation: AgentScheduledSendMutation
        switch member {
        case let .v1(record)?:
            mutation = .upsert(expectedUpdatedAt: expectedUpdatedAt, value: record)
        case .unreadable?:
            return .failed("Unreadable scheduled messages cannot be written.")
        case nil:
            guard let expectedUpdatedAt else {
                if let completedDispatch {
                    session.lastScheduledDispatch = completedDispatch
                }
                return .committed(committedUpdatedAt: nil)
            }
            mutation = .clear(expectedUpdatedAt: expectedUpdatedAt, completedDispatch: completedDispatch)
        }

        var attemptedCreation = false
        while true {
            // Prepared creation authority is not a persisted incarnation: until the first full
            // save commits (`persistedIncarnationSessionID`), a schedule CAS never targets the
            // still-missing file, and creation is retried under the same captured stamp.
            if expectedUpdatedAt == nil,
               session.persistedIncarnationSessionID != sessionID,
               session.persistenceRevokedSessionID != sessionID
            {
                // Genuine initial creation: the first full save establishes the incarnation
                // (create-only state) before any schedule CAS targets it.
                guard !attemptedCreation, member != nil else {
                    return .failed("The session file could not be created.")
                }
                attemptedCreation = true
                session.isDirty = true
                // Creation needs durable commitment, not a clean projection: a request that
                // coalesced behind the write only leaves the projection dirty (a fresh save is
                // already requested). The CAS below verifies the exact installed record against
                // the created file, so a durable write is never reported as creation failure.
                let creation = await flushSaveDetailed(for: session.tabID)
                guard creation.didWriteDurably else {
                    return .failed("The session file could not be created.")
                }
                continue
            }
            guard let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace) else {
                return session.persistenceRevokedSessionID == sessionID ? .destinationDeleted : .unavailable
            }
            do {
                let result = try await dataService.mutateScheduledSend(
                    sessionID: sessionID,
                    for: workspace,
                    persistenceStamp: persistenceState.stamp,
                    mutation: mutation
                )
                let committedUpdatedAt = result.session.scheduledSend?.persistedValue?.updatedAt
                session.scheduledSendPersistedUpdatedAt = committedUpdatedAt
                session.lastScheduledDispatch = result.session.lastScheduledDispatch
                if case let .repairNeeded(detail) = result.metadataIndexStatus {
                    // Committed success: the session file is authoritative; the index self-repairs.
                    print("[AgentModeVM][ScheduledSend] metadata index repair needed after commit: \(detail)")
                }
                postScheduledSendCommitNotification(sessionID: sessionID)
                return .committed(committedUpdatedAt: committedUpdatedAt)
            } catch AgentScheduledSendMutationError.staleDeletionGeneration,
                AgentScheduledSendMutationError.invalidPersistenceStamp
            {
                // Committed deletion or a stale lifetime for this exact owner: never recreate the
                // file or refresh the stamp from this tab's state.
                handleDurableSessionDeleted(session, sessionID: sessionID)
                return .destinationDeleted
            } catch AgentScheduledSendMutationError.sessionNotFound {
                // Valid lifetime, file missing: accidental loss, not deletion. Nothing is revoked or
                // recreated here; the retained recovery reconstructs it and the write is retried.
                return .failed("The session file is missing; it will be restored before this change is saved.")
            } catch let AgentScheduledSendMutationError.staleExpectedUpdatedAt(_, actual) {
                if let actual, actual == member?.persistedValue?.updatedAt {
                    // A full save already created the file with this exact record.
                    session.scheduledSendPersistedUpdatedAt = actual
                    if let completedDispatch {
                        session.lastScheduledDispatch = completedDispatch
                    }
                    return .committed(committedUpdatedAt: actual)
                }
                await resyncScheduledSendFromDisk(session: session)
                return .conflict
            } catch AgentScheduledSendMutationError.staleExpectedAttempt,
                AgentScheduledSendMutationError.scheduledSendNotDispatching,
                AgentScheduledSendMutationError.staleExpectedScheduledSendMember
            {
                await resyncScheduledSendFromDisk(session: session)
                return .conflict
            } catch {
                print("[AgentModeVM][ScheduledSend] persistence failed: \(error)")
                return .failed(String(describing: error))
            }
        }
    }

    private func scheduledSendPersistenceWorkspace(for session: TabSession) -> WorkspaceModel? {
        guard let workspace = persistenceWorkspace else { return nil }
        if let pinned = session.scheduledSendWorkspaceID, pinned != workspace.id {
            print("[AgentModeVM][ScheduledSend] refusing to persist schedule for workspace \(pinned) into \(workspace.id)")
            return nil
        }
        return workspace
    }

    /// Result of one authoritative schedule resync. Only `.adopted` establishes a verified
    /// durable revision; every other case leaves the local projection untouched.
    enum ScheduledSendResyncOutcome: Equatable {
        /// The on-disk record was installed on the captured owner at this persisted revision.
        case adopted(persistedUpdatedAt: Date?)
        /// No file exists for the durable session (accidental loss, not deletion evidence).
        case fileMissing
        /// The storage read threw.
        case readFailed
        /// No persistence target, or the captured tab no longer projects this durable session.
        case staleOwner
    }

    /// Another writer (window) changed the persisted schedule: adopt disk as the authority. A
    /// missing file is *not* deletion evidence (committed deletion arrives through the data
    /// service's deletion event or a stale-lifetime error) and leaves projections, ownership, and
    /// any retained recovery untouched; a read error leaves the projection as well. The captured
    /// owner is re-validated after the read, and coordinator-owned recovery is reconciled from the
    /// authoritative record even when no further recovery notification will arrive. The returned
    /// outcome lets callers that must act on a verified revision (Send now) distinguish an
    /// authoritative snapshot from a missing, failed, or stale-owner read.
    @discardableResult
    func resyncScheduledSendFromDisk(session: TabSession) async -> ScheduledSendResyncOutcome {
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let sessionID = session.activeAgentSessionID
        else { return .staleOwner }
        let persisted: AgentSession
        do {
            #if DEBUG
                if let injected = test_scheduledSendResyncReadFailureInjector?(sessionID) {
                    throw injected
                }
            #endif
            guard let loaded = try await dataService.loadAgentSession(id: sessionID, for: workspace) else {
                return .fileMissing
            }
            persisted = loaded
        } catch {
            return .readFailed
        }
        guard sessions[session.tabID] === session, session.activeAgentSessionID == sessionID else { return .staleOwner }
        defer { adoptScheduledSendRecoveryProjection(for: session) }
        session.scheduledSend = persisted.scheduledSend
        session.lastScheduledDispatch = persisted.lastScheduledDispatch
        session.scheduledSendPersistedUpdatedAt = persisted.scheduledSend?.persistedValue?.updatedAt
        if persisted.scheduledSend == nil {
            session.scheduledSendWorkspaceID = nil
        } else if session.scheduledSendWorkspaceID == nil {
            session.scheduledSendWorkspaceID = persisted.workspaceID ?? workspace.id
        }
        reconcileProvenanceForFinalizedItems(in: session, persisted: persisted)
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
        return .adopted(persistedUpdatedAt: session.scheduledSendPersistedUpdatedAt)
    }

    /// A finalization committed elsewhere carries the accepted item's marker; mirror it locally so
    /// a second window never shows an unmarked bubble for a delivered scheduled message.
    private func reconcileProvenanceForFinalizedItems(in session: TabSession, persisted: AgentSession) {
        guard let receipt = persisted.lastScheduledDispatch else { return }
        let stampedIDs = Set(
            (persisted.transcript?.turns ?? []).compactMap { turn -> UUID? in
                guard let request = turn.request, request.scheduledSend == receipt else { return nil }
                return request.id
            }
        )
        for itemID in stampedIDs {
            stampScheduledSendProvenance(receipt, onItemID: itemID, in: session)
        }
    }

    // MARK: - Hydration

    /// Installs persisted schedule state on hydration and normalizes restart cases (plan §3.3).
    /// Items are installed earlier in `applyPersistedHydration` (`hydrateSession(...)`), so the
    /// provenance and duplicate-item checks below observe the hydrated transcript.
    /// A `.dispatching` record whose session holds a live admission in this process (another
    /// window is mid-dispatch) is projected as-is and reconciled from the owner's commit.
    func installHydratedScheduledSend(from agentSession: AgentSession, into session: TabSession) {
        if agentSession.fileURL != nil {
            // Projection of an on-disk incarnation: later saves must not recreate it after
            // deletion. Persistence state itself arrives only with the paired hydration load.
            session.persistedIncarnationSessionID = agentSession.id
        }
        session.lastScheduledDispatch = agentSession.lastScheduledDispatch
        session.scheduledSendPersistedUpdatedAt = agentSession.scheduledSend?.persistedValue?.updatedAt
        session.isScheduledDispatchInFlight = false
        session.scheduledSendWorkspaceID = agentSession.scheduledSend == nil
            ? nil
            : (agentSession.workspaceID ?? persistenceWorkspace?.id)
        guard let member = agentSession.scheduledSend else {
            session.scheduledSend = nil
            return
        }
        guard case let .v1(record) = member else {
            session.scheduledSend = member
            return
        }
        let alreadyDelivered = agentSession.lastScheduledDispatch?.scheduleID == record.id
            || session.items.contains { $0.scheduledSend?.scheduleID == record.id }
        if alreadyDelivered {
            session.scheduledSend = nil
            let expected = record.updatedAt
            Task { @MainActor [weak self] in
                guard let self else { return }
                await runScheduledSendAction(on: session) {
                    _ = await self.commitScheduledSend(session: session, member: nil, expectedUpdatedAt: expected)
                }
            }
            return
        }
        guard record.state == .dispatching else {
            session.scheduledSend = member
            return
        }
        if scheduledSendCoordinator?.activeAdmission(sessionID: agentSession.id) != nil {
            // Live attempt owned by this process: project without normalizing. Once acceptance
            // is retained, this host presents the recovery from coordinator-owned values.
            session.scheduledSend = member
            adoptScheduledSendRecoveryProjection(for: session)
            return
        }
        var normalized = record
        normalized.state = .needsConfirmation
        normalized.confirmationReason = .deliveryUnknown
        normalized.updatedAt = Date()
        let duplicateItemExists = record.attempt.map { attempt in
            session.items.contains { $0.id == attempt.itemID }
        } ?? false
        normalized.lastFailureMessage = duplicateItemExists
            ? "The app closed while this message was being sent and it may already have been delivered. Sending it again could deliver it twice."
            : "The app closed while this message was being sent. Delivery could not be confirmed."
        session.scheduledSend = .v1(normalized)
        let expected = record.updatedAt
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runScheduledSendAction(on: session) {
                guard session.pendingScheduledSendRecord == normalized else { return }
                _ = await self.commitScheduledSend(session: session, member: .v1(normalized), expectedUpdatedAt: expected)
                self.updateLocalSessionIndexScheduledSendSummary(for: session)
            }
        }
    }

    // MARK: - Removal / cleanup

    /// Called before a live session leaves `sessions`. Deleting the persisted session also
    /// abandons the record, so its managed attachment files are removed; stashing keeps both.
    func releaseScheduledSendForRemovedSession(_ session: TabSession, deletesPersistedSession: Bool) {
        // Accepted-but-unfinalized work is process-owned; removing the tab detaches presentation only.
        guard deletesPersistedSession, let record = session.pendingScheduledSendRecord else { return }
        clearScheduledSendAttachmentFiles(record.attachments)
        session.scheduledSend = nil
        session.scheduledSendWorkspaceID = nil
    }

    private func clearScheduledSendAttachmentFiles(_ attachments: [AgentImageAttachment]) {
        guard clearConsumedAttachmentsAfterProviderConsumption,
              !attachments.isEmpty,
              let workspaceDirectory = attachmentWorkspaceDirectoryProvider()?.standardizedFileURL
        else { return }
        attachmentStore.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
    }

    private static func scheduledAttachmentLocalPath(_ attachment: AgentImageAttachment) -> String? {
        guard case let .localFile(path) = attachment.source else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func removeUnsentScheduledUserItem(id itemID: UUID, from session: TabSession) {
        guard let index = session.items.firstIndex(where: { $0.id == itemID && $0.kind == .user }),
              session.items[index].scheduledSend == nil
        else { return }
        _ = session.removeItem(at: index)
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == itemID }
        requestUIRefresh(tabID: session.tabID, urgent: true)
        scheduleSave(for: session.tabID)
    }

    func updateLocalSessionIndexScheduledSendSummary(for session: TabSession) {
        guard session.hasLoadedPersistedState,
              let sessionID = session.activeAgentSessionID,
              var entry = ownerValidatedSessionIndex[sessionID]
        else { return }
        let summary = AgentSessionScheduledSendSummary.make(from: session.scheduledSend)
        guard entry.scheduledSendSummary != summary
            || entry.lastScheduledDispatch != session.lastScheduledDispatch
        else { return }
        entry.scheduledSendSummary = summary
        entry.lastScheduledDispatch = session.lastScheduledDispatch
        applyLocalSessionIndexUpsert(entry)
    }

    // MARK: - Dispatch (plan §3.3)

    private func scheduledDispatchPreflightFailure(record: AgentScheduledSendPersist, session: TabSession) -> String? {
        if session.remoteHost != nil {
            return Self.scheduledSendRemoteUnsupportedMessage
        }
        guard AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: agentAvailabilityContext) else {
            return unavailableAgentMessage(for: session.selectedAgent)
        }
        if session.profile == .knowledge,
           !KnowledgeSessionPolicy.supportedProviders.contains(session.selectedAgent)
        {
            return "Knowledge sessions currently support Claude Code and Codex. Choose a supported provider before sending."
        }
        if let workspacePath = workspacePathProvider() {
            for taggedFile in record.taggedFileAttachments {
                let path = (workspacePath as NSString).appendingPathComponent(taggedFile.relativePath)
                if !FileManager.default.fileExists(atPath: path) {
                    return "The attached file \"\(taggedFile.displayName)\" no longer exists."
                }
            }
        }
        for attachment in record.attachments {
            if case let .localFile(path) = attachment.source, !FileManager.default.fileExists(atPath: path) {
                return "An attached image is no longer available."
            }
        }
        return nil
    }

    /// Busy evaluation that ignores this session's own in-flight scheduled attempt, for use by
    /// the dispatch path and the coordinator's final handoff validator.
    private func scheduledSendBusyStateExcludingOwnAttempt(for session: TabSession) -> AgentScheduledSendBusyState {
        let wasInFlight = session.isScheduledDispatchInFlight
        session.isScheduledDispatchInFlight = false
        defer { session.isScheduledDispatchInFlight = wasInFlight }
        return scheduledSendBusyState(tabID: session.tabID)
    }

    /// Provider acceptance for a scheduled turn. Codex reports a native send outcome; every
    /// other runner returns `nil` from `startRun` after launching the run (a pre-startup failure
    /// commits `.failed` before returning), so acceptance is the launched run state.
    static func scheduledProviderAccepted(
        outcome: CodexAgentModeCoordinator.NativeSendOutcome?,
        agent: AgentProviderKind,
        runState: AgentSessionRunState
    ) -> Bool {
        if let outcome {
            return outcome.didSend
        }
        guard agent != .codexExec else { return false }
        return runState.isActive || runState == .completed
    }

    private static func scheduledHandoffWasRevoked(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> Bool {
        if case let .stale(reason)? = outcome {
            return reason == AgentModeRunService.providerHandoffRevokedReason
        }
        return false
    }

    /// Appends the scheduled user turn through the shared seam and starts the idle run exactly
    /// like a composer first send (Codex uses the same serialized dispatch gate and fallback
    /// context). Never enters steering, `pendingInstructions`, or waiting-instruction resumption.
    private struct ScheduledSubmitResult {
        let outcome: CodexAgentModeCoordinator.NativeSendOutcome?
        /// The appended user item exactly as prepared (pre-marker), retained as the accepted snapshot.
        let userItem: AgentChatItem?
    }

    private func submitScheduledUserTurn(
        tabID: UUID,
        session: TabSession,
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        providerHandoffAuthorization: @escaping @MainActor () -> Bool
    ) async -> ScheduledSubmitResult {
        guard !session.runState.isActive, session.remoteHost == nil else {
            return ScheduledSubmitResult(
                outcome: .stale(reason: "The session became busy before the scheduled message could start."),
                userItem: nil
            )
        }
        let trimmedText = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = appendPreparedUserTurn(
            tabID: tabID,
            session: session,
            trimmedText: trimmedText,
            attachmentsToSend: record.attachments,
            taggedFilesToSend: record.taggedFileAttachments,
            activeWorkflow: record.workflow,
            nativePreparedTurn: nil,
            inputSource: .scheduled(record: record, attempt: attempt)
        )
        let wrappedText = prepared.wrappedText

        if let scheduledDispatchRunStarter {
            // Mirror the run service's final guarded boundary for injected provider starts.
            guard providerHandoffAuthorization() else {
                return ScheduledSubmitResult(
                    outcome: .stale(reason: AgentModeRunService.providerHandoffRevokedReason),
                    userItem: prepared.userItem
                )
            }
            let outcome = await scheduledDispatchRunStarter(tabID, wrappedText, record.attachments, record.taggedFileAttachments)
            return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem)
        }
        if session.selectedAgent == .codexExec {
            let dispatchTicket = session.codexDispatchSerialGate.issueTicket()
            let fallbackContext = TabSession.CodexFallbackSubmissionContext(
                queueID: UUID(),
                providerText: wrappedText,
                images: record.attachments,
                taggedFileAttachments: record.taggedFileAttachments,
                draftText: trimmedText,
                optimisticUserItemID: prepared.userItem.id,
                origin: .manual,
                dispatchTicket: dispatchTicket
            )
            let outcome = await startAgentRun(
                tabID: tabID,
                initialMessage: wrappedText,
                attachments: record.attachments,
                taggedFileAttachments: record.taggedFileAttachments,
                codexFallbackContext: fallbackContext,
                providerHandoffAuthorization: providerHandoffAuthorization
            )
            return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem)
        }
        _ = enqueueUserTurnTokenEstimate(
            wrappedText: wrappedText,
            attachments: record.attachments,
            session: session
        )
        let outcome = await startAgentRun(
            tabID: tabID,
            initialMessage: wrappedText,
            attachments: record.attachments,
            taggedFileAttachments: record.taggedFileAttachments,
            providerHandoffAuthorization: providerHandoffAuthorization
        )
        return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem)
    }

    /// Releases a persisted `.dispatching` attempt that never reached the provider: the record
    /// returns to its pre-attempt content at a new revision so the coordinator re-arms it. The
    /// coordinator carries the user's Send-now consent and the armed observation to that revision
    /// (`admissionRolledBack`) because no user edit or successor intervened.
    private func revertDispatchingAttempt(
        record: AgentScheduledSendPersist,
        dispatching: AgentScheduledSendPersist,
        session: TabSession,
        lease: AgentScheduledSendAdmissionLease
    ) async {
        var reverted = record
        reverted.updatedAt = Date()
        session.scheduledSend = .v1(reverted)
        let committed = await commitScheduledSend(session: session, member: .v1(reverted), expectedUpdatedAt: dispatching.updatedAt)
        // Consent travels only to a revision that is durable; a failed CAS means a concurrent
        // writer moved the record and the override is withdrawn by the next evaluation.
        if committed {
            scheduledSendCoordinator?.admissionRolledBack(lease: lease, revertedUpdatedAt: reverted.updatedAt)
        }
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
    }

    /// Undoes the run-preparation side effects of a handoff that was revoked before any provider
    /// work: staged handoff payload injection and the enqueued non-Codex token estimate.
    private func rollBackRevokedHandoffPreparation(session: TabSession) {
        if session.pendingHandoff.isStagedForSend {
            session.pendingHandoff.isStagedForSend = false
        }
        if session.selectedAgent != .codexExec {
            _ = dequeuePendingNonCodexUserTokens(for: session)
        }
    }

    private func stampScheduledSendProvenance(
        _ provenance: AgentScheduledSendProvenance,
        onItemID itemID: UUID,
        in session: TabSession
    ) {
        guard let index = session.items.firstIndex(where: { $0.id == itemID }),
              session.items[index].scheduledSend != provenance
        else { return }
        var item = session.items[index]
        item.scheduledSend = provenance
        session.replaceItem(at: index, with: item)
    }

    private func markScheduledSendFailed(
        session: TabSession,
        record: AgentScheduledSendPersist,
        message: String
    ) async {
        // The durable session was explicitly deleted while this attempt was in flight: there is
        // nothing to mark and no file may be recreated.
        guard session.scheduledSend != nil else { return }
        var failed = record
        failed.state = .failed
        failed.lastFailureMessage = message
        failed.confirmationReason = nil
        failed.updatedAt = Date()
        let expected = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(failed)
        session.isDirty = true
        _ = await commitScheduledSend(session: session, member: .v1(failed), expectedUpdatedAt: expected)
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
    }

    // MARK: - Recovery projection (coordinator-owned persistence)

    /// Builds this host's presentation of a process-retained accepted attempt from coordinator-
    /// owned values (status + immutable payload). Any host projecting the retained `.dispatching`
    /// attempt may adopt it: the dispatching owner, a peer window, or a reopened/hydrated tab. No
    /// owner-local state is required. Returns `true` when a projection was installed.
    @discardableResult
    func adoptScheduledSendRecoveryProjection(for session: TabSession) -> Bool {
        guard session.scheduledSendPendingFinalization == nil,
              let coordinator = scheduledSendCoordinator,
              let sessionID = session.activeAgentSessionID,
              let status = coordinator.recoveryStatus(sessionID: sessionID),
              let payload = coordinator.acceptedPayload(sessionID: sessionID),
              payload.attempt.attemptID == status.key.attemptID,
              session.pendingScheduledSendRecord?.attempt?.attemptID == payload.attempt.attemptID
        else { return false }
        session.scheduledSendPendingFinalization = ScheduledSendPendingFinalization(
            key: status.key,
            lease: status.lease,
            attempt: payload.attempt,
            receipt: payload.receipt,
            acceptedItem: payload.acceptedItem,
            status: status.phase
        )
        stampScheduledSendProvenance(payload.receipt, onItemID: payload.attempt.itemID, in: session)
        syncComposerUIState(tabID: session.tabID)
        return true
    }

    /// Reconciles this view model's presentation of a retained accepted attempt from the process
    /// coordinator's current state: installs it when absent, updates its phase, or adopts the
    /// file once the attempt settled. Never performs finalization, retries, or ownership release
    /// itself; those belong to the coordinator worker.
    func reconcileScheduledSendRecoveryProjection(for session: TabSession) {
        guard let sessionID = session.activeAgentSessionID else { return }
        guard let pending = session.scheduledSendPendingFinalization else {
            adoptScheduledSendRecoveryProjection(for: session)
            return
        }
        if let status = scheduledSendCoordinator?.recoveryStatus(sessionID: sessionID),
           status.key == pending.key
        {
            guard status.phase != pending.status else { return }
            var updated = pending
            updated.status = status.phase
            session.scheduledSendPendingFinalization = updated
            syncComposerUIState(tabID: session.tabID)
            return
        }
        // Terminal (durably committed or explicitly deleted): the file is the authority. The
        // live-attempt guard stays up until disk is adopted so no host normalizes the stale
        // `.dispatching` projection in between.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runScheduledSendAction(on: session) {
                guard session.scheduledSendPendingFinalization?.key == pending.key else { return }
                await self.adoptSettledScheduledSendState(
                    session: session,
                    attempt: pending.attempt,
                    receipt: pending.receipt
                )
            }
        }
    }

    /// Adopts disk after a retained attempt settled. Must run inside the session's serialized
    /// action. A file that still carries this exact attempt (transiently unreadable commit) keeps
    /// the acceptance evidence as the local truth; a missing file was explicitly deleted.
    private func adoptSettledScheduledSendState(
        session: TabSession,
        attempt: AgentScheduledSendPersist.Attempt,
        receipt: AgentScheduledSendProvenance
    ) async {
        await resyncScheduledSendFromDisk(session: session)
        if session.pendingScheduledSendRecord?.attempt == attempt {
            session.scheduledSend = nil
            session.scheduledSendPersistedUpdatedAt = nil
            session.scheduledSendWorkspaceID = nil
            session.lastScheduledDispatch = receipt
            stampScheduledSendProvenance(receipt, onItemID: attempt.itemID, in: session)
        }
        session.scheduledSendPendingFinalization = nil
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        syncSidebarUIState(refresh: true, reason: .sessionIndex)
        notifyScheduledSendRecordChanged()
    }

    /// The durable session `sessionID` behind `session` no longer exists (deletion committed under
    /// the persistence gate, or this owner's captured lifetime is stale). Drops every schedule
    /// projection so no candidate, normalization, or creation fallback can write it back. Items
    /// are untouched; the tab is torn down by the deletion flow that owns it. A failure that
    /// belongs to a previous binding of the tab never touches its current session.
    func handleDurableSessionDeleted(_ session: TabSession, sessionID: UUID) {
        guard session.activeAgentSessionID == sessionID else { return }
        // Ownership of the deleted incarnation is revoked for good: no fresh stamp for this ID.
        session.persistenceState = nil
        session.persistenceRevokedSessionID = sessionID
        guard session.scheduledSend != nil
            || session.scheduledSendPendingFinalization != nil
            || session.scheduledSendPersistedUpdatedAt != nil
        else { return }
        session.scheduledSend = nil
        session.scheduledSendPendingFinalization = nil
        session.scheduledSendPersistedUpdatedAt = nil
        session.scheduledSendWorkspaceID = nil
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
    }

    /// Banner action for a retained accepted attempt in attention state: persistence-only retry
    /// routed to the process coordinator. Never a provider action.
    func retryScheduledSendSaving(tabID: UUID) async -> String? {
        guard let session = sessions[tabID], let sessionID = session.activeAgentSessionID else {
            return Self.scheduledSendMissingMessage
        }
        guard let coordinator = scheduledSendCoordinator else {
            return "Scheduled sending is unavailable in this window."
        }
        if case .needsAttention? = coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase {
            // Persistence-only retry of the confirmation obligation; sending stays paused.
            _ = coordinator.retryPendingConfirmation(sessionID: sessionID)
            syncComposerUIState(tabID: tabID)
            return nil
        }
        guard coordinator.retryRecovery(sessionID: sessionID) else {
            reconcileScheduledSendRecoveryProjection(for: session)
            return session.scheduledSendPendingFinalization == nil
                ? nil
                : "Saving is already in progress for this message."
        }
        reconcileScheduledSendRecoveryProjection(for: session)
        return nil
    }
}

/// Mutable box for a serialized action's typed result.
@MainActor
private final class ScheduledSendActionResultBox<T> {
    var value: T?
}

// MARK: - Coordinator host

extension AgentModeViewModel: AgentScheduledSendCoordinatorHost {
    func scheduledSendSessionName(tabID: UUID) -> String? {
        guard let session = sessions[tabID], session.activeAgentSessionID != nil else { return nil }
        return resolvedSessionDisplayName(for: tabID)
    }

    func scheduledSendBusySessionName(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> String? {
        guard persistenceWorkspace?.id == workspaceID else { return nil }
        let busySessions = sessions.values.filter {
            $0.activeAgentSessionID != sessionID && scheduledSendBusyState(tabID: $0.tabID).isBusy
        }
        guard let session = busySessions.sorted(by: { $0.tabID.uuidString < $1.tabID.uuidString }).first
        else { return nil }
        return resolvedSessionDisplayName(for: session.tabID)
    }

    func scheduledSendCandidates() -> [AgentScheduledSendCandidate] {
        guard let workspaceID = persistenceWorkspace?.id else { return [] }
        var candidates: [AgentScheduledSendCandidate] = []
        var coveredSessionIDs: Set<UUID> = []
        for session in sessions.values {
            guard let sessionID = session.activeAgentSessionID,
                  !session.ownsLiveScheduledAttempt,
                  // A retained stale-reset view is neither hydrated nor available for dispatch.
                  session.staleResetRecovery == nil
            else { continue }
            if session.hasLoadedPersistedState {
                guard let record = session.pendingScheduledSendRecord else { continue }
                candidates.append(AgentScheduledSendCandidate(
                    sessionID: sessionID,
                    tabID: session.tabID,
                    workspaceID: session.scheduledSendWorkspaceID ?? workspaceID,
                    scheduledSend: record,
                    isHydrated: true
                ))
                coveredSessionIDs.insert(sessionID)
            } else if let placeholder = ownerValidatedSessionIndex[sessionID]?.scheduledSendSummary?.placeholderRecord {
                candidates.append(AgentScheduledSendCandidate(
                    sessionID: sessionID,
                    tabID: session.tabID,
                    workspaceID: workspaceID,
                    scheduledSend: placeholder,
                    isHydrated: false
                ))
                coveredSessionIDs.insert(sessionID)
            }
        }
        // Discovery hint for open tabs whose session has not been materialized yet.
        let openTabIDs = Set(promptManager?.currentComposeTabs.map(\.id) ?? [])
        for entry in ownerValidatedSessionIndex.values where !coveredSessionIDs.contains(entry.id) {
            guard openTabIDs.contains(entry.tabID),
                  sessions[entry.tabID] == nil,
                  let placeholder = entry.scheduledSendSummary?.placeholderRecord
            else { continue }
            candidates.append(AgentScheduledSendCandidate(
                sessionID: entry.id,
                tabID: entry.tabID,
                workspaceID: workspaceID,
                scheduledSend: placeholder,
                isHydrated: false
            ))
        }
        return candidates
    }

    func scheduledSendBusyState(tabID: UUID) -> AgentScheduledSendBusyState {
        guard let session = sessions[tabID] else { return AgentScheduledSendBusyState() }
        let hasQueuedInstructions = !session.pendingInstructions.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty
            || !session.pendingACPSteeringInstructions.isEmpty
        // A run whose state already went terminal but whose run bookkeeping is still active is
        // a cancellation/teardown that has not settled yet; the bookkeeping change re-triggers.
        let cancellationIsSettling = !session.runState.isActive && isTabRunning(tabID)
        let hasReservation = session.isComposerSubmissionInFlight
            || session.staleResetRecovery != nil
            || session.staleResetRemovalAdmission?.isReserved == true
            || session.isPreparingInitialWorktree
            || session.isChangingExecutionLocation
            || session.ownsLiveScheduledAttempt
            || session.mcpFollowUpRunPending
            || session.pendingMCPElicitationRequest != nil
            || session.mcpControlContext != nil
            || isMCPControlled(tabID: tabID)
        return AgentScheduledSendBusyState(
            runID: session.runID,
            runState: session.runState,
            hasPendingApproval: session.pendingApproval != nil,
            hasPendingAskUser: session.pendingAskUser != nil,
            hasPendingUserInputRequest: session.pendingUserInputRequest != nil,
            hasPendingPermissionsRequest: session.pendingPermissionsRequest != nil,
            hasPendingInstructions: hasQueuedInstructions,
            cancellationIsSettling: cancellationIsSettling,
            hasStartOrDispatchReservation: hasReservation
        )
    }

    func hasBusySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        guard persistenceWorkspace?.id == workspaceID else { return false }
        return sessions.values.contains { session in
            session.activeAgentSessionID != sessionID
                && scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    func scheduledSendBusyStateExcludingDispatchReservation(tabID: UUID) -> AgentScheduledSendBusyState {
        guard let session = sessions[tabID] else { return AgentScheduledSendBusyState() }
        return scheduledSendBusyStateExcludingOwnAttempt(for: session)
    }

    /// Workspace busy aggregation for the coordinator's final handoff validator. The owning host
    /// excludes only the dispatching tab itself (its reservation is the handoff); foreign hosts
    /// receive `nil` and report every busy session in the workspace.
    func hasBusySessionForScheduledSendHandoff(
        inWorkspace workspaceID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        guard persistenceWorkspace?.id == workspaceID else { return false }
        return sessions.values.contains { session in
            guard session.tabID != tabID else { return false }
            return scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    /// Destination ownership for the coordinator's validators: this host owns the tab and the
    /// tab is bound to the admitted durable session.
    func ownsScheduledSendDestination(tabID: UUID, sessionID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        return session.activeAgentSessionID == sessionID
    }

    /// Whether any tab on this host bound to `sessionID` is busy. The owning dispatch tab is
    /// evaluated without its own reservation; every other tab counts fully.
    func scheduledSendDestinationIsBusy(
        sessionID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        sessions.values.contains { session in
            guard session.activeAgentSessionID == sessionID else { return false }
            if session.tabID == tabID {
                return scheduledSendBusyStateExcludingOwnAttempt(for: session).isBusy
            }
            return scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    /// The coordinator observed a newer authoritative revision than this host projects
    /// (typically an unhydrated placeholder): refresh from disk or hydrate instead of skipping.
    func scheduledSendProjectionNeedsRefresh(tabID: UUID, sessionID: UUID) {
        if let session = sessions[tabID], session.activeAgentSessionID == sessionID {
            refreshScheduledSendProjection(for: session)
        } else if ownerValidatedSessionIndex[sessionID] != nil {
            Task { @MainActor [weak self] in
                await self?.refreshIndexScheduledSendSummaryFromDisk(sessionID: sessionID)
            }
        }
    }

    func ensureHydrated(tabID: UUID) async -> Bool {
        let tabIsOpen = promptManager?.currentComposeTabs.contains(where: { $0.id == tabID }) ?? false
        guard sessions[tabID] != nil || tabIsOpen else { return false }
        guard let session = try? await ensureSessionReady(tabID: tabID) else { return false }
        return session.hasLoadedPersistedState && sessions[tabID] === session
    }

    /// Coordinator-issued exact mutation: validated, committed through the shared CAS path inside
    /// this session's serialized action, and adopted only if this host is still the owner. The
    /// replacement is never projected before it is durable.
    func persistScheduledSendMutation(
        tabID: UUID,
        request: AgentScheduledSendHostMutationRequest
    ) async -> AgentScheduledSendHostMutationOutcome {
        guard let session = sessions[tabID],
              session.activeAgentSessionID == request.sessionID,
              session.staleResetRecovery == nil
        else {
            return .unavailable
        }
        guard session.hasLoadedPersistedState else {
            // Unhydrated discovery candidates cannot be mutated durably; hydrate so the
            // coordinator's next pass reaches a real record.
            Task { @MainActor [weak self] in
                _ = await self?.ensureHydrated(tabID: tabID)
            }
            return .unavailable
        }
        return await runScheduledSendAction(on: session) { [self] in
            guard sessions[tabID] === session,
                  session.activeAgentSessionID == request.sessionID,
                  !session.ownsLiveScheduledAttempt
            else { return .unavailable }
            guard let current = session.pendingScheduledSendRecord, current.id == request.scheduleID else {
                return session.persistenceRevokedSessionID == request.sessionID ? .destinationDeleted : .conflict
            }
            guard current == request.expected else { return .conflict }
            let outcome = await commitScheduledSendDetailed(
                session: session,
                member: .v1(request.replacement),
                expectedUpdatedAt: request.expected.updatedAt
            )
            if case .committed = outcome,
               sessions[tabID] === session,
               session.activeAgentSessionID == request.sessionID,
               session.pendingScheduledSendRecord == request.expected
            {
                // Adopt the durable result into this owner's projection.
                session.scheduledSend = .v1(request.replacement)
                session.isDirty = true
                updateLocalSessionIndexScheduledSendSummary(for: session)
                syncComposerUIState(tabID: tabID)
                notifyScheduledSendRecordChanged()
            }
            return outcome
        }
    }

    func dispatchScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        guard let session = sessions[tabID] else { return .failedBeforeHandoff }
        return await runScheduledSendAction(on: session) { [self] in
            await performScheduledDispatch(tabID: tabID, session: session, scheduleID: scheduleID, lease: lease)
        }
    }

    private func performScheduledDispatch(
        tabID: UUID,
        session: TabSession,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        guard let coordinator = scheduledSendCoordinator else { return .failedBeforeHandoff }
        guard sessions[tabID] === session,
              session.hasLoadedPersistedState,
              session.staleResetRecovery == nil,
              session.activeAgentSessionID == lease.sessionID,
              let record = session.pendingScheduledSendRecord,
              record.id == scheduleID
        else {
            return .failedBeforeHandoff
        }
        // Admission freshness: the lease must still name this exact revision and deadline.
        guard coordinator.isValid(lease, for: record) else { return .deferredBusy }
        let eligibleState = record.state == .scheduled
            || (lease.allowsNeedsConfirmation && (record.state == .needsConfirmation || record.state == .failed))
        guard eligibleState else { return .failedBeforeHandoff }
        guard !session.ownsLiveScheduledAttempt else { return .deferredBusy }
        guard !scheduledSendBusyState(tabID: tabID).isBusy else { return .deferredBusy }
        if record.isNewSessionStart,
           !lease.runAlongsideOtherSessions,
           hasBusySession(inWorkspace: lease.workspaceID, excluding: lease.sessionID)
        {
            return .deferredBusy
        }

        session.isScheduledDispatchInFlight = true
        syncComposerUIState(tabID: tabID)
        defer {
            session.isScheduledDispatchInFlight = false
            syncComposerUIState(tabID: tabID)
        }

        if let failureMessage = scheduledDispatchPreflightFailure(record: record, session: session) {
            await markScheduledSendFailed(session: session, record: record, message: failureMessage)
            return .failedBeforeHandoff
        }

        // At-most-once: persist the attempt before the optimistic item exists anywhere.
        let startedAt = Date()
        let attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: record.attempt?.itemID ?? UUID(),
            startedAt: startedAt
        )
        var dispatching = record
        dispatching.state = .dispatching
        dispatching.attempt = attempt
        dispatching.confirmationReason = nil
        dispatching.lastFailureMessage = nil
        dispatching.updatedAt = startedAt
        let expectedBeforeAttempt = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(dispatching)
        session.isDirty = true
        syncComposerUIState(tabID: tabID)
        guard await commitScheduledSend(session: session, member: .v1(dispatching), expectedUpdatedAt: expectedBeforeAttempt),
              session.pendingScheduledSendRecord == dispatching
        else {
            if session.pendingScheduledSendRecord == dispatching {
                session.scheduledSend = .v1(record)
                syncComposerUIState(tabID: tabID)
            }
            return .failedBeforeHandoff
        }

        #if DEBUG
            if let hook = test_scheduledSendAfterDispatchCommitHook {
                await hook(session)
            }
        #endif

        // Freshness after persistence: the coordinator's final handoff validator aggregates the
        // process-wide gates (lease revision/epoch/deadline, owning registration and tab, this
        // session's busy state excluding its own reservation, and every foreign host's workspace
        // busy state). It is carried into `startAgentRun` and re-checked immediately before the
        // provider runner is invoked. A superseded admission releases without retiring.
        // Process-owned recovery: a DataService-issued destination for this exact attempt is
        // captured under the persistence gate before the guarded handoff. The final validation
        // runs after this await; the handoff reservation is made synchronously inside it.
        guard sessions[tabID] === session,
              session.activeAgentSessionID == lease.sessionID,
              let recoveryWorkspace = scheduledSendPersistenceWorkspace(for: session),
              let recoveryStamp = await ensurePersistenceState(for: session, sessionID: lease.sessionID, workspace: recoveryWorkspace)?.stamp,
              let recoveryContext = try? await dataService.prepareScheduledSendRecovery(
                  sessionID: lease.sessionID,
                  for: recoveryWorkspace,
                  persistenceStamp: recoveryStamp,
                  expectedUpdatedAt: dispatching.updatedAt,
                  expectedAttempt: attempt
              ),
              sessions[tabID] === session,
              session.activeAgentSessionID == lease.sessionID,
              let handoffValidator = coordinator.finalHandoffValidator(for: lease)
        else {
            await revertDispatchingAttempt(record: record, dispatching: dispatching, session: session, lease: lease)
            return .deferredBusy
        }
        let recoveryKey = AgentScheduledSendRecoveryKey(
            sessionID: lease.sessionID,
            leaseID: lease.id,
            attemptID: attempt.attemptID
        )

        // Re-drive of a failed attempt reuses the item id; drop any stale unsent bubble first.
        removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
        // The captured coordinator (never a later `self.scheduledSendCoordinator` read) owns the
        // handoff reservation and receives acceptance; the closure retains only immutable values.
        let submitResult = await submitScheduledUserTurn(
            tabID: tabID,
            session: session,
            record: dispatching,
            attempt: attempt,
            providerHandoffAuthorization: { [coordinator, handoffValidator, recoveryContext, attempt] in
                coordinator.authorizeProviderHandoff(handoffValidator, context: recoveryContext, attempt: attempt)
            }
        )
        let outcome = submitResult.outcome

        if Self.scheduledHandoffWasRevoked(outcome) {
            // The process-wide gate closed during run preparation: nothing reached the provider.
            coordinator.reportProviderOutcomeNotAccepted(key: recoveryKey)
            removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
            rollBackRevokedHandoffPreparation(session: session)
            await revertDispatchingAttempt(record: record, dispatching: dispatching, session: session, lease: lease)
            return .deferredBusy
        }

        if Self.scheduledProviderAccepted(outcome: outcome, agent: session.selectedAgent, runState: session.runState) {
            let receipt = AgentScheduledSendProvenance(
                scheduleID: record.id,
                attemptID: attempt.attemptID,
                scheduledFor: dispatching.notBefore,
                sentAt: Date()
            )
            stampScheduledSendProvenance(receipt, onItemID: attempt.itemID, in: session)
            // Immutable accepted snapshot: the exact prepared item, stamped with the receipt.
            var acceptedItem = session.items.first(where: { $0.id == attempt.itemID && $0.kind == .user })
                ?? submitResult.userItem
                ?? AgentChatItem.user(
                    Self.userBubbleText(
                        trimmedText: dispatching.rawText.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments: dispatching.attachments,
                        taggedFiles: dispatching.taggedFileAttachments,
                        workflow: dispatching.workflow
                    ),
                    id: attempt.itemID,
                    attachments: dispatching.attachments,
                    taggedFileAttachments: dispatching.taggedFileAttachments,
                    workflow: dispatching.workflow
                )
            acceptedItem.scheduledSend = receipt
            // Synchronous ownership transfer: the immutable payload and the single persistence
            // worker belong to the process coordinator before any further suspension. Tab,
            // workspace, registration, or cancellation state never gates this transfer.
            coordinator.reportAcceptance(
                key: recoveryKey,
                payload: AgentScheduledSendAcceptedPayload(
                    context: recoveryContext,
                    attempt: attempt,
                    receipt: receipt,
                    acceptedItem: acceptedItem,
                    expectedUpdatedAt: dispatching.updatedAt
                )
            )
            // Read the coordinator's current state after reporting: the attempt may already have
            // settled (explicit deletion during the provider await) in which case no projection
            // is installed and the file is adopted instead.
            if let status = coordinator.recoveryStatus(sessionID: lease.sessionID), status.key == recoveryKey {
                session.scheduledSendPendingFinalization = ScheduledSendPendingFinalization(
                    key: recoveryKey,
                    lease: lease,
                    attempt: attempt,
                    receipt: receipt,
                    acceptedItem: acceptedItem,
                    status: status.phase
                )
                syncComposerUIState(tabID: tabID)
            } else {
                await adoptSettledScheduledSendState(session: session, attempt: attempt, receipt: receipt)
            }
            // Durable commitment is reported by the coordinator; registration alone is not acceptance.
            return .unknownAfterHandoff
        }

        coordinator.reportProviderOutcomeNotAccepted(key: recoveryKey)
        let failureMessage: String = switch outcome {
        case let .failed(message):
            message
        case let .stale(reason):
            reason
        case .cancelled:
            "The run was cancelled before the scheduled message was sent."
        case .sent, .queuedFallback:
            "The scheduled message could not be sent."
        case nil:
            "The agent runtime changed before the scheduled message could be sent."
        }
        removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
        await markScheduledSendFailed(session: session, record: dispatching, message: failureMessage)
        notifyScheduledSendRecordChanged()
        return .failedBeforeHandoff
    }
}
