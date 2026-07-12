@testable import RepoPromptApp
import XCTest

final class RemoteWorkspaceSidebarTests: XCTestCase {
    @MainActor
    func testLoadedCatalogProjectionFiltersAlreadyLocalAndSortsRemoteRows() async throws {
        let localRemoteID = UUID().uuidString
        let newestRemoteID = UUID().uuidString
        let olderRemoteID = UUID().uuidString
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: "host-workspace",
            hostWorkspaceName: "Project Alpha",
            sessions: [
                descriptor(id: localRemoteID, name: "Already here", modified: 30),
                descriptor(id: olderRemoteID, name: "Older remote", modified: 10),
                descriptor(id: newestRemoteID, name: "Newest remote", modified: 20)
            ],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 40)
        )))
        let fixture = try await makeFixture(store: store)
        let localSession = await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        localSession.remoteHost = binding(
            host: fixture.host,
            remoteSessionID: localRemoteID
        )

        let section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        guard case let .sessions(descriptors) = section.content else {
            return XCTFail("Expected loaded remote workspace sessions")
        }
        XCTAssertEqual(descriptors.map(\.sessionID), [newestRemoteID, olderRemoteID])
        XCTAssertEqual(section.hostRecord, fixture.host)
        XCTAssertEqual(section.workspaceID, fixture.workspace.id)
    }

    @MainActor
    func testCatalogFailureStatesExposeActionableCopyAndRetry() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .workspaceNotOpen(message: "closed"))
        let fixture = try await makeFixture(store: store)

        var section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(
            section.content,
            .workspaceNotOpen(
                "Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
            )
        )

        store.state = .unsupported
        section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(
            section.content,
            .unsupported("Studio Mac doesn't support workspace browsing (update RepoPrompt on the host).")
        )

        store.state = .error("Host is offline")
        section = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(section.content, .error("Host is offline"))

        await fixture.viewModel.retryRemoteWorkspaceSidebar()
        XCTAssertEqual(store.invalidatedWorkspaceIDs, [fixture.workspace.id])
        XCTAssertEqual(store.fetchForceRefreshValues, [true])
    }

    @MainActor
    func testWorkspacePickupMaterializesFocusedUserTabOnceAndAttaches() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let fixture = try await makeFixture(store: store)
        let remoteID = UUID().uuidString
        let remote = descriptor(id: remoteID, name: "Host Session", modified: 10)
        var attachCount = 0
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { _ in
            attachCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        async let first = fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remote,
            hostRecord: fixture.host
        )
        await Task.yield()
        async let second = fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remote,
            hostRecord: fixture.host
        )
        let (firstResult, secondResult) = await (first, second)

        let materialized = try XCTUnwrap(firstResult ?? secondResult)
        XCTAssertEqual([firstResult, secondResult].compactMap(\.self).count, 1)
        XCTAssertEqual(attachCount, 1)
        XCTAssertEqual(materialized.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(materialized.remoteHost?.remoteSessionID, remoteID)
        XCTAssertEqual(materialized.origin, .user)
        XCTAssertNil(materialized.parentSessionID)
        XCTAssertEqual(fixture.workspaceManager.activeWorkspace?.activeComposeTabID, materialized.tabID)
        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: materialized.tabID), "Host Session")
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count { $0.remoteHost?.remoteSessionID == remoteID },
            1
        )
    }

    @MainActor
    func testWorkspacePickupAttachFailureKeepsTabAndAppendsSystemMessage() async throws {
        let store = StubWorkspaceSessionCatalogStore(state: .loaded(.init(
            hostWorkspaceID: nil,
            hostWorkspaceName: nil,
            sessions: [],
            fetchedAt: Date()
        )))
        let fixture = try await makeFixture(store: store)
        let remoteID = UUID().uuidString
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { _ in
            throw WorkspacePickupTestError.attachFailed
        }

        let pickedUp = await fixture.coordinator.pickUpWorkspaceSession(
            descriptor: descriptor(id: remoteID, name: "Kept Session", modified: 1),
            hostRecord: fixture.host
        )
        let session = try XCTUnwrap(pickedUp)

        XCTAssertTrue(fixture.viewModel.sessions[session.tabID] === session)
        XCTAssertTrue(session.items.contains {
            $0.kind == .system
                && $0.text.contains("Remote workspace session attach failed")
                && $0.text.contains("attachFailed")
        })
    }

    @MainActor
    func testWorkspaceErrorsUseFriendlyWorkspaceAndHostCopy() {
        for code in ["workspace_not_open", "workspace_mismatch"] {
            let error = RemoteClientError.fromCommandError(
                code: code,
                message: code == "workspace_not_open"
                    ? "Workspace 'Project Alpha' is not open on the host."
                    : "workspace_mismatch: requested workspace differs"
            )
            XCTAssertEqual(
                RemoteAgentModeCoordinator.describe(
                    error,
                    workspaceName: "Project Alpha",
                    hostName: "Studio Mac"
                ),
                "Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
            )
        }

        let unscopedMismatch = RemoteClientError.fromCommandError(
            code: "workspace_mismatch",
            message: "workspace_mismatch: the target window's active workspace is 'Other' (id), not requested"
        )
        XCTAssertEqual(
            RemoteAgentModeCoordinator.describe(unscopedMismatch),
            "The requested workspace is not open on the host. Open it there and try again."
        )
    }

    @MainActor
    func testClosedWorkspaceSendFailureUsesSystemCopyAndResetsRunState() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.runState = .running
        session.setRunningStatus("Starting on Studio Mac…", source: .transport)
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote start failed",
            error: RemoteClientError.fromCommandError(
                code: "workspace_not_open",
                message: "Workspace 'Project Alpha' is not open on the host."
            )
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.runningStatusText)
        XCTAssertFalse(session.pendingRemoteOptimisticUserItemIDs.contains(optimisticID))
        let system = try XCTUnwrap(session.items.last)
        XCTAssertEqual(system.kind, .system)
        XCTAssertEqual(
            system.text,
            "Remote start failed: Workspace 'Project Alpha' is not open on Studio Mac. Open it there and try again."
        )
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(tabID: session.tabID, itemID: system.id))
    }

    @MainActor
    func testTransportSendFailureOffersLocalFallbackAndSubsequentLocalSendSucceeds() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        // Failed INITIAL start: the host never adopted a session for this run,
        // so falling back locally cannot orphan a still-running host session.
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "")
        XCTAssertNil(session.remoteHost?.normalizedRemoteSessionID)
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.runState = .running
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused")
        )

        let failureItem = try XCTUnwrap(session.items.last)
        XCTAssertEqual(failureItem.kind, .system)
        XCTAssertTrue(failureItem.text.contains("Remote transport failed: connection refused"))
        XCTAssertTrue(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        fixture.viewModel.runLocallyInsteadAfterRemoteFailure(tabID: session.tabID)
        XCTAssertNil(session.remoteHost)
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        let outcome = await fixture.viewModel.startAgentRun(
            tabID: session.tabID,
            initialMessage: "Run this locally"
        )
        XCTAssertTrue(outcome?.didSend == true, String(describing: outcome))
        XCTAssertTrue(fixture.lifecycleRecorder.events.contains("codex:send"))
        XCTAssertNil(session.remoteHost)
    }

    @MainActor
    func testTransportSteerFailureWithAdoptedRemoteSessionDoesNotOfferLocalFallback() async throws {
        let fixture = try await makeFixture(store: StubWorkspaceSessionCatalogStore(state: .error("unused")))
        let session = await fixture.viewModel.ensureSessionReady(tabID: fixture.initialTabID)
        // Adopted host session (non-empty remoteSessionID): a steer transport
        // failure does not mean the host run stopped, so "Run locally instead"
        // would create a dual-execution hazard and must not be offered.
        session.remoteHost = binding(host: fixture.host, remoteSessionID: "remote-abc123")
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5.4"
        session.hasSentFirstMessage = true
        session.appendItem(.user("already running on the host", sequenceIndex: 0))
        session.runState = .running
        let optimisticID = UUID()
        session.pendingRemoteOptimisticUserItemIDs.insert(optimisticID)

        fixture.viewModel.failRemoteSend(
            session: session,
            tabID: session.tabID,
            optimisticUserItemID: optimisticID,
            prefix: "Remote send failed",
            error: RemoteClientError.transport("connection refused")
        )

        let failureItem = try XCTUnwrap(session.items.last)
        XCTAssertEqual(failureItem.kind, .system)
        XCTAssertTrue(failureItem.text.contains("Remote transport failed: connection refused"))
        XCTAssertEqual(session.runState, .failed)
        XCTAssertFalse(fixture.viewModel.shouldOfferRunLocallyInstead(
            tabID: session.tabID,
            itemID: failureItem.id
        ))

        fixture.viewModel.runLocallyInsteadAfterRemoteFailure(tabID: session.tabID)
        XCTAssertEqual(session.remoteHost?.remoteSessionID, "remote-abc123")
        XCTAssertEqual(session.remoteHost?.hostID, fixture.host.id)
    }

    @MainActor
    private func makeFixture(
        store: StubWorkspaceSessionCatalogStore
    ) async throws -> Fixture {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let host = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(host)

        let initialTabID = UUID()
        let workspace = WorkspaceModel(
            name: "Project Alpha",
            repoPaths: [FileManager.default.currentDirectoryPath],
            defaultRemoteHostID: host.id,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: initialTabID, name: "Initial")],
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

        let coordinator = RemoteAgentModeCoordinator(workspaceSessionCatalogStore: store)
        let lifecycleRecorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: lifecycleRecorder)
            },
            remoteHostRegistry: registry,
            testRemoteCoordinator: coordinator
        )
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: prompt,
            workspaceManager: workspaceManager
        )
        viewModel.test_setActiveWorkspaceIDForSessionIndex(workspace.id)
        viewModel.test_setCurrentTabIDOverride(initialTabID)

        return Fixture(
            viewModel: viewModel,
            coordinator: coordinator,
            prompt: prompt,
            workspaceManager: workspaceManager,
            workspace: workspace,
            host: host,
            initialTabID: initialTabID,
            lifecycleRecorder: lifecycleRecorder
        )
    }

    private func descriptor(
        id: String,
        name: String,
        modified: TimeInterval
    ) -> RemoteAgentSessionDescriptor {
        RemoteAgentSessionDescriptor(
            sessionID: id,
            name: name,
            stateRaw: "running",
            agentKindRaw: AgentProviderKind.codexExec.rawValue,
            agentModelRaw: "gpt-5.4",
            parentSessionID: nil,
            lastModified: Date(timeIntervalSinceReferenceDate: modified),
            itemCount: 3,
            originSummary: "user",
            isLive: true
        )
    }

    private func binding(
        host: PairedHostRecord,
        remoteSessionID: String
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: host.id,
            hostDisplayName: host.displayName,
            remoteSessionID: remoteSessionID
        )
    }

    @MainActor
    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition", file: file, line: line)
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let coordinator: RemoteAgentModeCoordinator
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let host: PairedHostRecord
        let initialTabID: UUID
        let lifecycleRecorder: LifecycleRecorder
    }
}

@MainActor
private final class StubWorkspaceSessionCatalogStore: RemoteWorkspaceSessionCatalogStoring {
    var state: RemoteWorkspaceSessionCatalogStore.State
    private(set) var invalidatedWorkspaceIDs: [UUID] = []
    private(set) var fetchForceRefreshValues: [Bool] = []

    init(state: RemoteWorkspaceSessionCatalogStore.State) {
        self.state = state
    }

    func cachedState(
        hostID _: String,
        clientWorkspaceID _: UUID
    ) -> RemoteWorkspaceSessionCatalogStore.State? {
        state
    }

    func fetch(
        hostID _: String,
        clientWorkspaceID _: UUID,
        workspaceName _: String,
        forceRefresh: Bool
    ) async -> RemoteWorkspaceSessionCatalogStore.State {
        fetchForceRefreshValues.append(forceRefresh)
        return state
    }

    func invalidate(hostID _: String, clientWorkspaceID: UUID) {
        invalidatedWorkspaceIDs.append(clientWorkspaceID)
    }

    func invalidate(hostID _: String) {}
}

private enum WorkspacePickupTestError: Error {
    case attachFailed
}
