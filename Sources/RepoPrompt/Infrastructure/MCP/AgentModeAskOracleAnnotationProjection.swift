import MCP

/// Per-connection `tools/list` annotation adjustment for app-owned Agent Mode runs.
///
/// Canonical catalog metadata for `ask_oracle` stays `readOnlyHint: false` (the tool spends
/// money, creates chat state, and is non-idempotent). Only the wire projection for connections
/// whose purpose the server itself established as `.agentModeRun` advertises
/// `readOnlyHint: true`, so Claude Code's harness may overlap two `ask_oracle` calls.
///
/// Classification must use server-established run purpose (`MCPRunPurpose.agentModeRun` from
/// pending `ClientConnectionPolicy` / live run-affinity hydration) — never spoofable
/// initialize `clientInfo.name` strings.
///
/// Side effect: Claude plan mode treats read-only-hinted tools as invocable. That is accepted
/// for app-owned Agent Mode connections; external MCP clients keep `readOnlyHint: false`.
enum AgentModeAskOracleAnnotationProjection {
    static func project(
        _ canonical: MCP.Tool.Annotations,
        toolName: String,
        runPurpose: MCPRunPurpose
    ) -> MCP.Tool.Annotations {
        guard toolName == MCPWindowToolName.askOracle,
              runPurpose == .agentModeRun
        else {
            return canonical
        }

        var projected = canonical
        projected.readOnlyHint = true
        return projected
    }
}

/// Composes connection-specific `tools/list` annotation projections.
enum MCPToolListAnnotationProjection {
    static func project(
        _ canonical: MCP.Tool.Annotations,
        toolName: String,
        clientIdentifier: String?,
        runPurpose: MCPRunPurpose
    ) -> MCP.Tool.Annotations {
        let afterCodex = CodexMCPToolAnnotationProjection.project(
            canonical,
            clientIdentifier: clientIdentifier
        )
        return AgentModeAskOracleAnnotationProjection.project(
            afterCodex,
            toolName: toolName,
            runPurpose: runPurpose
        )
    }
}
