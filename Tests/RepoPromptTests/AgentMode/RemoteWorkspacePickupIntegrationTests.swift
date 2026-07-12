@testable import RepoPromptApp
import XCTest

/// V1-11 client-level integration lock for workspace-scoped remote control:
/// a stubbed host catalog renders in the sidebar merge, `pickUpWorkspaceSession`
/// materializes exactly one attached projection tab, the (fake) attach
/// catch-up applies transcript rows through the real coordinator pipeline, the
/// session index entry carries the remote identity used for dedupe, and the
/// picked-up session disappears from the remote sidebar section.
final class RemoteWorkspacePickupIntegrationTests: XCTestCase {
    @MainActor
    func testCatalogSidebarPickupAttachAppliesTranscriptAndIndexesRemoteIdentity() async throws {
        let remoteID = UUID().uuidString
        let localSessionID = try XCTUnwrap(UUID(uuidString: remoteID))
        let remoteDescriptor = descriptor(id: remoteID, name: "Host Review Session", modified: 25)
        let store = StubWorkspacePickupCatalogStore(state: .loaded(.init(
            hostWorkspaceID: "host-workspace",
            hostWorkspaceName: "Project Alpha",
            sessions: [remoteDescriptor],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 40)
        )))
        let fixture = try await makeFixture(store: store)

        // Sidebar merge: the never-seen host session renders as a remote-only row.
        let beforePickup = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(beforePickup.content, .sessions([remoteDescriptor]))
        XCTAssertEqual(beforePickup.hostRecord, fixture.host)

        // Fake attachAndCatchUp: replay host transcript rows through the real
        // coordinator event pipeline, exactly like a live catch-up delivery.
        var attachedTabIDs: [UUID] = []
        fixture.coordinator.test_setMaterializedRemoteWorkspaceAttachHandler { [coordinator = fixture.coordinator] session in
            attachedTabIDs.append(session.tabID)
            coordinator.test_handleEvent(
                .transcriptRows(
                    items: [
                        AgentChatItem.user("Summarize the host-side changes", sequenceIndex: 0),
                        AgentChatItem.assistant("The host session refactored the gateway runtime.", sequenceIndex: 1)
                    ],
                    removedIDs: []
                ),
                tabID: session.tabID
            )
        }

        let pickedUp = await fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remoteDescriptor,
            hostRecord: fixture.host
        )
        let session = try XCTUnwrap(pickedUp)

        // One focused projection tab, bound to the host session.
        XCTAssertEqual(attachedTabIDs, [session.tabID])
        XCTAssertEqual(session.remoteHost?.hostID, fixture.host.id)
        XCTAssertEqual(session.remoteHost?.remoteSessionID, remoteID)
        XCTAssertEqual(session.activeAgentSessionID, localSessionID)
        XCTAssertEqual(session.origin, .user)
        XCTAssertEqual(fixture.workspaceManager.activeWorkspace?.activeComposeTabID, session.tabID)
        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: session.tabID), "Host Review Session")

        // Catch-up transcript rows landed through the coordinator pipeline.
        XCTAssertTrue(session.items.contains {
            $0.kind == .user && $0.text == "Summarize the host-side changes"
        })
        XCTAssertTrue(session.items.contains {
            $0.kind == .assistant && $0.text == "The host session refactored the gateway runtime."
        })
        XCTAssertTrue(session.hasSentFirstMessage)

        // The session index entry carries the remote identity (the pickup
        // dedupe key) for the materialized local session.
        let indexEntry = try XCTUnwrap(fixture.viewModel.ownerValidatedSessionIndex[localSessionID])
        XCTAssertEqual(indexEntry.tabID, session.tabID)
        XCTAssertEqual(indexEntry.remoteHostID, fixture.host.id)
        XCTAssertEqual(indexEntry.remoteHostName, fixture.host.displayName)
        XCTAssertEqual(indexEntry.remoteSessionID, remoteID)

        // The sidebar merge now filters the picked-up session, and a repeat
        // pickup dedupes to a no-op instead of creating a second tab.
        let afterPickup = try XCTUnwrap(fixture.viewModel.remoteWorkspaceSidebarSection())
        XCTAssertEqual(afterPickup.content, .sessions([]))
        let repeatPickup = await fixture.coordinator.pickUpWorkspaceSession(
            descriptor: remoteDescriptor,
            hostRecord: fixture.host
        )
        XCTAssertNil(repeatPickup)
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count { $0.remoteHost?.remoteSessionID == remoteID },
            1
        )
    }

    @MainActor
    private func makeFixture(
        store: StubWorkspacePickupCatalogStore
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
        let indexOwner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        viewModel.test_installSessionIndexSnapshot(
            [:],
            owner: indexOwner,
            latestOwner: indexOwner,
            activeWorkspace: workspace
        )
        viewModel.test_setCurrentTabIDOverride(initialTabID)

        return Fixture(
            viewModel: viewModel,
            coordinator: coordinator,
            workspaceManager: workspaceManager,
            workspace: workspace,
            host: host
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
            itemCount: 2,
            originSummary: "user",
            isLive: true
        )
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let coordinator: RemoteAgentModeCoordinator
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let host: PairedHostRecord
    }
}

@MainActor
private final class StubWorkspacePickupCatalogStore: RemoteWorkspaceSessionCatalogStoring {
    var state: RemoteWorkspaceSessionCatalogStore.State

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
        forceRefresh _: Bool
    ) async -> RemoteWorkspaceSessionCatalogStore.State {
        state
    }

    func invalidate(hostID _: String, clientWorkspaceID _: UUID) {}

    func invalidate(hostID _: String) {}
}
