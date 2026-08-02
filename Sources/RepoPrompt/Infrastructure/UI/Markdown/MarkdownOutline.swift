import Foundation
import Markdown

/// One H1–H4 entry in a Markdown document's reader outline.
struct MarkdownOutlineHeading: Equatable, Identifiable {
    /// Source-order identity. Duplicated heading text intentionally receives a distinct ID.
    let id: Int
    let level: Int
    let title: String
    /// UTF-16 offset of the heading marker in the verbatim source.
    let sourceOffset: Int
}

/// Extracts the navigation outline from the same swift-markdown AST used by both renderers.
enum MarkdownOutlineExtractor {
    static func headings(in source: String) -> [MarkdownOutlineHeading] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let mapper = MarkdownSourceRangeMapper(source: source)
        var result: [MarkdownOutlineHeading] = []
        collect(from: document, mapper: mapper, into: &result)
        return result
    }

    private static func collect(
        from markup: any Markup,
        mapper: MarkdownSourceRangeMapper,
        into result: inout [MarkdownOutlineHeading]
    ) {
        if let heading = markup as? Heading,
           (1 ... 4).contains(heading.level),
           let sourceRange = heading.range,
           let mappedRange = mapper.nsRange(for: sourceRange)
        {
            let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                result.append(MarkdownOutlineHeading(
                    id: result.count,
                    level: heading.level,
                    title: title,
                    sourceOffset: mappedRange.location
                ))
            }
        }

        for child in markup.children {
            collect(from: child, mapper: mapper, into: &result)
        }
    }
}

/// Reads the occurrence-based anchors emitted by the preview's opt-in rendered compiler.
enum RenderedMarkdownHeadingAnchorMapper {
    static func offsets(in attributedString: NSAttributedString) -> [Int: Int] {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        var offsets: [Int: Int] = [:]
        attributedString.enumerateAttribute(.markdownHeadingAnchor, in: fullRange) { value, range, _ in
            guard let headingID = value as? Int, offsets[headingID] == nil else { return }
            offsets[headingID] = range.location
        }
        return offsets
    }
}

extension NSAttributedString.Key {
    static let markdownHeadingAnchor = NSAttributedString.Key("markdownHeadingAnchor")
}
