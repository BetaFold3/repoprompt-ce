#!/usr/bin/env python3
"""Deterministic tests for Scripts/swift_build_benchmark.py (plan Step 9).

No Swift builds and no daemons: conductor clients, host probes and clocks are
fakes; worktree ownership uses a real temporary Git repository and slot
probes use real flock files in a temporary directory.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import swift_build_benchmark as bench  # noqa: E402

ON, SKIP = bench.ARM_ON, bench.ARM_SKIP


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps = 0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.now += seconds


class FakeProbe:
    def __init__(self, thermal="nominal", load=1.0, main=None, slots=None) -> None:
        self.thermal_value = thermal
        self.load = load
        self.main = main or {"state": "idle"}
        self.slot_state = slots or {"state": "free", "slots": []}

    def thermal(self):
        return self.thermal_value() if callable(self.thermal_value) else self.thermal_value

    def load1(self):
        return self.load() if callable(self.load) else self.load

    def main_daemon(self):
        return self.main

    def slots(self, extra=()):
        return self.slot_state


def phase_metrics(primary_ns=10_000_000_000, slot="heavy", contended=False, status="complete"):
    return {
        "status": status,
        "intervals": {
            "acceptedToLaneRelease": {"ns": primary_ns, "quality": "measured_wall"} if primary_ns is not None
            else {"ns": None, "quality": "unavailable"},
            "processObserved": {"ns": 9_000_000_000, "quality": "measured_wall"},
            "queueWait": {"ns": 1_000, "quality": "measured_wall"},
        },
        "slotWaits": [{"ns": 1_000, "quality": "measured_wall", "slot": slot, "contended": contended}],
        "segments": [],
    }


def job_payload(ticket, *, state="completed", exit_code=0, digest="D", metrics=None, operation="test",
                args=None, invalid=False, fingerprint="F"):
    return {
        "ticket": ticket, "state": state, "exitCode": exit_code, "operation": operation,
        "args": args if args is not None else {"filter": bench.PROBE_SUITE},
        "measurementInvalid": invalid, "conductorDigest": digest, "fingerprint": fingerprint,
        "phaseMetrics": metrics if metrics is not None else phase_metrics(),
    }


class FakeClient:
    """Scripted conductor client. ``plan`` yields per-submit status sequences."""

    def __init__(self, root: Path, arm: str, plan=None) -> None:
        self.arm = arm
        self.paths = SimpleNamespace(jobs_dir=root / arm, socket_path=root / arm / "absent.sock")
        self.paths.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.pid = 42
        self.stops = []
        self.started_producers = []
        self.plan = plan or (lambda ticket: [job_payload(ticket)])
        self.submits = []
        self.cancels = []
        self.statuses = {}
        self.by_key = {}
        self.submit_errors = []
        self.key_status_errors = []
        self.persist = True
        # launchd: True loaded, False unloaded, None unknown (launchctl failure).
        self.launchd = True
        self.bootouts = []
        self.bootout_error = None

    def _persist(self, ticket, payload):
        if self.persist and payload.get("state") in bench.TERMINAL_STATES:
            (self.paths.jobs_dir / f"{ticket}.timings.json").write_text(
                json.dumps({"schema": 1, "ticket": ticket, "phaseMetrics": payload["phaseMetrics"]}))

    def submit(self, recipe, key, on_started=None):
        self.submits.append(key)
        if on_started is not None:
            on_started(1000 + len(self.submits), "tok")
            self.started_producers.append(key)
        if self.submit_errors:
            error = self.submit_errors.pop(0)
            if error == "accepted-then-lost":
                self._accept(key)
            raise bench.AmbiguousSubmit("lost response")
        return self._accept(key)

    def _accept(self, key):
        ticket = f"{self.arm}-{len(self.submits)}"
        self.statuses[ticket] = list(self.plan(ticket))
        self.by_key[key] = ticket
        return {"ticket": ticket, "requestKey": key, "reused": False}

    def status(self, ticket=None, request_key=None):
        if request_key is not None:
            if self.key_status_errors:
                raise Exception(self.key_status_errors.pop(0))
            if request_key not in self.by_key:
                raise Exception(f"no job found for request key '{request_key}'")
            ticket = self.by_key[request_key]
            return {"ticket": ticket, "requestKey": request_key}
        sequence = self.statuses[ticket]
        payload = sequence.pop(0) if len(sequence) > 1 else sequence[0]
        self._persist(ticket, payload)
        return payload

    def cancel(self, ticket):
        self.cancels.append(ticket)
        self.statuses[ticket] = [job_payload(ticket, state="canceled", exit_code=130)]
        return {}

    def daemon_status(self):
        if self.pid is None:
            raise AssertionError("a stopped daemon must never be queried")
        return {"pid": self.pid, "conductorDigest": "D", "runningJobs": [], "queuedJobs": [], "repoRoot": "/x"}

    def expected_fingerprint(self, recipe):
        return "F"

    def live_pid(self):
        return self.pid

    def verify_owned_daemon(self, pid):
        return pid == self.pid

    def daemon_identity(self, pid):
        return {"pid": pid, "processStart": None}

    def stop_daemon(self, expected):
        self.stops.append(expected.get("pid"))
        stopped, self.pid = self.pid, None
        return {"stoppedPid": stopped}

    def launchd_label(self):
        return f"label-{self.arm}"

    def launchd_loaded(self):
        return self.launchd

    def bootout_launchd(self):
        self.bootouts.append(self.launchd)
        if self.bootout_error is not None:
            error, self.bootout_error = self.bootout_error, None
            raise error
        if self.launchd is True:
            self.launchd = False


class FakeObserver(bench.ThermalObserver):
    """Thread-free observer on the fake clock: readings at start and at finish."""

    def __init__(self, clock, reader=lambda: "nominal") -> None:
        super().__init__(reader, clock.monotonic, max_gap=float("inf"))

    def start(self) -> None:
        self.started = True
        self._read()

    def finish(self):
        if not self.finished:
            self.finished = True
            if self.started:
                self._read()
        return self.summary()


def make_session(tmp: Path, *, clients=None, probe=None, clock=None, blocks=5, store=None, observer_factory=None):
    capture = bench.Capture(tmp / "capture")
    capture.create()
    clock = clock or FakeClock()
    clients = clients or {arm: FakeClient(tmp, arm) for arm in bench.ARMS}
    manifest = bench.load_fixture_manifest()
    ledgers = {arm: bench.FixtureLedger(tmp, manifest, busy_check=lambda: None) for arm in bench.ARMS}
    return bench.Session(
        run_id="t", capture=capture, clients=clients, probe=probe or FakeProbe(), ledgers=ledgers,
        expected_digests={arm: "D" for arm in bench.ARMS}, admission=bench.Admission(threshold=28.0, physical_cpu=28),
        blocks=blocks, clock=clock, log=lambda message: None, store=store,
        observer_factory=observer_factory or (lambda: FakeObserver(clock)),
    )


def attempts(capture: bench.Capture):
    return [json.loads(line) for line in capture.attempts.read_text().splitlines()]


class ThermalAndAdmissionTests(unittest.TestCase):
    def test_thermal_mapping_is_strict(self):
        self.assertEqual(bench.thermal_state(lambda: 0), "nominal")
        self.assertEqual(bench.thermal_state(lambda: 1), "fair")
        self.assertEqual(bench.thermal_state(lambda: 3), "critical")
        self.assertEqual(bench.thermal_state(lambda: 9), "unknown")
        self.assertEqual(bench.thermal_state(lambda: True), "unknown")
        self.assertEqual(bench.thermal_state(lambda: (_ for _ in ()).throw(OSError("x"))), "unknown")

    def test_real_thermal_reader_returns_a_known_label(self):
        self.assertIn(bench.thermal_state(), {"nominal", "fair", "serious", "critical", "unknown"})

    def test_main_status_classification(self):
        idle = {"protocolVersion": 15, "runningJobs": [], "queuedJobs": [], "activeJobsByLane": {}}
        self.assertEqual(bench.classify_main_status(idle, 15)["state"], "idle")
        self.assertEqual(bench.classify_main_status({**idle, "queuedJobs": [{}]}, 15)["state"], "busy")
        self.assertEqual(bench.classify_main_status({**idle, "activeJobsByLane": {"build": "t"}}, 15)["state"], "busy")
        self.assertEqual(bench.classify_main_status({**idle, "protocolVersion": 14}, 15)["state"], "unknown")
        self.assertEqual(bench.classify_main_status({"protocolVersion": 15}, 15)["state"], "unknown")
        self.assertEqual(bench.classify_main_status(None, 15)["state"], "unknown")

    def test_main_daemon_probe_is_passive(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = SimpleNamespace(pid_path=Path(tmp) / "pid", socket_path=Path(tmp) / "sock")
            cond = mock.Mock()
            cond.compute_paths.return_value = paths
            cond.read_pid.return_value = None
            cond.pid_alive.return_value = False
            cond.PROTOCOL_VERSION = 15
            probe = bench.HostProbe(cond, Path(tmp), {})
            self.assertEqual(probe.main_daemon()["state"], "idle")
            cond.request_daemon.assert_not_called()
            # Live pid but status fails: unknown, never idle.
            cond.read_pid.return_value = 123
            cond.pid_alive.return_value = True
            cond.request_daemon.side_effect = Exception("timeout")
            self.assertEqual(probe.main_daemon()["state"], "unknown")
            for call in cond.request_daemon.call_args_list:
                self.assertEqual(call.args[1], {"type": "status"})
            for name in ("ensure_daemon", "compatible_daemon_status_or_stop_idle_mismatch"):
                getattr(cond, name).assert_not_called()

    def test_slot_probe_free_busy_missing_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            existing = root / "global-heavy-0.lock"
            existing.write_text("")
            missing = root / "global-xctest-0.lock"
            result = bench.probe_slot_files([existing, missing])
            self.assertEqual(result["state"], "free")
            self.assertTrue(missing.exists())
            # Released: an independent descriptor can take the lock afterwards.
            with open(existing, "a+") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                busy = bench.probe_slot_files([existing, missing])
                self.assertEqual(busy["state"], "busy")
                self.assertEqual([s["state"] for s in busy["slots"]], ["busy", "free"])
            link = root / "global-heavy-1.lock"
            link.symlink_to(existing)
            self.assertEqual(bench.probe_slot_files([existing, link])["state"], "error")
            self.assertEqual(bench.probe_slot_files([])["state"], "error")

    def test_readiness_waits_then_admits_and_times_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = FakeClock()
            loads = iter([40.0, 40.0, 3.0])
            session = make_session(Path(tmp), probe=FakeProbe(load=lambda: next(loads)), clock=clock)
            ready = session.wait_ready()
            self.assertEqual(ready["polls"], 3)
            self.assertEqual(clock.sleeps, 2)
        for probe, blocker in (
            (FakeProbe(thermal="unknown"), "thermal_unknown"),
            (FakeProbe(thermal="fair"), "thermal_fair"),
            (FakeProbe(load=None), "load_unknown"),
            (FakeProbe(main={"state": "unknown"}), "main_daemon_unknown"),
            (FakeProbe(slots={"state": "busy"}), "slots_busy"),
        ):
            with tempfile.TemporaryDirectory() as tmp:
                clock = FakeClock()
                session = make_session(Path(tmp), probe=probe, clock=clock)
                with self.assertRaises(bench.StopRun) as raised:
                    session.wait_ready()
                self.assertEqual(raised.exception.reason, "readiness_timeout")
                self.assertIn(blocker, raised.exception.details["blockers"])
                self.assertGreaterEqual(clock.now, bench.READINESS_TIMEOUT_S)
                self.assertLessEqual(clock.now, bench.READINESS_TIMEOUT_S + bench.READINESS_POLL_S)


class RequestValidationTests(unittest.TestCase):
    def ns(self, **overrides):
        base = dict(instrumentation="full", dsym_mode="on", blocks=5, name="bench", scenarios="", ref="HEAD")
        base.update(overrides)
        return argparse.Namespace(**base)

    def test_defaults_are_the_selected_baseline(self):
        names = [recipe.name for recipe in bench.validate_request(self.ns(), {})]
        self.assertEqual(names, ["null-test", "test-body", "null-app", "app-body", "artifact"])

    def test_refusals(self):
        cases = [
            (self.ns(instrumentation=None), {}, "instrumentation full"),
            (self.ns(dsym_mode="off"), {}, "legacy-full-only"),
            (self.ns(dsym_mode="skip"), {}, "legacy-full-only"),
            (self.ns(), {"RPCE_DEBUG_DSYM": "on"}, "RPCE_DEBUG_DSYM"),
            (self.ns(), {"SWIFT_DRIVER_DSYMUTIL_EXEC": ""}, "SWIFT_DRIVER_DSYMUTIL_EXEC"),
            (self.ns(), {"REPOPROMPT_DEV_DAEMON_STATE_DIR": "/x"}, "own daemon state"),
            (self.ns(), {"RPCE_CONDUCTOR_TIMING": "off"}, "TIMING=off"),
            (self.ns(blocks=4), {}, "at least 5"),
            (self.ns(scenarios="app-body-package"), {}, "unsupported"),
            (self.ns(scenarios="null-package"), {}, "Step 12"),
            (self.ns(scenarios="null-test,diag-driver"), {}, "only scenario"),
            (self.ns(scenarios="diag-driver", calibration="x"), {}, "diagnostic-only"),
            (self.ns(), {"REPOPROMPT_DEV_XCTEST_DEADLINES": "0"}, "XCTEST_DEADLINES=0"),
            (self.ns(scenarios="nope"), {}, "unknown scenario"),
            (self.ns(scenarios="null-test,null-test"), {}, "twice"),
            (self.ns(name="../x"), {}, "--name"),
        ]
        for ns, env, text in cases:
            with self.subTest(text=text):
                with self.assertRaises(bench.HarnessError) as raised:
                    bench.validate_request(ns, env)
                self.assertIn(text, str(raised.exception))

    def test_off_is_rejected_before_any_mutation(self):
        with mock.patch.object(bench, "load_conductor", side_effect=AssertionError("mutation path reached")), \
                mock.patch.object(bench, "collect_host", side_effect=AssertionError("host probed")), \
                mock.patch.object(bench, "git_ok", side_effect=AssertionError("git used")):
            with mock.patch("sys.stderr"):
                code = bench.main(["run", "--instrumentation", "full", "--dsym-mode", "off"])
        self.assertEqual(code, bench.EXIT_HARNESS_FAILURE)

    def test_unknown_thermal_is_inconclusive_before_mutation(self):
        host = {"physicalCpu": 28, "logicalCpu": 28}
        with mock.patch.object(bench, "collect_host", return_value=host), \
                mock.patch.object(bench, "thermal_state", return_value="unknown"), \
                mock.patch.object(bench, "load_conductor", side_effect=AssertionError("mutation path reached")), \
                mock.patch("sys.stderr"):
            self.assertEqual(bench.main(["run", "--instrumentation", "full"]), bench.EXIT_INCONCLUSIVE)
        with mock.patch.object(bench, "collect_host", return_value={"physicalCpu": None, "logicalCpu": 28}), \
                mock.patch.object(bench, "load_conductor", side_effect=AssertionError("mutation path reached")), \
                mock.patch("sys.stderr"):
            self.assertEqual(bench.main(["run", "--instrumentation", "full"]), bench.EXIT_INCONCLUSIVE)

    def test_unexpected_reference_failure_is_refused_before_mutation(self):
        """S9-R2-01: the pre-mutation reference load maps any Exception to exit 3; interrupts propagate."""
        patches = dict(validate_request=[bench.SCENARIOS["null-test"]], load_fixture_manifest={},
                       collect_host=dict(FIXTURE_HOST), thermal_state="nominal",
                       resolve_main_repo=(Path("/nonexistent-main"), {}), git_ok="abc",
                       verify_probe_membership={}, check_capabilities={}, check_full_dsym_target=None,
                       load_conductor=object(),
                       benchmark_root=Path("/nonexistent-bench"))
        for error, expected in ((TypeError("unhashable"), bench.EXIT_HARNESS_FAILURE),
                                (KeyboardInterrupt(), KeyboardInterrupt), (SystemExit(9), SystemExit)):
            with self.subTest(error=type(error).__name__):
                with mock.patch.multiple(bench, **{name: mock.DEFAULT for name in patches}) as mocks, \
                        mock.patch.object(bench, "load_calibration_reference", side_effect=error), \
                        mock.patch.object(bench, "WorktreeOwner", side_effect=AssertionError("mutation path reached")), \
                        mock.patch("sys.stderr"):
                    for name, value in patches.items():
                        mocks[name].return_value = value
                    argv = ["run", "--instrumentation", "full", "--calibration", "ref"]
                    if isinstance(expected, int):
                        self.assertEqual(bench.main(argv), expected)
                    else:
                        with self.assertRaises(expected):
                            bench.main(argv)

    def test_job_environment_scrubs_policy_and_sets_all_destinations(self):
        environ = {"PATH": "/bin", "RPCE_DEBUG_DSYM": "on", "RPCE_ALLOW_UNKNOWN_FILTER": "1",
                   "REPOPROMPT_DEBUG_APP_BUNDLE": "/Applications/Live.app"}
        destinations = bench.scratch_destinations(Path("/tree"))
        env = bench.job_environment(environ, destinations)
        self.assertEqual(set(bench.DESTINATION_KEYS) - set(env), set())
        for key in bench.DESTINATION_KEYS:
            self.assertTrue(env[key].startswith("/tree/.build/rpce-benchmark/scratch/"), key)
        self.assertNotIn("RPCE_DEBUG_DSYM", env)
        self.assertNotIn("RPCE_ALLOW_UNKNOWN_FILTER", env)
        self.assertEqual(env["PATH"], "/bin")


class SubmissionAndWaitTests(unittest.TestCase):
    def recipe(self):
        return bench.SCENARIOS["null-test"]

    def test_ambiguous_submit_recovers_by_the_same_key_without_duplicating(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            client = session.clients[ON]
            client.submit_errors = ["accepted-then-lost"]
            result = session.run_job(ON, self.recipe(), "measured", {})
            self.assertEqual(len(client.submits), 1)
            self.assertTrue(result["valid"])
            rows = attempts(session.capture)
            intent = next(row for row in rows if row["phase"] == "intent")
            submitted = next(row for row in rows if row["phase"] == "submitted")
            self.assertTrue(submitted["recovered"])
            self.assertEqual(intent["requestKey"], submitted["requestKey"])
            self.assertLess(rows.index(intent), rows.index(next(r for r in rows if r["phase"] == "ambiguous_submit")))

    def test_unaccepted_submit_is_retried_with_the_same_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            client = session.clients[ON]
            client.submit_errors = ["never-accepted"]
            session.run_job(ON, self.recipe(), "measured", {})
            self.assertEqual(len(client.submits), 2)
            self.assertEqual(client.submits[0], client.submits[1])

    def test_unreachable_daemon_never_resubmits(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            client = session.clients[ON]
            client.submit_errors = ["never-accepted"]
            client.key_status_errors = ["could not contact daemon"] * 3
            with self.assertRaises(bench.HarnessError):
                session.run_job(ON, self.recipe(), "measured", {})
            self.assertEqual(len(client.submits), 1)

    def test_terminal_then_metrics_finalization_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            def plan(ticket):
                return [job_payload(ticket, state="running", metrics={"status": "running"}),
                        job_payload(ticket, state="running", metrics={"status": "running"}),
                        job_payload(ticket, metrics={"status": "pending"}),
                        job_payload(ticket)]
            clients = {arm: FakeClient(Path(tmp), arm, plan) for arm in bench.ARMS}
            clients[ON].persist = False
            session = make_session(Path(tmp), clients=clients)
            result = session.run_job(ON, self.recipe(), "measured", {})
            # Metrics never persisted within the bound: invalid, not fabricated.
            self.assertFalse(result["valid"])
            self.assertIn("metrics_not_finalized", result["invalidReasons"])
            self.assertGreaterEqual(session.clock.now, bench.METRICS_TIMEOUT_S)
            clients[ON].persist = True
            result = session.run_job(ON, self.recipe(), "measured", {})
            self.assertTrue(result["valid"], result["invalidReasons"])
            self.assertEqual(result["measures"]["primarySeconds"], 10.0)
            self.assertIsNotNone(result["rawTimings"])

    def test_terminal_timeout_cancels_the_exact_ticket_and_reprimes(self):
        with tempfile.TemporaryDirectory() as tmp:
            clients = {arm: FakeClient(Path(tmp), arm, lambda t: [job_payload(t, state="running")]) for arm in bench.ARMS}
            session = make_session(Path(tmp), clients=clients)
            result = session.run_job(ON, self.recipe(), "measured", {})
            self.assertEqual(clients[ON].cancels, [result["ticket"]])
            self.assertFalse(result["valid"])
            self.assertIn("terminal_timeout_canceled", result["invalidReasons"])
            self.assertIn(ON, session.needs_reprime)
            self.assertEqual(session.open_tickets, {})


class SampleEvaluationTests(unittest.TestCase):
    thermal_ok = {"samples": 3, "unknown": 0, "nonNominal": 0, "coverage": True}

    def evaluate(self, payload, metrics=None, finalized=True, thermal=None, recipe="null-test"):
        return bench.evaluate_sample(bench.SCENARIOS[recipe], payload, metrics if metrics is not None else payload["phaseMetrics"],
                                     finalized, thermal or self.thermal_ok, "D", "F")

    def test_valid_sample(self):
        result = self.evaluate(job_payload("t"))
        self.assertTrue(result["valid"], result["invalidReasons"])

    def test_invalid_reasons(self):
        cases = [
            (dict(payload=job_payload("t", state="failed", exit_code=1)), "job_failed_exit_1"),
            (dict(payload=job_payload("t", invalid=True)), "measurement_invalid"),
            (dict(payload=job_payload("t", digest="X")), "conductor_digest_mismatch"),
            (dict(payload=job_payload("t", args={"filter": "Other"})), "args_mismatch"),
            (dict(payload=job_payload("t", metrics=phase_metrics(primary_ns=None))), "primary_unavailable"),
            (dict(payload=job_payload("t", metrics=phase_metrics(status="partial"))), "metrics_status_partial"),
            (dict(payload=job_payload("t", metrics=phase_metrics(contended=True))), "contention_observed_heavy"),
            (dict(payload=job_payload("t", metrics=phase_metrics(contended=None))), "contention_unknown_heavy"),
            (dict(payload=job_payload("t", metrics=phase_metrics(slot="xctest"))), "slot_wait_missing_heavy"),
            (dict(payload=job_payload("t"), finalized=False), "metrics_not_finalized"),
            (dict(payload=job_payload("t"), thermal={"samples": 2, "unknown": 1, "nonNominal": 0, "coverage": True}), "thermal_unknown"),
            (dict(payload=job_payload("t"), thermal={"samples": 2, "unknown": 0, "nonNominal": 1, "coverage": True}), "thermal_non_nominal"),
            (dict(payload=job_payload("t"), thermal={"samples": 0, "unknown": 0, "nonNominal": 0, "coverage": False}), "thermal_unobserved"),
            (dict(payload=job_payload("t"), thermal={"samples": 4, "unknown": 0, "nonNominal": 0, "coverage": False}), "thermal_coverage_incomplete"),
            (dict(payload=job_payload("t"), thermal={"samples": 4, "unknown": 0, "nonNominal": 0}), "thermal_coverage_incomplete"),
            (dict(payload=job_payload("t", fingerprint="other")), "fingerprint_mismatch"),
            (dict(payload=job_payload("t", args={"filter": bench.PROBE_SUITE, "benchmarkDriverDiagnostics": True})), "args_mismatch"),
        ]
        for kwargs, reason in cases:
            with self.subTest(reason=reason):
                result = self.evaluate(**kwargs)
                self.assertFalse(result["valid"])
                self.assertIn(reason, result["invalidReasons"])

    def test_missing_primary_stays_null(self):
        result = self.evaluate(job_payload("t", metrics=phase_metrics(primary_ns=None)))
        self.assertIsNone(result["measures"]["primarySeconds"])

    def test_artifact_requires_the_xctest_slot(self):
        payload = job_payload("t", operation="test-artifact", metrics=phase_metrics(slot="xctest"))
        self.assertTrue(self.evaluate(payload, recipe="artifact")["valid"])

    def test_thermal_summary(self):
        summary = bench.thermal_summary([(0.0, "nominal"), (1.0, "fair"), (3.0, "unknown")])
        self.assertEqual((summary["samples"], summary["unknown"], summary["nonNominal"], summary["maxGapSeconds"]), (3, 1, 1, 2.0))


class StatisticsAndRetryTests(unittest.TestCase):
    def test_block_order_is_balanced_and_alternates(self):
        self.assertEqual(bench.block_order(0), (ON, SKIP, SKIP, ON))
        self.assertEqual(bench.block_order(1), (SKIP, ON, ON, SKIP))

    def test_pairs_first_with_first_and_second_with_second(self):
        samples = [{"arm": arm, "id": index} for index, arm in enumerate(bench.block_order(0))]
        pairs = bench.block_pairs(samples)
        self.assertEqual([(a["id"], b["id"]) for a, b in pairs], [(0, 1), (3, 2)])
        with self.assertRaises(bench.HarnessError):
            bench.block_pairs(samples[:3])

    def test_calibrate_qualifies_and_rejects(self):
        def block(on, skip):
            return [{"arm": arm, "measures": {"primarySeconds": on if arm == ON else skip}} for arm in bench.block_order(0)]
        self.assertEqual(bench.calibrate([block(10.0, 10.01)] * 5).verdict, "qualified")
        self.assertEqual(bench.calibrate([block(10.0, 11.0)] * 5).verdict, "inconclusive")
        self.assertEqual(bench.calibrate([block(10.0, 10.0)] * 4).reasons, ("insufficient_pairs",))

    def fake_session(self, tmp, validity):
        session = make_session(Path(tmp))
        sequence = iter(validity)
        counter = {"n": 0}

        def run_job(arm, recipe, kind, context):
            counter["n"] += 1
            valid = next(sequence) if kind == "measured" else True
            return {"attemptId": f"{counter['n']:05d}", "arm": arm, "valid": valid, "state": "completed", "exitCode": 0,
                    "load1": 2.0, "measures": {"primarySeconds": 10.0}}

        session.run_job = run_job
        return session

    def test_position_retries_then_whole_block_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            # Position 0 valid, position 1 invalid four times -> block discarded.
            session = self.fake_session(tmp, [True, False, False, False, False])
            self.assertIsNone(session.run_block(bench.SCENARIOS["null-test"], 0, 1))
            self.assertEqual(session.measured_attempts, 5)
            discarded = [row for row in attempts(session.capture) if row["phase"] == "block_discarded"]
            self.assertEqual(discarded[0]["reason"], "position_retries_exhausted")
            # The valid member is listed as discarded-valid, not relabeled invalid.
            self.assertEqual(discarded[0]["discardedValidAttemptIds"], ["00001"])

    def test_invalid_fraction_stops_immediately_mid_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = self.fake_session(tmp, [True] * 17 + [False] * 10)
            recipe = bench.SCENARIOS["null-test"]
            with self.assertRaises(bench.StopRun) as raised:
                for index in range(10):
                    session.run_block(recipe, index, index + 1)
            self.assertEqual(raised.exception.reason, "invalid_fraction_exceeded")
            # 17 valid + 3 invalid = 20 attempts at 15% invalid.
            self.assertEqual((session.measured_attempts, session.invalid_attempts), (20, 3))

    def test_invalid_fraction_below_minimum_attempts_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = self.fake_session(tmp, [False, True, True, True, True])
            self.assertIsNotNone(session.run_block(bench.SCENARIOS["null-test"], 0, 1))

    def test_scenario_extends_once_then_reports_inconclusive(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            values = {ON: 10.0, SKIP: 11.0}

            def run_job(arm, recipe, kind, context):
                return {"attemptId": "x", "arm": arm, "valid": True, "state": "completed", "exitCode": 0, "load1": 2.0,
                        "measures": {"primarySeconds": values[arm]}}

            session.run_job = run_job
            result = session.run_scenario(bench.SCENARIOS["null-test"])
            self.assertEqual(result["verdict"], "inconclusive")
            self.assertTrue(result["extended"])
            self.assertEqual(result["blocksRetained"], bench.EXTENDED_BLOCKS)
            self.assertEqual([e["blocks"] for e in result["evaluations"]], [5, 10])

    def test_scenario_qualifies_without_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))

            def run_job(arm, recipe, kind, context):
                return {"attemptId": "x", "arm": arm, "valid": True, "state": "completed", "exitCode": 0, "load1": 3.5,
                        "measures": {"primarySeconds": 10.0}}

            session.run_job = run_job
            result = session.run_scenario(bench.SCENARIOS["null-test"])
            self.assertEqual((result["verdict"], result["extended"], result["blocksRetained"]), ("qualified", False, 5))
            self.assertEqual(result["retainedLoad1Range"], [3.5, 3.5])

    def test_primer_failures_are_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            calls = []

            def run_job(arm, recipe, kind, context):
                calls.append(kind)
                return {"attemptId": "x", "arm": arm, "valid": False, "state": "failed", "exitCode": 1, "load1": 1.0,
                        "measures": {"primarySeconds": None}}

            session.run_job = run_job
            with self.assertRaises(bench.HarnessError):
                session.prime(bench.SCENARIOS["null-test"])
            self.assertEqual(len(calls), 1 + bench.PRIMER_RETRIES)


HASH_A = "a" * 64
HASH_C = "c" * 64
FIXTURE_HOST = {"physicalCpu": 28, "logicalCpu": 28, "model": "Mac15,14", "cpuBrand": "Apple M3 Ultra",
                "memoryBytes": 1, "arch": "arm64", "osVersion": "26.7", "osBuild": "25G229",
                "developerDir": "/dev", "swiftVersion": "6.3.1", "sdkVersion": "26.4", "sdkPath": "/sdk"}
# The harness inventory a current capture records (static runner imports plus debug_app_process).
FIXTURE_HARNESS_FILES = tuple(dict.fromkeys((*bench.HARNESS_FILES, *bench.RUNNER_IMPORTED_FILES,
                                             "Scripts/debug_app_process.py")))


def env_digests(**values):
    """The complete inventory a current runner records: its conductor's passthrough keys plus the extras."""
    base = {key: None for key in (*bench.load_conductor().OperationRegistry.PASSTHROUGH_ENV_KEYS,
                                  *bench.ENV_CLASS_EXTRA_KEYS)}
    base.update({"PATH": "/usr/bin", "REPOPROMPT_DEBUG_APP_ROOT": "<tree>/.build/x",
                 "REPOPROMPT_DEBUG_APP_BUNDLE": "<tree>/.build/x/RepoPrompt.app",
                 "REPOPROMPT_DEBUG_CLI_INSTALL_PATH": "<tree>/.build/cli"})
    base.update(values)
    return {key: bench.env_value_digest(key, value) for key, value in base.items()}


def arm_inventory(digests):
    return {"runtimeFileSha256": {rel: HASH_A for rel in bench.RUNTIME_FILES}, "environmentDigests": digests,
            "environmentKeys": sorted(digests), "environmentClass": bench.sha256_bytes(bench.canonical_json(digests)),
            "expectedConductorDigest": "sha256:d"}


def fixture_thermal(start):
    """Real observer bookkeeping on a scripted clock: readings before submit and after terminal."""
    times = iter([start, start + 1.0, start + 2.0, start + 3.0])
    observer = bench.ThermalObserver(lambda: "nominal", lambda: next(times))
    observer._read()
    observer.mark("submitStart", start + 0.5)
    observer._read()
    observer._read()
    observer.mark("terminalObserved", start + 2.5)
    observer._read()
    summary = observer.finish()
    return observer.raw(), summary


def fixture_sample(directory, run_id, recipe, aid, arm, ticket, primary_ns, load1, cap, coverage=True, raw=True,
                   block=0, position=0, prefix=None):
    """One result row plus raw status/terminal/timings/thermal files that reproduce its evaluation."""
    segments = []
    if recipe.work.required:
        segments = [{"modules": {name: {"compiledFiles": 1, "exact": True} for name in recipe.work.compiled_modules},
                     "linkedProducts": list(recipe.work.linked_products), "compiledFilesExact": True}]
    pm = phase_metrics(primary_ns=primary_ns, slot=recipe.slots[0])
    pm["segments"] = segments
    fingerprint = f"fp-{recipe.name}-{arm}"
    payload = job_payload(ticket, digest="sha256:d", metrics=pm, operation=recipe.operation,
                          args=dict(recipe.expected_args), fingerprint=fingerprint)
    payload["requestKey"] = f"rpce-swift-bench-{prefix or run_id}-{aid}"
    thermal_raw, thermal = fixture_thermal(100.0 * int(aid))
    evaluation = bench.evaluate_sample(recipe, payload, pm, True, thermal, "sha256:d", fingerprint)
    assert evaluation["valid"], evaluation
    if not coverage:
        thermal = dict(thermal, coverage=False, coverageReasons=["gap_exceeded"])  # forged summary
    files = {}
    for kind, body in (("status", payload), ("terminal", payload),
                       ("timings", {"schema": 1, "ticket": ticket, "phaseMetrics": pm}),
                       ("thermal", {**thermal_raw, "summary": thermal})):
        rel = f"raw/{aid}-{arm}.{kind}.json"
        if raw:
            (directory / rel).write_text(json.dumps(body))
        files["raw" + kind.capitalize()] = rel
    measures = dict(evaluation["measures"])
    measures["clientObserved"] = {"interval": bench.SECONDARY_CLIENT_INTERVAL, "seconds": primary_ns / 1e9 + 1.0}
    return {"phase": "result", "scenario": recipe.name, "kind": "measured", "attemptId": aid,
            "operation": recipe.operation, "cliArgs": list(recipe.cli_args),
            "requestKey": payload["requestKey"], "arm": arm, "ticket": ticket, "block": block,
            "position": position, "retry": 0, "state": "completed", "exitCode": 0, "conductorDigest": "sha256:d",
            "fingerprint": fingerprint, "load1": load1, "admissionCap": cap, "thermal": thermal, "valid": True,
            "invalidReasons": [], "measures": measures, **files}


def make_reference(root: Path, lineage: str):
    """A fresh, evidence-backed A/A calibration capture named after its lineage."""
    name = f"ref-{lineage}"
    if not (root / name).exists():
        make_capture(root, name, 5.0, 5.0, run_id=lineage)
    directory = root / name
    calibration = json.loads((directory / "calibration.json").read_text())
    return {"captureDir": str(directory), "runId": calibration["runId"],
            "pinnedLoad1Threshold": calibration["pinnedLoad1Threshold"], "lineageRoot": calibration["lineageRoot"],
            "qualifiedScenarios": calibration["qualifiedScenarios"],
            "calibrationSha256": bench.sha256_file(directory / "calibration.json")}


def make_capture(root: Path, name: str, on: float, skip: float, *, run_id=None, tickets=None, lineage="L",
                 treatment="none", skip_env=None, cleanup_ok=True, verdict=None, schema=2, meta_drop=(),
                 host_drop=(), coverage=True, raw=True, matches_commit=True, scenario="null-test", meta_overrides=None,
                 scenarios=None, reference=None, admission_cap=None, harness_drop=(), blocks=5):
    """A schema-2 capture whose summaries are reproducible from its retained rows and raw files."""
    directory = root / name
    (directory / "raw").mkdir(parents=True)
    run_id = run_id or f"run-{name}"
    prefix = tickets or name
    names = list(scenarios or [scenario])
    if treatment != "none" and reference is None:
        reference = make_reference(root, lineage)
    physical = FIXTURE_HOST["physicalCpu"]
    cap = admission_cap if admission_cap is not None else (
        float(physical) if reference is None else min(reference["pinnedLoad1Threshold"], float(physical)))
    rows, scenario_results, seq = [], {}, 0
    for scenario_name in names:
        recipe = bench.SCENARIOS[scenario_name]
        pairs, observations, retained_ids = [], [], []
        for block in range(blocks):
            order = bench.block_order(block)
            seen = {ON: 0, SKIP: 0}
            samples = []
            for position, arm in enumerate(order):
                seq += 1
                aid = f"{seq:05d}"
                index = block * 2 + seen[arm]
                seen[arm] += 1
                value = (on if arm == ON else skip) + 0.001 * index
                load1 = 4.0 + 0.01 * seq
                samples.append(fixture_sample(directory, run_id, recipe, aid, arm, f"{prefix}-{aid}",
                                              int(round(value * 1e9)), load1, cap, coverage, raw, block, position,
                                              prefix=None))
            rows.extend(samples)
            block_pairs = bench.block_pairs(samples)
            pairs.extend([first["measures"]["primarySeconds"], second["measures"]["primarySeconds"]]
                         for first, second in block_pairs)
            observations.append([{"runId": run_id, "attemptId": s["attemptId"], "arm": s["arm"], "ticket": s["ticket"],
                                  "requestKey": s["requestKey"], "primarySeconds": s["measures"]["primarySeconds"],
                                  "clientSeconds": s["measures"]["clientObserved"]["seconds"], "load1": s["load1"]}
                                 for pair in block_pairs for s in pair])
            retained_ids.append([s["attemptId"] for s in samples])
        entry = {"scenario": scenario_name, "statisticalRole": recipe.role, "pairs": pairs,
                 "retainedObservations": observations, "retainedAttemptIds": retained_ids, "blocksRetained": blocks,
                 "retainedLoad1Range": [min(r["load1"] for r in rows if r["scenario"] == scenario_name),
                                        max(r["load1"] for r in rows if r["scenario"] == scenario_name)]}
        if recipe.role == bench.ROLE_GATING:
            comparison = bench.metrics.aa_equivalence(
                [p[0] for p in pairs], [p[1] for p in pairs], bound_abs=bench.AA_BOUND_ABS_S,
                bound_rel=bench.AA_BOUND_REL, min_pairs=bench.MIN_PAIRS, confidence=bench.CONFIDENCE,
                iterations=bench.BOOTSTRAP_ITERATIONS, seed=bench.BOOTSTRAP_SEED, block_size=bench.PAIR_BLOCK_SIZE)
            entry.update(verdict=comparison.verdict, comparison=comparison.to_json())
        else:
            entry.update(verdict="recorded", comparison=None)
        if verdict is not None and scenario_name == names[0]:
            entry["verdict"] = verdict  # forged summary verdict
        scenario_results[scenario_name] = entry
    meta = {}
    for scenario_name in names:
        recipe = bench.SCENARIOS[scenario_name]
        scenario_meta = {key: f"m-{key}" for key in bench.MANDATORY_META_KEYS if key not in meta_drop}
        scenario_meta.update(statisticalRole=recipe.role, cacheClass=recipe.cache_class)
        scenario_meta.update(meta_overrides or {})
        meta[scenario_name] = scenario_meta
    host = {key: value for key, value in FIXTURE_HOST.items() if key not in host_drop}
    harness_files = {rel: {"runner": bench.sha256_file(bench.REPO_ROOT / rel),
                           "commit": bench.sha256_file(bench.REPO_ROOT / rel), "match": True}
                     for rel in FIXTURE_HARNESS_FILES if rel not in harness_drop}
    if not matches_commit:
        first = sorted(harness_files)[0]
        harness_files[first] = {"runner": HASH_A, "commit": HASH_C, "match": False}
    manifest = {"schema": schema, "runId": run_id, "comparisonMeta": meta, "host": host,
                "harness": {"harnessVersion": bench.HARNESS_VERSION, "files": harness_files,
                            "matchesCommit": matches_commit},
                "lineageRoot": run_id if reference is None else reference["lineageRoot"], "treatment": treatment,
                "calibrationReference": reference,
                "admission": {"effectiveLoad1Cap": cap, "physicalCpu": physical, "logicalCpu": physical},
                "arms": {ON: arm_inventory(env_digests()), SKIP: arm_inventory(env_digests(**(skip_env or {})))},
                "scenarios": names, "statisticalRoles": {n: bench.SCENARIOS[n].role for n in names}}
    passed = [n for n, e in scenario_results.items()
              if bench.SCENARIOS[n].role == bench.ROLE_GATING and e["verdict"] == "qualified"]
    loads = [r["load1"] for r in rows if r["scenario"] in passed]
    calibration = {"schema": schema, "runId": run_id, "lineageRoot": manifest["lineageRoot"], "reference": reference,
                   "qualifiedScenarios": passed,
                   "pinnedLoad1Threshold": (max(loads) if loads else None) if reference is None
                   else reference["pinnedLoad1Threshold"],
                   "effectiveLoad1Cap": cap, "physicalCpu": physical, "reusable": bool(passed) and cleanup_ok,
                   "diagnosticOnly": not any(bench.SCENARIOS[n].role == bench.ROLE_GATING for n in names)}
    result = {"schema": schema, "runId": run_id, "exitCode": 0, "cleanup": {"ok": cleanup_ok},
              "scenarios": scenario_results, "calibration": calibration}
    ownership = {"schema": 2, "runId": run_id, "state": "cleaned" if cleanup_ok else "cleanup_failed",
                 "arms": {arm: {"arm": arm, "cleanup": "removed" if cleanup_ok else "daemonStopped"} for arm in bench.ARMS}}
    (directory / "manifest.json").write_text(json.dumps(manifest))
    (directory / "result.json").write_text(json.dumps(result))
    (directory / "calibration.json").write_text(json.dumps(calibration))
    (directory / "ownership.json").write_text(json.dumps(ownership))
    (directory / "attempts.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
    return str(directory)


def edit_json(path, mutate):
    path = Path(path)
    data = json.loads(path.read_text())
    mutate(data)
    path.write_text(json.dumps(data))


DSYM_TREATMENT = {"env": [{"key": "RPCE_DEBUG_DSYM", "before": None, "after": "off", "reason": "dSYM skip"}]}


class CompareTests(unittest.TestCase):
    """Paired only within one capture; confirmation by a distinct capture's own pairs (OD23)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.treatment = self.root / "treatment.json"
        self.treatment.write_text(json.dumps(DSYM_TREATMENT))

    def tearDown(self):
        self.tmp.cleanup()

    def treated(self, name, on, skip, **kw):
        return make_capture(self.root, name, on, skip, treatment="declared", skip_env={"RPCE_DEBUG_DSYM": "off"}, **kw)

    def run_compare(self, base, cand, *extra, treatment=True):
        args = ["compare", "--baseline", base, "--candidate", cand, *extra]
        if treatment:
            args += ["--treatment-manifest", str(self.treatment)]
        report = self.root / f"report-{len(list(self.root.glob('report-*')))}.json"
        with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            code = bench.main([*args, "--report", str(report)])
        return code, json.loads(report.read_text()) if report.exists() else None

    def test_aa_capture_arms_qualify(self):
        cap = make_capture(self.root, "aa", 10.0, 10.0)
        code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
        self.assertEqual(code, 0, report)

    def test_first_batch_keeps_both_class_floors(self):
        # +4% and 0.8 s: under the 5% floor (threshold 1.0 s) -> qualified, never a regression.
        rel = self.treated("rel", 20.0, 20.8)
        self.assertEqual(self.run_compare(f"{rel}#{ON}", f"{rel}#{SKIP}")[0], 0)
        # +8% but 0.4 s: under the 0.5 s Swift floor -> never a regression.
        small = self.treated("small", 5.0, 5.4)
        self.assertEqual(self.run_compare(f"{small}#{ON}", f"{small}#{SKIP}")[0], 0)
        # +12% and 0.6 s: both exceeded but unconfirmed -> inconclusive.
        big = self.treated("big", 5.0, 5.6)
        code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertEqual(report["scenarios"]["null-test"]["primary"]["verdict"], "regression")
        self.assertIn("missing_confirming_batch", report["scenarios"]["null-test"]["confirmation"]["reasons"])

    def test_confirmation_needs_ci_above_zero_not_a_repeated_floor(self):
        big = self.treated("big", 5.0, 5.6)
        # Confirming batch +0.2 s (below both floors) with its paired CI entirely above zero: confirmed.
        modest = self.treated("modest", 5.0, 5.2)
        code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", "--confirm-baseline", f"{modest}#{ON}",
                                        "--confirm-candidate", f"{modest}#{SKIP}")
        self.assertEqual(code, 1, report)
        self.assertGreater(report["scenarios"]["null-test"]["confirmation"]["comparison"]["ciLow"], 0)
        flat = self.treated("flat", 5.0, 5.0)
        code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", "--confirm-baseline", f"{flat}#{ON}",
                                        "--confirm-candidate", f"{flat}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertIn("confirming_ci_not_above_zero", report["scenarios"]["null-test"]["confirmation"]["reasons"])

    def test_alias_copy_reuse_and_lineage_never_confirm(self):
        big = self.treated("big", 5.0, 5.6)
        copy = self.root / "copy"
        shutil.copytree(big, copy)
        reused = self.treated("reused", 5.0, 5.6, tickets="big", run_id="run-other")
        other_lineage = self.treated("lineage", 5.0, 5.6, lineage="L2")
        cold = self.treated("cold-mix", 5.0, 5.6, meta_overrides={"cacheClass": "cold"})
        cases = [
            (cold, "metadata_differs:cacheClass"),
            (big, "same_capture_alias"),
            (str(copy), "same_run_id_copy"),
            (reused, "shared_observations"),
            (other_lineage, "metadata_differs"),
        ]
        for confirm, reason in cases:
            with self.subTest(reason=reason):
                code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", "--confirm-baseline",
                                                f"{confirm}#{ON}", "--confirm-candidate", f"{confirm}#{SKIP}")
                self.assertEqual(code, 2)
                reasons = report["scenarios"]["null-test"]["confirmation"]["reasons"]
                self.assertTrue(any(reason in r for r in reasons), reasons)
        # Swapped arm roles in the confirming batch are not the same comparison.
        code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", "--confirm-baseline", f"{copy}#{SKIP}",
                                        "--confirm-candidate", f"{copy}#{ON}")
        self.assertEqual(code, 2)

    def test_cross_capture_index_alignment_is_inconclusive_not_paired(self):
        a = self.treated("a", 5.0, 5.0)
        b = self.treated("b", 5.6, 5.6)
        code, report = self.run_compare(f"{a}#{ON}", f"{b}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertIn("cross_capture_not_paired", report["scenarios"]["null-test"]["reasons"][0])

    def test_environment_class_allows_only_exact_declared_keys(self):
        undeclared = make_capture(self.root, "undeclared", 5.0, 5.0, treatment="declared",
                                  skip_env={"RPCE_DEBUG_DSYM": "off", "PATH": "/opt/bin"})
        code, report = self.run_compare(f"{undeclared}#{ON}", f"{undeclared}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertIn("incompatible:environmentClass", report["scenarios"]["null-test"]["primary"]["reasons"])
        wrong = self.treated("wrong", 5.0, 5.0)
        self.treatment.write_text(json.dumps({"env": [{"key": "RPCE_DEBUG_DSYM", "before": None, "after": "skip",
                                                       "reason": "dSYM skip"}]}))
        code, report = self.run_compare(f"{wrong}#{ON}", f"{wrong}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertIn("treatment_mismatch", report["scenarios"]["null-test"]["reasons"][0])

    def test_runtime_digest_class_requires_an_exact_treatment_manifest(self):
        cap = make_capture(self.root, "paths", 5.0, 5.0)
        manifest = json.loads((Path(cap) / "manifest.json").read_text())
        manifest["arms"][SKIP]["runtimeFileSha256"]["Scripts/canonical_swift.sh"] = HASH_C
        (Path(cap) / "manifest.json").write_text(json.dumps(manifest))
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)[0], 2)
        self.treatment.write_text(json.dumps({"paths": [{"path": "Scripts/canonical_swift.sh", "before": HASH_A,
                                                         "after": HASH_C, "reason": "dsym switch"}]}))
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}")[0], 0)

    def test_malformed_inputs_are_harness_failures(self):
        cap = make_capture(self.root, "cap", 5.0, 5.0)
        self.assertEqual(self.run_compare(cap, f"{cap}#{SKIP}", treatment=False)[0], 3)  # arm required
        self.assertEqual(self.run_compare(f"{cap}#ab-other", f"{cap}#{SKIP}", treatment=False)[0], 3)
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{ON}", treatment=False)[0], 3)
        self.assertEqual(self.run_compare(f"{self.root / 'missing'}#{ON}", f"{cap}#{SKIP}", treatment=False)[0], 3)
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", "--scenarios", "nope",
                                          treatment=False)[0], 3)
        for bad in ({"paths": [], "extra": 1},
                    {"env": [{"key": "RPCE_DEBUG_DSYM", "before": None, "after": "off", "reason": "x"}] * 2},
                    {"paths": [{"path": "Scripts/unknown.py", "before": "a", "after": "b", "reason": "x"}]},
                    {"paths": [{"path": "Scripts/conductor.py", "before": "a", "after": "b", "reason": "x", "x": 1}]},
                    {"env": [{"key": "RPCE_DEBUG_DSYM", "before": "on", "after": "on", "reason": "x"}]},
                    {"env": [{"key": "RPCE_DEBUG_DSYM", "before": None, "after": "off", "reason": ""}]}):
            with self.subTest(bad=bad):
                self.treatment.write_text(json.dumps(bad))
                self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}")[0], 3)
        broken = self.root / "broken"
        broken.mkdir()
        (broken / "manifest.json").write_text("{not json")
        self.assertEqual(self.run_compare(f"{broken}#{ON}", f"{broken}#{SKIP}", treatment=False)[0], 3)

    def test_legacy_v1_captures_are_ineligible(self):
        v1 = make_capture(self.root, "v1", 5.0, 5.0, schema=1)
        code, report = self.run_compare(f"{v1}#{ON}", f"{v1}#{SKIP}", treatment=False)
        self.assertEqual(code, 2)
        self.assertEqual(report["ineligible"], ["legacy_capture_schema_1"])

    def test_eligibility_reasons(self):
        """Well-formed evidence that cannot support a verdict: exit 2 with the reason."""
        cases = [
            (dict(cleanup_ok=False), "cleanup_incomplete"),
            (dict(skip=6.0), "aa_not_qualified"),  # the recomputed A/A misses its bound
            (dict(raw=False), "retained_raw_missing"),
            (dict(matches_commit=False), "harness_not_at_commit"),
            (dict(meta_drop=("toolchain", "testScope")), "metadata_missing:toolchain,testScope"),
            (dict(host_drop=("osBuild",)), "host.osBuild"),
            (dict(blocks=4), "insufficient_pairs"),
            (dict(harness_drop=("Scripts/debug_app_process.py",)),
             "harness_inventory_incomplete:Scripts/debug_app_process.py"),
        ]
        for index, (kwargs, reason) in enumerate(cases):
            with self.subTest(reason=reason):
                skip = kwargs.pop("skip", 5.0)
                cap = make_capture(self.root, f"e{index}", 5.0, skip, **kwargs)
                code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", "--scenarios", "null-test",
                                                treatment=False)
                self.assertEqual(code, 2, report)
                self.assertTrue(any(reason in r for r in report["scenarios"]["null-test"]["reasons"]),
                                report["scenarios"]["null-test"])

    def assert_integrity_failure(self, cap, text, scenario="null-test"):
        code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
        self.assertEqual(code, 3, report)
        blob = json.dumps(report)
        self.assertIn(text, blob, report)
        return report

    def test_edited_pairs_never_change_the_verdict(self):
        """S9-R0-04/S9-R1-05: pairs are reconstructed from retained attempts, never trusted from result.json."""
        cap = make_capture(self.root, "pairs", 5.0, 5.0)
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)[0], 0)
        edit_json(Path(cap) / "result.json",
                  lambda r: [pair.__setitem__(1, pair[1] + 1.0) for pair in r["scenarios"]["null-test"]["pairs"]])
        report = self.assert_integrity_failure(cap, "recorded pairs")
        self.assertEqual(report["scenarios"]["null-test"]["verdict"], "harness_failure")
        negative = make_capture(self.root, "negative", 5.0, 5.0)
        edit_json(Path(negative) / "result.json",
                  lambda r: r["scenarios"]["null-test"]["pairs"][3].__setitem__(1, -1.0))
        self.assert_integrity_failure(negative, "recorded pairs")

    def test_duplicated_observations_cannot_satisfy_the_sample_count(self):
        cap = make_capture(self.root, "dup", 5.0, 5.0)

        def duplicate(result):
            entry = result["scenarios"]["null-test"]
            entry["retainedObservations"][1] = entry["retainedObservations"][0]
            entry["retainedAttemptIds"][1] = entry["retainedAttemptIds"][0]
            entry["pairs"][2:4] = entry["pairs"][0:2]
        edit_json(Path(cap) / "result.json", duplicate)
        self.assert_integrity_failure(cap, "duplicate")

    def test_raw_files_must_reproduce_their_rows(self):
        for kind in ("status", "terminal", "thermal", "timings"):
            with self.subTest(kind=kind):
                cap = make_capture(self.root, f"raw-{kind}", 5.0, 5.0)
                for path in (Path(cap) / "raw").glob(f"*.{kind}.json"):
                    path.write_text("{}")
                self.assert_integrity_failure(cap, "raw/")
        forged = make_capture(self.root, "forged-thermal", 5.0, 5.0, coverage=False)
        self.assert_integrity_failure(forged, "thermal")
        moved = make_capture(self.root, "moved", 5.0, 5.0)
        rows = [json.loads(line) for line in (Path(moved) / "attempts.jsonl").read_text().splitlines()]
        rows[1]["rawStatus"] = rows[0]["rawStatus"]  # two rows citing one raw file
        (Path(moved) / "attempts.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        self.assert_integrity_failure(moved, "rawStatus")

    def test_provenance_and_environment_inventories_must_be_complete(self):
        missing = make_capture(self.root, "no-conductor", 5.0, 5.0, harness_drop=("Scripts/conductor.py",))
        code, report = self.run_compare(f"{missing}#{ON}", f"{missing}#{SKIP}", treatment=False)
        self.assertEqual(code, 2)
        self.assertIn("harness_inventory_incomplete:Scripts/conductor.py", report["scenarios"]["null-test"]["reasons"])
        unhashed = make_capture(self.root, "unhashed", 5.0, 5.0)
        edit_json(Path(unhashed) / "manifest.json",
                  lambda m: m["harness"]["files"].__setitem__("Scripts/conductor.py", {"match": True}))
        self.assert_integrity_failure(unhashed, "harness")
        env = make_capture(self.root, "env", 5.0, 5.0)

        def drop_policy_key(manifest):
            for arm in bench.ARMS:
                digests = manifest["arms"][arm]["environmentDigests"]
                digests.pop("RPCE_DEBUG_DSYM")
                manifest["arms"][arm].update(arm_inventory(digests))
        edit_json(Path(env) / "manifest.json", drop_policy_key)
        code, report = self.run_compare(f"{env}#{ON}", f"{env}#{SKIP}", treatment=False)
        self.assertEqual(code, 2)
        self.assertTrue(any("environment_inventory_incomplete" in r for r in report["scenarios"]["null-test"]["reasons"]))
        forged = make_capture(self.root, "env-class", 5.0, 5.0)
        edit_json(Path(forged) / "manifest.json",
                  lambda m: m["arms"][SKIP].__setitem__("environmentClass", HASH_C))
        self.assert_integrity_failure(forged, "environmentClass")

    def test_environment_inventory_is_the_recorded_conductors_passthrough_set(self):
        """S9-R0-04: completeness is judged against the passthrough keys of the conductor bytes the capture
        recorded, never against the capture's own key list."""
        complete = make_capture(self.root, "env-complete", 5.0, 5.0)
        self.assertEqual(self.run_compare(f"{complete}#{ON}", f"{complete}#{SKIP}", treatment=False)[0], 0)

        def rewrite(path, change):
            def mutate(manifest):
                for arm in bench.ARMS:
                    digests = manifest["arms"][arm]["environmentDigests"]
                    change(digests)
                    manifest["arms"][arm].update(arm_inventory(digests))  # keys and class stay self-consistent
            edit_json(Path(path) / "manifest.json", mutate)

        for index, key in enumerate(("REPOPROMPT_SENTRY_DSN", "SIGN_IDENTITY", "REPOPROMPT_DEV_XCTEST_DEADLINES",
                                     "SDKROOT")):
            with self.subTest(dropped=key):
                self.assertIn(key, bench.load_conductor().OperationRegistry.PASSTHROUGH_ENV_KEYS)
                cap = make_capture(self.root, f"env-drop-{index}", 5.0, 5.0)
                rewrite(cap, lambda digests: digests.pop(key))
                code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
                self.assertEqual(code, 2, report)
                reasons = report["scenarios"]["null-test"]["reasons"]
                for arm in bench.ARMS:
                    self.assertIn(f"environment_inventory_incomplete:{arm}:{key}", reasons)
        extra = make_capture(self.root, "env-extra", 5.0, 5.0)
        rewrite(extra, lambda digests: digests.__setitem__("UNLISTED_KEY", None))
        code, report = self.run_compare(f"{extra}#{ON}", f"{extra}#{SKIP}", treatment=False)
        self.assertEqual(code, 2, report)
        self.assertIn(f"environment_inventory_unexpected:{ON}:UNLISTED_KEY", report["scenarios"]["null-test"]["reasons"])
        # Conductor bytes the validator cannot reproduce leave the expected inventory unestablished.
        foreign = make_capture(self.root, "env-foreign-conductor", 5.0, 5.0)
        edit_json(Path(foreign) / "manifest.json", lambda m: m["harness"]["files"].__setitem__(
            "Scripts/conductor.py", {"runner": HASH_C, "commit": HASH_C, "match": True}))
        code, report = self.run_compare(f"{foreign}#{ON}", f"{foreign}#{SKIP}", treatment=False)
        self.assertEqual(code, 2, report)
        self.assertIn("environment_inventory_unverifiable:conductor_bytes_differ",
                      report["scenarios"]["null-test"]["reasons"])

    def test_nested_malformed_structures_are_harness_failures(self):
        mutations = {
            "arms-list": ("manifest.json", lambda m: m.__setitem__("arms", [])),
            "harness-files-list": ("manifest.json", lambda m: m["harness"].__setitem__("files", [])),
            "meta-string": ("manifest.json", lambda m: m["comparisonMeta"].__setitem__("null-test", "x")),
            "observation-ints": ("result.json", lambda r: r["scenarios"]["null-test"].__setitem__(
                "retainedObservations", [[1, 2, 3, 4]] * 5)),
            "pairs-string": ("result.json", lambda r: r["scenarios"]["null-test"].__setitem__("pairs", "x")),
            "scenario-list": ("result.json", lambda r: r.__setitem__("scenarios", [])),
            "cleanup-string": ("result.json", lambda r: r.__setitem__("cleanup", "ok")),
        }
        for name, (file_name, mutate) in mutations.items():
            with self.subTest(case=name):
                cap = make_capture(self.root, f"bad-{name}", 5.0, 5.0)
                edit_json(Path(cap) / file_name, mutate)
                code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", "--scenarios", "null-test",
                                                treatment=False)
                self.assertEqual(code, 3, report)
        rows = make_capture(self.root, "bad-rows", 5.0, 5.0)
        with open(Path(rows) / "attempts.jsonl", "a") as handle:
            handle.write("[1, 2]\n")
        self.assertEqual(self.run_compare(f"{rows}#{ON}", f"{rows}#{SKIP}", treatment=False)[0], 3)

    def test_admissions_are_checked_against_their_authority(self):
        """S9-R0-05: recorded caps and loads must agree with the capture's admission authority."""
        raised = make_capture(self.root, "raised", 5.0, 5.0, admission_cap=30.0)
        code, report = self.run_compare(f"{raised}#{ON}", f"{raised}#{SKIP}", treatment=False)
        self.assertEqual(code, 2)
        self.assertTrue(any("admission_authority_mismatch" in r for r in report["scenarios"]["null-test"]["reasons"]))
        inherited = self.treated("inherited", 5.0, 5.0, admission_cap=28.0)  # above the reference's pinned cap
        code, report = self.run_compare(f"{inherited}#{ON}", f"{inherited}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertTrue(any("admission_authority_mismatch" in r for r in report["scenarios"]["null-test"]["reasons"]))
        row_cap = make_capture(self.root, "row-cap", 5.0, 5.0)
        rows = [json.loads(line) for line in (Path(row_cap) / "attempts.jsonl").read_text().splitlines()]
        rows[0]["admissionCap"] = 99.0
        (Path(row_cap) / "attempts.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        self.assert_integrity_failure(row_cap, "admissionCap")

    def test_treatment_lineage_must_resolve_to_an_eligible_reference(self):
        cap = self.treated("lineage-ok", 5.0, 5.0)
        self.assertEqual(self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}")[0], 0)
        edit_json(Path(self.root / "ref-L" / "calibration.json"), lambda c: c.__setitem__("pinnedLoad1Threshold", 20.0))
        code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}")
        self.assertEqual(code, 2)
        self.assertTrue(any("calibration_reference" in r for r in report["scenarios"]["null-test"]["reasons"]), report)

    def test_diagnostic_scenarios_never_gate_the_aggregate(self):
        """S9-R0-08: cold is reported separately and only an integrity error affects the exit code."""
        mixed = make_capture(self.root, "mixed", 5.0, 5.0, scenarios=("null-test", "cold"))
        code, report = self.run_compare(f"{mixed}#{ON}", f"{mixed}#{SKIP}", treatment=False)
        self.assertEqual(code, 0, report)
        self.assertNotIn("cold", report["scenarios"])
        self.assertEqual(report["diagnostics"]["cold"]["verdict"], "not_gated")
        self.assertEqual(report["diagnostics"]["cold"]["integrity"], "ok")
        self.assertNotIn("primary", report["diagnostics"]["cold"])
        only = self.run_compare(f"{mixed}#{ON}", f"{mixed}#{SKIP}", "--scenarios", "cold", treatment=False)
        self.assertEqual(only[0], 2)
        self.assertIn("no_gated_scenarios", only[1]["reasons"])
        broken = make_capture(self.root, "mixed-broken", 5.0, 5.0, scenarios=("null-test", "cold"))
        edit_json(Path(broken) / "result.json",
                  lambda r: r["scenarios"]["cold"]["pairs"][0].__setitem__(0, 99.0))
        code, report = self.run_compare(f"{broken}#{ON}", f"{broken}#{SKIP}", treatment=False)
        self.assertEqual(code, 3, report)
        self.assertEqual(report["diagnostics"]["cold"]["integrity"], "harness_failure")
        self.assertEqual(report["scenarios"]["null-test"]["exitCode"], 0)

    def test_arm_selection(self):
        result = {"scenarios": {"null-test": {"pairs": [[1.0, 2.0], [3.0, 4.0]]}}}
        self.assertEqual(bench.arm_values(result, "null-test", ON), [1.0, 3.0])
        self.assertEqual(bench.arm_values(result, "null-test", SKIP), [2.0, 4.0])

    def assert_harness_failure(self, code, report, where):
        self.assertEqual(code, 3, report)
        self.assertIsNotNone(report, "a structured --report is written for malformed evidence")
        self.assertEqual(report["exitCode"], 3)
        text = report.get("error") or (report["scenarios"].get("null-test") or {}).get("error") or ""
        self.assertIn("malformed capture evidence", text)
        self.assertIn(where, text)

    def test_every_malformed_reference_field_is_a_reported_harness_failure(self):
        """S9-R0-04/S9-R2-01: reference fields are typed before any set or lineage use (exit 3, never 1 or 0)."""
        good = self.treated("good", 5.0, 5.0)
        self.assertEqual(self.run_compare(f"{good}#{ON}", f"{good}#{SKIP}")[0], 0)  # negative control
        missing = object()
        cases = [("qualifiedScenarios", [["null-test"]]), ("qualifiedScenarios", 5),
                 ("qualifiedScenarios", "null-test"), ("qualifiedScenarios", {"null-test": 1}),
                 ("qualifiedScenarios", [{"x": 1}]), ("qualifiedScenarios", [1]), ("qualifiedScenarios", [""]),
                 ("qualifiedScenarios", None), ("qualifiedScenarios", missing), ("captureDir", ["x"]),
                 ("captureDir", ""), ("runId", 5), ("lineageRoot", None), ("pinnedLoad1Threshold", "4.2"),
                 ("pinnedLoad1Threshold", [4.2]), ("pinnedLoad1Threshold", -1), ("calibrationSha256", "nothex"),
                 ("calibrationSha256", None), ("calibrationSha256", missing)]
        for index, (key, value) in enumerate(cases):
            with self.subTest(key=key, value="<missing>" if value is missing else value):
                cap = self.treated(f"bad-ref-{index}", 5.0, 5.0)

                def mutate(manifest):
                    if value is missing:
                        del manifest["calibrationReference"][key]
                    else:
                        manifest["calibrationReference"][key] = value
                edit_json(Path(cap) / "manifest.json", mutate)
                code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}")
                self.assert_harness_failure(code, report, f"manifest.calibrationReference.{key}")

    def test_malformed_retained_values_are_reported_harness_failures(self):
        """S9-R0-04: unhashable or mistyped retained values, consistent across row and raw files, exit 3."""

        def first_row(cap):
            rows = [json.loads(line) for line in (Path(cap) / "attempts.jsonl").read_text().splitlines()]
            return rows, next(row for row in rows if row.get("phase") == "result")

        def write_rows(cap, rows):
            (Path(cap) / "attempts.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))

        def fingerprint(value):
            def apply(cap):
                rows, row = first_row(cap)
                row["fingerprint"] = value
                write_rows(cap, rows)
                edit_json(Path(cap) / row["rawStatus"], lambda status: status.__setitem__("fingerprint", value))
            return apply

        def terminal_state(cap):
            rows, row = first_row(cap)
            row["state"] = ["completed"]
            write_rows(cap, rows)
            for field in ("rawStatus", "rawTerminal"):
                edit_json(Path(cap) / row[field], lambda doc: doc.__setitem__("state", ["completed"]))

        def interval_quality(cap):
            _rows, row = first_row(cap)
            edit_json(Path(cap) / row["rawTimings"], lambda timings: timings["phaseMetrics"]["intervals"][
                bench.PRIMARY_INTERVAL].__setitem__("quality", ["measured_wall"]))

        cases = [("list fingerprint", fingerprint(["fp"]), "fingerprint"),
                 ("dict fingerprint", fingerprint({"fp": 1}), "fingerprint"),
                 ("int fingerprint", fingerprint(7), "fingerprint"),
                 ("empty fingerprint", fingerprint(""), "fingerprint"),
                 ("list terminal state", terminal_state, "terminal observation"),
                 ("list interval quality", interval_quality, "not a valid sample")]
        for index, (name, apply, where) in enumerate(cases):
            with self.subTest(case=name):
                cap = make_capture(self.root, f"bad-row-{index}", 5.0, 5.0)
                apply(cap)
                code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
                self.assert_harness_failure(code, report, where)

    def test_real_cli_process_exits_3_with_report_for_reproduced_shapes(self):
        """The reproduced shapes, through the actual CLI process: exit 3, a report, no traceback."""
        nested = self.treated("nested", 5.0, 5.0)
        edit_json(Path(nested) / "manifest.json",
                  lambda m: m["calibrationReference"].__setitem__("qualifiedScenarios", [["null-test"]]))
        listed = make_capture(self.root, "listed", 5.0, 5.0)
        rows = [json.loads(line) for line in (Path(listed) / "attempts.jsonl").read_text().splitlines()]
        row = next(row for row in rows if row.get("phase") == "result")
        row["fingerprint"] = [row["fingerprint"]]
        (Path(listed) / "attempts.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        edit_json(Path(listed) / row["rawStatus"], lambda status: status.__setitem__("fingerprint", row["fingerprint"]))
        for name, cap, treatment in (("nested", nested, True), ("listed", listed, False)):
            with self.subTest(case=name):
                report = self.root / f"cli-{name}.json"
                args = [sys.executable, "-B", str(SCRIPT_DIR / "swift_build_benchmark.py"), "compare", "--baseline",
                        f"{cap}#{ON}", "--candidate", f"{cap}#{SKIP}", "--report", str(report)]
                if treatment:
                    args += ["--treatment-manifest", str(self.treatment)]
                proc = subprocess.run(args, capture_output=True, text=True,
                                      env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
                self.assertEqual(proc.returncode, 3, proc.stderr[-800:])
                self.assertNotIn("Traceback", proc.stderr)
                self.assertEqual(json.loads(report.read_text())["exitCode"], 3)

    def test_unexpected_exception_backstop_reports_exit_3_and_never_masks_interrupts(self):
        """S9-R2-01: any other Exception at an evidence site is exit 3 with a report; interrupts propagate."""
        cap = make_capture(self.root, "cap", 5.0, 5.0)
        with mock.patch.object(bench, "paired_within", side_effect=TypeError("boom")):
            code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
        self.assertEqual((code, report["exitCode"], report["scenarios"]["null-test"]["verdict"]),
                         (3, 3, "harness_failure"))
        self.assertIn("unexpected TypeError", report["scenarios"]["null-test"]["error"])
        with mock.patch.object(bench, "load_capture", side_effect=ValueError("bad")):
            code, report = self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
        self.assertEqual((code, report["exitCode"]), (3, 3))
        self.assertIn("unexpected ValueError", report["error"])
        for interrupt in (KeyboardInterrupt, SystemExit):
            with self.subTest(interrupt=interrupt.__name__):
                with mock.patch.object(bench, "paired_within", side_effect=interrupt()):
                    with self.assertRaises(interrupt):
                        self.run_compare(f"{cap}#{ON}", f"{cap}#{SKIP}", treatment=False)
        # A confirmed regression is still exit 1; the backstop only replaces a missing verdict.
        big = self.treated("big", 5.0, 5.6)
        modest = self.treated("modest", 5.0, 5.2)
        confirm = ("--confirm-baseline", f"{modest}#{ON}", "--confirm-candidate", f"{modest}#{SKIP}")
        self.assertEqual(self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", *confirm)[0], 1)
        with mock.patch.object(bench, "confirmation", side_effect=TypeError("boom")):
            code, report = self.run_compare(f"{big}#{ON}", f"{big}#{SKIP}", *confirm)
        self.assertEqual(code, 3)
        self.assertIn("unexpected TypeError", report["scenarios"]["null-test"]["confirmation"]["error"])


class CalibrationReferenceTests(unittest.TestCase):
    def test_effective_cap_is_pinned_and_never_raised(self):
        self.assertEqual(bench.effective_load_cap(None, 28), 28.0)
        self.assertEqual(bench.effective_load_cap({"pinnedLoad1Threshold": 6.5}, 28), 6.5)
        self.assertEqual(bench.effective_load_cap({"pinnedLoad1Threshold": 40.0}, 28), 28.0)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.host = dict(FIXTURE_HOST)

    def tearDown(self):
        self.tmp.cleanup()

    def reference(self, name="ref", **calibration):
        """An evidence-backed fresh A/A capture; ``calibration`` overrides forge its calibration.json."""
        directory = Path(make_capture(self.root, name, 5.0, 5.0))
        if calibration:
            edit_json(directory / "calibration.json", lambda data: data.update(calibration))
        return str(directory)

    def load(self, reference, host=None, scenario="null-test"):
        return bench.load_calibration_reference(reference, None, host or self.host, [bench.SCENARIOS[scenario]])

    def test_pins_cap_and_never_raises_it(self):
        ref = self.load(self.reference())
        rows = [json.loads(line) for line in (self.root / "ref" / "attempts.jsonl").read_text().splitlines()]
        self.assertEqual(ref["pinnedLoad1Threshold"], max(row["load1"] for row in rows))
        self.assertEqual(ref["lineageRoot"], "run-ref")
        self.assertFalse(any(action.option_strings == ["--load-cap"] for action in
                             bench.build_parser()._subparsers._group_actions[0].choices["run"]._actions))

    def test_rejections(self):
        cases = [
            (dict(reusable=False), "not_reusable"),
            (dict(diagnosticOnly=True), "diagnostic_only"),
            (dict(pinnedLoad1Threshold=None), "pinned_threshold_missing"),
            (dict(lineageRoot="other"), "lineage_missing_or_inconsistent"),
            (dict(qualifiedScenarios=["test-body"]), "scenario_not_calibrated:null-test"),
        ]
        for index, (kwargs, reason) in enumerate(cases):
            with self.subTest(reason=reason):
                with self.assertRaises(bench.Ineligible) as raised:
                    self.load(self.reference(f"r{index}", **kwargs))
                self.assertIn(reason, raised.exception.reasons)
        other_host = dict(self.host, osBuild="other")
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(self.reference("h"), host=other_host)
        self.assertIn("host_incompatible:osBuild", raised.exception.reasons)

    def test_reference_needs_complete_cleanup_and_attempt_evidence(self):
        """S9-R0-05: a manifest plus calibration.json alone never authorizes admission."""
        for missing in ("result.json", "attempts.jsonl"):
            with self.subTest(missing=missing):
                reference = self.reference(f"no-{missing}")
                (Path(reference) / missing).unlink()
                with self.assertRaises(bench.HarnessError):
                    self.load(reference)
        unclean = self.reference("unclean")
        edit_json(Path(unclean) / "ownership.json", lambda o: o["arms"][ON].__setitem__("cleanup", "daemonStopped"))
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(unclean)
        self.assertIn("cleanup_unverified", raised.exception.reasons)
        no_raw = Path(make_capture(self.root, "no-raw", 5.0, 5.0, raw=False))
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(str(no_raw))
        self.assertIn("qualified_scenario_unverified:null-test", raised.exception.reasons)

    def test_root_threshold_must_derive_from_retained_aa_loads(self):
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(self.reference("raised", pinnedLoad1Threshold=20.0))
        self.assertIn("pinned_threshold_not_derived", raised.exception.reasons)

    def test_inherited_threshold_is_validated_through_the_lineage(self):
        parent = make_reference(self.root, "L")
        child = Path(make_capture(self.root, "child", 5.0, 5.0, reference=parent))
        inherited = self.load(str(child))
        self.assertEqual((inherited["pinnedLoad1Threshold"], inherited["lineageRoot"]),
                         (parent["pinnedLoad1Threshold"], "L"))
        edit_json(child / "calibration.json",
                  lambda c: c.__setitem__("pinnedLoad1Threshold", parent["pinnedLoad1Threshold"] + 5.0))
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(str(child))
        self.assertIn("pinned_threshold_raised", raised.exception.reasons)
        # A parent whose calibration changed after the child referenced it breaks the lineage.
        sibling = Path(make_capture(self.root, "sibling", 5.0, 5.0, reference=parent))
        edit_json(self.root / "ref-L" / "calibration.json", lambda c: c.__setitem__("note", "edited"))
        with self.assertRaises(bench.Ineligible) as raised:
            self.load(str(sibling))
        self.assertTrue(any(r.startswith("lineage_reference_mismatch") for r in raised.exception.reasons),
                        raised.exception.reasons)

    def compare(self, cap, *, treatment=False):
        args = ["compare", "--baseline", f"{cap}#{ON}", "--candidate", f"{cap}#{SKIP}"]
        if treatment:
            manifest = self.root / "treatment.json"
            manifest.write_text(json.dumps(DSYM_TREATMENT))
            args += ["--treatment-manifest", str(manifest)]
        report = self.root / f"report-{len(list(self.root.glob('report-*')))}.json"
        with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            code = bench.main([*args, "--report", str(report)])
        return code, json.loads(report.read_text())

    def test_reference_needs_comparable_arms_and_mandatory_metadata(self):
        """S9-R0-05: reference admission applies the comparison's own gate and arm compatibility, so
        neither the reference nor any capture whose lineage depends on it can be qualified by it."""
        dropped = bench.MANDATORY_META_KEYS[0]

        def runtime(manifest):
            manifest["arms"][SKIP]["runtimeFileSha256"]["Scripts/canonical_swift.sh"] = HASH_C
        cases = [("path", dict(skip_env={"PATH": "/opt/bin"}), None, "incompatible:environmentClass"),
                 ("runtime", {}, runtime, "incompatible:digestClass"),
                 ("metadata", dict(meta_drop=(dropped,)), None, f"metadata_missing:{dropped}")]
        for name, kwargs, edit, reason in cases:
            with self.subTest(case=name):
                directory = Path(make_capture(self.root, f"ref-{name}", 5.0, 5.0, run_id=name, **kwargs))
                if edit is not None:
                    edit_json(directory / "manifest.json", edit)
                # The unchanged comparison authority rejects the capture's own arms.
                code, report = self.compare(directory)
                self.assertEqual(code, 2)
                self.assertIn(reason, json.dumps(report["scenarios"]["null-test"]))
                # Reference admission now rejects the same capture for the same reason.
                with self.assertRaises(bench.Ineligible) as raised:
                    self.load(str(directory))
                for expected in ("qualified_scenario_unverified:null-test",
                                 f"qualified_scenario_unverified:null-test:{reason}",
                                 "scenario_not_calibrated:null-test"):
                    self.assertIn(expected, raised.exception.reasons)
                reference = make_reference(self.root, name)  # what a run would have recorded from it
                # A treatment capture whose lineage is this reference is not qualified by it ...
                treated = make_capture(self.root, f"treated-{name}", 5.0, 5.0, treatment="declared",
                                       skip_env={"RPCE_DEBUG_DSYM": "off"}, reference=reference)
                code, report = self.compare(treated, treatment=True)
                self.assertEqual(code, 2, report)
                reasons = report["scenarios"]["null-test"]["reasons"]
                self.assertIn("calibration_reference_ineligible:qualified_scenario_unverified:null-test", reasons)
                self.assertIn("aa_not_qualified", reasons)
                # ... nor can an inherited A/A calibration through it be admitted.
                child = make_capture(self.root, f"child-{name}", 5.0, 5.0, reference=reference)
                with self.assertRaises(bench.Ineligible) as raised:
                    self.load(child)
                self.assertIn("calibration_reference_ineligible:qualified_scenario_unverified:null-test",
                              raised.exception.reasons)
        # Negative control: a comparable reference and the treatment lineage through it still qualify.
        reference = make_reference(self.root, "ok")
        self.assertEqual(self.load(reference["captureDir"])["qualifiedScenarios"], ["null-test"])
        treated = make_capture(self.root, "treated-ok", 5.0, 5.0, treatment="declared",
                               skip_env={"RPCE_DEBUG_DSYM": "off"}, reference=reference)
        self.assertEqual(self.compare(treated, treatment=True)[0], 0)


def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(os.path.realpath(self.tmp.name))
        self.repo = root / "repo"
        self.repo.mkdir()
        git(["init", "-q"], self.repo)
        git(["config", "user.email", "t@example.com"], self.repo)
        git(["config", "user.name", "t"], self.repo)
        git(["config", "commit.gpgsign", "false"], self.repo)
        (self.repo / "Tests" / "RepoPromptTests").mkdir(parents=True)
        (self.repo / "Sources" / "RepoPrompt" / "Support").mkdir(parents=True)
        (self.repo / "Tests" / "RepoPromptTests" / "ExistingTests.swift").write_text("class ExistingTests {}\n")
        (self.repo / "Sources" / "RepoPrompt" / "Support" / "keep.h").write_text("\n")
        (self.repo / ".gitignore").write_text(".build/\n")
        git(["add", "-A"], self.repo)
        git(["commit", "-q", "-m", "init"], self.repo)
        self.commit = git(["rev-parse", "HEAD"], self.repo).strip()
        self.owner = bench.WorktreeOwner(self.repo, root / "state" / "benchmarks")
        self.manifest = bench.load_fixture_manifest()

    def tearDown(self):
        subprocess.run(["git", "worktree", "prune"], cwd=self.repo, capture_output=True)
        self.tmp.cleanup()

    def create(self, arm=ON, run_id="run"):
        self.owner.dir.mkdir(parents=True, exist_ok=True)
        record = self.owner.create(arm, self.commit)
        self.owner.verify_identity(record)
        self.owner.write_marker(record, run_id)
        record.update(markerWritten=True, cleanup="active")
        record["daemon"] = {"pid": 42}
        ledger = bench.FixtureLedger(Path(record["realpath"]), self.manifest, busy_check=lambda: None)
        ledger.install()
        return record, ledger

    def test_create_verify_and_remove(self):
        record, ledger = self.create()
        self.owner.verify_identity(record, "run")
        self.owner.verify_dirtiness(record, ledger)
        self.assertEqual(sorted(ledger.expected_untracked()), sorted([
            "Sources/RepoPrompt/Support/BuildPipelineBenchmarkAppProbe.swift",
            "Tests/RepoPromptTests/BuildPipelineBenchmarkProbeTests.swift",
        ]))
        self.owner.remove(record)
        self.assertFalse(os.path.lexists(record["path"]))
        self.assertNotIn(record["realpath"], self.owner.registered())
        # The main checkout and its branch are untouched.
        self.assertEqual(git(["rev-parse", "HEAD"], self.repo).strip(), self.commit)

    def test_refuses_existing_paths_pointer_and_live_daemons(self):
        self.owner.dir.mkdir(parents=True)
        self.owner.preflight_new(lambda path: False)
        (self.owner.dir / ON).mkdir()
        with self.assertRaisesRegex(bench.HarnessError, "not owned by this run"):
            self.owner.preflight_new(lambda path: False)
        (self.owner.dir / ON).rmdir()
        with self.assertRaisesRegex(bench.HarnessError, "daemon"):
            self.owner.preflight_new(lambda path: True)
        self.owner.pointer.write_text("{}")
        with self.assertRaisesRegex(bench.HarnessError, "earlier run"):
            self.owner.preflight_new(lambda path: False)

    def test_control_lock_is_exclusive(self):
        self.owner.acquire_control_lock()
        other = bench.WorktreeOwner(self.repo, self.owner.bench_root)
        with self.assertRaisesRegex(bench.HarnessError, "another benchmark run"):
            other.acquire_control_lock()
        self.owner.release_control_lock()
        other.acquire_control_lock()
        other.release_control_lock()

    def test_identity_failures(self):
        record, _ledger = self.create()
        with self.assertRaisesRegex(bench.HarnessError, "marker"):
            self.owner.verify_identity(record, "other-run")
        tree = Path(record["realpath"])
        git(["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "moved"], tree)
        with self.assertRaisesRegex(bench.HarnessError, "HEAD"):
            self.owner.verify_identity(record, "run")

    def test_symlink_substitution_is_refused(self):
        record, _ledger = self.create()
        tree = Path(record["path"])
        moved = tree.with_name("moved-away")
        tree.rename(moved)
        tree.symlink_to(moved)
        with self.assertRaisesRegex(bench.HarnessError, "real directory"):
            self.owner.verify_identity(record, "run")
        tree.unlink()
        moved.rename(tree)

    def test_unexpected_dirtiness_preserves_the_tree(self):
        record, ledger = self.create()
        (Path(record["realpath"]) / "stray.txt").write_text("x")
        with self.assertRaisesRegex(bench.HarnessError, "unexpected dirtiness"):
            self.owner.verify_dirtiness(record, ledger)

    def store_for(self, *records, requests=None):
        store = bench.OwnershipStore(Path(self.tmp.name) / "ownership.json",
                                     {"runId": "run", "arms": {r["arm"]: r for r in records},
                                      "requests": requests or {}})
        store.save()
        return store

    def cleaner(self, store, clients, ledgers=None, scan=lambda text: []):
        return bench.Cleaner(None, self.owner, store, None, ledgers or {}, lambda arm, record: clients[arm],
                             clock=FakeClock(), scan=scan)

    def clients(self, **plans):
        return {arm: FakeClient(Path(self.tmp.name) / "clients", arm, plans.get(arm)) for arm in bench.ARMS}

    def test_mixed_cleanup_then_successful_resume(self):
        record_on, ledger_on = self.create(ON)
        record_skip, ledger_skip = self.create(SKIP)
        self.owner.pointer.write_text("{}")
        stray = Path(record_skip["realpath"]) / "stray.txt"
        stray.write_text("x")
        store = self.store_for(record_on, record_skip)
        clients = self.clients()
        report = self.cleaner(store, clients, {ON: ledger_on, SKIP: ledger_skip}).run()
        self.assertFalse(report["ok"])
        self.assertEqual((store.arm_state(ON), store.arm_state(SKIP)), ("removed", "daemonStopped"))
        self.assertFalse(os.path.lexists(record_on["path"]))
        self.assertTrue(os.path.isdir(record_skip["path"]))
        self.assertTrue(self.owner.pointer.exists(), "pointer kept while any owned tree is preserved")
        self.assertEqual(store.data["state"], "cleanup_failed")
        # Resume from the durable record after the operator resolves the stray file.
        stray.unlink()
        reloaded = bench.OwnershipStore(store.path, json.loads(store.path.read_text()))
        report = self.cleaner(reloaded, clients, {ON: ledger_on, SKIP: ledger_skip}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["arms"][ON]["steps"], ["already removed"])
        self.assertEqual(report["arms"][SKIP]["resumedFrom"], "daemonStopped")
        self.assertEqual(clients[SKIP].stops, [42], "the stopped daemon is neither queried nor stopped again")
        self.assertFalse(self.owner.pointer.exists())
        self.assertEqual(len(reloaded.data["cleanupRuns"]), 2)

    def test_unrecorded_daemon_needs_independent_identity_proof(self):
        record, ledger = self.create(ON)
        record.pop("daemon")
        clients = self.clients()
        clients[ON].verify_owned_daemon = lambda pid: False
        store = self.store_for(record)
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertFalse(report["ok"])
        self.assertIn("independently verified", report["arms"][ON]["error"])
        self.assertTrue(os.path.isdir(record["path"]))
        self.assertEqual(clients[ON].stops, [])
        clients[ON].verify_owned_daemon = lambda pid: pid == 42
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertTrue(store.arms[ON]["daemon"]["adopted"])

    def test_live_daemon_that_is_not_the_recorded_one_is_preserved(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        clients[ON].pid = 77
        clients[ON].verify_owned_daemon = lambda pid: True
        report = self.cleaner(self.store_for(record), clients, {ON: ledger}).run()
        self.assertFalse(report["ok"])
        self.assertIn("not the recorded owned daemon", report["arms"][ON]["error"])
        self.assertEqual(clients[ON].stops, [])

    def test_unrecorded_arm_paths_keep_the_pointer(self):
        self.owner.dir.mkdir(parents=True)
        (self.owner.dir / SKIP).mkdir()
        self.owner.pointer.write_text("{}")
        report = self.cleaner(self.store_for(), {}).run()
        self.assertFalse(report["ok"])
        self.assertEqual(report["unrecordedPaths"], [str(self.owner.dir / SKIP)])
        self.assertTrue((self.owner.dir / SKIP).is_dir())
        self.assertTrue(self.owner.pointer.exists())

    def test_accepted_tickets_are_cancelled_before_stop(self):
        record, ledger = self.create(ON)
        clients = self.clients(**{ON: lambda t: [job_payload(t, state="running")]})
        accepted = clients[ON]._accept("k1")
        store = self.store_for(record, requests={"k1": {"state": "accepted", "arm": ON, "ticket": accepted["ticket"]}})
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(clients[ON].cancels, [accepted["ticket"]])
        self.assertEqual(store.requests["k1"]["state"], "terminal")

    def test_interrupted_acceptance_is_reconciled_by_key_after_the_producer_finished(self):
        record, ledger = self.create(ON)
        clients = self.clients(**{ON: lambda t: [job_payload(t, state="running")]})
        clients[ON]._accept("k-accepted")
        requests = {
            "k-accepted": {"state": "intent", "arm": ON, "producer": {"pid": 5, "startToken": "a", "finished": True}},
            "k-lost": {"state": "intent", "arm": ON, "producer": {"pid": 6, "startToken": "b", "finished": True}},
        }
        store = self.store_for(record, requests=requests)
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(store.requests["k-accepted"]["state"], "terminal")
        self.assertEqual(len(clients[ON].cancels), 1)
        self.assertEqual(store.requests["k-lost"]["state"], "notAccepted")

    def test_a_possibly_live_producer_preserves_state(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        store = self.store_for(record, requests={
            "k": {"state": "intent", "arm": ON, "producer": {"pid": 5, "startToken": "a", "finished": False}}})
        for alive in (True, None):
            with self.subTest(alive=alive), mock.patch.object(bench, "process_alive_with_token", return_value=alive):
                report = self.cleaner(store, clients, {ON: ledger}).run()
                self.assertFalse(report["ok"])
                self.assertIn("may be alive", report["arms"][ON]["error"])
                self.assertEqual(store.requests["k"]["state"], "intent")
        # Unrecorded producer (launch window): a process still mentioning the key preserves state.
        store.requests["k"]["producer"] = None
        report = self.cleaner(store, clients, {ON: ledger}, scan=lambda text: [99] if text == "k" else []).run()
        self.assertFalse(report["ok"])
        self.assertIn("still mention request key k", report["arms"][ON]["error"])
        self.assertEqual(store.arm_state(ON), "active")
        self.assertEqual(clients[ON].stops, [])

    def test_unreachable_lookup_preserves_state(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        clients[ON].key_status_errors = ["could not contact daemon"]
        store = self.store_for(record, requests={
            "k": {"state": "intent", "arm": ON, "producer": {"pid": 5, "startToken": "a", "finished": True}}})
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertFalse(report["ok"])
        self.assertIn("lookup failed", report["arms"][ON]["error"])
        self.assertEqual((store.requests["k"]["state"], store.arm_state(ON)), ("intent", "active"))
        self.assertEqual(clients[ON].stops, [])
        self.assertTrue(os.path.isdir(record["path"]))

    def test_daemon_gone_resolution_requires_a_quiet_worktree(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        clients[ON].pid = None
        store = self.store_for(record, requests={
            "k": {"state": "intent", "arm": ON, "producer": {"pid": 5, "startToken": "a", "finished": True}}})
        busy = self.cleaner(store, clients, {ON: ledger},
                            scan=lambda text: [123] if text == record["realpath"] else []).run()
        self.assertFalse(busy["ok"])
        self.assertEqual(store.requests["k"]["state"], "intent")
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(store.requests["k"]["state"], "notAccepted")
        self.assertEqual(clients[ON].stops, [])

    def test_unenumerable_processes_preserve_state(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        store = self.store_for(record, requests={"k": {"state": "intent", "arm": ON, "producer": None}})
        report = self.cleaner(store, clients, {ON: ledger}, scan=lambda text: None).run()
        self.assertFalse(report["ok"])
        self.assertIn("cannot enumerate", report["arms"][ON]["error"])

    def test_resume_after_crash_in_remove_pending(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        store.set_arm_state(ON, "removePending", "test")
        self.owner.remove(record)  # the crash happened after git removed the tree
        clients = self.clients()
        clients[ON].pid = None  # stopped before the checkpoint; the launchd job is still verified unloaded
        report = self.cleaner(store, clients).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(store.arm_state(ON), "removed")
        self.assertEqual(clients[ON].stops, [])
        self.assertIs(clients[ON].launchd, False)
        # removePending with the tree still present: re-verified, then removed. The daemon was
        # stopped before the checkpoint (a live one now preserves; see the revalidation tests).
        record2, ledger2 = self.create(SKIP)
        store2 = self.store_for(record2)
        store2.set_arm_state(SKIP, "removePending", "test")
        clients[SKIP].pid = None
        report = self.cleaner(store2, clients, {SKIP: ledger2}).run()
        self.assertTrue(report["ok"], report)
        self.assertFalse(os.path.lexists(record2["path"]))

    def interrupt_first_removal(self):
        real, calls = self.owner.remove, []

        def remove(record):
            calls.append(record["arm"])
            if len(calls) == 1:
                raise bench.HarnessError("simulated interrupted git worktree remove")
            return real(record)
        self.owner.remove = remove
        return calls

    def test_resumed_removal_revalidates_a_tree_changed_after_the_checkpoint(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        store.set_arm_state(ON, "daemonStopped", {"stoppedPid": 42})
        clients = self.clients()
        clients[ON].pid = None
        calls = self.interrupt_first_removal()
        first = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertFalse(first["ok"])
        self.assertEqual(store.arm_state(ON), "removePending")
        self.assertTrue(os.path.isdir(record["path"]))
        # A user or new job writes into the tree before the cleanup retry.
        note = Path(record["realpath"]) / "user-note.txt"
        note.write_text("written after the checkpoint\n")
        reloaded = bench.OwnershipStore(store.path, json.loads(store.path.read_text()))
        retry = self.cleaner(reloaded, clients, {ON: ledger}).run()
        self.assertFalse(retry["ok"])
        self.assertIn("unexpected dirtiness", retry["arms"][ON]["error"])
        self.assertEqual(reloaded.arm_state(ON), "removePending")
        self.assertTrue(note.exists(), "an earlier proof never authorizes deleting a new file")
        self.assertIn(record["realpath"], self.owner.registered())
        self.assertEqual(calls, [ON], "no second forced removal was attempted")
        # The operator resolves the file: the unchanged resumable cleanup completes.
        note.unlink()
        done = self.cleaner(reloaded, clients, {ON: ledger}).run()
        self.assertTrue(done["ok"], done)
        self.assertEqual(done["arms"][ON]["steps"], ["worktree removed (resumed)"])
        self.assertTrue(self.owner.absent_and_deregistered(record))

    def test_resumed_removal_preserves_on_daemon_producer_request_or_fixture_doubt(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        store.set_arm_state(ON, "removePending", "checkpoint")
        clients = self.clients()
        tree = {record["realpath"], record["path"]}
        probe = Path(record["realpath"]) / "Tests" / "RepoPromptTests" / "BuildPipelineBenchmarkProbeTests.swift"
        original = probe.read_bytes()
        stat_before = os.stat(probe)
        cases = (
            ("restarted daemon", lambda: setattr(clients[ON], "pid", 4242), lambda t: [],
             "started after it was recorded stopped"),
            ("possibly live producer", lambda: None, lambda t: [31337] if t in tree else [], "still mention"),
            ("unenumerable processes", lambda: None, lambda t: None, "cannot enumerate"),
            ("open owned request", lambda: store.requests.update(
                {"k": {"state": "intent", "arm": ON, "producer": {"pid": 5, "finished": False}}}),
             lambda t: [], "not terminal"),
            ("fixture edited", lambda: probe.write_bytes(original + b"// edit\n"), lambda t: [], "fixture fence"),
        )
        for name, arrange, scan, reason in cases:
            with self.subTest(case=name):
                clients[ON].pid = None
                store.requests.pop("k", None)
                probe.write_bytes(original)
                os.utime(probe, ns=(stat_before.st_atime_ns, stat_before.st_mtime_ns))
                arrange()
                report = self.cleaner(store, clients, {ON: ledger}, scan=scan).run()
                self.assertFalse(report["ok"])
                self.assertIn(reason, report["arms"][ON]["error"])
                self.assertEqual(store.arm_state(ON), "removePending")
                self.assertTrue(os.path.isdir(record["path"]))
                self.assertIn(record["realpath"], self.owner.registered())
                self.assertEqual(clients[ON].stops, [], "a resumed removal never stops or queries a daemon")
        clients[ON].pid = None
        store.requests.pop("k", None)
        probe.write_bytes(original)
        os.utime(probe, ns=(stat_before.st_atime_ns, stat_before.st_mtime_ns))
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertTrue(self.owner.absent_and_deregistered(record))

    def test_daemon_stopped_final_proof_honors_the_process_boundary(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        store.set_arm_state(ON, "daemonStopped", {"stoppedPid": 42})
        clients = self.clients()
        clients[ON].pid = None
        tree = {record["realpath"], record["path"]}
        for scan, reason in ((lambda t: [31337] if t in tree else [], "still mention"),
                             (lambda t: None, "cannot enumerate")):
            with self.subTest(reason=reason):
                report = self.cleaner(store, clients, {ON: ledger}, scan=scan).run()
                self.assertFalse(report["ok"])
                self.assertIn(reason, report["arms"][ON]["error"])
                self.assertEqual(store.arm_state(ON), "daemonStopped", "no removePending checkpoint without proof")
                self.assertTrue(os.path.isdir(record["path"]))
        seen = []
        report = self.cleaner(store, clients, {ON: ledger}, scan=lambda t: seen.append(t) or []).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(sorted(set(seen)), sorted(tree), "the final proof scanned the tree paths")
        self.assertTrue(self.owner.absent_and_deregistered(record))

    def test_resumed_unload_freshly_proves_a_present_tree_before_any_launchd_operation(self):
        """S9-R0-01: from removePending, a changed marker or HEAD preserves the arm with no bootout."""
        record, ledger = self.create(ON)
        marker = Path(record["path"]) / bench.WorktreeOwner.MARKER
        original = marker.read_bytes()
        store = self.store_for(record)
        store.set_arm_state(ON, "removePending", "checkpoint")
        clients = self.clients()
        clients[ON].pid = None
        tree = Path(record["realpath"])

        def assert_preserved(report, text, loaded):
            self.assertFalse(report["ok"])
            self.assertIn(text, report["arms"][ON]["error"])
            self.assertEqual(clients[ON].bootouts, [], "no launchd side effect before the fresh identity proof")
            self.assertIs(clients[ON].launchd, loaded)
            self.assertNotIn("launchd", store.arms[ON], "no unload evidence is recorded")
            self.assertEqual(store.arm_state(ON), "removePending")
            self.assertIn(record["realpath"], self.owner.registered())
        for loaded in (True, None):
            with self.subTest(change="marker", loaded=loaded):
                clients[ON].launchd = loaded
                marker.write_text(json.dumps({**json.loads(original), "runId": "another-run"}))
                assert_preserved(self.cleaner(store, clients, {ON: ledger}).run(), "run marker", loaded)
        marker.write_bytes(original)
        clients[ON].launchd = True
        git(["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "moved"], tree)
        with self.subTest(change="HEAD"):
            assert_preserved(self.cleaner(store, clients, {ON: ledger}).run(), "HEAD", True)
        # Negative control: the restored tree is proven before its bootout and the resumed removal completes.
        git(["checkout", "-q", "--detach", record["commit"]], tree)
        events = []
        verify, bootout = self.owner.verify_identity, clients[ON].bootout_launchd
        self.owner.verify_identity = lambda r, run_id=None: events.append("identity") or verify(r, run_id)
        clients[ON].bootout_launchd = lambda: events.append("bootout") or bootout()
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(clients[ON].bootouts, [True])
        self.assertEqual(events[:2], ["identity", "bootout"])
        self.assertTrue(self.owner.absent_and_deregistered(record))

    def test_unload_fence_is_fresh_after_termination_in_the_same_run(self):
        """A tree changed while the daemon stopped is re-proven before the bootout in the same cleanup."""
        record, ledger = self.create(ON)
        marker = Path(record["path"]) / bench.WorktreeOwner.MARKER
        store = self.store_for(record)
        store.set_arm_state(ON, "jobsTerminal", "test")
        clients = self.clients()
        stop = clients[ON].stop_daemon

        def stop_then_change(expected):
            evidence = stop(expected)
            marker.write_text(json.dumps({**json.loads(marker.read_text()), "runId": "another-run"}))
            return evidence
        clients[ON].stop_daemon = stop_then_change
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertFalse(report["ok"])
        self.assertIn("run marker", report["arms"][ON]["error"])
        self.assertEqual(clients[ON].bootouts, [])
        self.assertIs(clients[ON].launchd, True)
        self.assertEqual(store.arm_state(ON), "jobsTerminal")
        self.assertIn("daemonTermination", store.arms[ON], "the verified stop stays checkpointed")
        self.assertTrue(os.path.isdir(record["path"]))

    def test_stopped_daemon_is_never_queried_on_resume(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        store.set_arm_state(ON, "jobsTerminal", "test")
        clients = self.clients()
        clients[ON].pid = None  # daemon_status would raise if queried
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["arms"][ON]["daemon"], {"stoppedPid": None, "alreadyStopped": True})

    def test_interrupted_launchd_unload_resumes_before_removal(self):
        """S9-R0-01/S9-R1-02: termination and launchd unloading are separate durable steps."""
        record, ledger = self.create(ON)
        self.owner.pointer.write_text("{}")
        store = self.store_for(record)
        clients = self.clients()
        clients[ON].bootout_error = bench.HarnessError("simulated interruption during launchctl bootout")
        first = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertFalse(first["ok"])
        self.assertEqual(store.arm_state(ON), "jobsTerminal", "no daemonStopped checkpoint before the unload")
        self.assertEqual(store.arms[ON]["daemonTermination"]["stoppedPid"], 42)
        self.assertTrue(os.path.isdir(record["path"]))
        self.assertTrue(self.owner.pointer.exists())
        self.assertIs(clients[ON].launchd, True)
        reloaded = bench.OwnershipStore(store.path, json.loads(store.path.read_text()))
        done = self.cleaner(reloaded, clients, {ON: ledger}).run()
        self.assertTrue(done["ok"], done)
        self.assertEqual(clients[ON].stops, [42], "a verified termination is never repeated")
        self.assertIs(clients[ON].launchd, False)
        self.assertTrue(reloaded.arms[ON]["launchd"]["unloaded"])
        states = [t["state"] for t in reloaded.arms[ON]["cleanupTransitions"]]
        self.assertEqual(states, ["jobsTerminal", "daemonStopped", "removePending", "removed"])
        self.assertFalse(self.owner.pointer.exists())

    def test_already_stopped_daemon_still_unloads_its_launchd_job(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        clients = self.clients()
        clients[ON].pid = None  # died on its own (or before an earlier crash); never queried
        report = self.cleaner(store, clients, {ON: ledger}).run()
        self.assertTrue(report["ok"], report)
        self.assertEqual(clients[ON].bootouts, [True])
        self.assertIs(clients[ON].launchd, False)
        self.assertEqual(report["arms"][ON]["daemon"], {"stoppedPid": None, "alreadyStopped": True})

    def test_unknown_or_stuck_launchd_state_preserves_the_arm(self):
        for name, arrange in (("unknown", lambda c: setattr(c, "launchd", None)),
                              ("stuck", lambda c: setattr(c, "bootout_launchd", lambda: c.bootouts.append(True)))):
            with self.subTest(case=name):
                record, ledger = self.create(ON, run_id="run")
                store = self.store_for(record)
                clients = self.clients()
                clients[ON].pid = None
                arrange(clients[ON])
                report = self.cleaner(store, clients, {ON: ledger}).run()
                self.assertFalse(report["ok"])
                self.assertIn("launchd", report["arms"][ON]["error"])
                self.assertEqual(store.arm_state(ON), "jobsTerminal")
                self.assertTrue(os.path.isdir(record["path"]))
                self.owner.remove(record)

    def test_launchd_bootout_needs_a_quiet_tree(self):
        record, ledger = self.create(ON)
        store = self.store_for(record)
        clients = self.clients()
        clients[ON].pid = None
        report = self.cleaner(store, clients, {ON: ledger},
                              scan=lambda text: [777] if text == record["realpath"] else []).run()
        self.assertFalse(report["ok"])
        self.assertEqual(clients[ON].bootouts, [])
        self.assertIs(clients[ON].launchd, True)

    def v1_record(self, record):
        return {key: value for key, value in record.items() if key not in ("cleanup", "markerWritten")}

    def legacy(self, records, history):
        capture = bench.Capture(Path(self.tmp.name) / "v1-capture")
        capture.create()
        capture.attempts.write_text("")
        v1 = {"schema": 1, "runId": "run", "state": "cleanup_failed",
              "arms": {r["arm"]: self.v1_record(r) for r in records}, "cleanup": {"ok": False, "arms": history}}
        return v1, capture

    REMOVED_STEPS = ["daemon stopped and verified", "ownership and dirtiness verified", "worktree removed"]

    def test_legacy_partial_cleanup_resumes_from_v1_evidence(self):
        """S9-R0-01: a schema-1 arm removed by the earlier cleanup is reconstructed as removed."""
        record_on, ledger_on = self.create(ON)
        record_skip, ledger_skip = self.create(SKIP)
        self.owner.pointer.write_text("{}")
        v1, capture = self.legacy((record_on, record_skip), {
            ON: {"ok": True, "steps": self.REMOVED_STEPS, "daemon": {"stoppedPid": 42, "label": "x"}},
            SKIP: {"ok": False, "steps": [], "error": "HarnessError: unexpected dirtiness"}})
        original = json.dumps(v1, sort_keys=True)
        self.owner.remove(record_on)  # the earlier v1 cleanup removed this arm
        data = bench.normalize_v1_ownership(v1, capture)
        self.assertEqual(json.dumps(v1, sort_keys=True), original)
        store = bench.OwnershipStore(Path(self.tmp.name) / "ownership-recovery.json", data)
        self.assertEqual((store.arm_state(ON), store.arm_state(SKIP)), ("removed", "active"))
        clients = self.clients()
        clients[ON].pid = None  # the removed arm's daemon was stopped by the v1 cleanup
        report = self.cleaner(store, clients, {SKIP: ledger_skip}).run()
        self.assertTrue(report["ok"], report)
        self.assertIn("already removed", report["arms"][ON]["steps"])
        self.assertIs(clients[ON].launchd, False, "the legacy-removed arm's launchd job is verified unloaded")
        self.assertEqual(clients[ON].stops, [])
        self.assertTrue(self.owner.absent_and_deregistered(record_skip))
        self.assertFalse(self.owner.pointer.exists())

    def test_existing_recovery_record_is_upgraded_from_v1_evidence(self):
        record_on, _ledger = self.create(ON)
        v1, capture = self.legacy((record_on,), {ON: {"ok": True, "steps": self.REMOVED_STEPS}})
        self.owner.remove(record_on)
        data = bench.normalize_v1_ownership(v1, capture)
        data["arms"][ON]["cleanup"] = "active"  # written by an earlier harness that ignored the evidence
        data["arms"][ON].pop("legacyCleanup", None)
        store = bench.OwnershipStore(Path(self.tmp.name) / "ownership-recovery.json", data)
        bench.apply_legacy_cleanup_evidence(store, v1)
        self.assertEqual(store.arm_state(ON), "removed")
        clients = self.clients()
        clients[ON].pid = None
        self.assertTrue(self.cleaner(store, clients).run()["ok"])

    def test_legacy_evidence_without_current_absence_preserves(self):
        record_on, ledger_on = self.create(ON)
        record_skip, _ = self.create(SKIP)
        v1, capture = self.legacy((record_on, record_skip), {
            ON: {"ok": True, "steps": self.REMOVED_STEPS},  # claims removal, but the tree is present
            SKIP: {"ok": False, "steps": ["daemon stopped and verified"]}})
        self.owner.remove(record_skip)  # missing without removal evidence
        store = bench.OwnershipStore(None, bench.normalize_v1_ownership(v1, capture))
        report = self.cleaner(store, self.clients(), {ON: ledger_on}).run()
        self.assertFalse(report["ok"])
        self.assertIn("still registered", report["arms"][ON]["error"])
        self.assertIn("missing", report["arms"][SKIP]["error"])
        self.assertTrue(os.path.isdir(record_on["path"]))

    def test_interrupted_creation_is_adopted_only_by_identity_proof(self):
        self.owner.dir.mkdir(parents=True, exist_ok=True)
        pending = {"arm": ON, "path": str(self.owner.arm_path(ON)),
                   "realpath": os.path.join(os.path.realpath(self.owner.dir), ON),
                   "parentRealpath": os.path.realpath(self.owner.dir), "commit": self.commit,
                   "commonDir": self.owner.common_dir(self.repo), "created": False}
        never = self.store_for(dict(pending))
        self.assertTrue(self.cleaner(never, self.clients()).run()["ok"])
        self.assertEqual(never.arm_state(ON), "removed")
        self.owner.create(ON, self.commit)  # crashed before the record was updated
        store = self.store_for(dict(pending))
        report = self.cleaner(store, self.clients()).run()
        self.assertTrue(report["ok"], report)
        self.assertTrue(store.arms[ON]["adopted"])
        self.assertFalse(os.path.lexists(pending["path"]))

    def test_recorded_paths_are_pinned_before_any_rpc(self):
        record, ledger = self.create(ON)
        clients = self.clients()
        clients[ON].live_pid = mock.Mock(side_effect=AssertionError("RPC before pinning"))
        for field, value in (("path", "/tmp/elsewhere"), ("realpath", "/tmp/elsewhere"), ("arm", SKIP)):
            with self.subTest(field=field):
                tampered = dict(record, **{field: value})
                store = bench.OwnershipStore(None, {"runId": "run", "arms": {ON: tampered}})
                report = self.cleaner(store, clients, {ON: ledger}).run()
                self.assertFalse(report["ok"])
                self.assertTrue(os.path.isdir(record["path"]))
        with self.assertRaisesRegex(bench.HarnessError, "unknown arm"):
            self.owner.arm_path("ab-other")


class OwnedDaemonIdentityTests(unittest.TestCase):
    """Regression for capture 20261007T084813Z: identity must use the worktree's entry, not the runner's."""

    def client(self, metadata, command, start="T1"):
        tree = Path("/state/benchmarks/worktrees/ab-on")
        paths = SimpleNamespace(repo_root=tree, repo_hash="h", pid_path=Path("/p"), socket_path=Path("/s"))
        cond = mock.Mock()
        cond.compute_paths.return_value = paths
        cond.read_daemon_metadata.return_value = metadata
        cond.process_start_token.return_value = start
        cond.process_command.return_value = command
        return bench.ConductorClient(cond, tree, {}), tree

    def test_accepts_only_the_worktree_entry_daemon(self):
        metadata = {"pid": 7, "repoRoot": "/state/benchmarks/worktrees/ab-on", "repoHash": "h", "processStart": "T1"}
        tree = "/state/benchmarks/worktrees/ab-on"
        good = f"/py/Python {tree}/Scripts/conductor_entry.py __daemon --repo-root {tree}"
        client, _ = self.client(metadata, good)
        self.assertTrue(client.verify_owned_daemon(7))
        runner_entry = f"/py/Python {bench.SCRIPT_DIR}/conductor_entry.py __daemon --repo-root {tree}"
        self.assertFalse(self.client(metadata, runner_entry)[0].verify_owned_daemon(7))
        self.assertFalse(self.client(metadata, good + "x")[0].verify_owned_daemon(7))
        self.assertFalse(self.client(metadata, good, start="T2")[0].verify_owned_daemon(7))
        self.assertFalse(self.client({**metadata, "processStart": None}, good)[0].verify_owned_daemon(7))
        self.assertFalse(self.client({**metadata, "repoHash": "x"}, good)[0].verify_owned_daemon(7))
        self.assertFalse(self.client(metadata, good)[0].verify_owned_daemon(8))

    def test_stop_refuses_unverified_daemon_without_rpc(self):
        metadata = {"pid": 7, "repoRoot": "/state/benchmarks/worktrees/ab-on", "repoHash": "h", "processStart": "T1"}
        client, _ = self.client(metadata, "/py/Python other __daemon")
        client.cond.read_pid.return_value = 7
        client.cond.pid_alive.return_value = True
        with self.assertRaisesRegex(bench.HarnessError, "identity could not be verified"):
            client.stop_daemon({"pid": 7, "processStart": "T1"})
        client.cond.request_daemon.assert_not_called()
        with self.assertRaisesRegex(bench.HarnessError, "recorded owned pid"):
            client.stop_daemon({"pid": 9})
        client.cond.request_daemon.assert_not_called()
        client.cond.bootout_daemon_launchd.assert_not_called()

    def test_verified_stop_never_boots_out_and_launchd_state_is_explicit(self):
        tree = "/state/benchmarks/worktrees/ab-on"
        metadata = {"pid": 7, "repoRoot": tree, "repoHash": "h", "processStart": "T1"}
        client, _ = self.client(metadata, f"/py/Python {tree}/Scripts/conductor_entry.py __daemon --repo-root {tree}")
        client.cond.read_pid.return_value = 7
        client.cond.pid_alive.side_effect = [True, False, False]
        client.cond.wait_until_stopped.return_value = True
        self.assertEqual(client.stop_daemon({"pid": 7, "processStart": "T1"}), {"stoppedPid": 7})
        client.cond.bootout_daemon_launchd.assert_not_called()
        client.cond.daemon_launchd_label.return_value = "com.example.label"
        for code, expected in ((0, True), (bench.LAUNCHCTL_SERVICE_NOT_FOUND, False), (1, None), (127, None)):
            with self.subTest(code=code):
                client.cond.run_launchctl.return_value = code
                self.assertIs(client.launchd_loaded(), expected)
                self.assertEqual(client.cond.run_launchctl.call_args[0][0],
                                 ["print", f"gui/{os.getuid()}/com.example.label"])


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self.tmp.name)
        (self.tree / "Tests" / "RepoPromptTests").mkdir(parents=True)
        (self.tree / "Sources" / "RepoPrompt" / "Support").mkdir(parents=True)
        (self.tree / "Tests" / "RepoPromptTests" / "OtherTests.swift").write_text("final class OtherTests {}\n")
        self.manifest = bench.load_fixture_manifest()
        self.busy = None
        self.ledger = bench.FixtureLedger(self.tree, self.manifest, busy_check=lambda: self.busy)
        self.ledger.install()

    def tearDown(self):
        self.tmp.cleanup()

    def probe_text(self, name):
        return (self.tree / self.manifest["probes"][name]["insertPath"]).read_text()

    def test_templates_are_hash_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp)
            for item in bench.FIXTURE_DIR.iterdir():
                (copy / item.name).write_bytes(item.read_bytes())
            bench.load_fixture_manifest(copy / "manifest.json")
            (copy / "BuildPipelineBenchmarkAppProbe.swift.template").write_text("changed")
            with self.assertRaisesRegex(bench.HarnessError, "hash"):
                bench.load_fixture_manifest(copy / "manifest.json")

    def test_variants_change_exactly_the_intended_tokens(self):
        before = self.probe_text("test-probe")
        self.ledger.toggle("test-body")
        after = self.probe_text("test-probe")
        self.assertNotEqual(before, after)
        self.assertIn("rpceBenchmarkBroadProbeA", after)
        self.ledger.toggle("broad")
        self.assertIn("rpceBenchmarkBroadProbeB", self.probe_text("test-probe"))
        app = self.probe_text("app-probe")
        self.ledger.toggle("app-body")
        self.assertNotEqual(app, self.probe_text("app-probe"))
        self.assertNotIn("{{", self.probe_text("app-probe"))

    def test_byte_fence_refuses_unexpected_edits(self):
        path = self.tree / self.manifest["probes"]["test-probe"]["insertPath"]
        path.write_text(path.read_text() + "// foreign edit\n")
        with self.assertRaisesRegex(bench.HarnessError, "fixture fence"):
            self.ledger.toggle("test-body")
        self.assertIn("foreign edit", path.read_text(), "unexpected edit preserved, not reset")

    def test_mtime_fence(self):
        path = self.tree / self.manifest["probes"]["app-probe"]["insertPath"]
        os.utime(path, ns=(1, 1))
        with self.assertRaisesRegex(bench.HarnessError, "fixture fence"):
            self.ledger.verify_all()

    def test_no_edit_while_owned_jobs_active(self):
        self.busy = "owned jobs not terminal: ['t1']"
        before = self.probe_text("test-probe")
        with self.assertRaisesRegex(bench.HarnessError, "refusing fixture"):
            self.ledger.toggle("test-body")
        with self.assertRaisesRegex(bench.HarnessError, "refusing fixture"):
            self.ledger.touch_tests()
        self.assertEqual(before, self.probe_text("test-probe"))

    def test_session_busy_reason_blocks_on_open_tickets_and_daemon_jobs(self):
        session = make_session(self.tree / "s")
        self.assertIsNone(session.busy_reason(ON))
        session.open_tickets["t"] = ON
        self.assertIn("not terminal", session.busy_reason(ON))
        session.open_tickets.clear()
        session.clients[ON].daemon_status = lambda: {"runningJobs": [{}], "queuedJobs": []}
        self.assertIn("active jobs", session.busy_reason(ON))

    def test_input_add_remove(self):
        self.assertFalse(self.ledger.input_present())
        with self.assertRaisesRegex(bench.HarnessError, "non-present"):
            self.ledger.remove_input()
        self.ledger.add_input()
        self.assertTrue(self.ledger.input_present())
        self.ledger.remove_input()
        self.assertFalse((self.tree / self.manifest["probes"]["input-probe"]["insertPath"]).exists())
        self.ledger.verify_all()

    def test_touch_tests_changes_mtime_not_content(self):
        other = self.tree / "Tests" / "RepoPromptTests" / "OtherTests.swift"
        content = other.read_bytes()
        os.utime(other, ns=(5, 5))
        event = self.ledger.touch_tests()
        self.assertEqual(other.read_bytes(), content)
        self.assertNotEqual(other.stat().st_mtime_ns, 5)
        self.assertEqual(event["files"], 2)
        self.ledger.verify_all()

    def test_probe_membership_against_the_real_package(self):
        package = (bench.REPO_ROOT / "Package.swift").read_text()
        evidence = bench.verify_probe_membership(package, self.manifest)
        self.assertEqual(evidence["app-probe"]["target"], "RepoPromptApp")
        self.assertEqual(evidence["test-probe"]["target"], "RepoPromptTests")

    def test_membership_refuses_filtered_or_moved_targets(self):
        moved = '.testTarget(name: "RepoPromptTests", path: "Tests/Elsewhere")\n.target(name: "RepoPromptApp", path: "Sources/RepoPrompt")'
        with self.assertRaisesRegex(bench.HarnessError, "path"):
            bench.verify_probe_membership(moved, self.manifest)
        filtered = ('.testTarget(name: "RepoPromptTests", path: "Tests/RepoPromptTests", exclude: ["X"])\n'
                    '.target(name: "RepoPromptApp", path: "Sources/RepoPrompt")')
        with self.assertRaisesRegex(bench.HarnessError, "exclude"):
            bench.verify_probe_membership(filtered, self.manifest)
        nested = ('.testTarget(name: "RepoPromptTests", path: "Tests/RepoPromptTests")\n'
                  '.target(name: "RepoPromptApp", path: "Sources/RepoPrompt")\n'
                  '.target(name: "Support", path: "Sources/RepoPrompt/Support")')
        with self.assertRaisesRegex(bench.HarnessError, "also lies in"):
            bench.verify_probe_membership(nested, self.manifest)

    def test_source_suite_fallback_admits_the_probe(self):
        import conductor

        suite = self.manifest["probes"]["test-probe"]["suite"]
        self.assertEqual(suite, bench.PROBE_SUITE)
        rows = conductor._ledger_filter_rows(bench.REPO_ROOT, "test")
        self.assertNotIn(suite, {s.rsplit(".", 1)[-1] for s, _m in rows}, "probe must not be in the curated ledger")
        self.assertTrue(conductor._source_contains_suite(self.tree / "Tests" / "RepoPromptTests", suite))
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RPCE_ALLOW_UNKNOWN_FILTER", None)
            with mock.patch.object(conductor, "_ledger_filter_rows", return_value=rows), mock.patch("sys.stderr"):
                conductor.preflight_test_filter(self.tree, "test", suite)
                conductor.preflight_test_filter(self.tree, "test-artifact", suite)
                with self.assertRaises(conductor.FilterPreflightError):
                    conductor.preflight_test_filter(self.tree, "test", "BuildPipelineBenchmarkMissingTests")


class ThermalObserverTests(unittest.TestCase):
    def observer(self, reader, **kw):
        kw.setdefault("interval", 0.01)
        kw.setdefault("max_gap", 0.5)
        kw.setdefault("join_timeout", 1.0)
        kw.setdefault("start_timeout", 1.0)
        return bench.ThermalObserver(reader, time.monotonic, **kw)

    def test_delayed_submission_is_covered_end_to_end(self):
        observer = self.observer(lambda: "nominal")
        observer.start()
        time.sleep(0.05)  # submission delayed after the first reading
        observer.mark("submitStart")
        time.sleep(0.1)
        observer.mark("terminalObserved")
        summary = observer.finish()
        self.assertTrue(summary["coverage"], summary["coverageReasons"])
        self.assertLessEqual(summary["firstAt"], summary["marks"]["submitStart"])
        self.assertGreaterEqual(summary["lastAt"], summary["marks"]["terminalObserved"])
        self.assertGreater(summary["samples"], 3)
        self.assertFalse(observer._thread.is_alive())
        self.assertEqual(len(observer.raw()["observations"]), summary["samples"])

    def test_gaps_unknown_errors_and_exhaustion_invalidate(self):
        def slow():
            time.sleep(0.08)
            return "nominal"

        values = iter(["nominal", "weird"] + ["nominal"] * 1000)
        failing = iter([None])

        def flaky():
            if next(failing, "ok") is None:
                return "nominal"
            raise OSError("ioreg")

        cases = [
            (self.observer(slow, max_gap=0.05), "gap_exceeded"),
            (self.observer(lambda: next(values)), "unknown"),
            (self.observer(flaky), "observer_error"),
            (self.observer(lambda: "nominal", max_observations=2), "exhausted"),
        ]
        for observer, reason in cases:
            with self.subTest(reason=reason):
                observer.start()
                observer.mark("submitStart")
                time.sleep(0.12)
                observer.mark("terminalObserved")
                summary = observer.finish()
                if reason == "unknown":
                    # Unknown readings invalidate the sample through evaluate_sample (thermal_unknown).
                    self.assertGreaterEqual(summary["unknown"], 1)
                    payload = job_payload("t")
                    evaluation = bench.evaluate_sample(bench.SCENARIOS["null-test"], payload, payload["phaseMetrics"],
                                                       True, summary, "D", "F")
                    self.assertIn("thermal_unknown", evaluation["invalidReasons"])
                else:
                    self.assertFalse(summary["coverage"])
                    self.assertIn(reason, summary["coverageReasons"])

    def test_missing_boundaries_and_late_first_reading(self):
        observer = self.observer(lambda: "nominal")
        observer.start()
        summary = observer.finish()
        self.assertIn("boundaries_missing", summary["coverageReasons"])
        gate = threading.Event()
        blocked = self.observer(lambda: gate.wait(5) and "nominal", start_timeout=0.05)
        with self.assertRaisesRegex(bench.HarnessError, "first reading"):
            blocked.start()
        gate.set()
        blocked.finish()

    def test_join_failure_is_bounded_and_reported(self):
        release = threading.Event()
        calls = {"n": 0}

        def reader():
            calls["n"] += 1
            if calls["n"] >= 2:
                release.wait(5)
            return "nominal"

        observer = self.observer(reader, join_timeout=0.05)
        observer.start()
        observer.mark("submitStart")
        time.sleep(0.03)
        observer.mark("terminalObserved")
        started = time.monotonic()
        summary = observer.finish()
        self.assertLess(time.monotonic() - started, 4.0, "finish must not stall on a stuck reader")
        release.set()
        self.assertTrue(summary["joinFailed"])
        self.assertIn("join_failed", summary["coverageReasons"])


def installed_session(tmp: Path):
    """A session whose arms have real, installed fixture ledgers."""
    session = make_session(tmp)
    manifest = bench.load_fixture_manifest()
    for arm in bench.ARMS:
        (tmp / "tree" / arm / "Tests" / "RepoPromptTests").mkdir(parents=True)
        (tmp / "tree" / arm / "Sources" / "RepoPrompt" / "Support").mkdir(parents=True)
        session.ledgers[arm] = bench.FixtureLedger(tmp / "tree" / arm, manifest, busy_check=lambda: None)
        session.ledgers[arm].install()
    return session, manifest


class SessionRegressionTests(unittest.TestCase):
    def test_thermal_raw_is_persisted_and_coverage_gates_validity(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            result = session.run_job(ON, bench.SCENARIOS["null-test"], "measured", {})
            self.assertTrue(result["valid"], result["invalidReasons"])
            raw = json.loads((session.capture.root / result["rawThermal"]).read_text())
            self.assertEqual(len(raw["observations"]), 2)
            self.assertTrue(raw["summary"]["coverage"])
            client = result["measures"]["clientObserved"]
            self.assertEqual(client["interval"], bench.SECONDARY_CLIENT_INTERVAL)
            self.assertEqual(client["pollIntervalSeconds"], bench.TERMINAL_POLL_S)

    def test_observer_join_failure_appends_the_invalid_result_then_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = FakeClock()

            class Stuck(FakeObserver):
                def finish(self):
                    summary = super().finish()
                    self.join_failed = True
                    return self.summary()

            session = make_session(Path(tmp), clock=clock, observer_factory=lambda: Stuck(clock))
            with self.assertRaisesRegex(bench.HarnessError, "thermal observer"):
                session.run_job(ON, bench.SCENARIOS["null-test"], "measured", {})
            result = [row for row in attempts(session.capture) if row["phase"] == "result"][-1]
            self.assertFalse(result["valid"])
            self.assertIn("thermal_coverage_incomplete", result["invalidReasons"])

    def test_daemon_identity_change_appends_the_invalid_result_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            client = session.clients[ON]
            session.run_job(ON, bench.SCENARIOS["null-test"], "measured", {})
            original = client.daemon_status
            client.daemon_status = lambda: {**original(), "pid": 43}
            with self.assertRaisesRegex(bench.HarnessError, "identity changed"):
                session.run_job(ON, bench.SCENARIOS["null-test"], "measured", {})
            last = [row for row in attempts(session.capture) if row["phase"] == "result"][-1]
            self.assertIn("daemon_identity_changed", last["invalidReasons"])

    def test_durable_request_records_track_intent_acceptance_and_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = bench.OwnershipStore(Path(tmp) / "own.json", {"runId": "t"})
            session = make_session(Path(tmp), store=store)
            session.clients[ON].submit_errors = ["accepted-then-lost"]
            result = session.run_job(ON, bench.SCENARIOS["null-test"], "measured", {})
            record = json.loads((Path(tmp) / "own.json").read_text())["requests"][result["requestKey"]]
            self.assertEqual(record["state"], "terminal")
            self.assertTrue(record["recovered"])
            self.assertTrue(record["producer"]["finished"])
            states = [t["state"] for t in store.data["transitions"] if t["subject"] == result["requestKey"]]
            self.assertEqual(states, ["intent", "accepted", "terminal"])

    def test_failed_edit_attempt_rebuilds_the_pre_edit_state_before_retrying(self):
        with tempfile.TemporaryDirectory() as tmp:
            session, manifest = installed_session(Path(tmp))
            probe = Path(tmp) / "tree" / ON / manifest["probes"]["test-probe"]["insertPath"]
            pre_edit = probe.read_bytes()
            seen = []
            outcomes = iter([False])

            def run_job(arm, recipe, kind, context):
                seen.append((arm, kind, probe.read_bytes() == pre_edit if arm == ON else None))
                valid = next(outcomes, True) if (arm == ON and kind == "measured") else True
                return {"attemptId": str(len(seen)), "arm": arm, "valid": valid, "state": "failed" if not valid
                        else "completed", "exitCode": 1 if not valid else 0, "load1": 1.0,
                        "invalidReasons": [] if valid else ["job_failed_exit_1"],
                        "measures": {"primarySeconds": 10.0}}

            session.run_job = run_job
            samples = session.run_block(bench.SCENARIOS["test-body"], 0, 1)
            self.assertIsNotNone(samples)
            on_jobs = [(kind, pristine) for arm, kind, pristine in seen if arm == ON]
            # Failed transition, then an unmeasured build of the restored pre-edit state, then the same transition.
            self.assertEqual(on_jobs[:3], [("measured", False), ("retry-baseline", True), ("measured", False)])
            self.assertEqual(session.invalid_attempts, 1)
            restores = [row for row in attempts(session.capture) if row["phase"] == "retry_baseline"]
            self.assertEqual(len(restores), 1)

    def test_retry_baseline_primers_are_bounded_separately(self):
        with tempfile.TemporaryDirectory() as tmp:
            session, _manifest = installed_session(Path(tmp))
            target = session.ledgers[ON].state()
            session.ledgers[ON].toggle("test-body")
            session.pending_restore[ON] = target
            calls = []

            def run_job(arm, recipe, kind, context):
                calls.append(kind)
                return {"attemptId": "x", "arm": arm, "valid": False, "state": "failed", "exitCode": 1,
                        "invalidReasons": ["job_failed_exit_1"], "measures": {"primarySeconds": None}}

            session.run_job = run_job
            with self.assertRaisesRegex(bench.HarnessError, "retry-baseline"):
                session.restore_baseline(ON, bench.SCENARIOS["test-body"], {})
            self.assertEqual(calls, ["retry-baseline"] * bench.RETRY_BASELINE_ATTEMPTS)

    def test_diagnostic_scenarios_are_recorded_never_calibrated_or_extended(self):
        with tempfile.TemporaryDirectory() as tmp:
            session = make_session(Path(tmp))
            values = {ON: 10.0, SKIP: 30.0}

            def run_job(arm, recipe, kind, context):
                return {"attemptId": f"{arm}{len(session.capture.root.name)}", "arm": arm, "valid": True,
                        "state": "completed", "exitCode": 0, "load1": 2.0, "ticket": "t",
                        "measures": {"primarySeconds": values[arm], "clientObserved": {"seconds": 11.0}}}

            session.run_job = run_job
            session.on_cold_reset = lambda arm: None
            result = session.run_scenario(bench.SCENARIOS["cold"])
            self.assertEqual((result["verdict"], result["comparison"], result["extended"]), ("recorded", None, False))
            self.assertEqual(result["statisticalRole"], bench.ROLE_DIAGNOSTIC)
            self.assertEqual(result["blocksRetained"], bench.DEFAULT_BLOCKS)


class WorkEvidenceTests(unittest.TestCase):
    TEST_SEGMENT = {"compileRecords": 1, "modules": {"RepoPromptTests": {"compiledFiles": 1, "emittedModule": True,
                                                                         "exact": True}},
                    "linkedProducts": ["RepoPromptCEPackageTests"], "modulesPartial": False, "compiledFilesExact": True}
    NULL_SEGMENT = {"compileRecords": 0, "modules": {}, "linkedProducts": [], "modulesPartial": False,
                    "compiledFilesExact": True}

    def test_declared_work_is_proven_from_segments(self):
        self.assertEqual(bench.work_evidence(bench.TEST_COMPILE, [self.TEST_SEGMENT])[0], [])
        self.assertEqual(bench.work_evidence(bench.NO_WORK, [self.NULL_SEGMENT])[0], [], "null builds are exempt")
        self.assertEqual(bench.work_evidence(bench.NO_WORK, [])[0], [])
        self.assertEqual(bench.work_evidence(bench.TEST_COMPILE, [self.NULL_SEGMENT])[0],
                         ["work_missing_compile_RepoPromptTests", "work_missing_link_RepoPromptCEPackageTests"])
        self.assertEqual(bench.work_evidence(bench.TEST_COMPILE, [])[0], ["work_unknown_no_segments"])
        partial = dict(self.NULL_SEGMENT, modulesPartial=True, linkedProducts=None)
        self.assertEqual(bench.work_evidence(bench.TEST_COMPILE, [partial])[0],
                         ["work_unknown_compile_RepoPromptTests", "work_unknown_link_RepoPromptCEPackageTests"])
        app = bench.SCENARIOS["app-body"].work
        self.assertEqual(bench.work_evidence(app, [self.TEST_SEGMENT])[0],
                         ["work_missing_compile_RepoPromptApp", "work_missing_link_RepoPrompt"])

    def test_edit_samples_without_compile_evidence_are_invalid(self):
        payload = job_payload("t", metrics={**phase_metrics(), "segments": [self.NULL_SEGMENT]})
        result = bench.evaluate_sample(bench.SCENARIOS["test-body"], payload, payload["phaseMetrics"], True,
                                       SampleEvaluationTests.thermal_ok, "D", "F")
        self.assertIn("work_missing_compile_RepoPromptTests", result["invalidReasons"])
        payload = job_payload("t", metrics={**phase_metrics(), "segments": [self.TEST_SEGMENT]})
        result = bench.evaluate_sample(bench.SCENARIOS["test-body"], payload, payload["phaseMetrics"], True,
                                       SampleEvaluationTests.thermal_ok, "D", "F")
        self.assertTrue(result["valid"], result["invalidReasons"])
        self.assertEqual(result["measures"]["work"]["linkedProducts"], ["RepoPromptCEPackageTests"])


class BoundaryTests(unittest.TestCase):
    def test_main_daemon_socket_present_is_never_idle_even_without_a_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            sock = Path(tmp) / "sock"
            sock.write_text("")
            paths = SimpleNamespace(pid_path=Path(tmp) / "pid", socket_path=sock)
            cond = mock.Mock()
            cond.compute_paths.return_value = paths
            cond.read_pid.return_value = None
            cond.pid_alive.return_value = False
            cond.PROTOCOL_VERSION = 15
            cond.request_daemon.side_effect = Exception("connection refused")
            self.assertEqual(bench.HostProbe(cond, Path(tmp), {}).main_daemon()["state"], "unknown")

    def test_slot_probe_opens_without_following_links_and_creates_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "elsewhere"
            link = root / "global-heavy-0.lock"
            link.symlink_to(target)
            self.assertEqual(bench.probe_slot_files([link])["state"], "error")
            self.assertFalse(target.exists(), "a dangling symlink target must not be created")
            fresh = root / "global-xctest-0.lock"
            old = os.umask(0)
            try:
                bench.probe_slot_files([fresh])
            finally:
                os.umask(old)
            self.assertEqual(stat.S_IMODE(fresh.stat().st_mode), 0o600)
            fifo = root / "global-heavy-1.lock"
            os.mkfifo(fifo)
            self.assertEqual(bench.probe_slot_files([fifo])["state"], "error")

    def test_environment_class_normalizes_destinations_and_never_stores_values(self):
        tree_a, tree_b = Path("/s/worktrees/ab-on"), Path("/s/worktrees/ab-skip")
        keys = ["PATH", "REPOPROMPT_SENTRY_DSN", *bench.DESTINATION_KEYS]
        env_a = {"PATH": "/bin", "REPOPROMPT_SENTRY_DSN": "secret-dsn", **bench.scratch_destinations(tree_a)}
        env_b = {"PATH": "/bin", "REPOPROMPT_SENTRY_DSN": "secret-dsn", **bench.scratch_destinations(tree_b)}
        a = bench.environment_class(env_a, tree_a, keys)
        b = bench.environment_class(env_b, tree_b, keys)
        self.assertEqual(a["class"], b["class"])
        self.assertNotIn("secret-dsn", json.dumps(a))
        self.assertIn("RPCE_DEBUG_DSYM", a["keys"])
        changed = bench.environment_class({**env_b, "REPOPROMPT_SENTRY_DSN": "other"}, tree_b, keys)
        self.assertNotEqual(a["class"], changed["class"])

    def test_state_inventory_records_names_and_sizes_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "jobs").mkdir()
            (root / "jobs" / "a.log").write_text("token=supersecret")
            inventory = bench.state_inventory(root)
            self.assertEqual((inventory["exists"], inventory["entries"]), (True, 1))
            self.assertNotIn("supersecret", json.dumps(inventory))
            self.assertEqual(bench.state_inventory(root / "missing"), {"exists": False})

    def test_diag_driver_is_sole_capability_checked_and_diagnostic(self):
        recipe = bench.SCENARIOS["diag-driver"]
        self.assertEqual((recipe.role, recipe.sole, recipe.instrumentation),
                         (bench.ROLE_DIAGNOSTIC, True, bench.INSTRUMENTATION_DRIVER))
        self.assertIn(bench.DIAG_CLI_FLAG, recipe.cli_args)
        self.assertIs(recipe.expected_args[bench.DIAG_ARG_KEY], True)
        ns = argparse.Namespace(instrumentation="full", dsym_mode="on", blocks=5, name="d", scenarios="diag-driver",
                                ref="HEAD", calibration=None)
        self.assertEqual([r.name for r in bench.validate_request(ns, {})], ["diag-driver"])
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(["init", "-q"], repo)
            (repo / "Scripts").mkdir()
            (repo / "Scripts" / "conductor.py").write_text("# old conductor without the route\n")
            git(["add", "-A"], repo)
            git(["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "a"], repo)
            old = git(["rev-parse", "HEAD"], repo).strip()
            with self.assertRaisesRegex(bench.HarnessError, "lacks the coordinated"):
                bench.check_capabilities([recipe], repo, old)
            (repo / "Scripts" / "conductor.py").write_text(
                f"{bench.DIAG_ROUTE_MARKER} = ()\nparser.add_argument('{bench.DIAG_CLI_FLAG}')\n")
            git(["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qam", "b"], repo)
            new = git(["rev-parse", "HEAD"], repo).strip()
            evidence = bench.check_capabilities([recipe], repo, new)
            self.assertEqual(evidence["diag-driver"]["capability"], bench.DIAG_ROUTE_MARKER)
            self.assertEqual(bench.check_capabilities([bench.SCENARIOS["null-test"]], repo, old), {})

    def test_the_real_conductor_provides_the_diag_route(self):
        text = (bench.REPO_ROOT / "Scripts" / "conductor.py").read_text()
        self.assertIn(bench.DIAG_ROUTE_MARKER, text)
        self.assertIn(bench.DIAG_CLI_FLAG, text)

    def test_default_skip_targets_are_refused_and_legacy_full_targets_accepted(self):
        """A Step 10 default-skip wrapper would run unset (= off) arms labeled full/on: refuse it."""
        commit = ["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q"]
        legacy = "#!/bin/bash\nexec /usr/bin/env -i \"${swift_env[@]}\" /usr/bin/swift \"$@\"\n"
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(["init", "-q"], repo)
            with self.assertRaisesRegex(bench.HarnessError, "no readable"):
                bench.check_full_dsym_target(repo, "HEAD")
            (repo / "Scripts").mkdir()
            (repo / "Scripts" / "canonical_swift.sh").write_text(legacy)
            git(["add", "-A"], repo)
            git([*commit, "-m", "legacy"], repo)
            legacy_rev = git(["rev-parse", "HEAD"], repo).strip()
            (repo / "Scripts" / "canonical_swift.sh").write_text(
                "#!/bin/bash\nswift_env+=(\"SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true\")\n" + legacy)
            git([*commit, "-am", "skip"], repo)
            skip_rev = git(["rev-parse", "HEAD"], repo).strip()
            (repo / "Scripts" / "canonical_swift.sh").write_text(legacy)
            (repo / "Scripts" / "debug_dsym.py").write_text("# helper\n")
            git(["add", "-A"], repo)
            git([*commit, "-m", "helper"], repo)
            helper_rev = git(["rev-parse", "HEAD"], repo).strip()
            self.assertIsNone(bench.check_full_dsym_target(repo, legacy_rev))
            for rev in (skip_rev, helper_rev):
                with self.subTest(rev=rev), self.assertRaisesRegex(bench.HarnessError, "private lean Step 10 recipe"):
                    bench.check_full_dsym_target(repo, rev)
            patches = dict(validate_request=[bench.SCENARIOS["null-test"]], load_fixture_manifest={},
                           collect_host=dict(FIXTURE_HOST), thermal_state="nominal",
                           resolve_main_repo=(repo, {}), git_ok=skip_rev, verify_probe_membership={},
                           check_capabilities={})
            with mock.patch.multiple(bench, **{name: mock.DEFAULT for name in patches}) as mocks, \
                    mock.patch.object(bench, "load_conductor", side_effect=AssertionError("mutation path reached")), \
                    mock.patch.object(bench, "WorktreeOwner", side_effect=AssertionError("mutation path reached")), \
                    mock.patch("sys.stderr") as stderr:
                for name, value in patches.items():
                    mocks[name].return_value = value
                self.assertEqual(bench.main(["run", "--instrumentation", "full"]), bench.EXIT_HARNESS_FAILURE)
            self.assertIn("skips debug dSYM generation by default",
                          "".join(str(call.args[0]) for call in stderr.write.call_args_list if call.args))

    def test_the_accepted_legacy_full_baseline_stays_supported(self):
        accepted = "d8c5c6abc93b7d30ef85db4b160e96e013e78478"
        present = subprocess.run(["git", "cat-file", "-e", f"{accepted}^{{commit}}"], cwd=str(bench.REPO_ROOT),
                                 capture_output=True).returncode == 0
        if not present:
            self.skipTest("accepted legacy baseline commit is not in this clone")
        self.assertIsNone(bench.check_full_dsym_target(bench.REPO_ROOT, accepted))

    def test_the_working_wrapper_is_recognized_as_default_skip(self):
        text = (bench.REPO_ROOT / "Scripts" / "canonical_swift.sh").read_text()
        self.assertTrue(any(marker in text for marker in bench.DEFAULT_SKIP_WRAPPER_MARKERS))


class ExtractTests(unittest.TestCase):
    def test_extract_is_read_only_and_outside_the_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cap = make_capture(root, "cap", 5.0, 5.1)
            before = bench.file_manifest(Path(cap))
            with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                self.assertEqual(bench.main(["extract", "--capture", cap, "--out", str(Path(cap) / "x")]), 3)
                self.assertEqual(bench.main(["extract", "--capture", cap, "--out", str(root / "out")]), 0)
            self.assertEqual(bench.file_manifest(Path(cap)), before)
            meta = json.loads((root / "out" / "extract-meta.json").read_text())
            self.assertTrue(meta["captureUnchanged"])
            self.assertEqual(meta["resultRows"], 20)
            mapping = json.loads((root / "out" / "retained-map.json").read_text())
            self.assertEqual(len(mapping["null-test"]["retainedBlocks"]), 5)
            lines = (root / "out" / "attempts.csv").read_text().splitlines()
            self.assertEqual(len(lines), 21)
            listed = (root / "out" / "extract-files.sha256").read_text()
            self.assertIn("attempts.csv", listed)



class ConductorParityTests(unittest.TestCase):
    def test_expected_fingerprint_matches_the_real_conductor_request_identity(self):
        import conductor

        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(os.path.realpath(tmp))
            env = {"PATH": "/usr/bin:/bin", "HOME": "/Users/x", "REPOPROMPT_SENTRY_DSN": "dsn",
                   "UNRELATED": "ignored", **bench.scratch_destinations(tree)}
            client = bench.ConductorClient(conductor, tree, env)
            for name in ("null-test", "artifact", "diag-driver", "null-app"):
                recipe = bench.SCENARIOS[name]
                with mock.patch.dict(os.environ, env, clear=True):
                    snapshot = conductor.OperationRegistry.client_env_snapshot()
                request = {"type": "enqueue", "operation": recipe.operation, "args": dict(recipe.expected_args),
                           "requestKey": "k", "timeout": None, "verbose": False, "env": snapshot}
                registry = conductor.OperationRegistry(tree, jobs_dir=Path(client.paths.jobs_dir))
                with self.subTest(name=name):
                    self.assertEqual(client.expected_fingerprint(recipe), registry.fingerprint(request))
            other = bench.ConductorClient(conductor, tree, {**env, "REPOPROMPT_SENTRY_DSN": "other"})
            self.assertNotEqual(other.expected_fingerprint(bench.SCENARIOS["null-test"]),
                                client.expected_fingerprint(bench.SCENARIOS["null-test"]))


class RunnerProvenanceTests(unittest.TestCase):
    def test_runner_inventory_covers_every_loaded_scripts_module(self):
        """S9-R1-01: every Scripts module the runner loads (including via conductor) is hash-checked."""
        bench.load_conductor()
        # This test module is the unittest __main__ here; the harness runner never loads it.
        loaded = [rel for rel in bench.loaded_script_modules() if rel != f"Scripts/{Path(__file__).name}"]
        self.assertIn("Scripts/debug_app_process.py", loaded)
        self.assertIn("Scripts/conductor.py", loaded)
        inventory = set(bench.HARNESS_FILES) | set(bench.RUNNER_IMPORTED_FILES)
        self.assertEqual(sorted(set(loaded) - inventory), [])
        self.assertEqual(set(bench.required_harness_files()), inventory)


class RecoveryInputTests(unittest.TestCase):
    def test_v1_ownership_is_normalized_without_rewriting_the_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = bench.Capture(Path(tmp) / "cap")
            capture.create()
            rows = [{"phase": "intent", "requestKey": "k1", "arm": ON},
                    {"phase": "submitted", "requestKey": "k1", "arm": ON, "ticket": "t1"},
                    {"phase": "result", "requestKey": "k1", "arm": ON, "ticket": "t1", "state": "completed"},
                    {"phase": "intent", "requestKey": "k2", "arm": SKIP},
                    {"phase": "submitted", "requestKey": "k3", "arm": SKIP, "ticket": "t3"}]
            capture.attempts.write_text("".join(json.dumps(row) + "\n" for row in rows))
            v1 = {"runId": "r", "arms": {ON: {"path": "/p", "daemon": {"pid": 1}}}, "state": "active"}
            original = json.dumps(v1)
            data = bench.normalize_v1_ownership(v1, capture)
            self.assertEqual(json.dumps(v1), original)
            self.assertEqual((data["schema"], data["normalizedFrom"]), (bench.OWNERSHIP_SCHEMA_VERSION, 1))
            self.assertEqual({k: r["state"] for k, r in data["requests"].items()},
                             {"k1": "terminal", "k2": "intent", "k3": "accepted"})
            self.assertIsNone(data["requests"]["k2"]["producer"])
            self.assertEqual(data["arms"][ON]["cleanup"], "active")

    def test_main_repo_must_be_the_original_top_level_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(os.path.realpath(tmp)) / "repo"
            repo.mkdir()
            git(["init", "-q"], repo)
            (repo / "sub").mkdir()
            (repo / "f").write_text("x")
            git(["add", "-A"], repo)
            git(["-c", "user.email=t@e", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "a"], repo)
            with mock.patch.object(bench, "REPO_ROOT", repo):
                root, meta = bench.resolve_main_repo(str(repo))
                self.assertEqual((root, meta["runnerIsMain"]), (repo, True))
                with self.assertRaisesRegex(bench.HarnessError, "top level"):
                    bench.resolve_main_repo(str(repo / "sub"))
                linked = Path(os.path.realpath(tmp)) / "linked"
                git(["worktree", "add", "-q", "--detach", str(linked)], repo)
                with self.assertRaisesRegex(bench.HarnessError, "linked worktree"):
                    bench.resolve_main_repo(str(linked))
                with self.assertRaisesRegex(bench.HarnessError, "not a directory"):
                    bench.resolve_main_repo(str(repo / "missing"))


if __name__ == "__main__":
    unittest.main()
