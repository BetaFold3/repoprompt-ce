import Foundation

// MARK: - Compare mode

/// What the Changes panel is comparing.
enum AgentChangesCompareMode: Equatable {
    /// Staged / Unstaged / Conflicts against the index and HEAD.
    case workingTree
    /// Everything since the merge base with `base`, as one read-only list.
    case vsBase(base: String)

    var allowsStaging: Bool {
        if case .workingTree = self { return true }
        return false
    }
}

/// Which working-tree section is visible. Filtering never mutates repository state.
enum AgentChangesFilter: String, CaseIterable, Identifiable {
    case all
    case staged
    case unstaged
    case conflicts

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .conflicts: "Conflicts"
        }
    }
}

/// Result of resolving a free-text compare revision in the selected repository.
enum AgentChangesRevisionValidation: Equatable {
    case valid(objectID: String)
    case invalid(String)
    case ambiguous(String)
    case failed(String)

    var errorMessage: String? {
        switch self {
        case .valid:
            nil
        case let .invalid(message), let .ambiguous(message), let .failed(message):
            message
        }
    }
}

// MARK: - Sections

/// The lists a changed file can appear in.
///
/// Membership comes from one `git status --porcelain=v2` read, never from comparing two diffs:
/// agents run Git concurrently, and two sequential diff reads can straddle a mutation and disagree
/// about which files exist.
enum AgentChangesSectionKind: String, Equatable, CaseIterable {
    case staged
    case unstaged
    case conflicts
    /// The flat vs-Base list. Read-only; it has no index to mutate.
    case vsBase
    /// The single working-copy list shown by backends without an index (Jujutsu).
    case workingCopy

    var title: String {
        switch self {
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .conflicts: "Conflicts"
        case .vsBase: "Changes vs Base"
        // Jujutsu's own word for it. "Changes" would repeat the segment's name back at the user
        // and hide the one fact this section exists to state: there is no index behind it.
        case .workingCopy: "Working Copy"
        }
    }

    /// Whether rows in this section can be staged or unstaged.
    var isStageable: Bool {
        switch self {
        case .staged, .unstaged: true
        // Conflicts are excluded deliberately: `git add` on an unmerged path records the conflict
        // markers as resolved content. Resolution is a separate, distinctly labelled action.
        case .conflicts, .vsBase, .workingCopy: false
        }
    }

    /// The compare this section's patches are generated from.
    func compareSpec(mode: AgentChangesCompareMode) -> GitDiffCompareSpec {
        switch self {
        case .staged:
            .staged(base: "HEAD")
        case .unstaged, .conflicts:
            .unstaged
        case .vsBase:
            if case let .vsBase(base) = mode { .uncommittedMergeBase(base: base) } else { .unstaged }
        case .workingCopy:
            .uncommitted(base: "HEAD")
        }
    }
}

// MARK: - File rows

/// One changed file in one section.
///
/// A partially-staged file produces two rows — one per section — with the same ``fileKey`` and
/// different ``id``s, because the two sections show genuinely different patches of the same file.
struct AgentChangesFileRow: Equatable, Identifiable {
    /// `"<section>:<fileKey>"`. Section-qualified so the dual rows of a partially-staged file are
    /// distinct identities to SwiftUI while still resolving to one file.
    let id: String

    /// The `perFile` patch-map key, which is also ``FileDiffProjection/Document/id``. Keeping the
    /// panel's file identity equal to the projection's means a row and its patch cannot disagree
    /// about which file they describe.
    let fileKey: String

    /// Repository-relative path.
    let path: String

    /// The pre-change path for renames and copies.
    let originalPath: String?

    let section: AgentChangesSectionKind

    /// Porcelain's index status character, or nil when the record carries no XY pair.
    let indexStatus: Character?

    /// Porcelain's working-tree status character, or nil when the record carries no XY pair.
    let workTreeStatus: Character?

    let isUntracked: Bool
    let isConflicted: Bool

    /// Added lines, or nil when no stats were available (binary files, or a numstat read that the
    /// authoritative status read deliberately did not wait for).
    let additions: Int?
    let deletions: Int?

    /// True when this file also appears in the opposite working-tree section — the partially-staged
    /// case. Surfaced on the row so the UI does not have to re-scan the other section to mark it.
    let hasCounterpartSection: Bool

    /// The content revision this row was built at. The staging preflight compares it against the
    /// live value to prove the file has not changed since the user saw it.
    let contentRevision: UInt64

    /// False when at least one path the corresponding Git mutation would touch is outside the
    /// represented logical-root scope.
    let isMutationScopeSafe: Bool

    init(
        id: String,
        fileKey: String,
        path: String,
        originalPath: String?,
        section: AgentChangesSectionKind,
        indexStatus: Character?,
        workTreeStatus: Character?,
        isUntracked: Bool,
        isConflicted: Bool,
        additions: Int?,
        deletions: Int?,
        hasCounterpartSection: Bool,
        contentRevision: UInt64,
        isMutationScopeSafe: Bool = true
    ) {
        self.id = id
        self.fileKey = fileKey
        self.path = path
        self.originalPath = originalPath
        self.section = section
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
        self.additions = additions
        self.deletions = deletions
        self.hasCounterpartSection = hasCounterpartSection
        self.contentRevision = contentRevision
        self.isMutationScopeSafe = isMutationScopeSafe
    }

    var identity: VCSIndexPathIdentity {
        let isCopy = indexStatus == "C" || workTreeStatus == "C"
        return VCSIndexPathIdentity(
            path: path,
            originalPath: originalPath,
            includesOriginalPathInMutation: !isCopy
        )
    }

    /// Two-character XY status for display, matching porcelain's own vocabulary.
    var displayStatus: String {
        if isUntracked { return "??" }
        return String([indexStatus ?? ".", workTreeStatus ?? "."])
    }

    /// Whether this row's checkbox can act. Conflicts and scope-escaping identities are inert.
    var isStageable: Bool {
        section.isStageable && !isConflicted && isMutationScopeSafe
    }

    /// True when the row represents an already-staged state.
    var isStaged: Bool {
        section == .staged
    }

    static func makeID(section: AgentChangesSectionKind, fileKey: String) -> String {
        "\(section.rawValue):\(fileKey)"
    }

    /// The exact review unit represented by this row at its current content revision.
    var viewedRevision: AgentChangesViewedRevision {
        AgentChangesViewedRevision(rowID: id, contentRevision: contentRevision)
    }
}

/// Revision-keyed Viewed identity. A later content revision intentionally fails equality.
struct AgentChangesViewedRevision: Equatable, Hashable {
    let rowID: String
    let contentRevision: UInt64
}

/// Whether a row is current, was current before a later edit, or has never been reviewed.
enum AgentChangesViewedStatus: Equatable {
    case notViewed
    case viewed
    case editedSinceViewed
}

/// One rendered section with its rows and rolled-up stats.
struct AgentChangesSection: Equatable, Identifiable {
    let kind: AgentChangesSectionKind
    let rows: [AgentChangesFileRow]

    var id: String {
        kind.rawValue
    }

    var isEmpty: Bool {
        rows.isEmpty
    }

    var fileCount: Int {
        rows.count
    }

    var additions: Int {
        rows.reduce(0) { $0 + ($1.additions ?? 0) }
    }

    var deletions: Int {
        rows.reduce(0) { $0 + ($1.deletions ?? 0) }
    }
}

struct AgentChangesFilterCounts: Equatable {
    let all: Int
    let staged: Int
    let unstaged: Int
    let conflicts: Int

    func count(for filter: AgentChangesFilter) -> Int {
        switch filter {
        case .all: all
        case .staged: staged
        case .unstaged: unstaged
        case .conflicts: conflicts
        }
    }
}

/// Pure working-tree filter policy shared by the view model and tests.
enum AgentChangesFiltering {
    static func counts(in sections: [AgentChangesSection]) -> AgentChangesFilterCounts {
        AgentChangesFilterCounts(
            all: Set(sections.flatMap { $0.rows.map(\.fileKey) }).count,
            staged: sections.first(where: { $0.kind == .staged })?.fileCount ?? 0,
            unstaged: sections.first(where: { $0.kind == .unstaged })?.fileCount ?? 0,
            conflicts: sections.first(where: { $0.kind == .conflicts })?.fileCount ?? 0
        )
    }

    static func sections(
        from sections: [AgentChangesSection],
        filter: AgentChangesFilter
    ) -> [AgentChangesSection] {
        switch filter {
        case .all:
            sections.filter { !$0.isEmpty }
        case .staged:
            sections.filter { $0.kind == .staged && !$0.isEmpty }
        case .unstaged:
            sections.filter { $0.kind == .unstaged && !$0.isEmpty }
        case .conflicts:
            sections.filter { $0.kind == .conflicts && !$0.isEmpty }
        }
    }
}

// MARK: - Patch load state

/// Why a file's patch cannot be shown.
enum AgentChangesPatchUnavailableReason: Equatable {
    /// Git reported no textual diff for this path under this compare.
    case noTextualDiff
    /// The patch or source file exceeded the byte budget the panel renders inline.
    case tooLarge(bytes: Int)
    /// Source context exceeded the line budget even though it fit the byte budget.
    case tooManyLines(lines: Int)
    /// A staged patch was requested in a repository whose HEAD has no commit yet, so there is no
    /// tree to diff against. Membership still renders — porcelain does not need HEAD.
    case unbornHead
    case failed(String)
}

/// Lazy per-file patch state. Refresh never populates this; expanding a file does.
enum AgentChangesPatchLoadState: Equatable {
    case idle
    case loading
    case loaded(FileDiffProjection.Document)
    case unavailable(AgentChangesPatchUnavailableReason)

    var document: FileDiffProjection.Document? {
        if case let .loaded(document) = self { return document }
        return nil
    }
}

/// The source version and side used to fill unchanged diff gaps.
struct AgentChangesContextSourceSelection: Equatable {
    let source: AgentChangesFileContentSource
    let side: DiffContextSplicer.SourceSide
}

enum AgentChangesGapExpansionOutcome: Equatable {
    case expanded(
        document: FileDiffProjection.Document,
        sourceLineCount: Int,
        sourceSide: DiffContextSplicer.SourceSide
    )
    case unavailable(AgentChangesPatchUnavailableReason)
}

/// Pure policy selecting the file version whose unchanged lines can fill a projected gap.
enum AgentChangesContextSourceResolver {
    static func selection(
        for row: AgentChangesFileRow,
        document: FileDiffProjection.Document,
        mode: AgentChangesCompareMode,
        hasHeadCommit: Bool
    ) -> AgentChangesContextSourceSelection? {
        if row.section == .staged, !hasHeadCommit { return nil }

        let sourcePath = document.change == .deleted
            ? (document.oldPath ?? row.originalPath ?? row.path)
            : row.path

        if document.change == .deleted {
            switch row.section {
            case .staged:
                return AgentChangesContextSourceSelection(
                    source: .reference(
                        .named(document.oldSourceReference ?? "HEAD"),
                        path: sourcePath
                    ),
                    side: .old
                )
            case .unstaged:
                return AgentChangesContextSourceSelection(
                    source: .index(path: sourcePath),
                    side: .old
                )
            case .vsBase:
                guard case let .vsBase(base) = mode else { return nil }
                let reference: AgentChangesFileContentSource.Reference = document.oldSourceReference
                    .map(AgentChangesFileContentSource.Reference.named)
                    ?? .mergeBase(base: base)
                return AgentChangesContextSourceSelection(
                    source: .reference(reference, path: sourcePath),
                    side: .old
                )
            case .workingCopy:
                return nil
            case .conflicts:
                return AgentChangesContextSourceSelection(
                    source: .worktree(path: row.path),
                    side: .new
                )
            }
        }

        switch row.section {
        case .staged:
            return AgentChangesContextSourceSelection(
                source: .index(path: row.path),
                side: .new
            )
        case .unstaged, .conflicts, .vsBase, .workingCopy:
            return AgentChangesContextSourceSelection(
                source: .worktree(path: row.path),
                side: .new
            )
        }
    }
}

/// The context widths a file's patch can be requested at.
enum AgentChangesContextLevel: Equatable, CaseIterable {
    case standard
    case expanded
    case fullFile

    /// The `-U` value passed to Git.
    var contextLines: Int {
        switch self {
        case .standard: 3
        case .expanded: 12
        // Larger than any file the panel renders inline, which is what "full file" means to Git.
        case .fullFile: 1_000_000
        }
    }

    /// The next rung, or nil at the top.
    var escalated: AgentChangesContextLevel? {
        switch self {
        case .standard: .expanded
        case .expanded: .fullFile
        case .fullFile: nil
        }
    }

    var projectionLevel: FileDiffProjection.ContextLevel {
        switch self {
        case .standard, .expanded: .lines(contextLines)
        case .fullFile: .fullFile
        }
    }
}

// MARK: - Snapshot

/// Why the panel has nothing to show.
enum AgentChangesEmptyReason: Equatable {
    case noCheckout
    case cleanTree
    case unbornHeadCleanTree
}

/// The panel's data state after one rebuild.
enum AgentChangesLoadState: Equatable {
    /// No rebuild has completed for the current target yet.
    case initial
    case ready
    case failed(String)
}

/// Everything the Changes panel renders for one checkout, from one rebuild.
struct AgentChangesSnapshot: Equatable {
    /// Monotonic per-target build number. A retarget bumps it, and results carrying an old
    /// generation are dropped rather than published.
    let generation: UInt64

    let target: AgentPanelResolvedCheckout?
    let mode: AgentChangesCompareMode
    let sections: [AgentChangesSection]
    let loadState: AgentChangesLoadState

    /// False for backends without an index (Jujutsu). The panel hides the staging surface entirely
    /// rather than showing controls that would throw.
    let supportsStaging: Bool

    /// False in a repository whose HEAD has no commit yet.
    let hasHeadCommit: Bool

    /// True while this checkout is on the degraded poll because its watcher could not be created.
    let isPollingDegraded: Bool

    /// The content-revision epoch this snapshot was built at.
    let contentEpoch: UInt64

    /// The diff/index observation that produced these rows. Patch request keys include it so an
    /// index-only change invalidates a partially-staged file's already-loaded projection.
    let fingerprint: GitDiffFingerprint?

    init(
        generation: UInt64,
        target: AgentPanelResolvedCheckout?,
        mode: AgentChangesCompareMode,
        sections: [AgentChangesSection],
        loadState: AgentChangesLoadState,
        supportsStaging: Bool,
        hasHeadCommit: Bool,
        isPollingDegraded: Bool,
        contentEpoch: UInt64,
        fingerprint: GitDiffFingerprint? = nil
    ) {
        self.generation = generation
        self.target = target
        self.mode = mode
        self.sections = sections
        self.loadState = loadState
        self.supportsStaging = supportsStaging
        self.hasHeadCommit = hasHeadCommit
        self.isPollingDegraded = isPollingDegraded
        self.contentEpoch = contentEpoch
        self.fingerprint = fingerprint
    }

    static let empty = AgentChangesSnapshot(
        generation: 0,
        target: nil,
        mode: .workingTree,
        sections: [],
        loadState: .initial,
        supportsStaging: false,
        hasHeadCommit: true,
        isPollingDegraded: false,
        contentEpoch: 0
    )

    var fingerprintKey: String {
        guard let fingerprint else { return "" }
        return "\(fingerprint.headSHA)|\(fingerprint.baseRef)|\(fingerprint.statusHash)"
    }

    var totalFileCount: Int {
        // A partially-staged file holds two rows; counting distinct files keeps the footer honest.
        Set(sections.flatMap { $0.rows.map(\.fileKey) }).count
    }

    var additions: Int {
        sections.reduce(0) { $0 + $1.additions }
    }

    var deletions: Int {
        sections.reduce(0) { $0 + $1.deletions }
    }

    var emptyReason: AgentChangesEmptyReason? {
        if target == nil { return .noCheckout }
        guard sections.allSatisfy(\.isEmpty) else { return nil }
        return hasHeadCommit ? .cleanTree : .unbornHeadCleanTree
    }

    func section(_ kind: AgentChangesSectionKind) -> AgentChangesSection? {
        sections.first { $0.kind == kind }
    }
}

/// Header/footer progress counts logical files once. A partially-staged file is complete only after
/// both of its distinct patches have been reviewed.
struct AgentChangesViewedProgress: Equatable {
    let viewedFileCount: Int
    let totalFileCount: Int

    var fraction: Double {
        guard totalFileCount > 0 else { return 0 }
        return Double(viewedFileCount) / Double(totalFileCount)
    }

    static func compute(
        sections: [AgentChangesSection],
        isViewed: (AgentChangesFileRow) -> Bool
    ) -> AgentChangesViewedProgress {
        let grouped = Dictionary(grouping: sections.flatMap(\.rows), by: \.fileKey)
        return AgentChangesViewedProgress(
            viewedFileCount: grouped.values.count { rows in rows.allSatisfy(isViewed) },
            totalFileCount: grouped.count
        )
    }
}

// MARK: - Refresh triggers

/// Why the panel is rebuilding.
///
/// The two flags are the whole gating policy, kept as data on the trigger so the rules live in one
/// readable table instead of scattered across the rebuild loop.
enum AgentChangesRefreshTrigger: Equatable {
    /// A `.git` metadata invalidation. Cheap and frequent — ref writes, index refreshes, gc — so it
    /// is gated on the diff fingerprint actually changing.
    case metadata

    /// Workspace content changed at these absolute paths.
    case contentDelta(paths: Set<String>)

    /// The degraded 5s poll, used only when a watcher could not be created.
    case poll

    /// App activation or wake. Anything could have happened while the app was not listening.
    case reconcile

    /// A staging mutation this repository performed just landed.
    case mutationCompleted

    /// The user pressed refresh.
    case manual

    /// Whether this trigger rebuilds even when the diff fingerprint is unchanged.
    ///
    /// Only `.metadata` is gated. Every other trigger describes a change the fingerprint cannot
    /// see, so gating them would be gating on the wrong evidence.
    var bypassesFingerprintGate: Bool {
        switch self {
        case .metadata: false
        case .contentDelta, .poll, .reconcile, .mutationCompleted, .manual: true
        }
    }

    /// Whether this trigger advances the content revision, evicting cached patches.
    ///
    /// The subtle case is `.contentDelta`. Porcelain output is byte-identical when an
    /// already-modified file is modified again — the XY pair stays `.M` and the fingerprint's
    /// status hash does not move — yet the file's diff text is now different. Re-editing a file the
    /// agent already touched is the single most common thing that happens while this panel is open,
    /// so content deltas must both bypass the gate and invalidate cached patches, or the panel
    /// would freeze on stale hunks precisely when it is being watched.
    ///
    /// `.mutationCompleted` is the deliberate exception: staging moves a file between the index and
    /// the working tree without changing its bytes. The fingerprint changes on its own, which
    /// re-keys the cache, so wiping patches as well would only re-fetch identical text.
    var advancesContentRevision: Bool {
        switch self {
        case .contentDelta, .poll, .reconcile, .manual: true
        case .metadata, .mutationCompleted: false
        }
    }
}

// MARK: - Staging outcomes

/// The result of one requested staging change.
enum AgentChangesMutationOutcome: Equatable {
    /// The index now matches the request because it already did. No Git ran.
    case noOp
    case applied
    /// The file changed on disk between the render the user reviewed and the click. The panel
    /// refreshes instead of staging content nobody has seen.
    case contentChanged
    /// The backend has no index to mutate.
    case unsupported
    /// Unmerged paths are never staged from this surface.
    case conflicted
    case failed(String)

    var didMutate: Bool {
        self == .applied
    }
}

/// One requested staging change.
struct AgentChangesResolveRequest: Equatable {
    let identity: VCSIndexPathIdentity
    let expectedContentRevision: UInt64

    init(row: AgentChangesFileRow) {
        identity = row.identity
        expectedContentRevision = row.contentRevision
    }

    init(identity: VCSIndexPathIdentity, expectedContentRevision: UInt64) {
        self.identity = identity
        self.expectedContentRevision = expectedContentRevision
    }
}

struct AgentChangesMutationRequest: Equatable {
    let identity: VCSIndexPathIdentity
    /// True to stage, false to unstage.
    let stage: Bool
    /// The content revision the reviewed row carried. The preflight rejects the mutation when the
    /// file has moved on since.
    let expectedContentRevision: UInt64

    init(row: AgentChangesFileRow, stage: Bool) {
        identity = row.identity
        self.stage = stage
        expectedContentRevision = row.contentRevision
    }

    init(identity: VCSIndexPathIdentity, stage: Bool, expectedContentRevision: UInt64) {
        self.identity = identity
        self.stage = stage
        self.expectedContentRevision = expectedContentRevision
    }
}

/// The exact section contents the user saw before invoking Stage All or Unstage All.
struct AgentChangesBulkMutationRequest: Equatable {
    struct ReviewedIdentity: Equatable {
        let identity: VCSIndexPathIdentity
        let contentRevision: UInt64
    }

    let section: AgentChangesSectionKind
    let stage: Bool
    let reviewed: [ReviewedIdentity]

    init(section: AgentChangesSectionKind, stage: Bool, rows: [AgentChangesFileRow]) {
        self.section = section
        self.stage = stage
        reviewed = rows.map {
            ReviewedIdentity(identity: $0.identity, contentRevision: $0.contentRevision)
        }
    }
}
