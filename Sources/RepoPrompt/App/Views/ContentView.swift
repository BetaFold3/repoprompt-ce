import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var workspaceApprovalManager = WorkspaceApprovalManager.shared
    @StateObject private var remoteDeviceApprovalManager = RemoteDeviceApprovalManager.shared

    @State private var showWorkspaceSetup = false

    /// Sheet for naming a brand-new preset
    @State private var showCreatePresetSheet = false

    @State private var showMCPStatusSheet = false
    @State private var showRecommendationWizardSheet = false
    @State private var showWorkspaceSwitchOverlay = false

    /// Recommendation wizard view model (lazy initialized)
    @State private var recommendationWizardViewModel: RecommendationWizardViewModel?

    /// Initialize with a single WindowState,
    /// then build a ContentViewModel from it.
    init(windowState: WindowState) {
        _viewModel = StateObject(wrappedValue: ContentViewModel(state: windowState))
    }

    var body: some View {
        ContentRootShellView(
            viewModel: viewModel,
            workspaceApprovalManager: workspaceApprovalManager,
            remoteDeviceApprovalManager: remoteDeviceApprovalManager,
            showWorkspaceSwitchOverlay: $showWorkspaceSwitchOverlay
        )
        .toolbar {
            ContentViewToolbarContent(windowState: viewModel.state)
        }
        .onAppear {
            showWorkspaceSwitchOverlay = viewModel.workspaceManager.isWorkspaceSwitchOverlayVisible

            // Evaluate initial route (workspace entry vs main) and auto-onboarding
            viewModel.evaluateInitialRouteIfNeeded()

            // Initialize recommendation wizard view model
            _ = ensureRecommendationWizardViewModel()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .workspaceSwitchOverlayDidChange,
                object: viewModel.workspaceManager
            )
        ) { notification in
            if let isVisible = notification.userInfo?["isVisible"] as? Bool {
                showWorkspaceSwitchOverlay = isVisible
            }
        }
        .workspaceSwitchConfirmation(manager: viewModel.workspaceManager)
        .modifier(ContentViewSheetPresenter(
            viewModel: viewModel,
            showWorkspaceSetup: $showWorkspaceSetup,
            showCreatePresetSheet: $showCreatePresetSheet,
            showMCPStatusSheet: $showMCPStatusSheet,
            showRecommendationWizardSheet: $showRecommendationWizardSheet,
            recommendationWizardViewModel: recommendationWizardViewModel
        ))
        .modifier(ContentViewNotificationHandler(
            windowState: viewModel.state,
            onShowWizard: { viewModel.presentSetupGuide() },
            onShowCreatePresetSheet: { showCreatePresetSheet = true },
            onShowMCPStatusSheet: { showMCPStatusSheet = true },
            onShowRecommendationWizard: {
                let wizardViewModel = ensureRecommendationWizardViewModel()
                wizardViewModel.refresh(navigation: .resetToIntro)
                showRecommendationWizardSheet = true
            },
            onAppWillRestartForUpdate: { closeAllSheets() }
        ))
        // Close all sheets when a connection approval request comes in
        .onChange(of: viewModel.state.mcpServer.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        // Close all sheets when a workspace approval request comes in
        .onChange(of: workspaceApprovalManager.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        // Close all sheets when a remote pairing approval request comes in
        .onChange(of: remoteDeviceApprovalManager.isApprovalOverlayVisible) { _, isVisible in
            if isVisible {
                closeAllSheets()
            }
        }
        .environmentObject(viewModel.workspaceManager)
    }

    private func ensureRecommendationWizardViewModel() -> RecommendationWizardViewModel {
        if let recommendationWizardViewModel {
            return recommendationWizardViewModel
        }

        let engine = AutoRecommendationEngine(
            settingsStore: GlobalSettingsStore.shared,
            profileSettingsManager: GlobalSettingsStore.shared,
            apiSettingsViewModel: viewModel.apiSettingsViewModel
        )
        let wizardViewModel = RecommendationWizardViewModel(
            engine: engine,
            settingsStore: GlobalSettingsStore.shared,
            workspaceManager: viewModel.workspaceManager,
            windowID: viewModel.state.windowID
        )
        recommendationWizardViewModel = wizardViewModel
        return wizardViewModel
    }

    private func closeAllSheets() {
        withAnimation {
            showWorkspaceSetup = false
            showCreatePresetSheet = false
            showMCPStatusSheet = false
            showRecommendationWizardSheet = false
        }
    }
}
