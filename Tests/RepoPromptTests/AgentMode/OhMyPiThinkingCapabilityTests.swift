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
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
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

    func testStableAgentSurfaceThinkingChildCommitsItsExactLeafAcrossProjectionShapes() throws {
        let scenarios: [(rawModel: String, path: [String])] = [
            ("root-high", ["root-high", "Default"]),
            (
                "google-antigravity/gemini-3.7-flash",
                ["google-antigravity", "gemini-3.7-flash", "Default"]
            ),
            (
                "cursor/gpt-5.6-sol-high",
                ["cursor", "gpt-5.6-sol", "High", "Default"]
            )
        ]
        var models = scenarios.map { scenario in
            AgentModelOption(
                rawValue: scenario.rawModel,
                displayName: scenario.rawModel,
                description: nil,
                isDefault: false
            )
        }
        models.append(AgentModelOption(
            rawValue: "cursor/gpt-5.6-sol-low",
            displayName: "cursor/gpt-5.6-sol-low",
            description: nil,
            isDefault: false
        ))
        var selectedRaw = scenarios[0].rawModel
        var committedRaws: [String] = []
        var appliedKeys: [String] = []
        var selections = OhMyPiThinkingSelections()
        let destination = ModelDestination(
            id: "exact-leaf-menu-test",
            getter: { selectedRaw },
            applier: { selectedRaw = $0 },
            thinkingGetter: { selections },
            thinkingApplier: { updatedSelections in
                let removedKeys = Set(selections.entries.keys)
                    .subtracting(updatedSelections.entries.keys)
                appliedKeys.append(contentsOf: removedKeys)
                selections = updatedSelections
            }
        )

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.rawModel) { _ in
                selections = OhMyPiThinkingSelections()
                for candidate in scenarios {
                    selections.setValue("high", for: candidate.rawModel, updatedAt: Date(timeIntervalSince1970: 1))
                }
                selectedRaw = scenario.rawModel
                committedRaws.removeAll()
                appliedKeys.removeAll()

                let commitSelection: (AgentProviderKind, AgentModelOption) -> Void = { agent, option in
                    XCTAssertEqual(agent, .ohMyPi)
                    committedRaws.append(option.rawValue)
                    selectedRaw = option.rawValue
                }
                let items = AgentModelStableMenuItems.ohMyPiModelItems(
                    options: models,
                    selectedAgent: .ohMyPi,
                    selectedModelRaw: selectedRaw,
                    thinkingDestination: destination,
                    onSelect: commitSelection
                )
                let child = try stableMenuItem(at: scenario.path, in: items)

                XCTAssertTrue(child.performActionForTesting())
                XCTAssertEqual(committedRaws, [scenario.rawModel])
                XCTAssertEqual(appliedKeys, [scenario.rawModel])
                XCTAssertNil(selections[scenario.rawModel])
                XCTAssertTrue(
                    scenarios.filter { $0.rawModel != scenario.rawModel }
                        .allSatisfy { selections[$0.rawModel]?.value == "high" }
                )
            }
        }
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
            client: ProbeClient(behavior: .failure),
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
        let viewModel = AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettings,
            settingsManager: WindowSettingsManager(windowID: -700, store: store),
            settingsStore: store
        )
        return (
            viewModel,
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
