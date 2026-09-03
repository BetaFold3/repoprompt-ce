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
        case .queued:
            rows.append(Row(
                id: "queued",
                title: "Queued — loading in background…",
                isEnabled: false,
                isSelected: false,
                style: .informational,
                action: .none
            ))
            rows.append(Row(
                id: "load-now",
                title: "Load now",
                isEnabled: true,
                isSelected: false,
                style: .normal,
                action: .load
            ))
        case .loading:
            rows.append(Row(
                id: "loading",
                title: "Loading thinking levels…",
                isEnabled: false,
                isSelected: false,
                style: .informational,
                action: .none
            ))
        case .unsupported:
            rows.append(Row(
                id: "unsupported",
                title: "This model does not advertise thinking levels.",
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
    static func perform(
        _ row: Row,
        exactModelID: String,
        destination: ModelDestination,
        resolver: OhMyPiThinkingCapabilityResolver = .shared,
        onBeforeApply: () -> Bool = { true }
    ) {
        switch row.action {
        case .none:
            break
        case .selectDefault:
            guard onBeforeApply() else { return }
            destination.applyThinkingValue(nil, for: exactModelID)
        case let .selectValue(value):
            guard onBeforeApply() else { return }
            destination.applyThinkingValue(value, for: exactModelID)
        case .load:
            resolver.requestManualRetry(exactModelID: exactModelID)
        case .clearUnavailable:
            guard onBeforeApply() else { return }
            destination.applyThinkingValue(nil, for: exactModelID)
        }
    }

    @MainActor
    static func stableMenuItems(
        exactModelID: String,
        destination: ModelDestination,
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        resolver: OhMyPiThinkingCapabilityResolver = .shared,
        onBeforeApply: @escaping () -> Bool = { true }
    ) -> [StableMenuItem] {
        rows(
            capability: registry.snapshot(for: exactModelID),
            probeState: resolver.state(for: exactModelID),
            storedChoice: destination.thinkingChoice(for: exactModelID)
        ).map { row in
            switch row.action {
            case .none:
                .message(row.title)
            case .selectDefault, .selectValue:
                .action(
                    row.title,
                    isEnabled: row.isEnabled,
                    isSelected: row.isSelected,
                    style: row.style == .warning ? .warning : .normal
                ) {
                    perform(
                        row,
                        exactModelID: exactModelID,
                        destination: destination,
                        resolver: resolver,
                        onBeforeApply: onBeforeApply
                    )
                }
            case .load:
                .action(row.title, isEnabled: row.isEnabled) {
                    perform(
                        row,
                        exactModelID: exactModelID,
                        destination: destination,
                        resolver: resolver,
                        onBeforeApply: onBeforeApply
                    )
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
                    perform(
                        row,
                        exactModelID: exactModelID,
                        destination: destination,
                        resolver: resolver,
                        onBeforeApply: onBeforeApply
                    )
                }
            }
        }
    }

    static func exactModelID(from rawAIModelValue: String) -> String? {
        guard let model = AIModel.fromModelName(rawAIModelValue) else { return nil }
        return OhMyPiCanonicalModelIdentity.exactWireID(for: model)
    }
}

enum OhMyPiThinkingSweepStatusPresentation {
    static func headerText(_ status: OhMyPiThinkingSweepStatus) -> String? {
        switch status {
        case .idle:
            return nil
        case .preflight:
            return "Loading thinking levels…"
        case let .running(done, total, current):
            if let current, !current.isEmpty {
                return "Loading thinking levels… \(done)/\(total) · \(current)"
            }
            return "Loading thinking levels… \(done)/\(total)"
        case let .partial(loaded, deferred):
            return "Loaded \(loaded) · \(deferred) deferred — open this menu again to continue"
        case let .failed(reason, _):
            return "Thinking levels: \(reason) — hover away and back to refresh"
        case let .completed(loaded, failed, unsupported, _):
            if failed > 0 {
                return "Thinking levels: \(failed) failed — hover away and back to refresh"
            }
            if unsupported > 0 {
                return "Loaded \(loaded) · \(unsupported) unsupported"
            }
            return "Loaded thinking levels for \(loaded) models"
        case .cancelled:
            return "Thinking-level loading cancelled."
        }
    }

    static func headerItem(_ status: OhMyPiThinkingSweepStatus) -> StableMenuItem? {
        headerText(status).map(StableMenuItem.header)
    }
}
