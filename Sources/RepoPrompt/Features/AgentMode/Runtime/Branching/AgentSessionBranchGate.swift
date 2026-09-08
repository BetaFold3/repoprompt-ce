import Foundation

enum AgentSessionBranchAvailability: Equatable {
    case available(CodexTurnCheckpoint)
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
        occupancy: Occupancy = Occupancy()
    ) -> AgentSessionBranchAvailability {
        if let reason = operationUnavailableReason(session: session, occupancy: occupancy) {
            return .unavailable(reason)
        }
        guard let threadID = session.codexConversationID,
              let ledger = session.codexTurnCheckpoints
        else {
            return .unavailable(.noCheckpoint)
        }
        guard ledger.threadID == threadID else { return .unavailable(.threadMismatch) }
        guard let checkpoint = ledger.entries.first(where: { $0.turnID == turnID }) else {
            return .unavailable(.noCheckpoint)
        }
        guard checkpoint.status == .completed, checkpoint.sideEffect != nil else {
            return .unavailable(.turnNotCompleted)
        }
        return .available(checkpoint)
    }

    static func operationUnavailableReason(
        session: AgentModeViewModel.TabSession,
        occupancy: Occupancy = Occupancy()
    ) -> AgentSessionBranchAvailability.Reason? {
        guard session.selectedAgent == .codexExec else {
            return .providerUnsupported(session.selectedAgent)
        }
        guard session.remoteHost == nil else { return .remoteSession }
        guard session.origin == .user, !session.isMCPOriginated else { return .mcpOriginated }
        guard session.parentSessionID == nil else { return .childSession }
        guard session.worktreeBindings.isEmpty, session.worktreeMergeOperations.isEmpty else {
            return .worktreeBound
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
