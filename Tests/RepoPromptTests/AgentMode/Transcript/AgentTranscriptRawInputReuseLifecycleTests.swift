@testable import RepoPromptApp
import XCTest

/// D4: the session's raw-input pair lifecycle, and the W3 differential oracle: a session using
/// raw-input reuse equals an independently driven session that derives cold at every step.
@MainActor
final class AgentTranscriptRawInputReuseLifecycleTests: XCTestCase {
    // MARK: - Pair lifecycle

    func testSuccessfulApplyInstallsEvidenceAndWarmFullImportReuses() async throws {
        let viewModel = makeViewModel()
        let session = try await viewModel.ensureSessionReady(tabID: UUID())
        session.runState = .running
        session.setItemsSilently(Self.bashHistory(resultCount: 6), reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)

        let evidence = try XCTUnwrap(session.rawInputSanitizeEvidence)
        XCTAssertEqual(evidence.importedTranscript.turns.map(\.id), session.transcript.turns.map(\.id))
        XCTAssertNotEqual(evidence.importedTranscript, session.transcript, "evidence holds the pre-sanitize input")
        XCTAssertEqual(
            evidence.activityProcessingFlags.map { $0.map(\.count) },
            evidence.importedTranscript.turns.map { $0.responseSpans.map(\.activities.count) }
        )
        XCTAssertNil(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount)

        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
        XCTAssertNotNil(session.rawInputSanitizeEvidence)
        XCTAssertNotNil(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount)
    }

    func testStaleApplyAndRetentionEvidenceLifecycle() async throws {
        let viewModel = makeViewModel()
        let session = try await viewModel.ensureSessionReady(tabID: UUID())
        session.runState = .running
        let items = Self.bashHistory(resultCount: 3)
        session.setItemsSilently(items, reason: .testOverride)
        session.clearDerivedTranscriptCaches()

        viewModel.applyTranscriptPresentation(
            AgentTranscriptIO.buildTranscript(from: items),
            sourceItems: Array(items.dropLast()),
            to: session
        )
        XCTAssertNil(session.rawInputSanitizeEvidence, "a stale build never installs evidence")

        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        let evidence = try XCTUnwrap(session.rawInputSanitizeEvidence)
        session.setItemsSilently(session.items, reason: .retentionCompaction)
        XCTAssertEqual(session.rawInputSanitizeEvidence, evidence, "retention that changes nothing keeps the evidence")

        session.setItemsSilently(items, reason: .testOverride)
        session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
        XCTAssertNotEqual(session.items, items, "retention changed source items")
        XCTAssertEqual(session.rawInputSanitizeEvidence, evidence, "active-run retention keeps the evidence")

        session.runState = .completed
        session.setItemsSilently(items, reason: .testOverride)
        session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
        XCTAssertNil(session.rawInputSanitizeEvidence, "idle retention drops pre-retention raw evidence")

        // Idle retention has already aligned source items. A full import records the summary
        // input immediately; later source changes can reuse it without another cold pass.
        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
        XCTAssertNotNil(session.rawInputSanitizeEvidence, "the next full import re-seeds evidence")
        XCTAssertNil(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount, "re-seeding is a recording pass")
        session.appendItem(.assistant("Follow-up"))
        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
        XCTAssertNotNil(session.rawInputSanitizeEvidence)
        XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount ?? 0, 0)
        session.appendItem(.assistant("Another follow-up"))
        viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
        XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount ?? 0, 0)
    }

    func testIdleRetentionDropsEvidenceOnlyWhenSourceChangesAcrossAllPaths() throws {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runState = .idle
        let items = Self.bashHistory(resultCount: 3)
        session.setItemsSilently(items, reason: .testOverride)
        let presentation = viewModel.applyTranscriptPresentation(AgentTranscriptIO.buildTranscript(from: items), to: session)
        let evidence = try XCTUnwrap(session.rawInputSanitizeEvidence)
        let compacted = AgentTranscriptIO.workingSourceItems(from: presentation.transcript)

        session.setItemsSilently(session.items, reason: .retentionCompaction)
        XCTAssertEqual(session.rawInputSanitizeEvidence, evidence, "idle no-op retention keeps evidence")
        session.setItemsSilently(compacted, reason: .retentionCompaction)
        XCTAssertNil(session.rawInputSanitizeEvidence, "idle bulk compaction drops raw evidence")

        session.setItemsSilently(items, reason: .testOverride)
        session.rawInputSanitizeEvidence = evidence
        let index = try XCTUnwrap(items.firstIndex { $0.kind == .toolResult })
        let payload = try XCTUnwrap(session.ephemeralToolResultPayloadByItemID[items[index].id])
        XCTAssertTrue(session.replaceItemSilentlyForRetentionCompaction(at: index, with: compacted[index], retainedRawPayload: payload))
        XCTAssertNil(session.rawInputSanitizeEvidence, "idle single-item compaction drops raw evidence")

        session.setItemsSilently(items, reason: .testOverride)
        session.clearDerivedTranscriptCaches()
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        XCTAssertNotEqual(session.items, items, "idle refresh performed source compaction")
        XCTAssertNil(session.rawInputSanitizeEvidence, "post-apply retention cannot leave raw evidence installed")
    }

    func testFullImportReseedsMissingEvidenceWhenSummaryInputEqualsPreviousOutput() async throws {
        let viewModel = makeViewModel()
        let session = try await viewModel.ensureSessionReady(tabID: UUID())
        session.runState = .running
        session.setItemsSilently(Self.bashHistory(resultCount: 3), reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        let imported = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: session.transcript,
            workingItems: session.items,
            terminalState: session.runState,
            nextSequenceIndex: session.nextSequenceIndex,
            policy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI)
        )
        XCTAssertEqual(imported.turns, session.transcript.turns)
        session.rawInputSanitizeEvidence = nil

        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)

        XCTAssertNotNil(session.rawInputSanitizeEvidence, "A full import must record rather than silently reuse the equal prefix.")
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount ?? 0, 0)
    }

    func testMetadataOnlyTranscriptWriteKeepsEvidenceAndActivityWriteOrResetDropsIt() async throws {
        let viewModel = makeViewModel()
        let session = try await viewModel.ensureSessionReady(tabID: UUID())
        session.runState = .running
        session.setItemsSilently(Self.bashHistory(resultCount: 2), reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        let turnID = try XCTUnwrap(session.transcript.turns.last?.id)

        XCTAssertTrue(AgentModeProcessRunIdentity.retainProcessRunID(UUID(), inTranscriptTurnID: turnID, for: session))
        XCTAssertNotNil(session.rawInputSanitizeEvidence, "a span runID write leaves activities unchanged")

        session.transcript.turns[0].responseSpans[0].activities[0].text = "edited"
        XCTAssertNil(session.rawInputSanitizeEvidence, "an activity write drops the evidence")

        viewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        XCTAssertNotNil(session.rawInputSanitizeEvidence)
        session.clearDerivedTranscriptCaches()
        XCTAssertNil(session.rawInputSanitizeEvidence)
    }

    // MARK: - W3 differential oracle

    /// 1,500 source items in one final turn holding 900 distinct bash results, appended one by one
    /// into two independent sessions, then replayed through a compaction transition, a warm full
    /// import, append, result update, assistant and reasoning segment end, a pending-question
    /// transition, user send, run completion with retention, and a warm full import after
    /// retention. The reference derives cold at every step (full import, no sanitize or projection
    /// reuse) while keeping its own durable history and identical payload-revision history; each
    /// step allocates at most one payload revision so numeric revisions compare exactly.
    func testW3RawInputReuseEqualsColdDerivationAcrossLiveHistory() async throws {
        let viewModel = makeViewModel()
        let candidate = try await viewModel.ensureSessionReady(tabID: UUID())
        let reference = try await viewModel.ensureSessionReady(tabID: UUID())
        reference.test_forcesColdDerivedTranscriptBuild = true
        let sessions = [candidate, reference]
        let seed = Self.w3Seed()
        XCTAssertEqual(seed.count, 1500)
        XCTAssertEqual(Set(seed.filter { $0.kind == .toolResult }.compactMap(\.toolResultJSON)).count, 900)

        var revisionHighWater = 0
        func refresh(_ reason: AgentModeViewModel.DerivedTranscriptRefreshReason) {
            for session in sessions {
                viewModel.refreshDerivedTranscriptState(for: session, reason: reason, publishActivePresentation: false)
            }
        }
        func compare(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            let allocated = candidate.ephemeralToolResultPayloadRevisionByItemID.values.filter { $0 > revisionHighWater }
            XCTAssertLessThanOrEqual(allocated.count, 1, "[\(step)] payload revisions allocated", file: file, line: line)
            revisionHighWater = max(revisionHighWater, allocated.max() ?? 0)
            assertEquivalent(candidate, reference, step: step, file: file, line: line)
        }
        /// Every execution-carrying tool activity except `processed` was reused, not processed.
        func assertWorkAvoided(_ step: String, processed: Int, file: StaticString = #filePath, line: UInt = #line) {
            let toolActivityCount = candidate.transcript.turns.reduce(0) { count, turn in
                count + turn.responseSpans.reduce(0) { spanCount, span in
                    spanCount + span.activities.count {
                        ($0.itemKind == .toolCall || $0.itemKind == .toolResult) && $0.toolExecution != nil
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(toolActivityCount, 1200, "[\(step)] fixture size", file: file, line: line)
            XCTAssertEqual(
                candidate.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount,
                toolActivityCount - processed,
                "[\(step)] reused activities",
                file: file,
                line: line
            )
            XCTAssertNil(reference.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount, file: file, line: line)
        }

        /// The build reused recorded work and left evidence for the next build.
        func assertReusedWithEvidence(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotNil(candidate.rawInputSanitizeEvidence, "[\(step)] evidence", file: file, line: line)
            XCTAssertGreaterThan(
                candidate.transcriptPerformanceSnapshot.lastSanitizeReusedActivityCount ?? 0,
                0,
                "[\(step)] reused activities",
                file: file,
                line: line
            )
        }

        for session in sessions {
            session.runState = .running
            for item in seed {
                session.appendItem(item)
            }
        }
        revisionHighWater = candidate.ephemeralToolResultPayloadRevisionByItemID.values.max() ?? 0
        assertEquivalent(candidate, reference, step: "sequential seed")
        refresh(.coldLoad)
        compare("seed cold load")

        // Retention has made the source summary-only; the first full import of that input
        // differs from the recorded raw input and is processed once.
        refresh(.manualRefresh)
        compare("compaction transition")
        refresh(.manualRefresh)
        compare("warm full import")
        assertWorkAvoided("warm full import", processed: 0)

        let appendedInvocation = UUID()
        let appendedCall = AgentChatItem.toolCall(name: "bash", invocationID: appendedInvocation, argsJSON: #"{"command":"echo appended"}"#)
        let appendedResult = AgentChatItem.toolResult(
            name: "bash",
            invocationID: appendedInvocation,
            resultJSON: Self.bashResultJSON(index: 10000, output: "appended output"),
            isError: false
        )
        apply(sessions) { session in
            session.appendItem(appendedCall)
            session.appendItem(appendedResult)
        }
        refresh(.liveMutation)
        compare("append")
        assertWorkAvoided("append", processed: 2)

        let updatedResultJSON = Self.bashResultJSON(index: 10001, output: "updated output")
        apply(sessions) { session in
            guard let index = session.items.lastIndex(where: { $0.id == appendedResult.id }) else {
                return XCTFail("missing appended result")
            }
            session.mutateItem(at: index) { item in
                item.toolResultJSON = updatedResultJSON
                item.text = updatedResultJSON
            }
        }
        refresh(.liveMutation)
        compare("result update")
        assertReusedWithEvidence("result update")

        var thinking = AgentChatItem.thinking("Considering")
        thinking.isStreaming = true
        let assistant = AgentChatItem.assistant("Checking the output.", isStreaming: true)
        apply(sessions) { session in
            session.appendItem(thinking)
            session.activeReasoningItemID = thinking.id
            session.appendItem(assistant)
            viewModel.test_endAssistantSegment(session, background: false)
            viewModel.endActiveReasoningSegment(session)
        }
        refresh(.liveMutation)
        compare("assistant and reasoning segment end")
        assertReusedWithEvidence("assistant and reasoning segment end")

        let askInvocation = UUID()
        let askCall = AgentChatItem.toolCall(name: "ask_user", invocationID: askInvocation, argsJSON: #"{"question":"Continue?"}"#)
        let pending = try Self.pendingAskUser()
        apply(sessions) { session in
            session.appendItem(askCall)
            session.pendingAskUser = pending
        }
        refresh(.liveMutation)
        compare("pending question hidden")
        assertReusedWithEvidence("pending question hidden")

        let askResult = AgentChatItem.toolResult(
            name: "ask_user",
            invocationID: askInvocation,
            resultJSON: #"{"answers":{"continue":"yes"}}"#,
            isError: false
        )
        apply(sessions) { session in
            session.pendingAskUser = nil
            session.appendItem(askResult)
        }
        refresh(.liveMutation)
        compare("question answered")
        assertReusedWithEvidence("question answered")

        let nextRequest = AgentChatItem.user("Next request")
        apply(sessions) { $0.appendItem(nextRequest) }
        refresh(.liveMutation)
        compare("user send")
        assertReusedWithEvidence("user send")

        let followUpInvocation = UUID()
        let followUpCall = AgentChatItem.toolCall(name: "bash", invocationID: followUpInvocation, argsJSON: #"{"command":"echo next"}"#)
        let followUpResult = AgentChatItem.toolResult(
            name: "bash",
            invocationID: followUpInvocation,
            resultJSON: Self.bashResultJSON(index: 10002, output: "next output"),
            isError: false
        )
        let done = AgentChatItem.assistant("Done.")
        apply(sessions) { session in
            session.appendItem(followUpCall)
            session.appendItem(followUpResult)
            session.appendItem(done)
        }
        refresh(.liveMutation)
        compare("second-turn appends")
        assertReusedWithEvidence("second-turn appends")

        apply(sessions) { $0.runState = .completed }
        refresh(.manualRefresh)
        compare("run completed with retention")
        // Active-run compaction already made the source summary-only, so completion retention
        // changes no source item and the evidence survives (idle drop and re-seed are covered by
        // the lifecycle test).
        assertReusedWithEvidence("run completed with retention")

        refresh(.manualRefresh)
        compare("warm full import after retention")
        assertWorkAvoided("warm full import after retention", processed: 0)
    }

    // MARK: - Helpers

    private func apply(_ sessions: [AgentModeViewModel.TabSession], _ body: (AgentModeViewModel.TabSession) -> Void) {
        for session in sessions {
            body(session)
        }
    }

    private func assertEquivalent(
        _ candidate: AgentModeViewModel.TabSession,
        _ reference: AgentModeViewModel.TabSession,
        step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func check<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
            XCTAssertTrue(lhs == rhs, "[\(step)] \(label)", file: file, line: line)
        }
        check(candidate.items, reference.items, "post-retention items")
        check(candidate.nextSequenceIndex, reference.nextSequenceIndex, "next sequence index")
        check(candidate.transcript, reference.transcript, "sanitized transcript")
        check(
            candidate.transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            reference.transcript.turns.flatMap { $0.responseSpans.map(\.fullRenderGroupedHistoryCache) },
            "grouped-history caches"
        )
        check(candidate.baseTranscriptProjection, reference.baseTranscriptProjection, "base projection")
        check(candidate.fullTranscriptProjection, reference.fullTranscriptProjection, "full projection")
        check(candidate.workingTranscriptProjection, reference.workingTranscriptProjection, "working projection")
        check(candidate.transcriptProjection, reference.transcriptProjection, "materialized projection")
        check(candidate.archivedTranscriptSnapshot, reference.archivedTranscriptSnapshot, "archived snapshot")
        check(candidate.transcriptProjectionCounts, reference.transcriptProjectionCounts, "projection counts")
        check(candidate.transcriptCanonicalVisibleRowCount, reference.transcriptCanonicalVisibleRowCount, "visible row count")
        check(candidate.ephemeralToolResultPayloadByItemID, reference.ephemeralToolResultPayloadByItemID, "payload map")
        check(candidate.ephemeralToolResultPayloadRevisionByItemID, reference.ephemeralToolResultPayloadRevisionByItemID, "payload revisions")
        check(
            candidate.rawToolResultPayloadRenderRevisionByItemID,
            reference.rawToolResultPayloadRenderRevisionByItemID,
            "render revisions"
        )
        check(candidate.hasPendingQuestionUI, reference.hasPendingQuestionUI, "pending question")
    }

    /// One user request, 300 bash calls, 900 distinct bash results, and 299 assistant rows.
    private static func w3Seed() -> [AgentChatItem] {
        var items: [AgentChatItem] = [.user("Run the W3 workload", sequenceIndex: 0)]
        var assistantCount = 0
        for index in 0 ..< 900 {
            let invocationID = UUID()
            let argsJSON = #"{"command":"run \#(index)"}"#
            if index < 300 {
                items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: items.count))
            }
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: bashResultJSON(index: index, output: String(repeating: "output \(index)\n", count: 20)),
                isError: false,
                sequenceIndex: items.count
            ))
            if index % 3 == 2, assistantCount < 299 {
                items.append(.assistant("Step \(index)", sequenceIndex: items.count))
                assistantCount += 1
            }
        }
        return items
    }

    private static func bashHistory(resultCount: Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = [.user("Run commands", sequenceIndex: 0)]
        for index in 0 ..< resultCount {
            let invocationID = UUID()
            items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: #"{"command":"echo \#(index)"}"#, sequenceIndex: items.count))
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                resultJSON: bashResultJSON(index: index, output: String(repeating: "line \(index)\n", count: 30)),
                isError: false,
                sequenceIndex: items.count
            ))
        }
        return items
    }

    private static func bashResultJSON(index: Int, output: String) -> String {
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

    private static func pendingAskUser() throws -> AgentAskUserPendingState {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            title: "Continue",
            context: "W3",
            timeoutSeconds: 30,
            questions: [AgentAskUserQuestion(id: "continue", question: "Continue?", allowsCustom: true)]
        )
        try interaction.validate()
        return AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: interaction.emptyDrafts(),
            currentQuestionIndex: 0
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )
        viewModel.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
        return viewModel
    }
}
