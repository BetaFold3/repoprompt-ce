import SwiftUI

enum AgentModelSelectionWarningVisuals {
    static let iconSystemName = "bolt.fill"
    static let warningColor = Color.orange

    static func warningTooltip(for agent: AgentProviderKind) -> String {
        switch agent {
        case .cursor:
            "Fast enabled: 2× more expensive, but faster speeds."
        default:
            "Fast Codex model selected: uses your usage limits about 2× faster."
        }
    }

    static func showsWarning(agent: AgentProviderKind, rawModel: String?) -> Bool {
        guard let rawModel else { return false }
        return switch agent {
        case .codexExec:
            CodexServiceTierVariantCatalog.isFastVariant(rawModel: rawModel)
        case .cursor:
            CursorModelMenuBuilder.hasFastEnabled(rawModel)
        default:
            false
        }
    }

    static func stableMenuImageSystemName(agent: AgentProviderKind, rawModel: String?) -> String? {
        showsWarning(agent: agent, rawModel: rawModel) ? iconSystemName : nil
    }

    static func stableMenuStyle(agent: AgentProviderKind, rawModel: String?) -> StableMenuItemStyle {
        showsWarning(agent: agent, rawModel: rawModel) ? .warning : .normal
    }

    static func codexGroupShowsWarning(_ group: AgentModelCatalog.CodexMenuGroup) -> Bool {
        showsWarning(agent: .codexExec, rawModel: group.baseModelID) ||
            group.options.contains { showsWarning(agent: .codexExec, rawModel: $0.rawValue) }
    }
}

struct AgentModelSelectionSummaryLabel: View {
    let agentKind: AgentProviderKind
    let rawModel: String
    let title: String
    var iconFont: Font = .caption

    var body: some View {
        let showsWarning = AgentModelSelectionWarningVisuals.showsWarning(agent: agentKind, rawModel: rawModel)
        let label = HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                    .font(iconFont)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            }
            if showsWarning {
                Text(title)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            } else {
                Text(title)
            }
        }
        if agentKind == .cursor, showsWarning {
            label.hoverTooltip(AgentModelSelectionWarningVisuals.warningTooltip(for: agentKind))
        } else {
            label
        }
    }
}

/// Reusable menu content for agent model selection.
/// For Codex and OpenCode, renders nested groups: base model -> variant/reasoning level.
///
/// Never attach state-mutating hover or overlay modifiers to views inside Menu content.
/// Hover-driven invalidation dismisses the tracking menu; use StableMenuItem.toolTip
/// for AppKit-backed in-menu tooltips.
struct AgentModelOptionsMenuContent: View {
    let agentKind: AgentProviderKind
    let options: [AgentModelOption]
    let selectedAgent: AgentProviderKind
    let selectedModelRaw: String
    let onSelect: (AgentProviderKind, AgentModelOption) -> Void

    var body: some View {
        if agentKind == .codexExec {
            let codexMenu = AgentModelCatalog.codexMenu(for: options)
            if let defaultOption = codexMenu.defaultOption {
                modelOptionButton(defaultOption)
            }
            ForEach(codexMenu.groups) { group in
                Menu {
                    ForEach(group.options, id: \.rawValue) { option in
                        modelOptionButton(option)
                    }
                } label: {
                    warningAwareMenuLabel(
                        title: group.displayName,
                        showsWarning: AgentModelSelectionWarningVisuals.codexGroupShowsWarning(group)
                    )
                }
            }
        } else if agentKind.usesClaudeTooling {
            let claudeMenu = AgentModelCatalog.claudeMenu(for: options, agentKind: agentKind)
            if let defaultOption = claudeMenu.defaultOption {
                modelOptionButton(defaultOption)
            }
            ForEach(claudeMenu.groups) { group in
                if group.rendersAsSubmenu {
                    Menu(group.displayName) {
                        ForEach(group.options, id: \.rawValue) { option in
                            modelOptionButton(option, title: claudeEffortMenuTitle(for: option))
                        }
                    }
                } else if let option = group.options.first {
                    modelOptionButton(option)
                }
            }
        } else if agentKind == .cursor {
            ForEach(options, id: \.rawValue) { option in
                if let leaves = Self.cursorSubmenuLeaves(
                    for: option,
                    selectedModelRaw: selectedAgent == agentKind ? selectedModelRaw : ""
                ) {
                    let sections = CursorModelMenuBuilder.sections(from: leaves)
                    let defaultLeaves = sections.first(where: { $0.section == .defaultSelection })?.leaves ?? []
                    let nondefaultSections = sections.filter { $0.section != .defaultSelection }
                    let parentShowsWarning = defaultLeaves.contains(where: \.showsFastWarning)
                        || nondefaultSections
                        .filter { $0.section != .fast }
                        .contains(where: \.showsFastWarning)
                    Menu {
                        ForEach(defaultLeaves, id: \.rawValue) { leaf in
                            cursorLeafButton(source: option, leaf: leaf, leaves: leaves)
                        }
                        if !defaultLeaves.isEmpty, !nondefaultSections.isEmpty {
                            Divider()
                        }
                        ForEach(Array(nondefaultSections.enumerated()), id: \.offset) { _, section in
                            switch section.section {
                            case .reasoning:
                                ForEach(section.leaves, id: \.rawValue) { leaf in
                                    cursorLeafButton(source: option, leaf: leaf, leaves: leaves)
                                }
                            case .context:
                                Menu(section.title ?? "") {
                                    ForEach(section.leaves, id: \.rawValue) { leaf in
                                        cursorLeafButton(source: option, leaf: leaf, leaves: leaves)
                                    }
                                }
                            case .fast:
                                Menu {
                                    ForEach(section.leaves, id: \.rawValue) { leaf in
                                        cursorLeafButton(source: option, leaf: leaf, leaves: leaves)
                                    }
                                } label: {
                                    warningAwareMenuLabel(
                                        title: section.title ?? "",
                                        showsWarning: true
                                    )
                                }
                            case .defaultSelection:
                                EmptyView()
                            }
                        }
                    } label: {
                        warningAwareMenuLabel(
                            title: option.displayName,
                            showsWarning: parentShowsWarning
                        )
                    }
                } else {
                    modelOptionButton(option)
                }
            }
        } else if agentKind == .openCode || agentKind == .ohMyPi {
            ForEach(AgentModelCatalog.openCodeMenu(
                for: options,
                providerID: agentKind.acpProviderID ?? .openCode
            ).providerGroups) { providerGroup in
                if providerGroup.rendersAsSubmenu {
                    Menu(providerGroup.displayName) {
                        openCodeModelGroupContent(providerGroup.groups)
                    }
                } else {
                    openCodeModelGroupContent(providerGroup.groups)
                }
            }
        } else {
            ForEach(options, id: \.rawValue) { option in
                modelOptionButton(option)
            }
        }
    }

    static func cursorSubmenuLeaves(
        for option: AgentModelOption,
        selectedModelRaw: String,
        catalog: CursorModelParameterCatalog = .shared,
        isEnabled: Bool = CursorParameterizedModels.isEnabled
    ) -> [CursorModelMenuBuilder.Leaf]? {
        CursorModelMenuBuilder.leaves(
            forModelRaw: option.rawValue,
            dimensionSet: .agentReasoning,
            selectedModelRaw: selectedModelRaw,
            catalog: catalog,
            isEnabled: isEnabled
        )
    }

    private func openCodeModelGroupContent(_ groups: [AgentModelCatalog.OpenCodeMenuGroup]) -> some View {
        ForEach(groups) { group in
            if group.rendersAsSubmenu {
                Menu(group.modelDisplayName) {
                    ForEach(group.options) { menuOption in
                        modelOptionButton(menuOption.option, title: menuOption.displayName)
                    }
                }
            } else if let menuOption = group.options.first {
                modelOptionButton(menuOption.option, title: menuOption.displayName)
            }
        }
    }

    @ViewBuilder
    private func modelOptionButton(
        _ option: AgentModelOption,
        title: String? = nil,
        isSelected: Bool? = nil
    ) -> some View {
        let showsWarning = AgentModelSelectionWarningVisuals.showsWarning(
            agent: agentKind,
            rawModel: option.rawValue
        )
        Button {
            AgentModelCatalog.updateLastUsedEffortIfEncoded(
                agentKind: agentKind,
                rawModel: option.rawValue
            )
            onSelect(agentKind, option)
        } label: {
            HStack {
                warningAwareMenuLabel(title: title ?? option.displayName, showsWarning: showsWarning)
                let optionIsSelected = isSelected ?? (
                    selectedAgent == agentKind && AgentModelCatalog.modelOptionIsSelected(
                        optionRaw: option.rawValue,
                        selectedRaw: selectedModelRaw,
                        agentKind: agentKind
                    )
                )
                if optionIsSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func cursorLeafButton(
        source: AgentModelOption,
        leaf: CursorModelMenuBuilder.Leaf,
        leaves: [CursorModelMenuBuilder.Leaf]
    ) -> some View {
        modelOptionButton(
            CursorModelMenuOptionAdapter.option(source: source, leaf: leaf),
            title: leaf.title,
            isSelected: CursorModelMenuBuilder.leafIsSelected(
                leaf,
                among: leaves,
                selectedModelRaw: selectedAgent == agentKind ? selectedModelRaw : ""
            )
        )
    }

    private func claudeEffortMenuTitle(for option: AgentModelOption) -> String {
        ClaudeModelSpecifier(raw: option.rawValue).effortLevel?.displayName ?? option.displayName
    }

    private func warningAwareMenuLabel(title: String, showsWarning: Bool) -> some View {
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            }
            if showsWarning {
                Text(title)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            } else {
                Text(title)
            }
        }
    }
}

private enum CursorModelMenuOptionAdapter {
    static func option(
        source: AgentModelOption,
        leaf: CursorModelMenuBuilder.Leaf
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: leaf.rawValue,
            displayName: source.displayName,
            description: source.description,
            isPlaceholderDefault: false,
            isProviderDefault: leaf.isDefaultLeaf && source.isProviderDefault
        )
    }
}

/// Reusable AppKit-backed menu item builder for agent model selection.
/// Mirrors `AgentModelOptionsMenuContent`, but produces `StableMenuItem`s for
/// long-lived pickers where SwiftUI `Menu` tracking can be interrupted by view updates.
enum AgentModelStableMenuItems {
    static func agentSubmenu(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        StableMenuItem.submenu(
            agentKind.displayName,
            items: modelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleCodexGroups: flattenSingleCodexGroups,
                groupOpenCode: groupOpenCode,
                onSelect: onSelect
            )
        )
    }

    static func modelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        if agentKind == .codexExec {
            return codexModelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleGroups: flattenSingleCodexGroups,
                onSelect: onSelect
            )
        }

        let visibleOptions = visibleOptions(options, includePlaceholderDefault: includePlaceholderDefault)
        if agentKind == .cursor {
            return cursorModelItems(
                options: visibleOptions,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        if agentKind.usesClaudeTooling {
            return claudeModelItems(
                agentKind: agentKind,
                options: visibleOptions,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        if agentKind == .openCode || agentKind == .ohMyPi, groupOpenCode {
            return AgentModelCatalog.openCodeMenu(
                for: visibleOptions,
                providerID: agentKind.acpProviderID ?? .openCode
            ).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
                let modelItems = providerGroup.groups.map { group in
                    openCodeModelItem(
                        agentKind: agentKind,
                        group: group,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
                guard providerGroup.rendersAsSubmenu else { return modelItems }
                return [.submenu(providerGroup.displayName, items: modelItems)]
            }
        }

        return visibleOptions.map { option in
            modelItem(
                option,
                agentKind: agentKind,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
    }

    static func cursorModelItems(
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        options.map { option in
            guard let leaves = CursorModelMenuBuilder.leaves(
                forModelRaw: option.rawValue,
                dimensionSet: .agentReasoning,
                selectedModelRaw: selectedAgent == .cursor ? selectedModelRaw : ""
            ) else {
                return modelItem(
                    option,
                    agentKind: .cursor,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            }

            let sections = CursorModelMenuBuilder.sections(from: leaves)
            let defaultLeaves = sections.first(where: { $0.section == .defaultSelection })?.leaves ?? []
            let nondefaultSections = sections.filter { $0.section != .defaultSelection }
            let parentShowsWarning = defaultLeaves.contains(where: \.showsFastWarning)
                || nondefaultSections
                .filter { $0.section != .fast }
                .contains(where: \.showsFastWarning)
            var items = defaultLeaves.map { leaf in
                modelItem(
                    CursorModelMenuOptionAdapter.option(source: option, leaf: leaf),
                    title: leaf.title,
                    agentKind: .cursor,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    isSelected: CursorModelMenuBuilder.leafIsSelected(
                        leaf,
                        among: leaves,
                        selectedModelRaw: selectedAgent == .cursor ? selectedModelRaw : ""
                    ),
                    onSelect: onSelect
                )
            }
            if !defaultLeaves.isEmpty, !nondefaultSections.isEmpty {
                items.append(.separator)
            }
            items.append(contentsOf: nondefaultSections.flatMap { section -> [StableMenuItem] in
                let leafItems = section.leaves.map { leaf in
                    modelItem(
                        CursorModelMenuOptionAdapter.option(source: option, leaf: leaf),
                        title: leaf.title,
                        agentKind: .cursor,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        isSelected: CursorModelMenuBuilder.leafIsSelected(
                            leaf,
                            among: leaves,
                            selectedModelRaw: selectedAgent == .cursor ? selectedModelRaw : ""
                        ),
                        onSelect: onSelect
                    )
                }
                switch section.section {
                case .reasoning:
                    return leafItems
                case .context:
                    return [.submenu(section.title ?? "", items: leafItems)]
                case .fast:
                    return [.submenu(
                        section.title ?? "",
                        imageSystemName: AgentModelSelectionWarningVisuals.iconSystemName,
                        style: .warning,
                        toolTip: AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor),
                        items: leafItems
                    )]
                case .defaultSelection:
                    return []
                }
            })
            return .submenu(
                option.displayName,
                isSelected: selectedAgent == .cursor
                    && CursorModelRegistryGate.normalizedAlias(option.rawValue)
                    == CursorModelRegistryGate.normalizedAlias(selectedModelRaw),
                imageSystemName: parentShowsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
                style: parentShowsWarning ? .warning : .normal,
                toolTip: parentShowsWarning
                    ? AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
                    : option.description,
                items: items
            )
        }
    }

    private static func codexModelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool,
        flattenSingleGroups: Bool,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let codexMenu = AgentModelCatalog.codexMenu(for: options)
        var items: [StableMenuItem] = []
        if includePlaceholderDefault, let defaultOption = codexMenu.defaultOption {
            items.append(
                modelItem(
                    defaultOption,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            )
        }
        items.append(contentsOf: codexMenu.groups.map { group in
            if flattenSingleGroups, group.options.count == 1, let only = group.options.first {
                return modelItem(
                    only,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            }
            let showsWarning = AgentModelSelectionWarningVisuals.codexGroupShowsWarning(group)
            return StableMenuItem.submenu(
                group.displayName,
                imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
                style: showsWarning ? .warning : .normal,
                items: group.options.map { option in
                    modelItem(
                        option,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
            )
        })
        return items
    }

    private static func claudeModelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let claudeMenu = AgentModelCatalog.claudeMenu(for: options, agentKind: agentKind)
        var items: [StableMenuItem] = []
        if let defaultOption = claudeMenu.defaultOption {
            items.append(
                modelItem(
                    defaultOption,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            )
        }
        items.append(contentsOf: claudeMenu.groups.map { group in
            if group.rendersAsSubmenu {
                return StableMenuItem.submenu(
                    group.displayName,
                    items: group.options.map { option in
                        modelItem(
                            option,
                            title: claudeEffortMenuTitle(for: option),
                            agentKind: agentKind,
                            selectedAgent: selectedAgent,
                            selectedModelRaw: selectedModelRaw,
                            onSelect: onSelect
                        )
                    }
                )
            }
            if let option = group.options.first {
                return modelItem(
                    option,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            }
            return .separator
        })
        return items
    }

    private static func openCodeModelItem(
        agentKind: AgentProviderKind,
        group: AgentModelCatalog.OpenCodeMenuGroup,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map { menuOption in
                    modelItem(
                        menuOption.option,
                        title: menuOption.displayName,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
            )
        }
        if let menuOption = group.options.first {
            return modelItem(
                menuOption.option,
                title: menuOption.displayName,
                agentKind: agentKind,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        return .separator
    }

    private static func modelItem(
        _ option: AgentModelOption,
        title: String? = nil,
        agentKind: AgentProviderKind,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        isSelected: Bool? = nil,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        StableMenuItem.action(
            title ?? option.displayName,
            isSelected: isSelected ?? (selectedAgent == agentKind && AgentModelCatalog.modelOptionIsSelected(
                optionRaw: option.rawValue,
                selectedRaw: selectedModelRaw,
                agentKind: agentKind
            )),
            imageSystemName: AgentModelSelectionWarningVisuals.stableMenuImageSystemName(agent: agentKind, rawModel: option.rawValue),
            style: AgentModelSelectionWarningVisuals.stableMenuStyle(agent: agentKind, rawModel: option.rawValue),
            toolTip: agentKind == .cursor
                && AgentModelSelectionWarningVisuals.showsWarning(agent: agentKind, rawModel: option.rawValue)
                ? AgentModelSelectionWarningVisuals.warningTooltip(for: agentKind)
                : nil
        ) {
            AgentModelCatalog.updateLastUsedEffortIfEncoded(
                agentKind: agentKind,
                rawModel: option.rawValue
            )
            onSelect(agentKind, option)
        }
    }

    private static func claudeEffortMenuTitle(for option: AgentModelOption) -> String {
        ClaudeModelSpecifier(raw: option.rawValue).effortLevel?.displayName ?? option.displayName
    }

    private static func visibleOptions(
        _ options: [AgentModelOption],
        includePlaceholderDefault: Bool
    ) -> [AgentModelOption] {
        guard !includePlaceholderDefault else { return options }
        let filtered = options.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? options : filtered
    }
}
