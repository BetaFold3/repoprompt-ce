import Foundation
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class ClaudePromptCacheRetentionResolverTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUserOneHourSettingRequiresExactValue() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settings = home.appendingPathComponent(".claude/settings.json")
        try writeSettings(settings, promptCacheTTL: " 1h ")

        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)

        try writeSettings(settings, promptCacheTTL: "1h")
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .extended)
    }

    func testMissingConfigurationResolvesStandard() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertEqual(
            resolve(environment: ["HOME": root.appendingPathComponent("missing-home").path]),
            .standard
        )
    }

    func testClaudeConfigDirectoryReplacesHomeUserSettings() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDirectory = root.appendingPathComponent("custom-claude", isDirectory: true)
        try writeSettings(home.appendingPathComponent(".claude/settings.json"), promptCacheTTL: "1h")
        try writeSettings(configDirectory.appendingPathComponent("settings.json"), promptCacheTTL: "5m")

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CONFIG_DIR": configDirectory.path
            ]),
            .standard
        )
    }

    func testProjectLocalProjectAndUserSettingsFollowPrecedenceInBothDirections() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let userSettings = home.appendingPathComponent(".claude/settings.json")
        let projectSettings = project.appendingPathComponent(".claude/settings.json")
        let localSettings = project.appendingPathComponent(".claude/settings.local.json")

        try writeSettings(userSettings, promptCacheTTL: "5m")
        try writeSettings(projectSettings, promptCacheTTL: "5m")
        try writeSettings(localSettings, promptCacheTTL: "1h")
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .extended)

        try writeSettings(userSettings, promptCacheTTL: "1h")
        try writeSettings(projectSettings, promptCacheTTL: "1h")
        try writeSettings(localSettings, promptCacheTTL: "5m")
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .standard)

        try FileManager.default.removeItem(at: localSettings)
        try writeSettings(userSettings, promptCacheTTL: "5m")
        try writeSettings(projectSettings, promptCacheTTL: "1h")
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .extended)

        try writeSettings(userSettings, promptCacheTTL: "1h")
        try writeSettings(projectSettings, promptCacheTTL: "5m")
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .standard)
    }

    func testInvalidHigherPromptCacheSettingMasksLowerFile() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeSettings(home.appendingPathComponent(".claude/settings.json"), promptCacheTTL: "1h")
        try writeSettings(project.appendingPathComponent(".claude/settings.local.json"), promptCacheTTL: "1H")

        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .standard)
    }

    func testLaunchEnvironmentFiveMinuteTTLBeatsOneHourSetting() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(home.appendingPathComponent(".claude/settings.json"), promptCacheTTL: "1h")

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_PROMPT_CACHE_TTL": " 5m "
            ]),
            .standard
        )
    }

    func testLaunchEnvironmentOneHourTTLWithoutSettingResolvesExtended() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertEqual(
            resolve(environment: [
                "HOME": root.appendingPathComponent("home").path,
                "CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"
            ]),
            .extended
        )
    }

    func testSettingsEnvironmentOneHourTTLResolvesExtended() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            environment: ["CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"]
        )

        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .extended)
    }

    func testForceFiveMinuteFlagInLaunchOrSettingsEnvironmentResolvesStandard() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settings = home.appendingPathComponent(".claude/settings.json")
        try writeSettings(settings, promptCacheTTL: "1h")

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "FORCE_PROMPT_CACHING_5M": " YES "
            ]),
            .standard
        )

        try writeSettings(
            settings,
            promptCacheTTL: "1h",
            environment: ["FORCE_PROMPT_CACHING_5M": "on"]
        )
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)
    }

    func testEnableOneHourFlagResolvesExtendedAfterOtherEvidenceFallsThrough() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertEqual(
            resolve(environment: [
                "HOME": root.appendingPathComponent("home").path,
                "ENABLE_PROMPT_CACHING_1H": "TrUe"
            ]),
            .extended
        )
    }

    func testEnableFlagUsesHighestPrecedenceSettingsEnvironmentValue() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let userSettings = home.appendingPathComponent(".claude/settings.json")
        let localSettings = project.appendingPathComponent(".claude/settings.local.json")

        try writeSettings(userSettings, environment: ["ENABLE_PROMPT_CACHING_1H": "1"])
        try writeSettings(localSettings, environment: ["ENABLE_PROMPT_CACHING_1H": "0"])
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .standard)

        try writeSettings(userSettings, environment: ["ENABLE_PROMPT_CACHING_1H": "0"])
        try writeSettings(localSettings, environment: ["ENABLE_PROMPT_CACHING_1H": "1"])
        XCTAssertEqual(resolve(environment: ["HOME": home.path], workingDirectory: project.path), .extended)
    }

    func testLaunchAndSettingsEnableConflictResolvesStandard() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            environment: ["ENABLE_PROMPT_CACHING_1H": "0"]
        )

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "ENABLE_PROMPT_CACHING_1H": "1"
            ]),
            .standard
        )
    }

    func testLaunchOneHourTTLWithInvalidEffectiveSettingsTTLResolvesStandard() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            environment: ["CLAUDE_CODE_PROMPT_CACHE_TTL": "60m"]
        )

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"
            ]),
            .standard
        )
    }

    func testNonStringSettingsEnvironmentValuesAreConservative() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settings = home.appendingPathComponent(".claude/settings.json")

        try writeSettings(
            settings,
            promptCacheTTL: "1h",
            environment: ["FORCE_PROMPT_CACHING_5M": 0]
        )
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)

        try writeSettings(
            settings,
            promptCacheTTL: "1h",
            environment: ["FORCE_PROMPT_CACHING_5M": false]
        )
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)

        try writeSettings(
            settings,
            environment: ["ENABLE_PROMPT_CACHING_1H": 1]
        )
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)
    }

    func testLoweredLaunchIdleTimeoutDisablesExtendedRetention() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(home.appendingPathComponent(".claude/settings.json"), promptCacheTTL: "1h")

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "600000"
            ]),
            .standard
        )
        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "0"
            ]),
            .extended
        )
        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "3600000"
            ]),
            .extended
        )
        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "invalid"
            ]),
            .standard
        )
    }

    func testSettingsToolTimeoutRequiresStringAboveExtendedBudget() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h",
            environment: ["MCP_TOOL_TIMEOUT": "1000000"]
        )

        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)

        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h",
            environment: ["MCP_TOOL_TIMEOUT": 10_800_000]
        )
        XCTAssertEqual(resolve(environment: ["HOME": home.path]), .standard)
    }

    func testRepoPromptToolTimeoutOverridePermitsExtendedRetention() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h"
        )
        let toolTimeout = try XCTUnwrap(
            ClaudeCodeIntegrationConfiguration.processEnvironmentOverrides["MCP_TOOL_TIMEOUT"]
        )

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "MCP_TOOL_TIMEOUT": toolTimeout
            ]),
            .extended
        )
    }

    func testToolTimeoutBudgetBoundaryIsInclusive() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h"
        )
        let thresholdSeconds = MCPTimeoutPolicy.agentLifecycleClaudeExtendedCacheAutomaticWaitSeconds
            + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
            + MCPTimeoutPolicy.agentLifecycleClaudeHostPreWaitBudgetSeconds
        let thresholdMilliseconds = Int(thresholdSeconds * 1000)

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "MCP_TOOL_TIMEOUT": String(thresholdMilliseconds)
            ]),
            .extended
        )
        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "MCP_TOOL_TIMEOUT": String(thresholdMilliseconds - 1)
            ]),
            .standard
        )
    }

    func testAllInvalidTTLEnvironmentValuesFallThroughToPromptSetting() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h",
            environment: ["CLAUDE_CODE_PROMPT_CACHE_TTL": "60m"]
        )

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_PROMPT_CACHE_TTL": "2h"
            ]),
            .extended
        )
    }

    func testLaunchAndSettingsOneHourTTLsResolveExtended() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            environment: ["CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"]
        )

        XCTAssertEqual(
            resolve(environment: [
                "HOME": home.path,
                "CLAUDE_CODE_PROMPT_CACHE_TTL": "1h"
            ]),
            .extended
        )
    }

    func testHigherFalsyForceFlagMasksLowerTruthyForceFlag() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeSettings(
            home.appendingPathComponent(".claude/settings.json"),
            promptCacheTTL: "1h",
            environment: ["FORCE_PROMPT_CACHING_5M": "1"]
        )
        try writeSettings(
            project.appendingPathComponent(".claude/settings.local.json"),
            environment: ["FORCE_PROMPT_CACHING_5M": "0"]
        )

        XCTAssertEqual(
            resolve(environment: ["HOME": home.path], workingDirectory: project.path),
            .extended
        )
    }

    func testManagedFiveMinuteSettingMasksUserOneHourSetting() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managed = root.appendingPathComponent("managed-settings.json")
        try writeSettings(home.appendingPathComponent(".claude/settings.json"), promptCacheTTL: "1h")
        try writeSettings(managed, promptCacheTTL: "5m")

        XCTAssertEqual(
            ClaudePromptCacheRetentionResolver.resolve(
                launchEnvironment: ["HOME": home.path],
                workingDirectory: nil,
                managedSettingsURL: managed
            ),
            .standard
        )
    }

    private func resolve(
        environment: [String: String],
        workingDirectory: String? = nil
    ) -> ClaudePromptCacheRetentionResolver.Retention {
        ClaudePromptCacheRetentionResolver.resolve(
            launchEnvironment: environment,
            workingDirectory: workingDirectory,
            managedSettingsURL: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudePromptCacheRetentionResolverTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeSettings(
        _ url: URL,
        promptCacheTTL: Any? = nil,
        environment: [String: Any] = [:]
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = [:]
        if let promptCacheTTL {
            object["promptCacheTtl"] = promptCacheTTL
        }
        if !environment.isEmpty {
            object["env"] = environment
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
