import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless-restart Phase 1b production composition and basic recovery list: one store and one
/// gated DataService per composition, scheduler admission closed until reconciliation is ready,
/// fail-closed dependency and index failures with Retry, and recovery-list actions that revalidate
/// the durable record and never replace newer typing. Every store, DataService, workspace, and
/// workspace index is an injected temporary directory (production composition is inactive here).
@MainActor
final class AgentRecoveryStartupCompositionTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private struct Fixture {
        let root: URL
        let recoveryRoot: URL
        let storageURL: URL
        let workspace: WorkspaceModel

        var destination: AgentRecoveryWorkspaceDestination {
            AgentRecoveryWorkspaceDestination(
                id: workspace.id,
                name: workspace.name,
                customStoragePath: workspace.customStoragePath
            )
        }
    }

    private struct Launch {
        let store: AgentRecoveryStore
        let service: AgentSessionDataService
    }

    // MARK: - Recovery list (UI / CAS)

    func testRecoveryListEditKeepsNewerTypingAndAFailedRemovalKeepsTheRowVisible() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        // Earlier launch: held input in a closed session, and a session whose record is unreadable.
        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let submission = Support.submission("held input")
        try await commitQueued(earlier, load, submission)
        let unreadable = try await makeSession(earlier, fixture: fixture)
        try await commitQueued(earlier, unreadable, Support.submission("unreadable input"))
        let unreadableURL = earlier.store.recordFileURL(sessionID: unreadable.session.id)
        try Data("{ not a recovery record".utf8).write(to: unreadableURL, options: .atomic)
        let unreadableBytes = try Data(contentsOf: unreadableURL)
        // A run whose transcript turn was never saved: listed from its recovery evidence alone.
        let unsaved = try await makeSession(earlier, fixture: fixture)
        let unsavedOwnership = Support.ownership(sessionID: unsaved.session.id)
        let unsavedGate = try earlier.service.recoveryLifecycleGate(for: unsaved.persistenceState)
        let earlierStore = earlier.store
        let unsavedBinding = unsavedGate.binding
        try await unsavedGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: unsavedBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: unsavedBinding.sessionID),
                ownership: unsavedOwnership,
                processRunID: nil,
                transcriptTurnID: nil
            )
        }

        // This launch: production-shaped composition installed before anything hydrates.
        let failures = RecoveryStoreWriteFailureSwitch()
        let now = makeLaunch(fixture, failures: failures)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4801, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        XCTAssertEqual(session.activeAgentSessionID, load.session.id)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed, "Hydration claims the session's lane")

        let rowID = "intent-\(load.session.id.uuidString)-\(submission.intentID.uuidString)"
        func row() -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == rowID }
        }
        XCTAssertEqual(row()?.text, "held input")
        XCTAssertEqual(row()?.actions, [.edit, .remove])

        // Unreadable recovered data is listed view-only and left unchanged.
        let statusRow = viewModel.recoveryListProps(forActiveSession: session)?.rows
            .first { $0.id == "status-\(unreadable.session.id.uuidString)" }
        XCTAssertEqual(statusRow?.title, "Recovery status unknown")
        XCTAssertEqual(statusRow?.actions, [])
        XCTAssertEqual(try Data(contentsOf: unreadableURL), unreadableBytes)
        let runRow = viewModel.recoveryListProps(forActiveSession: session)?.rows
            .first { $0.id == "run-\(unsaved.session.id.uuidString)-\(unsavedOwnership.attemptID.uuidString)" }
        XCTAssertEqual(runRow?.title, "Run interrupted before it was saved")
        XCTAssertEqual(runRow?.actions.first, .hide)

        // Edit never replaces newer typing; the source stays saved.
        viewModel.storeDraftText(for: tabID, "newer typing")
        await viewModel.performRecoveryListAction(rowID: rowID, action: .edit)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "newer typing")
        XCTAssertNotNil(row()?.error)
        let afterEdit = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterEdit, .queued)

        // A failed withdrawal leaves the row and its source in place.
        failures.shouldFailWrites = true
        await viewModel.performRecoveryListAction(rowID: rowID, action: .remove)
        failures.shouldFailWrites = false
        let failedRow = try XCTUnwrap(row(), "The row stays until the withdrawal commits")
        XCTAssertTrue(failedRow.error?.contains("couldn't be removed") == true, String(describing: failedRow.error))
        XCTAssertFalse(failedRow.isWorking)
        let afterFailure = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterFailure, .queued)

        // Repeating the action commits the withdrawal, then the row disappears.
        await viewModel.performRecoveryListAction(rowID: rowID, action: .remove)
        XCTAssertNil(row())
        let afterRemoval = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(afterRemoval, .withdrawn)
        XCTAssertEqual(try Data(contentsOf: unreadableURL), unreadableBytes)
    }

    /// R04: Edit keeps a carrier's exact pending-handoff association. An absent session payload is
    /// restored and saved before the withdrawal, the join then releases it for the next explicit send
    /// (never pasted into the composer text); a conflicting snapshot refuses with nothing changed.
    func testRecoveryListEditRestoresTheCarriedPendingHandoffAndRefusesAConflictingOne() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        func snapshot(_ payload: String) -> AgentRecoveryPendingHandoffSnapshot {
            AgentRecoveryPendingHandoffSnapshot(
                payloadID: UUID(),
                payload: payload,
                createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 1234),
                sourceItemID: nil,
                prependedText: "\(payload)\n\n---\n\n"
            )
        }
        func carrier(_ text: String, _ handoff: AgentRecoveryPendingHandoffSnapshot) -> AgentRecoveryIntentSubmission {
            AgentRecoveryIntentSubmission(
                intentID: UUID(),
                userItemID: UUID(),
                origin: .composer,
                target: .session,
                payload: Support.content(text),
                pendingHandoff: handoff
            )
        }
        let carried = snapshot("earlier conversation")
        let first = carrier("carried input", carried)
        try await commitQueued(earlier, load, first)
        let conflicting = carrier("conflicting input", snapshot("other conversation"))
        try await commitQueued(earlier, load, conflicting)

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let viewModel = makeViewModel(windowID: 4802, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        XCTAssertFalse(session.pendingHandoff.hasPayload, "No payload is pending in the session before Edit")

        func rowID(_ submission: AgentRecoveryIntentSubmission) -> String {
            "intent-\(load.session.id.uuidString)-\(submission.intentID.uuidString)"
        }
        func row(_ submission: AgentRecoveryIntentSubmission) -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == rowID(submission) }
        }

        await viewModel.performRecoveryListAction(rowID: rowID(first), action: .edit)
        XCTAssertNil(row(first)?.error)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "carried input", "The prefix is never pasted into the composer")
        XCTAssertEqual(session.pendingHandoff.payloadID, carried.payloadID)
        XCTAssertEqual(session.pendingHandoff.payload, carried.payload)
        XCTAssertNil(session.pendingHandoff.deliveryHold, "The withdrawn carrier releases the payload for the next explicit send")
        XCTAssertTrue(session.pendingHandoff.hasStageablePayload)
        let firstState = await deliveryState(now.store, load, first.intentID)
        XCTAssertEqual(firstState, .withdrawn)

        // A different carried payload never replaces the session's.
        viewModel.storeDraftText(for: tabID, "")
        await viewModel.performRecoveryListAction(rowID: rowID(conflicting), action: .edit)
        XCTAssertTrue(row(conflicting)?.error?.contains("Nothing was changed") == true, String(describing: row(conflicting)?.error))
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID) ?? "", "")
        XCTAssertEqual(session.pendingHandoff.payloadID, carried.payloadID)
        let conflictingState = await deliveryState(now.store, load, conflicting.intentID)
        XCTAssertEqual(conflictingState, .queued)
    }

    // MARK: - Composition

    func testCompositionSharesOneStoreAndDataServiceAndOpensSchedulingOnlyAfterReady() async throws {
        let fixture = try makeFixture()
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { .empty }
        )
        XCTAssertTrue(composition.isActive)
        XCTAssertNil(composition.failure)
        XCTAssertEqual(scheduler.startupAdmission, .awaitingRecovery)
        XCTAssertTrue(scheduler.dispatchingRecordsRequireTransferResolution)
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(coordinator.store === now.store)
        XCTAssertTrue(coordinator.dataService === now.service)

        let first = makeViewModel(windowID: 4811, fixture: fixture)
        let second = makeViewModel(windowID: 4812, fixture: fixture)
        composition.install(into: first)
        composition.install(into: second)
        XCTAssertFalse(scheduler.isStartupAdmissionOpen, "Scheduling stays closed until reconciliation is ready")
        for viewModel in [first, second] {
            XCTAssertTrue(viewModel.recoveryCoordinator === coordinator, "Every window shares one coordinator")
            XCTAssertTrue(viewModel.test_dataService === now.service, "Every window writes through the gated DataService")
            XCTAssertNil(viewModel.recoveryCompositionFailure)
        }

        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        first.test_establishPersistenceWorkspace(fixture.workspace)
        let tabID = UUID()
        first.test_setCurrentTabIDOverride(tabID)
        let session = try await first.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory)
    }

    func testCompositionDependencyFailureStaysFailClosedWithoutPermissiveFallback() async throws {
        let fixture = try makeFixture()
        let store = AgentRecoveryStore(rootURL: fixture.recoveryRoot)
        // A DataService not gated by `store`: the coordinator cannot be composed.
        let ungated = AgentSessionDataService(
            tombstoneRoot: fixture.recoveryRoot.appendingPathComponent("tombstones", isDirectory: true)
        )
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: store,
            dataService: ungated,
            scheduler: scheduler,
            loadInventory: { .empty }
        )
        XCTAssertTrue(composition.isActive)
        XCTAssertNil(composition.coordinator)
        XCTAssertNotNil(composition.failure)
        guard case .recoveryFailed = scheduler.startupAdmission else {
            return XCTFail("Scheduling stays closed with a reason, got \(scheduler.startupAdmission)")
        }

        let viewModel = makeViewModel(windowID: 4821, fixture: fixture)
        composition.install(into: viewModel)
        XCTAssertNil(viewModel.recoveryCoordinator)
        XCTAssertNotNil(viewModel.recoveryCompositionFailure)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory, "No legacy (untracked) fallback")

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "not admitted",
            tabID: tabID,
            origin: .composer
        )
        guard case .blocked = result else {
            return XCTFail("Input is refused without a coordinator, got \(result)")
        }
        XCTAssertFalse(session.items.contains { $0.kind == .user && $0.text == "not admitted" })
        let props = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        guard case .failed = props.status else {
            return XCTFail("The failure is shown, got \(props.status)")
        }
        XCTAssertFalse(props.canRetry)
        XCTAssertFalse(scheduler.isStartupAdmissionOpen)
    }

    func testUnreadableWorkspaceIndexKeepsStartupClosedUntilRetrySucceeds() async throws {
        let fixture = try makeFixture()
        let baseRoot = fixture.root.appendingPathComponent("WorkspacesRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        try Data("not a workspace index".utf8).write(to: indexURL, options: .atomic)
        XCTAssertThrowsError(try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot)) { error in
            XCTAssertTrue(error is AgentRecoveryInventoryIndexFailure, "\(error)")
        }

        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot) }
        )
        let viewModel = makeViewModel(windowID: 4831, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        guard case .failed = coordinator.startupState else {
            return XCTFail("The global scope could not be established, got \(coordinator.startupState)")
        }
        guard case .recoveryFailed = scheduler.startupAdmission else {
            return XCTFail("Scheduling stays closed, got \(scheduler.startupAdmission)")
        }
        let failedProps = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: nil))
        guard case .failed = failedProps.status else {
            return XCTFail("The failure is shown, got \(failedProps.status)")
        }
        XCTAssertTrue(failedProps.canRetry)

        // The index is repaired; Retry reconciles and then opens scheduling.
        let entry = WorkspaceIndexEntry(
            id: fixture.workspace.id,
            name: fixture.workspace.name,
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        try JSONEncoder().encode([entry]).write(to: indexURL, options: .atomic)
        viewModel.retryRecoveryStartup()
        XCTAssertFalse(scheduler.isStartupAdmissionOpen, "Retry closes admission until it is ready")
        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)
        XCTAssertNil(viewModel.recoveryListProps(forActiveSession: nil), "Nothing is left to show")
    }

    /// F-10: an owner that hydrated a `.dispatching` schedule while startup had failed holds it
    /// (`.awaitingRecovery`) and gives up its repair; once Retry opens admission, the transfer is
    /// resolved and the hydrated owner's projection and hold are released without user action.
    func testHydratedScheduleTransferIsRepairedWhenStartupRetryOpensAdmission() async throws {
        let fixture = try makeFixture()
        let tabID = UUID()

        // Earlier launch: the schedule attempt was transferred to a queued recovery intent, but the
        // pending `.dispatching` schedule was never cleared from the session file.
        let earlier = makeLaunch(fixture)
        let load = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let start = Date(timeIntervalSince1970: 100)
        let attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        let schedule = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            notBefore: start.addingTimeInterval(60),
            state: .dispatching,
            rawText: "scheduled",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            attempt: attempt
        )
        let submission = Support.submission(
            schedule.rawText,
            userItemID: attempt.itemID,
            origin: .scheduled,
            scheduleReference: AgentScheduledSendTransfer.recoveryScheduleReference(scheduleID: schedule.id, attempt: attempt)
        )
        try await commitQueued(earlier, load, submission)
        let sessionURL = fixture.storageURL
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(load.session.id.uuidString).json")
        var saved = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        saved.scheduledSend = .v1(schedule)
        try AgentSessionDataCodec.encodeSession(saved).write(to: sessionURL, options: .atomic)

        // This launch: the workspace index is unreadable, so startup fails and admission stays closed.
        let baseRoot = fixture.root.appendingPathComponent("WorkspacesRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        try Data("not a workspace index".utf8).write(to: indexURL, options: .atomic)
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot) }
        )
        let viewModel = makeViewModel(windowID: 4832, fixture: fixture)
        composition.install(into: viewModel)
        viewModel.attachScheduledSendCoordinator(scheduler)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        guard case .failed = coordinator.startupState else {
            return XCTFail("Startup failed before hydration, got \(coordinator.startupState)")
        }

        // Hydrated while startup is failed: projected as saved and held, never confirmed or dispatched.
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != load.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: load.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        XCTAssertEqual(session.activeAgentSessionID, load.session.id)
        XCTAssertEqual(session.pendingScheduledSendRecord?.id, schedule.id)
        XCTAssertEqual(session.pendingScheduledSendRecord?.state, .dispatching)
        let heldWhileFailed = await Support.eventually {
            scheduler.transferHold(scheduleID: schedule.id)?.reason == .awaitingRecovery
        }
        XCTAssertTrue(heldWhileFailed, "The hydrated attempt is held while startup is failed")
        XCTAssertFalse(scheduler.isStartupAdmissionOpen)
        let diskBeforeRetry = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        XCTAssertEqual(diskBeforeRetry.scheduledSend?.persistedValue?.id, schedule.id, "Nothing is repaired while startup is failed")

        // The index is repaired; Retry reconciles and opens admission.
        let entry = WorkspaceIndexEntry(
            id: fixture.workspace.id,
            name: fixture.workspace.name,
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        try JSONEncoder().encode([entry]).write(to: indexURL, options: .atomic)
        viewModel.retryRecoveryStartup()
        await composition.startupCompletion?.value
        XCTAssertEqual(coordinator.startupState, .ready)
        XCTAssertTrue(scheduler.isStartupAdmissionOpen)

        let released = await Support.eventually {
            session.pendingScheduledSendRecord == nil && scheduler.transferHold(scheduleID: schedule.id) == nil
        }
        XCTAssertTrue(released, "The hydrated owner's projection and hold are released after Retry")
        XCTAssertNil(scheduler.transferHold(sessionID: load.session.id))
        let disk = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: sessionURL))
        XCTAssertNil(disk.scheduledSend, "The pending schedule is cleared")
        XCTAssertEqual(disk.lastScheduledDispatch?.scheduleID, schedule.id)
        XCTAssertEqual(disk.lastScheduledDispatch?.attemptID, attempt.attemptID)
        XCTAssertEqual(
            disk.lastScheduledDispatch?.kind,
            .savedInQueue(AgentScheduledSendQueueLink(intentID: submission.intentID, userItemID: attempt.itemID))
        )
        let intentState = await deliveryState(now.store, load, submission.intentID)
        XCTAssertEqual(intentState, .queued, "The transfer never records acceptance")
    }

    // MARK: - Tab switch (R13)

    /// R13: switching tabs writes the outgoing tab's composer at the switch boundary. The debounce
    /// sleep is injected and never fired, so only the switch can have written the draft.
    func testTabSwitchFlushesTheOutgoingComposerWithoutTheDebounce() async throws {
        let fixture = try makeFixture()
        let sleeper = RecoveryManualSleeper()
        let now = makeLaunch(fixture)
        let coordinator = try AgentRecoveryCoordinator(
            store: now.store,
            dataService: now.service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { try await sleeper.sleep(until: $0) }
                )
            }
        )
        coordinator.startIfNeeded()
        let startup = await coordinator.awaitStartup()
        XCTAssertEqual(startup, .ready)

        // A real window, so the compose-tab change reaches the view model's tab-switch handler.
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        do {
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            let created = window.workspaceManager.createWorkspace(
                name: "Recovery Tab Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [fixture.storageURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: created, saveState: false, reason: "agentRecoveryTabSwitchFlushTest")
            let tabAID = UUID()
            let tabBID = UUID()
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex(where: { $0.id == created.id }))
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabAID, name: "A"),
                ComposeTabState(id: tabBID, name: "B")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true)

            let viewModel = window.agentModeViewModel
            viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
            XCTAssertTrue(viewModel.test_dataService === now.service, "The window writes through the coordinator's gated DataService")
            // Session files live in the temporary fixture storage, never in app data.
            var persistence = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            persistence.customStoragePath = fixture.storageURL
            viewModel.test_establishPersistenceWorkspace(persistence)

            // Tab A's first save claims its lane; the lane's eager composer restore completes.
            let sessionA = try XCTUnwrap(viewModel.session(for: tabAID, createIfNeeded: true))
            let sessionB = try XCTUnwrap(viewModel.session(for: tabBID, createIfNeeded: true))
            sessionA.appendItem(.user("Before switching"))
            let savedA = await viewModel.flushSave(for: tabAID)
            XCTAssertTrue(savedA)
            let laneA = try XCTUnwrap(sessionA.recoveryLane, "The first save claims tab A's lane")
            let restored = await Support.eventually {
                if case .ready = laneA.composerState { return true }
                return false
            }
            XCTAssertTrue(restored)
            viewModel.setAgentModeActive(true)

            // Typing arms the debounce, which never fires: nothing is written before the switch.
            viewModel.storeDraftText(for: tabAID, "typed in tab A")
            let armed = await Support.eventually { await !sleeper.pendingDeadlines.isEmpty }
            XCTAssertTrue(armed, "The debounce sleep is pending")
            let beforeSwitch = await now.store.read(sessionID: laneA.sessionID).record?.composer?.content.text
            XCTAssertNotEqual(beforeSwitch, "typed in tab A", "No write happens without the switch")

            await window.promptManager.switchComposeTab(tabBID)
            let flushed = await Support.eventually {
                await now.store.read(sessionID: laneA.sessionID).record?.composer?.content.text == "typed in tab A"
            }
            XCTAssertTrue(flushed, "The outgoing composer is written at the switch boundary")
            XCTAssertNotEqual(sessionB.draftText, "typed in tab A", "Nothing crosses tabs")
            if let laneB = sessionB.recoveryLane {
                XCTAssertNotEqual(laneB.sessionID, laneA.sessionID)
            }
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testRecoveryWorkspaceInventoryReportsMissingAndDuplicateEntriesWithoutWriting() throws {
        let fixture = try makeFixture()
        let baseRoot = fixture.root.appendingPathComponent("InventoryRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        XCTAssertEqual(try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot), .empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: baseRoot.path), [], "Nothing is created")

        let unique = WorkspaceIndexEntry(
            id: UUID(),
            name: "Unique",
            customStoragePath: fixture.storageURL,
            isSystemWorkspace: false,
            isHiddenInMenus: false
        )
        let repeatedID = UUID()
        let repeated = [
            WorkspaceIndexEntry(id: repeatedID, name: "Twice A", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: false),
            WorkspaceIndexEntry(id: repeatedID, name: "Twice B", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: true)
        ]
        let indexURL = baseRoot.appendingPathComponent("workspacesIndex.json")
        let indexData = try JSONEncoder().encode([unique] + repeated)
        try indexData.write(to: indexURL, options: .atomic)

        let inventory = try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory(baseRoot: baseRoot)
        XCTAssertEqual(inventory.workspaces, [AgentRecoveryWorkspaceDestination(
            id: unique.id,
            name: "Unique",
            customStoragePath: fixture.storageURL
        )])
        XCTAssertEqual(inventory.failures.map(\.workspaceID), [repeatedID], "A repeated workspace is a scoped failure")
        XCTAssertEqual(try Data(contentsOf: indexURL), indexData, "The index is read only")
    }

    // MARK: - Fixtures

    private func makeFixture() throws -> Fixture {
        let root = try Support.makeTemporaryRoot("AgentRecoveryStartupComposition")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            recoveryRoot: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            storageURL: storageURL,
            workspace: WorkspaceModel(
                name: "Recovery Startup Composition",
                repoPaths: [storageURL.path],
                customStoragePath: storageURL
            )
        )
    }

    private func makeLaunch(_ fixture: Fixture, failures: RecoveryStoreWriteFailureSwitch = RecoveryStoreWriteFailureSwitch()) -> Launch {
        let store = AgentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            appInstanceID: UUID(),
            fileOperations: failures.fileOperations()
        )
        let service = AgentSessionDataService(
            tombstoneRoot: fixture.recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        return Launch(store: store, service: service)
    }

    private func makeViewModel(windowID: Int, fixture: Fixture) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: fixture.storageURL.path,
            testWorkspaceDirectory: fixture.storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    private func makeSession(
        _ launch: Launch,
        fixture: Fixture,
        composeTabID: UUID = UUID()
    ) async throws -> AgentSessionEditableLoad {
        let session = AgentSession(
            id: UUID(),
            workspaceID: fixture.workspace.id,
            composeTabID: composeTabID,
            name: "Recovered Session"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await launch.service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: fixture.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
    }

    private func commitQueued(
        _ launch: Launch,
        _ load: AgentSessionEditableLoad,
        _ submission: AgentRecoveryIntentSubmission
    ) async throws {
        let gate = try launch.service.recoveryLifecycleGate(for: load.persistenceState)
        let store = launch.store
        let binding = gate.binding
        try await gate.performRecoveryTransaction {
            _ = try await store.commitQueuedIntent(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                submission: submission,
                consumption: nil
            )
        }
    }

    private func deliveryState(
        _ store: AgentRecoveryStore,
        _ load: AgentSessionEditableLoad,
        _ intentID: UUID
    ) async -> AgentRecoveryDeliveryState? {
        await store.read(sessionID: load.session.id).record?.intent(id: intentID)?.deliveryState
    }
}
