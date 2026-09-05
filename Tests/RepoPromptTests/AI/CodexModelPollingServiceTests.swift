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

        let initialKnownBaseCount = knownRegistry.entries().count
        await service.refreshNow()
        let first = await service.latestSnapshot()
        let firstStatus = await service.latestCatalogStatus()
        XCTAssertEqual(first?.models, [model])
        XCTAssertEqual(firstStatus?.modelCount, 1)
        XCTAssertEqual(firstStatus?.knownBaseCount, initialKnownBaseCount + 1)
        XCTAssertNil(firstStatus?.lastPollError)
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
        let currentZeroStatus = await service.latestCatalogStatus()
        let zeroStatus = try XCTUnwrap(currentZeroStatus)
        XCTAssertEqual(zeroStatus.modelCount, 0)
        XCTAssertNotNil(zeroStatus.fetchedAt)
        XCTAssertNil(zeroStatus.lastPollError)
        XCTAssertEqual(registry.currentLiveModels(), [model])
        XCTAssertNotNil(knownRegistry.capabilitySnapshot().capability(forBase: model.id))

        await service.refreshNow()
        guard case let .failure(message, _) = await service.lastPollOutcome() else {
            return XCTFail("Expected an observable failure outcome")
        }
        XCTAssertEqual(message, "offline")
        let currentFailureStatus = await service.latestCatalogStatus()
        let failureStatus = try XCTUnwrap(currentFailureStatus)
        XCTAssertEqual(failureStatus.modelCount, zeroStatus.modelCount)
        XCTAssertEqual(failureStatus.fetchedAt, zeroStatus.fetchedAt)
        XCTAssertEqual(failureStatus.lastPollError, "offline")

        let freshStream = await service.subscribeToCatalogStatus()
        var freshIterator = freshStream.makeAsyncIterator()
        let freshStatus = await freshIterator.next()
        XCTAssertEqual(freshStatus, failureStatus)

        let afterFailure = await service.latestSnapshot()
        XCTAssertEqual(afterFailure, first)
        XCTAssertEqual(registry.currentLiveModels(), [model])
        await service.shutdown()
    }

    func testFreshCatalogStatusSubscriberRetainsSuccessStateAfterFailure() async throws {
        let model = CodexAppServerClient.RemoteModel(
            id: "status-model",
            model: "status-model",
            displayName: "Status",
            description: "",
            isDefault: true
        )
        let client = PollingClientSpy(responses: [.models([model]), .failure("offline")])
        let service = CodexModelPollingService(client: client)

        await service.refreshNow()
        let currentSuccess = await service.latestCatalogStatus()
        let success = try XCTUnwrap(currentSuccess)
        await service.refreshNow()
        let currentFailure = await service.latestCatalogStatus()
        let failure = try XCTUnwrap(currentFailure)

        XCTAssertEqual(failure.modelCount, success.modelCount)
        XCTAssertEqual(failure.fetchedAt, success.fetchedAt)
        XCTAssertEqual(failure.lastPollError, "offline")

        let stream = await service.subscribeToCatalogStatus()
        var iterator = stream.makeAsyncIterator()
        let initialStatus = await iterator.next()
        XCTAssertEqual(initialStatus, failure)
        await service.shutdown()
    }

    func testCancellationDoesNotPublishFailureAndRetainsPriorStatus() async throws {
        let model = CodexAppServerClient.RemoteModel(
            id: "cancel-model",
            model: "cancel-model",
            displayName: "Cancel",
            description: "",
            isDefault: true
        )
        let client = PollingClientSpy(responses: [.models([model]), .cancellation])
        let service = CodexModelPollingService(client: client)

        await service.refreshNow()
        let currentPriorStatus = await service.latestCatalogStatus()
        let priorStatus = try XCTUnwrap(currentPriorStatus)
        let priorOutcome = await service.lastPollOutcome()
        await service.refreshNow()

        let retainedStatus = await service.latestCatalogStatus()
        let retainedOutcome = await service.lastPollOutcome()
        XCTAssertEqual(retainedStatus, priorStatus)
        XCTAssertEqual(retainedOutcome, priorOutcome)
        XCTAssertNil(retainedStatus?.lastPollError)
        await service.shutdown()
    }

    func testOutcomeStreamPublishesSuccessIncludingZeroAndFailure() async {
        let client = PollingClientSpy(responses: [.models([]), .failure("offline")])
        let service = CodexModelPollingService(client: client)
        let stream = await service.subscribeToOutcomes()
        var iterator = stream.makeAsyncIterator()

        await service.refreshNow()
        guard case let .success(modelCount, _) = await iterator.next() else {
            return XCTFail("Expected success outcome")
        }
        XCTAssertEqual(modelCount, 0)

        await service.refreshNow()
        guard case let .failure(message, _) = await iterator.next() else {
            return XCTFail("Expected failure outcome")
        }
        XCTAssertEqual(message, "offline")
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
        case cancellation
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
        case .cancellation:
            throw CancellationError()
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
