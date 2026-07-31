import Foundation
@testable import RepoPromptApp
import XCTest

final class AnthropicAPIModelsClientTests: XCTestCase {
    @MainActor
    func testRestoredAnthropicKeyPublishesDiscoveredAPIModels() async throws {
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: "restored-test-key"])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let loader = AnthropicModelsLoaderProbe(modelIDs: [
            "claude-opus-5",
            "claude-future-1"
        ])
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: APIModelCatalog(),
            anthropicModelsLoader: { key in
                await loader.load(key: key)
            }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        try await waitUntil {
            viewModel.availableAnthropicModels == ["claude-future-1", "claude-opus-5"]
        }

        let loadedKeys = await loader.loadedKeys()
        XCTAssertEqual(loadedKeys, ["restored-test-key"])
        XCTAssertTrue(viewModel.availableModels.contains(.claude5Opus))
        XCTAssertTrue(viewModel.availableModels.contains(.anthropicCustom(name: "claude-future-1")))
        XCTAssertFalse(viewModel.availableModels.contains(.claudeCodeModel(specifier: "claude-future-1")))
    }

    @MainActor
    func testReloadingRotatedAnthropicKeyReplacesPriorCatalogModels() async throws {
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: "first-key"])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let loader = KeyedAnthropicModelsLoaderProbe(modelIDsByKey: [
            "first-key": ["claude-first-private"],
            "second-key": ["claude-second-private"]
        ])
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: APIModelCatalog(),
            anthropicModelsLoader: { key in
                await loader.load(key: key)
            }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        try await waitUntil {
            viewModel.availableAnthropicModels == ["claude-first-private"]
        }

        try await keyManager.saveAPIKey("second-key", for: .anthropic)
        await viewModel.loadAllKeys(accessMode: .nonInteractive(reason: .test))
        try await waitUntil {
            viewModel.availableAnthropicModels == ["claude-second-private"]
        }

        XCTAssertFalse(viewModel.availableModels.contains(.anthropicCustom(name: "claude-first-private")))
        XCTAssertTrue(viewModel.availableModels.contains(.anthropicCustom(name: "claude-second-private")))
        let loadedKeys = await loader.loadedKeys()
        XCTAssertEqual(loadedKeys, ["first-key", "second-key"])
    }

    @MainActor
    func testDeletingOpenAIKeyClearsDiscoveredModelState() async throws {
        let secureStorage = TestSecureStorageBackend(values: [.openAIAPI: "openai-key"])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: APIModelCatalog()
        )
        defer { viewModel.prepareForWindowClose() }
        viewModel.openAIApiKey = "openai-key"
        viewModel.isOpenAIKeyValid = true
        viewModel.availableOpenAIModels = ["gpt-private"]

        try await viewModel.deleteKey(for: .openAI)

        XCTAssertEqual(viewModel.openAIApiKey, "")
        XCTAssertFalse(viewModel.isOpenAIKeyValid)
        XCTAssertEqual(viewModel.availableOpenAIModels, [])
        XCTAssertEqual(viewModel.availableOpenAIModelMetadata, [])
        XCTAssertNil(secureStorage.value(for: .openAIAPI))
    }

    func testFetchUsesAnthropicHeadersAndModelsEndpoint() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: page(ids: ["claude-opus-5"], lastID: "claude-opus-5", hasMore: false), statusCode: 200)
        ])
        let client = AnthropicAPIModelsClient(
            apiKey: "test-anthropic-key",
            transport: transport
        )

        let modelIDs = try await client.fetchModelIDs()
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        let requestURL = try XCTUnwrap(request.url)
        let queryItems = try XCTUnwrap(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(modelIDs, ["claude-opus-5"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "1000")
        XCTAssertNil(queryItems.first(where: { $0.name == "after_id" }))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-anthropic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testFetchPaginatesUsingLastIDAsAfterID() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: page(ids: ["claude-first"], lastID: "cursor-one", hasMore: true), statusCode: 200),
            .init(data: page(ids: ["claude-second"], lastID: "cursor-two", hasMore: false), statusCode: 200)
        ])
        let client = AnthropicAPIModelsClient(apiKey: "test-key", transport: transport)

        let modelIDs = try await client.fetchModelIDs()
        let requests = await transport.capturedRequests()
        let secondRequest = try XCTUnwrap(requests.dropFirst().first)
        let secondRequestURL = try XCTUnwrap(secondRequest.url)
        let queryItems = try XCTUnwrap(
            URLComponents(url: secondRequestURL, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(modelIDs, ["claude-first", "claude-second"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_id" })?.value, "cursor-one")
    }

    func testFetchRejectsMissingPaginationCursor() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: page(ids: ["claude-first"], lastID: nil, hasMore: true), statusCode: 200)
        ])
        let client = AnthropicAPIModelsClient(apiKey: "test-key", transport: transport)

        do {
            _ = try await client.fetchModelIDs()
            XCTFail("Expected a missing cursor error")
        } catch {
            XCTAssertEqual(error as? AnthropicAPIModelsClientError, .missingPaginationCursor)
        }
    }

    func testFetchRejectsRepeatedPaginationCursor() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: page(ids: ["claude-first"], lastID: "same-cursor", hasMore: true), statusCode: 200),
            .init(data: page(ids: ["claude-second"], lastID: "same-cursor", hasMore: true), statusCode: 200)
        ])
        let client = AnthropicAPIModelsClient(apiKey: "test-key", transport: transport)

        do {
            _ = try await client.fetchModelIDs()
            XCTFail("Expected a repeated cursor error")
        } catch {
            XCTAssertEqual(
                error as? AnthropicAPIModelsClientError,
                .repeatedPaginationCursor("same-cursor")
            )
        }
    }

    func testFetchStopsAtConfiguredPageLimit() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: page(ids: ["claude-first"], lastID: "cursor-one", hasMore: true), statusCode: 200)
        ])
        let client = AnthropicAPIModelsClient(
            apiKey: "test-key",
            maximumPageCount: 1,
            transport: transport
        )

        do {
            _ = try await client.fetchModelIDs()
            XCTFail("Expected a page limit error")
        } catch {
            XCTAssertEqual(error as? AnthropicAPIModelsClientError, .pageLimitExceeded(1))
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testFetchRejectsNonSuccessHTTPStatus() async throws {
        let transport = AnthropicAPIModelsTransportSpy(stubs: [
            .init(data: Data("{}".utf8), statusCode: 401)
        ])
        let client = AnthropicAPIModelsClient(apiKey: "bad-key", transport: transport)

        do {
            _ = try await client.fetchModelIDs()
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? AnthropicAPIModelsClientError, .httpStatus(401))
        }
    }

    func testDiscoveredModelsDedupeKnownModelsAndPreserveUnknownAPIIDs() {
        let models = AnthropicDiscoveredModelCatalog.models(from: [
            "claude-opus-5",
            "claude-opus-5",
            " claude-future-1 ",
            "claude-future-1-thinking",
            "claude-future-1-thinking-max"
        ])
        let unknown = AIModel.anthropicCustom(name: "claude-future-1")

        XCTAssertEqual(models, [.claude5Opus, unknown])
        XCTAssertEqual(unknown.rawValue, "anthropic_custom_claude-future-1")
        XCTAssertEqual(AIModel.fromModelName(unknown.rawValue), unknown)
        XCTAssertEqual(unknown.providerType, .anthropic)
        XCTAssertNil(unknown.claudeCodeRuntimeSpecifierRaw)
    }

    private func page(ids: [String], lastID: String?, hasMore: Bool) -> Data {
        let models = ids.map { ["id": $0, "type": "model", "display_name": $0, "created_at": "2026-01-01T00:00:00Z"] }
        let object: [String: Any] = [
            "data": models,
            "first_id": ids.first.map { $0 as Any } ?? NSNull(),
            "last_id": lastID.map { $0 as Any } ?? NSNull(),
            "has_more": hasMore
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for Anthropic model discovery")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum AnthropicAPIModelsTransportSpyError: Error {
    case unexpectedRequest
}

private actor AnthropicAPIModelsTransportSpy: AnthropicAPIModelsTransport {
    struct Stub {
        let data: Data
        let statusCode: Int
    }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func response(for request: URLRequest) async throws -> AnthropicAPIModelsTransportResponse {
        requests.append(request)
        guard !stubs.isEmpty else { throw AnthropicAPIModelsTransportSpyError.unexpectedRequest }
        let stub = stubs.removeFirst()
        return AnthropicAPIModelsTransportResponse(data: stub.data, statusCode: stub.statusCode)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private actor AnthropicModelsLoaderProbe {
    private let modelIDs: [String]
    private var keys: [String] = []

    init(modelIDs: [String]) {
        self.modelIDs = modelIDs
    }

    func load(key: String) -> [String] {
        keys.append(key)
        return modelIDs
    }

    func loadedKeys() -> [String] {
        keys
    }
}

private actor KeyedAnthropicModelsLoaderProbe {
    private let modelIDsByKey: [String: [String]]
    private var keys: [String] = []

    init(modelIDsByKey: [String: [String]]) {
        self.modelIDsByKey = modelIDsByKey
    }

    func load(key: String) -> [String] {
        keys.append(key)
        return modelIDsByKey[key] ?? []
    }

    func loadedKeys() -> [String] {
        keys
    }
}
