@testable import RepoPromptApp
import XCTest

/// D0 view-model diagnostics: no-attempt reasons, bounded caller attribution on merged
/// mutation summaries, and Sanitize/ProjectionOnly/ProjectionBuild stage dimensions.
/// Diagnostics must never change admission or equality.
@MainActor
final class AgentTranscriptRefreshAttributionTests: XCTestCase {
    private typealias Summary = AgentModeViewModel.PendingSourceItemsMutationSummary
    private typealias Diagnosis = AgentModeViewModel.DerivedTranscriptIncrementalNoAttemptDiagnosis
    private typealias Caller = AgentModeViewModel.SourceItemsMutationCaller

    // MARK: - No-attempt reasons

    func testReasonNotLiveTakesPrecedenceAndStillReportsSummaryFlags() {
        let diagnosis = Diagnosis.diagnose(
            reason: .saveSession,
            hasPendingQuestion: true,
            summary: Summary(.structural)
        )

        XCTAssertEqual(diagnosis?.primary, .reasonNotLive)
        XCTAssertEqual(diagnosis?.summaryFlags.label, "user-structural-unranged")
    }

    func testPendingQuestionReportsOverlappingSummaryFlags() {
        let admissible = Diagnosis.diagnose(
            reason: .liveMutation,
            hasPendingQuestion: true,
            summary: Summary(.mutate(index: 3, itemKind: .assistant))
        )
        XCTAssertEqual(admissible?.primary, .pendingQuestion)
        XCTAssertNil(admissible?.summaryFlags.label)

        let rejecting = Diagnosis.diagnose(
            reason: .liveMutation,
            hasPendingQuestion: true,
            summary: Summary(.remove(index: 2, itemKind: .assistant))
        )
        XCTAssertEqual(rejecting?.primary, .pendingQuestion)
        XCTAssertEqual(rejecting?.summaryFlags.label, "removal-structural")
    }

    func testMissingSummary() {
        let diagnosis = Diagnosis.diagnose(reason: .liveMutation, hasPendingQuestion: false, summary: nil)

        XCTAssertEqual(diagnosis?.primary, .missingSummary)
        XCTAssertNil(diagnosis?.summaryFlags.label)
    }

    func testSummaryRejectedReportsEveryOverlappingFlag() {
        let cases: [(AgentModeViewModel.SourceItemsMutation, String)] = [
            (.remove(index: 2, itemKind: .assistant), "removal-structural"),
            (.replaceAll, "replaceAll-user-structural-unranged"),
            (.append(index: 4, itemKind: .user), "user"),
            (.replace(index: 4, previousKind: .assistant, currentKind: .user), "user"),
            (.structural, "user-structural-unranged")
        ]
        for (mutation, expectedFlags) in cases {
            let summary = Summary(mutation)
            XCTAssertFalse(summary.allowsIncrementalFinalTurnRebuild, "\(mutation)")
            let diagnosis = Diagnosis.diagnose(reason: .liveMutation, hasPendingQuestion: false, summary: summary)
            XCTAssertEqual(diagnosis?.primary, .summaryRejected, "\(mutation)")
            XCTAssertEqual(diagnosis?.summaryFlags.label, expectedFlags, "\(mutation)")
        }
    }

    func testAdmissibleSummaryProducesNoDiagnosis() {
        var summary = Summary(.mutate(index: 3, itemKind: .assistant))
        summary.merge(.append(index: 4, itemKind: .toolCall))

        XCTAssertTrue(summary.allowsIncrementalFinalTurnRebuild)
        XCTAssertFalse(summary.containsUnrangedMutation)
        XCTAssertNil(Diagnosis.diagnose(reason: .liveMutation, hasPendingQuestion: false, summary: summary))
    }

    func testUnrangedFlagIsStickyAcrossMergesAndAdmissionIsUnchanged() {
        var summary = Summary(.mutate(index: 5, itemKind: .assistant))
        summary.merge(.structural)
        summary.merge(.mutate(index: 6, itemKind: .assistant))

        XCTAssertTrue(summary.containsUnrangedMutation)
        XCTAssertEqual(summary.earliestChangedIndex, 0)
        XCTAssertEqual(summary.latestChangedIndex, Int.max)
        XCTAssertFalse(summary.allowsIncrementalFinalTurnRebuild)
    }

    func testDiagnosticFieldsDoNotParticipateInEquality() {
        let first = Summary(.mutate(index: 3, itemKind: .assistant), caller: caller("first", line: 1))
        var second = Summary(.mutate(index: 3, itemKind: .assistant), caller: caller("second", line: 2))
        second.containsUnrangedMutation = true

        XCTAssertEqual(first, second)
    }

    // MARK: - Caller attribution

    func testCallerLabelIsBoundedStaticLocation() {
        XCTAssertEqual(
            Caller(fileID: "RepoPrompt/Dir/Coordinator.swift", function: "endSegment(for:at:)", line: 42).label,
            "Coordinator.swift_L42_endSegment"
        )
        XCTAssertEqual(Caller.itemsDidSet.label, "TabSession_L0_items.didSet")
    }

    #if DEBUG
        func testMergeRetainsFirstRejectingSourceAndEarliestChangeCaller() throws {
            var summary = Summary(.mutate(index: 5, itemKind: .assistant), caller: caller("first", line: 1))
            let initial = try XCTUnwrap(summary.debugAttribution)
            XCTAssertNil(initial.firstRejectingCaller)
            XCTAssertNil(initial.firstUnrangedCaller)
            XCTAssertEqual(initial.mergedMutationCount, 1)

            summary.merge(.mutate(index: 3, itemKind: .assistant), caller: caller("lower", line: 2))
            summary.merge(.structural, caller: caller("rejecting", line: 3))
            summary.merge(.remove(index: 1, itemKind: .assistant), caller: caller("laterRemoval", line: 4))
            summary.merge(.structural, caller: caller("laterUnranged", line: 5))

            let attribution = try XCTUnwrap(summary.debugAttribution)
            XCTAssertEqual(attribution.firstCaller.label, "File.swift_L1_first")
            XCTAssertEqual(attribution.firstRejectingCaller?.label, "File.swift_L3_rejecting")
            XCTAssertEqual(attribution.firstUnrangedCaller?.label, "File.swift_L3_rejecting")
            XCTAssertEqual(attribution.earliestChangeCaller.label, "File.swift_L3_rejecting")
            XCTAssertEqual(attribution.mergedMutationCount, 5)
        }

        func testEarliestChangeCallerTracksLowestRangedIndex() throws {
            var summary = Summary(.mutate(index: 6, itemKind: .assistant), caller: caller("six", line: 6))
            summary.merge(.mutate(index: 3, itemKind: .assistant), caller: caller("three", line: 3))
            summary.merge(.mutate(index: 4, itemKind: .assistant), caller: caller("four", line: 4))

            let attribution = try XCTUnwrap(summary.debugAttribution)
            XCTAssertEqual(attribution.earliestChangeCaller.label, "File.swift_L3_three")
            XCTAssertNil(attribution.firstRejectingCaller)
            XCTAssertEqual(attribution.mergedMutationCount, 3)
        }

        func testInitialRejectingMutationIsItsOwnRejectingSource() throws {
            let summary = Summary(.replaceAll, caller: caller("replaceAll", line: 9))

            let attribution = try XCTUnwrap(summary.debugAttribution)
            XCTAssertEqual(attribution.firstRejectingCaller?.label, "File.swift_L9_replaceAll")
            XCTAssertEqual(attribution.firstUnrangedCaller?.label, "File.swift_L9_replaceAll")
        }

        func testRefreshDiagnosticCallerSelectsSlotAndCount() {
            var summary = Summary(.mutate(index: 5, itemKind: .assistant), caller: caller("first", line: 1))
            summary.merge(.mutate(index: 2, itemKind: .assistant), caller: caller("earliest", line: 2))
            summary.merge(.append(index: 6, itemKind: .user), caller: caller("user", line: 3))

            let rejecting = AgentModeViewModel.transcriptRefreshDiagnosticCaller(summary, preferEarliestChange: false)
            XCTAssertEqual(rejecting.label, "File.swift_L3_user")
            XCTAssertEqual(rejecting.mergedCount, 3)
            let earliest = AgentModeViewModel.transcriptRefreshDiagnosticCaller(summary, preferEarliestChange: true)
            XCTAssertEqual(earliest.label, "File.swift_L2_earliest")
            XCTAssertNil(AgentModeViewModel.transcriptRefreshDiagnosticCaller(nil, preferEarliestChange: false).label)
        }
    #endif

    func testTabSessionMutationEntriesDeliverOriginalCallerThroughCallback() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        var received: [(mutation: AgentModeViewModel.SourceItemsMutation, caller: Caller)] = []
        session.onSourceItemsChanged = { _, mutation, caller in
            received.append((mutation, caller))
        }
        let expectedSuffix = "_testTabSessionMutationEntriesDeliverOriginalCallerThroughCallback"

        session.appendItem(.user("question", sequenceIndex: 0))
        session.appendItem(.assistant("answer", sequenceIndex: 1))
        session.mutateItem(at: 1) { $0.text = "answer, revised" }
        session.updateLastItem { $0.text = "answer, final" }
        session.mutateItemsBatch { $0.append(.assistant("batch", sequenceIndex: 2)) }
        _ = session.removeItem(at: 2)
        session.items = []

        guard received.count == 7 else {
            return XCTFail("Expected 7 callback deliveries, got \(received.count)")
        }
        for entry in received.prefix(6) {
            XCTAssertTrue(
                entry.caller.label.hasPrefix("AgentTranscriptRefreshAttributionTests.swift_L"),
                entry.caller.label
            )
            XCTAssertTrue(entry.caller.label.hasSuffix(expectedSuffix), entry.caller.label)
        }
        XCTAssertEqual(received.last?.caller.label, Caller.itemsDidSet.label)
        guard case .structural = received[4].mutation else {
            return XCTFail("mutateItemsBatch default mutation must stay .structural")
        }
    }

    // MARK: - Stage dimensions

    func testFinalTurnItemCountCountsFromLastUserItem() {
        let items = twoTurnItems()

        XCTAssertEqual(AgentModeViewModel.transcriptDiagnosticFinalTurnItemCount(items), 2)
        XCTAssertNil(AgentModeViewModel.transcriptDiagnosticFinalTurnItemCount([.assistant("only", sequenceIndex: 0)]))
        XCTAssertNil(AgentModeViewModel.transcriptDiagnosticFinalTurnItemCount([]))
    }

    #if DEBUG
        func testTabTagIsCoarseUUIDPrefix() throws {
            let tabID = try XCTUnwrap(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
            XCTAssertEqual(AgentModeViewModel.transcriptDiagnosticTabTag(tabID), "ABCDEF01")
        }

        func testIncrementalImportShapeCarriesFinalTurnStartAndSuffixCount() {
            let shapes: [(AgentTranscriptIncrementalImportResult, Int?, Int?)] = [
                (.rejected(.emptyItems), nil, nil),
                (.rejected(.changeBeforeFinalTurn(earliestChangedIndex: 0, finalTurnStartIndex: 4, finalTurnItemCount: 3)), 4, nil),
                (.rejected(.suffixTurnCountMismatch(suffixTurnCount: 2, finalTurnStartIndex: 5, finalTurnItemCount: 1)), 5, 2),
                (.rejected(.requestIDMismatch(finalTurnStartIndex: 6, finalTurnItemCount: 2)), 6, 1)
            ]
            for (result, expectedStart, expectedSuffix) in shapes {
                let shape = AgentModeViewModel.incrementalImportDiagnosticShape(result)
                XCTAssertEqual(shape.finalTurnStartIndex, expectedStart, "\(result)")
                XCTAssertEqual(shape.suffixTurnCount, expectedSuffix, "\(result)")
            }
        }

        func testSanitizeAndProjectionStagesCarryTabAndItemCountDimensions() throws {
            try EditFlowPerf.$debugCaptureIsolationTokenForTesting.withValue(UUID()) {
                switch EditFlowPerf.beginDebugCapture(label: "d0-stage-dimensions", maxSamples: 100) {
                case .started:
                    break
                case .busy:
                    return XCTFail("Capture should start.")
                }
                let items = twoTurnItems()
                let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)

                _ = AgentModeViewModel.buildTranscriptPresentation(
                    from: transcript,
                    sourceItems: items,
                    selectedAgent: .codexExec,
                    previousPerformanceSnapshot: .empty,
                    diagnosticTabTag: "TAB0D0"
                )

                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
                for stageName in [
                    "EditFlow.Transcript.Sanitize",
                    "EditFlow.Transcript.ProjectionOnly",
                    "EditFlow.Transcript.ProjectionBuild"
                ] {
                    let aggregate = try XCTUnwrap(
                        snapshot.stages.first { $0.stageName == stageName },
                        "missing \(stageName)"
                    )
                    let dimensions = aggregate.sanitizedDimensions
                    XCTAssertTrue(dimensions.contains("tab=TAB0D0"), "\(stageName): \(dimensions)")
                    XCTAssertTrue(dimensions.contains("sourceItemCount=4"), "\(stageName): \(dimensions)")
                    XCTAssertTrue(dimensions.contains("finalTurnItemCount=2"), "\(stageName): \(dimensions)")
                }
                let sanitize = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.Transcript.Sanitize" })
                XCTAssertTrue(
                    sanitize.sanitizedDimensions.contains("reason=trustedSuffixUnavailable"),
                    sanitize.sanitizedDimensions
                )
            }
        }

        func testBashParserCacheCounterSnapshotsReachDebugCapture() throws {
            try EditFlowPerf.$debugCaptureIsolationTokenForTesting.withValue(UUID()) {
                switch EditFlowPerf.beginDebugCapture(label: "d0-parser-cache-counters", maxSamples: 100) {
                case .started:
                    break
                case .busy:
                    return XCTFail("Capture should start.")
                }
                let items = twoTurnItems()

                _ = AgentModeViewModel.buildTranscriptPresentation(
                    from: AgentTranscriptIO.buildTranscript(from: items, compact: false),
                    sourceItems: items,
                    selectedAgent: .codexExec,
                    previousPerformanceSnapshot: .empty
                )

                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
                let counterSpans = snapshot.stages.filter { $0.stageName == "EditFlow.Transcript.BashParserCache" }
                for table in ["metadata", "parsed"] {
                    let aggregate = try XCTUnwrap(
                        counterSpans.first { $0.sanitizedDimensions.contains("scanKind=\(table)") },
                        "missing \(table) counter snapshot"
                    )
                    let dimensions = Dictionary(
                        uniqueKeysWithValues: aggregate.sanitizedDimensions.split(separator: " ").compactMap { part in
                            let pair = part.split(separator: "=", maxSplits: 1)
                            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
                        }
                    )
                    for counter in ["hitCount", "missCount", "evictedCount", "entryCount"] {
                        let value = try XCTUnwrap(dimensions[counter], "\(table) missing \(counter)")
                        XCTAssertNotNil(Int(value), "\(table) \(counter)=\(value)")
                    }
                }
            }
        }
    #endif

    // MARK: - Helpers

    private func caller(_ function: StaticString, line: UInt) -> Caller {
        Caller(fileID: "RepoPrompt/File.swift", function: function, line: line)
    }

    private func twoTurnItems() -> [AgentChatItem] {
        [
            .user("First question", sequenceIndex: 0),
            .assistant("First answer.", sequenceIndex: 1),
            .user("Second question", sequenceIndex: 2),
            .assistant("Second answer.", sequenceIndex: 3)
        ]
    }
}
