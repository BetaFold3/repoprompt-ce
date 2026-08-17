@testable import RepoPromptApp
import XCTest

final class GlobalShortcutActivationTests: XCTestCase {
    typealias Descriptor = GlobalShortcutTargetResolver.WindowDescriptor

    func testEnablementRequiresActiveAppEnabledSettingAndTrackedNativeKeyWindow() {
        let nativeKey = descriptor(windowID: 1, isNativeKeyWindow: true)

        XCTAssertTrue(isEnabled(appIsActive: true, settingsEnabled: true, windows: [nativeKey]))
        XCTAssertFalse(isEnabled(appIsActive: false, settingsEnabled: true, windows: [nativeKey]))
        XCTAssertFalse(isEnabled(appIsActive: true, settingsEnabled: false, windows: [nativeKey]))
        XCTAssertFalse(isEnabled(appIsActive: true, settingsEnabled: true, windows: []))
    }

    func testFocusFlagWithoutNativeKeyWindowDoesNotEnableShortcuts() {
        let trackedWindow = descriptor(windowID: 1, isFocusFlagged: true)

        XCTAssertFalse(isEnabled(windows: [trackedWindow]))
    }

    func testExactNativeWindowIdentityRequiresSameNonNilObject() {
        let trackedWindow = NSObject()
        let foreignWindow = NSObject()

        XCTAssertTrue(
            GlobalShortcutTargetResolver.isExactNativeWindowMatch(
                trackedWindow: trackedWindow,
                nativeKeyWindow: trackedWindow
            )
        )
        XCTAssertFalse(
            GlobalShortcutTargetResolver.isExactNativeWindowMatch(
                trackedWindow: trackedWindow,
                nativeKeyWindow: foreignWindow
            )
        )
        XCTAssertFalse(
            GlobalShortcutTargetResolver.isExactNativeWindowMatch(
                trackedWindow: nil,
                nativeKeyWindow: nil
            )
        )
    }

    func testNativeKeyWindowWinsOverStaleFocusFlag() {
        let staleFocusedWindow = descriptor(windowID: 1, isFocusFlagged: true)
        let nativeKeyWindow = descriptor(windowID: 2, isNativeKeyWindow: true)

        XCTAssertEqual(
            GlobalShortcutTargetResolver.targetWindowID(
                in: [staleFocusedWindow, nativeKeyWindow]
            ),
            2
        )
    }

    func testClosingWindowNeverEnablesOrTargets() {
        let closingWindow = descriptor(
            windowID: 1,
            isNativeKeyWindow: true,
            isFocusFlagged: true,
            isClosing: true
        )

        XCTAssertFalse(isEnabled(windows: [closingWindow]))
        XCTAssertNil(GlobalShortcutTargetResolver.targetWindowID(in: [closingWindow]))
    }

    func testFocusFlagFallbackResolvesButNeverEnables() {
        let focusFlaggedWindow = descriptor(windowID: 1, isFocusFlagged: true)

        XCTAssertFalse(isEnabled(windows: [focusFlaggedWindow]))
        XCTAssertEqual(
            GlobalShortcutTargetResolver.targetWindowID(in: [focusFlaggedWindow]),
            1
        )
    }

    private func isEnabled(
        appIsActive: Bool = true,
        settingsEnabled: Bool = true,
        windows: [Descriptor]
    ) -> Bool {
        GlobalShortcutTargetResolver.shouldEnable(
            appIsActive: appIsActive,
            settingsEnabled: settingsEnabled,
            windows: windows
        )
    }

    private func descriptor(
        windowID: Int,
        isNativeKeyWindow: Bool = false,
        isFocusFlagged: Bool = false,
        isClosing: Bool = false
    ) -> Descriptor {
        Descriptor(
            windowID: windowID,
            isNativeKeyWindow: isNativeKeyWindow,
            isFocusFlagged: isFocusFlagged,
            isClosing: isClosing
        )
    }
}
