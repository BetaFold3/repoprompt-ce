import Foundation
import Markdown
import MCP
import SwiftUI

struct ToolMarkdownExpandedContent: View {
    let item: AgentChatItem
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var maxHeight: CGFloat {
        fontPreset.scaledClamped(200, max: 320)
    }

    private var markdown: String? {
        ToolResultMarkdownRenderer.renderMarkdown(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON,
            resultPayload: item.toolResultJSON
        )
    }

    var body: some View {
        if let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty {
            ToolScrollableMarkdownTextView(
                text: markdown,
                maxHeight: maxHeight,
                detectsMarkdownFilePaths: true
            )
        } else {
            Text("No result")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct ToolScrollableMarkdownTextView: View {
    let text: String
    let maxHeight: CGFloat
    let detectsMarkdownFilePaths: Bool
    @Environment(\.markdownFileLinkOpener) private var markdownFileLinkOpener
    @ObservedObject private var fontScale = FontScaleManager.shared

    init(
        text: String,
        maxHeight: CGFloat,
        detectsMarkdownFilePaths: Bool = false
    ) {
        self.text = text
        self.maxHeight = maxHeight
        self.detectsMarkdownFilePaths = detectsMarkdownFilePaths
    }

    static func detectedFileLinks(
        in text: String,
        enabled: Bool
    ) -> [MarkdownFilePathLinkDetector.Match] {
        enabled ? ToolResultMarkdownLinkifier.matches(in: text) : []
    }

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    /// Use the codeFont size (rawValue - 2) for a tighter fit in tool cards
    private var fontSize: Double {
        max(Double(fontScale.preset.rawValue) - 2, 9)
    }

    private var wrapLines: Bool {
        globalSettings.wrapTranscriptDiffLines()
    }

    var body: some View {
        TextKitView(
            text: .constant(text),
            isEditable: false,
            isSpellCheckEnabled: false,
            fontSize: fontSize,
            useMonospacedFont: true,
            useTranscriptCodeFont: true,
            preferredTranscriptCodeFontPostScriptName: globalSettings.transcriptCodeFontPostScriptName(),
            wrapLines: wrapLines,
            autohidesScrollers: true,
            scrollerStyle: .overlay,
            detectedMarkdownFileLinks: Self.detectedFileLinks(
                in: text,
                enabled: detectsMarkdownFilePaths
            ),
            markdownFileLinkOpener: markdownFileLinkOpener
        )
        // Live TextKit 1 wrap-geometry mutation can leave the view blank; the creation path is the
        // only reliable one, so this forces recreation. Removing it regresses the blank-card bug.
        .id(wrapLines)
        .frame(height: maxHeight, alignment: .topLeading)
    }
}

private final class ToolResultMarkdownLinkMatchesBox: NSObject {
    let matches: [MarkdownFilePathLinkDetector.Match]

    init(_ matches: [MarkdownFilePathLinkDetector.Match]) {
        self.matches = matches
    }
}

enum ToolResultMarkdownLinkifier {
    private static let cache: NSCache<NSString, ToolResultMarkdownLinkMatchesBox> = {
        let cache = NSCache<NSString, ToolResultMarkdownLinkMatchesBox>()
        cache.countLimit = 16
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func matches(in source: String) -> [MarkdownFilePathLinkDetector.Match] {
        guard !source.isEmpty,
              MarkdownFilePathLinkDetector.containsSupportedExtension(in: source)
        else { return [] }

        let cacheKey = source as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.matches
        }

        let document = Document(parsing: source, options: [.disableSmartOpts])
        let mapper = MarkdownSourceRangeMapper(source: source)
        let nsSource = source as NSString
        var result: [MarkdownFilePathLinkDetector.Match] = []
        collectMatches(
            from: document,
            mapper: mapper,
            source: nsSource,
            into: &result
        )
        let sorted = result.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
        cache.setObject(
            ToolResultMarkdownLinkMatchesBox(sorted),
            forKey: cacheKey,
            cost: source.utf8.count
        )
        return sorted
    }

    private static func collectMatches(
        from markup: any Markup,
        mapper: MarkdownSourceRangeMapper,
        source: NSString,
        into result: inout [MarkdownFilePathLinkDetector.Match]
    ) {
        if markup is Markdown.CodeBlock || markup is Markdown.Link {
            return
        }

        if let inlineCode = markup as? Markdown.InlineCode {
            guard let match = MarkdownFilePathLinkDetector.inlineCodeMatch(in: inlineCode.code),
                  let sourceRange = inlineCode.range,
                  let mappedRange = mapper.nsRange(for: sourceRange)
            else { return }

            let pathRange = source.range(of: match.path, options: [], range: mappedRange)
            guard pathRange.location != NSNotFound else { return }
            result.append(.init(range: pathRange, path: match.path))
            return
        }

        if markup is Markdown.Text,
           let sourceRange = markup.range,
           let mappedRange = mapper.nsRange(for: sourceRange)
        {
            let text = source.substring(with: mappedRange)
            for match in MarkdownFilePathLinkDetector.proseMatches(in: text) {
                result.append(.init(
                    range: NSRange(
                        location: mappedRange.location + match.range.location,
                        length: match.range.length
                    ),
                    path: match.path
                ))
            }
            return
        }

        for child in markup.children {
            collectMatches(
                from: child,
                mapper: mapper,
                source: source,
                into: &result
            )
        }
    }
}

private enum ToolResultMarkdownRenderer {
    private static let emitResourceContentKey = "mcp.emitResourceContent"

    static func renderMarkdown(toolName: String?, argsJSON: String?, resultPayload: String?) -> String? {
        guard let payload = resultPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }

        if let transportMarkdown = mcpTransportMarkdown(from: payload) {
            return transportMarkdown
        }

        let preferredPayload = ToolJSON.preferredStructuredResultJSON(from: payload) ?? payload
        guard looksLikeJSONObjectOrArray(preferredPayload),
              let value = Value.fromJSONString(preferredPayload)
        else {
            return preferredPayload
        }

        let args = argsJSON.flatMap(Value.objectFromJSONString) ?? [:]
        let normalizedToolName = normalizedToolCardName(toolName) ?? ""
        let emitResources = UserDefaults.standard.bool(forKey: emitResourceContentKey)

        let blocks = ToolOutputFormatter.buildContentBlocks(
            toolName: normalizedToolName,
            args: args,
            result: value,
            emitResources: emitResources
        )

        let joinedText = extractText(from: blocks)
        if !joinedText.isEmpty {
            return joinedText
        }
        return preferredPayload
    }

    private static func mcpTransportMarkdown(from payload: String) -> String? {
        guard let object = ToolRawJSON.object(from: payload) else { return nil }
        let envelope = (object["Ok"] as? [String: Any])
            ?? (object["ok"] as? [String: Any])
            ?? (object["Err"] as? [String: Any])
            ?? (object["err"] as? [String: Any])
        guard let content = envelope?["content"] as? [Any], !content.isEmpty else { return nil }
        let textParts = content.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            if let type = block["type"] as? String,
               type.lowercased() != "text"
            {
                return nil
            }
            return block["text"] as? String
        }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !textParts.isEmpty else { return nil }
        return textParts.joined(separator: "\n\n")
    }

    private static func looksLikeJSONObjectOrArray(_ payload: String) -> Bool {
        guard let first = payload.first, let last = payload.last else {
            return false
        }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    private static func extractText(from blocks: [MCP.Tool.Content]) -> String {
        let textParts = blocks.compactMap { block -> String? in
            if case let .text(text: text, annotations: _, _meta: _) = block {
                return text
            }
            return nil
        }
        return textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
