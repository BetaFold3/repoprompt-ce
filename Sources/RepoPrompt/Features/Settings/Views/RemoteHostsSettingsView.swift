import SwiftUI

struct RemoteHostsSettingsView: View {
    var showFeedback: (String, Bool) -> Void

    @StateObject private var viewModel = RemoteHostsSettingsViewModel()
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var showingPairingSheet = false
    @State private var renameDraft: RemoteHostsRenameDraft?
    @State private var forgetDraft: RemoteHostsForgetDraft?

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(showFeedback: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.showFeedback = showFeedback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = viewModel.statusMessage {
                Text(status)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.hostRows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.hostRows) { row in
                        hostRow(row)
                    }
                }
            }
        }
        .onAppear(perform: viewModel.refreshHosts)
        .sheet(isPresented: $showingPairingSheet) {
            RemoteHostsPairingSheet(
                viewModel: viewModel,
                isPresented: $showingPairingSheet,
                showFeedback: showFeedback
            )
            .frame(width: 560, height: 560)
        }
        .sheet(item: $renameDraft) { draft in
            RemoteHostsRenameSheet(
                draft: draft,
                onCancel: { renameDraft = nil },
                onSave: { newName in
                    if viewModel.renameHost(id: draft.id, displayName: newName) {
                        showFeedback("Renamed remote host", false)
                        renameDraft = nil
                    } else if let message = viewModel.errorMessage {
                        showFeedback(message, true)
                    }
                }
            )
            .frame(width: 360)
        }
        .confirmationDialog(
            "Forget Remote Host?",
            isPresented: Binding(
                get: { forgetDraft != nil },
                set: { isPresented in
                    if !isPresented { forgetDraft = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget \(forgetDraft?.displayName ?? "Remote Host")", role: .destructive) {
                guard let draft = forgetDraft else { return }
                Task { @MainActor in
                    if await viewModel.forgetHost(id: draft.id) {
                        showFeedback(viewModel.statusMessage ?? "Forgot remote host", false)
                    } else if let message = viewModel.errorMessage {
                        showFeedback(message, true)
                    }
                    forgetDraft = nil
                }
            }
            Button("Cancel", role: .cancel) {
                forgetDraft = nil
            }
        } message: {
            if let draft = forgetDraft {
                Text("This removes the local host record and device key. The host may still list this device until it is revoked from that host's Remote Control settings.\n\n\(draft.hostFingerprint)")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Remote Hosts")
                    .font(fontPreset.subHeadlineBoldFont)
                Text("Pair this Mac as a remote client of another RepoPrompt host. Remote Agent Mode execution UI is deferred to later milestones.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Refresh") { viewModel.refreshHosts() }
                    .buttonStyle(CustomButtonStyle())
                Button {
                    viewModel.resetPairing()
                    showingPairingSheet = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .buttonStyle(CustomButtonStyle())
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .foregroundColor(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("No remote hosts paired.")
                    .font(fontPreset.font)
                Text("Local Agent Mode behavior is unchanged until a host is paired. Pairing only stores trust records; it does not start a connection manager or background network activity.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func hostRow(_ row: RemoteHostsSettingsHostRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let revocation = row.revocationBannerMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(revocation)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(row.isRevokedByHost ? Color.orange : Color.secondary.opacity(0.55))
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .font(fontPreset.font)
                        if row.isRevokedByHost {
                            Text("Revoked by host")
                                .font(fontPreset.captionFont)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                    }

                    labeledMonospace("Fingerprint", row.hostFingerprint)
                    labeledMonospace("Device ID", row.deviceID)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gateway")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                        Text(row.gatewayURLString)
                            .font(fontPreset.captionFont)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Granted scopes")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                        Text(row.scopeSummary.isEmpty ? "None" : row.scopeSummary)
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Paired \(row.pairedAt.formatted(date: .abbreviated, time: .shortened)) · Last connected: \(row.lastConnectedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        Task {
                            let success = await viewModel.testConnection(id: row.id)
                            if success {
                                showFeedback(viewModel.statusMessage ?? "Remote host connection succeeded", false)
                            } else if let message = viewModel.errorMessage {
                                showFeedback(message, true)
                            }
                        }
                    } label: {
                        if viewModel.isTestingConnection(hostID: row.id) {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .disabled(row.isRevokedByHost || viewModel.isTestingConnection(hostID: row.id))
                    .hoverTooltip("Mint a one-time ticket, open a signed WebSocket, ping the host, then disconnect.")
                    Button("Rename") {
                        renameDraft = RemoteHostsRenameDraft(id: row.id, displayName: row.displayName)
                    }
                    .buttonStyle(CustomButtonStyle())
                    Button("Forget") {
                        forgetDraft = RemoteHostsForgetDraft(
                            id: row.id,
                            displayName: row.displayName,
                            hostFingerprint: row.hostFingerprint
                        )
                    }
                    .buttonStyle(CustomButtonStyle())
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeledMonospace(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct RemoteHostsPairingSheet: View {
    @ObservedObject var viewModel: RemoteHostsSettingsViewModel
    @Binding var isPresented: Bool
    var showFeedback: (String, Bool) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Remote Host")
                        .font(fontPreset.headlineFont)
                    Text("Paste the pairing payload JSON from the host's Settings → MCP Server → Remote Control section.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.pairingState.isPairing)
            }

            TextEditor(text: $viewModel.pairingPayloadText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: viewModel.pairingPayloadText) { _, _ in
                    viewModel.parsePairingPayloadText()
                }

            if let preview = viewModel.pairingPreview {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Pinned host: \(preview.displayName)")
                            .font(fontPreset.font)
                    }
                    labeledMonospace("Host fingerprint", preview.hostFingerprint)
                    TextField("Gateway URL", text: $viewModel.gatewayURLString)
                        .textFieldStyle(.roundedBorder)
                    Text("Edit the URL before pairing if the host advertised a loopback or LAN address; for Tailscale, use the MagicDNS host name.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            stateMessage

            Spacer()

            HStack {
                Text("Requested scopes: Observe sessions, Operate sessions, Respond to interactions.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Pair") {
                    Task {
                        await viewModel.pairCurrentPayload()
                        switch viewModel.pairingState {
                        case let .paired(hostName):
                            showFeedback("Paired \(hostName)", false)
                            isPresented = false
                        case let .failed(message):
                            showFeedback(message, true)
                        case .idle, .ready, .waitingForApproval:
                            break
                        }
                    }
                }
                .buttonStyle(CustomButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canPair)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var stateMessage: some View {
        switch viewModel.pairingState {
        case .idle, .ready:
            EmptyView()
        case let .waitingForApproval(hostName):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for approval on \(hostName)…")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        case let .paired(hostName):
            Label("Paired \(hostName)", systemImage: "checkmark.circle.fill")
                .font(fontPreset.captionFont)
                .foregroundColor(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(fontPreset.captionFont)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledMonospace(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct RemoteHostsRenameSheet: View {
    var draft: RemoteHostsRenameDraft
    var onCancel: () -> Void
    var onSave: (String) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var displayName: String

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(
        draft: RemoteHostsRenameDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _displayName = State(initialValue: draft.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Remote Host")
                .font(fontPreset.headlineFont)
            TextField("Host name", text: $displayName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(displayName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct RemoteHostsRenameDraft: Identifiable, Equatable {
    var id: String
    var displayName: String
}

private struct RemoteHostsForgetDraft: Identifiable, Equatable {
    var id: String
    var displayName: String
    var hostFingerprint: String
}
