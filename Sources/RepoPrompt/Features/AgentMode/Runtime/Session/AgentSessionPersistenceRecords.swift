import Foundation
import RepoPromptWorkspace

/// View-model projection of a provider-accepted scheduled turn whose durable finalization is
/// owned by the process coordinator. Carries the shared recovery identity and immutable
/// evidence for UI only; it owns no retry policy, persistence revision, or release decision.
struct AgentScheduledSendPendingFinalization: Equatable {
    let key: AgentScheduledSendRecoveryKey
    let lease: AgentScheduledSendAdmissionLease
    let attempt: AgentScheduledSendPersist.Attempt
    let receipt: AgentScheduledSendProvenance
    /// Immutable snapshot of the accepted user item (already stamped with `receipt`).
    let acceptedItem: AgentChatItem
    var status: AgentScheduledSendRecoveryPhase

    var scheduleID: UUID {
        lease.scheduleID
    }

    var admittedUpdatedAt: Date {
        lease.admittedUpdatedAt
    }
}

struct AgentPersistentBindingTransitionToken: Equatable {
    let tabID: UUID
    let sessionIdentity: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity?
    let transitionGeneration: UInt64
    let sourceItemsRevision: Int
}

/// Owner-fenced record of a committed peer transcript reset discovered by this owner's own
/// save. The complete local working view stays in the `TabSession` (retained, never given a
/// fresh stamp); only an explicitly confirmed paired reload replaces it.
struct AgentStaleResetRecovery: Equatable {
    /// Replacement permit captured when the user confirms "Reload latest…": the payload may
    /// only be applied while the local view is exactly what the user saw when confirming.
    struct ConsentRevision: Equatable {
        let sourceItemsRevision: Int
        let persistenceMutationGeneration: UInt64
    }

    enum Phase: Equatable {
        /// The old run is being stopped through the ordinary cancellation/terminal lifecycle.
        /// A non-nil problem means the single stop attempt did not reach quiescence.
        case stopping(problem: String?)
        /// Ingestion is quiescent; the retained view is unsavable until an explicit reload.
        /// A non-nil problem reports the last failed reload attempt.
        case retained(problem: String?)
        /// One confirmed paired read is in flight under the captured permit.
        case reloading(attemptID: UUID, consent: ConsentRevision)
    }

    let id: UUID
    let tabID: UUID
    let sessionIdentity: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity
    let bindingTransitionGeneration: UInt64
    let workspaceID: UUID
    let workspaceOwner: AgentWorkspaceSessionIndexStore.SessionIndexOwner?
    /// The rejected lifetime/reset state, kept for comparison only (never save authority).
    let rejectedPersistenceState: AgentSessionPersistenceState
    /// Reset generation reported by the failed save; a replacement must cover it.
    let observedResetGeneration: UInt64
    var phase: Phase
}

/// Removal admission recorded by the pre-destructive preflight for every target tab: the
/// recovery episode (if any) the user consented to discard. The final removal boundary
/// revalidates the tab against it; an episode first discovered after the preflight is not
/// covered and vetoes the removal.
struct AgentStaleResetRemovalAdmission: Equatable {
    let id: UUID
    /// The removal operation this admission belongs to.
    let operationID: UUID
    /// Session object and binding the admission was granted for; a replaced owner or a
    /// changed binding is not covered.
    let sessionIdentity: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity?
    let transitionGeneration: UInt64
    let consentedEpisodeID: UUID?
    /// Set when the owning operation's commit begins: rebinding and new work are refused and
    /// no debounced save is scheduled (the operation's final save owns durability).
    var isReserved: Bool = false
    /// How the operation's final save for this owner settled.
    enum FinalSaveKind: Equatable {
        /// Nothing was dirty (or persistence is suppressed): the live state is the durable state.
        case clean
        /// A snapshot was durably written; `finalSaveRevision`/`finalSaveMutationGeneration`
        /// identify exactly that snapshot, not the live state observed afterwards.
        case written
        /// The save discovered a committed peer reset: the owner entered stop-and-retain and is
        /// judged by consent, never by settlement.
        case recovery
        /// Dirty state that could not be written (no authority, missing file, deferred).
        case unsaved
    }

    /// Content revision of the snapshot the operation's final save made durable (or of the
    /// clean live state); a live revision that differs is not settled.
    var finalSaveRevision: Int?
    /// Persistence-mutation generation of that same snapshot.
    var finalSaveMutationGeneration: UInt64?
    var finalSaveKind: FinalSaveKind?
    /// Set after the operation's final save: no later save may run for this owner.
    var isFinalSaveCompleted: Bool = false
    /// Set synchronously by the final batch commit: the owner is retired for removal.
    var isCommitted: Bool = false

    /// No debounced save may be scheduled once the operation owns durability for this owner.
    var blocksScheduledSaves: Bool {
        isReserved || isFinalSaveCompleted || isCommitted
    }
}

/// Result of one paired load operation. `attemptID` is the immutable identity of the load
/// that produced it; callers compare it with the session's current attempt before acting on
/// the outcome, so an obsolete (cancelled or superseded) load can never change a newer
/// load's readiness or published outcome.
struct AgentPersistedLoadOutcome: Equatable {
    let attemptID: UUID?
    let disposition: AgentTabSession.PersistedLoadDisposition
}
