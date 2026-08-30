//
//  CollapsibleUserMessage.swift
//  RepoPrompt
//
//  Shared component for user message bubbles that can collapse/expand.
//  Used by both Chat (Bubbles.swift) and Agent Mode (AgentMessageBubble.swift).
//

import AppKit
import SwiftUI

enum CollapsibleUserMessageLinkification {
    static func swiftUIAttributedString(
        _ displayText: String,
        sourceText: String? = nil,
        enabled: Bool = false
    ) -> AttributedString {
        var attributedString = AttributedString(displayText)
        guard enabled else { return attributedString }

        for match in matches(in: displayText, sourceText: sourceText) {
            guard let url = ReservedTranscriptFileURLCodec.makeURL(path: match.path),
                  let stringRange = Range(match.range, in: displayText),
                  let attributedRange = Range(stringRange, in: attributedString)
            else { continue }
            attributedString[attributedRange].link = url
        }
        return attributedString
    }

    static func appKitAttributedString(
        _ displayText: String,
        sourceText: String? = nil,
        font: NSFont,
        enabled: Bool = false
    ) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: displayText, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor
        ])
        guard enabled else { return attributedString }

        for match in matches(in: displayText, sourceText: sourceText) {
            guard let url = ReservedTranscriptFileURLCodec.makeURL(path: match.path) else { continue }
            attributedString.addAttributes([
                .link: url,
                .markdownRawLink: match.path,
                .markdownDetectedFileLink: true,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
        return attributedString
    }

    private static func matches(
        in displayText: String,
        sourceText: String?
    ) -> [MarkdownFilePathLinkDetector.Match] {
        let detectionText = sourceText ?? displayText
        let displayedUTF16Length = displayText.utf16.count
        return MarkdownFilePathLinkDetector.proseMatches(in: detectionText).filter {
            NSMaxRange($0.range) <= displayedUTF16Length &&
                Range($0.range, in: displayText) != nil
        }
    }
}

// MARK: - Content Width Observation

private struct CollapsibleUserMessageContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next.isFinite, next > 1 else { return }
        value = next
    }
}

private extension View {
    func recordCollapsibleUserMessageContentWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CollapsibleUserMessageContentWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        }
        .onPreferenceChange(CollapsibleUserMessageContentWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 1 else { return }
            onChange(width)
        }
    }
}

// MARK: - Measured Plain Text View

/// Plain-text user message renderer backed by the markdown text view's
/// synchronous `sizeThatFits` measurement path. This avoids the old
/// intrinsic-size/AppKit invalidation loop and ignores any oversized height
/// proposed by the transcript viewport.
private struct MeasuredPlainTextView: View {
    let text: String
    let font: NSFont
    let fallbackMeasurementWidth: CGFloat?
    let linkifiesDocumentPaths: Bool

    @Environment(\.markdownFileLinkOpener) private var linkOpener

    private var attributedString: NSAttributedString {
        CollapsibleUserMessageLinkification.appKitAttributedString(
            text,
            font: font,
            enabled: linkifiesDocumentPaths
        )
    }

    var body: some View {
        AttributedTextView(
            attributedString: attributedString,
            isEditable: false,
            allowsTextSelection: true,
            linkOpener: linkOpener,
            fallbackMeasurementWidth: fallbackMeasurementWidth
        )
    }
}

// MARK: - Collapsible User Message

/// A user message view that collapses if the text exceeds a threshold.
/// Provides expand/collapse functionality with smooth animations.
struct CollapsibleUserMessage: View {
    let text: String
    var linkifiesDocumentPaths: Bool = false

    /// Number of characters to show in collapsed state
    var previewCharCount: Int = 500

    /// Label shown on expand button
    var expandLabel: String = "Show more…"

    /// Label shown on collapse button
    var collapseLabel: String = "Show less"

    // UI state
    @State private var isCollapsed = true
    @State private var lastKnownContentWidth: CGFloat?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var displayText: String {
        if text.count > previewCharCount, isCollapsed {
            return String(text.prefix(previewCharCount))
        }
        return text
    }

    private var needsCollapse: Bool {
        text.count > previewCharCount
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if linkifiesDocumentPaths {
            Text(
                CollapsibleUserMessageLinkification.swiftUIAttributedString(
                    displayText,
                    sourceText: text,
                    enabled: true
                )
            )
        } else {
            Text(displayText)
        }
    }

    private func updateLastKnownContentWidth(_ width: CGFloat) {
        guard width.isFinite, width > 1 else { return }
        if let lastKnownContentWidth,
           abs(lastKnownContentWidth - width) <= 0.5
        {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lastKnownContentWidth = width
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Use normal Text for small messages or collapsed state.
            // Use the shared measured AppKit text path for expanded large messages.
            if !needsCollapse || isCollapsed {
                collapsedContent
                    .font(fontPreset.font)
                    .textSelection(.enabled)
                    .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            } else {
                MeasuredPlainTextView(
                    text: displayText,
                    font: fontPreset.nsFont,
                    fallbackMeasurementWidth: lastKnownContentWidth,
                    linkifiesDocumentPaths: linkifiesDocumentPaths
                )
                .recordCollapsibleUserMessageContentWidth(updateLastKnownContentWidth)
            }

            if needsCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Text(isCollapsed ? expandLabel : collapseLabel)
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
