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
}
