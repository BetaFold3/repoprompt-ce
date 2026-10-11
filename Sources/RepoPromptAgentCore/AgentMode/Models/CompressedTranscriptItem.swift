import Foundation

// MARK: - Compressed Transcript Item

/// Wraps either a single `AgentChatItem` or a group of consecutive tool/thinking items
/// for lightweight history rendering.
enum CompressedTranscriptItem: Identifiable, Equatable {
    case single(AgentChatItem)
    case toolGroup(ToolCallGroup)

    private static let maxToolNamesPerGroup = 4

    var id: String {
        switch self {
        case let .single(item):
            item.id.uuidString
        case let .toolGroup(group):
            "group-\(group.id)"
        }
    }
}

// MARK: - Tool Call Group

/// A compressed summary of consecutive tool/thinking items.
/// Stores only the count and unique tool names (for icon display), not the items themselves.
struct ToolCallGroup: Identifiable, Equatable {
    let id: String
    let toolCallCount: Int
    /// Unique tool names in order of first appearance (max 4 for icon display).
    let toolNames: [String]
}

// MARK: - Compression Logic

extension CompressedTranscriptItem {
    /// Compress a flat transcript into a mixed array of single items and tool groups.
    /// Consecutive runs of `.toolCall`, `.toolResult`, and `.thinking` items are merged
    /// into a single `.toolGroup`. All other item kinds act as group boundaries.
    static func compress(_ items: some Collection<AgentChatItem>) -> [CompressedTranscriptItem] {
        guard !items.isEmpty else { return [] }

        var result: [CompressedTranscriptItem] = []
        result.reserveCapacity(items.count)
        var groupStartID: String?
        var toolCallCount = 0
        var toolResultCount = 0
        var seenToolNames = Set<String>()
        var orderedToolNames: [String] = []
        orderedToolNames.reserveCapacity(Self.maxToolNamesPerGroup)

        func flushGroup() {
            guard let startID = groupStartID else { return }
            let count = toolCallCount > 0 ? toolCallCount : toolResultCount
            if count > 0 {
                result.append(.toolGroup(ToolCallGroup(
                    id: startID,
                    toolCallCount: count,
                    toolNames: orderedToolNames
                )))
            }
            groupStartID = nil
            toolCallCount = 0
            toolResultCount = 0
            seenToolNames.removeAll(keepingCapacity: true)
            orderedToolNames.removeAll(keepingCapacity: true)
        }

        for item in items {
            switch item.kind {
            case .toolCall, .toolResult, .thinking:
                if groupStartID == nil {
                    groupStartID = item.id.uuidString
                }
                if item.kind == .toolCall {
                    toolCallCount += 1
                } else if item.kind == .toolResult {
                    toolResultCount += 1
                }
                if orderedToolNames.count < Self.maxToolNamesPerGroup,
                   let name = item.toolName,
                   !name.isEmpty,
                   seenToolNames.insert(name).inserted
                {
                    orderedToolNames.append(name)
                }
            case .user, .assistant, .assistantInline, .system, .error:
                flushGroup()
                result.append(.single(item))
            }
        }
        flushGroup()

        return result
    }

    /// Cheap structural comparison used for UI update checks.
    /// - Note: `.single` items compare by stable ID only because history singles are immutable.
    static func hasRenderableDifference(_ lhs: [CompressedTranscriptItem], _ rhs: [CompressedTranscriptItem]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        for (left, right) in zip(lhs, rhs) {
            switch (left, right) {
            case let (.single(leftItem), .single(rightItem)):
                if leftItem.id != rightItem.id {
                    return true
                }
            case let (.toolGroup(leftGroup), .toolGroup(rightGroup)):
                if leftGroup.id != rightGroup.id ||
                    leftGroup.toolCallCount != rightGroup.toolCallCount ||
                    leftGroup.toolNames != rightGroup.toolNames
                {
                    return true
                }
            default:
                return true
            }
        }
        return false
    }
}
