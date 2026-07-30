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
        MCPWindowToolName.oracleChatLog
    ]
}
