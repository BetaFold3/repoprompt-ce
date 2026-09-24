import Foundation

// Shared immutable values for process-owned recovery of provider-accepted scheduled turns.
// No view-model references, provider callbacks, or mutable scheduler state live here.

/// Identity of one retained attempt: rejects stale callbacks and stale UI projections.
struct AgentScheduledSendRecoveryKey: Hashable {
    let sessionID: UUID
    let leaseID: UUID
    let attemptID: UUID
}

/// Stable identity supplied by the owner of an explicit conversation reset. Persistence records
/// its canonical post-reset snapshot only after that save commits.
struct AgentSessionTranscriptResetReceipt: Hashable {
    let id: UUID
}

/// DataService-issued destination captured under the session persistence gate before provider
/// handoff. Recovery reads and writes only ever target this context, never the currently
/// selected workspace or a tab's replacement session.
struct AgentScheduledSendRecoveryContext {
    let sessionID: UUID
    let workspaceID: UUID
    /// Pinned workspace model required by the data service's existing folder/index paths.
    let workspace: WorkspaceModel
    let fileURL: URL
    let agentSessionsFolderURL: URL
    /// Process-local explicit-deletion generation observed at preparation.
    let deletionGeneration: UInt64
    /// Canonical persisted session (encoded) at preparation, used only when the authoritative
    /// file is accidentally missing. Never overwrites an existing file.
    let canonicalSessionSnapshot: Data
    /// Explicit transcript-reset receipt visible when the snapshot was prepared.
    let transcriptResetReceiptAtPreparation: AgentSessionTranscriptResetReceipt?
    /// Process-local committed transcript-reset generation captured with the snapshot. A later
    /// generation wins over every pre-reset transcript item carried by this context.
    let transcriptResetGenerationAtPreparation: UInt64
    /// The same data-service instance whose gate serializes ordinary saves and deletion.
    let dataService: AgentSessionDataService
}

/// Immutable acceptance evidence. Constructed once after provider acceptance; never refreshed
/// from a live working set.
struct AgentScheduledSendAcceptedPayload {
    let context: AgentScheduledSendRecoveryContext
    let attempt: AgentScheduledSendPersist.Attempt
    let receipt: AgentScheduledSendProvenance
    let acceptedItem: AgentChatItem
    /// The dispatching revision supplied to persistence as `expectedUpdatedAt`.
    let expectedUpdatedAt: Date
}

enum AgentScheduledSendRecoveryOutcome {
    case committed(AgentScheduledSendMutationResult)
    /// Explicit session deletion committed before this recovery; nothing was reconstructed.
    case explicitlyDeleted
}

enum AgentScheduledSendRecoveryError: Error, Equatable {
    /// The pinned workspace storage root is not available; recovery must not redirect elsewhere.
    case destinationUnavailable(URL)
    case snapshotUndecodable
}

enum AgentScheduledSendRecoveryAttentionReason: Equatable {
    case persistenceExhausted(lastFailure: String)
    case destinationUnavailable
    case invalidAcceptanceEvidence(String)
    case unresolvedProviderOutcome
}

enum AgentScheduledSendRecoveryPhase: Equatable {
    /// Process ownership is reserved at the guarded handoff; acceptance not yet reported.
    case awaitingProviderOutcome
    case saving(attemptNumber: Int)
    case waitingToRetry(nextAttemptNumber: Int, notBefore: Date)
    /// Automatic work stopped; ownership, payload, and duplicate protection remain retained.
    case needsAttention(AgentScheduledSendRecoveryAttentionReason)
}

struct AgentScheduledSendRecoveryStatus: Equatable {
    let key: AgentScheduledSendRecoveryKey
    let lease: AgentScheduledSendAdmissionLease
    let phase: AgentScheduledSendRecoveryPhase
    let attemptCount: Int
    let hasAcceptedPayload: Bool
}

enum AgentScheduledSendRecoveryChangeKind: String {
    case reserved
    case accepted
    case saving
    case waitingToRetry
    case needsAttention
    case committed
    case explicitlyDeleted
    case released
}

extension Notification.Name {
    /// Retry/attention/terminal changes of a retained recovery. `userInfo`: `sessionID`,
    /// `workspaceID`, `leaseID`, `attemptID`, `changeKind` (raw). Observers query the
    /// coordinator for current status; the payload is not durable authority.
    static let agentScheduledSendRecoveryDidChange = Notification.Name("AgentScheduledSendCoordinator.recoveryDidChange")
    /// Published by the data service after an explicit session deletion committed under the
    /// session gate. `userInfo`: `sessionID` (when parseable), `fileKey` (URL), `generation`.
    static let agentSessionDeletionDidCommit = Notification.Name("AgentSessionDataService.deletionDidCommit")
}
