import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeProcessCommandSelectionTests: XCTestCase {
    func testConfiguredExactPathResolvesVerbatimWithProvenanceAndRevalidatesEachSpawn() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.root.appendingPathComponent("configured-claude")
        try writeExecutable(executable, contents: "#!/bin/sh\nexit 0\n")
        let selection = CLICommandSelection.configuredExactPath(executable.path)
        let environment = [
            "HOME": fixture.root.path,
            "PATH": "",
            "SHELL": fixture.fakeShell.path
        ]

        let first = try ClaudeNativeProcessSessionController.resolveCommandForLaunch(
            selection: selection,
            environment: environment,
            additionalPaths: []
        )

        XCTAssertEqual(first.command, executable.path)
        XCTAssertEqual(first.provenance, .configuredOverride)
        XCTAssertEqual(first.provenance.rawValue, "configuredOverride")
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: executable.path
        )

        XCTAssertThrowsError(
            try ClaudeNativeProcessSessionController.resolveCommandForLaunch(
                selection: selection,
                environment: environment,
                additionalPaths: []
            )
        ) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(detail.contains(executable.path))
            XCTAssertTrue(detail.contains("must be an executable regular file"))
            XCTAssertTrue(detail.contains("Fix the path in Settings or use Automatic"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testInvalidConfiguredPathFailsBeforeShellWithActionableInvalidConfiguration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missing = fixture.root.appendingPathComponent("missing-claude").path

        XCTAssertThrowsError(
            try ClaudeNativeProcessSessionController.resolveCommandForLaunch(
                selection: .configuredExactPath(missing),
                environment: [
                    "HOME": fixture.root.path,
                    "PATH": fixture.root.path,
                    "SHELL": fixture.fakeShell.path
                ],
                additionalPaths: [fixture.root.path]
            )
        ) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(detail.contains(missing))
            XCTAssertTrue(detail.contains("does not exist"))
            XCTAssertTrue(detail.contains("Fix the path in Settings or use Automatic"))
        }

        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testAutomaticAndProgrammaticSelectionsUsePreferShellAndReportProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.root.appendingPathComponent("claude")
        try writeExecutable(executable, contents: "#!/bin/sh\nexit 0\n")
        let environment = [
            "HOME": fixture.root.path,
            "PATH": fixture.root.path,
            "SHELL": fixture.fakeShell.path
        ]

        let automatic = try ClaudeNativeProcessSessionController.resolveCommandForLaunch(
            selection: .automatic(command: "claude"),
            environment: environment,
            additionalPaths: []
        )
        XCTAssertEqual(automatic.command, executable.path)
        XCTAssertEqual(automatic.provenance, .automaticResolved)
        XCTAssertFalse(try String(contentsOf: fixture.shellRecorder, encoding: .utf8).isEmpty)

        try Data().write(to: fixture.shellRecorder)
        let programmatic = try ClaudeNativeProcessSessionController.resolveCommandForLaunch(
            selection: .programmaticOverride(command: "claude"),
            environment: environment,
            additionalPaths: []
        )
        XCTAssertEqual(programmatic.command, executable.path)
        XCTAssertEqual(programmatic.provenance, .programmaticOverride)
        XCTAssertFalse(try String(contentsOf: fixture.shellRecorder, encoding: .utf8).isEmpty)
    }

    func testConfiguredSelectionRequiresFreshControllerAfterTerminalStartupFailure() async throws {
        let config = try ClaudeCodeAgentConfig.discovery(commandName: "claude")
        let configured = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: config,
            commandSelection: .configuredExactPath("/tmp/claude")
        )
        let automatic = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: config
        )

        let configuredRequiresReplacement = await configured.requiresReplacementAfterTerminalStartupFailure
        let automaticRequiresReplacement = await automatic.requiresReplacementAfterTerminalStartupFailure
        XCTAssertTrue(configuredRequiresReplacement)
        XCTAssertFalse(automaticRequiresReplacement)
    }

    func testControllerWithoutExplicitSelectionUsesConfiguredConfigSelection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suiteName = "ClaudeNativeProcessCommandSelectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let executable = fixture.root.appendingPathComponent("configured-claude")
        try writeExecutable(executable, contents: "#!/bin/sh\nexit 0\n")
        defaults.set(
            executable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )
        let config = try ClaudeCodeAgentConfig.discovery(defaults: defaults)
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: config
        )
        let environment = [
            "HOME": fixture.root.path,
            "PATH": "",
            "SHELL": fixture.fakeShell.path
        ]

        let resolved = try await controller.test_resolveCapturedCommandForLaunch(
            environment: environment
        )
        XCTAssertEqual(resolved.command, executable.path)
        XCTAssertEqual(resolved.provenance, .configuredOverride)
        let requiresReplacement = await controller.requiresReplacementAfterTerminalStartupFailure
        XCTAssertTrue(requiresReplacement)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: executable.path
        )
        do {
            _ = try await controller.test_resolveCapturedCommandForLaunch(environment: environment)
            XCTFail("Expected captured configured path to fail validation")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains(executable.path))
            XCTAssertTrue(detail.contains("must be an executable regular file"))
            XCTAssertTrue(detail.contains("Fix the path in Settings or use Automatic"))
        } catch {
            XCTFail("Expected invalidConfiguration, got \(error)")
        }
    }

    func testControllerRetainsCapturedPathWhenStoredDefaultChangesBetweenSpawnResolutions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suiteName = "ClaudeNativeProcessCommandSelectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstExecutable = fixture.root.appendingPathComponent("claude-a")
        let secondExecutable = fixture.root.appendingPathComponent("claude-b")
        try writeExecutable(firstExecutable, contents: "#!/bin/sh\nexit 0\n")
        try writeExecutable(secondExecutable, contents: "#!/bin/sh\nexit 0\n")
        let key = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        defaults.set(firstExecutable.path, forKey: key)
        let config = try ClaudeCodeAgentConfig.discovery(defaults: defaults)
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: config
        )
        let environment = [
            "HOME": fixture.root.path,
            "PATH": "",
            "SHELL": fixture.fakeShell.path
        ]

        let first = try await controller.test_resolveCapturedCommandForLaunch(environment: environment)
        defaults.set(secondExecutable.path, forKey: key)
        let second = try await controller.test_resolveCapturedCommandForLaunch(environment: environment)

        XCTAssertEqual(first.command, firstExecutable.path)
        XCTAssertEqual(second.command, firstExecutable.path)
        XCTAssertEqual(first.provenance, .configuredOverride)
        XCTAssertEqual(second.provenance, .configuredOverride)
    }

    func testProcessSpawnedPayloadContainsCommandProvenance() {
        let payload = ClaudeNativeProcessSessionController.test_processSpawnedPayload(
            command: "/tmp/configured-claude",
            provenance: .configuredOverride
        )

        XCTAssertEqual(payload["command"] as? String, "/tmp/configured-claude")
        XCTAssertEqual(payload["commandProvenance"] as? String, "configuredOverride")
    }

    func testConfiguredConnectTimeoutHintStatesWrapperTransparencyWithoutClaimingCause() {
        let path = "/tmp/custom claude"
        XCTAssertEqual(
            ClaudeNativeProcessSessionController.connectTimeoutHint(
                for: .configuredExactPath(path)
            ),
            "a custom Claude executable path is configured: \(path) — wrappers must exec and keep stdin/stdout stream-json-transparent"
        )
        XCTAssertNil(
            ClaudeNativeProcessSessionController.connectTimeoutHint(
                for: .automatic(command: "claude")
            )
        )
        XCTAssertNil(
            ClaudeNativeProcessSessionController.connectTimeoutHint(
                for: .programmaticOverride(command: "claude")
            )
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeNativeProcessCommandSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = root.appendingPathComponent("shell-invocations")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try Data().write(to: recorder)
        try writeExecutable(
            fakeShell,
            contents: """
            #!/bin/sh
            printf 'invoked\n' >> '\(recorder.path)'
            exit 1
            """
        )
        return Fixture(root: root, fakeShell: fakeShell, shellRecorder: recorder)
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private struct Fixture {
        let root: URL
        let fakeShell: URL
        let shellRecorder: URL
    }
}
