import SwiftUI

struct AIModelDropdown: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @Binding var showSettingsPopover: Bool
    var windowID: Int?
    var useBorderlessStyle: Bool = true
    var isInGeneralSettings: Bool = false

    /// The destination where model selection is applied.
    /// Defaults to `.chatModel(promptVM:)` if not specified.
    let destination: ModelDestination

    private let maxModelNameLength = 40

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var menuModelSnapshot: [AIModel]? = nil
    @State private var menuSnapshotReleaseTask: Task<Void, Never>? = nil
    @State private var cursorCatalogRevision: Int = 0

    private struct ClaudeCodeTopLevelMenu {
        let displayName: String
        let models: [AIModel]
        let isCompatibleBackend: Bool
    }

    // MARK: - Initializers

    /// Primary initializer with explicit destination
    init(
        promptViewModel: PromptViewModel,
        showSettingsPopover: Binding<Bool>,
        windowID: Int? = nil,
        useBorderlessStyle: Bool = true,
        isInGeneralSettings: Bool = false,
        destination: ModelDestination
    ) {
        self.promptViewModel = promptViewModel
        _showSettingsPopover = showSettingsPopover
        self.windowID = windowID
        self.useBorderlessStyle = useBorderlessStyle
        self.isInGeneralSettings = isInGeneralSettings
        self.destination = destination
    }

    /// Convenience initializer that defaults to chat model destination
    init(
        promptViewModel: PromptViewModel,
        showSettingsPopover: Binding<Bool>,
        windowID: Int? = nil,
        useBorderlessStyle: Bool = true,
        isInGeneralSettings: Bool = false
    ) {
        self.promptViewModel = promptViewModel
        _showSettingsPopover = showSettingsPopover
        self.windowID = windowID
        self.useBorderlessStyle = useBorderlessStyle
        self.isInGeneralSettings = isInGeneralSettings
        destination = .chatModel(promptVM: promptViewModel)
    }

    var body: some View {
        Group {
            let _ = cursorCatalogRevision
            if useBorderlessStyle {
                borderlessStyleMenu
            } else {
                standardStyleMenu
            }
        }
        .onDisappear {
            menuSnapshotReleaseTask?.cancel()
            menuSnapshotReleaseTask = nil
            menuModelSnapshot = nil
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cursorModelParameterCatalogDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            cursorCatalogRevision &+= 1
        }
    }

    // MARK: - Borderless Style (nested submenus)

    private var borderlessStyleMenu: some View {
        StableMenuButton(
            items: aiModelMenuItems,
            triggerStyle: .plain,
            onOpen: beginMenuPresentationSnapshot
        ) {
            HStack(spacing: 5) {
                if selectedModelShowsFastWarning {
                    Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                    Text(truncateHeadIfNeeded(displayedModelName))
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                        .truncationMode(.head)
                } else {
                    Text(truncateHeadIfNeeded(displayedModelName))
                        .truncationMode(.head)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .fixedSize()
    }

    // MARK: - Standard Style (nested submenus via stable AppKit menu)

    private var standardStyleMenu: some View {
        StableMenuButton(
            items: aiModelMenuItems,
            onOpen: beginMenuPresentationSnapshot
        ) {
            HStack(spacing: 5) {
                if selectedModelShowsFastWarning {
                    Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                    Text(truncateHeadIfNeeded(displayedModelName))
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                } else {
                    Text(truncateHeadIfNeeded(displayedModelName))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AppKit Menu Content (Provider → Models)

    private func aiModelMenuItems() -> [StableMenuItem] {
        let allModels = menuModelSnapshot ?? promptViewModel.availableModels
        guard !allModels.isEmpty else {
            return [.action("Configure API Settings", handleConfigureAction)]
        }

        let groupedModels = Dictionary(grouping: allModels, by: { $0.providerType })
        let sortedProviders = groupedModels.keys.sorted {
            if $0 == .ohMyPi { return false }
            if $1 == .ohMyPi { return true }
            return AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }

        return sortedProviders.flatMap { provider -> [StableMenuItem] in
            let models = AIModel.sortedForPicker(groupedModels[provider] ?? [])
            if provider == .claudeCode {
                return aiModelClaudeCodeTopLevelMenuItems(for: models)
            }

            let providerItems: [StableMenuItem] = if provider == .codex {
                AIModel.codexMenuGroups(for: models).map { group in
                    StableMenuItem.submenu(
                        group.displayName,
                        items: group.models.map(aiModelMenuItem)
                    )
                }
            } else if provider == .openAI {
                models.map(aiModelOpenAIMenuItem)
            } else if provider == .cursor {
                models.map(aiModelCursorMenuItem)
            } else if provider == .openCode {
                AIModel.openCodeMenu(for: models).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
                    let modelItems = providerGroup.groups.map(aiModelOpenCodeMenuItem)
                    guard providerGroup.rendersAsSubmenu else { return modelItems }
                    return [.submenu(providerGroup.displayName, items: modelItems)]
                }
            } else if provider == .ohMyPi {
                OhMyPiModelMenuBuilder.groups(for: models).map { group in
                    .submenu(
                        group.namespace,
                        items: group.leaves.map { leaf in
                            aiModelMenuItem(leaf.model, title: leaf.title)
                        }
                    )
                }
            } else {
                models.map(aiModelMenuItem)
            }
            return [.submenu(AIProviderType.displayName(for: provider), items: providerItems)]
        }
    }

    private func aiModelClaudeCodeTopLevelMenuItems(for models: [AIModel]) -> [StableMenuItem] {
        claudeCodeTopLevelMenus(for: models).map { section in
            let items = section.isCompatibleBackend
                ? section.models.compactMap(aiModelCompatibleClaudeBackendMenuItem)
                : aiModelClaudeCodeMenuItems(for: section.models)
            return .submenu(section.displayName, items: items)
        }
    }

    private func claudeCodeTopLevelMenus(for models: [AIModel]) -> [ClaudeCodeTopLevelMenu] {
        var sections: [ClaudeCodeTopLevelMenu] = []
        let nativeModels = models.filter { ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) == nil }
        if !nativeModels.isEmpty {
            sections.append(ClaudeCodeTopLevelMenu(
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
                    let lhsRank = compatibleClaudeBackendOptionRank(lhs.1.requestedModelRaw)
                    let rhsRank = compatibleClaudeBackendOptionRank(rhs.1.requestedModelRaw)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    return lhs.1.optionDisplayName.localizedCaseInsensitiveCompare(rhs.1.optionDisplayName) == .orderedAscending
                }
                .map(\.0)
            sections.append(ClaudeCodeTopLevelMenu(
                displayName: compatibleClaudeBackendTopLevelDisplayName(for: backendID),
                models: sortedModels,
                isCompatibleBackend: true
            ))
        }
        return sections
    }

    private func aiModelClaudeCodeMenuItems(for models: [AIModel]) -> [StableMenuItem] {
        let menu = AIModel.claudeCodeMenu(for: models)
        var items: [StableMenuItem] = []
        if let defaultOption = menu.defaultOption {
            items.append(aiModelMenuItem(defaultOption))
        }
        if !items.isEmpty, !menu.groups.isEmpty {
            items.append(.separator)
        }
        items.append(contentsOf: menu.groups.compactMap(aiModelClaudeCodeMenuItem))
        return items
    }

    private func aiModelCompatibleClaudeBackendMenuItem(_ model: AIModel) -> StableMenuItem? {
        guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
        return StableMenuItem.action(
            truncateHeadIfNeeded(compatibleClaudeBackendOptionDisplayName(for: descriptor)),
            isSelected: model.rawValue == destination.currentRawValue
        ) {
            destination.apply(model.rawValue)
        }
    }

    private func compatibleClaudeBackendTopLevelDisplayName(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized.normalizedDisplayName
    }

    private func compatibleClaudeBackendOptionDisplayName(
        for descriptor: ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor
    ) -> String {
        descriptor.optionDisplayName
    }

    private func compatibleClaudeBackendOptionRank(_ rawModel: String?) -> Int {
        switch rawModel {
        case .some(AgentModel.claudeHaiku.rawValue): return 0
        case .some(AgentModel.claudeSonnet.rawValue): return 1
        case .some(AgentModel.claudeOpus.rawValue): return 2
        case let .some(raw):
            if let index = ClaudeCompatibleProviderRuntimeBridge.directSelectableGLMModelRawValues.firstIndex(of: raw) {
                return 10 + index
            }
            return 99
        case nil:
            return 99
        }
    }

    private func aiModelClaudeCodeMenuItem(_ group: AIModel.ClaudeCodePickerMenuGroup) -> StableMenuItem? {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.displayName,
                items: group.options.map(aiModelMenuItem)
            )
        }
        if let option = group.options.first {
            return aiModelMenuItem(option)
        }
        return nil
    }

    private func aiModelOpenAIMenuItem(_ model: AIModel) -> StableMenuItem {
        guard model.openAIServiceTierBase == .gpt56Sol else {
            return aiModelMenuItem(model)
        }

        let modeItems = OpenAIReasoningMode.allCases.map { mode in
            StableMenuItem.submenu(
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
                    return aiModelMenuItem(selectedModel, title: effort.displayName)
                }
            )
        }
        return .submenu(model.displayName, items: modeItems)
    }

    private func aiModelCursorMenuItem(_ model: AIModel) -> StableMenuItem {
        guard case let .cursorCustom(modelRaw) = model,
              let item = Self.cursorPresetMenuItem(
                  modelRaw: modelRaw,
                  displayName: model.displayName,
                  selectedRawValue: destination.currentRawValue,
                  onSelect: { selectedRaw in
                      destination.apply(AIModel.cursorCustom(name: selectedRaw).rawValue)
                  }
              )
        else {
            return aiModelMenuItem(model)
        }
        return item
    }

    static func cursorPresetMenuItem(
        modelRaw: String,
        displayName: String,
        selectedRawValue: String,
        catalog: CursorModelParameterCatalog = .shared,
        isEnabled: Bool = CursorParameterizedModels.isEnabled,
        onSelect: @escaping (String) -> Void = { _ in }
    ) -> StableMenuItem? {
        guard let leaves = CursorModelMenuBuilder.leaves(
            forModelRaw: modelRaw,
            dimensionSet: .preset,
            selectedModelRaw: "",
            catalog: catalog,
            isEnabled: isEnabled
        ) else {
            return nil
        }

        let selectedProviderRaw: String? = if case let .cursorCustom(raw) = AIModel.fromModelName(selectedRawValue) {
            raw
        } else {
            nil
        }
        func leafItem(_ leaf: CursorModelMenuBuilder.Leaf) -> StableMenuItem {
            let showsWarning = leaf.showsFastWarning
            return .action(
                leaf.title,
                isSelected: selectedProviderRaw.map {
                    AgentModelCatalog.modelOptionIsSelected(
                        optionRaw: leaf.rawValue,
                        selectedRaw: $0,
                        agentKind: .cursor
                    )
                } ?? false,
                imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
                style: showsWarning ? .warning : .normal,
                toolTip: showsWarning
                    ? AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
                    : nil
            ) {
                onSelect(leaf.rawValue)
            }
        }

        let sections = CursorModelMenuBuilder.sections(from: leaves)
        var items: [StableMenuItem] = []
        if let defaultSection = sections.first(where: { $0.section == .defaultSelection }) {
            items.append(contentsOf: defaultSection.leaves.map(leafItem))
        }
        let nondefaultSections = sections.filter { $0.section != .defaultSelection }
        if !items.isEmpty, !nondefaultSections.isEmpty {
            items.append(.separator)
        }
        for section in nondefaultSections {
            switch section.section {
            case .reasoning:
                items.append(contentsOf: section.leaves.map(leafItem))
            case .context:
                items.append(.submenu(
                    section.title ?? "",
                    items: section.leaves.map(leafItem)
                ))
            case .fast:
                items.append(.submenu(
                    section.title ?? "",
                    imageSystemName: AgentModelSelectionWarningVisuals.iconSystemName,
                    style: .warning,
                    toolTip: AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor),
                    items: section.leaves.map(leafItem)
                ))
            case .defaultSelection:
                break
            }
        }

        return .submenu(
            displayName,
            isSelected: selectedProviderRaw.map {
                CursorModelRegistryGate.normalizedAlias(modelRaw)
                    == CursorModelRegistryGate.normalizedAlias($0)
            } ?? false,
            items: items
        )
    }

    private func aiModelOpenCodeMenuItem(_ group: AIModel.OpenCodePickerMenuGroup) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map(aiModelMenuItem)
            )
        }
        if let option = group.options.first {
            return aiModelMenuItem(option)
        }
        return .separator
    }

    private func aiModelMenuItem(_ model: AIModel) -> StableMenuItem {
        aiModelMenuItem(model, title: model.displayName)
    }

    private func aiModelMenuItem(
        _ model: AIModel,
        title: String,
        isSelected: Bool? = nil
    ) -> StableMenuItem {
        let showsWarning = Self.cursorModelShowsFastWarning(model)
        return StableMenuItem.action(
            truncateHeadIfNeeded(title),
            isSelected: isSelected ?? (model.rawValue == destination.currentRawValue),
            imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
            style: showsWarning ? .warning : .normal,
            toolTip: showsWarning
                ? AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
                : nil
        ) {
            destination.apply(model.rawValue)
        }
    }

    private func aiModelMenuItem(_ option: AIModel.OpenCodePickerMenuOption) -> StableMenuItem {
        StableMenuItem.action(
            truncateHeadIfNeeded(option.displayName),
            isSelected: option.model.rawValue == destination.currentRawValue
        ) {
            destination.apply(option.model.rawValue)
        }
    }

    private func aiModelMenuItem(_ option: AIModel.ClaudeCodePickerMenuOption) -> StableMenuItem {
        StableMenuItem.action(
            truncateHeadIfNeeded(option.displayName),
            isSelected: option.model.rawValue == destination.currentRawValue
        ) {
            destination.apply(option.model.rawValue)
        }
    }

    // MARK: - Display Name

    private var displayedModelName: String {
        Self.displayName(
            forRawValue: destination.currentRawValue,
            destinationID: destination.id,
            availableModels: promptViewModel.availableModels,
            customOpenRouterModels: promptViewModel.apiSettingsViewModel?.customOpenRouterModels ?? [],
            compatibleClaudeBackendDisplayName: { model in
                guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
        )
    }

    @MainActor
    static func displayName(
        forRawValue currentModel: String,
        destinationID: String,
        availableModels: [AIModel],
        customOpenRouterModels: [String],
        compatibleClaudeBackendDisplayName: (AIModel) -> String? = { _ in nil }
    ) -> String {
        if let parsed = AIModel.fromModelName(currentModel),
           let ohMyPiLabel = OhMyPiModelMenuBuilder.collapsedLabel(for: parsed)
        {
            return ohMyPiLabel
        }
        if availableModels.isEmpty {
            return "No models available"
        }

        // Check custom OpenRouter models
        if let customModel = customOpenRouterModels.first(where: { currentModel == "openrouter_custom_\($0)" }) {
            return "oRouter/\(customModel)"
        }

        // Check available models
        if let selectedModel = availableModels.first(where: { $0.rawValue == currentModel }) {
            return OhMyPiModelMenuBuilder.collapsedLabel(for: selectedModel)
                ?? cursorDisplayName(selectedModel)
                ?? compatibleClaudeBackendDisplayName(selectedModel)
                ?? selectedModel.displayName
        }

        // Try parsing (handles tier variants not in current list)
        if let parsed = AIModel.fromModelName(currentModel) {
            return cursorDisplayName(parsed)
                ?? compatibleClaudeBackendDisplayName(parsed)
                ?? parsed.displayName
        }

        if destinationID == "planningModel" {
            let trimmedRawValue = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedRawValue.isEmpty ? "Select an Oracle model" : "Invalid Oracle model"
        }

        // Fallback to first available for non-Oracle destinations.
        return availableModels.first?.displayName ?? "Select a model"
    }

    private var selectedModelShowsFastWarning: Bool {
        guard let model = AIModel.fromModelName(destination.currentRawValue) else {
            return false
        }
        return Self.cursorModelShowsFastWarning(model)
    }

    private static func cursorDisplayName(_ model: AIModel) -> String? {
        guard case let .cursorCustom(modelRaw) = model else { return nil }
        return AgentModelCatalog.displayName(
            for: modelRaw,
            agentKind: .cursor,
            availability: .init(cursorAvailable: true),
            includeCursorParameterSuffix: true
        )
    }

    private static func cursorModelShowsFastWarning(_ model: AIModel) -> Bool {
        guard case let .cursorCustom(modelRaw) = model else { return false }
        return CursorModelMenuBuilder.hasFastEnabled(modelRaw)
    }

    // MARK: - Helpers

    private func truncateHeadIfNeeded(_ text: String) -> String {
        if text.count <= maxModelNameLength {
            return text
        }

        if let lastSlashIndex = text.lastIndex(of: "/") {
            let trimmedText = String(text[lastSlashIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmedText.count <= maxModelNameLength {
                return trimmedText
            }
            let startIndex = trimmedText.index(trimmedText.endIndex, offsetBy: -maxModelNameLength)
            return "…\(trimmedText[startIndex...])"
        }

        let startIndex = text.index(text.endIndex, offsetBy: -maxModelNameLength)
        return "…\(text[startIndex...])"
    }

    private func handleConfigureAction() {
        NotificationCenter.default.post(
            name: .showAPISettingsTab,
            object: nil,
            userInfo: windowID != nil ? ["windowID": windowID!] : nil
        )
    }

    @MainActor
    private func beginMenuPresentationSnapshot() {
        menuSnapshotReleaseTask?.cancel()
        menuModelSnapshot = promptViewModel.availableModels
        menuSnapshotReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            menuModelSnapshot = nil
            menuSnapshotReleaseTask = nil
        }
    }
}
