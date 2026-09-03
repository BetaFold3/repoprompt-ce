import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class StableMenuItemTests: XCTestCase {
    func testLazySubmenuRebuildsOnMenuNeedsUpdateAndFiresOnOpenOnlyWhenOpened() throws {
        var openCount = 0
        var titles = ["First"]
        let item = StableMenuItem.lazySubmenu(
            "OMP",
            onOpen: { openCount += 1 },
            items: { titles.map { .message($0) } }
        )

        XCTAssertEqual(item.submenuItems?.map(\.title), ["First"])
        titles = ["Latest", "State"]
        XCTAssertEqual(item.submenuItems?.map(\.title), ["Latest", "State"])
        XCTAssertEqual(openCount, 0)

        let menuItem = item.makeMenuItemForTesting()
        let submenu = try XCTUnwrap(menuItem.submenu)
        XCTAssertNotNil(menuItem.representedObject)
        XCTAssertTrue(submenu.delegate === menuItem.representedObject as AnyObject)

        submenu.delegate?.menuNeedsUpdate?(submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Latest", "State"])
        XCTAssertEqual(openCount, 0)

        submenu.delegate?.menuWillOpen?(submenu)
        XCTAssertEqual(openCount, 1)
    }
}
