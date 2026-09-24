import Foundation
@testable import RepoPromptApp
import XCTest

/// Runtime/UI integration contract for Agent Mode scheduled sends (plan §3.3, P1):
/// the record is frozen and saved before any item exists, the `.dispatching` attempt is
/// durable before the optimistic bubble is appended, acceptance commits item + marker + receipt
/// + schedule removal atomically (readable on an immediate reload), failures keep the attempt's
/// item id for re-drive, restart with a `.dispatching` record needs confirmation unless the
/// attempt is live in this process, busy bookkeeping clearing re-triggers dispatch without a
/// manual evaluate, and attachments are never cleared early.
@MainActor
final class AgentScheduledSendDispatchTests: XCTestCase {
    // MARK: - Freeze + persistence

    func testInstallFreezesComposerStateSavesRecordAndKeepsAttachmentFilesUntilCancel() async throws {
        let harness = try await makeHarness(windowID: 4301)
        let attachmentURL = try makeManagedAttachmentFile(in: harness.storageURL, name: "frozen.png")
        let attachment = AgentImageAttachment(source: .localFile(path: attachmentURL.path))
        harness.session.pendingImageAttachments = [attachment]
        harness.session.pendingTaggedFileAttachments = [
            AgentTaggedFileAttachment(relativePath: "README.md", displayName: "README.md")
        ]
        harness.viewModel.interviewFirst = true
        let notBefore = Date().addingTimeInterval(900)

        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Summarize the diff",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: true,
            isNewSessionStart: true
        ).get()

        XCTAssertTrue(harness.session.items.isEmpty, "No bubble may exist before dispatch")
        XCTAssertTrue(harness.session.pendingImageAttachments.isEmpty)
        XCTAssertTrue(harness.session.pendingTaggedFileAttachments.isEmpty)
        XCTAssertFalse(harness.viewModel.interviewFirst, "Interview-first is consumed into the record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertEqual(harness.session.scheduledSendWorkspaceID, harness.workspace.id, "Persistence target is pinned")

        let persisted = try await harness.persistedSession()
        let record = try XCTUnwrap(persisted.scheduledSend?.persistedValue)
        XCTAssertEqual(record.id, scheduleID)
        XCTAssertEqual(record.state, .scheduled)
        XCTAssertEqual(record.rawText, "Summarize the diff")
        XCTAssertEqual(record.attachments, [attachment])
        XCTAssertEqual(record.taggedFileAttachments.map(\.relativePath), ["README.md"])
        XCTAssertTrue(record.interviewFirst)
        XCTAssertTrue(record.isNewSessionStart)
        XCTAssertTrue(record.runAlongsideOtherSessions)
        XCTAssertEqual(harness.session.scheduledSendPersistedUpdatedAt, record.updatedAt)

        let duplicate = await harness.viewModel.installScheduledSend(
            text: "second",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        )
        guard case .failure = duplicate else {
            return XCTFail("One pending scheduled message per session")
        }

        let cancelMessage = await harness.viewModel.cancelScheduledSend(
            tabID: harness.tabID,
            scheduleID: scheduleID
        )
        XCTAssertNil(cancelMessage)
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path), "Cancel releases the record's files")
        let afterCancel = try await harness.persistedSession()
        XCTAssertNil(afterCancel.scheduledSend)
        XCTAssertNil(afterCancel.lastScheduledDispatch)
    }

    // MARK: - Composer entry point (both routes)

    func testComposerScheduleOnLinkedUntouchedSessionIsNewSessionStartAndClearsDraft() async throws {
        let harness = try await makeHarness(windowID: 4310)
        XCTAssertNotNil(harness.viewModel.ensureSessionBoundToTab(harness.session))
        XCTAssertTrue(
            harness.viewModel.scheduleTargetIsNewSessionStart(tabID: harness.tabID, session: harness.session),
            "A linked tab that never carried a turn schedules a workspace-gated new-session start"
        )
        harness.viewModel.storeDraftText(for: harness.tabID, "Plan the migration")
        let claim = try claimComposer(harness, draft: "Plan the migration")
        XCTAssertEqual(claim.attempt.target.route, .existingAgentSession)
        let notBefore = Date().addingTimeInterval(1800)

        let result = await harness.viewModel.executeComposerScheduleAttempt(
            text: "Plan the migration",
            notBefore: notBefore,
            runAlongsideOtherSessions: true,
            claim: claim
        )

        guard case let .scheduled(scheduleID) = result else {
            return XCTFail("Expected .scheduled, got \(result)")
        }
        let record = try XCTUnwrap(harness.session.pendingScheduledSendRecord)
        XCTAssertEqual(record.id, scheduleID)
        XCTAssertTrue(record.isNewSessionStart)
        XCTAssertTrue(record.runAlongsideOtherSessions)
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "", "Draft clears only after the durable commit")
        XCTAssertFalse(harness.session.isComposerSubmissionInFlight, "The claim is released")
        XCTAssertFalse(
            harness.viewModel.canScheduleSend(tabID: harness.tabID, session: harness.session),
            "One pending record per session"
        )
        let persisted = try await harness.persistedSession()
        XCTAssertEqual(persisted.scheduledSend?.persistedValue?.id, scheduleID)

        harness.session.appendItem(.user("already sent"))
        XCTAssertFalse(
            harness.viewModel.scheduleTargetIsNewSessionStart(tabID: harness.tabID, session: harness.session),
            "A session with a turn schedules a follow-up"
        )
    }

    func testComposerScheduleCreateRouteRollsBackOnPersistenceFailureAndMovesStateOnSuccess() async throws {
        let harness = try await makeHarness(windowID: 4311)
        let attachmentURL = try makeManagedAttachmentFile(in: harness.storageURL, name: "source.png")
        let attachment = AgentImageAttachment(source: .localFile(path: attachmentURL.path))
        harness.session.pendingImageAttachments = [attachment]
        harness.viewModel.storeDraftText(for: harness.tabID, "First prompt")
        XCTAssertNil(harness.session.activeAgentSessionID, "Source tab is unlinked")

        let probe = DispatchProbe()
        let createDestination: @MainActor () async -> UUID? = { [harness, probe] in
            let destinationTabID = UUID()
            _ = try! await harness.viewModel.ensureSessionReady(tabID: destinationTabID)
            probe.createdTabIDs.append(destinationTabID)
            return destinationTabID
        }

        // Failure: the persistence target is unwritable, so the durable create cannot succeed.
        let brokenFile = harness.storageURL.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: brokenFile)
        harness.viewModel.test_persistenceWorkspaceOverride = WorkspaceModel(
            name: "Broken",
            repoPaths: [harness.storageURL.path],
            customStoragePath: brokenFile
        )
        let failingClaim = try claimComposer(harness, draft: "First prompt")
        XCTAssertEqual(failingClaim.attempt.target.route, .createAgentSessionFromSourceTab)
        let failed = await harness.viewModel.executeComposerScheduleAttempt(
            text: "First prompt",
            notBefore: Date().addingTimeInterval(1800),
            runAlongsideOtherSessions: false,
            claim: failingClaim,
            createAndActivateSessionTab: createDestination
        )
        guard case .blocked = failed else {
            return XCTFail("Expected .blocked, got \(failed)")
        }
        XCTAssertEqual(probe.createdTabIDs.count, 1)
        XCTAssertNil(harness.viewModel.sessions[probe.createdTabIDs[0]], "The fresh destination is discarded")
        XCTAssertEqual(harness.session.pendingImageAttachments, [attachment], "Source pending state survives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path), "Rollback never deletes files")
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "First prompt", "Draft survives")
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertFalse(harness.session.isComposerSubmissionInFlight)

        // Success: the destination owns the frozen state; the source keeps no schedule.
        harness.viewModel.test_persistenceWorkspaceOverride = harness.workspace
        let claim = try claimComposer(harness, draft: "First prompt")
        let result = await harness.viewModel.executeComposerScheduleAttempt(
            text: "First prompt",
            notBefore: Date().addingTimeInterval(1800),
            runAlongsideOtherSessions: false,
            claim: claim,
            createAndActivateSessionTab: createDestination
        )
        guard case let .scheduled(scheduleID) = result else {
            return XCTFail("Expected .scheduled, got \(result)")
        }
        let destinationTabID = try XCTUnwrap(probe.createdTabIDs.last)
        let destination = try XCTUnwrap(harness.viewModel.sessions[destinationTabID])
        let record = try XCTUnwrap(destination.pendingScheduledSendRecord)
        XCTAssertEqual(record.id, scheduleID)
        XCTAssertTrue(record.isNewSessionStart)
        XCTAssertEqual(record.attachments, [attachment])
        XCTAssertEqual(record.rawText, "First prompt")
        XCTAssertNil(harness.session.scheduledSend, "The source tab never carries the destination's schedule")
        XCTAssertTrue(harness.session.pendingImageAttachments.isEmpty, "Pending state moved, not copied")
        XCTAssertTrue(destination.pendingImageAttachments.isEmpty)
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
        let sessionID = try XCTUnwrap(destination.activeAgentSessionID)
        let loaded = try await harness.viewModel.test_dataService.loadAgentSession(id: sessionID, for: harness.workspace)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.scheduledSend?.persistedValue?.id, scheduleID)
    }

    // MARK: - Dispatch acceptance

    func testDispatchPersistsAttemptBeforeAppendAndFinalizesItemReceiptAndClearAtomically() async throws {
        let harness = try await makeHarness(windowID: 4302)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(120)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Run the tests",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] tabID, providerText, _, _ in
            probe.dispatchedTabID = tabID
            probe.providerText = providerText
            probe.diskStateAtHandoff = await (try? harness.persistedSession())?.scheduledSend?.persistedValue?.state
            probe.userItemsAtHandoff = harness.session.items.filter { $0.kind == .user }
            return .sent
        }

        XCTAssertTrue(harness.session.items.isEmpty)
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("provider acceptance recorded") {
            harness.session.lastScheduledDispatch != nil && harness.session.scheduledSendPendingFinalization == nil
        }

        XCTAssertEqual(probe.dispatchedTabID, harness.tabID)
        XCTAssertEqual(probe.providerText, "Run the tests")
        XCTAssertEqual(probe.diskStateAtHandoff, .dispatching, "The attempt must be durable before handoff")
        XCTAssertEqual(probe.userItemsAtHandoff.count, 1)
        XCTAssertNil(probe.userItemsAtHandoff.first?.scheduledSend, "No Sent marker before acceptance")

        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertEqual(receipt.scheduleID, scheduleID)
        XCTAssertEqual(receipt.scheduledFor, notBefore)
        let stamped = try XCTUnwrap(harness.session.items.first { $0.kind == .user })
        XCTAssertEqual(stamped.id, probe.userItemsAtHandoff.first?.id)
        XCTAssertEqual(stamped.scheduledSend, receipt)
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertNil(harness.session.scheduledSendWorkspaceID)

        // Immediate reload (before any debounced save could fire): item, marker, receipt, clear.
        let persisted = try await harness.persistedSession()
        XCTAssertNil(persisted.scheduledSend)
        XCTAssertEqual(persisted.lastScheduledDispatch, receipt)
        let persistedRequest = try XCTUnwrap(
            persisted.transcript?.turns.compactMap(\.request).first { $0.id == stamped.id },
            "The accepted user item must be durable together with the receipt"
        )
        XCTAssertEqual(persistedRequest.scheduledSend, receipt)
        XCTAssertEqual(persistedRequest.text, "Run the tests")
    }

    func testFailedOutcomeKeepsItemIDWithoutSentMarkerAndSendNowRedrivesSameItem() async throws {
        let harness = try await makeHarness(windowID: 4303)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Deploy",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            probe.userItemsAtHandoff = harness.session.items.filter { $0.kind == .user }
            return .failed(message: "provider exploded")
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("failed state recorded") {
            harness.session.pendingScheduledSendRecord?.state == .failed
        }

        let failedRecord = try XCTUnwrap(harness.session.pendingScheduledSendRecord)
        let firstItemID = try XCTUnwrap(probe.userItemsAtHandoff.first?.id)
        XCTAssertEqual(failedRecord.attempt?.itemID, firstItemID, "Failed records keep the item id for re-drive")
        XCTAssertEqual(failedRecord.lastFailureMessage, "provider exploded")
        XCTAssertFalse(harness.session.items.contains { $0.scheduledSend != nil }, "Never labelled Sent")
        XCTAssertFalse(harness.session.items.contains { $0.id == firstItemID }, "Unsent bubble is removed")
        XCTAssertNil(harness.session.lastScheduledDispatch)
        let persistedFailed = try await harness.persistedSession()
        XCTAssertEqual(persistedFailed.scheduledSend?.persistedValue?.state, .failed)

        harness.viewModel.scheduledDispatchRunStarter = { _, _, _, _ in .sent }
        let sendNowMessage = await harness.viewModel.sendScheduledSendNow(
            tabID: harness.tabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: false
        )
        XCTAssertNil(sendNowMessage)
        try await waitUntil("re-drive accepted") {
            harness.session.lastScheduledDispatch != nil
        }

        let stamped = try XCTUnwrap(harness.session.items.first { $0.scheduledSend != nil })
        XCTAssertEqual(stamped.id, firstItemID, "Re-drive reuses the attempt's item id instead of a second bubble")
        XCTAssertEqual(harness.session.items.count(where: { $0.kind == .user }), 1)
        XCTAssertEqual(stamped.scheduledSend?.scheduledFor, notBefore, "Send now keeps the original scheduled time")
        XCTAssertNil(harness.session.scheduledSend)
    }

    func testFailedRecordRescheduledThroughBannerDispatchesAtTheNewDeadline() async throws {
        let harness = try await makeHarness(windowID: 4307)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Retry me",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return probe.startCount == 1 ? .failed(message: "first attempt failed") : .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("first attempt failed") {
            harness.session.pendingScheduledSendRecord?.state == .failed
        }
        let failedAttemptItemID = try XCTUnwrap(harness.session.pendingScheduledSendRecord?.attempt?.itemID)

        // Reschedule (not Send now): the record must re-arm for the new deadline.
        let newDeadline = clock.now.addingTimeInterval(300)
        let updateMessage = await harness.viewModel.updateScheduledSend(
            tabID: harness.tabID,
            scheduleID: scheduleID,
            text: "Retry me",
            notBefore: newDeadline,
            runAlongsideOtherSessions: false
        )
        XCTAssertNil(updateMessage)
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .scheduled)
        clock.advance(to: newDeadline.addingTimeInterval(-1))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probe.startCount, 1, "Nothing runs before the new deadline")

        clock.advance(to: newDeadline.addingTimeInterval(1))
        try await waitUntil("rescheduled attempt accepted") {
            harness.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 2)
        let stamped = try XCTUnwrap(harness.session.items.first { $0.scheduledSend != nil })
        XCTAssertEqual(stamped.id, failedAttemptItemID, "The re-armed attempt reuses the failed attempt's item id")
        XCTAssertEqual(stamped.scheduledSend?.scheduledFor, newDeadline)
    }

    func testRunBookkeepingClearingAfterTerminalStateTriggersDispatchWithoutManualEvaluate() async throws {
        let harness = try await makeHarness(windowID: 4304)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Follow up",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        // Production start ordering: run bookkeeping first, then the running state.
        let runID = UUID()
        harness.session.runID = runID
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: true)
        harness.session.runState = .running

        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("deferral observed") {
            harness.session.pendingScheduledSendRecord?.firstEligibleAt != nil
        }
        XCTAssertEqual(probe.startCount, 0)
        XCTAssertTrue(harness.session.items.isEmpty, "A busy session never receives the scheduled turn as steering")

        // Production terminal ordering (AgentRunTerminalCommitBarrier): the terminal state
        // publishes while the tab is still in `tabsWithActiveAgentRun`, then bookkeeping clears
        // and `runID` is dropped. Only the bookkeeping change may release the follow-up.
        harness.session.runState = .completed
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probe.startCount, 0, "Settling run bookkeeping still counts as busy")
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: false)
        harness.session.runID = nil

        try await waitUntil("dispatch after bookkeeping cleared") {
            harness.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertEqual(harness.session.items.count(where: { $0.kind == .user }), 1)
    }

    // MARK: - Multi-window live attempt

    func testHydratingAnotherWindowDuringLiveDispatchProjectsAttemptAndOwnerStillFinalizes() async throws {
        let owner = try await makeHarness(windowID: 4308)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Shared session",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let gate = DispatchGate()
        owner.viewModel.scheduledDispatchRunStarter = { [gate] _, _, _, _ in
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("owner handed off to the provider") {
            gate.isWaiting
        }
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID))
        let diskDuringDispatch = try await owner.persistedSession()
        let dispatchingRecord = try XCTUnwrap(diskDuringDispatch.scheduledSend?.persistedValue)
        XCTAssertEqual(dispatchingRecord.state, .dispatching)

        // A second window in the same process hydrates the same session mid-dispatch.
        let other = try await makeHarness(windowID: 4309, workspace: owner.workspace, storageURL: owner.storageURL)
        other.viewModel.attachScheduledSendCoordinator(coordinator)
        let otherSession = AgentModeViewModel.TabSession(tabID: UUID())
        other.viewModel.installHydratedScheduledSend(from: diskDuringDispatch, into: otherSession)
        XCTAssertEqual(
            otherSession.pendingScheduledSendRecord?.state,
            .dispatching,
            "A live attempt owned by this process is projected, not normalized"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        let diskAfterHydration = try await owner.persistedSession()
        XCTAssertEqual(diskAfterHydration.scheduledSend?.persistedValue, dispatchingRecord, "Hydration must not rewrite the live attempt")

        gate.release()
        try await waitUntil("owner finalized") {
            owner.session.lastScheduledDispatch != nil && owner.session.scheduledSendPendingFinalization == nil
        }
        let receipt = try XCTUnwrap(owner.session.lastScheduledDispatch)
        let finalized = try await owner.persistedSession()
        XCTAssertNil(finalized.scheduledSend)
        XCTAssertEqual(finalized.lastScheduledDispatch, receipt)
        XCTAssertTrue(
            finalized.transcript?.turns.contains { $0.request?.scheduledSend == receipt } == true,
            "Provenance is committed despite the concurrent hydration"
        )
    }

    // MARK: - Restart normalization

    func testHydratingDispatchingRecordNeedsConfirmationAndDroppedWhenAlreadyDelivered() async throws {
        let harness = try await makeHarness(windowID: 4305)
        let itemID = UUID()
        var dispatching = makeRecord(notBefore: Date().addingTimeInterval(-60))
        dispatching.state = .dispatching
        dispatching.attempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: itemID, startedAt: Date())
        let persisted = AgentSession(id: UUID(), name: "Restart", scheduledSend: .v1(dispatching))

        let sessionWithItem = AgentModeViewModel.TabSession(tabID: UUID())
        sessionWithItem.appendItem(.user("maybe sent", id: itemID))
        harness.viewModel.installHydratedScheduledSend(from: persisted, into: sessionWithItem)
        let withItem = try XCTUnwrap(sessionWithItem.pendingScheduledSendRecord)
        XCTAssertEqual(withItem.state, .needsConfirmation)
        XCTAssertEqual(withItem.confirmationReason, .deliveryUnknown)
        XCTAssertEqual(withItem.attempt?.itemID, itemID)
        XCTAssertTrue(withItem.lastFailureMessage?.contains("twice") == true, "Duplicate-execution warning when the item exists")
        XCTAssertNil(sessionWithItem.items.first?.scheduledSend, "Restart never invents a Sent marker")
        let props = AgentScheduledSendProps(tabID: sessionWithItem.tabID, scheduledSend: withItem)
        XCTAssertEqual(props.status, .needsConfirmation(.deliveryUnknown))
        XCTAssertEqual(props.recoveryMessage, withItem.lastFailureMessage, "The banner receives the duplicate warning")

        let sessionWithoutItem = AgentModeViewModel.TabSession(tabID: UUID())
        harness.viewModel.installHydratedScheduledSend(from: persisted, into: sessionWithoutItem)
        let withoutItem = try XCTUnwrap(sessionWithoutItem.pendingScheduledSendRecord)
        XCTAssertEqual(withoutItem.state, .needsConfirmation)
        XCTAssertEqual(withoutItem.confirmationReason, .deliveryUnknown)
        XCTAssertFalse(withoutItem.lastFailureMessage?.contains("twice") == true)

        let scheduled = makeRecord(notBefore: Date().addingTimeInterval(600))
        let provenance = AgentScheduledSendProvenance(
            scheduleID: scheduled.id,
            attemptID: UUID(),
            scheduledFor: scheduled.notBefore,
            sentAt: Date()
        )
        let delivered = AgentSession(
            id: UUID(),
            name: "Delivered",
            scheduledSend: .v1(scheduled),
            lastScheduledDispatch: provenance
        )
        let deliveredSession = AgentModeViewModel.TabSession(tabID: UUID())
        harness.viewModel.installHydratedScheduledSend(from: delivered, into: deliveredSession)
        XCTAssertNil(deliveredSession.scheduledSend, "A record already recorded as provenance is dropped")
        XCTAssertEqual(deliveredSession.lastScheduledDispatch, provenance)

        let intact = AgentSession(id: UUID(), name: "Intact", scheduledSend: .v1(scheduled))
        let intactSession = AgentModeViewModel.TabSession(tabID: UUID())
        harness.viewModel.installHydratedScheduledSend(from: intact, into: intactSession)
        XCTAssertEqual(intactSession.pendingScheduledSendRecord, scheduled)
        XCTAssertEqual(intactSession.scheduledSendPersistedUpdatedAt, scheduled.updatedAt)
    }

    func testUnreadableScheduledSendIsProjectedAndCanBeDiscarded() async throws {
        let harness = try await makeHarness(windowID: 4312)
        let sessionID = try XCTUnwrap(harness.viewModel.ensureSessionBoundToTab(harness.session))
        let unreadableJSON = AgentScheduledSendJSONValue.object([
            "schemaVersion": .number(2),
            "rawText": .number(7)
        ])
        let persisted = AgentSession(
            id: sessionID,
            workspaceID: harness.workspace.id,
            composeTabID: harness.tabID,
            name: "Unreadable",
            scheduledSend: .unreadable(unreadableJSON)
        )
        _ = try await harness.viewModel.test_dataService.saveAgentSession(
            persisted,
            for: harness.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        // Real hydration adopts the unreadable member and the paired persistence state.
        _ = await harness.viewModel.test_hydrateBoundSession(tabID: harness.tabID)
        XCTAssertEqual(harness.session.scheduledSend, .unreadable(unreadableJSON))
        XCTAssertNotNil(harness.session.persistenceState(for: sessionID))
        XCTAssertFalse(harness.viewModel.canScheduleSend(tabID: harness.tabID, session: harness.session))
        XCTAssertTrue(harness.viewModel.scheduledSendCandidates().isEmpty, "Unreadable members are never dispatched")
        let props = AgentScheduledSendProps.unreadable(tabID: harness.tabID)
        XCTAssertEqual(props.status, .unreadable)
        XCTAssertNotNil(props.recoveryMessage)

        let message = await harness.viewModel.discardUnreadableScheduledSend(tabID: harness.tabID)
        XCTAssertNil(message)
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertTrue(harness.viewModel.canScheduleSend(tabID: harness.tabID, session: harness.session))
        let reloaded = try await harness.persistedSession()
        XCTAssertNil(reloaded.scheduledSend)
    }

    func testCandidatesExcludeLiveAttemptsAndBusyStateReflectsQueuedInstructionsAndMCPControl() async throws {
        let harness = try await makeHarness(windowID: 4306)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Candidate",
            on: harness.session,
            notBefore: Date().addingTimeInterval(300),
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let candidates = harness.viewModel.scheduledSendCandidates()
        XCTAssertEqual(candidates.map(\.tabID), [harness.tabID])
        XCTAssertEqual(candidates.first?.sessionID, harness.session.activeAgentSessionID)
        XCTAssertEqual(candidates.first?.isHydrated, true)
        XCTAssertEqual(candidates.first?.workspaceID, harness.workspace.id)

        harness.session.isScheduledDispatchInFlight = true
        XCTAssertTrue(
            harness.viewModel.scheduledSendCandidates().isEmpty,
            "An in-process dispatch must not be re-evaluated as a stale .dispatching record"
        )
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).hasStartOrDispatchReservation)
        harness.session.isScheduledDispatchInFlight = false

        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).isBusy)
        harness.session.pendingInstructions = ["queued follow-up"]
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).hasPendingInstructions)
        harness.session.pendingInstructions = []
        harness.session.runState = .waitingForUser
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).isBusy)
        harness.session.runState = .idle

        harness.viewModel.setAgentRunActive(harness.tabID, isActive: true)
        XCTAssertTrue(
            harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).cancellationIsSettling,
            "Terminal state with live run bookkeeping is a settling run"
        )
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: false)
        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: harness.tabID).isBusy)
    }

    // MARK: - Accepted-attempt durability and ownership (R2)

    func testAcceptanceFinalizesFromImmutableSnapshotWhenWorkingItemWasRemovedDuringProviderAwait() async throws {
        let harness = try await makeHarness(windowID: 4320)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Snapshot me",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let gate = DispatchGate()
        harness.viewModel.scheduledDispatchRunStarter = { [gate] _, _, _, _ in
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("provider handoff held") { gate.isWaiting }
        let diskDuringDispatch = try await harness.persistedSession()
        let attemptItemID = try XCTUnwrap(diskDuringDispatch.scheduledSend?.persistedValue?.attempt?.itemID)
        XCTAssertTrue(harness.session.items.contains { $0.id == attemptItemID })

        // The working set loses the bubble while the provider is still being awaited.
        harness.session.replaceItems([])
        XCTAssertTrue(harness.session.items.isEmpty)

        gate.release()
        try await waitUntil("acceptance finalized from the snapshot") {
            harness.session.lastScheduledDispatch != nil && harness.session.scheduledSendPendingFinalization == nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        let persisted = try await harness.persistedSession()
        XCTAssertNil(persisted.scheduledSend, "The schedule is retired only together with the accepted item")
        XCTAssertEqual(persisted.lastScheduledDispatch, receipt)
        let request = try XCTUnwrap(
            persisted.transcript?.turns.compactMap(\.request).first { $0.id == attemptItemID },
            "The accepted request payload must be durable even though the working set dropped it"
        )
        XCTAssertEqual(request.scheduledSend, receipt)
        XCTAssertEqual(request.text, "Snapshot me")
    }

    func testSameAttemptAtNewerRevisionOnDiskStillFinalizesAndClearsSchedule() async throws {
        let harness = try await makeHarness(windowID: 4321)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Revision race",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let gate = DispatchGate()
        harness.viewModel.scheduledDispatchRunStarter = { [gate] _, _, _, _ in
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("provider handoff held") { gate.isWaiting }
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let diskDuringDispatch = try await harness.persistedSession()
        let dispatching = try XCTUnwrap(diskDuringDispatch.scheduledSend?.persistedValue)
        XCTAssertEqual(dispatching.state, .dispatching)

        // Another writer bumps the same attempt to a newer revision (bookkeeping only).
        var bumped = dispatching
        bumped.firstEligibleAt = Date()
        bumped.updatedAt = Date().addingTimeInterval(1)
        _ = try await harness.viewModel.test_dataService.mutateScheduledSend(
            sessionID: sessionID,
            for: harness.workspace,
            mutation: .upsert(expectedUpdatedAt: dispatching.updatedAt, value: bumped)
        )

        gate.release()
        try await waitUntil("finalization reconciled the newer revision") {
            harness.session.lastScheduledDispatch != nil && harness.session.scheduledSendPendingFinalization == nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        XCTAssertEqual(receipt.attemptID, dispatching.attempt?.attemptID)
        let persisted = try await harness.persistedSession()
        XCTAssertNil(persisted.scheduledSend, "The same attempt at a newer revision is retired, not preserved")
        XCTAssertEqual(persisted.lastScheduledDispatch, receipt)
        let request = try XCTUnwrap(
            persisted.transcript?.turns.compactMap(\.request).first { $0.id == dispatching.attempt?.itemID }
        )
        XCTAssertEqual(request.scheduledSend, receipt)
    }

    func testTwoParticipatingHostsCannotResubmitWhileOwnerFinalizationIsPending() async throws {
        let owner = try await makeHarness(windowID: 4322)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await owner.viewModel.installScheduledSend(
            text: "Exactly once",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sharedSessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        let ownerProbe = DispatchProbe()
        let gate = DispatchGate()
        owner.viewModel.scheduledDispatchRunStarter = { [gate, ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("owner handed off to the provider") { gate.isWaiting }
        let diskDuringDispatch = try await owner.persistedSession()
        XCTAssertEqual(diskDuringDispatch.scheduledSend?.persistedValue?.state, .dispatching)

        // Second host: registered with the same coordinator, its tab bound to the same durable
        // session and hydrated with the live `.dispatching` projection.
        let other = try await makeHarness(windowID: 4323, workspace: owner.workspace, storageURL: owner.storageURL)
        other.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(
            other.viewModel.test_installPersistentSessionBinding(sessionID: sharedSessionID, on: other.session)
        )
        // Real hydration: transcript, schedule projection, and persistence state adopted as one pair.
        _ = await other.viewModel.test_hydrateBoundSession(tabID: other.tabID)
        XCTAssertEqual(other.session.activeAgentSessionID, sharedSessionID)
        XCTAssertNotNil(other.session.persistenceState(for: sharedSessionID), "Hydration pairs the editable state with the transcript")
        XCTAssertEqual(other.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertTrue(other.viewModel.ownsScheduledSendDestination(tabID: other.tabID, sessionID: sharedSessionID))
        let otherProbe = DispatchProbe()
        other.viewModel.scheduledDispatchRunStarter = { [otherProbe] _, _, _, _ in
            otherProbe.startCount += 1
            return .sent
        }

        // The process worker's durable commit fails after provider acceptance (injected).
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await owner.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        gate.release()
        try await waitUntil("owner accepted; process worker parked for retry") {
            owner.session.scheduledSendPendingFinalization != nil
                && !owner.session.isScheduledDispatchInFlight
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sharedSessionID)?.phase)
        }
        XCTAssertEqual(ownerProbe.startCount, 1)
        XCTAssertNotNil(
            coordinator.activeAdmission(sessionID: sharedSessionID),
            "Accepted-but-unfinalized attempts keep process-wide ownership"
        )
        XCTAssertEqual(
            owner.session.scheduledSendPendingFinalization?.key,
            coordinator.recoveryStatus(sessionID: sharedSessionID)?.key,
            "The owner projects the coordinator's retained attempt"
        )

        // The second host must not be able to re-drive or normalize the live attempt.
        let sendNowMessage = await other.viewModel.sendScheduledSendNow(
            tabID: other.tabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: false
        )
        XCTAssertNotNil(sendNowMessage, "Send now is refused while the attempt is live")
        coordinator.recordDidChange()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(otherProbe.startCount, 0, "No second provider submission")
        XCTAssertEqual(ownerProbe.startCount, 1)
        XCTAssertEqual(other.session.pendingScheduledSendRecord?.state, .dispatching, "No normalization of the live attempt")
        let diskWhilePending = try await other.persistedSession()
        XCTAssertEqual(diskWhilePending.scheduledSend?.persistedValue?.state, .dispatching)

        // Persistence recovers: the process worker's next bounded retry finalizes; ownership is
        // released exactly; both hosts adopt the committed file.
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("owner finalized after recovery") {
            owner.session.scheduledSendPendingFinalization == nil && owner.session.lastScheduledDispatch != nil
        }
        let receipt = try XCTUnwrap(owner.session.lastScheduledDispatch)
        let finalized = try await owner.persistedSession()
        XCTAssertNil(finalized.scheduledSend)
        XCTAssertEqual(finalized.lastScheduledDispatch, receipt)
        XCTAssertNil(coordinator.activeAdmission(sessionID: sharedSessionID), "Ownership released exactly on completion")
        try await waitUntil("peer resynced from the committed finalization") {
            other.session.scheduledSend == nil && other.session.lastScheduledDispatch == receipt
        }
        XCTAssertEqual(ownerProbe.startCount + otherProbe.startCount, 1)
    }

    func testSendNowWhileBusyDispatchesExactlyOnceWhenBlockerClears() async throws {
        let harness = try await makeHarness(windowID: 4324)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(3600)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Send now while busy",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }

        let runID = UUID()
        harness.session.runID = runID
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: true)
        harness.session.runState = .running

        let sendNowMessage = await harness.viewModel.sendScheduledSendNow(
            tabID: harness.tabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: false
        )
        XCTAssertNil(sendNowMessage)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(probe.startCount, 0, "Send now waits on the busy gate")
        XCTAssertTrue(harness.session.items.isEmpty)

        harness.session.runState = .completed
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: false)
        harness.session.runID = nil
        try await waitUntil("confirmed send dispatched once the blocker cleared") {
            harness.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 1, "Exactly one dispatch; the confirmation survives busy deferral")
        XCTAssertEqual(harness.session.lastScheduledDispatch?.scheduledFor, notBefore, "Send now keeps the original time")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.startCount, 1)
    }

    func testProviderAcceptanceIsDerivedFromRunStateForNonCodexRunners() {
        typealias Accept = AgentModeViewModel
        XCTAssertTrue(Accept.scheduledProviderAccepted(outcome: .sent, agent: .codexExec, runState: .idle))
        XCTAssertTrue(
            Accept.scheduledProviderAccepted(
                outcome: .queuedFallback(queueID: UUID(), reason: .activeWithoutAuthoritativeIdentity),
                agent: .codexExec,
                runState: .idle
            ),
            "A provider-durable Codex fallback queue entry counts as acceptance"
        )
        XCTAssertFalse(Accept.scheduledProviderAccepted(outcome: .failed(message: "x"), agent: .codexExec, runState: .running))
        XCTAssertFalse(Accept.scheduledProviderAccepted(outcome: nil, agent: .codexExec, runState: .running), "Codex never reports acceptance through run state alone")
        // Non-Codex runners return nil after launching; a pre-startup failure commits `.failed` first.
        XCTAssertTrue(Accept.scheduledProviderAccepted(outcome: nil, agent: .claudeCode, runState: .running))
        XCTAssertTrue(Accept.scheduledProviderAccepted(outcome: nil, agent: .openCode, runState: .completed))
        XCTAssertFalse(Accept.scheduledProviderAccepted(outcome: nil, agent: .claudeCode, runState: .failed))
        XCTAssertFalse(Accept.scheduledProviderAccepted(outcome: nil, agent: .claudeCode, runState: .idle))
        XCTAssertFalse(
            Accept.scheduledProviderAccepted(
                outcome: .stale(reason: AgentModeRunService.providerHandoffRevokedReason),
                agent: .claudeCode,
                runState: .idle
            ),
            "A revoked handoff is never acceptance"
        )
    }

    func testExplicitResetPassesFinalizedMarkersToTheNextSave() async throws {
        let harness = try await makeHarness(windowID: 4325)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Reset me later",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        harness.viewModel.scheduledDispatchRunStarter = { _, _, _, _ in .sent }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("accepted") {
            harness.session.lastScheduledDispatch != nil && harness.session.scheduledSendPendingFinalization == nil
        }
        let receipt = try XCTUnwrap(harness.session.lastScheduledDispatch)
        let stamped = try XCTUnwrap(harness.session.items.first { $0.scheduledSend == receipt })
        let savedBeforeReset = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(savedBeforeReset)
        let beforeReset = try await harness.persistedSession()
        XCTAssertTrue(beforeReset.transcript?.turns.contains { $0.request?.id == stamped.id } == true)

        harness.viewModel.clearChat(tabID: harness.tabID)
        XCTAssertEqual(
            harness.session.pendingFinalizedScheduledSendItemRemovals,
            [AgentScheduledSendFinalizedItemRemoval(itemID: stamped.id, receipt: receipt)],
            "An explicit reset captures the exact finalized marker it removes"
        )
        let savedAfterReset = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(savedAfterReset)
        XCTAssertTrue(harness.session.pendingFinalizedScheduledSendItemRemovals.isEmpty, "Removals are consumed by the save that carried them")
        let afterReset = try await harness.persistedSession()
        XCTAssertFalse(
            afterReset.transcript?.turns.contains { $0.request?.id == stamped.id } == true,
            "An intentionally removed finalized item is not resurrected by protection"
        )
        XCTAssertEqual(afterReset.lastScheduledDispatch, receipt, "The receipt remains the durable record of delivery")
    }

    // MARK: - Final gate policy, consent rollback, accepted recovery (R3)

    func testFollowUpDispatchesWhileAnotherTabRunsWithoutRevertLoop() async throws {
        let harness = try await makeHarness(windowID: 4330)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)

        // An unrelated tab in the same workspace is running.
        let otherTabID = UUID()
        let otherSession = try await harness.viewModel.ensureSessionReady(tabID: otherTabID)
        XCTAssertNotNil(harness.viewModel.ensureSessionBoundToTab(otherSession))
        otherSession.runID = UUID()
        harness.viewModel.setAgentRunActive(otherTabID, isActive: true)
        otherSession.runState = .running
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: otherTabID).isBusy)

        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Follow up while another tab runs",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }

        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("follow-up accepted while the other tab is busy") {
            harness.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 1, "A follow-up waits only on its own session; no revert/re-admit loop")
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: otherTabID).isBusy, "The unrelated run was never a blocker")
        XCTAssertNil(harness.session.scheduledSend)
    }

    func testRevokedHandoffKeepsSendNowConsentAndRollsBackPreparation() async throws {
        let harness = try await makeHarness(windowID: 4331)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Consent survives rollback",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()

        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [harness, probe] _, _, _, _ in
            probe.startCount += 1
            switch probe.startCount {
            case 1:
                return .failed(message: "first attempt failed")
            case 2:
                // Run preparation staged the handoff and enqueued a token estimate, then the
                // process-wide gate revoked the handoff before any provider work.
                harness.session.pendingHandoff.isStagedForSend = true
                harness.session.pendingNonCodexUserInputTokenQueue.append(42)
                return .stale(reason: AgentModeRunService.providerHandoffRevokedReason)
            default:
                return .sent
            }
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("first attempt failed") {
            harness.session.pendingScheduledSendRecord?.state == .failed
        }
        let failedItemID = try XCTUnwrap(harness.session.pendingScheduledSendRecord?.attempt?.itemID)

        let sendNowMessage = await harness.viewModel.sendScheduledSendNow(
            tabID: harness.tabID,
            scheduleID: scheduleID,
            runAlongsideOtherSessions: false
        )
        XCTAssertNil(sendNowMessage)
        try await waitUntil("confirmed send accepted after the revoked handoff") {
            harness.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 3, "Revocation defers and the confirmed send is retried exactly once more")
        XCTAssertFalse(harness.session.pendingHandoff.isStagedForSend, "Revoked preparation restores handoff staging")
        XCTAssertTrue(harness.session.pendingNonCodexUserInputTokenQueue.isEmpty, "Revoked preparation dequeues the token estimate")
        let stamped = try XCTUnwrap(harness.session.items.first { $0.scheduledSend != nil })
        XCTAssertEqual(stamped.id, failedItemID)
        XCTAssertEqual(harness.session.items.count(where: { $0.kind == .user }), 1, "The revoked attempt left no bubble behind")
        XCTAssertEqual(harness.session.lastScheduledDispatch?.scheduledFor, notBefore)
        XCTAssertNil(harness.session.scheduledSend)
    }

    func testAcceptedRecoveryCompletesAfterOwnerHostDetaches() async throws {
        let owner = try await makeHarness(windowID: 4332)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Process-owned recovery",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        // Provider accepts; the process worker's durable commit fails (injected) until released.
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await owner.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        let probe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("owner accepted; process worker parked for retry") {
            owner.session.scheduledSendPendingFinalization != nil
                && !owner.session.isScheduledDispatchInFlight
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
        }
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: sessionID)?.hasAcceptedPayload, true)
        XCTAssertEqual(
            coordinator.recoveryStatus(sessionID: sessionID)?.key,
            owner.session.scheduledSendPendingFinalization?.key,
            "UI projection and process ownership name the same attempt"
        )
        let acceptedItemID = try XCTUnwrap(owner.session.scheduledSendPendingFinalization?.attempt.itemID)

        // The owning host goes away entirely (tab close + window detach) before persistence recovers.
        owner.viewModel.releaseScheduledSendForRemovedSession(owner.session, deletesPersistedSession: false)
        owner.viewModel.detachScheduledSendCoordinator()
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID), "Detach never releases duplicate-delivery protection")
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: sessionID)?.hasAcceptedPayload, true, "Detach never drops the payload")

        // The coordinator's own bounded retry finalizes through the pinned destination.
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("process-owned recovery finalized") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(probe.startCount, 1, "Recovery never re-invokes the provider")
        XCTAssertEqual(failureSwitch.callCount, 2, "One failed attempt, one durable commit; no extra writers")
        let loaded = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertNil(persisted.scheduledSend)
        let receipt = try XCTUnwrap(persisted.lastScheduledDispatch)
        XCTAssertEqual(receipt.attemptID, owner.session.scheduledSendPendingFinalization?.attempt.attemptID ?? receipt.attemptID)
        let request = try XCTUnwrap(
            persisted.transcript?.turns.compactMap(\.request).first { $0.id == acceptedItemID },
            "The immutable accepted item is durable without any live view model"
        )
        XCTAssertEqual(request.scheduledSend, receipt)
        XCTAssertEqual(request.text, "Process-owned recovery")
    }

    func testExplicitSessionDeletionDuringRecoverySettlesWithoutRecreatingTheFile() async throws {
        let harness = try await makeHarness(windowID: 4333)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Deleted during recovery",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await harness.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("accepted; process worker parked for retry") {
            harness.session.scheduledSendPendingFinalization != nil
                && !harness.session.isScheduledDispatchInFlight
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
        }
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID))

        // Explicit deletion through the gated data service is authoritative evidence: the retained
        // attempt settles without reconstructing the file.
        try await harness.viewModel.test_dataService.deleteAgentSession(id: sessionID, for: harness.workspace)
        try await waitUntil("recovery settled as explicitly deleted") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID), "Every settlement releases ownership exactly")
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("projection released") {
            harness.session.scheduledSendPendingFinalization == nil
        }
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertEqual(failureSwitch.callCount, 1, "No further persistence attempt after explicit deletion")
        let loaded = try await harness.viewModel.test_dataService.loadAgentSession(id: sessionID, for: harness.workspace)
        XCTAssertNil(loaded, "An explicitly deleted session is never reconstructed by recovery")
    }

    func testAccidentalSessionFileLossDuringRecoveryIsReconstructedFromThePinnedSnapshot() async throws {
        let harness = try await makeHarness(windowID: 4334)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Lost file recovery",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await harness.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("accepted; process worker parked for retry") {
            harness.session.scheduledSendPendingFinalization != nil
                && !harness.session.isScheduledDispatchInFlight
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
        }
        let pending = try XCTUnwrap(harness.session.scheduledSendPendingFinalization)

        // The file vanishes without any gated deletion (no explicit-deletion evidence).
        let files = try await harness.viewModel.test_dataService.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(sessionID.uuidString) })
        try FileManager.default.removeItem(at: fileURL)
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("reconstruction committed and adopted") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
                && harness.session.scheduledSendPendingFinalization == nil
                && harness.session.lastScheduledDispatch != nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID), "Every durable settlement releases ownership exactly")
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertEqual(harness.session.lastScheduledDispatch, pending.receipt)
        XCTAssertEqual(probe.startCount, 1, "Reconstruction never re-invokes the provider")
        let persisted = try await harness.persistedSession()
        XCTAssertNil(persisted.scheduledSend)
        XCTAssertEqual(persisted.lastScheduledDispatch, pending.receipt)
        let request = try XCTUnwrap(
            persisted.transcript?.turns.compactMap(\.request).first { $0.id == pending.attempt.itemID },
            "The reconstructed file carries the accepted item and marker"
        )
        XCTAssertEqual(request.scheduledSend, pending.receipt)
        XCTAssertEqual(request.text, "Lost file recovery")
        let stamped = try XCTUnwrap(harness.session.items.first { $0.id == pending.attempt.itemID })
        XCTAssertEqual(stamped.scheduledSend, pending.receipt)
    }

    // MARK: - Round 3: admission predicate, recovery adoption, explicit deletion

    func testFollowUpWaitsForBusyPeerBoundToSameSessionWithoutAttemptWrites() async throws {
        let owner = try await makeHarness(windowID: 4340)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Wait for the peer",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let probe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }

        // A peer window bound to the same durable session is running, with no schedule projection.
        let peer = try await makeHarness(windowID: 4341, workspace: owner.workspace, storageURL: owner.storageURL)
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        peer.session.hasLoadedPersistedState = true
        peer.session.runID = UUID()
        peer.viewModel.setAgentRunActive(peer.tabID, isActive: true)
        peer.session.runState = .running
        XCTAssertNil(peer.session.scheduledSend)
        XCTAssertTrue(peer.viewModel.scheduledSendDestinationIsBusy(sessionID: sessionID, excludingDispatchReservationForTabID: nil))

        clock.advance(to: notBefore.addingTimeInterval(1))
        try? await Task.sleep(nanoseconds: 200_000_000)
        coordinator.recordDidChange()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.startCount, 0)
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        let waiting = try await owner.persistedSession()
        let waitingRecord = try XCTUnwrap(waiting.scheduledSend?.persistedValue)
        XCTAssertEqual(waitingRecord.state, .scheduled)
        XCTAssertNil(waitingRecord.attempt, "No .dispatching attempt is written while a same-session peer is busy")

        peer.session.runState = .completed
        peer.viewModel.setAgentRunActive(peer.tabID, isActive: false)
        peer.viewModel.notifyScheduledSendRunStateChanged(for: peer.session)
        try await waitUntil("dispatched once the destination is idle on every host") {
            owner.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertNil(owner.session.scheduledSend)
    }

    func testExplicitDeletionDuringProviderAwaitLeavesNoOrphanSavingProjection() async throws {
        let harness = try await makeHarness(windowID: 4342)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Deleted while the provider decides",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let gate = DispatchGate()
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [gate, probe] _, _, _, _ in
            probe.startCount += 1
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("handed off to the provider") { gate.isWaiting }
        XCTAssertEqual(coordinator.recoveryStatus(sessionID: sessionID)?.phase, .awaitingProviderOutcome)

        // Explicit deletion commits while the provider outcome is outstanding.
        try await harness.viewModel.test_dataService.deleteAgentSession(id: sessionID, for: harness.workspace)
        try await waitUntil("reservation settled by explicit deletion") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
        }
        gate.release()
        try await waitUntil("dispatch finished") { !harness.session.isScheduledDispatchInFlight }

        XCTAssertNil(harness.session.scheduledSendPendingFinalization, "No orphan saving projection after a settled reservation")
        XCTAssertNil(harness.session.scheduledSend)
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertNil(coordinator.recoveryStatus(sessionID: sessionID))
        XCTAssertEqual(probe.startCount, 1)
        let loaded = try await harness.viewModel.test_dataService.loadAgentSession(id: sessionID, for: harness.workspace)
        XCTAssertNil(loaded, "No schedule writer recreated the explicitly deleted session")
    }

    func testTwoHostsExplicitDeletionDuringRecoveryDoesNotResurrectTheFile() async throws {
        let owner = try await makeHarness(windowID: 4343)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Deleted during recovery with a peer open",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let gate = DispatchGate()
        let ownerProbe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [gate, ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("owner handed off to the provider") { gate.isWaiting }
        let diskDuringDispatch = try await owner.persistedSession()

        let peer = try await makeHarness(windowID: 4344, workspace: owner.workspace, storageURL: owner.storageURL)
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertNotNil(peer.session.persistenceState(for: sessionID))
        let peerProbe = DispatchProbe()
        peer.viewModel.scheduledDispatchRunStarter = { [peerProbe] _, _, _, _ in
            peerProbe.startCount += 1
            return .sent
        }

        let failureSwitch = DispatchRecoveryFailureSwitch()
        await owner.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        gate.release()
        try await waitUntil("worker parked for retry; peer adopted the retained attempt") {
            isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
                && peer.session.scheduledSendPendingFinalization?.key == coordinator.recoveryStatus(sessionID: sessionID)?.key
        }

        // Explicit deletion while the retained attempt waits to retry.
        try await owner.viewModel.test_dataService.deleteAgentSession(id: sessionID, for: owner.workspace)
        try await waitUntil("retained attempt settled by explicit deletion") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
        }
        try await waitUntil("both hosts dropped every projection") {
            peer.session.scheduledSend == nil
                && peer.session.scheduledSendPendingFinalization == nil
                && owner.session.scheduledSend == nil
                && owner.session.scheduledSendPendingFinalization == nil
        }
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        coordinator.recordDidChange()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(failureSwitch.callCount, 1, "No further persistence attempt after explicit deletion")
        XCTAssertEqual(ownerProbe.startCount + peerProbe.startCount, 1)
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        let loaded = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        XCTAssertNil(loaded, "Neither the worker, a peer normalization, nor a scheduled-commit fallback recreated the deleted session")
    }

    func testCommittedResetThenAccidentalFileLossReconstructsWithoutPreResetHistory() async throws {
        let harness = try await makeHarness(windowID: 4347)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        harness.viewModel.attachScheduledSendCoordinator(coordinator)

        // Earlier history: an unscheduled bubble and a finalized scheduled item A, both on disk.
        harness.session.appendItem(.user("Unscheduled history"))
        let firstNotBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Earlier scheduled item A",
            on: harness.session,
            notBefore: firstNotBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        harness.viewModel.scheduledDispatchRunStarter = { _, _, _, _ in .sent }
        clock.advance(to: firstNotBefore.addingTimeInterval(1))
        try await waitUntil("A accepted and committed") {
            harness.session.lastScheduledDispatch != nil && harness.session.scheduledSendPendingFinalization == nil
        }
        let receiptA = try XCTUnwrap(harness.session.lastScheduledDispatch)
        let itemA = try XCTUnwrap(harness.session.items.first { $0.scheduledSend == receiptA })
        let didFlushSave = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(didFlushSave)
        let beforeReset = try await harness.persistedSession()
        XCTAssertTrue(beforeReset.toLiveItems().contains { $0.id == itemA.id }, "Pre-reset history is on disk before the reset")

        // B is dispatched and accepted; its durable commit fails (injected) so the payload — whose
        // snapshot still carries the pre-reset history — stays retained.
        let secondNotBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Scheduled item B",
            on: harness.session,
            notBefore: secondNotBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await harness.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        clock.advance(to: secondNotBefore.addingTimeInterval(1))
        try await waitUntil("B accepted; worker parked for retry") {
            harness.session.scheduledSendPendingFinalization != nil
                && !harness.session.isScheduledDispatchInFlight
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
        }
        let pendingB = try XCTUnwrap(harness.session.scheduledSendPendingFinalization)

        // The user resets the conversation; the reset commits with its stable receipt against the
        // existing incarnation and tombstones both A and B.
        harness.viewModel.clearChat(tabID: harness.tabID)
        let resetReceipt = try XCTUnwrap(harness.session.pendingTranscriptResetReceipt)
        XCTAssertEqual(
            Set(harness.session.pendingFinalizedScheduledSendItemRemovals.map(\.itemID)),
            [itemA.id, pendingB.attempt.itemID]
        )
        let didFlushReset = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(didFlushReset)
        XCTAssertNil(harness.session.pendingTranscriptResetReceipt, "The receipt is consumed by the save that committed the reset")
        XCTAssertTrue(harness.session.pendingFinalizedScheduledSendItemRemovals.isEmpty)
        _ = resetReceipt
        let afterReset = try await harness.persistedSession()
        XCTAssertTrue(afterReset.toLiveItems().isEmpty)
        XCTAssertEqual(afterReset.scheduledSend?.persistedValue?.state, .dispatching, "Ordinary saves never touch the live attempt")

        // Accidental loss (not an explicit deletion) after the committed reset.
        let files = try await harness.viewModel.test_dataService.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(sessionID.uuidString) })
        try FileManager.default.removeItem(at: fileURL)
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("reconstruction committed and adopted") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
                && harness.session.scheduledSendPendingFinalization == nil
                && harness.session.lastScheduledDispatch == pendingB.receipt
        }
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reconstructed = try await harness.persistedSession()
        XCTAssertNil(reconstructed.scheduledSend)
        XCTAssertEqual(reconstructed.lastScheduledDispatch, pendingB.receipt)
        let reconstructedItems = reconstructed.toLiveItems()
        XCTAssertTrue(reconstructedItems.isEmpty, "Reconstruction honors the committed reset: no pre-reset history, no tombstoned B")
        XCTAssertFalse(reconstructedItems.contains { $0.id == itemA.id })
        XCTAssertFalse(reconstructedItems.contains { $0.id == pendingB.attempt.itemID })
        XCTAssertTrue(harness.session.items.isEmpty)
        XCTAssertNil(harness.session.scheduledSend)
    }

    func testQueuedSaveAfterExplicitDeletionDoesNotRecreateTheSession() async throws {
        let harness = try await makeHarness(windowID: 4348)
        let notBefore = Date().addingTimeInterval(600)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Deleted then saved",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        XCTAssertEqual(harness.session.persistedIncarnationSessionID, sessionID, "The first successful save pins the incarnation")

        try await harness.viewModel.test_dataService.deleteAgentSession(id: sessionID, for: harness.workspace)
        harness.session.appendItem(.user("late edit"))
        harness.session.isDirty = true
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertFalse(saved, "An existing-incarnation save refuses to recreate the deleted file")
        XCTAssertNil(harness.session.scheduledSend, "Explicit deletion invalidates the schedule projection")
        XCTAssertNil(harness.session.scheduledSendPersistedUpdatedAt)
        let loaded = try await harness.viewModel.test_dataService.loadAgentSession(id: sessionID, for: harness.workspace)
        XCTAssertNil(loaded)
    }

    func testClockConfirmationSurvivesWriteFailureStorageRecoveryAndReloadBeforeDeadline() async throws {
        let harness = try await makeHarness(windowID: 4349)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Confirm after a clock change",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }

        // The deadline is observed while the session is busy (no dispatch), then the wall clock
        // rolls back so the deadline is in the future again: an uncertain crossing.
        harness.session.runID = UUID()
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: true)
        harness.session.runState = .running
        clock.advance(to: notBefore.addingTimeInterval(5))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.startCount, 0)

        // Actual write failure: the session folder becomes read-only, so the durable CAS replace
        // fails at the file system while identity, stamp, and destination stay unchanged.
        let files = try await harness.viewModel.test_dataService.listAgentSessions(for: harness.workspace)
        let sessionFileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(sessionID.uuidString) })
        let sessionsFolder = sessionFileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessionsFolder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsFolder.path)
        }
        clock.setNow(notBefore.addingTimeInterval(-120), probe: SchedulerClockProbe(suspendedGap: 0, wallClockAdjustment: -125))
        coordinator.recordDidChange()
        try await waitUntil("confirmation write failed and parked for retry") {
            if case .waitingToRetry? = coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase { return true }
            return false
        }
        XCTAssertEqual(coordinator.pendingConfirmationStatus(sessionID: sessionID)?.reason, .clockChanged)
        XCTAssertEqual(harness.session.pendingScheduledSendRecord?.state, .scheduled, "No optimistic projection of the unacknowledged mutation")
        let props = try XCTUnwrap(harness.viewModel.makeComposerProps(tabID: harness.tabID).scheduledSend)
        XCTAssertEqual(props.status, .needsConfirmation(.clockChanged), "The banner derives the pending decision")
        XCTAssertEqual(props.pendingConfirmationSaving, .saving)
        let onDiskWhilePending = try await harness.persistedSession()
        XCTAssertEqual(onDiskWhilePending.scheduledSend?.persistedValue?.state, .scheduled)

        // The blocker clears and the rolled-back deadline passes: still no dispatch.
        harness.session.runState = .completed
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: false)
        harness.viewModel.notifyScheduledSendRunStateChanged(for: harness.session)
        clock.advance(to: notBefore.addingTimeInterval(1))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(probe.startCount, 0, "A pending confirmation blocks dispatch at the deadline")
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))

        // Storage recovers; the exact retry commits the confirmation durably.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsFolder.path)
        guard case let .waitingToRetry(_, retryAt)? = coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase else {
            return XCTFail("Expected a parked retry")
        }
        clock.advance(to: max(clock.now, retryAt))
        try await waitUntil("confirmation committed") {
            coordinator.pendingConfirmationStatus(sessionID: sessionID) == nil
        }
        let durable = try await harness.persistedSession()
        let durableRecord = try XCTUnwrap(durable.scheduledSend?.persistedValue)
        XCTAssertEqual(durableRecord.state, .needsConfirmation)
        XCTAssertEqual(durableRecord.confirmationReason, .clockChanged)
        XCTAssertEqual(harness.session.pendingScheduledSendRecord, durableRecord, "The owner adopts only the durable result")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.startCount, 0)

        // Reload before the rolled-back deadline in a fresh process (new coordinator, new host).
        let reloaded = try await makeHarness(windowID: 4350, workspace: harness.workspace, storageURL: harness.storageURL)
        let reloadClock = DispatchFakeClock(now: notBefore.addingTimeInterval(-60))
        let reloadCoordinator = AgentScheduledSendCoordinator(clock: reloadClock.clock)
        reloaded.viewModel.attachScheduledSendCoordinator(reloadCoordinator)
        XCTAssertNotNil(reloaded.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: reloaded.session))
        _ = await reloaded.viewModel.test_hydrateBoundSession(tabID: reloaded.tabID)
        XCTAssertEqual(reloaded.session.pendingScheduledSendRecord?.state, .needsConfirmation)
        XCTAssertNotNil(reloaded.session.persistenceState(for: sessionID))
        let reloadProbe = DispatchProbe()
        reloaded.viewModel.scheduledDispatchRunStarter = { [reloadProbe] _, _, _, _ in
            reloadProbe.startCount += 1
            return .sent
        }
        reloadCoordinator.recordDidChange()
        reloadClock.advance(to: notBefore.addingTimeInterval(30))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reloadProbe.startCount, 0, "The durable confirmation survives reload; nothing auto-sends at the deadline")

        // Explicit user confirmation on the reloaded host sends exactly once.
        let sendNow = await reloaded.viewModel.sendScheduledSendNow(tabID: reloaded.tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
        XCTAssertNil(sendNow)
        try await waitUntil("confirmed send dispatched once") { reloaded.session.lastScheduledDispatch != nil }
        XCTAssertEqual(reloadProbe.startCount, 1)
        XCTAssertEqual(probe.startCount, 0)
    }

    // MARK: - Round 4: late resync adoption, cross-host Send now, creation retry, missing-file lifetime

    func testLateAuthoritativeResyncAfterExhaustionAdoptsRecoveryOnThePeer() async throws {
        let owner = try await makeHarness(windowID: 4360)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1])
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Late resync adopts",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        // The peer hydrated the pre-dispatch record and stays detached from the coordinator, so
        // no commit or recovery notification reaches it: its authoritative refresh is "delayed".
        let peer = try await makeHarness(windowID: 4361, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.state, .scheduled)
        let peerProbe = DispatchProbe()
        peer.viewModel.scheduledDispatchRunStarter = { [peerProbe] _, _, _, _ in
            peerProbe.startCount += 1
            return .sent
        }

        let failureSwitch = DispatchRecoveryFailureSwitch()
        await owner.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        let ownerProbe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("bounded retries exhausted") {
            if case .needsAttention(.persistenceExhausted)? = coordinator.recoveryStatus(sessionID: sessionID)?.phase {
                return true
            }
            clock.advance(to: clock.now.addingTimeInterval(1))
            return false
        }
        owner.viewModel.releaseScheduledSendForRemovedSession(owner.session, deletesPersistedSession: false)
        owner.viewModel.detachScheduledSendCoordinator()

        // The peer attaches after every recovery notification has already been posted; its local
        // record still predates the attempt, so nothing can be adopted yet.
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNil(peer.session.scheduledSendPendingFinalization)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.state, .scheduled)

        // The delayed authoritative refresh lands with no further recovery event.
        await peer.viewModel.resyncScheduledSendFromDisk(session: peer.session)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.state, .dispatching)
        let adopted = try XCTUnwrap(peer.session.scheduledSendPendingFinalization, "The resync reconciles coordinator-owned recovery")
        XCTAssertEqual(adopted.key, coordinator.recoveryStatus(sessionID: sessionID)?.key)
        guard case .needsAttention = adopted.status else {
            return XCTFail("Expected the attention state, got \(adopted.status)")
        }
        let props = try XCTUnwrap(peer.viewModel.makeComposerProps(tabID: peer.tabID).scheduledSend)
        guard case .savingFailed = props.status else {
            return XCTFail("Expected savingFailed with Retry saving on the peer, got \(props.status)")
        }

        // Persistence-only retry from the peer completes without a second provider submission.
        failureSwitch.failing = false
        let peerRetryMessage = await peer.viewModel.retryScheduledSendSaving(tabID: peer.tabID)
        XCTAssertNil(peerRetryMessage)
        try await waitUntil("peer adopted the committed file") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
                && peer.session.scheduledSendPendingFinalization == nil
                && peer.session.scheduledSend == nil
                && peer.session.lastScheduledDispatch != nil
        }
        XCTAssertEqual(ownerProbe.startCount, 1)
        XCTAssertEqual(peerProbe.startCount, 0)
    }

    func testPeerSendNowWaitsForOwnerConfirmationWriteAndSendsOnceAtTheCommittedRevision() async throws {
        let owner = try await makeHarness(windowID: 4362)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await owner.viewModel.installScheduledSend(
            text: "Send now across hosts",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let ownerProbe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            return .sent
        }

        // Occupy the owner's per-tab serializer so the coordinator's confirmation write, once
        // issued to this host, stays outstanding until the gate opens.
        let gate = DispatchGate()
        let occupation = Task { @MainActor in
            await owner.viewModel.runScheduledSendAction(on: owner.session) {
                await gate.waitForRelease()
            }
        }
        try await waitUntil("serializer occupied") { gate.isWaiting }
        clock.advance(to: notBefore.addingTimeInterval(30), probe: SchedulerClockProbe(suspendedGap: 60))
        try await waitUntil("confirmation write issued and outstanding on the owner") {
            coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase == .saving(attemptNumber: 1)
        }
        let diskBefore = try await owner.persistedSession()
        XCTAssertEqual(diskBefore.scheduledSend?.persistedValue?.state, .scheduled)
        let revisionBefore = try XCTUnwrap(diskBefore.scheduledSend?.persistedValue?.updatedAt)

        // A peer window projects the pre-decision revision and the user presses Send now there.
        let peer = try await makeHarness(windowID: 4363, workspace: owner.workspace, storageURL: owner.storageURL)
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.updatedAt, revisionBefore)
        let peerProbe = DispatchProbe()
        peer.viewModel.scheduledDispatchRunStarter = { [peerProbe] _, _, _, _ in
            peerProbe.startCount += 1
            return .sent
        }
        let sendNowResult = DispatchProbe()
        let sendNow = Task { @MainActor in
            let message = await peer.viewModel.sendScheduledSendNow(tabID: peer.tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
            sendNowResult.providerText = message ?? "<nil>"
            sendNowResult.startCount = 1
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sendNowResult.startCount, 0, "Send now waits for the outstanding confirmation write")
        XCTAssertEqual(ownerProbe.startCount + peerProbe.startCount, 0)

        // The older write commits; only then may the user's consent be installed, at that revision.
        gate.release()
        await occupation.value
        await sendNow.value
        XCTAssertEqual(sendNowResult.providerText, "<nil>", "Send now succeeded")
        try await waitUntil("confirmed send dispatched exactly once") {
            ownerProbe.startCount + peerProbe.startCount == 1
                && (owner.session.lastScheduledDispatch != nil || peer.session.lastScheduledDispatch != nil)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(ownerProbe.startCount + peerProbe.startCount, 1, "Never more than one provider submission")
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        let persisted = try await owner.persistedSession()
        XCTAssertNil(persisted.scheduledSend)
        XCTAssertEqual(persisted.lastScheduledDispatch?.scheduleID, scheduleID)
    }

    func testSendNowHeldBehindTheTabSerializerNeverDeadlocksOnAnInformationalWrite() async throws {
        let harness = try await makeHarness(windowID: 4367)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Send now under a held serializer",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let probe = DispatchProbe()
        harness.viewModel.scheduledDispatchRunStarter = { [probe] _, _, _, _ in
            probe.startCount += 1
            return .sent
        }
        // Busy destination: once due, the coordinator would issue the first-eligibility write.
        let runID = UUID()
        harness.session.runID = runID
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: true)
        harness.session.runState = .running

        // Occupy the tab's serializer, then queue Send now behind it (its outer drain passes:
        // nothing is in flight yet).
        let gate = DispatchGate()
        let occupation = Task { @MainActor in
            await harness.viewModel.runScheduledSendAction(on: harness.session) {
                await gate.waitForRelease()
            }
        }
        try await waitUntil("serializer occupied") { gate.isWaiting }
        let sendNowResult = DispatchProbe()
        let sendNow = Task { @MainActor in
            let message = await harness.viewModel.sendScheduledSendNow(tabID: harness.tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
            sendNowResult.providerText = message ?? "<nil>"
            sendNowResult.startCount = 1
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sendNowResult.startCount, 0, "Send now is queued behind the held action")

        // The schedule becomes due while Send now is queued: an informational write issued now
        // would chain behind Send now in the same serializer. The session-scoped reservation
        // prevents it, so nothing can wait on the queued action.
        clock.advance(to: notBefore.addingTimeInterval(1))
        coordinator.recordDidChange()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let diskWhileQueued = try await harness.persistedSession()
        XCTAssertNil(diskWhileQueued.scheduledSend?.persistedValue?.firstEligibleAt, "No coordinator mutation is issued while a user action holds the session")

        gate.release()
        await occupation.value
        try await waitUntil("Send now completed without deadlocking") { sendNowResult.startCount == 1 }
        XCTAssertEqual(sendNowResult.providerText, "<nil>")
        _ = sendNow

        // The blocker clears: the confirmed send dispatches exactly once.
        harness.session.runState = .completed
        harness.viewModel.setAgentRunActive(harness.tabID, isActive: false)
        harness.viewModel.notifyScheduledSendRunStateChanged(for: harness.session)
        try await waitUntil("confirmed send dispatched") { harness.session.lastScheduledDispatch != nil }
        XCTAssertEqual(probe.startCount, 1)
    }

    func testMaterializedRemoteSessionAdoptsAnExistingIncarnationOrStartsAsCreator() async throws {
        let harness = try await makeHarness(windowID: 4368)

        // A previous pickup of the same deterministic id left its file behind; a fresh tab bound
        // to that id must adopt the incarnation (paired load), and its saves must succeed.
        let existingID = UUID()
        _ = try await harness.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: existingID, workspaceID: harness.workspace.id, name: "Earlier pickup"),
            for: harness.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let adopterTabID = UUID()
        let adopter = try await harness.viewModel.ensureSessionReady(tabID: adopterTabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: existingID, on: adopter))
        await harness.viewModel.hydrateMaterializedRemoteSession(adopter)
        XCTAssertTrue(adopter.hasLoadedPersistedState)
        XCTAssertEqual(adopter.persistedIncarnationSessionID, existingID)
        XCTAssertNotNil(adopter.persistenceState(for: existingID), "The existing incarnation is owned through the paired load")
        adopter.appendItem(.user("materialized after pickup"))
        adopter.isDirty = true
        let adopterSaved = await harness.viewModel.flushSave(for: adopterTabID)
        XCTAssertTrue(adopterSaved, "Saves target the adopted incarnation")
        let reloadedExisting = try await harness.viewModel.test_dataService.loadAgentSession(id: existingID, for: harness.workspace)
        let reloaded = try XCTUnwrap(reloadedExisting)
        XCTAssertTrue(reloaded.toLiveItems().contains { $0.text == "materialized after pickup" })

        // No file for a new deterministic id: the tab is a genuine creator, not a stuck owner.
        let freshID = UUID()
        let creatorTabID = UUID()
        let creator = try await harness.viewModel.ensureSessionReady(tabID: creatorTabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: freshID, on: creator))
        await harness.viewModel.hydrateMaterializedRemoteSession(creator)
        XCTAssertTrue(creator.hasLoadedPersistedState)
        XCTAssertNil(creator.persistedIncarnationSessionID)
        creator.appendItem(.user("first save creates the file"))
        creator.isDirty = true
        let creatorSaved = await harness.viewModel.flushSave(for: creatorTabID)
        XCTAssertTrue(creatorSaved)
        XCTAssertEqual(creator.persistedIncarnationSessionID, freshID)
        let createdFile = try await harness.viewModel.test_dataService.loadAgentSession(id: freshID, for: harness.workspace)
        XCTAssertNotNil(createdFile)
    }

    func testFailedInitialWriteRetriesCreationUnderThePreparedAuthority() async throws {
        let harness = try await makeHarness(windowID: 4364)
        let sessionsFolder = harness.storageURL.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessionsFolder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsFolder.path)
        }

        // The first durable write of a never-persisted session fails at the file system.
        let first = await harness.viewModel.installScheduledSend(
            text: "Create me",
            on: harness.session,
            notBefore: Date().addingTimeInterval(600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        )
        guard case .failure = first else {
            return XCTFail("Expected the initial write to fail, got \(first)")
        }
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        XCTAssertNil(harness.session.persistedIncarnationSessionID, "Prepared authority is not a persisted incarnation")
        XCTAssertNil(harness.session.persistenceRevokedSessionID, "A failed creation never revokes the lifetime")
        XCTAssertNil(harness.session.scheduledSend, "The failed install restored the composer state")

        // Storage recovers: the retry creates the file under the same captured authority.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsFolder.path)
        let scheduleID = try await harness.viewModel.installScheduledSend(
            text: "Create me",
            on: harness.session,
            notBefore: Date().addingTimeInterval(600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        XCTAssertEqual(harness.session.persistedIncarnationSessionID, sessionID)
        XCTAssertNil(harness.session.persistenceRevokedSessionID)
        XCTAssertNotNil(harness.session.persistenceState(for: sessionID))
        let persisted = try await harness.persistedSession()
        XCTAssertEqual(persisted.scheduledSend?.persistedValue?.id, scheduleID)
    }

    func testMissingSessionFileDuringRecoveryKeepsOwnershipRecoveryAndDirtyDataUntilReconstruction() async throws {
        let harness = try await makeHarness(windowID: 4365)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1, 1])
        harness.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Missing file keeps ownership",
            on: harness.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let failureSwitch = DispatchRecoveryFailureSwitch()
        await harness.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        harness.viewModel.scheduledDispatchRunStarter = { _, _, _, _ in .sent }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("accepted; worker parked") {
            harness.session.scheduledSendPendingFinalization != nil
                && isWaitingToRetry(coordinator.recoveryStatus(sessionID: sessionID)?.phase)
        }
        let pending = try XCTUnwrap(harness.session.scheduledSendPendingFinalization)
        let stateBefore = try XCTUnwrap(harness.session.persistenceState(for: sessionID))

        // Accidental loss (no gated deletion). An ordinary dirty save and an authoritative
        // schedule resync both observe the absence before the worker reconstructs the file.
        let files = try await harness.viewModel.test_dataService.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(sessionID.uuidString) })
        try FileManager.default.removeItem(at: fileURL)
        harness.session.appendItem(.user("edited while the file is missing"))
        harness.session.isDirty = true
        let savedWhileMissing = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertFalse(savedWhileMissing, "A save cannot recreate the file from the tab's transcript")
        await harness.viewModel.resyncScheduledSendFromDisk(session: harness.session)
        XCTAssertNil(harness.session.persistenceRevokedSessionID, "Mere absence is not deletion evidence")
        XCTAssertEqual(harness.session.persistenceState(for: sessionID), stateBefore, "Captured ownership is retained")
        XCTAssertEqual(harness.session.scheduledSendPendingFinalization?.key, pending.key, "The accepted recovery projection is retained")
        XCTAssertTrue(harness.session.isDirty, "Dirty data is retained for a later save")
        XCTAssertNotNil(coordinator.recoveryStatus(sessionID: sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Nothing recreated the file from stale state")

        // The retained recovery reconstructs the file; ordinary saves then succeed again.
        failureSwitch.failing = false
        clock.advance(to: clock.now.addingTimeInterval(1))
        try await waitUntil("reconstruction committed and adopted") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
                && harness.session.scheduledSendPendingFinalization == nil
                && harness.session.lastScheduledDispatch == pending.receipt
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        harness.session.isDirty = true
        let savedAfterReconstruction = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(savedAfterReconstruction, "Ownership survived the missing-file window")
        let persisted = try await harness.persistedSession()
        XCTAssertEqual(persisted.lastScheduledDispatch, pending.receipt)
        XCTAssertTrue(persisted.toLiveItems().contains { $0.text == "edited while the file is missing" })
    }

    func testStaleLifetimeFailureForAPreviousBindingNeverRevokesTheCurrentSession() async throws {
        let harness = try await makeHarness(windowID: 4366)
        _ = try await harness.viewModel.installScheduledSend(
            text: "Bound to A",
            on: harness.session,
            notBefore: Date().addingTimeInterval(600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionA = try XCTUnwrap(harness.session.activeAgentSessionID)
        let sessionB = UUID()
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: sessionB, on: harness.session))
        XCTAssertEqual(harness.session.activeAgentSessionID, sessionB)

        // A lifetime failure that belonged to the A-bound operation arrives after the rebinding.
        harness.viewModel.handleDurableSessionDeleted(harness.session, sessionID: sessionA)
        XCTAssertNil(harness.session.persistenceRevokedSessionID, "A stale failure for A cannot revoke B")
        XCTAssertNotNil(harness.session.scheduledSend, "B's projection is untouched")

        // The same failure for the current binding is honored exactly.
        harness.viewModel.handleDurableSessionDeleted(harness.session, sessionID: sessionB)
        XCTAssertEqual(harness.session.persistenceRevokedSessionID, sessionB)
        XCTAssertNil(harness.session.scheduledSend)
    }

    func testOwnerDetachWithOpenPeerExhaustionOffersPersistenceOnlyRetryOnThePeer() async throws {
        let owner = try await makeHarness(windowID: 4345)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock, recoveryRetryDelays: [1, 1])
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        _ = try await owner.viewModel.installScheduledSend(
            text: "Peer adopts the recovery",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let gate = DispatchGate()
        let ownerProbe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [gate, ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            await gate.waitForRelease()
            return .sent
        }
        clock.advance(to: notBefore.addingTimeInterval(1))
        try await waitUntil("owner handed off to the provider") { gate.isWaiting }
        let diskDuringDispatch = try await owner.persistedSession()

        let peer = try await makeHarness(windowID: 4346, workspace: owner.workspace, storageURL: owner.storageURL)
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.state, .dispatching)
        XCTAssertNotNil(peer.session.persistenceState(for: sessionID))
        XCTAssertNil(peer.session.scheduledSendPendingFinalization, "Nothing to adopt before acceptance is retained")
        let peerProbe = DispatchProbe()
        peer.viewModel.scheduledDispatchRunStarter = { [peerProbe] _, _, _, _ in
            peerProbe.startCount += 1
            return .sent
        }

        let failureSwitch = DispatchRecoveryFailureSwitch()
        await owner.viewModel.test_dataService.test_setScheduledSendRecoveryFailureInjector { [failureSwitch] _ in failureSwitch.next() }
        gate.release()
        try await waitUntil("peer adopted the retained attempt from coordinator-owned values") {
            peer.session.scheduledSendPendingFinalization != nil
                && peer.session.scheduledSendPendingFinalization?.key == coordinator.recoveryStatus(sessionID: sessionID)?.key
        }
        let pendingOnPeer = try XCTUnwrap(peer.session.scheduledSendPendingFinalization)
        XCTAssertEqual(pendingOnPeer.attempt, diskDuringDispatch.scheduledSend?.persistedValue?.attempt)

        // The owning host goes away entirely before persistence recovers.
        owner.viewModel.releaseScheduledSendForRemovedSession(owner.session, deletesPersistedSession: false)
        owner.viewModel.detachScheduledSendCoordinator()

        try await waitUntil("bounded retries exhausted") {
            if case .needsAttention(.persistenceExhausted)? = coordinator.recoveryStatus(sessionID: sessionID)?.phase {
                return true
            }
            clock.advance(to: clock.now.addingTimeInterval(1))
            return false
        }
        XCTAssertEqual(failureSwitch.callCount, 3)
        XCTAssertNotNil(coordinator.activeAdmission(sessionID: sessionID), "Attention retains duplicate-delivery protection")
        try await waitUntil("peer presents the attention state") {
            if case .needsAttention? = peer.session.scheduledSendPendingFinalization?.status { return true }
            return false
        }
        let peerRecord = try XCTUnwrap(peer.session.pendingScheduledSendRecord)
        let props = AgentScheduledSendProps(
            tabID: peer.tabID,
            scheduledSend: peerRecord,
            recoveryPhase: peer.session.scheduledSendPendingFinalization?.status
        )
        guard case .savingFailed = props.status else {
            return XCTFail("Expected savingFailed on the peer, got \(props.status)")
        }
        XCTAssertEqual(props.recoveryMessage, AgentScheduledSendProps.savingFailedRecoveryMessage)

        // Persistence-only retry from the peer: never a provider action.
        failureSwitch.failing = false
        let retryMessage = await peer.viewModel.retryScheduledSendSaving(tabID: peer.tabID)
        XCTAssertNil(retryMessage)
        try await waitUntil("manual retry committed and adopted on the peer") {
            coordinator.recoveryStatus(sessionID: sessionID) == nil
                && peer.session.scheduledSendPendingFinalization == nil
                && peer.session.scheduledSend == nil
                && peer.session.lastScheduledDispatch != nil
        }
        XCTAssertNil(coordinator.activeAdmission(sessionID: sessionID))
        XCTAssertEqual(failureSwitch.callCount, 4)
        XCTAssertEqual(ownerProbe.startCount, 1, "Exactly one provider submission across both hosts")
        XCTAssertEqual(peerProbe.startCount, 0)
        let persisted = try await peer.persistedSession()
        XCTAssertNil(persisted.scheduledSend)
        XCTAssertEqual(persisted.lastScheduledDispatch, pendingOnPeer.receipt)
        XCTAssertEqual(peer.session.lastScheduledDispatch, pendingOnPeer.receipt)
    }

    // MARK: - Harness

    @MainActor

    // MARK: - R5 P1 remediation: verified refresh, coalesced creation, guarded materialization

    func testPeerSendNowRefusesConsentWhenAuthoritativeRefreshFailsAfterDrainAndRetrySendsOnce() async throws {
        let owner = try await makeHarness(windowID: 4370)
        let clock = DispatchFakeClock(now: Date())
        let coordinator = AgentScheduledSendCoordinator(clock: clock.clock)
        owner.viewModel.attachScheduledSendCoordinator(coordinator)
        let notBefore = clock.now.addingTimeInterval(60)
        let scheduleID = try await owner.viewModel.installScheduledSend(
            text: "Send now after a failed refresh",
            on: owner.session,
            notBefore: notBefore,
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        ).get()
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let ownerProbe = DispatchProbe()
        owner.viewModel.scheduledDispatchRunStarter = { [ownerProbe] _, _, _, _ in
            ownerProbe.startCount += 1
            return .sent
        }

        // The owner's automatic confirmation write is issued while its serializer is occupied, so
        // it stays outstanding (and is drained by the peer's Send now) until the gate opens.
        let gate = DispatchGate()
        let occupation = Task { @MainActor in
            await owner.viewModel.runScheduledSendAction(on: owner.session) {
                await gate.waitForRelease()
            }
        }
        try await waitUntil("serializer occupied") { gate.isWaiting }
        clock.advance(to: notBefore.addingTimeInterval(30), probe: SchedulerClockProbe(suspendedGap: 60))
        try await waitUntil("confirmation write issued and outstanding on the owner") {
            coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase == .saving(attemptNumber: 1)
        }
        let diskBefore = try await owner.persistedSession()
        let revisionBefore = try XCTUnwrap(diskBefore.scheduledSend?.persistedValue?.updatedAt)

        // A peer window projects the pre-decision revision and the user presses Send now there.
        let peer = try await makeHarness(windowID: 4371, workspace: owner.workspace, storageURL: owner.storageURL)
        peer.viewModel.attachScheduledSendCoordinator(coordinator)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.updatedAt, revisionBefore)
        let peerProbe = DispatchProbe()
        peer.viewModel.scheduledDispatchRunStarter = { [peerProbe] _, _, _, _ in
            peerProbe.startCount += 1
            return .sent
        }
        // Every authoritative read on the peer fails until the first Send now has returned, so the
        // refresh that follows the drain cannot establish the committed revision.
        let readSwitch = ResyncReadFailureSwitch()
        peer.viewModel.test_scheduledSendResyncReadFailureInjector = { [readSwitch] _ in
            readSwitch.attempts += 1
            return readSwitch.failing ? InjectedResyncReadFailure() : nil
        }
        let sendNowResult = DispatchProbe()
        let sendNow = Task { @MainActor in
            let message = await peer.viewModel.sendScheduledSendNow(tabID: peer.tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
            sendNowResult.providerText = message ?? "<nil>"
            sendNowResult.startCount = 1
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sendNowResult.startCount, 0, "Send now waits for the outstanding confirmation write")

        // The older write commits; the peer's refresh right after the drain fails.
        gate.release()
        await occupation.value
        await sendNow.value
        readSwitch.failing = false
        let refreshAttempts = readSwitch.attempts
        XCTAssertGreaterThanOrEqual(refreshAttempts, 1, "The authoritative refresh after the drain was attempted")
        XCTAssertEqual(
            sendNowResult.providerText,
            AgentModeViewModel.scheduledSendVerificationFailedMessage,
            "A failed authoritative refresh is a retryable refusal, never success"
        )
        XCTAssertEqual(peer.session.pendingScheduledSendRecord?.updatedAt, revisionBefore, "Nothing is adopted from a failed read")
        // The committed write retired the coordinator's in-memory obligation
        // (`completeConfirmationPersistence` → `.committed`); from here the durable
        // `.needsConfirmation` record is the authority that blocks sending, and only an explicit
        // user confirmation verified against that revision may install consent for it.
        let obligationAfterRefusal = coordinator.pendingConfirmationStatus(sessionID: sessionID)
        XCTAssertNil(obligationAfterRefusal, "The committed decision no longer needs a durable acknowledgement")
        let diskAfterWrite = try await owner.persistedSession()
        let committedRecord = try XCTUnwrap(diskAfterWrite.scheduledSend?.persistedValue)
        XCTAssertEqual(committedRecord.state, .needsConfirmation)
        XCTAssertGreaterThan(committedRecord.updatedAt, revisionBefore, "The older write committed the newer revision")
        // No consent exists for the unverified revision R or the committed revision R′: a forced
        // evaluation neither dispatches nor writes a `.dispatching` attempt, and the committed
        // record is left exactly as written.
        coordinator.recordDidChange()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(ownerProbe.startCount + peerProbe.startCount, 0, "Nothing is sent from an obsolete or absent consent")
        let diskAfterEvaluation = try await owner.persistedSession()
        let recordAfterEvaluation = try XCTUnwrap(diskAfterEvaluation.scheduledSend?.persistedValue)
        XCTAssertEqual(recordAfterEvaluation.state, .needsConfirmation, "The committed decision still blocks sending")
        XCTAssertEqual(recordAfterEvaluation.updatedAt, committedRecord.updatedAt, "No admission touched the committed record")
        XCTAssertNil(recordAfterEvaluation.attempt, "No attempt was persisted against the committed decision")

        // Storage reads recover: the retry verifies the committed revision, installs consent for
        // exactly that revision, and dispatches exactly once.
        let retryMessage = await peer.viewModel.sendScheduledSendNow(tabID: peer.tabID, scheduleID: scheduleID, runAlongsideOtherSessions: false)
        XCTAssertNil(retryMessage)
        try await waitUntil("confirmed send dispatched exactly once") {
            ownerProbe.startCount + peerProbe.startCount == 1
                && (owner.session.lastScheduledDispatch != nil || peer.session.lastScheduledDispatch != nil)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(ownerProbe.startCount + peerProbe.startCount, 1, "Never more than one provider submission")
        XCTAssertNil(coordinator.pendingConfirmationStatus(sessionID: sessionID))
        let persisted = try await owner.persistedSession()
        XCTAssertNil(persisted.scheduledSend)
        XCTAssertEqual(persisted.lastScheduledDispatch?.scheduleID, scheduleID)
    }

    func testCoalescedSaveDuringInitialCreationKeepsScheduleInstalledAndDurable() async throws {
        let harness = try await makeHarness(windowID: 4372)
        let attachmentURL = try makeManagedAttachmentFile(in: harness.storageURL, name: "coalesced.png")
        let attachment = AgentImageAttachment(source: .localFile(path: attachmentURL.path))
        harness.session.pendingImageAttachments = [attachment]
        XCTAssertNil(harness.session.persistedIncarnationSessionID, "The session has never been persisted")

        // While initial creation prepares its create-only authority, another save request
        // coalesces behind the in-flight save (its commit token goes stale after the write).
        let hookCalls = DispatchProbe()
        harness.viewModel.test_initialPersistencePreparationHook = { [harness, hookCalls] session in
            hookCalls.startCount += 1
            harness.viewModel.scheduleSave(for: session.tabID)
        }
        let install = await harness.viewModel.installScheduledSend(
            text: "Create with a coalesced save",
            on: harness.session,
            notBefore: Date().addingTimeInterval(600),
            runAlongsideOtherSessions: false,
            isNewSessionStart: false
        )
        harness.viewModel.test_initialPersistencePreparationHook = nil
        let scheduleID = try install.get()
        XCTAssertEqual(hookCalls.startCount, 1, "Creation prepared its authority exactly once")

        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        XCTAssertEqual(harness.session.persistedIncarnationSessionID, sessionID, "The durable write established the incarnation")
        XCTAssertNotNil(harness.session.persistenceState(for: sessionID))
        let installedRecord = try XCTUnwrap(harness.session.pendingScheduledSendRecord)
        XCTAssertEqual(installedRecord.id, scheduleID, "The installed schedule is kept, not rolled back")
        XCTAssertEqual(installedRecord.attachments, [attachment])
        XCTAssertTrue(harness.session.pendingImageAttachments.isEmpty, "The draft is not restored after a durable creation")
        XCTAssertTrue(harness.session.isDirty, "The coalesced request keeps the projection dirty for its fresh save")
        let persisted = try await harness.persistedSession()
        let persistedRecord = try XCTUnwrap(persisted.scheduledSend?.persistedValue)
        XCTAssertEqual(persistedRecord.id, scheduleID)
        XCTAssertEqual(harness.session.scheduledSendPersistedUpdatedAt, persistedRecord.updatedAt, "Local revision matches the exact installed record")
    }

    func testMaterializedRemoteHydrationRejectsRebindDuringHeldLoadWithoutDeclaringLoaded() async throws {
        let harness = try await makeHarness(windowID: 4373)
        let existingID = UUID()
        _ = try await harness.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: existingID, workspaceID: harness.workspace.id, name: "Earlier pickup"),
            for: harness.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let replacementID = UUID()
        let tabID = UUID()
        let session = try await harness.viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: existingID, on: session))

        // The paired load is held after preparing A's payload; the tab is rebound to B meanwhile.
        let rebinds = DispatchProbe()
        harness.viewModel.test_persistedLoadPrepareHook = { [harness, rebinds] held in
            guard held.activeAgentSessionID == existingID else { return }
            rebinds.startCount += 1
            _ = harness.viewModel.test_installPersistentSessionBinding(sessionID: replacementID, on: held)
        }
        let outcome = await harness.viewModel.hydrateMaterializedRemoteSession(session)
        harness.viewModel.test_persistedLoadPrepareHook = nil

        XCTAssertEqual(rebinds.startCount, 1)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(session.activeAgentSessionID, replacementID)
        XCTAssertFalse(session.hasLoadedPersistedState, "A rejected hydration never declares the rebound tab loaded")
        XCTAssertNil(session.persistenceState, "A's authority is never installed on B's binding")
        XCTAssertNil(session.persistedIncarnationSessionID)
        XCTAssertTrue(session.items.isEmpty, "A's transcript is never applied to B")

        // The same tab, still bound to A, adopts the incarnation once the load is not interrupted.
        let control = try await harness.viewModel.ensureSessionReady(tabID: UUID())
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: existingID, on: control))
        let controlOutcome = await harness.viewModel.hydrateMaterializedRemoteSession(control)
        XCTAssertEqual(controlOutcome, .adoptedExisting)
        XCTAssertTrue(control.hasLoadedPersistedState)
        XCTAssertEqual(control.persistedIncarnationSessionID, existingID)
        XCTAssertNotNil(control.persistenceState(for: existingID))
    }

    func testObsoleteFailingLoadCannotOverwriteTheCurrentOwnersLoadOutcome() async throws {
        let harness = try await makeHarness(windowID: 4374)
        let previousID = UUID()
        let replacementID = UUID()
        // B is a valid earlier incarnation; A's file is unreadable so its load fails.
        _ = try await harness.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: replacementID, workspaceID: harness.workspace.id, name: "Replacement"),
            for: harness.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let files = try await harness.viewModel.test_dataService.listAgentSessions(for: harness.workspace)
        let sessionsFolder = try XCTUnwrap(files.first?.deletingLastPathComponent())
        try Data("not a session".utf8).write(to: sessionsFolder.appendingPathComponent("AgentSession-\(previousID.uuidString).json"))

        let tabID = UUID()
        let session = try await harness.viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: previousID, on: session))
        let previousGate = DispatchGate()
        let replacementGate = DispatchGate()
        harness.viewModel.test_persistedLoadBeforePrepareHook = { [previousGate] held in
            guard held.activeAgentSessionID == previousID else { return }
            await previousGate.waitForRelease()
        }
        harness.viewModel.test_persistedLoadPrepareHook = { [replacementGate] held in
            guard held.activeAgentSessionID == replacementID else { return }
            await replacementGate.waitForRelease()
        }

        // A's load is held before preparation; the tab is rebound to B and B's replacement load
        // runs until it has prepared its payload.
        let previousLoad = Task { @MainActor in
            await harness.viewModel.hydrateMaterializedRemoteSession(session)
        }
        try await waitUntil("A's load held before preparation") { previousGate.isWaiting }
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: replacementID, on: session))
        let replacementLoad = Task { @MainActor in
            await harness.viewModel.hydrateMaterializedRemoteSession(session)
        }
        try await waitUntil("B's load held after preparation") { replacementGate.isWaiting }
        let replacementTask = try XCTUnwrap(session.persistedLoadTask, "B's load owns the task handle")

        // A's delayed failure lands while B is still in flight.
        previousGate.release()
        let previousOutcome = await previousLoad.value
        XCTAssertEqual(previousOutcome, .rejected)
        XCTAssertNotEqual(session.persistedLoadDisposition, .failed, "An obsolete failure never publishes onto the current owner")
        XCTAssertTrue(session.persistedLoadTask == replacementTask, "A's cleanup never erases B's task handle")
        XCTAssertFalse(session.hasLoadedPersistedState, "A's failure never declares the rebound tab loaded")
        XCTAssertNil(session.persistenceState)

        replacementGate.release()
        let replacementOutcome = await replacementLoad.value
        harness.viewModel.test_persistedLoadBeforePrepareHook = nil
        harness.viewModel.test_persistedLoadPrepareHook = nil
        XCTAssertEqual(replacementOutcome, .adoptedExisting, "B consumes its own operation's outcome")
        XCTAssertEqual(session.persistedLoadDisposition, .applied)
        XCTAssertTrue(session.hasLoadedPersistedState)
        XCTAssertEqual(session.persistedIncarnationSessionID, replacementID)
        XCTAssertNotNil(session.persistenceState(for: replacementID))
        XCTAssertNil(session.persistedLoadTask)
    }

    func testCancelledSameBindingLoadCannotClearTheReplacementLoadsReadiness() async throws {
        let harness = try await makeHarness(windowID: 4375)
        let existingID = UUID()
        _ = try await harness.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: existingID, workspaceID: harness.workspace.id, name: "Existing"),
            for: harness.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let tabID = UUID()
        let session = try await harness.viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: existingID, on: session))

        // Load A is held after preparation; only the first load is held.
        let holds = DispatchProbe()
        let gate = DispatchGate()
        harness.viewModel.test_persistedLoadPrepareHook = { [gate, holds] _ in
            holds.startCount += 1
            if holds.startCount == 1 {
                await gate.waitForRelease()
            }
        }
        let firstLoad = Task { @MainActor in
            await harness.viewModel.hydrateMaterializedRemoteSession(session)
        }
        try await waitUntil("A held after preparation") { gate.isWaiting }

        // Cancellation without rebinding (what a removal preflight/teardown does before a veto),
        // then the same binding is hydrated again: B applies its paired payload.
        harness.viewModel.cancelPersistedLoad(for: session)
        let replacementOutcome = await harness.viewModel.hydrateMaterializedRemoteSession(session)
        XCTAssertEqual(replacementOutcome, .adoptedExisting)
        XCTAssertTrue(session.hasLoadedPersistedState)
        XCTAssertEqual(session.persistedLoadDisposition, .applied)
        XCTAssertNotNil(session.persistenceState(for: existingID))
        XCTAssertEqual(holds.startCount, 2)

        // A's late result: obsolete for the same binding.
        gate.release()
        let obsoleteOutcome = await firstLoad.value
        harness.viewModel.test_persistedLoadPrepareHook = nil
        XCTAssertEqual(obsoleteOutcome, .rejected)
        XCTAssertTrue(session.hasLoadedPersistedState, "An obsolete same-binding load never clears the replacement's readiness")
        XCTAssertEqual(session.persistedLoadDisposition, .applied, "An obsolete same-binding load never publishes over the current outcome")
        XCTAssertNotNil(session.persistenceState(for: existingID))
        XCTAssertEqual(session.persistedIncarnationSessionID, existingID)
        XCTAssertNil(session.persistedLoadTask)
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
                .appendingPathComponent("AgentScheduledSendDispatchTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
        let workspace = existingWorkspace ?? WorkspaceModel(
            name: "Agent Scheduled Send Dispatch",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in DispatchNoopCodexController() }
        )
        viewModel.test_persistenceWorkspaceOverride = workspace
        // The view model uses the shared data service; never leak an injector across tests.
        addTeardownBlock {
            await AgentSessionDataService.shared.test_setScheduledSendRecoveryFailureInjector(nil)
        }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try! await viewModel.ensureSessionReady(tabID: tabID)
        return Harness(
            viewModel: viewModel,
            workspace: workspace,
            storageURL: storageURL,
            tabID: tabID,
            session: session
        )
    }

    private func claimComposer(_ harness: Harness, draft: String) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(
            harness.viewModel.makeComposerSubmitTarget(tabID: harness.tabID, session: harness.session)
        )
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: draft
        )
        switch harness.viewModel.claimComposerSubmitAttempt(attempt) {
        case let .claimed(claim):
            return claim
        case let .rejected(rejection):
            throw ClaimRejected(reason: rejection.diagnosticReason)
        }
    }

    private struct ClaimRejected: Error {
        let reason: String
    }

    private func makeManagedAttachmentFile(in workspaceDirectory: URL, name: String) throws -> URL {
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let fileURL = storageRoot.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        return fileURL
    }

    private func makeRecord(notBefore: Date) -> AgentScheduledSendPersist {
        let createdAt = notBefore.addingTimeInterval(-900)
        return AgentScheduledSendPersist(
            id: UUID(),
            createdAt: createdAt,
            updatedAt: createdAt,
            notBefore: notBefore,
            state: .scheduled,
            confirmationReason: nil,
            rawText: "Persisted text",
            attachments: [],
            taggedFileAttachments: [],
            workflow: nil,
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )
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
                throw DispatchWaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct DispatchWaitTimeout: Error {}

private struct InjectedDispatchRecoveryFailure: Error {}

private struct InjectedResyncReadFailure: Error {}

/// Main-actor switch for the view model's authoritative-resync read injector.
@MainActor
private final class ResyncReadFailureSwitch {
    var failing = true
    var attempts = 0
}

@MainActor
private func isWaitingToRetry(_ phase: AgentScheduledSendRecoveryPhase?) -> Bool {
    if case .waitingToRetry? = phase { return true }
    return false
}

/// Thread-safe recovery failure injector state (the data-service actor invokes it off-main).
private final class DispatchRecoveryFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _failing = true
    private var _callCount = 0

    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func next() -> Error? {
        lock.withLock {
            _callCount += 1
            return _failing ? InjectedDispatchRecoveryFailure() : nil
        }
    }
}

@MainActor
private final class DispatchProbe {
    var dispatchedTabID: UUID?
    var providerText: String?
    var diskStateAtHandoff: AgentScheduledSendPersist.State?
    var userItemsAtHandoff: [AgentChatItem] = []
    var startCount = 0
    var createdTabIDs: [UUID] = []
}

/// Holds a dispatch inside the provider handoff until the test releases it.
@MainActor
private final class DispatchGate {
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
private final class DispatchFakeClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []
    private var nextProbe: SchedulerClockProbe = .none

    init(now: Date) {
        self.now = now
    }

    var clock: SchedulerClock {
        SchedulerClock(
            now: { [weak self] in
                self?.now ?? .distantPast
            },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await sleep(until: deadline)
            },
            probe: { [weak self] in
                guard let self else { return .none }
                let probe = nextProbe
                nextProbe = .none
                return probe
            }
        )
    }

    func advance(to date: Date, probe: SchedulerClockProbe = .none) {
        setNow(max(now, date), probe: probe)
    }

    /// Moves the wall clock in either direction; a backward move models a system clock rollback.
    func setNow(_ date: Date, probe: SchedulerClockProbe = .none) {
        now = date
        nextProbe = probe
        let ready = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    private func sleep(until deadline: Date) async throws {
        if deadline <= now { return }
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }
}

private final class DispatchNoopCodexController: CodexSessionControlling {
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
    func startOrResume(existing _: CodexNativeSessionController.SessionRef?, baseInstructions _: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil, runtimeStatus: .idle, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: nil)
    }

    func startUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(text _: String, images _: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
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
