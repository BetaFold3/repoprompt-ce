import AppKit
import SwiftUI

/// The Changes segment.
///
/// Three bands: fixed chrome that says what is being compared, a scrolling file list, and a fixed
/// footer that says how much and how fresh. The header and footer do not scroll because both answer
/// questions about the list as a whole — a diff read without its compare mode in view is a diff
/// that can be misread, and a refresh control that has scrolled away is a control the user cannot
/// find at the moment they doubt what they are seeing.
struct AgentChangesPanelView: View {
    @ObservedObject var viewModel: AgentChangesPanelViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let chromeSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let listBottomPadding: CGFloat = 8
        static let emptyStateTopPadding: CGFloat = 4
    }

    /// The list flattened into one sequence of pinned sections.
    ///
    /// Section headers and file headers share one level on purpose: SwiftUI pins the most recent
    /// section header, so a flat sequence gives exactly the behavior the design asks for — the
    /// group header sticks until the first file arrives, then each file header sticks while its own
    /// hunks scroll past. Nesting sections would pin two headers on top of each other instead.
    private enum Entry: Identifiable {
        case section(AgentChangesSection)
        case file(AgentChangesFileRow)

        var id: String {
            switch self {
            case let .section(section): "section:\(section.id)"
            case let .file(row): "file:\(row.id)"
            }
        }
    }

    private var entries: [Entry] {
        viewModel.visibleSections.flatMap { section in
            [Entry.section(section)] + section.rows.map(Entry.file)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let splitAvailable = AgentUtilityPanelLayoutMetrics.supportsSplitDiff(
                effectiveDiffWidth: proxy.size.width
            )
            VStack(spacing: 0) {
                chrome(isSplitViewAvailable: splitAvailable)
                list
                AgentChangesFooterView(
                    snapshot: viewModel.snapshot,
                    viewedProgress: viewModel.viewedProgress,
                    lastRefreshedAt: viewModel.lastRefreshedAt,
                    isRefreshing: viewModel.isRefreshing,
                    statusMessage: viewModel.statusMessage,
                    onRefresh: { viewModel.refresh() },
                    onDismissMessage: { viewModel.dismissStatusMessage() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                enforceWidthGate(isSplitViewAvailable: splitAvailable)
            }
            .onChange(of: splitAvailable) { _, available in
                enforceWidthGate(isSplitViewAvailable: available)
            }
        }
    }

    private func enforceWidthGate(isSplitViewAvailable: Bool) {
        if !isSplitViewAvailable, viewModel.panel.diffViewMode == .split {
            viewModel.selectDiffViewMode(.unified)
        }
    }

    // MARK: - Chrome

    private func chrome(isSplitViewAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Layout.chromeSpacing) {
            if let link = viewModel.bannerLink {
                AgentArtifactBannerView(
                    artifact: link.artifact,
                    onView: { viewModel.viewBannerArtifact() },
                    onDismiss: { viewModel.dismissBannerArtifact() }
                )
            }

            AgentChangesHeaderView(
                compareSelection: viewModel.panel.compareSelection,
                baseBranch: viewModel.panel.baseBranchOverride,
                baseBranchCandidates: viewModel.baseBranchCandidates,
                targets: viewModel.availableTargets,
                activeTarget: viewModel.activeTarget,
                diffViewMode: viewModel.panel.diffViewMode,
                isSplitViewAvailable: isSplitViewAvailable,
                customRevisionEditor: viewModel.customRevisionEditor,
                onSelectCompare: { viewModel.selectCompare($0) },
                onSelectDiffViewMode: { viewModel.selectDiffViewMode($0) },
                onSelectBaseBranch: { viewModel.selectBaseBranch($0) },
                onBeginCustomRevision: { viewModel.beginCustomRevisionEntry() },
                onUpdateCustomRevision: { viewModel.updateCustomRevisionText($0) },
                onSubmitCustomRevision: { viewModel.submitCustomRevision() },
                onCancelCustomRevision: { viewModel.cancelCustomRevisionEntry() },
                onSelectRoot: { viewModel.selectRoot($0) }
            )

            if viewModel.showsFilterPills {
                AgentChangesFilterPillsView(
                    filters: viewModel.availableFilters,
                    selected: viewModel.activeFilter,
                    counts: viewModel.filterCounts,
                    onSelect: { viewModel.selectFilter($0) }
                )
            }

            ForEach(viewModel.blockedCheckouts) { blocked in
                AgentChangesBlockedCheckoutCard(
                    blocked: blocked,
                    onShowWorkspaceCheckout: { viewModel.showWorkspaceCheckoutInstead(for: blocked) }
                )
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.chromeSpacing)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let emptyState = viewModel.emptyState {
                    AgentChangesEmptyStateView(
                        state: emptyState,
                        baseBranchCandidates: viewModel.baseBranchCandidates,
                        onCompareAgainstBase: { viewModel.offerBaseComparison() },
                        onSelectBaseBranch: { viewModel.selectBaseBranch($0) },
                        onSelectCustomRevision: { viewModel.beginCustomRevisionEntry() },
                        onRetry: { viewModel.refresh() }
                    )
                    .padding(.top, Layout.emptyStateTopPadding)
                } else if let filteredEmptyMessage = viewModel.filteredEmptyMessage {
                    Text(filteredEmptyMessage)
                        .font(fontScale.preset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Layout.emptyStateTopPadding + 12)
                        .accessibilityLabel(filteredEmptyMessage)
                } else {
                    ForEach(entries) { entry in
                        switch entry {
                        case let .section(section):
                            Section {
                                EmptyView()
                            } header: {
                                sectionHeader(section)
                            }
                        case let .file(row):
                            Section {
                                fileBody(row)
                            } header: {
                                fileHeader(row)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.bottom, Layout.listBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ section: AgentChangesSection) -> some View {
        AgentChangesSectionHeaderView(
            section: section,
            supportsStaging: viewModel.snapshot.supportsStaging,
            isBulkDisabled: viewModel.isBulkActionDisabled(for: section.kind),
            isBulkPending: viewModel.isBulkActionPending(for: section.kind),
            onBulkAction: {
                // Unstaged stages, Staged unstages: the action a section offers is the one that
                // moves its own rows out of it.
                viewModel.applyBulkStaging(section.kind == .unstaged, section: section.kind)
            }
        )
    }

    private func fileHeader(_ row: AgentChangesFileRow) -> some View {
        AgentChangesFileRowView(
            row: row,
            isExpanded: viewModel.isExpanded(row),
            showsCheckbox: viewModel.showsStagingCheckbox(for: row),
            isStagedForDisplay: viewModel.isStagedForDisplay(row),
            pending: viewModel.pendingStaging(for: row),
            isMutationDisabled: viewModel.isMutationDisabled(row),
            viewedStatus: viewModel.viewedStatus(for: row),
            pendingResolution: viewModel.pendingResolution(for: row),
            markResolvedDisabledReason: viewModel.markResolvedDisabledReason(for: row),
            isFlashing: viewModel.isFlashing(row),
            onToggleExpansion: { viewModel.toggleExpansion(row) },
            onSetStaged: { viewModel.setStaged($0, row: row) },
            onSetViewed: { viewModel.setViewed($0, for: row) },
            onMarkResolved: { viewModel.markResolved(row) }
        )
    }

    @ViewBuilder
    private func fileBody(_ row: AgentChangesFileRow) -> some View {
        if viewModel.isExpanded(row) {
            AgentChangesPatchView(
                row: row,
                state: viewModel.patchState(for: row),
                diffViewMode: viewModel.panel.diffViewMode,
                gapContextState: viewModel.gapContextState(for: row),
                onExpandGap: { gap, amount in
                    viewModel.expandContextGap(gap, amount: amount, for: row)
                },
                onOpenFile: { openFile(row) }
            )
        }
    }

    /// Opens the file itself, for the diffs the panel deliberately will not render inline.
    private func openFile(_ row: AgentChangesFileRow) {
        guard let checkout = viewModel.activeTarget?.checkoutURL else { return }
        NSWorkspace.shared.open(checkout.appendingPathComponent(row.path))
    }
}

// MARK: - Footer

/// Totals, freshness, refresh, and the panel's one error surface.
struct AgentChangesFooterView: View {
    let snapshot: AgentChangesSnapshot
    let viewedProgress: AgentChangesViewedProgress
    let lastRefreshedAt: Date?
    let isRefreshing: Bool
    let statusMessage: AgentChangesPanelViewModel.StatusMessage?
    let onRefresh: () -> Void
    let onDismissMessage: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let rowSpacing: CGFloat = 6
        static let messageSpacing: CGFloat = 5
        static let totalsSizeAtNormal: CGFloat = 10
        static let freshnessSizeAtNormal: CGFloat = 9.5
        static let messageSizeAtNormal: CGFloat = 10
        static let glyphSizeAtNormal: CGFloat = 10
        static let buttonSize: CGFloat = 22
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 6
        static let hoverFillOpacity: Double = 0.12
        static let progressScale: CGFloat = 0.5
        static let separatorOpacity: Double = 0.15
        static let viewedBarHeight: CGFloat = 2
        static let viewedBarBackgroundOpacity: Double = 0.12
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    /// A failed rebuild is surfaced here whenever there are still rows on screen; with no rows the
    /// empty state has already said it, and saying it twice would read as two failures.
    private var message: AgentChangesPanelViewModel.StatusMessage? {
        if let statusMessage { return statusMessage }
        if case let .failed(text) = snapshot.loadState, !snapshot.sections.allSatisfy(\.isEmpty) {
            return .failure(text)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.messageSpacing) {
            Divider().opacity(Layout.separatorOpacity)

            if let message {
                messageRow(message)
            }

            if viewedProgress.totalFileCount > 0 {
                viewedProgressRow
            }

            HStack(spacing: Layout.rowSpacing) {
                Text(AgentChangesFooterPresentation.totals(for: snapshot))
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.totalsSizeAtNormal, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Spacer(minLength: Layout.rowSpacing)

                if snapshot.isPollingDegraded {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal)))
                        .foregroundStyle(.orange)
                        .hoverTooltip("This checkout could not be watched, so it is being polled every few seconds.")
                        .accessibilityLabel("File watching unavailable; polling instead")
                }

                Text(AgentChangesFooterPresentation.lastRefreshed(lastRefreshedAt, now: Date()))
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.freshnessSizeAtNormal))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                refreshButton
            }
            .padding(.horizontal, Layout.horizontalPadding)
        }
        .padding(.bottom, Layout.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes summary")
    }

    private var viewedProgressRow: some View {
        VStack(alignment: .leading, spacing: Layout.messageSpacing) {
            Text("\(viewedProgress.viewedFileCount) of \(viewedProgress.totalFileCount) viewed")
                .font(preset.swiftUIFont(sizeAtNormal: Layout.freshnessSizeAtNormal, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(Layout.viewedBarBackgroundOpacity))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: proxy.size.width * viewedProgress.fraction)
                }
            }
            .frame(height: Layout.viewedBarHeight)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(viewedProgress.viewedFileCount) of \(viewedProgress.totalFileCount) files viewed"
        )
    }

    private func messageRow(_ message: AgentChangesPanelViewModel.StatusMessage) -> some View {
        HStack(alignment: .top, spacing: Layout.messageSpacing) {
            Image(systemName: message.isFailure ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle.fill")
                .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal)))
                .foregroundStyle(message.isFailure ? Color.orange : Color.accentColor)

            Text(message.text)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onDismissMessage) {
                Image(systemName: "xmark")
                    .font(.system(size: preset.scaledMetric(Layout.freshnessSizeAtNormal), weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.text)
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal), weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isRefreshing ? 0 : 1)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(Layout.progressScale)
                }
            }
            .frame(
                width: preset.scaledMetric(Layout.buttonSize),
                height: preset.scaledMetric(Layout.buttonSize)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .hoverTooltip("Refresh changes")
        .accessibilityLabel("Refresh changes")
    }
}
