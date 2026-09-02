import Foundation

struct AnthropicAPIModelsTransportResponse {
    let data: Data
    let statusCode: Int
}

protocol AnthropicAPIModelsTransport: Sendable {
    func response(for request: URLRequest) async throws -> AnthropicAPIModelsTransportResponse
}

struct AnthropicAPIModelsURLSessionTransport: AnthropicAPIModelsTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> AnthropicAPIModelsTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AnthropicAPIModelsClientError.invalidHTTPResponse
        }
        return AnthropicAPIModelsTransportResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

enum AnthropicAPIModelsClientError: Error, Equatable {
    case invalidEndpoint
    case invalidHTTPResponse
    case httpStatus(Int)
    case missingPaginationCursor
    case repeatedPaginationCursor(String)
    case pageLimitExceeded(Int)
    case invalidModelDescriptor
}

// Explicit because these values cross actor/task boundaries in catalog refresh payloads.
// swiftformat:disable:next redundantSendable
enum AnthropicJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([AnthropicJSONValue])
    case object([String: AnthropicJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnthropicJSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: AnthropicJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// swiftformat:disable:next redundantSendable
struct AnthropicDiscoveredModel: Codable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let maxInputTokens: Int?
    let maxOutputTokens: Int?
    let capabilities: AnthropicJSONValue?

    init(
        id: String,
        displayName: String? = nil,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: AnthropicJSONValue? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case maxInputTokens = "max_input_tokens"
        case maxOutputTokens = "max_tokens"
        case capabilities
    }
}

enum AnthropicDiscoveredModelValidation {
    static func canonicalizedPreservingOrder(
        _ models: [AnthropicDiscoveredModel]
    ) -> [AnthropicDiscoveredModel]? {
        var canonical: [AnthropicDiscoveredModel] = []
        var seen = Set<String>()

        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  id.utf8.count <= 512,
                  !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(id).inserted,
                  model.maxInputTokens.map({ $0 > 0 }) ?? true,
                  model.maxOutputTokens.map({ $0 > 0 }) ?? true
            else {
                return nil
            }

            let displayName = model.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            canonical.append(AnthropicDiscoveredModel(
                id: id,
                displayName: displayName?.isEmpty == false ? displayName : nil,
                maxInputTokens: model.maxInputTokens,
                maxOutputTokens: model.maxOutputTokens,
                capabilities: model.capabilities
            ))
        }
        return canonical
    }
}

struct AnthropicAPIModelsClient {
    private struct TolerantModelDescriptor: Decodable {
        let id: String
        let displayName: String?
        let maxInputTokens: Int?
        let maxOutputTokens: Int?
        let capabilities: AnthropicJSONValue?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try? container.decode(String.self, forKey: .displayName)
            maxInputTokens = try? container.decode(Int.self, forKey: .maxInputTokens)
            maxOutputTokens = try? container.decode(Int.self, forKey: .maxOutputTokens)
            capabilities = try? container.decode(AnthropicJSONValue.self, forKey: .capabilities)
        }

        var discoveredModel: AnthropicDiscoveredModel {
            AnthropicDiscoveredModel(
                id: id,
                displayName: displayName,
                maxInputTokens: maxInputTokens,
                maxOutputTokens: maxOutputTokens,
                capabilities: capabilities
            )
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case maxInputTokens = "max_input_tokens"
            case maxOutputTokens = "max_tokens"
            case capabilities
        }
    }

    private struct ModelsPage: Decodable {
        let data: [TolerantModelDescriptor]
        let lastID: String?
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case data
            case lastID = "last_id"
            case hasMore = "has_more"
        }
    }

    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/models")!

    private let endpoint: URL
    private let apiKey: String
    private let anthropicVersion: String
    private let pageSize: Int
    private let maximumPageCount: Int
    private let transport: any AnthropicAPIModelsTransport

    init(
        endpoint: URL = Self.defaultEndpoint,
        apiKey: String,
        anthropicVersion: String = "2023-06-01",
        pageSize: Int = 1000,
        maximumPageCount: Int = 100,
        transport: any AnthropicAPIModelsTransport = AnthropicAPIModelsURLSessionTransport()
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.anthropicVersion = anthropicVersion
        self.pageSize = min(max(pageSize, 1), 1000)
        self.maximumPageCount = max(maximumPageCount, 1)
        self.transport = transport
    }

    func fetchModelIDs() async throws -> [String] {
        try await fetchModels().map(\.id)
    }

    func fetchModels() async throws -> [AnthropicDiscoveredModel] {
        var models: [AnthropicDiscoveredModel] = []
        var afterID: String?
        var seenCursors = Set<String>()

        for pageIndex in 0 ..< maximumPageCount {
            let request = try makeRequest(afterID: afterID)
            let response = try await transport.response(for: request)
            guard (200 ... 299).contains(response.statusCode) else {
                throw AnthropicAPIModelsClientError.httpStatus(response.statusCode)
            }

            let page = try JSONDecoder().decode(ModelsPage.self, from: response.data)
            models.append(contentsOf: page.data.map(\.discoveredModel))
            guard page.hasMore else {
                guard let canonicalModels = AnthropicDiscoveredModelValidation
                    .canonicalizedPreservingOrder(models)
                else {
                    throw AnthropicAPIModelsClientError.invalidModelDescriptor
                }
                return canonicalModels
            }

            guard let rawCursor = page.lastID else {
                throw AnthropicAPIModelsClientError.missingPaginationCursor
            }
            let cursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cursor.isEmpty else {
                throw AnthropicAPIModelsClientError.missingPaginationCursor
            }
            guard cursor != afterID, seenCursors.insert(cursor).inserted else {
                throw AnthropicAPIModelsClientError.repeatedPaginationCursor(cursor)
            }
            afterID = cursor

            if pageIndex == maximumPageCount - 1 {
                throw AnthropicAPIModelsClientError.pageLimitExceeded(maximumPageCount)
            }
        }

        throw AnthropicAPIModelsClientError.pageLimitExceeded(maximumPageCount)
    }

    private func makeRequest(afterID: String?) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AnthropicAPIModelsClientError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "limit", value: String(pageSize)))
        if let afterID {
            queryItems.append(URLQueryItem(name: "after_id", value: afterID))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AnthropicAPIModelsClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }
}

enum AnthropicDiscoveredModelCatalog {
    static func models(from modelIDs: [String]) -> Set<AIModel> {
        Set(modelIDs.compactMap(model(from:)))
    }

    private static func model(from rawModelID: String) -> AIModel? {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              !modelID.hasSuffix("-thinking"),
              !modelID.hasSuffix("-thinking-max")
        else {
            return nil
        }

        if let knownModel = AIModel.fromModelName(modelID),
           knownModel.providerType == .anthropic
        {
            return knownModel
        }
        return .anthropicCustom(name: modelID)
    }
}
