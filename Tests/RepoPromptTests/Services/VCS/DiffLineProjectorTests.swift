@testable import RepoPromptApp
import XCTest

/// Projection coverage for the Changes panel's diff models.
///
/// The fixtures are shared with `GitDiffPatchParsingGoldenTests`, so the two suites read the same
/// patches through the same walker and any disagreement between the wire format and the panel shows
/// up as a diff between these files rather than as a rendering bug.
final class DiffLineProjectorTests: XCTestCase {
    func testMultiHunkProjectionPairsEveryLineWithItsOldAndNewNumbers() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.modifiedMultiHunk,
            fileKey: "Sources/Alpha.swift",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(document.change, .modified)
        XCTAssertNil(document.oldPath)
        XCTAssertEqual(document.additions, 3)
        XCTAssertEqual(document.deletions, 2)
        XCTAssertNil(document.truncation)
        XCTAssertEqual(document.hunks.count, 2)
        guard document.hunks.count == 2 else { return }

        let first = document.hunks[0]
        XCTAssertEqual([first.oldStart, first.oldCount, first.newStart, first.newCount], [1, 5, 1, 6])
        XCTAssertNil(first.heading)
        XCTAssertEqual(first.lines.map { ProjectedLine($0) }, [
            ProjectedLine(.context, 1, 1, "import Foundation"),
            ProjectedLine(.deletion, 2, nil, "let alpha = 1"),
            ProjectedLine(.addition, nil, 2, "let alpha = 2"),
            ProjectedLine(.addition, nil, 3, "let beta = 3"),
            ProjectedLine(.context, 3, 4, ""),
            ProjectedLine(.context, 4, 5, "func run() {}"),
            ProjectedLine(.context, 5, 6, "let a=1")
        ])

        let second = document.hunks[1]
        XCTAssertEqual([second.oldStart, second.oldCount, second.newStart, second.newCount], [8, 5, 9, 5])
        XCTAssertEqual(second.heading, "let c=3")
        XCTAssertEqual(second.lines.map { ProjectedLine($0) }, [
            ProjectedLine(.context, 8, 9, "let d=4"),
            ProjectedLine(.context, 9, 10, "let e=5"),
            ProjectedLine(.context, 10, 11, "// tail"),
            ProjectedLine(.deletion, 11, nil, "let gamma = 4"),
            ProjectedLine(.addition, nil, 12, "let gamma = 5"),
            ProjectedLine(.context, 12, 13, "let z=9")
        ])
    }

    /// The projector's reason for existing: the wire format drops `--- sql comment` as a file header
    /// and misnumbers everything after it (see `GitDiffPatchParsingGoldenTests`). Inside a hunk the
    /// marker character has to win, or the panel's gutter lies about which line a reviewer is staging.
    func testBodyLinesThatLookLikeFileHeadersKeepTheirPlaceAndNumbering() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.headerLikeBodyLines,
            fileKey: "tricky.txt",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(document.deletions, 4)
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.hunks.first?.lines.map { ProjectedLine($0) }, [
            ProjectedLine(.deletion, 1, nil, "-- sql comment"),
            ProjectedLine(.deletion, 2, nil, "++ plus line"),
            ProjectedLine(.deletion, 3, nil, "--- three dashes"),
            ProjectedLine(.deletion, 4, nil, "normal"),
            ProjectedLine(.addition, nil, 1, "normal only")
        ])
    }

    /// The projector asks for body-wins walking, but the walker owns the rule. A later file's
    /// headers have to end the previous file's hunk, or every `---`/`+++` after the first hunk reads
    /// as deleted and added content and the numbering runs away from there.
    func testBodyWinsWalkingTreatsLaterFileHeadersAsMetadataNotContent() {
        let twoFiles = [
            GitDiffPatchFixtures.headerLikeBodyLines,
            GitDiffPatchFixtures.crlfModified
        ].joined(separator: "\n")

        var hunkStarts: [Int] = []
        var kinds: [FileDiffProjection.LineKind] = []
        var texts: [String] = []
        GitDiffPatchParsing.walkPatch(twoFiles, headerDisambiguation: .bodyWins) { event in
            switch event {
            case let .hunkStart(_, oldStart, _, _, _):
                hunkStarts.append(oldStart)
            case let .line(line):
                kinds.append(line.kind)
                texts.append(String(line.text))
            case .metadata:
                break
            }
        }

        XCTAssertEqual(hunkStarts, [1, 1])
        XCTAssertEqual(kinds, [
            .deletion, .deletion, .deletion, .deletion, .addition,
            .context, .deletion, .addition, .context
        ])
        XCTAssertEqual(texts, [
            "-- sql comment", "++ plus line", "--- three dashes", "normal", "normal only",
            "crlf one\r", "crlf two\r", "crlf two changed\r", "crlf three\r"
        ])
    }

    func testFileChangeKindIsDerivedFromHeaderMetadata() {
        let cases: [(name: String, patch: String, fileKey: String, expected: FileDiffProjection.FileChange)] = [
            ("content edit", GitDiffPatchFixtures.modifiedMultiHunk, "Sources/Alpha.swift", .modified),
            ("new file", GitDiffPatchFixtures.emptyNewFile, "empty-new.txt", .added),
            ("deletion", GitDiffPatchFixtures.deletedFile, "gone.txt", .deleted),
            ("rename", GitDiffPatchFixtures.renamedWithoutContentChange, "moved.txt", .renamed(from: "tomove.txt")),
            ("copy", GitDiffPatchFixtures.copiedWithEdit, "copied.txt", .copied(from: "tocopy.txt")),
            ("mode flip", GitDiffPatchFixtures.modeOnlyChange, "script.sh", .modeOnly),
            ("binary", GitDiffPatchFixtures.binaryDiffer, "blob.bin", .binary),
            ("submodule bump", GitDiffPatchFixtures.submoduleBump, "sub", .submodule),
            ("unmerged path", GitDiffPatchFixtures.conflictedCombined, "c.txt", .conflicted)
        ]

        for testCase in cases {
            let document = DiffLineProjector.project(
                patch: testCase.patch,
                fileKey: testCase.fileKey,
                contextLevel: .lines(3)
            )
            XCTAssertEqual(document.change, testCase.expected, testCase.name)
        }
    }

    /// An untracked file is diffed against an empty tree, so nothing in its patch separates it from
    /// a staged addition; only the status bit the caller passes can.
    func testUntrackedClassificationComesFromStatusNotFromThePatch() {
        let asAddition = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.untrackedAddition,
            fileKey: "untracked.txt",
            contextLevel: .lines(3)
        )
        let asUntracked = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.untrackedAddition,
            fileKey: "untracked.txt",
            contextLevel: .lines(3),
            isUntracked: true
        )

        XCTAssertEqual(asAddition.change, .added)
        XCTAssertEqual(asUntracked.change, .untracked)
        XCTAssertEqual(asAddition.hunks, asUntracked.hunks)
    }

    func testRenameAndCopyOriginsPopulateOldPathAndSurviveGitQuoting() {
        let rename = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.renamedWithoutContentChange,
            fileKey: "moved.txt",
            contextLevel: .lines(3)
        )
        let quotedRename = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.renamedWithQuotedPaths,
            fileKey: "résumé final.txt",
            contextLevel: .lines(3)
        )
        let copy = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.copiedWithEdit,
            fileKey: "copied.txt",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(rename.oldPath, "tomove.txt")
        XCTAssertEqual(rename.hunks, [])
        XCTAssertEqual(quotedRename.oldPath, "café note.txt")
        XCTAssertEqual(quotedRename.change, .renamed(from: "café note.txt"))
        XCTAssertEqual(copy.oldPath, "tocopy.txt")
        XCTAssertEqual(copy.additions, 1)
        XCTAssertEqual(copy.deletions, 1)
    }

    func testNoNewlineMarkersFollowTheirNeighborAndCarryNoNumbers() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.noNewlineOnBothSides,
            fileKey: "nonl.txt",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
        XCTAssertEqual(document.hunks.first?.lines.map { ProjectedLine($0) }, [
            ProjectedLine(.deletion, 1, nil, "no trailing newline"),
            ProjectedLine(.noNewlineMarker, nil, nil, " No newline at end of file"),
            ProjectedLine(.addition, nil, 1, "no trailing newline now longer"),
            ProjectedLine(.noNewlineMarker, nil, nil, " No newline at end of file")
        ])
    }

    func testZeroCountHunksProjectOnlyTheSideThatExists() {
        let added = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.untrackedAddition,
            fileKey: "untracked.txt",
            contextLevel: .lines(3)
        )
        let removed = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.deletedFile,
            fileKey: "gone.txt",
            contextLevel: .lines(3)
        )

        let addedHunk = added.hunks.first
        XCTAssertEqual([addedHunk?.oldStart, addedHunk?.oldCount, addedHunk?.newStart, addedHunk?.newCount], [0, 0, 1, 3])
        XCTAssertEqual(addedHunk?.lines.map(\.oldLine), [nil, nil, nil])
        XCTAssertEqual(addedHunk?.lines.map(\.newLine), [1, 2, 3])

        let removedHunk = removed.hunks.first
        XCTAssertEqual(
            [removedHunk?.oldStart, removedHunk?.oldCount, removedHunk?.newStart, removedHunk?.newCount],
            [1, 3, 0, 0]
        )
        XCTAssertEqual(removedHunk?.lines.map(\.oldLine), [1, 2, 3])
        XCTAssertEqual(removedHunk?.lines.map(\.newLine), [nil, nil, nil])
    }

    func testCarriageReturnsStayInsideTheProjectedLineText() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.crlfModified,
            fileKey: "crlf.txt",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(document.hunks.first?.lines.map(\.text), [
            "crlf one\r",
            "crlf two\r",
            "crlf two changed\r",
            "crlf three\r"
        ])
    }

    /// A combined diff's `@@@` header never parses, so walking it would invent line numbers from a
    /// two-column body. Classifying it keeps the panel honest about what it cannot render yet.
    func testCombinedConflictPatchesAreClassifiedRatherThanWalked() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.conflictedCombined,
            fileKey: "c.txt",
            contextLevel: .lines(3)
        )

        XCTAssertEqual(document.change, .conflicted)
        XCTAssertEqual(document.hunks, [])
        XCTAssertEqual(document.additions, 0)
        XCTAssertEqual(document.deletions, 0)
        XCTAssertNil(document.truncation)
    }

    /// Identity has to be positional, not content-derived: the panel re-projects the same patch on
    /// every refresh while agents edit, and rows must not lose state because a byte moved elsewhere.
    func testProjectionIdentitiesAreStableAcrossRepeatedProjection() {
        func project(maxLines: Int?) -> FileDiffProjection.Document {
            DiffLineProjector.project(
                patch: GitDiffPatchFixtures.modifiedMultiHunk,
                fileKey: "Sources/Alpha.swift",
                contextLevel: .lines(3),
                maxLines: maxLines
            )
        }

        let first = project(maxLines: nil)
        let second = project(maxLines: nil)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "Sources/Alpha.swift")
        XCTAssertEqual(first.hunks.map(\.id), ["Sources/Alpha.swift#0", "Sources/Alpha.swift#1"])
        XCTAssertEqual(first.hunks[0].lines.prefix(3).map(\.id), [
            "Sources/Alpha.swift#0#0",
            "Sources/Alpha.swift#0#1",
            "Sources/Alpha.swift#0#2"
        ])
        XCTAssertEqual(
            project(maxLines: 3).hunks.first?.lines.map(\.id),
            Array(first.hunks[0].lines.prefix(3).map(\.id))
        )
    }

    func testIntralineProjectionIsOptInAndLeavesTheDefaultProjectionUnannotated() {
        let defaultDocument = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.modifiedMultiHunk,
            fileKey: "Sources/Alpha.swift",
            contextLevel: .lines(3)
        )
        let annotated = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.modifiedMultiHunk,
            fileKey: "Sources/Alpha.swift",
            contextLevel: .lines(3),
            computesIntralineDiffs: true
        )

        XCTAssertTrue(defaultDocument.hunks.flatMap(\.lines).allSatisfy(\.intralineRanges.isEmpty))
        let changed = annotated.hunks.flatMap(\.lines).filter {
            $0.kind == .addition || $0.kind == .deletion
        }
        XCTAssertTrue(changed.contains(where: { !$0.intralineRanges.isEmpty }))
        XCTAssertEqual(defaultDocument.additions, annotated.additions)
        XCTAssertEqual(defaultDocument.deletions, annotated.deletions)
        XCTAssertEqual(defaultDocument.hunks.map(\.id), annotated.hunks.map(\.id))
    }

    func testLineCapDropsEmptiedHunksWhileReportingTheUncappedTotal() {
        let document = DiffLineProjector.project(
            patch: GitDiffPatchFixtures.modifiedMultiHunk,
            fileKey: "Sources/Alpha.swift",
            contextLevel: .fullFile,
            maxLines: 3
        )

        XCTAssertEqual(document.contextLevel, .fullFile)
        XCTAssertEqual(document.hunks.count, 1)
        XCTAssertEqual(document.hunks.first?.lines.count, 3)
        XCTAssertEqual(document.truncation, .init(projectedLines: 3, totalLines: 13))
        XCTAssertEqual(document.truncation?.omittedLines, 10)
        XCTAssertEqual(document.additions, 3)
        XCTAssertEqual(document.deletions, 2)
    }

    // MARK: - Helpers

    /// Line identity is asserted separately, so line-shape expectations stay readable.
    private struct ProjectedLine: Equatable {
        let kind: FileDiffProjection.LineKind
        let oldLine: Int?
        let newLine: Int?
        let text: String

        init(_ kind: FileDiffProjection.LineKind, _ oldLine: Int?, _ newLine: Int?, _ text: String) {
            self.kind = kind
            self.oldLine = oldLine
            self.newLine = newLine
            self.text = text
        }

        init(_ line: FileDiffProjection.Line) {
            kind = line.kind
            oldLine = line.oldLine
            newLine = line.newLine
            text = line.text
        }
    }
}
