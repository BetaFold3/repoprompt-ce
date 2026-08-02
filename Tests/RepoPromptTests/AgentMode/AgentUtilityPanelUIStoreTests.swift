import Combine
@testable import RepoPromptApp
import XCTest

/// The active-tab facade for utility panel state.
///
/// These tests exercise the `make…UISnapshot()` / `sync…UIState()` ritual the rest of Agent Mode
/// uses: canonical state lives on `TabSession`, and the store publishes only the current tab's copy.
@MainActor
final class AgentUtilityPanelUIStoreTests: XCTestCase {
    // MARK: - Snapshot

    func testSnapshotFallsBackToDefaultsWhileNoTabIsActive() throws {
        let viewModel = try makeViewModel()

        viewModel.syncUtilityPanelUIState()

        XCTAssertNil(viewModel.ui.utilityPanel.snapshot.currentTabID)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel, AgentUtilityPanelTabState())
    }

    func testSyncPublishesTheActiveTabsPanelState() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        session.utilityPanel.select(segment: .preview)
        session.utilityPanel.setCompareSelection(.vsBase)
        viewModel.syncUtilityPanelUIState()

        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.currentTabID, tabID)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.segment, .preview)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel.compareSelection, .vsBase)
    }

    // MARK: - Per-tab isolation

    func testEachTabKeepsItsOwnSegmentAcrossTabSwitches() async throws {
        let viewModel = try makeViewModel()
        let firstTabID = id(1)
        let secondTabID = id(2)
        _ = await viewModel.ensureSessionReady(tabID: firstTabID)
        _ = await viewModel.ensureSessionReady(tabID: secondTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.test_setCurrentTabIDOverride(firstTabID)
        viewModel.selectUtilityPanelSegment(.preview)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.segment, .preview)

        // Switching tabs is exactly what `AgentModeDetailWithSidebarView` does on
        // `onChange(of: currentTabID)`.
        viewModel.test_setCurrentTabIDOverride(secondTabID)
        viewModel.syncUtilityPanelUIState()
        XCTAssertEqual(
            viewModel.ui.utilityPanel.snapshot.segment,
            .changes,
            "a second tab must open on its own default rather than inherit the first tab's segment"
        )

        viewModel.test_setCurrentTabIDOverride(firstTabID)
        viewModel.syncUtilityPanelUIState()
        XCTAssertEqual(
            viewModel.ui.utilityPanel.snapshot.segment,
            .preview,
            "returning to a tab restores what that tab was last showing"
        )
    }

    func testMutatingABackgroundTabDoesNotDisturbTheActiveSnapshot() async throws {
        let viewModel = try makeViewModel()
        let activeTabID = id(1)
        let backgroundTabID = id(2)
        _ = await viewModel.ensureSessionReady(tabID: activeTabID)
        let backgroundSession = await viewModel.ensureSessionReady(tabID: backgroundTabID)
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        viewModel.syncUtilityPanelUIState()

        viewModel.selectUtilityPanelSegment(.preview, tabID: backgroundTabID)

        XCTAssertEqual(backgroundSession.utilityPanel.segment, .preview, "the background tab still records the change")
        XCTAssertEqual(
            viewModel.ui.utilityPanel.snapshot.segment,
            .changes,
            "publishing a background tab's state would show the active tab someone else's panel"
        )
    }

    // MARK: - Mutation seams

    func testExpansionTogglesReportWhetherTheFileOpened() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        XCTAssertTrue(viewModel.toggleUtilityPanelFileExpansion(filePath: "Sources/App.swift"))
        XCTAssertTrue(session.utilityPanel.isExpanded(filePath: "Sources/App.swift"))
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel.expandedFilePaths, ["Sources/App.swift"])

        XCTAssertFalse(viewModel.toggleUtilityPanelFileExpansion(filePath: "Sources/App.swift"))
        XCTAssertTrue(viewModel.ui.utilityPanel.snapshot.panel.expandedFilePaths.isEmpty)
    }

    func testContextEscalationReturnsTheLevelToRequestFromTheDiffEngine() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        XCTAssertEqual(viewModel.escalateUtilityPanelContext(filePath: "a.swift"), .expanded)
        XCTAssertEqual(viewModel.escalateUtilityPanelContext(filePath: "a.swift"), .fullFile)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel.contextLevel(forFilePath: "a.swift"), .fullFile)
    }

    func testTheArtifactBannerDeepLinkOpensThePreviewSegmentOnThatDocument() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let document = PreviewDocumentReference(rootID: UUID(), relativePath: "docs/impl-report.md")

        viewModel.showUtilityPanelPreview(of: document)

        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.segment, .preview)
        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel.previewDocument, document)
    }

    func testDismissedBannersAreRememberedPerTab() async throws {
        let viewModel = try makeViewModel()
        let firstTabID = id(1)
        let secondTabID = id(2)
        _ = await viewModel.ensureSessionReady(tabID: firstTabID)
        _ = await viewModel.ensureSessionReady(tabID: secondTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.test_setCurrentTabIDOverride(firstTabID)
        viewModel.dismissUtilityPanelBanner(artifactID: "artifact-1")

        XCTAssertTrue(viewModel.utilityPanelState(tabID: firstTabID).isBannerDismissed(artifactID: "artifact-1"))
        XCTAssertFalse(
            viewModel.utilityPanelState(tabID: secondTabID).isBannerDismissed(artifactID: "artifact-1"),
            "the banner reports what this session's agent wrote, so dismissal cannot be shared"
        )
    }

    func testTheLastUsedBaseBranchIsRecalledPerRepository() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.selectUtilityPanelBaseBranch("develop", forRepoRoot: "/repos/alpha")

        XCTAssertEqual(viewModel.utilityPanelLastUsedBaseBranch(forRepoRoot: "/repos/alpha"), "develop")
        XCTAssertNil(viewModel.utilityPanelLastUsedBaseBranch(forRepoRoot: "/repos/beta"))
    }

    func testTheCompareSelectionReachesTheRepositoryLayerOnlyOnceABaseIsNamed() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        viewModel.setUtilityPanelCompareSelection(.vsBase)
        XCTAssertNil(
            viewModel.ui.utilityPanel.snapshot.panel.resolvedCompareMode,
            "the panel must offer a base picker rather than infer one"
        )

        viewModel.selectUtilityPanelBaseBranch("main", forRepoRoot: "/repos/alpha")

        XCTAssertEqual(viewModel.ui.utilityPanel.snapshot.panel.resolvedCompareMode, .vsBase(base: "main"))
    }

    // MARK: - Publishing

    func testAnUnchangedSnapshotDoesNotRepublish() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        viewModel.syncUtilityPanelUIState()

        var publishCount = 0
        let cancellable = viewModel.ui.utilityPanel.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancellable.cancel() }

        viewModel.syncUtilityPanelUIState()
        viewModel.syncUtilityPanelUIState()
        XCTAssertEqual(publishCount, 0, "a resync with identical state must not invalidate SwiftUI views")

        viewModel.selectUtilityPanelSegment(.preview)
        XCTAssertEqual(publishCount, 1)
    }

    func testSelectingTheSegmentAlreadyShownDoesNotRepublish() async throws {
        let viewModel = try makeViewModel()
        let tabID = id(1)
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        viewModel.syncUtilityPanelUIState()

        var publishCount = 0
        let cancellable = viewModel.ui.utilityPanel.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancellable.cancel() }

        viewModel.selectUtilityPanelSegment(.changes)

        XCTAssertEqual(publishCount, 0)
    }

    // MARK: - Harness

    private func makeViewModel() throws -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in AgentUtilityPanelNoopCodexController() }
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private final class AgentUtilityPanelNoopCodexController: CodexSessionControlling {
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
