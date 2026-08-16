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
    func testCacheFirstAvoidsProbe() async throws {
        let fixture = try makeResolver(behavior: .success)
        XCTAssertTrue(fixture.registry.record(
            capabilityRecord(modelID: "model-a"),
            ompVersion: "99.0.0"
        ))

        let outcome = await fixture.resolver.resolve(
            exactModelID: "model-a",
            workspacePath: nil,
            manualRetry: false
        )

        let calls = await fixture.client.metrics().calls
        XCTAssertEqual(outcome, .cached)
        XCTAssertEqual(calls, 0)
    }

    func testMenuConstructionStartsNoProbe() async throws {
        let fixture = try makeResolver(behavior: .success)
        await MainActor.run {
            var selections = OhMyPiThinkingSelections()
            let destination = ModelDestination(
                id: "anti-probing",
                getter: { "provider/model-a" },
                applier: { _ in },
                thinkingGetter: { selections },
                thinkingApplier: { selections = $0 }
            )
            let models = [
                AgentModelOption(
                    rawValue: "provider/model-a",
                    displayName: "Model A",
                    description: nil,
                    isDefault: true
                )
            ]
            _ = AgentModelStableMenuItems.ohMyPiModelItems(
                options: models,
                selectedAgent: .ohMyPi,
                selectedModelRaw: "provider/model-a",
                thinkingDestination: destination,
                onSelect: { _, _ in }
            )
            _ = OhMyPiThinkingMenuBuilder.rows(
                capability: nil,
                probeState: fixture.resolver.state(for: "provider/model-a"),
                storedChoice: nil
            )
        }
        let calls = await fixture.client.metrics().calls
        XCTAssertEqual(calls, 0)
    }

    func testExactModelSingleFlightAndNoCrossModelQueue() async throws {
        let fixture = try makeResolver(behavior: .gated)
        let first = Task {
            await fixture.resolver.resolve(
                exactModelID: "model-a",
                workspacePath: nil,
                manualRetry: false
            )
        }
        try await waitUntil { await fixture.client.metrics().calls == 1 }

        let sameModelOutcome = await fixture.resolver.resolve(
            exactModelID: "model-a",
            workspacePath: nil,
            manualRetry: false
        )
        let otherModelOutcome = await fixture.resolver.resolve(
            exactModelID: "model-b",
            workspacePath: nil,
            manualRetry: false
        )
        await fixture.client.release()
        let firstOutcome = await first.value

        XCTAssertEqual(sameModelOutcome, .coalesced)
        XCTAssertEqual(otherModelOutcome, .busySkipped)
        XCTAssertEqual(firstOutcome, .loaded)

        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.calls, 1)
        XCTAssertEqual(metrics.maximumActive, 1)
        XCTAssertEqual(metrics.disposals, 1)
    }

    func testExplicitSelectionTriggerIsFireAndForgetAndOMPOnly() async throws {
        let fixture = try makeResolver(behavior: .gated)

        OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
            agent: .ohMyPi,
            rawModel: "model-a",
            resolver: fixture.resolver
        )
        try await waitUntil { await fixture.client.metrics().calls == 1 }

        OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
            agent: .codexExec,
            rawModel: "model-b",
            resolver: fixture.resolver
        )
        try await Task.sleep(nanoseconds: 5_000_000)
        let callsBeforeRelease = await fixture.client.metrics().calls
        await fixture.client.release()
        try await waitUntil { await fixture.client.metrics().active == 0 }

        XCTAssertEqual(callsBeforeRelease, 1)
    }

    func testCooldownAndManualRetry() async throws {
        let fixture = try makeResolver(behavior: .failure)
        let initialOutcome = await fixture.resolver.resolve(
            exactModelID: "model-a",
            workspacePath: nil,
            manualRetry: false
        )
        let cooldownOutcome = await fixture.resolver.resolve(
            exactModelID: "model-a",
            workspacePath: nil,
            manualRetry: false
        )
        let manualOutcome = await fixture.resolver.resolve(
            exactModelID: "model-a",
            workspacePath: nil,
            manualRetry: true
        )
        let metrics = await fixture.client.metrics()

        XCTAssertEqual(initialOutcome, .failed)
        XCTAssertEqual(cooldownOutcome, .cooldownSkipped)
        XCTAssertEqual(manualOutcome, .failed)
        XCTAssertEqual(metrics.calls, 2)
        XCTAssertEqual(metrics.disposals, 2)
    }

    func testControllerProbeShutdownRunsOutsideCancelledTaskScope() async throws {
        let gate = ProbeCancellationGate()
        let recorder = ProbeCancellationRecorder()
        let task = Task {
            await gate.wait()
            await OhMyPiThinkingCapabilityControllerProbeClient.testRunCancellationShieldedShutdown {
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

    func testProbeDisposesOnSuccessFailureAndDeadlineCancellation() async throws {
        for behavior in [ProbeClient.Behavior.success, .failure, .suspended] {
            let deadline: UInt64 = behavior == .suspended ? 20_000_000 : 1_000_000_000
            let fixture = try makeResolver(
                behavior: behavior,
                deadlineNanoseconds: deadline
            )
            _ = await fixture.resolver.resolve(
                exactModelID: "model-\(behavior)",
                workspacePath: nil,
                manualRetry: true
            )
            let metrics = await fixture.client.metrics()
            XCTAssertEqual(metrics.calls, 1, "\(behavior)")
            XCTAssertEqual(metrics.disposals, 1, "\(behavior)")
            XCTAssertEqual(metrics.active, 0, "\(behavior)")
        }
    }

    private func makeResolver(
        behavior: ProbeClient.Behavior,
        deadlineNanoseconds: UInt64 = 1_000_000_000
    ) throws -> (
        resolver: OhMyPiThinkingCapabilityResolver,
        client: ProbeClient,
        registry: OhMyPiThinkingCapabilityRegistry
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-thinking-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let client = ProbeClient(behavior: behavior)
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
                deadlineNanoseconds: deadlineNanoseconds,
                cooldown: 60,
                runtimeVersion: { "99.0.0" }
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

@MainActor
final class OhMyPiThinkingMenuBuilderTests: XCTestCase {
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
        XCTAssertEqual(unknown.last?.action, .load)
        XCTAssertTrue(unknown.last?.isEnabled == true)

        let loading = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .loading,
            storedChoice: nil
        )
        XCTAssertEqual(loading.map(\.title), ["Default", "Loading thinking levels…"])
        XCTAssertFalse(loading.last?.isEnabled ?? true)

        let failed = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .failed,
            storedChoice: nil
        )
        XCTAssertEqual(failed.last?.action, .load)
    }

    func testStableAgentSurfaceAddsOneThinkingSiblingNotPerModel() {
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

        XCTAssertEqual(countTitle("Thinking", in: items), 1)
        XCTAssertEqual(
            items.last?.title,
            "Thinking"
        )
    }

    private func countTitle(_ title: String, in items: [StableMenuItem]) -> Int {
        items.reduce(0) { count, item in
            count + (item.title == title ? 1 : 0)
                + countTitle(title, in: item.submenuItems ?? [])
        }
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

private actor ProbeClient: OhMyPiThinkingCapabilityProbeClient {
    enum Behavior: CaseIterable, CustomStringConvertible, Equatable {
        case success
        case failure
        case gated
        case suspended

        var description: String {
            switch self {
            case .success: "success"
            case .failure: "failure"
            case .gated: "gated"
            case .suspended: "suspended"
            }
        }
    }

    struct Metrics {
        let calls: Int
        let active: Int
        let maximumActive: Int
        let disposals: Int
    }

    private let behavior: Behavior
    private var isReleased = false
    private var calls = 0
    private var active = 0
    private var maximumActive = 0
    private var disposals = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func probe(exactModelID _: String, workspacePath _: String?) async throws {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer {
            active -= 1
            disposals += 1
        }
        switch behavior {
        case .success:
            return
        case .failure:
            throw ProbeFailure()
        case .gated:
            while !isReleased {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        case .suspended:
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func release() {
        isReleased = true
    }

    func metrics() -> Metrics {
        Metrics(
            calls: calls,
            active: active,
            maximumActive: maximumActive,
            disposals: disposals
        )
    }

    private struct ProbeFailure: Error {}
}
