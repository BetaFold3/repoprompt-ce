import AppKit
import SwiftUI

/// Fixed, repository-spanning in-diff search chrome.
struct AgentChangesSearchBarView: View {
    let state: AgentChangesSearchState
    let focusRequest: Int
    let resignRequest: Int
    let onUpdateQuery: (String) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClearAndResign: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let spacing: CGFloat = 5
        static let textSizeAtNormal: CGFloat = 9.5
        static let glyphSizeAtNormal: CGFloat = 9
        static let fieldHeightAtNormal: CGFloat = 22
        static let buttonSizeAtNormal: CGFloat = 19
        static let progressScale: CGFloat = 0.45
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let backgroundOpacity: Double = 0.045
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var presentation: AgentChangesSearchBarPresentation {
        AgentChangesSearchBarPresentation(state: state)
    }

    private var isLoading: Bool {
        state.phase == .debouncing || state.phase == .loading
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            AgentChangesSearchField(
                text: state.query,
                focusRequest: focusRequest,
                resignRequest: resignRequest,
                fontSize: preset.scaledMetric(Layout.textSizeAtNormal),
                onChange: onUpdateQuery,
                onNext: onNext,
                onPrevious: onPrevious,
                onEscape: onClearAndResign
            )
            .frame(
                minWidth: 100,
                maxWidth: .infinity,
                minHeight: preset.scaledMetric(Layout.fieldHeightAtNormal)
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Layout.progressScale)
                    .hoverTooltip("Searching visible changes")
                    .accessibilityLabel("Searching visible changes")
            }

            if !presentation.resultText.isEmpty {
                Text(presentation.resultText)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.textSizeAtNormal))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("Search result \(presentation.resultText)")
            }

            if let limitText = presentation.limitText {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal)))
                    .foregroundStyle(.tertiary)
                    .hoverTooltip(limitText)
                    .accessibilityLabel(limitText)
            }

            navigationButton(
                symbol: "chevron.up",
                label: "Previous search match",
                action: onPrevious
            )
            navigationButton(
                symbol: "chevron.down",
                label: "Next search match",
                action: onNext
            )

            Button(action: onClearAndResign) {
                Image(systemName: "xmark")
                    .font(.system(
                        size: preset.scaledMetric(Layout.glyphSizeAtNormal),
                        weight: .semibold
                    ))
                    .frame(
                        width: preset.scaledMetric(Layout.buttonSizeAtNormal),
                        height: preset.scaledMetric(Layout.buttonSizeAtNormal)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverTooltip("Clear and close diff search")
            .accessibilityLabel("Clear and close diff search")
            .accessibilityValue(state.query.isEmpty ? "empty" : "query entered")
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(Layout.backgroundOpacity))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search changes")
    }

    private func navigationButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(
                    size: preset.scaledMetric(Layout.glyphSizeAtNormal),
                    weight: .semibold
                ))
                .frame(
                    width: preset.scaledMetric(Layout.buttonSizeAtNormal),
                    height: preset.scaledMetric(Layout.buttonSizeAtNormal)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(state.matches.isEmpty)
        .hoverTooltip(label)
        .accessibilityLabel(label)
        .accessibilityValue(state.matches.isEmpty ? "unavailable" : "available")
    }
}

/// Native field so focus requests can select the query and Escape can reliably resign AppKit's
/// field editor. No event monitor is involved; Return handling stays on the focused control.
private struct AgentChangesSearchField: NSViewRepresentable {
    let text: String
    let focusRequest: Int
    let resignRequest: Int
    let fontSize: CGFloat
    let onChange: (String) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.placeholderString = "Search changes"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .exterior
        field.toolTip = "Search file paths and visible diff content"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search changes")
        return field
    }

    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.onChange = onChange
        field.onNext = onNext
        field.onPrevious = onPrevious
        field.onEscape = onEscape
        field.font = .systemFont(ofSize: fontSize)
        field.setAccessibilityValue(text.isEmpty ? "empty" : text)

        if field.stringValue != text {
            field.stringValue = text
        }

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
        if context.coordinator.lastResignRequest != resignRequest {
            context.coordinator.lastResignRequest = resignRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, field.currentEditor() != nil else { return }
                field.window?.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var onChange: (String) -> Void = { _ in }
        var lastFocusRequest = 0
        var lastResignRequest = 0

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            onChange(field.stringValue)
        }
    }

    final class SearchField: NSSearchField {
        var onNext: () -> Void = {}
        var onPrevious: () -> Void = {}
        var onEscape: () -> Void = {}

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76:
                if event.modifierFlags.contains(.shift) {
                    onPrevious()
                } else {
                    onNext()
                }
            case 53:
                onEscape()
            default:
                super.keyDown(with: event)
            }
        }
    }
}

/// Panel-scoped key-equivalent bridge. AppKit asks views to perform key equivalents, so this stays
/// local to the view hierarchy and never installs a global or application event monitor.
struct AgentChangesPanelKeyCommandBridge: NSViewRepresentable {
    let isSearchActive: Bool
    let onFocusSearch: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onEscape: () -> Void

    func makeNSView(context _: Context) -> CommandView {
        CommandView()
    }

    func updateNSView(_ view: CommandView, context _: Context) {
        view.isSearchActive = isSearchActive
        view.onFocusSearch = onFocusSearch
        view.onNext = onNext
        view.onPrevious = onPrevious
        view.onEscape = onEscape
    }

    final class CommandView: NSView {
        var isSearchActive = false
        var onFocusSearch: () -> Void = {}
        var onNext: () -> Void = {}
        var onPrevious: () -> Void = {}
        var onEscape: () -> Void = {}

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let supported: NSEvent.ModifierFlags = [.command, .shift]
            let command = AgentChangesPanelKeyCommandRouting.command(
                character: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                isCommandPressed: modifiers.contains(.command),
                isShiftPressed: modifiers.contains(.shift),
                hasOtherModifiers: !modifiers.subtracting(supported).isEmpty,
                isFirstResponderInsidePanel: firstResponderIsInsidePanel(),
                isSearchActive: isSearchActive
            )
            switch command {
            case .focusSearch:
                onFocusSearch()
            case .nextMatch:
                onNext()
            case .previousMatch:
                onPrevious()
            case .clearAndResign:
                onEscape()
            case nil:
                return super.performKeyEquivalent(with: event)
            }
            return true
        }

        /// The responder must descend from a panel-sized ancestor shared with this full-size marker.
        /// A transcript editor shares the window's hosting root but not this bounded ancestor.
        private func firstResponderIsInsidePanel() -> Bool {
            guard let responderView = window?.firstResponder as? NSView else { return false }
            let panelRect = convert(bounds, to: nil)
            var ancestor = superview
            while let candidate = ancestor {
                if responderView === candidate || responderView.isDescendant(of: candidate) {
                    let candidateRect = candidate.convert(candidate.bounds, to: nil)
                    if candidateRect.approximatelyEquals(panelRect) {
                        return true
                    }
                }
                ancestor = candidate.superview
            }
            return false
        }
    }
}

private extension NSRect {
    func approximatelyEquals(_ other: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
