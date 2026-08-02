import SwiftUI

/// View-menu command for the Agent Mode right utility panel.
///
/// Routing goes through a windowID-targeted notification rather than touching a window's store
/// directly, matching how the session sidebar toggle and the navigation HUD reach a specific
/// window. The menu owns no state, so the panel's own close chevron and the toolbar toggle stay
/// authoritative.
///
/// Shortcut: ⌥⌘0. A collision audit over every `.keyboardShortcut` call site and every
/// `KeyboardShortcuts.Name` default found ⌥⌘ bound to 1–9 (workspace presets), B, N, P, S, U,
/// `[`, and `]`, but never 0; ⌘0 is likewise unbound (font scale uses ⌘= / ⌘-).
struct AgentUtilityPanelCommands: Commands {
    /// Shared window tracker injected from the app.
    @ObservedObject var windowStatesManager: WindowStatesManager

    /// The window currently in focus, or (as a fallback) the most-recently created one.
    private var focusedWindow: WindowState? {
        windowStatesManager.allWindows.first { $0.isCurrentlyFocused }
            ?? windowStatesManager.latestWindowState
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // Titled as a neutral toggle: SwiftUI `Commands` cannot reliably observe the focused
            // window's panel store, and a stale "Show"/"Hide" label would be worse than none.
            Button("Utility Panel") {
                toggleUtilityPanelForFocusedWindow()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }

    private func toggleUtilityPanelForFocusedWindow() {
        guard let window = focusedWindow else { return }
        NotificationCenter.default.post(
            name: .toggleAgentUtilityPanel,
            object: nil,
            userInfo: [AgentUtilityPanelNotificationUserInfoKey.windowID: window.windowID]
        )
    }
}
