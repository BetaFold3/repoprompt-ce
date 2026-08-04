import SwiftUI

/// Repository-local identity and compare controls for one ordered Changes group.
///
/// The group is intentionally not collapsible. Keeping this header visible while filters remove all
/// rows preserves the answer to "which checkout has no staged files?" instead of hiding the group.
struct AgentChangesGroupHeaderView: View {
    let group: AgentChangesGroupState
    let compareSelection: AgentChangesCompareSelection
    let customRevisionEditor: AgentChangesPanelViewModel.CustomRevisionEditor?
    let onSelectBaseRevision: (String) -> Void
    let onBeginCustomRevision: () -> Void
    let onUpdateCustomRevision: (String) -> Void
    let onSubmitCustomRevision: () -> Void
    let onCancelCustomRevision: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 6
        static let chipSpacing: CGFloat = 5
        static let titleSizeAtNormal: CGFloat = 11
        static let statusSizeAtNormal: CGFloat = 9
        static let horizontalPadding: CGFloat = 7
        static let verticalPadding: CGFloat = 6
        static let cornerRadius: CGFloat = 6
        static let backgroundOpacity: Double = 0.055
        static let progressScale: CGFloat = 0.48
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var presentation: AgentChangesGroupHeaderPresentation {
        AgentChangesGroupHeaderPresentation(target: group.target)
    }

    private var selectedRevision: String? {
        guard case let .vsBase(base) = group.compareState else { return nil }
        return base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack(spacing: Layout.chipSpacing) {
                Text(presentation.title)
                    .font(preset.swiftUIFont(
                        sizeAtNormal: Layout.titleSizeAtNormal,
                        weight: .semibold
                    ))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Layout.spacing)

                activity

                if compareSelection == .vsBase {
                    AgentChangesBaseRevisionMenu(
                        selectedRevision: selectedRevision,
                        candidates: group.baseCandidates,
                        onSelect: onSelectBaseRevision,
                        onSelectCustom: onBeginCustomRevision
                    )
                }
            }

            HStack(spacing: Layout.chipSpacing) {
                AgentChangesChipLabel(
                    symbolName: group.target.worktree == nil || group.target.substitutesUnavailableWorktree
                        ? "folder"
                        : "arrow.triangle.branch",
                    text: presentation.checkoutIdentity
                )
                .hoverTooltip(presentation.checkoutTooltip)
                .accessibilityLabel(
                    group.target.worktree == nil || group.target.substitutesUnavailableWorktree
                        ? "Workspace checkout"
                        : "Agent worktree"
                )
                .accessibilityValue(presentation.checkoutIdentity)

                if group.target.substitutesUnavailableWorktree {
                    AgentChangesSubstitutionWarningChip(worktree: group.target.worktree)
                }

                Spacer(minLength: 0)
            }

            if let customRevisionEditor,
               customRevisionEditor.groupID == group.id,
               compareSelection == .vsBase
            {
                AgentChangesCustomRevisionEditorView(
                    editor: customRevisionEditor,
                    onUpdate: onUpdateCustomRevision,
                    onSubmit: onSubmitCustomRevision,
                    onCancel: onCancelCustomRevision
                )
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(Layout.backgroundOpacity))
        )
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(presentation.checkoutIdentity)")
        .accessibilityValue(group.target.checkoutURL.path)
    }

    @ViewBuilder
    private var activity: some View {
        switch group.snapshot.loadState {
        case .initial:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(Layout.progressScale)
                .hoverTooltip("Loading changes for \(presentation.title)")
                .accessibilityLabel("Loading \(presentation.title)")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: preset.scaledMetric(Layout.statusSizeAtNormal)))
                .foregroundStyle(.orange)
                .hoverTooltip("This repository could not be refreshed")
                .accessibilityLabel("Repository refresh failed")
        case .ready where group.snapshot.isPollingDegraded:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: preset.scaledMetric(Layout.statusSizeAtNormal)))
                .foregroundStyle(.orange)
                .hoverTooltip("File watching is unavailable for this checkout; changes are polled")
                .accessibilityLabel("File watching unavailable; polling instead")
        case .ready:
            EmptyView()
        }
    }
}
