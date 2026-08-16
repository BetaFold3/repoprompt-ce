import Combine
import SwiftUI

/// AppKit-backed model picker that snapshots models at open and renders Provider → Models nesting.
/// AppKit owns tracking so catalog notifications cannot invalidate and dismiss an open menu.
struct OptimizedModelPicker: View {
    /// The destination where model selection is applied
    let destination: ModelDestination
    let availableModels: [AIModel]
    let font: Font
    let widthStyle: WidthStyle

    @State private var cursorCatalogRevision: Int = 0
    @State private var ohMyPiThinkingRevision: Int = 0
    @State private var menuModelSnapshot: [AIModel]? = nil
    @State private var menuSnapshotReleaseTask: Task<Void, Never>? = nil

    private struct ClaudeCodeTopLevelMenu: Identifiable {
        let id: String
        let displayName: String
        let models: [AIModel]
        let isCompatibleBackend: Bool
    }

    enum WidthStyle {
        case fixed(width: CGFloat, alignment: Alignment = .trailing)
        case flexible(minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, alignment: Alignment = .leading)
    }

    private var selectedLabel: String {
        let currentValue = destination.currentRawValue
        // 1. Try to find in available models
        if let match = availableModels.first(where: { $0.rawValue == currentValue }) {
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: match) {
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
            return OhMyPiModelMenuBuilder.collapsedLabel(for: match)
                ?? cursorDisplayName(match)
                ?? match.displayName
        }
        // 2. Try parsing (handles tier variants not in current list)
        if let parsed = AIModel.fromModelName(currentValue) {
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: parsed) {
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
            return OhMyPiModelMenuBuilder.collapsedLabel(for: parsed)
                ?? cursorDisplayName(parsed)
                ?? parsed.displayName
        }
        // 3. Fallback
        return currentValue.isEmpty ? "Select a model" : currentValue
    }

    // MARK: - Initializers

    /// Primary initializer with explicit destination
    init(destination: ModelDestination, availableModels: [AIModel], font: Font, widthStyle: WidthStyle = .fixed(width: 220, alignment: .trailing)) {
        self.destination = destination
        self.availableModels = availableModels
        self.font = font
        self.widthStyle = widthStyle
    }

    /// Convenience initializer with binding (creates a binding-backed destination)
    init(selection: Binding<String>, availableModels: [AIModel], font: Font, widthStyle: WidthStyle = .fixed(width: 220, alignment: .trailing)) {
        destination = .binding(selection, id: "optimizedModelPicker")
        self.availableModels = availableModels
        self.font = font
        self.widthStyle = widthStyle
    }

    var body: some View {
        // Never attach state-mutating hover or overlay modifiers to views inside menu
        // content. Hover-driven invalidation dismisses SwiftUI tracking menus; AppKit
        // tooltips belong on StableMenuItem instead.
        StableMenuButton(
            items: stableMenuItems,
            onOpen: beginMenuPresentationSnapshot
        ) {
            HStack(spacing: 6) {
                if selectedModelShowsFastWarning {
                    cursorWarningLabel(selectedLabel)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(selectedLabel)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .modifier(ControlWidthModifier(style: widthStyle))
        .onReceive(
            NotificationCenter.default.publisher(for: .cursorModelParameterCatalogDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            cursorCatalogRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .ohMyPiThinkingCapabilitiesDidChange)
                .merge(with: NotificationCenter.default.publisher(for: .ohMyPiThinkingCapabilityProbeStateDidChange))
                .receive(on: RunLoop.main)
        ) { _ in
            ohMyPiThinkingRevision &+= 1
        }
        .onDisappear {
            menuSnapshotReleaseTask?.cancel()
            menuSnapshotReleaseTask = nil
            menuModelSnapshot = nil
        }
    }

    static func codexMenuGroups(for models: [AIModel]) -> [AIModel.CodexPickerMenuGroup] {
        AIModel.codexMenuGroups(for: models)
    }

    #if DEBUG
        @MainActor
        static func stableMenuItemsForTesting(
            availableModels: [AIModel],
            selectedRawValue: String,
            onSelect: @escaping @MainActor (String) -> Void
        ) -> [StableMenuItem] {
            stableMenuItemsForTesting(
                availableModels: availableModels,
                destination: ModelDestination(
                    id: "optimizedModelPickerTest",
                    getter: { selectedRawValue },
                    applier: onSelect
                )
            )
        }

        static func stableMenuItemsForTesting(
            availableModels: [AIModel],
            destination: ModelDestination
        ) -> [StableMenuItem] {
            OptimizedModelPicker(
                destination: destination,
                availableModels: availableModels,
                font: .body
            ).stableMenuItems(for: availableModels)
        }
    #endif

    private func stableMenuItems() -> [StableMenuItem] {
        _ = cursorCatalogRevision
        _ = ohMyPiThinkingRevision
        let allModels = menuModelSnapshot ?? availableModels
        return stableMenuItems(for: allModels)
    }

    private func stableMenuItems(for allModels: [AIModel]) -> [StableMenuItem] {
        let grouped = Dictionary(grouping: allModels, by: { $0.providerType })
        let providers = grouped.keys.sorted {
            if $0 == .ohMyPi { return false }
            if $1 == .ohMyPi { return true }
            return AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }

        return providers.flatMap { provider -> [StableMenuItem] in
            let models = AIModel.sortedForPicker(grouped[provider] ?? [])
            if provider == .claudeCode {
                return claudeCodeTopLevelMenus(for: models).map { section in
                    .submenu(
                        section.displayName,
                        items: section.isCompatibleBackend
                            ? section.models.compactMap(stableCompatibleClaudeItem)
                            : stableProviderItems(provider: provider, models: section.models)
                    )
                }
            }
            return [
                .submenu(
                    AIProviderType.displayName(for: provider),
                    items: stableProviderItems(provider: provider, models: models)
                )
            ]
        }
    }

    private func stableProviderItems(
        provider: AIProviderType,
        models: [AIModel]
    ) -> [StableMenuItem] {
        if provider == .claudeCode {
            return AIModel.claudeCodeMenu(for: models).groups.compactMap { group in
                if group.rendersAsSubmenu {
                    return .submenu(
                        group.displayName,
                        items: group.options.map {
                            stableModelItem($0.model, title: $0.displayName)
                        }
                    )
                }
                guard let option = group.options.first else { return nil }
                return stableModelItem(option.model, title: option.displayName)
            }
        }
        if provider == .codex {
            return Self.codexMenuGroups(for: models).map { group in
                let showsWarning = group.models.contains(where: modelShowsFastWarning)
                return .submenu(
                    group.displayName,
                    imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
                    style: showsWarning ? .warning : .normal,
                    toolTip: showsWarning
                        ? AgentModelSelectionWarningVisuals.warningTooltip(for: .codexExec)
                        : nil,
                    items: group.models.map { stableModelItem($0) }
                )
            }
        }
        if provider == .openAI {
            return models.map(stableOpenAIItem)
        }
        if provider == .cursor {
            return models.map { model in
                guard case let .cursorCustom(modelRaw) = model,
                      let item = AIModelDropdown.cursorPresetMenuItem(
                          modelRaw: modelRaw,
                          displayName: model.displayName,
                          selectedRawValue: destination.currentRawValue,
                          onSelect: { raw in
                              destination.apply(AIModel.cursorCustom(name: raw).rawValue)
                          }
                      )
                else {
                    return stableModelItem(model)
                }
                return item
            }
        }
        if provider == .openCode {
            return AIModel.openCodeMenu(for: models).providerGroups.flatMap { providerGroup in
                let items = providerGroup.groups.compactMap(stableOpenCodeItem)
                return providerGroup.rendersAsSubmenu
                    ? [.submenu(providerGroup.displayName, items: items)]
                    : items
            }
        }
        if provider == .ohMyPi {
            let projection = OhMyPiModelMenuBuilder.projection(for: models)
            var items = projection.rootLeaves.map {
                stableModelItem($0.model, title: $0.title)
            }
            items.append(contentsOf: projection.namespaceGroups.map { namespaceGroup in
                .submenu(
                    namespaceGroup.namespace,
                    items: namespaceGroup.modelGroups.map(stableOhMyPiItem)
                )
            })
            if destination.hasThinkingAccessory,
               let exactModelID = OhMyPiThinkingMenuBuilder.exactModelID(from: destination.currentRawValue)
            {
                items.append(.separator)
                items.append(.submenu(
                    "Thinking",
                    items: OhMyPiThinkingMenuBuilder.stableMenuItems(
                        exactModelID: exactModelID,
                        destination: destination
                    )
                ))
            }
            return items
        }
        return models.map { stableModelItem($0) }
    }

    private func stableOpenAIItem(_ model: AIModel) -> StableMenuItem {
        guard model.openAIServiceTierBase == .gpt56Sol else {
            return stableModelItem(model)
        }
        return .submenu(
            model.displayName,
            items: OpenAIReasoningMode.allCases.map { mode in
                .submenu(
                    mode.displayName,
                    items: OpenAIConfiguredModelSelection.supportedEfforts.compactMap { effort in
                        guard let selection = OpenAIConfiguredModelSelection(
                            modelID: AIModel.gpt56Sol.modelName,
                            reasoningMode: mode,
                            reasoningEffort: effort
                        ) else { return nil }
                        let configured = AIModel.openAIConfigured(selection: selection)
                        let selectedModel = model.openAIServiceTierOverride.map {
                            AIModel.openAIServiceTierVariant(base: configured, tier: $0)
                        } ?? configured
                        return stableModelItem(selectedModel, title: effort.displayName)
                    }
                )
            }
        )
    }

    private func stableOpenCodeItem(_ group: AIModel.OpenCodePickerMenuGroup) -> StableMenuItem? {
        if group.rendersAsSubmenu {
            return .submenu(
                group.modelDisplayName,
                items: group.options.map {
                    stableModelItem($0.model, title: $0.displayName)
                }
            )
        }
        guard let option = group.options.first else { return nil }
        return stableModelItem(option.model, title: option.displayName)
    }

    private func stableOhMyPiItem(
        _ group: OhMyPiModelMenuBuilder.ModelGroup
    ) -> StableMenuItem {
        guard group.isFamily else {
            return group.normalLeaves.first.map {
                stableModelItem($0.model, title: $0.title)
            } ?? .separator
        }
        var items = group.normalLeaves.map {
            stableModelItem($0.model, title: $0.title)
        }
        if !group.fastLeaves.isEmpty {
            items.append(.submenu(
                "Fast",
                items: group.fastLeaves.map {
                    stableModelItem($0.model, title: $0.title)
                }
            ))
        }
        return .submenu(group.title, items: items)
    }

    private func stableCompatibleClaudeItem(_ model: AIModel) -> StableMenuItem? {
        guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else {
            return nil
        }
        return stableModelItem(
            model,
            title: compatibleClaudeBackendOptionDisplayName(for: descriptor)
        )
    }

    private func stableModelItem(_ model: AIModel, title: String? = nil) -> StableMenuItem {
        let showsWarning = modelShowsFastWarning(model)
        let warningAgent: AgentProviderKind = model.providerType == .cursor ? .cursor : .codexExec
        return .action(
            title ?? model.displayName,
            isSelected: modelIsSelected(model),
            imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
            style: showsWarning ? .warning : .normal,
            toolTip: showsWarning
                ? AgentModelSelectionWarningVisuals.warningTooltip(for: warningAgent)
                : nil
        ) {
            destination.apply(model.rawValue)
            OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(of: model)
        }
    }

    private func claudeCodeTopLevelMenus(for models: [AIModel]) -> [ClaudeCodeTopLevelMenu] {
        var sections: [ClaudeCodeTopLevelMenu] = []
        let nativeModels = models.filter { ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) == nil }
        if !nativeModels.isEmpty {
            sections.append(ClaudeCodeTopLevelMenu(
                id: "claude-code",
                displayName: AIProviderType.displayName(for: .claudeCode),
                models: nativeModels,
                isCompatibleBackend: false
            ))
        }

        let compatibleModels = models.compactMap { model -> (AIModel, ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor)? in
            guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
            return (model, descriptor)
        }
        let grouped = Dictionary(grouping: compatibleModels, by: { $0.1.backendID })
        let backendSortOrder = Dictionary(uniqueKeysWithValues: ClaudeCodeCompatibleBackendID.allCases.enumerated().map { ($0.element, $0.offset) })
        for backendID in grouped.keys.sorted(by: {
            let lhsRank = backendSortOrder[$0] ?? Int.max
            let rhsRank = backendSortOrder[$1] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return compatibleClaudeBackendTopLevelDisplayName(for: $0).localizedCaseInsensitiveCompare(
                compatibleClaudeBackendTopLevelDisplayName(for: $1)
            ) == .orderedAscending
        }) {
            let entries = grouped[backendID] ?? []
            let sortedModels = entries
                .sorted { lhs, rhs in
                    compatibleClaudeBackendOptionRank(lhs.1.requestedModelRaw) < compatibleClaudeBackendOptionRank(rhs.1.requestedModelRaw)
                }
                .map(\.0)
            sections.append(ClaudeCodeTopLevelMenu(
                id: "compatible-\(backendID.rawValue)",
                displayName: compatibleClaudeBackendTopLevelDisplayName(for: backendID),
                models: sortedModels,
                isCompatibleBackend: true
            ))
        }
        return sections
    }

    private func cursorWarningLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            Text(title)
                .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
        }
    }

    private func compatibleClaudeBackendTopLevelDisplayName(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized.normalizedDisplayName
    }

    private func compatibleClaudeBackendOptionDisplayName(
        for descriptor: ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor
    ) -> String {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: descriptor.backendID).normalized
        switch config.modelBehavior {
        case .noModel:
            return descriptor.optionDisplayName
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            let backendModelID: String? = switch descriptor.requestedModelRaw {
            case .some(AgentModel.claudeHaiku.rawValue):
                normalized.haiku
            case .some(AgentModel.claudeOpus.rawValue):
                normalized.opus
            case .some(AgentModel.claudeSonnet.rawValue), nil:
                normalized.sonnet
            default:
                nil
            }
            guard let backendModelID, !backendModelID.isEmpty else { return descriptor.optionDisplayName }
            return AgentModel(rawValue: backendModelID)?.displayName ?? backendModelID
        }
    }

    private func compatibleClaudeBackendOptionRank(_ rawModel: String?) -> Int {
        switch rawModel {
        case .some(AgentModel.claudeHaiku.rawValue): 0
        case .some(AgentModel.claudeSonnet.rawValue): 1
        case .some(AgentModel.claudeOpus.rawValue): 2
        default: 0
        }
    }

    private func modelIsSelected(_ model: AIModel) -> Bool {
        guard case let .cursorCustom(optionRaw) = model,
              case let .cursorCustom(selectedRaw) = AIModel.fromModelName(destination.currentRawValue)
        else {
            return destination.currentRawValue == model.rawValue
        }
        return AgentModelCatalog.modelOptionIsSelected(
            optionRaw: optionRaw,
            selectedRaw: selectedRaw,
            agentKind: .cursor
        )
    }

    private var selectedModelShowsFastWarning: Bool {
        guard let model = AIModel.fromModelName(destination.currentRawValue) else {
            return false
        }
        return modelShowsFastWarning(model)
    }

    private func cursorDisplayName(_ model: AIModel) -> String? {
        guard case let .cursorCustom(modelRaw) = model else { return nil }
        return AgentModelCatalog.displayName(
            for: modelRaw,
            agentKind: .cursor,
            availability: .init(cursorAvailable: true),
            includeCursorParameterSuffix: true
        )
    }

    private func cursorModelShowsFastWarning(_ model: AIModel) -> Bool {
        guard case let .cursorCustom(modelRaw) = model else { return false }
        return CursorModelMenuBuilder.hasFastEnabled(modelRaw)
    }

    private func modelShowsFastWarning(_ model: AIModel) -> Bool {
        if cursorModelShowsFastWarning(model) {
            return true
        }
        guard model.providerType == .codex else { return false }
        return AgentModelSelectionWarningVisuals.showsWarning(
            agent: .codexExec,
            rawModel: model.modelName
        )
    }

    private struct ControlWidthModifier: ViewModifier {
        let style: WidthStyle

        func body(content: Content) -> some View {
            switch style {
            case let .fixed(width, alignment):
                content.frame(width: width, alignment: alignment)
            case let .flexible(minWidth, maxWidth, alignment):
                content.frame(minWidth: minWidth, maxWidth: maxWidth, alignment: alignment)
            }
        }
    }

    @MainActor
    private func beginMenuPresentationSnapshot() {
        menuSnapshotReleaseTask?.cancel()
        menuModelSnapshot = availableModels
        menuSnapshotReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            menuModelSnapshot = nil
            menuSnapshotReleaseTask = nil
        }
    }
}
