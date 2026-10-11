import Foundation
import RepoPromptWorkspace

package enum AgentSourceItemsMutation {
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

    package var touchesUserItem: Bool {
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

package enum AgentTranscriptAutoFollowArmingState: String, Codable, Equatable {
    case armed
    case disarmedAfterManualDetach
}

package struct AgentPendingSourceItemsMutationSummary: Equatable {
    package var earliestChangedIndex: Int
    package var latestChangedIndex: Int
    package var containsRemoval: Bool
    package var containsReplaceAll: Bool
    package var containsUserMutation: Bool
    package var containsStructuralMutation: Bool

    package init(_ mutation: AgentSourceItemsMutation) {
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

    package mutating func merge(_ mutation: AgentSourceItemsMutation) {
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

    package var allowsIncrementalFinalTurnRebuild: Bool {
        !containsRemoval
            && !containsReplaceAll
            && !containsUserMutation
            && !containsStructuralMutation
    }
}

package struct AgentDerivedTranscriptSyncState: Equatable {
    let sourceItemsRevision: Int
    let nextSequenceIndex: Int
    let runState: AgentSessionRunState
    let selectedAgent: AgentProviderKind
    let hidePendingQuestionToolCall: Bool
    let projectionProtection: AgentTranscriptProjectionProtection

    package init(
        sourceItemsRevision: Int,
        nextSequenceIndex: Int,
        runState: AgentSessionRunState,
        selectedAgent: AgentProviderKind,
        hidePendingQuestionToolCall: Bool,
        projectionProtection: AgentTranscriptProjectionProtection
    ) {
        self.sourceItemsRevision = sourceItemsRevision
        self.nextSequenceIndex = nextSequenceIndex
        self.runState = runState
        self.selectedAgent = selectedAgent
        self.hidePendingQuestionToolCall = hidePendingQuestionToolCall
        self.projectionProtection = projectionProtection
    }
}

package struct AgentBuiltTranscriptPresentation {
    package let transcript: AgentTranscript
    package let baseProjection: AgentTranscriptProjection
    package let fullProjection: AgentTranscriptProjection
    package let workingProjection: AgentTranscriptProjection
    let projection: AgentTranscriptProjection
    package let turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
    package let archivedSnapshot: AgentArchivedTranscriptSnapshot
    package let projectionProtection: AgentTranscriptProjectionProtection
    package let canonicalVisibleRowCount: Int
    package let projectionCounts: AgentTranscriptProjectionCounts
    package let analyticsSnapshot: AgentTranscriptAnalyticsSnapshot
    package let sanitizedActivityCount: Int
    package let performanceSnapshot: AgentTranscriptPerformanceSnapshot
    package let rawToolResultPayloadRenderRevisionByItemID: [UUID: Int]

    package init(
        transcript: AgentTranscript,
        baseProjection: AgentTranscriptProjection,
        fullProjection: AgentTranscriptProjection,
        workingProjection: AgentTranscriptProjection,
        projection: AgentTranscriptProjection,
        turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache],
        archivedSnapshot: AgentArchivedTranscriptSnapshot,
        projectionProtection: AgentTranscriptProjectionProtection,
        canonicalVisibleRowCount: Int,
        projectionCounts: AgentTranscriptProjectionCounts,
        analyticsSnapshot: AgentTranscriptAnalyticsSnapshot,
        sanitizedActivityCount: Int,
        performanceSnapshot: AgentTranscriptPerformanceSnapshot,
        rawToolResultPayloadRenderRevisionByItemID: [UUID: Int]
    ) {
        self.transcript = transcript
        self.baseProjection = baseProjection
        self.fullProjection = fullProjection
        self.workingProjection = workingProjection
        self.projection = projection
        self.turnProjectionCaches = turnProjectionCaches
        self.archivedSnapshot = archivedSnapshot
        self.projectionProtection = projectionProtection
        self.canonicalVisibleRowCount = canonicalVisibleRowCount
        self.projectionCounts = projectionCounts
        self.analyticsSnapshot = analyticsSnapshot
        self.sanitizedActivityCount = sanitizedActivityCount
        self.performanceSnapshot = performanceSnapshot
        self.rawToolResultPayloadRenderRevisionByItemID = rawToolResultPayloadRenderRevisionByItemID
    }
}

package enum AgentDerivedTranscriptRefreshReason: String {
    case liveMutation
    case saveSession
    case coldLoad
    case manualRefresh
}
