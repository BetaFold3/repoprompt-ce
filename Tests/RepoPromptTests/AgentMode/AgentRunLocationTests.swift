@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunLocationTests: XCTestCase {
    func testRunLocationPropsHiddenWhenRegistryIsEmpty() async throws {
        let registry = try makeRegistry(hosts: [])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.syncStatusPillsUIState()

        XCTAssertNil(viewModel.runLocationProps(tabID: tabID))
        XCTAssertNil(viewModel.ui.statusPills.snapshot.runLocation)
        XCTAssertNotNil(viewModel.executionLocationProps(tabID: tabID))
    }

    func testRunLocationEligibilityLocksAfterFirstMessage() async throws {
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        let registry = try makeRegistry(hosts: [host])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(2)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let initialProps = try XCTUnwrap(viewModel.runLocationProps(tabID: tabID))
        XCTAssertTrue(initialProps.isEnabled)
        XCTAssertEqual(initialProps.selection, .thisMac)
        XCTAssertEqual(initialProps.hostOptions, [AgentRunLocationHostOption(id: host.id, displayName: "Studio Mac")])

        session.hasSentFirstMessage = true
        session.replaceItems([.user("hello", sequenceIndex: 0)])

        let lockedProps = try XCTUnwrap(viewModel.runLocationProps(tabID: tabID))
        XCTAssertFalse(lockedProps.isEnabled)
        XCTAssertEqual(lockedProps.disabledReason, "Run location can only be changed before the first message.")
        XCTAssertEqual(lockedProps.selection, .thisMac)
    }

    func testSelectingRemoteHostDisablesWorktreePill() async throws {
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        let registry = try makeRegistry(hosts: [host])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(3)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.selectRunLocation(.host(hostID: host.id), for: tabID)

        XCTAssertEqual(session.remoteHost?.hostID, host.id)
        XCTAssertEqual(session.remoteHost?.hostDisplayName, "Studio Mac")
        XCTAssertEqual(session.pendingInitialStartLocation, .local)
        XCTAssertEqual(session.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)

        let runProps = try XCTUnwrap(viewModel.runLocationProps(tabID: tabID))
        XCTAssertEqual(runProps.selection, .host(hostID: host.id))
        XCTAssertEqual(runProps.selectedHostDisplayName, "Studio Mac")
        XCTAssertEqual(runProps.selectedHostAbbreviation, "SM")

        let worktreeProps = try XCTUnwrap(viewModel.executionLocationProps(tabID: tabID))
        XCTAssertFalse(worktreeProps.isEnabled)
        XCTAssertEqual(worktreeProps.disabledReason, AgentModeViewModel.remoteWorktreeManagedReason)
        XCTAssertEqual(worktreeProps.selection, .local)
    }

    func testWorkspaceDefaultAutoBindingPinsModelAndPill() async throws {
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        let registry = try makeRegistry(hosts: [host])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(5)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let workspace = WorkspaceModel(
            name: "Remote Workspace",
            repoPaths: [],
            defaultRemoteHostID: host.id
        )

        XCTAssertTrue(
            viewModel.applyWorkspaceDefaultRunLocationIfNeeded(
                to: session,
                workspace: workspace
            )
        )

        XCTAssertEqual(session.remoteHost?.hostID, host.id)
        XCTAssertEqual(session.remoteHost?.hostDisplayName, "Studio Mac")
        XCTAssertEqual(session.remoteHost?.remoteSessionID, "")
        XCTAssertEqual(session.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        let props = try XCTUnwrap(viewModel.runLocationProps(tabID: tabID))
        XCTAssertEqual(props.selection, .host(hostID: host.id))
        XCTAssertEqual(props.selectedHostDisplayName, "Studio Mac")
    }

    func testHostRunLocationApplicationRejectsExistingSubmittedAndRevokedSessions() async throws {
        let firstHost = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        let secondHost = try RemoteHostTestSupport.hostRecord(displayName: "Build Mac")
        var revokedHost = try RemoteHostTestSupport.hostRecord(displayName: "Former Mac")
        revokedHost.revokedByHostAt = Date(timeIntervalSince1970: 1)
        let registry = try makeRegistry(hosts: [firstHost, secondHost, revokedHost])
        let viewModel = try makeViewModel(registry: registry)

        let alreadyBound = await viewModel.ensureSessionReady(tabID: id(6))
        XCTAssertTrue(viewModel.applyHostRunLocation(hostID: firstHost.id, to: alreadyBound))
        XCTAssertFalse(viewModel.applyHostRunLocation(hostID: secondHost.id, to: alreadyBound))
        XCTAssertEqual(alreadyBound.remoteHost?.hostID, firstHost.id)

        let submitted = await viewModel.ensureSessionReady(tabID: id(7))
        submitted.appendItem(.user("already sent", sequenceIndex: 0))
        XCTAssertFalse(viewModel.applyHostRunLocation(hostID: firstHost.id, to: submitted))
        XCTAssertNil(submitted.remoteHost)

        let revoked = await viewModel.ensureSessionReady(tabID: id(8))
        XCTAssertFalse(viewModel.applyHostRunLocation(hostID: revokedHost.id, to: revoked))
        XCTAssertNil(revoked.remoteHost)
    }

    func testSelectingThisMacClearsWorkspaceDefaultBinding() async throws {
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        let registry = try makeRegistry(hosts: [host])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(9)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let workspace = WorkspaceModel(
            name: "Remote Workspace",
            repoPaths: [],
            defaultRemoteHostID: host.id
        )
        XCTAssertTrue(
            viewModel.applyWorkspaceDefaultRunLocationIfNeeded(
                to: session,
                workspace: workspace
            )
        )

        viewModel.selectRunLocation(.thisMac, for: tabID)

        XCTAssertNil(session.remoteHost)
        XCTAssertNotEqual(session.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(
            try XCTUnwrap(viewModel.runLocationProps(tabID: tabID)).selection,
            .thisMac
        )

        let persisted = try AgentSession(
            id: id(109),
            name: "Local Override",
            savedAt: Date(timeIntervalSinceReferenceDate: 109),
            remoteHost: session.remoteHost,
            autoEditEnabled: session.autoEditEnabled
        )
        let reloaded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(persisted)
        )
        XCTAssertNil(reloaded.remoteHost)
    }

    func testRemoteBoundSessionDisablesLocalOnlyMutations() async throws {
        let registry = try makeRegistry(hosts: [])
        let viewModel = try makeViewModel(registry: registry)
        let tabID = id(4)
        let sessionID = id(104)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.replaceItems([.user("remote turn", sequenceIndex: 0)])
        session.remoteHost = AgentSessionRemoteHostBinding(
            hostID: "host-remote",
            hostDisplayName: "Studio Mac",
            remoteSessionID: "remote-session"
        )

        XCTAssertEqual(viewModel.localSessionMutationDisabledReason(for: session), "Managed on Studio Mac")
        XCTAssertEqual(viewModel.localSessionMutationDisabledReason(tabID: tabID), "Managed on Studio Mac")
        XCTAssertFalse(viewModel.canForkCurrentSession)
        let worktreeProps = try XCTUnwrap(viewModel.executionLocationProps(tabID: tabID))
        XCTAssertFalse(worktreeProps.isEnabled)
        XCTAssertEqual(worktreeProps.disabledReason, AgentModeViewModel.remoteWorktreeManagedReason)

        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [],
                forSessionID: sessionID,
                intent: .externalManagement
            )
            XCTFail("Expected remote-bound worktree mutation to be rejected")
        } catch {
            let localized = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(
                localized.contains("Managed on Studio Mac") || String(describing: error).contains("Managed on Studio Mac"),
                "Unexpected error: \(error)"
            )
        }
    }

    // MARK: - V1-3 fresh-workspace first-tab auto-bind (post-v1 review P1-1)

    func testFreshWorkspaceDefaultTabAutoBindsLazyComposerSessionExactlyOnce() async throws {
        let fixture = try await makeWorkspaceFixture()
        XCTAssertNil(fixture.viewModel.sessions[fixture.initialTabID])

        // The default T1 tab of a fresh workspace never passes through
        // createAndActivateSessionTab(); its session materializes lazily on
        // the first composer sync and must pick up the workspace default.
        let target = try XCTUnwrap(
            fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.initialTabID, session: nil)
        )
        XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.initialTabID])
        XCTAssertEqual(session.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(session.remoteHost?.hostDisplayName, "Studio Mac")
        XCTAssertEqual(session.remoteHost?.remoteSessionID, "")
        XCTAssertEqual(session.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        let props = try XCTUnwrap(fixture.viewModel.runLocationProps(tabID: fixture.initialTabID))
        XCTAssertEqual(props.selection, .host(hostID: fixture.host.id))

        // One-shot: an explicit "This Mac" selection sticks across later
        // composer syncs instead of being re-bound.
        fixture.viewModel.selectRunLocation(.thisMac, for: fixture.initialTabID)
        XCTAssertNil(session.remoteHost)
        _ = fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.initialTabID, session: nil)
        XCTAssertNil(session.remoteHost)
        XCTAssertNotEqual(session.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
    }

    func testMCPAndHydratedSessionCreationPathsDoNotAutoBindWorkspaceDefault() async throws {
        let mcpTabID = UUID()
        let hydratedTabID = UUID()
        let hydratedSessionID = UUID()
        let fixture = try await makeWorkspaceFixture(extraTabs: [
            ComposeTabState(id: mcpTabID, name: "MCP"),
            ComposeTabState(id: hydratedTabID, name: "Hydrated", activeAgentSessionID: hydratedSessionID)
        ])

        // MCP tool handlers materialize sessions through ensureSessionReady /
        // mcpResolveOrCreateSessionTarget — never the composer seam — and must
        // not inherit the workspace default run location.
        let mcpSession = await fixture.viewModel.ensureSessionReady(tabID: mcpTabID)
        XCTAssertNil(mcpSession.remoteHost)
        XCTAssertNotEqual(mcpSession.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)

        // A tab with a persisted agent session hydrates through the same lazy
        // composer seam but must keep its persisted (unbound) run location.
        _ = fixture.viewModel.makeComposerSubmitTarget(tabID: hydratedTabID, session: nil)
        let hydratedSession = try XCTUnwrap(fixture.viewModel.sessions[hydratedTabID])
        XCTAssertEqual(hydratedSession.activeAgentSessionID, hydratedSessionID)
        XCTAssertNil(hydratedSession.remoteHost)
        XCTAssertNotEqual(hydratedSession.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
    }

    func testFreshWorkspaceFirstSendCarriesBindingAndPinnedModelToDestination() async throws {
        let fixture = try await makeWorkspaceFixture()
        XCTAssertEqual(fixture.viewModel.currentTabID, fixture.initialTabID)

        let result = await fixture.viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: "First message from the default tab"
        )

        XCTAssertEqual(result, .submitted)
        let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
        XCTAssertNotEqual(destinationTabID, fixture.initialTabID)
        let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
        XCTAssertEqual(destination.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(destination.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        XCTAssertTrue(destination.items.contains { $0.kind == .user })

        // The still-sessionless source tab stays primed (bound + pinned) for
        // its next first-send after the success epilogue clears pending state.
        let source = try XCTUnwrap(fixture.viewModel.sessions[fixture.initialTabID])
        XCTAssertEqual(source.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(source.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        XCTAssertFalse(source.items.contains { $0.kind == .user })
    }

    func testExplicitThisMacSelectionOnFreshTabSendsLocallyAndSticks() async throws {
        // Tab creation during the first send can reload stored provider state,
        // which re-reads this key; pin it so Codex stays available for the
        // local dispatch (mirrors a machine with the Codex CLI connected).
        let defaults = UserDefaults.standard
        let previousCodexConnected = defaults.object(forKey: "CodexCLIConnected")
        defaults.set(true, forKey: "CodexCLIConnected")
        defer {
            if let previousCodexConnected {
                defaults.set(previousCodexConnected, forKey: "CodexCLIConnected")
            } else {
                defaults.removeObject(forKey: "CodexCLIConnected")
            }
        }
        let fixture = try await makeWorkspaceFixture()
        _ = try XCTUnwrap(
            fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.initialTabID, session: nil)
        )
        let source = try XCTUnwrap(fixture.viewModel.sessions[fixture.initialTabID])
        XCTAssertEqual(source.remoteHost?.hostID, fixture.host.id)

        fixture.viewModel.selectRunLocation(.thisMac, for: fixture.initialTabID)
        XCTAssertNil(source.remoteHost)
        source.selectedAgent = .codexExec
        source.selectedModelRaw = "gpt-5.4"

        let result = await fixture.viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: "Run this locally"
        )

        // Pre-reconciliation this send was BLOCKED (destination kept the
        // createAndActivateSessionTab auto-bind, so the pending-state equality
        // guard could never pass); now it must send locally, matching the pill.
        XCTAssertEqual(result, .submitted)
        let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
        XCTAssertNotEqual(destinationTabID, fixture.initialTabID)
        let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
        XCTAssertNil(destination.remoteHost)
        XCTAssertNotEqual(destination.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
        await waitUntil { fixture.lifecycleRecorder.events.contains("codex:send") }

        // The explicit "This Mac" choice sticks on the source tab.
        XCTAssertNil(source.remoteHost)
        XCTAssertNotEqual(source.selectedModelRaw, RemoteHostAgentCatalog.hostDefaultModelID)
    }

    private struct WorkspaceFixture {
        let viewModel: AgentModeViewModel
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let host: PairedHostRecord
        let initialTabID: UUID
        let lifecycleRecorder: LifecycleRecorder
    }

    private func makeWorkspaceFixture(
        extraTabs: [ComposeTabState] = []
    ) async throws -> WorkspaceFixture {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(host)

        let initialTabID = UUID()
        let workspace = WorkspaceModel(
            name: "Remote Workspace",
            repoPaths: [FileManager.default.currentDirectoryPath],
            defaultRemoteHostID: host.id,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: initialTabID, name: "T1")] + extraTabs,
            activeComposeTabID: initialTabID
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
        apiSettings.isCodexConnected = true
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

        let catalogDirectory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let catalogRegistry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: catalogDirectory))
        let catalogConnectionManager = RemoteHostConnectionManager(registry: catalogRegistry)
        let catalog = RemoteHostCatalog(connectionManagerProvider: { catalogConnectionManager })
        let lifecycleRecorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: lifecycleRecorder)
            },
            remoteHostRegistry: registry,
            remoteHostCatalog: catalog
        )
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: prompt,
            workspaceManager: workspaceManager
        )
        viewModel.test_setActiveWorkspaceIDForSessionIndex(workspace.id)

        return WorkspaceFixture(
            viewModel: viewModel,
            prompt: prompt,
            workspaceManager: workspaceManager,
            workspace: workspace,
            host: host,
            initialTabID: initialTabID,
            lifecycleRecorder: lifecycleRecorder
        )
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 600 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition", file: file, line: line)
    }

    private func makeRegistry(hosts: [PairedHostRecord]) throws -> RemoteHostRegistry {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let url = RemoteHostTestSupport.registryURL(in: directory)
        if !hosts.isEmpty {
            try RemoteHostTestSupport.writeRegistry(PairedHostRegistryFile(hosts: hosts), to: url)
        }
        return RemoteHostRegistry(url: url)
    }

    private func makeViewModel(registry: RemoteHostRegistry) throws -> AgentModeViewModel {
        let catalogDirectory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let catalogRegistry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: catalogDirectory))
        let catalogConnectionManager = RemoteHostConnectionManager(registry: catalogRegistry)
        let catalog = RemoteHostCatalog(connectionManagerProvider: { catalogConnectionManager })
        return AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in AgentRunLocationNoopCodexController() },
            remoteHostRegistry: registry,
            remoteHostCatalog: catalog
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

final class AgentRunLocationHostOptionAbbreviationTests: XCTestCase {
    func testAbbreviationsStripApostrophesBeforeTokenizing() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [(id: "host-a", displayName: "Tuan's Mac Studio")]
        )

        XCTAssertEqual(abbreviations["host-a"], "TM")
    }

    func testAbbreviationsUseFirstTwoCharactersForSingleToken() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [(id: "host-a", displayName: "Studio")]
        )

        XCTAssertEqual(abbreviations["host-a"], "ST")
    }

    func testAbbreviationsExtendLastTokenForCollisionsDeterministically() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "mac-studio", displayName: "Mac Studio"),
                (id: "mac-server", displayName: "Mac Server")
            ]
        )

        XCTAssertEqual(abbreviations["mac-studio"], "MSt")
        XCTAssertEqual(abbreviations["mac-server"], "MSe")
    }

    func testAbbreviationsDisambiguateIdenticalDisplayNamesWithIDPrefix() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "aa-host", displayName: "Mac Studio"),
                (id: "bb-host", displayName: "Mac Studio")
            ]
        )

        XCTAssertEqual(abbreviations["aa-host"], "MSaa")
        XCTAssertEqual(abbreviations["bb-host"], "MSbb")
    }

    func testAbbreviationFallbackAvoidsReservedDuplicateNameCandidates() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "aa-host", displayName: "Mac Studio"),
                (id: "bb-host", displayName: "Mac Studio"),
                (id: "aa-2", displayName: "Mac S")
            ]
        )

        XCTAssertEqual(abbreviations["aa-host"], "MSaa")
        XCTAssertEqual(abbreviations["bb-host"], "MSbb")
        XCTAssertEqual(abbreviations["aa-2"], "MSaa-")
        XCTAssertEqual(Set(abbreviations.values).count, abbreviations.count)
    }

    func testAbbreviationFallbackAvoidsOtherFallbackCandidates() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "aa-1", displayName: "Mac S"),
                (id: "aa-2", displayName: "Macro S")
            ]
        )

        XCTAssertEqual(abbreviations["aa-1"], "MSaa")
        XCTAssertEqual(abbreviations["aa-2"], "MSaa-")
        XCTAssertEqual(Set(abbreviations.values).count, abbreviations.count)
    }

    func testAbbreviationsArePermutationInvariant() {
        let hosts = [
            (id: "mac-studio", displayName: "Mac Studio"),
            (id: "mac-server", displayName: "Mac Server"),
            (id: "studio", displayName: "Studio"),
            (id: "aa-host", displayName: "Tuan's Mac Studio")
        ]

        XCTAssertEqual(
            AgentRunLocationHostOption.abbreviations(for: hosts),
            AgentRunLocationHostOption.abbreviations(for: Array(hosts.reversed()))
        )
    }
}

private final class AgentRunLocationNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
