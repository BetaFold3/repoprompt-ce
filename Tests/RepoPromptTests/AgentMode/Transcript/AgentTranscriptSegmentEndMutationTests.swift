import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// D1: an assistant (or reasoning) segment end only flips `isStreaming`, so it must reach the derived refresh as
/// one ranged, non-structural, non-user mutation covering exactly the flipped indices. It must keep
/// the background/source-ID predicate and retire the stream's current row before the flip, must not
/// poison a coalesced batch, and incremental derivation after it must equal a cold rebuild.
@MainActor
final class AgentTranscriptSegmentEndMutationTests: XCTestCase {
    private typealias Summary = AgentModeViewModel.PendingSourceItemsMutationSummary
    private typealias Mutation = AgentModeViewModel.SourceItemsMutation

    // MARK: - Classification

    func testSegmentEndMutationIsRangedNonStructuralAndNonUser() {
        let mutation = Mutation.assistantStreamingStateChanged(changedIndexRange: 3 ... 7)

        XCTAssertEqual(mutation.changedIndexRange, 3 ... 7)
        XCTAssertFalse(mutation.isStructural)
        XCTAssertFalse(mutation.touchesUserItem)
        let summary = Summary(mutation)
        XCTAssertTrue(summary.allowsIncrementalFinalTurnRebuild)
        XCTAssertFalse(summary.containsUnrangedMutation)
        XCTAssertEqual(summary.earliestChangedIndex, 3)
        XCTAssertEqual(summary.latestChangedIndex, 7)
    }

    func testReasoningSegmentEndMutationIsRangedNonStructuralAndNonUser() {
        let mutation = Mutation.reasoningStreamingStateChanged(changedIndexRange: 4 ... 4)

        XCTAssertEqual(mutation.changedIndexRange, 4 ... 4)
        XCTAssertFalse(mutation.isStructural)
        XCTAssertFalse(mutation.touchesUserItem)
        var summary = Summary(.assistantStreamingStateChanged(changedIndexRange: 5 ... 5))
        summary.merge(mutation)
        XCTAssertTrue(summary.allowsIncrementalFinalTurnRebuild)
        XCTAssertFalse(summary.containsUnrangedMutation)
        XCTAssertEqual(summary.earliestChangedIndex, 4)
        XCTAssertEqual(summary.latestChangedIndex, 5)
    }

    func testSegmentEndKeepsCoalescedBatchIncrementalButStructuralStaysSticky() {
        var summary = Summary(.append(index: 8, itemKind: .toolCall))
        summary.merge(.assistantStreamingStateChanged(changedIndexRange: 5 ... 6))
        summary.merge(.append(index: 9, itemKind: .toolResult))

        XCTAssertTrue(summary.allowsIncrementalFinalTurnRebuild)
        XCTAssertFalse(summary.containsUnrangedMutation)
        XCTAssertEqual(summary.earliestChangedIndex, 5)
        XCTAssertEqual(summary.latestChangedIndex, 9)

        summary.merge(.structural)
        XCTAssertFalse(summary.allowsIncrementalFinalTurnRebuild)
        summary.merge(.assistantStreamingStateChanged(changedIndexRange: 9 ... 9))
        XCTAssertFalse(summary.allowsIncrementalFinalTurnRebuild)
    }

    func testMutateItemsBatchDefaultStaysStructural() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.setItemsSilently([.user("q", sequenceIndex: 0), streamingAssistant("a", 1)], reason: .testOverride)
        var received: [Mutation] = []
        session.onSourceItemsChanged = { _, mutation, _ in received.append(mutation) }

        session.mutateItemsBatch { items in items[1].isStreaming = false }

        XCTAssertEqual(received.count, 1)
        guard case .structural = received.first else {
            return XCTFail("mutateItemsBatch default mutation must stay .structural")
        }
    }

    // MARK: - Exact range and no-op

    func testEndActiveAssistantSegmentDeliversExactRangeOnlyForStreamingAssistantRows() throws {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let items: [AgentChatItem] = [
            .user("q", sequenceIndex: 0),
            .assistant("done", sequenceIndex: 1),
            streamingAssistant("first", 2),
            streamingThinking("thinking", 3),
            .toolCall(name: "read_file", invocationID: UUID(), argsJSON: "{}", sequenceIndex: 4),
            streamingAssistant("second", 5),
            .assistant("done again", sequenceIndex: 6)
        ]
        session.setItemsSilently(items, reason: .testOverride)
        var received: [(Mutation, AgentModeViewModel.SourceItemsMutationCaller)] = []
        session.onSourceItemsChanged = { _, mutation, caller in received.append((mutation, caller)) }
        let revisionBefore = session.sourceItemsRevision

        viewModel.endActiveAssistantSegment(session)

        XCTAssertEqual(received.count, 1)
        let (mutation, caller) = try XCTUnwrap(received.first)
        guard case let .assistantStreamingStateChanged(range) = mutation else {
            return XCTFail("Segment end must be ranged and non-structural, got \(mutation)")
        }
        XCTAssertEqual(range, 2 ... 5)
        XCTAssertTrue(caller.label.hasSuffix("_endActiveAssistantSegment"), caller.label)
        XCTAssertEqual(session.sourceItemsRevision, revisionBefore &+ 1)
        XCTAssertEqual(session.items.map(\.id), items.map(\.id))
        XCTAssertEqual(session.items.map(\.isStreaming), [false, false, false, true, false, false, false])
        var expected = items
        expected[2].isStreaming = false
        expected[5].isStreaming = false
        XCTAssertEqual(session.items, expected, "Only isStreaming of the selected rows may change.")

        // No streaming assistant row left: no mutation, no notification, no revision bump.
        viewModel.endActiveAssistantSegment(session)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(session.sourceItemsRevision, revisionBefore &+ 1)
        XCTAssertFalse(session.endStreamingAssistantRows())
    }

    // MARK: - Reasoning segment end

    func testEndActiveReasoningSegmentEndsOnlyActiveReasoningRowsThenClearsState() throws {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let items: [AgentChatItem] = [
            .user("q", sequenceIndex: 0),
            streamingThinking("inactive", 1),
            streamingThinking("grouped", 2),
            streamingAssistant("answer", 3),
            streamingThinking("active", 4)
        ]
        session.setItemsSilently(items, reason: .testOverride)
        session.reasoningItemIDsByGroupID = ["group": items[2].id]
        session.activeReasoningItemID = items[4].id
        var received: [(Mutation, AgentModeViewModel.SourceItemsMutationCaller)] = []
        var stateAtNotification: (UUID?, Int)?
        session.onSourceItemsChanged = { session, mutation, caller in
            received.append((mutation, caller))
            stateAtNotification = (session.activeReasoningItemID, session.reasoningItemIDsByGroupID.count)
        }
        let revisionBefore = session.sourceItemsRevision

        viewModel.endActiveReasoningSegment(session)

        XCTAssertEqual(received.count, 1)
        let (mutation, caller) = try XCTUnwrap(received.first)
        guard case let .reasoningStreamingStateChanged(range) = mutation else {
            return XCTFail("Reasoning segment end must be ranged and non-structural, got \(mutation)")
        }
        XCTAssertEqual(range, 2 ... 4)
        XCTAssertTrue(caller.label.hasSuffix("_endActiveReasoningSegment"), caller.label)
        // Cleanup runs after the flip, as before.
        XCTAssertEqual(stateAtNotification?.0, items[4].id)
        XCTAssertEqual(stateAtNotification?.1, 1)
        XCTAssertNil(session.activeReasoningItemID)
        XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty)
        var expected = items
        expected[2].isStreaming = false
        expected[4].isStreaming = false
        XCTAssertEqual(session.items, expected, "Inactive reasoning and assistant rows keep streaming.")
        XCTAssertEqual(session.sourceItemsRevision, revisionBefore &+ 1)

        // Nothing active and streaming: no mutation, but state is still cleared.
        session.activeReasoningItemID = items[1].id
        session.mutateItem(at: 1) { $0.isStreaming = false }
        received.removeAll()
        let revisionAfterSetup = session.sourceItemsRevision
        viewModel.endActiveReasoningSegment(session)
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(session.sourceItemsRevision, revisionAfterSetup)
        XCTAssertNil(session.activeReasoningItemID)
    }

    // MARK: - Foreground/background source identity

    func testForegroundSegmentEndSkipsBackgroundRows() throws {
        let viewModel = makeViewModel()
        let fixture = backgroundFixture()
        var received: [Mutation] = []
        fixture.session.onSourceItemsChanged = { _, mutation, _ in received.append(mutation) }

        viewModel.test_endAssistantSegment(fixture.session, background: false)

        XCTAssertEqual(streamingIDs(fixture.session), [fixture.backgroundS1, fixture.backgroundS2, fixture.backgroundUnsourced])
        XCTAssertEqual(try singleRange(received), 1 ... 5)
        XCTAssertEqual(fixture.session.backgroundCurrentAssistantRowIDs.count, 3, "A run's segment end retires no background row.")
    }

    func testBackgroundSegmentEndEndsOnlyItsSourceAndRetiresCurrentRowFirst() throws {
        let viewModel = makeViewModel()
        let fixture = backgroundFixture()
        var received: [Mutation] = []
        var currentRowAtNotification: UUID??
        fixture.session.onSourceItemsChanged = { session, mutation, _ in
            received.append(mutation)
            currentRowAtNotification = .some(session.backgroundCurrentAssistantRowIDs[fixture.sourceS1])
        }

        viewModel.endBackgroundMessage(fromSource: fixture.sourceS1, session: fixture.session)

        XCTAssertEqual(
            streamingIDs(fixture.session),
            [fixture.foregroundA, fixture.backgroundS2, fixture.foregroundB, fixture.backgroundUnsourced]
        )
        XCTAssertEqual(try singleRange(received), 2 ... 2)
        XCTAssertEqual(currentRowAtNotification, .some(nil), "The current row must be retired before the flip.")
        XCTAssertNil(fixture.session.backgroundCurrentAssistantRowIDs[fixture.sourceS1])
        XCTAssertEqual(fixture.session.backgroundCurrentAssistantRowIDs[fixture.sourceS2], fixture.backgroundS2)

        // Unsourced background delivery ends only rows without a source.
        received.removeAll()
        viewModel.test_endAssistantSegment(fixture.session, background: true, sourceID: nil)
        XCTAssertEqual(streamingIDs(fixture.session), [fixture.foregroundA, fixture.backgroundS2, fixture.foregroundB])
        XCTAssertEqual(try singleRange(received), 6 ... 6)
        XCTAssertNil(fixture.session.backgroundCurrentAssistantRowIDs[nil])
    }

    func testBackgroundSegmentEndWithNothingStreamingStillRetiresAndDoesNotNotify() {
        let viewModel = makeViewModel()
        let fixture = backgroundFixture()
        viewModel.test_endAssistantSegment(fixture.session, background: true, sourceID: fixture.sourceS1)
        var received: [Mutation] = []
        fixture.session.onSourceItemsChanged = { _, mutation, _ in received.append(mutation) }
        fixture.session.backgroundCurrentAssistantRowIDs[fixture.sourceS1] = fixture.backgroundS1
        let revisionBefore = fixture.session.sourceItemsRevision

        viewModel.test_endAssistantSegment(fixture.session, background: true, sourceID: fixture.sourceS1)

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(fixture.session.sourceItemsRevision, revisionBefore)
        XCTAssertNil(fixture.session.backgroundCurrentAssistantRowIDs[fixture.sourceS1])
    }

    // MARK: - Refresh: incremental eligibility and cold-rebuild equality

    func testCoalescedSegmentEndRefreshesIncrementallyAndEqualsColdRebuild() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        var items = multiTurnHistory(turnCount: 3)
        items.append(.user("Final question", sequenceIndex: items.count))
        items.append(streamingAssistant("Looking", items.count))
        session.setItemsSilently(items, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        let snapshot = session.transcriptPerformanceSnapshot

        let invocationID = UUID()
        session.appendItem(.assistant("Let me check.", sequenceIndex: session.nextSequenceIndex, isStreaming: true))
        viewModel.endActiveAssistantSegment(session)
        session.appendItem(.toolCall(
            name: "read_file",
            invocationID: invocationID,
            argsJSON: #"{"path":"/tmp/a.swift"}"#,
            sequenceIndex: session.nextSequenceIndex
        ))
        session.appendItem(.toolResult(
            name: "read_file",
            invocationID: invocationID,
            resultJSON: #"{"content":"ok"}"#,
            sequenceIndex: session.nextSequenceIndex
        ))
        let pending = try XCTUnwrap(session.pendingSourceItemsMutationSummary)
        XCTAssertTrue(pending.allowsIncrementalFinalTurnRebuild, "A segment end must not poison the coalesced batch.")
        let sourceItemsBeforeRefresh = session.items
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        let after = session.transcriptPerformanceSnapshot
        XCTAssertGreaterThan(after.incrementalImportAttemptCount, snapshot.incrementalImportAttemptCount)
        XCTAssertGreaterThan(after.incrementalImportSuccessCount, snapshot.incrementalImportSuccessCount)
        XCTAssertEqual(after.incrementalImportFallbackCount, snapshot.incrementalImportFallbackCount)
        XCTAssertFalse(session.items.contains { $0.kind == .assistant && $0.isStreaming })
        try await assertEqualsColdRebuild(session, from: sourceItemsBeforeRefresh, viewModel: viewModel)
    }

    /// A provider tool event ends the assistant segment and then the reasoning segment
    /// (`endAssistantSegment` + `endActiveReasoningSegment`), then appends the tool rows. The
    /// whole coalesced batch must stay incremental and equal a cold rebuild.
    func testMixedAssistantAndReasoningSegmentEndRefreshesIncrementallyAndEqualsColdRebuild() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        var items = multiTurnHistory(turnCount: 3)
        items.append(.user("Final question", sequenceIndex: items.count))
        session.setItemsSilently(items, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        let snapshot = session.transcriptPerformanceSnapshot

        viewModel.applyReasoningDelta("Considering the file", groupID: "g1", session: session)
        session.appendItem(.assistant("Let me check.", sequenceIndex: session.nextSequenceIndex, isStreaming: true))
        XCTAssertTrue(session.items.contains { $0.kind == .thinking && $0.isStreaming })
        viewModel.test_endAssistantSegment(session, background: false)
        viewModel.endActiveReasoningSegment(session)
        let invocationID = UUID()
        session.appendItem(.toolCall(
            name: "read_file",
            invocationID: invocationID,
            argsJSON: #"{"path":"/tmp/b.swift"}"#,
            sequenceIndex: session.nextSequenceIndex
        ))
        session.appendItem(.toolResult(
            name: "read_file",
            invocationID: invocationID,
            resultJSON: #"{"content":"ok"}"#,
            sequenceIndex: session.nextSequenceIndex
        ))
        let pending = try XCTUnwrap(session.pendingSourceItemsMutationSummary)
        XCTAssertTrue(
            pending.allowsIncrementalFinalTurnRebuild,
            "Assistant plus reasoning segment end must not poison the coalesced batch."
        )
        XCTAssertFalse(pending.containsUnrangedMutation)
        XCTAssertFalse(session.items.contains { ($0.kind == .thinking || $0.kind == .assistant) && $0.isStreaming })
        let sourceItemsBeforeRefresh = session.items
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        let after = session.transcriptPerformanceSnapshot
        XCTAssertGreaterThan(after.incrementalImportAttemptCount, snapshot.incrementalImportAttemptCount)
        XCTAssertGreaterThan(after.incrementalImportSuccessCount, snapshot.incrementalImportSuccessCount)
        XCTAssertEqual(after.incrementalImportFallbackCount, snapshot.incrementalImportFallbackCount)
        try await assertEqualsColdRebuild(session, from: sourceItemsBeforeRefresh, viewModel: viewModel)
    }

    func testSegmentEndBeforeFinalTurnFallsBackAndEqualsColdRebuild() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        var items = multiTurnHistory(turnCount: 3)
        // A stale streaming row in an earlier turn: its flip changes that turn.
        items[1].isStreaming = true
        items.append(.user("Final question", sequenceIndex: items.count))
        items.append(streamingAssistant("Looking", items.count))
        session.setItemsSilently(items, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        let snapshot = session.transcriptPerformanceSnapshot

        viewModel.endActiveAssistantSegment(session)
        XCTAssertEqual(session.pendingSourceItemsMutationSummary?.earliestChangedIndex, 1)
        let sourceItemsBeforeRefresh = session.items
        await viewModel.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

        let after = session.transcriptPerformanceSnapshot
        XCTAssertGreaterThan(after.incrementalImportAttemptCount, snapshot.incrementalImportAttemptCount)
        XCTAssertGreaterThan(after.incrementalImportFallbackCount, snapshot.incrementalImportFallbackCount)
        try await assertEqualsColdRebuild(session, from: sourceItemsBeforeRefresh, viewModel: viewModel)
    }

    // MARK: - Helpers

    private struct BackgroundFixture {
        let session: AgentModeViewModel.TabSession
        let sourceS1: UUID
        let sourceS2: UUID
        let foregroundA: UUID
        let backgroundS1: UUID
        let backgroundS2: UUID
        let foregroundB: UUID
        let backgroundUnsourced: UUID
    }

    /// Index 0 user; 1 foreground A; 2 background S1; 3 background S2; 4 thinking; 5 foreground B;
    /// 6 unsourced background. Every assistant row is streaming.
    private func backgroundFixture() -> BackgroundFixture {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let items: [AgentChatItem] = [
            .user("q", sequenceIndex: 0),
            streamingAssistant("fg A", 1),
            streamingAssistant("bg S1", 2),
            streamingAssistant("bg S2", 3),
            streamingThinking("thinking", 4),
            streamingAssistant("fg B", 5),
            streamingAssistant("bg unsourced", 6)
        ]
        session.setItemsSilently(items, reason: .testOverride)
        let sourceS1 = UUID()
        let sourceS2 = UUID()
        session.backgroundRowIDs = [items[2].id, items[3].id, items[6].id]
        session.backgroundRowSourceIDs = [items[2].id: sourceS1, items[3].id: sourceS2]
        session.backgroundCurrentAssistantRowIDs = [sourceS1: items[2].id, sourceS2: items[3].id, nil: items[6].id]
        return BackgroundFixture(
            session: session,
            sourceS1: sourceS1,
            sourceS2: sourceS2,
            foregroundA: items[1].id,
            backgroundS1: items[2].id,
            backgroundS2: items[3].id,
            foregroundB: items[5].id,
            backgroundUnsourced: items[6].id
        )
    }

    private func streamingIDs(_ session: AgentModeViewModel.TabSession) -> [UUID] {
        session.items.filter { $0.kind == .assistant && $0.isStreaming }.map(\.id)
    }

    private func singleRange(_ received: [Mutation], file: StaticString = #filePath, line: UInt = #line) throws -> ClosedRange<Int>? {
        XCTAssertEqual(received.count, 1, file: file, line: line)
        guard case let .assistantStreamingStateChanged(range) = try XCTUnwrap(received.first, file: file, line: line) else {
            XCTFail("Expected a ranged segment-end mutation, got \(received)", file: file, line: line)
            return nil
        }
        return range
    }

    /// Cold reference: a fresh session given the same pre-refresh source items and run state, fully
    /// rebuilt. Pre-refresh items, because retention compaction keeps raw payloads only ephemerally.
    private func assertEqualsColdRebuild(
        _ session: AgentModeViewModel.TabSession,
        from sourceItems: [AgentChatItem],
        viewModel: AgentModeViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cold = try await viewModel.ensureSessionReady(tabID: UUID())
        cold.runState = session.runState
        cold.selectedAgent = session.selectedAgent
        cold.setItemsSilently(sourceItems, reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: cold, publishActivePresentation: false)

        XCTAssertEqual(session.items, cold.items, "post-retention items", file: file, line: line)
        XCTAssertEqual(session.transcript, cold.transcript, "sanitized transcript", file: file, line: line)
        XCTAssertEqual(session.workingTranscriptProjection, cold.workingTranscriptProjection, "working projection", file: file, line: line)
        XCTAssertEqual(session.transcriptProjection, cold.transcriptProjection, "projection", file: file, line: line)
        XCTAssertEqual(
            session.ephemeralToolResultPayloadByItemID,
            cold.ephemeralToolResultPayloadByItemID,
            "ephemeral payload map",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(session.ephemeralToolResultPayloadRevisionByItemID.keys),
            Set(cold.ephemeralToolResultPayloadRevisionByItemID.keys),
            "ephemeral payload revision keys",
            file: file,
            line: line
        )
    }

    private func multiTurnHistory(turnCount: Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        for turn in 0 ..< turnCount {
            items.append(.user("user \(turn)", sequenceIndex: items.count))
            items.append(.assistant("assistant \(turn)", sequenceIndex: items.count))
        }
        return items
    }

    private func streamingAssistant(_ text: String, _ sequenceIndex: Int) -> AgentChatItem {
        .assistant(text, sequenceIndex: sequenceIndex, isStreaming: true)
    }

    private func streamingThinking(_ text: String, _ sequenceIndex: Int) -> AgentChatItem {
        var item = AgentChatItem.thinking(text, sequenceIndex: sequenceIndex)
        item.isStreaming = true
        return item
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
