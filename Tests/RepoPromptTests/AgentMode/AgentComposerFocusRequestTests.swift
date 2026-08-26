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

        let oldTabID = UUID()
        let newTabID = UUID()
        let coalescedRequest = AgentComposerFocusRequest(
            id: UUID(),
            tabID: newTabID,
            reason: .newSession
        )
        let oldCue = AgentComposerFocusObservationCue(tabID: oldTabID, request: nil)
        let newCue = AgentComposerFocusObservationCue(tabID: newTabID, request: coalescedRequest)
        let tabChanged = AgentComposerFocusObservationCue.tabChanged(from: oldCue, to: newCue)
        var composerFocusToken: UUID? = UUID()
        if tabChanged {
            composerFocusToken = nil
        }
        let tokenWasClearedBeforeApply = composerFocusToken == nil
        store.requestFocus(coalescedRequest)
        switch newCue.requestAction(discardMismatch: tabChanged) {
        case let .applyAndConsume(requestID):
            composerFocusToken = requestID
            store.consumeFocusRequest(id: requestID)
        case .none, .leavePending, .discard:
            XCTFail("Expected coalesced matching request to apply and consume")
        }

        XCTAssertTrue(tabChanged)
        XCTAssertTrue(tokenWasClearedBeforeApply)
        XCTAssertEqual(composerFocusToken, coalescedRequest.id)
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

        let currentTabID = UUID()
        let requestOnlyOldCue = AgentComposerFocusObservationCue(tabID: currentTabID, request: nil)
        let requestOnlyNewCue = AgentComposerFocusObservationCue(tabID: currentTabID, request: request)
        let requestOnlyTabChanged = AgentComposerFocusObservationCue.tabChanged(
            from: requestOnlyOldCue,
            to: requestOnlyNewCue
        )

        XCTAssertFalse(requestOnlyTabChanged)
        XCTAssertEqual(
            requestOnlyNewCue.requestAction(discardMismatch: requestOnlyTabChanged),
            .leavePending
        )
        XCTAssertEqual(store.focusRequest, request)

        let destinationTabID = UUID()
        let tabChangeCue = AgentComposerFocusObservationCue(tabID: destinationTabID, request: request)
        let tabChanged = AgentComposerFocusObservationCue.tabChanged(
            from: requestOnlyNewCue,
            to: tabChangeCue
        )
        var composerFocusToken: UUID? = UUID()
        if tabChanged {
            composerFocusToken = nil
        }
        switch tabChangeCue.requestAction(discardMismatch: tabChanged) {
        case let .discard(requestID):
            store.consumeFocusRequest(id: requestID)
        case .none, .applyAndConsume, .leavePending:
            XCTFail("Expected tab-change mismatch to discard")
        }

        XCTAssertTrue(tabChanged)
        XCTAssertNil(composerFocusToken)
        XCTAssertNil(store.focusRequest)
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
