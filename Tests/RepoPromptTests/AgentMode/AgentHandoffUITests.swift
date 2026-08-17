@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentHandoffUITests: XCTestCase {
    private var cursorCatalogSnapshot: [String: [CursorModelParameterCatalog.ParameterSpec]] = [:]

    override func setUp() {
        super.setUp()
        cursorCatalogSnapshot = CursorModelParameterCatalog.shared.currentSnapshot()
        CursorModelParameterCatalog.shared.test_restoreSnapshot([:])
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        CursorModelParameterCatalog.shared.test_restoreSnapshot(cursorCatalogSnapshot)
        super.tearDown()
    }

    func testDestinationSourceRequiresMappedRemoteRowsAndKeepsLocalRowsEligible() {
        XCTAssertEqual(
            AgentHandoffConfig.destinationSource(remoteHostID: nil, resolvedHostRowID: nil),
            .localProviders
        )
        XCTAssertNil(
            AgentHandoffConfig.destinationSource(remoteHostID: "host-a", resolvedHostRowID: nil)
        )
        XCTAssertEqual(
            AgentHandoffConfig.destinationSource(remoteHostID: "host-a", resolvedHostRowID: UUID()),
            .remoteCatalog(hostID: "host-a")
        )
    }

    func testLocalHandoffPreservesEphemeralOMPMapAcrossNonOMPInitialSelectionAndCanonicalizesDestinations() {
        let ompModelRaw = "google-antigravity/gemini-3.7-flash"
        let codexModelRaw = "gpt-5.6-sol"
        var sourceThinking = OhMyPiThinkingSelections()
        sourceThinking.setValue("high", for: ompModelRaw)
        let ompOption = AgentModelOption(
            rawValue: ompModelRaw,
            displayName: "Gemini 3.7 Flash",
            description: nil,
            isDefault: true
        )
        let codexOption = AgentModelOption(
            rawValue: codexModelRaw,
            displayName: "GPT-5.6 Sol",
            description: nil,
            isDefault: true
        )
        let config = AgentHandoffConfig(
            itemID: UUID(),
            destinationSource: .localProviders,
            defaultDestinationAgent: .codexExec,
            defaultModelRaw: codexModelRaw,
            defaultReasoningEffortRaw: "high",
            defaultOhMyPiThinkingSelections: sourceThinking,
            availableAgentsProvider: { [.codexExec, .ohMyPi] },
            modelOptionsProvider: { agent in
                agent == .ohMyPi ? [ompOption] : [codexOption]
            },
            remoteCatalogSnapshot: nil,
            windowID: -1,
            buildPayloadForClipboard: { "" },
            performHandoff: { _ in }
        )

        let initial = AgentHandoffPopover.initialSelection(for: config)
        XCTAssertEqual(initial.agent, .codexExec)
        XCTAssertTrue(initial.ohMyPiThinkingSelections.isEmpty)
        XCTAssertEqual(
            AgentHandoffPopover.initialOhMyPiThinkingSelections(for: config),
            sourceThinking,
            "The ephemeral map must survive a non-OMP initial provider so switching to OMP can reuse it"
        )

        let ompSelection = AgentHandoffActionSupport.canonicalizedSelection(AgentHandoffSelection(
            agent: .ohMyPi,
            modelRaw: ompModelRaw,
            reasoningEffortRaw: nil,
            ohMyPiThinkingSelections: AgentHandoffPopover.initialOhMyPiThinkingSelections(for: config)
        ))
        XCTAssertEqual(ompSelection.ohMyPiThinkingSelections, sourceThinking)

        let nonOMP = AgentHandoffActionSupport.canonicalizedSelection(AgentHandoffSelection(
            agent: .codexExec,
            modelRaw: codexModelRaw,
            reasoningEffortRaw: "high",
            ohMyPiThinkingSelections: sourceThinking
        ))
        XCTAssertTrue(nonOMP.ohMyPiThinkingSelections.isEmpty)
    }

    func testRemoteDestinationStateRendersStructuredCatalogEffortAndExactRawValues() throws {
        var state = AgentHandoffRemoteDestinationState(
            catalog: structuredCatalogFixture(),
            preferredModelID: "codexExec:gpt-5.4:low"
        )

        let agent = try XCTUnwrap(state.structuredAgentGroups.first)
        let model = try XCTUnwrap(agent.models.first)
        XCTAssertEqual(agent.name, "Codex CLI")
        XCTAssertEqual(model.displayName, "GPT-5.4")
        XCTAssertEqual(state.effortOptions.map(\.displayName), ["Low", "High"])
        XCTAssertEqual(state.selectedEffortOption?.displayName, "Low")
        XCTAssertEqual(
            state.destination,
            .remote(
                agentID: "codexExec",
                modelID: "codexExec:gpt-5.4:low",
                effort: "low"
            )
        )

        state.selectEffort(modelID: "codexExec:gpt-5.4:high")
        XCTAssertEqual(state.selectedEffortOption?.displayName, "High")
        XCTAssertEqual(
            state.destination,
            .remote(
                agentID: "codexExec",
                modelID: "codexExec:gpt-5.4:high",
                effort: "high"
            )
        )
    }

    func testDegradedRemoteCatalogDisablesHandoffButKeepsCopyPayloadAvailable() {
        let state = AgentHandoffRemoteDestinationState(
            catalog: .degraded,
            preferredModelID: nil
        )

        XCTAssertFalse(state.canPerformHandoff)
        XCTAssertTrue(state.canCopyPayload)
        XCTAssertNil(state.destination)
    }

    func testCopyFailureAndInDoubtHandoffRemainLegibleInPopoverErrors() async {
        let copyResult = await AgentHandoffPopover.clipboardPayloadResult(
            config: remoteConfig(catalog: .degraded) {
                throw HandoffUITestError.extractionFailed
            }
        )
        XCTAssertEqual(copyResult, .failure("Copy Payload failed: Host extraction failed."))
        let supportCopyResult = await AgentHandoffActionSupport.clipboardPayloadResult(
            config: remoteConfig(catalog: .degraded) {
                throw HandoffUITestError.extractionFailed
            }
        )
        XCTAssertEqual(supportCopyResult, copyResult)

        let inDoubt = RemoteClientError.inDoubt(RemoteCommandError(
            code: "in_doubt",
            message: "The command outcome is unknown."
        ))
        let message = AgentHandoffPopover.errorMessage(for: .handoff, error: inDoubt)
        XCTAssertTrue(message.contains("uncertain (in doubt)"), message)
        XCTAssertTrue(message.contains("The command outcome is unknown."), message)
        XCTAssertTrue(message.contains("before retrying"), message)
        XCTAssertEqual(
            AgentHandoffActionSupport.errorMessage(for: .handoff, error: inDoubt),
            message
        )

        let copyMessage = AgentHandoffPopover.errorMessage(for: .copyPayload, error: inDoubt)
        XCTAssertTrue(copyMessage.contains("Copy Payload outcome is uncertain (in doubt)"), copyMessage)
        XCTAssertFalse(copyMessage.contains("created the fork"), copyMessage)
    }

    func testCursorHandoffPreservesBracketedSelectionReconcilesAndRendersMenu() throws {
        installCursorModel()
        XCTAssertEqual(
            CursorModelParameterCatalog.shared.apply(response: cursorParameterResponse()),
            .applied(didChange: true)
        )

        let baseOption = AgentModelOption(
            rawValue: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol",
            description: nil,
            isDefault: true
        )
        let preferredRaw = "gpt-5.6-sol[context=1m,thinking_mode=high,fast=false]"
        let config = localCursorConfig(defaultModelRaw: preferredRaw, options: [baseOption])

        XCTAssertEqual(AgentHandoffPopover.initialSelection(for: config).modelRaw, preferredRaw)
        XCTAssertEqual(
            AgentHandoffPopover.initialModelRaw(
                for: .cursor,
                preferredModelRaw: preferredRaw,
                config: config
            ),
            preferredRaw
        )
        XCTAssertEqual(
            AgentHandoffPopover.reconciledModelRaw(
                preferredRaw,
                for: .cursor,
                in: [baseOption],
                fallbackModelRaw: baseOption.rawValue
            ),
            preferredRaw
        )

        let replacementOption = AgentModelOption(
            rawValue: "composer-2",
            displayName: "Composer 2",
            description: nil,
            isDefault: true
        )
        XCTAssertEqual(
            AgentHandoffPopover.reconciledModelRaw(
                preferredRaw,
                for: .cursor,
                in: [replacementOption],
                fallbackModelRaw: replacementOption.rawValue
            ),
            replacementOption.rawValue
        )

        let malformedRaw = "gpt-5.6-sol[fast=true"
        XCTAssertNil(AgentHandoffPopover.option(
            matching: malformedRaw,
            for: .cursor,
            in: [baseOption]
        ))
        XCTAssertEqual(
            AgentHandoffPopover.reconciledModelRaw(
                malformedRaw,
                for: .cursor,
                in: [baseOption],
                fallbackModelRaw: baseOption.rawValue
            ),
            baseOption.rawValue
        )

        let leaves = try XCTUnwrap(AgentModelOptionsMenuContent.cursorSubmenuLeaves(
            for: baseOption,
            selectedModelRaw: preferredRaw,
            catalog: .shared,
            isEnabled: true
        ))
        XCTAssertEqual(leaves.map(\.title), [
            "Default", "None", "Low", "High", "None", "Low", "High"
        ])
        XCTAssertEqual(
            CursorModelMenuBuilder.sections(from: leaves).map(\.title),
            [nil, nil, "Fast (2×)"]
        )
        XCTAssertEqual(
            AgentHandoffPopover.selectedModelDisplayName(
                agent: .cursor,
                modelRaw: preferredRaw,
                option: baseOption
            ),
            "GPT 5.6 Sol · High · 1M"
        )
    }

    func testHandoffCodexEffortLeavesPairSelectionAndKeepSharedMenuCollapsed() throws {
        let option = AgentModelOption(
            rawValue: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: nil,
            isDefault: true,
            supportedReasoningEfforts: [.low, .high],
            defaultReasoningEffort: .high
        )

        let content = AgentHandoffCodexEffortMenu.content(
            options: [option],
            selectedModelRaw: option.rawValue,
            selectedReasoningEffortRaw: CodexReasoningEffort.low.rawValue
        )
        let group = try XCTUnwrap(content.groups.first)
        XCTAssertNil(content.defaultLeaf)
        XCTAssertEqual(content.groups.count, 1)
        XCTAssertEqual(group.displayName, "GPT-5.6 Sol")
        XCTAssertEqual(group.leaves.map(\.title), ["Low", "High (Default)"])
        XCTAssertEqual(group.leaves.map(\.isDefault), [false, true])
        XCTAssertEqual(group.leaves.map(\.isSelected), [true, false])
        XCTAssertFalse(group.showsWarning)
        XCTAssertTrue(group.leaves.allSatisfy { !$0.showsWarning })

        let highLeaf = try XCTUnwrap(group.leaves.first { $0.effort == .high })
        XCTAssertEqual(
            AgentHandoffCodexEffortMenu.selection(for: highLeaf),
            AgentHandoffSelection(
                agent: .codexExec,
                modelRaw: option.rawValue,
                reasoningEffortRaw: CodexReasoningEffort.high.rawValue
            )
        )

        let encoded = AgentModelOption(
            rawValue: "gpt-5.6-sol-high",
            displayName: "GPT-5.6 Sol High",
            description: nil,
            isDefault: true,
            supportedReasoningEfforts: [.low, .high],
            defaultReasoningEffort: .high
        )
        let encodedGroup = try XCTUnwrap(AgentHandoffCodexEffortMenu.groups(
            options: [encoded],
            selectedModelRaw: encoded.rawValue,
            selectedReasoningEffortRaw: CodexReasoningEffort.high.rawValue
        ).first)
        let encodedLeaf = try XCTUnwrap(encodedGroup.leaves.first)
        XCTAssertEqual(encodedGroup.leaves.count, 1)
        XCTAssertEqual(encodedLeaf.effort, .high)
        XCTAssertEqual(encodedLeaf.title, "High (Default)")
        XCTAssertTrue(encodedLeaf.isSelected)
        XCTAssertFalse(AgentHandoffPopover.shouldShowReasoningEffortPicker(
            agent: .codexExec,
            modelRaw: encoded.rawValue,
            option: encoded
        ))
        XCTAssertEqual(
            AgentHandoffPopover.codexReasoningEffortRaw(
                modelRaw: encoded.rawValue,
                preferredReasoningEffortRaw: CodexReasoningEffort.low.rawValue,
                option: encoded
            ),
            CodexReasoningEffort.high.rawValue
        )
        XCTAssertEqual(
            AgentHandoffCodexEffortMenu.selection(for: encodedLeaf),
            AgentHandoffSelection(
                agent: .codexExec,
                modelRaw: encoded.rawValue,
                reasoningEffortRaw: CodexReasoningEffort.high.rawValue
            )
        )

        let effortlessEncoded = AgentModelOption(
            rawValue: "gpt-5.6-sol-high",
            displayName: "GPT-5.6 Sol High",
            description: nil,
            isDefault: true
        )
        let effortlessLeaf = try XCTUnwrap(AgentHandoffCodexEffortMenu.groups(
            options: [effortlessEncoded],
            selectedModelRaw: effortlessEncoded.rawValue,
            selectedReasoningEffortRaw: CodexReasoningEffort.high.rawValue
        ).first?.leaves.first)
        XCTAssertEqual(effortlessLeaf.effort, .high)
        XCTAssertEqual(effortlessLeaf.title, "High (Default)")
        XCTAssertTrue(effortlessLeaf.isSelected)

        let placeholder = AgentModelOption(
            rawValue: AgentModel.defaultModel.rawValue,
            displayName: "Default",
            description: nil,
            isPlaceholderDefault: true,
            isProviderDefault: true
        )
        let placeholderContent = AgentHandoffCodexEffortMenu.content(
            options: [placeholder],
            selectedModelRaw: placeholder.rawValue,
            selectedReasoningEffortRaw: nil
        )
        XCTAssertEqual(placeholderContent.defaultLeaf?.title, "Default")
        XCTAssertTrue(placeholderContent.defaultLeaf?.isSelected == true)
        XCTAssertTrue(placeholderContent.groups.isEmpty)

        let fast = AgentModelOption(
            rawValue: "gpt-5.6-sol-fast-high",
            displayName: "GPT-5.6 Sol Fast High",
            description: nil,
            isDefault: false
        )
        let fastGroup = try XCTUnwrap(AgentHandoffCodexEffortMenu.groups(
            options: [fast],
            selectedModelRaw: fast.rawValue,
            selectedReasoningEffortRaw: CodexReasoningEffort.high.rawValue
        ).first)
        XCTAssertTrue(fastGroup.showsWarning)
        XCTAssertTrue(fastGroup.leaves.allSatisfy(\.showsWarning))

        let sharedMenu = AgentModelCatalog.codexMenu(for: [option])
        XCTAssertNil(sharedMenu.defaultOption)
        XCTAssertEqual(sharedMenu.groups.count, 1)
        XCTAssertEqual(sharedMenu.groups.first?.options, [option])
    }

    func testMixedEncodedCodexPreferenceCommitsOnlyAfterSuccessfulHandoff() async throws {
        let suiteName = "AgentHandoffUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let option = AgentModelOption(
            rawValue: "gpt-5.6-sol-high",
            displayName: "GPT-5.6 Sol High",
            description: nil,
            isDefault: true,
            supportedReasoningEfforts: [.low, .high],
            defaultReasoningEffort: .high
        )
        let leaf = try XCTUnwrap(AgentHandoffCodexEffortMenu.groups(
            options: [option],
            selectedModelRaw: option.rawValue,
            selectedReasoningEffortRaw: CodexReasoningEffort.high.rawValue
        ).first?.leaves.first)

        CodexAgentToolPreferences.setLastUsedReasoningEffort(
            .medium,
            forModelRaw: option.rawValue,
            defaults: defaults
        )
        let selection = AgentHandoffCodexEffortMenu.selection(for: leaf)
        XCTAssertEqual(
            CodexAgentToolPreferences.lastUsedReasoningEffort(
                forModelRaw: option.rawValue,
                defaults: defaults
            ),
            .medium,
            "Provisional leaf selection must not mutate the last-used preference"
        )

        let contradictorySelection = AgentHandoffSelection(
            agent: selection.agent,
            modelRaw: selection.modelRaw,
            reasoningEffortRaw: CodexReasoningEffort.low.rawValue
        )
        let destination = AgentHandoffDestination.local(contradictorySelection)
        do {
            try await AgentHandoffPopover.performCommittedHandoff(
                destination,
                defaults: defaults
            ) { _ in
                throw HandoffUITestError.extractionFailed
            }
            XCTFail("Expected the failed handoff to throw")
        } catch HandoffUITestError.extractionFailed {}
        XCTAssertEqual(
            CodexAgentToolPreferences.lastUsedReasoningEffort(
                forModelRaw: option.rawValue,
                defaults: defaults
            ),
            .medium,
            "A failed handoff must leave the provisional preference uncommitted"
        )

        var performedDestination: AgentHandoffDestination?
        try await AgentHandoffPopover.performCommittedHandoff(
            destination,
            defaults: defaults
        ) {
            performedDestination = $0
        }
        XCTAssertEqual(
            performedDestination,
            .local(AgentHandoffSelection(
                agent: .codexExec,
                modelRaw: option.rawValue,
                reasoningEffortRaw: CodexReasoningEffort.high.rawValue
            ))
        )
        XCTAssertEqual(
            CodexAgentToolPreferences.lastUsedReasoningEffort(
                forModelRaw: option.rawValue,
                defaults: defaults
            ),
            .high,
            "A successful handoff commits the encoded effort"
        )
    }

    func testAgentModelsSettingsRoutesBracketedCursorLabels() {
        installCursorModel()
        XCTAssertEqual(
            CursorModelParameterCatalog.shared.apply(response: cursorParameterResponse()),
            .applied(didChange: true)
        )
        let raw = AIModel.cursorCustom(
            name: "gpt-5.6-sol[context=1m,thinking_mode=high,fast=false]"
        ).rawValue

        XCTAssertEqual(
            AgentModelsSettingsViewModel.displayName(
                forChatModelRaw: raw,
                fallback: "Select a model"
            ),
            "GPT 5.6 Sol · High · 1M"
        )
    }

    private func structuredCatalogFixture() -> RemoteHostAgentCatalog {
        RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Codex CLI",
                defaultModelID: "codexExec:gpt-5.4:high",
                models: [
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4:low",
                        name: "Codex CLI GPT-5.4 Low",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4",
                        effort: "low",
                        modelDisplayName: "GPT-5.4",
                        effortDisplayName: "Low"
                    ),
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4:high",
                        name: "Codex CLI GPT-5.4 High",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4",
                        effort: "high",
                        modelDisplayName: "GPT-5.4",
                        effortDisplayName: "High",
                        isDefault: true
                    )
                ]
            )
        ])
    }

    private func localCursorConfig(
        defaultModelRaw: String,
        options: [AgentModelOption]
    ) -> AgentHandoffConfig {
        AgentHandoffConfig(
            itemID: UUID(),
            destinationSource: .localProviders,
            defaultDestinationAgent: .cursor,
            defaultModelRaw: defaultModelRaw,
            defaultReasoningEffortRaw: nil,
            defaultOhMyPiThinkingSelections: .empty,
            availableAgentsProvider: { [.cursor] },
            modelOptionsProvider: { agent in
                agent == .cursor ? options : []
            },
            remoteCatalogSnapshot: nil,
            windowID: -1,
            buildPayloadForClipboard: { "" },
            performHandoff: { _ in }
        )
    }

    private func installCursorModel() {
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "gpt-5.6-sol",
                        displayName: "GPT 5.6 Sol",
                        description: nil,
                        isDefault: true
                    )
                ],
                currentModelRaw: "gpt-5.6-sol"
            ),
            for: .cursor
        )
    }

    private func cursorParameterResponse() -> [String: Any] {
        [
            "models": [[
                "value": "gpt-5.6-sol",
                "configOptions": [
                    [
                        "id": "context",
                        "category": "context_window",
                        "type": "select",
                        "currentValue": "272k",
                        "options": [
                            ["value": "272k", "name": "272k"],
                            ["value": "1m", "name": "1m"]
                        ]
                    ],
                    [
                        "id": "thinking_mode",
                        "category": "thought_level",
                        "type": "select",
                        "currentValue": "low",
                        "options": [
                            ["value": "none", "name": "None"],
                            ["value": "low", "name": "Low"],
                            ["value": "high", "name": "High"]
                        ]
                    ],
                    [
                        "id": "fast",
                        "category": "speed",
                        "type": "select",
                        "currentValue": "false",
                        "options": [
                            ["value": "false", "name": "Off"],
                            ["value": "true", "name": "On"]
                        ]
                    ]
                ]
            ]]
        ]
    }

    private func remoteConfig(
        catalog: RemoteHostAgentCatalog,
        buildPayload: @escaping @MainActor () async throws -> String
    ) -> AgentHandoffConfig {
        AgentHandoffConfig(
            itemID: UUID(),
            destinationSource: .remoteCatalog(hostID: "host-a"),
            defaultDestinationAgent: .codexExec,
            defaultModelRaw: "codexExec:gpt-5.4:high",
            defaultReasoningEffortRaw: "high",
            defaultOhMyPiThinkingSelections: .empty,
            availableAgentsProvider: { [] },
            modelOptionsProvider: { _ in [] },
            remoteCatalogSnapshot: catalog,
            windowID: -1,
            buildPayloadForClipboard: buildPayload,
            performHandoff: { _ in }
        )
    }
}

private enum HandoffUITestError: LocalizedError {
    case extractionFailed

    var errorDescription: String? {
        "Host extraction failed."
    }
}
