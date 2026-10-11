import Foundation
import RepoPromptPlatform

package struct OhMyPiACPAgentProvider: ACPAgentProvider {
    private let config: OhMyPiAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: OhMyPiACPLaunchResolver

    #if DEBUG
        var test_config: OhMyPiAgentConfig {
            config
        }
    #endif

    init(
        config: OhMyPiAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: OhMyPiACPLaunchResolver = OhMyPiACPLaunchResolver()
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
    }

    package var providerID: ACPProviderID {
        .ohMyPi
    }

    package func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    package func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        if config.includeRepoPromptMCPServer {
            try repoPromptMCPConfiguration.validateACPLaunchCommand(workingDirectory: workingDirectory)
        }
        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: resolvedLaunch.arguments,
            environment: OhMyPiAgentConfig.managedEnvironment,
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity,
            expectedProcessExecutablePath: resolvedLaunch.processExecutablePath,
            expectedProcessExecutableIdentity: resolvedLaunch.processExecutableIdentity
        )
    }

    package func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let resumeSessionID = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: ACPSessionConfiguration.Mode = if let resumeSessionID, !resumeSessionID.isEmpty {
            .load(existingSessionID: resumeSessionID)
        } else {
            .new
        }
        return ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            mcpServers: config.includeRepoPromptMCPServer ? [repoPromptMCPConfiguration] : []
        )
    }

    package func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String = if isFollowUp || systemPrompt.isEmpty {
            userMessage.isEmpty ? message.userMessage : userMessage
        } else if userMessage.isEmpty {
            systemPrompt
        } else {
            "\(systemPrompt)\n\n\(userMessage)"
        }
        return try ACPPromptContentBuilder.blocks(text: text, attachments: request.attachments)
    }

    package func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        OhMyPiACPEventNormalizer.normalize(payload)
    }

    package func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
        context.authMethodIDs.first {
            $0.caseInsensitiveCompare("agent") == .orderedSame
        }
    }

    package func normalizeError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if error is AIProviderError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(
                detail: "Oh My Pi CLI not found. Install it and ensure omp is available on PATH."
            )
        }
        if error is OhMyPiACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = description.lowercased()
        let authenticationPhrases = [
            "not authenticated",
            "unauthorized",
            "authentication required",
            "login required",
            "requires login"
        ]
        if authenticationPhrases.contains(where: lower.contains) {
            return AIProviderError.invalidConfiguration(
                detail: "Oh My Pi is not authenticated. Open the OMP TUI (omp), complete provider sign-in/authentication, then retry."
            )
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
        let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cwd?.isEmpty == false ? cwd : nil)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            ?? FileManager.default.temporaryDirectory.path
    }
}
