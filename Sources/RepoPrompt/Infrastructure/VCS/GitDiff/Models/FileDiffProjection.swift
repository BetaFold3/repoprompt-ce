import Foundation

/// Value models describing one file's diff after ``DiffLineProjector`` has walked its patch.
///
/// The family is namespaced rather than flat because `Diffing/DiffChunk.swift` already owns a
/// module-level `DiffLine` for a different job (apply-edits chunk matching); nesting keeps the two
/// vocabularies from colliding as this one grows.
enum FileDiffProjection {
    /// Classification of a single line inside a unified-diff hunk body.
    enum LineKind: Equatable {
        case context
        case addition
        case deletion
        /// Git's `\ No newline at end of file` annotation. Kept as a line rather than dropped so the
        /// renderer can show it against the neighbor it describes, which is the only place that
        /// distinction is visible to a reviewer.
        case noNewlineMarker
    }

    /// One projected line of a file diff.
    struct Line: Equatable, Identifiable {
        /// `"<hunkID>#<positionInHunk>"`. Purely positional, so re-projecting an unchanged patch
        /// mints the same identity and SwiftUI keeps row state across the refreshes that fire while
        /// agents edit.
        let id: String
        let kind: LineKind
        /// Old-side number, or `nil` for additions and markers.
        let oldLine: Int?
        /// New-side number, or `nil` for deletions and markers.
        let newLine: Int?
        /// Body text with the leading marker character removed; every other byte, including CR and
        /// indentation, is preserved verbatim.
        let text: String
        /// Phase-2 intraline word-diff emphasis. Offsets index `text` by UTF-16 code unit so
        /// they bridge to `NSRange` without re-measuring.
        let intralineRanges: [Range<Int>]

        init(
            id: String,
            kind: LineKind,
            oldLine: Int?,
            newLine: Int?,
            text: String,
            intralineRanges: [Range<Int>] = []
        ) {
            self.id = id
            self.kind = kind
            self.oldLine = oldLine
            self.newLine = newLine
            self.text = text
            self.intralineRanges = intralineRanges
        }
    }

    /// One hunk of a projected file diff.
    struct Hunk: Equatable, Identifiable {
        /// `"<fileKey>#<hunkIndex>"`. Positional for the same reason as ``Line/id``: a wider context
        /// level or a re-fetch of the same patch must not look like a different hunk.
        let id: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        /// The enclosing-context text Git appends after the closing `@@`, or `nil` when absent.
        let heading: String?
        let lines: [Line]
    }

    /// How a file changed, as far as its patch — plus the untracked bit only `git status` knows —
    /// can tell.
    enum FileChange: Equatable {
        case added
        case modified
        case deleted
        case untracked
        case binary
        case submodule
        case modeOnly
        case renamed(from: String)
        case copied(from: String)
        case conflicted
    }

    /// The context width the patch behind a projection was generated at.
    ///
    /// Recorded because it cannot be recovered from patch text, and context escalation re-projects
    /// the same file at a wider width; the renderer needs to know which rung it is on.
    enum ContextLevel: Equatable {
        case lines(Int)
        case fullFile
    }

    /// Records that a projection stopped emitting lines before the patch ran out.
    struct Truncation: Equatable {
        let projectedLines: Int
        let totalLines: Int

        var omittedLines: Int {
            totalLines - projectedLines
        }
    }

    /// A single file's diff, projected into the value model the Changes panel renders.
    struct Document: Equatable, Identifiable {
        /// The `perFile` key this projection was built from; it anchors every hunk and line ID.
        let id: String
        /// Display path. Today this equals ``id``: `GitService.splitUnifiedDiffByFile` already
        /// resolves prefix stripping, quoting, and rename/copy preference when it keys the map, and
        /// re-deriving it here would create a second answer to "which file is this?".
        let path: String
        /// The pre-change path when it differs from ``path`` — renames and copies — otherwise `nil`.
        let oldPath: String?
        let change: FileChange
        /// Counted across the whole patch, including lines dropped by ``truncation``.
        let additions: Int
        let deletions: Int
        let hunks: [Hunk]
        let contextLevel: ContextLevel
        /// Immutable old-side Git object used by this patch, when the compare was ref-backed.
        ///
        /// Context expansion reads this exact object instead of resolving a branch again after the
        /// patch was projected. Nil for worktree/index-only compares and ordinary callers.
        let oldSourceReference: String?
        /// `nil` when every body line was projected.
        let truncation: Truncation?

        init(
            id: String,
            path: String,
            oldPath: String?,
            change: FileChange,
            additions: Int,
            deletions: Int,
            hunks: [Hunk],
            contextLevel: ContextLevel,
            oldSourceReference: String? = nil,
            truncation: Truncation?
        ) {
            self.id = id
            self.path = path
            self.oldPath = oldPath
            self.change = change
            self.additions = additions
            self.deletions = deletions
            self.hunks = hunks
            self.contextLevel = contextLevel
            self.oldSourceReference = oldSourceReference
            self.truncation = truncation
        }
    }
}
