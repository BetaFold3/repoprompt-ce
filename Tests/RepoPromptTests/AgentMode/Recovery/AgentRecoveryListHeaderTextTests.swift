@testable import RepoPromptApp
import XCTest

/// Lossless restart F3: the banner header counts this session's rows and never contradicts the
/// "Needs Attention (n)…" button, which counts items elsewhere.
@MainActor
final class AgentRecoveryListHeaderTextTests: XCTestCase {
    private func row(_ id: String) -> AgentRecoveryListRowProps {
        AgentRecoveryListRowProps(
            id: id,
            sessionID: UUID(),
            sessionName: "Session",
            title: "Interrupted turn",
            detail: "Detail",
            text: nil,
            attachmentNames: [],
            actions: [.dismiss],
            isWorking: false,
            error: nil
        )
    }

    private func props(rows: Int, other: Int, status: AgentRecoveryListProps.Status = .ready) -> AgentRecoveryListProps {
        AgentRecoveryListProps(
            status: status,
            rows: (0 ..< rows).map { row("row-\($0)") },
            canRetry: false,
            otherItemCount: other
        )
    }

    func testNoRowsHereButItemsElsewhereUsesNeutralText() {
        let many = props(rows: 0, other: 64)
        XCTAssertFalse(many.isEmpty, "Items elsewhere keep the banner for its Needs Attention button")
        XCTAssertEqual(many.headerText, "Nothing interrupted in this session. 64 items elsewhere need attention.")
        XCTAssertFalse(many.headerText.contains("0 saved"))
        XCTAssertEqual(
            props(rows: 0, other: 1).headerText,
            "Nothing interrupted in this session. 1 item elsewhere needs attention."
        )
    }

    func testRowsHereOnlyCountThisSession() {
        XCTAssertEqual(props(rows: 1, other: 0).headerText, "1 saved or interrupted item needs your attention.")
        XCTAssertEqual(props(rows: 3, other: 0).headerText, "3 saved or interrupted items need your attention.")
    }

    func testRowsHereAndElsewhereKeepBothCountsDistinct() {
        XCTAssertEqual(
            props(rows: 1, other: 5).headerText,
            "1 saved or interrupted item in this session needs your attention. 5 items elsewhere need attention."
        )
        XCTAssertEqual(
            props(rows: 2, other: 1).headerText,
            "2 saved or interrupted items in this session need your attention. 1 item elsewhere needs attention."
        )
    }

    func testEmptyIsHiddenAndNeverClaimsZeroItemsNeedAttention() {
        let empty = props(rows: 0, other: 0)
        XCTAssertTrue(empty.isEmpty, "Nothing here and nothing elsewhere: the banner is not shown")
        XCTAssertEqual(empty.headerText, "Nothing interrupted in this session.")
    }

    func testDismissedCrashHoldIndicatorCountsAsThisSessionsItem() {
        // The paused indicator of a dismissed crash hold is this session's only row.
        let indicator = AgentRecoveryListProps(
            status: .ready,
            rows: [row("\(AgentModeViewModel.recoveryListPausedRowPrefix)\(UUID().uuidString)")],
            canRetry: false,
            otherItemCount: 0
        )
        XCTAssertEqual(indicator.headerText, "1 saved or interrupted item needs your attention.")
        let withElsewhere = AgentRecoveryListProps(status: .ready, rows: indicator.rows, canRetry: false, otherItemCount: 4)
        XCTAssertEqual(
            withElsewhere.headerText,
            "1 saved or interrupted item in this session needs your attention. 4 items elsewhere need attention."
        )
    }

    func testLoadingAndFailedStatusesAreUnchanged() {
        XCTAssertEqual(
            props(rows: 0, other: 3, status: .loading).headerText,
            "Checking for work interrupted when RepoPrompt last closed…"
        )
        XCTAssertEqual(props(rows: 0, other: 3, status: .failed("Paused.")).headerText, "Paused.")
    }
}
