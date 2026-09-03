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
    var thinkingDestination: ModelDestination?
    let onSelect: (AgentProviderKind, AgentModelOption) -> Bool

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
        } else if agentKind == .ohMyPi {
            let projected = Self.ohMyPiProjection(for: options)
            Group {
                if let header = OhMyPiThinkingSweepStatusPresentation.headerText(
                    OhMyPiThinkingCapabilityResolver.shared.sweepStatus
                ) {
                    Button(header) {}
                        .disabled(true)
                }
                ForEach(projected.projection.rootLeaves) { leaf in
                    if let option = projected.optionsBySourceID[leaf.sourceID] {
                        ohMyPiModelLeaf(leaf, option: option)
                    }
                }
                ForEach(projected.projection.namespaceGroups) { namespaceGroup in
                    Menu(namespaceGroup.namespace) {
                        ohMyPiModelGroupContent(
                            namespaceGroup.modelGroups,
                            optionsBySourceID: projected.optionsBySourceID
                        )
                    }
                }
            }
            .onAppear {
                OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(
                    wireIDs: projected.projection.allLeaves.map(\.wireID),
                    selectedRawModel: selectedAgent == .ohMyPi ? selectedModelRaw : nil,
                    workspacePath: nil
                )
            }
        } else if agentKind == .openCode {
            ForEach(AgentModelCatalog.openCodeMenu(for: options).providerGroups) { providerGroup in
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

    private func ohMyPiModelGroupContent(
        _ groups: [OhMyPiModelMenuProjector.ModelGroup],
        optionsBySourceID: [String: AgentModelOption]
    ) -> some View {
        ForEach(groups) { group in
            if group.shape.collapsesNormal, let normal = group.normalLeaves.first {
                if let option = optionsBySourceID[normal.sourceID] {
                    ohMyPiModelLeaf(normal, option: option, title: group.title)
                }
                if group.shape.collapsesFast, let fast = group.fastLeaves.first,
                   let option = optionsBySourceID[fast.sourceID]
                {
                    ohMyPiModelLeaf(fast, option: option, title: "\(group.title) Fast")
                } else if !group.fastLeaves.isEmpty {
                    Menu("\(group.title) Fast") {
                        ForEach(group.fastLeaves) { leaf in
                            if let option = optionsBySourceID[leaf.sourceID] {
                                ohMyPiModelLeaf(leaf, option: option)
                            }
                        }
                    }
                }
            } else if group.isFamily {
                Menu(group.title) {
                    ForEach(group.normalLeaves) { leaf in
                        if let option = optionsBySourceID[leaf.sourceID] {
                            ohMyPiModelLeaf(leaf, option: option)
                        }
                    }
                    if group.shape.collapsesFast, let fast = group.fastLeaves.first,
                       let option = optionsBySourceID[fast.sourceID]
                    {
                        ohMyPiModelLeaf(fast, option: option, title: "Fast")
                    } else if !group.fastLeaves.isEmpty {
                        Menu("Fast") {
                            ForEach(group.fastLeaves) { leaf in
                                if let option = optionsBySourceID[leaf.sourceID] {
                                    ohMyPiModelLeaf(leaf, option: option)
                                }
                            }
                        }
                    }
                }
            } else if let leaf = group.normalLeaves.first,
                      let option = optionsBySourceID[leaf.sourceID]
            {
                ohMyPiModelLeaf(leaf, option: option)
            }
        }
    }

    @ViewBuilder
    private func ohMyPiModelLeaf(
        _ leaf: OhMyPiModelMenuProjector.Leaf,
        option: AgentModelOption,
        title titleOverride: String? = nil
    ) -> some View {
        let title = titleOverride ?? leaf.title
        if leaf.allowsThinkingAccessory,
           !option.isPlaceholderDefault,
           let thinkingDestination,
           thinkingDestination.hasThinkingAccessory,
           let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: leaf.wireID)
        {
            Menu {
                ohMyPiThinkingRows(
                    exactModelID: exactModelID,
                    option: option,
                    destination: thinkingDestination
                )
            } label: {
                HStack {
                    Text(title)
                    if selectedAgent == .ohMyPi,
                       AgentModelCatalog.modelOptionIsSelected(
                           optionRaw: option.rawValue,
                           selectedRaw: selectedModelRaw,
                           agentKind: .ohMyPi
                       )
                    {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        } else {
            modelOptionButton(option, title: title)
        }
    }

    fileprivate static func ohMyPiProjection(
        for options: [AgentModelOption]
    ) -> (
        projection: OhMyPiModelMenuProjector.Projection,
        optionsBySourceID: [String: AgentModelOption]
    ) {
        let indexed = options.enumerated().map { (sourceID: String($0.offset), option: $0.element) }
        return (
            OhMyPiModelMenuProjector.project(indexed.map {
                OhMyPiModelMenuProjector.Input(
                    sourceID: $0.sourceID,
                    wireID: $0.option.rawValue,
                    displayName: $0.option.displayName
                )
            }),
            Dictionary(uniqueKeysWithValues: indexed.map { ($0.sourceID, $0.option) })
        )
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
            commitModelOption(option)
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

    private func commitModelOption(_ option: AgentModelOption) -> Bool {
        guard onSelect(agentKind, option) else { return false }
        AgentModelCatalog.updateLastUsedEffortIfEncoded(
            agentKind: agentKind,
            rawModel: option.rawValue
        )
        OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
            agent: agentKind,
            rawModel: option.rawValue
        )
        return true
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

    @ViewBuilder
    private func ohMyPiThinkingRows(
        exactModelID: String,
        option: AgentModelOption,
        destination: ModelDestination
    ) -> some View {
        let rows = OhMyPiThinkingMenuBuilder.rows(
            capability: OhMyPiThinkingCapabilityRegistry.shared.snapshot(for: exactModelID),
            probeState: OhMyPiThinkingCapabilityResolver.shared.state(for: exactModelID),
            storedChoice: destination.thinkingChoice(for: exactModelID)
        )
        ForEach(rows) { row in
            switch row.action {
            case .none:
                Button(row.title) {}
                    .disabled(true)
            case .selectDefault, .selectValue, .clearUnavailable:
                Button {
                    OhMyPiThinkingMenuBuilder.perform(
                        row,
                        exactModelID: exactModelID,
                        destination: destination,
                        onBeforeApply: {
                            commitModelOption(option)
                        }
                    )
                } label: {
                    thinkingRowLabel(row)
                }
            case .load:
                Button(row.title) {
                    OhMyPiThinkingMenuBuilder.perform(
                        row,
                        exactModelID: exactModelID,
                        destination: destination
                    )
                }
            }
        }
    }

    private func thinkingRowLabel(_ row: OhMyPiThinkingMenuBuilder.Row) -> some View {
        HStack {
            Text(row.title)
                .foregroundStyle(row.style == .warning ? Color.orange : Color.primary)
            if row.isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
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
    /// - Parameter groupOpenCode: Whether OpenCode models use provider/model grouping.
    ///   Oh My Pi always projects hierarchically.
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
        let buildItems = {
            modelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleCodexGroups: flattenSingleCodexGroups,
                groupOpenCode: groupOpenCode,
                onSelect: onSelect
            )
        }
        guard agentKind == .ohMyPi else {
            return StableMenuItem.submenu(agentKind.displayName, items: buildItems())
        }
        return StableMenuItem.lazySubmenu(
            agentKind.displayName,
            onOpen: {
                OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(
                    wireIDs: options.map(\.rawValue),
                    selectedRawModel: selectedAgent == .ohMyPi ? selectedModelRaw : nil,
                    workspacePath: nil
                )
            },
            items: buildItems
        )
    }

    /// - Parameter groupOpenCode: Whether OpenCode models use provider/model grouping.
    ///   Oh My Pi always projects hierarchically.
    @MainActor
    static func agentSubmenu(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        thinkingDestination: ModelDestination,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Bool
    ) -> StableMenuItem {
        let buildItems = {
            modelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleCodexGroups: flattenSingleCodexGroups,
                groupOpenCode: groupOpenCode,
                thinkingDestination: thinkingDestination,
                onSelect: onSelect
            )
        }
        guard agentKind == .ohMyPi else {
            return StableMenuItem.submenu(agentKind.displayName, items: buildItems())
        }
        return StableMenuItem.lazySubmenu(
            agentKind.displayName,
            onOpen: {
                OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(
                    wireIDs: options.map(\.rawValue),
                    selectedRawModel: selectedAgent == .ohMyPi ? selectedModelRaw : nil,
                    workspacePath: nil
                )
            },
            items: buildItems
        )
    }

    /// - Parameter groupOpenCode: Whether OpenCode models use provider/model grouping.
    ///   Oh My Pi always projects hierarchically.
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
        if agentKind == .ohMyPi {
            return ohMyPiModelItems(
                options: visibleOptions,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        if agentKind == .openCode, groupOpenCode {
            return AgentModelCatalog.openCodeMenu(for: visibleOptions).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
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

    /// - Parameter groupOpenCode: Whether OpenCode models use provider/model grouping.
    ///   Oh My Pi always projects hierarchically.
    @MainActor
    static func modelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        thinkingDestination: ModelDestination,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Bool
    ) -> [StableMenuItem] {
        guard agentKind == .ohMyPi else {
            return modelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleCodexGroups: flattenSingleCodexGroups,
                groupOpenCode: groupOpenCode
            ) { agent, option in
                _ = onSelect(agent, option)
            }
        }
        return ohMyPiModelItems(
            options: visibleOptions(options, includePlaceholderDefault: includePlaceholderDefault),
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            thinkingDestination: thinkingDestination,
            onSelect: onSelect
        )
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

    static func ohMyPiModelItems(
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let projected = AgentModelOptionsMenuContent.ohMyPiProjection(for: options)

        func leafItem(_ leaf: OhMyPiModelMenuProjector.Leaf, title: String? = nil) -> StableMenuItem {
            guard let option = projected.optionsBySourceID[leaf.sourceID] else {
                return .separator
            }
            return modelItem(
                option,
                title: title ?? leaf.title,
                agentKind: .ohMyPi,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }

        func groupItems(_ group: OhMyPiModelMenuProjector.ModelGroup) -> [StableMenuItem] {
            guard group.isFamily else {
                return [group.normalLeaves.first.map { leafItem($0) } ?? .separator]
            }
            if group.shape.collapsesNormal, let normal = group.normalLeaves.first {
                var items = [leafItem(normal, title: group.title)]
                if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                    items.append(leafItem(fast, title: "\(group.title) Fast"))
                } else if !group.fastLeaves.isEmpty {
                    items.append(.submenu("\(group.title) Fast", items: group.fastLeaves.map { leafItem($0) }))
                }
                return items
            }
            var items = group.normalLeaves.map { leafItem($0) }
            if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                items.append(leafItem(fast, title: "Fast"))
            } else if !group.fastLeaves.isEmpty {
                items.append(.submenu("Fast", items: group.fastLeaves.map { leafItem($0) }))
            }
            return [.submenu(group.title, items: items)]
        }

        var items = projected.projection.rootLeaves.map { leafItem($0) }
        items.append(contentsOf: projected.projection.namespaceGroups.map { namespaceGroup in
            .submenu(namespaceGroup.namespace, items: namespaceGroup.modelGroups.flatMap(groupItems))
        })
        if let header = OhMyPiThinkingSweepStatusPresentation.headerItem(
            OhMyPiThinkingCapabilityResolver.shared.sweepStatus
        ) {
            items.insert(header, at: 0)
        }
        return items
    }

    @MainActor
    static func ohMyPiModelItems(
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        thinkingDestination: ModelDestination,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let committingSelect: (AgentProviderKind, AgentModelOption) -> Bool = { agent, option in
            onSelect(agent, option)
            return true
        }
        return ohMyPiModelItems(
            options: options,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            thinkingDestination: thinkingDestination,
            onSelect: committingSelect
        )
    }

    @MainActor
    static func ohMyPiModelItems(
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        thinkingDestination: ModelDestination,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Bool
    ) -> [StableMenuItem] {
        ohMyPiModelItems(
            options: options,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            thinkingDestinationForModel: { _ in thinkingDestination },
            onSelect: onSelect
        )
    }

    @MainActor
    static func ohMyPiModelItems(
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        thinkingDestinationForModel: @escaping (String) -> ModelDestination,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Bool
    ) -> [StableMenuItem] {
        let projected = AgentModelOptionsMenuContent.ohMyPiProjection(for: options)

        func leafItem(_ leaf: OhMyPiModelMenuProjector.Leaf, title: String? = nil) -> StableMenuItem {
            guard let option = projected.optionsBySourceID[leaf.sourceID] else {
                return .separator
            }
            guard leaf.allowsThinkingAccessory,
                  !option.isPlaceholderDefault,
                  let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: leaf.wireID)
            else {
                return modelItem(
                    option,
                    title: title ?? leaf.title,
                    agentKind: .ohMyPi,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw
                ) { agent, option in
                    _ = onSelect(agent, option)
                }
            }

            let thinkingDestination = thinkingDestinationForModel(exactModelID)
            guard thinkingDestination.hasThinkingAccessory else {
                return modelItem(
                    option,
                    title: title ?? leaf.title,
                    agentKind: .ohMyPi,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw
                ) { agent, option in
                    _ = onSelect(agent, option)
                }
            }

            return .submenu(
                title ?? leaf.title,
                isSelected: selectedAgent == .ohMyPi && AgentModelCatalog.modelOptionIsSelected(
                    optionRaw: option.rawValue,
                    selectedRaw: selectedModelRaw,
                    agentKind: .ohMyPi
                ),
                items: OhMyPiThinkingMenuBuilder.stableMenuItems(
                    exactModelID: exactModelID,
                    destination: thinkingDestination,
                    onBeforeApply: {
                        onSelect(.ohMyPi, option)
                    }
                )
            )
        }

        func groupItems(_ group: OhMyPiModelMenuProjector.ModelGroup) -> [StableMenuItem] {
            guard group.isFamily else {
                return [group.normalLeaves.first.map { leafItem($0) } ?? .separator]
            }
            if group.shape.collapsesNormal, let normal = group.normalLeaves.first {
                var items = [leafItem(normal, title: group.title)]
                if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                    items.append(leafItem(fast, title: "\(group.title) Fast"))
                } else if !group.fastLeaves.isEmpty {
                    items.append(.submenu("\(group.title) Fast", items: group.fastLeaves.map { leafItem($0) }))
                }
                return items
            }
            var items = group.normalLeaves.map { leafItem($0) }
            if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                items.append(leafItem(fast, title: "Fast"))
            } else if !group.fastLeaves.isEmpty {
                items.append(.submenu("Fast", items: group.fastLeaves.map { leafItem($0) }))
            }
            return [.submenu(group.title, items: items)]
        }

        var items = projected.projection.rootLeaves.map { leafItem($0) }
        items.append(contentsOf: projected.projection.namespaceGroups.map { namespaceGroup in
            .submenu(namespaceGroup.namespace, items: namespaceGroup.modelGroups.flatMap(groupItems))
        })
        if let header = OhMyPiThinkingSweepStatusPresentation.headerItem(
            OhMyPiThinkingCapabilityResolver.shared.sweepStatus
        ) {
            items.insert(header, at: 0)
        }
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
