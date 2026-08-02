//
//  SemiRenderedMarkdownCompiler.swift
//  RepoPrompt
//
//  Xcode-style semi-rendered Markdown: the source stays verbatim and visible,
//  and styling is layered on top of it.
//

import AppKit
import Foundation
import Markdown

// MARK: - Theme

/// The small palette semi-rendered Markdown draws from.
///
/// Markers stay legible but subordinate; content carries the hierarchy. Every
/// colour is a semantic `NSColor` so light/dark and accessibility variants
/// resolve at draw time rather than at compile time.
struct SemiRenderedMarkdownTheme {
    /// Ordinary prose.
    var bodyColor: NSColor
    /// Syntax markers — `#`, `**`, backticks, list bullets, `>`, `|`, fences.
    var markerColor: NSColor
    /// Text inside a block quote.
    var quoteColor: NSColor
    /// The visible label of a link or wiki link.
    var linkColor: NSColor
    /// Brackets, parentheses and destinations wrapped around a link label.
    var linkChromeColor: NSColor
    /// Code span and code fence content.
    var codeColor: NSColor

    static let standard = SemiRenderedMarkdownTheme(
        bodyColor: .textColor,
        markerColor: .secondaryLabelColor,
        quoteColor: .secondaryLabelColor,
        linkColor: .linkColor,
        linkChromeColor: NSColor.linkColor.withAlphaComponent(0.5),
        codeColor: .textColor
    )
}

// MARK: - Compiler

/// Compiles Markdown into an attributed string that **is** its own source.
///
/// # The invariant
///
/// `compiler.attributedString(for: source).string == source`, always.
///
/// This is guaranteed *by construction*, not by testing: the result is seeded
/// with the verbatim source and the compiler only ever calls `addAttributes`.
/// Nothing in this file inserts, deletes, substitutes, or reorders a character.
/// That single property is what makes the Preview panel's promise true —
/// selecting and copying rendered text yields valid Markdown identical to the
/// file on disk — and it is why a range-math mistake can only ever cost a
/// decoration, never corrupt the document.
///
/// The counterpart to that guarantee is defensive range handling. Positions
/// come from ``MarkdownSourceRangeMapper``, which returns `nil` for anything it
/// cannot translate confidently; every `NSRange` is then clamped to the
/// storage length before use; and every delimiter is re-verified lexically
/// against the source before it is styled. Delimiter scanning is always bounded
/// by the mapped range of the node being styled — never a regex swept across
/// the whole document — so a mis-parsed span cannot leak styling into its
/// neighbours.
///
/// # What "semi-rendered" means here
///
/// Markers remain on screen and remain selectable, tinted with
/// ``SemiRenderedMarkdownTheme/markerColor`` and left at a lighter weight than
/// the content they wrap. Content receives the real treatment: heading sizes
/// follow the same 1.8 / 1.5 / 1.3 / 1.15 / 1.05 ratios as
/// ``EnhancedMarkdownCompiler`` so the two renderers feel like one product,
/// bold and italic convert whatever font is already in place (which keeps
/// monospaced context monospaced), inline code and fenced code become
/// monospaced and syntax-highlighted, quotes tint and hang-indent, and links
/// colour their label while dimming their surrounding chrome.
///
/// Unlike ``EnhancedMarkdownCompiler``, this renderer uses the plain system
/// face rather than its rounded variant. Two reasons: SF Rounded ships no
/// italic face, so emphasis would silently render identically to body text —
/// unacceptable when the whole point is that content carries real styling —
/// and a document-reading surface showing verbatim source reads better in the
/// standard text face than in the chat transcript's rounded one. The preset
/// sizing conventions are shared; only the design axis differs.
///
/// Tables are deliberately left as aligned monospaced text. `NSTextTable`
/// would lay out real cells, but its text no longer corresponds to the source
/// character-for-character, which would break the invariant above.
struct SemiRenderedMarkdownCompiler {
    /// Body point size; heading and code sizes derive from it. Callers pass the
    /// active `FontScalePreset` value, matching `EnhancedMarkdownView`.
    var fontSize = CGFloat(FontScalePreset.normal.rawValue)
    var theme: SemiRenderedMarkdownTheme = .standard

    /// Heading point size for `level`, mirroring `EnhancedMarkdownCompiler`.
    static func headingFontSize(level: Int, baseSize: CGFloat) -> CGFloat {
        switch level {
        case 1: baseSize * 1.8
        case 2: baseSize * 1.5
        case 3: baseSize * 1.3
        case 4: baseSize * 1.15
        case 5: baseSize * 1.05
        default: baseSize
        }
    }

    /// Decorates `source` in place. The returned string's `.string` is `source`.
    func attributedString(for source: String) -> NSAttributedString {
        SemiRenderedMarkdownRenderer(
            source: source,
            fontSize: fontSize,
            theme: theme
        ).render()
    }
}

// MARK: - Renderer

/// Mutable working state for a single compile pass.
private final class SemiRenderedMarkdownRenderer {
    /// Deep enough for any hand-written document; a backstop against
    /// pathological nesting rather than a product limit.
    private static let maximumNestingDepth = 48

    private let source: String
    private let nsSource: NSString
    private let mapper: MarkdownSourceRangeMapper
    private let storage: NSMutableAttributedString
    private let fontSize: CGFloat
    private let theme: SemiRenderedMarkdownTheme

    private let bodyFont: NSFont
    private let codeFont: NSFont
    private let quoteIndentStep: CGFloat

    /// Literal-code spans. Wiki-link scanning skips these so `[[x]]` inside a
    /// code sample stays a code sample.
    private var codeSpans: [NSRange] = []
    /// Ranges of the blocks that can contain inline content. Wiki links are
    /// scanned inside these bounds only.
    private var inlineContainerRanges: [NSRange] = []

    init(source: String, fontSize: CGFloat, theme: SemiRenderedMarkdownTheme) {
        self.source = source
        nsSource = source as NSString
        mapper = MarkdownSourceRangeMapper(source: source)
        storage = NSMutableAttributedString(string: source)
        self.fontSize = fontSize
        self.theme = theme

        bodyFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        codeFont = NSFont.monospacedSystemFont(ofSize: max(fontSize - 1, 8), weight: .regular)
        quoteIndentStep = ceil(
            NSAttributedString(string: "> ", attributes: [.font: bodyFont]).size().width
        )
    }

    func render() -> NSAttributedString {
        guard storage.length > 0 else { return storage }
        storage.addAttributes(
            baseAttributes(),
            range: NSRange(location: 0, length: storage.length)
        )
        // Smart punctuation is disabled so parsed literals stay byte-identical
        // to the source; nothing here reads node text, but it keeps the AST and
        // the document describing the same characters.
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        visit(document, depth: 0)
        decorateWikiLinks()
        return storage
    }

    // MARK: - Traversal

    private func visit(_ markup: any Markup, depth: Int) {
        guard depth <= Self.maximumNestingDepth else { return }
        applyStyle(for: markup)
        if isInlineContainer(markup), let range = nsRange(of: markup) {
            inlineContainerRanges.append(range)
        }
        for child in markup.children {
            visit(child, depth: depth + 1)
        }
    }

    private func isInlineContainer(_ markup: any Markup) -> Bool {
        markup is Markdown.Paragraph
            || markup is Markdown.Heading
            || markup is Markdown.Table.Cell
    }

    private func applyStyle(for markup: any Markup) {
        switch markup {
        case let heading as Markdown.Heading: style(heading)
        case let codeBlock as Markdown.CodeBlock: style(codeBlock)
        case let htmlBlock as Markdown.HTMLBlock: styleRawHTML(htmlBlock)
        case let quote as Markdown.BlockQuote: style(quote)
        case let item as Markdown.ListItem: style(item)
        case let table as Markdown.Table: style(table)
        case let rule as Markdown.ThematicBreak: style(rule)
        case let strong as Markdown.Strong: style(strong)
        case let emphasis as Markdown.Emphasis: style(emphasis)
        case let strikethrough as Markdown.Strikethrough: style(strikethrough)
        case let inlineCode as Markdown.InlineCode: style(inlineCode)
        case let inlineHTML as Markdown.InlineHTML: styleRawHTML(inlineHTML)
        case let link as Markdown.Link: style(link)
        case let image as Markdown.Image: style(image)
        default: break
        }
    }

    // MARK: - Blocks

    private func style(_ heading: Markdown.Heading) {
        guard let range = nsRange(of: heading), let sourceRange = heading.range else { return }
        let size = SemiRenderedMarkdownCompiler.headingFontSize(level: heading.level, baseSize: fontSize)
        apply([.font: NSFont.systemFont(ofSize: size, weight: .bold)], to: range)

        // A setext heading's underline occupies the node's last line.
        if sourceRange.lowerBound.line != sourceRange.upperBound.line {
            if let underline = mapper.lineContentRange(line: sourceRange.upperBound.line) {
                apply([
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: theme.markerColor
                ], to: underline)
            }
            return
        }

        // ATX markers keep the heading's size but drop to regular weight, so
        // the left edge reads as a quiet rhythm rather than competing text.
        let markerFont = NSFont.systemFont(ofSize: size, weight: .regular)
        if let opening = leadingHashRun(in: range) {
            apply([.font: markerFont, .foregroundColor: theme.markerColor], to: opening)
        }
        if let closing = trailingHashRun(in: range) {
            apply([.font: markerFont, .foregroundColor: theme.markerColor], to: closing)
        }
    }

    private func style(_ codeBlock: Markdown.CodeBlock) {
        guard let range = nsRange(of: codeBlock), let sourceRange = codeBlock.range else { return }
        apply([.font: codeFont, .foregroundColor: theme.codeColor], to: range)
        // Lets CodeBlockTextView draw its rounded block background.
        apply([.codeBlockSource: nsSource.substring(with: range)], to: range)
        codeSpans.append(range)

        var firstContentLine = sourceRange.lowerBound.line
        var lastContentLine = max(firstContentLine, sourceRange.upperBound.line)

        if isFenceLine(sourceRange.lowerBound.line) {
            markLine(sourceRange.lowerBound.line)
            firstContentLine += 1
        }
        if lastContentLine >= firstContentLine, isFenceLine(lastContentLine) {
            markLine(lastContentLine)
            lastContentLine -= 1
        }

        guard lastContentLine >= firstContentLine,
              let first = mapper.lineContentRange(line: firstContentLine),
              let last = mapper.lineContentRange(line: lastContentLine)
        else { return }
        let contentEnd = last.location + last.length
        guard contentEnd > first.location else { return }
        applySyntaxHighlighting(
            in: NSRange(location: first.location, length: contentEnd - first.location)
        )
    }

    private func style(_ quote: Markdown.BlockQuote) {
        guard let range = nsRange(of: quote), let sourceRange = quote.range else { return }
        apply([.foregroundColor: theme.quoteColor], to: range)

        let paragraph = makeParagraphStyle()
        paragraph.headIndent = quoteIndentStep * CGFloat(quote.quoteDepth + 1)
        apply([.paragraphStyle: paragraph], to: range)

        forEachLine(of: sourceRange) { lineRange in
            if let marker = leadingQuoteRun(in: lineRange) {
                markRange(marker)
            }
        }
    }

    private func style(_ item: Markdown.ListItem) {
        guard let range = nsRange(of: item), let sourceRange = item.range else { return }
        guard let lineRange = mapper.lineContentRange(line: sourceRange.lowerBound.line),
              let marker = listMarkerRun(in: lineRange, startingAt: range.location)
        else { return }

        apply([
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: theme.markerColor
        ], to: marker)

        // Hang wrapped lines past the literal marker so multi-line items line
        // up with their own text instead of resetting to the margin.
        let prefixLength = (marker.location + marker.length) - lineRange.location
        guard prefixLength > 0 else { return }
        let prefix = nsSource.substring(
            with: NSRange(location: lineRange.location, length: prefixLength)
        ) + " "
        let paragraph = makeParagraphStyle()
        paragraph.headIndent = ceil(
            NSAttributedString(string: prefix, attributes: [.font: bodyFont]).size().width
        )
        apply([.paragraphStyle: paragraph], to: range)
    }

    private func style(_ table: Markdown.Table) {
        guard let range = nsRange(of: table), let sourceRange = table.range else { return }
        // Monospaced keeps the author's own column alignment readable. See the
        // type doc for why NSTextTable is deliberately not used.
        apply([.font: codeFont], to: range)

        let headerLine = sourceRange.lowerBound.line
        forEachLine(of: sourceRange) { lineRange, line in
            if isTableDelimiterLine(lineRange) {
                markRange(lineRange)
                return
            }
            if line == headerLine {
                applyFontTrait(.boldFontMask, in: lineRange)
            }
            markPipes(in: lineRange)
        }
    }

    private func style(_ rule: Markdown.ThematicBreak) {
        guard let range = nsRange(of: rule) else { return }
        markRange(range)
    }

    private func styleRawHTML(_ markup: any Markup) {
        guard let range = nsRange(of: markup) else { return }
        apply([.font: codeFont, .foregroundColor: theme.markerColor], to: range)
    }

    // MARK: - Inlines

    private func style(_ strong: Markdown.Strong) {
        guard let range = nsRange(of: strong),
              let span = delimitedSpan(in: range, delimiters: Self.emphasisDelimiters, minimumRun: 2)
        else { return }
        applyFontTrait(.boldFontMask, in: span.content)
        markRange(span.opening)
        markRange(span.closing)
    }

    private func style(_ emphasis: Markdown.Emphasis) {
        guard let range = nsRange(of: emphasis),
              let span = delimitedSpan(in: range, delimiters: Self.emphasisDelimiters, minimumRun: 1)
        else { return }
        applyFontTrait(.italicFontMask, in: span.content)
        markRange(span.opening)
        markRange(span.closing)
    }

    private func style(_ strikethrough: Markdown.Strikethrough) {
        guard let range = nsRange(of: strikethrough),
              let span = delimitedSpan(in: range, delimiters: [Self.tilde], minimumRun: 1)
        else { return }
        apply([.strikethroughStyle: NSUnderlineStyle.single.rawValue], to: span.content)
        markRange(span.opening)
        markRange(span.closing)
    }

    private func style(_ inlineCode: Markdown.InlineCode) {
        guard let range = nsRange(of: inlineCode),
              let span = delimitedSpan(in: range, delimiters: [Self.backtick], minimumRun: 1)
        else { return }
        apply([
            .font: codeFont,
            .foregroundColor: theme.codeColor,
            .inlineCode: true
        ], to: range)
        markRange(span.opening)
        markRange(span.closing)
        codeSpans.append(range)
    }

    private func style(_ link: Markdown.Link) {
        guard let range = nsRange(of: link), isPlausibleLinkSpan(range) else { return }

        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.linkChromeColor]
        let destination = link.destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !destination.isEmpty {
            attributes[.markdownRawLink] = destination
            attributes[.link] = Self.linkAttributeValue(for: destination)
        }
        apply(attributes, to: range)

        // Everything that is not the label — brackets, parentheses, angle
        // brackets, the destination — stays dimmed as chrome.
        for child in link.children {
            guard let childRange = nsRange(of: child) else { continue }
            apply([
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], to: childRange)
        }
    }

    private func style(_ image: Markdown.Image) {
        guard let range = nsRange(of: image), isPlausibleImageSpan(range) else { return }
        markRange(range)
        for child in image.children {
            guard let childRange = nsRange(of: child) else { continue }
            apply([.foregroundColor: theme.bodyColor], to: childRange)
        }
    }

    // MARK: - Wiki links

    /// Decorates `[[target]]`, `![[target]]`, and their aliased forms.
    ///
    /// CommonMark has no wiki-link production, so these arrive as ordinary text
    /// and cmark may split them across several `Text` nodes at each bracket.
    /// Scanning is therefore done per inline-containing block — bounded by that
    /// block's mapped range, and skipping any span that overlaps literal code.
    /// The raw target is attached as `.markdownRawLink` for a later step to
    /// resolve through ``WikiLinkResolver``.
    private func decorateWikiLinks() {
        for containerRange in inlineContainerRanges {
            scanWikiLinks(in: containerRange)
        }
    }

    private func scanWikiLinks(in range: NSRange) {
        let end = range.location + range.length
        var index = range.location
        while index + 4 <= end {
            guard character(at: index) == Self.openBracket,
                  character(at: index + 1) == Self.openBracket
            else {
                index += 1
                continue
            }
            guard let closingStart = wikiLinkClosingIndex(from: index + 2, limit: end) else {
                index += 1
                continue
            }
            // Include Obsidian's leading `!` in the styled/clickable chrome while keeping every
            // source character intact. The inner reference still begins after the two brackets.
            let spanStart = index > range.location && character(at: index - 1) == Self.bang
                ? index - 1
                : index
            let span = NSRange(location: spanStart, length: (closingStart + 2) - spanStart)
            let inner = NSRange(location: index + 2, length: closingStart - (index + 2))
            if inner.length > 0, !intersectsCodeSpan(span) {
                decorateWikiLink(
                    span: span,
                    inner: inner,
                    isEmbed: spanStart != index
                )
            }
            index = closingStart + 2
        }
    }

    /// Index of the first `]` of the terminating `]]`, or `nil` when the span
    /// is unterminated on its line.
    private func wikiLinkClosingIndex(from start: Int, limit: Int) -> Int? {
        var index = start
        while index + 2 <= limit {
            guard let current = character(at: index) else { return nil }
            if current == Self.newline || current == Self.carriageReturn {
                return nil
            }
            if current == Self.closeBracket, character(at: index + 1) == Self.closeBracket {
                return index > start ? index : nil
            }
            index += 1
        }
        return nil
    }

    private func decorateWikiLink(span: NSRange, inner: NSRange, isEmbed: Bool) {
        guard let reference = WikiLinkReference(rawInner: nsSource.substring(with: inner)) else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.linkChromeColor,
            .markdownRawLink: reference.target,
            .link: reference.target
        ]
        if isEmbed {
            attributes[.markdownObsidianEmbed] = true
        }
        apply(attributes, to: span)

        // The label is the alias when one is present, otherwise the target.
        var labelRange = inner
        if let pipeIndex = firstIndex(of: Self.pipe, in: inner) {
            labelRange = NSRange(
                location: pipeIndex + 1,
                length: (inner.location + inner.length) - (pipeIndex + 1)
            )
        }
        guard labelRange.length > 0 else { return }
        apply([
            .foregroundColor: theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], to: labelRange)
    }

    private func intersectsCodeSpan(_ range: NSRange) -> Bool {
        codeSpans.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // MARK: - Attribute application

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: theme.bodyColor,
            .paragraphStyle: makeParagraphStyle()
        ]
    }

    private func makeParagraphStyle() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0
        return paragraph
    }

    /// The single funnel every attribute write passes through: out-of-bounds or
    /// empty ranges are dropped rather than clamped onto neighbouring text.
    private func apply(_ attributes: [NSAttributedString.Key: Any], to range: NSRange) {
        let safe = range.clamped(to: storage.length)
        guard safe.length > 0 else { return }
        storage.addAttributes(attributes, range: safe)
    }

    private func markRange(_ range: NSRange) {
        apply([.foregroundColor: theme.markerColor], to: range)
    }

    private func markLine(_ line: Int) {
        guard let lineRange = mapper.lineContentRange(line: line) else { return }
        markRange(lineRange)
    }

    private func applyFontTrait(_ trait: NSFontTraitMask, in range: NSRange) {
        let safe = range.clamped(to: storage.length)
        guard safe.length > 0 else { return }
        var updates: [(NSFont, NSRange)] = []
        storage.enumerateAttribute(.font, in: safe, options: []) { value, subRange, _ in
            guard let font = value as? NSFont else { return }
            updates.append((NSFontManager.shared.convert(font, toHaveTrait: trait), subRange))
        }
        for (font, subRange) in updates {
            storage.addAttribute(.font, value: font, range: subRange)
        }
    }

    /// Runs the shared `CodeHighlighter` over a copy of the fence contents and
    /// transplants only its colours back, so highlighting can never alter text.
    private func applySyntaxHighlighting(in range: NSRange) {
        let safe = range.clamped(to: storage.length)
        guard safe.length > 0 else { return }
        let code = nsSource.substring(with: safe)
        let scratch = NSMutableAttributedString(string: code)
        CodeHighlighter.applyHighlighting(to: scratch, code: code)
        guard scratch.length == safe.length else { return }

        var updates: [(NSColor, NSRange)] = []
        scratch.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: scratch.length),
            options: []
        ) { value, subRange, _ in
            guard let color = value as? NSColor else { return }
            updates.append((
                color,
                NSRange(location: safe.location + subRange.location, length: subRange.length)
            ))
        }
        for (color, subRange) in updates {
            apply([.foregroundColor: color], to: subRange)
        }
    }

    // MARK: - Node-bounded lexical scanning

    private struct DelimitedSpan {
        let opening: NSRange
        let content: NSRange
        let closing: NSRange
    }

    /// Locates the delimiter runs at both edges of an already-mapped node
    /// range. Returning `nil` — because the run is missing or too short, or
    /// because nothing is left between the runs — means the mapped range did
    /// not look like the construct the parser reported, so the caller styles
    /// nothing at all.
    private func delimitedSpan(
        in range: NSRange,
        delimiters: Set<unichar>,
        minimumRun: Int
    ) -> DelimitedSpan? {
        let end = range.location + range.length
        var openingEnd = range.location
        while openingEnd < end, let value = character(at: openingEnd), delimiters.contains(value) {
            openingEnd += 1
        }
        let openingLength = openingEnd - range.location
        guard openingLength >= minimumRun else { return nil }

        var closingStart = end
        while closingStart > openingEnd,
              let value = character(at: closingStart - 1),
              delimiters.contains(value)
        {
            closingStart -= 1
        }
        let closingLength = end - closingStart
        guard closingLength >= minimumRun, closingStart > openingEnd else { return nil }

        return DelimitedSpan(
            opening: NSRange(location: range.location, length: openingLength),
            content: NSRange(location: openingEnd, length: closingStart - openingEnd),
            closing: NSRange(location: closingStart, length: closingLength)
        )
    }

    private func leadingHashRun(in range: NSRange) -> NSRange? {
        let end = range.location + range.length
        var index = range.location
        while index < end, let value = character(at: index), isSpaceOrTab(value) {
            index += 1
        }
        let start = index
        while index < end, character(at: index) == Self.hash {
            index += 1
        }
        guard index > start else { return nil }
        return NSRange(location: start, length: index - start)
    }

    private func trailingHashRun(in range: NSRange) -> NSRange? {
        var end = range.location + range.length
        while end > range.location, let value = character(at: end - 1), isSpaceOrTab(value) {
            end -= 1
        }
        var start = end
        while start > range.location, character(at: start - 1) == Self.hash {
            start -= 1
        }
        guard start < end else { return nil }
        // A closing sequence must be preceded by a space; otherwise this is the
        // opening run of a heading with no text, already handled above.
        guard start > range.location, let previous = character(at: start - 1), isSpaceOrTab(previous)
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func leadingQuoteRun(in lineRange: NSRange) -> NSRange? {
        let end = lineRange.location + lineRange.length
        var index = lineRange.location
        while index < end, let value = character(at: index), isSpaceOrTab(value) {
            index += 1
        }
        let start = index
        while index < end, character(at: index) == Self.greaterThan {
            index += 1
            if index < end, let value = character(at: index), isSpaceOrTab(value) {
                index += 1
            }
        }
        guard index > start else { return nil }
        return NSRange(location: start, length: index - start)
    }

    private func listMarkerRun(in lineRange: NSRange, startingAt start: Int) -> NSRange? {
        let end = lineRange.location + lineRange.length
        guard start >= lineRange.location, start < end else { return nil }

        var index = start
        if let value = character(at: index), Self.bulletMarkers.contains(value) {
            index += 1
        } else {
            while index < end, let value = character(at: index), isDigit(value) {
                index += 1
            }
            guard index > start, index < end, let value = character(at: index),
                  value == Self.period || value == Self.closeParen
            else { return nil }
            index += 1
        }
        // A list marker is only a marker when whitespace or a line end follows.
        if index < end {
            guard let value = character(at: index), isSpaceOrTab(value) else { return nil }
        }
        return NSRange(location: start, length: index - start)
    }

    private func isFenceLine(_ line: Int) -> Bool {
        guard let lineRange = mapper.lineContentRange(line: line) else { return false }
        let end = lineRange.location + lineRange.length
        var index = lineRange.location
        while index < end, index - lineRange.location < 3,
              let value = character(at: index), value == Self.space
        {
            index += 1
        }
        guard let fence = character(at: index), fence == Self.backtick || fence == Self.tilde else {
            return false
        }
        var run = 0
        while index < end, character(at: index) == fence {
            run += 1
            index += 1
        }
        return run >= 3
    }

    private func isTableDelimiterLine(_ lineRange: NSRange) -> Bool {
        let end = lineRange.location + lineRange.length
        guard lineRange.length > 0 else { return false }
        var sawHyphen = false
        for index in lineRange.location ..< end {
            guard let value = character(at: index) else { return false }
            if value == Self.hyphen {
                sawHyphen = true
                continue
            }
            guard value == Self.pipe || value == Self.colon || isSpaceOrTab(value) else {
                return false
            }
        }
        return sawHyphen
    }

    private func markPipes(in lineRange: NSRange) {
        let end = lineRange.location + lineRange.length
        for index in lineRange.location ..< end where character(at: index) == Self.pipe {
            markRange(NSRange(location: index, length: 1))
        }
    }

    private func firstIndex(of target: unichar, in range: NSRange) -> Int? {
        let end = range.location + range.length
        for index in range.location ..< end where character(at: index) == target {
            return index
        }
        return nil
    }

    private func isPlausibleLinkSpan(_ range: NSRange) -> Bool {
        guard let first = character(at: range.location),
              let last = character(at: range.location + range.length - 1)
        else { return false }
        guard first == Self.openBracket || first == Self.lessThan else { return false }
        return last == Self.closeParen || last == Self.closeBracket || last == Self.greaterThan
    }

    private func isPlausibleImageSpan(_ range: NSRange) -> Bool {
        guard range.length >= 2, character(at: range.location) == Self.bang else { return false }
        return character(at: range.location + 1) == Self.openBracket
    }

    // MARK: - Line iteration

    private func forEachLine(of sourceRange: SourceRange, _ body: (NSRange) -> Void) {
        forEachLine(of: sourceRange) { lineRange, _ in body(lineRange) }
    }

    private func forEachLine(of sourceRange: SourceRange, _ body: (NSRange, Int) -> Void) {
        let firstLine = sourceRange.lowerBound.line
        let lastLine = max(firstLine, sourceRange.upperBound.line)
        guard firstLine >= 1 else { return }
        for line in firstLine ... lastLine {
            guard let lineRange = mapper.lineContentRange(line: line) else { continue }
            body(lineRange, line)
        }
    }

    // MARK: - Primitives

    private func nsRange(of markup: any Markup) -> NSRange? {
        guard let sourceRange = markup.range,
              let mapped = mapper.nsRange(for: sourceRange)
        else { return nil }
        let safe = mapped.clamped(to: storage.length)
        return safe.length > 0 ? safe : nil
    }

    private func character(at index: Int) -> unichar? {
        guard index >= 0, index < nsSource.length else { return nil }
        return nsSource.character(at: index)
    }

    private func isSpaceOrTab(_ value: unichar) -> Bool {
        value == Self.space || value == Self.tab
    }

    private func isDigit(_ value: unichar) -> Bool {
        value >= Self.zero && value <= Self.nine
    }

    private static func linkAttributeValue(for destination: String) -> Any {
        if let url = URL(string: destination),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme)
        {
            return url
        }
        return destination
    }

    // MARK: - Character constants

    private static let hash = markdownScalar("#")
    private static let asterisk = markdownScalar("*")
    private static let underscore = markdownScalar("_")
    private static let tilde = markdownScalar("~")
    private static let backtick = markdownScalar("`")
    private static let space = markdownScalar(" ")
    private static let tab = markdownScalar("\t")
    private static let greaterThan = markdownScalar(">")
    private static let lessThan = markdownScalar("<")
    private static let pipe = markdownScalar("|")
    private static let hyphen = markdownScalar("-")
    private static let plus = markdownScalar("+")
    private static let colon = markdownScalar(":")
    private static let period = markdownScalar(".")
    private static let bang = markdownScalar("!")
    private static let openBracket = markdownScalar("[")
    private static let closeBracket = markdownScalar("]")
    private static let closeParen = markdownScalar(")")
    private static let newline = markdownScalar("\n")
    private static let carriageReturn = markdownScalar("\r")
    private static let zero = markdownScalar("0")
    private static let nine = markdownScalar("9")

    private static let emphasisDelimiters: Set<unichar> = [asterisk, underscore]
    private static let bulletMarkers: Set<unichar> = [hyphen, plus, asterisk]
}

private func markdownScalar(_ scalar: UnicodeScalar) -> unichar {
    unichar(scalar.value)
}
