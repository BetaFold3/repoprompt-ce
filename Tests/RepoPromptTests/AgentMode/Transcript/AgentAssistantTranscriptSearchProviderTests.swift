import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentAssistantTranscriptSearchProviderTests: XCTestCase {
    func testOnlyCompletedAssistantMessagesInDirectlyRenderedBlocksAreSearchable() {
        let user = item(kind: .user, text: "question about needle", sequenceIndex: 0)
        let assistant = item(kind: .assistant, text: "the needle is here", sequenceIndex: 1)
        let inline = item(kind: .assistantInline, text: "needle continued", sequenceIndex: 2)
        let streaming = item(kind: .assistant, text: "needle streaming", sequenceIndex: 3, isStreaming: true)
        let toolResult = item(kind: .toolResult, text: "needle in tool output", sequenceIndex: 4, toolName: "read_file")

        let block = AgentTranscriptRenderBlock(
            id: "block-1",
            kind: .standaloneAssistant,
            turnID: UUID(),
            retentionTier: .full,
            rows: [user, assistant, inline, streaming, toolResult],
            isArchived: false
        )

        let entries = AgentAssistantTranscriptSearchProvider().searchEntries(in: [block])

        XCTAssertEqual(entries.map(\.id), [assistant.id, inline.id])
    }

    func testActivityClusterAndGroupedHistoryRowsAreExcluded() {
        let hiddenAssistant = item(kind: .assistant, text: "needle inside cluster", sequenceIndex: 0)
        let clusterBlock = AgentTranscriptRenderBlock(
            id: "cluster-1",
            kind: .activityCluster,
            turnID: UUID(),
            retentionTier: .full,
            rows: [hiddenAssistant],
            isArchived: false
        )

        let groupedAssistant = item(kind: .assistant, text: "needle inside grouped history", sequenceIndex: 1)
        let groupedChildBlock = AgentTranscriptRenderBlock(
            id: "grouped-child-1",
            kind: .standaloneAssistant,
            turnID: UUID(),
            retentionTier: .condensed,
            rows: [groupedAssistant],
            isArchived: false
        )
        let groupedHistoryBlock = AgentTranscriptRenderBlock(
            id: "grouped-1",
            kind: .groupedHistory,
            turnID: UUID(),
            retentionTier: .condensed,
            rows: [],
            isArchived: false,
            groupedHistory: AgentTranscriptGroupedHistory(
                summary: AgentTranscriptGroupedHistorySummary(
                    hiddenToolCardCount: 0,
                    hiddenAssistantCount: 1,
                    hiddenProgressCount: 0,
                    hiddenNoteCount: 0,
                    toolSummary: nil
                ),
                sections: [
                    AgentTranscriptGroupedSection(
                        id: "section-1",
                        kind: .assistant,
                        childBlocks: [groupedChildBlock]
                    )
                ]
            )
        )

        let collapsedRangeBlock = AgentTranscriptRenderBlock(
            id: "range-1",
            kind: .collapsedHistoryRange,
            turnID: UUID(),
            retentionTier: .archived,
            rows: [],
            isArchived: true,
            collapsedHistoryRange: AgentTranscriptCollapsedHistoryRange(hiddenTurnCount: 3)
        )

        let entries = AgentAssistantTranscriptSearchProvider().searchEntries(
            in: [clusterBlock, groupedHistoryBlock, collapsedRangeBlock]
        )

        XCTAssertTrue(
            entries.isEmpty,
            "assistant text nested inside a collapsed cluster/grouped-history block is out of scope for v1 search"
        )
    }

    func testEntriesAreOrderedBySequenceIndexAcrossBlocksRegardlessOfBlockOrder() {
        let second = item(kind: .assistant, text: "second", sequenceIndex: 5)
        let first = item(kind: .assistant, text: "first", sequenceIndex: 1)
        let blockA = AgentTranscriptRenderBlock(
            id: "a",
            kind: .standaloneAssistant,
            turnID: UUID(),
            retentionTier: .full,
            rows: [second],
            isArchived: false
        )
        let blockB = AgentTranscriptRenderBlock(
            id: "b",
            kind: .standaloneAssistant,
            turnID: UUID(),
            retentionTier: .full,
            rows: [first],
            isArchived: false
        )

        let entries = AgentAssistantTranscriptSearchProvider().searchEntries(in: [blockA, blockB])

        XCTAssertEqual(entries.map(\.id), [first.id, second.id])
    }

    private func item(
        kind: AgentChatItemKind,
        text: String,
        sequenceIndex: Int,
        isStreaming: Bool = false,
        toolName: String? = nil
    ) -> AgentChatItem {
        AgentChatItem(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            kind: kind,
            text: text,
            toolName: toolName,
            sequenceIndex: sequenceIndex,
            isStreaming: isStreaming
        )
    }
}
