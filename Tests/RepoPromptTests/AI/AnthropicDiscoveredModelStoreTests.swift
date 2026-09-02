import Foundation
@testable import RepoPromptApp
import XCTest

final class AnthropicDiscoveredModelStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AnthropicDiscoveredModelStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSynchronousHydrationReplacementAndMonotoneRevision() {
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let firstModels = [model("claude-first")]
        let store = AnthropicDiscoveredModelStore(defaults: defaults)

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.revision, 0)
        XCTAssertTrue(store.replace(with: firstModels, fetchedAt: firstDate))
        XCTAssertEqual(store.snapshot, .init(fetchedAt: firstDate, models: firstModels))
        XCTAssertEqual(store.revision, 1)

        XCTAssertTrue(store.replace(with: firstModels, fetchedAt: secondDate))
        XCTAssertEqual(store.snapshot, .init(fetchedAt: secondDate, models: firstModels))
        XCTAssertEqual(store.revision, 1)

        let hydrated = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertEqual(hydrated.snapshot, .init(fetchedAt: secondDate, models: firstModels))
        XCTAssertEqual(hydrated.revision, 1)

        XCTAssertTrue(hydrated.replace(with: [model("claude-second")], fetchedAt: secondDate))
        XCTAssertEqual(hydrated.models.map(\.id), ["claude-second"])
        XCTAssertEqual(hydrated.revision, 2)
    }

    func testInvalidWholeReplacementRetainsLastGoodCatalogAndBytes() throws {
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertTrue(store.replace(with: [model("claude-good")]))
        let originalData = try XCTUnwrap(defaults.data(
            forKey: AnthropicDiscoveredModelStore.storageKey
        ))
        let originalSnapshot = try XCTUnwrap(store.snapshot)
        let originalRevision = store.revision

        XCTAssertFalse(store.replace(with: [
            model("claude-new"),
            AnthropicDiscoveredModel(id: "   ")
        ]))

        XCTAssertEqual(store.snapshot, originalSnapshot)
        XCTAssertEqual(store.revision, originalRevision)
        XCTAssertEqual(
            defaults.data(forKey: AnthropicDiscoveredModelStore.storageKey),
            originalData
        )
    }

    func testCorruptAndFutureVersionBytesAreIgnoredAndPreserved() throws {
        let future = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "fetchedAt": 0,
            "models": []
        ])

        for bytes in [Data("{not-json".utf8), future] {
            defaults.set(bytes, forKey: AnthropicDiscoveredModelStore.storageKey)
            let store = AnthropicDiscoveredModelStore(defaults: defaults)

            XCTAssertNil(store.snapshot)
            XCTAssertEqual(
                defaults.data(forKey: AnthropicDiscoveredModelStore.storageKey),
                bytes
            )
        }
    }

    func testValidEmptyResponseAuthoritativelyClearsCatalog() {
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertTrue(store.replace(with: [model("claude-present")]))
        let priorRevision = store.revision
        let fetchedAt = Date(timeIntervalSince1970: 500)

        XCTAssertTrue(store.replace(with: [], fetchedAt: fetchedAt))

        XCTAssertEqual(store.snapshot, .init(fetchedAt: fetchedAt, models: []))
        XCTAssertEqual(store.revision, priorRevision + 1)
        let hydrated = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertEqual(hydrated.snapshot, .init(fetchedAt: fetchedAt, models: []))
    }

    @MainActor
    func testCommittedDataChangePostsNotificationOnMainQueueOnly() async {
        let notificationCenter = NotificationCenter()
        let store = AnthropicDiscoveredModelStore(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let notification = expectation(description: "Anthropic store changed")
        notification.expectedFulfillmentCount = 1
        let token = notificationCenter.addObserver(
            forName: .anthropicDiscoveredModelStoreDidChange,
            object: store,
            queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            notification.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        await Task.detached {
            XCTAssertTrue(store.replace(with: [AnthropicDiscoveredModel(id: "claude-first")]))
            XCTAssertTrue(store.replace(with: [AnthropicDiscoveredModel(id: "claude-first")]))
        }.value

        await fulfillment(of: [notification], timeout: 2)
        XCTAssertEqual(store.revision, 1)
    }

    @MainActor
    func testTransientAnthropicRefreshFailureRetainsLastGoodDescriptorStore() async throws {
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: "test-key"])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertTrue(store.replace(with: [model("claude-retained")]))
        let loader = FailingAnthropicDescriptorLoaderProbe()
        let catalog = APIModelCatalog()
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: catalog,
            anthropicDiscoveredModelStore: store,
            anthropicModelsLoader: { key in try await loader.load(key) }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await loader.waitUntilCalled()
        let scope = try XCTUnwrap(APIModelCatalogScope(
            providerID: "anthropic",
            endpoint: "https://api.anthropic.com/v1",
            apiKey: "test-key"
        ))
        let completion = Task {
            await catalog.refresh(for: scope, payloadLoader: { _ in
                APIModelCatalogRefreshPayload(modelIDs: ["unexpected"])
            })
        }
        await Task.yield()
        await loader.fail()
        _ = await completion.value

        XCTAssertEqual(store.models.map(\.id), ["claude-retained"])
        XCTAssertEqual(store.revision, 1)
    }

    @MainActor
    func testSameScopeCoalescedRefreshRetainsDescriptorCommitAuthorization() async throws {
        let apiKey = "same-key"
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: apiKey])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let catalog = APIModelCatalog()
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        let loader = SameKeyCoalescingAnthropicLoaderProbe(
            models: [model("claude-current")]
        )
        let snapshotsGate = AnthropicSnapshotsCreatedGate()
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: catalog,
            anthropicDiscoveredModelStore: store,
            anthropicModelsLoader: { key in await loader.load(key: key) },
            anthropicModelsSnapshotsCreatedBoundary: {
                await snapshotsGate.reachBoundary()
            }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await loader.waitUntilFirstLoadStarts()

        viewModel.anthropicApiKey = " \(apiKey) "
        let validation = Task { @MainActor in
            try await viewModel.validateAndSaveKey(
                key: apiKey,
                for: .anthropic,
                validationFunc: { true }
            )
        }
        while viewModel.anthropicApiKey != apiKey {
            await Task.yield()
        }
        await snapshotsGate.waitUntilSecondBoundary()
        await Task.yield()
        await loader.completeFirstLoad()
        await snapshotsGate.releaseSecondBoundary()

        let validationResult = try await validation.value
        let loadCount = await loader.loadCount
        XCTAssertTrue(validationResult)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(store.models.map(\.id), ["claude-current"])
        XCTAssertEqual(viewModel.availableAnthropicModels, ["claude-current"])
    }

    @MainActor
    func testFailedThenSuccessfulSameKeyValidationPreservesCoalescedDescriptorCommit() async throws {
        let apiKey = "retry-key"
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: apiKey])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let catalog = APIModelCatalog()
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        let loader = SameKeyCoalescingAnthropicLoaderProbe(
            models: [model("claude-retried")]
        )
        let validationProbe = SequencedAnthropicKeyValidationProbe(results: [false, true])
        let snapshotsGate = AnthropicSnapshotsCreatedGate()
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: catalog,
            anthropicDiscoveredModelStore: store,
            anthropicModelsLoader: { key in await loader.load(key: key) },
            anthropicKeyValidationOperation: { key in
                await validationProbe.validate(key: key)
            },
            anthropicModelsSnapshotsCreatedBoundary: {
                await snapshotsGate.reachBoundary()
            }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await loader.waitUntilFirstLoadStarts()

        let firstValidationResult = try await viewModel.validateAnthropicKey()
        XCTAssertFalse(firstValidationResult)
        XCTAssertFalse(viewModel.isAnthropicKeyValid)

        let retry = Task { @MainActor in
            try await viewModel.validateAnthropicKey()
        }
        await snapshotsGate.waitUntilSecondBoundary()
        await Task.yield()
        await loader.completeFirstLoad()
        await snapshotsGate.releaseSecondBoundary()

        let retryResult = try await retry.value
        let loadCount = await loader.loadCount
        let validatedKeys = await validationProbe.validatedKeys
        XCTAssertTrue(retryResult)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(validatedKeys, [apiKey, apiKey])
        XCTAssertEqual(store.models.map(\.id), ["claude-retried"])
        XCTAssertEqual(viewModel.availableAnthropicModels, ["claude-retried"])
    }

    @MainActor
    func testRotatedAnthropicRequestCannotCommitOldDescriptorsAfterDelayedCacheLoad() async throws {
        let oldKey = "old-key"
        let newKey = "new-key"
        let oldScope = try XCTUnwrap(APIModelCatalogScope(
            providerID: "anthropic",
            endpoint: "https://api.anthropic.com/v1",
            apiKey: oldKey
        ))
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: oldKey])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let storage = DelayedScopeAPIModelCatalogStorage(delayedScope: oldScope)
        let catalog = APIModelCatalog(storage: storage)
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        let loader = RotatingAnthropicDescriptorLoaderProbe(
            oldKey: oldKey,
            oldModels: [model("claude-old")],
            newModels: [model("claude-new")]
        )
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: catalog,
            anthropicDiscoveredModelStore: store,
            anthropicModelsLoader: { key in await loader.load(key: key) }
        )
        defer { viewModel.prepareForWindowClose() }

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await storage.waitUntilDelayedLoadStarts()

        _ = try await viewModel.validateAndSaveKey(
            key: newKey,
            for: .anthropic,
            validationFunc: { true }
        )
        XCTAssertEqual(store.models.map(\.id), ["claude-new"])

        await storage.completeDelayedLoad()
        await loader.waitUntilOldLoadStarts()
        let oldRefreshCompletion = Task {
            await catalog.refresh(for: oldScope, payloadLoader: { _ in
                APIModelCatalogRefreshPayload(modelIDs: ["unexpected"])
            })
        }
        await Task.yield()
        await loader.completeOldLoad()
        _ = await oldRefreshCompletion.value

        XCTAssertEqual(store.models.map(\.id), ["claude-new"])
        XCTAssertEqual(viewModel.availableAnthropicModels, ["claude-new"])
    }

    @MainActor
    func testDeletingAnthropicKeyDoesNotClearDescriptorStore() async throws {
        let secureStorage = TestSecureStorageBackend(values: [.anthropicAPI: "test-key"])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let store = AnthropicDiscoveredModelStore(defaults: defaults)
        XCTAssertTrue(store.replace(with: [model("claude-retained")]))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            apiModelCatalog: APIModelCatalog(),
            anthropicDiscoveredModelStore: store,
            anthropicModelsLoader: { _ in [] }
        )
        defer { viewModel.prepareForWindowClose() }
        viewModel.anthropicApiKey = "test-key"
        viewModel.isAnthropicKeyValid = true

        try await viewModel.deleteKey(for: .anthropic)

        XCTAssertEqual(store.models.map(\.id), ["claude-retained"])
        XCTAssertEqual(viewModel.availableAnthropicModels, [])
        XCTAssertNil(secureStorage.value(for: .anthropicAPI))
    }

    private func model(_ id: String) -> AnthropicDiscoveredModel {
        AnthropicDiscoveredModel(
            id: id,
            displayName: id,
            maxInputTokens: 1_000_000,
            maxOutputTokens: 128_000,
            capabilities: .object(["thinking": .bool(true)])
        )
    }
}

private enum AnthropicDescriptorLoaderTestError: Error {
    case failed
}

private actor FailingAnthropicDescriptorLoaderProbe {
    private var wasCalled = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    func load(_ key: String) async throws -> [AnthropicDiscoveredModel] {
        wasCalled = true
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()
        await withCheckedContinuation { failureContinuation = $0 }
        throw AnthropicDescriptorLoaderTestError.failed
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }

    func fail() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}

private actor DelayedScopeAPIModelCatalogStorage: APIModelCatalogStorage {
    private let delayedScope: APIModelCatalogScope
    private var delayedLoadContinuation: CheckedContinuation<Void, Never>?
    private var delayedLoadStarted = false
    private var delayedLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshots: [APIModelCatalogScope: APIModelCatalogSnapshot] = [:]

    init(delayedScope: APIModelCatalogScope) {
        self.delayedScope = delayedScope
    }

    func load(for scope: APIModelCatalogScope) async throws -> APIModelCatalogSnapshot? {
        if scope == delayedScope {
            delayedLoadStarted = true
            delayedLoadWaiters.forEach { $0.resume() }
            delayedLoadWaiters.removeAll()
            await withCheckedContinuation { delayedLoadContinuation = $0 }
        }
        return snapshots[scope]
    }

    func save(_ snapshot: APIModelCatalogSnapshot) async throws {
        snapshots[snapshot.scope] = snapshot
    }

    func remove(for scope: APIModelCatalogScope) async throws {
        snapshots.removeValue(forKey: scope)
    }

    func waitUntilDelayedLoadStarts() async {
        guard !delayedLoadStarted else { return }
        await withCheckedContinuation { delayedLoadWaiters.append($0) }
    }

    func completeDelayedLoad() {
        delayedLoadContinuation?.resume()
        delayedLoadContinuation = nil
    }
}

private actor SequencedAnthropicKeyValidationProbe {
    private var results: [Bool]
    private(set) var validatedKeys: [String] = []

    init(results: [Bool]) {
        self.results = results
    }

    func validate(key: String) -> Bool {
        validatedKeys.append(key)
        return results.removeFirst()
    }
}

private actor AnthropicSnapshotsCreatedGate {
    private var callCount = 0
    private var secondBoundaryContinuation: CheckedContinuation<Void, Never>?
    private var secondBoundaryReached = false
    private var secondBoundaryWaiters: [CheckedContinuation<Void, Never>] = []

    func reachBoundary() async {
        callCount += 1
        guard callCount == 2 else { return }
        secondBoundaryReached = true
        secondBoundaryWaiters.forEach { $0.resume() }
        secondBoundaryWaiters.removeAll()
        await withCheckedContinuation { secondBoundaryContinuation = $0 }
    }

    func waitUntilSecondBoundary() async {
        guard !secondBoundaryReached else { return }
        await withCheckedContinuation { secondBoundaryWaiters.append($0) }
    }

    func releaseSecondBoundary() {
        secondBoundaryContinuation?.resume()
        secondBoundaryContinuation = nil
    }
}

private actor SameKeyCoalescingAnthropicLoaderProbe {
    private let models: [AnthropicDiscoveredModel]
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var firstLoadStarted = false
    private var firstLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadCount = 0

    init(models: [AnthropicDiscoveredModel]) {
        self.models = models
    }

    func load(key: String) async -> [AnthropicDiscoveredModel] {
        loadCount += 1
        guard loadCount == 1 else { return models }
        firstLoadStarted = true
        firstLoadWaiters.forEach { $0.resume() }
        firstLoadWaiters.removeAll()
        await withCheckedContinuation { firstLoadContinuation = $0 }
        return models
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { firstLoadWaiters.append($0) }
    }

    func completeFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }
}

private actor RotatingAnthropicDescriptorLoaderProbe {
    private let oldKey: String
    private let oldModels: [AnthropicDiscoveredModel]
    private let newModels: [AnthropicDiscoveredModel]
    private var oldLoadContinuation: CheckedContinuation<Void, Never>?
    private var oldLoadStarted = false
    private var oldLoadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        oldKey: String,
        oldModels: [AnthropicDiscoveredModel],
        newModels: [AnthropicDiscoveredModel]
    ) {
        self.oldKey = oldKey
        self.oldModels = oldModels
        self.newModels = newModels
    }

    func load(key: String) async -> [AnthropicDiscoveredModel] {
        guard key == oldKey else { return newModels }
        oldLoadStarted = true
        oldLoadWaiters.forEach { $0.resume() }
        oldLoadWaiters.removeAll()
        await withCheckedContinuation { oldLoadContinuation = $0 }
        return oldModels
    }

    func waitUntilOldLoadStarts() async {
        guard !oldLoadStarted else { return }
        await withCheckedContinuation { oldLoadWaiters.append($0) }
    }

    func completeOldLoad() {
        oldLoadContinuation?.resume()
        oldLoadContinuation = nil
    }
}
