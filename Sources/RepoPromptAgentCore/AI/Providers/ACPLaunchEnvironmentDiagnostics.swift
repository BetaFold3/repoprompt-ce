import Foundation
import RepoPromptPlatform

struct ACPLaunchEnvironment: Equatable {
    let environment: [String: String]
    let shellEnvironmentSource: ShellEnvironmentSource?

    init(environment: [String: String], shellEnvironmentSource: ShellEnvironmentSource? = nil) {
        self.environment = environment
        self.shellEnvironmentSource = shellEnvironmentSource
    }
}

package enum AgentCLILaunchDiagnostics {
    static func fallbackEnvironmentHint(for source: ShellEnvironmentSource?) -> String? {
        switch source {
        case .enrichedFallback:
            "Environment was built from RepoPrompt's fallback PATH because login-shell capture failed or timed out; PATH may not match Terminal."
        case .previousCapturedFallback:
            "Environment reused the last captured shell PATH because login-shell capture failed or timed out; PATH may be stale."
        case .capturedLoginShell, .inheritedRichEnvironment, .none:
            nil
        }
    }

    static func appendFallbackEnvironmentHint(to message: String, source: ShellEnvironmentSource?) -> String {
        guard let hint = fallbackEnvironmentHint(for: source) else { return message }
        return "\(message) \(hint)"
    }

    /// Set once by App composition at launch, before any resolver runs; records nothing when unset.
    package nonisolated(unsafe) static var pathResolutionFailureRecorder: ((AgentCLIPathResolutionFailure) -> Void)?

    static func recordPathResolutionFailure(
        providerKind: AgentProviderKind,
        shellEnvironmentSource: ShellEnvironmentSource?,
        candidateCount: Int
    ) {
        pathResolutionFailureRecorder?(
            AgentCLIPathResolutionFailure(
                providerKind: providerKind,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: candidateCount
            )
        )
    }
}

package struct AgentCLIPathResolutionFailure {
    package let providerKind: AgentProviderKind
    package let shellEnvironmentSource: ShellEnvironmentSource?
    package let candidateCount: Int
}
