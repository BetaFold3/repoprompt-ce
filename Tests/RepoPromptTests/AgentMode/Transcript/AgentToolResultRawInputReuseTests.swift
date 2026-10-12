@testable import RepoPromptApp
import XCTest

/// D4: runtime sanitize reuses a previous activity's output only after full raw-input equality,
/// replaying the processing flag recorded for it; every result must equal a cold sanitize,
/// including counts, flags, grouped-history caches, and per-build context registration.
final class AgentToolResultRawInputReuseTests: XCTestCase {
    func testUnchangedToolActivitiesAreReusedAndEqualCold() {
        let previousRaw = Self.importTranscript(Self.bashItems(count: 6))
        let previous = Self.evidence(previousRaw)

        let reuse = assertReuseEqualsCold(previousRaw, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 12)
        XCTAssertEqual(reuse.sanitizedActivityCount, 6)
        XCTAssertEqual(reuse.incrementalPathReason, .rawInputActivityComparison)
        XCTAssertEqual(reuse.reusedTurnCount, 1, "the wholly reused turn is installed whole")
    }

    func testRawOutputEqualActivitiesReplayTrueAndFalseFlags() {
        // Summary-only input: processing returns the same value, reporting true for results
        // and false for calls.
        let summaryOnly = Self.evidence(Self.importTranscript(Self.bashItems(count: 3))).sanitized
        let previous = Self.evidence(summaryOnly)
        XCTAssertEqual(previous.sanitized, summaryOnly, "raw input equals output")
        let flags = previous.evidence.activityProcessingFlags.flatMap { $0.flatMap(\.self) }
        XCTAssertEqual(flags, [false, true, false, true, false, true])

        let reuse = assertReuseEqualsCold(summaryOnly, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 6)
        XCTAssertEqual(reuse.sanitizedActivityCount, 3)
        XCTAssertEqual(reuse.activityProcessingFlags, previous.evidence.activityProcessingFlags)
    }

    func testChangedContentUnderSameIdentityIsProcessedNormally() throws {
        var items = Self.bashItems(count: 5)
        let previous = Self.evidence(Self.importTranscript(items))
        let changedIndex = try XCTUnwrap(items.lastIndex { $0.kind == .toolResult })
        items[changedIndex].toolResultJSON = Self.bashResultJSON(index: 99, output: "changed output")
        items[changedIndex].text = items[changedIndex].toolResultJSON ?? ""

        let reuse = assertReuseEqualsCold(Self.importTranscript(items), previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 9)
    }

    func testChangedEmbeddedExecutionUnderSameIdentityIsProcessedNormally() {
        let previousRaw = Self.importTranscript(Self.bashItems(count: 3))
        let previous = Self.evidence(previousRaw)
        var current = previousRaw
        let lastIndex = current.turns[0].responseSpans[0].activities.count - 1
        current.turns[0].responseSpans[0].activities[lastIndex].toolExecution?.processID = "other-process"

        let reuse = assertReuseEqualsCold(current, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 5)
    }

    func testAppendedActivitiesAndSpansAreProcessedAndPrefixIsReused() {
        let items = Self.bashItems(count: 4)
        let previous = Self.evidence(Self.importTranscript(items))
        let appendedActivities = Self.importTranscript(Self.bashItems(count: 2, firstIndex: 50))
            .turns[0].responseSpans[0].activities
        var current = Self.importTranscript(items)
        current.turns[0].responseSpans[0].activities.append(appendedActivities[0])
        current.turns[0].responseSpans.append(AgentTranscriptProviderResponseSpan(
            id: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 500),
            activities: [appendedActivities[1]]
        ))

        let reuse = assertReuseEqualsCold(current, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 8)
    }

    func testStructuralIdentityMismatchesRemoveReuseAtThosePositions() {
        let items = Self.bashItems(count: 3)
        let previous = Self.evidence(Self.importTranscript(items))

        var reorderedSpans = Self.importTranscript(items)
        let original = reorderedSpans.turns[0].responseSpans[0]
        reorderedSpans.turns[0].responseSpans = [
            AgentTranscriptProviderResponseSpan(id: UUID(), startedAt: original.startedAt, activities: []),
            original
        ]
        XCTAssertEqual(assertReuseEqualsCold(reorderedSpans, previous: previous).reusedActivityCount, 0)

        var insertedActivity = Self.importTranscript(items)
        let extra = Self.importTranscript(Self.bashItems(count: 1, firstIndex: 70)).turns[0].responseSpans[0].activities[0]
        insertedActivity.turns[0].responseSpans[0].activities.insert(extra, at: 0)
        XCTAssertEqual(assertReuseEqualsCold(insertedActivity, previous: previous).reusedActivityCount, 0)

        let otherTurn = Self.importTranscript([.user("other", sequenceIndex: 0)] + Array(items.dropFirst()))
        XCTAssertEqual(assertReuseEqualsCold(otherTurn, previous: previous).reusedActivityCount, 0)
    }

    func testMisalignedOrInconsistentFlagsAreNotTrusted() {
        let raw = Self.importTranscript(Self.bashItems(count: 3))
        let previous = Self.evidence(raw)

        var shortFlags = previous.evidence.activityProcessingFlags
        shortFlags[0][0].removeLast()
        let misaligned = (
            evidence: AgentSanitizeRawInputEvidence(importedTranscript: raw, activityProcessingFlags: shortFlags),
            sanitized: previous.sanitized
        )
        XCTAssertEqual(assertReuseEqualsCold(raw, previous: misaligned).reusedActivityCount, 0)

        // A false flag claims processing left the activity untouched; transformed outputs
        // contradict it and are processed instead. Untransformed calls stay reusable.
        let allFalse = previous.evidence.activityProcessingFlags.map { $0.map { $0.map { _ in false } } }
        let inconsistent = (
            evidence: AgentSanitizeRawInputEvidence(importedTranscript: raw, activityProcessingFlags: allFalse),
            sanitized: previous.sanitized
        )
        XCTAssertEqual(assertReuseEqualsCold(raw, previous: inconsistent).reusedActivityCount, 3)
    }

    func testExecutionlessActivitiesAreProcessedNormally() {
        var executionless = Self.importTranscript(Self.bashItems(count: 3))
        executionless.turns[0].responseSpans[0].activities[1].toolExecution = nil
        let previous = Self.evidence(executionless)

        let reuse = assertReuseEqualsCold(executionless, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 5)
    }

    func testGroupedHistoryCachesMatchColdForMixedSpans() {
        var items = Self.bashItems(count: 12)
        items.append(.assistant("Conclusion", sequenceIndex: items.count))
        var toolFreeSpan = AgentTranscriptProviderResponseSpan(
            id: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            activities: [AgentTranscriptActivity(from: .assistant("Tool-free", sequenceIndex: 900))]
        )
        toolFreeSpan.lifecycle = .completed
        var raw = Self.importTranscript(items, terminalState: .completed)
        raw.turns[0].responseSpans.append(toolFreeSpan)
        raw = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: raw)
        let previous = Self.evidence(raw)

        let reuse = assertReuseEqualsCold(raw, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 24)
        XCTAssertTrue(Self.groupedHistoryCaches(raw).contains { $0 != nil }, "the input carries grouped caches to compare")
    }

    func testFlagsAreRecordedOnlyWhenEveryActivityWasProcessedOrReplayed() {
        let twoTurns = Self.bashItems(count: 2) + [.user("Again", sequenceIndex: 5)] + Self.bashItems(count: 1, firstIndex: 9).dropFirst()
        let raw = Self.importTranscript(twoTurns.enumerated().map { index, item in
            var item = item
            item.sequenceIndex = index
            return item
        })
        let previous = Self.evidence(raw)
        XCTAssertEqual(previous.evidence.activityProcessingFlags.count, 2)

        // Summary-only input equals its output, so the legacy prefix validation accepts turn 0.
        let summaryOnly = previous.sanitized
        let prefixReuse = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            summaryOnly,
            previousSanitizedTranscript: Self.evidence(summaryOnly).sanitized,
            reusablePrefixTurnCount: 1
        )
        XCTAssertEqual(prefixReuse.reusedTurnCount, 1)
        XCTAssertNil(prefixReuse.activityProcessingFlags, "unchecked prefix reuse records no evidence")

        let toolFree = Self.importTranscript([.user("hi", sequenceIndex: 0), .assistant("hello", sequenceIndex: 1)])
        XCTAssertEqual(Self.cold(toolFree).metrics.activityProcessingFlags, [[[false]]], "tool-free activities never mutate")

        // Calls without results skip processing now but would be normalized once a result exists.
        let callsOnly = Self.importTranscript(Array(Self.bashItems(count: 2).filter { $0.kind != .toolResult }))
        XCTAssertNil(Self.cold(callsOnly).metrics.activityProcessingFlags, "skipped tool calls record no evidence")
    }

    func testLegacyLoopAndRecordingTraversalAgree() {
        var items = Self.bashItems(count: 4)
        items.append(.assistant("Done", sequenceIndex: items.count))
        let raw = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: Self.importTranscript(items, terminalState: .completed)
        )
        // An unrelated preserved ID forces the pre-D4 per-turn loop without changing its output.
        let legacy = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(raw, preservedVisibleToolResultRowIDs: [UUID()])
        let recording = Self.cold(raw).metrics

        XCTAssertNil(legacy.activityProcessingFlags)
        XCTAssertEqual(recording.transcript, legacy.transcript)
        XCTAssertEqual(recording.sanitizedActivityCount, legacy.sanitizedActivityCount)
        XCTAssertEqual(Self.groupedHistoryCaches(recording.transcript), Self.groupedHistoryCaches(legacy.transcript))
        let flags = try? XCTUnwrap(recording.activityProcessingFlags)
        XCTAssertEqual(flags?.flatMap { $0.flatMap(\.self) }.count { $0 }, legacy.sanitizedActivityCount)
        XCTAssertEqual(flags?.map { $0.map(\.count) }, raw.turns.map { $0.responseSpans.map(\.activities.count) })
    }

    func testChangedPairedCallDoesNotAffectReusedResult() throws {
        let raw = Self.importTranscript(Self.bashItems(count: 2))
        let previous = Self.evidence(raw)
        var current = raw
        let callIndex = try XCTUnwrap(current.turns[0].responseSpans[0].activities.firstIndex { $0.itemKind == .toolCall })
        current.turns[0].responseSpans[0].activities[callIndex].toolExecution?.argsJSON = #"{"command":"echo changed"}"#

        let reuse = assertReuseEqualsCold(current, previous: previous)

        XCTAssertEqual(reuse.reusedActivityCount, 3, "only the changed call is processed; its result is reused")
    }

    func testCompletedMultiTurnHistoryReusesWholeTurnsWithGroupedCaches() throws {
        var items: [AgentChatItem] = []
        for turn in 0 ..< 3 {
            items.append(.user("Turn \(turn)", sequenceIndex: items.count))
            for item in Self.bashItems(count: 12, firstIndex: turn * 100).dropFirst() {
                var item = item
                item.sequenceIndex = items.count
                items.append(item)
            }
            items.append(.assistant("Turn \(turn) done", sequenceIndex: items.count))
        }
        let raw = Self.importTranscript(items, terminalState: .completed)
        XCTAssertEqual(raw.turns.count, 3)
        XCTAssertTrue(raw.turns.allSatisfy { $0.retentionTier == .full && $0.isCompleted })
        let previous = Self.evidence(raw)
        XCTAssertTrue(Self.groupedHistoryCaches(previous.sanitized).contains { $0 != nil }, "completed turns carry grouped caches")

        let unchanged = assertReuseEqualsCold(raw, previous: previous)
        XCTAssertEqual(unchanged.reusedTurnCount, 3)
        XCTAssertEqual(unchanged.reusedActivityCount, 72)

        var changedLimit = raw
        changedLimit.turns[0].frozenDetailedToolTailLimit = 1
        let limited = assertReuseEqualsCold(changedLimit, previous: previous)
        XCTAssertEqual(limited.transcript.turns[0].frozenDetailedToolTailLimit, 1)
        XCTAssertEqual(limited.reusedActivityCount, 72)

        var changedLastTurn = raw
        let lastSpan = try XCTUnwrap(changedLastTurn.turns[2].responseSpans.indices.last)
        let resultIndex = try XCTUnwrap(changedLastTurn.turns[2].responseSpans[lastSpan].activities.lastIndex { $0.itemKind == .toolResult })
        changedLastTurn.turns[2].responseSpans[lastSpan].activities[resultIndex].toolExecution?.exitCode = 1
        let changed = assertReuseEqualsCold(changedLastTurn, previous: previous)
        XCTAssertEqual(changed.reusedTurnCount, 2, "only the leading unchanged turns are installed whole")
        XCTAssertEqual(changed.reusedActivityCount, 71)
    }

    func testPersistentStorageAndPreservedRowsIgnoreEvidence() {
        let raw = Self.importTranscript(Self.bashItems(count: 2))
        let previous = Self.evidence(raw)

        let persistent = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            raw,
            previousSanitizedTranscript: previous.sanitized,
            previousRawInputEvidence: previous.evidence,
            purpose: .persistentStorage
        )
        XCTAssertEqual(persistent.incrementalPathReason, .notRuntimePresentation)
        XCTAssertEqual(persistent, AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(raw))

        let preservedID = raw.turns[0].responseSpans[0].activities[1].id
        let preserved = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            raw,
            previousSanitizedTranscript: previous.sanitized,
            previousRawInputEvidence: previous.evidence,
            preservedVisibleToolResultRowIDs: [preservedID]
        )
        XCTAssertNotEqual(preserved.incrementalPathReason, .rawInputActivityComparison)
        XCTAssertEqual(preserved.reusedActivityCount, 0)
        XCTAssertNil(preserved.activityProcessingFlags)
        XCTAssertEqual(
            preserved.transcript,
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
                raw,
                preservedVisibleToolResultRowIDs: [preservedID]
            ).transcript
        )
    }

    func testEmptyAndToolFreeTranscriptsEqualCold() {
        for transcript in [
            AgentTranscript(turns: [], nextSequenceIndex: 0),
            Self.importTranscript([.user("hi", sequenceIndex: 0), .assistant("hello", sequenceIndex: 1)])
        ] {
            let previous = (
                evidence: AgentSanitizeRawInputEvidence(importedTranscript: transcript, activityProcessingFlags: []),
                sanitized: transcript
            )
            XCTAssertEqual(assertReuseEqualsCold(transcript, previous: previous).reusedActivityCount, 0)
        }
    }

    // MARK: - Helpers

    private typealias Previous = (evidence: AgentSanitizeRawInputEvidence, sanitized: AgentTranscript)

    @discardableResult
    private func assertReuseEqualsCold(
        _ transcript: AgentTranscript,
        previous: Previous,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AgentSanitizedTranscriptMetrics {
        let cold = Self.cold(transcript)
        let reuseContext = AgentToolResultProcessingContext()
        let reuse = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previous.sanitized,
            previousRawInputEvidence: previous.evidence,
            context: reuseContext
        )
        XCTAssertEqual(reuse.transcript, cold.metrics.transcript, "sanitized transcript", file: file, line: line)
        XCTAssertEqual(reuse.sanitizedActivityCount, cold.metrics.sanitizedActivityCount, "mutation count", file: file, line: line)
        XCTAssertEqual(reuse.activityProcessingFlags, cold.metrics.activityProcessingFlags, "processing flags", file: file, line: line)
        // The VM refreshes grouped caches after sanitize, keeping a validated reused prefix.
        XCTAssertEqual(
            Self.groupedHistoryCaches(Self.refreshed(reuse)),
            Self.groupedHistoryCaches(Self.refreshed(cold.metrics)),
            "grouped-history caches after refresh",
            file: file,
            line: line
        )
        let ids = Self.activityIDs(transcript)
        XCTAssertEqual(Self.registeredExecutions(reuseContext, ids: ids), Self.registeredExecutions(cold.context, ids: ids), "context registration", file: file, line: line)
        return reuse
    }

    /// Evidence and installed output of a cold runtime build of `raw`, as an applied build
    /// records them (sanitize, then grouped-cache refresh).
    private static func evidence(_ raw: AgentTranscript) -> Previous {
        let metrics = cold(raw).metrics
        let flags = metrics.activityProcessingFlags ?? []
        return (AgentSanitizeRawInputEvidence(importedTranscript: raw, activityProcessingFlags: flags), refreshed(metrics))
    }

    private static func refreshed(_ metrics: AgentSanitizedTranscriptMetrics) -> AgentTranscript {
        AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: metrics.transcript,
            reusablePrefixTurnCount: metrics.reusedTurnCount
        )
    }

    private static func cold(_ transcript: AgentTranscript) -> (metrics: AgentSanitizedTranscriptMetrics, context: AgentToolResultProcessingContext) {
        let context = AgentToolResultProcessingContext()
        return (AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(transcript, context: context), context)
    }

    private static func importTranscript(
        _ items: [AgentChatItem],
        terminalState: AgentSessionRunState = .running
    ) -> AgentTranscript {
        AgentTranscriptIO.buildTranscript(from: items, terminalState: terminalState, compact: false)
    }

    static func bashItems(count: Int, firstIndex: Int = 0) -> [AgentChatItem] {
        var items: [AgentChatItem] = [.user("Run commands", sequenceIndex: 0)]
        for offset in 0 ..< count {
            let index = firstIndex + offset
            let invocationID = UUID()
            items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: #"{"command":"echo \#(index)"}"#, sequenceIndex: items.count))
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: #"{"command":"echo \#(index)"}"#,
                resultJSON: bashResultJSON(index: index, output: String(repeating: "line \(index)\n", count: 40)),
                isError: false,
                sequenceIndex: items.count
            ))
        }
        return items
    }

    static func bashResultJSON(index: Int, output: String) -> String {
        let object: [String: Any] = [
            "type": "commandExecution",
            "status": "completed",
            "processId": "process-\(index)",
            "exitCode": 0,
            "aggregatedOutput": output
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func activityIDs(_ transcript: AgentTranscript) -> [UUID] {
        transcript.turns.flatMap { $0.responseSpans.flatMap { $0.activities.map(\.id) } }
    }

    private static func groupedHistoryCaches(_ transcript: AgentTranscript) -> [AgentTranscriptFullRenderGroupedHistoryCache?] {
        transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) }
    }

    private static func registeredExecutions(
        _ context: AgentToolResultProcessingContext,
        ids: [UUID]
    ) -> [UUID: AgentTranscriptToolExecution?] {
        var registered: [UUID: AgentTranscriptToolExecution?] = [:]
        for id in ids {
            if case let .hit(execution) = context.lookupToolExecution(for: id) {
                registered[id] = .some(execution)
            }
        }
        return registered
    }
}
