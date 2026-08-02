import Foundation

/// Projects one file's unified patch into the value models the Changes panel renders.
///
/// Pure statics over ``GitDiffPatchParsing/walkPatch(_:headerDisambiguation:onEvent:)``, the walker
/// the MCP wire format also runs on, so panel line numbers cannot disagree with the numbers MCP
/// replies ship. The walk runs in `bodyWins` mode: inside a hunk the leading marker character
/// decides, which keeps a deleted `-- sql comment` from being discarded as a `---` file header the
/// way the frozen wire format still does.
enum DiffLineProjector {
    /// Projects one file's patch into a renderable document.
    ///
    /// - Parameters:
    ///   - patch: the file's unified patch, in the shape `GitDiffEngine.buildSnapshotInputs` stores
    ///     under `perFile`.
    ///   - fileKey: that map's key. It anchors every ID this projection mints, so re-projecting an
    ///     unchanged patch yields identical identities.
    ///   - contextLevel: the width the patch was generated at; patch text does not record it.
    ///   - isUntracked: porcelain's untracked bit. Untracked files are diffed with `--no-index`
    ///     against an empty tree, so their patches are byte-identical to a tracked addition and
    ///     status is the only thing that can tell the two apart.
    ///   - maxLines: optional cap on projected body lines. The walk continues past the cap so
    ///     ``FileDiffProjection/Truncation`` can report a true total rather than the cap back.
    ///   - computesIntralineDiffs: opt-in word-level emphasis for the Changes UI. The default is
    ///     deliberately false so existing callers, including frozen MCP projection paths, keep
    ///     their output and cost unchanged.
    static func project(
        patch: String,
        fileKey: String,
        contextLevel: FileDiffProjection.ContextLevel,
        isUntracked: Bool = false,
        maxLines: Int? = nil,
        computesIntralineDiffs: Bool = false,
        oldSourceReference: String? = nil
    ) -> FileDiffProjection.Document {
        var facts = HeaderFacts()
        var hunks: [FileDiffProjection.Hunk] = []
        var pending: PendingHunk?
        var additions = 0
        var deletions = 0
        var totalLines = 0
        var projectedLines = 0

        /// A hunk that projected no lines is dropped rather than rendered as an empty box; the
        /// surviving hunks stay numbered 0, 1, 2… so IDs do not shift when a cap drops the tail.
        func closePendingHunk() {
            defer { pending = nil }
            guard let hunk = pending, !hunk.lines.isEmpty else { return }
            let lines = computesIntralineDiffs
                ? IntralineDiffComputer.annotating(hunk.lines)
                : hunk.lines
            hunks.append(FileDiffProjection.Hunk(
                id: hunk.id,
                oldStart: hunk.oldStart,
                oldCount: hunk.oldCount,
                newStart: hunk.newStart,
                newCount: hunk.newCount,
                heading: hunk.heading,
                lines: lines
            ))
        }

        GitDiffPatchParsing.walkPatch(patch, headerDisambiguation: .bodyWins) { event in
            switch event {
            case let .hunkStart(header, oldStart, oldLines, newStart, newLines):
                closePendingHunk()
                pending = PendingHunk(
                    id: "\(fileKey)#\(hunks.count)",
                    oldStart: oldStart,
                    oldCount: oldLines,
                    newStart: newStart,
                    newCount: newLines,
                    heading: GitDiffPatchParsing.hunkHeading(from: header)
                )

            case let .line(line):
                // Body lines outside a hunk are malformed input; counting them would report a
                // truncation that never happened.
                guard let hunkID = pending?.id, let lineIndex = pending?.lines.count else { return }

                switch line.kind {
                case .addition:
                    additions += 1
                case .deletion:
                    deletions += 1
                case .context, .noNewlineMarker:
                    break
                }
                if line.text.hasPrefix("Subproject commit ") {
                    facts.hasSubprojectRecord = true
                }

                totalLines += 1
                if let maxLines, projectedLines >= maxLines { return }
                projectedLines += 1
                pending?.lines.append(FileDiffProjection.Line(
                    id: "\(hunkID)#\(lineIndex)",
                    kind: line.kind,
                    oldLine: line.oldNumber,
                    newLine: line.newNumber,
                    text: String(line.text)
                ))

            case let .metadata(text):
                facts.absorb(text)
            }
        }
        closePendingHunk()

        return FileDiffProjection.Document(
            id: fileKey,
            path: fileKey,
            oldPath: facts.renameSource ?? facts.copySource,
            change: facts.resolveChange(hasHunks: !hunks.isEmpty, isUntracked: isUntracked),
            additions: additions,
            deletions: deletions,
            hunks: hunks,
            contextLevel: contextLevel,
            oldSourceReference: oldSourceReference,
            truncation: projectedLines < totalLines
                ? FileDiffProjection.Truncation(projectedLines: projectedLines, totalLines: totalLines)
                : nil
        )
    }

    // MARK: - Accumulators

    private struct PendingHunk {
        let id: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let heading: String?
        var lines: [FileDiffProjection.Line] = []
    }

    /// What the metadata lines around a patch body say about the file itself.
    private struct HeaderFacts {
        var isCombined = false
        var isBinary = false
        var addsFile = false
        var removesFile = false
        var changesMode = false
        var renameSource: String?
        var copySource: String?
        var hasSubprojectRecord = false

        mutating func absorb(_ line: String) {
            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                isCombined = true
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            } else if line.hasPrefix("new file mode ") || line.hasPrefix("--- /dev/null") {
                addsFile = true
            } else if line.hasPrefix("deleted file mode ") || line.hasPrefix("+++ /dev/null") {
                removesFile = true
            } else if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                changesMode = true
            } else if let source = Self.remainder(of: line, after: "rename from ") {
                renameSource = DiffLineProjector.gitPath(source)
            } else if let source = Self.remainder(of: line, after: "copy from ") {
                copySource = DiffLineProjector.gitPath(source)
            }
        }

        /// Ordered by how much each answer constrains rendering rather than by lifecycle: a combined
        /// or binary patch has no body a reviewer can read, and a submodule pointer is not text at
        /// all, so those outrank "added" or "renamed". Rename and copy origins are not lost to the
        /// ordering — they stay on ``FileDiffProjection/Document/oldPath`` whichever case wins.
        func resolveChange(hasHunks: Bool, isUntracked: Bool) -> FileDiffProjection.FileChange {
            if isCombined { return .conflicted }
            if isBinary { return .binary }
            if hasSubprojectRecord { return .submodule }
            if let renameSource { return .renamed(from: renameSource) }
            if let copySource { return .copied(from: copySource) }
            if addsFile { return isUntracked ? .untracked : .added }
            if removesFile { return .deleted }
            if changesMode, !hasHunks { return .modeOnly }
            return .modified
        }

        private static func remainder(of line: String, after prefix: String) -> String? {
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
        }
    }

    // MARK: - Paths

    /// Decodes a path as Git writes it in `rename from`/`copy from` metadata.
    ///
    /// Git C-quotes a path only when it holds controls, a quote, a backslash, or non-ASCII bytes;
    /// anything else is written verbatim. Octal escapes are UTF-8 *bytes*, so they are accumulated
    /// and decoded as one sequence — turning each escape into its own scalar would render
    /// `caf\303\251` as mojibake instead of `café`.
    private static func gitPath(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }

        var bytes: [UInt8] = []
        var index = raw.index(after: raw.startIndex)
        let end = raw.index(before: raw.endIndex)

        while index < end {
            let character = raw[index]
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                index = raw.index(after: index)
                continue
            }

            index = raw.index(after: index)
            guard index < end else { break }
            let escaped = raw[index]

            if let leadingDigit = octalDigit(escaped) {
                var byte = leadingDigit
                var digits = 1
                index = raw.index(after: index)
                while digits < 3, index < end, let digit = octalDigit(raw[index]) {
                    byte = byte * 8 + digit
                    digits += 1
                    index = raw.index(after: index)
                }
                bytes.append(UInt8(truncatingIfNeeded: byte))
                continue
            }

            switch escaped {
            case "n":
                bytes.append(0x0A)
            case "t":
                bytes.append(0x09)
            case "r":
                bytes.append(0x0D)
            default:
                bytes.append(contentsOf: String(escaped).utf8)
            }
            index = raw.index(after: index)
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octalDigit(_ character: Character) -> Int? {
        guard character.isASCII, let value = character.wholeNumberValue, (0 ... 7).contains(value) else {
            return nil
        }
        return value
    }
}
