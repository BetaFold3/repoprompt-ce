#!/usr/bin/env python3
"""Pure deterministic tests for swift_pipeline_metrics.py (plan Step 2)."""
from __future__ import annotations

import base64
from datetime import timezone
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
FIXTURE_ROOT = SCRIPT_DIR / "Fixtures" / "build-metrics" / "v1"
FIXTURE_NAMES = ("null-test", "compile-cr", "package-debug", "parallel-test", "artifact")
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import swift_pipeline_metrics as metrics  # noqa: E402

MS = 1_000_000


def load_case(name: str) -> dict:
    return json.loads((FIXTURE_ROOT / name / "case.json").read_text(encoding="utf-8"))


def chunk_bytes(step: dict) -> bytes:
    if "chunkB64" in step:
        return base64.b64decode(step["chunkB64"])
    return step["chunk"].encode("utf-8")


def replay(case: dict, *, piece_size: int | None = None) -> tuple[metrics.PipelineRecorder, dict]:
    """Replay a fixture. ``piece_size`` re-chunks every read into smaller reads at the same time."""
    origin = case["originNs"]
    anchor = case.get("wallAnchor")
    recorder = metrics.PipelineRecorder(
        origin_ns=origin,
        wall_anchor=tuple(anchor) if anchor else None,
        xctest_tz=timezone.utc if case.get("xctestTz") == "UTC" else None,
        not_applicable_intervals=case.get("notApplicableIntervals", ()),
    )
    splitter = metrics.RecordSplitter()
    for step in case["steps"]:
        at_ns = origin + int(round(step.get("atMs", 0) * MS))
        if "boundary" in step:
            recorder.record_boundary(step["boundary"], at_ns, step.get("metadata"))
        elif "chunk" in step or "chunkB64" in step:
            data = chunk_bytes(step)
            pieces = [data] if piece_size is None else [data[i:i + piece_size] for i in range(0, len(data), piece_size)]
            for piece in pieces:
                recorder.observe_records(splitter.feed(piece, at_ns))
        elif "eof" in step:
            recorder.observe_records(splitter.finish(at_ns))
        elif "operation" in step:
            op = step["operation"]
            recorder.record_operation(
                op["name"], op["durationNs"], op.get("counters"), op.get("origin", ""),
                quality=op.get("quality", metrics.MEASURED_WALL),
                monotonic_ns=at_ns if "atMs" in step else None,
            )
        else:
            raise AssertionError(f"unknown fixture step {step!r}")
    return recorder, recorder.finalize()


def lookup(payload, dotted: str):
    value = payload
    for part in dotted.split("."):
        if part == "#":
            return len(value)
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
    return value


class SpanInvariantMixin:
    def assert_span_invariants(self, payload) -> None:
        spans = list(metrics.iter_spans(payload))
        for item in spans:
            self.assertIn(item["quality"], metrics.QUALITY_LABELS, item)
            if item["quality"] in metrics.NULL_QUALITIES:
                self.assertIsNone(item["ns"], f"null-quality span carries a value: {item}")
            else:
                self.assertIsInstance(item["ns"], int, item)
                if not item.get("signed"):
                    self.assertGreaterEqual(item["ns"], 0, item)


class FixtureReplayTests(SpanInvariantMixin, unittest.TestCase):
    def test_fixture_set_matches_plan(self) -> None:
        present = sorted(p.name for p in FIXTURE_ROOT.iterdir() if p.is_dir())
        self.assertEqual(present, sorted(FIXTURE_NAMES))

    def test_fixtures_produce_expected_metrics(self) -> None:
        for name in FIXTURE_NAMES:
            with self.subTest(fixture=name):
                case = load_case(name)
                recorder, payload = replay(case)
                self.assertEqual(payload["schema"], metrics.SCHEMA_VERSION)
                for path, expected in case["expect"].items():
                    self.assertEqual(lookup(payload, path), expected, f"{name}: {path}")
                self.assert_span_invariants(payload)
                json.dumps(payload)
                json.dumps(recorder.events())

    def test_rechunked_reads_derive_identical_metrics(self) -> None:
        for name in FIXTURE_NAMES:
            for size in (1, 3, 7):
                with self.subTest(fixture=name, piece_size=size):
                    case = load_case(name)
                    _, whole = replay(case)
                    _, pieces = replay(case, piece_size=size)
                    self.assertEqual(pieces, whole)

    def test_fixture_events_cover_markers_and_boundaries(self) -> None:
        recorder, _ = replay(load_case("null-test"))
        kinds = [event["k"] for event in recorder.events()]
        for kind in ("boundary", "command", "segment_open", "build_start", "first_build_work", "build_complete", "suite", "first_method"):
            self.assertIn(kind, kinds)
        # Two started methods, one observation: no per-method event rows.
        self.assertEqual(kinds.count("first_method"), 1)
        self.assertNotIn("method", kinds)
        offsets = [event["t"] for event in recorder.events()]
        self.assertEqual(offsets[0], 0)

    def test_finalize_is_idempotent_and_late_observations_are_ignored(self) -> None:
        recorder, payload = replay(load_case("null-test"))
        recorder.observe_records([metrics.OutputRecord(999, 10**12, "Build complete! (9.00s)", "lf")])
        recorder.record_boundary("lane_released", 10**12)
        self.assertIs(recorder.finalize(), payload)
        self.assertEqual(payload["segments"][0]["reportedBuild"]["ns"], 420 * MS)


class RecordSplitterTests(unittest.TestCase):
    def texts(self, records):
        return [(r.text, r.delimiter) for r in records]

    def test_delimiters(self) -> None:
        splitter = metrics.RecordSplitter()
        records = splitter.feed(b"a\nb\r\nc\rd", 1)
        self.assertEqual(self.texts(records), [("a", "lf"), ("b", "crlf"), ("c", "cr")])
        self.assertEqual(self.texts(splitter.finish(2)), [("d", "eof")])
        self.assertEqual(splitter.finish(3), [])

    def test_bare_cr_at_read_end_swallows_exactly_one_following_lf(self) -> None:
        splitter = metrics.RecordSplitter()
        first = splitter.feed(b"x\r", 1)
        second = splitter.feed(b"\n\ny\n", 2)
        self.assertEqual(self.texts(first), [("x", "cr")])
        self.assertEqual(self.texts(second), [("", "lf"), ("y", "lf")])

    def test_swallow_survives_empty_read_and_only_applies_to_next_byte(self) -> None:
        splitter = metrics.RecordSplitter()
        splitter.feed(b"x\r", 1)
        self.assertEqual(splitter.feed(b"", 2), [])
        self.assertEqual(self.texts(splitter.feed(b"\nz\n", 3)), [("z", "lf")])
        splitter.feed(b"q\r", 4)
        self.assertEqual(self.texts(splitter.feed(b"w\n", 5)), [("w", "lf")])

    def test_split_utf8_and_later_read_timestamp(self) -> None:
        splitter = metrics.RecordSplitter()
        encoded = "Älpha".encode("utf-8")
        self.assertEqual(splitter.feed(encoded[:1], 10), [])
        records = splitter.feed(encoded[1:] + b"\n", 20)
        self.assertEqual(records[0].text, "Älpha")
        self.assertEqual(records[0].receive_ns, 20)

    def test_fast_paths_match_reference_loop(self) -> None:
        class ReferenceSplitter(metrics.RecordSplitter):
            def feed(self, data, receive_ns):
                start = 1 if self._swallow_lf and data[:1] == b"\n" else 0
                if data:
                    self._swallow_lf = False
                return self._feed_slow(data, start, receive_ns)

        import random

        rng = random.Random(20261005)
        alphabet = [b"\r", b"\n", b"\r\n", b"\xc3", b"\x84", b"\xff", b"\x1b[2K", b"ab", b"x" * 40,
                    "Älpha".encode(), b"[1/2] Compiling M A.swift"]
        streams = [b"".join(chunk_bytes(step) for step in load_case(name)["steps"] if "chunk" in step or "chunkB64" in step)
                   for name in FIXTURE_NAMES]
        streams += [b"".join(rng.choice(alphabet) for _ in range(3000)) for _ in range(20)]
        for index, stream in enumerate(streams):
            for max_pending in (metrics.MAX_PENDING_RECORD_BYTES, 16):
                fast, reference = metrics.RecordSplitter(max_pending), ReferenceSplitter(max_pending)
                position = 0
                with self.subTest(stream=index, max_pending=max_pending):
                    while position < len(stream):
                        size = rng.choice((1, 2, 5, 64, 700, 4096))
                        piece = stream[position:position + size]
                        if rng.random() < 0.3 and b"\n" in piece:
                            piece = piece[:piece.index(b"\n") + 1]  # readline-shaped read
                        position += len(piece)
                        self.assertEqual(fast.feed(piece, position), reference.feed(piece, position))
                    self.assertEqual(fast.finish(-1), reference.finish(-1))
                    self.assertEqual(fast.dropped_bytes, reference.dropped_bytes)

    def test_pending_cap_truncates_and_recovers(self) -> None:
        splitter = metrics.RecordSplitter()
        cap = metrics.MAX_PENDING_RECORD_BYTES
        self.assertEqual(cap, 64 * 1024)
        self.assertEqual(splitter.feed(b"a" * (cap - 10), 1), [])
        records = splitter.feed(b"b" * 100 + b"\nnext\n", 2)
        self.assertEqual(len(records[0].text), cap)
        self.assertTrue(records[0].truncated)
        self.assertEqual(splitter.dropped_bytes, 90)
        self.assertEqual((records[1].text, records[1].truncated), ("next", False))
        self.assertEqual([r.seq for r in records], [0, 1])


class ClassifierTests(unittest.TestCase):
    def kind(self, text: str):
        marker = metrics.classify_record(text)
        return None if marker is None else marker.kind

    def test_every_marker_alternative(self) -> None:
        cases = {
            "$ /repo/Scripts/canonical_swift.sh test": metrics.K_COMMAND,
            "+ /repo/Scripts/doctor.sh --quiet ": metrics.K_COMMAND,
            "==> Build root XCTest artifact": metrics.K_HEADING,
            "Building for debugging...": metrics.K_BUILD_START,
            "Building for production...": metrics.K_BUILD_START,
            "[0/1] Planning build": metrics.K_PLANNING,
            "[1/8] Write swift-version--58304C5D6DBC2206.txt": metrics.K_WRITE,
            "[8/19] Compiling RepoPromptApp AgentModeViewModel.swift": metrics.K_COMPILE,
            "[4/13] Emitting module RepoPromptShared": metrics.K_EMIT_MODULE,
            "[263/315] Linking RepoPrompt": metrics.K_LINK,
            "[264/315] Applying RepoPrompt": metrics.K_STEP,
            "Build complete! (82.52s)": metrics.K_BUILD_COMPLETE,
            "Build of product 'repoprompt-mcp' complete! (1.23s)": metrics.K_BUILD_COMPLETE,
            "Test Suite 'Selected tests' started at 2026-10-05 10:16:41.280.": metrics.K_SUITE,
            "Test Suite 'X' failed at 2026-10-05 10:16:41.280.": metrics.K_SUITE,
            "Test Case '-[A.B testC]' started.": metrics.K_METHOD,
            "Test Case '-[A.B testC]' passed (0.001 seconds).": metrics.K_METHOD,
            "\t Executed 131 tests, with 0 failures (0 unexpected) in 13.197 (13.204) seconds": metrics.K_EXECUTED,
            "warning: (arm64) /x/ModuleCache/H/Foo-1.pcm: No such file or directory": metrics.K_PCM_WARNING,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(self.kind(text), expected)
                self.assertEqual(self.kind("\x1b[2K" + text + "\x1b[0m"), expected)

    def test_non_markers(self) -> None:
        for text in ("", "\x1b[2K", "$", "+x", "==>", "[ACPAgentRunToolTracking] foo", "Build failed", "Test Suite 'x' oops",
                     "acquired global heavy slot /tmp/x after 0ms", "PLAN workers=8", "warning: something.pcm is fine"):
            with self.subTest(text=text):
                self.assertIsNone(metrics.classify_record(text))

    def test_compile_files_and_build_seconds(self) -> None:
        marker = metrics.classify_record("[5/11] Compiling RepoPromptApp Beta.swift, Gamma.swift")
        self.assertEqual((marker.module, marker.files), ("RepoPromptApp", ("Beta.swift", "Gamma.swift")))
        marker = metrics.classify_record("Build of product 'RepoPrompt' complete! (22.37s)")
        self.assertEqual((marker.name, marker.seconds), ("RepoPrompt", "22.37"))

    def test_swift_command_detection(self) -> None:
        self.assertTrue(metrics.is_swift_command("/repo/Scripts/canonical_swift.sh build -c debug"))
        self.assertTrue(metrics.is_swift_command("/usr/bin/xcrun xctest /x.xctest"))
        self.assertFalse(metrics.is_swift_command("/repo/Scripts/doctor.sh --quiet"))
        self.assertFalse(metrics.is_swift_command("/usr/bin/python3 /repo/Scripts/swift_style.sh.py"))


class RecorderBoundsTests(SpanInvariantMixin, unittest.TestCase):
    def method_records(self, count: int, name_width: int = 1):
        filler = "x" * name_width
        return [
            metrics.OutputRecord(i, 1000 + i, f"Test Case '-[S.T t{filler}{i}]' started.", "lf")
            for i in range(count)
        ]

    def new_recorder(self, **kwargs) -> metrics.PipelineRecorder:
        recorder = metrics.PipelineRecorder(origin_ns=0, **kwargs)
        recorder.record_boundary(metrics.COMMAND_START, 1, {"command": "/r/canonical_swift.sh test"})
        recorder.observe_records([metrics.OutputRecord(0, 2, "Test Suite 'All' started at 2026-10-05 10:00:00.000.", "lf")])
        return recorder

    def test_plan_bounds_are_the_defaults(self) -> None:
        self.assertEqual(metrics.MAX_EVENTS, 20_000)
        self.assertEqual(metrics.MAX_EVENT_BYTES, 4 * 1024 * 1024)
        self.assertEqual(metrics.MAX_FILE_IDENTITIES, 10_000)
        self.assertEqual(metrics.MAX_FILE_IDENTITY_TEXT_BYTES, 2 * 1024 * 1024)
        self.assertEqual(metrics.MAX_MODULE_AGGREGATES, 256)
        self.assertEqual(metrics.MAX_SEGMENTS, 64)
        self.assertEqual(metrics.HISTORY_MAX_ACTIVE_BYTES, 32 * 1024 * 1024)
        self.assertEqual(metrics.HISTORY_GENERATIONS, 2)

    def suite_records(self, count: int, name_width: int = 1):
        filler = "x" * name_width
        return [
            metrics.OutputRecord(i, 1000 + i, f"Test Suite 'S{filler}{i}' started at 2026-10-05 10:00:00.000.", "lf")
            for i in range(count)
        ]

    def test_methods_emit_one_first_method_event_per_segment(self) -> None:
        recorder = self.new_recorder()
        recorder.observe_records(self.method_records(25_000))
        payload = recorder.finalize()
        kinds = [event["k"] for event in recorder.events()]
        self.assertEqual(kinds.count("first_method"), 1)
        self.assertNotIn("method", kinds)
        self.assertEqual(payload["bounds"]["eventsDropped"], 0)
        self.assertNotIn("methodsStarted", payload["segments"][0])
        self.assertEqual(payload["segments"][0]["xctestObserved"]["quality"], "unavailable")

    def test_event_count_cap_keeps_derived_counts_exact(self) -> None:
        recorder = self.new_recorder()
        recorder.observe_records(self.suite_records(25_000))
        payload = recorder.finalize()
        self.assertEqual(len(recorder.events()), metrics.MAX_EVENTS)
        self.assertEqual(payload["status"], "partial")
        self.assertTrue(payload["bounds"]["eventsPartial"])
        self.assertGreater(payload["bounds"]["eventsDropped"], 5_000)
        self.assertEqual(payload["segments"][0]["suitesStarted"], 25_001)

    def test_event_byte_cap(self) -> None:
        recorder = self.new_recorder()
        recorder.observe_records(self.suite_records(19_900, name_width=150))
        payload = recorder.finalize()
        size = sum(len(json.dumps(e, separators=(",", ":"), ensure_ascii=False).encode()) + 1 for e in recorder.events())
        self.assertLessEqual(size, metrics.MAX_EVENT_BYTES)
        self.assertLess(len(recorder.events()), 19_900)
        self.assertTrue(payload["bounds"]["eventsPartial"])
        self.assertEqual(payload["segments"][0]["suitesStarted"], 19_901)

    def compile_records(self, module_for, file_for, count: int):
        return [
            metrics.OutputRecord(i, 10 + i, f"[{i}/{count}] Compiling {module_for(i)} {file_for(i)}", "cr")
            for i in range(count)
        ]

    def build_recorder(self) -> metrics.PipelineRecorder:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary(metrics.COMMAND_START, 1, {"command": "/r/canonical_swift.sh build"})
        return recorder

    def test_file_identity_count_cap_marks_inexact(self) -> None:
        recorder = self.build_recorder()
        recorder.observe_records(self.compile_records(lambda i: "M", lambda i: f"F{i}.swift", 10_050))
        payload = recorder.finalize()
        segment = payload["segments"][0]
        self.assertEqual(segment["modules"]["M"]["compiledFiles"], 10_000)
        self.assertFalse(segment["modules"]["M"]["exact"])
        self.assertFalse(segment["compiledFilesExact"])
        self.assertTrue(payload["bounds"]["fileIdentitiesSaturated"])
        self.assertEqual(payload["bounds"]["unresolvedFileObservations"], 50)
        self.assertEqual(segment["compileRecords"], 10_050)
        self.assertEqual(payload["status"], "partial")

    def test_saturation_marks_only_later_observed_modules_inexact(self) -> None:
        recorder = self.build_recorder()
        records = self.compile_records(lambda i: "Early", lambda i: f"F{i % 3}.swift", 9)  # 3 identities, duplicates
        records += self.compile_records(lambda i: "Big", lambda i: f"G{i}.swift", 10_000)  # saturates at the last one
        records += self.compile_records(lambda i: "Late", lambda i: "H.swift", 2)
        recorder.observe_records(records)
        payload = recorder.finalize()
        modules = payload["segments"][0]["modules"]
        self.assertEqual(modules["Early"], {"compiledFiles": 3, "exact": True, "emittedModule": False})
        self.assertEqual((modules["Big"]["compiledFiles"], modules["Big"]["exact"]), (9_997, False))
        self.assertEqual((modules["Late"]["compiledFiles"], modules["Late"]["exact"]), (0, False))
        self.assertEqual(payload["bounds"]["unresolvedFileObservations"], 3 + 2)
        self.assertEqual(payload["status"], "partial")

    def test_file_identity_text_budget(self) -> None:
        recorder = self.build_recorder()
        long_name = "N" * 250
        recorder.observe_records(self.compile_records(lambda i: "M", lambda i: f"{long_name}{i}.swift", 9_000))
        payload = recorder.finalize()
        compiled = payload["segments"][0]["modules"]["M"]["compiledFiles"]
        self.assertLess(compiled, 9_000)
        sizes = [1 + len(f"{long_name}{i}.swift") for i in range(9_000)]
        self.assertLessEqual(sum(sizes[:compiled]), metrics.MAX_FILE_IDENTITY_TEXT_BYTES)
        self.assertGreater(sum(sizes[:compiled + 1]), metrics.MAX_FILE_IDENTITY_TEXT_BYTES)
        self.assertTrue(payload["bounds"]["fileIdentitiesSaturated"])
        self.assertEqual(payload["bounds"]["unresolvedFileObservations"], 9_000 - compiled)
        self.assertFalse(payload["segments"][0]["modules"]["M"]["exact"])

    def test_module_aggregate_cap(self) -> None:
        recorder = self.build_recorder()
        recorder.observe_records(self.compile_records(lambda i: f"Mod{i}", lambda i: "A.swift", 300))
        payload = recorder.finalize()
        segment = payload["segments"][0]
        self.assertEqual(len(segment["modules"]), metrics.MAX_MODULE_AGGREGATES)
        self.assertTrue(segment["modulesPartial"])
        self.assertFalse(segment["compiledFilesExact"])
        self.assertEqual(payload["bounds"]["modulesDropped"], 44)

    def test_segment_cap_ignores_markers_in_dropped_segments(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        records = []
        for i in range(70):
            records.append(metrics.OutputRecord(2 * i, 100 * i, f"$ /r/canonical_swift.sh build --product P{i}", "lf"))
            records.append(metrics.OutputRecord(2 * i + 1, 100 * i + 5, "Build complete! (0.01s)", "lf"))
        recorder.observe_records(records)
        payload = recorder.finalize()
        self.assertEqual(len(payload["segments"]), metrics.MAX_SEGMENTS)
        self.assertEqual(payload["bounds"]["segmentsDropped"], 6)
        self.assertTrue(payload["bounds"]["segmentsPartial"])
        self.assertEqual(payload["commandCount"], 70)
        self.assertEqual(payload["status"], "partial")
        self.assert_span_invariants(payload)


def legacy_take_lines(pending: bytearray, chunk: bytes) -> list[bytes]:
    """The conductor's ``_take_complete_output_lines`` LF framing, verbatim in behavior."""
    pending.extend(chunk)
    lines = []
    while True:
        newline = pending.find(b"\n")
        if newline < 0:
            return lines
        lines.append(bytes(pending[:newline + 1]))
        del pending[:newline + 1]


def drive(case: dict, *, piece_size: int | None = None, cursor: bool, max_pending: int = metrics.MAX_PENDING_RECORD_BYTES):
    """Replay a fixture through the cursor (legacy framing) or the reference splitter."""
    origin = case.get("originNs", 0)
    anchor = case.get("wallAnchor")
    recorder = metrics.PipelineRecorder(
        origin_ns=origin,
        wall_anchor=tuple(anchor) if anchor else None,
        xctest_tz=timezone.utc if case.get("xctestTz") == "UTC" else None,
        not_applicable_intervals=case.get("notApplicableIntervals", ()),
    )
    splitter = metrics.RecordSplitter(max_pending)
    observer = metrics.OutputTelemetryCursor(recorder, max_pending=max_pending) if cursor else None
    pending = bytearray()
    finished = False
    for step in case["steps"]:
        at_ns = origin + int(round(step.get("atMs", 0) * MS))
        if "boundary" in step:
            recorder.record_boundary(step["boundary"], at_ns, step.get("metadata"))
        elif "chunk" in step or "chunkB64" in step:
            data = chunk_bytes(step)
            pieces = [data] if piece_size is None else [data[i:i + piece_size] for i in range(0, len(data), piece_size)]
            for piece in pieces:
                if observer is None:
                    recorder.observe_records(splitter.feed(piece, at_ns))
                    continue
                for line in legacy_take_lines(pending, piece):
                    observer.observe_line(line, line.decode("utf-8", errors="replace"), at_ns)
                if pending:
                    observer.scan_pending(pending, at_ns)
        elif "eof" in step:
            finished = True
            if observer is None:
                recorder.observe_records(splitter.finish(at_ns))
            else:
                tail = bytes(pending) if pending else None
                observer.finish(tail, tail.decode("utf-8", errors="replace") if tail else None, at_ns)
        elif "operation" in step:
            op = step["operation"]
            recorder.record_operation(
                op["name"], op["durationNs"], op.get("counters"), op.get("origin", ""),
                quality=op.get("quality", metrics.MEASURED_WALL),
                monotonic_ns=at_ns if "atMs" in step else None,
            )
    if not finished:
        if observer is None:
            recorder.observe_records(splitter.finish(10**15))
        else:
            tail = bytes(pending) if pending else None
            observer.finish(tail, tail.decode("utf-8", errors="replace") if tail else None, 10**15)
    payload = recorder.finalize()
    return recorder, payload, splitter.dropped_bytes


def reads_case(reads: list[tuple[bytes, int]], eof_ns: int, prefix_steps: tuple = ()) -> dict:
    steps = list(prefix_steps) + [{"chunkB64": base64.b64encode(data).decode(), "atMs": ns / MS} for data, ns in reads]
    return {"originNs": 0, "steps": steps + [{"eof": True, "atMs": eof_ns / MS}]}


class OutputTelemetryCursorTests(SpanInvariantMixin, unittest.TestCase):
    FUZZ_TOKENS = [
        b"\r", b"\n", b"\r\n", b"\n", b"\n", b"\xc3", b"\x84", b"\xff", b"\x1b[2K", b"\x1b[32m", b"ab", b"x" * 40,
        "Älpha".encode(), b"[1/2] Compiling M A.swift", b"[3/9] Compiling N B.swift, C.swift",
        b"[2/5] Write x.swiftmodule", b"[4/5] Linking P", b"[0/1] Planning build", b"$ /r/canonical_swift.sh build",
        b"+ /r/doctor.sh", b"==> Heading", b"Building for debugging...", b"Build complete! (1.00s)",
        b"Test Suite 'S' started at 2026-10-05 10:00:00.000.", b"Test Suite 'S' passed at 2026-10-05 10:00:01.000.",
        b"Test Case '-[A b]' started.", b"\x1b[32mTest Case '-[A c]' passed (0.1 seconds).",
        b"warning: /x/M.pcm: No such file", b"\t Executed 2 tests, with 0 failures (0 unexpected) in 0.1 (0.2) seconds",
        b"y" * 70_000,
    ]

    def assert_equivalent(self, case: dict, *, piece_size: int | None = None, max_pending: int = metrics.MAX_PENDING_RECORD_BYTES):
        cursor_recorder, cursor_payload, _ = drive(case, piece_size=piece_size, cursor=True, max_pending=max_pending)
        reference_recorder, reference_payload, dropped = drive(case, piece_size=piece_size, cursor=False, max_pending=max_pending)
        self.assertTrue(cursor_payload["output"]["complete"])
        self.assertEqual(cursor_payload["output"]["droppedBytes"], dropped)
        reference_payload = json.loads(json.dumps(reference_payload))
        reference_payload["output"]["droppedBytes"] = dropped
        self.assertEqual(json.loads(json.dumps(cursor_payload)), reference_payload)
        self.assertEqual(cursor_recorder.events(), reference_recorder.events())
        self.assert_span_invariants(cursor_payload)

    def test_fixtures_match_reference_splitter(self) -> None:
        for name in FIXTURE_NAMES:
            for size in (None, 1, 3, 7):
                with self.subTest(fixture=name, piece_size=size):
                    self.assert_equivalent(load_case(name), piece_size=size)

    def test_fuzzed_streams_match_reference_splitter(self) -> None:
        import random

        rng = random.Random(20261005)
        for index in range(30):
            stream = b"".join(rng.choice(self.FUZZ_TOKENS) for _ in range(500))
            onlcr = stream.replace(b"\n", b"\r\n")
            for shape, data in (("raw", stream), ("onlcr", onlcr)):
                reads, position, ns = [], 0, 0
                while position < len(data):
                    size = rng.choice((1, 2, 5, 64, 700, 4096, 65536))
                    piece = data[position:position + size]
                    if rng.random() < 0.4 and b"\n" in piece:
                        piece = piece[:piece.index(b"\n") + 1]  # readline-shaped read
                    position += len(piece)
                    ns += rng.choice((0, 1, 1000))
                    reads.append((piece, ns))
                case = reads_case(reads, ns + 5, prefix_steps=({"boundary": metrics.COMMAND_START, "atMs": 0, "metadata": {"command": "/r/canonical_swift.sh test"}},))
                for max_pending in (metrics.MAX_PENDING_RECORD_BYTES, 16):
                    with self.subTest(stream=index, shape=shape, max_pending=max_pending):
                        self.assert_equivalent(case, max_pending=max_pending)

    def run_reads(self, reads, eof_ns=99, **kwargs):
        _, payload, _ = drive(reads_case(reads, eof_ns), cursor=True, **kwargs)
        return payload

    def test_bare_cr_record_keeps_the_earlier_read_time(self) -> None:
        payload = self.run_reads([(b"[1/2] Compiling M A.swift\r", 10 * MS), (b"tail\n", 20 * MS)])
        self.assertEqual(payload["output"]["records"], 2)
        self.assertEqual(payload["segments"][0]["timeToFirstBuildWork"], {"ns": 0, "quality": "observed_wall"})
        self.assertEqual(payload["segments"][0]["openOffsetNs"], 10 * MS)
        self.assertEqual(payload["output"]["observedSpan"]["ns"], 10 * MS)

    def test_crlf_split_across_reads_is_one_record(self) -> None:
        payload = self.run_reads([(b"abc\r", 1), (b"\nnext\n", 2)])
        self.assertEqual(payload["output"]["records"], 2)
        payload = self.run_reads([(b"abc\r\nx\r\n", 1)])
        self.assertEqual(payload["output"]["records"], 2)

    def test_several_cr_records_in_one_lf_line(self) -> None:
        payload = self.run_reads([(b"\x1b[2K[1/3] Write a\r\x1b[2K[2/3] Write b\r[3/3] Linking P\n", 5)])
        self.assertEqual(payload["output"]["records"], 3)
        self.assertEqual(payload["segments"][0]["writeRecords"], 2)
        self.assertEqual(payload["segments"][0]["linkedProducts"], ["P"])

    def test_observe_line_uses_the_callers_decoded_text(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        cursor = metrics.OutputTelemetryCursor(recorder)
        cursor.observe_line(b"Build complete! (1.00s)\n", "Build complete! (2.00s)\n", 5)
        cursor.finish(None, None, 6)
        payload = recorder.finalize()
        self.assertEqual(payload["segments"][0]["reportedBuild"]["ns"], 2 * 10**9)

    def test_long_records_truncate_like_the_splitter(self) -> None:
        cap = metrics.MAX_PENDING_RECORD_BYTES
        payload = self.run_reads([(b"a" * (cap + 10) + b"\rb\n", 1), (b"c" * (cap + 3), 2)])
        self.assertEqual(payload["output"]["records"], 3)
        self.assertEqual(payload["output"]["truncatedRecords"], 2)
        self.assertEqual(payload["output"]["droppedBytes"], 13)

    def test_truncated_compile_record_is_inexact_on_both_observer_paths(self) -> None:
        cap = metrics.MAX_PENDING_RECORD_BYTES
        names = [f"File{i:06d}.swift" for i in range(6000)]
        record = ("[1/9] Compiling Mod " + ", ".join(names)).encode()
        visible = [name for name in record[:cap].decode().partition("Compiling Mod ")[2].split(", ") if name]
        self.assertGreater(len(record), cap)
        self.assertNotIn(visible[-1], names)  # the cap cuts a name: a prefix must never count
        expected = visible[:-1]
        self.assertTrue(set(expected) <= set(names))
        other = b"[2/9] Compiling Other A.swift, B.swift\n"
        shapes = {
            "lf": [(record + b"\n", 1), (other, 2)],
            "bare_cr": [(record + b"\r", 1), (other, 2)],
            "eof": [(other, 1), (record, 2)],
        }
        for shape, reads in shapes.items():
            for cursor in (True, False):
                with self.subTest(shape=shape, cursor=cursor):
                    _, payload, _ = drive(reads_case(reads, 99), cursor=cursor)
                    segment = payload["segments"][0]
                    self.assertEqual(segment["modules"]["Mod"], {"compiledFiles": len(expected), "exact": False, "emittedModule": False})
                    self.assertEqual(segment["modules"]["Other"], {"compiledFiles": 2, "exact": True, "emittedModule": False})
                    self.assertFalse(segment["compiledFilesExact"])
                    self.assertEqual(segment["compileRecords"], 2)
                    self.assertEqual(payload["bounds"]["truncatedCompileRecords"], 1)
                    self.assertEqual(payload["bounds"]["unresolvedFileObservations"], 0)
                    self.assertEqual(payload["status"], "partial")
                    if cursor:
                        self.assertEqual(payload["output"]["truncatedRecords"], 1)
            self.assert_equivalent(reads_case(shapes[shape], 99))

    def test_untruncated_long_compile_record_stays_exact(self) -> None:
        cap = metrics.MAX_PENDING_RECORD_BYTES
        record = ("[1/9] Compiling Mod " + ", ".join(f"F{i}.swift" for i in range(5000))).encode()[:cap]
        record = record[:record.rfind(b", ")]
        for terminator in (b"\n", b"\r\n"):
            for cursor in (True, False):
                with self.subTest(terminator=terminator, cursor=cursor):
                    _, payload, _ = drive(reads_case([(record + terminator, 1)], 9), cursor=cursor)
                    module = payload["segments"][0]["modules"]["Mod"]
                    self.assertTrue(module["exact"])
                    self.assertEqual(module["compiledFiles"], record.count(b", ") + 1)
                    self.assertEqual(payload["bounds"]["truncatedCompileRecords"], 0)
                    self.assertEqual(payload["status"], "complete")

    def test_cursor_failure_is_contained_and_marks_output_failed(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary(metrics.POPEN_AFTER, 1)
        cursor = metrics.OutputTelemetryCursor(recorder)
        cursor.observe_line(b"x\n", None, 2)  # type: ignore[arg-type]
        self.assertFalse(cursor.active)
        cursor.observe_line(b"Build complete! (1.00s)\n", "Build complete! (1.00s)\n", 3)
        cursor.scan_pending(bytearray(b"y\r"), 3)
        cursor.finish(None, None, 4)
        payload = recorder.finalize()
        self.assertEqual(payload["status"], "partial")
        self.assertFalse(payload["output"]["complete"])
        self.assertIsNone(payload["output"]["records"])
        self.assertIn("AttributeError", payload["output"]["error"])
        self.assertEqual(payload["segments"], [])
        self.assertEqual(payload["intervals"]["spawnToFirstOutput"]["quality"], "unavailable")
        self.assert_span_invariants(payload)

    def test_classifier_failure_disables_only_output(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        cursor = metrics.OutputTelemetryCursor(recorder)
        with mock.patch.object(metrics, "classify_record", side_effect=RuntimeError("boom")):
            cursor.observe_line(b"Build complete! (1.00s)\n", "Build complete! (1.00s)\n", 3)
        cursor.finish(None, None, 4)
        recorder.record_boundary(metrics.LANE_RELEASED, 5)
        payload = recorder.finalize()
        self.assertFalse(recorder.failed)
        self.assertIn("RuntimeError: boom", payload["output"]["error"])
        self.assertEqual(payload["status"], "partial")

    def test_finalize_before_finish_reports_incomplete_output_not_zero(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        cursor = metrics.OutputTelemetryCursor(recorder)
        cursor.observe_line(b"a\n", "a\n", 1)
        payload = recorder.finalize()
        self.assertEqual(payload["output"]["records"], None)
        self.assertEqual(payload["output"]["observedSpan"], {"ns": None, "quality": "unavailable", "reason": "output_incomplete"})
        self.assertEqual(payload["status"], "partial")
        cursor.observe_line(b"Build complete! (1.00s)\n", "Build complete! (1.00s)\n", 2)
        cursor.finish(None, None, 3)
        self.assertIs(recorder.finalize(), payload)

    def test_disabled_or_finalized_recorder_never_attaches(self) -> None:
        for recorder in (metrics.PipelineRecorder(origin_ns=0, enabled=False), metrics.PipelineRecorder(origin_ns=0)):
            if recorder.enabled:
                recorder.finalize()
            cursor = metrics.OutputTelemetryCursor(recorder)
            self.assertFalse(cursor.active)
            cursor.observe_line(b"a\n", "a\n", 1)
            cursor.finish(b"b", "b", 2)

    def test_method_records_after_first_method_skip_classification(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary(metrics.COMMAND_START, 0, {"command": "/r/canonical_swift.sh test"})
        cursor = metrics.OutputTelemetryCursor(recorder)
        lines = [b"Test Suite 'All' started at 2026-10-05 10:00:00.000.\n", b"Test Case '-[A a]' started.\n"]
        for line in lines:
            cursor.observe_line(line, line.decode(), 1)
        calls = []
        real = metrics.classify_record
        with mock.patch.object(metrics, "classify_record", side_effect=lambda text: calls.append(text) or real(text)):
            for i in range(50):
                line = f"\x1b[32mTest Case '-[A t{i}]' started.\x1b[0m\n".encode()
                cursor.observe_line(line, line.decode(), 2 + i)
            cursor.observe_line(b"Test Suite 'All' passed at 2026-10-05 10:00:01.000.\n", "Test Suite 'All' passed at 2026-10-05 10:00:01.000.\n", 60)
        cursor.finish(None, None, 61)
        self.assertEqual(len(calls), 1)  # only the suite record reached the classifier
        payload = recorder.finalize()
        self.assertEqual(payload["output"]["records"], 53)
        self.assertEqual(payload["segments"][0]["xctestObserved"]["ns"], 59)


class IntervalDerivationTests(unittest.TestCase):
    def b(self, name, ns, process="daemon", **meta):
        return metrics.Boundary(name, ns, process, meta)

    def test_missing_evidence_is_never_zero(self) -> None:
        intervals = metrics.derive_intervals([])
        self.assertEqual(set(intervals), set(metrics.INTERVAL_NAMES))
        for value in intervals.values():
            self.assertEqual((value["ns"], value["quality"]), (None, metrics.UNAVAILABLE))

    def test_reversed_cross_process_and_not_applicable(self) -> None:
        intervals = metrics.derive_intervals(
            [self.b("popen_before", 10), self.b("popen_after", 5),
             self.b("request_accepted", 1, "runner"), self.b("lane_dispatched", 2)],
            not_applicable_names=["prepare"],
        )
        self.assertEqual(intervals["spawn"], {"ns": None, "quality": "unavailable", "reason": "non_monotonic"})
        self.assertEqual(intervals["queueWait"], {"ns": None, "quality": "unavailable", "reason": "cross_process"})
        self.assertEqual(intervals["prepare"], {"ns": None, "quality": "not_applicable"})
        self.assertEqual(intervals["exitToLaneRelease"]["reason"], "missing_start_and_end")

    def test_first_occurrence_wins(self) -> None:
        intervals = metrics.derive_intervals([self.b("popen_before", 1), self.b("popen_before", 5), self.b("popen_after", 9)])
        self.assertEqual(intervals["spawn"]["ns"], 8)

    def test_slot_wait_pairing_and_unmatched(self) -> None:
        waits = metrics.derive_slot_waits([
            self.b("slot_wait_start", 0, slot="heavy", contended=True),
            self.b("slot_wait_start", 1, slot="xctest"),
            self.b("slot_wait_end", 4, slot="heavy"),
            self.b("slot_wait_end", 9, slot="other"),
        ])
        self.assertEqual(waits[0], {"ns": 4, "quality": "measured_wall", "slot": "heavy", "contended": True})
        self.assertEqual(waits[1]["quality"], "unavailable")
        self.assertEqual((waits[1]["slot"], waits[1]["reason"]), ("other", "missing_start"))
        self.assertEqual((waits[2]["slot"], waits[2]["reason"]), ("xctest", "missing_end"))

    def test_span_constructor_rejects_unknown_as_zero(self) -> None:
        with self.assertRaises(metrics.MetricsError):
            metrics.span(0, metrics.UNAVAILABLE)
        with self.assertRaises(metrics.MetricsError):
            metrics.span(None, metrics.MEASURED_WALL)
        with self.assertRaises(metrics.MetricsError):
            metrics.span(1, "made_up")
        with self.assertRaises(metrics.MetricsError):
            metrics.span(1.5, metrics.MEASURED_WALL)


class ContainmentTests(SpanInvariantMixin, unittest.TestCase):
    def test_internal_failure_degrades_without_raising(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary("request_accepted", 1)
        with mock.patch.object(metrics, "classify_record", side_effect=RuntimeError("boom")):
            recorder.observe_records([metrics.OutputRecord(0, 2, "Build complete! (1.00s)", "lf")])
        self.assertTrue(recorder.failed)
        recorder.record_boundary("lane_released", 3)
        recorder.record_operation("summary", 1, {}, "x")
        payload = recorder.finalize()
        self.assertEqual(payload["status"], "failed")
        self.assertIn("RuntimeError: boom", payload["telemetryError"])
        for value in payload["intervals"].values():
            self.assertEqual((value["ns"], value["quality"]), (None, "unavailable"))
        self.assert_span_invariants(payload)

    def test_failure_while_building_payload_is_contained(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        with mock.patch.object(metrics, "derive_intervals", side_effect=ValueError("bad")):
            payload = recorder.finalize()
        self.assertEqual(payload["status"], "failed")

    def test_invalid_inputs_are_counted_not_raised(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary("", 1)
        recorder.record_boundary("x" * 100, 1)
        recorder.record_boundary("ok", 1.5)  # type: ignore[arg-type]
        recorder.record_boundary("ok", True)  # type: ignore[arg-type]
        recorder.observe_records([{"text": 3, "receive_ns": 1}, {"text": "a"}, {"text": "a", "receiveNs": 4}])
        recorder.record_operation("op", -1, {}, "o")
        recorder.record_operation("op", 1, {}, "o", quality="unavailable")
        recorder.record_operation("op", 1, {"bad": "x", "ok": 2}, "o")
        payload = recorder.finalize()
        self.assertEqual(payload["status"], "complete")
        self.assertEqual(payload["invalidInputs"], 9)
        self.assertEqual(payload["output"]["records"], 1)
        self.assertEqual(payload["operations"][0]["counters"], {"ok": 2})

    def test_disabled_recorder_is_inert(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0, enabled=False)
        recorder.record_boundary("request_accepted", 1)
        recorder.observe_records([metrics.OutputRecord(0, 2, "Build complete! (1.00s)", "lf")])
        self.assertEqual(recorder.events(), [])
        self.assertEqual(recorder.finalize(), {"schema": 1, "status": "disabled", "process": "daemon"})

    def test_operation_sink_and_metadata_bounds(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        sink = recorder.operation_sink("prelaunch")
        sink("fingerprint", 5, {"bytesHashed": 10})
        sink("fingerprint", 7, {"bytesHashed": 10}, monotonic_ns=3)
        recorder.record_boundary("prepare_start", 1, {"blob": "z" * 5000, "obj": object()})
        recorder.record_boundary("prepare_end", 2, {f"k{i}": "v" * 200 for i in range(20)})
        payload = recorder.finalize()
        self.assertEqual(payload["operations"][0]["total"], {"ns": 12, "quality": "measured_wall"})
        self.assertEqual(payload["operations"][0]["counters"], {"bytesHashed": 20})
        boundary_events = [e for e in recorder.events() if e["k"] == "boundary"]
        self.assertEqual(len(boundary_events[0]["meta"]["blob"]), metrics.MAX_CONTEXT_CHARS)
        self.assertEqual(boundary_events[1]["meta"], {"truncated": True})

    def test_mixed_operation_quality_is_unavailable(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_operation("summary", 5, None, "x", quality=metrics.MEASURED_CPU)
        recorder.record_operation("summary", 5, None, "x")
        total = recorder.finalize()["operations"][0]["total"]
        self.assertEqual(total, {"ns": None, "quality": "unavailable", "reason": "mixed_quality"})

    def test_concurrent_observation_is_exact(self) -> None:
        recorder = metrics.PipelineRecorder(origin_ns=0)
        recorder.record_boundary(metrics.COMMAND_START, 0, {"command": "/r/canonical_swift.sh build"})

        def worker(offset: int) -> None:
            for i in range(500):
                recorder.observe_records([metrics.OutputRecord(i, 10 + i, f"[{i}/1] Compiling M{offset} F{i}.swift", "cr")])
                recorder.record_operation("summary", 1, {"n": 1}, "w")

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        payload = recorder.finalize()
        self.assertEqual(payload["output"]["records"], 2000)
        self.assertEqual(payload["segments"][0]["compileRecords"], 2000)
        self.assertEqual(payload["operations"][0]["calls"], 2000)
        self.assertEqual(payload["operations"][0]["counters"], {"n": 2000})


class RotatingJsonlTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "metrics" / "build-metrics.jsonl"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_rotation_keeps_two_generations_in_order(self) -> None:
        history = metrics.RotatingJsonl(self.path, max_bytes=60)
        for i in range(12):
            history.append({"i": i, "pad": "xxxxxxxxxx"})
        rows, malformed = history.read_rows()
        self.assertEqual(malformed, 0)
        ids = [row["i"] for row in rows]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(ids[-1], 11)
        self.assertLess(len(ids), 12)
        existing = [p.name for p in history.generation_paths() if p.exists()]
        self.assertEqual(existing, ["build-metrics.jsonl.2", "build-metrics.jsonl.1", "build-metrics.jsonl"])
        self.assertFalse(self.path.with_name("build-metrics.jsonl.3").exists())
        for path in history.generation_paths():
            self.assertLessEqual(path.stat().st_size, 60)

    def test_malformed_and_truncated_lines_are_skipped(self) -> None:
        history = metrics.RotatingJsonl(self.path)
        history.append({"i": 1})
        with self.path.open("ab") as handle:
            handle.write(b'[1,2]\n{"i": 2\n')
        history.append({"i": 3})
        rows, malformed = history.read_rows()
        self.assertEqual([row["i"] for row in rows], [1, 3])
        self.assertEqual(malformed, 2)

    def test_oversized_row_is_rejected_without_writing(self) -> None:
        history = metrics.RotatingJsonl(self.path, max_row_bytes=32)
        with self.assertRaises(metrics.MetricsError):
            history.append({"blob": "x" * 64})
        self.assertFalse(self.path.exists())

    def test_missing_history_reads_empty(self) -> None:
        self.assertEqual(metrics.RotatingJsonl(self.path).read_rows(), ([], 0))

    def test_busy_history_lock_is_bounded_and_writes_nothing(self) -> None:
        import fcntl

        self.assertEqual(metrics.RotatingJsonl(self.path).lock_timeout, metrics.HISTORY_LOCK_TIMEOUT_SECONDS)
        history = metrics.RotatingJsonl(self.path, lock_timeout=0.1)
        self.path.parent.mkdir(parents=True)
        with self.path.with_name(self.path.name + ".lock").open("a+") as holder:
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
            started = time.monotonic()
            with self.assertRaisesRegex(metrics.MetricsError, "history lock busy"):
                history.append({"i": 1})
            self.assertLess(time.monotonic() - started, 2.0)
            self.assertFalse(self.path.exists())
            fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
            history.append({"i": 2})
        self.assertEqual(history.read_rows(), ([{"i": 2}], 0))
        with self.assertRaises(metrics.MetricsError):
            metrics.RotatingJsonl(self.path, lock_timeout=-1)


class HelperTests(unittest.TestCase):
    def test_timing_kill_switch(self) -> None:
        self.assertTrue(metrics.timing_enabled({}))
        self.assertTrue(metrics.timing_enabled({"RPCE_CONDUCTOR_TIMING": "on"}))
        self.assertFalse(metrics.timing_enabled({"RPCE_CONDUCTOR_TIMING": "off"}))
        self.assertFalse(metrics.timing_enabled({"RPCE_CONDUCTOR_TIMING": " OFF "}))

    def test_content_digest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a = Path(tmp) / "conductor.py"
            a.write_bytes(b"one")
            first = metrics.content_digest([a])
            self.assertTrue(first.startswith("sha256:"))
            self.assertEqual(metrics.content_digest([a]), first)
            a.write_bytes(b"two")
            self.assertNotEqual(metrics.content_digest([a]), first)
            self.assertIsNone(metrics.content_digest([a, Path(tmp) / "missing.py"]))

    def test_atomic_writers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "t.timings.json"
            metrics.atomic_write_json(target, {"b": 1, "a": None})
            self.assertEqual(json.loads(target.read_text()), {"a": None, "b": 1})
            events = Path(tmp) / "t.timing-events.jsonl"
            metrics.write_events_jsonl(events, [{"k": "a"}, {"k": "b"}])
            self.assertEqual([json.loads(l)["k"] for l in events.read_text().splitlines()], ["a", "b"])
            self.assertEqual(sorted(os.listdir(tmp)), ["t.timing-events.jsonl", "t.timings.json"])

    def test_history_row_and_filtering(self) -> None:
        _, payload = replay(load_case("compile-cr"))
        row = metrics.history_row(payload, ticket="T1", kind="test", finished_wall_ns=None, conductor_digest=None, exit_code=0)
        self.assertNotIn("modules", row["segments"][0])
        self.assertEqual((row["segments"][0]["moduleCount"], row["segments"][0]["compiledFiles"]), (2, 5))
        self.assertIsNone(row["finishedAtWallNs"])
        rows = [{"kind": "test", "ticket": "a"}, {"kind": "build", "ticket": "b"}, {"kind": "test", "ticket": "c"}]
        self.assertEqual(metrics.filter_history(rows, kind="test", last=1), [rows[2]])
        self.assertEqual(metrics.filter_history(rows, ticket="b"), [rows[1]])
        self.assertEqual(metrics.filter_history(rows, last=0), [])

    def test_xctest_timestamp_parse(self) -> None:
        self.assertEqual(metrics.parse_xctest_timestamp("2026-10-05 10:16:41.280", timezone.utc), 1791195401280000000)
        self.assertIsNone(metrics.parse_xctest_timestamp("garbage", timezone.utc))


class StatisticsTests(unittest.TestCase):
    def test_median_and_percentile(self) -> None:
        self.assertEqual(metrics.median([3, 1, 2]), 2)
        self.assertEqual(metrics.median([4, 1, 2, 3]), 2.5)
        self.assertEqual(metrics.percentile([1, 2, 3, 4, 5], 90), 4.6)
        with self.assertRaises(metrics.MetricsError):
            metrics.median([])

    def test_bootstrap_is_deterministic(self) -> None:
        diffs = [0.01 * ((i * 7) % 11) for i in range(30)]
        self.assertEqual(metrics.bootstrap_median_ci(diffs, seed=4), metrics.bootstrap_median_ci(diffs, seed=4))
        low, high = metrics.bootstrap_median_ci(diffs, block_size=2)
        self.assertLessEqual(low, metrics.median(diffs))
        self.assertGreaterEqual(high, metrics.median(diffs))

    def series(self, base: float, delta: float, n: int = 30, jitter: float = 0.002):
        baseline = [base + jitter * ((i * 5) % 7) for i in range(n)]
        return baseline, [value + delta for value in baseline]

    def test_compare_paired_verdicts(self) -> None:
        baseline, slower = self.series(10.0, 1.0)
        result = metrics.compare_paired(baseline, slower, floor_abs=0.5)
        self.assertEqual((result.verdict, result.exit_code), ("regression", 1))
        baseline, same = self.series(10.0, 0.0)
        result = metrics.compare_paired(baseline, same, floor_abs=0.5)
        self.assertEqual((result.verdict, result.exit_code), ("qualified", 0))
        noisy = [b + (2.0 if i % 2 else -1.6) for i, b in enumerate(baseline)]
        result = metrics.compare_paired(baseline, noisy, floor_abs=0.5)
        self.assertEqual((result.verdict, result.exit_code), ("inconclusive", 2))
        self.assertEqual(result.to_json()["exitCode"], 2)

    def test_missing_or_incompatible_evidence_never_passes(self) -> None:
        baseline, same = self.series(10.0, 0.0)
        with_gap = list(same)
        with_gap[3] = None
        self.assertEqual(metrics.compare_paired(baseline, with_gap, floor_abs=0.5).reasons, ("missing_evidence",))
        self.assertEqual(metrics.compare_paired(baseline[:5], same[:5], floor_abs=0.5).exit_code, 2)
        self.assertEqual(metrics.compare_paired(baseline, same[:-1], floor_abs=0.5).exit_code, 3)
        result = metrics.compare_paired(
            baseline, same, floor_abs=0.5,
            baseline_meta={"toolchain": "6.3.1", "fixture": "v1"}, candidate_meta={"toolchain": "6.3.2"},
            match_keys=("toolchain", "fixture"),
        )
        self.assertEqual((result.exit_code, result.reasons), (2, ("incompatible:toolchain", "incompatible:fixture")))
        result = metrics.compare_paired(baseline, same, floor_abs=0.5, baseline_meta=None, candidate_meta=None, match_keys=("toolchain",))
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(metrics.metadata_mismatches({"k": None}, {"k": None}, ["k"]), ["k"])

    def test_relative_floor_dominates_large_baselines(self) -> None:
        baseline, slower = self.series(100.0, 4.0)
        result = metrics.compare_paired(baseline, slower, floor_abs=0.5)
        self.assertAlmostEqual(result.threshold, 5.0, places=3)
        self.assertNotEqual(result.verdict, "regression")

    def test_overhead_gate(self) -> None:
        off, on = self.series(2.0, 0.010)
        self.assertEqual(metrics.overhead_gate(on, off).verdict, "qualified")
        off, on = self.series(2.0, 0.060)
        self.assertEqual(metrics.overhead_gate(on, off).exit_code, 1)
        off, on = self.series(10.0, 0.060)
        result = metrics.overhead_gate(on, off)
        self.assertAlmostEqual(result.threshold, 0.1, places=3)
        self.assertEqual(result.verdict, "qualified")
        self.assertEqual(metrics.overhead_gate(on[:29], off[:29]).exit_code, 2)
        self.assertEqual(metrics.overhead_gate(on, off, process_wall=[None]).exit_code, 2)

    def test_aa_equivalence(self) -> None:
        a, b = self.series(10.0, 0.05, n=10)
        self.assertEqual(metrics.aa_equivalence(a, b, bound_abs=0.15).verdict, "qualified")
        a, b = self.series(10.0, 0.5, n=10)
        self.assertEqual(metrics.aa_equivalence(a, b, bound_abs=0.15).exit_code, 2)


if __name__ == "__main__":
    unittest.main()
