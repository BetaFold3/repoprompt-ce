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

    func testRemovingStripsOnlyTheNamedNoticesAndDropsTheKeyWhenEmpty() throws {
        let original: Value = .object(["status": .string("pending"), "content": .string("body")])
        let first = payload(name: "First child")
        let second = payload(name: "Second child")
        let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([first, second], to: original))

        let withoutFirst = AgentDelegatedQuestionNoticeWire.removing([first.key], from: attached)
        XCTAssertEqual(withoutFirst.objectValue?[AgentDelegatedQuestionNoticeWire.resultKey]?.arrayValue, [second.wireValue()])
        XCTAssertEqual(AgentDelegatedQuestionNoticeWire.splitting(withoutFirst).original, original)

        XCTAssertEqual(AgentDelegatedQuestionNoticeWire.removing([first.key, second.key], from: attached), original)
        XCTAssertEqual(
            AgentDelegatedQuestionNoticeWire.removing([.init(childSessionID: UUID(), interactionID: UUID())], from: attached),
            attached,
            "Unknown keys change nothing"
        )
        XCTAssertEqual(AgentDelegatedQuestionNoticeWire.removing([], from: attached), attached)
        for nonObject: Value in [.string("text"), .array([.int(1)]), .null] {
            XCTAssertEqual(AgentDelegatedQuestionNoticeWire.removing([first.key], from: nonObject), nonObject)
        }
        XCTAssertEqual(AgentDelegatedQuestionNoticeWire.noticeKey(of: first.wireValue()), first.key)
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.noticeKey(of: .object(["child_session_id": .string("nope")])))
    }

    func testRenderedTextForKeysMatchesTheFormattedNoticeBlockOfThoseEntriesOnly() throws {
        let original: Value = .object(["content": .string("body")])
        let first = payload(name: "First child")
        let second = payload(name: "Second child")
        let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([first, second], to: original))

        // Recording only the committed entries matches the notice block the formatter returns.
        let both = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.renderedText(for: [first.key, second.key], in: attached))
        XCTAssertEqual(both, AgentDelegatedQuestionNoticeWire.splitting(attached).noticeText)
        XCTAssertEqual(both, AgentDelegatedQuestionNoticeWire.renderedText(for: [first, second]))
        XCTAssertEqual(
            AgentDelegatedQuestionNoticeWire.renderedText(for: [second.key], in: attached),
            AgentDelegatedQuestionNoticeWire.renderedText(for: [second])
        )
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.renderedText(for: [], in: attached))
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.renderedText(for: [.init(childSessionID: UUID(), interactionID: UUID())], in: attached))
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.renderedText(for: [first.key], in: original))
        XCTAssertNil(AgentDelegatedQuestionNoticeWire.renderedText(for: [first.key], in: .string("text")))
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
