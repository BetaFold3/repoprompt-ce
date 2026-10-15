import CoreGraphics
import Foundation

struct AgentTranscriptScrollRuntimeState {
    let armingState: AgentModeViewModel.AgentTranscriptAutoFollowArmingState
    let isPinnedToLiveBottom: Bool
    let isDetachedFromLiveBottom: Bool
    let isUserInteractingWithScroll: Bool
    let isInteractionBlocked: Bool
    let isRehydrateRestoreActive: Bool
    let isProgrammaticScrollInFlight: Bool
    let canScrollTowardHistory: Bool
    let canScrollTowardLiveBottom: Bool
    let distanceToBottom: CGFloat
}

struct AgentTranscriptViewportProgress {
    let baselineDistanceToBottom: CGFloat
    let currentDistanceToBottom: CGFloat
    let baselineVisibleMinY: CGFloat
    let currentVisibleMinY: CGFloat
}

enum AgentTranscriptScrollCapabilityResolver {
    static func canScrollTowardHistory(
        firstVisibleBlockID: String?,
        effectiveTopVisibleBlockID: String?,
        rawVisibleMinY: CGFloat?,
        fallbackVisibleMinY: CGFloat?,
        epsilon: CGFloat
    ) -> Bool {
        if let firstVisibleBlockID, let effectiveTopVisibleBlockID {
            return effectiveTopVisibleBlockID != firstVisibleBlockID
        }
        if let rawVisibleMinY, rawVisibleMinY > epsilon {
            return true
        }
        if let fallbackVisibleMinY, fallbackVisibleMinY > epsilon {
            return true
        }
        return false
    }
}

func agentDetachedViewportTarget(for block: AgentTranscriptRenderBlock) -> DetachedViewportTarget {
    switch block.kind {
    case .groupedHistory:
        let groupedSequenceIndex = block.groupedHistory?.sections
            .flatMap(\.childBlocks)
            .flatMap(\.rows)
            .map(\.sequenceIndex)
            .min()
        let groupedAnchor = block.primaryAnchor
            ?? block.spanID.map { AgentTranscriptAnchor.groupedHistory(turnID: block.turnID, spanID: $0) }
            ?? .request(turnID: block.turnID)
        return DetachedViewportTarget(
            anchor: groupedAnchor,
            baseSequenceIndex: groupedSequenceIndex
        )
    case .activityCluster:
        return DetachedViewportTarget(
            anchor: block.primaryAnchor,
            baseSequenceIndex: block.rows.map(\.sequenceIndex).min()
        )
    default:
        return DetachedViewportTarget(
            anchor: block.primaryAnchor ?? .request(turnID: block.turnID),
            baseSequenceIndex: block.rows.map(\.sequenceIndex).min()
        )
    }
}

func agentDetachedAuthorityAnchor(for block: AgentTranscriptRenderBlock) -> AgentTranscriptAnchor {
    switch block.kind {
    case .request:
        .request(turnID: block.turnID)
    default:
        block.primaryAnchor ?? .request(turnID: block.turnID)
    }
}

enum AgentTranscriptManualDetachOverridePolicy {
    static func isActive(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    static func shouldSuppressActualBottomRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }

    static func shouldSuppressDetachedRevisionImmediateRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }

    static func shouldSuppressGeometryRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }
}

enum AgentTranscriptRehydrateRestoreLayoutPolicy {
    static func hasValidLayoutSample(_ metrics: AgentTranscriptScrollMetrics) -> Bool {
        metrics.viewportHeight > 0
    }

    static func canCompleteLiveBottomRestore(
        currentLayoutSampleKey: AgentTranscriptRehydrateRetryKey?,
        tabID: UUID,
        presentationRevision: Int,
        layoutPassToken: UInt64,
        isNearBottom: Bool
    ) -> Bool {
        guard isNearBottom else { return false }
        return currentLayoutSampleKey == AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: presentationRevision,
            layoutPassToken: layoutPassToken
        )
    }

    /// Largest distance from the content end still treated as the native initial bottom.
    static let nativeInitialBottomTolerance: CGFloat = 1

    /// The initial live-bottom restore scroll is redundant only when the instance still sits at
    /// its native bottom (within `nativeInitialBottomTolerance`, not the looser near-bottom
    /// threshold) in a valid layout sample recorded for the current tab, presentation revision
    /// and layout pass. Anything else — rows re-measured after the first layout, a stale or
    /// missing sample, a scroll in flight — keeps the existing restore scroll. Hosts without the
    /// native anchor never skip: their samples (the legacy bottom-sentinel path) do not prove the
    /// instance started at the bottom.
    static func canSkipLiveBottomRestoreScroll(
        hasNativeInitialBottomAnchor: Bool,
        isProgrammaticScrollInFlight: Bool,
        currentLayoutSampleKey: AgentTranscriptRehydrateRetryKey?,
        tabID: UUID,
        presentationRevision: Int,
        layoutPassToken: UInt64,
        metrics: AgentTranscriptScrollMetrics
    ) -> Bool {
        guard hasNativeInitialBottomAnchor, !isProgrammaticScrollInFlight else { return false }
        guard hasValidLayoutSample(metrics),
              metrics.viewportHeight.isFinite,
              metrics.distanceToBottom.isFinite,
              metrics.distanceToBottom >= 0,
              metrics.distanceToBottom <= nativeInitialBottomTolerance
        else {
            return false
        }
        return currentLayoutSampleKey == AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: presentationRevision,
            layoutPassToken: layoutPassToken
        )
    }
}

enum AgentTranscriptActivationRepaintRemountPolicy {
    static let maximumRemountsPerActivation = 2

    static func remountKey(
        oldSignal: AgentTranscriptRestoreSignal,
        newSignal: AgentTranscriptRestoreSignal,
        currentTabID: UUID?,
        rehydratePhase: AgentTranscriptRehydrateRestorePhase,
        lastRemountKey: AgentTranscriptRehydrateRetryKey?,
        remountCount: Int,
        layoutPassToken: UInt64
    ) -> AgentTranscriptRehydrateRetryKey? {
        guard let currentTabID,
              newSignal.tabID == currentTabID,
              newSignal.bindingsHydrated,
              rehydratePhase.tabID == currentTabID,
              rehydratePhase.isActive,
              rehydratePhase.target == .liveBottom,
              remountCount < maximumRemountsPerActivation
        else {
            return nil
        }

        let enteredTab = oldSignal.tabID != newSignal.tabID
        let becameHydrated = oldSignal.tabID == newSignal.tabID
            && !oldSignal.bindingsHydrated
            && newSignal.bindingsHydrated
        let revisionChanged = oldSignal.tabID == newSignal.tabID
            && oldSignal.presentationRevision != newSignal.presentationRevision
        let isAwaitingHydrationOrLayout = switch rehydratePhase {
        case .awaitingHydration, .awaitingLayout:
            true
        case .idle, .driving:
            false
        }

        guard enteredTab || becameHydrated || (revisionChanged && isAwaitingHydrationOrLayout) else {
            return nil
        }

        let key = AgentTranscriptRehydrateRetryKey(
            tabID: currentTabID,
            presentationRevision: newSignal.presentationRevision,
            layoutPassToken: layoutPassToken
        )
        if lastRemountKey?.tabID == currentTabID,
           lastRemountKey?.presentationRevision == newSignal.presentationRevision
        {
            return nil
        }
        return key
    }
}

enum AgentTranscriptBottomScrollOutcomeLayoutPolicy {
    static func hasMaterialLayoutMutation(
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics,
        contentHeightThreshold: CGFloat,
        viewportHeightThreshold: CGFloat
    ) -> Bool {
        let contentHeightDelta = abs(newMetrics.contentHeight - oldMetrics.contentHeight)
        let viewportHeightDelta = abs(newMetrics.viewportHeight - oldMetrics.viewportHeight)
        return contentHeightDelta >= contentHeightThreshold
            || viewportHeightDelta >= viewportHeightThreshold
    }

    static func remainingQuietDelay(
        lastLayoutMutationAt: Date?,
        now: Date,
        quietPeriod: TimeInterval
    ) -> TimeInterval? {
        guard quietPeriod > 0,
              let lastLayoutMutationAt
        else {
            return nil
        }
        let elapsed = now.timeIntervalSince(lastLayoutMutationAt)
        guard elapsed < quietPeriod else { return nil }
        return quietPeriod - max(0, elapsed)
    }
}

enum AgentTranscriptIdleBoundaryProgressResolver {
    static func resolve(
        activeSession: AgentTranscriptUserScrollSession?,
        lastCompletedSession: AgentTranscriptCompletedUserScrollSession?,
        currentMetrics: AgentTranscriptScrollMetrics,
        now: Date,
        freshnessWindow: TimeInterval
    ) -> (hasTowardHistoryManualIntent: Bool, progress: AgentTranscriptViewportProgress)? {
        if let activeSession {
            return (
                hasTowardHistoryManualIntent: activeSession.latestIntent == .towardHistory,
                progress: AgentTranscriptViewportProgress(
                    baselineDistanceToBottom: activeSession.baselineMetrics.distanceToBottom,
                    currentDistanceToBottom: max(currentMetrics.distanceToBottom, activeSession.latestMetrics.distanceToBottom),
                    baselineVisibleMinY: activeSession.baselineMetrics.visibleMinY,
                    currentVisibleMinY: min(currentMetrics.visibleMinY, activeSession.latestMetrics.visibleMinY)
                )
            )
        }
        guard let lastCompletedSession,
              freshnessWindow > 0,
              now.timeIntervalSince(lastCompletedSession.endedAt) <= freshnessWindow
        else {
            return nil
        }
        return (
            hasTowardHistoryManualIntent: lastCompletedSession.latestIntent == .towardHistory,
            progress: AgentTranscriptViewportProgress(
                baselineDistanceToBottom: lastCompletedSession.baselineMetrics.distanceToBottom,
                currentDistanceToBottom: max(currentMetrics.distanceToBottom, lastCompletedSession.finalMetrics.distanceToBottom),
                baselineVisibleMinY: lastCompletedSession.baselineMetrics.visibleMinY,
                currentVisibleMinY: min(currentMetrics.visibleMinY, lastCompletedSession.finalMetrics.visibleMinY)
            )
        )
    }
}

enum AgentTranscriptPinnedBottomProtectionPolicy {
    static func shouldArmOnBottomSettle(
        runtime: AgentTranscriptScrollRuntimeState,
        nearBottomThreshold: CGFloat
    ) -> Bool {
        runtime.isPinnedToLiveBottom
            && !runtime.isDetachedFromLiveBottom
            && !runtime.isUserInteractingWithScroll
            && !runtime.isInteractionBlocked
            && !runtime.isRehydrateRestoreActive
            && runtime.distanceToBottom <= nearBottomThreshold
    }

    static func shouldRemainActiveAfterSmoothSendCompletion(
        runtime: AgentTranscriptScrollRuntimeState
    ) -> Bool {
        runtime.isPinnedToLiveBottom
            && !runtime.isDetachedFromLiveBottom
            && !runtime.isUserInteractingWithScroll
            && !runtime.isInteractionBlocked
            && !runtime.isRehydrateRestoreActive
    }

    static func shouldPreserveLastResolvedScrollView(
        hasExistingScrollView: Bool,
        hasNewlyResolvedScrollView: Bool
    ) -> Bool {
        hasExistingScrollView && !hasNewlyResolvedScrollView
    }
}
