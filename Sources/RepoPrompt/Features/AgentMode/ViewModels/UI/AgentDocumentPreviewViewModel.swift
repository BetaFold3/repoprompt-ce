import Combine
import Foundation
import OSLog

// SEARCH-HELPER: AgentDocumentPreviewViewModel, preview document resolution, live reload, containment

// MARK: - Roots

/// One logical workspace root, as the Preview segment resolves document references against it.
///
/// Deliberately not `WorkspaceRootRef`: the preview needs only an identity, a display name, and a
/// path, and taking the workspace type would drag the whole context store into every test that
/// wants to prove a `..` escape is rejected.
struct AgentPreviewDocumentRoot: Equatable, Identifiable {
    /// `WorkspaceRootRef.id`, which is what `PreviewDocumentReference` stores.
    let id: UUID
    let name: String
    /// Standardized absolute path of the logical root.
    let path: String

    init(id: UUID, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var displayName: String {
        name.isEmpty ? (path as NSString).lastPathComponent : name
    }
}

/// The workspace facts a `PreviewDocumentReference` is resolved against.
///
/// Held as a value and re-supplied whenever it changes rather than read from a live store, so a
/// worktree binding that hydrates mid-session re-resolves the open document instead of leaving the
/// panel pointed at the checkout the reference was created under.
struct AgentPreviewResolutionContext: Equatable {
    var roots: [AgentPreviewDocumentRoot]
    var worktreeBindings: [AgentSessionWorktreeBinding]

    init(
        roots: [AgentPreviewDocumentRoot] = [],
        worktreeBindings: [AgentSessionWorktreeBinding] = []
    ) {
        self.roots = roots
        self.worktreeBindings = worktreeBindings
    }

    func root(id: UUID) -> AgentPreviewDocumentRoot? {
        roots.first { $0.id == id }
    }

    /// The directory a root's documents are actually read from.
    ///
    /// A bound worktree wins over the logical root, matching `AgentPanelCheckoutResolver`: a
    /// session reviewing an agent's work must read the agent's checkout, never the user's.
    /// Unlike the Changes panel this never blocks on an unavailable worktree — a preview is a
    /// read, so the worst case is a missing document rather than a mutation aimed at the wrong
    /// working tree.
    func checkoutRootPath(forRootPath rootPath: String) -> String {
        let standardized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let binding = worktreeBindings.first {
            URL(fileURLWithPath: $0.logicalRootPath).standardizedFileURL.path == standardized
        }
        guard let binding else { return standardized }
        return URL(fileURLWithPath: binding.worktreeRootPath).standardizedFileURL.path
    }
}

// MARK: - Resolution

/// Why a reference could not be turned into a readable path.
enum AgentPreviewResolutionFailure: Error, Equatable {
    /// The reference names a root this workspace no longer has.
    case unknownRoot
    /// The reference has no path, or a path that collapses to the root itself.
    case emptyPath
    /// Not a document family the preview renders.
    case unsupportedKind(String)
    /// Decision row 15: the fully resolved path — symlinks included — leaves the checkout.
    case outsideScope
}

/// A reference proven to name a readable file inside its own checkout.
struct AgentPreviewResolvedDocument: Equatable {
    let reference: PreviewDocumentReference
    let rootName: String
    /// The directory the document is read from and contained by.
    let checkoutRootURL: URL
    /// Symlink-resolved absolute location, already proven to be inside ``checkoutRootURL``.
    let fileURL: URL
    let kind: AgentSessionArtifactKind

    var fileName: String {
        reference.fileName
    }

    /// Path shown in the header's tooltip: root-relative, prefixed by the root's display name.
    var displayPath: String {
        "\(rootName)/\(reference.relativePath)"
    }
}

/// Turns a `PreviewDocumentReference` into an absolute path, or refuses.
///
/// Pure apart from symlink resolution, which is the whole point: decision row 15 requires the
/// containment check to run against the *resolved* path, because an agent can drop a symlink next
/// to the report it just wrote and a purely lexical check would happily follow it out of the
/// checkout. `resolvingSymlinksInPath` resolves the longest existing prefix, so a link planted at
/// any level of the path is caught even when the leaf does not exist yet.
enum AgentPreviewDocumentResolver {
    static func resolve(
        _ reference: PreviewDocumentReference,
        in context: AgentPreviewResolutionContext
    ) -> Result<AgentPreviewResolvedDocument, AgentPreviewResolutionFailure> {
        guard let root = context.root(id: reference.rootID) else {
            return .failure(.unknownRoot)
        }
        let relativePath = reference.relativePath
        guard !relativePath.isEmpty else { return .failure(.emptyPath) }

        let fileExtension = (relativePath as NSString).pathExtension
        guard let kind = AgentSessionArtifactKind(fileExtension: fileExtension) else {
            return .failure(.unsupportedKind(fileExtension))
        }

        let checkoutRootPath = context.checkoutRootPath(forRootPath: root.path)
        let checkoutRootURL = URL(fileURLWithPath: checkoutRootPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedFileURL = URL(fileURLWithPath: checkoutRootPath)
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard isContained(resolvedFileURL, in: checkoutRootURL) else {
            return .failure(.outsideScope)
        }

        return .success(AgentPreviewResolvedDocument(
            reference: reference,
            rootName: root.displayName,
            checkoutRootURL: checkoutRootURL,
            fileURL: resolvedFileURL,
            kind: kind
        ))
    }

    /// Strict containment: the checkout directory itself is not a document, so equality fails.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let directoryPath = directory.path
        let candidate = url.path
        guard candidate != directoryPath else { return false }
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidate.hasPrefix(prefix)
    }
}

// MARK: - Loading seam

/// What one read of a document produced.
struct AgentPreviewFileAttributes: Equatable {
    let byteCount: Int
    let modifiedAt: Date?
}

/// A document read, with its text omitted when the file is past the render budget.
struct AgentPreviewLoadedFile: Equatable {
    /// `nil` when `attributes.byteCount` exceeded the caller's limit; nothing was decoded.
    let text: String?
    let attributes: AgentPreviewFileAttributes
}

enum AgentPreviewLoadError: Error, Equatable {
    case missing
    case unreadable(String)
}

/// The result of one off-main document read.
///
/// A closed, `Sendable` outcome rather than `Result<_, Error>` so the value can cross back to the
/// main actor without laundering an existential error through the boundary.
enum AgentPreviewLoadOutcome: Equatable {
    case loaded(AgentPreviewLoadedFile)
    case failed(AgentPreviewLoadError)
}

/// The only disk reads the preview performs.
///
/// A seam rather than direct `FileManager` use so state-machine tests can drive a missing file, an
/// oversized file, and a decode failure without arranging each on a real volume.
protocol AgentPreviewDocumentLoading: Sendable {
    /// Size and modification date only — the gate the degraded poll uses so a 2 MB file is not
    /// re-read every couple of seconds just to discover it has not changed.
    func attributes(of url: URL) throws -> AgentPreviewFileAttributes
    /// Reads the file, decoding only when it fits inside `byteLimit`.
    func load(_ url: URL, byteLimit: Int) throws -> AgentPreviewLoadedFile
}

extension AgentPreviewDocumentLoading {
    /// `load` with every failure mapped onto the closed outcome the view model consumes.
    func loadOutcome(_ url: URL, byteLimit: Int) -> AgentPreviewLoadOutcome {
        do {
            return try .loaded(load(url, byteLimit: byteLimit))
        } catch let error as AgentPreviewLoadError {
            return .failed(error)
        } catch {
            return .failed(.unreadable(error.localizedDescription))
        }
    }
}

struct AgentPreviewLiveDocumentLoader: AgentPreviewDocumentLoading {
    func attributes(of url: URL) throws -> AgentPreviewFileAttributes {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            throw AgentPreviewLoadError.missing
        }
        return AgentPreviewFileAttributes(
            byteCount: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate
        )
    }

    func load(_ url: URL, byteLimit: Int) throws -> AgentPreviewLoadedFile {
        let attributes = try attributes(of: url)
        guard attributes.byteCount <= byteLimit else {
            return AgentPreviewLoadedFile(text: nil, attributes: attributes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
            {
                throw AgentPreviewLoadError.missing
            }
            throw AgentPreviewLoadError.unreadable(error.localizedDescription)
        }
        // Lossy UTF-8 rather than a decode failure: a report with one stray byte should still be
        // readable, and the semi-rendered compiler's invariant is about the string it is handed,
        // not about the file's bytes.
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return AgentPreviewLoadedFile(text: text, attributes: attributes)
    }
}

// MARK: - Watching seam

/// Builds the watch that drives live reload for one document.
///
/// Returns the same `AgentChangesScopedWatch` handle the Changes panel uses, so both halves of the
/// utility panel degrade through one tested mechanism. Throwing is meaningful: the caller must fall
/// back to polling rather than sit on a watch that will never fire.
struct AgentPreviewWatchFactory {
    var makeWatch: @Sendable (URL) throws -> AgentChangesScopedWatch

    /// Watches the document itself.
    ///
    /// Deliberately a `ScopedFileEventStream` for every document, in or out of a workspace root:
    /// the preview follows exactly one file, so a dedicated watch is both cheaper than filtering a
    /// whole root's delta firehose and free of the workspace indexer's ignore-rule blind spots — an
    /// agent report written into an ignored directory still live-reloads. `ScopedFileEventStream`
    /// watches a file through its parent directory, so atomic replaces and deletions report too.
    static let live = AgentPreviewWatchFactory { url in
        try AgentChangesScopedWatch.live(
            paths: [url],
            debounce: AgentDocumentPreviewViewModel.watchCoalescingWindow
        )
    }
}

// MARK: - State

/// What the Preview segment is showing.
enum AgentPreviewDocumentState: Equatable {
    /// No document has been selected; the picker is showing.
    case empty
    /// A first load of this document is in flight. Reloads never enter this case — see
    /// ``AgentDocumentPreviewViewModel`` for why.
    case loading(AgentPreviewResolvedDocument)
    case ready(AgentPreviewDocumentContent)
    /// Past the render budget; the panel offers "Open in Editor" instead.
    case tooLarge(AgentPreviewResolvedDocument, byteCount: Int)
    case missing(AgentPreviewResolvedDocument)
    /// The reference cannot name a readable file at all.
    case unresolvable(PreviewDocumentReference, AgentPreviewResolutionFailure)
    case failed(AgentPreviewResolvedDocument, message: String)

    var document: AgentPreviewResolvedDocument? {
        switch self {
        case .empty, .unresolvable:
            nil
        case let .loading(document),
             let .tooLarge(document, _),
             let .missing(document),
             let .failed(document, _):
            document
        case let .ready(content):
            content.document
        }
    }

    var content: AgentPreviewDocumentContent? {
        guard case let .ready(content) = self else { return nil }
        return content
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// A document that loaded, and the text it loaded.
struct AgentPreviewDocumentContent: Equatable {
    let document: AgentPreviewResolvedDocument
    let text: String
    /// Bumped only when the bytes actually changed.
    ///
    /// Views key their reload-sensitive work on this instead of on watch activity, so a save that
    /// rewrites a file with identical contents — or a watch batch that names a sibling — costs
    /// nothing. It is also what lets the HTML surface reload only on a real edit.
    let revision: Int
}

// MARK: - View model

/// Drives one Preview surface: resolve, load, watch, reload.
///
/// # Reloads never show a spinner
///
/// The single most important behaviour here is that a *reload* of the document already on screen
/// stays in `.ready` — it swaps the text inside the existing content rather than passing back
/// through `.loading`. That is what makes decision row 15's "scroll position restored after
/// re-render" true: the document view keeps its identity, so AppKit keeps the text view and SwiftUI
/// keeps the scroll offset. Flipping to `.loading` for a 30 ms file read would unmount the text
/// view and snap a reader who was 400 lines deep back to the top on every agent keystroke.
/// Selecting a *different* document does start at `.loading`, and there the reset to the top is
/// correct.
///
/// # Watch degradation
///
/// A watch that cannot be created is reported, not swallowed: `isWatchDegraded` drives a visible
/// header state and a slow poll takes over, because a silently dead watch is indistinguishable
/// from a file nobody is editing and would leave the panel showing stale content forever.
@MainActor
final class AgentDocumentPreviewViewModel: ObservableObject {
    /// Decision row 15. The text view measures synchronously during SwiftUI layout, so a document
    /// large enough to stall TextKit is refused rather than rendered slowly.
    nonisolated static let maximumDocumentBytes = 2 * 1024 * 1024

    /// FSEvents-side coalescing. Kept short because the view model debounces again on top; the two
    /// together stay inside the design's 150–250 ms window.
    nonisolated static let watchCoalescingWindow = Duration.milliseconds(50)
    nonisolated static let reloadDebounce = Duration.milliseconds(150)
    /// Only ever used after a watch failure. Each tick stats the file and re-reads solely when the
    /// size or modification date moved, so degraded mode does not re-decode megabytes on a timer.
    nonisolated static let degradedPollInterval = Duration.seconds(2)

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "DocumentPreview")

    @Published private(set) var state: AgentPreviewDocumentState = .empty
    /// True while live reload is running on the degraded poll instead of a filesystem watch.
    @Published private(set) var isWatchDegraded = false
    /// Set each time a reload actually replaced the content, for the header's live pip.
    @Published private(set) var lastReloadedAt: Date?
    /// Non-modal, self-clearing feedback for a link that could not be followed.
    @Published var linkFeedback: String?

    private let loader: any AgentPreviewDocumentLoading
    private let watchFactory: AgentPreviewWatchFactory
    private let scheduler: any AgentChangesScheduler
    private let byteLimit: Int
    private let debounce: Duration
    private let pollInterval: Duration
    private let now: @Sendable () -> Date

    private var context = AgentPreviewResolutionContext()
    private var reference: PreviewDocumentReference?
    private var revision = 0
    private var lastAttributes: AgentPreviewFileAttributes?

    private var watchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    init(
        loader: any AgentPreviewDocumentLoading = AgentPreviewLiveDocumentLoader(),
        watchFactory: AgentPreviewWatchFactory = .live,
        scheduler: any AgentChangesScheduler = AgentChangesLiveScheduler(),
        byteLimit: Int = AgentDocumentPreviewViewModel.maximumDocumentBytes,
        debounce: Duration = AgentDocumentPreviewViewModel.reloadDebounce,
        pollInterval: Duration = AgentDocumentPreviewViewModel.degradedPollInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.watchFactory = watchFactory
        self.scheduler = scheduler
        self.byteLimit = byteLimit
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.now = now
    }

    deinit {
        watchTask?.cancel()
        reloadTask?.cancel()
        feedbackTask?.cancel()
    }

    // MARK: - Inputs

    /// Points the surface at a document, or at nothing.
    ///
    /// Idempotent for an unchanged reference and context, because SwiftUI calls this on every
    /// update and re-reading the file on each one would fight the watch.
    func show(_ reference: PreviewDocumentReference?, context: AgentPreviewResolutionContext) {
        let contextChanged = self.context != context
        let referenceChanged = self.reference != reference
        self.context = context
        guard referenceChanged || contextChanged else { return }
        self.reference = reference

        guard let reference else {
            stop()
            state = .empty
            return
        }
        // A context change that does not move this document must not restart the load: bindings
        // and root lists are republished on unrelated workspace activity.
        if !referenceChanged, contextChanged, let current = state.document {
            let reresolved = AgentPreviewDocumentResolver.resolve(reference, in: context)
            if case let .success(document) = reresolved, document == current { return }
        }
        startInitialLoad(reference)
    }

    /// Re-reads the document now, keeping whatever is on screen until the read completes.
    func reloadNow() {
        scheduleReload()
    }

    /// Stops watching and forgets the in-flight work, without changing what is displayed.
    func stop() {
        watchTask?.cancel()
        watchTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        lastAttributes = nil
        isWatchDegraded = false
    }

    /// Shows a short, non-modal message — used when a link cannot be followed.
    ///
    /// Deliberately not an alert: a mistyped wiki link is a normal part of writing notes, and a
    /// modal for one would make the reading surface hostile.
    func reportLinkFeedback(_ message: String) {
        linkFeedback = message
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self, scheduler] in
            try? await scheduler.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.linkFeedback = nil
        }
    }

    // MARK: - Loading

    private func startInitialLoad(_ reference: PreviewDocumentReference) {
        stop()
        revision = 0
        switch AgentPreviewDocumentResolver.resolve(reference, in: context) {
        case let .failure(failure):
            if case .outsideScope = failure {
                Self.logger.warning(
                    "Preview refused a document resolving outside its checkout: \(reference.relativePath, privacy: .public)"
                )
            }
            state = .unresolvable(reference, failure)
        case let .success(document):
            state = .loading(document)
            performLoad(document, isReload: false)
        }
    }

    private func scheduleReload() {
        guard let document = state.document else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self, scheduler, debounce] in
            do {
                try await scheduler.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.performLoad(document, isReload: true)
        }
    }

    private func performLoad(_ document: AgentPreviewResolvedDocument, isReload: Bool) {
        let loader = loader
        let byteLimit = byteLimit
        let fileURL = document.fileURL
        Task { [weak self] in
            // Off the main actor: a 2 MB decode on the main thread would drop frames in the
            // transcript beside the panel.
            let outcome = await Task.detached(priority: .userInitiated) {
                loader.loadOutcome(fileURL, byteLimit: byteLimit)
            }.value
            guard let self, !Task.isCancelled else { return }
            apply(outcome, for: document, isReload: isReload)
        }
    }

    private func apply(
        _ outcome: AgentPreviewLoadOutcome,
        for document: AgentPreviewResolvedDocument,
        isReload: Bool
    ) {
        // A load that finished after the user moved on must not overwrite the new document.
        guard reference == document.reference else { return }

        switch outcome {
        case let .loaded(file):
            lastAttributes = file.attributes
            guard let text = file.text else {
                state = .tooLarge(document, byteCount: file.attributes.byteCount)
                startWatching(document)
                return
            }
            if let existing = state.content, existing.document == document, existing.text == text {
                // Identical bytes: republishing would churn every view keyed on the revision.
                return
            }
            revision += 1
            state = .ready(AgentPreviewDocumentContent(
                document: document,
                text: text,
                revision: revision
            ))
            if isReload { lastReloadedAt = now() }
            startWatching(document)

        case let .failed(error):
            lastAttributes = nil
            switch error {
            case .missing:
                state = .missing(document)
            case let .unreadable(message):
                state = .failed(document, message: message)
            }
            // Keep watching: a document an agent is about to rewrite reappears without the user
            // having to reselect it.
            startWatching(document)
        }
    }

    // MARK: - Watching

    private func startWatching(_ document: AgentPreviewResolvedDocument) {
        guard watchTask == nil else { return }
        let factory = watchFactory
        let fileURL = document.fileURL

        let watch: AgentChangesScopedWatch
        do {
            watch = try factory.makeWatch(fileURL)
        } catch {
            Self.logger.warning(
                "Preview watch unavailable for \(fileURL.path, privacy: .public); polling instead: \(error.localizedDescription, privacy: .public)"
            )
            isWatchDegraded = true
            startDegradedPoll(document)
            return
        }

        isWatchDegraded = false
        watchTask = Task { [weak self] in
            defer { watch.cancel() }
            for await _ in watch.batches {
                guard !Task.isCancelled else { return }
                self?.scheduleReload()
            }
        }
    }

    private func startDegradedPoll(_ document: AgentPreviewResolvedDocument) {
        let loader = loader
        let fileURL = document.fileURL
        watchTask = Task { [weak self, scheduler, pollInterval] in
            while !Task.isCancelled {
                do {
                    try await scheduler.sleep(for: pollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let probed = await Task.detached(priority: .utility) {
                    try? loader.attributes(of: fileURL)
                }.value
                guard let self, !Task.isCancelled else { return }
                guard probed != lastAttributes else { continue }
                lastAttributes = probed
                scheduleReload()
            }
        }
    }
}
