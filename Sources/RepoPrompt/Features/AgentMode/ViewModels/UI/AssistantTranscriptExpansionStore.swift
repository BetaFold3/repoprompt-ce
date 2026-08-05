import Foundation

/// Ephemeral, id-keyed store for assistant transcript message expansion state.
///
/// Lives for the duration of one displayed Agent Mode session: `AgentModeChatDetailView` owns
/// one instance per view and calls `reset()` from its existing `currentTabID` change handler —
/// the same place block-level `transcriptBlockExpansion` (activity-cluster/grouped-history
/// collapse) already resets on session switch. This store only ever affects
/// `shouldShowCollapsedAssistantView` rows; tool/activity-cluster/grouped-history collapse state
/// keeps living in `TranscriptPresentationViewState.transcriptBlockExpansion`, untouched.
///
/// Main-actor isolated because SwiftUI observes and mutates this UI state. The environment entry
/// is optional so constructing `EnvironmentValues` never needs to create an actor-isolated store.
@MainActor
final class AssistantTranscriptExpansionStore: ObservableObject {
    @Published private(set) var expandedAssistantIDs: Set<UUID> = []
    @Published private(set) var expandAllAssistants = false

    /// True when `id`'s per-row collapsed preview should be bypassed.
    func isExpanded(_ id: UUID) -> Bool {
        expandAllAssistants || expandedAssistantIDs.contains(id)
    }

    /// Manual chevron toggle. A no-op while "Expand all assistant replies" is active — every row
    /// already renders expanded in that bulk mode; use `restoreAutomaticCollapsing()` to exit it.
    func toggle(_ id: UUID) {
        guard !expandAllAssistants else { return }
        if expandedAssistantIDs.contains(id) {
            expandedAssistantIDs.remove(id)
        } else {
            expandedAssistantIDs.insert(id)
        }
    }

    /// Used by expand-on-match: force one row open regardless of its current state.
    func expand(_ id: UUID) {
        expandedAssistantIDs.insert(id)
    }

    /// Expands every assistant reply without needing to know their IDs up front. Callers should
    /// wrap the triggering action in `performAgentToolCardExpansionStateUpdateWithoutAnimation`
    /// so hundreds of rows don't animate open at once.
    func expandAll() {
        // Bulk mode replaces earlier manual choices. IDs inserted by expand-on-match while bulk
        // mode is active remain open when automatic collapsing is restored.
        expandedAssistantIDs.removeAll()
        expandAllAssistants = true
    }

    /// Reverts to per-row automatic collapsing. Search matches explicitly expanded during bulk
    /// mode remain open; earlier manual choices were discarded when bulk mode began.
    func restoreAutomaticCollapsing() {
        expandAllAssistants = false
    }

    /// Called when the displayed session changes; this store is ephemeral per session.
    func reset() {
        expandAllAssistants = false
        expandedAssistantIDs.removeAll()
    }
}
