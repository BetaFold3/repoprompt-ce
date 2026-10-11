import Foundation

extension CodexIntegrationConfiguration.ServerEntry: Equatable {
    package static func == (
        lhs: CodexIntegrationConfiguration.ServerEntry,
        rhs: CodexIntegrationConfiguration.ServerEntry
    ) -> Bool {
        lhs.rawName == rhs.rawName
            && lhs.normalizedName == rhs.normalizedName
            && lhs.cliPathComponent == rhs.cliPathComponent
    }
}

extension CodexIntegrationConfiguration.ServerEntry: @unchecked Sendable {}

package enum AgentProviderPermissionLevelID: Hashable {
    case codex(CodexAgentToolPreferences.PermissionLevel)
    case claude(ClaudeAgentToolPreferences.PermissionLevel)
    case openCode(OpenCodeAgentToolPreferences.PermissionLevel)
    case cursor(CursorAgentToolPreferences.PermissionLevel)
    case ohMyPi(OhMyPiAgentToolPreferences.PermissionLevel)

    package var providerID: AgentProviderBindingID {
        switch self {
        case .codex:
            .codex
        case .claude:
            .claude
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .ohMyPi:
            .ohMyPi
        }
    }

    package static func subagentDefault(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        switch providerID {
        case .codex:
            .codex(.defaultPermission)
        case .claude:
            .claude(.requireApproval)
        case .openCode:
            .openCode(.managedDefault)
        case .cursor:
            .cursor(.managedDefault)
        case .ohMyPi:
            .ohMyPi(.managedBarebones)
        }
    }

    package static func options(for providerID: AgentProviderBindingID) -> [AgentProviderPermissionLevelID] {
        switch providerID {
        case .codex:
            CodexAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.codex)
        case .claude:
            ClaudeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.claude)
        case .openCode:
            OpenCodeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.openCode)
        case .cursor:
            CursorAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.cursor)
        case .ohMyPi:
            OhMyPiAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.ohMyPi)
        }
    }

    init?(providerID: AgentProviderBindingID, subagentRawValue: String) {
        let raw = subagentRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch providerID {
        case .codex:
            guard let level = CodexAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .codex(level)
        case .claude:
            guard let level = ClaudeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .claude(level)
        case .openCode:
            guard let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .openCode(level)
        case .cursor:
            guard let level = CursorAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .cursor(level)
        case .ohMyPi:
            guard let level = OhMyPiAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
            self = .ohMyPi(level)
        }
    }

    var subagentRawValue: String {
        switch self {
        case let .codex(level):
            level.rawValue
        case let .claude(level):
            level.rawValue
        case let .openCode(level):
            level.rawValue
        case let .cursor(level):
            level.rawValue
        case let .ohMyPi(level):
            level.rawValue
        }
    }

    package var displayName: String {
        switch self {
        case let .codex(level):
            level.displayName
        case let .claude(level):
            level.displayName
        case let .openCode(level):
            level.displayName
        case let .cursor(level):
            level.displayName
        case let .ohMyPi(level):
            level.displayName
        }
    }

    package var iconName: String {
        switch self {
        case let .codex(level):
            level.iconName
        case let .claude(level):
            level.iconName
        case let .openCode(level):
            level.iconName
        case let .cursor(level):
            level.iconName
        case let .ohMyPi(level):
            level.iconName
        }
    }

    package var detailText: String? {
        switch self {
        case .codex:
            nil
        case let .claude(level):
            level.detailText
        case let .openCode(level):
            level.detailText
        case let .cursor(level):
            level.detailText
        case let .ohMyPi(level):
            level.detailText
        }
    }

    package var isWarning: Bool {
        switch self {
        case let .codex(level):
            level.isWarning
        case let .claude(level):
            level.isWarning
        case let .openCode(level):
            level.isWarning
        case let .cursor(level):
            level.isWarning
        case let .ohMyPi(level):
            level.isWarning
        }
    }
}

package struct AgentPermissionOptionBinding: Identifiable, Equatable {
    package let id: AgentProviderPermissionLevelID
    package let title: String
    package let iconName: String
    package let detailText: String?
    let isWarning: Bool
    package let isSelected: Bool
    package let isEnabled: Bool
}

package struct AgentPermissionModePresentationBinding: Equatable {
    let rawValue: String
    package let displayName: String
}

enum AgentPermissionSessionPhaseBinding: Equatable {
    case selectedNotStarted
    case blocked
    case initializing
    case acknowledged
    case failed
    case pendingNextTurn
}

/// Presentation-only projection of provider runtime evidence. These values describe
/// requests and acknowledgements; they are not an independently evaluated permission policy.
package struct AgentPermissionSessionStatusBinding: Equatable {
    let phase: AgentPermissionSessionPhaseBinding
    package let title: String
    package let detail: String
    package let iconName: String
    package let isWarning: Bool
    package let requestedMode: AgentPermissionModePresentationBinding
    package let resolvedLaunchMode: AgentPermissionModePresentationBinding?
    package let acknowledgedMode: AgentPermissionModePresentationBinding?
}

package struct AgentPermissionChromeBinding: Equatable {
    package let providerID: AgentProviderBindingID
    package let displayName: String
    package let iconName: String
    package let isWarning: Bool
    package let externallyManagedReason: String?
    package let options: [AgentPermissionOptionBinding]
    package let configuredMode: AgentPermissionModePresentationBinding?
    package let sessionStatus: AgentPermissionSessionStatusBinding?

    init(
        providerID: AgentProviderBindingID,
        displayName: String,
        iconName: String,
        isWarning: Bool,
        externallyManagedReason: String?,
        options: [AgentPermissionOptionBinding],
        configuredMode: AgentPermissionModePresentationBinding? = nil,
        sessionStatus: AgentPermissionSessionStatusBinding? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.iconName = iconName
        self.isWarning = isWarning
        self.externallyManagedReason = externallyManagedReason
        self.options = options
        self.configuredMode = configuredMode
        self.sessionStatus = sessionStatus
    }
}

package struct AgentProviderRuntimePermissionBinding: Equatable {
    let codexSandboxMode: CodexAgentToolPreferences.SandboxMode?
    let codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy?
    let codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer?
    let claudePermissionMode: String?
    let acpSessionModeID: String?
    let autoApproveAllACPToolPermissions: Bool
    let acceptsPendingACPApprovalWhenActivated: Bool

    init(
        codexSandboxMode: CodexAgentToolPreferences.SandboxMode? = nil,
        codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy? = nil,
        codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer? = nil,
        claudePermissionMode: String? = nil,
        acpSessionModeID: String? = nil,
        autoApproveAllACPToolPermissions: Bool = false,
        acceptsPendingACPApprovalWhenActivated: Bool = false
    ) {
        self.codexSandboxMode = codexSandboxMode
        self.codexApprovalPolicy = codexApprovalPolicy
        self.codexApprovalReviewer = codexApprovalReviewer
        self.claudePermissionMode = claudePermissionMode
        self.acpSessionModeID = acpSessionModeID
        self.autoApproveAllACPToolPermissions = autoApproveAllACPToolPermissions
        self.acceptsPendingACPApprovalWhenActivated = acceptsPendingACPApprovalWhenActivated
    }
}

package enum CodexToolSettingMutation: Equatable {
    case bashTool(enabled: Bool)
    case searchTool(enabled: Bool)
    case computerUse(enabled: Bool)
    case goalSupport(enabled: Bool)
    case reasoningSummaries(enabled: Bool)
    case mcpServer(normalizedName: String, enabled: Bool)
}

package enum ClaudeToolSettingMutation: Equatable {
    case bashTool(enabled: Bool)
    case mcpStrictMode(enabled: Bool)
    case toolSearch(enabled: Bool)
    case agentModePromptDelivery(delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery)
}

/// Persisted Codex tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`.
/// User-configured values mirror stored preferences; MCP-safe snapshots apply the Safe
/// Managed overrides defined by `codexToolSettingsBinding(profile:)`.
package struct CodexToolSettingsBinding: Equatable {
    package let bashToolEnabled: Bool
    package let searchToolEnabled: Bool
    let computerUseEnabled: Bool
    package let goalSupportEnabled: Bool
    /// Controls Codex Agent Mode app-server reasoning summary config only; this is not a
    /// general model reasoning-effort preference.
    package let reasoningSummariesEnabled: Bool
    package let mcpServerEntries: [MCPIntegrationHelper.CodexServerEntry]
    /// Keys are lowercased/trimmed toggle keys derived from each entry's normalized name,
    /// matching the current AgentInputBar lookup convention.
    package let mcpServerStatesByNormalizedName: [String: Bool]
}

/// Persisted Claude tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`; these
/// values intentionally mirror existing UserDefaults-backed tool preferences even when a
/// caller is rendering an externally managed or MCP-safe permission profile. `effortLevel`
/// is resolved for the selected model when a model context is available.
package struct ClaudeToolSettingsBinding: Equatable {
    package let bashToolEnabled: Bool
    package let mcpStrictModeEnabled: Bool
    package let toolSearchEnabled: Bool
    package let effortLevel: ClaudeCodeEffortLevel
    package let agentModePromptDelivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
}

/// Complete provider controls snapshot for the selected agent/provider.
///
/// `runtimePermission` is the profile-aware launch/runtime contract. Provider-specific
/// tool snapshots are Settings/editing snapshots for direct provider controls; callers
/// that are only previewing sub-agent policy should prefer capability summaries unless
/// they explicitly need a runtime binding.
package struct AgentProviderControlsBinding: Equatable {
    let revision: Int
    let selectedAgent: AgentProviderKind
    let providerID: AgentProviderBindingID
    package let permission: AgentPermissionChromeBinding
    let runtimePermission: AgentProviderRuntimePermissionBinding
    package let codexTools: CodexToolSettingsBinding?
    package let claudeTools: ClaudeToolSettingsBinding?
}
