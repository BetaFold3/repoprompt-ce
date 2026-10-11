import Foundation

package enum CursorAgentToolPreferences {
    package enum PermissionLevel: String, CaseIterable {
        case managedDefault
        case fullAccess

        var displayName: String {
            switch self {
            case .managedDefault:
                "Default"
            case .fullAccess:
                "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .managedDefault:
                "Cursor asks before running tools that need approval. RepoPrompt MCP is injected through the ACP session."
            case .fullAccess:
                "RepoPrompt automatically approves Cursor ACP tool permission requests."
            }
        }

        var iconName: String {
            switch self {
            case .managedDefault:
                "shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        package var autoApprovesACPToolPermissions: Bool {
            self == .fullAccess
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .managedDefault
            }
            switch raw.lowercased() {
            case PermissionLevel.fullAccess.rawValue.lowercased():
                return .fullAccess
            case PermissionLevel.managedDefault.rawValue.lowercased():
                return .managedDefault
            default:
                return .managedDefault
            }
        }
    }

    private static let permissionLevelKey = "cursorACPToolPermissionLevel"

    package static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.cursorPermissions().permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    package static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setCursorPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
