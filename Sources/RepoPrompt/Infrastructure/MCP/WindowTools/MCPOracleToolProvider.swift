import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPOracleToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .oracle

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            oracleUtilsTool(),
            askOracleTool(),
            oracleSendTool(),
            oracleChatLogTool()
        ]
    }

    private func oracleUtilsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleUtils,
            freshnessPolicy: .none,
            description: """
            Oracle helper utilities.

            Use this for read-only oracle-specific helpers:
            - `op="models"`   → list model choices relevant to oracle sends
            - `op="sessions"` → list oracle/chat sessions for the current workspace. Pass context_id to filter to a specific context's sessions.

            Model discovery lists only selectable models under Available models. If configured presets are disabled or temporarily hidden, it reports them separately as NOT selectable with exact remediation. Do not pass those presets to ask_oracle until they are enabled.

            Use `ask_oracle` for all send/continue turns.
            """,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Helper operation", enum: ["models", "sessions"]),
                    "limit": .integer(description: "Maximum sessions to return for the sessions operation"),
                    "scope": .string(description: "Filter scope: 'workspace' (default) or 'tab'. Auto-inferred when context_id is provided."),
                    "context_id": .string(description: "Context UUID to filter to a specific context's sessions. Use bind_context op=list to discover values.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleUtils(args)
        }
    }

    private func askOracleTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.askOracle,
            freshnessPolicy: .providerManaged,
            description: """
            Agent-mode oracle send/continue tool.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode for the current agent tab.

            To run two independent consultations concurrently, issue two calls with `new_chat:true`, a distinct exact model preset ID/name from `oracle_utils op=models`, and optionally distinct `chat_name` values. Continue each lane with its returned `chat_id`. Reusing a streaming chat returns `oracle_session_busy`; a third simultaneous MCP Oracle stream in the tab returns `oracle_concurrency_limit`. Under parallel use, always pass an explicit `chat_id` to `oracle_chat_log`.

            A `chat_id` continuation stays on the model preset that chat last used, so `model` can be omitted and the lane will not drift. Passing a different `model` with `chat_id` deliberately switches that lane from then on. If the chat's preset was deleted, disabled, or no longer supports the requested `mode`, the call fails instead of silently substituting another model. A manual send into the chat from the app resets its preset binding. Each result reports how the model was chosen through `model_selection` (`explicit`, `inherited`, or `automatic`).

            When the user names one or more Oracles, treat those names as model-preset selectors. First resolve them with `oracle_utils op=models`, prefer each returned exact preset UUID, and pass an explicit `model` on every new-chat lane. Issue independent lanes together in one tool-call batch. `chat_name` is display-only and never selects a model. Before synthesizing, verify each result's returned preset ID/name matches the requested preset; if identity is missing or mismatched, do not synthesize.

            Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            Use `oracle_chat_log` after compaction to recover recent oracle messages.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "message": .string(
                        description: "Your message to send",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current agent tab. The chat keeps the model preset it last used, so `model` can be omitted."
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false). Keep false for continuity; use true for an independent review or each independent parallel lane. When multiple compatible presets exist, new chats require an explicit model."
                    ),
                    "model": .string(
                        description: "Exact model preset UUID (preferred) or exact preset name from oracle_utils op=models. Required when the user requests a named Oracle. Omit it with `chat_id` to keep that chat's current preset; passing a different preset switches the chat to it."
                    ),
                    "chat_name": .string(
                        description: "Optional display-only session name; valid only with new_chat:true. This never selects the model."
                    ),
                    "export_response": .boolean(
                        description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    )
                ],
                required: ["message"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAskOracle(args)
        }
    }

    private func oracleSendTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleSend,
            freshnessPolicy: .providerManaged,
            description: """
            Consult a second AI for planning, review, or questions.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode.
            Use `oracle_utils` for passive helpers like models and sessions. Pass either `chat_id` to continue or `new_chat:true` to start fresh; the two arguments cannot be combined.

            A `chat_id` continuation stays on the model preset that chat last used, so `model` can be omitted. Passing a different `model` with `chat_id` deliberately switches that chat from then on.

            Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            Build context first with file reads, `manage_selection`, or `workspace_context`.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "message": .string(
                        description: "Your message to send",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current tab or current context. The chat keeps the model preset it last used, so `model` can be omitted."
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false). Keep false for continuity; use true for an independent review. Cannot be combined with chat_id."
                    ),
                    "model": .string(
                        description: "Model preset ID or name override. With `chat_id`, omitting it keeps the chat's current preset and passing a different one switches the chat to it."
                    ),
                    "export_response": .boolean(
                        description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    )
                ],
                required: ["message"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleSend(args)
        }
    }

    private func oracleChatLogTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleChatLog,
            freshnessPolicy: .none,
            description: """
            Read recent Oracle conversation messages to recover context during agent mode.

            Returns the tail of an Oracle chat as lightweight `{ role, text }` objects. Available only during agent mode runs.

            **Parameters**:
            - `chat_id` (optional): Target a specific Oracle chat (short ID or UUID). Omit to read the most recent one.
            - `limit` (optional): Number of messages to return (default: 8, range: 1–50)
            - `include_user` (optional): Include your own messages in output (default: false)
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "chat_id": .string(description: "Chat ID (short ID or UUID) to read"),
                    "limit": .integer(description: "Max number of messages to return (default: 8, min: 1, max: 50)"),
                    "include_user": .boolean(description: "Include user messages in output (default: false)")
                ],
                required: []
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleChatLog(args)
        }
    }
}
