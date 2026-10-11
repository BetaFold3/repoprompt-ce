import Foundation

package enum AgentSessionWorktreeBindingState: Equatable {
    case notApplicable
    case hydrated([AgentSessionWorktreeBinding])
    case unhydrated
    case unavailable

    package var bindings: [AgentSessionWorktreeBinding]? {
        guard case let .hydrated(bindings) = self else { return nil }
        return bindings
    }
}

package struct AgentWorkspaceLookupContextSource: Equatable {
    package let activeAgentSessionID: UUID?
    package let worktreeBindingState: AgentSessionWorktreeBindingState

    package init(
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingState = worktreeBindingState
    }

    package init(
        activeAgentSessionID: UUID?,
        worktreeBindings: [AgentSessionWorktreeBinding]
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings)
        )
    }

    package var worktreeBindings: [AgentSessionWorktreeBinding] {
        worktreeBindingState.bindings ?? []
    }

    package var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindingState)
        )
    }

    package static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
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

package struct AgentWorkspaceLookupContextIdentity: Hashable {
    let activeAgentSessionID: UUID?
    package let worktreeBindingFingerprint: String
}
