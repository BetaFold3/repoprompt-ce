import Foundation
import Markdown

/// One parsed Obsidian `![[target]]` or `![[target|alt]]` span.
struct ObsidianEmbed: Equatable {
    let sourceRange: NSRange
    let reference: WikiLinkReference
}

/// Lexes embeds from ordinary Markdown text while leaving inline and fenced code untouched.
enum ObsidianEmbedParser {
    static func embeds(in source: String) -> [ObsidianEmbed] {
        let excludedRanges = codeRanges(in: source)
        let nsSource = source as NSString
        var result: [ObsidianEmbed] = []
        var cursor = 0

        while cursor + 5 <= nsSource.length {
            guard nsSource.character(at: cursor) == Character.bang,
                  nsSource.character(at: cursor + 1) == Character.openBracket,
                  nsSource.character(at: cursor + 2) == Character.openBracket
            else {
                cursor += 1
                continue
            }

            guard let closing = closingBracketIndex(in: nsSource, from: cursor + 3) else {
                cursor += 1
                continue
            }

            let span = NSRange(location: cursor, length: closing + 2 - cursor)
            defer { cursor = NSMaxRange(span) }
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, span).length > 0 }) else {
                continue
            }

            let inner = NSRange(location: cursor + 3, length: closing - (cursor + 3))
            guard let reference = WikiLinkReference(rawInner: nsSource.substring(with: inner)) else {
                continue
            }
            result.append(ObsidianEmbed(sourceRange: span, reference: reference))
        }

        return result
    }

    private static func closingBracketIndex(in source: NSString, from start: Int) -> Int? {
        var cursor = start
        while cursor + 1 < source.length {
            let character = source.character(at: cursor)
            if character == Character.newline || character == Character.carriageReturn {
                return nil
            }
            if character == Character.closeBracket,
               source.character(at: cursor + 1) == Character.closeBracket
            {
                return cursor == start ? nil : cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func codeRanges(in source: String) -> [NSRange] {
        let mapper = MarkdownSourceRangeMapper(source: source)
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var result: [NSRange] = []
        collectCodeRanges(from: document, mapper: mapper, into: &result)
        return result
    }

    private static func collectCodeRanges(
        from markup: any Markup,
        mapper: MarkdownSourceRangeMapper,
        into result: inout [NSRange]
    ) {
        if markup is Markdown.InlineCode || markup is Markdown.CodeBlock,
           let range = markup.range,
           let mapped = mapper.nsRange(for: range)
        {
            result.append(mapped)
            return
        }
        for child in markup.children {
            collectCodeRanges(from: child, mapper: mapper, into: &result)
        }
    }

    private enum Character {
        static let bang: unichar = 33
        static let openBracket: unichar = 91
        static let closeBracket: unichar = 93
        static let newline: unichar = 10
        static let carriageReturn: unichar = 13
    }
}

/// Converts Obsidian embeds into CommonMark that `EnhancedMarkdownCompiler` already understands.
///
/// Image embeds become Markdown images and therefore flow through the preview's contained image
/// provider. Note embeds become quiet, explicit inline links and retain the ordinary wiki-link
/// activation path. Semi-rendered mode never calls this processor, so its source stays verbatim.
enum ObsidianEmbedProcessor {
    static func renderedMarkdown(
        from source: String,
        resolver: WikiLinkResolver,
        documentRelativePath: String
    ) -> String {
        let embeds = ObsidianEmbedParser.embeds(in: source)
        guard !embeds.isEmpty else { return source }

        let result = NSMutableString(string: source)
        for embed in embeds.reversed() {
            let replacement = renderedReplacement(
                for: embed,
                resolver: resolver,
                documentRelativePath: documentRelativePath,
                originalSource: source
            )
            result.replaceCharacters(in: embed.sourceRange, with: replacement)
        }
        return result as String
    }

    private static func renderedReplacement(
        for embed: ObsidianEmbed,
        resolver: WikiLinkResolver,
        documentRelativePath: String,
        originalSource: String
    ) -> String {
        switch resolver.resolveEmbed(embed.reference) {
        case let .resolved(relativePath, _, .image):
            let localPath = relativePathFromDocument(
                documentRelativePath: documentRelativePath,
                targetRootRelativePath: relativePath
            )
            return "![\(escapedLabel(embed.reference.displayText))](\(encodedDestination(localPath)))"

        case let .resolved(relativePath, fragment, .note):
            return noteLink(
                label: embed.reference.displayText,
                destination: relativePath,
                fragment: fragment
            )

        case .rejected(.notFound):
            if WikiLinkResolver.isImagePath(embed.reference.target) {
                let rootRelativePath = (embed.reference.target as NSString).standardizingPath
                let localPath = relativePathFromDocument(
                    documentRelativePath: documentRelativePath,
                    targetRootRelativePath: rootRelativePath
                )
                return "![\(escapedLabel(embed.reference.displayText))](\(encodedDestination(localPath)))"
            }
            return noteLink(
                label: embed.reference.displayText,
                destination: embed.reference.target,
                fragment: embed.reference.fragment
            )

        case .rejected:
            return (originalSource as NSString).substring(with: embed.sourceRange)
        }
    }

    private static func noteLink(label: String, destination: String, fragment: String?) -> String {
        var encoded = encodedDestination(destination)
        if let fragment, !fragment.isEmpty {
            encoded += "#" + encodedFragment(fragment)
        }
        return "[Embedded note: \(escapedLabel(label))](\(encoded))"
    }

    private static func relativePathFromDocument(
        documentRelativePath: String,
        targetRootRelativePath: String
    ) -> String {
        let documentDirectory = (documentRelativePath as NSString).deletingLastPathComponent
        let from = documentDirectory.split(separator: "/").map(String.init)
        let to = targetRootRelativePath.split(separator: "/").map(String.init)
        var commonCount = 0
        while commonCount < min(from.count, to.count), from[commonCount] == to[commonCount] {
            commonCount += 1
        }
        let upward = Array(repeating: "..", count: from.count - commonCount)
        let downward = Array(to.dropFirst(commonCount))
        let components = upward + downward
        return components.isEmpty ? (targetRootRelativePath as NSString).lastPathComponent : components.joined(separator: "/")
    }

    private static func escapedLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func encodedDestination(_ destination: String) -> String {
        destination.addingPercentEncoding(withAllowedCharacters: destinationAllowedCharacters) ?? destination
    }

    private static func encodedFragment(_ fragment: String) -> String {
        fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? fragment
    }

    private static let destinationAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.formUnion(CharacterSet(charactersIn: "-._~/%"))
        return characters
    }()
}
