@testable import RepoPromptApp
import XCTest

final class ScopedFileEventStreamTests: XCTestCase {
    /// FSEvents delivery is scheduled by the system, so waits are generous; the tests still finish
    /// as soon as the expectation is met and never sleep for a fixed delivery budget.
    private let deliveryTimeoutSeconds: TimeInterval = 30

    /// How long a change is given to arrive when the contract is that it must *not* arrive.
    private let silenceTimeoutSeconds: TimeInterval = 1

    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testDirectoryScopeDeliversCreateModifyAndDeleteForItsFiles() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ScopedFileEventStreamDirectory")
        let stream = try ScopedFileEventStream(paths: [root], debounce: .milliseconds(100))
        let recorder = ScopedFileChangeRecorder(stream)
        defer { recorder.stop() }

        let document = root.appendingPathComponent("notes.md")

        let created = recorder.expectation(forAll: [document], description: "creation delivered")
        try FileSystemTestSupport.write("first", to: document)
        await fulfillment(of: [created], timeout: deliveryTimeoutSeconds)

        // Each phase starts from a clean observation set so a later wait cannot be satisfied by the
        // batch that proved the previous phase.
        recorder.forgetObservedPaths()
        let modified = recorder.expectation(forAll: [document], description: "modification delivered")
        try FileSystemTestSupport.write("second", to: document)
        await fulfillment(of: [modified], timeout: deliveryTimeoutSeconds)

        recorder.forgetObservedPaths()
        let deleted = recorder.expectation(forAll: [document], description: "deletion delivered")
        try FileManager.default.removeItem(at: document)
        await fulfillment(of: [deleted], timeout: deliveryTimeoutSeconds)
    }

    func testWritesInsideOneDebounceWindowArriveAsFewerBatchesThanWrites() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ScopedFileEventStreamDebounce")
        let stream = try ScopedFileEventStream(paths: [root], debounce: .milliseconds(600))
        let recorder = ScopedFileChangeRecorder(stream)
        defer { recorder.stop() }

        let documents = (0 ..< 12).map { root.appendingPathComponent("burst-\($0).md") }
        let delivered = recorder.expectation(forAll: documents, description: "every burst write delivered")
        for document in documents {
            try FileSystemTestSupport.write("burst", to: document)
        }
        await fulfillment(of: [delivered], timeout: deliveryTimeoutSeconds)

        // The batch count is how many batches it took to see all twelve paths. Twelve writes inside
        // one 600ms window must not read as twelve rebuild requests; the exact number depends on
        // when FSEvents chooses to deliver, so the assertion is a ceiling rather than an equality.
        XCTAssertGreaterThanOrEqual(recorder.batchCount, 1)
        XCTAssertLessThanOrEqual(recorder.batchCount, 3)
    }

    func testContinuousEventsFlushAtMaximumBatchAgeAcrossWindows() throws {
        var accumulator = ScopedFileEventBatchAccumulator(
            debounceSeconds: 0.25,
            maximumBatchAgeSeconds: 0.5
        )
        var batches: [ScopedFileChangeBatch] = []
        var deadline: TimeInterval?

        // Each event arrives 100ms after the previous one, so a pure 250ms trailing debounce would
        // never flush. Crossing each 500ms maximum-age deadline must instead close that window.
        for tick in 0 ..< 15 {
            let time = Double(tick) * 0.1
            if let deadline, deadline <= time {
                try batches.append(XCTUnwrap(accumulator.flush()))
            }
            deadline = accumulator.accept(
                paths: ["/watched/event-\(tick)"],
                mayHaveMissedEvents: false,
                at: time
            )
        }
        try batches.append(XCTUnwrap(accumulator.flush()))

        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].paths, Set((0 ..< 5).map { "/watched/event-\($0)" }))
        XCTAssertEqual(batches[1].paths, Set((5 ..< 10).map { "/watched/event-\($0)" }))
        XCTAssertEqual(batches[2].paths, Set((10 ..< 15).map { "/watched/event-\($0)" }))
    }

    func testCancellationFinishesTheStreamAndStopsDelivery() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ScopedFileEventStreamCancel")
        let stream = try ScopedFileEventStream(paths: [root], debounce: .milliseconds(100))
        let recorder = ScopedFileChangeRecorder(stream)
        defer { recorder.stop() }

        let watched = root.appendingPathComponent("before-cancel.md")
        let delivered = recorder.expectation(forAll: [watched], description: "pre-cancel change delivered")
        try FileSystemTestSupport.write("before", to: watched)
        await fulfillment(of: [delivered], timeout: deliveryTimeoutSeconds)

        stream.cancel()
        await fulfillment(of: [recorder.finished], timeout: deliveryTimeoutSeconds)

        let silence = recorder.expectationForNextBatch(
            description: "no change delivered after cancellation",
            isInverted: true
        )
        try FileSystemTestSupport.write("after", to: root.appendingPathComponent("after-cancel.md"))
        await fulfillment(of: [silence], timeout: silenceTimeoutSeconds)
    }

    func testUnwatchableScopesReportFailureInsteadOfWatchingSomethingElse() throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ScopedFileEventStreamFailure")
        let missing = root.appendingPathComponent("never-created")

        // The parent exists and is perfectly watchable, which is exactly the silent-degradation the
        // caller must not get: an unhydrated worktree has to surface as a failure it can poll past.
        XCTAssertThrowsError(try ScopedFileEventStream(paths: [missing])) { error in
            XCTAssertEqual(error as? ScopedFileEventStreamError, .missingPath(missing.path))
        }
        XCTAssertThrowsError(try ScopedFileEventStream(paths: [])) { error in
            XCTAssertEqual(error as? ScopedFileEventStreamError, .noPathsRequested)
        }
    }

    func testExactFileScopeDeliversItsOwnChangesAndDropsSiblings() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ScopedFileEventStreamExactFile")
        let watched = root.appendingPathComponent("watched.md")
        let sibling = root.appendingPathComponent("sibling.md")
        try FileSystemTestSupport.write("watched", to: watched)
        try FileSystemTestSupport.write("sibling", to: sibling)

        let stream = try ScopedFileEventStream(paths: [watched], debounce: .milliseconds(100))
        let recorder = ScopedFileChangeRecorder(stream)
        defer { recorder.stop() }

        // FSEvents reports on the parent directory, so the sibling's change is delivered to the
        // stream and only the scope filter can keep it out of the batch. Editing the sibling first
        // means an unfiltered path would already be pending when the watched batch flushes.
        try FileSystemTestSupport.write("sibling edit", to: sibling)
        let siblingLeaked = recorder.expectation(forAll: [sibling], description: "sibling change never delivered")
        siblingLeaked.isInverted = true
        let delivered = recorder.expectation(forAll: [watched], description: "watched document delivered")
        try FileSystemTestSupport.write("watched edit", to: watched)
        await fulfillment(of: [delivered], timeout: deliveryTimeoutSeconds)

        // Inverted on the sibling path rather than on "any further batch": the watched document is
        // allowed to arrive in as many batches as FSEvents feels like splitting it into.
        await fulfillment(of: [siblingLeaked], timeout: silenceTimeoutSeconds)
        XCTAssertEqual(recorder.observedPaths, [ScopedFileChangeRecorder.canonicalPath(watched)])
    }
}

/// Consumes a `ScopedFileEventStream` on its own task and lets tests wait on containment rather
/// than on a fixed sleep, so a fast machine finishes immediately and a slow one still passes.
private final class ScopedFileChangeRecorder: @unchecked Sendable {
    /// Fulfilled when the stream finishes, which is the observable half of teardown.
    let finished = XCTestExpectation(description: "scoped file event stream finished")

    private let lock = NSLock()
    private var seenPaths: Set<String> = []
    private var batches = 0
    private var pathWaiters: [(paths: Set<String>, expectation: XCTestExpectation)] = []
    private var nextBatchWaiters: [XCTestExpectation] = []
    private var task: Task<Void, Never>?

    init(_ stream: ScopedFileEventStream) {
        task = Task { [weak self] in
            for await batch in stream.changes {
                self?.record(batch)
            }
            self?.finished.fulfill()
        }
    }

    func stop() {
        task?.cancel()
    }

    var batchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    var observedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return seenPaths
    }

    func forgetObservedPaths() {
        lock.lock()
        seenPaths.removeAll()
        lock.unlock()
    }

    func expectation(forAll urls: [URL], description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        let wanted = Set(urls.map(Self.canonicalPath))
        lock.lock()
        if wanted.isSubset(of: seenPaths) {
            lock.unlock()
            expectation.fulfill()
        } else {
            pathWaiters.append((wanted, expectation))
            lock.unlock()
        }
        return expectation
    }

    func expectationForNextBatch(description: String, isInverted: Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        expectation.isInverted = isInverted
        lock.lock()
        nextBatchWaiters.append(expectation)
        lock.unlock()
        return expectation
    }

    /// Mirrors the stream's own canonicalization: resolve the parent, keep the final component, so
    /// a deleted file still compares equal to the path the batch reported.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(standardized.lastPathComponent)
            .standardizedFileURL
            .path
    }

    private func record(_ batch: ScopedFileChangeBatch) {
        lock.lock()
        batches += 1
        seenPaths.formUnion(batch.paths)
        let satisfied = pathWaiters.filter { $0.paths.isSubset(of: seenPaths) }
        pathWaiters.removeAll { $0.paths.isSubset(of: seenPaths) }
        let batchWaiters = nextBatchWaiters
        nextBatchWaiters.removeAll()
        lock.unlock()

        for waiter in satisfied {
            waiter.expectation.fulfill()
        }
        for waiter in batchWaiters {
            waiter.fulfill()
        }
    }
}
