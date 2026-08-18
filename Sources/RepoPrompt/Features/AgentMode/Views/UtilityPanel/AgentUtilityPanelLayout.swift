import SwiftUI

/// Chrome constants for `AgentUtilityPanelLayout`.
///
/// Declared outside the generic view because Swift does not allow static stored properties inside
/// generic types.
private enum AgentUtilityPanelLayoutConstants {
    static let overlayShadowRadius: CGFloat = 12
    static let overlayShadowOpacity: Double = 0.18
    static let overlayShadowXOffset: CGFloat = -2
    static let resizeStripIndicatorWidth: CGFloat = 1
    static let resizeStripActiveOpacity: Double = 0.55
    static let resizeStripIdleOpacity: Double = 0
}

/// Places the utility panel beside — or over — the detail content.
///
/// Which of the two happens is decided by `AgentUtilityPanelLayoutMetrics`, not here: this view
/// only renders the chosen presentation, hosts the drag strip, and owns the gesture state. Docking
/// is preferred; the overlay exists so a narrow window can still show the panel without squeezing
/// the transcript below its protected reading width.
struct AgentUtilityPanelLayout<Detail: View, Panel: View>: View {
    @ObservedObject var store: AgentUtilityPanelPresentationStore
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var panel: () -> Panel

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Preferred width captured when a resize drag begins, so the gesture applies one total
    /// translation rather than accumulating per-frame deltas.
    @State private var dragStartPreferredWidth: CGFloat?
    @State private var isHoveringResizeStrip = false
    @GestureState private var isDraggingResizeStrip = false

    private typealias Layout = AgentUtilityPanelLayoutConstants

    private var metrics: AgentUtilityPanelLayoutMetrics {
        AgentUtilityPanelLayoutMetrics(preset: fontScale.preset)
    }

    var body: some View {
        GeometryReader { proxy in
            presentationContent(
                metrics.resolve(
                    availableWidth: proxy.size.width,
                    preferredWidth: store.preferredWidth,
                    isVisible: store.isVisible
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Presentation

    private func presentationContent(
        _ presentation: AgentUtilityPanelLayoutMetrics.Presentation
    ) -> some View {
        let isPresent = presentation.panelWidth != nil

        return HStack(spacing: 0) {
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if presentation.isDocked, let panelWidth = presentation.panelWidth {
                Divider()
                Color.clear.frame(width: panelWidth)
            }
        }
        .overlay(alignment: .trailing) {
            // The persisting container owns animation and hit testing. Its transaction cannot
            // animate the sibling detail layout, and an exiting panel becomes inert immediately.
            ZStack(alignment: .trailing) {
                if let panelWidth = presentation.panelWidth {
                    panelSurface(width: panelWidth, isOverlay: presentation.isOverlay)
                        .transition(panelTransition)
                }
            }
            .allowsHitTesting(isPresent)
            .animation(AgentPanelMotion.reveal(reduceMotion: reduceMotion), value: isPresent)
        }
        .clipped()
    }

    private func panelSurface(width: CGFloat, isOverlay: Bool) -> some View {
        panel()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(panelBackground(isOverlay: isOverlay))
            .overlay(alignment: .leading) {
                if isOverlay {
                    Divider()
                }
            }
            .compositingGroup()
            .shadow(
                color: isOverlay
                    ? Color.black.opacity(Layout.overlayShadowOpacity)
                    : Color.clear,
                radius: isOverlay ? Layout.overlayShadowRadius : 0,
                x: isOverlay ? Layout.overlayShadowXOffset : 0
            )
            // Claim hit-testing across the whole surface so overlay clicks never reach the
            // transcript underneath.
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { resizeStrip }
    }

    @ViewBuilder
    private func panelBackground(isOverlay: Bool) -> some View {
        if isOverlay {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Color.clear
        }
    }

    // MARK: - Resize strip

    private var resizeStrip: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: AgentUtilityPanelLayoutMetrics.resizeStripWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.accentColor.opacity(
                        isHoveringResizeStrip || isDraggingResizeStrip
                            ? Layout.resizeStripActiveOpacity
                            : Layout.resizeStripIdleOpacity
                    ))
                    .frame(width: Layout.resizeStripIndicatorWidth)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringResizeStrip = hovering
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(resizeDragGesture)
            .onTapGesture(count: 2) {
                // Width mutations are deliberately unanimated, matching the direct resize drag.
                store.resetPreferredWidth()
            }
            .accessibilityLabel("Resize utility panel")
            .accessibilityValue("\(Int(store.preferredWidth.rounded())) points")
    }

    private var resizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($isDraggingResizeStrip) { _, state, _ in
                state = true
            }
            .onChanged { value in
                let startingWidth = dragStartPreferredWidth ?? store.preferredWidth
                if dragStartPreferredWidth == nil {
                    dragStartPreferredWidth = startingWidth
                }
                // Deliberately unanimated: an animated width would lag the pointer.
                store.updatePreferredWidth(
                    metrics.preferredWidth(
                        draggingFrom: startingWidth,
                        translation: value.translation.width
                    ),
                    commit: false
                )
            }
            .onEnded { value in
                let startingWidth = dragStartPreferredWidth ?? store.preferredWidth
                dragStartPreferredWidth = nil
                // Single settings write for the whole gesture.
                store.updatePreferredWidth(
                    metrics.preferredWidth(
                        draggingFrom: startingWidth,
                        translation: value.translation.width
                    ),
                    commit: true
                )
            }
    }

    // MARK: - Motion

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing)
    }
}
