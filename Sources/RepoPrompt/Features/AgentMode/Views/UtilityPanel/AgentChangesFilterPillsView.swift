import SwiftUI

/// Quiet, local-only working-tree section filters.
struct AgentChangesFilterPillsView: View {
    let filters: [AgentChangesFilter]
    let selected: AgentChangesFilter
    let counts: AgentChangesFilterCounts
    let onSelect: (AgentChangesFilter) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 5
        static let labelSpacing: CGFloat = 4
        static let textSizeAtNormal: CGFloat = 9.5
        static let horizontalPadding: CGFloat = 7
        static let verticalPadding: CGFloat = 3
        static let selectedOpacity: Double = 0.14
        static let unselectedOpacity: Double = 0.06
        static let borderOpacity: Double = 0.16
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            ForEach(filters) { filter in
                Button { onSelect(filter) } label: {
                    HStack(spacing: Layout.labelSpacing) {
                        Text(filter.title)
                        Text("\(counts.count(for: filter))")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .font(preset.swiftUIFont(
                        sizeAtNormal: Layout.textSizeAtNormal,
                        weight: selected == filter ? .semibold : .regular
                    ))
                    .foregroundStyle(selected == filter ? Color.primary : Color.secondary)
                    .padding(.horizontal, Layout.horizontalPadding)
                    .padding(.vertical, Layout.verticalPadding)
                    .background(
                        Capsule()
                            .fill(
                                selected == filter
                                    ? Color.accentColor.opacity(Layout.selectedOpacity)
                                    : Color.secondary.opacity(Layout.unselectedOpacity)
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                selected == filter ? Color.accentColor.opacity(Layout.borderOpacity) : .clear,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Show \(filter.title.lowercased()) files across repositories")
                .accessibilityLabel("\(filter.title), \(counts.count(for: filter)) files")
                .accessibilityValue(selected == filter ? "selected" : "not selected")
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change filters")
    }
}
