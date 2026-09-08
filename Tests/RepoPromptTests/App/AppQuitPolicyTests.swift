@testable import RepoPromptApp
import XCTest

final class AppQuitPolicyTests: XCTestCase {
    func testEnabledWarningPromptsForEveryIdleNormalQuit() {
        let expected = AppQuitRequestDecision.showConfirmation(
            AppQuitConfirmation(
                title: "Quit RepoPrompt?",
                message: "Are you sure you want to quit RepoPrompt?",
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Quit"
            )
        )

        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: []
            ),
            expected
        )
    }

    func testActiveWorkAcrossWindowsOnlyEnrichesWarning() {
        let activeItems = [
            activity(id: "z-search", count: 2, singular: "active search", plural: "active searches"),
            activity(id: "a-session", count: 1, singular: "active agent session", plural: "active agent sessions"),
            activity(id: "a-session", count: 2, singular: "active agent session", plural: "active agent sessions"),
            activity(id: "mcp-active-execution", count: 1, singular: "active MCP tool execution", plural: "active MCP tool executions"),
            activity(id: "mcp-active-execution", count: 2, singular: "active MCP tool execution", plural: "active MCP tool executions"),
            activity(id: "ignored", count: 0, singular: "ignored item", plural: "ignored items")
        ]

        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: activeItems
            ),
            .showConfirmation(
                AppQuitConfirmation(
                    title: "Quit RepoPrompt?",
                    message: "Are you sure you want to quit RepoPrompt? Quitting will end 3 active agent sessions and 3 active MCP tool executions and 2 active searches.",
                    cancelButtonTitle: "Cancel",
                    confirmButtonTitle: "Quit"
                )
            )
        )
        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: false,
                suppressesConfirmation: false,
                phase: .idle,
                activeItems: activeItems
            ),
            .beginTermination
        )
    }

    func testUITestsBypassWarning() {
        XCTAssertEqual(
            AppQuitPolicy.decide(
                warningEnabled: true,
                suppressesConfirmation: true,
                phase: .idle,
                activeItems: []
            ),
            .beginTermination
        )
    }

    func testRepeatedRequestsDoNotCreateAnotherPrompt() {
        for phase in [AppQuitRequestPhase.awaitingConfirmation, .terminating] {
            XCTAssertEqual(
                AppQuitPolicy.decide(
                    warningEnabled: true,
                    suppressesConfirmation: false,
                    phase: phase,
                    activeItems: []
                ),
                .awaitCurrentRequest
            )
        }
    }

    private func activity(
        id: String,
        count: Int,
        singular: String,
        plural: String
    ) -> WindowCloseActivityItem {
        WindowCloseActivityItem(
            id: id,
            count: count,
            singularLabel: singular,
            pluralLabel: plural
        )
    }
}
