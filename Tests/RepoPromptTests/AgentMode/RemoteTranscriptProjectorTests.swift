@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteTranscriptProjectorTests: XCTestCase {
    func testEmptyTranscriptWrapperProducesNoItems() {
        XCTAssertTrue(project(xml: "<transcript></transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript>\n  </transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript/>").isEmpty)
    }

    func testUnparsedTranscriptWrapperPreservesStrippedContentAsSystemItem() throws {
        let items = project(xml: "<transcript>unparsed text</transcript>")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "unparsed text")
    }

    func testBareGarbagePreservesContentAsSystemItem() throws {
        let items = project(xml: "hello")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "hello")
    }

    func testNormalUserAndAssistantTagsStillParse() {
        let items = project(xml: "<transcript><user>Hello</user><assistant>Hi there</assistant></transcript>")

        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["Hello", "Hi there"])
    }

    private func project(xml: String) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-test")
            .projectGetLogResponse(.object([
                "turn_offset": .int(0),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ]))
            .items
    }
}
