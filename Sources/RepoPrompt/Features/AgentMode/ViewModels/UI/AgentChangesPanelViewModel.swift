import Combine
import Foundation

/// The Changes segment's controller: one per window, following whichever tab is active.
///
/// It owns three things the views must not own themselves.
///
/// **The repository.** One `AgentChangesRepository` per window, retargeted as the tab, root,
/// compare mode, or base changes. A repository per *tab* would keep a file watcher and a rebuild
/// loop alive for every background session in the window; a repository per *view* would be torn
/// down and rebuilt by SwiftUI on every layout change.
///
/// **The direction of writes.** Tab state is canonical in `TabSession`, so every user action here
/// writes through the environment and lets the change come back through the UI-store facade. The
/// view model keeps a local echo of the state it was last synced with — without it, an expansion
/// toggle could not start its patch load until the next render, and the panel would feel a frame
/// behind on every click.
///
/// **What is in flight.** Patch loads, staging mutations, and their pending presentation live here
/// rather than in view `@State`, because SwiftUI recreates row views freely and a spinner owned by
/// a row would vanish the moment the list re-sorted underneath it.
@MainActor
final class AgentChangesPanelViewModel: ObservableObject {
    // MARK: - Published state

    @Published private(set) var snapshot: AgentChangesSnapshot = .empty

    /// `nil` until the first checkout resolve completes, which is what separates "still looking"
    /// from "looked, and there is nothing here".
    @Published private(set) var resolution: AgentPanelCheckoutResolution?

    /// Patch state per row ID. Only expanded rows have entries.
    @Published private(set) var patchStates: [String: AgentChangesPatchLoadState] = [:]

    /// Source metadata and one in-flight per-gap read per expanded row.
    @Published private(set) var gapContextStates: [String: GapContextState] = [:]

    /// In-flight single-file staging, keyed by repository-relative path so both rows of a
    /// partially-staged file see the same pending state.
    @Published private(set) var pendingStagingByPath: [String: PendingStaging] = [:]

    /// Sections with a stage-all or unstage-all in flight.
    @Published private(set) var pendingBulkSections: Set<AgentChangesSectionKind> = []

    /// In-flight conflict resolution, keyed by path so only its row and overlapping bulk actions
    /// are disabled.
    @Published private(set) var pendingResolutionByPath: [String: PendingResolution] = [:]

    /// Inline free-text revision editor. Accepted base state is not changed until validation passes.
    @Published private(set) var customRevisionEditor: CustomRevisionEditor?

    /// Files whose row should flash because the panel refreshed them instead of staging content
    /// nobody had reviewed.
    @Published private(set) var flashedFileKeys: Set<String> = []

    @Published private(set) var statusMessage: StatusMessage?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false

    /// Branches offered by the base picker. Loaded when a checkout becomes active, never used to
    /// pick a base on the user's behalf.
    @Published private(set) var baseBranchCandidates: [String] = []

    /// The artifact banner, already resolved to a document the Preview segment can address.
    @Published private(set) var bannerLink: ArtifactBannerLink?

    // MARK: - Value types

    struct PendingStaging: Equatable {
        /// What the user asked for. The checkbox shows this while the mutation runs, so the click
        /// registers immediately without the row jumping to another section before Git agrees.
        let requestedStage: Bool
        /// Set once the mutation outlives the grace period. A spinner that appears instantly on a
        /// mutation that finishes in 20ms reads as a glitch.
        var showsSpinner: Bool
    }

    struct PendingResolution: Equatable {
        var showsSpinner: Bool
    }

    struct CustomRevisionEditor: Equatable {
        enum State: Equatable {
            case editing
            case validating
            case error(String)
        }

        var text: String
        var state: State

        var errorMessage: String? {
            if case let .error(message) = state { return message }
            return nil
        }

        var isValidating: Bool {
            state == .validating
        }
    }

    struct ArtifactBannerLink: Equatable {
        let artifact: AgentSessionArtifact
        let document: PreviewDocumentReference
    }

    struct GapContextState: Equatable {
        var sourceLineCount: Int?
        var sourceSide: DiffContextSplicer.SourceSide
        var loadingGapID: String?
        var unavailableReason: AgentChangesPatchUnavailableReason?

        init(
            sourceLineCount: Int? = nil,
            sourceSide: DiffContextSplicer.SourceSide = .new,
            loadingGapID: String? = nil,
            unavailableReason: AgentChangesPatchUnavailableReason? = nil
        ) {
            self.sourceLineCount = sourceLineCount
            self.sourceSide = sourceSide
            self.loadingGapID = loadingGapID
            self.unavailableReason = unavailableReason
        }
    }

    enum StatusMessage: Equatable {
        case info(String)
        case failure(String)

        var text: String {
            switch self {
            case let .info(text), let .failure(text): text
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    // MARK: - Dependencies

    private let environment: any AgentChangesPanelEnvironment
    private let repository: AgentChangesRepository
    private let probe: any AgentPanelCheckoutProbing
    private let scheduler: any AgentChangesScheduler
    private let watchedRootPaths: AgentChangesWatchedRootPaths
    private let stagingGrace: Duration
    private let flashDuration: Duration
    private let worktreeRetryInterval: Duration
    private let worktreeRetryAttempts: Int
    private let now: @MainActor () -> Date

    // MARK: - Tab state echo

    private(set) var tabID: UUID?
    private(set) var panel = AgentUtilityPanelTabState()

    private var rootInputs: AgentChangesPanelRootInputs = .empty

    /// Logical root paths where the user chose the workspace checkout over an unavailable worktree,
    /// per tab.
    ///
    /// Kept here rather than in `AgentUtilityPanelTabState` deliberately: it is a decision about a
    /// *checkout that is currently broken*, not about how the user wants to read a repository, and
    /// it must not outlive the window that asked the question. It is sticky for the window's life
    /// so the warning chip that comes with it stays honest.
    private var workspaceCheckoutOverridesByTab: [UUID: Set<String>] = [:]

    // MARK: - Bookkeeping

    private struct PatchRequestKey: Equatable {
        let rowID: String
        let targetKey: String
        let compareKey: String
        let fingerprintKey: String
        /// Content revision the row carried. This is the repository's own patch-cache invalidation
        /// signal, so reusing it here means the two layers cannot disagree about staleness.
        let contentRevision: UInt64
        let contextLevel: AgentChangesContextLevel
    }

    private var loadedPatchKeys: [String: PatchRequestKey] = [:]
    private var activeTargetKey: String?
    private var baseBranchCheckoutID: String?
    private var lastReconciledRepoRoot: String?
    private var didAutoExpandForTarget = false
    private var rootInputsGeneration: UInt64 = 0
    private var baseBranchGeneration: UInt64 = 0
    private var targetRequestID: UInt64 = 0
    private var expectedSnapshotTargetKey: String?
    private var expectedSnapshotMode: AgentChangesCompareMode = .workingTree
    private var activeRefreshID: UUID?

    private let artifactIndex = AgentSessionArtifactIndex()
    private var itemsCancellable: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var retargetTask: Task<Void, Never>?
    private var worktreeRetryTask: Task<Void, Never>?
    private var stagingGraceTasksByPath: [String: Task<Void, Never>] = [:]
    private var resolutionGraceTasksByPath: [String: Task<Void, Never>] = [:]
    private var customRevisionValidationID: UUID?
    private var workByID: [UUID: Task<Void, Never>] = [:]
    private var snapshotDeliveryWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Init

    init(
        environment: any AgentChangesPanelEnvironment,
        repository: AgentChangesRepository,
        watchedRootPaths: AgentChangesWatchedRootPaths = AgentChangesWatchedRootPaths(),
        probe: any AgentPanelCheckoutProbing = AgentPanelLiveCheckoutProbe(),
        scheduler: any AgentChangesScheduler = AgentChangesLiveScheduler(),
        stagingGrace: Duration = .milliseconds(300),
        flashDuration: Duration = .milliseconds(900),
        worktreeRetryInterval: Duration = .seconds(1),
        worktreeRetryAttempts: Int = 600,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.environment = environment
        self.repository = repository
        self.watchedRootPaths = watchedRootPaths
        self.probe = probe
        self.scheduler = scheduler
        self.stagingGrace = stagingGrace
        self.flashDuration = flashDuration
        self.worktreeRetryInterval = worktreeRetryInterval
        self.worktreeRetryAttempts = worktreeRetryAttempts
        self.now = now
        observeSnapshots()
    }

    /// The window's live panel controller.
    ///
    /// The trigger feed is assembled here because this is the only layer that knows both halves:
    /// the repository owns one checkout and cannot see the workspace, and the workspace store owns
    /// the watchers and cannot see which checkout is being reviewed.
    static func live(agentModeVM: AgentModeViewModel) -> AgentChangesPanelViewModel {
        let watchedRootPaths = AgentChangesWatchedRootPaths()
        let store = agentModeVM.promptManager?.workspaceFileContextStore
        let contentDeltas: @Sendable () -> AsyncStream<Set<String>> = store
            .map { AgentChangesTriggerSources.workspaceContentDeltas(store: $0) }
            ?? { AsyncStream { $0.finish() } }

        let repository = AgentChangesRepository(makeTriggerFeed: { checkout in
            AgentChangesLiveTriggerFeed(
                sources: AgentChangesTriggerSources(
                    metadataEvents: AgentChangesTriggerSources.metadataEvents(forCheckout: checkout.checkoutURL),
                    workspaceContentDeltas: contentDeltas,
                    reconcilePulses: AgentChangesTriggerSources.appActivationPulses()
                ),
                // A checkout inside a watched root is already reported by the workspace watcher.
                // An agent worktree parked outside every root is not, and without its own watch its
                // diff would freeze while the agent worked.
                scopedWatchPaths: watchedRootPaths.covers(checkout.checkoutURL) ? [] : [checkout.checkoutURL]
            )
        })

        return AgentChangesPanelViewModel(
            environment: AgentChangesPanelLiveEnvironment(agentModeVM: agentModeVM),
            repository: repository,
            watchedRootPaths: watchedRootPaths
        )
    }

    deinit {
        let repository = repository
        Task.detached { await repository.shutdown() }
    }

    /// Stops every stream this controller owns. Called when the panel leaves the window.
    func shutdown() {
        snapshotTask?.cancel()
        snapshotTask = nil
        retargetTask?.cancel()
        retargetTask = nil
        worktreeRetryTask?.cancel()
        worktreeRetryTask = nil
        itemsCancellable = nil
        for task in stagingGraceTasksByPath.values {
            task.cancel()
        }
        stagingGraceTasksByPath.removeAll()
        for task in resolutionGraceTasksByPath.values {
            task.cancel()
        }
        resolutionGraceTasksByPath.removeAll()
        customRevisionValidationID = nil
        resumeSnapshotDeliveryWaiters()
        let repository = repository
        Task { await repository.shutdown() }
    }

    // MARK: - Sync

    /// Applies the active tab's panel state.
    ///
    /// Called on every publish of the UI-store facade, so it must be cheap and idempotent: the
    /// expensive halves — re-reading workspace roots and re-resolving checkouts — run only on a tab
    /// change or an explicit request.
    func sync(tabID newTabID: UUID?, panel newPanel: AgentUtilityPanelTabState) {
        let tabChanged = newTabID != tabID
        if !tabChanged, panel != newPanel {
            objectWillChange.send()
        }
        tabID = newTabID
        panel = newPanel

        if tabChanged {
            resetForTabChange()
            // Clear the repository target immediately while the new tab's roots resolve. The
            // synchronous empty snapshot below prevents the previous tab's rows rendering under
            // the new header even for one frame.
            applyTargeting()
            observeTranscriptItems()
            reloadRootInputs()
            return
        }

        applyTargeting()
        refreshBannerLink()
    }

    private func resetForTabChange() {
        snapshot = .empty
        resumeSnapshotDeliveryWaiters()
        lastRefreshedAt = nil
        isRefreshing = false
        activeRefreshID = nil
        patchStates.removeAll()
        gapContextStates.removeAll()
        loadedPatchKeys.removeAll()
        pendingStagingByPath.removeAll()
        pendingBulkSections.removeAll()
        pendingResolutionByPath.removeAll()
        customRevisionEditor = nil
        customRevisionValidationID = nil
        flashedFileKeys.removeAll()
        statusMessage = nil
        baseBranchCandidates = []
        bannerLink = nil
        resolution = nil
        rootInputs = .empty
        activeTargetKey = nil
        baseBranchCheckoutID = nil
        lastReconciledRepoRoot = nil
        didAutoExpandForTarget = false
        artifactIndex.reset()
        for task in stagingGraceTasksByPath.values {
            task.cancel()
        }
        stagingGraceTasksByPath.removeAll()
        for task in resolutionGraceTasksByPath.values {
            task.cancel()
        }
        resolutionGraceTasksByPath.removeAll()
    }

    // MARK: - Targeting

    /// The checkout the panel is currently reading.
    var activeTarget: AgentPanelResolvedCheckout? {
        Self.activeTarget(in: resolution, rootOverride: panel.rootOverride, inputs: rootInputs)
    }

    /// Roots the panel could not read, for the header's blocked banners.
    var blockedCheckouts: [AgentPanelBlockedCheckout] {
        resolution?.blocked ?? []
    }

    var availableTargets: [AgentPanelResolvedCheckout] {
        resolution?.targets ?? []
    }

    /// The logical root identity a target is offered under in the root picker.
    func rootID(for target: AgentPanelResolvedCheckout) -> UUID? {
        target.logicalRoots.compactMap { rootInputs.rootID(forPath: $0.path) }.first
    }

    static func activeTarget(
        in resolution: AgentPanelCheckoutResolution?,
        rootOverride: UUID?,
        inputs: AgentChangesPanelRootInputs
    ) -> AgentPanelResolvedCheckout? {
        guard let resolution, !resolution.targets.isEmpty else { return nil }
        guard let rootOverride,
              let path = inputs.rootIDsByPath.first(where: { $0.value == rootOverride })?.key
        else { return resolution.targets.first }
        // An override naming a root that has since gone away falls back to the first readable
        // checkout rather than showing nothing: the root picker is a convenience, not a lock.
        return resolution.targets.first { target in
            target.logicalRoots.contains { $0.path == path }
        } ?? resolution.targets.first
    }

    @discardableResult
    private func reloadRootInputs() -> Task<Void, Never> {
        rootInputsGeneration &+= 1
        let generation = rootInputsGeneration
        let requestedTabID = tabID
        let overrides = requestedTabID.flatMap { workspaceCheckoutOverridesByTab[$0] } ?? []

        return trackedTask { [environment, probe] in
            let inputs = await environment.rootInputs(tabID: requestedTabID)
            guard self.isCurrent(generation: generation, tabID: requestedTabID) else { return }

            let request = AgentPanelCheckoutRequest(
                logicalRoots: inputs.logicalRoots,
                worktreeBindings: inputs.worktreeBindings,
                isPreparingWorktree: inputs.isPreparingWorktree,
                workspaceCheckoutOverrides: overrides
            )
            let resolved = await AgentPanelCheckoutResolver.resolve(request, probe: probe)
            guard self.isCurrent(generation: generation, tabID: requestedTabID) else { return }

            self.rootInputs = inputs
            self.resolution = resolved
            // Updated before retargeting, because the repository builds its trigger feed inside
            // `setTarget` and asks this box whether the checkout already has a watcher.
            self.watchedRootPaths.update(inputs.watchedRootPaths)
            self.applyTargeting()
            self.refreshBannerLink()
            self.scheduleWorktreeRetryIfNeeded()
        }
    }

    private func isCurrent(generation: UInt64, tabID requestedTabID: UUID?) -> Bool {
        generation == rootInputsGeneration && requestedTabID == tabID
    }

    private func applyTargeting() {
        let target = activeTarget
        reconcileBaseBranch(for: target)

        let mode = panel.resolvedCompareMode
        // vs-Base without a chosen base has no compare to build. Clearing the target is what makes
        // the panel ask for a base instead of quietly continuing to show working-tree rows under a
        // header that claims to be comparing against a branch.
        let effectiveTarget = mode == nil ? nil : target
        let key = effectiveTarget.map { "\($0.targetKey)\u{1F}\(String(describing: mode))" }

        if key != activeTargetKey {
            activeTargetKey = key
            patchStates.removeAll()
            gapContextStates.removeAll()
            loadedPatchKeys.removeAll()
            flashedFileKeys.removeAll()
            statusMessage = nil
            didAutoExpandForTarget = false
        }

        // Keyed on the checkout alone rather than on the compare key: the base picker has to be
        // populated *before* a base is chosen, and a vs-Base selection with no base yet produces no
        // compare key at all. Loading branches off the key would leave the picker empty in exactly
        // the state whose whole purpose is to ask.
        if target?.id != baseBranchCheckoutID {
            baseBranchCheckoutID = target?.id
            customRevisionEditor = nil
            customRevisionValidationID = nil
            loadBaseBranchCandidates(for: target)
        }

        let repository = repository
        let resolvedMode = mode ?? .workingTree
        targetRequestID &+= 1
        let requestID = targetRequestID
        expectedSnapshotTargetKey = effectiveTarget?.targetKey
        expectedSnapshotMode = resolvedMode
        retargetTask = trackedTask {
            await repository.setTarget(
                effectiveTarget,
                mode: resolvedMode,
                requestID: requestID
            )
        }
        syncPatchLoads()
    }

    /// Keeps the chosen base scoped to the repository it was chosen for.
    ///
    /// A base branch is per tab, but a branch name only means something inside one repository, so
    /// switching the active repository re-reads this tab's repo-scoped memory: the base the user
    /// already picked for the new repository if there is one, and otherwise nothing at all. Nothing
    /// is ever inferred — an unremembered repository asks, exactly as decision row 1 requires — and
    /// a name is never carried across repositories where it may mean a different branch or none.
    private func reconcileBaseBranch(for target: AgentPanelResolvedCheckout?) {
        guard let target else { return }
        let repoRoot = target.repoRootURL.standardizedFileURL.path
        guard repoRoot != lastReconciledRepoRoot else { return }
        lastReconciledRepoRoot = repoRoot

        let remembered = environment.lastUsedBaseBranch(forRepoRoot: repoRoot, tabID: tabID)
        guard remembered != panel.baseBranchOverride else { return }
        environment.selectBaseBranch(remembered, forRepoRoot: repoRoot, tabID: tabID)
        panel.selectBaseBranch(remembered, forRepoRoot: repoRoot)
    }

    private func loadBaseBranchCandidates(for target: AgentPanelResolvedCheckout?) {
        baseBranchGeneration &+= 1
        let generation = baseBranchGeneration
        baseBranchCandidates = []
        guard let target else { return }
        track { [environment] in
            let branches = await environment.baseBranchCandidates(at: target.checkoutURL)
            guard generation == self.baseBranchGeneration else { return }
            self.baseBranchCandidates = branches
        }
    }

    /// Re-resolves while a bound worktree is still hydrating.
    ///
    /// The session records its preparing flag and its bindings as plain state with no publisher, so
    /// a blocked root learns it can retry by asking again. Bounded rather than endless: after the
    /// attempts run out the panel keeps its "preparing" card and the Refresh button, instead of
    /// polling a checkout that is never going to appear.
    private func scheduleWorktreeRetryIfNeeded() {
        guard resolution?.isPreparing == true else {
            worktreeRetryTask?.cancel()
            worktreeRetryTask = nil
            return
        }
        guard worktreeRetryTask == nil else { return }

        let interval = worktreeRetryInterval
        let attempts = worktreeRetryAttempts
        worktreeRetryTask = Task { [weak self, scheduler] in
            for _ in 0 ..< attempts {
                try? await scheduler.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard resolution?.isPreparing == true else {
                    worktreeRetryTask = nil
                    return
                }
                reloadRootInputs()
            }
            self?.worktreeRetryTask = nil
        }
    }

    // MARK: - Snapshots

    private func observeSnapshots() {
        let repository = repository
        snapshotTask = Task { [weak self] in
            for await next in await repository.snapshots() {
                guard let self else { return }
                apply(next)
            }
        }
    }

    private func apply(_ next: AgentChangesSnapshot) {
        guard next.target?.targetKey == expectedSnapshotTargetKey,
              next.mode == expectedSnapshotMode
        else { return }
        snapshot = next
        resumeSnapshotDeliveryWaiters()
        if case .ready = next.loadState {
            lastRefreshedAt = now()
        }
        autoExpandFirstFileIfNeeded()
        syncPatchLoads()
        refreshBannerLink()
    }

    var filterCounts: AgentChangesFilterCounts {
        AgentChangesFiltering.counts(in: snapshot.sections)
    }

    var showsFilterPills: Bool {
        panel.compareSelection == .workingTree && snapshot.supportsStaging
    }

    var availableFilters: [AgentChangesFilter] {
        var filters: [AgentChangesFilter] = [.all, .staged, .unstaged]
        if filterCounts.conflicts > 0 { filters.append(.conflicts) }
        return filters
    }

    var activeFilter: AgentChangesFilter {
        availableFilters.contains(panel.changesFilter) ? panel.changesFilter : .all
    }

    /// Sections worth drawing, in design order and without changing their repository membership.
    var visibleSections: [AgentChangesSection] {
        guard showsFilterPills else { return snapshot.sections.filter { !$0.isEmpty } }
        return AgentChangesFiltering.sections(from: snapshot.sections, filter: activeFilter)
    }

    var filteredEmptyMessage: String? {
        guard showsFilterPills, activeFilter != .all, visibleSections.isEmpty else { return nil }
        return "No \(activeFilter.title.lowercased()) files"
    }

    func selectFilter(_ filter: AgentChangesFilter) {
        guard filter != panel.changesFilter, availableFilters.contains(filter) else { return }
        objectWillChange.send()
        environment.setChangesFilter(filter, tabID: tabID)
        panel.setChangesFilter(filter)
    }

    // MARK: - Expansion and Viewed

    func isExpanded(_ row: AgentChangesFileRow) -> Bool {
        panel.isExpanded(filePath: row.path)
    }

    func toggleExpansion(_ row: AgentChangesFileRow) {
        setExpansion(!isExpanded(row), for: row)
    }

    func setExpansion(_ isExpanded: Bool, for row: AgentChangesFileRow) {
        environment.setFileExpansion(isExpanded, filePath: row.path, tabID: tabID)
        panel.setExpansion(isExpanded, ofFilePath: row.path)
        syncPatchLoads()
    }

    private var viewedCompareTargetKey: String? {
        guard let target = activeTarget, let mode = panel.resolvedCompareMode else { return nil }
        let compare = switch mode {
        case .workingTree:
            "workingTree"
        case let .vsBase(base):
            "vsBase:\(base)"
        }
        return "\(target.targetKey)\u{1F}\(compare)"
    }

    func viewedStatus(for row: AgentChangesFileRow) -> AgentChangesViewedStatus {
        guard let viewedCompareTargetKey else { return .notViewed }
        return panel.viewedStatus(for: row.viewedRevision, compareTargetKey: viewedCompareTargetKey)
    }

    func isViewed(_ row: AgentChangesFileRow) -> Bool {
        viewedStatus(for: row) == .viewed
    }

    var viewedProgress: AgentChangesViewedProgress {
        AgentChangesViewedProgress.compute(sections: snapshot.sections, isViewed: isViewed)
    }

    func setViewed(_ viewed: Bool, for row: AgentChangesFileRow) {
        guard let viewedCompareTargetKey else { return }
        objectWillChange.send()
        let collapsePath = viewed && isExpanded(row) ? row.path : nil
        environment.setFileViewed(
            viewed,
            revision: row.viewedRevision,
            compareTargetKey: viewedCompareTargetKey,
            collapseFilePath: collapsePath,
            tabID: tabID
        )
        panel.setViewed(viewed, revision: row.viewedRevision, compareTargetKey: viewedCompareTargetKey)
        if let collapsePath {
            panel.setExpansion(false, ofFilePath: collapsePath)
            syncPatchLoads()
        }
    }

    func contextLevel(for row: AgentChangesFileRow) -> AgentChangesContextLevel {
        panel.contextLevel(forFilePath: row.path)
    }

    /// Widens one file's diff by a step and re-fetches it at that width.
    func escalateContext(for row: AgentChangesFileRow) {
        environment.escalateContext(filePath: row.path, tabID: tabID)
        panel.escalateContext(forFilePath: row.path)
        syncPatchLoads()
    }

    func patchState(for row: AgentChangesFileRow) -> AgentChangesPatchLoadState {
        patchStates[row.id] ?? .idle
    }

    /// The first file of the first non-empty section opens itself.
    ///
    /// Once per target only, and never against a tab that already expanded something: re-expanding
    /// after the user collapsed everything would fight them on every refresh.
    private func autoExpandFirstFileIfNeeded() {
        guard !didAutoExpandForTarget, case .ready = snapshot.loadState else { return }
        guard let first = visibleSections.first?.rows.first else { return }
        didAutoExpandForTarget = true
        guard panel.expandedFilePaths.isEmpty else { return }
        environment.setFileExpansion(true, filePath: first.path, tabID: tabID)
        panel.setExpansion(true, ofFilePath: first.path)
    }

    private func syncPatchLoads() {
        let rows = snapshot.sections.flatMap(\.rows)
        let expandedRows = rows.filter { panel.isExpanded(filePath: $0.path) }
        let expandedIDs = Set(expandedRows.map(\.id))

        for id in patchStates.keys where !expandedIDs.contains(id) {
            patchStates.removeValue(forKey: id)
            gapContextStates.removeValue(forKey: id)
            loadedPatchKeys.removeValue(forKey: id)
        }

        for row in expandedRows {
            let level = panel.contextLevel(forFilePath: row.path)
            guard let targetKey = snapshot.target?.targetKey else { continue }
            let key = PatchRequestKey(
                rowID: row.id,
                targetKey: targetKey,
                compareKey: row.section.compareSpec(mode: snapshot.mode).rawKey,
                fingerprintKey: snapshot.fingerprintKey,
                contentRevision: row.contentRevision,
                contextLevel: level
            )
            guard loadedPatchKeys[row.id] != key else { continue }
            loadedPatchKeys[row.id] = key
            patchStates[row.id] = .loading
            let repository = repository
            track {
                let state = await repository.patch(for: row, contextLevel: level)
                // A retarget, a collapse, or a newer revision arriving mid-read makes this answer
                // describe a file nobody is looking at any more.
                guard self.loadedPatchKeys[row.id] == key else { return }
                self.patchStates[row.id] = state
                if case let .loaded(document) = state {
                    let side = AgentChangesContextSourceResolver.selection(
                        for: row,
                        document: document,
                        mode: self.snapshot.mode,
                        hasHeadCommit: self.snapshot.hasHeadCommit
                    )?.side ?? .new
                    self.gapContextStates[row.id] = GapContextState(sourceSide: side)
                } else {
                    self.gapContextStates.removeValue(forKey: row.id)
                }
            }
        }
    }

    func gapContextState(for row: AgentChangesFileRow) -> GapContextState {
        gapContextStates[row.id] ?? GapContextState()
    }

    func expandContextGap(
        _ gap: DiffContextSplicer.Gap,
        amount: DiffContextSplicer.ExpansionAmount,
        for row: AgentChangesFileRow
    ) {
        guard case let .loaded(document) = patchState(for: row) else { return }
        var state = gapContextState(for: row)
        guard state.loadingGapID == nil else { return }
        state.loadingGapID = gap.id
        state.unavailableReason = nil
        gapContextStates[row.id] = state

        let requestKey = loadedPatchKeys[row.id]
        let repository = repository
        track {
            let outcome = await repository.expandContextGap(
                for: row,
                in: document,
                gapID: gap.id,
                amount: amount
            )
            guard self.loadedPatchKeys[row.id] == requestKey else { return }

            var current = self.gapContextState(for: row)
            current.loadingGapID = nil
            switch outcome {
            case let .expanded(expanded, sourceLineCount, sourceSide):
                current.sourceLineCount = sourceLineCount
                current.sourceSide = sourceSide
                current.unavailableReason = nil
                self.patchStates[row.id] = .loaded(expanded)
            case let .unavailable(reason):
                current.unavailableReason = reason
            }
            self.gapContextStates[row.id] = current
        }
    }

    // MARK: - Staging

    /// The checkbox state a row should draw: what the user asked for while a mutation is in flight,
    /// and what Git says otherwise. Never an optimistic section move.
    func isStagedForDisplay(_ row: AgentChangesFileRow) -> Bool {
        pendingStagingByPath[row.identity.path]?.requestedStage ?? row.isStaged
    }

    func pendingStaging(for row: AgentChangesFileRow) -> PendingStaging? {
        pendingStagingByPath[row.identity.path]
    }

    /// Whether a row shows a checkbox at all.
    ///
    /// Conflicts get one even though they can never be staged: an absent control reads as "this
    /// file is not stageable yet", while a present, refused one with a tooltip says why. vs-Base
    /// and working-copy lists get none, because neither has an index behind them.
    func showsStagingCheckbox(for row: AgentChangesFileRow) -> Bool {
        guard snapshot.supportsStaging else { return false }
        return row.section.isStageable || row.section == .conflicts
    }

    /// Whether this row's checkbox is inert.
    ///
    /// Exactly three reasons, and no others: the row is conflicted, its own path is mid-mutation,
    /// or a bulk action that covers it is running. A mutation elsewhere in the list leaves every
    /// other row clickable.
    func isMutationDisabled(_ row: AgentChangesFileRow) -> Bool {
        if !row.isStageable { return true }
        if pendingStagingByPath[row.identity.path] != nil { return true }
        if pendingResolutionByPath[row.identity.path] != nil { return true }
        if pendingBulkSections.contains(row.section) { return true }
        // A partially-staged file is represented in both sections, so either section's bulk action
        // is about to rewrite this row.
        if row.hasCounterpartSection, !pendingBulkSections.isEmpty { return true }
        return false
    }

    /// Bulk actions overlap every single-file mutation in the same repository, so any in-flight
    /// staging disables them.
    func isBulkActionDisabled(for section: AgentChangesSectionKind) -> Bool {
        !pendingStagingByPath.isEmpty
            || !pendingResolutionByPath.isEmpty
            || !pendingBulkSections.isEmpty
            || !section.isStageable
            || snapshot.section(section)?.rows.contains(where: \.isStageable) != true
    }

    func isBulkActionPending(for section: AgentChangesSectionKind) -> Bool {
        pendingBulkSections.contains(section)
    }

    func setStaged(_ stage: Bool, row: AgentChangesFileRow) {
        guard snapshot.supportsStaging, row.isStageable else { return }
        let path = row.identity.path
        guard pendingStagingByPath[path] == nil, pendingResolutionByPath[path] == nil else { return }

        pendingStagingByPath[path] = PendingStaging(requestedStage: stage, showsSpinner: false)
        startStagingGrace(for: path)

        let repository = repository
        let request = AgentChangesMutationRequest(row: row, stage: stage)
        track {
            let outcome = await repository.applyMutation(request)
            self.stagingGraceTasksByPath.removeValue(forKey: path)?.cancel()
            self.pendingStagingByPath.removeValue(forKey: path)
            self.handle(outcome: outcome, fileName: row.path, fileKey: row.fileKey)
        }
    }

    func applyBulkStaging(_ stage: Bool, section: AgentChangesSectionKind) {
        guard snapshot.supportsStaging, section.isStageable else { return }
        guard pendingResolutionByPath.isEmpty, !pendingBulkSections.contains(section) else { return }
        pendingBulkSections.insert(section)

        let repository = repository
        let reviewedRows = snapshot.section(section)?.rows.filter(\.isStageable) ?? []
        let request = AgentChangesBulkMutationRequest(
            section: section,
            stage: stage,
            rows: reviewedRows
        )
        track {
            let outcome = await repository.applyBulkMutation(request)
            self.pendingBulkSections.remove(section)
            self.handle(outcome: outcome, fileName: nil, fileKey: nil)
        }
    }

    func pendingResolution(for row: AgentChangesFileRow) -> PendingResolution? {
        pendingResolutionByPath[row.identity.path]
    }

    func markResolvedDisabledReason(for row: AgentChangesFileRow) -> String? {
        guard row.isConflicted else { return "Only conflicted files can be marked resolved." }
        guard activeTarget != nil, snapshot.target != nil else {
            return "The selected checkout is unavailable."
        }
        guard snapshot.supportsStaging else {
            return "This repository has no staging area, so conflicts cannot be marked resolved here."
        }
        if pendingResolutionByPath[row.identity.path] != nil {
            return "This conflict is already being marked resolved."
        }
        if pendingStagingByPath[row.identity.path] != nil || !pendingBulkSections.isEmpty {
            return "Wait for the overlapping index operation to finish."
        }
        return nil
    }

    func markResolved(_ row: AgentChangesFileRow) {
        guard markResolvedDisabledReason(for: row) == nil else { return }
        let path = row.identity.path
        pendingResolutionByPath[path] = PendingResolution(showsSpinner: false)
        startResolutionGrace(for: path)

        let repository = repository
        let request = AgentChangesResolveRequest(row: row)
        track {
            let outcome = await repository.markResolved(request)
            self.resolutionGraceTasksByPath.removeValue(forKey: path)?.cancel()
            self.pendingResolutionByPath.removeValue(forKey: path)
            self.handleResolution(outcome: outcome, row: row)
        }
    }

    /// Deliberately untracked: the grace timer is cosmetic and outlives nothing. Folding it into
    /// the work set would make "has this controller finished?" depend on a delay whose entire
    /// purpose is to still be running while the real work is.
    private func startStagingGrace(for path: String) {
        let grace = stagingGrace
        stagingGraceTasksByPath[path] = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: grace)
            guard !Task.isCancelled, let self, var pending = pendingStagingByPath[path] else { return }
            pending.showsSpinner = true
            pendingStagingByPath[path] = pending
        }
    }

    private func startResolutionGrace(for path: String) {
        let grace = stagingGrace
        resolutionGraceTasksByPath[path] = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: grace)
            guard !Task.isCancelled, let self, var pending = pendingResolutionByPath[path] else { return }
            pending.showsSpinner = true
            pendingResolutionByPath[path] = pending
        }
    }

    private func handleResolution(outcome: AgentChangesMutationOutcome, row: AgentChangesFileRow) {
        switch outcome {
        case .applied, .noOp:
            statusMessage = nil
        case .contentChanged:
            flash(fileKey: row.fileKey)
            let name = (row.path as NSString).lastPathComponent
            statusMessage = .info("\(name) changed on disk — refreshed instead of marking unreviewed contents resolved.")
        case .unsupported:
            statusMessage = .failure("This repository cannot mark conflicts resolved from the Changes panel.")
        case .conflicted:
            statusMessage = .failure("The conflict is still unresolved.")
        case let .failed(message):
            statusMessage = .failure(message)
        }
    }

    private func handle(outcome: AgentChangesMutationOutcome, fileName: String?, fileKey: String?) {
        switch outcome {
        case .applied, .noOp:
            statusMessage = nil
        case .contentChanged:
            // The repository already forced a rebuild; the flash is what tells the user their click
            // did something, and why the row they clicked did not move.
            if let fileKey { flash(fileKey: fileKey) }
            let name = fileName.map { ($0 as NSString).lastPathComponent } ?? "The file"
            statusMessage = .info("\(name) changed on disk — refreshed instead of staging unreviewed content.")
        case .conflicted:
            statusMessage = .failure("Conflicted files cannot be staged from this panel.")
        case .unsupported:
            statusMessage = .failure("This repository has no staging area.")
        case let .failed(message):
            statusMessage = .failure(message)
        }
    }

    /// Untracked for the same reason as the staging grace: a highlight that fades on its own is not
    /// work anything should wait for.
    private func flash(fileKey: String) {
        flashedFileKeys.insert(fileKey)
        let duration = flashDuration
        Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: duration)
            self?.flashedFileKeys.remove(fileKey)
        }
    }

    func isFlashing(_ row: AgentChangesFileRow) -> Bool {
        flashedFileKeys.contains(row.fileKey)
    }

    func dismissStatusMessage() {
        statusMessage = nil
    }

    // MARK: - Header actions

    func selectDiffViewMode(_ mode: AgentChangesDiffViewMode) {
        guard mode != panel.diffViewMode else { return }
        objectWillChange.send()
        environment.setDiffViewMode(mode, tabID: tabID)
        panel.setDiffViewMode(mode)
    }

    func selectCompare(_ selection: AgentChangesCompareSelection) {
        guard selection != panel.compareSelection else { return }
        if selection != .vsBase {
            customRevisionEditor = nil
            customRevisionValidationID = nil
        }
        environment.setCompareSelection(selection, tabID: tabID)
        panel.setCompareSelection(selection)
        applyTargeting()
    }

    func selectBaseBranch(_ branch: String) {
        guard let target = activeTarget else { return }
        customRevisionEditor = nil
        customRevisionValidationID = nil
        let repoRoot = target.repoRootURL.standardizedFileURL.path
        environment.selectBaseBranch(branch, forRepoRoot: repoRoot, tabID: tabID)
        panel.selectBaseBranch(branch, forRepoRoot: repoRoot)
        lastReconciledRepoRoot = repoRoot
        applyTargeting()
    }

    func beginCustomRevisionEntry() {
        guard panel.compareSelection == .vsBase, activeTarget != nil else { return }
        customRevisionValidationID = nil
        customRevisionEditor = CustomRevisionEditor(
            text: panel.baseBranchOverride ?? "",
            state: .editing
        )
    }

    func updateCustomRevisionText(_ text: String) {
        guard customRevisionEditor != nil else { return }
        customRevisionValidationID = nil
        customRevisionEditor = CustomRevisionEditor(text: text, state: .editing)
    }

    func cancelCustomRevisionEntry() {
        customRevisionValidationID = nil
        customRevisionEditor = nil
    }

    func submitCustomRevision() {
        guard var editor = customRevisionEditor, let target = activeTarget else { return }
        let revision = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            editor.state = .error("Enter a revision such as a tag, SHA, HEAD~3, or origin/main.")
            customRevisionEditor = editor
            return
        }

        let validationID = UUID()
        let requestedTabID = tabID
        let requestedTargetID = target.id
        customRevisionValidationID = validationID
        editor.state = .validating
        customRevisionEditor = editor

        let repository = repository
        track {
            let validation = await repository.validateRevision(revision, at: target)
            guard self.customRevisionValidationID == validationID,
                  self.tabID == requestedTabID,
                  self.activeTarget?.id == requestedTargetID
            else { return }

            switch validation {
            case .valid:
                self.customRevisionValidationID = nil
                self.customRevisionEditor = nil
                self.selectBaseBranch(revision)
            case .invalid, .ambiguous, .failed:
                var current = self.customRevisionEditor ?? CustomRevisionEditor(
                    text: revision,
                    state: .editing
                )
                current.state = .error(validation.errorMessage ?? "Revision could not be resolved.")
                self.customRevisionEditor = current
            }
        }
    }

    func selectRoot(_ target: AgentPanelResolvedCheckout) {
        let rootID = rootID(for: target)
        environment.selectRootOverride(rootID, tabID: tabID)
        panel.selectRootOverride(rootID)
        applyTargeting()
    }

    /// Substitutes the workspace checkout for a worktree that cannot be read.
    ///
    /// Only ever reached from an explicit action on the blocked card — decision row 5 forbids the
    /// panel from making this substitution on its own, because a staging surface pointed at the
    /// wrong working tree stages the user's own edits as if they were the agent's.
    func showWorkspaceCheckoutInstead(for blocked: AgentPanelBlockedCheckout) {
        guard blocked.reason.allowsWorkspaceCheckoutOverride, let tabID else { return }
        var overrides = workspaceCheckoutOverridesByTab[tabID] ?? []
        overrides.insert(blocked.logicalRoot.path)
        workspaceCheckoutOverridesByTab[tabID] = overrides
        reloadRootInputs()
    }

    /// Whether the active checkout is standing in for a worktree the user opted out of, which the
    /// header marks with a persistent warning chip.
    var isSubstitutingWorkspaceCheckout: Bool {
        activeTarget?.substitutesUnavailableWorktree == true
    }

    // MARK: - Refresh

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let refreshID = UUID()
        activeRefreshID = refreshID

        // Re-resolving as well as re-reading is deliberate: the most common reason a user reaches
        // for Refresh is that a worktree or root changed underneath the panel. The spinner belongs
        // to the complete chain, including the retarget produced by that resolve.
        let reloadTask = reloadRootInputs()
        let repository = repository
        track {
            _ = await reloadTask.value
            _ = await self.retargetTask?.value
            guard self.activeRefreshID == refreshID else { return }

            await repository.refresh(.manual)
            await repository.waitUntilIdle()
            guard self.activeRefreshID == refreshID else { return }
            self.activeRefreshID = nil
            self.isRefreshing = false
        }
    }

    // MARK: - Empty state

    var emptyState: AgentChangesEmptyState? {
        AgentChangesEmptyState.resolve(
            resolution: resolution,
            snapshot: snapshot,
            compareSelection: panel.compareSelection,
            hasResolvedCompare: panel.resolvedCompareMode != nil
        )
    }

    /// The decision-row-1 bridge from a clean working tree into vs-Base.
    func offerBaseComparison() {
        selectCompare(.vsBase)
    }

    // MARK: - Artifact banner

    private func observeTranscriptItems() {
        itemsCancellable = nil
        artifactIndex.ingest(environment.transcriptItems(tabID: tabID))
        refreshBannerLink()
        itemsCancellable = environment.transcriptItemsPublisher(tabID: tabID)?
            .sink { [weak self] items in
                guard let self else { return }
                artifactIndex.ingest(items)
                refreshBannerLink()
            }
    }

    /// Resolves the newest undismissed artifact into something Preview can actually open.
    ///
    /// An artifact whose path lies outside every known root produces no banner at all rather than a
    /// banner whose only action fails: the panel does not offer to open documents it cannot address.
    private func refreshBannerLink() {
        guard let artifact = artifactIndex.newestArtifact(
            excludingDismissed: panel.dismissedBannerArtifactIDs
        ) else {
            bannerLink = nil
            return
        }
        guard let document = AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: artifact.path,
            checkout: activeTarget,
            logicalRoots: rootInputs.logicalRoots,
            rootIDsByPath: rootInputs.rootIDsByPath
        ) else {
            bannerLink = nil
            return
        }
        let link = ArtifactBannerLink(artifact: artifact, document: document)
        guard link != bannerLink else { return }
        bannerLink = link
    }

    /// Opens the banner's document in Preview.
    ///
    /// Coordination with the Preview segment happens entirely through tab state: this writes the
    /// document reference and the segment, and the Preview view renders whatever it finds there.
    func viewBannerArtifact() {
        guard let link = bannerLink else { return }
        environment.showPreview(of: link.document, tabID: tabID)
        panel.showPreview(of: link.document)
    }

    func dismissBannerArtifact() {
        guard let link = bannerLink else { return }
        environment.dismissBanner(artifactID: link.artifact.id, tabID: tabID)
        panel.dismissBanner(artifactID: link.artifact.id)
        refreshBannerLink()
    }

    // MARK: - Work tracking

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        _ = trackedTask(operation)
    }

    @discardableResult
    private func trackedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.workByID.removeValue(forKey: id)
        }
        workByID[id] = task
        return task
    }

    /// Waits until every task this controller started, and every rebuild it caused, has finished.
    ///
    /// Exists for tests and diagnostics: the panel's work is a chain — resolve, retarget, rebuild,
    /// patch load — and asserting on any link of it without a way to wait would mean polling.
    func settle() async {
        var passes = 0
        repeat {
            passes += 1
            for task in Array(workByID.values) {
                _ = await task.value
            }
            await repository.waitUntilIdle()
            await drainSnapshotDelivery()
        } while !workByID.isEmpty && passes < Self.maximumSettlePasses
    }

    /// Waits for the published snapshot to catch up with the repository's own.
    ///
    /// Snapshots arrive through a long-lived stream rather than through the tracked work set. A
    /// scheduler yield is not a delivery acknowledgement: under load, a bounded yield loop can
    /// return with the repository ready while this controller still holds its initial empty
    /// snapshot. Wait for the consumer itself to signal progress instead.
    private func drainSnapshotDelivery() async {
        while true {
            let current = await repository.currentSnapshot()
            guard snapshot != current else { return }
            await withCheckedContinuation { continuation in
                snapshotDeliveryWaiters.append(continuation)
            }
        }
    }

    private func resumeSnapshotDeliveryWaiters() {
        let waiters = snapshotDeliveryWaiters
        snapshotDeliveryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static let maximumSettlePasses = 32
}
