import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

/// Resolution, loading, and live-reload behaviour of the Preview segment's controller.
///
/// Containment is exercised against a real temporary directory, because the property under test —
/// decision row 15's "reject resolved symlinks escaping the checkout" — is only meaningful against
/// links a filesystem actually resolves. Everything else runs on fakes with an injected scheduler,
/// so no test waits on a real debounce or a real poll interval.
@MainActor
final class AgentDocumentPreviewViewModelTests: XCTestCase {
    private var temporaryDirectory: URL?
    private var scheduler: PreviewTestScheduler?

    override func tearDownWithError() throws {
        scheduler?.cancelAll()
        scheduler = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Resolution

    func testAReferenceResolvesAgainstItsLogicalRoot() {
        let rootID = UUID()
        let context = makeContext(rootID: rootID, rootPath: "/repos/alpha")
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "docs/design.md")

        let document = resolved(reference, in: context)

        XCTAssertEqual(document?.fileURL.path, "/repos/alpha/docs/design.md")
        XCTAssertEqual(document?.checkoutRootURL.path, "/repos/alpha")
        XCTAssertEqual(document?.kind, .markdown)
        XCTAssertEqual(document?.rootName, "alpha")
    }

    func testABoundWorktreeRedirectsResolutionAwayFromTheWorkspaceCheckout() {
        let rootID = UUID()
        var context = makeContext(rootID: rootID, rootPath: "/repos/alpha")
        context.worktreeBindings = [makeBinding(
            logicalRootPath: "/repos/alpha",
            worktreeRootPath: "/worktrees/alpha-feature"
        )]
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "impl-report.md")

        let document = resolved(reference, in: context)

        XCTAssertEqual(
            document?.fileURL.path,
            "/worktrees/alpha-feature/impl-report.md",
            "a session bound to a worktree must read the agent's checkout, not the user's"
        )
        XCTAssertEqual(document?.checkoutRootURL.path, "/worktrees/alpha-feature")
    }

    func testABindingForADifferentRootDoesNotRedirectThisOne() {
        let rootID = UUID()
        var context = makeContext(rootID: rootID, rootPath: "/repos/alpha")
        context.worktreeBindings = [makeBinding(
            logicalRootPath: "/repos/beta",
            worktreeRootPath: "/worktrees/beta-feature"
        )]
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "notes.md")

        XCTAssertEqual(resolved(reference, in: context)?.fileURL.path, "/repos/alpha/notes.md")
    }

    func testATraversalPathIsRejectedRatherThanRead() {
        let rootID = UUID()
        let context = makeContext(rootID: rootID, rootPath: "/repos/alpha")
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "../beta/secrets.md")

        XCTAssertEqual(failure(of: reference, in: context), .outsideScope)
    }

    func testContainmentIsStrictAboutTheRootAndAboutSiblingsSharingItsPrefix() {
        let root = URL(fileURLWithPath: "/repos/alpha")

        XCTAssertTrue(AgentPreviewDocumentResolver.isContained(
            URL(fileURLWithPath: "/repos/alpha/docs/design.md"),
            in: root
        ))
        XCTAssertFalse(
            AgentPreviewDocumentResolver.isContained(root, in: root),
            "the checkout directory is not a document"
        )
        XCTAssertFalse(
            AgentPreviewDocumentResolver.isContained(
                URL(fileURLWithPath: "/repos/alpha-secrets/plan.md"),
                in: root
            ),
            "a sibling whose name merely starts with the root's must not read as contained"
        )
    }

    func testAReferenceIntoARootTheWorkspaceNoLongerHasIsRefused() {
        let context = makeContext(rootID: UUID(), rootPath: "/repos/alpha")
        let reference = PreviewDocumentReference(rootID: UUID(), relativePath: "docs/design.md")

        XCTAssertEqual(failure(of: reference, in: context), .unknownRoot)
    }

    func testOnlyMarkdownAndHTMLResolve() {
        let rootID = UUID()
        let context = makeContext(rootID: rootID, rootPath: "/repos/alpha")

        for path in ["notes.md", "notes.markdown", "report.html", "report.htm"] {
            let reference = PreviewDocumentReference(rootID: rootID, relativePath: path)
            XCTAssertNotNil(resolved(reference, in: context), "\(path) should resolve")
        }

        let unsupported = PreviewDocumentReference(rootID: rootID, relativePath: "main.swift")
        XCTAssertEqual(failure(of: unsupported, in: context), .unsupportedKind("swift"))

        let empty = PreviewDocumentReference(rootID: rootID, relativePath: "")
        XCTAssertEqual(failure(of: empty, in: context), .emptyPath)
    }

    func testASymlinkPointingOutOfTheCheckoutIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let outside = root.appendingPathComponent("outside")
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("planted.md"),
            withDestinationURL: outside.appendingPathComponent("secret.md")
        )

        let rootID = UUID()
        let context = makeContext(rootID: rootID, rootPath: checkout.path)
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "planted.md")

        XCTAssertEqual(
            failure(of: reference, in: context),
            .outsideScope,
            "an agent can plant a symlink beside its report; the containment check must resolve it"
        )
    }

    func testASymlinkStayingInsideTheCheckoutIsAllowed() throws {
        let root = try makeTemporaryDirectory()
        let checkout = root.appendingPathComponent("checkout")
        let documents = checkout.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let real = documents.appendingPathComponent("real.md")
        try "# Real".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("alias.md"),
            withDestinationURL: real
        )

        let rootID = UUID()
        let context = makeContext(rootID: rootID, rootPath: checkout.path)
        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "alias.md")

        let document = resolved(reference, in: context)
        XCTAssertEqual(document?.fileURL.resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path)
    }

    // MARK: - Loading

    func testOpeningADocumentGoesFromLoadingToReady() async throws {
        let loader = FakePreviewLoader(text: "# Title")
        let harness = makeHarness(loader: loader)

        harness.viewModel.show(harness.reference, context: harness.context)
        XCTAssertTrue(harness.viewModel.state.isLoading, "the first read of a document shows progress")

        try await waitForReady(harness.viewModel)
        XCTAssertEqual(harness.viewModel.state.content?.text, "# Title")
        XCTAssertEqual(harness.viewModel.state.content?.revision, 1)
        XCTAssertFalse(harness.viewModel.isWatchDegraded)
    }

    func testADocumentPastTheByteLimitIsRefusedInsteadOfRendered() async throws {
        let loader = FakePreviewLoader(text: String(repeating: "x", count: 64), byteCount: 4_000_000)
        let harness = makeHarness(loader: loader, byteLimit: 2 * 1024 * 1024)

        harness.viewModel.show(harness.reference, context: harness.context)

        try await AsyncTestWait.waitUntil("too-large state") {
            await MainActor.run {
                if case .tooLarge = harness.viewModel.state { return true }
                return false
            }
        }
        guard case let .tooLarge(_, byteCount) = harness.viewModel.state else {
            return XCTFail("expected the oversized state")
        }
        XCTAssertEqual(byteCount, 4_000_000)
    }

    func testAMissingFileReportsMissingRatherThanAnError() async throws {
        let loader = FakePreviewLoader(text: "ignored")
        loader.fail(with: .missing)
        let harness = makeHarness(loader: loader)

        harness.viewModel.show(harness.reference, context: harness.context)

        try await AsyncTestWait.waitUntil("missing state") {
            await MainActor.run {
                if case .missing = harness.viewModel.state { return true }
                return false
            }
        }
    }

    func testAnUnreadableFileSurfacesItsReason() async throws {
        let loader = FakePreviewLoader(text: "ignored")
        loader.fail(with: .unreadable("permission denied"))
        let harness = makeHarness(loader: loader)

        harness.viewModel.show(harness.reference, context: harness.context)

        try await AsyncTestWait.waitUntil("failed state") {
            await MainActor.run {
                if case .failed = harness.viewModel.state { return true }
                return false
            }
        }
        guard case let .failed(_, message) = harness.viewModel.state else {
            return XCTFail("expected the failure state")
        }
        XCTAssertEqual(message, "permission denied")
    }

    func testARefusedReferenceNeverReachesTheLoader() {
        let loader = FakePreviewLoader(text: "# Title")
        let harness = makeHarness(loader: loader)
        let escaping = PreviewDocumentReference(
            rootID: harness.reference.rootID,
            relativePath: "../elsewhere/secrets.md"
        )

        harness.viewModel.show(escaping, context: harness.context)

        guard case let .unresolvable(_, failure) = harness.viewModel.state else {
            return XCTFail("expected the unresolvable state")
        }
        XCTAssertEqual(failure, .outsideScope)
        XCTAssertEqual(loader.loadCount, 0, "a refused path must not be read at all")
    }

    func testClearingTheSelectionReturnsToTheEmptyState() async throws {
        let harness = makeHarness(loader: FakePreviewLoader(text: "# Title"))
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        harness.viewModel.show(nil, context: harness.context)

        XCTAssertEqual(harness.viewModel.state, .empty)
    }

    func testRepeatingTheSameReferenceDoesNotReReadTheFile() async throws {
        let loader = FakePreviewLoader(text: "# Title")
        let harness = makeHarness(loader: loader)
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        // SwiftUI republishes on every update; the panel must not turn that into disk traffic.
        harness.viewModel.show(harness.reference, context: harness.context)
        harness.viewModel.show(harness.reference, context: harness.context)

        XCTAssertEqual(loader.loadCount, 1)
    }

    // MARK: - Reload

    func testAReloadNeverPassesBackThroughLoading() async throws {
        let loader = FakePreviewLoader(text: "# First")
        let harness = makeHarness(loader: loader)
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        // Anything that unmounts the document view resets a reader's scroll position, which is
        // exactly what decision row 15 forbids on a live reload. Every published state is recorded
        // so the assertion covers the whole reload, not the moments the test happened to sample.
        let recorder = StateRecorder()
        let observation = harness.viewModel.$state.sink { state in
            recorder.record(isLoading: state.isLoading)
        }
        defer { observation.cancel() }

        loader.set(text: "# Second")
        harness.viewModel.reloadNow()

        try await fireUntil(harness) { $0.state.content?.text == "# Second" }

        XCTAssertFalse(
            recorder.sawLoading,
            "a reload must swap the text in place, never restart the surface"
        )
        XCTAssertEqual(harness.viewModel.state.content?.revision, 2)
        XCTAssertNotNil(harness.viewModel.lastReloadedAt)
    }

    func testAReloadThatFindsIdenticalBytesDoesNotBumpTheRevision() async throws {
        let loader = FakePreviewLoader(text: "# Same")
        let harness = makeHarness(loader: loader)
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        harness.viewModel.reloadNow()
        try await AsyncTestWait.waitUntil("second read completed") {
            harness.scheduler.fireAll()
            return loader.loadCount == 2
        }

        XCTAssertEqual(
            harness.viewModel.state.content?.revision,
            1,
            "the revision drives HTML reloads and view invalidation; unchanged bytes must not move it"
        )
        XCTAssertNil(harness.viewModel.lastReloadedAt)
    }

    func testABurstOfFileEventsCollapsesIntoOneReload() async throws {
        let loader = FakePreviewLoader(text: "# First")
        let watch = FakeScopedWatch()
        let harness = makeHarness(loader: loader, watch: watch)
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)
        loader.set(text: "# Second")

        watch.emit()
        watch.emit()
        watch.emit()

        // Each event re-arms the debounce and supersedes the previous one; waiting for all three
        // to have been requested is what makes the collapse observable rather than timing-dependent.
        try await AsyncTestWait.waitUntil("three debounce windows requested") {
            harness.scheduler.requestedCount(of: harness.debounce) == 3
        }

        try await fireUntil(harness) { $0.state.content?.text == "# Second" }
        XCTAssertEqual(loader.loadCount, 2, "an agent rewriting a file repeatedly costs one re-read")
    }

    // MARK: - Watch degradation

    func testAWatchThatCannotBeCreatedDegradesToPolling() async throws {
        let loader = FakePreviewLoader(text: "# First")
        let harness = makeHarness(
            loader: loader,
            watchFactory: AgentPreviewWatchFactory { url in
                throw ScopedFileEventStreamError.missingPath(url.path)
            }
        )

        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        XCTAssertTrue(
            harness.viewModel.isWatchDegraded,
            "a dead watch is indistinguishable from a quiet file, so it has to be visible"
        )

        // The poll gates on cheap attributes: an unchanged file costs a stat, not a re-read.
        try await AsyncTestWait.waitUntil("first poll armed") {
            harness.scheduler.requestedCount(of: harness.pollInterval) >= 1
        }
        harness.scheduler.fire(matching: harness.pollInterval)
        try await AsyncTestWait.waitUntil("attributes probed") { loader.attributeProbeCount >= 1 }
        XCTAssertEqual(loader.loadCount, 1, "an unchanged file must not be re-decoded on every tick")

        loader.set(text: "# Second", modifiedAt: Date(timeIntervalSince1970: 5000))
        try await fireUntil(harness) { $0.state.content?.text == "# Second" }
    }

    func testAHealthyWatchIsNotReportedAsDegraded() async throws {
        let harness = makeHarness(loader: FakePreviewLoader(text: "# First"), watch: FakeScopedWatch())

        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        XCTAssertFalse(harness.viewModel.isWatchDegraded)
        XCTAssertEqual(harness.scheduler.requestedCount(of: harness.pollInterval), 0)
    }

    func testStoppingTearsTheWatchDownWithoutChangingWhatIsShown() async throws {
        let watch = FakeScopedWatch()
        let harness = makeHarness(loader: FakePreviewLoader(text: "# First"), watch: watch)
        harness.viewModel.show(harness.reference, context: harness.context)
        try await waitForReady(harness.viewModel)

        harness.viewModel.stop()

        try await AsyncTestWait.waitUntil("watch cancelled") { watch.cancelCount >= 1 }
        XCTAssertEqual(harness.viewModel.state.content?.text, "# First")
    }

    // MARK: - Helpers

    private struct Harness {
        let viewModel: AgentDocumentPreviewViewModel
        let scheduler: PreviewTestScheduler
        let context: AgentPreviewResolutionContext
        let reference: PreviewDocumentReference
        let debounce: Duration
        let pollInterval: Duration
    }

    private func makeHarness(
        loader: FakePreviewLoader,
        watch: FakeScopedWatch? = nil,
        watchFactory: AgentPreviewWatchFactory? = nil,
        byteLimit: Int = 1024 * 1024
    ) -> Harness {
        let debounce = Duration.milliseconds(150)
        let pollInterval = Duration.seconds(2)
        let scheduler = PreviewTestScheduler()
        self.scheduler = scheduler

        let resolvedWatch = watch ?? FakeScopedWatch()
        let factory = watchFactory ?? AgentPreviewWatchFactory { _ in resolvedWatch.watch }

        let rootID = UUID()
        return Harness(
            viewModel: AgentDocumentPreviewViewModel(
                loader: loader,
                watchFactory: factory,
                scheduler: scheduler,
                byteLimit: byteLimit,
                debounce: debounce,
                pollInterval: pollInterval,
                now: { Date(timeIntervalSince1970: 1000) }
            ),
            scheduler: scheduler,
            context: makeContext(rootID: rootID, rootPath: "/repos/alpha"),
            reference: PreviewDocumentReference(rootID: rootID, relativePath: "docs/design.md"),
            debounce: debounce,
            pollInterval: pollInterval
        )
    }

    private func waitForReady(_ viewModel: AgentDocumentPreviewViewModel) async throws {
        try await AsyncTestWait.waitUntil("ready state") {
            await MainActor.run { viewModel.state.content != nil }
        }
    }

    /// Releases parked sleeps until the view model satisfies `condition`.
    ///
    /// Firing inside the wait keeps a chain of sleeps — a poll tick that arms a debounce window —
    /// from deadlocking on a single release, without ever shortening a real interval.
    private func fireUntil(
        _ harness: Harness,
        _ condition: @escaping @MainActor (AgentDocumentPreviewViewModel) -> Bool
    ) async throws {
        let viewModel = harness.viewModel
        let scheduler = harness.scheduler
        try await AsyncTestWait.waitUntil("view model reached the expected state") {
            scheduler.fireAll()
            return await MainActor.run { condition(viewModel) }
        }
    }

    private func makeContext(rootID: UUID, rootPath: String) -> AgentPreviewResolutionContext {
        AgentPreviewResolutionContext(
            roots: [AgentPreviewDocumentRoot(
                id: rootID,
                name: (rootPath as NSString).lastPathComponent,
                path: rootPath
            )]
        )
    }

    private func makeBinding(
        logicalRootPath: String,
        worktreeRootPath: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: "repo",
            repoKey: "repo-key",
            logicalRootPath: logicalRootPath,
            worktreeID: "worktree",
            worktreeRootPath: worktreeRootPath,
            source: "test"
        )
    }

    private func resolved(
        _ reference: PreviewDocumentReference,
        in context: AgentPreviewResolutionContext
    ) -> AgentPreviewResolvedDocument? {
        try? AgentPreviewDocumentResolver.resolve(reference, in: context).get()
    }

    private func failure(
        of reference: PreviewDocumentReference,
        in context: AgentPreviewResolutionContext
    ) -> AgentPreviewResolutionFailure? {
        switch AgentPreviewDocumentResolver.resolve(reference, in: context) {
        case .success: nil
        case let .failure(failure): failure
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentDocumentPreviewViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Resolved up front so the root the test hands the resolver is already canonical, the way
        // a workspace root is: /var is a symlink to /private/var on macOS.
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        temporaryDirectory = resolved
        return resolved
    }
}

// MARK: - Fakes

/// A loader whose answers the test sets directly, with counters for the traffic it saw.
private final class FakePreviewLoader: AgentPreviewDocumentLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String
    private var explicitByteCount: Int?
    private var modifiedAt: Date?
    private var error: AgentPreviewLoadError?
    private var loads = 0
    private var probes = 0

    init(text: String, byteCount: Int? = nil, modifiedAt: Date? = Date(timeIntervalSince1970: 100)) {
        self.text = text
        explicitByteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var attributeProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    func set(text: String, modifiedAt: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.text = text
        error = nil
        if let modifiedAt { self.modifiedAt = modifiedAt }
    }

    func fail(with error: AgentPreviewLoadError) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    func attributes(of url: URL) throws -> AgentPreviewFileAttributes {
        lock.lock()
        probes += 1
        let error = error
        let attributes = currentAttributesLocked()
        lock.unlock()
        if let error { throw error }
        return attributes
    }

    func load(_ url: URL, byteLimit: Int) throws -> AgentPreviewLoadedFile {
        lock.lock()
        loads += 1
        let error = error
        let text = text
        let attributes = currentAttributesLocked()
        lock.unlock()
        if let error { throw error }
        guard attributes.byteCount <= byteLimit else {
            return AgentPreviewLoadedFile(text: nil, attributes: attributes)
        }
        return AgentPreviewLoadedFile(text: text, attributes: attributes)
    }

    private func currentAttributesLocked() -> AgentPreviewFileAttributes {
        AgentPreviewFileAttributes(
            byteCount: explicitByteCount ?? text.utf8.count,
            modifiedAt: modifiedAt
        )
    }
}

/// A scoped watch the test drives by hand.
private final class FakeScopedWatch: @unchecked Sendable {
    let watch: AgentChangesScopedWatch

    private let continuation: AsyncStream<ScopedFileChangeBatch>.Continuation
    private let cancels = TestCounter()

    init() {
        let (stream, continuation) = AsyncStream<ScopedFileChangeBatch>.makeStream()
        self.continuation = continuation
        let cancels = cancels
        watch = AgentChangesScopedWatch(batches: stream, cancel: { cancels.increment() })
    }

    var cancelCount: Int {
        cancels.value
    }

    func emit(paths: Set<String> = ["/repos/alpha/docs/design.md"]) {
        continuation.yield(ScopedFileChangeBatch(paths: paths, mayHaveMissedEvents: false))
    }
}

/// Records whether the surface ever went back to a loading state.
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loadingSeen = false

    var sawLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadingSeen
    }

    func record(isLoading: Bool) {
        guard isLoading else { return }
        lock.lock()
        loadingSeen = true
        lock.unlock()
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// A scheduler that parks every sleep until the test releases it.
///
/// Parking rather than shortening is what makes the debounce observable: a burst of events can be
/// delivered in full, and only then released, so "these three events produced one reload" is a
/// statement about the collapse rather than about how fast the machine ran. Cancellation resumes a
/// parked sleep with `CancellationError`, matching a real clock, so a superseded debounce window
/// unwinds exactly as it does in production.
private final class PreviewTestScheduler: AgentChangesScheduler, @unchecked Sendable {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var requested: [Duration] = []

    func requestedCount(of duration: Duration) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requested.count(where: { $0 == duration })
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        lock.lock()
        requested.append(duration)
        lock.unlock()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledBeforeRegistration.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(duration: duration, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            resume(id, with: CancellationError())
        }
    }

    /// Releases every parked sleep of exactly this duration.
    func fire(matching duration: Duration) {
        release { $0.duration == duration }
    }

    func fireAll() {
        release { _ in true }
    }

    func cancelAll() {
        lock.lock()
        let all = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in all.values {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func release(_ predicate: (Waiter) -> Bool) {
        lock.lock()
        let matching = waiters.filter { predicate($0.value) }
        for key in matching.keys {
            waiters.removeValue(forKey: key)
        }
        lock.unlock()
        for waiter in matching.values {
            waiter.continuation.resume()
        }
    }

    private func resume(_ id: UUID, with error: Error) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: id) else {
            // Cancellation can outrun registration; remember it so the sleep fails closed.
            cancelledBeforeRegistration.insert(id)
            lock.unlock()
            return
        }
        lock.unlock()
        waiter.continuation.resume(throwing: error)
    }
}
