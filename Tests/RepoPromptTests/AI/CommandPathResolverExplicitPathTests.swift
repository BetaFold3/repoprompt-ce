import Foundation
@testable import RepoPromptApp
import XCTest

final class CommandPathResolverExplicitPathTests: XCTestCase {
    func testAbsoluteExecutablePathBypassesShellInEveryLookupMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandPathResolverExplicitPathTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("claude")
        let recordingFile = root.appendingPathComponent("shell-invocations")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(executable, contents: "#!/bin/sh\nexit 0\n")
        try Data().write(to: recordingFile)
        try writeExecutable(
            fakeShell,
            contents: """
            #!/bin/sh
            printf 'invoked\\n' >> "\(recordingFile.path)"
            exit 1
            """
        )

        let environment = [
            "HOME": root.path,
            "PATH": "",
            "SHELL": fakeShell.path
        ]
        let modes: [(String, CommandPathResolver.ShellLookupMode)] = [
            ("preferShell", .preferShell),
            ("fallbackOnly", .fallbackOnly),
            ("disabled", .disabled)
        ]

        for (label, mode) in modes {
            XCTAssertEqual(
                CommandPathResolver.resolve(
                    executable.path,
                    environment: environment,
                    additionalPaths: [],
                    preferredBasenames: ["claude"],
                    shellLookupMode: mode
                ),
                executable.path,
                label
            )
            XCTAssertEqual(
                try String(contentsOf: recordingFile, encoding: .utf8),
                "",
                "\(label) invoked the shell for an absolute executable path"
            )
        }
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
