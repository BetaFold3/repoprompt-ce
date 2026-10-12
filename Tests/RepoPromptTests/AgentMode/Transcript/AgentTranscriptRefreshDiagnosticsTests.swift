@testable import RepoPromptApp
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

            let beforeEviction = BashToolResultParser.cacheCountersSnapshot()
            for index in 0 ..< 300 {
                _ = BashToolResultParser.parseMetadata(raw: #"{"status":"completed","output":"\#(token)-\#(index)"}"#)
            }
            let afterEviction = BashToolResultParser.cacheCountersSnapshot()
            XCTAssertGreaterThanOrEqual(afterEviction.metadata.evictedEntryCount - beforeEviction.metadata.evictedEntryCount, 256)
            XCTAssertGreaterThanOrEqual(afterEviction.metadata.currentEntryCount, 1)
            XCTAssertLessThanOrEqual(afterEviction.metadata.currentEntryCount, 256)
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
