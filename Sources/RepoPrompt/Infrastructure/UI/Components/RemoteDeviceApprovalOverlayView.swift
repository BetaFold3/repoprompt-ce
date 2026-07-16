import SwiftUI

struct RemoteDeviceApprovalOverlayView: View {
    @ObservedObject var approvalManager: RemoteDeviceApprovalManager
    let request: RemoteDeviceApprovalRequest

    @State private var selectedScopes: Set<RemoteScope>
    @State private var isAnimating = false

    init(approvalManager: RemoteDeviceApprovalManager, request: RemoteDeviceApprovalRequest) {
        self.approvalManager = approvalManager
        self.request = request
        _selectedScopes = State(initialValue: request.requestedScopes)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                actions
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 22, x: 0, y: 14)
            .scaleEffect(isAnimating ? 1 : 0.96)
            .opacity(isAnimating ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isAnimating = true
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Approve Remote Device")
                    .font(.headline)
                Text("A gateway is asking to pair a device with this RepoPrompt host.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                labeledValue("Device", request.displayName)
                labeledValue("Device ID", request.deviceID)
                labeledValue("Device fingerprint", request.devicePublicKeyFingerprint)
                labeledValue("Host fingerprint", request.hostFingerprint)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Granted scopes")
                    .font(.subheadline.weight(.semibold))
                ForEach(RemoteScope.allCases.sorted()) { scope in
                    Toggle(isOn: binding(for: scope)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.displayName)
                                .font(.callout)
                            Text(scope.rawValue)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!request.requestedScopes.contains(scope))
                }
                Text("You may reduce scopes before approving. Pairing is not persisted unless you approve.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Deny") {
                resolve(allow: false)
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Approve Device") {
                resolve(allow: true)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedScopes.isEmpty)
        }
        .padding(20)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func binding(for scope: RemoteScope) -> Binding<Bool> {
        Binding(
            get: { selectedScopes.contains(scope) },
            set: { enabled in
                if enabled {
                    selectedScopes.insert(scope)
                } else {
                    selectedScopes.remove(scope)
                }
            }
        )
    }

    private func resolve(allow: Bool) {
        withAnimation(.easeInOut(duration: 0.14)) {
            isAnimating = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            approvalManager.resolveApproval(allow: allow, grantedScopes: selectedScopes)
        }
    }
}
