import SwiftUI

/// Centralized metrics for code view layout to avoid hard-coded literals.
/// These values enable index-based calculations without per-row geometry.
enum CodeViewMetrics {
    /// Base line height for code rows
    static let lineHeight: CGFloat = 20

    // Gutter widths
    static let lineNumberWidth: CGFloat = 40
    static let symbolWidth: CGFloat = 20

    /// Vertical offset applied to the copy button relative to the selected line
    static let copyButtonYOffset: CGFloat = 6
}
