import Foundation

enum CursorModelMenuBuilder {
    enum DimensionSet: Equatable {
        case agentReasoning
        case preset
    }

    enum Section: Hashable {
        case defaultSelection
        case reasoning
        case context(value: String, title: String)
        case fast
    }

    struct Leaf: Equatable {
        let rawValue: String
        let title: String
        let section: Section
        let showsFastWarning: Bool
        let isDefaultLeaf: Bool
    }

    struct MenuSection: Equatable {
        let section: Section
        let title: String?
        let leaves: [Leaf]

        var showsFastWarning: Bool {
            leaves.contains(where: \.showsFastWarning)
        }
    }

    static func leaves(
        forModelRaw modelRaw: String,
        dimensionSet: DimensionSet,
        selectedModelRaw: String,
        catalog: CursorModelParameterCatalog = .shared,
        isEnabled: Bool = CursorParameterizedModels.isEnabled
    ) -> [Leaf]? {
        let strippedModel = CursorBracketModelID.strippingCursorPrefix(modelRaw)
        guard let parsedModel = CursorBracketModelID.parse(strippedModel),
              !parsedModel.hasBracket
        else {
            return nil
        }

        let normalizedBase = CursorModelRegistryGate.normalizedAlias(parsedModel.base)
        guard normalizedBase != CursorModelRegistryGate.normalizedAlias(AgentModel.cursorAuto.rawValue),
              normalizedBase != CursorModelRegistryGate.normalizedAlias(AgentModel.cursorComposer2.rawValue),
              normalizedBase != "default",
              let specs = catalog.parameterSpecs(forModel: modelRaw),
              let picker = CursorModelParameterPickerViewModel(
                  modelRaw: modelRaw,
                  selectedModelRaw: selectedModelRaw,
                  specs: specs,
                  isEnabled: isEnabled
              )
        else {
            return nil
        }

        let thoughtSpec = preferredSpec(
            in: specs,
            category: "thought_level",
            fallbackIDs: ["reasoning", "effort", "thinking_mode", "thought_level"]
        )

        let fastSpec = preferredSpec(in: specs, fallbackIDs: ["fast"])

        switch dimensionSet {
        case .agentReasoning:
            return agentReasoningLeaves(
                picker: picker,
                thoughtSpec: thoughtSpec,
                fastSpec: fastSpec
            )
        case .preset:
            return presetLeaves(
                modelRaw: modelRaw,
                base: parsedModel.base,
                specs: specs,
                thoughtSpec: thoughtSpec
            )
        }
    }

    static func sections(from leaves: [Leaf]) -> [MenuSection] {
        var ordered: [Section] = []
        for leaf in leaves where !ordered.contains(leaf.section) {
            ordered.append(leaf.section)
        }
        return ordered.map { section in
            let title: String? = switch section {
            case .defaultSelection, .reasoning:
                nil
            case let .context(_, title):
                title
            case .fast:
                "Fast (2×)"
            }
            return MenuSection(
                section: section,
                title: title,
                leaves: leaves.filter { $0.section == section }
            )
        }
    }

    static func leafIsSelected(
        _ leaf: Leaf,
        among leaves: [Leaf],
        selectedModelRaw: String
    ) -> Bool {
        let matchingLeaves = leaves.filter {
            AgentModelCatalog.modelOptionIsSelected(
                optionRaw: $0.rawValue,
                selectedRaw: selectedModelRaw,
                agentKind: .cursor
            )
        }
        guard !matchingLeaves.isEmpty else { return false }

        let preferredLeaf: Leaf? = if let defaultLeaf = matchingLeaves.first(where: \.isDefaultLeaf) {
            defaultLeaf
        } else if hasFastEnabled(selectedModelRaw) {
            matchingLeaves.first(where: { $0.section == .fast }) ?? matchingLeaves.first
        } else {
            matchingLeaves.first
        }
        return preferredLeaf == leaf
    }

    static func displaySuffix(
        forRaw raw: String,
        catalog: CursorModelParameterCatalog = .shared
    ) -> String? {
        let stripped = CursorBracketModelID.strippingCursorPrefix(raw)
        guard let parsed = CursorBracketModelID.parse(stripped), parsed.hasBracket else {
            return nil
        }

        let specs = catalog.parameterSpecs(forModel: parsed.base) ?? []
        let specsByID = specs.reduce(into: [String: CursorModelParameterCatalog.ParameterSpec]()) {
            $0[$1.id.lowercased()] = $1
        }
        let thoughtIDs = Set(specs.filter { $0.category == "thought_level" }.map { $0.id.lowercased() })

        struct Part {
            let rank: Int
            let wireIndex: Int
            let text: String
        }

        let parts = parsed.params.enumerated().compactMap { index, parameter -> Part? in
            let key = parameter.key.lowercased()
            let spec = specsByID[key]
            let optionName = spec?.options.first(where: { $0.value == parameter.value })?.name
            let isDefault = spec?.defaultValue == parameter.value

            if isFastParameter(key) {
                guard parameter.value.caseInsensitiveCompare("true") == .orderedSame else {
                    return nil
                }
                return Part(rank: 1, wireIndex: index, text: "Fast")
            }

            if thoughtIDs.contains(key) || isFallbackThoughtParameter(key) {
                guard isDefault != true else { return nil }
                return Part(
                    rank: 0,
                    wireIndex: index,
                    text: optionName ?? humanizedValue(parameter.value)
                )
            }

            if key == "context" {
                guard isDefault != true else { return nil }
                return Part(
                    rank: 2,
                    wireIndex: index,
                    text: optionName.map(humanizedContext) ?? humanizedContext(parameter.value)
                )
            }

            guard isDefault != true else { return nil }
            return Part(
                rank: 3,
                wireIndex: index,
                text: optionName.map { "\(parameter.key): \($0)" }
                    ?? "\(parameter.key)=\(parameter.value)"
            )
        }
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.wireIndex < $1.wireIndex
        }

        guard !parts.isEmpty else { return nil }
        return parts.map(\.text).joined(separator: " · ")
    }

    static func hasFastEnabled(_ raw: String) -> Bool {
        let stripped = CursorBracketModelID.strippingCursorPrefix(raw)
        return CursorBracketModelID.parse(stripped)?.params.contains { parameter in
            isFastParameter(parameter.key)
                && parameter.value.caseInsensitiveCompare("true") == .orderedSame
        } ?? false
    }

    static func isFastParameter(_ id: String) -> Bool {
        id.caseInsensitiveCompare("fast") == .orderedSame
    }

    private static func agentReasoningLeaves(
        picker: CursorModelParameterPickerViewModel,
        thoughtSpec: CursorModelParameterCatalog.ParameterSpec?,
        fastSpec: CursorModelParameterCatalog.ParameterSpec?
    ) -> [Leaf]? {
        let fastOption = fastSpec?.options.first {
            $0.value.caseInsensitiveCompare("true") == .orderedSame
        }
        guard thoughtSpec != nil || fastOption != nil,
              let defaultRaw = picker.defaultSelectionRaw()
        else {
            return nil
        }

        var leaves = [
            Leaf(
                rawValue: defaultRaw,
                title: "Default",
                section: .defaultSelection,
                showsFastWarning: hasFastEnabled(defaultRaw),
                isDefaultLeaf: true
            )
        ]

        if let thoughtSpec {
            for option in thoughtSpec.options {
                guard let raw = picker.selectionRaw(setting: thoughtSpec.id, to: option.value) else {
                    return nil
                }
                leaves.append(Leaf(
                    rawValue: raw,
                    title: option.name,
                    section: .reasoning,
                    showsFastWarning: hasFastEnabled(raw),
                    isDefaultLeaf: false
                ))
            }
        }

        if let fastSpec, let fastOption {
            if let thoughtSpec {
                for option in thoughtSpec.options {
                    guard let raw = picker.selectionRaw(settings: [
                        (id: thoughtSpec.id, value: option.value),
                        (id: fastSpec.id, value: fastOption.value)
                    ]) else {
                        return nil
                    }
                    leaves.append(Leaf(
                        rawValue: raw,
                        title: option.name,
                        section: .fast,
                        showsFastWarning: true,
                        isDefaultLeaf: false
                    ))
                }
            } else {
                guard let raw = picker.selectionRaw(setting: fastSpec.id, to: fastOption.value) else {
                    return nil
                }
                leaves.append(Leaf(
                    rawValue: raw,
                    title: "Fast",
                    section: .fast,
                    showsFastWarning: true,
                    isDefaultLeaf: false
                ))
            }
        }

        return leaves
    }

    private static func presetLeaves(
        modelRaw: String,
        base: String,
        specs: [CursorModelParameterCatalog.ParameterSpec],
        thoughtSpec: CursorModelParameterCatalog.ParameterSpec?
    ) -> [Leaf]? {
        var leaves = [
            Leaf(
                rawValue: modelRaw,
                title: "Default (inherit)",
                section: .defaultSelection,
                showsFastWarning: false,
                isDefaultLeaf: true
            )
        ]

        if let thoughtSpec {
            for option in thoughtSpec.options {
                guard let raw = composePartial(
                    sourceModelRaw: modelRaw,
                    base: base,
                    parameters: [.init(key: thoughtSpec.id, value: option.value)]
                ) else {
                    return nil
                }
                leaves.append(Leaf(
                    rawValue: raw,
                    title: option.name,
                    section: .reasoning,
                    showsFastWarning: false,
                    isDefaultLeaf: false
                ))
            }
        }

        if let contextSpec = preferredSpec(
            in: specs,
            category: "context_window",
            fallbackIDs: ["context"]
        ) {
            for contextOption in contextSpec.options where contextOption.value != contextSpec.defaultValue {
                let section = Section.context(
                    value: contextOption.value,
                    title: "\(humanizedContext(contextOption.name)) Context"
                )
                guard let inheritRaw = composePartial(
                    sourceModelRaw: modelRaw,
                    base: base,
                    parameters: [.init(key: contextSpec.id, value: contextOption.value)]
                ) else {
                    return nil
                }
                leaves.append(Leaf(
                    rawValue: inheritRaw,
                    title: "Inherit reasoning",
                    section: section,
                    showsFastWarning: false,
                    isDefaultLeaf: false
                ))
                if let thoughtSpec {
                    for thoughtOption in thoughtSpec.options {
                        guard let raw = composePartial(
                            sourceModelRaw: modelRaw,
                            base: base,
                            parameters: [
                                .init(key: contextSpec.id, value: contextOption.value),
                                .init(key: thoughtSpec.id, value: thoughtOption.value)
                            ]
                        ) else {
                            return nil
                        }
                        leaves.append(Leaf(
                            rawValue: raw,
                            title: thoughtOption.name,
                            section: section,
                            showsFastWarning: false,
                            isDefaultLeaf: false
                        ))
                    }
                }
            }
        }

        if let fastSpec = preferredSpec(in: specs, fallbackIDs: ["fast"]),
           let fastOption = fastSpec.options.first(where: {
               $0.value.caseInsensitiveCompare("true") == .orderedSame
           })
        {
            guard let inheritRaw = composePartial(
                sourceModelRaw: modelRaw,
                base: base,
                parameters: [.init(key: fastSpec.id, value: fastOption.value)]
            ) else {
                return nil
            }
            leaves.append(Leaf(
                rawValue: inheritRaw,
                title: "Inherit reasoning",
                section: .fast,
                showsFastWarning: true,
                isDefaultLeaf: false
            ))
            if let thoughtSpec {
                for thoughtOption in thoughtSpec.options {
                    guard let raw = composePartial(
                        sourceModelRaw: modelRaw,
                        base: base,
                        parameters: [
                            .init(key: fastSpec.id, value: fastOption.value),
                            .init(key: thoughtSpec.id, value: thoughtOption.value)
                        ]
                    ) else {
                        return nil
                    }
                    leaves.append(Leaf(
                        rawValue: raw,
                        title: thoughtOption.name,
                        section: .fast,
                        showsFastWarning: true,
                        isDefaultLeaf: false
                    ))
                }
            }
        }

        return leaves.count > 1 ? leaves : nil
    }

    private static func preferredSpec(
        in specs: [CursorModelParameterCatalog.ParameterSpec],
        category: String? = nil,
        fallbackIDs: Set<String>
    ) -> CursorModelParameterCatalog.ParameterSpec? {
        if let category {
            let categoryMatches = specs.filter {
                $0.category.caseInsensitiveCompare(category) == .orderedSame
            }
            if categoryMatches.count == 1 {
                return categoryMatches[0]
            }
            if categoryMatches.count > 1 {
                return nil
            }
        }

        let idMatches = specs.filter { fallbackIDs.contains($0.id.lowercased()) }
        return idMatches.count == 1 ? idMatches[0] : nil
    }

    private static func composePartial(
        sourceModelRaw: String,
        base: String,
        parameters: [CursorBracketModelID.Parameter]
    ) -> String? {
        guard let composed = CursorBracketModelID.compose(base: base, params: parameters) else {
            return nil
        }
        let hasCursorPrefix = sourceModelRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("cursor:")
        return hasCursorPrefix ? "cursor:\(composed)" : composed
    }

    private static func isFallbackThoughtParameter(_ id: String) -> Bool {
        ["reasoning", "effort", "thinking_mode", "thought_level"].contains(id)
    }

    private static func humanizedContext(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix = trimmed.last, suffix == "k" || suffix == "K" || suffix == "m" || suffix == "M" else {
            return trimmed
        }
        return String(trimmed.dropLast()) + String(suffix).uppercased()
    }

    private static func humanizedValue(_ raw: String) -> String {
        switch raw.lowercased() {
        case "xhigh": "XHigh"
        case "max": "Max"
        case "none": "None"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
