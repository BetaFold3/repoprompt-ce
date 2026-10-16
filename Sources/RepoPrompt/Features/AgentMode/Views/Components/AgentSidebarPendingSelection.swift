import Foundation

/// Sidebar-local, presentation-only record of a row click whose session switch
/// has been deferred so the row highlight can commit before the heavy activation.
///
/// This never decides which session is active; `PromptViewModel.activeComposeTabID`
/// stays the only selection authority. It only lets the clicked row draw as
/// selected until that authority catches up, and lets the last click win when
/// several deferred clicks are queued.
struct AgentSidebarPendingSelection: Equatable {
    struct Entry: Equatable {
        let tabID: UUID
        let token: UInt64
    }

    private(set) var entry: Entry?
    private(set) var latestToken: UInt64 = 0

    /// Records a click on `tabID` and returns the token its deferred switch must present.
    /// Supersedes any earlier deferred click.
    mutating func begin(tabID: UUID) -> UInt64 {
        latestToken &+= 1
        entry = Entry(tabID: tabID, token: latestToken)
        return latestToken
    }

    /// True while `token` belongs to the most recent click; a deferred switch whose
    /// token is no longer current must not run.
    func isCurrent(_ token: UInt64) -> Bool {
        token == latestToken
    }

    /// Invalidates any queued deferred switch and drops the pending highlight
    /// (for example, a later click on the already-active row).
    mutating func cancel() {
        latestToken &+= 1
        entry = nil
    }

    /// Drops the pending highlight only when it still belongs to `token`.
    mutating func clear(ifToken token: UInt64) {
        guard entry?.token == token else { return }
        entry = nil
    }

    /// Drops the pending highlight once the selection authority reports its tab.
    /// Does not invalidate the deferred switch token.
    mutating func clear(ifTabID tabID: UUID?) {
        guard let tabID, entry?.tabID == tabID else { return }
        entry = nil
    }

    /// Drops the pending highlight without invalidating the deferred switch.
    mutating func clearHighlight() {
        entry = nil
    }

    /// The tab the sidebar should draw as selected.
    func resolvedActiveTabID(current: UUID?) -> UUID? {
        entry?.tabID ?? current
    }
}
