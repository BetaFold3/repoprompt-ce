import CoreFoundation
import Foundation
import MCP
import RepoPromptShared

// SEARCH-HELPER: MCP, agent_run, agent_explore, ask_oracle, wait policy, parent family, timeout, wait_policy

/// Invocation-local wait policy for `agent_run` / `agent_explore` lifecycle calls (plan §6.3)
/// and, unchanged, for bounded `ask_oracle` sends and `op:"wait"` (Oracle resumable wait plan
/// §3.1/§3.6): the same family table, the same `selection(rawTimeout:parentFamily:promptCacheRetention:)` rules and
/// the same canonical root `wait_policy` tuple attached once per response via `attaching(_:to:)`.
///
/// The effective-parent classification is frozen once at the outer lifecycle entry from the
/// authenticated run binding and then carried unchanged through child creation, run rebinding,
/// steering and Explore delegation. For `ask_oracle` it is frozen per invocation: a later
/// `op:"wait"` on the same operation is a new observation and may legitimately carry a
/// different family after a run rotation. The policy values never retain a live session and
/// never infer the family from the worker model, the MCP client name, a role label or a
/// transport protocol.
enum AgentMCPWaitPolicy {
    typealias ParentFamily = MCPTimeoutPolicy.AgentLifecycleParentFamily
    typealias ParentPromptCacheRetention = MCPTimeoutPolicy.AgentLifecycleParentPromptCacheRetention

    /// The already authenticated request metadata plus the frozen parent-family classification
    /// and prompt-cache retention visible at the matched parent process launch.
    struct RequestContext {
        let metadata: MCPServerViewModel.RequestMetadata
        let parentFamily: ParentFamily
        let parentPromptCacheRetention: ParentPromptCacheRetention

        init(
            metadata: MCPServerViewModel.RequestMetadata,
            parentFamily: ParentFamily,
            parentPromptCacheRetention: ParentPromptCacheRetention
        ) {
            self.metadata = metadata
            self.parentFamily = parentFamily
            self.parentPromptCacheRetention = parentPromptCacheRetention
        }

        static func unresolved(metadata: MCPServerViewModel.RequestMetadata) -> RequestContext {
            RequestContext(
                metadata: metadata,
                parentFamily: .unresolved,
                parentPromptCacheRetention: .standard
            )
        }
    }

    enum Mode: String {
        case automatic
        case explicit
        case poll
    }

    /// The wait selection for one lifecycle call. `parentFamily` is carried only for automatic mode.
    struct Selection: Equatable {
        let mode: Mode
        let timeoutSeconds: TimeInterval
        let parentFamily: ParentFamily?

        static func automatic(
            parentFamily: ParentFamily,
            promptCacheRetention: ParentPromptCacheRetention
        ) -> Selection {
            Selection(
                mode: .automatic,
                timeoutSeconds: MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(
                    for: parentFamily,
                    promptCacheRetention: promptCacheRetention
                ),
                parentFamily: parentFamily
            )
        }

        static func explicit(timeoutSeconds: TimeInterval) -> Selection {
            Selection(mode: .explicit, timeoutSeconds: timeoutSeconds, parentFamily: nil)
        }

        static let poll = Selection(mode: .poll, timeoutSeconds: 0, parentFamily: nil)

        /// Minimal canonical root tuple (plan §6.3): `mode`, `timeout_seconds`, and
        /// `parent_family` only for automatic mode. No TTLs, cache ages, park durations,
        /// warning codes, account details or policy version.
        var canonicalValue: Value {
            var object: [String: Value] = [
                "mode": .string(mode.rawValue),
                "timeout_seconds": Self.timeoutValue(timeoutSeconds)
            ]
            if mode == .automatic, let parentFamily {
                object["parent_family"] = .string(parentFamily.rawValue)
            }
            return .object(object)
        }

        private static func timeoutValue(_ seconds: TimeInterval) -> Value {
            if seconds.rounded(.down) == seconds, seconds <= TimeInterval(Int.max) {
                return .int(Int(seconds))
            }
            return .double(seconds)
        }
    }

    /// Validated canonical metadata decoded from a lifecycle result. This accepts only the
    /// Phase 7 root tuple and deliberately drops any additional nested payload.
    struct CanonicalMetadata: Equatable {
        let mode: Mode
        let timeoutSeconds: TimeInterval
        let parentFamily: ParentFamily?

        var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "mode": mode.rawValue,
                "timeout_seconds": Self.timeoutJSONValue(timeoutSeconds)
            ]
            if mode == .automatic, let parentFamily {
                object["parent_family"] = parentFamily.rawValue
            }
            return object
        }

        private static func timeoutJSONValue(_ seconds: TimeInterval) -> Any {
            if seconds.rounded(.down) == seconds, seconds <= TimeInterval(Int.max) {
                return Int(seconds)
            }
            return seconds
        }
    }

    static let waitPolicyKey = "wait_policy"

    /// Validates the canonical root tuple before UI or persistence consumes it. Stored timeout
    /// values remain authoritative; validation checks only the canonical mode-specific shape.
    static func canonicalMetadata(from rootObject: [String: Any]) -> CanonicalMetadata? {
        guard let object = rootObject[waitPolicyKey] as? [String: Any],
              let rawMode = object["mode"] as? String,
              let mode = Mode(rawValue: rawMode),
              let timeoutSeconds = numericTimeout(object["timeout_seconds"]),
              timeoutSeconds >= 0,
              timeoutSeconds <= MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds
        else { return nil }

        switch mode {
        case .automatic:
            guard timeoutSeconds > 0,
                  let rawFamily = object["parent_family"] as? String,
                  let parentFamily = ParentFamily(rawValue: rawFamily)
            else { return nil }
            return CanonicalMetadata(mode: mode, timeoutSeconds: timeoutSeconds, parentFamily: parentFamily)
        case .explicit:
            guard timeoutSeconds > 0, object["parent_family"] == nil else { return nil }
            return CanonicalMetadata(mode: mode, timeoutSeconds: timeoutSeconds, parentFamily: nil)
        case .poll:
            guard timeoutSeconds == 0, object["parent_family"] == nil else { return nil }
            return CanonicalMetadata(mode: mode, timeoutSeconds: timeoutSeconds, parentFamily: nil)
        }
    }

    private static func numericTimeout(_ value: Any?) -> TimeInterval? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds = number.doubleValue
            return seconds.isFinite ? seconds : nil
        }
        if let seconds = value as? Double, seconds.isFinite {
            return seconds
        }
        if let seconds = value as? Int {
            return TimeInterval(seconds)
        }
        return nil
    }

    /// Exhaustive current-enum mapping. Only `.claudeCode` belongs to the Claude row and only
    /// `.codexExec` to the Codex row; Claude-compatible vendors do not inherit the Claude default
    /// merely from protocol compatibility. Adding a provider case forces a visible decision here.
    static func parentFamily(for provider: AgentProviderKind) -> ParentFamily {
        switch provider {
        case .claudeCode:
            .claude
        case .codexExec:
            .codex
        case .openCode, .cursor, .ohMyPi, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            .other
        }
    }

    /// Value copy of one live tab session taken inside the MainActor read segment, so the policy
    /// never holds a live session reference.
    struct ParentCandidate: Equatable {
        let runID: UUID?
        let isActive: Bool
        let selectedAgent: AgentProviderKind
        let promptCacheRetention: ParentPromptCacheRetention

        init(
            runID: UUID?,
            isActive: Bool,
            selectedAgent: AgentProviderKind,
            promptCacheRetention: ParentPromptCacheRetention = .standard
        ) {
            self.runID = runID
            self.isActive = isActive
            self.selectedAgent = selectedAgent
            self.promptCacheRetention = promptCacheRetention
        }
    }

    struct ResolvedParent: Equatable {
        let family: ParentFamily
        let promptCacheRetention: ParentPromptCacheRetention

        static let unresolved = ResolvedParent(family: .unresolved, promptCacheRetention: .standard)
    }

    /// Requires an authenticated run identity and exactly one active session with that exact
    /// `runID`. Missing identity, no match, a stale (inactive) match, or an ambiguous match
    /// resolves to the unresolved family with standard retention.
    static func resolveParent(runID: UUID?, candidates: [ParentCandidate]) -> ResolvedParent {
        guard let runID else { return .unresolved }
        let matches = candidates.filter { $0.runID == runID && $0.isActive }
        guard matches.count == 1, let match = matches.first else { return .unresolved }
        let family = parentFamily(for: match.selectedAgent)
        return ResolvedParent(
            family: family,
            promptCacheRetention: family == .claude ? match.promptCacheRetention : .standard
        )
    }

    static func resolveParentFamily(runID: UUID?, candidates: [ParentCandidate]) -> ParentFamily {
        resolveParent(runID: runID, candidates: candidates).family
    }

    /// Single MainActor isolation segment: filters live tab sessions by exact `runID` and reads the
    /// unique active match's provider and prompt-cache retention without suspending.
    @MainActor
    static func resolveParent(
        runID: UUID?,
        sessions: some Sequence<AgentModeViewModel.TabSession>
    ) -> ResolvedParent {
        resolveParent(
            runID: runID,
            candidates: sessions.map {
                ParentCandidate(
                    runID: $0.runID,
                    isActive: $0.runState.isActive,
                    selectedAgent: $0.selectedAgent,
                    promptCacheRetention: $0.claudePromptCacheRetention
                )
            }
        )
    }

    @MainActor
    static func resolveParentFamily(
        runID: UUID?,
        sessions: some Sequence<AgentModeViewModel.TabSession>
    ) -> ParentFamily {
        resolveParent(runID: runID, sessions: sessions).family
    }

    /// Resolves the wait selection for a raw `timeout` / `timeout_seconds` argument.
    /// Omission is automatic (never rewritten to an explicit number); explicit `0` is a poll;
    /// explicit values from 1 through the shared maximum are accepted and larger values throw
    /// without clamping. `ask_oracle` validates the raw value before any model selection or
    /// packaging and reuses this resolution unchanged.
    static func selection(
        rawTimeout: Value?,
        parentFamily: ParentFamily,
        promptCacheRetention: ParentPromptCacheRetention
    ) throws -> Selection {
        guard let seconds = try AgentMCPToolHelpers.parseTimeoutSeconds(rawTimeout) else {
            return .automatic(
                parentFamily: parentFamily,
                promptCacheRetention: promptCacheRetention
            )
        }
        return seconds > 0 ? .explicit(timeoutSeconds: seconds) : .poll
    }

    /// Adds the canonical root `wait_policy` tuple. Emitted once per response, including
    /// multi-worker results, before idempotency storage and response presentation.
    static func attaching(_ selection: Selection, to value: Value) -> Value {
        guard var object = value.objectValue else { return value }
        object[waitPolicyKey] = selection.canonicalValue
        return .object(object)
    }
}
