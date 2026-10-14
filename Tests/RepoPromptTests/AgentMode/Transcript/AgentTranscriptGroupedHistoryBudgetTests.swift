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
