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
}
