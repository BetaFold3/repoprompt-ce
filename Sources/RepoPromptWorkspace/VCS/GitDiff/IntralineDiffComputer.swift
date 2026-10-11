import Foundation

/// Computes subtle word-level emphasis ranges for paired deletion/addition lines.
///
/// Ranges are UTF-16 offsets into `FileDiffProjection.Line.text`, matching AppKit and
/// `AttributedString` bridging. The computer is opt-in at the projection call site so MCP diff
/// extraction continues to use the frozen wire path without intraline work or output changes.
enum IntralineDiffComputer {
    struct Ranges: Equatable {
        let deletion: [Range<Int>]
        let addition: [Range<Int>]
    }

    static let defaultSimilarityThreshold = 0.35
    private static let maximumTokenCount = 256

    /// Annotates equal-length adjacent deletion/addition runs line by line.
    ///
    /// Unequal runs are intentionally left alone. Guessing a pairing across an inserted or removed
    /// line tends to emphasize unrelated text and is noisier than the line-level tint.
    static func annotating(
        _ lines: [FileDiffProjection.Line],
        similarityThreshold: Double = defaultSimilarityThreshold
    ) -> [FileDiffProjection.Line] {
        var result = lines
        var index = 0

        while index < lines.count {
            guard lines[index].kind == .deletion else {
                index += 1
                continue
            }

            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion {
                index += 1
            }
            let deletionEnd = index
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition {
                index += 1
            }
            let additionEnd = index

            guard additionStart < additionEnd,
                  deletionEnd - deletionStart == additionEnd - additionStart
            else { continue }

            for offset in 0 ..< (deletionEnd - deletionStart) {
                let deletionIndex = deletionStart + offset
                let additionIndex = additionStart + offset
                guard let ranges = ranges(
                    deletion: lines[deletionIndex].text,
                    addition: lines[additionIndex].text,
                    similarityThreshold: similarityThreshold
                ) else { continue }

                result[deletionIndex] = copying(
                    lines[deletionIndex],
                    intralineRanges: ranges.deletion
                )
                result[additionIndex] = copying(
                    lines[additionIndex],
                    intralineRanges: ranges.addition
                )
            }
        }

        return result
    }

    /// Computes changed spans between two related lines.
    ///
    /// Exact word/whitespace/punctuation tokens are aligned with LCS. Each unmatched block is then
    /// trimmed by its common grapheme prefix and suffix, so a one-character edit inside a Unicode
    /// word highlights only that edit without ever splitting a surrogate pair or combining cluster.
    static func ranges(
        deletion: String,
        addition: String,
        similarityThreshold: Double = defaultSimilarityThreshold
    ) -> Ranges? {
        guard deletion != addition else { return nil }
        let deletionLength = deletion.utf16.count
        let additionLength = addition.utf16.count
        let maximumLength = max(deletionLength, additionLength)
        guard maximumLength > 0 else { return nil }

        let deletionTokens = tokenize(deletion)
        let additionTokens = tokenize(addition)
        let matches: [TokenMatch] = if deletionTokens.count <= maximumTokenCount,
                                       additionTokens.count <= maximumTokenCount
        {
            lcsMatches(deletionTokens, additionTokens)
        } else {
            []
        }

        var deletionRanges: [Range<Int>] = []
        var additionRanges: [Range<Int>] = []
        var deletionCursor = 0
        var additionCursor = 0

        for match in matches {
            appendRefinedBlock(
                deletion: deletion,
                deletionRange: deletionCursor ..< match.deletion.range.lowerBound,
                addition: addition,
                additionRange: additionCursor ..< match.addition.range.lowerBound,
                deletionRanges: &deletionRanges,
                additionRanges: &additionRanges
            )
            deletionCursor = match.deletion.range.upperBound
            additionCursor = match.addition.range.upperBound
        }

        appendRefinedBlock(
            deletion: deletion,
            deletionRange: deletionCursor ..< deletionLength,
            addition: addition,
            additionRange: additionCursor ..< additionLength,
            deletionRanges: &deletionRanges,
            additionRanges: &additionRanges
        )

        deletionRanges = coalescing(deletionRanges)
        additionRanges = coalescing(additionRanges)
        guard !deletionRanges.isEmpty || !additionRanges.isEmpty else { return nil }

        let changedLength = max(
            deletionRanges.reduce(0) { $0 + $1.count },
            additionRanges.reduce(0) { $0 + $1.count }
        )
        let similarity = 1 - Double(changedLength) / Double(maximumLength)
        guard similarity >= min(max(similarityThreshold, 0), 1) else { return nil }

        return Ranges(deletion: deletionRanges, addition: additionRanges)
    }

    // MARK: - Token LCS

    private struct Token: Equatable {
        enum Category: Equatable {
            case word
            case whitespace
            case punctuation
        }

        let text: String
        let range: Range<Int>
        let category: Category
    }

    private struct TokenMatch {
        let deletion: Token
        let addition: Token
    }

    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        var tokens: [Token] = []
        var currentText = ""
        var currentCategory: Token.Category?
        var tokenStart = 0
        var offset = 0

        func flush() {
            guard let currentCategory, !currentText.isEmpty else { return }
            tokens.append(Token(
                text: currentText,
                range: tokenStart ..< offset,
                category: currentCategory
            ))
            currentText = ""
        }

        for character in text {
            let category = category(of: character)
            let length = String(character).utf16.count
            if category != currentCategory {
                flush()
                currentCategory = category
                tokenStart = offset
            }
            currentText.append(character)
            offset += length
        }
        flush()
        return tokens
    }

    private static func category(of character: Character) -> Token.Category {
        if character.isWhitespace { return .whitespace }
        if character.isLetter || character.isNumber || character == "_" { return .word }
        return .punctuation
    }

    private static func lcsMatches(_ deletion: [Token], _ addition: [Token]) -> [TokenMatch] {
        let columnCount = addition.count + 1
        var lengths = Array(
            repeating: 0,
            count: (deletion.count + 1) * columnCount
        )

        if !deletion.isEmpty, !addition.isEmpty {
            for deletionIndex in stride(from: deletion.count - 1, through: 0, by: -1) {
                for additionIndex in stride(from: addition.count - 1, through: 0, by: -1) {
                    let cell = deletionIndex * columnCount + additionIndex
                    if deletion[deletionIndex].text == addition[additionIndex].text,
                       deletion[deletionIndex].category == addition[additionIndex].category
                    {
                        lengths[cell] = 1 + lengths[(deletionIndex + 1) * columnCount + additionIndex + 1]
                    } else {
                        lengths[cell] = max(
                            lengths[(deletionIndex + 1) * columnCount + additionIndex],
                            lengths[deletionIndex * columnCount + additionIndex + 1]
                        )
                    }
                }
            }
        }

        var matches: [TokenMatch] = []
        var deletionIndex = 0
        var additionIndex = 0
        while deletionIndex < deletion.count, additionIndex < addition.count {
            if deletion[deletionIndex].text == addition[additionIndex].text,
               deletion[deletionIndex].category == addition[additionIndex].category
            {
                matches.append(TokenMatch(
                    deletion: deletion[deletionIndex],
                    addition: addition[additionIndex]
                ))
                deletionIndex += 1
                additionIndex += 1
            } else if lengths[(deletionIndex + 1) * columnCount + additionIndex]
                >= lengths[deletionIndex * columnCount + additionIndex + 1]
            {
                deletionIndex += 1
            } else {
                additionIndex += 1
            }
        }
        return matches
    }

    // MARK: - Block refinement

    private static func appendRefinedBlock(
        deletion: String,
        deletionRange: Range<Int>,
        addition: String,
        additionRange: Range<Int>,
        deletionRanges: inout [Range<Int>],
        additionRanges: inout [Range<Int>]
    ) {
        guard !deletionRange.isEmpty || !additionRange.isEmpty else { return }

        let deletionBlock = substring(deletion, utf16Range: deletionRange)
        let additionBlock = substring(addition, utf16Range: additionRange)
        let deletionCharacters = Array(deletionBlock)
        let additionCharacters = Array(additionBlock)

        var prefixCharacters = 0
        while prefixCharacters < min(deletionCharacters.count, additionCharacters.count),
              deletionCharacters[prefixCharacters] == additionCharacters[prefixCharacters]
        {
            prefixCharacters += 1
        }

        var suffixCharacters = 0
        while suffixCharacters < deletionCharacters.count - prefixCharacters,
              suffixCharacters < additionCharacters.count - prefixCharacters,
              deletionCharacters[deletionCharacters.count - suffixCharacters - 1]
              == additionCharacters[additionCharacters.count - suffixCharacters - 1]
        {
            suffixCharacters += 1
        }

        let deletionPrefix = deletionCharacters.prefix(prefixCharacters)
            .reduce(0) { $0 + String($1).utf16.count }
        let additionPrefix = additionCharacters.prefix(prefixCharacters)
            .reduce(0) { $0 + String($1).utf16.count }
        let deletionSuffix = deletionCharacters.suffix(suffixCharacters)
            .reduce(0) { $0 + String($1).utf16.count }
        let additionSuffix = additionCharacters.suffix(suffixCharacters)
            .reduce(0) { $0 + String($1).utf16.count }

        let refinedDeletion = (deletionRange.lowerBound + deletionPrefix)
            ..< (deletionRange.upperBound - deletionSuffix)
        let refinedAddition = (additionRange.lowerBound + additionPrefix)
            ..< (additionRange.upperBound - additionSuffix)

        if !refinedDeletion.isEmpty { deletionRanges.append(refinedDeletion) }
        if !refinedAddition.isEmpty { additionRanges.append(refinedAddition) }
    }

    private static func substring(_ string: String, utf16Range: Range<Int>) -> Substring {
        let lower = String.Index(utf16Offset: utf16Range.lowerBound, in: string)
        let upper = String.Index(utf16Offset: utf16Range.upperBound, in: string)
        return string[lower ..< upper]
    }

    private static func coalescing(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let last = result.last, last.upperBound >= range.lowerBound else {
                result.append(range)
                continue
            }
            result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
        }
        return result
    }

    private static func copying(
        _ line: FileDiffProjection.Line,
        intralineRanges: [Range<Int>]
    ) -> FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: line.id,
            kind: line.kind,
            oldLine: line.oldLine,
            newLine: line.newLine,
            text: line.text,
            intralineRanges: intralineRanges
        )
    }
}
