import Foundation

// MARK: - Transport seam

// swiftformat:disable:next redundantSendable
struct OpenAIPricingTransportResponse: Equatable, Sendable {
    let statusCode: Int
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
    /// The URL that produced the response; must equal the pinned endpoint.
    let finalURL: URL?

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum OpenAIPricingTransportError: Error, Equatable {
    case invalidResponse
    case redirected
    case responseTooLarge(limit: Int)
    case networkNotPermitted
}

/// Minimal metadata-only GET seam. The request carries no auth, prompts, usage, session IDs,
/// or model queries; only conditional validators when a validated body is held.
protocol OpenAIPricingDocumentTransport: Sendable {
    func fetch(_ request: URLRequest, maximumBodyBytes: Int) async throws -> OpenAIPricingTransportResponse
}

/// Allows only HTTPS redirects that stay on the pinned host; everything else is cancelled.
final class OpenAIPricingRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pinnedHost: String

    init(pinnedHost: String) {
        self.pinnedHost = pinnedHost
    }

    func permits(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == pinnedHost.lowercased()
        else {
            return false
        }
        return true
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(permits(request.url) ? request : nil)
    }
}

struct OpenAIPricingURLSessionTransport: OpenAIPricingDocumentTransport {
    private let session: URLSession
    private let policy: OpenAIPricingRedirectPolicy

    init(pinnedHost: String, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        policy = OpenAIPricingRedirectPolicy(pinnedHost: pinnedHost)
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }

    func fetch(_ request: URLRequest, maximumBodyBytes: Int) async throws -> OpenAIPricingTransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIPricingTransportError.invalidResponse
        }
        // Only validated same-host HTTPS redirects can reach here; anything else was cancelled.
        guard policy.permits(http.url) else {
            throw OpenAIPricingTransportError.redirected
        }
        if http.expectedContentLength > Int64(maximumBodyBytes) {
            throw OpenAIPricingTransportError.responseTooLarge(limit: maximumBodyBytes)
        }
        var body = Data()
        body.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(maximumBodyBytes))))
        // `bytes` yields decoded (decompressed) bytes, so the cap bounds the decoded response.
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumBodyBytes else {
                throw OpenAIPricingTransportError.responseTooLarge(limit: maximumBodyBytes)
            }
            body.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        return OpenAIPricingTransportResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: body,
            finalURL: http.url
        )
    }
}

// MARK: - Refresh outcome

enum OpenAIPricingRefreshOutcome: Equatable {
    /// A new validated catalog replaced the previous one.
    case updated(pricingVersion: String)
    /// The document was validated again (304, or a 200 with identical content); version unchanged.
    case revalidated(pricingVersion: String)
    /// Refresh failed; the last-good catalog is retained and retry backs off.
    case failed(OpenAIPricingRefreshFailure)
    /// Network use is not permitted by the injected policy; no failure backoff is recorded.
    case skippedNetworkNotPermitted
}

enum OpenAIPricingRefreshFailure: Equatable {
    case transport(String)
    case httpStatus(Int)
    case unexpectedNotModified
    case invalidDocument(String)
    case endpointMismatch
}

// MARK: - Store

/// Single-flight, bounded refresher and atomic local persistence for OpenAI pricing.
///
/// - Serves the reviewed seed or the persisted last-good catalog immediately; nothing waits on network.
/// - `noteCodexDispatch()` schedules at most one background refresh when the last validation is
///   older than 24 hours, no attempt failed within the last hour, and network use is permitted.
/// - The only request is a keyless GET of the pinned official document, capped at 10 seconds and
///   1 MiB decoded, with conditional validators when a corresponding validated body is held.
/// - A valid 304 refreshes `validatedAt` without changing `pricingVersion`; an unconditional
///   request answered with 304 is a failure. Failures keep the last-good catalog with stale provenance.
/// - Only fetched catalogs persist (normalized JSON under one `UserDefaults` key, replaced atomically);
///   the seed is bundled. A newer seed wins over an older persisted document.
final class OpenAIPricingStore: OpenAIPricingProviding, @unchecked Sendable {
    // swiftformat:disable:next redundantSendable
    struct Configuration: Sendable {
        var endpoint: URL = OpenAIPricingSeed.sourceURL
        var refreshInterval: TimeInterval = 24 * 60 * 60
        var failureBackoff: TimeInterval = 60 * 60
        var requestTimeout: TimeInterval = 10
        var maximumBodyBytes: Int = 1_048_576

        init() {}

        var pinnedHost: String {
            endpoint.host?.lowercased() ?? ""
        }
    }

    static let storageKey = "OpenAIPricingCatalogV1"
    static let shared = OpenAIPricingStore(defaults: .standard)

    /// Persisted only for fetched catalogs.
    private struct PersistedRecord: Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let catalog: OpenAIPricingCatalog
        let sourceURL: String
        let capturedAt: Date
        let validatedAt: Date
        let etag: String?
        let lastModified: String?
    }

    private struct State: Equatable {
        var catalog: OpenAIPricingCatalog
        var sourceKind: OpenAIPricingSourceKind
        var capturedAt: Date
        var validatedAt: Date
        var etag: String?
        var lastModified: String?
        var lastFailureAt: Date?
    }

    private let configuration: Configuration
    private let defaults: UserDefaults
    private let cleanupSuiteName: String?
    private let transport: any OpenAIPricingDocumentTransport
    private let now: @Sendable () -> Date
    private let isNetworkPermitted: @Sendable () -> Bool
    private let lock = NSLock()
    private var state: State
    private var inFlight: Task<OpenAIPricingRefreshOutcome, Never>?
    private var storedLastOutcome: OpenAIPricingRefreshOutcome?

    convenience init(defaults: UserDefaults = .standard) {
        let configuration = Configuration()
        self.init(
            defaults: defaults,
            transport: OpenAIPricingURLSessionTransport(
                pinnedHost: configuration.pinnedHost,
                timeout: configuration.requestTimeout
            ),
            configuration: configuration
        )
    }

    /// - Parameters:
    ///   - isNetworkPermitted: hook for any existing network restriction the caller already
    ///     enforces; `false` skips refresh without recording a failure. No new global policy exists.
    init(
        defaults: UserDefaults,
        transport: any OpenAIPricingDocumentTransport,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        isNetworkPermitted: @escaping @Sendable () -> Bool = { true },
        cleanupSuiteName: String? = nil
    ) {
        self.defaults = defaults
        self.transport = transport
        self.configuration = configuration
        self.now = now
        self.isNetworkPermitted = isNetworkPermitted
        self.cleanupSuiteName = cleanupSuiteName
        state = Self.initialState(defaults: defaults, endpoint: configuration.endpoint)
    }

    deinit {
        if let cleanupSuiteName {
            defaults.removePersistentDomain(forName: cleanupSuiteName)
        }
    }

    /// Isolated store for tests; its defaults domain is removed when the store deinitializes.
    static func transient(
        transport: any OpenAIPricingDocumentTransport,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        isNetworkPermitted: @escaping @Sendable () -> Bool = { true }
    ) -> OpenAIPricingStore {
        let suiteName = "OpenAIPricingStore.Transient.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated OpenAI pricing defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return OpenAIPricingStore(
            defaults: defaults,
            transport: transport,
            configuration: configuration,
            now: now,
            isNetworkPermitted: isNetworkPermitted,
            cleanupSuiteName: suiteName
        )
    }

    // MARK: OpenAIPricingProviding

    func currentSnapshot() -> OpenAIPricingSnapshot {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        return Self.snapshot(from: state, at: current, refreshInterval: configuration.refreshInterval)
    }

    @discardableResult
    func noteCodexDispatch() -> Bool {
        refreshIfDue()
    }

    /// Schedules one background refresh when due. Returns `true` only when this call scheduled it.
    @discardableResult
    func refreshIfDue() -> Bool {
        let current = now()
        lock.lock()
        guard inFlight == nil, Self.isRefreshDue(state, at: current, configuration: configuration) else {
            lock.unlock()
            return false
        }
        guard isNetworkPermitted() else {
            storedLastOutcome = .skippedNetworkNotPermitted
            lock.unlock()
            return false
        }
        startRefreshLocked()
        lock.unlock()
        return true
    }

    /// Runs (or joins) a refresh regardless of due time. Single-flight: concurrent callers share one attempt.
    func refresh() async -> OpenAIPricingRefreshOutcome {
        let task = withStateLock { () -> Task<OpenAIPricingRefreshOutcome, Never>? in
            if let inFlight {
                return inFlight
            }
            guard isNetworkPermitted() else {
                storedLastOutcome = .skippedNetworkNotPermitted
                return nil
            }
            return startRefreshLocked()
        }
        guard let task else {
            return .skippedNetworkNotPermitted
        }
        return await task.value
    }

    var lastRefreshOutcome: OpenAIPricingRefreshOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastOutcome
    }

    var isRefreshInFlight: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight != nil
    }

    // MARK: - Refresh

    @discardableResult
    private func startRefreshLocked() -> Task<OpenAIPricingRefreshOutcome, Never> {
        let validators = (etag: state.etag, lastModified: state.lastModified)
        let task = Task.detached(priority: .utility) { [weak self] () -> OpenAIPricingRefreshOutcome in
            guard let self else { return .failed(.transport("store released")) }
            let outcome = await performRefresh(validators: validators)
            finishRefresh(with: outcome)
            return outcome
        }
        inFlight = task
        return task
    }

    private func finishRefresh(with outcome: OpenAIPricingRefreshOutcome) {
        withStateLock {
            storedLastOutcome = outcome
            inFlight = nil
        }
    }

    private func performRefresh(
        validators: (etag: String?, lastModified: String?)
    ) async -> OpenAIPricingRefreshOutcome {
        let request = makeRequest(validators: validators)
        let response: OpenAIPricingTransportResponse
        do {
            response = try await transport.fetch(request, maximumBodyBytes: configuration.maximumBodyBytes)
        } catch {
            return recordFailure(.transport(String(describing: error)))
        }
        if let finalURL = response.finalURL, !Self.isPinned(finalURL, configuration: configuration) {
            return recordFailure(.endpointMismatch)
        }

        switch response.statusCode {
        case 304:
            let sentValidators = validators.etag != nil || validators.lastModified != nil
            guard sentValidators else {
                return recordFailure(.unexpectedNotModified)
            }
            return commitRevalidation(validatorsSent: validators)
        case 200:
            let catalog: OpenAIPricingCatalog
            do {
                catalog = try OpenAIPricingDocumentParser.parse(data: response.body)
            } catch {
                return recordFailure(.invalidDocument(String(describing: error)))
            }
            return commitFetched(catalog: catalog, response: response)
        default:
            return recordFailure(.httpStatus(response.statusCode))
        }
    }

    private func makeRequest(validators: (etag: String?, lastModified: String?)) -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    private func recordFailure(_ failure: OpenAIPricingRefreshFailure) -> OpenAIPricingRefreshOutcome {
        let current = now()
        lock.lock()
        state.lastFailureAt = current
        lock.unlock()
        return .failed(failure)
    }

    private func commitRevalidation(
        validatorsSent: (etag: String?, lastModified: String?)
    ) -> OpenAIPricingRefreshOutcome {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        // The 304 is only valid for the body whose validators were sent.
        guard state.etag == validatorsSent.etag, state.lastModified == validatorsSent.lastModified else {
            state.lastFailureAt = current
            return .failed(.unexpectedNotModified)
        }
        state.validatedAt = current
        state.lastFailureAt = nil
        if state.sourceKind != .bundledSeed {
            persistLocked()
        }
        return .revalidated(pricingVersion: state.catalog.pricingVersion)
    }

    private func commitFetched(
        catalog: OpenAIPricingCatalog,
        response: OpenAIPricingTransportResponse
    ) -> OpenAIPricingRefreshOutcome {
        let current = now()
        let lastModified = response.header("last-modified")
        let capturedAt = lastModified.flatMap(Self.parseHTTPDate) ?? current
        lock.lock()
        defer { lock.unlock() }
        let changed = state.catalog.pricingVersion != catalog.pricingVersion
        state = State(
            catalog: catalog,
            sourceKind: .fetched,
            capturedAt: capturedAt,
            validatedAt: current,
            etag: response.header("etag"),
            lastModified: lastModified,
            lastFailureAt: nil
        )
        persistLocked()
        return changed
            ? .updated(pricingVersion: catalog.pricingVersion)
            : .revalidated(pricingVersion: catalog.pricingVersion)
    }

    // MARK: - Persistence

    private func persistLocked() {
        let record = PersistedRecord(
            schemaVersion: PersistedRecord.schemaVersion,
            catalog: state.catalog,
            sourceURL: configuration.endpoint.absoluteString,
            capturedAt: state.capturedAt,
            validatedAt: state.validatedAt,
            etag: state.etag,
            lastModified: state.lastModified
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func initialState(defaults: UserDefaults, endpoint: URL) -> State {
        let seed = State(
            catalog: OpenAIPricingSeed.catalog,
            sourceKind: .bundledSeed,
            capturedAt: OpenAIPricingSeed.reviewedAt,
            validatedAt: OpenAIPricingSeed.reviewedAt,
            etag: OpenAIPricingSeed.documentETag,
            lastModified: OpenAIPricingSeed.documentLastModified,
            lastFailureAt: nil
        )
        guard let data = defaults.data(forKey: storageKey) else {
            return seed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(PersistedRecord.self, from: data),
              record.schemaVersion == PersistedRecord.schemaVersion,
              record.sourceURL == endpoint.absoluteString,
              !record.catalog.isEmpty,
              record.capturedAt >= seed.capturedAt
        else {
            return seed
        }
        return State(
            catalog: record.catalog,
            sourceKind: .persistedCache,
            capturedAt: record.capturedAt,
            validatedAt: record.validatedAt,
            etag: record.etag,
            lastModified: record.lastModified,
            lastFailureAt: nil
        )
    }

    // MARK: - Helpers

    /// Synchronous scoped locking; callable from asynchronous contexts because it never suspends.
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func snapshot(
        from state: State,
        at current: Date,
        refreshInterval: TimeInterval
    ) -> OpenAIPricingSnapshot {
        let expired = current.timeIntervalSince(state.validatedAt) > refreshInterval
        let failedSinceValidation = state.lastFailureAt.map { $0 >= state.validatedAt } ?? false
        return OpenAIPricingSnapshot(
            catalog: state.catalog,
            sourceKind: state.sourceKind,
            capturedAt: state.capturedAt,
            validatedAt: state.validatedAt,
            isStale: expired || failedSinceValidation
        )
    }

    /// A response must come from the pinned host over HTTPS, even after a validated redirect.
    private static func isPinned(_ url: URL, configuration: Configuration) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == configuration.pinnedHost
    }

    private static func isRefreshDue(
        _ state: State,
        at current: Date,
        configuration: Configuration
    ) -> Bool {
        guard current.timeIntervalSince(state.validatedAt) >= configuration.refreshInterval else {
            return false
        }
        if let lastFailureAt = state.lastFailureAt,
           current.timeIntervalSince(lastFailureAt) < configuration.failureBackoff
        {
            return false
        }
        return true
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parseHTTPDate(_ text: String) -> Date? {
        httpDateFormatter.date(from: text)
    }
}
