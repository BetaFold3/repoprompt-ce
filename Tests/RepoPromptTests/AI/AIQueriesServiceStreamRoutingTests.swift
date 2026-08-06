@testable import RepoPromptApp
import XCTest

final class AIQueriesServiceStreamRoutingTests: XCTestCase {
    func testVisibleTextBufferingExcludesStatusAndKeepsResponseText() {
        let scenarios: [(
            name: String,
            result: AIStreamResult,
            expectedText: String?
        )] = [
            (
                "Cursor session title status",
                AIStreamResult(type: "status", text: "Agent Model Files"),
                nil
            ),
            (
                "assistant content",
                AIStreamResult(type: "content", text: "OK, model check passed."),
                "OK, model check passed."
            ),
            (
                "terminal diagnostic content",
                AIStreamResult(type: "final_content", text: "Provider returned no completion."),
                "Provider returned no completion."
            ),
            (
                "provider error text",
                AIStreamResult(type: "error", text: "Provider timed out."),
                "Provider timed out."
            )
        ]

        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.name) { _ in
                XCTAssertEqual(
                    AIQueriesService.visibleTextForBuffering(from: scenario.result),
                    scenario.expectedText
                )
            }
        }
    }
}
