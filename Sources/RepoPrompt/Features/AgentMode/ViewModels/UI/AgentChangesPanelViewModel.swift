import Combine
import Foundation

/// A cancellation-aware view-model-wide gate for repository search reads.
///
/// Search generations can overlap while an actor finishes a cancelled read. Keeping permits outside
/// those generations makes the four-read ceiling global rather than merely four per batch.
///
/// The only bookkeeping is the live one: held permits and registered waiters. A cancellation cannot
/// arrive before the acquiring call has classified its own permit, because `cancel(id:)` is reachable
/// only from the handler installed *inside* `acquire`, and that handler's task must still take this
/// actor — which `acquire` holds without suspending until the permit is held, queued, or refused. A
/// cancellation for an unknown ID is therefore always a late one for an already-settled permit, and
/// recording it would grow a set that nothing could ever drain.
actor AgentChangesSearchReadLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []
    private var activePermitIDs: Set<UUID> = []

    init(limit: Int) {
        self.limit = limit
        available = limit
    }

    /// Permits and waiters this limiter is still tracking. Zero once every read has settled.
    var retainedPermitCount: Int {
        activePermitIDs.count + waiters.count
    }

    func acquire() async -> UUID? {
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            if available > 0 {
                available -= 1
                activePermitIDs.insert(id)
                return true
            }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        return acquired ? id : nil
    }

    func release(_ id: UUID) {
        guard activePermitIDs.remove(id) != nil else { return }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            activePermitIDs.insert(waiter.id)
            waiter.continuation.resume(returning: true)
            return
        }
        available = min(limit, available + 1)
    }

    /// Refuses a still-queued permit. Held and already-settled permits are left alone.
    func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

/// The Changes segment's controller: one per window, following whichever tab is active.
///
/// It owns four things the views must not own themselves.
///
/// **The repository pool.** Every resolved checkout in the active tab gets one single-checkout
/// AgentChangesRepository actor and one snapshot stream. A slot UUID fences late stream delivery,
/// while the full target key and expected compare mode fence stale retargets. The entire pool is
/// discarded on tab changes so background tabs retain no watchers or caches.
///
/// **The direction of writes.** Tab state is canonical in TabSession. Expansion, context, base, and
/// Viewed writes travel through the environment using checkout-qualified keys, then echo locally so
/// a click can start its lazy work before the next facade publication.
///
/// **What is in flight.** Patch loads, whole-file and partial mutations, selection tokens, grace
/// timers, and flashes survive SwiftUI row recreation here. Pending keys include the group, so an
/// index operation in one repository never disables an unrelated checkout.
///
/// **Search orchestration.** The view model freezes an ordered corpus from slot identities and
/// snapshots, debounces through the injected scheduler, admits at most four repository reads at a
/// time, and owns temporary search expansion separately from the user's tab expansion.
@MainActor
final class AgentChangesPanelViewModel: ObservableObject {
    // MARK: - Published state

    /// Ordered resolved-checkout state. Blocked entries remain in resolution.items at their logical
    /// root positions; callers join those items to this array by group ID.
    @Published private(set) var groups: [AgentChangesGroupState] = []

    @Published private(set) var resolution: AgentPanelCheckoutResolution?

    @Published private(set) var patchStates: [AgentChangesRowKey: AgentChangesPatchLoadState] = [:]
    @Published private(set) var gapContextStates: [AgentChangesRowKey: GapContextState] = [:]
    @Published private(set) var pendingStagingByPath: [AgentChangesGroupPathKey: PendingStaging] = [:]
    @Published private(set) var pendingBulkSections: [AgentChangesGroupID: Set<AgentChangesSectionKind>] = [:]
    @Published private(set) var pendingResolutionByPath: [AgentChangesGroupPathKey: PendingResolution] = [:]
    @Published private(set) var partialDescriptorsByRow: [
        AgentChangesRowKey: AgentChangesPartialStagingDescriptor
    ] = [:]
    @Published private(set) var partialSelectionsByHunk: [
        PartialSelectionKey: Set<AgentChangesDiffLineKey>
    ] = [:]
    @Published private(set) var pendingPartialByPath: [
        AgentChangesGroupPathKey: PendingPartialMutation
    ] = [:]
    @Published private(set) var customRevisionEditor: CustomRevisionEditor?
    @Published private(set) var flashedFileKeys: Set<AgentChangesFileStateKey> = []
    @Published private(set) var statusMessage: StatusMessage?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false

    @Published private(set) var bannerLink: ArtifactBannerLink?

    /// Publishing rebuilds the per-row match buckets so an expanded file's thousands of rendered
    /// lines each cost one dictionary lookup instead of a linear scan of the whole match set.
    @Published private(set) var searchState: AgentChangesSearchState = .idle {
        didSet { rebuildSearchMatchIndex() }
    }

    @Published private(set) var searchExpandedFiles: Set<AgentChangesFileStateKey> = []
    @Published private(set) var searchNavigationAnchor: SearchNavigationAnchor?

    // MARK: - Value types

    struct PendingStaging: Equatable {
        let requestedStage: Bool
        var showsSpinner: Bool
    }

    struct PendingResolution: Equatable {
        var showsSpinner: Bool
    }

    struct PendingPartialMutation: Equatable {
        enum SelectionKind: Equatable {
            case hunk
            case lines(count: Int)
        }

        let initiatingRowID: String
        let action: AgentChangesPartialAction
        let selectionKind: SelectionKind
        var showsSpinner: Bool
        let reviewToken: AgentChangesPatchReviewToken
    }

    struct PartialSelectionKey: Equatable, Hashable {
        let rowKey: AgentChangesRowKey
        let reviewToken: AgentChangesPatchReviewToken
        let projectedHunkID: String
    }

    struct CustomRevisionEditor: Equatable {
        enum State: Equatable {
            case editing
            case validating
            case error(String)
        }

        let groupID: AgentChangesGroupID
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

    struct FooterSummary: Equatable {
        let fileCount: Int
        let additions: Int
        let deletions: Int
        let isPollingDegraded: Bool
        let lastRefreshedAt: Date?
    }

    struct SearchNavigationAnchor: Equatable {
        let matchID: AgentChangesSearchMatch.ID
        let rowKey: AgentChangesRowKey
        let locator: AgentChangesSearchLocator
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
    private let repositoryFactory: () -> AgentChangesRepository
    private let probe: any AgentPanelCheckoutProbing
    private let scheduler: any AgentChangesScheduler
    private let watchedRootPaths: AgentChangesWatchedRootPaths
    private let stagingGrace: Duration
    private let flashDuration: Duration
    private let searchDebounce: Duration
    private let searchBudget: AgentChangesSearchBudget
    private let worktreeRetryInterval: Duration
    private let worktreeRetryAttempts: Int
    private let now: @MainActor () -> Date

    // MARK: - Tab state echo

    private(set) var tabID: UUID?
    private(set) var panel = AgentUtilityPanelTabState()
    private var rootInputs: AgentChangesPanelRootInputs = .empty
    private var workspaceCheckoutOverridesByTab: [UUID: Set<String>] = [:]

    // MARK: - Repository slots

    @MainActor
    private final class RepositorySlot {
        let id = UUID()
        let target: AgentPanelResolvedCheckout
        let repository: AgentChangesRepository
        nonisolated let mutationLeases = AgentChangesIndexMutationLeaseSlot()
        var expectedMode: AgentChangesCompareMode = .workingTree
        var expectedTargetKey: String?
        var isTargeted = false
        var targetingKey: String?
        var targetRequestID: UInt64 = 0
        var snapshot: AgentChangesSnapshot = .empty
        var baseCandidates: [String] = []
        var lastRefreshedAt: Date?
        var observationTask: Task<Void, Never>?
        var retargetTask: Task<Void, Never>?

        init(target: AgentPanelResolvedCheckout, repository: AgentChangesRepository) {
            self.target = target
            self.repository = repository
        }
    }

    private struct PatchRequestKey: Equatable {
        let slotID: UUID
        let targetRequestID: UInt64
        let rowID: String
        let targetKey: String
        let compareKey: String
        let fingerprintKey: String
        let contentRevision: UInt64
        let contextLevel: AgentChangesContextLevel
    }

    private struct SlotOperationFence {
        let lifecycleGeneration: UInt64
        let tabID: UUID?
        let groupID: AgentChangesGroupID
        let slotID: UUID
        let targetRequestID: UInt64
    }

    private struct SearchCorpusKey: Equatable {
        let value: String
    }

    private struct SearchCorpusItem: @unchecked Sendable {
        let rowKey: AgentChangesRowKey
        let groupOrder: Int
        let sectionOrder: Int
        let rowOrder: Int
        let row: AgentChangesFileRow
        let repository: AgentChangesRepository
    }

    private struct SearchLoadResult: @unchecked Sendable {
        let item: SearchCorpusItem
        let document: AgentChangesSearchPatchDocument
    }

    /// One row's published matches, kept in corpus order and bucketed by rendered element.
    private struct RowSearchMatches {
        var all: [AgentChangesSearchMatch] = []
        var byLocatorKey: [String: [AgentChangesSearchMatch]] = [:]
    }

    private var slots: [AgentChangesGroupID: RepositorySlot] = [:]
    private var loadedPatchKeys: [AgentChangesRowKey: PatchRequestKey] = [:]
    private var didAutoExpandGroups: Set<AgentChangesGroupID> = []
    private var rootInputsGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeRefreshID: UUID?

    private let artifactIndex = AgentSessionArtifactIndex()
    private var itemsCancellable: AnyCancellable?
    private var worktreeRetryTask: Task<Void, Never>?
    private var stagingGraceTasksByPath: [
        AgentChangesGroupPathKey: Task<Void, Never>
    ] = [:]
    private var resolutionGraceTasksByPath: [
        AgentChangesGroupPathKey: Task<Void, Never>
    ] = [:]
    private var partialGraceTasksByPath: [
        AgentChangesGroupPathKey: Task<Void, Never>
    ] = [:]
    private var customRevisionValidationID: UUID?
    private var statusMessageGroupID: AgentChangesGroupID?
    private var flashIDsByFileKey: [AgentChangesFileStateKey: UUID] = [:]
    private var workByID: [UUID: Task<Void, Never>] = [:]
    private var snapshotDeliveryWaiters: [CheckedContinuation<Void, Never>] = []

    private let searchReadLimiter = AgentChangesSearchReadLimiter(limit: 4)
    private var searchMatchIndex: [AgentChangesRowKey: RowSearchMatches] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var activeSearchCorpusKey: SearchCorpusKey?
    private var pendingNavigationMatchID: AgentChangesSearchMatch.ID?

    // MARK: - Init

    init(
        environment: any AgentChangesPanelEnvironment,
        repositoryFactory: @escaping () -> AgentChangesRepository,
        watchedRootPaths: AgentChangesWatchedRootPaths = AgentChangesWatchedRootPaths(),
        probe: any AgentPanelCheckoutProbing = AgentPanelLiveCheckoutProbe(),
        scheduler: any AgentChangesScheduler = AgentChangesLiveScheduler(),
        stagingGrace: Duration = .milliseconds(300),
        flashDuration: Duration = .milliseconds(900),
        searchDebounce: Duration = .milliseconds(150),
        searchBudget: AgentChangesSearchBudget = .standard,
        worktreeRetryInterval: Duration = .seconds(1),
        worktreeRetryAttempts: Int = 600,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.environment = environment
        self.repositoryFactory = repositoryFactory
        self.watchedRootPaths = watchedRootPaths
        self.probe = probe
        self.scheduler = scheduler
        self.stagingGrace = stagingGrace
        self.flashDuration = flashDuration
        self.searchDebounce = searchDebounce
        self.searchBudget = searchBudget
        self.worktreeRetryInterval = worktreeRetryInterval
        self.worktreeRetryAttempts = worktreeRetryAttempts
        self.now = now
    }

    static func live(agentModeVM: AgentModeViewModel) -> AgentChangesPanelViewModel {
        let watchedRootPaths = AgentChangesWatchedRootPaths()
        let store = agentModeVM.promptManager?.workspaceFileContextStore
        let contentDeltas: @Sendable () -> AsyncStream<Set<String>> = store
            .map { AgentChangesTriggerSources.workspaceContentDeltas(store: $0) }
            ?? { AsyncStream { $0.finish() } }

        return AgentChangesPanelViewModel(
            environment: AgentChangesPanelLiveEnvironment(agentModeVM: agentModeVM),
            repositoryFactory: {
                AgentChangesRepository(makeTriggerFeed: { checkout in
                    AgentChangesLiveTriggerFeed(
                        sources: AgentChangesTriggerSources(
                            metadataEvents: AgentChangesTriggerSources.metadataEvents(
                                forCheckout: checkout.checkoutURL
                            ),
                            workspaceContentDeltas: contentDeltas,
                            reconcilePulses: AgentChangesTriggerSources.appActivationPulses()
                        ),
                        scopedWatchPaths: watchedRootPaths.covers(checkout.checkoutURL)
                            ? []
                            : [checkout.checkoutURL]
                    )
                })
            },
            watchedRootPaths: watchedRootPaths
        )
    }

    deinit {
        let currentSlots = Array(slots.values)
        currentSlots.forEach { $0.mutationLeases.revoke() }
        let repositories = currentSlots.map(\.repository)
        Task.detached {
            for repository in repositories {
                await repository.shutdown()
            }
        }
    }

    /// Stops every stream, slot actor, timer, and search generation this controller owns.
    func shutdown() {
        lifecycleGeneration &+= 1
        rootInputsGeneration &+= 1
        worktreeRetryTask?.cancel()
        worktreeRetryTask = nil
        itemsCancellable = nil
        cancelCosmeticTasks()
        cancelSearch(clearState: true)
        customRevisionValidationID = nil
        let removed = Array(slots.values)
        removed.forEach { $0.mutationLeases.revoke() }
        slots.removeAll()
        groups = []
        lastRefreshedAt = nil
        resumeSnapshotDeliveryWaiters()
        for slot in removed {
            slot.observationTask?.cancel()
            slot.retargetTask?.cancel()
            track { await slot.repository.shutdown() }
        }
    }

    // MARK: - Sync

    func sync(tabID newTabID: UUID?, panel newPanel: AgentUtilityPanelTabState) {
        let tabChanged = newTabID != tabID
        if !tabChanged, panel != newPanel {
            objectWillChange.send()
        }
        tabID = newTabID
        panel = newPanel

        if tabChanged {
            resetForTabChange()
            observeTranscriptItems()
            reloadRootInputs()
            return
        }

        retargetSlots()
        refreshBannerLink()
    }

    private func resetForTabChange() {
        lifecycleGeneration &+= 1
        rootInputsGeneration &+= 1
        let removed = Array(slots.values)
        removed.forEach { $0.mutationLeases.revoke() }
        slots.removeAll()
        for slot in removed {
            slot.observationTask?.cancel()
            slot.retargetTask?.cancel()
            track { await slot.repository.shutdown() }
        }

        groups = []
        resolution = nil
        rootInputs = .empty
        lastRefreshedAt = nil
        isRefreshing = false
        activeRefreshID = nil
        patchStates.removeAll()
        gapContextStates.removeAll()
        loadedPatchKeys.removeAll()
        pendingStagingByPath.removeAll()
        pendingBulkSections.removeAll()
        pendingResolutionByPath.removeAll()
        partialDescriptorsByRow.removeAll()
        partialSelectionsByHunk.removeAll()
        pendingPartialByPath.removeAll()
        customRevisionEditor = nil
        customRevisionValidationID = nil
        flashedFileKeys.removeAll()
        flashIDsByFileKey.removeAll()
        statusMessage = nil
        statusMessageGroupID = nil
        bannerLink = nil
        didAutoExpandGroups.removeAll()
        artifactIndex.reset()
        cancelCosmeticTasks()
        cancelSearch(clearState: true)
        resumeSnapshotDeliveryWaiters()
    }

    private func cancelCosmeticTasks() {
        for task in stagingGraceTasksByPath.values {
            task.cancel()
        }
        stagingGraceTasksByPath.removeAll()
        for task in resolutionGraceTasksByPath.values {
            task.cancel()
        }
        resolutionGraceTasksByPath.removeAll()
        for task in partialGraceTasksByPath.values {
            task.cancel()
        }
        partialGraceTasksByPath.removeAll()
    }

    // MARK: - Resolution and slot reconciliation

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
            self.watchedRootPaths.update(inputs.watchedRootPaths)
            self.resolution = resolved
            self.reconcileSlots(with: resolved)
            self.refreshBannerLink()
            self.scheduleWorktreeRetryIfNeeded()
        }
    }

    private func isCurrent(generation: UInt64, tabID requestedTabID: UUID?) -> Bool {
        generation == rootInputsGeneration && requestedTabID == tabID
    }

    private func reconcileSlots(with resolved: AgentPanelCheckoutResolution) {
        let targets = resolved.items.compactMap { item -> AgentPanelResolvedCheckout? in
            guard case let .resolved(target) = item else { return nil }
            return target
        }
        let desiredIDs = Set(targets.map(AgentChangesGroupID.init(target:)))

        for groupID in Array(slots.keys) where !desiredIDs.contains(groupID) {
            guard let slot = slots[groupID] else { continue }
            slot.mutationLeases.revoke()
            slots.removeValue(forKey: groupID)
            removeUIState(for: groupID)
            slot.observationTask?.cancel()
            slot.retargetTask?.cancel()
            track { await slot.repository.shutdown() }
        }

        for target in targets {
            let groupID = AgentChangesGroupID(target: target)
            if let slot = slots[groupID], slot.target != target {
                slot.mutationLeases.revoke()
                slots.removeValue(forKey: groupID)
                removeUIState(for: groupID)
                slot.observationTask?.cancel()
                slot.retargetTask?.cancel()
                track { await slot.repository.shutdown() }
            }
            if slots[groupID] == nil {
                createSlot(for: target, groupID: groupID)
            }
        }

        publishGroups()
        retargetSlots()
    }

    private func createSlot(
        for target: AgentPanelResolvedCheckout,
        groupID: AgentChangesGroupID
    ) {
        let repository = repositoryFactory()
        let slot = RepositorySlot(target: target, repository: repository)
        slots[groupID] = slot
        let slotID = slot.id

        slot.observationTask = Task { @MainActor [weak self] in
            for await next in await repository.snapshots() {
                guard let self else { return }
                apply(next, to: groupID, slotID: slotID)
            }
        }

        track { [environment] in
            let candidates = await environment.baseBranchCandidates(at: target.checkoutURL)
            guard let current = self.slots[groupID],
                  current.id == slotID,
                  current.target.targetKey == target.targetKey
            else { return }
            current.baseCandidates = candidates
            self.publishGroups()
        }
    }

    private func retargetSlots() {
        for (groupID, slot) in slots {
            let mode = panel.resolvedCompareMode(for: slot.target)
            let resolvedMode = mode ?? .workingTree
            let effectiveTarget = mode == nil ? nil : slot.target
            let targetingKey = [
                effectiveTarget?.targetKey ?? "<none>",
                String(describing: resolvedMode)
            ].joined(separator: "\u{1F}")

            guard slot.targetingKey != targetingKey else { continue }
            let mutationLease = slot.mutationLeases.replace()
            slot.targetingKey = targetingKey
            slot.expectedMode = resolvedMode
            slot.expectedTargetKey = effectiveTarget?.targetKey
            slot.isTargeted = effectiveTarget != nil
            slot.snapshot = .empty
            slot.lastRefreshedAt = nil
            slot.targetRequestID &+= 1
            let requestID = slot.targetRequestID
            let repository = slot.repository
            removeUIState(for: groupID)
            didAutoExpandGroups.remove(groupID)

            slot.retargetTask?.cancel()
            slot.retargetTask = trackedTask {
                guard !Task.isCancelled,
                      let current = self.slots[groupID],
                      current.id == slot.id,
                      current.targetRequestID == requestID
                else { return }
                await repository.setTarget(
                    effectiveTarget,
                    mode: resolvedMode,
                    requestID: requestID,
                    mutationLease: mutationLease
                )
            }
        }

        publishGroups()
        syncPatchLoads()
        restartSearchIfCorpusChanged()
    }

    private func removeUIState(for groupID: AgentChangesGroupID) {
        for key in Array(stagingGraceTasksByPath.keys.filter { $0.groupID == groupID }) {
            stagingGraceTasksByPath.removeValue(forKey: key)?.cancel()
        }
        for key in Array(resolutionGraceTasksByPath.keys.filter { $0.groupID == groupID }) {
            resolutionGraceTasksByPath.removeValue(forKey: key)?.cancel()
        }
        for key in Array(partialGraceTasksByPath.keys.filter { $0.groupID == groupID }) {
            partialGraceTasksByPath.removeValue(forKey: key)?.cancel()
        }
        patchStates = patchStates.filter { $0.key.groupID != groupID }
        gapContextStates = gapContextStates.filter { $0.key.groupID != groupID }
        loadedPatchKeys = loadedPatchKeys.filter { $0.key.groupID != groupID }
        pendingStagingByPath = pendingStagingByPath.filter { $0.key.groupID != groupID }
        pendingBulkSections.removeValue(forKey: groupID)
        pendingResolutionByPath = pendingResolutionByPath.filter { $0.key.groupID != groupID }
        partialDescriptorsByRow = partialDescriptorsByRow.filter { $0.key.groupID != groupID }
        partialSelectionsByHunk = partialSelectionsByHunk.filter { $0.key.rowKey.groupID != groupID }
        pendingPartialByPath = pendingPartialByPath.filter { $0.key.groupID != groupID }
        flashedFileKeys = Set(flashedFileKeys.filter { $0.groupID != groupID })
        flashIDsByFileKey = flashIDsByFileKey.filter { $0.key.groupID != groupID }
        if statusMessageGroupID == groupID {
            statusMessage = nil
            statusMessageGroupID = nil
        }
        searchExpandedFiles = Set(searchExpandedFiles.filter { $0.groupID != groupID })
    }

    private func publishGroups() {
        groups = (resolution?.items ?? []).compactMap { item in
            guard case let .resolved(target) = item else { return nil }
            let groupID = AgentChangesGroupID(target: target)
            guard let slot = slots[groupID] else { return nil }
            return AgentChangesGroupState(
                target: target,
                resolvedCompareMode: panel.resolvedCompareMode(for: target),
                snapshot: slot.snapshot,
                baseCandidates: slot.baseCandidates,
                lastRefreshedAt: slot.lastRefreshedAt
            )
        }
        lastRefreshedAt = groups.compactMap(\.lastRefreshedAt).min()
    }

    // MARK: - Group access

    func groupState(for groupID: AgentChangesGroupID) -> AgentChangesGroupState? {
        groups.first { $0.id == groupID }
    }

    var repositorySlotCount: Int {
        slots.count
    }

    func repositorySlotID(for groupID: AgentChangesGroupID) -> UUID? {
        slots[groupID]?.id
    }

    // MARK: - Snapshots and aggregate presentation

    private func apply(
        _ next: AgentChangesSnapshot,
        to groupID: AgentChangesGroupID,
        slotID: UUID
    ) {
        guard let slot = slots[groupID],
              slot.id == slotID,
              next.targetRequestID == slot.targetRequestID,
              next.target?.targetKey == slot.expectedTargetKey,
              next.mode == slot.expectedMode
        else { return }

        slot.snapshot = next
        if case .ready = next.loadState {
            slot.lastRefreshedAt = now()
        }
        publishGroups()
        resumeSnapshotDeliveryWaiters()
        autoExpandFirstFileIfNeeded(in: groupID)
        syncPatchLoads()
        refreshBannerLink()
        restartSearchIfCorpusChanged()
    }

    var filterCounts: AgentChangesFilterCounts {
        var all: Set<AgentChangesFileStateKey> = []
        var staged = 0
        var unstaged = 0
        var conflicts = 0

        for group in groups {
            for section in group.snapshot.sections {
                let rows = section.rows
                for row in rows {
                    all.insert(fileStateKey(groupID: group.id, row: row))
                }
                switch section.kind {
                case .staged: staged += rows.count
                case .unstaged: unstaged += rows.count
                case .conflicts: conflicts += rows.count
                case .vsBase, .workingCopy: break
                }
            }
        }

        return AgentChangesFilterCounts(
            all: all.count,
            staged: staged,
            unstaged: unstaged,
            conflicts: conflicts
        )
    }

    var showsFilterPills: Bool {
        panel.compareSelection == .workingTree
            && groups.contains { $0.snapshot.supportsStaging }
    }

    var availableFilters: [AgentChangesFilter] {
        var filters: [AgentChangesFilter] = [.all, .staged, .unstaged]
        if filterCounts.conflicts > 0 { filters.append(.conflicts) }
        return filters
    }

    var activeFilter: AgentChangesFilter {
        availableFilters.contains(panel.changesFilter) ? panel.changesFilter : .all
    }

    func visibleSections(for groupID: AgentChangesGroupID) -> [AgentChangesSection] {
        guard let group = groupState(for: groupID) else { return [] }
        guard showsFilterPills else {
            return group.snapshot.sections.filter { !$0.isEmpty }
        }
        if activeFilter != .all, !group.snapshot.supportsStaging {
            return []
        }
        return AgentChangesFiltering.sections(
            from: group.snapshot.sections,
            filter: activeFilter
        )
    }

    func filteredEmptyMessage(for groupID: AgentChangesGroupID) -> String? {
        guard showsFilterPills,
              activeFilter != .all,
              visibleSections(for: groupID).isEmpty
        else { return nil }
        return "No \(activeFilter.title.lowercased()) files"
    }

    func selectFilter(_ filter: AgentChangesFilter) {
        guard filter != panel.changesFilter, availableFilters.contains(filter) else { return }
        objectWillChange.send()
        environment.setChangesFilter(filter, tabID: tabID)
        panel.setChangesFilter(filter)
        syncPatchLoads()
        restartSearch()
    }

    var footerSummary: FooterSummary {
        let rows = groups.flatMap { group in
            group.snapshot.sections.flatMap { section in
                section.rows.map { (group.id, $0) }
            }
        }
        let files = Set(rows.map { fileStateKey(groupID: $0.0, row: $0.1) })
        return FooterSummary(
            fileCount: files.count,
            additions: groups.reduce(0) { $0 + $1.snapshot.additions },
            deletions: groups.reduce(0) { $0 + $1.snapshot.deletions },
            isPollingDegraded: groups.contains { $0.snapshot.isPollingDegraded },
            lastRefreshedAt: groups.compactMap(\.lastRefreshedAt).min()
        )
    }

    func emptyState(for groupID: AgentChangesGroupID) -> AgentChangesEmptyState? {
        guard let group = groupState(for: groupID) else { return nil }
        if group.compareState == .awaitingBase { return .baseNotChosen }
        switch group.snapshot.loadState {
        case .initial:
            return .loading
        case let .failed(message):
            return .failed(message)
        case .ready:
            switch group.snapshot.emptyReason {
            case .none: return nil
            case .noCheckout: return .noWorkspaceRoot
            case .unbornHeadCleanTree: return .unbornHead
            case .cleanTree:
                return .cleanTree(
                    offersBaseComparison: panel.compareSelection == .workingTree
                )
            }
        }
    }

    // MARK: - Expansion, patches, and Viewed

    private func rowKey(
        groupID: AgentChangesGroupID,
        row: AgentChangesFileRow
    ) -> AgentChangesRowKey {
        AgentChangesRowKey(groupID: groupID, rowID: row.id)
    }

    private func fileStateKey(
        groupID: AgentChangesGroupID,
        row: AgentChangesFileRow
    ) -> AgentChangesFileStateKey {
        AgentChangesFileStateKey(
            groupID: groupID,
            repositoryRelativePath: row.path
        )
    }

    private func groupPathKey(
        groupID: AgentChangesGroupID,
        row: AgentChangesFileRow
    ) -> AgentChangesGroupPathKey {
        AgentChangesGroupPathKey(
            groupID: groupID,
            repositoryRelativePath: row.identity.path
        )
    }

    private func operationFence(
        for groupID: AgentChangesGroupID,
        slot: RepositorySlot
    ) -> SlotOperationFence {
        SlotOperationFence(
            lifecycleGeneration: lifecycleGeneration,
            tabID: tabID,
            groupID: groupID,
            slotID: slot.id,
            targetRequestID: slot.targetRequestID
        )
    }

    private func isCurrent(_ fence: SlotOperationFence) -> Bool {
        guard lifecycleGeneration == fence.lifecycleGeneration,
              tabID == fence.tabID,
              let slot = slots[fence.groupID]
        else { return false }
        return slot.id == fence.slotID && slot.targetRequestID == fence.targetRequestID
    }

    func isExpanded(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        let key = fileStateKey(groupID: groupID, row: row)
        return panel.isExpanded(file: key) || searchExpandedFiles.contains(key)
    }

    func toggleExpansion(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        setExpansion(!isExpanded(row, in: groupID), for: row, in: groupID)
    }

    func setExpansion(
        _ isExpanded: Bool,
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        let key = fileStateKey(groupID: groupID, row: row)
        if searchExpandedFiles.remove(key) != nil, isExpanded {
            // Manual expansion promotes a search-owned disclosure into canonical tab state.
        }
        environment.setFileExpansion(isExpanded, file: key, tabID: tabID)
        panel.setExpansion(isExpanded, ofFile: key)
        syncPatchLoads()
    }

    private func viewedCompareTargetKey(for groupID: AgentChangesGroupID) -> String? {
        guard let group = groupState(for: groupID),
              let mode = group.resolvedCompareMode
        else { return nil }
        return AgentUtilityPanelTabState.viewedCompareTargetKey(
            for: group.target,
            mode: mode
        )
    }

    func viewedStatus(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> AgentChangesViewedStatus {
        guard let key = viewedCompareTargetKey(for: groupID) else { return .notViewed }
        return panel.viewedStatus(for: row.viewedRevision, compareTargetKey: key)
    }

    func isViewed(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        viewedStatus(for: row, in: groupID) == .viewed
    }

    var viewedProgress: AgentChangesViewedProgress {
        var rowsByFile: [AgentChangesFileStateKey: [(AgentChangesGroupID, AgentChangesFileRow)]] = [:]
        for group in groups {
            for row in group.snapshot.sections.flatMap(\.rows) {
                rowsByFile[fileStateKey(groupID: group.id, row: row), default: []]
                    .append((group.id, row))
            }
        }
        return AgentChangesViewedProgress(
            viewedFileCount: rowsByFile.values.count {
                $0.allSatisfy { isViewed($0.1, in: $0.0) }
            },
            totalFileCount: rowsByFile.count
        )
    }

    func setViewed(
        _ viewed: Bool,
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        guard let compareTargetKey = viewedCompareTargetKey(for: groupID) else { return }
        objectWillChange.send()
        let fileKey = fileStateKey(groupID: groupID, row: row)
        let collapseFile = viewed && isExpanded(row, in: groupID) ? fileKey : nil
        environment.setFileViewed(
            viewed,
            revision: row.viewedRevision,
            compareTargetKey: compareTargetKey,
            collapseFile: collapseFile,
            tabID: tabID
        )
        panel.setViewed(
            viewed,
            revision: row.viewedRevision,
            compareTargetKey: compareTargetKey
        )
        if let collapseFile {
            panel.setExpansion(false, ofFile: collapseFile)
            searchExpandedFiles.remove(collapseFile)
            syncPatchLoads()
        }
    }

    func contextLevel(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> AgentChangesContextLevel {
        panel.contextLevel(forFile: fileStateKey(groupID: groupID, row: row))
    }

    func escalateContext(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        let key = fileStateKey(groupID: groupID, row: row)
        environment.escalateContext(file: key, tabID: tabID)
        panel.escalateContext(forFile: key)
        syncPatchLoads()
    }

    func patchState(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> AgentChangesPatchLoadState {
        patchStates[rowKey(groupID: groupID, row: row)] ?? .idle
    }

    private func autoExpandFirstFileIfNeeded(in groupID: AgentChangesGroupID) {
        guard !didAutoExpandGroups.contains(groupID),
              let group = groupState(for: groupID),
              case .ready = group.snapshot.loadState
        else { return }
        didAutoExpandGroups.insert(groupID)
        guard let first = visibleSections(for: groupID).first?.rows.first else { return }
        let key = fileStateKey(groupID: groupID, row: first)
        guard !panel.expandedFiles.contains(where: { $0.groupID == groupID }) else { return }
        environment.setFileExpansion(true, file: key, tabID: tabID)
        panel.setExpansion(true, ofFile: key)
    }

    private func syncPatchLoads() {
        var expanded: [(AgentChangesGroupState, RepositorySlot, AgentChangesFileRow)] = []
        var expandedKeys: Set<AgentChangesRowKey> = []

        for group in groups {
            guard let slot = slots[group.id] else { continue }
            for row in group.snapshot.sections.flatMap(\.rows)
                where isExpanded(row, in: group.id)
            {
                expanded.append((group, slot, row))
                expandedKeys.insert(rowKey(groupID: group.id, row: row))
            }
        }

        for key in Array(patchStates.keys) where !expandedKeys.contains(key) {
            patchStates.removeValue(forKey: key)
            gapContextStates.removeValue(forKey: key)
            loadedPatchKeys.removeValue(forKey: key)
            partialDescriptorsByRow.removeValue(forKey: key)
            clearPartialSelections(for: key)
        }

        for (group, slot, row) in expanded {
            let qualifiedRow = rowKey(groupID: group.id, row: row)
            let level = contextLevel(for: row, in: group.id)
            let key = PatchRequestKey(
                slotID: slot.id,
                targetRequestID: slot.targetRequestID,
                rowID: row.id,
                targetKey: group.target.targetKey,
                compareKey: row.section.compareSpec(mode: group.snapshot.mode).rawKey,
                fingerprintKey: group.snapshot.fingerprintKey,
                contentRevision: row.contentRevision,
                contextLevel: level
            )
            guard loadedPatchKeys[qualifiedRow] != key else {
                publishPendingNavigationIfReady(for: qualifiedRow)
                continue
            }

            loadedPatchKeys[qualifiedRow] = key
            patchStates[qualifiedRow] = .loading
            gapContextStates.removeValue(forKey: qualifiedRow)
            partialDescriptorsByRow.removeValue(forKey: qualifiedRow)
            clearPartialSelections(for: qualifiedRow)
            let repository = slot.repository

            track {
                let state = await repository.patch(for: row, contextLevel: level)
                guard self.loadedPatchKeys[qualifiedRow] == key,
                      self.slots[group.id]?.id == slot.id
                else { return }

                self.patchStates[qualifiedRow] = state
                if case let .loaded(document) = state {
                    let side = AgentChangesContextSourceResolver.selection(
                        for: row,
                        document: document,
                        mode: group.snapshot.mode,
                        hasHeadCommit: group.snapshot.hasHeadCommit
                    )?.side ?? .new
                    self.gapContextStates[qualifiedRow] = GapContextState(sourceSide: side)
                    let descriptor = await repository.partialStagingDescriptor(
                        for: row,
                        renderedDocument: document,
                        contextLevel: level
                    )
                    guard self.loadedPatchKeys[qualifiedRow] == key,
                          self.slots[group.id]?.id == slot.id
                    else { return }
                    self.setPartialDescriptor(descriptor, for: qualifiedRow)
                    self.publishPendingNavigationIfReady(for: qualifiedRow)
                } else {
                    self.gapContextStates.removeValue(forKey: qualifiedRow)
                }
            }
        }
    }

    func gapContextState(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> GapContextState {
        gapContextStates[rowKey(groupID: groupID, row: row)] ?? GapContextState()
    }

    func expandContextGap(
        _ gap: DiffContextSplicer.Gap,
        amount: DiffContextSplicer.ExpansionAmount,
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        guard case let .loaded(document) = patchState(for: row, in: groupID),
              let slot = slots[groupID]
        else { return }
        let qualifiedRow = rowKey(groupID: groupID, row: row)
        var state = gapContextState(for: row, in: groupID)
        guard state.loadingGapID == nil else { return }
        state.loadingGapID = gap.id
        state.unavailableReason = nil
        gapContextStates[qualifiedRow] = state

        let requestKey = loadedPatchKeys[qualifiedRow]
        let fence = operationFence(for: groupID, slot: slot)
        let repository = slot.repository
        track {
            let outcome = await repository.expandContextGap(
                for: row,
                in: document,
                gapID: gap.id,
                amount: amount
            )
            guard self.loadedPatchKeys[qualifiedRow] == requestKey,
                  self.isCurrent(fence)
            else { return }

            var current = self.gapContextStates[qualifiedRow] ?? GapContextState()
            current.loadingGapID = nil
            switch outcome {
            case let .expanded(expanded, sourceLineCount, sourceSide):
                current.sourceLineCount = sourceLineCount
                current.sourceSide = sourceSide
                current.unavailableReason = nil
                self.patchStates[qualifiedRow] = .loaded(expanded)
                // Expanded-gap documents are rendering-only and cannot mint a partial review token.
                self.partialDescriptorsByRow[qualifiedRow] = .unavailable(.rawPatchUnavailable)
                self.clearPartialSelections(for: qualifiedRow)
            case let .unavailable(reason):
                current.unavailableReason = reason
            }
            self.gapContextStates[qualifiedRow] = current
        }
    }

    // MARK: - Partial staging

    func partialDescriptor(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> AgentChangesPartialStagingDescriptor? {
        partialDescriptorsByRow[rowKey(groupID: groupID, row: row)]
    }

    func selectedPartialLineKeys(
        for row: AgentChangesFileRow,
        hunkID: String,
        in groupID: AgentChangesGroupID
    ) -> Set<AgentChangesDiffLineKey> {
        guard let descriptor = partialDescriptor(for: row, in: groupID),
              let token = descriptor.reviewToken
        else { return [] }
        return partialSelectionsByHunk[
            PartialSelectionKey(
                rowKey: rowKey(groupID: groupID, row: row),
                reviewToken: token,
                projectedHunkID: hunkID
            )
        ] ?? []
    }

    func setPartialLineSelected(
        _ selected: Bool,
        lineKey: AgentChangesDiffLineKey,
        hunkID: String,
        row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        guard let descriptor = partialDescriptor(for: row, in: groupID),
              descriptor.availability == .available,
              let token = descriptor.reviewToken,
              descriptor.selectableChangedLineKeys.contains(lineKey),
              descriptor.changedLineKeysByHunkID[hunkID]?.contains(lineKey) == true,
              !isPartialMutationDisabled(for: row, in: groupID)
        else { return }

        let key = PartialSelectionKey(
            rowKey: rowKey(groupID: groupID, row: row),
            reviewToken: token,
            projectedHunkID: hunkID
        )
        var lines = partialSelectionsByHunk[key] ?? []
        if selected {
            lines.insert(lineKey)
        } else {
            lines.remove(lineKey)
        }
        if lines.isEmpty {
            partialSelectionsByHunk.removeValue(forKey: key)
        } else {
            partialSelectionsByHunk[key] = lines
        }
    }

    func clearPartialSelection(
        for row: AgentChangesFileRow,
        hunkID: String,
        in groupID: AgentChangesGroupID
    ) {
        guard let token = partialDescriptor(for: row, in: groupID)?.reviewToken else { return }
        partialSelectionsByHunk.removeValue(
            forKey: PartialSelectionKey(
                rowKey: rowKey(groupID: groupID, row: row),
                reviewToken: token,
                projectedHunkID: hunkID
            )
        )
    }

    func pendingPartial(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> PendingPartialMutation? {
        pendingPartialByPath[groupPathKey(groupID: groupID, row: row)]
    }

    func isPartialMutationDisabled(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        let pathKey = groupPathKey(groupID: groupID, row: row)
        return pendingStagingByPath[pathKey] != nil
            || pendingResolutionByPath[pathKey] != nil
            || pendingPartialByPath[pathKey] != nil
            || !(pendingBulkSections[groupID] ?? []).isEmpty
    }

    func applyPartialHunk(
        for row: AgentChangesFileRow,
        hunkID: String,
        in groupID: AgentChangesGroupID
    ) {
        guard let descriptor = partialDescriptor(for: row, in: groupID),
              let lines = descriptor.changedLineKeysByHunkID[hunkID],
              !lines.isEmpty
        else { return }
        applyPartial(
            selection: .hunk(projectedHunkID: hunkID, lines: lines),
            kind: .hunk,
            descriptor: descriptor,
            row: row,
            groupID: groupID
        )
    }

    func applySelectedPartialLines(
        for row: AgentChangesFileRow,
        hunkID: String,
        in groupID: AgentChangesGroupID
    ) {
        let lines = selectedPartialLineKeys(for: row, hunkID: hunkID, in: groupID)
        guard !lines.isEmpty,
              let descriptor = partialDescriptor(for: row, in: groupID)
        else { return }
        applyPartial(
            selection: .lines(projectedHunkID: hunkID, lines: lines),
            kind: .lines(count: lines.count),
            descriptor: descriptor,
            row: row,
            groupID: groupID
        )
    }

    private func applyPartial(
        selection: AgentChangesPartialMutationSelection,
        kind: PendingPartialMutation.SelectionKind,
        descriptor: AgentChangesPartialStagingDescriptor,
        row: AgentChangesFileRow,
        groupID: AgentChangesGroupID
    ) {
        guard descriptor.availability == .available,
              let action = descriptor.action,
              let token = descriptor.reviewToken,
              let slot = slots[groupID],
              !isPartialMutationDisabled(for: row, in: groupID)
        else { return }

        let fence = operationFence(for: groupID, slot: slot)
        let pathKey = groupPathKey(groupID: groupID, row: row)
        pendingPartialByPath[pathKey] = PendingPartialMutation(
            initiatingRowID: row.id,
            action: action,
            selectionKind: kind,
            showsSpinner: false,
            reviewToken: token
        )
        startPartialGrace(for: pathKey)

        let request = AgentChangesPartialMutationRequest(
            reviewToken: token,
            row: row,
            selection: selection
        )
        let repository = slot.repository
        track {
            let outcome = await repository.applyPartialMutation(request)
            guard self.isCurrent(fence) else { return }
            self.partialGraceTasksByPath.removeValue(forKey: pathKey)?.cancel()
            self.pendingPartialByPath.removeValue(forKey: pathKey)
            let qualifiedRow = self.rowKey(groupID: groupID, row: row)
            switch outcome {
            case .applied:
                self.clearPartialSelections(for: qualifiedRow)
            case .contentChanged, .failed:
                self.partialDescriptorsByRow.removeValue(forKey: qualifiedRow)
                self.loadedPatchKeys.removeValue(forKey: qualifiedRow)
                self.clearPartialSelections(for: qualifiedRow)
                self.syncPatchLoads()
            case .noOp, .conflicted, .unsupported:
                break
            }
            self.handle(
                outcome: outcome,
                fileName: row.path,
                fileKey: row.fileKey,
                groupID: groupID
            )
        }
    }

    private func setPartialDescriptor(
        _ descriptor: AgentChangesPartialStagingDescriptor,
        for rowKey: AgentChangesRowKey
    ) {
        partialDescriptorsByRow[rowKey] = descriptor
        clearPartialSelections(for: rowKey, keeping: descriptor.reviewToken)
    }

    private func clearPartialSelections(
        for rowKey: AgentChangesRowKey,
        keeping token: AgentChangesPatchReviewToken? = nil
    ) {
        partialSelectionsByHunk = partialSelectionsByHunk.filter {
            $0.key.rowKey != rowKey || (token != nil && $0.key.reviewToken == token)
        }
    }

    // MARK: - Whole-file staging and conflicts

    func isStagedForDisplay(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        pendingStagingByPath[groupPathKey(groupID: groupID, row: row)]?.requestedStage
            ?? row.isStaged
    }

    func pendingStaging(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> PendingStaging? {
        pendingStagingByPath[groupPathKey(groupID: groupID, row: row)]
    }

    func showsStagingCheckbox(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        guard groupState(for: groupID)?.snapshot.supportsStaging == true else { return false }
        return row.section.isStageable || row.section == .conflicts
    }

    func isMutationDisabled(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        if !row.isStageable { return true }
        let pathKey = groupPathKey(groupID: groupID, row: row)
        if pendingStagingByPath[pathKey] != nil { return true }
        if pendingResolutionByPath[pathKey] != nil { return true }
        if pendingPartialByPath[pathKey] != nil { return true }
        let bulk = pendingBulkSections[groupID] ?? []
        if bulk.contains(row.section) { return true }
        if row.hasCounterpartSection, !bulk.isEmpty { return true }
        return false
    }

    func isBulkActionDisabled(
        for section: AgentChangesSectionKind,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        let hasStaging = pendingStagingByPath.keys.contains { $0.groupID == groupID }
        let hasResolution = pendingResolutionByPath.keys.contains { $0.groupID == groupID }
        let hasPartial = pendingPartialByPath.keys.contains { $0.groupID == groupID }
        let bulk = pendingBulkSections[groupID] ?? []
        let snapshot = groupState(for: groupID)?.snapshot
        return hasStaging
            || hasResolution
            || hasPartial
            || !bulk.isEmpty
            || !section.isStageable
            || snapshot?.section(section)?.rows.contains(where: \.isStageable) != true
    }

    func isBulkActionPending(
        for section: AgentChangesSectionKind,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        pendingBulkSections[groupID]?.contains(section) == true
    }

    func setStaged(
        _ stage: Bool,
        row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        guard let slot = slots[groupID],
              slot.snapshot.supportsStaging,
              row.isStageable
        else { return }
        let pathKey = groupPathKey(groupID: groupID, row: row)
        guard pendingStagingByPath[pathKey] == nil,
              pendingResolutionByPath[pathKey] == nil,
              pendingPartialByPath[pathKey] == nil
        else { return }

        let fence = operationFence(for: groupID, slot: slot)
        pendingStagingByPath[pathKey] = PendingStaging(
            requestedStage: stage,
            showsSpinner: false
        )
        startStagingGrace(for: pathKey)

        let request = AgentChangesMutationRequest(
            row: row,
            stage: stage,
            targetRequestID: slot.snapshot.targetRequestID
        )
        let repository = slot.repository
        track {
            let outcome = await repository.applyMutation(request)
            guard self.isCurrent(fence) else { return }
            self.stagingGraceTasksByPath.removeValue(forKey: pathKey)?.cancel()
            self.pendingStagingByPath.removeValue(forKey: pathKey)
            self.handle(
                outcome: outcome,
                fileName: row.path,
                fileKey: row.fileKey,
                groupID: groupID
            )
        }
    }

    func applyBulkStaging(
        _ stage: Bool,
        section: AgentChangesSectionKind,
        in groupID: AgentChangesGroupID
    ) {
        guard let slot = slots[groupID],
              slot.snapshot.supportsStaging,
              section.isStageable,
              !isBulkActionDisabled(for: section, in: groupID)
        else { return }

        let fence = operationFence(for: groupID, slot: slot)
        pendingBulkSections[groupID, default: []].insert(section)
        let reviewedRows = slot.snapshot.section(section)?.rows.filter(\.isStageable) ?? []
        let request = AgentChangesBulkMutationRequest(
            section: section,
            stage: stage,
            rows: reviewedRows,
            targetRequestID: slot.snapshot.targetRequestID
        )
        let repository = slot.repository
        track {
            let outcome = await repository.applyBulkMutation(request)
            guard self.isCurrent(fence) else { return }
            self.pendingBulkSections[groupID]?.remove(section)
            if self.pendingBulkSections[groupID]?.isEmpty == true {
                self.pendingBulkSections.removeValue(forKey: groupID)
            }
            self.handle(
                outcome: outcome,
                fileName: nil,
                fileKey: nil,
                groupID: groupID
            )
        }
    }

    func pendingResolution(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> PendingResolution? {
        pendingResolutionByPath[groupPathKey(groupID: groupID, row: row)]
    }

    func markResolvedDisabledReason(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> String? {
        guard row.isConflicted else { return "Only conflicted files can be marked resolved." }
        guard let group = groupState(for: groupID), group.snapshot.target != nil else {
            return "The selected checkout is unavailable."
        }
        guard group.snapshot.supportsStaging else {
            return "This repository has no staging area, so conflicts cannot be marked resolved here."
        }
        let pathKey = groupPathKey(groupID: groupID, row: row)
        if pendingResolutionByPath[pathKey] != nil {
            return "This conflict is already being marked resolved."
        }
        if pendingStagingByPath[pathKey] != nil
            || pendingPartialByPath[pathKey] != nil
            || !(pendingBulkSections[groupID] ?? []).isEmpty
        {
            return "Wait for the overlapping index operation to finish."
        }
        return nil
    }

    func markResolved(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) {
        guard markResolvedDisabledReason(for: row, in: groupID) == nil,
              let slot = slots[groupID]
        else { return }
        let fence = operationFence(for: groupID, slot: slot)
        let pathKey = groupPathKey(groupID: groupID, row: row)
        pendingResolutionByPath[pathKey] = PendingResolution(showsSpinner: false)
        startResolutionGrace(for: pathKey)

        let request = AgentChangesResolveRequest(
            row: row,
            targetRequestID: slot.snapshot.targetRequestID
        )
        let repository = slot.repository
        track {
            let outcome = await repository.markResolved(request)
            guard self.isCurrent(fence) else { return }
            self.resolutionGraceTasksByPath.removeValue(forKey: pathKey)?.cancel()
            self.pendingResolutionByPath.removeValue(forKey: pathKey)
            self.handleResolution(outcome: outcome, row: row, groupID: groupID)
        }
    }

    private func startStagingGrace(for pathKey: AgentChangesGroupPathKey) {
        let grace = stagingGrace
        stagingGraceTasksByPath[pathKey] = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: grace)
            guard !Task.isCancelled,
                  let self,
                  var pending = pendingStagingByPath[pathKey]
            else { return }
            pending.showsSpinner = true
            pendingStagingByPath[pathKey] = pending
        }
    }

    private func startResolutionGrace(for pathKey: AgentChangesGroupPathKey) {
        let grace = stagingGrace
        resolutionGraceTasksByPath[pathKey] = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: grace)
            guard !Task.isCancelled,
                  let self,
                  var pending = pendingResolutionByPath[pathKey]
            else { return }
            pending.showsSpinner = true
            pendingResolutionByPath[pathKey] = pending
        }
    }

    private func startPartialGrace(for pathKey: AgentChangesGroupPathKey) {
        let grace = stagingGrace
        partialGraceTasksByPath[pathKey] = Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: grace)
            guard !Task.isCancelled,
                  let self,
                  var pending = pendingPartialByPath[pathKey]
            else { return }
            pending.showsSpinner = true
            pendingPartialByPath[pathKey] = pending
        }
    }

    private func publishStatusMessage(
        _ message: StatusMessage,
        for groupID: AgentChangesGroupID
    ) {
        statusMessage = message
        statusMessageGroupID = groupID
    }

    private func clearStatusMessage(for groupID: AgentChangesGroupID) {
        guard statusMessageGroupID == groupID else { return }
        statusMessage = nil
        statusMessageGroupID = nil
    }

    private func handleResolution(
        outcome: AgentChangesMutationOutcome,
        row: AgentChangesFileRow,
        groupID: AgentChangesGroupID
    ) {
        switch outcome {
        case .applied(contentChanged: true):
            flash(fileKey: row.fileKey, groupID: groupID)
            publishStatusMessage(
                .info(
                    messagePrefix(for: groupID)
                        + "The conflict was marked resolved, then the file changed again."
                ),
                for: groupID
            )
        case .applied, .noOp:
            clearStatusMessage(for: groupID)
        case .contentChanged:
            flash(fileKey: row.fileKey, groupID: groupID)
            let name = (row.path as NSString).lastPathComponent
            publishStatusMessage(
                .info(
                    messagePrefix(for: groupID)
                        + "\(name) changed on disk — refreshed instead of marking unreviewed contents resolved."
                ),
                for: groupID
            )
        case .unsupported:
            publishStatusMessage(
                .failure(
                    messagePrefix(for: groupID)
                        + "This repository cannot mark conflicts resolved from the Changes panel."
                ),
                for: groupID
            )
        case .conflicted:
            publishStatusMessage(
                .failure(messagePrefix(for: groupID) + "The conflict is still unresolved."),
                for: groupID
            )
        case let .failed(message):
            publishStatusMessage(
                .failure(messagePrefix(for: groupID) + message),
                for: groupID
            )
        }
    }

    private func handle(
        outcome: AgentChangesMutationOutcome,
        fileName: String?,
        fileKey: String?,
        groupID: AgentChangesGroupID
    ) {
        switch outcome {
        case .applied(contentChanged: true):
            if let fileKey { flash(fileKey: fileKey, groupID: groupID) }
            publishStatusMessage(
                .info(
                    messagePrefix(for: groupID)
                        + "The reviewed change reached the index, then the file changed again."
                ),
                for: groupID
            )
        case .applied, .noOp:
            clearStatusMessage(for: groupID)
        case .contentChanged:
            if let fileKey { flash(fileKey: fileKey, groupID: groupID) }
            let name = fileName.map { ($0 as NSString).lastPathComponent } ?? "The file"
            publishStatusMessage(
                .info(
                    messagePrefix(for: groupID)
                        + "\(name) changed on disk — refreshed instead of staging unreviewed content."
                ),
                for: groupID
            )
        case .conflicted:
            publishStatusMessage(
                .failure(
                    messagePrefix(for: groupID)
                        + "Conflicted files cannot be staged from this panel."
                ),
                for: groupID
            )
        case .unsupported:
            publishStatusMessage(
                .failure(messagePrefix(for: groupID) + "This repository has no staging area."),
                for: groupID
            )
        case let .failed(message):
            publishStatusMessage(
                .failure(messagePrefix(for: groupID) + message),
                for: groupID
            )
        }
    }

    private func messagePrefix(for groupID: AgentChangesGroupID) -> String {
        guard groups.count > 1, let target = groupState(for: groupID)?.target else { return "" }
        return "\(target.displayName): "
    }

    private func flash(fileKey: String, groupID: AgentChangesGroupID) {
        let key = AgentChangesFileStateKey(
            groupID: groupID,
            repositoryRelativePath: fileKey
        )
        let flashID = UUID()
        flashIDsByFileKey[key] = flashID
        flashedFileKeys.insert(key)
        let duration = flashDuration
        Task { @MainActor [weak self, scheduler] in
            try? await scheduler.sleep(for: duration)
            guard let self, flashIDsByFileKey[key] == flashID else { return }
            flashIDsByFileKey.removeValue(forKey: key)
            flashedFileKeys.remove(key)
        }
    }

    func isFlashing(
        _ row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID
    ) -> Bool {
        flashedFileKeys.contains(
            AgentChangesFileStateKey(
                groupID: groupID,
                repositoryRelativePath: row.fileKey
            )
        )
    }

    func dismissStatusMessage() {
        statusMessage = nil
        statusMessageGroupID = nil
    }

    // MARK: - Header and per-group base actions

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
        retargetSlots()
    }

    func baseCandidates(for groupID: AgentChangesGroupID) -> [String] {
        groupState(for: groupID)?.baseCandidates ?? []
    }

    func selectBaseRevision(
        _ revision: String,
        for groupID: AgentChangesGroupID
    ) {
        guard let target = groupState(for: groupID)?.target else { return }
        customRevisionEditor = nil
        customRevisionValidationID = nil
        let repoRoot = target.repoRootURL.standardizedFileURL.path
        environment.selectBaseRevision(revision, forRepoRoot: repoRoot, tabID: tabID)
        panel.selectBaseRevision(revision, forRepoRoot: repoRoot)
        retargetSlots()
    }

    func beginCustomRevisionEntry(for groupID: AgentChangesGroupID) {
        guard panel.compareSelection == .vsBase,
              let target = groupState(for: groupID)?.target
        else { return }
        customRevisionValidationID = nil
        customRevisionEditor = CustomRevisionEditor(
            groupID: groupID,
            text: panel.selectedBaseRevision(
                forRepoRoot: target.repoRootURL.standardizedFileURL.path
            ) ?? "",
            state: .editing
        )
    }

    func updateCustomRevisionText(_ text: String) {
        guard var editor = customRevisionEditor else { return }
        customRevisionValidationID = nil
        editor.text = text
        editor.state = .editing
        customRevisionEditor = editor
    }

    func cancelCustomRevisionEntry() {
        customRevisionValidationID = nil
        customRevisionEditor = nil
    }

    func submitCustomRevision() {
        guard var editor = customRevisionEditor,
              let slot = slots[editor.groupID]
        else { return }
        let revision = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            editor.state = .error("Enter a revision such as a tag, SHA, HEAD~3, or origin/main.")
            customRevisionEditor = editor
            return
        }

        let validationID = UUID()
        let requestedTabID = tabID
        let requestedSlotID = slot.id
        let requestedTargetKey = slot.target.targetKey
        customRevisionValidationID = validationID
        editor.state = .validating
        customRevisionEditor = editor

        let repository = slot.repository
        let target = slot.target
        track {
            let validation = await repository.validateRevision(revision, at: target)
            guard self.customRevisionValidationID == validationID,
                  self.tabID == requestedTabID,
                  self.slots[editor.groupID]?.id == requestedSlotID,
                  self.slots[editor.groupID]?.target.targetKey == requestedTargetKey
            else { return }

            switch validation {
            case .valid:
                self.customRevisionValidationID = nil
                self.customRevisionEditor = nil
                self.selectBaseRevision(revision, for: editor.groupID)
            case .invalid, .ambiguous, .failed:
                var current = self.customRevisionEditor ?? CustomRevisionEditor(
                    groupID: editor.groupID,
                    text: revision,
                    state: .editing
                )
                current.state = .error(
                    validation.errorMessage ?? "Revision could not be resolved."
                )
                self.customRevisionEditor = current
            }
        }
    }

    func showWorkspaceCheckoutInstead(for blocked: AgentPanelBlockedCheckout) {
        guard blocked.reason.allowsWorkspaceCheckoutOverride, let tabID else { return }
        var overrides = workspaceCheckoutOverridesByTab[tabID] ?? []
        overrides.insert(blocked.logicalRoot.path)
        workspaceCheckoutOverridesByTab[tabID] = overrides
        reloadRootInputs()
    }

    func isSubstitutingWorkspaceCheckout(in groupID: AgentChangesGroupID) -> Bool {
        groupState(for: groupID)?.target.substitutesUnavailableWorktree == true
    }

    func offerBaseComparison() {
        selectCompare(.vsBase)
    }

    // MARK: - Refresh

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let refreshID = UUID()
        activeRefreshID = refreshID

        let reloadTask = reloadRootInputs()
        track {
            _ = await reloadTask.value
            let currentSlots = Array(self.slots.values)
            for slot in currentSlots {
                _ = await slot.retargetTask?.value
            }
            guard self.activeRefreshID == refreshID else { return }

            await withTaskGroup(of: Void.self) { group in
                for slot in currentSlots where slot.isTargeted {
                    let repository = slot.repository
                    group.addTask {
                        await repository.refresh(.manual)
                        await repository.waitUntilIdle()
                    }
                }
            }

            guard self.activeRefreshID == refreshID else { return }
            self.activeRefreshID = nil
            self.isRefreshing = false
        }
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

    private func refreshBannerLink() {
        guard let artifact = artifactIndex.newestArtifact(
            excludingDismissed: panel.dismissedBannerArtifactIDs
        ) else {
            bannerLink = nil
            return
        }
        guard let document = AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: artifact.path,
            checkouts: groups.map(\.target),
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

    // MARK: - Search orchestration

    func updateSearchQuery(_ query: String) {
        beginSearch(query: query)
    }

    func clearSearch() {
        beginSearch(query: "")
    }

    private func restartSearch() {
        guard !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        beginSearch(query: searchState.query)
    }

    private func restartSearchIfCorpusChanged() {
        guard !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let current = makeSearchCorpus().key
        guard current != activeSearchCorpusKey else { return }
        beginSearch(query: searchState.query)
    }

    private func beginSearch(query: String) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        activeSearchCorpusKey = nil
        pendingNavigationMatchID = nil
        searchNavigationAnchor = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState = .idle
            searchExpandedFiles.removeAll()
            syncPatchLoads()
            return
        }

        searchState = AgentChangesSearchState(
            query: query,
            phase: .debouncing
        )
        let generation = searchGeneration
        let debounce = searchDebounce
        searchTask = trackedTask { [scheduler] in
            do {
                try await scheduler.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            await self.executeSearch(query: query, generation: generation)
        }
    }

    /// Fills the match cap from the merged path-and-patch stream in corpus order.
    ///
    /// A row's path match and its patch matches are admitted together, in one ordered batch, so a
    /// later row's path match can never claim a cap slot ahead of an earlier row's patch match.
    /// Scanning every path first would do exactly that: a corpus whose paths alone fill the cap
    /// would publish a "top N" that the ranking comparator disagrees with, and would never read a
    /// patch at all.
    ///
    /// Because the corpus is enumerated in the comparator's own group/section/row order, a fully
    /// processed prefix that has filled the cap proves every remaining row ranks after the accepted
    /// results — which is what makes stopping there sound. Stopping on the byte budget stays a
    /// truncation, and the rows left unread are reported as skipped either way.
    private func executeSearch(query: String, generation: UInt64) async {
        let corpus = makeSearchCorpus()
        activeSearchCorpusKey = corpus.key
        var accounting = AgentChangesSearchBudgetAccounting(budget: searchBudget)

        guard searchIsCurrent(generation: generation, corpusKey: corpus.key) else { return }
        searchState = AgentChangesSearchState(
            query: searchState.query,
            phase: .loading
        )

        var nextIndex = 0
        while nextIndex < corpus.items.count, accounting.canScheduleMore {
            let upper = min(nextIndex + 4, corpus.items.count)
            let batch = Array(corpus.items[nextIndex ..< upper])
            nextIndex = upper

            var batchMatches: [AgentChangesSearchMatch] = []
            for item in batch {
                batchMatches.append(contentsOf: AgentChangesSearchEngine.pathMatches(
                    query: query,
                    rowKey: item.rowKey,
                    groupOrder: item.groupOrder,
                    sectionOrder: item.sectionOrder,
                    rowOrder: item.rowOrder,
                    path: item.row.path,
                    maximumMatchCount: searchBudget.maximumMatchCount
                ))
            }

            let results = await loadSearchBatch(batch)

            guard searchIsCurrent(generation: generation, corpusKey: corpus.key) else { return }
            for result in results {
                accounting.record(result.document)
                guard let document = result.document.document else { continue }
                batchMatches.append(contentsOf: AgentChangesSearchEngine.patchMatches(
                    query: query,
                    rowKey: result.item.rowKey,
                    groupOrder: result.item.groupOrder,
                    sectionOrder: result.item.sectionOrder,
                    rowOrder: result.item.rowOrder,
                    document: document,
                    maximumMatchCount: searchBudget.maximumMatchCount
                ))
            }
            let selectedMatchID = searchState.selectedMatch?.id
            accounting.accept(AgentChangesSearchEngine.ordered(batchMatches))

            searchState = AgentChangesSearchState(
                query: searchState.query,
                phase: .loading,
                matches: accounting.matches,
                selectedMatchIndex: selectedMatchIndex(
                    preserving: selectedMatchID,
                    in: accounting.matches
                ),
                skippedFileCount: accounting.skippedFileCount,
                isTruncated: accounting.isTruncated
            )
        }

        if nextIndex < corpus.items.count {
            accounting.recordBudgetExcludedFiles(corpus.items.count - nextIndex)
        }
        guard searchIsCurrent(generation: generation, corpusKey: corpus.key) else { return }
        let selectedMatchID = searchState.selectedMatch?.id
        searchState = AgentChangesSearchState(
            query: searchState.query,
            phase: .ready,
            matches: accounting.matches,
            selectedMatchIndex: selectedMatchIndex(
                preserving: selectedMatchID,
                in: accounting.matches
            ),
            skippedFileCount: accounting.skippedFileCount,
            isTruncated: accounting.isTruncated
        )
    }

    private func selectedMatchIndex(
        preserving selectedMatchID: AgentChangesSearchMatch.ID?,
        in matches: [AgentChangesSearchMatch]
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let selectedMatchID else { return 0 }
        return matches.firstIndex { $0.id == selectedMatchID } ?? 0
    }

    private func loadSearchBatch(
        _ batch: [SearchCorpusItem]
    ) async -> [SearchLoadResult] {
        let limiter = searchReadLimiter
        return await withTaskGroup(of: SearchLoadResult?.self) { group in
            for item in batch {
                group.addTask {
                    guard let permitID = await limiter.acquire() else { return nil }
                    guard !Task.isCancelled else {
                        await limiter.release(permitID)
                        return nil
                    }
                    let document = await item.repository.searchDocument(for: item.row)
                    await limiter.release(permitID)
                    guard !Task.isCancelled else { return nil }
                    return SearchLoadResult(item: item, document: document)
                }
            }
            var results: [SearchLoadResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private func searchIsCurrent(
        generation: UInt64,
        corpusKey: SearchCorpusKey
    ) -> Bool {
        generation == searchGeneration
            && corpusKey == activeSearchCorpusKey
            && !Task.isCancelled
    }

    private func makeSearchCorpus() -> (
        key: SearchCorpusKey,
        items: [SearchCorpusItem]
    ) {
        var keyParts: [String] = [activeFilter.rawValue]
        var items: [SearchCorpusItem] = []

        for (groupOrder, groupState) in groups.enumerated() {
            guard let slot = slots[groupState.id], slot.isTargeted else { continue }
            keyParts.append(
                [
                    slot.id.uuidString,
                    groupState.snapshot.fingerprintKey,
                    String(describing: groupState.resolvedCompareMode),
                    String(describing: groupState.snapshot.mode)
                ].joined(separator: "\u{1E}")
            )

            let sections = visibleSections(for: groupState.id)
            for (sectionOrder, section) in sections.enumerated() {
                for (rowOrder, row) in section.rows.enumerated() {
                    keyParts.append(
                        [
                            groupState.id.targetKey,
                            row.id,
                            String(row.contentRevision),
                            section.kind.rawValue
                        ].joined(separator: "\u{1D}")
                    )
                    items.append(
                        SearchCorpusItem(
                            rowKey: rowKey(groupID: groupState.id, row: row),
                            groupOrder: groupOrder,
                            sectionOrder: sectionOrder,
                            rowOrder: rowOrder,
                            row: row,
                            repository: slot.repository
                        )
                    )
                }
            }
        }

        return (
            SearchCorpusKey(value: keyParts.joined(separator: "\u{1F}")),
            items
        )
    }

    func selectNextSearchMatch() {
        guard !searchState.matches.isEmpty else { return }
        let next = ((searchState.selectedMatchIndex ?? -1) + 1) % searchState.matches.count
        selectSearchMatch(at: next)
    }

    func selectPreviousSearchMatch() {
        guard !searchState.matches.isEmpty else { return }
        let current = searchState.selectedMatchIndex ?? 0
        let previous = (current - 1 + searchState.matches.count) % searchState.matches.count
        selectSearchMatch(at: previous)
    }

    func selectSearchMatch(at index: Int) {
        guard searchState.matches.indices.contains(index) else { return }
        searchState = AgentChangesSearchState(
            query: searchState.query,
            phase: searchState.phase,
            matches: searchState.matches,
            selectedMatchIndex: index,
            skippedFileCount: searchState.skippedFileCount,
            isTruncated: searchState.isTruncated
        )
        navigate(to: searchState.matches[index])
    }

    private func navigate(to match: AgentChangesSearchMatch) {
        guard let row = row(for: match.rowKey) else { return }
        let fileKey = fileStateKey(groupID: match.groupID, row: row)
        searchNavigationAnchor = nil
        pendingNavigationMatchID = match.id

        switch match.locator {
        case .filePath:
            searchExpandedFiles.removeAll()
            pendingNavigationMatchID = nil
            searchNavigationAnchor = SearchNavigationAnchor(
                matchID: match.id,
                rowKey: match.rowKey,
                locator: match.locator
            )
            syncPatchLoads()
        case .hunkHeading, .line:
            if panel.isExpanded(file: fileKey) {
                searchExpandedFiles.removeAll()
            } else {
                searchExpandedFiles = [fileKey]
            }
            syncPatchLoads()
            publishPendingNavigationIfReady(for: match.rowKey)
        }
    }

    private func publishPendingNavigationIfReady(for rowKey: AgentChangesRowKey) {
        guard let matchID = pendingNavigationMatchID,
              let match = searchState.matches.first(where: { $0.id == matchID }),
              match.rowKey == rowKey,
              let row = row(for: rowKey),
              case let .loaded(document) = patchState(for: row, in: rowKey.groupID),
              documentContains(match.locator, document: document)
        else { return }

        pendingNavigationMatchID = nil
        searchNavigationAnchor = SearchNavigationAnchor(
            matchID: match.id,
            rowKey: match.rowKey,
            locator: match.locator
        )
    }

    private func documentContains(
        _ locator: AgentChangesSearchLocator,
        document: FileDiffProjection.Document
    ) -> Bool {
        switch locator {
        case .filePath:
            true
        case let .hunkHeading(hunkID):
            document.hunks.contains { $0.id == hunkID }
        case let .line(kind, oldLine, newLine):
            document.hunks.flatMap(\.lines).contains {
                $0.kind == kind && $0.oldLine == oldLine && $0.newLine == newLine
            }
        }
    }

    private func row(for key: AgentChangesRowKey) -> AgentChangesFileRow? {
        groupState(for: key.groupID)?
            .snapshot.sections
            .flatMap(\.rows)
            .first { $0.id == key.rowID }
    }

    /// Matches for one row, or for one rendered element inside it, in published order.
    ///
    /// Every rendered diff line asks for its own matches, so this reads the bucketed index rather
    /// than scanning the generation's whole match list once per line.
    func searchMatches(
        for row: AgentChangesFileRow,
        in groupID: AgentChangesGroupID,
        locator: AgentChangesSearchLocator? = nil
    ) -> [AgentChangesSearchMatch] {
        guard let bucket = searchMatchIndex[rowKey(groupID: groupID, row: row)] else { return [] }
        guard let locator else { return bucket.all }
        return bucket.byLocatorKey[locator.stableKey] ?? []
    }

    private func rebuildSearchMatchIndex() {
        var index: [AgentChangesRowKey: RowSearchMatches] = [:]
        for match in searchState.matches {
            var bucket = index[match.rowKey] ?? RowSearchMatches()
            bucket.all.append(match)
            bucket.byLocatorKey[match.locator.stableKey, default: []].append(match)
            index[match.rowKey] = bucket
        }
        searchMatchIndex = index
    }

    func isCurrentSearchMatch(_ match: AgentChangesSearchMatch) -> Bool {
        searchState.selectedMatch?.id == match.id
    }

    private func cancelSearch(clearState: Bool) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        activeSearchCorpusKey = nil
        pendingNavigationMatchID = nil
        searchNavigationAnchor = nil
        searchExpandedFiles.removeAll()
        if clearState {
            searchState = .idle
        }
    }

    // MARK: - Worktree retry

    private func scheduleWorktreeRetryIfNeeded() {
        guard resolution?.isPreparing == true else {
            worktreeRetryTask?.cancel()
            worktreeRetryTask = nil
            return
        }
        guard worktreeRetryTask == nil else { return }

        let interval = worktreeRetryInterval
        let attempts = worktreeRetryAttempts
        worktreeRetryTask = Task { @MainActor [weak self, scheduler] in
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

    // MARK: - Work tracking and settlement

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        _ = trackedTask(operation)
    }

    @discardableResult
    private func trackedTask(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.workByID.removeValue(forKey: id)
        }
        workByID[id] = task
        return task
    }

    func settle() async {
        var passes = 0
        repeat {
            passes += 1
            for task in Array(workByID.values) {
                _ = await task.value
            }
            for slot in Array(slots.values) {
                _ = await slot.retargetTask?.value
                await slot.repository.waitUntilIdle()
            }
            await drainSnapshotDelivery()
        } while !workByID.isEmpty && passes < Self.maximumSettlePasses
    }

    private func drainSnapshotDelivery() async {
        while true {
            let targeted = slots.values.filter(\.isTargeted)
            var isCaughtUp = true
            for slot in targeted {
                let current = await slot.repository.currentSnapshot()
                if slot.snapshot != current {
                    isCaughtUp = false
                    break
                }
            }
            guard !isCaughtUp else { return }
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
