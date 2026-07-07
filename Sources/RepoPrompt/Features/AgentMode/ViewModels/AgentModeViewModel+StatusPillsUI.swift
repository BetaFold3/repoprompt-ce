import Foundation

extension AgentModeViewModel {
    func makeStatusPillsSnapshot() -> AgentStatusPillsSnapshot {
        AgentStatusPillsSnapshot(
            currentTabID: currentTabID,
            selectedWorkflow: selectedWorkflow,
            stagedSlashCommand: stagedSlashCommandProps(tabID: currentTabID),
            selectedAgent: selectedAgent,
            autoEditPermissionGuidance: autoEditPermissionGuidance,
            runState: runState,
            autoEditEnabled: autoEditEnabled,
            interviewFirst: interviewFirst,
            runLocation: runLocationProps(tabID: currentTabID),
            executionLocation: executionLocationProps(tabID: currentTabID),
            activeAgentSessionID: activeSession?.activeAgentSessionID,
            activeRunID: activeSession?.runID
        )
    }

    func syncStatusPillsUIState() {
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    func runLocationProps(tabID: UUID?) -> AgentRunLocationProps? {
        guard let tabID,
              workspaceManager?.activeWorkspace?.isSystemWorkspace != true,
              remoteHostRegistry.hasHosts
        else {
            return nil
        }
        let hosts = (try? remoteHostRegistry.listHosts())?
            .filter { !$0.isRevokedByHost } ?? []
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: hosts.map { (id: $0.id, displayName: $0.displayName) }
        )
        let hostOptions = hosts.map {
            AgentRunLocationHostOption(
                id: $0.id,
                displayName: $0.displayName,
                abbreviation: abbreviations[$0.id]
            )
        }
        guard !hostOptions.isEmpty else { return nil }

        let session = sessions[tabID]
        let selection = runLocationSelection(for: session)
        let selectedHostDisplayName: String? = {
            if case let .host(hostID) = selection {
                return hostOptions.first(where: { $0.id == hostID })?.displayName
                    ?? session?.remoteHost?.hostDisplayName
            }
            return nil
        }()
        let selectedHostAbbreviation: String? = {
            if case let .host(hostID) = selection {
                if let option = hostOptions.first(where: { $0.id == hostID }) {
                    return option.abbreviation
                }
                if let remoteHost = session?.remoteHost,
                   remoteHost.hostID == hostID
                {
                    return AgentRunLocationHostOption.abbreviations(
                        for: [(id: remoteHost.hostID, displayName: remoteHost.hostDisplayName)]
                    )[remoteHost.hostID]
                }
            }
            return nil
        }()
        let disabledReason: String? = if let session,
                                         let remoteReason = localSessionMutationDisabledReason(for: session),
                                         !isEligibleForInitialRunLocation(tabID: tabID, session: session)
        {
            remoteReason
        } else if isEligibleForInitialRunLocation(tabID: tabID, session: session) {
            nil
        } else {
            "Run location can only be changed before the first message."
        }
        return AgentRunLocationProps(
            tabID: tabID,
            selection: selection,
            selectedHostDisplayName: selectedHostDisplayName,
            selectedHostAbbreviation: selectedHostAbbreviation,
            hostOptions: hostOptions,
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason
        )
    }

    func runLocationSelection(for session: TabSession?) -> AgentRunLocation {
        guard let remoteHost = session?.remoteHost else { return .thisMac }
        return .host(hostID: remoteHost.hostID)
    }

    func isEligibleForInitialRunLocation(tabID: UUID, session: TabSession?) -> Bool {
        isEligibleForInitialStartLocation(tabID: tabID, session: session)
    }

    /// Persistent projection for the primary execution root. The initial intent
    /// remains deferred until first send; committed bindings remain visible afterward.
    func executionLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let tabID,
              workspaceManager?.activeWorkspace?.isSystemWorkspace != true
        else {
            return nil
        }

        if isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID]) {
            let session = sessions[tabID]
            let busy = session?.isPreparingInitialWorktree == true
            let remoteWorktreeReason = session?.remoteHost == nil ? nil : Self.remoteWorktreeManagedReason
            return AgentExecutionLocationProps(
                tabID: tabID,
                selection: session?.remoteHost == nil ? (session?.pendingInitialStartLocation ?? .local) : .local,
                indicator: nil,
                isInitialSelection: true,
                isEnabled: remoteWorktreeReason == nil && !busy,
                isOperationInProgress: busy,
                requiresActiveRunConfirmation: false,
                disabledReason: busy ? "Preparing the selected worktree…" : remoteWorktreeReason
            )
        }

        guard let session = sessions[tabID],
              hasLinkedAgentSession(for: tabID) || session.hasSentFirstMessage || !session.worktreeBindings.isEmpty
        else {
            return nil
        }
        let indicator = primaryExecutionWorktreeIndicator(forTabID: tabID)
        let selection: InitialStartLocation = indicator.map { indicator in
            .existingWorktree(
                AgentExecutionWorktreeSelection(
                    repositoryID: indicator.repositoryID,
                    repoKey: "",
                    worktreeID: indicator.worktreeID,
                    path: indicator.worktreeRootPath,
                    name: indicator.worktreeName,
                    branch: indicator.branch,
                    head: nil,
                    isDetached: indicator.branch == nil,
                    label: indicator.label,
                    colorHex: indicator.colorHex,
                    isLocked: false,
                    lockReason: nil,
                    isPrunable: !indicator.isAvailable,
                    prunableReason: indicator.isAvailable ? nil : indicator.tooltipText
                )
            )
        } ?? .local
        let busy = session.isChangingExecutionLocation
        let disabledReason = session.remoteHost == nil ? executionLocationMutationDisabledReason(for: session) : Self.remoteWorktreeManagedReason
        return AgentExecutionLocationProps(
            tabID: tabID,
            selection: selection,
            indicator: indicator,
            isInitialSelection: false,
            isEnabled: disabledReason == nil && !busy,
            isOperationInProgress: busy,
            requiresActiveRunConfirmation: session.runState.isActive,
            disabledReason: busy ? "Changing execution location…" : disabledReason
        )
    }

    /// Initial-only compatibility shim used by the guarded first-send contract.
    func initialStartLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let props = executionLocationProps(tabID: tabID), props.isInitialSelection else { return nil }
        return props
    }

    func isEligibleForInitialStartLocation(tabID: UUID, session: TabSession?) -> Bool {
        guard workspaceManager?.activeWorkspace?.isSystemWorkspace != true else {
            return false
        }
        guard let session else { return !hasLinkedAgentSession(for: tabID) }
        guard !hasLinkedAgentSession(for: tabID) || session.hasLoadedPersistedState else { return false }
        return session.mcpControlContext == nil
            && !session.isMCPOriginated
            && session.parentSessionID == nil
            && !session.pendingHandoff.hasPayload
            && !session.hasSentFirstMessage
            && session.runState == .idle
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.providerSessionID == nil
            && session.codexConversationID == nil
            && session.worktreeBindings.isEmpty
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
    }

    static let remoteWorktreeManagedReason = "Worktrees are managed on the host for remote sessions."

    func localSessionMutationDisabledReason(tabID: UUID?) -> String? {
        guard let tabID,
              let session = sessions[tabID]
        else { return nil }
        return localSessionMutationDisabledReason(for: session)
    }

    func localSessionMutationDisabledReason(for session: TabSession) -> String? {
        guard let remoteHost = session.remoteHost else { return nil }
        return "Managed on \(remoteHost.hostDisplayName)"
    }

    private func executionLocationMutationDisabledReason(for session: TabSession) -> String? {
        if !session.hasLoadedPersistedState {
            return "Load this thread before changing its execution location."
        }
        if session.mcpControlContext != nil || session.isMCPOriginated || session.parentSessionID != nil {
            return "Execution location is managed by the parent or MCP run."
        }
        if session.pendingHandoff.defersProviderLockUntilSend {
            return "Send or clear the pending handoff before changing location."
        }
        return nil
    }

    func selectInitialStartLocation(_ selection: InitialStartLocation, for tabID: UUID) {
        guard tabID == currentTabID,
              isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID])
        else {
            return
        }
        let session = session(for: tabID)
        guard session.remoteHost == nil,
              !session.isPreparingInitialWorktree,
              session.pendingInitialStartLocation != selection
        else {
            return
        }
        session.pendingInitialStartLocation = selection
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    func selectRunLocation(_ selection: AgentRunLocation, for tabID: UUID) {
        guard tabID == currentTabID,
              let props = runLocationProps(tabID: tabID),
              props.isEnabled,
              props.selection != selection
        else { return }
        let session = session(for: tabID)
        switch selection {
        case .thisMac:
            if session.remoteHost != nil {
                remoteCoordinator.stop(tabID: tabID)
            }
            session.remoteHost = nil
            if session.selectedModelRaw == RemoteHostAgentCatalog.hostDefaultModelID {
                let fallback = defaultModelRaw(for: session.selectedAgent)
                session.selectedModelRaw = fallback
                if tabID == currentTabID {
                    setSelectedModelRawDuringStateRestore(fallback)
                }
            }
        case let .host(hostID):
            guard let host = try? remoteHostRegistry.host(id: hostID) else { return }
            session.remoteHost = AgentSessionRemoteHostBinding(
                hostID: host.id,
                hostDisplayName: host.displayName,
                remoteSessionID: ""
            )
            session.pendingInitialStartLocation = .local
            session.selectedModelRaw = RemoteHostAgentCatalog.hostDefaultModelID
            if tabID == currentTabID {
                setSelectedModelRawDuringStateRestore(RemoteHostAgentCatalog.hostDefaultModelID)
            }
            loadRemoteHostCatalogIfNeeded(hostID: host.id)
        }
        session.isDirty = true
        scheduleSave(for: tabID)
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    func setInterviewFirst(_ enabled: Bool) {
        guard interviewFirst != enabled else { return }
        interviewFirst = enabled
        syncStatusPillsUIState()
    }

    func toggleInterviewFirst() {
        setInterviewFirst(!interviewFirst)
    }
}
