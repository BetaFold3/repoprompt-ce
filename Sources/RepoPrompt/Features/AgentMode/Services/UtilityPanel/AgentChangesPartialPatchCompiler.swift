import Foundation

/// Parses and compiles one ordinary Git file patch for index-only partial mutation.
///
/// The parser is intentionally byte-oriented. Projection text supplies coordinates for UI identity,
/// never apply payloads; every body payload and unchanged whole hunk comes from retained Git bytes.
enum AgentChangesPartialPatchCompiler {
    static let maximumPatchBytes = 2 * 1024 * 1024

    enum CompilerError: LocalizedError, Equatable {
        case patchTooLarge(limit: Int)
        case malformedPatch(String)
        case unsupportedStructure(String)
        case pathMismatch(expected: String, actual: String)
        case invalidSelection(String)

        var errorDescription: String? {
            switch self {
            case let .patchTooLarge(limit):
                "The patch exceeds the \(limit)-byte partial-staging limit."
            case let .malformedPatch(message):
                "Malformed Git patch: \(message)"
            case let .unsupportedStructure(message):
                "This patch has structural metadata that cannot be partially staged: \(message)"
            case let .pathMismatch(expected, actual):
                "Patch path \(actual) does not match reviewed path \(expected)."
            case let .invalidSelection(message):
                "Invalid partial-staging selection: \(message)"
            }
        }
    }

    struct Compilation: Equatable {
        let data: Data
        let reverse: Bool
    }

    struct ParsedPatch: Equatable {
        let rawData: Data
        let path: String
        let diffHeader: Data
        let oldHeader: Data
        let newHeader: Data
        let hunks: [Hunk]

        var changedLineKeys: Set<AgentChangesDiffLineKey> {
            Set(hunks.flatMap(\.changedLineKeys))
        }
    }

    struct Hunk: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let headingSuffix: Data
        let lineEnding: Data
        let rawData: Data
        let records: [BodyRecord]

        var changedLineKeys: Set<AgentChangesDiffLineKey> {
            Set(records.compactMap(\.changedLineKey))
        }

        /// Whether any record carries a `\ No newline at end of file` annotation.
        ///
        /// Git reads that annotation positionally: it describes the line immediately above it and is
        /// only legal on the final line of a side. Recombining a subset of this hunk's records can
        /// therefore move the annotation into the middle of the emitted body, so callers offering
        /// per-line selection must treat such a hunk as whole-hunk-only.
        var carriesNoNewlineAnnotation: Bool {
            records.contains { !$0.annotations.isEmpty }
        }
    }

    struct BodyRecord: Equatable {
        enum Kind: Equatable {
            case context
            case addition
            case deletion
        }

        let kind: Kind
        let rawLine: Data
        let oldLine: Int?
        let newLine: Int?
        var annotations: [Data]

        var changedLineKey: AgentChangesDiffLineKey? {
            switch kind {
            case .context:
                nil
            case .addition:
                newLine.map(AgentChangesDiffLineKey.addition)
            case .deletion:
                oldLine.map(AgentChangesDiffLineKey.deletion)
            }
        }
    }

    /// Parses exactly one same-path ordinary modification.
    static func parse(
        _ data: Data,
        expectedPath: String,
        byteLimit: Int = maximumPatchBytes
    ) throws -> ParsedPatch {
        guard data.count <= byteLimit else {
            throw CompilerError.patchTooLarge(limit: byteLimit)
        }
        guard !data.isEmpty else {
            throw CompilerError.malformedPatch("empty input")
        }
        let fileSpans = GitRawDiffFileSplitter.split(data)
        guard fileSpans.count == 1, fileSpans[0] == data else {
            throw CompilerError.malformedPatch("input must contain exactly one file patch and no preamble")
        }

        let lines = splitLines(data)
        guard let first = lines.first,
              first.syntax.starts(with: Array("diff --git ".utf8))
        else {
            throw CompilerError.malformedPatch("missing diff --git header")
        }
        let headerPaths = try parseDiffHeader(first, expectedPath: expectedPath)
        guard headerPaths.old == headerPaths.new else {
            throw CompilerError.unsupportedStructure("rename or copy path")
        }
        try requirePath(headerPaths.old, expected: expectedPath)

        var oldHeader: RawLine?
        var newHeader: RawLine?
        var hunks: [Hunk] = []
        var index = 1

        while index < lines.count {
            let line = lines[index]
            if line.syntax.starts(with: Array("diff --git ".utf8)) {
                throw CompilerError.malformedPatch("multiple file patches")
            }
            if line.syntax.starts(with: Array("@@@".utf8)) {
                throw CompilerError.unsupportedStructure("combined hunk")
            }
            if line.syntax.starts(with: Array("@@ ".utf8)) {
                guard oldHeader != nil, newHeader != nil else {
                    throw CompilerError.malformedPatch("hunk precedes ---/+++ headers")
                }
                let parsed = try parseHunk(lines: lines, startIndex: index)
                hunks.append(parsed.hunk)
                index = parsed.nextIndex
                continue
            }

            let syntax = String(decoding: line.syntax, as: UTF8.self)
            if syntax.hasPrefix("--- ") {
                guard oldHeader == nil else {
                    throw CompilerError.malformedPatch("duplicate --- header")
                }
                let path = try parseFileHeaderPath(
                    String(syntax.dropFirst(4)),
                    expectedPath: expectedPath
                )
                guard path != "/dev/null" else {
                    throw CompilerError.unsupportedStructure("added file")
                }
                try requirePath(path, expected: expectedPath)
                oldHeader = line
            } else if syntax.hasPrefix("+++ ") {
                guard oldHeader != nil, newHeader == nil else {
                    throw CompilerError.malformedPatch("misordered or duplicate +++ header")
                }
                let path = try parseFileHeaderPath(
                    String(syntax.dropFirst(4)),
                    expectedPath: expectedPath
                )
                guard path != "/dev/null" else {
                    throw CompilerError.unsupportedStructure("deleted file")
                }
                try requirePath(path, expected: expectedPath)
                newHeader = line
            } else if syntax.hasPrefix("index ") {
                if syntax.contains(" 160000") {
                    throw CompilerError.unsupportedStructure("submodule mode")
                }
            } else if isStructuralMetadata(syntax) {
                throw CompilerError.unsupportedStructure(syntax)
            } else {
                throw CompilerError.malformedPatch("unknown metadata line")
            }
            index += 1
        }

        guard let oldHeader, let newHeader, !hunks.isEmpty else {
            throw CompilerError.malformedPatch("missing textual hunk")
        }
        return ParsedPatch(
            rawData: data,
            path: expectedPath,
            diffHeader: first.raw,
            oldHeader: oldHeader.raw,
            newHeader: newHeader.raw,
            hunks: hunks
        )
    }

    /// Compiles a selected set. Whole-hunk selections preserve each hunk byte-for-byte; line
    /// selections regenerate only markers and the ASCII range/count portion of hunk headers.
    static func compile(
        _ parsed: ParsedPatch,
        action: AgentChangesPartialAction,
        selectedLineKeys: Set<AgentChangesDiffLineKey>,
        selectsWholeHunks: Bool
    ) throws -> Compilation {
        guard !selectedLineKeys.isEmpty else {
            throw CompilerError.invalidSelection("selection is empty")
        }
        guard selectedLineKeys.isSubset(of: parsed.changedLineKeys) else {
            throw CompilerError.invalidSelection("selection contains an unreviewed line")
        }

        if selectsWholeHunks {
            let selectedHunks = parsed.hunks.filter {
                !$0.changedLineKeys.isDisjoint(with: selectedLineKeys)
            }
            guard !selectedHunks.isEmpty,
                  (selectedHunks.allSatisfy { $0.changedLineKeys.isSubset(of: selectedLineKeys) }),
                  Set(selectedHunks.flatMap(\.changedLineKeys)) == selectedLineKeys
            else {
                throw CompilerError.invalidSelection("a hunk action must select complete hunks")
            }

            var output = envelope(parsed, swappingFileHeaders: false)
            for hunk in selectedHunks {
                output.append(hunk.rawData)
            }
            return Compilation(data: output, reverse: action == .unstage)
        }

        var output = envelope(parsed, swappingFileHeaders: action == .unstage)
        var cumulativeDelta = 0

        for hunk in parsed.hunks {
            let selectedInHunk = hunk.changedLineKeys.intersection(selectedLineKeys)
            guard !selectedInHunk.isEmpty else { continue }

            // Defense in depth behind the descriptor's whole-hunk-only rule for annotated hunks.
            // `git apply` accepts a misplaced `\ No newline at end of file` whenever the preimage
            // still matches, then strips the newline from both images and glues the annotated line
            // to the one after it. A selection can also drop the annotated line outright and assert
            // a trailing newline the file never had. Neither shape is reconstructible from the
            // records alone, so a line action refuses the whole hunk rather than reason about where
            // the annotation would land.
            guard !hunk.carriesNoNewlineAnnotation else {
                throw CompilerError.unsupportedStructure(
                    "a no-newline annotation cannot survive a per-line selection"
                )
            }

            var emitted: [EmittedLine] = []
            for record in hunk.records {
                let marker: UInt8? = switch (
                    action,
                    record.kind,
                    record.changedLineKey.map(selectedLineKeys.contains) ?? false
                ) {
                case (_, .context, _): 0x20
                case (.stage, .deletion, true): 0x2D
                case (.stage, .deletion, false): 0x20
                case (.stage, .addition, true): 0x2B
                case (.stage, .addition, false): nil
                case (.unstage, .addition, true): 0x2D
                case (.unstage, .addition, false): 0x20
                case (.unstage, .deletion, true): 0x2B
                case (.unstage, .deletion, false): nil
                }
                guard let marker else { continue }

                let line = try replacingMarker(in: record.rawLine, with: marker)
                let counts: (Int, Int) = switch marker {
                case 0x20: (1, 1)
                case 0x2D: (1, 0)
                case 0x2B: (0, 1)
                default:
                    throw CompilerError.malformedPatch("unknown generated marker")
                }
                emitted.append(EmittedLine(
                    data: line,
                    sourceCount: counts.0,
                    targetCount: counts.1
                ))
            }

            let sourceCount = emitted.reduce(0) { $0 + $1.sourceCount }
            let targetCount = emitted.reduce(0) { $0 + $1.targetCount }
            let originalSourceStart = action == .stage ? hunk.oldStart : hunk.newStart
            let originalSourceCount = action == .stage ? hunk.oldCount : hunk.newCount
            let sourceBoundary = originalSourceCount == 0 ? originalSourceStart : originalSourceStart - 1
            let targetBoundary = sourceBoundary + cumulativeDelta
            guard sourceBoundary >= 0, targetBoundary >= 0 else {
                throw CompilerError.malformedPatch("generated range precedes beginning of file")
            }
            let sourceStart = sourceCount == 0 ? sourceBoundary : sourceBoundary + 1
            let targetStart = targetCount == 0 ? targetBoundary : targetBoundary + 1

            output.append(Data(
                "@@ -\(sourceStart),\(sourceCount) +\(targetStart),\(targetCount) @@".utf8
            ))
            output.append(hunk.headingSuffix)
            output.append(hunk.lineEnding)
            for line in emitted {
                output.append(line.data)
            }
            cumulativeDelta += targetCount - sourceCount
        }

        return Compilation(data: output, reverse: false)
    }

    // MARK: - Parsing

    /// One recompiled body line plus the range accounting it contributes.
    private struct EmittedLine {
        let data: Data
        let sourceCount: Int
        let targetCount: Int
    }

    private struct RawLine {
        let raw: Data
        let syntax: [UInt8]
        let ending: Data
    }

    private static func splitLines(_ data: Data) -> [RawLine] {
        let bytes = Array(data)
        var result: [RawLine] = []
        var start = 0

        for index in bytes.indices where bytes[index] == 0x0A {
            let hasCR = index > start && bytes[index - 1] == 0x0D
            let syntaxEnd = hasCR ? index - 1 : index
            result.append(RawLine(
                raw: Data(bytes[start ... index]),
                syntax: Array(bytes[start ..< syntaxEnd]),
                ending: Data(bytes[syntaxEnd ... index])
            ))
            start = index + 1
        }

        if start < bytes.count {
            result.append(RawLine(
                raw: Data(bytes[start ..< bytes.count]),
                syntax: Array(bytes[start ..< bytes.count]),
                ending: Data()
            ))
        }
        return result
    }

    private static func parseDiffHeader(
        _ line: RawLine,
        expectedPath: String
    ) throws -> (old: String, new: String) {
        let text = String(decoding: line.syntax, as: UTF8.self)
        let prefix = "diff --git "
        guard text.hasPrefix(prefix) else {
            throw CompilerError.malformedPatch("invalid diff --git header")
        }
        let remainder = String(text.dropFirst(prefix.count))

        // Git leaves ASCII spaces unquoted in diff --git headers. Match the already-reviewed
        // same-path identity before falling back to token parsing, avoiding an ambiguous split.
        if remainder == "a/\(expectedPath) b/\(expectedPath)" {
            return (expectedPath, expectedPath)
        }
        guard let tokens = GitPatchPathCodec.tokens(in: remainder), tokens.count == 2 else {
            throw CompilerError.malformedPatch("invalid diff --git header")
        }
        let prefixes: (String, String)? = if tokens[0].hasPrefix("a/"), tokens[1].hasPrefix("b/") {
            ("a/", "b/")
        } else {
            nil
        }
        return (
            normalizedPath(tokens[0], stripping: prefixes?.0),
            normalizedPath(tokens[1], stripping: prefixes?.1)
        )
    }

    private static func parseFileHeaderPath(
        _ remainder: String,
        expectedPath: String
    ) throws -> String {
        // Unquoted file headers may contain spaces; a tab, when present, begins the optional
        // timestamp field. Compare the entire path field against the reviewed identity first.
        let pathField = remainder.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if pathField == "a/\(expectedPath)" || pathField == "b/\(expectedPath)" {
            return expectedPath
        }
        guard let token = GitPatchPathCodec.tokens(in: String(pathField))?.first else {
            throw CompilerError.malformedPatch("invalid file header path")
        }
        if token == "/dev/null" { return token }
        return normalizedPath(
            token,
            stripping: token.hasPrefix("a/") || token.hasPrefix("b/") ? String(token.prefix(2)) : nil
        )
    }

    private static func normalizedPath(_ path: String, stripping prefix: String?) -> String {
        var result = path
        if let prefix, result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        if result.hasPrefix("./") {
            result.removeFirst(2)
        }
        return result
    }

    private static func requirePath(_ actual: String, expected: String) throws {
        guard actual == expected else {
            throw CompilerError.pathMismatch(expected: expected, actual: actual)
        }
    }

    private static func isStructuralMetadata(_ line: String) -> Bool {
        [
            "old mode ", "new mode ", "new file mode ", "deleted file mode ",
            "similarity index ", "dissimilarity index ", "rename from ", "rename to ",
            "copy from ", "copy to ", "Binary files ", "GIT binary patch"
        ].contains { line.hasPrefix($0) }
    }

    private static func parseHunk(
        lines: [RawLine],
        startIndex: Int
    ) throws -> (hunk: Hunk, nextIndex: Int) {
        let header = lines[startIndex]
        let headerText = String(decoding: header.syntax, as: UTF8.self)
        let expression = try NSRegularExpression(
            pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(.*)$"#
        )
        let fullRange = NSRange(headerText.startIndex ..< headerText.endIndex, in: headerText)
        guard let match = expression.firstMatch(in: headerText, range: fullRange),
              match.range == fullRange,
              let oldStart = integerCapture(1, match: match, in: headerText),
              let newStart = integerCapture(3, match: match, in: headerText)
        else {
            throw CompilerError.malformedPatch("invalid hunk header")
        }
        let oldCount = integerCapture(2, match: match, in: headerText) ?? 1
        let newCount = integerCapture(4, match: match, in: headerText) ?? 1
        let headingSuffix = try hunkHeadingSuffix(header.syntax)

        var records: [BodyRecord] = []
        var oldCursor = oldStart
        var newCursor = newStart
        var consumedOld = 0
        var consumedNew = 0
        var index = startIndex + 1

        while index < lines.count {
            let line = lines[index]
            if line.syntax.starts(with: Array("@@ ".utf8)) || line.syntax.starts(with: Array("@@@".utf8)) {
                break
            }
            if line.syntax.starts(with: Array("diff --git ".utf8)) {
                throw CompilerError.malformedPatch("multiple file patches")
            }
            guard let marker = line.syntax.first else {
                throw CompilerError.malformedPatch("empty hunk body line")
            }

            if marker == 0x5C {
                guard line.syntax == Array("\\ No newline at end of file".utf8),
                      !records.isEmpty,
                      records[records.count - 1].annotations.isEmpty
                else {
                    throw CompilerError.malformedPatch("orphan or duplicate no-newline marker")
                }
                records[records.count - 1].annotations.append(line.raw)
                index += 1
                continue
            }

            let payload = line.syntax.dropFirst()
            if payload.starts(with: Array("Subproject commit ".utf8)) {
                throw CompilerError.unsupportedStructure("submodule content")
            }

            let record: BodyRecord
            switch marker {
            case 0x20:
                record = BodyRecord(
                    kind: .context,
                    rawLine: line.raw,
                    oldLine: oldCursor,
                    newLine: newCursor,
                    annotations: []
                )
                oldCursor += 1
                newCursor += 1
                consumedOld += 1
                consumedNew += 1
            case 0x2D:
                record = BodyRecord(
                    kind: .deletion,
                    rawLine: line.raw,
                    oldLine: oldCursor,
                    newLine: nil,
                    annotations: []
                )
                oldCursor += 1
                consumedOld += 1
            case 0x2B:
                record = BodyRecord(
                    kind: .addition,
                    rawLine: line.raw,
                    oldLine: nil,
                    newLine: newCursor,
                    annotations: []
                )
                newCursor += 1
                consumedNew += 1
            default:
                throw CompilerError.malformedPatch("unknown hunk body marker")
            }
            records.append(record)
            index += 1
        }

        guard consumedOld == oldCount, consumedNew == newCount else {
            throw CompilerError.malformedPatch(
                "hunk counts consume old \(consumedOld)/\(oldCount), new \(consumedNew)/\(newCount)"
            )
        }
        guard records.contains(where: { $0.kind != .context }) else {
            throw CompilerError.malformedPatch("hunk contains no changed lines")
        }

        var rawData = Data()
        for line in lines[startIndex ..< index] {
            rawData.append(line.raw)
        }
        return (
            Hunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                headingSuffix: headingSuffix,
                lineEnding: header.ending,
                rawData: rawData,
                records: records
            ),
            index
        )
    }

    private static func integerCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        in text: String
    ) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text)
        else { return nil }
        return Int(text[swiftRange])
    }

    private static func hunkHeadingSuffix(_ bytes: [UInt8]) throws -> Data {
        guard bytes.count >= 4 else {
            throw CompilerError.malformedPatch("short hunk header")
        }
        var index = 2
        while index + 1 < bytes.count {
            if bytes[index] == 0x40, bytes[index + 1] == 0x40 {
                return Data(bytes[(index + 2)...])
            }
            index += 1
        }
        throw CompilerError.malformedPatch("hunk header lacks closing @@")
    }

    // MARK: - Emission

    private static func envelope(_ parsed: ParsedPatch, swappingFileHeaders: Bool) -> Data {
        var result = parsed.diffHeader
        if swappingFileHeaders {
            result.append(replacingHeaderMarker(parsed.newHeader, with: "---"))
            result.append(replacingHeaderMarker(parsed.oldHeader, with: "+++"))
        } else {
            result.append(parsed.oldHeader)
            result.append(parsed.newHeader)
        }
        return result
    }

    private static func replacingHeaderMarker(_ data: Data, with marker: String) -> Data {
        guard data.count >= 3 else { return data }
        var result = data
        result.replaceSubrange(result.startIndex ..< result.startIndex + 3, with: marker.utf8)
        return result
    }

    private static func replacingMarker(in data: Data, with marker: UInt8) throws -> Data {
        guard !data.isEmpty else {
            throw CompilerError.malformedPatch("empty body record")
        }
        var result = data
        result[result.startIndex] = marker
        return result
    }
}
