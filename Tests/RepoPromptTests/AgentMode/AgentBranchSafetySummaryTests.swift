@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentBranchSafetySummaryTests: XCTestCase {
    func testExactZeroOmissionAndRollbackStrings() {
        let summary = AgentBranchSafetySummary(
            retainedTurnCount: 3,
            omittedTurnCount: 0,
            impact: .readOnly
        )
        XCTAssertEqual(summary.turnSummaryText, "Keeps turns 1–3 · nothing set aside")
        XCTAssertEqual(summary.impactText, "Read-only exploration")
        XCTAssertEqual(
            AgentBranchSafetySummary.rollbackDisclosure,
            "Conversation only — files, Git state, and workspace selections are not rolled back."
        )
    }

    func testChangedPathsDeduplicateInCheckpointOrderAndCapAtEight() {
        let target = UUID()
        let omitted = UUID()
        let paths = (1 ... 10).map { "file-\($0).swift" }
        let summary = AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: [target, omitted],
            checkpointIndex: AgentBranchCheckpointIndex(checkpoints: [
                checkpoint(target, .readOnly),
                checkpoint(omitted, .modified(paths: paths + [paths[0]]))
            ])
        )
        XCTAssertEqual(summary.impact, .modified(paths: paths))
        XCTAssertEqual(
            summary.impactText,
            "Changed files: file-1.swift, file-2.swift, file-3.swift, file-4.swift, file-5.swift, file-6.swift, file-7.swift, file-8.swift, and 2 more"
        )
    }

    func testUnknownOrIncompleteOmittedCheckpointFailsClosed() {
        let target = UUID()
        let omitted = UUID()
        let summary = AgentBranchSafetySummary(
            turnID: target,
            transcriptTurnIDs: [target, omitted],
            checkpointIndex: AgentBranchCheckpointIndex(checkpoints: [
                checkpoint(target, .readOnly)
            ])
        )
        XCTAssertEqual(summary.impact, .unknown)
        XCTAssertEqual(summary.impactText, "May have changed files")
        XCTAssertEqual(summary.branchButtonTitle, "Branch anyway")
    }

    func testOracleDisclosureUsesSourcePathWording() {
        let summary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 2,
            impact: .unknown,
            sourceOwnedOracleChatCount: 4
        )
        XCTAssertEqual(
            summary.oracleDisclosureText,
            "4 Oracle chats stay with the source path — this branch can read their results but must start new chats to continue."
        )
    }

    func testStaleProviderAndRuntimeStringsArePinned() {
        XCTAssertEqual(
            AgentBranchSafetySummary.staleText,
            "The conversation changed. Review the updated branch details."
        )
        XCTAssertEqual(
            AgentBranchSafetySummary.providerUnavailableText,
            "Native branching is currently available only for local Codex and Claude Code sessions."
        )
        XCTAssertEqual(
            AgentBranchSafetySummary.runtimeCheckingText,
            "Checking Claude Code branching support…"
        )
    }

    private func checkpoint(
        _ turnID: UUID,
        _ sideEffect: AgentTurnSideEffect
    ) -> AgentBranchCheckpoint {
        AgentBranchCheckpoint(
            turnID: turnID,
            status: .completed,
            sideEffect: sideEffect,
            nativeRef: .codexTurn(id: turnID.uuidString),
            recordedAt: .distantPast
        )
    }

    func testChangedPathDisclosureExpandsPastEight() {
        let paths = (1 ... 10).map { "file-\($0).swift" }
        let summary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 1,
            impact: .modified(paths: paths)
        )

        XCTAssertTrue(summary.hasCollapsedChangedPaths)
        XCTAssertTrue(summary.impactText.contains("and 2 more"))
        XCTAssertTrue(summary.impactText(expanded: true).contains("file-10.swift"))
        XCTAssertFalse(summary.impactText(expanded: true).contains("and 2 more"))
    }
}
