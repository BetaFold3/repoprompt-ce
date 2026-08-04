import Foundation
import OSLog

/// A view-model-owned, synchronously revocable epoch for index-mutation authority.
final class AgentChangesIndexMutationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isLive: Bool {
        lock.withLock { !revoked }
    }

    func revoke() {
        lock.withLock { revoked = true }
    }
}

/// Stores the current lease epoch behind one immutable per-slot reference.
final class AgentChangesIndexMutationLeaseSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current = AgentChangesIndexMutationLease()

    func replace() -> AgentChangesIndexMutationLease {
        lock.withLock {
            current.revoke()
            let next = AgentChangesIndexMutationLease()
            current = next
            return next
        }
    }

    func revoke() {
        lock.withLock { current.revoke() }
    }
}

/// The Changes panel's data controller: one per window, one active checkout at a time.
///
/// Three rules shape everything below.
///
/// **Porcelain decides membership.** A single `git status --porcelain=v2` read is the only thing
/// that says which section a file belongs to. Diff reads only enrich rows with line counts, and are
/// allowed to fail without failing the rebuild. Deriving Staged and Unstaged from two sequential
/// diff reads instead would let an agent's concurrent `git add` land between them and produce a
/// list where a file is in both sections, neither, or the wrong one.
///
/// **Refresh reads metadata, never patch text.** A rebuild produces the file list and its stats.
/// Patches are fetched per file, when the user expands one, and cached. Generating patch text for a
/// whole working tree on every filesystem event is the expensive part of a diff read, and the panel
/// renders at most a handful of expanded files.
///
/// **Latest wins, and stale never publishes.** Rebuilds are serialized; triggers that arrive during
/// one collapse into a single follow-up. Every build captures the generation it started at and
/// drops its result if a retarget bumped it, so switching tab, root, mode, or base can never be
/// overwritten by an in-flight read of the previous target.
actor AgentChangesRepository {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ChangesRepository")

    // MARK: - Configuration

    /// How long content deltas collect before one rebuild covers them.
    ///
    /// A batching window rather than a trailing debounce: an agent rewriting files continuously
    /// would keep pushing a trailing debounce out forever, so the panel would go quiet exactly
    /// while the most is happening. A fixed window bounds both the rebuild rate and the latency.
    private let contentDeltaWindow: Duration

    /// Largest patch rendered inline. Beyond it the panel offers the file instead.
    private let patchByteLimit: Int

    /// Largest number of body lines projected for one file.
    private let patchLineLimit: Int

    /// Largest source file read while revealing hidden context.
    private let fileContentByteLimit: Int

    /// Largest source line count eligible for in-panel context expansion.
    private let fileContentLineLimit: Int

    /// Delay before the single contention retry. Injected through the repository scheduler.
    private let indexLockRetryDelay: Duration

    // MARK: - Dependencies

    private let indexBackend: any AgentChangesIndexBackend
    private let diffSource: any AgentChangesDiffSource
    private let invalidationPublisher: any AgentChangesInvalidationPublishing
    private let scheduler: any AgentChangesScheduler
    private let makeTriggerFeed: @Sendable (AgentPanelResolvedCheckout) -> any AgentChangesTriggerFeed

    // MARK: - Target state

    private var target: AgentPanelResolvedCheckout?
    private var mode: AgentChangesCompareMode = .workingTree
    private var capabilities: VCSCapabilities?

    /// Bumped by every retarget. Builds carry the value they started at.
    private var generation: UInt64 = 0

    /// Monotonic request fence supplied by the view model so independently-scheduled retarget tasks
    /// cannot arrive out of order and restore an older checkout.
    private var latestTargetRequestID: UInt64 = 0
    private var mutationLease = AgentChangesIndexMutationLease()
    private var isShutdown = false

    private var snapshot: AgentChangesSnapshot = .empty
    private var observers: [UUID: AsyncStream<AgentChangesSnapshot>.Continuation] = [:]

    // MARK: - Refresh state

    /// What a completed rebuild observed, and the compare it observed it under.
    ///
    /// The compare travels with the fingerprint deliberately. A fingerprint is only comparable to
    /// another one read the same way — the backend normalizes compare specs differently, and
    /// `.unstaged`, `.uncommitted`, and `.uncommittedMergeBase` derive their base refs from
    /// different places — so storing the pair makes the gate self-consistent for any backend
    /// instead of relying on two call sites agreeing about which spec to name.
    private var lastGate: GateObservation?

    private struct GateObservation {
        let compare: GitDiffCompareSpec
        let fingerprint: GitDiffFingerprint
    }

    private var pendingRebuild: PendingRebuild?
    private var isDrainingRebuilds = false
    private var windowTask: Task<Void, Never>?
    private var windowBypassesFingerprintGate = false
    private var feed: (any AgentChangesTriggerFeed)?
    private var feedTask: Task<Void, Never>?
    private var isPollingDegraded = false

    private struct PendingRebuild {
        var bypassesFingerprintGate: Bool

        mutating func absorb(_ other: PendingRebuild) {
            bypassesFingerprintGate = bypassesFingerprintGate || other.bypassesFingerprintGate
        }
    }

    // MARK: - Content revisions

    /// Monotonic source for revision stamps.
    private var revisionCounter: UInt64 = 0

    /// Revision floor applied to every path, advanced by triggers that carry no path list.
    private var contentEpoch: UInt64 = 0

    /// Per-path revisions from scoped deltas, so editing one file does not evict every cached patch
    /// or invalidate a staging click queued against another.
    private var pathRevisions: [String: UInt64] = [:]

    /// Paths whose captured revision baselines still authorize a queued or running mutation.
    /// Reference counts keep overlapping mutations independent while their actor-FIFO waits overlap.
    private var activeMutationPathRefCounts: [String: Int] = [:]

    // MARK: - Patch cache

    private struct PatchCacheKey: Hashable {
        let checkoutPath: String
        let compareKey: String
        let fileKey: String
        let contextLines: Int
        let fingerprintKey: String
        let contentRevision: UInt64
    }

    private struct PatchCacheEntry {
        let document: FileDiffProjection.Document
        let renderedText: String
        let rawData: Data?
        let payloadFingerprintKey: String
    }

    private var patchCache: [PatchCacheKey: PatchCacheEntry] = [:]

    // MARK: - Partial review tokens

    private struct PatchReviewArtifact {
        let generation: UInt64
        let targetRequestID: UInt64
        let target: AgentPanelResolvedCheckout
        let mode: AgentChangesCompareMode
        let compare: GitDiffCompareSpec
        let snapshotFingerprintKey: String
        let payloadFingerprintKey: String
        let rowID: String
        let fileKey: String
        let identity: VCSIndexPathIdentity
        let section: AgentChangesSectionKind
        let contextLevel: AgentChangesContextLevel
        let contentRevision: UInt64
        let indexIdentity: MutationIndexIdentity
        let rawData: Data
        let parsedPatch: AgentChangesPartialPatchCompiler.ParsedPatch
        let visibleLineKeys: Set<AgentChangesDiffLineKey>
        /// The subset of `visibleLineKeys` a person may act on one line at a time.
        ///
        /// Hunks carrying a `\ No newline at end of file` annotation are excluded: git reads that
        /// annotation positionally, so recombining a subset of such a hunk's lines can move it
        /// mid-hunk and glue two lines together in the index. Those hunks stay whole-hunk-only,
        /// which preserves their bytes exactly.
        let selectableLineKeys: Set<AgentChangesDiffLineKey>
        let lineKeysByHunkID: [String: Set<AgentChangesDiffLineKey>]
        let action: AgentChangesPartialAction
        let cacheKey: PatchCacheKey
    }

    private struct MutationIndexIdentity: Equatable {
        let observationPaths: [String]
        let reviewedIdentities: [VCSIndexPathIdentity]
        let entries: [VCSIndexStatusEntry]
        let allowsConflictedEntries: Bool

        init?(
            observationPaths: [String],
            reviewedIdentities: [VCSIndexPathIdentity],
            entries: [VCSIndexStatusEntry],
            allowsConflictedEntries: Bool = false
        ) {
            self.observationPaths = Array(Set(observationPaths)).sorted()
            self.reviewedIdentities = Array(Set(reviewedIdentities)).sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return ($0.originalPath ?? "") < ($1.originalPath ?? "")
            }
            let reviewedIdentitySet = Set(self.reviewedIdentities)
            let selectedEntries = entries
                .filter { reviewedIdentitySet.contains($0.identity) }
                .sorted { lhs, rhs in
                    if lhs.path != rhs.path { return lhs.path < rhs.path }
                    return (lhs.originalPath ?? "") < (rhs.originalPath ?? "")
                }
            guard selectedEntries.count == reviewedIdentitySet.count else { return nil }
            guard allowsConflictedEntries || selectedEntries.allSatisfy({
                !$0.isConflicted && $0.isMutationIdentityRepresentable
            }) else { return nil }
            self.entries = selectedEntries
            self.allowsConflictedEntries = allowsConflictedEntries
        }
    }

    private var patchReviewArtifacts: [AgentChangesPatchReviewToken: PatchReviewArtifact] = [:]
    /// A compiler/backend invalidity is deterministic for these exact reviewed bytes. Keeping the
    /// file-level action available while suppressing another identical token avoids a retry loop.
    private var disabledPartialDescriptorReasons: [
        PatchCacheKey: AgentChangesPartialStagingUnavailableReason
    ] = [:]

    // MARK: - Search cache

    private static let searchCacheByteLimit = 8 * 1024 * 1024
    private static let searchCacheDocumentLimit = 64

    private struct SearchCacheKey: Hashable {
        let checkoutPath: String
        let compareKey: String
        let fileKey: String
        let fingerprintKey: String
        let contentRevision: UInt64
    }

    private struct SearchCacheEntry {
        let document: FileDiffProjection.Document
        let byteCount: Int
        let access: UInt64
    }

    private var searchCache: [SearchCacheKey: SearchCacheEntry] = [:]
    private var searchCacheAccess: UInt64 = 0
    private var searchCacheBytes = 0

    /// Source cache key intentionally follows the Phase-2 contract exactly. Different source
    /// versions (worktree/index/ref) share one bucket under the file key rather than widening the
    /// key and allowing duplicate checkout/fingerprint/file entries.
    private struct FileContentCacheKey: Hashable {
        let checkoutPath: String
        let fingerprintKey: String
        let fileKey: String
    }

    private var fileContentCache: [
        FileContentCacheKey: [AgentChangesFileContentSource: AgentChangesFileContent]
    ] = [:]

    // MARK: - Serialization gates

    private var isMutating = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private var isRebuilding = false
    private var rebuildWaiters: [CheckedContinuation<Void, Never>] = []

    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Init

    init(
        indexBackend: any AgentChangesIndexBackend = AgentChangesLiveIndexBackend(),
        diffSource: any AgentChangesDiffSource = AgentChangesLiveDiffSource(),
        invalidationPublisher: any AgentChangesInvalidationPublishing = AgentChangesLiveInvalidationPublisher(),
        scheduler: any AgentChangesScheduler = AgentChangesLiveScheduler(),
        contentDeltaWindow: Duration = .milliseconds(300),
        patchByteLimit: Int = 2 * 1024 * 1024,
        patchLineLimit: Int = 4000,
        fileContentByteLimit: Int = 2 * 1024 * 1024,
        fileContentLineLimit: Int = 4000,
        indexLockRetryDelay: Duration = .milliseconds(150),
        makeTriggerFeed: (@Sendable (AgentPanelResolvedCheckout) -> any AgentChangesTriggerFeed)? = nil
    ) {
        self.indexBackend = indexBackend
        self.diffSource = diffSource
        self.invalidationPublisher = invalidationPublisher
        self.scheduler = scheduler
        self.contentDeltaWindow = contentDeltaWindow
        self.patchByteLimit = patchByteLimit
        self.patchLineLimit = patchLineLimit
        self.fileContentByteLimit = fileContentByteLimit
        self.fileContentLineLimit = fileContentLineLimit
        self.indexLockRetryDelay = indexLockRetryDelay
        self.makeTriggerFeed = makeTriggerFeed ?? { checkout in
            AgentChangesLiveTriggerFeed(
                sources: AgentChangesTriggerSources(
                    metadataEvents: AgentChangesTriggerSources.metadataEvents(forCheckout: checkout.checkoutURL),
                    reconcilePulses: AgentChangesTriggerSources.appActivationPulses()
                ),
                // The default repository has no workspace-store publisher to borrow. Give it a
                // scoped source instead; if creation fails, the feed emits polls and the snapshot
                // becomes observably degraded rather than silently freezing.
                scopedWatchPaths: Self.defaultScopedWatchPaths(for: checkout)
            )
        }
    }

    nonisolated static func defaultScopedWatchPaths(
        for checkout: AgentPanelResolvedCheckout
    ) -> [URL] {
        [checkout.checkoutURL]
    }

    // MARK: - Observation

    /// Snapshots for this window, current value first.
    ///
    /// Multi-subscriber by construction: the panel, a footer, and a test can all observe without
    /// one of them silently consuming another's events.
    func snapshots() -> AsyncStream<AgentChangesSnapshot> {
        let id = UUID()
        let current = snapshot
        return AsyncStream { continuation in
            continuation.yield(current)
            guard !isShutdown else {
                continuation.finish()
                return
            }
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func currentSnapshot() -> AgentChangesSnapshot {
        snapshot
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish(_ next: AgentChangesSnapshot) {
        guard !isShutdown else { return }
        snapshot = next
        for continuation in observers.values {
            continuation.yield(next)
        }
    }

    // MARK: - Targeting

    /// Points the panel at a checkout and compare mode.
    ///
    /// Retargeting is the cancellation boundary. Everything keyed to the old target — pending
    /// rebuilds, the batching window, cached patches, the fingerprint gate, the degraded-poll flag —
    /// is dropped, and the generation bump guarantees any read still in flight cannot publish.
    func setTarget(
        _ newTarget: AgentPanelResolvedCheckout?,
        mode newMode: AgentChangesCompareMode,
        requestID: UInt64? = nil,
        mutationLease newMutationLease: AgentChangesIndexMutationLease? = nil
    ) {
        defer { signalIdleIfNeeded() }
        guard !isShutdown, !Task.isCancelled else { return }

        let previousTargetRequestID = latestTargetRequestID
        if let requestID {
            guard requestID >= latestTargetRequestID else { return }
            latestTargetRequestID = requestID
        }
        mutationLease.revoke()
        mutationLease = newMutationLease ?? AgentChangesIndexMutationLease()
        guard newTarget != target || newMode != mode else {
            if latestTargetRequestID != previousTargetRequestID {
                patchReviewArtifacts.removeAll()
                publish(AgentChangesSnapshot(
                    generation: snapshot.generation,
                    targetRequestID: latestTargetRequestID,
                    target: snapshot.target,
                    mode: snapshot.mode,
                    sections: snapshot.sections,
                    loadState: snapshot.loadState,
                    supportsStaging: snapshot.supportsStaging,
                    hasHeadCommit: snapshot.hasHeadCommit,
                    isPollingDegraded: snapshot.isPollingDegraded,
                    contentEpoch: snapshot.contentEpoch,
                    fingerprint: snapshot.fingerprint
                ))
            }
            return
        }

        generation &+= 1
        target = newTarget
        mode = newMode
        capabilities = nil
        lastGate = nil
        pendingRebuild = nil
        isPollingDegraded = false
        windowTask?.cancel()
        windowTask = nil
        windowBypassesFingerprintGate = false
        patchCache.removeAll()
        patchReviewArtifacts.removeAll()
        disabledPartialDescriptorReasons.removeAll()
        clearSearchCache()
        fileContentCache.removeAll()
        pathRevisions.removeAll()

        stopFeed()

        publish(AgentChangesSnapshot(
            generation: generation,
            targetRequestID: latestTargetRequestID,
            target: newTarget,
            mode: newMode,
            sections: [],
            loadState: .initial,
            supportsStaging: false,
            hasHeadCommit: true,
            isPollingDegraded: false,
            contentEpoch: contentEpoch,
            fingerprint: nil
        ))

        guard let newTarget else { return }
        startFeed(for: newTarget)
        enqueueRebuild(bypassingFingerprintGate: true)
    }

    /// Tears down the feed and permanently closes the repository. Call before releasing it.
    func shutdown() {
        guard !isShutdown else { return }
        mutationLease.revoke()
        isShutdown = true
        generation &+= 1
        target = nil
        capabilities = nil
        lastGate = nil
        stopFeed()
        windowTask?.cancel()
        windowTask = nil
        pendingRebuild = nil
        windowBypassesFingerprintGate = false
        patchCache.removeAll()
        patchReviewArtifacts.removeAll()
        disabledPartialDescriptorReasons.removeAll()
        clearSearchCache()
        fileContentCache.removeAll()
        pathRevisions.removeAll()
        snapshot = AgentChangesSnapshot(
            generation: generation,
            targetRequestID: latestTargetRequestID,
            target: nil,
            mode: mode,
            sections: [],
            loadState: .initial,
            supportsStaging: false,
            hasHeadCommit: true,
            isPollingDegraded: false,
            contentEpoch: contentEpoch,
            fingerprint: nil
        )
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        for continuation in observers.values {
            continuation.finish()
        }
        observers.removeAll()
    }

    private func startFeed(for checkout: AgentPanelResolvedCheckout) {
        guard !isShutdown else { return }
        let feed = makeTriggerFeed(checkout)
        self.feed = feed
        let feedGeneration = generation
        feedTask = Task { [weak self] in
            for await trigger in feed.events() {
                guard let self else { return }
                await handleFeedTrigger(trigger, generation: feedGeneration)
            }
        }
    }

    private func stopFeed() {
        feedTask?.cancel()
        feedTask = nil
        feed?.cancel()
        feed = nil
    }

    /// Triggers from a feed that outlived its target are dropped rather than applied to the new one.
    private func handleFeedTrigger(_ trigger: AgentChangesRefreshTrigger, generation feedGeneration: UInt64) {
        guard !isShutdown, feedGeneration == generation else { return }
        refresh(trigger)
    }

    // MARK: - Triggers

    /// Applies one refresh trigger.
    ///
    /// The gating decisions live on ``AgentChangesRefreshTrigger`` itself; this method is the
    /// mechanism, not the policy.
    func refresh(_ trigger: AgentChangesRefreshTrigger) {
        guard !isShutdown, let target else { return }

        if case .poll = trigger, !isPollingDegraded {
            // The poll only exists because a watcher could not be created, so its first arrival is
            // how this actor learns the checkout is running degraded.
            isPollingDegraded = true
        }

        if case let .contentDelta(paths) = trigger, !paths.isEmpty {
            let scoped = inScopeRepositoryRelativePaths(paths, target: target)
            guard !scoped.isEmpty else {
                // Every reported path is outside this checkout, or outside the pathspec scope the
                // workspace represents. Nothing here changed.
                return
            }
            if trigger.advancesContentRevision {
                advanceContentRevision(forRepositoryRelativePaths: scoped)
            }
            scheduleWindowedRebuild(bypassingFingerprintGate: trigger.bypassesFingerprintGate)
            return
        }

        if trigger.advancesContentRevision {
            advanceContentEpoch()
        }

        if case .contentDelta = trigger {
            // A path-less content delta is a watcher gap or resync: the tree moved but the watcher
            // cannot say where, which the epoch bump above already accounted for.
            scheduleWindowedRebuild(bypassingFingerprintGate: trigger.bypassesFingerprintGate)
            return
        }

        enqueueRebuild(bypassingFingerprintGate: trigger.bypassesFingerprintGate)
    }

    /// Waits until no rebuild is running, queued, or waiting out a content-delta window.
    ///
    /// Exists for callers that need a settled snapshot — a mutation's caller, and tests — without
    /// polling for one.
    func waitUntilIdle() async {
        guard !isShutdown, !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private var isIdle: Bool {
        !isDrainingRebuilds && !isRebuilding && pendingRebuild == nil && windowTask == nil
    }

    private func signalIdleIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Content revisions

    /// The revision a path is currently at.
    ///
    /// The epoch is a floor rather than a separate concept: a trigger that cannot name paths
    /// invalidates all of them at once, and a scoped delta lifts one path above it.
    private func contentRevision(forRepositoryRelativePath path: String) -> UInt64 {
        max(contentEpoch, pathRevisions[path] ?? 0)
    }

    private func advanceContentEpoch() {
        revisionCounter &+= 1
        contentEpoch = revisionCounter
        pathRevisions.removeAll()
        patchCache.removeAll()
        patchReviewArtifacts.removeAll()
        disabledPartialDescriptorReasons.removeAll()
        clearSearchCache()
        fileContentCache.removeAll()
    }

    private func advanceContentRevision(forRepositoryRelativePaths paths: Set<String>) {
        revisionCounter &+= 1
        for path in paths {
            pathRevisions[path] = revisionCounter
        }
        // Cached patches for untouched files stay valid; only the edited files lose theirs.
        patchCache = patchCache.filter { key, _ in
            key.contentRevision == contentRevision(forRepositoryRelativePath: key.fileKey)
        }
        patchReviewArtifacts = patchReviewArtifacts.filter { _, artifact in
            !paths.contains(artifact.fileKey)
        }
        disabledPartialDescriptorReasons = disabledPartialDescriptorReasons.filter {
            !paths.contains($0.key.fileKey)
        }
        removeSearchCacheEntries(for: paths)
        fileContentCache = fileContentCache.filter { key, _ in
            !paths.contains(key.fileKey)
        }
    }

    /// Keep per-path revision state bounded to paths that still back visible rows or cache entries.
    private func prunePathRevisions(renderedSections: [AgentChangesSection]) {
        var retained = Set(renderedSections.flatMap { section in
            section.rows.flatMap(\.identity.mutationPaths)
        })
        retained.formUnion(patchCache.keys.map(\.fileKey))
        retained.formUnion(fileContentCache.keys.map(\.fileKey))
        retained.formUnion(activeMutationPathRefCounts.keys)
        pathRevisions = pathRevisions.filter { retained.contains($0.key) }
    }

    private func registerActiveMutationPaths(_ paths: [String]) {
        for path in Set(paths) {
            activeMutationPathRefCounts[path, default: 0] += 1
        }
    }

    private func unregisterActiveMutationPaths(_ paths: [String]) {
        for path in Set(paths) {
            guard let count = activeMutationPathRefCounts[path] else { continue }
            if count == 1 {
                activeMutationPathRefCounts.removeValue(forKey: path)
            } else {
                activeMutationPathRefCounts[path] = count - 1
            }
        }
    }

    /// Maps absolute event paths onto the repository-relative paths this target represents.
    private func inScopeRepositoryRelativePaths(
        _ absolutePaths: Set<String>,
        target: AgentPanelResolvedCheckout
    ) -> Set<String> {
        var scoped: Set<String> = []
        for absolute in absolutePaths {
            guard let relative = AgentPanelCheckoutResolver.repositoryRelativePath(
                of: URL(fileURLWithPath: absolute),
                underRepositoryRoot: target.checkoutURL
            ), !relative.isEmpty else { continue }
            guard relative != ".git", !relative.hasPrefix(".git/") else { continue }
            guard target.containsRepositoryRelativePath(relative) else { continue }
            scoped.insert(relative)
        }
        return scoped
    }

    // MARK: - Rebuild loop

    /// Opens, or joins, the batching window that one rebuild will cover.
    ///
    /// The window carries the gating policy of the triggers that opened it rather than assuming
    /// one, so the rule declared on ``AgentChangesRefreshTrigger`` is the rule that actually runs.
    private func scheduleWindowedRebuild(bypassingFingerprintGate bypass: Bool) {
        guard !isShutdown else { return }
        windowBypassesFingerprintGate = windowBypassesFingerprintGate || bypass
        guard windowTask == nil else { return }
        let scheduler = scheduler
        let window = contentDeltaWindow
        windowTask = Task { [weak self] in
            try? await scheduler.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.flushContentDeltaWindow()
        }
    }

    private func flushContentDeltaWindow() {
        windowTask = nil
        guard !isShutdown else {
            signalIdleIfNeeded()
            return
        }
        let bypass = windowBypassesFingerprintGate
        windowBypassesFingerprintGate = false
        guard target != nil else {
            signalIdleIfNeeded()
            return
        }
        enqueueRebuild(bypassingFingerprintGate: bypass)
    }

    private func enqueueRebuild(bypassingFingerprintGate bypass: Bool) {
        guard !isShutdown else { return }
        let incoming = PendingRebuild(bypassesFingerprintGate: bypass)
        if pendingRebuild != nil {
            pendingRebuild?.absorb(incoming)
        } else {
            pendingRebuild = incoming
        }
        guard !isDrainingRebuilds else {
            // Latest wins: the running drain will pick this up when it finishes, so a burst of
            // triggers costs one extra read rather than one read each.
            return
        }
        Task { [weak self] in await self?.drainRebuilds() }
    }

    private func drainRebuilds() async {
        guard !isShutdown, !isDrainingRebuilds else { return }
        isDrainingRebuilds = true
        while let pending = takePendingRebuild() {
            await performRebuild(bypassingFingerprintGate: pending.bypassesFingerprintGate)
        }
        isDrainingRebuilds = false
        signalIdleIfNeeded()
    }

    private func takePendingRebuild() -> PendingRebuild? {
        defer { pendingRebuild = nil }
        return pendingRebuild
    }

    private func performRebuild(bypassingFingerprintGate bypass: Bool) async {
        await acquireRebuildGate()
        defer { releaseRebuildGate() }

        guard !isShutdown, let target else { return }
        let buildGeneration = generation
        let buildMode = mode

        if !bypass, await isGatedOut(target: target) {
            return
        }

        do {
            let capabilities = await resolveCapabilities(for: target)
            let build = try await buildSections(target: target, mode: buildMode, capabilities: capabilities)
            // Retargeting during the reads above makes this result describe a checkout nobody is
            // looking at any more. Dropping it here is what keeps a slow read of the previous tab
            // from overwriting the current one.
            guard !isShutdown, buildGeneration == generation else { return }

            let nextFingerprintKey = build.fingerprint.map(Self.fingerprintKey) ?? ""
            if nextFingerprintKey != snapshot.fingerprintKey {
                patchCache.removeAll()
                patchReviewArtifacts.removeAll()
                disabledPartialDescriptorReasons.removeAll()
                clearSearchCache()
            }

            if let fingerprint = build.fingerprint {
                lastGate = GateObservation(compare: build.gateCompare, fingerprint: fingerprint)
            } else {
                // No comparable observation means the next `.metadata` trigger must rebuild rather
                // than compare against something that was never read.
                lastGate = nil
            }

            prunePathRevisions(renderedSections: build.sections)
            publish(AgentChangesSnapshot(
                generation: buildGeneration,
                targetRequestID: latestTargetRequestID,
                target: target,
                mode: buildMode,
                sections: build.sections,
                loadState: .ready,
                supportsStaging: capabilities.supportsStaging
                    && buildMode.allowsStaging
                    && target.isMutationScopeRepresentable,
                hasHeadCommit: build.hasHeadCommit,
                isPollingDegraded: isPollingDegraded,
                contentEpoch: contentEpoch,
                fingerprint: build.fingerprint
            ))
        } catch {
            guard !isShutdown, buildGeneration == generation else { return }
            Self.logger.warning(
                """
                Changes rebuild failed for \(target.checkoutURL.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            publish(AgentChangesSnapshot(
                generation: buildGeneration,
                targetRequestID: latestTargetRequestID,
                target: target,
                mode: buildMode,
                sections: snapshot.generation == buildGeneration ? snapshot.sections : [],
                loadState: .failed(error.localizedDescription),
                supportsStaging: snapshot.supportsStaging,
                hasHeadCommit: snapshot.hasHeadCommit,
                isPollingDegraded: isPollingDegraded,
                contentEpoch: contentEpoch,
                fingerprint: snapshot.fingerprint
            ))
        }
    }

    /// Whether a `.metadata` trigger can be dropped without rebuilding.
    ///
    /// This is the only trigger worth gating. `.git` metadata events fire for ref writes, index
    /// refreshes, gc, and packed-refs rewrites, most of which change nothing a reviewer can see, and
    /// one fingerprint read is cheaper than the porcelain plus two numstat reads it prevents.
    ///
    /// Every other trigger bypasses it, for three reasons worth stating plainly:
    ///
    /// 1. A content delta means the filesystem has *already* told us a file inside this checkout
    ///    changed. Asking Git to confirm what FSEvents just reported doubles the work on the hot
    ///    path — the path that fires continuously while an agent edits.
    /// 2. Section membership, which is what porcelain decides, is invariant under re-editing a file
    ///    that is already modified: the XY pair stays `.M` and the Staged/Unstaged lists come back
    ///    byte-identical. Only that file's *patch* moved, and patches are invalidated by the content
    ///    revision, not by this gate.
    /// 3. The fingerprint read needs a resolvable HEAD, so it throws in a repository whose first
    ///    commit has not landed. A gate that can fail must fail open, and one that fires on every
    ///    content change must not be able to freeze a fresh repository's panel.
    private func isGatedOut(target: AgentPanelResolvedCheckout) async -> Bool {
        guard let lastGate else { return false }
        guard let current = try? await diffSource.fingerprint(
            compare: lastGate.compare,
            at: target.checkoutURL
        ) else {
            // Fail open: an unreadable fingerprint is not evidence that nothing changed.
            return false
        }
        return current == lastGate.fingerprint
    }

    private func resolveCapabilities(for target: AgentPanelResolvedCheckout) async -> VCSCapabilities {
        if let capabilities { return capabilities }
        let requestedGeneration = generation
        let resolved = await indexBackend.capabilities(at: target.checkoutURL)
        guard requestedGeneration == generation, self.target == target else {
            return resolved
        }
        capabilities = resolved
        return resolved
    }

    // MARK: - Revision validation

    /// Resolve a candidate against the checkout before tab state accepts it as a compare target.
    func validateRevision(
        _ revision: String,
        at target: AgentPanelResolvedCheckout
    ) async -> AgentChangesRevisionValidation {
        guard !isShutdown else { return .invalid("The changes repository is no longer available.") }
        return await diffSource.resolveRevision(revision, at: target.checkoutURL)
    }

    // MARK: - Section building

    private struct SectionBuild {
        let sections: [AgentChangesSection]
        /// The compare ``fingerprint`` was read under, so the gate re-reads the same one.
        let gateCompare: GitDiffCompareSpec
        let fingerprint: GitDiffFingerprint?
        let hasHeadCommit: Bool
    }

    private func buildSections(
        target: AgentPanelResolvedCheckout,
        mode: AgentChangesCompareMode,
        capabilities: VCSCapabilities
    ) async throws -> SectionBuild {
        if case let .vsBase(base) = mode {
            return try await buildFlatSection(
                kind: .vsBase,
                compare: .uncommittedMergeBase(base: base),
                target: target
            )
        }
        guard capabilities.supportsStaging else {
            // Backends without an index have one working copy and nothing to stage into, so the
            // panel shows one list. No throwing staging path is reachable from here.
            return try await buildFlatSection(
                kind: .workingCopy,
                compare: .uncommitted(base: "HEAD"),
                target: target
            )
        }
        return try await buildWorkingTreeSections(target: target)
    }

    /// Porcelain-first decomposition into Staged / Unstaged / Conflicts.
    private func buildWorkingTreeSections(
        target: AgentPanelResolvedCheckout
    ) async throws -> SectionBuild {
        let entries = try await indexBackend.loadIndexStatus(at: target.checkoutURL)
            .filter { target.containsRepositoryRelativePath($0.path) }

        // Unborn HEAD is a normal state for a fresh repository, not an error. Membership does not
        // need HEAD, so the panel stays useful; only the staged diff read is skipped, because there
        // is no tree to diff against.
        let hasHeadCommit = await (try? indexBackend.hasHeadCommit(at: target.checkoutURL)) ?? true

        let checkout = target.checkoutURL
        let pathspecs = target.pathspecPrefixes
        async let stagedTask = hasHeadCommit
            ? readMetadata(compare: .staged(base: "HEAD"), pathspecs: pathspecs, at: checkout)
            : nil
        async let unstagedTask = readMetadata(compare: .unstaged, pathspecs: pathspecs, at: checkout)
        let stagedStats = await statsByPath(stagedTask)
        let unstagedMetadata = await unstagedTask
        let unstagedStats = statsByPath(unstagedMetadata)

        var staged: [AgentChangesFileRow] = []
        var unstaged: [AgentChangesFileRow] = []
        var conflicts: [AgentChangesFileRow] = []

        for entry in entries {
            if entry.isConflicted {
                conflicts.append(row(
                    for: entry,
                    section: .conflicts,
                    stats: nil,
                    hasCounterpart: false,
                    target: target
                ))
                continue
            }
            // A partially-staged file is genuinely in both sections: `git diff --cached` and
            // `git diff` show different patches of it, and hiding either would misrepresent what
            // committing right now would capture.
            let isStaged = entry.hasStagedChange
            let isUnstaged = entry.hasWorkTreeChange
            let dual = isStaged && isUnstaged
            if isStaged {
                staged.append(row(
                    for: entry,
                    section: .staged,
                    stats: stagedStats[entry.path],
                    hasCounterpart: dual,
                    target: target
                ))
            }
            if isUnstaged {
                unstaged.append(row(
                    for: entry,
                    section: .unstaged,
                    stats: unstagedStats[entry.path],
                    hasCounterpart: dual,
                    target: target
                ))
            }
        }

        return SectionBuild(
            sections: [
                AgentChangesSection(kind: .staged, rows: staged),
                AgentChangesSection(kind: .unstaged, rows: unstaged),
                AgentChangesSection(kind: .conflicts, rows: conflicts)
            ],
            // `.unstaged` is the widest cheap observation available here: its fingerprint hashes the
            // whole porcelain output plus HEAD, so it moves for staged-only changes and commits too.
            gateCompare: .unstaged,
            fingerprint: unstagedMetadata?.fingerprint,
            hasHeadCommit: hasHeadCommit
        )
    }

    /// The single read-only list used by vs-Base mode and by backends without an index.
    private func buildFlatSection(
        kind: AgentChangesSectionKind,
        compare: GitDiffCompareSpec,
        target: AgentPanelResolvedCheckout
    ) async throws -> SectionBuild {
        let metadata = try await diffSource.loadMetadata(
            compare: compare,
            pathspecs: target.pathspecPrefixes,
            at: target.checkoutURL
        )
        let rows = metadata.files
            .filter { target.containsRepositoryRelativePath($0.path) }
            .map { file in
                AgentChangesFileRow(
                    id: AgentChangesFileRow.makeID(section: kind, fileKey: file.path),
                    fileKey: file.path,
                    path: file.path,
                    originalPath: nil,
                    section: kind,
                    indexStatus: nil,
                    workTreeStatus: file.status.first,
                    isUntracked: file.status == "??",
                    isConflicted: file.status == "U",
                    additions: file.additions,
                    deletions: file.deletions,
                    hasCounterpartSection: false,
                    contentRevision: contentRevision(forRepositoryRelativePath: file.path)
                )
            }
        return SectionBuild(
            sections: [AgentChangesSection(kind: kind, rows: rows)],
            gateCompare: compare,
            fingerprint: metadata.fingerprint,
            hasHeadCommit: true
        )
    }

    private func row(
        for entry: VCSIndexStatusEntry,
        section: AgentChangesSectionKind,
        stats: VCSUncommittedFile?,
        hasCounterpart: Bool,
        target: AgentPanelResolvedCheckout
    ) -> AgentChangesFileRow {
        AgentChangesFileRow(
            id: AgentChangesFileRow.makeID(section: section, fileKey: entry.path),
            fileKey: entry.path,
            path: entry.path,
            originalPath: entry.originalPath,
            section: section,
            indexStatus: entry.indexStatus,
            workTreeStatus: entry.workTreeStatus,
            headMode: entry.headMode,
            indexMode: entry.indexMode,
            headOID: entry.headOID,
            indexOID: entry.indexOID,
            repositoryHeadIdentity: entry.repositoryHeadIdentity,
            isMutationIdentityRepresentable: entry.isMutationIdentityRepresentable,
            isUntracked: entry.isUntracked,
            isConflicted: entry.isConflicted,
            additions: stats?.additions,
            deletions: stats?.deletions,
            hasCounterpartSection: hasCounterpart,
            contentRevision: contentRevision(forRepositoryRelativePath: entry.path),
            isMutationScopeSafe: identityIsInsideMutationScope(entry.identity, target: target)
        )
    }

    private func identityIsInsideMutationScope(
        _ identity: VCSIndexPathIdentity,
        target: AgentPanelResolvedCheckout
    ) -> Bool {
        target.isMutationScopeRepresentable
            && identity.mutationPaths.allSatisfy(target.containsRepositoryRelativePath)
    }

    /// A metadata read that reports failure as absence.
    ///
    /// Deliberately non-throwing and `nonisolated`: porcelain has already decided which files
    /// exist, so a diff read that fails costs the rows their line counts rather than their place in
    /// the list — and running outside the actor lets the staged and unstaged reads overlap instead
    /// of queuing behind each other.
    private nonisolated func readMetadata(
        compare: GitDiffCompareSpec,
        pathspecs: [String],
        at checkout: URL
    ) async -> AgentChangesDiffMetadata? {
        try? await diffSource.loadMetadata(compare: compare, pathspecs: pathspecs, at: checkout)
    }

    private nonisolated func statsByPath(
        _ metadata: AgentChangesDiffMetadata?
    ) -> [String: VCSUncommittedFile] {
        guard let metadata else { return [:] }
        return Dictionary(metadata.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Patches

    /// The patch for one row, at one context width.
    ///
    /// Cached under the checkout, compare, file, width, fingerprint, and the file's content
    /// revision. The last two are what make the cache safe: the fingerprint covers index and HEAD
    /// movement, and the content revision covers an edit that leaves porcelain's answer unchanged.
    func patch(
        for row: AgentChangesFileRow,
        contextLevel: AgentChangesContextLevel = .standard
    ) async -> AgentChangesPatchLoadState {
        guard !isShutdown else {
            return .unavailable(.failed("The changes repository is no longer available."))
        }
        guard let target else { return .unavailable(.failed("No checkout is selected.")) }
        let requestedGeneration = generation
        let requestedMode = mode
        let requestedContentRevision = contentRevision(forRepositoryRelativePath: row.fileKey)
        let requestedFingerprintKey = snapshot.fingerprintKey

        if row.section == .staged, !snapshot.hasHeadCommit {
            return .unavailable(.unbornHead)
        }

        let compare = row.section.compareSpec(mode: mode)
        let fingerprintKey = requestedFingerprintKey
        let key = PatchCacheKey(
            checkoutPath: target.checkoutURL.path,
            compareKey: compare.rawKey,
            fileKey: row.fileKey,
            contextLines: contextLevel.contextLines,
            fingerprintKey: fingerprintKey,
            contentRevision: requestedContentRevision
        )
        if let cached = patchCache[key] {
            return .loaded(cached.document)
        }

        let payload: AgentChangesPatchPayload?
        do {
            payload = try await diffSource.loadPatch(
                compare: compare,
                paths: row.identity.allPaths,
                at: target.checkoutURL,
                contextLines: contextLevel.contextLines
            )
        } catch {
            return .unavailable(.failed(error.localizedDescription))
        }

        guard !isShutdown,
              requestedGeneration == generation,
              target == self.target,
              requestedMode == mode,
              requestedContentRevision == contentRevision(forRepositoryRelativePath: row.fileKey),
              requestedFingerprintKey == snapshot.fingerprintKey
        else {
            return .unavailable(.failed("The checkout changed while the patch was loading."))
        }

        guard let payload,
              let selectedPatch = Self.selectedPatch(from: payload, fileKey: row.fileKey)
        else { return .unavailable(.noTextualDiff) }
        let text = selectedPatch.text

        let byteCount = text.utf8.count
        guard byteCount <= patchByteLimit else {
            return .unavailable(.tooLarge(bytes: byteCount))
        }

        let document = DiffLineProjector.project(
            patch: text,
            fileKey: row.fileKey,
            contextLevel: contextLevel.projectionLevel,
            isUntracked: row.isUntracked,
            maxLines: patchLineLimit,
            computesIntralineDiffs: true,
            oldSourceReference: payload.oldSourceReference
        )
        patchCache[key] = PatchCacheEntry(
            document: document,
            renderedText: text,
            rawData: selectedPatch.rawData,
            payloadFingerprintKey: Self.fingerprintKey(payload.fingerprint)
        )
        return .loaded(document)
    }

    /// Mints a review token only when this document is the exact cached visible patch.
    ///
    /// Expanded-gap documents cannot satisfy the equality check because the cache retains only the
    /// Git projection. That keeps rendering-only context out of every apply artifact by construction.
    func partialStagingDescriptor(
        for row: AgentChangesFileRow,
        renderedDocument: FileDiffProjection.Document,
        contextLevel: AgentChangesContextLevel
    ) -> AgentChangesPartialStagingDescriptor {
        guard !isShutdown else {
            return .unavailable(.rawPatchUnavailable)
        }
        let action: AgentChangesPartialAction? = switch row.section {
        case .unstaged: .stage
        case .staged: .unstage
        case .conflicts, .vsBase, .workingCopy: nil
        }

        guard mode.allowsStaging else {
            return .unavailable(.readOnlyCompare, action: action)
        }
        guard snapshot.supportsStaging else {
            return .unavailable(.backendHasNoIndex, action: action)
        }
        guard let action else {
            return .unavailable(.readOnlyCompare)
        }
        guard let target,
              snapshot.targetRequestID == latestTargetRequestID,
              snapshot.target == target,
              snapshot.loadState == .ready,
              snapshot.sections.contains(where: { $0.rows.contains(row) })
        else {
            return .unavailable(.rawPatchUnavailable, action: action)
        }
        guard target.isMutationScopeRepresentable,
              row.isMutationScopeSafe,
              identityIsInsideMutationScope(row.identity, target: target)
        else {
            return .unavailable(.unsafeScope, action: action)
        }
        guard !row.isConflicted else {
            return .unavailable(.conflicted, action: action)
        }
        guard !row.isUntracked else {
            return .unavailable(.untrackedRequiresWholeFile, action: action)
        }
        guard row.originalPath == nil || row.originalPath == row.path else {
            return .unavailable(.structuralChange, action: action)
        }
        switch row.section {
        case .staged where row.indexStatus != "M",
             .unstaged where row.workTreeStatus != "M":
            return .unavailable(.structuralChange, action: action)
        default:
            break
        }
        guard renderedDocument.truncation == nil else {
            return .unavailable(.truncatedProjection, action: action)
        }
        switch renderedDocument.change {
        case .modified:
            break
        case .added, .deleted:
            return .unavailable(.addedOrDeletedFile, action: action)
        case .untracked:
            return .unavailable(.untrackedRequiresWholeFile, action: action)
        case .binary, .submodule:
            return .unavailable(.binaryOrSubmodule, action: action)
        case .conflicted:
            return .unavailable(.conflicted, action: action)
        case .modeOnly, .renamed, .copied:
            return .unavailable(.structuralChange, action: action)
        }

        let compare = row.section.compareSpec(mode: mode)
        let key = PatchCacheKey(
            checkoutPath: target.checkoutURL.path,
            compareKey: compare.rawKey,
            fileKey: row.fileKey,
            contextLines: contextLevel.contextLines,
            fingerprintKey: snapshot.fingerprintKey,
            contentRevision: row.contentRevision
        )
        if let disabledReason = disabledPartialDescriptorReasons[key] {
            return .unavailable(disabledReason, action: action)
        }
        guard let cached = patchCache[key],
              cached.document == renderedDocument,
              let rawData = cached.rawData,
              Data(cached.renderedText.utf8) == rawData
        else {
            return .unavailable(.rawPatchUnavailable, action: action)
        }

        let parsed: AgentChangesPartialPatchCompiler.ParsedPatch
        do {
            parsed = try AgentChangesPartialPatchCompiler.parse(
                rawData,
                expectedPath: row.fileKey,
                byteLimit: patchByteLimit
            )
        } catch {
            let reason = Self.partialStagingUnavailableReason(for: error)
            disabledPartialDescriptorReasons[key] = reason
            return .unavailable(reason, action: action)
        }

        guard let crossChecked = Self.crossCheckedLineKeys(
            document: renderedDocument,
            parsedPatch: parsed
        ) else {
            return .unavailable(.malformedPatch, action: action)
        }
        let lineKeysByHunkID = crossChecked.lineKeysByHunkID
        let visibleLineKeys = Set(lineKeysByHunkID.values.joined())
        guard !visibleLineKeys.isEmpty else {
            return .unavailable(.malformedPatch, action: action)
        }
        // Annotated hunks keep their hunk button and their reviewed line set, but offer no per-line
        // selection: only whole-hunk staging replays their bytes verbatim.
        let selectableLineKeys = Set(
            lineKeysByHunkID
                .filter { !crossChecked.annotatedHunkIDs.contains($0.key) }
                .values
                .joined()
        )

        patchReviewArtifacts = patchReviewArtifacts.filter { _, artifact in
            artifact.rowID != row.id
        }
        guard let indexIdentity = MutationIndexIdentity(
            observationPaths: row.identity.allPaths,
            reviewedIdentities: [row.identity],
            entries: [row.statusEntry]
        ) else {
            return .unavailable(.rawPatchUnavailable, action: action)
        }
        let reviewToken = AgentChangesPatchReviewToken()
        patchReviewArtifacts[reviewToken] = PatchReviewArtifact(
            generation: generation,
            targetRequestID: latestTargetRequestID,
            target: target,
            mode: mode,
            compare: compare,
            snapshotFingerprintKey: snapshot.fingerprintKey,
            payloadFingerprintKey: cached.payloadFingerprintKey,
            rowID: row.id,
            fileKey: row.fileKey,
            identity: row.identity,
            section: row.section,
            contextLevel: contextLevel,
            contentRevision: row.contentRevision,
            indexIdentity: indexIdentity,
            rawData: rawData,
            parsedPatch: parsed,
            visibleLineKeys: visibleLineKeys,
            selectableLineKeys: selectableLineKeys,
            lineKeysByHunkID: lineKeysByHunkID,
            action: action,
            cacheKey: key
        )
        return AgentChangesPartialStagingDescriptor(
            action: action,
            reviewToken: reviewToken,
            selectableChangedLineKeys: selectableLineKeys,
            changedLineKeysByHunkID: lineKeysByHunkID,
            availability: .available
        )
    }

    /// Loads the standard-context projection used by repository-wide diff search.
    ///
    /// This path has its own bounded cache and never calls `partialStagingDescriptor`, so machine
    /// loading a collapsed row cannot become evidence that a person reviewed its bytes.
    func searchDocument(for row: AgentChangesFileRow) async -> AgentChangesSearchPatchDocument {
        guard !isShutdown, let target else { return .unavailable() }
        let requestedGeneration = generation
        let requestedTarget = target
        let requestedMode = mode
        let requestedFingerprintKey = snapshot.fingerprintKey
        let requestedContentRevision = contentRevision(forRepositoryRelativePath: row.fileKey)

        if row.section == .staged, !snapshot.hasHeadCommit {
            return .unavailable()
        }

        let compare = row.section.compareSpec(mode: mode)
        let key = SearchCacheKey(
            checkoutPath: target.checkoutURL.standardizedFileURL.path,
            compareKey: compare.rawKey,
            fileKey: row.fileKey,
            fingerprintKey: requestedFingerprintKey,
            contentRevision: requestedContentRevision
        )
        if let cached = searchCache[key] {
            searchCacheAccess &+= 1
            searchCache[key] = SearchCacheEntry(
                document: cached.document,
                byteCount: cached.byteCount,
                access: searchCacheAccess
            )
            return AgentChangesSearchPatchDocument(
                document: cached.document,
                byteCount: cached.byteCount
            )
        }

        let payload: AgentChangesPatchPayload?
        do {
            payload = try await diffSource.loadPatch(
                compare: compare,
                paths: row.identity.allPaths,
                at: target.checkoutURL,
                contextLines: AgentChangesContextLevel.standard.contextLines
            )
        } catch {
            return .unavailable()
        }

        guard !isShutdown,
              requestedGeneration == generation,
              requestedTarget == self.target,
              requestedMode == mode,
              requestedFingerprintKey == snapshot.fingerprintKey,
              requestedContentRevision == contentRevision(forRepositoryRelativePath: row.fileKey)
        else {
            return .unavailable()
        }
        guard let payload,
              let selectedPatch = Self.selectedPatch(from: payload, fileKey: row.fileKey)
        else {
            return .unavailable()
        }
        let byteCount = selectedPatch.text.utf8.count
        guard byteCount <= patchByteLimit else {
            return .unavailable(byteCount: byteCount)
        }

        let document = DiffLineProjector.project(
            patch: selectedPatch.text,
            fileKey: row.fileKey,
            contextLevel: AgentChangesContextLevel.standard.projectionLevel,
            isUntracked: row.isUntracked,
            maxLines: patchLineLimit,
            computesIntralineDiffs: false,
            oldSourceReference: payload.oldSourceReference
        )
        insertSearchCache(document: document, byteCount: byteCount, for: key)
        return AgentChangesSearchPatchDocument(document: document, byteCount: byteCount)
    }

    /// Reveals one hidden unchanged region without regenerating the patch at a wider global context.
    ///
    /// Source content is cached per checkout/fingerprint/file, with worktree/index/ref variants in
    /// one bucket. A retarget or content revision evicts the bucket before another expansion can
    /// reuse it.
    func expandContextGap(
        for row: AgentChangesFileRow,
        in document: FileDiffProjection.Document,
        gapID: String,
        amount: DiffContextSplicer.ExpansionAmount
    ) async -> AgentChangesGapExpansionOutcome {
        guard !isShutdown else {
            return .unavailable(.failed("The changes repository is no longer available."))
        }
        guard let target else {
            return .unavailable(.failed("No checkout is selected."))
        }
        guard let selection = AgentChangesContextSourceResolver.selection(
            for: row,
            document: document,
            mode: mode,
            hasHeadCommit: snapshot.hasHeadCommit
        ) else {
            return row.section == .staged && !snapshot.hasHeadCommit
                ? .unavailable(.unbornHead)
                : .unavailable(.failed("This file version cannot provide expandable context."))
        }

        let requestedGeneration = generation
        let fingerprintKey = lastGate.map {
            "\($0.fingerprint.headSHA)|\($0.fingerprint.statusHash)"
        } ?? ""
        let cacheKey = FileContentCacheKey(
            checkoutPath: target.checkoutURL.standardizedFileURL.path,
            fingerprintKey: fingerprintKey,
            fileKey: row.fileKey
        )

        let content: AgentChangesFileContent
        if let cached = fileContentCache[cacheKey]?[selection.source] {
            content = cached
        } else {
            do {
                content = try await diffSource.loadFileContent(
                    source: selection.source,
                    at: target.checkoutURL,
                    byteLimit: fileContentByteLimit
                )
            } catch let error as AgentChangesFileContentReadError {
                switch error {
                case let .tooLarge(limit):
                    return .unavailable(.tooLarge(bytes: limit + 1))
                case .notUTF8:
                    return .unavailable(.noTextualDiff)
                case .outsideCheckout:
                    return .unavailable(.failed(error.localizedDescription))
                case let .unavailable(message):
                    return .unavailable(.failed(message))
                }
            } catch {
                return .unavailable(.failed(error.localizedDescription))
            }
            guard !isShutdown, requestedGeneration == generation else {
                return .unavailable(.failed("The checkout changed while context was loading."))
            }
            var bucket = fileContentCache[cacheKey] ?? [:]
            bucket[selection.source] = content
            fileContentCache[cacheKey] = bucket
        }

        guard content.lines.count <= fileContentLineLimit else {
            return .unavailable(.tooManyLines(lines: content.lines.count))
        }

        let expanded = DiffContextSplicer.splice(
            document: document,
            sourceLines: content.lines,
            sourceSide: selection.side,
            gapID: gapID,
            amount: amount
        )
        let renderedLineCount = expanded.hunks.reduce(0) { $0 + $1.lines.count }
        guard renderedLineCount <= patchLineLimit else {
            return .unavailable(.tooManyLines(lines: content.lines.count))
        }
        return .expanded(
            document: expanded,
            sourceLineCount: content.lines.count,
            sourceSide: selection.side
        )
    }

    // MARK: - Patch provenance helpers

    private nonisolated static func fingerprintKey(_ fingerprint: GitDiffFingerprint) -> String {
        "\(fingerprint.headSHA)|\(fingerprint.baseRef)|\(fingerprint.statusHash)"
    }

    private nonisolated static func partialStagingUnavailableReason(
        for error: Error
    ) -> AgentChangesPartialStagingUnavailableReason {
        guard let compilerError = error as? AgentChangesPartialPatchCompiler.CompilerError else {
            return .malformedPatch
        }
        switch compilerError {
        case let .unsupportedStructure(message):
            return message.contains("submodule") ? .binaryOrSubmodule : .structuralChange
        case .patchTooLarge:
            return .rawPatchUnavailable
        case .malformedPatch, .pathMismatch, .invalidSelection:
            return .malformedPatch
        }
    }

    private nonisolated static func selectedPatch(
        from payload: AgentChangesPatchPayload,
        fileKey: String
    ) -> (text: String, rawData: Data?)? {
        if let text = payload.perFile[fileKey] {
            return (text, payload.rawPerFile[fileKey])
        }
        guard payload.perFile.count == 1, let only = payload.perFile.first else { return nil }
        return (only.value, payload.rawPerFile[only.key])
    }

    /// The reviewed changed lines of each projected hunk, plus the hunks git annotated.
    private struct CrossCheckedLineKeys {
        let lineKeysByHunkID: [String: Set<AgentChangesDiffLineKey>]
        let annotatedHunkIDs: Set<String>
    }

    private nonisolated static func crossCheckedLineKeys(
        document: FileDiffProjection.Document,
        parsedPatch: AgentChangesPartialPatchCompiler.ParsedPatch
    ) -> CrossCheckedLineKeys? {
        guard document.hunks.count == parsedPatch.hunks.count else { return nil }
        var result: [String: Set<AgentChangesDiffLineKey>] = [:]
        var annotatedHunkIDs: Set<String> = []

        for (projected, raw) in zip(document.hunks, parsedPatch.hunks) {
            guard projected.oldStart == raw.oldStart,
                  projected.oldCount == raw.oldCount,
                  projected.newStart == raw.newStart,
                  projected.newCount == raw.newCount
            else { return nil }

            var keys = Set<AgentChangesDiffLineKey>()
            for line in projected.lines {
                switch line.kind {
                case .addition:
                    guard let newLine = line.newLine else { return nil }
                    keys.insert(.addition(newLine: newLine))
                case .deletion:
                    guard let oldLine = line.oldLine else { return nil }
                    keys.insert(.deletion(oldLine: oldLine))
                case .context, .noNewlineMarker:
                    break
                }
            }
            guard keys == raw.changedLineKeys else { return nil }
            result[projected.id] = keys
            if raw.carriesNoNewlineAnnotation {
                annotatedHunkIDs.insert(projected.id)
            }
        }
        return CrossCheckedLineKeys(
            lineKeysByHunkID: result,
            annotatedHunkIDs: annotatedHunkIDs
        )
    }

    private func insertSearchCache(
        document: FileDiffProjection.Document,
        byteCount: Int,
        for key: SearchCacheKey
    ) {
        if let old = searchCache.removeValue(forKey: key) {
            searchCacheBytes -= old.byteCount
        }
        searchCacheAccess &+= 1
        searchCache[key] = SearchCacheEntry(
            document: document,
            byteCount: byteCount,
            access: searchCacheAccess
        )
        searchCacheBytes += byteCount

        while searchCache.count > Self.searchCacheDocumentLimit
            || searchCacheBytes > Self.searchCacheByteLimit
        {
            guard let oldest = searchCache.min(by: { $0.value.access < $1.value.access }) else {
                break
            }
            searchCache.removeValue(forKey: oldest.key)
            searchCacheBytes -= oldest.value.byteCount
        }
    }

    private func removeSearchCacheEntries(for paths: Set<String>) {
        let removedBytes = searchCache.reduce(0) { partial, entry in
            paths.contains(entry.key.fileKey) ? partial + entry.value.byteCount : partial
        }
        searchCache = searchCache.filter { !paths.contains($0.key.fileKey) }
        searchCacheBytes -= removedBytes
    }

    private func clearSearchCache() {
        searchCache.removeAll()
        searchCacheBytes = 0
    }

    // MARK: - Staging

    /// Builds the final-authority check the index backend evaluates inside its own mutation lock.
    ///
    /// Every fence below is already checked by the repository-side preflights, but all of those
    /// checks happen before the mutation is handed to the backend. The backend then serializes
    /// mutations of one checkout, so a request can wait there while an unrelated app mutation runs —
    /// and a retarget or shutdown during that wait would otherwise let Git run against a checkout
    /// this actor no longer owns, with the panel silently discarding the completion. Re-checking
    /// immediately before the command is the last point at which refusing means nothing was written.
    private func mutationAuthorization(
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        targetRequestID: UInt64,
        mutationLease: AgentChangesIndexMutationLease,
        reviewedRevisions: [String: UInt64],
        reviewedIndexIdentity: MutationIndexIdentity
    ) -> VCSIndexMutationAuthorization {
        { [weak self] in
            guard mutationLease.isLive, let self else { return false }
            return await retainsMutationAuthority(
                target: target,
                requestedGeneration: requestedGeneration,
                targetRequestID: targetRequestID,
                mutationLease: mutationLease,
                reviewedRevisions: reviewedRevisions,
                reviewedIndexIdentity: reviewedIndexIdentity
            )
        }
    }

    private func retainsMutationAuthority(
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        targetRequestID: UInt64,
        mutationLease: AgentChangesIndexMutationLease,
        reviewedRevisions: [String: UInt64],
        reviewedIndexIdentity: MutationIndexIdentity
    ) async -> Bool {
        guard mutationFencesStillHold(
            target: target,
            requestedGeneration: requestedGeneration,
            targetRequestID: targetRequestID,
            mutationLease: mutationLease,
            reviewedRevisions: reviewedRevisions
        ) else { return false }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(
                at: target.checkoutURL,
                paths: reviewedIndexIdentity.observationPaths
            )
        } catch {
            return false
        }

        guard mutationFencesStillHold(
            target: target,
            requestedGeneration: requestedGeneration,
            targetRequestID: targetRequestID,
            mutationLease: mutationLease,
            reviewedRevisions: reviewedRevisions
        ) else { return false }
        guard let currentIndexIdentity = MutationIndexIdentity(
            observationPaths: reviewedIndexIdentity.observationPaths,
            reviewedIdentities: reviewedIndexIdentity.reviewedIdentities,
            entries: entries,
            allowsConflictedEntries: reviewedIndexIdentity.allowsConflictedEntries
        ) else { return false }
        return currentIndexIdentity == reviewedIndexIdentity
    }

    private func mutationFencesStillHold(
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        targetRequestID: UInt64,
        mutationLease: AgentChangesIndexMutationLease,
        reviewedRevisions: [String: UInt64]
    ) -> Bool {
        guard mutationLease.isLive,
              !isShutdown,
              generation == requestedGeneration,
              self.target == target,
              targetRequestID == latestTargetRequestID
        else { return false }
        return revisionsStillMatch(reviewedRevisions)
    }

    private func mutationRevisionBaseline(
        identity: VCSIndexPathIdentity,
        expectedContentRevision: UInt64
    ) -> [String: UInt64] {
        Dictionary(
            uniqueKeysWithValues: identity.mutationPaths.map { path in
                (
                    path,
                    path == identity.path
                        ? expectedContentRevision
                        : contentRevision(forRepositoryRelativePath: path)
                )
            }
        )
    }

    private func mutationRevisionBaseline(
        reviewed: [AgentChangesBulkMutationRequest.ReviewedIdentity]
    ) -> [String: UInt64]? {
        var revisions: [String: UInt64] = [:]
        for reviewedIdentity in reviewed {
            for path in reviewedIdentity.identity.mutationPaths {
                let revision = path == reviewedIdentity.identity.path
                    ? reviewedIdentity.contentRevision
                    : contentRevision(forRepositoryRelativePath: path)
                if let existing = revisions[path], existing != revision {
                    return nil
                }
                revisions[path] = revision
            }
        }
        return revisions
    }

    private func revisionsStillMatch(_ reviewedRevisions: [String: UInt64]) -> Bool {
        reviewedRevisions.allSatisfy { path, contentRevision in
            self.contentRevision(forRepositoryRelativePath: path) == contentRevision
        }
    }

    private func reviewedIdentityStillHolds(
        _ identity: VCSIndexPathIdentity,
        in entries: [VCSIndexStatusEntry]
    ) -> Bool {
        let mutationPaths = Set(identity.mutationPaths)
        let occupants = entries.filter { entry in
            !mutationPaths.isDisjoint(with: entry.identity.allPaths)
        }
        return occupants.count == 1 && occupants[0].identity == identity
    }

    /// The partial-apply flavour of ``mutationAuthorization(target:requestedGeneration:targetRequestID:reviewedRevisions:)``.
    ///
    /// A review token is the whole authority for a partial apply, so re-validating it re-checks
    /// shutdown, generation, retarget, snapshot fingerprint, and the reviewed content revision in
    /// exactly the same place the preflight does.
    private func partialMutationAuthorization(
        _ request: AgentChangesPartialMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        mutationLease: AgentChangesIndexMutationLease
    ) -> VCSIndexMutationAuthorization {
        { [weak self] in
            guard mutationLease.isLive, let self else { return false }
            guard let artifact = await validatedReviewArtifact(
                for: request,
                target: target,
                requestedGeneration: requestedGeneration
            ) else { return false }
            guard await retainsMutationAuthority(
                target: target,
                requestedGeneration: requestedGeneration,
                targetRequestID: artifact.targetRequestID,
                mutationLease: mutationLease,
                reviewedRevisions: [artifact.fileKey: artifact.contentRevision],
                reviewedIndexIdentity: artifact.indexIdentity
            ) else { return false }
            guard mutationLease.isLive else { return false }
            return await validatedReviewArtifact(
                for: request,
                target: target,
                requestedGeneration: requestedGeneration
            ) != nil
        }
    }

    /// Applies reviewed hunk or line bytes through the existing FIFO mutation pipeline.
    func applyPartialMutation(
        _ request: AgentChangesPartialMutationRequest
    ) async -> AgentChangesMutationOutcome {
        guard !isShutdown else { return .unsupported }
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .contentChanged
        }
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }
        let observationPaths = request.identity.allPaths
        registerActiveMutationPaths(observationPaths)
        defer { unregisterActiveMutationPaths(observationPaths) }

        let compilation: AgentChangesPartialPatchCompiler.Compilation
        switch await partialMutationPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration
        ) {
        case let .ready(prepared):
            compilation = prepared
        case let .stop(outcome):
            return outcome
        }

        let authorize = partialMutationAuthorization(
            request,
            target: target,
            requestedGeneration: requestedGeneration,
            mutationLease: mutationLease
        )

        do {
            try await indexBackend.applyCachedPatch(
                compilation.data,
                reverse: compilation.reverse,
                at: target.checkoutURL,
                authorize: authorize
            )
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }
            guard !isShutdown else { return .unsupported }
            guard generation == requestedGeneration, self.target == target else {
                return .contentChanged
            }

            let retryCompilation: AgentChangesPartialPatchCompiler.Compilation
            switch await partialMutationPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration
            ) {
            case let .ready(prepared):
                retryCompilation = prepared
            case let .stop(outcome):
                return outcome
            }

            do {
                try await indexBackend.applyCachedPatch(
                    retryCompilation.data,
                    reverse: retryCompilation.reverse,
                    at: target.checkoutURL,
                    authorize: authorize
                )
            } catch let error as GitIndexMutationError {
                return await partialApplyFailure(
                    error,
                    token: request.reviewToken,
                    target: target,
                    requestedGeneration: requestedGeneration
                )
            } catch {
                await rebuildAfterUncertainPartialFailure(
                    target: target,
                    requestedGeneration: requestedGeneration
                )
                return .failed(error.localizedDescription)
            }
        } catch let error as GitIndexMutationError {
            return await partialApplyFailure(
                error,
                token: request.reviewToken,
                target: target,
                requestedGeneration: requestedGeneration
            )
        } catch {
            await rebuildAfterUncertainPartialFailure(
                target: target,
                requestedGeneration: requestedGeneration
            )
            return .failed(error.localizedDescription)
        }

        patchReviewArtifacts.removeValue(forKey: request.reviewToken)
        var contentChangedAfterApply = generation == requestedGeneration
            && self.target == target
            && contentRevision(forRepositoryRelativePath: request.fileKey) != request.expectedContentRevision

        // The command targeted the captured checkout even if the panel retargeted while Git was
        // running. Always invalidate that checkout; only rebuild when this actor still owns it.
        await invalidationPublisher.publishIndexMutation(at: target.checkoutURL)
        if generation == requestedGeneration, self.target == target {
            let changedDuringInvalidation = contentRevision(forRepositoryRelativePath: request.fileKey)
                != request.expectedContentRevision
            contentChangedAfterApply = contentChangedAfterApply || changedDuringInvalidation
            await performRebuild(bypassingFingerprintGate: true)
            let changedDuringRebuild = contentRevision(forRepositoryRelativePath: request.fileKey)
                != request.expectedContentRevision
            contentChangedAfterApply = contentChangedAfterApply || changedDuringRebuild
        }
        return contentChangedAfterApply ? .appliedThenContentChanged : .applied
    }

    private enum PartialMutationPreflight {
        case ready(AgentChangesPartialPatchCompiler.Compilation)
        case stop(AgentChangesMutationOutcome)
    }

    private func partialMutationPreflight(
        _ request: AgentChangesPartialMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async -> PartialMutationPreflight {
        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.contentChanged)
        }
        guard let artifact = validatedReviewArtifact(
            for: request,
            target: target,
            requestedGeneration: requestedGeneration
        ) else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }
        guard identityIsInsideMutationScope(artifact.identity, target: target) else {
            return .stop(.failed("This file is outside the represented workspace scope."))
        }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(
                at: target.checkoutURL,
                paths: artifact.indexIdentity.observationPaths
            )
        } catch {
            await rebuildAfterUncertainPartialFailure(
                target: target,
                requestedGeneration: requestedGeneration
            )
            return .stop(.failed(error.localizedDescription))
        }

        guard let currentArtifact = validatedReviewArtifact(
            for: request,
            target: target,
            requestedGeneration: requestedGeneration
        ), currentArtifact.rawData == artifact.rawData
        else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }
        guard let entry = entries.first(where: { $0.path == artifact.identity.path }),
              entry.identity == artifact.identity
        else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }
        guard !entry.isConflicted else { return .stop(.conflicted) }
        guard let currentIndexIdentity = MutationIndexIdentity(
            observationPaths: artifact.indexIdentity.observationPaths,
            reviewedIdentities: artifact.indexIdentity.reviewedIdentities,
            entries: entries
        ), currentIndexIdentity == artifact.indexIdentity
        else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }
        let statusStillMatches: Bool = switch artifact.action {
        case .stage:
            entry.hasWorkTreeChange && !entry.isUntracked && entry.workTreeStatus == "M"
        case .unstage:
            entry.hasStagedChange && entry.indexStatus == "M"
        }
        guard statusStillMatches else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }

        let freshPayload: AgentChangesPatchPayload?
        do {
            // Deliberately bypasses both render and search caches.
            freshPayload = try await diffSource.loadPatch(
                compare: artifact.compare,
                paths: artifact.identity.allPaths,
                at: target.checkoutURL,
                contextLines: artifact.contextLevel.contextLines
            )
        } catch {
            await rebuildAfterUncertainPartialFailure(
                target: target,
                requestedGeneration: requestedGeneration
            )
            return .stop(.failed(error.localizedDescription))
        }

        guard let finalArtifact = validatedReviewArtifact(
            for: request,
            target: target,
            requestedGeneration: requestedGeneration
        ), finalArtifact.rawData == artifact.rawData
        else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }
        guard let freshPayload,
              let fresh = Self.selectedPatch(from: freshPayload, fileKey: artifact.fileKey),
              let freshRawData = fresh.rawData,
              Data(fresh.text.utf8) == freshRawData,
              freshRawData == artifact.rawData,
              Self.fingerprintKey(freshPayload.fingerprint) == artifact.payloadFingerprintKey
        else {
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .stop(.contentChanged)
        }

        let selectedLines = request.selection.lines
        guard !selectedLines.isEmpty,
              selectedLines.isSubset(of: artifact.visibleLineKeys),
              let reviewedHunkLines = artifact.lineKeysByHunkID[request.selection.projectedHunkID],
              selectedLines.isSubset(of: reviewedHunkLines),
              !reviewedHunkLines.isEmpty
        else {
            return .stop(.failed("The selected lines are not part of the reviewed patch."))
        }
        if request.selection.selectsWholeHunk {
            guard selectedLines == reviewedHunkLines else {
                return .stop(.failed("The hunk selection no longer matches the reviewed hunk."))
            }
        } else if !selectedLines.isSubset(of: artifact.selectableLineKeys) {
            // Line selection is withheld for hunks carrying a no-newline annotation, so a request
            // for one can only come from stale or forged state. Whole-hunk staging still works.
            return .stop(.failed("This hunk can only be staged or unstaged as a whole."))
        }

        do {
            let compilation = try AgentChangesPartialPatchCompiler.compile(
                artifact.parsedPatch,
                action: artifact.action,
                selectedLineKeys: selectedLines,
                selectsWholeHunks: request.selection.selectsWholeHunk
            )
            return .ready(compilation)
        } catch {
            patchReviewArtifacts.removeValue(forKey: request.reviewToken)
            disabledPartialDescriptorReasons[artifact.cacheKey] =
                Self.partialStagingUnavailableReason(for: error)
            Self.logger.fault(
                "Partial patch compilation failed after review validation: \(error.localizedDescription, privacy: .public)"
            )
            return .stop(.failed(error.localizedDescription))
        }
    }

    private func validatedReviewArtifact(
        for request: AgentChangesPartialMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) -> PatchReviewArtifact? {
        guard !isShutdown,
              let artifact = patchReviewArtifacts[request.reviewToken],
              generation == requestedGeneration,
              self.target == target,
              mode == artifact.mode,
              artifact.generation == requestedGeneration,
              artifact.targetRequestID == latestTargetRequestID,
              artifact.target == target,
              snapshot.targetRequestID == latestTargetRequestID,
              snapshot.target == target,
              snapshot.loadState == .ready,
              snapshot.fingerprintKey == artifact.snapshotFingerprintKey,
              request.rowID == artifact.rowID,
              request.fileKey == artifact.fileKey,
              request.identity == artifact.identity,
              request.section == artifact.section,
              request.expectedContentRevision == artifact.contentRevision,
              contentRevision(forRepositoryRelativePath: artifact.fileKey) == artifact.contentRevision
        else { return nil }
        return artifact
    }

    private func partialApplyFailure(
        _ error: GitIndexMutationError,
        token: AgentChangesPatchReviewToken,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async -> AgentChangesMutationOutcome {
        switch error {
        case .patchDoesNotApply:
            patchReviewArtifacts.removeValue(forKey: token)
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .contentChanged
        case .invalidPatch:
            if let artifact = patchReviewArtifacts.removeValue(forKey: token) {
                disabledPartialDescriptorReasons[artifact.cacheKey] = .malformedPatch
            }
            Self.logger.fault(
                "Git rejected a repository-compiled partial patch: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        case .patchTooLarge:
            if let artifact = patchReviewArtifacts.removeValue(forKey: token) {
                disabledPartialDescriptorReasons[artifact.cacheKey] = .rawPatchUnavailable
            }
            Self.logger.fault(
                "Git rejected a repository-compiled partial patch: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        case .indexLocked:
            return .failed(error.localizedDescription)
        case .authorizationRevoked:
            // Nothing ran. The rebuild is for the one revocable fence that can move without a
            // retarget — a content revision advancing while the mutation waited for the lock.
            await rebuildForPartialDrift(target: target, requestedGeneration: requestedGeneration)
            return .contentChanged
        case .unavailable, .invalidPath, .invalidStatusEncoding, .gitRefused:
            await rebuildAfterUncertainPartialFailure(
                target: target,
                requestedGeneration: requestedGeneration
            )
            return .failed(error.localizedDescription)
        }
    }

    private func rebuildForPartialDrift(
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async {
        guard !isShutdown, generation == requestedGeneration, self.target == target else { return }
        await performRebuild(bypassingFingerprintGate: true)
    }

    private func rebuildAfterUncertainPartialFailure(
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async {
        guard !isShutdown, generation == requestedGeneration, self.target == target else { return }
        await performRebuild(bypassingFingerprintGate: true)
    }

    private enum SingleMutationPreflight {
        case ready(MutationIndexIdentity)
        case stop(AgentChangesMutationOutcome)
    }

    /// Applies one staging change.
    ///
    /// The order inside the lock is the contract: preflight, authoritative read, decide, mutate,
    /// announce, rebuild. Every step is there because of a specific way the naive version is wrong.
    func applyMutation(_ request: AgentChangesMutationRequest) async -> AgentChangesMutationOutcome {
        guard !isShutdown else { return .unsupported }
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }
        // Gated, not caught: a backend without an index has no staging call to fail, so the panel
        // never reaches one.
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }
        guard identityIsInsideMutationScope(request.identity, target: target) else {
            return .failed("This rename reaches outside the represented workspace scope and cannot be staged here.")
        }

        let reviewedRevisions = mutationRevisionBaseline(
            identity: request.identity,
            expectedContentRevision: request.expectedContentRevision
        )
        let observationPaths = request.identity.allPaths
        registerActiveMutationPaths(observationPaths)
        defer { unregisterActiveMutationPaths(observationPaths) }

        let reviewedIndexIdentity: MutationIndexIdentity
        switch await singleMutationPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration,
            reviewedRevisions: reviewedRevisions,
            expectedIndexIdentity: nil
        ) {
        case let .ready(indexIdentity):
            reviewedIndexIdentity = indexIdentity
        case let .stop(outcome):
            return outcome
        }

        let authorize = mutationAuthorization(
            target: target,
            requestedGeneration: requestedGeneration,
            targetRequestID: request.targetRequestID,
            mutationLease: mutationLease,
            reviewedRevisions: reviewedRevisions,
            reviewedIndexIdentity: reviewedIndexIdentity
        )

        do {
            try await execute(request, at: target, authorize: authorize)
        } catch GitIndexMutationError.authorizationRevoked {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }
            guard !isShutdown else { return .unsupported }
            guard generation == requestedGeneration, self.target == target else {
                return .failed("The checkout changed before this operation could be completed.")
            }
            guard request.targetRequestID == latestTargetRequestID else {
                return .contentChanged
            }
            // The contender may have changed both index and worktree. Re-read the authoritative
            // status and re-check the cheap content revision before issuing the sole retry.
            switch await singleMutationPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration,
                reviewedRevisions: reviewedRevisions,
                expectedIndexIdentity: reviewedIndexIdentity
            ) {
            case .ready:
                break
            case let .stop(outcome):
                return outcome
            }
            do {
                // The same hook is re-evaluated inside the lock for the retry.
                try await execute(request, at: target, authorize: authorize)
            } catch GitIndexMutationError.authorizationRevoked {
                await performRebuild(bypassingFingerprintGate: true)
                return .contentChanged
            } catch {
                await performRebuild(bypassingFingerprintGate: true)
                return .failed(error.localizedDescription)
            }
        } catch {
            await performRebuild(bypassingFingerprintGate: true)
            return .failed(error.localizedDescription)
        }

        await invalidationPublisher.publishIndexMutation(at: target.checkoutURL)
        // Forced authoritative rebuild before the lock is released, so the next queued mutation
        // decides against the index this one produced rather than against a stale list.
        await performRebuild(bypassingFingerprintGate: true)
        return .applied
    }

    /// Captures the reviewed index identity on the first attempt and requires it on the retry.
    private func singleMutationPreflight(
        _ request: AgentChangesMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        reviewedRevisions: [String: UInt64],
        expectedIndexIdentity: MutationIndexIdentity?
    ) async -> SingleMutationPreflight {
        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this operation could be completed."))
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .stop(.contentChanged)
        }
        guard revisionsStillMatch(reviewedRevisions) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        let observationPaths = request.identity.allPaths
        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(
                at: target.checkoutURL,
                paths: observationPaths
            )
        } catch {
            return .stop(.failed(error.localizedDescription))
        }

        // This second cheap check closes the status-subprocess window: a content event can advance
        // the revision while the actor is suspended in `loadIndexStatus`.
        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this operation could be completed."))
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .stop(.contentChanged)
        }
        guard revisionsStillMatch(reviewedRevisions) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        guard reviewedIdentityStillHolds(request.identity, in: entries) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        let entry = entries.first { $0.identity == request.identity }
        if entry?.isConflicted == true { return .stop(.conflicted) }
        guard let currentIndexIdentity = MutationIndexIdentity(
            observationPaths: observationPaths,
            reviewedIdentities: [request.identity],
            entries: entries
        ) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        if let expectedIndexIdentity, currentIndexIdentity != expectedIndexIdentity {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        if isDesiredState(entry: entry, stage: request.stage) { return .stop(.noOp) }
        return .ready(currentIndexIdentity)
    }

    private func execute(
        _ request: AgentChangesMutationRequest,
        at target: AgentPanelResolvedCheckout,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        if request.stage {
            try await indexBackend.stage(
                [request.identity],
                at: target.checkoutURL,
                authorize: authorize
            )
        } else {
            try await indexBackend.unstage(
                [request.identity],
                at: target.checkoutURL,
                authorize: authorize
            )
        }
    }

    private enum ResolutionPreflight {
        case ready(MutationIndexIdentity)
        case stop(AgentChangesMutationOutcome)
    }

    /// Marks a conflict resolved by staging exactly the current path contents.
    ///
    /// This intentionally mirrors ordinary staging's generation, content-review preflight,
    /// repository serialization, invalidation, and forced-rebuild ordering while keeping a
    /// distinct entry point so the UI can never disguise resolution as a checkbox state.
    func markResolved(_ request: AgentChangesResolveRequest) async -> AgentChangesMutationOutcome {
        guard !isShutdown else { return .unsupported }
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }
        guard identityIsInsideMutationScope(request.identity, target: target) else {
            return .failed("This conflict is outside the represented workspace scope.")
        }
        let reviewedRevisions = mutationRevisionBaseline(
            identity: request.identity,
            expectedContentRevision: request.expectedContentRevision
        )
        let observationPaths = request.identity.allPaths
        registerActiveMutationPaths(observationPaths)
        defer { unregisterActiveMutationPaths(observationPaths) }

        let reviewedIndexIdentity: MutationIndexIdentity
        switch await resolutionPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration,
            reviewedRevisions: reviewedRevisions,
            expectedIndexIdentity: nil
        ) {
        case let .ready(indexIdentity):
            reviewedIndexIdentity = indexIdentity
        case let .stop(outcome):
            return outcome
        }

        let authorize = mutationAuthorization(
            target: target,
            requestedGeneration: requestedGeneration,
            targetRequestID: request.targetRequestID,
            mutationLease: mutationLease,
            reviewedRevisions: reviewedRevisions,
            reviewedIndexIdentity: reviewedIndexIdentity
        )

        do {
            try await indexBackend.markResolved(
                request.identity,
                at: target.checkoutURL,
                authorize: authorize
            )
        } catch GitIndexMutationError.authorizationRevoked {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }
            switch await resolutionPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration,
                reviewedRevisions: reviewedRevisions,
                expectedIndexIdentity: reviewedIndexIdentity
            ) {
            case .ready:
                break
            case let .stop(outcome):
                return outcome
            }
            do {
                // The same hook is re-evaluated inside the lock for the retry.
                try await indexBackend.markResolved(
                    request.identity,
                    at: target.checkoutURL,
                    authorize: authorize
                )
            } catch GitIndexMutationError.authorizationRevoked {
                await performRebuild(bypassingFingerprintGate: true)
                return .contentChanged
            } catch {
                await performRebuild(bypassingFingerprintGate: true)
                return .failed(error.localizedDescription)
            }
        } catch {
            await performRebuild(bypassingFingerprintGate: true)
            return .failed(error.localizedDescription)
        }

        await invalidationPublisher.publishIndexMutation(at: target.checkoutURL)
        await performRebuild(bypassingFingerprintGate: true)
        return .applied
    }

    private func resolutionPreflight(
        _ request: AgentChangesResolveRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        reviewedRevisions: [String: UInt64],
        expectedIndexIdentity: MutationIndexIdentity?
    ) async -> ResolutionPreflight {
        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this operation could be completed."))
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .stop(.contentChanged)
        }
        guard revisionsStillMatch(reviewedRevisions) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        let observationPaths = request.identity.allPaths
        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(
                at: target.checkoutURL,
                paths: observationPaths
            )
        } catch {
            return .stop(.failed(error.localizedDescription))
        }

        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this operation could be completed."))
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .stop(.contentChanged)
        }
        guard revisionsStillMatch(reviewedRevisions) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        guard reviewedIdentityStillHolds(request.identity, in: entries) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        guard let currentIndexIdentity = MutationIndexIdentity(
            observationPaths: observationPaths,
            reviewedIdentities: [request.identity],
            entries: entries,
            allowsConflictedEntries: true
        ) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        if let expectedIndexIdentity, currentIndexIdentity != expectedIndexIdentity {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        guard let entry = entries.first(where: { $0.identity == request.identity }),
              entry.isConflicted
        else {
            return .stop(.noOp)
        }
        return .ready(currentIndexIdentity)
    }

    /// Whether the index already says what the click asked for.
    ///
    /// Staging is only redundant when there is nothing left to stage. A partially-staged file has a
    /// staged change *and* a working-tree change, and staging it again is a real operation that
    /// captures the rest — so it is not a no-op even though the file is already in Staged.
    private func isDesiredState(entry: VCSIndexStatusEntry?, stage: Bool) -> Bool {
        guard let entry else {
            // Absent from status means clean: nothing to stage and nothing to unstage.
            return true
        }
        return stage
            ? entry.hasStagedChange && !entry.hasWorkTreeChange
            : !entry.hasStagedChange
    }

    /// Stages or unstages exactly the eligible identities rendered in one section.
    ///
    /// A fresh status read remains authoritative, but it must describe the same eligible set the
    /// user saw. A newly-created file or any other set change refreshes instead of silently widening
    /// Stage All to unreviewed content.
    func applyBulkMutation(
        _ request: AgentChangesBulkMutationRequest
    ) async -> AgentChangesMutationOutcome {
        guard !isShutdown else { return .unsupported }
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              request.section.isStageable,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard !isShutdown else { return .unsupported }
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this operation could be completed.")
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .contentChanged
        }

        guard let reviewedRevisions = mutationRevisionBaseline(reviewed: request.reviewed) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        }
        let observationPaths = request.reviewed.flatMap(\.identity.allPaths)
        registerActiveMutationPaths(observationPaths)
        defer { unregisterActiveMutationPaths(observationPaths) }

        let identities: [VCSIndexPathIdentity]
        let reviewedIndexIdentity: MutationIndexIdentity
        switch await bulkMutationPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration,
            reviewedRevisions: reviewedRevisions,
            expectedIndexIdentity: nil
        ) {
        case let .ready(preflightIdentities, indexIdentity):
            identities = preflightIdentities
            reviewedIndexIdentity = indexIdentity
        case let .stop(outcome):
            return outcome
        }

        let authorize = mutationAuthorization(
            target: target,
            requestedGeneration: requestedGeneration,
            targetRequestID: request.targetRequestID,
            mutationLease: mutationLease,
            reviewedRevisions: reviewedRevisions,
            reviewedIndexIdentity: reviewedIndexIdentity
        )

        do {
            try await executeBulk(
                identities,
                stage: request.stage,
                at: target,
                authorize: authorize
            )
        } catch GitIndexMutationError.authorizationRevoked {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }

            let retryIdentities: [VCSIndexPathIdentity]
            switch await bulkMutationPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration,
                reviewedRevisions: reviewedRevisions,
                expectedIndexIdentity: reviewedIndexIdentity
            ) {
            case let .ready(preflightIdentities, _):
                retryIdentities = preflightIdentities
            case let .stop(outcome):
                return outcome
            }
            do {
                // The same hook is re-evaluated inside the lock for the retry.
                try await executeBulk(
                    retryIdentities,
                    stage: request.stage,
                    at: target,
                    authorize: authorize
                )
            } catch GitIndexMutationError.authorizationRevoked {
                await performRebuild(bypassingFingerprintGate: true)
                return .contentChanged
            } catch {
                await performRebuild(bypassingFingerprintGate: true)
                return .failed(error.localizedDescription)
            }
        } catch {
            await performRebuild(bypassingFingerprintGate: true)
            return .failed(error.localizedDescription)
        }

        await invalidationPublisher.publishIndexMutation(at: target.checkoutURL)
        await performRebuild(bypassingFingerprintGate: true)
        return .applied
    }

    private enum BulkMutationPreflight {
        case ready([VCSIndexPathIdentity], MutationIndexIdentity)
        case stop(AgentChangesMutationOutcome)
    }

    private func bulkMutationPreflight(
        _ request: AgentChangesBulkMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64,
        reviewedRevisions: [String: UInt64],
        expectedIndexIdentity: MutationIndexIdentity?
    ) async -> BulkMutationPreflight {
        guard !isShutdown else { return .stop(.unsupported) }
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this operation could be completed."))
        }
        guard request.targetRequestID == latestTargetRequestID else {
            return .stop(.contentChanged)
        }
        guard revisionsStillMatch(reviewedRevisions) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(at: target.checkoutURL)
        } catch {
            return .stop(.failed(error.localizedDescription))
        }

        guard request.reviewed.allSatisfy({ reviewedIdentityStillHolds($0.identity, in: entries) }) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        let identities = entries
            .filter { !$0.isConflicted }
            .filter { target.containsRepositoryRelativePath($0.path) }
            .filter { identityIsInsideMutationScope($0.identity, target: target) }
            .filter {
                request.section == .staged ? $0.hasStagedChange : $0.hasWorkTreeChange
            }
            .filter { !isDesiredState(entry: $0, stage: request.stage) }
            .map(\.identity)

        let reviewedIdentitySet = Set(request.reviewed.map(\.identity))
        guard Set(identities) == reviewedIdentitySet else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        let reviewedIdentities = request.reviewed.map(\.identity)
        let observationPaths = reviewedIdentities.flatMap(\.allPaths)
        guard let currentIndexIdentity = MutationIndexIdentity(
            observationPaths: observationPaths,
            reviewedIdentities: reviewedIdentities,
            entries: entries
        ) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        if let expectedIndexIdentity, currentIndexIdentity != expectedIndexIdentity {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        // Re-check after the status subprocess, immediately before the caller issues Git.
        guard !isShutdown,
              generation == requestedGeneration,
              self.target == target,
              request.targetRequestID == latestTargetRequestID,
              revisionsStillMatch(reviewedRevisions)
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        guard !identities.isEmpty else { return .stop(.noOp) }
        return .ready(identities, currentIndexIdentity)
    }

    private func executeBulk(
        _ identities: [VCSIndexPathIdentity],
        stage: Bool,
        at target: AgentPanelResolvedCheckout,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        if stage {
            try await indexBackend.stage(
                identities,
                at: target.checkoutURL,
                authorize: authorize
            )
        } else {
            try await indexBackend.unstage(
                identities,
                at: target.checkoutURL,
                authorize: authorize
            )
        }
    }

    // MARK: - Gates

    /// FIFO so a burst of checkbox clicks applies in the order the user made them.
    ///
    /// An actor serializes calls but not the suspensions inside them: two `applyMutation` calls
    /// would otherwise interleave across their `await`s and let a stage and an unstage of the same
    /// path race, or let one decide against a status read the other has already invalidated.
    private func acquireMutationLock() async {
        guard isMutating else {
            isMutating = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationLock() {
        if mutationWaiters.isEmpty {
            isMutating = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    /// Keeps the drain loop's rebuilds and a mutation's forced rebuild from overlapping, so two
    /// reads of the same checkout cannot publish out of order.
    private func acquireRebuildGate() async {
        guard isRebuilding else {
            isRebuilding = true
            return
        }
        await withCheckedContinuation { continuation in
            rebuildWaiters.append(continuation)
        }
    }

    private func releaseRebuildGate() {
        if rebuildWaiters.isEmpty {
            isRebuilding = false
            signalIdleIfNeeded()
        } else {
            rebuildWaiters.removeFirst().resume()
        }
    }
}
