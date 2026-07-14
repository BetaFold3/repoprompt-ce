import Foundation
@testable import RepoPromptGateway
import XCTest

final class GatewayTrustRefreshCoordinatorTests: XCTestCase {
    func testRefreshesSerializeFetchAndApplyWithoutStaleOverwrite() async throws {
        let probe = GatewayTrustRefreshCoordinatorProbe()
        let coordinator = GatewayTrustRefreshCoordinator(
            fetchSnapshot: { try await probe.fetchSnapshot() },
            applySnapshot: { snapshot in await probe.apply(snapshot) }
        )

        let first = Task { try await coordinator.refresh() }
        await probe.waitUntilFirstFetchStarted()
        let second = Task { try await coordinator.refresh() }
        await coordinator.waitUntilRefreshIsQueuedForTesting()

        let fetchCountWhileBlocked = await probe.fetchCount
        XCTAssertEqual(fetchCountWhileBlocked, 1, "A second refresh must not overlap an older fetch")
        await probe.releaseFirstFetch()
        try await first.value
        try await second.value

        let maximumConcurrentFetches = await probe.maximumConcurrentFetches
        let appliedFingerprints = await probe.appliedFingerprints
        XCTAssertEqual(maximumConcurrentFetches, 1)
        XCTAssertEqual(appliedFingerprints, ["snapshot-1", "snapshot-2"])
    }

    func testStopReleasesQueuedRefreshesWithoutPublishing() async throws {
        let probe = GatewayTrustRefreshCoordinatorProbe()
        let coordinator = GatewayTrustRefreshCoordinator(
            fetchSnapshot: { try await probe.fetchSnapshot() },
            applySnapshot: { snapshot in await probe.apply(snapshot) }
        )

        let first = Task { try await coordinator.refresh() }
        await probe.waitUntilFirstFetchStarted()
        let second = Task { try await coordinator.refresh() }
        await coordinator.waitUntilRefreshIsQueuedForTesting()
        await coordinator.stop()
        await probe.releaseFirstFetch()

        do {
            try await first.value
            XCTFail("An in-flight refresh must not publish after stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            try await second.value
            XCTFail("A queued refresh must not run after stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let appliedFingerprints = await probe.appliedFingerprints
        XCTAssertTrue(appliedFingerprints.isEmpty)
    }
}

private actor GatewayTrustRefreshCoordinatorProbe {
    private(set) var fetchCount = 0
    private(set) var maximumConcurrentFetches = 0
    private(set) var appliedFingerprints: [String] = []
    private var concurrentFetches = 0
    private var firstFetchStarted = false
    private var firstFetchReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFirstFetchStarted() async {
        if firstFetchStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstFetch() {
        firstFetchReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func fetchSnapshot() async throws -> GatewayTrustSnapshot {
        fetchCount += 1
        let ordinal = fetchCount
        concurrentFetches += 1
        maximumConcurrentFetches = max(maximumConcurrentFetches, concurrentFetches)
        if ordinal == 1 {
            firstFetchStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !firstFetchReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        concurrentFetches -= 1
        return GatewayTrustSnapshot(
            hostPublicKeyRawRepresentation: Data(),
            hostFingerprint: "snapshot-\(ordinal)",
            devices: [:]
        )
    }

    func apply(_ snapshot: GatewayTrustSnapshot) {
        appliedFingerprints.append(snapshot.hostFingerprint)
    }
}
