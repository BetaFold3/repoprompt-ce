import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform

// App composition for agent-code providers and helpers that read per-model overrides.
// Each convenience keeps the current signature and injects the settings-backed
// `AppModelOverrideReader`, so App/UI/test construction sites stay unchanged.

extension OpenAIProvider {
    convenience init(
        apiKey: String? = nil,
        baseURL: URL? = nil,
        configuredMaxTokens: Int? = nil,
        overrideVersion: String? = nil,
        includeUsageInStream: Bool = true,
        serviceTier: String? = nil
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: configuredMaxTokens,
            overrideVersion: overrideVersion,
            includeUsageInStream: includeUsageInStream,
            serviceTier: serviceTier,
            modelOverrides: AppModelOverrideReader()
        )
    }
}

extension ZAIProvider {
    convenience init(apiKey: String, endpoint: Endpoint = .generalAPI) {
        self.init(apiKey: apiKey, endpoint: endpoint, modelOverrides: AppModelOverrideReader())
    }
}

extension CustomOpenAIProvider {
    convenience init(
        baseURL: String,
        apiKey: String,
        defaultModel: String,
        defaultTemperature: Double = 0.3,
        customHeaders: [String: String] = [:],
        configuredMaxTokens: Int? = nil,
        includeContentTypeHeader: Bool = false,
        apiVersion: String? = nil,
        httpClient: HTTPClient = DefaultHTTPClient.aiClient,
        streamingHttpClient: HTTPClient = DefaultHTTPClient.aiStreamingClient
    ) {
        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            defaultModel: defaultModel,
            defaultTemperature: defaultTemperature,
            customHeaders: customHeaders,
            configuredMaxTokens: configuredMaxTokens,
            includeContentTypeHeader: includeContentTypeHeader,
            apiVersion: apiVersion,
            httpClient: httpClient,
            streamingHttpClient: streamingHttpClient,
            modelOverrides: AppModelOverrideReader()
        )
    }
}

extension AzureOpenAIProvider {
    /// App wrapper over `defaultModelDescriptors(overrides:)` (compute-once, process-wide).
    static var defaultModelDescriptors: [AzureOpenAIConfiguration.ModelDescriptor] {
        defaultModelDescriptors(overrides: AppModelOverrideReader())
    }

    static func mergedWithDefaultDescriptors(
        _ descriptors: [AzureOpenAIConfiguration.ModelDescriptor]
    ) -> [AzureOpenAIConfiguration.ModelDescriptor] {
        mergedWithDefaultDescriptors(descriptors, overrides: AppModelOverrideReader())
    }

    static func discoverDeployments(
        baseURL: URL,
        apiKey: String,
        apiVersions: [String]
    ) async throws -> [AzureOpenAIConfiguration.ModelDescriptor] {
        try await discoverDeployments(
            baseURL: baseURL,
            apiKey: apiKey,
            apiVersions: apiVersions,
            overrides: AppModelOverrideReader()
        )
    }
}

extension OpenAIConfiguredModelProjection {
    static func legacyServiceTierVariants(
        for baseModels: Set<AIModel>,
        enabled: Bool
    ) -> Set<AIModel> {
        legacyServiceTierVariants(for: baseModels, enabled: enabled, overrides: AppModelOverrideReader())
    }
}
