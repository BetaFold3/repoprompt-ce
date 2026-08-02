import Foundation

// SEARCH-HELPER: AgentEditToolResultDecoder, AgentEditToolFacts, AgentEditedFileFact, edit payload normalization

// MARK: - Edit Tool Families

/// The tool families whose results describe file edits.
///
/// Raw values are the canonical tool-card names produced by `normalizedToolCardName`, so provider
/// aliases (`filechange`, `functions.apply_patch`, `Edit File`) resolve through the one existing
/// normalization table instead of a second table that could drift away from it.
enum AgentEditToolKind: String, Hashable, CaseIterable {
    /// RepoPrompt's own `apply_edits` MCP tool.
    case applyEdits = "apply_edits"
    /// Codex-style `apply_patch` file changes.
    case applyPatch = "apply_patch"
    /// Cursor's native ACP `edit` tool.
    case nativeEdit = "edit"

    init?(normalizedToolName: String?) {
        guard let normalized = normalizedToolName?.lowercased(),
              let kind = AgentEditToolKind(rawValue: normalized)
        else {
            return nil
        }
        self = kind
    }
}

// MARK: - Normalized Facts

/// What an edit payload claims happened to one file.
enum AgentEditedFileDisposition: String, Hashable {
    /// The file did not exist before the edit.
    case created
    /// The file existed and its whole content was replaced.
    case overwritten
    /// The file existed and part of it changed.
    case modified
    /// The file was removed.
    case deleted

    /// Whether the payload claims this edit authored the file's whole content.
    ///
    /// The right-utility-panel design (decision 12) keeps pure modifications out of the artifact
    /// banner, so this is the property that separates a session artifact from ordinary edit noise.
    var isWholeFileWrite: Bool {
        self == .created || self == .overwritten
    }
}

/// How far an edit tool call got, as far as its own payload admits.
enum AgentEditToolOutcome: String, Hashable {
    case succeeded
    /// Some edits landed and some did not (`partial`, `warning`).
    case partial
    /// Nothing reached disk: failed, cancelled, rejected, or declined.
    case failed
    /// Still streaming; the payload lists changes that may not have been written yet.
    case pending
    /// The payload carried no status word this decoder recognizes.
    case unknown

    /// Whether the payload is consistent with content having reached disk.
    ///
    /// `unknown` counts as reaching disk: a payload that states `file_created` but carries no
    /// status word still describes a written file, and dropping it would lose real artifacts.
    var mayHaveReachedDisk: Bool {
        switch self {
        case .succeeded, .partial, .unknown: true
        case .failed, .pending: false
        }
    }
}

/// One file touched by an edit tool call, normalized across the three payload shapes.
struct AgentEditedFileFact: Hashable {
    /// The path exactly as the payload reported it. Agents pass absolute and relative paths alike,
    /// and this type has no workspace root to resolve against, so the verbatim string is kept and
    /// `absolutePath` / `relativePath` merely classify it.
    let path: String
    /// Rename or move destination when the payload carried one.
    let movedToPath: String?
    let disposition: AgentEditedFileDisposition
    /// The payload's own change word (`apply_patch` kinds such as `add` / `update` / `delete`),
    /// preserved so consumers can branch on the exact vocabulary a provider used.
    let rawChangeKind: String?
    /// Unified diff text when the payload carried one, or could cheaply build one from old/new text.
    let diffText: String?
    /// Whether the provider truncated the diff or the text it was built from.
    let isDiffTruncated: Bool

    init(
        path: String,
        movedToPath: String? = nil,
        disposition: AgentEditedFileDisposition,
        rawChangeKind: String? = nil,
        diffText: String? = nil,
        isDiffTruncated: Bool = false
    ) {
        self.path = path
        self.movedToPath = movedToPath
        self.disposition = disposition
        self.rawChangeKind = rawChangeKind
        self.diffText = diffText
        self.isDiffTruncated = isDiffTruncated
    }

    var isAbsolutePath: Bool {
        path.hasPrefix("/")
    }

    /// The reported path when it is already absolute; `nil` when the tool reported a relative path.
    var absolutePath: String? {
        isAbsolutePath ? path : nil
    }

    /// The reported path when it is relative to some root; `nil` when the tool reported an absolute path.
    var relativePath: String? {
        isAbsolutePath ? nil : path
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// Lowercased extension without its dot, empty when the path has none.
    var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }
}

/// The normalized view of one edit tool result.
struct AgentEditToolFacts: Hashable {
    let toolKind: AgentEditToolKind
    let outcome: AgentEditToolOutcome
    /// Files in payload order. Empty when the payload named no file this decoder could read.
    let files: [AgentEditedFileFact]
}

// MARK: - Decoder

/// The single place edit-tool payloads are turned into facts.
///
/// Before the right utility panel this decoding lived only inside `ToolResultEditCards.swift`, which
/// meant anything else that wanted to know "which files did the agent just write?" had to re-parse
/// the same JSON with its own rules. The tool cards now consume this decoder, so the cards and the
/// panel's artifact index cannot disagree about a payload.
///
/// This type is deliberately view-free: it holds no SwiftUI import, no colors, and no formatting.
enum AgentEditToolResultDecoder {
    // MARK: Entry Points

    /// The edit family a transcript item belongs to, or `nil` when it is not an edit tool result.
    static func editToolKind(for item: AgentChatItem) -> AgentEditToolKind? {
        guard item.kind == .toolResult else { return nil }
        return AgentEditToolKind(normalizedToolName: normalizedToolCardName(item.toolName))
    }

    /// Normalized facts for a transcript item, or `nil` when the item is not an edit tool result.
    static func facts(for item: AgentChatItem) -> AgentEditToolFacts? {
        guard let toolKind = editToolKind(for: item) else { return nil }
        return facts(
            toolKind: toolKind,
            resultJSON: item.toolResultJSON,
            argsJSON: item.toolArgsJSON,
            isError: item.toolIsError
        )
    }

    /// Normalized facts from raw payload strings, for callers that hold no transcript item.
    static func facts(
        toolName: String?,
        resultJSON: String?,
        argsJSON: String?,
        isError: Bool?
    ) -> AgentEditToolFacts? {
        guard let toolKind = AgentEditToolKind(normalizedToolName: normalizedToolCardName(toolName)) else {
            return nil
        }
        return facts(toolKind: toolKind, resultJSON: resultJSON, argsJSON: argsJSON, isError: isError)
    }

    static func facts(
        toolKind: AgentEditToolKind,
        resultJSON: String?,
        argsJSON: String?,
        isError: Bool?
    ) -> AgentEditToolFacts {
        switch toolKind {
        case .applyEdits:
            let summary = applyEditsSummary(resultJSON: resultJSON)
            return AgentEditToolFacts(
                toolKind: .applyEdits,
                outcome: outcome(fromStatus: summary?.status, isError: isError),
                files: applyEditsFiles(summary: summary, arguments: applyEditsArguments(argsJSON: argsJSON))
            )
        case .applyPatch:
            let summary = applyPatchSummary(resultJSON: resultJSON)
            return AgentEditToolFacts(
                toolKind: .applyPatch,
                outcome: outcome(fromStatus: summary?.status, isError: isError),
                files: applyPatchFiles(summary: summary)
            )
        case .nativeEdit:
            let summary = nativeEditSummary(resultJSON: resultJSON)
            return AgentEditToolFacts(
                toolKind: .nativeEdit,
                outcome: outcome(fromStatus: summary?.acpStatus ?? summary?.status, isError: isError),
                files: nativeEditFiles(summary: summary)
            )
        }
    }

    // MARK: apply_edits

    static func applyEditsSummary(resultJSON: String?) -> ToolResultDTOs.EditSummary? {
        ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: resultJSON)
    }

    static func applyEditsArguments(argsJSON: String?) -> ToolArgsDTOs.ApplyEditsArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.ApplyEditsArgs.self, from: argsJSON)
    }

    /// The diff an `apply_edits` card shows: the compact card diff when present, else the full one.
    static func applyEditsDisplayDiff(from summary: ToolResultDTOs.EditSummary?) -> String? {
        guard let summary else { return nil }
        if let diff = summary.cardUnifiedDiff, !diff.isEmpty { return diff }
        if let diff = summary.unifiedDiff, !diff.isEmpty { return diff }
        return nil
    }

    /// `apply_edits` touches exactly one file, and only its arguments carry the path — the result
    /// payload reports the created/overwritten flags but never the path itself.
    static func applyEditsFiles(
        summary: ToolResultDTOs.EditSummary?,
        arguments: ToolArgsDTOs.ApplyEditsArgs?
    ) -> [AgentEditedFileFact] {
        guard let path = nonEmpty(arguments?.path) else { return [] }
        return [
            AgentEditedFileFact(
                path: path,
                disposition: applyEditsDisposition(summary: summary),
                diffText: applyEditsDisplayDiff(from: summary)
            )
        ]
    }

    /// `file_created` wins over `file_overwritten`: a payload that sets both still describes a file
    /// that did not exist beforehand, which is the stronger claim.
    private static func applyEditsDisposition(summary: ToolResultDTOs.EditSummary?) -> AgentEditedFileDisposition {
        if summary?.fileCreated == true { return .created }
        if summary?.fileOverwritten == true { return .overwritten }
        return .modified
    }

    // MARK: apply_patch

    static func applyPatchSummary(resultJSON: String?) -> ToolResultDTOs.ApplyPatchSummary? {
        ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: resultJSON)
    }

    /// Every change in payload order, including ones with an empty path: the patch card renders each
    /// change it is given, so filtering here would silently drop a row. Consumers that need a real
    /// file (the artifact extractor) filter on their own terms.
    static func applyPatchFiles(summary: ToolResultDTOs.ApplyPatchSummary?) -> [AgentEditedFileFact] {
        guard let summary else { return [] }
        return summary.changes.map { change in
            let rawKind = change.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return AgentEditedFileFact(
                path: change.path,
                movedToPath: nonEmpty(change.movePath),
                disposition: applyPatchDisposition(rawKind: rawKind),
                rawChangeKind: rawKind,
                diffText: nonEmpty(change.diff)
            )
        }
    }

    private static func applyPatchDisposition(rawKind: String) -> AgentEditedFileDisposition {
        switch rawKind {
        case "add", "added", "create", "created": .created
        case "delete", "deleted", "remove", "removed": .deleted
        default: .modified
        }
    }

    // MARK: Native edit (Cursor ACP)

    static func nativeEditSummary(resultJSON: String?) -> ToolResultDTOs.CursorNativeEditSummary? {
        ToolJSON.decode(ToolResultDTOs.CursorNativeEditSummary.self, from: resultJSON)
    }

    /// Content blocks that describe a real diff, in payload order.
    ///
    /// Blocks are dropped exactly where the edit card used to drop them: a non-diff block type, a
    /// blank path, or a block whose old/new text yields an empty diff. A dropped block is one the
    /// card would not have rendered either.
    static func nativeEditFiles(summary: ToolResultDTOs.CursorNativeEditSummary?) -> [AgentEditedFileFact] {
        guard let content = summary?.content else { return [] }
        return content.compactMap { block in
            let blockType = block.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard blockType == nil || blockType == "diff",
                  let path = nonEmpty(block.path?.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return nil
            }
            let isTruncated = block.diffTruncated == true
                || block.oldTextTruncated == true
                || block.newTextTruncated == true
            if let persistedDiff = nonEmpty(block.unifiedDiff?.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return AgentEditedFileFact(
                    path: path,
                    disposition: nativeEditDisposition(oldText: block.oldText, newText: block.newText),
                    diffText: persistedDiff,
                    isDiffTruncated: isTruncated
                )
            }
            guard let oldText = block.oldText, let newText = block.newText else { return nil }
            let diff = unifiedDiff(path: path, oldText: oldText, newText: newText)
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AgentEditedFileFact(
                path: path,
                disposition: nativeEditDisposition(oldText: oldText, newText: newText),
                diffText: diff,
                isDiffTruncated: isTruncated
            )
        }
    }

    /// ACP edits carry no created/overwritten flags, so the only honest signal is the old text the
    /// provider itself reported: present and empty means there was nothing there before. Absent old
    /// text stays `modified` rather than guessing — a wrong "created" would put a file in the
    /// artifact banner that the agent merely touched.
    private static func nativeEditDisposition(oldText: String?, newText: String?) -> AgentEditedFileDisposition {
        guard let oldText, oldText.isEmpty, let newText, !newText.isEmpty else { return .modified }
        return .created
    }

    private static func unifiedDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = String.splitContentPreservingLineEndings(oldText).0
        let newLines = String.splitContentPreservingLineEndings(newText).0
        let chunks = UnifiedDiffGenerator.diffChunks(oldLines: oldLines, newLines: newLines, context: 2)
        return UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
    }

    // MARK: Shared

    /// One status vocabulary for all three families, on top of the transcript's existing status-word
    /// normalizer. `declined` is spelled out because patch approvals use it and it means the same
    /// thing as a rejection here: nothing was written.
    private static func outcome(fromStatus rawStatus: String?, isError: Bool?) -> AgentEditToolOutcome {
        if isError == true { return .failed }
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(rawStatus) else {
            return .unknown
        }
        switch normalized {
        case "success": return .succeeded
        case "warning": return .partial
        case "failed", "cancelled", "declined": return .failed
        case "running", "pending": return .pending
        default: return .unknown
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
