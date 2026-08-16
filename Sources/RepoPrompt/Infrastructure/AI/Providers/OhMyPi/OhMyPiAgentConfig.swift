import Foundation

/// Fixed RepoPrompt-managed configuration for Oh My Pi's ACP runtime.
///
/// OMP is intentionally launched without native tools, extensions, skills, or rules.
/// These arguments are not user-overridable. Agent Mode injects RepoPrompt MCP as its
/// sole tool surface; tool-free Oracle requests explicitly disable that injection.
struct OhMyPiAgentConfig {
    static let minimumSupportedVersion = [17, 2, 12]
    static let managedArguments = [
        "acp",
        "--no-tools",
        "--no-extensions",
        "--no-skills",
        "--no-rules",
        "--approval-mode",
        "yolo"
    ]
    static let managedEnvironment = ["OMP_MCP_TIMEOUT_MS": "0"]
    static let requiredManagedFlags = [
        "--no-tools",
        "--no-extensions",
        "--no-skills",
        "--no-rules",
        "--approval-mode"
    ]

    let commandName: String
    let additionalPathHints: [String]
    let modelString: String?
    let additionalConfigOptionValues: [ACPConfigOptionAssignment]
    let enableDebugLogging: Bool
    let includeRepoPromptMCPServer: Bool

    init(
        commandName: String = "omp",
        additionalPathHints: [String] = CLIPathHints.ohMyPi,
        modelString: String? = nil,
        additionalConfigOptionValues: [ACPConfigOptionAssignment] = [],
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.additionalConfigOptionValues = additionalConfigOptionValues
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
    }
}
