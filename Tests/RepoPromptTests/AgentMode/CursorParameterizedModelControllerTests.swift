import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CursorParameterizedModelControllerTests: XCTestCase {
    private var originalSharedCatalogSnapshot: [String: [CursorModelParameterCatalog.ParameterSpec]] = [:]

    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        originalSharedCatalogSnapshot = CursorModelParameterCatalog.shared.currentSnapshot()
        CursorModelParameterCatalog.shared.test_restoreSnapshot([:])
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        CursorModelParameterCatalog.shared.test_restoreSnapshot(originalSharedCatalogSnapshot)
        super.tearDown()
    }

    func testCapabilityMetadataAndOpenCodeInitializeShape() async throws {
        let enabledProvider = CursorACPAgentProvider(
            config: CursorAgentConfig(enableParameterizedModelPicker: true)
        )
        let disabledProvider = CursorACPAgentProvider(
            config: CursorAgentConfig(enableParameterizedModelPicker: false)
        )
        XCTAssertEqual(enabledProvider.initializeClientCapabilityMetadata, ["parameterizedModelPicker": true])
        XCTAssertTrue(disabledProvider.initializeClientCapabilityMetadata.isEmpty)

        let cursor = try makeFixture(
            shape: "capability",
            metadata: ["parameterizedModelPicker": true],
            providerID: .cursor
        )
        _ = try await cursor.controller.bootstrap()
        await cursor.controller.shutdown()
        let cursorCapabilities = try initializeClientCapabilities(at: cursor.recordURL)
        XCTAssertEqual(
            (cursorCapabilities["_meta"] as? [String: Bool])?["parameterizedModelPicker"],
            true
        )

        let openCode = try makeFixture(shape: "capability", providerID: .openCode)
        _ = try await openCode.controller.bootstrap()
        try await openCode.controller.setSessionMode("plan")
        await openCode.controller.shutdown()
        let openCodeCapabilities = try initializeClientCapabilities(at: openCode.recordURL)
        XCTAssertNil(openCodeCapabilities["_meta"])
        XCTAssertEqual(
            mutationPairs(at: openCode.recordURL),
            [Mutation(configID: "mode", value: "plan")]
        )
    }

    func testDecompositionOrderIdempotencyAndParamsOnlyReconciliation() async throws {
        do {
            let fixture = try makeFixture(
                shape: "capability",
                initialModel: "default",
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel(
                "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
            )
            await fixture.controller.shutdown()

            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [
                    Mutation(configID: "model", value: "gpt-5.6-sol"),
                    Mutation(configID: "context", value: "1m"),
                    Mutation(configID: "reasoning", value: "high"),
                    Mutation(configID: "fast", value: "true")
                ]
            )
        }

        do {
            let fixture = try makeFixture(shape: "capability", providerID: .cursor)
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel(
                "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
            )
            await fixture.controller.shutdown()
            XCTAssertTrue(mutationPairs(at: fixture.recordURL).isEmpty)
        }

        do {
            let fixture = try makeFixture(shape: "capability", providerID: .cursor)
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel(
                "gpt-5.6-sol[context=272k,reasoning=high,fast=false]"
            )
            await fixture.controller.shutdown()
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [Mutation(configID: "reasoning", value: "high")]
            )
        }
    }

    func testValidationEchoAndRollbackFailureSemantics() async throws {
        for invalid in [
            (
                selection: "gpt-5.6-sol[unknown=on]",
                error: "does not advertise parameter selector 'unknown'"
            ),
            (
                selection: "gpt-5.6-sol[reasoning=bogus]",
                error: "Valid values:"
            )
        ] {
            let fixture = try makeFixture(shape: "capability", providerID: .cursor)
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: invalid.error) {
                try await fixture.controller.setSessionModel(invalid.selection)
            }
            await fixture.controller.shutdown()
            XCTAssertTrue(mutationPairs(at: fixture.recordURL).isEmpty, invalid.selection)
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_REJECT_CONFIG_ID": "reasoning"],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "Invalid value for reasoning: high") {
                try await fixture.controller.setSessionModel(
                    "gpt-5.6-sol[context=1m,reasoning=high]"
                )
            }
            await fixture.controller.shutdown()
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [
                    Mutation(configID: "context", value: "1m"),
                    Mutation(configID: "reasoning", value: "high"),
                    Mutation(configID: "context", value: "272k")
                ]
            )
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: [
                    "ACP_REJECT_CONFIG_ID": "reasoning",
                    "ACP_REJECT_ROLLBACK_CONFIG_ID": "context"
                ],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "cursor-agent may retain partial model configuration: context=1m") {
                try await fixture.controller.setSessionModel(
                    "gpt-5.6-sol[context=1m,reasoning=high]"
                )
            }
            await fixture.controller.shutdown()
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_ECHO_MISMATCH_CONFIG_ID": "reasoning"],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "ACP protocol violation") {
                try await fixture.controller.setSessionModel(
                    "gpt-5.6-sol[reasoning=high]"
                )
            }
            await fixture.controller.shutdown()
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [
                    Mutation(configID: "reasoning", value: "high"),
                    Mutation(configID: "reasoning", value: "medium")
                ]
            )
        }
    }

    func testPostModelWriteFailureRestoresPriorModelAndReportsRestoreFailure() async throws {
        do {
            let fixture = try makeFixture(
                shape: "capability",
                initialModel: "default",
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "does not advertise parameter selector 'unknown'") {
                try await fixture.controller.setSessionModel("gpt-5.6-sol[unknown=on]")
            }
            await fixture.controller.shutdown()

            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [
                    Mutation(configID: "model", value: "gpt-5.6-sol"),
                    Mutation(configID: "model", value: "default")
                ]
            )
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                initialModel: "default",
                extraEnvironment: ["ACP_REJECT_MODEL_ROLLBACK_VALUE": "default"],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "cursor-agent may retain partial model configuration: model=gpt-5.6-sol") {
                try await fixture.controller.setSessionModel("gpt-5.6-sol[unknown=on]")
            }
            await fixture.controller.shutdown()

            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [
                    Mutation(configID: "model", value: "gpt-5.6-sol"),
                    Mutation(configID: "model", value: "default")
                ]
            )
        }
    }

    func testNotificationMorphAndDEBUGParameterPostcheck() async throws {
        do {
            let diagnostics = LockedCursorStrings()
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_MORPH_AFTER_CONFIG_ID": "reasoning"],
                diagnostics: diagnostics,
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel("gpt-5.6-sol[reasoning=high]")
            _ = try await fixture.controller.sendProviderExtensionRequest(
                method: "test/flush_config_notification",
                params: [:],
                timeoutSeconds: 1
            )
            try await diagnostics.waitUntil("selector morph notification") {
                $0.contains { $0.contains("Processed authoritative config_option_update snapshot.") }
            }
            await assertThrows(containing: "does not advertise parameter selector 'context'") {
                try await fixture.controller.setSessionModel("gpt-5.2[context=1m]")
            }
            await fixture.controller.shutdown()
        }

        #if DEBUG
            do {
                let diagnostics = LockedCursorStrings()
                let fixture = try makeFixture(
                    shape: "capability",
                    extraEnvironment: ["ACP_REVERT_NOTIFICATION_CONFIG_ID": "reasoning"],
                    diagnostics: diagnostics,
                    providerID: .cursor
                )
                _ = try await fixture.controller.bootstrap()
                await fixture.controller.debugSuspendNextConfigurationMutationPostcheck()
                addTeardownBlock {
                    await fixture.controller.debugResumeConfigurationMutationPostcheck()
                }
                let task = Task {
                    try await fixture.controller.setSessionModel("gpt-5.6-sol[reasoning=high]")
                }
                try await AsyncTestWait.waitUntil("parameter postcheck suspension") {
                    await fixture.controller.debugIsConfigurationMutationPostcheckSuspended()
                }
                try await diagnostics.waitUntil("parameter revert notification") {
                    $0.contains { $0.contains("Processed authoritative config_option_update snapshot.") }
                }
                await fixture.controller.debugResumeConfigurationMutationPostcheck()
                await assertThrows(containing: "newer ACP configuration state no longer confirms requested value 'high' for selector 'reasoning'") {
                    try await task.value
                }
                await fixture.controller.shutdown()
            }
        #endif
    }

    func testLegacyAutoKillSwitchAndBareBaseBehavior() async throws {
        let legacyDefault = "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        do {
            let fixture = try makeFixture(
                shape: "legacy",
                initialModel: "default[]",
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel(legacyDefault)
            await fixture.controller.shutdown()
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [Mutation(configID: "model", value: legacyDefault)]
            )
            XCTAssertNil(try initializeClientCapabilities(at: fixture.recordURL)["_meta"])
        }

        do {
            let fixture = try makeFixture(shape: "legacy", providerID: .cursor)
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "does not support parameter selection") {
                try await fixture.controller.setSessionModel(
                    "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
                )
            }
            await fixture.controller.shutdown()
            XCTAssertTrue(mutationPairs(at: fixture.recordURL).isEmpty)
        }

        for shape in ["legacy", "capability"] {
            let fixture = try makeFixture(shape: shape, providerID: .cursor)
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel(AgentModel.cursorAuto.rawValue)
            await fixture.controller.shutdown()
            let expected = shape == "legacy" ? "default[]" : "default"
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [Mutation(configID: "model", value: expected)],
                shape
            )
        }

        do {
            let diagnostics = LockedCursorStrings()
            let results = LockedCursorResults()
            let fixture = try makeFixture(
                shape: "capability",
                initialModel: "default",
                extraEnvironment: ["ACP_FORCE_FAST_AFTER_MODEL": "1"],
                diagnostics: diagnostics,
                providerID: .cursor
            )
            let events = await fixture.controller.currentEventsStream()
            let collector = Task {
                for await event in events {
                    if case let .stream(result) = event {
                        results.append(result)
                    }
                }
            }
            _ = try await fixture.controller.bootstrap()
            try await fixture.controller.setSessionModel("gpt-5.6-sol")
            try await AsyncTestWait.waitUntil("bare-base Fast system event") {
                results.values.contains { $0.type == "system" }
            }
            await fixture.controller.shutdown()
            collector.cancel()

            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [Mutation(configID: "model", value: "gpt-5.6-sol")]
            )
            XCTAssertTrue(diagnostics.values.contains {
                $0.contains("inherited effective parameters") && $0.contains("fast=true")
            })
            XCTAssertEqual(
                results.values.count(where: { $0.type == "system" }),
                1
            )
        }
    }

    @MainActor
    func testRegistryGatesAcceptBracketedAndCleanGenerations() {
        let bracketed = snapshot(rawValue: "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]")
        let clean = snapshot(rawValue: "gpt-5.6-sol")
        let selection = "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"

        for registry in [bracketed, clean] {
            XCTAssertTrue(
                CursorACPHeadlessAgentProvider.registryAllowsSelectedModel(
                    selection,
                    snapshot: registry
                )
            )
            XCTAssertTrue(
                ACPIntegratedAgentModeRunner.cursorRegistryAllowsSelectedModel(
                    selection,
                    snapshot: registry
                )
            )
        }
        XCTAssertTrue(CursorModelRegistryGate.allows(AgentModel.cursorAuto.rawValue, in: nil))
        XCTAssertTrue(CursorModelRegistryGate.allows(selection, in: nil))
        XCTAssertTrue(
            ACPIntegratedAgentModeRunner.cursorRegistryAllowsSelectedModel(selection, snapshot: nil)
        )
        XCTAssertEqual(
            CursorACPHeadlessAgentProvider.selectedModelToApply(config: CursorAgentConfig(
                modelString: selection,
                includeRepoPromptMCPServer: false,
                cleanupProjectMCPApproval: false
            )),
            selection
        )
    }

    @MainActor
    func testCursorExternalModelBypassesCodexEffortExtraction() throws {
        let raw = "cursor:gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
        let extracted = AgentExternalMCPRunStarter.extractReasoningEffort(from: raw)
        XCTAssertEqual(extracted.model, raw)
        XCTAssertNil(extracted.effort)

        let resolved = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: raw,
            reasoningEffortRaw: nil
        )
        XCTAssertEqual(resolved.model, raw)
        XCTAssertNil(resolved.effort)
    }

    func testProviderExtensionRawResultTimeoutAndStandardObjectValidation() async throws {
        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_EXTENSION_RESULT_SHAPE": "array"],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            let result = try await fixture.controller.sendProviderExtensionRequest(
                method: "cursor/list_available_models",
                params: [:],
                timeoutSeconds: 1
            )
            XCTAssertEqual(result as? [String], ["raw", "result"])
            await fixture.controller.shutdown()
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_EXTENSION_NO_RESPONSE": "1"],
                providerID: .cursor
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "timed out") {
                _ = try await fixture.controller.sendProviderExtensionRequest(
                    method: "cursor/list_available_models",
                    params: [:],
                    timeoutSeconds: 0.01
                )
            }
            await fixture.controller.shutdown()
        }

        do {
            let fixture = try makeFixture(
                shape: "capability",
                extraEnvironment: ["ACP_ARRAY_RESULT_METHOD": "session/set_config_option"],
                providerID: .openCode
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "Missing result/error") {
                try await fixture.controller.setSessionMode("plan")
            }
            await fixture.controller.shutdown()
        }
    }

    func testDiscoveryAvoidsModelMutationAndReportsExtensionOutcome() async throws {
        let successful = try makeDiscoveryClientFixture()
        let successfulOutcome = await successful.client.discoverModels(workspacePath: nil)
        guard case let .completed(successfulSnapshot, successfulRefresh) = successfulOutcome else {
            return XCTFail("Expected successful Cursor discovery")
        }
        XCTAssertFalse(successfulSnapshot?.options.isEmpty ?? true)
        XCTAssertEqual(successfulRefresh, .live)
        XCTAssertFalse(successful.catalog.currentSnapshot().isEmpty)
        XCTAssertTrue(recordedRequests(at: successful.recordURL).contains {
            $0["method"] as? String == "cursor/list_available_models"
        })
        XCTAssertFalse(recordedRequests(at: successful.recordURL).contains {
            $0["method"] as? String == "session/set_config_option"
        })

        let unsupported = try makeDiscoveryClientFixture(
            extraEnvironment: ["ACP_EXTENSION_ERROR_CODE": "-32601"]
        )
        let unsupportedOutcome = await unsupported.client.discoverModels(workspacePath: nil)
        guard case let .completed(unsupportedSnapshot, unsupportedRefresh) = unsupportedOutcome else {
            return XCTFail("Expected bare models with unsupported extension")
        }
        XCTAssertEqual(unsupportedSnapshot, successfulSnapshot)
        XCTAssertEqual(unsupportedRefresh, .unsupported)
        XCTAssertFalse(recordedRequests(at: unsupported.recordURL).contains {
            $0["method"] as? String == "session/set_config_option"
        })
    }

    func testDiscoveryServiceCompositionUsesClientCatalogForLiveAndValidEmpty() async throws {
        let live = try makeDiscoveryClientFixture()
        XCTAssertTrue(live.client.parameterCatalog === live.catalog)
        let liveService = CursorACPModelPollingService(client: live.client)
        addTeardownBlock { await liveService.shutdown() }

        let liveRefreshed = await liveService.refreshNow(workspacePath: nil)
        XCTAssertTrue(liveRefreshed)
        XCTAssertEqual(live.catalog.status().state, .live)
        XCTAssertTrue(live.catalog.status().hasUsableCatalog)
        XCTAssertFalse(live.catalog.currentSnapshot().isEmpty)

        let empty = try makeDiscoveryClientFixture(
            extraEnvironment: ["ACP_EXTENSION_EMPTY_MODELS": "1"]
        )
        installSyntheticCatalog(in: empty.catalog)
        XCTAssertTrue(empty.client.parameterCatalog === empty.catalog)
        let emptyService = CursorACPModelPollingService(client: empty.client)
        addTeardownBlock { await emptyService.shutdown() }

        let emptyRefreshed = await emptyService.refreshNow(workspacePath: nil)
        XCTAssertTrue(emptyRefreshed)
        XCTAssertEqual(empty.catalog.status().state, .live)
        XCTAssertFalse(empty.catalog.status().hasUsableCatalog)
        XCTAssertTrue(empty.catalog.currentSnapshot().isEmpty)
    }

    func testParameterExtensionCancellationPropagatesAsCancelledDiscovery() async throws {
        let fixture = try makeDiscoveryClientFixture(
            extraEnvironment: ["ACP_EXTENSION_NO_RESPONSE": "1"],
            extensionTimeoutSeconds: 30
        )
        installSyntheticCatalog(in: fixture.catalog)
        let retained = fixture.catalog.currentSnapshot()
        let discovery = Task {
            await fixture.client.discoverModels(workspacePath: nil)
        }

        try await AsyncTestWait.waitUntil("Cursor parameter extension request started") {
            self.recordedRequests(at: fixture.recordURL).contains {
                $0["method"] as? String == "cursor/list_available_models"
            }
        }
        discovery.cancel()

        let outcome = await discovery.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.catalog.currentSnapshot(), retained)
        XCTAssertNotEqual(
            fixture.catalog.status().state,
            .stale(.extension)
        )
    }

    func testTransientCatalogExtensionFailureRetainsCatalog() async throws {
        let fixture = try makeDiscoveryClientFixture(
            extraEnvironment: ["ACP_EXTENSION_NO_RESPONSE": "1"],
            extensionTimeoutSeconds: 0.1
        )
        installSyntheticCatalog(in: fixture.catalog)
        let retainedCatalog = fixture.catalog.currentSnapshot()

        let outcome = await fixture.client.discoverModels(workspacePath: nil)

        guard case let .completed(snapshot, parameterRefresh) = outcome else {
            return XCTFail("Expected bare models with failed extension")
        }
        XCTAssertFalse(snapshot?.options.isEmpty ?? true)
        XCTAssertEqual(parameterRefresh, .stale(.timeout))
        XCTAssertEqual(fixture.catalog.currentSnapshot(), retainedCatalog)
    }

    @MainActor
    func testKillSwitchSkipsCatalogExtensionAndCursorEffortOverlay() async throws {
        installSyntheticCatalog()
        let resolved = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "custom-model",
            reasoningEffortRaw: "high",
            cursorParameterizedModelsEnabled: false
        )
        XCTAssertEqual(resolved.model, "custom-model")
        XCTAssertNil(resolved.effort)

        let fixture = try makeDiscoveryClientFixture(parameterizedModelsEnabled: false)
        let outcome = await fixture.client.discoverModels(workspacePath: nil)
        guard case let .completed(snapshot, parameterRefresh) = outcome else {
            return XCTFail("Expected bare models with parameterization disabled")
        }
        XCTAssertFalse(snapshot?.options.isEmpty ?? true)
        XCTAssertEqual(parameterRefresh, .disabled)
        XCTAssertFalse(recordedRequests(at: fixture.recordURL).contains {
            $0["method"] as? String == "cursor/list_available_models"
        })
    }

    @MainActor
    func testCursorReasoningEffortOverlaysCatalogThoughtLevelID() throws {
        installSyntheticCatalog()
        let resolved = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "custom-model[fast=true]",
            reasoningEffortRaw: "high"
        )

        XCTAssertEqual(resolved.model, "custom-model[thinking_mode=high,fast=true]")
        XCTAssertNil(resolved.effort)
    }

    @MainActor
    func testCursorReasoningEffortValidatesCanonicalizesAndRequiresModel() throws {
        installSyntheticCatalog()

        let canonicalized = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "custom-model",
            reasoningEffortRaw: " HIGH "
        )
        XCTAssertEqual(canonicalized.model, "custom-model[thinking_mode=high]")
        XCTAssertNil(canonicalized.effort)

        assertThrowsSync(containing: "Unsupported reasoning_effort 'ultra'") {
            _ = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "custom-model",
                reasoningEffortRaw: "ultra"
            )
        }
        assertThrowsSync(containing: "reasoning_effort for Cursor requires a model_id") {
            _ = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: nil,
                reasoningEffortRaw: "high"
            )
        }
    }

    @MainActor
    func testCursorReasoningEffortConflictIsInvalidParams() {
        installSyntheticCatalog()
        assertThrowsSync(containing: "conflicts with the explicit Cursor parameter") {
            _ = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "custom-model[thinking_mode=low]",
                reasoningEffortRaw: "high"
            )
        }
    }

    @MainActor
    func testCursorReasoningEffortWithoutCatalogIsInvalidParams() {
        assertThrowsSync(containing: "Cursor parameter metadata is unavailable") {
            _ = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "custom-model",
                reasoningEffortRaw: "high"
            )
        }
    }

    func testSetConfigOptionTimeoutAppliesToCursorAndOpenCode() async throws {
        for providerID in [ACPProviderID.cursor, .openCode] {
            let fixture = try makeFixture(
                shape: "capability",
                initialModel: "default",
                extraEnvironment: ["ACP_SET_CONFIG_NO_RESPONSE": "1"],
                providerID: providerID,
                setConfigOptionTimeoutSeconds: 0.1
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "session/set_config_option timed out after 0.1s") {
                try await fixture.controller.setSessionModel("gpt-5.6-sol")
            }
            await fixture.controller.shutdown()
            XCTAssertEqual(
                mutationPairs(at: fixture.recordURL),
                [Mutation(configID: "model", value: "gpt-5.6-sol")],
                providerID.rawValue
            )
        }

        let closingFixture = try makeFixture(
            shape: "capability",
            extraEnvironment: ["ACP_EXIT_ON_CONFIG_ID": "reasoning"],
            providerID: .cursor
        )
        _ = try await closingFixture.controller.bootstrap()
        await assertThrows(containing: "restore to medium failed: ACP transport closed unexpectedly") {
            try await closingFixture.controller.setSessionModel(
                "gpt-5.6-sol[context=1m,reasoning=high]"
            )
        }
        await closingFixture.controller.shutdown()
    }

    @MainActor
    func testNilRegistryHeadlessBracketedSelectionReachesSessionModelMutation() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }

        let directory = try makeTestDirectory(name: "CursorParameterizedHeadlessRegistryTests")
        let scriptURL = directory.appendingPathComponent("cursor_parameterized_acp.py")
        try Self.fakeACPServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let provider = CursorParameterizedFakeProvider(
            commandPath: scriptURL.path,
            environment: [
                "ACP_FIXTURE_DIR": fixtureDirectory.path,
                "ACP_SHAPE": "capability",
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_INITIAL_MODEL": "default"
            ],
            providerID: .cursor,
            initializeClientCapabilityMetadata: ["parameterizedModelPicker": true]
        )
        let headless = CursorACPHeadlessAgentProvider(
            config: CursorAgentConfig(
                modelString: "gpt-5.6-sol[reasoning=high]",
                includeRepoPromptMCPServer: false,
                cleanupProjectMCPApproval: false
            ),
            workspacePath: directory.path,
            providerFactory: { _ in provider }
        )
        let stream = try await headless.streamAgentMessage(AgentMessage(userMessage: "headless"))
        for try await _ in stream {}
        await headless.dispose()

        XCTAssertEqual(
            mutationPairs(at: recordURL),
            [
                Mutation(configID: "model", value: "gpt-5.6-sol"),
                Mutation(configID: "reasoning", value: "high")
            ]
        )
    }

    @MainActor
    func testNonCursorExplicitReasoningEffortIsUnchanged() throws {
        let resolved = try AgentExternalMCPRunStarter.resolvedModelAndEffort(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: "gpt-5.6-sol",
            reasoningEffortRaw: "high"
        )
        XCTAssertEqual(resolved.model, "gpt-5.6-sol")
        XCTAssertEqual(resolved.effort, "high")
    }

    private struct Mutation: Equatable {
        let configID: String
        let value: String
    }

    private struct Fixture {
        let controller: ACPAgentSessionController
        let recordURL: URL
    }

    private struct DiscoveryFixture {
        let client: CursorACPControllerModelDiscoveryClient
        let catalog: CursorModelParameterCatalog
        let recordURL: URL
    }

    private func makeFixture(
        shape: String,
        initialModel: String? = nil,
        extraEnvironment: [String: String] = [:],
        metadata: [String: Bool] = [:],
        diagnostics: LockedCursorStrings? = nil,
        providerID: ACPProviderID,
        setConfigOptionTimeoutSeconds: TimeInterval = 30
    ) throws -> Fixture {
        let directory = try makeTestDirectory(name: "CursorParameterizedModelControllerTests")
        let scriptURL = directory.appendingPathComponent("cursor_parameterized_acp.py")
        try Self.fakeACPServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let recordURL = directory.appendingPathComponent("requests.jsonl")

        var environment = extraEnvironment
        environment["ACP_FIXTURE_DIR"] = fixtureDirectory.path
        environment["ACP_SHAPE"] = shape
        environment["ACP_RECORD_PATH"] = recordURL.path
        if let initialModel {
            environment["ACP_INITIAL_MODEL"] = initialModel
        }
        let provider = CursorParameterizedFakeProvider(
            commandPath: scriptURL.path,
            environment: environment,
            providerID: providerID,
            initializeClientCapabilityMetadata: metadata
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: ACPRunRequest(
                agentKind: providerID == .cursor ? .cursor : .openCode,
                modelString: nil,
                workspacePath: directory.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            ),
            diagnosticSink: { event in
                if case let .info(message) = event {
                    diagnostics?.append(message)
                }
            },
            requestTimeouts: .init(
                bootstrapSeconds: 30,
                setConfigOptionSeconds: setConfigOptionTimeoutSeconds
            )
        )
        addTeardownBlock {
            await controller.shutdown()
        }
        return Fixture(controller: controller, recordURL: recordURL)
    }

    private func makeDiscoveryClientFixture(
        extraEnvironment: [String: String] = [:],
        parameterizedModelsEnabled: Bool = true,
        extensionTimeoutSeconds: TimeInterval = 10
    ) throws -> DiscoveryFixture {
        let directory = try makeTestDirectory(name: "CursorParameterizedModelDiscoveryTests")
        let scriptURL = directory.appendingPathComponent("cursor_parameterized_acp.py")
        try Self.fakeACPServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let recordURL = directory.appendingPathComponent("requests.jsonl")
        var environment = extraEnvironment
        environment["ACP_FIXTURE_DIR"] = fixtureDirectory.path
        environment["ACP_SHAPE"] = "capability"
        environment["ACP_RECORD_PATH"] = recordURL.path
        let provider = CursorParameterizedFakeProvider(
            commandPath: scriptURL.path,
            environment: environment,
            providerID: .cursor,
            initializeClientCapabilityMetadata: ["parameterizedModelPicker": true]
        )
        let catalog = CursorModelParameterCatalog()
        let client = CursorACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            },
            parameterCatalog: catalog,
            parameterizedModelsEnabled: { parameterizedModelsEnabled },
            extensionTimeoutSeconds: extensionTimeoutSeconds
        )
        return DiscoveryFixture(client: client, catalog: catalog, recordURL: recordURL)
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("CursorACP", isDirectory: true)
    }

    private func initializeClientCapabilities(at url: URL) throws -> [String: Any] {
        let request = try XCTUnwrap(recordedRequests(at: url).first {
            $0["method"] as? String == "initialize"
        })
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        return try XCTUnwrap(params["clientCapabilities"] as? [String: Any])
    }

    private func mutationPairs(at url: URL) -> [Mutation] {
        recordedRequests(at: url).compactMap { request in
            guard request["method"] as? String == "session/set_config_option",
                  let params = request["params"] as? [String: Any],
                  let configID = params["configId"] as? String,
                  let value = params["value"] as? String
            else {
                return nil
            }
            return Mutation(configID: configID, value: value)
        }
    }

    private func recordedRequests(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func snapshot(rawValue: String) -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: rawValue,
                displayName: "GPT-5.6 Sol",
                description: nil,
                isDefault: false
            )],
            currentModelRaw: rawValue
        )
    }

    private func assertThrows(
        containing text: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected error containing '\(text)'")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(text),
                "Expected '\(error.localizedDescription)' to contain '\(text)'"
            )
        }
    }

    private func assertThrowsSync(
        containing text: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected error containing '\(text)'")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(text),
                "Expected '\(error.localizedDescription)' to contain '\(text)'"
            )
        }
    }

    private func installSyntheticCatalog(
        in catalog: CursorModelParameterCatalog = .shared
    ) {
        catalog.test_restoreSnapshot([
            "custom-model": [.init(
                id: "thinking_mode",
                category: "thought_level",
                defaultValue: "low",
                options: [
                    .init(value: "low", name: "Low"),
                    .init(value: "high", name: "High")
                ],
                description: nil
            )]
        ])
    }

    private static let fakeACPServerScript = #"""
    #!/usr/bin/env python3
    import copy
    import json
    import os
    import sys

    fixture_dir = os.environ["ACP_FIXTURE_DIR"]
    shape = os.environ.get("ACP_SHAPE", "capability")
    record_path = os.environ["ACP_RECORD_PATH"]

    def load(name):
        with open(os.path.join(fixture_dir, name + ".json"), encoding="utf-8") as handle:
            return json.load(handle)

    session_fixture = load("legacy_session_new" if shape == "legacy" else "capability_session_new")
    initialize_result = session_fixture["initializeResponse"]["result"]
    session_result = copy.deepcopy(session_fixture["sessionNewResponse"]["result"])
    available_models_result = load("list_available_models")["result"]
    grown = load("capability_model_selected_grown")["result"]["configOptions"]
    shrunk = load("capability_model_switch_shrunk")["result"]["configOptions"]
    parameter_echo = load("capability_param_mutation_echo")["result"]["configOptions"]

    def find_option(options, config_id):
        return next((option for option in options if option.get("id") == config_id), None)

    initial_model = os.environ.get("ACP_INITIAL_MODEL")
    if initial_model:
        find_option(session_result.get("configOptions", []), "model")["currentValue"] = initial_model

    state = copy.deepcopy(session_result.get("configOptions", []))
    pending_config_notification = None

    def record(method, params):
        with open(record_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"method": method, "params": params}) + "\n")

    def send(payload):
        print(json.dumps(payload), flush=True)

    def respond(request_id, result=None, error=None):
        payload = {"jsonrpc": "2.0", "id": request_id}
        if error is not None:
            payload["error"] = error
        else:
            payload["result"] = result if result is not None else {}
        send(payload)

    def full_snapshot():
        return {"configOptions": copy.deepcopy(state)}

    def set_current(config_id, value):
        option = find_option(state, config_id)
        if option is not None:
            option["currentValue"] = value

    def model_values():
        option = find_option(state, "model")
        return [choice.get("value") for choice in option.get("options", [])] if option else []

    def config_notification(options):
        return {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_result["sessionId"],
                "update": {
                    "sessionUpdate": "config_option_update",
                    "configOptions": copy.deepcopy(options)
                }
            }
        }

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except Exception:
            continue
        method = request.get("method")
        params = request.get("params") or {}
        request_id = request.get("id")
        record(method, params)

        if method == "initialize":
            respond(request_id, copy.deepcopy(initialize_result))
            continue
        if method == "session/new":
            respond(request_id, copy.deepcopy(session_result))
            continue
        if method == "session/prompt":
            respond(request_id, {"stopReason": "end_turn"})
            continue
        if method == "cursor/list_available_models":
            if os.environ.get("ACP_EXTENSION_NO_RESPONSE") == "1":
                continue
            if os.environ.get("ACP_EXTENSION_EMPTY_MODELS") == "1":
                respond(request_id, {"models": []})
                continue
            extension_error_code = os.environ.get("ACP_EXTENSION_ERROR_CODE")
            if extension_error_code:
                respond(request_id, error={
                    "code": int(extension_error_code),
                    "message": "Method not found"
                })
            elif os.environ.get("ACP_EXTENSION_RESULT_SHAPE") == "array":
                respond(request_id, ["raw", "result"])
            else:
                respond(request_id, copy.deepcopy(available_models_result))
            continue
        if method == "test/flush_config_notification":
            if pending_config_notification is not None:
                send(pending_config_notification)
                pending_config_notification = None
            respond(request_id, {})
            continue
        if method == os.environ.get("ACP_ARRAY_RESULT_METHOD"):
            respond(request_id, ["not", "an", "object"])
            continue
        if method != "session/set_config_option":
            respond(request_id, {})
            continue

        config_id = params.get("configId")
        value = params.get("value")
        if os.environ.get("ACP_SET_CONFIG_NO_RESPONSE") == "1":
            continue
        if config_id == os.environ.get("ACP_EXIT_ON_CONFIG_ID"):
            sys.exit(0)
        if config_id == "model":
            if value == os.environ.get("ACP_REJECT_MODEL_ROLLBACK_VALUE"):
                respond(request_id, error={
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"message": "Model rollback rejected for " + str(value)}
                })
                continue
            if value not in model_values():
                respond(request_id, error={
                    "code": -32602,
                    "message": "Invalid params",
                    "data": {"message": "Invalid model value: " + str(value)}
                })
                continue
            if shape == "legacy":
                set_current("model", value)
            elif value == "gpt-5.2":
                state = copy.deepcopy(shrunk)
            elif value == "gpt-5.6-sol":
                state = copy.deepcopy(grown)
                if os.environ.get("ACP_FORCE_FAST_AFTER_MODEL") == "1":
                    set_current("fast", "true")
            else:
                set_current("model", value)
            respond(request_id, full_snapshot())
            continue

        reject_id = os.environ.get("ACP_REJECT_CONFIG_ID")
        if config_id == reject_id:
            respond(request_id, error={
                "code": -32602,
                "message": "Invalid params",
                "data": {"message": "Invalid value for " + config_id + ": " + str(value)}
            })
            continue
        rollback_id = os.environ.get("ACP_REJECT_ROLLBACK_CONFIG_ID")
        if config_id == rollback_id and value in ("272k", "medium", "false"):
            respond(request_id, error={
                "code": -32602,
                "message": "Invalid params",
                "data": {"message": "Rollback rejected for " + config_id}
            })
            continue

        option = find_option(state, config_id)
        if option is None:
            respond(request_id, error={
                "code": -32602,
                "message": "Invalid params",
                "data": {"message": "Unknown model config option: " + str(config_id)}
            })
            continue
        valid_values = [choice.get("value") for choice in option.get("options", [])]
        if value not in valid_values:
            respond(request_id, error={
                "code": -32602,
                "message": "Invalid params",
                "data": {"message": "Invalid value for " + config_id + ": " + str(value)}
            })
            continue

        old_value = option.get("currentValue")
        set_current(config_id, value)
        if os.environ.get("ACP_ECHO_MISMATCH_CONFIG_ID") == config_id:
            mismatch = copy.deepcopy(state)
            find_option(mismatch, config_id)["currentValue"] = old_value
            respond(request_id, {"configOptions": mismatch})
            continue

        if config_id == "reasoning" and value == "high":
            echoed = copy.deepcopy(parameter_echo)
            for prior in state:
                echoed_option = find_option(echoed, prior.get("id"))
                if echoed_option is not None:
                    echoed_option["currentValue"] = prior.get("currentValue")
            state = echoed

        respond(request_id, full_snapshot())

        if os.environ.get("ACP_MORPH_AFTER_CONFIG_ID") == config_id:
            state = copy.deepcopy(shrunk)
            set_current(config_id, value)
            pending_config_notification = config_notification(state)
        elif os.environ.get("ACP_REVERT_NOTIFICATION_CONFIG_ID") == config_id:
            set_current(config_id, old_value)
            send(config_notification(state))
    """#
}

private struct CursorParameterizedFakeProvider: ACPAgentProvider {
    let commandPath: String
    let environment: [String: String]
    let providerID: ACPProviderID
    let initializeClientCapabilityMetadata: [String: Bool]

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request _: ACPRunRequest
    ) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

private final class LockedCursorStrings: @unchecked Sendable {
    private let condition = AsyncTestCondition<[String]>([])

    var values: [String] {
        condition.snapshot()
    }

    func append(_ value: String) {
        condition.update { $0.append(value) }
    }

    func waitUntil(
        _ description: String,
        predicate: @escaping ([String]) -> Bool
    ) async throws {
        try await condition.waitUntil(description, predicate: predicate)
    }
}

private final class LockedCursorResults: @unchecked Sendable {
    private let condition = AsyncTestCondition<[AIStreamResult]>([])

    var values: [AIStreamResult] {
        condition.snapshot()
    }

    func append(_ value: AIStreamResult) {
        condition.update { $0.append(value) }
    }
}
