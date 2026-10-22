import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

/// App-wide Needs Attention sheet (lossless restart Phase 2): renders the recovery coordinator's
/// catalog snapshot itself, in snapshot order, with the same rows and actions as the composer
/// banner. Dismissed items are hidden unless "Show dismissed" is on. Presented by each window's
/// root host (`AgentRecoveryNeedsAttentionHost`) from the View menu, the banner, or the sidebar,
/// independent of the sidebar and of any tab. Opening a row never starts a provider.
struct AgentRecoveryNeedsAttentionSheet: View {
    let agentModeVM: AgentModeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDismissed = false
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let rows = agentModeVM.recoveryNeedsAttentionRows(
            includeDismissed: showDismissed,
            activeSession: agentModeVM.activeSession
        )
        let actions = AgentRecoveryListActions(
            perform: { rowID, action in
                await agentModeVM.performRecoveryListAction(rowID: rowID, action: action)
            },
            retryStartup: { agentModeVM.retryRecoveryStartup() }
        )
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Needs Attention")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Show dismissed", isOn: $showDismissed)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("agent.recoveryNeedsAttention.showDismissed")
                Button("Done") { dismiss() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty {
                        Text("Nothing needs your attention.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(rows) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = Self.label(for: entry) {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            AgentRecoveryListRow(row: entry.row, actions: actions)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(entry.isDismissed ? 0.04 : 0.10))
                        )
                        .opacity(entry.isDismissed ? 0.7 : 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 400)
        .accessibilityIdentifier("agent.recoveryNeedsAttention.sheet")
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCatalogDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
    }
}

extension AgentRecoveryNeedsAttentionSheet {
    static func label(for entry: AgentRecoveryNeedsAttentionRow) -> String? {
        var parts: [String] = []
        if entry.isDismissed { parts.append("Dismissed") }
        if entry.isOtherWorkspace { parts.append("Another workspace") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Window-root host of the Needs Attention sheet: presents it once per pending request of this
/// window's view model (View menu, banner, or sidebar), including a request made while the window
/// was still appearing. Independent of the session sidebar and of any tab.
struct AgentRecoveryNeedsAttentionHost: ViewModifier {
    let agentModeVM: AgentModeViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AgentRecoveryNeedsAttentionSheet(agentModeVM: agentModeVM)
            }
            .onAppear(perform: consumeRequest)
            .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryNeedsAttentionRequested)) { notification in
                guard (notification.object as AnyObject?) === agentModeVM else { return }
                consumeRequest()
            }
    }

    private func consumeRequest() {
        if agentModeVM.consumeRecoveryNeedsAttentionRequest() {
            isPresented = true
        }
    }
}

/// Sidebar shortcut to the Needs Attention sheet; shown while any recovery item is undismissed (the
/// View menu's command is always available).
struct AgentRecoveryNeedsAttentionSidebarButton: View {
    let agentModeVM: AgentModeViewModel
    let hitSize: CGFloat
    let open: () -> Void
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let count = agentModeVM.recoveryNeedsAttentionCount
        Group {
            if count > 0 {
                Button(action: open) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: hitSize, height: hitSize)
                        Text(count > 99 ? "99+" : String(count))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Needs Attention")
                .accessibilityLabel("Needs Attention, \(count)")
                .accessibilityIdentifier("agent.recoveryNeedsAttention.sidebarButton")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCatalogDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCoordinatorDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
    }
}
