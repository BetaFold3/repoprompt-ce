#!/usr/bin/env python3
"""Deterministic tests for Scripts/conductor_benchmark.py and the _pump_output seam."""

from __future__ import annotations

import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402
import conductor_benchmark as bench  # noqa: E402


def make_state(tmp: Path) -> conductor.DaemonState:
    return conductor.DaemonState(bench.target_paths(conductor, tmp))


class PumpOutputSeamTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = make_state(Path(self.tmp.name))
        self.job = bench.make_job(conductor, self.state.paths, "seam", "build", {})
        self.state.jobs[self.job.ticket] = self.job

    def test_pump_relays_every_chunk_unchanged_and_submits_lines_then_unterminated_tail(self) -> None:
        chunks = [b"alpha\r be", b"ta\ngam", b"ma\n\xe2\x9c", b"\x93 tail", b""]
        sink = mock.Mock()
        writes: list[bytes] = []
        sink.write.side_effect = writes.append

        self.state._pump_output(self.job.ticket, iter(chunks).__next__, sink)

        self.assertEqual(writes, chunks[:-1])
        self.assertEqual(sink.flush.call_count, len(chunks) - 1)
        # Step 3 (OD7) exact shape: CR-segmented records, each terminated by "\n"
        # except the unterminated final record.
        self.assertEqual(list(self.job.tail), ["alpha\n", " beta\n", "gamma\n", "✓ tail"])

    def test_pump_flushes_pending_partial_line_when_the_reader_raises(self) -> None:
        reads = iter([b"done\npartial"])

        def read_chunk() -> bytes:
            try:
                return next(reads)
            except StopIteration:
                raise OSError("fixture read failure")

        with self.assertRaises(OSError):
            self.state._pump_output(self.job.ticket, read_chunk, io.BytesIO())
        self.assertEqual(list(self.job.tail), ["done\n", "partial"])

    def test_read_process_output_closes_the_reader_after_success_and_failure(self) -> None:
        for failure in (False, True):
            with self.subTest(failure=failure):
                transport = mock.Mock()
                transport.read_chunk.side_effect = [b"x\n", OSError("boom")] if failure else [b"x\n", b""]
                log = io.BytesIO()
                if failure:
                    with self.assertRaises(OSError):
                        self.state._read_process_output(self.job.ticket, mock.Mock(), log, transport)
                else:
                    self.state._read_process_output(self.job.ticket, mock.Mock(), log, transport)
                self.assertEqual(log.getvalue(), b"x\n")
                transport.close_reader.assert_called_once_with()


class FixtureTests(unittest.TestCase):
    def test_splitmix64_sequence_is_pinned(self) -> None:
        rng = bench.SplitMix64(0)
        self.assertEqual([rng.next() for _ in range(2)], [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4])

    def test_output_fixture_matches_manifest_digest_and_required_shape(self) -> None:
        manifest = bench.load_manifest()
        data = bench.generate_output_fixture(manifest["output"]["seed"], manifest["output"]["sizeBytes"])
        self.assertEqual(len(data), 5 * 2**20)
        self.assertEqual(bench.sha256_bytes(data), manifest["output"]["sha256"])
        self.assertFalse(data.endswith(b"\n"))
        lf_lines = data.split(b"\n")
        self.assertGreater(len(lf_lines), 50_000)
        self.assertGreater(data.count(b"\r"), 5_000)
        self.assertTrue(any(len(line) > 150_000 for line in lf_lines))
        self.assertGreater(data.count(b"' started."), 1_000)
        self.assertEqual(data.count(b"Build complete!"), 1)
        data.decode("utf-8")  # true for the pinned seed and size; truncation can split sequences in general

    def test_fixture_subcommand_verifies_the_manifest(self) -> None:
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(bench.main(["fixture"]), 0)

    def test_pty_fidelity_fixture_is_pinned_retry_free_and_wider_than_the_visible_tail(self) -> None:
        _output, fidelity = bench.verified_fixtures(MANIFEST)
        translated = bench.onlcr(fidelity)
        self.assertLessEqual(len(translated), bench.PTY_FIDELITY_MAX_BYTES)
        entries = reference_tail_entries(translated)
        self.assertGreater(len(entries), conductor.LOG_TAIL_LINES)
        self.assertEqual(bench.canonical_json_digest(entries[-conductor.LOG_TAIL_LINES:]), EXPECTED_PTY_TAIL)
        visible = entries[-conductor.LOG_TAIL_LINES:]
        for boundary in ("warning: crlf\r", "\r\n", "page\x0c", "nel\x85", "bad � byte\r\n", "\x1b[2K[3/3] Linking A\r\n"):
            self.assertIn(boundary, visible)
        self.assertEqual(visible[-1], "tail without newline")


class TransportIntegrityTests(unittest.TestCase):
    WRITTEN = b"one\ntwo\r\nthree"

    def test_pipe_requires_byte_identity(self) -> None:
        self.assertEqual(bench.verify_transport_stream("pipe", self.WRITTEN, self.WRITTEN), [])
        with self.assertRaises(bench.HarnessError):
            bench.verify_transport_stream("pipe", self.WRITTEN, self.WRITTEN[:-1])

    def test_pty_accepts_onlcr_and_one_retried_cr_at_its_exact_position_only(self) -> None:
        translated = bench.onlcr(self.WRITTEN)
        self.assertEqual(translated, b"one\r\ntwo\r\r\nthree")
        self.assertEqual(bench.verify_transport_stream("pty", self.WRITTEN, translated), [])
        retried = translated.replace(b"one\r\n", b"one\r\r\n")
        self.assertEqual(bench.verify_transport_stream("pty", self.WRITTEN, retried), [3])
        self.assertEqual(bench.verify_transport_stream("pty", self.WRITTEN, b"one\r\ntwo\r\r\r\nthree"), [9])

    def test_pty_rejects_deleted_relocated_doubled_or_misplaced_crs(self) -> None:
        cases = {
            "relocated original CR": (b"a\rb\n", b"ab\r\r\n"),
            "deleted original CR": (b"a\rb\n", b"ab\r\n"),
            "deleted ONLCR CR": (b"a\nb", b"a\nb"),
            "CR inserted mid-record": (b"ab\n", b"a\rb\r\n"),
            "CR inserted after LF": (b"a\nb", b"a\r\n\rb"),
            "two retried CRs": (b"a\nb", b"a\r\r\r\nb"),
            "truncated": (self.WRITTEN, bench.onlcr(self.WRITTEN)[:-1]),
            "changed byte": (self.WRITTEN, bench.onlcr(self.WRITTEN).replace(b"two", b"twx")),
            "trailing bytes": (self.WRITTEN, bench.onlcr(self.WRITTEN) + b"\r"),
        }
        for name, (written, read) in cases.items():
            with self.subTest(name), self.assertRaises(bench.HarnessError):
                bench.verify_transport_stream("pty", written, read)

    def test_pty_tail_evidence_removes_retried_crs_at_their_offsets_and_digests_a_fixed_suffix(self) -> None:
        written = b"".join(f"line {index:04d} {'x' * 30}\n".encode() for index in range(200)) + b"end"
        plain = bench.onlcr(written)
        line = f"line 0198 {'x' * 30}".encode()
        retried = plain.replace(line + b"\r\n", line + b"\r\r\n")
        offsets = bench.verify_transport_stream("pty", written, retried)
        self.assertEqual(len(offsets), 1)

        def tail_of(read: bytes) -> list[str]:
            return read.decode().splitlines(keepends=True)[-30:]

        evidence = bench.pty_tail_evidence(tail_of(retried), retried, offsets)
        self.assertTrue(evidence["suffixOfStream"])
        self.assertEqual(evidence, bench.pty_tail_evidence(tail_of(plain), plain, []))
        self.assertNotEqual(evidence, bench.pty_tail_evidence(tail_of(retried), retried, []))
        self.assertFalse(bench.pty_tail_evidence(["not the stream"], plain, [])["suffixOfStream"])


def reference_tail_entries(read: bytes) -> list[str]:
    """Visible-tail reference model: LF records, UTF-8 with replacement, str.splitlines per record."""
    records = read.split(b"\n")
    entries: list[str] = []
    for index, record in enumerate(records):
        data = record if index == len(records) - 1 else record + b"\n"
        entries += data.decode("utf-8", errors="replace").splitlines(keepends=True)
    return entries


class ExactTailEvidenceTests(unittest.TestCase):
    """OracleA-003: suffix evidence tolerates transport noise; exact evidence sees every entry and boundary."""

    def test_dropped_entries_and_moved_boundaries_change_exact_but_not_suffix_evidence(self) -> None:
        written = b"".join(f"line {index:04d} {'x' * 30}\n".encode() for index in range(200)) + b"end"
        read = bench.onlcr(written)
        full = read.decode().splitlines(keepends=True)[-30:]
        truncated = full[-15:]
        merged = full[:-3] + [full[-3] + full[-2], full[-1]]
        self.assertGreater(len("".join(truncated)), bench.PTY_TAIL_EVIDENCE_BYTES)
        for name, changed in (("15 of 30 entries", truncated), ("merged boundary", merged)):
            with self.subTest(name):
                self.assertEqual(bench.pty_tail_evidence(changed, read, []), bench.pty_tail_evidence(full, read, []))
                self.assertNotEqual(bench.canonical_json_digest(changed), bench.canonical_json_digest(full))

    def test_fidelity_run_requires_exact_delivery(self) -> None:
        retried = {"tty_retried_cr": 1, "bytes_read": 946, "tail_sha256": "x", "tail_entries": 30}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(bench, "_run_output_variant", return_value=retried):
            fixture = Path(tmp) / "fidelity.log"
            fixture.write_bytes(bench.generate_pty_fidelity_fixture())
            with self.assertRaises(bench.HarnessError):
                bench.run_pty_fidelity(conductor, {"scratchDir": tmp, "fidelityFixturePath": str(fixture)})


class StepThreeTailModelTests(unittest.TestCase):
    """The harness's independent OD7 tail model agrees with the conductor's real path."""

    def test_pinned_fidelity_digest_is_the_model_over_the_exact_pty_delivery(self) -> None:
        fidelity = bench.generate_pty_fidelity_fixture()
        self.assertEqual(
            bench.canonical_json_digest(bench.step3_tail_model(bench.onlcr(fidelity))),
            EXPECTED_STEP3_PTY_TAIL,
        )

    def test_model_matches_conductor_tail_over_shapes(self) -> None:
        cases = {
            "cr-crlf-lf": b"a\rb\r\nc\nd",
            "ansi": b"\x1b[31mred\x1b[0m\n\x1b[1mbold",
            "long": b"x" * 9000 + b"\n" + "é".encode() * 3000 + b"\n",
            "many": b"".join(f"{index}\n".encode() for index in range(100)),
            "budget": b"".join((b"y" * 5000 + b"\n") for _ in range(40)),
            "empty-records": b"\n\n\r\r\n\n",
            "invalid-utf8": b"bad \xff byte\npartial \xe2\x9c",
        }
        for name, data in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                state = make_state(Path(tmp))
                job = bench.make_job(conductor, state.paths, "model", "build", {})
                state.jobs[job.ticket] = job
                chunks = [data[index:index + 7] for index in range(0, len(data), 7)] + [b""]
                state._pump_output(job.ticket, iter(chunks).__next__, io.BytesIO())
                self.assertEqual(list(job.tail), bench.step3_tail_model(data))
                self.assertLessEqual(len(job.tail), 30)
                self.assertLessEqual(sum(len(entry.encode()) for entry in job.tail), 64 * 1024)


# The Step 3 conductor loads its output helper by explicit path; loadable copies need it.
STEP3_REQUIRED_HELPERS = ("Scripts/conductor_output.py",)


class StepThreeTailEnforcementTests(unittest.TestCase):
    """S3-R0-05: a Step 3 tail must equal the independent model, outside the measurement."""

    DATA = (
        b"\x1b[1malpha\x1b[0m\r\nprogress 1\rprogress 2\r\n"
        + b"".join(b"line %d\r\n" % index for index in range(40))
        + b"\xe2\x9c\x93 done"
    )

    def wrong_tails(self) -> dict:
        good = bench.step3_tail_model(self.DATA)
        return {
            "empty": [],
            "first-entry-removed": good[1:],
            "last-entry-removed": good[:-1],
            "boundaries-merged": [good[0] + good[1]] + good[2:],
            "boundary-moved": [good[0][:-2], good[0][-2:] + good[1]] + good[2:],
            "content-changed": good[:-1] + [good[-1].upper()],
            "raw-suffix-instead": [self.DATA[-200:].decode("utf-8", errors="replace")],
        }

    def test_model_conformance_rejects_wrong_tails(self) -> None:
        bench.verify_step3_tail(bench.step3_tail_model(self.DATA), self.DATA, "pipe")
        for name, tail in self.wrong_tails().items():
            with self.subTest(mutation=name), self.assertRaises(bench.HarnessError):
                bench.verify_step3_tail(tail, self.DATA, "pipe")

    def test_step3_pty_evidence_requires_conformance(self) -> None:
        good = bench.step3_tail_model(self.DATA)
        evidence = bench.pty_tail_evidence(good, self.DATA, [], step3=True)
        self.assertEqual(evidence["normalizedTailSha256"], bench.canonical_json_digest(good))
        for name, tail in self.wrong_tails().items():
            with self.subTest(mutation=name), self.assertRaises(bench.HarnessError):
                bench.pty_tail_evidence(tail, self.DATA, [], step3=True)

    def test_collection_fails_when_the_target_tail_is_wrong_for_pipe_and_pty(self) -> None:
        data = bench.generate_output_fixture(13, 64 * 1024)
        output = conductor.CONDUCTOR_OUTPUT
        real_entries = output.tail_entries

        def merged(records: object) -> list:
            entries = real_entries(records)
            return [(entries[0][0] + entries[1][0], entries[0][1] + entries[1][1])] + entries[2:] if len(entries) > 1 else entries

        mutations = {
            "empty": mock.patch.object(output.OutputTail, "extend_sized", lambda self, entries: None),
            "boundaries-merged": mock.patch.object(output, "tail_entries", side_effect=merged),
            "entry-dropped": mock.patch.object(output, "tail_entries", side_effect=lambda records: real_entries(records)[1:]),
        }
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture.log"
            fixture.write_bytes(data)
            spec = {"scratchDir": tmp}
            for transport in ("pipe", "pty"):
                result = bench._run_output_variant(conductor, spec, fixture, data, transport, 0)
                self.assertEqual(result["tail_model"], bench.STEP3_TAIL_MODEL_VALIDATED)
                for name, patcher in mutations.items():
                    with self.subTest(transport=transport, mutation=name), patcher:
                        with self.assertRaises(bench.HarnessError) as raised:
                            bench._run_output_variant(conductor, spec, fixture, data, transport, 0)
                        self.assertIn("independent model", str(raised.exception))

    def test_step3_targets_are_detected_by_helper_or_shipped_file(self) -> None:
        self.assertTrue(bench.is_step3_target(conductor))
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "conductor.py"
            module_file.write_text("", encoding="utf-8")
            legacy = mock.Mock(spec=["__file__"], __file__=str(module_file))
            self.assertFalse(bench.is_step3_target(legacy))
            (Path(tmp) / "conductor_output.py").write_text("", encoding="utf-8")
            self.assertTrue(bench.is_step3_target(legacy))  # shipped but not loaded: still validated

    def test_comparison_rejects_step3_arms_without_validation_records(self) -> None:
        validated = {variant: {"tailModel": bench.STEP3_TAIL_MODEL_VALIDATED} for variant in bench.STEP3_TAIL_VARIANTS}
        unvalidated = dict(validated, **{"output.pty.w4": {"tailModel": bench.LEGACY_TAIL_MODEL}})
        capture = {
            "arms": [
                {"name": "parent", "files": {"Scripts/conductor.py": "a"}},
                {"name": "candidate", "files": {"Scripts/conductor.py": "b", "Scripts/conductor_output.py": "c"}},
            ],
            "samples": [
                {"arm": "parent", "workload": "output", "ok": True, "block": 0, "info": {}},
                {"arm": "candidate", "workload": "output", "ok": True, "block": 0, "info": validated},
                {"arm": "candidate", "workload": "output", "ok": True, "block": 1, "info": unvalidated},
                {"arm": "candidate", "workload": "output", "ok": True, "block": 2, "info": {}},
            ],
        }
        self.assertEqual(bench.tail_model_problems("baseline", capture, "parent"), [])
        problems = bench.tail_model_problems("candidate", capture, "candidate")
        self.assertEqual([problem.split(":")[0] for problem in problems], ["candidate output block 1", "candidate output block 2"])
        self.assertIn("output.pty.w4", problems[0])

    def test_evaluate_comparison_fails_an_unvalidated_step3_arm(self) -> None:
        capture = synthetic_capture("/c.json", {"A": {"output.pipe.w0.cpu_ms": series(10.0)}, "B": {"output.pipe.w0.cpu_ms": series(10.0)}})
        capture["arms"][1]["files"] = {"Scripts/conductor.py": "b", "Scripts/conductor_output.py": "c"}
        report = bench.evaluate_comparison(capture, "A", capture, "B", ComparisonTests.GATES, "changed")
        self.assertTrue(any("Step 3 tail not validated" in failure for failure in report["harnessFailures"]))
        self.assertEqual(report["outcome"], "harness_failure")
        for sample in capture["samples"]:
            if sample["arm"] == "B":
                sample["info"] = {variant: {"tailModel": bench.STEP3_TAIL_MODEL_VALIDATED} for variant in bench.STEP3_TAIL_VARIANTS}
        report = bench.evaluate_comparison(capture, "A", capture, "B", ComparisonTests.GATES, "changed")
        self.assertFalse(any("Step 3 tail" in failure for failure in report["harnessFailures"]))


class TargetLoadingTests(unittest.TestCase):
    def make_target(self, root: Path, optional: tuple[str, ...] = ()) -> Path:
        (root / "Scripts").mkdir(parents=True)
        for relative in bench.TARGET_FILES + optional:
            shutil.copy2(bench.REPO_ROOT / relative, root / relative)
        return root

    def test_required_only_target_keeps_its_step1_digest_and_optional_helper_is_covered(self) -> None:
        import hashlib

        with tempfile.TemporaryDirectory() as tmp:
            legacy = self.make_target(Path(tmp) / "legacy")
            combined = hashlib.sha256()
            for relative in bench.TARGET_FILES:  # the Step 1 (harness v4) formula
                combined.update(f"{relative}\0{bench.sha256_file(legacy / relative)}\n".encode())
            self.assertEqual(bench.target_digest(legacy)["conductorDigest"], combined.hexdigest())
            self.assertEqual(list(bench.target_digest(legacy)["files"]), list(bench.TARGET_FILES))
            timed = self.make_target(Path(tmp) / "timed", bench.OPTIONAL_TARGET_FILES)
            digest = bench.target_digest(timed)
            self.assertEqual(list(digest["files"]), list(bench.TARGET_FILES + bench.OPTIONAL_TARGET_FILES))
            helper = timed / bench.OPTIONAL_TARGET_FILES[0]
            helper.write_bytes(helper.read_bytes() + b"\n")
            self.assertNotEqual(bench.target_digest(timed)["conductorDigest"], digest["conductorDigest"])

    def test_staged_timing_target_loads_its_own_helper_and_reports_loaded_digests(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = self.make_target(Path(tmp) / "source", bench.OPTIONAL_TARGET_FILES)
            staged = bench.stage_target("arm", source, Path(tmp) / "staging", bench.target_digest(source))
            self.assertTrue((staged / "Scripts" / "swift_pipeline_metrics.py").is_file())
            self.assertTrue(list((staged / "Scripts" / "__pycache__").glob("swift_pipeline_metrics.*.pyc")))
            probe = (
                "import sys, json; sys.path.insert(0, %r); import conductor_benchmark as b; "
                "from pathlib import Path; m = b.load_target_module(Path(%r)); "
                "print(json.dumps([m.PIPELINE_METRICS.__file__, m.CONDUCTOR_DIGEST]))"
            ) % (str(SCRIPT_DIR), str(staged))
            result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
            helper_file, daemon_digest = json.loads(result.stdout)
            self.assertEqual(Path(helper_file).resolve(), (staged / "Scripts" / "swift_pipeline_metrics.py").resolve())
            loaded = bench.loaded_conductor_digests(Path(os.path.relpath(staged)))  # relative roots resolve too
            self.assertTrue(loaded["informational"])
            self.assertIsInstance(loaded["daemon"], str)
            self.assertEqual(loaded["daemon"], daemon_digest)
            self.assertEqual(loaded["runner"], loaded["daemon"])
            self.assertNotIn("daemonError", loaded)

    def test_timing_target_whose_helper_fails_to_load_is_a_harness_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_target(Path(tmp) / "target", bench.OPTIONAL_TARGET_FILES)
            (root / bench.OPTIONAL_TARGET_FILES[0]).write_text("raise RuntimeError('broken helper')\n", encoding="utf-8")
            probe = (
                "import sys; sys.path.insert(0, %r); import conductor_benchmark as b; "
                "from pathlib import Path\ntry:\n    b.load_target_module(Path(%r))\nexcept b.HarnessError as e:\n    print('refused', e)"
            ) % (str(SCRIPT_DIR), str(root))
            result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
            self.assertIn("refused", result.stdout)

    def test_staged_target_loads_its_own_output_helper_and_a_broken_one_fails_the_worker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = self.make_target(Path(tmp) / "source", bench.OPTIONAL_TARGET_FILES)
            staged = bench.stage_target("arm", source, Path(tmp) / "staging", bench.target_digest(source))
            self.assertTrue((staged / "Scripts" / "conductor_output.py").is_file())
            probe = (
                "import sys, json; sys.path.insert(0, %r); import conductor_benchmark as b; "
                "from pathlib import Path; m = b.load_target_module(Path(%r)); "
                "print(json.dumps(m.CONDUCTOR_OUTPUT.__file__))"
            ) % (str(SCRIPT_DIR), str(staged))
            result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
            self.assertEqual(Path(json.loads(result.stdout)).resolve(), (staged / "Scripts" / "conductor_output.py").resolve())
            # The output helper is required: a broken copy is a harness failure, never a silent fallback.
            (source / "Scripts" / "conductor_output.py").write_text("raise RuntimeError('broken output helper')\n", encoding="utf-8")
            worker = subprocess.run(
                [sys.executable, str(SCRIPT_DIR / "conductor_benchmark.py"), "__worker",
                 json.dumps({"targetRoot": str(source), "workload": "output"})],
                capture_output=True, text=True,
            )
            self.assertEqual(worker.returncode, bench.EXIT_HARNESS_FAILURE)
            self.assertIn("broken output helper", worker.stdout)

    def test_pre_timing_target_reports_no_loaded_digest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_target(Path(tmp) / "target")
            (root / "Scripts" / "conductor.py").write_text("import debug_app_process\n", encoding="utf-8")
            loaded = bench.loaded_conductor_digests(root)
            self.assertEqual((loaded["daemon"], loaded["runner"]), (None, None))
            self.assertNotIn("daemonError", loaded)
            self.assertNotIn("runnerError", loaded)

    def test_worker_loads_target_and_its_dependency_from_the_target_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_target(Path(tmp) / "target", STEP3_REQUIRED_HELPERS)
            probe = (
                "import sys, json; sys.path.insert(0, %r); import conductor_benchmark as b; "
                "from pathlib import Path; m = b.load_target_module(Path(%r)); "
                "print(json.dumps([m.__file__, sys.modules['debug_app_process'].__file__]))"
            ) % (str(SCRIPT_DIR), str(root))
            result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
            module_file, dependency_file = json.loads(result.stdout)
            self.assertEqual(Path(module_file).resolve(), (root / "Scripts" / "conductor.py").resolve())
            self.assertEqual(Path(dependency_file).resolve(), (root / "Scripts" / "debug_app_process.py").resolve())

    def test_loader_compiles_conductor_from_source_and_staging_preserves_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = self.make_target(Path(tmp) / "source", STEP3_REQUIRED_HELPERS)
            staged = bench.stage_target("arm", source, Path(tmp) / "staging", bench.target_digest(source))
            self.assertEqual(bench.target_digest(staged)["files"], bench.target_digest(source)["files"])
            self.assertTrue(list((staged / "Scripts" / "__pycache__").glob("debug_app_process.*.pyc")))
            probe = (
                "import sys, json; sys.path.insert(0, %r); import conductor_benchmark as b; "
                "from pathlib import Path; m = b.load_target_module(Path(%r)); "
                "print(json.dumps([m.__cached__, m.__name__, hasattr(m, 'DaemonState')]))"
            ) % (str(SCRIPT_DIR), str(staged))
            result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [None, bench.TARGET_MODULE_NAME, True])
            self.assertFalse(list((staged / "Scripts" / "__pycache__").glob("conductor.*.pyc")))

    def test_cli_caches_conductor_only_through_a_targets_own_step6_entry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            candidate_source = self.make_target(Path(tmp) / "candidate", bench.OPTIONAL_TARGET_FILES)
            legacy_source = self.make_target(Path(tmp) / "legacy", STEP3_REQUIRED_HELPERS)
            (legacy_source / "conductor").write_text(  # the parent (pre-Step-6) launcher
                '#!/usr/bin/env bash\nset -euo pipefail\nSCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
                'exec python3 "$SCRIPT_DIR/Scripts/conductor.py" "$@"\n',
                encoding="utf-8",
            )
            self.assertIn(bench.ENTRY_FILE, bench.target_digest(candidate_source)["files"])
            self.assertNotIn(bench.ENTRY_FILE, bench.target_digest(legacy_source)["files"])
            staging = Path(tmp) / "staging"
            staged = {
                name: bench.stage_target(name, source, staging, bench.target_digest(source))
                for name, source in (("candidate", candidate_source), ("legacy", legacy_source))
            }
            for name, root in staged.items():
                pycache = root / "Scripts" / "__pycache__"
                self.assertFalse(list(pycache.glob("conductor.*.pyc")), name)
                self.assertFalse(list(pycache.glob("conductor_entry.*.pyc")), name)
                scratch = Path(tmp) / f"scratch-{name}"
                scratch.mkdir()
                sample = bench.run_cli_sample(root, scratch)
                self.assertTrue(sample["ok"], sample)
            candidate_pyc = list((staged["candidate"] / "Scripts" / "__pycache__").glob("conductor.*.pyc"))
            self.assertEqual(len(candidate_pyc), 1)
            self.assertEqual(int.from_bytes(candidate_pyc[0].read_bytes()[4:8], "little"), 0b11)  # checked-hash
            self.assertFalse(list((staged["legacy"] / "Scripts" / "__pycache__").glob("conductor.*.pyc")))
            # The candidate's runner digest comes through its entry, and equals the worker-loaded value.
            loaded = bench.loaded_conductor_digests(staged["candidate"])
            self.assertIsInstance(loaded["runner"], str)
            self.assertEqual(loaded["runner"], loaded["daemon"])

    def test_target_digest_covers_every_target_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_target(Path(tmp) / "target")
            before = bench.target_digest(root)["conductorDigest"]
            for relative in bench.TARGET_FILES:
                with self.subTest(relative=relative):
                    path = root / relative
                    original = path.read_bytes()
                    path.write_bytes(original + b"\n")
                    self.assertNotEqual(bench.target_digest(root)["conductorDigest"], before)
                    path.write_bytes(original)
            (root / "conductor").unlink()
            with self.assertRaises(bench.HarnessError):
                bench.target_digest(root)

    def test_default_state_dir_matches_the_conductor_state_dir(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("REPOPROMPT_DEV_DAEMON_STATE_DIR", None)
            self.assertEqual(bench.default_state_dir(), conductor.compute_paths(bench.REPO_ROOT).state_dir)


class AdapterTests(unittest.TestCase):
    def test_output_variants_relay_exact_bytes_with_blocked_waiters_and_count_progress(self) -> None:
        data = bench.generate_output_fixture(7, 256 * 1024)
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture.log"
            fixture.write_bytes(data)
            spec = {"scratchDir": tmp}
            pipe = bench._run_output_variant(conductor, spec, fixture, data, "pipe", 2)
            pty = bench._run_output_variant(conductor, spec, fixture, data, "pty", 2)
        markers = sum(
            1
            for line in data.split(b"\n")
            if line.startswith((b"Test Case '", b"\x1b[32mTest Case '"))
            and line.endswith((b"' started.\x1b[0m", b" seconds)."))
        )
        self.assertEqual(pipe["bytes_read"], len(data))
        self.assertEqual(pipe["progress"]["sequence"], 0)
        self.assertEqual(pty["progress"]["sequence"], markers)
        self.assertEqual(pty["progress"]["started"], data.count(b"' started."))
        self.assertGreaterEqual(pty["bytes_read"], len(bench.onlcr(data)))
        self.assertEqual((pipe["watchdog_threads"], pty["watchdog_threads"]), (0, 1))
        # Step 3 tails are CR-segmented and ANSI-stripped, so not raw suffixes: the PTY
        # tail must equal the independent model over the received bytes, and its
        # evidence is the model over the written stream (stable under tty retries).
        self.assertEqual(
            pty["tail_evidence"],
            {
                "suffixOfStream": False,
                "step3Model": True,
                "normalizedTailSha256": bench.canonical_json_digest(bench.step3_tail_model(bench.onlcr(data))),
            },
        )
        self.assertEqual(pipe["tail_evidence"], pipe["tail_sha256"])
        self.assertEqual(pipe["tail_sha256"], bench.canonical_json_digest(bench.step3_tail_model(data)))

    def test_pty_fidelity_run_reports_the_pinned_exact_tail_through_the_real_job_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fidelity.log"
            fixture.write_bytes(bench.generate_pty_fidelity_fixture())
            spec = {"scratchDir": tmp, "fidelityFixturePath": str(fixture)}
            results = [bench.run_pty_fidelity(conductor, spec) for _ in range(5)]
        translated = len(bench.onlcr(bench.generate_pty_fidelity_fixture()))
        for digest, info in results:
            self.assertEqual(digest, EXPECTED_STEP3_PTY_TAIL)
            self.assertEqual(
                info,
                {"bytesRead": translated, "tailEntries": conductor.LOG_TAIL_LINES, "tailModel": bench.STEP3_TAIL_MODEL_VALIDATED},
            )

    def test_output_adapter_reports_exactly_its_inventory(self) -> None:
        data = bench.generate_output_fixture(5, 64 * 1024)
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture.log"
            fixture.write_bytes(data)
            fidelity = Path(tmp) / "fidelity.log"
            fidelity.write_bytes(bench.generate_pty_fidelity_fixture())
            spec = {"scratchDir": tmp, "fixturePath": str(fixture), "fidelityFixturePath": str(fidelity)}
            result = bench.adapter_output(conductor, spec)
        self.assertIsNone(bench.sample_inventory_problem(result, bench.workload_inventory("output", MANIFEST, False, False)))
        self.assertEqual(result["equivalence"][bench.PTY_FIDELITY_KEY], EXPECTED_STEP3_PTY_TAIL)

    def test_pty_variant_runs_the_real_watchdog_until_the_process_finishes(self) -> None:
        data = bench.generate_output_fixture(11, 64 * 1024)
        started: list[str] = []
        original = conductor.DaemonState._monitor_xctest_stall

        def recording_monitor(state: conductor.DaemonState, ticket: str) -> None:
            started.append(ticket)
            original(state, ticket)

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            conductor.DaemonState, "_monitor_xctest_stall", recording_monitor
        ):
            fixture = Path(tmp) / "fixture.log"
            fixture.write_bytes(data)
            bench._run_output_variant(conductor, {"scratchDir": tmp}, fixture, data, "pty", 0)
            bench._run_output_variant(conductor, {"scratchDir": tmp}, fixture, data, "pipe", 0)
        self.assertEqual(started, ["bench-output"])

    def test_summary_of_the_fixture_matches_the_parent_golden(self) -> None:
        """Step 3: the streamed, prechecked summary is the parent's v1 summary plus the
        SUMMARY_VERSION 2 fields; only deduplication saturation (OD7) may differ, and
        only as upper-bound omitted counts in the sections that report it."""
        manifest = bench.load_manifest()
        data = bench.generate_output_fixture(manifest["output"]["seed"], manifest["output"]["sizeBytes"])
        golden = json.loads(bench.SUMMARY_GOLDEN_PATH.read_text(encoding="utf-8"))["digests"]
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "summary.log"
            log.write_bytes(bench.onlcr(data))
            result = bench.adapter_summary(conductor, {"manifest": manifest, "summaryLogPath": str(log), "logsDir": None})
            for operation, state, exit_code in bench.summary_modes(manifest):
                with self.subTest(operation=operation, state=state):
                    capped = conductor.OutputSummarizer.summarize_file(operation, {}, state, exit_code, False, log)
                    with mock.patch.object(conductor, "SUMMARY_SEEN_MAX_ENTRIES", 10**9):
                        exact = conductor.OutputSummarizer.summarize_file(operation, {}, state, exit_code, False, log)
                    self.assertEqual(
                        bench.canonical_json_digest(v1_summary_projection(exact)),
                        golden[f"summary.{operation}.{state}.sha256"],
                    )
                    self.assertFalse(exact["deduplicationLimited"])
                    self.assertEqual(capped["version"], 2)
                    self.assertEqual(len(capped["sections"]), len(exact["sections"]))
                    for capped_section, exact_section in zip(capped["sections"], exact["sections"]):
                        if capped_section["deduplicationLimited"]:
                            self.assertEqual(capped_section["omittedLineCountQuality"], "upper_bound")
                            self.assertGreaterEqual(capped_section["omittedLineCount"], exact_section["omittedLineCount"])
                            capped_section = dict(capped_section, omittedLineCount=exact_section["omittedLineCount"])
                        # This fixture saturates only first-lines sections, so no displayed line changes (OD15 unused).
                        self.assertFalse(capped_section["displayedLinesMayRepeat"])
                        self.assertEqual(v1_section(capped_section), v1_section(exact_section))
                    self.assertEqual(capped["deduplicationLimited"], any(item["deduplicationLimited"] for item in capped["sections"]))
                    self.assertFalse(capped["displayedLinesMayRepeat"])
                    self.assertEqual(capped["omittedLineCountQuality"], "exact")
        self.assertEqual(result["info"]["goldenMatch"], {key: False for key in golden})
        inventory = bench.workload_inventory("summary", manifest, False, False)
        self.assertIsNone(bench.sample_inventory_problem(result, inventory))

    def test_mem_adapter_reports_exactly_its_inventory(self) -> None:
        manifest = copy.deepcopy(bench.load_manifest())
        manifest["mem"] = {"ledgerJobs": [2], "ledgerJobsFull": [2, 3], "seenLines": [1000], "seenLinesFull": [1000, 2000]}
        with tempfile.TemporaryDirectory() as tmp:
            ledger_root = Path(tmp) / "ledger"
            (ledger_root / "Scripts" / "Fixtures").mkdir(parents=True)
            shutil.copyfile(
                bench.REPO_ROOT / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv",
                ledger_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv",
            )
            for full in (False, True):
                with self.subTest(full=full):
                    spec = {"manifest": manifest, "full": full, "ledgerRoot": str(ledger_root), "scratchDir": tmp}
                    result = bench.adapter_mem(conductor, spec)
                    inventory = bench.workload_inventory("mem", manifest, full, False)
                    self.assertIsNone(bench.sample_inventory_problem(result, inventory))
                    self.assertGreater(result["metrics"]["mem.ledger_retained_n2_mib"], 0.0)
                    self.assertGreater(result["metrics"]["mem.ledger_load_ms"], 0.0)

    def test_cli_sample_measures_the_daemon_free_launcher_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = bench.run_cli_sample(bench.REPO_ROOT, Path(tmp))
        self.assertTrue(result["ok"], result)
        self.assertEqual(set(result["metrics"]), {"cli.help_ms", "cli.status_ms"})

    def test_cli_sample_reports_timeouts_and_spawn_failures_as_failed_samples(self) -> None:
        failures = (subprocess.TimeoutExpired(["conductor"], 60), FileNotFoundError("no launcher"))
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as tmp:
                with mock.patch.object(bench.subprocess, "run", side_effect=failure):
                    result = bench.run_cli_sample(bench.REPO_ROOT, Path(tmp))
                self.assertFalse(result["ok"])
                self.assertIn(type(failure).__name__, result["error"])

    @unittest.skipUnless(shutil.which("swift") and shutil.which("git"), "artifact path needs swift --version and git")
    def test_artifact_worker_counts_real_validation_sites_and_bytes(self) -> None:
        sizes = (300_000, 500_000)
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            repo = Path(tmp) / "repo"
            bench.build_fixture_repo(repo, bench.ARTIFACT_CANONICAL_SWIFT, sizes, None)
            spec = {
                "workload": "artifact",
                "targetRoot": str(bench.REPO_ROOT),
                "scratchDir": tmp,
                "artifactRepo": str(repo),
                "artifactFilter": "BenchProbeTests",
                "artifactFixtureBytes": list(sizes),
            }
            result = bench.run_worker(spec, timeout=300)
        self.assertTrue(result["ok"], result.get("error"))
        metrics = result["metrics"]
        calls = metrics["artifact.fingerprint_calls"]
        self.assertGreaterEqual(calls, 1)
        hashed_files = sum(sizes) + len("<plist/>\n")
        # Every fingerprint hashes the executable and closure content plus a small manifest digest.
        self.assertGreaterEqual(metrics["artifact.bytes_hashed"], calls * hashed_files)
        self.assertLess(metrics["artifact.bytes_hashed"], calls * (hashed_files + 4096))
        self.assertGreaterEqual(metrics["artifact.run_wall_ms"], metrics["artifact.integrity_ms"] * 0.5)

    @unittest.skipUnless(shutil.which("swift") and shutil.which("git"), "rss jobs mint tickets with swift --version")
    def test_rss_sample_retains_ledger_loaded_jobs_and_reads_footprints(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            ledger = bench.REPO_ROOT / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
            ledger_root = Path(tmp) / "ledger"
            (ledger_root / "Scripts" / "Fixtures").mkdir(parents=True)
            shutil.copyfile(ledger, ledger_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv")
            suite, method = bench.first_ledger_case(ledger_root)
            repo = Path(tmp) / "repo"
            bench.build_fixture_repo(repo, bench.rss_canonical_swift(suite, method, 20), (1024, 1024), ledger)
            spec = {
                "workload": "rss",
                "targetRoot": str(bench.REPO_ROOT),
                "scratchDir": tmp,
                "rssRepo": str(repo),
                "rssJobs": 2,
                "rssFilter": suite.rsplit(".", 1)[-1],
            }
            result = bench.run_rss_sample(spec, timeout=300)
        self.assertTrue(result["ok"], result.get("error"))
        self.assertEqual(result["info"], {"retainedJobs": 2, "ledgerLoadedJobs": 2})
        self.assertGreater(result["metrics"]["rss.footprint_idle_mib"], 1.0)


DIGESTS = {"A": "digest-a", "B": "digest-b"}
MANIFEST = bench.load_manifest()
SUMMARY_V2_FIELDS = ("deduplicationLimited", "omittedLineCountQuality", "displayedLinesMayRepeat")


def v1_section(section: dict) -> dict:
    return {key: value for key, value in section.items() if key not in SUMMARY_V2_FIELDS}


def v1_summary_projection(summary: dict) -> dict:
    """A SUMMARY_VERSION 2 summary without its v2-only fields, as version 1."""
    projected = {key: value for key, value in summary.items() if key not in SUMMARY_V2_FIELDS}
    projected["version"] = 1
    projected["sections"] = [v1_section(section) for section in summary["sections"]]
    return projected
MANIFEST_SHA256 = bench.sha256_file(bench.MANIFEST_PATH)
SUMMARY_GOLDEN = json.loads(bench.SUMMARY_GOLDEN_PATH.read_text(encoding="utf-8"))["digests"]
EXPECTED_PTY_TAIL = MANIFEST["output"]["ptyFidelity"]["expectedTailSha256"]
# The Step 3 (OD7) visible tail of the same exact PTY delivery; equals the harness's
# independent ``step3_tail_model`` (asserted in StepThreeTailModelTests).
EXPECTED_STEP3_PTY_TAIL = "23c6f6af26f02d3252361be1f5f4659c995a175f620ca6aba0fd9a954f50184f"
NCPU = 8


def series(base: float, n: int = 30, spread: float = 0.5) -> list[float]:
    return [base + spread * ((index * 7) % 11 - 5) / 5 for index in range(n)]


def default_series(metric: str, n: int) -> list[float]:
    cls = bench.metric_class(metric)
    if cls == "count":
        return [3.0] * n
    if cls == "memory_mib":
        return series(10.0, n, 0.05)
    if cls == "artifact_ms":
        return series(2800.0, n, 10.0)
    return series(50.0, n)


def default_equivalence(key: str) -> str:
    if key in SUMMARY_GOLDEN:
        return SUMMARY_GOLDEN[key]
    if key == bench.PTY_FIDELITY_KEY:
        return EXPECTED_PTY_TAIL
    return f"evidence:{key}"


def synthetic_capture(
    path: str,
    arms: dict[str, dict[str, list[float]]],
    workload: str = "output",
    equivalence: dict[str, str] | None = None,
    *,
    full: bool = False,
    retained_logs: bool = False,
    foreign=lambda index: 0.0,
    **overrides: object,
) -> dict:
    """A complete, acceptance-eligible capture under the real versioned contract.

    The manifest is the pinned file (with its real digest), adapters are current,
    and the inventory is the authoritative ``workload_inventory``. ``arms`` sets
    chosen metrics per arm; every other inventory metric gets the same
    deterministic series in each arm, and every equivalence key its real value
    (summary golden, pinned PTY tail) unless ``equivalence`` overrides it. Each
    sample takes one second with host-CPU counters showing ``foreign(index)``
    foreign cores.
    """
    inventory = bench.workload_inventory(workload, MANIFEST, full, retained_logs)
    unknown = {metric for values in arms.values() for metric in values} - set(inventory["metrics"])
    if unknown:
        raise AssertionError(f"metrics outside the {workload} contract: {sorted(unknown)}")
    blocks = len(next(iter(next(iter(arms.values())).values())))
    evidence = {key: default_equivalence(key) for key in inventory["equivalence"]}
    evidence.update(equivalence or {})
    capture = {
        "schemaVersion": bench.CAPTURE_SCHEMA_VERSION,
        "harnessVersion": bench.HARNESS_VERSION,
        "captureId": Path(path).stem,
        "state": "complete",
        "complete": True,
        "fixtureVersion": 1,
        "fixtureManifestSha256": MANIFEST_SHA256,
        "manifest": copy.deepcopy(MANIFEST),
        "summaryGolden": dict(SUMMARY_GOLDEN),
        "host": {"machine": "arm64", "cpu": "x", "ncpu": NCPU},
        "python": {"version": "3"},
        "full": full,
        "adapters": dict(bench.ADAPTER_VERSIONS),
        "workloads": [workload],
        "samplesConfig": {"fast": blocks, "memory": blocks, "artifact": blocks},
        "overrides": {"samples": None, "classSamples": {}, "artifactScale": None, "rssJobs": None},
        "primers": {workload: 0},
        "inventory": {workload: copy.deepcopy(inventory)},
        "arms": [{"name": name, "conductorDigest": DIGESTS.get(name, name)} for name in arms],
        "errors": [],
        "samples": [],
        "_path": path,
    }
    if retained_logs:
        capture["retainedLogsCorpus"] = {"digest": "corpus", "files": [{"name": "one.log", "bytes": 1, "sha256": "x"}]}
    if workload == "artifact":
        capture["artifactFixtureBytes"] = [MANIFEST["artifact"]["executableBytes"], MANIFEST["artifact"]["dsymBytes"]]
    if workload == "rss":
        capture["rssJobs"] = MANIFEST["rss"]["retainedJobs"]
    counters = {"at": 1_000_000.0, "busyTicks": 0, "totalTicks": 0, "ownCpuSeconds": 0.0}
    for block in range(blocks):
        for name, chosen in arms.items():
            start = dict(counters)
            foreign_now = float(foreign(len(capture["samples"])))
            counters = {
                "at": start["at"] + 1.0,
                "busyTicks": start["busyTicks"] + int(round(100 * (1.0 + foreign_now))),
                "totalTicks": start["totalTicks"] + 100 * NCPU,
                "ownCpuSeconds": start["ownCpuSeconds"] + 1.0,
            }
            capture["samples"].append(
                {
                    "workload": workload,
                    "arm": name,
                    "block": block,
                    "primer": False,
                    "ok": True,
                    "machine": {"loadavg": [1.0, 1.0, 1.0], "slotsHeld": []},
                    "hostCpu": {"start": start, "end": dict(counters)},
                    "metrics": {
                        metric: (chosen[metric] if metric in chosen else default_series(metric, blocks))[block]
                        for metric in inventory["metrics"]
                    },
                    "equivalence": dict(evidence),
                }
            )
    capture.update(overrides)
    return capture


def write_capture(directory: Path, capture: dict) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    data = {key: value for key, value in capture.items() if key != "_path"}
    (directory / "capture.json").write_text(json.dumps(data), encoding="utf-8")
    return directory


class ComparisonTests(unittest.TestCase):
    GATES = {
        "classes": {
            "fast_python_ms": {"relativeFloor": 0.05, "absoluteFloor": 2.0},
            "memory_mib": {"relativeFloor": 0.05, "absoluteFloor": 0.25},
            "artifact_ms": {"relativeFloor": 0.05, "absoluteFloor": 100.0},
            "count": {"relativeFloor": 0.0, "absoluteFloor": 0.0},
        },
        "minSamples": {"fast": 30, "memory": 10, "artifact": 10},
        "contamination": {"maxForeignCores": 4.0, "windowSeconds": 5.0},
        "profiles": {
            "no-regression": {"workloads": ["output"], "requireGolden": ["baseline"]},
            "artifact": {"workloads": ["artifact"]},
            "exact-tail-changes": {"workloads": ["output"], "allowChangedEquivalence": ["output.pty.fidelity.exact_tail_sha256"]},
            "memory": {"workloads": ["mem"]},
            "ledger200": {"workloads": ["mem"], "gates": [{"metric": "mem.ledger_retained_n200_mib", "maxValue": 4.0}]},
            "faster": {"workloads": ["output"], "gates": [{"metric": "output.pipe.w0.cpu_ms", "maxRatio": 0.5}]},
            "changed": {"workloads": ["output"], "allowChangedEquivalence": ["output.*.tail_sha256"]},
            "summary": {"workloads": ["summary"], "requireGolden": ["baseline"]},
        },
    }

    def compare(self, baseline: dict, candidate: dict, profile: str = "no-regression", confirm=None) -> dict:
        b_arm = baseline["arms"][0]["name"]
        c_arm = candidate["arms"][-1]["name"]
        return bench.evaluate_comparison(baseline, b_arm, candidate, c_arm, self.GATES, profile, confirm)

    def paired(self, a: list[float], b: list[float], path: str = "/c.json", **overrides: object) -> dict:
        return synthetic_capture(path, {"A": {"output.pipe.w0.cpu_ms": a}, "B": {"output.pipe.w0.cpu_ms": b}}, **overrides)

    def test_equivalent_paired_arms_qualify(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        report = self.compare(capture, capture)
        self.assertTrue(report["paired"])
        self.assertEqual((report["outcome"], report["exitCode"]), ("qualified", 0), report)

    def test_suspected_regression_needs_an_independent_valid_confirming_batch(self) -> None:
        capture = self.paired(series(100.0), series(120.0))
        report = self.compare(capture, capture)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("suspected regression" in item for item in report["inconclusive"]))
        independent = self.paired(series(100.0), series(121.0), path="/confirm.json")
        confirmed = self.compare(capture, capture, confirm=(independent, "A", independent, "B"))
        self.assertEqual(confirmed["exitCode"], bench.EXIT_REGRESSION, confirmed)
        self.assertTrue(confirmed["confirmation"]["accepted"])

    def test_invalid_confirming_batches_are_rejected_before_bootstrapping(self) -> None:
        capture = self.paired(series(100.0), series(120.0))
        good = self.paired(series(100.0), series(121.0), path="/confirm.json")
        other_target = copy.deepcopy(good)
        other_target["arms"][1]["conductorDigest"] = "digest-other"
        failed = copy.deepcopy(good)
        failed["errors"] = [{"error": "worker failed"}]
        partial = copy.deepcopy(good)
        partial["state"], partial["complete"] = "interrupted", False
        short = self.paired(series(100.0, n=10), series(121.0, n=10), path="/confirm.json")
        excluded = copy.deepcopy(good)
        excluded["_labels"] = {"excludeFromAcceptance": True, "reason": "profiling"}
        other_host = copy.deepcopy(good)
        other_host["host"] = {"machine": "x86_64", "ncpu": NCPU}
        smoke = copy.deepcopy(good)
        smoke["overrides"]["samples"] = 30
        cases = {
            "self-confirmation": ((capture, "A", capture, "B"), "not an independent capture"),
            "different target": ((other_target, "A", other_target, "B"), "different target"),
            "capture errors": ((failed, "A", failed, "B"), "recorded errors"),
            "partial capture": ((partial, "A", partial, "B"), "not complete"),
            "too few samples": ((short, "A", short, "B"), "below the required"),
            "excluded label": ((excluded, "A", excluded, "B"), "non-acceptance"),
            "incompatible host": ((other_host, "A", other_host, "B"), "incompatible host"),
            "smoke override": ((smoke, "A", smoke, "B"), "smoke override"),
            "same arm": ((good, "B", good, "B"), "same arm"),
        }
        for name, (confirm, reason) in cases.items():
            with self.subTest(name):
                report = self.compare(capture, capture, confirm=confirm)
                self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE, report)
                self.assertFalse(report["confirmation"]["accepted"])
                self.assertTrue(any(reason in item for item in report["confirmation"]["problems"]), report["confirmation"])

    def test_wide_noise_without_a_clear_slowdown_does_not_pass(self) -> None:
        noisy = [100.0 + (40.0 if index % 2 else -40.0) for index in range(30)]
        report = self.compare(self.paired(series(100.0), noisy), self.paired(series(100.0), noisy))
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)

    def test_insufficient_samples_missing_workload_and_incompatible_host_are_inconclusive(self) -> None:
        short = self.paired(series(100.0, n=10), series(100.0, n=10))
        self.assertEqual(self.compare(short, short)["exitCode"], bench.EXIT_INCONCLUSIVE)
        base = synthetic_capture("/b.json", {"A": {"output.pipe.w0.cpu_ms": series(100.0)}})
        cand = synthetic_capture("/c.json", {"B": {"output.pipe.w0.cpu_ms": series(100.0)}}, host={"machine": "x86_64", "ncpu": NCPU})
        self.assertFalse(self.compare(base, cand)["paired"])
        self.assertEqual(self.compare(base, cand)["exitCode"], bench.EXIT_INCONCLUSIVE)
        cand = synthetic_capture("/c.json", {"B": {"output.pipe.w0.cpu_ms": series(100.0)}}, workloads=["summary"])
        self.assertEqual(self.compare(base, cand)["exitCode"], bench.EXIT_INCONCLUSIVE)
        cand = synthetic_capture(
            "/c.json", {"B": {"output.pipe.w0.cpu_ms": series(100.0)}}, contentionStart={"slotsHeld": ["global-heavy-0.lock"]}
        )
        self.assertEqual(self.compare(base, cand)["exitCode"], bench.EXIT_INCONCLUSIVE)

    def test_samples_taken_while_machine_slots_were_held_are_inconclusive(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        capture["samples"][7]["machine"] = {"loadavg": [9.0, 9.0, 9.0], "slotsHeld": ["global-xctest-0.lock"]}
        report = self.compare(capture, capture)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("machine slots were held" in item for item in report["inconclusive"]))

    def test_minimum_samples_follow_the_workload_sampling_class(self) -> None:
        def capture(workload: str, metric: str) -> dict:
            return synthetic_capture("/c.json", {"A": {metric: series(44.0, n=10)}, "B": {metric: series(44.0, n=10)}}, workload=workload)

        memory = capture("mem", "mem.ledger_load_ms")
        self.assertEqual(self.compare(memory, memory, profile="memory")["exitCode"], bench.EXIT_QUALIFIED)
        fast = capture("output", "output.pipe.w0.cpu_ms")
        report = self.compare(fast, fast)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertIn("output.pipe.w0.cpu_ms: 10 samples < 30", report["inconclusive"])

    def test_a_profile_gate_without_a_measured_metric_never_passes(self) -> None:
        # A default (non-full) memory capture has no n200 metric, so the Step 4 gate cannot be judged.
        metric = "mem.ledger_retained_n56_mib"
        default = synthetic_capture("/c.json", {"A": {metric: series(86.0, n=10)}, "B": {metric: series(2.0, n=10)}}, workload="mem")
        report = self.compare(default, default, profile="ledger200")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE, report)
        self.assertIn("gate mem.ledger_retained_n200_mib: no measured metric with enough samples matches it", report["inconclusive"])

    def test_empty_partial_or_inventory_violating_captures_are_harness_failures(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        empty = copy.deepcopy(capture)
        empty["samples"] = []
        missing_block = copy.deepcopy(capture)
        del missing_block["samples"][5]
        wrong_inventory = copy.deepcopy(capture)
        wrong_inventory["samples"][2]["metrics"]["output.extra_ms"] = 1.0
        interrupted = copy.deepcopy(capture)
        interrupted["state"], interrupted["complete"] = "interrupted", False
        failed_sample = copy.deepcopy(capture)
        failed_sample["samples"][4] = dict(failed_sample["samples"][4], ok=False, error="worker died")
        for name, broken in {
            "empty": empty,
            "missing block": missing_block,
            "wrong inventory": wrong_inventory,
            "interrupted": interrupted,
            "failed sample": failed_sample,
        }.items():
            with self.subTest(name):
                report = self.compare(broken, broken)
                self.assertEqual(report["exitCode"], bench.EXIT_HARNESS_FAILURE, report)

    def test_inventories_are_rebuilt_from_the_versioned_contract_not_trusted_from_the_capture(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        self.assertEqual(self.compare(capture, capture)["exitCode"], bench.EXIT_QUALIFIED)
        # OracleA-001: keys removed from BOTH the recorded inventory and every sample.
        emptied = copy.deepcopy(capture)
        emptied["inventory"]["output"] = {"metrics": [], "equivalence": []}
        for sample in emptied["samples"]:
            sample["metrics"], sample["equivalence"] = {}, {}
        dropped = copy.deepcopy(capture)
        removed = ("output.pty.w4.wall_ms", bench.PTY_FIDELITY_KEY)
        for key in removed:
            for section in ("metrics", "equivalence"):
                if key in dropped["inventory"]["output"][section]:
                    dropped["inventory"]["output"][section].remove(key)
            for sample in dropped["samples"]:
                sample["metrics"].pop(key, None)
                sample["equivalence"].pop(key, None)
        old_adapter = copy.deepcopy(capture)
        old_adapter["adapters"]["output"] = "read_process_output+pty_xctest_watchdog@2"
        unpinned_digest = copy.deepcopy(capture)
        unpinned_digest["fixtureManifestSha256"] = "m"
        edited_manifest = copy.deepcopy(capture)
        edited_manifest["manifest"]["samples"]["fast"] = 5
        cases = {
            "emptied inventory and samples": emptied,
            "keys dropped from inventory and samples": dropped,
            "older adapter contract": old_adapter,
            "unpinned manifest digest": unpinned_digest,
            "edited manifest content": edited_manifest,
        }
        for name, broken in cases.items():
            with self.subTest(name):
                report = self.compare(broken, broken)
                self.assertEqual(report["exitCode"], bench.EXIT_HARNESS_FAILURE, report)
        self.assertTrue(
            any("does not match the versioned adapter contract" in item for item in self.compare(emptied, emptied)["harnessFailures"])
        )

    def test_recorded_settings_select_the_contract_and_cannot_be_misreported(self) -> None:
        metric = "mem.ledger_load_ms"
        default = synthetic_capture("/m.json", {"A": {metric: series(44.0, n=10)}, "B": {metric: series(44.0, n=10)}}, workload="mem")
        full = synthetic_capture(
            "/m.json", {"A": {metric: series(44.0, n=10)}, "B": {metric: series(44.0, n=10)}}, workload="mem", full=True
        )
        self.assertIn("mem.ledger_retained_n200_mib", full["inventory"]["mem"]["metrics"])
        self.assertEqual(self.compare(full, full, profile="memory")["exitCode"], bench.EXIT_QUALIFIED)
        claims_full = copy.deepcopy(default)
        claims_full["full"] = True
        self.assertEqual(self.compare(claims_full, claims_full, profile="memory")["exitCode"], bench.EXIT_HARNESS_FAILURE)
        summary_metric = "summary.test.completed.cpu_ms"
        retained = synthetic_capture(
            "/s.json", {"A": {summary_metric: series(876.0)}, "B": {summary_metric: series(876.0)}}, workload="summary", retained_logs=True
        )
        self.assertEqual(self.compare(retained, retained, profile="summary")["exitCode"], bench.EXIT_QUALIFIED)
        corpus_dropped = copy.deepcopy(retained)
        del corpus_dropped["retainedLogsCorpus"]
        self.assertEqual(self.compare(corpus_dropped, corpus_dropped, profile="summary")["exitCode"], bench.EXIT_HARNESS_FAILURE)

    def test_authoritative_inventory_matches_what_run_records_for_every_workload(self) -> None:
        for workload in bench.FULL_WORKLOADS:
            for full in (False, True):
                with self.subTest(workload=workload, full=full):
                    capture = {
                        "adapters": dict(bench.ADAPTER_VERSIONS),
                        "fixtureManifestSha256": MANIFEST_SHA256,
                        "manifest": copy.deepcopy(MANIFEST),
                        "full": full,
                        "inventory": {workload: bench.workload_inventory(workload, MANIFEST, full, False)},
                    }
                    inventory, problem = bench.authoritative_inventory(capture, workload)
                    self.assertIsNone(problem)
                    self.assertTrue(inventory["metrics"])
        self.assertIn(bench.PTY_FIDELITY_KEY, bench.workload_inventory("output", MANIFEST, False, False)["equivalence"])

    def test_non_finite_or_malformed_measurements_are_rejected_when_loading(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        with tempfile.TemporaryDirectory() as tmp:
            nan = copy.deepcopy(capture)
            nan["samples"][0]["metrics"]["output.pipe.w0.cpu_ms"] = float("nan")
            write_capture(Path(tmp) / "nan", nan)
            with self.assertRaises(bench.HarnessError):
                bench.load_capture(str(Path(tmp) / "nan"))
            text = copy.deepcopy(capture)
            text["samples"][0]["metrics"]["output.pipe.w0.cpu_ms"] = "100"
            write_capture(Path(tmp) / "text", text)
            with self.assertRaises(bench.HarnessError):
                bench.load_capture(str(Path(tmp) / "text"))
            legacy = copy.deepcopy(capture)
            legacy["schemaVersion"] = 1
            write_capture(Path(tmp) / "legacy", legacy)
            with self.assertRaises(bench.HarnessError):
                bench.load_capture(str(Path(tmp) / "legacy"))

    def test_smoke_overrides_and_unpinned_fixtures_are_never_acceptance_evidence(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        for key, value in (("samples", 30), ("artifactScale", 0.001), ("rssJobs", 2)):
            with self.subTest(key):
                smoke = copy.deepcopy(capture)
                smoke["overrides"][key] = value
                report = self.compare(smoke, smoke)
                self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
                self.assertTrue(any("smoke override" in item for item in report["inconclusive"]))
        artifact = synthetic_capture(
            "/c.json",
            {"A": {"artifact.run_wall_ms": series(2800.0, n=10)}, "B": {"artifact.run_wall_ms": series(2800.0, n=10)}},
            workload="artifact",
            artifactFixtureBytes=[1000, 2000],
        )
        gates = self.GATES
        report = bench.evaluate_comparison(artifact, "A", artifact, "B", gates, "artifact")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("!= pinned" in item for item in report["inconclusive"]), report["inconclusive"])
        artifact["artifactFixtureBytes"] = [490733568, 660602880]
        self.assertEqual(bench.evaluate_comparison(artifact, "A", artifact, "B", gates, "artifact")["exitCode"], 0)

    def test_required_golden_and_frozen_corpus_identity(self) -> None:
        metric = "summary.test.completed.cpu_ms"
        good = synthetic_capture("/s.json", {"A": {metric: series(876.0)}, "B": {metric: series(876.0)}}, workload="summary")
        self.assertEqual(self.compare(good, good, profile="summary")["exitCode"], bench.EXIT_QUALIFIED)
        drifted = copy.deepcopy(good)
        for sample in drifted["samples"]:
            sample["equivalence"]["summary.test.completed.sha256"] = "drift"
        report = self.compare(drifted, drifted, profile="summary")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertIn("baseline summary.test.completed.sha256: summary differs from the v1 golden", report["inconclusive"])
        retained = synthetic_capture(
            "/s.json", {"A": {metric: series(876.0)}, "B": {metric: series(876.0)}}, workload="summary", retained_logs=True
        )
        base = copy.deepcopy(retained)
        base["retainedLogsCorpus"]["digest"] = "corpus-1"
        cand = copy.deepcopy(retained)
        cand["_path"], cand["captureId"] = "/s2.json", "s2"
        cand["retainedLogsCorpus"]["digest"] = "corpus-2"
        report = self.compare(base, cand, profile="summary")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("retained-log corpus" in item for item in report["inconclusive"]))

    def test_evidence_labels_and_harness_changes_never_pass(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        for index, sample in enumerate(capture["samples"]):
            sample["startedAtUnix"] = 1_000_000.0 + index * 10
            sample["finishedAtUnix"] = sample["startedAtUnix"] + 5
        self.assertEqual(self.compare(capture, capture)["exitCode"], bench.EXIT_QUALIFIED)
        excluded = copy.deepcopy(capture)
        excluded["_labels"] = {"excludeFromAcceptance": True, "reason": "overlapping profiling"}
        self.assertEqual(self.compare(excluded, excluded)["exitCode"], bench.EXIT_INCONCLUSIVE)
        windowed = copy.deepcopy(capture)
        overlap = {"start": "1970-01-12T13:46:40Z", "end": "1970-01-12T13:46:45Z", "reason": "foreign CPU work"}
        windowed["_labels"] = {"contaminationWindows": [overlap]}
        report = self.compare(windowed, windowed)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("contamination window" in item for item in report["inconclusive"]))
        clear = copy.deepcopy(capture)
        clear["_labels"] = {"contaminationWindows": [{"start": "1970-01-01T00:00:00Z", "end": "1970-01-01T00:01:00Z"}]}
        self.assertEqual(self.compare(clear, clear)["exitCode"], bench.EXIT_QUALIFIED)
        base = synthetic_capture("/b.json", {"A": {"output.pipe.w0.cpu_ms": series(100.0)}}, harnessDigest={"digest": "a"})
        cand = synthetic_capture("/c.json", {"B": {"output.pipe.w0.cpu_ms": series(100.0)}}, harnessDigest={"digest": "b"})
        self.assertEqual(self.compare(base, cand)["exitCode"], bench.EXIT_INCONCLUSIVE)

    def test_label_command_writes_a_sidecar_that_compare_loads(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            write_capture(Path(tmp), self.paired(series(100.0), series(100.0)))
            with mock.patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(bench.main(["label", tmp, "--exclude", "--reason", "profiling overlap"]), 0)
            loaded, _arm = bench.load_capture(f"{tmp}#A")
            self.assertEqual(loaded["_labels"]["reason"], "profiling overlap")
            self.assertTrue(loaded["_labels"]["excludeFromAcceptance"])

    def test_capture_errors_and_unstable_equivalence_are_harness_failures(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        failed = copy.deepcopy(capture)
        failed["errors"] = [{"error": "worker failed"}]
        self.assertEqual(self.compare(failed, failed)["exitCode"], bench.EXIT_HARNESS_FAILURE)
        unstable = copy.deepcopy(capture)
        unstable["samples"][3]["equivalence"]["output.pipe.w0.tail_sha256"] = "other"
        self.assertEqual(self.compare(unstable, unstable)["exitCode"], bench.EXIT_HARNESS_FAILURE)

    def test_changed_behavior_evidence_is_a_regression_unless_the_profile_allows_it(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        for sample in capture["samples"]:
            if sample["arm"] == "B":
                sample["equivalence"]["output.pipe.w0.tail_sha256"] = "new-shape"
        self.assertEqual(self.compare(capture, capture)["exitCode"], bench.EXIT_REGRESSION)
        self.assertEqual(self.compare(capture, capture, profile="changed")["exitCode"], bench.EXIT_QUALIFIED)

    def test_exact_pty_tail_is_distinct_evidence_with_its_own_explicit_allowance(self) -> None:
        capture = self.paired(series(100.0), series(100.0))
        for sample in capture["samples"]:
            if sample["arm"] == "B":
                sample["equivalence"][bench.PTY_FIDELITY_KEY] = "dropped-or-merged-entries"
        report = self.compare(capture, capture)
        self.assertEqual(report["exitCode"], bench.EXIT_REGRESSION, report)
        self.assertIn(f"{bench.PTY_FIDELITY_KEY}: behavior evidence changed", report["regressions"])
        # The suffix-evidence allowance (output.*.tail_sha256) never covers the exact tail.
        self.assertEqual(self.compare(capture, capture, profile="changed")["exitCode"], bench.EXIT_REGRESSION)
        self.assertEqual(self.compare(capture, capture, profile="exact-tail-changes")["exitCode"], bench.EXIT_QUALIFIED)
        gates = bench.load_gates()
        self.assertIn(bench.PTY_FIDELITY_KEY, gates["profiles"]["step3-output-summary"]["allowChangedEquivalence"])
        for name in ("no-regression", "no-regression-full", "calibration-output"):
            allowed = gates["profiles"][name].get("allowChangedEquivalence") or []
            self.assertFalse(any(bench.fnmatch.fnmatch(bench.PTY_FIDELITY_KEY, pattern) for pattern in allowed), name)

    def test_required_golden_baseline_must_show_the_pinned_exact_pty_tail(self) -> None:
        capture = self.paired(series(100.0), series(100.0), equivalence={bench.PTY_FIDELITY_KEY: "other-tail"})
        report = self.compare(capture, capture)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE, report)
        self.assertIn(
            f"baseline {bench.PTY_FIDELITY_KEY}: PTY visible tail differs from the pinned expected tail", report["inconclusive"]
        )

    def test_predeclared_foreign_cpu_gate_makes_contaminated_windows_inconclusive(self) -> None:
        clean = self.paired(series(100.0), series(100.0))
        report = self.compare(clean, clean)
        self.assertEqual(report["exitCode"], bench.EXIT_QUALIFIED, report)
        self.assertEqual(report["foreignCpu"]["baseline"]["output"]["foreignCoresMax"], 0.0)
        # Samples 20..29 (blocks 10..14, both arms) carry 6 foreign cores: their 5 s windows exceed 4 cores.
        burst = self.paired(series(100.0), series(100.0), foreign=lambda index: 6.0 if 20 <= index < 30 else 0.0)
        report = self.compare(burst, burst)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE, report)
        self.assertTrue(any("foreign CPU above 4 cores" in item for item in report["inconclusive"]), report["inconclusive"])
        # One 8-core second averages to 1.6 cores over its 5 s window: below the predeclared limit.
        blip = self.paired(series(100.0), series(100.0), foreign=lambda index: 8.0 if index == 7 else 0.0)
        self.assertEqual(self.compare(blip, blip)["exitCode"], bench.EXIT_QUALIFIED)
        unmeasured = copy.deepcopy(clean)
        del unmeasured["samples"][3]["hostCpu"]
        report = self.compare(unmeasured, unmeasured)
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("lack host CPU evidence" in item for item in report["inconclusive"]))
        no_policy = copy.deepcopy(self.GATES)
        del no_policy["contamination"]
        report = bench.evaluate_comparison(clean, "A", clean, "B", no_policy, "no-regression")
        self.assertEqual(report["exitCode"], bench.EXIT_HARNESS_FAILURE)

    def test_foreign_cores_subtracts_the_capture_own_cpu(self) -> None:
        start = {"at": 0.0, "busyTicks": 0, "totalTicks": 0, "ownCpuSeconds": 0.0}
        end = {"at": 2.0, "busyTicks": 600, "totalTicks": 1600, "ownCpuSeconds": 2.0}
        self.assertAlmostEqual(bench.foreign_cores(start, end, 8), 8 * 600 / 1600 - 1.0)
        self.assertIsNone(bench.foreign_cores(start, dict(end, totalTicks=0), 8))

    def test_improvement_gate_requires_ratio_and_a_ci_below_zero(self) -> None:
        met = self.paired(series(100.0), series(40.0))
        self.assertEqual(self.compare(met, met, profile="faster")["exitCode"], bench.EXIT_QUALIFIED)
        unmet = self.paired(series(100.0), series(70.0))
        report = self.compare(unmet, unmet, profile="faster")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(report["gateFailures"])

    def test_deterministic_count_increase_is_a_regression(self) -> None:
        metric = "artifact.fingerprint_calls"
        capture = synthetic_capture("/c.json", {"A": {metric: [3.0] * 10}, "B": {metric: [4.0] * 10}}, workload="artifact")
        report = self.compare(capture, capture, profile="artifact")
        self.assertEqual(report["exitCode"], bench.EXIT_REGRESSION, report)
        self.assertIn("artifact.fingerprint_calls: count rose 3 -> 4", report["regressions"])

    def test_compare_command_returns_exact_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            primary = write_capture(Path(tmp) / "primary", self.paired(series(100.0), series(120.0), path="/primary.json"))
            confirm = write_capture(Path(tmp) / "confirm", self.paired(series(100.0), series(121.0), path="/confirm.json"))
            gates = Path(tmp) / "gates.json"
            gates.write_text(json.dumps(self.GATES), encoding="utf-8")
            with mock.patch("sys.stdout", new_callable=io.StringIO), mock.patch("sys.stderr", new_callable=io.StringIO):
                common = ["compare", "--gates", str(gates), "--baseline", f"{primary}#A", "--candidate", f"{primary}#B"]
                self.assertEqual(bench.main(common), bench.EXIT_INCONCLUSIVE)
                independent = ["--confirm-baseline", f"{confirm}#A", "--confirm-candidate", f"{confirm}#B"]
                self.assertEqual(bench.main(common + independent), bench.EXIT_REGRESSION)
                itself = ["--confirm-baseline", f"{primary}#A", "--confirm-candidate", f"{primary}#B"]
                self.assertEqual(bench.main(common + itself), bench.EXIT_INCONCLUSIVE)
                self.assertEqual(bench.main(["compare", "--baseline", str(primary), "--candidate", str(primary)]), 3)
                same_arm = ["compare", "--gates", str(gates), "--baseline", f"{primary}#A", "--candidate", f"{primary}#A"]
                self.assertEqual(bench.main(same_arm), bench.EXIT_HARNESS_FAILURE)
                missing = ["compare", "--baseline", str(Path(tmp) / "none"), "--candidate", f"{primary}#B"]
                self.assertEqual(bench.main(missing), bench.EXIT_HARNESS_FAILURE)

    def test_abba_order_and_bootstrap_are_deterministic(self) -> None:
        arms = [("A", Path("/a")), ("B", Path("/b"))]
        self.assertEqual([name for name, _ in bench.arm_order(arms, 0)], ["A", "B"])
        self.assertEqual([name for name, _ in bench.arm_order(arms, 1)], ["B", "A"])
        first = bench.bootstrap_ci(series(10.0), series(12.0), paired=True)
        self.assertEqual(first, bench.bootstrap_ci(series(10.0), series(12.0), paired=True))
        self.assertLessEqual(first[1], first[0])
        self.assertLessEqual(first[0], first[2])


class RunCommandTests(unittest.TestCase):
    """End-to-end ``run`` behaviour on the cheap cli workload with two staged target copies."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.targets = []
        for name in ("a", "b"):
            target = self.root / f"target {name}"
            (target / "Scripts").mkdir(parents=True)
            for relative in bench.present_target_files(bench.REPO_ROOT):
                shutil.copy2(bench.REPO_ROOT / relative, target / relative)
            self.targets.append((name, target))
        self.output = self.root / "captures"

    def run_capture(self, capture_id: str, *extra: str) -> tuple[int, Path]:
        argv = ["run", "--workloads", "cli", "--samples", "2", "--output-dir", str(self.output), "--capture-id", capture_id]
        for name, target in self.targets:
            argv += ["--target", f"{name}={target}"]
        with mock.patch("sys.stdout", new_callable=io.StringIO), mock.patch("sys.stderr", new_callable=io.StringIO):
            code = bench.main(argv + list(extra))
        return code, self.output / capture_id / "capture.json"

    def test_run_records_a_complete_abba_capture_with_inventory_and_machine_state(self) -> None:
        code, path = self.run_capture("smoke")
        self.assertEqual(code, 0)
        capture, _arm = bench.load_capture(f"{path}#a")
        self.assertEqual((capture["state"], capture["complete"], capture["errors"]), ("complete", True, []))
        self.assertEqual(capture["inventory"], {"cli": {"metrics": ["cli.help_ms", "cli.status_ms"], "equivalence": []}})
        self.assertEqual(capture["overrides"]["samples"], 2)
        order = [(sample["block"], sample["arm"], sample["primer"]) for sample in capture["samples"]]
        self.assertEqual(order, [(-1, "b", True), (-1, "a", True), (0, "a", False), (0, "b", False), (1, "b", False), (1, "a", False)])
        self.assertTrue(all("loadavg" in sample["machine"] for sample in capture["samples"]))
        for sample in capture["samples"]:
            start, end = sample["hostCpu"]["start"], sample["hostCpu"]["end"]
            self.assertTrue(bench._valid_cpu_counters(start) and bench._valid_cpu_counters(end), sample["hostCpu"])
            # Host counters publish about once per second, so one short sample may see no new ticks.
            self.assertGreaterEqual(end["totalTicks"], start["totalTicks"])
            self.assertGreater(end["ownCpuSeconds"], start["ownCpuSeconds"])
        self.assertIsNotNone(bench.foreign_cpu_windows(capture, "cli", 10.0))
        self.assertEqual(capture["summary"]["contaminationPolicy"], bench.load_gates()["contamination"])
        self.assertIn("version", capture["cliPython"])
        report = bench.evaluate_comparison(capture, "a", capture, "b", bench.load_gates(), "no-regression")
        self.assertEqual(report["exitCode"], bench.EXIT_INCONCLUSIVE)
        self.assertTrue(any("smoke override samples=2" in item for item in report["inconclusive"]))

    def test_a_target_changing_mid_capture_fails_the_capture(self) -> None:
        original = bench.run_cli_sample
        mutated = []

        def mutate_then_sample(target_root: Path, scratch: Path) -> dict:
            if not mutated:
                with (self.targets[0][1] / "conductor").open("a") as handle:
                    handle.write("\n# changed\n")
                mutated.append(True)
            return original(target_root, scratch)

        with mock.patch.object(bench, "run_cli_sample", mutate_then_sample):
            code, path = self.run_capture("changed")
        self.assertEqual(code, bench.EXIT_HARNESS_FAILURE)
        capture = json.loads(path.read_text())
        self.assertEqual((capture["state"], capture["complete"]), ("failed", False))
        self.assertIn("target bytes changed during the capture", [error["error"] for error in capture["errors"]])

    def test_setup_failures_and_interrupts_still_write_a_failed_capture(self) -> None:
        for failure, state in ((OSError("disk full"), "failed"), (subprocess.CalledProcessError(1, ["git"]), "failed"), (KeyboardInterrupt(), "interrupted")):
            with self.subTest(failure=type(failure).__name__):
                capture_id = f"setup-{type(failure).__name__}"
                with mock.patch.object(bench, "stage_target", side_effect=failure):
                    code, path = self.run_capture(capture_id)
                self.assertEqual(code, bench.EXIT_HARNESS_FAILURE)
                capture = json.loads(path.read_text())
                self.assertEqual((capture["state"], capture["complete"]), (state, False))
                self.assertTrue(capture["errors"])
                loaded = dict(capture, _path=str(path))
                report = bench.evaluate_comparison(loaded, "a", loaded, "b", bench.load_gates(), "no-regression")
                self.assertEqual(report["exitCode"], bench.EXIT_HARNESS_FAILURE)

    def test_unsafe_names_and_invalid_sample_counts_are_rejected_before_capturing(self) -> None:
        cases = (
            ["--capture-id", "../escape"],
            ["--capture-id", ".."],
            ["--class-samples", "fast=10"],
            ["--class-samples", "bogus=90"],
        )
        with mock.patch("sys.stdout", new_callable=io.StringIO), mock.patch("sys.stderr", new_callable=io.StringIO):
            for extra in cases:
                with self.subTest(extra=extra):
                    argv = ["run", "--workloads", "cli", "--output-dir", str(self.output), "--target", f"a={self.targets[0][1]}"]
                    self.assertEqual(bench.main(argv + extra), bench.EXIT_HARNESS_FAILURE)
            bad_arm = ["run", "--workloads", "cli", "--output-dir", str(self.output), "--target", f"../a={self.targets[0][1]}"]
            self.assertEqual(bench.main(bad_arm), bench.EXIT_HARNESS_FAILURE)
            zero = ["run", "--workloads", "cli", "--samples", "0", "--output-dir", str(self.output), "--target", f"a={self.targets[0][1]}"]
            self.assertEqual(bench.main(zero), bench.EXIT_HARNESS_FAILURE)
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "escape").exists())

    def test_retained_logs_are_frozen_and_fingerprinted_once(self) -> None:
        source = self.root / "jobs dir"
        source.mkdir()
        (source / "one.log").write_bytes(b"Compiling A\n")
        (source / "two.log").write_bytes(b"Compiling B\n")
        (source / "ignored.json").write_text("{}")
        frozen = bench.freeze_retained_logs(source, self.root / "frozen")
        (source / "one.log").write_bytes(b"rewritten by the daemon\n")
        self.assertEqual([entry["name"] for entry in frozen["files"]], ["one.log", "two.log"])
        self.assertEqual((self.root / "frozen" / "one.log").read_bytes(), b"Compiling A\n")
        self.assertEqual(frozen["files"][0]["sha256"], bench.sha256_bytes(b"Compiling A\n"))
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaises(bench.HarnessError):
            bench.freeze_retained_logs(empty, self.root / "frozen-empty")

    def test_machine_probe_applies_the_predeclared_limit(self) -> None:
        def counters(foreign: float) -> list[dict]:
            ncpu = os.cpu_count() or 1
            busy = int(round(100 * foreign * 0.5))
            return [
                {"at": 0.0, "busyTicks": 0, "totalTicks": 0, "ownCpuSeconds": 0.0},
                {"at": 0.5, "busyTicks": busy, "totalTicks": 50 * ncpu, "ownCpuSeconds": 0.0},
            ]

        no_slots = {"loadavg": [1.0, 1.0, 1.0], "slotsProbed": 0, "slotsHeld": []}
        for foreign, expected in ((1.0, 0), (6.0, bench.EXIT_INCONCLUSIVE)):
            with self.subTest(foreign=foreign), mock.patch.object(bench, "host_cpu_counters", side_effect=counters(foreign)), \
                    mock.patch.object(bench, "machine_slot_contention", return_value=no_slots), \
                    mock.patch.object(bench.time, "sleep"), mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                self.assertEqual(bench.main(["machine", "--seconds", "0.5"]), expected)
                report = json.loads(out.getvalue())
                self.assertAlmostEqual(report["foreignCores"], foreign)
                self.assertEqual(report["maxForeignCores"], bench.load_gates()["contamination"]["maxForeignCores"])

    @unittest.skipUnless(shutil.which("make"), "needs make")
    def test_make_targets_quote_scalar_arguments_with_spaces(self) -> None:
        result = subprocess.run(
            [
                "make",
                "-n",
                "-C",
                str(bench.REPO_ROOT),
                "dev-conductor-bench",
                "TARGET_A=parent=/tmp/a b/parent",
                "LOGS_DIR=/Users/x/Library/Application Support/RepoPrompt CE/jobs",
                "CLASS_SAMPLES=fast=90",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("--target 'parent=/tmp/a b/parent'", result.stdout)
        self.assertIn("--logs-dir '/Users/x/Library/Application Support/RepoPrompt CE/jobs'", result.stdout)
        self.assertIn("--class-samples 'fast=90'", result.stdout)
        compare = subprocess.run(
            ["make", "-n", "-C", str(bench.REPO_ROOT), "dev-conductor-bench-compare", "BASELINE=/a b#x", "CANDIDATE=/a b#y",
             "CONFIRM_BASELINE=/c d#x", "CONFIRM_CANDIDATE=/c d#y"],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("--confirm-baseline '/c d#x' --confirm-candidate '/c d#y'", compare.stdout)


if __name__ == "__main__":
    unittest.main()
