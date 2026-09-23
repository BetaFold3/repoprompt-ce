import Foundation
@testable import RepoPromptApp
import XCTest

func waitForAgentRunSessionStoreWaiter(
    registration: AgentRunSessionStore.Registration,
    expectedCount: Int = 1,
    timeout: TimeInterval = 1.5,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    do {
        try await AsyncTestWait.waitUntil(
            "AgentRunSessionStore waiter count \(expectedCount)",
            timeout: timeout
        ) {
            await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == expectedCount
        }
    } catch {
        let actualCount = await AgentRunSessionStore.shared.test_waiterCount(registration: registration)
        XCTFail(
            "Timed out waiting for AgentRunSessionStore waiter count \(expectedCount); actual=\(actualCount).",
            file: file,
            line: line
        )
        throw error
    }
}

final class AgentRunSessionStoreTimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequestedTimeoutNanoseconds: UInt64?
    private var sleepContinuations: [CheckedContinuation<Void, Never>] = []
    private var storedIsReleased = false

    func sleep(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            storedRequestedTimeoutNanoseconds = nanoseconds
            if storedIsReleased {
                lock.unlock()
                continuation.resume()
            } else {
                sleepContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitForRequestedTimeout(
        timeout: TimeInterval = 1
    ) async throws -> UInt64 {
        let description = "AgentRunSessionStore timeout request"
        try await AsyncTestWait.waitUntil(description, timeout: timeout) {
            self.requestedTimeoutNanoseconds != nil
        }
        guard let requestedTimeoutNanoseconds else {
            throw AsyncTestConditionTimeout(description: description, timeout: timeout)
        }
        return requestedTimeoutNanoseconds
    }

    func release() {
        lock.lock()
        storedIsReleased = true
        let continuations = sleepContinuations
        sleepContinuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    var requestedTimeoutNanoseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestedTimeoutNanoseconds
    }

    var parkedSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepContinuations.count
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsReleased
    }
}

func waitForBoundedFixtureTaskValue<Success: Sendable, Failure: Error>(
    _ task: Task<Success, Failure>,
    description: String,
    timeout: TimeInterval = 1,
    cleanupBeforeCancellation: @escaping @Sendable () async -> Void
) async throws -> Success {
    let completion = AsyncTestCondition<Result<Success, Failure>?>(nil)
    let observationTask = Task {
        let result = await task.result
        completion.update { $0 = result }
    }

    do {
        try await completion.waitUntil(description, timeout: timeout) { $0 != nil }
    } catch {
        await cleanupBeforeCancellation()
        task.cancel()
        observationTask.cancel()
        _ = await task.result
        _ = await observationTask.result
        throw error
    }

    _ = await observationTask.result
    guard let result = completion.snapshot() else {
        throw AsyncTestConditionTimeout(description: description, timeout: timeout)
    }
    return try result.get()
}
