import SwiftUI

/// The card treatment shared by Agent Mode's right-hand surfaces.
///
/// Extracted verbatim from `AgentRuntimeSidebarView`'s former private `sidebarCard` modifier so the
/// runtime sidebar and the utility panel cannot drift apart visually. Values are intentionally
/// named rather than inlined so a future restyle happens in one place.
struct AgentSidebarCardStyle: ViewModifier {
    static let cornerRadius: CGFloat = 10
    static let contentPadding: CGFloat = 10
    static let backgroundOpacity: Double = 0.35
    static let highlightOpacity: Double = 0.25
    static let highlightLineWidth: CGFloat = 1

    /// Tint for the card's border, used to mark a live activity (running, streaming). `nil` leaves
    /// the border clear.
    let highlight: Color?

    func body(content: Content) -> some View {
        content
            .padding(Self.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(Self.backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(
                        highlight?.opacity(Self.highlightOpacity) ?? Color.clear,
                        lineWidth: Self.highlightLineWidth
                    )
            )
    }
}

extension View {
    /// Applies the shared Agent sidebar/panel card treatment.
    func agentSidebarCard(highlight: Color? = nil) -> some View {
        modifier(AgentSidebarCardStyle(highlight: highlight))
    }
}
