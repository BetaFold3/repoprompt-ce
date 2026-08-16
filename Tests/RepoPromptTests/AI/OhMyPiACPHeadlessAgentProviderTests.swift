@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class OhMyPiACPHeadlessAgentProviderTests: XCTestCase {
    private enum TestFailure: Error {
        case setModel
    }

    func testMCPDisabledAppliesValidatedCanonicalModelWithoutRegistryReread() async throws {
        let canonicalModel = "Cursor/GPT:Fast"
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        defer {
            AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        }
        let modelRecorder = OMPModelSetterRecorder()

        try await OhMyPiACPHeadlessAgentProvider.prepareForPrompt(
            config: OhMyPiAgentConfig(
                modelString: canonicalModel,
                includeRepoPromptMCPServer: false
            ),
            runID: UUID(),
            setSelection: { model, options in
                XCTAssertTrue(options.isEmpty)
                await modelRecorder.record(model)
            },
            routeCheck: { _ in
                XCTFail("MCP-disabled requests must not check routing")
                return false
            }
        )

        let appliedModels = await modelRecorder.models
        XCTAssertEqual(appliedModels, [canonicalModel])

        do {
            try await OhMyPiACPHeadlessAgentProvider.prepareForPrompt(
                config: OhMyPiAgentConfig(
                    modelString: canonicalModel,
                    includeRepoPromptMCPServer: false
                ),
                runID: UUID(),
                setSelection: { model, options in
                    XCTAssertEqual(model, canonicalModel)
                    XCTAssertTrue(options.isEmpty)
                    throw TestFailure.setModel
                },
                routeCheck: { _ in
                    XCTFail("Model failure must occur before any MCP-disabled route check")
                    return false
                }
            )
            XCTFail("Expected setSessionModel failure")
        } catch TestFailure.setModel {
            // Preserve the exact controller failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRouteCheckIsSkippedWhenRepoPromptMCPIsDisabled() async throws {
        let recorder = OMPRouteCheckRecorder(result: false)
        try await OhMyPiACPHeadlessAgentProvider.prepareForPrompt(
            config: OhMyPiAgentConfig(includeRepoPromptMCPServer: false),
            runID: UUID(),
            setSelection: { _, _ in XCTFail("No model should be applied") },
            routeCheck: { runID in await recorder.check(runID) }
        )
        let invocationCount = await recorder.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testRouteCheckIsInvokedWhenRepoPromptMCPIsEnabled() async throws {
        let recorder = OMPRouteCheckRecorder(result: true)
        let runID = UUID()
        try await OhMyPiACPHeadlessAgentProvider.prepareForPrompt(
            config: OhMyPiAgentConfig(includeRepoPromptMCPServer: true),
            runID: runID,
            setSelection: { _, _ in XCTFail("No model should be applied") },
            routeCheck: { checkedRunID in await recorder.check(checkedRunID) }
        )
        let invocationCount = await recorder.invocationCount
        let checkedRunID = await recorder.lastRunID
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(checkedRunID, runID)
    }

    func testRouteCheckFailureStillThrowsAfterExactlyOneInvocation() async throws {
        let recorder = OMPRouteCheckRecorder(result: false)
        do {
            try await OhMyPiACPHeadlessAgentProvider.prepareForPrompt(
                config: OhMyPiAgentConfig(includeRepoPromptMCPServer: true),
                runID: UUID(),
                setSelection: { _, _ in XCTFail("No model should be applied") },
                routeCheck: { checkedRunID in await recorder.check(checkedRunID) }
            )
            XCTFail("Expected the existing route failure")
        } catch let error as AIProviderError {
            guard case let .invalidConfiguration(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, "Oh My Pi MCP routing did not complete before prompt dispatch.")
        }
        let invocationCount = await recorder.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }
}

private actor OMPModelSetterRecorder {
    private(set) var models: [String] = []

    func record(_ model: String) {
        models.append(model)
    }
}

private actor OMPRouteCheckRecorder {
    let result: Bool
    private(set) var invocationCount = 0
    private(set) var lastRunID: UUID?

    init(result: Bool) {
        self.result = result
    }

    func check(_ runID: UUID) -> Bool {
        invocationCount += 1
        lastRunID = runID
        return result
    }
}
