import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Lossless-restart Phase 1b: VM producers under mandatory admission with an injected coordinator,
/// a real temporary recovery store, and the real DataService gate. Every user input is committed as
/// a `queued` intent before its optimistic bubble, carried unchanged to the provider route, and
/// settled by real dispatch evidence; a failed commit projects, sends, and acknowledges nothing.
@MainActor
final class AgentRecoveryVMProducerAdmissionTests: XCTestCase {
    /// A bound session's active Codex turn (its run attempt began after the session's persistent
    /// binding, as in production): the composer input commits its intent and the steer reaches the
    /// provider under that intent and run attempt, which settles `providerAccepted`.
    func testMandatoryComposerSteerIntoBoundActiveRunCommitsIntentThenSteersUnderItsIdentity() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4701, controller: controller)
        _ = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        harness.viewModel.storeDraftText(for: harness.tabID, "steer me")

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "steer me",
            tabID: harness.tabID,
            origin: .composer
        )

        XCTAssertEqual(result, .submitted)
        let lane = try XCTUnwrap(harness.session.recoveryLane, "Admission established the tab's authority")
        XCTAssertEqual(lane.sessionID, harness.session.activeAgentSessionID)

        let intent = try await waitForSingleIntent(lane, state: .providerAccepted, session: harness.session)
        XCTAssertEqual(controller.steerTexts, ["steer me"])
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        XCTAssertTrue(harness.session.codexFallbackQueue.isEmpty)
        let bubble = try XCTUnwrap(harness.session.items.last { $0.kind == .user })
        XCTAssertEqual(bubble.text, "steer me")
        XCTAssertEqual(intent.userItemID, bubble.id, "The bubble is the committed intent's user item")
        XCTAssertEqual(intent.origin, .composer)
        XCTAssertEqual(intent.payload.text, "steer me")
        let attemptID = try XCTUnwrap(harness.session.activeRunAttemptID)
        XCTAssertEqual(intent.target, .liveRun(AgentRecoveryRunTarget(
            runAttemptID: attemptID,
            processRunID: harness.session.runID,
            providerConversationID: "fake"
        )))
        XCTAssertNil(intent.pendingHandoff)
        let readAfterSteer = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(readAfterSteer.record)
        XCTAssertEqual(record.attempts.map(\.runAttemptID), [attemptID], "The steer is joined to the active run attempt")
        XCTAssertEqual(record.runAttempts.map(\.runAttemptID), [attemptID])
        XCTAssertEqual(
            record.runAttempts.map(\.transcriptTurnID),
            [bubble.id],
            "R08: the first recorded input of the run supplies its missing turn join"
        )
    }

    /// A genuinely new, idle tab through the normal start path: admission establishes the tab's
    /// durable authority first, the run attempt is created downstream under that binding, its run
    /// record is on disk before the provider is called, and the first message is accepted joined to it.
    func testMandatoryFirstComposerSendOnIdleNewTabStartsRunUnderItsPersistentBinding() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4712, controller: controller)
        let session = harness.session
        XCTAssertNil(session.recoveryLane, "The new tab has no authority before its first input")
        XCTAssertNil(session.activeRunOwnership, "The new tab has no run before its first input")
        session.selectedAgent = .codexExec
        session.codexControllerWorkspacePath = harness.workspacePath
        var recordAtStart: AgentRecoveryRecord?
        var ownershipAtStart: AgentRunOwnership?
        controller.onStart = { @MainActor in
            ownershipAtStart = session.activeRunOwnership
            if let lane = session.recoveryLane {
                recordAtStart = await lane.store.read(sessionID: lane.sessionID).record
            }
        }
        harness.viewModel.storeDraftText(for: harness.tabID, "first message")

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "first message",
            tabID: harness.tabID,
            origin: .composer
        )

        XCTAssertEqual(result, .submitted)
        let lane = try XCTUnwrap(session.recoveryLane, "Admission established the tab's authority")
        let intent = try await waitForSingleIntent(lane, state: .providerAccepted, session: session)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(intent.payload.text, "first message")
        let ownership = try XCTUnwrap(ownershipAtStart, "The run attempt existed when the provider was called")
        XCTAssertEqual(ownership.binding.persistentSessionID, lane.sessionID, "Ownership was created under the persistent binding")
        let atStart = try XCTUnwrap(recordAtStart, "The record was on disk before the provider call")
        XCTAssertEqual(atStart.runAttempts.map(\.runAttemptID), [ownership.attemptID], "Run evidence precedes the handoff")
        XCTAssertEqual(
            atStart.runAttempts.map(\.transcriptTurnID),
            [intent.userItemID],
            "R08: the run is joined to the turn its first input opened"
        )
        XCTAssertEqual(atStart.intents.map(\.deliveryState), [.dispatching])
        XCTAssertEqual(atStart.attempts.map(\.runAttemptID), [ownership.attemptID])
        let readAfterStart = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(readAfterStart.record)
        XCTAssertEqual(record.attempts.map(\.runAttemptID), [ownership.attemptID], "No replacement attempt was invented")
    }

    /// A run attempt that began before the tab's persistent binding (its immutable ownership names no
    /// persistent session) cannot be this lane's run evidence: the steer is refused before any
    /// write, nothing reaches Codex, no ownership is rewritten, and the saved input is held visibly.
    func testSteerUnderOwnershipCreatedBeforeTheBindingIsRefusedWithInputHeld() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4713, controller: controller)
        let session = harness.session
        XCTAssertNil(session.recoveryLane)
        prepareActiveCodexTurn(harness, controller: controller)
        let ownershipBefore = try XCTUnwrap(session.activeRunOwnership)
        XCTAssertNil(ownershipBefore.binding.persistentSessionID)

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "steer me",
            tabID: harness.tabID,
            origin: .composer
        )

        XCTAssertEqual(result, .submitted)
        let lane = try XCTUnwrap(session.recoveryLane)
        let record = try await waitForRecord(lane, "the refused input held as a stale target") {
            $0.intents.count == 1 && $0.intents[0].staleTargetMarkedAt != nil
        }
        XCTAssertEqual(record.intents.map(\.deliveryState), [.queued], "The input stays saved and undelivered")
        XCTAssertTrue(record.attempts.isEmpty, "No delivery attempt was written")
        XCTAssertTrue(record.runAttempts.isEmpty, "No run evidence was written for the foreign ownership")
        XCTAssertTrue(controller.steerTexts.isEmpty, "Nothing reached Codex")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(
            session.items.contains { $0.kind == .error && $0.text == CodexAgentModeCoordinator.codexOwnershipRefusedMessage },
            "The refusal is explained"
        )
        if let ownershipAfter = session.activeRunOwnership {
            XCTAssertEqual(ownershipAfter, ownershipBefore, "The ownership token is never rewritten")
        }
    }

    /// An MCP instruction into the live run commits its own `mcp` intent, never consumes the
    /// composer, and is provider-accepted under that intent.
    func testMandatoryMCPSendCommitsMCPIntentWithoutConsumingComposer() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4702, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        harness.viewModel.storeDraftText(for: harness.tabID, "composer draft kept")

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "  from mcp  ",
            tabID: harness.tabID,
            origin: .mcp
        )

        XCTAssertEqual(result, .submitted)
        let intent = try await waitForSingleIntent(lane, state: .providerAccepted, session: harness.session)
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        let bubble = try XCTUnwrap(harness.session.items.last { $0.kind == .user })
        XCTAssertEqual(intent.userItemID, bubble.id)
        XCTAssertEqual(intent.origin, .mcp)
        XCTAssertEqual(intent.payload.text, "from mcp")
        XCTAssertEqual(
            harness.viewModel.retrieveDraftText(for: harness.tabID),
            "composer draft kept",
            "An MCP input never consumes the composer"
        )
    }

    /// The intent cannot be written: nothing is projected, sent, or acknowledged, the composer and
    /// pending handoff are kept, and no intent exists afterwards.
    func testMandatoryComposerCommitFailureProjectsSendsAndAcknowledgesNothing() async throws {
        let controller = ProducerFakeCodexController(steerError: Self.noActiveTurnError)
        let harness = try await makeHarness(windowID: 4703, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        let handoffID = UUID()
        harness.session.pendingHandoff = .init(payload: "<forked_session>kept</forked_session>", payloadID: handoffID)
        harness.viewModel.storeDraftText(for: harness.tabID, "typed but unsaved")
        let itemsBefore = harness.session.items.map(\.id)

        let sessionsDirectory = lane.store.sessionsDirectoryURL
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let originalPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionsDirectory.path)[.posixPermissions] as? NSNumber
        )
        var permissionsRestored = false
        defer {
            if !permissionsRestored {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: sessionsDirectory.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionsDirectory.path)

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "typed but unsaved",
            tabID: harness.tabID,
            origin: .composer
        )

        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: sessionsDirectory.path)
        permissionsRestored = true

        XCTAssertEqual(result, .blocked(message: AgentModeViewModel.recoveryAdmissionFailedMessage))
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "No optimistic bubble")
        XCTAssertTrue(controller.steerTurnIDs.isEmpty, "Nothing reached the provider")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(harness.session.codexFallbackQueue.isEmpty, "No queue acknowledgement")
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "typed but unsaved")
        XCTAssertEqual(harness.session.pendingHandoff.payloadID, handoffID, "The pending handoff is kept")
        XCTAssertEqual(harness.session.pendingHandoff.payload, "<forked_session>kept</forked_session>")
        XCTAssertTrue(harness.session.recoveryLane === lane)
        XCTAssertFalse(lane.isRetired)
        let record = await lane.store.read(sessionID: lane.sessionID).record
        XCTAssertEqual(record?.intents.map(\.payload.text) ?? [], [], "No intent was committed")
    }

    /// A legacy pending handoff (no payload ID) gets its ID through a fenced session save, and the
    /// exact prefix is on the committed intent before the provider is called, and therefore before
    /// the fallback queue acknowledgement that could clear it.
    func testLegacyPendingHandoffSnapshotIsDurableBeforeProviderAndQueueAck() async throws {
        let controller = ProducerFakeCodexController(steerError: Self.noActiveTurnError)
        let harness = try await makeHarness(windowID: 4704, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        let payload = "<forked_session>carried history</forked_session>"
        harness.session.pendingHandoff = .init(payload: payload, createdAt: Date())
        XCTAssertNil(harness.session.pendingHandoff.payloadID)

        var observedAtProvider: (intent: AgentRecoveryIntent?, sessionPayloadID: UUID?, fileText: String?)?
        controller.onSteer = { [harness] in
            let record = await lane.store.read(sessionID: lane.sessionID).record
            let fileText = try? await harness.persistedFileText()
            observedAtProvider = (record?.intents.first, harness.session.pendingHandoff.payloadID, fileText)
        }

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "after the handoff",
            tabID: harness.tabID,
            origin: .composer
        )

        XCTAssertEqual(result, .submitted)
        // The fallback queue acknowledgement follows the provider call, under the same intent.
        let entry = try await waitForFallbackEntry(harness.session)
        let atProvider = try XCTUnwrap(observedAtProvider, "The provider was called")
        let assignedID = try XCTUnwrap(atProvider.sessionPayloadID, "The legacy payload was assigned an ID")
        let snapshot = try XCTUnwrap(atProvider.intent?.pendingHandoff, "The snapshot is committed before the provider call")
        XCTAssertEqual(snapshot.payloadID, assignedID)
        XCTAssertEqual(snapshot.payload, payload)
        XCTAssertEqual(snapshot.prependedText, payload + "\n\n")
        XCTAssertEqual(atProvider.intent?.payload.text, "after the handoff", "The user payload never carries the prefix")
        let fileText = try XCTUnwrap(atProvider.fileText)
        XCTAssertTrue(fileText.contains(assignedID.uuidString), "The assigned payload ID was saved before dispatch")
        let steerText = try XCTUnwrap(controller.steerTexts.first)
        XCTAssertTrue(steerText.hasPrefix(snapshot.prependedText), "The provider text carries exactly the recorded prefix")

        let intent = try await waitForSingleIntent(lane, state: .queued, session: harness.session)
        XCTAssertEqual(entry.id, intent.intentID, "The fallback queue ID is the intent ID")
        XCTAssertEqual(intent.pendingHandoff, snapshot, "The snapshot is never replaced or cleared")
    }

    // MARK: - R01: refused composer admission keeps the only recoverable copy

    /// The target went stale after the commit while the live composer still is the exact submitted
    /// draft: the draft is durably written back as the lane's composer first, and only then is the
    /// unprojected intent withdrawn. Nothing is projected or sent.
    func testRefusedComposerAdmissionRestoresDraftDurablyBeforeWithdrawingIntent() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4705, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        harness.viewModel.storeDraftText(for: harness.tabID, "keep me")
        let itemsBefore = harness.session.items.map(\.id)

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "keep me",
            tabID: harness.tabID,
            origin: .composer,
            isStillCurrent: { false }
        )

        XCTAssertEqual(result, .blocked(message: AgentModeViewModel.staleComposerSubmitTargetMessage))
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "No optimistic bubble")
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(controller.steerTexts.isEmpty, "Nothing reached the provider")
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "keep me")
        let read = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(read.record)
        XCTAssertEqual(record.intents.map(\.deliveryState), [.withdrawn], "Withdrawn only after the restore")
        XCTAssertEqual(record.composer?.content.text, "keep me", "The draft was durably restored as the composer")
        XCTAssertTrue(record.attempts.isEmpty, "No dispatch was ever begun")
    }

    /// Newer typing arrived before the refusal: the submitted draft cannot be restored without
    /// overwriting it, so the committed intent stays held (`queued`, the only copy of that input)
    /// and the newer draft is untouched.
    func testRefusedComposerAdmissionWithNewerTypingKeepsIntentHeld() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4706, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        harness.viewModel.storeDraftText(for: harness.tabID, "submitted draft")
        let itemsBefore = harness.session.items.map(\.id)
        let viewModel = harness.viewModel
        let tabID = harness.tabID

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "submitted draft",
            tabID: tabID,
            origin: .composer,
            isStillCurrent: {
                viewModel.storeDraftText(for: tabID, "newer typing")
                return false
            }
        )

        XCTAssertEqual(result, .blocked(message: AgentModeViewModel.staleComposerSubmitTargetMessage))
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "No optimistic bubble")
        XCTAssertTrue(controller.steerTexts.isEmpty)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "newer typing", "Newer typing is never overwritten")
        let intents = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        XCTAssertEqual(intents.map(\.deliveryState), [.queued], "The only copy of the refused input stays held")
        XCTAssertEqual(intents.first?.payload.text, "submitted draft")
        XCTAssertTrue(harness.session.pendingInstructions.isEmpty, "A held intent is never dispatched by this caller")

        // The held intent is listed in this launch, with why it was held, without a restart.
        let intentID = try XCTUnwrap(intents.first?.intentID)
        let rowID = "intent-\(lane.sessionID.uuidString)-\(intentID.uuidString)"
        let session = harness.session
        func row() -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == rowID }
        }
        let listed = await RecoveryTestSupport.eventually { row() != nil }
        XCTAssertTrue(listed, "A current-launch held intent is listed live")
        XCTAssertEqual(row()?.text, "submitted draft")
        XCTAssertEqual(row()?.actions, [.edit, .remove, .dismiss])
        XCTAssertTrue(
            row()?.detail.contains(AgentModeViewModel.refusedSubmissionHoldReason) == true,
            String(describing: row()?.detail)
        )

        // Removing it withdraws the only copy explicitly; the row then leaves.
        await viewModel.performRecoveryListAction(rowID: rowID, action: .remove)
        XCTAssertNil(row())
        let afterRemoval = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        XCTAssertEqual(afterRemoval.map(\.deliveryState), [.withdrawn])
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "newer typing", "Newer typing is still untouched")
    }

    /// Stopping a run ends the live projection of its uncertain input: the possibly delivered
    /// message is listed at once (Remove only, never a resend-capable Edit) and the one whose
    /// handoff was in progress is listed view-only. While the run was open neither had a row.
    func testUncertainInputOfAStoppedRunIsListedLiveWithOnlySafeActions() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4710, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        let viewModel = harness.viewModel
        func admit(_ text: String) async throws -> AgentQueuedInputIdentity {
            let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
                binding: lane.binding,
                userItemID: UUID(),
                origin: .mcp,
                target: .session,
                original: RecoveryTestSupport.content(text)
            )).get()
            return AgentQueuedInputIdentity(receipt: admitted.receipt)
        }
        let unknown = try await admit("possibly delivered")
        let inFlight = try await admit("in progress")
        let ownership = RecoveryTestSupport.ownership(sessionID: lane.sessionID)
        let unknownEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [unknown],
            runAttemptID: ownership.attemptID
        ).get()
        unknownEvidence.noteDeliveryUnknown()
        _ = await unknownEvidence.settled()
        _ = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [inFlight],
            runAttemptID: ownership.attemptID
        ).get()
        let unknownRowID = try "intent-\(lane.sessionID.uuidString)-\(XCTUnwrap(unknown.intentID).uuidString)"
        let inFlightRowID = try "intent-\(lane.sessionID.uuidString)-\(XCTUnwrap(inFlight.intentID).uuidString)"
        func row(_ id: String) -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id == id }
        }
        let adopted = await RecoveryTestSupport.eventually {
            guard case let .supported(record)? = viewModel.recoveryCoordinator?.liveRecordState(for: lane.sessionID) else {
                return false
            }
            return record.intents.map(\.deliveryState) == [.deliveryUnknown, .dispatching]
        }
        XCTAssertTrue(adopted)
        XCTAssertNil(row(unknownRowID), "The open run still owns it")
        XCTAssertNil(row(inFlightRowID))

        await lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .cancelled),
            transcriptTurnID: nil
        ).value

        let listed = await RecoveryTestSupport.eventually { row(unknownRowID) != nil && row(inFlightRowID) != nil }
        XCTAssertTrue(listed, "Stopped-run uncertain input is visible without a restart")
        XCTAssertEqual(row(unknownRowID)?.actions, [.remove, .dismiss])
        XCTAssertEqual(row(inFlightRowID)?.actions, [.dismiss])
        for id in [unknownRowID, inFlightRowID] {
            XCTAssertTrue(
                row(id)?.detail.contains(AgentRecoveryCoordinator.runEndedUnconfirmedHoldReason) == true,
                String(describing: row(id)?.detail)
            )
        }

        await viewModel.performRecoveryListAction(rowID: unknownRowID, action: .remove)
        XCTAssertNil(row(unknownRowID))
        let intents = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        XCTAssertEqual(intents.map(\.deliveryState), [.withdrawn, .dispatching])
        XCTAssertTrue(controller.steerTexts.isEmpty, "Nothing was resent")
    }

    // MARK: - R12: one immutable admitted snapshot

    /// A tagged file added after admission (during the awaits) is not part of this send: the intent
    /// and the provider route carry only the submitted file, and the newer one stays in the composer.
    func testAdmittedSnapshotExcludesComposerChangesMadeDuringAdmission() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4707, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        let submittedTag = AgentTaggedFileAttachment(relativePath: "Submitted.swift", displayName: "Submitted.swift")
        let newerTag = AgentTaggedFileAttachment(relativePath: "Newer.swift", displayName: "Newer.swift")
        let session = harness.session
        session.pendingTaggedFileAttachments = [submittedTag]
        harness.viewModel.storeDraftText(for: harness.tabID, "with a tag")

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "with a tag",
            tabID: harness.tabID,
            origin: .composer,
            isStillCurrent: {
                session.pendingTaggedFileAttachments.append(newerTag)
                return true
            }
        )

        XCTAssertEqual(result, .submitted)
        let intent = try await waitForSingleIntent(lane, state: .providerAccepted, session: session)
        XCTAssertEqual(intent.payload.taggedFiles.map(\.relativePath), ["Submitted.swift"])
        XCTAssertEqual(session.pendingTaggedFileAttachments, [newerTag], "Only the submitted file was consumed")
        let bubble = try XCTUnwrap(session.items.last { $0.kind == .user })
        XCTAssertEqual(bubble.id, intent.userItemID)
        XCTAssertEqual(bubble.taggedFileAttachments, [submittedTag], "The bubble and route carry the admitted snapshot only")
        XCTAssertEqual(controller.steerTexts.count, 1)
    }

    /// An MCP instruction never reads or consumes the composer's tagged files or interview choice.
    func testMCPAdmissionNeverConsumesComposerAttachmentsOrInterviewChoice() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4708, controller: controller)
        let lane = try await persistAndClaimLane(harness)
        prepareActiveCodexTurn(harness, controller: controller)
        let composerTag = AgentTaggedFileAttachment(relativePath: "Composer.swift", displayName: "Composer.swift")
        harness.session.pendingTaggedFileAttachments = [composerTag]
        harness.viewModel.setInterviewFirst(true, for: harness.session)

        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "from mcp",
            tabID: harness.tabID,
            origin: .mcp
        )

        XCTAssertEqual(result, .submitted)
        let intent = try await waitForSingleIntent(lane, state: .providerAccepted, session: harness.session)
        XCTAssertTrue(intent.payload.taggedFiles.isEmpty)
        XCTAssertFalse(intent.payload.interviewFirst)
        XCTAssertEqual(harness.session.pendingTaggedFileAttachments, [composerTag])
        XCTAssertTrue(harness.session.interviewFirst, "The composer's interview choice is untouched")
        let bubble = try XCTUnwrap(harness.session.items.last { $0.kind == .user })
        XCTAssertTrue(bubble.taggedFileAttachments.isEmpty)
    }

    // MARK: - F1: no implicit untracked route under durable admission

    /// The synchronous submit and the run start both fail closed without an admitted identity once
    /// the session requires durable admission: no bubble, no run, and the composer is untouched.
    func testUnadmittedSubmitAndRunStartFailClosedUnderMandatoryAdmission() async throws {
        let controller = ProducerFakeCodexController()
        let harness = try await makeHarness(windowID: 4709, controller: controller)
        let session = harness.session
        session.selectedAgent = .openCode
        let tag = AgentTaggedFileAttachment(relativePath: "Kept.swift", displayName: "Kept.swift")
        session.pendingTaggedFileAttachments = [tag]
        harness.viewModel.setInterviewFirst(true, for: session)
        harness.viewModel.storeDraftText(for: harness.tabID, "untracked")
        let itemsBefore = session.items.map(\.id)

        let submitted = harness.viewModel.submitUserTurn(
            text: "untracked",
            tabID: harness.tabID,
            codexAttemptID: nil,
            admitted: nil
        )

        XCTAssertEqual(submitted, .blocked(message: AgentModeViewModel.durableQueueAdmissionRequiredMessage))
        XCTAssertEqual(session.items.map(\.id), itemsBefore, "No optimistic bubble")
        XCTAssertEqual(session.pendingTaggedFileAttachments, [tag])
        XCTAssertTrue(session.interviewFirst)
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "untracked")
        XCTAssertTrue(session.pendingInstructions.isEmpty)

        let outcome = await harness.viewModel.startAgentRun(
            tabID: harness.tabID,
            initialMessage: "untracked",
            inputConstituents: nil
        )

        guard case let .stale(reason) = outcome else {
            return XCTFail("Expected a fail-closed stale outcome, got \(String(describing: outcome))")
        }
        XCTAssertEqual(reason, AgentModeViewModel.durableQueueAdmissionRequiredMessage)
        XCTAssertFalse(session.runState.isActive, "No run was started")
        XCTAssertNil(session.runID)
        XCTAssertEqual(session.items.map(\.id), itemsBefore)
        XCTAssertEqual(controller.startCount, 0)
    }

    // MARK: - R05/F4: durable queue head drains into the instruction wait

    /// Two durable MCP inputs queued behind a running turn: the next instruction wait delivers the
    /// head (provider-accepted under its own dispatch attempt and the live run attempt) and installs
    /// no wait, so the second input stays queued in order and nothing overtakes it.
    func testInstructionWaitDrainsDurableQueueHeadInFIFOOrder() async throws {
        let harness = try await makeHarness(windowID: 4710, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.waitDrain")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)

        for text in ["first queued", "second queued"] {
            let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
                text: text,
                tabID: harness.tabID,
                origin: .mcp
            )
            XCTAssertEqual(result, .submitted)
        }
        XCTAssertEqual(session.pendingInstructions.count, 2)
        XCTAssertTrue(session.pendingInstructions.allSatisfy(\.isDurable))
        let queued = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        XCTAssertEqual(queued.map(\.payload.text), ["first queued", "second queued"])
        XCTAssertEqual(queued.map(\.deliveryState), [.queued, .queued])

        let response = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)

        XCTAssertFalse(response.timedOut)
        let text = try XCTUnwrap(response.text)
        XCTAssertTrue(text.contains("first queued"))
        XCTAssertFalse(text.contains("second queued"))
        XCTAssertNil(session.instructionContinuation, "No wait is installed past a queued head")
        XCTAssertEqual(session.pendingInstructions.count, 1)
        XCTAssertEqual(session.pendingInstructions.first?.constituents.map(\.intentID), [queued[1].intentID])
        // R05-R1a: returning the head to the waiting tool is a local handoff, not provider acceptance.
        let record = try await waitForRecord(lane, "head handed off (delivery unknown), second still queued") {
            $0.intents.map(\.deliveryState) == [.deliveryUnknown, .queued]
        }
        XCTAssertEqual(record.attempts.map(\.intentID), [queued[0].intentID], "Only the head was dispatched")
        XCTAssertEqual(record.attempts.first?.runAttemptID, runAttemptID)
    }

    /// A queued head that was settled back to `queued` with pre-handoff evidence receives its first
    /// pending-handoff prefix before its redispatch: the exact snapshot is attached to the carrier,
    /// the delivered text carries it, and the earlier attempt is kept as history.
    func testSettledQueueHeadReceivesItsFirstPrefixBeforeRedispatch() async throws {
        let harness = try await makeHarness(windowID: 4714, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.settledHead")
        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "settled head",
            tabID: harness.tabID,
            origin: .mcp
        )
        XCTAssertEqual(result, .submitted)
        let intentID = try XCTUnwrap(session.pendingInstructions.first?.constituents.first?.intentID)
        let earlier = UUID()
        guard case .success = await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: earlier),
            authorization: .liveQueue
        ), case .success = await lane.settleToQueue(intentID: intentID, attemptID: earlier, evidence: .preHandoff, message: nil)
        else { return XCTFail("The head was dispatched and settled back to queue") }
        session.pendingHandoff = .init(payload: "SETTLED-HISTORY", payloadID: UUID())

        let response = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)

        let text = try XCTUnwrap(response.text)
        XCTAssertTrue(text.contains("SETTLED-HISTORY\n\nsettled head"), "The redispatch carries its prefix: \(text)")
        let record = try await waitForRecord(lane, "the redispatched head handed off (delivery unknown)") {
            $0.intents.map(\.deliveryState) == [.deliveryUnknown]
        }
        XCTAssertEqual(record.intents.first?.pendingHandoff?.prependedText, "SETTLED-HISTORY\n\n")
        XCTAssertEqual(record.attempts(forIntent: intentID).count, 2)
        XCTAssertEqual(record.attempts(forIntent: intentID).first?.attemptID, earlier, "The earlier attempt is kept")
    }

    /// A queued head whose carrier cannot take the required prefix (a different snapshot is already
    /// attached) is never handed off without it: the wait reports the block, the head stays queued
    /// in place, nothing is dispatched, and the pending handoff stays for an explicit resolution.
    func testQueueHeadWhosePrefixCannotBeAttachedIsBlockedWithInputKept() async throws {
        let harness = try await makeHarness(windowID: 4715, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.blockedHead")
        let result = await harness.viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "blocked head",
            tabID: harness.tabID,
            origin: .mcp
        )
        XCTAssertEqual(result, .submitted)
        let head = try XCTUnwrap(session.pendingInstructions.first)
        let intentID = try XCTUnwrap(head.constituents.first?.intentID)
        let other = try XCTUnwrap(AgentRecoveryPendingHandoffSnapshot(
            .init(payload: "OTHER-HISTORY", payloadID: UUID()),
            prependedText: "OTHER-HISTORY\n\n"
        ))
        guard case .success = await lane.attachPendingHandoff(intentID: intentID, snapshot: other) else {
            return XCTFail("A first snapshot attaches to the queued carrier")
        }
        let payloadID = UUID()
        session.pendingHandoff = .init(payload: "REQUIRED-HISTORY", payloadID: payloadID)

        do {
            _ = try await harness.viewModel.waitForNextUserInstruction(tabID: harness.tabID)
            XCTFail("The head must not be delivered without its prefix")
        } catch let error as AgentModeViewModel.QueuedInstructionDeliveryError {
            XCTAssertEqual(error.message, AgentPendingHandoffDispatchStaging.blockedReason)
        }
        XCTAssertEqual(session.pendingInstructions.first, head, "The head stays queued in place")
        let read = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(read.record)
        XCTAssertEqual(record.intents.map(\.deliveryState), [.queued])
        XCTAssertEqual(record.intents.first?.pendingHandoff, other, "The attached snapshot is never replaced")
        XCTAssertTrue(record.attempts.isEmpty, "Nothing was dispatched")
        XCTAssertEqual(session.pendingHandoff.payload, "REQUIRED-HISTORY", "The required history stays pending")
        XCTAssertEqual(session.pendingHandoff.payloadID, payloadID)
        XCTAssertNil(session.pendingHandoff.stage, "The unsent stage was released")
    }

    /// An MCP input submitted while the agent waits is handed to the claimed continuation (the
    /// waiting tool's result channel). That local handoff is not proof the provider received the
    /// tool result (R05-R1a): it is recorded `deliveryUnknown`, never `providerAccepted`.
    func testInstructionContinuationHandoffIsDeliveryUnknownNotProviderAccepted() async throws {
        let harness = try await makeHarness(windowID: 4711, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.continuation")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        let viewModel = harness.viewModel
        let tabID = harness.tabID

        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "The wait was installed")
        XCTAssertEqual(session.runState, .waitingForUser)

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "answer for the wait",
            tabID: tabID,
            origin: .mcp
        )
        XCTAssertEqual(result, .submitted)

        let response = try await wait.value
        XCTAssertTrue(try XCTUnwrap(response.text).contains("answer for the wait"))
        XCTAssertNil(session.instructionContinuation, "The continuation was claimed")
        let intent = try await waitForSingleIntent(lane, state: .deliveryUnknown, session: session)
        XCTAssertEqual(intent.payload.text, "answer for the wait")
        let read = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(read.record)
        XCTAssertEqual(record.attempts.map(\.intentID), [intent.intentID])
        XCTAssertEqual(record.attempts.first?.runAttemptID, runAttemptID)
    }

    // MARK: - F-9: refusal texts

    /// Each refusal says why nothing was sent; only real save/authority failures claim a save failure.
    func testAdmissionRefusalsDescribeTheirOwnReason() {
        let hold = AgentRecoveryCrashHold(
            sessionID: UUID(),
            incarnationID: UUID(),
            transcriptResetGeneration: 0,
            uncertainRunAttemptIDs: [UUID()],
            uncertainIntentIDs: [],
            previousExitProvenClean: false
        )
        let saveFailure = AgentModeViewModel.recoveryAdmissionFailedMessage
        let refusals: [AgentRecoveryAdmissionRefusal] = [
            .startupNotReady,
            .startupFailed("index unreadable"),
            .restricted("Its recovery status is unknown."),
            .crashHeld(hold),
            .unsavedPredecessorInput,
            .resetPreparationInProgress,
            .laneRetired,
            .bindingMismatch
        ]
        for refusal in refusals {
            let message = AgentModeViewModel.recoveryAdmissionRefusalMessage(refusal)
            XCTAssertNotEqual(message, saveFailure, "\(refusal) is not a save failure")
            XCTAssertFalse(message.contains("could not be saved for recovery"), "\(refusal): \(message)")
            XCTAssertTrue(message.contains("Your draft is kept"), "\(refusal): \(message)")
        }
        XCTAssertTrue(AgentModeViewModel.recoveryAdmissionRefusalMessage(.crashHeld(hold)).contains("Confirm it stopped"))
        XCTAssertTrue(
            AgentModeViewModel.recoveryAdmissionRefusalMessage(.restricted("Its recovery status is unknown."))
                .contains("Its recovery status is unknown.")
        )
        XCTAssertEqual(AgentModeViewModel.recoveryAdmissionRefusalMessage(.untrackedInput), saveFailure)
    }

    // MARK: - FIFO edge: a head re-queued during a live instruction wait

    /// A durable head put back (`insert(_:at: 0)`) after the agent parked in its instruction wait is
    /// handed to that wait: dispatched under the live run attempt, recorded `deliveryUnknown` when
    /// the claimed continuation receives it (a local handoff, R05-R1a), and removed from the queue.
    func testHeadRequeuedDuringLiveInstructionWaitIsDeliveredToThatWait() async throws {
        let harness = try await makeHarness(windowID: 4716, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.requeuedHead")
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "re-queued head",
            tabID: tabID,
            origin: .mcp
        )
        XCTAssertEqual(result, .submitted)
        // Held out of the queue while the wait installs, then put back like a re-queue path does.
        let head = session.pendingInstructions.removeFirst()
        XCTAssertTrue(head.isDurable)

        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "The wait was installed")
        session.pendingInstructions.insert(head, at: 0)

        let delivery = try XCTUnwrap(viewModel.deliverRequeuedHeadToLiveInstructionWaitIfNeeded(session))
        await delivery.value

        let response = try await wait.value
        XCTAssertTrue(try XCTUnwrap(response.text).contains("re-queued head"))
        XCTAssertNil(session.instructionContinuation, "The continuation was claimed")
        XCTAssertTrue(session.pendingInstructions.isEmpty, "The delivered head left the queue")
        let intentID = try XCTUnwrap(head.constituents.first?.intentID)
        let record = try await waitForRecord(lane, "the re-queued head handed off (delivery unknown)") {
            $0.intents.map(\.deliveryState) == [.deliveryUnknown]
        }
        XCTAssertEqual(record.attempts.map(\.intentID), [intentID])
        XCTAssertEqual(record.attempts.first?.runAttemptID, runAttemptID)
    }

    /// A re-queued head whose required prefix cannot be attached is never handed to the live wait:
    /// it stays queued in place, nothing is dispatched, and the wait stays installed.
    func testRequeuedHeadWhosePrefixCannotBeAttachedStaysQueuedDuringLiveWait() async throws {
        let harness = try await makeHarness(windowID: 4717, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.requeuedBlockedHead")
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "blocked re-queued head",
            tabID: tabID,
            origin: .mcp
        )
        XCTAssertEqual(result, .submitted)
        let head = session.pendingInstructions.removeFirst()
        let intentID = try XCTUnwrap(head.constituents.first?.intentID)
        let other = try XCTUnwrap(AgentRecoveryPendingHandoffSnapshot(
            .init(payload: "OTHER-HISTORY", payloadID: UUID()),
            prependedText: "OTHER-HISTORY\n\n"
        ))
        guard case .success = await lane.attachPendingHandoff(intentID: intentID, snapshot: other) else {
            return XCTFail("A first snapshot attaches to the queued carrier")
        }

        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "The wait was installed")
        session.pendingHandoff = .init(payload: "REQUIRED-HISTORY", payloadID: UUID())
        session.pendingInstructions.insert(head, at: 0)

        let delivery = try XCTUnwrap(viewModel.deliverRequeuedHeadToLiveInstructionWaitIfNeeded(session))
        await delivery.value

        XCTAssertNotNil(session.instructionContinuation, "The wait was not claimed")
        XCTAssertEqual(session.runState, .waitingForUser)
        XCTAssertEqual(session.pendingInstructions.first, head, "The head stays queued in place")
        let read = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(read.record)
        XCTAssertEqual(record.intents.map(\.deliveryState), [.queued])
        XCTAssertTrue(record.attempts.isEmpty, "Nothing was dispatched")
        XCTAssertNil(session.pendingHandoff.stage, "The unsent stage was released")

        // R05-R1b: a second input B never claims the wait ahead of the blocked head A.
        let second = await viewModel.submitUserTurnAdmittingRecoveryInput(
            text: "second behind the blocked head",
            tabID: tabID,
            origin: .mcp
        )
        XCTAssertEqual(second, .submitted)
        await Task.yield()
        XCTAssertNotNil(session.instructionContinuation, "B did not claim the wait")
        XCTAssertEqual(session.runState, .waitingForUser)
        XCTAssertEqual(session.pendingInstructions.count, 2, "B is queued behind A")
        XCTAssertEqual(session.pendingInstructions.first, head, "A keeps the head")
        let afterSecondRead = await lane.store.read(sessionID: lane.sessionID)
        let afterSecond = try XCTUnwrap(afterSecondRead.record)
        XCTAssertEqual(afterSecond.intents.map(\.deliveryState), [.queued, .queued])
        XCTAssertEqual(afterSecond.intents.first?.intentID, intentID)
        XCTAssertEqual(
            session.pendingInstructions.last?.constituents.map(\.intentID),
            [afterSecond.intents.last?.intentID]
        )
        XCTAssertTrue(afterSecond.attempts.isEmpty, "Neither input was dispatched")

        viewModel.cancelPendingInstruction(for: session)
        do {
            _ = try await wait.value
            XCTFail("The cancelled wait throws")
        } catch is CancellationError {}
    }

    /// R05-R1b: an older head A owns the live wait while its own delivery has not claimed it yet, and
    /// also when A is re-queued while B's preparation is suspended (B's continuation task has not run
    /// when the submission returns). B queues behind A in both cases; A's delivery then claims the
    /// wait with A alone, and B stays queued for the next wait.
    func testNewInputQueuesBehindAnOlderHeadWhoseDeliveryHasNotClaimedTheLiveWait() async throws {
        let harness = try await makeHarness(windowID: 4718, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.olderHeadOwnsWait")
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let admittedA = await viewModel.submitUserTurnAdmittingRecoveryInput(text: "older head A", tabID: tabID, origin: .mcp)
        XCTAssertEqual(admittedA, .submitted)
        let headA = session.pendingInstructions.removeFirst()

        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "The wait was installed")

        // B's preparation is suspended (its continuation task has not run yet) when A is re-queued.
        let admittedB = await viewModel.submitUserTurnAdmittingRecoveryInput(text: "newer B", tabID: tabID, origin: .mcp)
        XCTAssertEqual(admittedB, .submitted)
        session.pendingInstructions.insert(headA, at: 0)
        for _ in 0 ..< 400 where session.pendingInstructions.count < 2 && session.instructionContinuation != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "B did not claim the wait ahead of A")
        XCTAssertEqual(session.pendingInstructions.first, headA, "A keeps the head")
        XCTAssertEqual(session.pendingInstructions.count, 2, "B queued behind A")

        // A third input C arrives while A's delivery has still not claimed the wait.
        let admittedC = await viewModel.submitUserTurnAdmittingRecoveryInput(text: "newest C", tabID: tabID, origin: .mcp)
        XCTAssertEqual(admittedC, .submitted)
        XCTAssertNotNil(session.instructionContinuation, "C did not claim the wait")
        XCTAssertEqual(session.pendingInstructions.count, 3, "C queued behind A and B")
        let queuedRead = await lane.store.read(sessionID: lane.sessionID)
        let queuedRecord = try XCTUnwrap(queuedRead.record)
        XCTAssertEqual(
            session.pendingInstructions.map { $0.constituents.map(\.intentID) },
            queuedRecord.intents.map { [$0.intentID] },
            "Queue order is admission order"
        )

        // A's delivery resumes and claims the wait with A alone.
        let delivery = try XCTUnwrap(viewModel.deliverRequeuedHeadToLiveInstructionWaitIfNeeded(session))
        await delivery.value
        let response = try await wait.value
        let text = try XCTUnwrap(response.text)
        XCTAssertTrue(text.contains("older head A"))
        XCTAssertFalse(text.contains("newer B"))
        XCTAssertFalse(text.contains("newest C"))
        XCTAssertEqual(session.pendingInstructions.count, 2, "B and C stay queued for the next wait")
        let record = try await waitForRecord(lane, "A handed off, B and C queued") {
            $0.intents.map(\.deliveryState) == [.deliveryUnknown, .queued, .queued]
        }
        let headAIntentID = try XCTUnwrap(headA.constituents.first?.intentID)
        XCTAssertEqual(record.attempts.map(\.intentID), [headAIntentID])
    }

    /// B R1-1: an input admitted for the live wait whose wait ends while its preparation is
    /// suspended is never left saved but invisible: it is presented as held, stays `queued`, is not
    /// dispatched, and is not resent automatically.
    func testInputWhoseWaitEndsDuringPreparationIsPresentedAsHeld() async throws {
        let harness = try await makeHarness(windowID: 4719, controller: ProducerFakeCodexController())
        let lane = try await persistAndClaimLane(harness)
        let session = harness.session
        session.selectedAgent = .openCode
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer.waitEndedDuringPreparation")
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let wait = Task { @MainActor in
            try await viewModel.waitForNextUserInstruction(tabID: tabID)
        }
        for _ in 0 ..< 400 where session.instructionContinuation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.instructionContinuation, "The wait was installed")

        let result = await viewModel.submitUserTurnAdmittingRecoveryInput(text: "late for the wait", tabID: tabID, origin: .mcp)
        XCTAssertEqual(result, .submitted)
        // The wait ends before the submission's continuation task runs (its preparation suspended).
        viewModel.cancelPendingInstruction(for: session)
        do {
            _ = try await wait.value
            XCTFail("The cancelled wait throws")
        } catch is CancellationError {}

        let intent = try await waitForSingleIntent(lane, state: .queued, session: session)
        for _ in 0 ..< 400 where lane.heldIntents[intent.intentID] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(lane.heldIntents[intent.intentID], AgentModeViewModel.instructionWaitEndedHoldReason)
        XCTAssertTrue(session.pendingInstructions.isEmpty, "Not re-queued for an automatic resend")
        let read = await lane.store.read(sessionID: lane.sessionID)
        let record = try XCTUnwrap(read.record)
        XCTAssertTrue(record.attempts.isEmpty, "Nothing was dispatched")
        XCTAssertEqual(record.intents.map(\.deliveryState), [.queued])
    }

    // MARK: - Harness

    private func waitForRecord(
        _ lane: AgentRecoverySessionLane,
        _ expectation: String,
        until predicate: (AgentRecoveryRecord) -> Bool
    ) async throws -> AgentRecoveryRecord {
        for _ in 0 ..< 400 {
            if let record = await lane.store.read(sessionID: lane.sessionID).record, predicate(record) {
                return record
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let states = await lane.store.read(sessionID: lane.sessionID).record?.intents.map(\.deliveryState) ?? []
        XCTFail("Expected \(expectation); intents=\(states)")
        throw Timeout()
    }

    private static let noActiveTurnError = CodexTurnSteerError.noActiveTurn(CodexAppServerClient.RequestFailure(
        method: "turn/steer",
        code: -32602,
        message: "no active turn to steer",
        data: nil
    ))

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let workspacePath: String
        let tabID: UUID
        let session: AgentTabSession

        struct MissingPersistedFile: Error {}

        @MainActor
        func persistedFileText() async throws -> String {
            guard let sessionID = session.activeAgentSessionID,
                  let persisted = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace),
                  let fileURL = persisted.fileURL
            else { throw MissingPersistedFile() }
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
    }

    private struct Timeout: Error {}

    private func waitForSingleIntent(
        _ lane: AgentRecoverySessionLane,
        state: AgentRecoveryDeliveryState,
        session: AgentTabSession? = nil
    ) async throws -> AgentRecoveryIntent {
        for _ in 0 ..< 400 {
            let intents = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
            if intents.count == 1, intents[0].deliveryState == state {
                return intents[0]
            }
            XCTAssertLessThanOrEqual(intents.count, 1, "One input commits exactly one intent")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let intents = await lane.store.read(sessionID: lane.sessionID).record?.intents ?? []
        let transcript = session.map(Self.diagnostics) ?? ""
        XCTFail("Expected one \(state) intent, got \(intents.map(\.deliveryState)); runState=\(String(describing: session?.runState)) transcript=[\(transcript)]")
        throw Timeout()
    }

    private func waitForFallbackEntry(_ session: AgentTabSession) async throws -> AgentTabSession.CodexFallbackQueueEntry {
        for _ in 0 ..< 400 {
            if session.codexFallbackQueue.count == 1, let entry = session.codexFallbackQueue.first {
                return entry
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let transcript = Self.diagnostics(session)
        XCTFail("Expected one fallback queue entry, got \(session.codexFallbackQueue.count); runState=\(session.runState) transcript=[\(transcript)]")
        throw Timeout()
    }

    private static func diagnostics(_ session: AgentTabSession) -> String {
        let identity = session.codexAuthoritativeActiveTurn
        let items = session.items.map { "\($0.kind): \($0.text.prefix(240))" }.joined(separator: " | ")
        return "\(items)] identity=\(identity.map { "gen \($0.controllerGeneration) run \($0.runID) attempt \($0.runAttemptID)" } ?? "nil")"
            + " session=gen \(session.codexControllerGeneration) run \(String(describing: session.runID)) attempt \(String(describing: session.activeRunAttemptID))"
            + " controllerSame=\(session.codexController.map { identity?.controllerInstanceID == ObjectIdentifier($0) } ?? false)"
            + " thread=\(String(describing: session.codexConversationID)) queue=\(session.codexFallbackQueue.count)"
    }

    /// Persists the first transcript through the VM save path, which claims the session's lane.
    private func persistAndClaimLane(_ harness: Harness) async throws -> AgentRecoverySessionLane {
        harness.session.appendItem(.user("Earlier turn"))
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        return try XCTUnwrap(harness.session.recoveryLane, "The first save claims the session's lane")
    }

    /// A live Codex user turn bound to `controller`, as a real controller start leaves it (including
    /// the controller's workspace path, so the send does not reconnect and invalidate the turn).
    private func prepareActiveCodexTurn(_ harness: Harness, controller: ProducerFakeCodexController) {
        let session = harness.session
        let runID = UUID()
        session.selectedAgent = .codexExec
        session.codexControllerWorkspacePath = harness.workspacePath
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.recoveryProducer")
        session.codexController = controller
        session.codexConversationID = "fake"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
    }

    private func makeHarness(windowID: Int, controller: ProducerFakeCodexController) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryVMProducerWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryVMProducerStore")
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
            name: "Agent Recovery VM Producers",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
        XCTAssertTrue(viewModel.test_dataService === service, "The VM writes through the coordinator's gated DataService")
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertEqual(session.recoveryAdmissionMode, .mandatory, "Injected mandatory mode applies to new sessions")
        return Harness(viewModel: viewModel, workspace: workspace, workspacePath: storageURL.path, tabID: tabID, session: session)
    }
}

/// Minimal Codex controller: an active thread whose steer succeeds (or throws `steerError`),
/// recording the provider-facing text. `onSteer` runs before the steer result, i.e. before any
/// fallback queue acknowledgement.
private final class ProducerFakeCodexController: CodexSessionControlling {
    private(set) var steerTexts: [String] = []
    private(set) var steerTurnIDs: [String] = []
    private(set) var startCount = 0
    var onSteer: (@MainActor () async -> Void)?
    /// Runs at the provider boundary of `startUserTurn`, before its receipt.
    var onStart: (@MainActor () async -> Void)?
    private let steerError: Error?

    init(steerError: Error? = nil) {
        self.steerError = steerError
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .active(activeFlags: []),
            currentTurnID: "turn",
            activeTurnIDs: ["turn"],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {}

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startCount += 1
        if let onStart {
            await onStart()
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "producer-submission-\(startCount)")
    }

    func steerUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        steerTexts.append(text)
        steerTurnIDs.append(expectedTurnID)
        if let onSteer {
            await onSteer()
        }
        if let steerError {
            throw steerError
        }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func pendingTurnFailure(turnID _: String?) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(turnID _: String?, failure _: CodexNativeSessionController.TurnFailure) async {}
    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
