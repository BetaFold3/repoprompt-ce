import Foundation

/// Identity-based registry for active one-shot headless providers.
///
/// Removal is the ownership claim for disposal: only the caller that successfully
/// removes a provider may dispose it.
final class ActiveHeadlessAgentProviderStore<Provider: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ObjectIdentifier: Provider] = [:]

    func insert(_ provider: Provider) {
        lock.lock()
        providers[ObjectIdentifier(provider)] = provider
        lock.unlock()
    }

    func contains(_ provider: Provider) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers[ObjectIdentifier(provider)] != nil
    }

    @discardableResult
    func remove(_ provider: Provider) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers.removeValue(forKey: ObjectIdentifier(provider)) != nil
    }

    func removeAll() -> [Provider] {
        lock.lock()
        let current = Array(providers.values)
        providers.removeAll()
        lock.unlock()
        return current
    }
}

/// Class-constrained type erasure for injected headless providers.
final class AnyHeadlessAgentProvider: HeadlessAgentProvider, @unchecked Sendable {
    private let provider: any HeadlessAgentProvider

    init(_ provider: any HeadlessAgentProvider) {
        self.provider = provider
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await provider.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await provider.dispose()
    }
}

/// Shared lifecycle and completion helpers for fresh-per-request headless CLI providers.
///
/// Provider-specific prompt construction, configuration, model validation, and event
/// semantics remain in each provider.
enum HeadlessCLIStreamBridge {
    static let toolEventRejectedDetail = "Tool events are not allowed in tool-free completions."

    enum CompletionAcceptance {
        /// Preserve Cursor's established behavior: a nonempty completion is accepted
        /// even when the upstream omits message_stop.
        case terminalOrNonemptyText
        /// Require an explicit successful terminal event. Partial text is not success.
        case terminalRequired
    }

    static func startStream<Provider: AnyObject>(
        provider: Provider,
        activeProviders: ActiveHeadlessAgentProviderStore<Provider>,
        makeUpstream: () async throws -> AsyncThrowingStream<AIStreamResult, Error>,
        dispose: @escaping @Sendable (Provider) async -> Void
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        activeProviders.insert(provider)

        let upstream: AsyncThrowingStream<AIStreamResult, Error>
        do {
            upstream = try await makeUpstream()
        } catch {
            await disposeIfOwned(
                provider,
                activeProviders: activeProviders,
                dispose: dispose
            )
            throw error
        }

        return bridge(
            upstream,
            provider: provider,
            activeProviders: activeProviders,
            dispose: dispose
        )
    }

    static func bridge<Provider: AnyObject>(
        _ upstream: AsyncThrowingStream<AIStreamResult, Error>,
        provider: Provider,
        activeProviders: ActiveHeadlessAgentProviderStore<Provider>,
        dispose: @escaping @Sendable (Provider) async -> Void
    ) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    for try await result in upstream {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                guard !Task.isCancelled else { return }
                await disposeIfOwned(
                    provider,
                    activeProviders: activeProviders,
                    dispose: dispose
                )
            }

            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                bridgeTask.cancel()
                Task {
                    await disposeIfOwned(
                        provider,
                        activeProviders: activeProviders,
                        dispose: dispose
                    )
                }
            }
        }
    }

    static func complete(
        stream: AsyncThrowingStream<AIStreamResult, Error>,
        providerName: String,
        acceptance: CompletionAcceptance,
        missingSuccessDetail: String? = nil
    ) async throws -> AICompletionResult {
        var textParts: [String] = []
        var finalContent: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var sawMessageStop = false

        for try await result in stream {
            switch result.type {
            case "content":
                if let text = result.text, !text.isEmpty {
                    textParts.append(text)
                }
            case "final_content":
                if let text = result.text, !text.isEmpty {
                    finalContent = text
                }
            case "message_stop":
                sawMessageStop = true
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case "error":
                throw AIProviderError.invalidConfiguration(
                    detail: result.text ?? "\(providerName) ACP reported an error"
                )
            case "tool_call", "tool_result", "tool_progress":
                switch acceptance {
                case .terminalRequired:
                    throw AIProviderError.invalidResponse(detail: toolEventRejectedDetail)
                case .terminalOrNonemptyText:
                    continue
                }
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        let isAccepted = switch acceptance {
        case .terminalOrNonemptyText:
            sawMessageStop || !text.isEmpty
        case .terminalRequired:
            sawMessageStop
        }
        guard isAccepted else {
            throw AIProviderError.invalidResponse(
                detail: missingSuccessDetail ?? "\(providerName) returned no successful completion"
            )
        }

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }

    static func disposeAll<Provider: AnyObject>(
        activeProviders: ActiveHeadlessAgentProviderStore<Provider>,
        dispose: @escaping @Sendable (Provider) async -> Void
    ) async {
        let providers = activeProviders.removeAll()
        for provider in providers {
            await dispose(provider)
        }
    }

    private static func disposeIfOwned<Provider: AnyObject>(
        _ provider: Provider,
        activeProviders: ActiveHeadlessAgentProviderStore<Provider>,
        dispose: @escaping @Sendable (Provider) async -> Void
    ) async {
        guard activeProviders.remove(provider) else { return }
        await dispose(provider)
    }
}
