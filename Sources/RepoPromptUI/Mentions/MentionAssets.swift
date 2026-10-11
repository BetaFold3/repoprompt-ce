import AppKit
import Foundation

/// Heavy, immutable resources that are needed by several mention-related
/// classes (regex compilation, SF-symbols).  They are created exactly once and
/// then shared for the lifetime of the application.
package final class MentionAssets {
    // MARK: – Singleton

    package static let shared = MentionAssets() // Lazy; thread-safe by Swift

    /// Optionally call this early (e.g. from AppDelegate) to make sure the
    /// resources are initialised on a background queue so the first UI access
    /// never blocks the main thread.
    static func prewarm() {
        guard !_isPrewarmed else { return }
        _isPrewarmed = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MentionAssets.shared
        }
    }

    // MARK: – Public, read-only resources

    package let tokenRegex: NSRegularExpression
    let folderIcon: NSImage
    let fileIcon: NSImage

    // MARK: – Private

    private static var _isPrewarmed = false

    private init() {
        // Regex – compiled once
        tokenRegex = try! NSRegularExpression(
            pattern: #"@([\w.\-/]+)"#,
            options: []
        )

        // SF Symbols – created once
        folderIcon = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: nil
        )!

        fileIcon = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: nil
        )!
    }
}
