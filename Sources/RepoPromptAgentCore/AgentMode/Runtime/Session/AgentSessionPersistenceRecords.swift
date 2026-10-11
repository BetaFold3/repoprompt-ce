import Foundation
import RepoPromptWorkspace

/// View-model projection of a provider-accepted scheduled turn whose durable finalization is
/// owned by the process coordinator. Carries the shared recovery identity and immutable
/// evidence for UI only; it owns no retry policy, persistence revision, or release decision.
package struct AgentScheduledSendPendingFinalization: Equatable {
    package let key: AgentScheduledSendRecoveryKey
    let lease: AgentScheduledSendAdmissionLease
    package let attempt: AgentScheduledSendPersist.Attempt
    package let receipt: AgentScheduledSendProvenance
    /// Immutable snapshot of the accepted user item (already stamped with `receipt`).
    let acceptedItem: AgentChatItem
    package var status: AgentScheduledSendRecoveryPhase

    package init(
        key: AgentScheduledSendRecoveryKey,
        lease: AgentScheduledSendAdmissionLease,
        attempt: AgentScheduledSendPersist.Attempt,
        receipt: AgentScheduledSendProvenance,
        acceptedItem: AgentChatItem,
        status: AgentScheduledSendRecoveryPhase
    ) {
        self.key = key
        self.lease = lease
        self.attempt = attempt
        self.receipt = receipt
        self.acceptedItem = acceptedItem
        self.status = status
    }

    var scheduleID: UUID {
        lease.scheduleID
    }

    var admittedUpdatedAt: Date {
        lease.admittedUpdatedAt
    }
}

package struct AgentPersistentBindingTransitionToken: Equatable {
    package let tabID: UUID
    package let sessionIdentity: ObjectIdentifier
    package let binding: AgentPersistentSessionBindingIdentity?
    package let transitionGeneration: UInt64
    package let sourceItemsRevision: Int
}

/// Owner-fenced record of a committed peer transcript reset discovered by this owner's own
/// save. The complete local working view stays in the `TabSession` (retained, never given a
/// fresh stamp); only an explicitly confirmed paired reload replaces it.
package struct AgentStaleResetRecovery: Equatable {
    /// Replacement permit captured when the user confirms "Reload latest…": the payload may
    /// only be applied while the local view is exactly what the user saw when confirming.
    package struct ConsentRevision: Equatable {
        package let sourceItemsRevision: Int
        package let persistenceMutationGeneration: UInt64

        package init(
            sourceItemsRevision: Int,
            persistenceMutationGeneration: UInt64
        ) {
            self.sourceItemsRevision = sourceItemsRevision
            self.persistenceMutationGeneration = persistenceMutationGeneration
        }
    }

    package enum Phase: Equatable {
        /// The old run is being stopped through the ordinary cancellation/terminal lifecycle.
        /// A non-nil problem means the single stop attempt did not reach quiescence.
        case stopping(problem: String?)
        /// Ingestion is quiescent; the retained view is unsavable until an explicit reload.
        /// A non-nil problem reports the last failed reload attempt.
        case retained(problem: String?)
        /// One confirmed paired read is in flight under the captured permit.
        case reloading(attemptID: UUID, consent: ConsentRevision)
    }

    package let id: UUID
    package let tabID: UUID
    package let sessionIdentity: ObjectIdentifier
    package let binding: AgentPersistentSessionBindingIdentity
    package let bindingTransitionGeneration: UInt64
    package let workspaceID: UUID
    package let workspaceOwner: AgentWorkspaceSessionIndexStore.SessionIndexOwner?
    /// The rejected lifetime/reset state, kept for comparison only (never save authority).
    package let rejectedPersistenceState: AgentSessionPersistenceState
    /// Reset generation reported by the failed save; a replacement must cover it.
    package let observedResetGeneration: UInt64
    package var phase: Phase

    package init(
        id: UUID,
        tabID: UUID,
        sessionIdentity: ObjectIdentifier,
        binding: AgentPersistentSessionBindingIdentity,
        bindingTransitionGeneration: UInt64,
        workspaceID: UUID,
        workspaceOwner: AgentWorkspaceSessionIndexStore.SessionIndexOwner?,
        rejectedPersistenceState: AgentSessionPersistenceState,
        observedResetGeneration: UInt64,
        phase: Phase
    ) {
        self.id = id
        self.tabID = tabID
        self.sessionIdentity = sessionIdentity
        self.binding = binding
        self.bindingTransitionGeneration = bindingTransitionGeneration
        self.workspaceID = workspaceID
        self.workspaceOwner = workspaceOwner
        self.rejectedPersistenceState = rejectedPersistenceState
        self.observedResetGeneration = observedResetGeneration
        self.phase = phase
    }
}

/// Removal admission recorded by the pre-destructive preflight for every target tab: the
/// recovery episode (if any) the user consented to discard. The final removal boundary
/// revalidates the tab against it; an episode first discovered after the preflight is not
/// covered and vetoes the removal.
package struct AgentStaleResetRemovalAdmission: Equatable {
    package let id: UUID
    /// The removal operation this admission belongs to.
    let operationID: UUID
    /// Session object and binding the admission was granted for; a replaced owner or a
    /// changed binding is not covered.
    let sessionIdentity: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity?
    let transitionGeneration: UInt64
    package let consentedEpisodeID: UUID?
    /// Set when the owning operation's commit begins: rebinding and new work are refused and
    /// no debounced save is scheduled (the operation's final save owns durability).
    package var isReserved: Bool = false
    /// How the operation's final save for this owner settled.
    package enum FinalSaveKind: Equatable {
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
    package var finalSaveRevision: Int?
    /// Persistence-mutation generation of that same snapshot.
    package var finalSaveMutationGeneration: UInt64?
    package var finalSaveKind: FinalSaveKind?
    /// Set after the operation's final save: no later save may run for this owner.
    package var isFinalSaveCompleted: Bool = false
    /// Set synchronously by the final batch commit: the owner is retired for removal.
    package var isCommitted: Bool = false

    package init(
        id: UUID,
        operationID: UUID,
        sessionIdentity: ObjectIdentifier,
        binding: AgentPersistentSessionBindingIdentity?,
        transitionGeneration: UInt64,
        consentedEpisodeID: UUID?,
        isReserved: Bool = false,
        finalSaveRevision: Int? = nil,
        finalSaveMutationGeneration: UInt64? = nil,
        finalSaveKind: FinalSaveKind? = nil,
        isFinalSaveCompleted: Bool = false,
        isCommitted: Bool = false
    ) {
        self.id = id
        self.operationID = operationID
        self.sessionIdentity = sessionIdentity
        self.binding = binding
        self.transitionGeneration = transitionGeneration
        self.consentedEpisodeID = consentedEpisodeID
        self.isReserved = isReserved
        self.finalSaveRevision = finalSaveRevision
        self.finalSaveMutationGeneration = finalSaveMutationGeneration
        self.finalSaveKind = finalSaveKind
        self.isFinalSaveCompleted = isFinalSaveCompleted
        self.isCommitted = isCommitted
    }

    /// No debounced save may be scheduled once the operation owns durability for this owner.
    package var blocksScheduledSaves: Bool {
        isReserved || isFinalSaveCompleted || isCommitted
    }
}

/// Result of one paired load operation. `attemptID` is the immutable identity of the load
/// that produced it; callers compare it with the session's current attempt before acting on
/// the outcome, so an obsolete (cancelled or superseded) load can never change a newer
/// load's readiness or published outcome.
package struct AgentPersistedLoadOutcome: Equatable {
    package let attemptID: UUID?
    package let disposition: AgentTabSession.PersistedLoadDisposition

    package init(
        attemptID: UUID?,
        disposition: AgentTabSession.PersistedLoadDisposition
    ) {
        self.attemptID = attemptID
        self.disposition = disposition
    }
}

package struct AgentPersistentSessionBindingIdentity: Equatable, Hashable {
    package let tabID: UUID
    package let sessionID: UUID
    package let generation: UUID

    package init(tabID: UUID, sessionID: UUID, generation: UUID = UUID()) {
        self.tabID = tabID
        self.sessionID = sessionID
        self.generation = generation
    }
}
