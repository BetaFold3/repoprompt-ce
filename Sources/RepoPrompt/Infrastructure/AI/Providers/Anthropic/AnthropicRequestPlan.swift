import Foundation

struct AnthropicRequestPlan: Equatable {
    let modelID: String
    let maxTokens: Int
    let thinking: AnthropicThinkingConfiguration
    let effort: AnthropicEffort?
    let temperature: Double?

    static func resolve(
        modelID: String,
        requestedMaxTokens: Int?,
        fallbackMaxTokens: Int,
        temperature: Double?,
        effort: AnthropicEffort? = nil
    ) throws -> AnthropicRequestPlan {
        let configuration = try AnthropicModelConfiguration.resolve(
            modelID: modelID,
            effort: effort
        )
        let resolvedMaxTokens = requestedMaxTokens
            ?? configuration.defaultMaxTokens
            ?? fallbackMaxTokens
        if case let .enabled(budgetTokens) = configuration.thinking,
           resolvedMaxTokens <= budgetTokens
        {
            throw AnthropicModelConfigurationError.insufficientMaxTokens(
                modelID: configuration.apiModelID,
                budgetTokens: budgetTokens,
                maxTokens: resolvedMaxTokens
            )
        }

        return AnthropicRequestPlan(
            modelID: configuration.apiModelID,
            maxTokens: resolvedMaxTokens,
            thinking: configuration.thinking,
            effort: configuration.effort,
            temperature: configuration.thinking.suppressesSamplingParameters
                ? nil
                : temperature
        )
    }
}

struct AnthropicRequestMessage: Encodable, Equatable {
    enum Role: String, Encodable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct AnthropicSystemBlock: Encodable, Equatable {
    let type = "text"
    let text: String
    let cacheControl = CacheControl()

    struct CacheControl: Encodable, Equatable {
        let type = "ephemeral"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case cacheControl = "cache_control"
    }
}

struct AnthropicMessageRequest: Encodable {
    let model: String
    let messages: [AnthropicRequestMessage]
    let maxTokens: Int
    let system: [AnthropicSystemBlock]
    let stream: Bool
    let temperature: Double?
    let thinking: Thinking?
    let outputConfig: OutputConfig?

    init(
        plan: AnthropicRequestPlan,
        messages: [AnthropicRequestMessage],
        system: [AnthropicSystemBlock],
        stream: Bool
    ) {
        model = plan.modelID
        self.messages = messages
        maxTokens = plan.maxTokens
        self.system = system
        self.stream = stream
        temperature = plan.temperature
        thinking = Thinking(plan.thinking)
        outputConfig = plan.effort.map(OutputConfig.init)
    }

    struct Thinking: Encodable {
        let type: String
        let budgetTokens: Int?

        init?(_ configuration: AnthropicThinkingConfiguration) {
            switch configuration {
            case .none:
                return nil
            case let .enabled(budgetTokens):
                type = "enabled"
                self.budgetTokens = budgetTokens
            case .adaptive:
                type = "adaptive"
                budgetTokens = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case budgetTokens = "budget_tokens"
        }
    }

    struct OutputConfig: Encodable {
        let effort: AnthropicEffort

        init(_ effort: AnthropicEffort) {
            self.effort = effort
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case system
        case stream
        case temperature
        case thinking
        case outputConfig = "output_config"
    }
}

struct AnthropicRequestEncoder {
    private let apiKey: String
    private let betaHeaders: [String]
    private let apiVersion: String
    private let baseURL: URL

    init(
        apiKey: String,
        betaHeaders: [String],
        apiVersion: String = "2023-06-01",
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.apiKey = apiKey
        self.betaHeaders = betaHeaders
        self.apiVersion = apiVersion
        self.baseURL = baseURL
    }

    func makeRequest(_ payload: AnthropicMessageRequest) throws -> URLRequest {
        let messagesURL = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("messages")
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("SwiftAnthropic", forHTTPHeaderField: "User-Agent")
        if !betaHeaders.isEmpty {
            request.setValue(
                betaHeaders.joined(separator: ","),
                forHTTPHeaderField: "anthropic-beta"
            )
        }
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}
