import Foundation

/// Splits unified-diff output without decoding or normalizing any patch byte.
///
/// Only an ASCII `diff --git ` sequence at a physical line start begins a file. A changed body
/// line containing the same words starts with its diff marker and therefore cannot split the input.
enum GitRawDiffFileSplitter {
    private static let boundary = Array("diff --git ".utf8)

    /// Returns raw file-patch spans in source order, excluding any diagnostic preamble.
    static func split(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        let bytes = Array(data)
        var starts: [Int] = []

        for index in bytes.indices where index == 0 || bytes[index - 1] == 0x0A {
            guard index + boundary.count <= bytes.count else { continue }
            if bytes[index ..< index + boundary.count].elementsEqual(boundary) {
                starts.append(index)
            }
        }

        guard !starts.isEmpty else { return [] }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : bytes.count
            return Data(bytes[start ..< end])
        }
    }

    /// Associates raw spans with the existing rendered per-file keys.
    ///
    /// Exact byte equality is the association proof. Count mismatches, duplicate/ambiguous rendered
    /// blocks, invalid decoding upstream, or any normalization difference return `nil` so partial
    /// staging remains unavailable while ordinary rendering can continue.
    static func split(
        _ data: Data,
        matching renderedPerFile: [String: String]
    ) -> [String: Data]? {
        let spans = split(data)
        guard spans.count == renderedPerFile.count else { return nil }

        let rendered = renderedPerFile.map { (key: $0.key, data: Data($0.value.utf8)) }
        var usedKeys = Set<String>()
        var result: [String: Data] = [:]

        for span in spans {
            let matches = rendered.filter { !usedKeys.contains($0.key) && $0.data == span }
            guard matches.count == 1, let match = matches.first else { return nil }
            usedKeys.insert(match.key)
            result[match.key] = span
        }

        return result.count == renderedPerFile.count ? result : nil
    }
}
