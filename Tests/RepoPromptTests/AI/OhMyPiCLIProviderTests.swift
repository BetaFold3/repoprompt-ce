@testable import RepoPromptApp
import XCTest

final class OhMyPiCLIProviderTests: XCTestCase {
    fileprivate enum TestFailure: Error {
        case upstream
    }

    func testCanonicalModelAndToolFreeConfigAfterRegistryWarm() async throws {
        let canonicalRaw = "Cursor/GPT:Fast"
        let recorder = OhMyPiCLIRecorder()
        let fake = OhMyPiCLIFake(behavior: .terminal(text: "complete"))
        let provider = OhMyPiCLIProvider(
            headlessProviderFactory: { config, workspacePath in
                recorder.recordFactory(config: config, workspacePath: workspacePath)
                return AnyHeadlessAgentProvider(fake)
            },
            modelSnapshotResolver: {
                recorder.recordStep("warm")
                return Self.snapshot(rawValue: canonicalRaw)
            },
            connectionStateProvider: {
                recorder.recordStep("connection")
                return true
            }
        )

        let thinking = ACPConfigOptionAssignment.ohMyPiThinking("high")
        let result = try await provider.completeMessage(
            AIMessage(
                systemPrompt: "",
                userMessage: "Hello",
                executionMetadata: AIMessageExecutionMetadata(
                    additionalACPConfigOptionValues: [thinking]
                )
            ),
            model: .ohMyPiCustom(name: "cursor/gpt:fast")
        )

        XCTAssertEqual(result.text, "complete")
        XCTAssertEqual(recorder.steps, ["warm", "connection"])
        XCTAssertEqual(recorder.config?.modelString, canonicalRaw)
        XCTAssertEqual(recorder.config?.additionalConfigOptionValues, [thinking])
        XCTAssertEqual(recorder.config?.includeRepoPromptMCPServer, false)
        XCTAssertNil(recorder.workspacePath)
        XCTAssertEqual(fake.lastMessage?.resumeSessionID, nil)
        XCTAssertTrue(fake.lastMessage?.systemPrompt.contains("Do not use any tools") == true)
        XCTAssertEqual(fake.disposalCount, 1)

        await provider.dispose()
        XCTAssertEqual(fake.disposalCount, 1)
    }

    func testDisconnectedAndWithdrawnModelsFailClosedWithDistinctErrors() async throws {
        let disconnectedRecorder = OhMyPiCLIRecorder()
        let disconnected = OhMyPiCLIProvider(
            headlessProviderFactory: { _, _ in
                XCTFail("Disconnected requests must not start OMP")
                return AnyHeadlessAgentProvider(OhMyPiCLIFake(behavior: .empty))
            },
            modelSnapshotResolver: {
                disconnectedRecorder.recordStep("warm")
                return Self.snapshot(rawValue: "provider/model")
            },
            connectionStateProvider: {
                disconnectedRecorder.recordStep("connection")
                return false
            }
        )

        do {
            _ = try await disconnected.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "provider/model")
            )
            XCTFail("Expected disconnected configuration failure")
        } catch let error as AIProviderError {
            guard case let .invalidConfiguration(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("disconnected"))
        }
        XCTAssertEqual(disconnectedRecorder.steps, ["warm", "connection"])

        let withdrawn = OhMyPiCLIProvider(
            headlessProviderFactory: { _, _ in
                XCTFail("Withdrawn models must not start OMP")
                return AnyHeadlessAgentProvider(OhMyPiCLIFake(behavior: .empty))
            },
            modelSnapshotResolver: { Self.snapshot(rawValue: "other/model") },
            connectionStateProvider: { true }
        )
        do {
            _ = try await withdrawn.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "missing/model")
            )
            XCTFail("Expected withdrawn-model configuration failure")
        } catch let error as AIProviderError {
            guard case let .invalidConfiguration(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("no longer available upstream"))
            XCTAssertTrue(detail.contains("missing/model"))
        }
    }

    func testPartialAndEmptyStreamsRequireSuccessTerminal() async throws {
        for behavior in [OhMyPiCLIFake.Behavior.partial(text: "partial"), .empty] {
            let fake = OhMyPiCLIFake(behavior: behavior)
            let provider = makeProvider(fake: fake)
            do {
                _ = try await provider.completeMessage(
                    AIMessage(systemPrompt: "", userMessage: "Hello"),
                    model: .ohMyPiCustom(name: "provider/model")
                )
                XCTFail("Expected missing-terminal failure")
            } catch let error as AIProviderError {
                guard case let .invalidResponse(detail) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(detail, "Oh My Pi returned no successful completion")
            }
            XCTAssertEqual(fake.disposalCount, 1)
        }
    }

    func testToolAttemptFailsClosedAndDisposesExactlyOnce() async throws {
        let disposal = expectation(description: "tool-attempt-disposal")
        let fake = OhMyPiCLIFake(behavior: .toolAttempt, onDispose: {
            disposal.fulfill()
        })
        let provider = makeProvider(fake: fake)
        do {
            _ = try await provider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "provider/model")
            )
            XCTFail("Expected the tool attempt to fail")
        } catch let error as AIProviderError {
            guard case let .invalidResponse(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, HeadlessCLIStreamBridge.toolEventRejectedDetail)
        }
        await fulfillment(of: [disposal], timeout: 1)
        await provider.dispose()
        XCTAssertEqual(fake.disposalCount, 1)
    }

    func testDirectStreamRejectsToolAndErrorEventsAndDisposesExactlyOnce() async throws {
        let eventCases: [(type: String, text: String?)] = [
            ("tool_call", nil),
            ("tool_result", nil),
            ("tool_progress", nil),
            ("error", "OMP event failure")
        ]

        for eventCase in eventCases {
            let disposal = expectation(description: "direct-event-disposal-\(eventCase.type)")
            let fake = OhMyPiCLIFake(
                behavior: .strictEvent(type: eventCase.type, text: eventCase.text),
                onDispose: { disposal.fulfill() }
            )
            let provider = makeProvider(fake: fake)
            let stream = try await provider.streamMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "provider/model")
            )

            do {
                for try await _ in stream {}
                XCTFail("Expected \(eventCase.type) to fail the direct stream")
            } catch let error as AIProviderError {
                switch eventCase.type {
                case "error":
                    guard case let .invalidConfiguration(detail) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(detail, eventCase.text)
                default:
                    guard case let .invalidResponse(detail) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(detail, HeadlessCLIStreamBridge.toolEventRejectedDetail)
                }
            }

            await fulfillment(of: [disposal], timeout: 1)
            await provider.dispose()
            XCTAssertEqual(fake.disposalCount, 1, eventCase.type)
        }
    }

    func testDirectStreamPreservesPartialTextThenFailsMissingTerminalAndDisposesExactlyOnce() async throws {
        let cases: [(behavior: OhMyPiCLIFake.Behavior, expectedText: [String])] = [
            (.partial(text: "partial"), ["partial"]),
            (.empty, [])
        ]

        for (index, testCase) in cases.enumerated() {
            let disposal = expectation(description: "direct-eof-disposal-\(index)")
            let fake = OhMyPiCLIFake(
                behavior: testCase.behavior,
                onDispose: { disposal.fulfill() }
            )
            let provider = makeProvider(fake: fake)
            let stream = try await provider.streamMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "provider/model")
            )
            var emittedText: [String] = []

            do {
                for try await result in stream {
                    if result.type == "content", let text = result.text {
                        emittedText.append(text)
                    }
                }
                XCTFail("Expected direct EOF without message_stop to fail")
            } catch let error as AIProviderError {
                guard case let .invalidResponse(detail) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(detail, "Oh My Pi returned no successful completion")
            }

            XCTAssertEqual(emittedText, testCase.expectedText)
            await fulfillment(of: [disposal], timeout: 1)
            await provider.dispose()
            XCTAssertEqual(fake.disposalCount, 1)
        }
    }

    func testDisposesExactlyOnceAcrossUpstreamErrorAndCancellation() async throws {
        let failingFake = OhMyPiCLIFake(behavior: .failure)
        let failingProvider = makeProvider(fake: failingFake)
        do {
            _ = try await failingProvider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .ohMyPiCustom(name: "provider/model")
            )
            XCTFail("Expected upstream error")
        } catch is TestFailure {}
        await failingProvider.dispose()
        XCTAssertEqual(failingFake.disposalCount, 1)

        let pendingFake = OhMyPiCLIFake(behavior: .pending)
        let pendingProvider = makeProvider(fake: pendingFake)
        let stream = try await pendingProvider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "Hello"),
            model: .ohMyPiCustom(name: "provider/model")
        )
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }
        await Task.yield()
        consumer.cancel()
        _ = await consumer.result
        await pendingProvider.dispose()
        XCTAssertEqual(pendingFake.disposalCount, 1)
    }

    private func makeProvider(fake: OhMyPiCLIFake) -> OhMyPiCLIProvider {
        OhMyPiCLIProvider(
            headlessProviderFactory: { _, _ in AnyHeadlessAgentProvider(fake) },
            modelSnapshotResolver: { Self.snapshot(rawValue: "provider/model") },
            connectionStateProvider: { true }
        )
    }

    private static func snapshot(rawValue: String) -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: rawValue,
                    displayName: rawValue,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: rawValue
        )
    }
}

private final class OhMyPiCLIRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [String] = []
    private var recordedConfig: OhMyPiAgentConfig?
    private var recordedWorkspacePath: String?

    var steps: [String] {
        lock.withLock { recordedSteps }
    }

    var config: OhMyPiAgentConfig? {
        lock.withLock { recordedConfig }
    }

    var workspacePath: String? {
        lock.withLock { recordedWorkspacePath }
    }

    func recordStep(_ step: String) {
        lock.withLock {
            recordedSteps.append(step)
        }
    }

    func recordFactory(config: OhMyPiAgentConfig, workspacePath: String?) {
        lock.withLock {
            recordedConfig = config
            recordedWorkspacePath = workspacePath
        }
    }
}

private final class OhMyPiCLIFake: HeadlessAgentProvider, @unchecked Sendable {
    enum Behavior {
        case terminal(text: String)
        case partial(text: String)
        case empty
        case failure
        case pending
        case toolAttempt
        case strictEvent(type: String, text: String?)
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private let onDispose: (() -> Void)?
    private var disposals = 0
    private var message: AgentMessage?
    private var retainedContinuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation?

    init(behavior: Behavior, onDispose: (() -> Void)? = nil) {
        self.behavior = behavior
        self.onDispose = onDispose
    }

    var disposalCount: Int {
        lock.withLock { disposals }
    }

    var lastMessage: AgentMessage? {
        lock.withLock { message }
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID _: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        lock.withLock {
            self.message = message
        }
        return AsyncThrowingStream { continuation in
            switch behavior {
            case let .terminal(text):
                continuation.yield(AIStreamResult(type: "content", text: text))
                continuation.yield(AIStreamResult(type: "message_stop", text: ""))
                continuation.finish()
            case let .partial(text):
                continuation.yield(AIStreamResult(type: "content", text: text))
                continuation.finish()
            case .empty:
                continuation.finish()
            case .failure:
                continuation.finish(throwing: OhMyPiCLIProviderTests.TestFailure.upstream)
            case .pending:
                lock.withLock {
                    retainedContinuation = continuation
                }
            case .toolAttempt:
                continuation.yield(AIStreamResult(type: "tool_call", text: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: ""))
                continuation.finish()
            case let .strictEvent(type, text):
                continuation.yield(AIStreamResult(type: type, text: text))
                continuation.yield(AIStreamResult(type: "message_stop", text: ""))
                continuation.finish()
            }
        }
    }

    func dispose() async {
        let continuation = lock.withLock { () -> AsyncThrowingStream<AIStreamResult, Error>.Continuation? in
            disposals += 1
            let continuation = retainedContinuation
            retainedContinuation = nil
            return continuation
        }
        continuation?.finish()
        onDispose?()
    }
}
