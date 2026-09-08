#if DEBUG
    import Foundation
    import XCTest

    final class ClaudeBranchForkSpikeLiveTests: XCTestCase {
        private let gateKey = "RPCE_CLAUDE_BRANCH_SPIKE"

        func testGateRejectsLiveExecutionWithoutExactOptIn() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent("claude-invoked")
            let fakeClaude = bin.appendingPathComponent("claude")
            try """
            #!/bin/sh
            /usr/bin/touch '\(marker.path)'
            exit 0
            """.write(to: fakeClaude, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

            let report = root.appendingPathComponent("report.md")
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: gateKey)
            environment["PATH"] = "\(bin.path):/usr/bin:/bin"
            let result = try runHelper(arguments: ["--report", report.path], environment: environment)

            XCTAssertEqual(result.terminationStatus, 64)
            XCTAssertTrue(result.outputText.contains("\(gateKey)=1 is required"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        }

        func testJSONLParserSummarizesStructureWithoutRawContent() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = root.appendingPathComponent("fixture.jsonl")
            try """
            {"type":"user","sessionId":"source-session","uuid":"prompt-uuid","isSidechain":false,"message":{"role":"user","content":"PRIVATE_PROMPT"}}
            malformed
            {"type":"assistant","sessionId":"source-session","uuid":"answer-uuid","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"PRIVATE_RESPONSE"}]}}
            {"type":"assistant","sessionId":"source-session","uuid":"side-uuid","isSidechain":true,"parent_tool_use_id":"tool-id","message":{"role":"assistant","content":[]}}
            """.write(to: fixture, atomically: true, encoding: .utf8)

            let result = try runHelper(arguments: ["--summarize-jsonl", fixture.path])
            XCTAssertEqual(result.terminationStatus, 0)
            let data = try XCTUnwrap(result.outputText.data(using: .utf8))
            let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(summary["entry_count"] as? Int, 3)
            XCTAssertEqual(summary["session_id_count"] as? Int, 1)
            XCTAssertEqual(summary["main_uuid_count"] as? Int, 2)
            XCTAssertEqual(summary["sidechain_count"] as? Int, 1)
            XCTAssertFalse(result.outputText.contains("PRIVATE_PROMPT"))
            XCTAssertFalse(result.outputText.contains("PRIVATE_RESPONSE"))
            XCTAssertFalse(result.outputText.contains("source-session"))
        }

        func testRedactorRemovesMachinePathsSecretsAndRawCredentialValues() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = root.appendingPathComponent("sensitive.txt")
            try """
            /Users/private-owner/project/file.swift
            Authorization: Bearer bearer-value
            {"api_key":"sk-supersecretvalue","password":"hunter2"}
            /private/var/folders/aa/private-value
            /var/folders/bb/private-value
            /private/tmp/private-value
            /tmp/private-value
            """.write(to: fixture, atomically: true, encoding: .utf8)

            let result = try runHelper(arguments: ["--redact-text", fixture.path])
            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertFalse(result.outputText.contains("private-owner"))
            XCTAssertFalse(result.outputText.contains("bearer-value"))
            XCTAssertFalse(result.outputText.contains("sk-supersecretvalue"))
            XCTAssertFalse(result.outputText.contains("hunter2"))
            XCTAssertFalse(result.outputText.contains("/private/var/folders"))
            XCTAssertFalse(result.outputText.contains("/var/folders"))
            XCTAssertFalse(result.outputText.contains("/private/tmp"))
            XCTAssertFalse(result.outputText.contains("/tmp/private-value"))
            XCTAssertTrue(result.outputText.contains("<machine-path>"))
            XCTAssertTrue(result.outputText.contains("<redacted>"))
        }

        func testDeterministicFakeClaudeHarnessContracts() throws {
            let script = try RepoRoot.url().appendingPathComponent("Scripts/test_claude_branch_fork_spike.py")
            let result = try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path, "-v"],
                timeout: 90
            )

            XCTAssertEqual(result.terminationStatus, 0, result.outputText)
            XCTAssertTrue(result.outputText.contains("OK"), result.outputText)
        }

        func testLiveSpikeCollectsS0ThroughS11AndWritesRedactedReportWhenEnabled() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment[gateKey] == "1",
                "Live Claude branch spike is opt-in. Set \(gateKey)=1 only after obtaining the required launch approval."
            )

            let executable = try XCTUnwrap(
                ProcessInfo.processInfo.environment["RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE"],
                "Coordinated live runs require an absolute RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE."
            )
            XCTAssertTrue(
                executable.hasPrefix("/"),
                "Coordinated live runs require an absolute RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE."
            )

            let repoRoot = try RepoRoot.url()
            let report = repoRoot.appendingPathComponent(
                "docs/investigations/claude-native-branching-2.1.258.md"
            )
            let result = try runHelper(
                arguments: ["--report", report.path],
                environment: ProcessInfo.processInfo.environment,
                timeout: 180
            )

            XCTAssertEqual(result.terminationStatus, 0, result.outputText)
            let markdown = try String(contentsOf: report, encoding: .utf8)
            XCTAssertTrue(markdown.contains("Blocking result (S0 + S2(a)): **PASS**"))
            XCTAssertTrue(markdown.contains("Installed CLI version: `"))
            XCTAssertTrue(markdown.contains("\"replay_enabled\""))
            XCTAssertTrue(markdown.contains("\"main_chain_evidence\""))
            XCTAssertTrue(markdown.contains("\"source_shape\""))
            XCTAssertTrue(markdown.contains("\"child_shape\""))
            for index in 0 ... 11 {
                XCTAssertTrue(markdown.contains("### S\(index) —"), "Missing S\(index)")
            }
            XCTAssertFalse(markdown.contains("/Users/"))
            XCTAssertTrue(markdown.contains("\"rewind_files_never_used\": true"))
            XCTAssertTrue(markdown.contains("\"repo_prompt_mcp_never_configured\": true"))
        }

        private func runHelper(
            arguments: [String],
            environment: [String: String]? = nil,
            timeout: TimeInterval = 10
        ) throws -> TestProcessResult {
            let script = try RepoRoot.url().appendingPathComponent("Scripts/claude_branch_fork_spike.py")
            return try TestProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path] + arguments,
                environment: environment,
                timeout: timeout
            )
        }

        private func makeTemporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-branch-spike-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }
#endif
