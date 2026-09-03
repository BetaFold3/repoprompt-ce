import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexGoalSupportDefaultTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetTestingOverrides()
    }

    override func tearDown() {
        resetTestingOverrides()
        super.tearDown()
    }

    func testMissingUserDefaultsGoalKeyDefaultsEnabled() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: "enableCodexGoalSupport"))
        XCTAssertTrue(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsGoalFalseDisablesSupport() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_GOALS")
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: "enableCodexGoalSupport")

        XCTAssertFalse(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsGoalTrueEnablesSupport() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "enableCodexGoalSupport")

        XCTAssertTrue(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testMissingUserDefaultsComputerUseKeyDefaultsDisabled() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_COMPUTER_USE")
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: "enableCodexComputerUse"))
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsComputerUseTrueEnablesWorkflow() throws {
        let defaults = try makeIsolatedDefaults()
        CodexComputerUseWorkflow.setEnabled(true, defaults: defaults)

        XCTAssertTrue(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsComputerUseFalseDisablesWorkflow() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_COMPUTER_USE")
        let defaults = try makeIsolatedDefaults()
        CodexComputerUseWorkflow.setEnabled(false, defaults: defaults)

        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
    }

    func testMissingUserDefaultsReasoningSummariesKeyDefaultsDisabled() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: CodexReasoningSummaries.defaultsKey))
        XCTAssertFalse(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsReasoningSummariesTrueEnablesSummaries() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: CodexReasoningSummaries.defaultsKey)

        XCTAssertTrue(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsReasoningSummariesFalseDisablesSummaries() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: CodexReasoningSummaries.defaultsKey)

        XCTAssertFalse(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testMissingGlobalSettingsGoalScalarDefaultsEnabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertTrue(store.codexGoalSupportEnabled())
    }

    func testExplicitGlobalSettingsGoalFalseDisablesSupport() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_GOALS")
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexGoalSupportEnabled: false))
        ))

        XCTAssertFalse(store.codexGoalSupportEnabled())
    }

    func testExplicitGlobalSettingsGoalTrueEnablesSupport() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexGoalSupportEnabled: true))
        ))

        XCTAssertTrue(store.codexGoalSupportEnabled())
    }

    func testMissingGlobalSettingsComputerUseScalarDefaultsDisabled() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_COMPUTER_USE")
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertFalse(store.codexComputerUseEnabled())
    }

    func testExplicitGlobalSettingsComputerUseTrueEnablesWorkflow() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexComputerUseEnabled: true))
        ))

        XCTAssertTrue(store.codexComputerUseEnabled())
    }

    func testExplicitGlobalSettingsComputerUseFalseDisablesWorkflow() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_COMPUTER_USE")
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexComputerUseEnabled: false))
        ))

        XCTAssertFalse(store.codexComputerUseEnabled())
    }

    func testComputerUseNotificationPostsOnlyOnEffectiveChange() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_COMPUTER_USE")
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))
        let notification = XCTNSNotificationExpectation(
            name: .codexComputerUseDidChange,
            object: nil,
            notificationCenter: .default
        )
        notification.expectedFulfillmentCount = 1
        notification.assertForOverFulfill = true

        store.setCodexComputerUseEnabled(false, commit: false)
        store.setCodexComputerUseEnabled(true, commit: false)
        store.setCodexComputerUseEnabled(true, commit: false)

        wait(for: [notification], timeout: 0.1)
    }

    func testSafeManagedComputerUseIsRejectedBeforeDispatch() {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                fatalError("Controller creation is not expected for availability validation.")
            }
        )
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.permissionProfile = .mcpSafeDefaults

        XCTAssertEqual(
            viewModel.test_codexCoordinator.nativeSlashCommandAvailabilityMessage(
                .computerUse,
                session: session
            ),
            CodexComputerUseWorkflow.safeManagedDisabledMessage
        )

        #if DEBUG
            CodexComputerUseWorkflow.setEnabledForTesting(true)
            defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
            session.permissionProfile = .userConfigured
            XCTAssertNil(
                viewModel.test_codexCoordinator.nativeSlashCommandAvailabilityMessage(
                    .computerUse,
                    session: session
                )
            )
        #endif
    }

    func testMissingGlobalSettingsReasoningSummariesScalarDefaultsDisabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testExplicitGlobalSettingsReasoningSummariesTrueEnablesSummaries() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexReasoningSummariesEnabled: true))
        ))

        XCTAssertTrue(store.codexReasoningSummariesEnabled())
    }

    func testExplicitGlobalSettingsReasoningSummariesFalseDisablesSummaries() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexReasoningSummariesEnabled: false))
        ))

        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CodexGoalSupportDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(document: GlobalSettingsDocument) throws -> GlobalSettingsStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexGoalSupportDefaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(document)
        return try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: fileStore
        )
    }

    private func skipIfEnvironmentFlagEnabled(_ key: String) throws {
        let rawValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let rawValue, ["1", "true", "yes", "on"].contains(rawValue) {
            throw XCTSkip("\(key) force-enables this feature in the current environment.")
        }
    }

    private func resetTestingOverrides() {
        #if DEBUG
            CodexGoalSupport.setEnabledForTesting(nil)
            CodexComputerUseWorkflow.setEnabledForTesting(nil)
        #endif
    }
}
