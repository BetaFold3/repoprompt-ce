import Foundation

enum AgentSessionBranchAvailability: Equatable {
    case available(AgentBranchCheckpoint)
    case unavailable(Reason)

    enum Reason: Equatable {
        case providerUnsupported(AgentProviderKind)
        case remoteSession
        case mcpOriginated
        case childSession
        case worktreeBound
        case notIdle
        case operationInProgress
        case pendingHandoff
        case noCheckpoint
        case turnNotCompleted
        case beforeCompaction
        case threadMismatch
        case runtimeCapabilityUnknown
        case runtimeUnsupported(AgentBranchRuntimeCapability.UnsupportedReason)
        case unsupportedHistory(UnsupportedHistoryReason)
        case turnNotRetained
        case lineageProviderMismatch
        case treeEvidenceUnavailable
    }

    enum UnsupportedHistoryReason: Equatable {
        case compaction
        case sidechain
        case ambiguousSegment
    }
}

@MainActor
enum AgentSessionBranchGate {
    struct Occupancy: Equatable {
        var oracleRequestActive = false
        var codexTerminalSettlePending = false
    }

    static func evaluate(
        session: AgentModeViewModel.TabSession,
        turnID: UUID,
        occupancy: Occupancy = Occupancy(),
        runtimeCapability: AgentBranchRuntimeCapability = .notApplicable
    ) -> AgentSessionBranchAvailability {
        if let reason = operationUnavailableReason(session: session, occupancy: occupancy) {
            return .unavailable(reason)
        }
        switch runtimeCapability {
        case .notApplicable, .supported:
            break
        case .unknown:
            return .unavailable(.runtimeCapabilityUnknown)
        case let .unsupported(reason):
            return .unavailable(.runtimeUnsupported(reason))
        }
        guard let binding = AgentBranchProviderSupport.nativeBinding(for: session) else {
            return .unavailable(.noCheckpoint)
        }
        switch binding {
        case let .codex(conversationID, ledger):
            guard ledger.threadID == conversationID else { return .unavailable(.threadMismatch) }
            let index = binding.checkpointIndex
            guard !index.duplicateTurnIDs.contains(turnID),
                  let checkpoint = index.byTurnID[turnID]
            else {
                return .unavailable(.noCheckpoint)
            }
            guard checkpoint.status == .completed, checkpoint.sideEffect != nil else {
                return .unavailable(.turnNotCompleted)
            }
            return .available(checkpoint)
        }
    }

    static func staticUnavailableReason(
        session: AgentModeViewModel.TabSession
    ) -> AgentSessionBranchAvailability.Reason? {
        guard AgentBranchProviderSupport.isSupported(session.selectedAgent) else {
            return .providerUnsupported(session.selectedAgent)
        }
        guard session.remoteHost == nil else { return .remoteSession }
        guard session.origin == .user, !session.isMCPOriginated else { return .mcpOriginated }
        guard session.parentSessionID == nil else { return .childSession }
        guard session.worktreeBindings.isEmpty, session.worktreeMergeOperations.isEmpty else {
            return .worktreeBound
        }
        return nil
    }

    static func operationUnavailableReason(
        session: AgentModeViewModel.TabSession,
        occupancy: Occupancy = Occupancy()
    ) -> AgentSessionBranchAvailability.Reason? {
        if let reason = staticUnavailableReason(session: session) {
            return reason
        }
        if let branchOrigin = session.branchOrigin,
           branchOrigin.diagnosticSourceProviderKind != session.selectedAgent.rawValue
        {
            return .lineageProviderMismatch
        }
        guard !session.isBranchOperationInProgress else { return .operationInProgress }
        guard !session.pendingHandoff.hasPayload else { return .pendingHandoff }
        guard !session.runState.isActive,
              !occupancy.oracleRequestActive,
              !occupancy.codexTerminalSettlePending,
              session.instructionContinuation == nil,
              session.codexFallbackQueue.isEmpty,
              session.codexFallbackDispatchInFlight == nil,
              session.attachmentTurnState == .idle,
              !session.hasBindingBlockingInteraction
        else {
            return .notIdle
        }
        return nil
    }
}
