import Foundation

/// RepoPrompt CE-owned timeout policy for MCP execution, delivery, and caller-driven defaults.
/// Caller-supplied timeout values remain dynamic; these constants only define CE defaults and guards.
public enum MCPTimeoutPolicy {
    public static let boundedToolExecutionDeadlineSeconds = 30
    public static let boundedToolExecutionDeadline: Duration = .seconds(boundedToolExecutionDeadlineSeconds)

    public static let workspaceFreshnessWaitTimeoutSeconds = 30
    public static let workspaceFreshnessWaitTimeout: Duration = .seconds(workspaceFreshnessWaitTimeoutSeconds)

    /// Mutation preflight must settle before the ordinary bounded tool watchdog so a blocked
    /// workspace barrier can return a retryable result instead of racing connection teardown.
    public static let mutationPreflightFreshnessWaitTimeoutSeconds = 20
    public static let mutationPreflightFreshnessWaitTimeout: Duration = .seconds(
        mutationPreflightFreshnessWaitTimeoutSeconds
    )

    public static let workspaceReadinessWaitTimeoutSeconds = 30
    public static let workspaceReadinessWaitTimeout: Duration = .seconds(workspaceReadinessWaitTimeoutSeconds)

    public static let workspaceSwitchToolExecutionDeadlineSeconds = 120
    public static let workspaceSwitchToolExecutionDeadline: Duration = .seconds(
        workspaceSwitchToolExecutionDeadlineSeconds
    )

    /// Allows the 120-second workspace-switch window, 5-second cleanup grace, and 25 seconds of transport margin.
    public static let postStdinHalfCloseBridgeDrainDeadlineSeconds = 150

    public static let boundedToolCancellationCleanupGraceSeconds = 5
    public static let boundedToolCancellationCleanupGrace: Duration = .seconds(boundedToolCancellationCleanupGraceSeconds)

    public static let bootstrapReplacementPredecessorStopGraceSeconds = 5
    public static let bootstrapReplacementPredecessorStopGrace: Duration = .seconds(
        bootstrapReplacementPredecessorStopGraceSeconds
    )

    public static let responseSendDeadlineSeconds = 30
    public static let responseSendDeadline: Duration = .seconds(responseSendDeadlineSeconds)
    public static let transportWriteStallTimeoutSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    public static let codexServerActiveTimeoutSeconds = 10000

    /// Default CLI-side deadline for ordinary tool responses.
    public static let cliDefaultToolCallTimeoutSeconds: TimeInterval = 300
    /// Long-running tools whose provider/run cancellation contract is authoritative.
    public static let cliDefaultUnboundedToolNames: Set<String> = [
        "ask_oracle",
        "context_builder"
    ]
    /// Extra time after a caller-requested server-side wait for response encoding
    /// and transport delivery before the CLI cancels the request.
    public static let cliSemanticWaitResponseMarginSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    /// Provider family of the **parent** model invocation that called an agent lifecycle tool
    /// (`agent_run` / `agent_explore` start, wait, multi-wait, steer-with-wait). The app freezes the
    /// family once at the outer lifecycle entry from the authenticated run binding; it is never
    /// inferred from the worker model, the MCP client name, a role label, or a transport protocol.
    public enum AgentLifecycleParentFamily: String, CaseIterable, Sendable, Codable {
        case claude
        case codex
        case other
        case unresolved
    }

    /// Automatic (omitted-timeout) lifecycle wait when the effective parent is Claude Code.
    public static let agentLifecycleClaudeAutomaticWaitSeconds: TimeInterval = 180
    /// Automatic lifecycle wait when the effective parent is Codex. This is a CE operational
    /// heuristic, not a Codex CLI/app-server prompt-cache TTL contract.
    public static let agentLifecycleCodexAutomaticWaitSeconds: TimeInterval = 600
    /// Automatic lifecycle wait for every other named provider.
    public static let agentLifecycleOtherAutomaticWaitSeconds: TimeInterval = 180
    /// Automatic lifecycle wait when no authoritative live parent can be resolved
    /// (missing, ambiguous, stale, fallback, external or remote binding).
    public static let agentLifecycleUnresolvedAutomaticWaitSeconds: TimeInterval = 180
    /// Largest value the automatic family table can select.
    public static let agentLifecycleMaximumAutomaticWaitSeconds: TimeInterval = 600
    /// Owned-host response envelope for operations that actually perform an automatic wait:
    /// the maximum automatic wait plus the response encoding/delivery margin (600 + 30).
    public static let agentLifecycleAutomaticWaitResponseEnvelopeSeconds: TimeInterval =
        agentLifecycleMaximumAutomaticWaitSeconds + cliSemanticWaitResponseMarginSeconds
    /// Inclusive upper bound for an explicit lifecycle timeout: exactly four hours. Larger values
    /// are rejected, never clamped.
    public static let agentLifecycleMaximumExplicitTimeoutSeconds: TimeInterval = 14400

    /// Resolves the automatic lifecycle wait for a frozen parent family.
    public static func agentLifecycleAutomaticWaitSeconds(for family: AgentLifecycleParentFamily) -> TimeInterval {
        switch family {
        case .claude:
            agentLifecycleClaudeAutomaticWaitSeconds
        case .codex:
            agentLifecycleCodexAutomaticWaitSeconds
        case .other:
            agentLifecycleOtherAutomaticWaitSeconds
        case .unresolved:
            agentLifecycleUnresolvedAutomaticWaitSeconds
        }
    }

    /// Compatibility alias for the unresolved-parent automatic wait. Provider-aware production
    /// code must resolve the parent family and call `agentLifecycleAutomaticWaitSeconds(for:)`
    /// instead of treating this value as a universal default.
    public static let agentLifecycleDefaultWaitSeconds: TimeInterval = agentLifecycleUnresolvedAutomaticWaitSeconds
    public static let askUserDefaultTimeoutSeconds: TimeInterval = 300
    public static let nextUserInstructionDefaultWaitSeconds: TimeInterval = 600
    public static let applyEditsApprovalTimeoutSeconds: TimeInterval = 300
    public static let worktreeMergeApprovalTimeoutSeconds: TimeInterval = 600
}
