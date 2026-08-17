import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AIModelPreferenceRegressionTests: XCTestCase {
    @MainActor
    func testPlanningDropdownInvalidStateMatrixDoesNotDisplayFirstAvailableModel() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]
        let rows = [
            (rawValue: "", expectedDisplayName: "Select an Oracle model"),
            (rawValue: "legacy-oracle-model", expectedDisplayName: "Invalid Oracle model")
        ]

        for row in rows {
            let displayName = AIModelDropdown.displayName(
                forRawValue: row.rawValue,
                destinationID: "planningModel",
                availableModels: availableModels,
                customOpenRouterModels: []
            )

            XCTAssertEqual(displayName, row.expectedDisplayName, row.rawValue)
            XCTAssertNotEqual(displayName, availableModels[0].displayName, row.rawValue)
        }
    }

    @MainActor
    func testNonPlanningDropdownRetainsFirstAvailableFallbackForInvalidRaw() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]

        let displayName = AIModelDropdown.displayName(
            forRawValue: "legacy-chat-model",
            destinationID: "chatModel",
            availableModels: availableModels,
            customOpenRouterModels: []
        )

        XCTAssertEqual(displayName, availableModels[0].displayName)
    }

    func testEmptyCursorCustomDisplayNameFallsBackToCursorDefault() {
        XCTAssertEqual(AIModel.cursorCustom(name: "").displayName, "Auto")
    }

    @MainActor
    func testOptimizedPickerStableMenuTreeRoutesProviderSelections() throws {
        let cursorSnapshot = CursorModelParameterCatalog.shared.currentSnapshot()
        defer { CursorModelParameterCatalog.shared.test_restoreSnapshot(cursorSnapshot) }
        let cursorCatalogOutcome = CursorModelParameterCatalog.shared.apply(
            response: optimizedPickerCursorParameterResponse()
        )
        guard case .applied = cursorCatalogOutcome else {
            XCTFail("Expected Cursor parameter catalog setup to apply, got \(cursorCatalogOutcome)")
            return
        }

        let codexLow = AIModel.codexCustom(name: "gpt-5.6-sol-low")
        let codexHigh = AIModel.codexCustom(name: "gpt-5.6-sol-high")
        let compatibleClaude = AIModel.claudeCodeModel(specifier: "compatible:glmzai:glm-4.7")
        let openCode = AIModel.openCodeCustom(name: "openai/gpt-oss")
        let cursor = AIModel.cursorCustom(name: "gpt-5.6-sol")
        let flat = AIModel.geminiCustom(name: "gemini-test")
        let models = [codexLow, codexHigh, compatibleClaude, openCode, cursor, flat]

        let codexGroup = try XCTUnwrap(OptimizedModelPicker.codexMenuGroups(for: [codexLow, codexHigh]).first)
        XCTAssertEqual(codexGroup.baseModelID, "gpt-5.6-sol")
        XCTAssertEqual(codexGroup.models.map(\.modelName), ["gpt-5.6-sol-low", "gpt-5.6-sol-high"])
        let compatibleDescriptor = try XCTUnwrap(
            ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: compatibleClaude)
        )
        let openCodeMenu = AIModel.openCodeMenu(for: [openCode])
        let openCodeProvider = try XCTUnwrap(openCodeMenu.providerGroups.first)
        let openCodeGroup = try XCTUnwrap(openCodeProvider.groups.first)
        let openCodeOption = try XCTUnwrap(openCodeGroup.options.first)

        var openCodePath = [AIProviderType.displayName(for: .openCode)]
        if openCodeProvider.rendersAsSubmenu {
            openCodePath.append(openCodeProvider.displayName)
        }
        if openCodeGroup.rendersAsSubmenu {
            openCodePath.append(openCodeGroup.modelDisplayName)
        }
        openCodePath.append(openCodeOption.displayName)

        let structureTree = OptimizedModelPicker.stableMenuItemsForTesting(
            availableModels: models,
            selectedRawValue: compatibleClaude.rawValue,
            onSelect: { _ in }
        )
        let compatibleTop = try stableMenuItem(
            at: [compatibleDescriptor.groupDisplayName],
            in: structureTree
        )
        let compatibleLeafTitle = try XCTUnwrap(compatibleTop.submenuItems?.first?.title)
        let cursorTop = try stableMenuItem(
            at: [AIProviderType.displayName(for: .cursor)],
            in: structureTree
        )
        let cursorModelTitle = try XCTUnwrap(cursorTop.submenuItems?.first?.title)
        let cursorModelItem = try stableMenuItem(
            at: [AIProviderType.displayName(for: .cursor), cursorModelTitle],
            in: structureTree
        )
        let cursorDefaultTitle = try XCTUnwrap(cursorModelItem.submenuItems?.first?.title)
        let codexTop = try stableMenuItem(
            at: [AIProviderType.displayName(for: .codex)],
            in: structureTree
        )
        let codexGroupTitle = try XCTUnwrap(codexTop.submenuItems?.first?.title)
        let codexGroupItem = try stableMenuItem(
            at: [AIProviderType.displayName(for: .codex), codexGroupTitle],
            in: structureTree
        )
        let codexLeafItems = try XCTUnwrap(codexGroupItem.submenuItems)
        XCTAssertEqual(codexLeafItems.count, 2)
        let codexHighTitle = codexLeafItems[1].title

        let scenarios: [(name: String, model: AIModel, path: [String])] = [
            (
                "Codex grouped effort",
                codexHigh,
                [AIProviderType.displayName(for: .codex), codexGroupTitle, codexHighTitle]
            ),
            (
                "Claude-compatible provider",
                compatibleClaude,
                [compatibleDescriptor.groupDisplayName, compatibleLeafTitle]
            ),
            ("OpenCode grouping", openCode, openCodePath),
            (
                "Cursor preset submenu",
                cursor,
                [AIProviderType.displayName(for: .cursor), cursorModelTitle, cursorDefaultTitle]
            ),
            (
                "ordinary flat provider",
                flat,
                [AIProviderType.displayName(for: .gemini), flat.displayName]
            )
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.name) { _ in
                var emittedRaw: String?
                let tree = OptimizedModelPicker.stableMenuItemsForTesting(
                    availableModels: models,
                    selectedRawValue: scenario.model.rawValue,
                    onSelect: { emittedRaw = $0 }
                )
                let leaf = try stableMenuItem(at: scenario.path, in: tree, context: scenario.name)
                XCTAssertTrue(leaf.isSelected, scenario.path.joined(separator: " > "))
                XCTAssertTrue(leaf.performActionForTesting())
                XCTAssertEqual(emittedRaw, scenario.model.rawValue)
            }
        }

        let codexTree = OptimizedModelPicker.stableMenuItemsForTesting(
            availableModels: models,
            selectedRawValue: codexHigh.rawValue,
            onSelect: { _ in }
        )
        let codexItems = try stableMenuItem(
            at: [AIProviderType.displayName(for: .codex), codexGroupTitle],
            in: codexTree
        ).submenuItems
        XCTAssertEqual(codexItems?.count, 2)
        XCTAssertEqual(codexItems?.map(\.isSelected), [false, true])
        var emittedLowRaw: String?
        let lowTree = OptimizedModelPicker.stableMenuItemsForTesting(
            availableModels: models,
            selectedRawValue: codexHigh.rawValue,
            onSelect: { emittedLowRaw = $0 }
        )
        let lowGroup = try stableMenuItem(
            at: [AIProviderType.displayName(for: .codex), codexGroupTitle],
            in: lowTree
        )
        let lowLeaf = try XCTUnwrap(lowGroup.submenuItems?.first)
        XCTAssertTrue(lowLeaf.performActionForTesting())
        XCTAssertEqual(emittedLowRaw, codexLow.rawValue)
    }

    @MainActor
    func testOptimizedPickerValidOMPLeafHasDefaultThinkingChildren() throws {
        let model = AIModel.ohMyPiCustom(name: "provider/model")
        var selectedRaw = model.rawValue
        var selections = OhMyPiThinkingSelections()
        let destination = ModelDestination(
            id: "optimized-picker-omp-thinking-test",
            getter: { selectedRaw },
            applier: { selectedRaw = $0 },
            thinkingGetter: { selections },
            thinkingApplier: { selections = $0 }
        )

        let tree = OptimizedModelPicker.stableMenuItemsForTesting(
            availableModels: [model],
            destination: destination
        )
        let ompMenu = try stableMenuItem(
            at: [AIProviderType.displayName(for: .ohMyPi)],
            in: tree
        )
        let validLeaves = descendants(of: ompMenu.submenuItems ?? []).filter {
            $0.submenuItems?.first?.title == "Default"
        }

        XCTAssertEqual(validLeaves.count, 1)
        let validLeaf = try XCTUnwrap(validLeaves.first)
        XCTAssertEqual(validLeaf.title, "model")
        let defaultChild = try XCTUnwrap(validLeaf.submenuItems?.first)
        XCTAssertEqual(defaultChild.title, "Default")
        XCTAssertTrue(defaultChild.isEnabled)
        XCTAssertTrue(defaultChild.isSelected)
    }

    private func descendants(of items: [StableMenuItem]) -> [StableMenuItem] {
        items.flatMap { item in
            [item] + descendants(of: item.submenuItems ?? [])
        }
    }

    private func stableMenuItem(
        at path: [String],
        in items: [StableMenuItem],
        context: String = ""
    ) throws -> StableMenuItem {
        var currentItems = items
        var currentItem: StableMenuItem?
        for title in path {
            currentItem = currentItems.first { $0.title == title }
            let item = try XCTUnwrap(
                currentItem,
                "\(context) missing menu path component: \(title); available: \(currentItems.map(\.title))"
            )
            currentItems = item.submenuItems ?? []
        }
        return try XCTUnwrap(currentItem)
    }

    private func optimizedPickerCursorParameterResponse() -> [String: Any] {
        [
            "models": [[
                "value": "gpt-5.6-sol",
                "configOptions": [
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

    @MainActor
    func testSettingsSyncClearsStaleModelRawWhenPersistedValueIsEmptyOrMissing() {
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-planning", persistedRaw: ""),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-preferred", persistedRaw: nil),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale", persistedRaw: "gpt-5.5-low"),
            "gpt-5.5-low"
        )
    }

    func testStrictOraclePlanningResolutionRejectsEmptyInvalidAndUnavailableRaw() {
        let empty = PromptViewModel.mcpOraclePlanningModelResolution(rawValue: "", isModelAvailable: { _ in true })
        XCTAssertEqual(empty, .unconfigured)
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: empty),
            "MCP Oracle model is not configured. Select an Oracle model in the Models settings before using ask_oracle."
        )

        let invalid = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "legacy-oracle-model",
            isModelAvailable: { _ in true }
        )
        XCTAssertEqual(invalid, .invalid(rawValue: "legacy-oracle-model"))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: invalid),
            "MCP Oracle model raw value 'legacy-oracle-model' is invalid. Select a valid Oracle model in the Models settings before using ask_oracle."
        )

        let unavailableModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let unavailable = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: unavailableModel.rawValue,
            isModelAvailable: { _ in false }
        )
        XCTAssertEqual(unavailable, .unavailable(unavailableModel))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: unavailable),
            "MCP oracle model '\(unavailableModel.displayName)' is not available."
        )
    }

    func testStrictOraclePlanningResolutionReturnsConfiguredModelOnlyWhenRawParsesAndIsAvailable() {
        let configuredModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let resolved = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "  \(configuredModel.rawValue)  ",
            isModelAvailable: { model in model == configuredModel }
        )
        XCTAssertEqual(resolved, .configured(configuredModel))
    }

    // MARK: - Oracle reset-on-restart regression

    //
    // Reproduces the durable "Oracle resets to nothing after restart" bug: when the
    // sync-chat-with-Oracle toggle is on, a blank built-in-chat (preferredCompose) write
    // — produced by the transient fallback in PromptViewModel.pickDiffCapableFallback when
    // the model list is unhydrated — is mirrored into the GLOBAL Oracle planningModel and
    // eagerly persisted. planningModel is deliberately never auto-healed, so the blank
    // survives relaunch.

    @MainActor
    private func makeIsolatedStore(_ fileURL: URL) throws -> GlobalSettingsStore {
        let suiteName = "AIModelPreferenceRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    @MainActor
    func testEmptyChatModelDoesNotBlankOracleAcrossRelaunchWhenSyncOn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleResetRepro.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")

        let store = try makeIsolatedStore(fileURL)
        let model = AIModel.codexCustom(name: "gpt-5.5-high").rawValue

        // User has the same model for Oracle and Chat with sync on.
        store.setSyncChatModelWithOracle(true)
        store.setPlanningModelRaw(model, commit: true)
        store.setPreferredComposeModelRaw(model, commit: true)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertEqual(store.preferredComposeModelRaw(), model)

        // Transient blank of the chat model (pickDiffCapableFallback's empty branch) routes
        // through here with honorSync=true while sync is on.
        store.setPreferredComposeModelRaw("", commit: true, honorSync: true)

        XCTAssertEqual(
            store.planningModelRaw(), model,
            "A blank chat model must not blank the Oracle planning model (Oracle is never auto-healed)"
        )

        // Whitespace-only is blank too — raw values can arrive from the MCP/app_settings API.
        store.setPreferredComposeModelRaw("   ", commit: true, honorSync: true)
        XCTAssertEqual(
            store.planningModelRaw(), model,
            "A whitespace-only chat model must not blank the Oracle either"
        )

        // Relaunch: a fresh store reading the same on-disk document must still have the Oracle.
        let reloaded = try makeIsolatedStore(fileURL)
        XCTAssertEqual(
            reloaded.planningModelRaw(), model,
            "Oracle planning model must survive relaunch"
        )
    }

    @MainActor
    func testRealChatModelStillMirrorsIntoOracleWhenSyncOn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleMirrorKept.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")

        let store = try makeIsolatedStore(fileURL)
        let model = AIModel.codexCustom(name: "gpt-5.5-high").rawValue
        let newModel = AIModel.codexCustom(name: "gpt-5.5-low").rawValue

        store.setSyncChatModelWithOracle(true)
        store.setPlanningModelRaw(model, commit: true)
        store.setPreferredComposeModelRaw(model, commit: true)

        // A real (non-empty) chat model selection must still mirror into the Oracle when sync is on.
        store.setPreferredComposeModelRaw(newModel, commit: true, honorSync: true)
        XCTAssertEqual(store.planningModelRaw(), newModel)
    }
}
