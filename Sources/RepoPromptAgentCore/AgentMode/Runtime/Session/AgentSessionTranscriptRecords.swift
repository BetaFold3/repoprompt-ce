import Foundation
import RepoPromptWorkspace

package enum AgentSourceItemsMutation {
    case append(index: Int, itemKind: AgentChatItemKind)
    case replace(index: Int, previousKind: AgentChatItemKind, currentKind: AgentChatItemKind)
    case mutate(index: Int, itemKind: AgentChatItemKind)
    case remove(index: Int, itemKind: AgentChatItemKind)
    /// Segment end: only `isStreaming` of existing assistant rows flipped, in place. The range
    /// spans the lowest through highest flipped index; interior rows may be unchanged. Computed in the same
    /// main-actor turn as the flip. No row is added, removed, reordered, or re-kinded.
    case assistantStreamingStateChanged(changedIndexRange: ClosedRange<Int>)
    /// Reasoning segment end: only `isStreaming` of existing thinking rows flipped, in place,
    /// with the same exact-range and same-turn contract as `assistantStreamingStateChanged`.
    case reasoningStreamingStateChanged(changedIndexRange: ClosedRange<Int>)
    case replaceAll
    case structural

    var changedIndexRange: ClosedRange<Int>? {
        switch self {
        case let .append(index, _),
             let .replace(index, _, _),
             let .mutate(index, _),
             let .remove(index, _):
            index ... index
        case let .assistantStreamingStateChanged(changedIndexRange),
             let .reasoningStreamingStateChanged(changedIndexRange):
            changedIndexRange
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
        case .assistantStreamingStateChanged, .reasoningStreamingStateChanged:
            false
        case .replaceAll, .structural:
            true
        }
    }

    var isStructural: Bool {
        switch self {
        case .remove, .replaceAll, .structural:
            true
        case .append, .replace, .mutate, .assistantStreamingStateChanged, .reasoningStreamingStateChanged:
            false
        }
    }
}

/// Static, content-free source location of the call into a `TabSession` source-items
/// mutation entry. Delivered through `onSourceItemsChanged`; recorded on the pending
/// mutation summary only in DEBUG.
package struct AgentSourceItemsMutationCaller {
    let fileID: StaticString
    let function: StaticString
    let line: UInt

    /// Direct `items` writes reach the callback through `items.didSet`, which has no caller context.
    static let itemsDidSet = AgentSourceItemsMutationCaller(fileID: "TabSession", function: "items.didSet", line: 0)

    /// Bounded label: file basename, line, and function base name (no arguments, no payload).
    package var label: String {
        let fileText = "\(fileID)"
        let functionText = "\(function)"
        let file = fileText.split(separator: "/").last.map(String.init) ?? fileText
        let functionName = functionText.split(separator: "(").first.map(String.init) ?? functionText
        return "\(file)_L\(line)_\(functionName)"
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
    /// Diagnostics: a merged mutation had no `changedIndexRange` (resets `earliestChangedIndex` to 0).
    /// Does not participate in admission or equality.
    package var containsUnrangedMutation: Bool
    #if DEBUG
        /// Bounded DEBUG attribution for merged mutations: fixed slots, never a growing list.
        package struct DebugAttribution {
            package var firstCaller: AgentSourceItemsMutationCaller
            /// Caller whose mutation first set the current `earliestChangedIndex` (lower index or unranged reset).
            package var earliestChangeCaller: AgentSourceItemsMutationCaller
            /// First caller whose mutation made the summary disallow incremental final-turn rebuild.
            package var firstRejectingCaller: AgentSourceItemsMutationCaller?
            package var firstUnrangedCaller: AgentSourceItemsMutationCaller?
            package var mergedMutationCount: Int
        }

        package var debugAttribution: DebugAttribution?
    #endif

    package init(_ mutation: AgentSourceItemsMutation, caller: AgentSourceItemsMutationCaller? = nil) {
        let changedRange = mutation.changedIndexRange
        containsUnrangedMutation = changedRange == nil
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
        #if DEBUG
            if let caller {
                let rejectsIncremental = !allowsIncrementalFinalTurnRebuild
                debugAttribution = DebugAttribution(
                    firstCaller: caller,
                    earliestChangeCaller: caller,
                    firstRejectingCaller: rejectsIncremental ? caller : nil,
                    firstUnrangedCaller: changedRange == nil ? caller : nil,
                    mergedMutationCount: 1
                )
            }
        #endif
    }

    package mutating func merge(_ mutation: AgentSourceItemsMutation, caller: AgentSourceItemsMutationCaller? = nil) {
        #if DEBUG
            let previousEarliestChangedIndex = earliestChangedIndex
            let previouslyAllowedIncremental = allowsIncrementalFinalTurnRebuild
        #endif
        if let changedRange = mutation.changedIndexRange {
            earliestChangedIndex = min(earliestChangedIndex, changedRange.lowerBound)
            latestChangedIndex = max(latestChangedIndex, changedRange.upperBound)
        } else {
            earliestChangedIndex = 0
            latestChangedIndex = Int.max
            containsUnrangedMutation = true
        }
        if case .remove = mutation {
            containsRemoval = true
        }
        if case .replaceAll = mutation {
            containsReplaceAll = true
        }
        containsUserMutation = containsUserMutation || mutation.touchesUserItem
        containsStructuralMutation = containsStructuralMutation || mutation.isStructural
        #if DEBUG
            if var attribution = debugAttribution {
                attribution.mergedMutationCount += 1
                if let caller {
                    if earliestChangedIndex < previousEarliestChangedIndex {
                        attribution.earliestChangeCaller = caller
                    }
                    if previouslyAllowedIncremental, !allowsIncrementalFinalTurnRebuild {
                        attribution.firstRejectingCaller = caller
                    }
                    if mutation.changedIndexRange == nil, attribution.firstUnrangedCaller == nil {
                        attribution.firstUnrangedCaller = caller
                    }
                }
                debugAttribution = attribution
            }
        #endif
    }

    package var allowsIncrementalFinalTurnRebuild: Bool {
        !containsRemoval
            && !containsReplaceAll
            && !containsUserMutation
            && !containsStructuralMutation
    }

    /// Equality covers admission-bearing fields only; diagnostics never affect it.
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.earliestChangedIndex == rhs.earliestChangedIndex
            && lhs.latestChangedIndex == rhs.latestChangedIndex
            && lhs.containsRemoval == rhs.containsRemoval
            && lhs.containsReplaceAll == rhs.containsReplaceAll
            && lhs.containsUserMutation == rhs.containsUserMutation
            && lhs.containsStructuralMutation == rhs.containsStructuralMutation
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

    /// True only when `current` changes `runState` and matches every other input. Drives the
    /// run-state-only incremental admission in `refreshDerivedTranscriptState`.
    package func differsOnlyInRunState(from current: AgentDerivedTranscriptSyncState) -> Bool {
        runState != current.runState
            && sourceItemsRevision == current.sourceItemsRevision
            && nextSequenceIndex == current.nextSequenceIndex
            && selectedAgent == current.selectedAgent
            && hidePendingQuestionToolCall == current.hidePendingQuestionToolCall
            && projectionProtection == current.projectionProtection
    }

    /// Diagnostics only: static, content-free labels of the inputs that differ from
    /// `current` (or `syncDelta.nil` when there is no previous state). Never drives admission.
    package static func diagnosticDeltaLabel(
        from previous: AgentDerivedTranscriptSyncState?,
        to current: AgentDerivedTranscriptSyncState
    ) -> String {
        guard let previous else { return "syncDelta.nil" }
        let changed: [(Bool, String)] = [
            (previous.sourceItemsRevision != current.sourceItemsRevision, "rev"),
            (previous.nextSequenceIndex != current.nextSequenceIndex, "seq"),
            (previous.runState != current.runState, "run"),
            (previous.selectedAgent != current.selectedAgent, "agent"),
            (previous.hidePendingQuestionToolCall != current.hidePendingQuestionToolCall, "ask"),
            (previous.projectionProtection != current.projectionProtection, "protect")
        ]
        let labels = changed.compactMap { $0.0 ? $0.1 : nil }
        return "syncDelta." + (labels.isEmpty ? "none" : labels.joined(separator: "-"))
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
    /// The exact pre-sanitize input of `transcript`, installed as the session's raw-input
    /// reuse pair on successful application; nil when the build cannot vouch for it.
    package var rawInputSanitizeEvidence: AgentSanitizeRawInputEvidence?

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
        rawToolResultPayloadRenderRevisionByItemID: [UUID: Int],
        rawInputSanitizeEvidence: AgentSanitizeRawInputEvidence? = nil
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
        self.rawInputSanitizeEvidence = rawInputSanitizeEvidence
    }
}

package enum AgentDerivedTranscriptRefreshReason: String {
    case liveMutation
    case saveSession
    case coldLoad
    case manualRefresh
}
