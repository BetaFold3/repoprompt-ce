import Foundation

/// Unified-diff corpus transcribed byte-for-byte from real `git diff` output.
///
/// The same fixtures back the frozen MCP wire format (`GitDiffPatchParsingGoldenTests`) and the
/// Changes-panel projection (`DiffLineProjectorTests`), so a walker change that silently alters one
/// surface cannot keep looking correct in the other.
enum GitDiffPatchFixtures {
    // MARK: - Content changes

    /// Two hunks. The second carries a trailing `@@` heading, and the first contains a blank context
    /// line (a bare space) that still has to advance both counters.
    static let modifiedMultiHunk = #"""
    diff --git a/Sources/Alpha.swift b/Sources/Alpha.swift
    index 4eaa153..4bcf366 100644
    --- a/Sources/Alpha.swift
    +++ b/Sources/Alpha.swift
    @@ -1,5 +1,6 @@
     import Foundation
    -let alpha = 1
    +let alpha = 2
    +let beta = 3
     
     func run() {}
     let a=1
    @@ -8,5 +9,5 @@ let c=3
     let d=4
     let e=5
     // tail
    -let gamma = 4
    +let gamma = 5
     let z=9
    """#

    /// Copy detection: `copy from`/`copy to` plus a real content edit on the copy.
    static let copiedWithEdit = #"""
    diff --git a/tocopy.txt b/copied.txt
    similarity index 68%
    copy from tocopy.txt
    copy to copied.txt
    index 47a544d..41277cd 100644
    --- a/tocopy.txt
    +++ b/copied.txt
    @@ -1,5 +1,5 @@
     copy source
    -line2
    +line2 changed
     line3
     line4
     line5
    """#

    /// CRLF content: the carriage return belongs to the line body and must survive projection.
    static let crlfModified = #"""
    diff --git a/crlf.txt b/crlf.txt
    index 31bbe38..5cea4b4 100644
    --- a/crlf.txt
    +++ b/crlf.txt
    @@ -1,3 +1,3 @@
     crlf one\#r
    -crlf two\#r
    +crlf two changed\#r
     crlf three\#r
    """#

    /// Both sides lack a trailing newline, so two `\ No newline at end of file` markers appear.
    /// The hunk header also omits both counts, which default to 1.
    static let noNewlineOnBothSides = #"""
    diff --git a/nonl.txt b/nonl.txt
    index 69db55d..0f69b08 100644
    --- a/nonl.txt
    +++ b/nonl.txt
    @@ -1 +1 @@
    -no trailing newline
    \ No newline at end of file
    +no trailing newline now longer
    \ No newline at end of file
    """#

    /// Deleted body lines that are indistinguishable from file headers by prefix alone: deleting
    /// `-- sql comment` yields `--- sql comment`, and deleting `--- three dashes` yields four dashes.
    static let headerLikeBodyLines = #"""
    diff --git a/tricky.txt b/tricky.txt
    index f6a6c79..e4a8019 100644
    --- a/tricky.txt
    +++ b/tricky.txt
    @@ -1,4 +1 @@
    --- sql comment
    -++ plus line
    ---- three dashes
    -normal
    +normal only
    """#

    // MARK: - Lifecycle changes

    /// Untracked file, shaped exactly like a tracked addition once `GitService` normalizes the
    /// `--no-index` path prefixes. Zero-count old side.
    static let untrackedAddition = #"""
    diff --git a/untracked.txt b/untracked.txt
    new file mode 100644
    index 0000000..e43b1cb
    --- /dev/null
    +++ b/untracked.txt
    @@ -0,0 +1,3 @@
    +brand new
    +untracked file
    +third
    """#

    /// Deletion with a zero-count new side.
    static let deletedFile = #"""
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 7aa5b55..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -del1
    -del2
    -del3
    """#

    /// A new empty file: header metadata only, no hunks at all.
    static let emptyNewFile = #"""
    diff --git a/empty-new.txt b/empty-new.txt
    new file mode 100644
    index 0000000..e69de29
    """#

    /// Pure rename at 100% similarity: no hunks, origin only in the metadata.
    static let renamedWithoutContentChange = #"""
    diff --git a/tomove.txt b/moved.txt
    similarity index 100%
    rename from tomove.txt
    rename to moved.txt
    """#

    /// Rename of a path Git C-quotes: the origin arrives as octal UTF-8 byte escapes.
    static let renamedWithQuotedPaths = #"""
    diff --git "a/caf\303\251 note.txt" "b/r\303\251sum\303\251 final.txt"
    similarity index 100%
    rename from "caf\303\251 note.txt"
    rename to "r\303\251sum\303\251 final.txt"
    """#

    /// Executable bit flipped and nothing else: bare `old mode`/`new mode`, no hunks.
    static let modeOnlyChange = #"""
    diff --git a/script.sh b/script.sh
    old mode 100644
    new mode 100755
    """#

    /// Binary content: Git refuses to emit a body.
    static let binaryDiffer = #"""
    diff --git a/blob.bin b/blob.bin
    index c94be36..11cff70 100644
    Binary files a/blob.bin and b/blob.bin differ
    """#

    /// Submodule pointer bump: an ordinary hunk whose body lines are `Subproject commit` records.
    static let submoduleBump = #"""
    diff --git a/sub b/sub
    index ab5af1a..0f8d818 160000
    --- a/sub
    +++ b/sub
    @@ -1 +1 @@
    -Subproject commit ab5af1ad35585e546b738d9e6cebc6dd28be4fe9
    +Subproject commit 0f8d818189f69923d7d9185b13cd0e64c4c48409
    """#

    /// Unmerged path during a conflicted merge. Git emits a combined diff: `diff --cc`, `@@@`
    /// headers, and two prefix columns per body line.
    ///
    /// Deliberately absent from ``perFileCorpus``: `GitService.splitUnifiedDiffByFile` only splits on
    /// `diff --git`, so a combined block never reaches the per-file map that MCP replies are built
    /// from. The projector still has to recognize it rather than mis-parse it.
    static let conflictedCombined = #"""
    diff --cc c.txt
    index 1e427e4,24100cc..0000000
    --- a/c.txt
    +++ b/c.txt
    @@@ -1,3 -1,3 +1,7 @@@
      line1
    ++<<<<<<< HEAD
     +main change
    ++=======
    + feature change
    ++>>>>>>> feature
      line3
    """#

    // MARK: - Corpus

    /// The corpus in the shape `GitDiffEngine.buildSnapshotInputs` produces: canonical Git path to
    /// that file's patch.
    static let perFileCorpus: [String: String] = [
        "Sources/Alpha.swift": modifiedMultiHunk,
        "blob.bin": binaryDiffer,
        "copied.txt": copiedWithEdit,
        "crlf.txt": crlfModified,
        "empty-new.txt": emptyNewFile,
        "gone.txt": deletedFile,
        "moved.txt": renamedWithoutContentChange,
        "nonl.txt": noNewlineOnBothSides,
        "script.sh": modeOnlyChange,
        "sub": submoduleBump,
        "tricky.txt": headerLikeBodyLines,
        "untracked.txt": untrackedAddition
    ]
}
