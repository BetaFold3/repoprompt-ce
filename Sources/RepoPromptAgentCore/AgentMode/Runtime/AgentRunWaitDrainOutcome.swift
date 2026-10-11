import Foundation

/// Sanitized snapshot of what still blocked a steering drain at its deadline: counts and
/// ages only, never tool arguments, prompts, or session content.
package struct AgentRunWaitDrainBlockers: Equatable {
    /// Child `agent_run` wait scopes (`op:"wait"` invocations) owned by the run.
    let childAgentRunWaitCount: Int
    let oldestChildAgentRunWaitAgeSeconds: Int?
    /// Bounded `ask_oracle` invocations (send, batch, or `op:"wait"`) owned by the run.
    /// Steering caps their own waits at a sub-second grace, so one still open at the drain
    /// deadline is suspended outside any wakeable wait.
    let oracleInvocationCount: Int
    let oldestOracleInvocationAgeSeconds: Int?

    package init(
        childAgentRunWaitCount: Int,
        oldestChildAgentRunWaitAgeSeconds: Int?,
        oracleInvocationCount: Int,
        oldestOracleInvocationAgeSeconds: Int?
    ) {
        self.childAgentRunWaitCount = childAgentRunWaitCount
        self.oldestChildAgentRunWaitAgeSeconds = oldestChildAgentRunWaitAgeSeconds
        self.oracleInvocationCount = oracleInvocationCount
        self.oldestOracleInvocationAgeSeconds = oldestOracleInvocationAgeSeconds
    }
}

package enum AgentRunWaitDrainOutcome: Equatable {
    case drained
    case cancelled
    case timedOut(AgentRunWaitDrainBlockers)

    var isDrained: Bool {
        self == .drained
    }
}
