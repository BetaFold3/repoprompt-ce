import Foundation

enum OhMyPiThinkingMenuBuilder {
    enum Action: Equatable {
        case selectDefault
        case selectValue(String)
        case load
        case clearUnavailable
        case none
    }

    struct Row: Equatable, Identifiable {
        enum Style: Equatable {
            case normal
            case informational
            case warning
        }

        let id: String
        let title: String
        let isEnabled: Bool
        let isSelected: Bool
        let style: Style
        let action: Action
    }

    static func rows(
        capability: OhMyPiThinkingCapabilitySnapshot?,
        probeState: OhMyPiThinkingCapabilityProbeState,
        storedChoice: OhMyPiThinkingSelections.ThinkingChoice?
    ) -> [Row] {
        let advertised = capability?.advertisedCapabilities
        let intent = OhMyPiThinkingDestinationIntent.resolve(
            choice: storedChoice,
            capabilities: advertised
        )
        var rows = [
            Row(
                id: "default",
                title: "Default",
                isEnabled: true,
                isSelected: intent == .defaultSelection,
                style: .normal,
                action: .selectDefault
            )
        ]

        if let capability {
            let duplicateNames = Dictionary(grouping: capability.orderedOptions, by: \.displayName)
                .filter { $0.value.count > 1 }
                .keys
            for option in capability.orderedOptions {
                let title = duplicateNames.contains(option.displayName)
                    ? "\(option.displayName) (\(option.value))"
                    : option.displayName
                let isSelected = if case let .advertised(_, value) = intent {
                    value == option.value
                } else {
                    false
                }
                rows.append(Row(
                    id: "value:\(option.value)",
                    title: title,
                    isEnabled: true,
                    isSelected: isSelected,
                    style: .normal,
                    action: .selectValue(option.value)
                ))
            }
            if case let .unavailable(rawValue) = intent {
                rows.append(Row(
                    id: "unavailable:\(rawValue)",
                    title: "Unavailable: \(rawValue)",
                    isEnabled: true,
                    isSelected: true,
                    style: .warning,
                    action: .clearUnavailable
                ))
            }
            return rows
        }

        switch probeState {
        case .loading:
            rows.append(Row(
                id: "loading",
                title: "Loading thinking levels…",
                isEnabled: false,
                isSelected: false,
                style: .informational,
                action: .none
            ))
        case .idle, .failed:
            let title = probeState == .failed
                ? "Thinking levels could not be loaded."
                : "Thinking levels have not been loaded."
            rows.append(Row(
                id: "unknown",
                title: title,
                isEnabled: false,
                isSelected: false,
                style: .informational,
                action: .none
            ))
            rows.append(Row(
                id: "load",
                title: "Load thinking levels…",
                isEnabled: true,
                isSelected: false,
                style: .normal,
                action: .load
            ))
        }
        return rows
    }

    @MainActor
    static func stableMenuItems(
        exactModelID: String,
        destination: ModelDestination,
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) -> [StableMenuItem] {
        rows(
            capability: registry.snapshot(for: exactModelID),
            probeState: resolver.state(for: exactModelID),
            storedChoice: destination.thinkingChoice(for: exactModelID)
        ).map { row in
            switch row.action {
            case .none:
                .message(row.title)
            case .selectDefault:
                .action(
                    row.title,
                    isEnabled: row.isEnabled,
                    isSelected: row.isSelected,
                    style: row.style == .warning ? .warning : .normal
                ) {
                    destination.applyThinkingValue(nil, for: exactModelID)
                }
            case let .selectValue(value):
                .action(
                    row.title,
                    isEnabled: row.isEnabled,
                    isSelected: row.isSelected,
                    style: row.style == .warning ? .warning : .normal
                ) {
                    destination.applyThinkingValue(value, for: exactModelID)
                }
            case .load:
                .action(row.title, isEnabled: row.isEnabled) {
                    resolver.requestManualRetry(exactModelID: exactModelID)
                }
            case .clearUnavailable:
                .action(
                    row.title,
                    isEnabled: row.isEnabled,
                    isSelected: row.isSelected,
                    imageSystemName: "exclamationmark.triangle.fill",
                    style: .warning,
                    toolTip: "Clear this unavailable stored thinking value."
                ) {
                    destination.applyThinkingValue(nil, for: exactModelID)
                }
            }
        }
    }

    static func exactModelID(from rawAIModelValue: String) -> String? {
        guard let model = AIModel.fromModelName(rawAIModelValue) else { return nil }
        return OhMyPiCanonicalModelIdentity.exactWireID(for: model)
    }
}
