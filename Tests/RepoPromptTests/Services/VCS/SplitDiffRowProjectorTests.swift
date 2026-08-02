@testable import RepoPromptApp
import XCTest

final class SplitDiffRowProjectorTests: XCTestCase {
    func testEqualDeletionAdditionRunsPairLineByLine() {
        let rows = SplitDiffRowProjector.rows(for: hunk([
            line("d1", .deletion, old: 10, new: nil),
            line("d2", .deletion, old: 11, new: nil),
            line("a1", .addition, old: nil, new: 10),
            line("a2", .addition, old: nil, new: 11)
        ]))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0.old?.oldLine }, [10, 11])
        XCTAssertEqual(rows.map { $0.new?.newLine }, [10, 11])
        XCTAssertTrue(rows.allSatisfy { !$0.spansBoth })
    }

    func testUnequalRunsLeaveTheExtraLineOppositeAnEmptyCell() {
        let rows = SplitDiffRowProjector.rows(for: hunk([
            line("d1", .deletion, old: 10, new: nil),
            line("d2", .deletion, old: 11, new: nil),
            line("a1", .addition, old: nil, new: 10)
        ]))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].old?.oldLine, 10)
        XCTAssertEqual(rows[0].new?.newLine, 10)
        XCTAssertEqual(rows[1].old?.oldLine, 11)
        XCTAssertNil(rows[1].new)
    }

    func testContextSpansBothSidesAndRetainsItsNumberPair() {
        let context = line("c", .context, old: 30, new: 32)
        let rows = SplitDiffRowProjector.rows(for: hunk([context]))

        XCTAssertEqual(rows, [
            .init(id: "c", old: context, new: context, spansBoth: true)
        ])
        XCTAssertEqual(rows[0].old?.oldLine, 30)
        XCTAssertEqual(rows[0].new?.newLine, 32)
    }

    private func hunk(_ lines: [FileDiffProjection.Line]) -> FileDiffProjection.Hunk {
        FileDiffProjection.Hunk(
            id: "file#0",
            oldStart: 10,
            oldCount: 2,
            newStart: 10,
            newCount: 2,
            heading: nil,
            lines: lines
        )
    }

    private func line(
        _ id: String,
        _ kind: FileDiffProjection.LineKind,
        old: Int?,
        new: Int?
    ) -> FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: id,
            kind: kind,
            oldLine: old,
            newLine: new,
            text: id
        )
    }
}
