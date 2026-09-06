import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentBranchUITests: XCTestCase {
    func testOnlyConclusionBlocksAreEligibleForReplyBranchControl() {
        XCTAssertTrue(AgentReplyBranchPresentation.isEligibleBlock(.conclusion))
        let otherKinds: [AgentTranscriptRenderBlockKind] = [
            .request,
            .activityCluster,
            .groupedHistory,
            .collapsedHistoryRange,
            .standaloneAssistant,
            .standaloneTool,
            .standaloneNote,
            .middleSummary
        ]
        XCTAssertTrue(otherKinds.allSatisfy { !AgentReplyBranchPresentation.isEligibleBlock($0) })
    }

    func testDisabledHelpTextUsesExactPhaseFourCopy() {
        let turnID = UUID()
        let cases: [(AgentSessionBranchAvailability.Reason, String)] = [
            (.providerUnsupported(.claudeCode), "Native branching is currently available only for local Codex sessions."),
            (.remoteSession, "Native branching is currently available only for local Codex sessions."),
            (.noCheckpoint, "No native checkpoint was recorded for this turn."),
            (.turnNotCompleted, "No native checkpoint was recorded for this turn."),
            (.beforeCompaction, "Codex compacted this conversation after this checkpoint."),
            (.notIdle, "Finish the pending operation before branching."),
            (.operationInProgress, "Finish the pending operation before branching."),
            (.pendingHandoff, "Finish the pending operation before branching.")
        ]

        for (reason, expected) in cases {
            let presentation = AgentReplyBranchPresentation(
                turnID: turnID,
                availability: .unavailable(reason),
                transcriptTurnIDs: [turnID],
                ledger: nil,
                isOperationInProgress: false
            )
            XCTAssertFalse(presentation.isAvailable)
            XCTAssertEqual(presentation.disabledHelpText, expected)
        }
    }

    func testReadOnlyConfirmationUsesExactCopyAndBranchLabel() {
        let targetID = UUID()
        let ledger = makeLedger(targetID: targetID, omitted: [.readOnly, .readOnly])
        let target = ledger.entries[0]
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: ledger.entries.map(\.turnID),
            ledger: ledger,
            isOperationInProgress: false
        )

        XCTAssertEqual(presentation.turnID, targetID)
        XCTAssertTrue(presentation.isAvailable)
        XCTAssertEqual(presentation.confirmationTitle, "Branch from this reply?")
        XCTAssertEqual(presentation.confirmationButtonTitle, "Branch")
        XCTAssertEqual(
            presentation.confirmationBody,
            "Keeps turns 1–1. Sets aside 2 later turn(s) on this branch: Read-only exploration. Anything they changed on disk stays changed. Files, Git state, and workspace selections are not rolled back. The current path stays available in the branch menu."
        )
    }

    func testOracleDisclosureUsesExactSingularAndPluralCopy() {
        let targetID = UUID()
        let ledger = makeLedger(targetID: targetID, omitted: [.readOnly])
        let base = "Keeps turns 1–1. Sets aside 1 later turn(s) on this branch: Read-only exploration. Anything they changed on disk stays changed. Files, Git state, and workspace selections are not rolled back. The current path stays available in the branch menu."

        let singular = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(ledger.entries[0]),
            transcriptTurnIDs: ledger.entries.map(\.turnID),
            ledger: ledger,
            sourceOwnedOracleChatCount: 1,
            isOperationInProgress: false
        )
        XCTAssertEqual(
            singular.confirmationBody,
            "\(base) 1 Oracle chat stays with the original path — this branch can read its results but must start a new chat to continue."
        )

        let plural = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(ledger.entries[0]),
            transcriptTurnIDs: ledger.entries.map(\.turnID),
            ledger: ledger,
            sourceOwnedOracleChatCount: 2,
            isOperationInProgress: false
        )
        XCTAssertEqual(
            plural.confirmationBody,
            "\(base) 2 Oracle chats stay with the original path — this branch can read their results but must start new chats to continue."
        )
    }

    func testWorstOfOmittedSideEffectsControlsWarningAndBranchAnywayLabel() {
        let modifiedTargetID = UUID()
        let modifiedLedger = makeLedger(
            targetID: modifiedTargetID,
            omitted: [.modified(paths: ["a.swift", "b.swift"]), .modified(paths: ["a.swift"])]
        )
        let modified = AgentReplyBranchPresentation(
            turnID: modifiedTargetID,
            availability: .available(modifiedLedger.entries[0]),
            transcriptTurnIDs: modifiedLedger.entries.map(\.turnID),
            ledger: modifiedLedger,
            isOperationInProgress: false
        )
        XCTAssertEqual(modified.confirmationButtonTitle, "Branch anyway")
        XCTAssertTrue(modified.confirmationBody.contains("Changed files: a.swift, b.swift"))

        let unknownTargetID = UUID()
        let unknownLedger = makeLedger(
            targetID: unknownTargetID,
            omitted: [.modified(paths: ["changed.swift"]), .unknown]
        )
        let unknown = AgentReplyBranchPresentation(
            turnID: unknownTargetID,
            availability: .available(unknownLedger.entries[0]),
            transcriptTurnIDs: unknownLedger.entries.map(\.turnID),
            ledger: unknownLedger,
            isOperationInProgress: false
        )
        XCTAssertEqual(unknown.confirmationButtonTitle, "Branch anyway")
        XCTAssertTrue(unknown.confirmationBody.contains("May have changed files"))
        XCTAssertFalse(unknown.confirmationBody.contains("changed.swift"))
    }

    func testProgressStateDisablesAnOtherwiseAvailablePresentation() {
        let targetID = UUID()
        let ledger = makeLedger(targetID: targetID, omitted: [])
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(ledger.entries[0]),
            transcriptTurnIDs: ledger.entries.map(\.turnID),
            ledger: ledger,
            isOperationInProgress: true
        )

        XCTAssertTrue(presentation.isOperationInProgress)
        XCTAssertFalse(presentation.isAvailable)
        XCTAssertEqual(
            presentation.disabledHelpText,
            "Finish the pending operation before branching."
        )
    }

    func testSparseLedgerUsesTranscriptOrdinalAndMissingOmittedCheckpointIsUnknown() {
        let targetID = UUID()
        let firstOmittedID = UUID()
        let missingOmittedID = UUID()
        let lastOmittedID = UUID()
        let ledger = CodexTurnCheckpointLedger(
            threadID: "thread",
            entries: [
                makeCheckpoint(turnID: targetID, codexTurnID: "target", sideEffect: .readOnly),
                makeCheckpoint(turnID: firstOmittedID, codexTurnID: "first", sideEffect: .readOnly),
                makeCheckpoint(turnID: lastOmittedID, codexTurnID: "last", sideEffect: .readOnly)
            ]
        )
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(ledger.entries[0]),
            transcriptTurnIDs: [targetID, firstOmittedID, missingOmittedID, lastOmittedID],
            ledger: ledger,
            isOperationInProgress: false
        )

        XCTAssertEqual(presentation.retainedTurnCount, 1)
        XCTAssertEqual(presentation.omittedTurnCount, 3)
        XCTAssertEqual(presentation.omittedTurnImpact, .unknown)
        XCTAssertEqual(presentation.confirmationButtonTitle, "Branch anyway")
    }

    func testDuplicateOmittedCheckpointFailsClosedAsUnknownImpact() {
        let targetID = UUID()
        let omittedID = UUID()
        let target = makeCheckpoint(
            turnID: targetID,
            codexTurnID: "target",
            sideEffect: .readOnly
        )
        let firstOmitted = makeCheckpoint(
            turnID: omittedID,
            codexTurnID: "omitted-a",
            sideEffect: .readOnly
        )
        let duplicateOmitted = makeCheckpoint(
            turnID: omittedID,
            codexTurnID: "omitted-b",
            sideEffect: .readOnly
        )
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: [targetID, omittedID],
            ledger: CodexTurnCheckpointLedger(
                threadID: "thread",
                entries: [target, firstOmitted, duplicateOmitted]
            ),
            isOperationInProgress: false
        )

        XCTAssertEqual(presentation.omittedTurnImpact, .unknown)
        XCTAssertEqual(presentation.confirmationButtonTitle, "Branch anyway")
    }

    func testConfirmationFailsClosedWhenSelectedTurnIsNotUnique() {
        let turnID = UUID()
        let checkpoint = makeCheckpoint(
            turnID: turnID,
            codexTurnID: "duplicate",
            sideEffect: .readOnly
        )
        let presentation = AgentReplyBranchPresentation(
            turnID: turnID,
            availability: .available(checkpoint),
            transcriptTurnIDs: [turnID, turnID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [checkpoint]),
            isOperationInProgress: false
        )

        XCTAssertFalse(presentation.hasResolvedTranscriptTurn)
        XCTAssertFalse(presentation.canPresentConfirmation)
        XCTAssertFalse(presentation.confirmationBody.contains("Keeps turns 1–0"))
    }

    func testTranscriptLeafHasZeroOmittedTurnsAndReadOnlyImpactWithoutSuffixCheckpoints() {
        let earlierTurnID = UUID()
        let targetID = UUID()
        let target = makeCheckpoint(turnID: targetID, codexTurnID: "target", sideEffect: .readOnly)
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: [earlierTurnID, targetID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [target]),
            isOperationInProgress: false
        )

        XCTAssertEqual(presentation.retainedTurnCount, 2)
        XCTAssertEqual(presentation.omittedTurnCount, 0)
        XCTAssertEqual(presentation.omittedTurnImpact, .readOnly)
        XCTAssertEqual(presentation.confirmationButtonTitle, "Branch")
    }

    func testModifiedPathDisclosureCapsAtEightPaths() {
        let targetID = UUID()
        let omittedID = UUID()
        let paths = (1 ... 10).map { String(format: "file-%02d.swift", $0) }
        let target = makeCheckpoint(turnID: targetID, codexTurnID: "target", sideEffect: .readOnly)
        let omitted = makeCheckpoint(
            turnID: omittedID,
            codexTurnID: "omitted",
            sideEffect: .modified(paths: paths)
        )
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: [targetID, omittedID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [target, omitted]),
            isOperationInProgress: false
        )

        XCTAssertTrue(presentation.confirmationBody.contains("file-08.swift, and 2 more"))
        XCTAssertFalse(presentation.confirmationBody.contains("file-09.swift"))
        XCTAssertFalse(presentation.confirmationBody.contains("file-10.swift"))
        XCTAssertEqual(presentation.omittedTurnImpact, .modified(paths: paths))
    }

    @MainActor
    func testConfirmationSubmissionKeepsCapturedPresentationUntilSuccess() async {
        let targetID = UUID()
        let replacementID = UUID()
        let target = makeCheckpoint(turnID: targetID, codexTurnID: "target", sideEffect: .readOnly)
        let replacement = makeCheckpoint(
            turnID: replacementID,
            codexTurnID: "replacement",
            sideEffect: .readOnly
        )
        let originalPresentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: [targetID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [target]),
            isOperationInProgress: false
        )
        let replacementPresentation = AgentReplyBranchPresentation(
            turnID: replacementID,
            availability: .available(replacement),
            transcriptTurnIDs: [replacementID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [replacement]),
            isOperationInProgress: false
        )
        let started = expectation(description: "branch submission started")
        var resumeSubmission: CheckedContinuation<Void, Never>?
        let state = AgentReplyBranchConfirmationState()
        state.present(
            AgentReplyBranchConfirmation(presentation: originalPresentation) {
                started.fulfill()
                await withCheckedContinuation { resumeSubmission = $0 }
            }
        )

        let submission = Task { await state.submit() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(state.submissionStarted)
        state.present(AgentReplyBranchConfirmation(presentation: replacementPresentation) {})
        state.dismiss()
        XCTAssertEqual(state.confirmation?.presentation.turnID, targetID)

        resumeSubmission?.resume()
        await submission.value
        XCTAssertNil(state.confirmation)
        XCTAssertFalse(state.submissionStarted)
    }

    @MainActor
    func testConfirmationFailureKeepsPresentationAndShowsLocalizedError() async {
        let targetID = UUID()
        let target = makeCheckpoint(turnID: targetID, codexTurnID: "target", sideEffect: .readOnly)
        let presentation = AgentReplyBranchPresentation(
            turnID: targetID,
            availability: .available(target),
            transcriptTurnIDs: [targetID],
            ledger: CodexTurnCheckpointLedger(threadID: "thread", entries: [target]),
            isOperationInProgress: false
        )
        let state = AgentReplyBranchConfirmationState()
        state.present(
            AgentReplyBranchConfirmation(presentation: presentation) {
                throw TestBranchFailure.failed
            }
        )

        await state.submit()

        XCTAssertEqual(state.confirmation?.presentation.turnID, targetID)
        XCTAssertFalse(state.submissionStarted)
        XCTAssertEqual(state.errorMessage, "Localized branch failure")
    }

    @MainActor
    func testConversationBranchMenuUsesCapturedSnapshotAndExactDisabledCopy() throws {
        let target = AgentConversationBranchPickerTarget(
            workspaceID: UUID(),
            tabID: UUID(),
            activeSessionID: UUID(),
            bindingTransitionGeneration: 4
        )
        let deletedRootID = UUID()
        let occupiedBranchID = UUID()
        let activeBranchID = target.activeSessionID
        let snapshot = AgentConversationBranchPickerSnapshot(
            target: target,
            items: [
                AgentConversationBranchPickerItem(
                    id: deletedRootID,
                    sourceTurnOrdinal: nil,
                    date: nil,
                    isOriginal: true,
                    isDeleted: true,
                    isActive: false,
                    isEnabled: false,
                    disabledHelpText: "The original conversation was deleted."
                ),
                AgentConversationBranchPickerItem(
                    id: occupiedBranchID,
                    sourceTurnOrdinal: 2,
                    date: Date(timeIntervalSinceReferenceDate: 10),
                    isOriginal: false,
                    isDeleted: false,
                    isActive: false,
                    isEnabled: false,
                    disabledHelpText: "This branch is open in another tab."
                ),
                AgentConversationBranchPickerItem(
                    id: activeBranchID,
                    sourceTurnOrdinal: 3,
                    date: Date(timeIntervalSinceReferenceDate: 20),
                    isOriginal: false,
                    isDeleted: false,
                    isActive: true,
                    isEnabled: true,
                    disabledHelpText: nil
                )
            ]
        )
        var invocations: [(AgentConversationBranchPickerTarget, UUID)] = []
        let menu = AgentConversationBranchMenuPresenter.makeMenu(
            snapshot: snapshot,
            actions: AgentConversationBranchMenuActions {
                invocations.append(($0, $1))
            }
        )

        XCTAssertEqual(menu.items.first?.title, "Original (deleted)")
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertTrue(menu.items[1].title.contains("Branch from turn 2"))
        XCTAssertEqual(menu.items[1].toolTip, "This branch is open in another tab.")
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[2].state, .on)

        let activeItem = menu.items[2]
        XCTAssertTrue(try NSApplication.shared.sendAction(
            XCTUnwrap(activeItem.action),
            to: activeItem.target,
            from: activeItem
        ))
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.0, target)
        XCTAssertEqual(invocations.first?.1, activeBranchID)
    }

    @MainActor
    func testDeletedRootWithSoleSurvivingBranchProjectsTwoVisibleMembers() {
        let rootID = UUID()
        let survivingBranch = makeBranchRecord(
            id: UUID(),
            rootID: rootID,
            ordinal: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            savedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let tree = AgentSessionBranchTree(rootSessionID: rootID, records: [survivingBranch])

        XCTAssertEqual(
            AgentModeViewModel.projectedConversationBranchMemberCount(tree: tree),
            2
        )
        XCTAssertTrue(AgentModeViewModel.conversationBranchPickerShouldBeVisible(tree: tree))
    }

    func testConversationBranchRecordOrderingUsesOrdinalThenDateThenUUID() throws {
        let rootID = UUID()
        let fallbackDateID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000006"))
        let earlierCreatedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
        let lowerUUIDValue = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let higherUUIDValue = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let laterOrdinalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let nilOrdinalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let fallbackDate = makeBranchRecord(
            id: fallbackDateID,
            rootID: rootID,
            ordinal: 1,
            createdAt: nil,
            savedAt: Date(timeIntervalSinceReferenceDate: 5)
        )
        let earlierCreated = makeBranchRecord(
            id: earlierCreatedID,
            rootID: rootID,
            ordinal: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            savedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let lowerUUID = makeBranchRecord(
            id: lowerUUIDValue,
            rootID: rootID,
            ordinal: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            savedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let higherUUID = makeBranchRecord(
            id: higherUUIDValue,
            rootID: rootID,
            ordinal: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            savedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let laterOrdinal = makeBranchRecord(
            id: laterOrdinalID,
            rootID: rootID,
            ordinal: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            savedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let nilOrdinal = makeBranchRecord(
            id: nilOrdinalID,
            rootID: rootID,
            ordinal: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: -100),
            savedAt: Date(timeIntervalSinceReferenceDate: -100)
        )

        let sorted = [
            nilOrdinal,
            laterOrdinal,
            higherUUID,
            earlierCreated,
            lowerUUID,
            fallbackDate
        ].sorted(by: AgentModeViewModel.ConversationBranchRecordOrdering.areInIncreasingOrder)

        XCTAssertEqual(
            sorted.map(\.id),
            [fallbackDate.id, earlierCreated.id, lowerUUID.id, higherUUID.id, laterOrdinal.id, nilOrdinal.id]
        )
    }

    @MainActor
    func testConversationBranchLabelsDistinguishSameDayBranchesByTime() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let morning = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 9, to: day))
        let afternoon = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 15, to: day))
        let base = AgentConversationBranchPickerItem(
            id: UUID(),
            sourceTurnOrdinal: 2,
            date: morning,
            isOriginal: false,
            isDeleted: false,
            isActive: false,
            isEnabled: true,
            disabledHelpText: nil
        )
        let later = AgentConversationBranchPickerItem(
            id: UUID(),
            sourceTurnOrdinal: 2,
            date: afternoon,
            isOriginal: false,
            isDeleted: false,
            isActive: false,
            isEnabled: true,
            disabledHelpText: nil
        )

        XCTAssertNotEqual(
            AgentConversationBranchMenuPresenter.title(for: base),
            AgentConversationBranchMenuPresenter.title(for: later)
        )
    }

    func testBranchLineageProjectsIntoWarmIndexAndSidebarEntry() throws {
        let rootID = UUID()
        let tabID = UUID()
        let origin = AgentSessionBranchOrigin(
            rootSessionID: rootID,
            sourceSessionID: rootID,
            sourceTurnID: UUID(),
            sourceCodexTurnID: "turn-2",
            sourceTurnOrdinal: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let session = AgentSession(
            workspaceID: UUID(),
            composeTabID: tabID,
            name: "Branch",
            savedAt: Date(timeIntervalSinceReferenceDate: 200),
            autoEditEnabled: true,
            branchOrigin: origin
        )
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-\(session.id).json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        let sidebarEntry = try XCTUnwrap(record.sidebarEntry())

        XCTAssertEqual(record.branchRootSessionID, rootID)
        XCTAssertEqual(record.branchSourceTurnOrdinal, 2)
        XCTAssertEqual(record.branchCreatedAt, origin.createdAt)
        XCTAssertEqual(sidebarEntry.branchRootSessionID, rootID)
        XCTAssertEqual(sidebarEntry.branchSourceTurnOrdinal, 2)
        XCTAssertEqual(sidebarEntry.branchCreatedAt, origin.createdAt)

        let encoded = try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [record]))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "branchSourceTurnOrdinal")
        entries[0].removeValue(forKey: "branchCreatedAt")
        payload["entries"] = entries
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let legacy = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: legacyData)
        XCTAssertNil(legacy.entries[0].branchSourceTurnOrdinal)
        XCTAssertNil(legacy.entries[0].branchCreatedAt)
        XCTAssertEqual(legacy.schemaVersion, AgentSessionMetadataIndex.currentSchemaVersion)
        XCTAssertEqual(AgentSession.currentSerializationVersion, 7)
    }

    private func makeBranchRecord(
        id: UUID,
        rootID: UUID,
        ordinal: Int?,
        createdAt: Date?,
        savedAt: Date
    ) -> AgentSessionMetadataRecord {
        let session = AgentSession(
            id: id,
            workspaceID: UUID(),
            name: "Branch",
            savedAt: savedAt,
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: AgentSessionBranchOrigin(
                rootSessionID: rootID,
                sourceSessionID: rootID,
                sourceTurnID: UUID(),
                sourceCodexTurnID: "turn",
                sourceTurnOrdinal: ordinal ?? 1,
                createdAt: createdAt ?? savedAt
            )
        )
        var record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-\(id).json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        record.branchSourceTurnOrdinal = ordinal
        record.branchCreatedAt = createdAt
        return record
    }

    private func makeLedger(
        targetID: UUID,
        omitted: [CodexTurnCheckpoint.SideEffect]
    ) -> CodexTurnCheckpointLedger {
        let target = CodexTurnCheckpoint(
            turnID: targetID,
            codexTurnID: "target",
            status: .completed,
            sideEffect: .readOnly,
            recordedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let suffix = omitted.enumerated().map { index, sideEffect in
            CodexTurnCheckpoint(
                turnID: UUID(),
                codexTurnID: "omitted-\(index)",
                status: .completed,
                sideEffect: sideEffect,
                recordedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index + 2))
            )
        }
        return CodexTurnCheckpointLedger(threadID: "thread", entries: [target] + suffix)
    }

    private func makeCheckpoint(
        turnID: UUID,
        codexTurnID: String,
        sideEffect: CodexTurnCheckpoint.SideEffect
    ) -> CodexTurnCheckpoint {
        CodexTurnCheckpoint(
            turnID: turnID,
            codexTurnID: codexTurnID,
            status: .completed,
            sideEffect: sideEffect,
            recordedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private enum TestBranchFailure: LocalizedError {
        case failed

        var errorDescription: String? {
            "Localized branch failure"
        }
    }
}
