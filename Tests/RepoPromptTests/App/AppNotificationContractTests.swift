@testable import RepoPromptApp
import XCTest

@MainActor
final class AppNotificationContractTests: XCTestCase {
    func testToolbarReplacementNotificationsKeepStableRawValues() {
        XCTAssertEqual(
            Notification.Name.showRecommendationWizard.rawValue,
            "showRecommendationWizard"
        )
        XCTAssertEqual(
            Notification.Name.showMCPSettingsTab.rawValue,
            "showMCPSettingsTab"
        )
    }

    func testOnboardingMCPActionPostsSettingsNotificationForTargetWindow() throws {
        let fixture = try makeOnboardingViewModel()
        let expectedWindowID = 731
        let notification = XCTNSNotificationExpectation(
            name: .showMCPSettingsTab,
            object: nil,
            notificationCenter: .default
        )
        notification.handler = { note in
            note.userInfo?["windowID"] as? Int == expectedWindowID
        }

        fixture.openMCPSettings(windowID: expectedWindowID)

        wait(for: [notification], timeout: 1)
    }

    private func makeOnboardingViewModel() throws -> AgentOnboardingWizardViewModel {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppNotificationContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "AppNotificationContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settingsStore = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
            )
        )
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let engine = AutoRecommendationEngine(
            settingsStore: settingsStore,
            profileSettingsManager: settingsStore,
            apiSettingsViewModel: apiSettings
        )

        return AgentOnboardingWizardViewModel(
            engine: engine,
            apiSettingsViewModel: apiSettings
        )
    }
}
