@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform

@MainActor
enum WorkspaceRootLoadTestSupport {
    static func loadRootMatchingCurrentFileSystemSettings(
        in window: WindowState,
        path: String
    ) async throws -> WorkspaceRootRecord {
        let settings = GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
        return try await window.workspaceFileContextStore.loadRoot(
            path: path,
            respectRepoIgnore: settings.respectRepoIgnore,
            respectCursorignore: settings.respectCursorignore,
            skipSymlinks: settings.skipSymlinks,
            enableHierarchicalIgnores: settings.enableHierarchicalIgnores
        )
    }
}
