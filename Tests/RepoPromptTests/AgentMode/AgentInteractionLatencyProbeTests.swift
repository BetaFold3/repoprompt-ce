import AppKit
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentInteractionLatencyProbeTests: XCTestCase {
    private typealias Ledger = AgentInteractionLatencyLedger
    private typealias Action = AgentInteractionLatencyAction
    private static let windowID = 1
    private static let otherWindowID = 2

    private static func ms(_ value: UInt64) -> UInt64 {
        value * 1_000_000
    }

    override func tearDown() {
        AgentInteractionLatencyProbe.resetForTesting()
        super.tearDown()
    }

    // MARK: Tab activation

    func testTabActivationEmitsOrderedMarkersWithStageSplits() {
        var ledger = Ledger()
        let tabID = UUID()
        let interactionID = UUID()
        let action = Action(id: interactionID, kind: .tabActivation, windowID: Self.windowID)
        var events: [Ledger.Event] = []

        events += ledger.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow", interactionID: interactionID, now: Self.ms(1000))
        events += ledger.tabActivationTaskEntered(actionID: interactionID, now: Self.ms(1003))
        events += ledger.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID, action: action, now: Self.ms(1010))
        events += ledger.transcriptRefreshBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(1020))
        events += ledger.transcriptRefreshEnded(tabID: tabID, windowID: Self.windowID, didRefresh: true, now: Self.ms(1120))
        events += ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(1125))
        events += ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 7, contentChanged: true, now: Self.ms(1130))
        events += ledger.transcriptPresentationObservedBySwiftUI(tabID: tabID, windowID: Self.windowID, revision: 7, now: Self.ms(1150))

        XCTAssertEqual(events.map(\.name), [
            "tabActivation.begin",
            "tabActivation.handlerEntered",
            "tabActivation.firstPublish",
            "tabActivation.presentationObservedBySwiftUI"
        ])
        XCTAssertEqual(events.map(\.phase), [.begin, .milestone, .milestone, .terminal])
        XCTAssertTrue(events.allSatisfy { $0.interactionID == interactionID && $0.tabID == tabID })

        let firstPublish = events[2]
        XCTAssertEqual(firstPublish.elapsedMS, 130, accuracy: 0.001)
        XCTAssertEqual(firstPublish.fields["clickToHandlerMS"], "10.0")
        XCTAssertEqual(firstPublish.fields["queueWaitMS"], "3.0")
        XCTAssertEqual(firstPublish.fields["clickToWorkStartMS"], "20.0")
        XCTAssertEqual(firstPublish.fields["handlerToWorkStartMS"], "10.0")
        XCTAssertEqual(firstPublish.fields["refreshPath"], "applyBindings")
        XCTAssertEqual(firstPublish.fields["refreshMS"], "100.0")
        XCTAssertEqual(firstPublish.fields["didRefresh"], "true")
        XCTAssertEqual(firstPublish.fields["publishMS"], "5.0")
        XCTAssertEqual(firstPublish.fields["revision"], "7")

        let observed = events[3]
        XCTAssertEqual(observed.elapsedMS, 150, accuracy: 0.001)
        XCTAssertEqual(observed.fields["firstPublishMS"], "130.0")
        XCTAssertEqual(observed.fields["publishToObservedMS"], "20.0")
        XCTAssertEqual(ledger.pendingInteractionCount, 0)
    }

    func testObservationBeforeFirstPublishOrForOlderRevisionDoesNotComplete() {
        var ledger = Ledger()
        let tabID = UUID()
        _ = ledger.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))

        // A loading presentation observed before the real publish is not completion.
        XCTAssertTrue(ledger.transcriptPresentationObservedBySwiftUI(tabID: tabID, windowID: Self.windowID, revision: 3, now: Self.ms(6)).isEmpty)

        _ = ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 4, contentChanged: true, now: Self.ms(10))
        XCTAssertTrue(ledger.transcriptPresentationObservedBySwiftUI(tabID: tabID, windowID: Self.windowID, revision: 3, now: Self.ms(11)).isEmpty)
        XCTAssertTrue(ledger.transcriptPresentationObservedBySwiftUI(tabID: UUID(), windowID: Self.windowID, revision: 9, now: Self.ms(12)).isEmpty)
        XCTAssertTrue(ledger.transcriptPresentationObservedBySwiftUI(tabID: nil, windowID: Self.windowID, revision: 9, now: Self.ms(12)).isEmpty)

        // Only the first publish is reported.
        XCTAssertTrue(ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 5, contentChanged: true, now: Self.ms(13)).isEmpty)

        let terminal = ledger.transcriptPresentationObservedBySwiftUI(tabID: tabID, windowID: Self.windowID, revision: 5, now: Self.ms(14))
        XCTAssertEqual(terminal.map(\.name), ["tabActivation.presentationObservedBySwiftUI"])
        XCTAssertEqual(terminal.first?.fields["firstPublishMS"], "10.0")
    }

    func testPublishForOtherTabIsIgnoredAndLatestPublishAttemptTimesThePublish() {
        var ledger = Ledger()
        let tabID = UUID()
        _ = ledger.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))

        XCTAssertTrue(ledger.transcriptPublished(tabID: UUID(), windowID: Self.windowID, revision: 1, contentChanged: true, now: Self.ms(5)).isEmpty)
        _ = ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(10))
        XCTAssertTrue(ledger.transcriptPublishSkipped(tabID: tabID, windowID: Self.windowID, now: Self.ms(11)).isEmpty)
        _ = ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(40))
        let events = ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 2, contentChanged: true, now: Self.ms(42))

        XCTAssertEqual(events.map(\.name), ["tabActivation.firstPublish"])
        XCTAssertEqual(events.first?.fields["publishMS"], "2.0")
        XCTAssertEqual(events.first?.fields["clickToWorkStartMS"], "10.0")
        XCTAssertEqual(events.first?.fields["refreshPath"], "none")
        XCTAssertEqual(events.first?.fields["publishSkipCount"], "1")
        // Unmeasured stages stay absent rather than zero-filled.
        XCTAssertNil(events.first?.fields["queueWaitMS"])
        XCTAssertNil(events.first?.fields["clickToHandlerMS"])
        XCTAssertNil(events.first?.fields["handlerToWorkStartMS"])
    }

    func testPublishInsideRefreshReportsRefreshUntilPublish() {
        var ledger = Ledger()
        let tabID = UUID()
        _ = ledger.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))
        _ = ledger.transcriptRefreshBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(10))
        _ = ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(50))
        let publish = ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 1, contentChanged: true, now: Self.ms(55))

        XCTAssertEqual(publish.first?.fields["refreshUntilPublishMS"], "45.0")
        XCTAssertNil(publish.first?.fields["refreshMS"])
        XCTAssertTrue(ledger.transcriptRefreshEnded(tabID: tabID, windowID: Self.windowID, didRefresh: true, now: Self.ms(60)).isEmpty)
    }

    func testNewActivationSupersedesPendingActivation() {
        var ledger = Ledger()
        let firstID = UUID()
        let secondID = UUID()
        let firstTab = UUID()
        _ = ledger.beginTabActivation(tabID: firstTab, windowID: Self.windowID, source: "sidebarRow", interactionID: firstID, now: Self.ms(0))
        _ = ledger.tabActivationHandlerEntered(
            tabID: firstTab,
            windowID: Self.windowID,
            action: Action(id: firstID, kind: .tabActivation, windowID: Self.windowID),
            now: Self.ms(5)
        )

        let events = ledger.beginTabActivation(tabID: UUID(), windowID: Self.windowID, source: "sidebarRow", interactionID: secondID, now: Self.ms(20))

        XCTAssertEqual(events.map(\.name), ["tabActivation.superseded", "tabActivation.begin"])
        XCTAssertEqual(events[0].interactionID, firstID)
        XCTAssertEqual(events[0].phase, .terminal)
        XCTAssertEqual(events[0].fields["lastMilestone"], "handlerEntered")
        XCTAssertEqual(events[1].interactionID, secondID)
        XCTAssertEqual(ledger.pendingInteractionCount, 1)
        // The superseded tab's publish no longer reports.
        XCTAssertTrue(ledger.transcriptPublished(tabID: firstTab, windowID: Self.windowID, revision: 1, contentChanged: true, now: Self.ms(30)).isEmpty)
    }

    func testHandlerForDifferentTabCancelsActivationAsRetargeted() {
        var ledger = Ledger()
        let otherTab = UUID()
        _ = ledger.beginTabActivation(tabID: UUID(), windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))

        let events = ledger.tabActivationHandlerEntered(tabID: otherTab, windowID: Self.windowID, action: nil, now: Self.ms(8))

        XCTAssertEqual(events.map(\.name), ["tabActivation.retargeted"])
        XCTAssertEqual(events.first?.phase, .terminal)
        XCTAssertEqual(events.first?.fields["retargetTabID"], Ledger.shortID(otherTab))
        XCTAssertFalse(ledger.hasPendingInteraction)
    }

    func testSupersededClickHandlerNeitherAdvancesNorCancelsNewerClick() {
        var ledger = Ledger()
        let olderTab = UUID()
        let newerTab = UUID()
        let older = Action(id: UUID(), kind: .tabActivation, windowID: Self.windowID)
        let newer = Action(id: UUID(), kind: .tabActivation, windowID: Self.windowID)
        _ = ledger.beginTabActivation(
            tabID: olderTab,
            windowID: Self.windowID,
            source: "sidebarRow",
            interactionID: older.id,
            now: Self.ms(0)
        )
        _ = ledger.beginTabActivation(
            tabID: newerTab,
            windowID: Self.windowID,
            source: "sidebarRow",
            interactionID: newer.id,
            now: Self.ms(5)
        )

        // The older click's switch runs late, carrying its own action.
        XCTAssertTrue(ledger.tabActivationHandlerEntered(
            tabID: olderTab,
            windowID: Self.windowID,
            action: older,
            now: Self.ms(10)
        ).isEmpty)
        XCTAssertEqual(ledger.pendingInteractionCount, 1)
        XCTAssertFalse(ledger.acceptsTabActivationWork(from: older))
        XCTAssertTrue(ledger.acceptsTabActivationWork(from: newer))
        // Actionless work is not owned until the newer click's own handler runs.
        XCTAssertFalse(ledger.acceptsTabActivationWork(from: nil))
        XCTAssertFalse(ledger.acceptsTabActivationObservation(from: older))
        XCTAssertTrue(ledger.acceptsTabActivationObservation(from: nil))

        let events = ledger.tabActivationHandlerEntered(
            tabID: newerTab,
            windowID: Self.windowID,
            action: newer,
            now: Self.ms(20)
        )
        XCTAssertEqual(events.map(\.name), ["tabActivation.handlerEntered"])
        XCTAssertEqual(events.first?.interactionID, newer.id)
        XCTAssertTrue(ledger.acceptsTabActivationWork(from: nil))
        XCTAssertFalse(ledger.acceptsTabActivationWork(from: older))
    }

    func testActionlessSameTabHandlerDoesNotEstablishOwnership() {
        var ledger = Ledger()
        let tabID = UUID()
        let action = Action(id: UUID(), kind: .tabActivation, windowID: Self.windowID)
        _ = ledger.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow",
            interactionID: action.id,
            now: Self.ms(0)
        )

        // E.g. an activation bootstrap re-entering the handler for the already-targeted tab.
        XCTAssertTrue(ledger.tabActivationHandlerEntered(
            tabID: tabID,
            windowID: Self.windowID,
            action: nil,
            now: Self.ms(3)
        ).isEmpty)
        XCTAssertFalse(ledger.acceptsTabActivationWork(from: nil))
        XCTAssertEqual(ledger.pendingInteractionCount, 1)

        let owned = ledger.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID, action: action, now: Self.ms(7))
        XCTAssertEqual(owned.map(\.name), ["tabActivation.handlerEntered"])
        XCTAssertTrue(ledger.acceptsTabActivationWork(from: nil))
    }

    func testQueueWaitEndsAtOwnTaskEntryNotAtSynchronousPreWork() {
        var ledger = Ledger()
        let tabID = UUID()
        let action = Action(id: UUID(), kind: .tabActivation, windowID: Self.windowID)
        _ = ledger.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow",
            interactionID: action.id,
            now: Self.ms(0)
        )

        // Scheduling wait: 2ms until the click's Task runs. Another action's entry is ignored.
        XCTAssertTrue(ledger.tabActivationTaskEntered(actionID: UUID(), now: Self.ms(1)).isEmpty)
        XCTAssertTrue(ledger.tabActivationTaskEntered(actionID: action.id, now: Self.ms(2)).isEmpty)
        XCTAssertTrue(ledger.tabActivationTaskEntered(actionID: action.id, now: Self.ms(9)).isEmpty)
        // Synchronous pre-work (old-tab flush) delays the handler to 30ms; work starts at 31ms.
        _ = ledger.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID, action: action, now: Self.ms(30))
        _ = ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID, now: Self.ms(31))
        let publish = ledger.transcriptPublished(
            tabID: tabID,
            windowID: Self.windowID,
            revision: 1,
            contentChanged: true,
            now: Self.ms(33)
        )

        let fields = publish.first?.fields ?? [:]
        XCTAssertEqual(fields["queueWaitMS"], "2.0")
        XCTAssertEqual(fields["clickToHandlerMS"], "30.0")
        XCTAssertEqual(fields["clickToWorkStartMS"], "31.0")
        XCTAssertEqual(fields["handlerToWorkStartMS"], "1.0")
        XCTAssertEqual(fields["refreshPath"], "none")
        XCTAssertNil(fields["refreshMS"])
    }

    func testOtherWindowHandlerAndMilestonesNeverTouchActivation() {
        var ledger = Ledger()
        let tabID = UUID()
        let interactionID = UUID()
        _ = ledger.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow",
            interactionID: interactionID,
            now: Self.ms(0)
        )

        // Another window's tab change (no action) is not a retarget of this window's click.
        XCTAssertTrue(ledger.tabActivationHandlerEntered(
            tabID: UUID(),
            windowID: Self.otherWindowID,
            action: nil,
            now: Self.ms(1)
        ).isEmpty)
        XCTAssertTrue(ledger.tabActivationHandlerEntered(
            tabID: tabID,
            windowID: Self.otherWindowID,
            action: nil,
            now: Self.ms(2)
        ).isEmpty)
        _ = ledger.transcriptRefreshBegan(tabID: tabID, windowID: Self.otherWindowID, now: Self.ms(3))
        _ = ledger.transcriptPublishBegan(tabID: tabID, windowID: Self.otherWindowID, now: Self.ms(4))
        XCTAssertTrue(ledger.transcriptPublished(
            tabID: tabID,
            windowID: Self.otherWindowID,
            revision: 1,
            contentChanged: true,
            now: Self.ms(5)
        ).isEmpty)
        XCTAssertEqual(ledger.pendingInteractionCount, 1)

        _ = ledger.tabActivationHandlerEntered(
            tabID: tabID,
            windowID: Self.windowID,
            action: Action(id: interactionID, kind: .tabActivation, windowID: Self.windowID),
            now: Self.ms(10)
        )
        let publish = ledger.transcriptPublished(
            tabID: tabID,
            windowID: Self.windowID,
            revision: 2,
            contentChanged: true,
            now: Self.ms(12)
        )
        XCTAssertEqual(publish.map(\.name), ["tabActivation.firstPublish"])
        XCTAssertEqual(publish.first?.interactionID, interactionID)
        // Only this window's handler stamped the stages.
        XCTAssertEqual(publish.first?.fields["clickToHandlerMS"], "10.0")
        XCTAssertNil(publish.first?.fields["refreshMS"])
        XCTAssertNil(publish.first?.fields["refreshUntilPublishMS"])
        XCTAssertNil(publish.first?.fields["publishMS"])
    }

    func testNewSessionActionHandlerForOtherTabStillRetargetsActivation() {
        var ledger = Ledger()
        _ = ledger.beginTabActivation(tabID: UUID(), windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))
        let newSession = Action(id: UUID(), kind: .newSession, windowID: Self.windowID)

        let events = ledger.tabActivationHandlerEntered(
            tabID: UUID(),
            windowID: Self.windowID,
            action: newSession,
            now: Self.ms(4)
        )

        XCTAssertEqual(events.map(\.name), ["tabActivation.retargeted"])
        XCTAssertFalse(ledger.hasPendingInteraction)
    }

    func testStalePendingInteractionsExpireLazilyOnNextCall() {
        var ledger = Ledger()
        let tabID = UUID()
        _ = ledger.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow", now: Self.ms(0))
        XCTAssertTrue(ledger.loadingPresentationPublished(tabID: tabID, windowID: Self.windowID, now: Self.ms(1)).isEmpty)
        _ = ledger.beginNewSession(source: "globalShortcut", now: Self.ms(0))

        let late = Self.ms(1) + Ledger.maxPendingAgeNanoseconds
        let events = ledger.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 1, contentChanged: true, now: late)

        XCTAssertEqual(events.map(\.name), ["tabActivation.expired", "newSession.expired"])
        XCTAssertEqual(events.first?.fields["lastMilestone"], "loadingPublished")
        XCTAssertTrue(events.allSatisfy { $0.phase == .terminal })
        XCTAssertFalse(ledger.hasPendingInteraction)
    }

    // MARK: New session

    func testNewSessionCompletesOnlyForCurrentRequestToken() {
        var ledger = Ledger()
        let interactionID = UUID()
        let tabID = UUID()
        let staleRequest = UUID()
        let request = UUID()
        var events: [Ledger.Event] = []

        let action = Action(id: interactionID, kind: .newSession, windowID: Self.windowID)

        events += ledger.beginNewSession(source: "titlebarNewSession", interactionID: interactionID, now: Self.ms(0))
        XCTAssertFalse(ledger.isAwaitingComposerFocus)
        events += ledger.composerFocusRequested(requestID: staleRequest, tabID: tabID, action: action, now: Self.ms(100))
        events += ledger.composerFocusRequested(requestID: request, tabID: tabID, action: action, now: Self.ms(200))
        XCTAssertTrue(ledger.isAwaitingComposerFocus)
        // An older request's token is no longer the interaction's token.
        XCTAssertTrue(ledger.composerFocusAcknowledged(token: staleRequest, via: "tokenAttempt", now: Self.ms(205)).isEmpty)
        events += ledger.composerFocusTokenApplied(requestID: request, now: Self.ms(210))
        events += ledger.composerFocusAcknowledged(token: request, via: "responderBecame", now: Self.ms(260))

        XCTAssertEqual(events.map(\.name), [
            "newSession.begin",
            "newSession.focusRequested",
            "newSession.focusRequested",
            "newSession.composerReady"
        ])
        XCTAssertTrue(events.allSatisfy { $0.interactionID == interactionID })
        let ready = events[3]
        XCTAssertEqual(ready.phase, .terminal)
        XCTAssertEqual(ready.elapsedMS, 260, accuracy: 0.001)
        XCTAssertEqual(ready.tabID, tabID)
        XCTAssertEqual(ready.fields["via"], "responderBecame")
        XCTAssertEqual(ready.fields["actionToRequestMS"], "200.0")
        XCTAssertEqual(ready.fields["requestToReadyMS"], "60.0")
        XCTAssertEqual(ready.fields["tokenAppliedToReadyMS"], "50.0")
        XCTAssertEqual(ready.fields["lastMilestone"], "focusTokenApplied")
        XCTAssertFalse(ledger.hasPendingInteraction)
    }

    func testNewSessionSupersessionCarriesLastMilestoneAndUnboundRequestsAreIgnored() {
        var ledger = Ledger()
        let firstID = UUID()
        let firstAction = Action(id: firstID, kind: .newSession, windowID: Self.windowID)
        XCTAssertTrue(ledger.composerFocusRequested(
            requestID: UUID(),
            tabID: UUID(),
            action: firstAction,
            now: Self.ms(0)
        ).isEmpty)
        XCTAssertFalse(ledger.hasPendingInteraction)

        _ = ledger.beginNewSession(source: "globalShortcut", interactionID: firstID, now: Self.ms(0))
        _ = ledger.composerFocusRequested(requestID: UUID(), tabID: UUID(), action: firstAction, now: Self.ms(10))

        let events = ledger.beginNewSession(source: "globalShortcut", now: Self.ms(40))
        XCTAssertEqual(events.map(\.name), ["newSession.superseded", "newSession.begin"])
        XCTAssertEqual(events[0].interactionID, firstID)
        XCTAssertEqual(events[0].fields["lastMilestone"], "focusRequested")
        XCTAssertFalse(ledger.isAwaitingComposerFocus)
    }

    func testOlderActionFocusRequestAfterNewerBeginNeitherRebindsNorCompletesNewer() {
        var ledger = Ledger()
        let older = Action(id: UUID(), kind: .newSession, windowID: Self.windowID)
        let newer = Action(id: UUID(), kind: .newSession, windowID: Self.windowID)
        let olderRequest = UUID()
        let newerRequest = UUID()
        _ = ledger.beginNewSession(source: "globalShortcut", interactionID: older.id, now: Self.ms(0))
        _ = ledger.beginNewSession(source: "globalShortcut", interactionID: newer.id, now: Self.ms(5))

        // The older action's creation finishes late and requests focus under its own action.
        XCTAssertTrue(ledger.composerFocusRequested(
            requestID: olderRequest,
            tabID: UUID(),
            action: older,
            now: Self.ms(10)
        ).isEmpty)
        XCTAssertFalse(ledger.isAwaitingComposerFocus)
        XCTAssertTrue(ledger.composerFocusTokenApplied(requestID: olderRequest, now: Self.ms(11)).isEmpty)
        XCTAssertTrue(ledger.composerFocusAcknowledged(token: olderRequest, via: "tokenAttempt", now: Self.ms(12)).isEmpty)
        // A request outside any action (another caller) never binds either.
        XCTAssertTrue(ledger.composerFocusRequested(
            requestID: UUID(),
            tabID: UUID(),
            action: nil,
            now: Self.ms(13)
        ).isEmpty)
        XCTAssertEqual(ledger.pendingInteractionCount, 1)

        var events = ledger.composerFocusRequested(requestID: newerRequest, tabID: UUID(), action: newer, now: Self.ms(20))
        events += ledger.composerFocusAcknowledged(token: newerRequest, via: "responderBecame", now: Self.ms(30))
        XCTAssertEqual(events.map(\.name), ["newSession.focusRequested", "newSession.composerReady"])
        XCTAssertTrue(events.allSatisfy { $0.interactionID == newer.id })
        XCTAssertEqual(events.last?.fields["actionToRequestMS"], "15.0")
    }

    // MARK: Façade

    func testRapidSameTargetClicksDropSupersededActionsHandlerAndStages() {
        var received: [Ledger.Event] = []
        var clock: UInt64 = Self.ms(1000)
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        AgentInteractionLatencyProbe.eventSinkForTesting = { received.append($0) }
        AgentInteractionLatencyProbe.nowOverrideForTesting = { clock }
        let tabID = UUID()

        let older = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )
        clock += Self.ms(5)
        let newer = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )
        let newerID = newer?.id
        XCTAssertNotNil(newerID)

        // The superseded click's switch, refresh and publish all run before the newer handler.
        Action.$current.withValue(older) {
            clock += Self.ms(10)
            AgentInteractionLatencyProbe.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID)
            AgentInteractionLatencyProbe.transcriptRefreshBegan(tabID: tabID, windowID: Self.windowID)
            AgentInteractionLatencyProbe.loadingPresentationPublished(tabID: tabID, windowID: Self.windowID)
            AgentInteractionLatencyProbe.transcriptRefreshEnded(tabID: tabID, windowID: Self.windowID, didRefresh: true)
            AgentInteractionLatencyProbe.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID)
            AgentInteractionLatencyProbe.transcriptPublishSkipped(tabID: tabID, windowID: Self.windowID)
            AgentInteractionLatencyProbe.transcriptPublished(
                tabID: tabID,
                windowID: Self.windowID,
                revision: 1,
                contentChanged: true
            )
            AgentInteractionLatencyProbe.transcriptPresentationObservedBySwiftUI(
                tabID: tabID,
                windowID: Self.windowID,
                revision: 1
            )
        }
        XCTAssertEqual(received.map(\.name), [
            "tabActivation.begin",
            "tabActivation.superseded",
            "tabActivation.begin"
        ])
        XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)

        Action.$current.withValue(newer) {
            clock += Self.ms(20)
            AgentInteractionLatencyProbe.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID)
            clock += Self.ms(5)
            AgentInteractionLatencyProbe.transcriptRefreshBegan(tabID: tabID, windowID: Self.windowID)
            clock += Self.ms(10)
            AgentInteractionLatencyProbe.transcriptRefreshEnded(tabID: tabID, windowID: Self.windowID, didRefresh: true)
            AgentInteractionLatencyProbe.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID)
            clock += Self.ms(2)
            AgentInteractionLatencyProbe.transcriptPublished(
                tabID: tabID,
                windowID: Self.windowID,
                revision: 2,
                contentChanged: true
            )
        }
        // SwiftUI observation carries no action and matches by window, tab and revision.
        clock += Self.ms(3)
        AgentInteractionLatencyProbe.transcriptPresentationObservedBySwiftUI(
            tabID: tabID,
            windowID: Self.windowID,
            revision: 2
        )

        let newerEvents = received.filter { $0.interactionID == newerID }
        XCTAssertEqual(newerEvents.map(\.name), [
            "tabActivation.begin",
            "tabActivation.handlerEntered",
            "tabActivation.firstPublish",
            "tabActivation.presentationObservedBySwiftUI"
        ])
        let firstPublish = newerEvents[2]
        XCTAssertEqual(firstPublish.fields["revision"], "2")
        XCTAssertEqual(firstPublish.fields["clickToHandlerMS"], "30.0")
        XCTAssertEqual(firstPublish.fields["clickToWorkStartMS"], "35.0")
        XCTAssertEqual(firstPublish.fields["handlerToWorkStartMS"], "5.0")
        // Bound without `run(as:)`, so no Task entry was measured.
        XCTAssertNil(firstPublish.fields["queueWaitMS"])
        XCTAssertEqual(firstPublish.fields["refreshMS"], "10.0")
        XCTAssertEqual(firstPublish.fields["publishMS"], "2.0")
        XCTAssertEqual(firstPublish.fields["publishSkipCount"], "0")
        XCTAssertEqual(newerEvents[3].fields["publishToObservedMS"], "3.0")
        XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 0)
    }

    func testActionlessWorkCannotStampOrCompleteClickWithoutItsOwnHandler() {
        var received: [Ledger.Event] = []
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        AgentInteractionLatencyProbe.eventSinkForTesting = { received.append($0) }
        let tabID = UUID()
        let older = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )
        let newer = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )
        // The older switch's handler is dropped; the newer switch is a no-op (no handler).
        Action.$current.withValue(older) {
            AgentInteractionLatencyProbe.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID)
        }

        // Unrelated streaming/derived refresh with no task-local action publishes the target.
        AgentInteractionLatencyProbe.transcriptRefreshBegan(tabID: tabID, windowID: Self.windowID)
        AgentInteractionLatencyProbe.transcriptRefreshEnded(tabID: tabID, windowID: Self.windowID, didRefresh: true)
        AgentInteractionLatencyProbe.loadingPresentationPublished(tabID: tabID, windowID: Self.windowID)
        AgentInteractionLatencyProbe.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID)
        AgentInteractionLatencyProbe.transcriptPublishSkipped(tabID: tabID, windowID: Self.windowID)
        AgentInteractionLatencyProbe.transcriptPublished(
            tabID: tabID,
            windowID: Self.windowID,
            revision: 4,
            contentChanged: true
        )
        AgentInteractionLatencyProbe.transcriptPresentationObservedBySwiftUI(
            tabID: tabID,
            windowID: Self.windowID,
            revision: 4
        )

        XCTAssertEqual(received.filter { $0.interactionID == newer?.id }.map(\.name), ["tabActivation.begin"])
        XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 1)
    }

    func testRunStampsOwnTaskEntryAsQueueWait() async {
        final class Clock {
            var now: UInt64 = 1_000_000_000
        }
        var received: [Ledger.Event] = []
        let clock = Clock()
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        AgentInteractionLatencyProbe.eventSinkForTesting = { received.append($0) }
        AgentInteractionLatencyProbe.nowOverrideForTesting = { clock.now }
        let tabID = UUID()
        let action = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )

        let task = Task {
            await AgentInteractionLatencyProbe.run(as: action) {
                // Synchronous pre-work before the handler (e.g. the old-tab flush).
                clock.now += Self.ms(12)
                AgentInteractionLatencyProbe.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID)
                clock.now += Self.ms(1)
                AgentInteractionLatencyProbe.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID)
                AgentInteractionLatencyProbe.transcriptPublished(
                    tabID: tabID,
                    windowID: Self.windowID,
                    revision: 1,
                    contentChanged: true
                )
            }
        }
        // The main-actor Task cannot start until this test suspends: 4ms of scheduling wait.
        clock.now += Self.ms(4)
        await task.value

        let firstPublish = received.first { $0.name == "tabActivation.firstPublish" }
        XCTAssertEqual(firstPublish?.interactionID, action?.id)
        XCTAssertEqual(firstPublish?.fields["queueWaitMS"], "4.0")
        XCTAssertEqual(firstPublish?.fields["clickToHandlerMS"], "16.0")
        XCTAssertEqual(firstPublish?.fields["clickToWorkStartMS"], "17.0")
        XCTAssertEqual(firstPublish?.fields["handlerToWorkStartMS"], "1.0")
        XCTAssertEqual(firstPublish?.fields["refreshPath"], "none")
    }

    func testFacadeFocusRequestReadsTaskLocalActionAcrossAwait() async {
        var received: [Ledger.Event] = []
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        AgentInteractionLatencyProbe.eventSinkForTesting = { received.append($0) }
        let older = AgentInteractionLatencyProbe.beginNewSession(windowID: Self.windowID, source: "test")
        let newer = AgentInteractionLatencyProbe.beginNewSession(windowID: Self.windowID, source: "test")
        let olderRequest = UUID()
        let newerRequest = UUID()

        // Mirrors the production entry points: the action is bound inside its own Task and the
        // request happens after a suspension.
        await Task {
            await AgentInteractionLatencyProbe.run(as: older) {
                await Task.yield()
                AgentInteractionLatencyProbe.composerFocusRequested(requestID: olderRequest, tabID: UUID())
            }
        }.value
        AgentInteractionLatencyProbe.composerFocusAcknowledged(token: olderRequest, via: "tokenAttempt")
        XCTAssertFalse(AgentInteractionLatencyProbe.isAwaitingComposerFocus)

        await Task {
            await AgentInteractionLatencyProbe.run(as: newer) {
                await Task.yield()
                AgentInteractionLatencyProbe.composerFocusRequested(requestID: newerRequest, tabID: UUID())
            }
        }.value
        AgentInteractionLatencyProbe.composerFocusAcknowledged(token: newerRequest, via: "tokenAttempt")

        XCTAssertEqual(
            received.filter { $0.name == "newSession.composerReady" }.map(\.interactionID),
            [newer?.id].compactMap(\.self)
        )
        XCTAssertNil(Action.current)
    }

    func testProbeDisabledRecordsNothingAndEnabledForwardsCorrelatedEvents() {
        var received: [Ledger.Event] = []
        var clock: UInt64 = Self.ms(1000)
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.eventSinkForTesting = { received.append($0) }
        AgentInteractionLatencyProbe.nowOverrideForTesting = { clock }
        let tabID = UUID()

        AgentInteractionLatencyProbe.enabledOverrideForTesting = false
        AgentInteractionLatencyProbe.beginTabActivation(tabID: tabID, windowID: Self.windowID, source: "sidebarRow")
        AgentInteractionLatencyProbe.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 1, contentChanged: true)
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 0)

        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        let action = AgentInteractionLatencyProbe.beginTabActivation(
            tabID: tabID,
            windowID: Self.windowID,
            source: "sidebarRow"
        )
        // The click's own handler establishes ownership; the later publish carries no action.
        Action.$current.withValue(action) {
            AgentInteractionLatencyProbe.tabActivationHandlerEntered(tabID: tabID, windowID: Self.windowID)
        }
        clock += Self.ms(15)
        AgentInteractionLatencyProbe.transcriptPublishBegan(tabID: tabID, windowID: Self.windowID)
        AgentInteractionLatencyProbe.transcriptPublished(tabID: tabID, windowID: Self.windowID, revision: 2, contentChanged: true)
        clock += Self.ms(5)
        AgentInteractionLatencyProbe.transcriptPresentationObservedBySwiftUI(tabID: tabID, windowID: Self.windowID, revision: 2)

        XCTAssertEqual(received.map(\.name), [
            "tabActivation.begin",
            "tabActivation.handlerEntered",
            "tabActivation.firstPublish",
            "tabActivation.presentationObservedBySwiftUI"
        ])
        XCTAssertEqual(Set(received.map(\.interactionID)).count, 1)
        XCTAssertEqual(received.last?.elapsedMS ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(AgentInteractionLatencyProbe.pendingInteractionCountForTesting, 0)
    }

    // MARK: Composer responder integration (real coordinator, text view, and window)

    func testSeededTokenIsAcknowledgedWhenFocusArrivesOutsideTheTokenPath() {
        let harness = ComposerResponderHarness()
        defer { harness.tearDown() }
        let token = UUID()
        let interactionID = harness.beginNewSession(requestID: token)
        harness.seedCoordinator(token: token)
        XCTAssertFalse(harness.window.firstResponder === harness.textView)

        // Seeded tokens never attempt focus; observing an unfocused view acknowledges nothing.
        harness.coordinator.observeComposerResponderForInteractionProbe(harness.textView, via: "viewUpdate")
        XCTAssertTrue(harness.readyEvents.isEmpty)

        // SwiftUI's focus binding (or a click) makes the text view first responder directly.
        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
        XCTAssertTrue(harness.window.firstResponder === harness.textView)
        // The view update that follows the focus change re-observes actual AppKit state. It is
        // a no-op when the responder callback already acknowledged.
        harness.coordinator.observeComposerResponderForInteractionProbe(harness.textView, via: "viewUpdate")

        XCTAssertEqual(harness.readyEvents.count, 1)
        XCTAssertEqual(harness.readyEvents.first?.interactionID, interactionID)
        XCTAssertTrue(["responderBecame", "viewUpdate"].contains(harness.readyEvents.first?.fields["via"] ?? ""))
        // The diagnostics never alter the seeded token policy state.
        XCTAssertEqual(harness.coordinator.lastAppliedComposerFocusToken, token)
        XCTAssertNil(harness.coordinator.pendingComposerFocusToken)
    }

    func testResponderWithoutKeyWindowOrMatchingTokenIsNotAcknowledged() {
        let harness = ComposerResponderHarness()
        defer { harness.tearDown() }
        let token = UUID()
        _ = harness.beginNewSession(requestID: token)

        // Mismatched token: focused, key, but the view carries another request's token.
        harness.seedCoordinator(token: UUID())
        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
        harness.coordinator.observeComposerResponderForInteractionProbe(harness.textView, via: "viewUpdate")
        XCTAssertTrue(harness.readyEvents.isEmpty)

        // Matching token but the window is not key.
        harness.seedCoordinator(token: token)
        harness.window.stubIsKeyWindow = false
        harness.coordinator.observeComposerResponderForInteractionProbe(harness.textView, via: "viewUpdate")
        XCTAssertTrue(harness.readyEvents.isEmpty)

        // Once actual state satisfies every condition, the next observation acknowledges.
        harness.window.stubIsKeyWindow = true
        harness.coordinator.observeComposerResponderForInteractionProbe(harness.textView, via: "viewUpdate")
        XCTAssertEqual(harness.readyEvents.map { $0.fields["via"] }, ["viewUpdate"])
    }
}

@MainActor
private final class ComposerResponderHarness {
    final class StubKeyWindow: NSWindow {
        var stubIsKeyWindow = true
        override var isKeyWindow: Bool {
            stubIsKeyWindow
        }
    }

    let window: StubKeyWindow
    let textView: ImageAwareTextView
    let coordinator: CustomTextField.Coordinator
    private(set) var events: [AgentInteractionLatencyLedger.Event] = []

    var readyEvents: [AgentInteractionLatencyLedger.Event] {
        events.filter { $0.name == "newSession.composerReady" }
    }

    init() {
        AgentInteractionLatencyProbe.resetForTesting()
        AgentInteractionLatencyProbe.enabledOverrideForTesting = true
        window = StubKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        textView = ImageAwareTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 80))
        window.contentView = textView
        coordinator = CustomTextField.Coordinator(Self.field(token: nil))
        coordinator.installInteractionProbeResponderObservation(on: textView)
        AgentInteractionLatencyProbe.eventSinkForTesting = { [weak self] event in
            self?.events.append(event)
        }
    }

    func beginNewSession(requestID: UUID) -> UUID? {
        let action = AgentInteractionLatencyProbe.beginNewSession(windowID: 1, source: "test")
        AgentInteractionLatencyAction.$current.withValue(action) {
            AgentInteractionLatencyProbe.composerFocusRequested(requestID: requestID, tabID: UUID())
        }
        return events.first { $0.name == "newSession.begin" }?.interactionID
    }

    /// Mirrors `makeNSView`: a token present at creation is seeded as already applied.
    func seedCoordinator(token: UUID) {
        coordinator.parent = Self.field(token: token)
        let seeded = ComposerFocusTokenPolicy.seededState(for: token)
        coordinator.lastAppliedComposerFocusToken = seeded.lastAppliedToken
        coordinator.pendingComposerFocusToken = seeded.pendingToken
    }

    func tearDown() {
        textView.onDidBecomeFirstResponderForInteractionProbe = nil
        window.orderOut(nil)
        AgentInteractionLatencyProbe.resetForTesting()
    }

    private static func field(token: UUID?) -> CustomTextField {
        CustomTextField(
            text: .constant(""),
            placeholder: "",
            onReturn: {},
            onImagePaste: nil,
            features: ResizableTextFieldFeatures(composerFocusToken: token),
            currentHeightPresetIndex: .constant(0)
        )
    }
}
