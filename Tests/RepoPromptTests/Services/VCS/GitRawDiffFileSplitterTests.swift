@testable import RepoPromptApp
import XCTest

final class GitRawDiffFileSplitterTests: XCTestCase {
    func testMultipleFilesPreserveEveryByteInSourceOrder() {
        let first = "diff --git a/a.txt b/a.txt\r\n--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n"
        let second = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-before\n+after"
        let data = Data(("warning preamble\n" + first + second).utf8)

        XCTAssertEqual(GitRawDiffFileSplitter.split(data), [
            Data(first.utf8),
            Data(second.utf8)
        ])
    }

    func testBodyLineContainingDiffGitDoesNotSplit() {
        let patch = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +diff --git is body text
        """ + "\n"

        XCTAssertEqual(GitRawDiffFileSplitter.split(Data(patch.utf8)), [Data(patch.utf8)])
    }

    func testCRLFAndNoTrailingNewlineRemainUnchanged() {
        let patch = Data(
            "diff --git a/file.txt b/file.txt\r\n--- a/file.txt\r\n+++ b/file.txt\r\n@@ -1 +1 @@\r\n-old\r\n+new".utf8
        )

        XCTAssertEqual(GitRawDiffFileSplitter.split(patch), [patch])
    }

    func testQuotedNamesAndRenameBlocksAssociateWithRenderedKeys() {
        let patch = """
        diff --git "a/old name.txt" "b/new name.txt"
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        --- "a/old name.txt"
        +++ "b/new name.txt"
        @@ -1 +1 @@
        -old
        +new
        """ + "\n"
        let rendered = GitService.splitUnifiedDiffByFile(patch)

        let raw = GitRawDiffFileSplitter.split(Data(patch.utf8), matching: rendered)

        XCTAssertEqual(raw?["new name.txt"], Data(patch.utf8))
    }

    func testAssociationMismatchFailsClosed() {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n"

        XCTAssertNil(GitRawDiffFileSplitter.split(
            Data(patch.utf8),
            matching: ["a": patch.replacingOccurrences(of: "+new", with: "+changed")]
        ))
        XCTAssertNil(GitRawDiffFileSplitter.split(
            Data(patch.utf8),
            matching: ["a": patch, "extra": patch]
        ))
    }

    func testRenderedSplitterPreservesEachRawBlockWhenFinalFileHasNoNewline() {
        let first = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n"
        let second = "diff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -1 +1 @@\n-before\n+after"
        let combined = first + second
        let rendered = GitService.splitUnifiedDiffByFile(combined)
        let raw = GitRawDiffFileSplitter.split(Data(combined.utf8), matching: rendered)

        XCTAssertEqual(rendered["a"], first)
        XCTAssertEqual(rendered["b"], second)
        XCTAssertEqual(raw?["a"], Data(first.utf8))
        XCTAssertEqual(raw?["b"], Data(second.utf8))
    }
}
