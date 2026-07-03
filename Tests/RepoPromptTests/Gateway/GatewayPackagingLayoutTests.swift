import Foundation
import XCTest

final class GatewayPackagingLayoutTests: XCTestCase {
    func testEmbeddedHelperLayoutValidatorRequiresMCPAndGatewayExecutables() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayPackagingLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("RepoPrompt.app", isDirectory: true)
        try makeAppLayout(at: app)

        let accepted = try runLayoutValidator(app: app)
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertTrue(accepted.stdout.contains("matches the embedded helper layout policy"))

        try FileManager.default.removeItem(
            at: app.appendingPathComponent("Contents/MacOS/repoprompt-gateway")
        )
        let rejected = try runLayoutValidator(app: app)
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertTrue(
            rejected.stderr.contains("missing embedded helper")
                && rejected.stderr.contains("repoprompt-gateway"),
            rejected.stderr
        )
    }

    private func makeAppLayout(at app: URL) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let resourcesBin = resources.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesBin, withIntermediateDirectories: true)

        for executable in ["RepoPrompt", "repoprompt-mcp", "repoprompt-gateway"] {
            let url = macOS.appendingPathComponent(executable)
            try "#!/usr/bin/env bash\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        for helper in ["repoprompt-mcp", "repoprompt-gateway"] {
            try FileManager.default.createSymbolicLink(
                atPath: resources.appendingPathComponent(helper).path,
                withDestinationPath: "../MacOS/\(helper)"
            )
            try FileManager.default.createSymbolicLink(
                atPath: resourcesBin.appendingPathComponent(helper).path,
                withDestinationPath: "../../MacOS/\(helper)"
            )
        }
    }

    private func runLayoutValidator(app: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let script = try RepoRoot.url()
            .appendingPathComponent("Scripts/validate_embedded_mcp_helper_layout.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, app.path, "Gateway packaging fixture"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
