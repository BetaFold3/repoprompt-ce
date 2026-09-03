import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceAgentModeSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetComputerUseTestingOverride()
    }

    override func tearDown() {
        resetComputerUseTestingOverride()
        super.tearDown()
    }

    func testCodexReasoningSummariesSettingListsReadsAndWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())

        let setFalse = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertEqual(setFalse.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setFalse.objectValue?["new_value"]?.boolValue, false)
        XCTAssertEqual(setFalse.objectValue?["changed"]?.boolValue, true)
        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testCodexComputerUseSettingListsReadsAndWrites() async throws {
        let environmentValue = ProcessInfo.processInfo.environment["RP_CODEX_COMPUTER_USE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let environmentValue, ["1", "true", "yes", "on"].contains(environmentValue) {
            throw XCTSkip("RP_CODEX_COMPUTER_USE force-enables computer use in the current environment.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_computer_use_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("agent_mode"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(store.codexComputerUseEnabled())

        let setFalse = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertEqual(setFalse.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setFalse.objectValue?["new_value"]?.boolValue, false)
        XCTAssertEqual(setFalse.objectValue?["changed"]?.boolValue, true)
        XCTAssertFalse(store.codexComputerUseEnabled())
    }

    func testContextBuilderAgentAllowedValuesAndExplicitOhMyPiSelectionRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let providerID = ACPProviderID.ohMyPi
        let modelRaw = "google-antigravity/gemini-3.6-flash"
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: providerID) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: modelRaw,
                    displayName: "Gemini 3.6 Flash",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: modelRaw
            ),
            for: providerID
        ))

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("context_builder"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let agent = try XCTUnwrap(
            settings.first { $0.objectValue?["key"]?.stringValue == "context_builder.agent" }
        )
        let allowedValues = try XCTUnwrap(agent.objectValue?["allowed_values"]?.arrayValue)
            .compactMap(\.stringValue)

        XCTAssertTrue(allowedValues.contains(AgentProviderKind.openCode.rawValue))
        XCTAssertTrue(allowedValues.contains(AgentProviderKind.cursor.rawValue))
        XCTAssertTrue(allowedValues.contains(AgentProviderKind.ohMyPi.rawValue))
        XCTAssertFalse(AgentModelCatalog.AvailabilityContext.current.ohMyPiAvailable)

        let setAgent = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.agent"),
            "value": .string(AgentProviderKind.ohMyPi.rawValue)
        ])
        XCTAssertEqual(setAgent.objectValue?["new_value"]?.stringValue, AgentProviderKind.ohMyPi.rawValue)
        XCTAssertEqual(store.globalContextBuilderAgentSelection().agentRaw, AgentProviderKind.ohMyPi.rawValue)

        let setModel = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.model"),
            "value": .string(modelRaw)
        ])
        XCTAssertEqual(setModel.objectValue?["new_value"]?.stringValue, modelRaw)
        XCTAssertEqual(store.globalContextBuilderAgentSelection().agentRaw, AgentProviderKind.ohMyPi.rawValue)
        XCTAssertEqual(store.globalContextBuilderAgentSelection().modelRaw, modelRaw)
    }

    func testOhMyPiModelCandidatesRequireEffectiveAvailabilityAndStayProviderFiltered() throws {
        let providerID = ACPProviderID.ohMyPi
        let modelRaw = "cursor/gpt-5.6-sol-max-fast"
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: providerID) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: modelRaw,
                    displayName: "OMP Cursor Fast",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: modelRaw
            ),
            for: providerID
        ))

        let disconnected = try AppSettingsMCPService.aiModelRawCandidateValuesForTesting(
            agentFilter: .ohMyPi,
            effectiveOhMyPiAvailable: false
        )
        XCTAssertTrue(disconnected.isEmpty)

        let available = try AppSettingsMCPService.aiModelRawCandidateValuesForTesting(
            agentFilter: .ohMyPi,
            effectiveOhMyPiAvailable: true
        )
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(available[0].objectValue?["value"]?.stringValue, "ohmypi_custom_\(modelRaw)")
        XCTAssertEqual(available[0].objectValue?["provider"]?.stringValue, "ohMyPi")
        XCTAssertTrue(available.allSatisfy {
            $0.objectValue?["provider"]?.stringValue == "ohMyPi"
        })

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.OMPAvailability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(OhMyPiConnectionAvailability.isEffectivelyConnected(
            userDefaults: defaults,
            debugOverride: false
        ))
        XCTAssertTrue(OhMyPiConnectionAvailability.isEffectivelyConnected(
            userDefaults: defaults,
            debugOverride: true
        ))
        defaults.set(true, forKey: "OhMyPiCLIConnected")
        XCTAssertTrue(OhMyPiConnectionAvailability.isEffectivelyConnected(
            userDefaults: defaults,
            debugOverride: false
        ))
    }

    func testSetWarnsWhenGlobalSettingsPersistenceIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(futureJSON.utf8).write(to: fileURL)

        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(onDiskVersion: 999, supportedVersion: GlobalSettingsDocument.currentSchemaVersion)
        )

        let service = AppSettingsMCPService(store: store)
        let key = "agent_mode.codex_reasoning_summaries_enabled"
        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])

        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(result.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_blocked"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_block_reason"]?.stringValue, "unsupported_future_schema")
        XCTAssertTrue(result.objectValue?["persistence_warning"]?.stringValue?.contains("will not persist") ?? false)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), futureJSON)
    }

    func testSetReportsAutomaticSchemaNormalizationFailureWithoutTouchingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let falseV4JSON = #"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        try Data(falseV4JSON.utf8).write(to: fileURL)
        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: fileURL,
                normalizationBackupWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
        let service = AppSettingsMCPService(store: store)

        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("agent_mode.codex_reasoning_summaries_enabled"),
            "value": .bool(true)
        ])

        XCTAssertEqual(
            result.objectValue?["persistence_block_reason"]?.stringValue,
            "automatic_schema_normalization_failed"
        )
        let warning = try XCTUnwrap(result.objectValue?["persistence_warning"]?.stringValue)
        XCTAssertTrue(warning.contains("applied in memory"))
        XCTAssertTrue(warning.contains("original file is preserved"))
        XCTAssertTrue(warning.contains("explicit recovery"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), falseV4JSON)
    }

    private func resetComputerUseTestingOverride() {
        #if DEBUG
            CodexComputerUseWorkflow.setEnabledForTesting(nil)
        #endif
    }
}
