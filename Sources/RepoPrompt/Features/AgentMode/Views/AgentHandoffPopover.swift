import AppKit
import SwiftUI

enum AgentHandoffCodexEffortMenu {
    struct Leaf: Identifiable, Hashable {
        let option: AgentModelOption
        let effort: CodexReasoningEffort?
        let title: String
        let isDefault: Bool
        let isSelected: Bool
        let showsWarning: Bool

        var id: String {
            "\(option.rawValue):\(effort?.rawValue ?? "_model")"
        }
    }

    struct Group: Identifiable, Hashable {
        let id: String
        let displayName: String
        let leaves: [Leaf]
        let showsWarning: Bool
    }

    struct Content: Hashable {
        let defaultLeaf: Leaf?
        let groups: [Group]
    }

    static func content(
        options: [AgentModelOption],
        selectedModelRaw: String,
        selectedReasoningEffortRaw: String?
    ) -> Content {
        let expanded = AgentCodexModelEffortExpansion.content(options: options)
        let defaultLeaf = expanded.defaultLeaf.map {
            leaf(
                expandedLeaf: $0,
                selectedModelRaw: selectedModelRaw,
                selectedReasoningEffortRaw: selectedReasoningEffortRaw
            )
        }
        let groups = expanded.groups.map { group in
            let leaves = group.leaves.map {
                leaf(
                    expandedLeaf: $0,
                    selectedModelRaw: selectedModelRaw,
                    selectedReasoningEffortRaw: selectedReasoningEffortRaw
                )
            }
            return Group(
                id: group.id,
                displayName: group.displayName,
                leaves: leaves,
                showsWarning: AgentModelSelectionWarningVisuals.showsWarning(
                    agent: .codexExec,
                    rawModel: group.baseModelID
                ) || leaves.contains(where: \.showsWarning)
            )
        }
        return Content(defaultLeaf: defaultLeaf, groups: groups)
    }

    static func groups(
        options: [AgentModelOption],
        selectedModelRaw: String,
        selectedReasoningEffortRaw: String?
    ) -> [Group] {
        content(
            options: options,
            selectedModelRaw: selectedModelRaw,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw
        ).groups
    }

    static func selection(for leaf: Leaf) -> AgentHandoffSelection {
        AgentHandoffSelection(
            agent: .codexExec,
            modelRaw: leaf.option.rawValue,
            reasoningEffortRaw: leaf.effort?.rawValue
        )
    }

    private static func leaf(
        expandedLeaf: AgentCodexModelEffortExpansion.Leaf,
        selectedModelRaw: String,
        selectedReasoningEffortRaw: String?
    ) -> Leaf {
        let option = expandedLeaf.option
        let effort = expandedLeaf.effort
        let isDefault = expandedLeaf.isDefault
        let encodedEffort = CodexModelSpecifier(raw: option.rawValue).reasoningEffort
        let selectedEffort = CodexReasoningEffort.parse(selectedReasoningEffortRaw)
        let effortMatches = if let encodedEffort {
            encodedEffort == selectedEffort && (effort == nil || effort == encodedEffort)
        } else if let effort {
            effort == selectedEffort
        } else {
            true
        }
        let modelMatches = AgentModelCatalog.modelOptionIsSelected(
            optionRaw: option.rawValue,
            selectedRaw: selectedModelRaw,
            agentKind: .codexExec
        )
        let title = if let effort {
            isDefault ? "\(effort.displayName) (Default)" : effort.displayName
        } else {
            option.displayName
        }
        return Leaf(
            option: option,
            effort: effort,
            title: title,
            isDefault: isDefault,
            isSelected: modelMatches && effortMatches,
            showsWarning: AgentModelSelectionWarningVisuals.showsWarning(
                agent: .codexExec,
                rawModel: option.rawValue
            )
        )
    }
}

/// Popover content for agent handoff configuration.
/// Lets the user pick destination agent/model, copy the handoff payload, or execute handoff.
struct AgentHandoffPopover: View {
    let config: AgentHandoffConfig
    let dismiss: () -> Void

    @State private var selectedAgent: AgentProviderKind
    @State private var selectedModelRaw: String
    @State private var selectedReasoningEffortRaw: String?
    @State private var remoteDestinationState: AgentHandoffRemoteDestinationState
    @State private var isLoading = false
    @State private var isCopying = false
    @State private var showCopied = false
    @State private var errorMessage: String?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(340, max: 460)
    }

    init(config: AgentHandoffConfig, dismiss: @escaping () -> Void) {
        self.config = config
        self.dismiss = dismiss
        let initialSelection = Self.initialSelection(for: config)
        _selectedAgent = State(initialValue: initialSelection.agent)
        _selectedModelRaw = State(initialValue: initialSelection.modelRaw)
        _selectedReasoningEffortRaw = State(initialValue: initialSelection.reasoningEffortRaw)
        _remoteDestinationState = State(initialValue: AgentHandoffRemoteDestinationState(
            catalog: config.remoteCatalogSnapshot,
            preferredModelID: config.defaultModelRaw
        ))
    }

    private var isRemoteDestination: Bool {
        if case .remoteCatalog = config.destinationSource {
            return true
        }
        return false
    }

    private var availableAgents: [AgentProviderKind] {
        config.availableAgentsProvider()
    }

    private var allCurrentOptions: [AgentModelOption] {
        config.modelOptionsProvider(selectedAgent)
    }

    private var selectedModelOption: AgentModelOption? {
        Self.option(matching: selectedModelRaw, for: selectedAgent, in: allCurrentOptions)
    }

    private var reasoningEffortOptions: [CodexReasoningEffort] {
        selectedModelOption?.supportedReasoningEfforts ?? []
    }

    private var showReasoningEffort: Bool {
        Self.shouldShowReasoningEffortPicker(
            agent: selectedAgent,
            modelRaw: selectedModelRaw,
            option: selectedModelOption
        )
    }

    static func shouldShowReasoningEffortPicker(
        agent: AgentProviderKind,
        modelRaw: String,
        option: AgentModelOption?
    ) -> Bool {
        agent == .codexExec
            && CodexModelSpecifier(raw: modelRaw).reasoningEffort == nil
            && !(option?.supportedReasoningEfforts.isEmpty ?? true)
    }

    private var chipColor: Color {
        Color.secondary.opacity(0.1)
    }

    private var selectedModelDisplayName: String {
        Self.selectedModelDisplayName(
            agent: selectedAgent,
            modelRaw: selectedModelRaw,
            option: selectedModelOption
        )
    }

    static func selectedModelDisplayName(
        agent: AgentProviderKind,
        modelRaw: String,
        option: AgentModelOption?
    ) -> String {
        guard agent == .cursor else {
            return option?.displayName ?? modelRaw
        }
        return AgentModelCatalog.displayName(
            for: modelRaw,
            agentKind: agent,
            availability: .init(cursorAvailable: true),
            includeCursorParameterSuffix: true
        )
    }

    private var canCopyPayload: Bool {
        !isRemoteDestination || remoteDestinationState.canCopyPayload
    }

    private var canPerformHandoff: Bool {
        if isRemoteDestination {
            return remoteDestinationState.canPerformHandoff
        }
        return availableAgents.contains(selectedAgent) && !allCurrentOptions.isEmpty
    }

    private var handoffDestination: AgentHandoffDestination? {
        if isRemoteDestination {
            return remoteDestinationState.destination
        }
        guard canPerformHandoff else { return nil }
        return .local(Self.canonicalizedSelection(AgentHandoffSelection(
            agent: selectedAgent,
            modelRaw: selectedModelRaw,
            reasoningEffortRaw: showReasoningEffort ? selectedReasoningEffortRaw : nil
        )))
    }

    private var providerChipTitle: String {
        guard availableAgents.contains(selectedAgent) else {
            return availableAgents.isEmpty ? "No connected CLI providers" : "Choose agent"
        }
        return "\(selectedAgent.displayName) \u{00B7} \(selectedModelDisplayName)"
    }

    private var selectedModelShowsFastWarning: Bool {
        AgentModelSelectionWarningVisuals.showsWarning(agent: selectedAgent, rawModel: selectedModelRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handoff to New Chat")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))

            Text("Migrates this session's context and Oracle chats to a new agent. The agent will pick up where it left off.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isRemoteDestination {
                Text("File contents come from the host tab's last stored selection.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("New Chat Agent")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundColor(.secondary)

                destinationPicker
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task {
                        isCopying = true
                        errorMessage = nil
                        switch await Self.clipboardPayloadResult(config: config) {
                        case let .success(payload):
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload, forType: .string)
                            showCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopied = false
                            }
                        case let .failure(message):
                            errorMessage = message
                        }
                        isCopying = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isCopying {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        }
                        Text(showCopied ? "Copied!" : "Copy Payload")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(showCopied ? .green : .accentColor)
                .disabled(isLoading || isCopying || !canCopyPayload)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .disabled(isLoading)

                Button {
                    Task {
                        guard let destination = handoffDestination else { return }
                        isLoading = true
                        errorMessage = nil
                        do {
                            try await Self.performCommittedHandoff(
                                destination,
                                perform: config.performHandoff
                            )
                            dismiss()
                        } catch {
                            errorMessage = Self.errorMessage(for: .handoff, error: error)
                            isLoading = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text("Handoff")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(canPerformHandoff ? Color.accentColor : Color.secondary.opacity(0.25))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isLoading || !canPerformHandoff)
            }
        }
        .padding(16)
        .frame(width: popoverWidth)
        .onAppear {
            if !isRemoteDestination {
                reconcileSelectionWithAvailability()
            }
        }
        .onChange(of: availableAgents) { _, _ in
            if !isRemoteDestination {
                reconcileSelectionWithAvailability()
            }
        }
    }

    @ViewBuilder
    private var destinationPicker: some View {
        if isRemoteDestination {
            remoteDestinationPicker
        } else {
            localDestinationPicker
        }
    }

    private var localDestinationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    if availableAgents.isEmpty {
                        Button("No connected CLI providers") {}
                            .disabled(true)
                    } else {
                        ForEach(availableAgents, id: \.self) { agent in
                            Menu(agent.displayName) {
                                handoffModelMenuContent(for: agent)
                            }
                        }
                    }
                    AgentProviderSettingsMenuSection(availableAgents: availableAgents, windowID: config.windowID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedAgent.iconName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        if selectedModelShowsFastWarning {
                            Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                                .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                        }
                        Text(providerChipTitle)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(selectedModelShowsFastWarning ? .orange : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(chipColor)
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)

                if showReasoningEffort {
                    Menu {
                        ForEach(reasoningEffortOptions, id: \.rawValue) { effort in
                            Button {
                                selectedReasoningEffortRaw = effort.rawValue
                            } label: {
                                HStack {
                                    Text(effort.rawValue.capitalized)
                                    if selectedReasoningEffortRaw == effort.rawValue {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedReasoningEffortRaw?.capitalized ?? "Default")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chipColor)
                        .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if availableAgents.isEmpty {
                Text("Connect a CLI provider in Settings before handing off to a new agent.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var remoteDestinationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    if remoteDestinationState.structuredAgentGroups.isEmpty {
                        Button("No remote destinations available") {}
                            .disabled(true)
                    } else {
                        ForEach(remoteDestinationState.structuredAgentGroups) { agent in
                            Menu(agent.name) {
                                ForEach(agent.models) { model in
                                    Button {
                                        remoteDestinationState.selectModel(
                                            agentGroupID: agent.id,
                                            modelGroupID: model.id
                                        )
                                    } label: {
                                        HStack {
                                            Text(model.displayName)
                                            if remoteDestinationState.selectedModelGroupID == model.id {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: remoteDestinationState.selectedAgentGroup?.agentKind?.iconName ?? "network")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        Text(remoteProviderChipTitle)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(chipColor)
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .disabled(remoteDestinationState.structuredAgentGroups.isEmpty)
                .fixedSize(horizontal: false, vertical: true)

                if !remoteDestinationState.effortOptions.isEmpty {
                    Menu {
                        ForEach(remoteDestinationState.effortOptions) { option in
                            Button {
                                remoteDestinationState.selectEffort(modelID: option.modelID)
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if remoteDestinationState.selectedModelID == option.modelID {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(remoteDestinationState.selectedEffortOption?.displayName ?? "Effort")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(chipColor)
                            .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if let message = remoteCatalogAvailabilityMessage {
                Text(message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var remoteProviderChipTitle: String {
        guard let agent = remoteDestinationState.selectedAgentGroup,
              let model = remoteDestinationState.selectedModelGroup
        else { return "No remote destinations" }
        return "\(agent.name) \u{00B7} \(model.displayName)"
    }

    private var remoteCatalogAvailabilityMessage: String? {
        guard let catalog = remoteDestinationState.catalog else {
            return "The host model catalog is unavailable. You can still copy the payload."
        }
        if catalog.isDegraded {
            return "The host model catalog is unavailable. You can still copy the payload."
        }
        if remoteDestinationState.structuredAgentGroups.isEmpty {
            return "This host did not expose structured handoff destinations. You can still copy the payload."
        }
        return nil
    }

    @ViewBuilder
    private func handoffModelMenuContent(for agent: AgentProviderKind) -> some View {
        let options = Self.visibleModelOptions(config.modelOptionsProvider(agent))
        if options.isEmpty {
            Button("No models available") {}
                .disabled(true)
        } else if agent == .codexExec {
            let content = AgentHandoffCodexEffortMenu.content(
                options: options,
                selectedModelRaw: selectedAgent == agent ? selectedModelRaw : "",
                selectedReasoningEffortRaw: selectedAgent == agent ? selectedReasoningEffortRaw : nil
            )
            if let defaultLeaf = content.defaultLeaf {
                handoffCodexLeafButton(defaultLeaf)
            }
            ForEach(content.groups) { group in
                Menu {
                    ForEach(group.leaves) { leaf in
                        handoffCodexLeafButton(leaf)
                    }
                } label: {
                    handoffCodexWarningLabel(
                        title: group.displayName,
                        showsWarning: group.showsWarning
                    )
                }
            }
        } else {
            AgentModelOptionsMenuContent(
                agentKind: agent,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw
            ) { agent, model in
                selectHandoffModel(model, for: agent)
                return true
            }
        }
    }

    private func handoffCodexLeafButton(_ leaf: AgentHandoffCodexEffortMenu.Leaf) -> some View {
        Button {
            selectHandoffCodexLeaf(leaf)
        } label: {
            HStack {
                handoffCodexWarningLabel(title: leaf.title, showsWarning: leaf.showsWarning)
                if leaf.isSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func handoffCodexWarningLabel(title: String, showsWarning: Bool) -> some View {
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            }
            Text(title)
                .foregroundStyle(showsWarning ? AgentModelSelectionWarningVisuals.warningColor : .primary)
        }
    }

    private func selectHandoffCodexLeaf(_ leaf: AgentHandoffCodexEffortMenu.Leaf) {
        let selection = AgentHandoffCodexEffortMenu.selection(for: leaf)
        selectedAgent = selection.agent
        selectedModelRaw = selection.modelRaw
        selectedReasoningEffortRaw = selection.reasoningEffortRaw
    }

    private func selectHandoffModel(_ model: AgentModelOption, for agent: AgentProviderKind) {
        selectedAgent = agent
        selectedModelRaw = model.rawValue
        selectedReasoningEffortRaw = agent == .codexExec
            ? Self.codexReasoningEffortRaw(
                modelRaw: model.rawValue,
                preferredReasoningEffortRaw: nil,
                option: model
            )
            : nil
    }

    private func reconcileSelectionWithAvailability() {
        let agents = availableAgents
        guard let agent = agents.contains(selectedAgent) ? selectedAgent : agents.first else { return }
        if selectedAgent != agent {
            selectedAgent = agent
        }

        let options = config.modelOptionsProvider(agent)
        guard !options.isEmpty else { return }

        let fallbackModelRaw = Self.initialModelRaw(
            for: agent,
            preferredModelRaw: agent == config.defaultDestinationAgent ? config.defaultModelRaw : nil,
            config: config
        )
        let reconciledModelRaw = Self.reconciledModelRaw(
            selectedModelRaw,
            for: agent,
            in: options,
            fallbackModelRaw: fallbackModelRaw
        )
        guard reconciledModelRaw != selectedModelRaw else { return }
        selectedModelRaw = reconciledModelRaw
        selectedReasoningEffortRaw = Self.initialReasoningEffortRaw(
            for: agent,
            modelRaw: reconciledModelRaw,
            preferredReasoningEffortRaw: agent == config.defaultDestinationAgent ? config.defaultReasoningEffortRaw : nil,
            config: config
        )
    }

    typealias Action = AgentHandoffActionSupport.Action
    typealias ClipboardPayloadResult = AgentHandoffActionSupport.ClipboardPayloadResult

    @MainActor
    static func clipboardPayloadResult(config: AgentHandoffConfig) async -> ClipboardPayloadResult {
        await AgentHandoffActionSupport.clipboardPayloadResult(config: config)
    }

    @MainActor
    static func performCommittedHandoff(
        _ destination: AgentHandoffDestination,
        defaults: UserDefaults = .standard,
        perform: @MainActor (AgentHandoffDestination) async throws -> Void
    ) async throws {
        try await AgentHandoffActionSupport.performCommittedHandoff(
            destination,
            defaults: defaults,
            perform: perform
        )
    }

    private static func canonicalizedSelection(
        _ selection: AgentHandoffSelection
    ) -> AgentHandoffSelection {
        AgentHandoffActionSupport.canonicalizedSelection(selection)
    }

    static func errorMessage(for action: Action, error: Error) -> String {
        AgentHandoffActionSupport.errorMessage(for: action, error: error)
    }

    static func initialSelection(for config: AgentHandoffConfig) -> AgentHandoffSelection {
        let agents = config.availableAgentsProvider()
        let agent = agents.contains(config.defaultDestinationAgent)
            ? config.defaultDestinationAgent
            : (agents.first ?? config.defaultDestinationAgent)
        let modelRaw = initialModelRaw(
            for: agent,
            preferredModelRaw: agent == config.defaultDestinationAgent ? config.defaultModelRaw : nil,
            config: config
        )
        let reasoningEffortRaw = initialReasoningEffortRaw(
            for: agent,
            modelRaw: modelRaw,
            preferredReasoningEffortRaw: agent == config.defaultDestinationAgent ? config.defaultReasoningEffortRaw : nil,
            config: config
        )
        return AgentHandoffSelection(agent: agent, modelRaw: modelRaw, reasoningEffortRaw: reasoningEffortRaw)
    }

    static func initialModelRaw(
        for agent: AgentProviderKind,
        preferredModelRaw: String?,
        config: AgentHandoffConfig
    ) -> String {
        let options = config.modelOptionsProvider(agent)
        if let preferredModelRaw,
           let option = option(matching: preferredModelRaw, for: agent, in: options)
        {
            return agent == .cursor ? preferredModelRaw : option.rawValue
        }
        return visibleModelOptions(options).first?.rawValue
            ?? options.first?.rawValue
            ?? preferredModelRaw
            ?? config.defaultModelRaw
    }

    private static func initialReasoningEffortRaw(
        for agent: AgentProviderKind,
        modelRaw: String,
        preferredReasoningEffortRaw: String?,
        config: AgentHandoffConfig
    ) -> String? {
        guard agent == .codexExec else { return nil }
        let option = option(matching: modelRaw, for: agent, in: config.modelOptionsProvider(agent))
        return codexReasoningEffortRaw(
            modelRaw: modelRaw,
            preferredReasoningEffortRaw: preferredReasoningEffortRaw,
            option: option
        )
    }

    static func codexReasoningEffortRaw(
        modelRaw: String,
        preferredReasoningEffortRaw: String?,
        option: AgentModelOption?
    ) -> String {
        if let encodedEffort = CodexModelSpecifier(raw: modelRaw).reasoningEffort {
            return encodedEffort.rawValue
        }
        let supportedEfforts = option?.supportedReasoningEfforts ?? []
        func acceptedRaw(_ effort: CodexReasoningEffort?) -> String? {
            guard let effort else { return nil }
            guard supportedEfforts.isEmpty || supportedEfforts.contains(effort) else { return nil }
            return effort.rawValue
        }

        return acceptedRaw(CodexReasoningEffort.parse(preferredReasoningEffortRaw))
            ?? acceptedRaw(option?.defaultReasoningEffort)
            ?? acceptedRaw(CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: modelRaw))
            ?? acceptedRaw(.medium)
            ?? supportedEfforts.first?.rawValue
            ?? CodexReasoningEffort.medium.rawValue
    }

    private static func visibleModelOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        let filtered = options.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? options : filtered
    }

    static func reconciledModelRaw(
        _ currentRaw: String,
        for agent: AgentProviderKind,
        in options: [AgentModelOption],
        fallbackModelRaw: String
    ) -> String {
        option(matching: currentRaw, for: agent, in: options) == nil
            ? fallbackModelRaw
            : currentRaw
    }

    static func option(
        matching rawValue: String,
        for agent: AgentProviderKind,
        in options: [AgentModelOption]
    ) -> AgentModelOption? {
        AgentModelCatalog.modelOption(
            matching: rawValue,
            for: agent,
            in: options
        )
    }
}
