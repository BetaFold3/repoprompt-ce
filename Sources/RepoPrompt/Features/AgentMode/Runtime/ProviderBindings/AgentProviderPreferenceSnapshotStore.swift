import Foundation

@MainActor
final class AgentProviderPreferenceSnapshotStore {
    typealias CodexMCPServerEntriesProvider = () -> [MCPIntegrationHelper.CodexServerEntry]

    private static let credentialKeyPattern =
        #"[A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|authorization)"#
    private static let credentialHeadPattern =
        #"(?is)(?<![A-Za-z0-9_])["']?(\#(credentialKeyPattern))["']?\s*[:=]\s*"#
    /// Escape-aware quoted value. A value truncated at end-of-input redacts through `\z`,
    /// including a dangling final backslash that has no character left to escape.
    private static let credentialQuotedValuePattern =
        #"(?:"(?:\\.|[^"\\])*(?:"|\\?\z)|'(?:\\.|[^'\\])*(?:'|\\?\z))"#
    private static let credentialNextAssignmentPattern =
        #"[,;|\&]?(?<![A-Za-z0-9_-])["']?\#(credentialKeyPattern)["']?\s*[:=]"#
    private static let credentialFreeTextRunPattern =
        #"\S(?:(?!\#(credentialNextAssignmentPattern))\S)*"#
    /// Internal redaction placeholder written by earlier passes. It uses private-use
    /// delimiters so a later pass can recognize its own output without trusting literal
    /// `[redacted]` text that arrived in the raw diagnostic; the caller must derive one
    /// that is absent from the raw input via `credentialRedactionPlaceholder(absentFrom:)`.
    private static let credentialRedactionPlaceholderBase = "\u{E000}rpce-redacted"
    private static let credentialRedactionPlaceholderTerminator = "\u{E001}"
    private static let credentialRedactionMarker = "[redacted]"

    private static func credentialRedactionPlaceholder(absentFrom rawValue: String) -> String {
        var candidate = credentialRedactionPlaceholderBase + credentialRedactionPlaceholderTerminator
        var suffix = 0
        while rawValue.contains(candidate) {
            suffix += 1
            candidate = "\(credentialRedactionPlaceholderBase)-\(suffix)\(credentialRedactionPlaceholderTerminator)"
        }
        return candidate
    }

    /// Ordered passes: quoted assignments, then authorization-scheme values, then free-text
    /// assignments. The free-text pass skips only values that begin with the exact,
    /// case-sensitive generated placeholder so it never re-consumes context after an earlier pass's redaction.
    private static func credentialRedactionPatterns(placeholder: String) -> [String] {
        let escapedPlaceholder = NSRegularExpression.escapedPattern(for: placeholder)
        let placeholderSkipPattern = "(?!(?-i:\(escapedPlaceholder)))"
        return [
            #"\#(credentialHeadPattern)\#(credentialQuotedValuePattern)"#,
            #"\#(credentialHeadPattern)(?:bearer|basic|token)\s+(?:\#(credentialQuotedValuePattern)|\#(credentialFreeTextRunPattern))"#,
            #"\#(credentialHeadPattern)\#(placeholderSkipPattern)\#(credentialFreeTextRunPattern)"#
        ]
    }

    let defaults: UserDefaults
    let securePermissions: AgentPermissionSecureStore?

    private let codexMCPServerEntriesProvider: CodexMCPServerEntriesProvider
    private var revisionByProviderID: [AgentProviderBindingID: Int]

    init(
        defaults: UserDefaults = .standard,
        securePermissions: AgentPermissionSecureStore? = nil,
        codexMCPServerEntries: @escaping CodexMCPServerEntriesProvider = { MCPIntegrationHelper.codexMCPServerEntries() }
    ) {
        self.defaults = defaults
        self.securePermissions = securePermissions ?? (defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil)
        codexMCPServerEntriesProvider = codexMCPServerEntries
        revisionByProviderID = Dictionary(uniqueKeysWithValues: AgentProviderBindingID.allCases.map { ($0, 0) })
    }

    func revision(for providerID: AgentProviderBindingID) -> Int {
        revisionByProviderID[providerID, default: 0]
    }

    /// Builds editable direct/top-level Settings controls for a provider.
    ///
    /// This is intentionally separate from the profile-aware runtime binding entry point
    /// below so Settings provider rows do not accidentally inherit sub-agent preview policy.
    func topLevelSettingsControlsBinding(providerID: AgentProviderBindingID) -> AgentProviderControlsBinding {
        controlsBinding(
            selectedAgent: Self.representativeAgent(for: providerID),
            selectedModelRaw: nil,
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: nil,
            claudePermissionSessionState: nil
        )
    }

    /// Builds a controls snapshot after higher-level policy has already resolved the
    /// permission profile and any externally managed reason. `isSubagent` is accepted for
    /// API compatibility with the Settings/runtime split, but subagent policy is intentionally
    /// applied by `AgentModeProviderBindingService` before reaching this store.
    func controlsBinding(
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String? = nil,
        permissionProfile: AgentProviderPermissionProfile,
        isSubagent _: Bool,
        externallyManagedReason: String?,
        claudePermissionSessionState: ClaudePermissionSessionState? = nil
    ) -> AgentProviderControlsBinding {
        let providerID = selectedAgent.providerBindingID
        let permission = permissionChromeBinding(
            for: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            profile: permissionProfile,
            externallyManagedReason: externallyManagedReason,
            claudePermissionSessionState: claudePermissionSessionState
        )
        return AgentProviderControlsBinding(
            revision: revision(for: providerID),
            selectedAgent: selectedAgent,
            providerID: providerID,
            permission: permission,
            runtimePermission: runtimePermission(for: selectedAgent, profile: permissionProfile),
            codexTools: providerID == .codex
                ? codexToolSettingsBinding(profile: permissionProfile)
                : nil,
            claudeTools: providerID == .claude
                ? claudeToolSettingsBinding(
                    profile: permissionProfile,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw
                )
                : nil
        )
    }

    func runtimePermission(
        for agent: AgentProviderKind,
        profile: AgentProviderPermissionProfile
    ) -> AgentProviderRuntimePermissionBinding {
        switch agent.providerBindingID {
        case .codex:
            let sandboxMode: CodexAgentToolPreferences.SandboxMode
            let approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy
            let approvalReviewer: CodexAgentToolPreferences.ApprovalReviewer
            switch profile {
            case .userConfigured:
                sandboxMode = CodexAgentToolPreferences.sandboxMode(defaults: defaults, secureStore: securePermissions)
                approvalPolicy = CodexAgentToolPreferences.approvalPolicy(defaults: defaults, secureStore: securePermissions)
                approvalReviewer = CodexAgentToolPreferences.approvalReviewer(defaults: defaults, secureStore: securePermissions)
            case .mcpSafeDefaults:
                let level = CodexAgentToolPreferences.PermissionLevel.autoReview
                sandboxMode = level.sandboxMode
                approvalPolicy = level.approvalPolicy
                approvalReviewer = level.approvalReviewer
            case let .providerOverride(.codex(level)):
                sandboxMode = level.sandboxMode
                approvalPolicy = level.approvalPolicy
                approvalReviewer = level.approvalReviewer
            case .providerOverride:
                let level = CodexAgentToolPreferences.PermissionLevel.defaultPermission
                sandboxMode = level.sandboxMode
                approvalPolicy = level.approvalPolicy
                approvalReviewer = level.approvalReviewer
            }
            return AgentProviderRuntimePermissionBinding(
                codexSandboxMode: sandboxMode,
                codexApprovalPolicy: approvalPolicy,
                codexApprovalReviewer: approvalReviewer
            )
        case .claude:
            let permissionMode: String = switch profile {
            case .userConfigured:
                ClaudeAgentToolPreferences.permissionMode(defaults: defaults, secureStore: securePermissions)
            case .mcpSafeDefaults:
                ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
            case let .providerOverride(.claude(level)):
                level.permissionMode
            case .providerOverride:
                ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
            }
            return AgentProviderRuntimePermissionBinding(
                claudePermissionMode: permissionMode
            )
        case .openCode:
            let level = effectiveOpenCodePermissionLevel(profile: profile)
            return AgentProviderRuntimePermissionBinding(
                acpSessionModeID: level.sessionModeID,
                acceptsPendingACPApprovalWhenActivated: level.acceptsPendingApprovalWhenActivated
            )
        case .cursor:
            let level = effectiveCursorPermissionLevel(profile: profile)
            return AgentProviderRuntimePermissionBinding(
                autoApproveAllACPToolPermissions: level.autoApprovesACPToolPermissions,
                acceptsPendingACPApprovalWhenActivated: level.autoApprovesACPToolPermissions
            )
        case .ohMyPi:
            return AgentProviderRuntimePermissionBinding()
        }
    }

    @discardableResult
    func setPermissionLevel(_ id: AgentProviderPermissionLevelID) -> AgentProviderBindingID {
        switch id {
        case let .codex(level):
            CodexAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .claude(level):
            ClaudeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .openCode(level):
            OpenCodeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case let .cursor(level):
            CursorAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
        case .ohMyPi:
            break
        }
        bumpRevision(for: id.providerID)
        return id.providerID
    }

    @discardableResult
    func applyCodexToolSettingMutation(_ mutation: CodexToolSettingMutation) -> AgentProviderBindingID {
        switch mutation {
        case let .bashTool(enabled):
            CodexAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
        case let .searchTool(enabled):
            CodexAgentToolPreferences.setSearchToolEnabled(enabled, defaults: defaults)
        case let .computerUse(enabled):
            CodexAgentModeBooleanPreference.computerUse.setEnabled(enabled, defaults: defaults)
        case let .goalSupport(enabled):
            CodexAgentModeBooleanPreference.goalSupport.setEnabled(enabled, defaults: defaults)
        case let .reasoningSummaries(enabled):
            CodexAgentModeBooleanPreference.reasoningSummaries.setEnabled(enabled, defaults: defaults)
        case let .mcpServer(normalizedName, enabled):
            CodexAgentToolPreferences.setMCPServerEnabled(
                normalizedName: normalizedName,
                isEnabled: enabled,
                defaults: defaults,
                secureStore: securePermissions
            )
        }
        bumpRevision(for: .codex)
        return .codex
    }

    func setCodexBashToolEnabled(_ enabled: Bool) {
        applyCodexToolSettingMutation(.bashTool(enabled: enabled))
    }

    func setCodexSearchToolEnabled(_ enabled: Bool) {
        applyCodexToolSettingMutation(.searchTool(enabled: enabled))
    }

    func setCodexComputerUseEnabled(_ enabled: Bool) {
        applyCodexToolSettingMutation(.computerUse(enabled: enabled))
    }

    func setCodexGoalSupportEnabled(_ enabled: Bool) {
        applyCodexToolSettingMutation(.goalSupport(enabled: enabled))
    }

    func setCodexReasoningSummariesEnabled(_ enabled: Bool) {
        applyCodexToolSettingMutation(.reasoningSummaries(enabled: enabled))
    }

    func setCodexMCPServerEnabled(normalizedName: String, enabled: Bool) {
        applyCodexToolSettingMutation(
            .mcpServer(normalizedName: normalizedName, enabled: enabled)
        )
    }

    @discardableResult
    func applyClaudeToolSettingMutation(_ mutation: ClaudeToolSettingMutation) -> AgentProviderBindingID {
        switch mutation {
        case let .bashTool(enabled):
            ClaudeAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
        case let .mcpStrictMode(enabled):
            ClaudeAgentToolPreferences.setMCPStrictModeEnabled(enabled, defaults: defaults, secureStore: securePermissions)
        case let .toolSearch(enabled):
            ClaudeAgentToolPreferences.setToolSearchEnabled(enabled, defaults: defaults)
        case let .agentModePromptDelivery(delivery):
            ClaudeAgentToolPreferences.setAgentModePromptDelivery(delivery, defaults: defaults)
        }
        bumpRevision(for: .claude)
        return .claude
    }

    func setClaudeBashToolEnabled(_ enabled: Bool) {
        applyClaudeToolSettingMutation(.bashTool(enabled: enabled))
    }

    func setClaudeMCPStrictModeEnabled(_ enabled: Bool) {
        applyClaudeToolSettingMutation(.mcpStrictMode(enabled: enabled))
    }

    func setClaudeToolSearchEnabled(_ enabled: Bool) {
        applyClaudeToolSettingMutation(.toolSearch(enabled: enabled))
    }

    func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
        ClaudeAgentToolPreferences.setEffortLevel(level, defaults: defaults)
        bumpRevision(for: .claude)
    }

    func setClaudeEffortLevel(
        _ level: ClaudeCodeEffortLevel,
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind?
    ) {
        guard let modelRaw, let agentKind else {
            setClaudeEffortLevel(level)
            return
        }
        ClaudeAgentToolPreferences.setEffortLevel(
            level,
            forModelRaw: modelRaw,
            agentKind: agentKind,
            defaults: defaults
        )
        bumpRevision(for: .claude)
    }

    func setClaudeAgentModePromptDelivery(_ delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery) {
        applyClaudeToolSettingMutation(.agentModePromptDelivery(delivery: delivery))
    }

    func bumpRevision(for providerID: AgentProviderBindingID) {
        revisionByProviderID[providerID, default: 0] += 1
    }

    private func permissionChromeBinding(
        for selectedAgent: AgentProviderKind,
        selectedModelRaw: String?,
        profile: AgentProviderPermissionProfile,
        externallyManagedReason: String?,
        claudePermissionSessionState: ClaudePermissionSessionState?
    ) -> AgentPermissionChromeBinding {
        let providerID = selectedAgent.providerBindingID
        switch providerID {
        case .codex:
            let effective = effectiveCodexPermissionLevel(profile: profile)
            return AgentPermissionChromeBinding(
                providerID: providerID,
                displayName: effective.displayName,
                iconName: effective.iconName,
                isWarning: effective.isWarning,
                externallyManagedReason: externallyManagedReason,
                options: CodexAgentToolPreferences.PermissionLevel.allCases.map { level in
                    AgentPermissionOptionBinding(
                        id: .codex(level),
                        title: level.displayName,
                        iconName: level.iconName,
                        detailText: level == .autoReview ? "Codex reviews tool requests automatically before asking you." : nil,
                        isWarning: level.isWarning,
                        isSelected: level == effective,
                        isEnabled: externallyManagedReason == nil
                    )
                }
            )
        case .claude:
            let configured = claudePermissionModePresentation(
                ClaudeAgentToolPreferences.permissionMode(
                    defaults: defaults,
                    secureStore: securePermissions
                )
            )
            let requested = claudePermissionModePresentation(
                runtimePermission(for: selectedAgent, profile: profile).claudePermissionMode
                    ?? ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
            )
            let configuredLevel = exactClaudePermissionLevel(for: configured.rawValue)
            let sessionStatus = claudePermissionSessionState.map {
                claudePermissionSessionStatusBinding(
                    state: $0,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    requestedMode: requested
                )
            }
            let chromeMode = sessionStatus == nil ? configured : requested
            let chromeLevel = exactClaudePermissionLevel(for: chromeMode.rawValue)
            return AgentPermissionChromeBinding(
                providerID: providerID,
                displayName: chromeMode.displayName,
                iconName: chromeLevel?.iconName ?? "questionmark.shield",
                isWarning: chromeLevel?.isWarning ?? false,
                externallyManagedReason: externallyManagedReason,
                options: ClaudeAgentToolPreferences.PermissionLevel.allCases.map { level in
                    AgentPermissionOptionBinding(
                        id: .claude(level),
                        title: level.displayName,
                        iconName: level.iconName,
                        detailText: level.detailText,
                        isWarning: level.isWarning,
                        isSelected: level == configuredLevel,
                        isEnabled: externallyManagedReason == nil
                    )
                },
                configuredMode: configured,
                sessionStatus: sessionStatus
            )
        case .openCode:
            let effective = effectiveOpenCodePermissionLevel(profile: profile)
            return AgentPermissionChromeBinding(
                providerID: providerID,
                displayName: effective.displayName,
                iconName: effective.iconName,
                isWarning: effective.isWarning,
                externallyManagedReason: externallyManagedReason,
                options: OpenCodeAgentToolPreferences.PermissionLevel.allCases.map { level in
                    AgentPermissionOptionBinding(
                        id: .openCode(level),
                        title: level.displayName,
                        iconName: level.iconName,
                        detailText: level.detailText,
                        isWarning: level.isWarning,
                        isSelected: level == effective,
                        isEnabled: externallyManagedReason == nil
                    )
                }
            )
        case .cursor:
            let effective = effectiveCursorPermissionLevel(profile: profile)
            return AgentPermissionChromeBinding(
                providerID: providerID,
                displayName: effective.displayName,
                iconName: effective.iconName,
                isWarning: effective.isWarning,
                externallyManagedReason: externallyManagedReason,
                options: CursorAgentToolPreferences.PermissionLevel.allCases.map { level in
                    AgentPermissionOptionBinding(
                        id: .cursor(level),
                        title: level.displayName,
                        iconName: level.iconName,
                        detailText: level.detailText,
                        isWarning: level.isWarning,
                        isSelected: level == effective,
                        isEnabled: externallyManagedReason == nil
                    )
                }
            )
        case .ohMyPi:
            let effective = OhMyPiAgentToolPreferences.PermissionLevel.managedBarebones
            return AgentPermissionChromeBinding(
                providerID: providerID,
                displayName: effective.displayName,
                iconName: effective.iconName,
                isWarning: false,
                externallyManagedReason: externallyManagedReason,
                options: [AgentPermissionOptionBinding(
                    id: .ohMyPi(effective),
                    title: effective.displayName,
                    iconName: effective.iconName,
                    detailText: effective.detailText,
                    isWarning: false,
                    isSelected: true,
                    isEnabled: false
                )]
            )
        }
    }

    private func claudePermissionSessionStatusBinding(
        state: ClaudePermissionSessionState,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String?,
        requestedMode: AgentPermissionModePresentationBinding
    ) -> AgentPermissionSessionStatusBinding {
        let resolution = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: requestedMode.rawValue,
            agentKind: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
        let desiredLaunchMode = resolution.launchMode.map(claudePermissionModePresentation)

        switch state {
        case .notStarted:
            return AgentPermissionSessionStatusBinding(
                phase: .selectedNotStarted,
                title: "\(requestedMode.displayName) selected",
                detail: "Not started — Claude Code has not acknowledged this request.",
                iconName: claudePermissionIconName(for: requestedMode.rawValue),
                isWarning: claudePermissionIsWarning(requestedMode.rawValue),
                requestedMode: requestedMode,
                resolvedLaunchMode: desiredLaunchMode,
                acknowledgedMode: nil
            )
        case .blocked:
            switch resolution.reason {
            case let .blockedAuto(currentCandidacy):
                return AgentPermissionSessionStatusBinding(
                    phase: .blocked,
                    title: "Auto blocked",
                    detail: sanitizedClaudePermissionPresentationMessage(
                        currentCandidacy.blockingMessage ?? "Claude Auto is unavailable for this selection."
                    ),
                    iconName: "exclamationmark.shield.fill",
                    isWarning: true,
                    requestedMode: requestedMode,
                    resolvedLaunchMode: nil,
                    acknowledgedMode: nil
                )
            case .eligibleAuto, .nonAutoPassThrough:
                return AgentPermissionSessionStatusBinding(
                    phase: .selectedNotStarted,
                    title: "\(requestedMode.displayName) selected",
                    detail: "Not started — Claude Code has not acknowledged this request.",
                    iconName: claudePermissionIconName(for: requestedMode.rawValue),
                    isWarning: claudePermissionIsWarning(requestedMode.rawValue),
                    requestedMode: requestedMode,
                    resolvedLaunchMode: desiredLaunchMode,
                    acknowledgedMode: nil
                )
            }
        case let .initializing(_, launchSettings, capturedRequestedMode):
            let capturedRequest = claudePermissionModePresentation(capturedRequestedMode)
            let launchMode = launchSettings.permissionMode.map(claudePermissionModePresentation)
            return AgentPermissionSessionStatusBinding(
                phase: .initializing,
                title: "\((launchMode ?? capturedRequest).displayName) initializing",
                detail: "Launch request pending — Claude Code has not acknowledged it yet.",
                iconName: "clock.badge.questionmark",
                isWarning: claudePermissionIsWarning((launchMode ?? capturedRequest).rawValue),
                requestedMode: requestedMode,
                resolvedLaunchMode: launchMode,
                acknowledgedMode: nil
            )
        case let .acknowledged(acknowledgement):
            let launchMode = acknowledgement.launchSettings.permissionMode
                .map(claudePermissionModePresentation)
                ?? claudePermissionModePresentation(acknowledgement.requestedMode)
            return AgentPermissionSessionStatusBinding(
                phase: .acknowledged,
                title: "\(launchMode.displayName) acknowledged",
                detail: "Claude Code accepted this request for the current controller attempt; this does not confirm that it remains continuously effective.",
                iconName: "checkmark.shield",
                isWarning: claudePermissionIsWarning(launchMode.rawValue),
                requestedMode: requestedMode,
                resolvedLaunchMode: launchMode,
                acknowledgedMode: launchMode
            )
        case let .failed(_, capturedRequestedMode, message):
            let failedMode = claudePermissionModePresentation(capturedRequestedMode)
            let reason = sanitizedClaudePermissionPresentationMessage(message)
            return AgentPermissionSessionStatusBinding(
                phase: .failed,
                title: "\(failedMode.displayName) request failed",
                detail: "\(reason) Review the model and permission selection, then retry.",
                iconName: "exclamationmark.shield.fill",
                isWarning: true,
                requestedMode: requestedMode,
                resolvedLaunchMode: desiredLaunchMode,
                acknowledgedMode: nil
            )
        case let .pendingNextTurn(active, _, reason):
            let acknowledgedMode = active.map {
                $0.launchSettings.permissionMode
                    .map(claudePermissionModePresentation)
                    ?? claudePermissionModePresentation($0.requestedMode)
            }
            let title = acknowledgedMode.map { "\($0.displayName) acknowledged · Change pending" }
                ?? "Permission change pending"
            var detail = normalizedClaudePendingReason(reason)
            if let acknowledgedMode {
                detail += " The active controller acknowledgement applies only to its captured \(acknowledgedMode.displayName) request."
            }
            return AgentPermissionSessionStatusBinding(
                phase: .pendingNextTurn,
                title: title,
                detail: detail,
                iconName: "clock.arrow.circlepath",
                isWarning: acknowledgedMode.map { claudePermissionIsWarning($0.rawValue) } ?? false,
                requestedMode: requestedMode,
                resolvedLaunchMode: desiredLaunchMode,
                acknowledgedMode: acknowledgedMode
            )
        }
    }

    private func claudePermissionModePresentation(
        _ rawValue: String
    ) -> AgentPermissionModePresentationBinding {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty
            ? ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
            : trimmed
        return AgentPermissionModePresentationBinding(
            rawValue: normalized,
            displayName: exactClaudePermissionLevel(for: normalized)?.displayName ?? normalized
        )
    }

    private func exactClaudePermissionLevel(
        for rawValue: String
    ) -> ClaudeAgentToolPreferences.PermissionLevel? {
        ClaudeAgentToolPreferences.PermissionLevel.allCases.first {
            $0.permissionMode.caseInsensitiveCompare(rawValue) == .orderedSame
        }
    }

    private func claudePermissionIconName(for rawValue: String) -> String {
        exactClaudePermissionLevel(for: rawValue)?.iconName ?? "questionmark.shield"
    }

    private func claudePermissionIsWarning(_ rawValue: String) -> Bool {
        exactClaudePermissionLevel(for: rawValue)?.isWarning ?? false
    }

    private func normalizedClaudePendingReason(_ rawValue: String) -> String {
        let sanitized = sanitizedClaudePermissionPresentationMessage(rawValue)
        let lowercased = sanitized.lowercased()
        guard lowercased.contains("effort"),
              !lowercased.contains("before the next turn")
        else {
            return sanitized
        }
        let prefix = "Effort change pending —"
        if sanitized.hasPrefix(prefix) {
            let suffix = sanitized.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty
                ? "Effort change pending — applies before the next turn."
                : "Effort change pending — applies before the next turn. \(suffix)"
        }
        return "\(sanitized) Applies before the next turn."
    }

    private func sanitizedClaudePermissionPresentationMessage(_ rawValue: String) -> String {
        var value = rawValue
        let placeholder = Self.credentialRedactionPlaceholder(absentFrom: rawValue)
        for pattern in Self.credentialRedactionPatterns(placeholder: placeholder) {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1=\(placeholder)",
                options: .regularExpression
            )
        }
        value = value.replacingOccurrences(of: placeholder, with: Self.credentialRedactionMarker)
        value = value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        value = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if value.isEmpty {
            value = "Claude Code did not accept the permission request."
        }
        if value.count > 240 {
            value = String(value.prefix(239)) + "…"
        }
        return value
    }

    /// Builds the Codex tool snapshot with Safe Managed overrides applied when the profile
    /// is `.mcpSafeDefaults`. User-configured runs read defaults directly as before.
    ///
    /// SEARCH-HELPER: Safe Managed, Codex Bash override, Codex MCP server toggles
    private func codexToolSettingsBinding(
        profile: AgentProviderPermissionProfile
    ) -> CodexToolSettingsBinding {
        let entries = codexMCPServerEntriesProvider()
        switch profile {
        case .userConfigured, .providerOverride:
            var states: [String: Bool] = [:]
            for entry in entries {
                let key = normalizedServerToggleKey(entry.normalizedName)
                states[key] = CodexAgentToolPreferences.mcpServerEnabled(
                    normalizedName: entry.normalizedName,
                    defaults: defaults,
                    secureStore: securePermissions
                )
            }
            return CodexToolSettingsBinding(
                bashToolEnabled: CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions),
                searchToolEnabled: CodexAgentToolPreferences.searchToolEnabled(defaults: defaults),
                computerUseEnabled: codexComputerUseEnabled(),
                goalSupportEnabled: codexGoalSupportEnabled(),
                reasoningSummariesEnabled: codexReasoningSummariesEnabled(),
                mcpServerEntries: entries,
                mcpServerStatesByNormalizedName: states
            )
        case .mcpSafeDefaults:
            // Codex Safe Managed keeps its product-default Bash capability while suppressing
            // every user-toggled third-party MCP server. Search remains user-configurable.
            var states: [String: Bool] = [:]
            for entry in entries {
                states[normalizedServerToggleKey(entry.normalizedName)] = false
            }
            return CodexToolSettingsBinding(
                bashToolEnabled: true,
                searchToolEnabled: CodexAgentToolPreferences.searchToolEnabled(defaults: defaults),
                computerUseEnabled: false,
                goalSupportEnabled: codexGoalSupportEnabled(),
                reasoningSummariesEnabled: codexReasoningSummariesEnabled(),
                mcpServerEntries: entries,
                mcpServerStatesByNormalizedName: states
            )
        }
    }

    /// Builds the Claude tool snapshot with Safe Managed overrides applied when the profile
    /// is `.mcpSafeDefaults`. User-configured runs read defaults directly as before.
    ///
    /// SEARCH-HELPER: Safe Managed, Claude Bash override, Claude MCP strict mode override
    private func claudeToolSettingsBinding(
        profile: AgentProviderPermissionProfile,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String?
    ) -> ClaudeToolSettingsBinding {
        let effortLevel = claudeEffortLevel(selectedAgent: selectedAgent, selectedModelRaw: selectedModelRaw)
        switch profile {
        case .userConfigured, .providerOverride:
            return ClaudeToolSettingsBinding(
                bashToolEnabled: ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions),
                mcpStrictModeEnabled: ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: securePermissions),
                toolSearchEnabled: ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults),
                effortLevel: effortLevel,
                agentModePromptDelivery: ClaudeAgentToolPreferences.agentModePromptDelivery(defaults: defaults)
            )
        case .mcpSafeDefaults:
            // Safe Managed: force Bash off and keep MCP strict mode on so only the RepoPrompt
            // MCP server is reachable. Search stays available. Effort and prompt-delivery are
            // carried through so runtime behavior for those remains user-configurable.
            return ClaudeToolSettingsBinding(
                bashToolEnabled: false,
                mcpStrictModeEnabled: true,
                toolSearchEnabled: ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults),
                effortLevel: effortLevel,
                agentModePromptDelivery: ClaudeAgentToolPreferences.agentModePromptDelivery(defaults: defaults)
            )
        }
    }

    private func codexComputerUseEnabled() -> Bool {
        CodexAgentModeBooleanPreference.computerUse.isEnabled(defaults: defaults)
    }

    private func codexGoalSupportEnabled() -> Bool {
        CodexAgentModeBooleanPreference.goalSupport.isEnabled(defaults: defaults)
    }

    private func codexReasoningSummariesEnabled() -> Bool {
        CodexAgentModeBooleanPreference.reasoningSummaries.isEnabled(defaults: defaults)
    }

    private func claudeEffortLevel(
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String?
    ) -> ClaudeCodeEffortLevel {
        guard let selectedModelRaw else {
            return ClaudeAgentToolPreferences.effortLevel(defaults: defaults)
        }
        return ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: selectedModelRaw,
            agentKind: selectedAgent,
            defaults: defaults
        )
    }

    private func effectiveCodexPermissionLevel(
        profile: AgentProviderPermissionProfile
    ) -> CodexAgentToolPreferences.PermissionLevel {
        switch profile {
        case .userConfigured:
            CodexAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
        case .mcpSafeDefaults:
            .autoReview
        case let .providerOverride(.codex(level)):
            level
        case .providerOverride:
            .defaultPermission
        }
    }

    private func effectiveClaudePermissionLevel(
        profile: AgentProviderPermissionProfile
    ) -> ClaudeAgentToolPreferences.PermissionLevel {
        switch profile {
        case .userConfigured:
            ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
        case .mcpSafeDefaults:
            .requireApproval
        case let .providerOverride(.claude(level)):
            level
        case .providerOverride:
            .requireApproval
        }
    }

    private func effectiveOpenCodePermissionLevel(
        profile: AgentProviderPermissionProfile
    ) -> OpenCodeAgentToolPreferences.PermissionLevel {
        switch profile {
        case .userConfigured:
            OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
        case .mcpSafeDefaults:
            .managedDefault
        case let .providerOverride(.openCode(level)):
            level
        case .providerOverride:
            .managedDefault
        }
    }

    private func effectiveCursorPermissionLevel(
        profile: AgentProviderPermissionProfile
    ) -> CursorAgentToolPreferences.PermissionLevel {
        switch profile {
        case .userConfigured:
            CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
        case .mcpSafeDefaults:
            .managedDefault
        case let .providerOverride(.cursor(level)):
            level
        case .providerOverride:
            .managedDefault
        }
    }

    private static func representativeAgent(for providerID: AgentProviderBindingID) -> AgentProviderKind {
        switch providerID {
        case .codex: .codexExec
        case .claude: .claudeCode
        case .openCode: .openCode
        case .cursor: .cursor
        case .ohMyPi: .ohMyPi
        }
    }

    private func normalizedServerToggleKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
