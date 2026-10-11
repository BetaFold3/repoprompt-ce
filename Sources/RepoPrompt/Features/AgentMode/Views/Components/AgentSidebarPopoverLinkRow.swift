import RepoPromptUI
import SwiftUI

/// Compact "deep link" row used by Agent Mode sidebar popovers (Models,
/// Permissions, etc.) to route to a specific settings tab. Kept in one place
/// so both popovers stay visually identical as the feature set grows.
///
/// SEARCH-HELPER: AgentSidebarPopoverLinkRow, Agent Mode popover deep link,
/// Models popover link, Permissions popover link, sidebar popover nav row
///
/// Related:
/// - Models popover:      /RepoPrompt/Views/AgentMode/AgentModelsPopoverView.swift
/// - Permissions popover: /RepoPrompt/Views/AgentMode/AgentPermissionsPopoverView.swift
struct AgentSidebarPopoverLinkRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var outerSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titleDetailSpacing: CGFloat {
        fontPreset.scaledClamped(1, max: 2)
    }

    private var horizontalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var verticalPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 8)
    }

    private var leadingIconSize: CGFloat {
        fontPreset.scaledClamped(11, max: 14)
    }

    private var leadingIconFrameWidth: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    private var chevronSize: CGFloat {
        fontPreset.scaledClamped(9, max: 12)
    }

    init(
        icon: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: outerSpacing) {
                Image(systemName: icon)
                    .font(.system(size: leadingIconSize))
                    .foregroundColor(.accentColor)
                    .frame(width: leadingIconFrameWidth)
                VStack(alignment: .leading, spacing: titleDetailSpacing) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSize))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
