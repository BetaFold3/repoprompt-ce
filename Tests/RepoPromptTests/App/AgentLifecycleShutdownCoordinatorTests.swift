import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// R4 two-stage quit / window close (lossless-restart spec): the app-scoped lifecycle coordinator
/// with fake participants, a manual absolute-deadline clock, and a scripted failure presenter.
/// Launch marks go through the real recovery coordinator and store into a temporary directory whose
/// launch-file writes can be held or failed; assertions read what was durably committed. No window,
/// provider, or app lifecycle is touched.
@MainActor
final class AgentLifecycleShutdownCoordinatorTests: XCTestCase {
    // MARK: Fakes

    /// Virtual monotonic time: a sleep resumes when the test advances past its absolute deadline
    /// (or fires every pending one); `jump` moves time without waking anything; cancellation throws.
    private final class ManualDeadlineClock: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private var offset: Duration = .zero
        private var waiters: [(UUID, ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = []
        private var requested: [ContinuousClock.Instant] = []

        var now: ContinuousClock.Instant {
            lock.withLock { origin + offset }
        }

        func instant(at offset: Duration) -> ContinuousClock.Instant {
            origin + offset
        }

        func sleep(until deadline: ContinuousClock.Instant) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    requested.append(deadline)
                    if deadline <= origin + offset {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append((id, deadline, continuation))
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                let index = waiters.firstIndex { $0.0 == id }
                let continuation = index.map { waiters.remove(at: $0).2 }
                lock.unlock()
                continuation?.resume(throwing: CancellationError())
            }
        }

        var pendingCount: Int {
            lock.withLock { waiters.count }
        }

        /// Deadline sleeps requested so far, in order.
        var requestedDeadlines: [ContinuousClock.Instant] {
            lock.withLock { requested }
        }

        var requestedCount: Int {
            requestedDeadlines.count
        }

        /// Expires every pending sleep (time does not move).
        func fire() {
            lock.lock()
            let pending = waiters
            waiters = []
            lock.unlock()
            for (_, _, continuation) in pending {
                continuation.resume()
            }
        }

        /// Advances time, expiring the sleeps it reaches.
        func advance(by duration: Duration) {
            lock.lock()
            offset += duration
            let current = origin + offset
            let due = waiters.filter { $0.1 <= current }
            waiters.removeAll { $0.1 <= current }
            lock.unlock()
            for (_, _, continuation) in due {
                continuation.resume()
            }
        }

        /// Advances time without resuming any sleep (an executor that never ran the deadline task).
        func jump(by duration: Duration) {
            lock.withLock { offset += duration }
        }
    }

    /// The temporary launch file's write seam: records each durably committed launch mark, and can
    /// hold (block) or fail the next write of a given state.
    private final class LaunchMarkDisk: @unchecked Sendable {
        private let lock = NSLock()
        private var committedStates: [AgentRecoveryLaunchMark.State] = []
        private var failing: Set<AgentRecoveryLaunchMark.State> = []
        private var holds: [AgentRecoveryLaunchMark.State: DispatchSemaphore] = [:]
        private var holding: Set<AgentRecoveryLaunchMark.State> = []
        private var released: [DispatchSemaphore] = []

        var committed: [AgentRecoveryLaunchMark.State] {
            lock.withLock { committedStates }
        }

        func resetLog() {
            lock.withLock { committedStates = [] }
        }

        func fail(_ state: AgentRecoveryLaunchMark.State, _ enabled: Bool = true) {
            lock.withLock {
                if enabled { failing.insert(state) } else { failing.remove(state) }
            }
        }

        /// The next write of `state` blocks (inside the store) until `release(state)`.
        func hold(_ state: AgentRecoveryLaunchMark.State) {
            lock.withLock { holds[state] = DispatchSemaphore(value: 0) }
        }

        func isHolding(_ state: AgentRecoveryLaunchMark.State) -> Bool {
            lock.withLock { holding.contains(state) }
        }

        func release(_ state: AgentRecoveryLaunchMark.State) {
            let semaphore = lock.withLock { holds.removeValue(forKey: state) }
            semaphore?.signal()
        }

        func releaseAll() {
            let pending = lock.withLock {
                let values = Array(holds.values)
                holds = [:]
                return values
            }
            pending.forEach { $0.signal() }
        }

        func fileOperations() -> AgentRecoveryStore.FileOperations {
            AgentRecoveryStore.FileOperations(
                writeAtomically: { [self] data, url in
                    guard url.lastPathComponent == "launch-state.json", let state = Self.state(of: data) else {
                        try data.write(to: url, options: .atomic)
                        return
                    }
                    let semaphore = lock.withLock {
                        let held = holds[state]
                        if held != nil { holding.insert(state) }
                        return held
                    }
                    if let semaphore {
                        semaphore.wait()
                        lock.withLock { _ = holding.remove(state) }
                    }
                    if lock.withLock({ failing.contains(state) }) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                    lock.withLock { committedStates.append(state) }
                },
                removeItem: { url in try FileManager.default.removeItem(at: url) }
            )
        }

        private static func state(of data: Data) -> AgentRecoveryLaunchMark.State? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["state"] as? String
            else { return nil }
            return AgentRecoveryLaunchMark.State(rawValue: raw)
        }
    }

    /// A suspension point that ignores cancellation (a non-cooperative task).
    @MainActor
    private final class Hang {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0

        func wait() async {
            entered += 1
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            let pending = continuations
            continuations = []
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class FakeParticipant: AgentLifecycleShutdownParticipant {
        private(set) var activeFreezes: Set<UUID> = []
        private(set) var ownedRecoveryFreezes = 0
        private(set) var prepareCalls = 0
        private(set) var finalizeCalls = 0
        /// Teardown executions (joined calls are not counted, as in the real view model).
        private(set) var teardownExecutions = 0
        private var teardownTask: Task<Void, Never>?
        var prepareResults: [AgentModeShutdownReport] = []
        var finalizeResults: [AgentModeShutdownReport] = []
        var prepareHang: Hang?
        var teardownHang: Hang?

        var isFrozen: Bool {
            !activeFreezes.isEmpty
        }

        func beginShutdownFreeze(requestID: UUID, ownsRecoveryFreeze: Bool) {
            activeFreezes.insert(requestID)
            if ownsRecoveryFreeze { ownedRecoveryFreezes += 1 }
        }

        func endShutdownFreeze(requestID: UUID) {
            activeFreezes.remove(requestID)
        }

        func shutdownPrepare(reason _: AgentRecoveryShutdownReason) async -> AgentModeShutdownReport {
            prepareCalls += 1
            if let hang = prepareHang {
                prepareHang = nil
                await hang.wait()
            }
            return prepareResults.isEmpty ? AgentModeShutdownReport() : prepareResults.removeFirst()
        }

        func shutdownTearDown(reason _: AgentRecoveryShutdownReason) async {
            if let teardownTask {
                await teardownTask.value
                return
            }
            teardownExecutions += 1
            let hang = teardownHang
            let task = Task { @MainActor in
                if let hang { await hang.wait() }
            }
            teardownTask = task
            await task.value
        }

        func shutdownFinalize() async -> AgentModeShutdownReport {
            finalizeCalls += 1
            return finalizeResults.isEmpty ? AgentModeShutdownReport() : finalizeResults.removeFirst()
        }
    }

    /// Records every non-mark environment effect and scripts the failure prompt.
    @MainActor
    private final class Recorder {
        var appFreezeBegins = 0
        var appFreezeEnds = 0
        var layoutResult = true
        var layoutHang: Hang?
        var layoutCalls = 0
        var releasedBlockers: [String] = []
        var irreversible: [AgentLifecycleShutdownScope] = []
        var scopeTeardowns: [AgentLifecycleShutdownScope] = []
        var dismissed: [AgentLifecycleShutdownScope] = []
        var presented: [AgentLifecycleShutdownFailure] = []
        private var pendingChoice: CheckedContinuation<AgentLifecycleShutdownChoice, Never>?

        func present(_ failure: AgentLifecycleShutdownFailure) async -> AgentLifecycleShutdownChoice {
            presented.append(failure)
            return await withCheckedContinuation { pendingChoice = $0 }
        }

        var isPresenting: Bool {
            pendingChoice != nil
        }

        func choose(_ choice: AgentLifecycleShutdownChoice) {
            let continuation = pendingChoice
            pendingChoice = nil
            continuation?.resume(returning: choice)
        }
    }

    private var recorder: Recorder!
    private var clock: ManualDeadlineClock!
    private var disk: LaunchMarkDisk!
    private var fixture: RecoveryLaneFixture!
    private var appParticipants: [FakeParticipant] = []
    private var windowParticipants: [Int: FakeParticipant] = [:]
    private var hangs: [Hang] = []

    override func setUp() async throws {
        recorder = Recorder()
        clock = ManualDeadlineClock()
        disk = LaunchMarkDisk()
        fixture = try await RecoveryLaneFixture.make(
            "AgentLifecycleShutdownCoordinatorTests",
            fileOperations: disk.fileOperations()
        )
        // Startup wrote this launch's `running` mark; tests observe only what shutdown commits.
        disk.resetLog()
        appParticipants = []
        windowParticipants = [:]
        hangs = []
    }

    override func tearDown() async throws {
        // Never leave a suspended fake or a blocked write behind.
        hangs.forEach { $0.release() }
        disk?.releaseAll()
        recorder?.choose(.proceedAnyway)
        clock?.fire()
        await settle()
        fixture?.tearDown()
        fixture = nil
    }

    private func makeHang() -> Hang {
        let hang = Hang()
        hangs.append(hang)
        return hang
    }

    private func makeCoordinator() -> AgentLifecycleShutdownCoordinator {
        let recorder = recorder!
        let clock = clock!
        let recovery = fixture.coordinator
        return AgentLifecycleShutdownCoordinator(environment: AgentLifecycleShutdownEnvironment(
            participants: { [unowned self] scope in
                switch scope {
                case .application:
                    appParticipants
                case let .window(id):
                    windowParticipants[id].map { [$0] } ?? []
                }
            },
            beginApplicationRecoveryFreeze: {
                recorder.appFreezeBegins += 1
                return { recorder.appFreezeEnds += 1 }
            },
            preserveLayout: {
                recorder.layoutCalls += 1
                if let hang = recorder.layoutHang {
                    recorder.layoutHang = nil
                    await hang.wait()
                }
                return recorder.layoutResult
            },
            settleReleasedRecoveryInput: { recorder.releasedBlockers },
            recordLaunchState: { recovery.recordLaunchState($0) },
            authorizeCleanExit: { recovery.authorizeCleanExit() },
            recordCleanExit: { recovery.recordCleanExit(authorization: $0) },
            beginIrreversible: { recorder.irreversible.append($0) },
            tearDownScope: { recorder.scopeTeardowns.append($0) },
            presentFailure: { await recorder.present($0) },
            dismissFailure: { recorder.dismissed.append($0) },
            now: { clock.now },
            sleepUntil: { try await clock.sleep(until: $0) }
        ))
    }

    private func settle() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    /// Joins every launch-mark write enqueued so far: an unauthorized clean write is ordered behind
    /// them and writes nothing.
    private func drainLaunchMarks() async {
        _ = await fixture.coordinator.recordCleanExit(authorization: UUID()).value
    }

    private func diskMark() async -> AgentRecoveryLaunchMark.State? {
        guard case let .mark(mark) = await fixture.store.readLaunchMark() else { return nil }
        return mark.state
    }

    /// Waits (bounded, real time) for asynchronous effects, including store writes off the main actor.
    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if condition() { return }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Stage A

    func testStageAFailureCancelKeepsTheAppUsableAndASecondAttemptQuitsCleanly() async {
        let participant = FakeParticipant()
        participant.prepareResults = [AgentModeShutdownReport(blockers: ["Session A: a secret answer would be lost."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) })
        XCTAssertTrue(participant.isFrozen, "frozen synchronously, before the first await")
        XCTAssertEqual(recorder.appFreezeBegins, 1)
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, ["Session A: a secret answer would be lost."])
        XCTAssertEqual(coordinator.applicationRequest?.phase, .preparationFailed)
        XCTAssertTrue(recorder.irreversible.isEmpty, "Stage A never crosses the point of no return")

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen, "Cancel reopens the owners")
        XCTAssertEqual(recorder.appFreezeEnds, 1)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .running], "the app keeps running")
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertFalse(coordinator.isApplicationRequestActive, "interaction continues")

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) }, "a second attempt starts fresh")
        await waitUntil("the second reply") { replies.count == 2 }
        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(participant.prepareCalls, 2)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(recorder.irreversible, [.application])
        XCTAssertEqual(recorder.scopeTeardowns, [.application])
        XCTAssertEqual(disk.committed.last, .cleanExit, "the clean mark was committed before the reply")
        XCTAssertEqual(disk.committed.count { $0 == .cleanExit }, 1)
        let mark = await diskMark()
        XCTAssertEqual(mark, .cleanExit)
    }

    func testStageALayoutAndReleasedInputFailuresBlockAndRetryRunsAFreshAttempt() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        recorder.layoutResult = false
        recorder.releasedBlockers = ["A closed tab's draft is not saved yet."]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(
            recorder.presented.last?.messages,
            [AgentLifecycleShutdownCoordinator.layoutFailureMessage, "A closed tab's draft is not saved yet."]
        )
        recorder.layoutResult = true
        recorder.releasedBlockers = []
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(coordinator.applicationRequest?.preparationAttempts, 2)
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    /// One absolute deadline per attempt: a non-cooperative preparation never delays the prompt,
    /// and its late completion is fenced (no teardown, no reply, no clean mark).
    func testStageADeadlineDoesNotJoinANonCooperativeTaskAndItsLateCompletionIsFenced() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck preparation") { hang.entered == 1 && clock.pendingCount == 1 }

        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, .preparation)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure?.messages, [AgentLifecycleShutdownCoordinator.timeoutMessage])

        hang.release()
        await settle()
        XCTAssertEqual(coordinator.applicationRequest?.phase, .preparationFailed, "late success is fenced")
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertTrue(replies.isEmpty)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit))

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen)
    }

    /// Cancel fences the attempt's remaining Stage A side effects: a late step never writes
    /// `shutdownInProgress` after Cancel's `running`, nor prepares participants.
    func testCancelFencesLateStageASideEffects() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let hang = makeHang()
        recorder.layoutHang = hang
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck layout step") { hang.entered == 1 && clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.running])

        hang.release()
        await settle()
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.running], "no late shutdownInProgress lands after Cancel")
        XCTAssertEqual(participant.prepareCalls, 0, "no participant is prepared for a cancelled attempt")
        XCTAssertEqual(replies, [false])
    }

    // MARK: Absolute expiry (R4-05)

    /// The expiry is captured when the user attempt starts: a deadline task that runs late (a busy
    /// main actor) still expires at the captured instant, never 8 seconds after it started.
    func testDelayedDeadlineTaskNeverExtendsTheCapturedExpiry() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        // Five seconds pass before the deadline task first runs.
        clock.jump(by: .seconds(5))
        await waitUntil("the deadline sleep") { clock.requestedCount == 1 && hang.entered == 1 }
        XCTAssertEqual(clock.requestedDeadlines, [clock.instant(at: .seconds(8))], "captured at the request")

        clock.advance(by: .milliseconds(2900))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "7.9 of 8 seconds since the request")
        clock.advance(by: .milliseconds(100))
        await waitUntil("the timeout at the captured expiry") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty)
        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
    }

    /// Success transitions check the captured expiry themselves: work that finishes after it (while
    /// the deadline task never got to run) neither crosses the point of no return nor marks clean.
    func testWorkFinishingAfterTheExpiryNeverCrossesTheBoundaryOrMarksClean() async {
        let participant = FakeParticipant()
        let prepareHang = makeHang()
        participant.prepareHang = prepareHang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { prepareHang.entered == 1 && clock.pendingCount == 1 }

        clock.jump(by: .seconds(9))
        prepareHang.release()
        await waitUntil("the Stage A timeout") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty, "a late Stage A never crosses the boundary")
        XCTAssertEqual(participant.teardownExecutions, 0)

        // Retry: a fresh deadline; Stage B's final flush then finishes after that expiry.
        let teardownHang = makeHang()
        participant.teardownHang = teardownHang
        recorder.choose(.retry)
        await waitUntil("the stuck teardown") { teardownHang.entered == 1 }
        clock.jump(by: .seconds(9))
        teardownHang.release()
        await waitUntil("the Stage B timeout") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertEqual(participant.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit), "no clean mark after the expiry")

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(participant.teardownExecutions, 1)
        let mark = await diskMark()
        XCTAssertEqual(mark, .cleanExit, "a retry within its own deadline marks clean")
    }

    // MARK: Stage B

    /// One absolute deadline per user attempt: Stage B receives only what Stage A left of it (no
    /// second deadline is armed at the point of no return); an explicit Retry gets a fresh one.
    func testOneAbsoluteDeadlineSpansStageAAndStageBAndOnlyRetryRearmsIt() async {
        let participant = FakeParticipant()
        let prepareHang = makeHang()
        let teardownHang = makeHang()
        participant.prepareHang = prepareHang
        participant.teardownHang = teardownHang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { prepareHang.entered == 1 && clock.pendingCount == 1 }

        clock.advance(by: .seconds(7))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "7 of 8 seconds used in Stage A")
        prepareHang.release()
        await waitUntil("the stuck teardown") { teardownHang.entered == 1 }
        XCTAssertEqual(clock.requestedCount, 1, "the point of no return arms no second deadline")
        XCTAssertEqual(coordinator.applicationRequest?.phase, .tearingDown)

        clock.advance(by: .milliseconds(1500))
        await waitUntil("the Stage B timeout on the remainder") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)

        recorder.choose(.retry)
        await waitUntil("the retry deadline") { clock.requestedCount == 2 && clock.pendingCount == 1 }
        XCTAssertEqual(clock.requestedDeadlines.last, clock.instant(at: .milliseconds(16500)), "Retry: now + 8 s")
        clock.advance(by: .milliseconds(7900))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "Retry gets a fresh 8 seconds")
        clock.advance(by: .milliseconds(200))
        await waitUntil("the retry timeout") { recorder.presented.count == 2 && recorder.isPresenting }
        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit))
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    func testStageBOffersNoCancelAndRetryFlushesAgainWithoutRepeatingTeardown() async {
        let participant = FakeParticipant()
        participant.finalizeResults = [AgentModeShutdownReport(blockers: ["Session A: the conversation could not be saved."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(coordinator.applicationRequest?.phase, .finalizationFailed)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit), "no clean mark after a failed final flush")

        recorder.choose(.cancel)
        await waitUntil("the prompt again") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization, "Stage B has no Cancel")
        XCTAssertEqual(
            recorder.presented.last?.messages,
            ["Session A: the conversation could not be saved."],
            "the dismissed prompt is shown again with its own reasons"
        )
        XCTAssertEqual(recorder.presented.last?.timedOut, false)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(participant.isFrozen, "past the point of no return nothing reopens")

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(participant.finalizeCalls, 2, "Retry flushes again")
        XCTAssertEqual(participant.teardownExecutions, 1, "teardown never runs twice")
        XCTAssertEqual(recorder.irreversible, [.application])
        XCTAssertEqual(recorder.scopeTeardowns, [.application])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
    }

    /// The Stage B deadline does not join a stuck teardown; Quit Anyway completes without a clean
    /// mark, and the teardown's late completion never finalizes or marks clean.
    func testStageBDeadlineWithAStuckTeardownQuitsAnywayWithoutACleanMark() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.teardownHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck teardown") { hang.entered == 1 && clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)

        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        hang.release()
        await settle()
        await drainLaunchMarks()
        XCTAssertEqual(participant.finalizeCalls, 0, "late teardown completion is fenced")
        XCTAssertEqual(disk.committed, [.shutdownInProgress])
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(replies, [true], "replied exactly once")
    }

    // MARK: Clean mark at the persistence boundary (R4-02)

    /// A clean write that failed committed nothing: no correction is needed, the launch file keeps
    /// the unclean mark, and Quit Anyway replies at once.
    func testFailedCleanWriteLeavesTheUncleanMarkWithoutACorrection() async {
        appParticipants = [FakeParticipant()]
        disk.fail(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.cleanMarkFailureMessage])
        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress], "nothing clean was committed, nothing corrected")
        let mark = await diskMark()
        XCTAssertEqual(mark, .shutdownInProgress)
    }

    /// Stage A awaits its `shutdownInProgress` mark: an unconfirmed write is held by the attempt's
    /// deadline (a Stage A timeout), never crossed. Nothing is prepared or torn down behind it.
    func testUnconfirmedStageALaunchMarkTimesOutBeforeAnythingIsTornDown() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.shutdownInProgress)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("Stage A's mark write held in the store") {
            disk.isHolding(.shutdownInProgress) && clock.pendingCount == 1
        }
        await settle()
        XCTAssertEqual(participant.prepareCalls, 0, "preparation waits for the confirmed mark")

        clock.fire()
        await waitUntil("the Stage A timeout prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty, "never crossed the point of no return")
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed)
        XCTAssertEqual(participant.teardownExecutions, 0)

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        disk.release(.shutdownInProgress)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .running], "Cancel's mark is ordered last")
        XCTAssertEqual(participant.prepareCalls, 0, "the late mark never resumes the cancelled attempt")
    }

    /// A failed Stage A launch mark blocks the point of no return (Retry / Cancel); Retry writes it
    /// again and, once confirmed, quits cleanly.
    func testFailedStageALaunchMarkPreventsTeardownUntilRetryConfirmsIt() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.fail(.shutdownInProgress)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.launchMarkFailureMessage])
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)

        disk.fail(.shutdownInProgress, false)
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    // MARK: Delayed clean-write acknowledgement

    /// Every participant was prepared and finalized and the clean write was enqueued under a valid
    /// authorization; only its acknowledgement is late. That is not uncertainty about saved input:
    /// no correction is written, the prompt says so, and Quit Anyway replies at once.
    func testDelayedCleanAcknowledgementIsNeverCorrectedAndQuitAnywayRepliesAtOnce() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }

        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, .finalization)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure?.awaitsCleanExitAcknowledgement, true)
        XCTAssertEqual(failure?.messages, [AgentLifecycleShutdownCoordinator.cleanExitAcknowledgementMessage])
        recorder.choose(.proceedAnyway)
        await waitUntil("the immediate reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true], "Quit Anyway does not wait for the write")

        disk.release(.cleanExit)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "no corrective write")
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(replies, [true], "replied exactly once")
    }

    /// Retry joins the pending clean write (bounded by its own fresh deadline, never a second
    /// write or finalization); the write's late completion never terminates the app by itself.
    func testRetryJoinsADelayedCleanWriteWhoseLateCompletionNeverTerminates() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }
        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }

        recorder.choose(.retry)
        await waitUntil("the retry deadline") { clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the bounded retry prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.cleanExitAcknowledgementMessage])
        XCTAssertTrue(replies.isEmpty)

        disk.release(.cleanExit)
        await drainLaunchMarks()
        await settle()
        XCTAssertTrue(replies.isEmpty, "a late acknowledgement never terminates by itself")
        XCTAssertEqual(coordinator.applicationRequest?.phase, .finalizationFailed)

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "one clean write")
        XCTAssertEqual(participant.finalizeCalls, 1, "no duplicate finalization")
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    /// A delayed clean write that finally wrote nothing is released: Retry finalizes and
    /// authorizes afresh.
    func testRetryAfterADelayedCleanWriteThatWroteNothingAuthorizesAfresh() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        disk.fail(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }
        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }
        disk.release(.cleanExit)
        await drainLaunchMarks()
        await settle()
        XCTAssertNil(coordinator.applicationRequest?.cleanWrite, "a write that wrote nothing is released")

        disk.fail(.cleanExit, false)
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
        XCTAssertEqual(participant.finalizeCalls, 2)
    }

    // MARK: Window close

    func testWindowCloseNeverWritesALaunchMarkAndHonorsTheForwardedVeto() async {
        let participant = FakeParticipant()
        windowParticipants = [7: participant]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var allowClose = false

        XCTAssertTrue(coordinator.requestWindowClose(windowID: 7, forwardedVeto: { allowClose }, finish: { finishes.append($0) }))
        XCTAssertTrue(participant.isFrozen)
        XCTAssertEqual(participant.ownedRecoveryFreezes, 1, "a window close owns its scoped recovery freeze")
        XCTAssertFalse(
            coordinator.requestWindowClose(windowID: 7, forwardedVeto: { true }, finish: { finishes.append($0) }),
            "a duplicate close joins the request in progress"
        )
        await waitUntil("the vetoed finish") { !finishes.isEmpty }
        XCTAssertEqual(finishes, [false], "the forwarded veto is honored before the point of no return")
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertFalse(participant.isFrozen)

        allowClose = true
        coordinator.requestWindowClose(windowID: 7, forwardedVeto: { allowClose }, finish: { finishes.append($0) })
        await waitUntil("the authorized finish") { finishes.count == 2 }
        XCTAssertEqual(finishes, [false, true])
        XCTAssertEqual(recorder.irreversible, [.window(7)])
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(participant.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertTrue(disk.committed.isEmpty, "a window close never writes a global launch mark")
        XCTAssertEqual(recorder.appFreezeBegins, 0)
        XCTAssertFalse(coordinator.hasUnfinalizedWindowClose)
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed, "a window close never seals admission")
        XCTAssertTrue(coordinator.admitApplicationWindow(FakeParticipant()))
    }

    /// R4-2 (B): Close Anyway after a failed window final flush keeps every later app quit of this
    /// launch from proving a clean exit.
    func testCloseAnywayKeepsALaterQuitFromMarkingClean() async {
        let window = FakeParticipant()
        window.finalizeResults = [AgentModeShutdownReport(blockers: ["Session W: the conversation could not be saved."])]
        let other = FakeParticipant()
        windowParticipants = [5: window]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        coordinator.requestWindowClose(windowID: 5, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the window Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        recorder.choose(.proceedAnyway)
        await waitUntil("the window finish") { !finishes.isEmpty }
        XCTAssertEqual(finishes, [true])
        XCTAssertTrue(coordinator.hasUnfinalizedWindowClose)

        windowParticipants = [:]
        appParticipants = [other]
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(other.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress], "the quit never marks clean")
        let mark = await diskMark()
        XCTAssertEqual(mark, .shutdownInProgress)
    }

    func testAppQuitSupersedesAWindowCloseInStageAAndRefusesNewCloses() async {
        let window = FakeParticipant()
        let hang = makeHang()
        window.prepareHang = hang
        let other = FakeParticipant()
        windowParticipants = [1: window]
        appParticipants = [window, other]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var replies: [Bool] = []
        coordinator.requestWindowClose(windowID: 1, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the stuck window preparation") { hang.entered == 1 }

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) })
        XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) }, "a duplicate quit joins")
        XCTAssertEqual(finishes, [false], "the window stays open; the quit owns it now")
        XCTAssertEqual(recorder.dismissed, [.window(1)])
        XCTAssertTrue(window.isFrozen, "still frozen by the app quit")
        XCTAssertFalse(
            coordinator.requestWindowClose(windowID: 2, forwardedVeto: { true }, finish: { finishes.append($0) }),
            "no window close starts during an app quit"
        )
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(window.teardownExecutions, 1)
        XCTAssertEqual(other.teardownExecutions, 1)
        hang.release()
        await settle()
        XCTAssertEqual(finishes, [false], "the superseded close never finishes later")
    }

    func testAppQuitJoinsAWindowPastItsPointOfNoReturnWithoutPreparingOrTearingItDownAgain() async {
        let window = FakeParticipant()
        let hang = makeHang()
        window.teardownHang = hang
        let other = FakeParticipant()
        windowParticipants = [3: window]
        appParticipants = [window, other]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var replies: [Bool] = []
        coordinator.requestWindowClose(windowID: 3, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the window teardown") { hang.entered == 1 }

        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the other window's preparation") { other.prepareCalls == 1 }
        XCTAssertEqual(window.prepareCalls, 1, "a window past its point of no return is not prepared again")
        hang.release()
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(window.teardownExecutions, 1, "its single teardown is joined, never repeated")
        XCTAssertEqual(disk.committed.last, .cleanExit)
    }

    // MARK: Window admission during an app quit (R4-3)

    /// Registers a window the way `WindowStatesManager.registerWindowState` does: admission is
    /// decided first; only an admitted window becomes an app participant.
    @discardableResult
    private func register(_ participant: FakeParticipant, with coordinator: AgentLifecycleShutdownCoordinator) -> Bool {
        guard coordinator.admitApplicationWindow(participant) else { return false }
        appParticipants.append(participant)
        return true
    }

    /// A window registered while Stage A runs is frozen at registration and invalidates the
    /// attempt: Stage A fails instead of crossing the point of no return without it. Retry
    /// preserves the layout again (now including it) and prepares it before the boundary.
    func testWindowRegisteredDuringStageAFailsTheAttemptAndRetryPreservesLayoutAndPreparesIt() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { hang.entered == 1 }

        let newcomer = FakeParticipant()
        XCTAssertTrue(register(newcomer, with: coordinator), "Stage A admits")
        XCTAssertTrue(newcomer.isFrozen, "frozen synchronously at registration")
        hang.release()
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.newWindowMessage])
        XCTAssertTrue(recorder.irreversible.isEmpty, "never crossed the point of no return without it")
        XCTAssertEqual(newcomer.prepareCalls, 0)
        XCTAssertEqual(recorder.layoutCalls, 1)

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(recorder.layoutCalls, 2, "the layout is preserved again with the new window")
        XCTAssertEqual(newcomer.prepareCalls, 1, "prepared before the point of no return")
        XCTAssertEqual(newcomer.teardownExecutions, 1)
        XCTAssertEqual(newcomer.finalizeCalls, 1)
        XCTAssertEqual(disk.committed.last, .cleanExit)
        XCTAssertFalse(disk.committed.dropLast().contains(.cleanExit))
    }

    /// A window registered while the Stage A prompt is shown joins the request; Cancel unfreezes it
    /// with the others. A registration after the request finished is ignored.
    func testWindowRegisteredDuringAStageAPromptIsUnfrozenByCancel() async {
        let participant = FakeParticipant()
        participant.prepareResults = [AgentModeShutdownReport(blockers: ["Session A: a draft could not be saved."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }

        let newcomer = FakeParticipant()
        register(newcomer, with: coordinator)
        XCTAssertTrue(newcomer.isFrozen)
        recorder.choose(.cancel)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(newcomer.isFrozen, "Cancel reopens the window that joined")
        XCTAssertFalse(participant.isFrozen)

        let afterwards = FakeParticipant()
        XCTAssertTrue(register(afterwards, with: coordinator), "a cancelled quit never sealed admission")
        XCTAssertFalse(afterwards.isFrozen, "no quit in progress")
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed)
    }

    /// Admission is sealed synchronously at the point of no return, before anything irreversible:
    /// a window arriving during teardown is refused and never frozen, prepared, torn down, or
    /// finalized, so it cannot invalidate the clean proof of the windows this quit prepared.
    func testAdmissionIsSealedAtThePointOfNoReturnAndARefusedWindowIsUntouched() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.teardownHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed, "Stage A admits")
        await waitUntil("the teardown") { hang.entered == 1 }
        XCTAssertTrue(coordinator.isApplicationAdmissionSealed)
        XCTAssertEqual(recorder.irreversible, [.application])

        let newcomer = FakeParticipant()
        XCTAssertFalse(register(newcomer, with: coordinator), "refused past the point of no return")
        XCTAssertFalse(newcomer.isFrozen)
        hang.release()
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(newcomer.prepareCalls, 0)
        XCTAssertEqual(newcomer.teardownExecutions, 0)
        XCTAssertEqual(newcomer.finalizeCalls, 0)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "the proof covers every admitted window")
    }

    /// The concrete late-window race: a window arrives while the clean write is gated in the store.
    /// It is refused before registration, nothing it would own is touched, and the clean claim
    /// stays justified (no correction). The seal persists after completion: no window, close, or
    /// second quit is admitted until the process exits.
    func testWindowArrivingWhileTheCleanWriteIsGatedIsRefusedAndTheCleanClaimHolds() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }

        let newcomer = FakeParticipant()
        XCTAssertFalse(register(newcomer, with: coordinator))
        XCTAssertFalse(newcomer.isFrozen)
        XCTAssertEqual(appParticipants.count, 1, "the refused window is never a participant")
        disk.release(.cleanExit)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(recorder.presented.isEmpty)
        XCTAssertEqual(recorder.layoutCalls, 1)
        XCTAssertEqual(newcomer.prepareCalls + newcomer.teardownExecutions + newcomer.finalizeCalls, 0)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "no correction")

        XCTAssertTrue(coordinator.isApplicationAdmissionSealed, "sealed until the process exits")
        XCTAssertFalse(register(FakeParticipant(), with: coordinator))
        XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) })
        windowParticipants = [9: participant]
        XCTAssertFalse(coordinator.requestWindowClose(windowID: 9, forwardedVeto: { true }, finish: { _ in }))
        XCTAssertEqual(replies, [true])
    }

    // MARK: Close authorization

    func testFinalizedCloseAuthorizationIsOneShot() {
        let closeCoordinator = WindowCloseCoordinator()
        XCTAssertFalse(closeCoordinator.consumeFinalizedCloseAuthorization())
        closeCoordinator.authorizeFinalizedClose()
        XCTAssertTrue(closeCoordinator.consumeFinalizedCloseAuthorization())
        XCTAssertFalse(closeCoordinator.consumeFinalizedCloseAuthorization(), "a later close asks again")
    }
}
