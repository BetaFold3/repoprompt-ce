import SwiftUI

struct RemoteHostsSettingsView: View {
    var showFeedback: (String, Bool) -> Void

    @StateObject private var viewModel = RemoteHostsSettingsViewModel()
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var showingDiscovery = false
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
            feedback
            if viewModel.hostRows.isEmpty { emptyState } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.hostRows) { hostRow($0) }
                }
            }
        }
        .onAppear(perform: viewModel.refreshHosts)
        .sheet(isPresented: $showingDiscovery, onDismiss: { viewModel.cancelDiscovery() }) {
            RemoteHostsDiscoverySheet(
                viewModel: viewModel,
                isPresented: $showingDiscovery,
                showFeedback: showFeedback
            )
            .frame(width: 620, height: 560)
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
                set: { if !$0 { forgetDraft = nil } }
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
            Button("Cancel", role: .cancel) { forgetDraft = nil }
        } message: {
            if let draft = forgetDraft {
                Text("This removes the local host record and device key. The host may still list this device until it is revoked there.\n\n\(draft.hostFingerprint)")
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = viewModel.errorMessage {
            Text(error).font(fontPreset.captionFont).foregroundColor(.orange)
        } else if let status = viewModel.statusMessage {
            Text(status).font(fontPreset.captionFont).foregroundColor(.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Remote Hosts").font(fontPreset.subHeadlineBoldFont)
                Text("Find signed RepoPrompt hosts directly on your tailnet, then request access from the host Mac.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
            Spacer()
            Button("Refresh") { viewModel.refreshHosts() }.buttonStyle(CustomButtonStyle())
            Button {
                showingDiscovery = true
                viewModel.findHosts()
            } label: {
                Label("Find Hosts", systemImage: "network")
            }
            .buttonStyle(CustomButtonStyle())
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled").foregroundColor(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("No remote hosts paired.").font(fontPreset.font)
                Text("Tailscale must be installed and running on both Macs. Finding hosts does not grant access; the host user must approve each pairing request.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func hostRow(_ row: RemoteHostsSettingsHostRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let revocation = row.revocationBannerMessage {
                Label(revocation, systemImage: "exclamationmark.triangle.fill")
                    .font(fontPreset.captionFont).foregroundColor(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(row.isRevokedByHost ? Color.orange : Color.secondary.opacity(0.55))
                    .frame(width: 9, height: 9).padding(.top, 5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(row.displayName).font(fontPreset.font)
                        if row.isRevokedByHost {
                            Text("Revoked by host").font(fontPreset.captionFont)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    labeledMonospace("Fingerprint", row.hostFingerprint)
                    labeledMonospace("Device ID", row.deviceID)
                    Text(row.gatewayURLString).font(fontPreset.captionFont).foregroundColor(.secondary).textSelection(.enabled)
                    Text("Granted: \(row.scopeSummary.isEmpty ? "None" : row.scopeSummary)")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                    Text("Paired \(row.pairedAt.formatted(date: .abbreviated, time: .shortened)) · Last connected: \(row.lastConnectedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        Task {
                            if await viewModel.testConnection(id: row.id) {
                                showFeedback(viewModel.statusMessage ?? "Remote host connection succeeded", false)
                            } else if let message = viewModel.errorMessage { showFeedback(message, true) }
                        }
                    } label: {
                        if viewModel.isTestingConnection(hostID: row.id) {
                            HStack(spacing: 5) { ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else { Text("Test Connection") }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .disabled(row.isRevokedByHost || viewModel.isTestingConnection(hostID: row.id))
                    Button("Rename") { renameDraft = .init(id: row.id, displayName: row.displayName) }
                        .buttonStyle(CustomButtonStyle())
                    Button("Forget") {
                        forgetDraft = .init(id: row.id, displayName: row.displayName, hostFingerprint: row.hostFingerprint)
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
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
        }
    }
}

private struct RemoteHostsDiscoverySheet: View {
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
                    Text("Find RepoPrompt Hosts").font(fontPreset.headlineFont)
                    Text("Searches numeric Tailscale peer addresses for signed RepoPrompt discovery responses.")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
                    .disabled(viewModel.pairingState.isPairing)
            }

            discoveryContent
            Spacer()
            HStack {
                Text("Requested scopes: Observe sessions, Operate sessions, Respond to interactions.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                Spacer()
                if viewModel.discoveryState.isSearching {
                    Button("Cancel Search") { viewModel.cancelDiscovery() }.buttonStyle(CustomButtonStyle())
                }
                Button("Search Again") { viewModel.findHosts() }.buttonStyle(CustomButtonStyle())
                    .disabled(viewModel.discoveryState.isSearching || viewModel.pairingState.isPairing)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var discoveryContent: some View {
        switch viewModel.discoveryState {
        case .idle:
            Text("Select Search Again to scan your tailnet.").foregroundColor(.secondary)
        case .searching:
            HStack(spacing: 8) { ProgressView().controlSize(.small)
                Text("Searching your tailnet…")
            }
        case let .noHosts(diagnostics):
            VStack(alignment: .leading, spacing: 6) {
                Label("No signed RepoPrompt hosts found", systemImage: "magnifyingglass")
                Text("Checked \(diagnostics.candidateCount) Tailscale routes. Confirm Tailscale and Remote Control are running on the host.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
        case let .results(diagnostics):
            VStack(alignment: .leading, spacing: 10) {
                Text("Verified \(diagnostics.verifiedCount) of \(diagnostics.candidateCount) candidate routes.")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                ForEach(viewModel.discoveredHosts) { candidateRow($0) }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(fontPreset.captionFont).foregroundColor(.orange)
        }
    }

    private func candidateRow(_ candidate: VerifiedRemoteHostCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.signedHostName).font(fontPreset.font)
                Text("Signed RepoPrompt host · \(candidate.channel.rawValue) · \(candidate.fingerprintShort)")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                Text("Tailnet peer: \(candidate.tailscalePeerName) · \(candidate.tailscaleIPv4)")
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
                Text(candidate.origin.string).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Request Access") {
                Task {
                    await viewModel.requestAccess(to: candidate)
                    switch viewModel.pairingState {
                    case let .paired(hostName):
                        showFeedback("Paired \(hostName)", false)
                        isPresented = false
                    case let .failed(message):
                        showFeedback(message, true)
                    case .idle, .waitingForApproval:
                        break
                    }
                }
            }
            .buttonStyle(CustomButtonStyle())
            .disabled(viewModel.pairingState.isPairing)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
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

    init(draft: RemoteHostsRenameDraft, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _displayName = State(initialValue: draft.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Remote Host").font(fontPreset.headlineFont)
            TextField("Host name", text: $displayName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(displayName) }.keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct RemoteHostsRenameDraft: Identifiable, Equatable { var id: String
    var displayName: String
}

private struct RemoteHostsForgetDraft: Identifiable, Equatable { var id: String
    var displayName: String
    var hostFingerprint: String
}
