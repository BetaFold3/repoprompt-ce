#!/usr/bin/env python3
"""Pure Swift-pipeline timing helpers for the conductor (plan Step 2).

This module owns no process, socket, scheduler, or conductor state. It provides:

* ``RecordSplitter``: bytes -> ``OutputRecord`` with ``\\n``, ``\\r\\n`` and bare
  ``\\r`` delimiters, split UTF-8 safety, and a bounded pending buffer.
* ``classify_record``: a cheap marker parser for command/heading/SwiftPM/XCTest
  lines.
* ``OutputTelemetryCursor``: a reader-owned adapter that feeds a recorder from
  the conductor's existing LF framing and decode, splitting only bare-CR
  records itself (splitter-equivalent records and receive times).
* ``PipelineRecorder``: a bounded per-job recorder with the plan's interface
  (``record_boundary``, ``observe_records``, ``record_operation``, ``finalize``).
* ``derive_intervals``/``derive_slot_waits``: same-process interval derivation.
* ``RotatingJsonl``: an append-only, size-rotated JSONL history.
* Comparison statistics with the harness exit-code contract
  (0 qualified, 1 established regression, 2 inconclusive, 3 harness failure).

Invariants:

* Unknown is never zero. Every span is ``{"ns": int | None, "quality": label}``;
  ``ns`` is ``None`` exactly when the quality is ``unavailable`` or
  ``not_applicable``.
* Durations from different processes are never subtracted.
* Recorder public methods never raise. An internal failure degrades the recorder
  to ``status: "failed"`` (all spans unavailable); callers still wrap calls in
  ``try/except Exception`` so telemetry can never change job state.
* The recorder lock is private and never held while calling back into the
  caller; callers must not hold their scheduler lock while calling in.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, tzinfo
from itertools import repeat
from typing import Any, Callable, Iterable, Iterator, Mapping, NamedTuple, Sequence

SCHEMA_VERSION = 1
FIXTURE_VERSION = "v1"

# Quality labels (plan §3 principle 3).
MEASURED_WALL = "measured_wall"
MEASURED_CPU = "measured_cpu"
OBSERVED_WALL = "observed_wall"
REPORTED_DURATION = "reported_duration"
SAMPLED_WINDOW = "sampled_window"
UNAVAILABLE = "unavailable"
NOT_APPLICABLE = "not_applicable"
VALUE_QUALITIES = frozenset({MEASURED_WALL, MEASURED_CPU, OBSERVED_WALL, REPORTED_DURATION, SAMPLED_WINDOW})
NULL_QUALITIES = frozenset({UNAVAILABLE, NOT_APPLICABLE})
QUALITY_LABELS = VALUE_QUALITIES | NULL_QUALITIES

# Recorder bounds (plan Step 2).
MAX_EVENTS = 20_000
MAX_EVENT_BYTES = 4 * 1024 * 1024
MAX_FILE_IDENTITIES = 10_000
MAX_FILE_IDENTITY_TEXT_BYTES = 2 * 1024 * 1024
MAX_MODULE_AGGREGATES = 256
MAX_SEGMENTS = 64
# Internal bounds not fixed by the plan; chosen to keep payloads small.
MAX_OPERATION_AGGREGATES = 64
MAX_COUNTERS_PER_OPERATION = 32
MAX_NAME_CHARS = 64
MAX_COMMAND_CHARS = 512
MAX_CONTEXT_CHARS = 256
MAX_METADATA_BYTES = 2048

# Splitter bound (shared with the Step 3 contract).
MAX_PENDING_RECORD_BYTES = 64 * 1024

# History bounds.
HISTORY_MAX_ACTIVE_BYTES = 32 * 1024 * 1024
HISTORY_GENERATIONS = 2
HISTORY_MAX_ROW_BYTES = 1024 * 1024
HISTORY_LOCK_TIMEOUT_SECONDS = 2.0

TIMING_ENV_KEY = "RPCE_CONDUCTOR_TIMING"

# Comparison exit codes (plan Step 1).
EXIT_QUALIFIED = 0
EXIT_REGRESSION = 1
EXIT_INCONCLUSIVE = 2
EXIT_HARNESS_FAILURE = 3

# Boundary names recorded by the conductor.
REQUEST_ACCEPTED = "request_accepted"
LANE_DISPATCHED = "lane_dispatched"
SOURCE_SNAPSHOT_START = "source_snapshot_start"
SOURCE_SNAPSHOT_END = "source_snapshot_end"
PREPARE_START = "prepare_start"
PREPARE_END = "prepare_end"
SLOT_WAIT_START = "slot_wait_start"
SLOT_WAIT_END = "slot_wait_end"
POPEN_BEFORE = "popen_before"
POPEN_AFTER = "popen_after"
FIRST_OUTPUT = "first_output"  # derived from the first observed record
EXIT_OBSERVED = "exit_observed"
PROVENANCE_START = "provenance_start"
PROVENANCE_END = "provenance_end"
LANE_RELEASED = "lane_released"
# The daemon writes the job's ``$ argv`` line straight to the log, not through
# the process output; record it with ``metadata={"command": text}`` so it opens
# a command segment without counting as process output.
COMMAND_START = "command_start"

KNOWN_BOUNDARIES = frozenset({
    REQUEST_ACCEPTED, LANE_DISPATCHED, SOURCE_SNAPSHOT_START, SOURCE_SNAPSHOT_END,
    PREPARE_START, PREPARE_END, SLOT_WAIT_START, SLOT_WAIT_END, POPEN_BEFORE,
    POPEN_AFTER, EXIT_OBSERVED, PROVENANCE_START, PROVENANCE_END, LANE_RELEASED,
    COMMAND_START,
})

# (interval name, start boundary, end boundary). Same-process monotonic only.
INTERVAL_DEFINITIONS: tuple[tuple[str, str, str], ...] = (
    ("queueWait", REQUEST_ACCEPTED, LANE_DISPATCHED),
    ("sourceSnapshot", SOURCE_SNAPSHOT_START, SOURCE_SNAPSHOT_END),
    ("prepare", PREPARE_START, PREPARE_END),
    ("spawn", POPEN_BEFORE, POPEN_AFTER),
    ("spawnToFirstOutput", POPEN_AFTER, FIRST_OUTPUT),
    ("processObserved", POPEN_AFTER, EXIT_OBSERVED),
    ("postRunProvenance", PROVENANCE_START, PROVENANCE_END),
    ("exitToLaneRelease", EXIT_OBSERVED, LANE_RELEASED),
    ("acceptedToLaneRelease", REQUEST_ACCEPTED, LANE_RELEASED),
)
INTERVAL_NAMES = tuple(name for name, _, _ in INTERVAL_DEFINITIONS)


class MetricsError(Exception):
    """Base class for every error this module raises deliberately."""


# ---------------------------------------------------------------------------
# Spans


def span(ns: int | None, quality: str, **extra: Any) -> dict[str, Any]:
    """Build a span, enforcing ``ns is None`` <=> null quality."""
    if quality not in QUALITY_LABELS:
        raise MetricsError(f"unknown quality label: {quality!r}")
    if ns is None:
        if quality not in NULL_QUALITIES:
            raise MetricsError(f"missing value labelled {quality!r}")
    else:
        if quality in NULL_QUALITIES:
            raise MetricsError(f"value {ns!r} labelled {quality!r}")
        if isinstance(ns, bool) or not isinstance(ns, int):
            raise MetricsError(f"span value must be integer nanoseconds, got {ns!r}")
    result: dict[str, Any] = {"ns": ns, "quality": quality}
    result.update(extra)
    return result


def unavailable(reason: str | None = None) -> dict[str, Any]:
    return span(None, UNAVAILABLE, reason=reason) if reason else span(None, UNAVAILABLE)


def not_applicable() -> dict[str, Any]:
    return span(None, NOT_APPLICABLE)


def iter_spans(payload: Any) -> Iterator[dict[str, Any]]:
    """Yield every span-shaped mapping inside ``payload`` (for invariant checks)."""
    if isinstance(payload, Mapping):
        if "quality" in payload and "ns" in payload:
            yield payload  # type: ignore[misc]
        for value in payload.values():
            yield from iter_spans(value)
    elif isinstance(payload, (list, tuple)):
        for value in payload:
            yield from iter_spans(value)


def _seconds_to_ns(text: str) -> int:
    return int(round(float(text) * 1_000_000_000))


# ---------------------------------------------------------------------------
# Record splitting


class OutputRecord(NamedTuple):
    seq: int
    receive_ns: int
    text: str
    delimiter: str  # "lf" | "crlf" | "cr" | "eof"
    truncated: bool = False


_DELIMITER_RE = re.compile(rb"\r\n|\r|\n")
_SPLIT_BYTES_RE = re.compile(rb"(\r\n|\r|\n)")
_SPLIT_TEXT_RE = re.compile(r"\r\n|\r|\n")
_DELIMITER_KINDS = {b"\n": "lf", b"\r\n": "crlf", b"\r": "cr"}
_tuple_new = tuple.__new__
# Reads smaller than this use the reference loop (bulk setup costs more).
_BULK_MIN_BYTES = 4096


class RecordSplitter:
    """Streaming bytes -> records. Not thread-safe; one per output reader.

    Records end at ``\\n``, ``\\r\\n`` or a bare ``\\r``. A ``\\r`` that ends a
    read emits its record immediately and swallows one ``\\n`` at the start of
    the next read. Splits only happen on ASCII bytes, so multi-byte UTF-8
    sequences split across reads are reassembled before decoding. A pending
    record is capped at ``max_pending`` bytes; the excess is dropped and the
    record is marked truncated. A record completed by a later read takes that
    read's receive time.
    """

    def __init__(self, max_pending: int = MAX_PENDING_RECORD_BYTES, first_seq: int = 0) -> None:
        if max_pending <= 0:
            raise MetricsError("max_pending must be positive")
        self.max_pending = max_pending
        self._pending = bytearray()
        self._truncated = False
        self._swallow_lf = False
        self._seq = first_seq
        self.dropped_bytes = 0

    def _append(self, piece: bytes) -> None:
        room = self.max_pending - len(self._pending)
        if len(piece) <= room:
            self._pending += piece
            return
        if room > 0:
            self._pending += piece[:room]
        self.dropped_bytes += len(piece) - max(room, 0)
        self._truncated = True

    def _emit(self, receive_ns: int, delimiter: str) -> OutputRecord:
        record = OutputRecord(
            seq=self._seq,
            receive_ns=receive_ns,
            text=bytes(self._pending).decode("utf-8", errors="replace"),
            delimiter=delimiter,
            truncated=self._truncated,
        )
        self._seq += 1
        self._pending = bytearray()
        self._truncated = False
        return record

    def feed(self, data: bytes, receive_ns: int) -> list[OutputRecord]:
        start = 0
        if self._swallow_lf and data[:1] == b"\n":
            start = 1
        if data:
            self._swallow_lf = False
        if self._truncated:
            return self._feed_slow(data, start, receive_ns)
        size = len(data)
        if start == 0 and not self._pending and size and data[-1] == 0x0A and data.find(b"\n") == size - 1:
            # One record per read (pipe ``readline()``), ending in LF or a lone CRLF.
            first_cr = data.find(b"\r")
            if first_cr == -1:
                body, delimiter = data[:-1], "lf"
            elif first_cr == size - 2:
                body, delimiter = data[:-2], "crlf"
            else:
                body = None
            if body is not None and len(body) <= self.max_pending:
                record = _tuple_new(OutputRecord, (self._seq, receive_ns, body.decode("utf-8", errors="replace"), delimiter, False))
                self._seq += 1
                return [record]
        if size < _BULK_MIN_BYTES:
            # Small reads with several records: the reference loop is cheaper.
            return self._feed_slow(data, start, receive_ns)
        last = max(data.rfind(b"\n"), data.rfind(b"\r"))
        if last < start:
            self._append(data[start:])
            return []
        # Bulk path: split complete records in C; any record that would hit
        # the pending cap falls back to the reference loop for this read.
        region = bytes(self._pending) + data[start:last + 1] if self._pending else data[start:last + 1]
        parts = _SPLIT_BYTES_RE.split(region)
        if max(map(len, parts)) > self.max_pending:
            return self._feed_slow(data, start, receive_ns)
        # Delimiters are ASCII and never part of a UTF-8 sequence, so decoding
        # the region once equals decoding each record separately.
        texts = _SPLIT_TEXT_RE.split(region.decode("utf-8", errors="replace"))
        texts.pop()
        delimiters = parts[1::2]
        count = len(delimiters)
        if len(texts) != count:
            raise MetricsError("record split mismatch after decoding")
        if delimiters[-1] == b"\r" and last == len(data) - 1:
            self._swallow_lf = True
        first_seq = self._seq
        self._seq += count
        self._pending = bytearray()
        if last + 1 < len(data):
            self._append(data[last + 1:])
        return list(map(
            _tuple_new,
            repeat(OutputRecord, count),
            zip(
                range(first_seq, first_seq + count),
                repeat(receive_ns, count),
                texts,
                map(_DELIMITER_KINDS.__getitem__, delimiters),
                repeat(False, count),
            ),
        ))

    def _feed_slow(self, data: bytes, start: int, receive_ns: int) -> list[OutputRecord]:
        """Reference per-record loop (also used for truncation)."""
        records: list[OutputRecord] = []
        end = len(data)
        for match in _DELIMITER_RE.finditer(data, start):
            self._append(data[start:match.start()])
            token = match.group(0)
            if token == b"\r\n":
                delimiter = "crlf"
            elif token == b"\r":
                delimiter = "cr"
                if match.end() == end:
                    self._swallow_lf = True
            else:
                delimiter = "lf"
            records.append(self._emit(receive_ns, delimiter))
            start = match.end()
        if start < end:
            self._append(data[start:])
        return records

    def finish(self, receive_ns: int) -> list[OutputRecord]:
        """Flush a final record that has no delimiter (EOF)."""
        self._swallow_lf = False
        if not self._pending and not self._truncated:
            return []
        return [self._emit(receive_ns, "eof")]


# ---------------------------------------------------------------------------
# Marker parsing

_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")
_EVENT_ENCODER = json.JSONEncoder(separators=(",", ":"), ensure_ascii=False)
_LEADING_ANSI_RE = re.compile(r"(?:\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_])+")
# First visible characters that can begin a marker (see ``classify_record``).
_MARKER_FIRST_CHARS = frozenset("[$+=BT \t")
_STEP_RE = re.compile(r"\[(\d+)/(\d+)\] (\S+)(?: (.*))?$")
_BUILD_COMPLETE_RE = re.compile(r"Build (?:of product '([^']*)' )?complete! \((\d+(?:\.\d+)?)s\)")
_SUITE_RE = re.compile(
    r"Test Suite '(.+)' (started|passed|failed) at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})"
)
_CASE_RE = re.compile(r"Test Case '(.+)' (started|passed|failed|skipped)")
_EXECUTED_RE = re.compile(
    r"[ \t]+Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\) in "
    r"(\d+(?:\.\d+)?) \((\d+(?:\.\d+)?)\) seconds"
)
_SWIFT_COMMAND_TOKENS = frozenset({
    "canonical_swift.sh", "swift", "swift-build", "swift-test", "xctest",
})

# Marker kinds.
K_COMMAND = "command"
K_HEADING = "heading"
K_BUILD_START = "build_start"
K_PLANNING = "planning"
K_WRITE = "write"
K_COMPILE = "compile"
K_EMIT_MODULE = "emit_module"
K_LINK = "link"
K_STEP = "step"
K_BUILD_COMPLETE = "build_complete"
K_SUITE = "suite"
K_METHOD = "method"
K_EXECUTED = "executed"
K_PCM_WARNING = "pcm_warning"
BUILD_STEP_KINDS = frozenset({K_PLANNING, K_WRITE, K_COMPILE, K_EMIT_MODULE, K_LINK, K_STEP})


class Marker(NamedTuple):
    kind: str
    text: str = ""
    module: str = ""
    files: tuple[str, ...] = ()
    name: str = ""
    state: str = ""
    printed_at: str = ""
    seconds: str = ""
    marker: str = ""


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text) if "\x1b" in text else text


def classify_record(text: str) -> Marker | None:
    """Classify one output record; ``None`` for non-marker records.

    Hot path: most records in a compiling log are erase sequences, colored
    diagnostics or source excerpts. Leading ANSI is skipped by one match, and
    full ANSI substitution only runs on records whose first visible character
    can start a marker; ``.pcm`` detection works on the raw text.
    """
    if not text:
        return None
    first = text[0]
    if first == "\x1b":
        leading = _LEADING_ANSI_RE.match(text)
        start = leading.end() if leading else 0
        first = text[start:start + 1]
        if first not in _MARKER_FIRST_CHARS:
            return _pcm_marker(text)
        text = text[start:]
    if first == " " or first == "\t":
        if "Executed " in text:
            match = _EXECUTED_RE.match(strip_ansi(text))
            if match is not None:
                return Marker(K_EXECUTED, seconds=match.group(4))
        return _pcm_marker(text)
    if first not in _MARKER_FIRST_CHARS:
        return _pcm_marker(text)
    if "\x1b" in text:
        text = _ANSI_RE.sub("", text)
    if first == "[":
        match = _STEP_RE.match(text.rstrip())
        if match is None:
            return _pcm_marker(text)
        verb, rest = match.group(3), match.group(4) or ""
        if verb == "Planning":
            return Marker(K_PLANNING)
        if verb == "Write":
            return Marker(K_WRITE, text=rest)
        if verb == "Compiling":
            module, _, files = rest.partition(" ")
            if not module or not files:
                return Marker(K_STEP, text=verb)
            parts = files.split(", ")
            if "" in parts:
                parts = [name for name in parts if name]
            return Marker(K_COMPILE, module=module, files=tuple(parts))
        if verb == "Emitting":
            module = rest[len("module "):] if rest.startswith("module ") else rest
            return Marker(K_EMIT_MODULE, module=module)
        if verb == "Linking":
            return Marker(K_LINK, name=rest)
        return Marker(K_STEP, text=verb)
    if first == "$" or first == "+":
        if len(text) > 2 and text[1] == " ":
            command = text[2:].rstrip()
            return Marker(K_COMMAND, text=command, marker=first) if command else None
        return None
    if first == "=":
        if text.startswith("==> "):
            return Marker(K_HEADING, text=text[4:].rstrip())
        return None
    if first == "B":
        if text.startswith("Building for "):
            return Marker(K_BUILD_START)
        match = _BUILD_COMPLETE_RE.match(text)
        if match is not None:
            return Marker(K_BUILD_COMPLETE, name=match.group(1) or "", seconds=match.group(2))
        return None
    if first == "T":
        if text.startswith("Test Suite '"):
            match = _SUITE_RE.match(text)
            if match is not None:
                return Marker(K_SUITE, name=match.group(1), state=match.group(2), printed_at=match.group(3))
            return None
        if text.startswith("Test Case '"):
            match = _CASE_RE.match(text)
            if match is not None:
                return Marker(K_METHOD, name=match.group(1), state=match.group(2))
        return None
    return _pcm_marker(text)


_PCM_MARKER = Marker(K_PCM_WARNING)


def _pcm_marker(text: str) -> Marker | None:
    if ".pcm" in text and "No such file" in text:
        return _PCM_MARKER
    return None


def is_swift_command(command: str) -> bool:
    for token in command.split():
        if token.rsplit("/", 1)[-1] in _SWIFT_COMMAND_TOKENS:
            return True
    return False


def parse_xctest_timestamp(text: str, tz: tzinfo | None = None) -> int | None:
    """Convert XCTest's printed local timestamp to wall-clock epoch ns."""
    try:
        moment = datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None
    if tz is not None:
        moment = moment.replace(tzinfo=tz)
    return int(round(moment.timestamp() * 1_000_000)) * 1000


def _bounded(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "\u2026"


# ---------------------------------------------------------------------------
# Interval derivation


@dataclass(frozen=True)
class Boundary:
    name: str
    ns: int
    process: str
    metadata: Mapping[str, Any]


def _first_boundaries(boundaries: Sequence[Boundary]) -> dict[str, Boundary]:
    first: dict[str, Boundary] = {}
    for boundary in boundaries:
        first.setdefault(boundary.name, boundary)
    return first


def _interval(start: Boundary | None, end: Boundary | None, quality: str) -> dict[str, Any]:
    if start is None or end is None:
        missing = [label for label, value in (("start", start), ("end", end)) if value is None]
        return unavailable("missing_" + "_and_".join(missing))
    if start.process != end.process:
        return unavailable("cross_process")
    if end.ns < start.ns:
        return unavailable("non_monotonic")
    return span(end.ns - start.ns, quality)


def derive_intervals(
    boundaries: Sequence[Boundary],
    *,
    not_applicable_names: Iterable[str] = (),
    quality: str = MEASURED_WALL,
) -> dict[str, dict[str, Any]]:
    """Derive the fixed interval table from first-occurrence boundaries."""
    skip = set(not_applicable_names)
    first = _first_boundaries(boundaries)
    result: dict[str, dict[str, Any]] = {}
    for name, start_name, end_name in INTERVAL_DEFINITIONS:
        if name in skip:
            result[name] = not_applicable()
            continue
        start, end = first.get(start_name), first.get(end_name)
        result[name] = _interval(start, end, OBSERVED_WALL if FIRST_OUTPUT in (start_name, end_name) else quality)
    return result


def derive_slot_waits(boundaries: Sequence[Boundary]) -> list[dict[str, Any]]:
    """Pair slot-wait start/end boundaries in order per ``metadata['slot']``."""
    open_waits: dict[str, list[Boundary]] = {}
    waits: list[dict[str, Any]] = []
    for boundary in boundaries:
        if boundary.name not in (SLOT_WAIT_START, SLOT_WAIT_END):
            continue
        slot = str(boundary.metadata.get("slot", ""))
        if boundary.name == SLOT_WAIT_START:
            open_waits.setdefault(slot, []).append(boundary)
            continue
        queue = open_waits.get(slot)
        start = queue.pop(0) if queue else None
        contended = boundary.metadata.get("contended")
        if contended is None and start is not None:
            contended = start.metadata.get("contended")
        entry = _interval(start, boundary, MEASURED_WALL)
        entry.update({"slot": slot, "contended": contended if isinstance(contended, bool) else None})
        waits.append(entry)
    for slot, queue in open_waits.items():
        for start in queue:
            entry = unavailable("missing_end")
            entry.update({"slot": slot, "contended": None})
            waits.append(entry)
    return waits


# ---------------------------------------------------------------------------
# Per-segment state


class _Segment:
    __slots__ = (
        "index", "opened_by", "command", "context", "open_ns", "close_ns",
        "first_planning_ns", "first_work_ns", "build_start_ns", "links", "build_complete_ns",
        "reported_build_ns", "build_product", "compile_records", "write_records",
        "modules", "modules_dropped", "first_suite_ns", "first_suite_printed", "suite_depth",
        "xctest_end_ns", "xctest_end_printed", "first_method_ns", "suites_started",
        "executed_reported_ns", "pcm_warnings",
    )

    def __init__(self, index: int, opened_by: str, command: str | None, context: str | None, open_ns: int) -> None:
        self.index = index
        self.opened_by = opened_by
        self.command = command
        self.context = context
        self.open_ns = open_ns
        self.close_ns: int | None = None
        self.first_planning_ns: int | None = None
        self.first_work_ns: int | None = None
        self.build_start_ns: int | None = None
        self.links: dict[str, int] = {}
        self.build_complete_ns: int | None = None
        self.reported_build_ns: int | None = None
        self.build_product: str | None = None
        self.compile_records = 0
        self.write_records = 0
        self.modules: dict[str, "_ModuleAggregate"] = {}
        self.modules_dropped = 0
        self.first_suite_ns: int | None = None
        self.first_suite_printed: str | None = None
        self.suite_depth = 0
        self.xctest_end_ns: int | None = None
        self.xctest_end_printed: str | None = None
        self.first_method_ns: int | None = None
        self.suites_started = 0
        self.executed_reported_ns: int | None = None
        self.pcm_warnings = 0

    @property
    def has_build_activity(self) -> bool:
        return self.build_start_ns is not None or self.first_planning_ns is not None or self.first_work_ns is not None

    @property
    def in_xctest(self) -> bool:
        return self.suite_depth > 0


class _ModuleAggregate:
    __slots__ = ("files", "exact", "emitted")

    def __init__(self) -> None:
        self.files: set[str] = set()
        self.exact = True
        self.emitted = False


class _OperationAggregate:
    __slots__ = ("calls", "known_ns", "missing", "qualities", "counters", "counters_dropped")

    def __init__(self) -> None:
        self.calls = 0
        self.known_ns = 0
        self.missing = 0
        self.qualities: set[str] = set()
        self.counters: dict[str, int] = {}
        self.counters_dropped = 0


def _since(start: int | None, end: int | None, quality: str = OBSERVED_WALL) -> dict[str, Any]:
    if start is None or end is None:
        return unavailable()
    if end < start:
        return unavailable("non_monotonic")
    return span(end - start, quality)


# ---------------------------------------------------------------------------
# Recorder


class PipelineRecorder:
    """Bounded per-job recorder. Thread-safe via a private lock.

    Lock order: the caller must not hold its scheduler lock (``self.condition``)
    while calling any recorder method, and the recorder never calls back into
    the caller while holding its own lock.
    """

    def __init__(
        self,
        *,
        origin_ns: int,
        process: str = "daemon",
        enabled: bool = True,
        wall_anchor: tuple[int, int] | None = None,
        xctest_tz: tzinfo | None = None,
        not_applicable_intervals: Iterable[str] = (),
        dsym_policy: str | None = None,
        max_events: int = MAX_EVENTS,
        max_event_bytes: int = MAX_EVENT_BYTES,
        max_file_identities: int = MAX_FILE_IDENTITIES,
        max_file_identity_bytes: int = MAX_FILE_IDENTITY_TEXT_BYTES,
        max_modules: int = MAX_MODULE_AGGREGATES,
        max_segments: int = MAX_SEGMENTS,
    ) -> None:
        self._lock = threading.Lock()
        self.enabled = bool(enabled)
        self.process = _bounded(str(process), MAX_NAME_CHARS)
        self.origin_ns = int(origin_ns)
        self._wall_anchor = wall_anchor  # (wall epoch ns, monotonic ns) taken together
        self._xctest_tz = xctest_tz
        self._not_applicable = tuple(not_applicable_intervals)
        self._dsym_policy = dsym_policy
        self._max_events = max_events
        self._max_event_bytes = max_event_bytes
        self._max_identities = max_file_identities
        self._max_identity_bytes = max_file_identity_bytes
        self._max_modules = max_modules
        self._max_segments = max_segments

        self._events: list[dict[str, Any]] = []
        self._event_bytes = 0
        self._events_dropped = 0
        self._boundaries: list[Boundary] = []
        self._boundaries_dropped = 0
        self._operations: dict[tuple[str, str], _OperationAggregate] = {}
        self._operations_dropped = 0
        self._segments: list[_Segment] = []
        self._segments_dropped = 0
        self._current: _Segment | None = None
        self._current_dropped = False
        self._pending_command: tuple[str, int] | None = None
        self._context: str | None = None
        self._command_count = 0
        self._ignored_command_markers = 0
        self._module_count = 0
        self._identity_count = 0
        self._identity_bytes = 0
        # Once any identity misses the bounds, later compile observations are
        # not hashed: their modules become inexact (lower-bound counts).
        self._identities_saturated = False
        self._unresolved_file_observations = 0
        self._truncated_compile_records = 0
        self._records = 0
        self._first_record_ns: int | None = None
        self._last_record_ns: int | None = None
        self._truncated_records = 0
        # Output observed through ``OutputTelemetryCursor``: open cursors, how
        # many ever attached, splitter-equivalent dropped bytes, stream errors.
        self._output_open = 0
        self._output_cursors = 0
        self._output_dropped_bytes = 0
        self._output_error: str | None = None
        self._invalid_inputs = 0
        self._late_observations = 0
        self._error: str | None = None
        self._finalized: dict[str, Any] | None = None

    # -- containment ---------------------------------------------------------

    def _active(self) -> bool:
        if not self.enabled or self._error is not None:
            return False
        if self._finalized is not None:
            self._late_observations += 1
            return False
        return True

    def _fail(self, exc: BaseException) -> None:
        self._error = _bounded(f"{type(exc).__name__}: {exc}", 256)

    @property
    def failed(self) -> bool:
        return self._error is not None

    # -- events --------------------------------------------------------------

    def _emit(self, kind: str, at_ns: int, /, **fields: Any) -> None:
        if len(self._events) >= self._max_events:
            self._events_dropped += 1
            return
        event = {"t": at_ns - self.origin_ns, "k": kind}
        event.update(fields)
        size = len(_EVENT_ENCODER.encode(event).encode("utf-8")) + 1
        if self._event_bytes + size > self._max_event_bytes:
            self._events_dropped += 1
            return
        self._event_bytes += size
        self._events.append(event)

    # -- public API ----------------------------------------------------------

    def record_boundary(self, name: str, monotonic_ns: int, metadata: Mapping[str, Any] | None = None) -> None:
        with self._lock:
            if not self._active():
                return
            try:
                if not isinstance(name, str) or not name or len(name) > MAX_NAME_CHARS:
                    self._invalid_inputs += 1
                    return
                if isinstance(monotonic_ns, bool) or not isinstance(monotonic_ns, int):
                    self._invalid_inputs += 1
                    return
                meta = _bounded_metadata(metadata)
                if len(self._boundaries) >= self._max_events:
                    self._boundaries_dropped += 1
                    return
                self._boundaries.append(Boundary(name, monotonic_ns, self.process, meta))
                fields: dict[str, Any] = {"name": name}
                if meta:
                    fields["meta"] = dict(meta)
                self._emit("boundary", monotonic_ns, **fields)
                command = meta.get("command")
                if name == COMMAND_START and isinstance(command, str) and command:
                    self._apply_marker(Marker(K_COMMAND, text=command, marker="$"), monotonic_ns)
            except Exception as exc:  # noqa: BLE001 - containment by design
                self._fail(exc)

    def observe_records(self, records: Iterable[OutputRecord | Mapping[str, Any]]) -> None:
        with self._lock:
            if not self._active():
                return
            # Hot loop: locals only; counters are written back in ``finally``.
            classify = classify_record
            apply_marker = self._apply_marker
            seen = 0
            truncated_seen = 0
            invalid = 0
            last_ns = self._last_record_ns
            try:
                for record in records:
                    if isinstance(record, OutputRecord):
                        _, ns, text, _, truncated = record
                    else:
                        text = record.get("text")
                        ns = record.get("receive_ns", record.get("receiveNs"))
                        truncated = bool(record.get("truncated", False))
                    if (type(ns) is not int or type(text) is not str) and (
                        not isinstance(text, str) or isinstance(ns, bool) or not isinstance(ns, int)
                    ):
                        invalid += 1
                        continue
                    seen += 1
                    if truncated:
                        truncated_seen += 1
                    if self._first_record_ns is None:
                        self._first_record_ns = ns
                    last_ns = ns
                    marker = classify(text)
                    if marker is not None:
                        apply_marker(marker, ns, truncated)
            except Exception as exc:  # noqa: BLE001
                self._fail(exc)
            finally:
                self._records += seen
                self._truncated_records += truncated_seen
                self._invalid_inputs += invalid
                self._last_record_ns = last_ns

    def record_operation(
        self,
        name: str,
        duration_ns: int | None,
        counters: Mapping[str, int] | None = None,
        origin: str = "",
        *,
        quality: str = MEASURED_WALL,
        monotonic_ns: int | None = None,
    ) -> None:
        with self._lock:
            if not self._active():
                return
            try:
                if (
                    not isinstance(name, str) or not name or len(name) > MAX_NAME_CHARS
                    or not isinstance(origin, str) or len(origin) > MAX_NAME_CHARS
                    or quality not in VALUE_QUALITIES
                    or (duration_ns is not None and (isinstance(duration_ns, bool) or not isinstance(duration_ns, int) or duration_ns < 0))
                ):
                    self._invalid_inputs += 1
                    return
                key = (name, origin)
                aggregate = self._operations.get(key)
                if aggregate is None:
                    if len(self._operations) >= MAX_OPERATION_AGGREGATES:
                        self._operations_dropped += 1
                        return
                    aggregate = self._operations[key] = _OperationAggregate()
                aggregate.calls += 1
                if duration_ns is None:
                    aggregate.missing += 1
                else:
                    aggregate.known_ns += duration_ns
                    aggregate.qualities.add(quality)
                for counter, value in (counters or {}).items():
                    if not isinstance(counter, str) or isinstance(value, bool) or not isinstance(value, int):
                        self._invalid_inputs += 1
                        continue
                    if counter not in aggregate.counters and len(aggregate.counters) >= MAX_COUNTERS_PER_OPERATION:
                        aggregate.counters_dropped += 1
                        continue
                    aggregate.counters[counter] = aggregate.counters.get(counter, 0) + value
                if monotonic_ns is not None and isinstance(monotonic_ns, int):
                    self._emit("operation", monotonic_ns, name=name, origin=origin, ns=duration_ns, quality=quality if duration_ns is not None else UNAVAILABLE)
            except Exception as exc:  # noqa: BLE001
                self._fail(exc)

    def operation_sink(self, origin: str) -> Callable[..., None]:
        """Return ``sink(name, duration_ns, counters=None, **kw)`` bound to ``origin``."""
        def sink(name: str, duration_ns: int | None, counters: Mapping[str, int] | None = None, **kwargs: Any) -> None:
            self.record_operation(name, duration_ns, counters, origin, **kwargs)
        return sink

    def events(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._events)

    def finalize(self) -> dict[str, Any]:
        """Return the schema-1 ``phaseMetrics`` payload. Idempotent."""
        with self._lock:
            if self._finalized is not None:
                return self._finalized
            if not self.enabled:
                self._finalized = {"schema": SCHEMA_VERSION, "status": "disabled", "process": self.process}
                return self._finalized
            if self._error is None:
                try:
                    self._finalized = self._build_payload()
                    return self._finalized
                except Exception as exc:  # noqa: BLE001
                    self._fail(exc)
            self._finalized = self._failed_payload()
            return self._finalized

    # -- marker application --------------------------------------------------

    def _open_segment(self, opened_by: str, command: str | None, open_ns: int) -> _Segment | None:
        self._pending_command = None
        if len(self._segments) >= self._max_segments:
            self._segments_dropped += 1
            self._current = None
            self._current_dropped = True
            return None
        segment = _Segment(len(self._segments), opened_by, command, self._context, open_ns)
        self._segments.append(segment)
        self._current = segment
        self._current_dropped = False
        fields: dict[str, Any] = {"segment": segment.index, "openedBy": opened_by}
        if command is not None:
            fields["command"] = _bounded(command, 160)
        self._emit("segment_open", open_ns, **fields)
        return segment

    def _close_current(self, ns: int) -> None:
        if self._current is not None and self._current.close_ns is None:
            self._current.close_ns = ns
        self._current = None
        self._current_dropped = False

    def _segment_for(self, marker: Marker, ns: int) -> _Segment | None:
        is_build_open = marker.kind in (K_BUILD_START, K_PLANNING)
        current = self._current
        if current is not None:
            if is_build_open and current.build_complete_ns is not None:
                self._close_current(ns)
                return self._open_segment("build_start", None, ns)
            return current
        if self._current_dropped:
            return None
        pending = self._pending_command
        if pending is not None:
            command, command_ns = pending
            build_type = marker.kind in BUILD_STEP_KINDS or marker.kind in (K_BUILD_START, K_BUILD_COMPLETE)
            if is_swift_command(command) or not build_type:
                return self._open_segment("command", command, command_ns)
            return self._open_segment("build_start", None, ns)
        return self._open_segment("build_start" if is_build_open else "implicit", None, ns)

    def _apply_marker(self, marker: Marker, ns: int, truncated: bool = False) -> None:
        """Apply one classified marker; ``truncated`` means its record hit the pending cap."""
        kind = marker.kind
        if kind == K_COMMAND:
            if self._current is not None and self._current.in_xctest:
                self._ignored_command_markers += 1
                return
            command = _bounded(marker.text, MAX_COMMAND_CHARS)
            self._command_count += 1
            self._close_current(ns)
            self._pending_command = (command, ns)
            self._emit("command", ns, marker=marker.marker, command=_bounded(command, 160))
            return
        if kind == K_HEADING:
            self._context = _bounded(marker.text, MAX_CONTEXT_CHARS)
            self._emit("heading", ns, text=_bounded(marker.text, 160))
            return
        segment = self._segment_for(marker, ns)
        if segment is None:
            return
        if kind == K_BUILD_START:
            if segment.build_start_ns is None:
                segment.build_start_ns = ns
                self._emit("build_start", ns, segment=segment.index)
        elif kind == K_PLANNING:
            if segment.first_planning_ns is None:
                segment.first_planning_ns = ns
                self._emit("planning", ns, segment=segment.index)
        elif kind in BUILD_STEP_KINDS:
            if segment.first_work_ns is None:
                segment.first_work_ns = ns
                self._emit("first_build_work", ns, segment=segment.index)
            if kind == K_COMPILE:
                segment.compile_records += 1
                self._record_compile(segment, marker.module, marker.files, truncated)
            elif kind == K_WRITE:
                segment.write_records += 1
            elif kind == K_EMIT_MODULE:
                aggregate = self._module(segment, marker.module)
                if aggregate is not None:
                    aggregate.emitted = True
            elif kind == K_LINK:
                product = _bounded(marker.name, MAX_NAME_CHARS)
                if product not in segment.links and len(segment.links) < self._max_modules:
                    segment.links[product] = ns
                    self._emit("link", ns, segment=segment.index, product=product)
        elif kind == K_BUILD_COMPLETE:
            if segment.build_complete_ns is None:
                segment.build_complete_ns = ns
                segment.reported_build_ns = _seconds_to_ns(marker.seconds)
                segment.build_product = _bounded(marker.name, MAX_NAME_CHARS) or None
                self._emit("build_complete", ns, segment=segment.index, reportedNs=segment.reported_build_ns)
        elif kind == K_SUITE:
            if marker.state == "started":
                if segment.first_suite_ns is None:
                    segment.first_suite_ns = ns
                    segment.first_suite_printed = marker.printed_at
                segment.suite_depth += 1
                segment.suites_started += 1
            else:
                if segment.suite_depth > 0:
                    segment.suite_depth -= 1
                if segment.suite_depth == 0 and segment.first_suite_ns is not None:
                    segment.xctest_end_ns = ns
                    segment.xctest_end_printed = marker.printed_at
            self._emit("suite", ns, segment=segment.index, state=marker.state, name=_bounded(marker.name, 160))
        elif kind == K_METHOD:
            # Only the first started method per segment is an observation; the
            # contract needs first-method timing, not one event per method.
            if marker.state == "started" and segment.first_method_ns is None:
                segment.first_method_ns = ns
                self._emit("first_method", ns, segment=segment.index, name=_bounded(marker.name, 200))
        elif kind == K_EXECUTED:
            segment.executed_reported_ns = _seconds_to_ns(marker.seconds)
        elif kind == K_PCM_WARNING:
            segment.pcm_warnings += 1
            self._emit("pcm_warning", ns, segment=segment.index)

    def _module(self, segment: _Segment, module: str) -> _ModuleAggregate | None:
        aggregate = segment.modules.get(module)
        if aggregate is not None:
            return aggregate
        if self._module_count >= self._max_modules:
            segment.modules_dropped += 1
            return None
        self._module_count += 1
        aggregate = segment.modules[_bounded(module, MAX_NAME_CHARS)] = _ModuleAggregate()
        return aggregate

    def _record_compile(self, segment: _Segment, module: str, files: tuple[str, ...], truncated: bool = False) -> None:
        aggregate = self._module(segment, module)
        if truncated:
            # The record was cut at the pending cap: its last name may be a
            # prefix and later names are lost, so the count cannot be exact.
            self._truncated_compile_records += 1
            files = files[:-1]
            if aggregate is not None:
                aggregate.exact = False
        if aggregate is None:
            return
        if self._identities_saturated:
            aggregate.exact = False
            self._unresolved_file_observations += len(files)
            return
        known = aggregate.files
        for index, name in enumerate(files):
            if name in known:
                continue
            size = len(module.encode("utf-8")) + len(name.encode("utf-8"))
            if self._identity_count >= self._max_identities or self._identity_bytes + size > self._max_identity_bytes:
                self._identities_saturated = True
                aggregate.exact = False
                self._unresolved_file_observations += len(files) - index
                return
            known.add(name)
            self._identity_count += 1
            self._identity_bytes += size

    # -- payload -------------------------------------------------------------

    def _segment_payload(self, segment: _Segment) -> dict[str, Any]:
        reported = (
            span(segment.reported_build_ns, REPORTED_DURATION)
            if segment.reported_build_ns is not None else unavailable()
        )
        if segment.build_complete_ns is not None and segment.reported_build_ns is not None:
            residual = span(
                (segment.build_complete_ns - segment.open_ns) - segment.reported_build_ns,
                OBSERVED_WALL,
                signed=True,
            )
        else:
            residual = unavailable()
        if segment.first_planning_ns is not None:
            planning = _since(segment.first_planning_ns, segment.first_work_ns)
        elif segment.build_complete_ns is not None:
            planning = not_applicable()
        else:
            planning = unavailable()
        last_link_ns = max(segment.links.values()) if segment.links else None
        if segment.executed_reported_ns is not None:
            xctest_reported = span(segment.executed_reported_ns, REPORTED_DURATION)
        else:
            xctest_reported = unavailable()
        printed_span = unavailable()
        if segment.first_suite_printed and segment.xctest_end_printed:
            start = parse_xctest_timestamp(segment.first_suite_printed, self._xctest_tz)
            end = parse_xctest_timestamp(segment.xctest_end_printed, self._xctest_tz)
            if start is not None and end is not None and end >= start:
                printed_span = span(end - start, REPORTED_DURATION)
        skew = unavailable()
        if self._wall_anchor is not None and segment.first_suite_printed and segment.first_suite_ns is not None:
            printed_wall = parse_xctest_timestamp(segment.first_suite_printed, self._xctest_tz)
            if printed_wall is not None:
                anchor_wall, anchor_mono = self._wall_anchor
                skew = span(segment.first_suite_ns - (anchor_mono + (printed_wall - anchor_wall)), OBSERVED_WALL, signed=True)
        modules = {
            name: {"compiledFiles": len(agg.files), "exact": agg.exact, "emittedModule": agg.emitted}
            for name, agg in sorted(segment.modules.items())
        }
        return {
            "index": segment.index,
            "openedBy": segment.opened_by,
            "command": segment.command,
            "context": segment.context,
            "openOffsetNs": segment.open_ns - self.origin_ns,
            "segmentWall": _since(segment.open_ns, segment.close_ns),
            "timeToFirstBuildWork": _since(segment.open_ns, segment.first_work_ns),
            "planning": planning,
            "reportedBuild": reported,
            "buildProduct": segment.build_product,
            "preCompletionResidual": residual,
            "linkToBuildComplete": _since(last_link_ns, segment.build_complete_ns),
            "linkedProducts": sorted(segment.links),
            "buildCompleteToFirstSuite": _since(segment.build_complete_ns, segment.first_suite_ns),
            "buildCompleteToFirstMethod": _since(segment.build_complete_ns, segment.first_method_ns),
            "xctestObserved": _since(segment.first_suite_ns, segment.xctest_end_ns),
            "xctestPrinted": printed_span,
            "xctestReported": xctest_reported,
            "firstSuitePrintedAt": segment.first_suite_printed,
            "firstSuiteClockSkew": skew,
            "suitesStarted": segment.suites_started,
            "compileRecords": segment.compile_records,
            "writeRecords": segment.write_records,
            "modules": modules,
            "modulesPartial": segment.modules_dropped > 0,
            "compiledFilesExact": segment.modules_dropped == 0 and all(agg.exact for agg in segment.modules.values()),
            "pcmWarnings": segment.pcm_warnings,
            # Step 10 fills these; ``None`` means unknown, never a default policy.
            "dsymPolicy": self._dsym_policy,
            "symbolEvidence": None,
        }

    def _operations_payload(self) -> list[dict[str, Any]]:
        result = []
        for (name, origin), agg in sorted(self._operations.items()):
            if agg.missing:
                total = unavailable("missing_duration")
            elif len(agg.qualities) != 1:
                total = unavailable("mixed_quality")
            else:
                total = span(agg.known_ns, next(iter(agg.qualities)))
            result.append({
                "name": name,
                "origin": origin,
                "calls": agg.calls,
                "callsMissingDuration": agg.missing,
                "total": total,
                "counters": dict(sorted(agg.counters.items())),
                "countersPartial": agg.counters_dropped > 0,
            })
        return result

    def _build_payload(self) -> dict[str, Any]:
        if self._current is not None and self._current.close_ns is None:
            self._current.close_ns = self._last_record_ns
        boundaries = list(self._boundaries)
        if self._first_record_ns is not None:
            boundaries.append(Boundary(FIRST_OUTPUT, self._first_record_ns, self.process, {}))
        partial = {
            "eventsDropped": self._events_dropped,
            "boundariesDropped": self._boundaries_dropped,
            "operationsDropped": self._operations_dropped,
            "segmentsDropped": self._segments_dropped,
            "fileIdentitiesSaturated": self._identities_saturated,
            "unresolvedFileObservations": self._unresolved_file_observations,
            "truncatedCompileRecords": self._truncated_compile_records,
            "modulesDropped": sum(segment.modules_dropped for segment in self._segments),
        }
        output_complete = self._output_open == 0 and self._output_error is None
        if output_complete:
            output: dict[str, Any] = {
                "complete": True,
                "records": self._records,
                "truncatedRecords": self._truncated_records,
                "droppedBytes": self._output_dropped_bytes if self._output_cursors else None,
                "observedSpan": _since(self._first_record_ns, self._last_record_ns),
            }
        else:
            output = {
                "complete": False,
                "records": None,
                "truncatedRecords": None,
                "droppedBytes": None,
                "observedSpan": unavailable("output_failed" if self._output_error else "output_incomplete"),
                "error": self._output_error,
            }
        is_partial = any(partial.values()) or not output_complete
        return {
            "schema": SCHEMA_VERSION,
            "status": "partial" if is_partial else "complete",
            "process": self.process,
            "intervals": derive_intervals(boundaries, not_applicable_names=self._not_applicable),
            "slotWaits": derive_slot_waits(boundaries),
            "operations": self._operations_payload(),
            "output": output,
            "commandCount": self._command_count,
            "ignoredCommandMarkers": self._ignored_command_markers,
            "segments": [self._segment_payload(segment) for segment in self._segments],
            "bounds": dict(partial, eventsPartial=self._events_dropped > 0, segmentsPartial=self._segments_dropped > 0),
            "invalidInputs": self._invalid_inputs,
            "lateObservations": self._late_observations,
            "telemetryError": None,
        }

    def _failed_payload(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA_VERSION,
            "status": "failed",
            "process": self.process,
            "intervals": {name: unavailable("telemetry_failed") for name in INTERVAL_NAMES},
            "slotWaits": [],
            "operations": [],
            "segments": [],
            "telemetryError": self._error,
        }


# ---------------------------------------------------------------------------
# Reader-owned output cursor

_CURSOR_FIRST_CHARS = _MARKER_FIRST_CHARS | frozenset("\x1b")
_CASE_PREFIX = "Test Case '"


class OutputTelemetryCursor:
    """Feed a recorder from the conductor's existing LF-line output path.

    One cursor per output reader; not thread-safe. The conductor keeps its own
    LF framing and decoding and hands each complete line (bytes and the text
    it already decoded) to :meth:`observe_line` before taking its scheduler
    lock, so ordinary records are never split or decoded twice. Bare-CR records
    are found sparsely: after each read :meth:`scan_pending` examines only the
    new bytes of the still-open LF line and emits each CR-terminated record with
    that read's receive time; the later LF line skips the consumed prefix.

    Records, delimiters, truncation and receive times equal ``RecordSplitter``
    fed with the same reads. Marker application takes the recorder's private
    lock only for recognized markers. A method record is skipped (no lock, no
    classification) once the current segment already holds its first method,
    because it could then change nothing. Any exception disables the cursor,
    marks the recorder's output as failed, and never propagates.
    """

    __slots__ = (
        "recorder", "max_pending", "active", "_fast_limit", "_cons_b", "_cons_c", "_scan_b",
        "_swallow", "_records", "_truncated", "_dropped", "_first_ns", "_last_ns",
        "_method_segment", "_closed",
    )

    def __init__(self, recorder: PipelineRecorder, *, max_pending: int = MAX_PENDING_RECORD_BYTES) -> None:
        if max_pending <= 0:
            raise MetricsError("max_pending must be positive")
        self.recorder = recorder
        self.max_pending = max_pending
        self._fast_limit = max_pending + 1  # a line this long cannot hold a truncated record
        self._cons_b = 0  # bytes of the open legacy line consumed as bare-CR records
        self._cons_c = 0  # decoded characters of that consumed prefix
        self._scan_b = 0  # bytes of the open legacy line already scanned for CR
        self._swallow = False
        self._records = 0
        self._truncated = 0
        self._dropped = 0
        self._first_ns: int | None = None
        self._last_ns: int | None = None
        self._method_segment: _Segment | None = None
        self._closed = True
        self.active = False
        with recorder._lock:
            if recorder.enabled and recorder._error is None and recorder._finalized is None:
                recorder._output_open += 1
                recorder._output_cursors += 1
                self._closed = False
                self.active = True

    # -- reader entry points --------------------------------------------------

    def observe_line(self, line: bytes, text: str, receive_ns: int) -> None:
        """One complete legacy LF line (``line`` ends in ``\\n``) and its decoded text."""
        if not self.active:
            return
        try:
            if self._scan_b:
                self._observe_continuation(line, text, receive_ns, False)
                return
            if len(line) <= self._fast_limit:
                cr = text.find("\r")
                if cr < 0 or cr == len(text) - 2:
                    # One LF or CRLF record. The classifier result is identical
                    # with the trailing delimiter, so the text is not sliced.
                    self._records += 1
                    self._last_ns = receive_ns
                    if self._first_ns is None:
                        self._mark_first(receive_ns)
                    first = text[:1]
                    if first in _CURSOR_FIRST_CHARS or ".pcm" in text:
                        self._candidate(text, first, receive_ns)
                    return
            self._observe_region(line, text, 0, 0, receive_ns, False, False)
        except Exception as exc:  # noqa: BLE001 - containment by design
            self._disable(exc)

    def scan_pending(self, pending: bytes | bytearray, receive_ns: int) -> None:
        """After a read: emit bare-CR records completed inside the open LF line."""
        if not self.active:
            return
        try:
            size = len(pending)
            start = self._scan_b
            if size <= start:
                return
            # New bytes arrived; an LF would have closed the line, so a pending
            # CR-swallow can no longer apply.
            self._swallow = False
            position = pending.find(b"\r", start)
            if position < 0:
                self._scan_b = size
                return
            consumed_b, consumed_c = self._cons_b, self._cons_c
            while position >= 0:
                length = position - consumed_b
                truncated = length > self.max_pending
                if truncated:
                    text = bytes(pending[consumed_b:consumed_b + self.max_pending]).decode("utf-8", errors="replace")
                    chars = len(bytes(pending[consumed_b:position]).decode("utf-8", errors="replace"))
                    self._truncated += 1
                    self._dropped += length - self.max_pending
                else:
                    text = bytes(pending[consumed_b:position]).decode("utf-8", errors="replace")
                    chars = len(text)
                self._observe_record(text, receive_ns, truncated)
                consumed_c += chars + 1
                consumed_b = position + 1
                position = pending.find(b"\r", consumed_b)
            self._cons_b, self._cons_c = consumed_b, consumed_c
            self._scan_b = size
            if consumed_b == size:
                self._swallow = True
        except Exception as exc:  # noqa: BLE001
            self._disable(exc)

    def finish(self, tail: bytes | None, tail_text: str | None, receive_ns: int) -> None:
        """EOF: the legacy unterminated tail (if any) and its decoded text."""
        if self.active:
            try:
                if tail:
                    if self._scan_b:
                        self._observe_continuation(tail, tail_text or "", receive_ns, True)
                    else:
                        self._observe_region(tail, tail_text or "", 0, 0, receive_ns, False, True)
            except Exception as exc:  # noqa: BLE001
                self._disable(exc)
                return
        self._close(None)

    # -- internals --------------------------------------------------------------

    def _observe_continuation(self, data: bytes, text: str, receive_ns: int, final: bool) -> None:
        consumed_b, consumed_c, swallow = self._cons_b, self._cons_c, self._swallow
        self._cons_b = self._cons_c = self._scan_b = 0
        self._swallow = False
        self._observe_region(data, text, consumed_b, consumed_c, receive_ns, swallow, final)

    def _observe_region(
        self, data: bytes, text: str, start_b: int, start_c: int, receive_ns: int, swallow: bool, final: bool
    ) -> None:
        if swallow and data[start_b:start_b + 1] == b"\n":
            start_b += 1
            start_c += 1
        if start_b >= len(data):
            return
        # A non-final region ends in its LF, so it may be one byte longer than
        # the longest untruncated record; an EOF region may not.
        if len(data) - start_b <= (self.max_pending if final else self._fast_limit):
            parts = _SPLIT_TEXT_RE.split(text[start_c:] if start_c else text)
            remainder = parts.pop()
            if final and remainder:
                parts.append(remainder)
            for record in parts:
                self._observe_record(record, receive_ns)
            return
        # Long region: split bytes so truncation equals the splitter's.
        start = start_b
        for match in _DELIMITER_RE.finditer(data, start_b):
            self._observe_bytes_record(data, start, match.start(), receive_ns)
            start = match.end()
        if final and start < len(data):
            self._observe_bytes_record(data, start, len(data), receive_ns)

    def _observe_bytes_record(self, data: bytes, start: int, end: int, receive_ns: int) -> None:
        length = end - start
        if length > self.max_pending:
            text = data[start:start + self.max_pending].decode("utf-8", errors="replace")
            self._truncated += 1
            self._dropped += length - self.max_pending
            self._observe_record(text, receive_ns, True)
            return
        self._observe_record(data[start:end].decode("utf-8", errors="replace"), receive_ns)

    def _observe_record(self, text: str, receive_ns: int, truncated: bool = False) -> None:
        self._records += 1
        self._last_ns = receive_ns
        if self._first_ns is None:
            self._mark_first(receive_ns)
        first = text[:1]
        if first in _CURSOR_FIRST_CHARS or ".pcm" in text:
            self._candidate(text, first, receive_ns, truncated)

    def _candidate(self, text: str, first: str, receive_ns: int, truncated: bool = False) -> None:
        segment = self._method_segment
        if segment is not None and (first == "T" or first == "\x1b") and _CASE_PREFIX in text:
            offset = 0
            if first == "\x1b":
                leading = _LEADING_ANSI_RE.match(text)
                offset = leading.end() if leading is not None else 0
            # A visible "Test Case '" prefix classifies as a method or nothing;
            # with the first method already recorded it cannot change state.
            if text.startswith(_CASE_PREFIX, offset) and self.recorder._current is segment:
                return
        marker = classify_record(text)
        if marker is not None:
            self._apply(marker, receive_ns, truncated)

    def _apply(self, marker: Marker, receive_ns: int, truncated: bool = False) -> None:
        recorder = self.recorder
        with recorder._lock:
            if not recorder._active():
                self.active = False
                return
            try:
                recorder._apply_marker(marker, receive_ns, truncated)
            except Exception as exc:  # noqa: BLE001
                recorder._fail(exc)
                self.active = False
                return
            current = recorder._current
            self._method_segment = current if current is not None and current.first_method_ns is not None else None

    def _mark_first(self, receive_ns: int) -> None:
        self._first_ns = receive_ns
        recorder = self.recorder
        with recorder._lock:
            if recorder._first_record_ns is None and recorder._finalized is None:
                recorder._first_record_ns = receive_ns

    def _disable(self, exc: BaseException) -> None:
        self.active = False
        self._close(_bounded(f"{type(exc).__name__}: {exc}", 256))

    def _close(self, error: str | None) -> None:
        if self._closed:
            return
        self._closed = True
        self.active = False
        recorder = self.recorder
        with recorder._lock:
            recorder._output_open -= 1
            if error is not None:
                recorder._output_error = error
                return
            if recorder._finalized is not None:
                recorder._late_observations += 1
                return
            recorder._records += self._records
            recorder._truncated_records += self._truncated
            recorder._output_dropped_bytes += self._dropped
            if self._last_ns is not None and (recorder._last_record_ns is None or self._last_ns > recorder._last_record_ns):
                recorder._last_record_ns = self._last_ns


def _bounded_metadata(metadata: Mapping[str, Any] | None) -> dict[str, Any]:
    if not metadata:
        return {}
    clean: dict[str, Any] = {}
    for key, value in metadata.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, str):
            value = _bounded(value, MAX_COMMAND_CHARS if key == "command" else MAX_CONTEXT_CHARS)
        elif value is not None and not isinstance(value, (bool, int, float)):
            value = _bounded(repr(value), MAX_CONTEXT_CHARS)
        clean[_bounded(key, MAX_NAME_CHARS)] = value
    if len(json.dumps(clean, ensure_ascii=False).encode("utf-8")) > MAX_METADATA_BYTES:
        return {"truncated": True}
    return clean


# ---------------------------------------------------------------------------
# Environment, provenance and persistence helpers


def timing_enabled(environ: Mapping[str, str]) -> bool:
    """Kill switch: only ``RPCE_CONDUCTOR_TIMING=off`` disables timing."""
    return environ.get(TIMING_ENV_KEY, "").strip().lower() != "off"


def content_digest(paths: Iterable[Path]) -> str | None:
    """Domain-separated SHA-256 over the named files' bytes; ``None`` if any is unreadable."""
    digest = hashlib.sha256(b"rpce-conductor-digest-v1\0")
    try:
        for path in sorted(Path(p) for p in paths):
            data = path.read_bytes()
            name = path.name.encode("utf-8")
            digest.update(len(name).to_bytes(8, "big") + name)
            digest.update(len(data).to_bytes(8, "big") + data)
    except OSError:
        return None
    return "sha256:" + digest.hexdigest()


def atomic_write_json(path: Path, payload: Any) -> None:
    path = Path(path)
    data = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temp_name)
        raise


def write_events_jsonl(path: Path, events: Iterable[Mapping[str, Any]]) -> None:
    lines = [json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False) for event in events]
    atomic_text = ("\n".join(lines) + "\n") if lines else ""
    path = Path(path)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(atomic_text)
        os.replace(temp_name, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temp_name)
        raise


def history_row(
    phase_metrics: Mapping[str, Any],
    *,
    ticket: str,
    kind: str,
    finished_wall_ns: int | None,
    conductor_digest: str | None,
    exit_code: int | None,
) -> dict[str, Any]:
    """Compact history row: the payload without per-module file detail."""
    segments = []
    for segment in phase_metrics.get("segments", []) or []:
        compact = {key: value for key, value in segment.items() if key != "modules"}
        modules = segment.get("modules") or {}
        compact["moduleCount"] = len(modules)
        compact["compiledFiles"] = sum(int(entry.get("compiledFiles", 0)) for entry in modules.values())
        segments.append(compact)
    row = {key: value for key, value in phase_metrics.items() if key != "segments"}
    row.update({
        "schema": SCHEMA_VERSION,
        "ticket": ticket,
        "kind": kind,
        "finishedAtWallNs": finished_wall_ns,
        "conductorDigest": conductor_digest,
        "exitCode": exit_code,
        "segments": segments,
    })
    return row


def filter_history(
    rows: Iterable[Mapping[str, Any]],
    *,
    last: int | None = None,
    kind: str | None = None,
    ticket: str | None = None,
) -> list[Mapping[str, Any]]:
    selected = [
        row for row in rows
        if (kind is None or row.get("kind") == kind) and (ticket is None or row.get("ticket") == ticket)
    ]
    if last is not None:
        selected = selected[-last:] if last > 0 else []
    return selected


class RotatingJsonl:
    """Append-only JSONL with size rotation: ``path``, ``path.1`` ... ``path.N``.

    Appends hold an advisory ``flock`` on ``path.lock`` and a process-local
    lock; callers must not hold scheduler or recorder locks while appending.
    Lock acquisition is bounded by ``lock_timeout``: a busy lock raises
    ``MetricsError`` instead of blocking optional telemetry indefinitely.
    """

    def __init__(
        self,
        path: Path,
        *,
        max_bytes: int = HISTORY_MAX_ACTIVE_BYTES,
        generations: int = HISTORY_GENERATIONS,
        max_row_bytes: int = HISTORY_MAX_ROW_BYTES,
        lock_timeout: float = HISTORY_LOCK_TIMEOUT_SECONDS,
    ) -> None:
        if max_bytes <= 0 or generations < 0 or max_row_bytes <= 0 or lock_timeout < 0:
            raise MetricsError("invalid RotatingJsonl bounds")
        self.lock_timeout = lock_timeout
        self.path = Path(path)
        self.max_bytes = max_bytes
        self.generations = generations
        self.max_row_bytes = min(max_row_bytes, max_bytes)
        self._lock = threading.Lock()

    def generation_paths(self) -> list[Path]:
        """Oldest first, active last."""
        rotated = [self.path.with_name(f"{self.path.name}.{index}") for index in range(self.generations, 0, -1)]
        return rotated + [self.path]

    def _rotate(self) -> None:
        if self.generations == 0:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.path)
            return
        oldest = self.path.with_name(f"{self.path.name}.{self.generations}")
        with contextlib.suppress(FileNotFoundError):
            os.unlink(oldest)
        for index in range(self.generations - 1, 0, -1):
            source = self.path.with_name(f"{self.path.name}.{index}")
            with contextlib.suppress(FileNotFoundError):
                os.replace(source, self.path.with_name(f"{self.path.name}.{index + 1}"))
        with contextlib.suppress(FileNotFoundError):
            os.replace(self.path, self.path.with_name(f"{self.path.name}.1"))

    def append(self, row: Mapping[str, Any]) -> None:
        line = json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        if len(line) > self.max_row_bytes:
            raise MetricsError(f"history row is {len(line)} bytes; limit {self.max_row_bytes}")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = self.path.with_name(self.path.name + ".lock")
        deadline = time.monotonic() + self.lock_timeout
        if not self._lock.acquire(timeout=self.lock_timeout):
            raise MetricsError(f"history lock busy for {self.lock_timeout:g}s")
        try:
            lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o644)
            try:
                while True:
                    try:
                        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise MetricsError(f"history lock busy for {self.lock_timeout:g}s") from None
                        time.sleep(0.01)
                try:
                    size = os.stat(self.path).st_size
                except FileNotFoundError:
                    size = 0
                if size > 0 and size + len(line) > self.max_bytes:
                    self._rotate()
                fd = os.open(str(self.path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
                try:
                    os.write(fd, line)
                finally:
                    os.close(fd)
            finally:
                os.close(lock_fd)
        finally:
            self._lock.release()

    def read_rows(self) -> tuple[list[dict[str, Any]], int]:
        """Return ``(rows oldest-first, malformed line count)``."""
        rows: list[dict[str, Any]] = []
        malformed = 0
        for path in self.generation_paths():
            try:
                data = path.read_bytes()
            except FileNotFoundError:
                continue
            for raw in data.splitlines():
                if not raw.strip():
                    continue
                try:
                    value = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    malformed += 1
                    continue
                if isinstance(value, dict):
                    rows.append(value)
                else:
                    malformed += 1
        return rows, malformed


# ---------------------------------------------------------------------------
# Comparison statistics


def _finite_numbers(values: Sequence[Any]) -> list[float] | None:
    numbers = []
    for value in values:
        if value is None or isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return None
        numbers.append(float(value))
    return numbers


def median(values: Sequence[float]) -> float:
    if not values:
        raise MetricsError("median of empty sample")
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def percentile(values: Sequence[float], q: float) -> float:
    """Linear-interpolated percentile, ``q`` in [0, 100]."""
    if not values:
        raise MetricsError("percentile of empty sample")
    if not 0.0 <= q <= 100.0:
        raise MetricsError("percentile q must be within [0, 100]")
    ordered = sorted(values)
    position = (len(ordered) - 1) * q / 100.0
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[int(position)]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def bootstrap_median_ci(
    differences: Sequence[float],
    *,
    confidence: float = 0.95,
    iterations: int = 2000,
    seed: int = 0,
    block_size: int = 1,
) -> tuple[float, float]:
    """Deterministic (moving-)block bootstrap CI of the median difference."""
    if not differences:
        raise MetricsError("bootstrap of empty sample")
    if not 0.0 < confidence < 1.0 or iterations <= 0 or block_size <= 0:
        raise MetricsError("invalid bootstrap parameters")
    n = len(differences)
    block = min(block_size, n)
    starts = n - block + 1
    blocks_needed = math.ceil(n / block)
    rng = random.Random(seed)
    estimates = []
    for _ in range(iterations):
        resample: list[float] = []
        for _ in range(blocks_needed):
            start = rng.randrange(starts)
            resample.extend(differences[start:start + block])
        estimates.append(median(resample[:n]))
    alpha = (1.0 - confidence) / 2.0
    return percentile(estimates, alpha * 100.0), percentile(estimates, (1.0 - alpha) * 100.0)


@dataclass(frozen=True)
class Comparison:
    verdict: str  # "qualified" | "regression" | "inconclusive" | "harness_failure"
    exit_code: int
    pairs: int
    baseline_median: float | None = None
    candidate_median: float | None = None
    median_delta: float | None = None
    ci_low: float | None = None
    ci_high: float | None = None
    threshold: float | None = None
    reasons: tuple[str, ...] = ()

    def to_json(self) -> dict[str, Any]:
        return {
            "verdict": self.verdict,
            "exitCode": self.exit_code,
            "pairs": self.pairs,
            "baselineMedian": self.baseline_median,
            "candidateMedian": self.candidate_median,
            "medianDelta": self.median_delta,
            "ciLow": self.ci_low,
            "ciHigh": self.ci_high,
            "threshold": self.threshold,
            "reasons": list(self.reasons),
        }


def _inconclusive(pairs: int, *reasons: str, **fields: Any) -> Comparison:
    return Comparison("inconclusive", EXIT_INCONCLUSIVE, pairs, reasons=tuple(reasons), **fields)


def metadata_mismatches(
    baseline: Mapping[str, Any] | None,
    candidate: Mapping[str, Any] | None,
    match_keys: Iterable[str],
) -> list[str]:
    """Keys whose values differ or are missing on either side (missing never matches)."""
    mismatched = []
    for key in match_keys:
        if baseline is None or candidate is None or key not in baseline or key not in candidate:
            mismatched.append(key)
        elif baseline[key] is None or baseline[key] != candidate[key]:
            mismatched.append(key)
    return mismatched


def _paired(baseline: Sequence[Any], candidate: Sequence[Any], min_pairs: int) -> tuple[list[float], list[float]] | Comparison:
    if len(baseline) != len(candidate):
        return Comparison("harness_failure", EXIT_HARNESS_FAILURE, 0, reasons=("unpaired_samples",))
    pairs = len(baseline)
    base = _finite_numbers(baseline)
    cand = _finite_numbers(candidate)
    if base is None or cand is None:
        return _inconclusive(pairs, "missing_evidence")
    if pairs < max(min_pairs, 1):
        return _inconclusive(pairs, "insufficient_pairs")
    return base, cand


def compare_paired(
    baseline: Sequence[Any],
    candidate: Sequence[Any],
    *,
    floor_abs: float,
    floor_rel: float = 0.05,
    min_pairs: int = 10,
    confidence: float = 0.95,
    iterations: int = 2000,
    seed: int = 0,
    block_size: int = 1,
    baseline_meta: Mapping[str, Any] | None = None,
    candidate_meta: Mapping[str, Any] | None = None,
    match_keys: Iterable[str] = (),
) -> Comparison:
    """Paired comparison for lower-is-better samples.

    * regression (1): median delta exceeds ``max(floor_abs, floor_rel * baseline
      median)`` and the whole CI lies above zero. Plan Step 9 additionally
      requires a confirming second batch; the harness owns that.
    * qualified (0): the CI upper bound is within that threshold.
    * inconclusive (2): anything else, including incompatible metadata, missing
      values or too few pairs. Missing evidence never passes.
    * harness failure (3): unpaired inputs.
    """
    mismatched = metadata_mismatches(baseline_meta, candidate_meta, match_keys) if match_keys else []
    if mismatched:
        return _inconclusive(min(len(baseline), len(candidate)), *(f"incompatible:{key}" for key in mismatched))
    paired = _paired(baseline, candidate, min_pairs)
    if isinstance(paired, Comparison):
        return paired
    base, cand = paired
    differences = [c - b for b, c in zip(base, cand)]
    base_median, cand_median = median(base), median(cand)
    delta = median(differences)
    low, high = bootstrap_median_ci(differences, confidence=confidence, iterations=iterations, seed=seed, block_size=block_size)
    threshold = max(floor_abs, floor_rel * base_median)
    fields = dict(
        baseline_median=base_median, candidate_median=cand_median, median_delta=delta,
        ci_low=low, ci_high=high, threshold=threshold,
    )
    if delta > threshold and low > 0:
        return Comparison("regression", EXIT_REGRESSION, len(base), reasons=("ci_above_zero_and_threshold",), **fields)
    if high <= threshold:
        return Comparison("qualified", EXIT_QUALIFIED, len(base), **fields)
    return _inconclusive(len(base), "ci_exceeds_threshold", **fields)


def overhead_gate(
    timing_on: Sequence[Any],
    timing_off: Sequence[Any],
    *,
    process_wall: Sequence[Any] | None = None,
    floor_abs: float = 0.050,
    floor_rel: float = 0.01,
    min_pairs: int = 30,
) -> Comparison:
    """Step 2 gate: median added wall below max(50 ms, 1% of process wall).

    Units are the caller's (seconds by default for the 50 ms floor). The
    process-wall median comes from ``process_wall`` or, if omitted, the
    timing-off samples.
    """
    paired = _paired(timing_off, timing_on, min_pairs)
    if isinstance(paired, Comparison):
        return paired
    off, on = paired
    wall_source = off
    if process_wall is not None:
        wall = _finite_numbers(process_wall)
        if wall is None or not wall:
            return _inconclusive(len(off), "missing_process_wall")
        wall_source = wall
    added = median([b - a for a, b in zip(off, on)])
    threshold = max(floor_abs, floor_rel * median(wall_source))
    fields = dict(baseline_median=median(off), candidate_median=median(on), median_delta=added, threshold=threshold)
    if added < threshold:
        return Comparison("qualified", EXIT_QUALIFIED, len(off), **fields)
    return Comparison("regression", EXIT_REGRESSION, len(off), reasons=("median_overhead_at_or_above_threshold",), **fields)


def aa_equivalence(
    arm_a: Sequence[Any],
    arm_b: Sequence[Any],
    *,
    bound_abs: float,
    bound_rel: float = 0.03,
    min_pairs: int = 10,
    confidence: float = 0.95,
    iterations: int = 2000,
    seed: int = 0,
    block_size: int = 2,
) -> Comparison:
    """A/A calibration: CI and |delta median| within ±max(bound_abs, bound_rel * pooled median)."""
    paired = _paired(arm_a, arm_b, min_pairs)
    if isinstance(paired, Comparison):
        return paired
    a, b = paired
    differences = [y - x for x, y in zip(a, b)]
    delta = median(b) - median(a)
    low, high = bootstrap_median_ci(differences, confidence=confidence, iterations=iterations, seed=seed, block_size=block_size)
    bound = max(bound_abs, bound_rel * median(a + b))
    fields = dict(baseline_median=median(a), candidate_median=median(b), median_delta=delta, ci_low=low, ci_high=high, threshold=bound)
    if -bound <= low and high <= bound and abs(delta) <= bound:
        return Comparison("qualified", EXIT_QUALIFIED, len(a), **fields)
    return _inconclusive(len(a), "outside_equivalence_bound", **fields)
