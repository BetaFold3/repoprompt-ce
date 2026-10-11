import Foundation
import RepoPromptShared

/// Resolves only explicit local evidence for the effective Claude Code main-conversation
/// prompt-cache retention at process launch. Blind spots include MDM/server-managed settings not
/// materialized at the managed-settings file path, wrapper scripts that change
/// `CLAUDE_CONFIG_DIR` after spawn, settings hot-reload after launch, and gateways or compatible
/// providers that may not honor the TTL. `.extended` means visible launch-time configuration explicitly
/// requests the one-hour main-conversation cache and visible MCP host timeouts permit the extended
/// automatic wait. Invalid visible launch/settings timeout values, or values below the extended wait plus
/// response margin and pre-wait budget, conservatively disable extended retention. Subscription defaults
/// are deliberately not inferred because billing state is unknowable, so absence resolves to `.standard`.
enum ClaudePromptCacheRetentionResolver {
    typealias Retention = MCPTimeoutPolicy.AgentLifecycleParentPromptCacheRetention

    static let defaultManagedSettingsURL = URL(
        fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"
    )

    private static let forceFiveMinuteKey = "FORCE_PROMPT_CACHING_5M"
    private static let cacheTTLKey = "CLAUDE_CODE_PROMPT_CACHE_TTL"
    private static let promptCacheTTLSettingKey = "promptCacheTtl"
    private static let enableOneHourKey = "ENABLE_PROMPT_CACHING_1H"
    private static let idleTimeoutKey = "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"
    private static let toolTimeoutKey = "MCP_TOOL_TIMEOUT"

    private enum EnvironmentValue {
        case string(String)
        case invalid

        var stringValue: String? {
            guard case let .string(value) = self else { return nil }
            return value
        }
    }

    private struct SettingsFile {
        let object: [String: Any]
        let environment: [String: Any]
    }

    static func resolve(
        launchEnvironment: [String: String],
        workingDirectory: String?,
        managedSettingsURL: URL? = defaultManagedSettingsURL,
        fileManager: FileManager = .default
    ) -> Retention {
        let settings = settingsURLs(
            launchEnvironment: launchEnvironment,
            workingDirectory: workingDirectory,
            managedSettingsURL: managedSettingsURL
        ).compactMap { settingsFile(at: $0, fileManager: fileManager) }

        let forceValues = presentEnvironmentValues(
            for: forceFiveMinuteKey,
            launchEnvironment: launchEnvironment,
            settings: settings
        )
        if forceValues.contains(where: potentiallyForcesFiveMinute) {
            return .standard
        }
        if hasInsufficientToolTimeout(
            launchEnvironment: launchEnvironment,
            settings: settings
        ) {
            return .standard
        }

        let ttlValues = presentEnvironmentValues(
            for: cacheTTLKey,
            launchEnvironment: launchEnvironment,
            settings: settings
        )
        if !ttlValues.isEmpty {
            let resolvedTTLValues = ttlValues.map { validTTL($0.stringValue) }
            if resolvedTTLValues.contains(.standard) {
                return .standard
            }
            if resolvedTTLValues.allSatisfy({ $0 == .extended }) {
                return .extended
            }
            if resolvedTTLValues.contains(.extended) {
                return .standard
            }
        }

        if let highestSetting = settings.first(where: { $0.object.keys.contains(promptCacheTTLSettingKey) }),
           let rawValue = highestSetting.object[promptCacheTTLSettingKey] as? String,
           let retention = validTTL(rawValue)
        {
            return retention
        }

        let enableValues = presentEnvironmentValues(
            for: enableOneHourKey,
            launchEnvironment: launchEnvironment,
            settings: settings
        )
        if !enableValues.isEmpty, enableValues.allSatisfy(truthy) {
            return .extended
        }

        return .standard
    }

    private static func settingsURLs(
        launchEnvironment: [String: String],
        workingDirectory: String?,
        managedSettingsURL: URL?
    ) -> [URL] {
        var urls: [URL] = []
        if let managedSettingsURL {
            urls.append(managedSettingsURL)
        }
        if let projectDirectory = nonEmptyURL(path: workingDirectory) {
            urls.append(projectDirectory.appendingPathComponent(".claude/settings.local.json"))
            urls.append(projectDirectory.appendingPathComponent(".claude/settings.json"))
        }
        if let configDirectory = nonEmptyURL(path: launchEnvironment["CLAUDE_CONFIG_DIR"]) {
            urls.append(configDirectory.appendingPathComponent("settings.json"))
        } else if let home = nonEmptyURL(path: launchEnvironment["HOME"]) {
            urls.append(home.appendingPathComponent(".claude/settings.json"))
        }
        return urls
    }

    private static func settingsFile(at url: URL, fileManager: FileManager) -> SettingsFile? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let environment = object["env"] as? [String: Any] ?? [:]
        return SettingsFile(object: object, environment: environment)
    }

    private static func environmentValue(_ value: Any) -> EnvironmentValue {
        guard let string = value as? String else { return .invalid }
        return .string(string)
    }

    private static func presentEnvironmentValues(
        for key: String,
        launchEnvironment: [String: String],
        settings: [SettingsFile]
    ) -> [EnvironmentValue] {
        var values: [EnvironmentValue] = []
        if let launchValue = launchEnvironment[key] {
            values.append(.string(launchValue))
        }
        for settingsFile in settings {
            if let settingsValue = settingsFile.environment[key] {
                values.append(environmentValue(settingsValue))
                break
            }
        }
        return values
    }

    private static func hasInsufficientToolTimeout(
        launchEnvironment: [String: String],
        settings: [SettingsFile]
    ) -> Bool {
        let requiredSeconds = MCPTimeoutPolicy.agentLifecycleClaudeExtendedCacheAutomaticWaitSeconds
            + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
            + MCPTimeoutPolicy.agentLifecycleClaudeHostPreWaitBudgetSeconds
        let requiredMilliseconds = Int64(requiredSeconds * 1000)
        for key in [idleTimeoutKey, toolTimeoutKey] {
            let values = presentEnvironmentValues(
                for: key,
                launchEnvironment: launchEnvironment,
                settings: settings
            )
            for value in values {
                guard let rawValue = value.stringValue,
                      let milliseconds = Int64(
                          rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                      )
                else {
                    return true
                }
                if key == idleTimeoutKey, milliseconds == 0 {
                    continue
                }
                guard milliseconds > 0, milliseconds >= requiredMilliseconds else {
                    return true
                }
            }
        }
        return false
    }

    private static func validTTL(_ rawValue: String?) -> Retention? {
        guard let rawValue else { return nil }
        if rawValue == "1h" {
            return .extended
        }
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines) == "5m" {
            return .standard
        }
        return nil
    }

    private static func potentiallyForcesFiveMinute(_ value: EnvironmentValue) -> Bool {
        guard value.stringValue != nil else { return true }
        return truthy(value)
    }

    private static func truthy(_ value: EnvironmentValue) -> Bool {
        guard let rawValue = value.stringValue else { return false }
        return ["1", "true", "yes", "on"].contains(
            rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func nonEmptyURL(path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
