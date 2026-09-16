import Foundation
import MCP
import RepoPromptShared

// SEARCH-HELPER: MCP, agent_run, agent_explore, wait policy, parent family, timeout, wait_policy

/// Invocation-local wait policy for `agent_run` / `agent_explore` lifecycle calls (plan §6.3).
///
/// The effective-parent classification is frozen once at the outer lifecycle entry from the
/// authenticated run binding and then carried unchanged through child creation, run rebinding,
/// steering and Explore delegation. The policy values never retain a live session and never infer
/// the family from the worker model, the MCP client name, a role label or a transport protocol.
enum AgentMCPWaitPolicy {
    typealias ParentFamily = MCPTimeoutPolicy.AgentLifecycleParentFamily

    /// The already authenticated request metadata plus the frozen parent-family classification.
    struct RequestContext {
        let metadata: MCPServerViewModel.RequestMetadata
        let parentFamily: ParentFamily

        init(metadata: MCPServerViewModel.RequestMetadata, parentFamily: ParentFamily) {
            self.metadata = metadata
            self.parentFamily = parentFamily
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

        static func automatic(parentFamily: ParentFamily) -> Selection {
            Selection(
                mode: .automatic,
                timeoutSeconds: MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(for: parentFamily),
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

    static let waitPolicyKey = "wait_policy"

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
    }

    /// Requires an authenticated run identity and exactly one active session with that exact
    /// `runID`. Missing identity, no match, a stale (inactive) match, or an ambiguous match
    /// resolves to `.unresolved`.
    static func resolveParentFamily(runID: UUID?, candidates: [ParentCandidate]) -> ParentFamily {
        guard let runID else { return .unresolved }
        let matches = candidates.filter { $0.runID == runID && $0.isActive }
        guard matches.count == 1, let match = matches.first else { return .unresolved }
        return parentFamily(for: match.selectedAgent)
    }

    /// Single MainActor isolation segment: filters live tab sessions by exact `runID` and reads the
    /// unique active match's `selectedAgent` without suspending.
    @MainActor
    static func resolveParentFamily(
        runID: UUID?,
        sessions: some Sequence<AgentModeViewModel.TabSession>
    ) -> ParentFamily {
        resolveParentFamily(
            runID: runID,
            candidates: sessions.map {
                ParentCandidate(runID: $0.runID, isActive: $0.runState.isActive, selectedAgent: $0.selectedAgent)
            }
        )
    }

    /// Resolves the wait selection for a raw `timeout` / `timeout_seconds` argument.
    /// Omission is automatic (never rewritten to an explicit number); explicit `0` is a poll;
    /// explicit values from 1 through the shared maximum are accepted and larger values throw
    /// without clamping.
    static func selection(rawTimeout: Value?, parentFamily: ParentFamily) throws -> Selection {
        guard let seconds = try AgentMCPToolHelpers.parseTimeoutSeconds(rawTimeout) else {
            return .automatic(parentFamily: parentFamily)
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
