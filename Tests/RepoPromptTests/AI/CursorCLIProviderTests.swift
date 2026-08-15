@testable import RepoPromptApp
import XCTest

final class CursorCLIProviderTests: XCTestCase {
    func testCompletionStillAcceptsNonemptyTextWithoutMessageStopAndUsesPromptOnlyConfig() async throws {
        let recorder = CursorCLIProviderRecorder()
        let fake = CursorCLIProviderFake(
            results: [AIStreamResult(type: "content", text: "cursor text")],
            finishes: true
        )
        let provider = CursorCLIProvider { config, workspacePath in
            recorder.record(config: config, workspacePath: workspacePath)
            return AnyHeadlessAgentProvider(fake)
        }

        let result = try await provider.completeMessage(
            AIMessage(systemPrompt: "System", userMessage: "Hello"),
            model: .cursorCustom(name: "gpt-5.6-sol")
        )

        XCTAssertEqual(result.text, "cursor text")
        XCTAssertEqual(recorder.config?.modelString, "gpt-5.6-sol")
        XCTAssertEqual(recorder.config?.includeRepoPromptMCPServer, false)
        XCTAssertEqual(recorder.config?.sessionModeID, CursorAgentConfig.promptOnlySessionModeID)
        XCTAssertNil(recorder.workspacePath)
        XCTAssertEqual(fake.disposalCount, 1)

        await provider.dispose()
        XCTAssertEqual(fake.disposalCount, 1)

        let emptyProvider = CursorCLIProvider { _, _ in
            AnyHeadlessAgentProvider(CursorCLIProviderFake(results: [], finishes: true))
        }
        do {
            _ = try await emptyProvider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello"),
                model: .cursorCustom(name: "gpt-5.6-sol")
            )
            XCTFail("Expected Cursor's established empty-completion failure")
        } catch let error as AIProviderError {
            guard case let .invalidResponse(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, "Cursor returned no completion")
        }
    }
}

private final class CursorCLIProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var config: CursorAgentConfig?
    private(set) var workspacePath: String?

    func record(config: CursorAgentConfig, workspacePath: String?) {
        lock.lock()
        self.config = config
        self.workspacePath = workspacePath
        lock.unlock()
    }
}

private final class CursorCLIProviderFake: HeadlessAgentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [AIStreamResult]
    private let finishes: Bool
    private var disposals = 0

    init(results: [AIStreamResult], finishes: Bool) {
        self.results = results
        self.finishes = finishes
    }

    var disposalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disposals
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            for result in results {
                continuation.yield(result)
            }
            if finishes {
                continuation.finish()
            }
        }
    }

    func dispose() async {
        lock.lock()
        disposals += 1
        lock.unlock()
    }
}
