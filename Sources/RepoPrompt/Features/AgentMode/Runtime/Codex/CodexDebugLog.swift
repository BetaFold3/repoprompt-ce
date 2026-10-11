import Foundation

enum CodexDebugLog {
    nonisolated static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableCodexDebugLogging") else { return }
            print(message())
        #endif
    }
}
