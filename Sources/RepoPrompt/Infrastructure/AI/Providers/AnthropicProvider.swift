import Foundation
import SwiftAnthropic

class AnthropicProvider: AIProvider {
    private let service: AnthropicService
    private let requestEncoder: AnthropicRequestEncoder

    init(apiKey: String, betaHeaders: [String] = ["messages-2023-12-15", "prompt-caching-2024-07-31", "output-128k-2025-02-19"]) {
        service = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: betaHeaders)
        requestEncoder = AnthropicRequestEncoder(
            apiKey: apiKey,
            betaHeaders: betaHeaders
        )
    }

    private func createMessages(for aiMessage: AIMessage) -> [AnthropicRequestMessage] {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        var messages: [AnthropicRequestMessage] = []

        for (idx, entry) in aiMessage.conversationMessages.enumerated() {
            let contentText: String = if let lastIdx = lastUserIndex,
                                         entry.role == .user,
                                         idx == lastIdx,
                                         !tail.isEmpty
            {
                "\(tail)\n\n\(entry.content)"
            } else {
                entry.content
            }

            let role: AnthropicRequestMessage.Role = (entry.role == .user) ? .user : .assistant
            messages.append(
                AnthropicRequestMessage(
                    role: role,
                    content: contentText
                )
            )
        }

        return messages
    }

    private func createSystemBlocks(systemPrompt: String) -> [AnthropicSystemBlock] {
        [AnthropicSystemBlock(text: systemPrompt)]
    }

    private func createRequestPlan(
        for aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?,
        fallbackMaxTokens: Int,
        defaultTemperature: Double?
    ) throws -> AnthropicRequestPlan {
        try AnthropicRequestPlan.resolve(
            modelID: model.modelName,
            requestedMaxTokens: maxTokens,
            fallbackMaxTokens: fallbackMaxTokens,
            temperature: aiMessage.effectiveTemperature(for: model) ?? defaultTemperature
        )
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // Check if streaming is enabled for the model
        if !model.canStream {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                continuation.finish()
            }
        }
        guard !aiMessage.systemPrompt.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        let plan = try createRequestPlan(
            for: aiMessage,
            model: model,
            maxTokens: maxTokens,
            fallbackMaxTokens: 8192,
            defaultTemperature: 0
        )
        let system = createSystemBlocks(systemPrompt: aiMessage.systemPrompt)
        let messages = createMessages(for: aiMessage)
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: messages,
            system: system,
            stream: true
        )
        let request = try requestEncoder.makeRequest(payload)

        let stream = try await service.fetchStream(
            type: MessageStreamResponse.self,
            with: request,
            debugEnabled: false
        )

        return AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    // Track current thinking content
                    var currentThinking = ""
                    // Track token counts
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil

                    for try await result in stream {
                        var reasoning: String? = nil

                        // Handle different stream events
                        switch result.streamEvent {
                        case .contentBlockStart:
                            // Check if this is a thinking block starting
                            if let contentBlock = result.contentBlock, contentBlock.type == "thinking" {
                                if let thinking = contentBlock.thinking {
                                    currentThinking = thinking
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockDelta:
                            // Check for thinking delta updates
                            if let delta = result.delta, delta.type == "thinking_delta" {
                                if let thinking = delta.thinking {
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockStop:
                            // If we're stopping a thinking block, include the final thinking
                            if currentThinking.count > 0 {
                                reasoning = currentThinking
                                currentThinking = ""
                            }

                        case .messageStop:
                            // Extract token usage from the end of stream
                            if let usage = result.usage {
                                promptTokens = usage.inputTokens
                                // Combine outputTokens and thinkingTokens for completion tokens
                                let outputTokens = usage.outputTokens
                                let thinkingTokens = usage.thinkingTokens ?? 0
                                completionTokens = outputTokens + thinkingTokens
                            }

                        default:
                            break
                        }

                        // Create AIStreamResult with text and reasoning
                        let aiResult = AIStreamResult(
                            type: result.type,
                            text: result.contentBlock?.text ?? result.delta?.text,
                            reasoning: reasoning,
                            promptTokens: promptTokens, // Only include tokens in final message_stop
                            completionTokens: completionTokens
                        )

                        continuation.yield(aiResult)
                    }

                    // Send final message_stop with token counts
                    continuation.yield(AIStreamResult(
                        type: "message_stop",
                        text: nil,
                        reasoning: nil,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
                    ))

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in bridgeTask.cancel() }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        guard !aiMessage.systemPrompt.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        let plan = try createRequestPlan(
            for: aiMessage,
            model: model,
            maxTokens: maxTokens,
            fallbackMaxTokens: 4096,
            defaultTemperature: nil
        )
        let system = createSystemBlocks(systemPrompt: aiMessage.systemPrompt)
        let messages = createMessages(for: aiMessage)
        let payload = AnthropicMessageRequest(
            plan: plan,
            messages: messages,
            system: system,
            stream: false
        )
        let request = try requestEncoder.makeRequest(payload)

        let response = try await service.fetch(
            type: MessageResponse.self,
            with: request,
            debugEnabled: false
        )

        let text = response.content.compactMap { contentItem in
            switch contentItem {
            case let .text(text, _):
                text
            case .toolUse:
                nil
            case let .thinking(thinking):
                thinking.thinking
            case .serverToolUse:
                nil
            case .webSearchToolResult:
                nil
            case .toolResult:
                nil
            case .codeExecutionToolResult:
                nil
            }
        }.joined()

        // Extract token counts from the response
        let promptTokens = response.usage.inputTokens
        // Combine outputTokens and thinkingTokens for completion tokens
        let outputTokens = response.usage.outputTokens
        let thinkingTokens = response.usage.thinkingTokens ?? 0
        let completionTokens = outputTokens + thinkingTokens

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    func testAPIKey() async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        let result = try await completeMessage(testMessage, model: .claude45Haiku)
        return result.text.lowercased().contains("hello")
    }
}
