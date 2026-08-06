import SwiftUI

/// Compact chrome for Workstream 5 item 1's assistant-only transcript search: query field,
/// match counter, and prev/next navigation.
struct AgentAssistantTranscriptSearchBarView: View {
    @Binding var query: String
    let counterText: String?
    let hasMatches: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search assistant replies", text: $query)
                .textFieldStyle(.plain)
                .font(preset.swiftUIFont(sizeAtNormal: 12))
                .focused($isFieldFocused)
                .onSubmit(onNext)
                .accessibilityLabel("Search assistant replies")

            if let counterText {
                Text(counterText)
                    .font(preset.swiftUIFont(sizeAtNormal: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            navButton(symbol: "chevron.up", label: "Previous match", action: onPrevious)
            navButton(symbol: "chevron.down", label: "Next match", action: onNext)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverTooltip("Close search")
            .accessibilityLabel("Close transcript search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentTranscript.assistantSearch.bar")
        .onAppear { isFieldFocused = true }
    }

    private func navButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!hasMatches)
        .hoverTooltip(label)
        .accessibilityLabel(label)
    }
}
