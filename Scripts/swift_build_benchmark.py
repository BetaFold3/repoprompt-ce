#!/usr/bin/env python3
"""Swift build benchmark harness (build-pipeline plan, Step 9; OD22/OD23).

A **slot-free, synchronous foreground orchestrator**. It never holds a machine
job slot, never runs Swift itself, and never edits the main checkout's sources.

Execution path::

    runner -> <worktree>/conductor --async --json -> that worktree's own daemon
           -> coordinated job -> canonical_swift.sh
           -> finalized phaseMetrics (Step 2/8 schema) -> paired statistics

Subcommands:

* ``run``      create two detached same-SHA worktrees ``ab-on`` / ``ab-skip``
               under ``<state>/benchmarks/worktrees/``, run primers and balanced
               ABBA blocks per scenario, evaluate A/A calibration (gating
               scenarios only), then clean up resumably.
* ``compare``  paired comparison of two arms of ONE capture (``CAPTURE#arm``)
               with the plan's regression floors; a regression needs a second,
               distinct capture's own paired arms whose paired CI lies above 0.
* ``clean``    resume cleanup of the recorded benchmark worktrees after the same
               ownership checks the run itself uses.
* ``extract``  read-only auditable extract (per-attempt rows, retained/discarded
               mapping, file SHA-256 manifest) of any capture.

Exit codes (shared with ``swift_pipeline_metrics``): 0 all requested
calibrations/comparisons qualified (or diagnostics recorded) with evidence and
cleanup complete, 1 confirmed regression (``compare`` only), 2 inconclusive or
well-formed but ineligible, 3 harness, integrity, ownership, malformed-input or
cleanup failure.

Step 9 wrapper capability is ``legacy-full-only``: both arms run the existing
full-dSYM wrapper (``requested=full``, ``effective=on``, ``treatment=none``).
The arm names are worktree *locations*, not treatments. An ``off`` request is
rejected before any mutation; Step 10 extends the capability only after the
wrapper switch is implemented and verified.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import ctypes
import ctypes.util
import dataclasses
import datetime as _dt
import errno
import fcntl
import hashlib
import json
import math
import os
import platform
import re
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import swift_pipeline_metrics as metrics  # noqa: E402

HARNESS_VERSION = 2
CAPTURE_SCHEMA_VERSION = 2
LEGACY_CAPTURE_SCHEMAS = frozenset({1})
OWNERSHIP_SCHEMA_VERSION = 2
FIXTURE_DIR = SCRIPT_DIR / "Fixtures" / "swift-build-benchmark" / "v1"
FIXTURE_MANIFEST = FIXTURE_DIR / "manifest.json"
HARNESS_FILES = (
    "Scripts/swift_build_benchmark.py",
    "Scripts/Fixtures/swift-build-benchmark/v1/manifest.json",
    "Scripts/Fixtures/swift-build-benchmark/v1/BuildPipelineBenchmarkProbeTests.swift.template",
    "Scripts/Fixtures/swift-build-benchmark/v1/BuildPipelineBenchmarkAppProbe.swift.template",
    "Scripts/Fixtures/swift-build-benchmark/v1/BuildPipelineBenchmarkInputProbe.swift.template",
)
# The runner imports these from its own checkout (directly or through
# ``conductor``); a qualification run must use the same bytes as the measured
# commit. ``harness_provenance`` also adds any other loaded Scripts module.
RUNNER_IMPORTED_FILES = ("Scripts/conductor.py", "Scripts/swift_pipeline_metrics.py", "Scripts/conductor_output.py",
                         "Scripts/debug_app_process.py")
# Runtime-affecting files of the measured worktree (their bytes come from the
# benchmarked commit). Every conductorDigest input is listed, so a digest change
# is always attributable to an exact path.
RUNTIME_FILES = (
    "conductor",
    "Scripts/conductor.py",
    "Scripts/conductor_entry.py",
    "Scripts/conductor_output.py",
    "Scripts/swift_pipeline_metrics.py",
    "Scripts/debug_app_process.py",
    "Scripts/canonical_swift.sh",
    "Scripts/package_app.sh",
    "Scripts/fast_package_fingerprint.py",
    "Package.swift",
    "Package.resolved",
)
CONDUCTOR_DIGEST_FILES = (
    "Scripts/conductor.py",
    "Scripts/swift_pipeline_metrics.py",
    "Scripts/debug_app_process.py",
    "Scripts/conductor_output.py",
    "Scripts/conductor_entry.py",
)

ARM_ON = "ab-on"
ARM_SKIP = "ab-skip"
ARMS = (ARM_ON, ARM_SKIP)

EXIT_QUALIFIED = metrics.EXIT_QUALIFIED
EXIT_REGRESSION = metrics.EXIT_REGRESSION
EXIT_INCONCLUSIVE = metrics.EXIT_INCONCLUSIVE
EXIT_HARNESS_FAILURE = metrics.EXIT_HARNESS_FAILURE

# Step 9 identity (capture-manifest fields, not job-schema fields).
WRAPPER_CAPABILITY = "legacy-full-only"
POLICY_ENV_KEYS = ("RPCE_DEBUG_DSYM", "SWIFT_DRIVER_DSYMUTIL_EXEC")
FORBIDDEN_ENV_KEYS = ("REPOPROMPT_DEV_DAEMON_STATE_DIR", "REPOPROMPT_DEV_DAEMON_SOCKET")
DESTINATION_KEYS = ("REPOPROMPT_DEBUG_APP_ROOT", "REPOPROMPT_DEBUG_APP_BUNDLE", "REPOPROMPT_DEBUG_CLI_INSTALL_PATH")
# Removed from job environments so filter preflight exercises the source-suite
# fallback and zero-test runs keep failing closed.
SCRUBBED_JOB_ENV_KEYS = ("RPCE_ALLOW_UNKNOWN_FILTER", "RPCE_ALLOW_ZERO_TESTS")
TIMING_ENV_KEY = "RPCE_CONDUCTOR_TIMING"
# Environment-class inventory beyond the conductor's request passthrough keys:
# policy keys, the daemon timing switch and the scrubbed keys (recorded absent).
ENV_CLASS_EXTRA_KEYS = (*POLICY_ENV_KEYS, TIMING_ENV_KEY, *SCRUBBED_JOB_ENV_KEYS)
ENV_DIGEST_DOMAIN = b"rpce-swift-bench-env-v1\0"
ARTIFACT_DERIVED_ARG_KEYS = (
    "artifactPath",
    "artifactFingerprint",
    "artifactScope",
    "artifactScopeDifferences",
    "artifactScopeMessage",
    "artifactTicketSourceSnapshot",
    "buildTicketId",
)
# Conductor messages the harness depends on (pinned by conductor tests).
REQUEST_KEY_NOT_FOUND_TEXT = "no job found for request key"
STOP_REFUSED_ACTIVE_TEXT = "daemon has active or queued jobs"
# ``launchctl print`` exit status for a label that is not loaded in the domain.
LAUNCHCTL_SERVICE_NOT_FOUND = 113

# OD23 narrow driver-diagnostics route (root debug ``test`` only).
DIAG_CLI_FLAG = "--benchmark-driver-diagnostics"
DIAG_ARG_KEY = "benchmarkDriverDiagnostics"
DIAG_ROUTE_MARKER = "BENCHMARK_DRIVER_DIAGNOSTIC_SWIFT_ARGS"
INSTRUMENTATION_FULL = "full"
INSTRUMENTATION_DRIVER = "full+driver-diagnostics"
PACKAGING_GATE = (
    "packaging recipes are refused before any mutation until plan Step 12 qualifies U12 (packaging caches "
    "checkout-local) and actual propagation/readback of all three scratch destinations; OD23 makes that "
    "qualification mandatory before the first packaging job"
)

# Sampling protocol (plan Step 9).
PRIMERS_PER_ARM = 2
DEFAULT_BLOCKS = 5
EXTENDED_BLOCKS = 10
POSITION_RETRIES = 3
PRIMER_RETRIES = 3
RETRY_BASELINE_ATTEMPTS = 3
INVALID_MIN_ATTEMPTS = 20
INVALID_MAX_FRACTION = 0.10
AA_BOUND_ABS_S = 0.150
AA_BOUND_REL = 0.03
MIN_PAIRS = 10
CONFIDENCE = 0.95
BOOTSTRAP_ITERATIONS = 2000
BOOTSTRAP_SEED = 0
PAIR_BLOCK_SIZE = 2
REGRESSION_REL_FLOOR = 0.05
FLOORS_S = {"python": 0.002, "artifact": 0.100, "swift": 0.5, "package": 0.5}
PRIMARY_INTERVAL = "acceptedToLaneRelease"
SECONDARY_CLIENT_INTERVAL = "clientSubmitStartToTerminalObserved"
CONFIRMATION_RULE = (
    "second batch = a distinct eligible capture's own paired arms (same metadata, treatment and calibration "
    "lineage, no shared observations) with >= MIN_PAIRS pairs and paired bootstrap CI low > 0; the 5%-and-"
    "absolute material floor applies to the first batch"
)

# Bounded waits (seconds, monotonic).
READINESS_POLL_S = 1.0
READINESS_TIMEOUT_S = 15 * 60
TERMINAL_POLL_S = 1.0
TERMINAL_TIMEOUT_S = 60 * 60
METRICS_TIMEOUT_S = 60.0
CANCEL_GRACE_S = 5 * 60
SUBMIT_TIMEOUT_S = 120.0
STATUS_RPC_TIMEOUT_S = 10.0
STATUS_RPC_FAILURES = 5
DAEMON_STOP_TIMEOUT_S = 20.0
GIT_TIMEOUT_S = 300.0
MAX_TOUCH_FILES = 5000
THERMAL_INTERVAL_S = 1.0
THERMAL_MAX_GAP_S = 3.0
THERMAL_START_TIMEOUT_S = 5.0
THERMAL_JOIN_TIMEOUT_S = 5.0
# One reading per second over the longest owned lifetime: three submits,
# terminal timeout, cancel grace, plus slack. Exhaustion invalidates.
THERMAL_MAX_OBSERVATIONS = int((3 * SUBMIT_TIMEOUT_S + TERMINAL_TIMEOUT_S + CANCEL_GRACE_S + 600) / THERMAL_INTERVAL_S)

TERMINAL_STATES = frozenset({"completed", "failed", "canceled"})
THERMAL_NAMES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")

ROLE_GATING = "gating"
ROLE_DIAGNOSTIC = "diagnostic"
ARM_CLEANUP_STATES = ("active", "jobsTerminal", "daemonStopped", "removePending", "removed")
REQUEST_STATES = ("intent", "accepted", "terminal", "notAccepted")
# Fixed comparison metadata; missing on both sides is missing evidence.
MANDATORY_META_KEYS = (
    "hardware", "toolchain", "sdk", "arch", "fixture", "command", "testScope", "cacheClass",
    "instrumentationMode", "instrumentationIdentity", "primaryInterval", "statisticalRole",
)
REQUIRED_HOST_KEYS = (
    "physicalCpu", "logicalCpu", "model", "cpuBrand", "memoryBytes", "arch", "osVersion", "osBuild",
    "developerDir", "swiftVersion", "sdkVersion", "sdkPath",
)
# Results that make a job unusable even as an unmeasured state-establishing build.
INTEGRITY_REASONS = ("operation_mismatch", "args_mismatch", "fingerprint_mismatch", "measurement_invalid",
                     "conductor_digest_mismatch", "metrics_persist_error", "metrics_not_finalized")

TESTS_MODULE = "RepoPromptTests"
APP_MODULE = "RepoPromptApp"
TEST_PRODUCT = "RepoPromptCEPackageTests"
APP_PRODUCT = "RepoPrompt"


class HarnessError(Exception):
    """Harness, integrity, ownership or cleanup failure (exit 3)."""


class StopRun(Exception):
    """Stop sampling as inconclusive (exit 2) with a recorded reason."""

    def __init__(self, reason: str, **details: Any) -> None:
        super().__init__(reason)
        self.reason = reason
        self.details = details


class Ineligible(Exception):
    """Well-formed evidence that cannot support a verdict (exit 2)."""

    def __init__(self, reasons: Sequence[str]) -> None:
        super().__init__("; ".join(reasons))
        self.reasons = list(reasons)


# ---------------------------------------------------------------------------
# Scenario recipes


@dataclasses.dataclass(frozen=True)
class WorkSpec:
    """Build work a measured sample must evidence in its Step 8 segments."""

    compiled_modules: Tuple[str, ...] = ()
    linked_products: Tuple[str, ...] = ()

    @property
    def required(self) -> bool:
        return bool(self.compiled_modules or self.linked_products)


NO_WORK = WorkSpec()
TEST_COMPILE = WorkSpec((TESTS_MODULE,), (TEST_PRODUCT,))


@dataclasses.dataclass(frozen=True)
class Recipe:
    name: str
    operation: str
    cli_args: Tuple[str, ...]
    expected_args: Mapping[str, Any]
    edit: str  # none | test-body | app-body | broad | add-input | remove-input | touch-tests
    floor_class: str
    slots: Tuple[str, ...]
    reset: Optional[str] = None  # input-absent | input-present | cold
    setup: Optional[str] = None  # mint-ticket
    primers: int = PRIMERS_PER_ARM
    cache_class: str = "warm-incremental"
    role: str = ROLE_GATING
    work: WorkSpec = NO_WORK
    sole: bool = False  # must be the only scenario of its capture
    capability: Optional[str] = None  # target-commit route the recipe needs
    instrumentation: str = INSTRUMENTATION_FULL
    supported: bool = True
    unsupported_reason: Optional[str] = None


PROBE_SUITE = "BuildPipelineBenchmarkProbeTests"
_TEST = ("test", ("--filter", PROBE_SUITE), {"filter": PROBE_SUITE})
_DIAG_TEST = ("test", ("--filter", PROBE_SUITE, DIAG_CLI_FLAG), {"filter": PROBE_SUITE, DIAG_ARG_KEY: True})
_APP = ("swift-build", ("--product", "RepoPrompt"), {"product": "RepoPrompt"})
_PACKAGE = ("build", (), {})


def _recipe(name: str, base: Tuple[str, Tuple[str, ...], Mapping[str, Any]], **kw: Any) -> Recipe:
    operation, cli_args, expected = base
    slots = kw.pop("slots", ("heavy",))
    return Recipe(name=name, operation=operation, cli_args=cli_args, expected_args=dict(expected), slots=slots, **kw)


SCENARIOS: Dict[str, Recipe] = {
    recipe.name: recipe
    for recipe in (
        _recipe("null-test", _TEST, edit="none", floor_class="swift"),
        _recipe("test-body", _TEST, edit="test-body", floor_class="swift", work=TEST_COMPILE),
        _recipe("null-app", _APP, edit="none", floor_class="swift"),
        _recipe("app-body", _APP, edit="app-body", floor_class="swift", work=WorkSpec((APP_MODULE,), (APP_PRODUCT,))),
        _recipe("app-body-test", _TEST, edit="app-body", floor_class="swift",
                work=WorkSpec((APP_MODULE,), (TEST_PRODUCT,))),
        _recipe("add-input", _TEST, edit="add-input", reset="input-absent", floor_class="swift", work=TEST_COMPILE),
        # Removing a source need not recompile anything, but must relink.
        _recipe("remove-input", _TEST, edit="remove-input", reset="input-present", floor_class="swift",
                work=WorkSpec((), (TEST_PRODUCT,))),
        _recipe("touch-tests", _TEST, edit="touch-tests", floor_class="swift", work=TEST_COMPILE),
        _recipe("broad-test", _TEST, edit="broad", floor_class="swift", work=TEST_COMPILE),
        _recipe(
            "artifact",
            ("test-artifact", ("--filter", PROBE_SUITE), {"filter": PROBE_SUITE}),
            edit="none", floor_class="artifact", setup="mint-ticket", slots=("xctest",),
        ),
        _recipe("null-package", _PACKAGE, edit="none", floor_class="package", supported=False,
                unsupported_reason=PACKAGING_GATE),
        _recipe("app-body-package", _PACKAGE, edit="app-body", floor_class="package", supported=False,
                unsupported_reason=PACKAGING_GATE),
        _recipe("cold", _TEST, edit="none", reset="cold", primers=0, cache_class="cold", floor_class="swift",
                role=ROLE_DIAGNOSTIC, work=TEST_COMPILE),
        _recipe("diag-driver", _DIAG_TEST, edit="test-body", floor_class="swift", role=ROLE_DIAGNOSTIC,
                work=TEST_COMPILE, sole=True, capability=DIAG_ROUTE_MARKER, instrumentation=INSTRUMENTATION_DRIVER),
    )
}
DEFAULT_SCENARIOS = ("null-test", "test-body", "null-app", "app-body", "artifact")


# ---------------------------------------------------------------------------
# Small helpers


def utc_now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> Optional[str]:
    try:
        return sha256_bytes(Path(path).read_bytes())
    except OSError:
        return None


def canonical_json(payload: Any) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")


def write_json_atomic(path: Path, payload: Any) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    data = json.dumps(payload, indent=2, sort_keys=True, default=str).encode("utf-8") + b"\n"
    with open(temp, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, path)


def append_jsonl(path: Path, payload: Any) -> None:
    line = canonical_json(payload) + b"\n"
    with open(path, "ab") as handle:
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())


def run_command(argv: Sequence[str], *, cwd: Optional[Path] = None, env: Optional[Mapping[str, str]] = None,
                timeout: float = GIT_TIMEOUT_S) -> subprocess.CompletedProcess:
    return subprocess.run(
        list(argv), cwd=str(cwd) if cwd else None, env=dict(env) if env is not None else None,
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, check=False,
    )


def git(args: Sequence[str], cwd: Path, *, timeout: float = GIT_TIMEOUT_S) -> subprocess.CompletedProcess:
    return run_command(["git", *args], cwd=cwd, timeout=timeout)


def git_ok(args: Sequence[str], cwd: Path) -> str:
    result = git(args, cwd)
    if result.returncode != 0:
        raise HarnessError(f"git {' '.join(args)} failed in {cwd}: {result.stderr.strip()[:400]}")
    return result.stdout


def git_blob_sha256(repo: Path, commit: str, rel: str) -> Optional[str]:
    result = subprocess.run(["git", "show", f"{commit}:{rel}"], cwd=str(repo), capture_output=True, timeout=60)
    return sha256_bytes(result.stdout) if result.returncode == 0 else None


def load_conductor() -> Any:
    """The runner's own conductor module (helpers only; no daemon is started)."""
    import conductor  # noqa: PLC0415 - deferred: only run/clean need it

    return conductor


def finite_nonnegative(value: Any) -> bool:
    return (isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
            and value >= 0)


def process_alive_with_token(cond: Any, pid: Any, token: Any) -> Optional[bool]:
    """True/False when provable, None when the evidence is unavailable."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    if not cond.pid_alive(pid):
        return False
    if not token:
        return None
    current = cond.process_start_token(pid)
    if current is None:
        return None
    return current == token


def processes_mentioning(text: str) -> Optional[List[int]]:
    """PIDs whose command line contains ``text`` (None when ``ps`` fails)."""
    try:
        result = run_command(["/bin/ps", "-axww", "-o", "pid=,command="], timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    pids: List[int] = []
    for line in result.stdout.splitlines():
        head, _, command = line.strip().partition(" ")
        if text in command and head.isdigit() and int(head) != os.getpid():
            pids.append(int(head))
    return pids


# ---------------------------------------------------------------------------
# Thermal state (NSProcessInfo.thermalState through the Objective-C runtime)


class _ObjC:
    def __init__(self) -> None:
        path = ctypes.util.find_library("objc")
        if not path:
            raise OSError("libobjc not found")
        objc = ctypes.CDLL(path)
        ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.object_getClass.restype = ctypes.c_void_p
        objc.object_getClass.argtypes = [ctypes.c_void_p]
        objc.class_respondsToSelector.restype = ctypes.c_bool
        objc.class_respondsToSelector.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        objc.objc_autoreleasePoolPush.restype = ctypes.c_void_p
        objc.objc_autoreleasePoolPush.argtypes = []
        objc.objc_autoreleasePoolPop.restype = None
        objc.objc_autoreleasePoolPop.argtypes = [ctypes.c_void_p]
        address = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value
        # Explicit prototypes per call shape (required on arm64).
        self.send_id = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(address)
        self.send_long = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(address)
        self.objc = objc

    def thermal_state_raw(self) -> int:
        objc = self.objc
        pool = objc.objc_autoreleasePoolPush()
        if not pool:
            raise OSError("autorelease pool unavailable")
        try:
            cls = objc.objc_getClass(b"NSProcessInfo")
            if not cls:
                raise OSError("NSProcessInfo unavailable")
            info = self.send_id(cls, objc.sel_registerName(b"processInfo"))
            if not info:
                raise OSError("processInfo returned nil")
            selector = objc.sel_registerName(b"thermalState")
            if not objc.class_respondsToSelector(objc.object_getClass(info), selector):
                raise OSError("thermalState selector unavailable")
            return int(self.send_long(info, selector))
        finally:
            objc.objc_autoreleasePoolPop(pool)


_OBJC: Optional[_ObjC] = None
_OBJC_LOCK = threading.Lock()


def thermal_state(reader: Optional[Callable[[], int]] = None) -> str:
    """``nominal|fair|serious|critical`` or ``unknown`` (never assumed nominal)."""
    global _OBJC
    try:
        if reader is None:
            with _OBJC_LOCK:
                if _OBJC is None:
                    _OBJC = _ObjC()
            reader = _OBJC.thermal_state_raw
        value = reader()
    except Exception:  # noqa: BLE001 - any failure is unknown evidence
        return "unknown"
    if isinstance(value, bool) or not isinstance(value, int):
        return "unknown"
    return THERMAL_NAMES.get(value, "unknown")


class ThermalObserver:
    """Benchmark-only, read-only 1 Hz thermal sampler for one job's lifetime.

    The worker thread only reads the thermal state and the clock: no RPC,
    subprocess, job, slot or fixture operation. The foreground thread stays the
    sole orchestrator; it starts the observer (first reading before submission),
    marks boundaries, takes the final reading after terminal state and stops it
    with a bounded join on every path.
    """

    def __init__(self, reader: Callable[[], str], clock: Callable[[], float] = time.monotonic, *,
                 interval: float = THERMAL_INTERVAL_S, max_gap: float = THERMAL_MAX_GAP_S,
                 max_observations: int = THERMAL_MAX_OBSERVATIONS, start_timeout: float = THERMAL_START_TIMEOUT_S,
                 join_timeout: float = THERMAL_JOIN_TIMEOUT_S) -> None:
        self.reader = reader
        self.clock = clock
        self.interval = interval
        self.max_gap = max_gap
        self.max_observations = max_observations
        self.start_timeout = start_timeout
        self.join_timeout = join_timeout
        self.observations: List[Tuple[float, str]] = []
        self.marks: Dict[str, float] = {}
        self.errors: List[str] = []
        self.exhausted = False
        self.join_failed = False
        self.started = False
        self.finished = False
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._first = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def _read(self) -> None:
        try:
            state = self.reader()
            if state not in ("nominal", "fair", "serious", "critical"):
                state = "unknown"
        except Exception as exc:  # noqa: BLE001 - recorded, invalidates the sample
            state = "error"
            with self._lock:
                self.errors.append(f"{type(exc).__name__}: {exc}"[:200])
        at = self.clock()
        with self._lock:
            if len(self.observations) >= self.max_observations:
                self.exhausted = True
                return
            self.observations.append((at, state))

    def _run(self) -> None:
        try:
            while not self._stop.is_set():
                self._read()
                self._first.set()
                if self.exhausted:
                    return
                self._stop.wait(self.interval)
        finally:
            self._first.set()

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="swift-bench-thermal", daemon=True)
        self._thread.start()
        self.started = True
        if not self._first.wait(self.start_timeout) or not self.observations:
            raise HarnessError("thermal observer produced no first reading before submission")

    def mark(self, name: str, at: Optional[float] = None) -> float:
        value = self.clock() if at is None else at
        with self._lock:
            self.marks[name] = value
        return value

    def finish(self) -> Dict[str, Any]:
        """Final reading, bounded stop/join, coverage summary. Never raises."""
        if self.finished:
            return self.summary()
        self.finished = True
        if self.started:
            # Final reading off the foreground thread too: a stuck reader must not stall cleanup.
            final = threading.Thread(target=self._read, name="swift-bench-thermal-final", daemon=True)
            final.start()
            final.join(self.join_timeout)
            if final.is_alive():
                self.join_failed = True
                with self._lock:
                    self.errors.append("final reading did not return within the join bound")
            self._stop.set()
            if self._thread is not None:
                self._thread.join(self.join_timeout)
                self.join_failed = self.join_failed or self._thread.is_alive()
        return self.summary()

    def summary(self) -> Dict[str, Any]:
        with self._lock:
            observations = list(self.observations)
            marks = dict(self.marks)
            errors = list(self.errors)
        return summarize_thermal(observations, marks, errors, exhausted=self.exhausted, join_failed=self.join_failed,
                                 max_gap=self.max_gap, interval=self.interval)

    def raw(self) -> Dict[str, Any]:
        with self._lock:
            return {"observations": [[at, state] for at, state in self.observations], "marks": dict(self.marks),
                    "errors": list(self.errors)}


def summarize_thermal(observations: Sequence[Tuple[float, str]], marks: Mapping[str, float], errors: Sequence[str], *,
                      exhausted: bool, join_failed: bool, max_gap: float, interval: float) -> Dict[str, Any]:
    """Coverage summary of one job's raw observations (pure; recomputed when a capture is validated)."""
    observations = sorted((at, state) for at, state in observations)
    marks = dict(marks)
    errors = list(errors)
    states: Dict[str, int] = {}
    for _at, state in observations:
        states[state] = states.get(state, 0) + 1
    times = [at for at, _state in observations]
    gaps = [b - a for a, b in zip(times, times[1:])]
    start = marks.get("submitStart")
    end = marks.get("terminalObserved")
    reasons: List[str] = []
    if not observations:
        reasons.append("no_observations")
    if start is None or end is None:
        reasons.append("boundaries_missing")
    elif observations:
        if times[0] > start:
            reasons.append("first_after_submission")
        if times[-1] < end:
            reasons.append("last_before_terminal")
    observed_gap = max(gaps) if gaps else (0.0 if observations else None)
    if observed_gap is not None and observed_gap > max_gap:
        reasons.append("gap_exceeded")
    if exhausted:
        reasons.append("exhausted")
    if errors or states.get("error"):
        reasons.append("observer_error")
    if join_failed:
        reasons.append("join_failed")
    return {
        "samples": len(observations),
        "states": states,
        "unknown": states.get("unknown", 0) + states.get("error", 0),
        "nonNominal": sum(count for state, count in states.items() if state not in ("nominal", "unknown", "error")),
        "maxGapSeconds": observed_gap,
        "maxGapBoundSeconds": max_gap,
        "intervalSeconds": interval,
        "firstAt": times[0] if times else None,
        "lastAt": times[-1] if times else None,
        "marks": marks,
        "errors": errors,
        "exhausted": exhausted,
        "joinFailed": join_failed,
        "coverage": not reasons,
        "coverageReasons": reasons,
    }


def thermal_summary(observations: Sequence[Tuple[float, str]]) -> Dict[str, Any]:
    """Count summary of raw observations (no coverage judgement)."""
    states: Dict[str, int] = {}
    for _at, state in observations:
        states[state] = states.get(state, 0) + 1
    gaps = [b[0] - a[0] for a, b in zip(observations, observations[1:])]
    return {
        "samples": len(observations),
        "states": states,
        "unknown": states.get("unknown", 0),
        "nonNominal": sum(count for state, count in states.items() if state not in ("nominal", "unknown")),
        "maxGapSeconds": max(gaps) if gaps else None,
    }


# ---------------------------------------------------------------------------
# Host evidence and admission probes


def sysctl_value(name: str) -> Optional[str]:
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        result = run_command(["/usr/sbin/sysctl", "-n", name], timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return None


def positive_int(text: Optional[str]) -> Optional[int]:
    try:
        value = int(str(text).strip())
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def _command_text(argv: Sequence[str]) -> Optional[str]:
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        result = run_command(argv, timeout=60)
        if result.returncode == 0:
            return (result.stdout + result.stderr).strip()[:2000] or None
    return None


def collect_host() -> Dict[str, Any]:
    return {
        "physicalCpu": positive_int(sysctl_value("hw.physicalcpu")),
        "logicalCpu": positive_int(sysctl_value("hw.logicalcpu")),
        "model": sysctl_value("hw.model"),
        "cpuBrand": sysctl_value("machdep.cpu.brand_string"),
        "memoryBytes": positive_int(sysctl_value("hw.memsize")),
        "arch": platform.machine() or None,
        "osVersion": _command_text(["/usr/bin/sw_vers", "-productVersion"]),
        "osBuild": _command_text(["/usr/bin/sw_vers", "-buildVersion"]),
        "developerDir": _command_text(["/usr/bin/xcode-select", "-p"]),
        "swiftVersion": _command_text(["/usr/bin/xcrun", "swift", "--version"]),
        "sdkVersion": _command_text(["/usr/bin/xcrun", "--show-sdk-version"]),
        "sdkPath": _command_text(["/usr/bin/xcrun", "--show-sdk-path"]),
        "python": sys.version.split()[0],
        "pmsetTherm": _command_text(["/usr/bin/pmset", "-g", "therm"]),  # diagnostic only, never authoritative
    }


class HostProbe:
    """Passive admission probes. Never starts, stops or reconfigures any daemon."""

    def __init__(self, cond: Any, main_root: Path, job_env: Mapping[str, str]) -> None:
        self.cond = cond
        self.main_root = main_root
        self.job_env = dict(job_env)

    def thermal(self) -> str:
        return thermal_state()

    def load1(self) -> Optional[float]:
        try:
            return float(os.getloadavg()[0])
        except OSError:
            return None

    def main_daemon(self) -> Dict[str, Any]:
        """Passive status RPC to the explicit main checkout's daemon: no ensure, autostart or stop."""
        cond = self.cond
        paths = cond.compute_paths(self.main_root)
        pid = cond.read_pid(paths.pid_path)
        alive = bool(pid) and cond.pid_alive(pid)
        socket_present = os.path.lexists(paths.socket_path)
        if not alive and not socket_present:
            return {"state": "idle", "detail": "absent", "pid": pid}
        try:
            payload = cond.request_daemon(paths, {"type": "status"}, timeout=1.0)
        except Exception as exc:  # noqa: BLE001 - a present socket or live pid that cannot answer is unknown
            return {"state": "unknown", "detail": f"status failed: {exc}"[:300], "pid": pid,
                    "socketPresent": socket_present, "pidAlive": alive}
        return classify_main_status(payload, cond.PROTOCOL_VERSION)

    def slots(self, extra: Iterable[Path] = ()) -> Dict[str, Any]:
        cond = self.cond
        try:
            lock_dir = cond.machine_lock_dir()
            cond.ensure_private_dir(lock_dir)
            configured = [*cond.global_heavy_slot_paths(self.job_env), *cond.global_xctest_slot_paths(self.job_env)]
        except Exception as exc:  # noqa: BLE001
            return {"state": "error", "detail": f"slot inventory failed: {exc}"[:300], "slots": []}
        existing: List[Path] = []
        with contextlib.suppress(OSError):
            existing = sorted(lock_dir.glob("global-heavy-*.lock")) + sorted(lock_dir.glob("global-xctest-*.lock"))
        return probe_slot_files([*configured, *existing, *extra])


def classify_main_status(payload: Any, protocol: int) -> Dict[str, Any]:
    if not isinstance(payload, dict):
        return {"state": "unknown", "detail": "malformed status"}
    if payload.get("protocolVersion") != protocol:
        return {"state": "unknown", "detail": f"protocol mismatch ({payload.get('protocolVersion')} != {protocol})",
                "pid": payload.get("pid")}
    running, queued, lanes = payload.get("runningJobs"), payload.get("queuedJobs"), payload.get("activeJobsByLane")
    if not isinstance(running, list) or not isinstance(queued, list) or not isinstance(lanes, dict):
        return {"state": "unknown", "detail": "status lacks job lists", "pid": payload.get("pid")}
    if running or queued or lanes:
        return {"state": "busy", "detail": f"running={len(running)} queued={len(queued)}", "pid": payload.get("pid")}
    return {"state": "idle", "detail": "running daemon has no active jobs", "pid": payload.get("pid"),
            "conductorDigest": payload.get("conductorDigest"),
            "slotPaths": [*(payload.get("globalHeavySlotPaths") or []), *(payload.get("xctestSlotPaths") or [])]}


def probe_slot_files(paths: Iterable[Path]) -> Dict[str, Any]:
    """Non-blocking probe of every slot file (created 0600 if missing), always released.

    Opened with ``O_NOFOLLOW`` (no check-then-open race) and verified regular.
    ``free`` only when every slot was acquired and released; any held slot is
    ``busy`` (wait); any open/lock error is ``error`` (unknown evidence).
    """
    results: List[Dict[str, Any]] = []
    seen: set[str] = set()
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    for raw in paths:
        path = Path(raw)
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        entry: Dict[str, Any] = {"path": key, "existed": os.path.lexists(path)}
        fd: Optional[int] = None
        try:
            fd = os.open(path, flags, 0o600)
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError(errno.EINVAL, "slot lock path is not a regular file")
            for _ in range(3):
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    entry["state"] = "busy"
                    break
                except OSError as exc:
                    if exc.errno == errno.EINTR:
                        continue
                    raise
                else:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_UN)
                    finally:
                        entry["state"] = "free"
                    break
            else:
                entry["state"] = "error"
                entry["detail"] = "interrupted"
        except OSError as exc:
            entry["state"] = "error"
            entry["detail"] = f"{type(exc).__name__}: {exc}"[:200]
        finally:
            if fd is not None:
                with contextlib.suppress(OSError):
                    os.close(fd)
        results.append(entry)
    if not results:
        return {"state": "error", "detail": "no slot paths", "slots": results}
    states = {entry["state"] for entry in results}
    overall = "error" if "error" in states else ("busy" if "busy" in states else "free")
    return {"state": overall, "slots": results}


# ---------------------------------------------------------------------------
# Fixtures: rendering, target membership and the byte/mtime ledger


def load_fixture_manifest(path: Path = FIXTURE_MANIFEST) -> Dict[str, Any]:
    manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    for name, probe in manifest["probes"].items():
        actual = sha256_file(path.parent / probe["template"])
        if actual != probe["templateSha256"]:
            raise HarnessError(f"fixture template {probe['template']} hash {actual} != manifest {probe['templateSha256']}")
    return manifest


def render_probe(manifest: Mapping[str, Any], name: str, body: int, broad: int = 0) -> bytes:
    probe = manifest["probes"][name]
    text = (FIXTURE_DIR / probe["template"]).read_text(encoding="utf-8")
    variants = manifest["variants"]
    text = text.replace("{{BODY_VARIANT}}", variants["BODY_VARIANT"][body % 2])
    text = text.replace("{{BROAD_MEMBER}}", variants["BROAD_MEMBER"][broad % 2])
    if "{{" in text or "}}" in text:
        raise HarnessError(f"unrendered placeholder in {name}")
    return text.encode("utf-8")


_TARGET_START = re.compile(r"\.(?:testTarget|target|executableTarget)\(\s*name:\s*\"([^\"]+)\"")


def package_target_paths(package_swift: str) -> Dict[str, Dict[str, Any]]:
    """Map target name -> ``{"path", "filtered"}`` from Package.swift text (plain declarations only)."""
    starts = [(match.start(), match.end(), match.group(1)) for match in _TARGET_START.finditer(package_swift)]
    result: Dict[str, Dict[str, Any]] = {}
    for index, (_start, end, name) in enumerate(starts):
        limit = starts[index + 1][0] if index + 1 < len(starts) else len(package_swift)
        body = package_swift[end:limit]
        path_match = re.search(r"\bpath:\s*\"([^\"]+)\"", body)
        result[name] = {
            "path": path_match.group(1) if path_match else None,
            "filtered": bool(re.search(r"\b(exclude|sources):", body)),
        }
    return result


def verify_probe_membership(package_swift: str, manifest: Mapping[str, Any]) -> Dict[str, Any]:
    """Each probe's insert path lies in its declared target's directory and in no nested target."""
    targets = package_target_paths(package_swift)
    evidence: Dict[str, Any] = {}
    for name, probe in manifest["probes"].items():
        target = targets.get(probe["target"])
        if target is None or target["path"] != probe["targetPath"]:
            raise HarnessError(f"probe {name}: target {probe['target']} path {target} != {probe['targetPath']}")
        if target["filtered"]:
            raise HarnessError(f"probe {name}: target {probe['target']} declares exclude/sources; membership is not plain")
        insert = probe["insertPath"]
        if not insert.startswith(probe["targetPath"] + "/") or ".." in Path(insert).parts:
            raise HarnessError(f"probe {name}: {insert} is outside {probe['targetPath']}")
        nested = [other for other, info in targets.items() if other != probe["target"] and info["path"]
                  and insert.startswith(info["path"].rstrip("/") + "/")]
        if nested:
            raise HarnessError(f"probe {name}: {insert} also lies in target(s) {nested}")
        evidence[name] = {"target": probe["target"], "targetPath": probe["targetPath"], "insertPath": insert}
    return evidence


class FixtureLedger:
    """Expected bytes/mtimes of every benchmark-owned path in one worktree.

    Mutations happen only after the caller proves no owned job is active; each
    mutation first verifies the expected prior bytes and refuses any
    unexpected edit rather than resetting it.
    """

    def __init__(self, tree: Path, manifest: Mapping[str, Any], *, busy_check: Callable[[], Optional[str]],
                 on_change: Optional[Callable[[], None]] = None) -> None:
        self.tree = tree
        self.manifest = manifest
        self.busy_check = busy_check
        self.on_change = on_change
        self.entries: Dict[str, Dict[str, Any]] = {}
        self.body = 0
        self.app_body = 0
        self.broad = 0
        self.input_body = 0
        self.history: List[Dict[str, Any]] = []

    def _path(self, rel: str) -> Path:
        path = self.tree / rel
        for parent in [path.parent, *path.parent.parents]:
            if parent == self.tree:
                break
            if os.path.islink(parent):
                raise HarnessError(f"fixture parent {parent} is a symlink")
        return path

    def _guard(self, action: str) -> None:
        busy = self.busy_check()
        if busy:
            raise HarnessError(f"refusing fixture {action}: {busy}")

    def _observe(self, rel: str) -> Dict[str, Any]:
        path = self._path(rel)
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return {"state": "absent"}
        if not stat.S_ISREG(st.st_mode):
            return {"state": "not-regular"}
        return {"state": "present", "sha256": sha256_file(path), "size": st.st_size, "mtimeNs": st.st_mtime_ns}

    def verify(self, rel: str) -> None:
        expected = self.entries.get(rel, {"state": "absent"})
        observed = self._observe(rel)
        keys = ("state", "sha256", "size", "mtimeNs") if expected["state"] == "present" else ("state",)
        if any(observed.get(key) != expected.get(key) for key in keys):
            raise HarnessError(f"fixture fence: {rel} expected {expected} observed {observed}")

    def verify_all(self) -> None:
        for rel in list(self.entries):
            self.verify(rel)

    def write(self, rel: str, data: bytes, reason: str) -> Dict[str, Any]:
        self._guard(f"write {rel}")
        self.verify(rel)
        prior = dict(self.entries.get(rel, {"state": "absent"}))
        path = self._path(rel)
        if not path.parent.is_dir():
            raise HarnessError(f"fixture parent missing: {path.parent}")
        temp = path.with_name(f".{path.name}.rpce-bench.tmp")
        with open(temp, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        after = self._observe(rel)
        if after.get("sha256") != sha256_bytes(data):
            raise HarnessError(f"fixture write verification failed for {rel}")
        self.entries[rel] = after
        event = {"at": utc_now_iso(), "action": "write", "path": rel, "reason": reason,
                 "priorSha256": prior.get("sha256"), "priorState": prior["state"], "sha256": after["sha256"]}
        self.history.append(event)
        self._changed()
        return event

    def _changed(self) -> None:
        if self.on_change is not None:
            self.on_change()

    def remove(self, rel: str, reason: str) -> Dict[str, Any]:
        self._guard(f"remove {rel}")
        self.verify(rel)
        prior = self.entries.get(rel)
        if not prior or prior["state"] != "present":
            raise HarnessError(f"fixture remove of non-present {rel}")
        os.unlink(self._path(rel))
        self.entries[rel] = {"state": "absent"}
        event = {"at": utc_now_iso(), "action": "remove", "path": rel, "reason": reason, "priorSha256": prior["sha256"]}
        self.history.append(event)
        self._changed()
        return event

    # Probe operations -------------------------------------------------------

    def probe_rel(self, name: str) -> str:
        return self.manifest["probes"][name]["insertPath"]

    def install(self) -> None:
        for name, probe in self.manifest["probes"].items():
            if probe.get("installedAtSetup"):
                self.write(probe["insertPath"], self._render(name), "install")

    def _render(self, name: str) -> bytes:
        if name == "test-probe":
            return render_probe(self.manifest, name, self.body, self.broad)
        if name == "app-probe":
            return render_probe(self.manifest, name, self.app_body)
        return render_probe(self.manifest, name, self.input_body)

    def toggle(self, kind: str) -> Dict[str, Any]:
        if kind == "test-body":
            self.body += 1
            return self.write(self.probe_rel("test-probe"), self._render("test-probe"), kind)
        if kind == "broad":
            self.broad += 1
            return self.write(self.probe_rel("test-probe"), self._render("test-probe"), kind)
        if kind == "app-body":
            self.app_body += 1
            return self.write(self.probe_rel("app-probe"), self._render("app-probe"), kind)
        raise HarnessError(f"unknown toggle {kind}")

    def input_present(self) -> bool:
        return self.entries.get(self.probe_rel("input-probe"), {}).get("state") == "present"

    def add_input(self) -> Dict[str, Any]:
        self.input_body += 1
        return self.write(self.probe_rel("input-probe"), self._render("input-probe"), "add-input")

    def remove_input(self) -> Dict[str, Any]:
        return self.remove(self.probe_rel("input-probe"), "remove-input")

    def touch_tests(self) -> Dict[str, Any]:
        """mtime-only churn of every test source; contents are fenced before and after."""
        self._guard("touch-tests")
        self.verify_all()
        root = self._path(self.manifest["probes"]["test-probe"]["targetPath"])
        files = sorted(path for path in root.rglob("*.swift") if path.is_file() and not path.is_symlink())
        if not files or len(files) > MAX_TOUCH_FILES:
            raise HarnessError(f"touch-tests: {len(files)} files outside 1..{MAX_TOUCH_FILES}")
        before = {str(path): (sha256_file(path), os.lstat(path).st_mtime_ns) for path in files}
        stamp = time.time_ns()
        for path in files:
            os.utime(path, ns=(stamp, stamp), follow_symlinks=False)
        changed = 0
        for path in files:
            sha, old_mtime = before[str(path)]
            if sha256_file(path) != sha:
                raise HarnessError(f"touch-tests changed content of {path}")
            if os.lstat(path).st_mtime_ns != stamp:
                raise HarnessError(f"touch-tests mtime not applied to {path}")
            changed += int(old_mtime != stamp)
        for rel, entry in self.entries.items():
            if entry["state"] == "present" and str(self.tree / rel) in before:
                entry["mtimeNs"] = stamp
        event = {"at": utc_now_iso(), "action": "touch", "files": len(files), "mtimeChanged": changed,
                 "mtimeNs": stamp, "contentSha256": sha256_bytes(json.dumps(sorted((k, v[0]) for k, v in before.items())).encode())}
        self.history.append(event)
        self._changed()
        return event

    # Intended states --------------------------------------------------------

    def state(self) -> Dict[str, Any]:
        """The intended fixture state (variant parities and input presence)."""
        return {"body": self.body % 2, "appBody": self.app_body % 2, "broad": self.broad % 2,
                "input": self.input_body % 2, "inputPresent": self.input_present()}

    def restore(self, target: Mapping[str, Any], reason: str = "retry-baseline") -> List[Dict[str, Any]]:
        """Rewrite owned probes to an earlier intended state (expected-byte fenced)."""
        events: List[Dict[str, Any]] = []
        for key, attr in (("body", "body"), ("appBody", "app_body"), ("broad", "broad"), ("input", "input_body")):
            current = getattr(self, attr)
            if current % 2 != target[key] % 2:
                setattr(self, attr, current + 1)
        for name in ("test-probe", "app-probe"):
            rel = self.probe_rel(name)
            data = self._render(name)
            if self.entries.get(rel, {}).get("sha256") != sha256_bytes(data):
                events.append(self.write(rel, data, reason))
        rel = self.probe_rel("input-probe")
        if target["inputPresent"]:
            data = self._render("input-probe")
            if self.entries.get(rel, {}).get("sha256") != sha256_bytes(data):
                events.append(self.write(rel, data, reason))
        elif self.input_present():
            events.append(self.remove(rel, reason))
        if self.state() != dict(target):
            raise HarnessError(f"fixture restore reached {self.state()} instead of {dict(target)}")
        return events

    def expected_untracked(self) -> List[str]:
        return sorted(rel for rel, entry in self.entries.items() if entry["state"] == "present")

    def snapshot(self) -> Dict[str, Any]:
        return {"entries": self.entries, "variants": {"body": self.body, "appBody": self.app_body,
                                                       "broad": self.broad, "input": self.input_body},
                "history": self.history}


# ---------------------------------------------------------------------------
# Environment class (no raw values are ever exported)


def env_value_digest(key: str, value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    return sha256_bytes(ENV_DIGEST_DOMAIN + key.encode("utf-8") + b"\0" + value.encode("utf-8"))


def environment_class(job_env: Mapping[str, str], tree: Path, passthrough_keys: Iterable[str]) -> Dict[str, Any]:
    """Hash of every forwarded/build-affecting key's normalized value.

    The scratch destinations are normalized to ``<tree>`` so both arms share a
    class; every other value is digested with a domain prefix and never stored.
    """
    keys = sorted(set(passthrough_keys) | set(ENV_CLASS_EXTRA_KEYS))
    prefix = str(tree)
    digests: Dict[str, Optional[str]] = {}
    for key in keys:
        value = job_env.get(key)
        if value is not None and key in DESTINATION_KEYS and (value == prefix or value.startswith(prefix + "/")):
            value = "<tree>" + value[len(prefix):]
        digests[key] = env_value_digest(key, value)
    return {"keys": keys, "digests": digests, "class": sha256_bytes(canonical_json(digests))}


# ---------------------------------------------------------------------------
# Worktree ownership


def benchmark_root(cond: Any, main_root: Path) -> Path:
    return Path(cond.compute_paths(main_root).state_dir) / "benchmarks"


def state_inventory(root: Path, limit: int = 20000) -> Dict[str, Any]:
    """Names, types and sizes only (never contents) of a daemon state directory."""
    if not os.path.lexists(root):
        return {"exists": False}
    entries: List[Tuple[str, str, int]] = []
    truncated = False
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for name in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(current, d))]:
            path = os.path.join(current, name)
            with contextlib.suppress(OSError):
                st = os.lstat(path)
                kind = "link" if stat.S_ISLNK(st.st_mode) else ("file" if stat.S_ISREG(st.st_mode) else "other")
                entries.append((os.path.relpath(path, root), kind, st.st_size))
            if len(entries) >= limit:
                truncated = True
                break
        if truncated:
            break
    return {"exists": True, "entries": len(entries), "truncated": truncated,
            "bytes": sum(size for _rel, _kind, size in entries),
            "namesDigest": sha256_bytes(canonical_json(entries)),
            "topLevel": sorted({rel.split(os.sep, 1)[0] for rel, _kind, _size in entries})[:50]}


class WorktreeOwner:
    """Fixed-location disposable worktrees guarded by a benchmark control lock.

    The control lock is not a machine job slot; it only serializes use of
    ``<state>/benchmarks/worktrees/{ab-on,ab-skip}``.
    """

    MARKER = Path(".build") / "rpce-benchmark" / "owner.json"

    def __init__(self, main_root: Path, bench_root: Path) -> None:
        self.main_root = main_root
        self.bench_root = bench_root
        self.dir = bench_root / "worktrees"
        self.pointer = self.dir / "OWNER.json"
        self.lock_path = self.dir / ".control.lock"
        self._lock_handle: Optional[Any] = None

    def arm_path(self, arm: str) -> Path:
        if arm not in ARMS:
            raise HarnessError(f"unknown arm {arm!r}")
        return self.dir / arm

    def acquire_control_lock(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        if os.path.islink(self.dir) or os.path.realpath(self.dir) != str(self.dir.resolve()):
            raise HarnessError(f"benchmark worktree directory {self.dir} must not be a symlink")
        handle = open(self.lock_path, "a+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            raise HarnessError(f"another benchmark run holds {self.lock_path}")
        self._lock_handle = handle

    def release_control_lock(self) -> None:
        if self._lock_handle is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(self._lock_handle.fileno(), fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                self._lock_handle.close()
            self._lock_handle = None

    def common_dir(self, cwd: Path) -> str:
        out = git_ok(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd).strip()
        return os.path.realpath(out)

    def registered(self) -> Dict[str, Dict[str, Any]]:
        out = git_ok(["worktree", "list", "--porcelain", "-z"], self.main_root)
        entries: Dict[str, Dict[str, Any]] = {}
        current: Dict[str, Any] = {}
        for field in out.split("\0"):
            if not field:
                if current.get("worktree"):
                    entries[os.path.realpath(current["worktree"])] = current
                current = {}
                continue
            key, _, value = field.partition(" ")
            current[key] = value if value else True
        if current.get("worktree"):
            entries[os.path.realpath(current["worktree"])] = current
        return entries

    def pin(self, arm: str, record: Mapping[str, Any]) -> None:
        """A recorded path must be exactly this arm's fixed location (checked before any RPC)."""
        if arm not in ARMS or record.get("arm") != arm:
            raise HarnessError(f"ownership record arm {record.get('arm')!r} != {arm!r}")
        expected = self.arm_path(arm)
        if record.get("path") != str(expected):
            raise HarnessError(f"recorded path {record.get('path')} != expected {expected}")
        parent_real = os.path.realpath(self.dir)
        if record.get("parentRealpath") != parent_real:
            raise HarnessError(f"recorded parent {record.get('parentRealpath')} != {parent_real}")
        if record.get("realpath") != os.path.join(parent_real, arm):
            raise HarnessError(f"recorded realpath {record.get('realpath')} != {os.path.join(parent_real, arm)}")

    def preflight_new(self, daemon_alive: Callable[[Path], bool]) -> None:
        if os.path.lexists(self.pointer):
            raise HarnessError(f"{self.pointer} records an earlier run; run 'make dev-bench-clean' first")
        registered = self.registered()
        for arm in ARMS:
            path = self.arm_path(arm)
            if os.path.lexists(path):
                raise HarnessError(f"{path} already exists and is not owned by this run; refusing to overwrite it")
            if os.path.realpath(path) in registered:
                raise HarnessError(f"{path} is still registered as a git worktree; refusing to reuse it")
            if daemon_alive(path):
                raise HarnessError(f"a conductor daemon for {path} is alive; refusing to start")

    def create(self, arm: str, commit: str) -> Dict[str, Any]:
        path = self.arm_path(arm)
        if os.path.lexists(path):
            raise HarnessError(f"{path} appeared before creation; refusing")
        result = git(["worktree", "add", "--detach", str(path), commit], self.main_root)
        if result.returncode != 0:
            raise HarnessError(f"git worktree add failed for {path}: {result.stderr.strip()[:400]}")
        real = os.path.realpath(path)
        return {
            "arm": arm,
            "path": str(path),
            "realpath": real,
            "parentRealpath": os.path.realpath(path.parent),
            "commit": commit,
            "commonDir": self.common_dir(self.main_root),
            "created": True,
            "createdAt": utc_now_iso(),
        }

    def write_marker(self, record: Mapping[str, Any], run_id: str) -> None:
        marker = Path(record["realpath"]) / self.MARKER
        marker.parent.mkdir(parents=True, exist_ok=True)
        write_json_atomic(marker, {"runId": run_id, "arm": record["arm"], "commit": record["commit"]})

    def verify_identity(self, record: Mapping[str, Any], run_id: Optional[str] = None) -> None:
        """Ownership checks shared by every destructive operation; raises on any doubt."""
        self.pin(record["arm"], record)
        path = Path(record["path"])
        problems: List[str] = []
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            raise HarnessError(f"{path} is missing")
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            raise HarnessError(f"ownership check failed for {path}: path is not a real directory")
        if os.path.realpath(path) != record["realpath"]:
            problems.append("realpath changed")
        if os.path.realpath(path.parent) != record["parentRealpath"]:
            problems.append("parent realpath changed")
        registered = self.registered().get(record["realpath"])
        if not registered:
            problems.append("not registered with the main repository")
        else:
            if registered.get("HEAD") != record["commit"]:
                problems.append(f"registered HEAD {registered.get('HEAD')} != {record['commit']}")
            if registered.get("detached") is not True:
                problems.append("registered worktree is not detached")
        if self.common_dir(path) != record["commonDir"]:
            problems.append("git common dir differs")
        head = git(["rev-parse", "HEAD"], path).stdout.strip()
        if head != record["commit"]:
            problems.append(f"HEAD {head} != {record['commit']}")
        if git(["symbolic-ref", "-q", "HEAD"], path).returncode == 0:
            problems.append("HEAD is attached to a branch")
        if run_id is not None:
            try:
                marker = json.loads((path / self.MARKER).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                marker = None
            if not marker or marker.get("runId") != run_id or marker.get("arm") != record["arm"]:
                problems.append("run marker missing or mismatched")
        if problems:
            raise HarnessError(f"ownership check failed for {path}: {'; '.join(problems)}")

    def verify_dirtiness(self, record: Mapping[str, Any], ledger: Optional[FixtureLedger]) -> None:
        path = Path(record["path"])
        out = git_ok(["status", "--porcelain=v1", "-z", "--untracked-files=all"], path)
        observed = sorted(field for field in out.split("\0") if field)
        expected = sorted(f"?? {rel}" for rel in (ledger.expected_untracked() if ledger else []))
        if observed != expected:
            raise HarnessError(f"unexpected dirtiness in {path}: observed {observed[:20]} expected {expected}")
        if ledger is not None:
            ledger.verify_all()

    def absent_and_deregistered(self, record: Mapping[str, Any]) -> bool:
        return not os.path.lexists(record["path"]) and record["realpath"] not in self.registered()

    def remove(self, record: Mapping[str, Any]) -> None:
        self.pin(record["arm"], record)
        result = git(["worktree", "remove", "--force", record["realpath"]], self.main_root)
        if result.returncode != 0:
            raise HarnessError(f"git worktree remove failed for {record['realpath']}: {result.stderr.strip()[:400]}")
        if not self.absent_and_deregistered(record):
            raise HarnessError(f"{record['path']} still exists or is registered after removal")


# ---------------------------------------------------------------------------
# Conductor job client (one owned worktree)


class AmbiguousSubmit(Exception):
    """The submit CLI finished (or was reaped) without a usable answer."""


class ConductorClient:
    def __init__(self, cond: Any, tree: Path, env: Mapping[str, str]) -> None:
        self.cond = cond
        self.tree = Path(tree)
        self.env = dict(env)
        self.paths = cond.compute_paths(self.tree)

    def submit(self, recipe: Recipe, request_key: str,
               on_started: Optional[Callable[[int, Optional[str]], None]] = None) -> Dict[str, Any]:
        """Run the async submit CLI; the producer process is always finished on return or raise."""
        argv = [str(self.tree / "conductor"), recipe.operation, *recipe.cli_args,
                "--async", "--json", "--request-key", request_key]
        try:
            process = subprocess.Popen(argv, cwd=str(self.tree), env=self.env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except OSError as exc:
            raise AmbiguousSubmit(f"submit could not start: {exc}") from exc
        try:
            if on_started is not None:
                on_started(process.pid, self.cond.process_start_token(process.pid))
            try:
                stdout, stderr = process.communicate(timeout=SUBMIT_TIMEOUT_S)
            except subprocess.TimeoutExpired as exc:
                process.kill()
                process.communicate()
                raise AmbiguousSubmit(f"submit timed out after {SUBMIT_TIMEOUT_S}s (producer reaped)") from exc
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        if process.returncode != 0:
            raise AmbiguousSubmit(f"submit exit {process.returncode}: {stderr.strip()[-400:]}")
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise AmbiguousSubmit(f"submit output not JSON: {exc}") from exc
        if not isinstance(payload, dict) or not payload.get("ticket"):
            raise AmbiguousSubmit("submit output lacks a ticket")
        return payload

    def status(self, ticket: Optional[str] = None, request_key: Optional[str] = None) -> Dict[str, Any]:
        return self.cond.request_daemon(
            self.paths, {"type": "job-status", "ticket": ticket, "requestKey": request_key}, timeout=STATUS_RPC_TIMEOUT_S
        )

    def cancel(self, ticket: str) -> Dict[str, Any]:
        return self.cond.request_daemon(self.paths, {"type": "job-cancel", "ticket": ticket}, timeout=STATUS_RPC_TIMEOUT_S)

    def daemon_status(self) -> Optional[Dict[str, Any]]:
        pid = self.cond.read_pid(self.paths.pid_path)
        if not os.path.lexists(self.paths.socket_path) and not (pid and self.cond.pid_alive(pid)):
            return None
        return self.cond.request_daemon(self.paths, {"type": "status"}, timeout=STATUS_RPC_TIMEOUT_S)

    def daemon_alive(self) -> bool:
        pid = self.cond.read_pid(self.paths.pid_path)
        return bool(pid) and self.cond.pid_alive(pid)

    def live_pid(self) -> Optional[int]:
        pid = self.cond.read_pid(self.paths.pid_path)
        return pid if pid and self.cond.pid_alive(pid) else None

    def expected_fingerprint(self, recipe: Recipe) -> str:
        """The conductor's own request identity for exactly this submission (env readback)."""
        registry = self.cond.OperationRegistry(self.tree, jobs_dir=Path(self.paths.jobs_dir))
        env = {key: value for key, value in self.env.items() if key in registry.PASSTHROUGH_ENV_KEYS}
        return registry.fingerprint({"operation": recipe.operation, "args": dict(recipe.expected_args),
                                     "timeout": None, "verbose": False, "env": env})

    def passthrough_keys(self) -> List[str]:
        return list(self.cond.OperationRegistry.PASSTHROUGH_ENV_KEYS)

    def verify_owned_daemon(self, pid: int) -> bool:
        """Identity of this worktree's daemon, checked against the worktree's own entry script.

        ``conductor.verify_daemon_pid_identity`` derives the expected entry path
        from the *loaded* module, i.e. the runner, so it can never match a
        benchmark worktree's daemon. The metadata, pid and start-token checks are
        the same; only the command suffix uses the worktree's entry script.
        """
        cond = self.cond
        metadata = cond.read_daemon_metadata(self.paths)
        if metadata.get("pid") != pid:
            return False
        if metadata.get("repoRoot") != str(self.paths.repo_root) or metadata.get("repoHash") != self.paths.repo_hash:
            return False
        expected_start = metadata.get("processStart")
        if not expected_start or cond.process_start_token(pid) != expected_start:
            return False
        entry = Path(self.paths.repo_root) / "Scripts" / "conductor_entry.py"
        command = cond.process_command(pid) or ""
        return command.endswith(f" {entry} __daemon --repo-root {self.paths.repo_root}")

    def daemon_identity(self, pid: int) -> Dict[str, Any]:
        metadata = self.cond.read_daemon_metadata(self.paths)
        return {"pid": pid, "processStart": metadata.get("processStart"), "repoRoot": metadata.get("repoRoot"),
                "repoHash": metadata.get("repoHash"), "command": self.cond.process_command(pid)}

    def launchd_label(self) -> str:
        return self.cond.daemon_launchd_label(self.paths)

    def launchd_loaded(self) -> Optional[bool]:
        """True when the label is loaded, False when launchd reports no such service, None when unknown."""
        code = self.cond.run_launchctl(["print", f"gui/{os.getuid()}/{self.launchd_label()}"])
        if code == 0:
            return True
        if code == LAUNCHCTL_SERVICE_NOT_FOUND:
            return False
        return None

    def bootout_launchd(self) -> None:
        self.cond.bootout_daemon_launchd(self.paths)

    def stop_daemon(self, expected: Mapping[str, Any]) -> Dict[str, Any]:
        """Scoped non-force stop of the verified owned daemon, then verify termination.

        Unloading the launchd job is a separate, separately checkpointed cleanup
        step (``Cleaner._ensure_unloaded``); there is no signal fallback.
        """
        cond = self.cond
        pid = cond.read_pid(self.paths.pid_path)
        expected_pid = expected.get("pid")
        if not (pid and cond.pid_alive(pid)):
            return {"stoppedPid": None, "alreadyStopped": True}
        if pid != expected_pid:
            raise HarnessError(f"daemon pid {pid} != recorded owned pid {expected_pid}; not stopping")
        if not self.verify_owned_daemon(pid):
            raise HarnessError(f"daemon pid {pid} identity could not be verified; not stopping")
        if expected.get("processStart") and cond.process_start_token(pid) != expected.get("processStart"):
            raise HarnessError(f"daemon pid {pid} start token differs from the recorded owned daemon; not stopping")
        try:
            cond.request_daemon(self.paths, {"type": "stop", "force": False}, timeout=10.0)
        except Exception as exc:  # noqa: BLE001 - termination is verified below either way
            if STOP_REFUSED_ACTIVE_TEXT in str(exc):
                raise HarnessError(f"owned daemon refused to stop: {exc}")
        if not cond.wait_until_stopped(self.paths, timeout=DAEMON_STOP_TIMEOUT_S):
            raise HarnessError(f"owned daemon pid {pid} did not stop")
        deadline = time.monotonic() + DAEMON_STOP_TIMEOUT_S
        while cond.pid_alive(pid) and time.monotonic() < deadline:
            time.sleep(0.2)
        if cond.pid_alive(pid):
            raise HarnessError(f"owned daemon pid {pid} still alive after stop")
        return {"stoppedPid": pid}


# ---------------------------------------------------------------------------
# Durable ownership (schema 2): per-request and per-arm checkpoints


class OwnershipStore:
    """``ownership.json`` with an atomic write after every transition.

    ``attempts.jsonl`` remains the append-only audit trail; this record is the
    recovery authority. Historical sampling outcomes are never rewritten.
    """

    def __init__(self, path: Optional[Path], data: Dict[str, Any]) -> None:
        self.path = path
        self.data = data
        self.data.setdefault("schema", OWNERSHIP_SCHEMA_VERSION)
        self.data.setdefault("arms", {})
        self.data.setdefault("requests", {})
        self.data.setdefault("transitions", [])

    def save(self) -> None:
        if self.path is not None:
            write_json_atomic(self.path, self.data)

    @property
    def arms(self) -> Dict[str, Dict[str, Any]]:
        return self.data["arms"]

    @property
    def requests(self) -> Dict[str, Dict[str, Any]]:
        return self.data["requests"]

    def _transition(self, kind: str, subject: str, state: str, evidence: Any = None) -> None:
        self.data["transitions"].append({"at": utc_now_iso(), "kind": kind, "subject": subject, "state": state,
                                         **({"evidence": evidence} if evidence is not None else {})})

    def add_request(self, key: str, **fields: Any) -> None:
        if key in self.requests:
            raise HarnessError(f"request key {key} already recorded")
        self.requests[key] = {"state": "intent", "createdAt": utc_now_iso(), **fields}
        self._transition("request", key, "intent")
        self.save()

    def update_request(self, key: str, state: Optional[str] = None, **fields: Any) -> None:
        record = self.requests[key]
        if state is not None:
            if state not in REQUEST_STATES:
                raise HarnessError(f"unknown request state {state}")
            record["state"] = state
        record.update(fields)
        record["updatedAt"] = utc_now_iso()
        if state is not None:
            self._transition("request", key, state, {k: v for k, v in fields.items() if k in ("ticket", "reason")})
        self.save()

    def set_arm_state(self, arm: str, state: str, evidence: Any = None) -> None:
        if state not in ARM_CLEANUP_STATES:
            raise HarnessError(f"unknown arm state {state}")
        record = self.arms[arm]
        record["cleanup"] = state
        record.setdefault("cleanupTransitions", []).append(
            {"at": utc_now_iso(), "state": state, **({"evidence": evidence} if evidence is not None else {})})
        self._transition("arm", arm, state, evidence)
        self.save()

    def arm_state(self, arm: str) -> str:
        return self.arms[arm].get("cleanup", "active")


# ---------------------------------------------------------------------------
# Sample evaluation (pure)


def span_seconds(value: Any) -> Optional[float]:
    if isinstance(value, dict) and isinstance(value.get("quality"), str) and \
            value["quality"] in metrics.VALUE_QUALITIES:
        ns = value.get("ns")
        if isinstance(ns, int) and not isinstance(ns, bool):
            return ns / 1e9
    return None


def work_evidence(work: WorkSpec, segments: Sequence[Mapping[str, Any]]) -> Tuple[List[str], Dict[str, Any]]:
    """Declared compile/link work from the actual Step 8 segment records.

    Unknown evidence never counts as the declared work (and never as a null
    build); null recipes declare no work and are never gated on compilation.
    """
    modules: Dict[str, Any] = {}
    linked: Set[str] = set()
    partial = False
    exact = True
    for segment in segments:
        for name, info in (segment.get("modules") or {}).items():
            if isinstance(info, dict):
                modules.setdefault(name, []).append(info)
        products = segment.get("linkedProducts")
        if isinstance(products, list):
            linked.update(str(product) for product in products)
        elif products is not None:
            partial = True
        partial = partial or bool(segment.get("modulesPartial"))
        exact = exact and segment.get("compiledFilesExact") is not False
    evidence = {"modules": {name: infos for name, infos in sorted(modules.items())}, "linkedProducts": sorted(linked),
                "modulesPartial": partial, "compiledFilesExact": exact, "segments": len(segments)}
    if not work.required:
        return [], evidence
    reasons: List[str] = []
    if not segments:
        return ["work_unknown_no_segments"], evidence
    for name in work.compiled_modules:
        infos = modules.get(name) or []
        compiled = [info for info in infos if isinstance(info.get("compiledFiles"), int)
                    and not isinstance(info.get("compiledFiles"), bool) and info["compiledFiles"] >= 1
                    and info.get("exact") is True]
        if compiled:
            continue
        reasons.append(f"work_unknown_compile_{name}" if partial or not exact else f"work_missing_compile_{name}")
    for product in work.linked_products:
        if product not in linked:
            reasons.append(f"work_unknown_link_{product}" if partial else f"work_missing_link_{product}")
    return reasons, evidence


def evaluate_sample(
    recipe: Recipe,
    payload: Mapping[str, Any],
    phase_metrics: Optional[Mapping[str, Any]],
    finalized: bool,
    thermal: Mapping[str, Any],
    expected_digest: Optional[str],
    expected_fingerprint: Optional[str] = None,
) -> Dict[str, Any]:
    """Validity and normalized measurements. Missing values stay ``None``."""
    reasons: List[str] = []
    if payload.get("operation") != recipe.operation:
        reasons.append("operation_mismatch")
    raw_args = payload.get("args") if isinstance(payload.get("args"), dict) else None
    args = {key: value for key, value in (raw_args or {}).items() if key not in ARTIFACT_DERIVED_ARG_KEYS}
    if raw_args is None or args != dict(recipe.expected_args):
        reasons.append("args_mismatch")
    if expected_fingerprint is None or payload.get("fingerprint") != expected_fingerprint:
        reasons.append("fingerprint_mismatch")
    if payload.get("state") != "completed" or payload.get("exitCode") != 0:
        reasons.append(f"job_{payload.get('state')}_exit_{payload.get('exitCode')}")
    if payload.get("measurementInvalid") is not False:
        reasons.append("measurement_invalid")
    if expected_digest is None or payload.get("conductorDigest") != expected_digest:
        reasons.append("conductor_digest_mismatch")
    if payload.get("phaseMetricsPersistError"):
        reasons.append("metrics_persist_error")
    if not finalized or not isinstance(phase_metrics, dict):
        reasons.append("metrics_not_finalized")
        phase_metrics = {}
    elif phase_metrics.get("status") != "complete":
        reasons.append(f"metrics_status_{phase_metrics.get('status')}")
    intervals = phase_metrics.get("intervals") if isinstance(phase_metrics.get("intervals"), dict) else {}
    primary = span_seconds(intervals.get(PRIMARY_INTERVAL))
    if primary is None:
        reasons.append("primary_unavailable")
    waits = phase_metrics.get("slotWaits") if isinstance(phase_metrics.get("slotWaits"), list) else []
    contention: Dict[str, Any] = {}
    for slot in recipe.slots:
        entries = [entry for entry in waits if isinstance(entry, dict) and entry.get("slot") == slot]
        if not entries:
            contention[slot] = None
            reasons.append(f"slot_wait_missing_{slot}")
            continue
        flags = [entry.get("contended") for entry in entries]
        contention[slot] = flags
        if any(flag is True for flag in flags):
            reasons.append(f"contention_observed_{slot}")
        if any(not isinstance(flag, bool) or span_seconds(entry) is None for flag, entry in zip(flags, entries)):
            reasons.append(f"contention_unknown_{slot}")
    for entry in waits:
        if isinstance(entry, dict) and entry.get("slot") not in recipe.slots and entry.get("contended") is not False:
            reasons.append(f"contention_{'observed' if entry.get('contended') else 'unknown'}_{entry.get('slot')}")
    if thermal.get("samples", 0) <= 0:
        reasons.append("thermal_unobserved")
    if thermal.get("unknown", 0):
        reasons.append("thermal_unknown")
    if thermal.get("nonNominal", 0):
        reasons.append("thermal_non_nominal")
    if thermal.get("coverage") is not True:
        reasons.append("thermal_coverage_incomplete")
    segments = [segment for segment in (phase_metrics.get("segments") or []) if isinstance(segment, dict)] \
        if isinstance(phase_metrics.get("segments"), list) else []
    work_reasons, work = work_evidence(recipe.work, segments)
    reasons.extend(work_reasons)
    measures = {
        "primarySeconds": primary,
        "processObservedSeconds": span_seconds(intervals.get("processObserved")),
        "queueWaitSeconds": span_seconds(intervals.get("queueWait")),
        "slotWaitSeconds": {str(entry.get("slot")): span_seconds(entry) for entry in waits if isinstance(entry, dict)},
        "segments": [
            {
                "command": segment.get("command"),
                "reportedBuildSeconds": span_seconds(segment.get("reportedBuild")),
                "preCompletionResidualSeconds": span_seconds(segment.get("preCompletionResidual")),
                "linkToBuildCompleteSeconds": span_seconds(segment.get("linkToBuildComplete")),
                "buildCompleteToFirstSuiteSeconds": span_seconds(segment.get("buildCompleteToFirstSuite")),
                "compileRecords": segment.get("compileRecords"),
                "linkedProducts": segment.get("linkedProducts"),
                "pcmWarnings": segment.get("pcmWarnings"),
                "dsymPolicy": segment.get("dsymPolicy"),
            }
            for segment in segments[:8]
        ],
        "work": work,
        "contention": contention,
    }
    return {"valid": not reasons, "invalidReasons": reasons, "measures": measures}


def establishes_state(result: Mapping[str, Any]) -> bool:
    """An unmeasured job that may establish a built fixture state."""
    if result.get("state") != "completed" or result.get("exitCode") != 0:
        return False
    return not any(reason in INTEGRITY_REASONS for reason in result.get("invalidReasons") or [])


def block_order(block_index: int) -> Tuple[str, str, str, str]:
    """Balanced ABBA, alternating which worktree leads each block."""
    if block_index % 2 == 0:
        return (ARM_ON, ARM_SKIP, ARM_SKIP, ARM_ON)
    return (ARM_SKIP, ARM_ON, ARM_ON, ARM_SKIP)


def block_pairs(samples: Sequence[Mapping[str, Any]]) -> List[Tuple[Mapping[str, Any], Mapping[str, Any]]]:
    """Pair the first ab-on with the first ab-skip and the second with the second."""
    on = [sample for sample in samples if sample["arm"] == ARM_ON]
    skip = [sample for sample in samples if sample["arm"] == ARM_SKIP]
    if len(on) != 2 or len(skip) != 2:
        raise HarnessError("a complete block holds exactly two samples per arm")
    return [(on[0], skip[0]), (on[1], skip[1])]


def calibrate(blocks: Sequence[Sequence[Mapping[str, Any]]]) -> metrics.Comparison:
    on: List[Any] = []
    skip: List[Any] = []
    for block in blocks:
        for first, second in block_pairs(block):
            on.append(first["measures"]["primarySeconds"])
            skip.append(second["measures"]["primarySeconds"])
    return metrics.aa_equivalence(
        on, skip, bound_abs=AA_BOUND_ABS_S, bound_rel=AA_BOUND_REL, min_pairs=MIN_PAIRS,
        confidence=CONFIDENCE, iterations=BOOTSTRAP_ITERATIONS, seed=BOOTSTRAP_SEED, block_size=PAIR_BLOCK_SIZE,
    )


# ---------------------------------------------------------------------------
# Capture store


class Capture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.raw = root / "raw"
        self.attempts = root / "attempts.jsonl"

    def create(self) -> None:
        self.root.mkdir(parents=True, exist_ok=False)
        self.raw.mkdir()

    def append(self, record: Mapping[str, Any]) -> None:
        append_jsonl(self.attempts, record)

    def write(self, name: str, payload: Any) -> Path:
        path = self.root / name
        write_json_atomic(path, payload)
        return path

    def save_raw(self, name: str, payload: Any) -> str:
        path = self.raw / name
        write_json_atomic(path, payload)
        return str(path.relative_to(self.root))

    def copy_raw(self, name: str, source: Path) -> Optional[str]:
        try:
            data = Path(source).read_bytes()
        except OSError:
            return None
        path = self.raw / name
        path.write_bytes(data)
        return str(path.relative_to(self.root))


# ---------------------------------------------------------------------------
# Sampling engine


class Clock:
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)


@dataclasses.dataclass
class Admission:
    threshold: float
    physical_cpu: int


class Session:
    """Synchronous scenario sampler. Holds no slot; owns tickets until terminal."""

    def __init__(
        self,
        *,
        run_id: str,
        capture: Capture,
        clients: Mapping[str, Any],
        probe: Any,
        ledgers: Mapping[str, FixtureLedger],
        expected_digests: Mapping[str, Optional[str]],
        admission: Admission,
        blocks: int = DEFAULT_BLOCKS,
        clock: Any = Clock,
        log: Callable[[str], None] = lambda message: print(message, file=sys.stderr, flush=True),
        on_cold_reset: Optional[Callable[[str], None]] = None,
        on_daemon_seen: Optional[Callable[[str, Mapping[str, Any]], None]] = None,
        store: Optional[OwnershipStore] = None,
        observer_factory: Optional[Callable[[], ThermalObserver]] = None,
    ) -> None:
        self.run_id = run_id
        self.capture = capture
        self.clients = dict(clients)
        self.probe = probe
        self.ledgers = dict(ledgers)
        self.expected_digests = dict(expected_digests)
        self.admission = admission
        self.blocks = blocks
        self.clock = clock
        self.log = log
        self.on_cold_reset = on_cold_reset
        self.on_daemon_seen = on_daemon_seen
        self.store = store if store is not None else OwnershipStore(None, {})
        self.observer_factory = observer_factory or (lambda: ThermalObserver(self.probe.thermal, self.clock.monotonic))
        self.seq = 0
        self.open_tickets: Dict[str, str] = {}  # ticket -> arm
        self.measured_attempts = 0
        self.invalid_attempts = 0
        self.daemon_pids: Dict[str, Optional[int]] = {}
        self.needs_reprime: set[str] = set()
        self.pending_restore: Dict[str, Dict[str, Any]] = {}  # arm -> intended pre-edit state
        self.results: Dict[str, Dict[str, Any]] = {}
        self._fingerprints: Dict[Tuple[str, str], Optional[str]] = {}

    # -- guards ---------------------------------------------------------------

    def busy_reason(self, arm: str) -> Optional[str]:
        """Fixture edits require every owned ticket terminal and the arm's daemon idle."""
        if self.open_tickets:
            return f"owned jobs not terminal: {sorted(self.open_tickets)}"
        client = self.clients[arm]
        try:
            status = client.daemon_status()
        except Exception as exc:  # noqa: BLE001
            return f"daemon status unknown: {exc}"
        if status and (status.get("runningJobs") or status.get("queuedJobs")):
            return "daemon reports active jobs"
        return None

    # -- readiness --------------------------------------------------------------

    def wait_ready(self) -> Dict[str, Any]:
        start = self.clock.monotonic()
        polls = 0
        last: Dict[str, Any] = {}
        while True:
            polls += 1
            thermal = self.probe.thermal()
            load1 = self.probe.load1()
            main = self.probe.main_daemon()
            slots = self.probe.slots(main.get("slotPaths") or ())
            last = {"thermal": thermal, "load1": load1, "threshold": self.admission.threshold,
                    "mainDaemon": main, "slots": slots}
            blockers = []
            if thermal != "nominal":
                blockers.append(f"thermal_{thermal}")
            if load1 is None:
                blockers.append("load_unknown")
            elif load1 > self.admission.threshold:
                blockers.append("load_above_threshold")
            if main.get("state") != "idle":
                blockers.append(f"main_daemon_{main.get('state')}")
            if slots.get("state") != "free":
                blockers.append(f"slots_{slots.get('state')}")
            waited = self.clock.monotonic() - start
            if not blockers:
                last.update(polls=polls, waitedSeconds=waited)
                return last
            if waited >= READINESS_TIMEOUT_S:
                raise StopRun("readiness_timeout", blockers=blockers, last=last, polls=polls)
            self.clock.sleep(READINESS_POLL_S)

    def expected_fingerprint(self, arm: str, recipe: Recipe) -> Optional[str]:
        key = (arm, recipe.name)
        if key not in self._fingerprints:
            try:
                self._fingerprints[key] = self.clients[arm].expected_fingerprint(recipe)
            except Exception:  # noqa: BLE001 - unknown identity invalidates, never passes
                self._fingerprints[key] = None
        return self._fingerprints[key]

    # -- one job ----------------------------------------------------------------

    def run_job(self, arm: str, recipe: Recipe, kind: str, context: Mapping[str, Any]) -> Dict[str, Any]:
        client = self.clients[arm]
        admission = self.wait_ready()
        self.seq += 1
        attempt_id = f"{self.seq:05d}"
        key = f"rpce-swift-bench-{self.run_id}-{attempt_id}"
        base = {"attemptId": attempt_id, "requestKey": key, "arm": arm, "scenario": recipe.name, "kind": kind,
                "operation": recipe.operation, "cliArgs": list(recipe.cli_args), **context}
        # Durable intent before any job control.
        self.store.add_request(key, arm=arm, attemptId=attempt_id, scenario=recipe.name, kind=kind,
                               operation=recipe.operation, args=dict(recipe.expected_args))
        self.capture.append({**base, "phase": "intent", "at": utc_now_iso(), "admission": admission})
        observer = self.observer_factory()
        poll: Dict[str, Any] = {}
        payload: Dict[str, Any] = {}
        recovery: Optional[str] = None
        ticket: Optional[str] = None
        try:
            observer.start()  # first reading strictly before submission
            submit_start = observer.mark("submitStart")
            enqueue = self.submit_with_recovery(client, recipe, key, attempt_id)
            ticket = str(enqueue["ticket"])
            self.open_tickets[ticket] = arm
            self.store.update_request(key, "accepted", ticket=ticket, recovered=bool(enqueue.get("recovered")))
            submit_returned = self.clock.monotonic()
            self.capture.append({**base, "phase": "submitted", "at": utc_now_iso(), "ticket": ticket,
                                 "reused": enqueue.get("reused"), "recovered": enqueue.get("recovered", False)})
            self.note_daemon(arm)
            payload, recovery, poll = self.wait_terminal(client, ticket, submit_returned)
            observer.mark("terminalObserved", poll["terminalObservedAt"])
        finally:
            thermal = observer.finish()
            raw_thermal = self.capture.save_raw(f"{attempt_id}-{arm}.thermal.json",
                                                {**observer.raw(), "summary": thermal})
        terminal_raw = self.capture.save_raw(f"{attempt_id}-{arm}.terminal.json", payload)
        self.store.update_request(key, "terminal", terminalState=payload.get("state"), terminalEvidence=terminal_raw)
        payload, phase_metrics, finalized = self.wait_metrics(client, ticket, payload)
        del self.open_tickets[ticket]
        raw_status = self.capture.save_raw(f"{attempt_id}-{arm}.status.json", payload)
        raw_timings = None
        timings_path = Path(client.paths.jobs_dir) / f"{ticket}.timings.json"
        if timings_path.is_file():
            with contextlib.suppress(OSError, json.JSONDecodeError):
                raw_timings = self.capture.save_raw(f"{attempt_id}-{arm}.timings.json",
                                                    json.loads(timings_path.read_text(encoding="utf-8")))
        raw_log = None
        if recipe.instrumentation == INSTRUMENTATION_DRIVER and payload.get("logPath"):
            raw_log = self.capture.copy_raw(f"{attempt_id}-{arm}.log", Path(str(payload["logPath"])))
        evaluation = evaluate_sample(recipe, payload, phase_metrics, finalized, thermal,
                                     self.expected_digests.get(arm), self.expected_fingerprint(arm, recipe))
        if recovery:
            evaluation["valid"] = False
            evaluation["invalidReasons"].append(recovery)
            self.needs_reprime.add(arm)
        client_seconds = poll["terminalObservedAt"] - submit_start
        evaluation["measures"]["clientObserved"] = {
            "interval": SECONDARY_CLIENT_INTERVAL,
            "seconds": client_seconds,
            "pollIntervalSeconds": TERMINAL_POLL_S,
            "terminalDetectionWindowSeconds": poll["terminalObservedAt"] - poll["lastNonTerminalAt"],
            "statusPolls": poll["polls"],
            "semantics": "runner monotonic wall from submit-CLI start to the status poll that first observed a "
                         "terminal state; includes CLI start, any daemon start, enqueue, queue, run and up to one "
                         "poll interval plus RPC latency of detection; secondary only, never the daemon interval",
        }
        changed = self.daemon_changed(arm)
        if changed:
            evaluation["valid"] = False
            evaluation["invalidReasons"].append("daemon_identity_changed")
        result = {**base, "phase": "result", "at": utc_now_iso(), "ticket": ticket, "state": payload.get("state"),
                  "exitCode": payload.get("exitCode"), "conductorDigest": payload.get("conductorDigest"),
                  "fingerprint": payload.get("fingerprint"), "load1": admission.get("load1"),
                  "admissionCap": self.admission.threshold, "thermal": thermal, "rawStatus": raw_status,
                  "rawTerminal": terminal_raw, "rawTimings": raw_timings, "rawThermal": raw_thermal,
                  "rawLog": raw_log, "logPath": payload.get("logPath"), **evaluation}
        self.capture.append(result)
        primary = evaluation["measures"]["primarySeconds"]
        self.log(f"[{recipe.name}] {kind} {arm} #{attempt_id}: {payload.get('state')}/{payload.get('exitCode')} "
                 f"primary={'?' if primary is None else f'{primary:.3f}s'} "
                 f"{'valid' if evaluation['valid'] else 'INVALID ' + ','.join(evaluation['invalidReasons'])}")
        if thermal.get("joinFailed"):
            raise HarnessError("thermal observer did not stop within its bound; no further measurement")
        if changed:
            # Two-tree design: the measured runtime is immutable, so a pid or digest
            # change is fatal (no ad-hoc re-prime on a mutated runtime).
            raise HarnessError(f"{arm}: owned daemon identity changed during the run")
        return result

    def submit_with_recovery(self, client: Any, recipe: Recipe, key: str, attempt_id: str) -> Dict[str, Any]:
        """Submit; recover ambiguity with the same key and never duplicate a live job.

        A key lookup is authoritative only after the producer process is known
        finished (``ConductorClient.submit`` always reaps it).
        """
        for attempt in range(3):
            def started(pid: int, token: Optional[str], _attempt: int = attempt) -> None:
                self.store.update_request(key, producer={"pid": pid, "startToken": token, "attempt": _attempt,
                                                         "finished": False})

            try:
                payload = client.submit(recipe, key, on_started=started)
            except AmbiguousSubmit as exc:
                producer = dict(self.store.requests[key].get("producer") or {})
                self.store.update_request(key, producer={**producer, "finished": True, "attempt": attempt,
                                                         "error": str(exc)[:300]})
                self.capture.append({"attemptId": attempt_id, "requestKey": key, "phase": "ambiguous_submit",
                                     "at": utc_now_iso(), "error": str(exc)[:400]})
                found = self.lookup_key(client, key)
                if found is not None:
                    self.check_lookup(found, recipe, key)
                    found = dict(found)
                    found["recovered"] = True
                    return found
                if attempt == 2:
                    raise HarnessError(f"submission for {key} stayed ambiguous: {exc}")
                continue
            producer = dict(self.store.requests[key].get("producer") or {})
            self.store.update_request(key, producer={**producer, "finished": True, "attempt": attempt, "exit": 0})
            return payload
        raise HarnessError(f"submission for {key} failed")

    @staticmethod
    def check_lookup(found: Mapping[str, Any], recipe: Recipe, key: str) -> None:
        problems = []
        if found.get("requestKey") not in (None, key):
            problems.append("requestKey")
        if found.get("operation") not in (None, recipe.operation):
            problems.append("operation")
        if not found.get("ticket"):
            problems.append("ticket")
        if problems:
            raise HarnessError(f"request-key lookup for {key} returned a mismatched job ({', '.join(problems)})")

    def lookup_key(self, client: Any, key: str) -> Optional[Dict[str, Any]]:
        last_error: Optional[str] = None
        for _ in range(3):
            try:
                return client.status(request_key=key)
            except Exception as exc:  # noqa: BLE001
                last_error = str(exc)
                if REQUEST_KEY_NOT_FOUND_TEXT in last_error:
                    return None
                self.clock.sleep(2.0)
        raise HarnessError(f"cannot establish whether {key} was accepted: {last_error}")

    def note_daemon(self, arm: str) -> None:
        if arm in self.daemon_pids:
            return
        status = self.clients[arm].daemon_status() or {}
        self.daemon_pids[arm] = status.get("pid")
        if self.on_daemon_seen is not None:
            self.on_daemon_seen(arm, status)

    def daemon_changed(self, arm: str) -> bool:
        try:
            status = self.clients[arm].daemon_status() or {}
        except Exception:  # noqa: BLE001
            return True
        return status.get("pid") != self.daemon_pids.get(arm) or status.get("conductorDigest") != self.expected_digests.get(arm)

    def _status(self, client: Any, ticket: str) -> Dict[str, Any]:
        failures = 0
        while True:
            try:
                return client.status(ticket=ticket)
            except Exception as exc:  # noqa: BLE001
                failures += 1
                if failures >= STATUS_RPC_FAILURES:
                    raise HarnessError(f"status of owned ticket {ticket} unavailable: {exc}")
                self.clock.sleep(TERMINAL_POLL_S)

    def wait_terminal(self, client: Any, ticket: str,
                      since: Optional[float] = None) -> Tuple[Dict[str, Any], Optional[str], Dict[str, Any]]:
        start = self.clock.monotonic()
        poll = {"polls": 0, "lastNonTerminalAt": start if since is None else since, "terminalObservedAt": None}
        while True:
            payload = self._status(client, ticket)
            now = self.clock.monotonic()
            poll["polls"] += 1
            if payload.get("state") in TERMINAL_STATES:
                poll["terminalObservedAt"] = now
                return payload, None, poll
            poll["lastNonTerminalAt"] = now
            if now - start >= TERMINAL_TIMEOUT_S:
                # A timeout does not mean the job stopped: cancel the exact ticket and reap it.
                client.cancel(ticket)
                deadline = now + CANCEL_GRACE_S
                while self.clock.monotonic() < deadline:
                    payload = self._status(client, ticket)
                    poll["polls"] += 1
                    if payload.get("state") in TERMINAL_STATES:
                        poll["terminalObservedAt"] = self.clock.monotonic()
                        return payload, "terminal_timeout_canceled", poll
                    poll["lastNonTerminalAt"] = self.clock.monotonic()
                    self.clock.sleep(TERMINAL_POLL_S)
                raise HarnessError(f"owned ticket {ticket} not terminal after timeout and cancel")
            self.clock.sleep(TERMINAL_POLL_S)

    def wait_metrics(self, client: Any, ticket: str, payload: Dict[str, Any]) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]], bool]:
        """Wait for the same ticket's finalized, persisted Step 8 metrics (bounded)."""
        start = self.clock.monotonic()
        timings_path = Path(client.paths.jobs_dir) / f"{ticket}.timings.json"
        while True:
            pm = payload.get("phaseMetrics")
            status = pm.get("status") if isinstance(pm, dict) else None
            if payload.get("phaseMetricsPersistError"):
                return payload, pm, True
            if status not in (None, "pending", "running") and timings_path.is_file():
                try:
                    persisted = json.loads(timings_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    persisted = None
                if isinstance(persisted, dict) and persisted.get("ticket") == ticket and isinstance(persisted.get("phaseMetrics"), dict):
                    return payload, persisted["phaseMetrics"], True
            if self.clock.monotonic() - start >= METRICS_TIMEOUT_S:
                return payload, pm if isinstance(pm, dict) else None, False
            self.clock.sleep(TERMINAL_POLL_S)
            payload = self._status(client, ticket)

    # -- recipe hooks -------------------------------------------------------------

    def apply_edit(self, arm: str, recipe: Recipe) -> Optional[Dict[str, Any]]:
        ledger = self.ledgers[arm]
        if recipe.edit == "none":
            ledger.verify_all()
            return None
        if recipe.edit in ("test-body", "app-body", "broad"):
            return ledger.toggle(recipe.edit)
        if recipe.edit == "add-input":
            return ledger.add_input()
        if recipe.edit == "remove-input":
            return ledger.remove_input()
        if recipe.edit == "touch-tests":
            return ledger.touch_tests()
        raise HarnessError(f"unknown edit {recipe.edit}")

    def apply_reset(self, arm: str, recipe: Recipe, context: Mapping[str, Any]) -> None:
        ledger = self.ledgers[arm]
        if recipe.reset == "input-absent" and ledger.input_present():
            ledger.remove_input()
            self.must_succeed(arm, recipe, "reset", context)
        elif recipe.reset == "input-present" and not ledger.input_present():
            ledger.add_input()
            self.must_succeed(arm, recipe, "reset", context)
        elif recipe.reset == "cold":
            reason = self.busy_reason(arm)
            if reason:
                raise HarnessError(f"refusing cold reset: {reason}")
            if self.on_cold_reset is None:
                raise HarnessError("cold reset unavailable")
            self.on_cold_reset(arm)

    def must_succeed(self, arm: str, recipe: Recipe, kind: str, context: Mapping[str, Any],
                     attempts: int = 1 + PRIMER_RETRIES) -> Dict[str, Any]:
        """An unmeasured, finalized, owned job that must establish its fixture state."""
        for attempt in range(attempts):
            if kind == "primer":
                if recipe.reset and recipe.reset != "cold":
                    self.apply_reset(arm, recipe, {**context, "retry": attempt})
                self.apply_edit(arm, recipe)
            result = self.run_job(arm, recipe, kind, {**context, "retry": attempt})
            if establishes_state(result):
                return result
        raise HarnessError(f"{recipe.name}: {kind} on {arm} failed {attempts} times")

    def prime(self, recipe: Recipe, arms: Sequence[str] = ARMS) -> None:
        for index in range(recipe.primers):
            for arm in arms:
                self.must_succeed(arm, recipe, "primer", {"primer": index})
        for arm in arms:
            self.needs_reprime.discard(arm)
            if recipe.primers:
                self.pending_restore.pop(arm, None)

    def restore_baseline(self, arm: str, recipe: Recipe, context: Mapping[str, Any]) -> None:
        """Rebuild the recipe's intended pre-edit state before retrying its transition."""
        target = self.pending_restore.get(arm)
        if target is None or recipe.edit == "none":
            return
        events = self.ledgers[arm].restore(target)
        self.capture.append({"phase": "retry_baseline", "scenario": recipe.name, "arm": arm, "target": target,
                             "fixtureEvents": events, "at": utc_now_iso(), **context})
        self.must_succeed(arm, recipe, "retry-baseline", {**context, "restore": True},
                          attempts=RETRY_BASELINE_ATTEMPTS)
        self.pending_restore.pop(arm, None)

    # -- blocks -------------------------------------------------------------------

    def record_attempt(self, valid: bool) -> None:
        self.measured_attempts += 1
        if not valid:
            self.invalid_attempts += 1
        if (self.measured_attempts >= INVALID_MIN_ATTEMPTS
                and self.invalid_attempts / self.measured_attempts > INVALID_MAX_FRACTION):
            raise StopRun("invalid_fraction_exceeded", measured=self.measured_attempts, invalid=self.invalid_attempts)

    def run_block(self, recipe: Recipe, block_index: int, block_attempt: int) -> Optional[List[Dict[str, Any]]]:
        order = block_order(block_index)
        samples: List[Dict[str, Any]] = []
        for position, arm in enumerate(order):
            for retry in range(1 + POSITION_RETRIES):
                if self.needs_reprime:
                    self.capture.append({"phase": "reprime", "scenario": recipe.name, "arms": sorted(self.needs_reprime),
                                         "at": utc_now_iso()})
                    self.prime(recipe, sorted(self.needs_reprime))
                    self.discard(samples, recipe, block_index, block_attempt, "reprime_after_recovery")
                    return None
                context = {"block": block_index, "blockAttempt": block_attempt, "position": position, "retry": retry}
                if arm in self.pending_restore:
                    self.restore_baseline(arm, recipe, context)
                if recipe.reset:
                    self.apply_reset(arm, recipe, context)
                pre_state = self.ledgers[arm].state()
                edit = self.apply_edit(arm, recipe)
                result = self.run_job(arm, recipe, "measured", {**context, "edit": edit, "preState": pre_state})
                if not result["valid"] and recipe.edit != "none":
                    # Unknown build state: the next attempt on this arm first rebuilds pre_state.
                    self.pending_restore[arm] = pre_state
                self.record_attempt(result["valid"])
                if result["valid"]:
                    samples.append(result)
                    break
            else:
                self.discard(samples, recipe, block_index, block_attempt, "position_retries_exhausted")
                return None
        return samples

    def discard(self, samples: Sequence[Mapping[str, Any]], recipe: Recipe, block_index: int, block_attempt: int, reason: str) -> None:
        self.capture.append({
            "phase": "block_discarded", "scenario": recipe.name, "block": block_index, "blockAttempt": block_attempt,
            "reason": reason, "discardedValidAttemptIds": [sample["attemptId"] for sample in samples], "at": utc_now_iso(),
        })

    def run_scenario(self, recipe: Recipe) -> Dict[str, Any]:
        self.log(f"[{recipe.name}] start ({recipe.operation} {' '.join(recipe.cli_args)}; role {recipe.role})")
        self.pending_restore.clear()
        if recipe.setup == "mint-ticket":
            mint = SCENARIOS["null-test"]
            for arm in ARMS:
                self.must_succeed(arm, mint, "setup", {"for": recipe.name})
        self.prime(recipe)
        retained: List[List[Dict[str, Any]]] = []
        target = self.blocks
        extended = False
        block_index = 0
        block_attempts = 0
        evaluations: List[Dict[str, Any]] = []
        comparison: Optional[metrics.Comparison] = None
        gating = recipe.role == ROLE_GATING
        while True:
            while len(retained) < target:
                block_attempts += 1
                samples = self.run_block(recipe, block_index, block_attempts)
                if samples is not None:
                    retained.append(samples)
                    block_index += 1
            if not gating:
                break  # diagnostic: recorded, never calibrated or extended
            comparison = calibrate(retained)
            evaluations.append({"blocks": len(retained), **comparison.to_json()})
            if comparison.verdict == "qualified" or extended or target >= EXTENDED_BLOCKS:
                break
            extended = True
            target = EXTENDED_BLOCKS
            self.log(f"[{recipe.name}] A/A outside bound after {len(retained)} blocks; extending once to {target}")
        pairs = [(first["measures"]["primarySeconds"], second["measures"]["primarySeconds"])
                 for block in retained for first, second in block_pairs(block)]
        observations = [[{"runId": self.run_id, "attemptId": sample["attemptId"], "arm": sample["arm"],
                          "ticket": sample.get("ticket"), "requestKey": sample.get("requestKey"),
                          "primarySeconds": sample["measures"]["primarySeconds"],
                          "clientSeconds": (sample["measures"].get("clientObserved") or {}).get("seconds"),
                          "load1": sample.get("load1")}
                         for pair in block_pairs(block) for sample in pair] for block in retained]
        loads = [sample["load1"] for block in retained for sample in block if isinstance(sample.get("load1"), (int, float))]
        result = {
            "scenario": recipe.name,
            "statisticalRole": recipe.role,
            "verdict": comparison.verdict if comparison is not None else "recorded",
            "exitCode": comparison.exit_code if comparison is not None else EXIT_QUALIFIED,
            "comparison": comparison.to_json() if comparison is not None else None,
            "evaluations": evaluations,
            "extended": extended,
            "blocksRetained": len(retained),
            "blockAttempts": block_attempts,
            "pairs": pairs,
            "secondaryClientPairs": [(first["measures"]["clientObserved"]["seconds"],
                                      second["measures"]["clientObserved"]["seconds"])
                                     for block in retained for first, second in block_pairs(block)
                                     if "clientObserved" in first["measures"] and "clientObserved" in second["measures"]],
            "retainedAttemptIds": [[sample["attemptId"] for sample in block] for block in retained],
            "retainedObservations": observations,
            "retainedLoad1Range": [min(loads), max(loads)] if loads else None,
            "primaryInterval": PRIMARY_INTERVAL,
            "secondaryInterval": SECONDARY_CLIENT_INTERVAL,
            "floorClass": recipe.floor_class,
            "cacheClass": recipe.cache_class,
        }
        self.results[recipe.name] = result
        if comparison is not None:
            self.log(f"[{recipe.name}] calibration {comparison.verdict}: delta={comparison.median_delta} "
                     f"ci=[{comparison.ci_low}, {comparison.ci_high}] bound={comparison.threshold}")
        else:
            self.log(f"[{recipe.name}] diagnostic recorded: {len(retained)} blocks (not gated)")
        return result


# ---------------------------------------------------------------------------
# Run orchestration


def parse_scenarios(text: Optional[str]) -> List[str]:
    return [part for part in re.split(r"[,\s]+", text or "") if part]


def validate_request(ns: argparse.Namespace, environ: Mapping[str, str]) -> List[Recipe]:
    """Every rejection happens before any mutation."""
    if ns.instrumentation != "full":
        raise HarnessError("Step 9 captures require explicit --instrumentation full (INSTRUMENTATION=full)")
    if ns.dsym_mode != "on":
        raise HarnessError(
            f"--dsym-mode {ns.dsym_mode!r} is not supported: wrapper capability is {WRAPPER_CAPABILITY} "
            "(requested=full, effective=on); off/skip arrives with Step 10's verified wrapper switch"
        )
    for key in POLICY_ENV_KEYS:
        if key in environ:
            raise HarnessError(f"{key} must be unset for a {WRAPPER_CAPABILITY} capture (found {environ[key]!r})")
    for key in FORBIDDEN_ENV_KEYS:
        if environ.get(key):
            raise HarnessError(f"{key} must be unset: benchmark worktrees need their own daemon state")
    if not metrics.timing_enabled(environ):
        raise HarnessError("RPCE_CONDUCTOR_TIMING=off disables the measurements this harness requires")
    if environ.get("REPOPROMPT_DEV_XCTEST_DEADLINES") == "0":
        raise HarnessError("REPOPROMPT_DEV_XCTEST_DEADLINES=0 changes job arguments and output transport; unset it")
    if ns.blocks < DEFAULT_BLOCKS:
        raise HarnessError(f"--blocks must be at least {DEFAULT_BLOCKS} (min {MIN_PAIRS} pairs)")
    if not SAFE_NAME.fullmatch(ns.name):
        raise HarnessError("--name must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    names = parse_scenarios(ns.scenarios) or list(DEFAULT_SCENARIOS)
    recipes: List[Recipe] = []
    for name in names:
        recipe = SCENARIOS.get(name)
        if recipe is None:
            raise HarnessError(f"unknown scenario {name!r}; known: {', '.join(SCENARIOS)}")
        if not recipe.supported:
            raise HarnessError(f"scenario {name} unsupported: {recipe.unsupported_reason}")
        if recipe in recipes:
            raise HarnessError(f"scenario {name} listed twice")
        recipes.append(recipe)
    sole = [recipe.name for recipe in recipes if recipe.sole]
    if sole and len(recipes) > 1:
        raise HarnessError(f"scenario {sole[0]} must be the only scenario in its capture (diagnostic instrumentation)")
    if sole and getattr(ns, "calibration", None):
        raise HarnessError(f"scenario {sole[0]} is diagnostic-only and takes no calibration reference")
    return recipes


def check_capabilities(recipes: Sequence[Recipe], main_root: Path, commit: str) -> Dict[str, Any]:
    """A recipe needing a conductor route is refused for target commits that lack it."""
    evidence: Dict[str, Any] = {}
    for recipe in recipes:
        if not recipe.capability:
            continue
        result = subprocess.run(["git", "show", f"{commit}:Scripts/conductor.py"], cwd=str(main_root),
                                capture_output=True, timeout=60)
        text = result.stdout.decode("utf-8", "replace") if result.returncode == 0 else ""
        if recipe.capability not in text or DIAG_CLI_FLAG not in text:
            raise HarnessError(f"scenario {recipe.name}: target {commit[:12]} lacks the coordinated "
                               f"{DIAG_CLI_FLAG} route ({recipe.capability}); refused before any mutation")
        evidence[recipe.name] = {"capability": recipe.capability, "conductorBlobSha256": sha256_bytes(result.stdout)}
    return evidence


# Step 10 default-skip markers: a target wrapper that applies RPCE_DEBUG_DSYM
# (unset means off) is not legacy-full-only, so this harness would mislabel it.
DEFAULT_SKIP_WRAPPER_MARKERS = ("RPCE_DEBUG_DSYM", "SWIFT_DRIVER_DSYMUTIL_EXEC", "debug_dsym")
DEFAULT_SKIP_HELPER = "Scripts/debug_dsym.py"


def check_full_dsym_target(main_root: Path, commit: str) -> None:
    """Fail closed unless the target commit's wrapper is the legacy full-dSYM wrapper.

    Both arms run with RPCE_DEBUG_DSYM unset and the manifest records
    ``effectiveDsymPolicy: on``; a default-skip target would silently produce
    skip captures labeled full. Refused before any worktree or daemon mutation.
    """
    def show(rel: str) -> Optional[bytes]:
        try:
            result = subprocess.run(["git", "show", f"{commit}:{rel}"], cwd=str(main_root), capture_output=True,
                                    timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:
            raise HarnessError(f"cannot read {rel} at {commit[:12]}: {exc}") from exc
        return result.stdout if result.returncode == 0 else None

    wrapper = show("Scripts/canonical_swift.sh")
    if wrapper is None:
        raise HarnessError(f"target {commit[:12]} has no readable Scripts/canonical_swift.sh; its dSYM policy cannot "
                           f"be proven {WRAPPER_CAPABILITY}; refused before any mutation")
    text = wrapper.decode("utf-8", "replace")
    found = [marker for marker in DEFAULT_SKIP_WRAPPER_MARKERS if marker in text]
    if found or show(DEFAULT_SKIP_HELPER) is not None:
        raise HarnessError(
            f"target {commit[:12]} skips debug dSYM generation by default (Step 10 policy switch: "
            f"{', '.join(found) or DEFAULT_SKIP_HELPER}); this {WRAPPER_CAPABILITY} harness would label its captures "
            "full while the wrapper skips. Refused before any mutation: compare default-skip refs with the private "
            "lean Step 10 recipe instead")


def resolve_main_repo(raw: Optional[str]) -> Tuple[Path, Dict[str, Any]]:
    """The explicit original checkout: worktree authority, state root and passive idle-check target."""
    root = Path(os.path.realpath(Path(raw).expanduser() if raw else REPO_ROOT))
    if not root.is_dir():
        raise HarnessError(f"--main-repo {root} is not a directory")
    top = os.path.realpath(git_ok(["rev-parse", "--show-toplevel"], root).strip())
    if top != str(root):
        raise HarnessError(f"--main-repo {root} is not a repository top level ({top})")
    common = os.path.realpath(git_ok(["rev-parse", "--path-format=absolute", "--git-common-dir"], root).strip())
    git_dir = os.path.realpath(git_ok(["rev-parse", "--path-format=absolute", "--git-dir"], root).strip())
    if common != git_dir:
        raise HarnessError(f"--main-repo {root} is a linked worktree; pass the original checkout")
    runner_common = None
    probe = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], REPO_ROOT)
    if probe.returncode == 0:
        runner_common = os.path.realpath(probe.stdout.strip())
        if runner_common != common:
            raise HarnessError(f"runner {REPO_ROOT} belongs to {runner_common}, not {common}")
    return root, {"path": str(root), "commonDir": common, "head": git_ok(["rev-parse", "HEAD"], root).strip(),
                  "runnerRoot": str(REPO_ROOT), "runnerCommonDir": runner_common,
                  "runnerIsMain": os.path.realpath(REPO_ROOT) == str(root)}


def job_environment(environ: Mapping[str, str], destinations: Mapping[str, str]) -> Dict[str, str]:
    env = {key: value for key, value in environ.items()
           if key not in POLICY_ENV_KEYS and key not in FORBIDDEN_ENV_KEYS and key not in SCRUBBED_JOB_ENV_KEYS}
    env.update(destinations)
    return env


def scratch_destinations(tree: Path) -> Dict[str, str]:
    root = Path(tree) / ".build" / "rpce-benchmark" / "scratch"
    return {
        "REPOPROMPT_DEBUG_APP_ROOT": str(root / "DebugApps"),
        "REPOPROMPT_DEBUG_APP_BUNDLE": str(root / "DebugApps" / "RepoPrompt.app"),
        "REPOPROMPT_DEBUG_CLI_INSTALL_PATH": str(root / "cli" / "repoprompt_ce_cli_debug"),
    }


def tree_file_hashes(main_root: Path, commit: str) -> Dict[str, Optional[str]]:
    return {rel: git_blob_sha256(main_root, commit, rel) for rel in RUNTIME_FILES}


def required_harness_files() -> Tuple[str, ...]:
    """The provenance inventory every eligible capture must hash-check (runner versus commit)."""
    return tuple(dict.fromkeys((*HARNESS_FILES, *RUNNER_IMPORTED_FILES)))


def loaded_script_modules() -> List[str]:
    """Repository-relative paths of every loaded module that lives in the runner's Scripts directory."""
    scripts = os.path.realpath(SCRIPT_DIR)
    found: Set[str] = set()
    for module in list(sys.modules.values()):
        path = getattr(module, "__file__", None)
        if not isinstance(path, str):
            continue
        real = os.path.realpath(path)
        if os.path.dirname(real) == scripts and real.endswith(".py"):
            found.add(f"Scripts/{os.path.basename(real)}")
    return sorted(found)


def harness_provenance(main_root: Path, commit: str) -> Dict[str, Any]:
    files: Dict[str, Any] = {}
    for rel in dict.fromkeys((*required_harness_files(), *loaded_script_modules())):
        runner = sha256_file(REPO_ROOT / rel)
        blob = git_blob_sha256(main_root, commit, rel)
        files[rel] = {"runner": runner, "commit": blob, "match": runner is not None and runner == blob}
    status = git(["status", "--porcelain=v1", "--", *files, "Makefile", "Scripts/test_swift_build_benchmark.py"],
                 REPO_ROOT)
    return {"harnessVersion": HARNESS_VERSION, "runnerRoot": str(REPO_ROOT), "files": files,
            "matchesCommit": all(entry["match"] for entry in files.values()),
            "gitStatus": status.stdout.splitlines() if status.returncode == 0 else None,
            "runnerHead": git(["rev-parse", "HEAD"], REPO_ROOT).stdout.strip() or None,
            "testFileSha256": sha256_file(REPO_ROOT / "Scripts/test_swift_build_benchmark.py"),
            "makefileSha256": sha256_file(REPO_ROOT / "Makefile")}


def comparison_meta(host: Mapping[str, Any], fixture_digest: str, recipe: Recipe) -> Dict[str, Any]:
    return {
        "hardware": f"{host.get('model')}|{host.get('cpuBrand')}|p{host.get('physicalCpu')}|l{host.get('logicalCpu')}|m{host.get('memoryBytes')}",
        "toolchain": f"{host.get('swiftVersion')}|{host.get('developerDir')}",
        "sdk": f"{host.get('sdkVersion')}|{host.get('sdkPath')}",
        "arch": host.get("arch"),
        "os": f"{host.get('osVersion')}|{host.get('osBuild')}",
        "fixture": f"v1|{fixture_digest}",
        "command": f"{recipe.operation} {' '.join(recipe.cli_args)}".strip(),
        "testScope": recipe.expected_args.get("filter") or "none",
        "cacheClass": recipe.cache_class,
        "instrumentationMode": "full",
        "instrumentationIdentity": recipe.instrumentation,
        "primaryInterval": PRIMARY_INTERVAL,
        "statisticalRole": recipe.role,
    }


def effective_load_cap(reference: Optional[Mapping[str, Any]], physical_cpu: int) -> float:
    """Fresh calibration admits load1 <= physical CPUs; a follow-up inherits min(pinned, physical), never raised."""
    if reference is None:
        return float(physical_cpu)
    return min(float(reference["pinnedLoad1Threshold"]), float(physical_cpu))


def cmd_run(ns: argparse.Namespace) -> int:
    environ = dict(os.environ)
    try:
        recipes = validate_request(ns, environ)
        manifest = load_fixture_manifest()
    except HarnessError as exc:
        print(f"swift-bench: refused before any mutation: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    host = collect_host()
    if not host["physicalCpu"] or not host["logicalCpu"]:
        print("swift-bench: inconclusive before any mutation: CPU counts unavailable", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    initial_thermal = thermal_state()
    if initial_thermal != "nominal":
        print(f"swift-bench: inconclusive before any mutation: thermal state {initial_thermal}", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    try:
        main_root, main_meta = resolve_main_repo(getattr(ns, "main_repo", None))
        commit = git_ok(["rev-parse", "--verify", f"{ns.ref}^{{commit}}"], main_root).strip()
        package_swift = git_ok(["show", f"{commit}:Package.swift"], main_root)
        membership = verify_probe_membership(package_swift, manifest)
        capabilities = check_capabilities(recipes, main_root, commit)
        check_full_dsym_target(main_root, commit)
    except HarnessError as exc:
        print(f"swift-bench: refused before any mutation: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    cond = load_conductor()
    bench_root = benchmark_root(cond, main_root)
    reference = None
    if getattr(ns, "calibration", None):
        try:
            reference = load_calibration_reference(ns.calibration, bench_root, host, recipes)
        except Ineligible as exc:
            print(f"swift-bench: inconclusive before any mutation: calibration reference ineligible: {exc}",
                  file=sys.stderr)
            return EXIT_INCONCLUSIVE
        except Exception as exc:  # noqa: BLE001 - HarnessError or the S9-R2-01 backstop, before any mutation
            print(f"swift-bench: refused before any mutation: {evidence_failure_text(exc)}", file=sys.stderr)
            return EXIT_HARNESS_FAILURE
    owner = WorktreeOwner(main_root, bench_root)
    run_id = f"{_dt.datetime.now(_dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{ns.name}-{secrets.token_hex(3)}"
    capture = Capture(bench_root / "swift" / run_id)
    try:
        owner.acquire_control_lock()
    except HarnessError as exc:
        print(f"swift-bench: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    try:
        try:
            owner.preflight_new(lambda path: ConductorClient(cond, path, {}).daemon_alive())
        except HarnessError as exc:
            print(f"swift-bench: refused before any mutation: {exc}", file=sys.stderr)
            return EXIT_HARNESS_FAILURE
        context = {"mainRoot": main_root, "mainMeta": main_meta, "capabilities": capabilities, "reference": reference}
        return run_capture(ns, cond, owner, capture, run_id, commit, host, manifest, membership, recipes, environ,
                           context)
    finally:
        owner.release_control_lock()


def run_capture(ns: argparse.Namespace, cond: Any, owner: WorktreeOwner, capture: Capture, run_id: str, commit: str,
                host: Dict[str, Any], manifest: Mapping[str, Any], membership: Mapping[str, Any],
                recipes: Sequence[Recipe], environ: Mapping[str, str], context: Mapping[str, Any]) -> int:
    main_root: Path = context["mainRoot"]
    reference: Optional[Dict[str, Any]] = context.get("reference")
    capture.create()
    fixture_digest = sha256_bytes(json.dumps(manifest, sort_keys=True).encode("utf-8"))
    physical = int(host["physicalCpu"])
    cap = effective_load_cap(reference, physical)
    lineage_root = run_id if reference is None else reference["lineageRoot"]
    store = OwnershipStore(capture.root / "ownership.json", {
        "schema": OWNERSHIP_SCHEMA_VERSION, "runId": run_id, "captureDir": str(capture.root),
        "mainRoot": str(main_root), "benchRoot": str(owner.bench_root), "commit": commit, "state": "creating",
    })
    # Daemon state carry-over (fixed arm paths share daemon state across runs): names/sizes only.
    for arm in ARMS:
        store.data.setdefault("daemonStateBefore", {})[arm] = {
            "stateDir": str(cond.compute_paths(owner.arm_path(arm)).state_dir),
            **state_inventory(Path(cond.compute_paths(owner.arm_path(arm)).state_dir)),
        }
    store.save()
    write_json_atomic(owner.pointer, {"schema": OWNERSHIP_SCHEMA_VERSION, "runId": run_id,
                                      "captureDir": str(capture.root), "ownershipFile": "ownership.json",
                                      "benchRoot": str(owner.bench_root), "createdAt": utc_now_iso()})
    runtime_hashes = tree_file_hashes(main_root, commit)
    base_manifest: Dict[str, Any] = {
        "schema": CAPTURE_SCHEMA_VERSION,
        "runId": run_id,
        "createdAt": utc_now_iso(),
        "commit": commit,
        "ref": ns.ref,
        "mainRepo": context["mainMeta"],
        "instrumentationMode": "full",
        "instrumentationIdentity": sorted({recipe.instrumentation for recipe in recipes}),
        "requestedDsymPolicy": "full",
        "effectiveDsymPolicy": "on",
        "wrapperCapability": WRAPPER_CAPABILITY,
        "treatment": "none",
        "armMeaning": "worktree location only; both arms run the same full-dSYM wrapper",
        "policyEnv": {key: environ.get(key) for key in POLICY_ENV_KEYS},
        "packagingGate": PACKAGING_GATE,
        "capabilities": context.get("capabilities") or {},
        "scrubbedJobEnv": list(SCRUBBED_JOB_ENV_KEYS),
        "host": host,
        "harness": harness_provenance(main_root, commit),
        "fixtureVersion": manifest["fixtureVersion"],
        "fixtureDigest": fixture_digest,
        "probeMembership": membership,
        "runtimeFileSha256": runtime_hashes,
        "scenarios": [recipe.name for recipe in recipes],
        "statisticalRoles": {recipe.name: recipe.role for recipe in recipes},
        "commands": {recipe.name: ["./conductor", recipe.operation, *recipe.cli_args, "--async", "--json",
                                   "--request-key", "<per-attempt>"] for recipe in recipes},
        "comparisonMeta": {recipe.name: comparison_meta(host, fixture_digest, recipe) for recipe in recipes},
        "protocol": {"primersPerArm": PRIMERS_PER_ARM, "blocks": ns.blocks, "extendedBlocks": EXTENDED_BLOCKS,
                     "positionRetries": POSITION_RETRIES, "retryBaselineAttempts": RETRY_BASELINE_ATTEMPTS,
                     "invalidMinAttempts": INVALID_MIN_ATTEMPTS,
                     "invalidMaxFraction": INVALID_MAX_FRACTION, "aaBoundAbsSeconds": AA_BOUND_ABS_S,
                     "aaBoundRel": AA_BOUND_REL, "minPairs": MIN_PAIRS, "confidence": CONFIDENCE,
                     "iterations": BOOTSTRAP_ITERATIONS, "seed": BOOTSTRAP_SEED, "blockSize": PAIR_BLOCK_SIZE,
                     "primaryInterval": PRIMARY_INTERVAL, "secondaryInterval": SECONDARY_CLIENT_INTERVAL,
                     "terminalPollSeconds": TERMINAL_POLL_S, "readinessPollSeconds": READINESS_POLL_S,
                     "readinessTimeoutSeconds": READINESS_TIMEOUT_S, "terminalTimeoutSeconds": TERMINAL_TIMEOUT_S,
                     "metricsTimeoutSeconds": METRICS_TIMEOUT_S, "thermalIntervalSeconds": THERMAL_INTERVAL_S,
                     "thermalMaxGapSeconds": THERMAL_MAX_GAP_S, "confirmationRule": CONFIRMATION_RULE},
        "admission": {"effectiveLoad1Cap": cap, "physicalCpu": physical, "logicalCpu": host["logicalCpu"],
                      "rule": ("load1 <= physical CPU count (fresh calibration)" if reference is None
                               else "load1 <= min(referenced pinned threshold, physical CPU count); never raised")},
        "calibrationReference": reference,
        "lineageRoot": lineage_root,
        "isolation": "checkout-local outputs and caches only; machine slots, conductor global state and global "
                     "SwiftPM/module caches are shared; no claim of global cache or write isolation; each fixed arm "
                     "path reuses its daemon state directory across runs (inventory in ownership.json)",
        "foreignWork": "pre-admission load, sampled thermal state, configured-slot probes and per-job slot contention; "
                       "evidence means no observed foreign SLOT contention, not no foreign machine work",
        "arms": {},
    }
    capture.write("manifest.json", base_manifest)
    print(f"swift-bench: run {run_id}; capture {capture.root}", file=sys.stderr, flush=True)
    clients: Dict[str, ConductorClient] = {}
    ledgers: Dict[str, FixtureLedger] = {}
    session: Optional[Session] = None
    outcome: Dict[str, Any] = {"exitCode": EXIT_HARNESS_FAILURE, "reason": None}
    try:
        for arm in ARMS:
            path = owner.arm_path(arm)
            # Recorded before creation so an interrupted add is never an unrecorded path.
            store.arms[arm] = {"arm": arm, "path": str(path), "realpath": os.path.join(os.path.realpath(owner.dir), arm),
                               "parentRealpath": os.path.realpath(owner.dir), "commit": commit,
                               "commonDir": owner.common_dir(main_root), "created": False, "cleanup": "active"}
            store.save()
            record = owner.create(arm, commit)
            if record["realpath"] != store.arms[arm]["realpath"]:
                raise HarnessError(f"{arm}: created realpath {record['realpath']} != pinned location")
            store.arms[arm].update(record)
            store.save()
            owner.verify_identity(store.arms[arm])
            owner.write_marker(store.arms[arm], run_id)
            store.arms[arm]["markerWritten"] = True
            tree = Path(store.arms[arm]["realpath"])
            destinations = scratch_destinations(tree)
            for value in destinations.values():
                Path(value).parent.mkdir(parents=True, exist_ok=True)
            store.arms[arm]["destinations"] = destinations
            clients[arm] = ConductorClient(cond, tree, job_environment(environ, destinations))
            store.arms[arm]["daemonPaths"] = {"stateDir": str(clients[arm].paths.state_dir),
                                              "socketPath": str(clients[arm].paths.socket_path),
                                              "repoHash": clients[arm].paths.repo_hash}
            store.save()
        expected_digests = {}
        env_classes = {}
        for arm in ARMS:
            tree = Path(store.arms[arm]["realpath"])
            expected_digests[arm] = metrics.content_digest(tree / rel for rel in CONDUCTOR_DIGEST_FILES)
            actual = {rel: sha256_file(tree / rel) for rel in RUNTIME_FILES}
            for rel, digest in runtime_hashes.items():
                if digest is None or actual[rel] != digest:
                    raise HarnessError(f"{arm}: {rel} differs from {commit} or is missing")
            env_classes[arm] = environment_class(clients[arm].env, tree, clients[arm].passthrough_keys())
            base_manifest["arms"][arm] = {"runtimeFileSha256": actual, "expectedConductorDigest": expected_digests[arm],
                                          "environmentClass": env_classes[arm]["class"],
                                          "environmentKeys": env_classes[arm]["keys"],
                                          "environmentDigests": env_classes[arm]["digests"]}
        if env_classes[ARM_ON]["class"] != env_classes[ARM_SKIP]["class"]:
            raise HarnessError("arm environment classes differ; Step 9 arms differ only by location")
        base_manifest["expectedConductorDigest"] = expected_digests
        capture.write("manifest.json", base_manifest)

        def busy_for(arm: str) -> Callable[[], Optional[str]]:
            return lambda: session.busy_reason(arm) if session is not None else None

        def persist_ledgers() -> None:
            store.data["fixtureLedgers"] = {name: ledger.snapshot() for name, ledger in ledgers.items()}
            store.save()

        for arm in ARMS:
            ledgers[arm] = FixtureLedger(Path(store.arms[arm]["realpath"]), manifest,
                                         busy_check=busy_for(arm), on_change=persist_ledgers)
            ledgers[arm].install()
        store.data["state"] = "active"
        store.save()

        def on_daemon_seen(arm: str, status: Mapping[str, Any]) -> None:
            tree = store.arms[arm]["realpath"]
            if os.path.realpath(str(status.get("repoRoot"))) != tree:
                raise HarnessError(f"{arm}: daemon repoRoot {status.get('repoRoot')} != {tree}")
            pid = status.get("pid")
            if not isinstance(pid, int) or not clients[arm].verify_owned_daemon(pid):
                raise HarnessError(f"{arm}: daemon pid {pid} identity could not be independently verified")
            store.arms[arm]["daemon"] = {
                **clients[arm].daemon_identity(pid),
                **{key: status.get(key) for key in ("stateDir", "socketPath", "conductorDigest", "protocolVersion",
                                                    "globalHeavySlotCount", "xctestSlotCount", "timingEnabled")},
                "recordedAt": utc_now_iso(),
            }
            store.save()

        def on_cold_reset(arm: str) -> None:
            record = store.arms[arm]
            owner.verify_identity(record, run_id)
            build = Path(record["realpath"]) / ".build"
            st = os.lstat(build)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                raise HarnessError(f"{build} is not a real directory")
            shutil.rmtree(build)
            owner.write_marker(record, run_id)
            for value in record["destinations"].values():
                Path(value).parent.mkdir(parents=True, exist_ok=True)

        probe = HostProbe(cond, main_root, clients[ARM_ON].env)
        session = Session(
            run_id=run_id, capture=capture, clients=clients, probe=probe, ledgers=ledgers,
            expected_digests=expected_digests, admission=Admission(threshold=cap, physical_cpu=physical),
            blocks=ns.blocks, on_cold_reset=on_cold_reset, on_daemon_seen=on_daemon_seen, store=store,
        )
        for recipe in recipes:
            session.run_scenario(recipe)
        gating = [result for result in session.results.values() if result["statisticalRole"] == ROLE_GATING]
        if all(result["verdict"] == "qualified" for result in gating):
            outcome = {"exitCode": EXIT_QUALIFIED, "reason": None if gating else "diagnostic_recorded"}
        else:
            outcome = {"exitCode": EXIT_INCONCLUSIVE, "reason": "calibration_outside_bound"}
    except StopRun as exc:
        outcome = {"exitCode": EXIT_INCONCLUSIVE, "reason": exc.reason, "details": exc.details}
        print(f"swift-bench: inconclusive: {exc.reason}", file=sys.stderr)
    except HarnessError as exc:
        outcome = {"exitCode": EXIT_HARNESS_FAILURE, "reason": str(exc)}
        print(f"swift-bench: harness failure: {exc}", file=sys.stderr)
    except KeyboardInterrupt:
        outcome = {"exitCode": EXIT_HARNESS_FAILURE, "reason": "interrupted"}
    except Exception as exc:  # noqa: BLE001 - unexpected: still clean up with full checks
        outcome = {"exitCode": EXIT_HARNESS_FAILURE, "reason": f"{type(exc).__name__}: {exc}"}
        print(f"swift-bench: unexpected error: {outcome['reason']}", file=sys.stderr)
    store.data["state"] = "sampling_done"
    store.data["samplingOutcome"] = outcome
    store.save()
    cleanup = Cleaner(cond, owner, store, capture, ledgers,
                      lambda arm, record: clients.get(arm) or ConductorClient(cond, Path(record["realpath"]), {})).run()
    exit_code = outcome["exitCode"]
    if not cleanup["ok"]:
        exit_code = EXIT_HARNESS_FAILURE
    calibration = None
    if session is not None:
        passed = [r for r in session.results.values()
                  if r["statisticalRole"] == ROLE_GATING and r["verdict"] == "qualified"]
        loads = [value for r in passed for value in (r["retainedLoad1Range"] or [])]
        if reference is None:
            pinned = max(loads) if loads else None
        else:
            pinned = float(reference["pinnedLoad1Threshold"])  # inherited, never raised
        calibration = {
            "schema": CAPTURE_SCHEMA_VERSION,
            "runId": run_id,
            "lineageRoot": lineage_root,
            "reference": reference,
            "qualifiedScenarios": [r["scenario"] for r in passed],
            "pinnedLoad1Threshold": pinned,
            "effectiveLoad1Cap": cap,
            "physicalCpu": physical,
            "observedLoad1Range": [min(loads), max(loads)] if loads else None,
            "reusable": bool(passed) and exit_code == EXIT_QUALIFIED and cleanup["ok"],
            "rule": "a capture referencing this calibration admits load1 <= min(pinned, physical CPU); never raised",
            "diagnosticOnly": not any(r["statisticalRole"] == ROLE_GATING for r in session.results.values()),
        }
        capture.write("calibration.json", calibration)
    result = {
        "schema": CAPTURE_SCHEMA_VERSION,
        "runId": run_id,
        "exitCode": exit_code,
        "outcome": outcome,
        "cleanup": cleanup,
        "scenarios": session.results if session else {},
        "attempts": {"measured": session.measured_attempts if session else 0,
                     "invalid": session.invalid_attempts if session else 0},
        "calibration": calibration,
        "finishedAt": utc_now_iso(),
    }
    capture.write("result.json", result)
    print(f"swift-bench: exit {exit_code}; result {capture.root / 'result.json'}", file=sys.stderr)
    return exit_code


# ---------------------------------------------------------------------------
# Resumable cleanup


class Preserve(Exception):
    """Evidence is insufficient to proceed; the arm's state is preserved as-is."""


class Cleaner:
    """Per-arm resumable state machine over ``ownership.json``.

    active -> (requests reconciled, jobs terminal) jobsTerminal -> (owned daemon
    termination verified, durably recorded as ``daemonTermination``; then its
    launchd job verified unloaded, recorded as ``launchd``) daemonStopped ->
    (final removal proof, including a fresh launchd check) removePending ->
    removed. Every transition is durable before the next destructive step; a
    rerun resumes from the recorded state (an interrupted unload resumes without
    stopping again), but the forced removal always re-runs the final removal
    proof. Any doubt raises ``Preserve`` and leaves the arm untouched.
    """

    def __init__(self, cond: Any, owner: WorktreeOwner, store: OwnershipStore, capture: Optional[Capture],
                 ledgers: Mapping[str, Optional[FixtureLedger]],
                 client_for: Callable[[str, Mapping[str, Any]], Any], *, clock: Any = Clock,
                 scan: Callable[[str], Optional[List[int]]] = processes_mentioning) -> None:
        self.cond = cond
        self.owner = owner
        self.store = store
        self.capture = capture
        self.ledgers = dict(ledgers)
        self.client_for = client_for
        self.clock = clock
        self.scan = scan

    # -- helpers ------------------------------------------------------------------

    def _run_id_for_marker(self, record: Mapping[str, Any]) -> Optional[str]:
        return self.store.data.get("runId") if record.get("markerWritten") else None

    def _quiet(self, text: str, what: str) -> None:
        pids = self.scan(text)
        if pids is None:
            raise Preserve(f"cannot enumerate processes to prove {what}")
        if pids:
            raise Preserve(f"processes {pids[:8]} still mention {what}")

    def _quiet_tree(self, arm: str, record: Mapping[str, Any], why: str) -> None:
        for text in sorted({str(record["realpath"]), str(record["path"])}):
            self._quiet(text, f"{arm} worktree ({why})")

    def _final_removal_proof(self, arm: str, record: Mapping[str, Any], client: Any) -> None:
        """Fresh proof immediately before every forced removal, including a resumed one.

        An earlier checkpoint never authorizes deleting files that appeared since:
        identity, marker, fixture ledger and exact dirtiness are re-verified, and no
        live daemon, open owned request or process mentioning the tree may remain.
        """
        self.owner.verify_identity(record, self._run_id_for_marker(record))
        if client.live_pid() is not None:
            raise Preserve("a daemon started after it was recorded stopped")
        open_requests = sorted(key for key, request in self.store.requests.items()
                               if request.get("arm") == arm and request.get("state") not in ("terminal", "notAccepted"))
        if open_requests:
            raise Preserve(f"owned requests {open_requests[:8]} are not terminal")
        self._quiet_tree(arm, record, "before removal")
        self.owner.verify_dirtiness(record, self.ledgers.get(arm))

    def _daemon(self, arm: str, record: Dict[str, Any], client: Any) -> Optional[int]:
        """The verified owned live daemon pid, None when provably not running; raises Preserve otherwise."""
        pid = client.live_pid()
        if pid is None:
            if os.path.lexists(client.paths.socket_path):
                # A socket without a live recorded pid: the daemon may be starting.
                self._quiet_tree(arm, record, "socket present without a live daemon pid")
            return None
        recorded = record.get("daemon") or {}
        if not client.verify_owned_daemon(pid):
            raise Preserve(f"live daemon pid {pid} identity could not be independently verified")
        if recorded.get("pid") is None:
            # Unrecorded daemon: adopted only with the independent identity proof above.
            record["daemon"] = {**client.daemon_identity(pid), "adopted": True, "recordedAt": utc_now_iso()}
            self.store.save()
        elif recorded.get("pid") != pid or (recorded.get("processStart")
                                            and recorded["processStart"] != self.cond.process_start_token(pid)):
            raise Preserve(f"live daemon pid {pid} is not the recorded owned daemon {recorded.get('pid')}")
        return pid

    def _verify_termination(self, arm: str, record: Dict[str, Any], client: Any, entry: Dict[str, Any]) -> None:
        """Stop (or prove already stopped) the owned daemon; the result is checkpointed before any unload."""
        pid = self._daemon(arm, record, client)
        if pid is not None:
            try:
                evidence = client.stop_daemon(record["daemon"])
            except HarnessError as exc:
                raise Preserve(str(exc))
        else:
            evidence = {"stoppedPid": None, "alreadyStopped": True}
        if client.live_pid() is not None:
            raise Preserve("a daemon is alive after the verified stop")
        entry["daemon"] = evidence
        record["daemonTermination"] = {**evidence, "verifiedAt": utc_now_iso()}
        self.store.save()

    def _ensure_unloaded(self, arm: str, record: Dict[str, Any], client: Any, entry: Dict[str, Any]) -> None:
        """Unload the owned daemon's launchd job after verified termination, then prove it unloaded.

        Idempotent and re-checked before every removal: a loaded or unknown label
        is booted out only when no daemon is live and no process mentions the tree.
        A still-present tree is freshly re-proven this run's (identity and marker)
        before any launchd operation, so neither an earlier proof nor a resumed
        checkpoint authorizes a bootout after the tree changed (S9-R0-01).
        """
        if client.live_pid() is not None:
            raise Preserve("a daemon started after it was recorded stopped; its launchd job is not unloaded while "
                           "it runs")
        if os.path.lexists(record["path"]):
            self.owner.verify_identity(record, self._run_id_for_marker(record))
        label = client.launchd_label()
        loaded = client.launchd_loaded()
        if loaded is not False:
            self._quiet_tree(arm, record, "before launchd bootout")
            client.bootout_launchd()
            after = client.launchd_loaded()
            if after is not False:
                state = "unknown" if after is None else "still loaded"
                raise Preserve(f"launchd job {label} is {state} after bootout")
        evidence = {"label": label, "loadedBefore": loaded, "bootedOut": loaded is not False, "unloaded": True,
                    "verifiedAt": utc_now_iso()}
        record["launchd"] = evidence
        self.store.save()
        entry["launchd"] = evidence

    def _drain_ticket(self, client: Any, ticket: str) -> str:
        payload = client.status(ticket=ticket)
        if payload.get("state") in TERMINAL_STATES:
            return str(payload.get("state"))
        client.cancel(ticket)
        deadline = self.clock.monotonic() + CANCEL_GRACE_S
        while True:
            state = client.status(ticket=ticket).get("state")
            if state in TERMINAL_STATES:
                return str(state)
            if self.clock.monotonic() > deadline:
                raise Preserve(f"owned ticket {ticket} not terminal after cancel")
            self.clock.sleep(1.0)

    def _reconcile_requests(self, arm: str, record: Dict[str, Any], client: Any, pid: Optional[int],
                            entry: Dict[str, Any]) -> None:
        for key, request in sorted(self.store.requests.items()):
            if request.get("arm") != arm or request.get("state") in ("terminal", "notAccepted"):
                continue
            if request.get("state") == "intent":
                producer = request.get("producer") or {}
                if producer and not producer.get("finished"):
                    alive = process_alive_with_token(self.cond, producer.get("pid"), producer.get("startToken"))
                    if alive is not False:
                        raise Preserve(f"{key}: submit producer pid {producer.get('pid')} may be alive")
                self._quiet(key, f"request key {key}")
                if pid is not None:
                    try:
                        found = client.status(request_key=key)
                    except Exception as exc:  # noqa: BLE001
                        if REQUEST_KEY_NOT_FOUND_TEXT not in str(exc):
                            raise Preserve(f"{key}: lookup failed: {exc}")
                        self.store.update_request(key, "notAccepted", reason="not found after producer finished",
                                                  resolvedBy="cleanup")
                        entry["steps"].append(f"{key} not accepted")
                        continue
                    if found.get("requestKey") not in (None, key) or not found.get("ticket"):
                        raise Preserve(f"{key}: lookup returned a mismatched job")
                    self.store.update_request(key, "accepted", ticket=str(found["ticket"]), recoveredBy="cleanup")
                else:
                    self._quiet_tree(arm, record, "no live daemon")
                    self.store.update_request(key, "notAccepted", reason="no daemon and producer finished",
                                              resolvedBy="cleanup")
                    entry["steps"].append(f"{key} not accepted (no daemon)")
                    continue
            request = self.store.requests[key]
            ticket = request.get("ticket")
            if pid is not None:
                state = self._drain_ticket(client, str(ticket))
                self.store.update_request(key, "terminal", terminalState=state, resolvedBy="cleanup")
            else:
                self._quiet_tree(arm, record, "no live daemon")
                self.store.update_request(key, "terminal", terminalState="unknown-daemon-gone", resolvedBy="cleanup")
            entry["steps"].append(f"{key} terminal")

    # -- arm state machine --------------------------------------------------------

    def clean_arm(self, arm: str, entry: Dict[str, Any]) -> None:
        record = self.store.arms[arm]
        self.owner.pin(arm, record)
        state = self.store.arm_state(arm)
        entry["resumedFrom"] = state
        if state == "removed":
            if not self.owner.absent_and_deregistered(record):
                raise Preserve("recorded removed but the path exists or is still registered")
            if record.get("legacyCleanup") and not (record.get("launchd") or {}).get("unloaded"):
                # Reconstructed from schema-1 evidence: v1 never verified the label unloaded.
                self._ensure_unloaded(arm, record, self.client_for(arm, record), entry)
            entry["steps"].append("already removed")
            return
        if not record.get("created"):
            if self.owner.absent_and_deregistered(record):
                self.store.set_arm_state(arm, "removed", "never created")
                entry["steps"].append("never created")
                return
            # Interrupted between 'git worktree add' and its record: adopt only with identity proof.
            proof = dict(record, created=True)
            self.owner.verify_identity(proof)
            record.update(created=True, adopted=True, adoptedAt=utc_now_iso())
            self.store.save()
            entry["steps"].append("adopted unrecorded creation by identity proof")
        if state == "removePending":
            if self.owner.absent_and_deregistered(record):
                if not (record.get("launchd") or {}).get("unloaded"):
                    self._ensure_unloaded(arm, record, self.client_for(arm, record), entry)
                self.store.set_arm_state(arm, "removed", "removal completed before interruption")
                entry["steps"].append("removal had completed")
                return
            if not os.path.lexists(record["path"]):
                raise Preserve("path missing but still registered; inspect 'git worktree list' manually")
            # The tree may have changed since the checkpoint: re-prove everything, never reuse it.
            resumed_client = self.client_for(arm, record)
            self._ensure_unloaded(arm, record, resumed_client, entry)
            self._final_removal_proof(arm, record, resumed_client)
            self.owner.remove(record)
            self.store.set_arm_state(arm, "removed", "resumed removal")
            entry["steps"].append("worktree removed (resumed)")
            return
        if not os.path.lexists(record["path"]):
            raise Preserve(f"{record['path']} missing in state {state}")
        # Identity before any RPC.
        self.owner.verify_identity(record, self._run_id_for_marker(record))
        client = self.client_for(arm, record)
        if state == "active":
            pid = self._daemon(arm, record, client)
            self._reconcile_requests(arm, record, client, pid, entry)
            if pid is not None:
                status = client.daemon_status() or {}
                if status.get("runningJobs") or status.get("queuedJobs"):
                    raise Preserve("owned daemon still reports active or queued jobs")
            self.store.set_arm_state(arm, "jobsTerminal", {"daemonPid": pid})
            state = "jobsTerminal"
        if state == "jobsTerminal":
            termination = record.get("daemonTermination")
            if termination:
                # Termination was verified before an interruption; resume with the unload only.
                entry["daemon"] = {key: value for key, value in termination.items() if key != "verifiedAt"}
                entry["steps"].append("termination already verified")
            else:
                self._verify_termination(arm, record, client, entry)
            self._ensure_unloaded(arm, record, client, entry)
            self.store.set_arm_state(arm, "daemonStopped", {**entry["daemon"], "launchd": record["launchd"]})
            state = "daemonStopped"
        if state == "daemonStopped":
            self._ensure_unloaded(arm, record, client, entry)
            self._final_removal_proof(arm, record, client)
            self.store.set_arm_state(arm, "removePending", "identity and dirtiness verified")
            self.owner.remove(record)
            self.store.set_arm_state(arm, "removed", "worktree removed")
            entry["steps"].append("worktree removed")
            return
        raise Preserve(f"unknown cleanup state {state}")

    def run(self) -> Dict[str, Any]:
        report: Dict[str, Any] = {"ok": True, "startedAt": utc_now_iso(), "arms": {}}
        unrecorded = [str(self.owner.arm_path(arm)) for arm in ARMS
                      if arm not in self.store.arms and os.path.lexists(self.owner.arm_path(arm))]
        if unrecorded:
            report["ok"] = False
            report["unrecordedPaths"] = unrecorded
        if self.ledgers:
            self.store.data["fixtureLedgers"] = {name: ledger.snapshot()
                                                 for name, ledger in self.ledgers.items() if ledger}
        for arm in ARMS:
            if arm not in self.store.arms:
                continue
            entry: Dict[str, Any] = {"steps": []}
            report["arms"][arm] = entry
            try:
                self.clean_arm(arm, entry)
                entry["ok"] = True
            except (Preserve, HarnessError, OSError, subprocess.SubprocessError) as exc:
                entry["ok"] = False
                entry["error"] = f"{type(exc).__name__}: {exc}"[:600]
                report["ok"] = False
            except Exception as exc:  # noqa: BLE001 - any doubt preserves the arm
                entry["ok"] = False
                entry["error"] = f"{type(exc).__name__}: {exc}"[:600]
                report["ok"] = False
            entry["state"] = self.store.arm_state(arm)
        all_removed = all(self.store.arm_state(arm) == "removed" for arm in self.store.arms)
        report["ok"] = report["ok"] and all_removed
        report["finishedAt"] = utc_now_iso()
        self.store.data["state"] = "cleaned" if report["ok"] else "cleanup_failed"
        self.store.data["cleanup"] = report
        self.store.data.setdefault("cleanupRuns", []).append(
            {"at": report["finishedAt"], "ok": report["ok"],
             "arms": {arm: entry.get("state") for arm, entry in report["arms"].items()}})
        self.store.save()
        if report["ok"]:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.owner.pointer)
            report["pointerRemoved"] = True
        return report


# Step text a schema-1 cleanup appended only after ``git worktree remove`` and its
# absent/deregistered check succeeded (v1 booted the launchd job out before that).
LEGACY_REMOVED_STEP = "worktree removed"


def legacy_removal_evidence(ownership: Mapping[str, Any], arm: str) -> Optional[Dict[str, Any]]:
    """The schema-1 cleanup report's proof that ``arm`` was removed, or None.

    Only the immutable v1 report counts; the current absent/deregistered check is
    made by the cleaner before the reconstructed state is accepted.
    """
    report = ownership.get("cleanup")
    arms = report.get("arms") if isinstance(report, dict) else None
    entry = arms.get(arm) if isinstance(arms, dict) else None
    if not isinstance(entry, dict):
        return None
    steps = entry.get("steps")
    if not isinstance(steps, list) or LEGACY_REMOVED_STEP not in steps:
        return None
    return {"source": "schema-1 ownership.json cleanup report", "steps": [str(step) for step in steps],
            "ok": entry.get("ok"), "daemon": entry.get("daemon")}


def apply_legacy_cleanup_evidence(store: OwnershipStore, ownership: Mapping[str, Any]) -> List[str]:
    """Advance still-``active`` normalized arms that the v1 cleanup provably removed.

    Idempotent; used for a fresh normalization and for a recovery record written
    by an earlier harness. The cleaner's ``removed`` branch then requires the path
    to be absent and deregistered now and verifies the launchd job unloaded.
    """
    advanced: List[str] = []
    for arm, record in store.arms.items():
        if store.arm_state(arm) != "active":
            continue
        evidence = legacy_removal_evidence(ownership, arm)
        if evidence is None:
            continue
        record["legacyCleanup"] = evidence
        store.set_arm_state(arm, "removed", {"reconstructedFrom": "schema-1 cleanup evidence"})
        advanced.append(arm)
    return advanced


def normalize_v1_ownership(ownership: Mapping[str, Any], capture: Capture) -> Dict[str, Any]:
    """Schema-2 recovery view of a schema-1 record; the original file is never rewritten.

    Arms the v1 cleanup report proves removed are reconstructed as ``removed``
    (checked against current absence by the cleaner); every other arm resumes
    from ``active``.
    """
    data: Dict[str, Any] = {key: value for key, value in ownership.items() if key not in ("arms",)}
    data.update(schema=OWNERSHIP_SCHEMA_VERSION, normalizedFrom=1, normalizedAt=utc_now_iso(),
                arms={}, requests={}, transitions=[])
    for arm, record in (ownership.get("arms") or {}).items():
        data["arms"][arm] = {**record, "arm": arm, "cleanup": "active", "markerWritten": True,
                             "created": record.get("created", True)}
    apply_legacy_cleanup_evidence(OwnershipStore(None, data), ownership)
    with contextlib.suppress(OSError):
        for line in capture.attempts.read_text(encoding="utf-8").splitlines():
            with contextlib.suppress(json.JSONDecodeError):
                row = json.loads(line)
                key = row.get("requestKey")
                if not key or row.get("arm") not in ARMS:
                    continue
                request = data["requests"].setdefault(key, {"state": "intent", "arm": row["arm"],
                                                            "producer": None, "fromV1": True})
                if row.get("ticket"):
                    request["ticket"] = row["ticket"]
                    if request["state"] == "intent":
                        request["state"] = "accepted"
                if row.get("phase") == "result" and row.get("state") in TERMINAL_STATES:
                    request["state"] = "terminal"
    # A v1 producer could have been killed with its runner; its identity was never recorded.
    for request in data["requests"].values():
        if request["state"] == "intent":
            request["producer"] = None
    return data


def cmd_clean(ns: argparse.Namespace) -> int:
    try:
        main_root, _main_meta = resolve_main_repo(getattr(ns, "main_repo", None))
    except HarnessError as exc:
        print(f"swift-bench clean: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    cond = load_conductor()
    owner = WorktreeOwner(main_root, benchmark_root(cond, main_root))
    try:
        owner.acquire_control_lock()
    except HarnessError as exc:
        print(f"swift-bench clean: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    try:
        if not os.path.lexists(owner.pointer):
            leftovers = [str(owner.arm_path(arm)) for arm in ARMS if os.path.lexists(owner.arm_path(arm))]
            if leftovers:
                print(f"swift-bench clean: unowned paths present, not touching: {leftovers}", file=sys.stderr)
                return EXIT_HARNESS_FAILURE
            print("swift-bench clean: nothing recorded")
            return EXIT_QUALIFIED
        try:
            st = os.lstat(owner.pointer)
            if not stat.S_ISREG(st.st_mode):
                raise HarnessError(f"{owner.pointer} is not a regular file")
            pointer = json.loads(owner.pointer.read_text(encoding="utf-8"))
            run_id = str(pointer.get("runId") or "")
            if not run_id or "/" in run_id or run_id.startswith("."):
                raise HarnessError("pointer runId is malformed")
            expected_dir = os.path.join(os.path.realpath(owner.bench_root / "swift"), run_id)
            if os.path.realpath(str(pointer.get("captureDir"))) != expected_dir:
                raise HarnessError(f"pointer captureDir {pointer.get('captureDir')} != {expected_dir}")
            capture = Capture(Path(expected_dir))
            ownership = json.loads((capture.root / "ownership.json").read_text(encoding="utf-8"))
            if ownership.get("runId") != run_id:
                raise HarnessError("pointer and ownership record disagree")
            if ownership.get("schema") == OWNERSHIP_SCHEMA_VERSION:
                store = OwnershipStore(capture.root / "ownership.json", ownership)
            else:
                recovery = capture.root / "ownership-recovery.json"
                if os.path.lexists(recovery):
                    store = OwnershipStore(recovery, json.loads(recovery.read_text(encoding="utf-8")))
                    apply_legacy_cleanup_evidence(store, ownership)
                else:
                    store = OwnershipStore(recovery, normalize_v1_ownership(ownership, capture))
                    store.save()
            for arm, record in store.arms.items():
                owner.pin(arm, record)
                if record.get("commonDir") and record["commonDir"] != owner.common_dir(main_root):
                    raise HarnessError(f"{arm}: recorded common dir differs from --main-repo")
        except (OSError, json.JSONDecodeError, KeyError, TypeError, HarnessError) as exc:
            print(f"swift-bench clean: preserving everything: {exc}", file=sys.stderr)
            return EXIT_HARNESS_FAILURE
        manifest = load_fixture_manifest()
        ledgers: Dict[str, Optional[FixtureLedger]] = {}
        for arm, record in store.arms.items():
            snapshot = (store.data.get("fixtureLedgers") or {}).get(arm) or {}
            if snapshot.get("entries"):
                ledger = FixtureLedger(Path(record["realpath"]), manifest, busy_check=lambda: None)
                ledger.entries = snapshot["entries"]
                ledgers[arm] = ledger
        cleaner = Cleaner(cond, owner, store, capture, {k: v for k, v in ledgers.items() if v},
                          lambda arm, record: ConductorClient(cond, Path(record["realpath"]), {}))
        report = cleaner.run()
        print(json.dumps(report, indent=2, default=str))
        return EXIT_QUALIFIED if report["ok"] else EXIT_HARNESS_FAILURE
    finally:
        owner.release_control_lock()


# ---------------------------------------------------------------------------
# Capture loading and eligibility


def capture_root_for(location: str, bench_root: Optional[Path]) -> Path:
    root = Path(location).expanduser()
    if root.is_dir():
        return Path(os.path.realpath(root))
    if bench_root is None or "/" in location or not location or location.startswith("."):
        raise HarnessError(f"capture {location!r} not found")
    candidate = bench_root / "swift" / location
    if not candidate.is_dir():
        raise HarnessError(f"capture {location!r} not found under {bench_root / 'swift'}")
    return Path(os.path.realpath(candidate))


def read_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot read {path}: {exc}") from exc


def read_attempt_rows(root: Path, strict: bool = True) -> List[Dict[str, Any]]:
    """Rows of ``attempts.jsonl``; with ``strict`` a non-object row is malformed (exit 3)."""
    rows: List[Dict[str, Any]] = []
    path = root / "attempts.jsonl"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise HarnessError(f"cannot read {path}: {exc}") from exc
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"{path}:{number} is not JSON: {exc}") from exc
        if isinstance(row, dict):
            rows.append(row)
        elif strict:
            raise HarnessError(f"{path}:{number} is not a JSON object")
    return rows


# ---------------------------------------------------------------------------
# Capture evidence validation (OD23): one validator for compare and calibration references.
#
# Malformed structure, or a summary that contradicts the retained rows or raw
# files it summarizes, is a harness/integrity failure (HarnessError, exit 3).
# Well-formed evidence that is missing or insufficient for a verdict is an
# ineligibility reason (exit 2). Statistics only see pairs reconstructed from
# validated, uniquely identified retained attempts.

HEX_DIGEST = re.compile(r"[0-9a-f]{64}")
RAW_EVIDENCE_FIELDS = (("rawStatus", "status"), ("rawTerminal", "terminal"), ("rawTimings", "timings"),
                       ("rawThermal", "thermal"))
STATUS_ROW_KEYS = ("ticket", "requestKey", "state", "exitCode", "conductorDigest", "fingerprint", "operation")
LINEAGE_MAX_DEPTH = 16


def _malformed(where: str, problem: str) -> HarnessError:
    return HarnessError(f"malformed capture evidence: {where}: {problem}")


def _obj(value: Any, where: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise _malformed(where, f"expected an object, found {type(value).__name__}")
    return value


def _arr(value: Any, where: str) -> List[Any]:
    if not isinstance(value, list):
        raise _malformed(where, f"expected a list, found {type(value).__name__}")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise _malformed(where, f"expected a non-empty string, found {value!r}")
    return value


def _number(value: Any, where: str) -> float:
    if not finite_nonnegative(value):
        raise _malformed(where, f"expected a finite non-negative number, found {value!r}")
    return float(value)


def _digest(value: Any, where: str) -> Optional[str]:
    if value is not None and not (isinstance(value, str) and HEX_DIGEST.fullmatch(value)):
        raise _malformed(where, f"expected a SHA-256 hex digest or null, found {value!r}")
    return value


def _dedupe(reasons: Iterable[str]) -> List[str]:
    return list(dict.fromkeys(reasons))


def validate_calibration_reference(value: Any, where: str) -> Dict[str, Any]:
    """The recorded reference fields (``load_calibration_reference``'s result) with their exact types."""
    reference = _obj(value, where)
    for key in ("captureDir", "runId", "lineageRoot"):
        _text(reference.get(key), f"{where}.{key}")
    _number(reference.get("pinnedLoad1Threshold"), f"{where}.pinnedLoad1Threshold")
    if _digest(reference.get("calibrationSha256"), f"{where}.calibrationSha256") is None:
        raise _malformed(f"{where}.calibrationSha256", "expected a SHA-256 hex digest, found None")
    for index, name in enumerate(_arr(reference.get("qualifiedScenarios"), f"{where}.qualifiedScenarios")):
        _text(name, f"{where}.qualifiedScenarios[{index}]")
    return reference


def validate_capture_structure(cap: Mapping[str, Any]) -> None:
    """Fixed-schema structure of a schema-2 capture's manifest, result and rows (raises on malformed)."""
    manifest, result, rows = cap["manifest"], cap["result"], cap["rows"]
    run_id = _text(manifest.get("runId"), "manifest.runId")
    _obj(manifest.get("host"), "manifest.host")
    for name, meta in _obj(manifest.get("comparisonMeta"), "manifest.comparisonMeta").items():
        _obj(meta, f"manifest.comparisonMeta.{name}")
    harness = _obj(manifest.get("harness"), "manifest.harness")
    files = _obj(harness.get("files"), "manifest.harness.files")
    for rel, entry in files.items():
        where = f"manifest.harness.files[{rel}]"
        entry = _obj(entry, where)
        runner = _digest(entry.get("runner"), f"{where}.runner")
        commit = _digest(entry.get("commit"), f"{where}.commit")
        if entry.get("match") is not (runner is not None and runner == commit):
            raise _malformed(where, "match flag contradicts the recorded runner/commit hashes")
    if harness.get("matchesCommit") is not all(entry["match"] for entry in files.values()):
        raise _malformed("manifest.harness.matchesCommit", "contradicts the per-file match flags")
    arms = _obj(manifest.get("arms"), "manifest.arms")
    if set(arms) != set(ARMS):
        raise _malformed("manifest.arms", f"expected exactly {list(ARMS)}, found {sorted(arms)}")
    for arm in ARMS:
        where = f"manifest.arms.{arm}"
        entry = _obj(arms[arm], where)
        for rel, value in _obj(entry.get("runtimeFileSha256"), f"{where}.runtimeFileSha256").items():
            _digest(value, f"{where}.runtimeFileSha256[{rel}]")
        digests = _obj(entry.get("environmentDigests"), f"{where}.environmentDigests")
        for key, value in digests.items():
            _digest(value, f"{where}.environmentDigests[{key}]")
        if _arr(entry.get("environmentKeys"), f"{where}.environmentKeys") != sorted(digests):
            raise _malformed(f"{where}.environmentKeys", "does not list exactly the digested keys")
        if entry.get("environmentClass") != sha256_bytes(canonical_json(digests)):
            raise _malformed(f"{where}.environmentClass", "does not hash the recorded environment digests")
        _text(entry.get("expectedConductorDigest"), f"{where}.expectedConductorDigest")
    admission = _obj(manifest.get("admission"), "manifest.admission")
    _number(admission.get("effectiveLoad1Cap"), "manifest.admission.effectiveLoad1Cap")
    _text(manifest.get("lineageRoot"), "manifest.lineageRoot")
    _text(manifest.get("treatment"), "manifest.treatment")
    if manifest.get("calibrationReference") is not None:
        validate_calibration_reference(manifest.get("calibrationReference"), "manifest.calibrationReference")
    _obj(result.get("cleanup"), "result.cleanup")
    for name, entry in _obj(result.get("scenarios"), "result.scenarios").items():
        _obj(entry, f"result.scenarios.{name}")
    attempt_ids: Set[str] = set()
    tickets: Set[str] = set()
    for row in rows:
        if row.get("phase") != "result":
            continue
        aid = _text(row.get("attemptId"), "attempts.jsonl result attemptId")
        if aid in attempt_ids:
            raise _malformed("attempts.jsonl", f"duplicate result row for attempt {aid}")
        attempt_ids.add(aid)
        if row.get("fingerprint") is not None:
            _text(row.get("fingerprint"), f"attempts.jsonl attempt {aid} fingerprint")
        if row.get("requestKey") != f"rpce-swift-bench-{run_id}-{aid}":
            raise _malformed(f"attempts.jsonl attempt {aid}", f"requestKey {row.get('requestKey')!r} is not this "
                                                              "run's key for the attempt")
        ticket = row.get("ticket")
        if ticket is not None:
            _text(ticket, f"attempts.jsonl attempt {aid} ticket")
            if ticket in tickets:
                raise _malformed("attempts.jsonl", f"ticket {ticket} appears in more than one result row")
            tickets.add(ticket)


def load_capture_root(root: Path) -> Dict[str, Any]:
    """A structurally validated schema-2 capture. Malformed -> HarnessError; schema 1 -> Ineligible."""
    manifest = read_json_file(root / "manifest.json")
    if not isinstance(manifest, dict):
        raise HarnessError(f"{root}/manifest.json is not an object")
    schema = manifest.get("schema")
    if schema in LEGACY_CAPTURE_SCHEMAS:
        raise Ineligible([f"legacy_capture_schema_{schema}"])
    if schema != CAPTURE_SCHEMA_VERSION:
        raise HarnessError(f"{root}: unknown capture schema {schema!r}")
    result = read_json_file(root / "result.json")
    if not isinstance(result, dict) or result.get("schema") != CAPTURE_SCHEMA_VERSION:
        raise HarnessError(f"{root}/result.json is malformed or not schema {CAPTURE_SCHEMA_VERSION}")
    if result.get("runId") != manifest.get("runId") or not manifest.get("runId"):
        raise HarnessError(f"{root}: manifest and result runIds disagree")
    cap = {"root": root, "manifest": manifest, "result": result, "rows": read_attempt_rows(root), "evidence": {}}
    validate_capture_structure(cap)
    return cap


def load_capture(reference: str, bench_root: Optional[Path]) -> Dict[str, Any]:
    """``<capture>#<arm>`` with an explicit known arm. Malformed -> HarnessError; v1 -> Ineligible."""
    location, sep, arm = reference.partition("#")
    if not sep or not arm:
        raise HarnessError(f"{reference!r}: an explicit arm is required (#{ARM_ON} or #{ARM_SKIP})")
    if arm not in ARMS:
        raise HarnessError(f"{reference!r}: unknown arm {arm!r}")
    cap = load_capture_root(capture_root_for(location, bench_root))
    cap.update(reference=reference, arm=arm)
    return cap


def _validate_phase_metrics_shape(pm: Mapping[str, Any], where: str) -> None:
    """The fields ``evaluate_sample`` reads must have their documented container types."""
    if pm.get("intervals") is not None:
        _obj(pm.get("intervals"), f"{where}.intervals")
    for index, wait in enumerate(_arr(pm.get("slotWaits", []), f"{where}.slotWaits")):
        _obj(wait, f"{where}.slotWaits[{index}]")
    for index, segment in enumerate(_arr(pm.get("segments", []), f"{where}.segments")):
        segment = _obj(segment, f"{where}.segments[{index}]")
        if segment.get("modules") is not None:
            for name, info in _obj(segment.get("modules"), f"{where}.segments[{index}].modules").items():
                _obj(info, f"{where}.segments[{index}].modules.{name}")


def _json_normalized(value: Any) -> Any:
    return json.loads(json.dumps(value, default=str))


def validate_raw_attempt(root: Path, row: Mapping[str, Any], recipe: Recipe, manifest: Mapping[str, Any]) -> Optional[str]:
    """Reconcile one retained row with its raw status/terminal/timings/thermal files.

    Returns ``retained_raw_missing`` when a raw file is absent (ineligible), raises
    when present evidence contradicts the row or cannot support a valid sample.
    """
    aid, arm = str(row["attemptId"]), str(row["arm"])
    docs: Dict[str, Dict[str, Any]] = {}
    missing = False
    for field, kind in RAW_EVIDENCE_FIELDS:
        rel = row.get(field)
        expected = f"raw/{aid}-{arm}.{kind}.json"
        if rel != expected:
            raise _malformed(f"attempt {aid}", f"{field} {rel!r} is not its own raw file {expected}")
        try:
            st = os.lstat(root / rel)
        except FileNotFoundError:
            missing = True
            continue
        if not stat.S_ISREG(st.st_mode):
            raise _malformed(rel, "raw evidence must be a regular file (not a link)")
        docs[kind] = _obj(read_json_file(root / rel), rel)
    if missing:
        return "retained_raw_missing"
    status_rel, terminal_rel, timings_rel, thermal_rel = (f"raw/{aid}-{arm}.{kind}.json"
                                                           for kind in ("status", "terminal", "timings", "thermal"))
    status, terminal, timings, thermal = docs["status"], docs["terminal"], docs["timings"], docs["thermal"]
    for key in STATUS_ROW_KEYS:
        if status.get(key) != row.get(key):
            raise _malformed(status_rel, f"{key} {status.get(key)!r} differs from the row's {row.get(key)!r}")
    if terminal.get("ticket") != row.get("ticket") or terminal.get("state") != row.get("state") or \
            not isinstance(terminal.get("state"), str) or terminal.get("state") not in TERMINAL_STATES:
        raise _malformed(terminal_rel, "terminal observation does not match the row's ticket and terminal state")
    if timings.get("ticket") != row.get("ticket"):
        raise _malformed(timings_rel, "finalized timings belong to another ticket")
    phase_metrics = _obj(timings.get("phaseMetrics"), f"{timings_rel}.phaseMetrics")
    _validate_phase_metrics_shape(phase_metrics, f"{timings_rel}.phaseMetrics")
    observations = []
    for index, item in enumerate(_arr(thermal.get("observations"), f"{thermal_rel}.observations")):
        item = _arr(item, f"{thermal_rel}.observations[{index}]")
        if len(item) != 2 or not isinstance(item[1], str):
            raise _malformed(f"{thermal_rel}.observations[{index}]", "expected [time, state]")
        observations.append((_number(item[0], f"{thermal_rel}.observations[{index}]"), item[1]))
    marks = {name: _number(value, f"{thermal_rel}.marks.{name}")
             for name, value in _obj(thermal.get("marks"), f"{thermal_rel}.marks").items()}
    errors = [_text(error, f"{thermal_rel}.errors") for error in _arr(thermal.get("errors"), f"{thermal_rel}.errors")]
    summary = _obj(thermal.get("summary"), f"{thermal_rel}.summary")
    if summary != row.get("thermal"):
        raise _malformed(thermal_rel, "thermal summary differs from the row's thermal record")
    recomputed = summarize_thermal(observations, marks, errors, exhausted=summary.get("exhausted") is True,
                                   join_failed=summary.get("joinFailed") is True, max_gap=THERMAL_MAX_GAP_S,
                                   interval=THERMAL_INTERVAL_S)
    if _json_normalized(recomputed) != summary:
        raise _malformed(thermal_rel, "thermal summary does not reproduce from the raw observations")
    expected_digest = manifest["arms"][arm].get("expectedConductorDigest")
    evaluation = evaluate_sample(recipe, status, phase_metrics, True, recomputed, expected_digest, row.get("fingerprint"))
    if not evaluation["valid"]:
        raise _malformed(f"attempt {aid}", "retained, but its raw evidence is not a valid sample: "
                                           + ",".join(evaluation["invalidReasons"]))
    recorded = {key: value for key, value in _obj(row.get("measures"), f"attempt {aid} measures").items()
                if key != "clientObserved"}
    if _json_normalized(evaluation["measures"]) != recorded:
        raise _malformed(f"attempt {aid}", "recorded measures do not reproduce from its raw status and timings")
    return None


def scenario_evidence(cap: Dict[str, Any], scenario: str) -> Dict[str, Any]:
    """Pairs reconstructed from unique, validated retained attempts (cached per loaded capture).

    Every retained observation must name its own valid measured result row in
    this scenario and block, at the ABBA position of its arm, with matching
    identity, measurement, admission and reconciled raw evidence. The recorded
    ``pairs`` and A/A verdict must reproduce exactly.
    """
    cache = cap.setdefault("evidence", {})
    if scenario in cache:
        return cache[scenario]
    manifest, result, root = cap["manifest"], cap["result"], Path(cap["root"])
    recipe = SCENARIOS.get(scenario)
    if recipe is None:
        raise HarnessError(f"unknown scenario {scenario!r}")
    entry = result["scenarios"].get(scenario)
    if entry is None:
        cache[scenario] = {"pairs": [], "loads": [], "reasons": ["scenario_missing"], "aa": None}
        return cache[scenario]
    where = f"result.scenarios.{scenario}"
    run_id = manifest["runId"]
    cap_value = float(manifest["admission"]["effectiveLoad1Cap"])
    blocks = _arr(entry.get("retainedObservations"), f"{where}.retainedObservations")
    block_ids = _arr(entry.get("retainedAttemptIds"), f"{where}.retainedAttemptIds")
    if len(blocks) != len(block_ids) or entry.get("blocksRetained") != len(blocks):
        raise _malformed(where, "retained observations, attempt ids and blocksRetained disagree")
    rows = {row["attemptId"]: row for row in cap["rows"] if row.get("phase") == "result"}
    seen: Set[str] = set()
    pairs: List[List[float]] = []
    loads: List[float] = []
    reasons: List[str] = []
    fingerprints: Dict[str, Set[Any]] = {arm: set() for arm in ARMS}
    for index, (block, ids) in enumerate(zip(blocks, block_ids)):
        block_where = f"{where} block {index}"
        block = _arr(block, block_where)
        ids = _arr(ids, f"{block_where} attempt ids")
        if len(block) != 4 or len(ids) != 4:
            raise _malformed(block_where, "a retained block holds exactly four observations")
        members: List[Dict[str, Any]] = []
        for obs in block:
            obs = _obj(obs, f"{block_where} observation")
            aid = _text(obs.get("attemptId"), f"{block_where} observation attemptId")
            if aid in seen:
                raise _malformed(block_where, f"duplicate retained observation {aid}")
            seen.add(aid)
            row = rows.get(aid)
            if row is None:
                raise _malformed(block_where, f"retained observation {aid} has no result row")
            arm = row.get("arm")
            checks = (
                (obs.get("runId") == run_id, "runId"),
                (row.get("scenario") == scenario, "scenario"),
                (row.get("kind") == "measured", "kind"),
                (arm in ARMS and obs.get("arm") == arm, "arm"),
                (isinstance(row.get("ticket"), str) and obs.get("ticket") == row.get("ticket"), "ticket"),
                (obs.get("requestKey") == row.get("requestKey"), "requestKey"),
                (row.get("block") == index, "block"),
                (row.get("valid") is True, "valid"),
                (isinstance(row.get("position"), int) and not isinstance(row.get("position"), bool)
                 and 0 <= row["position"] < 4 and block_order(index)[row["position"]] == arm, "position"),
            )
            for ok, field in checks:
                if not ok:
                    raise _malformed(f"{block_where} attempt {aid}", f"{field} contradicts the retained observation")
            primary = _number(_obj(row.get("measures"), f"attempt {aid} measures").get("primarySeconds"),
                              f"attempt {aid} primarySeconds")
            if obs.get("primarySeconds") != primary:
                raise _malformed(f"{block_where} attempt {aid}", "observation primarySeconds differs from its row")
            load1 = _number(row.get("load1"), f"attempt {aid} load1")
            if obs.get("load1") != row.get("load1"):
                raise _malformed(f"{block_where} attempt {aid}", "observation load1 differs from its row")
            if row.get("admissionCap") != cap_value:
                raise _malformed(f"attempt {aid}", f"admissionCap {row.get('admissionCap')!r} is not the capture's "
                                                   f"admission cap {cap_value}")
            if load1 > cap_value:
                raise _malformed(f"attempt {aid}", f"admitted at load1 {load1} above its cap {cap_value}")
            raw_reason = validate_raw_attempt(root, row, recipe, manifest)
            if raw_reason:
                reasons.append(raw_reason)
            fingerprints[arm].add(row.get("fingerprint"))
            loads.append(load1)
            members.append(row)
        if sorted(str(value) for value in ids) != sorted(row["attemptId"] for row in members) or \
                sorted(row["position"] for row in members) != [0, 1, 2, 3]:
            raise _malformed(block_where, "attempt ids or ABBA positions do not match the observations")
        ordered = sorted(members, key=lambda row: row["position"])
        on = [row for row in ordered if row["arm"] == ARM_ON]
        skip = [row for row in ordered if row["arm"] == ARM_SKIP]
        expected_order = [on[0]["attemptId"], skip[0]["attemptId"], on[1]["attemptId"], skip[1]["attemptId"]]
        if [obs["attemptId"] for obs in block] != expected_order:
            raise _malformed(block_where, "observations are not in first-with-first, second-with-second pair order")
        for first, second in zip(on, skip):
            pairs.append([first["measures"]["primarySeconds"], second["measures"]["primarySeconds"]])
    for arm, values in fingerprints.items():
        if len(values) > 1:
            raise _malformed(where, f"{arm} retained attempts carry {len(values)} different request fingerprints")
    recorded = [list(pair) if isinstance(pair, list) else pair for pair in _arr(entry.get("pairs"), f"{where}.pairs")]
    if recorded != pairs:
        raise _malformed(where, "recorded pairs do not match the pairs reconstructed from retained attempts")
    if len(pairs) < MIN_PAIRS:
        reasons.append("insufficient_pairs")
    aa: Optional[str] = None
    if recipe.role == ROLE_GATING:
        comparison = metrics.aa_equivalence(
            [pair[0] for pair in pairs], [pair[1] for pair in pairs], bound_abs=AA_BOUND_ABS_S,
            bound_rel=AA_BOUND_REL, min_pairs=MIN_PAIRS, confidence=CONFIDENCE, iterations=BOOTSTRAP_ITERATIONS,
            seed=BOOTSTRAP_SEED, block_size=PAIR_BLOCK_SIZE)
        aa = comparison.verdict
        if entry.get("verdict") != aa:
            raise _malformed(where, f"recorded A/A verdict {entry.get('verdict')!r} does not reproduce ({aa!r})")
    elif entry.get("verdict") != "recorded":
        raise _malformed(where, f"diagnostic scenario recorded verdict {entry.get('verdict')!r}, not 'recorded'")
    cache[scenario] = {"pairs": pairs, "loads": loads, "reasons": _dedupe(reasons), "aa": aa}
    return cache[scenario]


def _verify_cleanup(cap: Mapping[str, Any]) -> List[str]:
    if cap["result"]["cleanup"].get("ok") is not True:
        return ["cleanup_incomplete"]
    path = Path(cap["root"]) / "ownership.json"
    if not os.path.lexists(path):
        return ["cleanup_unverified"]
    ownership = read_json_file(path)
    arms = ownership.get("arms") if isinstance(ownership, dict) else None
    if not isinstance(ownership, dict) or ownership.get("schema") != OWNERSHIP_SCHEMA_VERSION or \
            ownership.get("runId") != cap["manifest"]["runId"] or ownership.get("state") != "cleaned" or \
            not isinstance(arms, dict) or set(arms) != set(ARMS) or \
            any(not isinstance(arms[arm], dict) or arms[arm].get("cleanup") != "removed" for arm in ARMS):
        return ["cleanup_unverified"]
    return []


def lineage_from_reference(reference: Mapping[str, Any], depth: int) -> Tuple[Optional[Dict[str, Any]], List[str]]:
    """Validate a recorded calibration reference against the referenced capture's own evidence."""
    reference = _obj(reference, "calibration reference")
    directory = _text(reference.get("captureDir"), "calibration reference captureDir")
    root = Path(directory)
    if not root.is_dir():
        return None, ["calibration_reference_unavailable"]
    info, reasons, _cap = calibration_lineage(Path(os.path.realpath(root)), depth + 1)
    reasons = [f"calibration_reference_ineligible:{reason}" for reason in reasons]
    if info is not None:
        for key in ("runId", "pinnedLoad1Threshold", "lineageRoot", "calibrationSha256"):
            if reference.get(key) != info.get(key):
                reasons.append(f"lineage_reference_mismatch:{key}")
        if set(reference.get("qualifiedScenarios") or []) - set(info["qualifiedScenarios"]):
            reasons.append("lineage_reference_mismatch:qualifiedScenarios")
    return info, reasons


def expected_environment_keys(manifest: Mapping[str, Any]) -> Tuple[Optional[List[str]], Optional[str]]:
    """The environment-class inventory the capture's runner must have recorded, from an authority outside it.

    ``environment_class`` records the runner conductor's request passthrough keys
    plus ``ENV_CLASS_EXTRA_KEYS``. The capture binds those conductor bytes by
    sha256 in ``harness.files["Scripts/conductor.py"].runner``; the expected set is
    derived only when this validator's own conductor has exactly those bytes, so
    a capture's recorded key list is never its own authority.
    """
    recorded = manifest["harness"]["files"].get("Scripts/conductor.py")
    cond = load_conductor()
    if recorded is None or recorded.get("runner") is None or \
            recorded["runner"] != sha256_file(Path(os.path.realpath(cond.__file__))):
        return None, "environment_inventory_unverifiable:conductor_bytes_differ"
    return sorted(set(cond.OperationRegistry.PASSTHROUGH_ENV_KEYS) | set(ENV_CLASS_EXTRA_KEYS)), None


def capture_ineligibility(cap: Dict[str, Any], depth: int = 0) -> List[str]:
    """Capture-level reasons: cleanup, provenance and environment inventories, admission authority."""
    cache = cap.setdefault("evidence", {})
    if "_capture" in cache:
        return cache["_capture"]
    manifest = cap["manifest"]
    reasons = _verify_cleanup(cap)
    harness = manifest["harness"]
    missing = [rel for rel in required_harness_files() if rel not in harness["files"]]
    if missing:
        reasons.append("harness_inventory_incomplete:" + ",".join(missing))
    if harness.get("matchesCommit") is not True:
        reasons.append("harness_not_at_commit")
    expected_env, env_authority_problem = expected_environment_keys(manifest)
    if env_authority_problem:
        reasons.append(env_authority_problem)
    for arm in ARMS:
        entry = manifest["arms"][arm]
        hashes = entry["runtimeFileSha256"]
        if set(hashes) != set(RUNTIME_FILES) or any(value is None for value in hashes.values()):
            reasons.append(f"runtime_inventory_incomplete:{arm}")
        digests = entry["environmentDigests"]
        if not digests:
            reasons.append(f"environment_class_missing:{arm}")
        if expected_env is not None:
            absent = [key for key in expected_env if key not in digests]
            if absent:
                reasons.append(f"environment_inventory_incomplete:{arm}:" + ",".join(absent))
            unexpected = sorted(set(digests) - set(expected_env))
            if unexpected:
                reasons.append(f"environment_inventory_unexpected:{arm}:" + ",".join(unexpected))
    physical = manifest["host"].get("physicalCpu")
    lineage: Optional[Dict[str, Any]] = None
    if not (isinstance(physical, int) and not isinstance(physical, bool) and physical > 0):
        reasons.append("admission_authority_unverified")
    else:
        reference = manifest.get("calibrationReference")
        if reference is None:
            authority = float(physical)
        else:
            lineage, lineage_reasons = lineage_from_reference(reference, depth)
            reasons.extend(lineage_reasons)
            authority = None if lineage is None or lineage.get("pinnedLoad1Threshold") is None else \
                min(float(lineage["pinnedLoad1Threshold"]), float(physical))
        if authority is None or manifest["admission"].get("effectiveLoad1Cap") != authority or \
                manifest["admission"].get("physicalCpu") != physical:
            reasons.append("admission_authority_mismatch")
    cache["_lineage"] = lineage
    cache["_capture"] = _dedupe(reasons)
    return cache["_capture"]


def calibration_lineage(root: Path, depth: int = 0) -> Tuple[Optional[Dict[str, Any]], List[str], Optional[Dict[str, Any]]]:
    """An evidence-backed calibration: eligible capture, qualified A/A observations and a pinned
    threshold derived from them (root) or inherited unchanged through a valid lineage (never raised)."""
    if depth > LINEAGE_MAX_DEPTH:
        return None, ["lineage_too_deep"], None
    try:
        cap = load_capture_root(root)
    except Ineligible as exc:
        return None, exc.reasons, None
    manifest = cap["manifest"]
    run_id = manifest["runId"]
    calibration = read_json_file(root / "calibration.json")
    if not isinstance(calibration, dict) or calibration.get("runId") != run_id:
        raise HarnessError(f"{root}/calibration.json is malformed or belongs to another run")
    reasons = list(capture_ineligibility(cap, depth))
    if calibration.get("diagnosticOnly"):
        reasons.append("diagnostic_only")
    if calibration.get("reusable") is not True:
        reasons.append("not_reusable")
    pinned = calibration.get("pinnedLoad1Threshold")
    pinned_ok = finite_nonnegative(pinned) and bool(pinned)
    if not pinned_ok:
        reasons.append("pinned_threshold_missing")
    lineage_root = calibration.get("lineageRoot")
    if not isinstance(lineage_root, str) or lineage_root != manifest["lineageRoot"]:
        reasons.append("lineage_missing_or_inconsistent")
    verified: List[str] = []
    loads: List[float] = []
    for name in _arr(calibration.get("qualifiedScenarios", []), f"{root}/calibration.json qualifiedScenarios"):
        name = _text(name, f"{root}/calibration.json qualifiedScenarios")
        recipe = SCENARIOS.get(name)
        if recipe is None or recipe.role != ROLE_GATING:
            reasons.append(f"qualified_scenario_unverified:{name}")
            continue
        evidence = scenario_evidence(cap, name)
        # The comparison's own scenario gate and arm compatibility, applied to this A/A capture.
        blockers = scenario_gate_reasons(cap, name) + calibration_arm_incompatibility(cap, name)
        if blockers or evidence["aa"] != "qualified":
            reasons.append(f"qualified_scenario_unverified:{name}")
            reasons.extend(f"qualified_scenario_unverified:{name}:{blocker}" for blocker in blockers)
            continue
        verified.append(name)
        loads.extend(evidence["loads"])
    reference = calibration.get("reference")
    if reference != manifest.get("calibrationReference"):
        reasons.append("lineage_reference_mismatch:manifest")
    if reference is None:
        if lineage_root != run_id:
            reasons.append("lineage_missing_or_inconsistent")
        if pinned_ok and loads and float(pinned) != max(loads):
            reasons.append("pinned_threshold_not_derived")
    else:
        parent = cap["evidence"].get("_lineage")
        if parent is not None and pinned_ok and parent.get("pinnedLoad1Threshold") is not None:
            if float(pinned) > float(parent["pinnedLoad1Threshold"]):
                reasons.append("pinned_threshold_raised")
            elif float(pinned) != float(parent["pinnedLoad1Threshold"]):
                reasons.append("pinned_threshold_not_inherited")
            if lineage_root != parent.get("lineageRoot"):
                reasons.append("lineage_missing_or_inconsistent")
    info = {"captureDir": str(root), "runId": run_id, "pinnedLoad1Threshold": float(pinned) if pinned_ok else None,
            "lineageRoot": lineage_root, "qualifiedScenarios": sorted(verified),
            "calibrationSha256": sha256_file(root / "calibration.json")}
    return info, _dedupe(reasons), cap


def scenario_ineligibility(cap: Dict[str, Any], scenario: str) -> List[str]:
    """Reasons a well-formed schema-2 capture cannot gate ``scenario`` (empty = eligible); raises on integrity."""
    reasons = list(capture_ineligibility(cap))
    return _dedupe(reasons + scenario_gate_reasons(cap, scenario))


def scenario_gate_reasons(cap: Dict[str, Any], scenario: str) -> List[str]:
    """Scenario-local gate reasons shared by comparisons and calibration references (non-recursive).

    Role, reconstructed evidence, A/A or lineage qualification and mandatory
    metadata. Reads the lineage ``capture_ineligibility`` already validated and
    cached; it never walks a lineage itself.
    """
    if "_capture" not in cap.get("evidence", {}):
        raise HarnessError("internal: scenario gate evaluated before the capture-level checks")
    manifest = cap["manifest"]
    reasons: List[str] = []
    recipe = SCENARIOS.get(scenario)
    if recipe is None:
        raise HarnessError(f"unknown scenario {scenario!r}")
    entry = cap["result"]["scenarios"].get(scenario)
    if entry is None:
        return ["scenario_missing"]
    if entry.get("statisticalRole") != ROLE_GATING or recipe.role != ROLE_GATING:
        reasons.append("not_gated")
    evidence = scenario_evidence(cap, scenario)
    reasons.extend(evidence["reasons"])
    if manifest["treatment"] == "none":
        # A/A capture: its own in-capture calibration, recomputed from the reconstructed pairs.
        if evidence["aa"] != "qualified":
            reasons.append("aa_not_qualified")
    else:
        # Treatment capture: qualification comes from its validated A/A calibration lineage.
        lineage = cap["evidence"].get("_lineage")
        if lineage is None or scenario not in lineage["qualifiedScenarios"] or \
                lineage.get("lineageRoot") != manifest["lineageRoot"]:
            reasons.append("aa_not_qualified")
    meta = manifest["comparisonMeta"].get(scenario) or {}
    missing = [key for key in MANDATORY_META_KEYS if meta.get(key) is None]
    host = manifest["host"]
    missing += [f"host.{key}" for key in REQUIRED_HOST_KEYS if host.get(key) is None]
    if missing:
        reasons.append("metadata_missing:" + ",".join(missing))
    return _dedupe(reasons)


# ---------------------------------------------------------------------------
# Treatment manifest, digest and environment classes

TREATMENT_TOP_KEYS = frozenset({"paths", "env", "description"})
TREATMENT_PATH_KEYS = frozenset({"path", "before", "after", "reason"})
TREATMENT_ENV_KEYS = frozenset({"key", "before", "after", "reason"})


def load_treatment(path: Optional[str]) -> Dict[str, Any]:
    """Exact treatment manifest; unknown fields, unknown targets or duplicates are malformed (exit 3)."""
    if not path:
        return {"paths": [], "env": []}
    data = read_json_file(Path(path))
    if not isinstance(data, dict) or set(data) - TREATMENT_TOP_KEYS:
        raise HarnessError(f"treatment manifest has unknown top-level keys: {sorted(set(data) - TREATMENT_TOP_KEYS) if isinstance(data, dict) else data!r}")
    paths = data.get("paths", [])
    env = data.get("env", [])
    if not isinstance(paths, list) or not isinstance(env, list):
        raise HarnessError("treatment manifest paths/env must be lists")
    seen: Set[str] = set()
    for entry in paths:
        if not isinstance(entry, dict) or set(entry) != TREATMENT_PATH_KEYS:
            raise HarnessError(f"treatment path entry must have exactly {sorted(TREATMENT_PATH_KEYS)}: {entry!r}")
        if entry["path"] not in RUNTIME_FILES:
            raise HarnessError(f"treatment path {entry['path']!r} is not a runtime file")
        if entry["path"] in seen:
            raise HarnessError(f"treatment path {entry['path']!r} declared twice")
        if not isinstance(entry["reason"], str) or not entry["reason"].strip() or entry["before"] == entry["after"]:
            raise HarnessError(f"treatment path {entry['path']!r} needs a reason and differing before/after")
        seen.add(entry["path"])
    seen_env: Set[str] = set()
    for entry in env:
        if not isinstance(entry, dict) or set(entry) != TREATMENT_ENV_KEYS:
            raise HarnessError(f"treatment env entry must have exactly {sorted(TREATMENT_ENV_KEYS)}: {entry!r}")
        if not isinstance(entry["key"], str) or entry["key"] in seen_env:
            raise HarnessError(f"treatment env key {entry.get('key')!r} malformed or declared twice")
        if not isinstance(entry["reason"], str) or not entry["reason"].strip() or entry["before"] == entry["after"]:
            raise HarnessError(f"treatment env key {entry['key']!r} needs a reason and differing before/after")
        for side in ("before", "after"):
            if entry[side] is not None and not isinstance(entry[side], str):
                raise HarnessError(f"treatment env key {entry['key']!r} {side} must be a string or null")
        seen_env.add(entry["key"])
    return {"paths": paths, "env": env, "description": data.get("description")}


def digest_class(runtime: Mapping[str, Optional[str]], treatment: Mapping[str, Any], side: str) -> Tuple[str, List[str]]:
    """Digest class from invariant runtime inputs plus an exact treatment manifest.

    A path may differ only when the manifest declares it with this side's exact
    hash (``before`` for the baseline, ``after`` for the candidate) and a reason.
    """
    declared = {entry["path"]: entry for entry in treatment.get("paths", [])}
    problems: List[str] = []
    parts = []
    for rel in sorted(runtime):
        value = runtime[rel]
        entry = declared.get(rel)
        if entry is not None:
            if entry.get(side) != value:
                problems.append(f"{rel}: undeclared {side} hash {value}")
            parts.append((rel, f"declared:{entry.get('reason')}"))
        else:
            parts.append((rel, value))
    return sha256_bytes(json.dumps(parts).encode("utf-8")), problems


def env_class_with_treatment(digests: Mapping[str, Optional[str]], treatment: Mapping[str, Any],
                             side: str) -> Tuple[str, List[str]]:
    """Environment class; only EXACT declared treatment keys may differ (values compared as digests)."""
    declared = {entry["key"]: entry for entry in treatment.get("env", [])}
    problems: List[str] = []
    parts: Dict[str, Any] = {}
    for key in sorted(set(digests) | set(declared)):
        if key not in digests:
            problems.append(f"{key}: treatment key not in the recorded environment class")
            continue
        entry = declared.get(key)
        if entry is not None:
            if env_value_digest(key, entry.get(side)) != digests[key]:
                problems.append(f"{key}: {side} value does not match the recorded digest")
            parts[key] = f"declared:{entry.get('reason')}"
        else:
            parts[key] = digests[key]
    return sha256_bytes(canonical_json(parts)), problems


def arm_values(result: Mapping[str, Any], scenario: str, arm: str) -> List[Optional[float]]:
    pairs = (result.get("scenarios") or {}).get(scenario, {}).get("pairs") or []
    index = 0 if arm == ARM_ON else 1
    return [pair[index] for pair in pairs]


NO_TREATMENT: Mapping[str, Any] = {"paths": [], "env": []}


def arm_meta(manifest: Mapping[str, Any], arm: str, scenario: str, treatment: Mapping[str, Any],
             side: str) -> Tuple[Dict[str, Any], List[str]]:
    """One arm's comparison metadata: scenario metadata plus treatment-aware digest/environment classes."""
    arm_entry = (manifest.get("arms") or {}).get(arm) or {}
    meta = dict((manifest.get("comparisonMeta") or {}).get(scenario) or {})
    d_class, d_problems = digest_class(arm_entry.get("runtimeFileSha256") or {}, treatment, side)
    e_class, e_problems = env_class_with_treatment(arm_entry.get("environmentDigests") or {}, treatment, side)
    meta["digestClass"] = d_class
    meta["environmentClass"] = e_class
    meta["lineageRoot"] = manifest.get("lineageRoot")
    return meta, d_problems + e_problems


def side_meta(cap: Mapping[str, Any], scenario: str, treatment: Mapping[str, Any], side: str) -> Tuple[Dict[str, Any], List[str]]:
    return arm_meta(cap["manifest"], cap["arm"], scenario, treatment, side)


def comparison_metas(before: Tuple[Mapping[str, Any], str], after: Tuple[Mapping[str, Any], str], scenario: str,
                     treatment: Mapping[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any], List[str], List[str]]:
    """Both sides' comparison metadata, the keys that must match, and treatment problems."""
    b_meta, b_problems = arm_meta(before[0], before[1], scenario, treatment, "before")
    c_meta, c_problems = arm_meta(after[0], after[1], scenario, treatment, "after")
    return b_meta, c_meta, sorted(set(b_meta) | set(c_meta)), b_problems + c_problems


def calibration_arm_incompatibility(cap: Mapping[str, Any], scenario: str) -> List[str]:
    """An A/A calibration's arms compared exactly as a comparison would, with no treatment declared.

    Uses the comparison's own metadata, digest/environment classes and match
    rule (``metrics.metadata_mismatches``), so a reference can never qualify
    arms that comparing its own two arms would reject (S9-R0-05).
    """
    manifest = cap["manifest"]
    on, skip, keys, problems = comparison_metas((manifest, ARM_ON), (manifest, ARM_SKIP), scenario, NO_TREATMENT)
    if problems:
        return ["treatment_mismatch:" + "; ".join(problems)]
    return [f"incompatible:{key}" for key in metrics.metadata_mismatches(on, skip, keys)]


def evidence_values(cap: Dict[str, Any], scenario: str, arm: str) -> List[float]:
    """One arm's side of the pairs reconstructed from validated retained attempts."""
    index = 0 if arm == ARM_ON else 1
    return [pair[index] for pair in scenario_evidence(cap, scenario)["pairs"]]


def observation_identities(cap: Dict[str, Any], scenario: str) -> Set[Tuple[str, str]]:
    scenario_evidence(cap, scenario)  # identities only from validated retained observations
    entry = cap["result"]["scenarios"].get(scenario) or {}
    identities: Set[Tuple[str, str]] = set()
    for block in entry.get("retainedObservations") or []:
        for obs in block:
            identities.add(("attempt", f"{obs.get('runId')}/{obs.get('attemptId')}"))
            identities.add(("ticket", str(obs.get("ticket"))))
            identities.add(("requestKey", str(obs.get("requestKey"))))
    return identities


def paired_within(base: Mapping[str, Any], cand: Mapping[str, Any], scenario: str,
                  treatment: Mapping[str, Any]) -> Tuple[Optional[metrics.Comparison], List[str]]:
    """Truly paired comparison of one capture's two arm observations (balanced ABBA blocks)."""
    if os.path.realpath(base["root"]) != os.path.realpath(cand["root"]) or \
            base["manifest"].get("runId") != cand["manifest"].get("runId"):
        return None, ["cross_capture_not_paired: pairs exist only within one capture's ABBA blocks; index "
                      "alignment across captures is not pairing and no unpaired estimator is provided"]
    reasons = scenario_ineligibility(base, scenario)
    if reasons:
        return None, reasons
    b_meta, c_meta, keys, problems = comparison_metas((base["manifest"], base["arm"]), (cand["manifest"], cand["arm"]),
                                                      scenario, treatment)
    if problems:
        return None, ["treatment_mismatch:" + "; ".join(problems)]
    comparison = metrics.compare_paired(
        evidence_values(base, scenario, base["arm"]), evidence_values(cand, scenario, cand["arm"]),
        floor_abs=FLOORS_S[SCENARIOS[scenario].floor_class], floor_rel=REGRESSION_REL_FLOOR, min_pairs=MIN_PAIRS,
        confidence=CONFIDENCE, iterations=BOOTSTRAP_ITERATIONS, seed=BOOTSTRAP_SEED, block_size=PAIR_BLOCK_SIZE,
        baseline_meta=b_meta, candidate_meta=c_meta, match_keys=keys,
    )
    return comparison, []


def confirmation(primary: Tuple[Mapping[str, Any], Mapping[str, Any]], second: Tuple[Mapping[str, Any], Mapping[str, Any]],
                 scenario: str, treatment: Mapping[str, Any]) -> Dict[str, Any]:
    """Independent confirming batch: a distinct capture's own pairs with CI low > 0 (no repeated floor)."""
    (pb, pc), (sb, sc) = primary, second
    problems: List[str] = []
    if (sb["arm"], sc["arm"]) != (pb["arm"], pc["arm"]):
        problems.append("arm_roles_differ")
    if os.path.realpath(sb["root"]) == os.path.realpath(pb["root"]):
        problems.append("same_capture_alias")
    if sb["manifest"].get("runId") == pb["manifest"].get("runId"):
        problems.append("same_run_id_copy")
    shared = observation_identities(sb, scenario) & observation_identities(pb, scenario)
    if shared:
        problems.append(f"shared_observations:{len(shared)}")
    p_meta, _ = side_meta(pb, scenario, treatment, "before")
    s_meta, _ = side_meta(sb, scenario, treatment, "before")
    pc_meta, _ = side_meta(pc, scenario, treatment, "after")
    sc_meta, _ = side_meta(sc, scenario, treatment, "after")
    for name, left, right in (("baseline", p_meta, s_meta), ("candidate", pc_meta, sc_meta)):
        differing = metrics.metadata_mismatches(left, right, sorted(set(left) | set(right)))
        if differing:
            problems.append(f"{name}_metadata_differs:{','.join(differing)}")
    if problems:
        return {"confirmed": False, "reasons": problems, "rule": CONFIRMATION_RULE}
    comparison, reasons = paired_within(sb, sc, scenario, treatment)
    if comparison is None:
        return {"confirmed": False, "reasons": reasons, "rule": CONFIRMATION_RULE}
    confirmed = (comparison.pairs >= MIN_PAIRS and comparison.ci_low is not None and comparison.ci_low > 0
                 and comparison.verdict != "harness_failure"
                 and not any(str(reason).startswith("incompatible:") for reason in comparison.reasons))
    return {"confirmed": confirmed, "comparison": comparison.to_json(), "rule": CONFIRMATION_RULE,
            "reasons": [] if confirmed else ["confirming_ci_not_above_zero"]}


def evidence_failure_text(exc: Exception) -> str:
    """Report text for a failure while validating evidence.

    ``HarnessError`` is the validator's own malformed-evidence result. Any other
    ``Exception`` reaching an evidence-evaluation site is the bounded backstop
    (S9-R2-01): still a harness failure (exit 3), never the regression exit.
    ``KeyboardInterrupt``/``SystemExit`` are not ``Exception`` and propagate.
    """
    if isinstance(exc, HarnessError):
        return str(exc)
    return f"unexpected {type(exc).__name__} while validating evidence: {exc}"


def cmd_compare(ns: argparse.Namespace) -> int:
    report: Dict[str, Any] = {"baseline": ns.baseline, "candidate": ns.candidate, "scenarios": {},
                              "comparator": "paired within one capture's ABBA blocks only",
                              "confirmationRule": CONFIRMATION_RULE}

    def finish(code: int) -> int:
        report["exitCode"] = code
        text = json.dumps(report, indent=2, default=str)
        if ns.report:
            Path(ns.report).write_text(text + "\n", encoding="utf-8")
        print(text)
        return code

    try:
        bench_root = None
        references = [ref for ref in (ns.baseline, ns.candidate, ns.confirm_baseline, ns.confirm_candidate) if ref]
        if getattr(ns, "main_repo", None) or any(not Path(ref.partition("#")[0]).expanduser().is_dir()
                                                 for ref in references):
            main_root, _ = resolve_main_repo(getattr(ns, "main_repo", None))
            bench_root = benchmark_root(load_conductor(), main_root)
        treatment = load_treatment(ns.treatment_manifest)
        report["treatment"] = treatment
        if bool(ns.confirm_baseline) != bool(ns.confirm_candidate):
            raise HarnessError("--confirm-baseline and --confirm-candidate go together")
        base = load_capture(ns.baseline, bench_root)
        cand = load_capture(ns.candidate, bench_root)
        second = (load_capture(ns.confirm_baseline, bench_root), load_capture(ns.confirm_candidate, bench_root)) \
            if ns.confirm_baseline else None
        if base["arm"] == cand["arm"] and os.path.realpath(base["root"]) == os.path.realpath(cand["root"]):
            raise HarnessError("baseline and candidate are the same capture arm")
        scenarios = parse_scenarios(ns.scenarios) or list((base["result"].get("scenarios") or {}))
        unknown = [name for name in scenarios if name not in SCENARIOS]
        if unknown:
            raise HarnessError(f"unknown scenarios {unknown}")
    except HarnessError as exc:
        report["error"] = str(exc)
        print(f"swift-bench compare: harness failure: {exc}", file=sys.stderr)
        return finish(EXIT_HARNESS_FAILURE)
    except Ineligible as exc:
        report["ineligible"] = exc.reasons
        return finish(EXIT_INCONCLUSIVE)
    except Exception as exc:  # noqa: BLE001 - malformed-evidence backstop (S9-R2-01)
        report["error"] = evidence_failure_text(exc)
        print(f"swift-bench compare: harness failure: {report['error']}", file=sys.stderr)
        return finish(EXIT_HARNESS_FAILURE)
    codes: List[int] = []
    for scenario in scenarios:
        if SCENARIOS[scenario].role != ROLE_GATING:
            # Diagnostic scenarios never contribute a verdict; only their integrity can fail the run.
            diagnostic: Dict[str, Any] = {"role": SCENARIOS[scenario].role, "verdict": "not_gated"}
            try:
                diagnostic["evidenceReasons"] = scenario_evidence(base, scenario)["reasons"]
                diagnostic["integrity"] = "ok"
            except Exception as exc:  # noqa: BLE001 - HarnessError or the S9-R2-01 backstop
                diagnostic.update(integrity="harness_failure", error=evidence_failure_text(exc))
                codes.append(EXIT_HARNESS_FAILURE)
            report.setdefault("diagnostics", {})[scenario] = diagnostic
            continue
        try:
            comparison, reasons = paired_within(base, cand, scenario, treatment)
        except Exception as exc:  # noqa: BLE001 - HarnessError or the S9-R2-01 backstop
            report["scenarios"][scenario] = {"verdict": "harness_failure", "error": evidence_failure_text(exc),
                                             "exitCode": EXIT_HARNESS_FAILURE}
            codes.append(EXIT_HARNESS_FAILURE)
            continue
        if comparison is None:
            report["scenarios"][scenario] = {"verdict": "inconclusive", "reasons": reasons,
                                             "exitCode": EXIT_INCONCLUSIVE}
            codes.append(EXIT_INCONCLUSIVE)
            continue
        entry: Dict[str, Any] = {"primary": comparison.to_json()}
        code = comparison.exit_code
        if comparison.verdict == "regression":
            if second is None:
                code = EXIT_INCONCLUSIVE
                entry["confirmation"] = {"confirmed": False, "reasons": ["missing_confirming_batch"]}
            else:
                try:
                    entry["confirmation"] = confirmation((base, cand), second, scenario, treatment)
                except Exception as exc:  # noqa: BLE001 - HarnessError or the S9-R2-01 backstop
                    entry["confirmation"] = {"confirmed": False, "verdict": "harness_failure",
                                             "error": evidence_failure_text(exc)}
                    entry["exitCode"] = EXIT_HARNESS_FAILURE
                    report["scenarios"][scenario] = entry
                    codes.append(EXIT_HARNESS_FAILURE)
                    continue
                code = EXIT_REGRESSION if entry["confirmation"]["confirmed"] else EXIT_INCONCLUSIVE
        entry["exitCode"] = code
        report["scenarios"][scenario] = entry
        codes.append(code)
    if EXIT_HARNESS_FAILURE in codes:
        return finish(EXIT_HARNESS_FAILURE)
    if not report["scenarios"]:
        report["reasons"] = ["no_gated_scenarios"]
        return finish(EXIT_INCONCLUSIVE)
    if EXIT_REGRESSION in codes:
        return finish(EXIT_REGRESSION)
    if all(code == EXIT_QUALIFIED for code in codes):
        return finish(EXIT_QUALIFIED)
    return finish(EXIT_INCONCLUSIVE)


# ---------------------------------------------------------------------------
# Calibration reference


def load_calibration_reference(reference: str, bench_root: Optional[Path], host: Mapping[str, Any],
                               recipes: Sequence[Recipe]) -> Dict[str, Any]:
    """Admission authority from an evidence-backed A/A calibration (OD23, S9-R0-05).

    The capture passes the same validator as comparisons; its pinned threshold
    derives from retained A/A loads (root) or is inherited unchanged through a
    validated lineage. Malformed evidence raises HarnessError; ineligibility raises
    Ineligible with every reason.
    """
    root = Path(os.path.realpath(capture_root_for(reference, bench_root)))
    info, reasons, cap = calibration_lineage(root)
    if cap is None or info is None:
        raise Ineligible(reasons)
    manifest = cap["manifest"]
    old_host = manifest["host"]
    for key in REQUIRED_HOST_KEYS:
        if old_host.get(key) is None or old_host.get(key) != host.get(key):
            reasons.append(f"host_incompatible:{key}")
    harness = manifest["harness"]
    if harness.get("matchesCommit") is not True or harness.get("harnessVersion") != HARNESS_VERSION:
        reasons.append("harness_not_comparable")
    for rel, entry in harness["files"].items():
        if entry.get("runner") != sha256_file(REPO_ROOT / rel):
            reasons.append(f"harness_hash_differs:{rel}")
    for recipe in recipes:
        if recipe.role == ROLE_GATING and recipe.name not in info["qualifiedScenarios"]:
            reasons.append(f"scenario_not_calibrated:{recipe.name}")
    if reasons:
        raise Ineligible(_dedupe(reasons))
    return info


# ---------------------------------------------------------------------------
# Read-only auditable extract

EXTRACT_COLUMNS = (
    "runId", "scenario", "kind", "attemptId", "arm", "ticket", "requestKey", "state", "exitCode", "valid",
    "invalidReasons", "primarySeconds", "clientObservedSeconds", "queueWaitSeconds", "processObservedSeconds",
    "load1", "admissionCap", "thermalSamples", "thermalUnknown", "thermalNonNominal", "thermalCoverage",
    "thermalMaxGapSeconds", "conductorDigest", "fingerprint", "retained", "retainedBlock", "rawStatus",
)


def extract_rows(manifest: Mapping[str, Any], result: Mapping[str, Any], rows: Sequence[Mapping[str, Any]]) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    retained: Dict[Tuple[str, str], int] = {}
    mapping: Dict[str, Any] = {}
    for scenario, entry in (result.get("scenarios") or {}).items():
        ids = entry.get("retainedAttemptIds") or []
        for index, block in enumerate(ids):
            for attempt in block:
                retained[(scenario, attempt)] = index
        mapping[scenario] = {"retainedBlocks": ids, "pairs": entry.get("pairs"), "verdict": entry.get("verdict"),
                             "discarded": []}
    out: List[Dict[str, Any]] = []
    for row in rows:
        if row.get("phase") != "result":
            continue
        measures = row.get("measures") or {}
        thermal = row.get("thermal") or {}
        key = (row.get("scenario"), row.get("attemptId"))
        is_retained = key in retained
        if not is_retained and row.get("kind") == "measured" and row.get("scenario") in mapping:
            mapping[row["scenario"]]["discarded"].append(row.get("attemptId"))
        out.append({
            "runId": manifest.get("runId"), "scenario": row.get("scenario"), "kind": row.get("kind"),
            "attemptId": row.get("attemptId"), "arm": row.get("arm"), "ticket": row.get("ticket"),
            "requestKey": row.get("requestKey"), "state": row.get("state"), "exitCode": row.get("exitCode"),
            "valid": row.get("valid"), "invalidReasons": ";".join(row.get("invalidReasons") or []),
            "primarySeconds": measures.get("primarySeconds"),
            "clientObservedSeconds": (measures.get("clientObserved") or {}).get("seconds"),
            "queueWaitSeconds": measures.get("queueWaitSeconds"),
            "processObservedSeconds": measures.get("processObservedSeconds"),
            "load1": row.get("load1"), "admissionCap": row.get("admissionCap"),
            "thermalSamples": thermal.get("samples"), "thermalUnknown": thermal.get("unknown"),
            "thermalNonNominal": thermal.get("nonNominal"), "thermalCoverage": thermal.get("coverage"),
            "thermalMaxGapSeconds": thermal.get("maxGapSeconds"),
            "conductorDigest": row.get("conductorDigest"), "fingerprint": row.get("fingerprint"),
            "retained": is_retained, "retainedBlock": retained.get(key), "rawStatus": row.get("rawStatus"),
        })
    return out, mapping


def file_manifest(root: Path) -> List[Tuple[str, str]]:
    entries: List[Tuple[str, str]] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for name in sorted(files):
            path = Path(current) / name
            if path.is_symlink():
                entries.append((str(path.relative_to(root)), "symlink-not-followed"))
                continue
            entries.append((str(path.relative_to(root)), sha256_file(path) or "unreadable"))
    return entries


def cmd_extract(ns: argparse.Namespace) -> int:
    """Read-only: never writes inside the capture; schema 1 and 2 captures are both accepted."""
    try:
        bench_root = None
        if not Path(ns.capture).expanduser().is_dir():
            main_root, _ = resolve_main_repo(getattr(ns, "main_repo", None))
            bench_root = benchmark_root(load_conductor(), main_root)
        root = capture_root_for(ns.capture, bench_root)
        out = Path(os.path.realpath(Path(ns.out).expanduser()))
        if out == root or str(out).startswith(str(root) + os.sep):
            raise HarnessError("--out must be outside the capture directory")
        before = file_manifest(root)
        manifest = read_json_file(root / "manifest.json")
        result = read_json_file(root / "result.json")
        rows = read_attempt_rows(root, strict=False)
        flat, mapping = extract_rows(manifest, result, rows)
        out.mkdir(parents=True, exist_ok=True)
        with open(out / "attempts.csv", "w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(EXTRACT_COLUMNS))
            writer.writeheader()
            for row in flat:
                writer.writerow(row)
        with open(out / "attempts.jsonl", "w", encoding="utf-8") as handle:
            for row in flat:
                handle.write(json.dumps(row, sort_keys=True) + "\n")
        (out / "retained-map.json").write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (out / "capture-files.sha256").write_text("".join(f"{digest}  {rel}\n" for rel, digest in before),
                                                  encoding="utf-8")
        after = file_manifest(root)
        meta = {"capture": str(root), "runId": manifest.get("runId"), "schema": manifest.get("schema"),
                "generator": str(Path(__file__).resolve()), "generatorSha256": sha256_file(Path(__file__).resolve()),
                "generatedAt": utc_now_iso(), "resultRows": len(flat), "captureUnchanged": before == after}
        (out / "extract-meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        outputs = [name for name in ("attempts.csv", "attempts.jsonl", "retained-map.json", "capture-files.sha256",
                                     "extract-meta.json")]
        (out / "extract-files.sha256").write_text("".join(f"{sha256_file(out / name)}  {name}\n" for name in outputs),
                                                  encoding="utf-8")
        if before != after:
            raise HarnessError("capture changed while extracting")
    except HarnessError as exc:
        print(f"swift-bench extract: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    print(json.dumps(meta, indent=2))
    return EXIT_QUALIFIED


# ---------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="swift_build_benchmark.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="capture an A/A calibration in two fresh same-SHA worktrees")
    run.add_argument("--instrumentation", help="required: full")
    run.add_argument("--dsym-mode", default="on", help=f"only 'on' ({WRAPPER_CAPABILITY}); off is rejected")
    run.add_argument("--ref", default="HEAD", help="commit to benchmark (both worktrees)")
    run.add_argument("--name", default="bench", help="capture label")
    run.add_argument("--scenarios", default="", help=f"comma list; default {','.join(DEFAULT_SCENARIOS)}")
    run.add_argument("--blocks", type=int, default=DEFAULT_BLOCKS)
    run.add_argument("--main-repo", help="original checkout (default: the runner's repository)")
    run.add_argument("--calibration", help="eligible calibration capture to inherit the pinned load cap from")
    compare = sub.add_parser("compare", help="paired comparison of one capture's two arms")
    compare.add_argument("--baseline", required=True, help="capture id or path with #arm")
    compare.add_argument("--candidate", required=True, help="same capture with the other #arm")
    compare.add_argument("--confirm-baseline", help="a distinct capture's #arm for the confirming batch")
    compare.add_argument("--confirm-candidate")
    compare.add_argument("--treatment-manifest")
    compare.add_argument("--scenarios")
    compare.add_argument("--report")
    compare.add_argument("--main-repo")
    clean = sub.add_parser("clean", help="resume cleanup of the recorded benchmark worktrees")
    clean.add_argument("--main-repo")
    extract = sub.add_parser("extract", help="read-only per-attempt extract plus file SHA manifest")
    extract.add_argument("--capture", required=True)
    extract.add_argument("--out", required=True, help="output directory outside the capture")
    extract.add_argument("--main-repo")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    ns = build_parser().parse_args(argv)
    if ns.command == "run":
        return cmd_run(ns)
    if ns.command == "compare":
        return cmd_compare(ns)
    if ns.command == "extract":
        return cmd_extract(ns)
    return cmd_clean(ns)


if __name__ == "__main__":
    sys.exit(main())
