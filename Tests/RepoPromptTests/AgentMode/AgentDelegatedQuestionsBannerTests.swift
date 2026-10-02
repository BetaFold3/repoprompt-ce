import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentDelegatedQuestionsBannerTests: XCTestCase {
    func testReservedHeightIncludesSpacingForVisibleAndOverflowRows() {
        let cases: [(name: String, rowCount: Int, expectedHeight: CGFloat)] = [
            ("empty", 0, 0),
            ("one row", 1, 32),
            ("two rows", 2, 54),
            ("three rows", 3, 76),
            ("first overflow row", 4, 98),
            ("multiple overflow rows", 8, 98)
        ]

        for testCase in cases {
            XCTAssertEqual(
                AgentDelegatedQuestionsBanner.reservedHeight(rowCount: testCase.rowCount),
                testCase.expectedHeight,
                testCase.name
            )
        }
    }
}
