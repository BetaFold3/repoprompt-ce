import Foundation
@testable import RepoPromptApp

/// Captured edit-tool payloads, shaped the way the real emitters shape them.
///
/// Edit summaries follow `MCPApplyEditsToolProvider`'s encoding, patch bodies follow
/// `CodexNativeSessionController`'s file-change payload, and native edit bodies follow the Cursor
/// ACP content blocks. Keeping them in one place means the decoder tests, the artifact tests, and
/// the index tests all argue about the same bytes.
enum AgentEditToolPayloadFixtures {
    struct Payload {
        let name: String
        let toolName: String
        let resultJSON: String
        let argsJSON: String?
        let isError: Bool?

        init(name: String, toolName: String, resultJSON: String, argsJSON: String? = nil, isError: Bool? = nil) {
            self.name = name
            self.toolName = toolName
            self.resultJSON = resultJSON
            self.argsJSON = argsJSON
            self.isError = isError
        }

        func item(
            id: UUID = UUID(),
            timestamp: Date = Date(timeIntervalSince1970: 1_754_000_000),
            sequenceIndex: Int = 0
        ) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: timestamp,
                kind: .toolResult,
                text: resultJSON,
                toolName: toolName,
                toolArgsJSON: argsJSON,
                toolResultJSON: resultJSON,
                toolIsError: isError,
                sequenceIndex: sequenceIndex
            )
        }
    }

    // MARK: - Edit summaries

    static let editCreatedMarkdown = Payload(
        name: "edit summary creating a markdown report",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "success",
          "edits_requested": 1,
          "edits_applied": 1,
          "added_lines": 3,
          "deleted_lines": 0,
          "total_lines_changed": 3,
          "total_chunks": 1,
          "unified_diff": "--- docs/impl-report.md\n+++ docs/impl-report.md\n@@ -1,0 +1,3 @@\n+# Implementation report\n+\n+Everything landed.\n",
          "card_unified_diff": "--- docs/impl-report.md\n+++ docs/impl-report.md\n@@ -1,0 +1,3 @@\n+# Implementation report\n",
          "file_created": true,
          "operation_id": "5C2B1F1E-0F3E-4E0B-9A2E-3D5B7F1A9C11",
          "mutation_state": "applied"
        }
        """#,
        argsJSON: ##"{"path":"/Users/dev/project/docs/impl-report.md","rewrite":"# Implementation report\n\nEverything landed.\n"}"##
    )

    static let editOverwrittenHTMLRelativePath = Payload(
        name: "edit summary overwriting html at a relative path",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "success",
          "edits_requested": 1,
          "edits_applied": 1,
          "total_lines_changed": 12,
          "total_chunks": 1,
          "unified_diff": "--- docs/coverage.html\n+++ docs/coverage.html\n@@ -1,2 +1,2 @@\n-<html><body>old</body></html>\n+<html><body>new</body></html>\n",
          "file_overwritten": true
        }
        """#,
        argsJSON: #"{"path":"docs/coverage.html","rewrite":"<html><body>new</body></html>"}"#
    )

    /// The compact card diff must win over the full diff, and a plain edit stays a modification.
    static let editModifiedSwiftWithBothDiffs = Payload(
        name: "edit summary modifying swift and carrying both diffs",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "success",
          "edits_requested": 2,
          "edits_applied": 2,
          "added_lines": 4,
          "deleted_lines": 2,
          "total_lines_changed": 4,
          "total_chunks": 2,
          "unified_diff": "--- Sources/App/Runner.swift\n+++ Sources/App/Runner.swift\n@@ -10,4 +10,6 @@\n full diff\n",
          "card_unified_diff": "--- Sources/App/Runner.swift\n+++ Sources/App/Runner.swift\n@@ -10,4 +10,6 @@\n compact diff\n"
        }
        """#,
        argsJSON: #"{"path":"/Users/dev/project/Sources/App/Runner.swift","search":"old","replace":"new"}"#
    )

    /// A markdown edit that did not land: nothing to offer the user.
    static let editFailedMarkdown = Payload(
        name: "edit summary that failed",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "failed",
          "edits_requested": 1,
          "edits_applied": 0,
          "error": "Search text not found",
          "error_code": "search_not_found",
          "retryable": true
        }
        """#,
        argsJSON: #"{"path":"/Users/dev/project/docs/impl-report.md","search":"missing","replace":"new"}"#,
        isError: true
    )

    /// The compacted shape a persisted transcript keeps: flags survive, diff bodies do not.
    static let editSummaryOnlyCreatedMarkdown = Payload(
        name: "summary-only edit creating markdown",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "success",
          "summary_only": true,
          "edits_requested": 1,
          "edits_applied": 1,
          "total_lines_changed": 40,
          "file_created": true
        }
        """#,
        argsJSON: #"{"path":"docs/design-notes.md"}"#
    )

    /// Providers wrap results in envelopes and namespace tool names; both must resolve.
    static let editEnvelopeWrappedCreatedMarkdown = Payload(
        name: "namespaced edit summary inside a structured-content envelope",
        toolName: "functions.apply_edits",
        resultJSON: #"""
        {
          "structuredContent": {
            "status": "success",
            "edits_requested": 1,
            "edits_applied": 1,
            "total_lines_changed": 6,
            "card_unified_diff": "--- notes/summary.md\n+++ notes/summary.md\n@@ -1,0 +1,1 @@\n+summary\n",
            "file_created": true
          }
        }
        """#,
        argsJSON: #"{"path":"notes/summary.md","rewrite":"summary\n"}"#
    )

    static let editWithoutArguments = Payload(
        name: "edit summary with no arguments recorded",
        toolName: "apply_edits",
        resultJSON: #"""
        {
          "status": "success",
          "edits_requested": 1,
          "edits_applied": 1,
          "total_lines_changed": 1,
          "file_created": true
        }
        """#,
        argsJSON: nil
    )

    // MARK: - Patches

    static let patchMixedChanges = Payload(
        name: "patch adding, updating, moving, and deleting files",
        toolName: "apply_patch",
        resultJSON: #"""
        {
          "status": "completed",
          "change_count": 4,
          "summary_only": false,
          "changes": [
            {
              "path": "docs/plan.md",
              "kind": "add",
              "diff": "# Plan\n\nStep one.\n"
            },
            {
              "path": "Sources/App/Runner.swift",
              "kind": "update",
              "diff": "--- Sources/App/Runner.swift\n+++ Sources/App/Runner.swift\n@@ -1,3 +1,4 @@\n context\n+added\n"
            },
            {
              "path": "docs/notes.md",
              "kind": "update",
              "move_path": "docs/archive/notes.md",
              "diff": "--- docs/notes.md\n+++ docs/archive/notes.md\n@@ -1,1 +1,1 @@\n-old\n+new\n"
            },
            {
              "path": "docs/obsolete.md",
              "kind": "delete",
              "diff": ""
            }
          ]
        }
        """#,
        argsJSON: #"{"path":"docs/plan.md","paths":["docs/plan.md","Sources/App/Runner.swift","docs/notes.md","docs/obsolete.md"],"change_count":4}"#
    )

    /// Codex streams file changes before they are applied.
    static let patchRunningMarkdown = Payload(
        name: "patch still running",
        toolName: "apply_patch",
        resultJSON: #"""
        {
          "status": "running",
          "change_count": 1,
          "summary_only": false,
          "changes": [
            {
              "path": "docs/streaming-report.md",
              "kind": "add",
              "diff": "# Streaming\n"
            }
          ]
        }
        """#,
        argsJSON: #"{"path":"docs/streaming-report.md","change_count":1}"#
    )

    static let patchDeclinedMarkdown = Payload(
        name: "patch declined by the user",
        toolName: "apply_patch",
        resultJSON: #"""
        {
          "status": "declined",
          "change_count": 1,
          "summary_only": false,
          "changes": [
            {
              "path": "docs/rejected-report.md",
              "kind": "add",
              "diff": "# Rejected\n"
            }
          ]
        }
        """#,
        argsJSON: #"{"path":"docs/rejected-report.md","change_count":1}"#
    )

    /// The compacted persisted shape drops diff bodies but keeps paths and kinds, and arrives under
    /// a provider alias.
    static let patchSummaryOnlyAliasedToolName = Payload(
        name: "summary-only patch under the filechange alias",
        toolName: "filechange",
        resultJSON: #"""
        {
          "status": "success",
          "summary_only": true,
          "change_count": 2,
          "changes": [
            {"path": "docs/report.html", "kind": "add", "diff": ""},
            {"path": "docs/report.md", "kind": "update", "diff": ""}
          ]
        }
        """#
    )

    static let patchWithoutChanges = Payload(
        name: "patch with output and no changes",
        toolName: "apply_patch",
        resultJSON: #"""
        {
          "status": "completed",
          "change_count": 0,
          "changes": [],
          "output": "Nothing to apply."
        }
        """#
    )

    // MARK: - Native edits (Cursor ACP)

    static let nativeCreatedMarkdown = Payload(
        name: "native edit creating a markdown file",
        toolName: "edit",
        resultJSON: #"""
        {
          "status": "completed",
          "acp_status": "completed",
          "kind": "edit",
          "title": "Edit File",
          "change_count": 1,
          "content": [
            {
              "type": "diff",
              "path": "docs/cursor-report.md",
              "oldText": "",
              "newText": "# Cursor report\nDone.\n"
            }
          ]
        }
        """#
    )

    static let nativeModifiedWithPersistedTruncatedDiff = Payload(
        name: "native edit with a persisted truncated diff and a padded path",
        toolName: "Edit File",
        resultJSON: #"""
        {
          "status": "completed",
          "acp_status": "completed",
          "title": "Edit File",
          "change_count": 1,
          "content": [
            {
              "type": "diff",
              "path": "  docs/handbook.md  ",
              "unified_diff": "--- docs/handbook.md\n+++ docs/handbook.md\n@@ -1,2 +1,2 @@\n-old\n+new\n",
              "diff_truncated": true
            }
          ]
        }
        """#
    )

    /// Non-diff blocks, blank paths, and no-op text pairs are all rows the card never drew.
    static let nativeWithUnrenderableBlocks = Payload(
        name: "native edit carrying blocks the card drops",
        toolName: "edit",
        resultJSON: #"""
        {
          "status": "completed",
          "acp_status": "completed",
          "title": "Rename symbol",
          "change_count": 4,
          "content": [
            {
              "type": "text",
              "path": "docs/ignored.md",
              "oldText": "",
              "newText": "# Ignored\n"
            },
            {
              "type": "diff",
              "path": "   ",
              "oldText": "",
              "newText": "# Blank path\n"
            },
            {
              "type": "diff",
              "path": "docs/unchanged.md",
              "oldText": "same\n",
              "newText": "same\n"
            },
            {
              "type": "diff",
              "path": "docs/kept.md",
              "oldText": "one\n",
              "newText": "two\n"
            }
          ]
        }
        """#
    )

    static let nativeFailed = Payload(
        name: "native edit that failed",
        toolName: "edit",
        resultJSON: #"""
        {
          "status": "failed",
          "acp_status": "failed",
          "title": "Edit File",
          "change_count": 1,
          "content": [
            {
              "type": "diff",
              "path": "docs/failed-report.md",
              "oldText": "",
              "newText": "# Never written\n"
            }
          ]
        }
        """#
    )

    // MARK: - Not an edit tool

    static let readFileResult = Payload(
        name: "read_file result",
        toolName: "read_file",
        resultJSON: ##"{"path":"docs/impl-report.md","content":"# Implementation report\n","lines":1}"##,
        argsJSON: #"{"path":"docs/impl-report.md"}"#
    )

    // MARK: - Collections

    static let editSummaryPayloads: [Payload] = [
        editCreatedMarkdown,
        editOverwrittenHTMLRelativePath,
        editModifiedSwiftWithBothDiffs,
        editFailedMarkdown,
        editSummaryOnlyCreatedMarkdown,
        editEnvelopeWrappedCreatedMarkdown,
        editWithoutArguments
    ]

    static let patchPayloads: [Payload] = [
        patchMixedChanges,
        patchRunningMarkdown,
        patchDeclinedMarkdown,
        patchSummaryOnlyAliasedToolName,
        patchWithoutChanges
    ]

    static let nativeEditPayloads: [Payload] = [
        nativeCreatedMarkdown,
        nativeModifiedWithPersistedTruncatedDiff,
        nativeWithUnrenderableBlocks,
        nativeFailed
    ]

    static let allEditPayloads: [Payload] = editSummaryPayloads + patchPayloads + nativeEditPayloads
}

/// The edit-payload rules exactly as `ToolResultEditCards.swift` implemented them before the shared
/// decoder existed, kept verbatim as the parity oracle.
///
/// Nothing here may be tidied up: its whole value is that it is the old code. A failure against this
/// reference means the decoder moved the cards' behavior, and somebody has to decide whether that
/// was intentional.
enum LegacyEditCardPayloadReference {
    // MARK: Edit summaries

    static func resolvedDisplayDiff(from dto: ToolResultDTOs.EditSummary?) -> String? {
        guard let dto else { return nil }
        if let diff = dto.cardUnifiedDiff, !diff.isEmpty { return diff }
        if let diff = dto.unifiedDiff, !diff.isEmpty { return diff }
        return nil
    }

    // MARK: Patches

    struct PatchChange: Equatable {
        let path: String
        let movePath: String?
        let diff: String
        let rendersAsUnifiedDiff: Bool
    }

    static func patchChanges(from dto: ToolResultDTOs.ApplyPatchSummary?) -> [PatchChange] {
        guard let dto else { return [] }
        return dto.changes.map { change in
            PatchChange(
                path: change.path,
                movePath: (change.movePath?.isEmpty == false) ? change.movePath : nil,
                diff: change.diff,
                rendersAsUnifiedDiff: isUnifiedDiff(change.diff, kind: change.kind)
            )
        }
    }

    static func isUnifiedDiff(_ diff: String, kind: String) -> Bool {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedKind != "update" {
            return false
        }
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@@") || trimmed.contains("--- ") || trimmed.contains("+++ ")
    }

    // MARK: Native edits

    struct DisplayDiff: Equatable {
        let path: String
        let diff: String
        let isTruncated: Bool
    }

    static func displayDiffs(from dto: ToolResultDTOs.CursorNativeEditSummary?) -> [DisplayDiff] {
        guard let content = dto?.content else { return [] }
        return content.compactMap { block in
            let blockType = block.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard blockType == nil || blockType == "diff",
                  let rawPath = block.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty
            else {
                return nil
            }
            let isTruncated = block.diffTruncated == true
                || block.oldTextTruncated == true
                || block.newTextTruncated == true
            if let persistedDiff = block.unifiedDiff?.trimmingCharacters(in: .whitespacesAndNewlines),
               !persistedDiff.isEmpty
            {
                return DisplayDiff(path: rawPath, diff: persistedDiff, isTruncated: isTruncated)
            }
            guard let oldText = block.oldText,
                  let newText = block.newText else { return nil }
            let diff = unifiedDiff(path: rawPath, oldText: oldText, newText: newText)
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DisplayDiff(path: rawPath, diff: diff, isTruncated: isTruncated)
        }
    }

    private static func unifiedDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = String.splitContentPreservingLineEndings(oldText).0
        let newLines = String.splitContentPreservingLineEndings(newText).0
        let chunks = UnifiedDiffGenerator.diffChunks(
            oldLines: oldLines,
            newLines: newLines,
            context: 2
        )
        return UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
    }
}
