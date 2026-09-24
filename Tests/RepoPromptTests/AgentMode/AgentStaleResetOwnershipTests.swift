import Foundation
@testable import RepoPromptApp
import XCTest

/// Stop-and-retain contract after a committed peer transcript reset (R6 P1-4): the exact owner
/// whose save was rejected retains its complete working view without save authority, stops
/// ingestion through the ordinary cancellation/terminal lifecycle, refuses new work at the
/// backend admission points, protects the view from unconfirmed disposal, and replaces it only
/// through an explicitly confirmed paired reload whose permit is re-validated at apply time.
@MainActor
final class AgentStaleResetOwnershipTests: XCTestCase {
    // MARK: - Entry, stop, retain, admission

    func testPeerResetDuringActiveStreamRetainsWorkStopsRunAndBlocksNewWork() async throws {
        let owner = try await makeHarness(windowID: 4380)
        owner.session.appendItem(.user("Pre-reset prompt"))
        let initialSave = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        XCTAssertNotNil(owner.session.persistenceState(for: sessionID))

        // The owner streams: an active run with a streaming assistant item and buffered output
        // that has not been committed to the transcript yet.
        owner.session.runID = UUID()
        owner.viewModel.setAgentRunActive(owner.tabID, isActive: true)
        owner.session.runState = .running
        owner.session.appendItem(.assistant("Streaming partial", isStreaming: true))
        owner.viewModel.enqueueAssistantDelta(" tail", session: owner.session)
        XCTAssertEqual(owner.session.pendingAssistantDelta, " tail")

        // A peer window resets the conversation and commits it.
        let peer = try await makeHarness(windowID: 4381, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        // The owner's next save is rejected by the committed reset: stop-and-retain begins for
        // exactly this owner, synchronously, before any suspension.
        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        let recovery = try XCTUnwrap(owner.session.staleResetRecovery)
        XCTAssertNil(owner.session.persistenceState, "Authority is dropped; no fresh stamp for rejected history")
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertTrue(owner.session.isPresentableForOwner, "The retained view stays presentable")
        XCTAssertTrue(owner.session.isDirty, "Retained work stays dirty")
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, sessionID, "The incarnation is never forgotten")

        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recovery.id, "One episode; the stop never replaces it")
        XCTAssertFalse(owner.session.runState.isActive, "The old run was stopped through the terminal lifecycle")
        XCTAssertFalse(owner.viewModel.isTabRunning(owner.tabID))
        XCTAssertNil(owner.session.activeRunOwnership)
        XCTAssertTrue(owner.session.pendingAssistantDelta.isEmpty)
        let retainedTexts = owner.session.items.map(\.text)
        XCTAssertTrue(retainedTexts.contains("Pre-reset prompt"), "\(retainedTexts)")
        XCTAssertTrue(retainedTexts.contains("Sent after the peer reset"), "\(retainedTexts)")
        XCTAssertTrue(
            retainedTexts.contains("Streaming partial tail"),
            "Buffered assistant output is committed to the retained view, never discarded: \(retainedTexts)"
        )
        XCTAssertFalse(owner.session.items.contains { $0.isStreaming }, "Streaming items are finalized by the stop")
        XCTAssertNil(owner.session.persistenceState, "Stopping never re-acquires authority")
        XCTAssertTrue(owner.session.isDirty)

        // Backend admission is closed and the view is retained; nothing is written.
        let submit = owner.viewModel.submitUserTurn(text: "blocked", tabID: owner.tabID)
        XCTAssertEqual(submit, .blocked(message: AgentModeViewModel.staleResetRecoveryBlockedMessage))
        let start = await owner.viewModel.startAgentRun(tabID: owner.tabID, initialMessage: "blocked")
        guard case let .failed(startMessage)? = start else {
            return XCTFail("Run start must be refused, got \(String(describing: start))")
        }
        XCTAssertEqual(startMessage, AgentModeViewModel.staleResetRecoveryBlockedMessage)
        owner.viewModel.clearChat(tabID: owner.tabID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts, "Reset is refused while recovery owns the view")
        XCTAssertTrue(owner.viewModel.scheduledSendBusyState(tabID: owner.tabID).isBusy, "Scheduled dispatch treats the tab as reserved")
        XCTAssertFalse(owner.viewModel.canScheduleSend(tabID: owner.tabID, session: owner.session))
        XCTAssertNil(
            owner.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: owner.session),
            "Rebinding is blocked while the retained view is unsaved"
        )
        XCTAssertEqual(owner.session.activeAgentSessionID, sessionID)
        XCTAssertFalse(owner.viewModel.isComposeTabEligibleForAutomaticStash(owner.tabID))
        let laterSave = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(laterSave, .notWritten, "The retained snapshot is never written")
        let disk = try await owner.persistedSession()
        XCTAssertTrue(disk.toLiveItems().isEmpty, "The peer's committed reset is never overwritten from the retained view")
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recovery.id)
    }

    // MARK: - Explicit reload permit

    func testReloadPermitRejectsMutationDuringHeldReadAndConfirmedRetrySucceeds() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4382, peerWindowID: 4383)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        owner.viewModel.storeDraftText(for: owner.tabID, "unsent draft")
        let attachmentURL = try makeManagedAttachmentFile(in: owner.storageURL, name: "kept.png")
        let attachment = AgentImageAttachment(source: .localFile(path: attachmentURL.path))
        owner.session.pendingImageAttachments = [attachment]
        let retainedTexts = owner.session.items.map(\.text)

        // A real source mutation lands while the confirmed read is held after preparation.
        owner.viewModel.test_persistedLoadPrepareHook = { held in
            held.appendItem(.user("Late mutation during reload"))
        }
        let rejected = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        owner.viewModel.test_persistedLoadPrepareHook = nil
        XCTAssertEqual(rejected, AgentModeViewModel.staleResetRecoveryChangedMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertEqual(
            owner.session.staleResetRecovery?.phase,
            .retained(problem: AgentModeViewModel.staleResetRecoveryChangedMessage),
            "The rejected attempt returns to retained with its problem; nothing retries automatically"
        )
        XCTAssertNil(owner.session.persistenceState, "A rejected payload never installs authority")
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(
            owner.session.items.map(\.text),
            retainedTexts + ["Late mutation during reload"],
            "The retained view (including the late mutation) is untouched"
        )
        XCTAssertNil(owner.session.staleResetRecoveryTask)

        // A new confirmed attempt after quiescence replaces the view with the persisted snapshot.
        let succeeded = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(succeeded)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertTrue(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, fixture.sessionID)
        let adoptedState = owner.session.persistenceState(for: fixture.sessionID)
        XCTAssertNotNil(adoptedState, "Authority is adopted together with the persisted snapshot")
        XCTAssertTrue(owner.session.items.isEmpty, "Cleared history and the discarded working copy are absent")
        XCTAssertEqual(owner.viewModel.retrieveDraftText(for: owner.tabID), "unsent draft", "Unsent composer text survives the reload")
        XCTAssertEqual(owner.session.pendingImageAttachments, [attachment], "Pending attachments survive the reload")
        XCTAssertNil(owner.session.pendingTranscriptResetReceipt)
        XCTAssertTrue(owner.session.pendingFinalizedScheduledSendItemRemovals.isEmpty)

        // Renewed save capability: an ordinary edit saves under the adopted paired state.
        owner.session.appendItem(.user("After reload"))
        let savedAfterReload = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(savedAfterReload)
        let disk = try await owner.persistedSession()
        XCTAssertEqual(disk.toLiveItems().map(\.text), ["After reload"], "No discarded history is reapplied")
    }

    func testMissingAndUnreadableFilesRetainLocalWorkAndNeverEnterCreation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4384, peerWindowID: 4385)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        let retainedTexts = owner.session.items.map(\.text)
        let files = try await owner.viewModel.test_dataService.listAgentSessions(for: owner.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(fixture.sessionID.uuidString) })
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: fileURL, to: aside)

        // Missing file: the read reports it; local work and ownership history are retained and
        // no create-only preparation is ever attempted.
        let missing = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertEqual(missing, AgentModeViewModel.staleResetRecoveryMissingFileMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: AgentModeViewModel.staleResetRecoveryMissingFileMessage))
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, fixture.sessionID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Missing-file recovery never enters initial creation")

        // Unreadable file: the read fails; the retained view is untouched and retry stays available.
        try Data("not a session".utf8).write(to: fileURL)
        let unreadable = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertEqual(unreadable, AgentModeViewModel.staleResetRecoveryReadFailedMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: AgentModeViewModel.staleResetRecoveryReadFailedMessage))
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // Storage recovers: the next confirmed attempt succeeds under the same lifetime.
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: aside, to: fileURL)
        let restored = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(restored)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertNotNil(owner.session.persistenceState(for: fixture.sessionID))
        XCTAssertTrue(owner.session.hasLoadedPersistedState)
    }

    // MARK: - Ownership fences and disposal

    func testStaleFailureForPreviousBindingIsIgnoredAndDuplicatesCoalesce() async throws {
        let owner = try await makeHarness(windowID: 4386)
        owner.session.appendItem(.user("history"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let staleToken = try XCTUnwrap(owner.viewModel.test_saveCommitToken(for: owner.session, workspaceID: owner.workspace.id))
        let submittedState = try XCTUnwrap(owner.session.persistenceState(for: sessionID))

        // A→B: the failure belongs to the previous binding.
        let replacement = UUID()
        XCTAssertNotNil(owner.viewModel.test_installPersistentSessionBinding(sessionID: replacement, on: owner.session))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: staleToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertNil(owner.session.staleResetRecovery, "A failure for a previous binding never enters recovery")

        // A→B→A: the durable ID matches again but the transition generation does not.
        XCTAssertNotNil(owner.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: owner.session))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: staleToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertNil(owner.session.staleResetRecovery, "A→B→A invalidates the old failure even though the ID matches")

        // The current owner enters exactly once; a duplicate failure neither restarts the stop
        // nor replaces the episode identity.
        let currentToken = try XCTUnwrap(owner.viewModel.test_saveCommitToken(for: owner.session, workspaceID: owner.workspace.id))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: currentToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        let entered = try XCTUnwrap(owner.session.staleResetRecovery)
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertTrue(owner.session.isDirty)
        try await waitUntil("stop settled") {
            if case .retained = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: currentToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertEqual(owner.session.staleResetRecovery?.id, entered.id)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: nil), "A duplicate failure does not restart shutdown")
        XCTAssertNil(owner.session.staleResetRecoveryTask)
    }

    func testDisposalConsentCollectionNeverPublishesOrRelinquishesOwnership() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4387, peerWindowID: 4388)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        let retainedTexts = owner.session.items.map(\.text)

        // No presenter: removal is refused rather than discarding silently.
        owner.viewModel.staleResetRecoveryDiscardConfirmation = nil
        let refused = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [owner.tabID], operation: "Closing the tab")
        XCTAssertFalse(refused)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)

        // The user cancels the confirmation: the recovery and its view remain.
        let requests = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [requests] request in
            requests.requests.append(request)
            return false
        }
        let cancelled = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [owner.tabID], operation: "Stashing the tab")
        XCTAssertFalse(cancelled)
        XCTAssertEqual(requests.requests.count, 1)
        XCTAssertEqual(requests.requests.first?.tabCount, 1)
        XCTAssertEqual(requests.requests.first?.operation, "Stashing the tab")
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // Unrelated tabs pass through without any confirmation.
        let other = try await owner.viewModel.ensureSessionReady(tabID: UUID())
        let unrelated = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [other.tabID], operation: "Closing the tab")
        XCTAssertTrue(unrelated)
        XCTAssertEqual(requests.requests.count, 1)

        // Confirmation alone is UI-only. It does not publish admission, reserve the tab,
        // or relinquish the retained episode; only a complete removal operation may do that.
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [requests] request in
            requests.requests.append(request)
            return true
        }
        let confirmed = await owner.viewModel.confirmStaleResetRecoveryDiscard(
            tabIDs: [owner.tabID],
            operation: "Closing the tab"
        )
        XCTAssertTrue(confirmed)
        XCTAssertEqual(requests.requests.count, 2)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertNil(owner.viewModel.reservedComposeTabIDs[owner.tabID])
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // A final commit for an episode the admission never covered is refused and preserves it.
        let uncovered = try await makeRetainedFixture(ownerWindowID: 4401, peerWindowID: 4402)
        let uncoveredID = try XCTUnwrap(uncovered.owner.session.staleResetRecovery?.id)
        XCTAssertNil(uncovered.owner.session.staleResetRemovalAdmission)
        XCTAssertEqual(
            uncovered.owner.session.staleResetRecovery?.id,
            uncoveredID,
            "Consent collection never publishes an admission or relinquishes an uncovered episode"
        )
    }

    func testCompetingAdmissionCannotOverwriteAtomicReservation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4403, peerWindowID: 4404)
        let owner = fixture.owner
        let firstConfirmationGate = StaleResetGate()
        let confirmations = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [confirmations, firstConfirmationGate] request in
            confirmations.requests.append(request)
            if confirmations.requests.count == 1 {
                await firstConfirmationGate.waitForRelease()
            }
            return true
        }

        let firstAdmission = Task { @MainActor in
            await owner.viewModel.admitComposeTabRemoval(
                tabIDs: [owner.tabID],
                reason: .close
            )
        }
        try await waitUntil("first admission confirmation held") {
            firstConfirmationGate.isWaiting
        }

        let secondAdmission = await owner.viewModel.admitComposeTabRemoval(
            tabIDs: [owner.tabID],
            reason: .close
        )
        let secondOperationID = try XCTUnwrap(secondAdmission)
        let secondAdmissionID = try XCTUnwrap(
            owner.session.staleResetRemovalAdmission?.id
        )
        XCTAssertEqual(owner.viewModel.reservedComposeTabIDs[owner.tabID], secondOperationID)

        firstConfirmationGate.release()
        let firstOperationID = await firstAdmission.value
        XCTAssertNil(firstOperationID)
        XCTAssertEqual(owner.session.staleResetRemovalAdmission?.id, secondAdmissionID)
        XCTAssertEqual(
            owner.session.staleResetRemovalAdmission?.operationID,
            secondOperationID
        )
        XCTAssertEqual(owner.viewModel.reservedComposeTabIDs[owner.tabID], secondOperationID)

        owner.viewModel.finalizeComposeTabRemoval(operationID: secondOperationID)
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertNil(owner.viewModel.reservedComposeTabIDs[owner.tabID])
    }

    // MARK: - Disposal through the real PromptViewModel removal path

    func testStashPathFinalSaveDiscoveringResetIsVetoableAndRetainsTheTab() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4389)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)

        // A peer commits a reset; the local tab keeps dirty work it has not saved since, so no
        // recovery marker exists yet when the user stashes the tab.
        let peer = try await makeHarness(windowID: 4390, workspace: fixture.workspace, storageURL: fixture.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)
        session.appendItem(.user("Unsaved local work"))
        XCTAssertNil(session.staleResetRecovery)
        XCTAssertTrue(session.isDirty)

        // No presenter: the final save runs before the vetoable commit, discovers the reset, enters
        // stop-and-retain, and the removal is refused.
        viewModel.staleResetRecoveryDiscardConfirmation = nil
        await fixture.promptManager.stashTab(tabID)
        XCTAssertTrue(
            fixture.composeTabIDs().contains(tabID),
            "The stash is refused once the final save discovered the committed peer reset"
        )
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        let recovery = try XCTUnwrap(session.staleResetRecovery, "The final save entered recovery before the commit")
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Unsaved local work"])
        XCTAssertNil(session.persistenceState)

        // Declined confirmation: the tab, its retained transcript, and the recovery stay available.
        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return false
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.operation, "Stashing the tab")
        XCTAssertTrue(fixture.composeTabIDs().contains(tabID))
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.staleResetRecovery?.id, recovery.id)
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Unsaved local work"])
        let diskWhileRetained = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskWhileRetained?.toLiveItems().isEmpty, true, "The retained view is never written over the peer's reset")

        // Confirmed discard: the stash proceeds and the tab is removed.
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 2)
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        let diskAfterStash = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskAfterStash?.toLiveItems().isEmpty, true, "Teardown never resurrects the discarded local work")
    }

    func testStashHeldBetweenPreflightAndFinalSaveVetoesRemovalWhenThePeerResetLandsInBetween() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4403)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertFalse(session.isDirty, "The preflight will find a clean, saveable tab")
        let peer = try await makeHarness(windowID: 4404, workspace: fixture.workspace, storageURL: fixture.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)

        // Between the preflight (clean tab, no prompt) and the listener's final save: the peer
        // commits a reset and the local tab receives a mutation.
        viewModel.staleResetRecoveryDiscardConfirmation = nil
        let holds = DiscardRequestRecorder()
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer, holds] held in
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil
        XCTAssertEqual(holds.requests.count, 1, "The listener reached its final save exactly once")
        XCTAssertTrue(
            fixture.composeTabIDs().contains(tabID),
            "The final save discovered the reset after the preflight; removal is vetoed at the final boundary"
        )
        XCTAssertTrue(viewModel.sessions[tabID] === session, "The retained owner is preserved even though its runtime cleanup already settled")
        let recovery = try XCTUnwrap(session.staleResetRecovery)
        XCTAssertNil(session.staleResetRemovalAdmission, "An admission that never covered this episode is dropped")
        XCTAssertNil(session.persistenceState)
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Mutation after preflight"])
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = session.staleResetRecovery?.phase { return true }
            return false
        }
        let diskAfterVeto = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskAfterVeto?.toLiveItems().isEmpty, true, "The peer's reset is never overwritten by the vetoed removal")

        // Next attempt: the preflight shows exactly this episode; consent covers it; removal proceeds.
        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1)
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        _ = recovery
    }

    func testMCPRegistrationSettlesBeforeFinalSaveResetVetoAndConfirmedReload() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4421)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        let peer = try await makeHarness(
            windowID: 4422,
            workspace: fixture.workspace,
            storageURL: fixture.storageURL
        )
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        try await waitUntil("approval subscription installed before MCP activation") {
            session.applyEditsApprovalScopeGeneration != nil
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        let activeRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNotNil(activeRegistration)

        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held.tabID == tabID else { return }
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "Unconsented reset vetoes the stash")
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertNil(session.mcpControlContext)
        let registrationAfterAbort = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNil(registrationAfterAbort, "Preparation owns registration settlement even when commit aborts")
        try await waitUntil("MCP-controlled reset retained after veto") {
            if case .retained(problem: nil) = session.staleResetRecovery?.phase { return true }
            return false
        }
        let recoveryID = try XCTUnwrap(session.staleResetRecovery?.id)
        let reloadProblem = await viewModel.reloadLatestForStaleResetRecovery(
            tabID: tabID,
            recoveryID: recoveryID
        )
        XCTAssertNil(reloadProblem)
        XCTAssertNil(session.staleResetRecovery)
        XCTAssertTrue(session.hasLoadedPersistedState)
    }

    func testBatchVetoRestoresCapturedMCPApprovalAfterOtherSubscriptionCancellation() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4423)
        let viewModel = fixture.viewModel
        let orderedTabIDs = ([fixture.primaryTabID] + fixture.extraTabIDs)
            .sorted { $0.uuidString < $1.uuidString }
        let firstTabID = orderedTabIDs[0]
        let secondTabID = orderedTabIDs[1]
        let vetoTabID = orderedTabIDs[2]
        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        let veto = try await viewModel.ensureSessionReady(tabID: vetoTabID)
        let approvalStore = viewModel.applyEditsApprovalStore

        for session in [first, second, veto] {
            session.appendItem(.user("Pre-reset history"))
            let saved = await viewModel.flushSave(for: session.tabID)
            XCTAssertTrue(saved)
        }
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let vetoSessionID = try XCTUnwrap(veto.activeAgentSessionID)
        let peer = try await makeHarness(
            windowID: 4424,
            workspace: fixture.workspace,
            storageURL: fixture.storageURL
        )
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: vetoSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)

        try await waitUntil("both approval subscriptions installed") {
            first.applyEditsApprovalScopeGeneration != nil
                && second.applyEditsApprovalScopeGeneration != nil
        }
        for session in [first, second] {
            let generation = try XCTUnwrap(session.applyEditsApprovalScopeGeneration)
            let accepted = await approvalStore.setAutoEditEnabled(
                false,
                for: viewModel.applyEditsScope(for: session.tabID),
                ifOwnedBy: generation,
                updateGlobalDefault: false
            )
            XCTAssertTrue(accepted)
        }
        try await waitUntil("both local preferences are off") {
            !first.autoEditEnabled && !second.autoEditEnabled
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: firstTabID,
            sessionID: firstSessionID,
            originatingConnectionID: nil
        )
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: secondTabID,
            sessionID: secondSessionID,
            originatingConnectionID: nil
        )
        XCTAssertTrue(first.autoEditEnabled)
        XCTAssertTrue(second.autoEditEnabled)
        let secondScope = viewModel.applyEditsScope(for: secondTabID)
        let forcedServiceSetting = await approvalStore.autoEditEnabled(for: secondScope)
        XCTAssertTrue(forcedServiceSetting)
        let secondSubscriptionTask = try XCTUnwrap(second.applyEditsApprovalSubscriptionTask)

        let firstGate = StaleResetGate()
        viewModel.test_composeTabRemovalEarlyTeardownHook = { held in
            guard held === first else { return }
            await firstGate.waitForRelease()
        }
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held === veto else { return }
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        defer {
            firstGate.release()
            viewModel.test_composeTabRemovalEarlyTeardownHook = nil
            viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil
        }
        let closeTask = Task { @MainActor in
            await fixture.promptManager.closeAllComposeTabs()
        }
        try await waitUntil("first target held during preparation") {
            firstGate.isWaiting
        }
        try await waitUntil("second cancelled subscription finished before deactivation") {
            second.applyEditsApprovalSubscriptionTask == nil
                && second.applyEditsApprovalScopeGeneration == nil
        }
        await secondSubscriptionTask.value
        XCTAssertNotNil(second.mcpControlContext)
        XCTAssertTrue(second.autoEditEnabled)

        firstGate.release()
        await closeTask.value

        XCTAssertTrue(fixture.composeTabIDs().contains(secondTabID), "The later reset vetoed the batch")
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertNil(second.staleResetRecovery, "The second target remains a healthy owner")
        XCTAssertNil(second.mcpControlContext)
        XCTAssertFalse(second.autoEditEnabled, "The captured owner's local preference is restored")
        let restoredServiceSetting = await approvalStore.autoEditEnabled(for: secondScope)
        XCTAssertFalse(restoredServiceSetting, "The captured generation restores the service override")
        let secondRegistration = await AgentRunSessionStore.currentRegistration(for: secondSessionID)
        XCTAssertNil(secondRegistration)
        XCTAssertNotNil(veto.staleResetRecovery, "A later final save supplies the batch veto")
    }

    func testBatchRemovalVetoRetainsConsentedAndNewlyDiscoveredEpisodesTogether() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4405)
        let viewModel = fixture.viewModel
        let firstTabID = fixture.extraTabIDs[0]
        let secondTabID = fixture.extraTabIDs[1]
        let peer = try await makeHarness(windowID: 4406, workspace: fixture.workspace, storageURL: fixture.storageURL)

        // First target: a consented recovery already retained before removal.
        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        first.appendItem(.user("First history"))
        let firstSaved = await viewModel.flushSave(for: firstTabID)
        XCTAssertTrue(firstSaved)
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: firstSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let firstResetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(firstResetSaved)
        first.appendItem(.user("First unsaved work"))
        let firstRejected = await viewModel.flushSaveDetailed(for: firstTabID)
        XCTAssertEqual(firstRejected, .notWritten)
        try await waitUntil("first target retained") {
            if case .retained(problem: nil) = first.staleResetRecovery?.phase { return true }
            return false
        }
        let consentedEpisodeID = try XCTUnwrap(first.staleResetRecovery?.id)

        // Second target: clean and saveable when the preflight runs; its reset lands only inside
        // the listener's final save.
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second history"))
        let secondSaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let secondPeerTabID = UUID()
        let secondPeer = try await peer.viewModel.ensureSessionReady(tabID: secondPeerTabID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: secondSessionID, on: secondPeer))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: secondPeerTabID)
        XCTAssertFalse(second.isDirty)

        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held.tabID == secondTabID else { return }
            peer.viewModel.clearChat(tabID: secondPeerTabID)
            _ = await peer.viewModel.flushSave(for: secondPeerTabID)
            held.appendItem(.user("Second mutation during final save"))
        }
        // Real two-target `.close` batch through PromptViewModel.
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1, "Consent covered only the first target's episode")
        let remainingTabIDs = fixture.composeTabIDs()
        XCTAssertTrue(remainingTabIDs.contains(firstTabID), "The batch is vetoed: the consented target stays")
        XCTAssertTrue(remainingTabIDs.contains(secondTabID), "The batch is vetoed: the newly discovered target stays")
        XCTAssertTrue(viewModel.sessions[firstTabID] === first)
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertEqual(first.staleResetRecovery?.id, consentedEpisodeID, "The consented episode is not relinquished when another target vetoes")
        XCTAssertEqual(first.items.map(\.text), ["First history", "First unsaved work"])
        XCTAssertNotNil(second.staleResetRecovery, "The episode discovered by the final save is retained")
        XCTAssertEqual(second.items.map(\.text), ["Second history", "Second mutation during final save"])
        XCTAssertNil(first.staleResetRemovalAdmission)
        XCTAssertNil(second.staleResetRemovalAdmission)
        XCTAssertNil(first.persistenceState)
        XCTAssertNil(second.persistenceState)
        try await waitUntil("second target retained") {
            if case .retained(problem: nil) = second.staleResetRecovery?.phase { return true }
            return false
        }
        let firstDisk = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        let secondDisk = try await viewModel.test_dataService.loadAgentSession(id: secondSessionID, for: fixture.workspace)
        XCTAssertEqual(firstDisk?.toLiveItems().isEmpty, true, "A vetoed close deletes nothing and writes nothing")
        XCTAssertEqual(secondDisk?.toLiveItems().isEmpty, true)

        // Next attempt shows both episodes; consent covers both; the batch is removed.
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        XCTAssertEqual(prompts.requests.count, 2)
        XCTAssertEqual(prompts.requests.last?.tabCount, 2)
        let afterRemoval = fixture.composeTabIDs()
        XCTAssertFalse(afterRemoval.contains(firstTabID))
        XCTAssertFalse(afterRemoval.contains(secondTabID))
        XCTAssertNil(viewModel.sessions[firstTabID])
        XCTAssertNil(viewModel.sessions[secondTabID])
        // The backing files were last written by the peer window (their stub `composeTabID` is
        // the peer's tab), so this window's close does not resolve them for deletion; what the
        // consented close must guarantee is that the discarded retained work never reaches them.
        let firstAfterClose = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        let secondAfterClose = try await viewModel.test_dataService.loadAgentSession(id: secondSessionID, for: fixture.workspace)
        XCTAssertEqual(firstAfterClose?.toLiveItems().isEmpty, true, "A consented close never resurrects the discarded work")
        XCTAssertEqual(secondAfterClose?.toLiveItems().isEmpty, true)
    }

    func testChangeAfterFinalSaveWhileAnotherTargetIsHeldIsReconsideredAndVetoesOnDiscoveredReset() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4407)
        let viewModel = fixture.viewModel
        let firstTabID = fixture.extraTabIDs[0]
        let secondTabID = fixture.extraTabIDs[1]
        let peer = try await makeHarness(windowID: 4408, workspace: fixture.workspace, storageURL: fixture.storageURL)

        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        first.appendItem(.user("First history"))
        let firstSaved = await viewModel.flushSave(for: firstTabID)
        XCTAssertTrue(firstSaved)
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: firstSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second history"))
        let secondSaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)

        // The first target's final save completes; while the second target's teardown is held,
        // the first target receives output and a peer commits a reset of its conversation.
        let holds = DiscardRequestRecorder()
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer, first, holds] held in
            guard held.tabID == secondTabID else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            XCTAssertEqual(first.staleResetRemovalAdmission?.isFinalSaveCompleted, true, "The first target's final save completed before the second was held")
            first.appendItem(.user("Output after the final save"))
            XCTAssertNil(first.saveDebounceTask, "A reserved owner never schedules a debounced save")
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertEqual(holds.requests.count, 1)
        let remaining = fixture.composeTabIDs()
        XCTAssertTrue(remaining.contains(firstTabID), "The changed target was re-saved, discovered the reset, and vetoed the batch")
        XCTAssertTrue(remaining.contains(secondTabID))
        XCTAssertTrue(viewModel.sessions[firstTabID] === first)
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertNotNil(first.staleResetRecovery, "The reset discovered by the reconsideration save is retained, never removed")
        XCTAssertEqual(first.items.map(\.text), ["First history", "Output after the final save"], "The complete retained transcript survives")
        XCTAssertNil(first.persistenceState)
        XCTAssertNil(first.staleResetRemovalAdmission, "The vetoed operation releases its reservation")
        XCTAssertNil(second.staleResetRemovalAdmission)
        XCTAssertNil(second.staleResetRecovery)
        try await waitUntil("first target retained") {
            if case .retained(problem: nil) = first.staleResetRecovery?.phase { return true }
            return false
        }
        let firstDisk = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        XCTAssertEqual(firstDisk?.toLiveItems().isEmpty, true, "The peer's reset is never overwritten by the vetoed removal")
        // The released owners accept work again.
        second.appendItem(.user("Second tab continues"))
        let secondResaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondResaved, "A released, healthy target saves normally after the veto")
    }

    func testOwnerReplacedDuringTeardownVetoesRemovalAndPreservesBothOwners() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4409)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let originalSessionID = try XCTUnwrap(original.activeAgentSessionID)

        // While the operation's teardown is held, the tab's owner object is replaced.
        let replacement = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [viewModel, replacement] held in
            guard held.tabID == tabID else { return }
            viewModel.test_installLiveSession(replacement)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "A replaced owner is not covered by the admission: the removal is vetoed")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement, "The replacement owner is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertEqual(original.items.map(\.text), ["Original history"], "The captured owner is not destroyed")
        XCTAssertEqual(original.activeAgentSessionID, originalSessionID)
        let disk = try await viewModel.test_dataService.loadAgentSession(id: originalSessionID, for: fixture.workspace)
        XCTAssertNotNil(disk, "A vetoed removal deletes nothing")
    }

    func testCommittedRemovalBlocksRematerializationUntilCapturedCleanupFinishes() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4410)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)

        let observations = DiscardRequestRecorder()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [viewModel, observations] held in
            guard held.tabID == tabID else { return }
            let optionalOwner = viewModel.session(for: tabID, createIfNeeded: true)
            let readinessWasRejected: Bool
            do {
                _ = try await viewModel.ensureSessionReady(tabID: tabID)
                readinessWasRejected = false
            } catch {
                readinessWasRejected = true
            }
            let rebound = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: held)
            observations.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(
                tabCount: optionalOwner == nil && readinessWasRejected && rebound == nil ? 0 : 1,
                operation: "postcommit exclusion"
            ))
        }

        await fixture.promptManager.closeComposeTab(tabID)
        viewModel.test_composeTabRemovalPhaseTwoHook = nil

        XCTAssertEqual(observations.requests.count, 1)
        XCTAssertEqual(
            observations.requests.first?.tabCount,
            0,
            "Optional materialization, throwing readiness, and rebinding all refuse a committed target"
        )
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        XCTAssertNil(viewModel.session(for: tabID, createIfNeeded: true))
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testHeldInitialApprovalSetupCannotClaimReplacementScopeAfterRemoval() async throws {
        let windowID = 4420
        let fixture = try await makePromptManagedFixture(windowID: windowID)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let approvalStore = viewModel.applyEditsApprovalStore
        let setupGate = StaleResetGate()
        await approvalStore.test_setInitialSetupHook { _ in
            let shouldHold = await MainActor.run { !setupGate.isWaiting }
            if shouldHold {
                await setupGate.waitForRelease()
            }
        }
        defer {
            setupGate.release()
            Task { await approvalStore.test_setInitialSetupHook(nil) }
        }

        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        let originalSetup = try XCTUnwrap(original.applyEditsApprovalSubscriptionTask)
        try await waitUntil("original setup held before service authority") {
            setupGate.isWaiting
        }

        await fixture.promptManager.closeComposeTab(tabID)
        XCTAssertNil(viewModel.sessions[tabID])
        let replacement = AgentModeViewModel.TabSession(tabID: tabID)
        replacement.autoEditEnabled = false
        viewModel.test_installLiveSession(replacement)
        XCTAssertTrue(viewModel.session(for: tabID, createIfNeeded: false) === replacement)
        try await waitUntil("replacement approval owner installed") {
            replacement.applyEditsApprovalSubscriptionID != nil
                && replacement.applyEditsApprovalScopeGeneration != nil
        }
        let replacementGeneration = try XCTUnwrap(replacement.applyEditsApprovalScopeGeneration)
        let scope = ApplyEditsApprovalScope(windowID: windowID, tabID: tabID)

        setupGate.release()
        await originalSetup.value
        let replacementStillOwnsScope = await approvalStore.setAutoEditEnabled(
            false,
            for: scope,
            ifOwnedBy: replacementGeneration,
            updateGlobalDefault: false
        )
        XCTAssertTrue(replacementStillOwnsScope)
        let enabled = await approvalStore.autoEditEnabled(for: scope)
        XCTAssertFalse(enabled, "A cancelled old setup never overwrites replacement configuration")
        XCTAssertEqual(replacement.applyEditsApprovalScopeGeneration, replacementGeneration)
        _ = await approvalStore.cleanupScope(scope, ifOwnedBy: replacementGeneration)
        await approvalStore.test_setInitialSetupHook(nil)
    }

    func testConditionalApprovalAndMCPPostcleanupPreserveNewerServiceOwners() async throws {
        let windowID = 4417
        let fixture = try await makePromptManagedFixture(windowID: windowID)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Cleanup ownership"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        try await waitUntil("approval subscription installed") {
            session.applyEditsApprovalSubscriptionID != nil
                && session.applyEditsApprovalScopeGeneration != nil
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )

        let approvalGate = StaleResetGate()
        let mcpGate = StaleResetGate()
        let approvalStore = viewModel.applyEditsApprovalStore
        await approvalStore.test_setConditionalCleanupHook { _, _ in
            await approvalGate.waitForRelease()
        }
        defer {
            Task {
                await approvalStore.test_setConditionalCleanupHook(nil)
                await AgentRunSessionStore.shared.test_setCleanupHook(nil)
            }
        }

        let closeTask = Task { @MainActor in
            await fixture.promptManager.closeComposeTab(tabID)
        }
        try await waitUntil("approval cleanup held at owner check") {
            approvalGate.isWaiting
        }

        let scope = ApplyEditsApprovalScope(windowID: windowID, tabID: tabID)
        let replacementApproval = await approvalStore.subscribe(scope: scope)
        await AgentRunSessionStore.shared.test_setCleanupHook { _ in
            await mcpGate.waitForRelease()
        }
        XCTAssertNil(viewModel.session(for: tabID, createIfNeeded: true))
        let reservedControlActivation = try? await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        XCTAssertNil(reservedControlActivation)
        approvalGate.release()

        try await waitUntil("MCP cleanup held at owner check") {
            mcpGate.isWaiting
        }
        let replacementRegistration = await AgentRunSessionStore.shared.register(
            sessionID: sessionID
        )
        mcpGate.release()
        await closeTask.value

        let newerApprovalStillOwnsScope = await approvalStore.setAutoEditEnabled(
            false,
            for: scope,
            ifOwnedBy: replacementApproval.generation,
            updateGlobalDefault: false
        )
        XCTAssertTrue(newerApprovalStillOwnsScope)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(
            for: sessionID
        )
        XCTAssertEqual(currentRegistration, replacementRegistration)

        _ = await approvalStore.cleanupScope(
            scope,
            ifOwnedBy: replacementApproval.generation
        )
        await AgentRunSessionStore.cleanup(registration: replacementRegistration)
        await approvalStore.test_setConditionalCleanupHook(nil)
        await AgentRunSessionStore.shared.test_setCleanupHook(nil)
    }

    func testConditionalDeletionFailureKeepsCapturedFileAndIndexEvidence() async throws {
        struct ForcedDeletionFailure: Error {}

        let fixture = try await makePromptManagedFixture(windowID: 4418)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Keep durable evidence"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertNotNil(viewModel.ownerValidatedSessionIndex[sessionID])

        await viewModel.test_dataService.test_setConditionalDeletionHook { _ in
            throw ForcedDeletionFailure()
        }
        await fixture.promptManager.closeComposeTab(tabID)
        await viewModel.test_dataService.test_setConditionalDeletionHook(nil)

        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        let retainedFile = try await viewModel.test_dataService.loadAgentSession(
            id: sessionID,
            for: fixture.workspace
        )
        XCTAssertNotNil(retainedFile)
        XCTAssertNotNil(
            viewModel.ownerValidatedSessionIndex[sessionID],
            "Failed deletion retains matching index evidence"
        )
    }

    func testFinalSaveHeldDuringMutationRecordsTheWrittenSnapshotAndReconsiders() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4411)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("History"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)

        // The tab becomes dirty only after admission (inside the operation's early teardown), so
        // the operation's own final save is the save that snapshots it. That save suspends before
        // the write and a mutation lands while the write is awaited.
        viewModel.test_composeTabRemovalEarlyTeardownHook = { held in
            guard held.tabID == tabID else { return }
            held.appendItem(.user("Dirty before removal"))
        }
        let holds = DiscardRequestRecorder()
        viewModel.test_saveSessionBeforeWriteHook = { [holds] held in
            guard held.tabID == tabID, held.staleResetRemovalAdmission?.isReserved == true else { return }
            guard holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            held.appendItem(.user("Mutation during the final save"))
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_saveSessionBeforeWriteHook = nil
        viewModel.test_composeTabRemovalEarlyTeardownHook = nil

        XCTAssertEqual(holds.requests.count, 1, "The mutation was delivered during the awaited final save exactly once")
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID), "The reconsideration saved the newer content; removal completed")
        XCTAssertNil(viewModel.sessions[tabID])
        let disk = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(
            disk?.toLiveItems().map(\.text),
            ["History", "Dirty before removal", "Mutation during the final save"],
            "Content that landed during the awaited final save is durably saved before removal"
        )
    }

    func testTargetReplacedDuringPreflightIsNotAdmittedAndKeepsItsTab() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4412)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        original.appendItem(.user("Original unsaved work"))

        // The preflight's discovery save for the dirty target is suspended; the tab's owner is
        // replaced meanwhile (no reservation exists yet).
        let replacement = AgentModeViewModel.TabSession(tabID: tabID)
        let holds = DiscardRequestRecorder()
        viewModel.test_saveSessionBeforeWriteHook = { [viewModel, replacement, holds] held in
            guard held === original, holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            viewModel.test_installLiveSession(replacement)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_saveSessionBeforeWriteHook = nil

        XCTAssertEqual(holds.requests.count, 1)
        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "A target replaced during admission is never admitted: the tab stays")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement, "The replacement is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertNil(original.staleResetRemovalAdmission, "No admission survives a refused operation")
        XCTAssertEqual(original.items.map(\.text), ["Original history", "Original unsaved work"], "The captured owner's content is retained")
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testAbsentTargetMaterializedDuringPreflightRefusesAdmission() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4413)
        let viewModel = fixture.viewModel
        let dirtyTabID = fixture.extraTabIDs[0]
        let absentTabID = fixture.extraTabIDs[1]
        let dirty = try await viewModel.ensureSessionReady(tabID: dirtyTabID)
        dirty.appendItem(.user("Dirty history"))
        let saved = await viewModel.flushSave(for: dirtyTabID)
        XCTAssertTrue(saved)
        dirty.appendItem(.user("Dirty unsaved work"))
        XCTAssertNil(viewModel.sessions[absentTabID], "The second target has no live session at entry")

        // While the preflight's discovery save is suspended, the absent target materializes.
        let holds = DiscardRequestRecorder()
        var materializationError: Error?
        viewModel.test_saveSessionBeforeWriteHook = { [viewModel, holds] held in
            guard held === dirty, holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            do {
                _ = try await viewModel.ensureSessionReady(tabID: absentTabID)
            } catch {
                materializationError = error
            }
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_saveSessionBeforeWriteHook = nil

        XCTAssertNil(
            materializationError,
            "The preflight fixture must materialize the absent target: \(String(describing: materializationError))"
        )
        XCTAssertEqual(holds.requests.count, 1)
        let remaining = fixture.composeTabIDs()
        XCTAssertTrue(remaining.contains(dirtyTabID), "Admission is refused for the whole batch")
        XCTAssertTrue(remaining.contains(absentTabID))
        XCTAssertTrue(viewModel.sessions[dirtyTabID] === dirty)
        XCTAssertNotNil(viewModel.sessions[absentTabID], "The materialized owner is untouched")
        XCTAssertNil(dirty.staleResetRemovalAdmission)
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testActiveReplacementDuringEarlyTeardownIsNeitherCancelledNorCleanedUp() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4414)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)

        // While the operation is suspended in early teardown, the owner is replaced by a session
        // with an active run.
        let replacement = AgentModeViewModel.TabSession(tabID: tabID)
        let replacementRunID = UUID()
        viewModel.test_composeTabRemovalEarlyTeardownHook = { [viewModel, replacement] held in
            guard held === original else { return }
            viewModel.test_installLiveSession(replacement)
            replacement.runID = replacementRunID
            viewModel.setAgentRunActive(tabID, isActive: true)
            replacement.runState = .running
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabRemovalEarlyTeardownHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "The operation aborts on the replaced owner")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement)
        XCTAssertEqual(replacement.runState, .running, "The older operation never cancels the replacement's run")
        XCTAssertEqual(replacement.runID, replacementRunID)
        XCTAssertTrue(viewModel.isTabRunning(tabID), "The replacement's run bookkeeping is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertEqual(original.items.map(\.text), ["Original history"])
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
        // Cleanup for the test runtime bookkeeping.
        viewModel.setAgentRunActive(tabID, isActive: false)
        replacement.runState = .idle
    }

    func testWorkspaceChangeDuringHeldPhaseOneAbortsWithoutRetiringTargets() async throws {
        let owner = try await makeHarness(windowID: 4415)
        owner.session.appendItem(.user("History"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let otherStorage = owner.storageURL.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let otherWorkspace = WorkspaceModel(name: "Other", repoPaths: [otherStorage.path], customStoragePath: otherStorage)

        // The active workspace changes while phase 1 is held before the final save.
        owner.viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [owner] held in
            guard held.tabID == owner.tabID else { return }
            owner.viewModel.test_establishPersistenceWorkspace(otherWorkspace)
        }
        await owner.viewModel.handleComposeTabsWillClose([owner.tabID], reason: .close)
        owner.viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(owner.viewModel.sessions[owner.tabID] === owner.session, "The operation aborts; its target is not retired")
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertTrue(owner.viewModel.reservedComposeTabIDs.isEmpty)
        XCTAssertTrue(owner.viewModel.composeTabRemovalOperations.isEmpty)
        owner.viewModel.test_establishPersistenceWorkspace(owner.workspace)
        let disk = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        XCTAssertNotNil(disk, "Nothing was deleted from the original workspace")
        // The released owner accepts work again.
        owner.session.appendItem(.user("After the abort"))
        let resaved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(resaved)
    }

    func testWorkspaceChangeAfterCommitUsesCapturedCleanupResourcesOnly() async throws {
        let owner = try await makeHarness(windowID: 4416)
        owner.session.appendItem(.user("History"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        // A different workspace holds a session for the same compose tab ID.
        let otherStorage = owner.storageURL.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let otherWorkspace = WorkspaceModel(name: "Other", repoPaths: [otherStorage.path], customStoragePath: otherStorage)
        let foreignSessionID = sessionID
        _ = try await owner.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: foreignSessionID, workspaceID: otherWorkspace.id, composeTabID: owner.tabID, name: "Foreign"),
            for: otherWorkspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        // The active workspace changes after the verdict, while the destructive phase is held.
        let foreignSortDate = Date(timeIntervalSinceReferenceDate: 4416)
        let foreignIndexEntry = AgentSessionIndexEntry(
            id: foreignSessionID,
            tabID: owner.tabID,
            name: "Foreign",
            lastUserMessageAt: foreignSortDate,
            savedAt: foreignSortDate,
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: nil,
            remoteHostName: nil,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        owner.viewModel.test_composeTabRemovalPhaseTwoHook = { [owner] held in
            guard held.tabID == owner.tabID else { return }
            owner.viewModel.test_establishPersistenceWorkspace(otherWorkspace)
            guard let foreignOwner = owner.viewModel.test_sessionIndexOwner else {
                XCTFail("Foreign workspace owner was not installed")
                return
            }
            owner.viewModel.test_installSessionIndexSnapshot(
                [foreignSessionID: foreignIndexEntry],
                owner: foreignOwner,
                latestOwner: foreignOwner,
                activeWorkspace: otherWorkspace
            )
        }
        await owner.viewModel.handleComposeTabsWillClose([owner.tabID], reason: .close)
        owner.viewModel.test_composeTabRemovalPhaseTwoHook = nil

        XCTAssertNil(owner.viewModel.sessions[owner.tabID], "Logical Agent removal committed before cleanup suspended")
        let foreign = try await owner.viewModel.test_dataService.loadAgentSession(id: foreignSessionID, for: otherWorkspace)
        XCTAssertNotNil(foreign, "Captured cleanup never targets the newly active workspace")
        XCTAssertEqual(owner.viewModel.ownerValidatedSessionIndex[foreignSessionID], foreignIndexEntry)
        XCTAssertEqual(owner.viewModel.ownerValidatedSessionListSortDates[owner.tabID], foreignSortDate)
        owner.viewModel.test_establishPersistenceWorkspace(owner.workspace)
        let original = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        XCTAssertNil(original, "Committed cleanup deletes only the captured original-workspace lifetime")
        XCTAssertTrue(owner.viewModel.reservedComposeTabIDs.isEmpty)
        XCTAssertTrue(owner.viewModel.composeTabRemovalOperations.isEmpty)
    }

    func testDiscardConsentIsRevalidatedAgainstEpisodesEnteredDuringConfirmation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4393, peerWindowID: 4394)
        let owner = fixture.owner
        let consentedID = try XCTUnwrap(owner.session.staleResetRecovery?.id)

        // A second tab in the same removal set is bound to another persisted session and is
        // still saveable when the confirmation is presented.
        let secondTabID = UUID()
        let second = try await owner.viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second tab history"))
        let secondSaved = await owner.viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let secondPeerTab = UUID()
        let secondPeer = try await fixture.peer.viewModel.ensureSessionReady(tabID: secondPeerTab)
        XCTAssertNotNil(fixture.peer.viewModel.test_installPersistentSessionBinding(sessionID: secondSessionID, on: secondPeer))
        _ = await fixture.peer.viewModel.test_hydrateBoundSession(tabID: secondPeerTab)

        // While the user is looking at the confirmation for the first tab, the second tab's
        // conversation is reset by the peer and the second tab's own save discovers it.
        let prompts = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [prompts, fixture, owner, second] request in
            prompts.requests.append(request)
            fixture.peer.viewModel.clearChat(tabID: secondPeerTab)
            _ = await fixture.peer.viewModel.flushSave(for: secondPeerTab)
            second.appendItem(.user("Second tab unsaved work"))
            _ = await owner.viewModel.flushSaveDetailed(for: second.tabID)
            return true
        }
        let admitted = await owner.viewModel.confirmStaleResetRecoveryDiscard(
            tabIDs: [owner.tabID, secondTabID],
            operation: "Closing the tab"
        )
        XCTAssertFalse(admitted, "Consent covered one episode; a second tab entered recovery meanwhile, so removal needs a new confirmation")
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, consentedID, "Nothing is relinquished when consent is stale")
        XCTAssertNotNil(second.staleResetRecovery)
        XCTAssertEqual(second.items.map(\.text), ["Second tab history", "Second tab unsaved work"])
    }

    // MARK: - Ingestion boundaries

    func testRemoteRecoveryRetiresTheAttachmentSoHeldRowsCannotMutateTheReplacement() async throws {
        let owner = try await makeHarness(windowID: 4395)
        let sessionID = try XCTUnwrap(owner.viewModel.test_ensureSessionBoundToTab(owner.session))
        owner.session.remoteHost = AgentSessionRemoteHostBinding(
            hostID: "host-1",
            hostDisplayName: "Studio Mac",
            remoteSessionID: sessionID.uuidString
        )
        owner.session.appendItem(.user("Pre-reset prompt"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        // A delivery captured by the attachment that exists before recovery.
        let retiredGeneration = owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID)
        owner.session.runState = .running

        let peer = try await makeHarness(windowID: 4396, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertFalse(owner.session.runState.isActive, "The detached projection's mirrored run is frozen locally")
        XCTAssertFalse(owner.viewModel.remoteCoordinator.isAttached(tabID: owner.tabID))
        XCTAssertNotEqual(
            owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID),
            retiredGeneration,
            "Stopping retired the attachment's delivery generation"
        )
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)

        // Confirmed reload adopts the reset snapshot and its authority.
        let reloaded = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(reloaded)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertNotNil(owner.session.persistenceState(for: sessionID))
        let replacementTexts = owner.session.items.map(\.text)
        XCTAssertFalse(replacementTexts.contains("Pre-reset prompt"))
        XCTAssertFalse(replacementTexts.contains("Sent after the peer reset"))
        let replacementRevision = owner.session.sourceItemsRevision

        // The retired attachment's delayed delivery arrives after application: dropped, and it
        // can neither mutate nor dirty the replacement.
        owner.viewModel.remoteCoordinator.test_handleEvent(
            .transcriptRows(
                items: [AgentChatItem.user("Late row from the retired attachment", sequenceIndex: 0)],
                removedIDs: [],
                hostRowIDByClientItemID: [:]
            ),
            tabID: owner.tabID,
            deliveryGeneration: retiredGeneration
        )
        XCTAssertEqual(owner.session.items.map(\.text), replacementTexts, "A retired delivery never mutates the replacement")
        XCTAssertEqual(owner.session.sourceItemsRevision, replacementRevision)
        _ = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        let diskAfterLateDelivery = try await owner.persistedSession()
        XCTAssertFalse(
            diskAfterLateDelivery.toLiveItems().contains { $0.text == "Late row from the retired attachment" },
            "Nothing from the retired delivery becomes saveable content under the adopted authority"
        )

        // The fence is generation-based: a delivery under the current attachment still applies.
        let currentGeneration = owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID)
        owner.viewModel.remoteCoordinator.test_handleEvent(
            .transcriptRows(
                items: [AgentChatItem.user("Row from the current attachment", sequenceIndex: 1)],
                removedIDs: [],
                hostRowIDByClientItemID: [:]
            ),
            tabID: owner.tabID,
            deliveryGeneration: currentGeneration
        )
        XCTAssertTrue(owner.session.items.contains { $0.text == "Row from the current attachment" })
    }

    func testLocalRecoveryWaitsForOwnedTerminalResourceTeardownBeforeRetaining() async throws {
        let owner = try await makeHarness(windowID: 4397)
        owner.session.appendItem(.user("Pre-reset prompt"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let peer = try await makeHarness(windowID: 4398, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        // An owned run attempt whose terminal resources tear down asynchronously (held).
        let ownership = owner.session.beginRunAttempt(source: "AgentStaleResetOwnershipTests")
        let teardownGate = StaleResetGate()
        owner.session.installRunAttemptTerminalResources(ownership: ownership) { [teardownGate] _ in
            let teardown: AgentRunAttemptTerminalResources.Teardown = { await teardownGate.waitForRelease() }
            return teardown
        }
        owner.session.runID = UUID()
        owner.viewModel.setAgentRunActive(owner.tabID, isActive: true)
        owner.session.runState = .running

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        XCTAssertNotNil(owner.session.staleResetRecovery)
        try await waitUntil("terminal state published while the owned teardown is held") {
            teardownGate.isWaiting && owner.session.runState == .cancelled
        }
        XCTAssertEqual(
            owner.session.staleResetRecovery?.phase,
            .stopping(problem: nil),
            "Recovery stays stopping until the run attempt's terminal resources are torn down"
        )
        XCTAssertNil(owner.session.persistenceState)
        // A final source mutation delivered during the held teardown is retained.
        owner.session.appendItem(.user("Final row during teardown"))

        teardownGate.release()
        try await waitUntil("stop settled into retained after teardown") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertNil(owner.session.activeRunOwnership)
        XCTAssertNil(owner.session.runAttemptTerminalResources)
        XCTAssertFalse(owner.viewModel.isTabRunning(owner.tabID))
        let texts = owner.session.items.map(\.text)
        XCTAssertTrue(texts.contains("Sent after the peer reset"))
        XCTAssertTrue(texts.contains("Final row during teardown"))
        XCTAssertNil(owner.session.persistenceState)
    }

    // MARK: - Harness

    private struct PromptManagedFixture {
        let viewModel: AgentModeViewModel
        let promptManager: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let storageURL: URL
        let primaryTabID: UUID
        /// Two further compose tabs to the right of `primaryTabID` (batch-removal targets).
        let extraTabIDs: [UUID]

        /// Compose tabs as stored on the workspace model (the source the removal path mutates).
        @MainActor
        func composeTabIDs() -> [UUID] {
            workspaceManager.workspaces.first { $0.id == workspace.id }?.composeTabs.map(\.id) ?? []
        }
    }

    /// Real PromptViewModel + WorkspaceManagerViewModel with two compose tabs and the Agent VM's
    /// production lifecycle hooks installed, so removal runs through the actual stash/close path.
    private func makePromptManagedFixture(windowID: Int) async throws -> PromptManagedFixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentStaleResetOwnershipTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
        }
        let primaryTabID = UUID()
        // Removal operations process targets in tab-ID order; sort so `extraTabIDs[0]` is first.
        let extraTabIDs = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let workspace = WorkspaceModel(
            name: "Agent Stale Reset Disposal",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL,
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: primaryTabID, name: "Primary"),
                ComposeTabState(id: extraTabIDs[0], name: "Second"),
                ComposeTabState(id: extraTabIDs[1], name: "Third")
            ],
            activeComposeTabID: primaryTabID
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
        let promptManager = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: promptManager,
            performInitialWorkspaceActivation: false
        )
        promptManager.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        promptManager.loadComposeTabsFromWorkspace(workspace)

        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: promptManager, workspaceManager: workspaceManager)
        viewModel.test_installPromptManagerLifecycleHooks()
        viewModel.test_setCurrentTabIDOverride(primaryTabID)
        return PromptManagedFixture(
            viewModel: viewModel,
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            workspace: workspace,
            storageURL: storageURL,
            primaryTabID: primaryTabID,
            extraTabIDs: extraTabIDs
        )
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let storageURL: URL
        let tabID: UUID
        let session: AgentModeViewModel.TabSession

        struct MissingPersistedSession: Error {}

        @MainActor
        func persistedSession() async throws -> AgentSession {
            guard let sessionID = session.activeAgentSessionID,
                  let persisted = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace)
            else {
                throw MissingPersistedSession()
            }
            return persisted
        }
    }

    private struct RetainedFixture {
        let owner: Harness
        let peer: Harness
        let sessionID: UUID
    }

    private func makeHarness(
        windowID: Int,
        workspace existingWorkspace: WorkspaceModel? = nil,
        storageURL existingStorageURL: URL? = nil
    ) async throws -> Harness {
        let storageURL: URL
        if let existingStorageURL {
            storageURL = existingStorageURL
        } else {
            storageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentStaleResetOwnershipTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
        let workspace = existingWorkspace ?? WorkspaceModel(
            name: "Agent Stale Reset Ownership",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        return Harness(
            viewModel: viewModel,
            workspace: workspace,
            storageURL: storageURL,
            tabID: tabID,
            session: session
        )
    }

    /// Owner with persisted history; a peer commits a reset; the owner's next save is rejected
    /// and the recovery settles into `.retained` (no active run in this fixture).
    private func makeRetainedFixture(ownerWindowID: Int, peerWindowID: Int) async throws -> RetainedFixture {
        let owner = try await makeHarness(windowID: ownerWindowID)
        owner.session.appendItem(.user("Pre-reset prompt"))
        owner.session.appendItem(.assistant("Pre-reset answer"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        let peer = try await makeHarness(windowID: peerWindowID, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        XCTAssertNotNil(owner.session.staleResetRecovery)
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        return RetainedFixture(owner: owner, peer: peer, sessionID: sessionID)
    }

    private func makeManagedAttachmentFile(in workspaceDirectory: URL, name: String) throws -> URL {
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let fileURL = storageRoot.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        return fileURL
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw StaleResetWaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct StaleResetWaitTimeout: Error {}

/// Holds an asynchronous boundary (owned terminal-resource teardown) until the test releases it.
@MainActor
private final class StaleResetGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    func waitForRelease() async {
        if released { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DiscardRequestRecorder {
    var requests: [AgentModeViewModel.AgentStaleResetDiscardRequest] = []
}
