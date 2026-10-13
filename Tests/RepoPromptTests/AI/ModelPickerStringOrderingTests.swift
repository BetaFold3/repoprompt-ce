import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class ModelPickerStringOrderingTests: XCTestCase {
    func testScalarOrderingUsesAsciiFoldThenRawScalarTieBreak() {
        XCTAssertEqual(
            ModelPickerStringOrdering.compare("GPT-5", "gpt-5", caseInsensitiveASCII: true),
            .orderedAscending
        )
        XCTAssertEqual(
            ["ı", "i", "I"].sorted { ModelPickerStringOrdering.precedes($0, $1) },
            ["I", "i", "ı"]
        )
        XCTAssertTrue(ModelPickerStringOrdering.precedes("gpt-5.6-sol-Low", "gpt-5.6-sol-low"))
    }

    func testAIModelSemanticPickerOrderingCoversGptVersionsServiceTierReasoningAndRawTieBreaks() {
        let models: [AIModel] = [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.6-sol-high"),
            .codexCustom(name: "gpt-5.4-low"),
            .codexCustom(name: "gpt-5.6-sol-low"),
            .codexCustom(name: "gpt-5.4-fast-low"),
            .codexCustom(name: "gpt-5.6-sol-Low")
        ]

        let sorted = AIModel.sortedForPicker(models).map(\.modelName)

        XCTAssertEqual(sorted, [
            "gpt-5.6-sol-Low",
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-high",
            "gpt-5.4-low",
            "gpt-5.4-fast-low",
            "gpt-5.4-fast-high",
            "gpt-5.2-high"
        ])
    }

    func testConfiguredAstraUsesTrustedDisplayOrderingAndStaticSolFallback() throws {
        let registry = OpenAIAPIModelMetadataRegistry.shared
        let previousRows = registry.rows
        try registry.resetForTesting(rows: OpenAIAPIModelMetadataBaseline.decode().document.models)
        defer { registry.resetForTesting(rows: previousRows) }

        func configured(
            id: String,
            effort: CodexReasoningEffort
        ) throws -> AIModel {
            let selection = try XCTUnwrap(OpenAIConfiguredModelSelection(
                modelID: id,
                reasoningMode: .standard,
                reasoningEffort: effort,
                supportsStreaming: true
            ))
            return .openAIConfigured(selection: selection)
        }

        let astraHigh = try configured(id: "gpt-6-astra", effort: .high)
        let astraLow = try configured(id: "gpt-6-astra", effort: .low)
        let solHigh = try configured(id: "gpt-5.6-sol", effort: .high)

        XCTAssertEqual(astraHigh.displayName, "GPT-6 Astra · Standard · High")
        XCTAssertEqual(solHigh.displayName, "GPT-5.6 Sol · Standard · High")
        XCTAssertEqual(
            AIModel.sortedForPicker([solHigh, astraHigh, astraLow]),
            [astraLow, astraHigh, solHigh]
        )
    }

    @MainActor
    func testCodexRefreshClassifiesSelectionByStoredBaseIdentity() {
        let live = CodexAppServerClient.RemoteModel(
            id: "gpt-daybreak-blue-latest",
            model: "gpt-daybreak-blue-latest",
            displayName: "Daybreak",
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: "ultra", description: "")]
        )

        XCTAssertTrue(CodexAgentModeCoordinator.shouldPreserveWithdrawnExplicitSelection(
            rawModel: "withdrawn-model-ultra",
            refreshedModels: [live]
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.shouldPreserveWithdrawnExplicitSelection(
            rawModel: "gpt-daybreak-blue-latest-ultra",
            refreshedModels: [live]
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.shouldPreserveWithdrawnExplicitSelection(
            rawModel: AgentModel.defaultModel.rawValue,
            refreshedModels: [live]
        ))
    }

    func testSemanticOrderingUsesFamilyBeforeDisplayNameAcrossFamilies() {
        let sorted = AIModel.sortedForPicker([
            .customProvider(name: "Aardvark", provider: "custom", model: "zzz-1"),
            .customProvider(name: "Zed", provider: "custom", model: "aaa-1")
        ])

        XCTAssertEqual(sorted.map(\.modelName), ["aaa-1", "zzz-1"])
    }

    func testStaleGeminiCLIPrefixedModelsAreRejectedForFallback() {
        XCTAssertNil(AIModel.fromModelName("gemini_cli_flash-2.5"))
        XCTAssertNil(AIModel.fromModelName(" gemini_cli_pro-3.1-preview "))
        XCTAssertEqual(AIModel.fromModelName("gemini-3-pro-preview"), .gemini3p1ProPreview)
    }

    func testClaudeCodePickerExposesFable51WithEffortVariantsFirstAndResolvesWireValue() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-fable-5-1")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-fable-5-1:xhigh")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-fable-5")))
        XCTAssertEqual(
            AIModel.fromModelName("\(ClaudeCodeAIModelCatalog.rawPrefix)claude-fable-5-1:xhigh"),
            .claudeCodeModel(specifier: "claude-fable-5-1:xhigh")
        )

        let menu = AIModel.claudeCodeMenu(for: models)
        XCTAssertEqual(menu.groups.first?.baseModelRaw, "claude-fable-5-1")
        let fable51Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-fable-5-1" })
        XCTAssertEqual(fable51Group.displayName, "Fable 5.1")
        XCTAssertEqual(fable51Group.options.map(\.displayName), ["Low", "Medium", "High", "Max", "XHigh"])
        XCTAssertEqual(Array(AgentModel.modelsForAgent(.claudeCode).prefix(3)), [.defaultModel, .claudeFable51, .claudeFable5])

        let selection = try ClaudeCodeProvider.resolveCLIModelSelection(
            for: .claudeCodeModel(specifier: "claude-fable-5-1:xhigh")
        )
        XCTAssertEqual(selection.modelArgument, "claude-fable-5-1")
        XCTAssertEqual(selection.effortLevel, .xhigh)
    }

    func testClaudeCodeEffectiveDefinitionsUseInjectedRegistryAndNumericFamilyOrdering() {
        let store = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(store.replace(with: [
            AnthropicDiscoveredModel(
                id: "claude-fable-5-2",
                displayName: "  Registry Fable 5.2  "
            ),
            AnthropicDiscoveredModel(id: "claude-fable-5-10"),
            AnthropicDiscoveredModel(
                id: "claude-opus-5-2",
                displayName: String(repeating: "x", count: 81)
            ),
            AnthropicDiscoveredModel(id: "claude-fable-5-preview"),
            AnthropicDiscoveredModel(
                id: "claude-fable-5-1",
                displayName: "Duplicate Static Name"
            ),
            AnthropicDiscoveredModel(
                id: "claude-sonnet-5-2",
                // One grapheme cluster (count == 1) hiding 400 combining
                // scalars: must fail the UTF-8 byte bound, not just count.
                displayName: "e" + String(repeating: "\u{0301}", count: 400)
            )
        ]))

        let definitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(store: store)
        XCTAssertEqual(
            Array(definitions.map(\.runtimeModelRaw).prefix(4)),
            [
                "claude-fable-5-10",
                "claude-fable-5-2",
                "claude-fable-5-1",
                "claude-fable-5"
            ]
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-fable-5-2" }?.displayName,
            "Registry Fable 5.2"
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-opus-5-2" }?.displayName,
            "Opus 5.2"
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-sonnet-5-2" }?.displayName,
            "Sonnet 5.2"
        )
        XCTAssertEqual(
            definitions.count { $0.runtimeModelRaw == "claude-fable-5-1" },
            1
        )
        XCTAssertFalse(definitions.contains {
            $0.runtimeModelRaw == "claude-fable-5-preview"
        })

        let pickerModels = ClaudeCodeAIModelCatalog.modelsForPicker(store: store)
        XCTAssertTrue(pickerModels.contains(
            .claudeCodeModel(specifier: "claude-fable-5-10:xhigh")
        ))
        XCTAssertFalse(pickerModels.contains(
            .claudeCodeModel(specifier: "claude-fable-5-preview")
        ))

        let menu = ClaudeCodeAIModelCatalog.menu(for: pickerModels, store: store)
        XCTAssertEqual(
            Array(menu.groups.map(\.baseModelRaw).prefix(4)),
            [
                "claude-fable-5-10",
                "claude-fable-5-2",
                "claude-fable-5-1",
                "claude-fable-5"
            ]
        )
        XCTAssertEqual(
            menu.groups.first { $0.baseModelRaw == "claude-fable-5-2" }?.displayName,
            "Registry Fable 5.2"
        )
    }

    func testClaudeCodeDatedTwinPointReleaseStaysDistinctFromUndatedStaticEntry() {
        let store = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(store.replace(with: [
            AnthropicDiscoveredModel(
                id: "claude-fable-5-1-20260315",
                // Registry-trusted name matching the static label must still
                // come out date-qualified — without double-appending the date.
                displayName: "Fable 5.1"
            ),
            AnthropicDiscoveredModel(id: "claude-fable-5-20260101")
        ]))

        let definitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(store: store)
        XCTAssertEqual(
            Array(definitions.map(\.runtimeModelRaw).prefix(4)),
            [
                "claude-fable-5-20260101",
                "claude-fable-5-1-20260315",
                "claude-fable-5-1",
                "claude-fable-5"
            ]
        )
        XCTAssertEqual(
            definitions.count { $0.runtimeModelRaw == "claude-fable-5-1-20260315" },
            1
        )
        XCTAssertEqual(
            definitions.count { $0.runtimeModelRaw == "claude-fable-5-1" },
            1
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-fable-5-1-20260315" }?.displayName,
            "Fable 5.1 (20260315)"
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-fable-5-1" }?.displayName,
            "Fable 5.1"
        )
        XCTAssertEqual(
            definitions.first { $0.runtimeModelRaw == "claude-fable-5-20260101" }?.displayName,
            "Fable 5.20260101"
        )

        let pickerModels = ClaudeCodeAIModelCatalog.modelsForPicker(store: store)
        XCTAssertEqual(
            pickerModels.count {
                $0 == .claudeCodeModel(specifier: "claude-fable-5-1-20260315:xhigh")
            },
            1
        )
        XCTAssertTrue(pickerModels.contains(
            .claudeCodeModel(specifier: "claude-fable-5-1:xhigh")
        ))

        let menu = ClaudeCodeAIModelCatalog.menu(for: pickerModels, store: store)
        XCTAssertEqual(
            menu.groups.first { $0.baseModelRaw == "claude-fable-5-1-20260315" }?.displayName,
            "Fable 5.1 (20260315)"
        )
        XCTAssertEqual(
            menu.groups.first { $0.baseModelRaw == "claude-fable-5-1" }?.displayName,
            "Fable 5.1"
        )

        // The promoted static recommendation target stays on the undated raw;
        // the dated twin never resolves to it.
        XCTAssertEqual(AgentModel.claudeFable51.rawValue, "claude-fable-5-1")
        XCTAssertFalse(AgentModel.claudeFable51.discoveryTags.isEmpty)
        XCTAssertNil(AgentModel.resolvedModel(
            forRaw: "claude-fable-5-1-20260315",
            agentKind: .claudeCode
        ))
    }

    func testClaudeCodeDynamicValidationIsRegistryIndependentAfterWithdrawal() {
        let store = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(store.replace(with: [
            AnthropicDiscoveredModel(id: "claude-fable-5-7-20260902")
        ]))
        XCTAssertTrue(
            ClaudeCodeAIModelCatalog.modelsForPicker(store: store).contains(
                .claudeCodeModel(specifier: "claude-fable-5-7-20260902:xhigh")
            )
        )

        XCTAssertTrue(store.replace(with: []))

        XCTAssertFalse(
            ClaudeCodeAIModelCatalog.modelsForPicker(store: store).contains(
                .claudeCodeModel(specifier: "claude-fable-5-7-20260902")
            )
        )
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.validatedModel(
                specifier: "claude-fable-5-7-20260902:xhigh",
                store: store
            ),
            .claudeCodeModel(specifier: "claude-fable-5-7-20260902:xhigh")
        )
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.displayName(
                for: "claude-fable-5-7-20260902:xhigh",
                store: store
            ),
            "Claude Code Fable 5.7 (20260902) XHigh"
        )
        XCTAssertNil(ClaudeCodeAIModelCatalog.validatedModel(
            specifier: "claude-fable-5-7-preview",
            store: store
        ))
        XCTAssertNil(ClaudeCodeAIModelCatalog.validatedModel(
            specifier: "claude-fable-5-7:ultra",
            store: store
        ))
    }

    func testClaudeCodeEffectiveDefinitionMemoizationSeparatesStoreIdentityAndRevision() {
        let firstStore = AnthropicDiscoveredModelStore.transient()
        let secondStore = AnthropicDiscoveredModelStore.transient()
        XCTAssertTrue(firstStore.replace(with: [
            AnthropicDiscoveredModel(id: "claude-fable-5-2")
        ]))
        XCTAssertTrue(secondStore.replace(with: [
            AnthropicDiscoveredModel(id: "claude-fable-5-3")
        ]))

        XCTAssertTrue(
            ClaudeCodeAIModelCatalog.effectiveDefinitions(store: firstStore)
                .contains { $0.runtimeModelRaw == "claude-fable-5-2" }
        )
        let secondDefinitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(
            store: secondStore
        )
        XCTAssertTrue(secondDefinitions.contains {
            $0.runtimeModelRaw == "claude-fable-5-3"
        })
        XCTAssertFalse(secondDefinitions.contains {
            $0.runtimeModelRaw == "claude-fable-5-2"
        })

        XCTAssertTrue(firstStore.replace(with: [
            AnthropicDiscoveredModel(id: "claude-fable-5-4")
        ]))
        let revisedDefinitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(
            store: firstStore
        )
        XCTAssertTrue(revisedDefinitions.contains {
            $0.runtimeModelRaw == "claude-fable-5-4"
        })
        XCTAssertFalse(revisedDefinitions.contains {
            $0.runtimeModelRaw == "claude-fable-5-2"
        })
    }

    func testClaudeCodePickerExposesSonnet5WithAllOfficialEffortVariants() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5:max")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-sonnet-5:xhigh")))
        XCTAssertEqual(
            AIModel.fromModelName("\(ClaudeCodeAIModelCatalog.rawPrefix)claude-sonnet-5:xhigh"),
            .claudeCodeModel(specifier: "claude-sonnet-5:xhigh")
        )

        let menu = AIModel.claudeCodeMenu(for: models)
        let sonnet5Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5Group.displayName, "Sonnet 5")
        XCTAssertEqual(sonnet5Group.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw), [
            "claude-sonnet-5:low",
            "claude-sonnet-5:medium",
            "claude-sonnet-5:high",
            "claude-sonnet-5:max",
            "claude-sonnet-5:xhigh"
        ])
        XCTAssertEqual(sonnet5Group.options.map(\.displayName), ["Low", "Medium", "High", "Max", "XHigh"])
    }

    func testClaudeCodeProviderResolvesSonnet5EffortSpecifierForCLI() throws {
        let maxSelection = try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-sonnet-5:max"))
        XCTAssertEqual(maxSelection.modelArgument, "claude-sonnet-5")
        XCTAssertEqual(maxSelection.effortLevel, .max)

        let xhighSelection = try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-sonnet-5:xhigh"))
        XCTAssertEqual(xhighSelection.modelArgument, "claude-sonnet-5")
        XCTAssertEqual(xhighSelection.effortLevel, .xhigh)
    }

    func testClaudeCodePickerExposesPinnedOpus5AndResolvesItForCLI() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-opus-5")))
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-opus-5:xhigh")))

        let menu = AIModel.claudeCodeMenu(for: models)
        let opus5Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-opus-5" })
        XCTAssertEqual(opus5Group.displayName, "Opus 5")
        XCTAssertEqual(opus5Group.options.map(\.displayName), ["Low", "Medium", "High", "Max", "XHigh"])
        XCTAssertEqual(AgentModel.claudeOpus5.contextWindowTokens, 1_000_000)

        let selection = try ClaudeCodeProvider.resolveCLIModelSelection(
            for: .claudeCodeModel(specifier: "claude-opus-5:xhigh")
        )
        XCTAssertEqual(selection.modelArgument, "claude-opus-5")
        XCTAssertEqual(selection.effortLevel, .xhigh)
    }

    func testCodexReasoningEffortParsesExtendedEffortsWithoutChangingRecommendations() {
        XCTAssertEqual(CodexReasoningEffort.parse("max"), .max)
        XCTAssertEqual(CodexReasoningEffort.parse("maximum"), .max)
        XCTAssertEqual(CodexReasoningEffort.parse("ultra"), .ultra)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-max", capabilities: .seedOnly).baseModel, "gpt-5.6-sol")
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-max", capabilities: .seedOnly).reasoningEffort, .max)
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-ultra", capabilities: .seedOnly).baseModel, "gpt-5.6-sol")
        XCTAssertEqual(CodexModelSpecifier(raw: "gpt-5.6-sol-ultra", capabilities: .seedOnly).reasoningEffort, .ultra)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-max", agentKind: .codexExec), .gpt56SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-ultra", agentKind: .codexExec), .gpt56SolUltra)
        XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.6-sol-max"), .codexCliGpt56SolMax)
        XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.6-sol-ultra"), .codexCliGpt56SolUltra)
        XCTAssertEqual(AIModel.codexCliGpt56SolMax.defaultReasoningEffort, "max")
        XCTAssertEqual(AIModel.codexCliGpt56SolUltra.defaultReasoningEffort, "ultra")
    }

    func testCodexModelSpecifierDoesNotMisparseGpt51CodexMaxBase() {
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max", capabilities: .seedOnly)
        XCTAssertEqual(base.baseModel, "gpt-5.1-codex-max")
        XCTAssertNil(base.reasoningEffort)

        let low = CodexModelSpecifier(raw: "gpt-5.1-codex-max-low", capabilities: .seedOnly)
        XCTAssertEqual(low.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(low.reasoningEffort, .low)

        let high = CodexModelSpecifier(raw: "gpt-5.1-codex-max-high", capabilities: .seedOnly)
        XCTAssertEqual(high.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(high.reasoningEffort, .high)
    }

    func testAIModelPickerDoesNotTreatGpt51CodexMaxFamilyTokenAsMaxEffort() {
        let codexMaxFamilySorted = AIModel.sortedForPicker([
            .gpt5CodexXHigh,
            .gpt5CodexMed,
            .gpt5CodexHigh,
            .gpt5CodexLow
        ]).map(\.rawValue)

        XCTAssertEqual(codexMaxFamilySorted, [
            "gpt-5.1-codex-max-low",
            "gpt-5.1-codex-max",
            "gpt-5.1-codex-max-high",
            "gpt-5.1-codex-max-xhigh"
        ])

        let extendedEffortSorted = AIModel.sortedForPicker([
            .codexCliGpt56SolUltra,
            .codexCliGpt56SolMax,
            .codexCliGpt56SolXHigh
        ]).map(\.rawValue)

        XCTAssertEqual(extendedEffortSorted, [
            "codex_cli_gpt-5.6-sol-xhigh",
            "codex_cli_gpt-5.6-sol-max",
            "codex_cli_gpt-5.6-sol-ultra"
        ])
    }

    func testStripCodexReasoningSuffixIsFamilyAwareForUltraFastAndCodexMaxLabels() {
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Ultra"), "GPT-5.6 Sol")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast X-High"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max High"), "GPT-5.1 Codex Max")

        let strippedFastUltra = AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra")
        XCTAssertEqual("\(strippedFastUltra) Ultra", "GPT-5.6 Sol Fast Ultra")
        XCTAssertFalse("\(strippedFastUltra) Ultra".contains("Ultra Fast Ultra"))
    }

    func testUnsupportedMaxUltraAgentModelResolutionReturnsNilInsteadOfMediumFallback() {
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.1-codex-max", agentKind: .codexExec))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-luna-ultra", agentKind: .codexExec))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-preview-ultra", agentKind: .codexExec))
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-max", agentKind: .codexExec), .gpt56SolMax)
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.6-sol-ultra", agentKind: .codexExec), .gpt56SolUltra)
    }

    func testCodexPickerExposesExtendedEffortsOnlyWhereSupportedAndInOrder() {
        let models = AgentModel.modelsForAgent(.codexExec)
        guard let solXHighIndex = models.firstIndex(of: .gpt56SolXHigh),
              let solMaxIndex = models.firstIndex(of: .gpt56SolMax),
              let solUltraIndex = models.firstIndex(of: .gpt56SolUltra),
              let terraXHighIndex = models.firstIndex(of: .gpt56TerraXHigh),
              let terraMaxIndex = models.firstIndex(of: .gpt56TerraMax),
              let terraUltraIndex = models.firstIndex(of: .gpt56TerraUltra),
              let lunaXHighIndex = models.firstIndex(of: .gpt56LunaXHigh),
              let lunaMaxIndex = models.firstIndex(of: .gpt56LunaMax)
        else {
            XCTFail("Expected GPT-5.6 extended effort entries in Codex picker")
            return
        }
        XCTAssertLessThan(solXHighIndex, solMaxIndex)
        XCTAssertLessThan(solMaxIndex, solUltraIndex)
        XCTAssertLessThan(terraXHighIndex, terraMaxIndex)
        XCTAssertLessThan(terraMaxIndex, terraUltraIndex)
        XCTAssertLessThan(lunaXHighIndex, lunaMaxIndex)
        XCTAssertNil(AgentModel(rawValue: "gpt-5.6-luna-ultra"))
        XCTAssertNil(AgentModel.resolvedModel(forRaw: "gpt-5.6-luna-ultra", agentKind: .codexExec))
        XCTAssertNil(AIModel.fromModelName("codex_cli_gpt-5.6-luna-ultra"))
        XCTAssertNil(CodexModelSpecifier(raw: "gpt-5.6-luna-ultra", capabilities: .seedOnly).reasoningEffort)
        XCTAssertTrue(AgentModel.gpt56SolMax.description.contains("choose intentionally"))
        XCTAssertTrue(AgentModel.gpt56SolUltra.description.contains("choose intentionally"))
    }

    func testGpt56DiscoveryTagsStayOnPriorLowAndHighRecommendationLevels() {
        XCTAssertEqual(AgentModel.gpt56SolLow.discoveryTags, [.fast, .exploration, .engineering])
        XCTAssertEqual(AgentModel.gpt56SolHigh.discoveryTags, [.complex, .engineering, .pair])
        XCTAssertEqual(AgentModel.gpt56SolMedium.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolXHigh.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolMax.discoveryTags, [])
        XCTAssertEqual(AgentModel.gpt56SolUltra.discoveryTags, [])
    }

    func testDynamicCodexModelEvidenceIncludesUltraOnlyForSolAndTerra() throws {
        let options = CodexDynamicModelMapper.options(from: [
            dynamicCodexRecord(id: "gpt-5.6-sol", defaultEffort: "low", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            dynamicCodexRecord(id: "gpt-5.6-terra", defaultEffort: "medium", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            dynamicCodexRecord(id: "gpt-5.6-luna", defaultEffort: "medium", efforts: ["low", "medium", "high", "xhigh", "max"])
        ])

        func ids(for baseID: String) -> [String] {
            options.filter { $0.baseID == baseID }.map(\.id)
        }

        XCTAssertEqual(ids(for: "gpt-5.6-sol"), [
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-medium",
            "gpt-5.6-sol-high",
            "gpt-5.6-sol-xhigh",
            "gpt-5.6-sol-max",
            "gpt-5.6-sol-ultra"
        ])
        XCTAssertEqual(ids(for: "gpt-5.6-terra"), [
            "gpt-5.6-terra-low",
            "gpt-5.6-terra-medium",
            "gpt-5.6-terra-high",
            "gpt-5.6-terra-xhigh",
            "gpt-5.6-terra-max",
            "gpt-5.6-terra-ultra"
        ])
        XCTAssertEqual(ids(for: "gpt-5.6-luna"), [
            "gpt-5.6-luna-low",
            "gpt-5.6-luna-medium",
            "gpt-5.6-luna-high",
            "gpt-5.6-luna-xhigh",
            "gpt-5.6-luna-max"
        ])
        XCTAssertFalse(ids(for: "gpt-5.6-luna").contains("gpt-5.6-luna-ultra"))
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-sol-low" }).isDefault)
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-terra-medium" }).isDefault)
        XCTAssertTrue(try XCTUnwrap(options.first { $0.id == "gpt-5.6-luna-medium" }).isDefault)
    }

    func testBestPracticeRecommendationsDoNotDefaultToMaxOrUltra() {
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelLabel, "GPT-5.6 Sol")
        XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-5.6-sol")
        let recommendedModelStrings = BestPracticeProfiles.all.compactMap(\.modelString)
        XCTAssertFalse(recommendedModelStrings.contains { $0.contains("-max") || $0.contains("-ultra") })
        XCTAssertFalse(BestPracticeProfiles.all.compactMap(\.agentModel).contains(.gpt56SolMax))
        XCTAssertFalse(BestPracticeProfiles.all.compactMap(\.agentModel).contains(.gpt56SolUltra))
        XCTAssertFalse(BestPracticeProfiles.codexVsOpenAIExplanation.contains("Sol XHigh for ChatGPT"))
    }

    func testSentryTelemetryModelFamilyIncludesGpt56() {
        XCTAssertEqual(SentryTelemetryBootstrap.ModelFamily.gpt56.rawValue, "gpt_5_6")
    }

    func testAIModelCodexMenuGroupsUseStableSemanticOrdering() {
        let groups = AIModel.codexMenuGroups(for: [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.6-sol-high"),
            .codexCustom(name: "gpt-5.4-low"),
            .codexCustom(name: "gpt-5.6-sol-low"),
            .codexCustom(name: "gpt-5.4-fast-low"),
            .codexCustom(name: "gpt-5.6-sol-Low")
        ])

        XCTAssertEqual(groups.map(\.baseModelID), [
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])
        XCTAssertEqual(
            groups.first { $0.baseModelID == "gpt-5.6-sol" }?.models.map(\.modelName),
            ["gpt-5.6-sol-Low", "gpt-5.6-sol-low", "gpt-5.6-sol-high"]
        )
    }

    func testAgentModelCatalogCodexMenuUsesStableSemanticOrdering() {
        let menu = AgentModelCatalog.codexMenu(for: [
            option(raw: AgentModel.defaultModel.rawValue, displayName: AgentModel.defaultModel.displayName, placeholderDefault: true),
            option(raw: "gpt-5.2-high", displayName: "GPT-5.2 High"),
            option(raw: "gpt-5.4-fast-high", displayName: "GPT-5.4 Fast High"),
            option(raw: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High"),
            option(raw: "gpt-5.4-low", displayName: "GPT-5.4 Low"),
            option(raw: "gpt-5.6-sol-low", displayName: "GPT-5.6 Sol Low"),
            option(raw: "gpt-5.4-fast-low", displayName: "GPT-5.4 Fast Low"),
            option(raw: "gpt-5.6-sol-Low", displayName: "GPT-5.6 Sol Low")
        ], capabilities: .seedOnly)

        XCTAssertEqual(menu.defaultOption?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertEqual(menu.groups.map(\.baseModelID), [
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])
        XCTAssertEqual(
            menu.groups.first { $0.baseModelID == "gpt-5.6-sol" }?.options.map(\.rawValue),
            ["gpt-5.6-sol-Low", "gpt-5.6-sol-low", "gpt-5.6-sol-high"]
        )
    }

    @MainActor
    func testCollapsedCodexOptionsUseStableSemanticOrderingAndPreserveDefaults() throws {
        let collapsed: [AgentModelOption] = CodexAgentModeCoordinator.test_collapseCodexModelOptions([
            option(raw: AgentModel.defaultModel.rawValue, displayName: AgentModel.defaultModel.displayName, placeholderDefault: true),
            option(raw: "gpt-5.2-high", displayName: "GPT-5.2 High"),
            option(raw: "gpt-5.4-fast-high", displayName: "GPT-5.4 Fast High"),
            option(raw: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol High", providerDefault: true),
            option(raw: "gpt-5.4-low", displayName: "GPT-5.4 Low"),
            option(raw: "gpt-5.6-sol-low", displayName: "GPT-5.6 Sol Low"),
            option(raw: "gpt-5.4-fast-low", displayName: "GPT-5.4 Fast Low")
        ])

        XCTAssertEqual(collapsed.map(\.rawValue), [
            AgentModel.defaultModel.rawValue,
            "gpt-5.6-sol",
            "gpt-5.4",
            "gpt-5.4-fast",
            "gpt-5.2"
        ])

        let gpt56Sol = try XCTUnwrap(collapsed.first { $0.rawValue == "gpt-5.6-sol" })
        XCTAssertEqual(gpt56Sol.supportedReasoningEfforts, [CodexReasoningEffort.low, .high])
        XCTAssertEqual(gpt56Sol.defaultReasoningEffort, .high)
        XCTAssertEqual(gpt56Sol.isProviderDefault, true)
    }

    func testDynamicCodexMapperOrdersPerOptionDefaultBeforeSemanticBaseOrder() {
        let options = CodexDynamicModelMapper.options(from: [
            orderingRecord(id: "gpt-5.1-codex-max"),
            orderingRecord(id: "gpt-5.6-sol", efforts: ["ultra", "low", "max"], defaultEffort: "low"),
            orderingRecord(id: "gpt-5.4", isDefault: true, efforts: ["high", "low"], defaultEffort: "low")
        ])

        XCTAssertEqual(options.map(\.id), [
            "gpt-5.4-low",
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-max",
            "gpt-5.6-sol-ultra",
            "gpt-5.4-high",
            "gpt-5.1-codex-max"
        ])
        XCTAssertEqual(options.filter(\.isDefault).map(\.id), ["gpt-5.4-low"])
    }

    func testDynamicCodexMapperFinalSortMatchesFrozenStringComparatorAcrossPermutations() {
        let records: [CodexDynamicModelRecord] = [
            orderingRecord(id: "gpt-5.6-sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
            orderingRecord(id: "gpt-5.6-terra", isDefault: true, efforts: ["low", "xhigh", "max", "ultra"], defaultEffort: "xhigh"),
            orderingRecord(id: "gpt-5.6-luna", efforts: ["low", "max"], defaultEffort: nil),
            orderingRecord(id: "GPT-5.6-Sol", displayName: "GPT-5.6 Sol Mixed", efforts: ["low", "minimal"], defaultEffort: "low"),
            orderingRecord(id: "gpt-5.6", efforts: ["high"], defaultEffort: "high"),
            orderingRecord(id: "gpt-5.5", isDefault: true),
            orderingRecord(id: "gpt-5.4", efforts: ["low", "high"], defaultEffort: "high"),
            orderingRecord(id: "gpt-5.4-fast", efforts: ["low", "high"], defaultEffort: "low"),
            orderingRecord(id: "gpt-5.1-codex-max", efforts: ["low", "high", "xhigh"], defaultEffort: "xhigh"),
            orderingRecord(id: "gpt-5.3-codex"),
            orderingRecord(id: "o3", displayName: ""),
            orderingRecord(id: "custom-model", displayName: "Same Label"),
            orderingRecord(id: "custom-model-two", displayName: "same label"),
            orderingRecord(id: "modèle-ünï", displayName: "Modèle"),
            orderingRecord(id: "mode\u{0300}le-u\u{0308}ni\u{0308}", displayName: "Mode\u{0300}le"),
            orderingRecord(id: "ı-model", displayName: "ı"),
            orderingRecord(id: "I-model", displayName: "I"),
            orderingRecord(id: "gpt-5.4", efforts: ["low", "high"], defaultEffort: "high"),
            orderingRecord(id: "  "),
            orderingRecord(id: "zz-default", isDefault: true, efforts: ["ultra", "none"], defaultEffort: "ultra")
        ]

        XCTAssertEqual(CodexDynamicModelMapper.options(from: [CodexDynamicModelRecord]()), [])
        XCTAssertEqual(referenceDynamicCodexOptions(from: []), [])

        let count = records.count
        var permutations: [[CodexDynamicModelRecord]] = []
        for base in [records, Array(records.reversed())] {
            for offset in 0 ..< count {
                permutations.append(Array(base[offset...] + base[..<offset]))
            }
            let evens = base.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            let odds = base.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
            permutations.append(evens + odds)
        }

        for (index, permutation) in permutations.enumerated() {
            let actual = CodexDynamicModelMapper.options(from: permutation)
            XCTAssertFalse(actual.isEmpty)
            XCTAssertEqual(actual, referenceDynamicCodexOptions(from: permutation), "permutation \(index)")
        }
    }

    func testCodexBaseModelSortKeyMatchesStringComparatorForAllPairs() {
        let identifiers = [
            "gpt-5.6-sol", "GPT-5.6-Sol", "gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-5.6-sol-ultra", "gpt-5.6-terra-max", "gpt-5.6-sol-fast", "gpt-5.5",
            "gpt-5.4", "gpt-5.4-fast", "gpt-5.3-codex", "gpt-5.1-codex-max", "o3",
            "custom-model", "mod\u{00E8}le", "mode\u{0300}le", "\u{0131}", "I", "", "  "
        ]
        for lhs in identifiers {
            let lhsKey = AIModel.CodexBaseModelSortKey(identifier: lhs)
            for rhs in identifiers {
                XCTAssertEqual(
                    lhsKey.precedes(AIModel.CodexBaseModelSortKey(identifier: rhs)),
                    AIModel.codexBaseModelPrecedes(lhs, rhs),
                    "\(lhs.debugDescription) vs \(rhs.debugDescription)"
                )
            }
        }
    }

    /// Collects single-record mapper output, already sorted within each record,
    /// and applies the mapper's first-wins lowercased-ID dedup. A frozen copy
    /// of the pre-key final sort then calls the unchanged string comparator.
    private func referenceDynamicCodexOptions(
        from records: [CodexDynamicModelRecord]
    ) -> [CodexDynamicModelOption] {
        var seen = Set<String>()
        var generated: [CodexDynamicModelOption] = []
        for record in records {
            for option in CodexDynamicModelMapper.options(from: [record])
                where seen.insert(option.id.lowercased()).inserted
            {
                generated.append(option)
            }
        }

        func effortRank(_ effort: CodexReasoningEffort?) -> Int {
            guard let effort else { return -1 }
            return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
        }

        return generated.sorted { lhs, rhs in
            let leftBase = lhs.baseID.lowercased()
            let rightBase = rhs.baseID.lowercased()
            if leftBase == rightBase {
                let leftRank = effortRank(lhs.reasoningEffort)
                let rightRank = effortRank(rhs.reasoningEffort)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            if AIModel.codexBaseModelPrecedes(leftBase, rightBase) { return true }
            if AIModel.codexBaseModelPrecedes(rightBase, leftBase) { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func orderingRecord(
        id: String,
        displayName: String? = nil,
        isDefault: Bool = false,
        efforts: [String] = [],
        defaultEffort: String? = nil
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: displayName ?? id,
            description: "\(id) description",
            isDefault: isDefault,
            supportedReasoningEfforts: efforts.map {
                CodexDynamicReasoningRecord(reasoningEffort: $0, description: "\(id) \($0)")
            },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func dynamicCodexRecord(
        id: String,
        defaultEffort: String,
        efforts: [String]
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: id,
            description: id,
            isDefault: true,
            supportedReasoningEfforts: efforts.map {
                CodexDynamicReasoningRecord(reasoningEffort: $0, description: "\($0) effort")
            },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func option(
        raw: String,
        displayName: String,
        placeholderDefault: Bool = false,
        providerDefault: Bool = false,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: raw,
            displayName: displayName,
            description: nil,
            isPlaceholderDefault: placeholderDefault,
            isProviderDefault: providerDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort
        )
    }
}
