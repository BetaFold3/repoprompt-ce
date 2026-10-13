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

    // MARK: - D7 background deferral

    /// W3 under D7: both sessions are background in one view model, so live mutations wait in
    /// the delayed window and many merge into one refresh. After every released batch, the
    /// question barrier, and the terminal barrier, the candidate's merged-summary refresh must
    /// equal the forced-cold reference, including numeric payload revisions and question state.
    func testW3BackgroundDeferredBatchesEqualColdDerivation() async throws {
        let viewModel = makeViewModel()
        viewModel.test_setCurrentTabIDOverride(UUID())
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let gate = DerivedTranscriptDeferralSleepGate()
        defer { gate.open() }
        viewModel.test_setDerivedTranscriptDeferralSleep(gate.makeSleep())
        viewModel.test_setBackgroundDerivedTranscriptDeferralEnabledOverride(true)
        let candidate = try await viewModel.ensureSessionReady(tabID: UUID())
        let reference = try await viewModel.ensureSessionReady(tabID: UUID())
        reference.test_forcesColdDerivedTranscriptBuild = true
        let sessions = [candidate, reference]
        let seed = Self.w3Seed()
        XCTAssertEqual(seed.count, 1500)
        XCTAssertEqual(Set(seed.filter { $0.kind == .toolResult }.compactMap(\.toolResultJSON)).count, 900)
        for session in sessions {
            XCTAssertFalse(viewModel.canBuildOrPublishActiveTranscriptBindings(for: session))
        }

        /// `incremental`: the merged summary admits the importer (batches carrying a user item
        /// never do: `containsUserMutation`).
        func releaseBatch(
            _ step: String,
            incremental: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            for session in sessions {
                XCTAssertTrue(session.hasDeferredDerivedTranscriptRefresh, "[\(step)] deferred", file: file, line: line)
            }
            let attempts = candidate.transcriptPerformanceSnapshot.incrementalImportAttemptCount
            await gate.release(sessions.map(\.derivedTranscriptRefreshTask))
            XCTAssertEqual(
                candidate.transcriptPerformanceSnapshot.incrementalImportAttemptCount,
                attempts + (incremental ? 1 : 0),
                "[\(step)] merged-summary attempts",
                file: file,
                line: line
            )
            compare(step, file: file, line: line)
        }
        func compare(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            for session in sessions {
                XCTAssertFalse(session.hasDeferredDerivedTranscriptRefresh, "[\(step)] settled", file: file, line: line)
                XCTAssertEqual(
                    session.derivedTranscriptSyncState?.sourceItemsRevision,
                    session.sourceItemsRevision,
                    "[\(step)] synchronized",
                    file: file,
                    line: line
                )
            }
            assertEquivalent(candidate, reference, step: step, file: file, line: line)
        }

        for session in sessions {
            session.runState = .running
            for item in seed {
                session.appendItem(item)
            }
        }
        await releaseBatch("seed batch", incremental: false)

        let invocation = UUID()
        let call = AgentChatItem.toolCall(name: "bash", invocationID: invocation, argsJSON: #"{"command":"echo batch"}"#)
        let result = AgentChatItem.toolResult(
            name: "bash",
            invocationID: invocation,
            resultJSON: Self.bashResultJSON(index: 20000, output: "batch output"),
            isError: false
        )
        let updatedResultJSON = Self.bashResultJSON(index: 20001, output: "batch output updated")
        var thinking = AgentChatItem.thinking("Considering")
        thinking.isStreaming = true
        let assistant = AgentChatItem.assistant("Checking the batch.", isStreaming: true)
        apply(sessions) { session in
            session.appendItem(call)
            session.appendItem(result)
            if let index = session.items.lastIndex(where: { $0.id == result.id }) {
                session.mutateItem(at: index) { item in
                    item.toolResultJSON = updatedResultJSON
                    item.text = updatedResultJSON
                }
            }
            session.appendItem(thinking)
            session.activeReasoningItemID = thinking.id
            session.appendItem(assistant)
            viewModel.test_endAssistantSegment(session, background: false)
            viewModel.endActiveReasoningSegment(session)
        }
        await releaseBatch("append, payload revision, and segment-end batch", incremental: true)

        let askInvocation = UUID()
        let askCall = AgentChatItem.toolCall(name: "ask_user", invocationID: askInvocation, argsJSON: #"{"question":"Continue?"}"#)
        let pending = try Self.pendingAskUser()
        apply(sessions) { session in
            session.appendItem(askCall)
            session.pendingAskUser = pending
        }
        compare("question barrier with pending batch")
        XCTAssertTrue(candidate.hasPendingQuestionUI)

        let askResult = AgentChatItem.toolResult(
            name: "ask_user",
            invocationID: askInvocation,
            resultJSON: #"{"answers":{"continue":"yes"}}"#,
            isError: false
        )
        apply(sessions) { $0.pendingAskUser = nil }
        compare("question cleared without pending batch")
        let nextRequest = AgentChatItem.user("Next request")
        let followUpInvocation = UUID()
        let followUpCall = AgentChatItem.toolCall(name: "bash", invocationID: followUpInvocation, argsJSON: #"{"command":"echo next"}"#)
        let followUpResult = AgentChatItem.toolResult(
            name: "bash",
            invocationID: followUpInvocation,
            resultJSON: Self.bashResultJSON(index: 20002, output: "next output"),
            isError: false
        )
        apply(sessions) { session in
            session.appendItem(askResult)
            session.appendItem(nextRequest)
            session.appendItem(followUpCall)
            session.appendItem(followUpResult)
        }
        await releaseBatch("answer and second-turn batch", incremental: false)

        let done = AgentChatItem.assistant("Done.")
        apply(sessions) { $0.appendItem(done) }
        apply(sessions) { $0.runState = .completed }
        compare("terminal barrier")
    }

    // MARK: - D2 run-state-only admission

    /// W3 kill gate and transitions through the production entry point. History sits behind a
    /// durable frontier; an earlier full, non-frozen turn keeps an unfinished tool call, an
    /// in-progress background bash result, and a streaming background assistant row. Each session
    /// is the only session of its own view model, so it owns headless active-binding publication
    /// and a bare `runState` assignment reaches the refresh only through `onRunStateChanged` ->
    /// `catchUpDerivedTranscriptForActiveBindingIfNeeded(.liveMutation)`; the test never refreshes
    /// manually around a transition. Where only `runState` changed, the candidate must take the
    /// incremental path and equal a cold derivation.
    func testW3RunStateOnlyRefreshEqualsColdDerivationAcrossTransitions() async throws {
        let pair = try await makeSyncedRunStatePair()
        let candidate = pair.candidate
        let reference = pair.reference
        let sessions = [candidate, reference]
        func refresh(_ reason: AgentModeViewModel.DerivedTranscriptRefreshReason) {
            for (viewModel, session) in pair.owned {
                viewModel.refreshDerivedTranscriptState(for: session, reason: reason, publishActivePresentation: false)
            }
        }
        func transition(to runState: AgentSessionRunState, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
            let before = Self.importCounts(candidate)
            let previousSync = candidate.derivedTranscriptSyncState
            XCTAssertNil(candidate.pendingSourceItemsMutationSummary, "[\(step)] no source mutation", file: file, line: line)
            XCTAssertEqual(previousSync?.runState == runState, false, "[\(step)] run state changed", file: file, line: line)
            apply(sessions) { $0.runState = runState }
            XCTAssertEqual(reference.transcript.turns.last?.terminalState, runState, "[\(step)] reference current", file: file, line: line)
            let after = Self.importCounts(candidate)
            XCTAssertEqual(after.attempts, before.attempts + 1, "[\(step)] run-state-only attempt", file: file, line: line)
            XCTAssertEqual(after.successes, before.successes + 1, "[\(step)] incremental success", file: file, line: line)
            XCTAssertEqual(after.frontierSuccesses, before.frontierSuccesses + 1, "[\(step)] durable frontier reused", file: file, line: line)
            assertEquivalent(candidate, reference, step: step, file: file, line: line)
            for (viewModel, session) in pair.owned {
                assertSynchronized(viewModel, session, step: step, file: file, line: line)
            }
        }

        transition(to: .idle, "running to idle")

        let thirdRequest = AgentChatItem.user("Third request")
        apply(sessions) { $0.appendItem(thirdRequest) }
        refresh(.liveMutation)
        assertEquivalent(candidate, reference, step: "user send while idle")
        transition(to: .running, "idle to running after synced user send")

        let inFlight = AgentChatItem.toolCall(name: "bash", invocationID: UUID(), argsJSON: #"{"command":"sleep 1"}"#)
        apply(sessions) { $0.appendItem(inFlight) }
        refresh(.liveMutation)
        assertEquivalent(candidate, reference, step: "in-flight call")
        transition(to: .failed, "running to failed with in-flight call")
        transition(to: .running, "failed to running")
        transition(to: .cancelled, "running to cancelled")
        transition(to: .running, "cancelled to running")
        transition(to: .completed, "running to completed")

        // Once synchronized, the delta is empty: no new admission, the existing full path runs.
        let before = Self.importCounts(candidate)
        refresh(.liveMutation)
        XCTAssertEqual(Self.importCounts(candidate).attempts, before.attempts, "empty delta stays full")
        assertEquivalent(candidate, reference, step: "repeat after sync")
    }

    /// Every other synchronization input, a missing or invalidated sync state, a pending question,
    /// and an explicit integrity repair keep the existing full import and still equal cold.
    func testRunStateOnlyAdmissionRejectsEveryOtherChangedInput() async throws {
        typealias Change = (AgentModeViewModel, AgentModeViewModel.TabSession) throws -> Void
        let cases: [(String, Change)] = [
            ("source revision", { $1.sourceItemsRevision &+= 1 }),
            ("next sequence index", { $1.nextSequenceIndex += 1 }),
            ("selected agent", { $1.selectedAgent = .codexExec }),
            ("question hiding", { $1.pendingUserInputRequest = Self.pendingUserInputRequest() }),
            ("projection protection", { _, session in
                let earlierSequence = try XCTUnwrap(session.items.first { $0.kind == .user }?.sequenceIndex)
                session.transcriptViewportState = AgentTranscriptViewportState(
                    isDetachedFromLiveBottom: true,
                    detachedAuthority: DetachedViewportAuthority(
                        targetID: nil,
                        anchor: nil,
                        sequenceIndex: earlierSequence,
                        blockID: nil,
                        viewportMinY: nil
                    )
                )
            }),
            ("nil sync", { $1.derivedTranscriptSyncState = nil }),
            ("silent replacement", { $1.setItemsSilently($1.items, reason: .testOverride) }),
            // Setting `pendingAskUser` also flips question hiding, so both the guard and the sync
            // delta reject this case.
            ("pending question with hiding change", { $1.pendingAskUser = try Self.pendingAskUser() }),
            // Isolates the `pendingAskUser` guard: hiding is already synchronized as true, so the
            // sync delta is exactly `runState` and only the guard rejects.
            ("pending question guard only", { viewModel, session in
                session.pendingUserInputRequest = Self.pendingUserInputRequest()
                viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
                XCTAssertTrue(session.hasPendingQuestionUI)
                session.pendingAskUser = try Self.pendingAskUser()
                let current = AgentModeViewModel.DerivedTranscriptSyncState(
                    sourceItemsRevision: session.sourceItemsRevision,
                    nextSequenceIndex: session.nextSequenceIndex,
                    runState: .idle,
                    selectedAgent: session.selectedAgent,
                    hidePendingQuestionToolCall: session.hasPendingQuestionUI,
                    projectionProtection: viewModel.transcriptProjectionProtection(for: session)
                )
                XCTAssertEqual(session.derivedTranscriptSyncState?.differsOnlyInRunState(from: current), true)
            })
        ]
        for (step, change) in cases {
            let pair = try await makeSyncedRunStatePair()
            let before = Self.importCounts(pair.candidate)
            for (viewModel, session) in pair.owned {
                try change(viewModel, session)
                session.runState = .idle
                viewModel.refreshDerivedTranscriptState(for: session, reason: .liveMutation, publishActivePresentation: false)
            }
            XCTAssertEqual(Self.importCounts(pair.candidate).attempts, before.attempts, "[\(step)] no incremental attempt")
            assertEquivalent(pair.candidate, pair.reference, step: step)
        }

        let pair = try await makeSyncedRunStatePair()
        let before = Self.importCounts(pair.candidate)
        for (viewModel, session) in pair.owned {
            session.onRunStateChanged = nil
            session.runState = .idle
            viewModel.refreshDerivedTranscriptState(
                for: session,
                reason: .liveMutation,
                publishActivePresentation: false,
                permitsRunStateOnlyAdmission: false
            )
        }
        XCTAssertEqual(Self.importCounts(pair.candidate).attempts, before.attempts, "integrity repair keeps the full import")
        assertEquivalent(pair.candidate, pair.reference, step: "integrity repair")
    }

    /// An importer rejection on the run-state-only path falls back to the same full rebuild the
    /// existing no-attempt path performs on identical input.
    func testRunStateOnlyImporterRejectionFallsBackToFullRebuild() async throws {
        let pair = try await makeSyncedRunStatePair()
        let candidate = pair.candidate
        let control = pair.reference
        control.test_forcesColdDerivedTranscriptBuild = false
        let invalidFrontier = AgentTranscriptCompactionFrontier(version: 1, frozenPrefixTurnCount: 999, lastFrozenTurnID: UUID())
        for session in [candidate, control] {
            session.onRunStateChanged = nil
            session.transcript.compactionFrontier = invalidFrontier
            XCTAssertNotNil(session.derivedTranscriptSyncState)
            session.runState = .idle
        }
        let before = Self.importCounts(candidate)
        pair.candidateViewModel.refreshDerivedTranscriptState(for: candidate, reason: .liveMutation, publishActivePresentation: false)
        pair.referenceViewModel.refreshDerivedTranscriptState(
            for: control,
            reason: .liveMutation,
            publishActivePresentation: false,
            permitsRunStateOnlyAdmission: false
        )
        let after = Self.importCounts(candidate)
        XCTAssertEqual(after.attempts, before.attempts + 1)
        XCTAssertEqual(after.fallbacks, before.fallbacks + 1)
        assertEquivalent(candidate, control, step: "importer rejection fallback")
        assertSynchronized(pair.candidateViewModel, candidate, step: "importer rejection fallback")
    }

    func testRunStateOnlyDiagnosticsLabelAdmissionAndMissingSummarySyncDelta() async throws {
        // Each session is refreshed by the view model that owns it.
        let admitted = try await makeSyncedRunStatePair()
        let unsynced = try await makeSyncedRunStatePair()
        let agentChanged = try await makeSyncedRunStatePair()
        try EditFlowPerf.$debugCaptureIsolationTokenForTesting.withValue(UUID()) {
            switch EditFlowPerf.beginDebugCapture(label: "d2-run-state-only", maxSamples: 100) {
            case .started:
                break
            case .busy:
                return XCTFail("Capture should start.")
            }
            for pair in [admitted, unsynced, agentChanged] {
                pair.candidate.onRunStateChanged = nil
            }
            unsynced.candidate.derivedTranscriptSyncState = nil
            agentChanged.candidate.selectedAgent = .codexExec
            for pair in [admitted, unsynced, agentChanged] {
                pair.candidate.runState = .idle
                pair.candidateViewModel.refreshDerivedTranscriptState(
                    for: pair.candidate,
                    reason: .liveMutation,
                    publishActivePresentation: false
                )
            }

            let imports = EditFlowPerf.debugCaptureSnapshot(finish: true).stages
                .filter { $0.stageName == "EditFlow.Transcript.ImportTranscript" }
                .map(\.sanitizedDimensions)
            let admittedImport = try XCTUnwrap(imports.first { $0.contains("mutationFlags=runStateOnly") }, "\(imports)")
            XCTAssertTrue(admittedImport.contains("outcome=incremental_success"), admittedImport)
            XCTAssertTrue(
                imports.contains { $0.contains("reason=missingSummary") && $0.contains("mutationFlags=syncDelta.nil") },
                "\(imports)"
            )
            XCTAssertTrue(
                imports.contains { $0.contains("reason=missingSummary") && $0.contains("mutationFlags=syncDelta.run-agent") },
                "\(imports)"
            )
        }
    }

    /// Equal-sync activation validates the unwindowed backing projections: valid grouped history
    /// (one presented card, no backing rows) under any history visibility or window skips repair,
    /// while genuine corruption repairs through the existing full import and equals cold.
    func testEqualSyncActivationRepairsOnlyCorruptBackingProjections() async throws {
        typealias Session = AgentModeViewModel.TabSession
        func removeFirstGroupedBlock(_ projection: inout AgentTranscriptProjection) throws {
            let index = try XCTUnwrap(projection.workingBlocks.firstIndex { $0.kind == .groupedHistory && $0.rows.isEmpty })
            projection.workingBlocks.remove(at: index)
        }
        func substituteRow(_ rows: inout [AgentChatItem]) {
            let index = rows.count / 2
            rows[index] = .assistant("substitute", sequenceIndex: rows[index].sequenceIndex)
        }
        let cases: [(String, Bool, (Session) throws -> Void)] = [
            ("valid hidden collapsed window", false, { _ in }),
            ("valid revealed expanded window", false, { session in
                session.isCompressedHistoryRevealed = true
                session.isTranscriptWindowExpanded = true
            }),
            ("stored counts", true, { session in
                let counts = session.transcriptProjectionCounts
                session.transcriptProjectionCounts = .init(
                    canonicalVisibleRowCount: counts.canonicalVisibleRowCount + 1,
                    defaultPresentedRowCount: counts.defaultPresentedRowCount + 1
                )
            }),
            ("grouped block missing", true, { session in
                try removeFirstGroupedBlock(&session.fullTranscriptProjection)
                try removeFirstGroupedBlock(&session.workingTranscriptProjection)
            }),
            ("working required row missing", true, { $0.workingTranscriptProjection.workingRows.removeLast() }),
            ("full row substituted", true, { substituteRow(&$0.fullTranscriptProjection.workingRows) }),
            ("full archived row substituted", true, { substituteRow(&$0.fullTranscriptProjection.archivedRows) })
        ]
        for (step, expectsRepair, change) in cases {
            let pair = try await makeSyncedRunStatePair(groupedHistoryToolCount: 14)
            let viewModel = pair.candidateViewModel
            let candidate = pair.candidate
            XCTAssertFalse(candidate.fullTranscriptProjection.archivedRows.isEmpty, "[\(step)] archived lane")
            XCTAssertLessThan(
                candidate.workingTranscriptProjection.workingRows.count,
                candidate.transcriptProjectionCounts.defaultPresentedRowCount,
                "[\(step)] grouped cards make raw rows and presented counts unlike units"
            )
            for (owner, session) in pair.owned {
                if session === candidate {
                    try change(session)
                } else if !expectsRepair {
                    try change(session)
                }
                session.transcriptProjection = owner.materializedTranscriptProjection(for: session)
            }
            XCTAssertTrue(viewModel.canBuildOrPublishActiveTranscriptBindings(for: candidate), "[\(step)] active owner")
            let generation = candidate.derivedTranscriptRefreshGeneration
            let before = Self.importCounts(candidate)

            viewModel.applySessionToBindings(candidate)

            XCTAssertEqual(
                candidate.derivedTranscriptRefreshGeneration != generation,
                expectsRepair,
                "[\(step)] integrity repair"
            )
            XCTAssertEqual(Self.importCounts(candidate).attempts, before.attempts, "[\(step)] no run-state-only admission")
            assertEquivalent(candidate, pair.reference, step: step)
            assertSynchronized(viewModel, candidate, step: step)
        }
    }

    func testSyncStateRunStateOnlyComparisonAndDeltaLabel() {
        let base = AgentModeViewModel.DerivedTranscriptSyncState(
            sourceItemsRevision: 1,
            nextSequenceIndex: 2,
            runState: .running,
            selectedAgent: .claudeCode,
            hidePendingQuestionToolCall: false,
            projectionProtection: .none
        )
        func changed(
            revision: Int = 1,
            sequence: Int = 2,
            runState: AgentSessionRunState = .idle,
            agent: AgentProviderKind = .claudeCode,
            hideQuestion: Bool = false,
            protection: AgentTranscriptProjectionProtection = .none
        ) -> AgentModeViewModel.DerivedTranscriptSyncState {
            .init(
                sourceItemsRevision: revision,
                nextSequenceIndex: sequence,
                runState: runState,
                selectedAgent: agent,
                hidePendingQuestionToolCall: hideQuestion,
                projectionProtection: protection
            )
        }
        XCTAssertTrue(base.differsOnlyInRunState(from: changed()))
        XCTAssertFalse(base.differsOnlyInRunState(from: base), "an empty delta is not run-state-only")
        for other in [
            changed(revision: 2),
            changed(sequence: 3),
            changed(agent: .codexExec),
            changed(hideQuestion: true),
            changed(protection: .protectedTurn(UUID()))
        ] {
            XCTAssertFalse(base.differsOnlyInRunState(from: other), "\(other)")
        }
        typealias Sync = AgentModeViewModel.DerivedTranscriptSyncState
        XCTAssertEqual(Sync.diagnosticDeltaLabel(from: nil, to: base), "syncDelta.nil")
        XCTAssertEqual(Sync.diagnosticDeltaLabel(from: base, to: base), "syncDelta.none")
        XCTAssertEqual(
            Sync.diagnosticDeltaLabel(
                from: base,
                to: changed(revision: 2, sequence: 3, agent: .codexExec, hideQuestion: true, protection: .protectedTurn(UUID()))
            ),
            "syncDelta.rev-seq-run-agent-ask-protect"
        )
    }

    // MARK: - Helpers

    /// Candidate and cold reference, each the only session of its own view model, so each owns
    /// headless active-binding publication and is refreshed only by its owner.
    private struct RunStatePair {
        let candidateViewModel: AgentModeViewModel
        let referenceViewModel: AgentModeViewModel
        let candidate: AgentModeViewModel.TabSession
        let reference: AgentModeViewModel.TabSession

        var owned: [(AgentModeViewModel, AgentModeViewModel.TabSession)] {
            [(candidateViewModel, candidate), (referenceViewModel, reference)]
        }
    }

    /// Running sessions over `runStateFixture()`, synchronized through a summarized live refresh.
    private func makeSyncedRunStatePair(groupedHistoryToolCount: Int = 0) async throws -> RunStatePair {
        let candidateViewModel = makeViewModel()
        let referenceViewModel = makeViewModel()
        let candidate = try await candidateViewModel.ensureSessionReady(tabID: UUID())
        let reference = try await referenceViewModel.ensureSessionReady(tabID: UUID())
        reference.test_forcesColdDerivedTranscriptBuild = true
        let pair = RunStatePair(
            candidateViewModel: candidateViewModel,
            referenceViewModel: referenceViewModel,
            candidate: candidate,
            reference: reference
        )
        let fixture = Self.runStateFixture(groupedHistoryToolCount: groupedHistoryToolCount)
        let stillWorking = AgentChatItem.assistant("Still working.")
        for (viewModel, session) in pair.owned {
            session.runState = .running
            for item in fixture.items {
                session.appendItem(item)
            }
            session.backgroundRowIDs = [fixture.backgroundAssistantID]
            viewModel.refreshDerivedTranscriptState(for: session, reason: .coldLoad, publishActivePresentation: false)
            viewModel.refreshDerivedTranscriptState(for: session, reason: .manualRefresh, publishActivePresentation: false)
            session.appendItem(stillWorking)
            viewModel.refreshDerivedTranscriptState(for: session, reason: .liveMutation, publishActivePresentation: false)
        }
        let frozenPrefixTurnCount = candidate.transcript.compactionFrontier?.frozenPrefixTurnCount ?? 0
        XCTAssertGreaterThan(frozenPrefixTurnCount, 0, "durable frontier")
        XCTAssertTrue(
            candidate.items.contains { $0.id == fixture.backgroundAssistantID && $0.isStreaming },
            "earlier-turn background row survives retention"
        )
        // The unfinished/background turn is non-final, outside the frozen prefix, and full, so the
        // cold reference re-imports it on every step instead of carrying it over.
        let backgroundTurnIndex = try XCTUnwrap(candidate.transcript.turns.firstIndex { turn in
            turn.allActivities.contains { $0.id == fixture.backgroundAssistantID }
        })
        XCTAssertGreaterThanOrEqual(backgroundTurnIndex, frozenPrefixTurnCount, "background turn outside frozen prefix")
        XCTAssertLessThan(backgroundTurnIndex, candidate.transcript.turns.count - 1, "background turn is not final")
        XCTAssertEqual(candidate.transcript.turns[backgroundTurnIndex].retentionTier, .full)
        XCTAssertEqual(reference.transcript.turns[backgroundTurnIndex].retentionTier, .full)
        assertEquivalent(candidate, reference, step: "synced pair")
        for (viewModel, session) in pair.owned {
            assertSynchronized(viewModel, session, step: "synced pair")
        }
        return pair
    }

    private func assertSynchronized(
        _ viewModel: AgentModeViewModel,
        _ session: AgentModeViewModel.TabSession,
        step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            viewModel.canReuseDerivedTranscriptForSave(
                for: session,
                projectionProtection: viewModel.transcriptProjectionProtection(for: session)
            ),
            "[\(step)] synchronized",
            file: file,
            line: line
        )
    }

    private static func importCounts(
        _ session: AgentModeViewModel.TabSession
    ) -> (attempts: Int, successes: Int, fallbacks: Int, frontierSuccesses: Int) {
        let snapshot = session.transcriptPerformanceSnapshot
        return (
            snapshot.incrementalImportAttemptCount,
            snapshot.incrementalImportSuccessCount,
            snapshot.incrementalImportFallbackCount,
            snapshot.frontierReuseSuccessCount
        )
    }

    /// 40 history turns, an optional completed turn of `groupedHistoryToolCount` bash calls, an
    /// earlier full turn with an unfinished call, an in-progress background bash result and a
    /// streaming background assistant row, then a final turn of bash work.
    private static func runStateFixture(
        groupedHistoryToolCount: Int = 0
    ) -> (items: [AgentChatItem], backgroundAssistantID: UUID) {
        var items: [AgentChatItem] = []
        func bash(_ index: Int, status: String = "completed") {
            let invocationID = UUID()
            items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: #"{"command":"run \#(index)"}"#, sequenceIndex: items.count))
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                resultJSON: bashResultJSON(index: index, output: String(repeating: "out \(index)\n", count: 10), status: status),
                isError: false,
                sequenceIndex: items.count
            ))
        }
        for turn in 0 ..< 40 {
            items.append(.user("History \(turn)", sequenceIndex: items.count))
            bash(turn)
            items.append(.assistant("History answer \(turn)", sequenceIndex: items.count))
        }
        if groupedHistoryToolCount > 0 {
            items.append(.user("Grouped history", sequenceIndex: items.count))
            for index in 0 ..< groupedHistoryToolCount {
                bash(700 + index)
            }
            items.append(.assistant("Grouped answer", sequenceIndex: items.count))
        }
        items.append(.user("Background work", sequenceIndex: items.count))
        items.append(.toolCall(name: "bash", invocationID: UUID(), argsJSON: #"{"command":"never finishes"}"#, sequenceIndex: items.count))
        bash(500, status: "inProgress")
        let backgroundAssistant = AgentChatItem.assistant("Background note", sequenceIndex: items.count, isStreaming: true)
        items.append(backgroundAssistant)
        items.append(.user("Final request", sequenceIndex: items.count))
        for index in 600 ..< 603 {
            bash(index)
        }
        items.append(.assistant("Progress so far.", sequenceIndex: items.count))
        return (items, backgroundAssistant.id)
    }

    private static func pendingUserInputRequest() -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string("d2-request"),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            questions: [
                AgentRequestUserInputQuestion(
                    id: "q1",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: []
                )
            ]
        )
    }

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

    private static func bashResultJSON(index: Int, output: String, status: String = "completed") -> String {
        let object: [String: Any] = [
            "type": "commandExecution",
            "status": status,
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
