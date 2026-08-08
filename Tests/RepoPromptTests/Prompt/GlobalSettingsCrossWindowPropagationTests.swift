import Combine
import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class GlobalSettingsCrossWindowPropagationTests: XCTestCase {
    /// Changing the Oracle model in one window's PromptViewModel must update every other
    /// window's cached value, because all windows share one `GlobalSettingsStore`. Defect:
    /// window A showed "fable" while every other window kept "gpt-5.5" until the app restarted.
    func testOracleModelChangePropagatesAcrossWindows() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let windowA = makePromptViewModel(
            windowID: 1,
            store: fixture.settingsStore,
            promptStore: fixture.promptStore
        )
        let windowB = makePromptViewModel(
            windowID: 2,
            store: fixture.settingsStore,
            promptStore: fixture.promptStore
        )

        let baseline = windowB.planningModelName
        XCTAssertNotEqual(baseline, "sonnet", "test is only meaningful if B does not already hold sonnet")

        // Window A changes the Oracle model (writes through to the shared store).
        windowA.planningModelName = "sonnet"
        await drainMainQueue()

        XCTAssertEqual(
            windowB.planningModelName, "sonnet",
            "Oracle model change in one window must propagate to other windows live"
        )
    }

    /// The cross-window subscription must not feedback-loop: a single Oracle change re-seeds
    /// other windows but must not re-mutate the store (re-entrancy is guarded by
    /// `isSyncingSettings` and direct storage writes). Defect: a naive subscription could
    /// make every change cascade into unbounded store writes / UI churn.
    func testOraclePropagationDoesNotFeedbackLoop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = fixture.settingsStore
        let windowA = makePromptViewModel(
            windowID: 1,
            store: store,
            promptStore: fixture.promptStore
        )
        let windowB = makePromptViewModel(
            windowID: 2,
            store: store,
            promptStore: fixture.promptStore
        ) // retained additional observer

        var storeEmissions = 0
        let cancellable = store.objectWillChange.sink { _ in storeEmissions += 1 }
        defer { cancellable.cancel() }

        windowA.planningModelName = "sonnet"
        await drainMainQueue()
        await drainMainQueue()

        XCTAssertLessThan(storeEmissions, 5, "cross-window re-sync must not feedback-loop into store writes")
        XCTAssertEqual(windowA.planningModelName, "sonnet")
        XCTAssertEqual(windowB.planningModelName, "sonnet")
    }

    func testContextBuilderPickerExplicitCommitPersistsDisplayedRuntimeFallback() async throws {
        let previousCodexConnected = UserDefaults.standard.object(forKey: "CodexCLIConnected")
        defer {
            if let previousCodexConnected {
                UserDefaults.standard.set(previousCodexConnected, forKey: "CodexCLIConnected")
            } else {
                UserDefaults.standard.removeObject(forKey: "CodexCLIConnected")
            }
        }
        UserDefaults.standard.set(true, forKey: "CodexCLIConnected")

        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = fixture.settingsStore
        let prompt = makePromptViewModel(
            windowID: 1,
            store: store,
            promptStore: fixture.promptStore
        )
        prompt.apiSettingsViewModel?.test_completeContextBuilderProviderValidation(
            verifiedProviders: [.codexExec]
        )
        await drainMainQueue()

        prompt.contextBuilderAgent = .codexExec
        prompt.selectContextBuilderAgentModel(rawModel: AgentModel.gpt55CodexLow.rawValue)
        prompt.commitContextBuilderSettings()

        let persisted = store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(persisted.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    // NOTE: Context Builder agent propagation is exercised compositionally — the store-side
    // publish is covered by SettingsJSONOnlyPersistenceTests.testGlobalDefaultsSettersPublishObjectWillChange
    // and the VM-side subscription + re-seed is covered by testOracleModelChangePropagatesAcrossWindows
    // above (same `objectWillChange` subscription, same `syncGlobalDerivedSettingsFromStore`). The
    // agent-kind resolution itself is availability-gated and covered by ContextBuilderModelStartupSelectionTests.

    // MARK: - Helpers

    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String
        let settingsStore: GlobalSettingsStore
        let promptStore: PromptStorage

        @MainActor
        func cleanup() {
            promptStore.waitForPendingWrites()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossWindowPropagation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsFileURL = directory.appendingPathComponent("Settings/globalSettings.json")
        let promptFileURL = directory.appendingPathComponent("Prompts/SavedPrompts.json")
        let suiteName = "CrossWindowPropagation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(
            directory: directory,
            defaults: defaults,
            suiteName: suiteName,
            settingsStore: GlobalSettingsStore(
                defaults: defaults,
                fileStore: GlobalSettingsFileStore(fileURL: settingsFileURL)
            ),
            promptStore: PromptStorage(fileURL: promptFileURL)
        )
    }

    private func makePromptViewModel(
        windowID: Int,
        store: GlobalSettingsStore,
        promptStore: PromptStorage
    ) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [:]))
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID, store: store),
            promptLibraryStore: promptStore
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1.0)
    }
}
