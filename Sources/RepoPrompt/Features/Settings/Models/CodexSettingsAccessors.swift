import Foundation
import RepoPromptAgentCore

extension CodexReasoningSummaries {
    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexReasoningSummariesEnabled()
    }
}

extension CodexGoalSupport {
    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexGoalSupportEnabled()
    }
}

extension CodexComputerUseWorkflow {
    @MainActor
    static var isEnabled: Bool {
        GlobalSettingsStore.shared.codexComputerUseEnabled()
    }
}

extension CodexAgentModeBooleanPreference {
    @MainActor
    func isEnabled(defaults: UserDefaults) -> Bool {
        if defaults === UserDefaults.standard {
            return isEnabledInGlobalSettingsStore()
        }
        switch self {
        case .goalSupport:
            return CodexGoalSupport.isEnabled(defaults: defaults)
        case .computerUse:
            return CodexComputerUseWorkflow.isEnabled(defaults: defaults)
        case .reasoningSummaries:
            return CodexReasoningSummaries.isEnabled(defaults: defaults)
        }
    }

    @MainActor
    func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        if defaults === UserDefaults.standard {
            setEnabledInGlobalSettingsStore(enabled)
            return
        }
        switch self {
        case .goalSupport:
            CodexGoalSupport.setEnabled(enabled, defaults: defaults)
        case .computerUse:
            CodexComputerUseWorkflow.setEnabled(enabled, defaults: defaults)
        case .reasoningSummaries:
            CodexReasoningSummaries.setEnabled(enabled, defaults: defaults)
        }
    }

    @MainActor
    private func isEnabledInGlobalSettingsStore() -> Bool {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.codexGoalSupportEnabled()
        case .computerUse:
            GlobalSettingsStore.shared.codexComputerUseEnabled()
        case .reasoningSummaries:
            GlobalSettingsStore.shared.codexReasoningSummariesEnabled()
        }
    }

    @MainActor
    private func setEnabledInGlobalSettingsStore(_ enabled: Bool) {
        switch self {
        case .goalSupport:
            GlobalSettingsStore.shared.setCodexGoalSupportEnabled(enabled)
        case .computerUse:
            GlobalSettingsStore.shared.setCodexComputerUseEnabled(enabled)
        case .reasoningSummaries:
            GlobalSettingsStore.shared.setCodexReasoningSummariesEnabled(enabled)
        }
    }
}
