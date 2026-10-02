import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class ToolOutputFormatterDelegatedQuestionNoticeTests: XCTestCase {
    func testAttachSplitRoundTripPreservesOriginalAndCombinesNotices() throws {
        let original: Value = .object(["status": .string("pending"), "ok": .bool(false), "is_error": .bool(true)])
        let first = payload(name: "First child")
        let second = payload(name: "Second child")
        let once = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([first], to: original))
        let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([second], to: once))
        let split = AgentDelegatedQuestionNoticeWire.splitting(attached)
        XCTAssertEqual(split.original, original)
        XCTAssertEqual(split.noticeText, first.renderedText + "\n\n" + second.renderedText)
        XCTAssertEqual(attached.objectValue?[AgentDelegatedQuestionNoticeWire.resultKey]?.arrayValue, [first.wireValue(), second.wireValue()])
        XCTAssertEqual(split.original.objectValue?["is_error"], .bool(true))
        XCTAssertEqual(split.original.objectValue?["ok"], .bool(false))
    }

    func testOriginalContentBlocksUnchangedWithOneAppendedNoticeIncludingRawJSON() throws {
        let notice = payload(name: "Child")
        let original: Value = .object([
            "status": .string("pending"),
            "operation_id": .string(UUID().uuidString),
            "pending": .object(["reason": .string("timed_out"), "stream_state": .string("streaming")]),
            "content": .string("Original tool body")
        ])
        let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([notice], to: original))
        for toolName in ["ask_oracle", "read_file", "agent_run", "generic"] {
            for rawJSON in [false, true] {
                for resources in [false, true] {
                    let args: [String: Value] = ["_rawJSON": .bool(rawJSON)]
                    let originalBlocks = ToolOutputFormatter.buildContentBlocks(
                        toolName: toolName, args: args, result: original, emitResources: resources
                    )
                    let blocks = ToolOutputFormatter.buildContentBlocks(
                        toolName: toolName, args: args, result: attached, emitResources: resources
                    )
                    XCTAssertEqual(blocks.count, originalBlocks.count + 1)
                    XCTAssertEqual(try encoded(Array(blocks.dropLast())), try encoded(originalBlocks))
                    let last = try XCTUnwrap(blocks.last)
                    guard case let .text(text, _, _) = last else {
                        XCTFail("Expected appended text notice")
                        continue
                    }
                    XCTAssertEqual(text, notice.renderedText)
                    XCTAssertTrue(text.contains(notice.key.childSessionID.uuidString))
                    XCTAssertTrue(text.contains(notice.key.interactionID.uuidString))
                    if rawJSON {
                        guard case let .text(json, _, _) = blocks[0] else {
                            XCTFail("Expected unchanged raw JSON block")
                            continue
                        }
                        XCTAssertEqual(json, ToolOutputFormatter.rawJSONString(original))
                    }
                }
            }
        }
    }

    func testEmptyAttachmentAndNonObjectPassthrough() {
        let notice = payload(name: "Child")
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.attaching([], to: .object([:])))
        let originals: [Value] = [.string("text"), .array([.int(1)]), .null, .bool(false)]
        for original in originals {
            XCTAssertNil(AgentDelegatedQuestionNoticeWire.attaching([notice], to: original))
            let split = AgentDelegatedQuestionNoticeWire.splitting(original)
            XCTAssertEqual(split.original, original)
            XCTAssertNil(split.noticeText)
        }
        let original: Value = .object(["ok": .bool(true)])
        let split = AgentDelegatedQuestionNoticeWire.splitting(original)
        XCTAssertEqual(split.original, original)
        XCTAssertNil(split.noticeText)
    }

    private func encoded(_ blocks: [MCP.Tool.Content]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blocks)
    }

    private func payload(name: String) -> AgentDelegatedQuestionNoticePayload {
        AgentDelegatedQuestionNoticePayload(
            key: .init(childSessionID: UUID(), interactionID: UUID()),
            childSessionName: name, title: "Choose a path", context: "Need a decision",
            questions: [.init(
                id: "path", header: "Path", question: "Which implementation?", context: "Two choices",
                options: [.init(label: "A", description: "Small"), .init(label: "B", description: nil)],
                allowsMultiple: false, allowsCustom: true
            )]
        )
    }
}
