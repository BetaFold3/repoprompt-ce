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
            props.hostOptions.first(where: { $0.id == hostID })?.abbreviation
                ?? props.selectedHostAbbreviation
                ?? props.selectedHostDisplayName
                ?? "Remote host"
        }
    }

    private var accessibilitySelectionLabel: String {
        switch props.selection {
        case .thisMac:
            "This Mac"
        case .host:
            selectedHostFullName ?? selectionLabel
        }
    }

    private var hoverTooltipText: String {
        if !props.isEnabled,
           let disabledReason = props.disabledReason
        {
            return disabledReason
        }
        if case .host = props.selection,
           let fullName = selectedHostFullName
        {
            return "Run on \(fullName)"
        }
        return props.disabledReason ?? "Choose where this run starts"
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

    private var outlineColor: Color {
        switch props.selection {
        case .thisMac: Color.secondary.opacity(0.15)
        case .host: Color.accentColor.opacity(0.35)
        }
    }

    private var outlineLineWidth: CGFloat {
        switch props.selection {
        case .thisMac: 0.5
        case .host: 0.8
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
                    .stroke(outlineColor, lineWidth: outlineLineWidth)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(!props.isEnabled)
        .opacity(props.isEnabled ? 1 : 0.6)
        .hoverTooltip(hoverTooltipText, .top)
        .accessibilityLabel("Run on \(accessibilitySelectionLabel)")
    }

    private var selectedHostID: String? {
        if case let .host(hostID) = props.selection { return hostID }
        return nil
    }

    private var selectedHostFullName: String? {
        guard let selectedHostID else { return nil }
        return props.hostOptions.first(where: { $0.id == selectedHostID })?.displayName
            ?? props.selectedHostDisplayName
    }
}
