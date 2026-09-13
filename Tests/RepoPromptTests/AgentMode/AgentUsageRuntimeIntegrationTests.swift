import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Runtime integration of `providerUsage` accounting through the production ViewModel seams
/// (plan §3.2/§3.3): persisted hydration, controller install/replace/remove, save, and handoff.
/// Production runs with G1 closed (`.productionClaude`), so every case asserts that runtime
/// lifecycle events leave the persisted payload byte-for-byte untouched.
@MainActor
final class AgentUsageRuntimeIntegrationTests: XCTestCase {
    private let qualified = AgentUsageQualification.qualified(contractID: "test.claude.cumulative.v1")

    // MARK: - Hydration → controller lifecycle → save

    func testHydrationPreservesNullOpaqueAndForeignUsageThroughControllerLifecycleAndSave() async throws {
        let foreignOrigin = UUID()
        let foreignRecord = AgentProviderUsageRecord(
            originSessionID: foreignOrigin,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasUnmeasuredHistory: true
        )
        let foreignRawJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreignRecord))
        let unknownSchemaJSON: [String: Any] = [
            "schemaVersion": 2,
            "turns": "future",
            "nested": ["k": [1, 2, ["deep": NSNull()]]]
        ]
        let cases: [(label: String, seed: AgentProviderUsagePersist?, rawMember: Any?, expectedEligibility: AgentUsageEligibility)] = [
            ("explicit null", .opaque(.null), nil, .opaquePersistedValue),
            ("unknown schema object", nil, unknownSchemaJSON, .opaquePersistedValue),
            ("foreign record", .record(foreignRecord), nil, .foreignOrigin(foreignOrigin))
        ]

        for testCase in cases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let persistedBeforeHydration = try await fixture.seedPersistedSession(
                providerUsage: testCase.seed,
                rawProviderUsageMember: testCase.rawMember
            )
            let expectedRawMember: Any = testCase.rawMember
                ?? (testCase.seed == .opaque(.null) ? NSNull() : foreignRawJSON)
            XCTAssertNotNil(persistedBeforeHydration.providerUsage, testCase.label)

            // A controller arriving before hydration installs a lifecycle-only accumulator.
            let recorder = LifecycleRecorder()
            let firstController = LifecycleFakeNativeController(recorder: recorder, label: "first")
            fixture.session.claudeController = firstController
            XCTAssertNil(fixture.session.usageAccounting?.persistedRepresentation, testCase.label)
            let preHydrationExecution = try XCTUnwrap(fixture.session.usageAccounting?.activeExecutionID, testCase.label)

            let payload = try await fixture.hydrationPayload()
            let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
            XCTAssertTrue(didHydrate, testCase.label)
            let hydrated = try XCTUnwrap(fixture.session.usageAccounting, testCase.label)
            XCTAssertEqual(hydrated.ownerSessionID, fixture.sessionID, testCase.label)
            XCTAssertEqual(hydrated.qualification, .unqualified, testCase.label)
            XCTAssertEqual(hydrated.eligibility, testCase.expectedEligibility, testCase.label)
            XCTAssertEqual(hydrated.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
            XCTAssertEqual(
                hydrated.activeExecutionID,
                preHydrationExecution,
                "\(testCase.label): a lifecycle-only accumulator keeps its live execution identity through hydration"
            )

            // Controller replacement is a fresh execution identity; removal disposes it.
            fixture.session.claudeController = LifecycleFakeNativeController(recorder: recorder, label: "second")
            let replacedExecution = try XCTUnwrap(fixture.session.usageAccounting?.activeExecutionID, testCase.label)
            XCTAssertNotEqual(replacedExecution, preHydrationExecution, testCase.label)
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)

            // Production-shaped lifecycle events (dispatch registration, unverified stream
            // observation, turn completion) are rejected with the gate closed.
            let turnID = UUID()
            XCTAssertEqual(
                fixture.session.usageAccounting?.registerTurn(turnID, executionID: replacedExecution),
                .rejected(.unqualifiedContract),
                testCase.label
            )
            XCTAssertEqual(
                fixture.session.usageAccounting?.observe(
                    .init(
                        observation: .init(source: .result, inputTokens: 10, outputTokens: 5, envelopeID: "res-live"),
                        reportedCost: AgentUsageObservationInput.exactCost(fromReported: 1.25),
                        executionID: replacedExecution,
                        turnID: nil,
                        attribution: .unverified
                    )
                ),
                .rejected(.unqualifiedContract),
                testCase.label
            )
            XCTAssertEqual(
                fixture.session.usageAccounting?.closeTurn(turnID, outcome: .completed),
                .rejected(.unqualifiedContract),
                testCase.label
            )
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
            XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate, testCase.label)
            XCTAssertNil(fixture.session.usageAccounting?.cacheHitShare, testCase.label)

            // The production save projects the hydrated payload verbatim.
            fixture.session.isDirty = true
            await fixture.viewModel.flushSave(for: fixture.tabID)
            let reloaded = try await fixture.reloadPersistedSession()
            XCTAssertEqual(reloaded.providerUsage, persistedBeforeHydration.providerUsage, testCase.label)
            let rawAfterSave = try fixture.rawProviderUsageMember() as AnyObject
            XCTAssertTrue(
                rawAfterSave.isEqual(expectedRawMember),
                "\(testCase.label): raw providerUsage member must be written back unchanged, got \(rawAfterSave)"
            )

            fixture.session.claudeController = nil
            XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID, testCase.label)
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
        }
    }

    func testRefusedLateHydrationNeverOverwritesPersistedUsageAndResyncsSurvivingController() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let persisted = try await fixture.seedPersistedSession(providerUsage: .opaque(.null), rawProviderUsageMember: nil)

        // A qualified accumulator that begins an execution before hydration owns mutations and
        // therefore refuses the late hydration. The on-disk payload must still win.
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: false,
            qualification: qualified
        )
        let recorder = LifecycleRecorder()
        fixture.session.claudeController = LifecycleFakeNativeController(recorder: recorder)
        let owned = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertNotNil(owned.persistedRepresentation?.record, "qualified execution materializes an owned record")
        var refused = owned
        XCTAssertFalse(refused.applyHydration(persisted.providerUsage, hasPriorHistory: true))

        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.persistedRepresentation, persisted.providerUsage)
        XCTAssertNil(hydrated.persistedRepresentation?.record)
        XCTAssertEqual(hydrated.qualification, .unqualified)
        XCTAssertNotNil(hydrated.activeExecutionID, "the surviving controller is re-registered as a fresh execution")

        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertEqual(reloaded.providerUsage, persisted.providerUsage)
        let rawAfterSave = try fixture.rawProviderUsageMember() as AnyObject
        XCTAssertTrue(rawAfterSave.isEqual(NSNull()), "got \(rawAfterSave)")

        // Route activation resets accounting while the controller survives; hydration must
        // re-register the execution instead of leaving later dispatches unregistered.
        fixture.session.usageAccounting = nil
        let didRehydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didRehydrate)
        let reactivated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertNotNil(reactivated.activeExecutionID)
        XCTAssertEqual(reactivated.persistedRepresentation, persisted.providerUsage)

        fixture.session.claudeController = nil
        XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID)
    }

    // MARK: - Handoff

    func testHandoffDestinationStartsWithoutInheritedAccounting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.hasLoadedPersistedState = true
        fixture.session.setItemsSilently(
            [.user("source question", sequenceIndex: 0), .assistant("source answer", sequenceIndex: 1)],
            reason: .testOverride
        )
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session)
        var sourceAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: true,
            qualification: qualified
        )
        let sourceExecution = UUID()
        sourceAccounting.beginExecution(
            executionID: sourceExecution,
            providerSessionID: "ps-source",
            baseline: .verifiedZero,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        fixture.session.usageAccounting = sourceAccounting
        let sourceRepresentation = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation)
        XCTAssertNotNil(sourceRepresentation.record)

        let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
            sourceTabID: fixture.tabID,
            upToItemID: nil,
            destinationAgent: .claudeCode,
            destinationModelRaw: fixture.session.selectedModelRaw,
            destinationReasoningEffortRaw: nil
        )
        let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
        let destinationSessionID = try XCTUnwrap(destination.activeAgentSessionID)
        XCTAssertNotEqual(destinationSessionID, fixture.sessionID)
        XCTAssertNil(destination.usageAccounting, "a branch never inherits source accounting")

        // The destination's first controller keys accounting to its own identity with no payload.
        destination.claudeController = LifecycleFakeNativeController(recorder: LifecycleRecorder(), label: "destination")
        let destinationAccounting = try XCTUnwrap(destination.usageAccounting)
        XCTAssertEqual(destinationAccounting.ownerSessionID, destinationSessionID)
        XCTAssertEqual(destinationAccounting.qualification, .unqualified)
        XCTAssertNil(destinationAccounting.persistedRepresentation)
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, sourceRepresentation)

        destination.isDirty = true
        await fixture.viewModel.flushSave(for: destinationTabID)
        let loadedDestination = try await AgentSessionDataService.shared.loadAgentSession(
            id: destinationSessionID,
            for: fixture.workspace
        )
        let persistedDestination = try XCTUnwrap(loadedDestination)
        XCTAssertEqual(persistedDestination.id, destinationSessionID)
        XCTAssertNil(persistedDestination.providerUsage, "absent stays absent: no measured-zero record is manufactured")
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let storage: URL
        let tabID: UUID
        let sessionID: UUID

        /// Resolved by scanning the writer's folder so the fixture never assumes a file-name
        /// scheme or a symlink-free temporary path.
        func sessionFileURL() throws -> URL {
            let folder = storage.appendingPathComponent("AgentSessions", isDirectory: true)
            let needle = sessionID.uuidString.lowercased()
            let matches = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.lowercased().contains(needle) }
            return try XCTUnwrap(matches.first, "expected exactly one persisted file for \(sessionID), found \(matches)")
        }

        /// Writes the persisted session through the production writer, optionally replacing the
        /// raw `providerUsage` member so the fixture is independent of the in-memory codec.
        @MainActor
        func seedPersistedSession(
            providerUsage: AgentProviderUsagePersist?,
            rawProviderUsageMember: Any?
        ) async throws -> AgentSession {
            let service = AgentSessionDataService.shared
            let persisted = AgentSession(
                id: sessionID,
                workspaceID: workspace.id,
                composeTabID: tabID,
                name: "Usage Runtime",
                items: [AgentChatItemPersist(from: .user("hello", sequenceIndex: 0))],
                itemCount: 1,
                agentKind: AgentProviderKind.claudeCode.rawValue,
                lastRunState: AgentSessionRunState.idle.rawValue,
                providerUsage: providerUsage
            )
            let fileURL = try await service.saveAgentSession(
                persisted,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            if let rawProviderUsageMember {
                var members = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
                )
                members["providerUsage"] = rawProviderUsageMember
                try JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]).write(to: fileURL)
            }
            return try await reloadPersistedSession()
        }

        func reloadPersistedSession() async throws -> AgentSession {
            let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            return try XCTUnwrap(loaded)
        }

        func rawProviderUsageMember() throws -> Any? {
            let members = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: sessionFileURL())) as? [String: Any]
            )
            return members["providerUsage"]
        }

        @MainActor
        func hydrationPayload() async throws -> AgentSessionHydrationPayload {
            let request = AgentSessionHydrationRequest(
                workspace: workspace,
                tabID: tabID,
                sessionID: sessionID,
                resolvedDisplayName: "Usage Runtime",
                hasPendingQuestionUI: false,
                transcriptViewportState: .liveBottom,
                isCompressedHistoryRevealed: false,
                initialPerformanceSnapshot: .empty
            )
            let prepared = try await AgentSessionDataService.shared.preparePersistedHydration(request)
            return try XCTUnwrap(prepared)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: storage)
        }
    }

    private func makeFixture() throws -> Fixture {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentUsageRuntimeIntegrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Agent Usage Runtime",
            repoPaths: [],
            customStoragePath: storage,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Source", activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )

        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        prompt.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)

        let recorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: recorder) }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: workspaceManager)
        viewModel.test_setActiveWorkspaceIDForSessionIndex(workspace.id)
        viewModel.test_setCurrentTabIDOverride(tabID)

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)

        return Fixture(
            viewModel: viewModel,
            session: session,
            prompt: prompt,
            workspaceManager: workspaceManager,
            workspace: workspace,
            storage: storage,
            tabID: tabID,
            sessionID: sessionID
        )
    }
}
