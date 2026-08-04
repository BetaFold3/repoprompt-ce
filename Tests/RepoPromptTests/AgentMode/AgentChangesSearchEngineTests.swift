import Foundation
@testable import RepoPromptApp
import XCTest

/// Pure matching contract for in-diff search.
///
/// The suite constructs projections directly so failures identify search semantics rather than
/// repository loading, debounce, or view-model orchestration.
final class AgentChangesSearchEngineTests: XCTestCase {
    func testLiteralMatchingIgnoresCaseAndDiacriticsWhileReturningOriginalUTF16Ranges() {
        let text = "👩🏽‍💻 CAFÉ cafe\u{0301} 中文"

        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(of: "cafe", in: text),
            [8 ..< 12, 13 ..< 18],
            "A decomposed accent occupies an extra UTF-16 unit in the displayed string"
        )
        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(of: "👩🏽‍💻", in: text),
            [0 ..< 7],
            "The emoji grapheme spans seven UTF-16 units and must remain one match"
        )
        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(of: "中文", in: text),
            [19 ..< 21],
            "CJK characters retain their original two-unit range"
        )
    }

    func testMultipleOccurrencesAdvanceFromThePriorStartWithoutLosingOverlaps() {
        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(of: "ana", in: "bananana"),
            [1 ..< 4, 3 ..< 6, 5 ..< 8]
        )
    }

    func testOverlapAdvancementFindsRepeatedScalarsInsideOneZWJGrapheme() {
        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(of: "👩", in: "👩‍👩"),
            [0 ..< 2, 3 ..< 5]
        )
    }

    func testLiteralEnumerationStopsAtTheSuppliedMatchLimit() {
        let text = String(repeating: "a", count: 100_000)

        XCTAssertEqual(
            AgentChangesSearchEngine.literalUTF16Ranges(
                of: "a",
                in: text,
                maximumMatchCount: 7
            ),
            (0 ..< 7).map { $0 ..< ($0 + 1) }
        )
    }

    func testProjectedSearchDistinguishesPathHeadingAndEveryBodyLineKind() {
        let document = makeDocument(
            path: "Sources/Café.swift",
            heading: "render Café",
            lines: [
                makeLine(id: "h0#0", kind: .context, oldLine: 1, newLine: 1, text: "café context"),
                makeLine(id: "h0#1", kind: .deletion, oldLine: 2, newLine: nil, text: "remove café"),
                makeLine(id: "h0#2", kind: .addition, oldLine: nil, newLine: 2, text: "add CAFÉ")
            ]
        )

        let matches = AgentChangesSearchEngine.matches(
            query: "cafe",
            rowKey: AgentChangesRowKey(
                groupID: AgentChangesGroupID(targetKey: "repo"),
                rowID: "unstaged:Sources/Café.swift"
            ),
            groupOrder: 0,
            sectionOrder: 0,
            rowOrder: 0,
            document: document
        )

        XCTAssertEqual(matches.map(\.displayedText), [
            "Sources/Café.swift",
            "render Café",
            "café context",
            "remove café",
            "add CAFÉ"
        ])
        XCTAssertEqual(matches.map(\.utf16Range), [
            8 ..< 12,
            7 ..< 11,
            0 ..< 4,
            7 ..< 11,
            4 ..< 8
        ])
        XCTAssertEqual(matches.map(\.locator), [
            .filePath,
            .hunkHeading(hunkID: "Sources/Café.swift#0"),
            .line(kind: .context, oldLine: 1, newLine: 1),
            .line(kind: .deletion, oldLine: 2, newLine: nil),
            .line(kind: .addition, oldLine: nil, newLine: 2)
        ])
    }

    func testNoNewlineMarkersUseTheRenderersExactDisplayedTextAndRange() {
        let document = makeDocument(
            lines: [
                makeLine(
                    id: "h0#0",
                    kind: .noNewlineMarker,
                    oldLine: nil,
                    newLine: nil,
                    text: " No newline at end of file "
                )
            ]
        )

        let matches = AgentChangesSearchEngine.patchMatches(
            query: "No newline",
            rowKey: AgentChangesRowKey(
                groupID: AgentChangesGroupID(targetKey: "repo"),
                rowID: "unstaged:file.swift"
            ),
            groupOrder: 0,
            sectionOrder: 0,
            rowOrder: 0,
            document: document
        )

        // The patch view draws `line.text` verbatim, so the match text and its UTF-16 offsets must
        // index that same string rather than a normalised copy of it.
        XCTAssertEqual(matches.map(\.displayedText), [" No newline at end of file "])
        XCTAssertEqual(matches.map(\.utf16Range), [1 ..< 11])
        XCTAssertEqual(
            matches.map(\.locator),
            [.line(kind: .noNewlineMarker, oldLine: nil, newLine: nil)]
        )
    }

    func testOrderingUsesGroupSectionRowLocatorRenderedElementAndUTF16Offset() {
        let unordered = [
            makeMatch("group 1", group: 1, section: 0, row: 0, locator: .filePath),
            makeMatch("section 1", group: 0, section: 1, row: 0, locator: .filePath),
            makeMatch("row 1", group: 0, section: 0, row: 1, locator: .filePath),
            makeMatch(
                "line order 1",
                locatorOrder: 1,
                locator: .line(kind: .context, oldLine: 2, newLine: 2)
            ),
            makeMatch(
                "line offset 5",
                locatorOrder: 0,
                locator: .line(kind: .context, oldLine: 1, newLine: 1),
                range: 5 ..< 7
            ),
            makeMatch(
                "heading order 1",
                locatorOrder: 1,
                locator: .hunkHeading(hunkID: "h1")
            ),
            makeMatch("path", locator: .filePath),
            makeMatch(
                "line offset 1",
                locatorOrder: 0,
                locator: .line(kind: .context, oldLine: 1, newLine: 1),
                range: 1 ..< 3
            ),
            makeMatch(
                "heading order 0",
                locatorOrder: 0,
                locator: .hunkHeading(hunkID: "h0")
            )
        ]

        let ordered = AgentChangesSearchEngine.ordered(unordered)

        XCTAssertEqual(ordered.map(\.displayedText), [
            "path",
            "heading order 0",
            "heading order 1",
            "line offset 1",
            "line offset 5",
            "line order 1",
            "row 1",
            "section 1",
            "group 1"
        ])
        XCTAssertEqual(Set(ordered.map(\.id)).count, ordered.count)
    }

    func testBudgetAccountingCountsExaminedBytesSkippedFilesAndDroppedMatches() {
        var accounting = AgentChangesSearchBudgetAccounting(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 10,
                maximumMatchCount: 3
            )
        )

        accounting.record(
            AgentChangesSearchPatchDocument(
                document: makeDocument(),
                byteCount: 6
            )
        )
        accounting.record(.unavailable(byteCount: 4))
        let accepted = accounting.accept([
            makeMatch("0"),
            makeMatch("1", range: 1 ..< 2),
            makeMatch("2", range: 2 ..< 3),
            makeMatch("3", range: 3 ..< 4),
            makeMatch("4", range: 4 ..< 5)
        ])
        accounting.recordBudgetExcludedFiles(2)

        XCTAssertEqual(accounting.examinedByteCount, 10)
        XCTAssertEqual(accepted.count, 3)
        XCTAssertEqual(accounting.matchCount, 3)
        XCTAssertEqual(accounting.skippedFileCount, 3)
        XCTAssertTrue(accounting.isTruncated)
        XCTAssertFalse(accounting.canScheduleMore)
    }

    func testBatchwiseCorpusOrderAdmissionMatchesDeterministicGlobalOrderingWithinBudget() {
        let corpusOrdered = [
            makeMatch("row 0 offset 0", row: 0, range: 0 ..< 1),
            makeMatch("row 0 offset 2", row: 0, range: 2 ..< 3),
            makeMatch("row 1 offset 0", row: 1, range: 0 ..< 1),
            makeMatch("row 2 offset 0", row: 2, range: 0 ..< 1)
        ]
        let budget = AgentChangesSearchBudget(
            maximumExaminedByteCount: 100,
            maximumMatchCount: 10
        )
        var batched = AgentChangesSearchBudgetAccounting(budget: budget)
        batched.accept(Array(corpusOrdered[0 ..< 2]))
        batched.accept(Array(corpusOrdered[2 ..< 3]))
        batched.accept(Array(corpusOrdered[3 ..< 4]))
        var sorted = AgentChangesSearchBudgetAccounting(budget: budget)
        sorted.accept(AgentChangesSearchEngine.ordered(Array(corpusOrdered.reversed())))

        XCTAssertEqual(batched.matches, AgentChangesSearchEngine.ordered(corpusOrdered))
        XCTAssertEqual(batched.matches, sorted.matches)
        XCTAssertFalse(batched.isTruncated)
    }

    func testCapSpentOnAnEarlyRowsPatchLinesBeatsALaterRowsPath() {
        var accounting = AgentChangesSearchBudgetAccounting(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 100,
                maximumMatchCount: 3
            )
        )

        // One batch carries each row's path match and its patch matches together, so the cap is
        // spent in corpus order. Admitting every path first would keep "row 2 path" and drop both
        // of row 0's patch lines, which the ranking comparator disagrees with.
        accounting.accept(AgentChangesSearchEngine.ordered([
            makeMatch("row 2 path", row: 2),
            makeMatch("row 0 patch line 2", row: 0, locatorOrder: 1, locator: .line(
                kind: .addition, oldLine: nil, newLine: 8
            )),
            makeMatch("row 1 path", row: 1),
            makeMatch("row 0 path", row: 0),
            makeMatch("row 0 patch line 1", row: 0, locatorOrder: 0, locator: .line(
                kind: .context, oldLine: 7, newLine: 7
            ))
        ]))

        XCTAssertFalse(accounting.canScheduleMore)
        XCTAssertTrue(accounting.isTruncated)
        XCTAssertEqual(
            accounting.matches.map(\.displayedText),
            ["row 0 path", "row 0 patch line 1", "row 0 patch line 2"]
        )
    }

    func testMatchBudgetKeepsTheGlobalTopResultsWhenEarlierRowsFinishLater() {
        var accounting = AgentChangesSearchBudgetAccounting(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 100,
                maximumMatchCount: 3
            )
        )

        accounting.accept([
            makeMatch("later 0", group: 1, range: 0 ..< 1),
            makeMatch("later 1", group: 1, range: 1 ..< 2),
            makeMatch("later 2", group: 1, range: 2 ..< 3)
        ])
        accounting.accept([
            makeMatch("earlier 0", range: 0 ..< 1),
            makeMatch("earlier 1", range: 1 ..< 2),
            makeMatch("earlier 2", range: 2 ..< 3),
            makeMatch("earlier 3", range: 3 ..< 4)
        ])

        XCTAssertEqual(accounting.matches.map(\.displayedText), [
            "earlier 0",
            "earlier 1",
            "earlier 2"
        ])
        XCTAssertEqual(accounting.matchCount, 3)
        XCTAssertTrue(accounting.isTruncated)
    }

    func testEmptyBatchesAreNoOpsAtNearMaximumMatchCapacity() {
        var accounting = AgentChangesSearchBudgetAccounting(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 100,
                maximumMatchCount: 5000
            )
        )
        let matches = (0 ..< 4999).map {
            makeMatch("match \($0)", row: $0, range: 0 ..< 1)
        }
        accounting.accept(matches)
        let beforeEmptyBatches = accounting

        for _ in 0 ..< 8 {
            accounting.accept([])
        }

        XCTAssertEqual(accounting, beforeEmptyBatches)
        XCTAssertEqual(accounting.matchCount, 4999)
        XCTAssertFalse(accounting.isTruncated)
    }

    func testProjectedDocumentTruncationPropagatesIntoSearchAccounting() {
        let truncated = makeDocument(
            truncation: FileDiffProjection.Truncation(
                projectedLines: 1,
                totalLines: 4
            )
        )
        let searchDocument = AgentChangesSearchPatchDocument(
            document: truncated,
            byteCount: 12
        )
        var accounting = AgentChangesSearchBudgetAccounting()

        accounting.record(searchDocument)

        XCTAssertTrue(searchDocument.isTruncated)
        XCTAssertTrue(accounting.isTruncated)
        XCTAssertEqual(accounting.skippedFileCount, 0)
        XCTAssertEqual(accounting.examinedByteCount, 12)
    }

    func testEmptyAndWhitespaceOnlyQueriesProduceNoRangesOrProjectionMatches() {
        let document = makeDocument(
            path: "blank.swift",
            heading: "   ",
            lines: [
                makeLine(id: "h0#0", kind: .context, oldLine: 1, newLine: 1, text: "some text")
            ]
        )

        for query in ["", " ", "\t\n"] {
            XCTAssertEqual(AgentChangesSearchEngine.literalUTF16Ranges(of: query, in: "some text"), [])
            XCTAssertEqual(
                AgentChangesSearchEngine.matches(
                    query: query,
                    rowKey: AgentChangesRowKey(
                        groupID: AgentChangesGroupID(targetKey: "repo"),
                        rowID: "unstaged:blank.swift"
                    ),
                    groupOrder: 0,
                    sectionOrder: 0,
                    rowOrder: 0,
                    document: document
                ),
                []
            )
        }
    }

    private func makeDocument(
        path: String = "file.swift",
        heading: String? = nil,
        lines: [FileDiffProjection.Line] = [],
        truncation: FileDiffProjection.Truncation? = nil
    ) -> FileDiffProjection.Document {
        FileDiffProjection.Document(
            id: path,
            path: path,
            oldPath: nil,
            change: .modified,
            additions: lines.count { $0.kind == .addition },
            deletions: lines.count { $0.kind == .deletion },
            hunks: [
                FileDiffProjection.Hunk(
                    id: "\(path)#0",
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    heading: heading,
                    lines: lines
                )
            ],
            contextLevel: .lines(3),
            truncation: truncation
        )
    }

    private func makeLine(
        id: String,
        kind: FileDiffProjection.LineKind,
        oldLine: Int?,
        newLine: Int?,
        text: String
    ) -> FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: id,
            kind: kind,
            oldLine: oldLine,
            newLine: newLine,
            text: text
        )
    }

    private func makeMatch(
        _ text: String,
        group: Int = 0,
        section: Int = 0,
        row: Int = 0,
        locatorOrder: Int = 0,
        locator: AgentChangesSearchLocator = .filePath,
        range: Range<Int> = 0 ..< 1
    ) -> AgentChangesSearchMatch {
        AgentChangesSearchMatch(
            rowKey: AgentChangesRowKey(
                // Real row IDs are section-qualified, so a staged and an unstaged view of one file
                // are different rows. Qualifying here keeps fixture identities as distinct as the
                // corpus ones, instead of aliasing two sections onto a single row key.
                groupID: AgentChangesGroupID(targetKey: "repo-\(group)"),
                rowID: "section-\(section):row-\(row)"
            ),
            groupOrder: group,
            sectionOrder: section,
            rowOrder: row,
            locatorOrder: locatorOrder,
            locator: locator,
            utf16Range: range,
            displayedText: text
        )
    }
}
