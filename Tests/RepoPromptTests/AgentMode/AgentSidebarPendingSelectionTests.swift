@testable import RepoPromptApp
import XCTest

final class AgentSidebarPendingSelectionTests: XCTestCase {
    func testWithoutPendingClickHighlightFollowsCurrentTab() {
        let selection = AgentSidebarPendingSelection()
        let current = UUID()

        XCTAssertNil(selection.entry)
        XCTAssertEqual(selection.resolvedActiveTabID(current: current), current)
        XCTAssertNil(selection.resolvedActiveTabID(current: nil))
    }

    func testPendingClickHighlightsClickedTabBeforeCurrentCatchesUp() {
        var selection = AgentSidebarPendingSelection()
        let current = UUID()
        let clicked = UUID()

        let token = selection.begin(tabID: clicked)

        XCTAssertEqual(selection.entry, .init(tabID: clicked, token: token))
        XCTAssertTrue(selection.isCurrent(token))
        XCTAssertEqual(selection.resolvedActiveTabID(current: current), clicked)
    }

    func testLastClickWins() {
        var selection = AgentSidebarPendingSelection()
        let first = UUID()
        let second = UUID()

        let firstToken = selection.begin(tabID: first)
        let secondToken = selection.begin(tabID: second)

        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertFalse(selection.isCurrent(firstToken))
        XCTAssertTrue(selection.isCurrent(secondToken))
        XCTAssertEqual(selection.resolvedActiveTabID(current: nil), second)
    }

    func testClearIfTokenOnlyClearsMatchingToken() {
        var selection = AgentSidebarPendingSelection()
        let current = UUID()
        let first = UUID()
        let second = UUID()

        let firstToken = selection.begin(tabID: first)
        let secondToken = selection.begin(tabID: second)

        // A superseded switch completing must not drop the newer highlight.
        selection.clear(ifToken: firstToken)
        XCTAssertEqual(selection.entry, .init(tabID: second, token: secondToken))
        XCTAssertEqual(selection.resolvedActiveTabID(current: current), second)

        // The owning switch completing (e.g. refused) reverts to the authority.
        selection.clear(ifToken: secondToken)
        XCTAssertNil(selection.entry)
        XCTAssertEqual(selection.resolvedActiveTabID(current: current), current)
    }

    func testClearWhenCurrentCatchesUpOnlyForPendingTab() {
        var selection = AgentSidebarPendingSelection()
        let clicked = UUID()
        let other = UUID()

        let token = selection.begin(tabID: clicked)

        selection.clear(ifTabID: other)
        XCTAssertEqual(selection.entry, .init(tabID: clicked, token: token))
        selection.clear(ifTabID: nil)
        XCTAssertEqual(selection.entry, .init(tabID: clicked, token: token))

        selection.clear(ifTabID: clicked)
        XCTAssertNil(selection.entry)
        XCTAssertEqual(selection.resolvedActiveTabID(current: clicked), clicked)
        // Catching up drops only the highlight; the deferred switch stays current.
        XCTAssertTrue(selection.isCurrent(token))
    }

    func testStaleTokenIgnoredAfterCancel() {
        var selection = AgentSidebarPendingSelection()
        let current = UUID()
        let clicked = UUID()

        let token = selection.begin(tabID: clicked)
        selection.cancel()

        XCTAssertFalse(selection.isCurrent(token))
        XCTAssertNil(selection.entry)
        XCTAssertEqual(selection.resolvedActiveTabID(current: current), current)

        // A stale completion after cancellation is a no-op on a newer click.
        let newer = UUID()
        let newerToken = selection.begin(tabID: newer)
        selection.clear(ifToken: token)
        XCTAssertEqual(selection.entry, .init(tabID: newer, token: newerToken))
    }

    func testClearHighlightKeepsDeferredSwitchCurrent() {
        var selection = AgentSidebarPendingSelection()
        let clicked = UUID()

        let token = selection.begin(tabID: clicked)
        selection.clearHighlight()

        XCTAssertNil(selection.entry)
        XCTAssertTrue(selection.isCurrent(token))
    }
}
