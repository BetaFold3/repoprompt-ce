@testable import RepoPromptApp
import XCTest

final class HeadlessCLIStreamBridgeTests: XCTestCase {
    private enum TestFailure: Error {
        case failed
    }

    func testDisposesExactlyOnceAcrossFinishErrorAndCancellation() async throws {
        for scenario in ["finish", "error", "cancel"] {
            let provider = HeadlessBridgeTestProvider()
            let store = ActiveHeadlessAgentProviderStore<HeadlessBridgeTestProvider>()
            let disposal = expectation(description: "disposed-\(scenario)")
            let upstream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
                switch scenario {
                case "finish":
                    continuation.yield(AIStreamResult(type: "content", text: "done"))
                    continuation.finish()
                case "error":
                    continuation.finish(throwing: TestFailure.failed)
                default:
                    provider.retain(continuation)
                }
            }
            let stream = try await HeadlessCLIStreamBridge.startStream(
                provider: provider,
                activeProviders: store,
                makeUpstream: { upstream },
                dispose: { provider in
                    provider.recordDisposal()
                    disposal.fulfill()
                }
            )

            let consumer = Task {
                do {
                    for try await _ in stream {}
                } catch {}
            }
            if scenario == "cancel" {
                await Task.yield()
                consumer.cancel()
            }
            _ = await consumer.result
            await fulfillment(of: [disposal], timeout: 1)
            await HeadlessCLIStreamBridge.disposeAll(
                activeProviders: store,
                dispose: { provider in provider.recordDisposal() }
            )
            XCTAssertEqual(provider.disposalCount, 1, scenario)
            XCTAssertEqual(provider.disposalCancellationStates, [false], scenario)
        }
    }

    func testStartFailureDisposesExactlyOnceWithoutReplacingOriginalError() async {
        let provider = HeadlessBridgeTestProvider()
        let store = ActiveHeadlessAgentProviderStore<HeadlessBridgeTestProvider>()

        do {
            _ = try await HeadlessCLIStreamBridge.startStream(
                provider: provider,
                activeProviders: store,
                makeUpstream: { throw TestFailure.failed },
                dispose: { provider in provider.recordDisposal() }
            )
            XCTFail("Expected upstream start failure")
        } catch TestFailure.failed {
            // The original start error must escape unchanged.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await HeadlessCLIStreamBridge.disposeAll(
            activeProviders: store,
            dispose: { provider in provider.recordDisposal() }
        )
        XCTAssertEqual(provider.disposalCount, 1)
        XCTAssertEqual(provider.disposalCancellationStates, [false])
    }

    func testCompletionPoliciesPreserveCursorPermissivenessAndRejectOMPPartialText() async throws {
        let partial = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            continuation.yield(AIStreamResult(type: "content", text: "partial"))
            continuation.finish()
        }
        let cursorResult = try await HeadlessCLIStreamBridge.complete(
            stream: partial,
            providerName: "Cursor",
            acceptance: .terminalOrNonemptyText
        )
        XCTAssertEqual(cursorResult.text, "partial")

        let ompPartial = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            continuation.yield(AIStreamResult(type: "content", text: "partial"))
            continuation.finish()
        }
        do {
            _ = try await HeadlessCLIStreamBridge.complete(
                stream: ompPartial,
                providerName: "Oh My Pi",
                acceptance: .terminalRequired
            )
            XCTFail("Expected a missing-terminal failure")
        } catch let error as AIProviderError {
            guard case let .invalidResponse(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, "Oh My Pi returned no successful completion")
        }
    }

    func testTerminalRequiredRejectsToolEventsWhileCursorPolicyRemainsPermissive() async throws {
        for toolType in ["tool_call", "tool_result", "tool_progress"] {
            let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
                continuation.yield(AIStreamResult(type: toolType, text: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: ""))
                continuation.finish()
            }
            do {
                _ = try await HeadlessCLIStreamBridge.complete(
                    stream: stream,
                    providerName: "Provider-independent",
                    acceptance: .terminalRequired
                )
                XCTFail("Expected \(toolType) to fail a tool-free completion")
            } catch let error as AIProviderError {
                guard case let .invalidResponse(detail) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(detail, HeadlessCLIStreamBridge.toolEventRejectedDetail)
            }
        }

        let cursorStream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            continuation.yield(AIStreamResult(type: "tool_call", text: nil))
            continuation.yield(AIStreamResult(type: "content", text: "cursor text"))
            continuation.yield(AIStreamResult(type: "message_stop", text: ""))
            continuation.finish()
        }
        let cursorResult = try await HeadlessCLIStreamBridge.complete(
            stream: cursorStream,
            providerName: "Cursor",
            acceptance: .terminalOrNonemptyText,
            missingSuccessDetail: "Cursor returned no completion"
        )
        XCTAssertEqual(cursorResult.text, "cursor text")
    }
}

private final class HeadlessBridgeTestProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var retainedContinuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?
    private var disposals = 0
    private var cancellationStates: [Bool] = []

    var disposalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disposals
    }

    var disposalCancellationStates: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return cancellationStates
    }

    func retain(_ continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) {
        lock.lock()
        retainedContinuation = continuation
        lock.unlock()
    }

    func recordDisposal() {
        lock.lock()
        disposals += 1
        cancellationStates.append(Task.isCancelled)
        let continuation = retainedContinuation
        retainedContinuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
