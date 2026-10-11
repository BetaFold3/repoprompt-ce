import Foundation

/// Configuration for Codex Exec agent provider.
struct CodexExecAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let modelString: String?
    let enableDebugLogging: Bool

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.codex,
        modelString: String? = nil,
        enableDebugLogging: Bool = false
    ) {
        let resolvedCommand = commandName ?? "codex"
        self.commandName = resolvedCommand
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
    }
}
