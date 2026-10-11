import Foundation

/// Purpose of an MCP connection's run, used to route UI (e.g., ask_user) to the correct surface.
public enum MCPRunPurpose: String, Sendable, Codable {
    case discoverRun // Context Builder agent exploring codebase
    case agentModeRun // Agent mode interactive session
    case unknown // No policy or unspecified
}
