import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Delegated `ask_user` escalation in `AgentModeViewModel` (plan §6): audience install, paused and
/// fallback timeouts, notice handoff de-duplication, idle next-turn staging, and legibility surfaces.
@MainActor
final class AgentModeViewModelDelegatedQuestionTests: XCTestCase {
    // MARK: - Audience install and timeout pause (§6.1, §6.4)

    func testQuestionAddressedToLiveParentPausesTimeoutAndRegistersNotice() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 0.05)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        XCTAssertNil(child.session.pendingAskUser?.timeoutStartedAt, "No countdown while the parent agent owns the question")
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.parentSessionID, parent.sessionID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)

        // Well past the child's own timeout, the question is still pending.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id)

        // Card activity never restarts a paused timeout.
        vm.noteAskUserCardActivity(tabID: child.tabID, interactionID: interaction.id)
        XCTAssertNil(child.session.pendingAskUser?.timeoutStartedAt)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        let response = try await task.value
        XCTAssertTrue(response.skipped)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty, "Resolving the question drops its notice")
    }

    func testParentClosingFallsBackToUserWithAFreshTimeout() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 0.2)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(child.session.pendingAskUser, "Paused: the original deadline passed without a timeout")

        let fallbackStart = Date()
        vm.test_removeLiveSession(tabID: parent.tabID)

        let pending = try XCTUnwrap(child.session.pendingAskUser)
        XCTAssertEqual(pending.delegatedRouting, .userFallback)
        let startedAt = try XCTUnwrap(pending.timeoutStartedAt)
        XCTAssertGreaterThanOrEqual(startedAt, fallbackStart, "The fallback timeout starts at the fallback, not at askedAt")
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[child.sessionID]?.ownQuestion, .needsUserAnswer)

        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "timeout")
    }

    func testMCPControlTeardownFallsBackToUserAndNeverRepauses() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        vm.test_setMCPControlledTabIDs([])
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .userFallback)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)

        // Control returning does not re-pause a question that already fell back.
        vm.test_setMCPControlledTabIDs([child.tabID])
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .userFallback)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testUnverifiedControlledRootFallsBackAndVerifiedExternalControllerIsUnchanged() async throws {
        let vm = makeViewModel()
        let connectionID = UUID()
        let root = makeSession(vm, parent: nil, originatingConnectionID: connectionID)
        vm.test_setMCPControlledTabIDs([root.tabID])

        XCTAssertEqual(vm.delegatedQuestionAudience(for: root.session, provenance: .unverified), .userFallback)
        XCTAssertEqual(
            vm.delegatedQuestionAudience(
                for: root.session,
                provenance: .init(verifiedNonAgentModeConnectionID: UUID())
            ),
            .userFallback,
            "Verification of a different connection never applies"
        )
        let verified = AgentDelegatedQuestionControllerProvenance(verifiedNonAgentModeConnectionID: connectionID)
        XCTAssertEqual(vm.delegatedQuestionAudience(for: root.session, provenance: verified), .externalController)

        let interaction = makeInteraction(timeoutSeconds: 60)
        let task = Task {
            try await vm.askUser(tabID: root.tabID, interaction: interaction, controllerProvenance: verified)
        }
        try await waitUntil { root.session.askUserContinuation != nil }
        XCTAssertEqual(root.session.pendingAskUser?.delegatedRouting, .direct)
        XCTAssertNotNil(root.session.pendingAskUser?.timeoutStartedAt)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)

        vm.skipAskUser(tabID: root.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testUncontrolledSessionKeepsDirectRouting() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID, controlled: false)
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.askUserContinuation != nil }
        XCTAssertEqual(child.session.pendingAskUser?.delegatedRouting, .direct)
        XCTAssertNotNil(child.session.pendingAskUser?.timeoutStartedAt)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Tool-result handoff (§6.2)

    func testHandoffDeliversOncePerNoticeAndNeverToTheSameOrALaterRunAgain() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runA = UUID()
        parent.session.runID = runA
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: []))
        XCTAssertFalse(
            vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: [child.sessionID]),
            "A wait already covering the asking child is not woken for it"
        )
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: UUID(), excludingChildSessionIDs: []))
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.waitingForNextTurn])
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.undeliveredChildQuestionCount, 1)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[child.sessionID]?.ownQuestion, .waitingOnParentAgent)

        let delivered = vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runA, coveredKeys: [])
        XCTAssertEqual(delivered.map(\.key.interactionID), [interaction.id])
        XCTAssertEqual(delivered.first?.childSessionName, "Agent Session")

        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runA, coveredKeys: []).isEmpty)
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runA, excludingChildSessionIDs: []))
        // A provider that reuses its process run ID, or a later run, never sees an acknowledged notice again.
        let runB = UUID()
        parent.session.runID = runB
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runB, coveredKeys: []).isEmpty)
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.delivered])
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.pendingChildQuestionCount, 1)
        XCTAssertEqual(vm.delegatedQuestionSidebarAttentionBySessionID()[parent.sessionID]?.undeliveredChildQuestionCount, 0)
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id, "Delivery never resolves the question")

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        XCTAssertTrue(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).isEmpty)
    }

    func testCoveredKeysAcknowledgeWithoutReturningAPayload() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = UUID()
        parent.session.runID = runID
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: [key]).isEmpty)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Idle parent: next turn's first input (§6.2)

    func testIdleParentNoticeIsStagedIntoProviderInputAndCommittedAsSystemNoteOnlyAfterSend() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let itemCountBefore = parent.session.items.count

        let staged = vm.stageDelegatedQuestionNoticesForTurnInput("user text", session: parent.session)
        XCTAssertTrue(staged.hasPrefix("<repoprompt_runtime_notice kind=\"delegated_child_questions\">\n"))
        XCTAssertTrue(staged.hasSuffix("</repoprompt_runtime_notice>\n\nuser text"))
        XCTAssertTrue(staged.contains(interaction.id.uuidString))
        XCTAssertEqual(parent.session.items.count, itemCountBefore, "Staging never writes to the transcript or user text")

        // A failed send rolls the stage back; the notice stays deliverable.
        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, didSend: false)
        XCTAssertTrue(vm.delegatedQuestionNotices.stagedTurnNoticesByParentTabID.isEmpty)
        XCTAssertEqual(parent.session.items.count, itemCountBefore)
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)

        let restaged = vm.stageDelegatedQuestionNoticesForTurnInput("next", session: parent.session)
        XCTAssertTrue(restaged.hasSuffix("\n\nnext"))
        let runID = UUID()
        parent.session.runID = runID
        // While staged, the tool-result path never double-delivers the same notice.
        XCTAssertTrue(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []).isEmpty)

        vm.recordDelegatedQuestionNoticeSendOutcome(for: parent.session, didSend: true)
        XCTAssertEqual(parent.session.items.count, itemCountBefore + 1)
        let note = try XCTUnwrap(parent.session.items.last)
        XCTAssertEqual(note.kind, .system)
        XCTAssertTrue(note.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader))
        XCTAssertTrue(note.text.contains(child.sessionID.uuidString))
        XCTAssertTrue(note.text.contains(interaction.id.uuidString))
        XCTAssertTrue(parent.session.isDirty, "The note is saved with the parent transcript")
        // The persisted note reaches the parent's transcript projection as a labeled, ID-bearing row.
        vm.refreshDerivedTranscriptState(for: parent.session)
        let projected = try XCTUnwrap(parent.session.workingTranscriptProjection.workingRows.last)
        XCTAssertEqual(projected.kind, .system)
        XCTAssertTrue(projected.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader))
        XCTAssertTrue(projected.text.contains(child.sessionID.uuidString))
        XCTAssertTrue(projected.text.contains(interaction.id.uuidString))
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])

        XCTAssertEqual(
            vm.stageDelegatedQuestionNoticesForTurnInput("later", session: parent.session),
            "later",
            "An acknowledged notice is never staged again"
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Reserved tool-result handoff (§6.2: cancellation never consumes a notice)

    func testReservedNoticeIsNotConsumedUntilCommitAndReleaseRestoresDelivery() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = UUID()
        parent.session.runID = runID
        parent.session.runState = .running
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)

        let first = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []))
        XCTAssertEqual(first.payloads.map(\.key), [key])
        XCTAssertEqual(first.parentRunID, runID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, "Reserving never acknowledges")
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [])
        XCTAssertFalse(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertNil(
            vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []),
            "A concurrent result never carries a notice already reserved by another result"
        )

        // Cancelled or failed before handoff: the notice is deliverable again to the same run.
        vm.mcpReleaseDelegatedQuestionNoticeReservation(first.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        XCTAssertTrue(vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: []))
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.awaitingNextToolResult])

        // Handed off: committed exactly once.
        let second = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []))
        XCTAssertEqual(second.payloads.map(\.key), [key])
        vm.mcpCommitDelegatedQuestionNoticeReservation(second.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
        XCTAssertNil(vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []))
        // Late finishes of settled reservations are no-ops.
        vm.mcpReleaseDelegatedQuestionNoticeReservation(second.id)
        vm.mcpReleaseDelegatedQuestionNoticeReservation(first.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
        XCTAssertEqual(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).map(\.status), [.delivered])

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    func testReconcileReleasesReservationWhoseRunStoppedAndCommitAfterResolutionIsNoOp() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = UUID()
        parent.session.runID = runID
        parent.session.runState = .running
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)

        let stranded = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []))
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNotNil(vm.delegatedQuestionNotices.records[key]?.reservationID, "An active run keeps its in-flight reservation")

        parent.session.runState = .idle
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty, "A run that stopped can no longer receive the result")
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.reservationID)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false)
        vm.mcpCommitDelegatedQuestionNoticeReservation(stranded.id)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, "A released reservation never commits later")

        parent.session.runState = .running
        let pending = try XCTUnwrap(vm.mcpReserveDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []))
        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        XCTAssertNil(vm.delegatedQuestionNotices.records[key])
        vm.mcpCommitDelegatedQuestionNoticeReservation(pending.id)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key], "Committing after the question resolved changes nothing")
        XCTAssertTrue(vm.delegatedQuestionNotices.reservations.isEmpty)
    }

    // MARK: - Idle staging release on start/send failure (§6.2)

    func testStartThatNeverSentReleasesTheStagedTurnNotice() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let key = AgentDelegatedQuestionNoticeKey(childSessionID: child.sessionID, interactionID: interaction.id)
        let itemCount = parent.session.items.count

        // Refused or failed before the provider: the run never became active.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("one", session: parent.session)
        let refusedStage = vm.delegatedQuestionTurnStageID(forTabID: parent.tabID)
        XCTAssertNotNil(refusedStage)
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertNotNil(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), "A start in flight keeps its stage")
        vm.settleDelegatedQuestionTurnStageAfterRunStart(refusedStage, session: parent.session, startReportedNoSend: false)
        assertReleased(vm, key: key, parentTabID: parent.tabID)

        // The start reported no send (stale, cancelled, or failed) even though a run is active.
        parent.session.runState = .running
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("two", session: parent.session)
        let failedStage = vm.delegatedQuestionTurnStageID(forTabID: parent.tabID)
        vm.settleDelegatedQuestionTurnStageAfterRunStart(failedStage, session: parent.session, startReportedNoSend: true)
        assertReleased(vm, key: key, parentTabID: parent.tabID)

        // Started, but the run stopped without ever reporting a send outcome.
        _ = vm.stageDelegatedQuestionNoticesForTurnInput("three", session: parent.session)
        let startedStage = vm.delegatedQuestionTurnStageID(forTabID: parent.tabID)
        vm.settleDelegatedQuestionTurnStageAfterRunStart(UUID(), session: parent.session, startReportedNoSend: true)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage, "Settling never touches another stage")
        vm.settleDelegatedQuestionTurnStageAfterRunStart(startedStage, session: parent.session, startReportedNoSend: false)
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage, "An active run awaits its send outcome")
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        XCTAssertEqual(vm.delegatedQuestionTurnStageID(forTabID: parent.tabID), startedStage)
        parent.session.runState = .failed
        vm.reconcileDelegatedQuestionNotices(trigger: "test")
        assertReleased(vm, key: key, parentTabID: parent.tabID)

        XCTAssertEqual(parent.session.items.count, itemCount, "Released stages never write a transcript note")
        let nextRunID = UUID()
        parent.session.runID = nextRunID
        parent.session.runState = .running
        XCTAssertEqual(
            vm.mcpHandOffDelegatedQuestionNotices(parentRunID: nextRunID, coveredKeys: []).map(\.key),
            [key],
            "The released notice is still delivered later"
        )

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
    }

    // MARK: - Answer authority races (§6.7: existing first-wins paths, no new mechanism)

    func testUserAnswerInChildTabWinsOverALaterParentRespond() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let runID = UUID()
        parent.session.runID = runID
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        // The parent already saw the notice.
        XCTAssertEqual(vm.mcpHandOffDelegatedQuestionNotices(parentRunID: runID, coveredKeys: []).count, 1)

        try vm.submitAskUserResponse(
            tabID: child.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["choice": AgentAskUserDraft(selectedOptionLabels: ["A"])]
        )
        do {
            _ = try await vm.mcpResolvePendingInteraction(
                sessionID: child.sessionID,
                interactionID: interaction.id,
                payload: parentAnswer("B"),
                resolvedBy: "parent-agent"
            )
            XCTFail("A respond for an already-answered question must be rejected")
        } catch {}

        let response = try await task.value
        XCTAssertEqual(response.answersByQuestionID["choice"]?.answers, ["A"])
        XCTAssertEqual(child.session.lastInteractionResolution?.interactionID, interaction.id)
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "user")
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
        XCTAssertTrue(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).isEmpty)
    }

    func testParentRespondWinsOverALaterUserSubmitAndStaleIDsAreRejected() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }

        do {
            _ = try await vm.mcpResolvePendingInteraction(
                sessionID: child.sessionID,
                interactionID: UUID(),
                payload: parentAnswer("B"),
                resolvedBy: "parent-agent"
            )
            XCTFail("A respond carrying a different interaction ID must be rejected")
        } catch {}
        XCTAssertEqual(child.session.pendingAskUser?.interaction.id, interaction.id, "A rejected respond changes nothing")

        _ = try await vm.mcpResolvePendingInteraction(
            sessionID: child.sessionID,
            interactionID: interaction.id,
            payload: parentAnswer("B"),
            resolvedBy: "parent-agent"
        )
        // The user's late submit in the child tab is a no-op: the first resolution won.
        try vm.submitAskUserResponse(
            tabID: child.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["choice": AgentAskUserDraft(selectedOptionLabels: ["A"])]
        )

        let response = try await task.value
        XCTAssertEqual(response.answersByQuestionID["choice"]?.answers, ["B"])
        XCTAssertEqual(child.session.lastInteractionResolution?.resolvedBy, "parent-agent")
        XCTAssertNil(child.session.pendingAskUser)
        XCTAssertTrue(vm.delegatedQuestionNotices.records.isEmpty)
    }

    func testOpenChildActionRefusesOnceTheQuestionResolved() async throws {
        let vm = makeViewModel()
        let parent = makeSession(vm, parent: nil)
        let child = makeSession(vm, parent: parent.sessionID)
        vm.test_setMCPControlledTabIDs([child.tabID])
        let interaction = makeInteraction(timeoutSeconds: 60)

        let task = Task { try await vm.askUser(tabID: child.tabID, interaction: interaction) }
        try await waitUntil { child.session.pendingAskUser?.isAwaitingParentAgent == true }
        let row = try XCTUnwrap(vm.delegatedQuestionBannerRows(forParentTabID: parent.tabID).first)
        XCTAssertEqual(row.childTabID, child.tabID)
        let openError = await vm.openDelegatedQuestionChild(row)
        XCTAssertNil(openError)

        vm.skipAskUser(tabID: child.tabID, interactionID: interaction.id)
        _ = try await task.value
        let staleError = await vm.openDelegatedQuestionChild(row)
        XCTAssertEqual(staleError, "That child question is no longer pending.")
    }

    // MARK: - Helpers

    private struct LiveSession {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    private func makeSession(
        _ vm: AgentModeViewModel,
        parent: UUID?,
        controlled: Bool = true,
        originatingConnectionID: UUID? = nil
    ) -> LiveSession {
        let tabID = UUID()
        let sessionID = UUID()
        let session = vm.session(for: tabID, createIfNeeded: true)!
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parent
        session.hasLoadedPersistedState = true
        if controlled, parent != nil || originatingConnectionID != nil {
            session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: originatingConnectionID,
                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: originatingConnectionID),
                suppressUserNotifications: true,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: false,
                taskLabelKind: .engineer
            )
        }
        return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
    }

    private func makeInteraction(timeoutSeconds: TimeInterval) -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            timeoutSeconds: timeoutSeconds,
            questions: [
                AgentAskUserQuestion(
                    id: "choice",
                    question: "Which option?",
                    options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
                    allowsCustom: true
                )
            ]
        )
    }

    private func parentAnswer(_ text: String) -> AgentModeViewModel.MCPInteractionResponsePayload {
        AgentModeViewModel.MCPInteractionResponsePayload(
            text: text,
            skip: false,
            decisionRaw: nil,
            amendment: nil,
            answersByQuestionID: [:]
        )
    }

    private func assertReleased(
        _ vm: AgentModeViewModel,
        key: AgentDelegatedQuestionNoticeKey,
        parentTabID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(vm.delegatedQuestionTurnStageID(forTabID: parentTabID), file: file, line: line)
        XCTAssertNil(vm.delegatedQuestionNotices.records[key]?.stagedParentTabID, file: file, line: line)
        XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, false, file: file, line: line)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
