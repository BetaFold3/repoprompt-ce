import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

/// Ultra-lightweight, non-expandable summary card for a group of compressed tool/thinking items.
/// Shows tool count with categorized tool type chips in a single compact row.
struct CompressedToolGroupCard: View {
    let toolCallCount: Int
    let toolNames: [String]

    @Environment(\.colorScheme) private var colorScheme

    private var groups: [ClusterToolGroup] {
        ClusterToolCategory.buildGroups(toolNames: toolNames, counts: [:])
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))

            Text("\(toolCallCount) tool\(toolCallCount == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            if !groups.isEmpty {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index == 0 {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: group.icon)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(group.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    if index < groups.count - 1 {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.3))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(BubbleColors.toolResultBackground(colorScheme: colorScheme))
        .cornerRadius(8)
    }
}
