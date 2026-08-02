import AppKit
import SwiftUI

// MARK: - File status

/// What happened to a file, as far as the row that describes it is concerned.
///
/// Derived from porcelain's XY pair rather than from the patch, because the panel renders rows long
/// before any patch is fetched — and for a section the patch would answer differently anyway: the
/// same file is an `M` in Staged and an `M` in Unstaged for two entirely different reasons.
enum AgentChangesFileStatusKind: Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted
    case unknown

    /// Git's own single-letter vocabulary. Letters rather than SF Symbols because a reviewer who
    /// knows `git status` already reads them, and a 10pt glyph has to survive three font presets.
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .conflicted: "!"
        case .unknown: "·"
        }
    }

    /// Semantic colors only, so the badge tracks light and dark without a second palette.
    var tint: Color {
        switch self {
        case .added, .untracked: .green
        case .modified, .typeChanged: .orange
        case .deleted: .red
        case .renamed, .copied: .blue
        case .conflicted: .pink
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .unknown: "Changed"
        }
    }
}

// MARK: - Row presentation

/// Everything a file row shows, resolved once so the view body stays declarative.
struct AgentChangesRowPresentation: Equatable {
    let status: AgentChangesFileStatusKind
    /// Leading directory component including its trailing slash, or `""` at the repository root.
    let directory: String
    /// Last path component.
    let name: String
    /// `"+12"`, or `nil` when the read produced no stats.
    let additionsText: String?
    /// `"−3"`, using a true minus sign so the digits stay optically aligned with `+`.
    let deletionsText: String?
    /// Rename or copy origin, for the row's tooltip.
    let originText: String?
    /// The row's whole story for VoiceOver, in one sentence.
    let accessibilityLabel: String
    /// Hover text: the porcelain XY pair plus the full path, which the middle-truncated row hides.
    let tooltip: String

    init(row: AgentChangesFileRow) {
        status = AgentChangesRowPresentation.statusKind(for: row)
        let split = AgentChangesRowPresentation.split(path: row.path)
        directory = split.directory
        name = split.name
        additionsText = row.additions.map { "+\($0)" }
        deletionsText = row.deletions.map { "\u{2212}\($0)" }
        originText = row.originalPath.map { "from \($0)" }

        var sentence = "\(status.label) \(row.path)"
        if let additions = row.additions, let deletions = row.deletions {
            sentence += ", \(additions) added, \(deletions) removed"
        }
        if let originalPath = row.originalPath {
            sentence += ", from \(originalPath)"
        }
        accessibilityLabel = sentence

        var hover = "\(row.displayStatus)  \(row.path)"
        if let originalPath = row.originalPath {
            hover += "\n\u{21B3} from \(originalPath)"
        }
        tooltip = hover
    }

    /// The status character that speaks for a row.
    ///
    /// Which side of the XY pair matters depends on the section: Staged shows what the index holds,
    /// Unstaged shows what the working tree holds, and a flat list has only one side to read.
    static func statusKind(for row: AgentChangesFileRow) -> AgentChangesFileStatusKind {
        if row.isConflicted { return .conflicted }
        if row.isUntracked { return .untracked }
        let primary: Character? = row.section == .staged ? row.indexStatus : row.workTreeStatus
        let secondary: Character? = row.section == .staged ? row.workTreeStatus : row.indexStatus
        return kind(for: primary) ?? kind(for: secondary) ?? .unknown
    }

    /// Splits a repository-relative path into a dimmable directory and its file name.
    static func split(path: String) -> (directory: String, name: String) {
        guard let separator = path.lastIndex(of: "/") else { return ("", path) }
        let boundary = path.index(after: separator)
        return (String(path[path.startIndex ..< boundary]), String(path[boundary...]))
    }

    private static func kind(for character: Character?) -> AgentChangesFileStatusKind? {
        switch character {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        case "?": .untracked
        default: nil
        }
    }
}

// MARK: - Section presentation

/// Header text and bulk-action affordance for one section.
struct AgentChangesSectionPresentation: Equatable {
    let title: String
    /// `"3 files · +40 −12"`. Stats are omitted when no read produced any.
    let subtitle: String
    /// `nil` when the section has no index action — Conflicts, vs-Base, and a working copy.
    let bulkActionTitle: String?
    let bulkActionAccessibilityLabel: String?

    init(section: AgentChangesSection, supportsStaging: Bool) {
        title = section.kind.title
        subtitle = AgentChangesSectionPresentation.subtitle(for: section)
        let offersBulkAction = supportsStaging && section.kind.isStageable && !section.isEmpty
        guard offersBulkAction else {
            bulkActionTitle = nil
            bulkActionAccessibilityLabel = nil
            return
        }
        let staging = section.kind == .unstaged
        bulkActionTitle = staging ? "Stage All" : "Unstage All"
        bulkActionAccessibilityLabel = staging
            ? "Stage all unstaged files"
            : "Unstage all staged files"
    }

    static func subtitle(for section: AgentChangesSection) -> String {
        let files = section.fileCount == 1 ? "1 file" : "\(section.fileCount) files"
        let additions = section.additions
        let deletions = section.deletions
        guard additions > 0 || deletions > 0 else { return files }
        return "\(files) · +\(additions) \u{2212}\(deletions)"
    }
}

// MARK: - Footer presentation

enum AgentChangesFooterPresentation {
    /// `"4 files · +120 −34"`, counting each file once even when it sits in two sections.
    static func totals(for snapshot: AgentChangesSnapshot) -> String {
        let count = snapshot.totalFileCount
        let files = count == 1 ? "1 file" : "\(count) files"
        guard snapshot.additions > 0 || snapshot.deletions > 0 else { return files }
        return "\(files) · +\(snapshot.additions) \u{2212}\(snapshot.deletions)"
    }

    /// Relative last-refresh text, coarse on purpose: a diff panel that ticks every second reads as
    /// an activity indicator rather than as a timestamp.
    static func lastRefreshed(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not refreshed yet" }
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<10: return "Updated just now"
        case ..<60: return "Updated \(Int(elapsed))s ago"
        case ..<3600: return "Updated \(Int(elapsed / 60))m ago"
        default: return "Updated \(Int(elapsed / 3600))h ago"
        }
    }
}

// MARK: - Empty states

/// The one thing the Changes panel says when it has no file list to show.
///
/// Resolved by a single pure function rather than by nested `if`s in the view body, because the
/// order of these cases *is* the policy: a checkout that cannot be resolved has to win over a clean
/// tree, or a session waiting on worktree hydration would claim the repository has no changes.
enum AgentChangesEmptyState: Equatable {
    /// No workspace root is loaded at all.
    case noWorkspaceRoot
    /// Every root resolved, none of them to a repository.
    case notARepository(rootName: String)
    /// Roots are blocked and the blocked banners above already explain why; no card is shown.
    case blockedRootsOnly
    /// vs-Base is selected and no base has been chosen. Never inferred — the panel asks.
    case baseNotChosen
    /// A clean working tree. `offersBaseComparison` is the decision-row-1 bridge: work an agent
    /// already committed is invisible here, and vs-Base is where it becomes visible.
    case cleanTree(offersBaseComparison: Bool)
    /// A repository whose first commit has not landed.
    case unbornHead
    case loading
    case failed(String)

    static func resolve(
        resolution: AgentPanelCheckoutResolution?,
        snapshot: AgentChangesSnapshot,
        compareSelection: AgentChangesCompareSelection,
        hasResolvedCompare: Bool
    ) -> AgentChangesEmptyState? {
        guard let resolution else { return .loading }

        if resolution.targets.isEmpty {
            if resolution.blocked.isEmpty { return .noWorkspaceRoot }
            let unresolvable = resolution.blocked.filter {
                switch $0.reason {
                case .notARepository, .rootMissing: true
                case .worktreePreparing, .worktreeMissing, .worktreeNotADirectory, .worktreeNotARepository: false
                }
            }
            guard unresolvable.count == resolution.blocked.count, let first = unresolvable.first else {
                return .blockedRootsOnly
            }
            return .notARepository(rootName: first.logicalRoot.displayName)
        }

        if compareSelection == .vsBase, !hasResolvedCompare { return .baseNotChosen }

        switch snapshot.loadState {
        case .initial:
            return .loading
        case let .failed(message):
            return .failed(message)
        case .ready:
            switch snapshot.emptyReason {
            case .none: return nil
            case .noCheckout: return .noWorkspaceRoot
            case .unbornHeadCleanTree: return .unbornHead
            case .cleanTree: return .cleanTree(offersBaseComparison: compareSelection == .workingTree)
            }
        }
    }
}

// MARK: - Blocked checkouts

/// Wording for a logical root the panel cannot read.
enum AgentChangesBlockedPresentation {
    static func title(for reason: AgentPanelCheckoutBlockReason) -> String {
        switch reason {
        case .worktreePreparing: "Agent worktree is preparing"
        case .worktreeMissing: "Agent worktree is missing"
        case .worktreeNotADirectory: "Agent worktree path is not a folder"
        case .worktreeNotARepository: "Agent worktree is not a repository"
        case .rootMissing: "Workspace folder is missing"
        case .notARepository: "Not a Git repository"
        }
    }

    static func message(for reason: AgentPanelCheckoutBlockReason) -> String {
        switch reason {
        case let .worktreePreparing(label, _):
            "Waiting for \(label) to finish hydrating. This view updates on its own."
        case let .worktreeMissing(label, path):
            "\(label) is bound to \(path), which is no longer on disk."
        case let .worktreeNotADirectory(label, path):
            "\(label) is bound to \(path), which is not a folder."
        case let .worktreeNotARepository(label, path):
            "\(label) is bound to \(path), which no version-control backend claims."
        case let .rootMissing(path):
            "\(path) is no longer on disk."
        case let .notARepository(path):
            "\(path) is not inside a Git or Jujutsu repository, so there are no changes to show."
        }
    }
}

// MARK: - Patch state

/// Wording, and the "Open file" escape hatch, for a patch the panel will not render inline.
enum AgentChangesPatchPresentation {
    static func message(for reason: AgentChangesPatchUnavailableReason) -> String {
        switch reason {
        case .noTextualDiff:
            "Git reported no textual diff for this file."
        case let .tooLarge(bytes):
            "This patch or source file is at least \(byteCount(bytes)) — too large to render inline."
        case let .tooManyLines(lines):
            "This file has \(lines) lines — too many to expand safely in the panel."
        case .unbornHead:
            "There is no commit to compare the index against yet."
        case let .failed(message):
            message
        }
    }

    /// Whether the reason is a size wall rather than an absence, which is the only case where
    /// opening the file in an editor is a better answer than a message.
    static func offersOpenFile(for reason: AgentChangesPatchUnavailableReason) -> Bool {
        switch reason {
        case .tooLarge, .tooManyLines: true
        case .noTextualDiff, .unbornHead, .failed: false
        }
    }

    /// One line describing a change that has no readable body.
    static func summary(for change: FileDiffProjection.FileChange) -> String? {
        switch change {
        case .binary: "Binary file — no text to show."
        case .submodule: "Submodule pointer change."
        case .modeOnly: "File mode changed; contents are unchanged."
        case let .renamed(from): "Renamed from \(from)."
        case let .copied(from): "Copied from \(from)."
        case .conflicted: "Conflicted merge — showing the combined diff."
        case .added, .modified, .deleted, .untracked: nil
        }
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Label for the per-hunk context control at the level the file is currently on.
    static func expandContextTitle(from level: AgentChangesContextLevel) -> String? {
        switch level.escalated {
        case .expanded: "Expand context"
        case .fullFile: "Expand to whole file"
        case .standard, .none: nil
        }
    }

    /// `"@@ -12,7 +12,9 @@"`, rebuilt from the projection rather than kept as raw text so the
    /// heading can be styled separately from the range.
    static func rangeText(for hunk: FileDiffProjection.Hunk) -> String {
        "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
    }

    /// Widest line number either gutter has to hold, so both columns are sized once per file.
    static func maximumLineNumberDigits(in document: FileDiffProjection.Document) -> Int {
        var widest = 2
        for hunk in document.hunks {
            widest = max(widest, digits(hunk.oldStart + hunk.oldCount))
            widest = max(widest, digits(hunk.newStart + hunk.newCount))
        }
        return widest
    }

    private static func digits(_ value: Int) -> Int {
        String(max(value, 1)).count
    }
}

// MARK: - Diff palette

/// The diff body's colors and metrics.
///
/// Colors are read straight off `UnifiedDiffCardRendering`'s line kinds instead of being restated
/// here: the transcript's diff cards and this panel render the same patches side by side in the
/// same window, and two independently maintained green-and-red palettes would drift apart.
enum AgentChangesDiffPalette {
    static func cardKind(for kind: FileDiffProjection.LineKind) -> UnifiedDiffDocument.Line.Kind {
        switch kind {
        case .addition: .addition
        case .deletion: .deletion
        case .context: .context
        // The `\ No newline at end of file` marker is an annotation about its neighbor, not a line
        // of the file, so it takes the same recessive treatment as a collapsed gap.
        case .noNewlineMarker: .gap
        }
    }

    static func textColor(for kind: FileDiffProjection.LineKind, colorScheme: ColorScheme) -> Color {
        Color(nsColor: cardKind(for: kind).nsTextColor(colorScheme: colorScheme))
    }

    static func backgroundColor(for kind: FileDiffProjection.LineKind, colorScheme: ColorScheme) -> Color? {
        cardKind(for: kind).nsBackgroundColor(colorScheme: colorScheme).map { Color(nsColor: $0) }
    }

    static func hunkHeaderBackground(colorScheme: ColorScheme) -> Color {
        Color(nsColor: UnifiedDiffDocument.Line.Kind.gap.nsBackgroundColor(colorScheme: colorScheme) ?? .clear)
    }

    /// A quieter second layer over the full-line tint, deliberately well below selection contrast.
    static func intralineBackgroundColor(
        for kind: FileDiffProjection.LineKind,
        colorScheme: ColorScheme
    ) -> Color? {
        let opacity = colorScheme == .dark ? 0.24 : 0.16
        return switch kind {
        case .addition: Color.green.opacity(opacity)
        case .deletion: Color.red.opacity(opacity)
        case .context, .noNewlineMarker: nil
        }
    }

    /// The marker character a line carries in the gutter's sign column.
    static func marker(for kind: FileDiffProjection.LineKind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "\u{2212}"
        case .context: " "
        case .noNewlineMarker: "\\"
        }
    }
}

/// Type metrics for the diff body.
///
/// Gutter width is measured from the monospaced font actually in use rather than guessed as a
/// per-digit constant, so the two number columns stay aligned at every font preset instead of
/// drifting apart as the preset scales.
enum AgentChangesDiffMetrics {
    static let lineFontSizeAtNormal: CGFloat = 10.5

    static func gutterWidth(digits: Int, preset: FontScalePreset) -> CGFloat {
        let font = NSFont.monospacedSystemFont(
            ofSize: preset.scaledMetric(lineFontSizeAtNormal),
            weight: .regular
        )
        return ceil(font.maximumAdvancement.width * CGFloat(max(digits, 1)))
    }

    static func markerWidth(preset: FontScalePreset) -> CGFloat {
        gutterWidth(digits: 1, preset: preset)
    }
}
