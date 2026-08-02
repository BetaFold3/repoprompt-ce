import Foundation

extension AgentModeViewModel {
    func makeUtilityPanelUISnapshot() -> AgentUtilityPanelUISnapshot {
        AgentUtilityPanelUISnapshot(
            currentTabID: currentTabID,
            panel: currentTabID.flatMap { sessions[$0] }?.utilityPanel ?? AgentUtilityPanelTabState()
        )
    }

    func syncUtilityPanelUIState() {
        ui.utilityPanel.update(makeUtilityPanelUISnapshot())
    }

    /// Panel state for a tab, without materializing a session for a tab that has none.
    func utilityPanelState(tabID: UUID?) -> AgentUtilityPanelTabState {
        guard let tabID, let session = sessions[tabID] else { return AgentUtilityPanelTabState() }
        return session.utilityPanel
    }

    // MARK: - Segment

    func selectUtilityPanelSegment(_ segment: AgentUtilityPanelSegment, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.select(segment: segment) }
    }

    // MARK: - Changes target

    func selectUtilityPanelRootOverride(_ rootID: UUID?, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.selectRootOverride(rootID) }
    }

    func setUtilityPanelCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.setCompareSelection(selection) }
    }

    func setUtilityPanelDiffViewMode(_ mode: AgentChangesDiffViewMode, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.setDiffViewMode(mode) }
    }

    func setUtilityPanelChangesFilter(_ filter: AgentChangesFilter, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.setChangesFilter(filter) }
    }

    func selectUtilityPanelBaseBranch(
        _ branch: String?,
        forRepoRoot repoRoot: String,
        tabID: UUID? = nil
    ) {
        mutateUtilityPanelState(tabID: tabID) { $0.selectBaseBranch(branch, forRepoRoot: repoRoot) }
    }

    /// The base branch this tab last used for a repository, for pre-selecting a base the user
    /// already chose instead of inferring one.
    func utilityPanelLastUsedBaseBranch(forRepoRoot repoRoot: String, tabID: UUID? = nil) -> String? {
        utilityPanelState(tabID: tabID ?? currentTabID).lastUsedBaseBranch(forRepoRoot: repoRoot)
    }

    // MARK: - File expansion and context

    /// Toggles a file's expansion and reports whether it is now expanded, so the caller can start a
    /// lazy patch load only when the file actually opened.
    @discardableResult
    func toggleUtilityPanelFileExpansion(filePath: String, tabID: UUID? = nil) -> Bool {
        var isExpanded = false
        mutateUtilityPanelState(tabID: tabID) { isExpanded = $0.toggleExpansion(ofFilePath: filePath) }
        return isExpanded
    }

    func setUtilityPanelFileExpansion(_ isExpanded: Bool, filePath: String, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.setExpansion(isExpanded, ofFilePath: filePath) }
    }

    func setUtilityPanelFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFilePath: String?,
        tabID: UUID? = nil
    ) {
        mutateUtilityPanelState(tabID: tabID) { state in
            state.setViewed(viewed, revision: revision, compareTargetKey: compareTargetKey)
            if let collapseFilePath {
                state.setExpansion(false, ofFilePath: collapseFilePath)
            }
        }
    }

    /// Raises a file's diff context by one step and reports the new level, which the caller passes
    /// to the diff engine as its context-line request.
    @discardableResult
    func escalateUtilityPanelContext(filePath: String, tabID: UUID? = nil) -> AgentChangesContextLevel {
        var level = AgentChangesContextLevel.standard
        mutateUtilityPanelState(tabID: tabID) { level = $0.escalateContext(forFilePath: filePath) }
        return level
    }

    // MARK: - Preview

    func selectUtilityPanelPreviewDocument(_ document: PreviewDocumentReference?, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.selectPreviewDocument(document) }
    }

    /// Artifact-banner deep link: reveals the document in the Preview segment in one step.
    func showUtilityPanelPreview(of document: PreviewDocumentReference, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.showPreview(of: document) }
    }

    func setUtilityPanelHTMLDisplayMode(_ mode: AgentPreviewHTMLDisplayMode, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.setHTMLDisplayMode(mode) }
    }

    func enableUtilityPanelHTMLScriptsOnce(
        for document: PreviewDocumentReference,
        tabID: UUID? = nil
    ) {
        mutateUtilityPanelState(tabID: tabID) { $0.enableHTMLScriptsOnce(for: document) }
    }

    func disableUtilityPanelHTMLScripts(tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.disableHTMLScripts() }
    }

    // MARK: - Artifact banner

    func dismissUtilityPanelBanner(artifactID: String, tabID: UUID? = nil) {
        mutateUtilityPanelState(tabID: tabID) { $0.dismissBanner(artifactID: artifactID) }
    }

    // MARK: - Mutation seam

    /// Applies a mutation to one tab's panel state and republishes only when the active tab moved.
    ///
    /// Panel state is not persisted, so this deliberately does not mark the session dirty or
    /// schedule a save — see `AgentUtilityPanelTabState` for why none of it belongs on disk.
    private func mutateUtilityPanelState(
        tabID explicitTabID: UUID?,
        _ mutate: (inout AgentUtilityPanelTabState) -> Void
    ) {
        guard let tabID = explicitTabID ?? currentTabID, let session = sessions[tabID] else { return }
        var state = session.utilityPanel
        mutate(&state)
        guard session.utilityPanel != state else { return }
        session.utilityPanel = state
        guard tabID == currentTabID else { return }
        syncUtilityPanelUIState()
    }
}
