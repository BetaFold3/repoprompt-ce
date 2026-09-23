import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class PromptAgentAvailabilityRefreshTests: XCTestCase {
    func testSavingGLMSecretRefreshesAgentAvailability() async throws {
        let fixture = try makeAvailabilityFixture(glmConfigured: false)
        defer { fixture.cleanup() }

        let viewModel = makeViewModel(fixture: fixture)
        XCTAssertFalse(viewModel.agentAvailability.zaiConfigured)

        try await viewModel.saveCompatibleBackendSecret("zai-test-key", for: .glmZAI)

        XCTAssertTrue(viewModel.agentAvailability.zaiConfigured)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured(defaults: fixture.defaults))
    }

    func testLoadingPreconfiguredZAIKeyRefreshesAgentAvailability() async throws {
        let fixture = try makeAvailabilityFixture(glmConfigured: true)
        defer { fixture.cleanup() }

        let viewModel = makeViewModel(fixture: fixture)
        XCTAssertFalse(viewModel.agentAvailability.zaiConfigured)

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))

        XCTAssertTrue(viewModel.agentAvailability.zaiConfigured)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured(defaults: fixture.defaults))
    }

    func testPromptRefreshesAvailableAgentKindsWhenPreconfiguredZAIKeyLoadsWithStaleSecretPresenceMirror() async throws {
        let fixture = try makeAvailabilityFixture(glmConfigured: true)
        defer { fixture.cleanup() }

        let apiSettings = makeViewModel(fixture: fixture)
        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: 999,
            settingsManager: WindowSettingsManager(windowID: 999)
        )

        XCTAssertFalse(prompt.availableAgentKinds.contains(.claudeCodeGLM))

        apiSettings.compatibleBackendSecretPresence[.glmZAI] = true
        await apiSettings.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await drainMainQueue()

        XCTAssertTrue(apiSettings.agentAvailability.zaiConfigured)
        XCTAssertTrue(
            prompt.availableAgentKinds.contains(.claudeCodeGLM),
            "PromptViewModel should refresh IDE agent options even when the secret-presence mirror was already populated before startup key load."
        )
    }

    func testLateConstructedPromptViewModelSeesPreconfiguredZAIAvailability() async throws {
        let fixture = try makeAvailabilityFixture(glmConfigured: true)
        defer { fixture.cleanup() }

        let apiSettings = makeViewModel(fixture: fixture)
        await apiSettings.loadStoredData(accessMode: .nonInteractive(reason: .test))
        XCTAssertTrue(apiSettings.agentAvailability.zaiConfigured)

        // Simulates a window restored after the startup key load finished: the
        // replayed `agentAvailability` value must initialize the picker without
        // any further change event.
        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: 998,
            settingsManager: WindowSettingsManager(windowID: 998)
        )
        await drainMainQueue()

        XCTAssertTrue(
            prompt.availableAgentKinds.contains(.claudeCodeGLM),
            "A PromptViewModel constructed after startup key load should initialize Z.ai availability from the replayed value."
        )
    }

    private struct AvailabilityFixture {
        let suiteName: String
        let defaults: UserDefaults
        let secureService: SecureKeysService
        let backendStore: ClaudeCodeCompatibleBackendStore

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeAvailabilityFixture(glmConfigured: Bool) throws -> AvailabilityFixture {
        let suiteName = "PromptAgentAvailabilityRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [
            .zAIAPI: "zai-test-key"
        ]))
        let backendStore = ClaudeCodeCompatibleBackendStore(
            defaults: defaults,
            secureService: secureService
        )
        for id in ClaudeCodeCompatibleBackendID.allCases {
            backendStore.setConfigured(id == .glmZAI && glmConfigured, for: id)
        }
        return AvailabilityFixture(
            suiteName: suiteName,
            defaults: defaults,
            secureService: secureService,
            backendStore: backendStore
        )
    }

    private func makeViewModel(fixture: AvailabilityFixture) -> APISettingsViewModel {
        let keyManager = KeyManager(secureService: fixture.secureService)
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            compatibleBackendStore: fixture.backendStore
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1.0)
    }
}
