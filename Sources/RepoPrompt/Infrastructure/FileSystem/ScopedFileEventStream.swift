import CoreFoundation
import CoreServices
import Dispatch
import Foundation

/// Why a scoped watch could not be activated.
///
/// Activation failures are thrown instead of being folded into a stream that simply never yields:
/// the Changes panel and the document preview both degrade to a slow poll when they cannot watch,
/// and a silent empty stream is indistinguishable from a quiet filesystem, so they would degrade
/// into showing stale content forever.
enum ScopedFileEventStreamError: LocalizedError, Equatable {
    case noPathsRequested
    case invalidPath(String)
    case missingPath(String)
    case streamCreationFailed(paths: [String])
    case streamStartFailed(paths: [String])

    var errorDescription: String? {
        switch self {
        case .noPathsRequested:
            "Scoped file watching requires at least one path."
        case let .invalidPath(path):
            "Scoped file watching requires an absolute filesystem path, but received \(path)."
        case let .missingPath(path):
            "Scoped file watching found nothing at \(path)."
        case let .streamCreationFailed(paths):
            "Scoped file event stream creation failed for \(paths.joined(separator: ", "))."
        case let .streamStartFailed(paths):
            "Scoped file event stream activation failed for \(paths.joined(separator: ", "))."
        }
    }
}

/// One debounce window's worth of filesystem activity inside a watched scope.
struct ScopedFileChangeBatch: Equatable {
    /// Symlink-resolved absolute paths that changed. A path appears once per batch however many raw
    /// FSEvents named it, so consumers can treat the batch as the work list for one rebuild.
    let paths: Set<String>

    /// FSEvents coalesced or dropped history for this window, so `paths` is a floor rather than the
    /// full set. Consumers should rebuild from disk instead of trusting it.
    let mayHaveMissedEvents: Bool
}

/// Watches an explicit set of files and directories that may sit outside every workspace root, and
/// publishes debounced batches of the in-scope paths that changed.
///
/// `FileSystemService` already watches workspace roots, but it is bound to one root and carries the
/// catalog, ignore-rule, and selection state that root needs. Agent worktrees under the app-managed
/// container and Obsidian vault documents are outside every root, so they need a watcher that owns
/// nothing but the watch.
///
/// One instance owns one FSEvents stream and one `AsyncStream`, and `changes` is written for a
/// single consumer. Two features watching the same worktree each construct their own instance
/// rather than sharing this one, so neither can consume the other's batches or tear down the
/// other's watch. The watch lives exactly as long as the instance: dropping the last reference
/// finishes `changes`.
final class ScopedFileEventStream: @unchecked Sendable {
    /// Debounced batches of in-scope changes, in observation order.
    let changes: AsyncStream<ScopedFileChangeBatch>

    private let targets: [WatchTarget]
    private let watchRootPaths: [String]
    private let queue: DispatchQueue
    private let continuation: AsyncStream<ScopedFileChangeBatch>.Continuation

    /// Guards teardown against a concurrent `cancel` from the consumer's cancellation path.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var streamWasStarted = false
    private var contextPointer: UnsafeMutableRawPointer?
    private var isCancelled = false

    /// Touched only on `queue`, which is where FSEvents delivers and where the debounce fires.
    private var batchAccumulator: ScopedFileEventBatchAccumulator
    private var flushGeneration: UInt64 = 0

    /// FSEvents flags that mean history was coalesced or dropped rather than reported per item.
    private static let historyGapFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
    )

    /// - Parameters:
    ///   - paths: absolute paths to watch. A directory is watched as a subtree; a file is watched
    ///     exactly, through its parent directory, so replacing or deleting it still reports.
    ///   - debounce: how long the scope must go quiet before a batch is published. Callers use
    ///     150–400ms: long enough that an agent rewriting a dozen files produces one rebuild,
    ///     short enough that a save feels live. Continuous activity is capped at a 500ms batch age.
    /// - Throws: ``ScopedFileEventStreamError`` when the scope cannot be watched.
    init(paths: [URL], debounce: Duration = .milliseconds(250)) throws {
        guard !paths.isEmpty else { throw ScopedFileEventStreamError.noPathsRequested }
        let targets = try Self.resolveTargets(paths)
        let watchRootPaths = Set(targets.map(\.watchRootPath)).sorted()
        self.targets = targets
        self.watchRootPaths = watchRootPaths
        batchAccumulator = ScopedFileEventBatchAccumulator(
            debounceSeconds: max(0, Self.seconds(from: debounce)),
            maximumBatchAgeSeconds: 0.5
        )
        queue = DispatchQueue(
            label: "com.repoprompt.scoped-file-events.\(UUID().uuidString)",
            qos: .utility
        )
        (changes, continuation) = AsyncStream<ScopedFileChangeBatch>.makeStream()

        // The callback context holds the stream weakly so the FSEvents retain cannot keep this
        // instance alive past its owner, matching `FileSystemServiceFSEventCallbackContext`.
        let callbackContext = ScopedFileEventCallbackContext()
        let contextPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        self.contextPointer = contextPointer

        callbackContext.owner = self
        // A consumer that cancels its task, or breaks out of `for await`, has stopped caring about
        // this scope; tear the watch down with it rather than leaving an orphaned FSEvents stream.
        continuation.onTermination = { [weak self] _ in self?.cancel() }

        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        // Zero FSEvents latency: coalescing is this type's own debounce, which spans every watch
        // root at once and is the value the caller configured.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &streamContext,
            watchRootPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            cancel()
            throw ScopedFileEventStreamError.streamCreationFailed(paths: watchRootPaths)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            cancel()
            throw ScopedFileEventStreamError.streamStartFailed(paths: watchRootPaths)
        }
        streamWasStarted = true
        // Starting a dispatch-backed stream arms it asynchronously. Flushing and then crossing the
        // queue makes `init` an activation barrier, closing the race where a caller writes
        // immediately after construction and loses that first change.
        FSEventStreamFlushSync(stream)
        queue.sync {}
    }

    deinit {
        cancel()
    }

    /// Tears the watch down and finishes `changes`.
    ///
    /// Idempotent and safe from any thread, because the consumer's cancellation path and the
    /// owner's teardown can both reach it.
    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let stream = stream
        self.stream = nil
        let streamWasStarted = streamWasStarted
        self.streamWasStarted = false
        let contextPointer = contextPointer
        self.contextPointer = nil
        lock.unlock()

        // Teardown runs behind every callback already executing on `queue`. Invalidating there
        // unschedules the stream before the context is released, so no callback can race the
        // unretained context pointer from another thread.
        queue.async {
            if let stream {
                if streamWasStarted {
                    FSEventStreamStop(stream)
                }
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            if let contextPointer {
                Unmanaged<ScopedFileEventCallbackContext>.fromOpaque(contextPointer).release()
            }
        }
        // A debounce flush may already be scheduled on `queue`. Yielding to a finished continuation
        // is a no-op, so teardown does not have to drain it.
        continuation.finish()
    }

    // MARK: - Scope resolution

    private struct WatchTarget {
        enum Scope {
            case subtree
            case exactFile
        }

        let canonicalPath: String
        let watchRootPath: String
        let scope: Scope

        func contains(_ canonicalEventPath: String) -> Bool {
            switch scope {
            case .subtree:
                canonicalEventPath == canonicalPath || canonicalEventPath.hasPrefix(canonicalPath + "/")
            case .exactFile:
                canonicalEventPath == canonicalPath
            }
        }
    }

    private static func resolveTargets(_ paths: [URL]) throws -> [WatchTarget] {
        let manager = FileManager.default
        var targetsByPath: [String: WatchTarget] = [:]
        for requested in paths {
            // FSEvents reports canonical volume paths (/private/var rather than the /var symlink),
            // so containment only holds if targets are canonicalized the same way up front.
            let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.isFileURL, resolved.path.hasPrefix("/"), !resolved.path.contains("\0") else {
                throw ScopedFileEventStreamError.invalidPath(requested.path)
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
                // Deliberately not widened to the nearest existing ancestor. An unhydrated worktree
                // or a deleted document is exactly when the caller must degrade to polling, not
                // when it should silently start watching a parent it never asked for.
                throw ScopedFileEventStreamError.missingPath(requested.path)
            }
            // A file is watched through its parent because FSEvents watches directories; the exact
            // scope then filters the siblings back out.
            let target = isDirectory.boolValue
                ? WatchTarget(canonicalPath: resolved.path, watchRootPath: resolved.path, scope: .subtree)
                : WatchTarget(
                    canonicalPath: resolved.path,
                    watchRootPath: resolved.deletingLastPathComponent().path,
                    scope: .exactFile
                )
            targetsByPath[target.canonicalPath] = target
        }
        return targetsByPath.values.sorted { $0.canonicalPath < $1.canonicalPath }
    }

    /// Canonicalizes an FSEvents path without resolving its final component.
    ///
    /// The last component is left alone on purpose: a deleted or replaced file has nothing left to
    /// resolve, and resolving a symlinked document would report its destination instead of the path
    /// the caller asked to watch.
    private static func canonicalEventPath(_ eventPath: String) -> String? {
        let url = URL(fileURLWithPath: eventPath).standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
        guard url.path != "/" else { return "/" }
        return url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
            .path
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    // MARK: - Event ingestion

    private static let callback: FSEventStreamCallback = {
        _, context, eventCount, eventPaths, eventFlags, eventIDs in
        guard let context else { return }
        let callbackContext = Unmanaged<ScopedFileEventCallbackContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        guard let owner = callbackContext.owner else { return }
        owner.ingest(
            eventCount: Int(eventCount),
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIDs: eventIDs
        )
    }

    /// Runs on `queue`; FSEvents delivers every callback there.
    private func ingest(
        eventCount: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        guard let payload = FileSystemService.buildOwnedFSEventPayload(
            numEvents: eventCount,
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIds: eventIDs
        ) else { return }

        var acceptedPaths: Set<String> = []
        var mayHaveMissedEvents = false
        for entry in payload.entries {
            // A gap is reported against a watch root this instance asked for, so in-scope changes
            // may be hiding inside it whatever the event's own path says.
            if entry.flags & Self.historyGapFlags != 0 {
                mayHaveMissedEvents = true
            }
            guard let canonicalPath = Self.canonicalEventPath(entry.path),
                  targets.contains(where: { $0.contains(canonicalPath) })
            else { continue }
            acceptedPaths.insert(canonicalPath)
        }
        guard !acceptedPaths.isEmpty || mayHaveMissedEvents else { return }
        let deadline = batchAccumulator.accept(
            paths: acceptedPaths,
            mayHaveMissedEvents: mayHaveMissedEvents,
            at: ProcessInfo.processInfo.systemUptime
        )
        scheduleFlush(at: deadline)
    }

    /// Keeps the short trailing quiet period for burst coalescing, but clamps it to the first
    /// pending event's 500ms deadline so continuous writes cannot starve the consumer indefinitely.
    private func scheduleFlush(at deadline: TimeInterval) {
        flushGeneration &+= 1
        let generation = flushGeneration
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == flushGeneration else { return }
            flush()
        }
    }

    private func flush() {
        guard let batch = batchAccumulator.flush() else { return }
        continuation.yield(batch)
    }
}

/// Queue-confined batching state. Time is passed in so the maximum-age contract can be exercised
/// deterministically without sleeping or depending on FSEvents delivery.
struct ScopedFileEventBatchAccumulator {
    private let debounceSeconds: TimeInterval
    private let maximumBatchAgeSeconds: TimeInterval
    private var firstPendingEventTime: TimeInterval?
    private var pendingPaths: Set<String> = []
    private var pendingMayHaveMissedEvents = false

    init(debounceSeconds: TimeInterval, maximumBatchAgeSeconds: TimeInterval) {
        self.debounceSeconds = max(0, debounceSeconds)
        self.maximumBatchAgeSeconds = max(0, maximumBatchAgeSeconds)
    }

    mutating func accept(
        paths: Set<String>,
        mayHaveMissedEvents: Bool,
        at time: TimeInterval
    ) -> TimeInterval {
        let firstEventTime = firstPendingEventTime ?? time
        firstPendingEventTime = firstEventTime
        pendingPaths.formUnion(paths)
        pendingMayHaveMissedEvents = pendingMayHaveMissedEvents || mayHaveMissedEvents
        return min(time + debounceSeconds, firstEventTime + maximumBatchAgeSeconds)
    }

    mutating func flush() -> ScopedFileChangeBatch? {
        let batch = ScopedFileChangeBatch(
            paths: pendingPaths,
            mayHaveMissedEvents: pendingMayHaveMissedEvents
        )
        firstPendingEventTime = nil
        pendingPaths.removeAll(keepingCapacity: true)
        pendingMayHaveMissedEvents = false
        return batch.paths.isEmpty && !batch.mayHaveMissedEvents ? nil : batch
    }
}

/// Weak indirection between the FSEvents retain and the stream it feeds, so the C callback can
/// find its owner without keeping that owner alive.
private final class ScopedFileEventCallbackContext {
    weak var owner: ScopedFileEventStream?
}
