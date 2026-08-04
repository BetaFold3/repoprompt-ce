import SwiftUI

/// One expanded file's diff body.
///
/// Unified and split layouts consume the same projection and partial-staging descriptor. Search and
/// intraline ranges are composed before rendering so search wins only on their overlap.
struct AgentChangesPatchView: View {
    let row: AgentChangesFileRow
    let state: AgentChangesPatchLoadState
    let diffViewMode: AgentChangesDiffViewMode
    let gapContextState: AgentChangesPanelViewModel.GapContextState
    let partialDescriptor: AgentChangesPartialStagingDescriptor?
    let pendingPartial: AgentChangesPanelViewModel.PendingPartialMutation?
    let isPartialMutationDisabled: Bool
    let selectedPartialLineKeys: (String) -> Set<AgentChangesDiffLineKey>
    let searchMatches: (AgentChangesSearchLocator) -> [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onSetPartialLineSelected: (Bool, AgentChangesDiffLineKey, String) -> Void
    let onClearPartialSelection: (String) -> Void
    let onApplyPartialHunk: (String) -> Void
    let onApplySelectedPartialLines: (String) -> Void
    let onExpandGap: (DiffContextSplicer.Gap, DiffContextSplicer.ExpansionAmount) -> Void
    let onOpenFile: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let blockSpacing: CGFloat = 4
        static let messageSizeAtNormal: CGFloat = 10
        static let horizontalPadding: CGFloat = 4
        static let verticalPadding: CGFloat = 4
        static let progressScale: CGFloat = 0.5
        static let noticeSpacing: CGFloat = 5
        static let expansionAnimationDuration: Double = 0.14
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.blockSpacing) {
            switch state {
            case .idle, .loading:
                loading
            case let .unavailable(reason):
                unavailable(reason)
            case let .loaded(document):
                loaded(document)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.verticalPadding)
    }

    // MARK: - States

    private var loading: some View {
        HStack(spacing: Layout.noticeSpacing) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(Layout.progressScale)
            Text("Loading diff\u{2026}")
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityLabel("Loading diff for \(row.path)")
    }

    private func unavailable(_ reason: AgentChangesPatchUnavailableReason) -> some View {
        notice(
            AgentChangesPatchPresentation.message(for: reason),
            actionTitle: AgentChangesPatchPresentation.offersOpenFile(for: reason) ? "Open File" : nil
        )
    }

    private func loaded(_ document: FileDiffProjection.Document) -> some View {
        VStack(alignment: .leading, spacing: Layout.blockSpacing) {
            if let summary = AgentChangesPatchPresentation.summary(for: document.change) {
                notice(summary, actionTitle: nil)
            }

            if let partialNotice {
                notice(partialNotice, actionTitle: nil, isSubdued: true)
            }

            let digits = AgentChangesPatchPresentation.maximumLineNumberDigits(in: document)
            let gaps: [DiffContextSplicer.Gap] = if gapContextState.unavailableReason == nil {
                DiffContextSplicer.gaps(
                    in: document,
                    sourceLineCount: gapContextState.sourceLineCount,
                    sourceSide: gapContextState.sourceSide
                )
            } else {
                []
            }

            if let before = gaps.first(where: { $0.location == .beforeFirst }) {
                gapView(before)
            }

            ForEach(document.hunks.indices, id: \.self) { index in
                hunkView(document.hunks[index], lineNumberDigits: digits)
                if let gap = gap(afterHunkAt: index, gaps: gaps) {
                    gapView(gap)
                }
            }

            if let reason = gapContextState.unavailableReason {
                notice(
                    AgentChangesPatchPresentation.message(for: reason),
                    actionTitle: AgentChangesPatchPresentation.offersOpenFile(for: reason)
                        ? "Open File"
                        : nil
                )
            }

            if let truncation = document.truncation {
                notice(
                    "\(truncation.omittedLines) more lines are not shown in the panel.",
                    actionTitle: "Open File"
                )
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Layout.expansionAnimationDuration),
            value: document.hunks
        )
    }

    private var partialNotice: String? {
        guard let partialDescriptor,
              case let .unavailable(reason) = partialDescriptor.availability
        else { return nil }
        return AgentChangesPartialStagingPresentation.unavailableMessage(for: reason)
    }

    private func hunkView(
        _ hunk: FileDiffProjection.Hunk,
        lineNumberDigits: Int
    ) -> some View {
        let availableAction: AgentChangesPartialAction? = {
            guard let partialDescriptor,
                  partialDescriptor.availability == .available,
                  partialDescriptor.changedLineKeysByHunkID[hunk.id]?.isEmpty == false
            else { return nil }
            return partialDescriptor.action
        }()
        // A hunk the repository withheld from line selection (a no-newline annotation makes partial
        // recombination unsafe) still shows its hunk action, just no per-line selection column.
        let selectableLineKeys = partialDescriptor.map {
            ($0.changedLineKeysByHunkID[hunk.id] ?? []).intersection($0.selectableChangedLineKeys)
        } ?? []
        return AgentChangesHunkView(
            hunk: hunk,
            lineNumberDigits: lineNumberDigits,
            diffViewMode: diffViewMode,
            partialAction: availableAction,
            selectableLineKeys: selectableLineKeys,
            selectedLineKeys: selectedPartialLineKeys(hunk.id),
            isPartialMutationDisabled: isPartialMutationDisabled || pendingPartial != nil,
            headingSearchMatches: searchMatches(.hunkHeading(hunkID: hunk.id)),
            lineSearchMatches: { line in
                searchMatches(.line(kind: line.kind, oldLine: line.oldLine, newLine: line.newLine))
            },
            isCurrentSearchMatch: isCurrentSearchMatch,
            onSetLineSelected: { selected, key in
                onSetPartialLineSelected(selected, key, hunk.id)
            },
            onClearSelection: { onClearPartialSelection(hunk.id) },
            onApplyHunk: { onApplyPartialHunk(hunk.id) },
            onApplySelectedLines: { onApplySelectedPartialLines(hunk.id) }
        )
    }

    private func gap(
        afterHunkAt index: Int,
        gaps: [DiffContextSplicer.Gap]
    ) -> DiffContextSplicer.Gap? {
        gaps.first { gap in
            switch gap.location {
            case let .between(leftHunkIndex, _):
                leftHunkIndex == index
            case .afterLast:
                index == (state.document?.hunks.count ?? 0) - 1
            case .beforeFirst:
                false
            }
        }
    }

    private func gapView(_ gap: DiffContextSplicer.Gap) -> some View {
        AgentChangesGapExpanderView(
            gap: gap,
            isLoading: gapContextState.loadingGapID == gap.id,
            onExpand: { onExpandGap(gap, $0) }
        )
    }

    private func notice(
        _ message: String,
        actionTitle: String?,
        isSubdued: Bool = false
    ) -> some View {
        HStack(spacing: Layout.noticeSpacing) {
            Text(message)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(isSubdued ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: onOpenFile)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
                    .hoverTooltip("\(actionTitle) \(row.path)")
                    .accessibilityLabel("\(actionTitle) \(row.path)")
                    .accessibilityValue("available")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Layout.verticalPadding)
    }
}

// MARK: - Gap expander

private struct AgentChangesGapExpanderView: View {
    let gap: DiffContextSplicer.Gap
    let isLoading: Bool
    let onExpand: (DiffContextSplicer.ExpansionAmount) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 8
        static let fontSizeAtNormal: CGFloat = 9.5
        static let verticalPadding: CGFloat = 3
        static let progressScale: CGFloat = 0.45
    }

    private var offersTwelve: Bool {
        gap.hiddenLineCount.map { $0 > 12 } ?? true
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.16))
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            separator
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
                    .accessibilityLabel("Expanding diff context")
            } else {
                if offersTwelve {
                    Button("Expand 12 lines") {
                        onExpand(.lines(12))
                    }
                    .hoverTooltip("Show 12 more lines of hidden context")
                    .accessibilityLabel("Expand 12 lines of hidden diff context")
                    .accessibilityValue("available")
                }
                Button("Expand all") {
                    onExpand(.all)
                }
                .hoverTooltip("Show all hidden context")
                .accessibilityLabel("Expand all hidden diff context")
                .accessibilityValue("available")
            }
            separator
        }
        .buttonStyle(.link)
        .font(fontScale.preset.swiftUIFont(
            sizeAtNormal: Layout.fontSizeAtNormal,
            weight: .medium
        ))
        .foregroundStyle(.secondary)
        .padding(.vertical, Layout.verticalPadding)
        .disabled(isLoading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hunk

struct AgentChangesHunkView: View {
    let hunk: FileDiffProjection.Hunk
    let lineNumberDigits: Int
    let diffViewMode: AgentChangesDiffViewMode
    let partialAction: AgentChangesPartialAction?
    let selectableLineKeys: Set<AgentChangesDiffLineKey>
    let selectedLineKeys: Set<AgentChangesDiffLineKey>
    let isPartialMutationDisabled: Bool
    let headingSearchMatches: [AgentChangesSearchMatch]
    let lineSearchMatches: (FileDiffProjection.Line) -> [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onSetLineSelected: (Bool, AgentChangesDiffLineKey) -> Void
    let onClearSelection: () -> Void
    let onApplyHunk: () -> Void
    let onApplySelectedLines: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHeaderHovered = false
    @FocusState private var isHeaderActionFocused: Bool

    private enum Layout {
        static let headerSpacing: CGFloat = 6
        static let headerHorizontalPadding: CGFloat = 4
        static let headerVerticalPadding: CGFloat = 3
        static let rangeSizeAtNormal: CGFloat = 9.5
        static let headingSizeAtNormal: CGFloat = 9.5
        static let actionSizeAtNormal: CGFloat = 9
        static let cornerRadius: CGFloat = 4
        static let bodyTopPadding: CGFloat = 1
        static let selectionRowSpacing: CGFloat = 7
        static let selectionRowVerticalPadding: CGFloat = 3
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var showsSelectionColumn: Bool {
        partialAction != nil && !selectableLineKeys.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 0) {
                switch diffViewMode {
                case .unified:
                    ForEach(hunk.lines) { line in
                        AgentChangesDiffLineView(
                            line: line,
                            lineNumberDigits: lineNumberDigits,
                            showsSelectionColumn: showsSelectionColumn,
                            selection: selection(for: line),
                            searchMatches: lineSearchMatches(line),
                            isCurrentSearchMatch: isCurrentSearchMatch,
                            onSetSelected: { selected in
                                guard let key = line.partialLineKey else { return }
                                onSetLineSelected(selected, key)
                            }
                        )
                    }
                case .split:
                    ForEach(SplitDiffRowProjector.rows(for: hunk)) { row in
                        AgentChangesSplitDiffRowView(
                            row: row,
                            lineNumberDigits: lineNumberDigits,
                            showsSelectionColumn: showsSelectionColumn,
                            selectionForLine: selection(for:),
                            searchMatchesForLine: lineSearchMatches,
                            isCurrentSearchMatch: isCurrentSearchMatch,
                            onSetLineSelected: onSetLineSelected
                        )
                    }
                }
            }
            .padding(.top, Layout.bodyTopPadding)
            .textSelection(.enabled)

            if let partialAction, !selectedLineKeys.isEmpty {
                selectedLinesActionRow(action: partialAction)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Layout.headerSpacing) {
            Text(AgentChangesPatchPresentation.rangeText(for: hunk))
                .font(.system(size: preset.scaledMetric(Layout.rangeSizeAtNormal), design: .monospaced))
                .foregroundStyle(.tertiary)

            if let heading = hunk.heading, !heading.isEmpty {
                Text(highlightedHeading(heading))
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.headingSizeAtNormal, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .overlay(AgentChangesSearchAnchorOverlay(matches: headingSearchMatches))
            }

            Spacer(minLength: Layout.headerSpacing)

            if let partialAction {
                Button(
                    AgentChangesPartialStagingPresentation.actionTitle(partialAction, noun: "hunk"),
                    action: onApplyHunk
                )
                .buttonStyle(.plain)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.actionSizeAtNormal, weight: .medium))
                .foregroundStyle(.secondary)
                .focused($isHeaderActionFocused)
                .opacity(isHeaderHovered || isHeaderActionFocused ? 1 : 0)
                .disabled(isPartialMutationDisabled)
                .hoverTooltip(
                    AgentChangesPartialStagingPresentation.actionTitle(partialAction, noun: "this hunk")
                )
                .accessibilityLabel(
                    AgentChangesPartialStagingPresentation.actionTitle(partialAction, noun: "hunk")
                )
                .accessibilityValue(isPartialMutationDisabled ? "unavailable" : "available on hover")
            }
        }
        .padding(.horizontal, Layout.headerHorizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(AgentChangesDiffPalette.hunkHeaderBackground(colorScheme: colorScheme))
        )
        .onHover { isHeaderHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private func highlightedHeading(_ heading: String) -> AttributedString {
        AgentChangesHighlightedText.make(
            heading,
            searchHighlights: headingSearchMatches.map {
                AgentChangesSearchHighlight(
                    utf16Range: $0.utf16Range,
                    isCurrent: isCurrentSearchMatch($0)
                )
            },
            searchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: false,
                colorScheme: colorScheme
            ),
            currentSearchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: true,
                colorScheme: colorScheme
            )
        )
    }

    private func selection(for line: FileDiffProjection.Line) -> AgentChangesLineSelection? {
        guard let partialAction,
              let key = line.partialLineKey,
              selectableLineKeys.contains(key)
        else { return nil }
        return AgentChangesLineSelection(
            key: key,
            action: partialAction,
            isSelected: selectedLineKeys.contains(key),
            isDisabled: isPartialMutationDisabled
        )
    }

    private func selectedLinesActionRow(action: AgentChangesPartialAction) -> some View {
        HStack(spacing: Layout.selectionRowSpacing) {
            Spacer(minLength: 0)
            Button(
                AgentChangesPartialStagingPresentation.selectedLinesTitle(
                    action,
                    count: selectedLineKeys.count
                ),
                action: onApplySelectedLines
            )
            .buttonStyle(.link)
            .font(preset.swiftUIFont(sizeAtNormal: Layout.actionSizeAtNormal, weight: .medium))
            .disabled(isPartialMutationDisabled)
            .hoverTooltip(
                AgentChangesPartialStagingPresentation.selectedLinesTitle(
                    action,
                    count: selectedLineKeys.count
                )
            )
            .accessibilityLabel(
                AgentChangesPartialStagingPresentation.selectedLinesTitle(
                    action,
                    count: selectedLineKeys.count
                )
            )
            .accessibilityValue(isPartialMutationDisabled ? "unavailable" : "available")

            Button("Clear", action: onClearSelection)
                .buttonStyle(.plain)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.actionSizeAtNormal))
                .foregroundStyle(.tertiary)
                .disabled(isPartialMutationDisabled)
                .hoverTooltip("Clear selected lines in this hunk")
                .accessibilityLabel("Clear selected lines in this hunk")
                .accessibilityValue(isPartialMutationDisabled ? "unavailable" : "available")
        }
        .padding(.vertical, Layout.selectionRowVerticalPadding)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Unified line

struct AgentChangesDiffLineView: View {
    let line: FileDiffProjection.Line
    let lineNumberDigits: Int
    let showsSelectionColumn: Bool
    let selection: AgentChangesLineSelection?
    let searchMatches: [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onSetSelected: (Bool) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let columnSpacing: CGFloat = 6
        static let markerSpacing: CGFloat = 4
        static let verticalPadding: CGFloat = 0.5
        static let leadingPadding: CGFloat = 4
        static let trailingPadding: CGFloat = 4
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var font: Font {
        .system(
            size: preset.scaledMetric(AgentChangesDiffMetrics.lineFontSizeAtNormal),
            design: .monospaced
        )
    }

    private var gutterWidth: CGFloat {
        AgentChangesDiffMetrics.gutterWidth(digits: lineNumberDigits, preset: preset)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            if showsSelectionColumn {
                AgentChangesLineSelectionButton(
                    line: line,
                    selection: selection,
                    onSetSelected: onSetSelected
                )
            }

            HStack(alignment: .top, spacing: Layout.columnSpacing) {
                number(line.oldLine)
                number(line.newLine)

                HStack(alignment: .top, spacing: Layout.markerSpacing) {
                    Text(AgentChangesDiffPalette.marker(for: line.kind))
                        .frame(
                            width: AgentChangesDiffMetrics.markerWidth(preset: preset),
                            alignment: .leading
                        )
                    Text(attributedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(AgentChangesSearchAnchorOverlay(matches: searchMatches))
                }
                .foregroundStyle(
                    AgentChangesDiffPalette.textColor(for: line.kind, colorScheme: colorScheme)
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .font(font)
        .padding(.leading, Layout.leadingPadding)
        .padding(.trailing, Layout.trailingPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentChangesDiffPalette.backgroundColor(for: line.kind, colorScheme: colorScheme))
        .accessibilityElement(children: .contain)
    }

    private var displayText: String {
        line.text
    }

    private var attributedText: AttributedString {
        AgentChangesHighlightedText.make(
            displayText,
            intralineRanges: line.kind == .noNewlineMarker ? [] : line.intralineRanges,
            searchHighlights: searchMatches.map {
                AgentChangesSearchHighlight(
                    utf16Range: $0.utf16Range,
                    isCurrent: isCurrentSearchMatch($0)
                )
            },
            intralineBackground: AgentChangesDiffPalette.intralineBackgroundColor(
                for: line.kind,
                colorScheme: colorScheme
            ),
            searchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: false,
                colorScheme: colorScheme
            ),
            currentSearchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: true,
                colorScheme: colorScheme
            )
        )
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: gutterWidth, alignment: .trailing)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        switch line.kind {
        case .addition: "Added line \(line.newLine.map(String.init) ?? ""): \(displayText)"
        case .deletion: "Removed line \(line.oldLine.map(String.init) ?? ""): \(displayText)"
        case .context: "Line \(line.newLine.map(String.init) ?? ""): \(displayText)"
        case .noNewlineMarker: displayText
        }
    }
}

// MARK: - Line selection

struct AgentChangesLineSelection {
    let key: AgentChangesDiffLineKey
    let action: AgentChangesPartialAction
    let isSelected: Bool
    let isDisabled: Bool
}

private struct AgentChangesLineSelectionButton: View {
    let line: FileDiffProjection.Line
    let selection: AgentChangesLineSelection?
    let onSetSelected: (Bool) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let glyphSizeAtNormal: CGFloat = 8
        static let frameSizeAtNormal: CGFloat = 15
        static let cornerRadius: CGFloat = 3
        static let selectedOpacity: Double = 0.72
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Group {
            if let selection {
                Button { onSetSelected(!selection.isSelected) } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(
                            size: preset.scaledMetric(Layout.glyphSizeAtNormal),
                            weight: .semibold
                        ))
                        .foregroundStyle(selection.isSelected ? Color.white : Color.secondary)
                        .frame(
                            width: preset.scaledMetric(Layout.frameSizeAtNormal),
                            height: preset.scaledMetric(Layout.frameSizeAtNormal)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                                .fill(
                                    selection.isSelected
                                        ? Color.accentColor.opacity(Layout.selectedOpacity)
                                        : Color.clear
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selection.isDisabled)
                .hoverTooltip(accessibilityLabel(selection))
                .accessibilityLabel(accessibilityLabel(selection))
                .accessibilityValue(selection.isSelected ? "selected" : "not selected")
            } else {
                Color.clear
                    .frame(
                        width: preset.scaledMetric(Layout.frameSizeAtNormal),
                        height: preset.scaledMetric(Layout.frameSizeAtNormal)
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private func accessibilityLabel(_ selection: AgentChangesLineSelection) -> String {
        let verb = selection.isSelected ? "Remove" : "Select"
        let direction = selection.action == .stage ? "staging" : "unstaging"
        switch selection.key {
        case let .addition(newLine):
            return "\(verb) added line \(newLine) for \(direction)"
        case let .deletion(oldLine):
            return "\(verb) removed line \(oldLine) for \(direction)"
        }
    }
}

// MARK: - Split row

private struct AgentChangesSplitDiffRowView: View {
    let row: SplitDiffRowProjector.Row
    let lineNumberDigits: Int
    let showsSelectionColumn: Bool
    let selectionForLine: (FileDiffProjection.Line) -> AgentChangesLineSelection?
    let searchMatchesForLine: (FileDiffProjection.Line) -> [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onSetLineSelected: (Bool, AgentChangesDiffLineKey) -> Void

    var body: some View {
        if row.spansBoth, let context = row.new ?? row.old {
            AgentChangesDiffLineView(
                line: context,
                lineNumberDigits: lineNumberDigits,
                showsSelectionColumn: showsSelectionColumn,
                selection: selectionForLine(context),
                searchMatches: searchMatchesForLine(context),
                isCurrentSearchMatch: isCurrentSearchMatch,
                onSetSelected: { selected in
                    guard let key = context.partialLineKey else { return }
                    onSetLineSelected(selected, key)
                }
            )
        } else {
            HStack(alignment: .top, spacing: 0) {
                AgentChangesSplitDiffCellView(
                    line: row.old,
                    side: .old,
                    lineNumberDigits: lineNumberDigits,
                    showsSelectionColumn: showsSelectionColumn,
                    selection: row.old.flatMap(selectionForLine),
                    searchMatches: row.old.map(searchMatchesForLine) ?? [],
                    isCurrentSearchMatch: isCurrentSearchMatch,
                    onSetSelected: { selected in
                        guard let key = row.old?.partialLineKey else { return }
                        onSetLineSelected(selected, key)
                    }
                )
                Divider()
                AgentChangesSplitDiffCellView(
                    line: row.new,
                    side: .new,
                    lineNumberDigits: lineNumberDigits,
                    showsSelectionColumn: showsSelectionColumn,
                    selection: row.new.flatMap(selectionForLine),
                    searchMatches: row.new.map(searchMatchesForLine) ?? [],
                    isCurrentSearchMatch: isCurrentSearchMatch,
                    onSetSelected: { selected in
                        guard let key = row.new?.partialLineKey else { return }
                        onSetLineSelected(selected, key)
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct AgentChangesSplitDiffCellView: View {
    let line: FileDiffProjection.Line?
    let side: DiffContextSplicer.SourceSide
    let lineNumberDigits: Int
    let showsSelectionColumn: Bool
    let selection: AgentChangesLineSelection?
    let searchMatches: [AgentChangesSearchMatch]
    let isCurrentSearchMatch: (AgentChangesSearchMatch) -> Bool
    let onSetSelected: (Bool) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let spacing: CGFloat = 4
        static let leadingPadding: CGFloat = 3
        static let trailingPadding: CGFloat = 3
        static let verticalPadding: CGFloat = 0.5
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var font: Font {
        .system(
            size: preset.scaledMetric(AgentChangesDiffMetrics.lineFontSizeAtNormal),
            design: .monospaced
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            if showsSelectionColumn {
                AgentChangesLineSelectionButton(
                    line: line ?? emptyLine,
                    selection: selection,
                    onSetSelected: onSetSelected
                )
            }

            HStack(alignment: .top, spacing: Layout.spacing) {
                number
                if let line {
                    Text(AgentChangesDiffPalette.marker(for: line.kind))
                        .frame(
                            width: AgentChangesDiffMetrics.markerWidth(preset: preset),
                            alignment: .leading
                        )
                    Text(attributedText(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(
                            AgentChangesDiffPalette.textColor(
                                for: line.kind,
                                colorScheme: colorScheme
                            )
                        )
                        .overlay(AgentChangesSearchAnchorOverlay(matches: searchMatches))
                } else {
                    Text(" ")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .font(font)
        .padding(.leading, Layout.leadingPadding)
        .padding(.trailing, Layout.trailingPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            line.flatMap {
                AgentChangesDiffPalette.backgroundColor(for: $0.kind, colorScheme: colorScheme)
            }
        )
        .accessibilityElement(children: .contain)
    }

    /// Used only by the inert selection-column spacer in an empty split cell.
    private var emptyLine: FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: "empty",
            kind: .context,
            oldLine: nil,
            newLine: nil,
            text: "",
            intralineRanges: []
        )
    }

    private var number: some View {
        let value = side == .old ? line?.oldLine : line?.newLine
        return Text(value.map(String.init) ?? "")
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(
                width: AgentChangesDiffMetrics.gutterWidth(
                    digits: lineNumberDigits,
                    preset: preset
                ),
                alignment: .trailing
            )
            .accessibilityHidden(true)
    }

    private func attributedText(for line: FileDiffProjection.Line) -> AttributedString {
        AgentChangesHighlightedText.make(
            line.text,
            intralineRanges: line.kind == .noNewlineMarker ? [] : line.intralineRanges,
            searchHighlights: searchMatches.map {
                AgentChangesSearchHighlight(
                    utf16Range: $0.utf16Range,
                    isCurrent: isCurrentSearchMatch($0)
                )
            },
            intralineBackground: AgentChangesDiffPalette.intralineBackgroundColor(
                for: line.kind,
                colorScheme: colorScheme
            ),
            searchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: false,
                colorScheme: colorScheme
            ),
            currentSearchBackground: AgentChangesDiffPalette.searchBackgroundColor(
                current: true,
                colorScheme: colorScheme
            )
        )
    }

    private var accessibilityLabel: String {
        guard let line else {
            return side == .old ? "Empty old-side cell" : "Empty new-side cell"
        }
        let number = side == .old ? line.oldLine : line.newLine
        let sideName = side == .old ? "Old" : "New"
        return "\(sideName) line \(number.map(String.init) ?? ""): \(line.text)"
    }
}

private extension FileDiffProjection.Line {
    var partialLineKey: AgentChangesDiffLineKey? {
        switch kind {
        case .addition:
            newLine.map(AgentChangesDiffLineKey.addition(newLine:))
        case .deletion:
            oldLine.map(AgentChangesDiffLineKey.deletion(oldLine:))
        case .context, .noNewlineMarker:
            nil
        }
    }
}
