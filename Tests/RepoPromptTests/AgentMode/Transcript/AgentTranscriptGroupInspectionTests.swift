import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Oracle failure inspection plan, Patch C: live group expansion, flattened entries,
/// bottom-sticky inner follow, and the header failure-count suffix.
final class AgentTranscriptGroupInspectionTests: XCTestCase {
    private typealias Policy = AgentTranscriptGroupExpansionPolicy

    // MARK: - C1 expansion provenance

    func testEffectiveExpansionTruthTable() {
        let rows: [(label: String, supports: Bool, manual: Bool, target: Bool, stored: Bool?, defaultExpanded: Bool, expected: Bool)] = [
            ("no content, manual expanded", false, true, false, true, true, false),
            ("no content, default expanded", false, false, false, nil, true, false),
            ("manual expanded on a default-collapse target", true, true, true, true, false, true),
            ("manual collapsed on a non-target", true, true, false, false, true, false),
            ("manual without stored value falls back to default", true, true, true, nil, true, true),
            ("target without a choice, stored expanded", true, false, true, true, true, false),
            ("target without a choice, default expanded", true, false, true, nil, true, false),
            ("non-target stored expanded", true, false, false, true, false, true),
            ("non-target stored collapsed", true, false, false, false, true, false),
            ("non-target default expanded", true, false, false, nil, true, true),
            ("non-target default collapsed", true, false, false, nil, false, false)
        ]
        for row in rows {
            XCTAssertEqual(
                Policy.effectiveExpansion(
                    supportsExpansion: row.supports,
                    isManualChoice: row.manual,
                    isDefaultCollapseTarget: row.target,
                    storedExpansion: row.stored,
                    defaultExpanded: row.defaultExpanded
                ),
                row.expected,
                row.label
            )
        }
    }

    func testFirstClickOnDefaultExpandedLockTargetExpandsIt() {
        let block = Policy.BlockInput(id: "grouped", supportsExpansion: true, defaultExpanded: true)
        var state = Policy.synchronized(Policy.State(), blocks: [block])
        XCTAssertEqual(state.expansion["grouped"], true, "Sync seeds the default")
        XCTAssertFalse(Policy.effectiveExpansion(of: block, in: state, isDefaultCollapseTarget: true))

        state = Policy.toggled(state, block: block, isDefaultCollapseTarget: true)
        XCTAssertTrue(
            Policy.effectiveExpansion(of: block, in: state, isDefaultCollapseTarget: true),
            "The first click flips the effective (collapsed) state, not the stored value"
        )
        XCTAssertTrue(state.manualIDs.contains("grouped"))

        state = Policy.toggled(state, block: block, isDefaultCollapseTarget: true)
        XCTAssertFalse(Policy.effectiveExpansion(of: block, in: state, isDefaultCollapseTarget: true))
        XCTAssertTrue(state.manualIDs.contains("grouped"), "Collapsing is an explicit choice too")
        XCTAssertFalse(
            Policy.effectiveExpansion(of: block, in: state, isDefaultCollapseTarget: false),
            "An explicit collapse survives run end"
        )

        let unsupported = Policy.BlockInput(id: "empty", supportsExpansion: false, defaultExpanded: true)
        XCTAssertEqual(Policy.toggled(state, block: unsupported, isDefaultCollapseTarget: false), state)
    }

    func testSyncKeepsExplicitChoicesAndPrunesStaleIDs() {
        let manual = Policy.BlockInput(id: "manual", supportsExpansion: true, defaultExpanded: false)
        let following = Policy.BlockInput(id: "following", supportsExpansion: true, defaultExpanded: false)
        let diverged = Policy.BlockInput(id: "diverged", supportsExpansion: true, defaultExpanded: false)
        let stale = Policy.BlockInput(id: "stale", supportsExpansion: true, defaultExpanded: false)
        var state = Policy.synchronized(Policy.State(), blocks: [manual, following, diverged, stale])
        state = Policy.toggled(state, block: manual, isDefaultCollapseTarget: true)
        state = Policy.toggled(state, block: stale, isDefaultCollapseTarget: false)
        state.expansion["diverged"] = true
        XCTAssertEqual(state.expansion["manual"], true)

        // Every remaining default flips to expanded; the stale block disappears.
        let flipped = [manual, following, diverged].map {
            Policy.BlockInput(id: $0.id, supportsExpansion: true, defaultExpanded: true)
        }
        state = Policy.synchronized(state, blocks: flipped)
        XCTAssertEqual(state.expansion["manual"], true, "An explicit choice is never default-following")
        XCTAssertEqual(state.expansion["following"], true, "An unchosen default-valued block follows the flip")
        XCTAssertEqual(state.expansion["diverged"], true)
        XCTAssertNil(state.expansion["stale"])
        XCTAssertNil(state.defaults["stale"])
        XCTAssertEqual(state.manualIDs, ["manual"], "Stale explicit choices are pruned")

        // A manual choice opposite to a flipped default keeps its value.
        state = Policy.toggled(state, block: flipped[0], isDefaultCollapseTarget: false)
        XCTAssertEqual(state.expansion["manual"], false)
        state = Policy.synchronized(state, blocks: [manual, following, diverged])
        XCTAssertEqual(state.expansion["manual"], false)
        XCTAssertEqual(state.expansion["following"], false, "Following blocks track the default back")

        // A block that no longer supports expansion loses its explicit choice.
        state = Policy.synchronized(state, blocks: [
            Policy.BlockInput(id: "manual", supportsExpansion: false, defaultExpanded: false),
            following,
            diverged
        ])
        XCTAssertTrue(state.manualIDs.isEmpty)
        XCTAssertNil(state.expansion["manual"])
    }

    func testRunActivationCountExcludesExplicitChoices() {
        let manualExpanded = Policy.BlockInput(id: "manual", supportsExpansion: true, defaultExpanded: false)
        let storedExpanded = Policy.BlockInput(id: "stored", supportsExpansion: true, defaultExpanded: false)
        let defaultExpanded = Policy.BlockInput(id: "default", supportsExpansion: true, defaultExpanded: true)
        let collapsed = Policy.BlockInput(id: "collapsed", supportsExpansion: true, defaultExpanded: false)
        let empty = Policy.BlockInput(id: "empty", supportsExpansion: false, defaultExpanded: true)
        let blocks = [manualExpanded, storedExpanded, defaultExpanded, collapsed, empty]
        var state = Policy.synchronized(Policy.State(), blocks: blocks)
        state = Policy.toggled(state, block: manualExpanded, isDefaultCollapseTarget: false)
        state.expansion["stored"] = true

        XCTAssertEqual(
            Policy.automaticallyCollapsingCount(state, blocks: blocks),
            2,
            "Only unchosen expanded groups collapse automatically and need the compensating re-pin"
        )
    }

    func testIndependentGroupsDoNotUnlockTogether() {
        let first = Policy.BlockInput(id: "grouped-history:turn:span-0", supportsExpansion: true, defaultExpanded: false)
        let second = Policy.BlockInput(id: "grouped-history:turn:span-1", supportsExpansion: true, defaultExpanded: false)
        var state = Policy.synchronized(Policy.State(), blocks: [first, second])
        state = Policy.toggled(state, block: first, isDefaultCollapseTarget: true)
        state = Policy.synchronized(state, blocks: [first, second])

        XCTAssertTrue(Policy.effectiveExpansion(of: first, in: state, isDefaultCollapseTarget: true))
        XCTAssertFalse(Policy.effectiveExpansion(of: second, in: state, isDefaultCollapseTarget: true))
        XCTAssertEqual(state.manualIDs, [first.id])
    }

    // MARK: - C1 gate: production block identity

    func testLiveGroupedHistoryBlockIDIsStableAcrossAppendsAndReprojection() throws {
        let user = AgentChatItem.user("Inspect the repository", sequenceIndex: 0)
        var items = [user]
        var sequenceIndex = 1
        func appendTools(_ count: Int) {
            for _ in 0 ..< count {
                let invocationID = UUID()
                items.append(.toolCall(
                    name: "read_file",
                    invocationID: invocationID,
                    argsJSON: #"{"path":"/tmp/file.swift"}"#,
                    sequenceIndex: sequenceIndex
                ))
                items.append(.toolResult(
                    name: "read_file",
                    invocationID: invocationID,
                    resultJSON: #"{"content":"ok"}"#,
                    sequenceIndex: sequenceIndex + 1
                ))
                sequenceIndex += 2
            }
        }
        func liveGroupedHistory() throws -> AgentTranscriptRenderBlock {
            let blocks = AgentTranscriptProjectionBuilder.blocks(
                for: AgentTranscriptIO.buildTranscript(from: items, compact: false)
            )
            XCTAssertFalse(
                blocks.contains { $0.kind == .activityCluster },
                "The live group is grouped history; extend this gate if clusters are emitted again"
            )
            return try XCTUnwrap(blocks.first { $0.kind == .groupedHistory && $0.turnID == user.id })
        }

        appendTools(10)
        let initial = try liveGroupedHistory()
        XCTAssertEqual(try liveGroupedHistory().id, initial.id, "Re-projection keeps the ID")

        appendTools(4)
        let appended = try liveGroupedHistory()
        XCTAssertEqual(appended.id, initial.id, "Appending calls keeps the live group's ID")
        XCTAssertGreaterThan(
            rowCount(appended),
            rowCount(initial),
            "The live grouped prefix grows as older calls fold into it"
        )

        let pendingID = UUID()
        items.append(.toolCall(name: "read_file", invocationID: pendingID, argsJSON: "{}", sequenceIndex: sequenceIndex))
        sequenceIndex += 1
        XCTAssertEqual(try liveGroupedHistory().id, initial.id)

        items.append(.toolResult(name: "read_file", invocationID: pendingID, resultJSON: "{}", sequenceIndex: sequenceIndex))
        sequenceIndex += 1
        items.append(.assistant("Done", sequenceIndex: sequenceIndex))
        let completed = AgentTranscriptProjectionBuilder.blocks(
            for: AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed, compact: false)
        )
        XCTAssertEqual(
            completed.first { $0.kind == .groupedHistory && $0.turnID == user.id }?.id,
            initial.id,
            "Run completion keeps the ID, so an explicit expansion survives it"
        )
    }

    // MARK: - C4 flattened entries

    func testFlattenedEntriesPreserveSectionsChildRowsAndSpacing() {
        let turnID = UUID()
        func row(_ text: String) -> AgentChatItem {
            .assistant(text, sequenceIndex: 0)
        }
        func child(_ id: String, _ rows: [AgentChatItem]) -> AgentTranscriptRenderBlock {
            AgentTranscriptRenderBlock(
                id: id,
                kind: .standaloneTool,
                turnID: turnID,
                retentionTier: .full,
                rows: rows,
                isArchived: false
            )
        }
        let a0 = row("a0"), a1 = row("a1"), b0 = row("b0"), c0 = row("c0"), d0 = row("d0")
        let sections = [
            AgentTranscriptGroupedSection(
                id: "s1",
                kind: .tools,
                title: "Explored",
                icon: "folder",
                childBlocks: [child("A", [a0, a1]), child("B", [b0])]
            ),
            AgentTranscriptGroupedSection(id: "s2", kind: .assistant, childBlocks: [child("C", [c0]), child("E", [])]),
            AgentTranscriptGroupedSection(
                id: "s3",
                kind: .notes,
                title: "Notes",
                childBlocks: [child("D", [d0, a0])]
            )
        ]

        let entries = AgentTranscriptGroupInspection.entries(for: sections)
        XCTAssertEqual(entries.map(\.id), [
            "section:s1",
            "row:\(a0.id.uuidString.lowercased())",
            "row:\(a1.id.uuidString.lowercased())",
            "row:\(b0.id.uuidString.lowercased())",
            "row:\(c0.id.uuidString.lowercased())",
            "section:s3",
            "row:\(d0.id.uuidString.lowercased())"
        ], "Headings precede their rows; a repeated row is emitted once")
        XCTAssertEqual(entries.map(\.topSpacing), [2, 6, 4, 6, 12, 12, 6])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(entries[0].content, .sectionHeader(sections[0]))
        XCTAssertEqual(entries[3].content, .row(b0, childBlock: sections[0].childBlocks[1]), "Rows keep their child render context")
        XCTAssertEqual(entries[4].content, .row(c0, childBlock: sections[1].childBlocks[0]))
        XCTAssertTrue(AgentTranscriptGroupInspection.entries(for: []).isEmpty)
    }

    // MARK: - C3 inner follow

    func testInnerFollowIsBottomSticky() {
        typealias Follow = AgentTranscriptInnerFollowPolicy
        let rows: [(label: String, current: Bool, old: Follow.Position?, new: Follow.Position, expected: Bool)] = [
            ("first report at the bottom pins", false, nil, .init(offsetY: 0, distanceToBottom: 0), true),
            ("starting at the top of a long list stays unpinned", false, nil, .init(offsetY: 0, distanceToBottom: 400), false),
            ("a new row below an unmoved offset keeps following", true, .init(offsetY: 200, distanceToBottom: 0), .init(offsetY: 200, distanceToBottom: 40), true),
            ("scrolling up stops following", true, .init(offsetY: 200, distanceToBottom: 0), .init(offsetY: 150, distanceToBottom: 50), false),
            ("scrolling down short of the bottom stays unpinned", false, .init(offsetY: 100, distanceToBottom: 150), .init(offsetY: 140, distanceToBottom: 110), false),
            ("returning to the bottom resumes following", false, .init(offsetY: 140, distanceToBottom: 110), .init(offsetY: 250, distanceToBottom: 2), true)
        ]
        for row in rows {
            XCTAssertEqual(Follow.isPinned(current: row.current, old: row.old, new: row.new), row.expected, row.label)
        }
        XCTAssertTrue(Follow.shouldFollow(isLive: true, isPinned: true))
        XCTAssertFalse(Follow.shouldFollow(isLive: true, isPinned: false), "Never yank a reader away")
        XCTAssertFalse(Follow.shouldFollow(isLive: false, isPinned: true), "No follow once the run ends")
    }

    /// macOS 14 derives the position from the content frame in the scroll view's coordinate space;
    /// macOS 15+ from `ScrollGeometry`. Equal geometry must give the same position.
    func testInnerFollowPositionMatchesAcrossPlatformPaths() {
        typealias Follow = AgentTranscriptInnerFollowPolicy
        let viewportHeight: CGFloat = 300
        for (offset, contentHeight) in [(0, 200), (0, 900), (250, 900), (598, 900), (600, 900), (640, 900)] as [(CGFloat, CGFloat)] {
            let modern = Follow.position(
                contentOffsetY: offset,
                contentHeight: contentHeight,
                visibleMaxY: offset + viewportHeight
            )
            let legacy = Follow.position(
                contentFrame: CGRect(x: 0, y: -offset, width: 400, height: contentHeight),
                viewportHeight: viewportHeight
            )
            XCTAssertEqual(legacy, modern, "offset \(offset), content \(contentHeight)")
        }
        XCTAssertEqual(
            Follow.position(contentFrame: CGRect(x: 0, y: -250, width: 400, height: 900), viewportHeight: 300),
            Follow.Position(offsetY: 250, distanceToBottom: 350)
        )
    }

    /// Follow, detach, and resume through the shared state machine, driven by each platform
    /// path's geometry.
    func testInnerFollowFollowsDetachesAndResumesOnBothPlatformPaths() {
        typealias Follow = AgentTranscriptInnerFollowPolicy
        let viewport: CGFloat = 300
        let derivations: [(name: String, position: (CGFloat, CGFloat) -> Follow.Position)] = [
            ("macOS 15 ScrollGeometry", { offset, height in
                Follow.position(contentOffsetY: offset, contentHeight: height, visibleMaxY: offset + viewport)
            }),
            ("macOS 14 geometry reader", { offset, height in
                Follow.position(contentFrame: CGRect(x: 0, y: -offset, width: 400, height: height), viewportHeight: viewport)
            })
        ]
        for derivation in derivations {
            var state = AgentTranscriptInnerFollowState(isLive: true)
            state.record(derivation.position(0, 900))
            XCTAssertNil(state.scheduleFollow(), "\(derivation.name): starting at the top does not follow")

            state.record(derivation.position(600, 900))
            XCTAssertTrue(state.isPinned, derivation.name)
            state.record(derivation.position(600, 940))
            XCTAssertTrue(state.isPinned, "\(derivation.name): a new row below an unmoved offset keeps following")
            let follow = state.scheduleFollow()
            XCTAssertNotNil(follow, derivation.name)
            XCTAssertTrue(follow.map(state.shouldExecuteFollow) == true, derivation.name)
            state.record(derivation.position(640, 940))

            state.record(derivation.position(500, 980))
            XCTAssertFalse(state.isPinned, "\(derivation.name): scrolling up detaches")
            XCTAssertNil(state.scheduleFollow(), "\(derivation.name): a detached reader is never followed")

            state.record(derivation.position(679, 980))
            XCTAssertTrue(state.isPinned, "\(derivation.name): returning to the bottom resumes")
            XCTAssertNotNil(state.scheduleFollow(), derivation.name)
        }
    }

    func testDeferredInnerFollowIsRevalidatedWhenItRuns() throws {
        typealias Follow = AgentTranscriptInnerFollowPolicy
        let bottom = Follow.Position(offsetY: 600, distanceToBottom: 0)

        var unpinned = AgentTranscriptInnerFollowState(isLive: true)
        unpinned.record(bottom)
        let unpinnedTicket = try XCTUnwrap(unpinned.scheduleFollow())
        unpinned.record(Follow.Position(offsetY: 520, distanceToBottom: 80))
        XCTAssertFalse(unpinned.shouldExecuteFollow(unpinnedTicket), "Scrolling up before the deferred scroll cancels it")
        unpinned.record(bottom)
        XCTAssertFalse(unpinned.shouldExecuteFollow(unpinnedTicket), "A cancelled follow stays cancelled after re-pinning")

        var ended = AgentTranscriptInnerFollowState(isLive: true)
        ended.record(bottom)
        let endedTicket = try XCTUnwrap(ended.scheduleFollow())
        ended.setLive(false)
        XCTAssertFalse(ended.shouldExecuteFollow(endedTicket), "The run ending before the deferred scroll cancels it")
        XCTAssertNil(ended.scheduleFollow(), "No follow once the run ends")

        var superseded = AgentTranscriptInnerFollowState(isLive: true)
        superseded.record(bottom)
        let first = try XCTUnwrap(superseded.scheduleFollow())
        let second = try XCTUnwrap(superseded.scheduleFollow())
        XCTAssertFalse(superseded.shouldExecuteFollow(first), "Only the latest scheduled follow runs")
        XCTAssertTrue(superseded.shouldExecuteFollow(second))
        superseded.record(Follow.Position(offsetY: 600, distanceToBottom: 44))
        XCTAssertTrue(superseded.shouldExecuteFollow(second), "Content growth alone does not cancel the follow")
    }

    // MARK: - C3 inner follow tracker parity (transcript inner-scroll hang fix, Step 3)

    @MainActor
    func testInnerFollowTrackerMatchesStateThroughGrowthUnpinAndRepin() {
        let driver = InnerFollowParityDriver(isLive: true)
        driver.record(offset: 0, distance: 400)
        XCTAssertFalse(driver.isPinned, "Starting at the top of a long list stays unpinned")
        XCTAssertNil(driver.scheduleFollow("top"), "No follow from the top")

        driver.record(offset: 600, distance: 0)
        XCTAssertTrue(driver.isPinned)
        XCTAssertNotNil(driver.scheduleFollow("growth"))
        driver.record(offset: 600, distance: 44)
        XCTAssertTrue(driver.isPinned, "Growth below an unmoved offset keeps following")
        XCTAssertTrue(driver.executes("growth"))
        driver.record(offset: 644, distance: 0)
        XCTAssertTrue(driver.executes("growth"))

        XCTAssertNotNil(driver.scheduleFollow("preUnpin"))
        XCTAssertFalse(driver.executes("growth"), "A newer follow supersedes the older ticket")
        XCTAssertTrue(driver.executes("preUnpin"))

        driver.record(offset: 560, distance: 84)
        XCTAssertFalse(driver.isPinned, "Scrolling up unpins")
        XCTAssertFalse(driver.executes("preUnpin"), "Unpinning cancels a ticket taken before it")
        XCTAssertNil(driver.scheduleFollow("unpinned"), "A detached reader is never followed")

        driver.record(offset: 643, distance: 1)
        XCTAssertTrue(driver.isPinned, "Returning to the bottom re-pins")
        XCTAssertFalse(driver.executes("preUnpin"), "Re-pinning never revives a cancelled ticket")
        XCTAssertNotNil(driver.scheduleFollow("repinned"))
        XCTAssertTrue(driver.executes("repinned"))
        XCTAssertFalse(driver.executes("preUnpin"))
    }

    @MainActor
    func testInnerFollowTrackerMatchesStateThroughRunCompletionAndSupersededTickets() {
        let driver = InnerFollowParityDriver(isLive: true)
        driver.record(offset: 600, distance: 0)
        XCTAssertNotNil(driver.scheduleFollow("first"))
        XCTAssertNotNil(driver.scheduleFollow("second"))
        XCTAssertFalse(driver.executes("first"), "Only the latest scheduled follow runs")
        XCTAssertTrue(driver.executes("second"))
        driver.record(offset: 600, distance: 44)
        XCTAssertTrue(driver.executes("second"), "Content growth alone does not cancel the follow")

        driver.setLive(false)
        XCTAssertFalse(driver.executes("second"), "The run ending cancels an outstanding follow")
        XCTAssertNil(driver.scheduleFollow("ended"), "No follow once the run ends")
        driver.setLive(false)
        driver.record(offset: 644, distance: 0)
        XCTAssertTrue(driver.isPinned)
        XCTAssertNil(driver.scheduleFollow("endedPinned"), "Being pinned alone does not follow after the run ends")

        driver.setLive(true)
        XCTAssertFalse(driver.executes("second"), "Going live again does not revive a cancelled follow")
        XCTAssertNotNil(driver.scheduleFollow("live"))
        XCTAssertTrue(driver.executes("live"))

        let idle = InnerFollowParityDriver(isLive: false)
        idle.record(offset: 0, distance: 0)
        XCTAssertNil(idle.scheduleFollow("idle"), "A group that is not live never follows")
        idle.setLive(true)
        XCTAssertNotNil(idle.scheduleFollow("started"))
        XCTAssertTrue(idle.executes("started"))
    }

    @MainActor
    func testInnerFollowTrackerMatchesStateAtPinToleranceAndScrollUpBoundaries() {
        let driver = InnerFollowParityDriver(isLive: true)
        driver.record(offset: 0, distance: 6.5)
        XCTAssertFalse(driver.isPinned, "Just outside the 6-point tolerance does not pin")
        driver.record(offset: 0.5, distance: 6)
        XCTAssertTrue(driver.isPinned, "Exactly 6 points from the bottom pins")
        XCTAssertNotNil(driver.scheduleFollow("edge"))

        driver.record(offset: 600, distance: 0)
        driver.record(offset: 594, distance: 6)
        XCTAssertTrue(driver.isPinned, "Scrolling up within the tolerance stays pinned")
        XCTAssertTrue(driver.executes("edge"))
        driver.record(offset: 593.5, distance: 6.5)
        XCTAssertTrue(driver.isPinned, "An upward move of exactly 0.5 points is not a scroll-up")
        XCTAssertTrue(driver.executes("edge"))
        driver.record(offset: 592.75, distance: 7.25)
        XCTAssertFalse(driver.isPinned, "More than 0.5 points upward outside the tolerance unpins")
        XCTAssertFalse(driver.executes("edge"))

        driver.record(offset: 593, distance: 7)
        XCTAssertFalse(driver.isPinned, "Scrolling down short of the tolerance stays unpinned")
        driver.record(offset: 594, distance: 6)
        XCTAssertTrue(driver.isPinned, "Re-pins exactly at the tolerance")
        XCTAssertFalse(driver.executes("edge"))
    }

    // MARK: - C5 failure-count suffix

    func testFailureCountCountsEachFailedExecutionOnceAndExcludesPendingAndCancelled() {
        let laneEnvelope = Self.failedLaneEnvelope
        let rows: [(label: String, execution: AgentTranscriptToolExecution, failed: Bool)] = [
            ("failed tool", execution("read_file", status: .failed, isError: true), true),
            ("cancelled tool", execution("read_file", status: .cancelled, isError: true), false),
            ("pending tool", execution("read_file", status: .pending), false),
            ("running tool", execution("bash", status: .running), false),
            ("successful tool", execution("read_file", status: .success), false),
            ("Oracle wait envelope with a failed lane", execution("ask_oracle", status: .success, result: laneEnvelope), true),
            ("oracle_send with retained errors", execution("oracle_send", status: .success, result: #"{"status":"success","errors":[{"message":"boom"}]}"#), true),
            ("Oracle success", execution("ask_oracle", status: .success, result: #"{"status":"success","chat_id":"c"}"#), false),
            ("Oracle pending envelope", execution("ask_oracle", status: .pending, result: #"{"status":"pending","operation_id":"o"}"#), false),
            ("non-Oracle result shaped like a lane envelope", execution("read_file", status: .success, result: laneEnvelope), false)
        ]
        for row in rows {
            XCTAssertEqual(AgentTranscriptToolFailureCount.isFailed(row.execution), row.failed, row.label)
        }
        XCTAssertEqual(AgentTranscriptToolFailureCount.failedExecutionCount(rows.map(\.execution)), 3)
        XCTAssertNil(AgentTranscriptToolFailureCount.storedFailedCount([rows[4].execution]))
        XCTAssertNil(AgentTranscriptToolFailureCount.headerSuffix(failedCount: nil))
        XCTAssertNil(AgentTranscriptToolFailureCount.headerSuffix(failedCount: 0))
        XCTAssertEqual(AgentTranscriptToolFailureCount.headerSuffix(failedCount: 3), " • 3 failed")
    }

    func testGroupedHistorySummaryCountsFailuresAtTheProjectionBoundary() throws {
        let user = AgentChatItem.user("Review", sequenceIndex: 0)
        var items = [user]
        var sequenceIndex = 1
        func appendPair(_ name: String, result: String?, isError: Bool? = false) {
            let invocationID = UUID()
            items.append(.toolCall(name: name, invocationID: invocationID, argsJSON: "{}", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            if let result {
                items.append(.toolResult(
                    name: name,
                    invocationID: invocationID,
                    resultJSON: result,
                    isError: isError,
                    sequenceIndex: sequenceIndex
                ))
                sequenceIndex += 1
            }
        }
        // Grouped prefix: one failed call (call + result rows), a multi-lane Oracle wait with one
        // failed lane, a cancelled call, and a still-pending Oracle call.
        appendPair("read_file", result: #"{"status":"failed","error":"boom"}"#, isError: true)
        appendPair("ask_oracle", result: Self.failedLaneEnvelope)
        appendPair("read_file", result: #"{"status":"cancelled"}"#, isError: true)
        appendPair("ask_oracle", result: nil)
        for _ in 0 ..< 9 {
            appendPair("read_file", result: #"{"content":"ok"}"#)
        }

        let blocks = AgentTranscriptProjectionBuilder.blocks(
            for: AgentTranscriptIO.buildTranscript(from: items, compact: false)
        )
        let grouped = try XCTUnwrap(blocks.first { $0.kind == .groupedHistory })
        let toolSummary = try XCTUnwrap(grouped.groupedHistory?.summary.toolSummary)
        XCTAssertEqual(toolSummary.toolCount, 5)
        XCTAssertEqual(
            toolSummary.failedToolCount,
            2,
            "The failed call counts once and the Oracle lane failure once; cancelled and pending are excluded"
        )
        XCTAssertTrue(toolSummary.containsFailure)
        XCTAssertEqual(AgentTranscriptToolFailureCount.headerSuffix(failedCount: toolSummary.failedToolCount), " • 2 failed")
    }

    func testClusterSummaryFailedCountIsAdditiveAndOmittedAtZero() throws {
        let legacyJSON = #"{"toolCount":2,"toolNames":["read_file"],"toolNameCounts":{},"toolGroups":[],"keyPaths":[],"containsRunningWork":false,"containsFailure":true,"containsWarning":false}"#
        let legacy = try JSONDecoder().decode(AgentTranscriptClusterSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.failedToolCount, "Older summaries decode without claiming a count")
        XCTAssertNil(AgentTranscriptToolFailureCount.headerSuffix(failedCount: legacy.failedToolCount))

        let clean = AgentTranscriptClusterSummary(
            toolCount: 1,
            toolNames: ["read_file"],
            keyPaths: [],
            containsRunningWork: false,
            containsFailure: false,
            containsWarning: false,
            shortNarration: nil,
            failedToolCount: 0
        )
        XCTAssertNil(clean.failedToolCount)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(clean), encoding: .utf8))
        XCTAssertFalse(encoded.contains("failedToolCount"), "Summaries without failures encode as before")

        let failed = AgentTranscriptClusterSummary(
            toolCount: 3,
            toolNames: ["read_file"],
            keyPaths: [],
            containsRunningWork: false,
            containsFailure: true,
            containsWarning: false,
            shortNarration: nil,
            failedToolCount: 2
        )
        let roundTripped = try JSONDecoder().decode(
            AgentTranscriptClusterSummary.self,
            from: JSONEncoder().encode(failed)
        )
        XCTAssertEqual(roundTripped, failed)
        XCTAssertEqual(roundTripped.failedToolCount, 2)
    }

    // MARK: - Cluster summary ordering and merge

    /// One condensed span whose grouped-history tool summary covers every row. Executions interleave so
    /// the outer order (each execution's latest row by sequence, then timestamp, then row-ID string)
    /// differs from first-seen order; two execution pairs tie on sequence; one execution has an exact
    /// sequence-and-timestamp tie between its own rows; one latest row has no tool name and one uses a
    /// prefixed alias. Span activities arrive unsorted in the scrambled variant.
    func testClusterSummaryOrdersMergesAndNormalizesExecutionsAtTheProjectionBoundary() throws {
        let rows = Self.clusterSummaryOrderingRows()
        let expected = Self.expectedClusterSummary(
            toolCount: 8,
            toolNames: ["apply_edits", "file_search", "read_file", "get_code_structure", "get_file_tree"],
            toolNameCounts: ["apply_edits": 1, "file_search": 2, "read_file": 3, "get_code_structure": 1, "get_file_tree": 1],
            keyPaths: ["a1.swift", "a2.swift", "d.swift", "g2.swift", "g1.swift", "g3.swift"],
            containsRunningWork: true,
            containsFailure: true,
            containsWarning: true,
            shortNarration: String(repeating: "n", count: 120) + "…",
            failedToolCount: 1
        )
        let canonical = ["a1", "b1", "b2", "e1", "h1", "a2", "c1", "c2", "d1", "n1", "f1", "e2", "g1", "g2", "g3", "t1"]
        // Unsorted, with the cross-execution c2/d1 tie reversed; g2 stays before its exact tie g3.
        let scrambled = ["t1", "g2", "d1", "e2", "a2", "g3", "b2", "c2", "n1", "h1", "f1", "e1", "b1", "g1", "c1", "a1"]
        XCTAssertEqual(try Self.condensedToolSummary(canonical.map { rows[$0]! }), expected, "canonical order")
        XCTAssertEqual(try Self.condensedToolSummary(scrambled.map { rows[$0]! }), expected, "scrambled order")

        // An exact sequence-and-timestamp tie inside one execution keeps input order, so the later
        // input row is the latest execution and earlier rows merge into it in ascending order.
        let tieSwapped = canonical.map { $0 == "g2" ? "g3" : $0 == "g3" ? "g2" : $0 }
        XCTAssertEqual(
            try Self.condensedToolSummary(tieSwapped.map { rows[$0]! }),
            Self.expectedClusterSummary(
                toolCount: 8,
                toolNames: ["apply_edits", "file_search", "read_file", "get_code_structure", "get_file_tree"],
                toolNameCounts: ["apply_edits": 1, "file_search": 2, "read_file": 3, "get_code_structure": 1, "get_file_tree": 1],
                keyPaths: ["a1.swift", "a2.swift", "d.swift", "g3.swift", "g1.swift", "g2.swift"],
                containsRunningWork: true,
                containsFailure: false,
                containsWarning: true,
                shortNarration: String(repeating: "n", count: 120) + "…",
                failedToolCount: nil
            ),
            "exact tie resolved by input order"
        )
    }

    func testClusterSummaryWithoutToolsKeepsZeroAndNilSemantics() throws {
        let reply = AgentChatItem(
            timestamp: Self.clusterBaseDate,
            kind: .assistant,
            text: "  Short reply  ",
            sequenceIndex: 1
        )
        XCTAssertEqual(
            try Self.condensedToolSummary([reply]),
            Self.expectedClusterSummary(
                toolCount: 0,
                toolNames: [],
                toolNameCounts: [:],
                keyPaths: [],
                containsRunningWork: false,
                containsFailure: false,
                containsWarning: false,
                shortNarration: "Short reply",
                failedToolCount: nil
            )
        )
    }

    private static let clusterBaseDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func clusterSummaryOrderingRows() -> [String: AgentChatItem] {
        func invocation(_ suffix: String) -> UUID {
            UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
        }
        func tool(
            _ kind: AgentChatItemKind,
            _ name: String?,
            _ invocationID: UUID?,
            args: String? = nil,
            result: String? = nil,
            isError: Bool? = nil,
            sequence: Int,
            at offset: TimeInterval? = nil,
            id: UUID = UUID()
        ) -> AgentChatItem {
            AgentChatItem(
                id: id,
                timestamp: clusterBaseDate.addingTimeInterval(offset ?? TimeInterval(sequence)),
                kind: kind,
                text: "",
                toolName: name,
                toolInvocationID: invocationID,
                toolArgsJSON: args,
                toolResultJSON: result,
                toolIsError: isError,
                sequenceIndex: sequence
            )
        }
        let (a, b, c, d, e, f, g) = (invocation("A1"), invocation("B1"), invocation("C1"), invocation("D1"), invocation("E1"), invocation("F1"), invocation("A7"))
        return [
            "a1": tool(.toolCall, "read_file", a, args: #"{"path":"a1.swift"}"#, sequence: 1),
            "b1": tool(.toolCall, "apply_edits", b, args: #"{"edits":[]}"#, sequence: 2),
            // The latest B row has no tool name; the merge fills it from the call before normalization.
            "b2": tool(.toolResult, nil, b, result: #"{"status":"success"}"#, sequence: 3),
            "e1": tool(.toolCall, "get_file_tree", e, args: #"{"depth":1}"#, sequence: 4),
            // No invocation ID: grouped by its own content-derived execution ID.
            "h1": tool(.toolCall, "file_search", nil, args: #"{"pattern":"needle"}"#, sequence: 5),
            "a2": tool(.toolResult, "read_file", a, args: #"{"path":"a2.swift"}"#, result: #"{"content":"ok"}"#, isError: false, sequence: 6),
            "c1": tool(.toolCall, "get_code_structure", c, args: #"{"symbol":"Widget"}"#, sequence: 7),
            // c2 and d1 tie on sequence and timestamp; the smaller row-ID string (d1) orders first.
            "c2": tool(
                .toolResult,
                "get_code_structure",
                c,
                result: #"{"status":"success"}"#,
                sequence: 8,
                id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
            ),
            "d1": tool(
                .toolCall,
                "mcp__RepoPromptCE__read_file",
                d,
                args: #"{"path":"d.swift"}"#,
                sequence: 8,
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            "n1": AgentChatItem(timestamp: clusterBaseDate.addingTimeInterval(9), kind: .assistant, text: String(repeating: "n", count: 130), sequenceIndex: 9),
            // f1 and e2 tie on sequence; the earlier timestamp (f1) orders first.
            "f1": tool(.toolCall, "read_file", f, args: #"{"pattern":"f"}"#, sequence: 10, at: 10),
            "e2": tool(.toolResult, "get_file_tree", e, result: #"{"status":"warning"}"#, sequence: 10, at: 10.5),
            "g1": tool(.toolCall, "file_search", g, args: #"{"path":"g1.swift"}"#, sequence: 11),
            "g2": tool(.toolResult, "file_search", g, args: #"{"path":"g2.swift"}"#, result: #"{"status":"running"}"#, sequence: 12),
            "g3": tool(.toolResult, "file_search", g, args: #"{"path":"g3.swift"}"#, result: #"{"status":"failed"}"#, isError: true, sequence: 12),
            "t1": AgentChatItem(timestamp: clusterBaseDate.addingTimeInterval(13), kind: .thinking, text: "Later thinking", sequenceIndex: 13)
        ]
    }

    /// Projects `items` as one condensed span (activities kept in the given order, raw tool names
    /// preserved) and returns the grouped-history tool summary.
    private static func condensedToolSummary(_ items: [AgentChatItem]) throws -> AgentTranscriptClusterSummary {
        let activities = items.map { item -> AgentTranscriptActivity in
            guard var execution = AgentTranscriptToolNormalizer.toolExecution(for: item) else {
                return AgentTranscriptActivity(from: item)
            }
            execution.toolName = item.toolName
            return AgentTranscriptActivity(from: item, toolExecution: execution)
        }
        let turn = AgentTranscriptTurn(
            responseSpans: [AgentTranscriptProviderResponseSpan(startedAt: clusterBaseDate, activities: activities)],
            retentionTier: .condensed,
            startedAt: clusterBaseDate
        )
        let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
        let grouped = try XCTUnwrap(blocks.first { $0.kind == .groupedHistory })
        return try XCTUnwrap(grouped.groupedHistory?.summary.toolSummary)
    }

    private static func expectedClusterSummary(
        toolCount: Int,
        toolNames: [String],
        toolNameCounts: [String: Int],
        keyPaths: [String],
        containsRunningWork: Bool,
        containsFailure: Bool,
        containsWarning: Bool,
        shortNarration: String?,
        failedToolCount: Int?
    ) -> AgentTranscriptClusterSummary {
        let toolGroups = ClusterToolCategory.buildGroups(
            toolNames: toolNameCounts.isEmpty ? toolNames : toolNameCounts.keys.sorted(),
            counts: toolNameCounts
        )
        let base = AgentTranscriptClusterSummary(
            toolCount: toolCount,
            toolNames: toolNames,
            toolNameCounts: toolNameCounts,
            toolGroups: toolGroups,
            keyPaths: keyPaths,
            containsRunningWork: containsRunningWork,
            containsFailure: containsFailure,
            containsWarning: containsWarning,
            shortNarration: shortNarration,
            failedToolCount: failedToolCount
        )
        return AgentTranscriptClusterSummary(
            toolCount: toolCount,
            toolNames: toolNames,
            toolNameCounts: toolNameCounts,
            toolGroups: toolGroups,
            keyPaths: keyPaths,
            containsRunningWork: containsRunningWork,
            containsFailure: containsFailure,
            containsWarning: containsWarning,
            shortNarration: shortNarration,
            collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(for: base, fallbackCount: toolCount),
            failedToolCount: failedToolCount
        )
    }

    // MARK: - Helpers

    /// Drives a plain `AgentTranscriptInnerFollowState` and an `AgentTranscriptInnerFollowTracker`
    /// through the same operations, asserting equal state and equal results for every issued
    /// ticket after each one. Queries return the plain state's result.
    @MainActor
    private final class InnerFollowParityDriver {
        private var plain: AgentTranscriptInnerFollowState
        private let tracker: AgentTranscriptInnerFollowTracker
        private var tickets: [(name: String, ticket: Int)] = []
        private var step = 0

        init(isLive: Bool, file: StaticString = #filePath, line: UInt = #line) {
            plain = AgentTranscriptInnerFollowState(isLive: isLive)
            tracker = AgentTranscriptInnerFollowTracker(isLive: isLive)
            verify("init(isLive: \(isLive))", file: file, line: line)
        }

        var isPinned: Bool {
            plain.isPinned
        }

        func record(offset: CGFloat, distance: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
            let position = AgentTranscriptInnerFollowPolicy.Position(offsetY: offset, distanceToBottom: distance)
            plain.record(position)
            tracker.record(position)
            verify("record(\(offset), \(distance))", file: file, line: line)
        }

        func setLive(_ live: Bool, file: StaticString = #filePath, line: UInt = #line) {
            plain.setLive(live)
            tracker.setLive(live)
            verify("setLive(\(live))", file: file, line: line)
        }

        func scheduleFollow(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Int? {
            let expected = plain.scheduleFollow()
            let actual = tracker.scheduleFollow()
            XCTAssertEqual(actual, expected, "scheduleFollow(\(name))", file: file, line: line)
            if let expected {
                tickets.append((name, expected))
            }
            verify("scheduleFollow(\(name))", file: file, line: line)
            return expected
        }

        func executes(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            guard let ticket = tickets.last(where: { $0.name == name })?.ticket else {
                XCTFail("No ticket named \(name)", file: file, line: line)
                return false
            }
            let expected = plain.shouldExecuteFollow(ticket)
            XCTAssertEqual(tracker.shouldExecuteFollow(ticket), expected, "ticket \(name)", file: file, line: line)
            return expected
        }

        private func verify(_ operation: String, file: StaticString, line: UInt) {
            step += 1
            XCTAssertEqual(tracker.state, plain, "step \(step) \(operation): state", file: file, line: line)
            for (name, ticket) in tickets {
                XCTAssertEqual(
                    tracker.shouldExecuteFollow(ticket),
                    plain.shouldExecuteFollow(ticket),
                    "step \(step) \(operation): ticket \(name)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private static let failedLaneEnvelope =
        #"{"results":[{"index":0,"status":"completed","chat_id":"lane-0","response":"done"},{"index":1,"ok":false,"status":"failed","chat_id":"lane-1","error":{"code":"oracle_stream_failed","message":"Lane one stream failed"}}],"wait":{"result":"completed_with_errors","pending_operation_ids":[]}}"#

    private func execution(
        _ toolName: String,
        status: AgentTranscriptToolStatus,
        isError: Bool? = false,
        result: String? = nil
    ) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: UUID().uuidString,
            toolName: toolName,
            invocationID: nil,
            argsJSON: nil,
            resultJSON: result,
            toolIsError: isError,
            status: status
        )
    }

    private func rowCount(_ block: AgentTranscriptRenderBlock) -> Int {
        block.groupedHistory?.sections.reduce(0) { partial, section in
            partial + section.childBlocks.reduce(0) { $0 + $1.rows.count }
        } ?? 0
    }
}
