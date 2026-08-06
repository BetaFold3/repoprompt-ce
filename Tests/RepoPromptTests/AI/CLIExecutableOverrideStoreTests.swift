import Foundation
@testable import RepoPromptApp
import XCTest

final class CLIExecutableOverrideStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "CLIExecutableOverrideStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIExecutableOverrideStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        suiteName = nil
        root = nil
    }

    func testEmptyWhitespaceAndNewlineStoredValuesUseAutomaticSelection() throws {
        let key = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        XCTAssertEqual(key, "cliExecutableOverride.claude")

        for storedValue in ["", "   ", "\n"] {
            defaults.set(storedValue, forKey: key)
            XCTAssertEqual(
                try CLIExecutableOverrideStore.effectiveCommand(
                    for: CLILaunchProfiles.claudeCode,
                    defaults: defaults
                ),
                .automatic(command: "claude"),
                "Stored value \(storedValue.debugDescription)"
            )
        }
    }

    func testApplyNormalizesTildeAndLocalFileURLInputs() throws {
        XCTAssertEqual(
            try CLIExecutableOverrideStore.normalizeForApply("  ~/.claude-rotator/shim/bin/claude\n"),
            NSHomeDirectory() + "/.claude-rotator/shim/bin/claude"
        )

        let executable = root.appendingPathComponent("claude tool$")
        try writeFile(executable, permissions: 0o755)

        let selection = try CLIExecutableOverrideStore.apply(
            executable.absoluteString,
            for: CLILaunchProfiles.claudeCode,
            defaults: defaults
        )

        XCTAssertEqual(selection, .configuredExactPath(executable.path))
        XCTAssertEqual(
            defaults.object(forKey: "cliExecutableOverride.claude") as? String,
            executable.path
        )
    }

    func testApplyRejectsRelativePath() {
        assertOverrideError(input: "bin/claude") { error in
            guard case .notAbsolute = error else {
                return XCTFail("Expected notAbsolute, got \(error)")
            }
        }
    }

    func testApplyRejectsVariableExpressionsWithoutExpandingThem() {
        for input in ["$HOME/bin/claude", "${CLAUDE_HOME}/bin/claude"] {
            assertOverrideError(input: input) { error in
                guard case .containsVariableExpression = error else {
                    return XCTFail("Expected containsVariableExpression, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("no expansion occurs"))
            }
        }
    }

    func testApplyRejectsUnsupportedAbsolutePathSyntax() {
        let inputs = [
            "~otheruser/bin/claude",
            "/tmp/claude\0suffix",
            "/tmp/claude\nother",
            "file://remote.example/tmp/claude",
            "file://%"
        ]

        for input in inputs {
            assertOverrideError(input: input) { error in
                guard case .notAbsolute = error else {
                    return XCTFail("Expected notAbsolute for \(input.debugDescription), got \(error)")
                }
            }
        }
    }

    func testValidateForLaunchRejectsNULAndNewlineBeforeFilesystemLookup() {
        for path in ["/tmp/claude\0suffix", "/tmp/claude\nother"] {
            XCTAssertThrowsError(
                try CLIExecutableOverrideStore.validateForLaunch(
                    path,
                    commandName: CLILaunchProfiles.claudeCode.commandName
                )
            ) { error in
                guard case CLIExecutableOverrideError.notAbsolute = error else {
                    return XCTFail("Expected notAbsolute for \(path.debugDescription), got \(error)")
                }
            }
        }
    }

    func testSeededMalformedStoredValuesRemainStrictAndFailValidation() throws {
        let executable = root.appendingPathComponent("claude")
        let newlineExecutable = root.appendingPathComponent("claude\nother")
        try writeFile(executable, permissions: 0o755)
        try writeFile(newlineExecutable, permissions: 0o755)
        let key = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)

        for storedPath in [executable.path + "\0suffix", newlineExecutable.path] {
            defaults.set(storedPath, forKey: key)
            let selection = try CLIExecutableOverrideStore.effectiveCommand(
                for: CLILaunchProfiles.claudeCode,
                defaults: defaults
            )
            XCTAssertEqual(selection, .configuredExactPath(storedPath))
            XCTAssertThrowsError(
                try CLIExecutableOverrideStore.validateForLaunch(
                    selection.command,
                    commandName: CLILaunchProfiles.claudeCode.commandName
                )
            ) { error in
                guard case CLIExecutableOverrideError.notAbsolute = error else {
                    return XCTFail("Expected notAbsolute for \(storedPath.debugDescription), got \(error)")
                }
            }
        }
    }

    func testApplyRejectsMissingFile() {
        assertOverrideError(input: root.appendingPathComponent("missing-claude").path) { error in
            guard case .missing = error else {
                return XCTFail("Expected missing, got \(error)")
            }
        }
    }

    func testApplyRejectsDirectoryWithCommandSuggestion() throws {
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        assertOverrideError(input: directory.path) { error in
            guard case let .directory(suggestion) = error else {
                return XCTFail("Expected directory, got \(error)")
            }
            XCTAssertEqual(suggestion, directory.appendingPathComponent("claude").path)
        }
    }

    func testApplyRejectsNonExecutableFile() throws {
        let file = root.appendingPathComponent("claude")
        try writeFile(file, permissions: 0o644)

        assertOverrideError(input: file.path) { error in
            guard case .notExecutable = error else {
                return XCTFail("Expected notExecutable, got \(error)")
            }
        }
    }

    func testApplyRejectsBrokenSymlink() throws {
        let link = root.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("missing-target")
        )

        assertOverrideError(input: link.path) { error in
            guard case .brokenSymlink = error else {
                return XCTFail("Expected brokenSymlink, got \(error)")
            }
        }
    }

    func testCorruptNonStringStoredValueThrowsTypedError() {
        defaults.set(true, forKey: "cliExecutableOverride.claude")

        XCTAssertThrowsError(
            try CLIExecutableOverrideStore.effectiveCommand(
                for: CLILaunchProfiles.claudeCode,
                defaults: defaults
            )
        ) { error in
            guard case let CLIExecutableOverrideError.corruptStoredValue(typeDescription) = error else {
                return XCTFail("Expected corruptStoredValue, got \(error)")
            }
            XCTAssertFalse(typeDescription.isEmpty)
            XCTAssertTrue(error.localizedDescription.hasPrefix(CLIExecutableOverrideError.messagePrefix))
        }
    }

    func testExecutableSymlinkIsAcceptedWithoutCanonicalizingConfiguredPath() throws {
        let target = root.appendingPathComponent("real-claude")
        let link = root.appendingPathComponent("configured-claude")
        try writeFile(target, permissions: 0o755)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let selection = try CLIExecutableOverrideStore.apply(
            " \(link.path)\n",
            for: CLILaunchProfiles.claudeCode,
            defaults: defaults
        )

        XCTAssertEqual(selection, .configuredExactPath(link.path))
        XCTAssertEqual(
            try CLIExecutableOverrideStore.validateForLaunch(
                link.path,
                commandName: CLILaunchProfiles.claudeCode.commandName
            ),
            link.path
        )
        XCTAssertEqual(
            try CLIExecutableOverrideStore.effectiveCommand(
                for: CLILaunchProfiles.claudeCode,
                defaults: defaults
            ),
            .configuredExactPath(link.path)
        )
    }

    private func assertOverrideError(
        input: String,
        verify: (CLIExecutableOverrideError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CLIExecutableOverrideStore.apply(
                input,
                for: CLILaunchProfiles.claudeCode,
                defaults: defaults
            ),
            file: file,
            line: line
        ) { error in
            guard let overrideError = error as? CLIExecutableOverrideError else {
                return XCTFail("Expected CLIExecutableOverrideError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                overrideError.localizedDescription.hasPrefix(CLIExecutableOverrideError.messagePrefix),
                file: file,
                line: line
            )
            verify(overrideError)
        }
    }

    private func writeFile(_ url: URL, permissions: Int16) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}
