@testable import RepoPromptApp
import XCTest

final class DiffContextSplicerTests: XCTestCase {
    func testGapRangesCarryAlignedOldAndNewNumberingAtEveryBoundary() {
        let gaps = DiffContextSplicer.gaps(
            in: document(),
            sourceLineCount: 30,
            sourceSide: .new
        )

        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0].location, .beforeFirst)
        XCTAssertEqual(gaps[0].oldRange, 1 ..< 5)
        XCTAssertEqual(gaps[0].newRange, 1 ..< 5)

        XCTAssertEqual(gaps[1].location, .between(leftHunkIndex: 0, rightHunkIndex: 1))
        XCTAssertEqual(gaps[1].oldRange, 8 ..< 20)
        XCTAssertEqual(gaps[1].newRange, 9 ..< 21)

        XCTAssertEqual(gaps[2].location, .afterLast)
        XCTAssertEqual(gaps[2].oldRange, 22 ..< 30)
        XCTAssertEqual(gaps[2].newRange, 23 ..< 31)
    }

    func testExpandingBeforeFirstPrependsContextAndMovesBothHunkStarts() throws {
        let original = document()
        let gap = try XCTUnwrap(DiffContextSplicer.gaps(
            in: original,
            sourceLineCount: 30,
            sourceSide: .new
        ).first)

        let expanded = DiffContextSplicer.splice(
            document: original,
            sourceLines: sourceLines,
            sourceSide: .new,
            gapID: gap.id,
            amount: .all
        )

        let first = try XCTUnwrap(expanded.hunks.first)
        XCTAssertEqual(first.oldStart, 1)
        XCTAssertEqual(first.newStart, 1)
        XCTAssertEqual(first.oldCount, 7)
        XCTAssertEqual(first.newCount, 8)
        XCTAssertEqual(first.lines.prefix(4).map(\.oldLine), [1, 2, 3, 4])
        XCTAssertEqual(first.lines.prefix(4).map(\.newLine), [1, 2, 3, 4])
        XCTAssertEqual(first.lines.prefix(4).map(\.text), ["line 1", "line 2", "line 3", "line 4"])
    }

    func testExpandingTwelveBetweenHunksSplicesFromBothEdgesWithoutRenumberingChanges() throws {
        let original = document()
        let gap = try XCTUnwrap(DiffContextSplicer.gaps(
            in: original,
            sourceLineCount: 30,
            sourceSide: .new
        ).first(where: {
            if case .between = $0.location { return true }
            return false
        }))

        let expanded = DiffContextSplicer.splice(
            document: original,
            sourceLines: sourceLines,
            sourceSide: .new,
            gapID: gap.id,
            amount: .lines(4)
        )

        XCTAssertEqual(expanded.hunks[0].lines.suffix(2).map(\.oldLine), [8, 9])
        XCTAssertEqual(expanded.hunks[0].lines.suffix(2).map(\.newLine), [9, 10])
        XCTAssertEqual(expanded.hunks[1].lines.prefix(2).map(\.oldLine), [18, 19])
        XCTAssertEqual(expanded.hunks[1].lines.prefix(2).map(\.newLine), [19, 20])
        XCTAssertEqual(expanded.hunks[1].oldStart, 18)
        XCTAssertEqual(expanded.hunks[1].newStart, 19)
    }

    func testExpandingAfterLastUsesNewSourceTextWithAlignedOldNumbers() throws {
        let original = document()
        let gap = try XCTUnwrap(DiffContextSplicer.gaps(
            in: original,
            sourceLineCount: 30,
            sourceSide: .new
        ).last)

        let expanded = DiffContextSplicer.splice(
            document: original,
            sourceLines: sourceLines,
            sourceSide: .new,
            gapID: gap.id,
            amount: .all
        )

        let last = try XCTUnwrap(expanded.hunks.last)
        XCTAssertEqual(expanded.oldSourceReference, "base-sha")
        XCTAssertEqual(last.lines.suffix(8).map(\.oldLine), Array(22 ... 29))
        XCTAssertEqual(last.lines.suffix(8).map(\.newLine), Array(23 ... 30))
        XCTAssertEqual(last.lines.suffix(8).map(\.text), Array(23 ... 30).map { "line \($0)" })
    }

    private var sourceLines: [String] {
        Array(1 ... 30).map { "line \($0)" }
    }

    private func document() -> FileDiffProjection.Document {
        FileDiffProjection.Document(
            id: "file.swift",
            path: "file.swift",
            oldPath: nil,
            change: .modified,
            additions: 1,
            deletions: 0,
            hunks: [
                FileDiffProjection.Hunk(
                    id: "file.swift#0",
                    oldStart: 5,
                    oldCount: 3,
                    newStart: 5,
                    newCount: 4,
                    heading: nil,
                    lines: [
                        context("h1", old: 5, new: 5),
                        context("h1-end", old: 7, new: 8)
                    ]
                ),
                FileDiffProjection.Hunk(
                    id: "file.swift#1",
                    oldStart: 20,
                    oldCount: 2,
                    newStart: 21,
                    newCount: 2,
                    heading: nil,
                    lines: [
                        context("h2", old: 20, new: 21),
                        context("h2-end", old: 21, new: 22)
                    ]
                )
            ],
            contextLevel: .lines(3),
            oldSourceReference: "base-sha",
            truncation: nil
        )
    }

    private func context(_ id: String, old: Int, new: Int) -> FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: id,
            kind: .context,
            oldLine: old,
            newLine: new,
            text: id
        )
    }
}
