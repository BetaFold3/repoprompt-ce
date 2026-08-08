import Foundation

enum AgentHandoffActionSupport {
    enum Action: Equatable {
        case copyPayload
        case handoff
    }

    enum ClipboardPayloadResult: Equatable {
        case success(String)
        case failure(String)
    }

    @MainActor
    static func clipboardPayloadResult(config: AgentHandoffConfig) async -> ClipboardPayloadResult {
        do {
            return try await .success(config.buildPayloadForClipboard())
        } catch {
            return .failure(errorMessage(for: .copyPayload, error: error))
        }
    }

    @MainActor
    static func performCommittedHandoff(
        _ destination: AgentHandoffDestination,
        defaults: UserDefaults = .standard,
        perform: @MainActor (AgentHandoffDestination) async throws -> Void
    ) async throws {
        let canonicalDestination = canonicalizedDestination(destination)
        try await perform(canonicalDestination)
        guard case let .local(selection) = canonicalDestination,
              selection.agent == .codexExec
        else {
            return
        }

        if let effort = CodexReasoningEffort.parse(selection.reasoningEffortRaw) {
            CodexAgentToolPreferences.setLastUsedReasoningEffort(
                effort,
                forModelRaw: selection.modelRaw,
                defaults: defaults
            )
        }
    }

    static func canonicalizedDestination(
        _ destination: AgentHandoffDestination
    ) -> AgentHandoffDestination {
        guard case let .local(selection) = destination else { return destination }
        return .local(canonicalizedSelection(selection))
    }

    static func canonicalizedSelection(
        _ selection: AgentHandoffSelection
    ) -> AgentHandoffSelection {
        guard selection.agent == .codexExec,
              let encodedEffort = CodexModelSpecifier(raw: selection.modelRaw).reasoningEffort
        else {
            return selection
        }
        return AgentHandoffSelection(
            agent: selection.agent,
            modelRaw: selection.modelRaw,
            reasoningEffortRaw: encodedEffort.rawValue
        )
    }

    static func errorMessage(for action: Action, error: Error) -> String {
        if let remoteError = error as? RemoteClientError,
           case let .inDoubt(commandError) = remoteError
        {
            let detail = commandError.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if action == .copyPayload {
                let suffix = detail.isEmpty
                    ? "The host did not confirm whether payload extraction completed."
                    : detail
                return "Copy Payload outcome is uncertain (in doubt). \(suffix)"
            }
            let suffix = detail.isEmpty ? "The host may already have created the fork." : detail
            return "Handoff outcome is uncertain (in doubt). \(suffix) Check remote sessions before retrying."
        }
        let prefix = action == .copyPayload ? "Copy Payload failed" : "Handoff failed"
        return "\(prefix): \(error.localizedDescription)"
    }
}
