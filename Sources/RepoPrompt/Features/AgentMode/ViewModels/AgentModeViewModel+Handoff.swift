import Foundation

enum AgentModelSelectionInteractivity: Equatable {
    case interactive
    case disabled(reason: String)

    var isDisabled: Bool {
        if case .disabled = self {
            return true
        }
        return false
    }
}

enum AgentHandoffRemoteCatalogAccess {
    case loading
    case cacheOnly
}

enum AgentModelSelectionCommitError: LocalizedError, Equatable {
    case sourceUnavailable
    case controlsDisabled(reason: String)
    case remoteSessionRequiresRemoteSelection
    case agentNotSelectable
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The source session is no longer active."
        case let .controlsDisabled(reason):
            reason
        case .remoteSessionRequiresRemoteSelection:
            "Remote session models must be selected from the host catalog."
        case .agentNotSelectable:
            "The selected agent is no longer available for this session."
        case .modelUnavailable:
            "The selected model is no longer available."
        }
    }
}

extension AgentModeViewModel {
    func modelSelectionInteractivity(tabID: UUID?) -> AgentModelSelectionInteractivity {
        if isMCPControlled(tabID: tabID) {
            return .disabled(
                reason: "Model and effort controls are locked while this session is controlled by an MCP agent."
            )
        }
        return .interactive
    }

    /// Commits a local model selection through the same mutation sequence used by the
    /// input bar. Every presentation-derived value is revalidated before mutation.
    @MainActor
    func commitCurrentSessionModelSelection(
        agent: AgentProviderKind,
        rawModel: String,
        explicitCodexEffort: CodexReasoningEffort?,
        sourceTabID: UUID
    ) throws {
        guard currentTabID == sourceTabID,
              let session = sessions[sourceTabID]
        else {
            throw AgentModelSelectionCommitError.sourceUnavailable
        }
        switch modelSelectionInteractivity(tabID: sourceTabID) {
        case .interactive:
            break
        case let .disabled(reason):
            throw AgentModelSelectionCommitError.controlsDisabled(reason: reason)
        }
        guard session.remoteHost == nil else {
            throw AgentModelSelectionCommitError.remoteSessionRequiresRemoteSelection
        }
        guard canSelectAgentInCurrentChat(agent, tabID: sourceTabID) else {
            throw AgentModelSelectionCommitError.agentNotSelectable
        }

        let sourceOptions = modelOptions(
            for: agent,
            includeClaudeEffortVariants: !agent.usesClaudeTooling
        )
        guard AgentModelCatalog.modelOption(
            matching: rawModel,
            for: agent,
            in: sourceOptions
        ) != nil else {
            throw AgentModelSelectionCommitError.modelUnavailable
        }

        AgentModelCatalog.updateLastUsedEffortIfEncoded(
            agentKind: agent,
            rawModel: rawModel
        )
        selectedAgent = agent
        selectModel(rawModel: rawModel)
        OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
            agent: agent,
            rawModel: rawModel
        )
        if agent == .codexExec,
           CodexModelSpecifier(raw: rawModel).reasoningEffort == nil,
           let explicitCodexEffort
        {
            selectedReasoningEffortRaw = explicitCodexEffort.rawValue
        }
    }

    /// Cache-only catalog accessor for HUD presentation. Unlike the composer accessor,
    /// this never starts a catalog load on a miss.
    func cachedRemoteHostCatalog(sourceTabID: UUID) -> RemoteHostAgentCatalog? {
        guard let hostID = sessions[sourceTabID]?.remoteHost?.hostID else { return nil }
        return remoteHostCatalog.cachedCatalog(for: hostID)
    }

    func resolveLastReplyHandoffTarget(
        sourceTabID: UUID
    ) -> AgentLastCompletedAssistantReplyHandoffResolution {
        guard let session = sessions[sourceTabID] else {
            return .unavailable(message: "Nothing to hand off yet.")
        }
        let remoteMapping: ((UUID) -> UUID?)? = if session.remoteHost != nil {
            { [remoteCoordinator] clientItemID in
                remoteCoordinator.hostRowID(for: session, clientItemID: clientItemID)
            }
        } else {
            nil
        }
        return AgentLastCompletedAssistantReplyHandoffCutoffResolver.resolve(
            runState: session.runState,
            canForkCurrentSession: canForkSession(session),
            transcript: session.transcript,
            legacyItems: session.items,
            remoteHostRowIDForClientItemID: remoteMapping
        )
    }

    /// Builds a per-message handoff configuration pinned to the source tab and live
    /// session identity captured at presentation.
    func makeHandoffConfig(
        for itemID: UUID,
        sourceTabID: UUID,
        windowID: Int,
        remoteCatalogAccess: AgentHandoffRemoteCatalogAccess = .loading
    ) -> AgentHandoffConfig? {
        guard let sourceSession = sessions[sourceTabID],
              canForkSession(sourceSession)
        else {
            return nil
        }

        let sourceIdentity = ObjectIdentifier(sourceSession)
        let expectedHostID = sourceSession.remoteHost?.hostID
        let expectedRemoteSessionID = sourceSession.remoteHost?.remoteSessionID
        let resolvedHostRowID = expectedHostID.map { _ in
            remoteCoordinator.hostRowID(for: sourceSession, clientItemID: itemID)
        } ?? nil
        guard let destinationSource = AgentHandoffConfig.destinationSource(
            remoteHostID: expectedHostID,
            resolvedHostRowID: resolvedHostRowID
        ) else {
            return nil
        }

        return AgentHandoffConfig(
            itemID: itemID,
            destinationSource: destinationSource,
            defaultDestinationAgent: sourceSession.selectedAgent,
            defaultModelRaw: sourceSession.selectedModelRaw,
            defaultReasoningEffortRaw: sourceSession.selectedReasoningEffortRaw,
            availableAgentsProvider: { [weak self] in
                guard let self,
                      (try? pinnedHandoffSource(
                          tabID: sourceTabID,
                          identity: sourceIdentity,
                          hostID: expectedHostID,
                          remoteSessionID: expectedRemoteSessionID
                      )) != nil
                else {
                    return []
                }
                return selectableAgents(forTabID: sourceTabID)
            },
            modelOptionsProvider: { [weak self] agent in
                guard let self,
                      (try? pinnedHandoffSource(
                          tabID: sourceTabID,
                          identity: sourceIdentity,
                          hostID: expectedHostID,
                          remoteSessionID: expectedRemoteSessionID
                      )) != nil
                else {
                    return []
                }
                return modelOptions(for: agent)
            },
            remoteCatalogSnapshot: expectedHostID.flatMap { hostID in
                switch remoteCatalogAccess {
                case .loading:
                    remoteHostCatalogSnapshot(for: sourceSession)
                case .cacheOnly:
                    remoteHostCatalog.cachedCatalog(for: hostID)
                }
            },
            windowID: windowID,
            buildPayloadForClipboard: { [weak self] in
                guard let self else {
                    throw AgentHandoffConfigurationError.sourceUnavailable
                }
                let session = try pinnedHandoffSource(
                    tabID: sourceTabID,
                    identity: sourceIdentity,
                    hostID: expectedHostID,
                    remoteSessionID: expectedRemoteSessionID
                )
                if expectedHostID != nil {
                    return try await remoteCoordinator.extractHandoff(
                        session: session,
                        upToClientItemID: itemID
                    )
                }
                return try await buildHandoffPayload(
                    sourceTabID: sourceTabID,
                    upToItemID: itemID
                )
            },
            performHandoff: { [weak self] destination in
                guard let self else {
                    throw AgentHandoffConfigurationError.sourceUnavailable
                }
                let session = try pinnedHandoffSource(
                    tabID: sourceTabID,
                    identity: sourceIdentity,
                    hostID: expectedHostID,
                    remoteSessionID: expectedRemoteSessionID
                )
                switch (destinationSource, destination) {
                case let (.localProviders, .local(selection)):
                    try await prepareHandoffToNewTab(
                        sourceTabID: sourceTabID,
                        upToItemID: itemID,
                        destinationAgent: selection.agent,
                        destinationModelRaw: selection.modelRaw,
                        destinationReasoningEffortRaw: selection.reasoningEffortRaw
                    )
                case let (.remoteCatalog, .remote(agentID, modelID, effort)):
                    try await remoteCoordinator.fork(
                        session: session,
                        upToClientItemID: itemID,
                        destinationAgent: agentID,
                        destinationModelID: modelID,
                        destinationEffort: effort
                    )
                default:
                    throw AgentHandoffConfigurationError.invalidDestination
                }
            }
        )
    }

    private func pinnedHandoffSource(
        tabID: UUID,
        identity: ObjectIdentifier,
        hostID: String?,
        remoteSessionID: String?
    ) throws -> TabSession {
        guard let session = sessions[tabID],
              ObjectIdentifier(session) == identity,
              session.remoteHost?.hostID == hostID,
              session.remoteHost?.remoteSessionID == remoteSessionID
        else {
            throw AgentHandoffConfigurationError.sourceUnavailable
        }
        return session
    }
}
