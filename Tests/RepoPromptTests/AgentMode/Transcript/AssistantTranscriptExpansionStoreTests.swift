import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AssistantTranscriptExpansionStoreTests: XCTestCase {
    func testExpandAndCollapseTracksIndividualRows() {
        let store = AssistantTranscriptExpansionStore()
        let a = UUID()
        let b = UUID()
        XCTAssertFalse(store.isExpanded(a))

        store.toggle(a)
        XCTAssertTrue(store.isExpanded(a))
        XCTAssertFalse(store.isExpanded(b))

        store.toggle(a)
        XCTAssertFalse(store.isExpanded(a))
    }

    func testExpandForcesOpenAndIsIdempotent() {
        let store = AssistantTranscriptExpansionStore()
        let id = UUID()

        store.expand(id)
        XCTAssertTrue(store.isExpanded(id))

        store.expand(id)
        XCTAssertTrue(store.isExpanded(id), "expand must not toggle an already-expanded row closed")
    }

    func testExpandAllOverridesPerRowStateAndDisablesManualToggle() {
        let store = AssistantTranscriptExpansionStore()
        let untouched = UUID()

        store.expandAll()
        XCTAssertTrue(store.expandAllAssistants)
        XCTAssertTrue(store.isExpanded(untouched), "bulk mode expands rows never individually toggled")

        // Manual per-row toggles are a no-op while bulk mode is active; "Restore automatic
        // collapsing" is the documented way out.
        store.toggle(untouched)
        XCTAssertTrue(store.isExpanded(untouched))
    }

    func testRestoreAutomaticCollapsingDropsPreBulkChoicesButKeepsBulkSearchExpansion() {
        let store = AssistantTranscriptExpansionStore()
        let manuallyExpanded = UUID()
        let searchMatch = UUID()
        store.toggle(manuallyExpanded)
        store.expandAll()
        store.expand(searchMatch)

        store.restoreAutomaticCollapsing()

        XCTAssertFalse(store.expandAllAssistants)
        XCTAssertFalse(store.isExpanded(manuallyExpanded))
        XCTAssertTrue(store.isExpanded(searchMatch), "expand-on-match during bulk mode must survive restoring automatic collapse")
    }

    func testResetClearsAllStateOnSessionChange() {
        let store = AssistantTranscriptExpansionStore()
        let id = UUID()
        store.toggle(id)
        store.expandAll()

        store.reset()

        XCTAssertFalse(store.expandAllAssistants)
        XCTAssertFalse(store.isExpanded(id))
        XCTAssertTrue(store.expandedAssistantIDs.isEmpty)
    }
}
