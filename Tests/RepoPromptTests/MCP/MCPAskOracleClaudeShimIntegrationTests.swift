import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Oracle shim-auth plan §3 integration tier: a Claude Code `ask_oracle` consultation runs the
/// real Oracle stream engine, `AIQueriesService`, provider pool, and `ClaudeCodeProvider`
/// against a recording fake executable configured as the Claude CLI override. No transport is
/// stubbed. The fake answers only print-mode (`-p`) launches; anything else (for example a
/// version probe) is answered and ignored so counts reflect Oracle launches alone.
@MainActor
final class MCPAskOracleClaudeShimIntegrationTests: XCTestCase {
    // MARK: - Recording fake executable

    private final class FakeClaude {
        let root: URL
        let executable: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPAskOracleClaudeShim-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appendingPathComponent("claude")
            try Self.script(root: root.path).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: executable.path
            )
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        var printInvocationCount: Int {
            let text = (try? String(contentsOf: root.appendingPathComponent("count"), encoding: .utf8)) ?? ""
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        func argv(_ invocation: Int) throws -> [String] {
            let data = try Data(contentsOf: root.appendingPathComponent("argv-\(invocation)"))
            var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0}")
            if parts.last == "" { parts.removeLast() }
            return parts
        }

        func stdin(_ invocation: Int) throws -> String {
            try String(contentsOf: root.appendingPathComponent("stdin-\(invocation)"), encoding: .utf8)
        }

        /// PIDs of a hanging print launch (`hang` file): the shell root and its `sleep` descendant.
        func processFamily(_ invocation: Int) throws -> FakeClaudeProcessFamily {
            try FakeClaudeProcessFamily.read(from: root.appendingPathComponent("pids-\(invocation)"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func script(root: String) -> String {
            """
            #!/bin/sh
            root='\(root)'
            if [ "$1" != "-p" ]; then
              printf 'Claude fixture 1.0\\n'
              exit 0
            fi
            n=$(( $(cat "$root/count" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "$root/count"
            for arg in "$@"; do printf '%s\\0' "$arg"; done > "$root/argv-$n"
            cat > "$root/stdin-$n"
            if [ -f "$root/hang" ]; then
              sleep 30 &
              child=$!
              printf '%s %s\\n' "$$" "$child" > "$root/pids-$n"
              printf started > "$root/started-$n"
              wait "$child"
              exit 0
            fi
            if [ -f "$root/stderr" ]; then cat "$root/stderr" >&2; fi
            if [ -f "$root/stdout" ]; then cat "$root/stdout"; fi
            code=0
            if [ -f "$root/exit" ]; then code=$(cat "$root/exit"); fi
            exit "$code"
            """
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let window: WindowState
        let tabID: UUID
        let connectionID: UUID
        let runID: UUID
        let preset: ModelPreset
        let fake: FakeClaude
        private let overrideKey: String
        private let previousOverride: Any?
        private let previousPresets: [ModelPreset]
        private let previousShowPresets: Bool
        private let previousTemporaryDisable: Bool
        private let previousClaudeCodeConnected: Bool
        private let storageRoot: URL
        private var didCleanup = false

        private init(
            window: WindowState,
            tabID: UUID,
            connectionID: UUID,
            runID: UUID,
            preset: ModelPreset,
            fake: FakeClaude,
            overrideKey: String,
            previousOverride: Any?,
            previousPresets: [ModelPreset],
            previousShowPresets: Bool,
            previousTemporaryDisable: Bool,
            previousClaudeCodeConnected: Bool,
            storageRoot: URL
        ) {
            self.window = window
            self.tabID = tabID
            self.connectionID = connectionID
            self.runID = runID
            self.preset = preset
            self.fake = fake
            self.overrideKey = overrideKey
            self.previousOverride = previousOverride
            self.previousPresets = previousPresets
            self.previousShowPresets = previousShowPresets
            self.previousTemporaryDisable = previousTemporaryDisable
            self.previousClaudeCodeConnected = previousClaudeCodeConnected
            self.storageRoot = storageRoot
        }

        static func make(name: String) async throws -> Fixture {
            let fake = try FakeClaude()
            // Production Oracle builds `ClaudeCodeProvider()` from the standard defaults of the
            // running process; in tests that is the test runner's domain, restored on cleanup.
            let overrideKey = CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
            let previousOverride = UserDefaults.standard.object(forKey: overrideKey)
            UserDefaults.standard.set(fake.executable.path, forKey: overrideKey)

            let settings = GlobalSettingsStore.shared
            let presetsManager = ModelPresetsManager.shared
            let previousPresets = presetsManager.presets
            let previousShowPresets = settings.mcpShowModelPresets()
            let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()

            let previousAutoStart = settings.mcpAutoStart()
            settings.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            settings.setMCPAutoStart(previousAutoStart, commit: false)

            func restoreEarly() {
                WindowStatesManager.shared.unregisterWindowState(window)
                Self.restore(overrideKey: overrideKey, previousOverride: previousOverride)
                fake.cleanup()
            }

            do {
                try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            } catch {
                restoreEarly()
                throw error
            }

            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPAskOracleClaudeShimIntegrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let tabID = UUID()
            workspace.customStoragePath = storageRoot
            workspace.repoPaths = [storageRoot.path]
            workspace.composeTabs = [ComposeTabState(id: tabID)]
            workspace.activeComposeTabID = tabID
            if let index = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                window.workspaceManager.workspaces[index] = workspace
            }
            window.workspaceManager.activeWorkspace = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace)
            await window.oracleViewModel.loadSessionsFromWorkspace()
            window.oracleViewModel.sessions = []

            let preset = ModelPreset(
                name: "ClaudeShim_\(name)",
                model: .claudeCodeHaiku,
                supportedModes: SupportedModes(chat: true, plan: true, review: true)
            )
            presetsManager.presets = [preset]
            settings.setMCPShowModelPresets(true, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            let previousClaudeCodeConnected = window.apiSettingsViewModel.isClaudeCodeConnected
            window.apiSettingsViewModel.isClaudeCodeConnected = true

            let connectionID = UUID()
            let runID = UUID()
            guard window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: window.windowID
            ) else {
                window.apiSettingsViewModel.isClaudeCodeConnected = previousClaudeCodeConnected
                presetsManager.presets = previousPresets
                settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                try? FileManager.default.removeItem(at: storageRoot)
                restoreEarly()
                throw ShimIntegrationTestError.runMappingFailed
            }
            return Fixture(
                window: window,
                tabID: tabID,
                connectionID: connectionID,
                runID: runID,
                preset: preset,
                fake: fake,
                overrideKey: overrideKey,
                previousOverride: previousOverride,
                previousPresets: previousPresets,
                previousShowPresets: previousShowPresets,
                previousTemporaryDisable: previousTemporaryDisable,
                previousClaudeCodeConnected: previousClaudeCodeConnected,
                storageRoot: storageRoot
            )
        }

        private static func restore(overrideKey: String, previousOverride: Any?) {
            if let previousOverride {
                UserDefaults.standard.set(previousOverride, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }

        var store: OracleMCPOperationStore {
            window.oracleViewModel.mcpOperationStore
        }

        func ask(_ extra: [String: Value] = [:], message: String) async throws -> [String: Value] {
            var args: [String: Value] = [
                "message": .string(message),
                "mode": .string("chat"),
                "model": .string(preset.id.uuidString),
                "new_chat": .bool(true)
            ]
            args.merge(extra) { _, new in new }
            return try await call(args)
        }

        func call(_ args: [String: Value]) async throws -> [String: Value] {
            let value = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await window.mcpServer.executeAskOracleForTesting(args: args)
            }
            return try XCTUnwrap(value.objectValue)
        }

        func waitUntilTerminal(_ operationID: UUID) async throws {
            let store = store
            try await AsyncTestWait.waitUntil("operation terminal", timeout: 15) {
                await MainActor.run { store.snapshot(operationID)?.phase.isTerminal == true }
            }
        }

        func cleanup() async {
            guard !didCleanup else { return }
            didCleanup = true
            window.oracleViewModel.mcpOperationStore.teardown()
            await window.oracleViewModel.cancelAllActiveSessionStreams()
            window.oracleViewModel.sessions = []
            window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: connectionID)
            let settings = GlobalSettingsStore.shared
            ModelPresetsManager.shared.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            window.apiSettingsViewModel.isClaudeCodeConnected = previousClaudeCodeConnected
            WindowStatesManager.shared.unregisterWindowState(window)
            Self.restore(overrideKey: overrideKey, previousOverride: previousOverride)
            try? FileManager.default.removeItem(at: storageRoot)
            fake.cleanup()
        }
    }

    private enum ShimIntegrationTestError: Error {
        case runMappingFailed
    }

    private func withFixture(
        _ name: String = #function,
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture.make(name: name.replacingOccurrences(of: "()", with: ""))
        do {
            try await body(fixture)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    private static func resultStream(_ text: String) -> String {
        let result: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": text,
            "total_cost_usd": 0.25,
            "duration_ms": 10,
            "duration_api_ms": 8,
            "num_turns": 1,
            "session_id": "fake-session",
            "usage": [
                "input_tokens": 5,
                "cache_creation_input_tokens": 10,
                "cache_read_input_tokens": 100,
                "output_tokens": 4,
                "server_tool_use": ["web_search_requests": 0]
            ]
        ]
        let resultLine = String(
            decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
            as: UTF8.self
        )
        return [
            #"{"type":"system","subtype":"init","session_id":"fake-session","model":"claude-haiku","tools":[]}"#,
            #"{"type":"assistant","session_id":"fake-session","message":{"role":"assistant","content":[{"type":"text","text":"draft"}]}}"#,
            resultLine
        ].joined(separator: "\n") + "\n"
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    private func assertManagedPrintShape(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(argv.first, "-p", file: file, line: line)
        XCTAssertTrue(argv.contains("--verbose"), file: file, line: line)
        XCTAssertEqual(argv.count(where: { $0 == "--output-format" }), 1, file: file, line: line)
        XCTAssertEqual(value(after: "--output-format", in: argv), "stream-json", file: file, line: line)
        for flag in ClaudeCodeProvider.forbiddenPrintModeFlags {
            XCTAssertFalse(argv.contains(flag), "Oracle passed \(flag)", file: file, line: line)
        }
        let disallowed = (value(after: "--disallowedTools", in: argv) ?? "").split(separator: ",").map(String.init)
        XCTAssertTrue(disallowed.contains("Agent"), file: file, line: line)
        XCTAssertTrue(disallowed.contains("Task"), file: file, line: line)
    }

    private func operationID(in result: [String: Value]) throws -> UUID {
        try XCTUnwrap(result["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    /// Diagnostic and containment text for a tool payload. Slashes stay unescaped so surfaced
    /// executable paths can be matched verbatim.
    private func encodedText(_ object: [String: Value]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(Value.object(object)), as: UTF8.self)
    }

    // MARK: - Tests

    func testAskOracleRunsConfiguredExecutableWithManagedStreamJSONShape() async throws {
        try await withFixture { fixture in
            try fixture.fake.write("stdout", Self.resultStream("Answer from configured Claude executable"))
            let marker = "shim-success-\(UUID().uuidString)"

            let result = try await fixture.ask(message: "Question \(marker)")
            let resultText = try encodedText(result)

            XCTAssertEqual(result["status"]?.stringValue, "completed", resultText)
            XCTAssertEqual(result["response"]?.stringValue, "Answer from configured Claude executable")
            XCTAssertEqual(fixture.fake.printInvocationCount, 1)
            try assertManagedPrintShape(fixture.fake.argv(1))
            let stdin = try fixture.fake.stdin(1)
            XCTAssertTrue(stdin.contains(marker), "the Oracle prompt travels on stdin")
            XCTAssertFalse(stdin.hasPrefix("{"), "stdin is plain text, not stream-json input")
        }
    }

    func testAskOracleSurfacesShimRefusalOnceWithoutRetryOrFallback() async throws {
        try await withFixture { fixture in
            let refusal = "claude-rotator shim: All Claude Rotator accounts have reached their usage limits."
            try fixture.fake.write("stderr", refusal + "\n")
            try fixture.fake.write("exit", "1")

            var surfacedText = ""
            do {
                let result = try await fixture.ask(message: "Question shim-refusal-\(UUID().uuidString)")
                XCTAssertNotEqual(result["status"]?.stringValue, "completed")
                XCTAssertNil(result["response"])
                surfacedText = try encodedText(result)
            } catch {
                surfacedText = String(describing: error) + " " + error.localizedDescription
            }

            XCTAssertTrue(surfacedText.contains(refusal), surfacedText)
            XCTAssertTrue(surfacedText.contains(fixture.fake.executable.path), surfacedText)
            XCTAssertFalse(surfacedText.contains("claude login"), surfacedText)
            XCTAssertEqual(fixture.fake.printInvocationCount, 1, "a shim refusal is never retried or relaunched")
        }
    }

    func testAskOracleCancelTerminatesClaudeChildAndStartsNoFurtherAttempt() async throws {
        try await withFixture { fixture in
            try fixture.fake.write("hang", "")

            let pending = try await fixture.ask(
                ["timeout_seconds": .int(0)],
                message: "Question shim-cancel-\(UUID().uuidString)"
            )
            let operationID = try operationID(in: pending)
            let fake = fixture.fake
            try await AsyncTestWait.waitUntil("fake Claude started", timeout: 30) { fake.exists("started-1") }
            let family = try fake.processFamily(1)
            XCTAssertTrue(family.isRunning, "the hanging Oracle launch and its descendant are alive before cancel")

            let cancelled = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            let cancelledText = try encodedText(cancelled)
            let lane = try XCTUnwrap(cancelled["results"]?.arrayValue?.first?.objectValue, cancelledText)
            XCTAssertEqual(lane["cancel"]?.stringValue, "requested", cancelledText)

            try await AsyncTestWait.waitUntil("fake Claude process family exited", timeout: 15) { family.isGone }
            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .cancelled)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(fake.printInvocationCount, 1, "a cancelled consultation never starts another attempt")
        }
    }
}
