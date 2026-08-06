import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCodeProviderUsageTests: XCTestCase {
    func testCompletionPayloadReportsCacheInclusiveInputAcrossTypedFallbackAndBoundaries() throws {
        let provider = try ClaudeCodeProvider()
        let cases: [(name: String, json: String, promptTokens: Int, outputTokens: Int, cost: Double)] = [
            (
                "typed result",
                """
                {
                  "type": "result",
                  "subtype": "success",
                  "total_cost_usd": 1.25,
                  "duration_ms": 10,
                  "duration_api_ms": 8,
                  "is_error": false,
                  "num_turns": 1,
                  "result": "typed",
                  "session_id": "typed-session",
                  "usage": {
                    "input_tokens": 3,
                    "cache_creation_input_tokens": 200,
                    "cache_read_input_tokens": 1000,
                    "output_tokens": 50,
                    "server_tool_use": { "web_search_requests": 0 }
                  }
                }
                """,
                1203,
                50,
                1.25
            ),
            (
                "fallback snake case",
                """
                {
                  "type": "result",
                  "total_cost_usd": 1.5,
                  "result": "fallback-snake",
                  "usage": {
                    "input_tokens": 4,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 100,
                    "output_tokens": 51
                  }
                }
                """,
                124,
                51,
                1.5
            ),
            (
                "fallback camel case",
                """
                {
                  "type": "result",
                  "total_cost_usd": 1.75,
                  "result": "fallback-camel",
                  "usage": {
                    "inputTokens": 5,
                    "cacheCreationInputTokens": 30,
                    "cacheReadInputTokens": 200,
                    "outputTokens": 52
                  }
                }
                """,
                235,
                52,
                1.75
            ),
            (
                "negative components",
                """
                {
                  "type": "result",
                  "total_cost_usd": 2.0,
                  "result": "negative",
                  "usage": {
                    "input_tokens": -4,
                    "cache_creation_input_tokens": -3,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 53
                  }
                }
                """,
                10,
                53,
                2.0
            ),
            (
                "overflow saturation",
                """
                {
                  "type": "result",
                  "total_cost_usd": 2.25,
                  "result": "overflow",
                  "usage": {
                    "input_tokens": \(Int.max),
                    "cache_creation_input_tokens": 1,
                    "cache_read_input_tokens": 1,
                    "output_tokens": 54
                  }
                }
                """,
                Int.max,
                54,
                2.25
            ),
            (
                "out-of-range numeric cache field",
                """
                {
                  "type": "result",
                  "total_cost_usd": 2.5,
                  "result": "out-of-range",
                  "usage": {
                    "input_tokens": 1,
                    "cache_read_input_tokens": 1e100,
                    "output_tokens": 55
                  }
                }
                """,
                Int.max,
                55,
                2.5
            ),
            (
                "missing cache fields",
                """
                {
                  "type": "result",
                  "total_cost_usd": 2.5,
                  "result": "uncached",
                  "usage": {
                    "input_tokens": 9,
                    "output_tokens": 55
                  }
                }
                """,
                9,
                55,
                2.5
            )
        ]

        for testCase in cases {
            try XCTContext.runActivity(named: testCase.name) { _ in
                let completion = try provider.parseCompletionPayload(Data(testCase.json.utf8))
                XCTAssertEqual(completion.promptTokens, testCase.promptTokens)
                XCTAssertEqual(completion.completionTokens, testCase.outputTokens)
                XCTAssertEqual(completion.cost, testCase.cost)
                XCTAssertFalse(completion.text.isEmpty)
            }
        }
    }
}
