import AppKit
import SwiftUI

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
        Self.option(matching: selectedModelRaw, in: allCurrentOptions)
    }

    private var reasoningEffortOptions: [CodexReasoningEffort] {
        selectedModelOption?.supportedReasoningEfforts ?? []
    }

    private var showReasoningEffort: Bool {
        selectedAgent == .codexExec && !reasoningEffortOptions.isEmpty
    }

    private var chipColor: Color {
        Color.secondary.opacity(0.1)
    }

    private var selectedModelDisplayName: String {
        selectedModelOption?.displayName ?? selectedModelRaw
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
        return .local(AgentHandoffSelection(
            agent: selectedAgent,
            modelRaw: selectedModelRaw,
            reasoningEffortRaw: showReasoningEffort ? selectedReasoningEffortRaw : nil
        ))
    }

    private var providerChipTitle: String {
        guard availableAgents.contains(selectedAgent) else {
            return availableAgents.isEmpty ? "No connected CLI providers" : "Choose agent"
        }
        return "\(selectedAgent.displayName) \u{00B7} \(selectedModelDisplayName)"
    }

    private var isSelectedCodexFastModel: Bool {
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
                            try await config.performHandoff(destination)
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
                        if isSelectedCodexFastModel {
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
                    .foregroundColor(isSelectedCodexFastModel ? .orange : .secondary)
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
        } else {
            AgentModelOptionsMenuContent(
                agentKind: agent,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw
            ) { agent, model in
                selectHandoffModel(model, for: agent)
            }
        }
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
        guard Self.option(matching: selectedModelRaw, in: options) == nil else { return }

        let fallbackModelRaw = Self.initialModelRaw(
            for: agent,
            preferredModelRaw: agent == config.defaultDestinationAgent ? config.defaultModelRaw : nil,
            config: config
        )
        selectedModelRaw = fallbackModelRaw
        selectedReasoningEffortRaw = Self.initialReasoningEffortRaw(
            for: agent,
            modelRaw: fallbackModelRaw,
            preferredReasoningEffortRaw: agent == config.defaultDestinationAgent ? config.defaultReasoningEffortRaw : nil,
            config: config
        )
    }

    enum Action: Equatable {
        case copyPayload
        case handoff
    }

    enum ClipboardPayloadResult: Equatable {
        case success(String)
        case failure(String)
    }

    @MainActor
    static func clipboardPayloadResult(config: AgentHandoffConfig) async -> ClipboardPayloadResult {
        do {
            return try await .success(config.buildPayloadForClipboard())
        } catch {
            return .failure(errorMessage(for: .copyPayload, error: error))
        }
    }

    static func errorMessage(for action: Action, error: Error) -> String {
        if let remoteError = error as? RemoteClientError,
           case let .inDoubt(commandError) = remoteError
        {
            let detail = commandError.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if action == .copyPayload {
                let suffix = detail.isEmpty
                    ? "The host did not confirm whether payload extraction completed."
                    : detail
                return "Copy Payload outcome is uncertain (in doubt). \(suffix)"
            }
            let suffix = detail.isEmpty ? "The host may already have created the fork." : detail
            return "Handoff outcome is uncertain (in doubt). \(suffix) Check remote sessions before retrying."
        }
        let prefix = action == .copyPayload ? "Copy Payload failed" : "Handoff failed"
        return "\(prefix): \(error.localizedDescription)"
    }

    private static func initialSelection(for config: AgentHandoffConfig) -> AgentHandoffSelection {
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

    private static func initialModelRaw(
        for agent: AgentProviderKind,
        preferredModelRaw: String?,
        config: AgentHandoffConfig
    ) -> String {
        let options = config.modelOptionsProvider(agent)
        if let preferredModelRaw,
           let option = option(matching: preferredModelRaw, in: options)
        {
            return option.rawValue
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
        let option = option(matching: modelRaw, in: config.modelOptionsProvider(agent))
        return codexReasoningEffortRaw(
            modelRaw: modelRaw,
            preferredReasoningEffortRaw: preferredReasoningEffortRaw,
            option: option
        )
    }

    private static func codexReasoningEffortRaw(
        modelRaw: String,
        preferredReasoningEffortRaw: String?,
        option: AgentModelOption?
    ) -> String {
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

    private static func option(matching rawValue: String, in options: [AgentModelOption]) -> AgentModelOption? {
        options.first { $0.rawValue.caseInsensitiveCompare(rawValue) == .orderedSame }
    }
}
