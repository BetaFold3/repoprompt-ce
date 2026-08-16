import Foundation

struct AgentModelSelectionLeafID: Hashable {
    enum Source: Hashable {
        case local
        case remote(hostID: String)
    }

    let source: Source
    let agentRaw: String
    let modelRaw: String
    let effortRaw: String?

    fileprivate var deterministicSortKey: String {
        let sourceKey = switch source {
        case .local:
            "local"
        case let .remote(hostID):
            "remote:\(hostID)"
        }
        return [sourceKey, agentRaw, modelRaw, effortRaw ?? ""]
            .joined(separator: "\u{001F}")
    }
}

enum AgentModelSelectionCommitPayload: Hashable {
    case local(
        agent: AgentProviderKind,
        modelRaw: String,
        reasoningEffortRaw: String?
    )
    case remote(
        agentID: String,
        modelID: String,
        effort: String?
    )
    case hostDefault(hostID: String)
}

struct AgentModelSelectionLeaf: Identifiable, Hashable {
    let id: AgentModelSelectionLeafID
    let commitPayload: AgentModelSelectionCommitPayload
    let title: String
    let providerSubtitle: String
    let detail: String?
    let showsWarning: Bool
    let isCurrentSelection: Bool
    let catalogOrder: Int
    let searchFields: AgentSessionSearchFields

    static func == (lhs: AgentModelSelectionLeaf, rhs: AgentModelSelectionLeaf) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    fileprivate func withCurrentSelection(_ isCurrentSelection: Bool) -> AgentModelSelectionLeaf {
        AgentModelSelectionLeaf(
            id: id,
            commitPayload: commitPayload,
            title: title,
            providerSubtitle: providerSubtitle,
            detail: detail,
            showsWarning: showsWarning,
            isCurrentSelection: isCurrentSelection,
            catalogOrder: catalogOrder,
            searchFields: searchFields
        )
    }
}

struct AgentModelSelectionLocalSelection: Hashable {
    let agent: AgentProviderKind
    let modelRaw: String
    let reasoningEffortRaw: String?
}

/// Pure, snapshot-backed search index for model-selection leaves.
///
/// Catalog discovery happens before construction, and selection preferences are an
/// explicit input. Query ranking is string-in / rows-out and performs no provider,
/// process, network, preference, or SwiftUI work.
struct AgentModelSelectionIndex {
    let leaves: [AgentModelSelectionLeaf]

    var currentSelectionID: AgentModelSelectionLeafID? {
        leaves.first(where: \.isCurrentSelection)?.id
    }

    init(leaves: [AgentModelSelectionLeaf]) {
        self.leaves = Self.deduplicated(leaves)
    }

    static func local(
        agents: [AgentProviderKind],
        optionsByAgent: [AgentProviderKind: [AgentModelOption]],
        selected: AgentModelSelectionLocalSelection?,
        selectionDefaults: UserDefaults,
        codexFallbackEffort: ((AgentModelOption) -> CodexReasoningEffort?)? = nil
    ) -> AgentModelSelectionIndex {
        let resolvedCodexFallbackEffort = codexFallbackEffort ?? { option in
            CodexAgentToolPreferences.lastUsedReasoningEffort(
                forModelRaw: option.rawValue,
                defaults: selectionDefaults
            ) ?? option.defaultReasoningEffort ?? .medium
        }
        var leaves: [AgentModelSelectionLeaf] = []
        var catalogOrder = 0

        for agent in agents {
            let options = optionsByAgent[agent] ?? []
            switch agent {
            case .codexExec:
                let content = AgentCodexModelEffortExpansion.content(options: options)
                if let defaultLeaf = content.defaultLeaf {
                    leaves.append(localCodexLeaf(
                        defaultLeaf,
                        groupDisplayName: defaultLeaf.option.displayName,
                        selected: selected,
                        selectionDefaults: selectionDefaults,
                        catalogOrder: catalogOrder,
                        fallbackEffort: resolvedCodexFallbackEffort
                    ))
                    catalogOrder += 1
                }
                for group in content.groups {
                    for leaf in group.leaves {
                        leaves.append(localCodexLeaf(
                            leaf,
                            groupDisplayName: group.displayName,
                            selected: selected,
                            selectionDefaults: selectionDefaults,
                            catalogOrder: catalogOrder,
                            fallbackEffort: resolvedCodexFallbackEffort
                        ))
                        catalogOrder += 1
                    }
                }

            case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
                let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: agent)
                if let defaultOption = menu.defaultOption {
                    leaves.append(localOptionLeaf(
                        agent: agent,
                        option: defaultOption,
                        title: defaultOption.displayName,
                        baseDisplayName: defaultOption.displayName,
                        effortDisplayName: nil,
                        selected: selected,
                        selectionDefaults: selectionDefaults,
                        catalogOrder: catalogOrder
                    ))
                    catalogOrder += 1
                }
                for group in menu.groups {
                    for option in group.options {
                        let effort = ClaudeModelSpecifier(raw: option.rawValue).effortLevel
                        leaves.append(localOptionLeaf(
                            agent: agent,
                            option: option,
                            title: option.displayName,
                            baseDisplayName: group.displayName,
                            effortDisplayName: effort?.displayName,
                            selected: selected,
                            selectionDefaults: selectionDefaults,
                            catalogOrder: catalogOrder
                        ))
                        catalogOrder += 1
                    }
                }

            case .openCode:
                let menu = AgentModelCatalog.openCodeMenu(for: options)
                for providerGroup in menu.providerGroups {
                    for group in providerGroup.groups {
                        for menuOption in group.options {
                            let variant = menuOption.variantDisplayName
                            let title: String = if group.rendersAsSubmenu,
                                                   let variant,
                                                   variant.caseInsensitiveCompare("Default") != .orderedSame
                            {
                                "\(group.modelDisplayName) \(variant)"
                            } else {
                                group.modelDisplayName
                            }
                            let providerDetail = providerGroup.rendersAsSubmenu
                                ? providerGroup.displayName
                                : nil
                            leaves.append(localOptionLeaf(
                                agent: agent,
                                option: menuOption.option,
                                title: title,
                                baseDisplayName: group.modelDisplayName,
                                effortDisplayName: variant,
                                providerDetail: providerDetail,
                                selected: selected,
                                selectionDefaults: selectionDefaults,
                                catalogOrder: catalogOrder
                            ))
                            catalogOrder += 1
                        }
                    }
                }

            case .ohMyPi:
                let indexed = options.enumerated().map {
                    (sourceID: String($0.offset), option: $0.element)
                }
                let optionsBySourceID = Dictionary(
                    uniqueKeysWithValues: indexed.map { ($0.sourceID, $0.option) }
                )
                let projection = OhMyPiModelMenuProjector.project(indexed.map {
                    OhMyPiModelMenuProjector.Input(
                        sourceID: $0.sourceID,
                        wireID: $0.option.rawValue,
                        displayName: $0.option.displayName
                    )
                })

                func appendProjectedLeaf(
                    _ leaf: OhMyPiModelMenuProjector.Leaf,
                    group: OhMyPiModelMenuProjector.ModelGroup?,
                    namespace: String?
                ) {
                    guard let option = optionsBySourceID[leaf.sourceID] else { return }
                    let isFamily = group?.isFamily == true
                    let variant = isFamily
                        ? (leaf.isFast ? "Fast \(leaf.title)" : leaf.title)
                        : nil
                    let title = if isFamily, leaf.isFast,
                                   leaf.title.caseInsensitiveCompare("Default") == .orderedSame
                    {
                        "\(group?.title ?? leaf.title) Fast"
                    } else if isFamily,
                              leaf.title.caseInsensitiveCompare("Default") != .orderedSame
                    {
                        "\(group?.title ?? leaf.title) \(variant ?? leaf.title)"
                    } else {
                        group?.title ?? leaf.title
                    }
                    leaves.append(localOptionLeaf(
                        agent: agent,
                        option: option,
                        title: title,
                        baseDisplayName: group?.title ?? leaf.title,
                        effortDisplayName: variant,
                        providerDetail: namespace,
                        selected: selected,
                        selectionDefaults: selectionDefaults,
                        catalogOrder: catalogOrder
                    ))
                    catalogOrder += 1
                }

                for leaf in projection.rootLeaves {
                    appendProjectedLeaf(leaf, group: nil, namespace: nil)
                }
                for namespaceGroup in projection.namespaceGroups {
                    for group in namespaceGroup.modelGroups {
                        for leaf in group.normalLeaves {
                            appendProjectedLeaf(leaf, group: group, namespace: namespaceGroup.namespace)
                        }
                        for leaf in group.fastLeaves {
                            appendProjectedLeaf(leaf, group: group, namespace: namespaceGroup.namespace)
                        }
                    }
                }

            case .cursor:
                let visibleOptions = placeholderFallbackOptions(options)
                for option in visibleOptions {
                    let leafModelRaw = cursorCurrentLeafRaw(
                        catalogOptionRaw: option.rawValue,
                        selected: selected
                    ) ?? option.rawValue
                    leaves.append(localOptionLeaf(
                        agent: agent,
                        option: option,
                        modelRawOverride: leafModelRaw,
                        title: option.displayName,
                        baseDisplayName: option.displayName,
                        effortDisplayName: nil,
                        selected: selected,
                        selectionDefaults: selectionDefaults,
                        catalogOrder: catalogOrder
                    ))
                    catalogOrder += 1
                }
            }
        }

        return AgentModelSelectionIndex(leaves: markOnlyFirstCurrent(leaves))
    }

    static func remote(
        hostID: String,
        hostDisplayName: String?,
        catalog: RemoteHostAgentCatalog?,
        includeHostDefault: Bool,
        selectedModelID: String?
    ) -> AgentModelSelectionIndex {
        var leaves: [AgentModelSelectionLeaf] = []
        var catalogOrder = 0

        if includeHostDefault {
            let modelID = RemoteHostAgentCatalog.hostDefaultModelID
            leaves.append(AgentModelSelectionLeaf(
                id: AgentModelSelectionLeafID(
                    source: .remote(hostID: hostID),
                    agentRaw: "_host",
                    modelRaw: modelID,
                    effortRaw: nil
                ),
                commitPayload: .hostDefault(hostID: hostID),
                title: RemoteHostAgentCatalog.hostDefaultDisplayName,
                providerSubtitle: "Remote",
                detail: hostDisplayName,
                showsWarning: false,
                isCurrentSelection: selectedModelID == modelID,
                catalogOrder: catalogOrder,
                searchFields: AgentSessionSearchFields(
                    title: nil,
                    primary: ["Remote"],
                    model: [RemoteHostAgentCatalog.hostDefaultDisplayName],
                    secondary: [hostDisplayName],
                    identifier: [hostID, modelID]
                )
            ))
            catalogOrder += 1
        }

        guard let catalog, !catalog.isDegraded else {
            return AgentModelSelectionIndex(leaves: markOnlyFirstCurrent(leaves))
        }

        for agentGroup in catalog.structuredAgentGroups {
            guard let agentID = agentGroup.agentID, !agentID.isEmpty else { continue }
            for modelGroup in agentGroup.models {
                for option in modelGroup.options {
                    let effortDisplayName = option.effort == nil ? nil : option.displayName
                    let title = effortDisplayName.map { "\(modelGroup.displayName) \($0)" }
                        ?? modelGroup.displayName
                    let showsWarning = switch agentGroup.agentKind {
                    case .codexExec:
                        CodexServiceTierVariantCatalog.isFastVariant(rawModel: modelGroup.baseModelID)
                            || CodexServiceTierVariantCatalog.isFastVariant(rawModel: option.modelID)
                    case .cursor:
                        CursorModelMenuBuilder.hasFastEnabled(option.modelID)
                    default:
                        false
                    }
                    leaves.append(AgentModelSelectionLeaf(
                        id: AgentModelSelectionLeafID(
                            source: .remote(hostID: hostID),
                            agentRaw: agentID,
                            modelRaw: option.modelID,
                            effortRaw: option.effort
                        ),
                        commitPayload: .remote(
                            agentID: agentID,
                            modelID: option.modelID,
                            effort: option.effort
                        ),
                        title: title,
                        providerSubtitle: agentGroup.name,
                        detail: hostDisplayName.map { "Remote · \($0)" } ?? "Remote",
                        showsWarning: showsWarning,
                        isCurrentSelection: selectedModelID == option.modelID,
                        catalogOrder: catalogOrder,
                        searchFields: AgentSessionSearchFields(
                            title: nil,
                            primary: [agentGroup.name],
                            model: [title, modelGroup.displayName, effortDisplayName],
                            secondary: ["Remote", hostDisplayName],
                            identifier: [hostID, agentID, modelGroup.baseModelID, option.modelID, option.effort]
                        )
                    ))
                    catalogOrder += 1
                }
            }
        }

        return AgentModelSelectionIndex(leaves: markOnlyFirstCurrent(leaves))
    }

    func ranked(query rawQuery: String?) -> [AgentModelSelectionLeaf] {
        let query = AgentSessionSearchQuery.parse(rawQuery)
        guard !query.isEmpty else {
            return leaves.sorted(by: Self.catalogOrderPrecedes)
        }

        return leaves.compactMap { leaf -> (AgentModelSelectionLeaf, AgentSessionSearchScore)? in
            guard let score = AgentSessionSearchMatcher.score(query: query, fields: leaf.searchFields) else {
                return nil
            }
            return (leaf, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return Self.catalogOrderPrecedes(lhs.0, rhs.0)
        }
        .map(\.0)
    }

    private static func localCodexLeaf(
        _ expandedLeaf: AgentCodexModelEffortExpansion.Leaf,
        groupDisplayName: String,
        selected: AgentModelSelectionLocalSelection?,
        selectionDefaults: UserDefaults,
        catalogOrder: Int,
        fallbackEffort: (AgentModelOption) -> CodexReasoningEffort?
    ) -> AgentModelSelectionLeaf {
        let option = expandedLeaf.option
        let modelMatches = selected?.agent == .codexExec
            && AgentModelCatalog.modelOptionIsSelected(
                optionRaw: option.rawValue,
                selectedRaw: selected?.modelRaw ?? "",
                agentKind: .codexExec,
                defaults: selectionDefaults
            )
        let selectedEffort = CodexReasoningEffort.parse(selected?.reasoningEffortRaw)
        let encodedEffort = CodexModelSpecifier(raw: option.rawValue).reasoningEffort
        let currentEffortMatches: Bool = if let encodedEffort {
            selectedEffort == encodedEffort
                && (expandedLeaf.effort == nil || expandedLeaf.effort == encodedEffort)
        } else if let effort = expandedLeaf.effort {
            selectedEffort == effort
        } else {
            true
        }

        let resolvedEffort = expandedLeaf.effort
            ?? (modelMatches ? selectedEffort : nil)
            ?? fallbackEffort(option)
            ?? .medium
        let title: String = if expandedLeaf.effort != nil {
            "\(groupDisplayName) \(resolvedEffort.displayName)"
        } else {
            groupDisplayName
        }

        return AgentModelSelectionLeaf(
            id: AgentModelSelectionLeafID(
                source: .local,
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: option.rawValue,
                effortRaw: resolvedEffort.rawValue
            ),
            commitPayload: .local(
                agent: .codexExec,
                modelRaw: option.rawValue,
                reasoningEffortRaw: resolvedEffort.rawValue
            ),
            title: title,
            providerSubtitle: AgentProviderKind.codexExec.displayName,
            detail: option.description,
            showsWarning: CodexServiceTierVariantCatalog.isFastVariant(rawModel: option.rawValue),
            isCurrentSelection: modelMatches && currentEffortMatches,
            catalogOrder: catalogOrder,
            searchFields: AgentSessionSearchFields(
                title: nil,
                primary: [AgentProviderKind.codexExec.displayName],
                model: [title, groupDisplayName, resolvedEffort.displayName],
                secondary: [option.description],
                identifier: [
                    AgentProviderKind.codexExec.rawValue,
                    option.rawValue,
                    resolvedEffort.rawValue
                ]
            )
        )
    }

    private static func localOptionLeaf(
        agent: AgentProviderKind,
        option: AgentModelOption,
        modelRawOverride: String? = nil,
        title: String,
        baseDisplayName: String,
        effortDisplayName: String?,
        providerDetail: String? = nil,
        selected: AgentModelSelectionLocalSelection?,
        selectionDefaults: UserDefaults,
        catalogOrder: Int
    ) -> AgentModelSelectionLeaf {
        let modelRaw = modelRawOverride ?? option.rawValue
        let isCurrent = selected?.agent == agent
            && AgentModelCatalog.modelOptionIsSelected(
                optionRaw: modelRaw,
                selectedRaw: selected?.modelRaw ?? "",
                agentKind: agent,
                defaults: selectionDefaults
            )
        let showsWarning = switch agent {
        case .codexExec:
            CodexServiceTierVariantCatalog.isFastVariant(rawModel: modelRaw)
        case .cursor:
            CursorModelMenuBuilder.hasFastEnabled(modelRaw)
        default:
            false
        }
        return AgentModelSelectionLeaf(
            id: AgentModelSelectionLeafID(
                source: .local,
                agentRaw: agent.rawValue,
                modelRaw: modelRaw,
                effortRaw: ClaudeModelSpecifier(raw: modelRaw).effortLevel?.rawValue
            ),
            commitPayload: .local(
                agent: agent,
                modelRaw: modelRaw,
                reasoningEffortRaw: nil
            ),
            title: title,
            providerSubtitle: agent.displayName,
            detail: providerDetail ?? option.description,
            showsWarning: showsWarning,
            isCurrentSelection: isCurrent,
            catalogOrder: catalogOrder,
            searchFields: AgentSessionSearchFields(
                title: nil,
                primary: [agent.displayName],
                model: [title, baseDisplayName, effortDisplayName],
                secondary: [providerDetail, option.description],
                identifier: [agent.rawValue, modelRaw]
            )
        )
    }

    private static func cursorCurrentLeafRaw(
        catalogOptionRaw: String,
        selected: AgentModelSelectionLocalSelection?
    ) -> String? {
        guard selected?.agent == .cursor,
              let selectedModelRaw = selected?.modelRaw,
              let catalogOption = CursorBracketModelID.parse(
                  CursorBracketModelID.strippingCursorPrefix(catalogOptionRaw)
              ),
              !catalogOption.hasBracket,
              let selectedModel = CursorBracketModelID.parse(
                  CursorBracketModelID.strippingCursorPrefix(selectedModelRaw)
              ),
              selectedModel.hasBracket
        else {
            return nil
        }
        let catalogBase = CursorModelRegistryGate.normalizedAlias(catalogOption.base)
        let selectedBase = CursorModelRegistryGate.normalizedAlias(selectedModel.base)
        guard catalogBase == selectedBase else { return nil }
        return selectedModelRaw
    }

    private static func placeholderFallbackOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        let filtered = options.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? options : filtered
    }

    private static func markOnlyFirstCurrent(
        _ leaves: [AgentModelSelectionLeaf]
    ) -> [AgentModelSelectionLeaf] {
        var markedCurrent = false
        return leaves.map { leaf in
            guard leaf.isCurrentSelection, !markedCurrent else {
                return leaf.withCurrentSelection(false)
            }
            markedCurrent = true
            return leaf
        }
    }

    private static func deduplicated(
        _ leaves: [AgentModelSelectionLeaf]
    ) -> [AgentModelSelectionLeaf] {
        var seen: Set<AgentModelSelectionLeafID> = []
        return leaves.filter { seen.insert($0.id).inserted }
    }

    private static func catalogOrderPrecedes(
        _ lhs: AgentModelSelectionLeaf,
        _ rhs: AgentModelSelectionLeaf
    ) -> Bool {
        if lhs.catalogOrder != rhs.catalogOrder {
            return lhs.catalogOrder < rhs.catalogOrder
        }
        let lhsKey = lhs.id.deterministicSortKey
        let rhsKey = rhs.id.deterministicSortKey
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        return lhs.title < rhs.title
    }
}

/// Models-layer expansion of Codex catalog options into concrete option × effort leaves.
///
/// This retains raw provider identifiers and contains no SwiftUI warning or row styling.
enum AgentCodexModelEffortExpansion {
    struct Leaf: Hashable {
        let option: AgentModelOption
        let effort: CodexReasoningEffort?
        let isDefault: Bool
    }

    struct Group: Hashable {
        let id: String
        let baseModelID: String
        let displayName: String
        let leaves: [Leaf]
    }

    struct Content: Hashable {
        let defaultLeaf: Leaf?
        let groups: [Group]
    }

    static func content(options: [AgentModelOption]) -> Content {
        let menu = AgentModelCatalog.codexMenu(for: options)
        let defaultLeaf = menu.defaultOption.map {
            Leaf(
                option: $0,
                effort: CodexModelSpecifier(raw: $0.rawValue).reasoningEffort,
                isDefault: true
            )
        }
        let groups = menu.groups.map { group in
            let leaves = group.options.flatMap { option -> [Leaf] in
                let encodedEffort = CodexModelSpecifier(raw: option.rawValue).reasoningEffort
                guard encodedEffort == nil, !option.supportedReasoningEfforts.isEmpty else {
                    return [Leaf(
                        option: option,
                        effort: encodedEffort,
                        isDefault: option.isProviderDefault
                            || (encodedEffort != nil && option.defaultReasoningEffort == encodedEffort)
                    )]
                }
                return option.supportedReasoningEfforts.map { effort in
                    Leaf(
                        option: option,
                        effort: effort,
                        isDefault: option.defaultReasoningEffort == effort
                    )
                }
            }
            return Group(
                id: group.id,
                baseModelID: group.baseModelID,
                displayName: group.displayName,
                leaves: leaves
            )
        }
        return Content(defaultLeaf: defaultLeaf, groups: groups)
    }
}
