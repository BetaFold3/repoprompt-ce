import Dispatch
import XCTest

func pollUntilOrFail(
    _ condition: () async -> Bool,
    deadline: Duration = .seconds(30),
    interval: Duration = .milliseconds(10),
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let startedAt = clock.now

    while true {
        if await condition() { return }

        let elapsed = startedAt.duration(to: clock.now)
        guard elapsed < deadline else {
            XCTFail("\(message) (elapsed: \(elapsed))", file: file, line: line)
            return
        }

        do {
            try await Task.sleep(for: min(interval, deadline - elapsed))
        } catch {
            XCTFail("\(message) (polling cancelled after: \(elapsed))", file: file, line: line)
            return
        }
    }
}

/// Blocks the calling thread until the semaphore signals or the timeout elapses.
/// Do not call from `MainActor`-isolated or cooperative-pool contexts; reserve it
/// for dedicated-thread or utility-queue test code, or it can deadlock.
func waitOrFail(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval = .seconds(30),
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        XCTFail(message, file: file, line: line)
        return
    }
}
