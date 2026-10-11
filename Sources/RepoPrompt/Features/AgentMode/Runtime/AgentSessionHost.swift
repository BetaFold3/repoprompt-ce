import Foundation

/// Host surface shared by the agent coordinators for session UI refresh, persistence, and
/// run-state publication.
@MainActor
protocol AgentSessionHost: AnyObject {
    func requestUIRefresh(
        tabID: UUID,
        urgent: Bool,
        scope: AgentUIRefreshScope
    )
    func scheduleSave(for tabID: UUID)
    func setAgentRunActive(_ tabID: UUID, isActive: Bool)
    func mcpDelegationRunToolPolicy(for session: AgentTabSession) -> AgentDelegationPolicy.RunToolPolicy
}

/// Mirrors the defaults of `AgentModeViewModel.requestUIRefresh` (`urgent: false`, `scope: .full`).
@MainActor
extension AgentSessionHost {
    func requestUIRefresh(tabID: UUID) {
        requestUIRefresh(tabID: tabID, urgent: false, scope: .full)
    }

    func requestUIRefresh(tabID: UUID, urgent: Bool) {
        requestUIRefresh(tabID: tabID, urgent: urgent, scope: .full)
    }

    func requestUIRefresh(tabID: UUID, scope: AgentUIRefreshScope) {
        requestUIRefresh(tabID: tabID, urgent: false, scope: scope)
    }
}

/// Host surface used by `CodexAgentModeCoordinator`.
@MainActor
protocol CodexAgentModeCoordinatorHost: AgentSessionHost {
    var selectedAgent: AgentProviderKind { get }
    var activeSession: AgentTabSession? { get }
    var currentTabID: UUID? { get }
    var codexDynamicModels: [CodexAppServerClient.RemoteModel] { get }
    func updateCodexDynamicModels(_ models: [CodexAppServerClient.RemoteModel])
    func applyCodexSelectionToBindings(modelRaw: String, reasoningEffortRaw: String?)
    func reconcileInteractiveRunState(_ session: AgentTabSession)
    func publishMCPStateChange(for session: AgentTabSession)
    func signalCodexInstructionDelivered(for session: AgentTabSession) async
    func restoreCodexFallbackDraft(tabID: UUID, text: String, message: String)
    func recordMCPInteractionResolution(
        for session: AgentTabSession,
        interactionID: UUID,
        fallbackResolvedBy: String
    )
    func bindPendingOracleReviewContext(tabID: UUID, runID: UUID)
    func canBuildOrPublishActiveTranscriptBindings(for session: AgentTabSession) -> Bool
    func requestAssistantPresentationRefresh(
        session: AgentTabSession,
        sourceItemsRevision: Int,
        flushGeneration: UInt64
    )
    func codexThreadDisplayName(for tabID: UUID) -> String
    func scheduleSaveForCommandOutput(tabID: UUID, minInterval: TimeInterval)
    func ensureMCPServerEnabledForThreadStart() async
    func hasLiveRunRouteInCurrentMCPServer(_ runID: UUID) -> Bool
    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: AgentTabSession)
    func refreshCodexContextUsageSnapshot(for session: AgentTabSession)
    func clearContextUsageSnapshot(for session: AgentTabSession)
    func markAttachmentsConsumed(for session: AgentTabSession, reservationID: UUID?)
    func stageConsumedAttachmentFilesForDeferredCleanup(_ attachments: [AgentImageAttachment], session: AgentTabSession)
    func finalizeAttachmentsForTurn(
        for session: AgentTabSession,
        reservationID: UUID?,
        disposition: AgentAttachmentTurnDisposition
    )
}

/// Mirrors the default of `AgentModeViewModel.recordMCPInteractionResolution` (`fallbackResolvedBy: "user"`).
@MainActor
extension CodexAgentModeCoordinatorHost {
    func recordMCPInteractionResolution(
        for session: AgentTabSession,
        interactionID: UUID
    ) {
        recordMCPInteractionResolution(
            for: session,
            interactionID: interactionID,
            fallbackResolvedBy: "user"
        )
    }
}

/// Host surface used by `ClaudeAgentModeCoordinator`.
@MainActor
protocol ClaudeAgentModeCoordinatorHost: AgentSessionHost {
    var sessions: [UUID: AgentTabSession] { get }
    var providerBindingService: AgentModeProviderBindingService { get }
    func provisionalClaudeContextWindowKey(for session: AgentTabSession) -> ClaudeProvisionalContextWindowResolver.Key?
    func syncSpawnResolvedClaudeConfiguredContextWindow(
        _ value: Int?,
        launchKey: ClaudeProvisionalContextWindowResolver.Key,
        for session: AgentTabSession
    )
    func stageClaudeResumeRecoveryHandoffIfNeeded(
        for session: AgentTabSession,
        ifStillOwned: @escaping @MainActor () -> Bool,
        beforeCommit: (@MainActor () async -> Void)?
    ) async -> Bool
    func prependPendingHandoffIfNeeded(
        _ text: String,
        session: AgentTabSession
    ) -> String
    @discardableResult
    func updatePermissionBindingState(from session: AgentTabSession, syncUI: Bool) -> Bool
}

/// Mirrors the default of `AgentModeViewModel.updatePermissionBindingState` (`syncUI: true`).
@MainActor
extension ClaudeAgentModeCoordinatorHost {
    @discardableResult
    func updatePermissionBindingState(from session: AgentTabSession) -> Bool {
        updatePermissionBindingState(from: session, syncUI: true)
    }
}

@MainActor
protocol AgentModeRunInteractionStateObserving: AnyObject {
    func agentModeViewModel(
        _ viewModel: any AgentSessionHost,
        didChangeRunInteractionStateFor session: AgentTabSession,
        reason: AgentRunInteractionStateChangeReason
    )
}
