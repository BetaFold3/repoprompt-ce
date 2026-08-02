import Foundation
import OSLog

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

    // MARK: - Patch cache

    private struct PatchCacheKey: Hashable {
        let checkoutPath: String
        let compareKey: String
        let fileKey: String
        let contextLines: Int
        let fingerprintKey: String
        let contentRevision: UInt64
    }

    private var patchCache: [PatchCacheKey: FileDiffProjection.Document] = [:]

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
            observers[id] = continuation
            continuation.yield(current)
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
        requestID: UInt64? = nil
    ) {
        defer { signalIdleIfNeeded() }

        if let requestID {
            guard requestID >= latestTargetRequestID else { return }
            latestTargetRequestID = requestID
        }
        guard newTarget != target || newMode != mode else { return }

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
        fileContentCache.removeAll()
        pathRevisions.removeAll()

        stopFeed()

        publish(AgentChangesSnapshot(
            generation: generation,
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

    /// Tears down the feed and stops publishing. Call before releasing the repository.
    func shutdown() {
        stopFeed()
        windowTask?.cancel()
        windowTask = nil
        pendingRebuild = nil
        signalIdleIfNeeded()
        for continuation in observers.values {
            continuation.finish()
        }
        observers.removeAll()
    }

    private func startFeed(for checkout: AgentPanelResolvedCheckout) {
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
        guard feedGeneration == generation else { return }
        refresh(trigger)
    }

    // MARK: - Triggers

    /// Applies one refresh trigger.
    ///
    /// The gating decisions live on ``AgentChangesRefreshTrigger`` itself; this method is the
    /// mechanism, not the policy.
    func refresh(_ trigger: AgentChangesRefreshTrigger) {
        guard let target else { return }

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
        guard !isIdle else { return }
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
        fileContentCache = fileContentCache.filter { key, _ in
            !paths.contains(key.fileKey)
        }
    }

    /// Keep per-path revision state bounded to paths that still back visible rows or cache entries.
    private func prunePathRevisions(renderedSections: [AgentChangesSection]) {
        var retained = Set(renderedSections.flatMap { $0.rows.map(\.fileKey) })
        retained.formUnion(patchCache.keys.map(\.fileKey))
        retained.formUnion(fileContentCache.keys.map(\.fileKey))
        pathRevisions = pathRevisions.filter { retained.contains($0.key) }
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
        let bypass = windowBypassesFingerprintGate
        windowBypassesFingerprintGate = false
        guard target != nil else {
            signalIdleIfNeeded()
            return
        }
        enqueueRebuild(bypassingFingerprintGate: bypass)
    }

    private func enqueueRebuild(bypassingFingerprintGate bypass: Bool) {
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
        guard !isDrainingRebuilds else { return }
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

        guard let target else { return }
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
            guard buildGeneration == generation else { return }

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
            guard buildGeneration == generation else { return }
            Self.logger.warning(
                """
                Changes rebuild failed for \(target.checkoutURL.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            publish(AgentChangesSnapshot(
                generation: buildGeneration,
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
        await diffSource.resolveRevision(revision, at: target.checkoutURL)
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
        guard let target else { return .unavailable(.failed("No checkout is selected.")) }
        let requestedGeneration = generation
        let requestedMode = mode
        let requestedContentRevision = contentRevision(forRepositoryRelativePath: row.fileKey)
        let requestedFingerprintKey = snapshot.fingerprintKey

        if row.section == .staged, !snapshot.hasHeadCommit {
            return .unavailable(.unbornHead)
        }

        let compare = row.section.compareSpec(mode: mode)
        let fingerprintKey = lastGate.map { "\($0.fingerprint.headSHA)|\($0.fingerprint.statusHash)" } ?? ""
        let key = PatchCacheKey(
            checkoutPath: target.checkoutURL.path,
            compareKey: compare.rawKey,
            fileKey: row.fileKey,
            contextLines: contextLevel.contextLines,
            fingerprintKey: fingerprintKey,
            contentRevision: requestedContentRevision
        )
        if let cached = patchCache[key] {
            return .loaded(cached)
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

        guard requestedGeneration == generation,
              target == self.target,
              requestedMode == mode,
              requestedContentRevision == contentRevision(forRepositoryRelativePath: row.fileKey),
              requestedFingerprintKey == snapshot.fingerprintKey
        else {
            return .unavailable(.failed("The checkout changed while the patch was loading."))
        }

        guard let payload else { return .unavailable(.noTextualDiff) }
        // Rename detection decides whether both sides of a rename come back as one patch or two;
        // when the read produced exactly one patch, that patch is this file's however it is keyed.
        let text = payload.perFile[row.fileKey]
            ?? (payload.perFile.count == 1 ? payload.perFile.values.first : nil)
        guard let text else { return .unavailable(.noTextualDiff) }

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
        patchCache[key] = document
        return .loaded(document)
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
            guard requestedGeneration == generation else {
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

    // MARK: - Staging

    /// Applies one staging change.
    ///
    /// The order inside the lock is the contract: preflight, authoritative read, decide, mutate,
    /// announce, rebuild. Every step is there because of a specific way the naive version is wrong.
    func applyMutation(_ request: AgentChangesMutationRequest) async -> AgentChangesMutationOutcome {
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }
        // Gated, not caught: a backend without an index has no staging call to fail, so the panel
        // never reaches one.
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }
        guard identityIsInsideMutationScope(request.identity, target: target) else {
            return .failed("This rename reaches outside the represented workspace scope and cannot be staged here.")
        }

        if let outcome = await singleMutationPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration
        ) {
            return outcome
        }

        do {
            try await execute(request, at: target)
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }
            guard generation == requestedGeneration, self.target == target else {
                return .failed("The checkout changed before the index-lock retry.")
            }
            // The contender may have changed both index and worktree. Re-read the authoritative
            // status and re-check the cheap content revision before issuing the sole retry.
            if let outcome = await singleMutationPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration
            ) {
                return outcome
            }
            do {
                try await execute(request, at: target)
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

    /// Returns an outcome when the request must stop, or nil when one mutation command may run.
    private func singleMutationPreflight(
        _ request: AgentChangesMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async -> AgentChangesMutationOutcome? {
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }
        guard contentRevision(forRepositoryRelativePath: request.identity.path)
            == request.expectedContentRevision
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(at: target.checkoutURL)
        } catch {
            return .failed(error.localizedDescription)
        }

        // This second cheap check closes the status-subprocess window: a content event can advance
        // the revision while the actor is suspended in `loadIndexStatus`.
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }
        guard contentRevision(forRepositoryRelativePath: request.identity.path)
            == request.expectedContentRevision
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        }

        let entry = entries.first { $0.path == request.identity.path }
        if entry?.isConflicted == true { return .conflicted }
        if isDesiredState(entry: entry, stage: request.stage) { return .noOp }
        return nil
    }

    private func execute(
        _ request: AgentChangesMutationRequest,
        at target: AgentPanelResolvedCheckout
    ) async throws {
        if request.stage {
            try await indexBackend.stage([request.identity], at: target.checkoutURL)
        } else {
            try await indexBackend.unstage([request.identity], at: target.checkoutURL)
        }
    }

    /// Marks a conflict resolved by staging exactly the current path contents.
    ///
    /// This intentionally mirrors ordinary staging's generation, content-review preflight,
    /// repository serialization, invalidation, and forced-rebuild ordering while keeping a
    /// distinct entry point so the UI can never disguise resolution as a checkbox state.
    func markResolved(_ request: AgentChangesResolveRequest) async -> AgentChangesMutationOutcome {
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this conflict could be resolved.")
        }
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this conflict could be resolved.")
        }
        guard identityIsInsideMutationScope(request.identity, target: target) else {
            return .failed("This conflict is outside the represented workspace scope.")
        }
        if let outcome = await resolutionPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration
        ) {
            return outcome
        }

        do {
            try await indexBackend.markResolved(request.identity, at: target.checkoutURL)
        } catch GitIndexMutationError.indexLocked {
            do {
                try await scheduler.sleep(for: indexLockRetryDelay)
            } catch {
                return .failed(error.localizedDescription)
            }
            if let outcome = await resolutionPreflight(
                request,
                target: target,
                requestedGeneration: requestedGeneration
            ) {
                return outcome
            }
            do {
                try await indexBackend.markResolved(request.identity, at: target.checkoutURL)
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
        requestedGeneration: UInt64
    ) async -> AgentChangesMutationOutcome? {
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this conflict could be resolved.")
        }
        guard contentRevision(forRepositoryRelativePath: request.identity.path)
            == request.expectedContentRevision
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(at: target.checkoutURL)
        } catch {
            return .failed(error.localizedDescription)
        }

        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this conflict could be resolved.")
        }
        guard contentRevision(forRepositoryRelativePath: request.identity.path)
            == request.expectedContentRevision
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .contentChanged
        }
        guard let entry = entries.first(where: { $0.path == request.identity.path }),
              entry.isConflicted
        else {
            return .noOp
        }
        return nil
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
        let requestedGeneration = generation
        guard let target,
              mode.allowsStaging,
              request.section.isStageable,
              target.isMutationScopeRepresentable
        else { return .unsupported }

        let capabilities = await resolveCapabilities(for: target)
        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }
        guard capabilities.supportsStaging else { return .unsupported }

        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard generation == requestedGeneration, self.target == target else {
            return .failed("The checkout changed before this change could be applied.")
        }

        let identities: [VCSIndexPathIdentity]
        switch await bulkMutationPreflight(
            request,
            target: target,
            requestedGeneration: requestedGeneration
        ) {
        case let .ready(preflightIdentities):
            identities = preflightIdentities
        case let .stop(outcome):
            return outcome
        }

        do {
            try await executeBulk(identities, stage: request.stage, at: target)
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
                requestedGeneration: requestedGeneration
            ) {
            case let .ready(preflightIdentities):
                retryIdentities = preflightIdentities
            case let .stop(outcome):
                return outcome
            }
            do {
                try await executeBulk(retryIdentities, stage: request.stage, at: target)
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
        case ready([VCSIndexPathIdentity])
        case stop(AgentChangesMutationOutcome)
    }

    private func bulkMutationPreflight(
        _ request: AgentChangesBulkMutationRequest,
        target: AgentPanelResolvedCheckout,
        requestedGeneration: UInt64
    ) async -> BulkMutationPreflight {
        guard generation == requestedGeneration, self.target == target else {
            return .stop(.failed("The checkout changed before this change could be applied."))
        }
        guard request.reviewed.allSatisfy({
            contentRevision(forRepositoryRelativePath: $0.identity.path) == $0.contentRevision
        }) else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        let entries: [VCSIndexStatusEntry]
        do {
            entries = try await indexBackend.loadIndexStatus(at: target.checkoutURL)
        } catch {
            return .stop(.failed(error.localizedDescription))
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

        let reviewedIdentities = Set(request.reviewed.map(\.identity))
        guard Set(identities) == reviewedIdentities else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }

        // Re-check after the status subprocess, immediately before the caller issues Git.
        guard generation == requestedGeneration,
              self.target == target,
              request.reviewed.allSatisfy({
                  contentRevision(forRepositoryRelativePath: $0.identity.path) == $0.contentRevision
              })
        else {
            await performRebuild(bypassingFingerprintGate: true)
            return .stop(.contentChanged)
        }
        guard !identities.isEmpty else { return .stop(.noOp) }
        return .ready(identities)
    }

    private func executeBulk(
        _ identities: [VCSIndexPathIdentity],
        stage: Bool,
        at target: AgentPanelResolvedCheckout
    ) async throws {
        if stage {
            try await indexBackend.stage(identities, at: target.checkoutURL)
        } else {
            try await indexBackend.unstage(identities, at: target.checkoutURL)
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
