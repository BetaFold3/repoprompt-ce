import Foundation

package struct AgentModelOption: Identifiable, Hashable {
    package let rawValue: String
    package let displayName: String
    package let description: String?
    package let isPlaceholderDefault: Bool
    package let isProviderDefault: Bool
    package let supportedReasoningEfforts: [CodexReasoningEffort]
    package let defaultReasoningEffort: CodexReasoningEffort?

    package init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil
    ) {
        let isPlaceholder =
            rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        isPlaceholderDefault = isPlaceholder && isDefault
        isProviderDefault = !isPlaceholder && isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    var isDefault: Bool {
        isPlaceholderDefault || isProviderDefault
    }

    package var id: String {
        rawValue
    }
}
