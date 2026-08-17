import Foundation
import MCP

// SEARCH-HELPER: model_id, compound identifier, task label, agent+model resolution, MCP parsing, global role defaults
// Related:
// - AgentModelSelectionID.swift (compound ID format)
// - AgentModelCatalog.swift (discovery/validation/task label recommendations)
// - MCPAgentRoleDefaultsService.swift (scoped role-default overrides)
// - AgentRunMCPToolService.swift / AgentManageMCPToolService.swift (consumers)

/// Resolves `model_id` into agent + model for session configuration.
///
/// Accepts two forms:
/// 1. **Task label**: `explore`, `engineer`, `pair`, `design` — auto-picks the effective role default
/// 2. **Compound ID**: `claudeCode:sonnet`, `codexExec:gpt-5.4-high` — explicit selection
enum AgentMCPSelectionResolver {
    typealias RoleSelectionProvider = @MainActor (
        _ role: AgentModelCatalog.TaskLabelKind,
        _ availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelCatalog.NormalizedAgentSelection?

    struct ResolvedSelection {
        let agentRaw: String?
        let modelRaw: String?
        /// The resolved task label kind, if the selection was role-driven.
        /// `nil` when the model_id was a compound ID or no role was involved.
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        /// Narrowed to the effective exact OMP model for role-driven resolution.
        /// Compound IDs, non-OMP roles, fallbacks, and injected selection providers carry empty intent.
        let ohMyPiThinkingSelections: OhMyPiThinkingSelections
    }

    private struct EffectiveRoleSelection {
        let selection: AgentModelCatalog.NormalizedAgentSelection
        let ohMyPiThinkingSelections: OhMyPiThinkingSelections
    }

    /// Resolves a `model_id` string into agent + model components.
    ///
    /// - If `modelID` is nil/empty and `defaultTaskLabel` is provided, resolves that role's effective default.
    /// - If `modelID` is nil/empty and no default is provided, returns nils (use agent defaults).
    /// - Task labels (`explore`, `engineer`, `pair`, `design`) resolve through effective role defaults.
    /// - Compound IDs are validated against the catalog and are never rewritten by role defaults.
    ///
    /// - Throws: `MCPError.invalidParams` for unrecognized or invalid IDs.
    @MainActor
    static func resolve(
        modelID: String?,
        defaultTaskLabel: AgentModelCatalog.TaskLabelKind? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        workspaceID: UUID? = nil,
        roleSelectionProvider: RoleSelectionProvider? = nil,
        roleDefaultsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) throws -> ResolvedSelection {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            // No explicit model_id — use default global role if provided
            if let defaultKind = defaultTaskLabel,
               let resolved = resolveRoleSelection(
                   defaultKind,
                   availability: availability,
                   workspaceID: workspaceID,
                   roleSelectionProvider: roleSelectionProvider,
                   roleDefaultsStore: roleDefaultsStore
               )
            {
                return ResolvedSelection(
                    agentRaw: resolved.selection.agent.rawValue,
                    modelRaw: resolved.selection.modelRaw,
                    taskLabelKind: defaultKind,
                    ohMyPiThinkingSelections: resolved.ohMyPiThinkingSelections
                )
            }
            return ResolvedSelection(
                agentRaw: nil,
                modelRaw: nil,
                taskLabelKind: nil,
                ohMyPiThinkingSelections: .empty
            )
        }

        // Try task label first (no colon = not a compound ID)
        if !trimmed.contains(":") {
            let lowered = trimmed.lowercased()
            if let entry = AgentModelCatalog.taskLabels.first(where: { $0.label == lowered }) {
                guard let resolved = resolveRoleSelection(
                    entry.kind,
                    availability: availability,
                    workspaceID: workspaceID,
                    roleSelectionProvider: roleSelectionProvider,
                    roleDefaultsStore: roleDefaultsStore
                ) else {
                    throw MCPError.invalidParams("No available agent/model for task label '\(trimmed)'.")
                }
                return ResolvedSelection(
                    agentRaw: resolved.selection.agent.rawValue,
                    modelRaw: resolved.selection.modelRaw,
                    taskLabelKind: entry.kind,
                    ohMyPiThinkingSelections: resolved.ohMyPiThinkingSelections
                )
            }
            let knownLabels = AgentModelCatalog.taskLabels.map(\.label).joined(separator: ", ")
            throw MCPError.invalidParams(
                "Unknown model_id '\(trimmed)'. Use a task label (\(knownLabels)) or a compound ID from agent_manage op=list_agents."
            )
        }

        // Parse compound ID
        guard let parsed = AgentModelSelectionID.parse(trimmed) else {
            throw MCPError.invalidParams(
                "Invalid model_id '\(trimmed)'. Use agent_manage op=list_agents to get valid model_id values."
            )
        }

        guard let agent = AgentProviderKind(rawValue: parsed.agentRaw) else {
            throw MCPError.invalidParams(
                "Unknown agent '\(parsed.agentRaw)' in model_id. Use agent_manage op=list_agents."
            )
        }

        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else {
            throw MCPError.invalidParams(
                "Agent '\(parsed.agentRaw)' is currently unavailable."
            )
        }

        // Codex is intentionally permissive for dynamic/stale model IDs
        if agent != .codexExec {
            guard AgentModelCatalog.isValid(rawModel: parsed.modelRaw, for: agent, availability: availability) else {
                throw MCPError.invalidParams(
                    "Model '\(parsed.modelRaw)' is not valid for agent '\(parsed.agentRaw)'. Use agent_manage op=list_agents."
                )
            }
        }

        return ResolvedSelection(
            agentRaw: parsed.agentRaw,
            modelRaw: parsed.modelRaw,
            taskLabelKind: nil,
            ohMyPiThinkingSelections: .empty
        )
    }

    @MainActor
    private static func resolveRoleSelection(
        _ role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext,
        workspaceID: UUID?,
        roleSelectionProvider: RoleSelectionProvider?,
        roleDefaultsStore: (any MCPAgentRoleDefaultsStoring)?
    ) -> EffectiveRoleSelection? {
        // Injected providers author only agent/model selection and cannot resolve scoped role thinking.
        // Keep their thinking map empty rather than consulting a second, potentially mismatched authority.
        if let provided = roleSelectionProvider?(role, availability) {
            return EffectiveRoleSelection(selection: provided, ohMyPiThinkingSelections: .empty)
        }
        if let effective = MCPAgentRoleDefaultsService.effectiveSelection(
            for: role,
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: roleDefaultsStore
        ) {
            return EffectiveRoleSelection(
                selection: effective.effective,
                ohMyPiThinkingSelections: effective.effectiveOhMyPiThinkingSelections
            )
        }
        return AgentModelCatalog.resolveTaskLabelKind(role, availability: availability).map {
            EffectiveRoleSelection(selection: $0, ohMyPiThinkingSelections: .empty)
        }
    }
}
