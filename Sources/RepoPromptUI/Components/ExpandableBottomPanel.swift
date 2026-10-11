import SwiftUI

/// Preference key for measuring header height
private struct HeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A reusable floating bottom panel with material background, expand/collapse animation,
/// optional resize handle, and customizable content. Used by terminal panel and Agent mode file tree panel.
struct ExpandableBottomPanel<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @Binding var collapsedHeight: CGFloat
    @Binding var expandedBodyHeight: CGFloat

    let minBodyHeight: CGFloat
    let maxBodyHeight: CGFloat
    let expandedMinWidth: CGFloat?
    let showsDividerWhenExpanded: Bool
    let cornerRadius: CGFloat
    let isResizable: Bool

    @ViewBuilder let header: (_ isExpanded: Bool, _ toggle: @escaping () -> Void) -> Header
    @ViewBuilder let content: () -> Content

    // Resize state
    @State private var resizeStartHeight: CGFloat?
    @State private var liveHeight: CGFloat?

    init(
        isExpanded: Binding<Bool>,
        collapsedHeight: Binding<CGFloat>,
        expandedBodyHeight: Binding<CGFloat>,
        minBodyHeight: CGFloat = 150,
        maxBodyHeight: CGFloat = 500,
        expandedMinWidth: CGFloat? = nil,
        showsDividerWhenExpanded: Bool = true,
        cornerRadius: CGFloat = 16,
        isResizable: Bool = false,
        @ViewBuilder header: @escaping (_ isExpanded: Bool, _ toggle: @escaping () -> Void) -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        _collapsedHeight = collapsedHeight
        _expandedBodyHeight = expandedBodyHeight
        self.minBodyHeight = minBodyHeight
        self.maxBodyHeight = maxBodyHeight
        self.expandedMinWidth = expandedMinWidth
        self.showsDividerWhenExpanded = showsDividerWhenExpanded
        self.cornerRadius = cornerRadius
        self.isResizable = isResizable
        self.header = header
        self.content = content
    }

    private var effectiveBodyHeight: CGFloat {
        liveHeight ?? expandedBodyHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // Resize handle at top (only when expanded and resizable)
            if isExpanded, isResizable {
                resizeHandle
            }

            // Header (always visible)
            header(isExpanded, toggle)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeaderHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )

            // Divider (optional, only when expanded)
            if showsDividerWhenExpanded {
                Divider()
                    .background(Color.primary.opacity(0.08))
                    .opacity(isExpanded ? 1 : 0)
                    .frame(height: isExpanded ? nil : 0)
            }

            // Content body
            content()
                .frame(height: isExpanded ? effectiveBodyHeight : 0)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .clipped()
        }
        .frame(minWidth: isExpanded ? expandedMinWidth : nil)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -2)
        .onPreferenceChange(HeaderHeightPreferenceKey.self) { newHeight in
            let clampedHeight = max(0, newHeight)
            guard clampedHeight > 0, abs(clampedHeight - collapsedHeight) > 0.5 else { return }
            DispatchQueue.main.async {
                collapsedHeight = clampedHeight
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded.toggle()
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isExpanded else { return }
                        if resizeStartHeight == nil {
                            resizeStartHeight = expandedBodyHeight
                        }
                        // Dragging up increases height, dragging down decreases
                        let proposed = (resizeStartHeight ?? expandedBodyHeight) - value.translation.height
                        let clamped = clampedHeight(proposed)
                        if let current = liveHeight, abs(clamped - current) < 1 {
                            return
                        }
                        liveHeight = clamped
                    }
                    .onEnded { _ in
                        if let finalHeight = liveHeight {
                            expandedBodyHeight = finalHeight
                        }
                        liveHeight = nil
                        resizeStartHeight = nil
                    }
            )
    }

    private func clampedHeight(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, minBodyHeight), maxBodyHeight)
    }

    // MARK: - Background

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - Convenience initializer with fixed height (non-resizable)

extension ExpandableBottomPanel {
    init(
        isExpanded: Binding<Bool>,
        collapsedHeight: Binding<CGFloat>,
        fixedBodyHeight: CGFloat,
        expandedMinWidth: CGFloat? = nil,
        showsDividerWhenExpanded: Bool = true,
        cornerRadius: CGFloat = 16,
        @ViewBuilder header: @escaping (_ isExpanded: Bool, _ toggle: @escaping () -> Void) -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        _collapsedHeight = collapsedHeight
        _expandedBodyHeight = .constant(fixedBodyHeight)
        minBodyHeight = fixedBodyHeight
        maxBodyHeight = fixedBodyHeight
        self.expandedMinWidth = expandedMinWidth
        self.showsDividerWhenExpanded = showsDividerWhenExpanded
        self.cornerRadius = cornerRadius
        isResizable = false
        self.header = header
        self.content = content
    }
}
