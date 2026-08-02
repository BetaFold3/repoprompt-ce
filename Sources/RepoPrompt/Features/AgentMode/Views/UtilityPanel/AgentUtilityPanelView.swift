import SwiftUI

/// Chrome for the right utility panel: header, segmented control, and content.
///
/// Visual vocabulary is deliberately borrowed from `AgentRuntimeSidebarView` — the same
/// `.ultraThinMaterial` header capsule, the same collapse-chevron treatment, and the same card
/// styling via `AgentSidebarCardStyle` — so the two right-hand surfaces read as one family.
struct AgentUtilityPanelView: View {
    @ObservedObject var store: AgentUtilityPanelPresentationStore
    /// Active-tab panel state. Segment selection is per tab, so it arrives through the UI-store
    /// facade rather than from the per-window presentation store.
    @ObservedObject var utilityPanelUI: AgentUtilityPanelUIStore
    let agentModeVM: AgentModeViewModel
    /// The Changes segment's controller.
    ///
    /// One per panel mount rather than per segment: it owns a file watcher and a rebuild loop, and
    /// tearing those down every time the user glances at Preview would make coming back to Changes
    /// cost a full repository read.
    @StateObject private var changesViewModel: AgentChangesPanelViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: AgentUtilityPanelPresentationStore,
        utilityPanelUI: AgentUtilityPanelUIStore,
        agentModeVM: AgentModeViewModel
    ) {
        _store = ObservedObject(wrappedValue: store)
        _utilityPanelUI = ObservedObject(wrappedValue: utilityPanelUI)
        self.agentModeVM = agentModeVM
        _changesViewModel = StateObject(
            wrappedValue: AgentChangesPanelViewModel.live(agentModeVM: agentModeVM)
        )
    }

    private enum Layout {
        static let headerHorizontalPadding: CGFloat = 10
        static let headerVerticalPadding: CGFloat = 7
        static let headerCornerRadius: CGFloat = 16
        static let headerBorderWidth: CGFloat = 0.5
        static let headerBorderOpacity: Double = 0.15
        static let headerSpacing: CGFloat = 6
        static let outerHorizontalPadding: CGFloat = 10
        static let outerTopPadding: CGFloat = 10
        static let headerBottomPadding: CGFloat = 4
        static let segmentBottomPadding: CGFloat = 8
        static let titleSizeAtNormal: CGFloat = 11
        static let segmentTransitionDuration: Double = 0.15
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var selectedSegment: AgentUtilityPanelSegment {
        utilityPanelUI.snapshot.segment
    }

    /// Writes go through the view model so the tab owns the value and the facade republishes it;
    /// the picker never mutates a store the way a per-window `@Published` would allow.
    private var segmentBinding: Binding<AgentUtilityPanelSegment> {
        Binding(
            get: { selectedSegment },
            set: { agentModeVM.selectUtilityPanelSegment($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentPicker
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Synced from the panel root rather than from the Changes branch: the artifact banner and
        // the checkout stay current while the user reads a document, so switching back to Changes
        // shows the repository as it is now instead of as it was when Preview took over.
        .onAppear { syncChangesState() }
        .onChange(of: utilityPanelUI.snapshot) { _, _ in syncChangesState() }
        .onDisappear { changesViewModel.shutdown() }
    }

    private func syncChangesState() {
        changesViewModel.sync(
            tabID: utilityPanelUI.snapshot.currentTabID,
            panel: utilityPanelUI.snapshot.panel
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Layout.headerSpacing) {
            AgentUtilityPanelCloseButton { store.hide() }

            Text("Utility")
                .font(preset.swiftUIFont(sizeAtNormal: Layout.titleSizeAtNormal, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, Layout.headerHorizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Layout.headerCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.headerCornerRadius, style: .continuous)
                .stroke(
                    Color.secondary.opacity(Layout.headerBorderOpacity),
                    lineWidth: Layout.headerBorderWidth
                )
        )
        .padding(.horizontal, Layout.outerHorizontalPadding)
        .padding(.top, Layout.outerTopPadding)
        .padding(.bottom, Layout.headerBottomPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility panel")
    }

    // MARK: - Segments

    private var segmentPicker: some View {
        Picker("Utility panel section", selection: segmentBinding) {
            ForEach(AgentUtilityPanelSegment.allCases) { segment in
                Text(segment.title)
                    .accessibilityLabel(segment.accessibilityLabel)
                    .tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, Layout.outerHorizontalPadding)
        .padding(.bottom, Layout.segmentBottomPadding)
        .accessibilityLabel("Utility panel section")
        .accessibilityValue(selectedSegment.title)
    }

    // MARK: - Content

    private var content: some View {
        Group {
            switch selectedSegment {
            case .changes:
                changesContent
            case .preview:
                AgentPreviewPanelView(
                    utilityPanelUI: utilityPanelUI,
                    agentModeVM: agentModeVM
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Layout.segmentTransitionDuration),
            value: selectedSegment
        )
    }

    /// The Changes segment.
    ///
    /// It owns its own scrolling, for the same reason Preview does: its file list pins section and
    /// file headers to the top of a viewport it has to control, and its footer stays put while that
    /// list scrolls underneath.
    private var changesContent: some View {
        AgentChangesPanelView(viewModel: changesViewModel)
    }
}

/// Mirrors `AgentRuntimeSidebarCollapseButton`: same glyph, metrics, hover fill, and hit shape, so
/// the two right-hand surfaces dismiss identically.
private struct AgentUtilityPanelCloseButton: View {
    let onClose: () -> Void
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var isHovered = false

    private enum Layout {
        static let glyphSizeAtNormal: CGFloat = 9
        static let buttonSize: CGFloat = 24
        static let hoverFillOpacity: Double = 0.12
    }

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.right")
                .font(.system(size: fontScale.preset.scaledMetric(Layout.glyphSizeAtNormal), weight: .bold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: Layout.buttonSize, height: Layout.buttonSize)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(Layout.hoverFillOpacity) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close utility panel")
    }
}
