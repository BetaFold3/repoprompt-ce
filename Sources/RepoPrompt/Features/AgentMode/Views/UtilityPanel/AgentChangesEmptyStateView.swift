import SwiftUI

/// The Changes segment's "nothing to show" card.
///
/// One view for every empty case so the panel cannot develop five slightly different ways of saying
/// nothing happened. The only case that offers an action is a clean working tree, which is decision
/// row 1's bridge: an agent that commits as it works leaves an empty working tree precisely when
/// the user most wants to review something, and vs-Base is where that work is.
struct AgentChangesEmptyStateView: View {
    let state: AgentChangesEmptyState
    let baseRevisionCandidates: [String]
    let onCompareAgainstBase: () -> Void
    let onSelectBaseRevision: (String) -> Void
    let onSelectCustomRevision: () -> Void
    let onRetry: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 6
        static let symbolSizeAtNormal: CGFloat = 22
        static let titleSizeAtNormal: CGFloat = 11
        static let messageSizeAtNormal: CGFloat = 10
        static let verticalPadding: CGFloat = 18
        static let symbolBottomPadding: CGFloat = 2
        static let actionTopPadding: CGFloat = 4
        static let progressScale: CGFloat = 0.6
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: Layout.spacing) {
            symbol

            Text(title)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.titleSizeAtNormal, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            action
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Layout.verticalPadding)
        .agentSidebarCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }

    // MARK: - Pieces

    @ViewBuilder
    private var symbol: some View {
        if case .loading = state {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(Layout.progressScale)
                .padding(.bottom, Layout.symbolBottomPadding)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: preset.scaledMetric(Layout.symbolSizeAtNormal), weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Layout.symbolBottomPadding)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case let .cleanTree(offersBaseComparison) where offersBaseComparison:
            Button("Compare Against a Base Branch\u{2026}", action: onCompareAgainstBase)
                .buttonStyle(.link)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
                .padding(.top, Layout.actionTopPadding)
                .hoverTooltip("Choose a base revision for this repository")
                .accessibilityLabel("Compare against a base revision")
                .accessibilityValue("available")
        case .baseNotChosen:
            AgentChangesBaseRevisionMenu(
                selectedRevision: nil,
                candidates: baseRevisionCandidates,
                onSelect: onSelectBaseRevision,
                onSelectCustom: onSelectCustomRevision
            )
            .padding(.top, Layout.actionTopPadding)
        case let .failed(message):
            Button("Try Again", action: onRetry)
                .buttonStyle(.link)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
                .padding(.top, Layout.actionTopPadding)
                .accessibilityHint(message)
                .hoverTooltip("Retry reading this repository")
                .accessibilityLabel("Try reading changes again")
                .accessibilityValue("available")
        case .cleanTree, .loading, .noWorkspaceRoot, .notARepository, .blockedRootsOnly, .unbornHead:
            EmptyView()
        }
    }

    // MARK: - Copy

    private var symbolName: String {
        switch state {
        case .noWorkspaceRoot: "folder.badge.questionmark"
        case .notARepository: "arrow.triangle.branch"
        case .blockedRootsOnly: "exclamationmark.triangle"
        case .baseNotChosen: "arrow.triangle.pull"
        case .cleanTree: "checkmark.circle"
        case .unbornHead: "sparkles"
        case .loading: "clock"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch state {
        case .noWorkspaceRoot: "No Workspace Folder"
        case let .notARepository(rootName): "\(rootName) Is Not a Repository"
        case .blockedRootsOnly: "No Readable Checkout"
        case .baseNotChosen: "Choose a Base Branch"
        case .cleanTree: "Working Tree Is Clean"
        case .unbornHead: "No Commits Yet"
        case .loading: "Looking for Changes"
        case .failed: "Could Not Read Changes"
        }
    }

    private var message: String {
        switch state {
        case .noWorkspaceRoot:
            "Add a folder to this workspace to review the changes an agent makes in it."
        case .notARepository:
            "Changes appear here once this folder is inside a Git or Jujutsu repository."
        case .blockedRootsOnly:
            "Every folder in this workspace is waiting on a checkout. See the notice above."
        case .baseNotChosen:
            "Pick the branch to compare against. RepoPrompt never guesses one for you."
        case let .cleanTree(offersBaseComparison):
            offersBaseComparison
                ? "Nothing is staged or modified. Work the agent already committed shows up under vs Base."
                : "There is nothing between this checkout and the base you chose."
        case .unbornHead:
            "This repository has no first commit yet, so there is nothing to compare against."
        case .loading:
            "Reading the repository\u{2026}"
        case let .failed(message):
            message
        }
    }
}
