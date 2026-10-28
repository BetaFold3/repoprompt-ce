import AppKit
@testable import RepoPromptApp
import XCTest

/// Lossless restart Step 8: the recovery banner's View popover closes on an outside click without
/// swallowing it, so one click both dismisses the popover and reaches what was clicked.
final class AgentRecoveryNativePopoverEventDecisionTests: XCTestCase {
    private func decide(
        mouseDown: Bool = false,
        escape: Bool = false,
        inPopover: Bool = false,
        onAnchor: Bool = false
    ) -> AgentRecoveryNativePopoverEventDecision {
        .decide(isMouseDown: mouseDown, isEscapeKey: escape, isInPopoverWindow: inPopover, isOnAnchor: onAnchor)
    }

    func testOutsideClickClosesAndIsDelivered() {
        XCTAssertEqual(decide(mouseDown: true), .closeAndDeliver)
    }

    func testClickInsidePopoverKeepsItOpen() {
        XCTAssertEqual(decide(mouseDown: true, inPopover: true), .ignore)
    }

    func testClickOnAnchorTogglesClosedWithoutReopening() {
        XCTAssertEqual(decide(mouseDown: true, onAnchor: true), .closeAndConsume)
    }

    func testEscapeInPopoverCloses() {
        XCTAssertEqual(decide(escape: true, inPopover: true), .closeAndConsume)
    }

    func testKeysElsewhereAreIgnored() {
        XCTAssertEqual(decide(escape: true), .ignore)
        XCTAssertEqual(decide(inPopover: true), .ignore)
        XCTAssertEqual(decide(), .ignore)
    }

    /// Verifier cycle 11: the popover opens outside its rows' region (banner: above it; sheet:
    /// beside it), positioned against the whole region so any edge AppKit picks stays outside.
    private typealias Region = AgentRecoveryNativePopoverRegion
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let popover = NSSize(width: 360, height: 280)

    func testRegionPlacementPrefersTheRequestedEdgeWhenTheScreenHasRoom() {
        let banner = NSRect(x: 300, y: 120, width: 800, height: 180)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.maxY))
        let sheet = NSRect(x: 410, y: 300, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: screen, preferredEdge: .maxX), .region(.maxX))
    }

    func testRegionPlacementUsesTheOppositeEdgeWhenOnlyThatHasRoom() {
        // A sheet near the screen's right edge: no room beside it on the right, enough on the left.
        let sheet = NSRect(x: 780, y: 300, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: screen, preferredEdge: .maxX), .region(.minX))
        // A banner near the top of the screen: no room above, enough below.
        let banner = NSRect(x: 300, y: 600, width: 800, height: 180)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.minY))
    }

    func testRegionPlacementUsesAnEdgeAtRightAnglesWhenOnlyThatHasRoom() {
        // Re-review VF-R1-1: a 620-pt sheet centred on a 1280-pt display leaves 330 pt on each
        // side, too little for the popover; below it, under the title bar, there is room.
        let laptop = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let sheet = NSRect(x: 330, y: 380, width: 620, height: 400)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: laptop, preferredEdge: .maxX), .region(.minY))
        // A banner filling the screen's height, with room only on its leading side.
        let banner = NSRect(x: 400, y: 0, width: 1040, height: 900)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.minX))
    }

    func testRegionPlacementFallsBackToTheAnchorWhenNoSideHasRoom() {
        // A minimum-width sheet on a small display: no room on any side.
        let small = NSRect(x: 0, y: 0, width: 1024, height: 700)
        let sheet = NSRect(x: 200, y: 100, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: small, preferredEdge: .maxX), .anchor)
        // A banner filling the screen's height.
        let banner = NSRect(x: 0, y: 0, width: 1024, height: 700)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: small, preferredEdge: .maxY), .anchor)
    }

    /// Verifier P5: Escape straight after opening closes the popover. Escape is handled only in the
    /// popover's window, so that window takes key when shown and gives it back when closed.
    @MainActor
    private final class FakeWindow: AgentRecoveryNativePopoverKeyWindow {
        var isVisible = true
        var canBecomeKey = true
        var isKeyWindow = false
        private(set) var makeKeyCount = 0
        func makeKey() {
            makeKeyCount += 1
            isKeyWindow = true
        }
    }

    private typealias KeyFocus = AgentRecoveryNativePopoverKeyFocus

    @MainActor
    func testShownPopoverTakesKeySoEscapeReachesIt() {
        let popoverWindow = FakeWindow()
        KeyFocus.takeKey(popoverWindow: popoverWindow)
        XCTAssertEqual(popoverWindow.makeKeyCount, 1)
        // With its window key, Escape there closes it with one press.
        XCTAssertEqual(decide(escape: true, inPopover: popoverWindow.isKeyWindow), .closeAndConsume)
    }

    @MainActor
    func testShownPopoverDoesNotTakeKeyWhenItCannotOrAlreadyHasIt() {
        let alreadyKey = FakeWindow()
        alreadyKey.isKeyWindow = true
        KeyFocus.takeKey(popoverWindow: alreadyKey)
        XCTAssertEqual(alreadyKey.makeKeyCount, 0)
        let cannot = FakeWindow()
        cannot.canBecomeKey = false
        KeyFocus.takeKey(popoverWindow: cannot)
        XCTAssertEqual(cannot.makeKeyCount, 0)
        KeyFocus.takeKey(popoverWindow: nil)
    }

    @MainActor
    func testClosingAKeyPopoverGivesKeyBackToThePreviousWindow() {
        let previous = FakeWindow()
        let popoverWindow = FakeWindow()
        popoverWindow.isKeyWindow = true
        KeyFocus.returnKey(from: popoverWindow, to: previous)
        XCTAssertEqual(previous.makeKeyCount, 1)
    }

    @MainActor
    func testClosingLeavesFocusAloneWhenThePopoverIsNotKeyOrThePreviousWindowCannotTakeIt() {
        // Focus already moved (app deactivated, or another window made key).
        let previous = FakeWindow()
        KeyFocus.returnKey(from: FakeWindow(), to: previous)
        XCTAssertEqual(previous.makeKeyCount, 0)

        let keyPopover = FakeWindow()
        keyPopover.isKeyWindow = true
        let hidden = FakeWindow()
        hidden.isVisible = false
        KeyFocus.returnKey(from: keyPopover, to: hidden)
        XCTAssertEqual(hidden.makeKeyCount, 0)
        let cannot = FakeWindow()
        cannot.canBecomeKey = false
        KeyFocus.returnKey(from: keyPopover, to: cannot)
        XCTAssertEqual(cannot.makeKeyCount, 0)
        KeyFocus.returnKey(from: keyPopover, to: keyPopover)
        XCTAssertEqual(keyPopover.makeKeyCount, 0)
        KeyFocus.returnKey(from: keyPopover, to: nil)
        KeyFocus.returnKey(from: nil, to: previous)
        XCTAssertEqual(previous.makeKeyCount, 0)
    }

    func testRegionPlacementCountsTheArrowAndBorder() {
        let exactFit = NSRect(x: 0, y: 0, width: 1440, height: 900 - popover.height - Region.popoverChrome)
        XCTAssertEqual(Region.placement(region: exactFit, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.maxY))
        let onePointShort = NSRect(x: 0, y: 1, width: 1440, height: exactFit.height)
        XCTAssertEqual(Region.placement(region: onePointShort, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .anchor)
    }
}
