import Foundation

package enum AgentProviderBindingID: String, CaseIterable, Hashable {
    case codex
    case claude
    case openCode
    case cursor
    case ohMyPi

    /// User-facing generic setting rows exclude the fixed managed OMP profile, which has no mutable binding.
    package static var publicSettingsCases: [Self] {
        allCases.filter { $0 != .ohMyPi }
    }

    package var displayName: String {
        switch self {
        case .codex:
            "Codex CLI"
        case .claude:
            "Claude Code"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .ohMyPi:
            "Oh My Pi"
        }
    }
}

package extension AgentProviderKind {
    var providerBindingID: AgentProviderBindingID {
        switch self {
        case .codexExec:
            .codex
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            .claude
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .ohMyPi:
            .ohMyPi
        }
    }
}
