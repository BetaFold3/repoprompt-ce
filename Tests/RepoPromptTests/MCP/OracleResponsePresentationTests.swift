import MCP
@testable import RepoPromptApp
import XCTest

final class OracleResponsePresentationTests: XCTestCase {
    func testCharacterTailKeepsLastBudgetCharacters() {
        let text = String(repeating: "a", count: 100) + String(repeating: "b", count: 50)
        let tail = OracleResponsePresentation.characterTail(text, budget: 50)
        XCTAssertEqual(tail.count, 50)
        XCTAssertTrue(tail.allSatisfy { $0 == "b" })
    }

    func testCompactChatLogPartHeadTailBothAndMarker() {
        let text = String(repeating: "H", count: 40) + String(repeating: "T", count: 40)
        let head = OracleResponsePresentation.compactChatLogText(text, maxChars: 20, part: .head)
        XCTAssertTrue(head.hasPrefix(String(repeating: "H", count: 20)))
        XCTAssertTrue(head.contains("[truncated:"))
        XCTAssertTrue(head.contains("retrieve full text via ask_oracle"))

        let tail = OracleResponsePresentation.compactChatLogText(text, maxChars: 20, part: .tail)
        XCTAssertTrue(tail.contains(String(repeating: "T", count: 20)))
        XCTAssertTrue(tail.contains("[truncated:"))

        let both = OracleResponsePresentation.compactChatLogText(text, maxChars: 20, part: .both)
        XCTAssertTrue(both.contains("H"))
        XCTAssertTrue(both.contains("T"))
        XCTAssertTrue(both.contains("[truncated:"))
    }

    func testDefaultMaxCharsMatchesLegacyBudget() {
        XCTAssertEqual(OracleResponsePresentation.defaultChatLogMaxCharsPerMessage, 8000)
        XCTAssertEqual(OracleResponseMode.default, .full)
        XCTAssertEqual(OracleChatLogPart.default, .tail)
        XCTAssertEqual(OracleResponseMode.tailExcerptCharacterBudget, 2000)
    }

    func testEnforceTotalCharCeilingTrimsLaterMessagesFirst() {
        var messages: [[String: Value]] = [
            ["text": .string(String(repeating: "a", count: 30))],
            ["text": .string(String(repeating: "b", count: 30))],
            ["text": .string(String(repeating: "c", count: 30))]
        ]
        OracleResponsePresentation.enforceTotalCharCeiling(messages: &messages, maxTotalChars: 50)
        let total = messages.reduce(0) { $0 + ($1["text"]?.stringValue?.count ?? 0) }
        XCTAssertLessThanOrEqual(total, 50)
        XCTAssertEqual(messages[0]["text"]?.stringValue, String(repeating: "a", count: 30))
        XCTAssertNotEqual(messages[2]["text"]?.stringValue, String(repeating: "c", count: 30))
    }

    func testBothUsesOneAccurateMiddleMarkerAndLargerBudgetHint() {
        let text = String(repeating: "a", count: 100)
        let both = OracleResponsePresentation.compactChatLogText(
            text,
            maxChars: 20,
            part: .both
        )

        XCTAssertEqual(both.components(separatedBy: "[truncated:").count - 1, 1)
        XCTAssertTrue(both.contains("80 of 100 chars omitted"), both)
        XCTAssertTrue(both.contains("larger max_chars"), both)
        XCTAssertFalse(both.contains("narrower"), both)

        let oneCharacterBudget = OracleResponsePresentation.compactChatLogText(
            "ab",
            maxChars: 1,
            part: .both
        )
        XCTAssertTrue(
            oneCharacterBudget.contains("1 of 2 chars omitted"),
            oneCharacterBudget
        )
    }

    func testTotalCeilingReservesFullMarkerAndFlagsZeroBudgetRows() throws {
        let original = String(repeating: "x", count: 10000)
        let fullMarker = OracleResponsePresentation.truncateMarker(
            omittedCount: original.count,
            originalCount: original.count
        )
        let budget = fullMarker.count + 12
        var messages: [[String: Value]] = [["text": .string(original)]]

        OracleResponsePresentation.enforceTotalCharCeiling(
            messages: &messages,
            maxTotalChars: budget
        )

        let compacted = try XCTUnwrap(messages[0]["text"]?.stringValue)
        XCTAssertLessThanOrEqual(compacted.count, budget)
        XCTAssertTrue(compacted.hasSuffix("]"), compacted)
        XCTAssertTrue(compacted.contains("of 10000 chars omitted"), compacted)
        XCTAssertEqual(messages[0]["truncated"]?.boolValue, true)

        var zeroBudget: [[String: Value]] = [
            ["text": .string("kept")],
            ["text": .string("must be removed")]
        ]
        OracleResponsePresentation.enforceTotalCharCeiling(
            messages: &zeroBudget,
            maxTotalChars: 4
        )
        XCTAssertEqual(zeroBudget[1]["text"]?.stringValue, "")
        XCTAssertEqual(zeroBudget[1]["truncated"]?.boolValue, true)
    }

    func testApplyResponseModeTailAndNoneAutoExport() async throws {
        var full: [String: Value] = [
            "chat_id": .string("abc"),
            "response": .string(String(repeating: "x", count: 2500) + "\n## Recommendations\n- ship it")
        ]
        try await OracleResponsePresentation.applyResponseMode(to: &full, mode: .full) { _ in
            XCTFail("full mode must not export")
            return OracleExportFile(path: "/tmp/unused", instruction: "unused")
        }
        XCTAssertNotNil(full["response"])

        var tail = full
        try await OracleResponsePresentation.applyResponseMode(to: &tail, mode: .tail) { response in
            XCTAssertEqual(response?.count, full["response"]?.stringValue?.count)
            return OracleExportFile(path: "/tmp/oracle-tail.md", instruction: "read it")
        }
        XCTAssertNil(tail["response"])
        XCTAssertEqual(tail["export_path"]?.stringValue, "/tmp/oracle-tail.md")
        XCTAssertEqual(tail["oracle_export_path"]?.stringValue, "/tmp/oracle-tail.md")
        XCTAssertEqual(tail["char_count"]?.intValue, 2500 + "\n## Recommendations\n- ship it".count)
        let excerpt = try XCTUnwrap(tail["excerpt"]?.stringValue)
        XCTAssertEqual(excerpt.count, OracleResponseMode.tailExcerptCharacterBudget)
        XCTAssertTrue(excerpt.contains("## Recommendations"))

        var none = full
        try await OracleResponsePresentation.applyResponseMode(to: &none, mode: .none) { _ in
            OracleExportFile(path: "/tmp/oracle-none.md", instruction: "read it")
        }
        XCTAssertNil(none["response"])
        XCTAssertNil(none["excerpt"])
        XCTAssertEqual(none["excerpt_lines"]?.intValue, 0)
        XCTAssertEqual(none["export_path"]?.stringValue, "/tmp/oracle-none.md")
    }
}
