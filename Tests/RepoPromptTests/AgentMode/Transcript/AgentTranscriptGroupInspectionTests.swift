import Foundation
@testable import RepoPromptApp
import XCTest

/// Oracle failure inspection plan, Patch C: live group expansion, flattened lazy entries,
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

    // MARK: - Helpers

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
