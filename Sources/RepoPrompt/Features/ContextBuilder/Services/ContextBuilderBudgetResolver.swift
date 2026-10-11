import Foundation
import RepoPromptAgentCore

/// Centralizes context builder budget selection so UI and MCP paths resolve
/// clarify/omitted runs and follow-up-generation runs consistently.
enum ContextBuilderBudgetResolver {
    static func resolveBudget(
        wantsResponse: Bool,
        discoveryTokenBudget: Int?,
        planTokenBudget: Int?
    ) -> Int {
        if wantsResponse {
            return planTokenBudget ?? ContextBuilderDefaults.planTokenBudget
        }
        return discoveryTokenBudget ?? ContextBuilderDefaults.discoveryTokenBudget
    }
}
