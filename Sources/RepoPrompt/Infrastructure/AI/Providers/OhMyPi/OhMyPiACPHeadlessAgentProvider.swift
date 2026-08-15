import Foundation

/// Headless ACP adapter for OMP.
///
/// Persisted provider session identifiers are forwarded to OMP's session/load path. Load
/// failures remain fail-closed so a missing transcript is never replaced by a silent fresh session.
final class OhMyPiACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: OhMyPiAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory
    typealias RoutingOutcomeWaiter = @Sendable (UUID, TimeInterval) async -> MCPRoutingWaiter.WaitOutcome
    typealias LiveRouteVerifier = @Sendable (UUID) async -> Bool

    private let config: OhMyPiAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: OhMyPiAgentConfig {
            config
        }
    #endif

    init(
        config: OhMyPiAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            OhMyPiACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Oh My Pi",
            makeProvider: {
                resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                Self.makeRunRequest(config: config, workspacePath: workspacePath, message: message)
            },
            makeController: controllerFactory,
            beforePrompt: { controller, _, runID in
                if let model = Self.selectedModelToApply(config: config) {
                    try await controller.setSessionModel(model)
                }
                let routed = await Self.prePromptMCPRouteIsReady(runID: runID)
                guard routed else {
                    throw AIProviderError.invalidConfiguration(
                        detail: "Oh My Pi MCP routing did not complete before prompt dispatch."
                    )
                }
            },
            approvalPolicy: .declineUnsupported
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }

    static func makeRunRequest(
        config: OhMyPiAgentConfig,
        workspacePath: String?,
        message: AgentMessage
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    static func prePromptMCPRouteIsReady(
        runID: UUID,
        timeoutSeconds: TimeInterval = Double(ContextBuilderDefaults.mcpRoutingTimeoutMilliseconds) / 1000,
        waitForRoutingOutcome: @escaping RoutingOutcomeWaiter = { runID, timeoutSeconds in
            await MCPRoutingWaiter.waitUntilRoutedOutcome(
                runID: runID,
                timeoutSeconds: timeoutSeconds
            )
        },
        verifyLiveRoute: @escaping LiveRouteVerifier = { runID in
            await ServerNetworkManager.shared.hasAuthoritativeLiveRunRoute(
                runID: runID,
                expectedClientName: AgentProviderKind.ohMyPiMCPClientID
            )
        }
    ) async -> Bool {
        switch await waitForRoutingOutcome(runID, timeoutSeconds) {
        case .notRouted:
            return false
        case .routed, .unregistered:
            guard !Task.isCancelled else { return false }
            let hasLiveRoute = await verifyLiveRoute(runID)
            return hasLiveRoute && !Task.isCancelled
        }
    }

    static func selectedModelToApply(config: OhMyPiAgentConfig) -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        guard let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi) else {
            return nil
        }
        return snapshot.contains(rawModel: model) ? model : nil
    }
}
