import SwiftUI

/// Native initial placement for the Agent Mode transcript scroll view.
///
/// Every transcript `ScrollView` instance (first mount, a new `AgentTranscriptScrollMountKey` on
/// tab entry or first hydration, a reset-revision remount) is followed by a live-bottom restore,
/// so its first layout should already show the latest content instead of offset 0. The anchor
/// uses only the `.initialOffset` role: it does not bottom-align short content (`.alignment`) or
/// keep the bottom edge fixed when content grows (`.sizeChanges`), so a detached reading position
/// inside a mounted instance is unaffected.
@available(macOS 15.0, *)
struct AgentTranscriptInitialBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        content.defaultScrollAnchor(.bottom, for: .initialOffset)
    }
}
