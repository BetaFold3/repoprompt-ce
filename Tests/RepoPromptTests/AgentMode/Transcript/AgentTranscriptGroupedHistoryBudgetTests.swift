import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
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

    /// The structural visible tool-result query equals the IDs read from a full projection build
    /// across tiers, frozen ceilings, newest-first allocation, and leaf-structure edges.
    func testStructuralVisibleToolResultRowIDsMatchProjectionBuild() throws {
        var collapsedFixtureCount = 0
        @discardableResult
        func assertMatches(_ transcript: AgentTranscript, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> Set<UUID> {
            let expected = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
                in: AgentTranscriptProjectionBuilder.build(from: transcript)
            )
            XCTAssertEqual(AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(for: transcript), expected, label, file: file, line: line)
            let allToolResultIDs = Set(transcript.turns.flatMap(\.allActivities).filter { $0.itemKind == .toolResult }.map(\.id))
            if expected.count < allToolResultIDs.count { collapsedFixtureCount += 1 }
            return expected
        }

        var newerSequenceIndex = 100
        let newerTurn = try XCTUnwrap(AgentTranscriptIO.buildTranscript(
            from: makeTurnItems(label: "newer", toolCount: 6, sequenceIndex: &newerSequenceIndex),
            terminalState: .completed,
            nextSequenceIndex: newerSequenceIndex,
            compact: false
        ).turns.first)
        for fixture in collapsePredicateFixtures() + conclusionToolResultFixtures() {
            for tier in [AgentTranscriptRetentionTier.full, .condensed, .summary, .archived] {
                for frozen in [nil, -1, 0, 1, 2, Int.max] as [Int?] {
                    var turn = fixture.turn
                    turn.retentionTier = tier
                    turn.frozenDetailedToolTailLimit = frozen
                    let label = "\(fixture.label) \(tier) frozen=\(String(describing: frozen))"
                    assertMatches(AgentTranscript(turns: [turn], nextSequenceIndex: 200), label)
                    assertMatches(AgentTranscript(turns: [turn, newerTurn], nextSequenceIndex: 200), "\(label) behind newer turn")
                }
            }
        }

        // Non-vacuous fallback: in summary and archived tiers the suppressed tool-result conclusion is
        // visible only through the `conclusionRow` fallback, which keeps its activity ID and kind.
        let suppressedFixture = try XCTUnwrap(conclusionToolResultFixtures().first { $0.label == "suppressed tool-result conclusion" })
        let suppressedConclusionID = try XCTUnwrap(suppressedFixture.turn.conclusionActivityID)
        for tier in [AgentTranscriptRetentionTier.summary, .archived] {
            var turn = suppressedFixture.turn
            turn.retentionTier = tier
            XCTAssertTrue(
                assertMatches(AgentTranscript(turns: [turn], nextSequenceIndex: 200), "suppressed fallback \(tier)")
                    .contains(suppressedConclusionID),
                "\(tier): the fallback conclusion row is a visible tool result"
            )
        }

        let mixed = makeMixedTierTranscript()
        assertMatches(mixed, "mixed tiers")
        assertMatches(
            AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: mixed),
            "mixed tiers with frozen limits"
        )
        var sequenceIndex = 0
        let olderItems = makeTurnItems(label: "older", toolCount: 20, sequenceIndex: &sequenceIndex)
        let newerItems = makeTurnItems(label: "newer", toolCount: 2, sequenceIndex: &sequenceIndex)
        let twoTurns = AgentTranscriptIO.buildTranscript(
            from: olderItems + newerItems,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let visible = assertMatches(twoTurns, "two turns sharing the global tail")
        XCTAssertEqual(visible.count, 8, "The newest-first allocation keeps 8 detailed tool executions")
        let compacted = AgentTranscriptCompactor.compact(
            AgentTranscriptIO.buildTranscript(
                from: (0 ..< 30).flatMap { makeTurnItems(label: "turn \($0)", toolCount: 6, sequenceIndex: &sequenceIndex) },
                terminalState: .completed,
                nextSequenceIndex: sequenceIndex,
                compact: false
            ),
            protection: .none
        )
        XCTAssertGreaterThan(Set(compacted.turns.map(\.retentionTier)).count, 1, "Compaction produces mixed tiers")
        assertMatches(compacted, "compacted multi-turn")
        assertMatches(AgentTranscriptPolicyPipeline.runtimeTranscript(compacted).transcript, "runtime-materialized multi-turn")
        XCTAssertGreaterThan(collapsedFixtureCount, 0, "Fixtures hide some tool results")
    }

    /// The runtime and handoff pipelines produce identical outputs with structural initial visibility
    /// and the projection reference, and the structural mode skips exactly the initial build.
    func testRuntimePipelineStructuralInitialVisibilityMatchesProjectionReference() {
        let buildCounter = ProjectionBuildCounter()
        AgentTranscriptDebugInstrumentation.reset()
        AgentTranscriptDebugInstrumentation.isEnabled = true
        AgentTranscriptDebugInstrumentation.projectionBuildHandler = { _ in buildCounter.increment() }
        defer { AgentTranscriptDebugInstrumentation.reset() }

        var sequenceIndex = 0
        let multiTurn = AgentTranscriptCompactor.compact(
            AgentTranscriptIO.buildTranscript(
                from: (0 ..< 30).flatMap { makeTurnItems(label: "turn \($0)", toolCount: 6, sequenceIndex: &sequenceIndex) },
                terminalState: .completed,
                nextSequenceIndex: sequenceIndex,
                compact: false
            ),
            protection: .none
        )
        let fixtures: [(String, AgentTranscript)] = [
            ("mixed tiers", makeMixedTierTranscript()),
            ("compacted multi-turn", multiTurn),
            ("empty", AgentTranscript())
        ]
        for (label, transcript) in fixtures {
            func materialize(reference: Bool, _ body: () -> AgentTranscriptPolicyPipeline.Result) -> (AgentTranscriptPolicyPipeline.Result, Int) {
                let before = buildCounter.value
                let result = AgentTranscriptPolicyPipeline.$derivesInitialVisibilityFromProjection.withValue(reference, operation: body)
                return (result, buildCounter.value - before)
            }
            let lastRowID = transcript.turns.last?.allActivities.last?.id
            for (purpose, body) in [
                ("runtime", { AgentTranscriptPolicyPipeline.runtimeTranscript(transcript) }),
                ("handoff", { AgentTranscriptPolicyPipeline.handoffTranscript(from: transcript, upToRowID: nil) }),
                ("handoff cutoff", { AgentTranscriptPolicyPipeline.handoffTranscript(from: transcript, upToRowID: lastRowID) })
            ] as [(String, () -> AgentTranscriptPolicyPipeline.Result)] {
                let (reference, referenceBuilds) = materialize(reference: true, body)
                let (candidate, candidateBuilds) = materialize(reference: false, body)
                let context = "\(label) \(purpose)"
                XCTAssertEqual(candidate.transcript, reference.transcript, context)
                XCTAssertEqual(
                    candidate.transcript.turns.map(\.frozenDetailedToolTailLimit),
                    reference.transcript.turns.map(\.frozenDetailedToolTailLimit),
                    context
                )
                XCTAssertEqual(
                    candidate.transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
                    reference.transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
                    context
                )
                XCTAssertEqual(candidate.projection, reference.projection, context)
                XCTAssertEqual(candidate.visibleToolResultRowIDs, reference.visibleToolResultRowIDs, context)
                XCTAssertEqual(candidate.sanitizedActivityCount, reference.sanitizedActivityCount, context)
                XCTAssertEqual(candidate.retainedFullDetailBytes, reference.retainedFullDetailBytes, context)
                XCTAssertEqual(candidateBuilds, referenceBuilds - 1, "\(context): only the initial build is removed")
            }
        }
        XCTAssertFalse(
            AgentTranscriptPolicyPipeline.runtimeTranscript(multiTurn).visibleToolResultRowIDs.isEmpty,
            "Runtime materialization preserves visible tool results"
        )
    }

    /// Every input the runtime stabilization loop queries (sanitized from the original input,
    /// grouped-history caches refreshed) gives equal structural and projection-derived visible
    /// tool-result IDs, across the visibility fixtures and fixtures that need stabilization retries.
    func testStructuralVisibleToolResultRowIDsMatchProjectionBuildOnRuntimeStabilizationInputs() throws {
        var queriedInputCount = 0
        var retryingFixtures: [String] = []
        var exhaustedFixtures: [String] = []
        for (label, transcript) in try runtimeStabilizationFixtures() {
            let trace = traceRuntimeStabilization(transcript)
            if trace.retries > 0 { retryingFixtures.append(label) }
            if trace.exhausted { exhaustedFixtures.append(label) }
            // The exhausted final transcript is never queried; it is checked too for coverage.
            for (index, input) in (trace.queriedInputs + (trace.exhausted ? [trace.final] : [])).enumerated() {
                queriedInputCount += 1
                XCTAssertEqual(
                    AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(for: input),
                    projectionVisibleToolResultRowIDs(input),
                    "\(label) stabilization input \(index)"
                )
            }
            // The replica is faithful: it reproduces the pipeline's transcript and caches.
            assertSameRuntimeTranscript(trace.final, AgentTranscriptPolicyPipeline.runtimeTranscript(transcript).transcript, "\(label) replica")
        }
        XCTAssertGreaterThan(queriedInputCount, 100)
        XCTAssertTrue(retryingFixtures.contains("execution metadata added by sanitize"), "Retrying fixtures: \(retryingFixtures)")
        XCTAssertFalse(exhaustedFixtures.contains("execution metadata added by sanitize"), "That fixture converges after one retry")
        // The full-tier suppressed tool-result conclusion's visible set does not settle within the
        // retry bound, so it covers the exhausted exit. It is the only fixture that does; if a
        // later fix makes it converge, add a dedicated exhausting fixture rather than drop this.
        XCTAssertTrue(
            exhaustedFixtures.contains("suppressed tool-result conclusion full frozen=nil"),
            "Exhausted fixtures: \(exhaustedFixtures)"
        )
    }

    /// `runtimeTranscriptOnly` equals `runtimeTranscript(_:).transcript` (including the in-memory
    /// frozen limits and per-span caches), in candidate and projection-reference modes, and the
    /// candidate skips every post-refresh projection build: exactly one fewer when no retry runs.
    func testRuntimeTranscriptOnlyMatchesRuntimeTranscriptWithoutFinalProjectionBuild() throws {
        let buildCounter = ProjectionBuildCounter()
        AgentTranscriptDebugInstrumentation.reset()
        AgentTranscriptDebugInstrumentation.isEnabled = true
        AgentTranscriptDebugInstrumentation.projectionBuildHandler = { _ in buildCounter.increment() }
        defer { AgentTranscriptDebugInstrumentation.reset() }
        func counted<T>(_ body: () -> T) -> (T, Int) {
            let before = buildCounter.value
            let value = body()
            return (value, buildCounter.value - before)
        }

        var sawConvergedRetry = false
        var sawExhausted = false
        var sawNoRetry = false
        for (label, transcript) in try runtimeStabilizationFixtures() {
            let trace = traceRuntimeStabilization(transcript)
            let (reference, referenceBuilds) = counted { AgentTranscriptPolicyPipeline.runtimeTranscript(transcript) }
            let (projectionMode, projectionModeBuilds) = counted {
                AgentTranscriptPolicyPipeline.$derivesPostRefreshVisibilityFromProjection.withValue(true) {
                    AgentTranscriptPolicyPipeline.runtimeTranscriptOnly(transcript)
                }
            }
            let (candidate, candidateBuilds) = counted { AgentTranscriptPolicyPipeline.runtimeTranscriptOnly(transcript) }
            assertSameRuntimeTranscript(candidate, reference.transcript, "\(label) candidate")
            assertSameRuntimeTranscript(projectionMode, reference.transcript, "\(label) projection reference mode")
            XCTAssertEqual(referenceBuilds, trace.queriedInputs.count + (trace.exhausted ? 1 : 0), "\(label): runtimeTranscript builds")
            XCTAssertEqual(projectionModeBuilds, trace.queriedInputs.count, "\(label): reference mode builds each queried input")
            XCTAssertEqual(candidateBuilds, 0, "\(label): the transcript-only path builds no projection")
            // Converged after r retries: r + 1 builds; exhausted: 3 queried + 1 final = retries + 1.
            XCTAssertEqual(referenceBuilds - candidateBuilds, trace.retries + 1, "\(label): skipped builds")
            if trace.retries == 0 {
                sawNoRetry = true
                XCTAssertEqual(candidateBuilds, referenceBuilds - 1, "\(label): one fewer build without retries")
            } else if trace.exhausted {
                sawExhausted = true
            } else {
                sawConvergedRetry = true
            }
        }
        XCTAssertTrue(sawConvergedRetry, "A fixture converges after a stabilization retry")
        XCTAssertTrue(sawExhausted, "A fixture exhausts the stabilization retries")
        XCTAssertTrue(sawNoRetry)
    }

    private struct RuntimeStabilizationTrace {
        /// The sanitized, cache-refreshed transcripts whose visible IDs the loop compares, in order.
        var queriedInputs: [AgentTranscript] = []
        var retries = 0
        var exhausted = false
        var final = AgentTranscript()
    }

    /// Replicates the runtime stabilization loop with projection-derived IDs: sanitize from the
    /// original input, refresh grouped-history caches, compare, at most 3 retries.
    private func traceRuntimeStabilization(_ transcript: AgentTranscript) -> RuntimeStabilizationTrace {
        func sanitizedAndRefreshed(_ preserved: Set<UUID>) -> AgentTranscript {
            AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
                in: AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
                    transcript,
                    preservedVisibleToolResultRowIDs: preserved,
                    purpose: .runtimePresentation
                ).transcript
            )
        }
        var trace = RuntimeStabilizationTrace()
        var visible = projectionVisibleToolResultRowIDs(transcript)
        trace.final = sanitizedAndRefreshed(visible)
        for _ in 0 ..< 3 {
            trace.queriedInputs.append(trace.final)
            let stabilized = projectionVisibleToolResultRowIDs(trace.final)
            guard stabilized != visible else { return trace }
            visible = stabilized
            trace.retries += 1
            trace.final = sanitizedAndRefreshed(visible)
        }
        trace.exhausted = true
        return trace
    }

    private func projectionVisibleToolResultRowIDs(_ transcript: AgentTranscript) -> Set<UUID> {
        AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: AgentTranscriptProjectionBuilder.build(from: transcript))
    }

    private func assertSameRuntimeTranscript(
        _ candidate: AgentTranscript,
        _ reference: AgentTranscript,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(candidate, reference, context, file: file, line: line)
        XCTAssertEqual(
            candidate.turns.map(\.frozenDetailedToolTailLimit),
            reference.turns.map(\.frozenDetailedToolTailLimit),
            "\(context): frozen limits",
            file: file,
            line: line
        )
        // Transcript equality omits the in-memory grouped-history caches; compare them explicitly.
        XCTAssertEqual(
            candidate.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            reference.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            "\(context): per-span grouped-history caches",
            file: file,
            line: line
        )
    }

    /// The visibility fixtures plus pending/terminal-tool transcripts and a fixture whose runtime
    /// sanitization changes the visible set, so stabilization needs a retry.
    private func runtimeStabilizationFixtures() throws -> [(String, AgentTranscript)] {
        var fixtures: [(String, AgentTranscript)] = []
        var newerSequenceIndex = 100
        let newerTurn = try XCTUnwrap(AgentTranscriptIO.buildTranscript(
            from: makeTurnItems(label: "newer", toolCount: 6, sequenceIndex: &newerSequenceIndex),
            terminalState: .completed,
            nextSequenceIndex: newerSequenceIndex,
            compact: false
        ).turns.first)
        for fixture in collapsePredicateFixtures() + conclusionToolResultFixtures() {
            for tier in [AgentTranscriptRetentionTier.full, .condensed, .summary, .archived] {
                for frozen in [nil, 0, 2, Int.max] as [Int?] {
                    var turn = fixture.turn
                    turn.retentionTier = tier
                    turn.frozenDetailedToolTailLimit = frozen
                    let label = "\(fixture.label) \(tier) frozen=\(String(describing: frozen))"
                    fixtures.append((label, AgentTranscript(turns: [turn], nextSequenceIndex: 200)))
                    fixtures.append(("\(label) behind newer turn", AgentTranscript(turns: [turn, newerTurn], nextSequenceIndex: 200)))
                }
            }
        }
        let mixed = makeMixedTierTranscript()
        fixtures.append(("mixed tiers", mixed))
        fixtures.append(("mixed tiers with frozen limits", AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: mixed)))
        var sequenceIndex = 0
        let compactedItems = (0 ..< 30).flatMap { makeTurnItems(label: "turn \($0)", toolCount: 6, sequenceIndex: &sequenceIndex) }
        let compacted = AgentTranscriptCompactor.compact(
            AgentTranscriptIO.buildTranscript(from: compactedItems, terminalState: .completed, nextSequenceIndex: sequenceIndex, compact: false),
            protection: .none
        )
        fixtures.append(("compacted multi-turn", compacted))

        sequenceIndex = 0
        let history = makeTurnItems(label: "older", toolCount: 12, sequenceIndex: &sequenceIndex)
            + makeTurnItems(label: "middle", toolCount: 3, sequenceIndex: &sequenceIndex)
        var pendingItems = history
        pendingItems.append(.user("Ask me.", sequenceIndex: sequenceIndex))
        pendingItems.append(.toolCall(name: "read_file", invocationID: UUID(), argsJSON: #"{"path":"/tmp/a.swift"}"#, sequenceIndex: sequenceIndex + 1))
        pendingItems.append(.toolCall(
            name: "ask_user",
            invocationID: UUID(),
            argsJSON: #"{"questions":[{"id":"q","question":"Proceed?"}]}"#,
            sequenceIndex: sequenceIndex + 2
        ))
        fixtures.append(("pending tool calls", AgentTranscriptIO.buildTranscript(
            from: pendingItems,
            terminalState: .running,
            nextSequenceIndex: sequenceIndex + 3,
            compact: false
        )))
        var terminalItems = history
        var terminalSequenceIndex = sequenceIndex
        terminalItems += makeTurnItems(label: "terminal", toolCount: 9, sequenceIndex: &terminalSequenceIndex).dropLast()
        fixtures.append(("terminal tool result", AgentTranscriptIO.buildTranscript(
            from: terminalItems,
            terminalState: .completed,
            nextSequenceIndex: terminalSequenceIndex,
            compact: false
        )))
        fixtures.append(("empty", AgentTranscript()))
        let missingExecutionMetadata = try makeMissingExecutionMetadataTranscript()
        fixtures.append(("execution metadata added by sanitize", missingExecutionMetadata))
        return fixtures
    }

    /// A completed full turn whose tool activities carry no execution metadata, so the original
    /// render keeps them in one block (no collapse, every result visible). Runtime sanitization
    /// attaches executions, splitting the block per execution and collapsing older tools, so the
    /// visible set changes and stabilization retries once.
    private func makeMissingExecutionMetadataTranscript() throws -> AgentTranscript {
        var sequenceIndex = 0
        var transcript = AgentTranscriptIO.buildTranscript(
            from: makeTurnItems(label: "stripped", toolCount: 12, sequenceIndex: &sequenceIndex),
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
        let turnIndex = try XCTUnwrap(transcript.turns.indices.last)
        for spanIndex in transcript.turns[turnIndex].responseSpans.indices {
            for activityIndex in transcript.turns[turnIndex].responseSpans[spanIndex].activities.indices {
                transcript.turns[turnIndex].responseSpans[spanIndex].activities[activityIndex].toolExecution = nil
            }
        }
        return transcript
    }

    private final class ProjectionBuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    /// Turns whose conclusion is a tool result: emitted leaf, suppressed (so only the turn's
    /// `conclusionRow` fallback can show it), and absent. These fixtures feed only the ID-equality
    /// test; their `expected` field is unused and left empty.
    private func conclusionToolResultFixtures() -> [CollapsePredicateFixture] {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func activity(
            _ kind: AgentChatItemKind,
            toolName: String,
            text: String,
            invocationID: UUID = UUID(),
            hasPayload: Bool = true,
            sequence: Int
        ) -> AgentTranscriptActivity {
            let item = AgentChatItem(
                timestamp: base.addingTimeInterval(TimeInterval(sequence)),
                kind: kind,
                text: text,
                toolName: toolName,
                toolInvocationID: invocationID,
                toolArgsJSON: hasPayload ? #"{"path":"/tmp/file.swift"}"# : nil,
                toolResultJSON: hasPayload && kind == .toolResult ? #"{"content":"ok"}"# : nil,
                sequenceIndex: sequence
            )
            return AgentTranscriptActivity(from: item, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: item))
        }
        func turn(conclusion: AgentTranscriptActivity, summary: AgentTranscriptTurnSummary? = nil) -> AgentTranscriptTurn {
            var activities: [AgentTranscriptActivity] = []
            for index in 0 ..< 4 {
                let invocationID = UUID()
                activities.append(activity(.toolCall, toolName: "read_file", text: "", invocationID: invocationID, sequence: index * 2))
                activities.append(activity(.toolResult, toolName: "read_file", text: "", invocationID: invocationID, sequence: index * 2 + 1))
            }
            activities.append(conclusion)
            return AgentTranscriptTurn(
                responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: base, activities: activities)],
                conclusionActivityID: conclusion.id,
                summary: summary,
                startedAt: base
            )
        }
        let emittedConclusion = activity(.toolResult, toolName: "read_file", text: "Visible conclusion", sequence: 20)
        // A placeholder-named result with no args, result, or text is suppressed by the existing policy;
        // the summary's conclusion text lets `conclusionRow` still produce a row for it.
        let suppressedConclusion = activity(.toolResult, toolName: "tool", text: "", hasPayload: false, sequence: 20)
        XCTAssertFalse(AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(emittedConclusion))
        XCTAssertTrue(AgentTranscriptToolVisibilityPolicy.shouldSuppressActivity(suppressedConclusion))
        let summary = AgentTranscriptTurnSummary(
            requestText: nil,
            conclusionText: "Summarized conclusion",
            compactConclusionText: nil,
            middleSummaryText: nil,
            toolCount: 5,
            notableToolNames: [],
            keyPaths: [],
            compactedActivityCount: 0,
            hadWarning: false,
            hadError: false
        )
        var missing = turn(conclusion: activity(.toolResult, toolName: "read_file", text: "Visible conclusion", sequence: 20))
        missing.conclusionActivityID = UUID()
        return [
            .init(label: "tool-result conclusion", turn: turn(conclusion: emittedConclusion), expected: []),
            .init(label: "suppressed tool-result conclusion", turn: turn(conclusion: suppressedConclusion, summary: summary), expected: []),
            .init(label: "missing conclusion activity", turn: missing, expected: [])
        ]
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
