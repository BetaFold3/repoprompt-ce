@testable import RepoPromptApp
import XCTest

@MainActor
final class RemoteSidebarBadgingTests: XCTestCase {
    func testRemoteHostNameSurvivesBuilderThreadDepthTransform() throws {
        let parentTabID = id(1)
        let childTabID = id(2)
        let parentSessionID = id(101)
        let childSessionID = id(102)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(childTabID, sessionID: childSessionID)
        ]
        let rows = build(
            tabs: tabs,
            sessionIndex: sessionIndex([
                entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(100)),
                entry(
                    childSessionID,
                    tabID: childTabID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(50),
                    remoteHostName: "Studio Mac"
                )
            ])
        )

        let child = try row(for: childTabID, in: rows)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.remoteHostName, "Studio Mac")
    }

    func testRemoteHostNameSurvivesThreadCollapseTransform() throws {
        let viewModel = makeViewModel()
        let parentTabID = id(11)
        let childTabID = id(12)
        let parentSessionID = id(111)
        let childSessionID = id(112)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(childTabID, sessionID: childSessionID)
        ]
        let workspace = WorkspaceModel(
            name: "Remote Sidebar Badge",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: nil
        )
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            sessionIndex([
                entry(
                    parentSessionID,
                    tabID: parentTabID,
                    lastUserMessageAt: date(100),
                    remoteHostName: "Studio Mac"
                ),
                entry(
                    childSessionID,
                    tabID: childTabID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(50)
                )
            ]),
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        viewModel.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

        let rows = viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil)

        XCTAssertEqual(rows.map(\.tabID), [parentTabID])
        let parent = try XCTUnwrap(rows.first)
        XCTAssertEqual(parent.remoteHostName, "Studio Mac")
        XCTAssertTrue(parent.hasThreadChildren)
        XCTAssertTrue(parent.isThreadCollapsed)
        XCTAssertEqual(parent.hiddenThreadDescendantCount, 1)
    }

    private func build(
        tabs: [ComposeTabState],
        sessionIndex: [UUID: AgentSessionIndexEntry]
    ) -> [AgentModeViewModel.SidebarSession] {
        AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            linkedTabs: tabs,
            sessions: [:],
            authoritativeSessionIDByTabID: Dictionary(
                uniqueKeysWithValues: tabs.compactMap { tab in
                    tab.activeAgentSessionID.map { (tab.id, $0) }
                }
            ),
            sessionIndex: sessionIndex,
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: []
        ).build()
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RemoteSidebarNoopCodexController() }
        )
    }

    private func tab(
        _ tabID: UUID,
        sessionID: UUID,
        isPinned: Bool = false,
        lastModified: Date? = nil
    ) -> ComposeTabState {
        ComposeTabState(
            id: tabID,
            name: "Tab \(tabID.uuidString.suffix(4))",
            lastModified: lastModified ?? date(1),
            isPinned: isPinned,
            activeAgentSessionID: sessionID
        )
    }

    private func entry(
        _ sessionID: UUID,
        tabID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date?,
        savedAt: Date? = nil,
        remoteHostName: String? = nil
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Session \(sessionID.uuidString.suffix(4))",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt ?? lastUserMessageAt ?? date(1),
            lastRunStateRaw: nil,
            itemCount: lastUserMessageAt == nil ? 0 : 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            remoteHostID: remoteHostName == nil ? nil : "host-1",
            remoteHostName: remoteHostName,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func sessionIndex(_ entries: [AgentSessionIndexEntry]) -> [UUID: AgentSessionIndexEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private func row(
        for tabID: UUID,
        in rows: [AgentModeViewModel.SidebarSession]
    ) throws -> AgentModeViewModel.SidebarSession {
        try XCTUnwrap(rows.first(where: { $0.tabID == tabID }))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private final class RemoteSidebarNoopCodexController: CodexSessionControlling {
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
