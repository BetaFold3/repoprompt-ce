import Foundation

extension AgentModeViewModel {
    func makeComposerProps(tabID explicitTabID: UUID? = nil) -> AgentComposerProps {
        let tabID = explicitTabID ?? currentTabID
        let session = tabID.flatMap { sessions[$0] }
        let isMCPControlled = isMCPControlled(tabID: tabID)
        let modelSelectionInteractivity = modelSelectionInteractivity(tabID: tabID)
        let availableAgentsForTab = selectableAgents(forTabID: tabID)
        let selectedAgentForTab = session?.selectedAgent ?? selectedAgent
        let canSendWithProviderForTab = availableAgentsForTab.contains(selectedAgentForTab)
        let isCodexRunActive: Bool = {
            guard selectedAgent == .codexExec, let tabID else { return false }
            return isTabRunning(tabID)
        }()
        let cancelTarget: AgentRunCancelTarget? = {
            guard let tabID,
                  let session,
                  session.runState.isActive,
                  session.runState != .waitingForUser,
                  session.runID != nil
            else { return nil }
            return makeRunCancelTarget(tabID: tabID, session: session)
        }()
        let submitTarget = makeComposerSubmitTarget(tabID: tabID, session: session)
        let remoteCatalog = remoteHostCatalogSnapshot(for: session)
        let isRemoteSession = session?.remoteHost != nil
        let selectedModelRawForProps = session?.selectedModelRaw ?? selectedModelRaw
        let selectedModelDisplayNameForProps = remoteCatalog?.displayName(forModelID: selectedModelRawForProps)
            ?? selectedModelDisplayName
        return AgentComposerProps(
            currentTabID: tabID,
            submitTarget: submitTarget,
            attachments: AgentAttachmentStripSnapshot(
                scopeTabID: tabID,
                imageAttachments: pendingImageAttachments,
                taggedFileAttachments: pendingTaggedFileAttachments
            ),
            runState: runState,
            cancelTarget: cancelTarget,
            isAgentBusy: isAgentBusy,
            isWaitingForInstruction: isWaitingForInstruction,
            canUseLinkedAgentSession: hasLinkedAgentSession(for: tabID),
            isCurrentTabMCPControlled: isMCPControlled,
            areModelControlsDisabled: modelSelectionInteractivity.isDisabled,
            providerControls: activeProviderControlsBinding,
            isCodexRunActive: isCodexRunActive,
            hasAvailableAgentProviders: isRemoteSession ? true : !availableAgentsForTab.isEmpty,
            canSendWithCurrentProvider: isRemoteSession ? true : canSendWithProviderForTab,
            unavailableSelectedAgentMessage: isRemoteSession
                ? nil
                : (canSendWithProviderForTab ? nil : unavailableSelectedAgentMessage),
            runLocation: runLocationSelection(for: session),
            runLocationHostDisplayName: session?.remoteHost?.hostDisplayName,
            remoteHostCatalog: remoteCatalog,
            selectedAgent: session?.selectedAgent ?? selectedAgent,
            selectedModelRaw: selectedModelRawForProps,
            selectedModelDisplayName: selectedModelDisplayNameForProps,
            ohMyPiThinkingSelections: session?.ohMyPiThinkingSelections ?? .empty,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw,
            selectedReasoningEffortDisplayName: selectedReasoningEffortDisplayName,
            availableAgents: availableAgentsForTab,
            isProviderPickerLockedForCurrentTab: isProviderPickerLocked(tabID: tabID),
            lockedAgentSelectionMessage: lockedAgentSelectionMessage(tabID: tabID),
            autoEditEnabled: autoEditEnabled,
            stagedSlashCommand: stagedSlashCommandProps(tabID: tabID),
            draftRestorationEvent: draftRestorationEvent.map(AgentDraftRestorationProps.init),
            fileTagLookupContextIdentity: agentWorkspaceLookupContextIdentity(tabID: tabID, session: session)
        )
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: TabSession?) -> AgentComposerSubmitTarget? {
        guard let tabID else { return nil }
        let existingSession = session ?? sessions[tabID]
        let resolvedSession = existingSession ?? self.session(for: tabID)
        // V1-3: the default tab of a fresh workspace never passes through
        // `createAndActivateSessionTab()` — its session materializes lazily
        // right here on the first composer sync. Apply the workspace-default
        // run location exactly once at that creation so the run-location pill
        // and the first-send snapshot carry the host binding + pinned model.
        // One-shot: an existing session is never re-bound, so an explicit
        // "This Mac" selection sticks. Hydrated sessions (persistent binding
        // installed at creation → activeAgentSessionID != nil) and MCP flows
        // (ensureSessionReady / mcpResolveOrCreateSessionTarget never call
        // this composer seam) keep their no-auto-bind behavior.
        if existingSession == nil,
           resolvedSession.activeAgentSessionID == nil,
           isEligibleForInitialStartLocation(tabID: tabID, session: resolvedSession)
        {
            applyWorkspaceDefaultRunLocationIfNeeded(to: resolvedSession)
        }
        let expectedInitialStartLocation = initialStartLocationProps(tabID: tabID)?.selection
        if workspaceSwitchInFlight, (expectedInitialStartLocation ?? .local) == .local {
            return nil
        }
        guard !resolvedSession.isComposerSubmissionInFlight,
              !resolvedSession.isPreparingInitialWorktree,
              !resolvedSession.isChangingExecutionLocation
        else { return nil }
        let expectedSourceAgentSessionID = composerSourceAgentSessionID(tabID: tabID, session: resolvedSession)
        let hasLinkedSession = hasLinkedAgentSession(for: tabID)
        let route: AgentComposerSubmitTarget.Route
        if hasLinkedSession {
            guard expectedSourceAgentSessionID != nil else { return nil }
            route = .existingAgentSession
        } else {
            guard expectedSourceAgentSessionID == nil else { return nil }
            guard !resolvedSession.runState.isActive,
                  resolvedSession.runID == nil,
                  resolvedSession.activeRunAttemptID == nil
            else { return nil }
            route = .createAgentSessionFromSourceTab
        }

        let expectedRunState = resolvedSession.runState
        let expectedRunID = resolvedSession.runID
        let expectedRunAttemptID = resolvedSession.activeRunAttemptID
        guard !expectedRunState.isActive || expectedRunID != nil else { return nil }
        return AgentComposerSubmitTarget(
            tabID: tabID,
            route: route,
            expectedSourceTabSessionIdentity: ObjectIdentifier(resolvedSession),
            expectedSourceAgentSessionID: expectedSourceAgentSessionID,
            expectedPersistentBindingIdentity: resolvedSession.persistentSessionBindingIdentity,
            expectedBindingTransitionGeneration: resolvedSession.bindingTransitionGeneration,
            expectedRunState: expectedRunState,
            expectedRunID: expectedRunID,
            expectedRunAttemptID: expectedRunAttemptID,
            expectedSubmissionToken: resolvedSession.composerSubmissionToken,
            expectedInitialStartLocation: expectedInitialStartLocation
        )
    }

    func syncComposerUIState(tabID: UUID? = nil) {
        #if DEBUG
            test_syncComposerCallCount += 1
        #endif
        ui.composer.update(makeComposerProps(tabID: tabID))
    }

    func syncAllActiveUIState(tabID: UUID? = nil) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncAllActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event("ui.syncAllActiveUIState", tabID: tabID)
        #endif
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
        syncRuntimeMetricsUIState()
        // Sidebar revision should publish only on sidebar-relevant changes (session
        // list, sort, search, visible count). `syncSidebarUIState()` still republishes
        // the snapshot when those inputs differ; callers that truly need to force a
        // sidebar revision bump (e.g. sessions/sessionIndex/run-state mutations) call
        // `syncSidebarUIState(refresh: true)` directly.
        syncSidebarUIState()
        syncTranscriptUIState()
        syncRunInteractionUIState()
    }

    func syncActiveUIState(tabID: UUID? = nil, invalidation: ActiveUIInvalidation) {
        guard !invalidation.isEmpty else { return }
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event(
                "ui.syncActiveUIState",
                tabID: tabID,
                fields: [
                    "composer": String(invalidation.contains(.composer)),
                    "status": String(invalidation.contains(.statusPills)),
                    "runtime": String(invalidation.contains(.runtimeMetrics)),
                    "transcript": String(invalidation.contains(.transcript)),
                    "run": String(invalidation.contains(.runInteraction))
                ]
            )
        #endif
        if invalidation.contains(.composer) {
            syncComposerUIState(tabID: tabID)
        }
        if invalidation.contains(.statusPills) {
            syncStatusPillsUIState()
        }
        if invalidation.contains(.runtimeMetrics) {
            syncRuntimeMetricsUIState()
        }
        if invalidation.contains(.transcript) {
            syncTranscriptUIState()
        }
        if invalidation.contains(.runInteraction) {
            syncRunInteractionUIState()
        }
    }
}
