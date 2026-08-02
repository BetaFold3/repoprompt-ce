import Combine
import Foundation

// MARK: - Inputs

/// The workspace and session facts one checkout resolve needs.
///
/// Gathered in a single call rather than read field by field so the resolve always sees one
/// coherent picture: reading roots, then bindings, then the preparing flag across three awaits
/// could observe a session mid-rebind and produce a checkout list that never existed.
struct AgentChangesPanelRootInputs: Equatable {
    var logicalRoots: [AgentPanelLogicalRoot]
    /// `WorkspaceRootRef.id` keyed by standardized logical root path. The panel stores root
    /// *identities* in tab state and preview references, and paths everywhere else; this is the
    /// one translation table between them.
    var rootIDsByPath: [String: UUID]
    var worktreeBindings: [AgentSessionWorktreeBinding]
    var isPreparingWorktree: Bool

    /// Every root the app's own file watchers already cover, including session-worktree roots that
    /// are loaded but never offered in the root picker.
    ///
    /// Separate from ``logicalRoots`` because the two answer different questions: that list decides
    /// what the panel *shows*, this one decides whether a checkout needs a watcher of its own.
    var watchedRootPaths: [String]

    static let empty = AgentChangesPanelRootInputs(
        logicalRoots: [],
        rootIDsByPath: [:],
        worktreeBindings: [],
        isPreparingWorktree: false,
        watchedRootPaths: []
    )

    func rootID(forPath path: String) -> UUID? {
        rootIDsByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
    }
}

// MARK: - Environment seam

/// Everything the Changes panel's view model needs from the rest of the app.
///
/// One protocol rather than a handful, because every member here is a question about *the tab the
/// panel is showing*, and a view model that had to be handed a workspace store, a VCS service, a
/// session, and a tab-state writer separately would have four chances to be pointed at four
/// different tabs. Tests substitute a single fake and get a panel with no workspace, no repository
/// on disk, and no session graph.
@MainActor
protocol AgentChangesPanelEnvironment: AnyObject {
    /// Workspace roots plus this tab's worktree bindings.
    func rootInputs(tabID: UUID?) async -> AgentChangesPanelRootInputs

    /// The tab's transcript items, for the artifact index.
    func transcriptItems(tabID: UUID?) -> [AgentChatItem]

    /// Republishes whenever the tab's transcript items change, so the artifact banner tracks a
    /// running agent. `nil` for a tab with no live session.
    func transcriptItemsPublisher(tabID: UUID?) -> AnyPublisher<[AgentChatItem], Never>?

    /// Branch names offered by the base picker, most recently active first.
    func baseBranchCandidates(at checkout: URL) async -> [String]

    // MARK: Tab-state writes

    func selectRootOverride(_ rootID: UUID?, tabID: UUID?)
    func setCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID?)
    func setDiffViewMode(_ mode: AgentChangesDiffViewMode, tabID: UUID?)
    func setChangesFilter(_ filter: AgentChangesFilter, tabID: UUID?)
    func selectBaseBranch(_ branch: String?, forRepoRoot repoRoot: String, tabID: UUID?)
    func lastUsedBaseBranch(forRepoRoot repoRoot: String, tabID: UUID?) -> String?
    func setFileExpansion(_ isExpanded: Bool, filePath: String, tabID: UUID?)
    func setFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFilePath: String?,
        tabID: UUID?
    )
    @discardableResult
    func escalateContext(filePath: String, tabID: UUID?) -> AgentChangesContextLevel
    func showPreview(of document: PreviewDocumentReference, tabID: UUID?)
    func dismissBanner(artifactID: String, tabID: UUID?)
}

// MARK: - Live environment

/// Live environment over the Agent Mode view model, the workspace context store, and `VCSService`.
///
/// Deliberately thin: every method is a forward, so the interesting behavior stays in the view
/// model where it can be tested, and this type stays the part that only integration can prove.
@MainActor
final class AgentChangesPanelLiveEnvironment: AgentChangesPanelEnvironment {
    private weak var agentModeVM: AgentModeViewModel?
    private let vcsService: VCSService
    private let branchLimit: Int

    init(
        agentModeVM: AgentModeViewModel,
        vcsService: VCSService = .shared,
        branchLimit: Int = 50
    ) {
        self.agentModeVM = agentModeVM
        self.vcsService = vcsService
        self.branchLimit = branchLimit
    }

    private var workspaceStore: WorkspaceFileContextStore? {
        agentModeVM?.promptManager?.workspaceFileContextStore
    }

    // MARK: Inputs

    func rootInputs(tabID: UUID?) async -> AgentChangesPanelRootInputs {
        let session = agentModeVM.flatMap { vm in tabID.flatMap { vm.sessions[$0] } }
        guard let workspaceStore else {
            return AgentChangesPanelRootInputs(
                logicalRoots: [],
                rootIDsByPath: [:],
                worktreeBindings: session?.worktreeBindings ?? [],
                isPreparingWorktree: session?.isPreparingInitialWorktree ?? false,
                watchedRootPaths: []
            )
        }

        // `.visibleWorkspace` is exactly the panel's notion of a logical root: the folders the user
        // added. Session-worktree roots are deliberately excluded — the panel reaches a worktree
        // through the binding that names it, never by listing it as a root of its own, or the root
        // picker would offer the same repository twice under two names.
        let refs = await workspaceStore.rootRefs(scope: .visibleWorkspace)
        let watched = await workspaceStore.rootRefs(scope: .allLoaded)
        return AgentChangesPanelRootInputs(
            logicalRoots: refs.map { AgentPanelLogicalRoot(path: $0.standardizedFullPath, name: $0.name) },
            rootIDsByPath: Dictionary(
                refs.map { ($0.standardizedFullPath, $0.id) },
                uniquingKeysWith: { first, _ in first }
            ),
            worktreeBindings: session?.worktreeBindings ?? [],
            isPreparingWorktree: session?.isPreparingInitialWorktree ?? false,
            watchedRootPaths: watched.map(\.standardizedFullPath)
        )
    }

    func transcriptItems(tabID: UUID?) -> [AgentChatItem] {
        guard let tabID, let session = agentModeVM?.sessions[tabID] else { return [] }
        return session.items
    }

    func transcriptItemsPublisher(tabID: UUID?) -> AnyPublisher<[AgentChatItem], Never>? {
        guard let tabID, let session = agentModeVM?.sessions[tabID] else { return nil }
        return session.$items.eraseToAnyPublisher()
    }

    func baseBranchCandidates(at checkout: URL) async -> [String] {
        let backend = await vcsService.backend(forRepoRoot: checkout)
        async let localTask = try? backend.getLocalBranches(at: checkout, limit: branchLimit)
        async let remoteTask = try? backend.getRemoteBranches(at: checkout, limit: branchLimit)
        let local = await localTask ?? []
        let remote = await remoteTask ?? []

        // Locals first because a base is almost always a local integration branch; remotes follow
        // for the case where the local copy was never created. Order inside each group is the
        // backend's own recency order, which is the closest thing to "the branch you mean".
        var seen: Set<String> = []
        return (local + remote)
            .map(\.name)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Tab-state writes

    func selectRootOverride(_ rootID: UUID?, tabID: UUID?) {
        agentModeVM?.selectUtilityPanelRootOverride(rootID, tabID: tabID)
    }

    func setCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID?) {
        agentModeVM?.setUtilityPanelCompareSelection(selection, tabID: tabID)
    }

    func setDiffViewMode(_ mode: AgentChangesDiffViewMode, tabID: UUID?) {
        agentModeVM?.setUtilityPanelDiffViewMode(mode, tabID: tabID)
    }

    func setChangesFilter(_ filter: AgentChangesFilter, tabID: UUID?) {
        agentModeVM?.setUtilityPanelChangesFilter(filter, tabID: tabID)
    }

    func selectBaseBranch(_ branch: String?, forRepoRoot repoRoot: String, tabID: UUID?) {
        agentModeVM?.selectUtilityPanelBaseBranch(branch, forRepoRoot: repoRoot, tabID: tabID)
    }

    func lastUsedBaseBranch(forRepoRoot repoRoot: String, tabID: UUID?) -> String? {
        agentModeVM?.utilityPanelLastUsedBaseBranch(forRepoRoot: repoRoot, tabID: tabID)
    }

    func setFileExpansion(_ isExpanded: Bool, filePath: String, tabID: UUID?) {
        agentModeVM?.setUtilityPanelFileExpansion(isExpanded, filePath: filePath, tabID: tabID)
    }

    func setFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFilePath: String?,
        tabID: UUID?
    ) {
        agentModeVM?.setUtilityPanelFileViewed(
            viewed,
            revision: revision,
            compareTargetKey: compareTargetKey,
            collapseFilePath: collapseFilePath,
            tabID: tabID
        )
    }

    @discardableResult
    func escalateContext(filePath: String, tabID: UUID?) -> AgentChangesContextLevel {
        agentModeVM?.escalateUtilityPanelContext(filePath: filePath, tabID: tabID) ?? .standard
    }

    func showPreview(of document: PreviewDocumentReference, tabID: UUID?) {
        agentModeVM?.showUtilityPanelPreview(of: document, tabID: tabID)
    }

    func dismissBanner(artifactID: String, tabID: UUID?) {
        agentModeVM?.dismissUtilityPanelBanner(artifactID: artifactID, tabID: tabID)
    }
}

// MARK: - Trigger wiring

/// The set of root paths the app's own file watchers already cover.
///
/// Lives behind a lock and outside the actor because the repository builds a trigger feed for a
/// checkout from a `@Sendable` closure, at a moment the view model is not part of. Handing that
/// closure a snapshot taken at construction time would freeze the answer for the window's whole
/// life; handing it this box keeps the answer current as roots load and unload.
final class AgentChangesWatchedRootPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    init(paths: [String] = []) {
        self.paths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    func update(_ newPaths: [String]) {
        let standardized = newPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        lock.withLock { paths = standardized }
    }

    /// Whether an already-watched workspace root covers this checkout.
    ///
    /// A checkout that is covered needs no watcher of its own; one that is not — the usual shape of
    /// an agent worktree parked outside the workspace — needs a scoped watch, or its diff would
    /// never refresh.
    func covers(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        return lock.withLock {
            paths.contains { root in
                target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }
}

extension AgentChangesTriggerSources {
    /// Absolute changed paths from every workspace root the app watches.
    ///
    /// The store already fans its per-root `FileSystemService` publishers into one stream, so the
    /// panel subscribes once rather than reaching into a service per root and re-deriving which
    /// roots exist on every reload. Paths are made absolute here because the repository's scope
    /// filter speaks absolute paths and a root-relative one would silently match nothing.
    static func workspaceContentDeltas(
        store: WorkspaceFileContextStore
    ) -> @Sendable () -> AsyncStream<Set<String>> {
        { @Sendable in
            AsyncStream { continuation in
                let task = Task {
                    for await event in await store.fileSystemDeltaEvents() {
                        let absolute = URL(fileURLWithPath: event.rootPath)
                            .appendingPathComponent(relativeEventPath(of: event.delta))
                            .standardizedFileURL
                            .path
                        continuation.yield([absolute])
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private static func relativeEventPath(of delta: FileSystemDelta) -> String {
        switch delta {
        case let .fileAdded(path),
             let .fileRemoved(path),
             let .folderAdded(path),
             let .folderRemoved(path):
            path
        case let .fileModified(path, _),
             let .folderModified(path, _):
            path
        }
    }
}
