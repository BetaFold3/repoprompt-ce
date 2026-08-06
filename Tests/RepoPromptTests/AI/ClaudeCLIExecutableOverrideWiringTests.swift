import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ClaudeCLIExecutableOverrideWiringTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "ClaudeCLIExecutableOverrideWiringTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIExecutableOverrideWiringTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        suiteName = nil
        root = nil
    }

    func testConfiguredOverrideFlowsThroughBothFactoriesAndAllRuntimeVariants() throws {
        let configuredPath = root.appendingPathComponent("configured-claude").path
        defaults.set(configuredPath, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))

        for variant in runtimeVariants {
            let agentMode = try ClaudeCodeAgentConfig.agentMode(
                runtimeVariant: variant,
                defaults: defaults
            )
            let discovery = try ClaudeCodeAgentConfig.discovery(
                runtimeVariant: variant,
                defaults: defaults
            )

            for config in [agentMode, discovery] {
                XCTAssertEqual(config.commandName, configuredPath, "variant: \(variant)")
                XCTAssertEqual(config.commandSelection, .configuredExactPath(configuredPath), "variant: \(variant)")
                XCTAssertEqual(
                    ClaudeCompatiblePluginBridge.runtimeConfig(from: config).commandName,
                    configuredPath,
                    "variant: \(variant)"
                )
            }

            let processConfig = AgentRuntimeProviderService.claudeProcessConfiguration(for: discovery)
            XCTAssertEqual(processConfig.command, configuredPath, "variant: \(variant)")
            XCTAssertEqual(processConfig.commandSelection, .configuredExactPath(configuredPath), "variant: \(variant)")
        }
    }

    func testProgrammaticCommandWinsOverConfiguredAndCorruptStoredValues() throws {
        let key = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        for storedValue in [root.appendingPathComponent("configured-claude").path as Any, true as Any] {
            defaults.set(storedValue, forKey: key)

            let agentMode = try ClaudeCodeAgentConfig.agentMode(
                commandName: "/usr/bin/false",
                defaults: defaults
            )
            let discovery = try ClaudeCodeAgentConfig.discovery(
                commandName: "/usr/bin/true",
                defaults: defaults
            )

            XCTAssertEqual(agentMode.commandName, "/usr/bin/false")
            XCTAssertEqual(agentMode.commandSelection, .programmaticOverride(command: "/usr/bin/false"))
            XCTAssertEqual(discovery.commandName, "/usr/bin/true")
            XCTAssertEqual(discovery.commandSelection, .programmaticOverride(command: "/usr/bin/true"))
        }
    }

    func testAbsentOverridePreservesAutomaticClaudeForBothFactoriesAndAllRuntimeVariants() throws {
        for variant in runtimeVariants {
            let agentMode = try ClaudeCodeAgentConfig.agentMode(
                runtimeVariant: variant,
                defaults: defaults
            )
            let discovery = try ClaudeCodeAgentConfig.discovery(
                runtimeVariant: variant,
                defaults: defaults
            )

            for config in [agentMode, discovery] {
                XCTAssertEqual(config.commandName, "claude", "variant: \(variant)")
                XCTAssertEqual(config.commandSelection, .automatic(command: "claude"), "variant: \(variant)")
            }
        }
    }

    func testCorruptStoredValueFailsClaudeFactoriesAndLegacyProviderWithTypedError() {
        defaults.set(true, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))

        assertCorruptOverrideError {
            _ = try ClaudeCodeAgentConfig.agentMode(defaults: defaults)
        }
        assertCorruptOverrideError {
            _ = try ClaudeCodeAgentConfig.discovery(defaults: defaults)
        }
        assertCorruptOverrideError {
            _ = try ClaudeCodeProvider(defaults: defaults)
        }
    }

    func testInvalidAndCorruptProbeSelectionsPublishStableFailureWithoutSpawn() async throws {
        let marker = root.appendingPathComponent("spawned")
        let configuredExecutable = root.appendingPathComponent("configured-claude")
        try writeFile(
            configuredExecutable,
            contents: "#!/bin/sh\nprintf spawned > '" + marker.path + "'\n",
            permissions: 0o644
        )
        defaults.set(
            configuredExecutable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )

        let viewModel = makeSettingsViewModel()
        let invalidProbeSucceeded = await viewModel.refreshClaudeCodeBinaryStatus(timeout: 2, forceProbe: true)
        XCTAssertFalse(invalidProbeSucceeded)
        let invalidProbeMessage = try XCTUnwrap(binaryMissingMessage(viewModel.claudeCodeCLIStatus))
        XCTAssertTrue(invalidProbeMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        XCTAssertTrue(invalidProbeMessage.contains(configuredExecutable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        guard case let .configured(path, validation, _) = viewModel.claudeExecutableOverrideAppliedState else {
            return XCTFail("Expected configured effective state for invalid applied path")
        }
        XCTAssertEqual(path, configuredExecutable.path)
        guard case let .invalid(appliedMessage) = validation else {
            return XCTFail("Expected invalid applied-path validation")
        }
        XCTAssertTrue(appliedMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        guard case let .failed(probeMessage)? = viewModel.displayedClaudeExecutableProbeStatus else {
            return XCTFail("Expected fingerprint-matched probe failure")
        }
        XCTAssertTrue(probeMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        XCTAssertTrue(probeMessage.contains(configuredExecutable.path))

        defaults.set(true, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))
        let corruptProbeSucceeded = await viewModel.refreshClaudeCodeBinaryStatus(timeout: 2, forceProbe: true)
        XCTAssertFalse(corruptProbeSucceeded)
        XCTAssertTrue(
            try XCTUnwrap(binaryMissingMessage(viewModel.claudeCodeCLIStatus))
                .hasPrefix(CLIExecutableOverrideError.messagePrefix)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        guard case let .corrupt(corruptMessage) = viewModel.claudeExecutableOverrideAppliedState else {
            return XCTFail("Expected visible corrupt effective state")
        }
        XCTAssertTrue(corruptMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        guard case let .failed(corruptProbeMessage)? = viewModel.displayedClaudeExecutableProbeStatus else {
            return XCTFail("Expected fingerprint-matched corrupt probe failure")
        }
        XCTAssertTrue(corruptProbeMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
    }

    func testValidProbeExecutesConfiguredBinaryAndReportsResolvedCommand() async throws {
        let marker = root.appendingPathComponent("probe-argv0")
        let executable = root.appendingPathComponent("configured-claude")
        try writeFile(
            executable,
            contents: "#!/bin/sh\nprintf '%s\\n' \"$0\" >> '" + marker.path + "'\nprintf 'Claude fixture 1.0\\n'\n",
            permissions: 0o755
        )
        defaults.set(executable.path, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))

        let viewModel = makeSettingsViewModel()
        let probeSucceeded = await viewModel.refreshClaudeCodeBinaryStatus(timeout: 5, forceProbe: true)
        XCTAssertTrue(probeSucceeded)
        XCTAssertEqual(viewModel.claudeCodeCLIStatus, .binaryPresent)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(
                resolvedCommand: executable.path,
                version: "Claude fixture 1.0"
            )
        )

        let config = try APISettingsViewModel.claudeCodeProbeConfiguration(
            defaults: defaults,
            captureTailBytes: 1024
        )
        XCTAssertEqual(config.shellLookupMode, .preferShell)
        XCTAssertEqual(config.commandSelection, .configuredExactPath(executable.path))

        let result = try await CLIProcessRunner(config: config).run(
            args: ["--version"],
            stdin: nil,
            outputMode: .none,
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.resolvedCommand, executable.path)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            executable.path + "\n" + executable.path + "\n"
        )
    }

    func testMCPInstallExecutesConfiguredBinaryAsArgv0() async throws {
        let marker = root.appendingPathComponent("install-argv0")
        let executable = root.appendingPathComponent("configured-claude")
        try writeFile(
            executable,
            contents: "#!/bin/sh\nprintf '%s\\n' \"$0\" > '" + marker.path + "'\nexit 0\n",
            permissions: 0o755
        )
        defaults.set(executable.path, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))

        let result = await ClaudeCodeIntegrationConfiguration.installInClaudeCode(
            defaults: defaults
        )

        XCTAssertTrue(result.success)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            executable.path + "\n"
        )
    }

    func testMCPInstallRejectsInvalidAndCorruptOverridesWithoutSpawn() async throws {
        let marker = root.appendingPathComponent("install-spawned")
        let executable = root.appendingPathComponent("configured-claude")
        try writeFile(
            executable,
            contents: "#!/bin/sh\nprintf spawned > '" + marker.path + "'\n",
            permissions: 0o644
        )
        let key = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        defaults.set(executable.path, forKey: key)

        let invalid = await ClaudeCodeIntegrationConfiguration.installInClaudeCode(
            defaults: defaults
        )
        XCTAssertFalse(invalid.success)
        let invalidInstallMessage = try XCTUnwrap(invalid.errorMessage)
        XCTAssertTrue(invalidInstallMessage.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        XCTAssertTrue(invalidInstallMessage.contains(executable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        defaults.set(true, forKey: key)
        let corrupt = await ClaudeCodeIntegrationConfiguration.installInClaudeCode(
            defaults: defaults
        )
        XCTAssertFalse(corrupt.success)
        XCTAssertTrue(
            try XCTUnwrap(corrupt.errorMessage)
                .hasPrefix(CLIExecutableOverrideError.messagePrefix)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClaudeOverrideDoesNotAffectCodexExecutableResolution() {
        let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        let before = CodexProviderHelpers.resolveCodexExecutable(
            commandName: "/usr/bin/true",
            environment: environment,
            additionalPathHints: []
        )

        defaults.set(
            root.appendingPathComponent("configured-claude").path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )

        let after = CodexProviderHelpers.resolveCodexExecutable(
            commandName: "/usr/bin/true",
            environment: environment,
            additionalPathHints: []
        )

        XCTAssertEqual(after.commandName, before.commandName)
        XCTAssertEqual(after.resolvedCommand, before.resolvedCommand)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.pathValue, before.pathValue)
        XCTAssertEqual(after.additionalPathHints, before.additionalPathHints)
        XCTAssertEqual(after.userMessage, before.userMessage)
        XCTAssertEqual(after.debugMessage, before.debugMessage)
    }

    private var runtimeVariants: [ClaudeCodeRuntimeVariant] {
        [.standard, .glm, .kimi, .customCompatible]
    }

    private func makeSettingsViewModel() -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            cliExecutableOverrideDefaults: defaults
        )
    }

    private func binaryMissingMessage(_ status: ClaudeCodeCLIStatus) -> String? {
        guard case let .binaryMissing(message) = status else { return nil }
        return message
    }

    private func assertCorruptOverrideError(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case CLIExecutableOverrideError.corruptStoredValue = error else {
                return XCTFail("Expected corruptStoredValue, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                error.localizedDescription.hasPrefix(CLIExecutableOverrideError.messagePrefix),
                file: file,
                line: line
            )
        }
    }

    private func writeFile(_ url: URL, contents: String, permissions: Int16) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}
