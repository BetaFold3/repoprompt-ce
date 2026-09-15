import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIPricingStoreTests: XCTestCase {
    private static let endpoint = OpenAIPricingSeed.sourceURL
    private static let hour: TimeInterval = 60 * 60
    private static let seedVersion = OpenAIPricingSeed.catalog.pricingVersion
    /// The official capture with one gpt-5.2 rate changed, so a refresh yields a new pricing version.
    private static let modifiedDocument = OpenAIPricingDocumentFixture.officialCapture20260915.replacingOccurrences(
        of: "| gpt-5.2 | $1.75 |",
        with: "| gpt-5.2 | $1.80 |"
    )

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OpenAIPricingStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Seed, due, and single scheduled refresh

    func testSeedServesImmediatelyAndDueDispatchSchedulesOneConditionalMetadataOnlyRefresh() async throws {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let transport = ScriptedPricingTransport([
            .response(Self.ok(
                body: Self.modifiedDocument,
                etag: "\"new-etag\"",
                lastModified: "Tue, 15 Sep 2026 20:00:00 GMT"
            ))
        ])
        let store = makeStore(transport: transport, clock: clock)

        let before = store.currentSnapshot()
        XCTAssertEqual(before.sourceKind, .bundledSeed)
        XCTAssertEqual(before.catalog, OpenAIPricingSeed.catalog)
        XCTAssertEqual(before.pricingVersion, Self.seedVersion)
        XCTAssertEqual(before.validatedAt, OpenAIPricingSeed.reviewedAt)
        XCTAssertTrue(before.isStale, "validated 25 hours ago")
        XCTAssertEqual(before.rates(forModelID: "gpt-5.2")?.pricing.flatRates?.input, 1.75)
        XCTAssertTrue(transport.requests.isEmpty, "reading a snapshot never touches the network")

        XCTAssertTrue(store.noteCodexDispatch())
        XCTAssertFalse(store.noteCodexDispatch(), "a refresh is already in flight")
        let outcome = await store.refresh()
        let expectedVersion = try OpenAIPricingDocumentParser.parse(Self.modifiedDocument).pricingVersion
        XCTAssertEqual(outcome, .updated(pricingVersion: expectedVersion))
        XCTAssertEqual(store.lastRefreshOutcome, outcome)
        XCTAssertFalse(store.isRefreshInFlight)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url, Self.endpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(transport.bodyLimits, [1_048_576])
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), OpenAIPricingSeed.documentETag)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), OpenAIPricingSeed.documentLastModified)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/markdown")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(Set((request.allHTTPHeaderFields ?? [:]).keys), ["Accept", "If-None-Match", "If-Modified-Since"])

        let after = store.currentSnapshot()
        XCTAssertEqual(after.sourceKind, .fetched)
        XCTAssertFalse(after.isStale)
        XCTAssertEqual(after.validatedAt, clock.now)
        XCTAssertEqual(after.capturedAt, OpenAIPricingStore.parseHTTPDate("Tue, 15 Sep 2026 20:00:00 GMT"))
        XCTAssertEqual(after.rates(forModelID: "gpt-5.2")?.pricing.flatRates?.input, Decimal(string: "1.80"))
        XCTAssertNotEqual(after.pricingVersion, before.pricingVersion)
        // The snapshot captured at dispatch is immutable; a later refresh cannot reprice it.
        XCTAssertEqual(before.rates(forModelID: "gpt-5.2")?.pricing.flatRates?.input, 1.75)
        XCTAssertFalse(store.noteCodexDispatch(), "freshly validated; nothing is due")
    }

    func testRefreshIsNotDueWithinTwentyFourHoursAndDueAfter() async {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(Self.hour))
        let transport = ScriptedPricingTransport([.response(Self.notModified())])
        let store = makeStore(transport: transport, clock: clock)

        XCTAssertFalse(store.currentSnapshot().isStale)
        XCTAssertFalse(store.noteCodexDispatch())
        clock.advance(by: 22 * Self.hour + 59 * 60)
        XCTAssertFalse(store.noteCodexDispatch())
        XCTAssertTrue(transport.requests.isEmpty)

        clock.advance(by: 60)
        XCTAssertTrue(store.noteCodexDispatch(), "due at exactly 24 hours")
        _ = await store.refresh()
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Conditional validation

    func testConditional304RevalidatesWithoutVersionChangeWhileUnconditional304Fails() async {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let transport = ScriptedPricingTransport([
            .response(Self.notModified()),
            .response(Self.ok(body: Self.modifiedDocument, etag: nil, lastModified: nil)),
            .response(Self.notModified())
        ])
        let store = makeStore(transport: transport, clock: clock)

        let revalidated = await store.refresh()
        XCTAssertEqual(revalidated, .revalidated(pricingVersion: Self.seedVersion))
        var snapshot = store.currentSnapshot()
        XCTAssertEqual(snapshot.sourceKind, .bundledSeed)
        XCTAssertEqual(snapshot.catalog, OpenAIPricingSeed.catalog)
        XCTAssertEqual(snapshot.validatedAt, clock.now)
        XCTAssertEqual(snapshot.capturedAt, OpenAIPricingSeed.reviewedAt)
        XCTAssertFalse(snapshot.isStale)
        XCTAssertNil(defaults.data(forKey: OpenAIPricingStore.storageKey), "the seed is never persisted")

        // A 200 without validators leaves nothing to condition on; the next request is unconditional.
        clock.advance(by: 25 * Self.hour)
        _ = await store.refresh()
        clock.advance(by: 25 * Self.hour)
        let unconditional = await store.refresh()
        XCTAssertEqual(unconditional, .failed(.unexpectedNotModified))
        let request = transport.requests[2]
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
        snapshot = store.currentSnapshot()
        XCTAssertEqual(snapshot.sourceKind, .fetched)
        XCTAssertTrue(snapshot.isStale, "failure after validation marks provenance stale")
        XCTAssertEqual(snapshot.rates(forModelID: "gpt-5.2")?.pricing.flatRates?.input, Decimal(string: "1.80"), "last-good retained")
    }

    // MARK: - Failure, backoff, and rejection

    func testFailureRetainsLastGoodAndBacksOffForOneHour() async {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let transport = ScriptedPricingTransport([
            .response(OpenAIPricingTransportResponse(statusCode: 500, headers: [:], body: Data(), finalURL: Self.endpoint)),
            .response(Self.ok(body: Self.modifiedDocument, etag: "\"e2\"", lastModified: nil))
        ])
        let store = makeStore(transport: transport, clock: clock)

        XCTAssertTrue(store.noteCodexDispatch())
        let failed = await store.refresh()
        XCTAssertEqual(failed, .failed(.httpStatus(500)))
        let snapshot = store.currentSnapshot()
        XCTAssertEqual(snapshot.catalog, OpenAIPricingSeed.catalog)
        XCTAssertEqual(snapshot.sourceKind, .bundledSeed)
        XCTAssertTrue(snapshot.isStale)

        XCTAssertFalse(store.noteCodexDispatch(), "backoff after failure")
        clock.advance(by: 59 * 60)
        XCTAssertFalse(store.noteCodexDispatch())
        XCTAssertEqual(transport.requests.count, 1)
        clock.advance(by: 60)
        XCTAssertTrue(store.noteCodexDispatch())
        let recovered = await store.refresh()
        guard case .updated = recovered else {
            return XCTFail("Expected update after backoff, got \(recovered)")
        }
        XCTAssertFalse(store.currentSnapshot().isStale)
    }

    func testRejectedTransportRedirectAndInvalidDocumentsKeepLastGood() async throws {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let batchOnly = OpenAIPricingDocumentFixture.officialCapture20260915.replacingOccurrences(
            of: "### Standard pricing data",
            with: "### Standard pricing data (revised)"
        )
        let offHostURL = try XCTUnwrap(URL(string: "https://example.com/api/docs/pricing.md"))
        let downgradedURL = try XCTUnwrap(URL(string: "http://developers.openai.com/api/docs/pricing.md"))
        let cases: [(name: String, step: ScriptedPricingTransport.Step, check: (OpenAIPricingRefreshOutcome) -> Bool)] = [
            ("oversized body", .failure(OpenAIPricingTransportError.responseTooLarge(limit: 1_048_576)), { outcome in
                if case .failed(.transport) = outcome { return true }
                return false
            }),
            ("redirect rejected by transport", .failure(OpenAIPricingTransportError.redirected), { outcome in
                if case .failed(.transport) = outcome { return true }
                return false
            }),
            ("final URL off the pinned host", .response(OpenAIPricingTransportResponse(
                statusCode: 200,
                headers: [:],
                body: Data(Self.modifiedDocument.utf8),
                finalURL: offHostURL
            )), { $0 == .failed(.endpointMismatch) }),
            ("final URL downgraded to HTTP", .response(OpenAIPricingTransportResponse(
                statusCode: 200,
                headers: [:],
                body: Data(Self.modifiedDocument.utf8),
                finalURL: downgradedURL
            )), { $0 == .failed(.endpointMismatch) }),
            ("garbage body", .response(Self.ok(body: "not a pricing document", etag: nil, lastModified: nil)), { outcome in
                if case .failed(.invalidDocument) = outcome { return true }
                return false
            }),
            ("document without a qualified Standard table", .response(Self.ok(body: batchOnly, etag: nil, lastModified: nil)), { outcome in
                if case .failed(.invalidDocument) = outcome { return true }
                return false
            }),
            ("http status 429", .response(OpenAIPricingTransportResponse(statusCode: 429, headers: [:], body: Data(), finalURL: Self.endpoint)), {
                $0 == .failed(.httpStatus(429))
            })
        ]

        for testCase in cases {
            let transport = ScriptedPricingTransport([testCase.step])
            let store = makeStore(transport: transport, clock: clock)
            let outcome = await store.refresh()
            XCTAssertTrue(testCase.check(outcome), "\(testCase.name): \(outcome)")
            let snapshot = store.currentSnapshot()
            XCTAssertEqual(snapshot.catalog, OpenAIPricingSeed.catalog, testCase.name)
            XCTAssertEqual(snapshot.sourceKind, .bundledSeed, testCase.name)
            XCTAssertTrue(snapshot.isStale, testCase.name)
            XCTAssertNil(defaults.data(forKey: OpenAIPricingStore.storageKey), testCase.name)
            XCTAssertFalse(store.noteCodexDispatch(), "\(testCase.name): backoff applies")
        }
    }

    func testNetworkNotPermittedSkipsRefreshWithoutBackoff() async {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let transport = ScriptedPricingTransport([.response(Self.notModified())])
        let permitted = LockedFlag(false)
        let store = makeStore(transport: transport, clock: clock, isNetworkPermitted: { permitted.value })

        XCTAssertFalse(store.noteCodexDispatch())
        XCTAssertEqual(store.lastRefreshOutcome, .skippedNetworkNotPermitted)
        let skipped = await store.refresh()
        XCTAssertEqual(skipped, .skippedNetworkNotPermitted)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(store.currentSnapshot().isStale, "still 25 hours old")

        permitted.value = true
        XCTAssertTrue(store.noteCodexDispatch(), "no failure backoff was recorded")
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .revalidated(pricingVersion: Self.seedVersion))
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Single flight

    func testConcurrentRefreshesShareOneInFlightAttempt() async {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let gate = AsyncGate()
        let transport = ScriptedPricingTransport([.response(Self.notModified())], gate: gate)
        let store = makeStore(transport: transport, clock: clock)

        async let first = store.refresh()
        async let second = store.refresh()
        while transport.requests.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(store.isRefreshInFlight)
        XCTAssertFalse(store.noteCodexDispatch(), "joins the in-flight attempt instead of starting another")
        gate.open()

        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.revalidated(pricingVersion: Self.seedVersion), .revalidated(pricingVersion: Self.seedVersion)])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(store.isRefreshInFlight)
    }

    // MARK: - Persistence

    func testPersistedFetchedCatalogHydratesAndOlderOrCorruptPersistenceYieldsToSeed() async throws {
        let clock = TestClock(OpenAIPricingSeed.reviewedAt.addingTimeInterval(25 * Self.hour))
        let fetchedTransport = ScriptedPricingTransport([
            .response(Self.ok(body: Self.modifiedDocument, etag: "\"persisted-etag\"", lastModified: "Tue, 15 Sep 2026 20:00:00 GMT"))
        ])
        let writer = makeStore(transport: fetchedTransport, clock: clock)
        guard case .updated = await writer.refresh() else {
            return XCTFail("Expected update")
        }
        let persisted = try XCTUnwrap(defaults.data(forKey: OpenAIPricingStore.storageKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("Authorization"))

        let rehydrateTransport = ScriptedPricingTransport([.response(Self.notModified())])
        let reader = makeStore(transport: rehydrateTransport, clock: clock)
        let hydrated = reader.currentSnapshot()
        XCTAssertEqual(hydrated.sourceKind, .persistedCache)
        XCTAssertEqual(hydrated.catalog, writer.currentSnapshot().catalog)
        XCTAssertEqual(hydrated.validatedAt, clock.now)
        XCTAssertFalse(hydrated.isStale)
        clock.advance(by: 25 * Self.hour)
        let revalidated = await reader.refresh()
        XCTAssertEqual(revalidated, .revalidated(pricingVersion: hydrated.pricingVersion))
        XCTAssertEqual(rehydrateTransport.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"persisted-etag\"")
        XCTAssertEqual(rehydrateTransport.requests.first?.value(forHTTPHeaderField: "If-Modified-Since"), "Tue, 15 Sep 2026 20:00:00 GMT")

        // A persisted document older than the reviewed seed yields to the seed. The content must
        // differ from the already-persisted catalog; identical content is (correctly) a revalidation.
        let olderDocument = Self.modifiedDocument.replacingOccurrences(
            of: "| gpt-5.2 | $1.80 |",
            with: "| gpt-5.2 | $1.90 |"
        )
        let olderTransport = ScriptedPricingTransport([
            .response(Self.ok(body: olderDocument, etag: "\"old\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))
        ])
        let olderWriter = makeStore(transport: olderTransport, clock: clock)
        XCTAssertEqual(olderWriter.currentSnapshot().sourceKind, .persistedCache, "hydrates the newer persisted catalog first")
        let olderOutcome = await olderWriter.refresh()
        let olderVersion = try OpenAIPricingDocumentParser.parse(olderDocument).pricingVersion
        XCTAssertEqual(olderOutcome, .updated(pricingVersion: olderVersion))
        XCTAssertEqual(olderWriter.currentSnapshot().capturedAt, OpenAIPricingStore.parseHTTPDate("Mon, 01 Jan 2024 00:00:00 GMT"))
        let seedReader = makeStore(transport: ScriptedPricingTransport([]), clock: clock)
        XCTAssertEqual(seedReader.currentSnapshot().sourceKind, .bundledSeed)
        XCTAssertEqual(seedReader.currentSnapshot().catalog, OpenAIPricingSeed.catalog)

        // Corrupt or future-schema bytes are ignored and preserved rather than deleted.
        for bytes in [Data("{not-json".utf8), Data(#"{"schemaVersion":99}"#.utf8)] {
            defaults.set(bytes, forKey: OpenAIPricingStore.storageKey)
            let corruptReader = makeStore(transport: ScriptedPricingTransport([]), clock: clock)
            XCTAssertEqual(corruptReader.currentSnapshot().sourceKind, .bundledSeed)
            XCTAssertEqual(defaults.data(forKey: OpenAIPricingStore.storageKey), bytes)
        }
    }

    // MARK: - Transport policy

    func testRedirectPolicyPermitsOnlyPinnedHTTPSHost() throws {
        let policy = OpenAIPricingRedirectPolicy(pinnedHost: "developers.openai.com")
        XCTAssertTrue(policy.permits(URL(string: "https://developers.openai.com/api/docs/pricing.md")))
        XCTAssertTrue(policy.permits(URL(string: "https://DEVELOPERS.openai.com/api/docs/pricing")))
        XCTAssertFalse(policy.permits(URL(string: "http://developers.openai.com/api/docs/pricing.md")))
        XCTAssertFalse(policy.permits(URL(string: "https://platform.openai.com/docs/pricing")))
        XCTAssertFalse(policy.permits(URL(string: "https://developers.openai.com.evil.example/x")))
        XCTAssertFalse(policy.permits(nil))

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: Self.endpoint)
        defer { session.invalidateAndCancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: Self.endpoint, statusCode: 302, httpVersion: nil, headerFields: nil))
        let crossHostURL = try XCTUnwrap(URL(string: "https://example.com/pricing.md"))
        var crossHostDecision: URLRequest?? = nil
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: crossHostURL)) {
            crossHostDecision = .some($0)
        }
        XCTAssertEqual(crossHostDecision, .some(nil))
        var sameHostDecision: URLRequest?? = nil
        let sameHost = try URLRequest(url: XCTUnwrap(URL(string: "https://developers.openai.com/api/docs/pricing")))
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: sameHost) {
            sameHostDecision = .some($0)
        }
        XCTAssertEqual(sameHostDecision, .some(sameHost))
    }

    // MARK: - Helpers

    private func makeStore(
        transport: ScriptedPricingTransport,
        clock: TestClock,
        isNetworkPermitted: @escaping @Sendable () -> Bool = { true }
    ) -> OpenAIPricingStore {
        OpenAIPricingStore(
            defaults: defaults,
            transport: transport,
            configuration: OpenAIPricingStore.Configuration(),
            now: { clock.now },
            isNetworkPermitted: isNetworkPermitted
        )
    }

    private static func ok(body: String, etag: String?, lastModified: String?) -> OpenAIPricingTransportResponse {
        var headers = ["content-type": "text/markdown; charset=utf-8"]
        if let etag { headers["etag"] = etag }
        if let lastModified { headers["last-modified"] = lastModified }
        return OpenAIPricingTransportResponse(statusCode: 200, headers: headers, body: Data(body.utf8), finalURL: endpoint)
    }

    private static func notModified() -> OpenAIPricingTransportResponse {
        OpenAIPricingTransportResponse(statusCode: 304, headers: [:], body: Data(), finalURL: endpoint)
    }
}

// MARK: - Test doubles

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class ScriptedPricingTransport: OpenAIPricingDocumentTransport, @unchecked Sendable {
    enum Step {
        case response(OpenAIPricingTransportResponse)
        case failure(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private let gate: AsyncGate?
    private var recordedRequests: [URLRequest] = []
    private var recordedLimits: [Int] = []

    init(_ steps: [Step], gate: AsyncGate? = nil) {
        self.steps = steps
        self.gate = gate
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var bodyLimits: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLimits
    }

    func fetch(_ request: URLRequest, maximumBodyBytes: Int) async throws -> OpenAIPricingTransportResponse {
        lock.lock()
        recordedRequests.append(request)
        recordedLimits.append(maximumBodyBytes)
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        if let gate {
            await gate.wait()
        }
        switch step {
        case let .response(response)?:
            return response
        case let .failure(error)?:
            throw error
        case nil:
            throw OpenAIPricingTransportError.invalidResponse
        }
    }
}
