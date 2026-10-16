@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentTranscriptActivationRepaintRemountPolicyTests: XCTestCase {
    private typealias Policy = AgentTranscriptActivationRepaintRemountPolicy

    func testEnteredHydratedLiveBottomActivationProducesRemountKey() {
        let tabID = UUID()
        let decision = Policy.decision(
            oldSignal: AgentTranscriptRestoreSignal(tabID: UUID(), bindingsHydrated: true, presentationRevision: 1),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 7),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 42,
            hydratedMountTabID: tabID
        )

        XCTAssertEqual(decision, Policy.Decision(
            key: AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 42),
            trigger: .enteredTab,
            requiresIdentityBump: false
        ), "tab entry keeps its restore bookkeeping but the mount key already mounted a fresh instance")
    }

    func testActivationStartDecisionKeepsGuardsAndNeverBumps() {
        let tabID = UUID()
        let hydrated = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 7)
        let liveBottom = AgentTranscriptRehydrateRestorePhase.awaitingHydration(tabID: tabID, target: .liveBottom)
        func start(
            _ signal: AgentTranscriptRestoreSignal = hydrated,
            currentTabID: UUID? = tabID,
            phase: AgentTranscriptRehydrateRestorePhase = liveBottom,
            lastRemountKey: AgentTranscriptRehydrateRetryKey? = nil,
            remountCount: Int = 0
        ) -> Policy.Decision? {
            Policy.activationStartDecision(
                signal: signal,
                currentTabID: currentTabID,
                rehydratePhase: phase,
                lastRemountKey: lastRemountKey,
                remountCount: remountCount,
                layoutPassToken: 43
            )
        }

        XCTAssertEqual(start(), Policy.Decision(
            key: AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 43),
            trigger: .enteredTab,
            requiresIdentityBump: false
        ), "activation start records its bookkeeping key without bumping the reset revision")

        // The same same-tab transition through the general decision does bump once the tab's
        // hydrated instance is latched; activation start is caller knowledge, not latch-derived.
        let sameTabReHydration = Policy.decision(
            oldSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: false, presentationRevision: 7),
            newSignal: hydrated,
            currentTabID: tabID,
            rehydratePhase: liveBottom,
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 43,
            hydratedMountTabID: tabID
        )
        XCTAssertEqual(sameTabReHydration?.requiresIdentityBump, true)

        // The policy guards still apply.
        XCTAssertNil(start(AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: false, presentationRevision: 7)))
        XCTAssertNil(start(currentTabID: UUID()), "a signal for another tab is not this activation")
        XCTAssertNil(start(phase: .awaitingHydration(tabID: tabID, target: .detached(nil))))
        XCTAssertNil(start(phase: .idle))
        XCTAssertNil(start(remountCount: Policy.maximumRemountsPerActivation))
        XCTAssertNil(start(lastRemountKey: AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 1)))
    }

    func testDuplicateRevisionExceededLimitDetachedOrIdleActivationSuppressesRemount() {
        let tabID = UUID()
        let oldSignal = AgentTranscriptRestoreSignal(tabID: nil, bindingsHydrated: false, presentationRevision: 0)
        let newSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 3)
        let previousKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 3, layoutPassToken: 1)

        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: previousKey,
            remountCount: 0,
            layoutPassToken: 2,
            hydratedMountTabID: nil
        ))
        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: Policy.maximumRemountsPerActivation,
            layoutPassToken: 2,
            hydratedMountTabID: nil
        ))
        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .detached(nil)),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0,
            hydratedMountTabID: nil
        ))
        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .idle,
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0,
            hydratedMountTabID: nil
        ))
        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: false, presentationRevision: 3),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0,
            hydratedMountTabID: nil
        ), "an unhydrated presentation never remounts")
    }

    func testFirstHydrationOfActivationKeepsBookkeepingWithoutIdentityBump() {
        let tabID = UUID()
        let decision = Policy.decision(
            oldSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: false, presentationRevision: 4),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 5),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 9,
            hydratedMountTabID: nil
        )

        XCTAssertEqual(decision, Policy.Decision(
            key: AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 5, layoutPassToken: 9),
            trigger: .becameHydrated,
            requiresIdentityBump: false
        ), "hydration that also changes the revision is the hydration trigger, freshened by the mount key")
    }

    func testRehydrationOfAlreadyMountedTabStillBumpsIdentity() {
        let tabID = UUID()
        let decision = Policy.decision(
            oldSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: false, presentationRevision: 4),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 4),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 1,
            layoutPassToken: 3,
            hydratedMountTabID: tabID
        )

        XCTAssertEqual(decision?.trigger, .becameHydrated)
        XCTAssertEqual(decision?.requiresIdentityBump, true, "the latched mount key does not change, so the remount must bump")
    }

    func testRevisionChangeWhileAwaitingLayoutStillBumpsIdentity() {
        let tabID = UUID()
        let oldSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 5)
        let newSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 6)
        let firstKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 5, layoutPassToken: 2)

        for phase: AgentTranscriptRehydrateRestorePhase in [
            .awaitingHydration(tabID: tabID, target: .liveBottom),
            .awaitingLayout(tabID: tabID, presentationRevision: 5, target: .liveBottom)
        ] {
            let decision = Policy.decision(
                oldSignal: oldSignal,
                newSignal: newSignal,
                currentTabID: tabID,
                rehydratePhase: phase,
                lastRemountKey: firstKey,
                remountCount: 1,
                layoutPassToken: 7,
                hydratedMountTabID: tabID
            )
            XCTAssertEqual(decision, Policy.Decision(
                key: AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 6, layoutPassToken: 7),
                trigger: .revisionChangedWhileAwaitingLayout,
                requiresIdentityBump: true
            ))
        }

        XCTAssertNil(Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .driving(tabID: tabID, presentationRevision: 5, target: .liveBottom),
            lastRemountKey: firstKey,
            remountCount: 1,
            layoutPassToken: 7,
            hydratedMountTabID: tabID
        ), "a revision change while driving re-asserts the restore without a remount")
    }

    func testMountKeyChangesOnTabEntryAndFirstHydrationOnly() {
        let tabA = UUID()
        let tabB = UUID()
        func key(_ tabID: UUID?, hydrated: Bool, revision: Int = 0, latch: UUID?, reset: Int = 0) -> AgentTranscriptScrollMountKey {
            AgentTranscriptScrollMountKey(
                restoreSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: hydrated, presentationRevision: revision),
                hydratedMountTabID: latch,
                resetRevision: reset
            )
        }

        // Warm switch A -> B: the presentation tab changes in the publishing update.
        XCTAssertNotEqual(key(tabA, hydrated: true, revision: 3, latch: tabA), key(tabB, hydrated: true, revision: 9, latch: tabA))
        // Switch to a lagging snapshot (`.empty` has no tab): fresh empty instance.
        XCTAssertNotEqual(key(tabA, hydrated: true, latch: tabA), key(nil, hydrated: true, latch: tabA))
        // Cold activation: loading -> first hydrated presentation, latch cleared at activation.
        XCTAssertNotEqual(key(tabB, hydrated: false, revision: 1, latch: nil), key(tabB, hydrated: true, revision: 2, latch: nil))
        // Same tab after the latch: a binding transition (unhydrated, then hydrated) keeps the instance.
        XCTAssertEqual(key(tabB, hydrated: true, revision: 2, latch: tabB), key(tabB, hydrated: false, revision: 3, latch: tabB))
        XCTAssertEqual(key(tabB, hydrated: false, revision: 3, latch: tabB), key(tabB, hydrated: true, revision: 4, latch: tabB))
        // Presentation revisions alone never remount; reset revision bumps always do.
        XCTAssertEqual(key(tabB, hydrated: true, revision: 4, latch: tabB), key(tabB, hydrated: true, revision: 5, latch: tabB))
        XCTAssertNotEqual(key(tabB, hydrated: true, latch: tabB, reset: 1), key(tabB, hydrated: true, latch: tabB, reset: 2))

        let hydratedB = AgentTranscriptRestoreSignal(tabID: tabB, bindingsHydrated: true, presentationRevision: 2)
        let loadingB = AgentTranscriptRestoreSignal(tabID: tabB, bindingsHydrated: false, presentationRevision: 1)
        XCTAssertEqual(AgentTranscriptScrollMountKey.hydratedMountTabID(atActivationOf: tabB, restoreSignal: hydratedB), tabB)
        XCTAssertNil(AgentTranscriptScrollMountKey.hydratedMountTabID(atActivationOf: tabB, restoreSignal: loadingB))
        XCTAssertNil(AgentTranscriptScrollMountKey.hydratedMountTabID(atActivationOf: tabA, restoreSignal: hydratedB))
        XCTAssertNil(AgentTranscriptScrollMountKey.hydratedMountTabID(atActivationOf: nil, restoreSignal: hydratedB))
        XCTAssertEqual(AgentTranscriptScrollMountKey.hydratedMountTabID(afterObserving: hydratedB, currentTabID: tabB, previous: nil), tabB)
        XCTAssertEqual(AgentTranscriptScrollMountKey.hydratedMountTabID(afterObserving: loadingB, currentTabID: tabB, previous: tabB), tabB)
        XCTAssertNil(AgentTranscriptScrollMountKey.hydratedMountTabID(afterObserving: loadingB, currentTabID: tabB, previous: nil))
        XCTAssertEqual(AgentTranscriptScrollMountKey.hydratedMountTabID(afterObserving: hydratedB, currentTabID: tabA, previous: tabA), tabA)
    }
}
