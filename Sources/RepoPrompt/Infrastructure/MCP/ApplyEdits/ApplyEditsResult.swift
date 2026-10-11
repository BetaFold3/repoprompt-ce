import Foundation
import RepoPromptWorkspace

enum ApplyEditsStatus: String, Equatable {
    case success
    case partial
    case failed
}

struct ApplyEditsStats: Equatable {
    let linesChanged: Int
    let chunks: Int
}

struct ApplyEditsLineStats: Equatable {
    let addedLines: Int
    let deletedLines: Int
}

struct ApplyEditsResult: Equatable {
    let updatedText: String
    let diffChunks: [DiffChunk]
    let unifiedDiff: String?
    let toolCardUnifiedDiff: String?
    let stats: ApplyEditsStats?
    let note: String?
    let fileCreated: Bool
    let fileOverwritten: Bool
    let editsRequested: Int
    let editsApplied: Int
    let status: ApplyEditsStatus
    let outcomes: [EditOutcome]?

    func withFileMetadata(created: Bool, overwritten: Bool) -> ApplyEditsResult {
        ApplyEditsResult(
            updatedText: updatedText,
            diffChunks: diffChunks,
            unifiedDiff: unifiedDiff,
            toolCardUnifiedDiff: toolCardUnifiedDiff,
            stats: stats,
            note: note,
            fileCreated: created,
            fileOverwritten: overwritten,
            editsRequested: editsRequested,
            editsApplied: editsApplied,
            status: status,
            outcomes: outcomes
        )
    }
}

extension ApplyEditsResult {
    func toolCardLineStats() -> ApplyEditsLineStats? {
        guard !diffChunks.isEmpty else { return nil }
        var addedLines = 0
        var deletedLines = 0
        for chunk in diffChunks {
            for line in chunk.lines {
                switch line.type {
                case .addition:
                    addedLines += 1
                case .removal:
                    deletedLines += 1
                case .context:
                    continue
                }
            }
        }
        return ApplyEditsLineStats(addedLines: addedLines, deletedLines: deletedLines)
    }

    /// UI-safe unified diff source:
    /// - Prefer explicit verbose diff when present.
    /// - Otherwise synthesize from applied diff chunks for tool-card rendering.
    func unifiedDiffForToolCard(filePath: String) -> String? {
        if let toolCardUnifiedDiff, !toolCardUnifiedDiff.isEmpty {
            return toolCardUnifiedDiff
        }
        if let unifiedDiff, !unifiedDiff.isEmpty {
            return unifiedDiff
        }
        guard !diffChunks.isEmpty else { return nil }
        let decodedChunks = diffChunks.map { $0.withDecodedIndentation() }
        return UnifiedDiffGenerator.buildFromEditChunks(
            filePath: filePath,
            chunks: decodedChunks,
            startLineBase: .oneBased
        )
    }
}
