import Foundation
import RepoPromptWorkspace

struct WorktreeMergeReviewScope: Hashable {
    let windowID: Int
    let tabID: UUID
}

struct PendingWorktreeMergeReview: Identifiable, Equatable {
    let id: UUID
    let scope: WorktreeMergeReviewScope
    let operationID: String
    let sourceLabel: String
    let sourceBranch: String?
    let sourcePath: String
    let sourceHead: String
    let targetLabel: String
    let targetBranch: String?
    let targetPath: String
    let targetHead: String
    let mergeBase: String
    let visualization: String
    let summary: GitWorktreeMergeSummary?
    let artifacts: GitWorktreeMergePreviewArtifacts?
    let conflictPrediction: GitWorktreeMergeConflictPrediction
    let createdAt: Date

    init(
        id: UUID = UUID(),
        scope: WorktreeMergeReviewScope,
        preview: GitWorktreeMergePreview,
        createdAt: Date = Date()
    ) {
        let inspection = preview.inspection
        self.id = id
        self.scope = scope
        operationID = preview.operationID
        sourceLabel = inspection.source.displayName
        sourceBranch = inspection.source.branch
        sourcePath = inspection.source.path
        sourceHead = inspection.sourceHead
        targetLabel = inspection.target.displayName
        targetBranch = inspection.target.branch
        targetPath = inspection.target.path
        targetHead = inspection.targetHead
        mergeBase = inspection.mergeBase
        visualization = inspection.visualization
        summary = inspection.summary
        artifacts = preview.artifacts
        conflictPrediction = inspection.conflictPrediction
        self.createdAt = createdAt
    }
}

enum WorktreeMergeReviewDecision: Equatable {
    case accept
    case reject(reason: String)
    case timeout
    case cancelled(reason: String)

    var cancelledReason: String? {
        switch self {
        case .accept:
            nil
        case let .reject(reason):
            reason
        case .timeout:
            "Timed out while waiting for worktree merge approval."
        case let .cancelled(reason):
            reason
        }
    }
}
