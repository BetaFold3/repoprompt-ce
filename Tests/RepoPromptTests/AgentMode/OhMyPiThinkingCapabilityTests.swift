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

    func testCollapsedGrokPairKeepsGroupingAndExposesThinkingOnAgentAndSettingsSurfaces() throws {
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
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6", "Default"], in: agentItems)
                .submenuItems?.first?.title,
            "Default"
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6", "Fast", "Default"], in: agentItems)
                .submenuItems?.first?.title,
            "Default"
        )

        let models = rawModels.map(AIModel.ohMyPiCustom(name:))
        let settingsItems = OhMyPiModelMenuBuilder.stableMenuItems(
            for: models,
            destination: destination,
            onModelCommit: { selectedRaw = $0.modelName }
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6", "Default"], in: settingsItems)
                .submenuItems?.first?.title,
            "Default"
        )
        XCTAssertEqual(
            try stableMenuItem(at: ["cursor", "cursor-grok-4.6", "Fast", "Default"], in: settingsItems)
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
