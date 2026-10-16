#!/usr/bin/env python3
"""Summarize ``[package-timing]`` records from ``Scripts/package_app.sh`` logs.

Each log may hold one or more packaging runs; a run ends at its
``[package-timing] summary`` record, and a ``phase="startup"`` record always
starts a new run, so an interrupted run never merges into the next one. Only
records at the start of a line count; shell-trace lines such as VERBOSE=1
``+ printf '[package-timing] ...'`` are ignored. Runs whose summary is missing,
whose status is non-zero, or whose script total is unknown are excluded and listed.

Per phase, and for ``total_ms``, ``build_ms`` (phases whose name starts with
``Building ``) and ``non_compile_ms = total_ms - build_ms``, the output reports
the sample count, median, quartiles and IQR in milliseconds. Script totals use
``$EPOCHREALTIME`` (wall clock); comparisons of end-to-end totals should use an
outer harness with a monotonic clock.

Usage: summarize_package_phases.py LOG [LOG ...] [--output summary.json]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import statistics
import sys
from typing import Any, Iterable

SCHEMA_VERSION = 1
BUILD_PHASE_PREFIX = "Building "
_RECORD_PREFIX = "[package-timing] "
STARTUP_PHASE = "startup"
_PHASE_RE = re.compile(
    r'\[package-timing\] phase="((?:[^"\\]|\\.)*)" elapsed_ms=(-?\d+|\?) total_ms=(-?\d+|\?)\s*$'
)
_SUMMARY_RE = re.compile(r"\[package-timing\] summary((?: [a-z_]+=\S*)*)\s*$")
_UNESCAPE_RE = re.compile(r"\\(.)")


def _int_or_none(value: str) -> int | None:
    return None if value == "?" else int(value)


def parse_runs(lines: Iterable[str], source: str = "<input>") -> list[dict[str, Any]]:
    """Split ``lines`` into runs, each closed by a summary record.

    A ``startup`` phase record with records pending closes those records as an
    unterminated run first. Records after the last summary also form an
    unterminated run (``summary`` is ``None``).
    """
    runs: list[dict[str, Any]] = []
    phases: list[tuple[str, int | None]] = []
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line.startswith(_RECORD_PREFIX):
            continue
        match = _PHASE_RE.match(line)
        if match is not None:
            name = _UNESCAPE_RE.sub(r"\1", match.group(1))
            if name == STARTUP_PHASE and phases:
                runs.append({"source": source, "index": len(runs), "phases": phases, "summary": None})
                phases = []
            phases.append((name, _int_or_none(match.group(2))))
            continue
        if line.startswith(_RECORD_PREFIX + "phase="):
            phases.append(("<malformed phase record>", None))
            continue
        match = _SUMMARY_RE.match(line)
        if match is not None:
            fields = dict(token.split("=", 1) for token in match.group(1).split())
            runs.append({"source": source, "index": len(runs), "phases": phases, "summary": fields})
            phases = []
    if phases:
        runs.append({"source": source, "index": len(runs), "phases": phases, "summary": None})
    return runs


def run_metrics(run: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    """Return ``(metrics, None)`` for a usable run or ``(None, reason)``."""
    summary = run["summary"]
    if summary is None:
        return None, "no summary record"
    status = summary.get("status")
    if status not in (None, "0"):
        return None, f"status={status}"
    total = summary.get("total_ms", "?")
    if not re.fullmatch(r"-?\d+", total):
        return None, "unknown total_ms"
    if int(total) < 0:
        return None, "negative total_ms (wall-clock jump; repeat the sample)"
    phase_ms: dict[str, int] = {}
    build_ms = 0
    for name, elapsed in run["phases"]:
        if elapsed is None:
            return None, f"unknown elapsed_ms for phase {name!r}"
        if elapsed < 0:
            return None, f"negative elapsed_ms for phase {name!r} (wall-clock jump; repeat the sample)"
        phase_ms[name] = phase_ms.get(name, 0) + elapsed
        if name.startswith(BUILD_PHASE_PREFIX):
            build_ms += elapsed
    total_ms = int(total)
    return {
        "phases": phase_ms,
        "total_ms": total_ms,
        "build_ms": build_ms,
        "non_compile_ms": total_ms - build_ms,
        "outcome": summary.get("outcome", "?"),
        "deep": summary.get("deep", "?"),
    }, None


def describe(values: list[int]) -> dict[str, Any]:
    ordered = sorted(values)
    if len(ordered) >= 2:
        q1, median, q3 = statistics.quantiles(ordered, n=4, method="inclusive")
    else:
        q1 = median = q3 = float(ordered[0])
    return {"n": len(ordered), "median_ms": median, "p25_ms": q1, "p75_ms": q3, "iqr_ms": q3 - q1,
            "min_ms": ordered[0], "max_ms": ordered[-1]}


def summarize(runs: list[dict[str, Any]]) -> dict[str, Any]:
    usable: list[tuple[dict[str, Any], dict[str, Any]]] = []
    excluded: list[dict[str, Any]] = []
    for run in runs:
        metrics, reason = run_metrics(run)
        if metrics is None:
            excluded.append({"source": run["source"], "index": run["index"], "reason": reason})
        else:
            usable.append((run, metrics))
    phase_order: list[str] = []
    for _, metrics in usable:
        for name in metrics["phases"]:
            if name not in phase_order:
                phase_order.append(name)
    payload: dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "runs": len(usable),
        "excludedRuns": excluded,
        "buildPhasePrefix": BUILD_PHASE_PREFIX,
        "phases": {
            name: describe([m["phases"][name] for _, m in usable if name in m["phases"]]) for name in phase_order
        },
        "outcomes": {},
        "deep": {},
        "perRun": [
            {"source": run["source"], "index": run["index"], "total_ms": m["total_ms"], "build_ms": m["build_ms"],
             "non_compile_ms": m["non_compile_ms"], "outcome": m["outcome"], "deep": m["deep"]}
            for run, m in usable
        ],
    }
    for key in ("total_ms", "build_ms", "non_compile_ms"):
        payload[key] = describe([m[key] for _, m in usable]) if usable else None
    for _, metrics in usable:
        payload["outcomes"][metrics["outcome"]] = payload["outcomes"].get(metrics["outcome"], 0) + 1
        payload["deep"][metrics["deep"]] = payload["deep"].get(metrics["deep"], 0) + 1
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="summarize_package_phases.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    runs: list[dict[str, Any]] = []
    for path in args.logs:
        with path.open(encoding="utf-8", errors="replace") as handle:
            runs.extend(parse_runs(handle, str(path)))
    payload = summarize(runs)
    text = json.dumps(payload, indent=2, sort_keys=False) + "\n"
    if args.output is not None:
        args.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    if not payload["runs"]:
        print("ERROR: no usable [package-timing] runs found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
