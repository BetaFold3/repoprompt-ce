@testable import RepoPromptApp
import XCTest

/// Oracle fresh-chat plan A3: every Agent Mode prompt family that recommends fresh Oracle
/// lanes carries the one shared fresh-chat contract, and named-Oracle guidance no longer
/// demands a discovery call when exact preset identity is already known.
final class OracleFreshChatGuidanceTests: XCTestCase {
    private static let freshChatContract = [
        "**Fresh Oracle chats**",
        "Every fresh chat (`new_chat:true`) carries an explicit `model` preset.",
        "including one listed by an `oracle_model_required` rejection",
        "only when a preset's identity is missing, ambiguous, or stale",
        "never selects a model",
        "`selection_mode:\"none\"` or `selection_mode:\"explicit_slices\"` with `slices`",
        "Neither packages the automatic review diff"
    ]

    func testFreshOracleRecommendingPromptFamiliesCarrySharedContractOnce() {
        let roles: [AgentModelCatalog.TaskLabelKind?] = [nil, .engineer, .pair, .design]
        for agentKind in [AgentProviderKind.claudeCode, .codexExec] {
            for role in roles {
                let label = "\(agentKind) \(role.map { "\($0)" } ?? "default")"
                let prompt = SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: role)
                XCTAssertEqual(
                    prompt.components(separatedBy: "**Fresh Oracle chats**").count - 1,
                    1,
                    "\(label): the shared fragment appears exactly once"
                )
                for sentence in Self.freshChatContract {
                    XCTAssertTrue(prompt.contains(sentence), "\(label) missing: \(sentence)")
                }
                // Named-Oracle guidance keeps its identity safeguards but reuses known UUIDs.
                XCTAssertTrue(
                    prompt.contains("unless this session already holds that preset's exact UUID"),
                    label
                )
                XCTAssertFalse(prompt.contains("First call `oracle_utils`"), label)
                XCTAssertFalse(
                    prompt.contains("First call `mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__oracle_utils`"),
                    label
                )
                XCTAssertTrue(prompt.contains("do not synthesize the answers"), label)
            }
        }
    }

    func testIndependentReviewSentenceRequiresExplicitModelOnFreshChat() {
        for agentKind in [AgentProviderKind.claudeCode, .codexExec] {
            let prompt = SystemPromptService.agentModePrompt(agentKind: agentKind)
            XCTAssertTrue(
                prompt.contains(
                    "mode:\"review\" in a fresh chat (`new_chat:true` plus an explicit `model`; review independence outweighs the continuity default)"
                ),
                "\(agentKind)"
            )
        }
    }

    func testKnowledgeAskOracleDescriptionStatesFreshChatModelRule() {
        XCTAssertTrue(
            AgentModeMCPToolPolicy.knowledgeAskOracleDescription.contains(
                "A fresh chat needs an explicit model when more than one preset supports the mode; the rejection lists the exact preset UUIDs to retry with."
            )
        )
    }
}
