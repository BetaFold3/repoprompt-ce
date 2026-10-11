import Foundation

typealias AgentHeadlessProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) throws -> HeadlessAgentProvider
typealias AgentACPProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
typealias AgentACPControllerFactory = (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController
typealias AgentConnectionPolicyInstaller = (
    _ clientName: String,
    _ windowID: Int,
    _ restrictedTools: Set<String>,
    _ oneShot: Bool,
    _ reason: String?,
    _ ttl: TimeInterval,
    _ tabID: UUID?,
    _ runID: UUID?,
    _ additionalTools: Set<String>?,
    _ allowedToolsOverride: Set<String>?,
    _ sessionProfile: AgentSessionProfile,
    _ purpose: MCPRunPurpose,
    _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
    _ allowsAgentExternalControlTools: Bool,
    _ requiresExpectedAgentPID: Bool
) async -> Void
typealias AgentMCPServerEnabler = () async -> Void
typealias AgentCodexActiveToolQuery = (_ runID: UUID) -> Bool
typealias AgentCodexAgentRunWaitQuery = (_ runID: UUID) -> Bool
typealias AgentCodexAgentRunWaitDrain = @MainActor (
    _ runID: UUID,
    _ source: String
) async -> MCPServerViewModel.AgentRunWaitDrainOutcome
