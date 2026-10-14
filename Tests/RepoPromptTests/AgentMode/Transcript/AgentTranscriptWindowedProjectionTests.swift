import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTranscriptWindowedProjectionTests: XCTestCase {
    func testLargeTranscriptProjectionEmitsCollapsedRangeAndFullTail() {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: AgentTranscriptProjectionBuilder.workingProjection(from: projection),
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertEqual(windowed.workingBlocks.first?.kind, .collapsedHistoryRange)
        XCTAssertEqual(windowed.workingBlocks.first?.collapsedHistoryRange?.hiddenTurnCount, 5)
        XCTAssertEqual(windowed.workingBlocks.first?.id, "collapsed-range:\(transcript.turns[0].id.uuidString)")
        XCTAssertEqual(windowed.workingBlocks.count(where: { $0.kind != .collapsedHistoryRange }), 80)
        XCTAssertEqual(windowed.workingRows.count, 80)
        XCTAssertEqual(orderedUniqueTurnIDs(windowed.workingBlocks.filter { $0.kind != .collapsedHistoryRange }.map(\.turnID)), transcript.turns.suffix(40).map(\.id))
    }

    func testOpenTurnRemainsVisibleEvenWhenOlderThanTail() {
        var transcript = makeTranscript(turnCount: 45)
        transcript.turns[0] = makeTurn(index: 0, completed: false)
        let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: AgentTranscriptProjectionBuilder.workingProjection(from: projection),
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertTrue(windowed.workingBlocks.contains { $0.turnID == transcript.turns[0].id && $0.kind != .collapsedHistoryRange })
        XCTAssertEqual(windowed.workingBlocks.first(where: { $0.kind == .collapsedHistoryRange })?.collapsedHistoryRange?.hiddenTurnCount, 4)
    }

    func testExpandedFlagRestoresExactProjectionRowsAndBlocks() {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: transcript)
        )

        let expanded = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: projection,
            transcript: transcript,
            isExpanded: true
        )

        XCTAssertEqual(expanded, projection)
    }

    func testAppendingNewMessagesPreservesStableCollapsedRangeIDAndFullTail() {
        let initialTranscript = makeTranscript(turnCount: 45)
        let updatedTranscript = makeTranscript(turnCount: 46, turnIDs: initialTranscript.turns.map(\.id) + [UUID()])
        let initialProjection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: initialTranscript)
        )
        let updatedProjection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: updatedTranscript)
        )

        let initialWindowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: initialProjection,
            transcript: initialTranscript,
            isExpanded: false
        )
        let updatedWindowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: updatedProjection,
            transcript: updatedTranscript,
            isExpanded: false
        )

        XCTAssertEqual(initialWindowed.workingBlocks.first?.id, updatedWindowed.workingBlocks.first?.id)
        XCTAssertEqual(updatedWindowed.workingBlocks.count(where: { $0.kind != .collapsedHistoryRange }), 80)
        XCTAssertEqual(updatedWindowed.workingBlocks.last?.turnID, updatedTranscript.turns.last?.id)
    }

    func testHiddenAnchorRemapsToCollapsedRangeAndVisibleAnchorsRemainUnchanged() throws {
        let transcript = makeTranscript(turnCount: 45)
        let projection = AgentTranscriptProjectionBuilder.workingProjection(
            from: AgentTranscriptProjectionBuilder.build(from: transcript)
        )
        let hiddenAnchor = AgentTranscriptAnchor.request(turnID: transcript.turns[0].id)
        let visibleAnchor = AgentTranscriptAnchor.request(turnID: transcript.turns[44].id)
        let originalVisibleBlockID = try XCTUnwrap(projection.anchorBlockIndex[visibleAnchor])

        let windowed = AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: projection,
            transcript: transcript,
            isExpanded: false
        )

        XCTAssertEqual(windowed.anchorBlockIndex[hiddenAnchor], "collapsed-range:\(transcript.turns[0].id.uuidString)")
        XCTAssertEqual(windowed.anchorBlockIndex[visibleAnchor], originalVisibleBlockID)
    }

    // MARK: - Backing-row integrity

    /// Real builds across retention tiers, protection, and cached rebuilds present the
    /// transcript-derived counts with every required backing row; grouped cards count once with
    /// no backing rows. Intentional display windowing is outside backing-projection validation.
    func testBackingProjectionsMatchTranscriptCountsAndCarryRequiredRows() throws {
        let compacted = AgentTranscriptIO.buildTranscript(from: groupedToolItems(turnCount: 48), terminalState: .completed)
        var tiered = AgentTranscriptIO.buildTranscript(
            from: groupedToolItems(turnCount: 46),
            terminalState: .completed,
            compact: false
        )
        let tiers: [AgentTranscriptRetentionTier] = [.archived, .archived, .summary, .summary, .condensed, .condensed]
        for (index, tier) in tiers.enumerated() {
            tiered.turns[index].retentionTier = tier
        }
        XCTAssertEqual(Set(tiered.turns.map(\.retentionTier)), Set(AgentTranscriptRetentionTier.allCases))
        XCTAssertTrue(compacted.turns.contains { $0.retentionTier != .full }, "real compaction retained tiers")

        for (name, transcript) in [("compacted", compacted), ("tiered", tiered)] {
            let lastTurnID = try XCTUnwrap(transcript.turns.last?.id)
            for protection in [AgentTranscriptProjectionProtection.none, .protectedTurn(lastTurnID)] {
                let step = "\(name) \(protection)"
                let first = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, protection: protection, turnCaches: [:])
                let cached = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: transcript,
                    protection: protection,
                    turnCaches: first.updatedTurnCaches
                ).projection
                let expected = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
                for full in [first.projection, cached] {
                    let working = AgentTranscriptProjectionBuilder.workingProjection(from: full)
                    XCTAssertTrue(full.workingBlocks.contains { $0.kind == .groupedHistory && $0.rows.isEmpty }, step)
                    XCTAssertEqual(AgentTranscriptProjectionBuilder.projectionCounts(for: full), expected, step)
                    XCTAssertEqual(
                        AgentTranscriptProjectionBuilder.projectionCounts(for: working),
                        .init(
                            canonicalVisibleRowCount: expected.defaultPresentedRowCount,
                            defaultPresentedRowCount: expected.defaultPresentedRowCount
                        ),
                        step
                    )
                    XCTAssertLessThan(full.workingRows.count, expected.defaultPresentedRowCount, "[\(step)] unlike units")
                    for projection in [full, working] {
                        XCTAssertTrue(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(for: projection), step)
                    }
                }
            }
        }
        XCTAssertFalse(
            AgentTranscriptProjectionBuilder.build(from: tiered).archivedRows.isEmpty,
            "the tiered fixture exercises the archived lane"
        )
    }

    /// The persistent storage pipeline's own full (unwindowed) projection yields the same projection
    /// counts as the transcript count walk over its paired output transcript, across protection,
    /// every retention tier, grouped history, and the archived lane. The save entry compacts first
    /// (re-tiering condensed turns here), so the normalized entry carries condensed into the same
    /// persistent materialization.
    func testPersistentPipelineProjectionCountsMatchPairedTranscriptCountWalk() throws {
        let compacted = AgentTranscriptIO.buildTranscript(from: groupedToolItems(turnCount: 48), terminalState: .completed)
        var tiered = AgentTranscriptIO.buildTranscript(
            from: groupedToolItems(turnCount: 46),
            terminalState: .completed,
            compact: false
        )
        let tiers: [AgentTranscriptRetentionTier] = [.archived, .archived, .summary, .summary, .condensed, .condensed]
        for (index, tier) in tiers.enumerated() {
            tiered.turns[index].retentionTier = tier
        }

        var results: [(String, AgentTranscriptPolicyPipeline.Result)] = []
        for (name, transcript) in [("compacted", compacted), ("tiered", tiered)] {
            let lastTurnID = try XCTUnwrap(transcript.turns.last?.id)
            for protection in [AgentTranscriptProjectionProtection.none, .protectedTurn(lastTurnID)] {
                results.append(("\(name) \(protection)", AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript, protection: protection)))
            }
        }
        let normalizedTiered = AgentTranscriptPolicyPipeline.persistedNormalizedTranscript(tiered)
        results.append(("tiered normalized", normalizedTiered))

        for (step, result) in results {
            XCTAssertEqual(
                AgentTranscriptProjectionBuilder.projectionCounts(for: result.projection),
                AgentTranscriptProjectionBuilder.projectionCounts(for: result.transcript),
                step
            )
            XCTAssertTrue(result.transcript.turns.contains { $0.retentionTier == .full }, step)
            XCTAssertTrue(result.transcript.turns.contains { $0.retentionTier != .full }, "[\(step)] retained tiers survive")
            XCTAssertTrue(result.projection.workingBlocks.contains { $0.kind == .groupedHistory }, "[\(step)] grouped history survives")
        }
        XCTAssertEqual(
            Set(normalizedTiered.transcript.turns.map(\.retentionTier)),
            Set(AgentTranscriptRetentionTier.allCases),
            "every retention tier survives persistent materialization"
        )
        XCTAssertFalse(normalizedTiered.projection.archivedRows.isEmpty, "the archived lane survives persistent materialization")
        let tieredSave = try XCTUnwrap(results.first { $0.0.hasPrefix("tiered") }?.1)
        XCTAssertFalse(tieredSave.projection.archivedRows.isEmpty, "the archived lane survives the save entry")
    }

    /// A multi-row cluster is one presented card that still requires all its rows; a cold-load
    /// degraded cluster keeps backing rows its block no longer lists. Missing, substituted, or
    /// reordered required rows fail in either lane.
    func testBackingRowConsistencyRejectsMissingSubstitutedOrReorderedRequiredRows() {
        let clusterRows = (0 ..< 3).map { AgentChatItem.assistant("cluster \($0)", sequenceIndex: $0) }
        func cluster(_ rows: [AgentChatItem]) -> AgentTranscriptRenderBlock {
            AgentTranscriptRenderBlock(
                id: "cluster",
                kind: .activityCluster,
                turnID: UUID(),
                retentionTier: .full,
                rows: rows,
                isArchived: false,
                defaultPresentation: .collapsed
            )
        }
        let clustered = AgentTranscriptProjection(workingBlocks: [cluster(clusterRows)], workingRows: clusterRows)
        XCTAssertEqual(AgentTranscriptProjectionBuilder.projectionCounts(for: clustered).defaultPresentedRowCount, 1)
        XCTAssertTrue(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(for: clustered))
        XCTAssertTrue(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(
            for: AgentTranscriptProjection(workingBlocks: [cluster([])], workingRows: clusterRows)
        ), "cold-load degraded cluster")
        XCTAssertTrue(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(for: .empty))

        var tiered = AgentTranscriptIO.buildTranscript(from: groupedToolItems(turnCount: 4), terminalState: .completed, compact: false)
        tiered.turns[0].retentionTier = .archived
        let valid = AgentTranscriptProjectionBuilder.build(from: tiered)
        XCTAssertTrue(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(for: valid))
        XCTAssertGreaterThanOrEqual(valid.archivedRows.count, 2)
        XCTAssertGreaterThanOrEqual(valid.workingRows.count, 2)

        func substitute(_ row: AgentChatItem) -> AgentChatItem {
            .assistant("substitute", sequenceIndex: row.sequenceIndex)
        }
        let corruptions: [(String, (inout AgentTranscriptProjection) -> Void)] = [
            ("cluster row missing", { $0 = AgentTranscriptProjection(workingBlocks: [cluster(clusterRows)], workingRows: Array(clusterRows.dropLast())) }),
            ("working row missing", { $0.workingRows.removeLast() }),
            ("working row substituted", { $0.workingRows[1] = substitute($0.workingRows[1]) }),
            ("working rows reordered", { $0.workingRows.swapAt(0, 1) }),
            ("archived row missing", { $0.archivedRows.removeFirst() }),
            ("archived row substituted", { $0.archivedRows[0] = substitute($0.archivedRows[0]) })
        ]
        for (step, corrupt) in corruptions {
            var projection = valid
            corrupt(&projection)
            XCTAssertFalse(AgentTranscriptProjectionBuilder.hasConsistentBackingRows(for: projection), step)
        }
    }

    private func groupedToolItems(turnCount: Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        for turn in 0 ..< turnCount {
            items.append(.user("request \(turn)", sequenceIndex: items.count))
            for _ in 0 ..< 12 {
                let invocationID = UUID()
                items.append(.toolCall(
                    name: "read_file",
                    invocationID: invocationID,
                    argsJSON: #"{"path":"/tmp/file.swift"}"#,
                    sequenceIndex: items.count
                ))
                items.append(.toolResult(
                    name: "read_file",
                    invocationID: invocationID,
                    resultJSON: #"{"content":"ok"}"#,
                    sequenceIndex: items.count
                ))
            }
            items.append(.assistant("answer \(turn)", sequenceIndex: items.count))
        }
        return items
    }

    private func orderedUniqueTurnIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    private func makeTranscript(turnCount: Int, turnIDs: [UUID]? = nil) -> AgentTranscript {
        AgentTranscript(
            turns: (0 ..< turnCount).map { index in
                makeTurn(index: index, id: turnIDs?[index] ?? UUID())
            },
            nextSequenceIndex: turnCount * 2
        )
    }

    private func makeTurn(index: Int, id: UUID = UUID(), completed: Bool = true) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(index))
        let user = AgentChatItem.user("request \(index)", sequenceIndex: index * 2)
        let assistant = AgentChatItem.assistant("response \(index)", sequenceIndex: index * 2 + 1)
        let activity = AgentTranscriptActivity(from: assistant)
        let completedAt = completed ? startedAt.addingTimeInterval(1) : nil
        return AgentTranscriptTurn(
            id: id,
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: completed ? .completed : .open,
                    startedAt: startedAt,
                    lastActivityAt: completedAt,
                    completedAt: completedAt,
                    activities: [activity]
                )
            ],
            retentionTier: .full,
            terminalState: completed ? .completed : .running,
            startedAt: startedAt,
            lastActivityAt: completedAt,
            completedAt: completedAt
        )
    }
}
