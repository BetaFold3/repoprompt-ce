import Foundation
import RepoPromptWorkspace

enum AgentRunInteractionStateChangeReason: String, Equatable {
    case userInputResponseSubmitted
    case pendingQuestionCancelled
    case pendingApprovalCancelled
    case approvalResponseSubmitted
    case permissionsResponseSubmitted
    case mcpElicitationResponseSubmitted
}

struct AgentMCPControlContext: Equatable {
    let sessionID: UUID
    let activationID: UUID
    let registration: AgentRunSessionStore.Registration
    var currentEpoch: AgentRunTurnEpoch?
    var preparedEpoch: AgentRunTurnEpoch?
    var pendingEpochTransition: AgentRunEpochTransitionIntent?
    let originatingConnectionID: UUID?
    let interactionTransport: AgentInteractionTransport
    let suppressUserNotifications: Bool
    let forceAutoEditEnabled: Bool
    let autoEditEnabledBeforeOverride: Bool
    /// The task label kind for this MCP-controlled run (e.g. explore, engineer).
    /// Used to customize tool advertisement and system prompts for role-specific behavior.
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?

    func replacingRegistration(_ registration: AgentRunSessionStore.Registration) -> Self {
        Self(
            sessionID: sessionID,
            activationID: activationID,
            registration: registration,
            currentEpoch: currentEpoch,
            preparedEpoch: preparedEpoch,
            pendingEpochTransition: pendingEpochTransition,
            originatingConnectionID: originatingConnectionID,
            interactionTransport: interactionTransport,
            suppressUserNotifications: suppressUserNotifications,
            forceAutoEditEnabled: forceAutoEditEnabled,
            autoEditEnabledBeforeOverride: autoEditEnabledBeforeOverride,
            taskLabelKind: taskLabelKind
        )
    }
}

struct AgentAutoEditPermissionGuidance: Equatable {
    enum Provider: Equatable {
        case codex
        case claude
    }

    enum Action: Equatable {
        case setCodexReadOnly
        case setClaudeRequireApproval
    }

    let provider: Provider
    let message: String
    let actionTitle: String
    let action: Action
}

struct AgentNonCodexTurnTokenAccumulator {
    var estimatedUserInputTokens: Int = 0
    var estimatedToolInputTokens: Int = 0
    var estimatedToolOutputTokens: Int = 0
    /// Exact stream-derived context snapshot for the current turn (from usage events),
    /// tracked separately from the session-wide display value to prevent billed-turn
    /// aggregates from overwriting it.
    var observedContextUsedTokens: Int?

    var estimatedInputTokens: Int {
        estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
    }
}

enum AgentAttachmentTurnDisposition: Equatable {
    case restoreToPending
    case deleteFiles
    case keepFiles
}

enum AgentAttachmentTurnState: Equatable {
    case idle
    case reserved(reservationID: UUID, attachments: [AgentImageAttachment])
    case consumed(reservationID: UUID, attachments: [AgentImageAttachment])
}

struct AgentCodexComputerUseActivation: Equatable {
    let id: UUID
    let createdAt: Date
}

struct AgentPendingHandoffState: Equatable {
    var payload: String?
    var createdAt: Date?
    var sourceItemID: UUID?
    /// True only for a freshly-created handoff tab. Keeps agent selection editable
    /// until the destination tab successfully sends its first real user turn.
    var defersProviderLockUntilSend: Bool = false
    var isStagedForSend: Bool = false

    var hasPayload: Bool {
        guard let payload else { return false }
        return !payload.isEmpty
    }

    mutating func clearAfterSend() {
        payload = nil
        createdAt = nil
        sourceItemID = nil
        defersProviderLockUntilSend = false
        isStagedForSend = false
    }
}

struct AgentCodexWatchdogState: Equatable {
    var lastProgressAt: Date?
    var suppressUntil: Date?
    var ambiguousActiveProbeCount: Int = 0
    var isPausedAfterWarning: Bool = false
    var warnedSinceLastProgress: Bool = false
    var requiresColdTeardownOnCancel: Bool = false
}

/// Consecutive `thread/resume` timeouts for one saved target. It only drives failure guidance
/// and never changes which request is sent. It resets on success, a target change, or a
/// failure that is neither a timeout nor a cancellation; Stop leaves it unchanged.
struct AgentCodexResumeTimeoutState: Equatable {
    var conversationID: String?
    var rolloutPath: String?
    var consecutiveTimeouts: Int = 0
}

struct AgentCodexNativeToolLivenessState: Equatable {
    struct Key: Hashable {
        let invocationID: UUID?
        let fallbackSignature: String
    }

    struct Execution: Equatable {
        let toolName: String
        let startedAt: Date
        var lastSignalAt: Date
        var processID: String?
        var sawRunningUpdate: Bool = false
    }

    var inFlight: [Key: Execution] = [:]
}

struct AgentBashLiveExecutionState: Equatable {
    private static let runningStatusWords: Set<String> = ["running", "in_progress", "inprogress", "in-progress", "pending"]

    let executionKey: String
    let transcriptItemID: UUID
    let toolName: String
    let invocationID: UUID?
    let fallbackSignature: String
    var processID: String?
    var command: String?
    var statusWord: String?
    var exitCode: Int?
    var output: String?
    var isSummaryOnly: Bool
    var lastSignalAt: Date

    var isRunning: Bool {
        guard let statusWord = statusWord?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !statusWord.isEmpty
        else {
            return exitCode == nil
        }
        return Self.runningStatusWords.contains(statusWord)
    }

    var parsedResult: BashToolResultParser.ParsedResult {
        .init(
            isRunning: isRunning,
            command: command,
            statusWord: statusWord,
            exitCode: exitCode,
            output: output,
            processID: processID,
            isSummaryOnly: isSummaryOnly
        )
    }

    var renderedResultJSON: String {
        BashToolResultParser.resultJSON(
            statusWord: statusWord ?? (isRunning ? "running" : "completed"),
            command: command,
            processID: processID,
            output: output,
            exitCode: exitCode,
            summaryOnly: isSummaryOnly
        )
    }
}

enum AgentInitialStartLocation: Equatable {
    case local
    case newWorktree
    case existingWorktree(AgentExecutionWorktreeSelection)

    var label: String {
        switch self {
        case .local:
            "Work locally"
        case .newWorktree:
            "New worktree"
        case let .existingWorktree(selection):
            selection.label
        }
    }
}

enum AgentInteractionTransport: Equatable {
    case ui
    case mcp(sessionID: UUID, originatingConnectionID: UUID?)
}

struct AgentRunEpochTransitionIntent: Equatable {
    let token: UUID
    let kind: AgentRunEpochTransitionKind
    let expectedCurrentEpoch: AgentRunTurnEpoch?
}

struct AgentExecutionWorktreeSelection: Equatable, Identifiable {
    let repositoryID: String
    let repoKey: String
    let worktreeID: String
    let path: String
    let name: String?
    let branch: String?
    let head: String?
    let isDetached: Bool
    let label: String
    let colorHex: String?
    let isLocked: Bool
    let lockReason: String?
    let isPrunable: Bool
    let prunableReason: String?

    var id: String {
        presentationID
    }

    /// Stable SwiftUI identity for picker presentation. Selection semantics
    /// remain repositoryID + worktreeID; this ID also includes the normalized
    /// path so malformed duplicate Git records cannot collide in ForEach.
    var presentationID: String {
        let checkoutPath = CheckoutPathIdentity.canonicalPathOrOriginal(path)
        return "\(repositoryID)::\(worktreeID)::\(checkoutPath)"
    }
}
