//
//  AgentModelsSettingsViewModel.swift
//  RepoPrompt
//
//  View model for AgentModelsSettingsView — the unified home for every
//  agent-mode model decision (Oracle, Built-in Chat, Context Builder agent,
//  and MCP agent role defaults).
//
//  SEARCH-HELPER: Agent Models, Oracle Model, Built-in Chat Model,
//  Context Builder Agent, Agent Role Defaults, Apply Recommended Setup,
//  Planning Model, sync toggle, workspace overrides
//
//  Related:
//  - Page:          /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
//  - Engine:        /RepoPrompt/Services/Recommendations/AutoRecommendationEngine.swift
//  - Role defaults: /RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift
//  - Sync key:      /RepoPrompt/Models/Settings/GlobalSettingsManager.swift
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentModelsSettingsViewModel: ObservableObject {
    // MARK: - Dependencies

    let apiSettingsVM: APISettingsViewModel
    private let settingsManager: any SettingsManaging
    private let notificationCenter: NotificationCenter
    private let engine: AutoRecommendationEngine

    // MARK: - Published state

    @Published private(set) var workspaceID: UUID?
    @Published private(set) var workspaceName: String?
    @Published private(set) var inheritanceMode: AgentModelsInheritanceMode
    @Published private(set) var profileSnapshot: AgentModelsSettingsProfile
    @Published private(set) var recommendations: RecommendationSet = .init()
    @Published private(set) var isApplyingAll: Bool = false
    @Published var syncChatWithOracle: Bool {
        didSet {
            guard !isReloadingScopedState, oldValue != syncChatWithOracle else { return }
            updateSelectedProfile(reason: "agent_models.sync_toggle") { profile in
                profile.syncChatModelWithOracle = syncChatWithOracle
                if syncChatWithOracle {
                    profile.preferredComposeModelRaw = profile.planningModelRaw
                    profile.preferredComposeOhMyPiThinkingSelections = profile.planningModelOhMyPiThinkingSelections
                }
            }
        }
    }

    /// When `true`, MCP `agent_manage list_agents` hides the extra per-agent
    /// compound model catalog while keeping the four sub-agent role labels
    /// (`explore`, `engineer`, `pair`, `design`) and their concrete model
    /// mappings visible. Manually supplied compound model IDs remain accepted by
    /// the resolver for backwards compatibility.
    ///
    /// SEARCH-HELPER: restrict MCP discovery catalog, role-label mappings,
    /// MCP list_agents filtering, hide non-role model IDs
    @Published var restrictMCPAgentDiscoveryToRoleLabels: Bool {
        didSet {
            guard !isReloadingScopedState, oldValue != restrictMCPAgentDiscoveryToRoleLabels else { return }
            updateSelectedProfile(reason: "agent_models.hide_non_role_toggle") { profile in
                profile.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
            }
        }
    }

    // MARK: - Bookkeeping

    private var cancellables = Set<AnyCancellable>()
    private var isReloadingScopedState = false

    // MARK: - Init

    init(
        apiSettingsVM: APISettingsViewModel,
        workspaceID: UUID? = nil,
        workspaceName: String? = nil,
        settingsManager: (any SettingsManaging)? = nil,
        settingsStore: GlobalSettingsStore? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let settingsManager = settingsManager ?? settingsStore
        let initialInheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let initialProfile = Self.profile(
            settingsManager: settingsManager,
            workspaceID: workspaceID,
            inheritanceMode: initialInheritanceMode
        )

        self.apiSettingsVM = apiSettingsVM
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        inheritanceMode = initialInheritanceMode
        profileSnapshot = initialProfile
        self.settingsManager = settingsManager
        _ = defaults // Retained for initializer compatibility while storage lives in GlobalSettingsStore.
        self.notificationCenter = notificationCenter
        engine = AutoRecommendationEngine(
            settingsStore: settingsStore,
            profileSettingsManager: settingsManager,
            apiSettingsViewModel: apiSettingsVM
        )
        syncChatWithOracle = initialProfile.syncChatModelWithOracle
        restrictMCPAgentDiscoveryToRoleLabels = initialProfile.restrictMCPAgentDiscoveryToRoleLabels

        observeNotifications()
        refresh()
    }

    // MARK: - Public Derived Values

    var hasWorkspace: Bool {
        workspaceID != nil
    }

    var workspaceDisplayName: String? {
        let trimmed = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var editingScope: AgentModelsEditingScope {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else { return .global }
        return .workspace(workspaceID)
    }

    var isEditingWorkspaceSettings: Bool {
        if case .workspace = editingScope { return true }
        return false
    }

    var isEditingGlobalSettings: Bool {
        !isEditingWorkspaceSettings
    }

    var effectiveScopeDescription: String {
        isEditingWorkspaceSettings ? "Using workspace overrides" : "Using global settings"
    }

    var workspaceAgentModelsTitle: String {
        if let workspaceDisplayName {
            return "Agent Models for Workspace: \(workspaceDisplayName)"
        }
        return "Agent Models"
    }

    var noWorkspaceExplanation: String {
        "No workspace is active, so Agent Models edits apply to global settings. Open a workspace to create workspace-specific overrides."
    }

    var showsRecommendationActions: Bool {
        hasWorkspace
    }

    var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    var hasConnectedCLIProvider: Bool {
        !AgentModelCatalog.selectableAgents(availability: availability).isEmpty
    }

    var currentOracleModelName: String {
        Self.displayName(forChatModelRaw: profileSnapshot.planningModelRaw, fallback: "Select an Oracle model")
    }

    var currentBuiltinChatModelName: String {
        let raw = profileSnapshot.syncChatModelWithOracle
            ? profileSnapshot.planningModelRaw
            : profileSnapshot.preferredComposeModelRaw
        return Self.displayName(
            forChatModelRaw: raw,
            fallback: "Select a Built-in Chat model"
        )
    }

    var selectedContextBuilderSelection: AgentModelCatalog.NormalizedAgentSelection {
        let selectedAgentRaw = profileSnapshot.contextBuilderAgentRaw
        let selectedModelRaw = selectedAgentRaw.flatMap { profileSnapshot.contextBuilderModelsByAgent?[$0] }
        return AgentModelCatalog.normalizeSelection(
            agentRaw: selectedAgentRaw,
            modelRaw: selectedModelRaw,
            availability: availability
        )
    }

    var selectedContextBuilderAgent: AgentProviderKind {
        selectedContextBuilderSelection.agent
    }

    var selectedContextBuilderModelRaw: String {
        selectedContextBuilderSelection.modelRaw
    }

    var selectedContextBuilderDisplayName: String {
        AgentModelCatalog.displayName(
            for: selectedContextBuilderModelRaw,
            agentKind: selectedContextBuilderAgent,
            availability: availability
        )
    }

    var recommendedOracleModelName: String? {
        guard let rec = recommendations.chatModel,
              let option = rec.option(for: rec.defaultBackend) else { return nil }
        let model = option.modelString ?? ""
        if let resolved = AIModel.fromModelName(model) {
            return resolved.displayName
        }
        return option.displayName
    }

    var recommendedContextBuilderDescription: String? {
        guard let rec = recommendations.contextBuilder else { return nil }
        return "\(rec.recommendedAgent.displayName) · \(rec.recommendedModel.displayName)"
    }

    var isOracleRecommendationSatisfied: Bool {
        recommendations.chatModel?.alreadySatisfied ?? true
    }

    var isContextBuilderRecommendationSatisfied: Bool {
        recommendations.contextBuilder?.alreadySatisfied ?? true
    }

    var roleDefaultsResolutions: [MCPAgentRoleDefaultsService.RoleDefaultResolution] {
        let profileStore = AgentModelsProfileRoleDefaultsStore(
            overrides: profileSnapshot.mcpAgentRoleOverrides,
            roleThinkingSelections: profileSnapshot.mcpAgentRoleOhMyPiThinkingSelections
        )
        return MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            recommendedAvailability: availability.filteredForRecommendationProviders(settingsManager.globalRecommendationProviderFilter()),
            settingsStore: profileStore
        )
    }

    var roleDefaultsHasOverrides: Bool {
        roleDefaultsResolutions.contains(where: \.hasStoredOverride)
    }

    var hasUnsatisfiedRecommendations: Bool {
        recommendations.hasUnsatisfied
    }

    // MARK: - Scope

    func updateWorkspaceContext(workspaceID: UUID?, workspaceName: String?) {
        guard self.workspaceID != workspaceID || self.workspaceName != workspaceName else { return }
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        reloadScopedState()
        refresh()
    }

    func setInheritanceMode(_ mode: AgentModelsInheritanceMode) {
        guard let workspaceID else { return }
        guard inheritanceMode != mode else { return }
        settingsManager.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: mode)
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.inheritance_mode")
    }

    // MARK: - Refresh

    /// Recompute the recommendation set.
    func refresh() {
        guard let workspaceID else {
            recommendations = RecommendationSet()
            return
        }
        let identity = AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: editingScope)
        let raw = engine.computeRecommendations(for: identity)
        recommendations = engine.applyMutedFlags(raw, workspaceID: workspaceID)
    }

    // MARK: - Destinations

    /// Destination for the Oracle model. Writes `planningModel` and, when the
    /// sync toggle is on, mirrors to `preferredComposeModel` in the selected
    /// global/workspace Agent Models profile.
    var oracleModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.oracle",
            getter: { [weak self] in
                self?.currentProfile().profile.planningModelRaw ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setOracleModel(raw: rawValue)
            },
            thinkingGetter: { [weak self] in
                self?.currentProfile().profile.planningModelOhMyPiThinkingSelections ?? .empty
            },
            thinkingApplier: { [weak self] selections in
                self?.setOracleThinkingSelections(selections)
            }
        )
    }

    /// Destination for the Built-in Chat model. Writes `preferredComposeModel`
    /// and, when the sync toggle is on, mirrors to `planningModel` in the
    /// selected global/workspace Agent Models profile.
    var builtinChatModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.builtinChat",
            getter: { [weak self] in
                self?.currentProfile().profile.preferredComposeModelRaw ?? ""
            },
            applier: { [weak self] rawValue in
                self?.setBuiltinChatModel(raw: rawValue)
            },
            thinkingGetter: { [weak self] in
                self?.currentProfile().profile.preferredComposeOhMyPiThinkingSelections ?? .empty
            },
            thinkingApplier: { [weak self] selections in
                self?.setBuiltinChatThinkingSelections(selections)
            }
        )
    }

    /// Destination for the Context Builder agent model and its OMP thinking selection.
    var contextBuilderAgentModelDestination: ModelDestination {
        ModelDestination(
            id: "agentModels.contextBuilderAgentModel",
            getter: { [weak self] in
                guard let self else { return "" }
                return currentContextBuilderSelection().modelRaw
            },
            applier: { [weak self] rawValue in
                guard let self else { return }
                setContextBuilderSelection(
                    agent: currentContextBuilderSelection().agent,
                    modelRaw: rawValue
                )
            },
            thinkingGetter: { [weak self] in
                self?.currentProfile().profile.contextBuilderOhMyPiThinkingSelections ?? .empty
            },
            thinkingApplier: { [weak self] selections in
                self?.updateSelectedProfile(
                    reason: "agent_models.context_builder_thinking",
                    contextBuilderWriteIntent: .userInitiated
                ) { profile in
                    profile.contextBuilderOhMyPiThinkingSelections = selections
                }
            }
        )
    }

    // MARK: - Oracle / Built-in Chat setters

    func setOracleModel(raw: String) {
        updateSelectedProfile(reason: "agent_models.oracle_model") { profile in
            profile.planningModelRaw = raw
            if profile.syncChatModelWithOracle {
                profile.preferredComposeModelRaw = raw
                profile.preferredComposeOhMyPiThinkingSelections =
                    profile.planningModelOhMyPiThinkingSelections
            }
        }
    }

    func setBuiltinChatModel(raw: String) {
        updateSelectedProfile(reason: "agent_models.builtin_chat_model") { profile in
            profile.preferredComposeModelRaw = raw
            if profile.syncChatModelWithOracle,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.planningModelRaw = raw
                profile.planningModelOhMyPiThinkingSelections =
                    profile.preferredComposeOhMyPiThinkingSelections
            }
        }
    }

    private func setOracleThinkingSelections(_ selections: OhMyPiThinkingSelections) {
        updateSelectedProfile(reason: "agent_models.oracle_thinking") { profile in
            profile.planningModelOhMyPiThinkingSelections = selections
            if profile.syncChatModelWithOracle,
               let modelRaw = profile.planningModelRaw,
               !modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.preferredComposeModelRaw = modelRaw
                profile.preferredComposeOhMyPiThinkingSelections = selections
            }
        }
    }

    private func setBuiltinChatThinkingSelections(_ selections: OhMyPiThinkingSelections) {
        updateSelectedProfile(reason: "agent_models.builtin_chat_thinking") { profile in
            profile.preferredComposeOhMyPiThinkingSelections = selections
            if profile.syncChatModelWithOracle,
               let modelRaw = profile.preferredComposeModelRaw,
               !modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.planningModelRaw = modelRaw
                profile.planningModelOhMyPiThinkingSelections = selections
            }
        }
    }

    // MARK: - Copy Actions

    func copyGlobalSettingsToWorkspaceOverrides() {
        guard let workspaceID else { return }
        settingsManager.copyAgentModelsProfile(from: .global, to: .workspace(workspaceID))
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.copy_global_to_workspace")
    }

    func copyWorkspaceSettingsToGlobal() {
        guard let workspaceID else { return }
        settingsManager.copyAgentModelsProfile(from: .workspace(workspaceID), to: .global)
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: "agent_models.copy_workspace_to_global")
    }

    // MARK: - Row-level Apply

    func applyOracleRecommendation() {
        guard workspaceID != nil,
              let rec = recommendations.chatModel,
              let recommendedModelRaw = engine.recommendedChatModelRaw(rec, backend: rec.defaultBackend)
        else {
            return
        }

        updateSelectedProfile(reason: "agent_models.apply_oracle_recommendation") { profile in
            profile.planningModelRaw = recommendedModelRaw
            profile.preferredComposeModelRaw = recommendedModelRaw
            // Recommendations have always set both model fields regardless of the sync toggle.
            // Thinking ownership remains directional, so only sync an existing map when opted in.
            if profile.syncChatModelWithOracle,
               !recommendedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.preferredComposeOhMyPiThinkingSelections =
                    profile.planningModelOhMyPiThinkingSelections
            }
        }
        postRecommendationsDidApply(reason: "agent_models.apply_oracle_recommendation")
    }

    func applyContextBuilderRecommendation() {
        guard let rec = recommendations.contextBuilder,
              workspaceID != nil else { return }
        let recommendedModelRaw = engine.recommendedContextBuilderModelRaw(rec)
        updateSelectedProfile(
            reason: "agent_models.apply_context_builder_recommendation",
            contextBuilderWriteIntent: .userInitiated
        ) { profile in
            profile.contextBuilderAgentRaw = rec.recommendedAgent.rawValue
            profile = profile.replacingContextBuilderModel(recommendedModelRaw, for: rec.recommendedAgent.rawValue)
        }
        postRecommendationsDidApply(reason: "agent_models.apply_context_builder_recommendation")
    }

    func applyRoleDefault(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) {
        updateSelectedProfile(reason: "agent_models.role_defaults") { profile in
            var overrides = profile.mcpAgentRoleOverrides ?? [:]
            overrides.removeValue(forKey: resolution.role.rawValue)
            profile.mcpAgentRoleOverrides = overrides.isEmpty ? nil : overrides
        }
        postAgentRoleDefaultsChanged()
    }

    func resetAllRoleDefaults() {
        persistRoleDefaultOverrides(nil)
    }

    func setRoleDefaultSelection(
        _ selection: AgentModelCatalog.NormalizedAgentSelection,
        for role: AgentModelCatalog.TaskLabelKind
    ) {
        updateSelectedProfile(reason: "agent_models.role_defaults") { profile in
            var overrides = profile.mcpAgentRoleOverrides ?? [:]
            let selectionID = AgentModelSelectionID(
                agentRaw: selection.agent.rawValue,
                modelRaw: selection.modelRaw
            )
            // Keep explicit role picks durable even when they currently match the recommendation;
            // `applyRoleDefault` / reset actions are the explicit path back to recommendation-tracking.
            overrides[role.rawValue] = selectionID.rawValue
            profile.mcpAgentRoleOverrides = overrides
        }
        postAgentRoleDefaultsChanged()
    }

    // MARK: - Bulk Apply

    func applyAllRecommendations(includePresetExposure: Bool = false) {
        guard showsRecommendationActions else { return }
        guard workspaceID != nil else { return }
        isApplyingAll = true

        let current = currentProfile()
        var profile = current.profile
        var didMutateProfile = false
        if let chat = recommendations.chatModel,
           let recommendedModelRaw = engine.recommendedChatModelRaw(chat, backend: chat.defaultBackend)
        {
            profile.planningModelRaw = recommendedModelRaw
            profile.preferredComposeModelRaw = recommendedModelRaw
            // The legacy recommendation path writes both models even with sync off; unlike the
            // model write, the whole-map copy remains opt-in and never clears independent maps.
            if profile.syncChatModelWithOracle,
               !recommendedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                profile.preferredComposeOhMyPiThinkingSelections =
                    profile.planningModelOhMyPiThinkingSelections
            }
            didMutateProfile = true
        }
        if let cb = recommendations.contextBuilder {
            let recommendedModelRaw = engine.recommendedContextBuilderModelRaw(cb)
            profile.contextBuilderAgentRaw = cb.recommendedAgent.rawValue
            profile = profile.replacingContextBuilderModel(recommendedModelRaw, for: cb.recommendedAgent.rawValue)
            didMutateProfile = true
        }
        if recommendations.mcpAgentDefaults != nil {
            profile.mcpAgentRoleOverrides = nil
            didMutateProfile = true
        }
        if didMutateProfile {
            persistSelectedProfile(
                profile,
                scope: current.scope,
                reason: "agent_models.apply_all_recommendations",
                contextBuilderWriteIntent: recommendations.contextBuilder == nil
                    ? .preserveExistingOwnership
                    : .userInitiated
            )
        }
        if includePresetExposure, let presetExposure = recommendations.mcpPresetExposure {
            engine.applyMCPPresetExposure(presetExposure)
        }
        if !didMutateProfile {
            reloadScopedState()
            refresh()
        }
        postRecommendationsDidApply(reason: "agent_models.apply_all_recommendations")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isApplyingAll = false
        }
    }

    // MARK: - Context Builder Menu

    func contextBuilderAgentModelMenuItems(windowID: Int) -> [StableMenuItem] {
        let selection = currentContextBuilderSelection()
        let thinkingDestination = contextBuilderAgentModelDestination
        let onSelect: (AgentProviderKind, AgentModelOption) -> Bool = { [weak self] selectedAgent, selectedOption in
            guard let self else { return false }
            setContextBuilderSelection(agent: selectedAgent, modelRaw: selectedOption.rawValue)
            OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
                agent: selectedAgent,
                rawModel: selectedOption.rawValue
            )
            return true
        }
        var items = AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            if agent == .ohMyPi {
                return AgentModelStableMenuItems.agentSubmenu(
                    agentKind: agent,
                    options: AgentModelCatalog.options(for: agent, availability: availability),
                    selectedAgent: selection.agent,
                    selectedModelRaw: selection.modelRaw,
                    thinkingDestination: thinkingDestination,
                    onSelect: onSelect
                )
            }
            return AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: selection.agent,
                selectedModelRaw: selection.modelRaw
            ) { selectedAgent, selectedOption in
                _ = onSelect(selectedAgent, selectedOption)
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: AgentModelCatalog.selectableAgents(availability: availability)
        )
        return items
    }

    func roleDefaultMenuItems(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> [StableMenuItem] {
        let onSelect: (AgentProviderKind, AgentModelOption) -> Bool = { [weak self] selectedAgent, selectedOption in
            guard let self else { return false }
            let selection = AgentModelCatalog.NormalizedAgentSelection(
                agent: selectedAgent,
                modelRaw: selectedOption.rawValue
            )
            setRoleDefaultSelection(selection, for: resolution.role)
            OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
                agent: selectedAgent,
                rawModel: selectedOption.rawValue
            )
            return true
        }
        let thinkingDestination = roleDefaultThinkingDestination(for: resolution)
        return AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            if agent == .ohMyPi {
                return AgentModelStableMenuItems.agentSubmenu(
                    agentKind: agent,
                    options: AgentModelCatalog.options(for: agent, availability: availability),
                    selectedAgent: resolution.effective.agent,
                    selectedModelRaw: resolution.effective.modelRaw,
                    includePlaceholderDefault: false,
                    flattenSingleCodexGroups: true,
                    groupOpenCode: false,
                    thinkingDestination: thinkingDestination,
                    onSelect: onSelect
                )
            }
            return AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: resolution.effective.agent,
                selectedModelRaw: resolution.effective.modelRaw,
                includePlaceholderDefault: false,
                flattenSingleCodexGroups: true,
                groupOpenCode: false
            ) { selectedAgent, selectedOption in
                _ = onSelect(selectedAgent, selectedOption)
            }
        }
    }

    private func roleDefaultThinkingDestination(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> ModelDestination {
        let role = resolution.role
        return ModelDestination(
            id: "agentModels.roleDefault.\(role.rawValue)",
            getter: { [weak self] in
                self?.roleDefaultsResolutions.first(where: { $0.role == role })?.effective.modelRaw
                    ?? resolution.effective.modelRaw
            },
            applier: { _ in },
            thinkingGetter: { [weak self] in
                self?.currentProfile().profile.mcpAgentRoleOhMyPiThinkingSelections?[role.rawValue] ?? .empty
            },
            thinkingApplier: { [weak self] selections in
                guard let self else { return }
                updateSelectedProfile(reason: "agent_models.role_thinking") { profile in
                    var selectionsByRole = profile.mcpAgentRoleOhMyPiThinkingSelections ?? [:]
                    selectionsByRole[role.rawValue] = selections.nilIfEmpty
                    profile.mcpAgentRoleOhMyPiThinkingSelections = selectionsByRole.isEmpty ? nil : selectionsByRole
                }
                postAgentRoleDefaultsChanged()
            }
        )
    }

    // MARK: - Private helpers

    private static func inheritanceMode(
        settingsManager: any SettingsManaging,
        workspaceID: UUID?
    ) -> AgentModelsInheritanceMode {
        guard let workspaceID else { return .useGlobalSettings }
        return settingsManager.workspaceAgentModelsSettings(for: workspaceID).inheritanceMode
    }

    private static func profile(
        settingsManager: any SettingsManaging,
        workspaceID: UUID?,
        inheritanceMode: AgentModelsInheritanceMode
    ) -> AgentModelsSettingsProfile {
        guard let workspaceID, inheritanceMode == .useWorkspaceOverrides else {
            return settingsManager.globalAgentModelsProfile()
        }
        return settingsManager.workspaceAgentModelsProfile(for: workspaceID)
            ?? settingsManager.effectiveAgentModelsProfile(workspaceID: workspaceID)
    }

    private func currentProfile() -> (
        scope: AgentModelsEditingScope,
        profile: AgentModelsSettingsProfile
    ) {
        let currentInheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let scope: AgentModelsEditingScope = if let workspaceID, currentInheritanceMode == .useWorkspaceOverrides {
            .workspace(workspaceID)
        } else {
            .global
        }
        return (
            scope,
            Self.profile(
                settingsManager: settingsManager,
                workspaceID: workspaceID,
                inheritanceMode: currentInheritanceMode
            )
        )
    }

    private func currentContextBuilderSelection() -> AgentModelCatalog.NormalizedAgentSelection {
        let profile = currentProfile().profile
        let selectedAgentRaw = profile.contextBuilderAgentRaw
        let selectedModelRaw = selectedAgentRaw.flatMap { profile.contextBuilderModelsByAgent?[$0] }
        return AgentModelCatalog.normalizeSelection(
            agentRaw: selectedAgentRaw,
            modelRaw: selectedModelRaw,
            availability: availability
        )
    }

    private func observeNotifications() {
        notificationCenter.publisher(for: .recommendationsShouldRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadScopedState()
                self?.refresh()
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .agentModelsSettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAgentModelsSettingsDidChange(notification)
            }
            .store(in: &cancellables)
    }

    private func handleAgentModelsSettingsDidChange(_ notification: Notification) {
        let scopeRaw = notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
        let workspaceID = notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
        if scopeRaw == AgentModelsSettingsNotification.Scope.workspace.rawValue,
           workspaceID != self.workspaceID
        {
            return
        }
        reloadScopedState()
        refresh()
    }

    private func reloadScopedState() {
        let nextInheritanceMode = Self.inheritanceMode(
            settingsManager: settingsManager,
            workspaceID: workspaceID
        )
        let nextProfile = Self.profile(
            settingsManager: settingsManager,
            workspaceID: workspaceID,
            inheritanceMode: nextInheritanceMode
        )
        isReloadingScopedState = true
        inheritanceMode = nextInheritanceMode
        profileSnapshot = nextProfile
        syncChatWithOracle = nextProfile.syncChatModelWithOracle
        restrictMCPAgentDiscoveryToRoleLabels = nextProfile.restrictMCPAgentDiscoveryToRoleLabels
        isReloadingScopedState = false
    }

    private func updateSelectedProfile(
        reason: String,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership,
        _ mutation: (inout AgentModelsSettingsProfile) -> Void
    ) {
        let current = currentProfile()
        var profile = current.profile
        mutation(&profile)
        persistSelectedProfile(
            profile,
            scope: current.scope,
            reason: reason,
            contextBuilderWriteIntent: contextBuilderWriteIntent
        )
    }

    private func persistSelectedProfile(
        _ profile: AgentModelsSettingsProfile,
        scope: AgentModelsEditingScope,
        reason: String,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership
    ) {
        switch scope {
        case .global:
            settingsManager.setGlobalAgentModelsProfile(
                profile,
                contextBuilderWriteIntent: contextBuilderWriteIntent
            )
        case let .workspace(workspaceID):
            settingsManager.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile)
        }
        reloadScopedState()
        refresh()
        postShouldRefresh(reason: reason)
    }

    private func persistRoleDefaultOverrides(_ overrides: [String: String]?) {
        updateSelectedProfile(reason: "agent_models.role_defaults") { profile in
            profile.mcpAgentRoleOverrides = overrides
        }
        postAgentRoleDefaultsChanged()
    }

    private func setContextBuilderSelection(agent: AgentProviderKind, modelRaw: String) {
        updateSelectedProfile(
            reason: "agent_models.context_builder",
            contextBuilderWriteIntent: .userInitiated
        ) { profile in
            profile.contextBuilderAgentRaw = agent.rawValue
            profile = profile.replacingContextBuilderModel(modelRaw, for: agent.rawValue)
        }
    }

    private func postShouldRefresh(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var userInfo: [String: Any] = ["reason": reason]
            if let workspaceID {
                userInfo["workspaceID"] = workspaceID
            }
            notificationCenter.post(
                name: .recommendationsShouldRefresh,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func postRecommendationsDidApply(reason: String) {
        var userInfo: [String: Any] = [
            "reason": reason,
            AgentModelsSettingsNotification.scopeKey: isEditingWorkspaceSettings
                ? AgentModelsSettingsNotification.Scope.workspace.rawValue
                : AgentModelsSettingsNotification.Scope.global.rawValue
        ]
        if case let .workspace(workspaceID) = editingScope {
            userInfo["workspaceID"] = workspaceID
        }
        if let workspaceID {
            userInfo["sourceWorkspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsDidApply,
            object: nil,
            userInfo: userInfo
        )
    }

    private func postAgentRoleDefaultsChanged() {
        var userInfo: [String: Any] = [
            "reason": "agentRoleDefaultsChanged",
            "scope": isEditingWorkspaceSettings ? "workspace" : "global"
        ]
        if let workspaceID {
            userInfo["workspaceID"] = workspaceID
        }
        notificationCenter.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: userInfo
        )
        refresh()
    }

    static func displayName(forChatModelRaw raw: String?, fallback: String) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return fallback
        }
        guard let model = AIModel.fromModelName(raw) else { return raw }
        if case let .cursorCustom(modelRaw) = model {
            return AgentModelCatalog.displayName(
                for: modelRaw,
                agentKind: .cursor,
                availability: .init(cursorAvailable: true),
                includeCursorParameterSuffix: true
            )
        }
        return model.displayName
    }
}
