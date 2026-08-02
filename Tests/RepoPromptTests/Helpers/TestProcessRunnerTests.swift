import Foundation
import XCTest

final class TestProcessRunnerTests: XCTestCase {
    func testDrainsLargeOutputWhileChildIsRunning() throws {
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "131072", "/dev/zero"]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.count, 131_072)
    }

    func testGitRunnerHermeticEnvironmentDropsInheritedCommandScopeConfiguration() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestGitCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let repository = sandbox.appendingPathComponent("repo", isDirectory: true)
        let hookDirectory = sandbox.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sandbox)
        }

        @discardableResult
        func runGit(
            _ arguments: [String],
            environment: [String: String]
        ) throws -> TestProcessResult {
            let result = try TestProcessRunner.run(
                executableURL: TestGitCommandRunner.executableURL,
                arguments: arguments,
                currentDirectoryURL: repository,
                environment: environment
            )
            guard result.terminationStatus == 0 else {
                throw NSError(
                    domain: "TestGitCommandRunnerTests.git",
                    code: Int(result.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: TestGitCommandRunner.failureDescription(
                            arguments: arguments,
                            cwd: repository,
                            outputText: result.outputText
                        )
                    ]
                )
            }
            return result
        }

        let cleanEnvironment = TestGitCommandRunner.processEnvironment(base: [
            "LANG": "C",
            "PATH": "/usr/bin:/bin"
        ])
        try runGit(["init", "--initial-branch=main"], environment: cleanEnvironment)
        try runGit(["config", "user.name", "RepoPrompt Test"], environment: cleanEnvironment)
        try runGit(["config", "user.email", "repoprompt@example.test"], environment: cleanEnvironment)
        try runGit(["config", "commit.gpgSign", "false"], environment: cleanEnvironment)
        try "stable\n".write(
            to: repository.appendingPathComponent("Tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "Tracked.txt"], environment: cleanEnvironment)

        let preCommitHook = hookDirectory.appendingPathComponent("pre-commit")
        try "#!/bin/sh\nexit 91\n".write(to: preCommitHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: preCommitHook.path
        )

        var hostileBase = cleanEnvironment
        hostileBase["GIT_CONFIG_COUNT"] = "3"
        hostileBase["GIT_CONFIG_KEY_0"] = "commit.gpgSign"
        hostileBase["GIT_CONFIG_VALUE_0"] = "true"
        hostileBase["GIT_CONFIG_KEY_1"] = "gpg.program"
        hostileBase["GIT_CONFIG_VALUE_1"] = "/usr/bin/false"
        hostileBase["GIT_CONFIG_KEY_2"] = "core.hooksPath"
        hostileBase["GIT_CONFIG_VALUE_2"] = hookDirectory.path
        hostileBase["GIT_CONFIG_PARAMETERS"] = "'commit.gpgSign=true'"

        let hermeticEnvironment = TestGitCommandRunner.processEnvironment(base: hostileBase)
        XCTAssertEqual(hermeticEnvironment["GIT_CONFIG_NOSYSTEM"], "1")
        XCTAssertEqual(hermeticEnvironment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(hermeticEnvironment["GIT_ATTR_NOSYSTEM"], "1")
        XCTAssertNil(hermeticEnvironment["GIT_CONFIG_COUNT"])
        XCTAssertNil(hermeticEnvironment["GIT_CONFIG_PARAMETERS"])
        XCTAssertFalse(hermeticEnvironment.keys.contains { $0.hasPrefix("GIT_CONFIG_KEY_") })
        XCTAssertFalse(hermeticEnvironment.keys.contains { $0.hasPrefix("GIT_CONFIG_VALUE_") })

        try runGit(["commit", "-m", "Stable fixture"], environment: hermeticEnvironment)
    }

    func testTimeoutTerminatesProcessAndReportsContext() throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cwd)
        }

        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf started; exec /bin/sleep 5"],
                currentDirectoryURL: cwd,
                timeout: 0.25
            )
            XCTFail("Expected process timeout")
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.executableURL.path, "/bin/sh")
            XCTAssertEqual(error.arguments, ["-c", "printf started; exec /bin/sleep 5"])
            XCTAssertEqual(error.currentDirectoryURL, cwd)
            XCTAssertEqual(error.timeout, 0.25)
            XCTAssertEqual(error.outputText, "started")
            XCTAssertTrue(error.description.contains("cwd: \(cwd.path)"))
        }
    }

    func testTimeoutReturnsWhenChildProcessKeepsPipeOpen() throws {
        let startedAt = Date()

        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf parent-started; sleep 5 & wait"],
                timeout: 0.25
            )
            XCTFail("Expected process timeout")
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.outputText, "parent-started")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
    }

    func testTimeoutReturnsWhenExitedParentLeavesChildHoldingPipe() throws {
        let startedAt = Date()

        // Hold the pipe write end with a child that ignores common signals so platform
        // SIGHUP/termination of the orphan cannot make drain complete before the grace budget.
        // Accept either drain-timeout (parent exits 0) or process-timeout as long as wall time
        // stays bounded and the output prefix matches.
        do {
            _ = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf parent-exited; (trap '' HUP INT TERM; exec /bin/sleep 30) & exit 0"
                ],
                timeout: 0.25
            )
            XCTFail("Expected a bounded timeout while orphaned child holds the pipe")
        } catch let error as TestProcessOutputDrainTimeoutError {
            XCTAssertEqual(error.outputText, "parent-exited")
            XCTAssertEqual(error.terminationStatus, 0)
            XCTAssertTrue(error.description.contains("output drain timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        } catch let error as TestProcessTimeoutError {
            XCTAssertEqual(error.outputText, "parent-exited")
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
    }
}
