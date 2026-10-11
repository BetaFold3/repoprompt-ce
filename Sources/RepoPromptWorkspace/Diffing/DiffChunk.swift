import SwiftUI

package struct DiffChunk: Equatable {
    package var lines: [DiffLine]
    package var startLine: Int

    func lineCountDifference() -> Int {
        lines.reduce(0) { count, line in
            switch line.type {
            case .addition: count + 1
            case .removal: count - 1
            case .context: count
            }
        }
    }

    /// Number of lines that appear in the old version (context + removals)
    var oldLineCount: Int {
        lines.count(where: { $0.type == .context || $0.type == .removal })
    }

    /// Number of lines that appear in the new version (context + additions)
    var newLineCount: Int {
        lines.count(where: { $0.type == .context || $0.type == .addition })
    }

    func withEncodedIndentation() -> DiffChunk {
        let encodedLines = lines.map { line in
            let prefix = line.prefix
            return DiffLine(content: prefix + String.encodeIndentation(line.content))
        }
        return DiffChunk(lines: encodedLines, startLine: startLine)
    }

    package func withDecodedIndentation() -> DiffChunk {
        let decodedLines = lines.map { line in
            let prefix = line.prefix
            return DiffLine(content: prefix + String.decodeIndentation(line.content))
        }
        return DiffChunk(lines: decodedLines, startLine: startLine)
    }

    private func scoreMatch(in content: [String], startingAt line: Int) -> Int {
        var score = 0
        let windowSize = min(lines.count, 3)

        for i in 0 ..< windowSize {
            if line + i < content.count, lines[i].type == .context {
                let contextLine = lines[i].content
                let contentLine = content[line + i]
                if contextLine.isSimilar(to: contentLine, threshold: 0.8) {
                    score += 1
                }
            }
        }

        return score
    }

    /// Implement Equatable
    package static func == (lhs: DiffChunk, rhs: DiffChunk) -> Bool {
        lhs.lines == rhs.lines
    }
}

import Foundation

package struct DiffLine: Equatable {
    package enum LineType: Equatable {
        case addition
        case removal
        case context
    }

    package let type: LineType
    var content: String
    let rawContent: String

    init(content: String) {
        rawContent = content
        switch content.prefix(1) {
        case "+":
            type = .addition
            self.content = String(content.dropFirst())
        case "-":
            type = .removal
            self.content = String(content.dropFirst())
        default:
            type = .context
            self.content = String(content.dropFirst())
        }
    }

    var prefix: String {
        switch type {
        case .addition: "+"
        case .removal: "-"
        case .context: " "
        }
    }

    var prefixColor: Color {
        switch type {
        case .addition: .green
        case .removal: .red
        case .context: .primary
        }
    }

    var contentColor: Color {
        switch type {
        case .addition, .removal: .primary
        case .context: .secondary
        }
    }

    var backgroundColor: Color {
        switch type {
        case .addition: Color.green.opacity(0.1)
        case .removal: Color.red.opacity(0.1)
        case .context: Color.clear
        }
    }

    /// Implement Equatable with fuzzy comparison
    package static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.type == rhs.type &&
            lhs.content.isSimilar(to: rhs.content, threshold: 0.9) &&
            lhs.rawContent.isSimilar(to: rhs.rawContent, threshold: 0.9)
    }
}
