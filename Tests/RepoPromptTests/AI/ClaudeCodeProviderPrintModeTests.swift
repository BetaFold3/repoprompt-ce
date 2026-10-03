import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// PIDs recorded by a hanging fake Claude launch: the `/bin/sh` root, which `ProcessLauncher`
/// makes its own process-group leader, and a same-group descendant. Cancellation is proven by
/// these processes and their group actually disappearing, not by a shell `trap`: children
/// spawned from Swift concurrency inherit the libdispatch worker signal mask (SIGTERM blocked),
/// so a TERM trap may never run even though the runner's SIGKILL escalation reaps the family.
struct FakeClaudeProcessFamily {
    let rootPID: pid_t
    let descendantPID: pid_t

    private struct MalformedRecord: Error {
        let text: String
    }

    static func read(from url: URL) throws -> FakeClaudeProcessFamily {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pids = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t(String($0)) }
        guard pids.count == 2, pids.allSatisfy({ $0 > 1 }), pids[0] != pids[1] else {
            throw MalformedRecord(text: text)
        }
        return FakeClaudeProcessFamily(rootPID: pids[0], descendantPID: pids[1])
    }

    /// Signal 0 probes existence without delivering a signal; EPERM still means the PID exists.
    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        killpg(processGroupID, 0) == 0 || errno == EPERM
    }

    /// True while the root, its descendant, and the root-led process group are all alive. Checked
    /// before cancellation so the post-cancellation `isGone` oracle cannot pass vacuously.
    var isRunning: Bool {
        Self.processExists(rootPID) && Self.processExists(descendantPID) && Self.processGroupExists(rootPID)
    }

    var isGone: Bool {
        !Self.processExists(rootPID) && !Self.processExists(descendantPID) && !Self.processGroupExists(rootPID)
    }
}

/// Oracle shim-auth plan §3 (Workstream 1): every `ClaudeCodeProvider` print-mode launch sends
/// `-p --verbose --output-format stream-json` with the prompt on stdin to the configured
/// executable, parses the final stream-json `result`, retries only transient failures, surfaces
/// shim and authentication refusals once with override-aware copy, and honors cancellation.
final class ClaudeCodeProviderPrintModeTests: XCTestCase {
    // MARK: - Fixtures

    private struct StubLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel _: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(
                effectiveModel: "compatible-fixture-model",
                environmentOverrides: ["RP_CLAUDE_FIXTURE_BACKEND": "compatible"],
                backend: .compatible(.glmZAI)
            )
        }
    }

    /// A recording fake Claude executable configured as the CLI override. Each launch `n`
    /// records NUL-separated argv, stdin, and one environment value, then replays canned
    /// stdout/stderr/exit from `<name>-n` (falling back to `<name>`). A `hang` file makes the
    /// launch block on a descendant `sleep`, recording both PIDs as `pids-n` before `started-n`.
    private final class RecordingClaudeExecutable {
        let root: URL
        let executable: URL
        let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            suiteName = "ClaudeCodeProviderPrintModeTests." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeCodeProviderPrintModeTests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appendingPathComponent("claude")
            try Self.script(root: root.path).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: executable.path
            )
            defaults.set(executable.path, forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))
        }

        func makeProvider(maxRetries: Int = 2, initialRetryBackoff: TimeInterval = 0.01) throws -> ClaudeCodeProvider {
            try ClaudeCodeProvider(
                maxRetries: maxRetries,
                defaults: defaults,
                launchEnvironmentResolver: StubLaunchEnvironmentResolver(),
                initialRetryBackoff: initialRetryBackoff
            )
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        var invocationCount: Int {
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

        func backendEnvironment(_ invocation: Int) throws -> String {
            try String(contentsOf: root.appendingPathComponent("env-\(invocation)"), encoding: .utf8)
        }

        func processFamily(_ invocation: Int) throws -> FakeClaudeProcessFamily {
            try FakeClaudeProcessFamily.read(from: root.appendingPathComponent("pids-\(invocation)"))
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        private static func script(root: String) -> String {
            """
            #!/bin/sh
            root='\(root)'
            n=$(( $(cat "$root/count" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "$root/count"
            for arg in "$@"; do printf '%s\\0' "$arg"; done > "$root/argv-$n"
            cat > "$root/stdin-$n"
            printf '%s' "${RP_CLAUDE_FIXTURE_BACKEND:-}" > "$root/env-$n"
            pick() {
              if [ -f "$root/$1-$n" ]; then printf '%s' "$root/$1-$n"
              elif [ -f "$root/$1" ]; then printf '%s' "$root/$1"
              fi
            }
            if [ -n "$(pick hang)" ]; then
              sleep 30 &
              child=$!
              printf '%s %s\\n' "$$" "$child" > "$root/pids-$n"
              printf started > "$root/started-$n"
              wait "$child"
              exit 0
            fi
            f=$(pick stderr); if [ -n "$f" ]; then cat "$f" >&2; fi
            f=$(pick stdout); if [ -n "$f" ]; then cat "$f"; fi
            code=0
            f=$(pick exit); if [ -n "$f" ]; then code=$(cat "$f"); fi
            printf done > "$root/done-$n"
            exit "$code"
            """
        }
    }

    private var fakes: [RecordingClaudeExecutable] = []

    override func tearDown() {
        for fake in fakes {
            fake.cleanup()
        }
        fakes = []
        super.tearDown()
    }

    private func makeFake() throws -> RecordingClaudeExecutable {
        let fake = try RecordingClaudeExecutable()
        fakes.append(fake)
        return fake
    }

    // MARK: - Stream-json payloads

    private static let initLine =
        #"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-haiku","tools":[],"mcp_servers":[]}"#

    /// Intermediate assistant usage must never be added to the result usage.
    private static func assistantLine(_ text: String) -> String {
        jsonLine([
            "type": "assistant",
            "session_id": "s-1",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
                "usage": ["input_tokens": 999, "output_tokens": 999]
            ]
        ])
    }

    private static func resultLine(
        _ text: String?,
        isError: Bool = false,
        subtype: String = "success",
        extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = [
            "type": "result",
            "subtype": subtype,
            "is_error": isError,
            "total_cost_usd": 0.5,
            "duration_ms": 10,
            "duration_api_ms": 8,
            "num_turns": 1,
            "session_id": "s-1",
            "usage": [
                "input_tokens": 3,
                "cache_creation_input_tokens": 20,
                "cache_read_input_tokens": 100,
                "output_tokens": 7,
                "server_tool_use": ["web_search_requests": 0]
            ]
        ]
        if let text { object["result"] = text }
        object.merge(extra) { _, new in new }
        return jsonLine(object)
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func streamJSON(_ lines: [String], lineEnding: String = "\n") -> String {
        lines.joined(separator: lineEnding) + lineEnding
    }

    private static let expectedPromptTokens = 123
    private static let expectedCompletionTokens = 7

    // MARK: - Error helpers

    private enum ProviderErrorShape: Equatable {
        case invalidConfiguration(String)
        case invalidResponse(String)
    }

    private func shape(of error: Error) -> ProviderErrorShape? {
        switch error as? AIProviderError {
        case let .invalidConfiguration(detail)?:
            .invalidConfiguration(detail)
        case let .invalidResponse(detail)?:
            .invalidResponse(detail)
        default:
            nil
        }
    }

    private func configurationDetail(_ error: Error) -> String? {
        if case let .invalidConfiguration(detail)? = shape(of: error) {
            return detail
        }
        return nil
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    private func assertStreamJSONPrintShape(
        _ argv: [String],
        launch: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(argv.first, "-p", launch, file: file, line: line)
        XCTAssertEqual(argv.count(where: { $0 == "-p" }), 1, launch, file: file, line: line)
        XCTAssertTrue(argv.contains("--verbose"), launch, file: file, line: line)
        XCTAssertEqual(argv.count(where: { $0 == "--output-format" }), 1, launch, file: file, line: line)
        XCTAssertEqual(value(after: "--output-format", in: argv), "stream-json", launch, file: file, line: line)
        for flag in ClaudeCodeProvider.forbiddenPrintModeFlags {
            XCTAssertFalse(argv.contains(flag), "\(launch) passed \(flag)", file: file, line: line)
            XCTAssertFalse(argv.contains { $0.hasPrefix(flag + "=") }, "\(launch) passed \(flag)=", file: file, line: line)
        }
        let disallowed = (value(after: "--disallowedTools", in: argv) ?? "").split(separator: ",").map(String.init)
        for tool in ["Agent", "Task", "WebFetch", "WebSearch"] {
            XCTAssertTrue(disallowed.contains(tool), "\(launch) must block \(tool)", file: file, line: line)
        }
        XCTAssertNotNil(value(after: "--mcp-config", in: argv), launch, file: file, line: line)
        XCTAssertTrue(argv.contains("--strict-mcp-config"), launch, file: file, line: line)
    }

    // MARK: - Launch arguments

    func testPrintModeArgumentsForcePrintVerboseAndOmitSessionAndInputFlags() {
        var options = ClaudeCLIOptions()
        options.printMode = false
        options.verbose = false
        options.model = "haiku"
        options.disallowedTools = ["Task", "Agent"]
        options.mcpConfigPath = "/tmp/empty-mcp.json"
        options.systemPromptOverride = "System rules"

        let args = ClaudeCodeProvider.printModeArguments(for: options)

        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertFalse(args.contains("--output-format"), "the runner applies the output format exactly once")
        XCTAssertTrue(ClaudeCodeProvider.forbiddenPrintModeFlags.isDisjoint(with: args))
        XCTAssertEqual(ClaudeCodeProvider.printModeOutputFormat, .streamJson)
        XCTAssertEqual(ClaudeCodeProvider.printModeOutputFormat.tokens, ["--output-format", "stream-json"])
    }

    // MARK: - Parsing

    func testStreamJSONParserUsesFinalResultAcrossLineShapes() throws {
        let provider = try makeFake().makeProvider()
        let large = String(repeating: "x", count: 200 * 1024) + "END"
        let cases: [(name: String, output: String, text: String)] = [
            (
                "result as the last line",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine("final answer")]),
                "final answer"
            ),
            (
                "unparseable and blank leading lines",
                Self.streamJSON(["not json at all", #"{"type":"#, "   ", Self.initLine, Self.resultLine("after noise")]),
                "after noise"
            ),
            (
                "CRLF line endings",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine("crlf answer")], lineEnding: "\r\n"),
                "crlf answer"
            ),
            (
                "large result over 128 KiB",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine(large)]),
                large
            ),
            (
                "last of several results wins",
                Self.streamJSON([Self.resultLine("earlier"), Self.assistantLine("more"), Self.resultLine("later")]),
                "later"
            ),
            (
                "single result line",
                Self.resultLine("solo") + "\n",
                "solo"
            )
        ]

        for testCase in cases {
            try XCTContext.runActivity(named: testCase.name) { _ in
                let completion = try provider.parseCompletionPayload(Data(testCase.output.utf8))
                XCTAssertEqual(completion.text, testCase.text)
                XCTAssertEqual(
                    completion.promptTokens,
                    Self.expectedPromptTokens,
                    "only the final result's cache-inclusive usage counts"
                )
                XCTAssertEqual(completion.completionTokens, Self.expectedCompletionTokens)
                XCTAssertEqual(completion.cost, 0.5)
            }
        }
    }

    func testLegacySingleObjectAndArrayJSONStillParse() throws {
        let provider = try makeFake().makeProvider()
        let prettyTyped = """
        {
          "type": "result",
          "subtype": "success",
          "total_cost_usd": 1.25,
          "duration_ms": 10,
          "duration_api_ms": 8,
          "is_error": false,
          "num_turns": 1,
          "result": "pretty legacy",
          "session_id": "legacy",
          "usage": {
            "input_tokens": 1,
            "cache_creation_input_tokens": 2,
            "cache_read_input_tokens": 3,
            "output_tokens": 4,
            "server_tool_use": { "web_search_requests": 0 }
          }
        }
        """
        let pretty = try provider.parseCompletionPayload(Data(prettyTyped.utf8))
        XCTAssertEqual(pretty.text, "pretty legacy")
        XCTAssertEqual(pretty.promptTokens, 6)
        XCTAssertEqual(pretty.completionTokens, 4)
        XCTAssertEqual(pretty.cost, 1.25)

        let untyped = try provider.parseCompletionPayload(Data(
            #"{"result":"untyped legacy","usage":{"input_tokens":2,"output_tokens":3}}"#.utf8
        ))
        XCTAssertEqual(untyped.text, "untyped legacy")
        XCTAssertEqual(untyped.promptTokens, 2)
        XCTAssertEqual(untyped.completionTokens, 3)

        let contentBlocks = try provider.parseCompletionPayload(Data(
            #"{"content":[{"text":"a"},{"text":"b"}]}"#.utf8
        ))
        XCTAssertEqual(contentBlocks.text, "ab")

        let verboseArray = "[" + [Self.initLine, Self.assistantLine("draft"), Self.resultLine("array result")]
            .joined(separator: ",") + "]"
        let array = try provider.parseCompletionPayload(Data(verboseArray.utf8))
        XCTAssertEqual(array.text, "array result")
        XCTAssertEqual(array.promptTokens, Self.expectedPromptTokens)

        let untypedArray = try provider.parseCompletionPayload(Data(
            #"[{"content":"from content"},{"other":1}]"#.utf8
        ))
        XCTAssertEqual(untypedArray.text, "from content")
    }

    func testErrorResultsAndMissingResultsThrowTypedProviderErrors() throws {
        let provider = try makeFake().makeProvider()
        let noResult = ProviderErrorShape.invalidResponse("stream-json output contained no result message")
        let cases: [(name: String, output: String, expected: ProviderErrorShape)] = [
            (
                "is_error result",
                Self.streamJSON([Self.initLine, Self.resultLine("Invalid API key · Please run /login", isError: true)]),
                .invalidConfiguration("Invalid API key · Please run /login")
            ),
            (
                "error subtype without text",
                Self.streamJSON([Self.initLine, Self.resultLine(nil, subtype: "error_max_turns")]),
                .invalidConfiguration("Claude CLI reported an error result (error_max_turns).")
            ),
            (
                "error result with errors array",
                Self.streamJSON([
                    Self.initLine,
                    Self.resultLine(nil, isError: true, subtype: "error_during_execution", extra: ["errors": ["boom one", "boom two"]])
                ]),
                .invalidConfiguration("boom one; boom two")
            ),
            (
                "legacy single-object error",
                #"{"type":"result","is_error":true,"result":"legacy failure"}"#,
                .invalidConfiguration("legacy failure")
            ),
            (
                "no result among stream lines",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft only")]),
                noResult
            ),
            (
                "only a system line",
                Self.initLine + "\n",
                noResult
            ),
            (
                "only unparseable lines",
                "garbage\nmore garbage\n",
                noResult
            )
        ]

        for testCase in cases {
            try XCTContext.runActivity(named: testCase.name) { _ in
                XCTAssertThrowsError(try provider.parseCompletionPayload(Data(testCase.output.utf8))) { error in
                    XCTAssertEqual(shape(of: error), testCase.expected)
                }
            }
        }
    }

    func testCLIErrorDetailUsesLastStreamObjectAndKeepsPlainTextFallback() throws {
        let provider = try makeFake().makeProvider()
        let cases: [(name: String, output: String, expected: String?)] = [
            (
                "error result is the last line",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine("Credit balance is too low", isError: true)]),
                "Credit balance is too low"
            ),
            (
                "last object with text wins, nested error message",
                Self.streamJSON([#"{"type":"system","error":"first"}"#, #"{"type":"system","error":{"message":"nested last"}}"#, Self.initLine]),
                "nested last"
            ),
            (
                "CRLF stream",
                Self.streamJSON([Self.initLine, #"{"type":"system","message":"crlf message"}"#], lineEnding: "\r\n"),
                "crlf message"
            ),
            (
                "legacy single object",
                #"{"error":"legacy error"}"#,
                "legacy error"
            ),
            (
                "plain-text fallback",
                "Error: something broke before JSON mode\n",
                "Error: something broke before JSON mode"
            ),
            (
                "plain text keeps non-credential numbers",
                "Error: max_tokens: 4096 exceeds the limit\n",
                "Error: max_tokens: 4096 exceeds the limit"
            ),
            (
                "plain text redacts a bearer credential only",
                "Error: request failed with Authorization: Bearer abcdefghijklmnop0123\n",
                "Error: request failed with Authorization: Bearer <redacted>"
            ),
            (
                "stream result redacts an Anthropic key only",
                Self.streamJSON([Self.initLine, Self.resultLine("Invalid key sk-ant-api03-SECRETSECRET for this org", isError: true)]),
                "Invalid key sk-ant-<redacted> for this org"
            ),
            (
                "stream lines without error text",
                Self.streamJSON([Self.initLine, Self.assistantLine("draft")]),
                nil
            ),
            (
                "empty stdout",
                "",
                nil
            )
        ]

        for testCase in cases {
            XCTContext.runActivity(named: testCase.name) { _ in
                XCTAssertEqual(provider.extractCLIErrorDetail(fromStdout: Data(testCase.output.utf8)), testCase.expected)
            }
        }
    }

    // MARK: - Retry classification and failure copy

    func testRetryClassificationSurfacesRefusalsAndRetriesOnlyTransientFailures() {
        let cases: [(name: String, stderr: String, timedOut: Bool, kind: ClaudeCodeProvider.PrintFailureKind)] = [
            ("shim usage-limit refusal", "claude-rotator shim: All Claude Rotator accounts have reached their usage limits.\n", false, .admissionRefused),
            ("shim refusal mentioning 429", "claude-rotator shim: No eligible Claude Rotator account is available (last error: 429 rate limit).\n", false, .admissionRefused),
            ("shim trust drift", "claude-rotator shim: real Claude executable trust drift (sha256); re-approve with 'claude-rotator trust' before tokens are injected.\n", false, .admissionRefused),
            ("generic ineligible account", "No preferred or reserve account is eligible for new work; adjust the policy.\n", false, .admissionRefused),
            ("authentication wins over network", "Error: authentication failed: network request returned 401 unauthorized\n", false, .authentication),
            ("rate limited", "API Error: 429 Too Many Requests\n", false, .rateLimited),
            ("overloaded", #"API Error: 529 {"type":"overloaded_error"}"# + "\n", false, .overloaded),
            ("bad gateway", "502 Bad Gateway\n", false, .transient),
            ("connection reset", "Error: read ECONNRESET\n", false, .transient),
            ("timed out", "", true, .timedOut),
            ("bare exit without stderr", "", false, .unclassified),
            ("unknown failure", "Error: something unexpected happened\n", false, .unclassified),
            ("code coverage is not an overage refusal", "warning: code coverage data missing\n", false, .unclassified)
        ]

        for testCase in cases {
            XCTAssertEqual(
                ClaudeCodeProvider.classifyPrintFailure(stderr: testCase.stderr, timedOut: testCase.timedOut),
                testCase.kind,
                testCase.name
            )
        }

        let retryable: [ClaudeCodeProvider.PrintFailureKind] = [.timedOut, .rateLimited, .overloaded, .transient]
        let surfaced: [ClaudeCodeProvider.PrintFailureKind] = [.admissionRefused, .authentication, .missingExecutable, .unclassified]
        XCTAssertTrue(retryable.allSatisfy(\.isRetryable))
        XCTAssertFalse(surfaced.contains(where: \.isRetryable))
    }

    func testProcessFailureCopyNamesConfiguredExecutableAndRedactsCredentials() throws {
        let path = "/Users/example/.claude-rotator/shim/bin/claude"
        let configured = CLICommandSelection.configuredExactPath(path)
        let authStderr = "Error: authentication failed for token=abc123secret Authorization: Bearer eyJhbGciOiJ.payload.sig key sk-ant-oat01-SECRETVALUE\n"

        let authDetail = try XCTUnwrap(configurationDetail(ClaudeCodeProvider.processFailureError(
            exitCode: 1,
            stderr: authStderr,
            timedOut: false,
            timeoutSeconds: 30,
            commandSelection: configured
        )))
        XCTAssertTrue(authDetail.contains(path))
        XCTAssertTrue(authDetail.contains("authentication failed"))
        XCTAssertFalse(authDetail.contains("claude login"))
        for secret in ["abc123secret", "eyJhbGciOiJ", "SECRETVALUE"] {
            XCTAssertFalse(authDetail.contains(secret), "leaked \(secret)")
        }

        let refusal = "claude-rotator shim: All Claude Rotator accounts have reached their usage limits."
        let refusalDetail = try XCTUnwrap(configurationDetail(ClaudeCodeProvider.processFailureError(
            exitCode: 1,
            stderr: refusal + "\n",
            timedOut: false,
            timeoutSeconds: 30,
            commandSelection: configured
        )))
        XCTAssertTrue(refusalDetail.contains(path))
        XCTAssertTrue(refusalDetail.contains(refusal))
        XCTAssertFalse(refusalDetail.contains("claude login"))

        let longDetail = try XCTUnwrap(configurationDetail(ClaudeCodeProvider.processFailureError(
            exitCode: 1,
            stderr: String(repeating: "authentication failed again ", count: 200),
            timedOut: false,
            timeoutSeconds: 30,
            commandSelection: configured
        )))
        XCTAssertLessThan(longDetail.count, 800, "the stderr excerpt stays short")

        XCTAssertEqual(
            configurationDetail(ClaudeCodeProvider.processFailureError(
                exitCode: 1,
                stderr: authStderr,
                timedOut: false,
                timeoutSeconds: 30,
                commandSelection: .automatic(command: "claude")
            )),
            "Claude Code is not authenticated. Please run `claude login` in your terminal."
        )
    }

    func testTransientAndUnclassifiedStderrIsSurfacedAsBoundedRedactedExcerpt() {
        let secrets = ["abc123secretvalue", "eyJhbGciOiJ", "SECRETVALUE"]
        let stderr = "API Error: 503 Service Unavailable token=abc123secretvalue Authorization: Bearer eyJhbGciOiJ.payload.sig key sk-ant-oat01-SECRETVALUE\n"
            + String(repeating: "stack frame line\n", count: 400)
        let cases: [(name: String, stderr: String, selection: CLICommandSelection, expectedFragment: String)] = [
            ("transient, configured", stderr, .configuredExactPath("/opt/shim/claude"), "503 Service Unavailable"),
            ("transient, automatic", stderr, .automatic(command: "claude"), "503 Service Unavailable"),
            (
                "unclassified, automatic",
                "Error: model haiku is not available password=hunter2hunter2\n" + String(repeating: "detail ", count: 600),
                .automatic(command: "claude"),
                "model haiku is not available"
            ),
            ("empty stderr", "  \n", .automatic(command: "claude"), "Claude Code failed (exit 1).")
        ]

        for testCase in cases {
            let error = ClaudeCodeProvider.processFailureError(
                exitCode: 1,
                stderr: testCase.stderr,
                timedOut: false,
                timeoutSeconds: 30,
                commandSelection: testCase.selection
            )
            guard case .apiError? = error as? AIProviderError else {
                XCTFail("\(testCase.name): expected apiError, got \(error)")
                continue
            }
            let description = error.localizedDescription
            XCTAssertTrue(description.contains(testCase.expectedFragment), "\(testCase.name): \(description)")
            XCTAssertLessThan(description.count, 400, "\(testCase.name) surfaces a bounded excerpt")
            for secret in secrets + ["hunter2hunter2"] {
                XCTAssertFalse(description.contains(secret), "\(testCase.name) leaked \(secret)")
            }
        }
    }

    // MARK: - Recording fake executable

    func testConnectionTestSurfacesRefusalsAfterOneLaunch() async throws {
        let cases: [(name: String, stderr: String)] = [
            ("shim admission refusal", "claude-rotator shim: All Claude Rotator accounts have reached their usage limits."),
            ("authentication failure", "Error: authentication failed (401 unauthorized)")
        ]

        for testCase in cases {
            let fake = try makeFake()
            try fake.write("stderr", testCase.stderr + "\n")
            try fake.write("exit", "1")

            do {
                _ = try await fake.makeProvider().testConnection(timeout: 20)
                XCTFail("Expected \(testCase.name) to surface")
            } catch {
                let detail = configurationDetail(error)
                XCTAssertNotNil(detail, "\(testCase.name): \(error)")
                XCTAssertTrue(detail?.contains(fake.executable.path) == true, testCase.name)
                XCTAssertFalse(detail?.contains("claude login") == true, testCase.name)
            }
            XCTAssertEqual(fake.invocationCount, 1, "\(testCase.name) skips the no-model fallback launch")
            try assertStreamJSONPrintShape(fake.argv(1), launch: testCase.name)
        }
    }

    func testConnectionTestKeepsNoModelFallbackForOtherFailures() async throws {
        let fake = try makeFake()
        try fake.write("stderr-1", "Error: model haiku is not available for this account\n")
        try fake.write("exit-1", "1")
        try fake.write("stdout-2", Self.streamJSON([Self.initLine, Self.resultLine("OK")]))

        let connected = try await fake.makeProvider().testConnection(timeout: 20)

        XCTAssertTrue(connected)
        XCTAssertEqual(fake.invocationCount, 2, "an unclassified failure still tries the no-model fallback")
        let first = try fake.argv(1)
        let fallback = try fake.argv(2)
        assertStreamJSONPrintShape(first, launch: "haiku attempt")
        assertStreamJSONPrintShape(fallback, launch: "no-model fallback")
        XCTAssertEqual(value(after: "--model", in: first), "haiku")
        XCTAssertNil(value(after: "--model", in: fallback))
    }

    func testConnectionTestSurfacesStdoutRefusalsAfterOneLaunch() async throws {
        let invalidKey = "Invalid API key · Please run /login"
        let usageLimit = "Claude AI usage limit reached|1760000000"
        let cases: [(name: String, stdout: String, exit: String?, fragment: String)] = [
            (
                "non-zero is_error authentication",
                Self.streamJSON([Self.initLine, Self.resultLine(invalidKey, isError: true)]),
                "1",
                invalidKey
            ),
            (
                "exit-zero is_error authentication",
                Self.streamJSON([Self.initLine, Self.resultLine(invalidKey, isError: true)]),
                nil,
                invalidKey
            ),
            (
                "non-zero is_error admission",
                Self.streamJSON([Self.initLine, Self.resultLine(usageLimit, isError: true)]),
                "1",
                usageLimit
            ),
            (
                "exit-zero is_error admission",
                Self.streamJSON([Self.initLine, Self.resultLine(usageLimit, isError: true)]),
                nil,
                usageLimit
            ),
            (
                "non-zero plain-text authentication",
                "Invalid API key: OAuth token sk-ant-oat01-STDOUTSECRET was rejected\n",
                "1",
                "Invalid API key"
            )
        ]

        for testCase in cases {
            let fake = try makeFake()
            try fake.write("stdout", testCase.stdout)
            if let exit = testCase.exit {
                try fake.write("exit", exit)
            }

            do {
                _ = try await fake.makeProvider().testConnection(timeout: 20)
                XCTFail("Expected \(testCase.name) to surface")
            } catch {
                let detail = try XCTUnwrap(configurationDetail(error), "\(testCase.name): \(error)")
                XCTAssertTrue(detail.contains(fake.executable.path), "\(testCase.name): \(detail)")
                XCTAssertTrue(detail.contains(testCase.fragment), "\(testCase.name): \(detail)")
                XCTAssertFalse(detail.contains("claude login"), testCase.name)
                XCTAssertFalse(detail.contains("STDOUTSECRET"), "\(testCase.name) leaked a credential")
            }
            XCTAssertEqual(fake.invocationCount, 1, "\(testCase.name) skips the no-model fallback launch")
            try assertStreamJSONPrintShape(fake.argv(1), launch: testCase.name)
        }
    }

    func testConnectionTestKeepsNoModelFallbackForStdoutNonRefusalErrors() async throws {
        let unavailable = "API Error: 404 model claude-haiku is not available"
        let cases: [(name: String, exit: String?)] = [
            ("non-zero is_error", "1"),
            ("exit-zero is_error", nil)
        ]

        for testCase in cases {
            let fake = try makeFake()
            try fake.write("stdout-1", Self.streamJSON([Self.initLine, Self.resultLine(unavailable, isError: true)]))
            if let exit = testCase.exit {
                try fake.write("exit-1", exit)
            }
            try fake.write("stdout-2", Self.streamJSON([Self.initLine, Self.resultLine("OK")]))

            let connected = try await fake.makeProvider().testConnection(timeout: 20)

            XCTAssertTrue(connected, testCase.name)
            XCTAssertEqual(fake.invocationCount, 2, "\(testCase.name) still tries the no-model fallback")
            let first = try fake.argv(1)
            let fallback = try fake.argv(2)
            XCTAssertEqual(value(after: "--model", in: first), "haiku", testCase.name)
            XCTAssertNil(value(after: "--model", in: fallback), testCase.name)
        }
    }

    func testStdoutRefusalsKeepConfiguredExecutableContextOnCompletionAndCompatibleTest() async throws {
        let invalidKey = "Invalid API key · Please run /login"
        let stdout = Self.streamJSON([Self.initLine, Self.resultLine(invalidKey, isError: true)])
        let launches = ["completeMessage", "testCompatibleBackendConnection"]
        let exits: [String?] = ["1", nil]

        for launch in launches {
            for exit in exits {
                let name = "\(launch), exit \(exit ?? "0")"
                let fake = try makeFake()
                try fake.write("stdout", stdout)
                if let exit {
                    try fake.write("exit", exit)
                }
                let provider = try fake.makeProvider(maxRetries: 2)

                do {
                    if launch == "completeMessage" {
                        _ = try await provider.completeMessage(
                            AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
                            model: .claudeCodeHaiku
                        )
                    } else {
                        _ = try await provider.testCompatibleBackendConnection(.glmZAI, timeout: 20)
                    }
                    XCTFail("Expected \(name) to surface the refusal")
                } catch {
                    let detail = try XCTUnwrap(configurationDetail(error), "\(name): \(error)")
                    XCTAssertTrue(detail.contains(fake.executable.path), "\(name): \(detail)")
                    XCTAssertTrue(detail.contains(invalidKey), "\(name): \(detail)")
                    XCTAssertFalse(detail.contains("claude login"), name)
                }
                XCTAssertEqual(fake.invocationCount, 1, "\(name) is surfaced once without retry")
            }
        }
    }

    func testEmptyOutputDiagnosticsAreBoundedAndRedacted() async throws {
        let stderr = "warning: Authorization: Bearer eyJhbGciOiJ.payload.sig api_key=sk-ant-api03-PREVIEWSECRET\n"
            + String(repeating: "verbose diagnostic line\n", count: 300)

        let compatible = try makeFake()
        try compatible.write("stderr", stderr)
        do {
            _ = try await compatible.makeProvider().testCompatibleBackendConnection(.glmZAI, timeout: 20)
            XCTFail("Expected empty output to fail")
        } catch {
            if case let .invalidResponse(detail)? = shape(of: error) {
                XCTAssertTrue(detail.contains("returned empty output"), detail)
                XCTAssertLessThan(detail.count, 400, "the stderr preview is a bounded excerpt")
                XCTAssertFalse(detail.contains("eyJhbGciOiJ"))
                XCTAssertFalse(detail.contains("PREVIEWSECRET"))
            } else {
                XCTFail("Expected invalidResponse, got \(error)")
            }
        }
        XCTAssertEqual(compatible.invocationCount, 1)

        let standard = try makeFake()
        try standard.write("stderr", stderr)
        do {
            _ = try await standard.makeProvider().testConnection(timeout: 20)
            XCTFail("Expected empty output to fail")
        } catch {
            if case let .invalidResponse(detail)? = shape(of: error) {
                XCTAssertTrue(detail.contains("returned empty output"), detail)
                XCTAssertLessThan(detail.count, 400, "the stderr preview is a bounded excerpt")
                XCTAssertFalse(detail.contains("eyJhbGciOiJ"))
                XCTAssertFalse(detail.contains("PREVIEWSECRET"))
            } else {
                XCTFail("Expected invalidResponse, got \(error)")
            }
        }
        XCTAssertEqual(standard.invocationCount, 2, "empty output is not a refusal, so the fallback still runs")
    }

    func testAllThreePrintModeLaunchesSendStreamJSONShapeToConfiguredExecutable() async throws {
        let fake = try makeFake()
        try fake.write("stdout", Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine("OK")]))
        let provider = try fake.makeProvider()

        let completion = try await provider.completeMessage(
            AIMessage(systemPrompt: "System rules", userMessage: "Hello oracle"),
            model: .claudeCodeHaiku
        )
        XCTAssertEqual(completion.text, "OK")
        XCTAssertEqual(completion.promptTokens, Self.expectedPromptTokens)
        let standardTest = try await provider.testConnection(timeout: 20)
        XCTAssertTrue(standardTest)
        let compatibleTest = try await provider.testCompatibleBackendConnection(.glmZAI, timeout: 20)
        XCTAssertTrue(compatibleTest)

        XCTAssertEqual(fake.invocationCount, 3, "each launch runs the configured executable exactly once")
        let launches = ["completeMessage", "testConnection", "testCompatibleBackendConnection"]
        for (index, launch) in launches.enumerated() {
            let invocation = index + 1
            try assertStreamJSONPrintShape(fake.argv(invocation), launch: launch)
            let stdin = try fake.stdin(invocation)
            XCTAssertFalse(stdin.isEmpty, launch)
            XCTAssertFalse(stdin.hasPrefix("{"), "\(launch) sends plain-text stdin, not stream-json input")
        }
        XCTAssertTrue(try fake.stdin(1).contains("Hello oracle"))
        XCTAssertEqual(try fake.stdin(2), "User: Say OK\n")
        XCTAssertEqual(try fake.stdin(3), "User: Say OK\n")
        let compatibleArgv = try fake.argv(3)
        XCTAssertEqual(value(after: "--model", in: compatibleArgv), "compatible-fixture-model")
        XCTAssertEqual(try fake.backendEnvironment(3), "compatible")
        XCTAssertEqual(try fake.backendEnvironment(1), "")
    }

    func testShimRefusalOnStderrIsSurfacedOnceWithConfiguredExecutableCopy() async throws {
        let fake = try makeFake()
        let refusal = "claude-rotator shim: No eligible Claude Rotator account is available (all accounts rate limited, 429)."
        try fake.write("stderr", refusal + "\n")
        try fake.write("exit", "1")
        let provider = try fake.makeProvider(maxRetries: 2)

        do {
            _ = try await provider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
                model: .claudeCodeHaiku
            )
            XCTFail("Expected the shim refusal to surface")
        } catch {
            let detail = try XCTUnwrap(configurationDetail(error), "\(error)")
            XCTAssertTrue(detail.contains(fake.executable.path))
            XCTAssertTrue(detail.contains(refusal))
            XCTAssertFalse(detail.contains("claude login"))
        }
        XCTAssertEqual(fake.invocationCount, 1, "a fail-closed refusal is never retried or relaunched")
    }

    func testStdoutErrorResultIsSurfacedImmediatelyWithoutRetry() async throws {
        let fake = try makeFake()
        try fake.write(
            "stdout",
            Self.streamJSON([Self.initLine, Self.resultLine("API Error: 429 rate limited", isError: true)])
        )
        try fake.write("exit", "1")
        let provider = try fake.makeProvider(maxRetries: 2)

        do {
            _ = try await provider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
                model: .claudeCodeHaiku
            )
            XCTFail("Expected the stdout error result to surface")
        } catch {
            XCTAssertEqual(shape(of: error), .invalidConfiguration("API Error: 429 rate limited"))
        }
        XCTAssertEqual(fake.invocationCount, 1)
    }

    func testTransientRateLimitIsRetriedAndUnclassifiedExitIsNot() async throws {
        let retrying = try makeFake()
        try retrying.write("stderr-1", "API Error: 429 Too Many Requests\n")
        try retrying.write("exit-1", "1")
        try retrying.write("stdout-2", Self.streamJSON([Self.initLine, Self.resultLine("after retry")]))
        let completion = try await retrying.makeProvider(maxRetries: 2).completeMessage(
            AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
            model: .claudeCodeHaiku
        )
        XCTAssertEqual(completion.text, "after retry")
        XCTAssertEqual(retrying.invocationCount, 2)
        try assertStreamJSONPrintShape(retrying.argv(2), launch: "retry attempt")

        let unclassified = try makeFake()
        try unclassified.write("exit", "1")
        do {
            _ = try await unclassified.makeProvider(maxRetries: 2).completeMessage(
                AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
                model: .claudeCodeHaiku
            )
            XCTFail("Expected the bare exit 1 to surface")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(unclassified.invocationCount, 1, "exit 1 alone is no longer retried")
    }

    func testLargeStreamJSONResultIsReadPastTheTailCaptureLimit() async throws {
        let fake = try makeFake()
        let large = String(repeating: "y", count: 300 * 1024) + "END"
        try fake.write("stdout", Self.streamJSON([Self.initLine, Self.assistantLine("draft"), Self.resultLine(large)]))

        let completion = try await fake.makeProvider().completeMessage(
            AIMessage(systemPrompt: "", userMessage: "Hello oracle"),
            model: .claudeCodeHaiku
        )

        XCTAssertEqual(completion.text.count, large.count)
        XCTAssertTrue(completion.text.hasSuffix("END"))
    }

    // MARK: - Cancellation

    func testCancellationTerminatesRunningChildAndStartsNoFurtherAttempt() async throws {
        let fake = try makeFake()
        try fake.write("hang", "")
        let provider = try fake.makeProvider(maxRetries: 2)

        let task = Task {
            try await provider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "cancel me"),
                model: .claudeCodeHaiku
            )
        }
        try await AsyncTestWait.waitUntil("fake Claude started", timeout: 15) { fake.exists("started-1") }
        let family = try fake.processFamily(1)
        XCTAssertTrue(family.isRunning, "the hanging launch and its descendant are alive before cancellation")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await AsyncTestWait.waitUntil("fake Claude process family exited", timeout: 10) { family.isGone }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.invocationCount, 1, "a cancelled request never starts another attempt")
    }

    func testCancellationDuringRetryBackoffStartsNoFurtherAttempt() async throws {
        let fake = try makeFake()
        try fake.write("stderr", "API Error: 503 Service Unavailable\n")
        try fake.write("exit", "1")
        let provider = try fake.makeProvider(maxRetries: 2, initialRetryBackoff: 30)

        let task = Task {
            try await provider.completeMessage(
                AIMessage(systemPrompt: "", userMessage: "cancel during backoff"),
                model: .claudeCodeHaiku
            )
        }
        try await AsyncTestWait.waitUntil("first attempt finished", timeout: 15) { fake.exists("done-1") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "cancellation interrupts the backoff sleep")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.invocationCount, 1)
    }

    func testCancelledConnectionTestTerminatesChildAndSkipsFallbackLaunch() async throws {
        let fake = try makeFake()
        try fake.write("hang", "")
        let provider = try fake.makeProvider()

        let task = Task { try await provider.testConnection(timeout: 60) }
        try await AsyncTestWait.waitUntil("fake Claude started", timeout: 15) { fake.exists("started-1") }
        let family = try fake.processFamily(1)
        XCTAssertTrue(family.isRunning, "the hanging connection test and its descendant are alive before cancellation")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await AsyncTestWait.waitUntil("fake Claude process family exited", timeout: 10) { family.isGone }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.invocationCount, 1, "a cancelled connection test never launches its fallback model")
    }
}
