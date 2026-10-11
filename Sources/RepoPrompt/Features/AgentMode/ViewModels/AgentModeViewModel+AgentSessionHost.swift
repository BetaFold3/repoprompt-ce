// App-owned: AgentModeViewModel's conformance to the agent coordinator host protocols.

import Foundation

extension AgentModeViewModel: CodexAgentModeCoordinatorHost, ClaudeAgentModeCoordinatorHost {
    func bindPendingOracleReviewContext(tabID: UUID, runID: UUID) {
        mcpBindPendingAgentRunOracleReviewContext(tabID: tabID, runID: runID)
    }
}
