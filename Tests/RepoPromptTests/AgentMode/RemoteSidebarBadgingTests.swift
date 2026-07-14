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
        let registeredHosts = [
            (id: "host-1", displayName: "Mac Studio"),
            (id: "host-2", displayName: "Mac Server")
        ]
        let pillAbbreviations = AgentRunLocationHostOption.abbreviations(for: registeredHosts)
        let rows = build(
            tabs: tabs,
            sessionIndex: sessionIndex([
                entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(100)),
                entry(
                    childSessionID,
                    tabID: childTabID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(50),
                    remoteHostName: "Mac Studio"
                )
            ]),
            registeredRemoteHosts: registeredHosts
        )

        let child = try row(for: childTabID, in: rows)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.remoteHostName, "Mac Studio")
        XCTAssertEqual(child.remoteHostAbbreviation, "MSt")
        XCTAssertEqual(child.remoteHostAbbreviation, pillAbbreviations["host-1"])
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
                    remoteHostName: "Studio Mac",
                    origin: .remote(deviceID: "ab12cd34")
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
        XCTAssertEqual(parent.remoteHostAbbreviation, "SM")
        XCTAssertEqual(parent.remoteControlDeviceID, "ab12cd34")
        XCTAssertTrue(parent.hasThreadChildren)
        XCTAssertTrue(parent.isThreadCollapsed)
        XCTAssertEqual(parent.hiddenThreadDescendantCount, 1)
    }

    func testRemoteControlDeviceIDUsesRemoteOriginFromIndexEntry() throws {
        let tabID = id(21)
        let sessionID = id(121)
        let rows = build(
            tabs: [tab(tabID, sessionID: sessionID)],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ])
        )

        XCTAssertEqual(try row(for: tabID, in: rows).remoteControlDeviceID, "ab12cd34")
    }

    func testRemoteControlDeviceIDIgnoresGatewayMCPOrigin() throws {
        let tabID = id(22)
        let sessionID = id(122)
        let rows = build(
            tabs: [tab(tabID, sessionID: sessionID)],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .mcp(clientID: "repoprompt-gateway")
                )
            ])
        )

        XCTAssertNil(try row(for: tabID, in: rows).remoteControlDeviceID)
    }

    func testRemoteControlDeviceIDPrefersLiveRemoteOriginOverIndexEntry() throws {
        let tabID = id(23)
        let sessionID = id(123)
        let rows = build(
            tabs: [tab(tabID, sessionID: sessionID)],
            sessions: [
                tabID: liveSession(
                    tabID: tabID,
                    sessionID: sessionID,
                    origin: .remote(deviceID: "feedbabe")
                )
            ],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ])
        )

        XCTAssertEqual(try row(for: tabID, in: rows).remoteControlDeviceID, "feedbabe")
    }

    func testRemoteControlDeviceDisplayNameUsesBuilderMap() throws {
        let namedTabID = id(24)
        let unknownTabID = id(25)
        let revokedNamedTabID = id(26)
        let namedSessionID = id(124)
        let unknownSessionID = id(125)
        let revokedNamedSessionID = id(126)
        let rows = build(
            tabs: [
                tab(namedTabID, sessionID: namedSessionID),
                tab(unknownTabID, sessionID: unknownSessionID),
                tab(revokedNamedTabID, sessionID: revokedNamedSessionID)
            ],
            sessionIndex: sessionIndex([
                entry(
                    namedSessionID,
                    tabID: namedTabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                ),
                entry(
                    unknownSessionID,
                    tabID: unknownTabID,
                    lastUserMessageAt: date(90),
                    origin: .remote(deviceID: "feedbabe")
                ),
                entry(
                    revokedNamedSessionID,
                    tabID: revokedNamedTabID,
                    lastUserMessageAt: date(80),
                    origin: .remote(deviceID: "deadbeef")
                )
            ]),
            pairedDeviceDisplayNameByBareID: [
                "ab12cd34": "Tuan’s MacBook Pro",
                "deadbeef": "Revoked MacBook"
            ]
        )

        let named = try row(for: namedTabID, in: rows)
        XCTAssertEqual(named.remoteControlDeviceID, "ab12cd34")
        XCTAssertEqual(named.remoteControlDeviceDisplayName, "Tuan’s MacBook Pro")
        XCTAssertNil(try row(for: unknownTabID, in: rows).remoteControlDeviceDisplayName)
        XCTAssertEqual(try row(for: revokedNamedTabID, in: rows).remoteControlDeviceDisplayName, "Revoked MacBook")
    }

    func testRemoteControlDeviceDisplayNameSurvivesBuilderThreadDepthTransform() throws {
        let parentTabID = id(27)
        let childTabID = id(28)
        let parentSessionID = id(127)
        let childSessionID = id(128)
        let rows = build(
            tabs: [
                tab(parentTabID, sessionID: parentSessionID),
                tab(childTabID, sessionID: childSessionID)
            ],
            sessionIndex: sessionIndex([
                entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(100)),
                entry(
                    childSessionID,
                    tabID: childTabID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(50),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ]),
            pairedDeviceDisplayNameByBareID: ["ab12cd34": "Threaded Mac"]
        )

        let child = try row(for: childTabID, in: rows)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.remoteControlDeviceID, "ab12cd34")
        XCTAssertEqual(child.remoteControlDeviceDisplayName, "Threaded Mac")
    }

    func testSidebarRecencyFloorIgnoresEpochLastUserMessageButPreservesTitleIntent() throws {
        let tabID = id(29)
        let sessionID = id(129)
        let savedAt = date(1_750_000_000)
        // Default-blank tab name ("T29"): if the recency floor leaked into title
        // intent, hasSentUserMessage would flip false and the empty-session title
        // ("New Chat") would replace it. Linked entries render the tab name by design.
        let rows = build(
            tabs: [
                ComposeTabState(
                    id: tabID,
                    name: "T29",
                    lastModified: date(1),
                    isPinned: false,
                    activeAgentSessionID: sessionID
                )
            ],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    name: "New Session",
                    lastUserMessageAt: date(1_000_005),
                    savedAt: savedAt,
                    itemCount: 0,
                    origin: .remote(deviceID: "ab12cd34")
                )
            ])
        )

        let row = try row(for: tabID, in: rows)
        XCTAssertNil(row.lastUserMessageAt)
        XCTAssertEqual(row.activityDate, savedAt)
        XCTAssertEqual(row.title, "T29")
        XCTAssertEqual(
            AgentSidebarDateSectionBuilder.activeGroups(for: rows, now: savedAt).first?.bucket,
            .today
        )
    }

    func testSidebarRecencyFloorPreservesGenuineUserDate() throws {
        let tabID = id(30)
        let sessionID = id(130)
        let genuineUserDate = date(1_704_067_200)
        let rows = build(
            tabs: [tab(tabID, sessionID: sessionID)],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: genuineUserDate,
                    savedAt: date(1_750_000_000),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ])
        )

        let row = try row(for: tabID, in: rows)
        XCTAssertEqual(row.lastUserMessageAt, genuineUserDate)
        XCTAssertEqual(row.activityDate, genuineUserDate)
    }

    func testRemoteControlDeviceBadgeTextUsesFriendlyNameAndHexTooltip() {
        let known = AgentSessionRow.remoteControlDeviceBadgeText(
            deviceID: "ab12cd34",
            displayName: "Tuan’s MacBook Pro"
        )
        XCTAssertEqual(known.label, "TMP")
        XCTAssertEqual(known.badgeTooltip, "Remote controlled by Tuan’s MacBook Pro (ab12cd34)")
        XCTAssertEqual(known.statusPlateTooltip, "Remote controlled by Tuan’s MacBook Pro (ab12cd34)")

        XCTAssertEqual(AgentSessionRow.remoteControlDeviceBadgeAbbreviation(for: "Studio"), "STU")
        XCTAssertEqual(AgentSessionRow.remoteControlDeviceBadgeAbbreviation(for: "Mac mini"), "MM")
        XCTAssertEqual(AgentSessionRow.remoteControlDeviceBadgeAbbreviation(for: "Tuan's iPad Pro 13"), "TIP")

        let unknown = AgentSessionRow.remoteControlDeviceBadgeText(deviceID: "remote:feedbabe", displayName: nil)
        XCTAssertEqual(unknown.label, "feedbabe")
        XCTAssertEqual(unknown.badgeTooltip, "Remote-controlled by device remote:feedbabe")
        XCTAssertEqual(unknown.statusPlateTooltip, "Remote controlled (device feedbabe)")
    }

    func testSidebarSessionEqualityIncludesRemoteControlDeviceID() {
        let tabID = id(31)
        let base = AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: "Remote",
            lastUserMessageAt: nil,
            activityDate: date(100),
            isPinned: false,
            sessionID: id(131),
            parentSessionID: nil,
            depth: 0,
            isMCPControlled: true,
            remoteControlDeviceID: "ab12cd34"
        )
        let changed = AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: "Remote",
            lastUserMessageAt: nil,
            activityDate: date(100),
            isPinned: false,
            sessionID: id(131),
            parentSessionID: nil,
            depth: 0,
            isMCPControlled: true,
            remoteControlDeviceID: "feedbabe"
        )

        XCTAssertNotEqual(base, changed)
    }

    func testSidebarSessionEqualityIncludesRemoteControlDeviceDisplayName() {
        let tabID = id(32)
        let base = AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: "Remote",
            lastUserMessageAt: nil,
            activityDate: date(100),
            isPinned: false,
            sessionID: id(132),
            parentSessionID: nil,
            depth: 0,
            isMCPControlled: true,
            remoteControlDeviceID: "ab12cd34",
            remoteControlDeviceDisplayName: "Tuan’s MacBook Pro"
        )
        let changed = AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: "Remote",
            lastUserMessageAt: nil,
            activityDate: date(100),
            isPinned: false,
            sessionID: id(132),
            parentSessionID: nil,
            depth: 0,
            isMCPControlled: true,
            remoteControlDeviceID: "ab12cd34",
            remoteControlDeviceDisplayName: "Office MacBook"
        )

        XCTAssertNotEqual(base, changed)
    }

    func testSidebarContentFingerprintIncludesRemoteDeviceDisplayNameMap() {
        let tabID = id(33)
        let sessionID = id(133)
        let base = AgentModeViewModel.AgentSessionSidebarContentFingerprint(
            currentTabID: nil,
            sessionListCacheReady: true,
            tabsWithActiveAgentRun: Set<UUID>(),
            mcpControlledTabIDs: Set<UUID>(),
            tabMetadataSignatures: [],
            sessionSignatures: [],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ]),
            pairedDeviceDisplayNameByBareID: ["ab12cd34": "Tuan’s MacBook Pro"],
            sessionListSortDates: [:],
            sidebarRestoreFrozenOrderByTabID: [:]
        )
        let changed = AgentModeViewModel.AgentSessionSidebarContentFingerprint(
            currentTabID: nil,
            sessionListCacheReady: true,
            tabsWithActiveAgentRun: Set<UUID>(),
            mcpControlledTabIDs: Set<UUID>(),
            tabMetadataSignatures: [],
            sessionSignatures: [],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ]),
            pairedDeviceDisplayNameByBareID: ["ab12cd34": "Office MacBook"],
            sessionListSortDates: [:],
            sidebarRestoreFrozenOrderByTabID: [:]
        )

        XCTAssertNotEqual(base, changed)
    }

    func testSidebarContentFingerprintIncludesPersistedRemoteOrigin() {
        let tabID = id(34)
        let sessionID = id(134)
        let mcpFingerprint = AgentModeViewModel.AgentSessionSidebarContentFingerprint(
            currentTabID: nil,
            sessionListCacheReady: true,
            tabsWithActiveAgentRun: Set<UUID>(),
            mcpControlledTabIDs: Set<UUID>(),
            tabMetadataSignatures: [],
            sessionSignatures: [],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .mcp(clientID: "repoprompt-gateway")
                )
            ]),
            sessionListSortDates: [:],
            sidebarRestoreFrozenOrderByTabID: [:]
        )
        let remoteFingerprint = AgentModeViewModel.AgentSessionSidebarContentFingerprint(
            currentTabID: nil,
            sessionListCacheReady: true,
            tabsWithActiveAgentRun: Set<UUID>(),
            mcpControlledTabIDs: Set<UUID>(),
            tabMetadataSignatures: [],
            sessionSignatures: [],
            sessionIndex: sessionIndex([
                entry(
                    sessionID,
                    tabID: tabID,
                    lastUserMessageAt: date(100),
                    origin: .remote(deviceID: "ab12cd34")
                )
            ]),
            sessionListSortDates: [:],
            sidebarRestoreFrozenOrderByTabID: [:]
        )

        XCTAssertNotEqual(mcpFingerprint, remoteFingerprint)
    }

    private func build(
        tabs: [ComposeTabState],
        sessions: [UUID: AgentModeViewModel.TabSession] = [:],
        sessionIndex: [UUID: AgentSessionIndexEntry],
        registeredRemoteHosts: [(id: String, displayName: String)] = [],
        pairedDeviceDisplayNameByBareID: [String: String] = [:]
    ) -> [AgentModeViewModel.SidebarSession] {
        AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            linkedTabs: tabs,
            sessions: sessions,
            authoritativeSessionIDByTabID: Dictionary(
                uniqueKeysWithValues: tabs.compactMap { tab in
                    tab.activeAgentSessionID.map { (tab.id, $0) }
                }
            ),
            sessionIndex: sessionIndex,
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: [],
            registeredRemoteHosts: registeredRemoteHosts,
            pairedDeviceDisplayNameByBareID: pairedDeviceDisplayNameByBareID
        ).build()
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RemoteSidebarNoopCodexController() }
        )
    }

    private func liveSession(
        tabID: UUID,
        sessionID: UUID,
        origin: AgentSessionOrigin
    ) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.hasLoadedPersistedState = true
        session.origin = origin
        session.lastUserMessageAt = date(100)
        session.lastActivityAt = date(100)
        return session
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
        name: String? = nil,
        lastUserMessageAt: Date?,
        savedAt: Date? = nil,
        itemCount: Int? = nil,
        remoteHostName: String? = nil,
        origin: AgentSessionOrigin? = nil
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: name ?? "Session \(sessionID.uuidString.suffix(4))",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt ?? lastUserMessageAt ?? date(1),
            lastRunStateRaw: nil,
            itemCount: itemCount ?? (lastUserMessageAt == nil ? 0 : 1),
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            remoteHostID: remoteHostName == nil ? nil : "host-1",
            remoteHostName: remoteHostName,
            isMCPOriginated: origin?.isMCPOriginated ?? false,
            origin: origin,
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
