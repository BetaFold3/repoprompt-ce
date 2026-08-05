import AppKit
import SwiftUI

private final class EdgeForwardingScrollView: NSScrollView {
    private let edgeTolerance: CGFloat = 0.5

    override func scrollWheel(with event: NSEvent) {
        let predominantlyVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        guard predominantlyVertical else {
            super.scrollWheel(with: event)
            return
        }

        let maxOffsetY = maximumVerticalContentOffset
        let previousOffsetY = contentView.bounds.origin.y
        let wasAtVerticalEdge = previousOffsetY <= edgeTolerance || previousOffsetY >= (maxOffsetY - edgeTolerance)

        super.scrollWheel(with: event)

        let updatedOffsetY = contentView.bounds.origin.y
        let didConsumeVerticalScroll = abs(updatedOffsetY - previousOffsetY) > edgeTolerance
        guard wasAtVerticalEdge, !didConsumeVerticalScroll else { return }
        nextResponder?.scrollWheel(with: event)
    }

    private var maximumVerticalContentOffset: CGFloat {
        guard let documentView else { return 0 }
        return max(documentView.bounds.height - contentView.bounds.height, 0)
    }
}

extension NSAttributedString.Key {
    static let unifiedDiffLineBackgroundColor = NSAttributedString.Key("RepoPromptUnifiedDiffLineBackgroundColor")
}

private final class UnifiedDiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage else { return }
        let fullWidth = firstTextView?.bounds.width ?? 0

        enumerateLineFragments(forGlyphRange: glyphsToShow) { lineFragmentRect, _, _, glyphRange, _ in
            let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard characterRange.length > 0,
                  let backgroundColor = textStorage.attribute(.unifiedDiffLineBackgroundColor, at: characterRange.location, effectiveRange: nil) as? NSColor
            else {
                return
            }

            var fillRect = lineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            fillRect.origin.x = 0
            fillRect.size.width = max(fullWidth, fillRect.maxX)

            backgroundColor.setFill()
            fillRect.fill()
        }
    }
}

struct UnifiedDiffTextView: NSViewRepresentable {
    let document: UnifiedDiffDocument
    let fontSize: CGFloat
    let fontPreset: FontScalePreset
    let colorScheme: ColorScheme
    /// When false (default), preserves today's infinite-width + `.byClipping` + h-scroll path.
    var wrapLines: Bool = false
    /// Optional PostScript preference; nil uses system monospaced.
    var preferredPostScriptName: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EdgeForwardingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapLines
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = UnifiedDiffLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(
            width: wrapLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isHorizontallyResizable = !wrapLines
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: UnifiedDiffCardRendering.appKitVerticalTextInset(for: fontPreset))
        textView.textContainer?.lineFragmentPadding = UnifiedDiffCardRendering.appKitHorizontalTextPadding(for: fontPreset)
        if wrapLines {
            textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
        } else {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
        }
        textView.textContainer?.heightTracksTextView = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        if let layoutManager = textView.layoutManager {
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.usesFontLeading = true
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: preferredPostScriptName,
            pointSize: fontSize
        )
        let fontFingerprint = resolved.fingerprint
        let font = resolved.font
        let horizontalPadding = UnifiedDiffCardRendering.appKitHorizontalTextPadding(for: fontPreset)
        let verticalInset = UnifiedDiffCardRendering.appKitVerticalTextInset(for: fontPreset)
        let lineSpacing = UnifiedDiffCardRendering.appKitLineSpacing(for: fontPreset)
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = horizontalPadding

        applyWrapConfiguration(to: textView, scrollView: scrollView)

        let signature = RenderSignature(
            renderID: document.renderID,
            fontFingerprint: fontFingerprint,
            colorScheme: colorScheme,
            lineSpacing: lineSpacing,
            horizontalPadding: horizontalPadding,
            verticalInset: verticalInset,
            wrapLines: wrapLines
        )

        guard context.coordinator.lastRenderSignature != signature else { return }
        let attributedString = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: colorScheme,
            lineSpacing: lineSpacing,
            wrapLines: wrapLines,
            resolvedFontMetrics: resolved,
            preferredPostScriptName: preferredPostScriptName
        ).build()
        textView.textStorage?.setAttributedString(attributedString)
        context.coordinator.lastRenderSignature = signature
    }

    private func applyWrapConfiguration(to textView: NSTextView, scrollView: NSScrollView) {
        let shouldHaveHScroller = !wrapLines
        if scrollView.hasHorizontalScroller != shouldHaveHScroller {
            scrollView.hasHorizontalScroller = shouldHaveHScroller
        }
        if wrapLines {
            if textView.isHorizontallyResizable {
                textView.isHorizontallyResizable = false
            }
            textView.autoresizingMask = [.width]
            if let container = textView.textContainer {
                if container.widthTracksTextView == false {
                    container.widthTracksTextView = true
                }
                container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            }
        } else {
            if !textView.isHorizontallyResizable {
                textView.isHorizontallyResizable = true
            }
            textView.autoresizingMask = []
            if let container = textView.textContainer {
                if container.widthTracksTextView {
                    container.widthTracksTextView = false
                }
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate var lastRenderSignature: RenderSignature?
    }

    /// Includes font fingerprint so Workstream 5.3 custom faces invalidate renders.
    fileprivate struct RenderSignature: Equatable {
        let renderID: Int
        let fontFingerprint: TranscriptCodeFontFingerprint
        let colorScheme: ColorScheme
        let lineSpacing: CGFloat
        let horizontalPadding: CGFloat
        let verticalInset: CGFloat
        let wrapLines: Bool
    }
}

struct UnifiedDiffAttributedStringBuilder {
    private struct LineAttributeSet {
        let prefix: [NSAttributedString.Key: Any]
        let body: [NSAttributedString.Key: Any]
    }

    let document: UnifiedDiffDocument
    let font: NSFont
    let colorScheme: ColorScheme
    let lineSpacing: CGFloat
    /// When true, soft-wraps via paragraph style; source string stays unwrapped so copy is exact.
    var wrapLines: Bool = false
    /// Optional resolver metrics for pinned line height + tab stops; derived from `font` when nil.
    var resolvedFontMetrics: TranscriptCodeFontResolver.Resolved?
    /// Nil/empty identifies the legacy system-font default path, which keeps AppKit tab defaults.
    var preferredPostScriptName: String?

    func build() -> NSAttributedString {
        EditFlowPerf.measure(
            EditFlowPerf.Stage.UnifiedDiff.attributedBuild,
            EditFlowPerf.Dimensions(lineCount: document.lines.count)
        ) {
            let output = NSMutableAttributedString()
            output.beginEditing()
            let paragraphStyle = makeParagraphStyle()
            let numberColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
            let blankNumber = String(repeating: " ", count: document.maxLineNumberDigits)
            let attributesByKind = makeAttributesByKind(numberColor: numberColor, paragraphStyle: paragraphStyle)
            let lastIndex = document.lines.count - 1

            for (index, line) in document.lines.enumerated() {
                guard let attributeSet = attributesByKind[line.kind] else { continue }
                let prefix = numberPrefix(for: line, blankNumber: blankNumber)
                output.append(NSAttributedString(string: prefix, attributes: attributeSet.prefix))
                output.append(NSAttributedString(string: line.text, attributes: attributeSet.body))
                if index < lastIndex {
                    output.append(NSAttributedString(string: "\n", attributes: attributeSet.body))
                }
            }

            output.endEditing()
            return output
        }
    }

    /// Plain source text with hard newlines only — what copy/select must preserve when wrapped.
    func plainSourceText() -> String {
        let blankNumber = String(repeating: " ", count: document.maxLineNumberDigits)
        var lines: [String] = []
        lines.reserveCapacity(document.lines.count)
        for line in document.lines {
            lines.append(numberPrefix(for: line, blankNumber: blankNumber) + line.text)
        }
        return lines.joined(separator: "\n")
    }

    private func makeParagraphStyle() -> NSParagraphStyle {
        let normalizedPreference = preferredPostScriptName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !wrapLines, normalizedPreference?.isEmpty != false {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
            paragraphStyle.maximumLineHeight = paragraphStyle.minimumLineHeight
            return paragraphStyle
        }

        let metrics = resolvedFontMetrics ?? TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: font.fontName,
            pointSize: font.pointSize
        )
        let paragraphStyle = metrics.makeCodeParagraphStyle(
            lineSpacing: lineSpacing,
            lineBreakMode: wrapLines ? .byWordWrapping : .byClipping
        )
        if wrapLines {
            // Blank gutter on visual continuation lines: indent wrapped fragments past the
            // monospace line-number prefix so numbers appear only on the first fragment.
            let gutterWidth = Self.gutterWidth(
                maxLineNumberDigits: document.maxLineNumberDigits,
                font: font
            )
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.headIndent = gutterWidth
        }
        return paragraphStyle
    }

    static func gutterWidth(maxLineNumberDigits: Int, font: NSFont) -> CGFloat {
        let blankNumber = String(repeating: "0", count: max(maxLineNumberDigits, 1))
        // Matches `numberPrefix`: "\(old) \(new)  "
        let sample = "\(blankNumber) \(blankNumber)  "
        return ceil((sample as NSString).size(withAttributes: [.font: font]).width)
    }

    private func makeAttributesByKind(
        numberColor: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> [UnifiedDiffDocument.Line.Kind: LineAttributeSet] {
        let kinds: [UnifiedDiffDocument.Line.Kind] = [.addition, .deletion, .context, .gap, .fileHeader]
        var result: [UnifiedDiffDocument.Line.Kind: LineAttributeSet] = [:]
        result.reserveCapacity(kinds.count)
        for kind in kinds {
            let background = kind.nsBackgroundColor(colorScheme: colorScheme)
            result[kind] = LineAttributeSet(
                prefix: makeLineAttributes(
                    foregroundColor: numberColor,
                    paragraphStyle: paragraphStyle,
                    backgroundColor: background
                ),
                body: makeLineAttributes(
                    foregroundColor: kind.nsTextColor(colorScheme: colorScheme),
                    paragraphStyle: paragraphStyle,
                    backgroundColor: background
                )
            )
        }
        return result
    }

    private func makeLineAttributes(
        foregroundColor: NSColor,
        paragraphStyle: NSParagraphStyle,
        backgroundColor: NSColor?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        if let backgroundColor {
            attributes[.unifiedDiffLineBackgroundColor] = backgroundColor
        }
        return attributes
    }

    private func numberPrefix(for line: UnifiedDiffDocument.Line, blankNumber: String) -> String {
        "\(paddedLineNumber(line.oldLineNumber, blankNumber: blankNumber)) \(paddedLineNumber(line.newLineNumber, blankNumber: blankNumber))  "
    }

    private func paddedLineNumber(_ value: Int?, blankNumber: String) -> String {
        guard let value else { return blankNumber }
        let raw = String(value)
        let padding = document.maxLineNumberDigits - raw.count
        guard padding > 0 else { return raw }
        return String(repeating: " ", count: padding) + raw
    }
}
