@testable import RepoPromptApp
import XCTest

final class AgentControlToolCardPresentationTests: XCTestCase {
    func testUltraReasoningEffortBuildsBadgeAndIsNotDuplicatedInSubtitle() throws {
        let presentation = try XCTUnwrap(AgentRunCardPresentation(resultObject: resultObject(reasoningEffort: "ultra")))

        XCTAssertEqual(presentation.reasoningBadge?.rawValue, "ultra")
        XCTAssertEqual(presentation.reasoningBadge?.displayLabel, "Ultra")
        XCTAssertFalse(presentation.subtitle?.contains("reasoning ultra") == true, presentation.subtitle ?? "")
        XCTAssertTrue(presentation.subtitle?.contains("gpt-5.6-sol-ultra") == true, presentation.subtitle ?? "")
    }

    func testRecognizedReasoningEffortBadgeNormalizesXHighAndMax() throws {
        let xhigh = try XCTUnwrap(AgentRunCardPresentation(resultObject: resultObject(reasoningEffort: "xhigh")))
        XCTAssertEqual(xhigh.reasoningBadge?.displayLabel, "XHigh")

        let max = try XCTUnwrap(AgentRunCardPresentation(resultObject: resultObject(reasoningEffort: "max")))
        XCTAssertEqual(max.reasoningBadge?.displayLabel, "Max")
    }

    func testUnknownReasoningEffortBadgeUsesReadableRawFallback() throws {
        let presentation = try XCTUnwrap(AgentRunCardPresentation(resultObject: resultObject(reasoningEffort: "provider_super")))

        XCTAssertEqual(presentation.reasoningBadge?.rawValue, "provider_super")
        XCTAssertEqual(presentation.reasoningBadge?.displayLabel, "Provider Super")
        XCTAssertFalse(presentation.subtitle?.contains("reasoning provider_super") == true, presentation.subtitle ?? "")
    }

    func testLifecycleWaitSubtitlesAreDerivedFromCallArguments() throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"

        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "start"])
            ),
            "start • wait auto"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID])
            ),
            "wait • wait auto"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID, "timeout": 600])
            ),
            "wait • wait ≤10m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID, "timeout": 0])
            ),
            "wait • poll"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID, "timeout": -5])
            ),
            "wait • poll"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "start", "detach": true, "timeout": 600])
            ),
            "start • detach"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_explore",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID])
            ),
            "wait • \(sessionID) • wait auto"
        )
    }

    func testReasoningEffortFallsBackToArgsWhenResultAgentObjectOmitsIt() throws {
        let args = try runArgs([
            "op": "start",
            "model": "gpt-5.6-sol-xhigh",
            "reasoning_effort": "xhigh"
        ])
        let presentation = try XCTUnwrap(AgentRunCardPresentation(
            resultObject: resultObject(reasoningEffort: nil),
            args: args
        ))

        XCTAssertEqual(presentation.reasoningBadge?.rawValue, "xhigh")
        XCTAssertEqual(presentation.reasoningBadge?.displayLabel, "XHigh")
        XCTAssertFalse(presentation.subtitle?.contains("reasoning xhigh") == true, presentation.subtitle ?? "")
    }

    private func resultObject(reasoningEffort: String?) -> [String: Any] {
        var agent: [String: Any] = [
            "id": "codex_exec",
            "name": "Codex",
            "model": "gpt-5.6-sol-ultra"
        ]
        if let reasoningEffort {
            agent["reasoning_effort"] = reasoningEffort
        }
        return [
            "status": "completed",
            "session": ["id": "11111111-1111-1111-1111-111111111111", "name": "Sub-agent"],
            "agent": agent,
            "assistant_text": "Done"
        ]
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func runArgs(_ object: [String: Any]) throws -> ToolArgsDTOs.AgentRunArgs {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(ToolArgsDTOs.AgentRunArgs.self, from: data)
    }
}
