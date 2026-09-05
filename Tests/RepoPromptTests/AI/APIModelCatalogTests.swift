import Foundation
@testable import RepoPromptApp
import XCTest

final class APIModelCatalogTests: XCTestCase {
    func testScopeNormalizesProviderEndpointAndFingerprintsKey() throws {
        let first = try XCTUnwrap(APIModelCatalogScope(
            providerID: " OpenAI ",
            endpoint: "HTTPS://API.OPENAI.COM:443/v1///",
            apiKey: " secret-key "
        ))
        let second = try XCTUnwrap(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://api.openai.com/v1",
            apiKey: "secret-key"
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.providerID, "openai")
        XCTAssertEqual(first.normalizedEndpoint, "https://api.openai.com/v1")
        XCTAssertEqual(first.keyFingerprint.count, 64)
        XCTAssertFalse(first.keyFingerprint.contains("secret-key"))
        XCTAssertNil(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://user:password@api.openai.com/v1",
            apiKey: "secret-key"
        ))
    }

    func testFileStoragePersistsScopesWithoutWritingRawAPIKeys() async throws {
        let firstScope = try makeScope()
        let secondScope = try XCTUnwrap(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://api.openai.com/v1",
            apiKey: "second-test-key"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = APIModelCatalogFileStorage(directoryURL: directory)
        let firstSnapshot = APIModelCatalogSnapshot(
            scope: firstScope,
            modelIDs: ["first"],
            refreshedAt: Date(timeIntervalSince1970: 10),
            generation: 1
        )
        let secondSnapshot = APIModelCatalogSnapshot(
            scope: secondScope,
            modelIDs: ["second"],
            refreshedAt: Date(timeIntervalSince1970: 20),
            generation: 1
        )

        try await storage.save(firstSnapshot)
        try await storage.save(secondSnapshot)
        let loadedFirst = try await storage.load(for: firstScope)
        let loadedSecond = try await storage.load(for: secondScope)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let persistedText = try files
            .map { try String(decoding: Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")

        XCTAssertEqual(loadedFirst, firstSnapshot)
        XCTAssertEqual(loadedSecond, secondSnapshot)
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(persistedText.contains("test-key"))
        XCTAssertFalse(persistedText.contains("second-test-key"))
    }

    func testSnapshotsYieldPersistentCacheBeforeCoalescedRefresh() async throws {
        let scope = try makeScope()
        let cachedDate = Date(timeIntervalSince1970: 100)
        let refreshedDate = Date(timeIntervalSince1970: 200)
        let cached = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: ["cached-model"],
            refreshedAt: cachedDate,
            generation: 41
        )
        let storage = APIModelCatalogStorageSpy(initial: [scope: cached])
        let loader = APIModelCatalogLoaderProbe()
        let catalog = APIModelCatalog(
            clock: { refreshedDate },
            storage: storage
        )

        let stream = await catalog.snapshots(
            for: scope,
            loader: { try await loader.load($0) }
        )
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.modelIDs, ["cached-model"])
        XCTAssertEqual(first?.refreshedAt, cachedDate)

        await loader.waitForCallCount(1)
        let concurrentRefresh = Task { await catalog.refresh(for: scope) }
        await loader.succeed(call: 0, modelIDs: ["new-model", "new-model", "  other-model  "])

        let second = await iterator.next()
        let coalesced = await concurrentRefresh.value
        XCTAssertEqual(second?.modelIDs, ["new-model", "other-model"])
        XCTAssertEqual(coalesced, second)
        let terminal = await iterator.next()
        let loaderCallCount = await loader.callCount
        let savedSnapshotCount = await storage.savedSnapshots.count
        XCTAssertNil(terminal)
        XCTAssertEqual(loaderCallCount, 1)
        XCTAssertEqual(savedSnapshotCount, 1)
    }

    func testFailedAndSuspiciousEmptyRefreshesRetainLastKnownGood() async throws {
        let scope = try makeScope()
        let loader = APIModelCatalogLoaderProbe()
        let catalog = APIModelCatalog(
            clock: { Date(timeIntervalSince1970: 300) },
            loader: { try await loader.load($0) }
        )

        let firstRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(1)
        await loader.succeed(call: 0, modelIDs: ["known-good"])
        let firstResult = await firstRefresh.value
        let knownGood = try XCTUnwrap(firstResult)

        let emptyRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(2)
        await loader.succeed(call: 1, modelIDs: ["", "\n"])
        let emptyResult = await emptyRefresh.value
        XCTAssertEqual(emptyResult, knownGood)

        let failedRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(3)
        await loader.fail(call: 2)
        let failedResult = await failedRefresh.value
        let retained = await catalog.cachedSnapshot(for: scope)
        XCTAssertEqual(failedResult, knownGood)
        XCTAssertEqual(retained, knownGood)
        let reportedFailure = await catalog.refreshFailure(for: scope)
        XCTAssertNotNil(reportedFailure)

        let recoveredRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(4)
        await loader.succeed(call: 3, modelIDs: ["recovered"])
        let recoveredResult = await recoveredRefresh.value
        let clearedFailure = await catalog.refreshFailure(for: scope)
        XCTAssertEqual(recoveredResult?.modelIDs, ["recovered"])
        XCTAssertNil(clearedFailure)
    }

    func testOpenAIModelsResponseLossilyParsesShutdownDateThroughHTTPDecoder() async throws {
        let response = try await HTTPDecoding.decode(
            CustomOpenAIProvider.ModelsResponse.self,
            from: Data(
                #"{"data":[{"id":"numeric","shutdown_date":1800000000},{"id":"absent"},{"id":"null","shutdown_date":null},{"id":"string","shutdown_date":"secret"},{"id":"object","shutdown_date":{"value":1800000000}}]}"#.utf8
            )
        )

        XCTAssertEqual(response.allModels.map(\.id), ["numeric", "absent", "null", "string", "object"])
        XCTAssertEqual(response.allModels.first?.shutdown_date, 1_800_000_000)
        XCTAssertTrue(response.allModels.dropFirst().allSatisfy { $0.shutdown_date == nil })
    }

    func testDescriptorPayloadPersistsShutdownDateAndLegacyCacheDecodes() async throws {
        let scope = try makeScope()
        let shutdown = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = APIModelCatalog()

        let snapshot = await catalog.refresh(for: scope, payloadLoader: { _ in
            APIModelCatalogRefreshPayload(
                modelIDs: ["gpt-future"],
                models: [.init(id: "gpt-future", shutdownDate: shutdown)]
            )
        })
        XCTAssertEqual(snapshot?.models, [.init(id: "gpt-future", shutdownDate: shutdown)])

        let legacy = """
        {"scope":{"providerID":"openai","normalizedEndpoint":"https://api.openai.com/v1","keyFingerprint":"fingerprint"},"modelIDs":["legacy"],"refreshedAt":0,"generation":1}
        """
        let decoded = try JSONDecoder().decode(APIModelCatalogSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.modelIDs, ["legacy"])
        XCTAssertTrue(decoded.models.isEmpty)
    }

    func testStorageLoadNormalizesFiltersAndDeduplicatesDescriptors() async throws {
        let scope = try makeScope()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let duplicateDate = Date(timeIntervalSince1970: 1_900_000_000)
        let stored = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: [" valid ", "valid", "bad\u{0001}"],
            refreshedAt: Date(timeIntervalSince1970: 10),
            generation: 4,
            models: [
                .init(id: " valid ", shutdownDate: firstDate),
                .init(id: "valid", shutdownDate: duplicateDate),
                .init(id: "bad\u{0001}", shutdownDate: duplicateDate),
                .init(id: "unmatched", shutdownDate: duplicateDate)
            ]
        )
        let catalog = APIModelCatalog(storage: APIModelCatalogStorageSpy(initial: [scope: stored]))

        let loadedSnapshot = await catalog.cachedSnapshot(for: scope)
        let loaded = try XCTUnwrap(loadedSnapshot)
        XCTAssertEqual(loaded.modelIDs, ["valid"])
        XCTAssertEqual(loaded.models, [.init(id: "valid", shutdownDate: firstDate)])

        let resolver = try OpenAIAPIModelMetadataResolver()
        let status = OpenAIModelCatalogStatus.make(
            resolution: resolver.currentResolution(),
            baselineVersion: "baseline",
            overrideFileURL: URL(fileURLWithPath: "/tmp/metadata.json"),
            snapshot: loaded,
            hasSuccessfulLiveRefresh: false,
            refreshFailure: nil,
            normalizedEndpoint: scope.normalizedEndpoint,
            typedCustomModelID: nil,
            projectedMetadataRowCount: 0
        )
        XCTAssertEqual(status.shutdownDatesByModelID, ["valid": firstDate])
    }

    func testCancellationRetainsSnapshotWithoutPublishingFailure() async throws {
        let scope = try makeScope()
        let catalog = APIModelCatalog()
        let knownGood = await catalog.refresh(for: scope, payloadLoader: { _ in
            APIModelCatalogRefreshPayload(modelIDs: ["known-good"])
        })

        let cancelled = await catalog.refresh(for: scope, payloadLoader: { _ in
            throw CancellationError()
        })

        let retained = await catalog.cachedSnapshot(for: scope)
        let failure = await catalog.refreshFailure(for: scope)
        XCTAssertEqual(cancelled, knownGood)
        XCTAssertEqual(retained, knownGood)
        XCTAssertNil(failure)
    }

    func testArbitraryRefreshErrorBecomesBoundedDisplaySafeFailure() async throws {
        let scope = try makeScope()
        let sentinels = [
            "sk-live-secret",
            String(repeating: "f", count: 64),
            "user:password",
            "query-token",
            "Authorization: Bearer",
            "%2Fsecret",
            String(repeating: "x", count: 2000)
        ]
        let catalog = APIModelCatalog()

        _ = await catalog.refresh(for: scope, payloadLoader: { _ in
            throw APIModelCatalogSensitiveError(message: sentinels.joined(separator: "|"))
        })

        let reportedFailure = await catalog.refreshFailure(for: scope)
        let failure = try XCTUnwrap(reportedFailure)
        XCTAssertEqual(failure.reason, .requestFailed)
        XCTAssertLessThanOrEqual(failure.message.count, 80)

        let resolver = try OpenAIAPIModelMetadataResolver()
        let status = OpenAIModelCatalogStatus.make(
            resolution: resolver.currentResolution(),
            baselineVersion: "baseline",
            overrideFileURL: URL(fileURLWithPath: "/tmp/metadata.json"),
            snapshot: nil,
            hasSuccessfulLiveRefresh: false,
            refreshFailure: failure,
            normalizedEndpoint: "https://api.openai.com/v1",
            typedCustomModelID: nil,
            projectedMetadataRowCount: 0
        )
        let displayable = String(describing: status)
        XCTAssertLessThanOrEqual(status.lastError?.count ?? .max, 80)
        for sentinel in sentinels {
            XCTAssertFalse(failure.message.contains(sentinel))
            XCTAssertFalse(displayable.contains(sentinel))
        }
    }

    func testInvalidationGenerationPreventsOlderRefreshFromOverwritingNewerResult() async throws {
        let scope = try makeScope()
        let loader = APIModelCatalogLoaderProbe()
        let storage = APIModelCatalogStorageSpy()
        let catalog = APIModelCatalog(
            clock: { Date(timeIntervalSince1970: 400) },
            loader: { try await loader.load($0) },
            storage: storage
        )

        let olderRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(1)
        await catalog.invalidate(scope)

        let newerRefresh = Task { await catalog.refresh(for: scope) }
        await loader.waitForCallCount(2)
        await loader.succeed(call: 1, modelIDs: ["newer"])
        let newerResult = await newerRefresh.value
        let newer = try XCTUnwrap(newerResult)

        await loader.succeed(call: 0, modelIDs: ["older"])
        _ = await olderRefresh.value

        let retainedModelIDs = await catalog.cachedSnapshot(for: scope)?.modelIDs
        let staleFailure = await catalog.refreshFailure(for: scope)
        let savedModelIDs = await storage.savedSnapshots.map(\.modelIDs)
        XCTAssertEqual(newer.modelIDs, ["newer"])
        XCTAssertEqual(retainedModelIDs, ["newer"])
        XCTAssertNil(staleFailure)
        XCTAssertEqual(savedModelIDs, [["newer"]])
    }

    func testAcceptedEmptyPayloadClearsPriorSnapshotAndRunsCommit() async throws {
        let scope = try makeScope()
        let accepted = APIModelCatalogAcceptedCommitProbe()
        let storage = APIModelCatalogStorageSpy()
        let catalog = APIModelCatalog(storage: storage)

        _ = await catalog.refresh(for: scope, payloadLoader: { _ in
            APIModelCatalogRefreshPayload(modelIDs: ["known"])
        })
        let cleared = await catalog.refresh(for: scope, payloadLoader: { _ in
            APIModelCatalogRefreshPayload(
                modelIDs: [],
                acceptsEmptyResponse: true,
                acceptedCommit: { accepted.append("empty") }
            )
        })

        let cachedModelIDs = await catalog.cachedSnapshot(for: scope)?.modelIDs
        let savedModelIDs = await storage.savedSnapshots.map(\.modelIDs)
        let rehydratedCatalog = APIModelCatalog(storage: storage)
        let rehydratedModelIDs = await rehydratedCatalog.cachedSnapshot(for: scope)?.modelIDs
        XCTAssertEqual(cleared?.modelIDs, [])
        XCTAssertEqual(cachedModelIDs, [])
        XCTAssertEqual(savedModelIDs, [["known"], []])
        XCTAssertEqual(rehydratedModelIDs, [])
        XCTAssertEqual(accepted.values, ["empty"])
    }

    func testInvalidationGenerationPreventsStaleDescriptorPayloadCommit() async throws {
        let scope = try makeScope()
        let loader = APIModelCatalogPayloadLoaderProbe()
        let accepted = APIModelCatalogAcceptedCommitProbe()
        let catalog = APIModelCatalog()

        let olderRefresh = Task {
            await catalog.refresh(for: scope, payloadLoader: { try await loader.load($0) })
        }
        await loader.waitForCallCount(1)
        await catalog.invalidate(scope)

        let newerRefresh = Task {
            await catalog.refresh(for: scope, payloadLoader: { try await loader.load($0) })
        }
        await loader.waitForCallCount(2)
        await loader.succeed(
            call: 1,
            payload: APIModelCatalogRefreshPayload(
                modelIDs: ["newer"],
                acceptedCommit: { accepted.append("newer") }
            )
        )
        _ = await newerRefresh.value

        await loader.succeed(
            call: 0,
            payload: APIModelCatalogRefreshPayload(
                modelIDs: ["older"],
                acceptedCommit: { accepted.append("older") }
            )
        )
        _ = await olderRefresh.value

        let cachedModelIDs = await catalog.cachedSnapshot(for: scope)?.modelIDs
        XCTAssertEqual(accepted.values, ["newer"])
        XCTAssertEqual(cachedModelIDs, ["newer"])
    }

    private func makeScope() throws -> APIModelCatalogScope {
        try XCTUnwrap(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://api.openai.com/v1",
            apiKey: "test-key"
        ))
    }
}

private enum APIModelCatalogTestError: Error {
    case failed
}

private struct APIModelCatalogSensitiveError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private actor APIModelCatalogLoaderProbe {
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<[String], any Error>] = [:]
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(_ scope: APIModelCatalogScope) async throws -> [String] {
        let call = callCount
        callCount += 1
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func succeed(call: Int, modelIDs: [String]) {
        pending.removeValue(forKey: call)?.resume(returning: modelIDs)
    }

    func fail(call: Int) {
        pending.removeValue(forKey: call)?.resume(throwing: APIModelCatalogTestError.failed)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if callCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callWaiters = remaining
    }
}

private actor APIModelCatalogPayloadLoaderProbe {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<APIModelCatalogRefreshPayload, any Error>] = [:]
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(_ scope: APIModelCatalogScope) async throws -> APIModelCatalogRefreshPayload {
        let call = callCount
        callCount += 1
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func succeed(call: Int, payload: APIModelCatalogRefreshPayload) {
        pending.removeValue(forKey: call)?.resume(returning: payload)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if callCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callWaiters = remaining
    }
}

private final class APIModelCatalogAcceptedCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: String) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private actor APIModelCatalogStorageSpy: APIModelCatalogStorage {
    private var stored: [APIModelCatalogScope: APIModelCatalogSnapshot]
    private(set) var savedSnapshots: [APIModelCatalogSnapshot] = []

    init(initial: [APIModelCatalogScope: APIModelCatalogSnapshot] = [:]) {
        stored = initial
    }

    func load(for scope: APIModelCatalogScope) async throws -> APIModelCatalogSnapshot? {
        stored[scope]
    }

    func save(_ snapshot: APIModelCatalogSnapshot) async throws {
        savedSnapshots.append(snapshot)
        stored[snapshot.scope] = snapshot
    }

    func remove(for scope: APIModelCatalogScope) async throws {
        stored.removeValue(forKey: scope)
    }
}
