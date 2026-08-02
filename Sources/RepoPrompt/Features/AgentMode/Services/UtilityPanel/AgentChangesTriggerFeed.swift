import AppKit
import Foundation
import OSLog

// MARK: - Scheduler seam

/// The only time the Changes panel's data layer spends.
///
/// Injected so the batching window and the degraded poll can be driven deterministically in tests
/// instead of by real sleeps, which would make the suite both slow and flaky.
protocol AgentChangesScheduler: Sendable {
    func sleep(for duration: Duration) async throws
}

struct AgentChangesLiveScheduler: AgentChangesScheduler {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Trigger feed

/// A source of rebuild triggers for one checkout.
protocol AgentChangesTriggerFeed: Sendable {
    /// The merged trigger stream. Finishes when the feed is cancelled.
    func events() -> AsyncStream<AgentChangesRefreshTrigger>
    func cancel()
}

/// A live scoped watch, plus the handle that keeps it running.
///
/// `ScopedFileEventStream` tears its watch down when the last reference drops, so the stream alone
/// is not enough to hold one open; `cancel` owns that reference.
struct AgentChangesScopedWatch {
    let batches: AsyncStream<ScopedFileChangeBatch>
    let cancel: @Sendable () -> Void

    /// Wraps a real `ScopedFileEventStream`, retaining it for the watch's lifetime.
    static func live(paths: [URL], debounce: Duration) throws -> AgentChangesScopedWatch {
        let stream = try ScopedFileEventStream(paths: paths, debounce: debounce)
        return AgentChangesScopedWatch(batches: stream.changes, cancel: { stream.cancel() })
    }
}

/// The upstream event sources a live feed fans in.
///
/// Passed as closures rather than concrete services because their owners live at different layers:
/// `.git` invalidations come from an app-wide actor, workspace content deltas come from the
/// `FileSystemService` of whichever root is loaded, and reconcile pulses come from AppKit
/// notifications. The feed's job is the merge, not the acquisition.
struct AgentChangesTriggerSources {
    /// `.git` metadata invalidations already filtered to this checkout's repository.
    var metadataEvents: @Sendable () -> AsyncStream<Void>

    /// Absolute paths that changed inside workspace roots the app already watches.
    var workspaceContentDeltas: @Sendable () -> AsyncStream<Set<String>>

    /// App activation and wake pulses.
    var reconcilePulses: @Sendable () -> AsyncStream<Void>

    init(
        metadataEvents: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
        workspaceContentDeltas: @escaping @Sendable () -> AsyncStream<Set<String>> = { AsyncStream { $0.finish() } },
        reconcilePulses: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    ) {
        self.metadataEvents = metadataEvents
        self.workspaceContentDeltas = workspaceContentDeltas
        self.reconcilePulses = reconcilePulses
    }
}

/// Merges every refresh signal for one checkout into a single trigger stream.
///
/// The one piece of policy that lives here rather than in the repository is watch degradation: this
/// type owns the scoped watcher, so it is the only place that learns the watch could not be
/// created. When that happens it substitutes a 5s poll for that checkout and says so in the log —
/// an agent worktree outside every workspace root is otherwise invisible to the app, and a silently
/// dead watch would leave the panel showing a frozen diff with no indication anything was wrong.
final class AgentChangesLiveTriggerFeed: AgentChangesTriggerFeed, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ChangesTriggers")

    private let sources: AgentChangesTriggerSources
    private let scopedWatchPaths: [URL]
    private let makeScopedWatch: @Sendable ([URL]) throws -> AgentChangesScopedWatch
    private let scheduler: any AgentChangesScheduler
    private let pollInterval: Duration
    private let scopedWatchDebounce: Duration

    private let lock = NSLock()
    private var pumpTask: Task<Void, Never>?
    private var activeWatch: AgentChangesScopedWatch?
    private var isCancelled = false

    /// - Parameters:
    ///   - scopedWatchPaths: paths needing a dedicated watch because no workspace root covers them.
    ///     Empty for an in-root checkout, which the workspace watcher already reports on.
    ///   - pollInterval: the degraded cadence used only after a watch failure.
    init(
        sources: AgentChangesTriggerSources,
        scopedWatchPaths: [URL] = [],
        scopedWatchDebounce: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(5),
        scheduler: any AgentChangesScheduler = AgentChangesLiveScheduler(),
        makeScopedWatch: (@Sendable ([URL]) throws -> AgentChangesScopedWatch)? = nil
    ) {
        self.sources = sources
        self.scopedWatchPaths = scopedWatchPaths
        self.scopedWatchDebounce = scopedWatchDebounce
        self.pollInterval = pollInterval
        self.scheduler = scheduler
        let debounce = scopedWatchDebounce
        self.makeScopedWatch = makeScopedWatch ?? { paths in
            try AgentChangesScopedWatch.live(paths: paths, debounce: debounce)
        }
    }

    deinit {
        cancel()
    }

    func events() -> AsyncStream<AgentChangesRefreshTrigger> {
        let (stream, continuation) = AsyncStream<AgentChangesRefreshTrigger>.makeStream()

        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.finish()
            return stream
        }
        // A second subscriber would silently steal the first one's events, so replacing the pump is
        // the honest behavior: the previous stream finishes rather than going quiet.
        pumpTask?.cancel()
        let task = Task { [weak self] in
            await self?.pump(into: continuation)
            continuation.finish()
        }
        pumpTask = task
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.lock()
            let shouldCancel = pumpTask == task
            if shouldCancel { pumpTask = nil }
            lock.unlock()
            if shouldCancel { task.cancel() }
        }
        return stream
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = pumpTask
        pumpTask = nil
        let watch = activeWatch
        activeWatch = nil
        lock.unlock()

        task?.cancel()
        watch?.cancel()
    }

    // MARK: - Fan-in

    private func pump(into continuation: AsyncStream<AgentChangesRefreshTrigger>.Continuation) async {
        let sources = sources
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in sources.metadataEvents() {
                    continuation.yield(.metadata)
                }
            }
            group.addTask {
                for await paths in sources.workspaceContentDeltas() {
                    continuation.yield(.contentDelta(paths: paths))
                }
            }
            group.addTask {
                for await _ in sources.reconcilePulses() {
                    continuation.yield(.reconcile)
                }
            }
            addScopedWatchTask(to: &group, continuation: continuation)
            await group.waitForAll()
        }
    }

    private func addScopedWatchTask(
        to group: inout TaskGroup<Void>,
        continuation: AsyncStream<AgentChangesRefreshTrigger>.Continuation
    ) {
        guard !scopedWatchPaths.isEmpty else { return }

        let watch: AgentChangesScopedWatch
        do {
            watch = try makeScopedWatch(scopedWatchPaths)
        } catch {
            let scope = scopedWatchPaths.map(\.path).joined(separator: ", ")
            let seconds = pollInterval.components.seconds
            Self.logger.warning(
                "Scoped watch unavailable for \(scope, privacy: .public); falling back to a \(seconds, privacy: .public)s poll: \(error.localizedDescription, privacy: .public)"
            )
            let scheduler = scheduler
            let interval = pollInterval
            group.addTask {
                while !Task.isCancelled {
                    do {
                        try await scheduler.sleep(for: interval)
                    } catch {
                        return
                    }
                    continuation.yield(.poll)
                }
            }
            return
        }

        lock.lock()
        let cancelled = isCancelled
        if !cancelled { activeWatch = watch }
        lock.unlock()
        guard !cancelled else {
            watch.cancel()
            return
        }

        group.addTask {
            for await batch in watch.batches {
                if batch.mayHaveMissedEvents {
                    // Empty paths are the cross-worker full-resync signal: filtering a history-gap
                    // event down to its watch-root path must not suppress the authoritative rebuild.
                    continuation.yield(.contentDelta(paths: []))
                }
                if !batch.paths.isEmpty {
                    continuation.yield(.contentDelta(paths: batch.paths))
                }
            }
        }
    }
}

// MARK: - Live source adapters

extension AgentChangesTriggerSources {
    /// `.git` metadata invalidations for one repository, as a path-free wakeup stream.
    ///
    /// Filtered to the checkout's own repository key so a busy sibling repository in the same
    /// workspace cannot make this panel rebuild.
    static func metadataEvents(
        forCheckout checkout: URL,
        authority: GitWorkspaceStateAuthority = .shared
    ) -> @Sendable () -> AsyncStream<Void> {
        { @Sendable in
            guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: checkout) else {
                return AsyncStream { $0.finish() }
            }
            let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
            return AsyncStream { continuation in
                let task = Task {
                    for await event in await authority.invalidationEvents()
                        where event.repositoryKey == key
                    {
                        continuation.yield(())
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// App activation and system wake, the two moments the app can be sure it stopped listening.
    static func appActivationPulses(
        center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> @Sendable () -> AsyncStream<Void> {
        { @Sendable in
            AsyncStream { continuation in
                let activation = center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: nil
                ) { _ in continuation.yield(()) }
                let wake = workspaceCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification,
                    object: nil,
                    queue: nil
                ) { _ in continuation.yield(()) }
                continuation.onTermination = { _ in
                    center.removeObserver(activation)
                    workspaceCenter.removeObserver(wake)
                }
            }
        }
    }
}
