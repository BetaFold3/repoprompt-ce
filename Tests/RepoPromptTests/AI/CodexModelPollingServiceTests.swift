@testable import RepoPromptApp
import XCTest

final class CodexModelPollingServiceTests: XCTestCase {
    func testLastSubscriberStopsOwnedClientAndLaterSubscriberRestartsPolling() async throws {
        let client = PollingClientSpy(responses: [.models([]), .models([])])
        let service = CodexModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000,
            stopClientOnShutdown: true,
            stopClientWhenIdle: true
        )

        let firstConsumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 1 }
        firstConsumer.cancel()
        await firstConsumer.value
        try await waitUntil { await client.stopCallCount >= 1 }

        let secondConsumer = await makeConsumer(service: service)
        try await waitUntil { await client.listCallCount >= 2 }
        secondConsumer.cancel()
        await secondConsumer.value
        try await waitUntil { await client.stopCallCount >= 2 }

        await service.shutdown()
    }

    func testZeroAndFailurePreserveLastGoodWhileOutcomeRemainsObservable() async throws {
        let suiteName = "CodexModelPollingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownRegistry = CodexKnownModelBaseRegistry(defaults: defaults)
        let registry = AgentCodexModelRegistry(
            defaults: defaults,
            knownModelBaseRegistry: knownRegistry
        )
        let model = CodexAppServerClient.RemoteModel(
            id: "gpt-daybreak-blue-latest",
            model: "gpt-daybreak-blue-latest",
            displayName: "Daybreak",
            description: "",
            isDefault: true,
            supportedReasoningEfforts: [.init(reasoningEffort: "ultra", description: "")]
        )
        let client = PollingClientSpy(responses: [
            .models([model]),
            .models([model]),
            .models([]),
            .failure("offline")
        ])
        let service = CodexModelPollingService(client: client, registry: registry)

        await service.refreshNow()
        let first = await service.latestSnapshot()
        XCTAssertEqual(first?.models, [model])
        XCTAssertNotNil(knownRegistry.capabilitySnapshot().capability(forBase: model.id))

        await service.refreshNow()
        let unchanged = await service.latestSnapshot()
        XCTAssertEqual(unchanged, first, "unchanged snapshots are not republished")

        await service.refreshNow()
        let afterZero = await service.latestSnapshot()
        XCTAssertEqual(afterZero, first)
        guard case let .success(modelCount, _) = await service.lastPollOutcome() else {
            return XCTFail("Expected an observable zero-model outcome")
        }
        XCTAssertEqual(modelCount, 0)
        XCTAssertEqual(registry.currentLiveModels(), [model])
        XCTAssertNotNil(knownRegistry.capabilitySnapshot().capability(forBase: model.id))

        await service.refreshNow()
        guard case let .failure(message, _) = await service.lastPollOutcome() else {
            return XCTFail("Expected an observable failure outcome")
        }
        XCTAssertEqual(message, "offline")
        let afterFailure = await service.latestSnapshot()
        XCTAssertEqual(afterFailure, first)
        XCTAssertEqual(registry.currentLiveModels(), [model])
        await service.shutdown()
    }

    private func makeConsumer(
        service: CodexModelPollingService
    ) async -> Task<Void, Never> {
        let stream = await service.subscribe()
        return Task {
            for await _ in stream {}
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor PollingClientSpy: CodexModelListingClient {
    enum Response {
        case models([CodexAppServerClient.RemoteModel])
        case failure(String)
    }

    private(set) var listCallCount = 0
    private(set) var stopCallCount = 0
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
        listCallCount += 1
        guard !responses.isEmpty else { return [] }
        switch responses.removeFirst() {
        case let .models(models):
            return models
        case let .failure(message):
            throw PollingError(message: message)
        }
    }

    func stop() async {
        stopCallCount += 1
    }
}

private struct PollingError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}
