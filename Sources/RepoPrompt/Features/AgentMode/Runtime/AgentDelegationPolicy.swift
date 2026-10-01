import Foundation

/// Bounded RepoPrompt MCP delegation.
///
/// Delegation depth is derived from the existing `parentSessionID` lineage (never persisted):
/// a parentless session is depth 0, its child depth 1, and its grandchild depth 2. Non-explore
/// sessions at depths 0 and 1 may delegate (`agent_run`, `agent_manage`, `agent_explore`);
/// depth ≥ 2 sessions, explore sessions at any depth, and sessions whose lineage is missing,
/// cyclic, or inconsistent are delegation leaves. The ceiling applies to Agent Mode sessions
/// only; external MCP clients without an Agent Mode source keep their existing surface.
///
/// Related:
/// - AgentModeViewModel.mcpDelegationLineage / mcpValidateAgentRunSpawnAllowed (live/index lookup, admission)
/// - AgentModeRunLease.swift (leaf restrictions folded into `restrictedTools`)
/// - AgentModeMCPToolAdvertisementPolicy.swift (advertisement-only flag)
/// - docs/context/agent-mcp-delegation-depth.md (owning contract)
enum AgentDelegationPolicy {
    /// Deepest lineage depth that may still start or control delegated agents.
    static let maximumDelegatingDepth = 1

    /// Every RepoPrompt MCP delegation tool: `agent_run`, `agent_manage`, and `agent_explore`.
    static let delegationToolNames: Set<String> = MCPToolCapabilities.toolNames(
        for: [.agentExternalControl, .agentExploreControl]
    )

    /// Parent relationship recorded for one known session.
    enum ParentLookup: Equatable {
        /// Known session without a parent.
        case root
        /// Known session with this parent.
        case parent(UUID)
        /// No live or owner-validated indexed record for the session.
        case unknown
        /// Ambiguous live binding or disagreeing live/indexed parents.
        case inconsistent
    }

    enum LineageResolution: Equatable {
        case resolved(depth: Int)
        case unresolved
        case cyclic
        case inconsistent

        var depth: Int? {
            if case let .resolved(depth) = self { return depth }
            return nil
        }
    }

    enum Decision: Equatable {
        case eligible(depth: Int)
        case exploreLeaf
        case depthLimit(depth: Int)
        case lineageFailure(LineageResolution)

        var canDelegate: Bool {
            if case .eligible = self { return true }
            return false
        }
    }

    /// Per-run MCP tool policy derived from one delegation decision.
    struct RunToolPolicy: Equatable {
        /// Advertisement-only exception that restores `agent_run`/`agent_manage` for named roles.
        let allowsAgentExternalControlTools: Bool
        /// Execution-time restrictions unioned into the run's existing `restrictedTools`.
        let additionalRestrictedTools: Set<String>
        /// Delegation surface the production prompt may describe.
        let promptAudience: ExportDelegationAudience

        static let leaf = RunToolPolicy(
            allowsAgentExternalControlTools: false,
            additionalRestrictedTools: AgentDelegationPolicy.delegationToolNames,
            promptAudience: .none
        )
    }

    /// Walks parent edges from a session whose own parent relationship is `startingParent`.
    /// Counts edges until a root; repeated IDs (including self-parenting) are cyclic, and any
    /// unknown or inconsistent ancestor fails closed.
    static func resolveLineage(
        sessionID: UUID?,
        startingParent: ParentLookup,
        parentOf: (UUID) -> ParentLookup
    ) -> LineageResolution {
        var visited: Set<UUID> = []
        if let sessionID { visited.insert(sessionID) }
        var depth = 0
        var current = startingParent
        while true {
            switch current {
            case .root:
                return .resolved(depth: depth)
            case .unknown:
                return .unresolved
            case .inconsistent:
                return .inconsistent
            case let .parent(parentID):
                guard visited.insert(parentID).inserted else { return .cyclic }
                depth += 1
                current = parentOf(parentID)
            }
        }
    }

    /// Explore is a leaf at every depth. A nil role (explicit-model session) is not a lineage
    /// failure and is judged by depth like any named non-explore role.
    static func decision(
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        lineage: LineageResolution
    ) -> Decision {
        if taskLabelKind == .explore { return .exploreLeaf }
        guard let depth = lineage.depth else { return .lineageFailure(lineage) }
        return depth <= maximumDelegatingDepth ? .eligible(depth: depth) : .depthLimit(depth: depth)
    }

    static func runToolPolicy(
        decision: Decision,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> RunToolPolicy {
        guard decision.canDelegate else { return .leaf }
        return RunToolPolicy(
            allowsAgentExternalControlTools: true,
            additionalRestrictedTools: [],
            // Nil-role sessions keep their existing agent_run/agent_manage surface; named
            // non-explore roles additionally see agent_explore.
            promptAudience: taskLabelKind == nil ? .agentRunOnly : .both
        )
    }

    /// Caller-facing denial for a decision that cannot delegate; nil when delegation is allowed.
    static func denialMessage(for decision: Decision) -> String? {
        switch decision {
        case .eligible:
            nil
        case .exploreLeaf:
            "Explore agents cannot start or control other agents."
        case let .depthLimit(depth):
            "This agent session is at delegation depth \(depth); RepoPrompt allows delegation only from depth 0 (main) and depth 1 (worker) sessions, so sub-workers cannot start or control other agents."
        case let .lineageFailure(resolution):
            "RepoPrompt could not verify this agent session's delegation lineage (\(lineageFailureLabel(resolution))). Refusing to start or control other agents."
        }
    }

    private static func lineageFailureLabel(_ resolution: LineageResolution) -> String {
        switch resolution {
        case .resolved:
            "resolved"
        case .unresolved:
            "missing ancestor"
        case .cyclic:
            "cyclic ancestry"
        case .inconsistent:
            "inconsistent ancestry"
        }
    }
}
