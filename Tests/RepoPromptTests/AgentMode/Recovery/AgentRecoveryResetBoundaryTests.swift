import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless-restart Phase 1b: the VM transcript-reset boundary with recovery composed. A reset
/// preserves the old composer, joins (never queues behind) an in-flight normal save, keeps
/// admission frozen until the reset receipt actually commits, and clears live/provider state only
/// after that commit. A failed commit clears nothing, keeps the old generation, and reopens
/// admission. Real temporary store, real DataService gate, real VM save path.
@MainActor
final class AgentRecoveryResetBoundaryTests: XCTestCase {
    func testResetJoinsHeldInFlightSaveRefusesInputAndClearsOnlyAfterCommit() async throws {
        let harness = try await makeHarness(windowID: 4601)
        let oldLane = try await persistAndClaimLane(harness)
        harness.session.providerSessionID = "provider-before-reset"
        harness.session.draftText = "draft before reset"

        // A normal save suspended in its write.
        let gate = ResetBoundaryWriteGate()
        harness.viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("Saved by the held write"))
        let heldSave = Task { await harness.viewModel.flushSaveDetailed(for: harness.tabID) }
        let saveHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(saveHeld)

        var commitHookCalls = 0
        var admissionDuringCommit: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>?
        harness.viewModel.test_recoveryResetBeforeCommitHook = { session in
            commitHookCalls += 1
            XCTAssertEqual(session.items.count, 2, "Nothing is cleared before the reset commit")
            admissionDuringCommit = await Self.admitQueued("typed during the commit", on: oldLane)
        }
        let reset = Task { await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID) }
        let frozen = await RecoveryTestSupport.eventually { oldLane.isResetPreparationActive }
        XCTAssertTrue(frozen)
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // The reset waits for the writer; the old state is intact and admission stays frozen.
        XCTAssertEqual(commitHookCalls, 0, "The reset never commits around an in-flight write")
        XCTAssertEqual(harness.session.items.map(\.text), ["Before reset", "Saved by the held write"])
        XCTAssertEqual(harness.session.providerSessionID, "provider-before-reset")
        guard case .failure(.refused(.resetPreparationInProgress)) = await Self.admitQueued("typed while joined", on: oldLane) else {
            return XCTFail("Admission is frozen while the reset joins the writer")
        }

        gate.release()
        let heldOutcome = await heldSave.value
        guard case .written = heldOutcome else {
            return XCTFail("The held save writes its old-generation snapshot, got \(heldOutcome)")
        }
        let outcome = await reset.value
        harness.viewModel.test_saveSessionBeforeWriteHook = nil
        harness.viewModel.test_recoveryResetBeforeCommitHook = nil

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(commitHookCalls, 1)
        guard case .failure(.refused(.resetPreparationInProgress))? = admissionDuringCommit else {
            return XCTFail("Admission is frozen through the commit, got \(String(describing: admissionDuringCommit))")
        }
        XCTAssertTrue(oldLane.isRetired, "The successor claim retired the frozen lane")
        let newLane = try XCTUnwrap(harness.session.recoveryLane)
        XCTAssertFalse(newLane === oldLane)
        XCTAssertEqual(newLane.binding.transcriptResetGeneration, 1, "The generation advanced exactly once")
        XCTAssertEqual(harness.session.persistenceState?.transcriptResetGeneration, 1)
        XCTAssertNil(harness.session.pendingTranscriptResetReceipt, "No reset is left for a later normal save")
        XCTAssertTrue(harness.session.items.isEmpty)
        XCTAssertNil(harness.session.providerSessionID)

        let fileText = try await harness.persistedFileText()
        XCTAssertFalse(fileText.contains("Before reset"), fileText)
        XCTAssertFalse(fileText.contains("Saved by the held write"), fileText)

        // The preserved old-generation composer is held for explicit resolution, never adopted.
        let held = await RecoveryTestSupport.eventually {
            if case .held = newLane.composerState { return true }
            return false
        }
        XCTAssertTrue(held)
        guard case let .held(snapshot) = newLane.composerState else {
            return XCTFail("Expected a held composer, got \(newLane.composerState)")
        }
        XCTAssertEqual(snapshot.content.text, "draft before reset")
        XCTAssertEqual(snapshot.transcriptResetGeneration, 0)
    }

    func testResetCommitFailureClearsNothingKeepsGenerationAndReopensAdmission() async throws {
        let harness = try await makeHarness(windowID: 4602)
        let oldLane = try await persistAndClaimLane(harness)
        harness.session.providerSessionID = "provider-before-reset"
        harness.session.draftText = "draft kept on failure"
        let stateBefore = try XCTUnwrap(harness.session.persistenceState)

        // A normal save held in its write while the reset starts.
        let gate = ResetBoundaryWriteGate()
        harness.viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("Saved by the held write"))
        let heldSave = Task { await harness.viewModel.flushSaveDetailed(for: harness.tabID) }
        let saveHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(saveHeld)

        // The session file cannot be replaced when the reset commits.
        let folderPath = try await harness.persistedFileURL().deletingLastPathComponent().path
        let originalPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: folderPath)[.posixPermissions] as? NSNumber
        )
        var permissionsRestored = false
        defer {
            if !permissionsRestored {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
            }
        }
        var admissionDuringCommit: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>?
        harness.viewModel.test_recoveryResetBeforeCommitHook = { _ in
            admissionDuringCommit = await Self.admitQueued("typed during the failing commit", on: oldLane)
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folderPath)
        }
        let reset = Task { await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID) }
        let frozen = await RecoveryTestSupport.eventually { oldLane.isResetPreparationActive }
        XCTAssertTrue(frozen)
        guard case .failure(.refused(.resetPreparationInProgress)) = await Self.admitQueued("typed while joined", on: oldLane) else {
            return XCTFail("Admission is frozen while the reset joins the writer")
        }
        gate.release()
        _ = await heldSave.value
        let outcome = await reset.value
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
        permissionsRestored = true
        harness.viewModel.test_saveSessionBeforeWriteHook = nil
        harness.viewModel.test_recoveryResetBeforeCommitHook = nil

        guard case let .vetoed(reason) = outcome else {
            return XCTFail("A failed reset commit is a veto, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("reset commit failed"), reason)
        guard case .failure(.refused(.resetPreparationInProgress))? = admissionDuringCommit else {
            return XCTFail("Admission is frozen through the commit attempt, got \(String(describing: admissionDuringCommit))")
        }

        // Nothing was cleared; the old generation and its lane stay usable.
        XCTAssertEqual(harness.session.items.map(\.text), ["Before reset", "Saved by the held write"])
        XCTAssertEqual(harness.session.providerSessionID, "provider-before-reset")
        XCTAssertEqual(harness.session.draftText, "draft kept on failure")
        XCTAssertNil(harness.session.pendingTranscriptResetReceipt, "No reset is left for a later normal save")
        XCTAssertEqual(harness.session.persistenceState, stateBefore, "The generation did not advance")
        XCTAssertTrue(harness.session.recoveryLane === oldLane)
        XCTAssertFalse(oldLane.isRetired)
        XCTAssertFalse(oldLane.isResetPreparationActive, "The veto released the freeze")
        let fileText = try await harness.persistedFileText()
        XCTAssertTrue(fileText.contains("Saved by the held write"), fileText)

        // Admission reopened under the old generation.
        let admitted = await Self.admitQueued("typed after the veto", on: oldLane)
        guard case let .success(committed) = admitted else {
            return XCTFail("Admission reopens after a vetoed reset, got \(admitted)")
        }
        XCTAssertEqual(committed.admission.binding.transcriptResetGeneration, 0)
    }

    /// The draft held by Clear Chat is listed without a restart. Restore is offered only into an
    /// empty message box (typing keeps both); Discard asks first; resolving it removes the row.
    func testHeldDraftIsListedLiveAndRestoreIsOfferedOnlyIntoAnEmptyMessageBox() async throws {
        let harness = try await makeHarness(windowID: 4603)
        _ = try await persistAndClaimLane(harness)
        harness.session.draftText = "draft before reset"
        let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID)
        XCTAssertEqual(outcome, .committed)
        let newLane = try XCTUnwrap(harness.session.recoveryLane)
        let isHeld = await RecoveryTestSupport.eventually {
            if case .held = newLane.composerState { return true }
            return false
        }
        XCTAssertTrue(isHeld)

        let viewModel = harness.viewModel
        let session = harness.session
        let tabID = harness.tabID
        func heldRow() -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id.hasPrefix("draft-held-") }
        }
        viewModel.storeDraftText(for: tabID, "typed after clearing")
        let typedRow = try XCTUnwrap(heldRow(), "The held draft is listed in this launch")
        XCTAssertEqual(typedRow.text, "draft before reset")
        XCTAssertEqual(typedRow.actions, [.discardDraft], "Restore never replaces current typing")
        XCTAssertNotNil(typedRow.confirmation, "Discard asks first")

        viewModel.storeDraftText(for: tabID, "")
        let emptyRow = try XCTUnwrap(heldRow())
        XCTAssertEqual(emptyRow.id, typedRow.id, "The row identifies the same displayed draft")
        XCTAssertEqual(emptyRow.actions, [.restoreDraft, .discardDraft])

        await viewModel.performRecoveryListAction(rowID: emptyRow.id, action: .restoreDraft)
        XCTAssertNil(heldRow(), "The resolved draft leaves the list")
        XCTAssertEqual(newLane.composerState, .ready)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "draft before reset")
        let stored = await newLane.store.read(sessionID: newLane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "draft before reset")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let tabID: UUID
        let session: AgentTabSession

        struct MissingPersistedFile: Error {}

        @MainActor
        func persistedFileURL() async throws -> URL {
            guard let sessionID = session.activeAgentSessionID,
                  let persisted = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace),
                  let fileURL = persisted.fileURL
            else { throw MissingPersistedFile() }
            return fileURL
        }

        @MainActor
        func persistedFileText() async throws -> String {
            try await String(contentsOf: persistedFileURL(), encoding: .utf8)
        }
    }

    private static func admitQueued(
        _ text: String,
        on lane: AgentRecoverySessionLane
    ) async -> Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure> {
        await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content(text)
        ))
    }

    /// Persists the first transcript through the VM save path (which claims the lane) and waits for
    /// the lane's eager composer restore.
    private func persistAndClaimLane(_ harness: Harness) async throws -> AgentRecoverySessionLane {
        harness.session.appendItem(.user("Before reset"))
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(harness.session.recoveryLane, "The first save claims the session's lane")
        let restored = await RecoveryTestSupport.eventually {
            if case .ready = lane.composerState { return true }
            return false
        }
        XCTAssertTrue(restored)
        return lane
    }

    private func makeHarness(windowID: Int) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryResetBoundaryWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryResetBoundaryStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = AgentRecoveryStore(rootURL: recoveryRoot)
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                // Debounced composer writes never fire on their own: only explicit flushes write.
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        coordinator.startIfNeeded()
        let startup = await coordinator.awaitStartup()
        guard startup == .ready else { throw RecoveryLaneFixtureError.startupNotReady }

        let workspace = WorkspaceModel(
            name: "Agent Recovery Reset Boundary",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.installRecoveryCoordinator(coordinator)
        XCTAssertTrue(viewModel.test_dataService === service, "The VM writes through the coordinator's gated DataService")
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(session.recoveryComposerObserver, "First-draft observation is installed at session creation")
        return Harness(viewModel: viewModel, workspace: workspace, tabID: tabID, session: session)
    }
}

/// Suspends the first write that reaches it until released.
@MainActor
private final class ResetBoundaryWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    private(set) var isWaiting = false

    func waitOnce() async {
        guard !used else { return }
        used = true
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
