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

    private func fixtureWireIDs() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentMode/Fixtures/OhMyPiACP/models-17.3.4.json")
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
