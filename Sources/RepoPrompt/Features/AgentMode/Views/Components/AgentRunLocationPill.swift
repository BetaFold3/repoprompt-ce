import SwiftUI

struct AgentRunLocationPill: View {
    let props: AgentRunLocationProps
    let selectLocation: (AgentRunLocation) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var selectionLabel: String {
        switch props.selection {
        case .thisMac:
            "This Mac"
        case let .host(hostID):
            props.hostOptions.first(where: { $0.id == hostID })?.displayName ?? props.selectedHostDisplayName ?? "Remote host"
        }
    }

    private var iconName: String {
        switch props.selection {
        case .thisMac:
            "laptopcomputer"
        case .host:
            "network"
        }
    }

    private var accentColor: Color {
        switch props.selection {
        case .thisMac: .secondary
        case .host: .accentColor
        }
    }

    var body: some View {
        Menu {
            Button {
                selectLocation(.thisMac)
            } label: {
                Label("This Mac", systemImage: "laptopcomputer")
            }

            if !props.hostOptions.isEmpty {
                Divider()
                ForEach(props.hostOptions) { host in
                    Button {
                        selectLocation(.host(hostID: host.id))
                    } label: {
                        Label(host.displayName, systemImage: selectedHostID == host.id ? "checkmark" : "network")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Run on: \(selectionLabel)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: fontPreset.scaledClamped(190, max: 250), alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, AgentPillMetrics.horizontalPadding())
            .frame(height: AgentPillMetrics.height())
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous)
                    .stroke(accentColor.opacity(0.35), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(!props.isEnabled)
        .opacity(props.isEnabled ? 1 : 0.6)
        .hoverTooltip(props.disabledReason ?? "Choose where this run starts", .top)
        .accessibilityLabel("Run on \(selectionLabel)")
    }

    private var selectedHostID: String? {
        if case let .host(hostID) = props.selection { return hostID }
        return nil
    }
}
