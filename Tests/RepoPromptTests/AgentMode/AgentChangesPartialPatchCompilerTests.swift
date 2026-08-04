@testable import RepoPromptApp
import XCTest

final class AgentChangesPartialPatchCompilerTests: XCTestCase {
    func testWholeHunkCompilationPreservesRawHunksAndOmitsIndexMetadata() throws {
        let patch = """
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@ first
        -old
        +new
        @@ -10 +10 @@ second
        -before
        +after
        """ + "\n"
        let parsed = try parse(patch)
        let selection = Set(parsed.hunks.flatMap(\.changedLineKeys))

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: selection,
            selectsWholeHunks: true
        )

        XCTAssertFalse(compiled.reverse)
        XCTAssertFalse(text(compiled.data).contains("index 1111111"))
        XCTAssertTrue(text(compiled.data).hasPrefix(
            "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n"
        ))
        let allHunks = parsed.hunks.map(\.rawData).reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(Data(compiled.data.suffix(allHunks.count)), allHunks)
        XCTAssertTrue(text(compiled.data).contains("@@ -1 +1 @@ first\n-old\n+new\n"))
        XCTAssertTrue(text(compiled.data).contains("@@ -10 +10 @@ second\n-before\n+after\n"))
    }

    func testForwardLineCompilationNeutralizesAndOmitsOnlyUnselectedChanges() throws {
        let parsed = try parse(replacementPatch)
        let selection: Set<AgentChangesDiffLineKey> = [
            .deletion(oldLine: 2),
            .addition(newLine: 2)
        ]

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: selection,
            selectsWholeHunks: false
        )
        let output = text(compiled.data)

        XCTAssertFalse(compiled.reverse)
        XCTAssertTrue(output.contains("@@ -1,4 +1,4 @@ block\n"))
        XCTAssertTrue(output.contains("-oldA\n+newA\n"))
        XCTAssertTrue(output.contains(" oldB\n"))
        XCTAssertFalse(output.contains("+newB"))
        XCTAssertNoThrow(try AgentChangesPartialPatchCompiler.parse(compiled.data, expectedPath: "file.txt"))
    }

    func testUnstageLineCompilationInvertsSelectionAndKeepsUnselectedIndexLinesAsContext() throws {
        let parsed = try parse(replacementPatch)
        let selection: Set<AgentChangesDiffLineKey> = [
            .deletion(oldLine: 2),
            .addition(newLine: 2)
        ]

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .unstage,
            selectedLineKeys: selection,
            selectsWholeHunks: false
        )
        let output = text(compiled.data)

        XCTAssertFalse(compiled.reverse)
        XCTAssertTrue(output.hasPrefix(
            "diff --git a/file.txt b/file.txt\n--- b/file.txt\n+++ a/file.txt\n"
        ))
        XCTAssertTrue(output.contains("+oldA\n-newA\n"))
        XCTAssertFalse(output.contains("oldB"))
        XCTAssertTrue(output.contains(" newB\n"))
        XCTAssertNoThrow(try AgentChangesPartialPatchCompiler.parse(compiled.data, expectedPath: "file.txt"))
    }

    func testWholeHunkUnstageUsesReverseWithoutEditingHunkBytes() throws {
        let parsed = try parse(replacementPatch)
        let selected = parsed.hunks[0].changedLineKeys
        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .unstage,
            selectedLineKeys: selected,
            selectsWholeHunks: true
        )

        XCTAssertTrue(compiled.reverse)
        XCTAssertEqual(
            Data(compiled.data.suffix(parsed.hunks[0].rawData.count)),
            parsed.hunks[0].rawData
        )
    }

    func testZeroCountAndOmittedCountHeadersRecomputeValidRanges() throws {
        let additions = try parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -0,0 +1,2 @@
        +first
        +second
        """ + "\n")
        let compiledAddition = try AgentChangesPartialPatchCompiler.compile(
            additions,
            action: .stage,
            selectedLineKeys: [.addition(newLine: 2)],
            selectsWholeHunks: false
        )
        XCTAssertTrue(text(compiledAddition.data).contains("@@ -0,0 +1,1 @@\n+second\n"))

        let deletion = try parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +0,0 @@
        -only
        """ + "\n")
        let compiledDeletion = try AgentChangesPartialPatchCompiler.compile(
            deletion,
            action: .stage,
            selectedLineKeys: [.deletion(oldLine: 1)],
            selectsWholeHunks: false
        )
        XCTAssertTrue(text(compiledDeletion.data).contains("@@ -1,1 +0,0 @@\n-only\n"))
    }

    func testCRLFPayloadAndHeaderEndingsArePreserved() throws {
        let bytes = Data(
            "diff --git a/file.txt b/file.txt\r\n--- a/file.txt\r\n+++ b/file.txt\r\n@@ -1 +1 @@ heading\r\n-old\r\n+new\r\n".utf8
        )
        let parsed = try AgentChangesPartialPatchCompiler.parse(bytes, expectedPath: "file.txt")
        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.changedLineKeys,
            selectsWholeHunks: true
        )

        XCTAssertEqual(
            Data(compiled.data.suffix(parsed.hunks[0].rawData.count)),
            parsed.hunks[0].rawData
        )
        XCTAssertTrue(compiled.data.contains(Data("-old\r\n+new\r\n".utf8)))
    }

    func testAnyAnnotatedHunkRefusesEveryLineSelectionInBothDirections() throws {
        // Git reads `\ No newline at end of file` positionally: it describes the line above it and is
        // only legal as the last line of a side. A line selection can move it into the middle of the
        // emitted body, where `git apply` accepts it and glues the annotated line to the next one, or
        // drop it entirely and assert a trailing newline the file never had. Neither shape is
        // reconstructible from the records, so an annotated hunk refuses every line selection
        // regardless of where the annotation would land — the descriptor already withholds these
        // lines, and this is the compiler's independent second layer.
        let fixtures: [(name: String, patch: String, selections: [(String, Set<AgentChangesDiffLineKey>)])] = [
            (
                "both sides annotated",
                Self.bothSidesNoNewlinePatch,
                [
                    ("addition only", [.addition(newLine: 2)]),
                    ("deletion only", [.deletion(oldLine: 2)])
                ]
            ),
            (
                "old side annotated",
                Self.oldSideNoNewlinePatch,
                [
                    ("addition only", [.addition(newLine: 2)]),
                    ("deletion only", [.deletion(oldLine: 2)])
                ]
            ),
            (
                "new side annotated",
                Self.newSideNoNewlinePatch,
                [
                    ("addition only", [.addition(newLine: 2)]),
                    ("deletion only", [.deletion(oldLine: 2)])
                ]
            ),
            (
                "new side annotated with a later change",
                Self.newSideNoNewlineFollowedByChangePatch,
                [
                    ("annotated addition only", [.addition(newLine: 1)]),
                    ("annotated deletion only", [.deletion(oldLine: 1)]),
                    ("trailing addition only", [.addition(newLine: 2)]),
                    ("trailing deletion only", [.deletion(oldLine: 2)]),
                    ("annotated replacement", [.deletion(oldLine: 1), .addition(newLine: 1)])
                ]
            )
        ]

        for fixture in fixtures {
            let parsed = try parse(fixture.patch)
            for action in [AgentChangesPartialAction.stage, .unstage] {
                for selection in fixture.selections {
                    let name = "\(fixture.name), \(selection.0), \(action)"
                    XCTAssertThrowsError(
                        try AgentChangesPartialPatchCompiler.compile(
                            parsed,
                            action: action,
                            selectedLineKeys: selection.1,
                            selectsWholeHunks: false
                        ),
                        name
                    ) { error in
                        switch error as? AgentChangesPartialPatchCompiler.CompilerError {
                        case .unsupportedStructure:
                            break
                        default:
                            XCTFail("Expected unsupportedStructure for \(name), got \(error)")
                        }
                    }
                }
            }
        }

        // Whole-hunk actions replay the reviewed bytes on the same fixtures, annotations included.
        for fixture in fixtures {
            let parsed = try parse(fixture.patch)
            for action in [AgentChangesPartialAction.stage, .unstage] {
                let wholeHunk = try AgentChangesPartialPatchCompiler.compile(
                    parsed,
                    action: action,
                    selectedLineKeys: parsed.changedLineKeys,
                    selectsWholeHunks: true
                )
                XCTAssertEqual(
                    Data(wholeHunk.data.suffix(parsed.hunks[0].rawData.count)),
                    parsed.hunks[0].rawData,
                    "\(fixture.name) whole-hunk \(action) must replay Git's own bytes"
                )
                XCTAssertEqual(wholeHunk.reverse, action == .unstage)
            }
        }
    }

    func testQuotedUnicodeSpaceAndLeadingDashPathsDecodeConsistently() throws {
        let unicode = """
        diff --git "a/caf\\303\\251 file.txt" "b/caf\\303\\251 file.txt"
        --- "a/caf\\303\\251 file.txt"
        +++ "b/caf\\303\\251 file.txt"
        @@ -1 +1 @@
        -old
        +new
        """ + "\n"
        XCTAssertNoThrow(try AgentChangesPartialPatchCompiler.parse(
            Data(unicode.utf8),
            expectedPath: "café file.txt"
        ))

        let leadingDash = """
        diff --git a/-flag b/-flag
        --- a/-flag
        +++ b/-flag
        @@ -1 +1 @@
        -old
        +new
        """ + "\n"
        XCTAssertNoThrow(try AgentChangesPartialPatchCompiler.parse(
            Data(leadingDash.utf8),
            expectedPath: "-flag"
        ))
    }

    func testStructuralPatchFamiliesAreRejected() {
        let metadata = [
            "old mode 100644\nnew mode 100755",
            "similarity index 100%\nrename from file.txt\nrename to renamed.txt",
            "similarity index 100%\ncopy from file.txt\ncopy to copied.txt",
            "Binary files a/file.txt and b/file.txt differ",
            "GIT binary patch",
            "new file mode 100644",
            "deleted file mode 100644"
        ]

        for item in metadata {
            let patch = "diff --git a/file.txt b/file.txt\n\(item)\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n"
            XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
                Data(patch.utf8),
                expectedPath: "file.txt"
            ), item)
        }

        let submodule = "diff --git a/file.txt b/file.txt\nindex 111..222 160000\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-Subproject commit 111\n+Subproject commit 222\n"
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(submodule.utf8),
            expectedPath: "file.txt"
        ))
    }

    func testMalformedCombinedPathMismatchedAndMultiFilePatchesFailClosed() {
        let malformedCount = "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1 @@\n-old\n+new\n"
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(malformedCount.utf8),
            expectedPath: "file.txt"
        ))
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(replacementPatch.utf8),
            expectedPath: "other.txt"
        ))

        let combined = "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@@ -1 -1 +1 @@@\n-old\n+new\n"
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(combined.utf8),
            expectedPath: "file.txt"
        ))

        let multi = replacementPatch + replacementPatch
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(multi.utf8),
            expectedPath: "file.txt"
        ))
    }

    func testSelectionAndMaximumInputBoundsFailClosed() throws {
        let parsed = try parse(replacementPatch)
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [],
            selectsWholeHunks: false
        ))
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [.addition(newLine: 999)],
            selectsWholeHunks: false
        ))
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [.addition(newLine: 2)],
            selectsWholeHunks: true
        ))

        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(repeating: 0x20, count: 65),
            expectedPath: "file.txt",
            byteLimit: 64
        ))
    }

    /// Index and worktree both end without a trailing newline, so git annotates both sides.
    private static let bothSidesNoNewlinePatch = """
    diff --git a/file.txt b/file.txt
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     context
    -old last
    \\ No newline at end of file
    +new last
    \\ No newline at end of file
    """ + "\n"

    /// Only the old side lacks a trailing newline: the edit added one.
    private static let oldSideNoNewlinePatch = """
    diff --git a/file.txt b/file.txt
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     context
    -last
    \\ No newline at end of file
    +last
    """ + "\n"

    /// Only the new side lacks a trailing newline: the edit removed one.
    private static let newSideNoNewlinePatch = """
    diff --git a/file.txt b/file.txt
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     context
    -last
    +last
    \\ No newline at end of file
    """ + "\n"

    /// Synthetic: an annotated new-side line followed by a further change, which proves the guard
    /// is side-agnostic rather than merely rejecting annotated deletions.
    private static let newSideNoNewlineFollowedByChangePatch = """
    diff --git a/file.txt b/file.txt
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
    -old1
    +new1
    \\ No newline at end of file
    -old2
    +new2
    """ + "\n"

    private var replacementPatch: String {
        """
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,4 +1,4 @@ block
         context
        -oldA
        +newA
         keep
        -oldB
        +newB
        """ + "\n"
    }

    private func parse(_ patch: String) throws -> AgentChangesPartialPatchCompiler.ParsedPatch {
        try AgentChangesPartialPatchCompiler.parse(Data(patch.utf8), expectedPath: "file.txt")
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool {
        range(of: other) != nil
    }
}
