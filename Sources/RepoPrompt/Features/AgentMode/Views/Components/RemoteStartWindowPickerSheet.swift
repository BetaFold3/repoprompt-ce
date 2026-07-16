import SwiftUI

struct RemoteStartWindowPickerSheet: View {
    let state: RemoteStartWindowPickerState
    let onSelect: (RemoteStartWindowOption) -> Void
    let onOpenWorkspace: (() -> Void)?
    let onCancel: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a remote window")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .semibold))
                    Text("\(state.hostName) needs a target window before starting this run.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if let workspaceName = state.openableWorkspaceName,
               let onOpenWorkspace
            {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This workspace isn't open on the host.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundStyle(.secondary)
                    Button("Open '\(workspaceName)' on \(state.hostName)") {
                        onOpenWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.windows) { window in
                    Button {
                        onSelect(window)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "macwindow")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.title)
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if let subtitle = window.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                            Text("#\(window.windowID)")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(RemoteStartWindowRowButtonStyle())
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: fontPreset.scaledClamped(420, min: 380, max: 520), alignment: .leading)
    }

    private struct RemoteStartWindowRowButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(configuration.isPressed ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        }
    }
}
