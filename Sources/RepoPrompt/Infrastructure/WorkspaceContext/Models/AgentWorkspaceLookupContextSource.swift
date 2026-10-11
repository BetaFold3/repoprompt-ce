import Foundation

enum AgentSessionWorktreeBindingState: Equatable {
    case notApplicable
    case hydrated([AgentSessionWorktreeBinding])
    case unhydrated
    case unavailable

    var bindings: [AgentSessionWorktreeBinding]? {
        guard case let .hydrated(bindings) = self else { return nil }
        return bindings
    }
}

struct AgentWorkspaceLookupContextSource: Equatable {
    let activeAgentSessionID: UUID?
    let worktreeBindingState: AgentSessionWorktreeBindingState

    init(
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingState = worktreeBindingState
    }

    init(
        activeAgentSessionID: UUID?,
        worktreeBindings: [AgentSessionWorktreeBinding]
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings)
        )
    }

    var worktreeBindings: [AgentSessionWorktreeBinding] {
        worktreeBindingState.bindings ?? []
    }

    var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindingState)
        )
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        worktreeBindingFingerprint(.hydrated(bindings))
    }

    static func worktreeBindingFingerprint(_ state: AgentSessionWorktreeBindingState) -> String {
        switch state {
        case .notApplicable:
            "not-applicable"
        case .unhydrated:
            "unhydrated"
        case .unavailable:
            "unavailable"
        case let .hydrated(bindings):
            bindings
                .map { binding in
                    [
                        binding.repositoryID,
                        binding.repoKey,
                        StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath),
                        binding.worktreeID,
                        StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath),
                        binding.branch ?? "",
                        binding.head ?? ""
                    ].joined(separator: "\u{1F}")
                }
                .sorted()
                .joined(separator: "\u{1E}")
        }
    }
}

struct AgentWorkspaceLookupContextIdentity: Hashable {
    let activeAgentSessionID: UUID?
    let worktreeBindingFingerprint: String
}
