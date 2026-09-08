import Foundation

// swiftformat:disable:next redundantSendable
enum AgentTurnCheckpointStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled
}

// swiftformat:disable:next redundantSendable
enum AgentTurnSideEffect: Codable, Equatable, Sendable {
    case readOnly
    case modified(paths: [String])
    case unknown
}

// swiftformat:disable:next redundantSendable
enum AgentBranchNativeTurnRef: Codable, Equatable, Sendable {
    case codexTurn(id: String)
    case claudeEntry(lastEntryUUID: String, promptEntryUUID: String)
}

// swiftformat:disable:next redundantSendable
struct AgentBranchCheckpoint: Codable, Equatable, Sendable {
    let turnID: UUID
    var status: AgentTurnCheckpointStatus
    var sideEffect: AgentTurnSideEffect?
    let nativeRef: AgentBranchNativeTurnRef
    let recordedAt: Date
}

// swiftformat:disable:next redundantSendable
struct AgentBranchCheckpointIndex: Equatable, Sendable {
    let byTurnID: [UUID: AgentBranchCheckpoint]
    let duplicateTurnIDs: Set<UUID>

    init(checkpoints: [AgentBranchCheckpoint]) {
        var byTurnID: [UUID: AgentBranchCheckpoint] = [:]
        var duplicateTurnIDs: Set<UUID> = []
        byTurnID.reserveCapacity(checkpoints.count)
        for checkpoint in checkpoints {
            if byTurnID[checkpoint.turnID] != nil {
                duplicateTurnIDs.insert(checkpoint.turnID)
            } else {
                byTurnID[checkpoint.turnID] = checkpoint
            }
        }
        self.byTurnID = byTurnID
        self.duplicateTurnIDs = duplicateTurnIDs
    }
}

enum AgentBranchNativeBinding: Equatable {
    case codex(conversationID: String, ledger: CodexTurnCheckpointLedger)

    var checkpointIndex: AgentBranchCheckpointIndex {
        switch self {
        case let .codex(_, ledger):
            ledger.checkpointIndex()
        }
    }
}

@MainActor
enum AgentBranchProviderSupport {
    /// Phase 1 intentionally preserves the shipped Codex-only support boundary.
    static func isSupported(_ kind: AgentProviderKind) -> Bool {
        kind == .codexExec
    }

    static func nativeBinding(
        for session: AgentModeViewModel.TabSession
    ) -> AgentBranchNativeBinding? {
        switch session.selectedAgent {
        case .codexExec:
            guard let conversationID = session.codexConversationID,
                  let ledger = session.codexTurnCheckpoints
            else {
                return nil
            }
            return .codex(conversationID: conversationID, ledger: ledger)
        case .claudeCode, .openCode, .cursor, .ohMyPi, .claudeCodeGLM, .kimiCode,
             .customClaudeCompatible:
            return nil
        }
    }
}

enum AgentBranchRuntimeCapability: Equatable {
    case notApplicable
    case unknown
    case supported(version: String)
    case unsupported(UnsupportedReason)

    enum UnsupportedReason: Equatable {
        case versionBelowFloor
        case flagMissing
        case probeFailed
        case probeTimedOut
    }
}
