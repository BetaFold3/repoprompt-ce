import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTranscriptBranchPrefixTests: XCTestCase {
    func testBranchPrefixPreservesIdentityHighWaterAndClampsFrontier() throws {
        let fixture = makeThreeTurnFixture()
        var source = fixture.transcript
        source.turns[0].retentionTier = .condensed
        source.compactionFrontier = AgentTranscriptCompactionFrontier(
            frozenPrefixTurnCount: 1,
            lastFrozenTurnID: source.turns[0].id
        )

        let prefix = try AgentTranscriptIO.branchPrefix(
            of: source,
            throughTurnID: fixture.secondUser.id
        )

        XCTAssertEqual(prefix.turns, Array(source.turns.prefix(2)))
        XCTAssertEqual(prefix.turns.map(\.id), source.turns.prefix(2).map(\.id))
        XCTAssertEqual(
            prefix.turns.flatMap { $0.responseSpans.map(\.id) },
            source.turns.prefix(2).flatMap { $0.responseSpans.map(\.id) }
        )
        XCTAssertEqual(prefix.nextSequenceIndex, source.nextSequenceIndex)
        XCTAssertEqual(
            prefix.compactionFrontier,
            AgentTranscriptCompactionFrontier(
                frozenPrefixTurnCount: 1,
                lastFrozenTurnID: source.turns[0].id
            )
        )
    }

    func testSessionBranchPrefixFiltersPayloadsAndDerivesPersistenceMetadata() throws {
        let fixture = makeThreeTurnFixture()
        let targetResultID = try XCTUnwrap(
            fixture.transcript.turns[1].allActivities.first(where: { $0.itemKind == .toolResult })?.id
        )
        let omittedResultID = try XCTUnwrap(
            fixture.transcript.turns[2].allActivities.first(where: { $0.itemKind == .toolResult })?.id
        )
        var source = AgentSession(name: "Source", autoEditEnabled: true)
        source.items = AgentTranscriptIO.flattenFullTranscript(fixture.transcript).map {
            AgentChatItemPersist(from: $0)
        }
        source.uiToolResultPayloadsByItemID = [
            targetResultID.uuidString: "keep",
            omittedResultID.uuidString: "drop",
            UUID().uuidString: "unknown"
        ]
        source.transcript = fixture.transcript
        source.itemCount = 999
        source.transcriptProjectionCounts = .init(
            canonicalVisibleRowCount: 999,
            defaultPresentedRowCount: 999
        )
        source.lastUserMessageAt = Date.distantFuture
        source.providerTokenUsageByTurn = [
            AgentTokenUsagePersist(
                promptTokens: 10,
                completionTokens: 1,
                timestamp: Date(timeIntervalSinceReferenceDate: 5)
            ),
            AgentTokenUsagePersist(
                promptTokens: 20,
                completionTokens: 2,
                timestamp: Date(timeIntervalSinceReferenceDate: 25)
            )
        ]

        let branch = try AgentTranscriptIO.branchPrefix(
            of: source,
            throughTurnID: fixture.secondUser.id
        )
        let transcript = try XCTUnwrap(branch.transcript)
        let counts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)

        XCTAssertTrue(branch.items.isEmpty)
        XCTAssertEqual(transcript.turns.count, 2)
        XCTAssertEqual(branch.uiToolResultPayloadsByItemID, [targetResultID.uuidString: "keep"])
        XCTAssertEqual(branch.itemCount, counts.canonicalVisibleRowCount)
        XCTAssertEqual(branch.transcriptProjectionCounts, counts)
        XCTAssertEqual(branch.lastUserMessageAt, fixture.secondUser.timestamp)
        XCTAssertEqual(branch.providerTokenUsageByTurn.map(\.promptTokens), [10])
    }

    func testBranchPrefixRejectsMissingNonFullAndIncompleteTurns() throws {
        let fixture = makeThreeTurnFixture()

        XCTAssertThrowsError(
            try AgentTranscriptIO.branchPrefix(of: fixture.transcript, throughTurnID: UUID())
        ) {
            XCTAssertEqual($0 as? AgentTranscriptBranchPrefixError, .turnNotFound)
        }

        var nonFull = fixture.transcript
        nonFull.turns[1].retentionTier = .summary
        XCTAssertThrowsError(
            try AgentTranscriptIO.branchPrefix(of: nonFull, throughTurnID: fixture.secondUser.id)
        ) {
            XCTAssertEqual($0 as? AgentTranscriptBranchPrefixError, .turnNotFullyRetained)
        }

        var incomplete = fixture.transcript
        incomplete.turns[1].completedAt = nil
        incomplete.turns[1].responseSpans[0].lifecycle = .open
        XCTAssertThrowsError(
            try AgentTranscriptIO.branchPrefix(of: incomplete, throughTurnID: fixture.secondUser.id)
        ) {
            XCTAssertEqual($0 as? AgentTranscriptBranchPrefixError, .turnNotCompleted)
        }
    }

    func testBranchPrefixRequiresAStoredFinalAssistantReply() throws {
        let fixture = makeThreeTurnFixture()
        var missingConclusion = fixture.transcript
        missingConclusion.turns[1].conclusionActivityID = nil

        XCTAssertThrowsError(
            try AgentTranscriptIO.branchPrefix(
                of: missingConclusion,
                throughTurnID: fixture.secondUser.id
            )
        ) {
            XCTAssertEqual($0 as? AgentTranscriptBranchPrefixError, .missingFinalAssistantReply)
        }

        let session = AgentSession(name: "No transcript", autoEditEnabled: true)
        XCTAssertThrowsError(
            try AgentTranscriptIO.branchPrefix(of: session, throughTurnID: UUID())
        ) {
            XCTAssertEqual($0 as? AgentTranscriptBranchPrefixError, .missingTranscript)
        }
    }

    private func makeThreeTurnFixture() -> (
        transcript: AgentTranscript,
        secondUser: AgentChatItem
    ) {
        let firstUser = item(.user, "first", 0)
        let secondUser = item(.user, "second", 10)
        let thirdUser = item(.user, "third", 20)
        let items = [
            firstUser,
            item(.assistant, "First answer.", 1),
            secondUser,
            item(.toolCall, "read", 11, toolName: "read_file"),
            item(.toolResult, "second result", 12, toolName: "read_file"),
            item(.assistant, "Second answer.", 13),
            thirdUser,
            item(.toolCall, "read", 21, toolName: "read_file"),
            item(.toolResult, "third result", 22, toolName: "read_file"),
            item(.assistant, "Third answer.", 23)
        ]
        return (
            AgentTranscriptIO.buildTranscript(
                from: items,
                terminalState: .completed,
                nextSequenceIndex: 100,
                compact: false
            ),
            secondUser
        )
    }

    private func item(
        _ kind: AgentChatItemKind,
        _ text: String,
        _ sequenceIndex: Int,
        toolName: String? = nil
    ) -> AgentChatItem {
        AgentChatItem(
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
            kind: kind,
            text: text,
            toolName: toolName,
            sequenceIndex: sequenceIndex
        )
    }
}
