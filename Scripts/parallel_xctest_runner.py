#!/usr/bin/env python3
"""Run an already-built root XCTest bundle in parallel, one suite per process."""

from __future__ import annotations

import argparse
import csv
import heapq
import json
import os
import re
import signal
import subprocess
import threading
import time
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BUNDLE = REPO_ROOT / ".build/arm64-apple-macosx/debug/RepoPromptCEPackageTests.xctest"
DEFAULT_LEDGER = REPO_ROOT / "Scripts/Fixtures/test-suite-contract-ledger.tsv"
DEFAULT_WORKDIR_ROOT = Path("/tmp/rpce-parallel-tests")
XCRUN_PATH = Path("/usr/bin/xcrun")
RUNTIME_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
RUNTIME_GATE_KEYS = (
    "DEVELOPER_DIR",
    "REPOPROMPT_ENABLE_SENTRY",
    "RPCE_ENABLE_BENCHMARK_TESTS",
    "RPCE_RUN_CODEMAP_E2E",
    "RPCE_RUN_SCALE_TESTS",
    "SDKROOT",
    "TOOLCHAINS",
)
UNKNOWN_METHOD_WEIGHT = 45.0
UNKNOWN_SUITE_DEADLINE = 180.0

# These resources are unsafe when two suites that use the same process-global or
# filesystem state run in separate XCTest processes. Extra tags may be supplied
# with --serial-tag.
CROSS_PROCESS_UNSAFE_TAGS = frozenset(
    {
        "UserDefaults",
        "UserDefaults.standard",
        "UserDefaults.CodexCLIConnected",
        "UserDefaults.historyIdleThreshold",
        "userdefaults_suite",
        "ServerNetworkManager.bootstrapSocket",
        "mcp_shared_server",
        "temporary_application_support_root",
        "repository_checkout",
        "webkit_content_rule_store",
    }
)

TAG_SPLIT_RE = re.compile(r"[,;\s]+")
LISTED_TEST_RE = re.compile(
    r"^(?P<suite>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)/"
    r"(?P<method>[A-Za-z_][A-Za-z0-9_]*)$"
)
TEST_SHAPED_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[^\s/]+)+/[^\s/]+$"
)
SUMMARY_RE = re.compile(
    r"Executed\s+(?P<executed>\d+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>\d+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>\d+)\s+failures?\b"
)


class RunnerError(RuntimeError):
    """A user-facing runner configuration or input error."""


@dataclass(frozen=True)
class LedgerMethod:
    runtime_s: float | None
    shared_state_tags: frozenset[str]


@dataclass(frozen=True)
class SuiteWork:
    name: str
    methods: tuple[str, ...]
    expected_count: int
    weight: float
    ledger_runtime_s: float | None
    deadline_s: float
    serial_tags: tuple[str, ...]
    exclusive: bool


@dataclass
class Attempt:
    number: int
    worker: str
    duration_s: float
    executed: int | None
    failures: int | None
    exit_code: int | None
    status: str
    timed_out: bool


@dataclass
class SuiteResult:
    name: str
    attempts: list[Attempt] = field(default_factory=list)
    status: str = "NOT-RUN"

    @property
    def final_attempt(self) -> Attempt | None:
        return self.attempts[-1] if self.attempts else None

    @property
    def duration_s(self) -> float:
        return sum(attempt.duration_s for attempt in self.attempts)


class WorkHeap:
    """Thread-safe LPT heap shared by all parallel workers."""

    def __init__(self, suites: Sequence[SuiteWork]) -> None:
        self._items = [(-suite.weight, suite.name, suite) for suite in suites]
        heapq.heapify(self._items)
        self._lock = threading.Lock()

    def pop(self) -> SuiteWork | None:
        with self._lock:
            if not self._items:
                return None
            return heapq.heappop(self._items)[2]


class ProcessRegistry:
    """Tracks child process groups so cancellation can stop all of them."""

    def __init__(self) -> None:
        self._processes: set[subprocess.Popen[str]] = set()
        self._cancellation_groups: set[int] = set()
        self._cancelling = False
        self._lock = threading.Lock()

    def add(self, process: subprocess.Popen[str]) -> None:
        should_terminate = False
        with self._lock:
            self._processes.add(process)
            if self._cancelling:
                self._cancellation_groups.add(process.pid)
                should_terminate = True
        if should_terminate:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def discard(self, process: subprocess.Popen[str]) -> None:
        with self._lock:
            self._processes.discard(process)

    def terminate_all(self) -> None:
        with self._lock:
            processes = list(self._processes)
        for process in processes:
            terminate_process_group(process)

    def begin_cancellation(self) -> None:
        with self._lock:
            self._cancelling = True
            self._cancellation_groups.update(
                process.pid for process in self._processes
            )

    def signal_all(self, signum: int) -> None:
        with self._lock:
            group_ids = set(self._cancellation_groups)
            group_ids.update(process.pid for process in self._processes)
        for group_id in group_ids:
            try:
                os.killpg(group_id, signum)
            except ProcessLookupError:
                continue


PRINT_LOCK = threading.Lock()


def progress(message: str) -> None:
    with PRINT_LOCK:
        print(message, flush=True)


def split_tags(value: str) -> frozenset[str]:
    return frozenset(tag for tag in TAG_SPLIT_RE.split(value.strip()) if tag)


def parse_runtime(value: str, *, row_number: int) -> float | None:
    if not value.strip():
        return None
    try:
        runtime = float(value)
    except ValueError as exc:
        raise RunnerError(
            f"ledger row {row_number}: invalid runtime_seconds {value!r}"
        ) from exc
    if runtime < 0:
        raise RunnerError(
            f"ledger row {row_number}: invalid runtime_seconds {value!r}"
        )
    return runtime


def parse_test_list(path: Path) -> dict[str, set[str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RunnerError(f"cannot read test list {path}: {exc}") from exc

    suites: dict[str, set[str]] = defaultdict(set)
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        match = LISTED_TEST_RE.match(line)
        if match is None:
            if TEST_SHAPED_RE.match(line):
                raise RunnerError(
                    f"test list {path} line {line_number} has an unrecognized "
                    f"test identifier: {line!r}"
                )
            # SwiftPM diagnostics and ordinary non-test lines are ignored.
            continue
        suites[match.group("suite")].add(match.group("method"))

    if not suites:
        raise RunnerError(f"test list {path} contains no suite/method entries")
    return dict(suites)


def xctest_runtime_environment(tmpdir: Path) -> dict[str, str]:
    """Return the complete deterministic environment passed to direct XCTest."""
    environment = {"PATH": RUNTIME_PATH, "TMPDIR": str(tmpdir)}
    for key in RUNTIME_GATE_KEYS:
        value = os.environ.get(key)
        if value is not None:
            environment[key] = value
    return environment


def load_ledger(
    path: Path,
) -> tuple[dict[tuple[str, str], LedgerMethod], dict[str, frozenset[str]]]:
    required = {
        "target",
        "suite",
        "method",
        "runtime_seconds",
        "shared_state_tags",
        "current_disposition",
    }
    methods: dict[tuple[str, str], LedgerMethod] = {}
    suite_tags: dict[str, set[str]] = defaultdict(set)

    try:
        handle = path.open("r", encoding="utf-8", newline="")
    except OSError as exc:
        raise RunnerError(f"cannot read ledger {path}: {exc}") from exc

    with handle:
        reader = csv.DictReader(handle, delimiter="\t")
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise RunnerError(
                f"ledger {path} is missing columns: {', '.join(sorted(missing))}"
            )
        for row_number, row in enumerate(reader, start=2):
            if row["target"] != "root":
                continue
            suite = row["suite"].strip()
            method = row["method"].strip()
            if not suite or not method:
                continue
            tags = split_tags(row["shared_state_tags"])
            suite_tags[suite].update(tags)
            key = (suite, method)
            if key in methods:
                raise RunnerError(
                    f"ledger row {row_number}: duplicate root method {suite}/{method}"
                )
            methods[key] = LedgerMethod(
                runtime_s=parse_runtime(row["runtime_seconds"], row_number=row_number),
                shared_state_tags=tags,
            )

    return methods, {suite: frozenset(tags) for suite, tags in suite_tags.items()}


def deadline_for_runtime(runtime_s: float | None) -> float:
    if runtime_s is None:
        return UNKNOWN_SUITE_DEADLINE
    return max(90.0, 4.0 * runtime_s + 30.0)


def build_work_list(
    expected: dict[str, set[str]],
    ledger_methods: dict[tuple[str, str], LedgerMethod],
    ledger_suite_tags: dict[str, frozenset[str]],
    serial_tags: frozenset[str],
    suite_filter: re.Pattern[str] | None,
    exclusive_suite_patterns: Sequence[re.Pattern[str]],
) -> list[SuiteWork]:
    work: list[SuiteWork] = []
    for suite in sorted(expected):
        if suite_filter is not None and suite_filter.search(suite) is None:
            continue
        methods = tuple(sorted(expected[suite]))
        known_runtimes = [
            entry.runtime_s
            for method in methods
            if (entry := ledger_methods.get((suite, method))) is not None
            and entry.runtime_s is not None
        ]
        unknown_count = sum(
            1
            for method in methods
            if (entry := ledger_methods.get((suite, method))) is None
            or entry.runtime_s is None
        )
        ledger_runtime = sum(known_runtimes) if known_runtimes else None
        weight = sum(known_runtimes) + unknown_count * UNKNOWN_METHOD_WEIGHT
        matched_tags = tuple(sorted(ledger_suite_tags.get(suite, frozenset()) & serial_tags))
        work.append(
            SuiteWork(
                name=suite,
                methods=methods,
                expected_count=len(methods),
                weight=weight,
                ledger_runtime_s=ledger_runtime,
                deadline_s=deadline_for_runtime(ledger_runtime),
                serial_tags=matched_tags,
                exclusive=any(
                    pattern.search(suite) is not None
                    for pattern in exclusive_suite_patterns
                ),
            )
        )
    if not work:
        detail = " after applying --filter" if suite_filter is not None else ""
        raise RunnerError(f"no root XCTest suites selected{detail}")
    return work


def parse_suite_summary(output: str) -> tuple[int, int] | None:
    matches = list(SUMMARY_RE.finditer(output))
    if not matches:
        return None
    final = matches[-1]
    return int(final.group("executed")), int(final.group("failures"))


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


def safe_log_name(suite: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", suite)


def append_attempt_log(
    path: Path, attempt: Attempt, output: str, deadline_s: float
) -> None:
    header = (
        f"===== attempt {attempt.number} worker={attempt.worker} "
        f"status={attempt.status} exit_code={attempt.exit_code} "
        f"duration_s={attempt.duration_s:.3f} deadline={deadline_s:.1f}s =====\n"
    )
    with path.open("a", encoding="utf-8") as handle:
        handle.write(header)
        handle.write(output)
        if output and not output.endswith("\n"):
            handle.write("\n")
        handle.write("===== end attempt =====\n")


def run_attempt(
    suite: SuiteWork,
    *,
    attempt_number: int,
    worker: str,
    tmpdir: Path,
    bundle: Path,
    logs_dir: Path,
    registry: ProcessRegistry,
    deadline_override_s: float | None = None,
) -> Attempt:
    deadline_s = suite.deadline_s if deadline_override_s is None else deadline_override_s
    tmpdir.mkdir(parents=True, exist_ok=True)
    environment = xctest_runtime_environment(tmpdir)
    command = [str(XCRUN_PATH), "xctest", "-XCTest", suite.name, str(bundle)]
    progress(
        f"START worker={worker} suite={suite.name} "
        f"attempt={attempt_number} deadline={deadline_s:.1f}s"
    )
    started = time.monotonic()
    output = ""
    exit_code: int | None = None
    timed_out = False
    process: subprocess.Popen[str] | None = None

    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            env=environment,
            start_new_session=True,
        )
        registry.add(process)
        try:
            output, _ = process.communicate(timeout=deadline_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_process_group(process)
            remaining, _ = process.communicate()
            output = (output or "") + (remaining or "")
        exit_code = process.returncode
    except KeyboardInterrupt:
        if process is not None:
            terminate_process_group(process)
        raise
    except OSError as exc:
        output = f"failed to launch {' '.join(command)}: {exc}\n"
    finally:
        if process is not None:
            registry.discard(process)

    duration = time.monotonic() - started
    summary = parse_suite_summary(output)
    executed, failures = summary if summary is not None else (None, None)
    if timed_out:
        status = "TIMEOUT"
    elif exit_code not in (0,):
        # Per the runner contract, any nonzero xctest exit is a crash even when
        # XCTest happened to print a summary before terminating.
        status = "CRASH"
    elif summary is None:
        status = "CRASH"
    elif failures:
        status = "FAILED"
    else:
        status = "PASS"

    attempt = Attempt(
        number=attempt_number,
        worker=worker,
        duration_s=duration,
        executed=executed,
        failures=failures,
        exit_code=exit_code,
        status=status,
        timed_out=timed_out,
    )
    append_attempt_log(
        logs_dir / f"{safe_log_name(suite.name)}.log", attempt, output, deadline_s
    )
    progress(
        f"FINISH worker={worker} suite={suite.name} attempt={attempt_number} "
        f"status={status} duration={duration:.1f}s deadline={deadline_s:.1f}s "
        f"executed={executed} "
        f"failures={failures} exit={exit_code}"
    )
    return attempt


def print_plan(work: Sequence[SuiteWork], workers: int) -> None:
    parallel = sorted(
        (suite for suite in work if not suite.exclusive and not suite.serial_tags),
        key=lambda suite: (-suite.weight, suite.name),
    )
    serial = sorted(
        (suite for suite in work if not suite.exclusive and suite.serial_tags),
        key=lambda suite: (-suite.weight, suite.name),
    )
    exclusive = sorted(
        (suite for suite in work if suite.exclusive),
        key=lambda suite: (-suite.weight, suite.name),
    )
    print(
        f"PLAN workers={workers} suites={len(work)} "
        f"parallel={len(parallel)} serial={len(serial)} exclusive={len(exclusive)}"
    )
    print("PARALLEL LPT QUEUE")
    for index, suite in enumerate(parallel, start=1):
        runtime = (
            "unknown" if suite.ledger_runtime_s is None else f"{suite.ledger_runtime_s:.3f}s"
        )
        print(
            f"  {index:3d}. {suite.name} tests={suite.expected_count} "
            f"weight={suite.weight:.3f} ledger_runtime={runtime} "
            f"deadline={suite.deadline_s:.1f}s"
        )
    print("SERIAL LPT QUEUE (dedicated lane)")
    if not serial:
        print("  (empty)")
    for index, suite in enumerate(serial, start=1):
        runtime = (
            "unknown" if suite.ledger_runtime_s is None else f"{suite.ledger_runtime_s:.3f}s"
        )
        print(
            f"  {index:3d}. {suite.name} tests={suite.expected_count} "
            f"weight={suite.weight:.3f} ledger_runtime={runtime} "
            f"deadline={suite.deadline_s:.1f}s "
            f"tags={','.join(suite.serial_tags)}"
        )
    print("EXCLUSIVE QUEUE")
    if not exclusive:
        print("  (empty)")
    for index, suite in enumerate(exclusive, start=1):
        runtime = (
            "unknown" if suite.ledger_runtime_s is None else f"{suite.ledger_runtime_s:.3f}s"
        )
        print(
            f"  {index:3d}. {suite.name} tests={suite.expected_count} "
            f"weight={suite.weight:.3f} ledger_runtime={runtime} "
            f"deadline={max(suite.deadline_s, 300.0):.1f}s"
        )


def attempt_payload(attempt: Attempt) -> dict[str, object]:
    payload = asdict(attempt)
    payload["duration_s"] = round(attempt.duration_s, 3)
    return payload


def suite_payload(result: SuiteResult) -> dict[str, object]:
    final = result.final_attempt
    return {
        "name": result.name,
        "worker": final.worker if final else None,
        "duration_s": round(result.duration_s, 3),
        "executed": final.executed if final else None,
        "failures": final.failures if final else None,
        "status": result.status,
        "attempts": [attempt_payload(attempt) for attempt in result.attempts],
    }


def write_summary_json(
    path: Path,
    *,
    wall_time_s: float,
    busy_times: dict[str, float],
    work: Sequence[SuiteWork],
    results: dict[str, SuiteResult],
    retries: int,
    parity_mismatches: list[dict[str, object]],
    failures: list[str],
    interrupted: bool,
) -> None:
    final_test_count = sum(
        result.final_attempt.executed
        for result in results.values()
        if result.final_attempt is not None and result.final_attempt.executed is not None
    )
    final_failure_count = sum(
        result.final_attempt.failures
        for result in results.values()
        if result.final_attempt is not None and result.final_attempt.failures is not None
    )
    payload = {
        "status": "PASS" if not failures else "FAIL",
        "wall_time_s": round(wall_time_s, 3),
        "worker_busy_time_s": {
            worker: round(duration, 3) for worker, duration in sorted(busy_times.items())
        },
        "suite_count": len(work),
        "completed_suite_count": len(results),
        "expected_test_count": sum(suite.expected_count for suite in work),
        "executed_test_count": final_test_count,
        "failure_count": final_failure_count,
        "retry_count": retries,
        "interrupted": interrupted,
        "parity_mismatches": parity_mismatches,
        "fail_reasons": failures,
        "suites": [
            suite_payload(results[suite.name])
            for suite in sorted(work, key=lambda item: item.name)
            if suite.name in results
        ],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_suites(
    work: Sequence[SuiteWork],
    *,
    workers: int,
    bundle: Path,
    workdir: Path,
    retry_failed: bool,
) -> int:
    logs_dir = workdir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    registry = ProcessRegistry()
    stop_event = threading.Event()
    result_lock = threading.Lock()
    results: dict[str, SuiteResult] = {}
    busy_times: dict[str, float] = defaultdict(float)

    parallel_suites = [
        suite for suite in work if not suite.exclusive and not suite.serial_tags
    ]
    serial_suites = sorted(
        (suite for suite in work if not suite.exclusive and suite.serial_tags),
        key=lambda suite: (-suite.weight, suite.name),
    )
    exclusive_suites = sorted(
        (suite for suite in work if suite.exclusive),
        key=lambda suite: (-suite.weight, suite.name),
    )
    for index in range(1, workers + 1):
        (workdir / f"w{index}" / "tmp").mkdir(parents=True, exist_ok=True)
        busy_times[f"w{index}"] = 0.0
    if serial_suites:
        (workdir / "w0" / "tmp").mkdir(parents=True, exist_ok=True)
        busy_times["w0-serial"] = 0.0
    if exclusive_suites:
        busy_times["w-exclusive"] = 0.0
    parallel_heap = WorkHeap(parallel_suites)
    suite_by_name = {suite.name: suite for suite in work}

    def record(suite: SuiteWork, attempt: Attempt) -> None:
        with result_lock:
            result = results.setdefault(suite.name, SuiteResult(name=suite.name))
            result.attempts.append(attempt)
            result.status = attempt.status
            busy_times[attempt.worker] += attempt.duration_s

    def parallel_worker(index: int) -> None:
        worker = f"w{index}"
        # CodeMapRootManifestStore flocks the parent of its root. Test roots use
        # FileManager.default.temporaryDirectory, so a distinct TMPDIR per worker
        # removes the cross-process parent-directory flock collision.
        tmpdir = workdir / worker / "tmp"
        while not stop_event.is_set():
            suite = parallel_heap.pop()
            if suite is None:
                return
            record(
                suite,
                run_attempt(
                    suite,
                    attempt_number=1,
                    worker=worker,
                    tmpdir=tmpdir,
                    bundle=bundle,
                    logs_dir=logs_dir,
                    registry=registry,
                ),
            )

    def serial_worker() -> None:
        worker = "w0-serial"
        tmpdir = workdir / "w0" / "tmp"
        for suite in serial_suites:
            if stop_event.is_set():
                return
            record(
                suite,
                run_attempt(
                    suite,
                    attempt_number=1,
                    worker=worker,
                    tmpdir=tmpdir,
                    bundle=bundle,
                    logs_dir=logs_dir,
                    registry=registry,
                ),
            )

    started = time.monotonic()
    threads = [
        threading.Thread(target=parallel_worker, args=(index,), name=f"xctest-w{index}")
        for index in range(1, workers + 1)
    ]
    if serial_suites:
        threads.append(threading.Thread(target=serial_worker, name="xctest-serial"))

    termination_signal: int | None = None
    kill_timer: threading.Timer | None = None
    previous_signal_handlers: dict[int, signal.Handlers] = {}

    def handle_termination(signum: int, _frame: object) -> None:
        nonlocal termination_signal, kill_timer
        if termination_signal is not None:
            return
        termination_signal = signum
        stop_event.set()
        progress(
            f"INTERRUPTED: received {signal.Signals(signum).name}; "
            "terminating all active xctest process groups"
        )
        registry.begin_cancellation()
        registry.signal_all(signal.SIGTERM)
        kill_timer = threading.Timer(2.0, registry.signal_all, args=(signal.SIGKILL,))
        kill_timer.daemon = True
        kill_timer.start()

    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGTERM, signal.SIGHUP):
            previous_signal_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, handle_termination)

    interrupted = False
    for thread in threads:
        thread.start()
    try:
        for thread in threads:
            while thread.is_alive():
                thread.join(timeout=0.2)
    except KeyboardInterrupt:
        interrupted = True
        stop_event.set()
        progress("INTERRUPTED: terminating all active xctest process groups")
        registry.terminate_all()
        for thread in threads:
            thread.join()
    if termination_signal is not None:
        interrupted = True

    if not interrupted:
        for exclusive_index, suite in enumerate(exclusive_suites, start=1):
            try:
                attempt = run_attempt(
                    suite,
                    attempt_number=1,
                    worker="w-exclusive",
                    tmpdir=workdir / "exclusive" / str(exclusive_index) / "tmp",
                    bundle=bundle,
                    logs_dir=logs_dir,
                    registry=registry,
                    deadline_override_s=max(suite.deadline_s, 300.0),
                )
            except KeyboardInterrupt:
                interrupted = True
                stop_event.set()
                progress("INTERRUPTED: terminating the active exclusive process group")
                registry.terminate_all()
                break
            record(suite, attempt)
            if termination_signal is not None:
                interrupted = True
                break

    retries = 0
    if retry_failed and not interrupted:
        retry_names = sorted(
            name
            for name, result in results.items()
            if result.status in {"FAILED", "CRASH", "TIMEOUT"}
        )
        for retry_index, name in enumerate(retry_names, start=1):
            suite = suite_by_name[name]
            prior_status = results[name].status
            retry_deadline = (
                max(3.0 * suite.deadline_s, 300.0)
                if prior_status == "TIMEOUT"
                else suite.deadline_s
            )
            retries += 1
            progress(
                f"RETRY suite={name} prior_status={prior_status} "
                f"deadline={retry_deadline:.1f}s "
                f"fresh_tmpdir=retry/{retry_index}/tmp"
            )
            try:
                attempt = run_attempt(
                    suite,
                    attempt_number=2,
                    worker="retry",
                    tmpdir=workdir / "retry" / str(retry_index) / "tmp",
                    bundle=bundle,
                    logs_dir=logs_dir,
                    registry=registry,
                    deadline_override_s=(
                        retry_deadline if prior_status == "TIMEOUT" else None
                    ),
                )
            except KeyboardInterrupt:
                interrupted = True
                stop_event.set()
                progress("INTERRUPTED: terminating the active retry process group")
                registry.terminate_all()
                break
            record(suite, attempt)
            results[name].status = (
                "RETRIED-PASS" if attempt.status == "PASS" else "RETRIED-FAIL"
            )
            if termination_signal is not None:
                interrupted = True
                break

    if termination_signal is not None:
        interrupted = True
    if kill_timer is not None:
        kill_timer.join(timeout=2.5)
    for signum, previous in previous_signal_handlers.items():
        signal.signal(signum, previous)

    wall_time = time.monotonic() - started
    expected_total = sum(suite.expected_count for suite in work)
    parity_mismatches: list[dict[str, object]] = []
    executed_total = 0
    for suite in work:
        result = results.get(suite.name)
        actual = (
            result.final_attempt.executed
            if result is not None and result.final_attempt is not None
            else None
        )
        if actual is not None:
            executed_total += actual
        if actual != suite.expected_count:
            kind = (
                "MISSING"
                if actual is None or actual < suite.expected_count
                else "EXTRA"
            )
            parity_mismatches.append(
                {
                    "suite": suite.name,
                    "expected": suite.expected_count,
                    "executed": actual,
                    "kind": kind,
                }
            )

    # V1 intentionally gates method parity by per-suite counts only; it does not
    # verify individual method names in XCTest output.
    if executed_total != expected_total and not parity_mismatches:
        parity_mismatches.append(
            {
                "suite": "<total>",
                "expected": expected_total,
                "executed": executed_total,
                "kind": "MISSING" if executed_total < expected_total else "EXTRA",
            }
        )

    fail_reasons: list[str] = []
    missing_suites = sorted(suite.name for suite in work if suite.name not in results)
    if interrupted:
        fail_reasons.append("run interrupted")
    if missing_suites:
        fail_reasons.append("suites not run: " + ", ".join(missing_suites))
    for suite in work:
        result = results.get(suite.name)
        if result is None:
            continue
        if result.status not in {"PASS", "RETRIED-PASS"}:
            fail_reasons.append(f"{suite.name}: {result.status}")
    for mismatch in parity_mismatches:
        fail_reasons.append(
            f"{mismatch['suite']}: {mismatch['kind']} "
            f"expected={mismatch['expected']} executed={mismatch['executed']}"
        )

    final_failures = sum(
        result.final_attempt.failures or 0
        for result in results.values()
        if result.final_attempt is not None
    )
    print()
    print("FINAL SUMMARY")
    print(f"  result: {'FAIL' if fail_reasons else 'PASS'}")
    print(f"  wall time: {wall_time:.1f}s")
    for worker, duration in sorted(busy_times.items()):
        print(f"  busy {worker}: {duration:.1f}s")
    print(f"  suites: {len(results)}/{len(work)}")
    print(f"  tests: {executed_total}/{expected_total}")
    print(f"  failures: {final_failures}")
    print(f"  retries: {retries}")
    retried_results = sorted(
        (result for result in results.values() if len(result.attempts) > 1),
        key=lambda result: result.name,
    )
    if retried_results:
        print("  RETRIES (both attempts):")
        for result in retried_results:
            attempts = " -> ".join(
                f"attempt {attempt.number} {attempt.status} ({attempt.duration_s:.1f}s)"
                for attempt in result.attempts
            )
            print(f"    {result.name}: {attempts} => {result.status}")
    print("  slowest suites (all attempts):")
    for result in sorted(results.values(), key=lambda item: (-item.duration_s, item.name))[:10]:
        print(f"    {result.duration_s:.1f}s {result.name} [{result.status}]")

    if fail_reasons:
        print("FAIL")
        for reason in fail_reasons:
            print(f"  - {reason}")

    write_summary_json(
        workdir / "summary.json",
        wall_time_s=wall_time,
        busy_times=dict(busy_times),
        work=work,
        results=results,
        retries=retries,
        parity_mismatches=parity_mismatches,
        failures=fail_reasons,
        interrupted=interrupted,
    )
    print(f"  JSON summary: {workdir / 'summary.json'}")
    return 1 if fail_reasons else 0


def default_workdir() -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_WORKDIR_ROOT / timestamp


def generate_test_list(path: Path) -> int:
    command = [str(REPO_ROOT / "Scripts" / "canonical_swift.sh"), "test", "list", "--skip-build"]
    progress("$ " + " ".join(command))
    try:
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        raise RunnerError(f"cannot generate test list: {exc}") from exc
    if completed.returncode != 0:
        if completed.stderr:
            progress(completed.stderr.rstrip())
        return completed.returncode
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(completed.stdout, encoding="utf-8")
        os.replace(temporary, path)
    except OSError as exc:
        raise RunnerError(f"cannot write generated test list {path}: {exc}") from exc
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run suites from an already-built root XCTest bundle across parallel "
            "direct-xctest worker processes."
        )
    )
    parser.add_argument("--workers", type=int, required=True, help="parallel worker count")
    parser.add_argument(
        "--bundle",
        type=Path,
        default=DEFAULT_BUNDLE,
        help=f"built XCTest bundle (default: {DEFAULT_BUNDLE})",
    )
    parser.add_argument(
        "--test-list",
        type=Path,
        required=True,
        help="file containing authoritative 'swift test list' output",
    )
    parser.add_argument(
        "--generate-test-list",
        action="store_true",
        help="refresh --test-list with 'swift test list --skip-build' before running",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=DEFAULT_LEDGER,
        help=f"test contract ledger (default: {DEFAULT_LEDGER})",
    )
    parser.add_argument(
        "--workdir",
        type=Path,
        default=None,
        help="run output directory (default: /tmp/rpce-parallel-tests/<timestamp>)",
    )
    parser.add_argument("--filter", help="optional regular expression selecting suite names")
    parser.add_argument(
        "--plan-only",
        action="store_true",
        help="print LPT queues and serial classification without running xctest",
    )
    parser.add_argument(
        "--serial-tag",
        action="append",
        default=[],
        metavar="TAG",
        help="additional shared-state tag requiring the dedicated serial lane",
    )
    parser.add_argument(
        "--exclusive-suite",
        action="append",
        default=[],
        metavar="REGEX",
        help="suite-name regex requiring an exclusive post-worker phase",
    )
    retry_group = parser.add_mutually_exclusive_group()
    retry_group.add_argument(
        "--retry-failed",
        dest="retry_failed",
        action="store_true",
        default=True,
        help="retry failed/crashed suites once serially (default)",
    )
    retry_group.add_argument(
        "--no-retry-failed",
        dest="retry_failed",
        action="store_false",
        help="disable the single serial retry",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.workers < 1:
        parser.error("--workers must be at least 1")

    if args.generate_test_list:
        try:
            list_exit_code = generate_test_list(args.test_list)
        except RunnerError as exc:
            parser.error(str(exc))
        if list_exit_code != 0:
            return list_exit_code

    suite_filter: re.Pattern[str] | None = None
    if args.filter:
        try:
            suite_filter = re.compile(args.filter)
        except re.error as exc:
            parser.error(f"invalid --filter regular expression: {exc}")

    exclusive_suite_patterns: list[re.Pattern[str]] = []
    for pattern in args.exclusive_suite:
        try:
            exclusive_suite_patterns.append(re.compile(pattern))
        except re.error as exc:
            parser.error(f"invalid --exclusive-suite regular expression: {exc}")

    try:
        expected = parse_test_list(args.test_list)
        ledger_methods, ledger_suite_tags = load_ledger(args.ledger)
        serial_tags = CROSS_PROCESS_UNSAFE_TAGS | frozenset(args.serial_tag)
        work = build_work_list(
            expected,
            ledger_methods,
            ledger_suite_tags,
            serial_tags,
            suite_filter,
            exclusive_suite_patterns,
        )
    except RunnerError as exc:
        parser.error(str(exc))

    if args.plan_only:
        print_plan(work, args.workers)
        return 0

    bundle = args.bundle.resolve()
    if not bundle.exists():
        parser.error(
            f"XCTest bundle does not exist: {bundle}; "
            "run swift build --build-tests first"
        )
    workdir = (args.workdir or default_workdir()).resolve()
    try:
        workdir.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error(f"workdir already exists: {workdir}")
    except OSError as exc:
        parser.error(f"cannot create workdir {workdir}: {exc}")

    print_plan(work, args.workers)
    print(f"WORKDIR {workdir}")
    return run_suites(
        work,
        workers=args.workers,
        bundle=bundle,
        workdir=workdir,
        retry_failed=args.retry_failed,
    )


if __name__ == "__main__":
    raise SystemExit(main())
