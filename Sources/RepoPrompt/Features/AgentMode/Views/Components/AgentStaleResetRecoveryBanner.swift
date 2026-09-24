import Foundation
import SwiftUI

/// Notice above the composer while a tab retains a local conversation that cannot be saved
/// because the conversation was reset in another window (stale-reset recovery). The retained
/// view stays visible and copyable; only the explicitly confirmed "Reload latest…" replaces it.
struct AgentStaleResetRecoveryBanner: View {
    let props: AgentStaleResetRecoveryProps
    let actions: AgentStaleResetRecoveryActions

    @State private var isConfirmingReload = false
    @State private var actionError: String?
    @State private var isActionInFlight = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                if let detail = props.problem ?? actionError, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .accessibilityIdentifier("agent.staleResetRecovery.problem")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if props.canRetryStop {
                Button("Retry stopping") {
                    perform { await actions.retryStopping(props.tabID, props.recoveryID) }
                }
                .accessibilityIdentifier("agent.staleResetRecovery.retryStopping")
            }
            if props.canReload {
                Button("Reload latest…") {
                    isConfirmingReload = true
                }
                .accessibilityIdentifier("agent.staleResetRecovery.reloadLatest")
                .confirmationDialog(
                    "Replace the local conversation?",
                    isPresented: $isConfirmingReload,
                    titleVisibility: .visible
                ) {
                    Button("Reload and discard the local conversation", role: .destructive) {
                        perform { await actions.reloadLatest(props.tabID, props.recoveryID) }
                    }
                    Button("Keep local view", role: .cancel) {}
                } message: {
                    Text("This conversation was reset in another window. Reloading replaces everything shown here with the saved version. Your unsent draft and attachments are kept.")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .disabled(isActionInFlight)
        .accessibilityIdentifier("agent.staleResetRecovery.banner")
        .onChange(of: props) { _, _ in
            actionError = nil
        }
    }

    private var statusIcon: String {
        switch props.status {
        case .stopping:
            "stop.circle"
        case .retained:
            "exclamationmark.arrow.triangle.2.circlepath"
        case .reloading:
            "arrow.triangle.2.circlepath"
        }
    }

    private var statusText: String {
        switch props.status {
        case .stopping:
            "This conversation was reset in another window. Stopping the current run; the local view is kept but can't be saved."
        case .retained:
            "This conversation was reset in another window. The local view is kept but can't be saved until you reload the latest version."
        case .reloading:
            "Reloading the latest saved conversation…"
        }
    }

    private func perform(_ action: @escaping () async -> String?) {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let message = await action()
            actionError = message
            isActionInFlight = false
        }
    }
}
