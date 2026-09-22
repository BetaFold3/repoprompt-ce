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

    func testLifecycleCallSubtitlesUsePreCompletionContextAndCanonicalCompletionPolicy() throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let codexContext = AgentControlToolCardContext(authoritativeLocalParentFamily: .codex)
        let claudeContext = AgentControlToolCardContext(authoritativeLocalParentFamily: .claude)
        let otherContext = AgentControlToolCardContext(authoritativeLocalParentFamily: .other)
        let unresolvedContext = AgentControlToolCardContext(authoritativeLocalParentFamily: nil)

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
                argsJSON: jsonString(["op": "start", "model": "requested-worker-model"]),
                agentControlContext: codexContext
            ),
            "start • requested-worker-model • wait ≤10m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID]),
                agentControlContext: claudeContext
            ),
            "wait • wait ≤3m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_explore",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID]),
                agentControlContext: otherContext
            ),
            "wait • \(sessionID) • wait ≤3m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID]),
                agentControlContext: unresolvedContext
            ),
            "wait • wait auto"
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

        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString([
                    "op": "start",
                    "model": "requested-worker-model",
                    "timeout": 600
                ]),
                resultJSON: jsonString([
                    "status": "completed",
                    "wait_policy": [
                        "mode": "automatic",
                        "timeout_seconds": 300,
                        "parent_family": "claude"
                    ]
                ]),
                agentControlContext: codexContext
            ),
            "start • requested-worker-model • wait ≤5m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString([
                    "op": "start",
                    "model": "requested-worker-model"
                ]),
                resultJSON: jsonString(["status": "completed"]),
                agentControlContext: codexContext
            ),
            "start • requested-worker-model"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_explore",
                argsJSON: jsonString(["op": "wait", "session_id": sessionID]),
                resultJSON: jsonString([
                    "status": "completed",
                    "wait_policy": [
                        "mode": "automatic",
                        "timeout_seconds": 180,
                        "parent_family": "legacy-unknown"
                    ]
                ]),
                agentControlContext: codexContext
            ),
            "wait • \(sessionID)"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "agent_run",
                argsJSON: jsonString(["op": "start", "detach": true, "timeout": 600]),
                resultJSON: jsonString(["status": "running"]),
                agentControlContext: codexContext
            ),
            "start • detach"
        )
        for isError in [false, true] {
            try XCTAssertEqual(
                ToolCardRouter.callSubtitle(
                    for: "agent_run",
                    argsJSON: jsonString([
                        "op": "start",
                        "model": "requested-worker-model"
                    ]),
                    toolIsError: isError,
                    agentControlContext: codexContext
                ),
                "start • requested-worker-model",
                "toolIsError=\(isError)"
            )
        }
    }

    func testAskOracleSubtitlesUseParentFamilyAndCanonicalResultWaitLabels() throws {
        let operationID = "11111111-1111-1111-1111-111111111111"
        let codexContext = AgentControlToolCardContext(authoritativeLocalParentFamily: .codex)
        let claudeContext = AgentControlToolCardContext(authoritativeLocalParentFamily: .claude)

        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["message": "question", "mode": "plan"]),
                agentControlContext: codexContext
            ),
            "plan • wait ≤10m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["op": "wait", "operation_ids": [operationID]]),
                agentControlContext: claudeContext
            ),
            "wait • \(operationID) • wait ≤3m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString([
                    "op": "wait",
                    "operation_ids": [operationID, "22222222-2222-2222-2222-222222222222"],
                    "timeout_seconds": 0
                ])
            ),
            "wait • 2 operations • poll"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["op": "cancel", "operation_ids": [operationID]]),
                agentControlContext: codexContext
            ),
            "cancel • \(operationID)"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString([
                    "message": "question",
                    "mode": "review",
                    "timeout_seconds": 600
                ]),
                resultJSON: jsonString([
                    "status": "completed",
                    "wait_policy": [
                        "mode": "automatic",
                        "timeout_seconds": 180,
                        "parent_family": "claude"
                    ]
                ]),
                agentControlContext: codexContext
            ),
            "review • wait ≤3m"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["message": "question", "mode": "review"]),
                resultJSON: jsonString(["status": "completed"]),
                agentControlContext: codexContext
            ),
            "review"
        )
        try XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["consultations": [["message": "one"], ["message": "two"]]]),
                agentControlContext: codexContext
            ),
            "wait ≤10m"
        )
    }

    func testLifecycleResultSubtitlesUseCanonicalWaitPolicy() {
        var automaticResult = resultObject(reasoningEffort: nil)
        automaticResult["wait_policy"] = [
            "mode": "automatic",
            "timeout_seconds": 420,
            "parent_family": "codex"
        ]
        XCTAssertEqual(
            AgentRunCardPresentation(resultObject: automaticResult)?.waitLabel,
            "wait ≤7m"
        )

        var explicitResult = resultObject(reasoningEffort: nil)
        explicitResult["wait_policy"] = ["mode": "explicit", "timeout_seconds": 90]
        XCTAssertEqual(AgentRunCardPresentation(resultObject: explicitResult)?.waitLabel, "wait ≤90s")

        var pollResult = resultObject(reasoningEffort: nil)
        pollResult["wait_policy"] = ["mode": "poll", "timeout_seconds": 0]
        XCTAssertEqual(AgentRunCardPresentation(resultObject: pollResult)?.waitLabel, "poll")
        XCTAssertNil(AgentRunCardPresentation(resultObject: resultObject(reasoningEffort: nil))?.waitLabel)

        var malformedResult = resultObject(reasoningEffort: nil)
        malformedResult["wait_policy"] = [
            "mode": "automatic",
            "timeout_seconds": 180,
            "parent_family": "legacy-unknown"
        ]
        XCTAssertNil(AgentRunCardPresentation(resultObject: malformedResult)?.waitLabel)
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
