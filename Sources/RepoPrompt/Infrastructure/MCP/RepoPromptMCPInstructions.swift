//
//  RepoPromptMCPInstructions.swift
//  RepoPrompt
//
//  MCP server initialization instructions for agents.
//

import Foundation

/// Instructions text returned in the MCP Initialize response.
/// Tailored per `MCPRunPurpose` so each connection only sees guidance for its available tools.
enum RepoPromptMCPInstructions {
    /// Returns instructions text appropriate for the given run purpose.
    /// - Parameters:
    ///   - purpose: Connection/run purpose used to tailor guidance.
    ///   - codeMapsDisabled: When true, omit Code Map tools from instructions.
    static func text(for purpose: MCPRunPurpose = .unknown, codeMapsDisabled: Bool = false) -> String {
        switch purpose {
        case .agentModeRun:
            agentModeText(codeMapsDisabled: codeMapsDisabled)
        case .discoverRun:
            discoverText(codeMapsDisabled: codeMapsDisabled)
        case .unknown:
            externalMCPText(codeMapsDisabled: codeMapsDisabled)
        }
    }

    // MARK: - Per-purpose instructions

    private static let routingAndBoundaries = """
    ROUTING AND BOUNDARIES:
    - `file_search` locates paths or content across workspace roots with literal or regex matching.
    - `get_file_tree` maps directories with configurable depth and detail.
    - `read_file` returns full files or precise line ranges.
    - `apply_edits` applies targeted replacements, transaction groups, or complete-file rewrites, and creates new files.
    """

    private static let contextWorkflow = "CONTEXT WORKFLOW: `manage_selection` curates the files and slices used by Oracle; update it before Oracle calls. `workspace_context` renders that selection. Add or remove incrementally; reserve set mode=full for complete replacement and set mode=slices for file-scoped slice replacement."

    private static func additionalCapabilities(codeMapsDisabled: Bool) -> String {
        codeMapsDisabled
            ? "Additional capabilities: `file_actions` creates, deletes, or moves files, and `git` reports status, diffs, history, and blame. Code Maps are globally disabled; use `file_search` and targeted `read_file` for structure."
            : "Additional capabilities: `get_code_structure` returns function and type signatures, `file_actions` creates, deletes, or moves files, and `git` reports status, diffs, history, and blame."
    }

    /// Full toolset with `ask_oracle`, no bind_context.
    private static func agentModeText(codeMapsDisabled: Bool) -> String {
        """
        RepoPrompt provides workspace-aware tools for reliable, token-efficient repository work.

        \(routingAndBoundaries)

        \(additionalCapabilities(codeMapsDisabled: codeMapsDisabled))

        \(contextWorkflow)

        CONTEXT BUILDING: `context_builder` explores the repository and prepares curated context for a plan, review, or question. Continue its stateful result with `ask_oracle` using the returned chat_id.

        DELEGATION: Follow the system prompt's named control tool when a fresh Agent Mode session or read-only probe is useful.

        EXPORT SHARING: Set `export_response: true` on `context_builder` or `ask_oracle`. The result includes `oracle_export_path` and `oracle_export_instruction`. Pass the exported path or instruction in the delegated child's `message`; the child can open it with `read_file`.
        """
    }

    /// Full toolset with `oracle_send` and bind_context for external MCP clients.
    private static func externalMCPText(codeMapsDisabled: Bool) -> String {
        """
        RepoPrompt provides workspace-aware tools for reliable, token-efficient repository work. These tools are the primary interface to this workspace: they span all bound roots and feed the shared Oracle selection.

        \(routingAndBoundaries)

        \(additionalCapabilities(codeMapsDisabled: codeMapsDisabled))

        \(contextWorkflow)

        CONTEXT BUILDING: `context_builder` explores the repository and prepares curated context for a plan, review, or question. Continue its stateful result with `oracle_send` using the returned chat_id.

        DELEGATION: `agent_run` starts or drives a separate Agent Mode session when a fresh workstream is appropriate; pass model_id with a role: explore (lightweight, read-only), engineer, pair, or design.

        EXPORT SHARING: Set `export_response: true` on `context_builder` or `oracle_send`. The result includes `oracle_export_path` and `oracle_export_instruction`. Pass the exported path or instruction in the delegated child's `message` for the next `agent_run`; the child can open it with `read_file`.

        TAB ROUTING: Workspace tabs isolate tab contexts. Use `bind_context` with `context_id` to bind this connection to the intended tab and workspace context.
        """
    }

    /// Read-only tools - no editing, oracle, context_builder, or delegation.
    private static func discoverText(codeMapsDisabled: Bool) -> String {
        let codeStructureLine = codeMapsDisabled
            ? "- Code Maps are globally disabled; use `file_search` and targeted `read_file` for structure."
            : "- `get_code_structure` returns function and type signatures without loading full files."
        return """
        RepoPrompt provides a reduced read-only workspace surface for repository discovery.

        AVAILABLE CAPABILITIES:
        - `file_search` locates paths or content across workspace roots with literal or regex matching.
        - `get_file_tree` maps directories with configurable depth and detail.
        - `read_file` returns full files or precise line ranges.
        \(codeStructureLine)
        - `manage_selection` curates files and slices for the response.
        - `workspace_context` renders the current selection as a snapshot.
        - `git` reports status, diffs, history, and blame without repository mutation.
        """
    }
}
