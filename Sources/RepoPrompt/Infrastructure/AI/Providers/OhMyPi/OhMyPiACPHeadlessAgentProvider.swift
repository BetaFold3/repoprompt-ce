import Foundation

/// Fresh-session-only headless adapter for OMP.
///
/// Resume identifiers are intentionally discarded until cross-process session/load with
/// MCP re-registration is proven. Transcript handoff remains part of the fresh prompt.
final class OhMyPiACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: OhMyPiAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

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
                let routed = await MCPRoutingWaiter.waitUntilRouted(
                    runID: runID,
                    timeoutSeconds: Double(ContextBuilderDefaults.mcpRoutingTimeoutMilliseconds) / 1000
                )
                guard routed else {
                    throw AIProviderError.invalidConfiguration(
                        detail: "Oh My Pi MCP routing did not complete before prompt dispatch."
                    )
                }
                if let model = Self.selectedModelToApply(config: config) {
                    try await controller.setSessionModel(model)
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
        message _: AgentMessage
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
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
