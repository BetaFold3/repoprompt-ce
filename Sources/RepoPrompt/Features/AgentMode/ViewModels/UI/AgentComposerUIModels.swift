import Foundation

struct AgentComposerFocusRequest: Equatable {
    enum Reason: Equatable {
        case newSession
        case newKnowledgeSession
        case reusedPlaceholder
    }

    let id: UUID
    let tabID: UUID
    let reason: Reason
}

struct AgentDraftRestorationProps: Equatable {
    let id: UUID
    let tabID: UUID
    let text: String
    let message: String
    let strategy: AgentModeRunService.DraftRestorationStrategy

    init(_ event: AgentModeViewModel.DraftRestorationEvent) {
        id = event.id
        tabID = event.tabID
        text = event.text
        message = event.message
        strategy = event.strategy
    }
}

struct AgentStagedSlashCommandProps: Equatable {
    enum Kind: Equatable {
        case codexGoal
    }

    enum GoalAction: String, Equatable {
        case setObjective
        case show
        case pause
        case resume
        case clear
    }

    let kind: Kind
    let displayText: String
    let action: GoalAction
    let selectedWorkflowName: String?
    let appliesSelectedWorkflowContext: Bool
}

struct AgentRunCancelTarget: Equatable {
    let tabID: UUID
    let expectedRunID: UUID?
    let expectedActiveAgentSessionID: UUID?
    let expectedRunAttemptID: UUID?
    let expectedPendingUserInputRequestID: CodexAppServerRequestID?
}

struct AgentComposerSubmitTarget: Equatable {
    enum Route: String, Equatable {
        case existingAgentSession
        case createAgentSessionFromSourceTab
    }

    let tabID: UUID
    let route: Route
    let expectedSourceTabSessionIdentity: ObjectIdentifier
    let expectedSourceAgentSessionID: UUID?
    let expectedPersistentBindingIdentity: AgentPersistentSessionBindingIdentity?
    let expectedBindingTransitionGeneration: UInt64
    // Exact freshness guards for unlinked first-send targets. For an existing
    // persistent session, these remain render-time diagnostics while live routing
    // selects the current run and attempt at send time.
    let expectedRunState: AgentSessionRunState
    let expectedRunID: UUID?
    let expectedRunAttemptID: UUID?
    /// One-shot render identity claimed before submission performs any async work.
    let expectedSubmissionToken: UUID
    let expectedInitialStartLocation: AgentModeViewModel.InitialStartLocation?
}

struct AgentComposerSubmitAttempt: Equatable {
    let id: UUID
    let target: AgentComposerSubmitTarget
    let inputRevision: UInt64
    let noticeRevision: UInt64
    let rawDraftSnapshot: String

    var sourceTabID: UUID {
        target.tabID
    }

    var sourceTabSessionIdentity: ObjectIdentifier {
        target.expectedSourceTabSessionIdentity
    }

    var capturedSubmissionToken: UUID {
        target.expectedSubmissionToken
    }
}

struct AgentComposerSubmissionLatch {
    struct CompletionEffects: Equatable {
        let matchedAttempt: Bool
        let shouldClearInput: Bool
        let blockedMessage: String?

        static let stale = CompletionEffects(
            matchedAttempt: false,
            shouldClearInput: false,
            blockedMessage: nil
        )
    }

    private(set) var activeAttemptsByTabID: [UUID: AgentComposerSubmitAttempt] = [:]
    private(set) var inputRevision: UInt64 = 0
    private(set) var noticeRevision: UInt64 = 0

    func isLatched(for tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return activeAttemptsByTabID[tabID] != nil
    }

    func activeAttemptID(for tabID: UUID?) -> UUID? {
        guard let tabID else { return nil }
        return activeAttemptsByTabID[tabID]?.id
    }

    mutating func advanceInputRevision() {
        inputRevision &+= 1
    }

    mutating func advanceNoticeRevision() {
        noticeRevision &+= 1
    }

    mutating func begin(
        target: AgentComposerSubmitTarget,
        rawDraftSnapshot: String,
        attemptID: UUID = UUID()
    ) -> AgentComposerSubmitAttempt? {
        guard activeAttemptsByTabID[target.tabID] == nil else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: attemptID,
            target: target,
            inputRevision: inputRevision,
            noticeRevision: noticeRevision,
            rawDraftSnapshot: rawDraftSnapshot
        )
        activeAttemptsByTabID[target.tabID] = attempt
        return attempt
    }

    @discardableResult
    mutating func cancel(_ attempt: AgentComposerSubmitAttempt) -> Bool {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else { return false }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)
        return true
    }

    mutating func complete(
        _ attempt: AgentComposerSubmitAttempt,
        result: AgentModeViewModel.UserTurnSubmissionResult,
        currentTabID: UUID?,
        currentRawDraft: String
    ) -> CompletionEffects {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else {
            return .stale
        }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)

        let inputStillMatches = currentTabID == attempt.sourceTabID
            && inputRevision == attempt.inputRevision
            && currentRawDraft == attempt.rawDraftSnapshot
        switch result {
        case .submitted, .scheduled:
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: inputStillMatches,
                blockedMessage: nil
            )
        case let .blocked(message):
            let mayPublishNotice = inputStillMatches && noticeRevision == attempt.noticeRevision
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: false,
                blockedMessage: mayPublishNotice ? message : nil
            )
        }
    }
}

struct AgentScheduledSendProps: Equatable, Identifiable {
    enum Status: Equatable {
        case scheduled
        case waitingForCurrentRun(blockingSessionName: String?)
        case waitingForWorkspace(blockingSessionName: String?)
        case needsConfirmation(AgentScheduledSendPersist.ConfirmationReason?)
        case dispatching
        /// Provider accepted the message; the durable commit of item + receipt is still pending
        /// and automatic persistence retries are in progress.
        case finalizing
        /// Provider accepted the message; automatic persistence stopped. Only a persistence
        /// retry is offered (never a provider re-send).
        case savingFailed(message: String?)
        case failed(message: String?)
        /// Persisted member this build cannot read; only Discard is offered.
        case unreadable
    }

    let id: UUID
    let tabID: UUID
    let notBefore: Date
    let rawText: String
    let attachments: AgentAttachmentStripSnapshot
    let isNewSessionStart: Bool
    let runAlongsideOtherSessions: Bool
    let firstEligibleAt: Date?
    let status: Status
    /// Recovery guidance that must be visible before any re-drive (for example the explicit
    /// duplicate-delivery warning after an interrupted dispatch whose bubble already exists).
    let recoveryMessage: String?
    /// A coordinator decision that the record requires confirmation whose durable save has not
    /// been acknowledged yet. Automatic sending is paused; the banner presents the confirmation
    /// state derived from the decision rather than from the persisted record.
    let pendingConfirmationSaving: PendingConfirmationSaving?

    enum PendingConfirmationSaving: Equatable {
        case saving
        case needsAttention(message: String?)
    }

    init(
        tabID: UUID,
        scheduledSend: AgentScheduledSendPersist,
        blockingSessionName: String? = nil,
        recoveryPhase: AgentScheduledSendRecoveryPhase? = nil,
        pendingConfirmation: AgentScheduledSendPendingConfirmationStatus? = nil
    ) {
        id = scheduledSend.id
        self.tabID = tabID
        notBefore = scheduledSend.notBefore
        rawText = scheduledSend.rawText
        attachments = AgentAttachmentStripSnapshot(
            scopeTabID: tabID,
            imageAttachments: scheduledSend.attachments,
            taggedFileAttachments: scheduledSend.taggedFileAttachments
        )
        isNewSessionStart = scheduledSend.isNewSessionStart
        runAlongsideOtherSessions = scheduledSend.runAlongsideOtherSessions
        firstEligibleAt = scheduledSend.firstEligibleAt
        if let pendingConfirmation, scheduledSend.state != .dispatching {
            // Derived projection: the decision blocks sending now even though the persisted
            // record has not been rewritten yet.
            status = .needsConfirmation(pendingConfirmation.reason)
            switch pendingConfirmation.phase {
            case let .needsAttention(lastFailure):
                pendingConfirmationSaving = .needsAttention(message: lastFailure)
                recoveryMessage = Self.pendingConfirmationAttentionMessage
            case .waitingForOwner, .saving, .waitingToRetry:
                pendingConfirmationSaving = .saving
                recoveryMessage = Self.pendingConfirmationSavingMessage
            }
            return
        }
        pendingConfirmationSaving = nil
        status = switch scheduledSend.state {
        case .scheduled where scheduledSend.firstEligibleAt != nil && scheduledSend.isNewSessionStart:
            .waitingForWorkspace(blockingSessionName: blockingSessionName)
        case .scheduled where scheduledSend.firstEligibleAt != nil:
            .waitingForCurrentRun(blockingSessionName: blockingSessionName)
        case .scheduled:
            .scheduled
        case .needsConfirmation:
            .needsConfirmation(scheduledSend.confirmationReason)
        case .dispatching where recoveryPhase != nil:
            Self.acceptedStatus(for: recoveryPhase)
        case .dispatching:
            .dispatching
        case .failed:
            .failed(message: scheduledSend.lastFailureMessage)
        }
        recoveryMessage = switch scheduledSend.state {
        case .needsConfirmation:
            scheduledSend.lastFailureMessage.flatMap { $0.isEmpty ? nil : $0 }
        case .dispatching where recoveryPhase.map(Self.isAttention) == true:
            Self.savingFailedRecoveryMessage
        case .scheduled, .dispatching, .failed:
            nil
        }
    }

    static let savingFailedRecoveryMessage =
        "Message sent, but saving has not completed. Retry saving will not send the message again."
    static let pendingConfirmationSavingMessage =
        "Automatic sending is paused until this confirmation is saved."
    static let pendingConfirmationAttentionMessage =
        "Automatic sending is paused. Saving the confirmation failed; retry saving or confirm the message yourself."

    private static func acceptedStatus(for phase: AgentScheduledSendRecoveryPhase?) -> Status {
        switch phase {
        case let .needsAttention(reason)?:
            .savingFailed(message: attentionMessage(for: reason))
        case .awaitingProviderOutcome?, .saving?, .waitingToRetry?, nil:
            .finalizing
        }
    }

    private static func isAttention(_ phase: AgentScheduledSendRecoveryPhase) -> Bool {
        if case .needsAttention = phase { return true }
        return false
    }

    private static func attentionMessage(for reason: AgentScheduledSendRecoveryAttentionReason) -> String? {
        switch reason {
        case let .persistenceExhausted(lastFailure):
            lastFailure.isEmpty ? nil : lastFailure
        case .destinationUnavailable:
            "The workspace storage folder is unavailable."
        case let .invalidAcceptanceEvidence(detail):
            detail.isEmpty ? nil : detail
        case .unresolvedProviderOutcome:
            "The provider outcome was not reported before this window went away."
        }
    }

    private init(unreadableForTabID tabID: UUID) {
        id = tabID
        self.tabID = tabID
        notBefore = .distantPast
        rawText = ""
        attachments = AgentAttachmentStripSnapshot(
            scopeTabID: tabID,
            imageAttachments: [],
            taggedFileAttachments: []
        )
        isNewSessionStart = false
        runAlongsideOtherSessions = false
        firstEligibleAt = nil
        status = .unreadable
        pendingConfirmationSaving = nil
        recoveryMessage = "This scheduled message was saved by a newer or incompatible version and can't be read here. It will never be sent automatically."
    }

    static func unreadable(tabID: UUID) -> AgentScheduledSendProps {
        AgentScheduledSendProps(unreadableForTabID: tabID)
    }

    var isUnreadable: Bool {
        status == .unreadable
    }
}

struct AgentScheduledSendActions {
    let executeSchedule: (
        _ claim: AgentModeViewModel.AgentComposerSubmitClaim,
        _ text: String,
        _ notBefore: Date,
        _ runAlongsideOtherSessions: Bool
    ) async -> AgentModeViewModel.UserTurnSubmissionResult
    let update: (
        _ tabID: UUID,
        _ scheduleID: UUID,
        _ text: String,
        _ notBefore: Date,
        _ runAlongsideOtherSessions: Bool
    ) async -> String?
    let cancel: (_ tabID: UUID, _ scheduleID: UUID) async -> String?
    let sendNow: (
        _ tabID: UUID,
        _ scheduleID: UUID,
        _ runAlongsideOtherSessions: Bool
    ) async -> String?
    let discardUnreadable: (_ tabID: UUID) async -> String?
    /// Persistence-only retry for an accepted message whose durable save stopped; never a send.
    let retrySaving: (_ tabID: UUID) async -> String?
}

/// Presentation of a stale-reset recovery: this tab retains a local conversation that cannot be
/// saved because the conversation was reset in another window; only an explicit reload replaces it.
struct AgentStaleResetRecoveryProps: Equatable, Identifiable {
    enum Status: Equatable {
        case stopping
        case retained
        case reloading
    }

    let tabID: UUID
    let recoveryID: UUID
    let status: Status
    /// Last reported problem (failed stop or failed reload); the retained view is unchanged.
    let problem: String?

    var id: UUID {
        recoveryID
    }

    var canReload: Bool {
        status == .retained
    }

    var canRetryStop: Bool {
        status == .stopping && problem != nil
    }
}

struct AgentStaleResetRecoveryActions {
    /// Explicitly confirmed replacement of the retained view by the persisted snapshot.
    let reloadLatest: (_ tabID: UUID, _ recoveryID: UUID) async -> String?
    /// One more stop attempt after a reported stop problem.
    let retryStopping: (_ tabID: UUID, _ recoveryID: UUID) async -> String?
}

struct AgentComposerProps: Equatable {
    let currentTabID: UUID?
    let submitTarget: AgentComposerSubmitTarget?
    let attachments: AgentAttachmentStripSnapshot
    let scheduledSend: AgentScheduledSendProps?
    let staleResetRecovery: AgentStaleResetRecoveryProps?
    let canSchedule: Bool
    /// Semantic first-prompt predicate (unlinked tab or linked-but-untouched session): the
    /// schedule control offers "Run alongside other sessions" exactly when the record will be a
    /// workspace-gated new-session start.
    let scheduleTargetIsNewSessionStart: Bool
    let runState: AgentSessionRunState
    let cancelTarget: AgentRunCancelTarget?
    let isAgentBusy: Bool
    let isWaitingForInstruction: Bool
    let canUseLinkedAgentSession: Bool
    let isCurrentTabMCPControlled: Bool
    let areModelControlsDisabled: Bool
    let providerControls: AgentProviderControlsBinding?
    let isCodexRunActive: Bool
    let hasAvailableAgentProviders: Bool
    let canSendWithCurrentProvider: Bool
    let unavailableSelectedAgentMessage: String?
    let runLocation: AgentRunLocation?
    let runLocationHostDisplayName: String?
    let remoteHostCatalog: RemoteHostAgentCatalog?
    let selectedAgent: AgentProviderKind
    let selectedModelRaw: String
    let selectedModelDisplayName: String
    let ohMyPiThinkingSelections: OhMyPiThinkingSelections
    let selectedReasoningEffortRaw: String?
    let selectedReasoningEffortDisplayName: String
    let availableAgents: [AgentProviderKind]
    let isProviderPickerLockedForCurrentTab: Bool
    let lockedAgentSelectionMessage: String?
    let autoEditEnabled: Bool
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let draftRestorationEvent: AgentDraftRestorationProps?
    let fileTagLookupContextIdentity: AgentWorkspaceLookupContextIdentity

    static let empty = AgentComposerProps(
        currentTabID: nil,
        submitTarget: nil,
        attachments: AgentAttachmentStripSnapshot(
            imageAttachments: [],
            taggedFileAttachments: []
        ),
        scheduledSend: nil,
        staleResetRecovery: nil,
        canSchedule: false,
        scheduleTargetIsNewSessionStart: false,
        runState: .idle,
        cancelTarget: nil,
        isAgentBusy: false,
        isWaitingForInstruction: false,
        canUseLinkedAgentSession: false,
        isCurrentTabMCPControlled: false,
        areModelControlsDisabled: false,
        providerControls: nil,
        isCodexRunActive: false,
        hasAvailableAgentProviders: false,
        canSendWithCurrentProvider: false,
        unavailableSelectedAgentMessage: nil,
        runLocation: nil,
        runLocationHostDisplayName: nil,
        remoteHostCatalog: nil,
        selectedAgent: .claudeCode,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedModelDisplayName: AgentModel.defaultModel.displayName,
        ohMyPiThinkingSelections: .empty,
        selectedReasoningEffortRaw: nil,
        selectedReasoningEffortDisplayName: "",
        availableAgents: [],
        isProviderPickerLockedForCurrentTab: false,
        lockedAgentSelectionMessage: nil,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        stagedSlashCommand: nil,
        draftRestorationEvent: nil,
        fileTagLookupContextIdentity: AgentWorkspaceLookupContextSource(
            activeAgentSessionID: nil,
            worktreeBindings: []
        ).identity
    )
}
