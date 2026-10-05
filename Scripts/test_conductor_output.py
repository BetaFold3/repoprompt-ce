#!/usr/bin/env python3
"""Focused tests for conductor concise output summaries."""

from __future__ import annotations

import contextlib
import fcntl
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any, Optional
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


def summarize(operation: str, state: str, exit_code: Optional[int], lines: list[str]) -> dict:
    return conductor.OutputSummarizer.summarize_lines(operation, {}, state, exit_code, False, lines)


def section(summary: dict, title: str) -> list[str]:
    for item in summary.get("sections", []):
        if item.get("title") == title:
            return item.get("lines") or []
    return []


def app_payload(subcommand: str, state: str, exit_code: int, lines: list[str], **extra: object) -> dict:
    payload = {
        "ticket": "ticket",
        "operation": "app",
        "operationLabel": f"app {subcommand}",
        "args": {"subcommand": subcommand},
        "state": state,
        "exitCode": exit_code,
        "timedOut": False,
        "logPath": "/tmp/job.log",
        "outputSummary": conductor.OutputSummarizer.summarize_lines(
            "app", {"subcommand": subcommand}, state, exit_code, False, lines
        ),
    }
    payload.update(extra)
    return payload


def rendered_terminal_output(payload: dict) -> str:
    with contextlib.redirect_stdout(io.StringIO()) as output:
        conductor.print_terminal_job_output(payload)
    return output.getvalue()


class OutputSummarizerTests(unittest.TestCase):
    def test_success_package_summary_omits_raw_build_noise(self) -> None:
        lines = ["==> Building RepoPrompt\n"]
        lines.extend(f"CompileSwift noisy file {index}\n" for index in range(200))
        lines.append("Created: /tmp/RepoPrompt.app\n")

        summary = summarize("build", "completed", 0, lines)

        self.assertIn("Created: /tmp/RepoPrompt.app", section(summary, "Artifacts"))
        rendered = "\n".join(line for item in summary["sections"] for line in item["lines"])
        self.assertNotIn("CompileSwift noisy file", rendered)

    def test_swift_compiler_failure_extracts_file_error_and_context(self) -> None:
        lines = [
            "==> Building\n",
            "previous context one\n",
            "previous context two\n",
            "Sources/Foo.swift:10:5: error: cannot find 'x' in scope\n",
            "let y = x\n",
            "    ^\n",
        ]

        summary = summarize("swift-build", "failed", 1, lines)
        swift_errors = section(summary, "Swift compiler errors")

        self.assertTrue(any("Sources/Foo.swift:10:5: error" in line for line in swift_errors))
        self.assertIn("previous context two", swift_errors)
        self.assertIn("let y = x", swift_errors)

    def test_xctest_failure_extracts_failing_test(self) -> None:
        summary = summarize(
            "test",
            "failed",
            1,
            [
                "Test Case 'RepoPromptTests.FooTests.testBar' failed (0.1 seconds)\n",
                "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds\n",
            ],
        )

        test_failures = section(summary, "Test failures")
        self.assertTrue(any("FooTests.testBar" in line for line in test_failures))
        self.assertTrue(any("Executed 1 test" in line for line in test_failures))

    def test_xctest_active_deadline_summary_preserves_budget_diagnostic(self) -> None:
        deadline = (
            "XCTest ACTIVE-METHOD deadline triggered; "
            "active test method=-[RepoPromptTests.FooTests testBar]; "
            "budget=90.000s; budget source=ledger-derived; previous=<none>"
        )

        summary = summarize("test", "failed", 70, [deadline + "\n"])

        self.assertIn(deadline, section(summary, "Timeout or cancellation"))

    def test_completion_header_includes_global_heavy_slot_wait(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "test",
            "args": {},
            "state": "completed",
            "exitCode": 0,
            "logPath": "/tmp/job.log",
            "globalHeavySlotWaitSeconds": 2.5,
            "outputSummary": {"headline": "completed successfully", "sections": []},
        }

        rendered = rendered_terminal_output(payload)

        self.assertIn("global-wait=2.5s", rendered)

    def test_stale_artifact_pass_wording_only_renders_for_completed_exit_zero(self) -> None:
        base = {
            "ticket": "ticket",
            "operation": "test-artifact",
            "args": {"filter": "AlphaTests"},
            "logPath": "/tmp/job.log",
            "artifactScope": "stale",
            "artifactScopeDifferences": ["dirty digest"],
            "artifactScopeMessage": (
                "artifact_scope: stale — current source was NOT validated; differs: dirty digest"
            ),
            "outputSummary": {"headline": "test result", "sections": []},
        }

        completed = rendered_terminal_output({**base, "state": "completed", "exitCode": 0})
        failed = rendered_terminal_output({**base, "state": "failed", "exitCode": 1})
        canceled = rendered_terminal_output({**base, "state": "canceled", "exitCode": 130})

        self.assertIn("artifact passed", completed)
        self.assertNotIn("artifact passed", failed)
        self.assertNotIn("artifact passed", canceled)
        self.assertIn("current source was NOT validated", failed)
        self.assertIn("current source was NOT validated", canceled)

    def test_style_findings_extract_swiftlint_lines(self) -> None:
        summary = summarize(
            "lint",
            "failed",
            1,
            [
                "Running SwiftLint\n",
                "Sources/Foo.swift:12:3: warning: Todo Violation: TODOs should be resolved\n",
                "ERROR: Missing required Swift style tools\n",
            ],
        )

        findings = section(summary, "Style findings")
        self.assertTrue(any("SwiftLint" in line for line in findings))
        self.assertTrue(any("Sources/Foo.swift:12:3: warning" in line for line in findings))

    def test_timeout_lines_are_prioritized(self) -> None:
        summary = summarize(
            "test",
            "failed",
            124,
            ["timed out after 300.0s\n", "terminating process group: timed out after 300.0s\n"],
        )

        timeout_lines = section(summary, "Timeout or cancellation")
        self.assertTrue(any("timed out after 300.0s" in line for line in timeout_lines))
        self.assertTrue(any("terminating process group" in line for line in timeout_lines))

    def test_progress_line_selection_filters_noise_and_caps_output(self) -> None:
        lines = ["CompileSwift noisy file\n", "==> Build\n"]
        lines.extend(f"Created: /tmp/artifact-{index}\n" for index in range(20))
        lines.append("plain final noise\n")

        selected = conductor.select_progress_lines("build", lines)

        self.assertLessEqual(len(selected), conductor.PROGRESS_MAX_LINES_PER_POLL)
        self.assertIn("==> Build", selected)
        self.assertTrue(any("Created: /tmp/artifact-" in line for line in selected))
        self.assertFalse(any("CompileSwift noisy file" in line for line in selected))
        self.assertFalse(any("plain final noise" in line for line in selected))

    def test_app_lifecycle_summary_and_progress_prioritize_confirmed_transition(self) -> None:
        lines = [
            "==> Stopping existing RepoPrompt CE debug app instance\n",
            "==> Waiting for existing RepoPrompt CE debug app process to exit\n",
            "RepoPrompt CE debug app stop confirmed.\n",
            "==> Launching /tmp/RepoPrompt.app\n",
            "==> Confirming launched RepoPrompt CE debug app process\n",
            "Observed launched RepoPrompt CE debug PID(s): 123\n",
        ]

        summary = summarize("run", "completed", 0, lines)
        lifecycle = section(summary, "App lifecycle")
        titles = [item["title"] for item in summary["sections"]]
        progress = conductor.select_progress_lines(
            "run",
            ["RepoPrompt CE debug app stop confirmed.\n", "Observed launched RepoPrompt CE debug PID(s): 123\n"],
        )

        self.assertIn("RepoPrompt CE debug app stop confirmed.", lifecycle)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", lifecycle)
        self.assertTrue(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["launchRequested"])
        self.assertTrue(summary["launchLifecycle"]["launchConfirmed"])
        self.assertLess(titles.index("App lifecycle"), titles.index("Phases"))
        self.assertIn("RepoPrompt CE debug app stop confirmed.", progress)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", progress)

    def test_app_operation_display_name_is_precise(self) -> None:
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "stop"}), "app stop")
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_failed_relaunch_before_transition_reports_safe_rebuild_failure_and_source_edit_guidance(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "error: input file '/tmp/Sources/Foo.swift' was modified during the build\n",
            ],
        )

        summary = payload["outputSummary"]
        rendered = rendered_terminal_output(payload)

        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertIn("Rebuild/package failed before this relaunch ticket reached app stop/open.", rendered)
        self.assertIn("This ticket did not stop or reopen RepoPrompt.", rendered)
        self.assertIn("source files changed during the build", rendered)
        self.assertIn("retry after edits settle", rendered)
        self.assertNotIn("superseded", rendered)

    def test_failed_relaunch_after_transition_advises_status_instead_of_preservation(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "==> Stopping existing RepoPrompt CE debug app instance\n",
                "ERROR: open failed\n",
            ],
        )

        rendered = rendered_terminal_output(payload)

        self.assertTrue(payload["outputSummary"]["launchLifecycle"]["transitionStarted"])
        self.assertIn("failed after this ticket began app stop/open lifecycle work", rendered)
        self.assertIn("Check app status before retrying.", rendered)
        self.assertNotIn("did not stop or reopen", rendered)

    def test_canceled_lifecycle_output_distinguishes_supersession_from_cancellation(self) -> None:
        superseded = rendered_terminal_output(
            app_payload(
                "relaunch",
                "canceled",
                130,
                ["terminating process group: superseded by app stop replacement\n"],
                supersededByOperation="app stop",
                supersededByTicket="replacement",
            )
        )
        superseded_stop = rendered_terminal_output(
            app_payload(
                "stop",
                "canceled",
                130,
                ["job superseded before start by app relaunch replacement\n"],
                supersededByOperation="app relaunch",
                supersededByTicket="replacement",
            )
        )
        canceled = rendered_terminal_output(app_payload("stop", "canceled", 130, ["job canceled before start\n"]))

        self.assertIn("superseded by newer app stop intent (ticket replacement)", superseded)
        self.assertIn("superseded by newer app relaunch intent (ticket replacement)", superseded_stop)
        self.assertIn("This app stop ticket was canceled before completion.", canceled)
        self.assertNotIn("superseded", canceled)

    def test_failed_relaunch_recomputes_legacy_summary_for_lifecycle_classification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text(
                "==> Packaging debug app\nerror: input file '/tmp/Foo.swift' was modified during the build\n",
                encoding="utf-8",
            )
            payload = {
                "ticket": "ticket",
                "operation": "app",
                "operationLabel": "app relaunch",
                "args": {"subcommand": "relaunch"},
                "state": "failed",
                "exitCode": 1,
                "timedOut": False,
                "logPath": str(log),
                "outputSummary": {"headline": "failed with exit code 1", "sections": []},
            }

            summary = conductor.output_summary_for_payload(payload)
            enriched = conductor.payload_with_output_summary(payload)

        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(enriched["outputSummary"]["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(enriched["outputSummary"]["launchLifecycle"]["transitionStarted"])

    def test_huge_log_is_capped(self) -> None:
        lines = [f"Sources/Foo.swift:{index}:1: error: boom {index}\n" for index in range(500)]
        summary = summarize("swift-build", "failed", 1, lines)

        rendered_lines = [line for item in summary["sections"] for line in item["lines"]]
        rendered_chars = sum(len(line) for line in rendered_lines)
        self.assertLessEqual(len(rendered_lines), conductor.SUMMARY_FAILURE_MAX_LINES)
        self.assertLessEqual(rendered_chars, conductor.SUMMARY_MAX_CHARS)
        self.assertTrue(summary["truncated"] or summary["omittedLineCount"] > 0)

    def test_ansi_and_long_lines_are_cleaned(self) -> None:
        long_error = "\x1b[31mERROR: " + ("x" * 1000) + "\x1b[0m\n"
        summary = summarize("build", "failed", 1, [long_error])
        highlights = section(summary, "Failure highlights")

        self.assertEqual(len(highlights), 1)
        self.assertNotIn("\x1b", highlights[0])
        self.assertLessEqual(len(highlights[0]), conductor.SUMMARY_LINE_MAX_CHARS)

    def test_summarize_file_preserves_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            summary = conductor.OutputSummarizer.summarize_file(
                "build", {}, "completed", 0, False, log
            )
        self.assertIn("Created: /tmp/App.app", section(summary, "Artifacts"))

    def test_phase_summary_keeps_recent_phases(self) -> None:
        lines = [f"==> Phase {index}\n" for index in range(25)]
        summary = summarize("build", "failed", 1, lines)
        phases = section(summary, "Phases")

        self.assertNotIn("==> Phase 0", phases)
        self.assertIn("==> Phase 24", phases)
        self.assertLessEqual(len(phases), 20)

    def test_generic_failure_includes_recent_output(self) -> None:
        summary = summarize(
            "build",
            "failed",
            1,
            ["setup\n", "ERROR: command failed\n", "tail detail one\n", "tail detail two\n"],
        )

        self.assertIn("ERROR: command failed", section(summary, "Failure highlights"))
        self.assertIn("tail detail two", section(summary, "Recent output"))

    def test_payload_with_output_summary_adds_client_side_json_fallback_without_log_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            payload = {
                "ticket": "ticket",
                "operation": "build",
                "args": {},
                "state": "completed",
                "exitCode": 0,
                "timedOut": False,
                "logPath": str(log),
                "logTail": [f"line {index}\n" for index in range(40)],
            }

            enriched = conductor.payload_with_output_summary(payload)

        self.assertIsNot(enriched, payload)
        self.assertIn("outputSummary", enriched)
        self.assertIn("Created: /tmp/App.app", section(enriched["outputSummary"], "Artifacts"))
        self.assertNotIn("logTail", enriched)
        self.assertEqual(str(log), enriched["logPath"])

    def test_payload_with_output_summary_can_preserve_trimmed_log_tail_for_compatibility(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "args": {},
            "state": "completed",
            "exitCode": 0,
            "timedOut": False,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": [f"line {index}\n" for index in range(40)],
        }

        enriched = conductor.payload_with_output_summary(payload, include_log_tail=True)

        self.assertEqual(len(enriched["logTail"]), conductor.LOG_TAIL_LINES)
        self.assertEqual(enriched["logTail"][0], "line 10\n")

    def test_payload_with_output_summary_drops_existing_tail_when_summary_is_present(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "state": "completed",
            "exitCode": 0,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": ["redundant raw tail\n"],
        }

        enriched = conductor.payload_with_output_summary(payload)

        self.assertIn("outputSummary", enriched)
        self.assertNotIn("logTail", enriched)

    def test_job_payload_exposes_additive_process_timing_and_lifecycle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            diagnostic = root / "stall.sample.txt"
            job = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="test",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={},
                created_at=10.0,
                started_at=12.5,
                finished_at=20.0,
                process_started_at=13.0,
                process_finished_at=19.25,
                progress_transport="pty",
                test_evidence_scope="full-root",
                build_phase_seconds=2.5,
                run_phase_seconds=3.75,
                xctest_progress_sequence=17,
                xctest_last_progress_test="RepoPromptTests.ExampleTests.testProgress",
                xctest_last_progress_action="started",
                xctest_last_progress_observed_at=18.75,
                log_path=root / "ticket.log",
                state="completed",
                exit_code=0,
                diagnostic_paths=[diagnostic],
            )

            payload = job.to_payload()

        self.assertEqual(payload["queuedAt"], 10.0)
        self.assertEqual(payload["processStartedAt"], 13.0)
        self.assertEqual(payload["processFinishedAt"], 19.25)
        self.assertEqual(payload["queueWaitSeconds"], 2.5)
        self.assertEqual(payload["executionSeconds"], 6.25)
        self.assertEqual(payload["testEvidenceScope"], "full-root")
        self.assertEqual(payload["buildPhaseSeconds"], 2.5)
        self.assertEqual(payload["runPhaseSeconds"], 3.75)
        self.assertFalse(payload["measurementInvalid"])
        self.assertEqual(payload["progressTransport"], "pty")
        self.assertEqual(payload["progressSequence"], 17)
        self.assertEqual(payload["lastProgressTest"], "RepoPromptTests.ExampleTests.testProgress")
        self.assertEqual(payload["lastProgressAction"], "started")
        self.assertEqual(payload["lastProgressObservedAt"], 18.75)
        self.assertEqual(payload["diagnosticPaths"], [str(diagnostic)])

    def test_terminal_job_status_attaches_missing_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jobs_dir = root / "jobs"
            jobs_dir.mkdir()
            paths = conductor.Paths(
                repo_root=root,
                repo_hash="test",
                state_dir=root,
                socket_path=root / "conductor.sock",
                pid_path=root / "conductor.pid",
                lock_path=root / "conductor.lock",
                jobs_dir=jobs_dir,
                daemon_log_path=root / "daemon.log",
                daemon_meta_path=root / "daemon.json",
                running_processes_path=root / "running.json",
            )
            log = jobs_dir / "ticket.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            state = conductor.DaemonState(paths)
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=log,
                state="completed",
                finished_at=conductor.now(),
                exit_code=0,
                result_summary="completed successfully",
            )

            payload = state.job_status("ticket", None)

        self.assertIn("outputSummary", payload)
        self.assertIn("Created: /tmp/App.app", section(payload["outputSummary"], "Artifacts"))

    def test_json_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--json", "--full-log"])

    def test_async_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--async", "--full-log"])

    def test_job_list_omits_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jobs_dir = root / "jobs"
            jobs_dir.mkdir()
            paths = conductor.Paths(
                repo_root=root,
                repo_hash="test",
                state_dir=root,
                socket_path=root / "conductor.sock",
                pid_path=root / "conductor.pid",
                lock_path=root / "conductor.lock",
                jobs_dir=jobs_dir,
                daemon_log_path=root / "daemon.log",
                daemon_meta_path=root / "daemon.json",
                running_processes_path=root / "running.json",
            )
            state = conductor.DaemonState(paths)
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=jobs_dir / "ticket.log",
                state="completed",
                output_summary={"headline": "completed successfully", "sections": []},
            )

            payload = state.list_jobs(None)

        self.assertNotIn("outputSummary", payload["jobs"][0])


class CanonicalSwiftCommandTests(unittest.TestCase):
    def test_build_and_test_pin_native_engine_without_changing_other_arguments(self) -> None:
        # Intercept only exec: exercise the actual shell argument construction
        # without starting Swift or depending on the installed Xcode version.
        for arguments in (
            ["build", "-c", "debug", "--product", "RepoPrompt"],
            ["build", "--show-bin-path"],
            ["build", "--build-tests"],
            ["test", "list", "--skip-build"],
            ["test", "--skip-build", "--filter", "Suite/test with spaces"],
            ["--version"],
            [],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [
                        "/bin/bash", "-c",
                        'exec() { printf "%s\\0" "$@"; }; wrapper="$1"; shift; source "$wrapper" "$@"',
                        "canonical-swift-test", str(SCRIPT_DIR / "canonical_swift.sh"),
                        *arguments,
                    ],
                    check=True, capture_output=True,
                )
                argv = result.stdout.decode().split("\0")[:-1]
                swift_index = argv.index("/usr/bin/swift")
                expected = list(arguments)
                if arguments and arguments[0] in {"build", "test"}:
                    expected[1:1] = ["--build-system", "native"]
                self.assertEqual(argv[swift_index + 1:], expected)
                self.assertEqual(argv[:2], ["/usr/bin/env", "-i"])


class JobTicketEnvEligibilityTests(unittest.TestCase):
    def test_direct_swift_invocations_do_not_receive_job_ticket_env(self) -> None:
        self.assertFalse(conductor.job_ticket_env_eligible(["swift", "test", "--filter", "X"]))
        self.assertFalse(conductor.job_ticket_env_eligible(["/usr/bin/swift", "build", "--product", "RepoPrompt"]))
        self.assertFalse(
            conductor.job_ticket_env_eligible(
                ["/repo/Scripts/canonical_swift.sh", "build", "--product", "RepoPrompt"]
            )
        )

    def test_delegated_scripts_receive_job_ticket_env(self) -> None:
        self.assertTrue(conductor.job_ticket_env_eligible(["/repo/Scripts/package_app.sh", "debug"]))
        self.assertTrue(conductor.job_ticket_env_eligible(["python3", "Scripts/debug_app_process.py"]))
        self.assertTrue(conductor.job_ticket_env_eligible([]))


# ---------------------------------------------------------------------------
# Step 2 passive timing integration

metrics = conductor.PIPELINE_METRICS

TELEMETRY_STREAMS = {
    "lf-lines": [b"[1/3] Compiling Foo a.swift\n", b"[2/3] Compiling Foo b.swift\n[3/3] Linking foo\n", b""],
    "bare-cr-progress": [b"[1/4] Compiling A a.swift\r[2/4] Comp", b"iling A b.swift\r", b"\n[3/4] Linking a\n", b""],
    "crlf-across-reads": [b"Build complete! (0.10s)\r", b"\nTest Suite 'All tests' started at 2026-10-05 10:00:00.000.\r\n", b""],
    "split-utf8-and-tail": [b"\xe2\x9c", b"\x93 done\n\xff bad\rTest Case '-[A.B testC]' started.\n", b"unterminated", b""],
    "xctest-methods": [
        b"Test Case '-[A.B testOne]' started.\nTest Case '-[A.B testOne]' passed (0.001 seconds).\n",
        b"Test Case '-[A.B testTwo]' started.\nTest Case '-[A.B testTwo]' failed (0.002 seconds).\n",
        b"",
    ],
    "onlcr-pty": [b"[1/2] Compiling P p.swift\r\r\n[2/2] Linking p\r\n", b"$ next\r\n", b""],
}


def timing_paths(root: Path) -> conductor.Paths:
    jobs_dir = root / "jobs"
    jobs_dir.mkdir(parents=True, exist_ok=True)
    return conductor.Paths(
        repo_root=root,
        repo_hash="test",
        state_dir=root,
        socket_path=root / "conductor.sock",
        pid_path=root / "conductor.pid",
        lock_path=root / "conductor.lock",
        jobs_dir=jobs_dir,
        daemon_log_path=root / "daemon.log",
        daemon_meta_path=root / "daemon.json",
        running_processes_path=root / "running.json",
    )


def timing_state(root: Path, timing: str = "on") -> conductor.DaemonState:
    env = {key: value for key, value in os.environ.items() if key != "RPCE_CONDUCTOR_TIMING"}
    if timing == "off":
        env["RPCE_CONDUCTOR_TIMING"] = "off"
    with mock.patch.dict(os.environ, env, clear=True):
        return conductor.DaemonState(timing_paths(root))


def timing_job(state: conductor.DaemonState, ticket: str, operation: str = "build") -> conductor.Job:
    job = conductor.Job(
        ticket=ticket,
        request_key=None,
        fingerprint="fingerprint",
        operation=operation,
        args={},
        lanes=["style"],
        timeout=None,
        verbose=False,
        env={},
        created_at=conductor.now(),
        log_path=state.paths.jobs_dir / f"{ticket}.log",
        state="running",
        telemetry=state.attach_job_telemetry(operation),
    )
    state.jobs[ticket] = job
    return job


def capture_pump(state: conductor.DaemonState, job: conductor.Job, chunks: list[bytes], observed: bool) -> dict:
    writes: list[bytes] = []
    progress: list[str] = []
    sink = mock.Mock()
    sink.write.side_effect = writes.append
    original_progress = state._record_xctest_progress_locked

    def record_progress(target: conductor.Job, text: str) -> Any:
        progress.append(text)
        return original_progress(target, text)

    with mock.patch.object(state, "_record_xctest_progress_locked", side_effect=record_progress):
        if observed:
            cursor = state._output_telemetry_cursor(job.ticket)
            assert cursor is not None
            state._pump_output_observed(job.ticket, iter(chunks).__next__, sink, cursor)
        else:
            state._pump_output(job.ticket, iter(chunks).__next__, sink)
    return {
        "writes": writes,
        "flushes": sink.flush.call_count,
        "tail": list(job.tail),
        "progress": progress,
        "xctest": (job.xctest_started_count, job.xctest_last_progress_test, job.xctest_last_progress_action),
    }


class GuardedRecorderLock:
    """Recorder lock proxy that records any acquisition under the scheduler lock."""

    def __init__(self, inner: Any, state: conductor.DaemonState, held: threading.local, violations: list[str]) -> None:
        self.inner = inner
        self.state = state
        self.held = held
        self.violations = violations

    def __enter__(self) -> Any:
        if self.state.lock._is_owned():
            self.violations.append("recorder lock taken while holding self.condition")
        result = self.inner.__enter__()
        self.held.depth = getattr(self.held, "depth", 0) + 1
        return result

    def __exit__(self, *exc: Any) -> Any:
        self.held.depth -= 1
        return self.inner.__exit__(*exc)


class GuardedSchedulerLock:
    """Scheduler lock/condition proxy that records acquisition under a recorder lock."""

    def __init__(self, inner: Any, held: threading.local, violations: list[str]) -> None:
        self.inner = inner
        self.held = held
        self.violations = violations

    def __enter__(self) -> Any:
        if getattr(self.held, "depth", 0):
            self.violations.append("self.condition taken while holding the recorder lock")
        return self.inner.__enter__()

    def __exit__(self, *exc: Any) -> Any:
        return self.inner.__exit__(*exc)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)


@unittest.skipIf(metrics is None, "swift_pipeline_metrics.py is unavailable")
class PhaseTimingIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_state(self, name: str, timing: str = "on") -> conductor.DaemonState:
        state = timing_state(self.root / name, timing)
        # Persistence finishes after ``job_wait`` (A009); drain before the tempdir goes.
        self.addCleanup(state._await_job_telemetry, 10.0)
        return state

    def settled(self, state: conductor.DaemonState, waited: dict) -> dict:
        """Private drain, then the job's status: timing is published after the result."""
        self.assertEqual(waited["state"], "completed")
        self.assertIsNotNone(waited.get("outputSummary"))
        self.assertTrue(state._await_job_telemetry(10.0, state.jobs[waited["ticket"]]))
        return state.job_status(waited["ticket"], None)

    def install_lock_guards(self, state: conductor.DaemonState) -> list[str]:
        violations: list[str] = []
        held = threading.local()
        state.condition = GuardedSchedulerLock(state.condition, held, violations)
        state.lock = GuardedSchedulerLock(state.lock, held, violations)
        original_attach = state.attach_job_telemetry

        def attach(operation: str, accepted_ns: Optional[int] = None) -> Any:
            recorder = original_attach(operation, accepted_ns)
            if recorder is not None:
                recorder._lock = GuardedRecorderLock(recorder._lock, state, held, violations)
            return recorder

        state.attach_job_telemetry = attach  # type: ignore[method-assign]
        return violations

    def run_child_job(self, state: conductor.DaemonState, child: str, request_extra: Optional[dict] = None) -> dict:
        argv = [sys.executable, "-u", "-c", child]
        request = {"operation": "build", "args": {}, "env": {}}
        request.update(request_extra or {})
        with mock.patch.object(
            state.registry,
            "prepare",
            side_effect=lambda _request: (argv, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 30.0),
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            enqueued = state.enqueue(request)
            return state.job_wait(enqueued["ticket"], None, 30.0)

    CHILD = (
        "import sys\n"
        "print('[1/3] Compiling Foo a.swift', flush=True)\n"
        "sys.stdout.write('[2/3] Compiling Foo b.swift\\r[3/3] Linking foo\\r\\n'); sys.stdout.flush()\n"
        "sys.stdout.write('Build complete! (0.10s)\\nno newline'); sys.stdout.flush()\n"
    )

    def test_helper_is_loaded_next_to_conductor_and_digest_is_reported(self) -> None:
        self.assertEqual(Path(metrics.__file__).resolve(), Path(conductor.__file__).resolve().with_name("swift_pipeline_metrics.py"))
        self.assertTrue(str(conductor.CONDUCTOR_DIGEST).startswith("sha256:"))
        state = self.make_state("status")
        status = state.status_payload()
        self.assertEqual(status["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertTrue(status["timingEnabled"])
        self.assertEqual(status["protocolVersion"], 15)
        self.assertFalse(self.make_state("off", timing="off").status_payload()["timingEnabled"])

    def test_observed_pump_preserves_raw_bytes_tail_and_progress_for_every_stream(self) -> None:
        for name, chunks in TELEMETRY_STREAMS.items():
            with self.subTest(stream=name):
                legacy_state = self.make_state(f"legacy-{name}", timing="off")
                legacy = capture_pump(legacy_state, timing_job(legacy_state, "t"), chunks, observed=False)
                observed_state = self.make_state(f"observed-{name}")
                observed_job = timing_job(observed_state, "t")
                observed = capture_pump(observed_state, observed_job, chunks, observed=True)
                self.assertEqual(observed, legacy)
                self.assertEqual(observed["writes"], [chunk for chunk in chunks if chunk])
                # Telemetry equals the reference splitter fed the same reads.
                splitter = metrics.RecordSplitter()
                reference = metrics.PipelineRecorder(origin_ns=0)
                for chunk in chunks[:-1]:
                    reference.observe_records(splitter.feed(chunk, 0))
                reference.observe_records(splitter.finish(0))
                payload = observed_job.telemetry.finalize()
                self.assertTrue(payload["output"]["complete"])
                self.assertEqual(payload["output"]["records"], reference.finalize()["output"]["records"])

    def test_receipt_timestamp_precedes_write_flush_and_scheduler_lock(self) -> None:
        state = self.make_state("order")
        job = timing_job(state, "t")
        order: list[str] = []
        chunks = [b"[1/2] Compiling A a.swift\n", b"partial\r", b""]
        reads = iter(chunks)
        real_monotonic_ns = time.monotonic_ns

        def read_chunk() -> bytes:
            order.append("read")
            return next(reads)

        def stamp() -> int:
            order.append("stamp-locked" if state.lock._is_owned() else "stamp")
            return real_monotonic_ns()

        sink = mock.Mock()
        sink.write.side_effect = lambda _chunk: order.append("write")
        sink.flush.side_effect = lambda: order.append("flush")
        cursor = state._output_telemetry_cursor(job.ticket)
        with mock.patch.object(conductor.time, "monotonic_ns", side_effect=stamp):
            state._pump_output_observed(job.ticket, read_chunk, sink, cursor)
        self.assertEqual(order[:4], ["read", "stamp", "write", "flush"])
        self.assertEqual(order[4:8], ["read", "stamp", "write", "flush"])
        self.assertEqual(order[8:10], ["read", "stamp"])
        self.assertNotIn("stamp-locked", order)
        payload = job.telemetry.finalize()
        self.assertEqual(payload["output"]["records"], 2)

    def test_read_process_output_uses_legacy_pump_without_a_recorder(self) -> None:
        for timing, attach in (("off", True), ("on", False)):
            with self.subTest(timing=timing, attach=attach):
                state = self.make_state(f"dispatch-{timing}", timing)
                job = timing_job(state, "t")
                if not attach:
                    job.telemetry = None
                transport = mock.Mock()
                transport.read_chunk.side_effect = [b"line\n", b""]
                with mock.patch.object(state, "_pump_output_observed") as observed:
                    state._read_process_output(job.ticket, mock.Mock(), io.BytesIO(), transport)
                observed.assert_not_called()
                self.assertEqual(list(job.tail), ["line\n"])
                transport.close_reader.assert_called_once()

    def test_end_to_end_job_records_boundaries_persists_and_reports_phase_metrics(self) -> None:
        state = self.make_state("e2e")
        violations = self.install_lock_guards(state)
        client = [
            {"name": "artifact_evaluation", "durationNs": 1500, "counters": {"bytesHashed": 7}},
            {"name": 5, "durationNs": 1},
            "junk",
        ]
        payload = self.settled(state, self.run_child_job(state, self.CHILD, {"clientMetrics": client}))

        self.assertEqual(violations, [])
        self.assertEqual(payload["state"], "completed")
        self.assertEqual(payload["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        phase = payload["phaseMetrics"]
        self.assertEqual(phase["schema"], 1)
        self.assertEqual(phase["status"], "complete", phase)
        for name in ("queueWait", "prepare", "spawn", "spawnToFirstOutput", "processObserved", "postRunProvenance", "exitToLaneRelease", "acceptedToLaneRelease"):
            self.assertIsInstance(phase["intervals"][name]["ns"], int, name)
        self.assertEqual(phase["intervals"]["sourceSnapshot"]["quality"], "not_applicable")
        self.assertEqual(phase["output"]["records"], 5)
        self.assertTrue(phase["output"]["complete"])
        self.assertEqual(phase["commandCount"], 1)
        operations = {(item["name"], item["origin"]): item for item in phase["operations"]}
        self.assertEqual(operations[("output_summary", "daemon.summary")]["calls"], 1)
        self.assertIn(("retention_pass", "daemon.enqueue"), operations)
        self.assertIn(("retention_pass", "daemon.lane_release"), operations)
        self.assertEqual(operations[("output_reader_cpu", "daemon.reader")]["total"]["quality"], "measured_cpu")
        client_op = operations[("artifact_evaluation", "client")]
        self.assertEqual(client_op["total"], {"ns": 1500, "quality": "reported_duration"})
        self.assertEqual(client_op["counters"], {"bytesHashed": 7})
        self.assertEqual(phase["invalidInputs"], 0)

        ticket = payload["ticket"]
        jobs_dir = state.paths.jobs_dir
        events = [json.loads(line) for line in (jobs_dir / f"{ticket}.timing-events.jsonl").read_text().splitlines()]
        boundaries = [event["name"] for event in events if event["k"] == "boundary"]
        self.assertEqual(
            boundaries,
            ["request_accepted", "lane_dispatched", "prepare_start", "prepare_end", "command_start",
             "popen_before", "popen_after", "exit_observed", "provenance_start", "provenance_end", "lane_released"],
        )
        self.assertTrue(set(boundaries) <= metrics.KNOWN_BOUNDARIES)
        timings = json.loads((jobs_dir / f"{ticket}.timings.json").read_text())
        self.assertEqual(timings["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(timings["phaseMetrics"], phase)
        self.assertIsNone(timings["runner"])
        rows, malformed = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual(malformed, 0)
        self.assertEqual([row["ticket"] for row in rows], [ticket])
        self.assertEqual(rows[0]["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(rows[0]["exitCode"], 0)
        # Status listings stay compact: no phaseMetrics without include_summary.
        self.assertNotIn("phaseMetrics", state.list_jobs(None)["jobs"][0])

    def test_kill_switch_produces_identical_output_and_no_timing_artifacts(self) -> None:
        on_state = self.make_state("on")
        off_state = self.make_state("off", timing="off")
        on = self.run_child_job(on_state, self.CHILD)
        off = self.run_child_job(off_state, self.CHILD)
        self.assertEqual(off["phaseMetrics"], {"schema": 1, "status": "disabled"})
        self.assertIsNone(off_state.jobs[off["ticket"]].telemetry)
        self.assertEqual(
            Path(on["logPath"]).read_bytes(), Path(off["logPath"]).read_bytes()
        )
        self.assertEqual(on["logTail"], off["logTail"])
        self.assertEqual(on["outputSummary"], off["outputSummary"])
        self.assertEqual(sorted(path.name for path in off_state.paths.jobs_dir.iterdir()), [f"{off['ticket']}.log"])
        self.assertFalse((off_state.paths.state_dir / "metrics").exists())

    def test_telemetry_failures_never_change_job_result_or_output(self) -> None:
        baseline = self.run_child_job(self.make_state("baseline", timing="off"), self.CHILD)

        classifier_state = self.make_state("classifier")
        with mock.patch.object(metrics, "classify_record", side_effect=RuntimeError("boom")):
            failed = self.settled(classifier_state, self.run_child_job(classifier_state, self.CHILD))
        self.assertEqual(failed["state"], "completed")
        self.assertEqual(Path(failed["logPath"]).read_bytes(), Path(baseline["logPath"]).read_bytes())
        self.assertEqual(failed["logTail"], baseline["logTail"])
        self.assertEqual(failed["phaseMetrics"]["status"], "partial")
        self.assertFalse(failed["phaseMetrics"]["output"]["complete"])
        self.assertIn("RuntimeError", failed["phaseMetrics"]["output"]["error"])

        persist_state = self.make_state("persist")
        with mock.patch.object(metrics, "write_events_jsonl", side_effect=OSError("disk full")):
            persisted = self.settled(persist_state, self.run_child_job(persist_state, self.CHILD))
        self.assertEqual(persisted["state"], "completed")
        self.assertEqual(persisted["exitCode"], 0)
        self.assertIn("disk full", persisted["phaseMetricsPersistError"])
        self.assertEqual(persisted["phaseMetrics"]["status"], "complete")
        self.assertFalse((persist_state.paths.state_dir / "metrics").exists())

        recorder_state = self.make_state("recorder")
        with mock.patch.object(metrics.PipelineRecorder, "record_boundary", side_effect=RuntimeError("x")):
            boundary_failed = self.run_child_job(recorder_state, self.CHILD)
        self.assertEqual(boundary_failed["state"], "completed")
        self.assertEqual(Path(boundary_failed["logPath"]).read_bytes(), Path(baseline["logPath"]).read_bytes())

    def test_slot_wait_records_contention_only_when_a_foreign_holder_blocks(self) -> None:
        state = self.make_state("slots")
        lock_root = self.root / "machine-locks"
        lock_root.mkdir(mode=0o700)
        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root), mock.patch.object(
            conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01
        ):
            free_job = timing_job(state, "free")
            slot = state._acquire_global_slot("free", "heavy")
            state._release_global_slot(slot)

            busy_job = timing_job(state, "busy")
            holder = (lock_root / "global-heavy-0.lock").open("a+")
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
            releaser = threading.Timer(0.1, lambda: (fcntl.flock(holder.fileno(), fcntl.LOCK_UN), holder.close()))
            releaser.start()
            slot = state._acquire_global_slot("busy", "heavy")
            releaser.join()
            state._release_global_slot(slot)

        free = free_job.telemetry.finalize()["slotWaits"]
        busy = busy_job.telemetry.finalize()["slotWaits"]
        self.assertEqual([(item["slot"], item["contended"]) for item in free], [("heavy", False)])
        self.assertEqual([(item["slot"], item["contended"]) for item in busy], [("heavy", True)])
        self.assertGreaterEqual(busy[0]["ns"], 50_000_000)

    def test_retention_removes_timing_files_of_pruned_and_orphaned_tickets(self) -> None:
        state = self.make_state("retention")
        jobs_dir = state.paths.jobs_dir
        kept = timing_job(state, "kept")
        kept.state = "completed"
        kept.finished_at = conductor.now()
        pruned = timing_job(state, "pruned")
        pruned.state = "completed"
        pruned.finished_at = conductor.now() - conductor.TERMINAL_RETENTION_SECONDS - 10
        old = time.time() - conductor.TERMINAL_RETENTION_SECONDS - 10
        for ticket in ("kept", "pruned", "orphan", "fresh-orphan"):
            for suffix in conductor.TIMING_FILE_SUFFIXES:
                path = jobs_dir / f"{ticket}{suffix}"
                path.write_text("{}")
                if ticket != "fresh-orphan":
                    os.utime(path, (old, old))
        with state.condition:
            state._retention_pass_locked()
        remaining = sorted(path.name for path in jobs_dir.iterdir() if "timing" in path.name)
        expected = sorted(f"{ticket}{suffix}" for ticket in ("kept", "fresh-orphan") for suffix in conductor.TIMING_FILE_SUFFIXES)
        self.assertEqual(remaining, expected)
        self.assertNotIn("pruned", state.jobs)

    def test_metrics_command_reads_history_client_side_with_filters(self) -> None:
        state = self.make_state("cli")
        history = metrics.RotatingJsonl(conductor.timing_history_path(state.paths))
        for ticket, kind in (("a", "build"), ("b", "test"), ("c", "build")):
            history.append({"ticket": ticket, "kind": kind, "status": "complete", "intervals": {"queueWait": {"ns": 2_000_000, "quality": "measured_wall"}}})
        with mock.patch.object(conductor, "request_daemon", side_effect=AssertionError("no daemon")):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(conductor.handle_metrics_command(state.paths, ["--kind", "build", "--last", "1", "--json"]), 0)
            report = json.loads(output.getvalue())
            self.assertEqual([row["ticket"] for row in report["rows"]], ["c"])
            self.assertEqual(report["totalRows"], 3)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(conductor.handle_metrics_command(state.paths, ["--ticket", "b"]), 0)
        text = output.getvalue()
        self.assertIn("1 of 3 rows", text)
        self.assertIn("queue=2.0ms", text)
        with self.assertRaises(conductor.ConductorError):
            conductor.handle_metrics_command(state.paths, ["--last", "-1"])
        self.assertIn("./conductor metrics [--last N] [--kind K] [--ticket T] [--json]", conductor.HELP)
        self.assertIn("RPCE_CONDUCTOR_TIMING=off", conductor.HELP)

    def test_client_metrics_are_outside_request_identity(self) -> None:
        state = self.make_state("identity")
        request = {"operation": "build", "args": {}, "env": {}}
        with_metrics = dict(request, clientMetrics=[{"name": "artifact_evaluation", "durationNs": 5}])
        self.assertEqual(state.registry.fingerprint(request), state.registry.fingerprint(with_metrics))
        collected: list[dict] = []
        sink = conductor.client_metrics_sink(collected)
        for index in range(conductor.CLIENT_METRICS_MAX_ITEMS + 5):
            sink("op", index, {"bytesHashed": 1})
        sink("missing", None)
        self.assertEqual(len(collected), conductor.CLIENT_METRICS_MAX_ITEMS)
        self.assertEqual(collected[0], {"name": "op", "durationNs": 0, "counters": {"bytesHashed": 1}})

    def test_artifact_fingerprint_sink_counts_bytes_and_files_without_changing_result(self) -> None:
        artifact = self.root / "products" / "Example.xctest"
        executable = artifact / "Contents" / "MacOS" / "Example"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"x" * 3000)
        (artifact / "Contents" / "Info.plist").write_bytes(b"y" * 200)
        bundle = self.root / "products" / "Resources.bundle"
        bundle.mkdir()
        (bundle / "data").write_bytes(b"z" * 50)
        calls: list[tuple] = []
        plain = conductor.test_artifact_fingerprint(artifact)
        explicit = conductor.test_artifact_fingerprint(artifact, sink=lambda *call: calls.append(call))
        with conductor.artifact_operation_sink(lambda *call: calls.append(call)):
            ambient = conductor.test_artifact_fingerprint(artifact)
        self.assertEqual(plain, explicit)
        self.assertEqual(plain, ambient)
        self.assertEqual([call[0] for call in calls], ["artifact_fingerprint", "artifact_fingerprint"])
        self.assertEqual(calls[0][2], {"bytesHashed": 3250, "filesHashed": 3})
        self.assertIsInstance(calls[0][1], int)
        failing = conductor.test_artifact_fingerprint(artifact, sink=mock.Mock(side_effect=RuntimeError("sink")))
        self.assertEqual(failing, plain)

    def test_runner_writes_its_own_timings_and_hides_the_path_from_descendants(self) -> None:
        target = self.root / "jobs-runner"
        target.mkdir()
        path = target / "t.runner-timings.json"
        env = {conductor.TIMING_RUNNER_PATH_ENV_KEY: str(path), "REPOPROMPT_CONDUCTOR_JOB_TICKET": "t"}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(io.StringIO()):
            code = conductor.run_operation_runner(json.dumps({"kind": "no-such-kind", "repoRoot": str(self.root)}))
            self.assertNotIn(conductor.TIMING_RUNNER_PATH_ENV_KEY, os.environ)
        self.assertEqual(code, 2)
        runner = json.loads(path.read_text())
        self.assertEqual(runner["process"], "runner")
        self.assertEqual(runner["ticket"], "t")
        self.assertEqual(runner["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(runner["phaseMetrics"]["process"], "runner")
        self.assertEqual(conductor.read_runner_timings(path), runner)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(conductor.run_operation_runner(json.dumps({"kind": "no-such-kind"})), 2)

    def test_runner_timing_path_is_only_given_to_conductor_runner_children(self) -> None:
        state = self.make_state("runner-env")
        seen: list[dict] = []
        real_popen = conductor.subprocess.Popen
        runner_argv = state.registry._internal_argv("app_status", {})
        plain_argv = [sys.executable, "-c", "pass"]

        def capture(argv: Any, *args: Any, **kwargs: Any) -> Any:
            if argv in (runner_argv, plain_argv):
                seen.append(dict(kwargs["env"]))
                return real_popen(plain_argv, *args, **kwargs)
            return real_popen(argv, *args, **kwargs)

        tickets: list[str] = []
        for argv in (runner_argv, plain_argv):
            with mock.patch.object(
                state.registry, "prepare", return_value=(argv, ["style"], self.root, {}, 30.0)
            ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
                conductor.subprocess, "Popen", side_effect=capture
            ):
                enqueued = state.enqueue({"operation": "build", "args": {}, "env": {}})
                tickets.append(enqueued["ticket"])
                self.assertEqual(state.job_wait(enqueued["ticket"], None, 30.0)["state"], "completed")
        self.assertEqual(len(seen), 2)
        self.assertEqual(
            seen[0][conductor.TIMING_RUNNER_PATH_ENV_KEY],
            str(state.paths.jobs_dir / f"{tickets[0]}.runner-timings.json"),
        )
        self.assertNotIn(conductor.TIMING_RUNNER_PATH_ENV_KEY, seen[1])

    # -- review r2 Step 2 P1 regressions ----------------------------------------

    def hold_history_lock(self, state: conductor.DaemonState) -> Any:
        history = conductor.timing_history_path(state.paths)
        history.parent.mkdir(parents=True, exist_ok=True)
        holder = history.with_name(history.name + ".lock").open("a+")
        fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
        self.addCleanup(holder.close)
        return holder

    def test_held_history_lock_never_delays_the_job_result(self) -> None:
        # OracleA-009: optional persistence must not gate the result or summary.
        state = self.make_state("history-lock")
        state.timing_history.lock_timeout = 30.0
        holder = self.hold_history_lock(state)
        safety = threading.Timer(8.0, lambda: fcntl.flock(holder.fileno(), fcntl.LOCK_UN))
        safety.start()
        self.addCleanup(safety.cancel)
        started = time.monotonic()
        waited = self.run_child_job(state, self.CHILD)
        elapsed = time.monotonic() - started
        job = state.jobs[waited["ticket"]]
        self.assertLess(elapsed, 3.0)
        self.assertEqual((waited["state"], waited["exitCode"]), ("completed", 0))
        self.assertIsNotNone(waited["outputSummary"])
        self.assertFalse(job.telemetry_persisted)  # still blocked on the history lock
        self.assertIn(waited["phaseMetrics"]["status"], {"pending", "complete"})
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
        status = self.settled(state, waited)
        self.assertNotIn("phaseMetricsPersistError", status)
        self.assertEqual(status["phaseMetrics"]["status"], "complete")
        rows, _ = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual([row["ticket"] for row in rows], [waited["ticket"]])

        # A lock held past the bounded deadline becomes a persistence error.
        stuck = self.make_state("history-lock-timeout")
        stuck.timing_history.lock_timeout = 0.2
        self.hold_history_lock(stuck)
        waited = self.run_child_job(stuck, self.CHILD)
        status = self.settled(stuck, waited)
        self.assertEqual(status["exitCode"], 0)
        self.assertIn("history lock busy", status["phaseMetricsPersistError"])
        self.assertTrue((stuck.paths.jobs_dir / f"{waited['ticket']}.timings.json").exists())

    def enqueue_blocked(self, state: conductor.DaemonState, lane: str) -> conductor.Job:
        """Enqueue a job that stays queued: its lane is held by a foreign ticket."""
        argv = [sys.executable, "-c", "pass"]
        with state.condition:
            state.active_lanes[lane] = "blocker"
        with mock.patch.object(
            state.registry, "prepare", return_value=(argv, [lane], state.paths.repo_root, {}, 30.0)
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
        job = state.jobs[ticket]
        self.assertEqual(job.state, "queued")
        return job

    def assert_undispatched_timing_persisted(self, state: conductor.DaemonState, job: conductor.Job) -> None:
        self.assertEqual((job.state, job.exit_code), ("canceled", 130))
        self.assertIsNone(job.telemetry_dispatch_ns)
        self.assertTrue(state._await_job_telemetry(10.0))  # private drain; no status/wait query
        self.assertIsNone(job.telemetry_persist_error)
        jobs_dir = state.paths.jobs_dir
        timings = json.loads((jobs_dir / f"{job.ticket}.timings.json").read_text())
        self.assertTrue((jobs_dir / f"{job.ticket}.timing-events.jsonl").exists())
        phase = timings["phaseMetrics"]
        self.assertEqual(job.phase_metrics, phase)
        self.assertEqual(phase["intervals"]["queueWait"]["quality"], "unavailable")
        self.assertEqual(phase["intervals"]["acceptedToLaneRelease"]["quality"], "unavailable")
        rows, _ = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual([(row["ticket"], row["exitCode"]) for row in rows], [(job.ticket, 130)])

    def test_queued_cancel_persists_timing_without_a_status_or_wait_query(self) -> None:
        # OracleA-008: terminal before dispatch, never queried.
        state = self.make_state("queued-cancel")
        violations = self.install_lock_guards(state)
        job = self.enqueue_blocked(state, "style")
        state.job_cancel(job.ticket, None)
        self.assert_undispatched_timing_persisted(state, job)
        self.assertEqual(violations, [])

    def test_queued_supersede_persists_timing_without_a_status_or_wait_query(self) -> None:
        state = self.make_state("queued-supersede")
        job = self.enqueue_blocked(state, "liveApp")
        with state.condition:
            superseded, _ = state._supersede_live_app_jobs_locked(mock.Mock(ticket="newer"), "app relaunch")
        self.assertEqual([(item["ticket"], item["cancellationState"]) for item in superseded], [(job.ticket, "canceled")])
        self.assert_undispatched_timing_persisted(state, job)

    def test_queued_force_stop_persists_timing_without_a_status_or_wait_query(self) -> None:
        state = self.make_state("queued-stop")
        job = self.enqueue_blocked(state, "style")
        state.stop(force=True)
        self.assert_undispatched_timing_persisted(state, job)

    @contextlib.contextmanager
    def failing_timing_worker(self, failure: str) -> Any:
        """Fail only the timing worker's thread construction or start; other threads run."""
        real_thread = threading.Thread

        class SelectiveThread(real_thread):  # type: ignore[misc, valid-type]
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                if failure == "construct" and str(kwargs.get("name", "")).startswith("timing-"):
                    raise RuntimeError("injected timing worker construction failure")
                super().__init__(*args, **kwargs)

            def start(self) -> None:
                if failure == "start" and self.name.startswith("timing-"):
                    raise RuntimeError("can't start new thread (injected)")
                super().start()

        with mock.patch.object(conductor.threading, "Thread", SelectiveThread):
            yield

    def assert_timing_worker_failure_recorded(self, state: conductor.DaemonState, job: conductor.Job) -> None:
        self.assertEqual((job.state, job.exit_code), ("canceled", 130))
        self.assertNotIn(job.ticket, state.queue)
        self.assertEqual(state._telemetry_completions, 0)
        self.assertTrue(job.telemetry_persisted)
        self.assertIn("timing worker", job.telemetry_persist_error)
        self.assertTrue(state._await_job_telemetry(1.0))
        status = state.job_status(job.ticket, None)
        self.assertEqual(status["state"], "canceled")
        self.assertEqual(status["phaseMetrics"], {"schema": 1, "status": "failed", "telemetryError": job.telemetry_persist_error})
        self.assertEqual(status["phaseMetricsPersistError"], job.telemetry_persist_error)
        self.assertFalse((state.paths.jobs_dir / f"{job.ticket}.timings.json").exists())
        self.assertFalse(conductor.timing_history_path(state.paths).exists())

    def test_timing_worker_failure_never_escapes_queued_cancel(self) -> None:
        # R3-S2-P1-01: optional timing must not turn a cancellation into an RPC error.
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"cancel-worker-{failure}")
                violations = self.install_lock_guards(state)
                job = self.enqueue_blocked(state, "style")
                with self.failing_timing_worker(failure):
                    payload = state.job_cancel(job.ticket, None)
                self.assertEqual((payload["state"], payload["exitCode"]), ("canceled", 130))
                self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_timing_worker_failure_never_escapes_queued_supersession(self) -> None:
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"supersede-worker-{failure}")
                violations = self.install_lock_guards(state)
                jobs = [self.enqueue_blocked(state, "liveApp") for _ in range(2)]
                with self.failing_timing_worker(failure), state.condition:
                    superseded, _ = state._supersede_live_app_jobs_locked(mock.Mock(ticket="newer"), "app relaunch")
                self.assertEqual(
                    [(item["ticket"], item["cancellationState"]) for item in superseded],
                    [(job.ticket, "canceled") for job in jobs],
                )
                for job in jobs:
                    self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_timing_worker_failure_never_escapes_queued_force_stop(self) -> None:
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"stop-worker-{failure}")
                violations = self.install_lock_guards(state)
                jobs = [self.enqueue_blocked(state, "style") for _ in range(3)]
                server = mock.Mock()
                state.server = server
                with self.failing_timing_worker(failure):
                    payload = state.stop(force=True)
                self.assertTrue(payload["shutdownRequested"])
                deadline = time.monotonic() + 5.0
                while not server.shutdown.called and time.monotonic() < deadline:
                    time.sleep(0.01)
                server.shutdown.assert_called_once_with()  # the original shutdown thread still ran
                for job in jobs:
                    self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_launchd_plist_forwards_the_kill_switch_and_status_reports_the_mode(self) -> None:
        # OracleA-007 / RV-R2-S2-P1-01: launchd does not inherit the client environment.
        paths = timing_paths(self.root / "launchd")
        script = Path(conductor.__file__).resolve()
        for setting in ("off", "on", None):
            env = {key: value for key, value in os.environ.items() if key != conductor.TIMING_ENV_KEY}
            if setting is not None:
                env[conductor.TIMING_ENV_KEY] = setting
            with self.subTest(setting=setting), mock.patch.dict(os.environ, env, clear=True):
                bootstrapped: list[list[str]] = []
                with mock.patch.object(conductor, "bootout_daemon_launchd"), mock.patch.object(
                    conductor, "run_launchctl", side_effect=lambda args: bootstrapped.append(list(args)) or 0
                ), mock.patch.object(conductor, "spawn_daemon_direct") as direct:
                    conductor.spawn_daemon(paths, script)
                direct.assert_not_called()
                plist_path = conductor.daemon_launchd_plist_path(paths)
                self.assertEqual(bootstrapped, [["bootstrap", f"gui/{os.getuid()}", str(plist_path)]])
                with plist_path.open("rb") as handle:
                    environment = conductor.plistlib.load(handle)["EnvironmentVariables"]
                expected = {
                    "REPOPROMPT_DEV_DAEMON_STATE_DIR": str(paths.state_dir),
                    "REPOPROMPT_DEV_DAEMON_SOCKET": str(paths.socket_path),
                }
                if setting is not None:
                    expected[conductor.TIMING_ENV_KEY] = setting
                self.assertEqual(environment, expected)
                # The daemon started with that environment reports the effective mode.
                with mock.patch.dict(os.environ, environment):
                    started = conductor.DaemonState(timing_paths(self.root / f"launchd-{setting}"))
                status = started.status_payload()
                self.assertEqual(status["timingEnabled"], setting != "off")
                self.assertEqual(status["timing"]["setting"], setting)
                self.assertEqual(status["timing"]["readAt"], "daemon start")
                with contextlib.redirect_stdout(io.StringIO()) as rendered:
                    conductor.render_daemon_status(status)
                source = f"RPCE_CONDUCTOR_TIMING={setting}" if setting is not None else "RPCE_CONDUCTOR_TIMING unset"
                mode = "disabled" if setting == "off" else "enabled"
                self.assertIn(f"timing:   {mode} ({source} at daemon start)", rendered.getvalue())
        # The kill switch never enters request identity or job environments.
        state = self.make_state("identity-env")
        request = {"operation": "build", "args": {}, "env": {conductor.TIMING_ENV_KEY: "off"}}
        self.assertNotIn(conductor.TIMING_ENV_KEY, state.registry._request_env_snapshot(request))
        self.assertNotIn(conductor.TIMING_ENV_KEY, conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)

    def test_daemon_start_reports_a_running_daemon_timing_mismatch_without_restarting(self) -> None:
        paths = timing_paths(self.root / "mismatch")
        running = self.make_state("mismatch-running").status_payload()  # enabled, variable unset
        env = dict(os.environ, **{conductor.TIMING_ENV_KEY: "off"})
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            conductor, "ensure_daemon", return_value=running
        ) as ensure, mock.patch.object(conductor, "spawn_daemon") as spawn, mock.patch.object(
            conductor, "request_daemon"
        ) as request:
            with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(conductor.handle_daemon_command(paths, ["start", "--json"]), 0)
        ensure.assert_called_once_with(paths, start_if_needed=True)
        spawn.assert_not_called()
        request.assert_not_called()
        notice = json.loads(out.getvalue())["timingNotice"]
        self.assertEqual(err.getvalue().strip(), notice)
        self.assertIn("has timing enabled (RPCE_CONDUCTOR_TIMING unset at its start)", notice)
        self.assertIn("asks for disabled", notice)
        self.assertIn("was not restarted", notice)
        self.assertIsNone(conductor.daemon_timing_notice(running, {}))
        self.assertIsNone(conductor.daemon_timing_notice(running, {conductor.TIMING_ENV_KEY: "on"}))
        self.assertIsNone(conductor.daemon_timing_notice({"pid": 1}, {conductor.TIMING_ENV_KEY: "off"}))
        # A daemon whose helper failed to load names that cause, not the variable.
        no_helper = dict(running, timingEnabled=False, timing=dict(running["timing"], enabled=False, helperLoaded=False))
        self.assertIn("(timing helper not loaded at its start)", conductor.daemon_timing_notice(no_helper, {}))
        with contextlib.redirect_stdout(io.StringIO()) as rendered:
            conductor.render_daemon_status(no_helper)
        self.assertIn("timing:   disabled (timing helper not loaded at daemon start)", rendered.getvalue())


if __name__ == "__main__":
    unittest.main()
