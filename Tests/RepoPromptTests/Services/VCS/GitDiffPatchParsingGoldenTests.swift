@testable import RepoPromptApp
import XCTest

/// Golden coverage for the changed-line surface that ships inside MCP `git` tool replies and the
/// published `changed-lines.tsv` artifact.
///
/// These expectations are frozen on purpose. `GitDiffPatchParsing.extractChangedLines` and
/// `buildChangedLinesTsv` are a wire format: agents parse their output, so every quirk below —
/// including the header-prefix misreads — is contract until a deliberate format change replaces it.
final class GitDiffPatchParsingGoldenTests: XCTestCase {
    func testChangedLinesTsvLocksTheFrozenWireFormatForTheFullCorpus() {
        let tsv = GitDiffPatchParsing.buildChangedLinesTsv(from: GitDiffPatchFixtures.perFileCorpus)

        XCTAssertEqual(tsv, Self.tsv([
            ["path", "line_number", "change_type", "content"],
            ["Sources/Alpha.swift", "2", "-", "let alpha = 1"],
            ["Sources/Alpha.swift", "2", "+", "let alpha = 2"],
            ["Sources/Alpha.swift", "3", "+", "let beta = 3"],
            ["Sources/Alpha.swift", "11", "-", "let gamma = 4"],
            ["Sources/Alpha.swift", "12", "+", "let gamma = 5"],
            ["copied.txt", "2", "-", "line2"],
            ["copied.txt", "2", "+", "line2 changed"],
            ["crlf.txt", "2", "-", "crlf two\r"],
            ["crlf.txt", "2", "+", "crlf two changed\r"],
            ["gone.txt", "1", "-", "del1"],
            ["gone.txt", "2", "-", "del2"],
            ["gone.txt", "3", "-", "del3"],
            ["nonl.txt", "1", "-", "no trailing newline"],
            ["nonl.txt", "1", "+", "no trailing newline now longer"],
            ["sub", "1", "-", "Subproject commit ab5af1ad35585e546b738d9e6cebc6dd28be4fe9"],
            ["sub", "1", "+", "Subproject commit 0f8d818189f69923d7d9185b13cd0e64c4c48409"],
            ["tricky.txt", "1", "-", "++ plus line"],
            ["tricky.txt", "2", "-", "normal"],
            ["tricky.txt", "1", "+", "normal only"],
            ["untracked.txt", "1", "+", "brand new"],
            ["untracked.txt", "2", "+", "untracked file"],
            ["untracked.txt", "3", "+", "third"]
        ]))
    }

    func testAdditionsNumberFromTheNewSideAndDeletionsFromTheOldSideAcrossHunks() {
        let lines = GitDiffPatchParsing.extractChangedLines(from: [
            "Sources/Alpha.swift": GitDiffPatchFixtures.modifiedMultiHunk
        ])

        XCTAssertEqual(lines, [
            .init(path: "Sources/Alpha.swift", lineNumber: 2, changeType: "-", content: "let alpha = 1"),
            .init(path: "Sources/Alpha.swift", lineNumber: 2, changeType: "+", content: "let alpha = 2"),
            .init(path: "Sources/Alpha.swift", lineNumber: 3, changeType: "+", content: "let beta = 3"),
            .init(path: "Sources/Alpha.swift", lineNumber: 11, changeType: "-", content: "let gamma = 4"),
            .init(path: "Sources/Alpha.swift", lineNumber: 12, changeType: "+", content: "let gamma = 5")
        ])
    }

    func testZeroCountHunksNumberFromTheirPresentSideOnly() {
        let added = GitDiffPatchParsing.extractChangedLines(from: [
            "untracked.txt": GitDiffPatchFixtures.untrackedAddition
        ])
        let removed = GitDiffPatchParsing.extractChangedLines(from: [
            "gone.txt": GitDiffPatchFixtures.deletedFile
        ])

        XCTAssertEqual(added.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(added.map(\.changeType), ["+", "+", "+"])
        XCTAssertEqual(removed.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(removed.map(\.changeType), ["-", "-", "-"])
    }

    /// Frozen defect, not an aspiration: a deleted `-- sql comment` reaches the walker as
    /// `--- sql comment` and is discarded as a file header, which also holds the old-side counter
    /// back so the surviving records are numbered too low. Changing this changes a shipped wire
    /// format; the Changes panel avoids it through the walker's body-wins mode instead.
    func testBodyLinesThatLookLikeFileHeadersStayOmittedFromTheWireFormat() {
        let lines = GitDiffPatchParsing.extractChangedLines(from: [
            "tricky.txt": GitDiffPatchFixtures.headerLikeBodyLines
        ])

        XCTAssertEqual(lines, [
            .init(path: "tricky.txt", lineNumber: 1, changeType: "-", content: "++ plus line"),
            .init(path: "tricky.txt", lineNumber: 2, changeType: "-", content: "normal"),
            .init(path: "tricky.txt", lineNumber: 1, changeType: "+", content: "normal only")
        ])
    }

    func testMetadataOnlyPatchesAndNoNewlineMarkersContributeNoChangedLines() {
        let metadataOnly: [String: String] = [
            "blob.bin": GitDiffPatchFixtures.binaryDiffer,
            "empty-new.txt": GitDiffPatchFixtures.emptyNewFile,
            "moved.txt": GitDiffPatchFixtures.renamedWithoutContentChange,
            "script.sh": GitDiffPatchFixtures.modeOnlyChange
        ]

        XCTAssertEqual(GitDiffPatchParsing.extractChangedLines(from: metadataOnly), [])
        XCTAssertEqual(
            GitDiffPatchParsing.buildChangedLinesTsv(from: metadataOnly),
            "path\tline_number\tchange_type\tcontent"
        )
        XCTAssertEqual(
            GitDiffPatchParsing.extractChangedLines(from: ["nonl.txt": GitDiffPatchFixtures.noNewlineOnBothSides]),
            [
                .init(path: "nonl.txt", lineNumber: 1, changeType: "-", content: "no trailing newline"),
                .init(path: "nonl.txt", lineNumber: 1, changeType: "+", content: "no trailing newline now longer")
            ]
        )
    }

    func testTrailingPatchNewlineDoesNotChangeExtractedLines() {
        let withTrailingNewline = GitDiffPatchFixtures.perFileCorpus.mapValues { $0 + "\n" }

        XCTAssertEqual(
            GitDiffPatchParsing.buildChangedLinesTsv(from: withTrailingNewline),
            GitDiffPatchParsing.buildChangedLinesTsv(from: GitDiffPatchFixtures.perFileCorpus)
        )
    }

    /// A combined `@@@` header never matches the hunk-header pattern, so the counters keep running
    /// from zero instead of restarting at the hunk's declared start. Locked because the refactored
    /// walker must not "helpfully" reset counters on an unparsable header, and because it shows why
    /// the projector classifies combined diffs instead of walking them.
    func testUnparsableCombinedHunkHeadersLeaveCountersRunningFromZero() {
        let combined = GitDiffPatchParsing.extractChangedLines(from: [
            "c.txt": GitDiffPatchFixtures.conflictedCombined
        ])

        XCTAssertEqual(combined.map(\.lineNumber), [1, 3, 4, 5])
        XCTAssertEqual(combined.map(\.content), [
            "+<<<<<<< HEAD",
            "+=======",
            " feature change",
            "+>>>>>>> feature"
        ])
    }

    // MARK: - Helpers

    private static func tsv(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}
