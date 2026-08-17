import Foundation

/// The authority used to populate handoff destinations.
enum AgentHandoffDestinationSource: Equatable {
    case localProviders
    case remoteCatalog(hostID: String)
}

/// Configuration for the handoff button in message footers.
/// Provides the data and callbacks needed for the handoff popover.
struct AgentHandoffConfig {
    let itemID: UUID
    let destinationSource: AgentHandoffDestinationSource
    let defaultDestinationAgent: AgentProviderKind
    let defaultModelRaw: String
    let defaultReasoningEffortRaw: String?
    let defaultOhMyPiThinkingSelections: OhMyPiThinkingSelections
    let availableAgentsProvider: () -> [AgentProviderKind]
    let modelOptionsProvider: (AgentProviderKind) -> [AgentModelOption]
    let remoteCatalogSnapshot: RemoteHostAgentCatalog?
    let windowID: Int
    let buildPayloadForClipboard: @MainActor () async throws -> String
    let performHandoff: @MainActor (_ destination: AgentHandoffDestination) async throws -> Void

    /// Local rows remain eligible under the session-level gate. Remote rows additionally
    /// require the host UUID side-channel so the client never sends a synthetic cutoff.
    static func destinationSource(
        remoteHostID: String?,
        resolvedHostRowID: UUID?
    ) -> AgentHandoffDestinationSource? {
        guard let remoteHostID else { return .localProviders }
        guard resolvedHostRowID != nil else { return nil }
        return .remoteCatalog(hostID: remoteHostID)
    }
}

/// A destination resolved by the picker against its owning source of truth.
enum AgentHandoffDestination: Equatable {
    case local(AgentHandoffSelection)
    case remote(agentID: String, modelID: String, effort: String?)
}

enum AgentHandoffConfigurationError: LocalizedError {
    case sourceUnavailable
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The source session is no longer available."
        case .invalidDestination:
            "The selected handoff destination no longer matches this session."
        }
    }
}

/// The user's local-provider selection in the handoff popover.
struct AgentHandoffSelection: Equatable {
    let agent: AgentProviderKind
    let modelRaw: String
    let reasoningEffortRaw: String?
    let ohMyPiThinkingSelections: OhMyPiThinkingSelections

    init(
        agent: AgentProviderKind,
        modelRaw: String,
        reasoningEffortRaw: String?,
        ohMyPiThinkingSelections: OhMyPiThinkingSelections = .empty
    ) {
        self.agent = agent
        self.modelRaw = modelRaw
        self.reasoningEffortRaw = reasoningEffortRaw
        self.ohMyPiThinkingSelections = agent == .ohMyPi ? ohMyPiThinkingSelections : .empty
    }
}

/// Testable selection state for the remote handoff picker. Every destination value is
/// retained verbatim from `RemoteHostAgentCatalog` for the host to validate (contract C3).
struct AgentHandoffRemoteDestinationState: Equatable {
    let catalog: RemoteHostAgentCatalog?
    private(set) var selectedAgentGroupID: String?
    private(set) var selectedModelGroupID: String?
    private(set) var selectedModelID: String?

    init(catalog: RemoteHostAgentCatalog?, preferredModelID: String?) {
        self.catalog = catalog
        selectedAgentGroupID = nil
        selectedModelGroupID = nil
        selectedModelID = nil

        let groups = catalog?.structuredAgentGroups ?? []
        let preferredAgent = groups.first { agent in
            agent.models.contains { model in
                preferredModelID.map(model.containsModelID) ?? false
            }
        }
        guard let agent = preferredAgent ?? groups.first else { return }
        let preferredModel = agent.models.first { model in
            preferredModelID.map(model.containsModelID) ?? false
        }
        guard let model = preferredModel ?? agent.models.first,
              let option = preferredModelID.flatMap({ rawModelID in
                  model.options.first { $0.modelID == rawModelID }
              }) ?? model.preferredOption
        else { return }

        selectedAgentGroupID = agent.id
        selectedModelGroupID = model.id
        selectedModelID = option.modelID
    }

    var structuredAgentGroups: [RemoteHostAgentModelGroup] {
        catalog?.structuredAgentGroups ?? []
    }

    var selectedAgentGroup: RemoteHostAgentModelGroup? {
        structuredAgentGroups.first { $0.id == selectedAgentGroupID }
    }

    var selectedModelGroup: RemoteHostBaseModelGroup? {
        selectedAgentGroup?.models.first { $0.id == selectedModelGroupID }
    }

    var selectedEffortOption: RemoteHostEffortOption? {
        guard let selectedModelID else { return nil }
        return selectedModelGroup?.options.first { $0.modelID == selectedModelID }
    }

    var effortOptions: [RemoteHostEffortOption] {
        selectedModelGroup?.effortOptions ?? []
    }

    /// Payload extraction is independent of destination-catalog health.
    var canCopyPayload: Bool {
        true
    }

    var canPerformHandoff: Bool {
        destination != nil
    }

    var destination: AgentHandoffDestination? {
        guard catalog?.isDegraded == false,
              let agentID = selectedAgentGroup?.agentID,
              !agentID.isEmpty,
              let option = selectedEffortOption
        else { return nil }
        return .remote(
            agentID: agentID,
            modelID: option.modelID,
            effort: option.effort
        )
    }

    mutating func selectModel(agentGroupID: String, modelGroupID: String) {
        guard let agent = structuredAgentGroups.first(where: { $0.id == agentGroupID }),
              let model = agent.models.first(where: { $0.id == modelGroupID }),
              let option = model.preferredOption
        else { return }
        selectedAgentGroupID = agent.id
        selectedModelGroupID = model.id
        selectedModelID = option.modelID
    }

    mutating func selectEffort(modelID: String) {
        guard selectedModelGroup?.options.contains(where: { $0.modelID == modelID }) == true else { return }
        selectedModelID = modelID
    }
}
