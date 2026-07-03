import AppKit
import CoreImage
import SwiftUI

enum RemoteControlPairingPayloadBuilder {
    static func defaultHostName() -> String {
        let candidates = [
            Host.current().localizedName,
            Host.current().name,
            ProcessInfo.processInfo.hostName
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return "RepoPrompt Host"
    }

    static func payload(
        windowID: Int,
        gatewayURL: String,
        hostPublicKey: String,
        hostFingerprint: String,
        hostName: String = defaultHostName()
    ) -> String {
        let object: [String: Any] = [
            "v": 1,
            "kind": "repoprompt_remote_pairing",
            "window_id": windowID,
            "gateway_url": gatewayURL,
            "host_public_key": hostPublicKey,
            "host_fingerprint": hostFingerprint,
            "host_name": hostName
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }
}

struct RemoteControlSettingsView: View {
    let windowID: Int
    var showFeedback: (String, Bool) -> Void

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared

    @State private var remoteGatewayToken = ""
    @State private var hostPublicKey = ""
    @State private var hostFingerprint = ""
    @State private var pairedDevices: [PairedDeviceRecord] = []
    @State private var storeError: String?

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

    private var remoteGatewayBindAddressBinding: Binding<String> {
        Binding(
            get: { globalSettings.mcpRemoteGatewayBindAddress() },
            set: { address in
                globalSettings.setMCPRemoteGatewayBindAddress(address)
                Task { await ServerController.shared.applyRemoteGatewaySettings() }
            }
        )
    }

    private var remoteGatewayPortBinding: Binding<Int> {
        Binding(
            get: { globalSettings.mcpRemoteGatewayPort() },
            set: { port in
                globalSettings.setMCPRemoteGatewayPort(port)
                Task { await ServerController.shared.applyRemoteGatewaySettings() }
            }
        )
    }

    private var showPairingDetailsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.remoteControlShowPairingDetails() },
            set: { globalSettings.setRemoteControlShowPairingDetails($0) }
        )
    }

    private var pairingPayload: String {
        RemoteControlPairingPayloadBuilder.payload(
            windowID: windowID,
            gatewayURL: "https://\(globalSettings.mcpRemoteGatewayBindAddress()):\(globalSettings.mcpRemoteGatewayPort())",
            hostPublicKey: hostPublicKey,
            hostFingerprint: hostFingerprint
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            gatewaySection
            Divider()
            pairingSection
            Divider()
            devicesSection
        }
        .onAppear(perform: refreshAll)
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Control")
                        .font(fontPreset.font)
                    Text("Gateway process, app-owned pairing authority, and paired device trust records.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: remoteGatewayEnabledBinding)
                    .toggleStyle(SwitchToggleStyle())
                    .hoverTooltip("Start the packaged repoprompt-gateway helper")
            }

            HStack(spacing: 8) {
                TextField("Bind address", text: remoteGatewayBindAddressBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(!globalSettings.mcpRemoteGatewayEnabled())
                    .hoverTooltip("Defaults to 127.0.0.1. Non-loopback binding is developer-only unless paired-device auth is enforced.")

                TextField("Port", value: remoteGatewayPortBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 82)
                    .disabled(!globalSettings.mcpRemoteGatewayEnabled())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Phase 0 static token")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ReadOnlyInputBox(text: remoteGatewayToken, placeholder: "Token unavailable", minHeight: 30)
                    Button("Copy") {
                        copyToPasteboard(remoteGatewayToken)
                        showFeedback("Remote gateway token copied", false)
                    }
                    .buttonStyle(CustomButtonStyle())
                    .disabled(remoteGatewayToken.isEmpty)

                    Button("Regenerate") {
                        regenerateRemoteGatewayToken()
                    }
                    .buttonStyle(CustomButtonStyle())
                }
                Text("Temporary static-token auth remains for Phase 0 compatibility. Paired-device records are stored only in the validated RemoteControl trust file.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair a device")
                        .font(fontPreset.font)
                    Text("Show this host fingerprint and QR payload to the gateway/PWA pairing flow.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Details", isOn: showPairingDetailsBinding)
                    .toggleStyle(.switch)
            }

            if let storeError {
                Text(storeError)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.red)
            }

            labeledMonospace("Host fingerprint", hostFingerprint.isEmpty ? "Unavailable" : hostFingerprint)

            if globalSettings.remoteControlShowPairingDetails() {
                HStack(alignment: .top, spacing: 14) {
                    if let image = qrImage(for: pairingPayload) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 112, height: 112)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ReadOnlyInputBox(text: pairingPayload, placeholder: "Pairing payload unavailable", minHeight: 82)
                        HStack {
                            Button("Copy Pairing Payload") {
                                copyToPasteboard(pairingPayload)
                                showFeedback("Remote pairing payload copied", false)
                            }
                            .buttonStyle(CustomButtonStyle())
                            .disabled(pairingPayload.isEmpty)

                            Button("Refresh") { refreshAll() }
                                .buttonStyle(CustomButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Paired devices")
                    .font(fontPreset.font)
                Spacer()
                Button("Refresh") { refreshDevices() }
                    .buttonStyle(CustomButtonStyle())
            }

            if pairedDevices.isEmpty {
                Text("No paired devices yet.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                ForEach(pairedDevices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: PairedDeviceRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                .foregroundColor(device.isRevoked ? .secondary : .accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(fontPreset.font)
                    if device.isRevoked {
                        Text("Revoked")
                            .font(fontPreset.captionFont)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(device.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(device.scopes.sorted().map(\.rawValue).joined(separator: ", "))
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Revoke") {
                revoke(device)
            }
            .buttonStyle(CustomButtonStyle())
            .disabled(device.isRevoked)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeledMonospace(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func refreshAll() {
        refreshRemoteGatewayToken()
        refreshHostIdentity()
        refreshDevices()
    }

    private func refreshRemoteGatewayToken() {
        do {
            remoteGatewayToken = try RemoteGatewayTokenStore.shared.ensureToken()
        } catch {
            remoteGatewayToken = ""
            showFeedback("Failed to load remote gateway token: \(error.localizedDescription)", true)
        }
    }

    private func regenerateRemoteGatewayToken() {
        do {
            remoteGatewayToken = try RemoteGatewayTokenStore.shared.regenerateToken()
            showFeedback("Remote gateway token regenerated", false)
            Task { await ServerController.shared.applyRemoteGatewaySettings() }
        } catch {
            showFeedback("Failed to regenerate remote gateway token: \(error.localizedDescription)", true)
        }
    }

    private func refreshHostIdentity() {
        do {
            let host = try RemotePairingIdentityStore.shared.hostPublicKeyInfo()
            hostPublicKey = host.rawRepresentation.base64EncodedString()
            hostFingerprint = host.fingerprint
            storeError = nil
        } catch {
            hostPublicKey = ""
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func qrImage(for text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter?.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
