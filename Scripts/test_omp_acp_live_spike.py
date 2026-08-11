#!/usr/bin/env python3
"""Hermetic safety regression tests for omp_acp_live_spike.py."""

from __future__ import annotations

import hashlib
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from unittest import mock
from argparse import Namespace
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import omp_acp_live_spike as spike  # noqa: E402
import omp_qualification_support as qualification_support  # noqa: E402


class FakeExitedProcess:
    def poll(self) -> int:
        return 0


class FakeRunningProcess:
    returncode = None

    def poll(self) -> None:
        return None


class DelayedPumpJSONLProcess(spike.JSONLProcess):
    def _pump(self, name: str, stream: Any, sink: list[str]) -> None:
        if name == "stdout":
            time.sleep(0.05)
        super()._pump(name, stream, sink)


class OMPACPLiveSpikeTests(unittest.TestCase):
    @staticmethod
    def pid_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def make_executable(self, root: Path, name: str, body: str) -> Path:
        path = root / name
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)
        return path

    def make_retained_jsonl_process(
        self,
        lines: list[str],
        *,
        message_limit: int = spike.DEFAULT_MESSAGE_LIMIT,
        protocol_error: spike.ProbeError | None = None,
    ) -> spike.JSONLProcess:
        process = object.__new__(spike.JSONLProcess)
        process.command = ["retained-jsonl"]
        process.stdout_lines = lines
        process.stderr_lines = []
        process.messages = []
        process.message_limit = message_limit
        process._processed_lines = 0
        process._overflow = None
        process._protocol_error = protocol_error
        process._pending_requests = {}
        process._completed_response_ids = set()
        process._lock = threading.Lock()
        process._pumps_joined = True
        process.close = mock.Mock()
        return process

    def run_proxy(
        self,
        root: Path,
        messages: list[dict[str, Any]] | None = None,
        raw_input: bytes | None = None,
        frame_limit_bytes: int | None = None,
        mode: str = "roundtrip",
        exit_on_complete: bool = False,
    ) -> tuple[dict[str, Any], subprocess.CompletedProcess[bytes]]:
        workspace = root / "workspace"
        workspace.mkdir()
        audit = root / "audit.json"
        command = [
            sys.executable,
            str(SCRIPT_DIR / "omp_acp_live_spike.py"),
            "--readonly-mcp-proxy",
            "--mode",
            mode,
            "--workspace",
            str(workspace),
            "--audit-file",
            str(audit),
        ]
        if frame_limit_bytes is not None:
            command.extend(["--frame-limit-bytes", str(frame_limit_bytes)])
        if exit_on_complete:
            command.append("--exit-on-complete")
        input_bytes = raw_input
        if input_bytes is None:
            input_bytes = b"".join(json.dumps(message).encode() + b"\n" for message in (messages or []))
        completed = subprocess.run(
            command,
            input=input_bytes,
            capture_output=True,
            timeout=5,
            check=False,
        )
        return json.loads(audit.read_text(encoding="utf-8")), completed

    @staticmethod
    def valid_proxy_messages(arguments: Any = None) -> list[dict[str, Any]]:
        call_params: dict[str, Any] = {"name": "get_file_tree"}
        if arguments is not None:
            call_params["arguments"] = arguments
        return [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": spike.MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": call_params},
        ]

    def test_readonly_proxy_accepts_only_minimal_sequence_and_records_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            audit, completed = self.run_proxy(root, self.valid_proxy_messages())
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(audit["protocolSequence"], [
                "initialize",
                "notifications/initialized",
                "tools/list",
                "tools/call",
            ])
            self.assertEqual(audit["observedToolArguments"], {})
            self.assertNotIn("sanitizedToolArguments", audit)
            spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")

    def test_readonly_proxy_exit_on_complete_writes_live_audit_before_teardown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = self.valid_proxy_messages() + [
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_file_tree"}}
            ]
            audit, completed = self.run_proxy(root, messages, exit_on_complete=True)
            self.assertEqual(completed.returncode, 0)
            self.assertTrue(audit["exitedOnComplete"])
            self.assertEqual(audit["rejectedRequestCount"], 0)
            self.assertEqual(audit["protocolSequence"], [
                "initialize",
                "notifications/initialized",
                "tools/list",
                "tools/call",
            ])
            spike.load_readonly_proxy_audit(
                root / "audit.json",
                "roundtrip",
                require_exit_on_complete=True,
            )

    def test_readonly_proxy_rejects_invalid_envelopes_order_duplicates_and_arguments(self) -> None:
        cases: dict[str, list[dict[str, Any]]] = {}
        missing_jsonrpc = self.valid_proxy_messages()
        missing_jsonrpc[0] = {"id": 1, "method": "initialize", "params": {}}
        cases["missing-jsonrpc"] = missing_jsonrpc
        missing_id = self.valid_proxy_messages()
        missing_id[0] = {"jsonrpc": "2.0", "method": "initialize", "params": {}}
        cases["missing-id"] = missing_id
        out_of_order = self.valid_proxy_messages()
        out_of_order[0], out_of_order[1] = out_of_order[1], out_of_order[0]
        cases["out-of-order"] = out_of_order
        duplicate = self.valid_proxy_messages() + [
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_file_tree"}}
        ]
        cases["duplicate-call"] = duplicate
        cases["non-empty-arguments"] = self.valid_proxy_messages({"depth": 99})

        for label, messages in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                audit, _ = self.run_proxy(root, messages)
                self.assertTrue(audit["rejectedRequests"])
                with self.assertRaises(spike.ProbeError):
                    spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")
                if label == "non-empty-arguments":
                    self.assertNotIn("observedToolArguments", audit)

    def test_readonly_proxy_validates_ids_core_params_and_strict_json(self) -> None:
        invalid_sequences: list[tuple[str, list[dict[str, Any]] | None, bytes | None]] = []
        for bad_id in (True, 1.5, {}, []):
            messages = self.valid_proxy_messages()
            messages[0]["id"] = bad_id
            invalid_sequences.append((f"id-{bad_id!r}", messages, None))
        for field, value in (("protocolVersion", 1), ("capabilities", []), ("clientInfo", "bad")):
            messages = self.valid_proxy_messages()
            messages[0]["params"][field] = value
            invalid_sequences.append((field, messages, None))
        for field in ("name", "version"):
            messages = self.valid_proxy_messages()
            del messages[0]["params"]["clientInfo"][field]
            invalid_sequences.append((f"clientInfo-{field}", messages, None))
        initialized_with_id = self.valid_proxy_messages()
        initialized_with_id[1]["id"] = 9
        invalid_sequences.append(("initialized-id", initialized_with_id, None))
        nonempty_tools_list = self.valid_proxy_messages()
        nonempty_tools_list[2]["params"] = {"cursor": "unexpected"}
        invalid_sequences.append(("tools-list-params", nonempty_tools_list, None))
        nonobject_tool_call = self.valid_proxy_messages()
        nonobject_tool_call[3]["params"] = []
        invalid_sequences.append(("tools-call-params", nonobject_tool_call, None))
        unknown_notification = self.valid_proxy_messages()
        unknown_notification.insert(2, {"jsonrpc": "2.0", "method": "notifications/unknown", "params": {}})
        invalid_sequences.append(("unknown-notification", unknown_notification, None))
        malformed_notifications = {
            "progress": {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}},
            "cancelled": {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}},
            "roots": {"jsonrpc": "2.0", "method": "notifications/roots/list_changed", "params": {"extra": True}},
        }
        for label, notification in malformed_notifications.items():
            messages = self.valid_proxy_messages()
            messages.insert(2, notification)
            invalid_sequences.append((f"malformed-{label}", messages, None))
        invalid_sequences.append(("non-standard-constant", None, b'{"jsonrpc":"2.0","id":NaN,"method":"initialize"}\n'))

        for label, messages, raw_input in invalid_sequences:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                audit, _ = self.run_proxy(root, messages, raw_input)
                self.assertGreater(audit["rejectedRequestCount"], 0)
                with self.assertRaises(spike.ProbeError):
                    spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")

    def test_readonly_proxy_tolerates_sideband_and_preserves_accepted_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = self.valid_proxy_messages()
            messages[0]["params"]["capabilities"] = {"future": {"nested": [1, "two"]}}
            messages[2:2] = [
                {"jsonrpc": "2.0", "id": "ping-1", "method": "ping", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "probe", "progress": 1, "message": "ok"}},
                {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7, "reason": "done"}},
                {"jsonrpc": "2.0", "method": "notifications/roots/list_changed"},
            ]
            audit, _ = self.run_proxy(root, messages)
            spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")
            self.assertEqual(audit["pingCount"], 1)
            self.assertEqual(audit["benignNotificationCounts"], {
                "notifications/cancelled": 1,
                "notifications/progress": 1,
                "notifications/roots/list_changed": 1,
            })
            self.assertEqual(audit["protocolSequence"], [
                "initialize", "notifications/initialized", "tools/list", "tools/call"
            ])

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = self.valid_proxy_messages() + [
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {"name": "get_file_tree", "arguments": {"overwrite": True}},
                }
            ]
            audit, _ = self.run_proxy(root, messages)
            self.assertEqual(audit["observedToolArguments"], {})
            self.assertGreater(audit["rejectedRequestCount"], 0)

    def test_readonly_proxy_rejects_newline_free_oversized_frame_with_bounded_audit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            audit, completed = self.run_proxy(root, raw_input=b"x" * 65, frame_limit_bytes=64)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(audit["rejectedRequestCount"], 1)
            self.assertLessEqual(len(audit["rejectedRequests"]), spike.DEFAULT_PROXY_REJECTION_LIMIT)
            self.assertEqual(audit["rejectedRequests"][0]["reason"], "oversized-line")
            with self.assertRaises(spike.ProbeError):
                spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = [
                {"jsonrpc": "2.0", "id": index, "method": "unknown/method"}
                for index in range(spike.DEFAULT_PROXY_REJECTION_LIMIT + 8)
            ]
            audit, _ = self.run_proxy(root, messages)
            self.assertEqual(audit["rejectedRequestCount"], spike.DEFAULT_PROXY_REJECTION_LIMIT + 8)
            self.assertEqual(len(audit["rejectedRequests"]), spike.DEFAULT_PROXY_REJECTION_LIMIT)

    def test_wait_for_response_rescans_messages_after_final_drain(self) -> None:
        process = object.__new__(spike.JSONLProcess)
        process.stdout_lines = ['{"jsonrpc":"2.0","id":7,"result":{}}']
        process.stderr_lines = []
        process.messages = []
        process._processed_lines = 0
        process._stream_sizes = {"stdout": len(process.stdout_lines[0]), "stderr": 0}
        process._overflow = None
        process._protocol_error = None
        process._pending_requests = {7: "test"}
        process._completed_response_ids = set()
        process._lock = threading.Lock()
        process.message_limit = 10
        process.process = FakeExitedProcess()
        process._join_pumps = mock.Mock()

        response = process.wait_for_response(7, 0)

        self.assertEqual(response["id"], 7)

    def test_wait_for_response_joins_delayed_terminal_pump(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = self.make_executable(
                root,
                "terminal.py",
                """
                import sys
                sys.stdin.readline()
                print('{"jsonrpc":"2.0","id":1,"result":{}}', flush=True)
                """,
            )
            process = DelayedPumpJSONLProcess(
                [str(executable)],
                root,
                pump_join_timeout_seconds=0.5,
            )

            process.send({"jsonrpc": "2.0", "id": 1, "method": "test", "params": {}})
            response = process.wait_for_response(1, 1)
            process.close()

            self.assertEqual(response["id"], 1)

            notifications: list[dict[str, Any]] = []
            second = DelayedPumpJSONLProcess(
                [str(executable)],
                root,
                pump_join_timeout_seconds=0.5,
            )
            second.send({"jsonrpc": "2.0", "id": 1, "method": "test", "params": {}})
            second.drain_for(1, notifications.append)
            second.close()
            self.assertEqual(notifications[0]["id"], 1)

    def test_permission_terminal_error_is_preserved_by_jsonl_process(self) -> None:
        process = object.__new__(spike.JSONLProcess)
        process._lock = threading.Lock()
        process._overflow = None
        process._protocol_error = None
        terminal = spike.PermissionTerminalError("permission terminal")
        self.assertIs(process.latch_protocol_error(terminal), terminal)
        with self.assertRaises(spike.PermissionTerminalError):
            process._check_terminal()

    def test_parsed_message_retention_is_bounded(self) -> None:
        process = object.__new__(spike.JSONLProcess)
        process.stdout_lines = ['{"jsonrpc":"2.0","id":1,"result":{}}', '{"jsonrpc":"2.0","id":2,"result":{}}']
        process.messages = []
        process._processed_lines = 0
        process._stream_sizes = {"stdout": 40, "stderr": 0}
        process._overflow = None
        process._protocol_error = None
        process._pending_requests = {1: "one", 2: "two"}
        process._completed_response_ids = set()
        process._lock = threading.Lock()
        process.message_limit = 1

        with self.assertRaisesRegex(spike.ProbeError, "message count"):
            process.drain()

        self.assertEqual(len(process.messages), 1)

    def test_combined_errors_prioritize_survivors_and_preserve_all_causes(self) -> None:
        bounded = object.__new__(spike.BoundedTextProcess)
        bounded.command = ["fake"]
        bounded.process = FakeRunningProcess()
        bounded._lock = threading.Lock()
        bounded._overflow = None
        bounded.close = mock.Mock(side_effect=spike.ProbeError("subprocess group survived forced teardown"))

        with self.assertRaises(spike.ProbeError) as timeout_context:
            bounded.wait(0.02)
        timeout_message = str(timeout_context.exception)
        self.assertLess(timeout_message.index("survived"), timeout_message.index("timed out"))
        self.assertIn("timed out", timeout_message)
        self.assertEqual(len(timeout_context.exception.details["causes"]), 2)

        overflowing = object.__new__(spike.BoundedTextProcess)
        overflowing.command = ["fake"]
        overflowing.process = FakeExitedProcess()
        overflowing.process.returncode = 0
        overflowing._lock = threading.Lock()
        overflowing._overflow = "stdout exceeded retained bytes"
        overflowing.close = mock.Mock(side_effect=spike.ProbeError("subprocess group survived forced teardown"))
        with self.assertRaises(spike.ProbeError) as overflow_context:
            overflowing.wait(1)
        self.assertIn("survived", str(overflow_context.exception))
        self.assertIn("stdout exceeded", str(overflow_context.exception))

        jsonl = object.__new__(spike.JSONLProcess)
        jsonl.command = ["fake"]
        jsonl.process = mock.Mock(stdin=None)
        jsonl.termination_grace_seconds = 0.01
        jsonl._close_complete = False
        jsonl._join_pumps = mock.Mock(side_effect=spike.ProbeError("pump did not stop"))
        jsonl._check_terminal = mock.Mock()
        with (
            mock.patch.object(
                spike,
                "terminate_process_group",
                side_effect=spike.ProbeError("subprocess group survived forced teardown"),
            ),
            self.assertRaises(spike.ProbeError) as close_context,
        ):
            jsonl.close()
        self.assertIn("survived", str(close_context.exception))
        self.assertIn("pump did not stop", str(close_context.exception))
        jsonl._check_terminal.assert_called_once_with()

        evidence_process = mock.Mock()
        evidence_process.close.side_effect = spike.ProbeError("subprocess group survived forced teardown")
        evidence_process.write_evidence.side_effect = spike.ProbeError("evidence disk full")
        with self.assertRaises(spike.ProbeError) as evidence_context:
            spike.close_and_write_jsonl_evidence(evidence_process, Path("unused"))
        self.assertIn("survived", str(evidence_context.exception))
        self.assertIn("evidence disk full", str(evidence_context.exception))

    def test_close_kills_descendant_when_group_leader_exits_on_eof(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = self.make_executable(
                root,
                "leader.py",
                """
                import json
                import os
                import signal
                import sys
                child = os.fork()
                if child == 0:
                    devnull = os.open(os.devnull, os.O_RDWR)
                    os.dup2(devnull, 0)
                    os.dup2(devnull, 1)
                    os.dup2(devnull, 2)
                    signal.pause()
                    raise SystemExit(0)
                print(json.dumps({"jsonrpc":"2.0","method":"ready","params":{"child":child}}), flush=True)
                sys.stdin.read()
                """,
            )
            process = spike.JSONLProcess(
                [str(executable)],
                root,
                termination_grace_seconds=0.5,
            )
            process_group_id = process.process.pid
            child_pid: int | None = None
            try:
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline and child_pid is None:
                    ready: list[dict[str, Any]] = []
                    process.drain_for(0.02, ready.append)
                    for message in ready:
                        if message.get("method") == "ready":
                            child_pid = message["params"]["child"]
                            break
                self.assertIsNotNone(child_pid)
                assert child_pid is not None
                os.kill(child_pid, 0)
                process.close()
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline and (
                    spike.process_group_exists(process_group_id) or self.pid_exists(child_pid)
                ):
                    time.sleep(0.01)
                self.assertFalse(spike.process_group_exists(process_group_id))
                self.assertFalse(self.pid_exists(child_pid))
            finally:
                if spike.process_group_exists(process_group_id):
                    os.killpg(process_group_id, signal.SIGKILL)
                if child_pid is not None and self.pid_exists(child_pid):
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_output_overflow_is_bounded_and_cleanup_still_runs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = self.make_executable(
                root,
                "noisy.py",
                """
                import os
                import signal
                import sys
                child = os.fork()
                if child == 0:
                    devnull = os.open(os.devnull, os.O_RDWR)
                    os.dup2(devnull, 0)
                    os.dup2(devnull, 1)
                    os.dup2(devnull, 2)
                    signal.pause()
                    raise SystemExit(0)
                os.write(1, b'x' * 129)
                signal.pause()
                """,
            )
            process = spike.JSONLProcess(
                [str(executable)],
                root,
                stream_limit_bytes=256,
                frame_limit_bytes=128,
                message_limit=4,
                termination_grace_seconds=0.5,
            )
            process_group_id = process.process.pid
            with self.assertRaisesRegex(spike.ProbeError, "exceeded"):
                process.wait_for_response(1, 1)
            with self.assertRaisesRegex(spike.ProbeError, "exceeded"):
                process.close()

            self.assertLessEqual(sum(len(line.encode()) + 1 for line in process.stdout_lines), 128)
            self.assertFalse(spike.process_group_exists(process_group_id))

    def test_prompt_injects_no_mcp_and_tool_event_invalidates_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            captured = root / "session-new.json"
            fake_omp = self.make_executable(
                root,
                "fake-omp.py",
                f"""
                import json
                import sys
                from pathlib import Path
                captured = Path({str(captured)!r})
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize":
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"authMethods":[],"agentCapabilities":{{}}}}}}), flush=True)
                    elif method == "session/new":
                        captured.write_text(json.dumps(message), encoding="utf-8")
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"sessionId":"s"}}}}), flush=True)
                    elif method == "session/prompt":
                        update = {{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"tool_call","toolCallId":"unexpected-id","title":"unexpected"}}}}}}
                        text = {{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"agent_message_chunk","content":{{"text":"OMP_ACP_PROMPT_OK"}}}}}}}}
                        print(json.dumps(update), flush=True)
                        print(json.dumps(text), flush=True)
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"stopReason":"end_turn"}}}}), flush=True)
                    elif method == "session/close":
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{}}}}), flush=True)
                        break
                """,
            )

            before = spike.snapshot_workspace(workspace)
            summary = spike.acp_probe(fake_omp, root / "unused-helper", workspace, output, "prompt", 2)
            after = spike.snapshot_workspace(workspace)

            self.assertTrue(spike.phase_requires_workspace_snapshot("prompt"))
            self.assertEqual(spike.changed_snapshot_paths(before, after), [])
            session_new = json.loads(captured.read_text(encoding="utf-8"))
            self.assertEqual(session_new["params"]["mcpServers"], [])
            self.assertEqual(summary["mcpServerKind"], "none")
            self.assertTrue(summary["agentAcknowledgementObserved"])
            with self.assertRaisesRegex(spike.ProbeError, "tool or permission"):
                spike.validate_prompt_summary(summary)

    def test_prompt_close_tail_tool_and_permission_events_are_finalized_before_summary(self) -> None:
        for position in ("before", "after"):
            with self.subTest(position=position), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                fake_omp = self.make_executable(
                    root,
                    "fake-close-tail.py",
                    f"""
                    import json
                    import time
                    import sys
                    tool = {{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"tool_call","toolCallId":"late-id","title":"late-tool"}}}}}}
                    permission = {{"jsonrpc":"2.0","id":77,"method":"session/request_permission","params":{{"sessionId":"s"}}}}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize":
                            print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"authMethods":[],"agentCapabilities":{{}}}}}}), flush=True)
                        elif method == "session/new":
                            print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"sessionId":"s"}}}}), flush=True)
                        elif method == "session/prompt":
                            text = {{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"agent_message_chunk","content":{{"text":"OMP_ACP_PROMPT_OK"}}}}}}}}
                            print(json.dumps(text), flush=True)
                            print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{"stopReason":"end_turn"}}}}), flush=True)
                        elif method == "session/close":
                            if {position!r} == "before":
                                print(json.dumps(tool), flush=True)
                            print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":{{}}}}), flush=True)
                            if {position!r} == "after":
                                time.sleep(0.05)
                                print(json.dumps(tool), flush=True)
                                print(json.dumps(permission), flush=True)
                            break
                    """,
                )

                with self.assertRaisesRegex(spike.ProbeError, "after session close began") as context:
                    spike.acp_probe(fake_omp, root / "unused-helper", workspace, output, "prompt", 2)
                partial = context.exception.details["ompACPPartial"]
                self.assertEqual(partial["toolEventRecords"][0]["titleRepresentations"], ["late-tool"])
                self.assertIn(partial["toolEventRecords"][0]["lifecyclePhase"], {"closing", "closed"})

    def test_main_prompt_exits_nonzero_when_acknowledgement_has_tool_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            args = Namespace(
                phase="prompt",
                omp="fake-omp",
                app_bundle=root / "Fake.app",
                workspace=workspace,
                unsafe_allow_nonempty_workspace=False,
                output_dir=root,
                prompt_timeout=1,
            )
            acp = {
                "agentAcknowledgementObserved": True,
                "observedUpdateKinds": ["agent_message_chunk", "tool_call"],
                "observedToolTitles": ["unexpected"],
                "permissionEvents": [],
                "unexpectedInboundRequests": {"count": 0, "records": []},
            }
            global_help = " ".join(["--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--approval-mode"])
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, False)),
                mock.patch.object(spike, "find_executable", return_value=Path("/bin/echo")),
                mock.patch.object(
                    spike,
                    "run_text",
                    side_effect=["1.0", global_help, "Run Oh My Pi as an ACP"],
                ) as run_text_mock,
                mock.patch.object(spike, "helper_preflight", return_value={}),
                mock.patch.object(spike, "acp_probe", return_value=acp),
            ):
                exit_code = spike.main()

            summary = json.loads((output / "safe-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(exit_code, 1)
            self.assertFalse(summary["success"])
            self.assertIn("tool or permission", summary["error"])
            self.assertTrue(summary["workspaceUnchanged"])
            self.assertEqual([call.kwargs["cwd"] for call in run_text_mock.call_args_list], [workspace] * 3)

    def test_roundtrip_audit_path_is_prepared_before_omp_launch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            (output / "readonly-mcp-proxy.audit.json").mkdir()
            launch_marker = root / "launched"
            fake_omp = self.make_executable(
                root,
                "fake-omp.py",
                f"from pathlib import Path\nPath({str(launch_marker)!r}).write_text('launched')\n",
            )

            with self.assertRaisesRegex(spike.ProbeError, "pre-existing"):
                spike.acp_probe(fake_omp, root / "helper", workspace, output, "roundtrip", 1)

            self.assertFalse(launch_marker.exists())

    def test_evidence_directory_is_fresh_private_and_cannot_overlap_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            parent = root / "evidence-parent"
            repo.mkdir()
            parent.mkdir()
            (parent / "safe-summary.json").write_text('{"success":true}', encoding="utf-8")
            (parent / "omp-acp.stdout.jsonl").symlink_to(parent / "safe-summary.json")

            output = spike.prepare_output_directory(parent, repo)

            self.assertEqual(output.parent, parent.resolve())
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual(list(output.iterdir()), [])
            args = Namespace(
                workspace=output,
                unsafe_allow_nonempty_workspace=False,
            )
            with self.assertRaisesRegex(spike.ProbeError, "overlap"):
                spike.prepare_workspace(args, output, repo)

    def test_default_workspace_repo_containment_cleanup_and_snapshot_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            output = root / "output"
            repo.mkdir()
            output.mkdir()
            created = repo / "tmp-workspace"

            def create_inside_repo(*_args: Any, **_kwargs: Any) -> str:
                created.mkdir()
                return str(created)

            args = Namespace(workspace=None, unsafe_allow_nonempty_workspace=False)
            with (
                mock.patch.object(spike.tempfile, "mkdtemp", side_effect=create_inside_repo),
                self.assertRaisesRegex(spike.ProbeError, "repository workspace"),
            ):
                spike.prepare_workspace(args, output, repo)

            self.assertFalse(created.exists())
            for phase in ("preflight", "cli-prompt", "helper", "bootstrap", "prompt", "roundtrip"):
                self.assertTrue(spike.phase_requires_workspace_snapshot(phase))

    def test_workspace_snapshot_detects_root_mode_and_helper_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir(mode=0o700)
            output.mkdir()
            before = spike.snapshot_workspace(workspace)
            workspace.chmod(0o755)
            after = spike.snapshot_workspace(workspace)
            self.assertEqual(spike.changed_snapshot_paths(before, after), ["."])

            args = Namespace(
                phase="helper",
                omp="fake-omp",
                app_bundle=root / "Fake.app",
                workspace=workspace,
                unsafe_allow_nonempty_workspace=False,
                output_dir=root,
                prompt_timeout=1,
            )
            global_help = " ".join(["--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--approval-mode"])

            def mutate_helper(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
                (workspace / "helper-mutation").write_text("changed", encoding="utf-8")
                return {}

            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, False)),
                mock.patch.object(spike, "find_executable", return_value=Path("/bin/echo")),
                mock.patch.object(
                    spike,
                    "run_text",
                    side_effect=["1.0", global_help, "Run Oh My Pi as an ACP"],
                ),
                mock.patch.object(spike, "helper_preflight", side_effect=mutate_helper),
            ):
                exit_code = spike.main()

            summary = json.loads((output / "safe-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(exit_code, 1)
            self.assertIn("helper-mutation", summary["workspaceChangedPaths"])

    def test_jsonl_process_rejects_malformed_envelopes_and_accepts_legal_notification(self) -> None:
        invalid_lines = [
            "not-json",
            '{"id":1,"result":{}}',
            '{"jsonrpc":"2.0","id":NaN,"result":{}}',
            '{"jsonrpc":"2.0","id":true,"result":{}}',
            '[]',
        ]
        for line in invalid_lines:
            with self.subTest(line=line):
                process = object.__new__(spike.JSONLProcess)
                process.stdout_lines = [line]
                process.messages = []
                process._processed_lines = 0
                process._stream_sizes = {"stdout": len(line), "stderr": 0}
                process._overflow = None
                process._protocol_error = None
                process._lock = threading.Lock()
                process.message_limit = 4
                with self.assertRaises(spike.ProbeError):
                    process.drain()
                self.assertIsNotNone(process._protocol_error)

        legal = object.__new__(spike.JSONLProcess)
        legal.stdout_lines = ['{"jsonrpc":"2.0","method":"future/notification","params":{"value":1}}']
        legal.messages = []
        legal._processed_lines = 0
        legal._stream_sizes = {"stdout": 70, "stderr": 0}
        legal._overflow = None
        legal._protocol_error = None
        legal._lock = threading.Lock()
        legal.message_limit = 4
        legal.drain()
        self.assertEqual(legal.messages[0]["method"], "future/notification")

    def test_jsonl_process_rejects_string_response_ids_without_correlation(self) -> None:
        line = '{"jsonrpc":"2.0","id":"1","result":{}}'
        process = object.__new__(spike.JSONLProcess)
        process.stdout_lines = [line]
        process.messages = []
        process._processed_lines = 0
        process._stream_sizes = {"stdout": len(line), "stderr": 0}
        process._overflow = None
        process._protocol_error = None
        process._pending_requests = {1: "initialize"}
        process._completed_response_ids = set()
        process._lock = threading.Lock()
        process.message_limit = 4

        with self.assertRaisesRegex(spike.ProbeError, "invalid JSON-RPC response envelope"):
            process.drain()

        self.assertEqual(process._pending_requests, {1: "initialize"})
        self.assertIsNone(process._response(1))
        self.assertEqual(process.messages, [])

    def test_phase_tool_event_validation_requires_exact_attribution(self) -> None:
        with self.assertRaisesRegex(spike.ProbeError, "bootstrap"):
            spike.validate_bootstrap_summary({
                "observedUpdateKinds": ["tool_call"],
                "observedToolTitles": [],
                "toolEventRecords": [{"kind": "tool_call", "toolCallId": "x", "title": None}],
                "permissionEvents": [],
                "unexpectedInboundRequests": {"count": 0, "records": []},
            })

        valid = {
            "agentAcknowledgementObserved": True,
            "permissionEvents": [],
            "toolEventRecords": [
                {"kind": "tool_call", "toolCallId": "expected", "title": "mcp__RepoPromptCE__get_file_tree"},
                {"kind": "tool_call_update", "toolCallId": "expected", "title": None},
            ],
            "unattributedToolEventCount": 0,
            "unexpectedInboundRequests": {"count": 0, "records": []},
            "unknownUpdateKinds": [],
        }
        spike.validate_roundtrip_summary(valid)
        observed_omp_title = {
            **valid,
            "toolEventRecords": [
                {"kind": "tool_call", "toolCallId": "expected", "title": "mcp__repopromptce_get_file_tree"},
                {"kind": "tool_call_update", "toolCallId": "expected", "title": None},
            ],
        }
        spike.validate_roundtrip_summary(observed_omp_title)
        invalid_records = [
            valid["toolEventRecords"] + [{"kind": "tool_call", "toolCallId": "extra", "title": "bash"}],
            [{"kind": "tool_call", "toolCallId": "expected", "title": "mcp__OtherServer__get_file_tree"}],
            [{"kind": "tool_call", "toolCallId": "expected", "title": "get_file_tree"}],
            [{"kind": "tool_call", "toolCallId": "expected", "title": "mcp__repopromptcex_get_file_tree"}],
            [{"kind": "tool_call", "toolCallId": None, "title": None}],
            [{"kind": "tool_call", "toolCallId": "   ", "title": "mcp__RepoPromptCE__get_file_tree"}],
            valid["toolEventRecords"] + [{"kind": "tool_call_update", "toolCallId": None, "title": None}],
            valid["toolEventRecords"] + [{"kind": "tool_call_update", "toolCallId": "\t", "title": None}],
        ]
        for records in invalid_records:
            with self.subTest(records=records), self.assertRaises(spike.ProbeError):
                spike.validate_roundtrip_summary({**valid, "toolEventRecords": records})
        with self.assertRaisesRegex(spike.ProbeError, "permission"):
            spike.validate_roundtrip_summary({**valid, "permissionEvents": [{"title": "get_file_tree"}]})
        with self.assertRaisesRegex(spike.ProbeError, "unknown"):
            spike.validate_bootstrap_summary({"unknownUpdateKinds": ["future_tool_update"]})
        with self.assertRaisesRegex(spike.ProbeError, "unknown"):
            spike.validate_prompt_summary({"unknownUpdateKinds": ["future_tool_update"]})
        with self.assertRaisesRegex(spike.ProbeError, "unknown"):
            spike.validate_roundtrip_summary({**valid, "unknownUpdateKinds": ["future_tool_update"]})

    def test_snapshot_and_readonly_tree_enforce_pre_io_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            oversized = root / "sparse"
            with oversized.open("wb") as stream:
                stream.truncate(100)
            with (
                mock.patch.object(spike, "hash_regular_file") as hash_mock,
                self.assertRaisesRegex(spike.ProbeError, "exceeds 10 bytes"),
            ):
                spike.snapshot_workspace(root, file_byte_limit=10, aggregate_byte_limit=100, deadline_seconds=1)
            hash_mock.assert_not_called()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "one").write_text("1", encoding="utf-8")
            (root / "two").write_text("2", encoding="utf-8")
            with self.assertRaisesRegex(spike.ProbeError, "entry count"):
                spike.snapshot_workspace(root, entry_limit=1, deadline_seconds=1)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index in range(140):
                (root / f"entry-{index:03d}").write_text("x", encoding="utf-8")
            with mock.patch.object(spike, "hash_regular_file", side_effect=AssertionError("must not hash")):
                tree = spike.readonly_workspace_tree(root, entry_limit=128, deadline_seconds=1)
            self.assertEqual(len(tree), 128)

    def test_teardown_keyboard_interrupt_is_combined_evidenced_and_cached(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = self.make_executable(
                root,
                "interrupt-close.py",
                """
                import signal
                signal.pause()
                """,
            )
            process = spike.JSONLProcess([str(executable)], root, termination_grace_seconds=0.2)
            process_group_id = process.process.pid
            original_terminate = spike.terminate_process_group
            calls = 0

            def interrupt_once(*args: Any, **kwargs: Any) -> None:
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise KeyboardInterrupt()
                original_terminate(*args, **kwargs)

            with (
                mock.patch.object(spike, "terminate_process_group", side_effect=interrupt_once),
                self.assertRaises(spike.ProbeError) as context,
            ):
                spike.close_and_write_jsonl_evidence(process, root / "interrupt")
            self.assertIn("KeyboardInterrupt", str(context.exception))
            self.assertFalse(spike.process_group_exists(process_group_id))
            self.assertTrue((root / "interrupt.stdout.jsonl").exists())
            with self.assertRaisesRegex(spike.ProbeError, "KeyboardInterrupt"):
                process.close()
            self.assertEqual(calls, 2)

    def test_session_close_keyboard_interrupt_still_reaps_and_writes_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            pid_file = root / "pid"
            fake_omp = self.make_executable(
                root,
                "close-interrupt-omp.py",
                f"""
                import json
                import os
                import sys
                from pathlib import Path
                Path({str(pid_file)!r}).write_text(str(os.getpid()), encoding="utf-8")
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize":
                        result = {{"authMethods": [], "agentCapabilities": {{}}}}
                    elif method == "session/new":
                        result = {{"sessionId": "s"}}
                    elif method == "session/close":
                        result = {{}}
                    else:
                        continue
                    print(json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": result}}), flush=True)
                    if method == "session/close":
                        break
                """,
            )
            original_wait = spike.JSONLProcess.wait_for_response

            def interrupt_close(process: spike.JSONLProcess, request_id: int, timeout: float, handler: Any = None) -> dict[str, Any]:
                if request_id == 99:
                    raise KeyboardInterrupt()
                return original_wait(process, request_id, timeout, handler)

            with (
                mock.patch.object(spike.JSONLProcess, "wait_for_response", new=interrupt_close),
                self.assertRaises(spike.ProbeError) as context,
            ):
                spike.acp_probe(fake_omp, root / "helper", workspace, output, "bootstrap", 1)
            process_group_id = int(pid_file.read_text(encoding="utf-8"))
            self.assertFalse(spike.process_group_exists(process_group_id))
            self.assertTrue((output / "omp-acp.stdout.jsonl").exists())
            causes = context.exception.details["causes"]
            self.assertTrue(any(cause["stage"] == "session close" and "KeyboardInterrupt" in cause["message"] for cause in causes))

    def test_bounded_text_pump_failure_is_terminal(self) -> None:
        class FailingStream:
            def __init__(self) -> None:
                self.calls = 0

            def read(self, _size: int) -> bytes:
                self.calls += 1
                if self.calls == 1:
                    return b"prefix"
                raise OSError("read failed")

        process = object.__new__(spike.BoundedTextProcess)
        process.command = ["fake"]
        process.stream_limit_bytes = 100
        process.termination_grace_seconds = 0.1
        process._chunks = {"stdout": [], "stderr": []}
        process._sizes = {"stdout": 0, "stderr": 0}
        process._overflow = None
        process._lock = threading.Lock()
        process.process = FakeExitedProcess()
        process._join_pumps = mock.Mock()
        process._pump("stdout", FailingStream())
        with (
            mock.patch.object(spike, "terminate_process_group"),
            self.assertRaisesRegex(spike.ProbeError, "pump failed"),
        ):
            process.close()

    def test_owned_evidence_directory_is_removed_on_preparation_failures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            created = repo / "owned-output"

            def create_inside_repo(*_args: Any, **_kwargs: Any) -> str:
                created.mkdir()
                return str(created)

            with (
                mock.patch.object(spike.tempfile, "mkdtemp", side_effect=create_inside_repo),
                self.assertRaisesRegex(spike.ProbeError, "repository-local evidence"),
            ):
                spike.prepare_output_directory(None, repo)
            self.assertFalse(created.exists())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "owned-run"
            output.mkdir()
            args = Namespace(prompt_timeout=1, output_dir=None)
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", side_effect=spike.ProbeError("workspace rejected")),
            ):
                self.assertEqual(spike.main(), 2)
            self.assertFalse(output.exists())
            self.assertTrue(root.exists())

    def test_final_snapshot_keyboard_interrupt_still_writes_failure_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            args = Namespace(
                phase="preflight",
                omp="fake",
                app_bundle=root / "Fake.app",
                workspace=workspace,
                unsafe_allow_nonempty_workspace=False,
                output_dir=root,
                prompt_timeout=1,
            )
            global_help = " ".join(["--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--approval-mode"])
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, False)),
                mock.patch.object(spike, "snapshot_workspace", side_effect=[{}, KeyboardInterrupt()]),
                mock.patch.object(spike, "find_executable", return_value=Path("/bin/echo")),
                mock.patch.object(spike, "run_text", side_effect=["1.0", global_help, "Run Oh My Pi as an ACP"]),
            ):
                exit_code = spike.main()
            summary = json.loads((output / "safe-summary.json").read_text(encoding="utf-8"))
            self.assertEqual(exit_code, 1)
            self.assertFalse(summary["success"])
            self.assertIn("KeyboardInterrupt", summary["error"])


    def test_discovery_proxy_is_zero_tool_mode_and_rejects_mode_confusion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery = self.valid_proxy_messages()[:3]
            audit, completed = self.run_proxy(root, discovery, mode="discovery")
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(audit["mode"], "discovery")
            self.assertEqual(audit["advertisedToolNames"], [])
            self.assertEqual(audit["allowedToolCallCount"], 0)
            spike.load_readonly_proxy_audit(root / "audit.json", "discovery")
            with self.assertRaises(spike.ProbeError):
                spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = self.valid_proxy_messages()
            audit, completed = self.run_proxy(root, messages, mode="discovery")
            self.assertNotEqual(completed.returncode, 0)
            self.assertGreater(audit["rejectedRequestCount"], 0)
            with self.assertRaises(spike.ProbeError):
                spike.load_readonly_proxy_audit(root / "audit.json", "discovery")

    def test_proxy_rejects_hybrid_extraneous_and_audits_post_completion_failure(self) -> None:
        for label, mutation in (
            ("hybrid", {"result": {}}),
            ("extraneous", {"unexpected": True}),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                messages = self.valid_proxy_messages()
                messages[0].update(mutation)
                audit, _ = self.run_proxy(root, messages)
                self.assertGreater(audit["rejectedRequestCount"], 0)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            messages = self.valid_proxy_messages()
            messages[0]["id"] = "init"
            messages[2]["id"] = "list"
            messages[3]["id"] = "call"
            audit, completed = self.run_proxy(root, messages)
            self.assertEqual(completed.returncode, 0)
            spike.load_readonly_proxy_audit(root / "audit.json", "roundtrip")
            self.assertEqual(audit["protocolSequence"][-1], "tools/call")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir()
            audit_path = root / "audit.json"
            raw = b"".join(json.dumps(message).encode() + b"\n" for message in self.valid_proxy_messages())
            fake_stdin = Namespace(buffer=io.BytesIO(raw))
            with (
                mock.patch.object(spike.sys, "stdin", fake_stdin),
                mock.patch.object(spike.sys, "stdout", io.StringIO()),
                mock.patch.object(spike, "readonly_workspace_tree", side_effect=spike.ProbeError("post-completion failure")),
            ):
                code = spike.readonly_mcp_proxy_main([
                    "--mode", "roundtrip",
                    "--workspace", str(workspace),
                    "--audit-file", str(audit_path),
                ])
            audit = json.loads(audit_path.read_text(encoding="utf-8"))
            self.assertEqual(code, 1)
            self.assertTrue(audit["protocolComplete"])
            self.assertEqual(audit["exitCode"], 1)
            with self.assertRaises(spike.ProbeError):
                spike.load_readonly_proxy_audit(audit_path, "roundtrip")

    def test_jsonl_pending_ids_reject_future_and_duplicate_responses(self) -> None:
        cases = (
            ("future", {1: "expected"}, set(), 2, "unsolicited"),
            ("duplicate", {}, {1}, 1, "duplicate"),
        )
        for label, pending, completed, response_id, expected in cases:
            with self.subTest(label=label):
                process = object.__new__(spike.JSONLProcess)
                process.stdout_lines = [
                    json.dumps({"jsonrpc": "2.0", "id": response_id, "result": {}})
                ]
                process.messages = []
                process._processed_lines = 0
                process._stream_sizes = {"stdout": 100, "stderr": 0}
                process._overflow = None
                process._protocol_error = None
                process._pending_requests = dict(pending)
                process._completed_response_ids = set(completed)
                process._lock = threading.Lock()
                process.message_limit = 4
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    process.drain()
                self.assertEqual(process.messages[0]["id"], response_id)
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    process.drain()

    def test_invalid_session_events_are_recorded_then_fail_terminally(self) -> None:
        cases = {
            "missing": None,
            "wrong": "other",
            "pre-session": "s",
        }
        for label, event_session in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                session_field = "" if event_session is None else f'"sessionId":{event_session!r},'
                before_new = label == "pre-session"
                fake = self.make_executable(
                    root,
                    "invalid-session.py",
                    f"""
                    import json
                    import sys
                    event = {{"jsonrpc":"2.0","method":"session/update","params":{{{session_field}"update":{{"sessionUpdate":"tool_call","toolCallId":"bad","title":"bad"}}}}}}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize":
                            result = {{"authMethods": [], "agentCapabilities": {{}}}}
                        elif method == "session/new":
                            if {before_new!r}:
                                print(json.dumps(event), flush=True)
                            result = {{"sessionId": "s"}}
                        elif method == "session/prompt":
                            if not {before_new!r}:
                                print(json.dumps(event), flush=True)
                            result = {{"stopReason": "end_turn"}}
                        elif method == "session/close":
                            result = {{}}
                        else:
                            continue
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                    """,
                )
                with self.assertRaises(spike.ProbeError) as context:
                    spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
                partial = context.exception.details["ompACPPartial"]
                self.assertEqual(partial["toolEventRecords"][0]["titleRepresentations"], ["bad"])
                self.assertEqual(partial["toolEventRecords"][0]["sessionId"], event_session)
                self.assertTrue((output / "omp-acp.stdout.jsonl").exists())

    def test_acknowledgement_requires_exact_normalized_post_prompt_output(self) -> None:
        variants = {
            "fragmented": (["OMP_ACP_", "PROMPT_OK"], True, False),
            "whitespace": (["  OMP_ACP_", "PROMPT_OK  \n"], True, False),
            "prefix": (["Sure! OMP_ACP_PROMPT_OK"], False, False),
            "suffix": (["OMP_ACP_PROMPT_OK done"], False, False),
            "multiple": (["OMP_ACP_PROMPT_OK", "OMP_ACP_PROMPT_OK"], False, False),
            "pre-prompt": ([], False, True),
        }
        for label, (chunks, expected, pre_prompt) in variants.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                fake = self.make_executable(
                    root,
                    "ack.py",
                    f"""
                    import json
                    import sys
                    import time
                    def update(text):
                        return {{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"agent_message_chunk","content":{{"text":text}}}}}}}}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize":
                            result = {{"authMethods": [], "agentCapabilities": {{}}}}
                        elif method == "session/new":
                            result = {{"sessionId": "s"}}
                            print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                            if {pre_prompt!r}:
                                time.sleep(0.05)
                                print(json.dumps(update("OMP_ACP_PROMPT_OK")), flush=True)
                            continue
                        elif method == "session/prompt":
                            for chunk in {chunks!r}:
                                print(json.dumps(update(chunk)), flush=True)
                            result = {{"stopReason": "end_turn"}}
                        elif method == "session/close":
                            result = {{}}
                        else:
                            continue
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                    """,
                )
                if pre_prompt:
                    with self.assertRaisesRegex(spike.ProbeError, "before prompt dispatch") as context:
                        spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
                    self.assertEqual(
                        context.exception.details["ompACPPartial"]["sessionEventRecords"][0]["lifecyclePhase"],
                        "session-open",
                    )
                    continue
                summary = spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
                self.assertEqual(summary["agentAcknowledgementObserved"], expected)
                if expected:
                    spike.validate_prompt_summary(summary)
                else:
                    with self.assertRaises(spike.ProbeError):
                        spike.validate_prompt_summary(summary)

    def test_roundtrip_acknowledgement_requires_unique_final_token(self) -> None:
        for label, post_tool_chunks, expected in (
            ("exact", ["OMP_REPOPROMPT_MCP_ROUNDTRIP_OK"], True),
            ("suffix", ["OMP_REPOPROMPT_MCP_ROUNDTRIP_OK", " done"], False),
            ("multiple", ["OMP_REPOPROMPT_MCP_ROUNDTRIP_OK", " OMP_REPOPROMPT_MCP_ROUNDTRIP_OK"], False),
            ("missing", [], False),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                events = [
                    {
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": "s",
                            "update": {
                                "sessionUpdate": "tool_call",
                                "toolCallId": "tool-1",
                                "title": "mcp__repopromptce_get_file_tree",
                            },
                        },
                    },
                    {
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": "s",
                            "update": {
                                "sessionUpdate": "tool_call_update",
                                "toolCallId": "tool-1",
                                "status": "completed",
                            },
                        },
                    },
                    {
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": "s",
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "content": {"text": "I will call the tool first."},
                            },
                        },
                    },
                    *[
                        {
                            "jsonrpc": "2.0",
                            "method": "session/update",
                            "params": {
                                "sessionId": "s",
                                "update": {
                                    "sessionUpdate": "agent_message_chunk",
                                    "content": {"text": chunk},
                                },
                            },
                        }
                        for chunk in post_tool_chunks
                    ],
                ]
                fake = self.make_executable(
                    root,
                    "roundtrip-ack.py",
                    f"""
                    import json
                    import sys
                    events = {events!r}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize":
                            result = {{"authMethods": [], "agentCapabilities": {{}}}}
                        elif method == "session/new":
                            result = {{"sessionId": "s"}}
                        elif method == "session/prompt":
                            for event in events:
                                print(json.dumps(event), flush=True)
                            result = {{"stopReason": "end_turn"}}
                        elif method == "session/close":
                            result = {{}}
                        else:
                            continue
                        print(json.dumps({{"jsonrpc": "2.0", "id": request_id, "result": result}}), flush=True)
                    """,
                )
                summary = spike.acp_probe(fake, root / "helper", workspace, output, "roundtrip", 1)
                self.assertEqual(summary["agentAcknowledgementObserved"], expected)
                if expected:
                    spike.validate_roundtrip_summary(summary)
                else:
                    with self.assertRaises(spike.ProbeError):
                        spike.validate_roundtrip_summary(summary)

        acknowledgement = "OMP_REPOPROMPT_MCP_ROUNDTRIP_OK"
        self.assertTrue(spike.has_unique_final_acknowledgement_token(f"narration.{acknowledgement}", acknowledgement))
        self.assertFalse(spike.has_unique_final_acknowledgement_token(f"narrationx{acknowledgement}", acknowledgement))
        self.assertFalse(spike.has_unique_final_acknowledgement_token(f"é{acknowledgement}", acknowledgement))
        self.assertFalse(spike.has_unique_final_acknowledgement_token(f"\u0301{acknowledgement}", acknowledgement))
        self.assertFalse(spike.has_unique_final_acknowledgement_token(f"{acknowledgement}界", acknowledgement))
        self.assertFalse(spike.has_unique_final_acknowledgement_token(f"{acknowledgement}.", acknowledgement))
        self.assertFalse(
            spike.has_unique_final_acknowledgement_token(
                f"{acknowledgement} {acknowledgement}",
                acknowledgement,
            )
        )

    def test_bootstrap_injects_discovery_proxy_and_helper_preflight_stays_real(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            capture = root / "session.json"
            helper = root / "production-helper"
            fake_omp = self.make_executable(
                root,
                "bootstrap.py",
                f"""
                import json
                import sys
                from pathlib import Path
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize":
                        result = {{"authMethods": [], "agentCapabilities": {{}}}}
                    elif method == "session/new":
                        Path({str(capture)!r}).write_text(json.dumps(message), encoding="utf-8")
                        result = {{"sessionId": "s"}}
                    elif method == "session/close":
                        result = {{}}
                    else:
                        continue
                    print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                """,
            )
            summary = spike.acp_probe(fake_omp, helper, workspace, output, "bootstrap", 1)
            server = json.loads(capture.read_text(encoding="utf-8"))["params"]["mcpServers"][0]
            self.assertNotEqual(server["command"], str(helper))
            self.assertIn("--readonly-mcp-proxy", server["args"])
            self.assertIn("--exit-on-complete", server["args"])
            self.assertEqual(server["args"][server["args"].index("--mode") + 1], "discovery")
            self.assertEqual(summary["mcpServerKind"], "test-only-discovery-mcp-proxy")
            with self.assertRaisesRegex(spike.ProbeError, "audit"):
                spike.validate_bootstrap_summary(summary)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            marker = root / "helper-ran"
            helper = self.make_executable(
                root,
                "real-helper.py",
                f"""
                import json
                import sys
                from pathlib import Path
                Path({str(marker)!r}).write_text("yes", encoding="utf-8")
                for line in sys.stdin:
                    message = json.loads(line)
                    if message.get("method") == "initialize":
                        result = {{"serverInfo": {{}}, "capabilities": {{}}}}
                    elif message.get("method") == "tools/list":
                        result = {{"tools": []}}
                    else:
                        continue
                    print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                """,
            )
            spike.helper_preflight(helper, workspace, output)
            self.assertTrue(marker.exists())

    def test_production_bootstrap_injects_only_real_helper_and_never_prompts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            capture = root / "messages.jsonl"
            helper = self.make_executable(root, "repoprompt-mcp", "print('helper')")
            fake_omp = self.make_executable(
                root,
                "production-bootstrap.py",
                f"""
                import json
                import sys
                from pathlib import Path
                capture = Path({str(capture)!r})
                for line in sys.stdin:
                    with capture.open("a", encoding="utf-8") as stream:
                        stream.write(line)
                    message = json.loads(line)
                    method = message.get("method")
                    if method == "initialize":
                        result = {{"authMethods": [], "agentCapabilities": {{}}}}
                    elif method == "session/new":
                        result = {{"sessionId": "s"}}
                    elif method == "session/close":
                        result = {{}}
                    else:
                        continue
                    print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                """,
            )
            evidence = {
                "evidenceLabel": "production transport/identity evidence",
                "policyProof": False,
                "connection": {
                    "connection_id": "22222222-2222-4222-8222-222222222222",
                    "client_name": "omp-coding-agent",
                    "normalized_client_id": "omp-coding-agent",
                    "helper_peer_pid": 42,
                    "total_tool_calls": 0,
                    "has_in_flight_calls": False,
                    "active_tool_scope_count": 0,
                    "active_tool_scopes": [],
                },
                "process": {
                    "ompACPProcess": {
                        "startIdentityMatch": True,
                        "currentExecutableIdentityMatch": True,
                        "launchCommandExecutableIdentityMatch": True,
                    },
                    "helperProcess": {"pid": 42, "currentExecutableIdentityMatch": True},
                },
                "delta": {
                    "registrationHistorySequence": 10,
                    "newReadyAttributableConnectionCount": 1,
                },
            }
            evidence["terminalConnectionEvidence"] = {
                "evidenceLabel": "terminal exact-connection history evidence",
                "connection_id": "22222222-2222-4222-8222-222222222222",
                "registration_history_sequence": 10,
                "removed_event_count": 1,
                "baseline_preserved": True,
                "removed_event": {
                    "event": "removed",
                    "client_name": "omp-coding-agent",
                    "normalized_client_id": "omp-coding-agent",
                    "helper_peer_pid": 42,
                    "qualification_raw_tool_call_count": 0,
                    "qualification_raw_in_flight_call_count": 0,
                    "active_tool_scope_count": 0,
                },
            }
            summary = spike.acp_probe(
                fake_omp,
                helper,
                workspace,
                output,
                "production-bootstrap",
                1,
                session_open_inspector=lambda _process, _identities: evidence,
            )
            messages = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            methods = [message.get("method") for message in messages]
            self.assertNotIn("session/prompt", methods)
            session_new = next(message for message in messages if message.get("method") == "session/new")
            self.assertEqual(
                session_new["params"]["mcpServers"],
                [{
                    "type": "stdio",
                    "name": "RepoPromptCE",
                    "command": str(helper.resolve()),
                    "args": [],
                    "env": [],
                }],
            )
            self.assertFalse(summary["promptDispatched"])
            self.assertEqual(summary["productionTransportIdentityEvidence"], evidence)
            spike.validate_production_bootstrap_summary(summary)

    def test_production_terminal_connection_requires_one_clean_exact_removal(self) -> None:
        connection_id = "22222222-2222-4222-8222-222222222222"
        evidence = {
            "connection": {"connection_id": connection_id},
            "process": {"helperProcess": {"pid": 42}},
            "delta": {"registrationHistorySequence": 10},
        }
        registered = {
            "seq": 10,
            "event": "registered",
            "connection_id": connection_id,
        }
        removed = {
            "seq": 11,
            "event": "removed",
            "connection_id": connection_id,
            "client_name": "omp-coding-agent",
            "normalized_client_id": "omp-coding-agent",
            "helper_peer_pid": 42,
            "qualification_raw_tool_call_count": 0,
            "qualification_raw_in_flight_call_count": 0,
            "active_tool_scope_count": 0,
        }
        with mock.patch.object(spike, "debug_connection_history", return_value=[registered, removed]) as history:
            result = spike.production_terminal_connection_evidence(Path("/cli"), evidence)
        history.assert_called_once_with(Path("/cli"), connection_id)
        self.assertEqual(result["removed_event_count"], 1)
        self.assertTrue(result["baseline_preserved"])

        cases = [
            ("trailing-call", [registered, {**removed, "qualification_raw_tool_call_count": 1}], "zero-tool"),
            ("ambiguous", [registered, removed, {**removed, "seq": 12}], "ambiguous"),
            (
                "wrong-connection",
                [registered, {**removed, "connection_id": "33333333-3333-4333-8333-333333333333"}],
                "wrong connection UUID",
            ),
            ("missing-terminal", [registered], "missing"),
        ]
        for label, events, expected in cases:
            with (
                self.subTest(label=label),
                mock.patch.object(spike, "debug_connection_history", return_value=events),
                mock.patch.object(spike, "PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS", 0),
            ):
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    spike.production_terminal_connection_evidence(Path("/cli"), evidence)

    def test_production_bootstrap_rejects_unknown_notification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake_omp = self.make_executable(
                root,
                "unknown-notification.py",
                """
                import json
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    method = message.get("method")
                    if method == "initialize":
                        result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new":
                        result = {"sessionId": "s"}
                    elif method == "session/close":
                        result = {}
                    else:
                        continue
                    print(json.dumps({"jsonrpc":"2.0","id":message["id"],"result":result}), flush=True)
                    if method == "session/new":
                        print(json.dumps({"jsonrpc":"2.0","method":"notifications/adversarial","params":{}}), flush=True)
                """,
            )
            helper = self.make_executable(root, "repoprompt-mcp", "print('helper')")
            with self.assertRaisesRegex(spike.ProbeError, "unsupported inbound ACP notification") as context:
                spike.acp_probe(
                    fake_omp,
                    helper,
                    workspace,
                    output,
                    "production-bootstrap",
                    1,
                    session_open_inspector=lambda _process, _identities: {},
                )
            partial = context.exception.details["ompACPPartial"]
            self.assertEqual(partial["unknownNotifications"]["count"], 1)

    def test_production_connection_delta_uses_uuid_with_preexisting_same_name(self) -> None:
        old_id = "11111111-1111-4111-8111-111111111111"
        new_id = "22222222-2222-4222-8222-222222222222"
        before = [{
            "seq": 10,
            "event": "registered",
            "reason": "bootstrap",
            "connection_id": old_id,
            "client_name": "omp-coding-agent",
        }]
        during = before + [
            {
                "seq": 11,
                "event": "registered",
                "reason": "bootstrap",
                "connection_id": "33333333-3333-4333-8333-333333333333",
                "client_name": "RepoPrompt CLI (Interactive)",
            },
            {
                "seq": 12,
                "event": "registered",
                "reason": "bootstrap",
                "connection_id": new_id,
                "client_name": "repoprompt-mcp",
            },
        ]
        snapshot = {
            "id": new_id,
            "client_name": "omp-coding-agent",
            "normalized_client_id": "omp-coding-agent",
            "state": "ready",
            "transport": "bootstrapSocket",
            "session_fingerprint": "sha256:0123456789abcdef",
            "helper_peer_pid": 42,
            "total_tool_calls": 0,
            "has_in_flight_calls": False,
            "active_tool_scope_count": 0,
            "active_tool_scopes": [],
        }
        with (
            mock.patch.object(spike, "debug_connection_history", return_value=during),
            mock.patch.object(spike, "debug_connection_snapshot", return_value=snapshot),
            mock.patch.object(
                spike,
                "inspect_helper_descendant",
                return_value={"parentChain": [], "helperProcess": {"pid": 42}},
            ),
        ):
            result = spike.production_transport_identity_evidence(
                Path("/cli"), before, mock.Mock(), Path("/omp"), Path("/helper"),
                {"ompProcess": {}, "ompLaunchFile": {}, "helperFile": {}},
            )
        self.assertEqual(result["connection"]["connection_id"], new_id)
        self.assertEqual(result["connection"]["client_name"], "omp-coding-agent")
        self.assertEqual(result["connection"]["session_fingerprint"], "sha256:0123456789abcdef")
        self.assertEqual(result["evidenceLabel"], "production transport/identity evidence")
        self.assertFalse(result["policyProof"])

    def test_production_connection_rejects_identity_pid_and_tool_activity_drift(self) -> None:
        connection_id = "22222222-2222-4222-8222-222222222222"
        history = [{
            "seq": 1,
            "event": "registered",
            "reason": "bootstrap",
            "connection_id": connection_id,
            "client_name": "repoprompt-mcp",
        }]
        base = {
            "id": connection_id,
            "client_name": "omp-coding-agent",
            "normalized_client_id": "omp-coding-agent",
            "state": "ready",
            "transport": "bootstrapSocket",
            "helper_peer_pid": 42,
            "total_tool_calls": 0,
            "has_in_flight_calls": False,
            "active_tool_scope_count": 0,
            "active_tool_scopes": [],
        }
        cases = [
            ("wrong authoritative name", {"client_name": "oh-my-pi"}, "identity"),
            ("wrong normalized name", {"normalized_client_id": "oh-my-pi"}, "identity"),
            ("wrong peer", {"helper_peer_pid": 99}, "peer PID"),
            ("historical call", {"total_tool_calls": 1}, "tool activity"),
            ("in flight", {"has_in_flight_calls": True}, "tool activity"),
            ("active scope", {"active_tool_scope_count": 1, "active_tool_scopes": [{"tool_name": "read_file"}]}, "tool activity"),
        ]
        for label, mutation, expected in cases:
            snapshot = {**base, **mutation}
            with (
                self.subTest(label=label),
                mock.patch.object(spike, "debug_connection_history", return_value=history),
                mock.patch.object(spike, "debug_connection_snapshot", return_value=snapshot),
                mock.patch.object(
                    spike,
                    "inspect_helper_descendant",
                    return_value={"helperProcess": {"pid": 42}, "parentChain": []},
                ),
            ):
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    spike.production_transport_identity_evidence(
                        Path("/cli"), [], mock.Mock(), Path("/omp"), Path("/helper"),
                        {"ompProcess": {}, "ompLaunchFile": {}, "helperFile": {}},
                    )

    def test_production_connection_delta_rejects_missing_and_ambiguous(self) -> None:
        before: list[dict[str, Any]] = []
        registration = lambda seq, value: {
            "seq": seq,
            "event": "registered",
            "reason": "bootstrap",
            "connection_id": value,
            "client_name": "repoprompt-mcp",
        }
        cases = [
            ("missing", [], "did not produce exactly one"),
            (
                "ambiguous",
                [registration(1, "11111111-1111-4111-8111-111111111111"),
                 registration(2, "22222222-2222-4222-8222-222222222222")],
                "ambiguous",
            ),
        ]
        for label, during, expected in cases:
            with (
                self.subTest(label=label),
                mock.patch.object(spike, "debug_connection_history", return_value=during),
                mock.patch.object(spike, "PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS", 0),
            ):
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    spike.production_transport_identity_evidence(
                        Path("/cli"), before, mock.Mock(), Path("/omp"), Path("/helper"), {}
                    )

    def test_explicit_debug_cli_override_never_falls_back(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fallback = self.make_executable(root, "rpce-cli-debug", "print('fallback')")
            with (
                mock.patch.dict(os.environ, {"PATH": str(root)}, clear=False),
                self.assertRaisesRegex(spike.ProbeError, "explicit --debug-cli override"),
            ):
                spike.resolve_debug_cli(str(root / "missing"), fallback)

            with (
                mock.patch.dict(
                    os.environ,
                    {"REPOPROMPT_DEBUG_CLI_INSTALL_PATH": str(root / "missing")},
                    clear=False,
                ),
                self.assertRaisesRegex(spike.ProbeError, "explicit REPOPROMPT_DEBUG_CLI_INSTALL_PATH override"),
            ):
                spike.resolve_debug_cli(None, fallback)

            bundled_helper = self.make_executable(root, "repoprompt-mcp", "print('stdio helper')")
            empty_home = root / "empty-home"
            empty_home.mkdir()
            with (
                mock.patch.dict(os.environ, {"PATH": ""}, clear=False),
                mock.patch.object(spike.Path, "home", return_value=empty_home),
                self.assertRaisesRegex(spike.ProbeError, "PATH or the user-space fallback"),
            ):
                os.environ.pop("REPOPROMPT_DEBUG_CLI_INSTALL_PATH", None)
                spike.resolve_debug_cli(None, bundled_helper)

            resolved, provenance = spike.resolve_debug_cli(str(fallback), root / "unused")
            self.assertEqual(resolved, fallback.resolve())
            self.assertEqual(provenance, "--debug-cli")

    def test_debug_history_rejects_malformed_cli_json_and_non_debug_payload(self) -> None:
        cases = [
            ("not-json", "malformed JSON"),
            (
                json.dumps({"ok": False, "op": "connection_history", "error": "unknown tool"}),
                "failed or malformed top-level envelope",
            ),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw), mock.patch.object(spike, "run_text", return_value=raw):
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    spike.debug_connection_history(Path("/rpce-cli-debug"))

    def test_diagnostic_envelope_parsers_accept_only_one_documented_success_path(self) -> None:
        payload = {"ok": True, "op": "connection_history", "events": []}
        documented = [
            payload,
            {"result": payload},
            {"result": {"structuredContent": payload}},
            {"structured_content": payload},
        ]
        for index, value in enumerate(documented):
            with self.subTest(parser="support", index=index):
                self.assertEqual(
                    qualification_support._normalized_response(value, "diagnostic:connection_history"),
                    payload,
                )
            with self.subTest(parser="spike", index=index):
                self.assertEqual(
                    spike.strict_diagnostic_payload(value, "connection_history", "events"),
                    payload,
                )

        adversarial = [
            {"isError": True, "content": [{"text": json.dumps(payload)}]},
            {"error": {"message": json.dumps(payload)}, "result": payload},
            {**payload, "isError": True},
            {"result": {**payload, "error": "failed"}},
            {"result": {"structuredContent": {**payload, "isError": True}}},
            {"structured_content": {**payload, "error": "failed"}},
            {"result": {"structuredContent": {**payload, "isError": "false"}}},
            {**payload, "result": {"ignored": True}},
            {"result": {"structuredContent": payload, "structured_content": payload}},
            {"result": payload, "structuredContent": {**payload, "events": [{"seq": 1}]}},
            {"content": [{"text": json.dumps(payload)}]},
            {"ok": True, "op": "wrong_op", "events": []},
        ]
        raw_cli_fixture = '{"ok":true,"op":"connection_history","events":[]}'
        self.assertEqual(
            qualification_support._normalized_response(
                qualification_support._strict_json_loads(raw_cli_fixture),
                "diagnostic:connection_history",
            ),
            payload,
        )
        self.assertEqual(
            spike.strict_diagnostic_payload(
                spike.strict_response_json(raw_cli_fixture),
                "connection_history",
                "events",
            ),
            payload,
        )
        duplicate = '{"ok":true,"ok":true,"op":"connection_history","events":[]}'
        with self.assertRaisesRegex(qualification_support.SupportError, "duplicate key"):
            qualification_support._strict_json_loads(duplicate)
        with self.assertRaisesRegex(spike.ProbeError, "duplicate key"):
            spike.strict_response_json(duplicate)
        with self.assertRaises(qualification_support.SupportError):
            qualification_support._normalized_response(
                {"status": "running", "session_id": "s", "error": "failed"},
                "agent_run",
            )
        for index, value in enumerate(adversarial):
            with self.subTest(parser="support", index=index):
                with self.assertRaises(qualification_support.SupportError):
                    qualification_support._normalized_response(value, "diagnostic:connection_history")
            with self.subTest(parser="spike", index=index):
                with self.assertRaises(spike.ProbeError):
                    spike.strict_diagnostic_payload(value, "connection_history", "events")

    def test_qualification_snapshot_rejects_gitlinks_and_nested_repositories(self) -> None:
        def git(root: Path, *arguments: str) -> str:
            return subprocess.run(
                ["git", "-C", str(root), *arguments],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ).stdout.strip()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init")
            git(root, "config", "user.email", "qualification@example.invalid")
            git(root, "config", "user.name", "Qualification Fixture")
            (root / "tracked.txt").write_text("base\n", encoding="utf-8")
            git(root, "add", "tracked.txt")
            git(root, "-c", "commit.gpgsign=false", "commit", "-m", "base")
            head = git(root, "rev-parse", "HEAD")
            git(root, "update-index", "--add", "--cacheinfo", f"160000,{head},submodule")
            with self.assertRaisesRegex(qualification_support.SupportError, "gitlink"):
                qualification_support._repository_snapshot(str(root))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init")
            git(root, "config", "user.email", "qualification@example.invalid")
            git(root, "config", "user.name", "Qualification Fixture")
            (root / "tracked.txt").write_text("base\n", encoding="utf-8")
            git(root, "add", "tracked.txt")
            git(root, "-c", "commit.gpgsign=false", "commit", "-m", "base")
            nested = root / "nested"
            nested.mkdir()
            git(nested, "init")
            (nested / "untracked.txt").write_text("nested\n", encoding="utf-8")
            with self.assertRaisesRegex(qualification_support.SupportError, "nested repository"):
                qualification_support._repository_snapshot(str(root))

    def test_qualification_snapshot_rejects_intermediate_swap_mutation_and_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "root"
            outside = Path(tmp) / "outside"
            root.mkdir()
            outside.mkdir()
            (root / "nested").mkdir()
            (root / "nested" / "tracked.txt").write_text("inside", encoding="utf-8")
            (outside / "tracked.txt").write_text("outside", encoding="utf-8")
            root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            real_open = os.open
            swapped = False

            def racing_open(path: object, flags: int, mode: int = 0o777, *, dir_fd: int | None = None) -> int:
                nonlocal swapped
                if path == b"nested" and dir_fd is not None and not swapped:
                    swapped = True
                    (root / "nested").rename(root / "original")
                    (root / "nested").symlink_to(outside, target_is_directory=True)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            try:
                with mock.patch.object(qualification_support.os, "open", side_effect=racing_open):
                    with self.assertRaisesRegex(qualification_support.SupportError, "unsafe or unstable"):
                        qualification_support._hash_worktree_path(
                            root_descriptor,
                            b"nested/tracked.txt",
                            hashlib.sha256(),
                            time.monotonic() + 2,
                        )
            finally:
                os.close(root_descriptor)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "tracked.txt"
            target.write_bytes(b"AAAA")
            root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            real_read = os.read
            mutated = False

            def mutating_read(descriptor: int, count: int) -> bytes:
                nonlocal mutated
                chunk = real_read(descriptor, count)
                if chunk and not mutated:
                    mutated = True
                    target.write_bytes(b"BBBB")
                return chunk

            try:
                with mock.patch.object(qualification_support.os, "read", side_effect=mutating_read):
                    with self.assertRaisesRegex(qualification_support.SupportError, "changed during snapshot"):
                        qualification_support._hash_worktree_path(
                            root_descriptor,
                            b"tracked.txt",
                            hashlib.sha256(),
                            time.monotonic() + 2,
                        )
                with self.assertRaisesRegex(qualification_support.SupportError, "deadline"):
                    qualification_support._hash_worktree_path(
                        root_descriptor,
                        b"tracked.txt",
                        hashlib.sha256(),
                        time.monotonic() - 1,
                    )
            finally:
                os.close(root_descriptor)

    def test_qualification_snapshot_fifo_leaf_swap_is_nonblocking_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "tracked.txt"
            target.write_text("tracked", encoding="utf-8")
            root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            real_stat = os.stat
            swapped = False

            def racing_stat(path: object, *args: object, **kwargs: object) -> os.stat_result:
                nonlocal swapped
                info = real_stat(path, *args, **kwargs)
                if path == b"tracked.txt" and not swapped:
                    swapped = True
                    target.unlink()
                    os.mkfifo(target)
                return info

            def alarm_handler(_signal: int, _frame: object) -> None:
                raise TimeoutError("FIFO leaf open blocked")

            previous_handler = signal.signal(signal.SIGALRM, alarm_handler)
            signal.setitimer(signal.ITIMER_REAL, 1)
            try:
                with mock.patch.object(qualification_support.os, "stat", side_effect=racing_stat):
                    with self.assertRaisesRegex(qualification_support.SupportError, "file changed"):
                        qualification_support._hash_worktree_path(
                            root_descriptor,
                            b"tracked.txt",
                            hashlib.sha256(),
                            time.monotonic() + 2,
                        )
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous_handler)
                os.close(root_descriptor)

    def test_process_inspection_uses_live_handle_and_scopes_helper_matches_to_omp_tree(self) -> None:
        omp = Path("/bin/echo")
        helper = Path("/bin/cat")
        prefix = "Mon Aug 10 12:34:56 2026"
        process = mock.Mock(pid=10, args=[str(omp), "acp"])
        process.poll.return_value = None
        concurrent = (
            f"10 1 {prefix} {omp}\n"
            f"20 10 {prefix} {helper}\n"
            f"30 1 {prefix} {helper}\n"
        )
        concurrent_rows = spike.parse_process_snapshot(concurrent)
        launch_omp_identity = spike.capture_executable_file_identity(omp)
        launch_helper_identity = spike.capture_executable_file_identity(helper)
        expected_process_identity = {
            "pid": 10,
            "startTime": prefix,
            "runtimeExecutable": str(omp.resolve()),
            "runtimeExecutableFileIdentity": launch_omp_identity,
        }
        result = spike.inspect_helper_descendant(
            process,
            omp,
            helper,
            expected_omp_process_identity=expected_process_identity,
            expected_omp_launch_file_identity=launch_omp_identity,
            expected_helper_file_identity=launch_helper_identity,
            snapshot_text=concurrent,
            executable_resolver=lambda pid: Path(concurrent_rows[pid]["executable"]),
        )
        self.assertEqual(result["helperProcess"]["pid"], 20)
        self.assertEqual(result["ompACPProcess"]["runtimeExecutable"], str(omp.resolve()))
        self.assertTrue(result["ompACPProcess"]["startIdentityMatch"])
        self.assertTrue(result["ompACPProcess"]["currentExecutableIdentityMatch"])
        self.assertTrue(result["helperProcess"]["currentExecutableIdentityMatch"])
        self.assertEqual(result["ompACPProcess"]["launchedExecutable"], str(omp.resolve()))

        cases = [
            (
                "zero-in-tree-with-unrelated-helper",
                f"10 1 {prefix} {omp}\n30 1 {prefix} {helper}\n",
                "exactly one bundled-helper descendant",
            ),
            (
                "multiple",
                f"10 1 {prefix} {omp}\n20 10 {prefix} {helper}\n21 10 {prefix} {helper}\n",
                "exactly one bundled-helper descendant",
            ),
            (
                "wrong-helper-path",
                f"10 1 {prefix} {omp}\n20 10 {prefix} /tmp/{helper.name}\n",
                "wrong executable path",
            ),
        ]
        for label, snapshot, expected in cases:
            with self.subTest(label=label):
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    rows = spike.parse_process_snapshot(snapshot)
                    spike.inspect_helper_descendant(
                        process,
                        omp,
                        helper,
                        expected_omp_process_identity=expected_process_identity,
                        expected_omp_launch_file_identity=launch_omp_identity,
                        expected_helper_file_identity=launch_helper_identity,
                        snapshot_text=snapshot,
                        executable_resolver=lambda pid: Path(rows[pid]["executable"]),
                    )

    def test_process_inspection_rejects_start_exec_and_same_path_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            omp = self.make_executable(root, "omp", "print('omp')")
            replacement = self.make_executable(root, "replacement", "print('replacement')")
            helper = self.make_executable(root, "helper", "print('helper')")
            prefix = "Mon Aug 10 12:34:56 2026"
            snapshot = f"10 1 {prefix} {omp}\n20 10 {prefix} {helper}\n"
            rows = spike.parse_process_snapshot(snapshot)
            process = mock.Mock(pid=10, args=[str(omp), "acp"])
            process.poll.return_value = None
            omp_file_identity = spike.capture_executable_file_identity(omp)
            helper_file_identity = spike.capture_executable_file_identity(helper)
            expected = {
                "pid": 10,
                "startTime": prefix,
                "runtimeExecutable": str(omp.resolve()),
                "runtimeExecutableFileIdentity": omp_file_identity,
            }
            arguments = dict(
                omp_process=process,
                omp=omp,
                helper=helper,
                expected_omp_launch_file_identity=omp_file_identity,
                expected_helper_file_identity=helper_file_identity,
                snapshot_text=snapshot,
            )

            with self.assertRaisesRegex(spike.ProbeError, "start identity"):
                spike.inspect_helper_descendant(
                    expected_omp_process_identity={**expected, "startTime": "Mon Aug 10 12:34:55 2026"},
                    executable_resolver=lambda pid: Path(rows[pid]["executable"]),
                    **arguments,
                )
            with self.assertRaisesRegex(spike.ProbeError, "runtime executable identity"):
                spike.inspect_helper_descendant(
                    expected_omp_process_identity=expected,
                    executable_resolver=lambda pid: replacement if pid == 10 else Path(rows[pid]["executable"]),
                    **arguments,
                )

            omp.write_text("#!/usr/bin/env python3\nprint('same-path replacement')\n", encoding="utf-8")
            omp.chmod(0o755)
            with self.assertRaisesRegex(spike.ProbeError, "launched OMP executable file identity"):
                spike.inspect_helper_descendant(
                    expected_omp_process_identity=expected,
                    executable_resolver=lambda pid: Path(rows[pid]["executable"]),
                    **arguments,
                )

    def test_production_bootstrap_inspector_failure_still_closes_and_writes_error_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            capture = root / "methods"
            fake_omp = self.make_executable(
                root,
                "production-cleanup.py",
                f"""
                import json
                import sys
                from pathlib import Path
                capture = Path({str(capture)!r})
                for line in sys.stdin:
                    message = json.loads(line)
                    with capture.open("a", encoding="utf-8") as stream:
                        stream.write(str(message.get("method")) + "\\n")
                    if message.get("method") == "initialize":
                        result = {{"authMethods": [], "agentCapabilities": {{}}}}
                    elif message.get("method") == "session/new":
                        result = {{"sessionId": "s"}}
                    elif message.get("method") == "session/close":
                        result = {{}}
                    else:
                        continue
                    print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                """,
            )
            with self.assertRaisesRegex(spike.ProbeError, "diagnostic failed") as context:
                spike.acp_probe(
                    fake_omp,
                    self.make_executable(root, "helper", "print('helper')"),
                    workspace,
                    output,
                    "production-bootstrap",
                    1,
                    session_open_inspector=lambda _process, _identities: (_ for _ in ()).throw(
                        spike.ProbeError("diagnostic failed", {"safe": True})
                    ),
                )
            self.assertIn("session/close", capture.read_text(encoding="utf-8").splitlines())
            self.assertTrue((output / "omp-acp.stdout.jsonl").exists())
            partial = context.exception.details["ompACPPartial"]
            self.assertEqual(partial["mcpServerKind"], "production-bundled-repoprompt-mcp")
            self.assertFalse(partial["promptDispatched"])
            self.assertEqual(partial["permissionEvents"], [])
            self.assertEqual(partial["unknownUpdateKinds"], [])
            self.assertEqual(partial["unexpectedInboundRequests"]["count"], 0)

    def test_workspace_names_are_bounded_in_success_and_partial_evidence(self) -> None:
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                for index in range(300):
                    (workspace / f"file-{index:03d}").touch()
                fake = self.make_executable(
                    root,
                    "bounded-names.py",
                    """
                    import json
                    import sys
                    for line in sys.stdin:
                        message = json.loads(line)
                        method = message.get("method")
                        if method == "initialize":
                            result = {"authMethods": [], "agentCapabilities": {}}
                        elif method == "session/new":
                            result = {"sessionId": "s"}
                        elif method == "session/close":
                            result = {}
                        else:
                            continue
                        print(json.dumps({"jsonrpc":"2.0","id":message["id"],"result":result}), flush=True)
                    """,
                )
                if interrupted:
                    original = spike.JSONLProcess.wait_for_response
                    def interrupt_close(process: spike.JSONLProcess, request_id: int, timeout: float, handler: Any = None) -> dict[str, Any]:
                        if request_id == 99:
                            raise KeyboardInterrupt()
                        return original(process, request_id, timeout, handler)
                    with mock.patch.object(spike.JSONLProcess, "wait_for_response", new=interrupt_close):
                        with self.assertRaises(spike.ProbeError) as context:
                            spike.acp_probe(fake, root / "helper", workspace, output, "bootstrap", 1)
                    evidence = context.exception.details["ompACPPartial"]
                else:
                    evidence = spike.acp_probe(fake, root / "helper", workspace, output, "bootstrap", 1)
                self.assertEqual(len(evidence["workspaceFileNames"]), 200)
                self.assertTrue(evidence["workspaceFileNamesTruncated"])

    def test_preparation_cleanup_marker_snapshot_and_chmod_failures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            created = root / "created"
            def make_created(*_args: Any, **_kwargs: Any) -> str:
                created.mkdir()
                return str(created)
            with (
                mock.patch.object(spike.tempfile, "mkdtemp", side_effect=make_created),
                mock.patch.object(spike.os, "chmod", side_effect=OSError("chmod failed")),
                self.assertRaisesRegex(spike.ProbeError, "chmod failed"),
            ):
                spike.prepare_output_directory(None, repo)
            self.assertFalse(created.exists())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "caller-workspace"
            output = root / "owned-output"
            target = root / "outside"
            workspace.mkdir()
            output.mkdir()
            target.write_text("outside", encoding="utf-8")
            (workspace / ".omp-live-spike-readonly-marker").symlink_to(target)
            args = Namespace(
                phase="preflight", omp="fake", app_bundle=root / "Fake.app",
                workspace=workspace, unsafe_allow_nonempty_workspace=True,
                output_dir=root, prompt_timeout=1,
            )
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
            ):
                self.assertEqual(spike.main(), 2)
            self.assertFalse(output.exists())
            self.assertTrue(workspace.exists())
            self.assertTrue((workspace / ".omp-live-spike-readonly-marker").is_symlink())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "owned-workspace"
            output = root / "owned-output"
            workspace.mkdir()
            output.mkdir()
            args = Namespace(
                phase="preflight", omp="fake", app_bundle=root / "Fake.app",
                workspace=None, unsafe_allow_nonempty_workspace=False,
                output_dir=None, prompt_timeout=1,
            )
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, True)),
                mock.patch.object(spike, "snapshot_workspace", side_effect=KeyboardInterrupt()),
            ):
                self.assertEqual(spike.main(), 2)
            self.assertFalse(workspace.exists())
            self.assertFalse(output.exists())

    def test_cli_keyboard_interrupt_writes_evidence_and_reaps_group(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            pid_file = root / "pid"
            executable = self.make_executable(
                root,
                "cli-interrupt.py",
                f"""
                import os
                import time
                from pathlib import Path
                Path({str(pid_file)!r}).write_text(str(os.getpid()), encoding="utf-8")
                print("partial", flush=True)
                time.sleep(30)
                """,
            )
            def interrupt_wait(process: spike.BoundedTextProcess, _timeout: float) -> tuple[int, str, str]:
                deadline = time.monotonic() + 1
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                process.close()
                raise KeyboardInterrupt()
            with (
                mock.patch.object(spike.BoundedTextProcess, "wait", new=interrupt_wait),
                self.assertRaisesRegex(spike.ProbeError, "KeyboardInterrupt"),
            ):
                spike.cli_prompt_probe(executable, workspace, output, 1)
            pid = int(pid_file.read_text(encoding="utf-8"))
            self.assertFalse(spike.process_group_exists(pid))
            self.assertTrue((output / "omp-cli-prompt.stdout.txt").exists())
            self.assertTrue((output / "omp-cli-prompt.stderr.txt").exists())

    def test_snapshot_and_tree_do_not_follow_external_symlink_and_reject_fifo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            outside = root / "outside"
            workspace.mkdir()
            outside.mkdir()
            external = outside / "large"
            external.write_bytes(b"x" * 100)
            link = workspace / "link"
            link.symlink_to(external)
            with mock.patch.object(spike, "hash_regular_file") as hash_mock:
                snapshot = spike.snapshot_workspace(
                    workspace, file_byte_limit=1, aggregate_byte_limit=1, deadline_seconds=1
                )
                tree = spike.readonly_workspace_tree(workspace, deadline_seconds=1)
            hash_mock.assert_not_called()
            self.assertEqual(snapshot["link"]["kind"], "symlink")
            self.assertEqual(snapshot["link"]["target"], str(external))
            self.assertIn({"path": "link", "kind": "symlink"}, tree)

            fifo = workspace / "pipe"
            os.mkfifo(fifo)
            started = time.monotonic()
            with self.assertRaisesRegex(spike.ProbeError, "unsupported"):
                spike.snapshot_workspace(workspace, deadline_seconds=1)
            with self.assertRaisesRegex(spike.ProbeError, "unsupported"):
                spike.readonly_workspace_tree(workspace, deadline_seconds=1)
            self.assertLess(time.monotonic() - started, 1)

            workspace_link = root / "workspace-link"
            workspace_link.symlink_to(workspace, target_is_directory=True)
            with self.assertRaisesRegex(spike.ProbeError, "root is not a directory"):
                spike.snapshot_workspace(workspace_link, deadline_seconds=1)
            with self.assertRaisesRegex(spike.ProbeError, "root is not a directory"):
                spike.readonly_workspace_tree(workspace_link, deadline_seconds=1)

    def test_traversal_swap_before_child_open_fails_closed(self) -> None:
        for walker in (spike.snapshot_workspace, spike.readonly_workspace_tree):
            with self.subTest(walker=walker.__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                outside = root / "outside"
                child = workspace / "d"
                child.mkdir(parents=True)
                outside.mkdir()
                (child / "original").write_text("ok", encoding="utf-8")
                (outside / "sentinel").write_text("external", encoding="utf-8")
                original_open = spike._open_directory_fd
                swapped = False

                def swap_before(name: Any, *, dir_fd: int | None = None) -> int:
                    nonlocal swapped
                    if name == "d" and dir_fd is not None and not swapped:
                        swapped = True
                        child.rename(workspace / "d-original")
                        child.symlink_to(outside, target_is_directory=True)
                    return original_open(name, dir_fd=dir_fd)

                with mock.patch.object(spike, "_open_directory_fd", side_effect=swap_before):
                    with self.assertRaises(spike.ProbeError):
                        walker(workspace, deadline_seconds=1)

    def test_non_reading_permission_flood_terminates_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            pid_file = root / "pid"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "permission-flood.py",
                f"""
                import json
                import os
                import signal
                import sys
                from pathlib import Path
                Path({str(pid_file)!r}).write_text(str(os.getpid()), encoding="utf-8")
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize":
                        result = {{"authMethods": [], "agentCapabilities": {{}}}}
                    elif method == "session/new":
                        result = {{"sessionId": "s"}}
                    elif method == "session/prompt":
                        for index in range(500):
                            permission = {{"jsonrpc":"2.0","id":1000 + index,"method":"session/request_permission","params":{{"sessionId":"s","toolCall":{{"title":"blocked"}}}}}}
                            print(json.dumps(permission), flush=True)
                        signal.pause()
                    else:
                        result = {{}}
                    print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                """,
            )
            sent: list[dict[str, Any]] = []
            original_send = spike.JSONLProcess.send

            def record_send(process: spike.JSONLProcess, payload: dict[str, Any]) -> None:
                sent.append(payload)
                original_send(process, payload)

            started = time.monotonic()
            with (
                mock.patch.object(spike.JSONLProcess, "send", new=record_send),
                self.assertRaises(spike.ProbeError) as context,
            ):
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 2)
            self.assertLess(time.monotonic() - started, 5)
            partial = context.exception.details["ompACPPartial"]
            self.assertEqual(len(partial["permissionEvents"]), 1)
            self.assertEqual(partial["permissionEvents"][0]["sessionId"], "s")
            self.assertEqual(partial["permissionEvents"][0]["lifecyclePhase"], "prompt-dispatched")
            self.assertEqual([item.get("method") for item in sent], ["initialize", "session/new", "session/prompt"])
            self.assertTrue((output / "omp-acp.stdout.jsonl").exists())
            self.assertFalse(spike.process_group_exists(int(pid_file.read_text(encoding="utf-8"))))

    def test_session_update_lifecycle_metadata_and_post_close_rules(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "metadata.py",
                """
                import json
                import sys
                import time
                def update(value):
                    return {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":value}}
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize":
                        result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new":
                        result = {"sessionId": "s"}
                        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                        time.sleep(0.03)
                        print(json.dumps(update({"sessionUpdate":"available_commands_update","availableCommands":[]})), flush=True)
                        print(json.dumps(update({"sessionUpdate":"session_info_update","updatedAt":"2026-08-10T10:55:54.990Z"})), flush=True)
                        continue
                    elif method == "session/close":
                        result = {}
                    else:
                        continue
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            summary = spike.acp_probe(fake, root / "helper", workspace, output, "bootstrap", 1)
            self.assertEqual(
                summary["observedUpdateKinds"], ["available_commands_update", "session_info_update"]
            )
            self.assertTrue(all(record["lifecyclePhase"] == "session-open" for record in summary["sessionEventRecords"]))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "post-close-metadata.py",
                """
                import json
                import sys
                import time
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId": "s"}
                    elif method == "session/prompt":
                        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"OMP_ACP_PROMPT_OK"}}}}), flush=True)
                        result = {"stopReason":"anything"}
                    elif method == "session/close":
                        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":{}}), flush=True)
                        time.sleep(0.03)
                        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"late"}}}), flush=True)
                        break
                    else: continue
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            with self.assertRaisesRegex(spike.ProbeError, "after session close began") as context:
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
            record = context.exception.details["ompACPPartial"]["sessionEventRecords"][-1]
            self.assertEqual(record["kind"], "session_info_update")
            self.assertEqual(record["lifecyclePhase"], "closed")

    def test_session_info_update_allows_titleless_delta_but_rejects_malformed_title(self) -> None:
        self.assertEqual(
            spike.validate_known_update_payload(
                "session_info_update",
                {"sessionUpdate": "session_info_update", "updatedAt": "2026-08-10T10:55:54.990Z"},
            ),
            {},
        )
        self.assertEqual(
            spike.validate_known_update_payload(
                "session_info_update",
                {"sessionUpdate": "session_info_update", "title": "safe"},
            ),
            {},
        )
        with self.assertRaisesRegex(spike.ProbeError, "title must be a string"):
            spike.validate_known_update_payload(
                "session_info_update",
                {"sessionUpdate": "session_info_update", "title": 7},
            )

    def test_known_update_payload_conflicts_and_malformed_shapes_are_terminal(self) -> None:
        cases = {
            "malformed-chunk": {"sessionUpdate":"agent_message_chunk","content":{"wrong":"value"}},
            "malformed-thought": {"sessionUpdate":"agent_thought_chunk","content":{"wrong":"value"}},
            "malformed-user": {"sessionUpdate":"user_message_chunk","content":[{"wrong":"value"}]},
            "malformed-usage": {"sessionUpdate":"usage_update","used":"not-a-number"},
            "unvalidated-plan": {"sessionUpdate":"plan","entries":[]},
            "conflicting-title": {"sessionUpdate":"tool_call","toolCallId":"id","title":"safe","toolCall":{"toolCallId":"id","title":"other"}},
            "conflicting-id": {"sessionUpdate":"tool_call","toolCallId":"one","title":"safe","toolCall":{"id":"two","title":"safe"}},
            "empty-id": {"sessionUpdate":"tool_call","toolCallId":"","title":"safe"},
            "whitespace-id": {"sessionUpdate":"tool_call","toolCallId":" \t ","title":"safe"},
            "malformed-tool": {"sessionUpdate":"tool_call","toolCallId":7,"title":"safe"},
        }
        for label, event in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                fake = self.make_executable(
                    root,
                    "malformed-update.py",
                    f"""
                    import json
                    import sys
                    event = {event!r}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize": result = {{"authMethods": [], "agentCapabilities": {{}}}}
                        elif method == "session/new": result = {{"sessionId":"s"}}
                        elif method == "session/prompt":
                            print(json.dumps({{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":event}}}}), flush=True)
                            print(json.dumps({{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s","update":{{"sessionUpdate":"agent_message_chunk","content":{{"text":"OMP_ACP_PROMPT_OK"}}}}}}}}), flush=True)
                            result = {{"stopReason":"end_turn"}}
                        elif method == "session/close": result = {{}}
                        else: continue
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                    """,
                )
                with self.assertRaises(spike.ProbeError) as context:
                    spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
                partial = context.exception.details["ompACPPartial"]
                self.assertEqual(partial["sessionEventRecords"][0]["kind"], event["sessionUpdate"])
                if event["sessionUpdate"] == "tool_call":
                    record = partial["toolEventRecords"][0]
                    self.assertEqual(record["titleRepresentations"], [
                        value for value in (event.get("title"), event.get("toolCall", {}).get("title"))
                        if value is not None
                    ])
                    self.assertEqual(record["idRepresentations"], [
                        source[key]
                        for source in (event, event.get("toolCall", {}))
                        for key in ("toolCallId", "id")
                        if key in source
                    ])
                self.assertTrue((output / "omp-acp.stdout.jsonl").exists())

        canonical = spike.validate_known_update_payload(
            "tool_call",
            {"sessionUpdate":"tool_call","toolCallId":"same","id":"same","title":"same", "toolCall":{"toolCallId":"same","id":"same","title":"same"}},
        )
        self.assertEqual(canonical, {"title":"same", "toolCallId":"same"})

    def test_usage_update_accepts_real_compatible_shape_and_rejects_malformed_fields(self) -> None:
        self.assertEqual(
            spike.validate_known_update_payload(
                "usage_update",
                {
                    "sessionUpdate": "usage_update",
                    "used": 12_345,
                    "size": 200_000,
                    "cost": {"amount": 0.031, "currency": "USD"},
                },
            ),
            {},
        )
        malformed = [
            {"sessionUpdate": "usage_update"},
            {"sessionUpdate": "usage_update", "used": True},
            {"sessionUpdate": "usage_update", "size": 1.5},
            {"sessionUpdate": "usage_update", "cost": {}},
            {"sessionUpdate": "usage_update", "cost": {"amount": float("nan")}},
            {"sessionUpdate": "usage_update", "cost": {"amount": 1, "extra": "field"}},
        ]
        for update in malformed:
            with self.subTest(update=update), self.assertRaises(spike.ProbeError):
                spike.validate_known_update_payload("usage_update", update)

    def test_traversal_swap_after_child_open_pins_original(self) -> None:
        for walker in (spike.snapshot_workspace, spike.readonly_workspace_tree):
            with self.subTest(walker=walker.__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                outside = root / "outside"
                child = workspace / "d"
                child.mkdir(parents=True)
                outside.mkdir()
                (child / "original").write_text("ok", encoding="utf-8")
                (outside / "sentinel").write_text("external", encoding="utf-8")
                original_open = spike._open_directory_fd
                swapped = False

                def swap_after(name: Any, *, dir_fd: int | None = None) -> int:
                    nonlocal swapped
                    descriptor = original_open(name, dir_fd=dir_fd)
                    if name == "d" and dir_fd is not None and not swapped:
                        swapped = True
                        child.rename(workspace / "d-original")
                        child.symlink_to(outside, target_is_directory=True)
                    return descriptor

                with mock.patch.object(spike, "_open_directory_fd", side_effect=swap_after):
                    result = walker(workspace, deadline_seconds=1)
                paths = set(result) if isinstance(result, dict) else {item["path"] for item in result}
                self.assertIn("d/original", paths)
                self.assertNotIn("d/sentinel", paths)

    def test_snapshot_growth_uses_descriptor_size_and_actual_aggregate_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "file"
            target.write_bytes(b"a")
            original_open = spike._open_regular_fd
            grew = False

            def grow_within(name: Any, *, dir_fd: int) -> int:
                nonlocal grew
                descriptor = original_open(name, dir_fd=dir_fd)
                if name == "file" and not grew:
                    grew = True
                    target.write_bytes(b"abcd")
                return descriptor

            with mock.patch.object(spike, "_open_regular_fd", side_effect=grow_within):
                snapshot = spike.snapshot_workspace(root, file_byte_limit=8, aggregate_byte_limit=8, deadline_seconds=1)
            self.assertEqual(snapshot["file"]["size"], 4)
            self.assertEqual(snapshot["file"]["sha256"], spike.hashlib.sha256(b"abcd").hexdigest())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "a"
            second = root / "b"
            first.write_bytes(b"a")
            second.write_bytes(b"b")
            original_open = spike._open_regular_fd
            grew = False

            def grow_over_aggregate(name: Any, *, dir_fd: int) -> int:
                nonlocal grew
                descriptor = original_open(name, dir_fd=dir_fd)
                if name == "b" and not grew:
                    grew = True
                    second.write_bytes(b"bbbb")
                return descriptor

            with (
                mock.patch.object(spike, "_open_regular_fd", side_effect=grow_over_aggregate),
                self.assertRaisesRegex(spike.ProbeError, "aggregate byte limit"),
            ):
                spike.snapshot_workspace(root, file_byte_limit=8, aggregate_byte_limit=4, deadline_seconds=1)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "file"
            target.write_bytes(b"a")
            original_open = spike._open_regular_fd

            def grow_over_file(name: Any, *, dir_fd: int) -> int:
                descriptor = original_open(name, dir_fd=dir_fd)
                target.write_bytes(b"abcdef")
                return descriptor

            with (
                mock.patch.object(spike, "_open_regular_fd", side_effect=grow_over_file),
                self.assertRaisesRegex(spike.ProbeError, "exceeds 4 bytes"),
            ):
                spike.snapshot_workspace(root, file_byte_limit=4, aggregate_byte_limit=10, deadline_seconds=1)

    def test_wait_for_response_defers_coalesced_frames_until_state_transition(self) -> None:
        process = object.__new__(spike.JSONLProcess)
        process.stdout_lines = [
            '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s"}}',
            '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"ready"}}}',
        ]
        process.messages = []
        process._processed_lines = 0
        process._stream_sizes = {"stdout": 200, "stderr": 0}
        process._overflow = None
        process._protocol_error = None
        process._pending_requests = {3: "session/new"}
        process._completed_response_ids = set()
        process._lock = threading.Lock()
        process.message_limit = 10
        observed: list[dict[str, Any]] = []

        process.drain(observed.append, stop_after_response_id=3)
        self.assertEqual(process._processed_lines, 1)
        self.assertEqual(observed, [process.messages[0]])
        process.drain(observed.append)
        self.assertEqual(process._processed_lines, 2)
        self.assertEqual(observed[-1]["method"], "session/update")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "coalesced-session.py",
                """
                import json
                import os
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new":
                        response = {"jsonrpc":"2.0","id":request_id,"result":{"sessionId":"s"}}
                        metadata = {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"ready"}}}
                        os.write(1, (json.dumps(response) + "\\n" + json.dumps(metadata) + "\\n").encode())
                        continue
                    elif method == "session/close": result = {}
                    else: continue
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            summary = spike.acp_probe(fake, root / "helper", workspace, output, "bootstrap", 1)
            self.assertEqual(summary["sessionEventRecords"][0]["lifecyclePhase"], "session-open")

    def test_coalesced_prompt_response_trailing_update_is_post_prompt_terminal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "coalesced-prompt.py",
                """
                import json
                import os
                import sys
                def update(text):
                    return {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":text}}}}
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId":"s"}
                    elif method == "session/prompt":
                        frames = [update("OMP_ACP_PROMPT_OK"), {"jsonrpc":"2.0","id":request_id,"result":{"stopReason":"end_turn"}}, update("late")]
                        os.write(1, ("\\n".join(json.dumps(frame) for frame in frames) + "\\n").encode())
                        continue
                    elif method == "session/close": result = {}
                    else: continue
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            with self.assertRaisesRegex(spike.ProbeError, "outside prompt dispatch") as context:
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
            records = context.exception.details["ompACPPartial"]["sessionEventRecords"]
            self.assertEqual(records[-1]["lifecyclePhase"], "prompt-complete")

    def test_string_id_permission_request_is_recorded_terminal_and_unanswered(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "string-permission-request.py",
                """
                import json
                import signal
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId":"s"}
                    elif method == "session/prompt":
                        permission = {
                            "jsonrpc": "2.0",
                            "id": "agent-permission-1",
                            "method": "session/request_permission",
                            "params": {
                                "sessionId": "s",
                                "toolCall": {"title": "blocked"}
                            }
                        }
                        print(json.dumps(permission), flush=True)
                        signal.pause()
                    else: result = {}
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            sent: list[dict[str, Any]] = []
            original_send = spike.JSONLProcess.send

            def record_send(process: spike.JSONLProcess, payload: dict[str, Any]) -> None:
                sent.append(payload)
                original_send(process, payload)

            with (
                mock.patch.object(spike.JSONLProcess, "send", new=record_send),
                self.assertRaisesRegex(spike.ProbeError, "permission request") as context,
            ):
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)

            permission_events = context.exception.details["ompACPPartial"]["permissionEvents"]
            self.assertEqual(len(permission_events), 1)
            self.assertEqual(permission_events[0]["title"], "blocked")
            self.assertEqual(permission_events[0]["response"], "terminal-no-response")
            self.assertEqual(
                [item.get("method") for item in sent],
                ["initialize", "session/new", "session/prompt"],
            )
            self.assertNotIn("agent-permission-1", [item.get("id") for item in sent])

    def test_unsupported_inbound_requests_are_recorded_terminal_and_unanswered(self) -> None:
        cases = {
            "fs": {"jsonrpc":"2.0","id":"agent-fs-500","method":"fs/read_text_file","params":{"sessionId":"s","path":"x"}},
            "id-update": {"jsonrpc":"2.0","id":501,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"OMP_ACP_PROMPT_OK"}}}},
        }
        for label, inbound in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                fake = self.make_executable(
                    root,
                    "unsupported-request.py",
                    f"""
                    import json
                    import signal
                    import sys
                    inbound = {inbound!r}
                    for line in sys.stdin:
                        message = json.loads(line)
                        request_id = message.get("id")
                        method = message.get("method")
                        if method == "initialize": result = {{"authMethods": [], "agentCapabilities": {{}}}}
                        elif method == "session/new": result = {{"sessionId":"s"}}
                        elif method == "session/prompt":
                            print(json.dumps(inbound), flush=True)
                            signal.pause()
                        else: result = {{}}
                        print(json.dumps({{"jsonrpc":"2.0","id":request_id,"result":result}}), flush=True)
                    """,
                )
                sent: list[dict[str, Any]] = []
                original_send = spike.JSONLProcess.send
                def record_send(process: spike.JSONLProcess, payload: dict[str, Any]) -> None:
                    sent.append(payload)
                    original_send(process, payload)
                with (
                    mock.patch.object(spike.JSONLProcess, "send", new=record_send),
                    self.assertRaisesRegex(spike.ProbeError, "unsupported inbound ACP request") as context,
                ):
                    spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
                unexpected = context.exception.details["ompACPPartial"]["unexpectedInboundRequests"]
                self.assertEqual(unexpected["count"], 1)
                self.assertEqual(unexpected["records"][0]["id"], inbound["id"])
                self.assertEqual([item.get("method") for item in sent], ["initialize", "session/new", "session/prompt"])
                self.assertNotIn(inbound["id"], [item.get("id") for item in sent])
                self.assertTrue((output / "omp-acp.stdout.jsonl").exists())

        empty = {"count": 0, "records": []}
        bad = {"count": 1, "records": [{"method":"fs/read_text_file","id":1}]}
        with self.assertRaises(spike.ProbeError):
            spike.validate_prompt_summary({"agentAcknowledgementObserved": True, "unexpectedInboundRequests": bad})
        with self.assertRaises(spike.ProbeError):
            spike.validate_bootstrap_summary({"unexpectedInboundRequests": bad})
        valid_roundtrip = {
            "unexpectedInboundRequests": empty, "permissionEvents": [], "agentAcknowledgementObserved": True,
            "toolEventRecords": [{"kind":"tool_call","toolCallId":"x","title":"mcp__repopromptce_get_file_tree"}],
            "unattributedToolEventCount": 0,
        }
        spike.validate_roundtrip_summary(valid_roundtrip)
        with self.assertRaises(spike.ProbeError):
            spike.validate_roundtrip_summary({**valid_roundtrip, "unexpectedInboundRequests": bad})

    def test_process_constructor_thread_start_failures_rollback_groups(self) -> None:
        for wrapper, injected, fail_call in (
            (spike.BoundedTextProcess, RuntimeError("start failed"), 2),
            (spike.JSONLProcess, KeyboardInterrupt(), 2),
            (spike.BoundedTextProcess, KeyboardInterrupt(), 1),
            (spike.JSONLProcess, RuntimeError("first start failed"), 1),
        ):
            with self.subTest(wrapper=wrapper.__name__, fail_call=fail_call), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                child_pid_file = root / "child-pid"
                executable = self.make_executable(
                    root,
                    "constructor-child.py",
                    f"""
                    import signal
                    import subprocess
                    from pathlib import Path
                    child = subprocess.Popen(["sleep", "30"])
                    Path({str(child_pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    signal.pause()
                    """,
                )
                original_start = threading.Thread.start
                original_popen = subprocess.Popen
                calls = 0
                captured: list[subprocess.Popen[Any]] = []

                def capture_popen(*args: Any, **kwargs: Any) -> subprocess.Popen[Any]:
                    process = original_popen(*args, **kwargs)
                    captured.append(process)
                    return process

                def fail_second_start(thread: threading.Thread) -> None:
                    nonlocal calls
                    calls += 1
                    if calls < fail_call:
                        original_start(thread)
                        return
                    deadline = time.monotonic() + 2
                    while not child_pid_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(child_pid_file.exists())
                    raise injected

                kwargs: dict[str, Any] = {"termination_grace_seconds": 0.2}
                if wrapper is spike.JSONLProcess:
                    kwargs["cwd"] = root
                with (
                    mock.patch.object(spike.subprocess, "Popen", side_effect=capture_popen),
                    mock.patch.object(spike.threading.Thread, "start", new=fail_second_start),
                    self.assertRaises(type(injected)),
                ):
                    wrapper([str(executable)], **kwargs)
                self.assertEqual(len(captured), 1)
                process = captured[0]
                child_pid = int(child_pid_file.read_text(encoding="utf-8"))
                deadline = time.monotonic() + 2
                while self.pid_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertIsNotNone(process.poll())
                self.assertFalse(spike.process_group_exists(process.pid))
                self.assertFalse(self.pid_exists(child_pid))
                for stream in (process.stdout, process.stderr):
                    self.assertTrue(stream is None or stream.closed)

    def test_process_constructor_pre_pump_failures_are_transactional(self) -> None:
        for wrapper, injected in (
            (spike.BoundedTextProcess, RuntimeError("post-spawn failure")),
            (spike.BoundedTextProcess, KeyboardInterrupt()),
            (spike.JSONLProcess, RuntimeError("post-spawn failure")),
            (spike.JSONLProcess, KeyboardInterrupt()),
        ):
            with self.subTest(wrapper=wrapper.__name__, error=type(injected).__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                child_pid_file = root / "child-pid"
                executable = self.make_executable(
                    root,
                    "pre-pump-child.py",
                    f"""
                    import signal
                    import subprocess
                    from pathlib import Path
                    child = subprocess.Popen(["sleep", "30"])
                    Path({str(child_pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    signal.pause()
                    """,
                )
                original_popen = subprocess.Popen
                original_rollback = spike.rollback_process_construction
                captured: list[subprocess.Popen[Any]] = []

                def capture_popen(*args: Any, **kwargs: Any) -> subprocess.Popen[Any]:
                    process = original_popen(*args, **kwargs)
                    captured.append(process)
                    return process

                def fail_thread_construction(*_args: Any, **_kwargs: Any) -> None:
                    deadline = time.monotonic() + 2
                    while not child_pid_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(child_pid_file.exists())
                    raise injected

                def rollback_with_recorded_cleanup(*args: Any, **kwargs: Any) -> spike.ProbeError:
                    cleanup = original_rollback(*args, **kwargs)
                    self.assertIsNone(cleanup)
                    return spike.ProbeError("recorded rollback detail")

                kwargs: dict[str, Any] = {"termination_grace_seconds": 0.2}
                if wrapper is spike.JSONLProcess:
                    kwargs["cwd"] = root
                with (
                    mock.patch.object(spike.subprocess, "Popen", side_effect=capture_popen),
                    mock.patch.object(spike.threading, "Thread", side_effect=fail_thread_construction),
                    mock.patch.object(spike, "rollback_process_construction", side_effect=rollback_with_recorded_cleanup) as rollback,
                    self.assertRaises(type(injected)) as context,
                ):
                    wrapper([str(executable)], **kwargs)
                rollback.assert_called_once()
                self.assertTrue(any("recorded rollback detail" in note for note in getattr(context.exception, "__notes__", [])))
                process = captured[0]
                child_pid = int(child_pid_file.read_text(encoding="utf-8"))
                deadline = time.monotonic() + 2
                while self.pid_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(spike.process_group_exists(process.pid))
                self.assertFalse(self.pid_exists(child_pid))
                for stream in (process.stdin, process.stdout, process.stderr):
                    self.assertTrue(stream is None or stream.closed)

        for wrapper, injected in (
            (spike.BoundedTextProcess, FileNotFoundError("popen failed")),
            (spike.JSONLProcess, KeyboardInterrupt()),
        ):
            kwargs = {"cwd": Path("/")} if wrapper is spike.JSONLProcess else {}
            with (
                self.subTest(wrapper=wrapper.__name__, branch="popen"),
                mock.patch.object(spike.subprocess, "Popen", side_effect=injected),
                mock.patch.object(spike, "rollback_process_construction") as rollback,
                self.assertRaises(type(injected)),
            ):
                wrapper(["missing"], **kwargs)
            rollback.assert_not_called()

    def test_private_marker_partial_write_cleanup_owned_and_caller_workspace(self) -> None:
        class PartialFailStream:
            def __init__(self, stream: Any) -> None:
                self.stream = stream
            @property
            def closed(self) -> bool:
                return self.stream.closed
            def write(self, content: str) -> int:
                self.stream.write(content[:1])
                self.stream.flush()
                raise OSError(28, "no space")
            def flush(self) -> None:
                self.stream.flush()
            def close(self) -> None:
                self.stream.close()

        for owned in (True, False):
            with self.subTest(owned=owned), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                unrelated = workspace / "unrelated"
                if not owned:
                    unrelated.write_text("keep", encoding="utf-8")
                args = Namespace(
                    phase="preflight", omp="fake", app_bundle=root / "Fake.app",
                    workspace=None if owned else workspace,
                    unsafe_allow_nonempty_workspace=not owned,
                    output_dir=None, prompt_timeout=1,
                )
                real_fdopen = os.fdopen
                with (
                    mock.patch.object(spike, "parse_args", return_value=args),
                    mock.patch.object(spike, "prepare_output_directory", return_value=output),
                    mock.patch.object(spike, "prepare_workspace", return_value=(workspace, owned)),
                    mock.patch.object(spike.os, "fdopen", side_effect=lambda *a, **k: PartialFailStream(real_fdopen(*a, **k))),
                ):
                    self.assertEqual(spike.main(), 2)
                self.assertFalse((workspace / ".omp-live-spike-readonly-marker").exists())
                if owned:
                    self.assertFalse(workspace.exists())
                else:
                    self.assertTrue(workspace.exists())
                    self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep")

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "private"
            real_fdopen = os.fdopen
            with (
                mock.patch.object(spike.os, "fdopen", side_effect=lambda *a, **k: PartialFailStream(real_fdopen(*a, **k))),
                mock.patch.object(spike, "_unlink_exclusively_created_file", side_effect=OSError("unlink failed")),
                self.assertRaisesRegex(OSError, "no space") as context,
            ):
                spike.write_private_text(path, "content")
            self.assertTrue(path.exists())
            self.assertTrue(any("unlink failed" in note for note in getattr(context.exception, "__notes__", [])))

    def test_private_marker_initial_fstat_failures_recover_safely(self) -> None:
        for owned, injected in (
            (True, KeyboardInterrupt()),
            (True, OSError(5, "fstat failed")),
            (False, KeyboardInterrupt()),
            (False, OSError(5, "fstat failed")),
        ):
            with self.subTest(owned=owned, error=type(injected).__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                unrelated = workspace / "unrelated"
                if not owned:
                    unrelated.write_text("keep", encoding="utf-8")
                args = Namespace(
                    phase="preflight", omp="fake", app_bundle=root / "Fake.app",
                    workspace=None if owned else workspace,
                    unsafe_allow_nonempty_workspace=not owned,
                    output_dir=None, prompt_timeout=1,
                )
                real_fstat = os.fstat
                calls = 0
                def fail_once(descriptor: int) -> os.stat_result:
                    nonlocal calls
                    calls += 1
                    if calls == 1:
                        raise injected
                    return real_fstat(descriptor)
                with (
                    mock.patch.object(spike, "parse_args", return_value=args),
                    mock.patch.object(spike, "prepare_output_directory", return_value=output),
                    mock.patch.object(spike, "prepare_workspace", return_value=(workspace, owned)),
                    mock.patch.object(spike.os, "fstat", side_effect=fail_once),
                ):
                    self.assertEqual(spike.main(), 2)
                self.assertGreaterEqual(calls, 2)
                self.assertFalse((workspace / ".omp-live-spike-readonly-marker").exists())
                if owned:
                    self.assertFalse(workspace.exists())
                else:
                    self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "private"
            real_fstat = os.fstat
            real_open = os.open
            opened_descriptor: int | None = None
            calls = 0
            def capture_open(*args: Any, **kwargs: Any) -> int:
                nonlocal opened_descriptor
                descriptor = real_open(*args, **kwargs)
                if opened_descriptor is None:
                    opened_descriptor = descriptor
                return descriptor
            def fail_twice(descriptor: int) -> os.stat_result:
                nonlocal calls
                calls += 1
                if calls <= 2:
                    raise OSError(5, f"fstat failure {calls}")
                return real_fstat(descriptor)
            with (
                mock.patch.object(spike.os, "open", side_effect=capture_open),
                mock.patch.object(spike.os, "fstat", side_effect=fail_twice),
                mock.patch.object(spike, "_unlink_exclusively_created_file") as unlink,
                self.assertRaisesRegex(OSError, "fstat failure 1") as context,
            ):
                spike.write_private_text(path, "content")
            unlink.assert_not_called()
            self.assertTrue(path.exists())
            self.assertTrue(any("fstat failure 2" in note for note in getattr(context.exception, "__notes__", [])))
            assert opened_descriptor is not None
            with self.assertRaises(OSError):
                real_fstat(opened_descriptor)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "private"
            original = root / "original"
            replacement = b"replacement"
            real_fstat = os.fstat
            real_open = os.open
            opened_descriptor: int | None = None
            calls = 0
            def capture_replacement_open(*args: Any, **kwargs: Any) -> int:
                nonlocal opened_descriptor
                descriptor = real_open(*args, **kwargs)
                if opened_descriptor is None:
                    opened_descriptor = descriptor
                return descriptor
            def replace_then_fail(descriptor: int) -> os.stat_result:
                nonlocal calls
                calls += 1
                if calls == 1:
                    path.rename(original)
                    path.write_bytes(replacement)
                    raise KeyboardInterrupt()
                return real_fstat(descriptor)
            with (
                mock.patch.object(spike.os, "open", side_effect=capture_replacement_open),
                mock.patch.object(spike.os, "fstat", side_effect=replace_then_fail),
                self.assertRaises(KeyboardInterrupt) as context,
            ):
                spike.write_private_text(path, "content")
            self.assertEqual(path.read_bytes(), replacement)
            self.assertTrue(any("refusing to unlink replaced" in note for note in getattr(context.exception, "__notes__", [])))
            assert opened_descriptor is not None
            with self.assertRaises(OSError):
                real_fstat(opened_descriptor)

    def test_regular_file_to_fifo_swap_is_nonblocking_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "file"
            target.write_text("safe", encoding="utf-8")
            original_open = spike._open_regular_fd
            swapped = False

            def swap_to_fifo(name: Any, *, dir_fd: int) -> int:
                nonlocal swapped
                if name == "file" and not swapped:
                    swapped = True
                    target.unlink()
                    os.mkfifo(target)
                return original_open(name, dir_fd=dir_fd)

            started = time.monotonic()
            with (
                mock.patch.object(spike, "_open_regular_fd", side_effect=swap_to_fifo),
                self.assertRaisesRegex(spike.ProbeError, "changed before open"),
            ):
                spike.snapshot_workspace(root, deadline_seconds=1)
            self.assertLess(time.monotonic() - started, 1)

    def test_primary_probe_failure_survives_partial_summary_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "primary-and-summary-failure.py",
                """
                import json
                import signal
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId":"s"}
                    elif method == "session/prompt":
                        print(json.dumps({"jsonrpc":"2.0","id":700,"method":"fs/read_text_file","params":{"sessionId":"s"}}), flush=True)
                        signal.pause()
                    else: result = {}
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            with (
                mock.patch.object(spike, "bounded_workspace_names", side_effect=OSError("names unavailable")),
                self.assertRaisesRegex(spike.ProbeError, "unsupported inbound ACP request") as context,
            ):
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
            partial = context.exception.details["ompACPPartial"]
            self.assertEqual(partial["partialSummaryUnavailable"]["message"], "names unavailable")
            self.assertEqual(partial["unexpectedInboundRequests"]["count"], 1)
            self.assertTrue((output / "omp-acp.stdout.jsonl").exists())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "main-primary-and-summary-failure.py",
                """
                import json
                import signal
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId":"s"}
                    elif method == "session/prompt":
                        print(json.dumps({"jsonrpc":"2.0","id":701,"method":"fs/read_text_file","params":{"sessionId":"s"}}), flush=True)
                        signal.pause()
                    else: result = {}
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            args = Namespace(
                phase="prompt", omp=str(fake), app_bundle=root / "Fake.app",
                workspace=workspace, unsafe_allow_nonempty_workspace=False,
                output_dir=root, prompt_timeout=1,
            )
            help_text = "--no-tools --no-extensions --no-skills --no-rules --approval-mode"
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, False)),
                mock.patch.object(spike, "find_executable", return_value=fake),
                mock.patch.object(spike, "run_text", side_effect=["1.0", help_text, "Run Oh My Pi as an ACP"]),
                mock.patch.object(spike, "helper_preflight", return_value={}),
                mock.patch.object(spike, "bounded_workspace_names", side_effect=OSError("names unavailable")),
            ):
                self.assertEqual(spike.main(), 1)
            safe_summary = json.loads((output / "safe-summary.json").read_text(encoding="utf-8"))
            self.assertFalse(safe_summary["success"])
            self.assertIn("unsupported inbound ACP request", safe_summary["error"])
            self.assertIn("partialSummaryUnavailable", json.dumps(safe_summary["failureDetails"]))

    def test_primary_probe_failure_survives_partial_summary_keyboard_interrupt(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            fake = self.make_executable(
                root,
                "primary-and-summary-interrupt.py",
                """
                import json
                import signal
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    request_id = message.get("id")
                    method = message.get("method")
                    if method == "initialize": result = {"authMethods": [], "agentCapabilities": {}}
                    elif method == "session/new": result = {"sessionId":"s"}
                    elif method == "session/prompt":
                        print(json.dumps({"jsonrpc":"2.0","id":702,"method":"fs/read_text_file","params":{"sessionId":"s"}}), flush=True)
                        signal.pause()
                    else: result = {}
                    print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
                """,
            )
            with (
                mock.patch.object(spike, "bounded_workspace_names", side_effect=KeyboardInterrupt()),
                self.assertRaisesRegex(spike.ProbeError, "unsupported inbound ACP request") as context,
            ):
                spike.acp_probe(fake, root / "helper", workspace, output, "prompt", 1)
            partial = context.exception.details["ompACPPartial"]
            self.assertEqual(partial["partialSummaryUnavailable"]["type"], "KeyboardInterrupt")
            self.assertEqual(partial["unexpectedInboundRequests"]["count"], 1)
            self.assertTrue((output / "omp-acp.stdout.jsonl").exists())

    def test_helper_preflight_rejects_every_invalid_trailing_frame(self) -> None:
        cases = {
            "malformed": ("{HOSTILE_MALFORMED", "invalid JSON-RPC stdout"),
            "invalid-envelope": (json.dumps({"jsonrpc":"2.0","id":3,"result":{},"extra":True}), "invalid JSON-RPC response envelope"),
            "duplicate": (json.dumps({"jsonrpc":"2.0","id":2,"result":{"tools":[]}}), "duplicate JSON-RPC response id 2"),
            "unsolicited": (json.dumps({"jsonrpc":"2.0","id":99,"result":{}}), "unsolicited JSON-RPC response id 99"),
        }
        for label, (tail, expected) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                workspace.mkdir()
                output.mkdir()
                helper = self.make_executable(
                    root,
                    "tail-helper.py",
                    f"""
                    import json
                    import os
                    import sys
                    tail = {tail!r}
                    for line in sys.stdin:
                        message = json.loads(line)
                        method = message.get("method")
                        if method == "initialize":
                            result = {{"serverInfo": {{}}, "capabilities": {{}}}}
                        elif method == "tools/list":
                            response = {{"jsonrpc":"2.0","id":message["id"],"result":{{"tools":[]}}}}
                            os.write(1, (json.dumps(response) + "\\n" + tail + "\\n").encode())
                            break
                        else:
                            continue
                        print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                    """,
                )
                with self.assertRaisesRegex(spike.ProbeError, expected):
                    spike.helper_preflight(helper, workspace, output)
                evidence = (output / "repoprompt-mcp.stdout.jsonl").read_text(encoding="utf-8")
                self.assertIn(tail, evidence)

    def test_helper_preflight_rejects_inbound_requests_and_tolerates_notifications(self) -> None:
        for target in ("initialize", "tools/list"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                output = root / "evidence"
                capture = root / "stdin.jsonl"
                child_pid_file = root / "child-pid"
                workspace.mkdir()
                output.mkdir()
                helper = self.make_executable(
                    root,
                    "requesting-helper.py",
                    f"""
                    import json
                    import signal
                    import subprocess
                    import sys
                    from pathlib import Path
                    capture = Path({str(capture)!r})
                    child = subprocess.Popen(["sleep", "30"])
                    Path({str(child_pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    for line in sys.stdin:
                        with capture.open("a", encoding="utf-8") as stream:
                            stream.write(line)
                        message = json.loads(line)
                        method = message.get("method")
                        if method == {target!r}:
                            request = {{"jsonrpc":"2.0","id":9,"method":"roots/list","params":{{}}}}
                            print(json.dumps(request), flush=True)
                            if method == "initialize":
                                result = {{"serverInfo": {{}}, "capabilities": {{}}}}
                            else:
                                result = {{"tools": []}}
                            print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                            signal.pause()
                        elif method == "initialize":
                            result = {{"serverInfo": {{}}, "capabilities": {{}}}}
                            print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                    """,
                )
                started = time.monotonic()
                with self.assertRaisesRegex(spike.ProbeError, "roots/list.*id=9"):
                    spike.helper_preflight(helper, workspace, output)
                self.assertLess(time.monotonic() - started, 8)
                outbound = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
                self.assertFalse(any(message.get("id") == 9 for message in outbound))
                child_pid = int(child_pid_file.read_text(encoding="utf-8"))
                deadline = time.monotonic() + 2
                while self.pid_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(self.pid_exists(child_pid))
                self.assertTrue((output / "repoprompt-mcp.stdout.jsonl").exists())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            helper = self.make_executable(
                root,
                "notifying-helper.py",
                """
                import json
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    method = message.get("method")
                    if method == "initialize": result = {"serverInfo": {}, "capabilities": {}}
                    elif method == "tools/list": result = {"tools": []}
                    else: continue
                    print(json.dumps({"jsonrpc":"2.0","method":"notifications/helper_status","params":{"ok":True}}), flush=True)
                    print(json.dumps({"jsonrpc":"2.0","id":message["id"],"result":result}), flush=True)
                """,
            )
            result = spike.helper_preflight(helper, workspace, output)
            self.assertEqual(result["toolCount"], 0)

    def test_helper_phase_safe_summary_rejects_hostile_tail_without_leaking_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            output = root / "evidence"
            workspace.mkdir()
            output.mkdir()
            hostile = "HOSTILE_RAW_TRANSCRIPT_DO_NOT_COPY"
            helper = self.make_executable(
                root,
                "hostile-tail-helper.py",
                f"""
                import json
                import os
                import sys
                for line in sys.stdin:
                    message = json.loads(line)
                    method = message.get("method")
                    if method == "initialize": result = {{"serverInfo": {{}}, "capabilities": {{}}}}
                    elif method == "tools/list":
                        response = {{"jsonrpc":"2.0","id":message["id"],"result":{{"tools":[]}}}}
                        os.write(1, (json.dumps(response) + "\\n" + json.dumps({hostile!r}) + "\\n").encode())
                        break
                    else: continue
                    print(json.dumps({{"jsonrpc":"2.0","id":message["id"],"result":result}}), flush=True)
                """,
            )
            args = Namespace(
                phase="helper", omp="fake", app_bundle=root / "Fake.app",
                workspace=workspace, unsafe_allow_nonempty_workspace=False,
                output_dir=root, prompt_timeout=1,
            )
            help_text = "--no-tools --no-extensions --no-skills --no-rules --approval-mode"
            with (
                mock.patch.object(spike, "parse_args", return_value=args),
                mock.patch.object(spike, "prepare_output_directory", return_value=output),
                mock.patch.object(spike, "prepare_workspace", return_value=(workspace, False)),
                mock.patch.object(spike, "find_executable", side_effect=[Path("/bin/echo"), helper]),
                mock.patch.object(spike, "run_text", side_effect=["1.0", help_text, "Run Oh My Pi as an ACP"]),
            ):
                self.assertEqual(spike.main(), 1)
            summary_text = (output / "safe-summary.json").read_text(encoding="utf-8")
            summary = json.loads(summary_text)
            self.assertFalse(summary["success"])
            self.assertNotIn(hostile, summary_text)
            self.assertNotIn("helperMCP", summary)
            self.assertIn("invalid JSON-RPC 2.0 envelope", summary["error"])
            self.assertIn(hostile, (output / "repoprompt-mcp.stdout.jsonl").read_text(encoding="utf-8"))

    def test_tail_invalid_line_flood_bounds_causes_and_preserves_raw_evidence(self) -> None:
        frame_count = 5_000
        lines = [f"not-json-{index}" for index in range(frame_count)]
        expected_evidence = ("\n".join(lines) + "\n").encode("utf-8")
        expected_omitted = frame_count - (spike.TAIL_CAUSE_LIMIT - 1)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for pre_latched in (False, True):
                with self.subTest(pre_latched=pre_latched):
                    original_error = spike.ProbeError("pre-latched terminal error") if pre_latched else None
                    process = self.make_retained_jsonl_process(lines, protocol_error=original_error)
                    prefix = root / f"invalid-tail-{pre_latched}"
                    started = time.monotonic()
                    with self.assertRaises(spike.ProbeError) as context:
                        spike.close_and_write_jsonl_evidence(
                            process,
                            prefix,
                            tail_handler=lambda _message: None,
                        )
                    self.assertLess(time.monotonic() - started, 2.0)
                    tail_detail = context.exception.details["causes"][0]
                    self.assertEqual(tail_detail["stage"], "tail drain")
                    causes = tail_detail["details"]["causes"]
                    self.assertEqual(len(causes), spike.TAIL_CAUSE_LIMIT)
                    self.assertIn("invalid JSON-RPC stdout", causes[0]["message"])
                    self.assertEqual(causes[-1]["stage"], "tail adjudication cap")
                    self.assertEqual(
                        causes[-1]["details"]["omittedOrUnadjudicatedRetainedFrameCount"],
                        expected_omitted,
                    )
                    if original_error is None:
                        self.assertIsNotNone(process._protocol_error)
                        self.assertIn("invalid JSON-RPC stdout", str(process._protocol_error))
                    else:
                        self.assertIs(process._protocol_error, original_error)
                    self.assertEqual(
                        prefix.with_suffix(".stdout.jsonl").read_bytes(),
                        expected_evidence,
                    )

    def test_tail_valid_notification_flood_past_message_limit_is_bounded(self) -> None:
        frame_count = 5_000
        message_limit = 8
        lines = [
            spike.json_line(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/tail",
                    "params": {"index": index},
                }
            )
            for index in range(frame_count)
        ]
        expected_evidence = ("\n".join(lines) + "\n").encode("utf-8")
        expected_omitted = frame_count - message_limit - (spike.TAIL_CAUSE_LIMIT - 1)

        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "valid-tail"
            process = self.make_retained_jsonl_process(lines, message_limit=message_limit)
            started = time.monotonic()
            with self.assertRaises(spike.ProbeError) as context:
                spike.close_and_write_jsonl_evidence(
                    process,
                    prefix,
                    tail_handler=lambda _message: None,
                )
            self.assertLess(time.monotonic() - started, 2.0)
            tail_detail = context.exception.details["causes"][0]
            self.assertEqual(tail_detail["stage"], "tail drain")
            causes = tail_detail["details"]["causes"]
            self.assertEqual(len(causes), spike.TAIL_CAUSE_LIMIT)
            self.assertEqual(
                causes[0]["message"],
                f"parsed message count exceeded {message_limit}",
            )
            self.assertEqual(causes[-1]["stage"], "tail adjudication cap")
            self.assertEqual(
                causes[-1]["details"]["omittedOrUnadjudicatedRetainedFrameCount"],
                expected_omitted,
            )
            self.assertEqual(
                prefix.with_suffix(".stdout.jsonl").read_bytes(),
                expected_evidence,
            )

    def test_jsonl_cleanup_preserves_close_tail_and_evidence_failures(self) -> None:
        process = mock.Mock()
        process._protocol_error = None
        process._processed_lines = 0
        process.stdout_lines = [{}]
        process.close.side_effect = KeyboardInterrupt()
        process.drain.side_effect = RuntimeError("tail failed")
        process.write_evidence.side_effect = OSError("evidence failed")
        with self.assertRaises(spike.ProbeError) as context:
            spike.close_and_write_jsonl_evidence(process, Path("/tmp/evidence"), tail_handler=lambda _message: None)
        causes = context.exception.details["causes"]
        self.assertEqual([cause["stage"] for cause in causes], ["process close", "tail drain", "evidence write"])
        self.assertIn("KeyboardInterrupt", causes[0]["message"])
        self.assertIn("tail failed", causes[1]["message"])
        self.assertEqual(causes[2]["message"], "evidence failed")
        process.drain.assert_called_once()
        process.write_evidence.assert_called_once()


if __name__ == "__main__":
    unittest.main()
