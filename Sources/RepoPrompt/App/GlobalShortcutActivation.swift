import AppKit
import KeyboardShortcuts

enum GlobalShortcutTargetResolver {
    struct WindowDescriptor: Equatable {
        let windowID: Int
        let isNativeKeyWindow: Bool
        let isFocusFlagged: Bool
        let isClosing: Bool
    }

    static func isExactNativeWindowMatch(
        trackedWindow: AnyObject?,
        nativeKeyWindow: AnyObject?
    ) -> Bool {
        guard let trackedWindow, let nativeKeyWindow else { return false }
        return trackedWindow === nativeKeyWindow
    }

    static func shouldEnable(
        appIsActive: Bool,
        settingsEnabled: Bool,
        windows: [WindowDescriptor]
    ) -> Bool {
        appIsActive
            && settingsEnabled
            && windows.contains { $0.isNativeKeyWindow && !$0.isClosing }
    }

    static func targetWindowID(in windows: [WindowDescriptor]) -> Int? {
        if let nativeKeyWindow = windows.first(where: { $0.isNativeKeyWindow && !$0.isClosing }) {
            return nativeKeyWindow.windowID
        }
        return windows.first(where: { $0.isFocusFlagged && !$0.isClosing })?.windowID
    }
}

@MainActor
final class GlobalShortcutActivationController {
    private let trackedWindows: () -> [WindowState]
    private let isSuspended: () -> Bool
    private let settingsEnabled: () -> Bool
    private let ensureHandlersRegistered: () -> Void
    private var observerTokens: [NSObjectProtocol] = []
    private var lastAppliedEnabled: Bool?

    init(
        trackedWindows: @escaping () -> [WindowState],
        isSuspended: @escaping () -> Bool,
        settingsEnabled: @escaping () -> Bool,
        ensureHandlersRegistered: @escaping () -> Void
    ) {
        self.trackedWindows = trackedWindows
        self.isSuspended = isSuspended
        self.settingsEnabled = settingsEnabled
        self.ensureHandlersRegistered = ensureHandlersRegistered

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ]
        observerTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        guard !isSuspended() else { return }

        let application = NSApplication.shared
        let appIsActive = application.isActive
        let nativeKeyWindow = application.keyWindow

        // Only an exact tracked main-window match counts. Settings windows,
        // sheets, and popover host windows intentionally remain excluded.
        let descriptors = trackedWindows().map { window in
            GlobalShortcutTargetResolver.WindowDescriptor(
                windowID: window.windowID,
                isNativeKeyWindow: GlobalShortcutTargetResolver.isExactNativeWindowMatch(
                    trackedWindow: window.nsWindow,
                    nativeKeyWindow: nativeKeyWindow
                ),
                isFocusFlagged: window.isCurrentlyFocused,
                isClosing: window.isClosing
            )
        }
        let shouldEnable = GlobalShortcutTargetResolver.shouldEnable(
            appIsActive: appIsActive,
            settingsEnabled: settingsEnabled(),
            windows: descriptors
        )

        if shouldEnable {
            ensureHandlersRegistered()
        }
        guard shouldEnable != lastAppliedEnabled else { return }
        lastAppliedEnabled = shouldEnable
        KeyboardShortcuts.isEnabled = shouldEnable
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
