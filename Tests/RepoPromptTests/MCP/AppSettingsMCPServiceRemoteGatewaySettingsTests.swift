import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppSettingsMCPServiceRemoteGatewaySettingsTests: XCTestCase {
    func testRemoteGatewaySettingListsGetsAndReconcilesChangedAndUnchangedSets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppSettingsMCPServiceRemoteGatewaySettingsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppSettingsMCPServiceRemoteGatewaySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        var reconciliationCount = 0
        let service = AppSettingsMCPService(
            store: store,
            scheduleRemoteGatewayReconciliation: { reconciliationCount += 1 }
        )
        let key = "mcp.remote_gateway_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("mcp"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["group"]?.stringValue, "mcp")
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["writable"]?.boolValue, true)
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)

        let remotePublicKeys = Set(settings.compactMap { setting -> String? in
            guard let candidate = setting.objectValue?["key"]?.stringValue else { return nil }
            let isRemoteKey = candidate.contains("remote_gateway")
                || candidate.contains("remote_control")
                || candidate.contains("pairing")
            return isRemoteKey ? candidate : nil
        })
        XCTAssertEqual(remotePublicKeys, Set([key]))

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let beforeChangedSet = reconciliationCount
        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["applied"]?.boolValue, true)
        XCTAssertTrue(store.mcpRemoteGatewayEnabled())
        XCTAssertEqual(reconciliationCount, beforeChangedSet + 1)

        let beforeUnchangedSet = reconciliationCount
        let setTrueAgain = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrueAgain.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(setTrueAgain.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setTrueAgain.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrueAgain.objectValue?["changed"]?.boolValue, false)
        XCTAssertEqual(setTrueAgain.objectValue?["applied"]?.boolValue, false)
        XCTAssertTrue(store.mcpRemoteGatewayEnabled())
        XCTAssertEqual(reconciliationCount, beforeUnchangedSet + 1)
    }

    func testRemoteGatewaySetPreservesBlockedPersistenceWarningAndReconciles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppSettingsMCPServiceRemoteGatewaySettingsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("globalSettings.json")
        let futureJSON = #"{"schemaVersion":999,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-05-20T00:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{}}"#
        let originalBytes = Data(futureJSON.utf8)
        try originalBytes.write(to: fileURL)

        let suiteName = "AppSettingsMCPServiceRemoteGatewaySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(
            store.persistenceBlockReason,
            .unsupportedFutureSchema(
                onDiskVersion: 999,
                supportedVersion: GlobalSettingsDocument.currentSchemaVersion
            )
        )

        var reconciliationCount = 0
        let service = AppSettingsMCPService(
            store: store,
            scheduleRemoteGatewayReconciliation: { reconciliationCount += 1 }
        )
        let key = "mcp.remote_gateway_enabled"
        let result = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])

        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(result.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(result.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["applied"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["persistence_blocked"]?.boolValue, true)
        XCTAssertEqual(
            result.objectValue?["persistence_block_reason"]?.stringValue,
            "unsupported_future_schema"
        )
        XCTAssertTrue(
            result.objectValue?["persistence_warning"]?.stringValue?.contains("will not persist") ?? false
        )
        XCTAssertTrue(store.mcpRemoteGatewayEnabled())
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(reconciliationCount, 1)
    }
}
