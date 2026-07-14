import Foundation

/// Serializes trust fetch-and-apply operations from the periodic poll and
/// event-driven refreshes. The fetch and apply stay in the same critical
/// section so an older poll cannot publish after a newer post-pairing refresh.
actor GatewayTrustRefreshCoordinator {
    typealias SnapshotFetcher = @Sendable () async throws -> GatewayTrustSnapshot
    typealias SnapshotApplier = @Sendable (GatewayTrustSnapshot) async -> Void

    private let fetchSnapshot: SnapshotFetcher
    private let applySnapshot: SnapshotApplier
    private var refreshInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    #if DEBUG
        private var queueObservationWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(fetchSnapshot: @escaping SnapshotFetcher, applySnapshot: @escaping SnapshotApplier) {
        self.fetchSnapshot = fetchSnapshot
        self.applySnapshot = applySnapshot
    }

    func refresh() async throws {
        await acquireRefreshSlot()
        defer { releaseRefreshSlot() }

        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let snapshot = try await fetchSnapshot()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        await applySnapshot(snapshot)
    }

    /// Prevents queued or in-flight fetches from publishing after gateway
    /// termination. In-flight app-link calls are left to normal app-link
    /// shutdown rather than delaying process teardown.
    func stop() {
        stopped = true
        refreshInProgress = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        #if DEBUG
            let observationWaiters = queueObservationWaiters
            queueObservationWaiters.removeAll()
            observationWaiters.forEach { $0.resume() }
        #endif
    }

    #if DEBUG
        func waitUntilRefreshIsQueuedForTesting() async {
            if !waiters.isEmpty || stopped { return }
            await withCheckedContinuation { queueObservationWaiters.append($0) }
        }
    #endif

    private func acquireRefreshSlot() async {
        guard !stopped else { return }
        if !refreshInProgress {
            refreshInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            #if DEBUG
                queueObservationWaiters.forEach { $0.resume() }
                queueObservationWaiters.removeAll()
            #endif
        }
    }

    private func releaseRefreshSlot() {
        guard !stopped else {
            refreshInProgress = false
            return
        }
        if waiters.isEmpty {
            refreshInProgress = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Actor wrapper for the stateful revocation transition tracker used by the
/// sendable trust-application closure in gateway startup wiring.
actor GatewayRevokedDeviceTransitionState {
    private var tracker = GatewayRevokedDeviceTransitionTracker()

    func devicesRequiringTeardown(
        revoked: Set<String>,
        tornDown: Set<String>,
        snapshot: GatewayTrustSnapshot
    ) -> [String] {
        tracker.devicesRequiringTeardown(revoked: revoked, tornDown: tornDown, snapshot: snapshot)
    }
}
