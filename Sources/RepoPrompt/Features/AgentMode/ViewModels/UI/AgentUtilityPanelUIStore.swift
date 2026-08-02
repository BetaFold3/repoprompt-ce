import Foundation

/// Active-tab projection of `AgentUtilityPanelTabState`.
///
/// The panel state itself is embedded rather than flattened field by field: it is already a value
/// type with a meaningful `Equatable` conformance, so embedding keeps one definition of "what the
/// panel remembers" and lets `update(_:)` reject a redundant publish with a single comparison.
struct AgentUtilityPanelUISnapshot: Equatable {
    var currentTabID: UUID?
    var panel: AgentUtilityPanelTabState

    /// Shown segment, read often enough by the panel chrome to be worth naming here.
    var segment: AgentUtilityPanelSegment {
        panel.segment
    }

    static let empty = AgentUtilityPanelUISnapshot(
        currentTabID: nil,
        panel: AgentUtilityPanelTabState()
    )
}

@MainActor
final class AgentUtilityPanelUIStore: ObservableObject {
    @Published private(set) var snapshot: AgentUtilityPanelUISnapshot = .empty

    func update(_ snapshot: AgentUtilityPanelUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("utilityPanel", published: false)
            #endif
            return
        }
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "utilityPanel",
                published: true,
                details: [
                    "tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID),
                    "segment": snapshot.panel.segment.rawValue,
                    "compareSelection": snapshot.panel.compareSelection.rawValue,
                    "diffViewMode": snapshot.panel.diffViewMode.rawValue,
                    "expandedFileCount": String(snapshot.panel.expandedFilePaths.count),
                    "hasPreviewDocument": String(snapshot.panel.previewDocument != nil)
                ]
            )
        #endif
        self.snapshot = snapshot
    }
}
