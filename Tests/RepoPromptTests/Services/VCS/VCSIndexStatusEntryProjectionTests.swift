@testable import RepoPromptApp
import XCTest

final class VCSIndexStatusEntryProjectionTests: XCTestCase {
    func testProjectsStagedModifiedUntrackedRenamedConflictedAndPartiallyStagedRecords() throws {
        let entries = try project([
            "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb Staged.txt",
            "1 .M N... 100644 100644 100644 ccccccc ddddddd Modified.txt",
            "1 MM N... 100644 100644 100644 eeeeeee fffffff Partially Staged.txt",
            "2 R. N... 100644 100644 100644 1111111 2222222 R100 New Name.txt",
            "Old Name.txt",
            "u UU N... 100644 100644 100644 100644 3333333 4444444 5555555 Conflict.txt",
            "? Untracked File.txt"
        ])

        XCTAssertEqual(
            entries.map(\.path),
            [
                "Staged.txt",
                "Modified.txt",
                "Partially Staged.txt",
                "New Name.txt",
                "Conflict.txt",
                "Untracked File.txt"
            ]
        )
        XCTAssertEqual(entries.map(\.indexStatus), ["M", ".", "M", "R", "U", nil])
        XCTAssertEqual(entries.map(\.workTreeStatus), [".", "M", "M", ".", "U", nil])
        XCTAssertEqual(entries.map(\.originalPath), [nil, nil, nil, "Old Name.txt", nil, nil])
        XCTAssertEqual(entries.map(\.isUntracked), [false, false, false, false, false, true])
        XCTAssertEqual(entries.map(\.isConflicted), [false, false, false, false, true, false])
        XCTAssertEqual(entries.map(\.hasStagedChange), [true, false, true, true, true, false])
        XCTAssertEqual(entries.map(\.hasWorkTreeChange), [false, true, true, false, true, true])
    }

    func testDropsIgnoredRecordsAndPreservesGitRecordOrder() throws {
        let entries = try project([
            "! Ignored.log",
            "? Untracked.txt",
            "! build/Ignored.o",
            "1 A. N... 000000 100644 100644 0000000 aaaaaaa Added.txt"
        ])

        XCTAssertEqual(entries.map(\.path), ["Untracked.txt", "Added.txt"])
    }

    func testRenameEntryIdentityCarriesBothPathsWhileOrdinaryEntryCarriesOne() throws {
        let entries = try project([
            "2 R. N... 100644 100644 100644 1111111 2222222 R100 New Name.txt",
            "Old Name.txt",
            "1 .M N... 100644 100644 100644 ccccccc ddddddd Modified.txt"
        ])

        XCTAssertEqual(entries[0].identity.allPaths, ["New Name.txt", "Old Name.txt"])
        XCTAssertEqual(entries[1].identity.allPaths, ["Modified.txt"])
        XCTAssertEqual(
            VCSIndexPathIdentity(path: "Same.txt", originalPath: "Same.txt").allPaths,
            ["Same.txt"]
        )
    }

    private func project(_ records: [String]) throws -> [VCSIndexStatusEntry] {
        let output = records.joined(separator: "\0") + "\0"
        let snapshot = try GitStatusPorcelainV2Parser.parse(output)
        return VCSIndexStatusEntry.project(snapshot.pathRecords)
    }
}
