import Foundation

/// Utilities for parsing unified diff patches and managing truncation.
enum GitDiffPatchParsing {
    // MARK: - Types

    /// A parsed hunk from a unified diff.
    struct ParsedHunk: Equatable {
        let header: String
        let oldStart: Int
        let oldLines: Int
        let newStart: Int
        let newLines: Int
        let content: String
    }

    /// A file with its parsed hunks for inline diff responses.
    struct ParsedFileHunks {
        let path: String
        let status: String
        let insertions: Int
        let deletions: Int
        let hunks: [ParsedHunk]

        /// Total line count (header + content lines per hunk)
        var lineCount: Int {
            hunks.reduce(0) { $0 + 1 + $1.content.components(separatedBy: "\n").count }
        }
    }

    /// Result of truncation operation.
    struct TruncationResult {
        let files: [ParsedFileHunks]
        let truncated: Bool
        let note: String?
    }

    // MARK: - Hunk Parsing

    /// Regular expression for hunk headers: @@ -start,count +start,count @@
    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"^@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@"#,
        options: []
    )

    /// Parses hunks from a patch text (single file diff).
    static func parseHunks(from patchText: String) -> [ParsedHunk] {
        let lines = patchText.components(separatedBy: "\n")
        var hunks: [ParsedHunk] = []
        var currentHunkHeader: String?
        var currentHunkContent: [String] = []
        var currentHunkMeta: (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)?

        for line in lines {
            if line.hasPrefix("@@") {
                // Finalize previous hunk if any
                if let header = currentHunkHeader, let meta = currentHunkMeta {
                    hunks.append(ParsedHunk(
                        header: header,
                        oldStart: meta.oldStart,
                        oldLines: meta.oldLines,
                        newStart: meta.newStart,
                        newLines: meta.newLines,
                        content: currentHunkContent.joined(separator: "\n")
                    ))
                }

                // Parse new hunk header
                currentHunkHeader = line
                currentHunkContent = []
                currentHunkMeta = parseHunkHeader(line)
            } else if currentHunkHeader != nil {
                // Inside a hunk, collect content lines
                currentHunkContent.append(line)
            }
            // Lines before first hunk (diff headers) are ignored
        }

        // Finalize last hunk
        if let header = currentHunkHeader, let meta = currentHunkMeta {
            hunks.append(ParsedHunk(
                header: header,
                oldStart: meta.oldStart,
                oldLines: meta.oldLines,
                newStart: meta.newStart,
                newLines: meta.newLines,
                content: currentHunkContent.joined(separator: "\n")
            ))
        }

        return hunks
    }

    /// Parses the numeric values from a hunk header line.
    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = hunkHeaderRegex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        func intAt(_ index: Int) -> Int {
            guard let swiftRange = Range(match.range(at: index), in: line) else {
                return index == 2 || index == 4 ? 1 : 0 // Default count is 1 if not specified
            }
            return Int(line[swiftRange]) ?? (index == 2 || index == 4 ? 1 : 0)
        }

        let oldStart = intAt(1)
        let oldLines = match.range(at: 2).location != NSNotFound ? intAt(2) : 1
        let newStart = intAt(3)
        let newLines = match.range(at: 4).location != NSNotFound ? intAt(4) : 1

        return (oldStart, oldLines, newStart, newLines)
    }

    /// The enclosing-context text Git appends after a hunk header's closing `@@`, or `nil` when the
    /// header carries none.
    static func hunkHeading(from header: String) -> String? {
        guard let opening = header.range(of: "@@"),
              let closing = header.range(of: "@@", range: opening.upperBound ..< header.endIndex)
        else {
            return nil
        }
        let heading = header[closing.upperBound...].trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    // MARK: - Patch Walking

    /// How a line that reads as either a file header or hunk-body content is classified.
    ///
    /// Both cases share one counter walk and differ only in this test, so the two consumers can
    /// never drift apart on line numbering.
    enum PatchHeaderDisambiguation {
        /// `+++`, `---`, `diff --git`, and `index ` mean "file header" wherever they appear.
        /// Frozen behavior for ``extractChangedLines(from:)``, which ships in MCP tool replies: it
        /// misreads body lines such as a deleted `-- sql comment`, which arrives as `--- sql comment`.
        case prefixWins
        /// Header prefixes only count outside a hunk body. Inside one the leading marker character
        /// is authoritative, so deleted `--` or added `++` content keeps its place and its numbers.
        case bodyWins
    }

    /// A hunk-body line with the counters already resolved for whichever side it exists on.
    struct PatchLine: Equatable {
        let kind: FileDiffProjection.LineKind
        let oldNumber: Int?
        let newNumber: Int?
        /// The walked line minus its marker character. Left as a slice so callers that discard the
        /// line — the wire format discards every context line — pay nothing to materialize it.
        let text: Substring
    }

    /// Everything ``walkPatch(_:headerDisambiguation:onEvent:)`` reports, in patch order.
    enum PatchWalkEvent: Equatable {
        /// A hunk header that parsed; the walker's counters have just been reset from it.
        case hunkStart(header: String, oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)
        case line(PatchLine)
        /// Any other line: `diff --git`, `index`, mode/rename/copy metadata, binary notices, and
        /// hunk headers that did not parse.
        case metadata(String)
    }

    /// Walks a unified patch once, emitting every hunk header and body line with its old/new numbers.
    ///
    /// Shared by ``extractChangedLines(from:)``, which filters it into the MCP wire format, and
    /// ``DiffLineProjector``, which builds render models from it. One walk behind both means a
    /// numbering fix — or a numbering regression — lands on the two surfaces together.
    ///
    /// `GitDiffSnapshotStore.parseDeepArtifacts` still keeps a private copy of this walk for the
    /// deep `hunks.jsonl`/`changed-lines.tsv` artifacts; folding it in needs its own golden coverage
    /// for that artifact shape first.
    static func walkPatch(
        _ patchText: String,
        headerDisambiguation: PatchHeaderDisambiguation = .prefixWins,
        onEvent: (PatchWalkEvent) -> Void
    ) {
        var oldLine = 0
        var newLine = 0
        var insideHunk = false

        for line in patchText.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                guard let meta = parseHunkHeader(line) else {
                    // An unparsable header leaves the counters where they were, which is what the
                    // frozen wire format does with combined `@@@` headers.
                    onEvent(.metadata(line))
                    continue
                }
                oldLine = meta.oldStart
                newLine = meta.newStart
                insideHunk = true
                onEvent(.hunkStart(
                    header: line,
                    oldStart: meta.oldStart,
                    oldLines: meta.oldLines,
                    newStart: meta.newStart,
                    newLines: meta.newLines
                ))
                continue
            }

            let marker = line.first
            if !isBodyMarker(marker) {
                insideHunk = false
            }
            if isFileHeaderLine(line), headerDisambiguation == .prefixWins || !insideHunk {
                onEvent(.metadata(line))
                continue
            }

            switch marker {
            case "+":
                onEvent(.line(PatchLine(
                    kind: .addition,
                    oldNumber: nil,
                    newNumber: newLine,
                    text: line.dropFirst()
                )))
                newLine += 1
            case "-":
                onEvent(.line(PatchLine(
                    kind: .deletion,
                    oldNumber: oldLine,
                    newNumber: nil,
                    text: line.dropFirst()
                )))
                oldLine += 1
            case " ":
                onEvent(.line(PatchLine(
                    kind: .context,
                    oldNumber: oldLine,
                    newNumber: newLine,
                    text: line.dropFirst()
                )))
                oldLine += 1
                newLine += 1
            case "\\":
                onEvent(.line(PatchLine(
                    kind: .noNewlineMarker,
                    oldNumber: nil,
                    newNumber: nil,
                    text: line.dropFirst()
                )))
            default:
                onEvent(.metadata(line))
            }
        }
    }

    /// Marker characters that can only introduce a hunk-body line.
    private static func isBodyMarker(_ marker: Character?) -> Bool {
        marker == " " || marker == "+" || marker == "-" || marker == "\\"
    }

    /// Lines Git writes above a hunk body, matched by prefix exactly as the frozen wire format does.
    private static func isFileHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("+++")
            || line.hasPrefix("---")
            || line.hasPrefix("diff --git")
            || line.hasPrefix("index ")
    }

    // MARK: - Truncation

    /// Truncates patches to fit within a line budget.
    ///
    /// Strategy:
    /// 1. Sort files by churn (insertions + deletions) descending
    /// 2. Include full patches until budget is exhausted
    /// 3. For remaining files, include only headers with truncation markers
    ///
    /// - Parameters:
    ///   - files: Files with their parsed hunks
    ///   - maxLines: Maximum total lines to include
    /// - Returns: Truncated files, whether truncation occurred, and a note about omitted content
    static func truncatePatches(
        files: [ParsedFileHunks],
        maxLines: Int
    ) -> TruncationResult {
        guard maxLines > 0 else {
            return TruncationResult(files: [], truncated: true, note: "No lines available")
        }

        // Sort by churn (highest first) to prioritize important changes
        let sorted = files.sorted { ($0.insertions + $0.deletions) > ($1.insertions + $1.deletions) }

        var result: [ParsedFileHunks] = []
        var usedLines = 0
        var omittedFiles: [(path: String, lines: Int)] = []

        for file in sorted {
            let fileLines = file.lineCount
            if usedLines + fileLines <= maxLines {
                // Include full file
                result.append(file)
                usedLines += fileLines
            } else {
                // File doesn't fit, try to include truncated version
                let remainingBudget = maxLines - usedLines
                if remainingBudget > 0 {
                    // Try to include some hunks
                    let truncated = truncateFileHunks(file, maxLines: remainingBudget)
                    if truncated.lineCount > 0 {
                        result.append(truncated)
                        usedLines += truncated.lineCount
                    }
                }
                omittedFiles.append((file.path, fileLines))
            }
        }

        let truncated = !omittedFiles.isEmpty
        var note: String?
        if truncated {
            let omittedList = omittedFiles
                .prefix(5)
                .map { "\($0.path) (\($0.lines) lines)" }
                .joined(separator: ", ")
            let moreCount = max(0, omittedFiles.count - 5)
            let moreText = moreCount > 0 ? " and \(moreCount) more" : ""
            note = "Showing \(usedLines) of \(files.reduce(0) { $0 + $1.lineCount }) lines. Omitted: \(omittedList)\(moreText)"
        }

        return TruncationResult(files: result, truncated: truncated, note: note)
    }

    /// Truncates a single file's hunks to fit within a line budget.
    private static func truncateFileHunks(_ file: ParsedFileHunks, maxLines: Int) -> ParsedFileHunks {
        var truncatedHunks: [ParsedHunk] = []
        var usedLines = 0

        for hunk in file.hunks {
            let hunkLines = 1 + hunk.content.components(separatedBy: "\n").count
            if usedLines + hunkLines <= maxLines {
                truncatedHunks.append(hunk)
                usedLines += hunkLines
            } else {
                // Partial hunk inclusion
                let remainingBudget = maxLines - usedLines - 1 // -1 for header
                if remainingBudget > 0 {
                    let contentLines = hunk.content.components(separatedBy: "\n")
                    let includedContent = contentLines.prefix(remainingBudget).joined(separator: "\n")
                    let omittedCount = contentLines.count - remainingBudget
                    let truncatedContent = includedContent + "\n[+\(omittedCount) more lines]"
                    truncatedHunks.append(ParsedHunk(
                        header: hunk.header,
                        oldStart: hunk.oldStart,
                        oldLines: hunk.oldLines,
                        newStart: hunk.newStart,
                        newLines: hunk.newLines,
                        content: truncatedContent
                    ))
                }
                break
            }
        }

        return ParsedFileHunks(
            path: file.path,
            status: file.status,
            insertions: file.insertions,
            deletions: file.deletions,
            hunks: truncatedHunks
        )
    }

    // MARK: - Statistics

    /// Counts insertions and deletions from a patch text.
    static func countChanges(in patchText: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0

        for line in patchText.components(separatedBy: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                insertions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }

        return (insertions, deletions)
    }

    /// Converts ParsedFileHunks to the DTO format.
    static func toDiffFileDTO(
        _ file: ParsedFileHunks,
        includeHunks: Bool
    ) -> ToolResultDTOs.GitToolReplyDTO.DiffFileDTO {
        let hunks: [ToolResultDTOs.GitToolReplyDTO.DiffHunkDTO]? = includeHunks ? file.hunks.map { hunk in
            ToolResultDTOs.GitToolReplyDTO.DiffHunkDTO(
                header: hunk.header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                patch: hunk.content
            )
        } : nil

        return ToolResultDTOs.GitToolReplyDTO.DiffFileDTO(
            path: file.path,
            status: file.status,
            insertions: file.insertions,
            deletions: file.deletions,
            hunks: hunks
        )
    }

    // MARK: - Changed Lines Extraction

    /// A single changed line from a diff.
    struct ChangedLine: Equatable {
        let path: String
        let lineNumber: Int
        let changeType: Character // "+" or "-"
        let content: String
    }

    /// Extracts all changed lines from a per-file patch dictionary.
    /// - Parameter perFilePatches: Dictionary mapping git paths to their patch text
    /// - Returns: Array of changed lines with path, line number, change type, and content
    static func extractChangedLines(from perFilePatches: [String: String]) -> [ChangedLine] {
        var result: [ChangedLine] = []

        for (gitPath, patchText) in perFilePatches.sorted(by: { $0.key < $1.key }) {
            result.append(contentsOf: extractChangedLines(from: patchText, path: gitPath))
        }

        return result
    }

    /// Extracts changed lines from a single file's patch text.
    ///
    /// A filter over ``walkPatch(_:headerDisambiguation:onEvent:)`` in its `prefixWins` mode: the
    /// additions and deletions, numbered from the side each one exists on. Context lines and
    /// no-newline markers carry no wire record.
    private static func extractChangedLines(from patchText: String, path: String) -> [ChangedLine] {
        var result: [ChangedLine] = []

        walkPatch(patchText) { event in
            guard case let .line(line) = event else { return }

            let lineNumber: Int?
            let changeType: Character
            switch line.kind {
            case .addition:
                lineNumber = line.newNumber
                changeType = "+"
            case .deletion:
                lineNumber = line.oldNumber
                changeType = "-"
            case .context, .noNewlineMarker:
                return
            }
            guard let lineNumber else { return }

            result.append(ChangedLine(
                path: path,
                lineNumber: lineNumber,
                changeType: changeType,
                content: String(line.text)
            ))
        }

        return result
    }

    /// Builds a TSV string for changed lines.
    /// Format: path\tline_number\tchange_type\tcontent
    static func buildChangedLinesTsv(from perFilePatches: [String: String]) -> String {
        let changedLines = extractChangedLines(from: perFilePatches)

        var lines: [String] = []
        lines.append("path\tline_number\tchange_type\tcontent")

        for cl in changedLines {
            let row = [cl.path, String(cl.lineNumber), String(cl.changeType), cl.content].joined(separator: "\t")
            lines.append(row)
        }

        return lines.joined(separator: "\n")
    }
}
