import Foundation

/// OMP 17.2.12 emits RepoPrompt MCP tool titles as
/// `mcp__repopromptce_<tool>`. Canonicalize this observed presentation form for
/// cards and transcript tracking only; permission auto-approval retains stricter
/// protocol-level identity requirements.
enum OhMyPiACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(canonicalizedPayload(payload), providerID: .ohMyPi)
    }

    private static func canonicalizedPayload(_ payload: [String: Any]) -> [String: Any] {
        guard let updateKind = payload["sessionUpdate"] as? String,
              ["tool_call", "tool_call_update"].contains(updateKind),
              let title = payload["title"] as? String,
              let canonicalTitle = canonicalRepoPromptMCPTitle(title)
        else {
            return payload
        }

        var canonicalized = payload
        canonicalized["title"] = canonicalTitle
        return canonicalized
    }

    private static func canonicalRepoPromptMCPTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverName = RepoPromptMCPServerConfiguration.defaultServerName
        let prefix = "mcp__\(serverName.lowercased())_"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }

        let toolName = String(trimmed.dropFirst(prefix.count))
        let loweredToolName = toolName.lowercased()
        guard toolName.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil,
              !loweredToolName.hasPrefix("mcp_"),
              !loweredToolName.hasPrefix(serverName.lowercased() + "_"),
              let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName)
        else {
            return nil
        }
        return "mcp__\(serverName)__\(canonicalToolName)"
    }
}
