import Foundation

package struct CustomProviderConfiguration: Codable {
    package let url: String
    let defaultModel: String
    let headers: [String: String]
    package let name: String
    package var enabledModels: Set<String>
    private static let defaultTemperature = 0.3
    package var maxTokens: Int? // Add the new optional maxTokens property
    package var userPreferredModel: String?
    package var includeContentTypeHeader: Bool = false // Add flag for Content-Type header
    package var apiVersion: String? = nil // NEW: optional API version (e.g., "v1", "v4")

    enum CodingKeys: String, CodingKey {
        case url, defaultModel, headers, name, enabledModels, maxTokens, userPreferredModel, includeContentTypeHeader, apiVersion
    }

    /// Custom decoder to handle backwards compatibility
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        defaultModel = try container.decode(String.self, forKey: .defaultModel)
        headers = try container.decode([String: String].self, forKey: .headers)
        name = try container.decode(String.self, forKey: .name)
        enabledModels = try container.decode(Set<String>.self, forKey: .enabledModels)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        userPreferredModel = try container.decodeIfPresent(String.self, forKey: .userPreferredModel)
        // Default to false for backwards compatibility
        includeContentTypeHeader = try container.decodeIfPresent(Bool.self, forKey: .includeContentTypeHeader) ?? false
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) // may be nil for legacy
    }

    /// Manual initializer
    package init(url: String, defaultModel: String, headers: [String: String], name: String, enabledModels: Set<String> = [], maxTokens: Int? = nil, userPreferredModel: String? = nil, includeContentTypeHeader: Bool = false, apiVersion: String? = nil) throws { // Add maxTokens, includeContentTypeHeader, apiVersion
        guard !url.isEmpty else {
            throw AIProviderError.missingURL
        }
        guard !defaultModel.isEmpty else {
            throw AIProviderError.invalidModel
        }
        guard !name.isEmpty else {
            throw AIProviderError.providerNotConfigured
        }

        self.url = url
        self.defaultModel = defaultModel
        self.headers = headers
        self.name = name
        self.enabledModels = enabledModels
        self.maxTokens = maxTokens // Initialize the new property
        self.userPreferredModel = userPreferredModel
        self.includeContentTypeHeader = includeContentTypeHeader // Initialize the new flag
        self.apiVersion = apiVersion
    }

    var effectiveDefaultModel: String {
        userPreferredModel?.isEmpty == false ? userPreferredModel! : defaultModel
    }

    package static func load() throws -> CustomProviderConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "CustomProviderConfig") else {
            throw AIProviderError.providerNotConfigured
        }
        return try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)
    }

    package static func save(_ config: CustomProviderConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        UserDefaults.standard.set(data, forKey: "CustomProviderConfig")
    }

    package static func save(_ config: CustomProviderConfiguration, apiKey: String, keyManager: KeyManager) async throws {
        try save(config)
        try await keyManager.saveAPIKey(apiKey, for: .customProvider)
    }

    package static func delete() {
        UserDefaults.standard.removeObject(forKey: "CustomProviderConfig")
    }

    package mutating func updateModelSettings(model: String, isEnabled: Bool) {
        if isEnabled {
            enabledModels.insert(model)
        } else {
            enabledModels.remove(model)
        }
    }
}
