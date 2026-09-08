#!/usr/bin/env python3
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
HELPER_PATH = ROOT / "Scripts" / "claude_branch_fork_spike.py"
FAKE_PATH = ROOT / "Scripts" / "Fixtures" / "fake_claude_branch_fork.py"
SPEC = importlib.util.spec_from_file_location("claude_branch_fork_spike", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
spike = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = spike
SPEC.loader.exec_module(spike)


class ClaudeBranchForkSpikeTests(unittest.TestCase):
    def make_executable(self, root: Path, source: str) -> Path:
        path = root / "child.py"
        path.write_text("#!/usr/bin/python3\n" + source, encoding="utf-8")
        path.chmod(0o755)
        return path

    def environment(self, root: Path) -> dict[str, str]:
        home = root / "home"
        config = root / "config"
        cwd = root / "cwd"
        for path in (home, config, cwd):
            path.mkdir()
        return spike.safe_environment(home, config)

    def test_redactor_covers_headers_json_credentials_and_temporary_paths(self) -> None:
        raw = """Authorization: Bearer complete-secret
{"api_key":"quoted-secret","password": "quoted-password"}
/private/var/folders/aa/private /var/folders/bb/private /private/tmp/private /tmp/private
"""
        redacted = spike.redact(raw)
        for secret in ("complete-secret", "quoted-secret", "quoted-password", "/private/var/folders", "/var/folders", "/private/tmp", "/tmp/private"):
            self.assertNotIn(secret, redacted)
        self.assertIn("<redacted>", redacted)
        self.assertIn("<machine-path>", redacted)

    def test_chain_evidence_rejects_full_untruncated_child(self) -> None:
        cwd = Path("/fixture")
        session = "source"
        first = spike.fixture_entry(session, cwd, "a", None, "user", "one")
        second = spike.fixture_entry(session, cwd, "b", "a", "assistant", "two")
        extra = spike.fixture_entry("child", cwd, "c", "b", "user", "extra")
        source = spike.parse_jsonl_bytes_with_integrity(
            b"".join(json.dumps(entry).encode() + b"\n" for entry in (first, second, extra))
        )
        evidence = spike.chain_evidence(source, source, "b")
        self.assertFalse(evidence["structural_equality_ignoring_uuid"])
        self.assertFalse(evidence["exact_entry_count"])
        self.assertFalse(evidence["no_extra_main_chain_entries"])

    def test_chain_evidence_rejects_malformed_incomplete_tail(self) -> None:
        cwd = Path("/fixture")
        entries = [
            spike.fixture_entry("source", cwd, "a", None, "user", "one"),
            spike.fixture_entry("source", cwd, "b", "a", "assistant", "two"),
            spike.fixture_entry("source", cwd, "c", "b", "user", "three"),
            spike.fixture_entry("source", cwd, "d", "c", "assistant", "four"),
        ]
        valid_bytes = b"".join(json.dumps(entry).encode() + b"\n" for entry in entries)
        source = spike.parse_jsonl_bytes_with_integrity(valid_bytes)
        child = spike.parse_jsonl_bytes_with_integrity(valid_bytes + b'{"truncated":')
        evidence = spike.chain_evidence(source, child, "d")
        self.assertTrue(evidence["exact_entry_count"])
        self.assertFalse(evidence["child_parse_integrity"]["complete_tail"])
        self.assertEqual(evidence["child_parse_integrity"]["malformed_line_count"], 1)
        self.assertFalse(evidence["structural_equality_ignoring_uuid"])

    def test_chain_evidence_rejects_dangling_root_parent(self) -> None:
        cwd = Path("/fixture")
        source_entries = [
            spike.fixture_entry("source", cwd, "a", None, "user", "one"),
            spike.fixture_entry("source", cwd, "b", "a", "assistant", "two"),
        ]
        child_entries = [dict(entry) for entry in source_entries]
        child_entries[0]["parentUuid"] = "unknown-parent"
        source = spike.parse_jsonl_bytes_with_integrity(
            b"".join(json.dumps(entry).encode() + b"\n" for entry in source_entries)
        )
        child = spike.parse_jsonl_bytes_with_integrity(
            b"".join(json.dumps(entry).encode() + b"\n" for entry in child_entries)
        )
        evidence = spike.chain_evidence(source, child, "b")
        self.assertFalse(evidence["child_parent_references_valid"])
        self.assertFalse(evidence["parent_linkage_equal"])
        self.assertFalse(evidence["structural_equality_ignoring_uuid"])

    def test_child_discovery_traversal_error_keeps_s9_s10_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            config = root / "config"
            cwd = root / "cwd"
            config.mkdir()
            cwd.mkdir()

            def failing_walk(_root, *, topdown, onerror, followlinks):
                self.assertTrue(topdown)
                self.assertFalse(followlinks)
                onerror(PermissionError("unreadable subtree"))
                return iter(())

            with mock.patch.object(spike.os, "walk", side_effect=failing_walk):
                child, evidence = spike.discover_child_store(
                    config, cwd, "child", config / "child.jsonl"
                )

            self.assertIsNone(child)
            self.assertEqual(evidence["classification"], "incomplete-scan")
            self.assertFalse(evidence["scan_complete"])
            self.assertFalse(evidence["physical_absence_established"])
            self.assertEqual(evidence["traversal_error_count"], 1)
            self.assertEqual(evidence["enumerated_candidate_count"], 0)
            self.assertIsNone(spike.child_candidate_presence(evidence))
            self.assertIsNone(spike.child_candidate_bytes(evidence))
            self.assertEqual(
                spike.missing_session_status(True, False, evidence), "inconclusive"
            )

    def test_child_discovery_metadata_error_preserves_enumerated_presence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            config = root / "config"
            cwd = root / "cwd"
            config.mkdir()
            cwd.mkdir()
            candidate = config / "child.jsonl"
            candidate.write_bytes(b'{"cwd":')

            with mock.patch.object(
                spike, "_child_candidate_metadata", side_effect=OSError("metadata failed")
            ):
                child, evidence = spike.discover_child_store(
                    config, cwd, "child", candidate
                )

            self.assertIsNone(child)
            self.assertEqual(evidence["classification"], "incomplete-scan")
            self.assertFalse(evidence["scan_complete"])
            self.assertFalse(evidence["physical_absence_established"])
            self.assertEqual(evidence["enumerated_candidate_count"], 1)
            self.assertEqual(evidence["exact_name_candidate_count"], 1)
            self.assertEqual(evidence["unresolved_metadata_count"], 1)
            self.assertEqual(evidence["exact_name_candidate_byte_sizes"], [])
            self.assertTrue(spike.child_candidate_presence(evidence))
            self.assertIsNone(spike.child_candidate_bytes(evidence))
            self.assertEqual(
                spike.missing_session_status(True, False, evidence), "inconclusive"
            )

    def test_timeout_closes_stdin_before_escalation_and_frames_large_line(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            marker = root / "eof"
            child = self.make_executable(root, f"""
import json
import sys
from pathlib import Path
sys.stdin.buffer.read()
Path({str(marker)!r}).write_text("eof")
print(json.dumps({{"type":"system","subtype":"init","session_id":"child","padding":"x" * 70000}}), flush=True)
""")
            environment = self.environment(root)
            started = time.monotonic()
            observation = spike.run_owned(
                child, [], environment, root / "cwd",
                stdin_lines=(b"input\n",), requested_session_id="child", timeout=0.75,
            )
            self.assertLess(time.monotonic() - started, 3.0)
            self.assertEqual(observation.status, 0)
            self.assertTrue(marker.exists())
            self.assertTrue(observation.timed_out)
            self.assertTrue(observation.requested_id_system_init_match)
            self.assertLessEqual(len(observation.output), spike.OUTPUT_LIMIT)

    def test_early_exit_preserves_partial_output_and_write_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            child = self.make_executable(root, """
import sys
print("partial-evidence", flush=True)
raise SystemExit(7)
""")
            observation = spike.run_owned(
                child, [], self.environment(root), root / "cwd",
                stdin_lines=(b"x" * (8 * 1024 * 1024),), timeout=1.0,
            )
            self.assertEqual(observation.status, 7)
            self.assertIn(b"partial-evidence", observation.output)
            self.assertIn(observation.stdin_write_error, (None, "BrokenPipeError", "OSError"))

    def test_cancellation_forwards_signal_and_reaps_leader(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            marker = root / "term"
            ready = root / "ready"
            child = self.make_executable(root, f"""
import signal
import time
from pathlib import Path
def stop(_signum, _frame):
    Path({str(marker)!r}).write_text("term")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
Path({str(ready)!r}).write_text("ready")
while True:
    time.sleep(0.05)
""")
            def send_when_ready() -> None:
                deadline = time.monotonic() + 2.0
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                os.kill(os.getpid(), signal.SIGTERM)

            sender = threading.Thread(target=send_when_ready, daemon=True)
            sender.start()
            with self.assertRaises(InterruptedError):
                spike.run_owned(child, [], self.environment(root), root / "cwd", timeout=3.0)
            sender.join(timeout=1.0)
            self.assertTrue(marker.exists())

    def test_cancellation_during_cleanup_kills_term_ignoring_child_and_restores_handler(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            term_marker = root / "cleanup-term"
            pid_path = root / "pid"
            child = self.make_executable(root, f"""
import os
import signal
import time
from pathlib import Path
def ignore_term(_signum, _frame):
    Path({str(term_marker)!r}).write_text("term")
signal.signal(signal.SIGTERM, ignore_term)
Path({str(pid_path)!r}).write_text(str(os.getpid()))
while True:
    time.sleep(0.05)
""")
            def cancel_during_cleanup() -> None:
                deadline = time.monotonic() + 2.0
                while not term_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if term_marker.exists():
                    os.kill(os.getpid(), signal.SIGTERM)

            old_handler = signal.getsignal(signal.SIGTERM)
            sender = threading.Thread(target=cancel_during_cleanup, daemon=True)
            sender.start()
            started = time.monotonic()
            with self.assertRaises(InterruptedError):
                spike.run_owned(
                    child, [], self.environment(root), root / "cwd", timeout=1.0,
                )
            sender.join(timeout=1.0)
            self.assertLess(time.monotonic() - started, 4.0)
            self.assertTrue(term_marker.exists())
            self.assertIs(signal.getsignal(signal.SIGTERM), old_handler)
            child_pid = int(pid_path.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_surviving_descendant_receives_group_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            marker = root / "descendant-term"
            child = self.make_executable(root, f"""
import os
import signal
import time
from pathlib import Path
pid = os.fork()
if pid == 0:
    def stop(_signum, _frame):
        Path({str(marker)!r}).write_text("term")
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    while True:
        time.sleep(0.05)
print(pid, flush=True)
""")
            observation = spike.run_owned(
                child, [], self.environment(root), root / "cwd", timeout=2.0,
            )
            self.assertEqual(observation.status, 0)
            self.assertTrue(marker.exists())

    def run_diagnostic(self, executable: Path, report: Path) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["RPCE_CLAUDE_BRANCH_SPIKE"] = "1"
        environment["RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE"] = str(executable)
        return subprocess.run(
            [sys.executable, str(HELPER_PATH), "--report", str(report)],
            cwd=ROOT, env=environment, text=True, capture_output=True, timeout=15,
        )

    def test_fake_claude_covers_s0_through_s11_report_shape_and_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            report = Path(raw) / "report.md"
            started = time.monotonic()
            result = self.run_diagnostic(FAKE_PATH, report)
            elapsed = time.monotonic() - started
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertLess(elapsed, 10.0)
            markdown = report.read_text(encoding="utf-8")
            self.assertLess(len(markdown.encode()), spike.OUTPUT_LIMIT)
            self.assertIn("Blocking result (S0 + S2(a)): **PASS**", markdown)
            self.assertIn('"exact_entry_count": true', markdown)
            self.assertIn('"parent_linkage_equal": true', markdown)
            self.assertIn('"classification": "found-expected"', markdown)
            self.assertIn("### S9 — supported", markdown)
            for index in range(12):
                self.assertIn(f"### S{index} —", markdown)

    def test_s0_block_keeps_s5_s6_and_s8_inconclusive(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            wrapper = root / "fake-wrapper"
            wrapper.write_text(
                "#!/bin/sh\nexport FAKE_CLAUDE_NO_FORK_CHILD=1\n"
                f"exec {sys.executable!r} {str(FAKE_PATH)!r} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            report = root / "report.md"
            result = self.run_diagnostic(wrapper, report)
            self.assertEqual(result.returncode, 1)
            markdown = report.read_text(encoding="utf-8")
            self.assertIn("### S0 — unsupported", markdown)
            for scenario in ("S5", "S6", "S8"):
                self.assertIn(f"### {scenario} — inconclusive", markdown)

    def test_fake_claude_strictly_rejects_extra_untruncated_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            wrapper = root / "fake-wrapper"
            wrapper.write_text(
                "#!/bin/sh\nexport FAKE_CLAUDE_APPEND_EXTRA=1\n"
                f"exec {sys.executable!r} {str(FAKE_PATH)!r} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            report = root / "report.md"
            result = self.run_diagnostic(wrapper, report)
            self.assertEqual(result.returncode, 0)
            markdown = report.read_text(encoding="utf-8")
            s2 = markdown.split("### S2 —", 1)[1].split("### S3 —", 1)[0]
            self.assertIn("unsupported", s2)
            self.assertIn('"no_extra_main_chain_entries": false', s2)

    def test_fake_claude_discovers_child_written_outside_expected_directory(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            wrapper = root / "fake-wrapper"
            wrapper.write_text(
                "#!/bin/sh\n"
                "export FAKE_CLAUDE_CHILD_ELSEWHERE=1\n"
                "export FAKE_CLAUDE_MISSING_CHILD_CWD_MISMATCH=1\n"
                "export FAKE_CLAUDE_PARTIAL_CHILD_BEFORE_CONTROL=1\n"
                f"exec {sys.executable!r} {str(FAKE_PATH)!r} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            report = root / "report.md"
            result = self.run_diagnostic(wrapper, report)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            markdown = report.read_text(encoding="utf-8")
            s2 = markdown.split("### S2 —", 1)[1].split("### S3 —", 1)[0]
            self.assertIn('"classification": "found-elsewhere"', s2)
            self.assertIn('"a_child_durable_before_prompt": true', s2)

            s9 = markdown.split("### S9 —", 1)[1].split("### S10 —", 1)[0]
            self.assertIn("inconclusive", s9)
            self.assertIn('"child_created": true', s9)
            self.assertIn('"classification": "cwd-mismatch"', s9)
            self.assertIn('"exact_name_candidate_count": 1', s9)
            self.assertIn('"cwd_qualified_candidate_count": 0', s9)

            s10 = markdown.split("### S10 —", 1)[1].split("### S11 —", 1)[0]
            self.assertIn('"child_exists_after_kill": true', s10)
            self.assertIn('"child_bytes_after_kill": 7', s10)
            self.assertIn('"classification": "cwd-mismatch"', s10)
            self.assertIn('"exact_name_candidate_byte_sizes": [', s10)
            self.assertIn("      7", s10)

    def test_absolute_executable_failure_report_includes_redacted_cause(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            report = Path(raw) / "report.md"
            environment = dict(os.environ)
            environment["RPCE_CLAUDE_BRANCH_SPIKE"] = "1"
            environment["RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE"] = "relative-claude"
            result = subprocess.run(
                [sys.executable, str(HELPER_PATH), "--report", str(report)],
                cwd=ROOT, env=environment, text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 1)
            markdown = report.read_text(encoding="utf-8")
            self.assertIn("failure_cause", markdown)
            self.assertIn("must be an absolute path", markdown)


if __name__ == "__main__":
    unittest.main()
