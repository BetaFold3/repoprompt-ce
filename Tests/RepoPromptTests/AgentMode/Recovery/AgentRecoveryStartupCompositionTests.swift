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
        XCTAssertEqual(row()?.actions, [.edit, .remove, .dismiss])

        // Phase 2: the banner is the active session's exact catalog filter; other sessions' items
        // are counted there and listed in the app-wide Needs Attention sheet.
        let statusRowID = "status-\(unreadable.session.id.uuidString)"
        let runRowID = "run-\(unsaved.session.id.uuidString)-\(unsavedOwnership.attemptID.uuidString)"
        let banner = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session))
        XCTAssertFalse(banner.rows.contains { $0.id == statusRowID || $0.id == runRowID })
        XCTAssertGreaterThanOrEqual(banner.otherItemCount, 2)
        func sheetRow(_ id: String, includeDismissed: Bool = false) -> AgentRecoveryNeedsAttentionRow? {
            viewModel.recoveryNeedsAttentionRows(includeDismissed: includeDismissed, activeSession: session).first { $0.id == id }
        }

        // Unreadable recovered data is listed view-only (not dismissible) and left unchanged.
        let statusRow = sheetRow(statusRowID)?.row
        XCTAssertEqual(statusRow?.title, "Recovery status unknown")
        XCTAssertEqual(statusRow?.actions, [])
        XCTAssertEqual(try Data(contentsOf: unreadableURL), unreadableBytes)
        let runRow = sheetRow(runRowID)?.row
        XCTAssertEqual(runRow?.title, "Run interrupted before it was saved")
        XCTAssertEqual(runRow?.actions.first, .dismiss)

        // Dismiss of a closed session's card is durable (under its persistence gate) and changes
        // nothing else: the run evidence stays open and the item is still listed as dismissed.
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .dismiss)
        let dismissed = await Support.eventually { sheetRow(runRowID) == nil }
        XCTAssertTrue(dismissed, String(describing: viewModel.recoveryCoordinator?.catalogActionStates[runRowID]))
        XCTAssertEqual(sheetRow(runRowID, includeDismissed: true)?.isDismissed, true)
        let unsavedRecord = await now.store.read(sessionID: unsaved.session.id).record
        XCTAssertEqual(unsavedRecord?.cardAcknowledgements.map(\.key.entityID), [unsavedOwnership.attemptID.uuidString])
        XCTAssertNil(unsavedRecord?.runAttempts.first?.terminal, "Dismiss resolves nothing")

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

    /// Review B F5, F10 and cross-workspace Open: rows resolve their session from the catalog (the
    /// paused indicator's "It stopped" confirms the dismissed crash hold; a schedule row opens its
    /// session); an item in another workspace opens through the agent-session route with its exact
    /// workspace, tab, and session; and items only elsewhere keep the banner reachable.
    func testRecoveryListRowsResolveSessionsFromTheCatalogAndOpenAcrossWorkspaces() async throws {
        let fixture = try makeFixture()
        let otherStorage = fixture.root.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let other = WorkspaceModel(name: "Other Workspace", repoPaths: [otherStorage.path], customStoragePath: otherStorage)
        let otherDestination = AgentRecoveryWorkspaceDestination(id: other.id, name: other.name, customStoragePath: otherStorage)
        let tabID = UUID()

        // Earlier launch (no clean exit): a run in flight in this workspace's session (a crash
        // hold), and in another workspace an interrupted run and a schedule awaiting confirmation.
        let earlier = makeLaunch(fixture)
        let earlierStore = earlier.store
        let held = try await makeSession(earlier, fixture: fixture, composeTabID: tabID)
        let heldOwnership = Support.ownership(sessionID: held.session.id)
        let heldGate = try earlier.service.recoveryLifecycleGate(for: held.persistenceState)
        let heldBinding = heldGate.binding
        try await heldGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                ownership: heldOwnership,
                processRunID: nil,
                transcriptTurnID: nil
            )
            _ = try await earlierStore.commitDispatchingIntent(
                binding: heldBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: heldBinding.sessionID),
                submission: Support.submission("in flight at crash"),
                attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: heldOwnership.attemptID),
                consumption: nil
            )
        }
        let elsewhereTabID = UUID()
        let elsewhere = try await makeSession(earlier, fixture: fixture, workspace: other, composeTabID: elsewhereTabID)
        let elsewhereOwnership = Support.ownership(sessionID: elsewhere.session.id)
        let elsewhereGate = try earlier.service.recoveryLifecycleGate(for: elsewhere.persistenceState)
        let elsewhereBinding = elsewhereGate.binding
        let question = AgentRecoveryQuestionSnapshot(
            interactionID: UUID(),
            kind: .askUser,
            runAttemptID: elsewhereOwnership.attemptID,
            transcriptResetGeneration: elsewhereBinding.transcriptResetGeneration,
            appInstanceID: UUID(),
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            title: "Question",
            message: nil,
            items: [AgentRecoveryQuestionItem(
                questionID: "target", header: nil, text: "Which environment?", options: [], isSecret: false, answer: "staging"
            )],
            extras: [:]
        )
        try await elsewhereGate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: elsewhereBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: elsewhereBinding.sessionID),
                ownership: elsewhereOwnership,
                processRunID: nil,
                transcriptTurnID: nil
            )
            _ = try await earlierStore.updateQuestionSnapshots(
                binding: elsewhereBinding,
                expectedRevision: earlierStore.currentRevision(sessionID: elsewhereBinding.sessionID),
                update: AgentRecoveryStore.QuestionSnapshotUpdate(upserting: [question], removing: [])
            )
        }
        let scheduledTabID = UUID()
        let scheduled = try await makeSession(earlier, fixture: fixture, workspace: other, composeTabID: scheduledTabID)
        let notBefore = Date(timeIntervalSince1970: 1000)
        let schedule = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: notBefore.addingTimeInterval(-60),
            updatedAt: notBefore,
            notBefore: notBefore,
            state: .needsConfirmation,
            confirmationReason: .missedWhileClosed,
            rawText: "scheduled elsewhere",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false
        )
        let sessionsFolder = otherStorage.appendingPathComponent("AgentSessions", isDirectory: true)
        let scheduledURL = sessionsFolder.appendingPathComponent("AgentSession-\(scheduled.session.id.uuidString).json")
        var saved = try AgentSessionDataCodec.decodeSession(from: Data(contentsOf: scheduledURL))
        saved.scheduledSend = .v1(schedule)
        try AgentSessionDataCodec.encodeSession(saved).write(to: scheduledURL, options: .atomic)
        try? FileManager.default.removeItem(at: sessionsFolder.appendingPathComponent("AgentSessionIndex.json"))
        _ = try await makeLaunch(fixture).service.indexedAgentSessionMetadataRecords(for: otherDestination)

        // This launch: both workspaces are inventoried; this window shows the first one.
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destinations = [fixture.destination, otherDestination]
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: destinations) }
        )
        let viewModel = makeViewModel(windowID: 4811, fixture: fixture)
        composition.install(into: viewModel)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        viewModel.test_establishPersistenceWorkspace(fixture.workspace)

        let runRowID = "run-\(elsewhere.session.id.uuidString)-\(elsewhereOwnership.attemptID.uuidString)"
        let scheduleRowID = "schedule-\(scheduled.session.id.uuidString)-\(schedule.id.uuidString)"
        let listed = await Support.eventually {
            coordinator.catalog.item(id: runRowID) != nil && coordinator.catalog.item(id: scheduleRowID) != nil
        }
        XCTAssertTrue(listed, "\(coordinator.catalog.items.map(\.id))")

        // B F2: a saved question never claims it went unanswered (its answer may have been sent).
        let questionRowID = AgentModeViewModel.recoveryListQuestionRowID(
            sessionID: elsewhere.session.id, interactionID: question.interactionID
        )
        let questionRow = try XCTUnwrap(
            viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil).first { $0.id == questionRowID },
            "\(coordinator.catalog.items.map(\.id))"
        )
        XCTAssertTrue(questionRow.isOtherWorkspace)
        XCTAssertEqual(questionRow.row.title, "Expired question")
        XCTAssertTrue(questionRow.row.detail.contains("Whether an answer reached the agent is uncertain"), questionRow.row.detail)
        XCTAssertFalse(questionRow.row.title.localizedCaseInsensitiveContains("unanswered"))
        XCTAssertFalse(questionRow.row.detail.localizedCaseInsensitiveContains("before it was answered"))
        XCTAssertEqual(questionRow.row.actions, [.open, .dismiss])

        // F10: with nothing for the active (here no) session, items elsewhere keep the banner.
        let elsewhereOnly = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: nil), "Items elsewhere keep the banner reachable")
        XCTAssertTrue(elsewhereOnly.rows.isEmpty)
        XCTAssertGreaterThanOrEqual(elsewhereOnly.otherItemCount, 3)

        // Cross-workspace Open (run and schedule rows) uses the exact agent-session route.
        final class Routes {
            var routes: [AgentSessionDeepLinkRoute] = []
            var result: AgentSessionRouteResult = .routed
        }
        let routes = Routes()
        viewModel.recoveryListRouteToSession = { route in
            routes.routes.append(route)
            return routes.result
        }
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .open)
        XCTAssertNil(coordinator.catalogActionStates[runRowID])
        await viewModel.performRecoveryListAction(rowID: scheduleRowID, action: .open)
        XCTAssertNil(coordinator.catalogActionStates[scheduleRowID], "A schedule row resolves its session from the catalog")
        XCTAssertEqual(routes.routes, [
            AgentSessionDeepLinkRoute(workspaceID: other.id, tabID: elsewhereTabID, sessionID: elsewhere.session.id),
            AgentSessionDeepLinkRoute(workspaceID: other.id, tabID: scheduledTabID, sessionID: scheduled.session.id)
        ])
        routes.result = .workspaceUnavailable
        await viewModel.performRecoveryListAction(rowID: runRowID, action: .open)
        guard case .failed = coordinator.catalogActionStates[runRowID] else {
            return XCTFail("A failed route is reported on the row: \(String(describing: coordinator.catalogActionStates[runRowID]))")
        }
        XCTAssertTrue(viewModel.sessions.isEmpty, "Opening elsewhere hydrates nothing in this window")

        // F5: the paused indicator of a dismissed crash hold confirms exactly that hold.
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if session.activeAgentSessionID != held.session.id {
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: held.session.id, on: session))
            _ = await viewModel.test_hydrateBoundSession(tabID: tabID)
        }
        let laneClaimed = await Support.eventually { session.recoveryLane != nil }
        XCTAssertTrue(laneClaimed)
        XCTAssertNotNil(coordinator.crashHold(for: held.session.id))
        let crash = try XCTUnwrap(coordinator.catalog.items.first { $0.sessionID == held.session.id && $0.kind == .crashHold })
        await viewModel.performRecoveryListAction(rowID: crash.id, action: .dismiss)
        let dismissed = await Support.eventually { coordinator.catalog.item(id: crash.id)?.isDismissed == true }
        XCTAssertTrue(dismissed, String(describing: coordinator.catalogActionStates[crash.id]))
        XCTAssertEqual(coordinator.catalog.blockers[held.session.id], .crashHold, "Dismiss lifts nothing")
        let pausedRowID = "\(AgentModeViewModel.recoveryListPausedRowPrefix)\(held.session.id.uuidString)"
        let paused = try XCTUnwrap(viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == pausedRowID })
        XCTAssertTrue(paused.actions.contains(.confirmStopped))
        XCTAssertFalse(paused.actions.contains(.dismiss), "The paused indicator is not dismissible")
        await viewModel.performRecoveryListAction(rowID: pausedRowID, action: .confirmStopped)
        XCTAssertNil(coordinator.catalogActionStates[pausedRowID], "It stopped resolves the hold's session from the catalog")
        let lifted = await Support.eventually { coordinator.catalog.blockers[held.session.id] == nil }
        XCTAssertTrue(lifted)
        let acknowledgement = await now.store.read(sessionID: held.session.id).record?.crashHoldAcknowledgement
        XCTAssertNotNil(acknowledgement)
    }

    /// Review A F09: recorded outcomes are worded without unsupported timing claims, and a failed or
    /// cancelled run is never presented as completed.
    func testRecoveredRunWordingStatesOnlyWhatTheEvidenceEstablishes() {
        func attempt(_ state: AgentSessionRunState, _ cause: AgentRunTerminalCause?) -> AgentRecoveryRunAttempt {
            AgentRecoveryRunAttempt(
                runAttemptID: UUID(),
                transcriptResetGeneration: 0,
                processRunID: nil,
                transcriptTurnID: UUID(),
                startedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
                terminal: AgentRecoveryRunTerminalEvidence(
                    commitID: UUID(), terminalState: state, expectedRunID: nil,
                    recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: 2000), cause: cause
                )
            )
        }
        let completed = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.completed, .ordinary))
        )
        XCTAssertEqual(completed.title, "Completed; transcript tail may be missing")
        XCTAssertFalse(completed.title.contains("while RepoPrompt was closed"))
        XCTAssertFalse(completed.detail.contains("while RepoPrompt was closed"))
        let failed = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.failed, .ordinary))
        )
        XCTAssertEqual(failed.title, "Run failed")
        XCTAssertFalse(failed.title.localizedCaseInsensitiveContains("completed"))
        let cancelled = AgentModeViewModel.recoveryListOutcomeTurnText(
            AgentRecoveryOutcomeTurn(turnID: UUID(), runAttempt: attempt(.cancelled, .userCancel))
        )
        XCTAssertEqual(cancelled.title, "Run cancelled")
        let unsavedCompleted = AgentModeViewModel.recoveryOnlyRunRowText(attempt(.completed, .ordinary))
        XCTAssertEqual(unsavedCompleted.title, "Run finished, but its turn wasn't saved")
        XCTAssertTrue(unsavedCompleted.detail.hasPrefix("The run completed"))
        let unsavedFailed = AgentModeViewModel.recoveryOnlyRunRowText(attempt(.failed, .ordinary))
        XCTAssertTrue(unsavedFailed.detail.hasPrefix("The run failed"), unsavedFailed.detail)
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

    // MARK: - App-wide Needs Attention (non-visible routing and publication)

    /// Records the objects of one notification name (posted synchronously on the main thread).
    @MainActor
    private final class PostedObjects {
        var ids: [ObjectIdentifier] = []
        private var token: (any NSObjectProtocol)?

        init(_ name: Notification.Name) {
            token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let id = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    if let id { self?.ids.append(id) }
                }
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }

        func count(of object: AnyObject) -> Int {
            ids.count { $0 == ObjectIdentifier(object) }
        }
    }

    private struct RouteOpenFailure: Error {}

    /// The app-level route reaches the focused window's view model, or a window it opens when none
    /// exists, and presents the shared catalog only: nothing hydrates, and the route stays
    /// reachable when every item is dismissed. A Dismiss in one window is published to every window.
    func testNeedsAttentionRouteReachesAnyWindowWithoutHydratingAndStaysReachableWhenAllDismissed() async throws {
        let fixture = try makeFixture()

        // Earlier launch: a closed session's run whose transcript turn was never saved.
        let earlier = makeLaunch(fixture)
        let unsaved = try await makeSession(earlier, fixture: fixture)
        let ownership = Support.ownership(sessionID: unsaved.session.id)
        let gate = try earlier.service.recoveryLifecycleGate(for: unsaved.persistenceState)
        let earlierStore = earlier.store
        let binding = gate.binding
        try await gate.performRecoveryTransaction {
            _ = try await earlierStore.ensureRunAttempt(
                binding: binding,
                expectedRevision: earlierStore.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: nil,
                transcriptTurnID: nil
            )
        }

        // This launch: two windows share one composition; neither opens a tab.
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let windowA = makeViewModel(windowID: 4851, fixture: fixture)
        let windowB = makeViewModel(windowID: 4852, fixture: fixture)
        composition.install(into: windowA)
        composition.install(into: windowB)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        XCTAssertTrue(windowA.recoveryCoordinator === coordinator)
        XCTAssertTrue(windowB.recoveryCoordinator === coordinator)

        let runRowID = "run-\(unsaved.session.id.uuidString)-\(ownership.attemptID.uuidString)"
        let initialRows = windowA.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil)
        let initialSummary = initialRows.map { "\($0.id): \($0.row.title) \($0.row.actions)" }
        XCTAssertTrue(initialRows.contains { $0.id == runRowID }, "\(initialSummary)")
        XCTAssertEqual(windowA.recoveryNeedsAttentionCount, initialRows.count)
        XCTAssertEqual(windowB.recoveryNeedsAttentionCount, initialRows.count)
        XCTAssertEqual(
            initialRows.map(\.id),
            windowB.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil).map(\.id),
            "Every window renders the same catalog"
        )

        // Every item dismissed in window B; window A observes the same published catalog.
        let catalogPosts = PostedObjects(.agentRecoveryCatalogDidChange)
        defer { catalogPosts.stop() }
        for row in initialRows {
            XCTAssertTrue(row.row.actions.contains(.dismiss), "\(initialSummary)")
            await windowB.performRecoveryListAction(rowID: row.id, action: .dismiss)
        }
        let dismissedEverywhere = await Support.eventually {
            windowA.recoveryNeedsAttentionCount == 0 && windowB.recoveryNeedsAttentionCount == 0
        }
        XCTAssertTrue(dismissedEverywhere, "\(initialSummary) \(coordinator.catalogActionStates)")
        let publishedPost = await Support.eventually { catalogPosts.count(of: coordinator) > 0 }
        XCTAssertTrue(publishedPost)
        let dismissedRowInA = windowA.recoveryNeedsAttentionRows(includeDismissed: true, activeSession: nil).first { $0.id == runRowID }
        XCTAssertEqual(dismissedRowInA?.isDismissed, true, "Show dismissed still lists it with nothing undismissed")
        XCTAssertNil(dismissedRowInA?.row.error)

        // Route to an existing window: it never opens another.
        let requests = PostedObjects(.agentRecoveryNeedsAttentionRequested)
        defer { requests.stop() }
        let existingTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: windowA) {
            XCTFail("An existing window is used")
            throw RouteOpenFailure()
        }
        XCTAssertTrue(existingTarget === windowA)
        XCTAssertEqual(requests.ids, [ObjectIdentifier(windowA)])
        XCTAssertTrue(windowA.consumeRecoveryNeedsAttentionRequest())
        XCTAssertFalse(windowA.consumeRecoveryNeedsAttentionRequest(), "A request presents once")
        XCTAssertFalse(windowB.consumeRecoveryNeedsAttentionRequest())

        // No window: one is opened through the existing route and presents once registered.
        var opened = 0
        let openedTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: nil) {
            opened += 1
            return windowB
        }
        XCTAssertTrue(openedTarget === windowB)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(requests.ids, [ObjectIdentifier(windowA), ObjectIdentifier(windowB)])
        XCTAssertTrue(windowB.consumeRecoveryNeedsAttentionRequest())

        let failedTarget = await AgentRecoveryNeedsAttentionRouter.present(existing: nil) {
            throw RouteOpenFailure()
        }
        XCTAssertNil(failedTarget)
        XCTAssertEqual(requests.count(of: windowA) + requests.count(of: windowB), 2)

        XCTAssertTrue(windowA.sessions.isEmpty, "Presenting hydrates nothing")
        XCTAssertTrue(windowB.sessions.isEmpty, "Presenting hydrates nothing")
        XCTAssertTrue(scheduler.confirmationSummaries().isEmpty)
    }

    /// A tab's failed composer preparation is a coordinator catalog item (runtime only): every
    /// window lists it, only the window owning the tab offers Retry, it has no durable Dismiss, and
    /// an action's failure is the same shared state in every window.
    func testFailedComposerPreparationAndActionResultArePublishedToEveryWindow() async throws {
        let fixture = try makeFixture()
        let now = makeLaunch(fixture)
        let scheduler = AgentScheduledSendCoordinator(startupAdmission: .awaitingRecovery)
        let destination = fixture.destination
        let composition = AgentRecoveryAppComposition(
            store: now.store,
            dataService: now.service,
            scheduler: scheduler,
            loadInventory: { AgentRecoveryWorkspaceInventory(workspaces: [destination]) }
        )
        let windowA = makeViewModel(windowID: 4861, fixture: fixture)
        let windowB = makeViewModel(windowID: 4862, fixture: fixture)
        composition.install(into: windowA)
        composition.install(into: windowB)
        await composition.startupCompletion?.value
        let coordinator = try XCTUnwrap(composition.coordinator)
        windowA.test_establishPersistenceWorkspace(fixture.workspace)
        windowB.test_establishPersistenceWorkspace(fixture.workspace)

        let tabID = UUID()
        let owner = try XCTUnwrap(windowA.session(for: tabID, createIfNeeded: true))
        let catalogPosts = PostedObjects(.agentRecoveryCatalogDidChange)
        defer { catalogPosts.stop() }
        coordinator.recordComposerMutationAwaitingPreparation(owner: owner, content: AgentRecoveryInputContent(text: "typed"))
        XCTAssertTrue(coordinator.startComposerPreparation(owner: owner) { _ in .authorityUnavailable("no workspace authority") })

        let itemID = AgentRecoveryCatalogProjection.preparationItemID(tabID: tabID)
        let published = await Support.eventually {
            coordinator.catalog.item(id: itemID) != nil && catalogPosts.count(of: coordinator) > 0
        }
        XCTAssertTrue(published, "The failure is published as a catalog change")
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        XCTAssertEqual(item.kind, .saveFailure)
        XCTAssertEqual(item.composeTabID, tabID)
        XCTAssertNil(item.acknowledgement, "No durable Dismiss for an unpersistable failure")
        XCTAssertEqual(item.payload, .composerPreparationFailed(.authorityUnavailable("no workspace authority")))

        func sheetRow(_ window: AgentModeViewModel) -> AgentRecoveryListRowProps? {
            window.recoveryNeedsAttentionRows(includeDismissed: true, activeSession: nil).first { $0.id == itemID }?.row
        }
        XCTAssertEqual(sheetRow(windowA)?.title, "Message box not saved yet")
        XCTAssertEqual(sheetRow(windowA)?.actions, [.retrySave], "The window owning the tab retries")
        XCTAssertEqual(sheetRow(windowB)?.title, "Message box not saved yet")
        XCTAssertEqual(sheetRow(windowB)?.actions, [], "Another window lists it without acting on a tab it does not own")
        let banner = try XCTUnwrap(windowA.recoveryListProps(forActiveSession: owner))
        XCTAssertTrue(banner.rows.contains { $0.id == itemID }, "The owning tab's banner shows the same item")

        // An action failure is shared state: both windows show it, and the item stays listed.
        await windowA.performRecoveryListAction(rowID: itemID, action: .dismiss)
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed("This item can't be dismissed."))
        XCTAssertEqual(sheetRow(windowA)?.error, "This item can't be dismissed.")
        XCTAssertEqual(sheetRow(windowB)?.error, "This item can't be dismissed.")
        XCTAssertNotNil(coordinator.catalog.item(id: itemID))
        XCTAssertTrue(windowB.sessions.isEmpty, "Listing it in another window hydrates nothing there")
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
        workspace: WorkspaceModel? = nil,
        composeTabID: UUID = UUID()
    ) async throws -> AgentSessionEditableLoad {
        let workspace = workspace ?? fixture.workspace
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: composeTabID,
            name: "Recovered Session"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        return try await launch.service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
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
