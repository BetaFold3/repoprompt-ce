import SwiftUI

struct RemoteControlSettingsView: View {
    var showFeedback: (String, Bool) -> Void

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @ObservedObject private var gatewayStatus = RemoteGatewayStatusStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var hostFingerprint = ""
    @State private var pairedDevices: [PairedDeviceRecord] = []
    @State private var storeError: String?

    private let buildIdentity = RemoteControlBuildIdentity.current
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var remoteGatewayEnabledBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpRemoteGatewayEnabled() },
            set: { enabled in
                globalSettings.setMCPRemoteGatewayEnabled(enabled)
                Task { await ServerController.shared.applyRemoteGatewaySettings() }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            gatewaySection
            Divider()
            identitySection
            Divider()
            devicesSection
        }
        .onAppear(perform: refreshAll)
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Control").font(fontPreset.font)
                    Text("Advertise this Mac as a signed RepoPrompt host directly on its Tailscale IPv4 address.")
                        .font(fontPreset.captionFont).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: remoteGatewayEnabledBinding)
                    .toggleStyle(SwitchToggleStyle())
                    .hoverTooltip("Start the packaged gateway on the current Tailscale address")
            }

            HStack(spacing: 16) {
                labeledValue("Build channel", buildIdentity.channel.rawValue.capitalized)
                labeledValue("Fixed port", String(buildIdentity.fixedPort))
                labeledValue("Status", gatewayStatus.status.summary)
            }
            if let origin = gatewayStatus.status.origin {
                labeledMonospace("Tailnet origin", origin.string)
            }
            Text("Tailscale must be installed, signed in, and running. Remote Control never falls back to loopback, LAN, or wildcard binding.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Status") {
                    Task { await ServerController.shared.applyRemoteGatewaySettings() }
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(!globalSettings.mcpRemoteGatewayEnabled())
                Spacer()
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed host identity").font(fontPreset.font)
            Text("Clients verify this app-owned key before showing a host or requesting access.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
            if let storeError {
                Text(storeError).font(fontPreset.captionFont).foregroundColor(.red)
            }
            labeledMonospace("Host fingerprint", hostFingerprint.isEmpty ? "Unavailable" : hostFingerprint)
            Text("Pairing requests are approved in the host app and are bound to a short-lived, single-use discovery context. No pairing payload or editable endpoint is required.")
                .font(fontPreset.captionFont).foregroundColor(.secondary)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Paired devices").font(fontPreset.font)
                Spacer()
                Button("Refresh") { refreshDevices() }.buttonStyle(CustomButtonStyle())
            }
            if pairedDevices.isEmpty {
                Text("No paired devices yet.").font(fontPreset.captionFont).foregroundColor(.secondary)
            } else {
                ForEach(pairedDevices) { deviceRow($0) }
            }
        }
    }

    private func deviceRow(_ device: PairedDeviceRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                .foregroundColor(device.isRevoked ? .secondary : .accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName).font(fontPreset.font)
                    if device.isRevoked {
                        Text("Revoked").font(fontPreset.captionFont)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(device.id).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Text(device.scopes.sorted().map(\.rawValue).joined(separator: ", "))
                    .font(fontPreset.captionFont).foregroundColor(.secondary)
            }
            Spacer()
            Button("Revoke") { revoke(device) }.buttonStyle(CustomButtonStyle()).disabled(device.isRevoked)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(value).font(fontPreset.captionFont)
        }
    }

    private func labeledMonospace(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(fontPreset.captionFont).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func refreshAll() {
        refreshHostIdentity()
        refreshDevices()
    }

    private func refreshHostIdentity() {
        do {
            hostFingerprint = try RemotePairingIdentityStore.shared.hostPublicKeyInfo().fingerprint
            storeError = nil
        } catch {
            hostFingerprint = ""
            storeError = "Remote pairing host key unavailable: \(error.localizedDescription)"
        }
    }

    private func refreshDevices() {
        do {
            pairedDevices = try RemotePairingIdentityStore.shared.listDevices(includeRevoked: true)
            storeError = nil
        } catch {
            pairedDevices = []
            storeError = "Remote pairing store unavailable: \(error.localizedDescription)"
        }
    }

    private func revoke(_ device: PairedDeviceRecord) {
        do {
            _ = try RemotePairingIdentityStore.shared.revokeDevice(id: device.id)
            refreshDevices()
            showFeedback("Revoked \(device.displayName)", false)
        } catch {
            showFeedback("Failed to revoke device: \(error.localizedDescription)", true)
        }
    }
}
