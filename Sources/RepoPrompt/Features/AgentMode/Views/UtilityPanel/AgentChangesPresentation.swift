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
        totals(
            fileCount: snapshot.totalFileCount,
            additions: snapshot.additions,
            deletions: snapshot.deletions
        )
    }

    /// Aggregate footer copy for independently refreshing repository groups.
    static func totals(fileCount: Int, additions: Int, deletions: Int) -> String {
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        guard additions > 0 || deletions > 0 else { return files }
        return "\(files) · +\(additions) \u{2212}\(deletions)"
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

// MARK: - Group and search presentation

/// Stable copy for one repository header, kept pure so collapsed roots and worktrees cannot drift
/// between the visual label, tooltip, and accessibility value.
struct AgentChangesGroupHeaderPresentation: Equatable {
    let title: String
    let checkoutIdentity: String
    let checkoutTooltip: String

    init(target: AgentPanelResolvedCheckout) {
        title = target.displayName
        if let worktree = target.worktree, !target.substitutesUnavailableWorktree {
            checkoutIdentity = worktree.branch ?? worktree.label
            checkoutTooltip = "Agent worktree at \(worktree.worktreeRootPath)"
        } else {
            checkoutIdentity = target.checkoutURL.lastPathComponent
            checkoutTooltip = "Workspace checkout at \(target.checkoutURL.path)"
        }
    }
}

/// Compact result and budget copy for the fixed search bar.
struct AgentChangesSearchBarPresentation: Equatable {
    let resultText: String
    let limitText: String?

    init(state: AgentChangesSearchState) {
        let total = state.matches.count
        if let selected = state.selectedMatchIndex, total > 0 {
            resultText = "\(selected + 1) of \(total)"
        } else if state.phase == .ready {
            resultText = "No matches"
        } else if state.phase == .loading || state.phase == .debouncing {
            resultText = "Searching\u{2026}"
        } else {
            resultText = ""
        }

        var limits: [String] = []
        if state.skippedFileCount > 0 {
            let noun = state.skippedFileCount == 1 ? "file" : "files"
            limits.append("\(state.skippedFileCount) \(noun) skipped")
        }
        if state.isTruncated {
            limits.append("results limited")
        }
        limitText = limits.isEmpty ? nil : limits.joined(separator: " · ")
    }
}

/// Copy for the one patch-level partial-staging notice and the quiet hunk/line actions.
enum AgentChangesPartialStagingPresentation {
    static func actionTitle(_ action: AgentChangesPartialAction, noun: String) -> String {
        switch action {
        case .stage: "Stage \(noun)"
        case .unstage: "Unstage \(noun)"
        }
    }

    static func selectedLinesTitle(_ action: AgentChangesPartialAction, count: Int) -> String {
        actionTitle(action, noun: count == 1 ? "1 line" : "\(count) lines")
    }

    static func unavailableMessage(
        for reason: AgentChangesPartialStagingUnavailableReason
    ) -> String? {
        switch reason {
        case .untrackedRequiresWholeFile:
            "Stage the whole file before staging individual lines."
        case .addedOrDeletedFile, .structuralChange, .binaryOrSubmodule:
            "Partial staging is unavailable for structural file changes."
        case .truncatedProjection:
            "Partial staging is disabled because not all changed lines are shown."
        case .rawPatchUnavailable, .malformedPatch:
            "Partial staging is unavailable for this patch."
        case .readOnlyCompare, .backendHasNoIndex, .unsafeScope, .conflicted:
            nil
        }
    }
}

/// One background span after intraline and search ranges have been composed.
struct AgentChangesTextHighlightSpan: Equatable {
    enum Kind: Equatable {
        case intraline
        case search
        case currentSearch
    }

    let utf16Range: Range<Int>
    let kind: Kind
}

struct AgentChangesSearchHighlight: Equatable {
    let utf16Range: Range<Int>
    let isCurrent: Bool
}

/// Search takes precedence only where it overlaps an intraline range; current search takes the
/// strongest background. Splitting at every endpoint preserves intraline emphasis everywhere else.
enum AgentChangesHighlightComposition {
    static func spans(
        utf16Length: Int,
        intralineRanges: [Range<Int>],
        searchHighlights: [AgentChangesSearchHighlight]
    ) -> [AgentChangesTextHighlightSpan] {
        let intraline = intralineRanges.filter { valid($0, length: utf16Length) }
        let search = searchHighlights.filter { valid($0.utf16Range, length: utf16Length) }
        let rangeBoundaries = intraline.flatMap { [$0.lowerBound, $0.upperBound] }
        let searchBoundaries = search.flatMap {
            [$0.utf16Range.lowerBound, $0.utf16Range.upperBound]
        }
        let boundaries = Set([0, utf16Length] + rangeBoundaries + searchBoundaries).sorted()

        var result: [AgentChangesTextHighlightSpan] = []
        for pair in zip(boundaries, boundaries.dropFirst()) where pair.0 < pair.1 {
            let range = pair.0 ..< pair.1
            let kind: AgentChangesTextHighlightSpan.Kind? = if search.contains(
                where: { $0.isCurrent && $0.utf16Range.contains(range) }
            ) {
                .currentSearch
            } else if search.contains(where: { $0.utf16Range.contains(range) }) {
                .search
            } else if intraline.contains(where: { $0.contains(range) }) {
                .intraline
            } else {
                nil
            }
            guard let kind else { continue }

            if let last = result.last,
               last.kind == kind,
               last.utf16Range.upperBound == range.lowerBound
            {
                result[result.count - 1] = AgentChangesTextHighlightSpan(
                    utf16Range: last.utf16Range.lowerBound ..< range.upperBound,
                    kind: kind
                )
            } else {
                result.append(AgentChangesTextHighlightSpan(utf16Range: range, kind: kind))
            }
        }
        return result
    }

    private static func valid(_ range: Range<Int>, length: Int) -> Bool {
        range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty
    }
}

private extension Range where Bound == Int {
    func contains(_ other: Range<Int>) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }
}

/// Builds one attributed string from the composed spans. Applying the already-prioritized spans
/// once avoids relying on modifier order for overlap semantics.
enum AgentChangesHighlightedText {
    static func make(
        _ text: String,
        intralineRanges: [Range<Int>] = [],
        searchHighlights: [AgentChangesSearchHighlight] = [],
        intralineBackground: Color? = nil,
        searchBackground: Color,
        currentSearchBackground: Color
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let spans = AgentChangesHighlightComposition.spans(
            utf16Length: text.utf16.count,
            intralineRanges: intralineRanges,
            searchHighlights: searchHighlights
        )
        for span in spans {
            guard let range = attributedRange(span.utf16Range, text: text, attributed: attributed) else {
                continue
            }
            switch span.kind {
            case .intraline:
                attributed[range].backgroundColor = intralineBackground
            case .search:
                attributed[range].backgroundColor = searchBackground
            case .currentSearch:
                attributed[range].backgroundColor = currentSearchBackground
            }
        }
        return attributed
    }

    static func attributedRange(
        _ utf16Range: Range<Int>,
        text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard utf16Range.lowerBound >= 0,
              utf16Range.upperBound <= text.utf16.count,
              !utf16Range.isEmpty
        else { return nil }
        let lower = String.Index(utf16Offset: utf16Range.lowerBound, in: text)
        let upper = String.Index(utf16Offset: utf16Range.upperBound, in: text)
        guard let attributedLower = AttributedString.Index(lower, within: attributed),
              let attributedUpper = AttributedString.Index(upper, within: attributed)
        else { return nil }
        return attributedLower ..< attributedUpper
    }
}

/// Pure keyboard-routing decision. The AppKit bridge supplies the explicit ancestry result; no
/// command is produced when the first responder belongs to the transcript or another surface.
enum AgentChangesPanelKeyCommand: Equatable {
    case focusSearch
    case nextMatch
    case previousMatch
    case clearAndResign
}

enum AgentChangesPanelKeyCommandRouting {
    static func command(
        character: String?,
        keyCode: UInt16,
        isCommandPressed: Bool,
        isShiftPressed: Bool,
        hasOtherModifiers: Bool,
        isFirstResponderInsidePanel: Bool,
        isSearchActive: Bool
    ) -> AgentChangesPanelKeyCommand? {
        guard isFirstResponderInsidePanel, !hasOtherModifiers else { return nil }
        switch (character?.lowercased(), isCommandPressed, isShiftPressed) {
        case ("f", true, false): return .focusSearch
        case ("g", true, false): return .nextMatch
        case ("g", true, true): return .previousMatch
        default:
            return keyCode == 53 && !isCommandPressed && !isShiftPressed && isSearchActive
                ? .clearAndResign
                : nil
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

    static func searchBackgroundColor(current: Bool, colorScheme: ColorScheme) -> Color {
        let opacity: Double = if current {
            colorScheme == .dark ? 0.52 : 0.36
        } else {
            colorScheme == .dark ? 0.3 : 0.2
        }
        return Color.accentColor.opacity(opacity)
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
