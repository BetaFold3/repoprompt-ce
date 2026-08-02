import SwiftUI

/// The quiet "the agent just wrote you a document" line in the Changes panel.
///
/// This is ambient UI, not an alert: one line, the panel's own card treatment, no color fill, no
/// motion. It states what was written, offers to open it, and offers to go away. The banner is
/// intentionally unopinionated about *which* artifact it shows — the caller picks the newest
/// non-dismissed one (`AgentSessionArtifactIndex.newestArtifact(excludingDismissed:)`) and owns the
/// per-tab dismissal set, so the same view serves whatever selection policy the panel settles on.
struct AgentArtifactBannerView: View {
    let artifact: AgentSessionArtifact
    /// Opens the artifact in the panel's Preview segment.
    let onView: () -> Void
    /// Dismisses this artifact for this tab.
    let onDismiss: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let rowSpacing: CGFloat = 6
        static let messageSpacing: CGFloat = 4
        static let symbolSizeAtNormal: CGFloat = 11
        static let nameSizeAtNormal: CGFloat = 11
        static let captionSizeAtNormal: CGFloat = 11
        static let actionSizeAtNormal: CGFloat = 11
        static let actionArrowSizeAtNormal: CGFloat = 9
        static let actionSpacing: CGFloat = 3
        static let dismissGlyphSizeAtNormal: CGFloat = 9
        static let dismissButtonSize: CGFloat = 20
        static let hoverFillOpacity: Double = 0.12
    }

    /// The banner's whole sentence, kept together so the wording stays one decision.
    private static let caption = "written by agent"

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var accessibilityMessage: String {
        "\(artifact.fileName) \(Self.caption)"
    }

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            Image(systemName: symbolName)
                .font(.system(size: preset.scaledMetric(Layout.symbolSizeAtNormal)))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            message

            Spacer(minLength: Layout.messageSpacing)

            Text("·")
                .font(preset.swiftUIFont(sizeAtNormal: Layout.captionSizeAtNormal))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            viewButton

            AgentArtifactBannerDismissButton(
                glyphSize: preset.scaledMetric(Layout.dismissGlyphSizeAtNormal),
                buttonSize: Layout.dismissButtonSize,
                hoverFillOpacity: Layout.hoverFillOpacity,
                accessibilityLabel: "Dismiss \(artifact.fileName) notice",
                onDismiss: onDismiss
            )
        }
        .agentSidebarCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document written by agent")
    }

    // MARK: - Message

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.messageSpacing) {
            Text(artifact.fileName)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.nameSizeAtNormal, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(Self.caption)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.captionSizeAtNormal))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage)
    }

    // MARK: - Actions

    private var viewButton: some View {
        Button(action: onView) {
            HStack(spacing: Layout.actionSpacing) {
                Text("View")
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.actionSizeAtNormal, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: preset.scaledMetric(Layout.actionArrowSizeAtNormal), weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("View \(artifact.fileName)")
    }

    private var symbolName: String {
        switch artifact.kind {
        case .markdown: "doc.text"
        case .html: "doc.richtext"
        }
    }
}

// MARK: - Dismiss Button

/// Mirrors the panel header's close button: same glyph treatment, same hover fill, same hit shape.
private struct AgentArtifactBannerDismissButton: View {
    let glyphSize: CGFloat
    let buttonSize: CGFloat
    let hoverFillOpacity: Double
    let accessibilityLabel: String
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(hoverFillOpacity) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}
