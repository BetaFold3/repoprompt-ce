import Foundation
@testable import RepoPromptApp
import XCTest

final class CLIProcessRunnerCommandSelectionTests: XCTestCase {
    func testConfiguredExactPathRunsVerbatimWithoutShellAndMatchesBufferedStreaming() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let marker = fixture.root.appendingPathComponent("argv0")
        let executable = fixture.root.appendingPathComponent("configured-claude")
        try writeExecutable(
            executable,
            contents: """
            #!/bin/sh
            printf '%s\n' "$0" >> '\(marker.path)'
            printf 'exact-output'
            """
        )

        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "claude",
            commandSelection: .configuredExactPath(executable.path),
            environment: ["SHELL": fixture.fakeShell.path],
            additionalPaths: [],
            enableDebugLogging: false
        ))

        let buffered = try await runner.run(
            args: [],
            stdin: nil,
            outputMode: .none,
            timeout: 5
        )
        XCTAssertEqual(buffered.status, 0)
        XCTAssertEqual(buffered.stdout, Data("exact-output".utf8))
        XCTAssertEqual(buffered.resolvedCommand, executable.path)

        let stream = try await runner.runStreaming(
            args: [],
            stdin: nil,
            outputMode: .none,
            timeout: 5
        )
        var streamingResolvedCommand: String?
        var streamingOutput = Data()
        for try await event in stream {
            switch event {
            case let .stdout(chunk):
                streamingOutput.append(chunk)
            case .stderr:
                break
            case let .terminated(status, timedOut, resolvedCommand):
                XCTAssertEqual(status, 0)
                XCTAssertFalse(timedOut)
                streamingResolvedCommand = resolvedCommand
            }
        }

        XCTAssertEqual(streamingOutput, buffered.stdout)
        XCTAssertEqual(streamingResolvedCommand, buffered.resolvedCommand)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "\(executable.path)\n\(executable.path)\n"
        )
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testInvalidConfiguredPathThrowsTypedErrorBeforeShellOrSpawn() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let spawnMarker = fixture.root.appendingPathComponent("spawned")
        let fallback = fixture.root.appendingPathComponent("claude")
        try writeExecutable(
            fallback,
            contents: "#!/bin/sh\nprintf spawned > '\(spawnMarker.path)'\n"
        )
        let missing = fixture.root.appendingPathComponent("missing-claude").path
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: fallback.path,
            commandSelection: .configuredExactPath(missing),
            environment: ["SHELL": fixture.fakeShell.path],
            additionalPaths: [fixture.root.path],
            enableDebugLogging: false
        ))

        do {
            _ = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
            XCTFail("Expected strict buffered launch validation to fail")
        } catch let CLIProcessRunnerError.explicitCommandNotLaunchable(path, reason) {
            XCTAssertEqual(path, missing)
            guard case .missing = reason else {
                return XCTFail("Expected missing reason, got \(reason)")
            }
        } catch {
            XCTFail("Expected typed runner error, got \(error)")
        }

        do {
            _ = try await runner.runStreaming(args: [], stdin: nil, outputMode: .none, timeout: 5)
            XCTFail("Expected strict streaming launch validation to fail")
        } catch let CLIProcessRunnerError.explicitCommandNotLaunchable(path, reason) {
            XCTAssertEqual(path, missing)
            guard case .missing = reason else {
                return XCTFail("Expected missing reason, got \(reason)")
            }
        } catch {
            XCTFail("Expected typed runner error, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: spawnMarker.path))
        try writeExecutable(URL(fileURLWithPath: missing), contents: "#!/bin/sh\nprintf recovered\n")
        let recoveredStream = try await runner.runStreaming(
            args: [],
            stdin: nil,
            outputMode: .none,
            timeout: 5
        )
        var recoveredOutput = Data()
        for try await event in recoveredStream {
            if case let .stdout(chunk) = event {
                recoveredOutput.append(chunk)
            }
        }
        XCTAssertEqual(recoveredOutput, Data("recovered".utf8))
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testAutomaticNonStrictResolutionPreservesPathSearchBehavior() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "tailscale")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.root.appendingPathComponent("tailscale")
        try writeExecutable(executable, contents: "#!/bin/sh\nprintf legacy-path\n")
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "tailscale",
            environment: ["SHELL": fixture.fakeShell.path, "PATH": ""],
            additionalPaths: [fixture.root.path],
            enableDebugLogging: false,
            shellLookupMode: .disabled
        ))

        let result = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data("legacy-path".utf8))
        XCTAssertEqual(result.resolvedCommand, executable.path)
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testCacheInvalidationRestoresAutomaticResolutionAndExactPathsNeverEnterCache() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let automaticA = fixture.root.appendingPathComponent("automatic-a", isDirectory: true)
        let exactDirectory = fixture.root.appendingPathComponent("exact", isDirectory: true)
        let automaticC = fixture.root.appendingPathComponent("automatic-c", isDirectory: true)
        try FileManager.default.createDirectory(at: automaticA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exactDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: automaticC, withIntermediateDirectories: true)

        let a = automaticA.appendingPathComponent("claude")
        let b = exactDirectory.appendingPathComponent("claude")
        let c = automaticC.appendingPathComponent("claude")
        try writeExecutable(a, contents: "#!/bin/sh\nprintf A\n")
        try writeExecutable(b, contents: "#!/bin/sh\nprintf B\n")
        try writeExecutable(c, contents: "#!/bin/sh\nprintf C\n")

        let first = try await runAutomatic(command: "claude", path: automaticA.path, fixture: fixture)
        XCTAssertEqual(first.stdout, Data("A".utf8))
        XCTAssertEqual(first.resolvedCommand, a.path)

        let exact = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "claude",
            commandSelection: .configuredExactPath(b.path),
            environment: ["SHELL": fixture.fakeShell.path, "PATH": ""],
            additionalPaths: [automaticC.path],
            enableDebugLogging: false,
            shellLookupMode: .disabled
        ))
        let exactResult = try await exact.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
        XCTAssertEqual(exactResult.stdout, Data("B".utf8))
        XCTAssertEqual(exactResult.resolvedCommand, b.path)

        let staleAutomatic = try await runAutomatic(command: "claude", path: automaticC.path, fixture: fixture)
        XCTAssertEqual(staleAutomatic.stdout, Data("A".utf8))
        XCTAssertEqual(staleAutomatic.resolvedCommand, a.path)

        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")

        let refreshedAutomatic = try await runAutomatic(command: "claude", path: automaticC.path, fixture: fixture)
        XCTAssertEqual(refreshedAutomatic.stdout, Data("C".utf8))
        XCTAssertEqual(refreshedAutomatic.resolvedCommand, c.path)
        XCTAssertEqual(try String(contentsOf: fixture.shellRecorder, encoding: .utf8), "")
    }

    func testConfiguredDirectorySuggestionUsesBareProfileCommandName() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let directory = fixture.root.appendingPathComponent("configured-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: directory.path,
            validationCommandName: "claude",
            commandSelection: .configuredExactPath(directory.path),
            environment: ["SHELL": fixture.fakeShell.path],
            additionalPaths: [],
            enableDebugLogging: false
        ))

        do {
            _ = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
            XCTFail("Expected configured directory validation to fail")
        } catch let CLIProcessRunnerError.explicitCommandNotLaunchable(path, reason) {
            XCTAssertEqual(path, directory.path)
            guard case let .directory(suggestion) = reason else {
                return XCTFail("Expected directory reason, got \(reason)")
            }
            XCTAssertEqual(suggestion, directory.appendingPathComponent("claude").path)
        } catch {
            XCTFail("Expected typed runner error, got \(error)")
        }
    }

    func testClaudeScopedInvalidationLeavesNonClaudeCacheEntryIntact() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "tailscale")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let firstDirectory = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try writeExecutable(firstDirectory.appendingPathComponent("claude"), contents: "#!/bin/sh\nprintf claude-first\n")
        try writeExecutable(firstDirectory.appendingPathComponent("tailscale"), contents: "#!/bin/sh\nprintf tailscale-first\n")
        try writeExecutable(secondDirectory.appendingPathComponent("claude"), contents: "#!/bin/sh\nprintf claude-second\n")
        try writeExecutable(secondDirectory.appendingPathComponent("tailscale"), contents: "#!/bin/sh\nprintf tailscale-second\n")

        _ = try await runAutomatic(command: "claude", path: firstDirectory.path, fixture: fixture)
        _ = try await runAutomatic(command: "tailscale", path: firstDirectory.path, fixture: fixture)
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")

        let claude = try await runAutomatic(command: "claude", path: secondDirectory.path, fixture: fixture)
        let tailscale = try await runAutomatic(command: "tailscale", path: secondDirectory.path, fixture: fixture)
        XCTAssertEqual(claude.stdout, Data("claude-second".utf8))
        XCTAssertEqual(tailscale.stdout, Data("tailscale-first".utf8))
    }

    func testInvalidationDropsStalePutFromInFlightAutomaticRun() async throws {
        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let firstDirectory = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let release = fixture.root.appendingPathComponent("release")
        try writeExecutable(
            firstDirectory.appendingPathComponent("claude"),
            contents: "#!/bin/sh\nwhile [ ! -f '\(release.path)' ]; do /bin/sleep 0.01; done\nprintf stale\n"
        )
        try writeExecutable(
            secondDirectory.appendingPathComponent("claude"),
            contents: "#!/bin/sh\nprintf fresh\n"
        )

        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "claude",
            environment: ["SHELL": fixture.fakeShell.path, "PATH": ""],
            additionalPaths: [firstDirectory.path],
            enableDebugLogging: false,
            shellLookupMode: .disabled
        ))
        let stream = try await runner.runStreaming(
            args: [],
            stdin: nil,
            outputMode: .none,
            timeout: 5
        )

        await CLIProcessRunner.invalidateResolvedCommandCache(command: "claude")
        try Data().write(to: release)
        for try await _ in stream {}

        let refreshed = try await runAutomatic(command: "claude", path: secondDirectory.path, fixture: fixture)
        XCTAssertEqual(refreshed.stdout, Data("fresh".utf8))
        XCTAssertEqual(
            refreshed.resolvedCommand,
            secondDirectory.appendingPathComponent("claude").path
        )
    }

    func testConfiguredENOENTAfterValidationUsesLaunchFailedAfterValidation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.root.appendingPathComponent("configured-claude")
        try writeExecutable(
            executable,
            contents: "#!/definitely/missing/repoprompt-test-interpreter\n"
        )
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: executable.path,
            validationCommandName: "claude",
            commandSelection: .configuredExactPath(executable.path),
            environment: ["SHELL": fixture.fakeShell.path],
            additionalPaths: [],
            enableDebugLogging: false
        ))

        do {
            _ = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
            XCTFail("Expected launch to fail after validation")
        } catch let CLIProcessRunnerError.explicitCommandNotLaunchable(path, reason) {
            XCTAssertEqual(path, executable.path)
            guard case .launchFailedAfterValidation = reason else {
                return XCTFail("Expected launchFailedAfterValidation, got \(reason)")
            }
            XCTAssertTrue(reason.localizedDescription.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        } catch {
            XCTFail("Expected configured launch failure, got \(error)")
        }
    }

    private func runAutomatic(
        command: String,
        path: String,
        fixture: Fixture
    ) async throws -> CLIProcessRunner.Result {
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: command,
            environment: ["SHELL": fixture.fakeShell.path, "PATH": ""],
            additionalPaths: [path],
            enableDebugLogging: false,
            shellLookupMode: .disabled
        ))
        return try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProcessRunnerCommandSelectionTests-\(UUID().uuidString)", isDirectory: true)
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
