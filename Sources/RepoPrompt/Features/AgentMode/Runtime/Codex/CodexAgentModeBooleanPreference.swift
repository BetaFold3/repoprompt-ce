import Foundation

/// Codex Agent Mode boolean preferences. Their settings-backed read and write routing lives in
/// `Features/Settings/Models/CodexSettingsAccessors.swift`.
enum CodexAgentModeBooleanPreference {
    case goalSupport
    case computerUse
    case reasoningSummaries
}
