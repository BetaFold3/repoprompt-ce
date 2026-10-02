@testable import RepoPromptApp
import XCTest

final class AgentRunningStatusPresentationTests: XCTestCase {
    func testCanonicalRawToolsUseExistingDisplayNames() {
        let cases = [
            ("mcp__RepoPromptCE__agent_run", "Agent Run"),
            ("agent_run", "Agent Run"),
            ("mcp__RepoPromptCE__read_file", "Read File"),
            ("mcp__RepoPromptCE__ask_user", "Question")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), expected, raw)
        }
    }

    func testOrdinaryStatusProseAndNilFallbackRemainUnchanged() {
        let cases: [(String?, String)] = [
            (nil, "Thinking…"),
            ("Thinking…", "Thinking…"),
            ("Reviewing the implementation", "Reviewing the implementation"),
            ("Running mcp__RepoPromptCE__agent_run", "Running mcp__RepoPromptCE__agent_run"),
            ("  Thinking deeply… \n", "  Thinking deeply… \n"),
            ("", "")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), expected)
        }
    }

    func testUnsupportedPrefixesUnknownSuffixesAndLookalikesStayUnrecognized() {
        let names = [
            "mcp_RepoPromptCE_agent_run",
            "mcp__RepoPromptCE__unknown_tool",
            "mcp__RepoPromptCEExtra__agent_run",
            "mcp__OtherRepoPromptCE__agent_run",
            "mcp_RepoPromptCEExtra_agent_run",
            "mcp__RepoPromptCE__agent_runner"
        ]
        for raw in names {
            XCTAssertNil(MCPIntegrationHelper.canonicalRepoPromptToolName(raw), raw)
            XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(raw), raw)
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), raw, raw)
        }
    }
}
