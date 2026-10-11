import AppKit

/// Centralised colour for the thin outline that appears when hovering rows in
/// both the native file tree and the search results tree.
///
/// • Light Mode → dark grey (≈ 15 % white) @ 65 % opacity
/// • Dark Mode  → light grey (100 % white) @ 20 % opacity
///
/// The colour is provided through `dynamicProvider` so any *runtime* appearance
/// change (manually switching Light ⇄ Dark in System Settings) is picked up
/// automatically without extra notifications.
extension NSColor {
    static var hoverOutlineColor: NSColor {
        NSColor(
            name: NSColor.Name("HoverOutlineColor"),
            dynamicProvider: { appearance in
                // Determine whether the requesting appearance is dark or light.
                let darkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if darkAppearance {
                    // Light grey with lower opacity for dark mode
                    return NSColor(white: 1.0, alpha: 0.20)
                } else {
                    // Much darker grey, closer to primary text colour
                    return NSColor(white: 0.15, alpha: 0.65)
                }
            }
        )
    }

    /// Dark mode aware color for search text highlighting.
    ///
    /// • Light Mode → yellow (standard highlight color)
    /// • Dark Mode  → orange/amber for better contrast with white text
    static var searchHighlightColor: NSColor {
        NSColor(
            name: NSColor.Name("SearchHighlightColor"),
            dynamicProvider: { appearance in
                let darkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if darkAppearance {
                    // Orange/amber color for better contrast with white text in dark mode
                    return NSColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.5)
                } else {
                    // Standard yellow for light mode
                    return NSColor.yellow.withAlphaComponent(0.5)
                }
            }
        )
    }
}
