import SwiftUI

enum SnippetPaletteActivationGate {
    static func shouldActivate(
        requestWindowID: Int?,
        currentWindowID: Int,
        rootRoute: AppRootRoute,
        isMainWindowKey: Bool,
        hasAttachedSheet: Bool,
        isBlockingOverlayVisible: Bool,
        isNavigationHUDPresented: Bool,
        isModelSelectionHUDPresented: Bool,
        activeComposeTabID: UUID?
    ) -> Bool {
        requestWindowID == currentWindowID
            && rootRoute == .main
            && isMainWindowKey
            && !hasAttachedSheet
            && !isBlockingOverlayVisible
            && !isNavigationHUDPresented
            && !isModelSelectionHUDPresented
            && activeComposeTabID != nil
    }
}

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @ObservedObject var remoteDeviceApprovalManager: RemoteDeviceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @StateObject private var agentNavigationHUD = AgentNavigationHUDViewModel()
    @StateObject private var agentModelSelectionHUD = AgentModelSelectionHUDViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastAgentNavigationHUDCommand: (mode: AgentNavigationHUDMode, at: Date)?
    @State private var lastAgentModelSelectionHUDCommand: (mode: AgentModelSelectionHUDMode, at: Date)?

    private var isBlockingOverlayVisible: Bool {
        showWorkspaceSwitchOverlay
            || (viewModel.state.mcpServer.pendingClientID != nil && viewModel.state.mcpServer.isApprovalOverlayVisible)
            || (workspaceApprovalManager.pendingRequest != nil && workspaceApprovalManager.isApprovalOverlayVisible)
            || (remoteDeviceApprovalManager.pendingRequest != nil && remoteDeviceApprovalManager.isApprovalOverlayVisible)
    }

    var body: some View {
        ZStack {
            routedContent
                .blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
                .animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

            if agentNavigationHUD.isPresented {
                AgentNavigationHUDView(
                    viewModel: agentNavigationHUD,
                    windowState: viewModel.state
                )
                .transition(hudTransition)
                .zIndex(998)
            }

            if agentModelSelectionHUD.isPresented {
                AgentModelSelectionHUDView(viewModel: agentModelSelectionHUD)
                    .transition(hudTransition)
                    .zIndex(998)
            }

            if showWorkspaceSwitchOverlay {
                WorkspaceSwitchLoadingOverlay {
                    await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                }
                .zIndex(999)
            }

            // MCP Client Approval Overlay
            if let clientID = viewModel.state.mcpServer.pendingClientID,
               viewModel.state.mcpServer.isApprovalOverlayVisible
            {
                MCPApprovalOverlayView(clientID: clientID)
                    .environmentObject(viewModel.state.mcpServer)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1000)
            }

            // Workspace Operation Approval Overlay
            if let request = workspaceApprovalManager.pendingRequest,
               workspaceApprovalManager.isApprovalOverlayVisible
            {
                WorkspaceApprovalOverlayView(
                    approvalManager: workspaceApprovalManager,
                    request: request
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1001)
            }

            // Remote Device Pairing Approval Overlay
            if let request = remoteDeviceApprovalManager.pendingRequest,
               remoteDeviceApprovalManager.isApprovalOverlayVisible
            {
                RemoteDeviceApprovalOverlayView(
                    approvalManager: remoteDeviceApprovalManager,
                    request: request
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1002)
            }
        }
        .animation(hudAnimation, value: agentNavigationHUD.isPresented)
        .animation(hudAnimation, value: agentModelSelectionHUD.isPresented)
        .onReceive(NotificationCenter.default.publisher(for: .openPromptSnippetPalette)) { note in
            let window = viewModel.state.nsWindow
            let tabID = viewModel.state.promptManager.activeComposeTabID
            guard SnippetPaletteActivationGate.shouldActivate(
                requestWindowID: note.userInfo?[SnippetPaletteNotificationUserInfoKey.windowID] as? Int,
                currentWindowID: viewModel.state.windowID,
                rootRoute: viewModel.rootRoute,
                isMainWindowKey: window?.isKeyWindow == true,
                hasAttachedSheet: window?.attachedSheet != nil,
                isBlockingOverlayVisible: isBlockingOverlayVisible,
                isNavigationHUDPresented: agentNavigationHUD.isPresented,
                isModelSelectionHUDPresented: agentModelSelectionHUD.isPresented,
                activeComposeTabID: tabID
            ), let tabID
            else { return }

            NotificationCenter.default.post(
                name: .performPromptSnippetPaletteActivation,
                object: nil,
                userInfo: [
                    SnippetPaletteNotificationUserInfoKey.windowID: viewModel.state.windowID,
                    SnippetPaletteNotificationUserInfoKey.tabID: tabID
                ]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentNavigationHUD)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            guard !agentModelSelectionHUD.isCommitting else { return }
            guard !isBlockingOverlayVisible else {
                animateHUD {
                    agentNavigationHUD.dismiss()
                    agentModelSelectionHUD.dismiss()
                }
                return
            }
            let rawMode = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentNavigationHUDMode.init(rawValue:)) ?? .currentWindow
            guard !isDuplicateAgentNavigationHUDCommand(mode) else { return }
            guard viewModel.rootRoute != .workspaceEntry || mode == .allAgents else {
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            animateHUD {
                agentModelSelectionHUD.dismiss()
                agentNavigationHUD.present(mode: mode, currentWindow: viewModel.state)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentModelSelectionHUD)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            guard !agentNavigationHUD.isRouting else { return }
            guard !isBlockingOverlayVisible else {
                animateHUD {
                    agentNavigationHUD.dismiss()
                    agentModelSelectionHUD.dismiss()
                }
                return
            }
            let rawMode = note.userInfo?[AgentModelSelectionHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentModelSelectionHUDMode.init(rawValue:)) ?? .switchModel
            guard !isDuplicateAgentModelSelectionHUDCommand(mode) else { return }
            guard viewModel.rootRoute != .workspaceEntry else {
                animateHUD { agentModelSelectionHUD.dismiss() }
                return
            }

            let sourceTabID = viewModel.state.promptManager.activeComposeTabID
            animateHUD {
                agentNavigationHUD.dismiss()
                agentModelSelectionHUD.present(mode: mode) {
                    guard let sourceTabID else {
                        return .unavailable(
                            title: mode.title,
                            message: "No active Agent session is available."
                        )
                    }
                    return viewModel.state.agentModeViewModel.makeModelSelectionHUDPresentation(
                        mode: mode,
                        sourceTabID: sourceTabID,
                        windowID: viewModel.state.windowID
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentNavigationHUDResult)) { note in
            guard noteTargetsCurrentWindow(note), agentNavigationHUD.isPresented else { return }
            (note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.handledRequest] as? AgentNavigationHUDHandledRequest)?.handled = true
            guard let index = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.resultIndex] as? Int else { return }
            Task {
                await agentNavigationHUD.selectItem(atDisplayIndex: index, currentWindow: viewModel.state)
            }
        }
        .onChange(of: isBlockingOverlayVisible) { _, isVisible in
            if isVisible {
                animateHUD {
                    agentNavigationHUD.dismiss()
                    if agentModelSelectionHUD.isCommitting {
                        agentModelSelectionHUD.suspendForBlockingOverlay()
                    } else {
                        agentModelSelectionHUD.dismiss()
                    }
                }
            }
        }
        .onChange(of: agentModelSelectionHUD.isCommitting) { _, isCommitting in
            if !isCommitting, isBlockingOverlayVisible {
                animateHUD { agentModelSelectionHUD.dismiss() }
            }
        }
        .onChange(of: viewModel.state.promptManager.activeComposeTabID) { _, _ in
            if agentNavigationHUD.isPresented, !agentNavigationHUD.isRouting {
                animateHUD { agentNavigationHUD.dismiss() }
            }
            if agentModelSelectionHUD.isPresented, !agentModelSelectionHUD.isRouting {
                animateHUD { agentModelSelectionHUD.dismiss() }
            }
        }
    }

    private var hudTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var hudAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.18, extraBounce: 0)
    }

    private func animateHUD(_ action: () -> Void) {
        withAnimation(hudAnimation) {
            action()
        }
    }

    /// SwiftUI menu commands and the app-focus-gated KeyboardShortcuts handler
    /// can both see the same physical ⌘K event. Coalesce same-mode repeats from
    /// a single keypress so the VM's deliberate toggle semantics don't open and
    /// immediately close the switcher.
    private func isDuplicateAgentNavigationHUDCommand(_ mode: AgentNavigationHUDMode) -> Bool {
        let now = Date()
        defer { lastAgentNavigationHUDCommand = (mode, now) }
        guard let lastAgentNavigationHUDCommand,
              lastAgentNavigationHUDCommand.mode == mode
        else { return false }
        return now.timeIntervalSince(lastAgentNavigationHUDCommand.at) < 0.20
    }

    private func isDuplicateAgentModelSelectionHUDCommand(_ mode: AgentModelSelectionHUDMode) -> Bool {
        let now = Date()
        defer { lastAgentModelSelectionHUDCommand = (mode, now) }
        guard let lastAgentModelSelectionHUDCommand,
              lastAgentModelSelectionHUDCommand.mode == mode
        else { return false }
        return now.timeIntervalSince(lastAgentModelSelectionHUDCommand.at) < 0.20
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let id = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int {
            return id == viewModel.state.windowID
        }
        return true
    }

    @ViewBuilder
    private var routedContent: some View {
        if viewModel.rootRoute == .workspaceEntry {
            WorkspaceEntryRootView(
                workspaceManager: viewModel.workspaceManager,
                windowState: viewModel.state,
                tab: $viewModel.workspaceEntryTab,
                onboardingViewModel: viewModel.onboardingViewModel,
                onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
                onContinueToMain: {
                    viewModel.continueFromOnboarding()
                }
            )
        } else {
            AgentModeView(
                windowState: viewModel.state,
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager
            )
        }
    }
}
