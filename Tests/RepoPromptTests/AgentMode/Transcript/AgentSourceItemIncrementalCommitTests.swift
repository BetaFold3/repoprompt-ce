#if DEBUG
    import Foundation
    @testable import RepoPromptAgentCore
    @testable import RepoPromptPlatform
    @testable import RepoPromptUI
    @testable import RepoPromptWorkspace
    import XCTest
    @_spi(TestSupport) @testable import RepoPromptApp

    /// D5: collision-free single-row writes and the owned streaming-end commit must leave source
    /// items, identity, sequence, payload/revision history, notifications and tool-correlation
    /// query results exactly as an independent full-scan reference predicts, without a duplicate-ID
    /// repair scan or a full derived rebuild. Collisions, generic batches and direct assignment keep
    /// the repaired full path.
    @MainActor
    final class AgentSourceItemIncrementalCommitTests: XCTestCase {
        private typealias Session = AgentTabSession

        // MARK: - Seeded differential

        func testSeededCollisionFreeMutationsMatchIndependentFullScanReference() {
            var coverage = Coverage()
            for seed: UInt64 in [0xD5, 0x5EED_0001, 0xC0FFEE, 0xBAD5EED] {
                runDifferential(seed: seed, steps: 250, coverage: &coverage)
            }
            // The stream must actually exercise the boundaries it claims to cover.
            XCTAssertGreaterThan(coverage.payloadAllocations, 0, "payload allocation")
            XCTAssertGreaterThan(coverage.payloadDeletions, 0, "payload deletion")
            XCTAssertGreaterThan(coverage.payloadReintroductions, 0, "payload deletion then reintroduction")
            XCTAssertGreaterThan(coverage.unchangedPayloadMutations, 0, "mutation with unchanged payloads")
            XCTAssertGreaterThan(coverage.sameIDReplacements, 0, "same-ID replacement")
            XCTAssertGreaterThan(coverage.freshIDReplacements, 0, "fresh-ID replacement")
            XCTAssertGreaterThan(coverage.userKindRebuilds, 0, "user-kind correlation rebuild")
            XCTAssertGreaterThan(coverage.frozenUserAppends, 0, "queued user row while active")
            XCTAssertGreaterThan(coverage.anchorFallbacks, 0, "missing boundary anchor fallback")
            XCTAssertGreaterThan(coverage.streamingEndsWithUnchangedInterior, 0, "streaming range with unchanged interior")
            XCTAssertGreaterThan(coverage.streamingEndsWithoutMatch, 0, "streaming end without a match")
            XCTAssertGreaterThan(coverage.reasoningStreamingEnds, 0, "reasoning streaming end")
            XCTAssertGreaterThan(coverage.staleRunEndFullCommits, 0, "run end with a frozen boundary")
        }

        // MARK: - Skipped work and retained full paths

        func testCollisionFreeSingleRowWritesSkipDuplicateRepairAndFullRebuild() {
            let session = Session(tabID: UUID())
            session.setItemsSilently([.user("q", sequenceIndex: 0), .assistant("a", sequenceIndex: 1)], reason: .testOverride)
            let repairs = session.test_sourceItemDuplicateRepairScanCount
            let rebuilds = session.test_sourceItemDerivedRebuildCount

            session.appendItem(.assistant("b"))
            var sameID = session.items[1]
            sameID.text = "a2"
            session.replaceItem(at: 1, with: sameID)
            session.replaceItem(at: 2, with: .assistant("fresh", sequenceIndex: 5))
            session.mutateItem(at: 0) { $0.text = "q2" }
            session.updateLastItem { $0.text = "fresh2" }
            session.removeItem(at: 1)

            XCTAssertEqual(session.items.map(\.text), ["q2", "fresh2"])
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds)
            session.testAssertSourceItemDerivedStateIsConsistent()

            // Generic paths still repair and rebuild, once each (the rebuild no longer repairs again).
            session.mutateItemsBatch { $0[1].text = "batch" }
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs + 1)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds + 1)
            session.items[1].text = "direct"
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs + 2)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds + 2)
            session.setItemsSilently(session.items, reason: .testOverride)
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs + 3)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds + 3)
        }

        func testGenericBatchAndDirectAssignmentStillRepairDuplicateIDs() {
            let session = Session(tabID: UUID())
            session.setItemsSilently([.user("q", sequenceIndex: 0), .assistant("a", sequenceIndex: 1)], reason: .testOverride)
            let duplicatedID = session.items[1].id

            session.mutateItemsBatch { $0.append(AgentChatItem(id: duplicatedID, kind: .assistant, text: "batch", sequenceIndex: 2)) }
            XCTAssertEqual(session.items.count, 3)
            XCTAssertEqual(Set(session.items.map(\.id)).count, 3)
            XCTAssertEqual(session.items[1].id, duplicatedID)

            session.items.append(AgentChatItem(id: duplicatedID, kind: .assistant, text: "direct", sequenceIndex: 3))
            XCTAssertEqual(session.items.count, 4)
            XCTAssertEqual(Set(session.items.map(\.id)).count, 4)
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testCollidingSingleRowWritesKeepRepairedStructuralCommit() {
            let session = Session(tabID: UUID())
            let base: [AgentChatItem] = [
                .user("q", sequenceIndex: 0),
                .assistant("a", sequenceIndex: 1),
                .assistant("b", sequenceIndex: 2),
                .assistant("c", sequenceIndex: 3)
            ]
            session.setItemsSilently(base, reason: .testOverride)
            let received = EventLog()
            session.onSourceItemsChanged = { _, mutation, _ in received.events.append(Event(mutation)) }

            // Append: the existing row is the first occurrence; the appended row is rekeyed.
            assertRepairedStructuralCommit(session, received: received) {
                session.appendItem(AgentChatItem(id: base[1].id, kind: .assistant, text: "appended"))
            }
            XCTAssertEqual(Array(session.items.prefix(4)), base)
            XCTAssertEqual(session.items[4].text, "appended")
            XCTAssertFalse(base.map(\.id).contains(session.items[4].id))

            // Replace with a later row's ID: the replaced row is first, so the later row is rekeyed.
            let moved = AgentChatItem(id: base[3].id, kind: .assistant, text: "moved", sequenceIndex: 1)
            assertRepairedStructuralCommit(session, received: received) {
                session.replaceItem(at: 1, with: moved)
            }
            XCTAssertEqual(session.items[1], moved)
            XCTAssertNotEqual(session.items[3].id, base[3].id)
            XCTAssertEqual(session.items[3].replacingID(base[3].id), base[3])

            // Mutate to an earlier row's ID: the mutated row is rekeyed.
            let userID = base[0].id
            assertRepairedStructuralCommit(session, received: received) {
                session.mutateItem(at: 2) { $0 = AgentChatItem(id: userID, kind: .assistant, text: "mutated", sequenceIndex: 2) }
            }
            XCTAssertEqual(session.items[0], base[0])
            XCTAssertEqual(session.items[2].text, "mutated")
            XCTAssertNotEqual(session.items[2].id, userID)

            // Update-last to an earlier row's ID: the last row is rekeyed.
            let earlierID = session.items[1].id
            assertRepairedStructuralCommit(session, received: received) {
                session.updateLastItem { $0 = AgentChatItem(id: earlierID, kind: .assistant, text: "last", sequenceIndex: 9) }
            }
            XCTAssertEqual(session.items[1], moved)
            XCTAssertEqual(session.items.last?.text, "last")
            XCTAssertNotEqual(session.items.last?.id, earlierID)

            // An exact duplicate of another row is dropped by the existing repair policy.
            let countBefore = session.items.count
            let exactCopy = session.items[2]
            assertRepairedStructuralCommit(session, received: received) {
                session.replaceItem(at: 1, with: exactCopy)
            }
            XCTAssertEqual(session.items.count, countBefore - 1)
            XCTAssertEqual(session.items[1], exactCopy)
        }

        // MARK: - Streaming end

        func testStreamingEndCommitsOnlyFlagsAndKeepsSidecarPayloadsAndRevisions() throws {
            let session = Session(tabID: UUID())
            let oracleResult = try retainedToolResult(marker: "oracle", chatID: "chat-1", sequenceIndex: 1)
            let items: [AgentChatItem] = [
                .user("q", sequenceIndex: 0),
                oracleResult,
                .assistant("first", sequenceIndex: 2, isStreaming: true),
                .assistant("done", sequenceIndex: 3),
                streamingThinking("thinking", 4),
                .assistant("second", sequenceIndex: 5, isStreaming: true)
            ]
            session.setItemsSilently(items, reason: .testOverride)
            session.captureOracleUIIdentitySidecars(["chat-1": #"{"ui_model_id":"preset-1","ui_model_name":"Oracle One"}"#])
            let payloadsBefore = session.ephemeralToolResultPayloadByItemID
            let revisionsBefore = session.ephemeralToolResultPayloadRevisionByItemID
            XCTAssertEqual(payloadsBefore[oracleResult.id]?.contains("preset-1"), true, "sidecar merged before the flip")
            var received: [Event] = []
            session.onSourceItemsChanged = { _, mutation, _ in received.append(Event(mutation)) }
            session.isDirty = false
            let activityBefore = session.lastActivityAt
            let sequenceBefore = session.nextSequenceIndex
            let revisionBefore = session.sourceItemsRevision
            let repairs = session.test_sourceItemDuplicateRepairScanCount
            let rebuilds = session.test_sourceItemDerivedRebuildCount

            XCTAssertTrue(session.endStreamingAssistantRows())

            XCTAssertEqual(received, [.assistantStreaming(2 ... 5)])
            var expected = items
            expected[2].isStreaming = false
            expected[5].isStreaming = false
            XCTAssertEqual(session.items, expected)
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, payloadsBefore)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisionsBefore)
            XCTAssertEqual(session.sourceItemsRevision, revisionBefore + 1)
            XCTAssertEqual(session.nextSequenceIndex, sequenceBefore)
            XCTAssertEqual(session.lastActivityAt, activityBefore)
            XCTAssertTrue(session.isDirty)
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds)
            session.testAssertSourceItemDerivedStateIsConsistent()

            // Idempotent: nothing left to end means no event, revision, or dirtying.
            session.isDirty = false
            XCTAssertFalse(session.endStreamingAssistantRows())
            XCTAssertEqual(received.count, 1)
            XCTAssertEqual(session.sourceItemsRevision, revisionBefore + 1)
            XCTAssertFalse(session.isDirty)

            XCTAssertTrue(session.endStreamingReasoningRows { _ in true })
            XCTAssertEqual(received.last, .reasoningStreaming(4 ... 4))
            XCTAssertFalse(session.items[4].isStreaming)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisionsBefore)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds)

            // An admitted single-row write keeps the incremental sidecar merge.
            let appended = try retainedToolResult(marker: "appended", chatID: "chat-1", sequenceIndex: 0)
            session.appendItem(appended)
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[appended.id]?.contains("preset-1"), true)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[oracleResult.id], revisionsBefore[oracleResult.id])
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// The former full rebuild re-derived an idle session's active-turn boundary from the last
        /// user row; the flags-only commit keeps that effect for a boundary frozen during a run.
        func testIdleStreamingEndReconcilesBoundaryFrozenDuringRun() {
            let session = Session(tabID: UUID())
            let earlierInvocation = UUID()
            let laterInvocation = UUID()
            session.setItemsSilently([
                .user("active", sequenceIndex: 0),
                .toolCall(name: "read_file", invocationID: earlierInvocation, argsJSON: "{}", sequenceIndex: 1)
            ], reason: .testOverride)
            session.runState = .running
            session.appendItem(.user("steering"))
            session.appendItem(.toolCall(name: "read_file", invocationID: laterInvocation, argsJSON: "{}"))
            session.appendItem(.assistant("streaming", isStreaming: true))
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: earlierInvocation), [1], "frozen while running")
            session.runState = .idle
            let rebuilds = session.test_sourceItemDerivedRebuildCount

            XCTAssertTrue(session.endStreamingAssistantRows())

            XCTAssertTrue(session.indexedToolItemIndices(invocationID: earlierInvocation).isEmpty)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: laterInvocation), [3])
            XCTAssertEqual(session.activeTurnToolItemIndices { $0.kind == .toolCall }.indices, [3])
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// D5-01: during a run, single-row writes leave a stale start when a removed boundary
        /// anchor is reappended. The former full rebuild at streaming end re-resolved it; the
        /// flags-only commit must reach the same correlation outcome without a full rebuild.
        func testActiveStreamingEndReResolvesReappendedBoundaryAnchor() {
            let session = Session(tabID: UUID())
            let invocation = UUID()
            let anchor = AgentChatItem.user("anchor", sequenceIndex: 0)
            session.setItemsSilently([
                anchor,
                .toolCall(name: "read_file", invocationID: invocation, argsJSON: "{}", sequenceIndex: 1),
                .assistant("streaming", sequenceIndex: 2, isStreaming: true)
            ], reason: .testOverride)
            session.runState = .running
            XCTAssertEqual(session.removeItem(at: 0), anchor)
            session.appendItem(anchor)
            XCTAssertEqual(session.items.map(\.id).last, anchor.id)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocation), [0], "stale before streaming end")

            let outcome = assertActiveFlagsOnlyStreamingEndMatchesFullRebuild(session, invocationIDs: [invocation])

            XCTAssertEqual(outcome, CorrelationSnapshot(invocationIndices: [[]], activeCalls: [], scannedItemCount: 0))
        }

        /// D5-01: a missing anchor resolves by sequence index; a sequence change moves that
        /// fallback without re-resolving it. Streaming end must match the former full rebuild.
        func testActiveStreamingEndReResolvesMissingAnchorAfterSequenceChange() {
            let session = Session(tabID: UUID())
            let invocation = UUID()
            session.setItemsSilently([
                .user("anchor", sequenceIndex: 5),
                .toolCall(name: "read_file", invocationID: invocation, argsJSON: "{}", sequenceIndex: 6),
                .assistant("streaming", sequenceIndex: 7, isStreaming: true)
            ], reason: .testOverride)
            session.runState = .running
            XCTAssertNotNil(session.removeItem(at: 0))
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocation), [0], "fallback includes the tool row")
            session.mutateItem(at: 0) { $0.sequenceIndex = 4 }
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocation), [0], "stale before streaming end")

            let outcome = assertActiveFlagsOnlyStreamingEndMatchesFullRebuild(session, invocationIDs: [invocation])

            XCTAssertEqual(outcome, CorrelationSnapshot(invocationIndices: [[]], activeCalls: [], scannedItemCount: 1))
        }

        // MARK: - No-op boundaries

        func testNoOpAndInvalidSingleRowWritesEmitNothing() {
            let session = Session(tabID: UUID())
            var received: [Event] = []
            session.onSourceItemsChanged = { _, mutation, _ in received.append(Event(mutation)) }
            session.updateLastItem { $0.text = "ignored" }
            XCTAssertNil(session.removeItem(at: 0))
            XCTAssertFalse(session.endStreamingAssistantRows())

            session.setItemsSilently([.user("q", sequenceIndex: 0)], reason: .testOverride)
            let revision = session.sourceItemsRevision
            let unchanged = session.items[0]
            session.replaceItem(at: 0, with: unchanged)
            session.replaceItem(at: 5, with: .assistant("out of range"))
            session.mutateItem(at: 0) { _ in }
            session.mutateItem(at: -1) { $0.text = "invalid" }
            session.updateLastItem { _ in }

            XCTAssertTrue(received.isEmpty)
            XCTAssertEqual(session.sourceItemsRevision, revision)
            XCTAssertEqual(session.items, [unchanged])
        }

        // MARK: - Differential driver

        private func runDifferential(seed: UInt64, steps: Int, coverage: inout Coverage) {
            var rng = SplitMix64(state: seed)
            var factory = ItemFactory()
            let session = Session(tabID: UUID())
            var reference = Reference(sourceRevision: session.sourceItemsRevision)
            var removedPool: [AgentChatItem] = []
            var received: [Event] = []
            session.onSourceItemsChanged = { _, mutation, _ in received.append(Event(mutation)) }

            for step in 0 ..< steps {
                let context = "seed=\(seed) step=\(step)"
                received.removeAll()
                session.isDirty = false
                let activityBefore = session.lastActivityAt
                let repairs = session.test_sourceItemDuplicateRepairScanCount
                let rebuilds = session.test_sourceItemDerivedRebuildCount
                var expectedEvent: Event?
                var isStreamingEnd = false
                var expectedFullCommits = 0

                var operation = reference.rows.isEmpty ? 0 : rng.int(100)
                // Reintroducing the boundary anchor's own ID is excluded: an append does not
                // re-resolve a boundary (pre-existing behavior; see D5 evidence). Streaming end
                // recovers it; the deterministic D5-01 tests cover that recovery.
                let reintroducible = removedPool.indices.filter { removedPool[$0].id != reference.anchorID }
                if (40 ..< 45).contains(operation), reintroducible.isEmpty { operation = 0 }
                switch operation {
                case 0 ..< 40, 40 ..< 45:
                    var item: AgentChatItem
                    if operation >= 40 {
                        item = removedPool.remove(at: reintroducible[rng.int(reintroducible.count)])
                        if reference.payloads[item.id] == nil,
                           AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item) != nil
                        {
                            coverage.payloadReintroductions += 1
                        }
                    } else {
                        item = factory.make(kind: factory.randomKind(&rng), rng: &rng)
                    }
                    session.appendItem(item)
                    item.sequenceIndex = reference.nextSequenceIndex
                    reference.nextSequenceIndex += 1
                    reference.rows.append(item)
                    expectedEvent = .append(reference.rows.count - 1, item.kind)
                    if item.kind == .user {
                        if reference.isActive {
                            coverage.frozenUserAppends += 1
                        } else {
                            reference.boundary = .after(item.id, item.sequenceIndex)
                            reference.startIndex = reference.rows.count
                        }
                    }
                case 45 ..< 55:
                    let index = rng.int(reference.rows.count)
                    let previous = reference.rows[index]
                    var updated: AgentChatItem
                    if rng.bool() {
                        updated = previous
                        reference.randomChange(&rng, factory: &factory).apply(to: &updated)
                        coverage.sameIDReplacements += 1
                    } else {
                        updated = factory.make(kind: factory.randomKind(&rng), rng: &rng)
                        updated.sequenceIndex = previous.sequenceIndex
                        coverage.freshIDReplacements += 1
                    }
                    session.replaceItem(at: index, with: updated)
                    expectedEvent = reference.replace(at: index, with: updated, coverage: &coverage)
                        .map { Event.replace(index, previous.kind, $0.kind) }
                case 55 ..< 68:
                    let index = rng.int(reference.rows.count)
                    let change = reference.randomChange(&rng, factory: &factory)
                    session.mutateItem(at: index) { change.apply(to: &$0) }
                    var updated = reference.rows[index]
                    change.apply(to: &updated)
                    expectedEvent = reference.replace(at: index, with: updated, coverage: &coverage)
                        .map { Event.mutate(index, $0.kind) }
                case 68 ..< 78:
                    let index = reference.rows.count - 1
                    let previous = reference.rows[index]
                    let change = reference.randomChange(&rng, factory: &factory)
                    session.updateLastItem { change.apply(to: &$0) }
                    var updated = previous
                    change.apply(to: &updated)
                    expectedEvent = reference.replace(at: index, with: updated, coverage: &coverage)
                        .map { Event.replace(index, previous.kind, $0.kind) }
                case 78 ..< 86:
                    var index = rng.int(reference.rows.count)
                    if case let .after(anchorID, _) = reference.boundary, rng.int(4) == 0,
                       let anchorIndex = reference.rows.firstIndex(where: { $0.id == anchorID })
                    {
                        index = anchorIndex
                    }
                    let removed = reference.rows.remove(at: index)
                    XCTAssertEqual(session.removeItem(at: index), removed, context)
                    removedPool.append(removed)
                    reference.rebuildCorrelation(coverage: &coverage)
                    expectedEvent = .remove(index, removed.kind)
                case 86 ..< 96:
                    isStreamingEnd = true
                    let kind: AgentChatItemKind = rng.int(3) == 0 ? .thinking : .assistant
                    let selected = Set(reference.rows.filter { _ in rng.bool() }.map(\.id))
                    if kind == .assistant {
                        session.endStreamingAssistantRows { selected.contains($0.id) }
                    } else {
                        session.endStreamingReasoningRows { selected.contains($0.id) }
                    }
                    let flipped = reference.rows.indices.filter { index in
                        let row = reference.rows[index]
                        return row.kind == kind && row.isStreaming && selected.contains(row.id)
                    }
                    if let first = flipped.first, let last = flipped.last {
                        for index in flipped {
                            reference.rows[index].isStreaming = false
                        }
                        if !reference.isActive {
                            reference.rebuildCorrelation(coverage: &coverage)
                        }
                        expectedEvent = kind == .assistant ? .assistantStreaming(first ... last) : .reasoningStreaming(first ... last)
                        if last - first + 1 > flipped.count { coverage.streamingEndsWithUnchangedInterior += 1 }
                        if kind == .thinking { coverage.reasoningStreamingEnds += 1 }
                    } else {
                        coverage.streamingEndsWithoutMatch += 1
                    }
                default:
                    // Run-state toggle. Incremental single-row writes keep a boundary frozen by a
                    // queued user row after the run ends, until a full rebuild (pre-existing
                    // behavior; see D5 evidence), and the full consistency sweep reports that as
                    // desynchronized. Such a run end is therefore followed by a full silent commit.
                    if !reference.isActive {
                        reference.isActive = true
                        session.runState = .running
                    } else {
                        let boundaryWasFresh = reference.boundaryIsIdleFresh
                        reference.isActive = false
                        session.runState = .idle
                        if !boundaryWasFresh {
                            session.setItemsSilently(session.items, reason: .testOverride)
                            reference.rebuildCorrelation(coverage: &coverage)
                            reference.sourceRevision += 1
                            expectedFullCommits = 1
                            coverage.staleRunEndFullCommits += 1
                        }
                    }
                }

                let allocations = reference.advancePayloadHistory(coverage: &coverage, mutated: expectedEvent != nil)
                XCTAssertLessThanOrEqual(allocations, 1, "\(context): exact stamp comparison allows one allocation per step")
                if expectedEvent != nil {
                    reference.sourceRevision += 1
                }
                XCTAssertEqual(received, expectedEvent.map { [$0] } ?? [], context)
                XCTAssertEqual(session.isDirty, expectedEvent != nil, context)
                if isStreamingEnd {
                    XCTAssertEqual(session.lastActivityAt, activityBefore, context)
                }
                XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs + expectedFullCommits, context)
                XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds + expectedFullCommits, context)
                assertSessionMatchesReference(session, reference, factory: factory, context: context)
                session.testAssertSourceItemDerivedStateIsConsistent()
                if hasFailedAssertions { return }
            }
        }

        private struct CorrelationSnapshot: Equatable {
            var invocationIndices: [[Int]]
            var activeCalls: [Int]
            var scannedItemCount: Int
        }

        private func correlationSnapshot(_ session: Session, invocationIDs: [UUID]) -> CorrelationSnapshot {
            let activeCalls = session.activeTurnToolItemIndices { $0.kind == .toolCall }
            return CorrelationSnapshot(
                invocationIndices: invocationIDs.map { session.indexedToolItemIndices(invocationID: $0) },
                activeCalls: activeCalls.indices,
                scannedItemCount: activeCalls.scannedItemCount
            )
        }

        /// Ends streaming during an active run as one flags-only commit (no duplicate repair, no
        /// full derived rebuild, payload/revision history untouched), then checks the correlation
        /// outcome equals the former streaming-end full rebuild with the frozen boundary.
        private func assertActiveFlagsOnlyStreamingEndMatchesFullRebuild(
            _ session: Session,
            invocationIDs: [UUID],
            file: StaticString = #filePath,
            line: UInt = #line
        ) -> CorrelationSnapshot {
            XCTAssertTrue(session.runState.isActive, file: file, line: line)
            let repairs = session.test_sourceItemDuplicateRepairScanCount
            let rebuilds = session.test_sourceItemDerivedRebuildCount
            let payloads = session.ephemeralToolResultPayloadByItemID
            let revisions = session.ephemeralToolResultPayloadRevisionByItemID

            XCTAssertTrue(session.endStreamingAssistantRows(), file: file, line: line)

            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs, file: file, line: line)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds, file: file, line: line)
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, payloads, file: file, line: line)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, revisions, file: file, line: line)
            session.testAssertSourceItemDerivedStateIsConsistent()
            let flagsOnly = correlationSnapshot(session, invocationIDs: invocationIDs)

            // The former streaming-end path: a full commit rebuilding from the frozen boundary.
            session.setItemsSilently(session.items, reason: .testOverride)
            XCTAssertTrue(session.runState.isActive, file: file, line: line)
            XCTAssertEqual(correlationSnapshot(session, invocationIDs: invocationIDs), flagsOnly, file: file, line: line)
            return flagsOnly
        }

        private var hasFailedAssertions: Bool {
            (testRun?.failureCount ?? 0) > 0
        }

        private func assertSessionMatchesReference(
            _ session: Session,
            _ reference: Reference,
            factory: ItemFactory,
            context: String
        ) {
            let rows = reference.rows
            XCTAssertEqual(session.items, rows, context)
            XCTAssertEqual(session.liveItemIDs, Set(rows.map(\.id)), context)
            XCTAssertEqual(session.nextSequenceIndex, reference.nextSequenceIndex, context)
            XCTAssertEqual(session.sourceItemsRevision, reference.sourceRevision, context)
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID, reference.payloads, context)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID, reference.revisions, context)

            let activeIndices = Array(min(reference.startIndex, rows.count) ..< rows.count)
            let toolIndices = activeIndices.filter { rows[$0].kind == .toolCall || rows[$0].kind == .toolResult }
            for invocationID in factory.invocationPool.compactMap(\.self) + [UUID()] {
                XCTAssertEqual(
                    session.indexedToolItemIndices(invocationID: invocationID),
                    toolIndices.filter { rows[$0].toolInvocationID == invocationID },
                    "\(context) invocation"
                )
            }
            let signatureOf = { (row: AgentChatItem) in
                Session.canonicalToolInvocationSignature(toolName: row.toolName, argsJSON: row.toolArgsJSON)
            }
            let signatures = Set(rows.filter { $0.kind == .toolCall || $0.kind == .toolResult }.map(signatureOf))
            for signature in signatures.union(["missing|{}"]) {
                XCTAssertEqual(
                    session.indexedToolItemIndices(signature: signature),
                    toolIndices.filter { signatureOf(rows[$0]) == signature },
                    "\(context) signature"
                )
                XCTAssertEqual(
                    session.indexedToolItemIndices(signature: signature, pendingCallsOnly: true),
                    toolIndices.filter { rows[$0].kind == .toolCall && signatureOf(rows[$0]) == signature },
                    "\(context) pending signature"
                )
            }
            for name in Set(factory.toolNames.map { Session.normalizedToolCorrelationName($0) }).union(["missing"]) {
                XCTAssertEqual(
                    session.indexedNilInvocationToolItemIndices(normalizedToolName: name),
                    toolIndices.filter {
                        rows[$0].toolInvocationID == nil && Session.normalizedToolCorrelationName(rows[$0].toolName) == name
                    },
                    "\(context) nil invocation"
                )
            }
            let activeCalls = session.activeTurnToolItemIndices { $0.kind == .toolCall }
            XCTAssertEqual(activeCalls.indices, activeIndices.filter { rows[$0].kind == .toolCall }, "\(context) active turn")
            XCTAssertEqual(activeCalls.scannedItemCount, activeIndices.count, "\(context) active turn scan")
        }

        private func assertRepairedStructuralCommit(
            _ session: Session,
            received: EventLog,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ write: () -> Void
        ) {
            received.events.removeAll()
            let repairs = session.test_sourceItemDuplicateRepairScanCount
            let rebuilds = session.test_sourceItemDerivedRebuildCount
            let revision = session.sourceItemsRevision
            write()
            XCTAssertEqual(received.events, [.structural], file: file, line: line)
            // Exactly two scans: the colliding write's detection scan, then `commitSourceItems`'
            // unconditional repair of the already-repaired candidate (a no-op re-scan).
            XCTAssertEqual(session.test_sourceItemDuplicateRepairScanCount, repairs + 2, file: file, line: line)
            XCTAssertEqual(session.test_sourceItemDerivedRebuildCount, rebuilds + 1, file: file, line: line)
            XCTAssertEqual(session.sourceItemsRevision, revision + 1, file: file, line: line)
            XCTAssertEqual(Set(session.items.map(\.id)).count, session.items.count, file: file, line: line)
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)), file: file, line: line)
            XCTAssertEqual(
                Set(session.ephemeralToolResultPayloadRevisionByItemID.keys),
                Set(session.ephemeralToolResultPayloadByItemID.keys),
                file: file,
                line: line
            )
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        private func retainedToolResult(marker: String, chatID: String, sequenceIndex: Int) throws -> AgentChatItem {
            let object: [String: Any] = [
                "status": "success",
                "chat_id": chatID,
                "session_id": "session-\(marker)",
                "response": String(repeating: "raw \(marker) response ", count: 80)
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
            let item = AgentChatItem(
                kind: .toolResult,
                text: raw,
                toolName: "agent_run",
                toolInvocationID: UUID(),
                toolResultJSON: raw,
                toolIsError: false,
                sequenceIndex: sequenceIndex
            )
            XCTAssertNotNil(AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item), "fixture must retain")
            return item
        }

        private func streamingThinking(_ text: String, _ sequenceIndex: Int) -> AgentChatItem {
            var item = AgentChatItem.thinking(text, sequenceIndex: sequenceIndex)
            item.isStreaming = true
            return item
        }
    }

    // MARK: - Independent reference

    /// Test-owned full-scan reference. It never calls `TabSession` index or payload maintenance:
    /// payloads come from the pure retention policy over every row, revision stamps carry forward
    /// from the previous step, and correlation expectations are full scans from the boundary.
    private struct Reference {
        enum Boundary: Equatable {
            case start
            case after(UUID, Int)
        }

        var rows: [AgentChatItem] = []
        var nextSequenceIndex = 0
        var isActive = false
        var boundary: Boundary = .start
        var startIndex = 0
        var payloads: [UUID: String] = [:]
        var revisions: [UUID: Int] = [:]
        var nextRevision = 1
        var sourceRevision: Int

        init(sourceRevision: Int) {
            self.sourceRevision = sourceRevision
        }

        var idleFreshBoundary: Boundary {
            guard let index = rows.lastIndex(where: { $0.kind == .user }) else { return .start }
            return .after(rows[index].id, rows[index].sequenceIndex)
        }

        /// A boundary whose anchor row is gone resolves by sequence index. Incremental writes do
        /// not re-resolve it (pre-existing behavior; see D5 evidence), so the stream rewrites no
        /// sequence index while in that state; production rows keep their sequence index. Streaming
        /// end recovers it; the deterministic D5-01 tests cover that recovery.
        var anchorIsMissing: Bool {
            guard let anchorID else { return false }
            return !rows.contains(where: { $0.id == anchorID })
        }

        var anchorID: UUID? {
            guard case let .after(anchorID, _) = boundary else { return nil }
            return anchorID
        }

        func randomChange(_ rng: inout SplitMix64, factory: inout ItemFactory) -> Change {
            let change = Change.random(&rng, factory: &factory, nextSequenceIndex: nextSequenceIndex)
            if case .sequenceIndex = change, anchorIsMissing {
                return .text("changed \(factory.nextMarker())")
            }
            return change
        }

        var boundaryIsIdleFresh: Bool {
            boundary == idleFreshBoundary && startIndex == resolvedStartIndex(for: boundary)
        }

        func resolvedStartIndex(for boundary: Boundary) -> Int {
            switch boundary {
            case .start:
                return 0
            case let .after(anchorID, sequenceIndex):
                if let anchorIndex = rows.firstIndex(where: { $0.id == anchorID }) {
                    return anchorIndex + 1
                }
                return rows.firstIndex(where: { $0.sequenceIndex > sequenceIndex }) ?? rows.count
            }
        }

        mutating func rebuildCorrelation(coverage: inout Coverage) {
            if !isActive {
                boundary = idleFreshBoundary
            }
            if case let .after(anchorID, _) = boundary, !rows.contains(where: { $0.id == anchorID }) {
                coverage.anchorFallbacks += 1
            }
            startIndex = resolvedStartIndex(for: boundary)
        }

        /// Returns the updated row when the write changes anything.
        mutating func replace(at index: Int, with updated: AgentChatItem, coverage: inout Coverage) -> AgentChatItem? {
            let previous = rows[index]
            guard updated != previous else { return nil }
            rows[index] = updated
            nextSequenceIndex = max(nextSequenceIndex, updated.sequenceIndex + 1)
            if previous.kind == .user || updated.kind == .user {
                coverage.userKindRebuilds += 1
                rebuildCorrelation(coverage: &coverage)
            }
            return updated
        }

        /// Advances the existing revision history from the previous payloads to a full rescan.
        mutating func advancePayloadHistory(coverage: inout Coverage, mutated: Bool) -> Int {
            var newPayloads: [UUID: String] = [:]
            for row in rows {
                if let payload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: row), !payload.isEmpty {
                    newPayloads[row.id] = payload
                }
            }
            var allocations = 0
            for itemID in Set(payloads.keys).union(newPayloads.keys) where payloads[itemID] != newPayloads[itemID] {
                if newPayloads[itemID] != nil {
                    revisions[itemID] = nextRevision
                    nextRevision += 1
                    allocations += 1
                    coverage.payloadAllocations += 1
                } else {
                    revisions.removeValue(forKey: itemID)
                    coverage.payloadDeletions += 1
                }
            }
            if mutated, !payloads.isEmpty, payloads == newPayloads {
                coverage.unchangedPayloadMutations += 1
            }
            payloads = newPayloads
            return allocations
        }
    }

    private final class EventLog {
        var events: [Event] = []
    }

    private struct Coverage {
        var payloadAllocations = 0
        var payloadDeletions = 0
        var payloadReintroductions = 0
        var unchangedPayloadMutations = 0
        var sameIDReplacements = 0
        var freshIDReplacements = 0
        var userKindRebuilds = 0
        var frozenUserAppends = 0
        var anchorFallbacks = 0
        var streamingEndsWithUnchangedInterior = 0
        var streamingEndsWithoutMatch = 0
        var reasoningStreamingEnds = 0
        var staleRunEndFullCommits = 0
    }

    private enum Event: Equatable {
        case append(Int, AgentChatItemKind)
        case replace(Int, AgentChatItemKind, AgentChatItemKind)
        case mutate(Int, AgentChatItemKind)
        case remove(Int, AgentChatItemKind)
        case assistantStreaming(ClosedRange<Int>)
        case reasoningStreaming(ClosedRange<Int>)
        case replaceAll
        case structural

        init(_ mutation: AgentSourceItemsMutation) {
            switch mutation {
            case let .append(index, kind): self = .append(index, kind)
            case let .replace(index, previous, current): self = .replace(index, previous, current)
            case let .mutate(index, kind): self = .mutate(index, kind)
            case let .remove(index, kind): self = .remove(index, kind)
            case let .assistantStreamingStateChanged(range): self = .assistantStreaming(range)
            case let .reasoningStreamingStateChanged(range): self = .reasoningStreaming(range)
            case .replaceAll: self = .replaceAll
            case .structural: self = .structural
            }
        }
    }

    /// One field-level change, applied identically to the session row and the reference row.
    private enum Change {
        case text(String)
        case toggleStreaming
        case completeToolCall(String)
        case arguments(String?)
        case invocation(UUID?)
        case sequenceIndex(Int)
        case kind(AgentChatItemKind)

        static func random(_ rng: inout SplitMix64, factory: inout ItemFactory, nextSequenceIndex: Int) -> Change {
            switch rng.int(9) {
            case 0, 1: .text("changed \(factory.nextMarker())")
            case 2: .toggleStreaming
            case 3: .completeToolCall(factory.resultJSON(&rng))
            case 4: .arguments(factory.argumentsPool[rng.int(factory.argumentsPool.count)])
            case 5: .invocation(factory.invocationPool[rng.int(factory.invocationPool.count)])
            case 6: .sequenceIndex(nextSequenceIndex + rng.int(3))
            default: .kind(rng.bool() ? .user : .assistant)
            }
        }

        func apply(to item: inout AgentChatItem) {
            switch self {
            case let .text(text): item.text = text
            case .toggleStreaming: item.isStreaming.toggle()
            case let .completeToolCall(resultJSON):
                if item.kind == .toolCall {
                    item.kind = .toolResult
                    item.toolResultJSON = resultJSON
                    item.text = resultJSON
                } else {
                    item.text += " +"
                }
            case let .arguments(arguments): item.toolArgsJSON = arguments
            case let .invocation(invocationID): item.toolInvocationID = invocationID
            case let .sequenceIndex(sequenceIndex): item.sequenceIndex = sequenceIndex
            case let .kind(kind): item.kind = kind
            }
        }
    }

    private struct ItemFactory {
        let toolNames = ["read_file", "file_search", "agent_run"]
        let argumentsPool: [String?] = [nil, "{}", #"{"path":"a.swift"}"#, #"{"path": "a.swift"}"#, #"{"pattern":"needle"}"#]
        let invocationPool: [UUID?] = [
            nil,
            UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"),
            UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"),
            UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")
        ]
        private var marker = 0

        mutating func nextMarker() -> Int {
            marker += 1
            return marker
        }

        func randomKind(_ rng: inout SplitMix64) -> AgentChatItemKind {
            let kinds: [AgentChatItemKind] = [.user, .assistant, .assistant, .thinking, .toolCall, .toolCall, .toolResult, .toolResult, .system]
            return kinds[rng.int(kinds.count)]
        }

        mutating func resultJSON(_ rng: inout SplitMix64) -> String {
            let marker = nextMarker()
            if rng.bool() {
                let response = String(repeating: "raw \(marker) response ", count: 80)
                return #"{"response":"\#(response)","session_id":"session-\#(marker)","status":"success"}"#
            }
            return #"{"n":\#(marker),"status":"ok"}"#
        }

        mutating func make(kind: AgentChatItemKind, rng: inout SplitMix64) -> AgentChatItem {
            let marker = nextMarker()
            let id = rng.uuid()
            let timestamp = Date(timeIntervalSinceReferenceDate: TimeInterval(marker))
            switch kind {
            case .toolCall, .toolResult:
                let result = kind == .toolResult ? resultJSON(&rng) : nil
                return AgentChatItem(
                    id: id,
                    timestamp: timestamp,
                    kind: kind,
                    text: result ?? "call \(marker)",
                    toolName: toolNames[rng.int(toolNames.count)],
                    toolInvocationID: invocationPool[rng.int(invocationPool.count)],
                    toolArgsJSON: argumentsPool[rng.int(argumentsPool.count)],
                    toolResultJSON: result,
                    toolIsError: kind == .toolResult ? false : nil,
                    isStreaming: false
                )
            default:
                return AgentChatItem(
                    id: id,
                    timestamp: timestamp,
                    kind: kind,
                    text: "\(kind) \(marker)",
                    isStreaming: (kind == .assistant || kind == .thinking) && rng.int(3) != 0
                )
            }
        }
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func int(_ upperBound: Int) -> Int {
            Int(next() % UInt64(upperBound))
        }

        mutating func bool() -> Bool {
            next() & 1 == 1
        }

        mutating func uuid() -> UUID {
            let hex = String(format: "%016llX%016llX", next(), next())
            let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            return UUID(uuidString: parts.joined(separator: "-"))!
        }
    }
#endif
