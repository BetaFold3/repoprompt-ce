@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class AgentModeSidebarSessionBuilderTests: XCTestCase {
    func testRestoredOnlyOrdersSiblingsByNewestActivityAndPreservesHierarchy() {
        let parentTabID = id(1)
        let olderChildTabID = id(2)
        let newerChildTabID = id(3)
        let grandchildTabID = id(4)
        let parentSessionID = id(101)
        let olderChildSessionID = id(102)
        let newerChildSessionID = id(103)
        let grandchildSessionID = id(104)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(olderChildTabID, sessionID: olderChildSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID),
            tab(grandchildTabID, sessionID: grandchildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                olderChildSessionID,
                tabID: olderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(40)
            ),
            entry(
                grandchildSessionID,
                tabID: grandchildTabID,
                parentSessionID: newerChildSessionID,
                lastUserMessageAt: date(30)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, newerChildTabID, grandchildTabID, olderChildTabID])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1])
    }

    func testSiblingOrderIsHydrationInvariant() {
        let parentTabID = id(10)
        let olderChildTabID = id(11)
        let newerChildTabID = id(12)
        let parentSessionID = id(110)
        let olderChildSessionID = id(111)
        let newerChildSessionID = id(112)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(olderChildTabID, sessionID: olderChildSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID)
        ]
        let entries = [
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                olderChildSessionID,
                tabID: olderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(30)
            )
        ]
        let index = sessionIndex(entries)
        let expectedOrder = [parentTabID, newerChildTabID, olderChildTabID]
        let restoredRows = build(tabs: tabs, sessionIndex: index)
        let partiallyHydratedRows = build(
            tabs: tabs,
            sessions: [
                newerChildTabID: liveSession(
                    tabID: newerChildTabID,
                    sessionID: newerChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(30)
                )
            ],
            sessionIndex: index
        )
        let fullyHydratedRows = build(
            tabs: tabs,
            sessions: [
                parentTabID: liveSession(
                    tabID: parentTabID,
                    sessionID: parentSessionID,
                    lastUserMessageAt: date(10)
                ),
                olderChildTabID: liveSession(
                    tabID: olderChildTabID,
                    sessionID: olderChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(20)
                ),
                newerChildTabID: liveSession(
                    tabID: newerChildTabID,
                    sessionID: newerChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(30)
                )
            ],
            sessionIndex: index
        )

        XCTAssertEqual(restoredRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(partiallyHydratedRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(fullyHydratedRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(restoredRows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(partiallyHydratedRows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(fullyHydratedRows.map(\.depth), [0, 1, 1])
    }

    func testLiveContinuationWinsOverStalePersistedDates() throws {
        let recentBase: TimeInterval = 1_800_000_000
        let parentTabID = id(20)
        let continuedChildTabID = id(21)
        let otherChildTabID = id(22)
        let parentSessionID = id(120)
        let continuedChildSessionID = id(121)
        let otherChildSessionID = id(122)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(continuedChildTabID, sessionID: continuedChildSessionID),
            tab(otherChildTabID, sessionID: otherChildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(recentBase + 10)),
            entry(
                continuedChildSessionID,
                tabID: continuedChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(recentBase + 100),
                savedAt: date(recentBase + 1000)
            ),
            entry(
                otherChildSessionID,
                tabID: otherChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(recentBase + 200)
            )
        ])
        let continuedSession = liveSession(
            tabID: continuedChildTabID,
            sessionID: continuedChildSessionID,
            parentSessionID: parentSessionID,
            lastUserMessageAt: date(recentBase + 300)
        )

        let rows = build(
            tabs: tabs,
            sessions: [continuedChildTabID: continuedSession],
            sessionIndex: index
        )

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, continuedChildTabID, otherChildTabID])
        let continuedRow = try XCTUnwrap(rows.first(where: { $0.tabID == continuedChildTabID }))
        XCTAssertEqual(continuedRow.lastUserMessageAt, date(recentBase + 300))
        XCTAssertEqual(continuedRow.activityDate, date(recentBase + 300))
    }

    func testUnhydratedPersistedRowUsesIndexSavedAtInsteadOfTabLastModified() throws {
        let staleTabID = id(23)
        let newerTabID = id(24)
        let staleSessionID = id(123)
        let newerSessionID = id(124)
        let tabs = [
            tab(staleTabID, sessionID: staleSessionID, lastModified: date(1000)),
            tab(newerTabID, sessionID: newerSessionID, lastModified: date(1))
        ]
        let index = sessionIndex([
            entry(
                staleSessionID,
                tabID: staleTabID,
                lastUserMessageAt: nil,
                savedAt: date(100)
            ),
            entry(
                newerSessionID,
                tabID: newerTabID,
                lastUserMessageAt: nil,
                savedAt: date(200)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [newerTabID, staleTabID])
        XCTAssertEqual(try row(for: staleTabID, in: rows).activityDate, date(100))
    }

    func testSiblingOrderFollowsActivityDates() throws {
        let parentTabID = id(30)
        let newerChildTabID = id(31)
        let activeOlderChildTabID = id(32)
        let parentSessionID = id(130)
        let newerChildSessionID = id(131)
        let activeOlderChildSessionID = id(132)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID),
            tab(activeOlderChildTabID, sessionID: activeOlderChildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(300)
            ),
            entry(
                activeOlderChildSessionID,
                tabID: activeOlderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(100)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, newerChildTabID, activeOlderChildTabID])
        XCTAssertEqual(
            try XCTUnwrap(rows.first(where: { $0.tabID == activeOlderChildTabID })).activityDate,
            date(100)
        )
        XCTAssertEqual(
            try XCTUnwrap(rows.first(where: { $0.tabID == newerChildTabID })).activityDate,
            date(300)
        )
    }

    func testPinnedChildPrecedesNewerUnpinnedSibling() {
        let rootTabID = id(33)
        let pinnedChildTabID = id(34)
        let newerChildTabID = id(35)
        let rootSessionID = id(133)
        let pinnedChildSessionID = id(134)
        let newerChildSessionID = id(135)
        let tabs = [
            tab(rootTabID, sessionID: rootSessionID),
            tab(pinnedChildTabID, sessionID: pinnedChildSessionID, isPinned: true),
            tab(newerChildTabID, sessionID: newerChildSessionID)
        ]
        let index = sessionIndex([
            entry(rootSessionID, tabID: rootTabID, lastUserMessageAt: date(1)),
            entry(
                pinnedChildSessionID,
                tabID: pinnedChildTabID,
                parentSessionID: rootSessionID,
                lastUserMessageAt: date(10)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: rootSessionID,
                lastUserMessageAt: date(100)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [rootTabID, pinnedChildTabID, newerChildTabID])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }

    func testPinnedDescendantElevatesContainingRootSubtree() {
        let pinnedSubtreeRootTabID = id(36)
        let branchTabID = id(37)
        let pinnedGrandchildTabID = id(38)
        let newerRootTabID = id(39)
        let pinnedSubtreeRootSessionID = id(136)
        let branchSessionID = id(137)
        let pinnedGrandchildSessionID = id(138)
        let newerRootSessionID = id(139)
        let tabs = [
            tab(pinnedSubtreeRootTabID, sessionID: pinnedSubtreeRootSessionID),
            tab(branchTabID, sessionID: branchSessionID),
            tab(pinnedGrandchildTabID, sessionID: pinnedGrandchildSessionID, isPinned: true),
            tab(newerRootTabID, sessionID: newerRootSessionID)
        ]
        let index = sessionIndex([
            entry(
                pinnedSubtreeRootSessionID,
                tabID: pinnedSubtreeRootTabID,
                lastUserMessageAt: date(1)
            ),
            entry(
                branchSessionID,
                tabID: branchTabID,
                parentSessionID: pinnedSubtreeRootSessionID,
                lastUserMessageAt: date(5)
            ),
            entry(
                pinnedGrandchildSessionID,
                tabID: pinnedGrandchildTabID,
                parentSessionID: branchSessionID,
                lastUserMessageAt: date(10)
            ),
            entry(newerRootSessionID, tabID: newerRootTabID, lastUserMessageAt: date(100))
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(
            rows.map(\.tabID),
            [pinnedSubtreeRootTabID, branchTabID, pinnedGrandchildTabID, newerRootTabID]
        )
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0])
    }

    func testPinnedRootsAndRootSubtreeRecencyRemainStable() {
        let pinnedOlderSubtreeRootTabID = id(40)
        let pinnedOlderSubtreeChildTabID = id(41)
        let pinnedNewerSubtreeRootTabID = id(42)
        let pinnedNewerSubtreeChildTabID = id(43)
        let freshRootTabID = id(44)
        let freshChildTabID = id(45)
        let mediumRootTabID = id(46)
        let pinnedOlderSubtreeRootSessionID = id(140)
        let pinnedOlderSubtreeChildSessionID = id(141)
        let pinnedNewerSubtreeRootSessionID = id(142)
        let pinnedNewerSubtreeChildSessionID = id(143)
        let freshRootSessionID = id(144)
        let freshChildSessionID = id(145)
        let mediumRootSessionID = id(146)
        let tabs = [
            tab(pinnedOlderSubtreeRootTabID, sessionID: pinnedOlderSubtreeRootSessionID, isPinned: true),
            tab(pinnedOlderSubtreeChildTabID, sessionID: pinnedOlderSubtreeChildSessionID),
            tab(pinnedNewerSubtreeRootTabID, sessionID: pinnedNewerSubtreeRootSessionID, isPinned: true),
            tab(pinnedNewerSubtreeChildTabID, sessionID: pinnedNewerSubtreeChildSessionID),
            tab(freshRootTabID, sessionID: freshRootSessionID),
            tab(freshChildTabID, sessionID: freshChildSessionID),
            tab(mediumRootTabID, sessionID: mediumRootSessionID)
        ]
        let index = sessionIndex([
            entry(
                pinnedOlderSubtreeRootSessionID,
                tabID: pinnedOlderSubtreeRootTabID,
                lastUserMessageAt: date(250)
            ),
            entry(
                pinnedOlderSubtreeChildSessionID,
                tabID: pinnedOlderSubtreeChildTabID,
                parentSessionID: pinnedOlderSubtreeRootSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                pinnedNewerSubtreeRootSessionID,
                tabID: pinnedNewerSubtreeRootTabID,
                lastUserMessageAt: date(10)
            ),
            entry(
                pinnedNewerSubtreeChildSessionID,
                tabID: pinnedNewerSubtreeChildTabID,
                parentSessionID: pinnedNewerSubtreeRootSessionID,
                lastUserMessageAt: date(280)
            ),
            entry(freshRootSessionID, tabID: freshRootTabID, lastUserMessageAt: date(5)),
            entry(
                freshChildSessionID,
                tabID: freshChildTabID,
                parentSessionID: freshRootSessionID,
                lastUserMessageAt: date(300)
            ),
            entry(mediumRootSessionID, tabID: mediumRootTabID, lastUserMessageAt: date(200))
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(
            rows.map(\.tabID),
            [
                pinnedNewerSubtreeRootTabID,
                pinnedNewerSubtreeChildTabID,
                pinnedOlderSubtreeRootTabID,
                pinnedOlderSubtreeChildTabID,
                freshRootTabID,
                freshChildTabID,
                mediumRootTabID
            ]
        )
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1, 0, 1, 0])
    }

    func testCyclesAndMissingParentsDegradeToRootWithoutBreakingValidHierarchy() throws {
        let validRootTabID = id(50)
        let validChildTabID = id(51)
        let cycleATabID = id(52)
        let cycleBTabID = id(53)
        let missingParentTabID = id(54)
        let validRootSessionID = id(150)
        let validChildSessionID = id(151)
        let cycleASessionID = id(152)
        let cycleBSessionID = id(153)
        let missingParentSessionID = id(154)
        let tabs = [
            tab(validRootTabID, sessionID: validRootSessionID),
            tab(validChildTabID, sessionID: validChildSessionID),
            tab(cycleATabID, sessionID: cycleASessionID),
            tab(cycleBTabID, sessionID: cycleBSessionID),
            tab(missingParentTabID, sessionID: missingParentSessionID)
        ]
        let index = sessionIndex([
            entry(validRootSessionID, tabID: validRootTabID, lastUserMessageAt: date(10)),
            entry(
                validChildSessionID,
                tabID: validChildTabID,
                parentSessionID: validRootSessionID,
                lastUserMessageAt: date(200)
            ),
            entry(
                cycleASessionID,
                tabID: cycleATabID,
                parentSessionID: cycleBSessionID,
                lastUserMessageAt: date(500)
            ),
            entry(
                cycleBSessionID,
                tabID: cycleBTabID,
                parentSessionID: cycleASessionID,
                lastUserMessageAt: date(400)
            ),
            entry(
                missingParentSessionID,
                tabID: missingParentTabID,
                parentSessionID: id(999),
                lastUserMessageAt: date(300)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.count, tabs.count)
        XCTAssertEqual(try row(for: cycleATabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: cycleBTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: missingParentTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: validRootTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: validChildTabID, in: rows).depth, 1)
        XCTAssertLessThan(
            try XCTUnwrap(rows.firstIndex(where: { $0.tabID == validRootTabID })),
            try XCTUnwrap(rows.firstIndex(where: { $0.tabID == validChildTabID }))
        )
    }

    func testUnhydratedScheduledEntrySurvivesThreadedRowCopyAndSearch() throws {
        let parentTabID = id(60)
        let childTabID = id(61)
        let parentSessionID = id(160)
        let childSessionID = id(161)
        let due = date(1_800_000_000)
        let rows = build(
            tabs: [
                tab(parentTabID, sessionID: parentSessionID),
                tab(childTabID, sessionID: childSessionID)
            ],
            sessionIndex: sessionIndex([
                entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(100)),
                entry(
                    childSessionID,
                    tabID: childTabID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: nil,
                    scheduledSendSummary: scheduledSummary(state: .scheduled, notBefore: due)
                )
            ])
        )

        let child = try row(for: childTabID, in: rows)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.scheduledSendStatus, .pending(due))
        XCTAssertTrue(child.searchFields.fields.map(\.text).contains("scheduled"))
        XCTAssertTrue(AgentModeSidebarSessionBuilder.sessionIndexEntryHasConversationContent(
            entry(
                childSessionID,
                tabID: childTabID,
                lastUserMessageAt: nil,
                scheduledSendSummary: scheduledSummary(state: .scheduled, notBefore: due)
            )
        ))
    }

    func testHydratedNilSuppressesStaleScheduledBadgeTitleAndSearch() throws {
        let tabID = id(62)
        let sessionID = id(162)
        let tab = ComposeTabState(
            id: tabID,
            name: "New Session",
            lastModified: date(1),
            activeAgentSessionID: sessionID
        )
        var staleEntry = entry(sessionID, tabID: tabID, lastUserMessageAt: nil)
        staleEntry.name = "New Session"
        staleEntry.scheduledSendSummary = scheduledSummary(state: .scheduled, notBefore: date(200))
        staleEntry.lastScheduledDispatch = receipt()

        let unhydrated = liveSession(
            tabID: tabID,
            sessionID: sessionID,
            lastUserMessageAt: nil,
            hydrated: false
        )
        let unhydratedRow = try row(
            for: tabID,
            in: build(tabs: [tab], sessions: [tabID: unhydrated], sessionIndex: sessionIndex([staleEntry]))
        )
        XCTAssertEqual(unhydratedRow.title, "New Session")
        XCTAssertEqual(unhydratedRow.scheduledSendStatus, .pending(date(200)))
        XCTAssertTrue(unhydratedRow.searchFields.fields.map(\.text).contains("scheduled"))

        unhydrated.hasLoadedPersistedState = true
        let liveReceipt = receipt()
        unhydrated.lastScheduledDispatch = liveReceipt
        let liveRow = try row(
            for: tabID,
            in: build(tabs: [tab], sessions: [tabID: unhydrated], sessionIndex: sessionIndex([staleEntry]))
        )
        XCTAssertEqual(liveRow.scheduledSendStatus, .sent(liveReceipt))
        XCTAssertTrue(liveRow.searchFields.fields.map(\.text).contains("scheduled"))

        unhydrated.lastScheduledDispatch = nil
        let hydratedRow = try row(
            for: tabID,
            in: build(tabs: [tab], sessions: [tabID: unhydrated], sessionIndex: sessionIndex([staleEntry]))
        )
        XCTAssertEqual(hydratedRow.title, "New Chat")
        XCTAssertNil(hydratedRow.scheduledSendStatus)
        XCTAssertFalse(hydratedRow.searchFields.fields.map(\.text).contains("scheduled"))
    }

    func testNoIndexEntryHistoricalReceiptRetainsDefaultTitleAndStatus() throws {
        let tabID = id(64)
        let sessionID = id(164)
        let tab = ComposeTabState(
            id: tabID,
            name: "New Session",
            lastModified: date(1),
            activeAgentSessionID: sessionID
        )
        let live = liveSession(tabID: tabID, sessionID: sessionID, lastUserMessageAt: nil)
        let emptyRow = try row(
            for: tabID,
            in: build(tabs: [tab], sessions: [tabID: live], sessionIndex: [:])
        )
        XCTAssertEqual(emptyRow.title, "New Chat")
        XCTAssertNil(emptyRow.scheduledSendStatus)

        let sentReceipt = receipt()
        live.lastScheduledDispatch = sentReceipt
        let historicalRow = try row(
            for: tabID,
            in: build(tabs: [tab], sessions: [tabID: live], sessionIndex: [:])
        )
        XCTAssertEqual(historicalRow.title, "New Session")
        XCTAssertEqual(historicalRow.scheduledSendStatus, .sent(sentReceipt))
        XCTAssertTrue(historicalRow.searchFields.fields.map(\.text).contains("scheduled"))
    }

    func testScheduledAttentionOverridesHistoryAndHistoricalClockRemainsSearchable() throws {
        let tabID = id(63)
        let sessionID = id(163)
        let sentReceipt = receipt()
        let cases: [(AgentSessionScheduledSendSummary?, AgentSidebarScheduledSendStatus?, Bool, String)] = [
            (scheduledSummary(state: .needsConfirmation), .needsConfirmation(date(200)), true, "Needs confirmation"),
            (scheduledSummary(state: .failed), .failed(date(200)), true, "Send failed"),
            (scheduledSummary(state: .dispatching), .dispatching(date(200)), false, "Sending"),
            (scheduledSummary(state: .scheduled), .pending(date(200)), false, "Scheduled for"),
            (scheduledSummary(unreadable: true), .unreadable, true, "Unreadable")
        ]
        for (summary, expected, attention, text) in cases {
            let indexed = entry(
                sessionID,
                tabID: tabID,
                lastUserMessageAt: nil,
                scheduledSendSummary: summary,
                lastScheduledDispatch: sentReceipt
            )
            let projected = try row(
                for: tabID,
                in: build(tabs: [tab(tabID, sessionID: sessionID)], sessionIndex: sessionIndex([indexed]))
            )
            XCTAssertEqual(projected.scheduledSendStatus, expected)
            XCTAssertEqual(projected.scheduledSendStatus?.needsAttention, attention)
            XCTAssertTrue(projected.scheduledSendStatus?.tooltipText.contains(text) == true)
            XCTAssertTrue(projected.searchFields.fields.map(\.text).contains("scheduled"))
            XCTAssertTrue(AgentModeSidebarSessionBuilder.sessionIndexEntryHasConversationContent(indexed))
        }

        let historical = entry(
            sessionID,
            tabID: tabID,
            lastUserMessageAt: nil,
            lastScheduledDispatch: sentReceipt
        )
        let projected = try row(
            for: tabID,
            in: build(tabs: [tab(tabID, sessionID: sessionID)], sessionIndex: sessionIndex([historical]))
        )
        XCTAssertEqual(projected.scheduledSendStatus, .sent(sentReceipt))
        XCTAssertFalse(try XCTUnwrap(projected.scheduledSendStatus).needsAttention)
        XCTAssertTrue(projected.scheduledSendStatus?.tooltipText.contains("Sent") == true)
        XCTAssertTrue(projected.searchFields.fields.map(\.text).contains("scheduled"))
        XCTAssertTrue(AgentModeSidebarSessionBuilder.sessionIndexEntryHasConversationContent(historical))
    }

    func testDelegatedQuestionAttentionResolvesByDurableSessionIDOnThreadedIndexOnlyRows() throws {
        let parentTabID = id(70)
        let childTabID = id(71)
        let quietTabID = id(72)
        let parentSessionID = id(170)
        let childSessionID = id(171)
        let quietSessionID = id(172)
        let parentAttention = AgentDelegatedQuestionSidebarAttention(
            pendingChildQuestionCount: 1,
            undeliveredChildQuestionCount: 1,
            ownQuestion: nil
        )
        let childAttention = AgentDelegatedQuestionSidebarAttention(ownQuestion: .waitingOnParentAgent)
        let rows = build(
            tabs: [
                tab(parentTabID, sessionID: parentSessionID),
                tab(childTabID, sessionID: childSessionID),
                tab(quietTabID, sessionID: quietSessionID)
            ],
            sessionIndex: sessionIndex([
                entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(100)),
                entry(childSessionID, tabID: childTabID, parentSessionID: parentSessionID, lastUserMessageAt: date(90)),
                entry(quietSessionID, tabID: quietTabID, lastUserMessageAt: date(80))
            ]),
            delegatedQuestionAttention: [
                parentSessionID: parentAttention,
                childSessionID: childAttention,
                quietSessionID: AgentDelegatedQuestionSidebarAttention()
            ]
        )

        let parent = try row(for: parentTabID, in: rows)
        XCTAssertEqual(parent.delegatedQuestionAttention, parentAttention)
        XCTAssertEqual(parent.delegatedQuestionAttention?.tooltipText, "1 pending child question (1 not yet delivered)")
        XCTAssertTrue(parent.searchFields.fields.map(\.text).contains("question"))

        let child = try row(for: childTabID, in: rows)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.delegatedQuestionAttention, childAttention)
        XCTAssertEqual(child.delegatedQuestionAttention?.tooltipText, "Waiting on parent agent")

        let quiet = try row(for: quietTabID, in: rows)
        XCTAssertNil(quiet.delegatedQuestionAttention, "Empty attention never renders a badge")
        XCTAssertFalse(quiet.searchFields.fields.map(\.text).contains("question"))
    }

    func testSearchFieldsOptOutMatchesFullBuildExceptSearchFields() throws {
        let rootTabID = id(80)
        let childTabID = id(81)
        let grandchildTabID = id(82)
        let pinnedTabID = id(83)
        let remoteTabID = id(84)
        let liveTabID = id(85)
        let rootSessionID = id(180)
        let childSessionID = id(181)
        let grandchildSessionID = id(182)
        let pinnedSessionID = id(183)
        let remoteSessionID = id(184)
        let liveSessionID = id(185)
        let tabs = [
            tab(rootTabID, sessionID: rootSessionID),
            tab(childTabID, sessionID: childSessionID),
            tab(grandchildTabID, sessionID: grandchildSessionID),
            tab(pinnedTabID, sessionID: pinnedSessionID, isPinned: true),
            tab(remoteTabID, sessionID: remoteSessionID),
            tab(liveTabID, sessionID: liveSessionID)
        ]
        let index = sessionIndex([
            entry(rootSessionID, tabID: rootTabID, lastUserMessageAt: date(300)),
            entry(childSessionID, tabID: childTabID, parentSessionID: rootSessionID, lastUserMessageAt: date(250)),
            entry(
                grandchildSessionID,
                tabID: grandchildTabID,
                parentSessionID: childSessionID,
                lastUserMessageAt: nil,
                scheduledSendSummary: scheduledSummary(state: .needsConfirmation)
            ),
            entry(pinnedSessionID, tabID: pinnedTabID, lastUserMessageAt: date(10)),
            entry(remoteSessionID, tabID: remoteTabID, lastUserMessageAt: date(200), remoteHostName: "Mac Studio"),
            entry(liveSessionID, tabID: liveTabID, lastUserMessageAt: date(100))
        ])
        let sessions = [
            liveTabID: liveSession(tabID: liveTabID, sessionID: liveSessionID, lastUserMessageAt: date(400))
        ]
        let attention = [
            rootSessionID: AgentDelegatedQuestionSidebarAttention(
                pendingChildQuestionCount: 1,
                undeliveredChildQuestionCount: 0,
                ownQuestion: nil
            ),
            childSessionID: AgentDelegatedQuestionSidebarAttention(ownQuestion: .waitingOnParentAgent)
        ]

        func rows(includesSearchFields: Bool) -> [AgentModeViewModel.SidebarSession] {
            build(
                tabs: tabs,
                sessions: sessions,
                sessionIndex: index,
                delegatedQuestionAttention: attention,
                mcpControlledTabIDs: [childTabID],
                registeredRemoteHosts: [(id: "host-1", displayName: "Mac Studio")],
                includesSearchFields: includesSearchFields
            )
        }
        let full = rows(includesSearchFields: true)
        let lean = rows(includesSearchFields: false)

        XCTAssertEqual(
            full.map(\.tabID),
            [pinnedTabID, liveTabID, rootTabID, childTabID, grandchildTabID, remoteTabID]
        )
        XCTAssertEqual(full.map(\.depth), [0, 0, 0, 1, 2, 0])
        XCTAssertTrue(full.allSatisfy { !$0.searchFields.fields.isEmpty })
        XCTAssertTrue(lean.allSatisfy { $0.searchFields == .empty })
        XCTAssertEqual(lean, full.map { withSearchFields(.empty, $0) })
        XCTAssertNotNil(try row(for: rootTabID, in: lean).delegatedQuestionAttention)
        XCTAssertNotNil(try row(for: grandchildTabID, in: lean).scheduledSendStatus)
        XCTAssertTrue(try row(for: childTabID, in: lean).isMCPControlled)
        XCTAssertNotNil(try row(for: remoteTabID, in: lean).remoteHostAbbreviation)
    }

    func testDefaultBuilderKeepsCompleteSearchCorpus() throws {
        let tabID = id(86)
        let sessionID = id(186)
        let indexed = entry(
            sessionID,
            tabID: tabID,
            lastUserMessageAt: date(100),
            scheduledSendSummary: scheduledSummary(state: .scheduled)
        )
        let builder = AgentModeSidebarSessionBuilder(
            allTabs: [tab(tabID, sessionID: sessionID)],
            linkedTabs: [tab(tabID, sessionID: sessionID)],
            sessions: [:],
            authoritativeSessionIDByTabID: [tabID: sessionID],
            sessionIndex: sessionIndex([indexed]),
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: [],
            registeredRemoteHosts: []
        )
        XCTAssertTrue(builder.includesSearchFields)

        let projected = try row(for: tabID, in: builder.build())
        XCTAssertEqual(
            projected.searchFields,
            AgentModeSidebarSessionBuilder.searchFields(
                title: projected.title,
                entry: indexed,
                runState: nil,
                isMCPControlled: false,
                worktree: nil,
                mergeAttention: nil,
                scheduledSendStatus: projected.scheduledSendStatus,
                sessionID: sessionID,
                tabID: tabID
            )
        )
        let texts = projected.searchFields.fields.map(\.text)
        XCTAssertTrue(texts.contains(projected.title))
        XCTAssertTrue(texts.contains("scheduled"))
        XCTAssertTrue(texts.contains(tabID.uuidString))
        XCTAssertTrue(texts.contains(sessionID.uuidString))
    }

    func testBlankSearchFilteredRowsSkipCorpusButKeepOrderThreadCollapseAndAttention() throws {
        let viewModel = makeViewModel()
        let rootATabID = id(90)
        let childBTabID = id(91)
        let grandchildCTabID = id(92)
        let rootDTabID = id(93)
        let childETabID = id(94)
        let rootFTabID = id(95)
        let rootASessionID = id(190)
        let childBSessionID = id(191)
        let grandchildCSessionID = id(192)
        let rootDSessionID = id(193)
        let childESessionID = id(194)
        let rootFSessionID = id(195)
        let tabs = [
            tab(rootATabID, sessionID: rootASessionID),
            tab(childBTabID, sessionID: childBSessionID),
            tab(grandchildCTabID, sessionID: grandchildCSessionID),
            tab(rootDTabID, sessionID: rootDSessionID),
            tab(childETabID, sessionID: childESessionID),
            tab(rootFTabID, sessionID: rootFSessionID)
        ]
        let workspace = WorkspaceModel(
            name: "Sidebar Blank Search Corpus",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: nil
        )
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            sessionIndex([
                entry(rootASessionID, tabID: rootATabID, lastUserMessageAt: date(300)),
                entry(childBSessionID, tabID: childBTabID, parentSessionID: rootASessionID, lastUserMessageAt: date(250)),
                entry(
                    grandchildCSessionID,
                    tabID: grandchildCTabID,
                    parentSessionID: childBSessionID,
                    lastUserMessageAt: date(240)
                ),
                entry(rootDSessionID, tabID: rootDTabID, lastUserMessageAt: date(200)),
                entry(childESessionID, tabID: childETabID, parentSessionID: rootDSessionID, lastUserMessageAt: date(190)),
                entry(rootFSessionID, tabID: rootFTabID, lastUserMessageAt: date(100))
            ]),
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        viewModel.setSidebarThreadCollapsed(true, for: .session(rootASessionID))
        viewModel.setSidebarThreadCollapsed(true, for: .session(rootDSessionID))
        viewModel.ui.sessionSidebar.markRunStateAttention(tabID: grandchildCTabID, state: .completed)
        viewModel.ui.sessionSidebar.markRunStateAttention(tabID: rootFTabID, state: .failed)

        let fullRows = viewModel.sidebarSessions(for: tabs)
        XCTAssertTrue(fullRows.allSatisfy { !$0.searchFields.fields.isEmpty })
        let fullRowByTabID = Dictionary(uniqueKeysWithValues: fullRows.map { ($0.tabID, $0) })

        let blank = viewModel.filteredSidebarSessions(for: tabs, currentTabID: childETabID, searchText: "")
        let whitespace = viewModel.filteredSidebarSessions(for: tabs, currentTabID: childETabID, searchText: " \n\t ")
        XCTAssertEqual(whitespace, blank)
        XCTAssertTrue(blank.allSatisfy { $0.searchFields == .empty })
        XCTAssertEqual(blank.map(\.tabID), [rootATabID, rootDTabID, childETabID, rootFTabID])
        for row in blank {
            let full = try XCTUnwrap(fullRowByTabID[row.tabID])
            XCTAssertEqual(builderProjection(row), withSearchFields(.empty, full))
        }

        let rootA = try row(for: rootATabID, in: blank)
        XCTAssertEqual(rootA.threadKey, .session(rootASessionID))
        XCTAssertTrue(rootA.hasThreadChildren)
        XCTAssertTrue(rootA.isThreadCollapsed)
        XCTAssertEqual(rootA.hiddenThreadDescendantCount, 2)
        XCTAssertEqual(rootA.hiddenThreadDescendantAttentionCount, 1)
        XCTAssertEqual(rootA.threadActivityDate, date(300))
        let rootD = try row(for: rootDTabID, in: blank)
        XCTAssertTrue(rootD.hasThreadChildren)
        XCTAssertFalse(rootD.isThreadCollapsed, "A collapsed thread containing the active tab stays expanded")
        XCTAssertEqual(rootD.hiddenThreadDescendantCount, 0)
        let rootF = try row(for: rootFTabID, in: blank)
        XCTAssertFalse(rootF.hasThreadChildren)
        XCTAssertEqual(rootF.hiddenThreadDescendantAttentionCount, 0)
        XCTAssertEqual(
            viewModel.collapsibleSidebarThreadKeys(filteredRows: blank),
            [.session(rootASessionID), .session(rootDSessionID)]
        )

        let searched = viewModel.filteredSidebarSessions(
            for: tabs,
            currentTabID: childETabID,
            searchText: "Tab 0092"
        )
        XCTAssertEqual(searched.map(\.tabID), [rootATabID, childBTabID, grandchildCTabID])
        XCTAssertEqual(searched.map(\.depth), [0, 1, 2])
        XCTAssertFalse(searched.contains(where: \.isThreadCollapsed), "Search never collapses threads")
        for row in searched {
            let full = try XCTUnwrap(fullRowByTabID[row.tabID])
            XCTAssertEqual(row.searchFields, full.searchFields)
            XCTAssertEqual(builderProjection(row), full)
        }
    }

    private func build(
        tabs: [ComposeTabState],
        sessions: [UUID: AgentTabSession] = [:],
        sessionIndex: [UUID: AgentSessionIndexEntry],
        delegatedQuestionAttention: [UUID: AgentDelegatedQuestionSidebarAttention] = [:],
        mcpControlledTabIDs: Set<UUID> = [],
        registeredRemoteHosts: [(id: String, displayName: String)] = [],
        includesSearchFields: Bool = true
    ) -> [AgentModeViewModel.SidebarSession] {
        var builder = AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            linkedTabs: tabs,
            sessions: sessions,
            authoritativeSessionIDByTabID: Dictionary(
                uniqueKeysWithValues: tabs.compactMap { tab in
                    tab.activeAgentSessionID.map { (tab.id, $0) }
                }
            ),
            sessionIndex: sessionIndex,
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: mcpControlledTabIDs,
            registeredRemoteHosts: registeredRemoteHosts
        )
        builder.delegatedQuestionAttentionBySessionID = delegatedQuestionAttention
        builder.includesSearchFields = includesSearchFields
        return builder.build()
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    /// Copy of `row` with every field preserved except `searchFields`.
    private func withSearchFields(
        _ searchFields: AgentSessionSearchFields,
        _ row: AgentModeViewModel.SidebarSession
    ) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: row.id,
            tabID: row.tabID,
            title: row.title,
            lastUserMessageAt: row.lastUserMessageAt,
            activityDate: row.activityDate,
            isPinned: row.isPinned,
            sessionID: row.sessionID,
            parentSessionID: row.parentSessionID,
            depth: row.depth,
            isMCPControlled: row.isMCPControlled,
            remoteHostName: row.remoteHostName,
            remoteHostAbbreviation: row.remoteHostAbbreviation,
            remoteControlDeviceID: row.remoteControlDeviceID,
            remoteControlDeviceDisplayName: row.remoteControlDeviceDisplayName,
            worktree: row.worktree,
            worktreeMergeAttention: row.worktreeMergeAttention,
            scheduledSendStatus: row.scheduledSendStatus,
            delegatedQuestionAttention: row.delegatedQuestionAttention,
            threadKey: row.threadKey,
            hasThreadChildren: row.hasThreadChildren,
            isThreadCollapsed: row.isThreadCollapsed,
            hiddenThreadDescendantCount: row.hiddenThreadDescendantCount,
            hiddenThreadDescendantAttentionCount: row.hiddenThreadDescendantAttentionCount,
            threadActivityDate: row.threadActivityDate,
            searchFields: searchFields
        )
    }

    /// Builder-owned fields of a displayed row: the thread-collapse pass's fields reset to
    /// the builder defaults so the row compares against `sidebarSessions(for:)` output.
    private func builderProjection(_ row: AgentModeViewModel.SidebarSession) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: row.id,
            tabID: row.tabID,
            title: row.title,
            lastUserMessageAt: row.lastUserMessageAt,
            activityDate: row.activityDate,
            isPinned: row.isPinned,
            sessionID: row.sessionID,
            parentSessionID: row.parentSessionID,
            depth: row.depth,
            isMCPControlled: row.isMCPControlled,
            remoteHostName: row.remoteHostName,
            remoteHostAbbreviation: row.remoteHostAbbreviation,
            remoteControlDeviceID: row.remoteControlDeviceID,
            remoteControlDeviceDisplayName: row.remoteControlDeviceDisplayName,
            worktree: row.worktree,
            worktreeMergeAttention: row.worktreeMergeAttention,
            scheduledSendStatus: row.scheduledSendStatus,
            delegatedQuestionAttention: row.delegatedQuestionAttention,
            searchFields: row.searchFields
        )
    }

    private func liveSession(
        tabID: UUID,
        sessionID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date?,
        hydrated: Bool = true
    ) -> AgentTabSession {
        let session = AgentTabSession(tabID: tabID)
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parentSessionID
        session.hasLoadedPersistedState = hydrated
        session.lastUserMessageAt = lastUserMessageAt
        session.lastActivityAt = lastUserMessageAt ?? date(1)
        return session
    }

    private func tab(
        _ tabID: UUID,
        sessionID: UUID,
        isPinned: Bool = false,
        lastModified: Date? = nil
    ) -> ComposeTabState {
        ComposeTabState(
            id: tabID,
            name: "Tab \(tabID.uuidString.suffix(4))",
            lastModified: lastModified ?? date(1),
            isPinned: isPinned,
            activeAgentSessionID: sessionID
        )
    }

    private func entry(
        _ sessionID: UUID,
        tabID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date?,
        savedAt: Date? = nil,
        remoteHostName: String? = nil,
        scheduledSendSummary: AgentSessionScheduledSendSummary? = nil,
        lastScheduledDispatch: AgentScheduledSendProvenance? = nil
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Session \(sessionID.uuidString.suffix(4))",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt ?? lastUserMessageAt ?? date(1),
            lastRunStateRaw: nil,
            itemCount: lastUserMessageAt == nil ? 0 : 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            remoteHostID: remoteHostName == nil ? nil : "host-1",
            remoteHostName: remoteHostName,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: [],
            scheduledSendSummary: scheduledSendSummary,
            lastScheduledDispatch: lastScheduledDispatch
        )
    }

    private func scheduledSummary(
        state: AgentScheduledSendPersist.State = .scheduled,
        notBefore: Date? = nil,
        unreadable: Bool = false
    ) -> AgentSessionScheduledSendSummary {
        AgentSessionScheduledSendSummary(
            id: unreadable ? nil : UUID(),
            createdAt: unreadable ? nil : date(100),
            updatedAt: unreadable ? nil : date(150),
            notBefore: unreadable ? nil : (notBefore ?? date(200)),
            stateRaw: unreadable ? nil : state.rawValue,
            confirmationReasonRaw: nil,
            isNewSessionStart: true,
            runAlongsideOtherSessions: false,
            previewText: unreadable ? "" : "Send later",
            isUnreadable: unreadable
        )
    }

    private func receipt() -> AgentScheduledSendProvenance {
        AgentScheduledSendProvenance(
            scheduleID: UUID(),
            attemptID: UUID(),
            scheduledFor: date(100),
            sentAt: date(120)
        )
    }

    private func sessionIndex(_ entries: [AgentSessionIndexEntry]) -> [UUID: AgentSessionIndexEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private func row(
        for tabID: UUID,
        in rows: [AgentModeViewModel.SidebarSession]
    ) throws -> AgentModeViewModel.SidebarSession {
        try XCTUnwrap(rows.first(where: { $0.tabID == tabID }))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
