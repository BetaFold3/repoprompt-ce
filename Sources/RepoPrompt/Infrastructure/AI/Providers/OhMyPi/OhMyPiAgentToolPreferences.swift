import Foundation

/// OMP permissions are fixed by the managed barebones launch contract.
///
/// This single level exists to give OMP an independent provider binding and persistence
/// namespace without exposing a control that could weaken the fixed launch profile.
enum OhMyPiAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable, Hashable {
        case managedBarebones

        var displayName: String {
            "Managed Barebones"
        }

        var iconName: String {
            "lock.shield"
        }

        var detailText: String? {
            "OMP native tools and ambient extensions, skills, and rules are disabled. Only recognized RepoPrompt MCP permission requests may be auto-approved at the ACP layer."
        }

        var isWarning: Bool {
            false
        }
    }
}
