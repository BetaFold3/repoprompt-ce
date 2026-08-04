import Foundation

/// The utility panel's two content modes.
///
/// Segment selection is per tab rather than per window: a tab reviewing a diff and a tab reading a
/// design document want different answers, and switching tabs should return to whatever the user
/// was last doing in that tab.
enum AgentUtilityPanelSegment: String, CaseIterable, Identifiable {
    case changes
    case preview

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .preview: "Preview"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .changes: "Show repository changes"
        case .preview: "Show document preview"
        }
    }
}

/// Which comparison the user picked for the Changes segment.
///
/// Distinct from `AgentChangesCompareMode`, which the repository layer consumes: that type carries
/// the base branch inside its `.vsBase(base:)` case and so can only describe a *complete* compare.
/// The user's selection can legitimately be incomplete — picking vs-Base before naming a base is
/// the state that drives the "Choose base…" affordance. The design forbids silently inferring or
/// fetching a default branch, so that gap has to be representable rather than papered over.
///
/// Working Tree is the default because it answers "what has the agent touched right now". Agents
/// commit as they work, so vs-Base exists to keep the panel useful after those commits land.
enum AgentChangesCompareSelection: String, CaseIterable, Identifiable {
    /// Staged, unstaged, and conflicted entries against the index and `HEAD`.
    case workingTree
    /// Everything since the merge base with an explicitly chosen base branch.
    case vsBase

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .workingTree: "Working Tree"
        case .vsBase: "vs Base"
        }
    }

    /// Staging checkboxes are hidden in vs-Base: that list spans commits, and a file-level index
    /// mutation there would not mean what the row shows.
    var allowsStaging: Bool {
        self == .workingTree
    }
}

/// How projected file changes are arranged.
enum AgentChangesDiffViewMode: String, CaseIterable, Identifiable {
    case unified
    case split

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .unified: "Unified"
        case .split: "Split"
        }
    }
}

/// Which document the Preview segment is showing.
///
/// Deliberately a logical root ID plus a root-relative path rather than an absolute path: an agent
/// session can be bound to a worktree whose checkout moves or is torn down, and a stored absolute
/// path would then point at a stale — or worse, a wrong — checkout. Resolving through the root at
/// read time keeps the reference honest across rebinding.
struct PreviewDocumentReference: Equatable, Hashable {
    /// `WorkspaceRootRef.id` of the logical root the document belongs to.
    let rootID: UUID
    /// Path relative to that logical root, using forward slashes and no leading separator.
    let relativePath: String

    init(rootID: UUID, relativePath: String) {
        self.rootID = rootID
        self.relativePath = Self.normalize(relativePath)
    }

    /// Last path component, for titles and tab labels.
    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private static func normalize(_ path: String) -> String {
        var normalized = path
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }
}

/// How an HTML document renders.
enum AgentPreviewHTMLDisplayMode: String, CaseIterable, Identifiable {
    case rendered
    case source

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .rendered: "Rendered"
        case .source: "Source"
        }
    }
}

/// Per-tab state for the right utility panel.
///
/// **Not persisted in Phase 1, by design.** `TabSession` is not `Codable`; sessions reach disk
/// through the hand-built `AgentSession` DTO, which maps persisted fields one by one. This state is
/// never added to that mapping, so it cannot enter the durable schema by accident. That is the
/// intent, not an oversight: every field here is a view into a checkout that may not exist on the
/// next launch — a base branch that has since been merged, expanded paths for files that are gone,
/// a preview document in a torn-down worktree. Restoring those would resurrect a stale view of a
/// repository rather than the user's work. Durable panel preferences that *are* worth keeping
/// (the preferred width) live in `GlobalSettingsStore` instead.
///
/// A value type, so the UI-store facade can snapshot it and compare for equality without the
/// aliasing hazards of handing a reference to a SwiftUI view.
struct AgentUtilityPanelTabState: Equatable {
    /// Which segment this tab shows.
    var segment: AgentUtilityPanelSegment = .changes

    /// Tab-global echo of the most recently chosen base revision.
    ///
    /// `baseRevisionByRepoRoot` is authoritative for what a repository actually compares against.
    /// No caller may infer a missing group base from this scalar; it carries only the last value
    /// the user named, for tab-global presentation.
    var baseBranchOverride: String?

    var compareSelection: AgentChangesCompareSelection = .workingTree

    /// Quiet working-tree section filter. Hidden, but retained, while comparing against a base.
    var changesFilter: AgentChangesFilter = .all

    /// Unified is the safe default at the panel's ordinary widths. This preference is per tab and
    /// in memory only; the layout gate may move it back to unified when the panel narrows.
    var diffViewMode: AgentChangesDiffViewMode = .unified

    /// Tab-global projection of the legacy scalar base echo.
    ///
    /// Grouped orchestration resolves compare modes per repository from `baseRevisionByRepoRoot`
    /// through ``resolvedCompareMode(for:)``. `nil` still means a caller must ask rather than
    /// substitute a guess.
    var resolvedCompareMode: AgentChangesCompareMode? {
        switch compareSelection {
        case .workingTree:
            return .workingTree
        case .vsBase:
            guard let base = baseBranchOverride, !base.isEmpty else { return nil }
            return .vsBase(base: base)
        }
    }

    /// Qualified files whose hunks are expanded.
    ///
    /// The checkout identity is required even though staged and unstaged counterparts intentionally
    /// share a key. Without it, `README.md` in two visible repositories would open and close as if
    /// it were one file.
    var expandedFiles: Set<AgentChangesFileStateKey> = []

    /// Context escalation per qualified file. Absent keys read as `.standard`, so the map only
    /// carries files the user actually escalated.
    ///
    /// Escalation is one-way per file and per tab: starting every file at full context would make a
    /// large changeset pull the whole repository into the panel.
    var contextLevelsByFile: [AgentChangesFileStateKey: AgentChangesContextLevel] = [:]

    /// Last reviewed content revision per row, partitioned by checkout + compare target.
    ///
    /// Keeping the older revision is intentional: when a content delta advances the row, the eye
    /// can explain "Viewed, edited since" instead of losing the fact that review became stale.
    private(set) var viewedRevisionsByCompareTarget: [String: [String: UInt64]] = [:]

    /// Document shown by the Preview segment.
    var previewDocument: PreviewDocumentReference?

    var htmlDisplayMode: AgentPreviewHTMLDisplayMode = .rendered

    /// The sole in-memory script consent, keyed to the exact currently-open document.
    ///
    /// This is deliberately a document reference rather than a sticky Bool. A fresh
    /// tab, back-to-picker action, deep link to another file, and every different
    /// document selection all start scripts-off. Like the rest of this state it is
    /// never mapped into the persisted `AgentSession` DTO.
    private(set) var scriptedHTMLDocument: PreviewDocumentReference?

    /// Artifact IDs whose "written by agent" banner this tab has dismissed.
    ///
    /// Dismissal is per tab because the banner reports what *this* session's agent wrote.
    var dismissedBannerArtifactIDs: Set<String> = []

    /// Last non-empty base the user named for each repository.
    ///
    /// This is presentation memory only. It may preselect a candidate, but it never supplies a
    /// grouped compare target and clearing the picker deliberately preserves the remembered value.
    private var lastUsedBaseBranchByRepoRoot: [String: String] = [:]

    /// Explicit base revision selected independently for each repository shown by this tab.
    ///
    /// This map is the grouped-mode choice and memory in one place: a missing or empty entry means
    /// that repository must show "Choose base…". It is never populated from branch candidates,
    /// worktree metadata, or the legacy single-root base fields. Keeping it on this non-`Codable`
    /// value preserves the panel's no-persistence contract.
    private(set) var baseRevisionByRepoRoot: [String: String] = [:]

    init() {}

    // MARK: - Segment

    mutating func select(segment: AgentUtilityPanelSegment) {
        self.segment = segment
    }

    // MARK: - Changes target

    mutating func setCompareSelection(_ selection: AgentChangesCompareSelection) {
        compareSelection = selection
    }

    mutating func setDiffViewMode(_ mode: AgentChangesDiffViewMode) {
        diffViewMode = mode
    }

    mutating func setChangesFilter(_ filter: AgentChangesFilter) {
        changesFilter = filter
    }

    /// Records a named base in the tab-global echo and this repository's picker memory.
    ///
    /// It updates presentation state only. The explicit grouped base map remains separate, so this
    /// API can never infer a compare target on a repository's behalf.
    mutating func selectBaseBranch(_ branch: String?, forRepoRoot repoRoot: String) {
        baseBranchOverride = branch
        guard let branch, !branch.isEmpty else { return }
        lastUsedBaseBranchByRepoRoot[repoRoot] = branch
    }

    /// Returns picker presentation memory for a repository, never an explicit grouped base.
    func lastUsedBaseBranch(forRepoRoot repoRoot: String) -> String? {
        lastUsedBaseBranchByRepoRoot[repoRoot]
    }

    /// Returns only the revision explicitly selected for this repository.
    ///
    /// Candidate lists are presentation data and never participate in this lookup.
    func selectedBaseRevision(forRepoRoot repoRoot: String) -> String? {
        baseRevisionByRepoRoot[repoRoot]
    }

    /// Selects or clears the explicit base revision for one repository.
    ///
    /// Clearing removes the entry rather than retaining a hidden fallback. The next vs-Base
    /// resolution therefore returns `nil` and asks again, as required by the design.
    mutating func selectBaseRevision(_ revision: String?, forRepoRoot repoRoot: String) {
        guard let revision, !revision.isEmpty else {
            baseRevisionByRepoRoot.removeValue(forKey: repoRoot)
            return
        }
        baseRevisionByRepoRoot[repoRoot] = revision
    }

    /// Stable viewed-partition key for one resolved checkout and its explicit compare.
    ///
    /// Centralizing this spelling prevents expansion/view code from accidentally falling back to a
    /// path-only or global compare key when several repositories are visible.
    static func viewedCompareTargetKey(
        for target: AgentPanelResolvedCheckout,
        mode: AgentChangesCompareMode
    ) -> String {
        let compare = switch mode {
        case .workingTree:
            "workingTree"
        case let .vsBase(base):
            "vsBase:\(base)"
        }
        return "\(target.targetKey)\u{1F}\(compare)"
    }

    /// Projects the tab's global compare selection for one resolved checkout.
    ///
    /// Working Tree is complete without repository-specific input. vs-Base resolves only from this
    /// target's explicit map entry; neither the legacy single-root override nor candidates can fill
    /// the gap.
    func resolvedCompareMode(for target: AgentPanelResolvedCheckout) -> AgentChangesCompareMode? {
        switch compareSelection {
        case .workingTree:
            return .workingTree
        case .vsBase:
            guard let base = selectedBaseRevision(forRepoRoot: target.repoRootURL.path) else {
                return nil
            }
            return .vsBase(base: base)
        }
    }

    // MARK: - File expansion

    func isExpanded(file key: AgentChangesFileStateKey) -> Bool {
        expandedFiles.contains(key)
    }

    /// Toggles one qualified file's expansion and reports the resulting state, so callers can
    /// trigger the lazy patch load only when a file actually opened.
    @discardableResult
    mutating func toggleExpansion(ofFile key: AgentChangesFileStateKey) -> Bool {
        if expandedFiles.contains(key) {
            expandedFiles.remove(key)
            return false
        }
        expandedFiles.insert(key)
        return true
    }

    mutating func setExpansion(_ isExpanded: Bool, ofFile key: AgentChangesFileStateKey) {
        if isExpanded {
            expandedFiles.insert(key)
        } else {
            expandedFiles.remove(key)
        }
    }

    mutating func collapseAllFiles() {
        expandedFiles.removeAll()
    }

    // MARK: - Viewed

    func viewedStatus(
        for revision: AgentChangesViewedRevision,
        compareTargetKey: String
    ) -> AgentChangesViewedStatus {
        guard let recorded = viewedRevisionsByCompareTarget[compareTargetKey]?[revision.rowID] else {
            return .notViewed
        }
        return recorded == revision.contentRevision ? .viewed : .editedSinceViewed
    }

    mutating func setViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String
    ) {
        var revisions = viewedRevisionsByCompareTarget[compareTargetKey] ?? [:]
        if viewed {
            revisions[revision.rowID] = revision.contentRevision
        } else {
            revisions.removeValue(forKey: revision.rowID)
        }
        if revisions.isEmpty {
            viewedRevisionsByCompareTarget.removeValue(forKey: compareTargetKey)
        } else {
            viewedRevisionsByCompareTarget[compareTargetKey] = revisions
        }
    }

    // MARK: - Context escalation

    func contextLevel(forFile key: AgentChangesFileStateKey) -> AgentChangesContextLevel {
        contextLevelsByFile[key] ?? .standard
    }

    /// Raises one qualified file's context level by a step and reports the new level.
    ///
    /// Saturates at the top rung, so a repeated tap on an already-full-file diff is a no-op rather
    /// than a wrap back to three lines.
    @discardableResult
    mutating func escalateContext(forFile key: AgentChangesFileStateKey) -> AgentChangesContextLevel {
        let current = contextLevel(forFile: key)
        let escalated = current.escalated ?? current
        contextLevelsByFile[key] = escalated
        return escalated
    }

    // MARK: - Preview

    /// Points the Preview segment at a document without changing which segment is showing.
    mutating func selectPreviewDocument(_ document: PreviewDocumentReference?) {
        guard previewDocument != document else { return }
        previewDocument = document
        // Consent is exact-reference-only. Clearing here makes every caller — picker,
        // wiki link, and back navigation — inherit the same safe transition.
        scriptedHTMLDocument = nil
    }

    /// The banner deep link: opens a document *and* reveals it, in one step, so the caller cannot
    /// leave the panel showing Changes while Preview silently retargets.
    mutating func showPreview(of document: PreviewDocumentReference) {
        if previewDocument != document {
            scriptedHTMLDocument = nil
        }
        previewDocument = document
        segment = .preview
    }

    func areHTMLScriptsEnabled(for document: PreviewDocumentReference) -> Bool {
        scriptedHTMLDocument == document && previewDocument == document
    }

    /// Records one explicit opt-in only if the requested document is still current.
    /// A stale confirmation can therefore fail only toward scripts-off.
    mutating func enableHTMLScriptsOnce(for document: PreviewDocumentReference) {
        guard previewDocument == document else { return }
        scriptedHTMLDocument = document
    }

    mutating func disableHTMLScripts() {
        scriptedHTMLDocument = nil
    }

    mutating func setHTMLDisplayMode(_ mode: AgentPreviewHTMLDisplayMode) {
        htmlDisplayMode = mode
    }

    // MARK: - Artifact banner

    func isBannerDismissed(artifactID: String) -> Bool {
        dismissedBannerArtifactIDs.contains(artifactID)
    }

    mutating func dismissBanner(artifactID: String) {
        dismissedBannerArtifactIDs.insert(artifactID)
    }
}
