import SwiftUI

/// Fixed Changes chrome. Repository identity and base selection belong to each ordered group;
/// keeping only the two global choices here prevents one checkout's state from speaking for all.
struct AgentChangesHeaderView: View {
    let compareSelection: AgentChangesCompareSelection
    let diffViewMode: AgentChangesDiffViewMode
    let isSplitViewAvailable: Bool
    let onSelectCompare: (AgentChangesCompareSelection) -> Void
    let onSelectDiffViewMode: (AgentChangesDiffViewMode) -> Void

    private enum Layout {
        static let spacing: CGFloat = 6
    }

    private var compareBinding: Binding<AgentChangesCompareSelection> {
        Binding(get: { compareSelection }, set: onSelectCompare)
    }

    private var diffViewModeBinding: Binding<AgentChangesDiffViewMode> {
        Binding(get: { diffViewMode }, set: onSelectDiffViewMode)
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            comparePicker
            diffViewPicker
        }
        .agentSidebarCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comparison settings")
    }

    private var comparePicker: some View {
        Picker("Comparison", selection: compareBinding) {
            ForEach(AgentChangesCompareSelection.allCases) { selection in
                Text(selection.title).tag(selection)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .hoverTooltip("Choose Working Tree or a repository-local base comparison")
        .accessibilityLabel("Comparison")
        .accessibilityValue(compareSelection.title)
    }

    private var diffViewPicker: some View {
        Picker("Diff layout", selection: diffViewModeBinding) {
            ForEach(AgentChangesDiffViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!isSplitViewAvailable)
        .hoverTooltip(
            isSplitViewAvailable
                ? "Switch between unified and split diff layouts."
                : "Split view requires at least 560 points of effective diff width."
        )
        .accessibilityLabel("Diff layout")
        .accessibilityValue(diffViewMode.title)
        .accessibilityHint(
            isSplitViewAvailable
                ? "Switches between unified and split diff layouts"
                : "Split view requires at least 560 points of effective diff width"
        )
    }
}

// MARK: - Chip label

/// The header's shared chip treatment: one small glyph, one truncating label.
///
/// Named rather than inlined so the root picker, the base picker, and the worktree chip cannot
/// drift into three different sizes at three different font presets.
struct AgentChangesChipLabel: View {
    let symbolName: String
    let text: String
    var tint: Color = .secondary
    var showsMenuIndicator = false

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 3
        static let textSizeAtNormal: CGFloat = 10
        static let symbolSizeAtNormal: CGFloat = 9
        static let indicatorSizeAtNormal: CGFloat = 7
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 3
        static let cornerRadius: CGFloat = 5
        static let backgroundOpacity: Double = 0.1
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: symbolName)
                .font(.system(size: preset.scaledMetric(Layout.symbolSizeAtNormal), weight: .medium))
            Text(text)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.textSizeAtNormal, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: preset.scaledMetric(Layout.indicatorSizeAtNormal), weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(tint.opacity(Layout.backgroundOpacity))
        )
        .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
    }
}

// MARK: - Base picker

/// Base-branch chooser.
///
/// The empty label is "Choose base…" rather than a pre-filled default on purpose: decision row 1
/// forbids inferring or fetching a default branch, because a comparison against the wrong base
/// looks exactly like a comparison against the right one.
struct AgentChangesBaseRevisionMenu: View {
    let selectedRevision: String?
    let candidates: [String]
    let onSelect: (String) -> Void
    let onSelectCustom: () -> Void

    var body: some View {
        Menu {
            if candidates.isEmpty {
                Text("No branches found")
            } else {
                ForEach(candidates, id: \.self) { branch in
                    Button {
                        onSelect(branch)
                    } label: {
                        if branch == selectedRevision {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
            Divider()
            Button("Custom revision\u{2026}", action: onSelectCustom)
        } label: {
            AgentChangesChipLabel(
                symbolName: "arrow.triangle.pull",
                text: selectedRevision ?? "Choose base\u{2026}",
                tint: selectedRevision == nil ? .accentColor : .secondary,
                showsMenuIndicator: true
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTooltip(
            selectedRevision.map { "Comparing against \($0)" } ?? "Choose the revision to compare against"
        )
        .accessibilityLabel("Base revision")
        .accessibilityValue(selectedRevision ?? "not chosen")
    }
}

// MARK: - Custom revision

struct AgentChangesCustomRevisionEditorView: View {
    let editor: AgentChangesPanelViewModel.CustomRevisionEditor
    let onUpdate: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 5
        static let textSizeAtNormal: CGFloat = 10
        static let progressScale: CGFloat = 0.5
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var binding: Binding<String> {
        Binding(get: { editor.text }, set: onUpdate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack(spacing: Layout.spacing) {
                TextField("Tag, SHA, HEAD~3, origin/main", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(
                        size: preset.scaledMetric(Layout.textSizeAtNormal),
                        design: .monospaced
                    ))
                    .disabled(editor.isValidating)
                    .onSubmit(onSubmit)
                    .hoverTooltip("Enter a tag, commit, or other Git revision")
                    .accessibilityLabel("Custom base revision")
                    .accessibilityValue(editor.text.isEmpty ? "empty" : editor.text)

                if editor.isValidating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(Layout.progressScale)
                        .accessibilityLabel("Validating revision")
                } else {
                    Button("Compare", action: onSubmit)
                        .controlSize(.small)
                        .disabled(editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .hoverTooltip("Validate and compare against this revision")
                        .accessibilityLabel("Compare against custom revision")
                        .accessibilityValue(
                            editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "unavailable"
                                : "available"
                        )
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.textSizeAtNormal))
                    .hoverTooltip("Cancel custom revision entry")
                    .accessibilityLabel("Cancel custom revision entry")
                    .accessibilityValue(editor.isValidating ? "validation in progress" : "available")
            }

            if let error = editor.errorMessage {
                Text(error)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.textSizeAtNormal))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Revision error: \(error)")
            }
        }
    }
}

// MARK: - Worktree chips

/// Names the agent worktree the panel is reading, so a staging click is never ambiguous about which
/// working tree it lands in.
struct AgentChangesWorktreeChip: View {
    let worktree: AgentPanelWorktreeIdentity

    private var text: String {
        worktree.branch ?? worktree.label
    }

    var body: some View {
        AgentChangesChipLabel(symbolName: "arrow.triangle.branch", text: text)
            .hoverTooltip("Agent worktree at \(worktree.worktreeRootPath)")
            .accessibilityLabel("Agent worktree")
            .accessibilityValue(text)
    }
}

/// Persistent reminder that the user chose the workspace checkout over an unavailable worktree.
///
/// Sticky by design: the substitution is a real change in what a staging click mutates, and a
/// notice that faded after a few seconds would leave the panel silently pointed elsewhere.
struct AgentChangesSubstitutionWarningChip: View {
    let worktree: AgentPanelWorktreeIdentity?

    private var tooltip: String {
        guard let worktree else { return "Showing the workspace checkout instead of the agent worktree." }
        return "Showing the workspace checkout instead of \(worktree.label) at \(worktree.worktreeRootPath)."
    }

    var body: some View {
        AgentChangesChipLabel(
            symbolName: "exclamationmark.triangle.fill",
            text: "Workspace checkout",
            tint: .orange
        )
        .hoverTooltip(tooltip)
        .accessibilityLabel("Showing workspace checkout instead of the agent worktree")
    }
}

// MARK: - Blocked checkout

/// A logical root the panel refuses to guess about.
///
/// A bound worktree never silently falls back to the main checkout: while it is hydrating this card
/// says so and waits, and when it is genuinely unavailable the substitution is offered as an
/// explicit action the user has to take.
struct AgentChangesBlockedCheckoutCard: View {
    let blocked: AgentPanelBlockedCheckout
    let onShowWorkspaceCheckout: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 4
        static let titleSpacing: CGFloat = 5
        static let titleSizeAtNormal: CGFloat = 11
        static let messageSizeAtNormal: CGFloat = 10
        static let symbolSizeAtNormal: CGFloat = 10
        static let progressScale: CGFloat = 0.5
        static let actionTopPadding: CGFloat = 2
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var isPreparing: Bool {
        blocked.reason.isTransient
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack(spacing: Layout.titleSpacing) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(Layout.progressScale)
                        .frame(width: preset.scaledMetric(Layout.symbolSizeAtNormal))
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: preset.scaledMetric(Layout.symbolSizeAtNormal)))
                        .foregroundStyle(.orange)
                }
                Text("\(blocked.logicalRoot.displayName) · \(AgentChangesBlockedPresentation.title(for: blocked.reason))")
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.titleSizeAtNormal, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            Text(AgentChangesBlockedPresentation.message(for: blocked.reason))
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if blocked.reason.allowsWorkspaceCheckoutOverride {
                Button("Show Workspace Checkout Instead", action: onShowWorkspaceCheckout)
                    .buttonStyle(.link)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
                    .padding(.top, Layout.actionTopPadding)
                    .hoverTooltip("Show \(blocked.logicalRoot.displayName) from the workspace checkout")
                    .accessibilityLabel("Show \(blocked.logicalRoot.displayName) workspace checkout instead")
                    .accessibilityValue("available")
                    .accessibilityHint("Reads \(blocked.logicalRoot.displayName) from the workspace folder instead of the agent worktree")
            }
        }
        .agentSidebarCard(highlight: isPreparing ? nil : .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(blocked.logicalRoot.displayName). "
                + "\(AgentChangesBlockedPresentation.title(for: blocked.reason)). "
                + AgentChangesBlockedPresentation.message(for: blocked.reason)
        )
    }
}
