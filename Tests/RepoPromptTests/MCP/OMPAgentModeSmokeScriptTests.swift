import Darwin
import Foundation
import XCTest

final class OMPAgentModeSmokeScriptTests: XCTestCase {
    func testRejectsInvalidArgumentsBeforeCLIInvocation() throws {
        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "--window-id", "0", "--model-id", "ohMyPi:exact/model"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--window-id must be a positive integer"))
        XCTAssertFalse(result.stdout.contains("OMP_AGENT_MODE_EVIDENCE_DIR="))
    }

    func testBoundedCLIRunnerTerminatesOverflowingProcessGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPQualificationBoundedRunnerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fakeCLI = root.appendingPathComponent("rpce-cli-debug")
        let marker = root.appendingPathComponent("child-terminated")
        let fake = """
        #!/usr/bin/env bash
        set -eu
        trap 'exit 0' TERM
        (
          trap 'printf terminated > "$FAKE_TERMINATION_MARKER"; exit 0' TERM
          while :; do sleep 1; done
        ) &
        python3 -c 'import sys; sys.stdout.buffer.write(b"x" * (2 * 1024 * 1024)); sys.stdout.flush()'
        wait
        """
        try fake.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let support = try RepoRoot.url().appendingPathComponent("Scripts/omp_qualification_support.py")
        let stdout = root.appendingPathComponent("stdout")
        let stderr = root.appendingPathComponent("stderr")
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_TERMINATION_MARKER"] = marker.path
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                support.path, "run-cli", fakeCLI.path, "7", "agent_run", "{}",
                stdout.path, stderr.path, "5"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertLessThanOrEqual((try? Data(contentsOf: stdout).count) ?? 0, 1024 * 1024)
    }

    func testBoundedCLIRunnerKillsIgnoringDescendantAfterLeaderExit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPQualificationLeaderExitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fakeCLI = root.appendingPathComponent("rpce-cli-debug")
        let childPID = root.appendingPathComponent("child.pid")
        let fake = """
        #!/usr/bin/env python3
        import os
        import signal
        import subprocess
        import sys
        import time
        code = '''
        import os
        import signal
        import time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(os.environ["FAKE_CHILD_PID"], "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
        while True:
            time.sleep(1)
        '''
        subprocess.Popen(
            [sys.executable, "-c", code],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 2
        while not os.path.exists(os.environ["FAKE_CHILD_PID"]):
            if time.monotonic() >= deadline:
                raise SystemExit(3)
            time.sleep(0.01)
        """
        try fake.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let support = try RepoRoot.url().appendingPathComponent("Scripts/omp_qualification_support.py")
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CHILD_PID"] = childPID.path
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                support.path, "run-cli", fakeCLI.path, "7", "agent_run", "{}",
                root.appendingPathComponent("stdout").path,
                root.appendingPathComponent("stderr").path,
                "5"
            ],
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let pid = try XCTUnwrap(Int(String(contentsOf: childPID, encoding: .utf8)))
        XCTAssertNotEqual(
            kill(Int32(pid), 0),
            0,
            "The bounded runner returned before its TERM-ignoring descendant was gone"
        )
    }

    func testActiveWorkspaceOutputParentIsNotMutatedByOverlapPreflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPQualificationOverlapPreflightTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("active-workspace", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLIContents.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = output.path

        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("overlap preflight failed"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testSyntheticPrivateFlowCapturesJSONAndVerifiesCleanupWithoutApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPAgentModeSmokeScriptTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLIContents.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        let modelID = "ohMyPi:default"
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path

        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", modelID,
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let prefix = "OMP_AGENT_MODE_EVIDENCE_DIR="
        let evidenceLine = try XCTUnwrap(result.stdout.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let evidencePath = String(evidenceLine.dropFirst(prefix.count))
        let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
        XCTAssertEqual(evidence.deletingLastPathComponent().standardizedFileURL, output.standardizedFileURL)

        for name in [
            "manifest.json",
            "start.json",
            "wait.json",
            "workspace_before.json",
            "workspace_after.json",
            "routing_baseline.json",
            "lease_acquire.json",
            "run_routing_history.json",
            "connections.json",
            "session_cleanup.json",
            "omp_connection_history.json",
            "lease_cleanup_release.json",
            "lease_cleanup_status.json"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.appendingPathComponent(name).path), name)
        }

        let manifestData = try Data(contentsOf: evidence.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["classification"] as? String, "private")
        XCTAssertEqual(manifest["scenario"] as? String, "synthetic_deterministic_no_edit_acknowledgement")
        XCTAssertEqual(manifest["caller_supplied_exact_model_id"] as? String, modelID)
        XCTAssertEqual(manifest["contains_raw_credentials_or_tokens"] as? Bool, false)

        let beforeWorkspaceData = try Data(contentsOf: evidence.appendingPathComponent("workspace_before.json"))
        let afterWorkspaceData = try Data(contentsOf: evidence.appendingPathComponent("workspace_after.json"))
        let beforeWorkspace = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeWorkspaceData) as? [String: Any])
        let afterWorkspace = try XCTUnwrap(JSONSerialization.jsonObject(with: afterWorkspaceData) as? [String: Any])
        let beforeTarget = try XCTUnwrap(beforeWorkspace["qualification_target"] as? [String: Any])
        let afterTarget = try XCTUnwrap(afterWorkspace["qualification_target"] as? [String: Any])
        XCTAssertEqual(beforeTarget["active_context_id"] as? String, "66666666-6666-4666-8666-666666666666")
        XCTAssertEqual(beforeTarget["active_context_name"] as? String, "Existing user context")
        XCTAssertEqual(afterTarget["active_context_id"] as? String, "77777777-7777-4777-8777-777777777777")
        XCTAssertEqual(afterTarget["active_context_name"] as? String, "PRIVATE SYNTHETIC OMP Agent Mode smoke")

        let cleanupData = try Data(contentsOf: evidence.appendingPathComponent("session_cleanup.json"))
        let cleanup = try XCTUnwrap(JSONSerialization.jsonObject(with: cleanupData) as? [String: Any])
        XCTAssertEqual(cleanup["status"] as? String, "completed")
        XCTAssertEqual(cleanup["deleted_count"] as? Int, 1)
        XCTAssertEqual(cleanup["skipped_count"] as? Int, 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("cleanup_verified").path))
        let calls = try String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)
        let cleanupCalls = calls.split(separator: "\n").filter { $0.contains(#""op":"cleanup_sessions""#) }
        XCTAssertEqual(
            cleanupCalls.map(String.init),
            [
                #"--raw-json -w 7 -c agent_manage -j {"op":"cleanup_sessions","session_ids":["A1111111-ABCD-4A11-8B11-ABCDEFABCDEF"]}"#
            ]
        )
        XCTAssertFalse(calls.contains("resume_session"))
        XCTAssertTrue(calls.contains(#""workspace_id":"55555555-5555-4555-8555-555555555555""#))
        XCTAssertEqual(disallowedWorkspaceLifecycleCalls(in: calls), [])
        XCTAssertFalse(calls.contains("--launch-app"))
        XCTAssertFalse(calls.contains("\"op\":\"stop"))

        let concreteDefaultFixture = try makeSyntheticFixture(
            name: "OMPAgentModeConcreteDefaultSuccess",
            fakeCLI: fakeCLIContents
        )
        defer { try? FileManager.default.removeItem(at: concreteDefaultFixture.root) }
        var concreteDefaultEnvironment = concreteDefaultFixture.environment
        concreteDefaultEnvironment["FAKE_START_MODEL"] = "smoke-provider/exact-model"
        concreteDefaultEnvironment["FAKE_WAIT_MODEL"] = "smoke-provider/exact-model"
        let concreteDefaultResult = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                concreteDefaultFixture.script.path,
                "--window-id", "7",
                "--model-id", modelID,
                "--output-parent", concreteDefaultFixture.output.path,
                "--timeout", "30"
            ],
            environment: concreteDefaultEnvironment
        )
        XCTAssertEqual(concreteDefaultResult.status, 0, concreteDefaultResult.stderr)

        let qualificationFailures: [(name: String, environment: [String: String], expectsCancel: Bool)] = [
            (
                "default concrete model mismatch",
                ["FAKE_START_MODEL": "provider-a/model-a", "FAKE_WAIT_MODEL": "provider-b/model-b"],
                false
            ),
            (
                "completed wait bad acknowledgement",
                ["FAKE_WAIT_ACK": "WRONG_ACK"],
                false
            ),
            (
                "start metadata mismatch after valid identifiers",
                ["FAKE_START_AGENT_ID": "wrong-agent"],
                true
            )
        ]
        for scenario in qualificationFailures {
            let fixture = try makeSyntheticFixture(
                name: "OMPAgentModeQualificationFailure",
                fakeCLI: fakeCLIContents
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var scenarioEnvironment = fixture.environment
            scenario.environment.forEach { scenarioEnvironment[$0.key] = $0.value }
            let scenarioResult = try run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    fixture.script.path,
                    "--window-id", "7",
                    "--model-id", modelID,
                    "--output-parent", fixture.output.path,
                    "--timeout", "30"
                ],
                environment: scenarioEnvironment
            )
            XCTAssertNotEqual(scenarioResult.status, 0, scenario.name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("session_cleaned").path),
                scenario.name
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("cleanup_verified").path),
                scenario.name
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("lease_active").path),
                scenario.name
            )
            let scenarioCalls = try String(
                contentsOf: fixture.state.appendingPathComponent("calls.log"),
                encoding: .utf8
            )
            XCTAssertEqual(
                scenarioCalls.contains(#""op":"cancel""#),
                scenario.expectsCancel,
                scenario.name
            )
            XCTAssertTrue(
                scenarioCalls.contains(
                    #""op":"cleanup_sessions","session_ids":["A1111111-ABCD-4A11-8B11-ABCDEFABCDEF"]"#
                ),
                scenario.name
            )
        }
    }

    func testWorkspaceLifecycleCallAllowlistRejectsSyntheticDisallowedCall() {
        let calls = """
        --raw-json -w 7 -c __repoprompt_debug_diagnostics -j {"op":"routing_snapshot"}
        --raw-json -w 7 -c manage_workspaces -j {"op":"switch_workspace"}
        --raw-json -w 7 -c __repoprompt_debug_diagnostics -j {"op":"relaunch_app"}
        --raw-json -w 7 -c agent_run -j {"op":"start","workspace_action":{"verb":"switch_workspace"}}
        --raw-json -w 7 -c agent_run -j {"op":"start","worktree":{"action":"create_worktree"}}
        --raw-json -w 7 -c agent_run -j {"op":"start","message":{"switch_workspace":true}}
        --raw-json -w 7 -c agent_run -j {"op":"start","message":{"external_path":"/tmp"}}
        --raw-json --relaunch-app -w 7 -c agent_manage -j {"op":"list_agents"}
        --raw-json -w 7 -w 8 -c agent_manage -j {"op":"list_agents"}
        --raw-json -w 7 -c agent_manage -c agent_run -j {"op":"list_agents"}
        --raw-json -w 7 -c agent_manage --external-path /tmp -j {"op":"list_agents"}
        --raw-json -w 7 -c agent_manage --create-worktree -j {"op":"list_agents"}
        """
        let violations = disallowedWorkspaceLifecycleCalls(in: calls)
        XCTAssertEqual(violations.count, 11)
        XCTAssertTrue(violations.contains { $0.contains("manage_workspaces") })
        XCTAssertTrue(violations.contains { $0.contains("relaunch_app") })
        XCTAssertTrue(violations.contains { $0.contains("workspace_action") })
        XCTAssertTrue(violations.contains { $0.contains("create_worktree") })
        XCTAssertTrue(violations.contains { $0.contains("switch_workspace") })
        XCTAssertTrue(violations.contains { $0.contains("external_path") })
    }

    func testSyntheticFlowRejectsRunScopedToolEventAndReleasesLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPAgentModeSmokeScriptToolEventTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        let adversarial = fakeCLIContents.replacingOccurrences(
            of: #"{"seq":16,"run_id":"%s","event":"pid_gate_wait_completed""#,
            with: #"{"seq":16,"run_id":"%s","event":"tool_call_observed""#
        )
        try adversarial.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("cleanup_verified").path))
    }

    func testSyntheticFlowRejectsMalformedHelperStartIdentityValues() throws {
        let mutations = [
            (#""helper_process_start_seconds":"123457""#, #""helper_process_start_seconds":"-1""#),
            (#""helper_process_start_microseconds":"111""#, #""helper_process_start_microseconds":"1000000""#),
            (#""helper_peer_start_seconds":123457"#, #""helper_peer_start_seconds":"123457""#)
        ]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try makeSyntheticFixture(
                name: "OMPMalformedStartIdentity\(index)",
                fakeCLI: fakeCLIContents.replacingOccurrences(of: mutation.0, with: mutation.1)
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    fixture.script.path,
                    "--window-id", "7",
                    "--model-id", "ohMyPi:smoke-provider/exact-model",
                    "--output-parent", fixture.output.path,
                    "--timeout", "30"
                ],
                environment: fixture.environment
            )
            XCTAssertNotEqual(result.status, 0, "mutation \(index) unexpectedly passed")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("cleanup_verified").path),
                "mutation \(index) did not complete cleanup"
            )
        }
    }

    func testTerminalRawSetStatusIsAcceptedAsBookkeeping() throws {
        try assertTerminalRawToolContract(toolName: "set_status", nonBookkeepingCount: 0, expectsSuccess: true)
    }

    func testTerminalRawReadFileFailsZeroToolProofAndReleasesLease() throws {
        try assertTerminalRawToolContract(toolName: "read_file", nonBookkeepingCount: 1, expectsSuccess: false)
    }

    func testTerminalGateAcceptsBookkeepingOnlyRawLiveness() throws {
        try assertTerminalEvidence(
            fields: bookkeepingTerminalFields,
            expectsSuccess: true
        )
    }

    func testTerminalGateAcceptsZeroRawToolEvidence() throws {
        try assertTerminalEvidence(
            fields: #""qualification_raw_tool_call_count":0,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":[],"qualification_raw_canonical_tool_names":[],"qualification_raw_nonbookkeeping_tool_call_count":0,"qualification_raw_nonbookkeeping_tool_names":[],"non_bookkeeping_tool_call_count":0,"non_bookkeeping_tool_names":[],"active_tool_scope_count":0"#,
            expectsSuccess: true
        )
    }

    func testTerminalGateRejectsContradictoryZeroRawToolEvidence() throws {
        try assertTerminalEvidence(
            fields: #""qualification_raw_tool_call_count":0,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["set_status"],"qualification_raw_canonical_tool_names":["set_status"],"qualification_raw_nonbookkeeping_tool_call_count":0,"qualification_raw_nonbookkeeping_tool_names":[],"non_bookkeeping_tool_call_count":0,"non_bookkeeping_tool_names":[],"active_tool_scope_count":0"#,
            expectsSuccess: false,
            stderrContains: "zero raw call count contradicts observed tool names"
        )
    }

    func testTerminalGateAcceptsServerPrefixedBookkeepingRawNames() throws {
        try assertTerminalEvidence(
            fields: #""qualification_raw_tool_call_count":2,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["mcp__RepoPromptCE__bind_context","mcp__RepoPromptCE__set_status"],"qualification_raw_canonical_tool_names":["bind_context","set_status"],"qualification_raw_nonbookkeeping_tool_call_count":0,"qualification_raw_nonbookkeeping_tool_names":[],"non_bookkeeping_tool_call_count":0,"non_bookkeeping_tool_names":[],"active_tool_scope_count":0"#,
            expectsSuccess: true
        )
    }

    func testTerminalGateRejectsNonBookkeepingRawTool() throws {
        try assertTerminalEvidence(
            fields: #""qualification_raw_tool_call_count":3,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["bind_context","read_file","set_status"],"qualification_raw_canonical_tool_names":["bind_context","read_file","set_status"],"qualification_raw_nonbookkeeping_tool_call_count":1,"qualification_raw_nonbookkeeping_tool_names":["read_file"],"non_bookkeeping_tool_call_count":1,"non_bookkeeping_tool_names":["read_file"],"active_tool_scope_count":0"#,
            expectsSuccess: false,
            stderrContains: "terminal zero-tool evidence contained non-bookkeeping"
        )
    }

    func testTerminalGateRejectsMissingNonBookkeepingEvidence() throws {
        try assertTerminalEvidence(
            fields: #""qualification_raw_tool_call_count":2,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["bind_context","set_status"],"qualification_raw_canonical_tool_names":["bind_context","set_status"],"active_tool_scope_count":0"#,
            expectsSuccess: false,
            stderrContains: "missing terminal tool evidence"
        )
    }

    func testAppWaitTimeoutEvidenceBeatsCLIProcessTimeout() throws {
        let fixture = try makeSyntheticFixture(name: "OMPAgentModeAppWaitTimeoutTests", fakeCLI: fakeCLIContents)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var environment = fixture.environment
        environment["FAKE_APP_WAIT_TIMED_OUT"] = "1"
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                fixture.script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", fixture.output.path,
                "--timeout", "10"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("app-side wait_result=timed_out"), result.stderr)
        XCTAssertFalse(result.stderr.contains("agent_run call failed"), result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("cleanup_verified").path))
    }

    func testCleanupContinuesThroughCancellationAndReleaseFailuresToAuthoritativeStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPAgentModeSmokeCleanupFailureTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLIContents.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path
        environment["FAKE_CLEANUP_SKIPS_ACTIVE"] = "1"

        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("exact-session cleanup did not prove deletion of only session"))
        XCTAssertFalse(result.stderr.contains("cleanup action release failed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("cleanup_verified").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("lease_active").path))
        let calls = try String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertFalse(calls.contains { $0.contains("\"op\":\"cancel\"") })
        let sessionCleanupIndices = calls.indices.filter {
            calls[$0].contains("\"op\":\"cleanup_sessions\"")
        }
        XCTAssertEqual(sessionCleanupIndices.count, 2)
        XCTAssertTrue(sessionCleanupIndices.allSatisfy {
            calls[$0].contains(
                #""session_ids":["A1111111-ABCD-4A11-8B11-ABCDEFABCDEF"]"#
            )
        })
        let releaseIndex = try XCTUnwrap(calls.firstIndex { $0.contains("\"action\":\"release\"") })
        let statusIndex = try XCTUnwrap(calls.lastIndex { $0.contains("\"action\":\"status\"") })
        XCTAssertLessThan(try XCTUnwrap(sessionCleanupIndices.last), releaseIndex)
        XCTAssertLessThan(releaseIndex, statusIndex)

        let prefix = "OMP_AGENT_MODE_EVIDENCE_DIR="
        let evidenceLine = try XCTUnwrap(result.stdout.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let evidence = URL(fileURLWithPath: String(evidenceLine.dropFirst(prefix.count)), isDirectory: true)
        let cleanupData = try Data(contentsOf: evidence.appendingPathComponent("session_cleanup.json"))
        let cleanup = try XCTUnwrap(JSONSerialization.jsonObject(with: cleanupData) as? [String: Any])
        XCTAssertEqual(cleanup["status"] as? String, "partial")
        XCTAssertEqual(cleanup["deleted_count"] as? Int, 0)
        XCTAssertEqual(cleanup["skipped_count"] as? Int, 1)
        let skipped = try XCTUnwrap(cleanup["skipped_sessions"] as? [[String: Any]])
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped[0]["reason"] as? String, "skipped_active")
    }

    func testRejectedAcquireResponseReleasesMatchingControllerLeaseAndVerifiesInactive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPAgentModeAcquireRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLIContents.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path
        environment["FAKE_INVALID_ACQUIRE_RESPONSE"] = "1"

        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("failed local validation"), result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("cleanup_verified").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("lease_active").path))
        let calls = try String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)
        XCTAssertTrue(calls.contains("\"action\":\"release\""))
        XCTAssertGreaterThanOrEqual(calls.components(separatedBy: "\"action\":\"status\"").count - 1, 2)
    }

    func testRejectedAcquireResponseDoesNotReleaseMismatchedOwnerLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPAgentModeAcquireMismatchTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCLI = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLIContents.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path
        environment["FAKE_INVALID_ACQUIRE_RESPONSE"] = "1"
        environment["FAKE_STATUS_OWNER_MISMATCH"] = "1"

        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", output.path,
                "--timeout", "30"
            ],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("did not match the active controller-owned lease"), result.stderr)
        let calls = try String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)
        XCTAssertFalse(calls.contains("\"action\":\"release\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("lease_active").path))
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let captureRoot = FileManager.default.temporaryDirectory
        let stdoutURL = captureRoot.appendingPathComponent("omp-smoke-stdout-\(UUID().uuidString)")
        let stderrURL = captureRoot.appendingPathComponent("omp-smoke-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        return try (
            process.terminationStatus,
            String(decoding: Data(contentsOf: stdoutURL), as: UTF8.self),
            String(decoding: Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    private func assertTerminalRawToolContract(
        toolName: String,
        nonBookkeepingCount: Int,
        expectsSuccess: Bool
    ) throws {
        let nonBookkeepingNames = nonBookkeepingCount == 0 ? "[]" : #"["\#(toolName)"]"#
        let fields = #""qualification_raw_tool_call_count":1,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["\#(toolName)"],"qualification_raw_canonical_tool_names":["\#(toolName)"],"qualification_raw_nonbookkeeping_tool_call_count":\#(nonBookkeepingCount),"qualification_raw_nonbookkeeping_tool_names":\#(nonBookkeepingNames),"non_bookkeeping_tool_call_count":\#(nonBookkeepingCount),"non_bookkeeping_tool_names":\#(nonBookkeepingNames),"active_tool_scope_count":0"#
        try assertTerminalEvidence(fields: fields, expectsSuccess: expectsSuccess)
    }

    private func assertTerminalEvidence(
        fields: String,
        expectsSuccess: Bool,
        stderrContains: String? = nil
    ) throws {
        let fixture = try makeSyntheticFixture(
            name: "OMPAgentModeTerminalEvidenceTests",
            fakeCLI: fakeCLIContents.replacingOccurrences(of: bookkeepingTerminalFields, with: fields)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                fixture.script.path,
                "--window-id", "7",
                "--model-id", "ohMyPi:smoke-provider/exact-model",
                "--output-parent", fixture.output.path,
                "--timeout", "30"
            ],
            environment: fixture.environment
        )
        XCTAssertEqual(result.status == 0, expectsSuccess, result.stderr)
        if let stderrContains {
            XCTAssertTrue(result.stderr.contains(stderrContains), result.stderr)
        }
        if !expectsSuccess {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("cleanup_verified").path))
        }
    }

    private func disallowedWorkspaceLifecycleCalls(in calls: String) -> [String] {
        let lifecycleVerbs = Set([
            "launch_app", "relaunch_app", "stop", "stop_app",
            "switch_workspace", "create_workspace", "delete_workspace", "manage_workspaces",
            "resume", "resume_session", "create_worktree", "delete_worktree"
        ])

        func containsLifecycleMutation(_ value: Any) -> Bool {
            if let text = value as? String {
                return lifecycleVerbs.contains(text.lowercased())
            }
            if let values = value as? [Any] {
                return values.contains(where: containsLifecycleMutation)
            }
            if let object = value as? [String: Any] {
                return object.contains { key, child in
                    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                    return lifecycleVerbs.contains(normalized)
                        || normalized.contains("worktree")
                        || normalized.contains("external_path")
                        || containsLifecycleMutation(child)
                }
            }
            return false
        }

        func hasExpectedValueTypes(tool: String, operation: String, payload: [String: Any]) -> Bool {
            func strings(_ keys: [String]) -> Bool {
                keys.allSatisfy { payload[$0] == nil || payload[$0] is String }
            }
            func booleans(_ keys: [String]) -> Bool {
                keys.allSatisfy { payload[$0] == nil || payload[$0] is Bool }
            }
            func integers(_ keys: [String]) -> Bool {
                keys.allSatisfy { key in
                    guard let value = payload[key] else { return true }
                    guard let number = value as? NSNumber else { return false }
                    return CFGetTypeID(number) != CFBooleanGetTypeID()
                        && number.doubleValue.rounded(.towardZero) == number.doubleValue
                }
            }
            switch (tool, operation) {
            case ("agent_manage", "list_agents"):
                return true
            case ("agent_manage", "cleanup_sessions"):
                return payload["session_ids"] as? [String] != nil
            case ("agent_run", "start"):
                return strings(["model_id", "_omp_qualification_lease_id", "workspace_id", "session_name", "message"])
                    && booleans(["detach"])
            case ("agent_run", "wait"):
                return strings(["session_id"]) && integers(["timeout"])
            case ("agent_run", "cancel"):
                return strings(["session_id", "run_id"])
            case ("__repoprompt_debug_diagnostics", "routing_snapshot"):
                return booleans(["include_records", "include_windows"])
            case ("__repoprompt_debug_diagnostics", "routing_sequence_baseline"):
                return true
            case ("__repoprompt_debug_diagnostics", "run_routing_history"):
                return strings(["run_id"]) && integers(["limit"])
            case ("__repoprompt_debug_diagnostics", "connections"):
                return booleans(["include_identity"])
            case ("__repoprompt_debug_diagnostics", "connection_history"):
                return strings(["connection_id"]) && integers(["limit"])
            case ("__repoprompt_debug_diagnostics", "omp_qualification_lease"):
                return strings(["action", "lease_id"]) && integers(["duration_seconds", "owner_pid"])
            default:
                return false
            }
        }

        func allowedKeys(tool: String, operation: String, payload: [String: Any]) -> Set<String>? {
            switch (tool, operation) {
            case ("agent_manage", "list_agents"):
                return ["op"]
            case ("agent_manage", "cleanup_sessions"):
                return ["op", "session_ids"]
            case ("agent_run", "start"):
                return [
                    "op", "model_id", "_omp_qualification_lease_id", "workspace_id",
                    "session_name", "message", "detach"
                ]
            case ("agent_run", "wait"):
                return ["op", "session_id", "timeout"]
            case ("agent_run", "cancel"):
                return ["op", "session_id", "run_id"]
            case ("__repoprompt_debug_diagnostics", "routing_snapshot"):
                return ["op", "include_records", "include_windows"]
            case ("__repoprompt_debug_diagnostics", "routing_sequence_baseline"):
                return ["op"]
            case ("__repoprompt_debug_diagnostics", "run_routing_history"):
                return ["op", "run_id", "limit"]
            case ("__repoprompt_debug_diagnostics", "connections"):
                return ["op", "include_identity"]
            case ("__repoprompt_debug_diagnostics", "connection_history"):
                return ["op", "connection_id", "limit"]
            case ("__repoprompt_debug_diagnostics", "omp_qualification_lease"):
                guard let action = payload["action"] as? String,
                      ["acquire", "release", "status"].contains(action)
                else { return nil }
                return ["op", "action", "duration_seconds", "owner_pid", "lease_id"]
            default:
                return nil
            }
        }

        return calls.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            let fields = line.split(separator: " ")
            guard let toolFlag = fields.firstIndex(of: "-c"),
                  fields.indices.contains(toolFlag + 1),
                  let payloadRange = line.range(of: " -j ")
            else {
                return "unparseable CLI call: \(line)"
            }
            let tool = String(fields[toolFlag + 1])
            let prefix = String(line[..<payloadRange.lowerBound])
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            // payloadRange starts at the separator before -j; the exact single -j
            // delimiter is therefore validated separately from the argv prefix.
            guard prefix == ["--raw-json", "-w", "7", "-c", tool] else {
                return "disallowed CLI argv: \(prefix.joined(separator: " "))"
            }
            let payloadText = String(line[payloadRange.upperBound...])
            guard let payloadData = payloadText.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let operation = payload["op"] as? String,
                  let permittedKeys = allowedKeys(tool: tool, operation: operation, payload: payload),
                  Set(payload.keys).isSubset(of: permittedKeys),
                  hasExpectedValueTypes(tool: tool, operation: operation, payload: payload),
                  !containsLifecycleMutation(payload)
            else {
                return "disallowed smoke call: tool=\(tool) payload=\(payloadText)"
            }
            return nil
        }
    }

    private var bookkeepingTerminalFields: String {
        #""qualification_raw_tool_call_count":2,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["bind_context","set_status"],"qualification_raw_canonical_tool_names":["bind_context","set_status"],"qualification_raw_nonbookkeeping_tool_call_count":0,"qualification_raw_nonbookkeeping_tool_names":[],"non_bookkeeping_tool_call_count":0,"non_bookkeeping_tool_names":[],"active_tool_scope_count":0"#
    }

    private func makeSyntheticFixture(
        name: String,
        fakeCLI: String
    ) throws -> (root: URL, output: URL, state: URL, script: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("rpce-cli-debug")
        try fakeCLI.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let script = try RepoRoot.url().appendingPathComponent("Scripts/smoke_omp_agent_mode.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_STATE_DIR"] = state.path
        environment["FAKE_REPO_ROOT"] = try RepoRoot.url().path
        return (root, output, state, script, environment)
    }

    private var fakeCLIContents: String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$*" >> "$FAKE_STATE_DIR/calls.log"
        [[ "$#" -eq 7 && "$1" == "--raw-json" && "$2" == "-w" && "$4" == "-c" && "$6" == "-j" ]] || exit 88
        tool=""
        payload=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -c) tool="$2"; shift 2 ;;
            -j) payload="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        session_id="A1111111-ABCD-4A11-8B11-ABCDEFABCDEF"
        run_id="B2222222-BCDE-4B22-8C22-BCDEFABCDEF0"
        connection_id="33333333-3333-4333-8333-333333333333"
        lease_id="44444444-4444-4444-8444-444444444444"
        if [[ "${FAKE_FAIL_WAIT:-0}" == "1" && "$tool" == "agent_run" && "$payload" != *'"op":"start"'* && "$payload" != *'"op":"cancel"'* ]]; then
          printf 'invalid wait response\\n'
          exit 0
        fi
        if [[ "${FAKE_FAIL_CANCEL:-0}" == "1" && "$tool" == "agent_run" && "$payload" == *'"op":"cancel"'* ]]; then
          printf 'invalid cancel response\\n'
          exit 0
        fi
        if [[ "${FAKE_FAIL_RELEASE:-0}" == "1" && "$tool" == "__repoprompt_debug_diagnostics" && "$payload" == *'"action":"release"'* ]]; then
          printf 'invalid release response\\n'
          exit 0
        fi
        case "$tool" in
          agent_manage)
            if [[ "$payload" == '{"op":"list_agents"}' ]]; then
              printf '{"result":{"structuredContent":{"agents":[{"name":"Oh My Pi","available":true,"models":[{"model_id":"ohMyPi:default","agent_id":"ohMyPi"},{"model_id":"ohMyPi:smoke-provider/exact-model","agent_id":"ohMyPi"}]}],"task_labels":[]}}}\\n'
            elif [[ "$payload" == '{"op":"cleanup_sessions","session_ids":["'"$session_id"'"]}' ]]; then
              if [[ "${FAKE_CLEANUP_SKIPS_ACTIVE:-0}" == "1" ]]; then
                printf '{"result":{"structuredContent":{"status":"partial","deleted_count":0,"skipped_count":1,"deleted_sessions":[],"skipped_sessions":[{"session_id":"%s","name":"PRIVATE SYNTHETIC OMP Agent Mode smoke","reason":"skipped_active"}]}}}\\n' "$session_id"
              else
                : > "$FAKE_STATE_DIR/session_cleaned"
                printf '{"result":{"structuredContent":{"status":"completed","deleted_count":1,"skipped_count":0,"deleted_sessions":[{"session_id":"%s","name":"PRIVATE SYNTHETIC OMP Agent Mode smoke"}],"skipped_sessions":[]}}}\\n' "$session_id"
              fi
            else
              exit 89
            fi
            ;;
          agent_run)
            if [[ "$payload" == *'"op":"start"'* ]]; then
              : > "$FAKE_STATE_DIR/session_started"
              start_agent_id="${FAKE_START_AGENT_ID:-ohMyPi}"
              if [[ "$payload" == *'"model_id":"ohMyPi:default"'* ]]; then
                start_model="${FAKE_START_MODEL:-default}"
              else
                start_model="${FAKE_START_MODEL:-smoke-provider/exact-model}"
              fi
              printf '{"status":"running","session_id":"%s","run_id":"%s","agent":{"id":"%s","model":"%s"}}\\n' "$session_id" "$run_id" "$start_agent_id" "$start_model"
            elif [[ "$payload" == *'"op":"cancel"'* ]]; then
              printf '{"status":"cancelled","session_id":"%s","run_id":"%s"}\\n' "$session_id" "$run_id"
            else
              if [[ "${FAKE_APP_WAIT_TIMED_OUT:-0}" == "1" ]]; then
                app_timeout="$(printf '%s' "$payload" | sed -E 's/.*"timeout":([0-9]+).*/\\1/')"
                sleep "$((app_timeout + 1))"
                printf '{"status":"running","session_id":"%s","run_id":"%s","agent":{"id":"ohMyPi","model":"smoke-provider/exact-model"},"_meta":{"wait_result":"timed_out"}}\\n' "$session_id" "$run_id"
              else
                wait_ack="${FAKE_WAIT_ACK:-OMP_AGENT_MODE_SMOKE_OK}"
                wait_model="${FAKE_WAIT_MODEL:-smoke-provider/exact-model}"
                printf '{"status":"completed","session_id":"%s","run_id":"%s","assistant_text":"%s","agent":{"id":"ohMyPi","model":"%s"}}\\n' "$session_id" "$run_id" "$wait_ack" "$wait_model"
              fi
            fi
            ;;
          __repoprompt_debug_diagnostics)
            if [[ "$payload" == *'"op":"routing_snapshot"'* ]]; then
              if [[ -f "$FAKE_STATE_DIR/session_started" ]]; then
                active_context_id="77777777-7777-4777-8777-777777777777"
                active_context_name="PRIVATE SYNTHETIC OMP Agent Mode smoke"
              else
                active_context_id="66666666-6666-4666-8666-666666666666"
                active_context_name="Existing user context"
              fi
              printf '{"ok":true,"op":"routing_snapshot","windows":[{"window_id":7,"workspace_id":"55555555-5555-4555-8555-555555555555","workspace_name":"fixture","workspace_instance_number":1,"active_context_id":"%s","active_context_name":"%s","repo_paths":["%s"]}]}\\n' "$active_context_id" "$active_context_name" "$FAKE_REPO_ROOT"
            elif [[ "$payload" == *'"op":"routing_sequence_baseline"'* ]]; then
              printf '{"ok":true,"op":"routing_sequence_baseline","run_routing_sequence":10,"connection_sequence":20}\\n'
            elif [[ "$payload" == *'"op":"omp_qualification_lease"'* && "$payload" == *'"action":"acquire"'* ]]; then
              owner_pid="$(printf '%s' "$payload" | sed -E 's/.*"owner_pid":([0-9]+).*/\\1/')"
              printf '%s' "$owner_pid" > "$FAKE_STATE_DIR/lease_owner_pid"
              : > "$FAKE_STATE_DIR/lease_active"
              action="acquire"
              if [[ "${FAKE_INVALID_ACQUIRE_RESPONSE:-0}" == "1" ]]; then action="invalid-local-fixture"; fi
              printf '{"ok":true,"op":"omp_qualification_lease","action":"%s","active":true,"lease_id":"%s","owner_connection_id":"%s","owner_pid":%s,"owner_process_start_seconds":123456,"owner_process_start_microseconds":789,"expires_at_ms":9999999999999,"session_id":null,"run_id":null}\\n' "$action" "$lease_id" "$connection_id" "$owner_pid"
            elif [[ "$payload" == *'"op":"omp_qualification_lease"'* && "$payload" == *'"action":"release"'* ]]; then
              : > "$FAKE_STATE_DIR/cleanup_verified"
              rm -f "$FAKE_STATE_DIR/lease_active"
              printf '{"ok":true,"op":"omp_qualification_lease","action":"release","active":false,"lease_id":"%s","owner_connection_id":"%s","owner_pid":1,"expires_at_ms":9999999999999,"session_id":"%s","run_id":"%s"}\\n' "$lease_id" "$connection_id" "$session_id" "$run_id"
            elif [[ "$payload" == *'"op":"omp_qualification_lease"'* ]]; then
              if [[ -f "$FAKE_STATE_DIR/lease_active" ]]; then
                owner_pid="$(cat "$FAKE_STATE_DIR/lease_owner_pid")"
                if [[ "${FAKE_STATUS_OWNER_MISMATCH:-0}" == "1" ]]; then owner_pid="$((owner_pid + 1))"; fi
                printf '{"ok":true,"op":"omp_qualification_lease","action":"status","active":true,"lease_id":"%s","owner_connection_id":"%s","owner_pid":%s,"owner_process_start_seconds":123456,"owner_process_start_microseconds":789,"expires_at_ms":9999999999999,"session_id":null,"run_id":null}\\n' "$lease_id" "$connection_id" "$owner_pid"
              else
                printf '{"ok":true,"op":"omp_qualification_lease","action":"status","active":false,"lease_id":null,"owner_connection_id":null,"owner_pid":null,"expires_at_ms":null,"session_id":null,"run_id":null}\\n'
              fi
            elif [[ "$payload" == *'run_routing_history'* ]]; then
              printf '{"ok":true,"op":"run_routing_history","run_id":"%s","dropped_event_count":0,"events":[' "$run_id"
              printf '{"seq":11,"run_id":"%s","event":"policy_installed","connection_id":null,"fields":{"pending_policy_key":"omp-coding-agent"}},' "$run_id"
              printf '{"seq":12,"run_id":"%s","event":"expected_pid_policy_armed","connection_id":null,"fields":{"armed":"true"}},' "$run_id"
              printf '{"seq":13,"run_id":"%s","event":"expected_pid_registered","connection_id":null,"fields":{"expected_pid":"321"}},' "$run_id"
              printf '{"seq":14,"run_id":"%s","event":"client_identity_observed","connection_id":"%s","fields":{"verified_client_name":"omp-coding-agent","helper_peer_pid":"123","process_correlation_ok":"true","matched_expected_pid":"321","matched_expected_start_seconds":"123456","matched_expected_start_microseconds":"789","matched_expected_executable_path":"/fixture/bin/omp","omp_current_executable_identity_match":"true","helper_process_start_seconds":"123457","helper_process_start_microseconds":"111","helper_executable_path":"/fixture/RepoPrompt.app/Contents/Helpers/repoprompt-mcp","helper_bundled_identity_match":"true","helper_current_executable_identity_match":"true","helper_strict_descendant":"true"}},' "$run_id" "$connection_id"
              printf '{"seq":15,"run_id":"%s","event":"pid_gate_wait_started","connection_id":"%s","fields":{}},' "$run_id" "$connection_id"
              printf '{"seq":16,"run_id":"%s","event":"pid_gate_wait_completed","connection_id":"%s","fields":{}},' "$run_id" "$connection_id"
              printf '{"seq":17,"run_id":"%s","event":"run_route_mapped","connection_id":"%s","fields":{}},' "$run_id" "$connection_id"
              printf '{"seq":18,"run_id":"%s","event":"routing_waiter_signalled","connection_id":"%s","fields":{"outcome":"routed"}},' "$run_id" "$connection_id"
              printf '{"seq":19,"run_id":"%s","event":"policy_applied","connection_id":"%s","fields":{}},' "$run_id" "$connection_id"
              printf '{"seq":20,"run_id":"%s","event":"route_wait_completed","connection_id":"%s","fields":{"routed":"true"}}]}\\n' "$run_id" "$connection_id"
            elif [[ "$payload" == *'connection_history'* ]]; then
              if [[ -f "$FAKE_STATE_DIR/session_cleaned" ]]; then
                printf '{"ok":true,"op":"connection_history","events":[{"seq":21,"connection_id":"%s","client_name":"omp-coding-agent","normalized_client_id":"omp-coding-agent","event":"initialized"},{"seq":22,"connection_id":"%s","client_name":"omp-coding-agent","normalized_client_id":"omp-coding-agent","event":"removed","qualification_raw_tool_call_count":2,"qualification_raw_in_flight_call_count":0,"qualification_raw_tool_names":["bind_context","set_status"],"qualification_raw_canonical_tool_names":["bind_context","set_status"],"qualification_raw_nonbookkeeping_tool_call_count":0,"qualification_raw_nonbookkeeping_tool_names":[],"non_bookkeeping_tool_call_count":0,"non_bookkeeping_tool_names":[],"active_tool_scope_count":0,"helper_peer_pid":123,"helper_peer_start_seconds":123457,"helper_peer_start_microseconds":111}]}\\n' "$connection_id" "$connection_id"
              else
                printf '{"ok":true,"op":"connection_history","events":[{"seq":21,"connection_id":"%s","client_name":"omp-coding-agent","normalized_client_id":"omp-coding-agent","event":"initialized"}]}\\n' "$connection_id"
              fi
            else
              printf '{"ok":true,"op":"connections","connections":[]}\\n'
            fi
            ;;
          *)
            exit 9
            ;;
        esac
        """
    }
}
