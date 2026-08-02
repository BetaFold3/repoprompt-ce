import SwiftUI

// MARK: - Content View Toolbar Content

struct ContentViewToolbarContent: ToolbarContent {
    let windowState: WindowState
    let recommendationWizardViewModel: RecommendationWizardViewModel?
    @Binding var showRecommendationsPopover: Bool
    @Binding var showMCPServerPopover: Bool

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            agentChatTitleItem
                .sharedBackgroundVisibility(.hidden)
        } else {
            agentChatTitleItem
        }

        // Recommendation wizard button
        ToolbarItem(placement: .automatic) {
            if let wizardVM = recommendationWizardViewModel {
                RecommendationToolbarButtonView(
                    viewModel: wizardVM,
                    showPopover: $showRecommendationsPopover
                )
            }
        }

        // TOOLBAR POPOVER FIX: Pass bindings to prevent state loss during toolbar re-evaluation
        ToolbarItem(placement: .automatic) {
            MCPServerToggleView(windowState: windowState, showPopover: $showMCPServerPopover)
        }

        // Update pill (user-initiated Sparkle UI)
        ToolbarItem(placement: .automatic) {
            UpdateAvailableToolbarPill(sparkleManager: SparkleUpdaterManager.shared)
        }

        // Right utility panel (Changes / Preview)
        ToolbarItem(placement: .automatic) {
            AgentUtilityPanelToolbarToggle(store: windowState.agentUtilityPanel)
        }
    }

    @ToolbarContentBuilder
    private var agentChatTitleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            AgentChatTitleClusterView(
                model: windowState.agentChatTitleCluster,
                menuSnapshot: { [weak windowState] in
                    windowState?.agentChatTitleClusterMenuSnapshot()
                },
                menuActions: windowState.agentChatTitleClusterMenuActions()
            )
        }
    }
}

// MARK: - Utility Panel Toggle

/// Toolbar control for the right utility panel.
///
/// Reads its own state from the window's presentation store so the toolbar highlight, the View
/// menu item, and the panel's own close chevron can never disagree.
private struct AgentUtilityPanelToolbarToggle: View {
    @ObservedObject var store: AgentUtilityPanelPresentationStore

    var body: some View {
        Button {
            store.toggleVisibility()
        } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(store.isVisible ? Color.accentColor : Color.secondary)
        }
        .hoverTooltip(store.isVisible ? "Hide utility panel (\u{2325}\u{2318}0)" : "Show utility panel (\u{2325}\u{2318}0)")
        .accessibilityLabel("Utility panel")
        .accessibilityValue(store.isVisible ? "shown" : "hidden")
    }
}
