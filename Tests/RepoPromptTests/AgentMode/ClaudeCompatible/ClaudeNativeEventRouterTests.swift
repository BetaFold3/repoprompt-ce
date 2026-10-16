import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Ownership, approval, and drain rules of the long-lived Claude native event router. Every event
/// belongs to the run that was current when the controller emitted it; a run becomes current at
/// its in-band start marker. Output owned by no live run is between-run output.
@MainActor
final class ClaudeNativeEventRouterTests: XCTestCase {
    // MARK: - Ownership

    func testOutputOwnedByFinishedRunIsDeliveredIdleEvenWhileNewerRunConsumes() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        // Emitted while run A is still finalizing: held for A, not delivered idle yet.
        fixture.yield(.stream(AIStreamResult(type: "content", text: "old")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        // Run B starts and consumes while A is still alive. "old" is not B's output.
        fixture.startRun(Self.runB)
        let consumer = fixture.consume(Self.runB, finishOn: "done")
        await fixture.waitUntilConsuming()
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [], "Output owned by a live older run must wait for that run.")

        // A's task ends without consuming again: "old" is between-run output, not B's.
        fixture.endRun(Self.runA)
        fixture.yield(.stream(AIStreamResult(type: "content", text: "new")))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "done")))
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["idle:old", "run:new", "run:done"])
    }

    func testOutputEmittedBeforeRunMarkerIsNotTheRunsEvenWhenReadAfterTheRunStarted() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        // The controller emitted "old" before B's marker, but the reader has not read it yet when
        // B registers: ownership follows stream order, not read time.
        fixture.yield(.stream(AIStreamResult(type: "content", text: "old")))
        fixture.startRun(Self.runB)
        fixture.yield(.stream(AIStreamResult(type: "content", text: "new")))
        let consumer = fixture.consume(Self.runB, finishOn: "new")
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["idle:old", "run:new"])
    }

    func testRunWithoutMarkerOwnsOutputFromWhenItsStartResolves() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.stream(AIStreamResult(type: "content", text: "old")))
        fixture.registerRun(Self.runB)
        try? await waitUntil { fixture.log == ["idle:old"] }

        fixture.router.resolveRunStart(attemptID: Self.runB)
        fixture.yield(.stream(AIStreamResult(type: "content", text: "new")))
        let consumer = fixture.consume(Self.runB, finishOn: "new")
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["idle:old", "run:new"])
    }

    func testOutputBufferedBeforeFirstRunMarkerOnFreshRouterIsBetweenRunOutput() async {
        let fixture = makeFixture(initialOwner: nil, aliveAttempts: [Self.runB])
        fixture.registerRun(Self.runB)

        fixture.yield(.stream(AIStreamResult(type: "content", text: "buffered")))
        fixture.yield(.marker(Self.runB))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "mine")))
        let consumer = fixture.consume(Self.runB, finishOn: "mine")
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["idle:buffered", "run:mine"])
    }

    func testOutputArrivingBeforeLiveRunConsumesWaitsForThatRun() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        fixture.yield(.stream(AIStreamResult(type: "content", text: "early")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        let consumer = fixture.consume(Self.runA, finishOn: "done")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "done")))
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["run:early", "run:done"])
    }

    func testBetweenRunOutputIsDeliveredIdleWithoutAnyConsumer() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.stream(AIStreamResult(type: "content", text: "background")))
        try await waitUntil { fixture.log == ["idle:background"] }
    }

    func testDetachedEventIsRoutedAgainByOwnership() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        let consumer = fixture.consume(Self.runA, finishOn: "never", detachOn: "x")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "x")))
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["detached:x"])

        fixture.endRun(Self.runA)
        try await waitUntil { fixture.log == ["detached:x", "idle:x"] }
    }

    func testEndedStreamStillHoldsLiveRunsEventsForItsConsumer() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        // The process exits after B's message was sent: B's failure is the stream's last event.
        fixture.startRun(Self.runB)
        fixture.yield(.error("exited"))
        fixture.finishStream()
        await bounded { await fixture.router.waitUntilStreamEnded() }
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertTrue(fixture.router.hasStreamEnded)
        XCTAssertFalse(fixture.router.isFinished)
        XCTAssertTrue(fixture.router.holdsUndeliveredEvents(ownedBy: Self.runB))
        XCTAssertFalse(fixture.router.holdsUndeliveredEvents(ownedBy: Self.runA))

        let consumer = fixture.consume(Self.runB, finishOn: "error:exited")
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["run:error:exited"])
    }

    // MARK: - Approvals

    func testApprovalCancelledBeforeAnyRunSawItIsDroppedAndReleasesLaterOutput() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.approvalRequest(Self.approval(id: "r1")))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "after")))
        await fixture.waitUntilProcessorWaits(undelivered: 2)
        XCTAssertEqual(fixture.log, [], "An approval is never handled idle; later output keeps stream order.")

        fixture.yield(.approvalCancelled(requestID: "r1"))
        try await waitUntil { fixture.log == ["idle:after"] }
    }

    func testUnseenApprovalCancelledWhileAnotherRunConsumesIsDropped() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        // A completes, then an approval request and its cancellation arrive in one burst.
        let first = fixture.consume(Self.runA, finishOn: "done")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "done")))
        fixture.yield(.approvalRequest(Self.approval(id: "r4")))
        fixture.yield(.approvalCancelled(requestID: "r4"))
        _ = await resolved(first)
        fixture.endRun(Self.runA)

        fixture.startRun(Self.runB)
        let second = fixture.consume(Self.runB, finishOn: "b-done")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "b-done")))
        _ = await resolved(second)
        XCTAssertEqual(fixture.log, ["run:done", "run:b-done"], "A cancelled, unseen approval reaches no run.")
    }

    func testHeldApprovalIsHandedToNextConsumingRun() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.approvalRequest(Self.approval(id: "r2")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        fixture.startRun(Self.runB)
        let consumer = fixture.consume(Self.runB, finishOn: "done")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "done")))
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["run:approval:r2", "run:done"])
    }

    func testCancellationFollowsRunThatReceivedTheRequest() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        // B consumes before its marker is read, so the request (owned by dead A) is handed to B.
        fixture.registerRun(Self.runB)
        let consumer = fixture.consume(Self.runB, finishOn: "done")
        fixture.yield(.approvalRequest(Self.approval(id: "r5")))
        try? await waitUntil { fixture.log == ["run:approval:r5"] }

        // Its cancellation also predates B's marker, yet must reach B, which shows the request.
        fixture.yield(.approvalCancelled(requestID: "r5"))
        fixture.yield(.marker(Self.runB))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "done")))
        _ = await resolved(consumer)
        XCTAssertEqual(fixture.log, ["run:approval:r5", "run:approvalCancelled:r5", "run:done"])
    }

    func testApprovalHeldAtStreamEndIsNotHandedToARunAndRouterFinishes() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.approvalRequest(Self.approval(id: "r3")))
        fixture.finishStream()
        try await waitUntil { fixture.router.isFinished }
        XCTAssertEqual(fixture.log, ["idle:approval:r3"])
        XCTAssertTrue(fixture.finishedNotified)

        let resolution = await bounded { await fixture.router.consumeRun(attemptID: Self.runB) { _ in .continue } }
        XCTAssertEqual(resolution, .streamEnded)
    }

    // MARK: - Drain before a follow-up

    func testDrainReleasesFinishingRunAndDeliversOutputItStillOwned() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        fixture.yield(.stream(AIStreamResult(type: "content", text: "late")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        await bounded { await fixture.router.drain(releasing: Self.runA, throughMarker: nil) }
        XCTAssertEqual(fixture.log, ["idle:late"], "Output read before the drain is delivered before it returns.")
    }

    func testDrainThroughMarkerDeliversOutputEmittedBeforeTheMarker() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])
        let markerID = UUID()

        // Not yet read when the drain starts.
        fixture.yield(.stream(AIStreamResult(type: "content", text: "late")))
        fixture.yield(.marker(markerID))
        await bounded { await fixture.router.drain(releasing: Self.runA, throughMarker: markerID) }
        XCTAssertEqual(fixture.log, ["idle:late"])
    }

    func testDrainDoesNotResolveEarlyWhenHeadWasUnblockedBeforeProcessorReevaluated() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])
        let markerID = UUID()

        // "late" waits for live run A; the drain waits for a marker not read yet.
        fixture.yield(.stream(AIStreamResult(type: "content", text: "late")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        let drain = Task { @MainActor in
            await fixture.router.drain(releasing: nil, throughMarker: markerID)
            fixture.note("drained")
        }
        try? await waitUntil { fixture.router.test_pendingDrainCount == 1 }
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        // The marker is read before the processor re-evaluates the head that the release just
        // unblocked (the reader's wake is queued first). "late" can now progress, so the drain
        // must wait for its delivery instead of treating the head as stalled.
        let gate = IdleGate()
        fixture.idleGate = { await gate.wait() }
        fixture.yield(.marker(markerID))
        fixture.router.release(attemptID: Self.runA)
        try? await waitUntil { fixture.router.test_undeliveredEventCount == 0 && gate.isWaiting }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.log, [], "The drain must not return while \"late\" is being delivered.")

        gate.open()
        await bounded { await drain.value }
        XCTAssertEqual(fixture.log, ["idle:late", "drained"])
    }

    func testDrainDoesNotWaitForApprovalHeldForNextRun() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        fixture.yield(.approvalRequest(Self.approval(id: "r6")))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "behind")))
        await fixture.waitUntilProcessorWaits(undelivered: 2)
        await bounded { await fixture.router.drain(releasing: nil, throughMarker: nil) }
        XCTAssertEqual(fixture.log, [], "Held approval keeps stream order; the drain returns instead of hanging.")
    }

    func testLiveRunsMarkerStartsItEvenWhenReadBeforeItRegisteredOnThisRouter() async {
        let fixture = makeFixture(initialOwner: nil, aliveAttempts: [Self.runA])

        // A's start is pending here; B's run task is alive, but B registered on no router yet.
        fixture.registerRun(Self.runA)
        fixture.yield(.marker(Self.runA))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "a-out")))
        fixture.markAlive(Self.runB)
        fixture.yield(.marker(Self.runB))
        fixture.yield(.stream(AIStreamResult(type: "content", text: "b-out")))
        await fixture.waitUntilProcessorWaits(undelivered: 2)
        XCTAssertTrue(fixture.router.holdsUndeliveredEvents(ownedBy: Self.runB))

        // A ends without consuming; B's output stays B's.
        fixture.endRun(Self.runA)
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        let consumer = fixture.consume(Self.runB, finishOn: "b-out")
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .finished)
        XCTAssertEqual(fixture.log, ["idle:a-out", "run:b-out"])
    }

    // MARK: - Release and stream end

    func testOutputOwnedByNewerRunThatEndedIsNotHandedToOlderConsumer() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        let consumer = fixture.consume(Self.runA, finishOn: "never")
        await fixture.waitUntilConsuming()
        fixture.startRun(Self.runB)
        fixture.yield(.stream(AIStreamResult(type: "content", text: "b-out")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [], "Output of a newer live run waits for it.")

        // B ends without consuming: its output is between-run output, never A's.
        fixture.endRun(Self.runB)
        try await waitUntil { fixture.log == ["idle:b-out"] }
        consumer.cancel()
        _ = await resolved(consumer)
    }

    func testReleasedRunsOutputIsDeliveredWhileItsTaskIsStillAlive() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        fixture.yield(.stream(AIStreamResult(type: "content", text: "late")))
        await fixture.waitUntilProcessorWaits(undelivered: 1)
        XCTAssertEqual(fixture.log, [])

        fixture.router.release(attemptID: Self.runA)
        try await waitUntil { fixture.log == ["idle:late"] }
    }

    func testWaitUntilStreamEndedTakesInEventsStillBufferedInFinishedStream() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [])

        // Emitted and finished before the reader ran: the inbox does not show them yet.
        fixture.startRun(Self.runB)
        fixture.yield(.error("exited"))
        fixture.finishStream()
        XCTAssertFalse(fixture.router.holdsUndeliveredEvents(ownedBy: Self.runB))

        await bounded { await fixture.router.waitUntilStreamEnded() }
        XCTAssertTrue(fixture.router.hasStreamEnded)
        XCTAssertTrue(fixture.router.holdsUndeliveredEvents(ownedBy: Self.runB))
    }

    // MARK: - Lifecycle

    func testCancellingConsumerDetachesRunButKeepsReadingStream() async throws {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        let consumer = fixture.consume(Self.runA, finishOn: "never")
        await fixture.waitUntilConsuming()
        consumer.cancel()
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .cancelled)

        fixture.endRun(Self.runA)
        fixture.yield(.stream(AIStreamResult(type: "content", text: "later")))
        try await waitUntil { fixture.log == ["idle:later"] }
        XCTAssertFalse(fixture.router.hasStreamEnded)
        XCTAssertFalse(fixture.router.isFinished)
    }

    func testStreamEndResolvesConsumingRun() async {
        let fixture = makeFixture(initialOwner: Self.runA, aliveAttempts: [Self.runA])

        let consumer = fixture.consume(Self.runA, finishOn: "never")
        fixture.yield(.stream(AIStreamResult(type: "content", text: "partial")))
        fixture.finishStream()
        let resolution = await resolved(consumer)
        XCTAssertEqual(resolution, .streamEnded)
        XCTAssertEqual(fixture.log, ["run:partial"])
    }

    // MARK: - Helpers

    private static let runA = UUID()
    private static let runB = UUID()

    private static func approval(id: String) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .claudeControl(id),
            method: "can_use_tool",
            kind: .commandExecution,
            threadID: "thread",
            turnID: id,
            itemID: id
        )
    }

    /// Creates a fixture whose runs end and stream finishes at teardown, and checks that the
    /// router then finishes (no stranded processor or continuation).
    private func makeFixture(initialOwner: UUID?, aliveAttempts: Set<UUID>) -> RouterFixture {
        let fixture = RouterFixture(initialOwner: initialOwner, aliveAttempts: aliveAttempts)
        addTeardownBlock { @MainActor in
            fixture.shutdown()
            let deadline = ContinuousClock.now + .seconds(2)
            while !fixture.router.isFinished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(fixture.router.isFinished, "The router must finish once its runs ended and its stream finished.")
        }
        return fixture
    }

    /// Awaits `operation`, failing instead of hanging the suite when it does not finish in time.
    @discardableResult
    private func bounded<T: Sendable>(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @MainActor () async -> T
    ) async -> T? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await operation()
                if once.claim() {
                    continuation.resume(returning: value)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if once.claim() {
                    XCTFail("Timed out awaiting operation", file: file, line: line)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func resolved(
        _ consumer: Task<ClaudeNativeEventRouter.RunResolution, Never>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ClaudeNativeEventRouter.RunResolution? {
        await bounded(file: file, line: line) { await consumer.value }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class IdleGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var isWaiting: Bool {
        !waiters.isEmpty
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@MainActor
private final class ResumeOnce {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

@MainActor
private final class RouterFixture {
    let router: ClaudeNativeEventRouter
    private let controller = NSObject()
    private let continuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation
    private var aliveAttempts: Set<UUID>
    private(set) var log: [String] = []
    private(set) var finishedNotified = false
    /// Awaited by the idle handler before it records an event.
    var idleGate: (@MainActor () async -> Void)?
    private var consumingCount = 0

    init(initialOwner: UUID?, aliveAttempts: Set<UUID>) {
        let (stream, continuation) = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        self.continuation = continuation
        self.aliveAttempts = aliveAttempts
        var logIdle: (@MainActor (NativeAgentRuntimeEvent) async -> Void)?
        var isAlive: (@MainActor (UUID) -> Bool)?
        var markFinished: (@MainActor () -> Void)?
        router = ClaudeNativeEventRouter(
            controller: controller,
            streamGeneration: 0,
            events: stream,
            initialOwner: initialOwner,
            idleHandler: { event in await logIdle?(event) },
            isRunTaskAlive: { attemptID in isAlive?(attemptID) ?? false },
            onFinished: { _ in markFinished?() }
        )
        logIdle = { [weak self] event in
            await self?.idleGate?()
            self?.log.append("idle:\(Self.label(event))")
        }
        isAlive = { [weak self] attemptID in self?.aliveAttempts.contains(attemptID) ?? false }
        markFinished = { [weak self] in self?.finishedNotified = true }
        router.start()
    }

    func yield(_ event: NativeAgentRuntimeEvent) {
        continuation.yield(event)
    }

    func finishStream() {
        continuation.finish()
    }

    /// Ends every run and finishes the stream.
    func shutdown() {
        let attempts = aliveAttempts
        aliveAttempts.removeAll()
        for attemptID in attempts {
            router.noteRunEnded(attemptID: attemptID)
        }
        router.signal()
        continuation.finish()
    }

    /// Waits until the processor has evaluated everything read so far and suspended, with
    /// `count` events still undelivered (held, not lost).
    func waitUntilProcessorWaits(undelivered count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(router.test_isProcessorWaiting && router.test_undeliveredEventCount == count) {
            guard ContinuousClock.now < deadline else {
                XCTFail(
                    "Processor did not settle with \(count) undelivered (has \(router.test_undeliveredEventCount))",
                    file: file,
                    line: line
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Waits until a consumer task entered `consumeRun`.
    func waitUntilConsuming(file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while consumingCount == 0 {
            guard ContinuousClock.now < deadline else {
                XCTFail("Consumer did not start", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        // `consumeRun` installs its sink synchronously once entered; let it run.
        await Task.yield()
    }

    /// Mirrors the runner: the run task becomes alive and registers synchronously; the controller
    /// emits the run's start marker before its message.
    func startRun(_ attemptID: UUID) {
        registerRun(attemptID)
        continuation.yield(.marker(attemptID))
    }

    func registerRun(_ attemptID: UUID) {
        aliveAttempts.insert(attemptID)
        router.noteRunStarted(attemptID: attemptID)
    }

    /// The run task is alive without registering on this router.
    func markAlive(_ attemptID: UUID) {
        aliveAttempts.insert(attemptID)
    }

    func note(_ entry: String) {
        log.append(entry)
    }

    func endRun(_ attemptID: UUID) {
        aliveAttempts.remove(attemptID)
        router.noteRunEnded(attemptID: attemptID)
    }

    func consume(
        _ attemptID: UUID,
        finishOn finishText: String,
        detachOn detachText: String? = nil
    ) -> Task<ClaudeNativeEventRouter.RunResolution, Never> {
        let router = router
        return Task { @MainActor [weak self] in
            self?.consumingCount += 1
            return await router.consumeRun(attemptID: attemptID) { event in
                let label = Self.label(event)
                if label == detachText {
                    self?.log.append("detached:\(label)")
                    return .detach
                }
                self?.log.append("run:\(label)")
                return label == finishText ? .finish : .continue
            }
        }
    }

    static func label(_ event: NativeAgentRuntimeEvent) -> String {
        switch event {
        case let .stream(result):
            result.text ?? result.type
        case let .approvalRequest(request):
            if case let .claudeControl(id) = request.requestID {
                "approval:\(id)"
            } else {
                "approval"
            }
        case let .approvalCancelled(requestID):
            "approvalCancelled:\(requestID)"
        case .runtimeInit:
            "runtimeInit"
        case .turnCompleted:
            "turnCompleted"
        case let .error(message):
            "error:\(message)"
        case let .marker(id):
            "marker:\(id.uuidString)"
        }
    }
}
