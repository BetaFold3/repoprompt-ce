#!/usr/bin/env python3
"""Versioned conductor benchmark harness (build-pipeline plan, Step 1).

The harness measures a *target* conductor implementation (a directory holding
``Scripts/conductor.py``, its import dependency ``Scripts/debug_app_process.py``
and the ``conductor`` launcher). Every workload drives the target's real code
paths through explicit, versioned adapters; nothing is re-implemented here.

Subcommands:

* ``run``      capture one or more target arms (ABBA-interleaved, fresh worker
               process per sample) into ``<state>/benchmarks/conductor/<id>/``.
* ``compare``  apply gates to two captures. Exit codes: 0 qualified,
               1 established regression, 2 inconclusive, 3 harness failure.
               Missing, partial, malformed, or incompatible evidence never passes.
* ``label``    attach evidence labels (exclusion, contamination windows).
* ``fixture``  print or verify the deterministic fixture digests.
* ``machine``  measure current foreign CPU against the predeclared contamination limit.

Workloads: ``output summary mem cli`` (default) plus ``artifact rss`` (full).
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import fnmatch
import gc
import hashlib
import importlib.util
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import tracemalloc
import types
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

HARNESS_VERSION = 5
CAPTURE_SCHEMA_VERSION = 3
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
FIXTURE_DIR = SCRIPT_DIR / "Fixtures" / "conductor-benchmark" / "v1"
MANIFEST_PATH = FIXTURE_DIR / "manifest.json"
GATES_PATH = FIXTURE_DIR / "gates.json"
SUMMARY_GOLDEN_PATH = FIXTURE_DIR / "summary-golden.json"
TARGET_FILES = ("Scripts/conductor.py", "Scripts/debug_app_process.py", "conductor")
# Staged and digested only when the target has them (Step 2+ conductors load the timing
# helper by explicit path from their own directory). Absent files leave the digest of a
# required-files-only target unchanged, so earlier targets keep their conductorDigest.
OPTIONAL_TARGET_FILES = ("Scripts/swift_pipeline_metrics.py",)
FAST_WORKLOADS = ("output", "summary", "mem", "cli")
FULL_WORKLOADS = FAST_WORKLOADS + ("artifact", "rss")
TARGET_MODULE_NAME = "rpce_bench_target_conductor"
HARNESS_FILES = (
    "Scripts/conductor_benchmark.py",
    "Scripts/Fixtures/conductor-benchmark/v1/manifest.json",
    "Scripts/Fixtures/conductor-benchmark/v1/gates.json",
    "Scripts/Fixtures/conductor-benchmark/v1/summary-golden.json",
)
LABELS_FILE = "labels.json"
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
OUTPUT_VARIANTS = (("pipe", 0), ("pipe", 4), ("pty", 0), ("pty", 4))
PTY_TAIL_EVIDENCE_BYTES = 512
# The PTY output-queue high-water mark measured on the reference host (a non-blocking
# writer is refused beyond 1024 queued bytes). A fixture whose ONLCR-translated size
# stays within it can never fill the queue, so the tty never retries a CR.
PTY_FIDELITY_MAX_BYTES = 1024
PTY_FIDELITY_KEY = "output.pty.fidelity.exact_tail_sha256"

EXIT_QUALIFIED = 0
EXIT_REGRESSION = 1
EXIT_INCONCLUSIVE = 2
EXIT_HARNESS_FAILURE = 3

ADAPTER_VERSIONS = {
    "output": "read_process_output+pty_xctest_watchdog+pty_exact_tail_fidelity@3",
    "summary": "summarize_file+frozen_retained_corpus@2",
    "mem": "record_progress_ledger+section_seen@1",
    "cli": "launcher_subprocess@1",
    "artifact": "client_evaluate+enqueue+run_job@1",
    "rss": "enqueue_run_job_retained_footprint@1",
}


class HarnessError(Exception):
    """A harness, fixture, or evidence failure (never a measurement)."""


# ---------------------------------------------------------------------------
# Deterministic primitives


class SplitMix64:
    """Version-stable PRNG so fixtures never depend on CPython's ``random``."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int) -> None:
        self.state = seed & self.MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def below(self, bound: int) -> int:
        if bound <= 0:
            raise ValueError("bound must be positive")
        return self.next() % bound


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_digest(value: Any) -> str:
    return sha256_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def load_manifest(path: Path = MANIFEST_PATH) -> Dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise HarnessError(f"fixture manifest unreadable at {path}: {exc}") from exc
    if manifest.get("fixtureVersion") != 1:
        raise HarnessError(f"unsupported fixture version in {path}")
    return manifest


MODULES = ("RepoPrompt", "RepoPromptMCP", "RepoPromptShared", "RepoPromptGateway", "RepoPromptTests")
SUITES = ("AgentModeViewModelTests", "MCPInitializeCompatibilityTests", "OracleWaitTests", "CodeMapTests")


def generate_output_fixture(seed: int, size: int) -> bytes:
    """A deterministic swift-build/XCTest-shaped log of exactly ``size`` bytes.

    Its shape follows retained compiling logs (plan U6): about 100k LF records,
    several thousand bare-CR progress segments with erase-line ANSI sequences,
    a few LF "lines" of ~200 KB built from CR runs, SGR colour, multi-byte
    UTF-8, warnings, errors, XCTest progress markers, and no trailing newline.
    """
    rng = SplitMix64(seed)
    out = bytearray(b"Building for debugging...\n")
    total = 2400
    step = 0
    test_index = 0
    build_complete_written = False
    while len(out) < size:
        roll = rng.below(100_000)
        step += 1
        module = MODULES[rng.below(len(MODULES))]
        name = f"File{rng.below(5000):04d}"
        if not build_complete_written and len(out) > size // 5:
            out += b"Build complete! (194.04s)\n"
            build_complete_written = True
        elif roll < 3:
            segments = 3000 + rng.below(2000)
            for index in range(segments):
                out += f"\x1b[2K[{index}/{segments}] Write {name}.swiftmodule\r".encode()
            out += b"\n"
        elif roll < 2_000:
            segments = 1 + rng.below(5)
            for index in range(segments):
                out += f"\x1b[2K[{index}/{segments}] Linking {module}\r".encode()
            out += b"\n"
        elif roll < 45_000:
            out += f"[{step % total}/{total}] Compiling {module} {name}.swift\n".encode()
        elif roll < 57_000:
            line = rng.below(900) + 1
            out += (
                f"/Users/dev/src/Sources/{module}/{name}.swift:{line}:{rng.below(80) + 1}: "
                f"warning: variable 'value{rng.below(100)}' was never mutated; consider 'let'\n"
            ).encode()
        elif roll < 77_000:
            suite = SUITES[rng.below(len(SUITES))]
            test_index += 1
            case = f"-[RepoPromptTests.{suite} testCase{test_index:05d}]"
            outcome = "failed" if rng.below(50) == 0 else "passed"
            out += f"\x1b[32mTest Case '{case}' started.\x1b[0m\n".encode()
            out += f"Test Case '{case}' {outcome} (0.{rng.below(1000):03d} seconds).\n".encode()
        elif roll < 82_000:
            out += f"  ✓ résumé 日本語 {name} — ok ✔︎ {rng.below(10**6)}\n".encode("utf-8")
        elif roll < 83_000:
            out += (
                f"/Users/dev/src/Sources/{module}/{name}.swift:{rng.below(900) + 1}:7: "
                "error: cannot find 'missingSymbol' in scope\n"
            ).encode()
        elif roll < 83_300:
            out += b"error: emit-module command failed with exit code 1 (use -v to see invocation)\n"
        else:
            out += f"    note: {module}.{name} resolved in {rng.below(9999)} us\n".encode()
    del out[size:]
    if out[-1:] == b"\n":
        out[-1:] = b"."
    return bytes(out)


def generate_pty_fidelity_fixture() -> bytes:
    """A small deterministic log whose PTY delivery is exact, for full visible-tail fidelity.

    Its ONLCR-translated size stays within ``PTY_FIDELITY_MAX_BYTES``, so the tty
    output queue never fills and the line discipline never retries a CR: the bytes
    read must equal ``onlcr(fixture)`` exactly, and the target's whole visible tail
    (every entry and every entry boundary) is a deterministic function of them. It
    holds more records than the visible tail keeps and covers each boundary the
    tail splitter sees: LF, bare-CR progress segments, a written CR LF (``\\r\\r\\n``
    after ONLCR), form feed, U+0085, SGR colour, multi-byte UTF-8, an invalid byte,
    XCTest markers, and an unterminated final record.
    """
    out = bytearray(b"Building for debugging...\n")
    for index in range(20):
        out += f"[{index}/20] Compiling M{index % 3}.swift\n".encode()
    out += b"\x1b[2K[1/3] Linking A\r\x1b[2K[2/3] Linking A\r\x1b[2K[3/3] Linking A\n"
    out += b"warning: crlf\r\n"
    out += "  ✓ résumé 日本\n".encode("utf-8")
    out += b"bad \xff byte\n"
    out += b"page\x0cbreak\n"
    out += "nel\u0085next\n".encode("utf-8")
    out += b"\x1b[32mTest Case '-[RepoPromptTests.OracleWaitTests testA]' started.\x1b[0m\n"
    out += b"Test Case '-[RepoPromptTests.OracleWaitTests testA]' passed (0.001 seconds).\n"
    out += b"Test Case '-[RepoPromptTests.OracleWaitTests testB]' started.\n"
    out += b"tail without newline"
    return bytes(out)


def verified_fixtures(manifest: Dict[str, Any]) -> Tuple[bytes, bytes]:
    """Generate the output and PTY-fidelity fixtures and prove they match the pinned manifest."""
    output_spec = manifest["output"]
    output = generate_output_fixture(int(output_spec["seed"]), int(output_spec["sizeBytes"]))
    if len(output) != int(output_spec["sizeBytes"]) or sha256_bytes(output) != output_spec["sha256"]:
        raise HarnessError("generated output fixture does not match the manifest size and digest")
    fidelity_spec = output_spec["ptyFidelity"]
    fidelity = generate_pty_fidelity_fixture()
    if len(fidelity) != int(fidelity_spec["sizeBytes"]) or sha256_bytes(fidelity) != fidelity_spec["sha256"]:
        raise HarnessError("generated PTY fidelity fixture does not match the manifest size and digest")
    if len(onlcr(fidelity)) > PTY_FIDELITY_MAX_BYTES:
        raise HarnessError(f"PTY fidelity fixture exceeds the {PTY_FIDELITY_MAX_BYTES}-byte PTY output queue bound")
    return output, fidelity


def onlcr(data: bytes) -> bytes:
    """Default PTY output post-processing (``OPOST|ONLCR``): ``\\n`` -> ``\\r\\n``."""
    return data.replace(b"\n", b"\r\n")


def verify_transport_stream(transport_kind: str, written: bytes, read: bytes) -> List[int]:
    """Prove the transport delivered the written bytes, position by position.

    A pipe must be byte-identical. A PTY applies ONLCR, so every written LF
    must arrive as CR LF and every other written byte must arrive unchanged at
    its translated position. The one tolerated deviation is the macOS line
    discipline retrying an ONLCR expansion that did not fit the output queue,
    which re-emits its CR: exactly one extra CR directly before the CR LF of a
    written LF (``\\r\\n`` -> ``\\r\\r\\n``). Deleted, relocated, or any other
    inserted bytes fail. Returns the offsets in ``read`` of the retried CRs.
    """
    if transport_kind == "pipe":
        if read != written:
            raise HarnessError(f"pipe: bytes read ({len(read)}) differ from bytes written ({len(written)})")
        return []
    inserted: List[int] = []
    segments = written.split(b"\n")
    last = len(segments) - 1
    position = 0
    for index, segment in enumerate(segments):
        if not read.startswith(segment, position):
            raise HarnessError(f"pty: written bytes of record {index} not found at read offset {position}")
        position += len(segment)
        if index == last:
            break
        if read.startswith(b"\r\n", position):
            position += 2
        elif read.startswith(b"\r\r\n", position):
            inserted.append(position)
            position += 3
        else:
            raise HarnessError(f"pty: written LF at read offset {position} did not arrive as ONLCR CR LF")
    if position != len(read):
        raise HarnessError(f"pty: {len(read) - position} unexpected bytes after the written stream")
    return inserted


def pty_tail_evidence(tail: Iterable[str], read: bytes, inserted: Sequence[int]) -> Dict[str, Any]:
    """Arm-comparable evidence for a PTY job tail.

    The tail must be a suffix of the bytes the target received; the tty-retried
    CRs at their exact offsets are removed, and the last fixed number of bytes
    are digested so window shifts caused by retried CRs cannot vary the result.
    """
    joined = "".join(tail).encode("utf-8", errors="surrogateescape")
    if not read.endswith(joined):
        return {"suffixOfStream": False, "tailSha256": sha256_bytes(joined)}
    start = len(read) - len(joined)
    drop = {offset - start for offset in inserted if offset >= start}
    normalized = bytes(value for index, value in enumerate(joined) if index not in drop)
    if len(normalized) < PTY_TAIL_EVIDENCE_BYTES:
        return {"suffixOfStream": True, "shortTailBytes": len(normalized)}
    return {
        "suffixOfStream": True,
        "suffixBytes": PTY_TAIL_EVIDENCE_BYTES,
        "suffixSha256": sha256_bytes(normalized[-PTY_TAIL_EVIDENCE_BYTES:]),
    }


def verify_pty_output_mode(fd: int) -> None:
    import termios

    oflag = termios.tcgetattr(fd)[1]
    unsupported = 0
    for name in ("OCRNL", "ONOCR", "ONLRET", "OXTABS", "OFILL"):
        unsupported |= getattr(termios, name, 0)
    if not (oflag & termios.OPOST and oflag & termios.ONLCR) or oflag & unsupported:
        raise HarnessError(f"unsupported PTY output mode {oflag:#x}; expected exactly OPOST|ONLCR translation")


# ---------------------------------------------------------------------------
# Targets


def present_target_files(root: Path) -> Tuple[str, ...]:
    """Required target files, then whichever optional files the target has."""
    return TARGET_FILES + tuple(relative for relative in OPTIONAL_TARGET_FILES if (root / relative).is_file())


def target_digest(root: Path) -> Dict[str, Any]:
    files: Dict[str, str] = {}
    combined = hashlib.sha256()
    for relative in present_target_files(root):
        path = root / relative
        if not path.is_file():
            raise HarnessError(f"target {root} is missing {relative}")
        digest = sha256_file(path)
        files[relative] = digest
        combined.update(f"{relative}\0{digest}\n".encode())
    return {"root": str(root), "files": files, "conductorDigest": combined.hexdigest()}


def harness_digest() -> Dict[str, Any]:
    files = {relative: sha256_file(REPO_ROOT / relative) for relative in HARNESS_FILES}
    return {"files": files, "digest": canonical_json_digest(files)}


def stage_target(name: str, root: Path, staging_root: Path, expected: Dict[str, Any]) -> Path:
    """Copy a target's files into a private staging root and verify their bytes.

    Every arm then runs from an identical, writable layout: the dependency's
    bytecode is precompiled once (as an ordinary import would cache it) and
    ``conductor.py`` is compiled from source per process.
    """
    staged = staging_root / name
    (staged / "Scripts").mkdir(parents=True)
    for relative in expected["files"]:
        shutil.copy2(root / relative, staged / relative)
    if target_digest(staged)["files"] != expected["files"]:
        raise HarnessError(f"staged copy of target {name} does not match its source bytes")
    dependencies = [str(staged / relative) for relative in expected["files"] if relative.endswith(".py") and relative != "Scripts/conductor.py"]
    subprocess.run(
        [sys.executable, "-c", "import py_compile, sys; [py_compile.compile(p, doraise=True) for p in sys.argv[1:]]", *dependencies],
        check=True,
        capture_output=True,
    )
    return staged


def load_target_module(root: Path) -> Any:
    """Load ``<root>/Scripts/conductor.py`` the way production executes it.

    The daemon, job runners, and the launcher all run ``conductor.py`` as
    ``__main__``, which CPython always compiles from source and never caches,
    while ``debug_app_process`` is an ordinary (bytecode-cached) import. Loading
    mirrors exactly that, so every arm pays the same compile and allocation cost
    regardless of whether its directory has or permits a ``__pycache__``.

    Must run in a fresh worker process: the harness directory is removed from
    ``sys.path`` so ``debug_app_process`` resolves inside the target only.
    """
    scripts = (root / "Scripts").resolve()
    sys.path[:] = [entry for entry in sys.path if Path(entry or ".").resolve() != SCRIPT_DIR]
    sys.path.insert(0, str(scripts))
    for name in ("debug_app_process", "swift_pipeline_metrics", TARGET_MODULE_NAME):
        sys.modules.pop(name, None)
    source_path = scripts / "conductor.py"
    try:
        code = compile(source_path.read_bytes(), str(source_path), "exec", dont_inherit=True)
    except (OSError, SyntaxError) as exc:
        raise HarnessError(f"cannot load target conductor from {scripts}: {exc}") from exc
    module = types.ModuleType(TARGET_MODULE_NAME)
    module.__file__ = str(source_path)
    module.__cached__ = None  # type: ignore[attr-defined]
    sys.modules[TARGET_MODULE_NAME] = module  # dataclasses resolve their module here
    exec(code, module.__dict__)
    dependency = sys.modules.get("debug_app_process")
    dependency_file = Path(getattr(dependency, "__file__", "") or "").resolve()
    if dependency is None or dependency_file.parent != scripts:
        raise HarnessError(f"target dependency debug_app_process resolved outside {scripts}: {dependency_file}")
    if (scripts / "swift_pipeline_metrics.py").is_file() and "PIPELINE_METRICS" in module.__dict__:
        # A target that ships the timing helper must actually load it from itself;
        # a silent fallback would measure timing-disabled code.
        helper = module.__dict__["PIPELINE_METRICS"]
        helper_file = Path(getattr(helper, "__file__", "") or "").resolve()
        if helper is None or helper_file != scripts / "swift_pipeline_metrics.py":
            raise HarnessError(f"target timing helper did not load from {scripts}: {helper_file if helper else None}")
    return module


RUNNER_DIGEST_PROBE = (
    "import json, runpy, sys; sys.path.insert(0, sys.argv[1]); "
    "g = runpy.run_path(sys.argv[2], run_name='rpce_runner_digest_probe'); "
    "print(json.dumps(g.get('CONDUCTOR_DIGEST')))"
)


def loaded_conductor_digests(staged: Path) -> Dict[str, Any]:
    """Informational ``conductorDigest`` as each process role computes it (plan Step 2).

    ``daemon`` is the value in a harness worker, which loads the target the way the
    daemon-side workloads run it; ``runner`` is the value in a fresh interpreter that
    executes ``Scripts/conductor.py`` from its own directory, as job runners and the
    launcher do. Pre-Step-2 conductors define no digest (``None``). Never gated: the
    harness's own byte digest (``conductorDigest``) remains the arm identity.
    """
    staged = staged.resolve()
    scripts = staged / "Scripts"
    result: Dict[str, Any] = {"informational": True}
    probes = {
        "daemon": [sys.executable, str(Path(__file__).resolve()), "__loaded_digest", str(staged)],
        "runner": [sys.executable, "-c", RUNNER_DIGEST_PROBE, str(scripts), str(scripts / "conductor.py")],
    }
    for role, argv in probes.items():
        try:
            completed = subprocess.run(argv, capture_output=True, text=True, timeout=120, cwd=str(staged))
            if completed.returncode != 0:
                raise HarnessError(f"exit {completed.returncode}: {completed.stderr.strip()[-200:]}")
            result[role] = json.loads(completed.stdout.strip().splitlines()[-1])
        except (HarnessError, OSError, subprocess.SubprocessError, ValueError, IndexError) as exc:
            result[role] = None
            result[f"{role}Error"] = str(exc)[:300]
    return result


def loaded_digest_main(root: str) -> int:
    module = load_target_module(Path(root))
    print(json.dumps(module.__dict__.get("CONDUCTOR_DIGEST")))
    return 0


def target_paths(mod: Any, root: Path, repo_root: Optional[Path] = None) -> Any:
    jobs_dir = root / "jobs"
    jobs_dir.mkdir(parents=True, exist_ok=True)
    return mod.Paths(
        repo_root=repo_root or root,
        repo_hash="conductor-benchmark",
        state_dir=root,
        socket_path=root / "conductor.sock",
        pid_path=root / "conductor.pid",
        lock_path=root / "conductor.lock",
        jobs_dir=jobs_dir,
        daemon_log_path=root / "daemon.log",
        daemon_meta_path=root / "daemon.json",
        running_processes_path=root / "running.json",
    )


def isolate_machine_locks(mod: Any, lock_dir: Path) -> None:
    """Point the target's machine-wide slot locks at a private directory.

    The harness never holds or contends for this machine's real heavy/XCTest
    slots; only lock placement changes, never the measured validation work.
    """
    lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    mod.machine_lock_dir = lambda: lock_dir


def drain_job_timing(state: Any) -> None:
    """Wait for a timing target's post-result persistence before leaving the state dir.

    Targets that persist per-job timing after publishing the result expose a
    private drain; older targets do not, and nothing changes for them. Called
    outside every measured region.
    """
    drain = getattr(state, "_await_job_telemetry", None)
    if callable(drain) and not drain(30.0):
        raise HarnessError("target job timing did not finish persisting within 30 s")


def make_job(mod: Any, paths: Any, ticket: str, operation: str, args: Dict[str, Any]) -> Any:
    return mod.Job(
        ticket=ticket,
        request_key=None,
        fingerprint="conductor-benchmark",
        operation=operation,
        args=args,
        lanes=["build"],
        timeout=None,
        verbose=False,
        env={},
        created_at=mod.now(),
        log_path=paths.jobs_dir / f"{ticket}.log",
        state="running",
    )


def wait_for_condition_waiters(condition: Any, count: int, timeout: float = 10.0) -> None:
    if count == 0:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        waiters = getattr(condition, "_waiters", None)
        if waiters is None:
            raise HarnessError("threading.Condition no longer exposes _waiters; cannot prove waiters are blocked")
        if len(waiters) >= count:
            return
        time.sleep(0.001)
    raise HarnessError(f"only {len(condition._waiters)} of {count} job_wait clients blocked")


# ---------------------------------------------------------------------------
# Worker adapters (run inside a fresh worker process)


def adapter_output(mod: Any, spec: Dict[str, Any]) -> Dict[str, Any]:
    fixture = Path(spec["fixturePath"])
    raw = fixture.read_bytes()
    metrics: Dict[str, float] = {}
    equivalence: Dict[str, Any] = {}
    info: Dict[str, Any] = {}
    for transport, waiters in OUTPUT_VARIANTS:
        result = _run_output_variant(mod, spec, fixture, raw, transport, waiters)
        key = f"output.{transport}.w{waiters}"
        metrics[f"{key}.wall_ms"] = result["wall_ms"]
        metrics[f"{key}.cpu_ms"] = result["cpu_ms"]
        equivalence[f"{key}.tail_sha256"] = result["tail_evidence"]
        equivalence[f"{key}.progress"] = result["progress"]
        info[key] = {
            "bytesRead": result["bytes_read"],
            "chunks": result["chunks"],
            "ttyRetriedCR": result["tty_retried_cr"],
            "rawTailSha256": result["tail_sha256"],
            "watchdogThreads": result["watchdog_threads"],
        }
    equivalence[PTY_FIDELITY_KEY], info["output.pty.fidelity"] = run_pty_fidelity(mod, spec)
    return {"metrics": metrics, "equivalence": equivalence, "info": info}


def run_pty_fidelity(mod: Any, spec: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """Exact visible-tail evidence for a PTY job (untimed; never a performance metric).

    The deterministic fidelity fixture runs through the same real PTY job path as
    the timed variants. Delivery must be exact (no tty-retried CR), so the digest of
    the complete tail entry list -- content and boundaries -- is arm-comparable
    without normalization. The 512-byte suffix of the timed variants stays the
    transport-noise-tolerant evidence; this is the full-fidelity check.
    """
    fixture = Path(spec["fidelityFixturePath"])
    raw = fixture.read_bytes()
    result = _run_output_variant(mod, spec, fixture, raw, "pty", 0)
    if result["tty_retried_cr"] or result["bytes_read"] != len(onlcr(raw)):
        raise HarnessError(
            f"PTY fidelity delivery was not exact ({result['tty_retried_cr']} retried CRs, {result['bytes_read']} bytes)"
        )
    return result["tail_sha256"], {"bytesRead": result["bytes_read"], "tailEntries": result["tail_entries"]}


def _run_output_variant(
    mod: Any, spec: Dict[str, Any], fixture: Path, raw: bytes, transport_kind: str, waiters: int
) -> Dict[str, Any]:
    with tempfile.TemporaryDirectory(dir=spec["scratchDir"]) as tmp:
        paths = target_paths(mod, Path(tmp))
        state = mod.DaemonState(paths)
        if transport_kind == "pty":
            # A real watchdog-enabled test job; the explicit active-method budget keeps
            # ledger I/O out of this workload (the mem workload measures the ledger).
            job = make_job(mod, paths, "bench-output", "test", {"filter": "BenchProbe", "xctestStallSeconds": 600.0})
        else:
            job = make_job(mod, paths, "bench-output", "build", {})
        state.jobs[job.ticket] = job
        transport = state._create_process_output_transport(job)
        if transport.kind != transport_kind:
            raise HarnessError(f"target chose {transport.kind} transport for the {transport_kind} variant")
        if transport_kind == "pty":
            verify_pty_output_mode(transport.slave_fd)
        job.progress_transport = transport.kind
        wait_results: List[Dict[str, Any]] = []

        def wait_client() -> None:
            wait_results.append(state.job_wait(job.ticket, None, None))

        threads = [threading.Thread(target=wait_client, daemon=True) for _ in range(waiters)]
        for thread in threads:
            thread.start()
        wait_for_condition_waiters(state.condition, waiters)
        chunk_counter = {"count": 0}
        received = bytearray()
        original_read_chunk = transport.read_chunk

        def counting_read_chunk(process: Any) -> bytes:
            chunk = original_read_chunk(process)
            if chunk:
                chunk_counter["count"] += 1
                received.extend(chunk)
            return chunk

        transport.read_chunk = counting_read_chunk
        watchdog: Optional[threading.Thread] = None
        if transport_kind == "pty" and not state._xctest_watchdog_enabled(job):
            raise HarnessError("target did not enable the XCTest watchdog for the PTY variant")
        try:
            with job.log_path.open("ab") as log_file:
                wall_start = time.perf_counter()
                cpu_start = time.process_time()
                process = subprocess.Popen(
                    ["/bin/cat", str(fixture)],
                    stdin=subprocess.DEVNULL,
                    stdout=transport.popen_stdout,
                    stderr=transport.popen_stderr,
                    start_new_session=True,
                )
                transport.attach_process(process)
                reader = threading.Thread(
                    target=state._read_process_output,
                    args=(job.ticket, process, log_file, transport),
                    daemon=True,
                )
                reader.start()
                if transport_kind == "pty":
                    # Production starts the real stall watchdog right after the reader
                    # for every watchdog-enabled (PTY) job; it waits on the same condition.
                    watchdog = threading.Thread(target=state._monitor_xctest_stall, args=(job.ticket,), daemon=True)
                    watchdog.start()
                process.wait(timeout=300)
                reader.join(timeout=300)
                wall_ms = (time.perf_counter() - wall_start) * 1000.0
                cpu_ms = (time.process_time() - cpu_start) * 1000.0
                if reader.is_alive():
                    raise HarnessError("output reader did not finish")
        finally:
            transport.close_all()
            with state.condition:
                job.xctest_process_finished = True
                state.condition.notify_all()
            if watchdog is not None:
                watchdog.join(timeout=30)
            with state.condition:
                job.output_summary = {"benchmark": "summary-not-computed"}
                job.state = "completed"
                state.condition.notify_all()
            for thread in threads:
                thread.join(timeout=30)
        if any(thread.is_alive() for thread in threads) or len(wait_results) != waiters:
            raise HarnessError("job_wait clients did not return after the job completed")
        if watchdog is not None and watchdog.is_alive():
            raise HarnessError("XCTest watchdog did not finish after the process finished")
        if job.xctest_watchdog_triggered:
            raise HarnessError("XCTest watchdog triggered during the output workload")
        if process.returncode != 0:
            raise HarnessError(f"fixture writer exited {process.returncode}")
        logged = job.log_path.read_bytes()
        if logged != bytes(received):
            raise HarnessError(
                f"{transport_kind}: log bytes ({len(logged)}) differ from transport bytes ({len(received)})"
            )
        retried = verify_transport_stream(transport_kind, raw, logged)
        tail_sha256 = canonical_json_digest(list(job.tail))
        return {
            "wall_ms": wall_ms,
            "cpu_ms": cpu_ms,
            "bytes_read": len(logged),
            "chunks": chunk_counter["count"],
            "tty_retried_cr": len(retried),
            "watchdog_threads": 0 if watchdog is None else 1,
            "tail_sha256": tail_sha256,
            "tail_entries": len(job.tail),
            "tail_evidence": tail_sha256 if transport_kind == "pipe" else pty_tail_evidence(job.tail, logged, retried),
            "progress": {
                "sequence": job.xctest_progress_sequence,
                "started": job.xctest_started_count,
                "lastTest": job.xctest_last_progress_test,
                "lastAction": job.xctest_last_progress_action,
            },
        }


def summary_modes(manifest: Dict[str, Any]) -> List[Tuple[str, str, int]]:
    return [(str(op), str(state), int(code)) for op, state, code in manifest["summary"]["modes"]]


def adapter_summary(mod: Any, spec: Dict[str, Any]) -> Dict[str, Any]:
    manifest = spec["manifest"]
    log_path = Path(spec["summaryLogPath"])
    metrics: Dict[str, float] = {}
    equivalence: Dict[str, Any] = {}
    total_cpu = 0.0
    for operation, state, exit_code in summary_modes(manifest):
        cpu_start = time.thread_time()
        wall_start = time.perf_counter()
        summary = mod.OutputSummarizer.summarize_file(operation, {}, state, exit_code, False, log_path)
        cpu_ms = (time.thread_time() - cpu_start) * 1000.0
        wall_ms = (time.perf_counter() - wall_start) * 1000.0
        key = f"summary.{operation}.{state}"
        metrics[f"{key}.cpu_ms"] = cpu_ms
        metrics[f"{key}.wall_ms"] = wall_ms
        equivalence[f"{key}.sha256"] = canonical_json_digest(summary)
        total_cpu += cpu_ms
    metrics["summary.fixture.total_cpu_ms"] = total_cpu
    golden = json.loads(SUMMARY_GOLDEN_PATH.read_text(encoding="utf-8"))["digests"]
    info: Dict[str, Any] = {
        "goldenMatch": {key: equivalence.get(key) == digest for key, digest in sorted(golden.items())}
    }
    logs_dir = spec.get("logsDir")
    if logs_dir:
        retained_cpu = 0.0
        per_log: Dict[str, str] = {}
        logs = sorted(Path(logs_dir).glob("*.log"))
        if not logs:
            raise HarnessError(f"--logs-dir {logs_dir} holds no *.log files")
        for log in logs:
            digests = []
            for operation, state, exit_code in summary_modes(manifest):
                cpu_start = time.thread_time()
                summary = mod.OutputSummarizer.summarize_file(operation, {}, state, exit_code, False, log)
                retained_cpu += (time.thread_time() - cpu_start) * 1000.0
                digests.append(canonical_json_digest(summary))
            per_log[log.name] = canonical_json_digest(digests)
        metrics["summary.retained.total_cpu_ms"] = retained_cpu
        equivalence["summary.retained.sha256"] = canonical_json_digest(per_log)
        info["retainedLogs"] = per_log
    return {"metrics": metrics, "equivalence": equivalence, "info": info}


def first_ledger_case(ledger_root: Path) -> Tuple[str, str]:
    import csv

    path = ledger_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
    with path.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            suite = (row.get("suite") or "").strip()
            method = (row.get("method") or "").strip()
            runtime = (row.get("runtime_seconds") or "").strip()
            if suite and method and runtime:
                return suite, method
    raise HarnessError(f"no ledger row with a runtime in {path}")


def _retained_jobs_mib(
    mod: Any, scratch: str, ledger_root: Path, count_points: Sequence[int], text: str, tag: str
) -> Dict[int, float]:
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        paths = target_paths(mod, Path(tmp), repo_root=ledger_root)
        state = mod.DaemonState(paths)
        results: Dict[int, float] = {}
        gc.collect()
        tracemalloc.start()
        try:
            base = tracemalloc.get_traced_memory()[0]
            for index in range(max(count_points)):
                job = make_job(mod, paths, f"bench-{tag}-{index:04d}", "test", {"filter": "BenchProbe"})
                with state.condition:
                    state.jobs[job.ticket] = job
                    state._record_xctest_progress_locked(job, text)
                    job.state = "completed"
                if index + 1 in count_points:
                    gc.collect()
                    results[index + 1] = (tracemalloc.get_traced_memory()[0] - base) / 2**20
        finally:
            tracemalloc.stop()
        loaded = [job.xctest_method_runtimes for job in state.jobs.values()]
        if tag == "ledger" and not all(loaded):
            raise HarnessError("ledger workload jobs did not load the XCTest runtime ledger")
        del state
        return results


def adapter_mem(mod: Any, spec: Dict[str, Any]) -> Dict[str, Any]:
    manifest = spec["manifest"]["mem"]
    full = bool(spec.get("full"))
    ledger_root = Path(spec["ledgerRoot"])
    suite, method = first_ledger_case(ledger_root)
    started = f"Test Case '-[{suite} {method}]' started.\n"
    control = "Compiling RepoPrompt File.swift\n"
    points = list(manifest["ledgerJobsFull" if full else "ledgerJobs"])
    metrics: Dict[str, float] = {}
    info: Dict[str, Any] = {"ledgerCase": f"{suite}/{method}"}
    control_mib = _retained_jobs_mib(mod, spec["scratchDir"], ledger_root, points, control, "control")
    ledger_mib = _retained_jobs_mib(mod, spec["scratchDir"], ledger_root, points, started, "ledger")
    for point in points:
        metrics[f"mem.ledger_retained_n{point}_mib"] = ledger_mib[point] - control_mib[point]
        info[f"jobsOnlyN{point}Mib"] = control_mib[point]
    # Per-job ledger load wall time, measured without tracemalloc.
    with tempfile.TemporaryDirectory(dir=spec["scratchDir"]) as tmp:
        paths = target_paths(mod, Path(tmp), repo_root=ledger_root)
        state = mod.DaemonState(paths)
        load_times = []
        for index in range(5):
            job = make_job(mod, paths, f"bench-load-{index}", "test", {"filter": "BenchProbe"})
            with state.condition:
                state.jobs[job.ticket] = job
                start = time.perf_counter()
                state._record_xctest_progress_locked(job, started)
                load_times.append((time.perf_counter() - start) * 1000.0)
            info["ledgerEntries"] = len(job.xctest_method_runtimes or {})
        metrics["mem.ledger_load_ms"] = statistics.median(load_times)
    equivalence: Dict[str, Any] = {}
    seen_points = list(manifest["seenLinesFull" if full else "seenLines"])
    seen_mib: Dict[int, float] = {}
    for count in seen_points:
        gc.collect()
        tracemalloc.start()
        try:
            base = tracemalloc.get_traced_memory()[0]
            builder = mod.SummarySectionBuilder("Warnings", 25)
            for index in range(count):
                builder.add(f"/path/to/File{index}.swift:{index}:1: warning: something unique number {index}")
            gc.collect()
            seen_mib[count] = (tracemalloc.get_traced_memory()[0] - base) / 2**20
        finally:
            tracemalloc.stop()
        metrics[f"mem.seen_{count}_mib"] = seen_mib[count]
        equivalence[f"mem.seen_{count}.payload_sha256"] = canonical_json_digest(builder.payload())
        del builder
    if 100_000 in seen_mib and 1_000_000 in seen_mib:
        metrics["mem.seen_growth_100k_1m_mib"] = seen_mib[1_000_000] - seen_mib[100_000]
    return {"metrics": metrics, "equivalence": equivalence, "info": info}


class _HashCounter:
    """Delegating ``hashlib`` shim that counts bytes hashed per origin."""

    def __init__(self, real: Any, tracker: "_CallTracker") -> None:
        self._real = real
        self._tracker = tracker

    def __getattr__(self, name: str) -> Any:
        return getattr(self._real, name)

    def sha256(self, *args: Any, **kwargs: Any) -> Any:
        real = self._real.sha256(*args, **kwargs)
        tracker = self._tracker

        class Counted:
            def update(self, data: Any) -> None:
                tracker.add_bytes(len(data))
                real.update(data)

            def __getattr__(self, name: str) -> Any:
                return getattr(real, name)

        if args:
            tracker.add_bytes(len(args[0]))
        return Counted()


class _CallTracker:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.local = threading.local()
        self.calls: Dict[str, int] = {}
        self.bytes: Dict[str, int] = {}
        self.top_level_seconds = 0.0
        self.durations: Dict[str, List[float]] = {}

    def stack(self) -> List[str]:
        if not hasattr(self.local, "stack"):
            self.local.stack = []
        return self.local.stack

    def add_bytes(self, count: int) -> None:
        stack = self.stack()
        origin = stack[-1] if stack else "untracked"
        with self.lock:
            self.bytes[origin] = self.bytes.get(origin, 0) + count

    def wrap(self, name: str, function: Callable[..., Any]) -> Callable[..., Any]:
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            stack = self.stack()
            stack.append(name)
            start = time.perf_counter()
            try:
                return function(*args, **kwargs)
            finally:
                elapsed = time.perf_counter() - start
                stack.pop()
                with self.lock:
                    self.calls[name] = self.calls.get(name, 0) + 1
                    self.durations.setdefault(name, []).append(elapsed)
                    if not stack:
                        self.top_level_seconds += elapsed

        return wrapper


TRACKED_ARTIFACT_FUNCTIONS = (
    "evaluate_test_artifact",
    "verify_test_artifact_fingerprint",
    "test_artifact_fingerprint",
    "source_snapshot",
    "artifact_toolchain_snapshot",
)


def install_artifact_tracker(mod: Any) -> _CallTracker:
    tracker = _CallTracker()
    for name in TRACKED_ARTIFACT_FUNCTIONS:
        setattr(mod, name, tracker.wrap(name, getattr(mod, name)))
    mod.hashlib = _HashCounter(mod.hashlib, tracker)
    return tracker


def mint_root_ticket(mod: Any, repo_root: Path, jobs_dir: Path, env: Dict[str, str]) -> None:
    paths = target_paths(mod, jobs_dir.parent, repo_root=repo_root)
    job = make_job(mod, paths, "bench-ticket-mint", "test", {})
    payload = mod.build_ticket_payload(repo_root, job, env)
    if payload is None:
        raise HarnessError("could not mint fixture build ticket (source snapshot unavailable)")
    mod.write_build_ticket(jobs_dir / "build-ticket-root.json", payload)


def adapter_artifact(mod: Any, spec: Dict[str, Any]) -> Dict[str, Any]:
    repo_root = Path(spec["artifactRepo"])
    with tempfile.TemporaryDirectory(dir=spec["scratchDir"]) as tmp:
        state_root = Path(tmp)
        paths = target_paths(mod, state_root, repo_root=repo_root)
        isolate_machine_locks(mod, state_root / "locks")
        client_env = mod.OperationRegistry.client_env_snapshot()
        effective_env = mod.OperationRegistry(repo_root, paths.jobs_dir).request_environment(
            False, {"env": client_env}
        )
        mint_root_ticket(mod, repo_root, paths.jobs_dir, effective_env)
        state = mod.DaemonState(paths)
        tracker = install_artifact_tracker(mod)
        start = time.perf_counter()
        args: Dict[str, Any] = {"filter": spec["artifactFilter"]}
        args.update(mod.evaluate_test_artifact(paths.repo_root, paths.jobs_dir, effective_env))
        request = {
            "type": "enqueue",
            "operation": "test-artifact",
            "args": args,
            "requestKey": None,
            "timeout": 600,
            "verbose": False,
            "env": client_env,
        }
        enqueued = state.enqueue(request)
        final = state.job_wait(enqueued["ticket"], None, 600)
        wall_ms = (time.perf_counter() - start) * 1000.0
        drain_job_timing(state)
        if final.get("state") != "completed" or final.get("exitCode") != 0:
            raise HarnessError(f"fixture test-artifact job did not complete: {final.get('state')} {final.get('error')}")
        if final.get("artifactScope") != "current":
            raise HarnessError(f"fixture artifact scope was {final.get('artifactScope')!r}, expected 'current'")
    fingerprint_durations = tracker.durations.get("test_artifact_fingerprint", [])
    fingerprint_bytes = tracker.bytes.get("test_artifact_fingerprint", 0)
    metrics = {
        "artifact.run_wall_ms": wall_ms,
        "artifact.integrity_ms": tracker.top_level_seconds * 1000.0,
        "artifact.fingerprint_ms": statistics.median(fingerprint_durations) * 1000.0 if fingerprint_durations else 0.0,
        "artifact.fingerprint_calls": float(tracker.calls.get("test_artifact_fingerprint", 0)),
        "artifact.evaluate_calls": float(tracker.calls.get("evaluate_test_artifact", 0)),
        "artifact.toolchain_calls": float(tracker.calls.get("artifact_toolchain_snapshot", 0)),
        "artifact.source_snapshot_calls": float(tracker.calls.get("source_snapshot", 0)),
        "artifact.bytes_hashed": float(fingerprint_bytes),
    }
    info = {"calls": tracker.calls, "bytesByOrigin": tracker.bytes, "fixtureBytes": spec["artifactFixtureBytes"]}
    return {"metrics": metrics, "equivalence": {}, "info": info}


def read_footprint_bytes(pid: int) -> int:
    result = subprocess.run(
        ["/usr/bin/footprint", "-f", "bytes", "--noCategories", str(pid)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("phys_footprint:"):
            return int(stripped.split()[1])
    raise HarnessError(f"footprint produced no phys_footprint for pid {pid}: {result.stderr.strip()[:200]}")


def read_rss_bytes(pid: int) -> int:
    result = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    try:
        return int(result.stdout.strip()) * 1024
    except ValueError as exc:
        raise HarnessError(f"ps reported no RSS for pid {pid}") from exc


def adapter_rss_worker(mod: Any, spec: Dict[str, Any]) -> Dict[str, Any]:
    """Interactive worker: the orchestrator samples this process's footprint."""
    repo_root = Path(spec["rssRepo"])
    with tempfile.TemporaryDirectory(dir=spec["scratchDir"]) as tmp:
        state_root = Path(tmp)
        paths = target_paths(mod, state_root, repo_root=repo_root)
        isolate_machine_locks(mod, state_root / "locks")
        state = mod.DaemonState(paths)
        client_env = mod.OperationRegistry.client_env_snapshot()
        gc.collect()
        _handshake("idle")
        states = []
        for _index in range(int(spec["rssJobs"])):
            enqueued = state.enqueue(
                {
                    "type": "enqueue",
                    "operation": "test",
                    "args": {"filter": spec["rssFilter"]},
                    "requestKey": None,
                    "timeout": 600,
                    "verbose": False,
                    "env": client_env,
                }
            )
            final = state.job_wait(enqueued["ticket"], None, 600)
            states.append((final.get("state"), final.get("exitCode")))
        drain_job_timing(state)
        bad = [entry for entry in states if entry != ("completed", 0)]
        if bad:
            raise HarnessError(f"{len(bad)} retained rss jobs did not complete: {bad[:3]}")
        loaded = sum(1 for job in state.jobs.values() if job.xctest_method_runtimes)
        if loaded != len(states):
            raise HarnessError(f"only {loaded} of {len(states)} rss jobs loaded the runtime ledger")
        gc.collect()
        _handshake("retained")
        return {"metrics": {}, "equivalence": {}, "info": {"retainedJobs": len(state.jobs), "ledgerLoadedJobs": loaded}}


def _handshake(stage: str) -> None:
    sys.stdout.write(json.dumps({"stage": stage, "pid": os.getpid()}) + "\n")
    sys.stdout.flush()
    reply = sys.stdin.readline().strip()
    if reply != "continue":
        raise HarnessError(f"rss orchestrator aborted at {stage}: {reply!r}")


WORKER_ADAPTERS: Dict[str, Callable[[Any, Dict[str, Any]], Dict[str, Any]]] = {
    "output": adapter_output,
    "summary": adapter_summary,
    "mem": adapter_mem,
    "artifact": adapter_artifact,
    "rss": adapter_rss_worker,
}


def worker_main(spec_json: str) -> int:
    spec = json.loads(spec_json)
    try:
        module = load_target_module(Path(spec["targetRoot"]))
        result = WORKER_ADAPTERS[spec["workload"]](module, spec)
        result["ok"] = True
        payload = json.dumps(result, sort_keys=True, allow_nan=False)
    except Exception as exc:  # report every failure (including non-finite values) as harness evidence
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        payload = json.dumps(result, sort_keys=True)
    sys.stdout.write("RESULT " + payload + "\n")
    sys.stdout.flush()
    return 0 if result["ok"] else EXIT_HARNESS_FAILURE


def parse_worker_result(stdout: str) -> Dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        if line.startswith("RESULT "):
            return json.loads(line[len("RESULT "):])
    raise HarnessError(f"worker produced no RESULT line: {stdout[-400:]!r}")


# ---------------------------------------------------------------------------
# Orchestrator


def default_state_dir(repo_root: Path = REPO_ROOT) -> Path:
    override = os.environ.get("REPOPROMPT_DEV_DAEMON_STATE_DIR")
    if override:
        return Path(override).expanduser().resolve()
    repo_hash = hashlib.sha256(str(repo_root.resolve()).encode("utf-8")).hexdigest()
    return Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "Conductor" / repo_hash


def sysctl(name: str) -> Optional[str]:
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        result = subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            return result.stdout.strip()
    return None


def host_metadata() -> Dict[str, Any]:
    return {
        "machine": platform.machine(),
        "osVersion": platform.mac_ver()[0] or platform.release(),
        "cpu": sysctl("machdep.cpu.brand_string"),
        "ncpu": os.cpu_count(),
        "memsize": sysctl("hw.memsize"),
    }


def python_metadata() -> Dict[str, Any]:
    return {
        "version": platform.python_version(),
        "implementation": platform.python_implementation(),
        "executable": sys.executable,
    }


def swift_version() -> Optional[str]:
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        result = subprocess.run(["swift", "--version"], capture_output=True, text=True, timeout=60)
        if result.returncode == 0 and result.stdout:
            return result.stdout.splitlines()[0].strip()
    return None


def machine_slot_contention() -> Dict[str, Any]:
    """Probe this machine's real heavy/XCTest slot locks without creating them."""
    lock_dir = Path("/tmp") / f"repoprompt-ce-dev-locks-{os.getuid()}"
    held: List[str] = []
    probed = 0
    for path in sorted(lock_dir.glob("global-*.lock")) if lock_dir.is_dir() else []:
        probed += 1
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            held.append(path.name)
        else:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
    return {"loadavg": list(os.getloadavg()), "slotsProbed": probed, "slotsHeld": held}


_HOST_CPU: Dict[str, Any] = {}


def host_cpu_counters() -> Optional[Dict[str, Any]]:
    """Cumulative host CPU ticks and this harness's own CPU, for foreign-CPU windows.

    ``busyTicks``/``totalTicks`` are the Mach host CPU load counters (user+system+nice
    and all states, summed over every logical CPU). ``ownCpuSeconds`` is this process
    plus every reaped descendant (workers, CLI runs, fixture writers), so the
    difference over a window is CPU work this capture did not do. Returns ``None``
    when the counters are unavailable; compare then cannot rule out contamination.
    """
    import ctypes
    import resource

    try:
        if "libc" not in _HOST_CPU:
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            libc.mach_host_self.restype = ctypes.c_uint
            _HOST_CPU["libc"], _HOST_CPU["host"] = libc, libc.mach_host_self()
        info = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)  # HOST_CPU_LOAD_INFO_COUNT: user, system, idle, nice
        if _HOST_CPU["libc"].host_statistics(_HOST_CPU["host"], 3, info, ctypes.byref(count)) != 0:
            return None
    except (OSError, AttributeError):
        return None
    own = resource.getrusage(resource.RUSAGE_SELF)
    children = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {
        "at": time.time(),
        "busyTicks": int(info[0]) + int(info[1]) + int(info[3]),
        "totalTicks": int(info[0]) + int(info[1]) + int(info[2]) + int(info[3]),
        "ownCpuSeconds": own.ru_utime + own.ru_stime + children.ru_utime + children.ru_stime,
    }


def foreign_cores(start: Dict[str, Any], end: Dict[str, Any], ncpu: int) -> Optional[float]:
    """Average logical CPUs busy with work outside this capture between two counter readings."""
    wall = float(end["at"]) - float(start["at"])
    total = int(end["totalTicks"]) - int(start["totalTicks"])
    if wall <= 0 or total <= 0:
        return None
    busy = ncpu * (int(end["busyTicks"]) - int(start["busyTicks"])) / total
    return busy - (float(end["ownCpuSeconds"]) - float(start["ownCpuSeconds"])) / wall


def run_worker(spec: Dict[str, Any], timeout: float = 1800.0) -> Dict[str, Any]:
    argv = [sys.executable, str(Path(__file__).resolve()), "__worker", json.dumps(spec)]
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"worker timed out after {timeout}s"}
    except OSError as exc:
        return {"ok": False, "error": f"worker could not start: {exc}"}
    try:
        result = parse_worker_result(completed.stdout)
    except (HarnessError, ValueError) as exc:
        return {"ok": False, "error": f"{exc}; stderr={completed.stderr[-400:]!r}"}
    if completed.returncode != 0 and result.get("ok"):
        return {"ok": False, "error": f"worker exited {completed.returncode}"}
    return result


def run_rss_sample(spec: Dict[str, Any], timeout: float = 1800.0) -> Dict[str, Any]:
    argv = [sys.executable, str(Path(__file__).resolve()), "__worker", json.dumps(spec)]
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as exc:
        return {"ok": False, "error": f"rss worker could not start: {exc}"}
    footprints: Dict[str, int] = {}
    rss: Dict[str, int] = {}
    timer = threading.Timer(timeout, process.kill)
    timer.start()
    try:
        assert process.stdout is not None and process.stdin is not None
        for expected in ("idle", "retained"):
            line = process.stdout.readline()
            if not line.startswith("{"):
                rest = process.stdout.read()
                return parse_worker_result(line + rest) if "RESULT " in line + rest else {
                    "ok": False,
                    "error": f"rss worker ended before {expected}: {(line + rest)[-400:]!r}",
                }
            stage = json.loads(line)
            if stage.get("stage") != expected:
                raise HarnessError(f"rss worker reported {stage} before {expected}")
            footprints[expected] = read_footprint_bytes(process.pid)
            rss[expected] = read_rss_bytes(process.pid)
            process.stdin.write("continue\n")
            process.stdin.flush()
        stdout, stderr = process.communicate(timeout=timeout)
        result = parse_worker_result(stdout)
    except (HarnessError, ValueError, OSError, subprocess.SubprocessError) as exc:
        process.kill()
        with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
            process.communicate(timeout=60)
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    finally:
        timer.cancel()
    if not result.get("ok"):
        return result
    mib = 2**20
    result["metrics"] = {
        "rss.footprint_idle_mib": footprints["idle"] / mib,
        "rss.footprint_retained_mib": footprints["retained"] / mib,
        "rss.footprint_delta_mib": (footprints["retained"] - footprints["idle"]) / mib,
        "rss.rss_retained_mib": rss["retained"] / mib,
        "rss.rss_delta_mib": (rss["retained"] - rss["idle"]) / mib,
    }
    return result


def run_cli_sample(target_root: Path, scratch: Path) -> Dict[str, Any]:
    # A private, daemon-free state dir: every arm measures the same launcher +
    # "daemon not running" status path, independent of real daemons.
    env = dict(os.environ)
    env["REPOPROMPT_DEV_DAEMON_STATE_DIR"] = str(scratch / "cli-state")
    env["REPOPROMPT_DEV_DAEMON_SOCKET"] = str(scratch / "cli-state" / "conductor.sock")
    launcher = str(target_root / "conductor")
    metrics: Dict[str, float] = {}
    for name, argv, expected_exit in (("help", [launcher, "--help"], 0), ("status", [launcher, "status"], 1)):
        start = time.perf_counter()
        try:
            completed = subprocess.run(argv, cwd=str(target_root), env=env, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"ok": False, "error": f"cli {name} failed to run: {type(exc).__name__}: {exc}"}
        elapsed = (time.perf_counter() - start) * 1000.0
        if completed.returncode != expected_exit:
            return {"ok": False, "error": f"cli {name} exited {completed.returncode}: {completed.stderr[-300:]!r}"}
        if name == "status" and "conductor daemon not running" not in completed.stdout:
            return {"ok": False, "error": "cli status did not take the daemon-free path"}
        metrics[f"cli.{name}_ms"] = elapsed
    return {"ok": True, "metrics": metrics, "equivalence": {}, "info": {}}


def build_fixture_repo(root: Path, canonical_swift_body: str, artifact_sizes: Optional[Tuple[int, int]], ledger: Optional[Path]) -> None:
    """A committed scratch git repo with a fake ``canonical_swift.sh`` and test bundle."""
    root.mkdir(parents=True, exist_ok=True)
    scripts = root / "Scripts"
    scripts.mkdir(exist_ok=True)
    canonical = scripts / "canonical_swift.sh"
    canonical.write_text(canonical_swift_body, encoding="utf-8")
    canonical.chmod(0o755)
    (root / ".gitignore").write_text(".build/\n", encoding="utf-8")
    if ledger is not None:
        (scripts / "Fixtures").mkdir(exist_ok=True)
        shutil.copyfile(ledger, scripts / "Fixtures" / "test-suite-contract-ledger.tsv")
    git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=bench", "-c", "user.email=bench@example.invalid"]
    for argv in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "conductor benchmark fixture"]):
        subprocess.run(git + argv, cwd=str(root), check=True, capture_output=True)
    if artifact_sizes is None:
        return
    arch = platform.machine()
    bundle = root / ".build" / f"{arch}-apple-macosx" / "debug" / "RepoPromptCEPackageTests.xctest"
    macos = bundle / "Contents" / "MacOS"
    dwarf = macos / "RepoPromptCEPackageTests.dSYM" / "Contents" / "Resources" / "DWARF"
    dwarf.mkdir(parents=True, exist_ok=True)
    (bundle / "Contents" / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
    write_deterministic_blob(macos / "RepoPromptCEPackageTests", artifact_sizes[0], seed=1)
    write_deterministic_blob(dwarf / "RepoPromptCEPackageTests", artifact_sizes[1], seed=2)


def write_deterministic_blob(path: Path, size: int, seed: int) -> None:
    rng = SplitMix64(seed)
    block = b"".join(rng.next().to_bytes(8, "little") for _ in range(128 * 1024))  # 1 MiB
    with path.open("wb") as handle:
        written = 0
        index = 0
        while written < size:
            piece = index.to_bytes(8, "little") + block[8:]
            piece = piece[: size - written]
            handle.write(piece)
            written += len(piece)
            index += 1


ARTIFACT_CANONICAL_SWIFT = """#!/bin/sh
# conductor-benchmark fixture: stands in for a successful `swift test --skip-build`.
echo "Test Case '-[RepoPromptTests.BenchProbeTests testProbe]' started."
echo "Test Case '-[RepoPromptTests.BenchProbeTests testProbe]' passed (0.001 seconds)."
echo "Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
exit 0
"""


def rss_canonical_swift(suite: str, method: str, lines: int) -> str:
    return f"""#!/bin/sh
# conductor-benchmark fixture: a retained successful test job with build output.
i=0
while [ $i -lt {lines} ]; do
  echo "[$i/{lines}] Compiling RepoPrompt File$i.swift"
  i=$((i+1))
done
echo "Build complete! (1.00s)"
echo "Test Case '-[{suite} {method}]' started."
echo "Test Case '-[{suite} {method}]' passed (0.001 seconds)."
echo "Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
exit 0
"""


SAMPLE_CLASS = {"output": "fast", "summary": "fast", "cli": "fast", "mem": "memory", "artifact": "artifact", "rss": "memory"}
PRIMERS = {"output": 1, "summary": 1, "cli": 2, "mem": 0, "artifact": 1, "rss": 0}
ARTIFACT_METRICS = (
    "artifact.run_wall_ms",
    "artifact.integrity_ms",
    "artifact.fingerprint_ms",
    "artifact.fingerprint_calls",
    "artifact.evaluate_calls",
    "artifact.toolchain_calls",
    "artifact.source_snapshot_calls",
    "artifact.bytes_hashed",
)
RSS_METRICS = (
    "rss.footprint_idle_mib",
    "rss.footprint_retained_mib",
    "rss.footprint_delta_mib",
    "rss.rss_retained_mib",
    "rss.rss_delta_mib",
)


def workload_inventory(workload: str, manifest: Dict[str, Any], full: bool, retained_logs: bool) -> Dict[str, List[str]]:
    """Every metric and equivalence key a sample of ``workload`` must report."""
    metrics: List[str] = []
    equivalence: List[str] = []
    if workload == "output":
        for transport, waiters in OUTPUT_VARIANTS:
            key = f"output.{transport}.w{waiters}"
            metrics += [f"{key}.wall_ms", f"{key}.cpu_ms"]
            equivalence += [f"{key}.tail_sha256", f"{key}.progress"]
        equivalence.append(PTY_FIDELITY_KEY)
    elif workload == "summary":
        for operation, state, _code in summary_modes(manifest):
            key = f"summary.{operation}.{state}"
            metrics += [f"{key}.cpu_ms", f"{key}.wall_ms"]
            equivalence.append(f"{key}.sha256")
        metrics.append("summary.fixture.total_cpu_ms")
        if retained_logs:
            metrics.append("summary.retained.total_cpu_ms")
            equivalence.append("summary.retained.sha256")
    elif workload == "mem":
        mem = manifest["mem"]
        metrics += [f"mem.ledger_retained_n{point}_mib" for point in mem["ledgerJobsFull" if full else "ledgerJobs"]]
        metrics.append("mem.ledger_load_ms")
        seen = list(mem["seenLinesFull" if full else "seenLines"])
        metrics += [f"mem.seen_{count}_mib" for count in seen]
        equivalence += [f"mem.seen_{count}.payload_sha256" for count in seen]
        if 100_000 in seen and 1_000_000 in seen:
            metrics.append("mem.seen_growth_100k_1m_mib")
    elif workload == "cli":
        metrics += ["cli.help_ms", "cli.status_ms"]
    elif workload == "artifact":
        metrics += list(ARTIFACT_METRICS)
    elif workload == "rss":
        metrics += list(RSS_METRICS)
    else:
        raise HarnessError(f"unknown workload {workload!r}")
    return {"metrics": sorted(metrics), "equivalence": sorted(equivalence)}


def is_finite_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def sample_inventory_problem(result: Dict[str, Any], inventory: Dict[str, List[str]]) -> Optional[str]:
    """Why a successful sample result does not satisfy its workload inventory, if it does not."""
    metrics = result.get("metrics")
    equivalence = result.get("equivalence")
    if not isinstance(metrics, dict) or not isinstance(equivalence, dict):
        return "sample lacks metrics/equivalence objects"
    if sorted(metrics) != inventory["metrics"]:
        return f"sample metrics {sorted(metrics)} != required {inventory['metrics']}"
    if sorted(equivalence) != inventory["equivalence"]:
        return f"sample equivalence {sorted(equivalence)} != required {inventory['equivalence']}"
    bad = [name for name, value in metrics.items() if not is_finite_number(value)]
    if bad:
        return f"non-finite or non-numeric metrics {sorted(bad)}"
    return None


def validate_component(kind: str, value: str) -> str:
    if not SAFE_COMPONENT.fullmatch(value or ""):
        raise HarnessError(f"{kind} {value!r} must match {SAFE_COMPONENT.pattern} (a single safe path component)")
    return value


def parse_class_samples(value: Optional[str], manifest_samples: Dict[str, Any]) -> Dict[str, int]:
    """``fast=90,memory=10``: per-class sample counts, never below the manifest counts."""
    counts: Dict[str, int] = {}
    for item in (value or "").split(","):
        if not item:
            continue
        name, separator, text = item.partition("=")
        if not separator or name not in manifest_samples:
            raise HarnessError(f"--class-samples entry {item!r} must be CLASS=COUNT with CLASS in {sorted(manifest_samples)}")
        try:
            count = int(text)
        except ValueError as exc:
            raise HarnessError(f"--class-samples count {text!r} is not an integer") from exc
        if count < int(manifest_samples[name]):
            raise HarnessError(
                f"--class-samples {name}={count} is below the manifest count {manifest_samples[name]}; use --samples for smoke runs"
            )
        counts[name] = count
    return counts


def freeze_retained_logs(source: Path, destination: Path) -> Dict[str, Any]:
    """Copy ``source/*.log`` once into the capture scratch and fingerprint the copy."""
    logs = sorted(path for path in source.glob("*.log") if path.is_file())
    if not logs:
        raise HarnessError(f"--logs-dir {source} holds no *.log files")
    destination.mkdir(parents=True)
    files = []
    for log in logs:
        copied = destination / log.name
        shutil.copyfile(log, copied)
        files.append({"name": log.name, "bytes": copied.stat().st_size, "sha256": sha256_file(copied)})
    return {"source": str(source), "files": files, "digest": canonical_json_digest(files)}


def cli_python_metadata() -> Dict[str, Any]:
    """The interpreter the ``conductor`` launcher resolves (``python3`` on PATH)."""
    path = shutil.which("python3")
    version = None
    if path:
        with contextlib.suppress(OSError, subprocess.SubprocessError):
            completed = subprocess.run([path, "-c", "import sys; print(sys.version)"], capture_output=True, text=True, timeout=30)
            version = completed.stdout.strip() or None
    return {"path": path, "realpath": str(Path(path).resolve()) if path else None, "version": version}


def parse_targets(values: Sequence[str]) -> List[Tuple[str, Path]]:
    if not values:
        return [("current", REPO_ROOT)]
    arms: List[Tuple[str, Path]] = []
    for value in values:
        name, separator, root = value.partition("=")
        if not separator or not name or not root:
            raise HarnessError(f"--target must be NAME=ROOT, got {value!r}")
        validate_component("target arm name", name)
        if any(existing == name for existing, _ in arms):
            raise HarnessError(f"duplicate target arm {name!r}")
        arms.append((name, Path(root).expanduser().resolve()))
    if len(arms) > 2:
        raise HarnessError("at most two target arms per capture")
    return arms


def arm_order(arms: Sequence[Tuple[str, Path]], block: int) -> List[Tuple[str, Path]]:
    """Balanced ABBA: even blocks run A,B; odd blocks run B,A."""
    return list(arms) if block % 2 == 0 else list(reversed(arms))


def run_overrides(ns: argparse.Namespace, manifest: Dict[str, Any]) -> Dict[str, Any]:
    """Validate sampling/fixture overrides; smoke overrides make a capture ineligible for acceptance."""
    if ns.samples is not None and ns.samples <= 0:
        raise HarnessError("--samples must be a positive integer")
    if ns.samples is not None and ns.class_samples:
        raise HarnessError("--samples (smoke) and --class-samples are mutually exclusive")
    if ns.artifact_scale is not None and not (math.isfinite(ns.artifact_scale) and ns.artifact_scale > 0):
        raise HarnessError("--artifact-scale must be a positive finite number")
    if ns.rss_jobs is not None and ns.rss_jobs <= 0:
        raise HarnessError("--rss-jobs must be a positive integer")
    return {
        "samples": ns.samples,
        "classSamples": parse_class_samples(ns.class_samples, manifest["samples"]),
        "artifactScale": ns.artifact_scale,
        "rssJobs": ns.rss_jobs,
    }


def command_run(ns: argparse.Namespace) -> int:
    manifest = load_manifest()
    workloads = list(FULL_WORKLOADS if ns.full else FAST_WORKLOADS)
    if ns.workloads:
        workloads = [item for item in ns.workloads.split(",") if item]
        unknown = [item for item in workloads if item not in FULL_WORKLOADS]
        if unknown or not workloads or len(set(workloads)) != len(workloads):
            raise HarnessError(f"--workloads must be distinct names from {list(FULL_WORKLOADS)}, got {ns.workloads!r}")
    overrides = run_overrides(ns, manifest)
    arms = parse_targets(ns.target)
    if ns.capture_id:
        validate_component("--capture-id", ns.capture_id)
    digests_before = {name: target_digest(root) for name, root in arms}
    capture_id = ns.capture_id or (
        time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        + "-"
        + "-".join(f"{name}{digests_before[name]['conductorDigest'][:10]}" for name, _ in arms)
    )
    output_root = Path(ns.output_dir).expanduser().resolve() if ns.output_dir else default_state_dir() / "benchmarks" / "conductor"
    capture_dir = output_root / capture_id
    if capture_dir.resolve().parent != output_root.resolve():
        raise HarnessError(f"capture directory {capture_dir} escapes {output_root}")
    if capture_dir.exists():
        raise HarnessError(f"capture {capture_dir} already exists")
    capture_dir.mkdir(parents=True)
    scratch = Path(tempfile.mkdtemp(prefix=f"rpce-conductor-bench-{os.getpid()}-", dir="/tmp"))
    samples_config = {key: int(value) for key, value in manifest["samples"].items()}
    samples_config.update(overrides["classSamples"])
    if ns.samples is not None:
        samples_config = {key: ns.samples for key in samples_config}
    retained_logs = bool(ns.logs_dir)
    capture: Dict[str, Any] = {
        "schemaVersion": CAPTURE_SCHEMA_VERSION,
        "harnessVersion": HARNESS_VERSION,
        "captureId": capture_id,
        "state": "running",
        "complete": False,
        "label": ns.label,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "startedAtUnix": time.time(),
        "fixtureVersion": manifest["fixtureVersion"],
        "fixtureManifestSha256": sha256_file(MANIFEST_PATH),
        "manifest": manifest,
        "summaryGolden": json.loads(SUMMARY_GOLDEN_PATH.read_text(encoding="utf-8"))["digests"],
        "host": host_metadata(),
        "python": python_metadata(),
        "workloads": workloads,
        "full": bool(ns.full),
        "samplesConfig": samples_config,
        "overrides": overrides,
        "primers": {name: (PRIMERS[name] if ns.samples is None else min(PRIMERS[name], 1)) for name in workloads},
        "inventory": {name: workload_inventory(name, manifest, bool(ns.full), retained_logs) for name in workloads},
        "adapters": {name: ADAPTER_VERSIONS[name] for name in workloads},
        "arms": [{"name": name, **digests_before[name]} for name, _ in arms],
        "harnessDigest": harness_digest(),
        "targetLoading": "staged copy; conductor.py compiled from source per process (as __main__); dependency bytecode precompiled",
        "contentionStart": machine_slot_contention(),
        "samples": [],
        "errors": [],
    }
    started = time.perf_counter()
    finished_normally = False
    interrupted = False
    try:
        if "cli" in workloads:
            capture["cliPython"] = cli_python_metadata()
        fixture_bytes, fidelity_bytes = verified_fixtures(manifest)
        fixture_path = scratch / "output-fixture.log"
        fixture_path.write_bytes(fixture_bytes)
        fidelity_path = scratch / "pty-fidelity-fixture.log"
        fidelity_path.write_bytes(fidelity_bytes)
        summary_log = scratch / "summary-fixture.log"
        summary_log.write_bytes(onlcr(fixture_bytes))
        ledger = REPO_ROOT / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
        if any(item in workloads for item in ("mem", "rss")):
            capture["ledgerSha256"] = sha256_file(ledger)
        ledger_root = scratch / "ledger-root"
        (ledger_root / "Scripts" / "Fixtures").mkdir(parents=True)
        shutil.copyfile(ledger, ledger_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv")
        base_spec: Dict[str, Any] = {
            "manifest": manifest,
            "scratchDir": str(scratch),
            "fixturePath": str(fixture_path),
            "fidelityFixturePath": str(fidelity_path),
            "summaryLogPath": str(summary_log),
            "ledgerRoot": str(ledger_root),
            "full": bool(ns.full),
            "logsDir": None,
        }
        if retained_logs:
            corpus = freeze_retained_logs(Path(ns.logs_dir).expanduser().resolve(), scratch / "retained-logs")
            capture["retainedLogsCorpus"] = corpus
            base_spec["logsDir"] = str(scratch / "retained-logs")
        if "artifact" in workloads:
            sizes = (int(manifest["artifact"]["executableBytes"]), int(manifest["artifact"]["dsymBytes"]))
            if ns.artifact_scale is not None:
                sizes = (max(1, int(sizes[0] * ns.artifact_scale)), max(1, int(sizes[1] * ns.artifact_scale)))
            artifact_repo = scratch / "artifact-repo"
            build_fixture_repo(artifact_repo, ARTIFACT_CANONICAL_SWIFT, sizes, None)
            capture["artifactFixtureBytes"] = list(sizes)
            capture["swiftVersion"] = swift_version()
            base_spec.update(
                artifactRepo=str(artifact_repo),
                artifactFilter="BenchProbeTests",
                artifactFixtureBytes=list(sizes),
            )
        if "rss" in workloads:
            suite, method = first_ledger_case(ledger_root)
            rss_repo = scratch / "rss-repo"
            build_fixture_repo(
                rss_repo,
                rss_canonical_swift(suite, method, int(manifest["rss"]["outputLinesPerJob"])),
                (64 * 1024, 64 * 1024),
                ledger,
            )
            capture["swiftVersion"] = capture.get("swiftVersion") or swift_version()
            base_spec.update(
                rssRepo=str(rss_repo),
                rssJobs=int(ns.rss_jobs or manifest["rss"]["retainedJobs"]),
                rssFilter=suite.rsplit(".", 1)[-1],
            )
            capture["rssJobs"] = base_spec["rssJobs"]
        staged_roots = {
            name: stage_target(name, root, scratch / "targets", digests_before[name]) for name, root in arms
        }
        for entry in capture["arms"]:
            entry["loadedConductorDigest"] = loaded_conductor_digests(staged_roots[entry["name"]])
        for workload in workloads:
            count = int(samples_config[SAMPLE_CLASS[workload]])
            primers = int(capture["primers"][workload])
            inventory = capture["inventory"][workload]
            for block in range(-primers, count):
                for name, _root in arm_order(arms, block):
                    staged = staged_roots[name]
                    spec = dict(base_spec, workload=workload, targetRoot=str(staged))
                    machine = machine_slot_contention()
                    cpu_start = host_cpu_counters()
                    sample_started = time.time()
                    if workload == "cli":
                        result = run_cli_sample(staged, scratch)
                    elif workload == "rss":
                        result = run_rss_sample(spec)
                    else:
                        result = run_worker(spec)
                    if result.get("ok"):
                        problem = sample_inventory_problem(result, inventory)
                        if problem:
                            result = {"ok": False, "error": f"invalid sample evidence: {problem}"}
                    record = {
                        "workload": workload,
                        "arm": name,
                        "block": block,
                        "primer": block < 0,
                        "machine": machine,
                        "startedAtUnix": sample_started,
                        "finishedAtUnix": time.time(),
                        "hostCpu": {"start": cpu_start, "end": host_cpu_counters()},
                        **result,
                    }
                    capture["samples"].append(record)
                    if not result.get("ok"):
                        capture["errors"].append({"workload": workload, "arm": name, "block": block, "error": result.get("error")})
                        print(f"[{workload}] {name} block {block}: ERROR {result.get('error')}", file=sys.stderr)
                        if ns.fail_fast:
                            raise HarnessError(f"{workload} sample failed: {result.get('error')}")
                print(f"[{workload}] block {block + 1 if block >= 0 else 'primer'} / {count} done", file=sys.stderr)
        finished_normally = True
    except HarnessError as exc:
        capture["errors"].append({"workload": None, "error": str(exc)})
    except KeyboardInterrupt:
        interrupted = True
        capture["errors"].append({"workload": None, "error": "capture interrupted"})
    except Exception as exc:  # every other failure is recorded harness evidence, never a clean capture
        capture["errors"].append({"workload": None, "error": f"{type(exc).__name__}: {exc}"})
    finally:
        capture["contentionEnd"] = machine_slot_contention()
        capture["elapsedSeconds"] = time.perf_counter() - started
        capture["finishedAtUnix"] = time.time()
        try:
            if harness_digest() != capture["harnessDigest"]:
                capture["errors"].append({"workload": None, "error": "harness bytes changed during the capture"})
            digests_after = {name: target_digest(root) for name, root in arms}
            if digests_after != digests_before:
                capture["errors"].append({"workload": None, "error": "target bytes changed during the capture"})
        except (HarnessError, OSError) as exc:
            capture["errors"].append({"workload": None, "error": f"post-capture verification failed: {exc}"})
        if not ns.keep_scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            capture["scratchDir"] = str(scratch)
        if interrupted:
            capture["state"] = "interrupted"
        elif finished_normally and not capture["errors"]:
            capture["state"] = "complete"
        else:
            capture["state"] = "failed"
        capture["complete"] = capture["state"] == "complete"
        capture["summary"] = summarize_capture(capture)
        try:
            text = json.dumps(capture, indent=2, sort_keys=True, allow_nan=False)
        except ValueError as exc:
            capture["errors"].append({"workload": None, "error": f"capture holds non-finite values: {exc}"})
            capture["state"], capture["complete"] = "failed", False
            text = json.dumps(capture, indent=2, sort_keys=True)
        (capture_dir / "capture.json").write_text(text + "\n", encoding="utf-8")
    print(render_capture_summary(capture))
    print(f"capture: {capture_dir / 'capture.json'} (state {capture['state']})")
    return 0 if capture["complete"] else EXIT_HARNESS_FAILURE


# ---------------------------------------------------------------------------
# Statistics and comparison


def metric_class(metric: str) -> str:
    if metric.startswith("artifact.") and metric.endswith("_ms"):
        return "artifact_ms"
    if metric.endswith("_ms"):
        return "fast_python_ms"
    if metric.endswith("_mib"):
        return "memory_mib"
    return "count"


def percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("no values")
    rank = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[rank]


def collect_metric_samples(capture: Dict[str, Any], arm: str) -> Dict[str, Dict[int, float]]:
    values: Dict[str, Dict[int, float]] = {}
    for sample in capture.get("samples", []):
        if sample.get("arm") != arm or sample.get("primer") or not sample.get("ok"):
            continue
        for metric, value in (sample.get("metrics") or {}).items():
            values.setdefault(metric, {})[int(sample["block"])] = float(value)
    return values


def collect_equivalence(capture: Dict[str, Any], arm: str) -> Dict[str, List[str]]:
    seen: Dict[str, List[str]] = {}
    for sample in capture.get("samples", []):
        if sample.get("arm") != arm or not sample.get("ok"):
            continue
        for key, value in (sample.get("equivalence") or {}).items():
            digest = canonical_json_digest(value)
            if digest not in seen.setdefault(key, []):
                seen[key].append(digest)
    return seen


def summarize_capture(capture: Dict[str, Any]) -> Dict[str, Any]:
    summary: Dict[str, Any] = {}
    for arm in capture.get("arms", []):
        name = arm["name"]
        rows = {}
        for metric, by_block in sorted(collect_metric_samples(capture, name).items()):
            values = list(by_block.values())
            rows[metric] = {
                "n": len(values),
                "median": statistics.median(values),
                "p10": percentile(values, 0.10),
                "p90": percentile(values, 0.90),
                "min": min(values),
                "max": max(values),
            }
        summary[name] = rows
    try:
        policy = contamination_policy(load_gates())
    except HarnessError:
        policy = None
    return {
        "arms": summary,
        "machine": machine_observations(capture),
        "foreignCpu": foreign_cpu_observations(capture, capture.get("workloads", []), policy[1] if policy else 10.0),
        "contaminationPolicy": {"maxForeignCores": policy[0], "windowSeconds": policy[1]} if policy else None,
        "goldenMismatches": golden_mismatches(capture),
    }


def machine_observations(capture: Dict[str, Any]) -> Dict[str, Any]:
    """Per-workload 1-minute load average and held machine slots observed before each sample."""
    observations: Dict[str, Any] = {}
    for workload in capture.get("workloads", []):
        loads = []
        held = 0
        for sample in capture.get("samples", []):
            if sample.get("workload") != workload:
                continue
            machine = sample.get("machine") or {}
            if machine.get("loadavg"):
                loads.append(float(machine["loadavg"][0]))
            held += bool(machine.get("slotsHeld"))
        if loads:
            observations[workload] = {
                "samples": len(loads),
                "load1Min": min(loads),
                "load1Median": statistics.median(loads),
                "load1Max": max(loads),
                "samplesWithSlotsHeld": held,
            }
    return observations


def golden_mismatches(capture: Dict[str, Any]) -> Dict[str, List[str]]:
    golden = capture.get("summaryGolden") or {}
    mismatches: Dict[str, List[str]] = {}
    for sample in capture.get("samples", []):
        if sample.get("workload") != "summary" or not sample.get("ok"):
            continue
        equivalence = sample.get("equivalence") or {}
        for key, digest in golden.items():
            if equivalence.get(key) != digest and key not in mismatches.setdefault(sample["arm"], []):
                mismatches[sample["arm"]].append(key)
    return {arm: sorted(keys) for arm, keys in mismatches.items() if keys}


def render_capture_summary(capture: Dict[str, Any]) -> str:
    lines = [
        f"capture {capture['captureId']} state={capture.get('state')} "
        f"({capture.get('elapsedSeconds', 0):.1f}s, errors={len(capture['errors'])})"
    ]
    summary = capture.get("summary", {})
    for name, rows in summary.get("arms", {}).items():
        lines.append(f"arm {name}:")
        for metric, row in rows.items():
            lines.append(
                f"  {metric:44s} n={row['n']:3d} median={row['median']:12.3f} p90={row['p90']:12.3f} min={row['min']:12.3f}"
            )
    for workload, row in summary.get("machine", {}).items():
        lines.append(
            f"machine {workload:9s} load1 min/median/max={row['load1Min']:.2f}/{row['load1Median']:.2f}/{row['load1Max']:.2f} "
            f"samples with held slots={row['samplesWithSlotsHeld']}"
        )
    limit = (summary.get("contaminationPolicy") or {}).get("maxForeignCores")
    for workload, row in (summary.get("foreignCpu") or {}).items():
        flag = " ABOVE contamination limit" if limit is not None and row["foreignCoresMax"] > limit else ""
        lines.append(
            f"foreign CPU {workload:9s} {row['windows']} windows of >={row['windowSeconds']:g}s: "
            f"median {row['foreignCoresMedian']:.2f} max {row['foreignCoresMax']:.2f} cores (limit {limit}){flag}"
        )
    for arm, keys in summary.get("goldenMismatches", {}).items():
        lines.append(f"WARNING arm {arm} summary differs from the v1 golden: {keys}")
    return "\n".join(lines)


def bootstrap_ci(
    baseline: Sequence[float], candidate: Sequence[float], paired: bool, resamples: int = 4000, seed: int = 1
) -> Tuple[float, float, float]:
    """95% CI of the median difference (candidate - baseline)."""
    rng = SplitMix64(seed)
    if paired:
        diffs = [c - b for b, c in zip(baseline, candidate)]
        point = statistics.median(diffs)
        stats = []
        for _ in range(resamples):
            stats.append(statistics.median(diffs[rng.below(len(diffs))] for _ in range(len(diffs))))
    else:
        point = statistics.median(candidate) - statistics.median(baseline)
        stats = []
        for _ in range(resamples):
            b = statistics.median(baseline[rng.below(len(baseline))] for _ in range(len(baseline)))
            c = statistics.median(candidate[rng.below(len(candidate))] for _ in range(len(candidate)))
            stats.append(c - b)
    stats.sort()
    low = stats[int(0.025 * (resamples - 1))]
    high = stats[int(math.ceil(0.975 * (resamples - 1)))]
    return point, low, high


def load_capture(reference: str) -> Tuple[Dict[str, Any], Optional[str]]:
    path_text, _, arm = reference.partition("#")
    path = Path(path_text).expanduser()
    if path.is_dir():
        path = path / "capture.json"
    try:
        capture = json.loads(path.read_text(encoding="utf-8"), parse_constant=_reject_json_constant)
    except (OSError, ValueError) as exc:
        raise HarnessError(f"capture unreadable at {path}: {exc}") from exc
    validate_capture(capture, path)
    capture["_path"] = str(path.resolve())
    labels_path = path.parent / LABELS_FILE
    if labels_path.exists():
        try:
            capture["_labels"] = json.loads(labels_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise HarnessError(f"capture labels unreadable at {labels_path}: {exc}") from exc
    return capture, (arm or None)


def _reject_json_constant(name: str) -> Any:
    raise ValueError(f"non-finite JSON constant {name}")


def validate_capture(capture: Any, path: Any) -> None:
    """Reject malformed evidence before any statistics (harness failure, never a measurement)."""
    if not isinstance(capture, dict):
        raise HarnessError(f"capture {path} is not a JSON object")
    if capture.get("schemaVersion") != CAPTURE_SCHEMA_VERSION:
        raise HarnessError(f"capture {path} has unsupported schema {capture.get('schemaVersion')}")
    problems: List[str] = []
    if capture.get("state") not in ("running", "complete", "failed", "interrupted"):
        problems.append(f"invalid state {capture.get('state')!r}")
    if not isinstance(capture.get("complete"), bool):
        problems.append("missing complete flag")
    for key in ("workloads", "arms", "samples", "errors"):
        if not isinstance(capture.get(key), list):
            problems.append(f"{key} is not a list")
    for key in ("samplesConfig", "inventory", "primers", "overrides", "manifest"):
        if not isinstance(capture.get(key), dict):
            problems.append(f"{key} is not an object")
    if problems:
        raise HarnessError(f"capture {path} is malformed: {problems}")
    for arm in capture["arms"]:
        if not isinstance(arm, dict) or not isinstance(arm.get("name"), str) or not isinstance(arm.get("conductorDigest"), str):
            problems.append(f"arm entry {arm!r} lacks name/conductorDigest")
    for name, count in capture["samplesConfig"].items():
        if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
            problems.append(f"samplesConfig[{name}] = {count!r} is not a positive integer")
    for index, sample in enumerate(capture["samples"]):
        if not isinstance(sample, dict):
            problems.append(f"sample {index} is not an object")
            continue
        block = sample.get("block")
        if (
            not isinstance(sample.get("workload"), str)
            or not isinstance(sample.get("arm"), str)
            or not isinstance(block, int)
            or isinstance(block, bool)
            or not isinstance(sample.get("primer"), bool)
            or not isinstance(sample.get("ok"), bool)
        ):
            problems.append(f"sample {index} lacks workload/arm/block/primer/ok")
            continue
        if sample["ok"]:
            metrics = sample.get("metrics")
            if not isinstance(metrics, dict) or not isinstance(sample.get("equivalence"), dict):
                problems.append(f"sample {index} lacks metrics/equivalence")
                continue
            bad = sorted(name for name, value in metrics.items() if not is_finite_number(value))
            if bad:
                problems.append(f"sample {index} has non-finite or non-numeric metrics {bad}")
        if len(problems) > 20:
            break
    if problems:
        raise HarnessError(f"capture {path} is malformed: {problems[:20]}")


def resolve_arm(capture: Dict[str, Any], arm: Optional[str]) -> str:
    names = [entry["name"] for entry in capture.get("arms", [])]
    if arm is None:
        if len(names) != 1:
            raise HarnessError(f"capture {capture['_path']} has arms {names}; select one with #ARM")
        return names[0]
    if arm not in names:
        raise HarnessError(f"capture {capture['_path']} has no arm {arm!r}")
    return arm


COMPATIBILITY_KEYS = (
    "harnessVersion",
    "harnessDigest",
    "fixtureVersion",
    "fixtureManifestSha256",
    "host",
    "python",
    "full",
    "adapters",
    "targetLoading",
)


def compatibility_problems(baseline: Dict[str, Any], candidate: Dict[str, Any], workloads: Iterable[str]) -> List[str]:
    """Measurement settings that must match for two captures' samples to be comparable."""
    problems = []
    workload_set = set(workloads)
    for key in COMPATIBILITY_KEYS:
        b_value, c_value = baseline.get(key), candidate.get(key)
        if key == "adapters":
            b_value = {name: (b_value or {}).get(name) for name in sorted(workload_set)}
            c_value = {name: (c_value or {}).get(name) for name in sorted(workload_set)}
        if b_value != c_value:
            problems.append(f"incompatible {key}: {b_value!r} != {c_value!r}")
    for name in sorted(workload_set):
        if (baseline.get("inventory") or {}).get(name) != (candidate.get("inventory") or {}).get(name):
            problems.append(f"incompatible {name} inventory")
    if workload_set & {"mem", "rss"} and baseline.get("ledgerSha256") != candidate.get("ledgerSha256"):
        problems.append("incompatible ledgerSha256")
    if workload_set & {"artifact", "rss"} and baseline.get("swiftVersion") != candidate.get("swiftVersion"):
        problems.append("incompatible swiftVersion")
    if "cli" in workload_set and baseline.get("cliPython") != candidate.get("cliPython"):
        problems.append(f"incompatible cliPython: {baseline.get('cliPython')!r} != {candidate.get('cliPython')!r}")
    if "artifact" in workload_set and baseline.get("artifactFixtureBytes") != candidate.get("artifactFixtureBytes"):
        problems.append("incompatible artifactFixtureBytes")
    if "rss" in workload_set and baseline.get("rssJobs") != candidate.get("rssJobs"):
        problems.append("incompatible rssJobs")
    if "summary" in workload_set:
        b_corpus = (baseline.get("retainedLogsCorpus") or {}).get("digest")
        c_corpus = (candidate.get("retainedLogsCorpus") or {}).get("digest")
        if b_corpus != c_corpus:
            problems.append(f"incompatible retained-log corpus: {b_corpus!r} != {c_corpus!r}")
    return problems


def acceptance_problems(label: str, capture: Dict[str, Any], workloads: Iterable[str], gates: Dict[str, Any]) -> List[str]:
    """Smoke overrides and below-minimum settings make a capture ineligible for acceptance."""
    problems = []
    manifest = capture.get("manifest") or {}
    overrides = capture.get("overrides") or {}
    for key in ("samples", "artifactScale", "rssJobs"):
        if overrides.get(key) is not None:
            problems.append(f"{label} capture used smoke override {key}={overrides[key]!r}; not acceptance evidence")
    workload_set = set(workloads)
    minimums = gates.get("minSamples") or {}
    for workload in sorted(workload_set):
        cls = SAMPLE_CLASS.get(workload)
        configured = (capture.get("samplesConfig") or {}).get(cls)
        required = max(int((manifest.get("samples") or {}).get(cls, 0)), int(minimums.get(cls, 0)))
        if cls is None or not isinstance(configured, int) or configured < required or required <= 0:
            problems.append(f"{label} {workload} sample count {configured!r} is below the required {required}")
    if "artifact" in workload_set:
        pinned = [int(manifest.get("artifact", {}).get("executableBytes", -1)), int(manifest.get("artifact", {}).get("dsymBytes", -1))]
        if capture.get("artifactFixtureBytes") != pinned:
            problems.append(f"{label} artifact fixture bytes {capture.get('artifactFixtureBytes')!r} != pinned {pinned}")
    if "rss" in workload_set and capture.get("rssJobs") != (manifest.get("rss") or {}).get("retainedJobs"):
        problems.append(f"{label} rss jobs {capture.get('rssJobs')!r} != pinned {(manifest.get('rss') or {}).get('retainedJobs')!r}")
    return problems


def pinned_manifest_problem(capture: Dict[str, Any]) -> Optional[str]:
    """Why the capture's recorded manifest is not the pinned fixture manifest, if it is not."""
    try:
        pinned_sha = sha256_file(MANIFEST_PATH)
        pinned = load_manifest()
    except (OSError, HarnessError) as exc:
        return f"pinned fixture manifest unavailable: {exc}"
    if capture.get("fixtureManifestSha256") != pinned_sha:
        return f"recorded fixtureManifestSha256 {capture.get('fixtureManifestSha256')!r} is not the pinned manifest {pinned_sha}"
    if capture.get("manifest") != pinned:
        return "recorded manifest content does not match the pinned manifest"
    return None


def authoritative_inventory(capture: Dict[str, Any], workload: str) -> Tuple[Optional[Dict[str, List[str]]], Optional[str]]:
    """(inventory, problem): what the versioned adapter contract requires of ``workload`` samples.

    The inventory is rebuilt from the current adapter contract, the pinned fixture
    manifest, and the recorded run settings (``full``, retained-log corpus); the
    capture's own inventory is evidence checked against it, never the authority.
    """
    if workload not in ADAPTER_VERSIONS:
        return None, f"unknown workload {workload!r}"
    recorded_adapter = (capture.get("adapters") or {}).get(workload)
    if recorded_adapter != ADAPTER_VERSIONS[workload]:
        return None, f"{workload}: recorded adapter {recorded_adapter!r} is not the current contract {ADAPTER_VERSIONS[workload]!r}"
    problem = pinned_manifest_problem(capture)
    if problem:
        return None, problem
    full = capture.get("full")
    if not isinstance(full, bool):
        return None, f"recorded full setting {full!r} is not a boolean"
    corpus = capture.get("retainedLogsCorpus")
    if corpus is not None and not (isinstance(corpus, dict) and isinstance(corpus.get("digest"), str) and corpus.get("files")):
        return None, "recorded retained-log corpus is malformed"
    expected = workload_inventory(workload, capture["manifest"], full, corpus is not None)
    recorded = (capture.get("inventory") or {}).get(workload)
    if recorded != expected:
        recorded = recorded if isinstance(recorded, dict) else {}
        missing = sorted(set(expected["metrics"] + expected["equivalence"]) - set((recorded.get("metrics") or []) + (recorded.get("equivalence") or [])))
        return None, f"{workload}: recorded inventory does not match the versioned adapter contract (missing {missing[:8]})"
    return expected, None


def completeness_problems(label: str, capture: Dict[str, Any], arm: str, inventories: Dict[str, Dict[str, List[str]]]) -> List[str]:
    """Every measured block of every required workload must be present exactly once and satisfy the inventory."""
    problems = []
    for workload, inventory in sorted(inventories.items()):
        cls = SAMPLE_CLASS.get(workload)
        count = (capture.get("samplesConfig") or {}).get(cls)
        if not isinstance(count, int):
            problems.append(f"{label} {workload}: no sample count recorded")
            continue
        blocks: List[int] = []
        for sample in capture.get("samples", []):
            if sample.get("arm") != arm or sample.get("workload") != workload or sample.get("primer"):
                continue
            if not sample.get("ok"):
                problems.append(f"{label} {workload} block {sample.get('block')}: failed sample")
                continue
            problem = sample_inventory_problem(sample, inventory)
            if problem:
                problems.append(f"{label} {workload} block {sample.get('block')}: {problem}")
            blocks.append(int(sample["block"]))
        if sorted(blocks) != list(range(count)):
            problems.append(f"{label} {workload}: measured blocks {len(blocks)} do not cover 0..{count - 1} exactly once")
    return problems


def capture_problems(
    label: str, capture: Dict[str, Any], arm: str, workloads: Iterable[str], gates: Dict[str, Any]
) -> Tuple[List[str], List[str]]:
    """(harness failures, inconclusive reasons) for one arm of one capture."""
    harness: List[str] = []
    inconclusive: List[str] = []
    if capture.get("state") != "complete" or capture.get("complete") is not True:
        harness.append(f"{label} capture state is {capture.get('state')!r}, not complete")
    if capture.get("errors"):
        harness.append(f"{label} capture recorded errors: {capture['errors'][:3]}")
    missing = [name for name in workloads if name not in capture.get("workloads", [])]
    if missing:
        inconclusive.append(f"{label} capture lacks required workloads {missing}")
    else:
        inventories: Dict[str, Dict[str, List[str]]] = {}
        for workload in sorted(set(workloads)):
            inventory, problem = authoritative_inventory(capture, workload)
            if inventory is None:
                if f"{label} {problem}" not in harness:
                    harness.append(f"{label} {problem}")
            else:
                inventories[workload] = inventory
        harness.extend(completeness_problems(label, capture, arm, inventories))
        policy_problem, contaminated = contamination_problems(label, capture, arm, workloads, gates)
        harness.extend(policy_problem)
        inconclusive.extend(contaminated)
    inconclusive.extend(acceptance_problems(label, capture, workloads, gates))
    inconclusive.extend(label_problems(label, capture, arm, workloads))
    for key in ("contentionStart", "contentionEnd"):
        if (capture.get(key) or {}).get("slotsHeld"):
            inconclusive.append(f"{label} {key}: machine slots held {capture[key]['slotsHeld']}")
    held = sorted(
        {
            sample["workload"]
            for sample in capture.get("samples", [])
            if sample.get("arm") == arm and sample.get("workload") in set(workloads) and (sample.get("machine") or {}).get("slotsHeld")
        }
    )
    if held:
        inconclusive.append(f"{label} samples for {held} ran while machine slots were held")
    return harness, inconclusive


def arm_digest(capture: Dict[str, Any], arm: str) -> Optional[str]:
    for entry in capture.get("arms", []):
        if entry.get("name") == arm:
            return entry.get("conductorDigest")
    return None


def parse_utc(value: str) -> float:
    import calendar

    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except (TypeError, ValueError) as exc:
        raise HarnessError(f"timestamp {value!r} is not YYYY-MM-DDTHH:MM:SSZ") from exc


def label_problems(label: str, capture: Dict[str, Any], arm: str, workloads: Iterable[str]) -> List[str]:
    """Evidence labels never pass: excluded captures and contaminated samples are inconclusive."""
    labels = capture.get("_labels") or {}
    problems = []
    if labels.get("excludeFromAcceptance"):
        problems.append(f"{label} capture is labeled non-acceptance: {labels.get('reason')}")
    workload_set = set(workloads)
    for window in labels.get("contaminationWindows") or []:
        start, end = parse_utc(window["start"]), parse_utc(window["end"])
        affected = set()
        for sample in capture.get("samples", []):
            if sample.get("arm") != arm or sample.get("workload") not in workload_set or sample.get("primer"):
                continue
            sample_start = sample.get("startedAtUnix", capture.get("startedAtUnix"))
            sample_end = sample.get("finishedAtUnix", capture.get("finishedAtUnix"))
            if sample_start is None or sample_end is None or (sample_start < end and sample_end > start):
                affected.add(sample["workload"])
        if affected:
            problems.append(
                f"{label} samples for {sorted(affected)} overlap contamination window "
                f"{window['start']}..{window['end']} ({window.get('reason')})"
            )
    return problems


def _valid_cpu_counters(value: Any) -> bool:
    return isinstance(value, dict) and all(is_finite_number(value.get(key)) for key in ("at", "busyTicks", "totalTicks", "ownCpuSeconds"))


def foreign_cpu_windows(capture: Dict[str, Any], workload: str, window_seconds: float) -> Optional[List[Dict[str, Any]]]:
    """Run-order windows of consecutive ``workload`` samples spanning at least ``window_seconds``.

    Windows include both arms and primers (the host counters are continuous) and the
    gaps between samples; a short final remainder joins the previous window. Returns
    ``None`` when any sample lacks valid counters or the host CPU count is unknown.
    """
    ncpu = (capture.get("host") or {}).get("ncpu")
    if not isinstance(ncpu, int) or isinstance(ncpu, bool) or ncpu <= 0:
        return None
    groups: List[List[Dict[str, Any]]] = []
    current: List[Dict[str, Any]] = []
    for sample in capture.get("samples", []):
        if sample.get("workload") != workload:
            continue
        cpu = sample.get("hostCpu") or {}
        if not (_valid_cpu_counters(cpu.get("start")) and _valid_cpu_counters(cpu.get("end"))):
            return None
        current.append(sample)
        if float(cpu["end"]["at"]) - float(current[0]["hostCpu"]["start"]["at"]) >= window_seconds:
            groups.append(current)
            current = []
    if current:
        if groups:
            groups[-1].extend(current)
        else:
            groups.append(current)
    windows = []
    for group in groups:
        start, end = group[0]["hostCpu"]["start"], group[-1]["hostCpu"]["end"]
        windows.append(
            {"samples": group, "seconds": float(end["at"]) - float(start["at"]), "foreignCores": foreign_cores(start, end, ncpu)}
        )
    return windows


def contamination_policy(gates: Dict[str, Any]) -> Optional[Tuple[float, float]]:
    policy = gates.get("contamination")
    if not isinstance(policy, dict):
        return None
    limit, window = policy.get("maxForeignCores"), policy.get("windowSeconds")
    if not (is_finite_number(limit) and limit > 0 and is_finite_number(window) and window > 0):
        return None
    return float(limit), float(window)


def contamination_problems(
    label: str, capture: Dict[str, Any], arm: str, workloads: Iterable[str], gates: Dict[str, Any]
) -> Tuple[List[str], List[str]]:
    """(policy failures, inconclusive reasons) from the predeclared foreign-CPU contamination gate.

    A measured sample of ``arm`` is contaminated when it falls in a window whose
    average foreign CPU (host busy CPUs minus this capture's own CPU) exceeds the
    gates' ``maxForeignCores``. Any contaminated sample, or missing counters, makes
    the workload inconclusive; the gate can never make a result pass.
    """
    policy = contamination_policy(gates)
    if policy is None:
        return ["gates define no valid contamination policy (contamination.maxForeignCores, contamination.windowSeconds)"], []
    limit, window_seconds = policy
    problems: List[str] = []
    for workload in sorted(set(workloads)):
        windows = foreign_cpu_windows(capture, workload, window_seconds)
        if windows is None:
            problems.append(f"{label} {workload}: samples lack host CPU evidence; contamination cannot be ruled out")
            continue
        flagged = [item for item in windows if item["foreignCores"] is None or item["foreignCores"] > limit]
        affected = sum(1 for item in flagged for sample in item["samples"] if sample.get("arm") == arm and not sample.get("primer"))
        if affected:
            observed = [item["foreignCores"] for item in flagged if item["foreignCores"] is not None]
            worst = f"{max(observed):.2f}" if observed else "unmeasurable"
            problems.append(
                f"{label} {workload}: {affected} measured samples ran in {len(flagged)} windows with foreign CPU above "
                f"{limit:g} cores (worst {worst})"
            )
    return [], problems


def foreign_cpu_observations(capture: Dict[str, Any], workloads: Iterable[str], window_seconds: float) -> Dict[str, Any]:
    observations: Dict[str, Any] = {}
    for workload in workloads:
        windows = foreign_cpu_windows(capture, workload, window_seconds) or []
        values = [item["foreignCores"] for item in windows if item["foreignCores"] is not None]
        if values:
            observations[workload] = {
                "windows": len(windows),
                "windowSeconds": window_seconds,
                "foreignCoresMedian": statistics.median(values),
                "foreignCoresMax": max(values),
            }
    return observations


def command_label(ns: argparse.Namespace) -> int:
    path = Path(ns.capture).expanduser()
    capture_dir = path if path.is_dir() else path.parent
    if not (capture_dir / "capture.json").is_file():
        raise HarnessError(f"no capture.json in {capture_dir}")
    labels_path = capture_dir / LABELS_FILE
    labels = json.loads(labels_path.read_text(encoding="utf-8")) if labels_path.exists() else {}
    if ns.exclude:
        labels["excludeFromAcceptance"] = True
        labels["reason"] = ns.reason
    if ns.window:
        start, end = ns.window
        parse_utc(start), parse_utc(end)
        labels.setdefault("contaminationWindows", []).append({"start": start, "end": end, "reason": ns.reason})
    labels.setdefault("history", []).append(
        {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "exclude": bool(ns.exclude), "window": ns.window, "reason": ns.reason}
    )
    labels_path.write_text(json.dumps(labels, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"labels: {labels_path}")
    return 0


def load_gates(path: Path = GATES_PATH) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise HarnessError(f"gates unreadable at {path}: {exc}") from exc


def evaluate_comparison(
    baseline: Dict[str, Any],
    baseline_arm: str,
    candidate: Dict[str, Any],
    candidate_arm: str,
    gates: Dict[str, Any],
    profile_name: str,
    confirm: Optional[Tuple[Dict[str, Any], str, Dict[str, Any], str]] = None,
    enforce_reference_targets: bool = False,
) -> Dict[str, Any]:
    profile = (gates.get("profiles") or {}).get(profile_name)
    if profile is None:
        raise HarnessError(f"unknown gate profile {profile_name!r}")
    report: Dict[str, Any] = {
        "profile": profile_name,
        "baseline": f"{baseline['_path']}#{baseline_arm}",
        "candidate": f"{candidate['_path']}#{candidate_arm}",
        "harnessFailures": [],
        "inconclusive": [],
        "regressions": [],
        "gateFailures": [],
        "metrics": {},
    }
    if baseline["_path"] == candidate["_path"] and baseline_arm == candidate_arm:
        report["harnessFailures"].append("baseline and candidate are the same arm of the same capture")
    workloads = list(profile.get("workloads") or [])
    if not workloads:
        report["harnessFailures"].append(f"profile {profile_name!r} names no workloads")
    for label, capture, arm in (("baseline", baseline, baseline_arm), ("candidate", candidate, candidate_arm)):
        harness, inconclusive = capture_problems(label, capture, arm, workloads, gates)
        report["harnessFailures"].extend(harness)
        report["inconclusive"].extend(inconclusive)
    report["inconclusive"].extend(compatibility_problems(baseline, candidate, workloads))
    confirm = _validated_confirmation(baseline, baseline_arm, candidate, candidate_arm, confirm, workloads, gates, report)
    paired = baseline["_path"] == candidate["_path"] and baseline_arm != candidate_arm
    report["paired"] = paired
    classes = gates["classes"]
    b_samples = collect_metric_samples(baseline, baseline_arm)
    c_samples = collect_metric_samples(candidate, candidate_arm)
    required_metrics: List[str] = []
    required_equivalence: List[str] = []
    for workload in workloads:
        if workload not in baseline.get("workloads", []) or workload not in candidate.get("workloads", []):
            continue  # already inconclusive: a capture lacks the workload
        for capture in (baseline, candidate):
            inventory, _problem = authoritative_inventory(capture, workload)
            if inventory is None:
                continue  # already a harness failure from capture_problems
            required_metrics.extend(inventory["metrics"])
            required_equivalence.extend(inventory["equivalence"])
    policy = contamination_policy(gates)
    if policy is not None:
        report["foreignCpu"] = {
            label: foreign_cpu_observations(capture, workloads, policy[1])
            for label, capture in (("baseline", baseline), ("candidate", candidate))
        }
    for metric in sorted(set(required_metrics)):
        cls = metric_class(metric)
        rules = classes[cls]
        b_values_map = b_samples.get(metric, {})
        c_values_map = c_samples.get(metric, {})
        if not b_values_map or not c_values_map:
            report["inconclusive"].append(f"{metric}: missing in {'baseline' if not b_values_map else 'candidate'}")
            continue
        if paired:
            blocks = sorted(set(b_values_map) & set(c_values_map))
            b_values = [b_values_map[block] for block in blocks]
            c_values = [c_values_map[block] for block in blocks]
        else:
            b_values = list(b_values_map.values())
            c_values = list(c_values_map.values())
        workload = metric.split(".", 1)[0]
        if workload not in SAMPLE_CLASS or SAMPLE_CLASS[workload] not in gates.get("minSamples", {}):
            report["harnessFailures"].append(f"{metric}: no minimum sample count for workload {workload!r}")
            continue
        minimum = int(gates["minSamples"][SAMPLE_CLASS[workload]])
        if min(len(b_values), len(c_values)) < minimum:
            report["inconclusive"].append(f"{metric}: {min(len(b_values), len(c_values))} samples < {minimum}")
            continue
        b_median = statistics.median(b_values)
        c_median = statistics.median(c_values)
        row: Dict[str, Any] = {"class": cls, "baselineMedian": b_median, "candidateMedian": c_median, "n": len(c_values)}
        if cls == "count":
            if set(b_values) != {b_values[0]} or set(c_values) != {c_values[0]}:
                report["inconclusive"].append(f"{metric}: deterministic count varied between samples")
            elif c_values[0] > b_values[0] and not _gate_for(profile, metric):
                report["regressions"].append(f"{metric}: count rose {b_values[0]:g} -> {c_values[0]:g}")
            report["metrics"][metric] = row
            _apply_gates(profile, metric, row, b_values, c_values, report, enforce_reference_targets)
            continue
        point, low, high = bootstrap_ci(b_values, c_values, paired)
        floor = max(float(rules["relativeFloor"]) * abs(b_median), float(rules["absoluteFloor"]))
        row.update({"diffMedian": point, "ciLow": low, "ciHigh": high, "regressionFloor": floor})
        row["candidateP90"] = percentile(c_values, 0.9)
        row["baselineP90"] = percentile(b_values, 0.9)
        has_gate = _gate_for(profile, metric) is not None
        if not has_gate:
            if point > floor and low > 0:
                confirmed = _confirm_regression(confirm, metric, floor)
                if confirmed:
                    report["regressions"].append(f"{metric}: +{point:.3f} (CI {low:.3f}..{high:.3f}) > floor {floor:.3f}, confirmed")
                else:
                    report["inconclusive"].append(
                        f"{metric}: suspected regression +{point:.3f} (CI {low:.3f}..{high:.3f}); needs a valid independent confirming batch"
                    )
            elif high > floor:
                report["inconclusive"].append(f"{metric}: CI upper {high:.3f} exceeds no-regression floor {floor:.3f}")
        report["metrics"][metric] = row
        _apply_gates(profile, metric, row, b_values, c_values, report, enforce_reference_targets)
    for gate in profile.get("gates") or []:
        if not any(fnmatch.fnmatch(metric, gate["metric"]) for metric in report["metrics"]):
            report["inconclusive"].append(f"gate {gate['metric']}: no measured metric with enough samples matches it")
    allowed = list(profile.get("allowChangedEquivalence") or [])
    b_eq = collect_equivalence(baseline, baseline_arm)
    c_eq = collect_equivalence(candidate, candidate_arm)
    for key in sorted(set(required_equivalence)):
        b_digests, c_digests = b_eq.get(key, []), c_eq.get(key, [])
        if not b_digests or not c_digests:
            report["harnessFailures"].append(f"{key}: equivalence evidence missing")
        elif len(b_digests) > 1 or len(c_digests) > 1:
            report["harnessFailures"].append(f"{key}: equivalence evidence varied between samples")
        elif b_digests != c_digests and not any(fnmatch.fnmatch(key, pattern) for pattern in allowed):
            report["regressions"].append(f"{key}: behavior evidence changed")
    if "summary" in workloads:
        for role in profile.get("requireGolden") or []:
            capture, arm = (baseline, baseline_arm) if role == "baseline" else (candidate, candidate_arm)
            golden = capture.get("summaryGolden") or {}
            if not golden:
                report["inconclusive"].append(f"{role}: no summary golden recorded")
            equivalence = collect_equivalence(capture, arm)
            for key, digest in sorted(golden.items()):
                if equivalence.get(key) != [canonical_json_digest(digest)]:
                    report["inconclusive"].append(f"{role} {key}: summary differs from the v1 golden")
    if "output" in workloads:
        expected_tail = (((capture_manifest_or_none(baseline) or {}).get("output") or {}).get("ptyFidelity") or {}).get("expectedTailSha256")
        for role in profile.get("requireGolden") or []:
            capture, arm = (baseline, baseline_arm) if role == "baseline" else (candidate, candidate_arm)
            if not expected_tail or collect_equivalence(capture, arm).get(PTY_FIDELITY_KEY) != [canonical_json_digest(expected_tail)]:
                report["inconclusive"].append(f"{role} {PTY_FIDELITY_KEY}: PTY visible tail differs from the pinned expected tail")
    if report["harnessFailures"]:
        outcome, code = "harness_failure", EXIT_HARNESS_FAILURE
    elif report["regressions"]:
        outcome, code = "regression", EXIT_REGRESSION
    elif report["inconclusive"] or report["gateFailures"]:
        outcome, code = "inconclusive", EXIT_INCONCLUSIVE
    else:
        outcome, code = "qualified", EXIT_QUALIFIED
    report["outcome"] = outcome
    report["exitCode"] = code
    return report


def capture_manifest_or_none(capture: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """The capture's manifest only when it is the validated pinned manifest."""
    return capture.get("manifest") if pinned_manifest_problem(capture) is None else None


def _validated_confirmation(
    baseline: Dict[str, Any],
    baseline_arm: str,
    candidate: Dict[str, Any],
    candidate_arm: str,
    confirm: Optional[Tuple[Dict[str, Any], str, Dict[str, Any], str]],
    workloads: List[str],
    gates: Dict[str, Any],
    report: Dict[str, Any],
) -> Optional[Tuple[Dict[str, Any], str, Dict[str, Any], str]]:
    """A confirming batch counts only if it is independent, clean, complete, and measures the same targets."""
    if confirm is None:
        return None
    cb, cb_arm, cc, cc_arm = confirm
    problems: List[str] = []
    primary_paths = {baseline["_path"], candidate["_path"]}
    primary_ids = {baseline.get("captureId"), candidate.get("captureId")}
    for label, capture in (("confirm baseline", cb), ("confirm candidate", cc)):
        if capture["_path"] in primary_paths or capture.get("captureId") in primary_ids:
            problems.append(f"{label} is not an independent capture (it reuses a primary capture)")
    if cb["_path"] == cc["_path"] and cb_arm == cc_arm:
        problems.append("confirm baseline and candidate are the same arm of the same capture")
    if arm_digest(cb, cb_arm) != arm_digest(baseline, baseline_arm):
        problems.append("confirm baseline measured a different target than the primary baseline")
    if arm_digest(cc, cc_arm) != arm_digest(candidate, candidate_arm):
        problems.append("confirm candidate measured a different target than the primary candidate")
    for label, capture, arm in (("confirm baseline", cb, cb_arm), ("confirm candidate", cc, cc_arm)):
        harness, inconclusive = capture_problems(label, capture, arm, workloads, gates)
        problems.extend(harness + inconclusive)
    problems.extend(f"confirm vs primary baseline: {item}" for item in compatibility_problems(baseline, cb, workloads))
    problems.extend(f"confirm vs primary candidate: {item}" for item in compatibility_problems(candidate, cc, workloads))
    problems.extend(f"confirm pair: {item}" for item in compatibility_problems(cb, cc, workloads))
    if problems:
        report["inconclusive"].extend(f"confirmation rejected: {item}" for item in problems)
        report["confirmation"] = {"accepted": False, "problems": problems}
        return None
    report["confirmation"] = {"accepted": True, "baseline": f"{cb['_path']}#{cb_arm}", "candidate": f"{cc['_path']}#{cc_arm}"}
    return confirm


def _gate_for(profile: Dict[str, Any], metric: str) -> Optional[List[Dict[str, Any]]]:
    matches = [gate for gate in profile.get("gates") or [] if fnmatch.fnmatch(metric, gate["metric"])]
    return matches or None


def _apply_gates(
    profile: Dict[str, Any],
    metric: str,
    row: Dict[str, Any],
    b_values: Sequence[float],
    c_values: Sequence[float],
    report: Dict[str, Any],
    enforce_reference_targets: bool,
) -> None:
    for gate in _gate_for(profile, metric) or []:
        b_median, c_median = row["baselineMedian"], row["candidateMedian"]
        failures = []
        if "exact" in gate and any(value != float(gate["exact"]) for value in c_values):
            failures.append(f"expected exactly {gate['exact']}")
        if "maxRatio" in gate:
            ratio = c_median / b_median if b_median else math.inf
            row["ratio"] = ratio
            if ratio > float(gate["maxRatio"]) or row.get("ciHigh", 0.0) >= 0:
                failures.append(f"ratio {ratio:.3f} (CI high {row.get('ciHigh', 0.0):.3f}) not <= {gate['maxRatio']} with CI below zero")
        if "minImprovement" in gate:
            improvement = b_median - c_median
            if improvement < float(gate["minImprovement"]) or row.get("ciHigh", 0.0) >= 0:
                failures.append(f"improvement {improvement:.3f} < {gate['minImprovement']}")
        if "maxValue" in gate and c_median > float(gate["maxValue"]):
            failures.append(f"median {c_median:.3f} > {gate['maxValue']}")
        if "maxP90Increase" in gate:
            rule = gate["maxP90Increase"]
            b_p90, c_p90 = percentile(b_values, 0.9), percentile(c_values, 0.9)
            if c_p90 - b_p90 > max(float(rule["ratio"]) * b_p90, float(rule["absolute"])):
                failures.append(f"p90 rose {b_p90:.3f} -> {c_p90:.3f}")
        if "referenceMax" in gate:
            row["referenceMax"] = gate["referenceMax"]
            if enforce_reference_targets and c_median > float(gate["referenceMax"]):
                failures.append(f"median {c_median:.3f} > reference target {gate['referenceMax']}")
        if failures:
            report["gateFailures"].append(f"{metric}: " + "; ".join(failures))


def _confirm_regression(
    confirm: Optional[Tuple[Dict[str, Any], str, Dict[str, Any], str]], metric: str, floor: float
) -> bool:
    """Only a pre-validated independent batch (see _validated_confirmation) can confirm."""
    if confirm is None:
        return False
    baseline, b_arm, candidate, c_arm = confirm
    b_values_map = collect_metric_samples(baseline, b_arm).get(metric, {})
    c_values_map = collect_metric_samples(candidate, c_arm).get(metric, {})
    if not b_values_map or not c_values_map:
        return False
    paired = baseline["_path"] == candidate["_path"] and b_arm != c_arm
    if paired:
        blocks = sorted(set(b_values_map) & set(c_values_map))
        b_values = [b_values_map[block] for block in blocks]
        c_values = [c_values_map[block] for block in blocks]
    else:
        b_values, c_values = list(b_values_map.values()), list(c_values_map.values())
    point, low, _high = bootstrap_ci(b_values, c_values, paired, seed=2)
    return point > floor and low > 0


def command_compare(ns: argparse.Namespace) -> int:
    try:
        gates = load_gates(Path(ns.gates) if ns.gates else GATES_PATH)
        baseline, b_arm = load_capture(ns.baseline)
        candidate, c_arm = load_capture(ns.candidate)
        if b_arm is None and c_arm is None and baseline["_path"] == candidate["_path"]:
            raise HarnessError("comparing a capture with itself requires #ARM selectors")
        b_arm = resolve_arm(baseline, b_arm)
        c_arm = resolve_arm(candidate, c_arm)
        if baseline["_path"] == candidate["_path"] and b_arm == c_arm:
            raise HarnessError(f"baseline and candidate are the same arm {b_arm!r} of the same capture")
        confirm = None
        if ns.confirm_baseline or ns.confirm_candidate:
            if not (ns.confirm_baseline and ns.confirm_candidate):
                raise HarnessError("--confirm-baseline and --confirm-candidate must be given together")
            cb, cb_arm = load_capture(ns.confirm_baseline)
            cc, cc_arm = load_capture(ns.confirm_candidate)
            confirm = (cb, resolve_arm(cb, cb_arm), cc, resolve_arm(cc, cc_arm))
        report = evaluate_comparison(
            baseline, b_arm, candidate, c_arm, gates, ns.profile, confirm, ns.enforce_reference_targets
        )
    except HarnessError as exc:
        print(f"harness failure: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    if ns.report:
        Path(ns.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if ns.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_report(report))
    return int(report["exitCode"])


def render_report(report: Dict[str, Any]) -> str:
    lines = [
        f"profile {report['profile']}: {report['outcome']} (exit {report['exitCode']}, paired={report['paired']})",
        f"  baseline:  {report['baseline']}",
        f"  candidate: {report['candidate']}",
    ]
    for metric, row in report["metrics"].items():
        extra = ""
        if "diffMedian" in row:
            extra = f" diff={row['diffMedian']:+.3f} CI[{row['ciLow']:+.3f},{row['ciHigh']:+.3f}] floor={row['regressionFloor']:.3f}"
        lines.append(f"  {metric:44s} base={row['baselineMedian']:12.3f} cand={row['candidateMedian']:12.3f}{extra}")
    for title in ("harnessFailures", "regressions", "gateFailures", "inconclusive"):
        for item in report[title]:
            lines.append(f"  [{title}] {item}")
    return "\n".join(lines)


def command_fixture(ns: argparse.Namespace) -> int:
    manifest = load_manifest()
    data = generate_output_fixture(int(manifest["output"]["seed"]), int(manifest["output"]["sizeBytes"]))
    fidelity = generate_pty_fidelity_fixture()
    pinned = manifest["output"].get("ptyFidelity") or {}
    report = {
        "outputSha256": sha256_bytes(data),
        "sizeBytes": len(data),
        "manifestSha256": manifest["output"]["sha256"],
        "ptyFidelitySha256": sha256_bytes(fidelity),
        "ptyFidelitySizeBytes": len(fidelity),
        "ptyFidelityTranslatedBytes": len(onlcr(fidelity)),
        "ptyFidelityManifestSha256": pinned.get("sha256"),
    }
    print(json.dumps(report))
    if ns.write:
        Path(ns.write).write_bytes(data)
    try:
        verified_fixtures(manifest)
    except (HarnessError, KeyError, TypeError, ValueError) as exc:
        print(f"harness failure: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    return 0


def command_machine(ns: argparse.Namespace) -> int:
    """Measure foreign CPU now against the gates' predeclared contamination limit."""
    if not (math.isfinite(ns.seconds) and ns.seconds > 0):
        raise HarnessError("--seconds must be a positive number")
    policy = contamination_policy(load_gates(Path(ns.gates) if ns.gates else GATES_PATH))
    if policy is None:
        raise HarnessError("gates define no valid contamination policy")
    start = host_cpu_counters()
    time.sleep(ns.seconds)
    end = host_cpu_counters()
    if start is None or end is None:
        raise HarnessError("host CPU counters are unavailable")
    value = foreign_cores(start, end, int(os.cpu_count() or 0))
    slots = machine_slot_contention()
    within = value is not None and value <= policy[0] and not slots["slotsHeld"]
    print(json.dumps({"seconds": ns.seconds, "foreignCores": value, "maxForeignCores": policy[0], "slots": slots, "withinLimit": within}))
    return 0 if within else EXIT_INCONCLUSIVE


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="conductor_benchmark.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="capture benchmark samples for one or two target arms")
    run.add_argument("--target", action="append", default=[], help="NAME=ROOT (repeat for a paired A/B capture)")
    run.add_argument("--full", action="store_true", help="add the artifact and rss workloads")
    run.add_argument("--workloads", help="comma-separated workload subset")
    run.add_argument("--capture-id")
    run.add_argument("--output-dir", help="default: <conductor state>/benchmarks/conductor")
    run.add_argument("--label")
    run.add_argument(
        "--samples", type=int, help="override every sample count (tests/smoke only; the capture is never acceptance evidence)"
    )
    run.add_argument(
        "--class-samples",
        help="per-class sample counts at or above the manifest, e.g. fast=90 (acceptance-eligible)",
    )
    run.add_argument("--logs-dir", help="optional retained conductor logs for the summary workload (never committed)")
    run.add_argument("--artifact-scale", type=float, help="scale the artifact fixture (tests/smoke only; never acceptance evidence)")
    run.add_argument("--rss-jobs", type=int, help="override retained rss jobs (tests/smoke only; never acceptance evidence)")
    run.add_argument("--keep-scratch", action="store_true")
    run.add_argument("--fail-fast", action="store_true")
    compare = sub.add_parser("compare", help="apply gates to a baseline and a candidate capture")
    compare.add_argument("--baseline", required=True, help="CAPTURE_DIR_OR_JSON[#ARM]")
    compare.add_argument("--candidate", required=True, help="CAPTURE_DIR_OR_JSON[#ARM]")
    compare.add_argument("--profile", default="no-regression")
    compare.add_argument("--gates")
    compare.add_argument("--confirm-baseline")
    compare.add_argument("--confirm-candidate")
    compare.add_argument("--enforce-reference-targets", action="store_true")
    compare.add_argument("--report")
    compare.add_argument("--json", action="store_true")
    label = sub.add_parser("label", help="attach evidence labels (sidecar labels.json) to a capture; compare honors them")
    label.add_argument("capture")
    label.add_argument("--reason", required=True)
    label.add_argument("--exclude", action="store_true", help="exclude the whole capture from acceptance")
    label.add_argument("--window", nargs=2, metavar=("START_UTC", "END_UTC"), help="contamination window, YYYY-MM-DDTHH:MM:SSZ")
    fixture = sub.add_parser("fixture", help="verify the deterministic output and PTY fidelity fixtures")
    fixture.add_argument("--write")
    machine = sub.add_parser("machine", help="measure foreign CPU now against the predeclared contamination limit (exit 0 within, 2 above)")
    machine.add_argument("--seconds", type=float, default=10.0)
    machine.add_argument("--gates")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "__worker":
        return worker_main(args[1])
    if args and args[0] == "__loaded_digest":
        return loaded_digest_main(args[1])
    ns = build_parser().parse_args(args)
    try:
        if ns.command == "run":
            return command_run(ns)
        if ns.command == "compare":
            return command_compare(ns)
        if ns.command == "label":
            if not (ns.exclude or ns.window):
                raise HarnessError("label needs --exclude and/or --window")
            return command_label(ns)
        if ns.command == "machine":
            return command_machine(ns)
        return command_fixture(ns)
    except HarnessError as exc:
        print(f"harness failure: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    except KeyboardInterrupt:
        print("harness failure: interrupted", file=sys.stderr)
        return EXIT_HARNESS_FAILURE
    except Exception as exc:  # never let an unexpected failure exit 1 ("regression")
        print(f"harness failure: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_HARNESS_FAILURE


if __name__ == "__main__":
    raise SystemExit(main())
