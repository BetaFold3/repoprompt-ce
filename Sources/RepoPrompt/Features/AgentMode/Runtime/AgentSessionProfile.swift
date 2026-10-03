import Foundation

enum AgentSessionProfile: String, Codable, Equatable {
    case standard
    case knowledge
}

enum KnowledgeSessionPolicy {
    static let supportedProvidersOrdered: [AgentProviderKind] = [
        .claudeCode,
        .codexExec
    ]

    static let supportedProviders = Set(supportedProvidersOrdered)

    static let allowedMCPToolNames: Set<String> = [
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.search,
        MCPWindowToolName.readFile,
        MCPWindowToolName.applyEdits,
        MCPWindowToolName.oracleUtils,
        MCPWindowToolName.askOracle,
        MCPWindowToolName.oracleChatLog,
        // Knowledge roots start and control fresh Knowledge research workers. Delegation leaf
        // restrictions remove it again for workers (`AgentDelegationPolicy.knowledgeLeaf`).
        MCPWindowToolName.agentRun
    ]

    /// Closed per-operation allowlist for `agent_run` calls from a Knowledge caller. An
    /// operation added to `agent_run` later stays denied for Knowledge sessions until it is
    /// listed here deliberately.
    static let allowedAgentRunOperations: Set<String> = [
        "start",
        "poll",
        "wait",
        "cancel",
        "steer",
        "respond"
    ]
}
