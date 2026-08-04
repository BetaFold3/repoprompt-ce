import AppKit
import SwiftUI

/// The Changes segment: fixed global compare/search chrome, one ordered multi-repository list, and
/// an aggregate footer. All row actions are checkout-qualified at the call site.
struct AgentChangesPanelView: View {
    @ObservedObject var viewModel: AgentChangesPanelViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchFocusRequest = 0
    @State private var searchResignRequest = 0

    private enum Layout {
        static let chromeSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let listBottomPadding: CGFloat = 8
        static let emptyStateTopPadding: CGFloat = 4
        static let groupTopPadding: CGFloat = 5
        static let navigationDuration: Double = 0.16
    }

    /// One flat sequence keeps only the most recent repository/section/file header pinned. That
    /// avoids stacked sticky chrome while preserving group order and file identity through a patch.
    private enum Entry: Identifiable {
        case group(AgentChangesGroupState)
        case section(AgentChangesGroupID, AgentChangesSection)
        case file(AgentChangesGroupID, AgentChangesFileRow)
        case groupEmpty(AgentChangesGroupState, AgentChangesEmptyState)
        case filteredEmpty(AgentChangesGroupID, String)
        case blocked(AgentPanelBlockedCheckout)

        var id: String {
            switch self {
            case let .group(group):
                "group:\(group.id.targetKey)"
            case let .section(groupID, section):
                "section:\(groupID.targetKey):\(section.id)"
            case let .file(groupID, row):
                "file:\(groupID.targetKey):\(row.id)"
            case let .groupEmpty(group, state):
                "empty:\(group.id.targetKey):\(String(describing: state))"
            case let .filteredEmpty(groupID, message):
                "filtered:\(groupID.targetKey):\(message)"
            case let .blocked(blocked):
                "blocked:\(blocked.logicalRoot.path)"
            }
        }
    }

    private var orderedEntries: [Entry] {
        guard let resolution = viewModel.resolution else { return [] }
        let groupsByID = Dictionary(uniqueKeysWithValues: viewModel.groups.map { ($0.id, $0) })
        var entries: [Entry] = []

        for item in resolution.items {
            switch item {
            case let .blocked(blocked):
                entries.append(.blocked(blocked))
            case let .resolved(target):
                let groupID = AgentChangesGroupID(target: target)
                guard let group = groupsByID[groupID] else { continue }
                entries.append(.group(group))

                if let emptyState = viewModel.emptyState(for: groupID) {
                    entries.append(.groupEmpty(group, emptyState))
                } else if let message = viewModel.filteredEmptyMessage(for: groupID) {
                    entries.append(.filteredEmpty(groupID, message))
                } else {
                    for section in viewModel.visibleSections(for: groupID) {
                        entries.append(.section(groupID, section))
                        entries.append(contentsOf: section.rows.map { .file(groupID, $0) })
                    }
                }
            }
        }
        return entries
    }

    private var globalEmptyState: AgentChangesEmptyState? {
        guard let resolution = viewModel.resolution else { return .loading }
        return resolution.items.isEmpty ? .noWorkspaceRoot : nil
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
                    summary: viewModel.footerSummary,
                    viewedProgress: viewModel.viewedProgress,
                    isRefreshing: viewModel.isRefreshing,
                    statusMessage: viewModel.statusMessage,
                    onRefresh: { viewModel.refresh() },
                    onDismissMessage: { viewModel.dismissStatusMessage() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                AgentChangesPanelKeyCommandBridge(
                    isSearchActive: !viewModel.searchState.query.isEmpty,
                    onFocusSearch: { searchFocusRequest &+= 1 },
                    onNext: { viewModel.selectNextSearchMatch() },
                    onPrevious: { viewModel.selectPreviousSearchMatch() },
                    onEscape: clearSearchAndResign
                )
            }
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

    private func clearSearchAndResign() {
        viewModel.clearSearch()
        searchResignRequest &+= 1
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
                diffViewMode: viewModel.panel.diffViewMode,
                isSplitViewAvailable: isSplitViewAvailable,
                onSelectCompare: { viewModel.selectCompare($0) },
                onSelectDiffViewMode: { viewModel.selectDiffViewMode($0) }
            )

            if viewModel.showsFilterPills {
                AgentChangesFilterPillsView(
                    filters: viewModel.availableFilters,
                    selected: viewModel.activeFilter,
                    counts: viewModel.filterCounts,
                    onSelect: { viewModel.selectFilter($0) }
                )
            }

            AgentChangesSearchBarView(
                state: viewModel.searchState,
                focusRequest: searchFocusRequest,
                resignRequest: searchResignRequest,
                onUpdateQuery: { viewModel.updateSearchQuery($0) },
                onNext: { viewModel.selectNextSearchMatch() },
                onPrevious: { viewModel.selectPreviousSearchMatch() },
                onClearAndResign: clearSearchAndResign
            )
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.chromeSpacing)
    }

    // MARK: - Ordered list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let globalEmptyState {
                        AgentChangesEmptyStateView(
                            state: globalEmptyState,
                            baseRevisionCandidates: [],
                            onCompareAgainstBase: { viewModel.selectCompare(.vsBase) },
                            onSelectBaseRevision: { _ in },
                            onSelectCustomRevision: {},
                            onRetry: { viewModel.refresh() }
                        )
                        .padding(.top, Layout.emptyStateTopPadding)
                    } else {
                        ForEach(orderedEntries) { entry in
                            entryView(entry)
                        }
                    }
                }
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.bottom, Layout.listBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.searchNavigationAnchor) { _, anchor in
                guard let anchor else { return }
                if reduceMotion {
                    proxy.scrollTo(anchor.matchID, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: Layout.navigationDuration)) {
                        proxy.scrollTo(anchor.matchID, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case let .group(group):
            Section {
                EmptyView()
            } header: {
                groupHeader(group)
                    .padding(.top, Layout.groupTopPadding)
            }
        case let .section(groupID, section):
            Section {
                EmptyView()
            } header: {
                sectionHeader(section, groupID: groupID)
            }
        case let .file(groupID, row):
            Section {
                fileBody(row, groupID: groupID)
            } header: {
                fileHeader(row, groupID: groupID)
            }
        case let .groupEmpty(group, state):
            AgentChangesEmptyStateView(
                state: state,
                baseRevisionCandidates: viewModel.baseCandidates(for: group.id),
                onCompareAgainstBase: { viewModel.selectCompare(.vsBase) },
                onSelectBaseRevision: { viewModel.selectBaseRevision($0, for: group.id) },
                onSelectCustomRevision: { viewModel.beginCustomRevisionEntry(for: group.id) },
                onRetry: { viewModel.refresh() }
            )
            .padding(.top, Layout.emptyStateTopPadding)
        case let .filteredEmpty(_, message):
            Text(message)
                .font(fontScale.preset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Layout.emptyStateTopPadding + 10)
                .accessibilityLabel(message)
        case let .blocked(blocked):
            AgentChangesBlockedCheckoutCard(
                blocked: blocked,
                onShowWorkspaceCheckout: {
                    viewModel.showWorkspaceCheckoutInstead(for: blocked)
                }
            )
            .padding(.top, Layout.groupTopPadding)
        }
    }

    private func groupHeader(_ group: AgentChangesGroupState) -> some View {
        AgentChangesGroupHeaderView(
            group: group,
            compareSelection: viewModel.panel.compareSelection,
            customRevisionEditor: viewModel.customRevisionEditor,
            onSelectBaseRevision: { viewModel.selectBaseRevision($0, for: group.id) },
            onBeginCustomRevision: { viewModel.beginCustomRevisionEntry(for: group.id) },
            onUpdateCustomRevision: { viewModel.updateCustomRevisionText($0) },
            onSubmitCustomRevision: { viewModel.submitCustomRevision() },
            onCancelCustomRevision: { viewModel.cancelCustomRevisionEntry() }
        )
    }

    private func sectionHeader(
        _ section: AgentChangesSection,
        groupID: AgentChangesGroupID
    ) -> some View {
        AgentChangesSectionHeaderView(
            section: section,
            supportsStaging: viewModel.groupState(for: groupID)?.snapshot.supportsStaging == true,
            isBulkDisabled: viewModel.isBulkActionDisabled(for: section.kind, in: groupID),
            isBulkPending: viewModel.isBulkActionPending(for: section.kind, in: groupID),
            onBulkAction: {
                viewModel.applyBulkStaging(
                    section.kind == .unstaged,
                    section: section.kind,
                    in: groupID
                )
            }
        )
    }

    private func fileHeader(
        _ row: AgentChangesFileRow,
        groupID: AgentChangesGroupID
    ) -> some View {
        AgentChangesFileRowView(
            row: row,
            isExpanded: viewModel.isExpanded(row, in: groupID),
            showsCheckbox: viewModel.showsStagingCheckbox(for: row, in: groupID),
            isStagedForDisplay: viewModel.isStagedForDisplay(row, in: groupID),
            pending: viewModel.pendingStaging(for: row, in: groupID),
            isMutationDisabled: viewModel.isMutationDisabled(row, in: groupID),
            viewedStatus: viewModel.viewedStatus(for: row, in: groupID),
            pendingResolution: viewModel.pendingResolution(for: row, in: groupID),
            pendingPartial: viewModel.pendingPartial(for: row, in: groupID),
            markResolvedDisabledReason: viewModel.markResolvedDisabledReason(
                for: row,
                in: groupID
            ),
            isFlashing: viewModel.isFlashing(row, in: groupID),
            pathSearchMatches: viewModel.searchMatches(
                for: row,
                in: groupID,
                locator: .filePath
            ),
            isCurrentSearchMatch: { viewModel.isCurrentSearchMatch($0) },
            onToggleExpansion: { viewModel.toggleExpansion(row, in: groupID) },
            onSetStaged: { viewModel.setStaged($0, row: row, in: groupID) },
            onSetViewed: { viewModel.setViewed($0, for: row, in: groupID) },
            onMarkResolved: { viewModel.markResolved(row, in: groupID) }
        )
    }

    @ViewBuilder
    private func fileBody(
        _ row: AgentChangesFileRow,
        groupID: AgentChangesGroupID
    ) -> some View {
        if viewModel.isExpanded(row, in: groupID) {
            AgentChangesPatchView(
                row: row,
                state: viewModel.patchState(for: row, in: groupID),
                diffViewMode: viewModel.panel.diffViewMode,
                gapContextState: viewModel.gapContextState(for: row, in: groupID),
                partialDescriptor: viewModel.partialDescriptor(for: row, in: groupID),
                pendingPartial: viewModel.pendingPartial(for: row, in: groupID),
                isPartialMutationDisabled: viewModel.isPartialMutationDisabled(
                    for: row,
                    in: groupID
                ),
                selectedPartialLineKeys: {
                    viewModel.selectedPartialLineKeys(
                        for: row,
                        hunkID: $0,
                        in: groupID
                    )
                },
                searchMatches: {
                    viewModel.searchMatches(for: row, in: groupID, locator: $0)
                },
                isCurrentSearchMatch: { viewModel.isCurrentSearchMatch($0) },
                onSetPartialLineSelected: { selected, key, hunkID in
                    viewModel.setPartialLineSelected(
                        selected,
                        lineKey: key,
                        hunkID: hunkID,
                        row: row,
                        in: groupID
                    )
                },
                onClearPartialSelection: {
                    viewModel.clearPartialSelection(for: row, hunkID: $0, in: groupID)
                },
                onApplyPartialHunk: {
                    viewModel.applyPartialHunk(for: row, hunkID: $0, in: groupID)
                },
                onApplySelectedPartialLines: {
                    viewModel.applySelectedPartialLines(for: row, hunkID: $0, in: groupID)
                },
                onExpandGap: { gap, amount in
                    viewModel.expandContextGap(
                        gap,
                        amount: amount,
                        for: row,
                        in: groupID
                    )
                },
                onOpenFile: { openFile(row, groupID: groupID) }
            )
        }
    }

    /// Opens relative to the row's own checkout, never whichever group happened to publish first.
    private func openFile(
        _ row: AgentChangesFileRow,
        groupID: AgentChangesGroupID
    ) {
        guard let checkout = viewModel.groupState(for: groupID)?.target.checkoutURL else { return }
        NSWorkspace.shared.open(checkout.appendingPathComponent(row.path))
    }
}

// MARK: - Footer

/// Aggregate totals, oldest-success freshness, refresh, and the panel's mutation message surface.
struct AgentChangesFooterView: View {
    let summary: AgentChangesPanelViewModel.FooterSummary
    let viewedProgress: AgentChangesViewedProgress
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
        static let progressScale: CGFloat = 0.5
        static let separatorOpacity: Double = 0.15
        static let viewedBarHeight: CGFloat = 2
        static let viewedBarBackgroundOpacity: Double = 0.12
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.messageSpacing) {
            Divider().opacity(Layout.separatorOpacity)

            if let statusMessage {
                messageRow(statusMessage)
            }

            if viewedProgress.totalFileCount > 0 {
                viewedProgressRow
            }

            HStack(spacing: Layout.rowSpacing) {
                Text(AgentChangesFooterPresentation.totals(
                    fileCount: summary.fileCount,
                    additions: summary.additions,
                    deletions: summary.deletions
                ))
                .font(preset.swiftUIFont(sizeAtNormal: Layout.totalsSizeAtNormal, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

                Spacer(minLength: Layout.rowSpacing)

                if summary.isPollingDegraded {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal)))
                        .foregroundStyle(.orange)
                        .hoverTooltip("At least one checkout cannot be watched and is being polled.")
                        .accessibilityLabel("File watching unavailable for at least one checkout")
                }

                Text(AgentChangesFooterPresentation.lastRefreshed(
                    summary.lastRefreshedAt,
                    now: Date()
                ))
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
            .hoverTooltip("Dismiss changes message")
            .accessibilityLabel("Dismiss message")
            .accessibilityValue(message.isFailure ? "failure" : "information")
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
        .accessibilityValue(isRefreshing ? "refreshing" : "ready")
    }
}
