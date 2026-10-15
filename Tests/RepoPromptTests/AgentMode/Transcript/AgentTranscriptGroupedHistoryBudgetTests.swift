import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTranscriptGroupedHistoryBudgetTests: XCTestCase {
    func testProjectionCachesPreserveAnchorIndexesOnReuse() throws {
        var sequenceIndex = 0
        let items = makeTurnItems(label: "older", toolCount: 10, sequenceIndex: &sequenceIndex)
            + makeTurnItems(label: "newer", toolCount: 4, sequenceIndex: &sequenceIndex)
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let refreshedTranscript = AgentTranscriptProjectionBuilder
            .refreshCompletedFullTurnGroupedHistoryCaches(in: transcript)

        let coldBuild = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: refreshedTranscript,
            turnCaches: [:]
        )
        let cachedBuild = AgentTranscriptProjectionBuilder.buildWithCaches(
            from: refreshedTranscript,
            turnCaches: coldBuild.updatedTurnCaches
        )

        XCTAssertEqual(coldBuild.updatedTurnCaches.count, refreshedTranscript.turns.count)
        for turn in refreshedTranscript.turns {
            let cache = try XCTUnwrap(coldBuild.updatedTurnCaches[turn.id])
            XCTAssertTrue(cache.rowAnchorIndex.values.allSatisfy { anchorTurnID($0) == turn.id })
            XCTAssertTrue(cache.anchorBlockIndex.keys.allSatisfy { anchorTurnID($0) == turn.id })
        }
        XCTAssertFalse(coldBuild.projection.rowAnchorIndex.isEmpty)
        XCTAssertFalse(coldBuild.projection.anchorBlockIndex.isEmpty)
        XCTAssertEqual(cachedBuild.projection, coldBuild.projection)
        XCTAssertEqual(cachedBuild.updatedTurnCaches, coldBuild.updatedTurnCaches)
    }

    func testReusablePrefixCacheTightensWhenNewerTurnConsumesDetailedToolBudget() throws {
        var sequenceIndex = 0
        let olderItems = makeTurnItems(label: "older", toolCount: 10, sequenceIndex: &sequenceIndex)
        let initialNewerItems = makeTurnItems(label: "newer", toolCount: 1, sequenceIndex: &sequenceIndex)
        let initialItems = olderItems + initialNewerItems
        let initialTranscript = AgentTranscriptIO.buildTranscript(
            from: initialItems,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let refreshedInitial = AgentTranscriptProjectionBuilder
            .refreshCompletedFullTurnGroupedHistoryCaches(in: initialTranscript)
        XCTAssertEqual(refreshedInitial.turns.count, 2)
        let initialOlderLimit = try XCTUnwrap(
            refreshedInitial.turns[0].responseSpans
                .compactMap(\.fullRenderGroupedHistoryCache?.detailedToolTailLimit)
                .first
        )
        XCTAssertEqual(initialOlderLimit, 7)

        var updatedSequenceIndex = olderItems.count
        let updatedNewerItems = makeTurnItems(
            label: "newer-updated",
            toolCount: 5,
            sequenceIndex: &updatedSequenceIndex,
            userItem: initialNewerItems[0]
        )
        let updatedNewerTranscript = AgentTranscriptIO.buildTranscript(
            from: updatedNewerItems,
            terminalState: .completed,
            nextSequenceIndex: updatedSequenceIndex,
            compact: false
        )
        var incrementallyUpdated = refreshedInitial
        incrementallyUpdated.turns[1] = try XCTUnwrap(updatedNewerTranscript.turns.first)
        incrementallyUpdated.nextSequenceIndex = updatedSequenceIndex

        let refreshedUpdated = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: incrementallyUpdated,
            reusablePrefixTurnCount: 1
        )
        let shiftedOlderLimit = try XCTUnwrap(
            refreshedUpdated.turns[0].responseSpans
                .compactMap(\.fullRenderGroupedHistoryCache?.detailedToolTailLimit)
                .first
        )

        XCTAssertEqual(shiftedOlderLimit, 3)
        XCTAssertEqual(refreshedUpdated.turns[0].frozenDetailedToolTailLimit, 3)
    }

    func testPairedStorageProjectionMatchesSequentialForMultiSpanDuplicateConclusionsAndSuppressedActivities() throws {
        var sequenceIndex = 0
        // Each split span keeps more standalone tools than the older turn's remaining budget.
        let olderItems = makeTurnItems(label: "older", toolCount: 20, sequenceIndex: &sequenceIndex)
        let newerItems = makeTurnItems(label: "newer", toolCount: 2, sequenceIndex: &sequenceIndex)
        var transcript = AgentTranscriptIO.buildTranscript(
            from: olderItems + newerItems,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        XCTAssertEqual(transcript.turns.count, 2)
        var older = transcript.turns[0]
        XCTAssertEqual(older.responseSpans.count, 1)
        let conclusionID = try XCTUnwrap(older.conclusionActivityID)
        let activities = older.responseSpans[0].activities
        let conclusion = try XCTUnwrap(activities.first { $0.id == conclusionID })
        let splitIndex = activities.count / 2
        let displaylessAssistant = AgentTranscriptActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            sequenceIndex: activities[splitIndex].sequenceIndex,
            role: .assistant,
            itemKind: .assistant,
            text: "   "
        )
        // Span 0 carries the first half plus a duplicate of the conclusion; span 1 the rest.
        older.responseSpans[0].activities = Array(activities.prefix(splitIndex)) + [conclusion, displaylessAssistant]
        older.responseSpans.append(AgentTranscriptProviderResponseSpan(
            lifecycle: older.responseSpans[0].lifecycle,
            startedAt: Date(timeIntervalSince1970: 0),
            activities: Array(activities.dropFirst(splitIndex))
        ))
        transcript.turns[0] = older

        let preparedTurns = assertPairedStorageMatchesSequential(transcript)
        XCTAssertEqual(preparedTurns, 2)
        let sanitizedInput = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript
        XCTAssertTrue(
            sanitizedInput.turns[0].allActivities.contains { $0.id == displaylessAssistant.id },
            "The suppressed activity reaches the storage refresh"
        )
        XCTAssertEqual(sanitizedInput.turns[0].responseSpans.count, 2)
        let refreshed = AgentTranscriptProjectionBuilder.refreshGroupedHistoryAndBuildStorageProjection(
            in: sanitizedInput
        )
        XCTAssertTrue(
            refreshed.transcript.turns[0].responseSpans.contains { $0.fullRenderGroupedHistoryCache != nil },
            "The fixture collapses grouped history"
        )
        let conclusionBlocks = refreshed.projection.workingBlocks.filter { $0.kind == .conclusion && $0.anchorActivityID == conclusionID }
        XCTAssertEqual(conclusionBlocks.count, 1, "The duplicated conclusion is emitted once")
        XCTAssertFalse(
            refreshed.projection.workingRows.contains { $0.id == displaylessAssistant.id },
            "Suppressed activities stay out of the projection"
        )
    }

    func testPairedStorageProjectionMatchesSequentialAcrossTiersCachesAndIneligibleTurns() throws {
        let transcript = makeMixedTierTranscript()
        XCTAssertEqual(
            transcript.turns.map(\.retentionTier),
            [.full, .condensed, .summary, .archived, .full, .full, .full]
        )

        // Nil caches: 2 eligible turns (collapsing and no-collapse); open-span and incomplete fall back.
        XCTAssertEqual(assertPairedStorageMatchesSequential(transcript), 2)

        // Persistence sanitization drops the in-memory span caches, so matching and stale caches are
        // applied to the already-sanitized input.
        let sanitizedInput = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript
        let matching = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: sanitizedInput)
        XCTAssertTrue(matching.turns[0].responseSpans.contains { $0.fullRenderGroupedHistoryCache != nil })
        XCTAssertEqual(assertPairedStorageMatchesSequential(matching, isSanitized: true), 2)

        // Stale cache digest.
        var stale = matching
        let staleSpanIndex = try XCTUnwrap(stale.turns[0].responseSpans.firstIndex { $0.fullRenderGroupedHistoryCache != nil })
        let cache = try XCTUnwrap(stale.turns[0].responseSpans[staleSpanIndex].fullRenderGroupedHistoryCache)
        stale.turns[0].responseSpans[staleSpanIndex].fullRenderGroupedHistoryCache = .init(
            detailedToolTailLimit: cache.detailedToolTailLimit,
            collapseDigest: "stale",
            summary: cache.summary
        )
        XCTAssertEqual(assertPairedStorageMatchesSequential(stale, isSanitized: true), 2)

        // Storage pipeline smoke: sanitized count and outputs match the sequential path.
        let pipeline = AgentTranscriptPolicyPipeline.persistedNormalizedTranscript(transcript)
        let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(
            AgentTranscriptHistoricalTruncationPolicy.truncatedTranscript(transcript)
        )
        let sequentialTranscript = AgentTranscriptProjectionBuilder
            .refreshCompletedFullTurnGroupedHistoryCaches(in: sanitized.transcript)
        XCTAssertEqual(pipeline.sanitizedActivityCount, sanitized.sanitizedActivityCount)
        XCTAssertEqual(pipeline.transcript, sequentialTranscript)
        XCTAssertEqual(pipeline.projection, AgentTranscriptProjectionBuilder.build(from: sequentialTranscript))
    }

    func testPairedStorageProjectionMatchesSequentialWhenNewerTurnTightensBudgetAndWhenEmpty() throws {
        var sequenceIndex = 0
        let olderItems = makeTurnItems(label: "older", toolCount: 10, sequenceIndex: &sequenceIndex)
        let initialNewerItems = makeTurnItems(label: "newer", toolCount: 1, sequenceIndex: &sequenceIndex)
        let refreshedInitial = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: AgentTranscriptIO.buildTranscript(
                from: olderItems + initialNewerItems,
                terminalState: .completed,
                nextSequenceIndex: sequenceIndex,
                compact: false
            )
        )
        XCTAssertEqual(refreshedInitial.turns[0].frozenDetailedToolTailLimit, 7)
        var updatedSequenceIndex = olderItems.count
        let updatedNewer = AgentTranscriptIO.buildTranscript(
            from: makeTurnItems(
                label: "newer-updated",
                toolCount: 5,
                sequenceIndex: &updatedSequenceIndex,
                userItem: initialNewerItems[0]
            ),
            terminalState: .completed,
            nextSequenceIndex: updatedSequenceIndex,
            compact: false
        )
        var tightened = refreshedInitial
        tightened.turns[1] = try XCTUnwrap(updatedNewer.turns.first)
        tightened.nextSequenceIndex = updatedSequenceIndex

        XCTAssertEqual(assertPairedStorageMatchesSequential(tightened), 2)
        let paired = AgentTranscriptProjectionBuilder.refreshGroupedHistoryAndBuildStorageProjection(
            in: AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(tightened).transcript
        )
        XCTAssertEqual(paired.transcript.turns[0].frozenDetailedToolTailLimit, 3)

        let empty = AgentTranscriptIO.buildTranscript(from: [], terminalState: .completed, compact: false)
        XCTAssertTrue(empty.turns.isEmpty)
        XCTAssertEqual(assertPairedStorageMatchesSequential(empty), 0)
    }

    func testPairedStorageProjectionUsesPreparedLeavesForSuppressedWhitespaceConclusion() throws {
        var sequenceIndex = 0
        var transcript = AgentTranscriptIO.buildTranscript(
            from: makeTurnItems(label: "whitespace-conclusion", toolCount: 10, sequenceIndex: &sequenceIndex),
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let conclusionID = try XCTUnwrap(transcript.turns[0].conclusionActivityID)
        let spanIndex = try XCTUnwrap(transcript.turns[0].responseSpans.firstIndex {
            $0.activities.contains { $0.id == conclusionID }
        })
        let activityIndex = try XCTUnwrap(transcript.turns[0].responseSpans[spanIndex].activities.firstIndex {
            $0.id == conclusionID
        })
        transcript.turns[0].responseSpans[spanIndex].activities[activityIndex].text = "   "
        transcript.turns[0].summary = nil
        let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript
        XCTAssertEqual(sanitized.turns[0].allActivities.first { $0.id == conclusionID }?.text, "   ")
        XCTAssertNil(sanitized.turns[0].summary)

        XCTAssertEqual(assertPairedStorageMatchesSequential(sanitized, isSanitized: true), 1, "Prepared leaves are used")
        let paired = AgentTranscriptProjectionBuilder.refreshGroupedHistoryAndBuildStorageProjection(in: sanitized)
        // Existing fallback outcome: the suppressed conclusion emits no leaf, and the fallback finds
        // no displayable conclusion text, so the turn has no conclusion block or row.
        XCTAssertFalse(paired.projection.workingBlocks.contains { $0.kind == .conclusion })
        XCTAssertFalse(paired.projection.workingRows.contains { $0.id == conclusionID })
        XCTAssertTrue(paired.projection.workingBlocks.contains { $0.kind == .groupedHistory })
    }

    /// The lightweight collapse predicate must agree with whether the unchanged full render emits
    /// grouped history, across limits and leaf-structure edges; non-full tiers never collapse.
    func testGroupedHistoryCollapsePredicateMatchesFullRenderGroupedHistory() {
        let limits = [Int.min, -1, 0, 1, 2, 3, Int.max]
        let fixtures = collapsePredicateFixtures()
        XCTAssertEqual(fixtures.count, 10)
        for fixture in fixtures {
            let rendered = limits.map { limit in
                AgentTranscriptProjectionBuilder.blocks(
                    for: fixture.turn,
                    archived: false,
                    detailedToolTailLimit: limit
                ).contains { $0.kind == .groupedHistory }
            }
            let predicted = limits.map { limit in
                AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(in: fixture.turn, detailedToolTailLimit: limit)
            }
            XCTAssertEqual(predicted, rendered, "\(fixture.label): predicate matches full render")
            XCTAssertEqual(rendered, fixture.expected, "\(fixture.label): full-render outcome per limit")
            for tier in [AgentTranscriptRetentionTier.condensed, .summary, .archived] {
                var nonFullTurn = fixture.turn
                nonFullTurn.retentionTier = tier
                XCTAssertFalse(
                    limits.contains { AgentTranscriptProjectionBuilder.groupedHistoryWouldCollapse(in: nonFullTurn, detailedToolTailLimit: $0) },
                    "\(fixture.label): \(tier) never collapses"
                )
            }
        }
    }

    private struct CollapsePredicateFixture {
        let label: String
        let turn: AgentTranscriptTurn
        /// Expected grouped-history emission for limits `[Int.min, -1, 0, 1, 2, 3, Int.max]`.
        let expected: [Bool]
    }

    private func collapsePredicateFixtures() -> [CollapsePredicateFixture] {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func tool(
            _ kind: AgentChatItemKind,
            _ invocationID: UUID?,
            sequence: Int,
            at offset: TimeInterval? = nil,
            hasExecution: Bool = true
        ) -> AgentTranscriptActivity {
            let item = AgentChatItem(
                timestamp: base.addingTimeInterval(offset ?? TimeInterval(sequence)),
                kind: kind,
                text: "",
                toolName: "read_file",
                toolInvocationID: invocationID,
                toolArgsJSON: #"{"path":"/tmp/file.swift"}"#,
                toolResultJSON: kind == .toolResult ? #"{"content":"ok"}"# : nil,
                sequenceIndex: sequence
            )
            let execution = hasExecution ? AgentTranscriptToolNormalizer.toolExecution(for: item) : nil
            return AgentTranscriptActivity(from: item, toolExecution: execution)
        }
        func note(_ kind: AgentChatItemKind, _ text: String, sequence: Int, at offset: TimeInterval? = nil, id: UUID = UUID()) -> AgentTranscriptActivity {
            AgentTranscriptActivity(from: AgentChatItem(
                id: id,
                timestamp: base.addingTimeInterval(offset ?? TimeInterval(sequence)),
                kind: kind,
                text: text,
                sequenceIndex: sequence
            ))
        }
        func turn(_ spans: [[AgentTranscriptActivity]], conclusionID: UUID? = nil) -> AgentTranscriptTurn {
            AgentTranscriptTurn(
                responseSpans: spans.map { AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: base, activities: $0) },
                conclusionActivityID: conclusionID,
                retentionTier: .full,
                startedAt: base
            )
        }
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let conclusionID = UUID()
        let conclusion = note(.assistant, "Final answer", sequence: 30, id: conclusionID)
        let blankConclusion = note(.assistant, "   ", sequence: 3)
        let suppressedToolRow = AgentChatItem(
            timestamp: base.addingTimeInterval(2),
            kind: .toolCall,
            text: "",
            toolName: "tool",
            sequenceIndex: 2
        )
        let suppressedTool = AgentTranscriptActivity(
            from: suppressedToolRow,
            toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: suppressedToolRow)
        )
        XCTAssertTrue(AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(suppressedTool))
        let never = [false, false, false, false, false, false, false]
        return [
            .init(label: "no spans", turn: turn([]), expected: never),
            .init(
                label: "no tools",
                turn: turn([[], [note(.assistant, "Looking", sequence: 1), note(.thinking, "Hmm", sequence: 2)]]),
                expected: never
            ),
            .init(
                label: "adjacent call/result pairs",
                turn: turn([[
                    tool(.toolCall, a, sequence: 1), tool(.toolResult, a, sequence: 2),
                    tool(.toolCall, b, sequence: 3), tool(.toolResult, b, sequence: 4),
                    tool(.toolCall, c, sequence: 5), tool(.toolResult, c, sequence: 6)
                ]]),
                expected: [true, true, true, true, true, false, false]
            ),
            .init(
                // A visible assistant splits one execution; a suppressed (displayless) one does not.
                label: "same execution separated by visible and suppressed rows",
                turn: turn([[
                    tool(.toolCall, a, sequence: 1), note(.assistant, "Between", sequence: 2), tool(.toolResult, a, sequence: 3),
                    tool(.toolCall, b, sequence: 4), note(.assistant, "   ", sequence: 5), tool(.toolResult, b, sequence: 6)
                ]]),
                expected: [true, true, true, true, true, false, false]
            ),
            .init(
                label: "suppressed tool and blank conclusion do not split an execution",
                turn: turn([[
                    tool(.toolCall, a, sequence: 1), suppressedTool, blankConclusion, tool(.toolResult, a, sequence: 4)
                ]], conclusionID: blankConclusion.id),
                expected: [true, true, true, false, false, false, false]
            ),
            .init(
                // Adjacent tools without execution metadata share one block.
                label: "missing execution metadata",
                turn: turn([[
                    tool(.toolCall, nil, sequence: 1, hasExecution: false),
                    tool(.toolResult, nil, sequence: 2, hasExecution: false),
                    note(.assistant, "Between", sequence: 3),
                    tool(.toolCall, nil, sequence: 4, hasExecution: false)
                ]]),
                expected: [true, true, true, true, false, false, false]
            ),
            .init(
                // Stored out of order; the sequence-3 tie resolves by timestamp (assistant first).
                label: "unsorted and tied activities",
                turn: turn([[
                    tool(.toolResult, b, sequence: 4),
                    tool(.toolResult, a, sequence: 2),
                    tool(.toolCall, b, sequence: 3, at: 3.5),
                    tool(.toolCall, a, sequence: 1),
                    note(.assistant, "Between", sequence: 3, at: 3)
                ]]),
                expected: [true, true, true, true, false, false, false]
            ),
            .init(
                label: "leading assistant buffered",
                turn: turn([[note(.assistant, "Plan", sequence: 1), tool(.toolCall, a, sequence: 2), tool(.toolCall, b, sequence: 3)]]),
                expected: [true, true, true, true, false, false, false]
            ),
            .init(
                label: "leading assistant with progress",
                turn: turn([[
                    note(.assistant, "Plan", sequence: 1), tool(.toolCall, a, sequence: 2),
                    note(.thinking, "Hmm", sequence: 3), tool(.toolCall, b, sequence: 4)
                ]]),
                expected: [true, true, true, true, false, false, false]
            ),
            .init(
                // Per-span budgets: 2 + 3 tool blocks never collapse at limit 3. The conclusion and its
                // duplicate in the second span both split the surrounding execution.
                label: "multi-span with duplicate conclusion",
                turn: turn([
                    [tool(.toolCall, d, sequence: 10), conclusion, tool(.toolResult, d, sequence: 31)],
                    [tool(.toolCall, e, sequence: 29), conclusion, tool(.toolResult, e, sequence: 32), tool(.toolCall, a, sequence: 33)]
                ], conclusionID: conclusionID),
                expected: [true, true, true, true, true, false, false]
            )
        ]
    }

    /// Compares the old sequential refresh + build with the paired storage entry on the same
    /// persistence-sanitized input; returns the paired entry's prepared-leaf turn count, which
    /// must equal the input's eligible (full, completed, no open span) turn count.
    @discardableResult
    private func assertPairedStorageMatchesSequential(
        _ fixture: AgentTranscript,
        isSanitized: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let input = isSanitized
            ? fixture
            : AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(fixture).transcript
        let sequentialTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: input)
        let sequentialProjection = AgentTranscriptProjectionBuilder.build(from: sequentialTranscript)
        let paired = AgentTranscriptProjectionBuilder.refreshGroupedHistoryAndBuildStorageProjection(in: input)

        XCTAssertEqual(paired.transcript, sequentialTranscript, file: file, line: line)
        // Transcript equality omits the in-memory grouped-history caches; compare them explicitly.
        XCTAssertEqual(
            paired.transcript.turns.map(\.frozenDetailedToolTailLimit),
            sequentialTranscript.turns.map(\.frozenDetailedToolTailLimit),
            file: file,
            line: line
        )
        XCTAssertEqual(
            paired.transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            sequentialTranscript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            "Per-span cache tail limit, digest, and summary",
            file: file,
            line: line
        )
        // Projection equality covers every block, row, anchor index, and the working unit count.
        XCTAssertEqual(paired.projection, sequentialProjection, file: file, line: line)
        XCTAssertEqual(
            AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: paired.projection),
            AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: sequentialProjection),
            file: file,
            line: line
        )
        XCTAssertEqual(
            AgentTranscriptProjectionBuilder.projectionCounts(for: paired.projection),
            AgentTranscriptProjectionBuilder.projectionCounts(for: sequentialProjection),
            file: file,
            line: line
        )
        XCTAssertEqual(
            AgentTranscriptCompactor.retainedFullDetailBytes(for: paired.transcript),
            AgentTranscriptCompactor.retainedFullDetailBytes(for: sequentialTranscript),
            file: file,
            line: line
        )
        let eligibleTurnCount = input.turns.count { turn in
            turn.retentionTier == .full
                && turn.isCompleted
                && !turn.responseSpans.contains { $0.lifecycle == .open }
        }
        XCTAssertEqual(paired.preparedLeafTurnCount, eligibleTurnCount, "Prepared leaves used for eligible turns only", file: file, line: line)
        return paired.preparedLeafTurnCount
    }

    /// Full collapsing, condensed, summary, archived, full no-collapse, full open-span, and full
    /// incomplete turns.
    private func makeMixedTierTranscript() -> AgentTranscript {
        var sequenceIndex = 0
        var items: [AgentChatItem] = []
        for (label, toolCount) in [("collapse", 10), ("condensed", 3), ("summary", 3), ("archived", 2), ("no-collapse", 2), ("open-span", 3), ("incomplete", 3)] {
            items += makeTurnItems(label: label, toolCount: toolCount, sequenceIndex: &sequenceIndex)
        }
        var transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        transcript.turns[1].retentionTier = .condensed
        transcript.turns[2].retentionTier = .summary
        transcript.turns[3].retentionTier = .archived
        transcript.turns[5].responseSpans[0].lifecycle = .open
        transcript.turns[6].terminalState = .running
        transcript.turns[6].completedAt = nil
        return transcript
    }

    private func anchorTurnID(_ anchor: AgentTranscriptAnchor) -> UUID {
        switch anchor {
        case let .request(turnID),
             let .summary(turnID):
            turnID
        case let .activity(turnID, _, _),
             let .conclusion(turnID, _),
             let .groupedHistory(turnID, _):
            turnID
        }
    }

    private func makeTurnItems(
        label: String,
        toolCount: Int,
        sequenceIndex: inout Int,
        userItem: AgentChatItem? = nil
    ) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        let user = userItem ?? .user("\(label) request", sequenceIndex: sequenceIndex)
        items.append(user)
        sequenceIndex += 1
        for toolIndex in 0 ..< toolCount {
            let invocationID = UUID()
            items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"/tmp/file.swift"}"#,
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
            items.append(.toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: #"{"content":"ok"}"#,
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
        }
        items.append(.assistant("\(label) done", sequenceIndex: sequenceIndex))
        sequenceIndex += 1
        return items
    }
}
