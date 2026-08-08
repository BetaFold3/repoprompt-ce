@testable import RepoPromptApp
import XCTest

final class AgentLastCompletedAssistantReplyHandoffCutoffResolverTests: XCTestCase {
    func testResolverUsesStoredRecomputedAndAssistantInlineConclusions() throws {
        let stored = item(kind: .assistant, text: "Stored conclusion.", sequenceIndex: 1)
        let storedTranscript = AgentTranscript(turns: [
            completedTurn(baseSequence: 0, activities: [stored], conclusionActivityID: stored.id)
        ])
        let storedTarget = try target(from: resolve(transcript: storedTranscript))
        XCTAssertEqual(storedTarget.clientRowID, stored.id)
        XCTAssertEqual(storedTarget.previewText, "Stored conclusion.")
        XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(
            storedTarget.clientRowID,
            in: storedTranscript
        ))

        let progress = item(kind: .assistant, text: "Checking the repository", sequenceIndex: 11)
        let tool = item(kind: .toolCall, text: "Read files", sequenceIndex: 12)
        let recomputed = item(
            kind: .assistant,
            text: "Recomputed conclusion.\nAdditional detail.",
            sequenceIndex: 13
        )
        let recomputedTranscript = AgentTranscript(turns: [
            completedTurn(
                baseSequence: 10,
                activities: [progress, tool, recomputed],
                conclusionActivityID: UUID()
            )
        ])
        let recomputedTarget = try target(from: resolve(transcript: recomputedTranscript))
        XCTAssertEqual(recomputedTarget.clientRowID, recomputed.id)
        XCTAssertEqual(recomputedTarget.previewText, "Recomputed conclusion.")
        XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(
            recomputedTarget.clientRowID,
            in: recomputedTranscript
        ))

        let inline = item(kind: .assistantInline, text: "Inline conclusion.", sequenceIndex: 21)
        let inlineTranscript = AgentTranscript(turns: [
            completedTurn(baseSequence: 20, activities: [inline], conclusionActivityID: nil)
        ])
        XCTAssertEqual(try target(from: resolve(transcript: inlineTranscript)).clientRowID, inline.id)
    }

    func testResolverRefusesActiveAndNonForkableSessionsBeforeInspectingTranscript() {
        let answer = item(kind: .assistant, text: "Older completed answer.", sequenceIndex: 1)
        let transcript = AgentTranscript(turns: [
            completedTurn(baseSequence: 0, activities: [answer], conclusionActivityID: answer.id)
        ])

        for runState in [
            AgentSessionRunState.running,
            .waitingForUser,
            .waitingForQuestion,
            .waitingForApproval
        ] {
            XCTAssertEqual(
                resolve(runState: runState, canFork: true, transcript: transcript),
                .unavailable(message: "Wait for the current reply to finish.")
            )
        }
        XCTAssertEqual(
            resolve(runState: .idle, canFork: false, transcript: transcript),
            .unavailable(message: "Nothing to hand off yet.")
        )

        let userOnly = AgentTranscript(turns: [
            completedTurn(baseSequence: 30, activities: [], conclusionActivityID: nil)
        ])
        XCTAssertEqual(
            resolve(runState: .completed, canFork: true, transcript: userOnly),
            .unavailable(message: "No completed assistant reply to hand off.")
        )
    }

    func testResolverFallsBackAcrossActiveCompactedAndLegacyBoundaries() throws {
        let earlier = item(kind: .assistant, text: "Earlier completed reply.", sequenceIndex: 1)
        let earlierTurn = completedTurn(
            baseSequence: 0,
            activities: [earlier],
            conclusionActivityID: earlier.id
        )
        let streaming = item(
            kind: .assistant,
            text: "Still streaming",
            sequenceIndex: 11,
            isStreaming: true
        )
        let activeTurn = completedTurn(
            baseSequence: 10,
            activities: [streaming],
            conclusionActivityID: streaming.id
        )
        let compactedTurn = AgentTranscriptTurn(
            id: UUID(),
            responseSpans: [],
            conclusionActivityID: nil,
            retentionTier: .summary,
            summary: AgentTranscriptTurnSummary(
                requestText: "Compacted request",
                conclusionText: "Compacted summary only",
                compactConclusionText: "Compacted summary only",
                middleSummaryText: nil,
                toolCount: 0,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 2,
                hadWarning: false,
                hadError: false
            ),
            terminalState: .failed,
            startedAt: Date(timeIntervalSinceReferenceDate: 20),
            completedAt: Date(timeIntervalSinceReferenceDate: 21)
        )
        let fallbackTranscript = AgentTranscript(turns: [earlierTurn, activeTurn, compactedTurn])
        XCTAssertEqual(
            try target(from: resolve(transcript: fallbackTranscript)).clientRowID,
            earlier.id
        )

        let legacyUser = item(kind: .user, text: "Legacy request", sequenceIndex: 0)
        let legacyAssistant = item(
            kind: .assistant,
            text: "Legacy completed reply.",
            sequenceIndex: 1
        )
        let newestLegacyUser = item(kind: .user, text: "Newer legacy request", sequenceIndex: 2)
        let newestLegacyAssistant = item(
            kind: .assistant,
            text: "Newest legacy reply.",
            sequenceIndex: 3
        )
        let legacyTarget = try target(from: resolve(
            transcript: .empty,
            legacyItems: [legacyUser, legacyAssistant, newestLegacyUser, newestLegacyAssistant]
        ))
        XCTAssertEqual(legacyTarget.clientRowID, newestLegacyAssistant.id)

        let structuredUserOnly = AgentTranscript(turns: [
            completedTurn(baseSequence: 40, activities: [], conclusionActivityID: nil)
        ])
        XCTAssertEqual(
            resolve(
                transcript: structuredUserOnly,
                legacyItems: [legacyUser, legacyAssistant]
            ),
            .unavailable(message: "No completed assistant reply to hand off.")
        )
    }

    func testResolverSkipsFailedAndCancelledTurnsWithAssistantText() throws {
        let legacyNil = item(
            kind: .assistant,
            text: "Legacy nil-terminal reply.",
            sequenceIndex: 1
        )
        let failed = item(
            kind: .assistant,
            text: "Finalized text from a failed turn.",
            sequenceIndex: 11
        )
        let cancelled = item(
            kind: .assistant,
            text: "Finalized text from a cancelled turn.",
            sequenceIndex: 21
        )
        let transcript = AgentTranscript(turns: [
            completedTurn(
                baseSequence: 0,
                activities: [legacyNil],
                conclusionActivityID: legacyNil.id,
                terminalState: nil
            ),
            completedTurn(
                baseSequence: 10,
                activities: [failed],
                conclusionActivityID: failed.id,
                terminalState: .failed
            ),
            completedTurn(
                baseSequence: 20,
                activities: [cancelled],
                conclusionActivityID: cancelled.id,
                terminalState: .cancelled
            )
        ])

        let resolved = try target(from: resolve(transcript: transcript))
        XCTAssertEqual(resolved.clientRowID, legacyNil.id)
        XCTAssertEqual(resolved.previewText, "Legacy nil-terminal reply.")
    }

    func testRemoteResolverRequiresAndReturnsHostRowMapping() throws {
        let older = item(kind: .assistant, text: "Older remote reply.", sequenceIndex: 1)
        let answer = item(kind: .assistant, text: "Remote completed reply.", sequenceIndex: 11)
        let transcript = AgentTranscript(turns: [
            completedTurn(baseSequence: 0, activities: [older], conclusionActivityID: older.id),
            completedTurn(baseSequence: 10, activities: [answer], conclusionActivityID: answer.id)
        ])
        let hostRowID = UUID()

        let mapped = resolve(
            transcript: transcript,
            remoteHostRowIDForClientItemID: { $0 == answer.id ? hostRowID : nil }
        )
        let target = try target(from: mapped)
        XCTAssertEqual(target.clientRowID, answer.id)
        XCTAssertEqual(target.hostRowID, hostRowID)

        let olderHostRowID = UUID()
        XCTAssertEqual(
            resolve(
                transcript: transcript,
                remoteHostRowIDForClientItemID: { $0 == older.id ? olderHostRowID : nil }
            ),
            .unavailable(message: "This reply hasn't synced with the host yet.")
        )
    }

    private func resolve(
        runState: AgentSessionRunState = .completed,
        canFork: Bool = true,
        transcript: AgentTranscript,
        legacyItems: [AgentChatItem] = [],
        remoteHostRowIDForClientItemID: ((UUID) -> UUID?)? = nil
    ) -> AgentLastCompletedAssistantReplyHandoffResolution {
        AgentLastCompletedAssistantReplyHandoffCutoffResolver.resolve(
            runState: runState,
            canForkCurrentSession: canFork,
            transcript: transcript,
            legacyItems: legacyItems,
            remoteHostRowIDForClientItemID: remoteHostRowIDForClientItemID
        )
    }

    private func target(
        from resolution: AgentLastCompletedAssistantReplyHandoffResolution
    ) throws -> AgentLastCompletedAssistantReplyHandoffTarget {
        guard case let .target(target) = resolution else {
            XCTFail("Expected a resolved handoff target, got \(resolution)")
            throw ResolverTestError.unexpectedResolution
        }
        return target
    }

    private func completedTurn(
        baseSequence: Int,
        activities: [AgentChatItem],
        conclusionActivityID: UUID?,
        terminalState: AgentSessionRunState? = .completed
    ) -> AgentTranscriptTurn {
        let startedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(baseSequence))
        let user = item(kind: .user, text: "Request", sequenceIndex: baseSequence)
        let transcriptActivities = activities.map { AgentTranscriptActivity(from: $0) }
        return AgentTranscriptTurn(
            id: user.id,
            request: AgentTranscriptRequestAnchor(from: user),
            responseSpans: transcriptActivities.isEmpty ? [] : [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: startedAt,
                    lastActivityAt: transcriptActivities.last?.timestamp,
                    completedAt: transcriptActivities.last?.timestamp ?? startedAt,
                    activities: transcriptActivities
                )
            ],
            conclusionActivityID: conclusionActivityID,
            terminalState: terminalState,
            startedAt: startedAt,
            lastActivityAt: transcriptActivities.last?.timestamp,
            completedAt: transcriptActivities.last?.timestamp ?? startedAt
        )
    }

    private func item(
        kind: AgentChatItemKind,
        text: String,
        sequenceIndex: Int,
        isStreaming: Bool = false
    ) -> AgentChatItem {
        AgentChatItem(
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
            kind: kind,
            text: text,
            sequenceIndex: sequenceIndex,
            isStreaming: isStreaming
        )
    }

    private enum ResolverTestError: Error {
        case unexpectedResolution
    }
}
