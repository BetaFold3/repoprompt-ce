import Foundation

/// A generic helper for "wait for user input with optional timeout" patterns.
/// Used by both question and instruction flows.
@MainActor
public final class AsyncUserWaiter<Response: Sendable> {
    private var continuation: CheckedContinuation<Response, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var startedAt: Date?

    public init() {}

    /// Current elapsed seconds since wait began (0 if not waiting)
    public var elapsedSeconds: Int {
        guard let start = startedAt else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    /// Whether currently waiting for a response
    public var isWaiting: Bool {
        continuation != nil
    }

    /// Wait for a response with optional timeout.
    /// - Parameters:
    ///   - timeoutSeconds: Optional timeout duration. Nil means no timeout.
    ///   - onTimeout: Called when timeout elapses, should return a timeout response.
    /// - Returns: The response (either from resume() or timeout)
    /// - Throws: CancellationError if cancel() is called
    public func wait(
        timeoutSeconds: TimeInterval?,
        onTimeout: @escaping @MainActor @Sendable (_ elapsed: Int) -> Response
    ) async throws -> Response {
        // Cancel any existing wait
        cancel()

        startedAt = Date()

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            // Set up timeout if specified
            if let timeout = timeoutSeconds, timeout > 0 {
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.handleTimeout(onTimeout: onTimeout)
                    }
                }
            }
        }
    }

    /// Resume the wait with a successful response.
    public func resume(_ response: Response) {
        guard let cont = continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        startedAt = nil

        cont.resume(returning: response)
    }

    /// Cancel the wait, causing it to throw CancellationError.
    public func cancel() {
        guard let cont = continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        startedAt = nil

        cont.resume(throwing: CancellationError())
    }

    private func handleTimeout(onTimeout: @MainActor @Sendable (_ elapsed: Int) -> Response) {
        guard let cont = continuation else { return }

        let elapsed = elapsedSeconds

        continuation = nil
        timeoutTask = nil
        startedAt = nil

        let response = onTimeout(elapsed)
        cont.resume(returning: response)
    }
}
