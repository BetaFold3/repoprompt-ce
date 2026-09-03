import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import SwiftUI
import XCTest

final class OhMyPiThinkingCapabilityRegistryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: OhMyPiThinkingCapabilityStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-capability-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = OhMyPiThinkingCapabilityStore(
            fileURL: temporaryDirectory.appendingPathComponent(
                OhMyPiThinkingCapabilityStore.fileName
            )
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testStoreRoundTripSkipsInvalidRecordsAndNeverPersistsCurrentValue() async throws {
        OhMyPiRuntimeVersionRegistry.shared.test_reset()
        defer { OhMyPiRuntimeVersionRegistry.shared.test_reset() }
        let registry = OhMyPiThinkingCapabilityRegistry(store: store)
        XCTAssertTrue(registry.record(
            capabilityRecord(modelID: "provider/model-a"),
            ompVersion: "17.3.4",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let data = try Data(contentsOf: store.fileURL)
        let persistedText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(persistedText.contains("currentValue"))
        XCTAssertTrue(persistedText.contains("ompVersion"))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [Any])
        records.append([
            "modelID": "",
            "configID": "wrong",
            "category": "wrong",
            "orderedOptions": [],
            "ompVersion": "",
            "observedAt": "2026-08-16T00:00:00Z"
        ])
        records.append(["modelID": "structurally-invalid"])
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: store.fileURL, options: [.atomic])

        let loaded = store.load()
        XCTAssertEqual(Array(loaded.keys), ["provider/model-a"])
        XCTAssertEqual(
            loaded["provider/model-a"]?.orderedOptions.map(\.value),
            ["off", "auto", "high"]
        )

        let reloadedRegistry = OhMyPiThinkingCapabilityRegistry(store: store)
        await reloadedRegistry.warmStandardStoreIfNeeded()
        XCTAssertEqual(
            reloadedRegistry.snapshot(for: "provider/model-a")?.ompVersion,
            "17.3.4"
        )
    }

    func testCorruptStoreDegradesToEmpty() throws {
        try Data("{ not-json".utf8).write(to: store.fileURL, options: [.atomic])
        XCTAssertTrue(store.load().isEmpty)
    }

    func testConcurrentRecordsPersistMergedSnapshotAndOlderObservationCannotWin() {
        let registry = OhMyPiThinkingCapabilityRegistry(store: store)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "omp-capability-records", attributes: .concurrent)
        for index in 0 ..< 24 {
            group.enter()
            queue.async {
                _ = registry.record(
                    OhMyPiThinkingCapabilityRecord(
                        modelID: "provider/model-\(index)",
                        configID: "thinking",
                        category: "thought_level",
                        orderedOptions: ["off", "auto", "high"],
                        optionDisplayNames: ["Off", "Auto", "High"]
                    ),
                    ompVersion: "17.3.4",
                    observedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
                )
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(store.load().count, 24)

        let modelID = "provider/newest"
        let newest = Date(timeIntervalSinceReferenceDate: 200)
        XCTAssertTrue(registry.record(
            capabilityRecord(modelID: modelID),
            ompVersion: "17.3.4",
            observedAt: newest
        ))
        XCTAssertFalse(registry.record(
            capabilityRecord(modelID: modelID),
            ompVersion: "17.3.4",
            observedAt: Date(timeIntervalSinceReferenceDate: 100)
        ))
        XCTAssertEqual(registry.snapshot(for: modelID)?.observedAt, newest)
        XCTAssertEqual(store.load()[modelID]?.observedAt, newest)
    }

    func testVersionChangeInvalidatesPriorRecordsInMemoryAndOnDisk() {
        let registry = OhMyPiThinkingCapabilityRegistry(store: store)
        XCTAssertTrue(registry.record(
            capabilityRecord(modelID: "provider/model-a"),
            ompVersion: "17.3.4"
        ))
        XCTAssertTrue(registry.record(
            capabilityRecord(modelID: "provider/model-b"),
            ompVersion: "17.4.0"
        ))

        XCTAssertNil(registry.snapshot(for: "provider/model-a"))
        XCTAssertEqual(registry.snapshot(for: "provider/model-b")?.ompVersion, "17.4.0")
        XCTAssertEqual(Set(store.load().keys), ["provider/model-b"])
    }

    func testConditionalRecordIsAtomicWithRuntimeVersionTransition() async {
        let registry = OhMyPiThinkingCapabilityRegistry(store: store)
        let runtime = OhMyPiRuntimeVersionRegistry(capabilityRegistry: registry)
        runtime.observe([1, 0, 0])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        runtime.test_setConditionalRecordBarrier {
            entered.signal()
            release.wait()
        }
        let record = OhMyPiThinkingCapabilityRecord(
            modelID: "provider/model-a",
            configID: "thinking",
            category: "thought_level",
            orderedOptions: ["off", "high"],
            optionDisplayNames: ["Off", "High"]
        )
        let recordTask = Task.detached {
            runtime.recordCapabilityIfCurrent(record, expectedVersion: "1.0.0")
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let transitionTask = Task.detached { runtime.observe([2, 0, 0]) }
        release.signal()
        _ = await recordTask.value
        _ = await transitionTask.value
        runtime.test_setConditionalRecordBarrier(nil)
        XCTAssertEqual(runtime.currentVersion, "2.0.0")
        XCTAssertNil(registry.snapshot(for: "provider/model-a"))
    }

    private func capabilityRecord(modelID: String) -> OhMyPiThinkingCapabilityRecord {
        OhMyPiThinkingCapabilityRecord(
            modelID: modelID,
            configID: "thinking",
            category: "thought_level",
            orderedOptions: ["off", "auto", "high"],
            optionDisplayNames: ["Off", "Auto", "High"]
        )
    }
}

final class OhMyPiThinkingCapabilityResolverTests: XCTestCase {
    #if DEBUG
        override func setUp() {
            super.setUp()
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = false
        }

        override func tearDown() {
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = false
            super.tearDown()
        }
    #endif

    func testSweepTargetsNormalizeDeduplicateAndRejectPlaceholdersBeforeProjection() {
        XCTAssertEqual(
            OhMyPiThinkingSweepTargets.compute(
                wireIDs: [" ", AgentModel.defaultModel.rawValue, " cursor/model-a ", "cursor/model-a", "cursor/model-b-high"],
                selectedRawModel: AgentModel.defaultModel.rawValue,
                recentlyInvalidated: []
            ),
            ["cursor/model-a", "cursor/model-b-high"]
        )
    }

    func testPlaceholderOnlySweepSpawnsNoClientAndMixedPlaceholdersConsumeNoCap() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 1
        let fixture = try makeResolver(limits: limits)
        let placeholder = await fixture.resolver.requestSweep(.init(
            wireIDs: ["", "   ", AgentModel.defaultModel.rawValue],
            selectedRawModel: AgentModel.defaultModel.rawValue,
            workspacePath: nil
        ))
        XCTAssertEqual(placeholder, .cached)
        let placeholderMetrics = await fixture.client.metrics()
        XCTAssertEqual(placeholderMetrics.bootstraps, 0)

        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: [AgentModel.defaultModel.rawValue, "cursor/model-a", " ", "cursor/model-b"],
            selectedRawModel: nil,
            workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let mixedMetrics = await fixture.client.metrics()
        XCTAssertEqual(mixedMetrics.switches, ["cursor/model-a"])
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 1, deferred: 1))
    }

    func testRepeatedSubmenuOpenDoesNotInflateDeferredCount() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 2
        let fixture = try makeResolver(limits: limits, gateFirstSwitch: true)
        let request = OhMyPiThinkingSweepRequest(
            wireIDs: ["cursor/a", "cursor/b", "cursor/c"], selectedRawModel: nil, workspacePath: nil
        )
        _ = await fixture.resolver.requestSweep(request)
        try await waitUntil { await fixture.client.metrics().switches == ["cursor/a"] }
        _ = await fixture.resolver.requestSweep(request)
        _ = await fixture.resolver.requestSweep(request)
        await fixture.client.release()
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 2, deferred: 1))
    }

    func testDeferredPromotionRemovesIdentityAndRunsNext() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 1
        let fixture = try makeResolver(limits: limits, gateFirstSwitch: true)
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a", "cursor/b", "cursor/c"], selectedRawModel: nil, workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().switches == ["cursor/a"] }
        let promotion = await fixture.resolver.requestPriority(
            exactModelID: "cursor/c", workspacePath: nil, manual: false
        )
        XCTAssertEqual(promotion, .enqueued)
        await fixture.client.release()
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.switches, ["cursor/a", "cursor/c"])
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 2, deferred: 1))
    }

    func testRequestDuringDelayedCleanupStaysQueuedAndStartsAfterCleanup() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.perSwitchSeconds = 0.02
        let fixture = try makeResolver(
            limits: limits, gateFirstSwitch: true, cancellationDisposalDelay: 0.15
        )
        _ = await fixture.resolver.requestPriority(
            exactModelID: "cursor/a", workspacePath: nil, manual: true
        )
        try await waitUntil { fixture.resolver.state(for: "cursor/a") == .failed }
        let queued = await fixture.resolver.requestPriority(
            exactModelID: "cursor/b", workspacePath: nil, manual: true
        )
        XCTAssertEqual(queued, .enqueued)
        XCTAssertEqual(fixture.resolver.state(for: "cursor/b"), .queued)
        try await waitUntil { await fixture.client.metrics().disposals == 2 }
        XCTAssertEqual(fixture.resolver.state(for: "cursor/b"), .idle)
    }

    func testBackgroundRequestDuringDelayedCleanupStartsSecondRunWithoutPhantomQueuedRows() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.perSwitchSeconds = 0.02
        let fixture = try makeResolver(
            limits: limits, gateFirstSwitch: true, cancellationDisposalDelay: 0.15
        )
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a"], selectedRawModel: nil, workspacePath: nil
        ))
        try await waitUntil { fixture.resolver.state(for: "cursor/a") == .failed }
        let queued = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/b"], selectedRawModel: nil, workspacePath: nil
        ))
        XCTAssertEqual(queued, .enqueued)
        XCTAssertEqual(fixture.resolver.state(for: "cursor/b"), .queued)
        try await waitUntil { await fixture.client.metrics().disposals == 2 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.bootstraps, 2)
        XCTAssertEqual(metrics.switches, ["cursor/a", "cursor/b"])
        XCTAssertNotEqual(fixture.resolver.state(for: "cursor/a"), .queued)
        XCTAssertNotEqual(fixture.resolver.state(for: "cursor/b"), .queued)
    }

    func testCompletedBackgroundSwitchesContinueConsumingControllerPassCap() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 2
        let fixture = try makeResolver(limits: limits, gateAfterFirstSwitch: true)
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a"], selectedRawModel: nil, workspacePath: nil
        ))
        try await waitUntil {
            await fixture.client.metrics().switches == ["cursor/a"]
                && fixture.resolver.state(for: "cursor/a") == .idle
        }
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/b", "cursor/c", "cursor/d"], selectedRawModel: nil, workspacePath: nil
        ))
        await fixture.client.release()
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.switches, ["cursor/a", "cursor/b"])
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 2, deferred: 2))
    }

    func testBudgetExpiredBeforeWillSwitchDefersWithoutCooldownAndResumesNextOpen() async throws {
        let fixture = try makeResolver(expireBudgetBeforeFirstSwitch: true)
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a"], selectedRawModel: nil, workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        XCTAssertEqual(fixture.resolver.state(for: "cursor/a"), .idle)
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 0, deferred: 1))
        let resumed = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a"], selectedRawModel: nil, workspacePath: nil
        ))
        XCTAssertEqual(resumed, .enqueued)
        try await waitUntil { await fixture.client.metrics().disposals == 2 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.switches, ["cursor/a", "cursor/a"])
        XCTAssertEqual(fixture.resolver.state(for: "cursor/a"), .idle)
    }

    func testDeferredBackgroundPassCarriesForwardWithPerControllerCap() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 2
        let fixture = try makeResolver(limits: limits)
        let request = OhMyPiThinkingSweepRequest(
            wireIDs: ["cursor/a", "cursor/b", "cursor/c", "cursor/d", "cursor/e"],
            selectedRawModel: nil, workspacePath: nil
        )
        _ = await fixture.resolver.requestSweep(request)
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/c", "cursor/d", "cursor/e"], selectedRawModel: nil, workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().disposals == 2 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.switches, ["cursor/a", "cursor/b", "cursor/c", "cursor/d"])
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 2, deferred: 1))
    }

    func testSweepBootstrapsOnceAndSwitchesSequentiallyInPriorityOrder() async throws {
        let fixture = try makeResolver()
        let outcome = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/model-a", "cursor/model-b", "cursor/model-c"],
            selectedRawModel: "cursor/model-b",
            workspacePath: nil
        ))
        XCTAssertEqual(outcome, .enqueued)
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.bootstraps, 1)
        XCTAssertEqual(metrics.switches, ["cursor/model-b", "cursor/model-a", "cursor/model-c"])
        XCTAssertEqual(metrics.maximumActiveSwitches, 1)
    }

    func testSweepSkipsCachedCooldownAndUnsupportedTargets() async throws {
        let fixture = try makeResolver(results: ["cursor/unsupported": .unsupported])
        XCTAssertTrue(fixture.registry.record(
            capabilityRecord(modelID: "cursor/cached"),
            ompVersion: "99.0.0"
        ))
        _ = await fixture.resolver.requestPriority(
            exactModelID: "cursor/unsupported", workspacePath: nil, manual: true
        )
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let before = await fixture.client.metrics().bootstraps
        let outcome = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/cached", "cursor/unsupported"],
            selectedRawModel: nil,
            workspacePath: nil
        ))
        XCTAssertEqual(outcome, .cached)
        let after = await fixture.client.metrics().bootstraps
        XCTAssertEqual(after, before)
    }

    func testSubmenuOpenWithFreshRecordsSpawnsNothing() async throws {
        let fixture = try makeResolver()
        XCTAssertTrue(fixture.registry.record(
            capabilityRecord(modelID: "cursor/model-a"),
            ompVersion: "99.0.0"
        ))
        let outcome = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/model-a"], selectedRawModel: nil, workspacePath: nil
        ))
        XCTAssertEqual(outcome, .cached)
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.bootstraps, 0)
    }

    func testExplicitSelectionDuringSweepPromotesToFrontInsteadOfSkipping() async throws {
        let fixture = try makeResolver(gateFirstSwitch: true)
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/model-a", "cursor/model-b", "cursor/model-c"],
            selectedRawModel: nil,
            workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().switches == ["cursor/model-a"] }
        let outcome = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-c", workspacePath: nil, manual: false
        )
        XCTAssertEqual(outcome, .enqueued)
        await fixture.client.release()
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let switches = await fixture.client.metrics().switches
        XCTAssertEqual(switches, ["cursor/model-a", "cursor/model-c", "cursor/model-b"])
    }

    func testIdleExplicitSelectionRunsSingleTargetOnly() async throws {
        let fixture = try makeResolver()
        let outcome = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: false
        )
        XCTAssertEqual(outcome, .enqueued)
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let switches = await fixture.client.metrics().switches
        XCTAssertEqual(switches, ["cursor/model-a"])
    }

    func testManualLoadBypassesModelCooldown() async throws {
        let fixture = try makeResolver(results: ["cursor/model-a": .failed("nope")])
        _ = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: false
        )
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        let cooldownOutcome = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: false
        )
        XCTAssertEqual(cooldownOutcome, .cooldownSkipped)
        let manualOutcome = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: true
        )
        XCTAssertEqual(manualOutcome, .enqueued)
        try await waitUntil { await fixture.client.metrics().disposals == 2 }
    }

    func testWallClockTimeoutExitsLoadingBeforeDisposalFinishes() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.perSwitchSeconds = 0.02
        let fixture = try makeResolver(
            limits: limits,
            gateFirstSwitch: true,
            cancellationDisposalDelay: 0.3
        )
        _ = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: true
        )
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            fixture.resolver.state(for: "cursor/model-a") == .loading
        }
        try await waitUntil(timeoutNanoseconds: 100_000_000) {
            fixture.resolver.state(for: "cursor/model-a") != .loading
        }
        XCTAssertEqual(fixture.resolver.state(for: "cursor/model-a"), .failed)
        let disposalsBeforeCleanup = await fixture.client.metrics().disposals
        XCTAssertEqual(disposalsBeforeCleanup, 0)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await fixture.client.metrics().disposals == 1
        }
    }

    func testCancelOnAvailabilityLossOrVersionChangeResetsQueuedToIdleAndDisposesOnce() async throws {
        for reason in [
            OhMyPiThinkingSweepCancellationReason.availabilityLost,
            .runtimeVersionChanged
        ] {
            let fixture = try makeResolver(gateFirstSwitch: true)
            _ = await fixture.resolver.requestSweep(.init(
                wireIDs: ["cursor/model-a", "cursor/model-b"],
                selectedRawModel: nil,
                workspacePath: nil
            ))
            try await waitUntil { fixture.resolver.state(for: "cursor/model-a") == .loading }
            await fixture.resolver.cancel(reason: reason)
            XCTAssertEqual(fixture.resolver.state(for: "cursor/model-a"), .idle)
            XCTAssertEqual(fixture.resolver.state(for: "cursor/model-b"), .idle)
            let disposals = await fixture.client.metrics().disposals
            XCTAssertEqual(disposals, 1)
        }
    }

    func testSweepStatusReportsMonotonicPartialProgress() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.maxBackgroundTargets = 2
        let fixture = try makeResolver(limits: limits)
        _ = await fixture.resolver.requestSweep(.init(
            wireIDs: ["cursor/a", "cursor/b", "cursor/c"],
            selectedRawModel: nil,
            workspacePath: nil
        ))
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        XCTAssertEqual(fixture.resolver.sweepStatus, .partial(loaded: 2, deferred: 1))
    }

    func testVersionTransitionClearsVisibleUnsupportedStateAndSweepCooldownScope() async throws {
        let version = LockedTestVersion("1.0.0")
        let fixture = try makeResolver(
            results: ["cursor/model-a": .unsupported],
            runtimeVersion: { version.value }
        )
        _ = await fixture.resolver.requestPriority(
            exactModelID: "cursor/model-a", workspacePath: nil, manual: true
        )
        try await waitUntil { await fixture.client.metrics().disposals == 1 }
        XCTAssertEqual(fixture.resolver.state(for: "cursor/model-a"), .unsupported)
        version.value = "2.0.0"
        let outcome = await fixture.resolver.requestSweep(.init(
            wireIDs: [AgentModel.defaultModel.rawValue], selectedRawModel: nil, workspacePath: nil
        ))
        XCTAssertEqual(outcome, .cached)
        XCTAssertEqual(fixture.resolver.state(for: "cursor/model-a"), .idle)
    }

    func testLateRecordFromChangedRuntimeVersionIsDropped() throws {
        let fixture = try makeResolver()
        let runtime = OhMyPiRuntimeVersionRegistry(capabilityRegistry: fixture.registry)
        runtime.observe([99, 0, 0])
        XCTAssertFalse(runtime.recordCapabilityIfCurrent(
            capabilityRecord(modelID: "cursor/model-a"),
            expectedVersion: "98.0.0"
        ))
        XCTAssertNil(fixture.registry.snapshot(for: "cursor/model-a"))
    }

    func testMenuConstructionStartsNoProbe() async throws {
        let fixture = try makeResolver()
        let menu = await MainActor.run {
            StableMenuItem.lazySubmenu(
                AgentProviderKind.ohMyPi.displayName,
                onOpen: {
                    OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(
                        wireIDs: ["cursor/model-a"],
                        selectedRawModel: nil,
                        workspacePath: nil,
                        resolver: fixture.resolver
                    )
                },
                items: {
                    OhMyPiThinkingMenuBuilder.stableMenuItems(
                        exactModelID: "cursor/model-a",
                        destination: ModelDestination(
                            id: "lazy-test",
                            getter: { "cursor/model-a" },
                            applier: { _ in }
                        ),
                        resolver: fixture.resolver
                    )
                }
            )
        }
        _ = menu.submenuItems
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.bootstraps, 0)
    }

    func testControllerSweepShutdownRunsOutsideCancelledTaskScope() async throws {
        let gate = ProbeCancellationGate()
        let recorder = ProbeCancellationRecorder()
        let task = Task {
            await gate.wait()
            await OhMyPiThinkingCapabilityControllerSweepClient.testRunCancellationShieldedShutdown {
                await recorder.record(isCancelled: Task.isCancelled)
            }
        }
        try await waitUntil { await gate.isWaiting }
        task.cancel()
        await gate.release()
        await task.value
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.calls, 1)
        XCTAssertFalse(snapshot.wasCancelled)
    }

    private func makeResolver(
        results: [String: OhMyPiThinkingSwitchResult] = [:],
        limits: OhMyPiThinkingSweepLimits = OhMyPiThinkingSweepLimits(),
        gateFirstSwitch: Bool = false,
        cancellationDisposalDelay: TimeInterval = 0,
        gateAfterFirstSwitch: Bool = false,
        expireBudgetBeforeFirstSwitch: Bool = false,
        runtimeVersion: @escaping @Sendable () -> String? = { "99.0.0" }
    ) throws -> (
        resolver: OhMyPiThinkingCapabilityResolver,
        client: SweepClient,
        registry: OhMyPiThinkingCapabilityRegistry
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let client = SweepClient(
            results: results,
            gateFirstSwitch: gateFirstSwitch,
            cancellationDisposalDelay: cancellationDisposalDelay,
            gateAfterFirstSwitch: gateAfterFirstSwitch,
            expireBudgetBeforeFirstSwitch: expireBudgetBeforeFirstSwitch
        )
        let registry = OhMyPiThinkingCapabilityRegistry(
            store: OhMyPiThinkingCapabilityStore(
                fileURL: directory.appendingPathComponent("capabilities.json")
            )
        )
        return (
            OhMyPiThinkingCapabilityResolver(
                client: client,
                registry: registry,
                statusStore: OhMyPiThinkingCapabilityProbeStatusStore(),
                limits: limits,
                runtimeVersion: runtimeVersion,
                isAvailable: { true }
            ),
            client,
            registry
        )
    }

    private func capabilityRecord(modelID: String) -> OhMyPiThinkingCapabilityRecord {
        OhMyPiThinkingCapabilityRecord(
            modelID: modelID,
            configID: "thinking",
            category: "thought_level",
            orderedOptions: ["off", "high"],
            optionDisplayNames: ["Off", "High"]
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

final class OhMyPiThinkingCapabilityControllerSweepClientTests: XCTestCase {
    func testProductionClientContinuesAfterModelLocalFailureAndKeepsSequentialOrder() async throws {
        let fixture = try makeClient(classifications: ["cursor/b": .modelLocal])
        let events = SweepEventRecorder()
        let targets = SweepTargetQueue(["cursor/a", "cursor/b", "cursor/c"])
        do {
            try await fixture.client.run(
                workspacePath: nil,
                limits: .init(),
                nextTarget: { await targets.next() },
                report: { await events.append($0) }
            )
        } catch { XCTFail("Unexpected abort: \(error)") }
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.models, ["cursor/a", "cursor/b", "cursor/c"])
        XCTAssertEqual(snapshot.shutdowns, 1)
        let terminals = await events.terminals()
        XCTAssertEqual(terminals, [.completed])
    }

    func testProductionClientTripsConsecutiveFailureBreakerAndDisposesOnce() async throws {
        var limits = OhMyPiThinkingSweepLimits()
        limits.consecutiveFailureLimit = 3
        let fixture = try makeClient(classifications: [
            "cursor/a": .modelLocal, "cursor/b": .modelLocal, "cursor/c": .modelLocal
        ])
        let events = SweepEventRecorder()
        let targets = SweepTargetQueue(["cursor/a", "cursor/b", "cursor/c", "cursor/d"])
        do {
            try await fixture.client.run(
                workspacePath: nil, limits: limits,
                nextTarget: { await targets.next() },
                report: { await events.append($0) }
            )
            XCTFail("Expected breaker abort")
        } catch {}
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.models, ["cursor/a", "cursor/b", "cursor/c"])
        XCTAssertEqual(snapshot.shutdowns, 1)
        let terminals = await events.terminals()
        XCTAssertEqual(terminals.count, 1)
    }

    func testProductionClientSessionFatalAbortsBeforeFollowingTargetAndDisposesOnce() async throws {
        let fixture = try makeClient(classifications: ["cursor/a": .sessionFatal])
        let events = SweepEventRecorder()
        let targets = SweepTargetQueue(["cursor/a", "cursor/b"])
        do {
            try await fixture.client.run(
                workspacePath: nil, limits: .init(),
                nextTarget: { await targets.next() },
                report: { await events.append($0) }
            )
            XCTFail("Expected fatal abort")
        } catch {}
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.models, ["cursor/a"])
        XCTAssertEqual(snapshot.shutdowns, 1)
    }

    private func makeClient(
        classifications: [String: OhMyPiThinkingControllerFailureClassification]
    ) throws -> (client: OhMyPiThinkingCapabilityControllerSweepClient, controller: TestSweepController) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-production-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let registry = OhMyPiThinkingCapabilityRegistry(store: .init(fileURL: directory.appendingPathComponent("capabilities.json")))
        let runtime = OhMyPiRuntimeVersionRegistry(capabilityRegistry: registry)
        runtime.observe([99, 0, 0])
        let controller = TestSweepController(classifications: classifications)
        let factory = TestSweepSessionFactory(controller: controller)
        return (
            OhMyPiThinkingCapabilityControllerSweepClient(
                registry: registry,
                runtimeVersionRegistry: runtime,
                sessionFactory: factory,
                isAvailable: { true }
            ),
            controller
        )
    }
}

@MainActor
final class OhMyPiThinkingMenuBuilderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = true
        #endif
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = false
        #endif
        super.tearDown()
    }

    func testRowsPreserveUpstreamOrderDisambiguateDuplicatesAndWarnForStaleValue() {
        let capability = OhMyPiThinkingCapabilitySnapshot(
            modelID: "provider/model",
            configID: "thinking",
            category: "thought_level",
            orderedOptions: [
                .init(value: "off", displayName: "Off"),
                .init(value: "high-a", displayName: "High"),
                .init(value: "high-b", displayName: "High")
            ],
            ompVersion: "17.3.4",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let rows = OhMyPiThinkingMenuBuilder.rows(
            capability: capability,
            probeState: .idle,
            storedChoice: .init(value: "stale", updatedAt: Date(timeIntervalSince1970: 2))
        )

        XCTAssertEqual(
            rows.map(\.title),
            [
                "Default",
                "Off",
                "High (high-a)",
                "High (high-b)",
                "Unavailable: stale"
            ]
        )
        XCTAssertEqual(rows.last?.style, .warning)
        XCTAssertEqual(rows.last?.action, .clearUnavailable)
        XCTAssertTrue(rows.last?.isSelected == true)
    }

    func testUnknownLoadingAndFailedRowsKeepDefaultAndManualLoadAvailable() {
        let unknown = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .idle,
            storedChoice: .init(value: "future", updatedAt: Date())
        )
        XCTAssertEqual(unknown.first?.title, "Default")
        XCTAssertTrue(unknown.first?.isEnabled == true)
        XCTAssertEqual(unknown.last?.action, .load)
        XCTAssertTrue(unknown.last?.isEnabled == true)

        let loading = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .loading,
            storedChoice: nil
        )
        XCTAssertEqual(loading.map(\.title), ["Default", "Loading thinking levels…"])
        XCTAssertTrue(loading.first?.isEnabled == true)
        XCTAssertFalse(loading.last?.isEnabled ?? true)

        let failed = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .failed,
            storedChoice: nil
        )
        XCTAssertEqual(failed.first?.title, "Default")
        XCTAssertTrue(failed.first?.isEnabled == true)
        XCTAssertEqual(failed.last?.action, .load)
    }

    func testQueuedStateRendersDisabledRowAndLoadNow() {
        let rows = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .queued,
            storedChoice: nil
        )
        let queued = rows.first { $0.title == "Queued — loading in background…" }
        XCTAssertEqual(queued?.isEnabled, false)
        XCTAssertEqual(queued?.action, OhMyPiThinkingMenuBuilder.Action.none)
        let loadNow = rows.first { $0.title == "Load now" }
        XCTAssertEqual(loadNow?.isEnabled, true)
        XCTAssertEqual(loadNow?.action, .load)
    }

    func testUnsupportedStateRendersInformationalRowWithoutLoad() {
        let rows = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .unsupported,
            storedChoice: nil
        )
        XCTAssertTrue(rows.contains {
            $0.title == "This model does not advertise thinking levels." && !$0.isEnabled
        })
        XCTAssertFalse(rows.contains { $0.action == .load })
    }

    func testSweepHeaderReflectsRunningPartialFailedCompletedIdle() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertNil(OhMyPiThinkingSweepStatusPresentation.headerText(.idle))
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(
                .running(done: 12, total: 24, current: "cursor/cursor-grok-4.6")
            ),
            "Loading thinking levels… 12/24 · cursor/cursor-grok-4.6"
        )
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(.partial(loaded: 18, deferred: 6)),
            "Loaded 18 · 6 deferred — open this menu again to continue"
        )
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(.failed(reason: "three models", at: now)),
            "Thinking levels: three models — hover away and back to refresh"
        )
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(
                .completed(loaded: 18, failed: 3, unsupported: 2, at: now)
            ),
            "Thinking levels: 3 failed — hover away and back to refresh"
        )
    }

    func testStableAgentSurfaceNestsThinkingUnderEachValidModelNotAsSibling() {
        let models = (0 ..< 203).map {
            AgentModelOption(
                rawValue: "provider/model-\($0)",
                displayName: "Model \($0)",
                description: nil,
                isDefault: false
            )
        }
        var selections = OhMyPiThinkingSelections()
        let destination = ModelDestination(
            id: "menu-test",
            getter: { "provider/model-0" },
            applier: { _ in },
            thinkingGetter: { selections },
            thinkingApplier: { selections = $0 }
        )
        let items = AgentModelStableMenuItems.ohMyPiModelItems(
            options: models,
            selectedAgent: .ohMyPi,
            selectedModelRaw: "provider/model-0",
            thinkingDestination: destination,
            onSelect: { _, _ in }
        )

        let modelLeaves = models.compactMap { model in
            findItem(titled: model.displayName, in: items)
        }
        XCTAssertEqual(modelLeaves.count, 203)
        XCTAssertTrue(modelLeaves.allSatisfy { $0.submenuItems?.first?.title == "Default" })
        XCTAssertEqual(countTitle("Thinking", in: items), 0)
    }

    func testStableAgentSurfaceUsesPerLeafThinkingAccessoryAndPreservesStandaloneBehavior() throws {
        let rootRaw = "root-high"
        let googleRaw = "google-antigravity/gemini-3.7-flash"
        let familyDefaultRaw = "cursor/cursor-grok-4.6"
        let familyHighRaw = "cursor/cursor-grok-4.6-high"
        let fastXHighRaw = "cursor/cursor-grok-4.6-xhigh-fast"
        let sparseFastDefaultRaw = "provider/sparse-fast"
        let sparseFastLowRaw = "provider/sparse-low-fast"
        let rawModels = [
            rootRaw,
            googleRaw,
            familyDefaultRaw,
            "cursor/cursor-grok-4.6-low",
            familyHighRaw,
            "cursor/cursor-grok-4.6-low-fast",
            fastXHighRaw,
            sparseFastDefaultRaw,
            sparseFastLowRaw
        ]
        let options = rawModels.map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isDefault: false
            )
        }
        var selectedRaw = googleRaw
        var selections = OhMyPiThinkingSelections()
        selections.setValue("high", for: rootRaw)
        selections.setValue("high", for: googleRaw)
        selections.setValue("high", for: familyDefaultRaw)
        selections.setValue("low", for: sparseFastDefaultRaw)
        var events: [String] = []
        let destination = ModelDestination(
            id: "agent-family-vs-standalone",
            getter: { selectedRaw },
            applier: { selectedRaw = $0 },
            thinkingGetter: { selections },
            thinkingApplier: {
                selections = $0
                events.append("thinking")
            }
        )
        let onSelect: (AgentProviderKind, AgentModelOption) -> Void = { _, option in
            selectedRaw = option.rawValue
            events.append("model:\(option.rawValue)")
        }
        let items = AgentModelStableMenuItems.ohMyPiModelItems(
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: selectedRaw,
            thinkingDestination: destination,
            onSelect: onSelect
        )

        let rootDefault = try stableMenuItem(at: [rootRaw, "Default"], in: items)
        XCTAssertTrue(rootDefault.performActionForTesting())
        XCTAssertEqual(events, ["model:\(rootRaw)", "thinking"])
        XCTAssertNil(selections[rootRaw])
        XCTAssertEqual(
            selections[googleRaw]?.value,
            "high",
            "Clearing a root standalone leaf must preserve other standalone keys"
        )

        events.removeAll()
        let familyDefault = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "Default"],
            in: items
        )
        let familyHigh = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "High"],
            in: items
        )
        let fastXHigh = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "Fast", "X-High"],
            in: items
        )
        let sparseFastDefault = try stableMenuItem(
            at: ["provider", "sparse", "Fast", "Default"],
            in: items
        )
        let sparseFastLow = try stableMenuItem(
            at: ["provider", "sparse", "Fast", "Low"],
            in: items
        )
        XCTAssertEqual(familyDefault.submenuItems?.first?.title, "Default")
        XCTAssertNil(familyHigh.submenuItems)
        XCTAssertNil(fastXHigh.submenuItems)
        XCTAssertEqual(sparseFastDefault.submenuItems?.first?.title, "Default")
        XCTAssertNil(sparseFastLow.submenuItems)

        let familyThinkingDefault = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "Default", "Default"],
            in: items
        )
        XCTAssertTrue(familyThinkingDefault.performActionForTesting())
        XCTAssertEqual(events, ["model:\(familyDefaultRaw)", "thinking"])
        XCTAssertNil(selections[familyDefaultRaw])
        XCTAssertEqual(selections[googleRaw]?.value, "high")
        XCTAssertEqual(selections[sparseFastDefaultRaw]?.value, "low")

        events.removeAll()
        XCTAssertTrue(familyHigh.performActionForTesting())
        XCTAssertEqual(events, ["model:\(familyHighRaw)"])
        XCTAssertEqual(selections[googleRaw]?.value, "high")

        events.removeAll()
        let googleDefault = try stableMenuItem(
            at: ["google-antigravity", "gemini-3.7-flash", "Default"],
            in: items
        )
        XCTAssertTrue(googleDefault.performActionForTesting())
        XCTAssertEqual(events, ["model:\(googleRaw)", "thinking"])
        XCTAssertNil(selections[googleRaw])
    }

    func testStableSettingsSurfaceUsesPerLeafThinkingAccessoryAndPreservesStandaloneBehavior() throws {
        let googleRaw = "google-antigravity/gemini-3.7-flash"
        let familyDefaultRaw = "cursor/cursor-grok-4.6"
        let familyHighRaw = "cursor/cursor-grok-4.6-high"
        let models: [AIModel] = [
            .ohMyPiCustom(name: googleRaw),
            .ohMyPiCustom(name: familyDefaultRaw),
            .ohMyPiCustom(name: "cursor/cursor-grok-4.6-low"),
            .ohMyPiCustom(name: familyHighRaw),
            .ohMyPiCustom(name: "cursor/cursor-grok-4.6-xhigh-fast")
        ]
        let projection = OhMyPiModelMenuBuilder.projection(for: models)
        let googleTitle = try XCTUnwrap(
            projection.namespaceGroups
                .first { $0.namespace == "google-antigravity" }?
                .modelGroups.first?.normalLeaves.first?.title
        )
        var selectedModel = models[0]
        var selections = OhMyPiThinkingSelections()
        selections.setValue("high", for: googleRaw)
        var events: [String] = []
        let destination = ModelDestination(
            id: "settings-family-vs-standalone",
            getter: { selectedModel.rawValue },
            applier: { _ in },
            thinkingGetter: { selections },
            thinkingApplier: {
                selections = $0
                events.append("thinking")
            }
        )
        let items = OhMyPiModelMenuBuilder.stableMenuItems(
            for: models,
            destination: destination
        ) { model in
            selectedModel = model
            events.append("model:\(model.modelName)")
        }

        let familyDefault = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "Default"],
            in: items
        )
        let familyHigh = try stableMenuItem(
            at: ["cursor", "cursor-grok-4.6", "High"],
            in: items
        )
        XCTAssertEqual(familyDefault.submenuItems?.first?.title, "Default")
        XCTAssertNil(familyHigh.submenuItems)
        XCTAssertTrue(familyHigh.performActionForTesting())
        XCTAssertEqual(events, ["model:\(familyHighRaw)"])

        events.removeAll()
        let googleDefault = try stableMenuItem(
            at: ["google-antigravity", googleTitle, "Default"],
            in: items
        )
        XCTAssertTrue(googleDefault.performActionForTesting())
        XCTAssertEqual(events, ["model:\(googleRaw)", "thinking"])
        XCTAssertNil(selections[googleRaw])
    }

    func testPositionHCollapsesSingletonDefaultBranchesAcrossAgentAndSettingsSurfaces() throws {
        let rawModels = [
            "cursor/cursor-grok-4.6",
            "cursor/cursor-grok-4.6-fast"
        ]
        let options = rawModels.map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isDefault: false
            )
        }
        let projection = OhMyPiModelMenuProjector.project(options.map {
            .init(sourceID: $0.rawValue, wireID: $0.rawValue, displayName: $0.displayName)
        })
        let cursor = try XCTUnwrap(projection.namespaceGroups.first { $0.namespace == "cursor" })
        let family = try XCTUnwrap(cursor.modelGroups.first { $0.title == "cursor-grok-4.6" })
        XCTAssertTrue(family.isFamily)
        XCTAssertEqual(family.normalLeaves.map(\.wireID), [rawModels[0]])
        XCTAssertEqual(family.fastLeaves.map(\.wireID), [rawModels[1]])
        XCTAssertTrue(family.allLeaves.allSatisfy { $0.effort == nil && $0.allowsThinkingAccessory })

        var selectedRaw = rawModels[0]
        var selections = OhMyPiThinkingSelections()
        let destination = ModelDestination(
            id: "collapsed-grok-pair",
            getter: { selectedRaw },
            applier: { selectedRaw = $0 },
            thinkingGetter: { selections },
            thinkingApplier: { selections = $0 }
        )
        let agentItems = AgentModelStableMenuItems.ohMyPiModelItems(
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: selectedRaw,
            thinkingDestination: destination,
            onSelect: { _, option in selectedRaw = option.rawValue }
        )
        let agentCursor = try stableMenuItem(at: ["cursor"], in: agentItems)
        XCTAssertEqual(
            agentCursor.submenuItems?.map(\.title),
            ["cursor-grok-4.6", "cursor-grok-4.6 Fast"]
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6"], in: agentItems)
                .submenuItems?.first?.title,
            "Default"
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6 Fast"], in: agentItems)
                .submenuItems?.first?.title,
            "Default"
        )

        let models = rawModels.map(AIModel.ohMyPiCustom(name:))
        let settingsItems = OhMyPiModelMenuBuilder.stableMenuItems(
            for: models,
            destination: destination,
            onModelCommit: { selectedRaw = $0.modelName }
        )
        let settingsCursor = try stableMenuItem(at: ["cursor"], in: settingsItems)
        XCTAssertEqual(
            settingsCursor.submenuItems?.map(\.title),
            ["cursor-grok-4.6", "cursor-grok-4.6 Fast"]
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6"], in: settingsItems)
                .submenuItems?.first?.title,
            "Default"
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6 Fast"], in: settingsItems)
                .submenuItems?.first?.title,
            "Default"
        )
    }

    func testContextBuilderSurfaceNestsThinkingUnderValidLeavesEvenWhenSelectedAgentIsNonOMP() throws {
        let rawModel = "provider/context-builder-model"
        let surface = try makeContextBuilderSurface(
            selectedModelRaw: rawModel,
            selectedCurrentAgent: .codexExec
        )
        defer { surface.cleanup() }

        let items = surface.viewModel.contextBuilderAgentModelMenuItems(windowID: -701)
        let ompMenu = try XCTUnwrap(items.first { $0.title == AgentProviderKind.ohMyPi.displayName })
        let validLeaf = try XCTUnwrap(
            findItem(titled: "Context Builder Model", in: ompMenu.submenuItems ?? [])
        )

        XCTAssertEqual(surface.viewModel.selectedContextBuilderAgent, .codexExec)
        XCTAssertEqual(validLeaf.submenuItems?.first?.title, "Default")
        XCTAssertEqual(countTitle("Thinking", in: items), 0)
    }

    func testRoleDefaultMenuExposesThinkingForOMPLeafAndCommitsExactModelFirst() throws {
        let rawModel = "provider/context-builder-model"
        let surface = try makeContextBuilderSurface(
            selectedModelRaw: rawModel,
            selectedCurrentAgent: .codexExec
        )
        defer { surface.cleanup() }
        let resolution = try XCTUnwrap(
            surface.viewModel.roleDefaultsResolutions.first { $0.role == .explore }
        )
        XCTAssertNotEqual(resolution.effective.agent, .ohMyPi)
        var stored = OhMyPiThinkingSelections()
        stored.setValue("high", for: rawModel)
        MCPAgentRoleDefaultsService.setRoleOhMyPiThinkingSelections(
            stored,
            for: resolution.role,
            scope: .global,
            settingsStore: surface.store
        )

        let items = surface.viewModel.roleDefaultMenuItems(for: resolution)
        let ompMenu = try XCTUnwrap(items.first { $0.title == AgentProviderKind.ohMyPi.displayName })
        let validLeaf = try XCTUnwrap(
            findItem(titled: "Context Builder Model", in: ompMenu.submenuItems ?? [])
        )
        let defaultThinking = try XCTUnwrap(validLeaf.submenuItems?.first)
        XCTAssertEqual(defaultThinking.title, "Default")

        XCTAssertTrue(defaultThinking.performActionForTesting())
        let profile = surface.store.globalAgentModelsProfile()
        XCTAssertEqual(
            profile.mcpAgentRoleOverrides?[resolution.role.rawValue],
            AgentModelSelectionID(
                agentRaw: AgentProviderKind.ohMyPi.rawValue,
                modelRaw: rawModel
            ).rawValue,
            "Thinking children must commit their exact OMP leaf before writing role thinking"
        )
        XCTAssertNil(
            profile.mcpAgentRoleOhMyPiThinkingSelections?[resolution.role.rawValue]?[rawModel]
        )
    }

    func testRoleThinkingMenuUsesFreshWorkspaceScopeForModelAndThinkingWrites() throws {
        let rawModel = "provider/context-builder-model"
        let surface = try makeContextBuilderSurface(
            selectedModelRaw: rawModel,
            selectedCurrentAgent: .codexExec
        )
        defer { surface.cleanup() }
        let role = AgentModelCatalog.TaskLabelKind.explore
        var globalThinking = OhMyPiThinkingSelections()
        globalThinking.setValue("high", for: rawModel)
        MCPAgentRoleDefaultsService.setRoleOhMyPiThinkingSelections(
            globalThinking,
            for: role,
            scope: .global,
            settingsStore: surface.store
        )

        let workspaceID = UUID()
        surface.viewModel.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: "Fresh role scope")
        surface.manager.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile()
        )
        surface.manager.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useWorkspaceOverrides
        )

        var profileNotifications: [(scope: String?, workspaceID: UUID?)] = []
        let profileToken = NotificationCenter.default.addObserver(
            forName: .agentModelsSettingsDidChange,
            object: surface.store,
            queue: nil
        ) { notification in
            profileNotifications.append((
                notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
                notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
            ))
        }
        defer { NotificationCenter.default.removeObserver(profileToken) }
        var roleChangeNotifications = 0
        let roleToken = NotificationCenter.default.addObserver(
            forName: .recommendationsShouldRefresh,
            object: nil,
            queue: nil
        ) { notification in
            if notification.userInfo?["reason"] as? String == "agentRoleDefaultsChanged" {
                roleChangeNotifications += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(roleToken) }

        let resolution = try XCTUnwrap(
            surface.viewModel.roleDefaultsResolutions.first { $0.role == role }
        )
        let items = surface.viewModel.roleDefaultMenuItems(for: resolution)
        let ompMenu = try XCTUnwrap(items.first { $0.title == AgentProviderKind.ohMyPi.displayName })
        let validLeaf = try XCTUnwrap(
            findItem(titled: "Context Builder Model", in: ompMenu.submenuItems ?? [])
        )
        let defaultThinking = try XCTUnwrap(validLeaf.submenuItems?.first)
        XCTAssertEqual(defaultThinking.title, "Default")
        XCTAssertTrue(defaultThinking.performActionForTesting())

        XCTAssertEqual(
            surface.store.globalAgentModelsProfile()
                .mcpAgentRoleOhMyPiThinkingSelections?[role.rawValue],
            globalThinking,
            "A stale cached global scope must not receive the thinking half of a workspace action"
        )
        XCTAssertEqual(
            surface.store.workspaceAgentModelsProfile(for: workspaceID)?
                .mcpAgentRoleOverrides?[role.rawValue],
            AgentModelSelectionID(
                agentRaw: AgentProviderKind.ohMyPi.rawValue,
                modelRaw: rawModel
            ).rawValue
        )
        XCTAssertNil(
            surface.store.workspaceAgentModelsProfile(for: workspaceID)?
                .mcpAgentRoleOhMyPiThinkingSelections?[role.rawValue]
        )
        XCTAssertEqual(profileNotifications.count, 2, "Exact-model commit and thinking apply must each persist once")
        XCTAssertTrue(profileNotifications.allSatisfy {
            $0.scope == AgentModelsSettingsNotification.Scope.workspace.rawValue
                && $0.workspaceID == workspaceID
        })
        XCTAssertEqual(roleChangeNotifications, 2)
    }

    func testThinkingSubmenuAbsentForPlaceholderModel() throws {
        let surface = try makeContextBuilderSurface(
            selectedModelRaw: AgentModel.defaultModel.rawValue
        )
        defer { surface.cleanup() }

        let items = surface.viewModel.contextBuilderAgentModelMenuItems(windowID: -702)
        let ompMenu = try XCTUnwrap(items.first { $0.title == AgentProviderKind.ohMyPi.displayName })
        let ompItems = try XCTUnwrap(ompMenu.submenuItems)
        let placeholder = try XCTUnwrap(ompItems.first { $0.title == "Default" })
        let validLeaf = try XCTUnwrap(
            findItem(titled: "Context Builder Model", in: ompItems)
        )

        XCTAssertNil(placeholder.submenuItems, "The literal provider default must remain an action leaf")
        XCTAssertEqual(validLeaf.submenuItems?.first?.title, "Default")
        XCTAssertEqual(countTitle("Thinking", in: items), 0)
    }

    func testThinkingSelectionCommitsModelBeforeApplyRejectsFailedCommitAndLoadSkipsCommit() throws {
        let rawModel = "provider/composite-model"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-composite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capabilityRegistry = OhMyPiThinkingCapabilityRegistry(
            store: OhMyPiThinkingCapabilityStore(
                fileURL: directory.appendingPathComponent("capabilities.json")
            )
        )
        XCTAssertTrue(capabilityRegistry.record(
            OhMyPiThinkingCapabilityRecord(
                modelID: rawModel,
                configID: "thinking",
                category: "thought_level",
                orderedOptions: ["off", "high"],
                optionDisplayNames: ["Off", "High"]
            ),
            ompVersion: "99.0.0"
        ))

        var events: [String] = []
        var selections = OhMyPiThinkingSelections()
        let destination = ModelDestination(
            id: "composite-menu-test",
            getter: { rawModel },
            applier: { _ in },
            thinkingGetter: { selections },
            thinkingApplier: {
                selections = $0
                events.append("thinking")
            }
        )

        let high = try XCTUnwrap(OhMyPiThinkingMenuBuilder.rows(
            capability: capabilityRegistry.snapshot(for: rawModel),
            probeState: .idle,
            storedChoice: nil
        ).first { $0.title == "High" })
        OhMyPiThinkingMenuBuilder.perform(
            high,
            exactModelID: rawModel,
            destination: destination,
            onBeforeApply: {
                events.append("model")
                return true
            }
        )
        XCTAssertEqual(events, ["model", "thinking"])
        XCTAssertEqual(selections[rawModel]?.value, "high")

        events.removeAll()
        let rejectedItems = OhMyPiThinkingMenuBuilder.stableMenuItems(
            exactModelID: rawModel,
            destination: destination,
            registry: capabilityRegistry,
            onBeforeApply: {
                events.append("model-rejected")
                return false
            }
        )
        let defaultItem = try XCTUnwrap(rejectedItems.first { $0.title == "Default" })
        XCTAssertTrue(defaultItem.performActionForTesting())
        XCTAssertEqual(events, ["model-rejected"])
        XCTAssertEqual(selections[rawModel]?.value, "high")

        let emptyRegistry = OhMyPiThinkingCapabilityRegistry(
            store: OhMyPiThinkingCapabilityStore(
                fileURL: directory.appendingPathComponent("empty-capabilities.json")
            )
        )
        let resolver = OhMyPiThinkingCapabilityResolver(
            client: SweepClient(results: [rawModel: .failed("fixture failure")]),
            registry: capabilityRegistry,
            statusStore: OhMyPiThinkingCapabilityProbeStatusStore(),
            runtimeVersion: { "99.0.0" }
        )
        events.removeAll()
        let unknownItems = OhMyPiThinkingMenuBuilder.stableMenuItems(
            exactModelID: rawModel,
            destination: destination,
            registry: emptyRegistry,
            resolver: resolver,
            onBeforeApply: {
                events.append("unexpected-model-commit")
                return true
            }
        )
        let load = try XCTUnwrap(unknownItems.first { $0.title == "Load thinking levels…" })
        XCTAssertTrue(load.performActionForTesting())
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(selections[rawModel]?.value, "high")
    }

    func testReopenedThinkingMenuReflectsNewlyLearnedCapabilities() throws {
        let rawModel = "provider/reopened-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = OhMyPiThinkingCapabilityRegistry(
            store: OhMyPiThinkingCapabilityStore(
                fileURL: directory.appendingPathComponent("capabilities.json")
            )
        )
        let destination = contextBuilderDestination(rawModel: rawModel)
        let buildItems = {
            OhMyPiThinkingMenuBuilder.stableMenuItems(
                exactModelID: rawModel,
                destination: destination,
                registry: registry
            )
        }

        XCTAssertFalse(buildItems().contains { $0.title == "High" })
        XCTAssertTrue(registry.record(
            OhMyPiThinkingCapabilityRecord(
                modelID: rawModel,
                configID: "thinking",
                category: "thought_level",
                orderedOptions: ["off", "high"],
                optionDisplayNames: ["Off", "High"]
            ),
            ompVersion: "99.0.0"
        ))
        XCTAssertTrue(buildItems().contains { $0.title == "High" })
    }

    private func contextBuilderDestination(rawModel: String) -> ModelDestination {
        var selections = OhMyPiThinkingSelections()
        return ModelDestination(
            id: "contextBuilderAgentModel",
            getter: { rawModel },
            applier: { _ in },
            thinkingGetter: { selections },
            thinkingApplier: { selections = $0 }
        )
    }

    private func makeContextBuilderSurface(
        selectedModelRaw: String,
        selectedCurrentAgent: AgentProviderKind = .ohMyPi
    ) throws -> (
        viewModel: AgentModelsSettingsViewModel,
        store: GlobalSettingsStore,
        manager: WindowSettingsManager,
        cleanup: () -> Void
    ) {
        let discoveredRaw = OhMyPiCanonicalModelIdentity.exactWireID(for: selectedModelRaw)
            ?? "provider/context-builder-catalog-model"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: discoveredRaw,
                        displayName: "Context Builder Model",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: discoveredRaw
            ),
            for: .ohMyPi
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "OhMyPiThinkingMenuBuilderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = try GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: directory.appendingPathComponent("globalSettings.json")
            )
        )
        var contextBuilderModelsByAgent = [
            AgentProviderKind.ohMyPi.rawValue: selectedModelRaw
        ]
        if selectedCurrentAgent != .ohMyPi {
            contextBuilderModelsByAgent[selectedCurrentAgent.rawValue] = AgentModel.defaultModel.rawValue
        }
        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: selectedCurrentAgent.rawValue,
                contextBuilderModelsByAgent: contextBuilderModelsByAgent
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.isOhMyPiConnected = true
        if selectedCurrentAgent == .codexExec {
            apiSettings.isCodexConnected = true
        }
        let manager = WindowSettingsManager(windowID: -700, store: store)
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            settingsManager: manager,
            settingsStore: store
        )
        return (
            viewModel,
            store,
            manager,
            {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    private func stableMenuItem(at path: [String], in items: [StableMenuItem]) throws -> StableMenuItem {
        var currentItems = items
        var currentItem: StableMenuItem?
        for title in path {
            currentItem = currentItems.first { $0.title == title }
            let item = try XCTUnwrap(
                currentItem,
                "Missing menu path component \(title); available: \(currentItems.map(\.title))"
            )
            currentItems = item.submenuItems ?? []
        }
        return try XCTUnwrap(currentItem)
    }

    private func findItem(titled title: String, in items: [StableMenuItem]) -> StableMenuItem? {
        for item in items {
            if item.title == title {
                return item
            }
            if let match = findItem(titled: title, in: item.submenuItems ?? []) {
                return match
            }
        }
        return nil
    }

    private func countTitle(_ title: String, in items: [StableMenuItem]) -> Int {
        items.reduce(0) { count, item in
            count + (item.title == title ? 1 : 0)
                + countTitle(title, in: item.submenuItems ?? [])
        }
    }
}

private final class LockedTestVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) {
        stored = value
    }

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private enum TestSweepError: Error { case model }

private actor TestSweepController: OhMyPiThinkingCapabilitySweepController {
    struct Snapshot { let models: [String]
        let shutdowns: Int
    }

    private let classifications: [String: OhMyPiThinkingControllerFailureClassification]
    private var models: [String] = []
    private var shutdowns = 0

    init(classifications: [String: OhMyPiThinkingControllerFailureClassification]) {
        self.classifications = classifications
    }

    func start() async throws {}
    func setSessionModel(_ modelID: String) async throws {
        models.append(modelID)
        if classifications[modelID] != nil { throw TestSweepError.model }
    }

    func normalizedErrorDescription(_: Error) async -> String {
        "fixture failure"
    }

    func classifyConfigurationMutationFailure(_: Error) async -> OhMyPiThinkingControllerFailureClassification {
        classifications[models.last ?? ""] ?? .modelLocal
    }

    func shutdown() async {
        shutdowns += 1
    }

    func snapshot() -> Snapshot {
        .init(models: models, shutdowns: shutdowns)
    }
}

private struct TestSweepPreparedSession: OhMyPiThinkingCapabilityPreparedSession {
    let ompVersion = "99.0.0"
    let controller: TestSweepController
    func makeController(publisher _: @escaping OhMyPiThinkingCapabilityPublisher) throws -> any OhMyPiThinkingCapabilitySweepController {
        controller
    }
}

private struct TestSweepSessionFactory: OhMyPiThinkingCapabilitySessionFactory {
    let controller: TestSweepController
    func prepare(workspacePath _: String?, limits _: OhMyPiThinkingSweepLimits) async throws -> any OhMyPiThinkingCapabilityPreparedSession {
        TestSweepPreparedSession(controller: controller)
    }
}

private actor SweepEventRecorder {
    private var values: [OhMyPiThinkingSweepEvent] = []
    func append(_ event: OhMyPiThinkingSweepEvent) {
        values.append(event)
    }

    func terminals() -> [OhMyPiThinkingSweepTerminal] {
        values.compactMap { if case let .terminal(value) = $0 { value } else { nil } }
    }
}

private actor SweepTargetQueue {
    private var values: [String]
    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        values.isEmpty ? nil : values.removeFirst()
    }
}

private actor ProbeCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ProbeCancellationRecorder {
    private var calls = 0
    private var wasCancelled = false

    func record(isCancelled: Bool) {
        calls += 1
        wasCancelled = isCancelled
    }

    func snapshot() -> (calls: Int, wasCancelled: Bool) {
        (calls, wasCancelled)
    }
}

private actor SweepClient: OhMyPiThinkingCapabilitySweepClient {
    struct Metrics {
        let bootstraps: Int
        let switches: [String]
        let activeSwitches: Int
        let maximumActiveSwitches: Int
        let disposals: Int
    }

    private let results: [String: OhMyPiThinkingSwitchResult]
    private let gateFirstSwitch: Bool
    private let cancellationDisposalDelay: TimeInterval
    private let gateAfterFirstSwitch: Bool
    private let expireBudgetBeforeFirstSwitch: Bool
    private var released = false
    private var bootstraps = 0
    private var switches: [String] = []
    private var activeSwitches = 0
    private var maximumActiveSwitches = 0
    private var disposals = 0

    init(
        results: [String: OhMyPiThinkingSwitchResult] = [:],
        gateFirstSwitch: Bool = false,
        cancellationDisposalDelay: TimeInterval = 0,
        gateAfterFirstSwitch: Bool = false,
        expireBudgetBeforeFirstSwitch: Bool = false
    ) {
        self.results = results
        self.gateFirstSwitch = gateFirstSwitch
        self.cancellationDisposalDelay = cancellationDisposalDelay
        self.gateAfterFirstSwitch = gateAfterFirstSwitch
        self.expireBudgetBeforeFirstSwitch = expireBudgetBeforeFirstSwitch
    }

    func run(
        workspacePath _: String?,
        limits _: OhMyPiThinkingSweepLimits,
        nextTarget: @escaping @Sendable () async -> String?,
        report: @escaping @Sendable (OhMyPiThinkingSweepEvent) async -> Void
    ) async throws {
        bootstraps += 1
        await report(.bootstrapped(ompVersion: "99.0.0"))
        do {
            while let modelID = await nextTarget() {
                switches.append(modelID)
                activeSwitches += 1
                maximumActiveSwitches = max(maximumActiveSwitches, activeSwitches)
                if expireBudgetBeforeFirstSwitch, bootstraps == 1, switches.count == 1 {
                    await report(.terminal(.workBudgetExpired(current: modelID)))
                    throw OhMyPiThinkingSweepAbort.terminal(.workBudgetExpired(current: modelID))
                }
                await report(.willSwitch(modelID))
                if gateFirstSwitch, switches.count == 1 {
                    while !released {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
                let result = results[modelID] ?? .loaded
                await report(.switched(modelID, result, elapsed: 0.001))
                activeSwitches -= 1
                if gateAfterFirstSwitch, switches.count == 1 {
                    while !released {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
            }
            await report(.terminal(.completed))
        } catch {
            await report(.terminal(.cancelled(.availabilityLost)))
            activeSwitches = max(0, activeSwitches - 1)
            let disposalDelay = cancellationDisposalDelay
            if disposalDelay > 0 {
                await Task.detached {
                    try? await Task.sleep(
                        nanoseconds: UInt64(disposalDelay * 1_000_000_000)
                    )
                }.value
            }
            disposals += 1
            throw error
        }
        disposals += 1
    }

    func release() {
        released = true
    }

    func metrics() -> Metrics {
        Metrics(
            bootstraps: bootstraps,
            switches: switches,
            activeSwitches: activeSwitches,
            maximumActiveSwitches: maximumActiveSwitches,
            disposals: disposals
        )
    }
}
