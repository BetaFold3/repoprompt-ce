@testable import RepoPromptApp
import XCTest

final class SnippetPaletteActivationGateTests: XCTestCase {
    func testActivationRequiresEveryShellCondition() {
        let tabID = UUID()
        let cases: [(
            name: String,
            requestWindowID: Int?,
            route: AppRootRoute,
            isKey: Bool,
            hasSheet: Bool,
            hasBlocker: Bool,
            hasNavigationHUD: Bool,
            hasModelHUD: Bool,
            tabID: UUID?,
            expected: Bool
        )] = [
            ("eligible", 41, .main, true, false, false, false, false, tabID, true),
            ("missing window ID", nil, .main, true, false, false, false, false, tabID, false),
            ("mismatched window ID", 42, .main, true, false, false, false, false, tabID, false),
            ("workspace entry route", 41, .workspaceEntry, true, false, false, false, false, tabID, false),
            ("main window not key", 41, .main, false, false, false, false, false, tabID, false),
            ("attached sheet", 41, .main, true, true, false, false, false, tabID, false),
            ("blocking overlay", 41, .main, true, false, true, false, false, tabID, false),
            ("navigation HUD", 41, .main, true, false, false, true, false, tabID, false),
            ("model HUD", 41, .main, true, false, false, false, true, tabID, false),
            ("nil tab ID", 41, .main, true, false, false, false, false, nil, false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                SnippetPaletteActivationGate.shouldActivate(
                    requestWindowID: testCase.requestWindowID,
                    currentWindowID: 41,
                    rootRoute: testCase.route,
                    isMainWindowKey: testCase.isKey,
                    hasAttachedSheet: testCase.hasSheet,
                    isBlockingOverlayVisible: testCase.hasBlocker,
                    isNavigationHUDPresented: testCase.hasNavigationHUD,
                    isModelSelectionHUDPresented: testCase.hasModelHUD,
                    activeComposeTabID: testCase.tabID
                ),
                testCase.expected,
                testCase.name
            )
        }
    }
}
