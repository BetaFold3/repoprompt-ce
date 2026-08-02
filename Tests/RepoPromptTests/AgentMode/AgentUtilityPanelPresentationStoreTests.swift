import Foundation
@testable import RepoPromptApp
import XCTest

/// Persistence split for the right utility panel.
///
/// The design record draws a deliberate line: the preferred width is a durable preference, while
/// visibility belongs to one window and one session. This store owns those two window-level
/// concerns only — what the panel *shows* is per tab and is covered by
/// `AgentUtilityPanelTabStateTests` and `AgentUtilityPanelUIStoreTests`. Each test drives an
/// isolated settings store backed by a temporary file and a private `UserDefaults` suite, so
/// nothing here touches the developer's real settings document.
@MainActor
final class AgentUtilityPanelPresentationStoreTests: XCTestCase {
    private typealias Metrics = AgentUtilityPanelLayoutMetrics

    func testFreshWindowOpensHiddenAtTheDefaultWidth() throws {
        let harness = try makeHarness()

        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)

        XCTAssertFalse(store.isVisible)
        XCTAssertEqual(store.preferredWidth, Metrics.defaultPanelWidth)
    }

    func testCommittedWidthSurvivesIntoAFreshWindow() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)

        store.updatePreferredWidth(480, commit: true)

        XCTAssertEqual(store.preferredWidth, 480)
        XCTAssertEqual(try harness.persistedWidth(), 480)

        let reloadedSettings = harness.makeReloadedSettingsStore()
        let reloadedPanel = AgentUtilityPanelPresentationStore(settingsStore: reloadedSettings)
        XCTAssertEqual(reloadedPanel.preferredWidth, 480)
    }

    /// A drag publishes continuously but must not write the settings document on every frame.
    func testWidthUpdatesDuringADragAreNotWrittenUntilTheDragEnds() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)

        store.updatePreferredWidth(400, commit: false)
        store.updatePreferredWidth(430, commit: false)

        XCTAssertEqual(store.preferredWidth, 430)
        XCTAssertNil(try harness.persistedWidth(), "an in-flight drag should not write to disk")

        store.updatePreferredWidth(455, commit: true)

        XCTAssertEqual(store.preferredWidth, 455)
        XCTAssertEqual(try harness.persistedWidth(), 455)
    }

    func testOutOfRangeWidthsAreClampedBeforeTheyReachStorage() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)

        store.updatePreferredWidth(4000, commit: true)
        XCTAssertEqual(store.preferredWidth, Metrics.maximumPanelWidth)
        XCTAssertEqual(try harness.persistedWidth(), Double(Metrics.maximumPanelWidth))

        store.updatePreferredWidth(10, commit: true)
        XCTAssertEqual(store.preferredWidth, Metrics.minimumPanelWidth)
        XCTAssertEqual(try harness.persistedWidth(), Double(Metrics.minimumPanelWidth))
    }

    /// The settings document is user-editable, so a hand-written or corrupted value must not reach
    /// a SwiftUI frame.
    func testWidthWrittenOutOfBandIsClampedOnRead() throws {
        let harness = try makeHarness()
        try harness.writePersistedWidth(9999)

        let reloadedSettings = harness.makeReloadedSettingsStore()
        let store = AgentUtilityPanelPresentationStore(settingsStore: reloadedSettings)

        XCTAssertEqual(store.preferredWidth, Metrics.maximumPanelWidth)
    }

    func testResetRestoresTheDefaultWidthAndPersistsIt() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)
        store.updatePreferredWidth(520, commit: true)

        store.resetPreferredWidth()

        XCTAssertEqual(store.preferredWidth, Metrics.defaultPanelWidth)
        XCTAssertEqual(try harness.persistedWidth(), Double(Metrics.defaultPanelWidth))
    }

    func testVisibilityIsWindowLocalAndNeverPersisted() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)

        store.toggleVisibility()
        XCTAssertTrue(store.isVisible)

        // A second window on the same settings document opens hidden.
        let secondWindow = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)
        XCTAssertFalse(secondWindow.isVisible)

        // And a relaunch does not restore it.
        let reloadedSettings = harness.makeReloadedSettingsStore()
        XCTAssertFalse(AgentUtilityPanelPresentationStore(settingsStore: reloadedSettings).isVisible)

        store.toggleVisibility()
        XCTAssertFalse(store.isVisible)
    }

    /// Deep links reveal the panel without disturbing the width the user chose for this window.
    func testShowRevealsThePanelAndIsIdempotent() throws {
        let harness = try makeHarness()
        let store = AgentUtilityPanelPresentationStore(settingsStore: harness.settingsStore)
        store.updatePreferredWidth(430, commit: true)

        store.show()

        XCTAssertTrue(store.isVisible)
        XCTAssertEqual(store.preferredWidth, 430)

        store.show()
        XCTAssertTrue(store.isVisible, "a second deep link should leave an already-open panel open")

        store.hide()
        XCTAssertFalse(store.isVisible)
    }

    // MARK: - Harness

    private struct Harness {
        let settingsStore: GlobalSettingsStore
        let fileStore: GlobalSettingsFileStore
        let defaults: UserDefaults

        func persistedWidth() throws -> Double? {
            try fileStore.load().scalarPreferences?.ui?.agentUtilityPanelWidth
        }

        /// Writes directly through the file store, bypassing the settings accessor's write clamp,
        /// to model a user-edited settings document on the next launch.
        func writePersistedWidth(_ width: Double) throws {
            var document = try fileStore.load()
            var preferences = document.scalarPreferences ?? GlobalScalarPreferences()
            var ui = preferences.ui ?? GlobalScalarPreferences.UISettings()
            ui.agentUtilityPanelWidth = width
            preferences.ui = ui
            document.scalarPreferences = preferences
            try fileStore.save(document)
        }

        @MainActor
        func makeReloadedSettingsStore() -> GlobalSettingsStore {
            GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        }
    }

    private func makeHarness(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Harness {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentUtilityPanelPresentationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let suiteName = "AgentUtilityPanelPresentationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileStore = GlobalSettingsFileStore(
            fileURL: temporaryDirectory.appendingPathComponent("Settings/globalSettings.json")
        )
        return Harness(
            settingsStore: GlobalSettingsStore(defaults: defaults, fileStore: fileStore),
            fileStore: fileStore,
            defaults: defaults
        )
    }
}
