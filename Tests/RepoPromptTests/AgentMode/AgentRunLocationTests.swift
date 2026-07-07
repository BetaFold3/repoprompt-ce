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
        XCTAssertEqual(runProps.selectedHostAbbreviation, "sm")

        let worktreeProps = try XCTUnwrap(viewModel.executionLocationProps(tabID: tabID))
        XCTAssertFalse(worktreeProps.isEnabled)
        XCTAssertEqual(worktreeProps.disabledReason, AgentModeViewModel.remoteWorktreeManagedReason)
        XCTAssertEqual(worktreeProps.selection, .local)
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

        XCTAssertEqual(abbreviations["host-a"], "tm")
    }

    func testAbbreviationsUseFirstTwoCharactersForSingleToken() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [(id: "host-a", displayName: "Studio")]
        )

        XCTAssertEqual(abbreviations["host-a"], "st")
    }

    func testAbbreviationsExtendLastTokenForCollisionsDeterministically() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "mac-studio", displayName: "Mac Studio"),
                (id: "mac-server", displayName: "Mac Server")
            ]
        )

        XCTAssertEqual(abbreviations["mac-studio"], "mst")
        XCTAssertEqual(abbreviations["mac-server"], "mse")
    }

    func testAbbreviationsDisambiguateIdenticalDisplayNamesWithIDPrefix() {
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: [
                (id: "aa-host", displayName: "Mac Studio"),
                (id: "bb-host", displayName: "Mac Studio")
            ]
        )

        XCTAssertEqual(abbreviations["aa-host"], "msaa")
        XCTAssertEqual(abbreviations["bb-host"], "msbb")
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
