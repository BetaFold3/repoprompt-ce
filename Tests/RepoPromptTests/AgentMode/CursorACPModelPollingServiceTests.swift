import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CursorACPModelPollingServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor))
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor))
        super.tearDown()
    }

    func testFailureClassifierCoversAuthenticationTimeoutDiscoveryAndExtension() {
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                URLError(.userAuthenticationRequired),
                stage: .discovery
            ),
            .authentication
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                TestError("token expired"),
                stage: .extension
            ),
            .authentication
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                URLError(.timedOut),
                stage: .extension
            ),
            .timeout
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                TestError("launch failed"),
                stage: .discovery
            ),
            .discovery
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                TestError("login shell capture failed"),
                stage: .discovery
            ),
            .discovery
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                TestError("login required"),
                stage: .discovery
            ),
            .authentication
        )
        XCTAssertEqual(
            CursorACPModelFailureClassifier.classify(
                TestError("provider extension failed"),
                stage: .extension
            ),
            .extension
        )
    }

    func testFailuresRetainCatalogAndRecordEveryStaleKind() async {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let retained = catalog.currentSnapshot()
        let outcomes: [CursorACPModelDiscoveryOutcome] = [
            .failed(.authentication),
            .completed(models: models(), parameterRefresh: .stale(.timeout)),
            .completed(models: models(), parameterRefresh: .stale(.malformedResponse)),
            .completed(models: models(), parameterRefresh: .stale(.extension)),
            .failed(.discovery)
        ]
        let client = ScriptedCursorDiscoveryClient(
            outcomes: outcomes,
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let expectedKinds: [CursorModelParameterCatalog.FailureKind] = [
            .authentication,
            .timeout,
            .malformedResponse,
            .extension,
            .discovery
        ]
        for expectedKind in expectedKinds {
            _ = await service.refreshNow(workspacePath: nil)
            XCTAssertEqual(catalog.currentSnapshot(), retained)
            XCTAssertEqual(catalog.status().state, .stale(expectedKind))
        }
    }

    func testMalformedApplyResultRetainsCatalogAndBecomesMalformedOutcome() async {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let retained = catalog.currentSnapshot()
        let client = MalformedApplyingCursorDiscoveryClient(catalog: catalog)
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let refreshed = await service.refreshNow(workspacePath: nil)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(catalog.currentSnapshot(), retained)
        XCTAssertEqual(catalog.status().state, .stale(.malformedResponse))
    }

    func testMethodNotFoundAuthoritativelyClearsCatalog() async {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let client = ScriptedCursorDiscoveryClient(
            outcomes: [
                .completed(models: models(), parameterRefresh: .unsupported)
            ],
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let refreshed = await service.refreshNow(workspacePath: nil)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
        XCTAssertEqual(catalog.status().state, .unsupported)
    }

    func testValidEmptyResponseAuthoritativelyClearsCatalogAndIsLive() async {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let client = ValidEmptyApplyingCursorDiscoveryClient(catalog: catalog)
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let refreshed = await service.refreshNow(workspacePath: nil)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
        XCTAssertEqual(catalog.status().state, .live)
    }

    func testDisabledOutcomeRecordsDisabledWithoutClearingCatalog() async {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let retained = catalog.currentSnapshot()
        let client = ScriptedCursorDiscoveryClient(
            outcomes: [
                .completed(models: models(), parameterRefresh: .disabled)
            ],
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let refreshed = await service.refreshNow(workspacePath: nil)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(catalog.currentSnapshot(), retained)
        XCTAssertEqual(catalog.status().state, .disabled)
    }

    func testBackoffSequenceCapsAndResetsAfterLiveRefresh() async {
        let catalog = makeCatalog()
        let failures = Array(repeating: CursorACPModelDiscoveryOutcome.failed(.discovery), count: 5)
        let client = ScriptedCursorDiscoveryClient(
            outcomes: failures + [
                .completed(models: models(), parameterRefresh: .live)
            ],
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(
            client: client,
            intervalNanos: 1000,
            retryBaseNanos: 10,
            retryMaximumNanos: 80
        )
        addTeardownBlock { await service.shutdown() }

        var delays: [UInt64] = []
        for _ in 0 ..< 5 {
            let refreshed = await service.refreshNow(workspacePath: nil)
            XCTAssertFalse(refreshed)
            await delays.append(service.test_nextPollingDelayNanos())
        }
        XCTAssertEqual(delays, [10, 20, 40, 80, 80])
        let failedStreak = await service.test_pollingFailureStreak()
        XCTAssertEqual(failedStreak, 5)

        let refreshed = await service.refreshNow(workspacePath: nil)
        let resetStreak = await service.test_pollingFailureStreak()
        let regularDelay = await service.test_nextPollingDelayNanos()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(resetStreak, 0)
        XCTAssertEqual(regularDelay, 1000)
    }

    func testBareModelsPublishWhenParameterExtensionFails() async throws {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let discovered = models(rawValue: "cursor-live-model")
        let client = ScriptedCursorDiscoveryClient(
            outcomes: [
                .completed(models: discovered, parameterRefresh: .stale(.extension))
            ],
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }

        let refreshed = await service.refreshNow(workspacePath: nil)
        let latest = await service.latestSnapshot()
        XCTAssertTrue(refreshed)
        let snapshot = try XCTUnwrap(latest)
        XCTAssertEqual(snapshot.models, discovered)
        XCTAssertTrue(snapshot.isLiveDiscovery)
        XCTAssertEqual(catalog.status().state, .stale(.extension))
    }

    func testShutdownCancellationDoesNotRecordFailureStatus() async throws {
        let catalog = makeCatalog()
        seedCatalog(catalog)
        let client = CancellingCursorDiscoveryClient(parameterCatalog: catalog)
        let service = CursorACPModelPollingService(client: client)
        let started = await client.startedEvents()

        async let refresh = service.refreshNow(workspacePath: nil)
        await awaitFirst(started)
        await service.shutdown()
        let refreshResult = await refresh
        XCTAssertFalse(refreshResult)
        XCTAssertEqual(catalog.status().state, .idle)
        XCTAssertTrue(catalog.status().hasUsableCatalog)
        let failureStreak = await service.test_pollingFailureStreak()
        XCTAssertEqual(failureStreak, 0)

        let directCatalog = makeCatalog()
        seedCatalog(directCatalog)
        let directClient = GatedCursorPollingDiscoveryClient(
            outcome: .completed(models: models(rawValue: "late-model"), parameterRefresh: .live),
            parameterCatalog: directCatalog
        )
        let directService = CursorACPModelPollingService(client: directClient)
        let directStarted = await directClient.startedEvents()

        async let directResult = directService.discoverOnce(workspacePath: nil)
        await awaitFirst(directStarted)
        await directService.shutdown()
        await directClient.release()

        let result = try await directResult
        XCTAssertNil(result)
        XCTAssertEqual(directCatalog.status().state, .idle)
        XCTAssertTrue(directCatalog.status().hasUsableCatalog)
        let directFailureStreak = await directService.test_pollingFailureStreak()
        XCTAssertEqual(directFailureStreak, 0)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor))
    }

    func testRefreshNowCoalescesWithInFlightRefresh() async {
        let catalog = makeCatalog()
        let client = GatedCursorPollingDiscoveryClient(
            outcome: .completed(models: models(), parameterRefresh: .live),
            parameterCatalog: catalog
        )
        let service = CursorACPModelPollingService(client: client)
        addTeardownBlock { await service.shutdown() }
        let started = await client.startedEvents()

        async let first = service.refreshNow(workspacePath: nil)
        await awaitFirst(started)
        async let second = service.refreshNow(workspacePath: nil)
        await Task.yield()
        await client.release()

        let firstResult = await first
        let secondResult = await second
        let calls = await client.callCount()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(calls, 1)
    }

    private func makeCatalog() -> CursorModelParameterCatalog {
        let suiteName = "CursorACPModelPollingServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return CursorModelParameterCatalog(
            store: CursorModelParameterStore(defaults: defaults),
            notificationCenter: NotificationCenter()
        )
    }

    private func seedCatalog(_ catalog: CursorModelParameterCatalog) {
        let result: CursorModelParameterCatalog.ApplyResult = catalog.apply(response: [
            "models": [[
                "value": "seed-model",
                "configOptions": [[
                    "id": "reasoning",
                    "category": "thought_level",
                    "type": "select",
                    "currentValue": "medium",
                    "options": [
                        ["value": "medium", "name": "Medium"],
                        ["value": "high", "name": "High"]
                    ]
                ]]
            ]]
        ])
        XCTAssertEqual(result, .applied(didChange: true))
    }

    fileprivate static func models(rawValue: String = "bare-model") -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: rawValue,
                displayName: rawValue,
                description: nil,
                isDefault: true
            )],
            currentModelRaw: rawValue
        )
    }

    private func models(rawValue: String = "bare-model") -> ACPDiscoveredSessionModels {
        Self.models(rawValue: rawValue)
    }

    private func awaitFirst(_ stream: AsyncStream<Void>) async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private actor ScriptedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    nonisolated let parameterCatalog: CursorModelParameterCatalog
    private var outcomes: [CursorACPModelDiscoveryOutcome]

    init(
        outcomes: [CursorACPModelDiscoveryOutcome],
        parameterCatalog: CursorModelParameterCatalog
    ) {
        self.outcomes = outcomes
        self.parameterCatalog = parameterCatalog
    }

    func discoverModels(workspacePath _: String?) async -> CursorACPModelDiscoveryOutcome {
        guard !outcomes.isEmpty else { return .failed(.discovery) }
        return outcomes.removeFirst()
    }
}

private struct MalformedApplyingCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    let catalog: CursorModelParameterCatalog

    var parameterCatalog: CursorModelParameterCatalog {
        catalog
    }

    func discoverModels(workspacePath _: String?) async -> CursorACPModelDiscoveryOutcome {
        let result: CursorModelParameterCatalog.ApplyResult = catalog.apply(response: ["models": "invalid"])
        let parameterRefresh: CursorACPParameterRefreshOutcome =
            result == .rejectedMalformed ? .stale(.malformedResponse) : .live
        return .completed(
            models: CursorACPModelPollingServiceTests.models(),
            parameterRefresh: parameterRefresh
        )
    }
}

private struct ValidEmptyApplyingCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    let catalog: CursorModelParameterCatalog

    var parameterCatalog: CursorModelParameterCatalog {
        catalog
    }

    func discoverModels(workspacePath _: String?) async -> CursorACPModelDiscoveryOutcome {
        let result: CursorModelParameterCatalog.ApplyResult = catalog.apply(response: ["models": []])
        guard case .applied = result else {
            return .completed(
                models: CursorACPModelPollingServiceTests.models(),
                parameterRefresh: .stale(.malformedResponse)
            )
        }
        return .completed(
            models: CursorACPModelPollingServiceTests.models(),
            parameterRefresh: .live
        )
    }
}

private actor CancellingCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    nonisolated let parameterCatalog: CursorModelParameterCatalog
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(parameterCatalog: CursorModelParameterCatalog) {
        self.parameterCatalog = parameterCatalog
    }

    func startedEvents() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        return stream
    }

    func discoverModels(workspacePath _: String?) async -> CursorACPModelDiscoveryOutcome {
        for observer in observers.values {
            observer.yield(())
        }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .failed(.discovery)
        } catch {
            return .cancelled
        }
    }
}

private actor GatedCursorPollingDiscoveryClient: CursorACPModelDiscoveryClient {
    nonisolated let parameterCatalog: CursorModelParameterCatalog
    private let outcome: CursorACPModelDiscoveryOutcome
    private var calls = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isReleased = false

    init(
        outcome: CursorACPModelDiscoveryOutcome,
        parameterCatalog: CursorModelParameterCatalog
    ) {
        self.outcome = outcome
        self.parameterCatalog = parameterCatalog
    }

    func startedEvents() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        return stream
    }

    func discoverModels(workspacePath _: String?) async -> CursorACPModelDiscoveryOutcome {
        calls += 1
        for observer in observers.values {
            observer.yield(())
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return outcome
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func callCount() -> Int {
        calls
    }
}
