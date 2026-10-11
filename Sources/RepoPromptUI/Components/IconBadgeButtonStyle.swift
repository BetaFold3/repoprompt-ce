import SwiftUI

/// A minimal button style intended for toolbar icon buttons that display an
/// overlay badge.
/// • No padding, border or background that could clip the badge.
/// • Subtle press animation for feedback.
struct IconBadgeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(6) // extra space around icon & badge
            .contentShape(Rectangle()) // ensure full hit area
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
