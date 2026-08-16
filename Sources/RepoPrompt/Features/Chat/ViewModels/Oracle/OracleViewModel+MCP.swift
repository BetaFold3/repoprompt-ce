import Foundation
import MCP // <- required for `Value`

// MARK: - MCP Tool helpers (moved from MCPServerViewModel)

extension OracleViewModel {
    enum OracleSelectionMode: String, Equatable {
        case current
        case none
        case explicitSlices = "explicit_slices"
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Model Selection

    /// How the model for this send was determined.
    ///
    /// `inherited` is distinct on purpose: reporting an inherited continuation as `automatic`
    /// would be indistinguishable from the wrong-lane defect this resolution exists to fix,
    /// and reporting it as `explicit` would claim the caller passed a `model` it did not pass.
    private enum ModelSelectionKind: String {
        case explicit
        case automatic
        case inherited
    }

    /// Encapsulates the result of model selection.
    private struct ModelSelectionResult {
        let model: AIModel
        let mcpControlInfo: String?
        let selectionKind: ModelSelectionKind
        let chatPresetID: UUID? // The chat preset to use for this mode (always resolved now)
        let modelSource: String
        let modelPresetID: UUID?
        let modelPresetName: String?

        init(
            model: AIModel,
            mcpControlInfo: String?,
            selectionKind: ModelSelectionKind,
            chatPresetID: UUID?,
            modelSource: String = "planning_model",
            modelPresetID: UUID? = nil,
            modelPresetName: String? = nil
        ) {
            self.model = model
            self.mcpControlInfo = mcpControlInfo
            self.selectionKind = selectionKind
            self.chatPresetID = chatPresetID
            self.modelSource = modelSource
            self.modelPresetID = modelPresetID
            self.modelPresetName = modelPresetName
        }
    }

    /// Durable lane attribution read from an explicitly continued chat.
    ///
    /// Used to keep a `chat_id` continuation on the model the conversation was opened with.
    private struct OracleLaneAttribution {
        let modelPresetID: UUID?
        let modelRawValue: String?
        let hasMessages: Bool

        init(session: ChatSession) {
            modelPresetID = session.lastSendModelPresetID
            modelRawValue = session.lastSendModelID
            hasMessages = session.hasMessages
        }
    }

    private enum ModelPresetMatchPolicy {
        case fuzzyAllowed
        case exactOnly
    }

    enum OracleSendPackagingProvenance: Equatable {
        case direct
        case delegated(delegationID: UUID)
    }

    /// Immutable prompt-packaging inputs. These may be source-owned by a launching tab while
    /// `OracleSendTabContext` remains owned by the exact child conversation/session/run.
    struct OracleSendPackagingContext {
        let sourceTabID: UUID
        let sourceWorkspaceID: UUID?
        let sourceSelectionRevision: UInt64
        let sourceAgentSessionID: UUID?
        let sourceAgentRunID: UUID?
        let promptText: String
        let selection: StoredSelection
        let lookupContext: WorkspaceLookupContext?
        let reviewGitContext: FrozenPromptGitReviewContext
        let gitInclusionOverride: GitInclusion?
        let provenance: OracleSendPackagingProvenance

        init(
            sourceTabID: UUID,
            sourceWorkspaceID: UUID?,
            sourceSelectionRevision: UInt64,
            sourceAgentSessionID: UUID?,
            sourceAgentRunID: UUID?,
            promptText: String,
            selection: StoredSelection,
            lookupContext: WorkspaceLookupContext?,
            reviewGitContext: FrozenPromptGitReviewContext,
            gitInclusionOverride: GitInclusion? = nil,
            provenance: OracleSendPackagingProvenance
        ) {
            self.sourceTabID = sourceTabID
            self.sourceWorkspaceID = sourceWorkspaceID
            self.sourceSelectionRevision = sourceSelectionRevision
            self.sourceAgentSessionID = sourceAgentSessionID
            self.sourceAgentRunID = sourceAgentRunID
            self.promptText = promptText
            self.selection = selection
            self.lookupContext = lookupContext
            self.reviewGitContext = reviewGitContext
            self.gitInclusionOverride = gitInclusionOverride
            self.provenance = provenance
        }

        func applying(
            selectionMode: OracleSelectionMode,
            explicitSelection: StoredSelection? = nil
        ) -> OracleSendPackagingContext {
            switch selectionMode {
            case .current:
                self
            case .none:
                OracleSendPackagingContext(
                    sourceTabID: sourceTabID,
                    sourceWorkspaceID: sourceWorkspaceID,
                    sourceSelectionRevision: sourceSelectionRevision,
                    sourceAgentSessionID: sourceAgentSessionID,
                    sourceAgentRunID: sourceAgentRunID,
                    promptText: promptText,
                    selection: StoredSelection(codemapAutoEnabled: false),
                    lookupContext: lookupContext,
                    reviewGitContext: .automaticOnly(),
                    gitInclusionOverride: GitInclusion.none,
                    provenance: provenance
                )
            case .explicitSlices:
                OracleSendPackagingContext(
                    sourceTabID: sourceTabID,
                    sourceWorkspaceID: sourceWorkspaceID,
                    sourceSelectionRevision: sourceSelectionRevision,
                    sourceAgentSessionID: sourceAgentSessionID,
                    sourceAgentRunID: sourceAgentRunID,
                    promptText: promptText,
                    selection: explicitSelection ?? StoredSelection(codemapAutoEnabled: false),
                    lookupContext: lookupContext,
                    reviewGitContext: .automaticOnly(),
                    gitInclusionOverride: GitInclusion.none,
                    provenance: provenance
                )
            }
        }

        init(delegated context: DelegatedAgentRunOracleReviewContext) throws {
            if let reason = context.unavailableReason {
                throw reason
            }
            guard let source = context.capturedSource else {
                throw AgentRunOracleReviewUnavailableReason.sourceCaptureFailed(
                    "The immutable launch snapshot is unavailable."
                )
            }
            let artifactDelegation = SelectedGitArtifactDelegation(
                delegationID: source.delegationID,
                sourceWorkspaceID: source.workspaceID,
                sourceTabID: source.sourceTabID,
                sourceAgentSessionID: source.sourceAgentSessionID,
                sourceAgentRunID: source.sourceAgentRunID,
                targetWorkspaceID: context.target.workspaceID,
                targetTabID: context.target.tabID,
                targetAgentSessionID: context.target.agentSessionID,
                targetAgentRunID: context.targetRunID,
                exactSelectedArtifactPaths: Set(source.exactSelectedIdentities),
                targetBoundCheckouts: context.target.boundCheckouts
            )
            let delegatedReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: source.reviewGitContext.artifactCapability?.delegated(artifactDelegation),
                artifactDelegationConsumer: SelectedGitArtifactDelegationConsumer(
                    workspaceID: context.target.workspaceID,
                    tabID: context.target.tabID,
                    agentSessionID: context.target.agentSessionID,
                    agentRunID: context.targetRunID,
                    boundCheckouts: context.target.boundCheckouts
                ),
                compareIntent: source.reviewGitContext.compareIntent,
                displayContext: source.reviewGitContext.displayContext
            )
            self.init(
                sourceTabID: source.sourceTabID,
                sourceWorkspaceID: source.workspaceID,
                sourceSelectionRevision: source.sourceSelectionRevision,
                sourceAgentSessionID: source.sourceAgentSessionID,
                sourceAgentRunID: source.sourceAgentRunID,
                promptText: source.promptText,
                selection: source.selection,
                lookupContext: source.lookupContext,
                reviewGitContext: delegatedReviewContext,
                provenance: .delegated(delegationID: source.delegationID)
            )
        }
    }

    struct OracleSendTabContext {
        /// Conversation ownership. Never substitute packaging source identity here.
        let tabID: UUID
        let workspaceID: UUID?
        let origin: OracleSendOrigin
        let agentModeSessionID: UUID?
        let agentModeRunID: UUID?
        let packaging: OracleSendPackagingContext

        init(
            tabID: UUID,
            workspaceID: UUID? = nil,
            origin: OracleSendOrigin = .compatibility,
            agentModeSessionID: UUID? = nil,
            agentModeRunID: UUID? = nil,
            packaging: OracleSendPackagingContext
        ) {
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.origin = origin
            self.agentModeSessionID = agentModeSessionID
            self.agentModeRunID = agentModeRunID
            self.packaging = packaging
        }
    }

    private func oracleModelAvailabilityGuidance(for model: AIModel) -> String {
        switch model.providerType {
        case .claudeCode:
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
                return "Configure and enable \(descriptor.groupDisplayName) in Settings."
            }
            return "Connect Claude Code in Settings."
        default:
            return "Please check that the \(model.providerType.displayName) API key is configured in Settings."
        }
    }

    /// 1) Presets OFF: use the configured MCP Oracle planning model.
    /// 2) Presets ON & no presets exist: use the configured MCP Oracle planning model.
    /// 3) Presets ON & presets exist: use a compatible available preset; if none available, fail loudly.
    @MainActor
    private func selectModel(
        modelParam: String?,
        mode rawMode: String,
        allPresets: [ModelPreset],
        promptVM: PromptViewModel,
        planningModelRawOverride: String? = nil,
        presetMatchPolicy: ModelPresetMatchPolicy = .fuzzyAllowed,
        laneAttribution: OracleLaneAttribution? = nil
    ) async throws -> ModelSelectionResult {
        /// Resolve a chat preset for the MCP mode even when the selected model preset
        /// does not map one explicitly. Ensures UI display and prompt building stay in sync.
        func resolveChatPreset(for mode: String, from mappings: ChatPresetMappings?) -> (id: UUID?, name: String?) {
            if let id = mappings?.presetID(for: mode),
               let preset = ChatPresetManager.shared.preset(with: id)
            {
                return (id, preset.name)
            }
            if let builtIn = findBuiltInPreset(for: mode) {
                return (builtIn.id, builtIn.name)
            }
            return (nil, nil)
        }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let mode = norm(rawMode)
        guard ["chat", "plan", "review"].contains(mode) else {
            throw ChatToolError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        let modeLabel = mode.capitalized

        func strictPlanningModel() throws -> AIModel {
            let resolution = if let planningModelRawOverride {
                PromptViewModel.mcpOraclePlanningModelResolution(
                    rawValue: planningModelRawOverride,
                    isModelAvailable: { promptVM.mcpOracleIsProviderConfigured(for: $0) }
                )
            } else {
                promptVM.mcpOraclePlanningModelResolution()
            }
            if case let .configured(model) = resolution {
                return model
            }
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: resolution,
                availabilityGuidance: { model in self.oracleModelAvailabilityGuidance(for: model) }
            ) ?? "MCP Oracle model is not configured."
            throw ChatToolError.invalidParams(message)
        }

        // Settings toggle: "Use Model Preset for MCP chat"
        let settingsStore = GlobalSettingsStore.shared
        let useModelPresets = settingsStore.mcpShowModelPresets()
        let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()
        let presetUsageState = MCPModelPresetUsageState(
            showModelPresets: useModelPresets,
            temporarilyDisabled: temporarilyDisabled,
            configuredPresetCount: allPresets.count
        )

        // When presets are temporarily hidden by wizard, treat as empty
        // This ensures hiding presets behaves identically to having no presets
        let effectivePresets: [ModelPreset] = presetUsageState.allowsConfiguredPresets ? allPresets : []
        let hasAnyModelPresets = !effectivePresets.isEmpty

        /// Helpers for consistent info labels
        func infoLine(reason: String, model: AIModel) -> String {
            "\(modeLabel) mode • \(reason) (\(model.displayName))"
        }

        // ─────────────────────────────────────────────────────────────────
        // CASE A: Model Presets are DISABLED
        // Uses planningModel (MCP default model) - same as presets ON but empty.
        // This ensures consistent MCP behavior regardless of preset toggle state.
        // ─────────────────────────────────────────────────────────────────
        if !useModelPresets {
            if let mp = modelParam,
               let preset = try await findPreset(named: mp, in: allPresets, allowFuzzy: false),
               let message = presetUsageState.blockedPresetMessage(for: preset)
            {
                throw ChatToolError.invalidParams(message)
            }
            // MCP always uses the explicitly configured Oracle planning model when presets are off.
            let planningModel = try strictPlanningModel()
            let resolvedPreset = resolveChatPreset(for: mode, from: nil)
            let info = resolvedPreset.name ?? infoLine(reason: "MCP Oracle Model", model: planningModel)

            // If a model was explicitly requested, only accept planningModel or "current_chat_model"
            if let mp = modelParam {
                let mpn = norm(mp)
                if mpn == "current_chat_model" || mpn == norm(planningModel.displayName) {
                    return .init(
                        model: planningModel,
                        mcpControlInfo: info,
                        selectionKind: .explicit,
                        chatPresetID: resolvedPreset.id
                    )
                }

                throw ChatToolError.invalidParams(
                    "Model '\(mp)' not allowed when presets are disabled. " +
                        "Pass 'current_chat_model' or '\(planningModel.displayName)', or enable model presets."
                )
            }

            // No explicit model param → return planningModel
            return .init(
                model: planningModel,
                mcpControlInfo: info,
                selectionKind: .automatic,
                chatPresetID: resolvedPreset.id
            )
        }

        // ─────────────────────────────────────────────────────────────────
        // CASE B: Model Presets are ENABLED
        // 1) No presets defined at all → use the configured Oracle planning model.
        // 2) Presets exist → pick an available preset for the mode; if none available, fail loudly.
        // ─────────────────────────────────────────────────────────────────

        // B.1: No model presets exist at all → use default MCP model (error if unavailable)
        if !hasAnyModelPresets {
            if let mp = modelParam,
               let preset = try await findPreset(named: mp, in: allPresets, allowFuzzy: false),
               let message = presetUsageState.blockedPresetMessage(for: preset)
            {
                throw ChatToolError.invalidParams(message)
            }
            // Default MCP model must be explicitly configured and available when presets are enabled but none are defined.
            let planningModel = try strictPlanningModel()
            let resolvedPreset = resolveChatPreset(for: mode, from: nil)
            let info = resolvedPreset.name ?? infoLine(reason: "MCP Oracle Model", model: planningModel)
            // Respect explicit model only for the sentinel or configured Oracle model display name
            if let mp = modelParam {
                let mpn = norm(mp)
                if mpn == "current_chat_model" ||
                    mpn == norm(planningModel.displayName)
                {
                    return .init(
                        model: planningModel,
                        mcpControlInfo: info,
                        selectionKind: .explicit,
                        chatPresetID: resolvedPreset.id
                    )
                }
                throw ChatToolError.invalidParams(
                    "Model '\(mp)' not found. No model presets are defined. Pass 'current_chat_model' or the display name shown by oracle_utils op=models, or create presets and enable them in Settings."
                )
            }
            return .init(
                model: planningModel,
                mcpControlInfo: info,
                selectionKind: .automatic,
                chatPresetID: resolvedPreset.id
            )
        }

        // B.2: Model presets exist → use compatible preset, then fallback if needed
        let supporting: [ModelPreset] = effectivePresets.filteredForMode(mode)
        var available: [ModelPreset] = []
        for p in supporting {
            if promptVM.isModelAvailable(p.model) {
                available.append(p)
            }
        }

        // Explicit model request via param
        if let mp = modelParam {
            // ask_oracle uses exact preset identity; oracle_send keeps its
            // compatibility fuzzy match behavior.
            if let preset = try await findPreset(
                named: mp,
                in: effectivePresets,
                allowFuzzy: presetMatchPolicy == .fuzzyAllowed
            ) {
                try validateModeCompatibility(preset: preset, mode: mode, allPresets: effectivePresets)

                // Check if the preset's model is available (model presets are sacred)
                if !promptVM.isModelAvailable(preset.model) {
                    throw ChatToolError.invalidParams(
                        "Model preset '\(preset.name)' is not available. Check its provider and model configuration in Settings."
                    )
                }

                let modelName = preset.model.displayName
                let resolvedPreset = resolveChatPreset(for: mode, from: preset.chatPresetMappings)

                let info = resolvedPreset.name ?? "\(modeLabel) mode • \(preset.name) (\(modelName))"

                return .init(
                    model: preset.model,
                    mcpControlInfo: info,
                    selectionKind: .explicit,
                    chatPresetID: resolvedPreset.id,
                    modelSource: "preset",
                    modelPresetID: preset.id,
                    modelPresetName: preset.name
                )
            }

            // No preset match: do not allow sentinel fallback here since presets exist.
            throw buildModelNotFoundError(
                modelParam: mp,
                mode: mode,
                allPresets: effectivePresets,
                hasPresets: hasAnyModelPresets
            )
        }

        // Continuation inheritance: a `chat_id` continuation that omitted `model` must stay on
        // the preset the lane was opened with. Re-running automatic selection here is exactly
        // what moved a lane onto `available.first`.
        //
        // This lives inside CASE B.2 deliberately. When presets are globally disabled, hidden, or
        // undefined, the planning-model paths above are already deterministic — a single
        // user-configured model, not a guess among peers — so there is no ambiguity to guard. It is
        // also the only safe choice: in that state an explicit `model` naming a preset is rejected
        // too, so failing closed on a recorded binding would leave the lane un-continuable with no
        // in-band remediation. Fail-closed therefore applies to per-preset problems only, never to
        // a global mode change. The trade-off is that such a send rebinds the lane to the planning
        // model, so re-enabling presets may need one explicit `model` call to rebind.
        if let laneAttribution,
           let inheritedPreset = try inheritedLanePreset(
               laneAttribution: laneAttribution,
               mode: mode,
               effectivePresets: effectivePresets,
               available: available,
               promptVM: promptVM
           )
        {
            let resolvedPreset = resolveChatPreset(for: mode, from: inheritedPreset.chatPresetMappings)
            let info = resolvedPreset.name
                ?? "\(modeLabel) mode • \(inheritedPreset.name) (\(inheritedPreset.model.displayName))"
            return .init(
                model: inheritedPreset.model,
                mcpControlInfo: info,
                selectionKind: .inherited,
                chatPresetID: resolvedPreset.id,
                modelSource: "preset",
                modelPresetID: inheritedPreset.id,
                modelPresetName: inheritedPreset.name
            )
        }

        // No explicit model → pick first available compatible preset
        if let first = available.first {
            let modelName = first.model.displayName
            let resolvedPreset = resolveChatPreset(for: mode, from: first.chatPresetMappings)
            let info = resolvedPreset.name ?? "\(modeLabel) mode • Auto: \(first.name) (\(modelName))"

            return .init(
                model: first.model,
                mcpControlInfo: info,
                selectionKind: .automatic,
                chatPresetID: resolvedPreset.id,
                modelSource: "preset",
                modelPresetID: first.id,
                modelPresetName: first.name
            )
        }

        // Hard line: user disabled this mode across presets
        if supporting.isEmpty {
            throw ChatToolError.invalidParams(
                "Mode '\(mode)' is disabled by your configured model presets. Choose a different mode, edit your presets to enable this mode, or disable 'Use Model Preset for MCP chat' in Settings."
            )
        }

        // Presets exist for this mode but none have available models - error instead of silent fallback
        // (model presets are sacred)
        let presetNames = supporting.map(\.name).joined(separator: ", ")
        throw ChatToolError.invalidParams(
            "None of your model presets for '\(mode)' mode are available. " +
                "Configured presets: \(presetNames). Check their provider and model configurations in Settings."
        )
    }

    @MainActor
    func resolveMCPFollowUpModel(
        mode: String,
        modelParam: String? = nil,
        workspaceID: UUID? = nil,
        planningModelRawOverride: String? = nil
    ) async throws -> (model: AIModel, chatPresetID: UUID?, modelPresetID: UUID?, mcpControlInfo: String?) {
        let presetsManager = ModelPresetsManager.shared
        let allPresets = presetsManager.allPresets()
        let selection = try await selectModel(
            modelParam: modelParam,
            mode: mode,
            allPresets: allPresets,
            promptVM: promptViewModel,
            planningModelRawOverride: planningModelRawOverride ?? workspaceID.flatMap {
                GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: $0).planningModelRaw
            }
        )
        // `modelPresetID` is returned so the chat this model is sent into records the same exact
        // lane binding an `ask_oracle` send would; otherwise a later `chat_id` continuation of that
        // chat could only fall back to matching on the raw model.
        return (selection.model, selection.chatPresetID, selection.modelPresetID, selection.mcpControlInfo)
    }

    /// Finds a built-in chat preset for the given mode
    @MainActor
    private func findBuiltInPreset(for mode: String) -> ChatPreset? {
        let manager = ChatPresetManager.shared
        switch mode.lowercased() {
        case "chat":
            return manager.defaultPreset(for: .chat)
                ?? manager.builtInPresets.first { $0.mode == .chat && $0.id != ChatPreset.BuiltIn.manual.id }
                ?? manager.builtInPresets.first { $0.mode == .chat }
        case "plan":
            return manager.defaultPreset(for: .plan)
                ?? manager.builtInPresets.first { $0.mode == .plan }
        case "review":
            return manager.defaultPreset(for: .review)
                ?? manager.builtInPresets.first { $0.mode == .review }
        default:
            return manager.defaultPreset(for: .chat)
                ?? manager.builtInPresets.first { $0.mode == .chat && $0.id != ChatPreset.BuiltIn.manual.id }
                ?? manager.builtInPresets.first { $0.mode == .chat }
        }
    }

    /// Finds a preset by name using various matching strategies
    @MainActor
    private func findPreset(
        named name: String,
        in presets: [ModelPreset],
        allowFuzzy: Bool
    ) async throws -> ModelPreset? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try by ID first
        if let presetId = UUID(uuidString: normalizedName),
           let preset = presets.first(where: { $0.id == presetId })
        {
            return preset
        }

        // Try exact name match (case-insensitive). Strict ask_oracle calls
        // must fail closed when duplicate display names exist; UUIDs remain unique.
        let exactNameMatches = presets.filter {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
        if exactNameMatches.count == 1 {
            return exactNameMatches[0]
        }
        if exactNameMatches.count > 1, !allowFuzzy {
            throw ChatToolError.invalidParams(
                "Multiple model presets are named '\(normalizedName)'. Pass the exact preset UUID from oracle_utils op=models."
            )
        }
        if let firstExactMatch = exactNameMatches.first {
            return firstExactMatch
        }

        guard allowFuzzy else { return nil }

        // Try fuzzy matching
        let availableNames = presets.map(\.name)
        let closestName = await Task.detached(priority: .userInitiated) {
            ModelPreset.findBestMatch(normalizedName, among: availableNames)
        }.value

        if let closestName {
            print("[MCP] Fuzzy matched model '\(normalizedName)' to preset '\(closestName)'")
            return presets.first { $0.name == closestName }
        }

        return nil
    }

    /// Resolves the model preset that a `chat_id` continuation should stay on.
    ///
    /// Returns `nil` only when the lane has no recorded identity **and** automatic selection is
    /// unambiguous. Every other unresolvable case throws, because silently substituting a
    /// different preset is the defect this resolution exists to prevent. Callers can always
    /// override by passing an explicit `model`, which deliberately migrates the lane.
    @MainActor
    private func inheritedLanePreset(
        laneAttribution: OracleLaneAttribution,
        mode: String,
        effectivePresets: [ModelPreset],
        available: [ModelPreset],
        promptVM: PromptViewModel
    ) throws -> ModelPreset? {
        let remediation = "To choose a preset explicitly, pass `model` with the exact preset UUID from `oracle_utils op=models`."

        // Tier 1: exact recorded preset identity is authoritative.
        if let recordedPresetID = laneAttribution.modelPresetID {
            guard let preset = effectivePresets.first(where: { $0.id == recordedPresetID }) else {
                // Recorded-then-deleted is known identity loss, which is not the same as never
                // having recorded identity. Recovering by model here would substitute a
                // different preset behind the caller's back.
                throw ChatToolError.invalidParams(
                    "This chat's last send used model preset \(recordedPresetID.uuidString), which no longer exists. " +
                        "No replacement preset was substituted. " + remediation
                )
            }

            func inheritedFailure(_ reason: String) -> ChatToolError {
                .invalidParams(
                    "This chat is bound to model preset '\(preset.name)', inherited because no `model` argument was passed. " +
                        reason + " " + remediation
                )
            }

            // `ModelPreset.model` silently falls back to a default model when its stored model
            // string no longer resolves, so inheriting it unchecked would be a wrong-model send.
            guard preset.isModelResolvable else {
                throw inheritedFailure("Its configured model can no longer be resolved.")
            }
            guard preset.supports(mode: mode) else {
                throw inheritedFailure("It does not support '\(mode)' mode.")
            }
            guard promptVM.isModelAvailable(preset.model) else {
                throw inheritedFailure("Its configured model is not available. Check the preset configuration in Settings.")
            }
            return preset
        }

        // Tier 2: no recorded preset identity, but the lane's model is known. Inherit only on a
        // unique match, otherwise this becomes a narrower version of the defect it fixes. This is
        // the migration path for every chat saved before preset identity was recorded.
        if let recordedModelRawValue = laneAttribution.modelRawValue {
            // Matching is by model identity only. `lastSendModelDisplayName` is never used to
            // resolve a preset because display names are not stable identifiers.
            // `isModelResolvable` is required because `ModelPreset.model` falls back to a default
            // model when its stored model string no longer resolves; without this a corrupt preset
            // could become the "unique" match for an unrelated recorded model.
            let matches = available.filter {
                $0.isModelResolvable && $0.model.rawValue == recordedModelRawValue
            }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.isEmpty {
                throw ChatToolError.invalidParams(
                    "This chat has a recorded legacy model identity, and no available model preset for '\(mode)' mode uses it. " +
                        "A different preset was not substituted. " + remediation
                )
            }
            throw ChatToolError.invalidParams(
                "This chat has a recorded legacy model identity shared by \(matches.count) available presets for '\(mode)' mode (\(matches.map(\.name).joined(separator: ", "))). " +
                    "Which preset owns this chat is ambiguous, so none was chosen. " + remediation
            )
        }

        // Tier 3: no recorded identity at all.
        // A chat that has never been sent has no binding to preserve, so today's automatic
        // selection cannot mis-route it. A chat that already has messages does have a historical
        // model that simply was never recorded (pre-attribution sessions, truncated forks);
        // guessing there would be nondeterministic, so ambiguity fails closed.
        if laneAttribution.hasMessages, available.count > 1 {
            throw ChatToolError.invalidParams(
                "This chat has earlier messages but no recorded model attribution, and \(available.count) model presets support '\(mode)' mode. " +
                    "Automatic selection could run it on a different model than the chat already used. " + remediation
            )
        }

        return nil
    }

    /// Validates that a preset supports the requested mode
    private func validateModeCompatibility(
        preset: ModelPreset,
        mode: String,
        allPresets: [ModelPreset]
    ) throws {
        guard let supportedModes = preset.supportedModes else { return }

        let isSupported = switch mode {
        case "chat": supportedModes.chat
        case "plan": supportedModes.plan
        case "review": supportedModes.review
        default: true
        }

        guard isSupported else {
            // Build list of supported modes
            var supportedModesList: [String] = []
            if supportedModes.chat { supportedModesList.append("chat") }
            if supportedModes.plan { supportedModesList.append("plan") }
            if supportedModes.review { supportedModesList.append("review") }

            let supportedModesStr = supportedModesList.isEmpty ?
                "no modes" :
                supportedModesList.joined(separator: ", ")

            // Find alternatives
            let alternatives = allPresets.filteredForMode(mode).map(\.name)
            let alternativesNote = if alternatives.isEmpty {
                " No defined presets support '\(mode)' mode. Use `oracle_utils op=models` to view each preset's supported modes."
            } else {
                " Alternative presets for \(mode) mode: \(alternatives.joined(separator: ", "))"
            }

            throw ChatToolError.invalidParams(
                "Model preset '\(preset.name)' does not support '\(mode)' mode. " +
                    "This preset only supports: \(supportedModesStr)." +
                    alternativesNote +
                    " To fix: either use a supported mode (\(supportedModesStr)) or choose a different model."
            )
        }
    }

    /// Builds appropriate error message when model is not found
    private func buildModelNotFoundError(
        modelParam: String,
        mode: String,
        allPresets: [ModelPreset],
        hasPresets: Bool
    ) -> ChatToolError {
        if !hasPresets {
            return ChatToolError.invalidParams(
                "Model '\(modelParam)' not found. No model presets are defined. " +
                    "Pass 'current_chat_model' or the display name of the current/planning model (as shown by oracle_utils op=models), " +
                    "or create presets and enable them in Settings."
            )
        }
        let available = allPresets.map(\.name).joined(separator: ", ")
        return ChatToolError.invalidParams(
            "Model '\(modelParam)' not found. Available presets: \(available). " +
                "Choose a compatible preset (see oracle_utils op=models), or disable 'Use Model Preset for MCP Oracle' to use the current oracle model."
        )
    }

    /// Builds an array of `Value` objects representing chat history, ready for MCP JSON-RPC responses.
    private func buildMCPMessageLog(from parsedMessages: [AIChatMessage]) -> [Value] {
        var log: [Value] = []
        log.reserveCapacity(parsedMessages.count)

        for msg in parsedMessages {
            let role: String = msg.isUser ? "user" : "assistant"

            let baseText = msg.content

            var dict: [String: Value] = [
                "id": .string(msg.id.uuidString),
                "role": .string(role),
                "is_user": .bool(msg.isUser),
                "text": .string(baseText)
            ]

            /*
             // Include reasoning when available (streaming, not persisted).
             if !msg.isUser {
             	let reasoning = ephemeralState.reasoningContent(for: msg.id)
             	if !reasoning.isEmpty {
             		dict["reasoning"] = .string(reasoning)
             	}
             }
             */
            log.append(.object(dict))
        }

        return log
    }

    /// Builds MCP log output from the currently displayed chat state.
    private func buildMCPMessageLog(includeDiffs: Bool = false, limit: Int? = nil) -> [Value] {
        let messagesToProcess = if let limit, limit > 0 {
            Array(messages.suffix(limit))
        } else {
            messages
        }
        _ = includeDiffs
        return buildMCPMessageLog(from: messagesToProcess)
    }

    /// Builds MCP log output from persisted `StoredMessage` values without switching UI state.
    private func buildMCPMessageLog(
        from storedMessages: [StoredMessage],
        includeDiffs: Bool = false,
        limit: Int? = nil
    ) async -> [Value] {
        let storedToProcess = if let limit, limit > 0 {
            Array(storedMessages.suffix(limit))
        } else {
            storedMessages
        }

        var parsedMessages: [AIChatMessage] = []
        parsedMessages.reserveCapacity(storedToProcess.count)
        for stored in storedToProcess {
            await parsedMessages.append(Self.parseSingleRawMessage(stored))
        }
        _ = includeDiffs
        return buildMCPMessageLog(from: parsedMessages)
    }

    // MARK: - Session resolution helpers

    @MainActor
    func resolveSession(id raw: String?) -> ChatSession? {
        guard let raw, !raw.isEmpty else { return nil }

        // 1️⃣ Exact UUID
        if let uuid = UUID(uuidString: raw) {
            return sessions.first { $0.id == uuid }
        }
        // 2️⃣ shortID
        return sessions.first { $0.shortID == raw }
    }

    @MainActor
    private func resolveSessionForExplicitContinuation(
        id rawID: String,
        tabID: UUID?
    ) async throws -> ChatSession? {
        if let loaded = resolveSession(id: rawID) {
            return loaded
        }
        guard let tabID,
              let candidate = workspaceManager.bindingCandidate(forContextID: tabID),
              let workspace = workspaceManager.workspaces.first(where: { $0.id == candidate.workspaceID }),
              let persisted = try await chatData.findSession(for: workspace, id: rawID, composeTabID: tabID)
        else {
            return nil
        }

        // Inactive headless generation deliberately avoids publishing into the active
        // workspace's chat catalog. Load only an explicitly requested continuation;
        // activation remains disabled for an inactive tab, so currentSession is untouched.
        if !sessions.contains(where: { $0.id == persisted.id }) {
            sessions.append(persisted)
        }
        return persisted
    }

    @MainActor
    private func resolveBackgroundTabID(
        for session: ChatSession,
        fallbackTabID: UUID?
    ) async -> UUID? {
        if let tabID = session.composeTabID,
           workspaceManager.composeTab(with: tabID) != nil
        {
            return tabID
        }

        if let fallbackTabID,
           workspaceManager.composeTab(with: fallbackTabID) != nil
        {
            await assignSession(session.id, toTabID: fallbackTabID, setActiveForTab: false)
            return fallbackTabID
        }

        return await ensureTabForSession(session)
    }

    private enum ChatInspectionScope: String {
        case workspace
        case tab
    }

    @MainActor
    private func requestedChatInspectionScope(from args: [String: Value]) -> ChatInspectionScope {
        let rawScope = args["scope"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawScope == ChatInspectionScope.tab.rawValue {
            return .tab
        }
        let explicitContextID = (args["context_id"] ?? args["tab_id"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (explicitContextID?.isEmpty == false) ? .tab : .workspace
    }

    @MainActor
    private func resolvedInspectionTabID(from args: [String: Value]) throws -> UUID? {
        guard requestedChatInspectionScope(from: args) == .tab else { return nil }

        if let rawID = (args["context_id"] ?? args["tab_id"])?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty
        {
            guard let tabID = UUID(uuidString: rawID) else {
                throw ChatToolError.invalidParams("context_id must be a valid UUID")
            }
            return tabID
        }

        return promptViewModel.activeComposeTabID
    }

    private func sessionNeedsInspectionLoad(_ session: ChatSession) -> Bool {
        session.isListStub || (session.messages.isEmpty && session.effectiveMessageCount > 0)
    }

    private func loadSessionForInspection(_ session: ChatSession) async throws -> ChatSession {
        guard sessionNeedsInspectionLoad(session) else { return session }
        guard let fileURL = session.fileURL else {
            throw ChatToolError.internalError("Chat session '\(session.shortID)' is missing its backing file")
        }
        do {
            return try await chatData.loadChatSession(from: fileURL)
        } catch {
            throw ChatToolError.internalError("Failed to load chat session '\(session.shortID)'")
        }
    }

    @MainActor
    private func resolveSessionForInspection(
        id rawID: String,
        workspace: WorkspaceModel,
        tabID: UUID?
    ) async throws -> ChatSession {
        if let loaded = resolveSession(id: rawID) {
            if let sessionWorkspaceID = loaded.workspaceID, sessionWorkspaceID != workspace.id {
                // Ignore stale in-memory sessions from other workspaces; fall through to disk lookup.
            } else {
                if let tabID, loaded.composeTabID != tabID {
                    throw ChatToolError.invalidParams("Chat with ID '\(rawID)' belongs to a different tab")
                }
                return try await loadSessionForInspection(loaded)
            }
        }

        if let persisted = try await chatData.findSession(for: workspace, id: rawID, composeTabID: tabID) {
            return persisted
        }

        throw ChatToolError.invalidParams("Chat with ID '\(rawID)' not found")
    }

    @MainActor
    private func mostRecentSessionForInspection(
        workspace: WorkspaceModel,
        tabID: UUID?
    ) async throws -> ChatSession {
        if let tabID {
            if let loaded = sessions(forTabID: tabID).sorted(by: { $0.savedAt > $1.savedAt }).first {
                return try await loadSessionForInspection(loaded)
            }
            if let persisted = try await chatData.mostRecentSession(for: workspace, composeTabID: tabID) {
                return persisted
            }
            throw ChatToolError.invalidParams("No chats found in the requested tab")
        }

        if let loaded = sessions.sorted(by: { $0.savedAt > $1.savedAt }).first {
            return try await loadSessionForInspection(loaded)
        }
        if let persisted = try await chatData.mostRecentSession(for: workspace, composeTabID: nil) {
            return persisted
        }
        throw ChatToolError.invalidParams("No chats found in the current workspace")
    }

    @MainActor
    func createSession(
        named name: String?,
        tabID: UUID? = nil,
        activateInUI: Bool = true,
        setActiveForTab: Bool = true,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        reuseBlankSession: Bool = true
    ) async throws -> ChatSession {
        let safeName = ChatSession.validatedName(name ?? "")
        let createdID = await startNewChatSession(
            name: safeName,
            tabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI,
            setActiveForTab: setActiveForTab,
            reuseBlankSession: reuseBlankSession
        )

        guard let id = createdID ?? currentSessionID,
              let session = sessions.first(where: { $0.id == id })
        else {
            throw ChatToolError.internalError("Failed to create chat session")
        }
        return session
    }

    private static func sessionBelongsToResolvedTab(_ session: ChatSession, tabID: UUID?) -> Bool {
        guard let tabID else { return true }
        return session.composeTabID == tabID
    }

    /// Chat-primary owner matching: the stored chat's strongest identity decides.
    ///
    /// - Session-owned chats (`agentModeSessionID != nil`) are owned by that durable Agent
    ///   Mode session. The caller must present the same session ID. The stored run ID is
    ///   ephemeral per-process metadata — a fresh UUID is minted whenever a provider
    ///   controller is (re)created, so it can never match after an app relaunch or a
    ///   mid-session controller rotation — and it never authorizes or blocks continuation.
    /// - Run-owned chats (`agentModeSessionID == nil`, `agentModeRunID != nil` — headless /
    ///   context-builder lanes) require the exact run: they die with their process, and a
    ///   session-having caller must not adopt them even when the run matches.
    /// - Unowned legacy chats match unowned callers always, and owned callers only where
    ///   `allowUnownedLegacy` permits adoption.
    private static func sessionMatchesOracleOwner(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> Bool {
        if let ownerSessionID = session.agentModeSessionID {
            return agentModeSessionID == ownerSessionID
        }
        if let ownerRunID = session.agentModeRunID {
            return agentModeSessionID == nil && agentModeRunID == ownerRunID
        }
        guard agentModeSessionID != nil || agentModeRunID != nil else { return true }
        return allowUnownedLegacy
    }

    static func sessionMatchesOracleOwnerForExplicitContinuation(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) -> Bool {
        sessionMatchesOracleOwner(
            session,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            allowUnownedLegacy: false
        )
    }

    /// Rejection message for an explicit continuation whose owner check failed; `nil` when
    /// the caller may continue the chat. The "different Agent Mode owner" phrase is
    /// load-bearing for existing callers/tests; the parenthetical discriminates
    /// session-mismatch from run-scoped causes so field reports are self-diagnosing.
    static func oracleOwnerContinuationRejection(
        _ session: ChatSession,
        chatID: String,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) -> String? {
        guard !sessionMatchesOracleOwnerForExplicitContinuation(
            session,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        ) else { return nil }

        let detail = if session.agentModeSessionID != nil {
            "the chat is owned by a different Agent Mode session"
        } else if session.agentModeRunID != nil {
            "the chat is a run-scoped headless lane owned by its originating run"
        } else {
            "the chat was created outside Agent Mode ownership"
        }
        return "Chat with ID '\(chatID)' belongs to a different Agent Mode owner (\(detail))"
    }

    /// Returns a handoff-specific hint only when the caller already owns the mapped
    /// destination clone. The old ID remains invalid and is never resolved as an alias.
    @MainActor
    private func clonedHandoffContinuationRejection(
        chatID: String,
        tabID: UUID?,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) -> String? {
        let lookupID = UUID(uuidString: chatID)?.uuidString ?? chatID
        guard let tabID,
              agentModeSessionID != nil || agentModeRunID != nil,
              let replacementID = handoffChatIDReplacementsByTabID[tabID]?[lookupID],
              let clone = resolveSession(id: replacementID),
              clone.composeTabID == tabID,
              Self.sessionMatchesOracleOwnerForExplicitContinuation(
                  clone,
                  agentModeSessionID: agentModeSessionID,
                  agentModeRunID: agentModeRunID
              )
        else { return nil }

        return "Chat with ID '\(chatID)' was cloned during handoff; use '\(replacementID)'"
    }

    /// Owner-scoped candidate tiers:
    /// - `0`: exact current-run match (session-owned lane stamped with the caller's run, or a
    ///   run-owned lane on its exact run).
    /// - `1`: same-session lane whose run stamp is stale or missing — a lane from a previous
    ///   process/controller rotation of the caller's own Agent Mode session. Eligible for
    ///   read-only log recovery and for callers without a current run; implicit sends with a
    ///   run stay exact-run-scoped (see `implicitContinuationCandidate`).
    /// - `2`: unowned legacy chat, where adoption is permitted.
    /// `nil` excludes the candidate (different session, foreign run-owned lane, or legacy
    /// adoption not allowed).
    private static func oracleOwnerRank(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> Int? {
        guard agentModeSessionID != nil || agentModeRunID != nil else {
            // Mirror the matcher: a fully-unowned caller ranks only unowned chats, so a
            // future call site without a hasOwner gate cannot adopt agent lanes at tier 0.
            return (session.agentModeSessionID == nil && session.agentModeRunID == nil) ? 0 : nil
        }

        if let ownerSessionID = session.agentModeSessionID {
            guard agentModeSessionID == ownerSessionID else { return nil }
            guard let agentModeRunID else { return 1 }
            return session.agentModeRunID == agentModeRunID ? 0 : 1
        }
        if let ownerRunID = session.agentModeRunID {
            return (agentModeSessionID == nil && agentModeRunID == ownerRunID) ? 0 : nil
        }
        return allowUnownedLegacy ? 2 : nil
    }

    private static func rankedOracleOwnerPairs(
        _ sessions: [ChatSession],
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> [(session: ChatSession, rank: Int)] {
        sessions.compactMap { session -> (session: ChatSession, rank: Int)? in
            guard let rank = oracleOwnerRank(
                session,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                allowUnownedLegacy: allowUnownedLegacy
            ) else { return nil }
            return (session, rank)
        }
    }

    private static func strongestOracleOwnerBucket(
        _ sessions: [ChatSession],
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool,
        maxRank: Int = Int.max
    ) -> [ChatSession] {
        let ranked = rankedOracleOwnerPairs(
            sessions,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            allowUnownedLegacy: allowUnownedLegacy
        )
        .filter { $0.rank <= maxRank }
        guard let strongestRank = ranked.map(\.rank).min() else { return [] }
        return ranked
            .filter { $0.rank == strongestRank }
            .map(\.session)
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// All owner-eligible sessions ordered by (tier, then recency). Unlike
    /// `strongestOracleOwnerBucket`, weaker tiers stay in the list so log recovery can fall
    /// through to a non-empty stale same-session lane instead of dead-ending on an empty
    /// exact-run lane.
    private static func rankedOracleOwnerCandidates(
        _ sessions: [ChatSession],
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> [ChatSession] {
        rankedOracleOwnerPairs(
            sessions,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            allowUnownedLegacy: allowUnownedLegacy
        )
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.session.savedAt > $1.session.savedAt
        }
        .map(\.session)
    }

    @MainActor
    private func applyOracleOwnerIfNeeded(
        sessionID: UUID,
        tabID: UUID?,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async {
        guard agentModeSessionID != nil || agentModeRunID != nil else { return }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        var changed = false
        if let tabID, sessions[index].composeTabID == nil {
            sessions[index].composeTabID = tabID
            changed = true
        }
        if sessions[index].agentModeSessionID == nil, let agentModeSessionID {
            sessions[index].agentModeSessionID = agentModeSessionID
            changed = true
        }
        if sessions[index].agentModeRunID == nil, let agentModeRunID {
            sessions[index].agentModeRunID = agentModeRunID
            changed = true
        }
        if let agentModeSessionID,
           sessions[index].agentModeSessionID == agentModeSessionID,
           let agentModeRunID,
           sessions[index].agentModeRunID != agentModeRunID
        {
            // Advance the ephemeral run stamp when the owning session continues its lane
            // under a new process run (app relaunch or controller rotation). The stamp
            // records the run that last ADOPTED the lane (even if the subsequent send
            // fails) — it is metadata, never authorization: it only keeps the adopted
            // lane exact-run sticky for implicit resolution. Run-owned lanes never reach
            // here (their nil session ID fails the equality above).
            sessions[index].agentModeRunID = agentModeRunID
            changed = true
        }
        guard changed else { return }

        scheduleSessionSave(sessions[index])
    }

    @MainActor
    private func activateResolvedChatSession(
        _ session: ChatSession,
        resolvedTabID: UUID?,
        activateInUI: Bool
    ) async {
        if activateInUI {
            await switchToSession(session.id)
            return
        }

        _ = await ensureSessionLoadedForBackground(session)
        let targetTabID = await resolveBackgroundTabID(
            for: session,
            fallbackTabID: resolvedTabID
        )
        if let targetTabID {
            workspaceManager.setActiveChatSessionID(session.id, forTabID: targetTabID)
        }
    }

    /// Read-only resolution of the chat an implicit continuation (no `chat_id`, no `new_chat`)
    /// would resume.
    ///
    /// Extracted so model selection and `locateOrCreateChat` cannot disagree about which chat an
    /// implicit continuation means. If they disagreed, an inherited preset could be applied to a
    /// different conversation than the one it came from — a subtler version of the wrong-lane
    /// defect this inheritance exists to prevent.
    @MainActor
    private func implicitContinuationCandidate(
        tabID resolvedTabID: UUID?,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        activateInUI: Bool
    ) -> ChatSession? {
        func eligible(_ session: ChatSession, allowUnownedLegacy: Bool = true) -> Bool {
            Self.sessionBelongsToResolvedTab(session, tabID: resolvedTabID) &&
                Self.sessionMatchesOracleOwner(
                    session,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    allowUnownedLegacy: allowUnownedLegacy
                )
        }

        let hasOwner = agentModeSessionID != nil || agentModeRunID != nil
        func findCandidate(allowUnownedLegacy: Bool) -> ChatSession? {
            let scopedSessions: [ChatSession]
            let activeForTab: UUID?
            if let resolvedTabID {
                scopedSessions = sessions(forTabID: resolvedTabID)
                activeForTab = workspaceManager.activeChatSessionID(forTabID: resolvedTabID)
            } else {
                scopedSessions = sessions
                activeForTab = nil
            }

            let candidates: [ChatSession] = if hasOwner {
                // Implicit sends never silently adopt a stale-run lane: a caller with a
                // current run resumes only that run's own lanes; after a rotation/restart
                // a chat_id-less send starts fresh. Lane recovery is deliberate —
                // oracle_chat_log (which serves stale same-session lanes read-only and
                // echoes the chat_id) followed by explicit chat_id continuation.
                // Callers without a run (owner known, run not yet started) keep
                // same-session resumption.
                Self.strongestOracleOwnerBucket(
                    scopedSessions.filter { Self.sessionBelongsToResolvedTab($0, tabID: resolvedTabID) },
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    allowUnownedLegacy: allowUnownedLegacy,
                    maxRank: agentModeRunID == nil ? 1 : 0
                )
            } else {
                scopedSessions.filter { eligible($0, allowUnownedLegacy: allowUnownedLegacy) }
            }

            if let activeForTab,
               let activeCandidate = candidates.first(where: { $0.id == activeForTab })
            {
                return activeCandidate
            }
            if activateInUI,
               let currentSessionID,
               let currentCandidate = candidates.first(where: { $0.id == currentSessionID })
            {
                return currentCandidate
            }
            return candidates.sorted(by: { $0.savedAt > $1.savedAt }).first
        }

        return hasOwner
            ? findCandidate(allowUnownedLegacy: false)
            : findCandidate(allowUnownedLegacy: true)
    }

    /// Ensure the requested chat exists (or create one) and make it active.
    /// Defaults to resuming the most recent chat scoped to the resolved tab/owner.
    @discardableResult
    @MainActor
    func locateOrCreateChat(
        _ idString: String?,
        desiredName: String? = nil,
        forceNew: Bool = false,
        tabID: UUID? = nil,
        activateInUI: Bool = true,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        deferContinuationMutation: Bool = false
    ) async throws -> UUID {
        let resolvedTabID = tabID ?? promptViewModel.activeComposeTabID

        if forceNew {
            let new = try await createSession(
                named: desiredName,
                tabID: resolvedTabID,
                activateInUI: activateInUI,
                setActiveForTab: true,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                reuseBlankSession: false
            )
            return new.id
        }

        if let idString = idString?.trimmingCharacters(in: .whitespacesAndNewlines), !idString.isEmpty {
            if let rejection = clonedHandoffContinuationRejection(
                chatID: idString,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) {
                throw ChatToolError.invalidParams(rejection)
            }
            guard let existing = try await resolveSessionForExplicitContinuation(
                id: idString,
                tabID: resolvedTabID
            ) else {
                throw ChatToolError.invalidParams("Chat with ID '\(idString)' not found")
            }
            guard Self.sessionBelongsToResolvedTab(existing, tabID: resolvedTabID) else {
                throw ChatToolError.invalidParams("Chat with ID '\(idString)' belongs to a different tab")
            }
            if let rejection = Self.oracleOwnerContinuationRejection(
                existing,
                chatID: idString,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) {
                throw ChatToolError.invalidParams(rejection)
            }

            // Preflight callers load conversation state without changing activation,
            // ownership, or the chat name. Those mutations are committed only after a
            // reservation succeeds.
            if deferContinuationMutation {
                guard await ensureSessionLoadedForBackground(existing) != nil else {
                    throw ChatToolError.internalError("Failed to load the requested chat")
                }
                return existing.id
            }

            // Activate/load first, then stamp: background activation replaces the
            // in-memory session with the loaded (disk) copy, so an owner stamp applied
            // before activation would be silently reverted for any session that still
            // needs its messages loaded — which post-restart is every reloaded chat.
            await activateResolvedChatSession(existing, resolvedTabID: resolvedTabID, activateInUI: activateInUI)
            await applyOracleOwnerIfNeeded(
                sessionID: existing.id,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )

            if let newName = desiredName,
               !newName.isEmpty,
               newName != existing.name
            {
                renameSession(id: existing.id, newName: ChatSession.validatedName(newName))
            }
            return existing.id
        }

        let candidate = implicitContinuationCandidate(
            tabID: resolvedTabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI
        )

        if let candidate {
            // Same ordering invariant as the explicit path: load/activate before stamping.
            await activateResolvedChatSession(candidate, resolvedTabID: resolvedTabID, activateInUI: activateInUI)
            await applyOracleOwnerIfNeeded(
                sessionID: candidate.id,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            if let newName = desiredName,
               !newName.isEmpty,
               newName != candidate.name
            {
                renameSession(id: candidate.id, newName: ChatSession.validatedName(newName))
            }
            return candidate.id
        }

        let new = try await createSession(
            named: desiredName ?? "New Chat",
            tabID: resolvedTabID,
            activateInUI: activateInUI,
            setActiveForTab: true,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            // Parallel MCP implicits must not collide on the same blank "New Chat".
            reuseBlankSession: false
        )
        return new.id
    }

    /// Synchronous chat choice for MCP force-new / implicit sends.
    /// Skips streaming candidates so a concurrent peer that already reserved forks a new chat.
    @MainActor
    private func chooseMCPChatForSendSync(
        desiredName: String?,
        forceNew: Bool,
        tabID: UUID?,
        activateInUI: Bool,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        expectedImplicitCandidateID: UUID?,
        enforceExpectedImplicitCandidate: Bool
    ) throws -> (chatID: UUID, createdFresh: Bool) {
        let resolvedTabID = tabID ?? promptViewModel.activeComposeTabID
        let safeName = ChatSession.validatedName(desiredName ?? (forceNew ? "" : "New Chat"))

        if forceNew {
            guard let id = startNewChatSessionSync(
                name: safeName,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                activateInUI: activateInUI,
                setActiveForTab: true,
                reuseBlankSession: false
            ) else {
                throw ChatToolError.internalError("Failed to create chat session")
            }
            return (id, true)
        }

        let candidate = implicitContinuationCandidate(
            tabID: resolvedTabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI
        )
        let reservableCandidate = candidate.flatMap {
            isSessionStreaming($0.id) ? nil : $0
        }
        if enforceExpectedImplicitCandidate,
           reservableCandidate?.id != expectedImplicitCandidateID
        {
            throw ChatToolError.internalError(
                "The continuation chat changed after request preflight. Retry the call."
            )
        }

        if let candidate = reservableCandidate {
            if let desiredName,
               !desiredName.isEmpty,
               desiredName != candidate.name
            {
                renameSession(id: candidate.id, newName: ChatSession.validatedName(desiredName))
            }
            return (candidate.id, false)
        }

        guard let id = startNewChatSessionSync(
            name: safeName.isEmpty ? "New Chat" : safeName,
            tabID: resolvedTabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI,
            setActiveForTab: true,
            reuseBlankSession: false
        ) else {
            throw ChatToolError.internalError("Failed to create chat session")
        }
        return (id, true)
    }

    struct OraclePreparedRequestSnapshot {
        let message: AIMessage
        let budget: OracleRequestBudgetEstimate
        let conversationRevision: Int?
    }

    /// Packages and budgets one prospective Oracle turn without mutating chat state. The returned
    /// `AIMessage` is the same value later handed to the provider after reservation.
    @MainActor
    private func prepareOracleRequestSnapshot(
        userMessage: String,
        conversationSessionID: UUID?,
        model: AIModel,
        chatPresetID: UUID?,
        mode: PromptViewModel.PlanActMode,
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext?,
        reviewGitContext: FrozenPromptGitReviewContext,
        gitInclusionOverride: GitInclusion?,
        requestedMaxOutputTokens: Int?,
        promptVM: PromptViewModel
    ) async throws -> OraclePreparedRequestSnapshot {
        var conversation = conversationSessionID.map {
            buildConversationEntries(for: $0)
        } ?? []
        let conversationRevision = conversationSessionID.map {
            self.conversationRevision(for: $0)
        }
        conversation.append(ConversationEntry(role: .user, content: userMessage))

        let chatPreset: ChatPreset = if let chatPresetID,
                                        let resolved = ChatPresetManager.shared.preset(with: chatPresetID)
        {
            resolved
        } else {
            promptVM.currentChatPreset()
        }
        let promptContext = promptVM.resolvedPromptContext(from: chatPreset)
        let packagedMessage = await promptVM.packagePrompt(
            conversation: conversation,
            overrideModel: model,
            overridePromptConfig: promptContext,
            overrideChatPreset: chatPreset,
            overrideMode: mode,
            gitInclusionOverride: gitInclusionOverride,
            gitBaseOverride: nil,
            selectionOverride: selection,
            lookupContextOverride: lookupContext,
            reviewGitContextOverride: reviewGitContext
        )

        let capabilities = AIModelCapabilityMetadata.resolve(for: model)
        let contextWindow: Int?
        #if DEBUG
            if let override = oracleContextWindowOverrideForTesting {
                contextWindow = override(model)
            } else {
                contextWindow = capabilities.contextWindowTokens
            }
        #else
            contextWindow = capabilities.contextWindowTokens
        #endif
        let budget = OracleRequestBudgetEstimator.estimate(
            message: packagedMessage,
            contextWindowTokens: contextWindow,
            requestedMaxOutputTokens: requestedMaxOutputTokens,
            modelMaxOutputTokens: capabilities.maxOutputTokens
        )
        let hardLimitIsExact: Bool
        #if DEBUG
            hardLimitIsExact = oracleContextWindowOverrideForTesting != nil
                ? contextWindow != nil
                && oracleContextWindowSourceOverrideForTesting != .providerFallback
                : capabilities.windowSource == .exact
        #else
            hardLimitIsExact = capabilities.windowSource == .exact
        #endif
        guard !hardLimitIsExact || !budget.exceedsKnownContextWindow else {
            throw ChatToolError.oracleContextOverflow(budget)
        }
        #if DEBUG
            if let conversationSessionID {
                await oraclePreflightPreparedObserverForTesting?(
                    conversationSessionID
                )
            }
        #endif
        return OraclePreparedRequestSnapshot(
            message: packagedMessage,
            budget: budget,
            conversationRevision: conversationRevision
        )
    }

    /// Full implementation of the shared oracle send backend.
    @MainActor
    func tool_chatSend(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil
    ) async throws
        -> [String: Value]
    {
        // ────────── 1. Validate & extract parameters ──────────
        let removedArgs = ["selected_paths", "git_scope", "git_base"].filter { args[$0] != nil }
        if !removedArgs.isEmpty {
            throw ChatToolError.invalidParams(
                "ask_oracle no longer accepts \(removedArgs.joined(separator: ", ")). Use manage_selection for selection and git tools for git context."
            )
        }

        let useTabPrompt = args["use_tab_prompt"]?.boolValue ?? false
        let rawMessage = args["message"]?.stringValue ?? ""

        // Resolve message: either from tab prompt or explicit message parameter
        let message: String
        if useTabPrompt {
            let base = tabContext?.packaging.promptText ?? promptVM.promptText
            message = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("Active tab prompt is empty (use_tab_prompt=true)")
            }
        } else {
            message = rawMessage
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("message cannot be empty")
            }
        }

        let mode = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(mode) else {
            throw ChatToolError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        let chatName = args["chat_name"]?.stringValue
        let chatIdIn = args["chat_id"]?.stringValue
        let newChat = args["new_chat"]?.boolValue ?? false
        let modelParam = args["model"]?.stringValue
        if newChat,
           let chatIdIn,
           !chatIdIn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ChatToolError.invalidParams("chat_id and new_chat:true cannot be used together")
        }
        // Deprecated compatibility parameter: Oracle replies are text-only and no longer emit diffs.
        _ = args["include_diffs"]?.boolValue
        let selectionOverride = tabContext?.packaging.selection
        let lookupContextOverride = tabContext?.packaging.lookupContext
        let reviewGitContextOverride = tabContext?.packaging.reviewGitContext
        let gitInclusionOverride = tabContext?.packaging.gitInclusionOverride
        let requestedMaxOutputTokens = args["max_output_tokens"]?.intValue
        let requiresAskOraclePreflight = tabContext?.origin == .askOracle

        // ────────── 2. Handle model selection ──────────
        let presetsManager = ModelPresetsManager.shared
        let allPresets = presetsManager.allPresets()

        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID

        // Implicit-continuation candidate selection depends on the activation flag, so a value is
        // needed before model selection. It is deliberately NOT reused for `locateOrCreateChat`:
        // model selection suspends, and a user send starting in that window must still suppress
        // activation. Step 3 recomputes it against live state immediately before mutating.
        let preResolutionActivation: Bool
        if let tabContext {
            let isFocusedTab = (promptVM.activeComposeTabID == tabContext.tabID)
            let activeSessionID = workspaceManager.activeChatSessionID(forTabID: tabContext.tabID)
                ?? currentSessionID.flatMap { currentID in
                    sessions.first(where: { $0.id == currentID && $0.composeTabID == tabContext.tabID })?.id
                }
            let isUserStreaming = isSessionStreaming(activeSessionID)
            preResolutionActivation = isFocusedTab && !isUserStreaming
        } else {
            preResolutionActivation = true
        }

        // A continuation that omits `model` must inherit the lane's own preset rather than re-run
        // automatic selection. Resolve the target first, through the same resolver and the same
        // tab/owner guards `locateOrCreateChat` uses below, so the two can never disagree about
        // which session this call means.
        //
        // This step claims no Agent Mode ownership, activates nothing, and renames nothing, so a
        // model-resolution failure leaves ownership and UI state untouched. It is not perfectly
        // side-effect free: resolving a persisted-only chat appends it to the in-memory session
        // cache, which `locateOrCreateChat` would do moments later on the success path.
        //
        // When resolution or a guard fails we leave this nil and fall through: `locateOrCreateChat`
        // stays the single source of the canonical not-found / wrong-tab / wrong-owner errors.
        var continuationLane: (sessionID: UUID, attribution: OracleLaneAttribution)?
        if !newChat, modelParam == nil {
            let requestedChatID = chatIdIn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !requestedChatID.isEmpty {
                if let existing = try await resolveSessionForExplicitContinuation(
                    id: requestedChatID,
                    tabID: tabID
                ),
                    Self.sessionBelongsToResolvedTab(existing, tabID: tabID),
                    Self.sessionMatchesOracleOwnerForExplicitContinuation(
                        existing,
                        agentModeSessionID: tabContext?.agentModeSessionID,
                        agentModeRunID: tabContext?.agentModeRunID
                    )
                {
                    continuationLane = (existing.id, OracleLaneAttribution(session: existing))
                }
            } else if let resumed = implicitContinuationCandidate(
                tabID: tabID,
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID,
                activateInUI: preResolutionActivation
            ) {
                // An implicit continuation (no `chat_id`, no `new_chat`) silently resumes the most
                // recent eligible chat, so it can drift onto another preset exactly like an
                // explicit continuation could. Compaction-recovery guidance steers agents into
                // this path, so it inherits on the same terms.
                continuationLane = (resumed.id, OracleLaneAttribution(session: resumed))
            }
        }

        let modelSelection = try await selectModel(
            modelParam: modelParam,
            mode: mode,
            allPresets: allPresets,
            promptVM: promptVM,
            presetMatchPolicy: tabContext?.origin == .askOracle ? .exactOnly : .fuzzyAllowed,
            laneAttribution: continuationLane?.attribution
        )

        let selectedModel = modelSelection.model
        let mcpControlledModel = modelSelection.mcpControlInfo
        let overrideModelName = selectedModel.displayName
        let overrideChatPresetName: String? = {
            if let presetID = modelSelection.chatPresetID,
               let chatPreset = ChatPresetManager.shared.preset(with: presetID)
            {
                return chatPreset.name
            }
            // Fallback: map the requested mode to a built-in chat preset so the orange chip matches the active mode
            if let builtIn = findBuiltInPreset(for: mode) {
                return builtIn.name
            }
            return nil
        }()

        // ────────── 3. Resolve chat session ──────────
        // Recomputed against live state: model selection suspended above, and a user send that
        // started in that window must still suppress activation.
        let shouldActivate: Bool
        if let tabContext {
            let isFocusedTab = (promptVM.activeComposeTabID == tabContext.tabID)
            let activeSessionID = workspaceManager.activeChatSessionID(forTabID: tabContext.tabID)
                ?? currentSessionID.flatMap { currentID in
                    sessions.first(where: { $0.id == currentID && $0.composeTabID == tabContext.tabID })?.id
                }
            shouldActivate = isFocusedTab && !isSessionStreaming(activeSessionID)
        } else {
            shouldActivate = true
        }
        let previousActiveChatSessionID = tabID.flatMap {
            workspaceManager.activeChatSessionID(forTabID: $0)
        }
        let requestedChatID = chatIdIn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usesExplicitChatID = !requestedChatID.isEmpty

        // Explicit chat_id keeps the async locate path (ownership / disk hydrate / busy).
        // Force-new and true-implicit sends choose+reserve in one synchronous MainActor
        // turn so concurrent peers cannot both latch onto the same non-streaming chat.
        let chatID: UUID
        let createdFreshChat: Bool
        let sendStart: SendStart
        let outputReserveTokens: Int?
        let effectiveMode = PromptViewModel.PlanActMode(rawValue: mode.capitalized) ?? .chat
        #if DEBUG
            let packagingTrace = OracleReviewPackagingDiagnostics.makeTraceContext(
                tabContext: tabContext,
                observer: oracleReviewPackagingTraceObserverForTesting
            )
        #endif

        if usesExplicitChatID {
            chatID = try await locateOrCreateChat(
                chatIdIn,
                desiredName: chatName,
                forceNew: false,
                tabID: tabID,
                activateInUI: shouldActivate,
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID,
                deferContinuationMutation: true
            )
            createdFreshChat = false
            if let continuationLane, continuationLane.sessionID != chatID {
                throw ChatToolError.internalError(
                    "This chat was re-resolved to a different session while its model was being selected. Retry the call."
                )
            }
            let preparedRequest: OraclePreparedRequestSnapshot?
            if requiresAskOraclePreflight {
                guard let selectionOverride, let reviewGitContextOverride else {
                    throw ChatToolError.internalError(
                        "ask_oracle preflight is missing its immutable packaging context"
                    )
                }
                let prepare = {
                    try await self.prepareOracleRequestSnapshot(
                        userMessage: message,
                        conversationSessionID: chatID,
                        model: selectedModel,
                        chatPresetID: modelSelection.chatPresetID,
                        mode: effectiveMode,
                        selection: selectionOverride,
                        lookupContext: lookupContextOverride,
                        reviewGitContext: reviewGitContextOverride,
                        gitInclusionOverride: gitInclusionOverride,
                        requestedMaxOutputTokens: requestedMaxOutputTokens,
                        promptVM: promptVM
                    )
                }
                #if DEBUG
                    preparedRequest = try await OracleReviewPackagingDiagnostics.withTrace(
                        packagingTrace,
                        operation: prepare
                    )
                #else
                    preparedRequest = try await prepare()
                #endif
            } else {
                preparedRequest = nil
            }
            outputReserveTokens = preparedRequest?.budget.outputReserveTokens
            pinSession(chatID)
            let send = {
                await self.sendMessage(
                    message,
                    sessionID: chatID,
                    overrideModel: selectedModel,
                    overrideModelPresetID: modelSelection.modelPresetID,
                    overrideChatPresetID: modelSelection.chatPresetID,
                    overrideMode: effectiveMode,
                    gitInclusionOverride: gitInclusionOverride,
                    gitBaseOverride: nil,
                    selectionOverride: selectionOverride,
                    lookupContextOverride: lookupContextOverride,
                    reviewGitContextOverride: reviewGitContextOverride,
                    overrideAIMessage: preparedRequest?.message,
                    expectedConversationRevision: preparedRequest?
                        .conversationRevision,
                    overlapPolicy: .rejectIfBusy,
                    origin: .mcp
                )
            }
            #if DEBUG
                sendStart = await OracleReviewPackagingDiagnostics.withTrace(
                    packagingTrace,
                    operation: send
                )
            #else
                sendStart = await send()
            #endif
        } else {
            var preparedContinuationSessionID: UUID?
            if !newChat,
               let candidate = implicitContinuationCandidate(
                   tabID: tabID,
                   agentModeSessionID: tabContext?.agentModeSessionID,
                   agentModeRunID: tabContext?.agentModeRunID,
                   activateInUI: shouldActivate
               ),
               !isSessionStreaming(candidate.id)
            {
                // Load only the conversation needed for packaging. Activation and
                // ownership remain unchanged until the atomic reservation succeeds.
                guard await ensureSessionLoadedForBackground(candidate) != nil else {
                    throw ChatToolError.internalError(
                        "Failed to load the continuation chat"
                    )
                }
                preparedContinuationSessionID = candidate.id
            }

            let preparedRequest: OraclePreparedRequestSnapshot?
            if requiresAskOraclePreflight {
                guard let selectionOverride, let reviewGitContextOverride else {
                    throw ChatToolError.internalError(
                        "ask_oracle preflight is missing its immutable packaging context"
                    )
                }
                let prepare = {
                    try await self.prepareOracleRequestSnapshot(
                        userMessage: message,
                        conversationSessionID: newChat ? nil : preparedContinuationSessionID,
                        model: selectedModel,
                        chatPresetID: modelSelection.chatPresetID,
                        mode: effectiveMode,
                        selection: selectionOverride,
                        lookupContext: lookupContextOverride,
                        reviewGitContext: reviewGitContextOverride,
                        gitInclusionOverride: gitInclusionOverride,
                        requestedMaxOutputTokens: requestedMaxOutputTokens,
                        promptVM: promptVM
                    )
                }
                #if DEBUG
                    preparedRequest = try await OracleReviewPackagingDiagnostics.withTrace(
                        packagingTrace,
                        operation: prepare
                    )
                #else
                    preparedRequest = try await prepare()
                #endif
            } else {
                preparedRequest = nil
            }
            outputReserveTokens = preparedRequest?.budget.outputReserveTokens

            // Choose and reserve must share one sync turn — no await between them.
            let performAtomicChooseAndReserve: () throws -> (UUID, Bool, SendStart) = {
                let choice = try self.chooseMCPChatForSendSync(
                    desiredName: chatName,
                    forceNew: newChat,
                    tabID: tabID,
                    activateInUI: shouldActivate,
                    agentModeSessionID: tabContext?.agentModeSessionID,
                    agentModeRunID: tabContext?.agentModeRunID,
                    expectedImplicitCandidateID: preparedContinuationSessionID,
                    enforceExpectedImplicitCandidate: !newChat
                )
                if let continuationLane, continuationLane.sessionID != choice.chatID {
                    throw ChatToolError.internalError(
                        "This chat was re-resolved to a different session while its model was being selected. Retry the call."
                    )
                }
                if requiresAskOraclePreflight, !newChat {
                    if let preparedContinuationSessionID {
                        guard preparedContinuationSessionID == choice.chatID else {
                            throw ChatToolError.internalError(
                                "The continuation chat changed after request preflight. Retry the call."
                            )
                        }
                    } else if !choice.createdFresh {
                        throw ChatToolError.internalError(
                            "A continuation chat appeared after request preflight. Retry the call."
                        )
                    }
                }
                self.pinSession(choice.chatID)
                let started = self.beginSendMessageReservation(
                    message,
                    targetSessionID: choice.chatID,
                    overrideModel: selectedModel,
                    overrideModelPresetID: modelSelection.modelPresetID,
                    overrideChatPresetID: modelSelection.chatPresetID,
                    overrideMode: effectiveMode,
                    gitInclusionOverride: gitInclusionOverride,
                    gitBaseOverride: nil,
                    selectionOverride: selectionOverride,
                    lookupContextOverride: lookupContextOverride,
                    reviewGitContextOverride: reviewGitContextOverride,
                    overrideAIMessage: preparedRequest?.message,
                    expectedConversationRevision: preparedRequest?
                        .conversationRevision,
                    origin: .mcp
                )
                return (choice.chatID, choice.createdFresh, started)
            }
            #if DEBUG
                let atomic = try await OracleReviewPackagingDiagnostics.withTrace(packagingTrace) {
                    try performAtomicChooseAndReserve()
                }
            #else
                let atomic = try performAtomicChooseAndReserve()
            #endif
            chatID = atomic.0
            createdFreshChat = atomic.1
            sendStart = atomic.2
        }
        defer { unpinSession(chatID) }

        let queryId: UUID
        switch sendStart {
        case let .started(startedQueryID):
            queryId = startedQueryID
        case .rejectedSessionBusy:
            throw ChatToolError.oracleSessionBusy(
                "This chat is still streaming. Pass new_chat:true or a different chat_id, or wait. In Agent Mode, use oracle_chat_log with the explicit chat_id to inspect the lane."
            )
        case .rejectedTabConcurrencyLimit:
            // A freshly created target that never reserved must not linger as an orphan
            // or steal the tab's active-chat pointer.
            #if DEBUG
                if let observer = oracleRejectedNewSessionCleanupObserverForTesting {
                    await observer(chatID, tabID)
                }
            #endif
            if createdFreshChat,
               let rejectedSession = sessions.first(where: { $0.id == chatID }),
               rejectedSession.effectiveMessageCount == 0
            {
                // Restore only while the rejected session still owns the tab pointer.
                // This check-and-set is synchronous on MainActor; doing it before
                // deletion prevents cleanup awaits from overwriting a newer lane.
                if let tabID,
                   workspaceManager.activeChatSessionID(forTabID: tabID) == chatID
                {
                    workspaceManager.setActiveChatSessionID(previousActiveChatSessionID, forTabID: tabID)
                }
                await deleteSession(rejectedSession)
            }
            throw ChatToolError.oracleConcurrencyLimit(
                "2 Oracle streams are already running in this tab. Wait for one to finish, then retry. In Agent Mode, use oracle_chat_log with each explicit chat_id to inspect the active lanes."
            )
        case let .failed(reason):
            throw ChatToolError.invalidParams(reason)
        }

        // Continuation activation, ownership, and naming are committed only after
        // overflow validation and the atomic reservation both succeed.
        if !createdFreshChat,
           let continuationSession = sessions.first(where: { $0.id == chatID })
        {
            await activateResolvedChatSession(
                continuationSession,
                resolvedTabID: tabID,
                activateInUI: shouldActivate
            )
            await applyOracleOwnerIfNeeded(
                sessionID: chatID,
                tabID: tabID,
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID
            )
            if let chatName,
               !chatName.isEmpty,
               chatName != continuationSession.name
            {
                renameSession(
                    id: chatID,
                    newName: ChatSession.validatedName(chatName)
                )
            }
        }

        // Publish ephemeral UI state only after this send owns the session.
        if let mcpControlledModel {
            setMCPSessionUIState(
                MCPSessionUIState(
                    modelInfo: mcpControlledModel,
                    overrideModelName: overrideModelName,
                    overrideChatPresetName: overrideChatPresetName
                ),
                for: chatID
            )
        } else {
            clearMCPSessionUIState(for: chatID)
        }

        try await waitUntilMessageFinalised(queryId)

        // ────────── 6. Build typed reply ──────────
        let errors: [String] = []
        let aiMsg = getChatMessage(withId: queryId).flatMap { $0.isUser ? nil : $0 }

        let replyObj = ChatSendReply(
            chatId: chatID,
            shortId: sessions.first(where: { $0.id == chatID })?.shortID ?? "",
            mode: mode,
            response: aiMsg?.content,
            errors: errors.isEmpty ? nil : errors
        )

        // Serialise to MCP Value → dictionary
        guard case var .object(dict) = replyObj.toMCPValue() else {
            throw ChatToolError.internalError("failed to encode reply")
        }
        if let tabID {
            dict["context_id"] = .string(tabID.uuidString)
        }
        if let agentModeSessionID = tabContext?.agentModeSessionID {
            dict["agent_session_id"] = .string(agentModeSessionID.uuidString)
        }
        if let agentModeRunID = tabContext?.agentModeRunID {
            dict["agent_run_id"] = .string(agentModeRunID.uuidString)
        }
        if modelSelection.modelSource == "preset" {
            // Internal UI-only fields are captured by Agent Mode tool cards and are never
            // formatted into MCP output or retained in agent-facing transcript summaries.
            dict["ui_model_id"] = .string(selectedModel.rawValue)
            dict["ui_model_name"] = .string(selectedModel.displayName)
        } else {
            dict["model_id"] = .string(selectedModel.rawValue)
            dict["model_name"] = .string(selectedModel.displayName)
        }
        dict["model_selection"] = .string(modelSelection.selectionKind.rawValue)
        dict["model_source"] = .string(modelSelection.modelSource)
        if let modelPresetID = modelSelection.modelPresetID {
            dict["model_preset_id"] = .string(modelPresetID.uuidString)
        }
        if let modelPresetName = modelSelection.modelPresetName {
            dict["model_preset_name"] = .string(modelPresetName)
        }
        if let usage = buildOracleUsageEcho(
            assistantMessageID: queryId,
            model: selectedModel,
            outputReserveTokens: outputReserveTokens
        ) {
            dict["usage"] = .object(usage)
        }
        return dict
    }

    /// Neutral usage echo for ask_oracle / oracle_send results.
    /// Prefers provider-reported prompt tokens; otherwise estimates the packaged request.
    @MainActor
    func buildOracleUsageEcho(
        assistantMessageID: UUID,
        model: AIModel,
        outputReserveTokens: Int? = nil
    ) -> [String: Value]? {
        let capabilities = AIModelCapabilityMetadata.resolve(for: model)
        let assistant = getChatMessage(withId: assistantMessageID).flatMap { $0.isUser ? nil : $0 }
        let source: String
        let inputTokens: Int
        if let providerTokens = assistant?.promptTokens {
            inputTokens = max(0, providerTokens)
            source = "provider_reported"
        } else if let estimate = oracleRequestInputTokenEstimate(for: assistantMessageID) {
            inputTokens = estimate
            source = "app_estimate"
        } else {
            return nil
        }

        var usage: [String: Value] = [
            "input_tokens": .int(inputTokens),
            "source": .string(source)
        ]
        if let window = capabilities.exactContextWindowTokens,
           let pct = AIModelCapabilityMetadata.safeUsagePercentage(
               inputTokens: inputTokens,
               contextWindowTokens: window
           )
        {
            usage["context_window"] = .int(window)
            usage["pct"] = .int(pct)
        }
        if let maxOutput = capabilities.maxOutputTokens {
            usage["max_output_tokens"] = .int(maxOutput)
        }
        if let outputReserveTokens {
            usage["output_reserve_tokens"] = .int(outputReserveTokens)
        }
        return usage
    }

    /// Legacy entry point kept for compatibility with `MCPServerViewModel`.
    /// Delegates to the newer implementation that returns the enriched log.
    @MainActor
    func handleChatGetLogTool(chatIdRaw: String?) async throws -> [String: Value] {
        var args: [String: Value] = ["include_diffs": .bool(false)]
        if let chatIdRaw, !chatIdRaw.isEmpty {
            args["chat_id"] = .string(chatIdRaw)
        }
        return try await tool_chatGetLog(args: args)
    }

    /// Full implementation of **chat_get_log** MCP tool.
    /// Returns a richer, size-optimised message log.
    @MainActor
    func tool_chatGetLog(args: [String: Value]) async throws -> [String: Value] {
        let chatIdIn = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeDiffs = args["include_diffs"]?.boolValue ?? false
        let limit = args["limit"]?.intValue ?? 3 // Default to 3 messages

        guard let workspace = workspaceManager.activeWorkspace else {
            throw ChatToolError.invalidParams("No active workspace loaded")
        }

        let scope = requestedChatInspectionScope(from: args)
        let tabID = try resolvedInspectionTabID(from: args)
        if scope == .tab, tabID == nil {
            throw ChatToolError.invalidParams("scope=tab requires an active compose tab or an explicit context_id")
        }
        let normalizedChatID = (chatIdIn?.isEmpty == false) ? chatIdIn : nil
        let resolvedSession = if let normalizedChatID {
            try await resolveSessionForInspection(id: normalizedChatID, workspace: workspace, tabID: tabID)
        } else {
            try await mostRecentSessionForInspection(workspace: workspace, tabID: tabID)
        }

        let msgs = await buildMCPMessageLog(from: resolvedSession.messages, includeDiffs: includeDiffs, limit: limit)
        var result: [String: Value] = [
            "chat_id": .string(resolvedSession.shortID),
            "messages": .array(msgs),
            "scope": .string(scope.rawValue)
        ]
        if let resolvedTabID = tabID ?? resolvedSession.composeTabID {
            result["context_id"] = .string(resolvedTabID.uuidString)
        }

        return result
    }

    private static func preferredOracleLogSession(
        forTabID tabID: UUID,
        sessions: [ChatSession],
        activeSessionID: UUID?,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) -> ChatSession? {
        let tabSessions = sessions.filter { $0.composeTabID == tabID }
        let hasOwner = agentModeSessionID != nil || agentModeRunID != nil
        let sortedCandidates: [ChatSession] = if hasOwner {
            Self.rankedOracleOwnerCandidates(
                tabSessions,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                allowUnownedLegacy: false
            )
        } else {
            // Fail-closed for ownerless callers too: an Agent Mode log request whose
            // owner resolution came up empty must not read agent-owned lanes. Only
            // genuinely unowned (UI/legacy) chats stay visible.
            tabSessions
                .filter {
                    Self.sessionMatchesOracleOwner(
                        $0,
                        agentModeSessionID: nil,
                        agentModeRunID: nil,
                        allowUnownedLegacy: true
                    )
                }
                .sorted(by: { $0.savedAt > $1.savedAt })
        }

        // Policy: the tab's active lane wins across tiers when non-empty — log recovery
        // follows what the tab currently points at, even over an inactive exact-run lane.
        if let activeSessionID,
           let activeSession = sortedCandidates.first(where: { $0.id == activeSessionID }),
           activeSession.hasMessages
        {
            return activeSession
        }
        if let mostRecentNonEmpty = sortedCandidates
            .filter(\.hasMessages)
            .first
        {
            return mostRecentNonEmpty
        }
        return sortedCandidates.first
    }

    static func test_preferredOracleLogSession(
        forTabID tabID: UUID,
        sessions: [ChatSession],
        activeSessionID: UUID?,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) -> ChatSession? {
        preferredOracleLogSession(
            forTabID: tabID,
            sessions: sessions,
            activeSessionID: activeSessionID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )
    }

    /// Agent-mode helper for a stripped-down, tab-scoped Oracle chat log.
    /// Returns only role/text messages and never creates sessions.
    @MainActor
    func tool_oracleChatLog(
        args: [String: Value],
        tabID: UUID,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) async throws -> [String: Value] {
        let chatIDIn = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChatID = (chatIDIn?.isEmpty == false) ? chatIDIn : nil

        let limit: Int = {
            guard let rawLimit = args["limit"]?.intValue else { return 8 }
            return min(max(rawLimit, 1), 50)
        }()
        let includeUser = args["include_user"]?.boolValue ?? false

        let resolvedSession: ChatSession
        if let normalizedChatID {
            if let rejection = clonedHandoffContinuationRejection(
                chatID: normalizedChatID,
                tabID: tabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) {
                throw ChatToolError.invalidParams(rejection)
            }
            guard let found = resolveSession(id: normalizedChatID) else {
                throw ChatToolError.invalidParams("Chat with ID '\(normalizedChatID)' not found")
            }
            guard found.composeTabID == tabID else {
                throw ChatToolError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' belongs to a different tab. oracle_utils op='log' can only read chats from the current tab during agent mode."
                )
            }
            if let rejection = Self.oracleOwnerContinuationRejection(
                found,
                chatID: normalizedChatID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) {
                throw ChatToolError.invalidParams(rejection)
            }
            guard let loaded = await ensureSessionLoadedForBackground(found) else {
                throw ChatToolError.internalError("Failed to load chat session '\(normalizedChatID)'")
            }
            resolvedSession = loaded
        } else {
            guard let preferredSession = Self.preferredOracleLogSession(
                forTabID: tabID,
                sessions: sessions,
                activeSessionID: workspaceManager.activeChatSessionID(forTabID: tabID),
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) else {
                throw ChatToolError.invalidParams("No chats found in the current tab")
            }
            guard let loaded = await ensureSessionLoadedForBackground(preferredSession) else {
                throw ChatToolError.internalError("Failed to load the preferred chat for the current tab")
            }
            resolvedSession = loaded
        }

        let maxCharsPerMessage: Int = {
            if let raw = args["max_chars"]?.intValue {
                return max(1, raw)
            }
            return OracleResponsePresentation.defaultChatLogMaxCharsPerMessage
        }()
        let maxTotalChars: Int? = {
            guard let raw = args["max_total_chars"]?.intValue else { return nil }
            return max(1, raw)
        }()
        let part: OracleChatLogPart = {
            if let raw = args["part"]?.stringValue {
                return (try? OracleChatLogPart.parse(raw)) ?? .default
            }
            return .default
        }()

        let filteredMessages = resolvedSession.messages.filter { includeUser || !$0.isUser }
        let trimmedMessages = Array(filteredMessages.suffix(limit))
        var messageObjects: [[String: Value]] = trimmedMessages.map { msg in
            [
                "role": .string(msg.isUser ? "user" : "assistant"),
                "text": .string(
                    OracleResponsePresentation.compactChatLogText(
                        msg.rawText,
                        maxChars: maxCharsPerMessage,
                        part: part
                    )
                )
            ]
        }
        if let maxTotalChars {
            OracleResponsePresentation.enforceTotalCharCeiling(
                messages: &messageObjects,
                maxTotalChars: maxTotalChars
            )
        }
        let msgArray: [Value] = messageObjects.map { .object($0) }

        var result: [String: Value] = [
            "action": .string("log"),
            "chat_id": .string(resolvedSession.shortID),
            "messages": .array(msgArray),
            "context_id": .string(tabID.uuidString),
            "max_chars": .int(maxCharsPerMessage),
            "part": .string(part.rawValue)
        ]
        if let maxTotalChars {
            result["max_total_chars"] = .int(maxTotalChars)
        }
        if let agentModeSessionID = resolvedSession.agentModeSessionID ?? agentModeSessionID {
            result["agent_session_id"] = .string(agentModeSessionID.uuidString)
        }
        if let agentModeRunID = resolvedSession.agentModeRunID ?? agentModeRunID {
            result["agent_run_id"] = .string(agentModeRunID.uuidString)
        }
        return result
    }

    /// Full implementation of **chat_list** MCP tool.
    @MainActor
    func tool_chatList(args: [String: Value]) async throws -> [String: Value] {
        let limit = args["limit"]?.intValue ?? 10

        // Get active workspace
        guard let workspace = workspaceManager.activeWorkspace else {
            return ["chats": .array([])]
        }

        let scope = requestedChatInspectionScope(from: args)
        let resolvedTabID = try resolvedInspectionTabID(from: args)
        if scope == .tab, resolvedTabID == nil {
            throw ChatToolError.invalidParams("scope=tab requires an active compose tab or an explicit context_id")
        }

        // Get recent sessions from ChatDataService
        let metadataList = try await chatData.recentSessions(
            for: workspace,
            limit: limit,
            composeTabID: resolvedTabID
        )

        let formatter = Self.iso8601Formatter

        // Always expose every active stream first, even if its initial autosave
        // has not reached disk yet. Completed persisted sessions fill the rest.
        let liveStreamingSessions = sessions
            .filter { session in
                session.workspaceID == workspace.id &&
                    streamingSessions.contains(session.id) &&
                    (resolvedTabID == nil || session.composeTabID == resolvedTabID)
            }
            .sorted { $0.savedAt > $1.savedAt }
        let liveStreamingIDs = Set(liveStreamingSessions.map(\.id))

        func liveSessionValue(_ session: ChatSession) -> Value {
            let activeForTab = session.composeTabID.flatMap { workspaceManager.activeChatSessionID(forTabID: $0) } == session.id
            var chatDict: [String: Value] = [
                "id": .string(session.shortID),
                "name": .string(session.name),
                "last_modified": .string(formatter.string(from: session.savedAt)),
                "message_count": .int(session.effectiveMessageCount),
                "selected_files": .array(session.selectedFilePaths.map(Value.string)),
                "is_current": .bool(session.id == currentSessionID),
                "is_active_for_tab": .bool(activeForTab),
                "is_streaming": .bool(true)
            ]
            if let tabID = session.composeTabID {
                chatDict["context_id"] = .string(tabID.uuidString)
            }
            if let modelID = session.lastSendModelID {
                chatDict["model_id"] = .string(modelID)
            }
            if let modelName = session.lastSendModelDisplayName ?? session.lastResponseModelDisplayName {
                chatDict["model_name"] = .string(modelName)
            }
            return .object(chatDict)
        }

        func persistedSessionValue(_ meta: ChatSessionMeta) -> Value {
            let activeForTab = meta.composeTabID.flatMap { workspaceManager.activeChatSessionID(forTabID: $0) } == meta.id
            var chatDict: [String: Value] = [
                "id": .string(meta.shortID),
                "name": .string(meta.name),
                "last_modified": .string(formatter.string(from: meta.lastModified)),
                "message_count": .int(meta.messageCount),
                "selected_files": .array(meta.selectedFilePaths.map(Value.string)),
                "is_current": .bool(meta.id == currentSessionID),
                "is_active_for_tab": .bool(activeForTab),
                "is_streaming": .bool(streamingSessions.contains(meta.id))
            ]
            if let tabID = meta.composeTabID {
                chatDict["context_id"] = .string(tabID.uuidString)
            }
            if let modelID = meta.lastSendModelID {
                chatDict["model_id"] = .string(modelID)
            }
            if let modelName = meta.lastSendModelDisplayName {
                chatDict["model_name"] = .string(modelName)
            }
            return .object(chatDict)
        }

        let completedLimit = max(0, limit - liveStreamingSessions.count)
        let persistedCompleted = metadataList
            .filter { !liveStreamingIDs.contains($0.id) }
            .prefix(completedLimit)
        let chatsArray = liveStreamingSessions.map(liveSessionValue)
            + persistedCompleted.map(persistedSessionValue)

        var result: [String: Value] = [
            "chats": .array(chatsArray),
            "scope": .string(scope.rawValue)
        ]
        if let resolvedTabID {
            result["context_id"] = .string(resolvedTabID.uuidString)
        }
        return result
    }

    // MARK: - Headless Generation (Plan & Question)

    /// Run a plan request without going through the normal sendMessage pipeline.
    /// - Parameters:
    ///   - useChatModelDirectly: If true, bypasses MCP preset resolution and uses the current chat model.
    ///                           Use this for UI-triggered requests (e.g., from discover view).
    ///   - onProgress: Optional callback invoked with accumulated text and reasoning during streaming.
    @MainActor
    func runHeadlessPlan(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        useChatModelDirectly: Bool = false,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Plan",
            tabID: tabID,
            selection: selection,
            mode: .plan,
            useChatModelDirectly: useChatModelDirectly,
            onProgress: onProgress
        )
    }

    /// Run a question/chat request without going through the normal sendMessage pipeline.
    @MainActor
    func runHeadlessQuestion(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Q&A",
            tabID: tabID,
            selection: selection,
            mode: .chat,
            onProgress: onProgress
        )
    }

    /// Run a review request without going through the normal sendMessage pipeline.
    @MainActor
    func runHeadlessReview(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        gitScopeOverride: GitInclusion? = nil,
        reviewGitContext: FrozenPromptGitReviewContext? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        let frozenReviewGitContext = if let reviewGitContext {
            reviewGitContext
        } else {
            await promptViewModel.freezePromptGitReviewContext(tabID: tabID, base: "HEAD")
        }
        return try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Review",
            tabID: tabID,
            selection: selection,
            mode: .review,
            gitScopeOverride: gitScopeOverride,
            reviewGitContext: frozenReviewGitContext,
            onProgress: onProgress
        )
    }

    /// Internal: run a headless request (plan or chat) via AIQueriesService.
    /// - Builds an AIMessage from a frozen tab snapshot
    /// - Streams via AIQueriesService without touching `messages` or `isAIResponseInProgress`
    /// - Creates a `ChatSession` with the resulting user+assistant messages
    /// - Returns a `ChatSendReply` suitable for MCP or UI callers
    @MainActor
    func runHeadless(
        prompt: String,
        modelParam: String?,
        chatName: String,
        tabID: UUID,
        selection: StoredSelection,
        mode: HeadlessMode,
        useChatModelDirectly: Bool = false,
        gitScopeOverride: GitInclusion? = nil,
        reviewGitContext: FrozenPromptGitReviewContext = .automaticOnly(),
        workspaceID: UUID? = nil,
        lookupContext: WorkspaceLookupContext? = nil,
        resolvedModel: AIModel? = nil,
        resolvedModelPresetID: UUID? = nil,
        finalReviewAuthorization: ContextBuilderFinalReviewAuthorization? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        // Check cancellation at entry
        try Task.checkCancellation()

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ChatToolError.invalidParams("Prompt cannot be empty")
        }
        let userTimestamp = Date()

        // 1) Resolve model
        let model: AIModel
        let chatPresetID: UUID?
        let modelPresetID: UUID?

        if let resolvedModel {
            model = resolvedModel
            chatPresetID = nil
            modelPresetID = resolvedModelPresetID
        } else if useChatModelDirectly {
            // UI-triggered: use the current chat model directly, bypassing MCP preset logic
            model = promptViewModel.preferredAIModel
            chatPresetID = nil
            modelPresetID = nil
        } else {
            // MCP-triggered: use preset resolution logic
            let presetsManager = ModelPresetsManager.shared
            let allPresets = presetsManager.allPresets()

            try Task.checkCancellation()

            let modelSelection = try await selectModel(
                modelParam: modelParam,
                mode: mode.mcpModeName,
                allPresets: allPresets,
                promptVM: promptViewModel
            )
            model = modelSelection.model
            chatPresetID = modelSelection.chatPresetID
            modelPresetID = modelSelection.modelPresetID
        }

        let effectiveProfile = workspaceID.map {
            GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: $0)
        }
        let resolvedModelPreset = modelPresetID.flatMap { ModelPresetsManager.shared.preset(withID: $0) }
        let ohMyPiThinkingSelections: OhMyPiThinkingSelections = if let resolvedModelPreset {
            resolvedModelPreset.ohMyPiThinkingSelections
        } else if useChatModelDirectly {
            effectiveProfile?.preferredComposeOhMyPiThinkingSelections
                ?? promptViewModel.preferredModelOhMyPiThinkingSelections
        } else {
            effectiveProfile?.planningModelOhMyPiThinkingSelections
                ?? promptViewModel.planningModelOhMyPiThinkingSelections
        }

        // 2) Build snapshot
        let snapshot = HeadlessContextSnapshot(
            workspaceID: workspaceID,
            tabID: tabID,
            promptText: trimmedPrompt,
            selection: selection,
            lookupContext: lookupContext,
            reviewGitContext: reviewGitContext,
            finalReviewAuthorization: finalReviewAuthorization
        )

        try Task.checkCancellation()

        // 3) Build AIMessage from snapshot
        let packagedAIMessage = try await promptViewModel.buildHeadlessAIMessage(
            from: snapshot,
            model: model,
            mode: mode,
            gitScopeOverride: gitScopeOverride
        )
        let aiMessage = packagedAIMessage.replacingExecutionMetadata(
            ohMyPiThinkingSelections.executionMetadata(for: model)
        )

        try Task.checkCancellation()

        // 4) Stream via AIQueriesService WITHOUT touching OracleViewModel.messages
        let (streamID, stream) = try await aiQueriesService.sendPrompt(aiMessage, model: model)

        // Register this headless stream by tab ID so Discover can cancel it.
        headlessStreamsByTabID[tabID] = streamID
        defer {
            // Always clean up mapping when this headless run finishes or errors.
            headlessStreamsByTabID.removeValue(forKey: tabID)
        }

        // Stream with 4-hour timeout using single task group
        // (One Task.sleep for entire stream, not per-chunk - avoids CPU churn)
        let timeout: Duration = .seconds(4 * 60 * 60)

        let (finalText, finalReasoning, finalTokenInfo) = try await withThrowingTaskGroup(
            of: (String, String, ChatTokenInfo).self
        ) { group in
            // Timeout task - throws after 4 hours
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ChatToolError.internalError("Stream timed out after 4 hours of inactivity.")
            }

            // Streaming task - accumulates locally, returns result
            group.addTask { [stream, onProgress] in
                var accText = ""
                var accReasoning = ""
                var tokens = ChatTokenInfo()
                var iterator = stream.makeAsyncIterator()

                while let chunk = try await iterator.next() {
                    accText += chunk.text
                    if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                        accReasoning += reasoning
                        accReasoning = ReasoningTextFormatter.normalize(accReasoning)
                    }
                    if chunk.tokens.promptTokens != nil ||
                        chunk.tokens.completionTokens != nil ||
                        chunk.tokens.cost != nil
                    {
                        tokens = chunk.tokens
                    }
                    // Only hop to MainActor for progress callback
                    if let onProgress {
                        let text = accText
                        let reasoning = accReasoning.isEmpty ? nil : accReasoning
                        await MainActor.run { onProgress(text, reasoning) }
                    }
                }
                return (accText, accReasoning, tokens)
            }

            // Wait for stream to complete or timeout to fire
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let trimmedResponse = finalText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            throw ChatToolError.internalError("Request produced no content.")
        }
        let assistantTimestamp = Date()

        // 5) Create persisted ChatSession
        let (session, shortID) = try await createSessionFromHeadlessRun(
            prompt: trimmedPrompt,
            response: trimmedResponse,
            model: model,
            tokenInfo: finalTokenInfo,
            selection: selection,
            chatName: chatName,
            chatPresetID: chatPresetID,
            tabID: tabID,
            workspaceID: workspaceID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            userTimestamp: userTimestamp,
            assistantTimestamp: assistantTimestamp
        )

        // 6) Return ChatSendReply
        return ChatSendReply(
            chatId: session.id,
            shortId: shortID,
            mode: mode.mcpModeName,
            response: trimmedResponse,
            errors: nil
        )
    }

    static func headlessStoredMessages(
        prompt: String,
        response: String,
        modelName: String,
        tokenInfo: ChatTokenInfo,
        allowedPaths: [String],
        userTimestamp: Date,
        assistantTimestamp: Date
    ) -> [StoredMessage] {
        let userMessage = StoredMessage(
            isUser: true,
            rawText: prompt,
            timestamp: userTimestamp,
            sequenceIndex: 0,
            allowedFilePaths: allowedPaths
        )
        let assistantMessage = StoredMessage(
            isUser: false,
            rawText: response,
            timestamp: assistantTimestamp,
            sequenceIndex: 1,
            allowedFilePaths: allowedPaths,
            promptTokens: tokenInfo.promptTokens,
            completionTokens: tokenInfo.completionTokens,
            cost: tokenInfo.cost,
            modelName: modelName
        )
        return [userMessage, assistantMessage]
    }

    /// Helper: persist a new ChatSession from a headless run without
    /// mutating the current chat stream (no changes to `messages` or `currentSessionID`).
    @MainActor
    func createSessionFromHeadlessRun(
        prompt: String,
        response: String,
        model: AIModel,
        tokenInfo: ChatTokenInfo,
        selection: StoredSelection,
        chatName: String?,
        chatPresetID: UUID?,
        tabID: UUID,
        workspaceID: UUID? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        userTimestamp: Date = Date(),
        assistantTimestamp: Date = Date(),
        setActiveForTab: Bool = false
    ) async throws -> (session: ChatSession, shortID: String) {
        let workspace: WorkspaceModel? = if let workspaceID {
            workspaceManager.workspaces.first(where: { $0.id == workspaceID })
        } else {
            workspaceManager.activeWorkspace
        }
        guard let workspace else {
            throw ChatSessionError.invalidFilename("The target workspace for this plan chat is unavailable.")
        }

        // 1) Build StoredMessage entries
        let allowedPaths = selection.selectedPaths
        let storedMessages = Self.headlessStoredMessages(
            prompt: prompt,
            response: response,
            modelName: model.displayName,
            tokenInfo: tokenInfo,
            allowedPaths: allowedPaths,
            userTimestamp: userTimestamp,
            assistantTimestamp: assistantTimestamp
        )

        // 2) Create a ChatSession object (in-memory)
        let resolvedName = ChatSession.validatedName(
            chatName ?? "Plan – \(workspace.name)"
        )

        var session = ChatSession(
            workspaceID: workspace.id,
            composeTabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            name: resolvedName,
            messages: storedMessages,
            selectedFilePaths: allowedPaths,
            selectedPromptIDs: workspace.id == workspaceManager.activeWorkspaceID
                ? Array(promptViewModel.selectedPromptIDsForChat)
                : [],
            preferredAIModel: model.rawValue,
            selectedChatPresetID: chatPresetID,
            lastSendModelID: model.rawValue,
            lastSendModelDisplayName: model.displayName
        )

        if setActiveForTab {
            if workspaceID != nil {
                workspaceManager.setActiveChatSessionID(
                    session.id,
                    for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
                )
            } else {
                workspaceManager.setActiveChatSessionID(session.id, forTabID: tabID)
            }
        }

        // 3) Persist to disk via ChatDataService
        let fileURL = try await autosaveSession(session)
        session.fileURL = fileURL

        // 4) Register in-memory but DO NOT disturb the live session/stream
        if workspace.id == workspaceManager.activeWorkspaceID {
            sessions.append(session)
        }

        return (session, session.shortID)
    }
}
