import Foundation
import RepoPromptWorkspace

enum AgentSourceItemsMutation {
    case append(index: Int, itemKind: AgentChatItemKind)
    case replace(index: Int, previousKind: AgentChatItemKind, currentKind: AgentChatItemKind)
    case mutate(index: Int, itemKind: AgentChatItemKind)
    case remove(index: Int, itemKind: AgentChatItemKind)
    case replaceAll
    case structural

    var changedIndexRange: ClosedRange<Int>? {
        switch self {
        case let .append(index, _),
             let .replace(index, _, _),
             let .mutate(index, _),
             let .remove(index, _):
            index ... index
        case .replaceAll, .structural:
            nil
        }
    }

    var touchesUserItem: Bool {
        switch self {
        case let .append(_, itemKind),
             let .mutate(_, itemKind),
             let .remove(_, itemKind):
            itemKind == .user
        case let .replace(_, previousKind, currentKind):
            previousKind == .user || currentKind == .user
        case .replaceAll, .structural:
            true
        }
    }

    var isStructural: Bool {
        switch self {
        case .remove, .replaceAll, .structural:
            true
        case .append, .replace, .mutate:
            false
        }
    }
}

enum AgentTranscriptAutoFollowArmingState: String, Codable, Equatable {
    case armed
    case disarmedAfterManualDetach
}

struct AgentPendingSourceItemsMutationSummary: Equatable {
    var earliestChangedIndex: Int
    var latestChangedIndex: Int
    var containsRemoval: Bool
    var containsReplaceAll: Bool
    var containsUserMutation: Bool
    var containsStructuralMutation: Bool

    init(_ mutation: AgentSourceItemsMutation) {
        let changedRange = mutation.changedIndexRange
        earliestChangedIndex = changedRange?.lowerBound ?? 0
        latestChangedIndex = changedRange?.upperBound ?? Int.max
        containsRemoval = {
            if case .remove = mutation { return true }
            return false
        }()
        containsReplaceAll = {
            if case .replaceAll = mutation { return true }
            return false
        }()
        containsUserMutation = mutation.touchesUserItem
        containsStructuralMutation = mutation.isStructural
    }

    mutating func merge(_ mutation: AgentSourceItemsMutation) {
        if let changedRange = mutation.changedIndexRange {
            earliestChangedIndex = min(earliestChangedIndex, changedRange.lowerBound)
            latestChangedIndex = max(latestChangedIndex, changedRange.upperBound)
        } else {
            earliestChangedIndex = 0
            latestChangedIndex = Int.max
        }
        if case .remove = mutation {
            containsRemoval = true
        }
        if case .replaceAll = mutation {
            containsReplaceAll = true
        }
        containsUserMutation = containsUserMutation || mutation.touchesUserItem
        containsStructuralMutation = containsStructuralMutation || mutation.isStructural
    }

    var allowsIncrementalFinalTurnRebuild: Bool {
        !containsRemoval
            && !containsReplaceAll
            && !containsUserMutation
            && !containsStructuralMutation
    }
}

struct AgentDerivedTranscriptSyncState: Equatable {
    let sourceItemsRevision: Int
    let nextSequenceIndex: Int
    let runState: AgentSessionRunState
    let selectedAgent: AgentProviderKind
    let hidePendingQuestionToolCall: Bool
    let projectionProtection: AgentTranscriptProjectionProtection
}

struct AgentBuiltTranscriptPresentation {
    let transcript: AgentTranscript
    let baseProjection: AgentTranscriptProjection
    let fullProjection: AgentTranscriptProjection
    let workingProjection: AgentTranscriptProjection
    let projection: AgentTranscriptProjection
    let turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
    let archivedSnapshot: AgentArchivedTranscriptSnapshot
    let projectionProtection: AgentTranscriptProjectionProtection
    let canonicalVisibleRowCount: Int
    let projectionCounts: AgentTranscriptProjectionCounts
    let analyticsSnapshot: AgentTranscriptAnalyticsSnapshot
    let sanitizedActivityCount: Int
    let performanceSnapshot: AgentTranscriptPerformanceSnapshot
    let rawToolResultPayloadRenderRevisionByItemID: [UUID: Int]
}

enum AgentDerivedTranscriptRefreshReason: String {
    case liveMutation
    case saveSession
    case coldLoad
    case manualRefresh
}
