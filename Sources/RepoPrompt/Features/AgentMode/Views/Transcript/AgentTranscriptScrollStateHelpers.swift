import CoreGraphics
import Foundation
import RepoPromptAgentCore

struct AgentTranscriptScrollRuntimeState {
    let armingState: AgentTranscriptAutoFollowArmingState
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

/// Identity of the transcript `ScrollView` instance (`.id(_:)` on the modern and legacy paths).
///
/// The key changes in the same SwiftUI update that delivers the content it freshens: a different
/// presentation tab (tab entry) or the activation's first hydrated presentation. A stale instance
/// therefore never lays out the destination rows first and gets replaced afterwards, which used
/// to build every destination row twice per switch (see the D6 double-build experiment).
///
/// `tabID` is the presentation's tab, not the view's `currentTabID`: the rows come from the
/// presentation, which is either the current tab's snapshot or an empty/loading placeholder, and
/// `AgentTranscriptRestoreSignal` (observed by the activation repaint policy) carries the same tab.
/// Its hydration component flips only for the first hydrated presentation of an activation:
/// once `hydratedMountTabID` latches the tab, a later binding transition on the same tab
/// (unhydrated, then hydrated again) keeps the mounted instance, as it did before this key.
/// `resetRevision` remains for explicit remounts (manual reset, revision re-mount while the
/// activation still awaits layout).
///
/// The hydration flip is not gated by `AgentTranscriptActivationRepaintRemountPolicy`'s guards
/// (active phase, live-bottom target, two-remount cap): an activation whose restore is not
/// live-bottom or has already ended still gets a fresh instance at its first hydration, at most
/// once per activation because `armRehydrateRestore` resets the latch.
struct AgentTranscriptScrollMountKey: Hashable {
    let tabID: UUID?
    let isHydratedMount: Bool
    let resetRevision: Int

    init(
        restoreSignal: AgentTranscriptRestoreSignal,
        hydratedMountTabID: UUID?,
        resetRevision: Int
    ) {
        tabID = restoreSignal.tabID
        isHydratedMount = restoreSignal.bindingsHydrated
            || (restoreSignal.tabID != nil && restoreSignal.tabID == hydratedMountTabID)
        self.resetRevision = resetRevision
    }

    /// Latch value at the start of an activation (`armRehydrateRestore`): the tab when its
    /// hydrated presentation is already shown, otherwise `nil` so the first hydrated presentation
    /// changes the key.
    static func hydratedMountTabID(
        atActivationOf tabID: UUID?,
        restoreSignal: AgentTranscriptRestoreSignal
    ) -> UUID? {
        guard let tabID, restoreSignal.tabID == tabID, restoreSignal.bindingsHydrated else { return nil }
        return tabID
    }

    /// Latch value after observing `restoreSignal`: a hydrated presentation of the current tab
    /// latches that tab; anything else keeps the previous latch.
    static func hydratedMountTabID(
        afterObserving restoreSignal: AgentTranscriptRestoreSignal,
        currentTabID: UUID?,
        previous: UUID?
    ) -> UUID? {
        guard let tabID = restoreSignal.tabID,
              tabID == currentTabID,
              restoreSignal.bindingsHydrated
        else {
            return previous
        }
        return tabID
    }

    /// Whether the mount key differs between two restore signals under the same latch and reset
    /// revision, i.e. whether SwiftUI already mounts a fresh instance in the update that changed
    /// the signal.
    static func changes(
        from oldSignal: AgentTranscriptRestoreSignal,
        to newSignal: AgentTranscriptRestoreSignal,
        hydratedMountTabID: UUID?
    ) -> Bool {
        AgentTranscriptScrollMountKey(restoreSignal: oldSignal, hydratedMountTabID: hydratedMountTabID, resetRevision: 0)
            != AgentTranscriptScrollMountKey(restoreSignal: newSignal, hydratedMountTabID: hydratedMountTabID, resetRevision: 0)
    }
}

/// Latest outer-transcript scroll geometry together with the mount key of the instance that
/// reported it.
///
/// A fresh instance created by a mount-key change reports its first geometry in the update that
/// mounted it, before that update's `onChange` handlers reset scroll state and arm the restore
/// (measured in `AgentTranscriptScrollMountKeyHostingTests`); no further callback follows while
/// the value is unchanged. The handlers replay that sample into the restore so it sees the same
/// first layout the former post-handler remount delivered.
struct AgentTranscriptMountedScrollGeometry: Equatable {
    let mountKey: AgentTranscriptScrollMountKey
    let metrics: AgentTranscriptScrollMetrics

    /// Metrics to replay, only when they were reported by the currently keyed instance.
    static func replayableMetrics(
        _ sample: AgentTranscriptMountedScrollGeometry?,
        currentMountKey: AgentTranscriptScrollMountKey
    ) -> AgentTranscriptScrollMetrics? {
        guard let sample, sample.mountKey == currentMountKey else { return nil }
        return sample.metrics
    }
}

/// Decides when an activation's live-bottom restore needs a fresh transcript `ScrollView`
/// instance and the restore bookkeeping that goes with it (new layout pass token, cleared layout
/// sample, `awaitingHydration` demotion, cleared viewport capture). A fresh instance gets the
/// native initial bottom (`AgentTranscriptInitialBottomAnchor`) for the content it shows.
///
/// For tab entry and the first hydration the fresh instance already comes from
/// `AgentTranscriptScrollMountKey` in the same update, so `requiresIdentityBump` is false and
/// only the bookkeeping runs. A presentation revision change while the activation still awaits
/// hydration or layout does not change the mount key; it still bumps the reset revision.
enum AgentTranscriptActivationRepaintRemountPolicy {
    static let maximumRemountsPerActivation = 2

    enum Trigger: Equatable {
        case enteredTab
        case becameHydrated
        case revisionChangedWhileAwaitingLayout
    }

    struct Decision: Equatable {
        let key: AgentTranscriptRehydrateRetryKey
        let trigger: Trigger
        /// True only when the mount key did not already change with `newSignal`.
        let requiresIdentityBump: Bool
    }

    /// Activation start (`armRehydrateRestore`) for an already hydrated presentation. Never bumps:
    /// its only callers already show a fresh instance — `onAppear` (inserted subtree),
    /// `onChange(currentTabID)` (the presentation tab in the mount key changed with the tab), and
    /// the manual reset (bumps before arming).
    static func activationStartDecision(
        signal: AgentTranscriptRestoreSignal,
        currentTabID: UUID?,
        rehydratePhase: AgentTranscriptRehydrateRestorePhase,
        lastRemountKey: AgentTranscriptRehydrateRetryKey?,
        remountCount: Int,
        layoutPassToken: UInt64
    ) -> Decision? {
        let entry = AgentTranscriptRestoreSignal(tabID: nil, bindingsHydrated: false, presentationRevision: signal.presentationRevision)
        return decision(
            oldSignal: entry, newSignal: signal, currentTabID: currentTabID, rehydratePhase: rehydratePhase,
            lastRemountKey: lastRemountKey, remountCount: remountCount, layoutPassToken: layoutPassToken, hydratedMountTabID: nil
        ).map { Decision(key: $0.key, trigger: .enteredTab, requiresIdentityBump: false) }
    }

    static func decision(
        oldSignal: AgentTranscriptRestoreSignal,
        newSignal: AgentTranscriptRestoreSignal,
        currentTabID: UUID?,
        rehydratePhase: AgentTranscriptRehydrateRestorePhase,
        lastRemountKey: AgentTranscriptRehydrateRetryKey?,
        remountCount: Int,
        layoutPassToken: UInt64,
        hydratedMountTabID: UUID?
    ) -> Decision? {
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

        let trigger: Trigger
        if enteredTab {
            trigger = .enteredTab
        } else if becameHydrated {
            trigger = .becameHydrated
        } else if revisionChanged, isAwaitingHydrationOrLayout {
            trigger = .revisionChangedWhileAwaitingLayout
        } else {
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
        let mountKeyChanged = AgentTranscriptScrollMountKey.changes(
            from: oldSignal,
            to: newSignal,
            hydratedMountTabID: hydratedMountTabID
        )
        return Decision(key: key, trigger: trigger, requiresIdentityBump: !mountKeyChanged)
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
