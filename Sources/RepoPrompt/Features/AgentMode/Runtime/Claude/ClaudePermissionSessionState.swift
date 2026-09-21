import Foundation

struct ClaudePermissionControllerOwnership: Equatable {
    let controllerIdentifier: ObjectIdentifier
    let runID: UUID
    let runAttemptID: UUID?
}

struct ClaudePermissionAcknowledgement: Equatable {
    let ownership: ClaudePermissionControllerOwnership
    let launchSettings: ClaudeAgentModeCoordinator.ControllerLaunchSettings
    let requestedMode: String
    let acknowledgedEffort: ClaudeCodeEffortLevel?
}

/// Transient evidence for the current Claude controller attempt. This records
/// request/acknowledgement history only; it is not a continuously observed
/// effective permission mode and is never persisted.
enum ClaudePermissionSessionState: Equatable {
    case notStarted
    case blocked(
        requestedMode: String,
        reason: ClaudeAgentToolPreferences.AutoPermissionCandidacy,
        runID: UUID?,
        runAttemptID: UUID?
    )
    case initializing(
        ownership: ClaudePermissionControllerOwnership,
        launchSettings: ClaudeAgentModeCoordinator.ControllerLaunchSettings,
        requestedMode: String
    )
    case acknowledged(ClaudePermissionAcknowledgement)
    case failed(
        ownership: ClaudePermissionControllerOwnership?,
        requestedMode: String,
        message: String
    )
    case pendingNextTurn(
        active: ClaudePermissionAcknowledgement?,
        requestedMode: String,
        reason: String
    )
}
