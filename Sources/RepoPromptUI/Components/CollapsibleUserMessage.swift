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

    static func matches(
        in displayText: String,
        sourceText: String?
    ) -> [MarkdownFilePathLinkDetector.Match] {
        let detectionText = sourceText ?? displayText
        let displayedUTF16Length = displayText.utf16.count
        return displayedPrefixCandidates(
            in: detectionText,
            displayedUTF16Length: displayedUTF16Length
        ).filter {
            NSMaxRange($0.range) <= displayedUTF16Length &&
                Range($0.range, in: displayText) != nil
        }
    }

    /// Detector matches that can end within the displayed prefix, scanning only `[0, w + 2)`
    /// where `w` is the first whitespace at or after it: matches contain no regex `\s`, so they
    /// end by `w`. Without a `.` + m/M/h/H pair in `[0, w)` nothing can be displayed. Accepted
    /// divergence: a displayed path whose needle the precheck rejects (`x.md` + combining mark)
    /// links only if the prefix passes the precheck. See D6-collapsed-link-scan notes.
    private static func displayedPrefixCandidates(
        in detectionText: String,
        displayedUTF16Length: Int
    ) -> [MarkdownFilePathLinkDetector.Match] {
        guard let bounded = boundedDetection(
            of: detectionText,
            displayedUTF16Length: displayedUTF16Length
        ) else {
            return MarkdownFilePathLinkDetector.proseMatches(in: detectionText)
        }
        guard containsExtensionCandidate(bounded.prefix, utf16Limit: bounded.whitespaceOffset) else {
            return []
        }
        return MarkdownFilePathLinkDetector.proseMatches(in: bounded.prefix)
    }

    /// UTF-16 prefix `[0, cut)` of `text`, where `cut` is the first composed-character boundary at
    /// or after `w + 2` and `w` (`whitespaceOffset`) is the first whitespace at or after
    /// `displayedUTF16Length`. Nil when the prefix would be the whole text.
    static func boundedDetection(
        of text: String,
        displayedUTF16Length: Int
    ) -> (prefix: String, whitespaceOffset: Int)? {
        let source = text as NSString
        let length = source.length
        guard displayedUTF16Length >= 0, displayedUTF16Length < length else { return nil }
        let whitespace = source.rangeOfCharacter(
            from: patternWhitespace,
            options: [],
            range: NSRange(location: displayedUTF16Length, length: length - displayedUTF16Length)
        )
        guard whitespace.location != NSNotFound else { return nil }
        var cut = whitespace.location + 2
        guard cut < length else { return nil }
        let composed = source.rangeOfComposedCharacterSequence(at: cut)
        if composed.location < cut {
            cut = NSMaxRange(composed)
        }
        guard cut < length else { return nil }
        return (source.substring(to: cut), whitespace.location)
    }

    /// ICU's documented regex `\s`, `[\t\n\f\r\p{Z}]`. Any implementation superset still makes
    /// every member a character the detector's path body cannot contain.
    private static let patternWhitespace: CharacterSet = {
        var set = CharacterSet.whitespaces // Zs and U+0009
        set.insert(charactersIn: "\n\u{0C}\r\u{2028}\u{2029}")
        return set
    }()

    private static func containsExtensionCandidate(_ text: String, utf16Limit: Int) -> Bool {
        var previousWasDot = false
        for unit in text.utf16.prefix(utf16Limit) {
            if previousWasDot, unit == 0x6D || unit == 0x4D || unit == 0x68 || unit == 0x48 {
                return true
            }
            previousWasDot = unit == 0x2E
        }
        return false
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
package struct CollapsibleUserMessage: View {
    let text: String
    var linkifiesDocumentPaths: Bool = false

    /// Number of characters to show in collapsed state
    var previewCharCount: Int = 500

    /// Label shown on expand button
    var expandLabel: String = "Show more…"

    /// Label shown on collapse button
    var collapseLabel: String = "Show less"

    package init(
        text: String,
        linkifiesDocumentPaths: Bool = false,
        previewCharCount: Int = 500,
        expandLabel: String = "Show more…",
        collapseLabel: String = "Show less"
    ) {
        self.text = text
        self.linkifiesDocumentPaths = linkifiesDocumentPaths
        self.previewCharCount = previewCharCount
        self.expandLabel = expandLabel
        self.collapseLabel = collapseLabel
    }

    // UI state
    @State private var isCollapsed = true
    @State private var lastKnownContentWidth: CGFloat?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private func resolvedDisplayText(needsCollapse: Bool) -> String {
        if needsCollapse, isCollapsed {
            return String(text.prefix(previewCharCount))
        }
        return text
    }

    @ViewBuilder
    private func collapsedContent(displayText: String) -> some View {
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

    package var body: some View {
        // O(preview): `text.count` is O(n) for large pasted messages.
        let previewEnd = text.index(text.startIndex, offsetBy: previewCharCount, limitedBy: text.endIndex)
        let needsCollapse = previewEnd.map { $0 < text.endIndex } ?? false
        let displayText = resolvedDisplayText(needsCollapse: needsCollapse)
        VStack(alignment: .leading, spacing: 6) {
            // Use normal Text for small messages or collapsed state.
            // Use the shared measured AppKit text path for expanded large messages.
            if !needsCollapse || isCollapsed {
                collapsedContent(displayText: displayText)
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
