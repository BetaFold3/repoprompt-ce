import Foundation
import RepoPromptPlatform

// App-owned: records agent CLI path-resolution failures installed as
// `AgentCLILaunchDiagnostics.pathResolutionFailureRecorder`.
extension SentryTelemetryBootstrap {
    static func recordAgentCLIPathResolutionFailure(_ failure: AgentCLIPathResolutionFailure) {
        let providerKind = ProviderKind(agentKind: failure.providerKind)
        addBreadcrumb(
            .cliPath,
            action: .cliPathResolutionFailed,
            attributes: [
                .providerKind(providerKind),
                .shellEnvironmentSource(failure.shellEnvironmentSource),
                .resultCount(failure.candidateCount),
                .outcome(.failed)
            ]
        )
        increment(
            .cliPathResolutionFailures,
            attributes: [
                .providerKind(providerKind),
                .shellEnvironmentSource(failure.shellEnvironmentSource),
                .resultCount(failure.candidateCount)
            ]
        )
    }
}
