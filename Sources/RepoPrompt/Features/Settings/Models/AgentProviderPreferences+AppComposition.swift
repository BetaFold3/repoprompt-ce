import Foundation
import RepoPromptAgentCore

extension AgentProviderPreferenceSnapshotStore {
    convenience init(
        defaults: UserDefaults = .standard,
        securePermissions: AgentPermissionSecureStore? = nil,
        codexMCPServerEntries: @escaping CodexMCPServerEntriesProvider = { MCPIntegrationHelper.codexMCPServerEntries() }
    ) {
        self.init(
            defaults: defaults,
            securePermissions: securePermissions,
            codexMCPServerEntries: codexMCPServerEntries,
            codexBooleanPreferenceIsEnabled: { @MainActor preference in
                preference.isEnabled(defaults: defaults)
            },
            codexBooleanPreferenceSetEnabled: { @MainActor preference, enabled in
                preference.setEnabled(enabled, defaults: defaults)
            }
        )
    }
}

extension AgentModeProviderBindingService {
    convenience init() {
        self.init(preferences: AgentProviderPreferenceSnapshotStore())
    }
}
