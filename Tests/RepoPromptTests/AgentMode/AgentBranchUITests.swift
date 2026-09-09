@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentBranchUITests: XCTestCase {
    func testConversationBranchShortcutRequestIsWindowScopedAndRequiresMenu() {
        XCTAssertTrue(AgentConversationTreeRequestGate.shouldAccept(
            requestWindowID: 7,
            currentWindowID: 7,
            hasActiveAgentTab: true
        ))
        XCTAssertFalse(AgentConversationTreeRequestGate.shouldAccept(
            requestWindowID: 8,
            currentWindowID: 7,
            hasActiveAgentTab: true
        ))
        XCTAssertFalse(AgentConversationTreeRequestGate.shouldAccept(
            requestWindowID: 7,
            currentWindowID: 7,
            hasActiveAgentTab: false
        ))
    }

    @MainActor
    func testConversationBranchShortcutPresentationConsumesEachRequestOnce() {
        let state = AgentConversationTreePickerState()
        let first = request()
        state.present(first)
        state.focusOrPresent(request())
        XCTAssertEqual(state.request?.id, first.id)
        state.dismiss()
        XCTAssertNil(state.request)
    }

    func testOnlyConclusionBlocksAreEligibleForReplyBranchControl() {
        XCTAssertTrue(AgentReplyBranchPresentation.isEligibleBlock(.conclusion))
        XCTAssertFalse(AgentReplyBranchPresentation.isEligibleBlock(.request))
        XCTAssertFalse(AgentReplyBranchPresentation.isEligibleBlock(.middleSummary))
    }

    func testDisabledHelpTextUsesExactPhaseFourCopy() {
        XCTAssertEqual(
            AgentReplyBranchPresentation.helpText(for: .providerUnsupported(.openCode)),
            AgentBranchSafetySummary.providerUnavailableText
        )
        XCTAssertEqual(
            AgentReplyBranchPresentation.helpText(for: .runtimeCapabilityUnknown),
            AgentBranchSafetySummary.runtimeCheckingText
        )
        XCTAssertEqual(
            AgentReplyBranchPresentation.helpText(for: .runtimeUnsupported(.versionBelowFloor)),
            AgentBranchSafetySummary.runtimeVersionText
        )
        XCTAssertEqual(
            AgentReplyBranchPresentation.helpText(for: .runtimeUnsupported(.probeFailed)),
            AgentBranchSafetySummary.runtimeUnverifiedText
        )
    }

    func testReadOnlyConfirmationUsesExactCopyAndBranchLabel() {
        let summary = AgentBranchSafetySummary(
            retainedTurnCount: 2,
            omittedTurnCount: 1,
            impact: .readOnly
        )
        XCTAssertEqual(summary.turnSummaryText, "Keeps turns 1–2 · sets aside 1 later turn(s)")
        XCTAssertEqual(summary.impactText, "Read-only exploration")
        XCTAssertEqual(summary.branchButtonTitle, "Branch")
        XCTAssertEqual(
            AgentBranchSafetySummary.rollbackDisclosure,
            "Conversation only — files, Git state, and workspace selections are not rolled back."
        )
    }

    func testOracleDisclosureUsesExactSingularAndPluralCopy() {
        XCTAssertEqual(
            AgentBranchSafetySummary(
                retainedTurnCount: 1,
                omittedTurnCount: 0,
                impact: .readOnly,
                sourceOwnedOracleChatCount: 1
            ).oracleDisclosureText,
            "1 Oracle chat stays with the source path — this branch can read its results but must start a new chat to continue."
        )
        XCTAssertEqual(
            AgentBranchSafetySummary(
                retainedTurnCount: 1,
                omittedTurnCount: 0,
                impact: .readOnly,
                sourceOwnedOracleChatCount: 2
            ).oracleDisclosureText,
            "2 Oracle chats stay with the source path — this branch can read their results but must start new chats to continue."
        )
    }

    func testWorstOfOmittedSideEffectsControlsWarningAndBranchAnywayLabel() {
        let summary = safety(omitted: [.readOnly, .modified(paths: ["a.swift"])])
        XCTAssertEqual(summary.impact, .modified(paths: ["a.swift"]))
        XCTAssertEqual(summary.branchButtonTitle, "Branch anyway")
    }

    func testProgressStateDisablesAnOtherwiseAvailablePresentation() {
        let turnID = UUID()
        let presentation = AgentReplyBranchPresentation(
            turnID: turnID,
            availability: .available(checkpoint(turnID).agentBranchCheckpoint),
            isOperationInProgress: true
        )
        XCTAssertFalse(presentation.isAvailable)
    }

    func testSparseLedgerUsesTranscriptOrdinalAndMissingOmittedCheckpointIsUnknown() {
        let target = UUID()
        let missing = UUID()
        let index = AgentBranchCheckpointIndex(checkpoints: [checkpoint(target).agentBranchCheckpoint])
        let summary = AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: [target, missing],
            checkpointIndex: index
        )
        XCTAssertEqual(summary.retainedTurnCount, 1)
        XCTAssertEqual(summary.impact, .unknown)
    }

    func testTranscriptLeafHasZeroOmittedTurnsAndReadOnlyImpactWithoutSuffixCheckpoints() {
        let target = UUID()
        let summary = AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: [UUID(), target],
            checkpointIndex: nil
        )
        XCTAssertEqual(summary.turnSummaryText, "Keeps turns 1–2 · nothing set aside")
        XCTAssertEqual(summary.impact, .readOnly)
    }

    func testModifiedPathDisclosureCapsAtEightPaths() {
        let paths = (1 ... 10).map { "file-\($0).swift" }
        let summary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 1,
            impact: .modified(paths: paths)
        )
        XCTAssertTrue(summary.impactText.contains("file-8.swift, and 2 more"))
        XCTAssertFalse(summary.impactText.contains("file-9.swift"))
    }

    @MainActor
    func testConfirmationSubmissionKeepsCapturedPresentationUntilSuccess() {
        let state = AgentConversationTreePickerState()
        let first = request()
        state.present(first)
        state.present(request())
        XCTAssertEqual(state.request?.id, first.id)
    }

    @MainActor
    func testConfirmationFailureKeepsPresentationAndShowsLocalizedError() async {
        let model = failingModel()
        _ = await model.submit()
        guard case .preCommitFailed("Localized branch failure") = model.operation else {
            return XCTFail("Expected pre-commit failure")
        }
    }

    func testConversationBranchMenuUsesCapturedSnapshotAndExactDisabledCopy() {
        let path = path(evidence: .deleted)
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [path])
        guard case let .path(projected) = nodes.first?.kind else {
            return XCTFail("Expected path")
        }
        XCTAssertEqual(projected.evidence, .deleted)
    }

    func testConversationBranchRecordOrderingUsesOrdinalThenDateThenUUID() {
        let early = path(savedAt: Date(timeIntervalSinceReferenceDate: 1), sourceOrdinal: 1)
        let late = path(savedAt: Date(timeIntervalSinceReferenceDate: 2), sourceOrdinal: 2)
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [late, early])
        XCTAssertEqual(nodes.map(\.id), [.path(early.id), .path(late.id)])
    }

    func testConversationBranchLabelsDistinguishSameDayBranchesByTime() {
        let first = path(savedAt: Date(timeIntervalSinceReferenceDate: 1))
        let second = path(savedAt: Date(timeIntervalSinceReferenceDate: 2))
        XCTAssertNotEqual(first.savedAt, second.savedAt)
    }

    func testBranchLineageProjectsIntoWarmIndexAndSidebarEntry() {
        let root = path()
        let child = path(sourceID: root.id, sourceOrdinal: 1)
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, child])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].children.first?.children.first?.id, .path(child.id))
    }

    func testDuplicateOmittedCheckpointFailsClosedAsUnknownImpact() {
        let target = UUID()
        let duplicate = UUID()
        let index = AgentBranchCheckpointIndex(checkpoints: [
            checkpoint(target).agentBranchCheckpoint,
            checkpoint(duplicate, native: "one").agentBranchCheckpoint,
            checkpoint(duplicate, native: "two").agentBranchCheckpoint
        ])
        let summary = AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: [target, duplicate],
            checkpointIndex: index
        )
        XCTAssertEqual(summary.impact, .unknown)
    }

    func testConfirmationFailsClosedWhenSelectedTurnIsNotUnique() {
        let id = UUID()
        let summary = AgentBranchSafetySummary(
            turnID: id,
            transcriptTurnIDs: [id, id],
            checkpointIndex: nil
        )
        XCTAssertFalse(summary.hasResolvedTurn)
    }

    func testDeletedRootWithSoleSurvivingBranchProjectsTwoVisibleMembers() {
        let rootID = UUID()
        let deleted = AgentConversationTreePickerPath(
            id: rootID,
            name: "Original (deleted)",
            savedAt: .distantPast,
            sourceSessionID: nil,
            sourceTurnID: nil,
            sourceTurnOrdinal: nil,
            isActive: false,
            isOpenElsewhere: false,
            evidence: .deleted,
            turns: []
        )
        let branch = path(sourceID: rootID, sourceOrdinal: 1)
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [deleted, branch])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].children.first?.id, .missingTurn(sessionID: rootID, ordinal: 1))
    }

    @MainActor
    private func request() -> AgentConversationTreePresentationRequest {
        AgentConversationTreePresentationRequest(
            id: UUID(),
            tabID: UUID(),
            initialSelection: .latestCompletedTurn,
            model: model()
        )
    }

    @MainActor
    private func model() -> AgentConversationTreePickerModel {
        AgentConversationTreePickerModel(
            phase: .ready,
            paths: [path(isActive: true)],
            initialSelection: nil,
            loadPath: { _ in throw TestFailure.failed },
            performBranch: { _ in },
            performSwitch: { _ in }
        )
    }

    @MainActor
    private func failingModel() -> AgentConversationTreePickerModel {
        let turn = pickerTurn()
        return AgentConversationTreePickerModel(
            phase: .ready,
            paths: [path(isActive: true, turns: [turn])],
            initialSelection: .turn(turn.id),
            loadPath: { _ in throw TestFailure.failed },
            performBranch: { _ in throw TestFailure.failed },
            performSwitch: { _ in }
        )
    }

    private func safety(omitted: [AgentTurnSideEffect]) -> AgentBranchSafetySummary {
        let target = UUID()
        let entries = [checkpoint(target)] + omitted.enumerated().map {
            checkpoint(UUID(), native: "omitted-\($0.offset)", sideEffect: $0.element)
        }
        return AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: entries.map(\.turnID),
            checkpointIndex: AgentBranchCheckpointIndex(
                checkpoints: entries.map(\.agentBranchCheckpoint)
            )
        )
    }

    private func checkpoint(
        _ turnID: UUID,
        native: String = "native",
        sideEffect: AgentTurnSideEffect = .readOnly
    ) -> CodexTurnCheckpoint {
        CodexTurnCheckpoint(
            turnID: turnID,
            codexTurnID: native,
            status: .completed,
            sideEffect: sideEffect,
            recordedAt: .distantPast
        )
    }

    private func pickerTurn() -> AgentConversationTreePickerTurn {
        let sessionID = UUID()
        let turnID = UUID()
        return AgentConversationTreePickerTurn(
            id: .init(sessionID: sessionID, turnID: turnID),
            ordinal: 1,
            prompt: "Prompt",
            conclusion: "Conclusion",
            availability: .available(checkpoint(turnID).agentBranchCheckpoint),
            safetySummary: AgentBranchSafetySummary(
                retainedTurnCount: 1,
                omittedTurnCount: 0,
                impact: .readOnly
            ),
            isCompleted: true
        )
    }

    private func path(
        savedAt: Date = .distantPast,
        sourceID: UUID? = nil,
        sourceOrdinal: Int? = nil,
        isActive: Bool = false,
        evidence: AgentConversationTreePickerPath.Evidence = .available,
        turns: [AgentConversationTreePickerTurn]? = []
    ) -> AgentConversationTreePickerPath {
        AgentConversationTreePickerPath(
            id: UUID(),
            name: "Path",
            savedAt: savedAt,
            sourceSessionID: sourceID,
            sourceTurnID: nil,
            sourceTurnOrdinal: sourceOrdinal,
            isActive: isActive,
            isOpenElsewhere: false,
            evidence: evidence,
            turns: turns
        )
    }

    private enum TestFailure: LocalizedError {
        case failed
        var errorDescription: String? {
            "Localized branch failure"
        }
    }
}
