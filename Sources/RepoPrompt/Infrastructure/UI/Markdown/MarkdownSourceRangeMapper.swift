//
//  MarkdownSourceRangeMapper.swift
//  RepoPrompt
//
//  Translates swift-markdown source positions into NSRanges over the verbatim
//  Markdown source, so a decorator-style compiler can style the original text
//  instead of re-emitting it.
//

import Foundation
import Markdown

/// Maps swift-markdown ``SourceRange`` values onto `NSRange` values over the
/// *verbatim* Markdown source string that produced them.
///
/// # Why this exists
///
/// ``SemiRenderedMarkdownCompiler`` decorates the original source rather than
/// re-emitting rendered text, so every style it applies has to be expressed as
/// an `NSRange` over that exact string. swift-markdown reports positions as
/// line/column pairs, which means a translation layer is unavoidable — and it
/// has to be exactly right, because a range that is off by a single UTF-16 unit
/// paints the wrong characters. Everything here is therefore either derived
/// from a documented guarantee or verified empirically (see below), and any
/// position that cannot be translated with confidence returns `nil` so the
/// caller can degrade to unstyled text instead of styling the wrong span.
///
/// # Verified swift-markdown / cmark-gfm column semantics
///
/// The right-utility-panel plan flagged these as a must-verify risk, so they
/// are pinned by `MarkdownSourceRangeMapperTests` (swift-markdown 0.6.0)
/// rather than assumed:
///
/// - `SourceLocation.line` is **1-based**.
/// - `SourceLocation.column` is a **1-based UTF-8 byte offset within its
///   line** — not a character, grapheme-cluster, or UTF-16 offset. A 4-byte
///   emoji advances `column` by 4, a 3-byte CJK ideograph by 3, and every
///   scalar of a combining sequence is counted separately (`e` + U+0301
///   advances `column` by 3). A tab is one byte and advances `column` by one.
/// - `SourceRange.lowerBound` is **inclusive** and `SourceRange.upperBound` is
///   **exclusive**: swift-markdown adds one to cmark's inclusive end column.
/// - Line terminators are **not addressable**. cmark measures a line after
///   stripping `\r\n`, `\n`, or a lone `\r`, so the largest meaningful column
///   on a line is `utf8ByteCount(content) + 1`, used only as an exclusive end.
///   CRLF sources therefore report the same columns as LF sources.
/// - cmark treats `\r\n`, a bare `\n`, and a bare `\r` as line breaks, so the
///   line table below splits on all three to keep line numbering aligned.
///
/// # Known blind spot
///
/// cmark expands a *partially consumed* tab (a tab straddling a block-level
/// indent boundary, such as `-\titem`) into spaces inside its internal block
/// buffer. Inline positions inside that block are derived from the expanded
/// buffer, so their columns can be larger than the corresponding source line.
/// Such columns fail this mapper's bounds check and yield `nil`, and the
/// compiler additionally re-verifies every delimiter lexically before styling —
/// so the failure mode is a missed decoration, never a misplaced one.
struct MarkdownSourceRangeMapper {
    /// One source line, addressed the way cmark addresses it: content only,
    /// with the line terminator excluded.
    private struct Line {
        /// Range of the line's content (terminator excluded) in `source`.
        let contentRange: Range<String.Index>
        /// UTF-16 offset of the line's first unit within the whole source.
        let utf16Start: Int
        /// UTF-8 byte count of the line's content, excluding the terminator.
        let contentUTF8Count: Int
        /// True when the content is entirely ASCII, in which case a UTF-8 byte
        /// offset within the line is also its UTF-16 offset.
        let isASCIIContent: Bool
    }

    private let source: String
    private let lines: [Line]

    /// Length of the source in UTF-16 units — the units `NSRange` counts.
    let utf16Length: Int

    init(source: String) {
        self.source = source
        var lines: [Line] = []
        let scalars = source.unicodeScalars

        var lineContentStart = scalars.startIndex
        var lineUTF16Start = 0
        var contentUTF8Count = 0
        var contentIsASCII = true
        var cursorUTF16 = 0
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" || scalar == "\r" {
                lines.append(
                    Line(
                        contentRange: lineContentStart ..< index,
                        utf16Start: lineUTF16Start,
                        contentUTF8Count: contentUTF8Count,
                        isASCIIContent: contentIsASCII
                    )
                )
                var afterTerminator = scalars.index(after: index)
                var terminatorUTF16 = 1
                if scalar == "\r",
                   afterTerminator < scalars.endIndex,
                   scalars[afterTerminator] == "\n"
                {
                    terminatorUTF16 += 1
                    afterTerminator = scalars.index(after: afterTerminator)
                }
                cursorUTF16 += terminatorUTF16
                lineUTF16Start = cursorUTF16
                lineContentStart = afterTerminator
                contentUTF8Count = 0
                contentIsASCII = true
                index = afterTerminator
                continue
            }

            contentUTF8Count += Self.utf8Count(of: scalar)
            cursorUTF16 += Self.utf16Count(of: scalar)
            if !scalar.isASCII {
                contentIsASCII = false
            }
            index = scalars.index(after: index)
        }

        // The trailing line always exists, even when the source is empty or
        // ends with a terminator (in which case it is the empty final line).
        lines.append(
            Line(
                contentRange: lineContentStart ..< scalars.endIndex,
                utf16Start: lineUTF16Start,
                contentUTF8Count: contentUTF8Count,
                isASCIIContent: contentIsASCII
            )
        )

        self.lines = lines
        utf16Length = cursorUTF16
    }

    /// Number of addressable source lines, counting a trailing empty line when
    /// the source ends with a terminator.
    var lineCount: Int {
        lines.count
    }

    /// Translates one swift-markdown position into a UTF-16 offset.
    ///
    /// - Returns: `nil` when the line does not exist or the column falls
    ///   outside the line's addressable range, so callers degrade to no
    ///   styling rather than styling an arbitrary span.
    func utf16Offset(line: Int, utf8Column: Int) -> Int? {
        guard line >= 1, line <= lines.count, utf8Column >= 1 else { return nil }
        let record = lines[line - 1]
        // `contentUTF8Count + 1` is the exclusive end of the line's content.
        guard utf8Column <= record.contentUTF8Count + 1 else { return nil }

        let byteOffset = utf8Column - 1
        if record.isASCIIContent {
            return record.utf16Start + byteOffset
        }

        var consumedUTF8 = 0
        var consumedUTF16 = 0
        var index = record.contentRange.lowerBound
        let scalars = source.unicodeScalars
        // A column is only ever expected to land on a scalar boundary. If a
        // malformed one lands mid-scalar we round up to the next boundary so
        // the resulting range stays valid.
        while index < record.contentRange.upperBound, consumedUTF8 < byteOffset {
            let scalar = scalars[index]
            consumedUTF8 += Self.utf8Count(of: scalar)
            consumedUTF16 += Self.utf16Count(of: scalar)
            index = scalars.index(after: index)
        }
        return record.utf16Start + consumedUTF16
    }

    /// Translates a swift-markdown range into an `NSRange` over the source.
    ///
    /// - Returns: `nil` when either endpoint is unmappable or the endpoints are
    ///   inverted, so the caller applies no attribute at all.
    func nsRange(for sourceRange: SourceRange) -> NSRange? {
        guard
            let start = utf16Offset(
                line: sourceRange.lowerBound.line,
                utf8Column: sourceRange.lowerBound.column
            ),
            let end = utf16Offset(
                line: sourceRange.upperBound.line,
                utf8Column: sourceRange.upperBound.column
            ),
            end >= start,
            end <= utf16Length
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The `NSRange` of one line's content, with its terminator excluded.
    func lineContentRange(line: Int) -> NSRange? {
        guard line >= 1, line <= lines.count else { return nil }
        let record = lines[line - 1]
        guard
            let end = utf16Offset(line: line, utf8Column: record.contentUTF8Count + 1)
        else { return nil }
        return NSRange(location: record.utf16Start, length: end - record.utf16Start)
    }

    // MARK: - Scalar width helpers

    private static func utf8Count(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0 ..< 0x80: 1
        case 0x80 ..< 0x800: 2
        case 0x800 ..< 0x10000: 3
        default: 4
        }
    }

    private static func utf16Count(of scalar: Unicode.Scalar) -> Int {
        scalar.value <= 0xFFFF ? 1 : 2
    }
}
