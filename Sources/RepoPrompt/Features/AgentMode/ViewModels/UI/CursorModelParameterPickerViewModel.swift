import Foundation

struct CursorModelParameterPickerViewModel {
    enum SelectionState: Equatable {
        case notSelected
        case inheritedBareBase
        case partialOrUnsupportedBracket
        case fullyEnforced
    }

    struct Option: Equatable {
        let value: String
        let displayName: String
    }

    struct Parameter: Equatable {
        let id: String
        let label: String
        let description: String?
        let defaultValue: String
        let options: [Option]
        let selectedValue: String?
    }

    struct MenuRowDescriptor: Equatable {
        let isSelected: Bool
        let selectionRaw: String
        let showsFastWarning: Bool
    }

    let parameters: [Parameter]
    let isSelectedModel: Bool
    let selectionState: SelectionState

    private let base: String
    private let hasCursorPrefix: Bool
    private let valuesByID: [String: String]
    private let fullyEnforcedSelectionRaw: String?

    init?(
        modelRaw: String,
        selectedModelRaw: String,
        specs: [CursorModelParameterCatalog.ParameterSpec]?,
        isEnabled: Bool
    ) {
        guard isEnabled,
              let specs,
              !specs.isEmpty
        else {
            return nil
        }

        let strippedModel = CursorBracketModelID.strippingCursorPrefix(modelRaw)
        guard let parsedModel = CursorBracketModelID.parse(strippedModel) else { return nil }
        let normalizedBase = Self.normalizedBase(parsedModel.base)
        guard normalizedBase != "auto", normalizedBase != "default" else { return nil }

        let strippedSelection = CursorBracketModelID.strippingCursorPrefix(selectedModelRaw)
        let parsedSelection = CursorBracketModelID.parse(strippedSelection)
        let selectionMatchesModel = parsedSelection.map {
            Self.normalizedBase($0.base) == normalizedBase
        } ?? false
        let explicitSelectionValues: [String: String] = if selectionMatchesModel,
                                                           parsedSelection?.hasBracket == true
        {
            Dictionary(
                uniqueKeysWithValues: parsedSelection?.params.map {
                    ($0.key.lowercased(), $0.value)
                } ?? []
            )
        } else {
            [:]
        }

        var seenIDs: Set<String> = []
        var valuesByID: [String: String] = [:]
        var parameters: [Parameter] = []
        for spec in specs {
            let normalizedID = spec.id.lowercased()
            guard seenIDs.insert(normalizedID).inserted,
                  Set(spec.options.map(\.value)).count == spec.options.count,
                  spec.options.contains(where: { $0.value == spec.defaultValue }),
                  spec.options.allSatisfy({
                      CursorBracketModelID.compose(
                          base: parsedModel.base,
                          params: [.init(key: spec.id, value: $0.value)]
                      ) != nil
                  })
            else {
                return nil
            }

            let selectedValue = explicitSelectionValues[normalizedID]
                .flatMap { candidate in
                    spec.options.contains(where: { $0.value == candidate }) ? candidate : nil
                }
            valuesByID[normalizedID] = selectedValue ?? spec.defaultValue
            parameters.append(Parameter(
                id: spec.id,
                label: Self.parameterLabel(id: spec.id, category: spec.category),
                description: spec.description,
                defaultValue: spec.defaultValue,
                options: spec.options.map {
                    Option(
                        value: $0.value,
                        displayName: Self.optionLabel(parameterID: spec.id, option: $0)
                    )
                },
                selectedValue: selectedValue
            ))
        }

        let selectionState: SelectionState
        if !selectionMatchesModel {
            selectionState = .notSelected
        } else if parsedSelection?.hasBracket != true {
            selectionState = .inheritedBareBase
        } else {
            let suppliedIDs = Set(explicitSelectionValues.keys)
            let hasExactlyAdvertisedIDs = suppliedIDs == seenIDs
            let allSuppliedValuesAreValid = parameters.allSatisfy { parameter in
                guard let supplied = explicitSelectionValues[parameter.id.lowercased()] else {
                    return false
                }
                return parameter.options.contains(where: { $0.value == supplied })
            }
            selectionState = hasExactlyAdvertisedIDs && allSuppliedValuesAreValid
                ? .fullyEnforced
                : .partialOrUnsupportedBracket
        }

        base = parsedModel.base
        hasCursorPrefix = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("cursor:")
        self.parameters = parameters
        isSelectedModel = selectionMatchesModel
        self.selectionState = selectionState
        self.valuesByID = valuesByID
        fullyEnforcedSelectionRaw = selectionState == .fullyEnforced ? selectedModelRaw : nil
    }

    func defaultSelectionRaw() -> String? {
        composeSelection(overrides: [:], useCatalogDefaults: true)
    }

    func selectionRaw(setting parameterID: String, to value: String) -> String? {
        selectionRaw(settings: [(id: parameterID, value: value)])
    }

    func selectionRaw(settings: [(id: String, value: String)]) -> String? {
        var overrides: [String: String] = [:]
        for setting in settings {
            guard let parameter = parameters.first(where: {
                $0.id.caseInsensitiveCompare(setting.id) == .orderedSame
            }),
                parameter.options.contains(where: { $0.value == setting.value })
            else {
                return nil
            }
            overrides[parameter.id.lowercased()] = setting.value
        }
        return composeSelection(overrides: overrides, useCatalogDefaults: false)
    }

    func currentSelectionRaw() -> String? {
        if selectionState == .fullyEnforced {
            return fullyEnforcedSelectionRaw
        }
        return composeSelection(overrides: [:], useCatalogDefaults: false)
    }

    func plainMenuRowDescriptor() -> MenuRowDescriptor? {
        guard let selectionRaw = currentSelectionRaw() else { return nil }
        return MenuRowDescriptor(
            isSelected: isSelectedModel,
            selectionRaw: selectionRaw,
            showsFastWarning: CursorModelMenuBuilder.hasFastEnabled(selectionRaw)
        )
    }

    var summaryLabel: String {
        switch selectionState {
        case .inheritedBareBase:
            return "Inherited"
        case .partialOrUnsupportedBracket:
            return "Partial"
        case .notSelected, .fullyEnforced:
            let parts = parameters.compactMap { parameter -> String? in
                guard let value = value(for: parameter.id) else { return nil }
                if Self.isFastParameter(parameter.id) {
                    return value.caseInsensitiveCompare("true") == .orderedSame ? "Fast" : nil
                }
                if parameter.id.caseInsensitiveCompare("context") == .orderedSame {
                    return value
                }
                return parameter.options.first(where: { $0.value == value })?.displayName ?? value
            }
            return parts.isEmpty ? "Settings" : parts.joined(separator: " · ")
        }
    }

    var summaryShowsFastWarning: Bool {
        guard selectionState != .inheritedBareBase else { return false }
        return value(for: "fast")?.caseInsensitiveCompare("true") == .orderedSame
    }

    var detailTooltip: String {
        var lines: [String] = []
        switch selectionState {
        case .notSelected:
            lines.append("Catalog default settings")
        case .inheritedBareBase:
            lines.append("Inherited from Cursor's global settings")
        case .partialOrUnsupportedBracket:
            lines.append("Partial or unsupported settings; valid values will be kept and missing values use catalog defaults")
        case .fullyEnforced:
            lines.append("Cursor model settings")
        }
        lines.append(contentsOf: parameters.compactMap { parameter in
            guard let value = value(for: parameter.id) else { return nil }
            let displayName = parameter.options.first(where: { $0.value == value })?.displayName ?? value
            return "\(parameter.label): \(displayName)"
        })
        return lines.joined(separator: "\n")
    }

    func value(for parameterID: String) -> String? {
        valuesByID[parameterID.lowercased()]
    }

    static func isFastParameter(_ parameterID: String) -> Bool {
        CursorModelMenuBuilder.isFastParameter(parameterID)
    }

    private func composeSelection(
        overrides: [String: String],
        useCatalogDefaults: Bool
    ) -> String? {
        let composedParameters = parameters.map { parameter in
            let value = if let override = overrides[parameter.id.lowercased()] {
                override
            } else if useCatalogDefaults {
                parameter.defaultValue
            } else {
                valuesByID[parameter.id.lowercased()] ?? parameter.defaultValue
            }
            return CursorBracketModelID.Parameter(key: parameter.id, value: value)
        }
        guard let composed = CursorBracketModelID.compose(base: base, params: composedParameters) else {
            return nil
        }
        return hasCursorPrefix ? "cursor:\(composed)" : composed
    }

    private static func normalizedBase(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parameterLabel(id: String, category: String) -> String {
        if category == "thought_level" {
            return "Reasoning"
        }
        return id
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func optionLabel(
        parameterID: String,
        option: CursorModelParameterCatalog.Option
    ) -> String {
        guard !isFastParameter(parameterID) else {
            return switch option.value.lowercased() {
            case "true":
                "On"
            case "false":
                "Off"
            default:
                option.name
            }
        }
        return option.name
    }
}
