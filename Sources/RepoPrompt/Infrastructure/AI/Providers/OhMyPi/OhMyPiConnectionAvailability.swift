import Foundation

/// Global effective availability used by non-window OMP request surfaces.
///
/// Window-owned settings view models keep using their published connection state, while
/// global services and one-shot providers share this persisted connection + DEBUG override.
enum OhMyPiConnectionAvailability {
    static func isEffectivelyConnected(
        userDefaults: UserDefaults = .standard,
        debugOverride: Bool = currentDebugOverride
    ) -> Bool {
        userDefaults.bool(forKey: "OhMyPiCLIConnected") || debugOverride
    }

    private static var currentDebugOverride: Bool {
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.isEnabled
        #else
            false
        #endif
    }
}
