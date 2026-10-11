import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

enum ToolCardAccentResolver {
    static func family(for toolName: String?) -> ClusterToolCategory.ToolFamily {
        guard let normalized = normalizedToolCardName(toolName)?.lowercased() else {
            return .other
        }
        return ClusterToolCategory.classification(forNormalizedToolName: normalized).family
    }

    static func color(for toolName: String?) -> Color {
        switch family(for: toolName) {
        case .navigation:
            BubbleColors.toolNavigationAccent
        case .edit:
            BubbleColors.toolEditAccent
        case .execution:
            BubbleColors.toolExecutionAccent
        case .communication:
            BubbleColors.toolCommunicationAccent
        case .agentControl:
            BubbleColors.toolCommunicationAccent
        case .config:
            BubbleColors.toolConfigAccent
        case .other:
            BubbleColors.toolOtherAccent
        }
    }
}
