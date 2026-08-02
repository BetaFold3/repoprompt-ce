import SwiftUI

/// One expanded file's diff body.
///
/// Unified and split layouts consume the same projection and the same vertical stack. Split rows
/// are derived at render time, so gutters stay synchronized without two competing scroll views.
struct AgentChangesPatchView: View {
    let row: AgentChangesFileRow
    let state: AgentChangesPatchLoadState
    let diffViewMode: AgentChangesDiffViewMode
    let gapContextState: AgentChangesPanelViewModel.GapContextState
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
                AgentChangesHunkView(
                    hunk: document.hunks[index],
                    lineNumberDigits: digits,
                    diffViewMode: diffViewMode
                )
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

    private func notice(_ message: String, actionTitle: String?) -> some View {
        HStack(spacing: Layout.noticeSpacing) {
            Text(message)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: onOpenFile)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
                    .accessibilityLabel("\(actionTitle) \(row.path)")
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
                    .accessibilityLabel("Expand 12 lines of hidden diff context")
                }
                Button("Expand all") {
                    onExpand(.all)
                }
                .accessibilityLabel("Expand all hidden diff context")
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

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let headerSpacing: CGFloat = 6
        static let headerHorizontalPadding: CGFloat = 4
        static let headerVerticalPadding: CGFloat = 3
        static let rangeSizeAtNormal: CGFloat = 9.5
        static let headingSizeAtNormal: CGFloat = 9.5
        static let cornerRadius: CGFloat = 4
        static let bodyTopPadding: CGFloat = 1
    }

    private var preset: FontScalePreset {
        fontScale.preset
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
                            lineNumberDigits: lineNumberDigits
                        )
                    }
                case .split:
                    ForEach(SplitDiffRowProjector.rows(for: hunk)) { row in
                        AgentChangesSplitDiffRowView(
                            row: row,
                            lineNumberDigits: lineNumberDigits
                        )
                    }
                }
            }
            .padding(.top, Layout.bodyTopPadding)
            .textSelection(.enabled)
        }
    }

    private var header: some View {
        HStack(spacing: Layout.headerSpacing) {
            Text(AgentChangesPatchPresentation.rangeText(for: hunk))
                .font(.system(size: preset.scaledMetric(Layout.rangeSizeAtNormal), design: .monospaced))
                .foregroundStyle(.tertiary)

            if let heading = hunk.heading, !heading.isEmpty {
                Text(heading)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.headingSizeAtNormal, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Layout.headerSpacing)
        }
        .padding(.horizontal, Layout.headerHorizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(AgentChangesDiffPalette.hunkHeaderBackground(colorScheme: colorScheme))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Unified line

struct AgentChangesDiffLineView: View {
    let line: FileDiffProjection.Line
    let lineNumberDigits: Int

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
            number(line.oldLine)
            number(line.newLine)

            HStack(alignment: .top, spacing: Layout.markerSpacing) {
                Text(AgentChangesDiffPalette.marker(for: line.kind))
                    .frame(width: AgentChangesDiffMetrics.markerWidth(preset: preset), alignment: .leading)
                Text(attributedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AgentChangesDiffPalette.textColor(for: line.kind, colorScheme: colorScheme))
        }
        .font(font)
        .padding(.leading, Layout.leadingPadding)
        .padding(.trailing, Layout.trailingPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentChangesDiffPalette.backgroundColor(for: line.kind, colorScheme: colorScheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayText: String {
        line.kind == .noNewlineMarker
            ? line.text.trimmingCharacters(in: .whitespaces)
            : line.text
    }

    private var attributedText: AttributedString {
        AgentChangesIntralineText.make(
            displayText,
            ranges: line.kind == .noNewlineMarker ? [] : line.intralineRanges,
            background: AgentChangesDiffPalette.intralineBackgroundColor(
                for: line.kind,
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

// MARK: - Split row

private struct AgentChangesSplitDiffRowView: View {
    let row: SplitDiffRowProjector.Row
    let lineNumberDigits: Int

    var body: some View {
        if row.spansBoth, let context = row.new ?? row.old {
            AgentChangesDiffLineView(line: context, lineNumberDigits: lineNumberDigits)
        } else {
            HStack(alignment: .top, spacing: 0) {
                AgentChangesSplitDiffCellView(
                    line: row.old,
                    side: .old,
                    lineNumberDigits: lineNumberDigits
                )
                Divider()
                AgentChangesSplitDiffCellView(
                    line: row.new,
                    side: .new,
                    lineNumberDigits: lineNumberDigits
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct AgentChangesSplitDiffCellView: View {
    let line: FileDiffProjection.Line?
    let side: DiffContextSplicer.SourceSide
    let lineNumberDigits: Int

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
            } else {
                Text(" ")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
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
        .accessibilityLabel(accessibilityLabel)
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
        let text = line.kind == .noNewlineMarker
            ? line.text.trimmingCharacters(in: .whitespaces)
            : line.text
        return AgentChangesIntralineText.make(
            text,
            ranges: line.kind == .noNewlineMarker ? [] : line.intralineRanges,
            background: AgentChangesDiffPalette.intralineBackgroundColor(
                for: line.kind,
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

private enum AgentChangesIntralineText {
    static func make(
        _ text: String,
        ranges: [Range<Int>],
        background: Color?
    ) -> AttributedString {
        var attributed = AttributedString(text)
        guard let background else { return attributed }

        for range in ranges {
            guard range.lowerBound >= 0,
                  range.upperBound <= text.utf16.count,
                  range.lowerBound < range.upperBound
            else { continue }
            let stringLower = String.Index(utf16Offset: range.lowerBound, in: text)
            let stringUpper = String.Index(utf16Offset: range.upperBound, in: text)
            guard let lower = AttributedString.Index(stringLower, within: attributed),
                  let upper = AttributedString.Index(stringUpper, within: attributed)
            else { continue }
            attributed[lower ..< upper].backgroundColor = background
        }
        return attributed
    }
}
