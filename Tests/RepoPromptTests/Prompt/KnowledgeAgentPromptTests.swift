@testable import RepoPromptApp
import XCTest

final class KnowledgeAgentPromptTests: XCTestCase {
    func testKnowledgePromptUsesFocusedWorkspaceAndOracleSurface() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )

        for tool in [
            "get_file_tree",
            "file_search",
            "read_file",
            "apply_edits",
            "oracle_utils",
            "ask_oracle",
            "oracle_chat_log"
        ] {
            XCTAssertTrue(prompt.contains("`\(tool)`"), tool)
        }
        for forbidden in ["`git`", "`bash`", "`agent_run`", "`agent_explore`", "`context_builder`"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertFalse(prompt.contains("packet_context_clean"))
        XCTAssertFalse(prompt.contains("model_preset_id"))
        XCTAssertTrue(prompt.contains("Default to zero critique rounds"))
        XCTAssertTrue(prompt.contains("Judge the evidence"))
    }

    func testKnowledgePromptKeepsProviderMediaClaimsTruthful() {
        let claude = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )
        XCTAssertTrue(claude.contains("provider-native `Read` tool"))
        XCTAssertTrue(claude.contains("PDFs"))

        let codex = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            sessionProfile: .knowledge
        )
        XCTAssertTrue(codex.contains("native `view_image`"))
        XCTAssertTrue(codex.contains("Do not claim native PDF support"))
        XCTAssertFalse(codex.contains("provider-native `Read` tool"))
    }

    func testKnowledgePromptIsStableForEachProvider() {
        for provider in [AgentProviderKind.claudeCode, .codexExec] {
            XCTAssertEqual(
                SystemPromptService.agentModePrompt(agentKind: provider, sessionProfile: .knowledge),
                SystemPromptService.agentModePrompt(agentKind: provider, sessionProfile: .knowledge)
            )
        }
    }

    func testStandardPromptDoesNotAdoptKnowledgeIdentity() {
        let standard = SystemPromptService.agentModePrompt(agentKind: .claudeCode)
        let knowledge = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )

        XCTAssertFalse(standard.contains("RepoPrompt's Knowledge agent"))
        XCTAssertTrue(knowledge.contains("RepoPrompt's Knowledge agent"))
        XCTAssertNotEqual(standard, knowledge)
    }
}
