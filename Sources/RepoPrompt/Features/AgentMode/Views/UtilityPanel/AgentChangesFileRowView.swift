import SwiftUI

// MARK: - Section header

/// A pinned section header: Staged, Unstaged, Conflicts, or the flat list's single title.
///
/// Pinned rather than scrolled away because the same file can legitimately appear twice — a
/// partially-staged file is in both Staged and Unstaged with different patches — and a row seen
/// without its section header is a row whose meaning is ambiguous.
struct AgentChangesSectionHeaderView: View {
    let section: AgentChangesSection
    let supportsStaging: Bool
    let isBulkDisabled: Bool
    let isBulkPending: Bool
    let onBulkAction: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 6
        static let titleSizeAtNormal: CGFloat = 11
        static let subtitleSizeAtNormal: CGFloat = 10
        static let actionSizeAtNormal: CGFloat = 10
        static let horizontalPadding: CGFloat = 4
        static let verticalPadding: CGFloat = 5
        static let progressScale: CGFloat = 0.5
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var presentation: AgentChangesSectionPresentation {
        AgentChangesSectionPresentation(section: section, supportsStaging: supportsStaging)
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Text(presentation.title)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.titleSizeAtNormal, weight: .semibold))
                .foregroundStyle(.primary)

            Text(presentation.subtitle)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.subtitleSizeAtNormal))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: Layout.spacing)

            if isBulkPending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
            } else if let title = presentation.bulkActionTitle {
                Button(title, action: onBulkAction)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.actionSizeAtNormal, weight: .medium))
                    .disabled(isBulkDisabled)
                    .hoverTooltip(presentation.bulkActionAccessibilityLabel ?? title)
                    .accessibilityLabel(presentation.bulkActionAccessibilityLabel ?? title)
                    .accessibilityValue(isBulkDisabled ? "unavailable" : "available")
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(presentation.subtitle)")
    }
}

// MARK: - File row

/// One changed file: its status, its path, its line counts, and — where the section allows it — the
/// checkbox that stages or unstages it.
///
/// Also the sticky header for its own hunks, so a long diff always shows which file it belongs to.
struct AgentChangesFileRowView: View {
    let row: AgentChangesFileRow
    let isExpanded: Bool
    let showsCheckbox: Bool
    let isStagedForDisplay: Bool
    let pending: AgentChangesPanelViewModel.PendingStaging?
    let isMutationDisabled: Bool
    let viewedStatus: AgentChangesViewedStatus
    let pendingResolution: AgentChangesPanelViewModel.PendingResolution?
    let pendingPartial: AgentChangesPanelViewModel.PendingPartialMutation?
    let markResolvedDisabledReason: String?
    let isFlashing: Bool
    let pathSearchMatches: [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onToggleExpansion: () -> Void
    let onSetStaged: (Bool) -> Void
    let onSetViewed: (Bool) -> Void
    let onMarkResolved: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showsResolveConfirmation = false

    private enum Layout {
        static let spacing: CGFloat = 5
        static let pathSizeAtNormal: CGFloat = 11
        static let statSizeAtNormal: CGFloat = 10
        static let disclosureSizeAtNormal: CGFloat = 9
        static let disclosureWidthAtNormal: CGFloat = 12
        static let horizontalPadding: CGFloat = 4
        static let verticalPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 5
        static let hoverOpacity: Double = 0.08
        static let flashOpacity: Double = 0.22
        static let disclosureRotation: Double = 90
        static let disclosureDuration: Double = 0.15
        static let viewedSecondaryOpacity: Double = 0.55
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var presentation: AgentChangesRowPresentation {
        AgentChangesRowPresentation(row: row)
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            disclosure
                .opacity(isViewed ? Layout.viewedSecondaryOpacity : 1)

            if showsCheckbox {
                AgentChangesStagingCheckbox(
                    row: row,
                    isStagedForDisplay: isStagedForDisplay,
                    showsSpinner: pending?.showsSpinner == true,
                    isDisabled: isMutationDisabled,
                    onSetStaged: onSetStaged
                )
                .opacity(isViewed ? Layout.viewedSecondaryOpacity : 1)
            }

            AgentChangesStatusBadge(status: presentation.status)
                .opacity(isViewed ? Layout.viewedSecondaryOpacity : 1)

            path

            Spacer(minLength: Layout.spacing)

            if row.isConflicted {
                AgentChangesMarkResolvedButton(
                    row: row,
                    showsSpinner: pendingResolution?.showsSpinner == true,
                    disabledReason: markResolvedDisabledReason,
                    onRequestConfirmation: { showsResolveConfirmation = true }
                )
            }

            if let pendingPartial {
                AgentChangesPartialPendingIndicator(row: row, pending: pendingPartial)
            }

            stats
                .opacity(isViewed ? Layout.viewedSecondaryOpacity : 1)

            AgentChangesViewedButton(
                row: row,
                status: viewedStatus,
                onSetViewed: { viewed in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Layout.disclosureDuration)) {
                        onSetViewed(viewed)
                    }
                }
            )
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        // Opaque backing under the row's own tint: this view is a pinned section header, and a
        // transparent one would let the hunks it is standing in front of scroll through it.
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpansion)
        .onHover { isHovered = $0 }
        .hoverTooltip(presentation.tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .confirmationDialog(
            "Mark \(row.path) resolved?",
            isPresented: $showsResolveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark Resolved", action: onMarkResolved)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks \(row.path) as resolved by staging its current contents.")
        }
    }

    private var isViewed: Bool {
        viewedStatus == .viewed
    }

    // MARK: - Pieces

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: preset.scaledMetric(Layout.disclosureSizeAtNormal), weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? Layout.disclosureRotation : 0))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: Layout.disclosureDuration),
                value: isExpanded
            )
            .frame(width: preset.scaledMetric(Layout.disclosureWidthAtNormal))
            .accessibilityHidden(true)
    }

    /// Directory dimmed, name at full strength, truncated in the middle.
    ///
    /// One concatenated `Text` rather than an `HStack` so truncation is decided for the path as a
    /// whole: two separate labels would each truncate on their own and could hide the file name to
    /// keep showing a directory nobody needed.
    private var path: some View {
        Text(attributedPath)
            .font(preset.swiftUIFont(sizeAtNormal: Layout.pathSizeAtNormal))
            .lineLimit(1)
            .truncationMode(.middle)
            .overlay(AgentChangesSearchAnchorOverlay(matches: pathSearchMatches))
            .accessibilityHidden(true)
    }

    private var attributedPath: AttributedString {
        let highlights = pathSearchMatches.map {
            AgentChangesSearchHighlight(
                utf16Range: $0.utf16Range,
                isCurrent: isCurrentSearchMatch($0)
            )
        }
        var attributed = AgentChangesHighlightedText.make(
            row.path,
            searchHighlights: highlights,
            searchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: false,
                colorScheme: colorScheme
            ),
            currentSearchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: true,
                colorScheme: colorScheme
            )
        )
        let directoryEnd = presentation.directory.utf16.count
        if directoryEnd > 0,
           let range = AgentChangesHighlightedText.attributedRange(
               0 ..< directoryEnd,
               text: row.path,
               attributed: attributed
           )
        {
            attributed[range].foregroundColor = .secondary.opacity(0.7)
        }
        if directoryEnd < row.path.utf16.count,
           let range = AgentChangesHighlightedText.attributedRange(
               directoryEnd ..< row.path.utf16.count,
               text: row.path,
               attributed: attributed
           )
        {
            attributed[range].foregroundColor = .primary
        }
        return attributed
    }

    @ViewBuilder
    private var stats: some View {
        if presentation.additionsText != nil || presentation.deletionsText != nil {
            HStack(spacing: Layout.spacing) {
                if let additions = presentation.additionsText {
                    Text(additions).foregroundStyle(.green)
                }
                if let deletions = presentation.deletionsText {
                    Text(deletions).foregroundStyle(.red)
                }
            }
            .font(preset.swiftUIFont(sizeAtNormal: Layout.statSizeAtNormal, weight: .medium))
            .monospacedDigit()
            .accessibilityHidden(true)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
            .fill(backgroundColor)
            .animation(reduceMotion ? nil : .easeOut(duration: Layout.disclosureDuration), value: isFlashing)
    }

    private var backgroundColor: Color {
        if isFlashing { return Color.accentColor.opacity(Layout.flashOpacity) }
        if isHovered { return Color.secondary.opacity(Layout.hoverOpacity) }
        return .clear
    }
}

// MARK: - Partial pending and search anchors

private struct AgentChangesPartialPendingIndicator: View {
    let row: AgentChangesFileRow
    let pending: AgentChangesPanelViewModel.PendingPartialMutation

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let glyphSizeAtNormal: CGFloat = 9
        static let frameSizeAtNormal: CGFloat = 16
        static let progressScale: CGFloat = 0.45
    }

    private var label: String {
        let verb = pending.action == .stage ? "Staging" : "Unstaging"
        switch pending.selectionKind {
        case .hunk: return "\(verb) a hunk in \(row.path)"
        case let .lines(count): return "\(verb) \(count) selected lines in \(row.path)"
        }
    }

    var body: some View {
        Group {
            if pending.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
            } else {
                Image(systemName: pending.action == .stage ? "arrow.down.to.line" : "arrow.up.to.line")
                    .font(.system(
                        size: fontScale.preset.scaledMetric(Layout.glyphSizeAtNormal),
                        weight: .medium
                    ))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(
            width: fontScale.preset.scaledMetric(Layout.frameSizeAtNormal),
            height: fontScale.preset.scaledMetric(Layout.frameSizeAtNormal)
        )
        .hoverTooltip(label)
        .accessibilityLabel(label)
    }
}

/// Zero-size IDs colocated with the visible match target. Multiple occurrences in one displayed
/// string share a scroll position but retain distinct navigation identity.
struct AgentChangesSearchAnchorOverlay: View {
    let matches: [AgentChangesSearchMatch]

    var body: some View {
        ZStack {
            ForEach(matches) { match in
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(match.id)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Viewed and resolution actions

private struct AgentChangesViewedButton: View {
    let row: AgentChangesFileRow
    let status: AgentChangesViewedStatus
    let onSetViewed: (Bool) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let sizeAtNormal: CGFloat = 10
        static let buttonSizeAtNormal: CGFloat = 18
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var isViewed: Bool {
        status == .viewed
    }

    private var accessibilityLabel: String {
        switch status {
        case .notViewed:
            "Mark \(row.path) viewed"
        case .viewed:
            "Mark \(row.path) not viewed"
        case .editedSinceViewed:
            "Viewed, edited since — review \(row.path) again"
        }
    }

    var body: some View {
        Button { onSetViewed(!isViewed) } label: {
            Image(systemName: isViewed ? "eye.fill" : "eye")
                .font(.system(size: preset.scaledMetric(Layout.sizeAtNormal), weight: .medium))
                .foregroundStyle(status == .editedSinceViewed ? Color.orange : Color.secondary)
                .frame(
                    width: preset.scaledMetric(Layout.buttonSizeAtNormal),
                    height: preset.scaledMetric(Layout.buttonSizeAtNormal)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isViewed ? "viewed" : "not viewed")
    }
}

private struct AgentChangesMarkResolvedButton: View {
    let row: AgentChangesFileRow
    let showsSpinner: Bool
    let disabledReason: String?
    let onRequestConfirmation: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let textSizeAtNormal: CGFloat = 9.5
        static let progressScale: CGFloat = 0.5
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Group {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
            } else {
                Button("Mark resolved", action: onRequestConfirmation)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.textSizeAtNormal, weight: .medium))
                    .disabled(disabledReason != nil)
            }
        }
        .fixedSize()
        .hoverTooltip(
            disabledReason ?? "Marks \(row.path) resolved by staging its current contents"
        )
        .accessibilityLabel("Mark \(row.path) resolved")
        .accessibilityValue(
            showsSpinner ? "in progress" : (disabledReason == nil ? "available" : "unavailable")
        )
        .accessibilityHint(disabledReason ?? "Stages the file's current contents after confirmation")
    }
}

// MARK: - Status badge

/// Git's own status letter, in Git's own vocabulary.
struct AgentChangesStatusBadge: View {
    let status: AgentChangesFileStatusKind

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let sizeAtNormal: CGFloat = 10
        static let widthAtNormal: CGFloat = 13
        static let heightAtNormal: CGFloat = 13
        static let cornerRadius: CGFloat = 3
        static let backgroundOpacity: Double = 0.15
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Text(status.letter)
            .font(.system(size: preset.scaledMetric(Layout.sizeAtNormal), weight: .bold, design: .monospaced))
            .foregroundStyle(status.tint)
            .frame(
                width: preset.scaledMetric(Layout.widthAtNormal),
                height: preset.scaledMetric(Layout.heightAtNormal)
            )
            .background(
                RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                    .fill(status.tint.opacity(Layout.backgroundOpacity))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Staging checkbox

/// The index-mutating control.
///
/// Three rules from decision row 8 live here. It shows the state the user *asked for* while the
/// mutation runs, so a click registers instantly without the row optimistically jumping to another
/// section. It grows a spinner only once the mutation outlives its grace period. And on a
/// conflicted row it is present but inert, because `git add` on an unmerged path records the
/// conflict markers as resolved content — the control has to be visibly refused, not quietly
/// missing.
struct AgentChangesStagingCheckbox: View {
    let row: AgentChangesFileRow
    let isStagedForDisplay: Bool
    let showsSpinner: Bool
    let isDisabled: Bool
    let onSetStaged: (Bool) -> Void

    private enum Layout {
        static let progressScale: CGFloat = 0.5
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isStagedForDisplay },
            set: { onSetStaged($0) }
        )
    }

    private var accessibilityLabel: String {
        isStagedForDisplay ? "Unstage \(row.path)" : "Stage \(row.path)"
    }

    private var tooltip: String {
        if row.isConflicted {
            return "Resolve this conflict before staging it. Staging an unmerged file would record its conflict markers as resolved content."
        }
        return isStagedForDisplay ? "Unstage \(row.path)" : "Stage \(row.path)"
    }

    var body: some View {
        ZStack {
            Toggle("", isOn: binding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isDisabled)
                .opacity(showsSpinner ? 0 : 1)

            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
            }
        }
        .hoverTooltip(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isStagedForDisplay ? "staged" : "not staged")
    }
}
