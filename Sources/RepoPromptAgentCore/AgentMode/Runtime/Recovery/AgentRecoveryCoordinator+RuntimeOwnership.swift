import Foundation

// Spec R6 (Phase 3) integration of the runtime-ownership registry into recovery admission,
// scheduling and the recovery catalog. The registry alone decides runtime state; the coordinator
// only holds its latest restriction snapshot (main-actor readable) and asks for Refresh or Let
// finish. Existing runtime records are enforced whether or not new registration is active.
//
// - Send admission refuses a session whose native conversation may have another writer, or whose
//   worktree has an unassociated possible writer (`AgentRuntimeRestrictionSnapshot.blocksSend`).
// - Automatic work (scheduled sends, new-session starts) is also refused while any restricting
//   runtime (tool-only survivors included) overlaps the worktree.
// - Unidentifiable records or an unreadable runtime directory are global uncertainty: a visible
//   warning, and no ownership-dependent work is admitted anywhere.
// - Recovered Stop is not offered (production Stop stays disabled).

package extension AgentRecoveryCoordinator {
    /// Attaches the app's single registry before startup and the windows' session-key lookup. The
    /// registry's change handler pulls fresh snapshots; nothing polls.
    func attachProcessRegistry(
        _ registry: AgentProcessRegistry,
        ownershipKeys: @escaping @MainActor (UUID) -> [AgentRuntimeOwnershipKeys]
    ) {
        processRegistry = registry
        runtimeOwnershipKeys = ownershipKeys
    }

    /// Whether runtime ownership is enforced by this coordinator.
    var hasProcessRegistry: Bool {
        processRegistry != nil
    }

    /// The keys of every window hosting `sessionID` plus the session itself, so a runtime associated
    /// with the session restricts it before any native conversation is known and when no window
    /// hosts it.
    private func sessionOwnershipKeys(_ sessionID: UUID) -> [AgentRuntimeOwnershipKeys] {
        runtimeOwnershipKeys(sessionID) + [AgentRuntimeOwnershipKeys(sessionID: sessionID, conversationID: nil, worktreePath: nil)]
    }

    // MARK: Admission and scheduling

    /// The refusal reason when runtime ownership blocks sending to `sessionID`; `nil` otherwise.
    func runtimeSendRefusalReason(sessionID: UUID) -> String? {
        guard processRegistry != nil else { return nil }
        if runtimeRestrictions.hasGlobalUncertainty {
            return Self.runtimeGlobalUncertaintyReason
        }
        for keys in sessionOwnershipKeys(sessionID) {
            if let restriction = runtimeRestrictions.sendRestriction(for: keys) {
                return Self.runtimeSendRefusalReason(restriction)
            }
        }
        return nil
    }

    /// Whether runtime ownership blocks automatic work (scheduled sends) for `sessionID`: the keys of
    /// every window hosting it plus `additionalKeys` (the caller's own session object, which may not
    /// be installed in a window yet).
    /// `worktreeUnresolved`: the caller could not resolve the session's worktree, so a tool-only or
    /// unassociated survivor on it cannot be ruled out while any restriction carries a worktree; the
    /// session then stays blocked (conservative). With no worktree-carrying restriction there is
    /// nothing an unresolved worktree could overlap, so it blocks nothing.
    func runtimeBlocksAutomaticWork(
        sessionID: UUID,
        additionalKeys: [AgentRuntimeOwnershipKeys] = [],
        worktreeUnresolved: Bool = false
    ) -> Bool {
        guard processRegistry != nil else { return false }
        if runtimeRestrictions.hasGlobalUncertainty { return true }
        if worktreeUnresolved, runtimeRestrictions.restrictions.contains(where: { !$0.worktreePaths.isEmpty }) { return true }
        return (sessionOwnershipKeys(sessionID) + additionalKeys).contains { runtimeRestrictions.blocksAutomaticWork($0) }
    }

    /// Whether runtime ownership blocks automatic work on `worktreePath` (new-session starts).
    func runtimeBlocksAutomaticWork(worktreePath: String?) -> Bool {
        guard processRegistry != nil else { return false }
        if runtimeRestrictions.hasGlobalUncertainty { return true }
        guard let worktreePath else { return false }
        return runtimeRestrictions.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: worktreePath))
    }

    /// The runtime restriction that blocks sending to `sessionID`, if any (banner presentation).
    func runtimeSendRestriction(sessionID: UUID) -> AgentRuntimeRestriction? {
        guard processRegistry != nil else { return nil }
        for keys in sessionOwnershipKeys(sessionID) {
            if let restriction = runtimeRestrictions.sendRestriction(for: keys) {
                return restriction
            }
        }
        return nil
    }

    static let runtimeGlobalUncertaintyReason =
        "Agent processes from an earlier launch couldn't be identified, so RepoPrompt can't tell which conversations they may still be writing. Sending stays paused until Refresh can check them."

    // MARK: Actions

    /// The Refresh action: retries a failed runtime-directory read, then one coalesced discovery
    /// pass; the published snapshot follows.
    func refreshRuntimeOwnership() async {
        guard let registry = processRegistry else { return }
        await registry.refreshRetryingStorage()
        pullRuntimeRestrictions()
    }

    /// Persists Let finish for exactly the displayed runtime revision; it keeps watching and keeps
    /// every restriction until the family exits. Returns a failure message, or `nil`.
    func letRuntimeFinish(runtimeID: UUID, expectedRevision: AgentRecoveryRecordRevision) async -> String? {
        guard let registry = processRegistry else { return "Runtime ownership isn't available." }
        do {
            try await registry.letFinish(runtimeID: runtimeID, expectedRevision: expectedRevision)
            pullRuntimeRestrictions()
            return nil
        } catch {
            pullRuntimeRestrictions()
            return "This process changed. Review it again."
        }
    }
}

extension AgentRecoveryCoordinator {
    /// Startup step (before readiness): loads and discovers every runtime record, then subscribes.
    func startRuntimeOwnership() async {
        guard let registry = processRegistry else { return }
        await registry.setChangeHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pullRuntimeRestrictions()
            }
        }
        runtimeSnapshotRequest &+= 1
        let snapshot = await registry.start()
        adoptRuntimeRestrictions(snapshot)
    }

    /// Re-reads the registry's current snapshot; a later pull supersedes an earlier one.
    private func pullRuntimeRestrictions() {
        guard let registry = processRegistry else { return }
        runtimeSnapshotRequest &+= 1
        let request = runtimeSnapshotRequest
        Task { @MainActor [weak self] in
            let snapshot = await registry.restrictionSnapshot()
            guard let self, runtimeSnapshotRequest == request else { return }
            adoptRuntimeRestrictions(snapshot)
        }
    }

    private func adoptRuntimeRestrictions(_ snapshot: AgentRuntimeRestrictionSnapshot) {
        guard snapshot != runtimeRestrictions else { return }
        runtimeRestrictions = snapshot
        postCoordinatorDidChange()
    }

    static func runtimeSendRefusalReason(_ restriction: AgentRuntimeRestriction) -> String {
        if restriction.conversationIDs.isEmpty {
            return "An agent process that isn't attached to a known conversation may still be running in this worktree. Sending stays paused until it exits or Refresh confirms it stopped."
        }
        return "Another agent process may still be writing this conversation. Sending stays paused until it exits or Refresh confirms it stopped."
    }
}
