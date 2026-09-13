@testable import RepoPromptApp
import XCTest

@MainActor
final class AppQuitWarningPersistenceTests: XCTestCase {
    func testWarningDefaultsEnabledAndDisabledValueRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppQuitWarningPersistenceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "AppQuitWarningPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(store.warnBeforeQuit())

        store.setWarnBeforeQuit(false)

        let persisted = try fileStore.load()
        XCTAssertEqual(persisted.scalarPreferences?.ui?.warnBeforeQuit, false)

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(reloaded.warnBeforeQuit())
    }
}
