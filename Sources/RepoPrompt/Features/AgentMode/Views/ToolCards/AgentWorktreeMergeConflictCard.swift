import RepoPromptUI
import SwiftUI

// MARK: - Worktree Merge Conflict Card

//
// Shown in the Agent Mode blocker stack while an `AgentSessionWorktreeMergeOperation`
// is in `.conflicted` or `.awaitingCommit` state and no higher-priority blocker
// (apply-edits review, merge review, generic approval, MCP elicitation, user input,
// ask_user) is active. Persists across relaunch because the operation is
// session-persisted (see `AgentSessionWorktreeMergeOperation`).
//
// SEARCH-HELPER: worktree merge conflict card, AgentWorktreeMergeConflictCard,
// merge continue / abort blocker.
struct AgentWorktreeMergeConflictCard: View {
    let operation: AgentSessionWorktreeMergeOperation
    let onContinue: () -> Void
    let onAbort: () -> Void

    private var statusLabel: String {
        switch operation.status {
        case .conflicted:
            "Conflicts in target worktree"
        case .awaitingCommit:
            "Awaiting commit"
        default:
            "Merge in progress"
        }
    }

    private var statusTint: Color {
        switch operation.status {
        case .conflicted: .orange
        case .awaitingCommit: .yellow
        default: .secondary
        }
    }

    private var headerIcon: String {
        operation.status == .conflicted
            ? "exclamationmark.triangle.fill"
            : "arrow.triangle.merge"
    }

    private var conflictFiles: [String] {
        operation.conflictFiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            targetRow

            if let visualization = operation.visualization, !visualization.isEmpty {
                visualizationBlock(visualization)
            }

            if operation.status == .conflicted {
                conflictBlock
            } else if operation.status == .awaitingCommit {
                awaitingCommitBlock
            }

            if let lastError = operation.lastError,
               !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(role: .destructive, action: onAbort) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Abort merge")
                    }
                }
                .buttonStyle(.bordered)
                .hoverTooltip("Abort merge — discards in-progress merge in the target worktree")

                Spacer()

                Button(action: onContinue) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("Continue after resolving")
                        Text("⌘⏎")
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .hoverTooltip("Commit merge after resolving conflicts (⌘⏎)")
            }
        }
        .padding(12)
        .background(statusTint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusTint.opacity(0.32), lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .foregroundColor(statusTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.headline)
                Text("Operation \(operation.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    // MARK: Target row

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("TARGET")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.85))
                Text(operation.target.displayName)
                    .font(.system(size: 12, weight: .medium))
                if let branch = operation.target.branch, !branch.isEmpty {
                    Text("· \(branch)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(operation.target.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .hoverTooltip(operation.target.path, .top)
        }
    }

    // MARK: Visualization

    private func visualizationBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
        }
        .frame(maxHeight: 80)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Conflicted body

    private var conflictBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(conflictFiles.count) conflicted file\(conflictFiles.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            if conflictFiles.isEmpty {
                Text("Inspect target worktree for conflicts (cd \(operation.target.path) && git status --short).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                conflictFileList
            }
            Text("Resolve conflicts in the target worktree, then continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conflictFileList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(conflictFiles, id: \.self) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .hoverTooltip(file, .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 110)
        .padding(6)
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Awaiting-commit body

    private var awaitingCommitBlock: some View {
        Text("No conflicts remain. Click Continue to create the merge commit in the target worktree.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
