import Foundation
import SwiftUI

/// Lossless-restart recovery banner above the composer: the active session's items of the app-wide
/// recovery catalog (held input with View / Edit / Remove, held or unsaved drafts with Restore /
/// Discard (confirmed), unanswered questions, composer save failures, crash holds, interrupted
/// turns, held schedule transfers, and unknown recovery status), with a Needs Attention entry for
/// items elsewhere. Failures stay inline on their row until the action succeeds; nothing shows a
/// permanent "Saving"/"Saved" state.
struct AgentRecoveryListBanner: View {
    let props: AgentRecoveryListProps
    let actions: AgentRecoveryListActions

    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 52
    static let maxVisibleRows = 3

    static func reservedHeight(for props: AgentRecoveryListProps) -> CGFloat {
        let visibleRows = min(max(props.rows.count, 0), maxVisibleRows)
        return headerHeight + CGFloat(visibleRows) * rowHeight + 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !props.rows.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(props.rows) { row in
                            AgentRecoveryListRow(row: row, actions: actions)
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
                .frame(height: CGFloat(min(props.rows.count, Self.maxVisibleRows)) * Self.rowHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityIdentifier("agent.recoveryList.banner")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(headerText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agent.recoveryList.status")
            if props.canRetry {
                Button("Retry") { actions.retryStartup() }
                    .accessibilityIdentifier("agent.recoveryList.retry")
            }
            if props.status == .ready, props.otherItemCount > 0 {
                Button("Needs Attention (\(props.otherItemCount))…") { actions.openNeedsAttention() }
                    .controlSize(.small)
                    .accessibilityIdentifier("agent.recoveryList.needsAttention")
            }
        }
        .frame(minHeight: Self.headerHeight)
    }

    private var headerIcon: String {
        switch props.status {
        case .loading:
            "clock.arrow.circlepath"
        case .ready:
            "exclamationmark.arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private var headerText: String {
        switch props.status {
        case .loading:
            "Checking for work interrupted when RepoPrompt last closed…"
        case .ready:
            props.rows.count == 1
                ? "1 saved or interrupted item needs your attention."
                : "\(props.rows.count) saved or interrupted items need your attention."
        case let .failed(message):
            message
        }
    }
}

/// One recovery row (banner and Needs Attention sheet).
struct AgentRecoveryListRow: View {
    let row: AgentRecoveryListRowProps
    let actions: AgentRecoveryListActions

    @State private var isViewing = false
    @State private var pendingConfirmation: AgentRecoveryListRowProps.Action?
    /// Phase 4: the continuation being edited (its action), and its editable text.
    @State private var editingContinuation: AgentRecoveryListRowProps.Action?
    @State private var continuationDraft = ""
    /// Step 5a: the latest comparison of this row's proposal (transient; recomputed on each View).
    @State private var inspection: (rowID: String, text: String)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text("· \(row.sessionName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(row.error ?? row.detail)
                    .font(.system(size: 10, weight: row.error == nil ? .regular : .semibold))
                    .foregroundStyle(row.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier(row.error == nil ? "agent.recoveryList.detail" : "agent.recoveryList.error")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.isWorking {
                ProgressView().controlSize(.small)
            }
            if row.text != nil || !row.attachmentNames.isEmpty {
                Button("View") { isViewing = true }
                    .popover(isPresented: $isViewing, arrowEdge: .top) { viewer }
                    .accessibilityIdentifier("agent.recoveryList.view")
            }
            ForEach(row.actions, id: \.self) { action in
                Button(title(for: action), role: isDestructive(action) ? .destructive : nil) {
                    if action == .discardDraft || action == .cancelSchedule || action == .discardProposal, row.confirmation != nil {
                        pendingConfirmation = action
                    } else if isContinuation(action), let text = row.continuationText {
                        continuationDraft = text
                        editingContinuation = action
                    } else {
                        Task { await actions.perform(row.id, action) }
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { editingContinuation == action },
                        set: { if !$0 { editingContinuation = nil } }
                    ),
                    arrowEdge: .top
                ) { continuationEditor(for: action) }
                .accessibilityIdentifier("agent.recoveryList.\(action)")
            }
        }
        .controlSize(.small)
        .disabled(row.isWorking)
        .padding(.vertical, 3)
        .confirmationDialog(
            row.confirmation ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingConfirmation == .cancelSchedule ? "Cancel Schedule" : "Discard", role: .destructive) {
                guard let action = pendingConfirmation else { return }
                pendingConfirmation = nil
                Task { await actions.perform(row.id, action) }
            }
            .accessibilityIdentifier("agent.recoveryList.confirmDiscard")
            Button(pendingConfirmation == .cancelSchedule ? "Keep" : "Cancel", role: .cancel) { pendingConfirmation = nil }
        }
    }

    private func isContinuation(_ action: AgentRecoveryListRowProps.Action) -> Bool {
        action == .continueTurn || action == .continueInNewConversation
    }

    /// Editable continuation shown before the choice; Send reserves exactly this text.
    private func continuationEditor(for action: AgentRecoveryListRowProps.Action) -> some View {
        let warning = row.continuationWarning
        return VStack(alignment: .leading, spacing: 8) {
            Text(title(for: action)).font(.headline)
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.recoveryList.continuationWarning")
            }
            TextEditor(text: $continuationDraft)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 160)
                .accessibilityIdentifier("agent.recoveryList.continuationText")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingContinuation = nil }
                Button(warning == nil ? "Send" : "Send anyway") {
                    let text = continuationDraft
                    editingContinuation = nil
                    Task { await actions.performContinuation(row.id, action, text, warning) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(continuationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("agent.recoveryList.continuationSend")
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func isDestructive(_ action: AgentRecoveryListRowProps.Action) -> Bool {
        action == .remove || action == .discardDraft || action == .cancelSchedule || action == .discardProposal
    }

    private var viewer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title).font(.headline)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
            if row.inspectsOnView {
                Text(inspection?.rowID == row.id ? inspection?.text ?? "" : "Comparing with the current file…")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.recoveryList.inspection")
            }
            if let text = row.text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            if !row.attachmentNames.isEmpty {
                Text("Attachments: \(row.attachmentNames.joined(separator: ", "))")
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 360)
        .task(id: row.id) {
            // Never show an earlier View's comparison while this one is computed.
            inspection = nil
            guard row.inspectsOnView else { return }
            let rowID = row.id
            let text = await actions.inspect(rowID) ?? "The current file couldn't be compared."
            guard !Task.isCancelled, rowID == row.id else { return }
            inspection = (rowID, text)
        }
    }

    private func title(for action: AgentRecoveryListRowProps.Action) -> String {
        switch action {
        case .edit:
            "Edit"
        case .remove:
            "Remove"
        case .open:
            "Open"
        case .confirmStopped:
            "It stopped"
        case .dismiss:
            "Dismiss"
        case .removeSavedQuestion:
            "Remove saved question"
        case .restoreDraft:
            "Restore"
        case .discardDraft:
            "Discard…"
        case .retrySave:
            "Retry save"
        case .cancelSchedule:
            "Cancel pending schedule…"
        case .refreshProcesses:
            "Refresh"
        case .letProcessFinish:
            "Let it finish"
        case .continueTurn:
            "Continue…"
        case .sendSaved:
            "Send"
        case .answerAsInput:
            "Send answer as message"
        case .reconcileHistory:
            "Check provider history"
        case .continueInNewConversation:
            "Continue in a new conversation…"
        case let .openDelegatedSession(childSessionID):
            "Open delegated session \(childSessionID.uuidString.prefix(8))"
        case .copyProposal:
            "Copy proposal"
        case .discardProposal:
            "Discard proposal…"
        }
    }
}
