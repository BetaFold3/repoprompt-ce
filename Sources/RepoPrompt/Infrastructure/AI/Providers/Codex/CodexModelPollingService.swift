import Foundation

protocol CodexModelListingClient: Sendable {
    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel]
    func stop() async
}

extension CodexAppServerClient: CodexModelListingClient {}

struct CodexModelCatalogStatus: Equatable {
    let modelCount: Int
    let fetchedAt: Date?
    let knownBaseCount: Int
    let lastPollError: String?
}

// SEARCH-HELPER: Codex model polling, centralized, shared client, model list, subscribe
/// Centralized polling service for Codex dynamic models.
///
/// Replaces duplicated polling logic previously spread across:
/// - `CodexAgentModeCoordinator`
/// - `ContextBuilderAgentViewModel`
/// - `APISettingsViewModel` (one-shot refresh)
///
/// Owns:
/// - A single polling loop using a dedicated `CodexAppServerClient`
/// - Broadcasting model snapshots to subscribers via `AsyncStream`
/// - Updating `AgentCodexModelRegistry` as the single canonical writer
///
/// Related:
/// - CodexProviderHelpers.makeOwnedNonAgentAppServerClient() (dedicated polling transport)
/// - AgentCodexModelRegistry (canonical registry updated by this service)
/// - AgentModelCatalog (consumes registry for model option resolution)
actor CodexModelPollingService {
    static let shared = CodexModelPollingService(
        client: CodexProviderHelpers.makeOwnedNonAgentAppServerClient(),
        stopClientOnShutdown: true,
        stopClientWhenIdle: true
    )

    struct Snapshot: Equatable {
        let models: [CodexAppServerClient.RemoteModel]
        let fetchedAt: Date
    }

    enum LastPollOutcome: Equatable {
        case success(modelCount: Int, fetchedAt: Date)
        case failure(message: String, failedAt: Date)
    }

    private let client: any CodexModelListingClient
    private let intervalNanos: UInt64
    private let stopClientOnShutdown: Bool
    private let stopClientWhenIdle: Bool
    private let registry: AgentCodexModelRegistry

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var outcomeContinuations: [UUID: AsyncStream<LastPollOutcome>.Continuation] = [:]
    private var catalogStatusContinuations: [UUID: AsyncStream<CodexModelCatalogStatus>.Continuation] = [:]
    #if DEBUG
        private var testSubscriberCountObservers: [UUID: AsyncStream<Int>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var pollOutcome: LastPollOutcome?
    private var catalogStatus: CodexModelCatalogStatus?
    private var isShutdown = false
    private var isStoppingClientForIdle = false

    init(
        client: any CodexModelListingClient,
        intervalNanos: UInt64 = 60_000_000_000,
        stopClientOnShutdown: Bool = false,
        stopClientWhenIdle: Bool = false,
        registry: AgentCodexModelRegistry = .shared
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
        self.stopClientOnShutdown = stopClientOnShutdown
        self.stopClientWhenIdle = stopClientWhenIdle
        self.registry = registry
    }

    /// Returns the most recent snapshot if available (non-blocking).
    func latestSnapshot() -> Snapshot? {
        latest
    }

    func lastPollOutcome() -> LastPollOutcome? {
        pollOutcome
    }

    func latestCatalogStatus() -> CodexModelCatalogStatus? {
        catalogStatus
    }

    #if DEBUG
        func test_subscriberCount() -> Int {
            continuations.count
        }

        func test_subscriberCountUpdates() -> AsyncStream<Int> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testSubscriberCountObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestSubscriberCountObserver(id) }
            }
            continuation.yield(continuations.count)
            return stream
        }
    #endif

    /// Subscribe to model snapshot updates.
    ///
    /// - Immediately yields the latest snapshot if one exists.
    /// - Starts the polling loop if not already running.
    /// - When the last subscriber detaches, the polling loop is cancelled.
    func subscribe() -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        #if DEBUG
            publishTestSubscriberCount()
        #endif

        // Yield latest immediately so UI populates without waiting for the first tick.
        if let latest {
            continuation.yield(latest)
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        startPollingIfNeeded()
        return stream
    }

    func subscribeToOutcomes() -> AsyncStream<LastPollOutcome> {
        guard !isShutdown else {
            return AsyncStream { $0.finish() }
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<LastPollOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        outcomeContinuations[id] = continuation
        if let pollOutcome {
            continuation.yield(pollOutcome)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeOutcomeSubscriber(id) }
        }
        return stream
    }

    func subscribeToCatalogStatus() -> AsyncStream<CodexModelCatalogStatus> {
        guard !isShutdown else {
            return AsyncStream { $0.finish() }
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<CodexModelCatalogStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        catalogStatusContinuations[id] = continuation
        if let catalogStatus {
            continuation.yield(catalogStatus)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeCatalogStatusSubscriber(id) }
        }
        return stream
    }

    /// Force an immediate model refresh (e.g. after connectivity test succeeds).
    /// Updates the registry and only broadcasts when the normalized model payload changes.
    /// Coalesces with any in-flight refresh to avoid overlapping network/process calls.
    func refreshNow() async {
        guard !isShutdown else { return }
        if let existing = inFlightRefresh {
            await existing.value
            return
        }
        await performRefresh()
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            #if DEBUG
                publishTestSubscriberCount()
            #endif
            for continuation in activeContinuations.values {
                continuation.finish()
            }
            let activeOutcomeContinuations = outcomeContinuations
            outcomeContinuations.removeAll()
            for continuation in activeOutcomeContinuations.values {
                continuation.finish()
            }
            let activeCatalogStatusContinuations = catalogStatusContinuations
            catalogStatusContinuations.removeAll()
            for continuation in activeCatalogStatusContinuations.values {
                continuation.finish()
            }
        }
        if stopClientOnShutdown {
            await client.stop()
        }
    }

    // MARK: - Internal

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard !isStoppingClientForIdle else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() async {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
        guard stopClientWhenIdle else { return }
        guard !isStoppingClientForIdle else { return }

        isStoppingClientForIdle = true
        if let inFlightRefresh {
            inFlightRefresh.cancel()
            await inFlightRefresh.value
        }
        await client.stop()
        isStoppingClientForIdle = false

        if !isShutdown, !continuations.isEmpty {
            startPollingIfNeeded()
        }
    }

    private func removeOutcomeSubscriber(_ id: UUID) {
        outcomeContinuations.removeValue(forKey: id)
    }

    private func removeCatalogStatusSubscriber(_ id: UUID) {
        catalogStatusContinuations.removeValue(forKey: id)
    }

    private func removeSubscriber(_ id: UUID) async {
        continuations.removeValue(forKey: id)
        #if DEBUG
            publishTestSubscriberCount()
        #endif
        await stopPollingIfIdle()
    }

    #if DEBUG
        private func publishTestSubscriberCount() {
            for continuation in testSubscriberCountObservers.values {
                continuation.yield(continuations.count)
            }
        }

        private func removeTestSubscriberCountObserver(_ id: UUID) {
            testSubscriberCountObservers.removeValue(forKey: id)
        }
    #endif

    private func performRefresh() async {
        guard !isShutdown else { return }
        // Single-flight: if a refresh is already running, await it instead of starting another.
        if let existing = inFlightRefresh {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await client.listModels(limit: 100)
                guard !Task.isCancelled else { return }
                let snapshot = Snapshot(models: models, fetchedAt: Date())
                await applyRefreshResult(snapshot)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                await recordPollFailure(error)
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        await task.value
    }

    private func applyRefreshResult(_ snapshot: Snapshot) {
        guard !isShutdown else { return }

        var didChange = false
        if !snapshot.models.isEmpty {
            // Single canonical registry update — no other call site should write to the registry.
            didChange = registry.updateLiveModels(snapshot.models)
        }

        let status = CodexModelCatalogStatus(
            modelCount: snapshot.models.count,
            fetchedAt: snapshot.fetchedAt,
            knownBaseCount: registry.knownModelBaseCount(),
            lastPollError: nil
        )
        catalogStatus = status
        publishCatalogStatus(status)

        let outcome = LastPollOutcome.success(
            modelCount: snapshot.models.count,
            fetchedAt: snapshot.fetchedAt
        )
        pollOutcome = outcome
        publishOutcome(outcome)

        guard !snapshot.models.isEmpty, didChange else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func recordPollFailure(_ error: Error) {
        guard !isShutdown, !(error is CancellationError), !Task.isCancelled else { return }
        let message = error.localizedDescription
        let failedAt = Date()
        let retained = catalogStatus
        let status = CodexModelCatalogStatus(
            modelCount: retained?.modelCount ?? 0,
            fetchedAt: retained?.fetchedAt,
            knownBaseCount: registry.knownModelBaseCount(),
            lastPollError: message
        )
        catalogStatus = status
        publishCatalogStatus(status)

        let outcome = LastPollOutcome.failure(message: message, failedAt: failedAt)
        pollOutcome = outcome
        publishOutcome(outcome)
    }

    private func publishOutcome(_ outcome: LastPollOutcome) {
        for continuation in outcomeContinuations.values {
            continuation.yield(outcome)
        }
    }

    private func publishCatalogStatus(_ status: CodexModelCatalogStatus) {
        for continuation in catalogStatusContinuations.values {
            continuation.yield(status)
        }
    }
}
