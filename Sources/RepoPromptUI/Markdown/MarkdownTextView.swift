import AppKit
import Markdown
import SwiftUI

// MARK: - Markdown Text View

package enum MarkdownRenderCadence: Equatable {
    case immediate
    case streamingCoalesced
}

struct MarkdownRenderSignature: Equatable {
    let text: String
    let fontSize: CGFloat
    let forceTextColor: Color?
    let useMonospaced: Bool
    let detectsMarkdownFilePaths: Bool
    /// Resolved transcript code-font face identity (system or custom).
    let codeFontFaceIdentity: String

    func hasSameRenderingConfiguration(as other: Self) -> Bool {
        fontSize == other.fontSize &&
            forceTextColor == other.forceTextColor &&
            useMonospaced == other.useMonospaced &&
            detectsMarkdownFilePaths == other.detectsMarkdownFilePaths &&
            codeFontFaceIdentity == other.codeFontFaceIdentity
    }

    func isAppendOnlyRelative(to other: Self) -> Bool {
        hasSameRenderingConfiguration(as: other) &&
            text.hasPrefix(other.text)
    }
}

struct MarkdownStreamingAppendDelta: Equatable {
    let appendedCharacterCount: Int
    let appendedNewlineCount: Int

    static func between(previous: MarkdownRenderSignature, requested: MarkdownRenderSignature) -> Self? {
        guard requested.isAppendOnlyRelative(to: previous) else { return nil }
        let appendedText = String(requested.text.dropFirst(previous.text.count))
        return Self(
            appendedCharacterCount: appendedText.count,
            appendedNewlineCount: appendedText.reduce(into: 0) { count, character in
                if character == "\n" {
                    count += 1
                }
            }
        )
    }
}

enum MarkdownRenderSchedulingDecision: Equatable {
    case skip
    case compileNow
    case compileAfter(TimeInterval)
}

enum MarkdownStreamingCompileTier {
    case normal
    case large
    case extreme

    init(text: String) {
        switch text.count {
        case 20000...:
            self = .extreme
        case 8000...:
            self = .large
        default:
            self = .normal
        }
    }

    var minimumPublishInterval: TimeInterval {
        switch self {
        case .normal:
            0.20
        case .large:
            0.32
        case .extreme:
            0.50
        }
    }

    var quietWindow: TimeInterval {
        switch self {
        case .normal:
            0.12
        case .large:
            0.18
        case .extreme:
            0.25
        }
    }

    var minimumAppendedCharacterCount: Int {
        switch self {
        case .normal:
            0
        case .large:
            350
        case .extreme:
            700
        }
    }

    var minimumAppendedNewlineCount: Int {
        switch self {
        case .normal:
            0
        case .large:
            12
        case .extreme:
            24
        }
    }
}

enum MarkdownStreamingCompilePolicy {
    static func decision(
        cadence: MarkdownRenderCadence,
        hasCompiledText: Bool,
        lastPublishedSignature: MarkdownRenderSignature?,
        requestedSignature: MarkdownRenderSignature,
        lastPublishedAt: Date?,
        now: Date
    ) -> MarkdownRenderSchedulingDecision {
        if lastPublishedSignature == requestedSignature {
            return .skip
        }

        guard cadence == .streamingCoalesced else {
            return .compileNow
        }

        guard hasCompiledText else {
            return .compileNow
        }

        guard let lastPublishedSignature else {
            return .compileNow
        }

        guard let appendDelta = MarkdownStreamingAppendDelta.between(previous: lastPublishedSignature, requested: requestedSignature) else {
            return .compileNow
        }

        let tier = MarkdownStreamingCompileTier(text: requestedSignature.text)
        let elapsedSinceLastPublish = lastPublishedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if elapsedSinceLastPublish < tier.minimumPublishInterval {
            return .compileAfter(max(tier.quietWindow, tier.minimumPublishInterval - elapsedSinceLastPublish))
        }

        guard tier.minimumAppendedCharacterCount > 0 || tier.minimumAppendedNewlineCount > 0 else {
            return .compileNow
        }

        if appendDelta.appendedCharacterCount < tier.minimumAppendedCharacterCount,
           appendDelta.appendedNewlineCount < tier.minimumAppendedNewlineCount
        {
            return .compileAfter(tier.quietWindow)
        }

        return .compileNow
    }
}

enum MarkdownStreamingSegmentationPolicy {
    static func shouldUseSegmentedRenderer(
        isMarkdown: Bool,
        allowsStreamingSegmentation: Bool,
        renderCadence: MarkdownRenderCadence,
        text: String
    ) -> Bool {
        guard isMarkdown,
              allowsStreamingSegmentation,
              renderCadence == .streamingCoalesced
        else {
            return false
        }
        return MarkdownStreamingFreezeBoundaryResolver.shouldConsiderSegmentation(for: text)
    }
}

struct MarkdownStreamingFreezeBoundary: Equatable {
    let utf16Offset: Int
    let prefixCharacterCount: Int
    let prefixLineCount: Int
    let tailCharacterCount: Int
    let tailLineCount: Int
}

enum MarkdownStreamingFreezeBoundaryResolver {
    static let extremeCharacterThreshold = 20000
    static let extremeLineThreshold = 350
    static let minimumPrefixCharacterCount = 8000
    static let minimumTailCharacterCount = 4000
    static let minimumTailLineCount = 120
    static let preferredTailCharacterCount = 6000
    static let preferredTailLineCount = 140
    static let minimumFreezeAdvanceCharacterCount = 2500

    static func shouldConsiderSegmentation(for text: String) -> Bool {
        text.count >= extremeCharacterThreshold || lineCount(in: text) >= extremeLineThreshold
    }

    static func resolveBoundary(in text: String) -> MarkdownStreamingFreezeBoundary? {
        guard shouldConsiderSegmentation(for: text) else { return nil }
        let totalLineCount = lineCount(in: text)
        let candidates = blankLineBoundaryOffsets(in: text)
        guard !candidates.isEmpty else { return nil }

        let boundaries = candidates.compactMap { makeBoundary(in: text, utf16Offset: $0, totalLineCount: totalLineCount) }
        if let preferred = boundaries.reversed().first(where: {
            $0.tailCharacterCount >= preferredTailCharacterCount || $0.tailLineCount >= preferredTailLineCount
        }) {
            return preferred
        }
        return boundaries.last
    }

    static func split(text: String, atUTF16Offset utf16Offset: Int) -> (prefix: String, tail: String)? {
        guard utf16Offset > 0, utf16Offset < text.utf16.count else { return nil }
        let boundaryIndex = String.Index(utf16Offset: utf16Offset, in: text)
        return (
            prefix: String(text[..<boundaryIndex]),
            tail: String(text[boundaryIndex...])
        )
    }

    static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private static func blankLineBoundaryOffsets(in text: String) -> [Int] {
        let nsText = text as NSString
        let fullLength = nsText.length
        var searchLocation = 0
        var offsets: [Int] = []

        while searchLocation < fullLength {
            let searchRange = NSRange(location: searchLocation, length: fullLength - searchLocation)
            let range = nsText.range(of: "\n\n", options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            let boundaryOffset = range.location + range.length
            offsets.append(boundaryOffset)
            searchLocation = boundaryOffset
        }

        return offsets
    }

    private static func makeBoundary(
        in text: String,
        utf16Offset: Int,
        totalLineCount: Int
    ) -> MarkdownStreamingFreezeBoundary? {
        guard let split = split(text: text, atUTF16Offset: utf16Offset) else { return nil }
        let prefixCharacterCount = split.prefix.count
        let tailCharacterCount = split.tail.count
        guard prefixCharacterCount >= minimumPrefixCharacterCount,
              tailCharacterCount >= minimumTailCharacterCount
        else {
            return nil
        }

        let tailLineCount = lineCount(in: split.tail)
        guard tailLineCount >= minimumTailLineCount else { return nil }
        guard !isFenceOpen(in: split.prefix) else { return nil }
        guard !startsInPipeTable(tail: split.tail, prefix: split.prefix) else { return nil }

        let prefixLineCount = max(0, totalLineCount - tailLineCount)
        return MarkdownStreamingFreezeBoundary(
            utf16Offset: utf16Offset,
            prefixCharacterCount: prefixCharacterCount,
            prefixLineCount: prefixLineCount,
            tailCharacterCount: tailCharacterCount,
            tailLineCount: tailLineCount
        )
    }

    private static func isFenceOpen(in text: String) -> Bool {
        var activeFenceMarker: String?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmedLine = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let marker = fenceMarker(in: trimmedLine) else { continue }
            if activeFenceMarker == marker {
                activeFenceMarker = nil
            } else if activeFenceMarker == nil {
                activeFenceMarker = marker
            }
        }
        return activeFenceMarker != nil
    }

    private static func fenceMarker(in line: String) -> String? {
        if line.hasPrefix("```") {
            return "```"
        }
        if line.hasPrefix("~~~") {
            return "~~~"
        }
        return nil
    }

    private static func startsInPipeTable(tail: String, prefix: String) -> Bool {
        guard let firstTailLine = firstNonEmptyLine(in: tail),
              looksLikePipeTableRow(firstTailLine),
              let lastPrefixLine = lastNonEmptyLine(in: prefix)
        else {
            return false
        }
        return looksLikePipeTableRow(lastPrefixLine) || looksLikePipeTableSeparator(lastPrefixLine)
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .reversed()
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    private static func looksLikePipeTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.contains("|")
    }

    private static func looksLikePipeTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let stripped = line
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }
}

private struct MarkdownRenderRequestContext: Equatable {
    let signature: MarkdownRenderSignature
    let cadence: MarkdownRenderCadence
    let prefersSynchronousFirstLayout: Bool
}

/// Compiles a render signature into attributed text. The scheduled compile and the opt-in
/// first-layout memo both use this, so they produce identical output for one signature.
enum MarkdownRenderCompiler {
    @MainActor
    static func compile(_ signature: MarkdownRenderSignature) -> NSAttributedString {
        let document = Document(parsing: signature.text)
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = signature.fontSize
        compiler.forceTextColor = signature.forceTextColor
        compiler.useMonospaced = signature.useMonospaced
        compiler.detectsMarkdownFilePaths = signature.detectsMarkdownFilePaths
        compiler.codeFont = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: signature.codeFontFaceIdentity,
            pointSize: signature.fontSize
        ).font
        var compiled = compiler.attributedString(from: document)
        if let forceTextColor = signature.forceTextColor {
            compiled = applyTextColor(compiled, color: forceTextColor)
        }
        return compiled
    }

    private static func applyTextColor(_ attributedString: NSAttributedString, color: Color) -> NSAttributedString {
        let mutable = attributedString.mutableCopy() as! NSMutableAttributedString
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor(color), range: fullRange)
        return mutable
    }
}

/// Decides whether an opted-in view compiles its first single-renderer layout synchronously
/// instead of measuring an unstyled placeholder and re-measuring after a scheduled compile.
/// Only the first compiled text is affected; later updates keep the scheduled path.
enum MarkdownFirstLayoutCompilePolicy {
    static func compilesSynchronously(
        prefersSynchronousFirstLayout: Bool,
        cadence: MarkdownRenderCadence,
        hasCompiledText: Bool
    ) -> Bool {
        prefersSynchronousFirstLayout && cadence == .immediate && !hasCompiledText
    }
}

/// Single-entry memo owned by one `MarkdownTextView` identity. It lets `body` produce the
/// styled first layout and lets the lifecycle publish that same result without compiling twice.
/// It is a plain reference type: mutating it never publishes a SwiftUI change.
@MainActor
final class MarkdownFirstLayoutCompileMemo {
    private var entry: (signature: MarkdownRenderSignature, compiled: NSAttributedString)?

    var isEmpty: Bool {
        entry == nil
    }

    /// Returns the retained result for exactly `signature`, compiling and replacing it on a miss.
    func resolve(
        _ signature: MarkdownRenderSignature,
        compile: (MarkdownRenderSignature) -> NSAttributedString
    ) -> NSAttributedString {
        if let entry, entry.signature == signature {
            return entry.compiled
        }
        let compiled = compile(signature)
        entry = (signature, compiled)
        return compiled
    }

    /// Resolves `signature` and releases the entry, for handing the result to published state.
    func consume(
        _ signature: MarkdownRenderSignature,
        compile: (MarkdownRenderSignature) -> NSAttributedString
    ) -> NSAttributedString {
        let compiled = resolve(signature, compile: compile)
        entry = nil
        return compiled
    }

    func clear() {
        entry = nil
    }
}

private struct SegmentedStreamingMarkdownTextView: View, Equatable {
    let text: String
    let allowInteraction: Bool
    let forceTextColor: Color?
    let useMonospaced: Bool
    let detectsMarkdownFilePaths: Bool
    let initialBoundary: MarkdownStreamingFreezeBoundary

    @State private var frozenBoundaryUTF16Offset: Int?

    var body: some View {
        Group {
            if let segments = textSegments {
                VStack(alignment: .leading, spacing: 0) {
                    if !segments.prefix.isEmpty {
                        MarkdownTextView(
                            text: segments.prefix,
                            isMarkdown: true,
                            allowInteraction: allowInteraction,
                            forceTextColor: forceTextColor,
                            useMonospaced: useMonospaced,
                            detectsMarkdownFilePaths: detectsMarkdownFilePaths,
                            renderCadence: .immediate,
                            allowsStreamingSegmentation: false
                        )
                    }
                    MarkdownTextView(
                        text: segments.tail,
                        isMarkdown: true,
                        allowInteraction: allowInteraction,
                        forceTextColor: forceTextColor,
                        useMonospaced: useMonospaced,
                        detectsMarkdownFilePaths: detectsMarkdownFilePaths,
                        renderCadence: .streamingCoalesced,
                        allowsStreamingSegmentation: false
                    )
                }
            } else {
                MarkdownTextView(
                    text: text,
                    isMarkdown: true,
                    allowInteraction: allowInteraction,
                    forceTextColor: forceTextColor,
                    useMonospaced: useMonospaced,
                    detectsMarkdownFilePaths: detectsMarkdownFilePaths,
                    renderCadence: .streamingCoalesced,
                    allowsStreamingSegmentation: false
                )
            }
        }
        .onAppear {
            updateFrozenBoundary(using: initialBoundary)
        }
    }

    static func == (lhs: SegmentedStreamingMarkdownTextView, rhs: SegmentedStreamingMarkdownTextView) -> Bool {
        lhs.text == rhs.text &&
            lhs.allowInteraction == rhs.allowInteraction &&
            lhs.forceTextColor == rhs.forceTextColor &&
            lhs.useMonospaced == rhs.useMonospaced &&
            lhs.detectsMarkdownFilePaths == rhs.detectsMarkdownFilePaths &&
            lhs.initialBoundary == rhs.initialBoundary
    }

    private var activeBoundaryOffset: Int {
        frozenBoundaryUTF16Offset ?? initialBoundary.utf16Offset
    }

    private var textSegments: (prefix: String, tail: String)? {
        MarkdownStreamingFreezeBoundaryResolver.split(text: text, atUTF16Offset: activeBoundaryOffset)
    }

    private func updateFrozenBoundary(using candidate: MarkdownStreamingFreezeBoundary?) {
        guard let candidate, frozenBoundaryUTF16Offset == nil else { return }
        frozenBoundaryUTF16Offset = candidate.utf16Offset
    }
}

/// Renders text content - either as Markdown or plain Text.
/// Uses EnhancedMarkdownCompiler to create NSAttributedString once, then displays via AttributedTextView.
/// Tables are compiled into NSTextTable-backed attributed text and render through the same non-scrolling text view path.
/// The default-off synchronous first-layout opt-in mutates only a nonpublishing memo during body evaluation;
/// it applies before the first `.immediate` compile, while later updates retain scheduled rendering.
package struct MarkdownTextView: View, Equatable {
    let text: String
    let isMarkdown: Bool
    let allowInteraction: Bool
    let forceTextColor: Color?
    let useMonospaced: Bool
    let detectsMarkdownFilePaths: Bool
    let renderCadence: MarkdownRenderCadence
    private let allowsStreamingSegmentation: Bool
    private let prefersSynchronousFirstLayout: Bool
    @Environment(\.markdownFileLinkOpener) private var markdownFileLinkOpener
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var displayPreferences = UIDisplayPreferences.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var resolvedCodeFont: TranscriptCodeFontResolver.Resolved {
        TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: displayPreferences.transcriptCodeFontPostScriptName,
            pointSize: CGFloat(fontPreset.rawValue)
        )
    }

    @State private var attributedText: NSAttributedString?
    @State private var compileTask: Task<Void, Never>?
    @State private var latestRequestedSignature: MarkdownRenderSignature?
    @State private var lastPublishedSignature: MarkdownRenderSignature?
    @State private var lastPublishedAt: Date?
    @State private var latestRequestID: Int = 0
    @State private var firstLayoutMemo = MarkdownFirstLayoutCompileMemo()

    package init(
        text: String,
        isMarkdown: Bool = true,
        allowInteraction: Bool = true,
        forceTextColor: Color? = nil,
        useMonospaced: Bool = false,
        detectsMarkdownFilePaths: Bool = false,
        renderCadence: MarkdownRenderCadence = .immediate,
        allowsStreamingSegmentation: Bool = true,
        prefersSynchronousFirstLayout: Bool = false
    ) {
        self.text = text
        self.isMarkdown = isMarkdown
        self.allowInteraction = allowInteraction
        self.forceTextColor = forceTextColor
        self.useMonospaced = useMonospaced
        self.detectsMarkdownFilePaths = detectsMarkdownFilePaths
        self.renderCadence = renderCadence
        self.allowsStreamingSegmentation = allowsStreamingSegmentation
        self.prefersSynchronousFirstLayout = prefersSynchronousFirstLayout
    }

    package static func == (lhs: MarkdownTextView, rhs: MarkdownTextView) -> Bool {
        lhs.text == rhs.text &&
            lhs.isMarkdown == rhs.isMarkdown &&
            lhs.allowInteraction == rhs.allowInteraction &&
            lhs.forceTextColor == rhs.forceTextColor &&
            lhs.useMonospaced == rhs.useMonospaced &&
            lhs.detectsMarkdownFilePaths == rhs.detectsMarkdownFilePaths &&
            lhs.renderCadence == rhs.renderCadence &&
            lhs.allowsStreamingSegmentation == rhs.allowsStreamingSegmentation &&
            lhs.prefersSynchronousFirstLayout == rhs.prefersSynchronousFirstLayout &&
            lhs.fontScale.preset.scaleFactor == rhs.fontScale.preset.scaleFactor &&
            lhs.displayPreferences.transcriptCodeFontPostScriptName
            == rhs.displayPreferences.transcriptCodeFontPostScriptName
    }

    package var body: some View {
        if isMarkdown {
            markdownBody
                .onAppear {
                    updateMarkdownRenderingLifecycle()
                }
                .onChange(of: renderRequestContext) { _, _ in
                    updateMarkdownRenderingLifecycle()
                }
                .onDisappear {
                    cancelPendingCompile()
                }
        } else {
            Text(text)
                .font(useMonospaced ? .system(size: CGFloat(fontPreset.rawValue), design: .monospaced) : fontPreset.font)
                .textSelection(.enabled)
                .allowsHitTesting(allowInteraction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var markdownBody: some View {
        if let segmentedBoundary {
            SegmentedStreamingMarkdownTextView(
                text: text,
                allowInteraction: allowInteraction,
                forceTextColor: forceTextColor,
                useMonospaced: useMonospaced,
                detectsMarkdownFilePaths: detectsMarkdownFilePaths,
                initialBoundary: segmentedBoundary
            )
        } else {
            markdownContent
        }
    }

    private var markdownContent: some View {
        AttributedTextView(
            attributedString: displayAttributedString,
            isEditable: false,
            allowsTextSelection: allowInteraction,
            linkOpener: markdownFileLinkOpener
        )
    }

    private var renderRequestContext: MarkdownRenderRequestContext {
        MarkdownRenderRequestContext(
            signature: MarkdownRenderSignature(
                text: text,
                fontSize: CGFloat(fontPreset.rawValue),
                forceTextColor: forceTextColor,
                useMonospaced: useMonospaced,
                detectsMarkdownFilePaths: detectsMarkdownFilePaths,
                codeFontFaceIdentity: resolvedCodeFont.fingerprint.faceIdentity
            ),
            cadence: renderCadence,
            prefersSynchronousFirstLayout: prefersSynchronousFirstLayout
        )
    }

    private var segmentedBoundary: MarkdownStreamingFreezeBoundary? {
        guard shouldUseSegmentedStreamingRenderer else { return nil }
        return MarkdownStreamingFreezeBoundaryResolver.resolveBoundary(in: text)
    }

    private var shouldUseSegmentedStreamingRenderer: Bool {
        MarkdownStreamingSegmentationPolicy.shouldUseSegmentedRenderer(
            isMarkdown: isMarkdown,
            allowsStreamingSegmentation: allowsStreamingSegmentation,
            renderCadence: renderCadence,
            text: text
        )
    }

    private var displayAttributedString: NSAttributedString {
        if let compiled = attributedText {
            return compiled
        }
        if MarkdownFirstLayoutCompilePolicy.compilesSynchronously(
            prefersSynchronousFirstLayout: prefersSynchronousFirstLayout,
            cadence: renderCadence,
            hasCompiledText: false
        ) {
            // Mutates only the non-publishing memo; the lifecycle adopts this same result.
            return firstLayoutMemo.resolve(renderRequestContext.signature, compile: MarkdownRenderCompiler.compile)
        }
        let font: NSFont = if useMonospaced {
            resolvedCodeFont.font
        } else {
            NSFont.systemFont(ofSize: CGFloat(fontPreset.rawValue))
        }
        let color = forceTextColor.map { NSColor($0) } ?? NSColor.textColor
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
    }

    private func updateMarkdownRenderingLifecycle(now: Date = Date()) {
        guard isMarkdown else {
            cancelPendingCompile()
            return
        }
        guard !shouldUseSegmentedStreamingRenderer else {
            clearSingleRendererRenderState()
            return
        }
        scheduleMarkdownCompile(for: renderRequestContext, now: now)
    }

    private func scheduleMarkdownCompile(for context: MarkdownRenderRequestContext, now: Date = Date()) {
        guard isMarkdown else {
            cancelPendingCompile()
            return
        }

        let decision = MarkdownStreamingCompilePolicy.decision(
            cadence: context.cadence,
            hasCompiledText: attributedText != nil,
            lastPublishedSignature: lastPublishedSignature,
            requestedSignature: context.signature,
            lastPublishedAt: lastPublishedAt,
            now: now
        )

        latestRequestedSignature = context.signature

        switch decision {
        case .skip:
            return
        case .compileNow:
            if MarkdownFirstLayoutCompilePolicy.compilesSynchronously(
                prefersSynchronousFirstLayout: context.prefersSynchronousFirstLayout,
                cadence: context.cadence,
                hasCompiledText: attributedText != nil
            ) {
                // Supersede any queued compile, then publish the result `body` already laid out.
                cancelPendingCompile()
                latestRequestID += 1
                let compiled = firstLayoutMemo.consume(context.signature, compile: MarkdownRenderCompiler.compile)
                publishCompiled(compiled, for: context.signature)
            } else {
                enqueueCompile(for: context.signature, after: nil)
            }
        case let .compileAfter(delay):
            enqueueCompile(for: context.signature, after: delay)
        }
    }

    private func enqueueCompile(for signature: MarkdownRenderSignature, after delay: TimeInterval?) {
        cancelPendingCompile()
        latestRequestID += 1
        let requestID = latestRequestID

        compileTask = Task { @MainActor in
            if let delay {
                let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }

            guard !Task.isCancelled else { return }
            guard latestRequestID == requestID else { return }
            guard latestRequestedSignature == signature else { return }

            compileMarkdown(for: signature, requestID: requestID)
        }
    }

    private func cancelPendingCompile() {
        compileTask?.cancel()
        compileTask = nil
    }

    private func clearSingleRendererRenderState() {
        guard attributedText != nil
            || compileTask != nil
            || latestRequestedSignature != nil
            || lastPublishedSignature != nil
            || lastPublishedAt != nil
            || !firstLayoutMemo.isEmpty
        else {
            return
        }
        cancelPendingCompile()
        firstLayoutMemo.clear()
        attributedText = nil
        latestRequestedSignature = nil
        lastPublishedSignature = nil
        lastPublishedAt = nil
    }

    private func compileMarkdown(for signature: MarkdownRenderSignature, requestID: Int) {
        let compiled = MarkdownRenderCompiler.compile(signature)

        guard !Task.isCancelled else { return }
        guard latestRequestID == requestID else { return }
        guard latestRequestedSignature == signature else { return }
        guard renderRequestContext.signature == signature else { return }

        publishCompiled(compiled, for: signature)
    }

    private func publishCompiled(_ compiled: NSAttributedString, for signature: MarkdownRenderSignature) {
        firstLayoutMemo.clear()
        attributedText = compiled
        lastPublishedSignature = signature
        lastPublishedAt = Date()
        compileTask = nil
    }
}

// MARK: - Preview

#if DEBUG
    struct MarkdownTextView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(alignment: .leading, spacing: 16) {
                MarkdownTextView(
                    text: "# Hello World\n\nThis is **bold** and *italic* text.\n\n```swift\nlet x = 42\n```",
                    isMarkdown: true
                )

                MarkdownTextView(
                    text: "Plain text without markdown rendering",
                    isMarkdown: false
                )
            }
            .padding()
            .frame(width: 400)
        }
    }
#endif
