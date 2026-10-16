@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// D0 runtime diagnostics: incremental-import rejection reasons, sanitize incremental-path reasons,
/// and process-wide bash parser cache counters. Diagnostics must never change outputs.
final class AgentTranscriptRefreshDiagnosticsTests: XCTestCase {
    // MARK: - Incremental import

    func testIncrementalImportSuccessReportsFinalTurnSizeAndMatchesWrapper() {
        let items = twoTurnItems()
        let existing = AgentTranscriptIO.buildTranscript(from: Array(items.prefix(3)), compact: false)

        let diagnostic = importDiagnostic(existing: existing, items: items, earliestChangedIndex: 3)

        guard case let .updated(transcript, finalTurnStartIndex, finalTurnItemCount) = diagnostic else {
            return XCTFail("Expected incremental update, got \(diagnostic)")
        }
        XCTAssertEqual(finalTurnStartIndex, 2)
        XCTAssertEqual(finalTurnItemCount, 2)
        XCTAssertNil(diagnostic.rejection)
        XCTAssertEqual(transcript, importWrapper(existing: existing, items: items, earliestChangedIndex: 3))
    }

    func testIncrementalImportRejectsEmptyItems() {
        let existing = AgentTranscriptIO.buildTranscript(from: twoTurnItems(), compact: false)
        assertImportRejected(existing: existing, items: [], earliestChangedIndex: 0, expected: .emptyItems)
    }

    func testIncrementalImportRejectsEmptyExistingTranscript() {
        assertImportRejected(
            existing: AgentTranscript(),
            items: twoTurnItems(),
            earliestChangedIndex: 3,
            expected: .emptyExistingTranscript
        )
    }

    func testIncrementalImportRejectsInvalidFrontier() {
        let items = twoTurnItems()
        var existing = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        existing.compactionFrontier = nil
        existing.turns[0].retentionTier = .summary
        assertImportRejected(existing: existing, items: items, earliestChangedIndex: 3, expected: .invalidFrontier)
    }

    func testIncrementalImportRejectsMissingFinalTurnStart() {
        let existing = AgentTranscriptIO.buildTranscript(from: twoTurnItems(), compact: false)
        assertImportRejected(
            existing: existing,
            items: [.assistant("Orphan answer.", sequenceIndex: 0)],
            earliestChangedIndex: 0,
            expected: .noFinalTurnStart
        )
    }

    func testIncrementalImportRejectsChangeBeforeFinalTurnWithBoundaries() {
        let items = twoTurnItems()
        let existing = AgentTranscriptIO.buildTranscript(from: items, compact: false)
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 1,
            expected: .changeBeforeFinalTurn(earliestChangedIndex: 1, finalTurnStartIndex: 2, finalTurnItemCount: 2)
        )
    }

    func testIncrementalImportRejectsSuffixThatRebuildsIntoMultipleTurns() {
        // The suffix's assistant row sorts before its user row, so the suffix rebuilds into two turns.
        let items: [AgentChatItem] = [
            .user("First question", sequenceIndex: 0),
            .assistant("First answer.", sequenceIndex: 1),
            .user("Second question", sequenceIndex: 5),
            .assistant("Out of order answer.", sequenceIndex: 3)
        ]
        let existing = AgentTranscriptIO.buildTranscript(from: Array(items.prefix(2)), compact: false)
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 3,
            expected: .suffixTurnCountMismatch(suffixTurnCount: 2, finalTurnStartIndex: 2, finalTurnItemCount: 2)
        )
    }

    func testIncrementalImportRejectsRequestIDMismatch() {
        let existing = AgentTranscriptIO.buildTranscript(
            from: [.user("Question", sequenceIndex: 0), .assistant("Answer.", sequenceIndex: 1)],
            compact: false
        )
        let items: [AgentChatItem] = [
            .user("Question", sequenceIndex: 0),
            .assistant("Answer.", sequenceIndex: 1)
        ]
        assertImportRejected(
            existing: existing,
            items: items,
            earliestChangedIndex: 1,
            expected: .requestIDMismatch(finalTurnStartIndex: 0, finalTurnItemCount: 2)
        )
    }

    // MARK: - Sanitize incremental path

    func testSanitizeActivitySuffixSuccessReason() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[3] = makeReadFileActivity(id: activities[3].id, sequenceIndex: 3, marker: "after")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .activitySuffixSuccess)
    }

    func testSanitizePersistencePurposeReportsNotRuntimePresentation() {
        let fixture = SanitizeFixture()
        let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(fixture.previousRaw)
        XCTAssertEqual(metrics.incrementalPathReason, .notRuntimePresentation)
    }

    func testSanitizeReportsTrustedSuffixUnavailable() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: fixture.previousSanitized, start: nil, expected: .trustedSuffixUnavailable)
    }

    func testSanitizeReportsPreviousSanitizedTranscriptUnavailable() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: nil, start: 3, expected: .previousSanitizedTranscriptUnavailable)
    }

    func testSanitizeReportsTurnCountMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns.insert(fixture.turn(id: UUID(), activities: [fixture.activities[0]]), at: 0)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .turnCountMismatch)
    }

    func testSanitizeReportsReusedPrefixMismatch() {
        let fixture = SanitizeFixture()
        let prefixTurn = fixture.turn(id: UUID(), activities: [makeReadFileActivity(id: UUID(), sequenceIndex: 0, marker: "prefix")])
        var previousRaw = fixture.previousRaw
        previousRaw.turns.insert(prefixTurn, at: 0)
        let previousSanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(previousRaw).transcript
        assertSanitizeReason(previousRaw, previous: previousSanitized, start: 3, expected: .reusedPrefixMismatch)
    }

    func testSanitizeReportsFinalTurnMissing() {
        assertSanitizeReason(AgentTranscript(), previous: AgentTranscript(), start: 0, expected: .finalTurnMissing)
    }

    func testSanitizeReportsFinalTurnIdentityMismatch() {
        let fixture = SanitizeFixture()
        let updated = AgentTranscript(turns: [fixture.turn(id: UUID(), activities: fixture.activities)], nextSequenceIndex: 4)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .finalTurnIdentityMismatch)
    }

    func testSanitizeReportsRequestMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].request = AgentTranscriptRequestAnchor(from: .user("Different request"))
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .requestMismatch)
    }

    func testSanitizeReportsSpanCountMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].responseSpans.append(
            AgentTranscriptProviderResponseSpan(startedAt: fixture.startedAt, activities: [])
        )
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .spanCountMismatch)
    }

    func testSanitizeReportsSpanIdentityMismatch() {
        let fixture = SanitizeFixture()
        var updated = fixture.previousRaw
        updated.turns[0].responseSpans = [
            AgentTranscriptProviderResponseSpan(id: UUID(), startedAt: fixture.startedAt, activities: fixture.activities)
        ]
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .spanIdentityMismatch)
    }

    func testSanitizeReportsUnchangedSpanMismatch() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[3] = makeReadFileActivity(id: UUID(), sequenceIndex: 3, marker: "replaced")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 10, expected: .unchangedSpanMismatch)
    }

    func testSanitizeReportsChangedActivityIndexOutOfRange() {
        let fixture = SanitizeFixture()
        let appended = (4 ..< 7).map { makeReadFileActivity(id: UUID(), sequenceIndex: $0, marker: "appended-\($0)") }
        let updated = fixture.transcript(activities: fixture.activities + appended)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 5, expected: .changedActivityIndexOutOfRange)
    }

    func testSanitizeReportsPrefixBoundaryMismatch() {
        let fixture = SanitizeFixture()
        var activities = fixture.activities
        activities[2] = makeReadFileActivity(id: UUID(), sequenceIndex: 2, marker: "replaced")
        activities[3] = makeReadFileActivity(id: activities[3].id, sequenceIndex: 3, marker: "after")
        let updated = fixture.transcript(activities: activities)
        assertSanitizeReason(updated, previous: fixture.previousSanitized, start: 3, expected: .prefixBoundaryMismatch)
    }

    func testSanitizeReportsChangedSuffixNotFound() {
        let fixture = SanitizeFixture()
        assertSanitizeReason(fixture.previousRaw, previous: fixture.previousSanitized, start: 10, expected: .changedSuffixNotFound)
    }

    // MARK: - Interrupted final-turn envelope through a rebuild

    /// A cold-cancelled (and an explicitly failed) final turn keeps its terminal envelope through an
    /// idle or unspecified rebuild with an unchanged source extent, on the full and incremental paths;
    /// a content-only repair of an existing row is applied without losing the envelope.
    func testRebuildPreservesInterruptedFinalTurnEnvelopeWhenSourceExtentIsUnchanged() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinal = try XCTUnwrap(existing.turns.last)
        XCTAssertEqual(existingFinal.terminalState, .cancelled)
        XCTAssertEqual(existingFinal.responseSpans.map(\.lifecycle), [.cancelled])
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        // Baseline the guard exists for: a fresh import at the restored idle state loses cancellation.
        let freshFinal = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: workingItems, terminalState: .idle).turns.last)
        XCTAssertEqual(freshFinal.terminalState, .idle)
        XCTAssertEqual(freshFinal.responseSpans.map(\.lifecycle), [.completed])

        let cases: [(label: String, terminalState: AgentSessionRunState?, earliestChangedIndex: Int?)] = [
            ("idle full", .idle, nil),
            ("unspecified full", nil, nil),
            ("idle incremental", .idle, 4),
            ("equal explicit", .cancelled, nil)
        ]
        for (label, terminalState, earliestChangedIndex) in cases {
            let rebuilt = rebuild(existing, items: workingItems, terminalState: terminalState, earliestChangedIndex: earliestChangedIndex)
            let final = try XCTUnwrap(rebuilt.turns.last, label)
            XCTAssertEqual(final.id, existingFinal.id, label)
            XCTAssertEqual(final.terminalState, .cancelled, label)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.cancelled], label)
            XCTAssertEqual(final.responseSpans.map(\.completedAt), existingFinal.responseSpans.map(\.completedAt), label)
            XCTAssertEqual(final.completedAt, existingFinal.completedAt, label)
            XCTAssertEqual(rebuilt.turns.first?.terminalState, existing.turns.first?.terminalState, label)
        }

        // A content repair of an existing row (same IDs) is not new source activity.
        var repairedItems = workingItems
        let resultIndex = try XCTUnwrap(repairedItems.lastIndex { $0.kind == .toolResult })
        repairedItems[resultIndex].toolResultJSON = #"{"output":"repaired"}"#
        repairedItems[resultIndex].text = #"{"output":"repaired"}"#
        let repaired = try XCTUnwrap(rebuild(existing, items: repairedItems, terminalState: .idle).turns.last)
        XCTAssertEqual(repaired.terminalState, .cancelled)
        XCTAssertEqual(repaired.responseSpans.map(\.lifecycle), [.cancelled])
        XCTAssertTrue(repaired.allActivities.contains { $0.toItem().toolResultJSON?.contains("repaired") == true })

        // An explicitly failed final turn is an interrupted envelope too.
        let failed = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .failed,
            nextSequenceIndex: items.count,
            compact: false
        )
        let failedFinal = try XCTUnwrap(failed.turns.last)
        XCTAssertEqual(failedFinal.terminalState, .failed)
        let rebuiltFailed = try XCTUnwrap(rebuild(failed, items: items, terminalState: .idle).turns.last)
        XCTAssertEqual(rebuiltFailed.terminalState, .failed)
        XCTAssertEqual(rebuiltFailed.responseSpans.map(\.lifecycle), failedFinal.responseSpans.map(\.lifecycle))
    }

    /// A turn interrupted mid-tool (its final `toolCall` has no `toolResult`, e.g. bash was running
    /// when the app quit) keeps its cancelled envelope through the real sequence: a session persisted
    /// while running → the data service's load normalization (cold-restore sanitize) → the VM save's
    /// pending-tool repair at the restored idle state → the save's rebuild at idle. The repair turns the
    /// unmatched `toolCall` row into a `toolResult` in place (same ID), so the source extent is unchanged.
    ///
    /// Two writers: the live transcript a running VM persists (built at `.running`, open spans, which
    /// sanitize closes as cancelled), and an item-only session whose transcript was built without a run
    /// state (closed `.completed` spans; sanitize cancels the turn for its pending tool but leaves the
    /// already-closed spans). The rebuild keeps whatever envelope the restore produced.
    func testMidToolInterruptedTurnKeepsCancelledEnvelopeThroughLoadRepairAndSaveRebuild() async throws {
        let invocation = UUID()
        let items: [AgentChatItem] = [
            .user("First request", sequenceIndex: 0),
            .assistant("First reply", sequenceIndex: 1),
            .user("Second request", sequenceIndex: 2),
            .assistant("Running it.", sequenceIndex: 3),
            .toolCall(name: "bash", invocationID: invocation, argsJSON: #"{"command":"sleep 60"}"#, sequenceIndex: 4)
        ]
        let pendingCallID = try XCTUnwrap(items.last?.id)
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTranscriptRefreshDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let workspace = WorkspaceModel(id: UUID(), name: "Mid-tool interruption", repoPaths: ["/tmp/repo"], customStoragePath: storage)
        let liveRunningTranscript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .running,
            nextSequenceIndex: items.count,
            policy: .liveSession(hidePendingQuestionToolCall: false)
        )
        let writers: [(label: String, transcript: AgentTranscript?, restoredSpans: [AgentTranscriptSpanLifecycle])] = [
            ("live running transcript", liveRunningTranscript, [.cancelled]),
            ("item-only transcript", nil, [.completed])
        ]
        for writer in writers {
            let label = writer.label
            var persisted = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: label).withItems(items)
            if let transcript = writer.transcript {
                persisted.transcript = transcript
            }
            persisted.lastRunState = AgentSessionRunState.running.rawValue
            let fileURL = try await AgentSessionDataService().saveAgentSession(persisted, for: workspace)

            // Load normalization, including the cold-restore sanitize.
            let loaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
            XCTAssertEqual(loaded.lastRunState, AgentSessionRunState.idle.rawValue, label)
            let restored = try XCTUnwrap(loaded.transcript, label)
            let restoredFinal = try XCTUnwrap(restored.turns.last, label)
            XCTAssertEqual(restoredFinal.terminalState, .cancelled, label)
            XCTAssertEqual(restoredFinal.responseSpans.map(\.lifecycle), writer.restoredSpans, label)
            var workingItems = loaded.items.map { $0.toItem() }
            let restoredCall = try XCTUnwrap(workingItems.last, label)
            XCTAssertEqual(restoredCall.id, pendingCallID, label)
            XCTAssertEqual(restoredCall.kind, .toolCall, "\(label): the restored turn still ends in the unmatched call")

            // The VM save's pending-tool repair at the restored idle state.
            let repairedCount = AgentTranscriptIO.finalizePendingToolCalls(
                in: &workingItems,
                terminalState: .idle,
                includeExplicitRepoPromptToolCalls: false,
                nonToolBoundary: 200
            )
            XCTAssertEqual(repairedCount, 1, label)
            let repairedRow = try XCTUnwrap(workingItems.last, label)
            XCTAssertEqual(repairedRow.id, pendingCallID, "\(label): the repair converts the row in place")
            XCTAssertEqual(repairedRow.kind, .toolResult, label)
            XCTAssertEqual(workingItems.count, items.count, label)

            // The save's rebuild at idle, with the live-session policy the VM save uses.
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: restored,
                workingItems: workingItems,
                terminalState: .idle,
                nextSequenceIndex: (workingItems.map(\.sequenceIndex).max() ?? -1) + 1,
                policy: .liveSession(hidePendingQuestionToolCall: false)
            )
            let final = try XCTUnwrap(rebuilt.turns.last, label)
            XCTAssertEqual(final.id, restoredFinal.id, label)
            XCTAssertEqual(final.terminalState, .cancelled, "\(label): the mid-tool interrupted turn stays cancelled")
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), writer.restoredSpans, label)
            XCTAssertEqual(final.completedAt, restoredFinal.completedAt, label)
            XCTAssertTrue(final.allActivities.contains { $0.id == pendingCallID && $0.itemKind == .toolResult }, label)
        }
    }

    /// New source activity in the interrupted turn takes the normal rebuild.
    func testRebuildDropsInterruptedEnvelopeWhenSourceExtentChanges() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinalID = try XCTUnwrap(existing.turns.last?.id)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        let appended = workingItems + [.assistant("Late reply", sequenceIndex: items.count)]
        for earliestChangedIndex in [Int?.none, appended.count - 1] {
            let label = "appended activity, incremental: \(earliestChangedIndex != nil)"
            let final = try XCTUnwrap(rebuild(existing, items: appended, terminalState: .idle, earliestChangedIndex: earliestChangedIndex).turns.last, label)
            XCTAssertEqual(final.id, existingFinalID, label)
            XCTAssertEqual(final.terminalState, .idle, label)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.completed], label)
        }

        // A non-final interrupted turn whose extent changes takes the normal rebuild too.
        let lateRow = AgentChatItem.assistant("Late reply", sequenceIndex: items.count)
        let changedThenNextTurn = workingItems + [lateRow, .user("Third request", sequenceIndex: items.count + 1)]
        let rebuilt = rebuild(existing, items: changedThenNextTurn, terminalState: .idle)
        XCTAssertEqual(rebuilt.turns.count, 3)
        let formerFinal = try XCTUnwrap(rebuilt.turns.first { $0.id == existingFinalID })
        XCTAssertNil(formerFinal.terminalState, "a changed non-final turn takes the normal rebuild")
        XCTAssertEqual(formerFinal.responseSpans.map(\.lifecycle), [.completed])
    }

    /// After a new turn, the former final interrupted turn keeps its envelope on the full path as the
    /// incremental path already does: no supplied state applies to a non-final turn, so it is kept for
    /// active, idle and explicit terminal states alike, while the new final turn takes the supplied state.
    func testRebuildPreservesEarlierInterruptedTurnEnvelopesAfterANewTurn() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let existingFinal = try XCTUnwrap(existing.turns.last)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)
        let nextTurn = workingItems + [.user("Third request", sequenceIndex: items.count)]

        let cases: [(label: String, terminalState: AgentSessionRunState?, earliestChangedIndex: Int?)] = [
            ("idle full", .idle, nil),
            ("running full", .running, nil),
            ("completed full", .completed, nil),
            ("idle incremental", .idle, nextTurn.count - 1),
            ("running incremental", .running, nextTurn.count - 1)
        ]
        for (label, terminalState, earliestChangedIndex) in cases {
            let rebuilt = rebuild(existing, items: nextTurn, terminalState: terminalState, earliestChangedIndex: earliestChangedIndex)
            XCTAssertEqual(rebuilt.turns.count, 3, label)
            let formerFinal = try XCTUnwrap(rebuilt.turns.first { $0.id == existingFinal.id }, label)
            XCTAssertEqual(formerFinal.terminalState, .cancelled, "\(label): the earlier interrupted turn stays cancelled")
            XCTAssertEqual(formerFinal.responseSpans.map(\.lifecycle), [.cancelled], label)
            XCTAssertEqual(formerFinal.completedAt, existingFinal.completedAt, label)
            XCTAssertEqual(rebuilt.turns.last?.terminalState, terminalState, label)
            XCTAssertEqual(rebuilt.turns.first?.terminalState, existing.turns.first?.terminalState, label)
        }
    }

    /// An active run never keeps the interrupted envelope, and a different explicit terminal state wins.
    func testRebuildIgnoresInterruptedEnvelopeForActiveRunsAndDifferentExplicitTerminalStates() throws {
        let items = interruptedTwoTurnItems()
        let existing = coldCancelledTranscript(from: items)
        let workingItems = AgentTranscriptIO.workingSourceItems(from: existing)

        for activeState in [AgentSessionRunState.running, .waitingForUser, .waitingForQuestion, .waitingForApproval] {
            let final = try XCTUnwrap(rebuild(existing, items: workingItems, terminalState: activeState).turns.last)
            XCTAssertEqual(final.terminalState, activeState, activeState.rawValue)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.open], activeState.rawValue)
            XCTAssertNil(final.completedAt, activeState.rawValue)
        }
        for explicitState in [AgentSessionRunState.completed, .failed] {
            let final = try XCTUnwrap(rebuild(existing, items: workingItems, terminalState: explicitState).turns.last)
            XCTAssertEqual(final.terminalState, explicitState, explicitState.rawValue)
            XCTAssertEqual(final.responseSpans.map(\.lifecycle), [.completed], explicitState.rawValue)
        }
    }

    // MARK: - Bash parser cache counters

    #if DEBUG || EDIT_FLOW_PERF
        func testBashParserCacheCountersTrackHitsMissesAndEvictionsWithoutChangingOutput() {
            let token = UUID().uuidString
            let raw = #"{"status":"completed","exit_code":0,"output":"\#(token)"}"#
            let argsJSON = #"{"command":"echo \#(token)"}"#

            let beforeMetadata = BashToolResultParser.cacheCountersSnapshot()
            let firstMetadata = BashToolResultParser.parseMetadata(raw: raw)
            let afterMetadataMiss = BashToolResultParser.cacheCountersSnapshot()
            let secondMetadata = BashToolResultParser.parseMetadata(raw: raw)
            let afterMetadataHit = BashToolResultParser.cacheCountersSnapshot()
            XCTAssertEqual(firstMetadata, secondMetadata)
            XCTAssertEqual(firstMetadata, BashToolResultParser.parseLivenessMetadata(raw: raw))
            XCTAssertGreaterThanOrEqual(afterMetadataMiss.metadata.missCount - beforeMetadata.metadata.missCount, 1)
            XCTAssertGreaterThanOrEqual(afterMetadataHit.metadata.hitCount - afterMetadataMiss.metadata.hitCount, 1)

            let firstParsed = BashToolResultParser.parse(raw: raw, argsJSON: argsJSON)
            let afterParsedMiss = BashToolResultParser.cacheCountersSnapshot()
            let secondParsed = BashToolResultParser.parse(raw: raw, argsJSON: argsJSON)
            let afterParsedHit = BashToolResultParser.cacheCountersSnapshot()
            XCTAssertEqual(firstParsed, secondParsed)
            XCTAssertGreaterThanOrEqual(afterParsedMiss.parsed.missCount - afterMetadataHit.parsed.missCount, 1)
            XCTAssertGreaterThanOrEqual(afterParsedHit.parsed.hitCount - afterParsedMiss.parsed.hitCount, 1)

            // Eviction is two-generation (D3); exercise it on a small isolated cache so the
            // process-wide table's larger working set does not hide the counters.
            let smallCache = BashToolResultParser.Cache(
                limits: .init(maxEntriesPerGeneration: 128, maxBytesPerTable: 16 * 1024 * 1024)
            )
            for index in 0 ..< 300 {
                let indexedRaw = #"{"status":"completed","output":"\#(token)-\#(index)"}"#
                _ = smallCache.metadata(raw: indexedRaw) { BashToolResultParser.parseLivenessMetadata(raw: indexedRaw) }
            }
            let afterEviction = smallCache.countersSnapshot().metadata
            XCTAssertEqual(afterEviction.missCount, 300)
            XCTAssertEqual(afterEviction.evictedEntryCount, 128)
            XCTAssertEqual(afterEviction.currentEntryCount, 172)
        }
    #endif

    // MARK: - Helpers

    private func twoTurnItems() -> [AgentChatItem] {
        [
            .user("First question", sequenceIndex: 0),
            .assistant("First answer.", sequenceIndex: 1),
            .user("Second question", sequenceIndex: 2),
            .assistant("Second answer.", sequenceIndex: 3)
        ]
    }

    /// Two bash turns; the final turn is the one a cold restore interrupts.
    private func interruptedTwoTurnItems() -> [AgentChatItem] {
        let firstInvocation = UUID()
        let secondInvocation = UUID()
        return [
            .user("First request", sequenceIndex: 0),
            .toolCall(name: "bash", invocationID: firstInvocation, argsJSON: #"{"command":"echo 0"}"#, sequenceIndex: 1),
            .toolResult(name: "bash", invocationID: firstInvocation, resultJSON: #"{"output":"0"}"#, sequenceIndex: 2),
            .assistant("First reply", sequenceIndex: 3),
            .user("Second request", sequenceIndex: 4),
            .toolCall(name: "bash", invocationID: secondInvocation, argsJSON: #"{"command":"echo 1"}"#, sequenceIndex: 5),
            .toolResult(name: "bash", invocationID: secondInvocation, resultJSON: #"{"output":"1"}"#, sequenceIndex: 6),
            .assistant("Second reply", sequenceIndex: 7)
        ]
    }

    /// The transcript a cold restore produces for a session persisted while running.
    private func coldCancelledTranscript(from items: [AgentChatItem]) -> AgentTranscript {
        AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
            AgentTranscriptIO.buildTranscript(
                from: items,
                terminalState: .running,
                nextSequenceIndex: items.count,
                compact: false
            )
        )
    }

    private func rebuild(
        _ existing: AgentTranscript,
        items: [AgentChatItem],
        terminalState: AgentSessionRunState?,
        earliestChangedIndex: Int? = nil
    ) -> AgentTranscript {
        AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: existing,
            workingItems: items,
            earliestChangedIndex: earliestChangedIndex,
            terminalState: terminalState,
            nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1
        )
    }

    private func importDiagnostic(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int
    ) -> AgentTranscriptIncrementalImportResult {
        AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics(
            existingTranscript: existing,
            items: items,
            earliestChangedIndex: earliestChangedIndex,
            nextSequenceIndex: items.count
        )
    }

    private func importWrapper(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int
    ) -> AgentTranscript? {
        AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
            existingTranscript: existing,
            items: items,
            earliestChangedIndex: earliestChangedIndex,
            nextSequenceIndex: items.count
        )
    }

    private func assertImportRejected(
        existing: AgentTranscript,
        items: [AgentChatItem],
        earliestChangedIndex: Int,
        expected: AgentTranscriptIncrementalImportRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostic = importDiagnostic(existing: existing, items: items, earliestChangedIndex: earliestChangedIndex)
        XCTAssertEqual(diagnostic, .rejected(expected), file: file, line: line)
        XCTAssertNil(diagnostic.transcript, file: file, line: line)
        XCTAssertEqual(diagnostic.finalTurnItemCount, expected.finalTurnItemCount, file: file, line: line)
        XCTAssertNil(importWrapper(existing: existing, items: items, earliestChangedIndex: earliestChangedIndex), file: file, line: line)
    }

    /// Asserts the reason and that the result equals full sanitization (diagnostics never change output).
    private func assertSanitizeReason(
        _ transcript: AgentTranscript,
        previous: AgentTranscript?,
        start: Int?,
        expected: AgentSanitizeIncrementalPathReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previous,
            trustedReusablePrefixTurnCount: 0,
            trustedIncrementalFinalTurnStartSequenceIndex: start
        )
        XCTAssertEqual(metrics.incrementalPathReason, expected, file: file, line: line)
        XCTAssertEqual(
            metrics.transcript,
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(transcript).transcript,
            file: file,
            line: line
        )
    }

    private struct SanitizeFixture {
        let turnID = UUID()
        let spanID = UUID()
        let request = AgentTranscriptRequestAnchor(from: .user("Request"))
        let startedAt = Date(timeIntervalSinceReferenceDate: 1)
        let activities: [AgentTranscriptActivity] = (0 ..< 4).map {
            makeReadFileActivity(id: UUID(), sequenceIndex: $0, marker: "before-\($0)")
        }

        var previousRaw: AgentTranscript {
            transcript(activities: activities)
        }

        var previousSanitized: AgentTranscript {
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(previousRaw).transcript
        }

        func turn(id: UUID, activities: [AgentTranscriptActivity]) -> AgentTranscriptTurn {
            AgentTranscriptTurn(
                id: id,
                request: request,
                responseSpans: [
                    AgentTranscriptProviderResponseSpan(id: spanID, startedAt: startedAt, activities: activities)
                ],
                startedAt: startedAt
            )
        }

        func transcript(activities: [AgentTranscriptActivity]) -> AgentTranscript {
            AgentTranscript(turns: [turn(id: turnID, activities: activities)], nextSequenceIndex: 100)
        }
    }
}

private func makeReadFileActivity(id: UUID, sequenceIndex: Int, marker: String) -> AgentTranscriptActivity {
    let invocationID = UUID()
    let argsJSON = diagnosticsJSONString(["path": "/tmp/\(marker).txt"])
    let resultJSON = diagnosticsJSONString([
        "path": "/tmp/\(marker).txt",
        "content": String(repeating: "\(marker) payload ", count: 80)
    ])
    let execution = AgentTranscriptToolExecution(
        stableExecutionID: invocationID.uuidString,
        toolName: "read_file",
        invocationID: invocationID,
        argsJSON: argsJSON,
        resultJSON: resultJSON,
        toolIsError: false,
        status: .success
    )
    return AgentTranscriptActivity(
        id: id,
        timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
        sequenceIndex: sequenceIndex,
        role: .toolExecution,
        itemKind: .toolResult,
        text: resultJSON,
        toolExecution: execution
    )
}

private func diagnosticsJSONString(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
