import SwiftUI

struct AgentModeDetailWithSidebarView: View {
    let agentModeVM: AgentModeViewModel
    let runtimeVM: AgentRuntimeSidebarViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var utilityPanel: AgentUtilityPanelPresentationStore
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let oracleViewModel: OracleViewModel
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    #if DEBUG
        let stressHarness: AgentChatStressHarness?
    #endif
    let windowID: Int
    let currentTabID: UUID?
    let codexManagedLoginAction: CodexManagedLoginAction

    @State private var isContextBuilderQuestionPresented = false

    #if DEBUG
        init(
            agentModeVM: AgentModeViewModel,
            runtimeVM: AgentRuntimeSidebarViewModel,
            statusPillsUI: AgentStatusPillsUIStore,
            utilityPanel: AgentUtilityPanelPresentationStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            stressHarness: AgentChatStressHarness?,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.agentModeVM = agentModeVM
            self.runtimeVM = runtimeVM
            _statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
            _utilityPanel = ObservedObject(wrappedValue: utilityPanel)
            self.contextBuilderAgentVM = contextBuilderAgentVM
            self.oracleViewModel = oracleViewModel
            self.promptManager = promptManager
            self.workspaceSearchService = workspaceSearchService
            self.selectionCoordinator = selectionCoordinator
            self.stressHarness = stressHarness
            self.windowID = windowID
            self.currentTabID = currentTabID
            self.codexManagedLoginAction = codexManagedLoginAction
        }

        init(
            agentModeVM: AgentModeViewModel,
            runtimeMetricsUI: AgentRuntimeMetricsUIStore,
            statusPillsUI: AgentStatusPillsUIStore,
            utilityPanel: AgentUtilityPanelPresentationStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            stressHarness: AgentChatStressHarness?,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.init(
                agentModeVM: agentModeVM,
                runtimeVM: runtimeMetricsUI.runtimeVM,
                statusPillsUI: statusPillsUI,
                utilityPanel: utilityPanel,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                stressHarness: stressHarness,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        }
    #else
        init(
            agentModeVM: AgentModeViewModel,
            runtimeVM: AgentRuntimeSidebarViewModel,
            statusPillsUI: AgentStatusPillsUIStore,
            utilityPanel: AgentUtilityPanelPresentationStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.agentModeVM = agentModeVM
            self.runtimeVM = runtimeVM
            _statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
            _utilityPanel = ObservedObject(wrappedValue: utilityPanel)
            self.contextBuilderAgentVM = contextBuilderAgentVM
            self.oracleViewModel = oracleViewModel
            self.promptManager = promptManager
            self.workspaceSearchService = workspaceSearchService
            self.selectionCoordinator = selectionCoordinator
            self.windowID = windowID
            self.currentTabID = currentTabID
            self.codexManagedLoginAction = codexManagedLoginAction
        }

        init(
            agentModeVM: AgentModeViewModel,
            runtimeMetricsUI: AgentRuntimeMetricsUIStore,
            statusPillsUI: AgentStatusPillsUIStore,
            utilityPanel: AgentUtilityPanelPresentationStore,
            contextBuilderAgentVM: ContextBuilderAgentViewModel,
            oracleViewModel: OracleViewModel,
            promptManager: PromptViewModel,
            workspaceSearchService: WorkspaceSearchService,
            selectionCoordinator: WorkspaceSelectionCoordinator,
            windowID: Int,
            currentTabID: UUID?,
            codexManagedLoginAction: @escaping CodexManagedLoginAction
        ) {
            self.init(
                agentModeVM: agentModeVM,
                runtimeVM: runtimeMetricsUI.runtimeVM,
                statusPillsUI: statusPillsUI,
                utilityPanel: utilityPanel,
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        }
    #endif

    /// One body for both build configurations.
    ///
    /// The DEBUG-only stress harness now varies through `transcriptColumn` and the two
    /// `…IfNeeded` helpers instead of duplicating the whole view, so the utility panel mounts in
    /// exactly one place and release builds cannot drift from debug builds.
    var body: some View {
        AgentUtilityPanelLayout(store: utilityPanel) {
            transcriptColumn
        } panel: {
            AgentUtilityPanelView(
                store: utilityPanel,
                utilityPanelUI: agentModeVM.ui.utilityPanel,
                agentModeVM: agentModeVM
            )
        }
        .onAppear {
            syncActiveTabUIState(tabID: currentTabID)
            bootstrapStressHarnessIfNeeded(tabID: currentTabID)
        }
        .onReceive(contextBuilderAgentVM.$pendingAskUser) { _ in
            syncContextBuilderQuestionPresentation()
        }
        .onReceive(promptManager.fileManager.$selectionStateRevision.removeDuplicates()) { _ in
            syncRuntimeMetricsSelectionCountFromActiveUIIfCurrent()
        }
        .onReceive(selectionCoordinator.changes) { change in
            syncRuntimeMetricsSelectionCount(from: change)
        }
        .onChange(of: currentTabID) { _, tabID in
            syncActiveTabUIState(tabID: tabID)
            bootstrapStressHarnessIfNeeded(tabID: tabID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAgentUtilityPanel)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            utilityPanel.toggleVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentUtilityPanel)) { note in
            guard noteTargetsCurrentWindow(note) else { return }
            utilityPanel.show()
        }
        .onDisappear { pauseStressHarnessIfNeeded() }
    }

    /// The transcript side of the layout, including the DEBUG-only stress harness overlay.
    @ViewBuilder
    private var transcriptColumn: some View {
        #if DEBUG
            chatDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let stressHarness, stressHarness.configuration.showOverlay {
                        AgentChatStressHarnessPanel(harness: stressHarness, currentTabID: currentTabID)
                            .padding(.top, 14)
                            .padding(.trailing, 14)
                    }
                }
        #else
            chatDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// `AgentModeChatDetailView` declares its stress-harness member only in DEBUG, so this is the
    /// single place where the two build configurations legitimately differ.
    private var chatDetail: AgentModeChatDetailView {
        #if DEBUG
            AgentModeChatDetailView(
                agentModeVM: agentModeVM,
                transcriptUI: agentModeVM.ui.transcript,
                runInteractionUI: agentModeVM.ui.runInteraction,
                statusPillsUI: statusPillsUI,
                contextBuilderAgentVM: contextBuilderAgentVM,
                isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                stressHarness: stressHarness,
                runtimeVM: runtimeVM,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        #else
            AgentModeChatDetailView(
                agentModeVM: agentModeVM,
                transcriptUI: agentModeVM.ui.transcript,
                runInteractionUI: agentModeVM.ui.runInteraction,
                statusPillsUI: statusPillsUI,
                contextBuilderAgentVM: contextBuilderAgentVM,
                isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
                oracleViewModel: oracleViewModel,
                promptManager: promptManager,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                runtimeVM: runtimeVM,
                windowID: windowID,
                currentTabID: currentTabID,
                codexManagedLoginAction: codexManagedLoginAction
            )
        #endif
    }

    // MARK: - Stress harness (DEBUG only)

    private func bootstrapStressHarnessIfNeeded(tabID: UUID?) {
        #if DEBUG
            stressHarness?.bootstrapIfNeeded(currentTabID: tabID)
        #endif
    }

    private func pauseStressHarnessIfNeeded() {
        #if DEBUG
            stressHarness?.pause()
        #endif
    }

    // MARK: - UI state sync

    /// The `onAppear` / `onChange(of: currentTabID)` resync ritual, previously duplicated.
    private func syncActiveTabUIState(tabID: UUID?) {
        syncContextBuilderQuestionPresentation()
        agentModeVM.syncComposerUIState(tabID: tabID)
        agentModeVM.syncTranscriptUIState()
        agentModeVM.syncRunInteractionUIState()
        agentModeVM.syncStatusPillsUIState()
        agentModeVM.syncUtilityPanelUIState()
        syncRuntimeMetricsSelectionCount()
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        AgentUtilityPanelNotificationTarget.matches(note, windowID: windowID)
    }

    private func syncContextBuilderQuestionPresentation() {
        isContextBuilderQuestionPresented = contextBuilderAgentVM.pendingAskUser(for: currentTabID) != nil
    }

    private var runtimeMetricsTargetTabID: UUID? {
        currentTabID ?? promptManager.activeComposeTabID
    }

    private func syncRuntimeMetricsSelectionCount() {
        guard let targetTabID = runtimeMetricsTargetTabID,
              let snapshot = selectionCoordinator.selectionSnapshot(for: targetTabID, flushPendingUIIfActive: true)
        else {
            agentModeVM.syncRuntimeMetricsUIState(liveSelectedFileCount: nil, liveSelectionSummary: nil)
            return
        }
        syncRuntimeMetricsSelectionCount(selection: snapshot.selection)
    }

    private func syncRuntimeMetricsSelectionCountFromActiveUIIfCurrent() {
        guard runtimeMetricsTargetTabID == selectionCoordinator.activeTabID() else { return }
        syncRuntimeMetricsSelectionCount()
    }

    private func syncRuntimeMetricsSelectionCount(from change: WorkspaceSelectionCoordinator.Change) {
        guard change.tabID == runtimeMetricsTargetTabID else { return }
        syncRuntimeMetricsSelectionCount(selection: change.selection)
    }

    private func syncRuntimeMetricsSelectionCount(selection: StoredSelection) {
        let summary = AgentContextExportResolver.selectionSummary(for: selection)
        agentModeVM.syncRuntimeMetricsUIState(
            liveSelectedFileCount: summary.totalExplicitFileCount,
            liveSelectionSummary: summary
        )
    }
}
