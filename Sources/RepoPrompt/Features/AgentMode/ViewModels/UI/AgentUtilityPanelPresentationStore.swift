import Combine
import Foundation
import SwiftUI

/// Presentation state for one window's right utility panel.
///
/// This store owns exactly the two things that belong to a *window*: whether the panel is showing,
/// and how wide it is. Everything the panel displays — segment, compare target, preview document —
/// belongs to a tab and lives in `AgentUtilityPanelTabState`, reaching views through
/// `AgentUtilityPanelUIStore`.
///
/// Visibility is deliberately per-window and *not* persisted: reopening RepoPrompt should not
/// restore a panel the user last used for an unrelated session, and two windows on the same
/// workspace routinely want different answers. The preferred width is the opposite — it is a
/// durable ergonomic preference, so it round-trips through `GlobalSettingsStore` unscaled.
@MainActor
final class AgentUtilityPanelPresentationStore: ObservableObject {
    @Published private(set) var isVisible: Bool = false

    /// User's preferred panel width, unscaled and always inside the resizable range.
    @Published private(set) var preferredWidth: CGFloat

    private let settingsStore: GlobalSettingsStore

    /// - Parameter settingsStore: injection seam for tests; defaults to the shared store.
    ///   Resolved inside the initializer rather than as a default argument because default
    ///   arguments are evaluated in a nonisolated context.
    init(settingsStore: GlobalSettingsStore? = nil) {
        let resolvedStore = settingsStore ?? GlobalSettingsStore.shared
        self.settingsStore = resolvedStore
        preferredWidth = AgentUtilityPanelLayoutMetrics.clampPreferredWidth(
            CGFloat(resolvedStore.agentUtilityPanelWidth())
        )
    }

    // MARK: - Visibility

    func toggleVisibility() {
        isVisible.toggle()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }

    func hide() {
        setVisible(false)
    }

    /// Reveals the panel, for deep links from elsewhere in the UI.
    ///
    /// Callers that also want a particular segment select it on the tab first — the segment is a
    /// property of the session being reviewed, not of the window revealing it.
    func show() {
        setVisible(true)
    }

    // MARK: - Width

    /// Updates the preferred width.
    ///
    /// Pass `commit: false` while a drag is in flight so the settings document is written once on
    /// release rather than on every gesture frame.
    func updatePreferredWidth(_ width: CGFloat, commit: Bool) {
        let clamped = AgentUtilityPanelLayoutMetrics.clampPreferredWidth(width)
        if preferredWidth != clamped {
            preferredWidth = clamped
        }
        settingsStore.setAgentUtilityPanelWidth(Double(clamped), commit: commit)
    }

    /// Restores the default width; bound to a double-click on the drag strip.
    func resetPreferredWidth() {
        updatePreferredWidth(AgentUtilityPanelLayoutMetrics.defaultPanelWidth, commit: true)
    }
}
