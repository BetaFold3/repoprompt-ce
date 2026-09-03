@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class OhMyPiModelCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        #endif
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        #endif
        super.tearDown()
    }

    func testRawRoundTripsPreserveWireIDsAndRejectEmptySuffix() async throws {
        let wireIDs = [
            "cursor/gpt-5.6-sol-max-fast",
            "provider:model:variant",
            "MixedCase/Model-ID",
            "cursor/AlreadyCursorPrefixed"
        ]

        for wireID in wireIDs {
            let model = AIModel.ohMyPiCustom(name: wireID)
            XCTAssertEqual(model.rawValue, "ohmypi_custom_\(wireID)")
            XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
            XCTAssertEqual(model.providerType, .ohMyPi)
            XCTAssertEqual(model.modelName, wireID)
        }

        XCTAssertNil(AIModel.fromModelName("ohmypi_custom_"))
        XCTAssertEqual(AIProviderType.displayName(for: .ohMyPi), "Oh My Pi")
        XCTAssertEqual(AIModel.test_cursorProviderIndex, 13)
        XCTAssertEqual(AIModel.test_ohMyPiProviderIndex, 14)
        XCTAssertNil(AIProviderType.ohMyPi.secureStorageAccount)

        let secureStorage = TestSecureStorageBackend()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: secureStorage)
        )
        let storedOhMyPiKey = try await keyManager.getAPIKey(for: .ohMyPi)
        XCTAssertNil(storedOhMyPiKey)
        try await keyManager.saveAPIKey("must-not-persist", for: .ohMyPi)
        try await keyManager.deleteAPIKey(for: .ohMyPi)
        XCTAssertTrue(secureStorage.calls.isEmpty)
    }

    func testCatalogHasNoStaticFallbackAndUsesCanonicalRegistryMetadata() {
        XCTAssertTrue(ACPAIModelCatalog.ohMyPiModelsFromStore().isEmpty)

        let canonicalRaw = "Cursor/GPT:Fast"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: canonicalRaw,
                        displayName: "GPT Fast via OMP",
                        description: "Remote OMP model",
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: canonicalRaw
            ),
            for: .ohMyPi
        ))

        let persisted = AIModel.ohMyPiCustom(name: "cursor/gpt:fast")
        XCTAssertEqual(persisted.rawValue, "ohmypi_custom_cursor/gpt:fast")
        XCTAssertEqual(persisted.modelName, canonicalRaw)
        XCTAssertEqual(persisted.displayName, "GPT Fast via OMP")
        XCTAssertEqual(ACPAIModelCatalog.ohMyPiModelsFromStore().map(\.modelName), [canonicalRaw])
    }

    @MainActor
    func testGroupingPreservesFullSelectionAndOMPProviderIsLastWhenAvailable() async {
        let firstRaw = "cursor/gpt-5.6-sol-max-fast"
        let secondRaw = "openrouter/claude-opus"
        let groups = OhMyPiModelMenuBuilder.groups(for: [
            .ohMyPiCustom(name: secondRaw),
            .cursorCustom(name: "gpt-5.6-sol"),
            .ohMyPiCustom(name: firstRaw)
        ])

        XCTAssertEqual(groups.map(\.namespace), ["cursor", "openrouter"])
        XCTAssertEqual(groups[0].leaves.map(\.title), ["gpt-5.6-sol-max-fast"])
        XCTAssertEqual(groups[0].leaves.map(\.model.rawValue), ["ohmypi_custom_\(firstRaw)"])

        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: firstRaw,
                        displayName: firstRaw,
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: firstRaw
            ),
            for: .ohMyPi
        ))

        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        viewModel.isCodexConnected = true
        viewModel.isOhMyPiConnected = false
        await viewModel.updateAvailableModels()
        let firstBeforeOMP = viewModel.availableModels.first
        XCTAssertFalse(viewModel.availableModels.contains { $0.providerType == .ohMyPi })

        viewModel.isOhMyPiConnected = true
        await viewModel.updateAvailableModels()
        XCTAssertEqual(viewModel.availableModels.first, firstBeforeOMP)
        XCTAssertEqual(viewModel.availableModels.last?.providerType, .ohMyPi)

        viewModel.isOhMyPiConnected = false
        await viewModel.updateAvailableModels()
        XCTAssertFalse(viewModel.availableModels.contains { $0.providerType == .ohMyPi })
        XCTAssertEqual(
            AIModelDropdown.displayName(
                forRawValue: AIModel.ohMyPiCustom(name: firstRaw).rawValue,
                destinationID: "planningModel",
                availableModels: viewModel.availableModels,
                customOpenRouterModels: []
            ),
            "OMP/\(firstRaw)"
        )
    }

    func testProjectorAndStableMenuAreBijectiveForOMP1734Catalog() throws {
        let wireIDs = try fixtureWireIDs()
        XCTAssertEqual(wireIDs.count, 203)

        let inputs = wireIDs.enumerated().map {
            OhMyPiModelMenuProjector.Input(
                sourceID: "source-\($0.offset)",
                wireID: $0.element,
                displayName: "Display \($0.offset)"
            )
        }
        let projection = OhMyPiModelMenuProjector.project(inputs)
        XCTAssertEqual(multiset(projection.allLeaves.map(\.wireID)), multiset(wireIDs))
        XCTAssertEqual(multiset(projection.allLeaves.map(\.sourceID)), multiset(inputs.map(\.sourceID)))

        let cursor = try XCTUnwrap(projection.namespaceGroups.first { $0.namespace == "cursor" })
        let sol = try XCTUnwrap(cursor.modelGroups.first { $0.title == "gpt-5.6-sol" })
        XCTAssertTrue(sol.isFamily)
        XCTAssertEqual(sol.normalLeaves.map(\.title), ["None", "Low", "Medium", "High", "X-High", "Max"])
        XCTAssertEqual(sol.fastLeaves.map(\.title), ["None", "Low", "Medium", "High", "X-High", "Max"])
        XCTAssertTrue(sol.fastLeaves.allSatisfy(\.isFast))

        let options = wireIDs.enumerated().map {
            AgentModelOption(
                rawValue: $0.element,
                displayName: "source-\($0.offset)",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        var selectedWireIDs: [String] = []
        var selectedSourceIDs: [String] = []
        let menuItems = AgentModelStableMenuItems.modelItems(
            agentKind: .ohMyPi,
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: ""
        ) { agent, option in
            XCTAssertEqual(agent, .ohMyPi)
            selectedWireIDs.append(option.rawValue)
            selectedSourceIDs.append(option.displayName)
        }
        performAllActions(in: menuItems)
        XCTAssertEqual(multiset(selectedWireIDs), multiset(wireIDs))
        XCTAssertEqual(multiset(selectedSourceIDs), multiset(inputs.map(\.sourceID)))
    }

    func testOMP1813FixtureProjectsCollapsedGrokLeavesAsThinkingCapable() throws {
        let wireIDs = try fixtureWireIDs(named: "models-18.1.3.json")
        XCTAssertEqual(wireIDs.count, 144)
        XCTAssertEqual(
            wireIDs.filter { $0.hasPrefix("cursor/cursor-grok-4.5") },
            ["cursor/cursor-grok-4.5", "cursor/cursor-grok-4.5-fast"]
        )
        XCTAssertEqual(
            wireIDs.filter { $0.hasPrefix("cursor/cursor-grok-4.6") },
            ["cursor/cursor-grok-4.6", "cursor/cursor-grok-4.6-fast"]
        )
        XCTAssertTrue(wireIDs.contains("cursor/gpt-5.2"))
        XCTAssertTrue(wireIDs.contains("cursor/gpt-5.2-fast"))
        XCTAssertTrue(wireIDs.contains("cursor/gpt-5.2-high"))
        XCTAssertTrue(wireIDs.contains("cursor/gpt-5.2-high-fast"))

        let projection = OhMyPiModelMenuProjector.project(wireIDs.enumerated().map {
            .init(sourceID: "source-\($0.offset)", wireID: $0.element, displayName: $0.element)
        })
        let cursor = try XCTUnwrap(projection.namespaceGroups.first { $0.namespace == "cursor" })
        for title in ["cursor-grok-4.5", "cursor-grok-4.6"] {
            let family = try XCTUnwrap(cursor.modelGroups.first { $0.title == title })
            XCTAssertTrue(family.isFamily)
            XCTAssertEqual(family.normalLeaves.map(\.title), ["Default"])
            XCTAssertEqual(family.fastLeaves.map(\.title), ["Default"])
            XCTAssertTrue(family.allLeaves.allSatisfy { $0.effort == nil && $0.allowsThinkingAccessory })
        }

        let gpt52 = try XCTUnwrap(cursor.modelGroups.first { $0.title == "gpt-5.2" })
        XCTAssertTrue(gpt52.isFamily)
        XCTAssertTrue(gpt52.allLeaves.filter { $0.effort == nil }.allSatisfy(\.allowsThinkingAccessory))
        XCTAssertTrue(gpt52.allLeaves.filter { $0.effort != nil }.allSatisfy { !$0.allowsThinkingAccessory })
        XCTAssertTrue(projection.allLeaves.filter { $0.effort != nil }.allSatisfy { !$0.allowsThinkingAccessory })
    }

    func testSweepTargetsExcludeEffortEncodedLeavesAndOrderSelectedFirst() {
        let targets = OhMyPiThinkingSweepTargets.compute(
            wireIDs: [
                "cursor/gpt-5.2",
                "cursor/gpt-5.2-high",
                "cursor/gpt-5.2-fast",
                "cursor/gpt-5.2-high-fast",
                "google/gemini-3.7-flash"
            ],
            selectedRawModel: "cursor/gpt-5.2-fast"
        )

        XCTAssertEqual(targets.first, "cursor/gpt-5.2-fast")
        XCTAssertTrue(targets.contains("cursor/gpt-5.2"))
        XCTAssertTrue(targets.contains("google/gemini-3.7-flash"))
        XCTAssertFalse(targets.contains("cursor/gpt-5.2-high"))
        XCTAssertFalse(targets.contains("cursor/gpt-5.2-high-fast"))
    }

    func testThinkingRowsExposeQueuedPromotionAndUnsupportedState() {
        let queued = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .queued,
            storedChoice: nil
        )
        XCTAssertEqual(queued.map(\.title), [
            "Default",
            "Queued — loading in background…",
            "Load now"
        ])
        XCTAssertFalse(queued[1].isEnabled)
        XCTAssertEqual(queued[2].action, .load)

        let unsupported = OhMyPiThinkingMenuBuilder.rows(
            capability: nil,
            probeState: .unsupported,
            storedChoice: nil
        )
        XCTAssertEqual(unsupported.map(\.title), [
            "Default",
            "This model does not advertise thinking levels."
        ])
        XCTAssertFalse(unsupported.contains { $0.action == .load })
    }

    func testSweepStatusHeaderReflectsRunningPartialFailedCompletedAndIdle() {
        XCTAssertNil(OhMyPiThinkingSweepStatusPresentation.headerText(.idle))
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(
                .running(done: 12, total: 24, current: "cursor/cursor-grok-4.6")
            ),
            "Loading thinking levels… 12/24 · cursor/cursor-grok-4.6"
        )
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(.partial(loaded: 18, deferred: 6)),
            "Loaded 18 · 6 deferred — open this menu again to continue"
        )
        XCTAssertEqual(
            OhMyPiThinkingSweepStatusPresentation.headerText(
                .completed(loaded: 18, failed: 3, unsupported: 2, at: Date(timeIntervalSince1970: 0))
            ),
            "Thinking levels: 3 failed — hover away and back to refresh"
        )
        XCTAssertNotNil(OhMyPiThinkingSweepStatusPresentation.headerText(
            .failed(reason: "unavailable", at: Date(timeIntervalSince1970: 0))
        ))
    }

    func testProjectorShapeForCollapsedPairsAndMixedGpt52Family() throws {
        let wireIDs = try fixtureWireIDs(named: "models-18.1.3.json")
        let projection = OhMyPiModelMenuProjector.project(wireIDs.enumerated().map {
            .init(sourceID: "source-\($0.offset)", wireID: $0.element, displayName: $0.element)
        })
        let cursor = try XCTUnwrap(projection.namespaceGroups.first { $0.namespace == "cursor" })

        for title in ["cursor-grok-4.5", "cursor-grok-4.6"] {
            let group = try XCTUnwrap(cursor.modelGroups.first { $0.title == title })
            XCTAssertEqual(
                group.shape,
                .init(collapsesNormal: true, collapsesFast: true),
                title
            )
        }

        let mixed = try XCTUnwrap(cursor.modelGroups.first { $0.title == "gpt-5.2" })
        XCTAssertEqual(
            mixed.shape,
            .init(collapsesNormal: false, collapsesFast: false)
        )
    }

    func testSelectionIndexTitlesMatchProjectorShape() {
        let wireIDs = [
            "cursor/cursor-grok-4.6",
            "cursor/cursor-grok-4.6-fast",
            "cursor/mixed",
            "cursor/mixed-low",
            "cursor/mixed-fast"
        ]
        let options = wireIDs.map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let index = AgentModelSelectionIndex.local(
            agents: [.ohMyPi],
            optionsByAgent: [.ohMyPi: options],
            selected: nil,
            selectionDefaults: .standard
        )
        let titlesByWireID = Dictionary(uniqueKeysWithValues: index.leaves.map {
            ($0.id.modelRaw, $0.title)
        })

        XCTAssertEqual(titlesByWireID["cursor/cursor-grok-4.6"], "cursor-grok-4.6")
        XCTAssertEqual(titlesByWireID["cursor/cursor-grok-4.6-fast"], "cursor-grok-4.6 Fast")
        XCTAssertEqual(titlesByWireID["cursor/mixed"], "mixed")
        XCTAssertEqual(titlesByWireID["cursor/mixed-low"], "mixed Low")
        XCTAssertEqual(titlesByWireID["cursor/mixed-fast"], "mixed Fast")
    }

    @MainActor
    func testPositionHCollapsesSingletonDefaultBranchesAcrossStableSurfaces() throws {
        let wireIDs = ["cursor/cursor-grok-4.6", "cursor/cursor-grok-4.6-fast"]
        let options = wireIDs.map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let agentItems = AgentModelStableMenuItems.ohMyPiModelItems(
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: wireIDs[0]
        ) { _, _ in }
        let agentCursor = try XCTUnwrap(agentItems.first { $0.title == "cursor" })
        XCTAssertEqual(
            agentCursor.submenuItems?.map(\.title),
            ["cursor-grok-4.6", "cursor-grok-4.6 Fast"]
        )

        let models = wireIDs.map(AIModel.ohMyPiCustom(name:))
        let destination = ModelDestination(
            id: "position-h-test",
            getter: { models[0].rawValue },
            applier: { _ in }
        )
        let settingsItems = OhMyPiModelMenuBuilder.stableMenuItems(
            for: models,
            destination: destination,
            onModelCommit: { _ in }
        )
        let settingsCursor = try XCTUnwrap(settingsItems.first { $0.title == "cursor" })
        XCTAssertEqual(
            settingsCursor.submenuItems?.map(\.title),
            ["cursor-grok-4.6", "cursor-grok-4.6 Fast"]
        )
    }

    @MainActor
    func testPositionHKeepsMixedFamilyContainerAndCollapsesFastLeaf() throws {
        let options = [
            "cursor/mixed",
            "cursor/mixed-low",
            "cursor/mixed-fast"
        ].map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let items = AgentModelStableMenuItems.ohMyPiModelItems(
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: options[0].rawValue
        ) { _, _ in }
        let namespace = try XCTUnwrap(items.first { $0.title == "cursor" })
        let family = try XCTUnwrap(namespace.submenuItems?.first { $0.title == "mixed" })

        XCTAssertEqual(family.submenuItems?.map(\.title), ["Default", "Low", "Fast"])
        XCTAssertNil(family.submenuItems?.last?.submenuItems)
    }

    @MainActor
    func testPositionHKeepsEffortEncodedSingletonBranchesNested() throws {
        let options = [
            "cursor/effort-high",
            "cursor/effort-high-fast"
        ].map {
            AgentModelOption(
                rawValue: $0,
                displayName: $0,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let items = AgentModelStableMenuItems.ohMyPiModelItems(
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: options[0].rawValue
        ) { _, _ in }
        let namespace = try XCTUnwrap(items.first { $0.title == "cursor" })
        let family = try XCTUnwrap(namespace.submenuItems?.first { $0.title == "effort" })

        XCTAssertEqual(family.submenuItems?.map(\.title), ["High", "Fast"])
        XCTAssertEqual(family.submenuItems?.last?.submenuItems?.map(\.title), ["High"])
    }

    func testOhMyPiIgnoresGroupOpenCodeFlagAndAlwaysProjects() throws {
        let wireIDs = try fixtureWireIDs()
        XCTAssertEqual(wireIDs.count, 203)

        let options = wireIDs.enumerated().map {
            AgentModelOption(
                rawValue: $0.element,
                displayName: "source-\($0.offset)",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        var selectedWireIDs: [String] = []
        var selectedSourceIDs: [String] = []
        let menuItems = AgentModelStableMenuItems.modelItems(
            agentKind: .ohMyPi,
            options: options,
            selectedAgent: .ohMyPi,
            selectedModelRaw: "",
            groupOpenCode: false
        ) { agent, option in
            XCTAssertEqual(agent, .ohMyPi)
            selectedWireIDs.append(option.rawValue)
            selectedSourceIDs.append(option.displayName)
        }

        XCTAssertLessThan(menuItems.count, wireIDs.count)
        XCTAssertNotNil(try XCTUnwrap(menuItems.first { $0.title == "cursor" }).submenuItems)
        XCTAssertNotNil(try XCTUnwrap(menuItems.first { $0.title == "google-antigravity" }).submenuItems)

        performAllActions(in: menuItems)
        XCTAssertEqual(multiset(selectedWireIDs), multiset(wireIDs))
        XCTAssertEqual(multiset(selectedSourceIDs), multiset(options.map(\.displayName)))
    }

    func testAntigravityGeminiHasNoFabricatedEffortLeaves() throws {
        let wireIDs = try fixtureWireIDs()
        XCTAssertEqual(wireIDs.count, 203)

        let expectedWireIDs = [
            "google-antigravity/gemini-3.7-flash",
            "google-antigravity/gemini-3.7-flash-tiered"
        ]
        XCTAssertEqual(
            wireIDs.filter { $0.hasPrefix("google-antigravity/gemini-3.7-flash") },
            expectedWireIDs
        )

        let inputs = wireIDs.enumerated().map {
            OhMyPiModelMenuProjector.Input(
                sourceID: "source-\($0.offset)",
                wireID: $0.element,
                displayName: $0.element
            )
        }
        let projection = OhMyPiModelMenuProjector.project(inputs)
        let antigravity = try XCTUnwrap(
            projection.namespaceGroups.first { $0.namespace == "google-antigravity" }
        )
        let gemini37Groups = antigravity.modelGroups.filter {
            $0.allLeaves.contains { $0.wireID.hasPrefix("google-antigravity/gemini-3.7-flash") }
        }

        XCTAssertEqual(gemini37Groups.map(\.title), ["gemini-3.7-flash", "gemini-3.7-flash-tiered"])
        XCTAssertTrue(gemini37Groups.allSatisfy { !$0.isFamily })
        XCTAssertTrue(gemini37Groups.flatMap(\.allLeaves).allSatisfy { $0.effort == nil })
        XCTAssertEqual(
            gemini37Groups.flatMap(\.allLeaves).map(\.wireID),
            expectedWireIDs
        )
    }

    func testProjectorEnforcesAdversarialParsingCorroborationAndStableOrdering() throws {
        let wireIDs = [
            "root-high",
            "NS/foo-low",
            "ns/foo-high",
            "ns/folder/model-low",
            "ns/folder/model-high",
            "ns/bare",
            "ns/bare-low",
            "ns/pair",
            "ns/pair-fast",
            "ns/order-low-fast",
            "ns/order-fast-high",
            "ns/case-LoW",
            "ns/case-HIGH",
            "ns/dup-high",
            "ns/dup-HIGH",
            "ns/single-high",
            "ns/single-fast",
            "ns/grok-code-fast-1",
            "ns/free-high:free",
            "ns/model-(high)",
            "ns/auto-auto"
        ]
        let inputs = wireIDs.enumerated().map {
            OhMyPiModelMenuProjector.Input(
                sourceID: "id-\($0.offset)",
                wireID: $0.element,
                displayName: "same display"
            )
        }

        let projection = OhMyPiModelMenuProjector.project(inputs)
        XCTAssertEqual(projection.rootLeaves.map(\.wireID), ["root-high"])
        XCTAssertEqual(projection.namespaceGroups.map(\.namespace), ["NS", "ns"])

        let lowercase = try XCTUnwrap(projection.namespaceGroups.first { $0.namespace == "ns" })
        let nested = try XCTUnwrap(lowercase.modelGroups.first { $0.title == "folder/model" })
        XCTAssertTrue(nested.isFamily)
        XCTAssertEqual(nested.normalLeaves.map(\.title), ["Low", "High"])

        XCTAssertTrue(try XCTUnwrap(lowercase.modelGroups.first { $0.title == "bare" }).isFamily)
        let pair = try XCTUnwrap(lowercase.modelGroups.first { $0.title == "pair" })
        XCTAssertTrue(pair.isFamily)
        XCTAssertEqual(pair.normalLeaves.map(\.title), ["Default"])
        XCTAssertEqual(pair.fastLeaves.map(\.title), ["Default"])

        let order = try XCTUnwrap(lowercase.modelGroups.first { $0.title == "order" })
        XCTAssertTrue(order.isFamily)
        XCTAssertEqual(order.fastLeaves.map(\.title), ["Low", "High"])

        let mixedCase = try XCTUnwrap(lowercase.modelGroups.first { $0.title == "case" })
        XCTAssertTrue(mixedCase.isFamily)
        XCTAssertEqual(mixedCase.normalLeaves.map(\.title), ["Low", "High"])

        let duplicateLeaves = lowercase.modelGroups
            .filter { !$0.isFamily }
            .flatMap(\.allLeaves)
            .filter { $0.wireID == "ns/dup-high" || $0.wireID == "ns/dup-HIGH" }
        XCTAssertEqual(duplicateLeaves.count, 2)
        XCTAssertEqual(
            Set(lowercase.modelGroups.filter { !$0.isFamily }.flatMap(\.allLeaves).map(\.wireID)),
            Set([
                "ns/dup-high",
                "ns/dup-HIGH",
                "ns/single-high",
                "ns/single-fast",
                "ns/grok-code-fast-1",
                "ns/free-high:free",
                "ns/model-(high)",
                "ns/auto-auto",
                "ns/foo-high"
            ])
        )

        let reversed = OhMyPiModelMenuProjector.project(Array(inputs.reversed()))
        XCTAssertEqual(reversed, projection)
    }

    func testPerLeafThinkingEligibilitySurvivesFamilyDriftAndPinsSuffixAmbiguity() throws {
        let base = "cursor/gpt-5.2"
        let fast = "cursor/gpt-5.2-fast"
        let high = "cursor/gpt-5.2-high"
        let highFast = "cursor/gpt-5.2-high-fast"
        let purePair = [base, fast]
        let expanded = [base, fast, high, highFast]

        for wireIDs in [purePair, expanded] {
            let options = wireIDs.map {
                AgentModelOption(
                    rawValue: $0,
                    displayName: $0,
                    description: nil,
                    isDefault: false
                )
            }
            let projection = OhMyPiModelMenuProjector.project(options.map {
                .init(sourceID: $0.rawValue, wireID: $0.rawValue, displayName: $0.displayName)
            })
            let leavesByWireID = Dictionary(uniqueKeysWithValues: projection.allLeaves.map { ($0.wireID, $0) })
            XCTAssertTrue(try XCTUnwrap(leavesByWireID[base]).allowsThinkingAccessory)
            XCTAssertTrue(try XCTUnwrap(leavesByWireID[fast]).allowsThinkingAccessory)

            let snapshot = ACPDiscoveredSessionModels(options: options, currentModelRaw: base)
            XCTAssertTrue(OhMyPiThinkingExecutionEligibility.allowsAssignment(for: base, snapshot: snapshot))
            XCTAssertTrue(OhMyPiThinkingExecutionEligibility.allowsAssignment(for: fast, snapshot: snapshot))
            if wireIDs == expanded {
                XCTAssertFalse(try XCTUnwrap(leavesByWireID[high]).allowsThinkingAccessory)
                XCTAssertFalse(try XCTUnwrap(leavesByWireID[highFast]).allowsThinkingAccessory)
                XCTAssertFalse(OhMyPiThinkingExecutionEligibility.allowsAssignment(for: high, snapshot: snapshot))
                XCTAssertFalse(OhMyPiThinkingExecutionEligibility.allowsAssignment(for: highFast, snapshot: snapshot))
            }
        }

        let standalone = OhMyPiModelMenuProjector.project([
            .init(sourceID: "standalone", wireID: "provider/model-high", displayName: "Model High")
        ])
        XCTAssertTrue(try XCTUnwrap(standalone.allLeaves.first).allowsThinkingAccessory)

        let corroborated = OhMyPiModelMenuProjector.project([
            .init(sourceID: "low", wireID: "provider/model-low", displayName: "Model Low"),
            .init(sourceID: "high", wireID: "provider/model-high", displayName: "Model High")
        ])
        let corroboratedHigh = try XCTUnwrap(corroborated.allLeaves.first { $0.wireID == "provider/model-high" })
        XCTAssertEqual(corroboratedHigh.effort, .high)
        XCTAssertFalse(corroboratedHigh.allowsThinkingAccessory)
    }

    func testProjectorMeetsBoundedStressBudget() {
        let inputs = (0 ..< 5000).flatMap { index in
            [
                OhMyPiModelMenuProjector.Input(
                    sourceID: "low-\(index)",
                    wireID: "ns/model-\(index)-low",
                    displayName: "Low \(index)"
                ),
                OhMyPiModelMenuProjector.Input(
                    sourceID: "high-\(index)",
                    wireID: "ns/model-\(index)-high",
                    displayName: "High \(index)"
                )
            ]
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let projection = OhMyPiModelMenuProjector.project(inputs)
            XCTAssertEqual(projection.allLeaves.count, 10000)
            XCTAssertEqual(projection.namespaceGroups.first?.modelGroups.count, 5000)
        }
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    private func fixtureWireIDs(named fixtureName: String = "models-17.3.4.json") throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentMode/Fixtures/OhMyPiACP/\(fixtureName)")
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    }

    private func multiset(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private func performAllActions(in items: [StableMenuItem]) {
        for item in items {
            if let children = item.submenuItems {
                performAllActions(in: children)
            } else {
                _ = item.performActionForTesting()
            }
        }
    }
}
