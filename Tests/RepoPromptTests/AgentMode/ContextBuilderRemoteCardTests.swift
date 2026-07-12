@testable import RepoPromptApp
import XCTest

final class ContextBuilderRemoteCardTests: XCTestCase {
    func testRemoteCallCardPhaseUsesResultPresenceOnly() {
        let resultless = AgentChatItem.toolCall(name: "context_builder", argsJSON: nil)
        XCTAssertEqual(ContextBuilderCallCard.remoteCallCardPhase(for: resultless), .running)

        var withResult = resultless
        withResult.toolResultJSON = AgentToolResultPersistencePolicy.minimalResultJSON(
            statusWord: "success",
            normalizedToolName: "context_builder"
        )
        XCTAssertEqual(ContextBuilderCallCard.remoteCallCardPhase(for: withResult), .completed)

        var withErrorFlag = resultless
        withErrorFlag.toolIsError = true
        XCTAssertEqual(ContextBuilderCallCard.remoteCallCardPhase(for: withErrorFlag), .completed)
    }

    func testDetailLineOmitsRemoteModelAndPreservesLocalFormatting() {
        XCTAssertNil(contextBuilderCardDetailLine(
            isRemoteSession: true,
            runModelDisplayName: "GPT 5.5 medium",
            mcpResponseType: "plan",
            mcpPlanModel: "GLM 5.2"
        ))

        XCTAssertEqual(
            contextBuilderCardDetailLine(
                isRemoteSession: false,
                runModelDisplayName: "GPT 5.5 medium",
                mcpResponseType: nil,
                mcpPlanModel: nil
            ),
            "Context Builder: GPT 5.5 medium"
        )
        XCTAssertEqual(
            contextBuilderCardDetailLine(
                isRemoteSession: false,
                runModelDisplayName: "GPT 5.5 medium",
                mcpResponseType: "plan",
                mcpPlanModel: "GLM 5.2"
            ),
            "Context Builder: GPT 5.5 medium → plan: GLM 5.2"
        )
    }
}
