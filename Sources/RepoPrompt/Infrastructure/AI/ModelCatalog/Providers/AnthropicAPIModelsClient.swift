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
}

struct AnthropicAPIModelsClient {
    private struct ModelDescriptor: Decodable {
        let id: String
    }

    private struct ModelsPage: Decodable {
        let data: [ModelDescriptor]
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
        var modelIDs: [String] = []
        var afterID: String?
        var seenCursors = Set<String>()

        for pageIndex in 0 ..< maximumPageCount {
            let request = try makeRequest(afterID: afterID)
            let response = try await transport.response(for: request)
            guard (200 ... 299).contains(response.statusCode) else {
                throw AnthropicAPIModelsClientError.httpStatus(response.statusCode)
            }

            let page = try JSONDecoder().decode(ModelsPage.self, from: response.data)
            modelIDs.append(contentsOf: page.data.map(\.id))
            guard page.hasMore else { return modelIDs }

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
