import Foundation
import RepoPromptAgentCore
import RepoPromptUI

extension CodexAgentModeCoordinator {
    func nativeSlashCommandSuggestions(
        for session: AgentTabSession,
        query: String,
        limit: Int
    ) -> [MentionSuggestion] {
        guard session.selectedAgent == .codexExec else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return NativeSlashCommand.allCases
            .filter { shouldShowNativeSlashCommand($0, session: session) }
            .filter { normalizedQuery.isEmpty || $0.rawValue.hasPrefix(normalizedQuery) }
            .prefix(limit)
            .map { command in
                MentionSuggestion(
                    displayName: "/\(command.rawValue)",
                    relativePath: command.rawValue,
                    kind: .skill,
                    subtitle: command.subtitle
                )
            }
    }
}
