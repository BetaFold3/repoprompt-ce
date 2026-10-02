/// Formats known raw RepoPrompt tool names without rewriting ordinary status prose.
enum AgentRunningStatusPresentation {
    static func displayText(for status: String?) -> String {
        guard let canonicalName = MCPIntegrationHelper.canonicalRepoPromptToolName(status) else {
            return status ?? "Thinking…"
        }
        return toolDisplayName(for: canonicalName)
    }
}
