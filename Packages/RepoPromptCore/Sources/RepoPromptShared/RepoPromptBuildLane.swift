#if DEBUG
    /// Runtime label for the Dev app build lane. Exists only under `DEBUG`, so release binaries are unchanged.
    /// `RPCE_OPTIMIZED_DIAGNOSTICS` is defined only by the optimized-diagnostics lane (`-c release` with first-party `DEBUG`).
    public enum RepoPromptBuildLane: String, Sendable {
        case debug, debugOptimized = "debug-optimized"
        public static let current: RepoPromptBuildLane = {
            #if RPCE_OPTIMIZED_DIAGNOSTICS
                return .debugOptimized
            #else
                return .debug
            #endif
        }()
    }
#endif
#if RPCE_OPTIMIZED_DIAGNOSTICS && !DEBUG
    #error("RPCE_OPTIMIZED_DIAGNOSTICS requires DEBUG")
#endif
