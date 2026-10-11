import Foundation

extension WorkspaceManagerViewModel: WorkspaceSelectionHost {
    func committedSelectionRevision(for identity: WorkspaceSelectionIdentity) -> UInt64 {
        selectionRevisionForMCP(workspaceID: identity.workspaceID, tabID: identity.tabID)
    }
}
