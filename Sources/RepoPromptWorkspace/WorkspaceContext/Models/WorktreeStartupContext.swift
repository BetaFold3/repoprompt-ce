import Foundation

package enum WorktreeStartupServingControl: Equatable {
    case automatic
    case forceFullCrawl
}

package struct WorktreeStartupFeatureFlags: Equatable {
    static let observeDefaultsKey = "observeDiffSeededWorktreeStartup"
    static let serveDefaultsKey = "serveDiffSeededWorktreeStartup"

    package let observeDiffSeededWorktreeStartup: Bool
    let serveDiffSeededWorktreeStartup: Bool

    package init(
        observeDiffSeededWorktreeStartup: Bool = false,
        serveDiffSeededWorktreeStartup: Bool = false
    ) {
        self.observeDiffSeededWorktreeStartup = observeDiffSeededWorktreeStartup
        // Serving can never be active without observation authority.
        self.serveDiffSeededWorktreeStartup = serveDiffSeededWorktreeStartup
            && observeDiffSeededWorktreeStartup
    }

    package static func current(defaults: UserDefaults = .standard) -> Self {
        #if DEBUG
            // Diff-seeded worktree startup is always on. In DEBUG we still honor optional
            // UserDefaults kill switches so we can force the legacy full-crawl path for
            // benchmarks/troubleshooting; an absent key means enabled.
            return Self(
                observeDiffSeededWorktreeStartup: defaults.object(forKey: observeDefaultsKey) as? Bool ?? true,
                serveDiffSeededWorktreeStartup: defaults.object(forKey: serveDefaultsKey) as? Bool ?? true
            )
        #else
            // Hardcoded on in release: there is no production preference to disable diff-seeded
            // worktree startup. The kill switches above exist only for DEBUG diagnostics.
            return Self(
                observeDiffSeededWorktreeStartup: true,
                serveDiffSeededWorktreeStartup: true
            )
        #endif
    }
}

package struct WorktreeStartupContext: Equatable {
    package let agentSessionID: UUID
    package let correlationID: UUID
    package let flags: WorktreeStartupFeatureFlags
    let servingControl: WorktreeStartupServingControl

    package init(
        agentSessionID: UUID,
        correlationID: UUID = UUID(),
        flags: WorktreeStartupFeatureFlags = .current(),
        servingControl: WorktreeStartupServingControl = .automatic
    ) {
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        self.flags = flags
        self.servingControl = servingControl
    }
}
