import Foundation

package enum MarkdownFilePathLinkDetector {
    package struct Match: Equatable {
        package let range: NSRange
        package let path: String

        package init(range: NSRange, path: String) {
            self.range = range
            self.path = path
        }
    }

    static let supportedExtensions: Set<String> = ["md", "markdown", "html", "htm"]

    private static let extensionAlternation = supportedExtensions
        .sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:))
        .joined(separator: "|")

    private static let extensionNeedles = supportedExtensions.map { ".\($0)" }

    private static let proseExpression = try! NSRegularExpression(
        pattern: #"(?<![#:~\p{L}\p{N}_./])(?:~\/|\.\.?\/|\/)?[^\s:#<>\"'\x60()\[\]{}]+?\.(?:"# +
            extensionAlternation +
            #")(?::[0-9]+)?(?![\p{L}\p{N}_/]|\.(?!$|[\s,;!?)}\]]))"#,
        options: [.caseInsensitive]
    )

    package static func proseMatches(in text: String) -> [Match] {
        guard containsSupportedExtension(in: text) else { return [] }

        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        return proseExpression.matches(in: text, range: fullRange).compactMap {
            let path = (text as NSString).substring(with: $0.range)
            guard isValidCandidate(path) else { return nil }
            return Match(range: $0.range, path: path)
        }
    }

    package static func inlineCodeMatch(in span: String) -> Match? {
        guard span.utf16.count <= 512, !span.contains(where: \.isNewline) else { return nil }

        let trimmed = span.trimmingCharacters(in: .whitespaces)
        guard isValidCandidate(trimmed) else { return nil }

        let range = (span as NSString).range(of: trimmed)
        return Match(range: range, path: trimmed)
    }

    package static func containsSupportedExtension(in text: String) -> Bool {
        extensionNeedles.contains {
            text.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    private static func isValidCandidate(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("//"), !value.contains("#") else { return false }

        let path: String
        if let colon = value.lastIndex(of: ":") {
            let suffix = value[value.index(after: colon)...]
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return false }
            path = String(value[..<colon])
        } else {
            path = value
        }

        guard !path.isEmpty, !path.hasPrefix("//"), !hasSchemePrefix(path) else { return false }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }

    private static func hasSchemePrefix(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let prefix = value[..<colon]
        guard let first = prefix.first, first.isASCII, first.isLetter else { return false }
        return prefix.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-")
        }
    }
}
