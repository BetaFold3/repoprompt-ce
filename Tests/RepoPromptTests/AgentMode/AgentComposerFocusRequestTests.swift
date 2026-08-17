import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerFocusRequestTests: XCTestCase {
    func testRequestFocusPublishesRequest() {
        let store = AgentComposerUIStore()
        let request = AgentComposerFocusRequest(
            id: UUID(),
            tabID: UUID(),
            reason: .newSession
        )

        store.requestFocus(request)

        XCTAssertEqual(store.focusRequest, request)
    }

    func testMatchingConsumeClearsRequest() {
        let store = AgentComposerUIStore()
        let request = AgentComposerFocusRequest(
            id: UUID(),
            tabID: UUID(),
            reason: .newKnowledgeSession
        )
        store.requestFocus(request)

        store.consumeFocusRequest(id: request.id)

        XCTAssertNil(store.focusRequest)
    }

    func testStaleConsumeLeavesRequestPending() {
        let store = AgentComposerUIStore()
        let request = AgentComposerFocusRequest(
            id: UUID(),
            tabID: UUID(),
            reason: .reusedPlaceholder
        )
        store.requestFocus(request)

        store.consumeFocusRequest(id: UUID())

        XCTAssertEqual(store.focusRequest, request)
    }

    func testNewerRequestSupersedesOlderRequest() {
        let store = AgentComposerUIStore()
        let olderRequest = AgentComposerFocusRequest(
            id: UUID(),
            tabID: UUID(),
            reason: .newSession
        )
        let newerRequest = AgentComposerFocusRequest(
            id: UUID(),
            tabID: UUID(),
            reason: .newKnowledgeSession
        )

        store.requestFocus(olderRequest)
        store.requestFocus(newerRequest)

        XCTAssertEqual(store.focusRequest, newerRequest)
    }
}
