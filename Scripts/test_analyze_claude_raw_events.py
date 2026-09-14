#!/usr/bin/env python3
"""Hermetic tests for analyze_claude_raw_events.py."""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import analyze_claude_raw_events as analyzer  # noqa: E402


def log_record(
    payload: object,
    *,
    kind: str = "protocol.inbound.streamPayload",
    run_id: str = "run-a",
    tab_id: str = "tab-a",
    window_id: int = 1,
    session_id: str = "session-a",
    **extra: object,
) -> dict[str, object]:
    record: dict[str, object] = {
        "kind": kind,
        "timestamp": "2026-09-14T00:00:00.000Z",
        "runID": run_id,
        "tabID": tab_id,
        "windowID": window_id,
        "sessionID": session_id,
        "payload": payload,
    }
    record.update(extra)
    return record


def assistant_payload(
    request_id: str | None,
    usage: object,
    *,
    parent: object = None,
    message_id: str = "message-id",
    **extra: object,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "type": "assistant",
        "parent_tool_use_id": parent,
        "message": {
            "id": message_id,
            "model": "private-model",
            "usage": usage,
            "content": [{"type": "text", "text": "private assistant text"}],
        },
    }
    if request_id is not None:
        payload["request_id"] = request_id
    payload.update(extra)
    return payload


def result_payload(
    request_id: str | None,
    *,
    usage: object = None,
    cost: object = None,
    uuid: str | None = None,
    parent: object = None,
    include_usage: bool = True,
    include_cost: bool = True,
    **extra: object,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "type": "result",
        "parent_tool_use_id": parent,
        "result": "private final text",
        "session_id": "private-provider-session",
    }
    if request_id is not None:
        payload["request_id"] = request_id
    if uuid is not None:
        payload["uuid"] = uuid
    if include_usage:
        payload["usage"] = usage
    if include_cost:
        payload["total_cost_usd"] = cost
    payload.update(extra)
    return payload


class AnalyzerTestCase(unittest.TestCase):
    def analyze_records(
        self,
        records: list[object],
        *,
        raw_lines: list[bytes] | None = None,
        limits: analyzer.Limits | None = None,
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.jsonl"
            with path.open("wb") as handle:
                for record in records:
                    handle.write(json.dumps(record, separators=(",", ":")).encode("utf-8") + b"\n")
                for line in raw_lines or []:
                    handle.write(line)
                    if not line.endswith(b"\n"):
                        handle.write(b"\n")
            return analyzer.analyze_paths([path], limits)

    def test_summary_reports_weighted_cache_share_and_unsummed_cost_checkpoints(self) -> None:
        first_usage = {
            "input_tokens": 10,
            "output_tokens": 2,
            "cache_read_input_tokens": 90,
            "cache_creation_input_tokens": 0,
        }
        second_usage = {
            "input_tokens": 900,
            "output_tokens": 3,
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0,
        }
        turn_usage = {
            "input_tokens": 910,
            "output_tokens": 5,
            "cache_read_input_tokens": 90,
            "cache_creation_input_tokens": 0,
        }
        first = assistant_payload("request-a", first_usage)
        records = [
            log_record(
                {
                    "encoding": "utf8",
                    "byteCount": 999_999,
                    "text": json.dumps(first),
                },
                kind="protocol.inbound.raw",
            ),
            log_record(first),
            log_record(first),
            log_record(assistant_payload("request-b", second_usage)),
            log_record(
                {"type": "message_stop", "promptTokens": 910},
                kind="translator.streamResult",
            ),
            log_record(
                result_payload(
                    "request-b",
                    usage=turn_usage,
                    cost=1.0,
                    uuid="result-one",
                )
            ),
            log_record(
                result_payload(
                    "request-b",
                    include_usage=False,
                    cost=1.5,
                    uuid="result-two",
                )
            ),
            log_record(
                result_payload(
                    "request-b",
                    usage=turn_usage,
                    cost=1.0,
                    uuid="result-one",
                )
            ),
        ]

        summary = self.analyze_records(records)

        self.assertEqual(summary["views"]["canonical_decoded_records"], 6)
        self.assertEqual(summary["views"]["raw_records_ignored"], 1)
        self.assertEqual(summary["views"]["translated_records_ignored"], 1)
        self.assertEqual(
            summary["parent_requests"]["unique_observed_parent_request_ids"],
            2,
        )
        self.assertEqual(summary["parent_requests"]["duplicate_snapshot_records"], 1)
        self.assertEqual(
            summary["parent_requests"]["turn_level_result_usage_snapshot_records"],
            2,
        )
        self.assertEqual(summary["cache"]["status"], "partial")
        self.assertEqual(summary["cache"]["contributing_requests"], 2)
        self.assertEqual(
            summary["cache"]["excluded_parent_usage_reasons"]["result_turn_scope"],
            2,
        )
        self.assertEqual(
            summary["cache"]["totals"],
            {
                "input_tokens": 910,
                "cache_read_input_tokens": 90,
                "cache_creation_input_tokens": 0,
                "denominator_tokens": 1000,
            },
        )
        self.assertEqual(summary["cache"]["weighted_cache_hit_percent"], "9")
        self.assertEqual(summary["turn_level_result_usage"]["usage_objects"], 2)
        self.assertEqual(
            summary["turn_level_result_usage"]["included_in_request_cache_totals"],
            0,
        )
        checkpoints = summary["cost_checkpoints"]
        self.assertEqual(checkpoints["identified_checkpoint_count"], 2)
        self.assertEqual(checkpoints["duplicate_identity_records"], 1)
        self.assertEqual(
            checkpoints["series"][0]["cumulative_values_usd"],
            ["1.0", "1.5"],
        )
        self.assertIsNone(checkpoints["aggregate_usd"])
        self.assertIsNone(checkpoints["delta_usd"])
        self.assertFalse(summary["claims"]["savings_established"])

    def test_request_updates_preserve_missing_and_exclude_invalid_or_conflicting_fields(self) -> None:
        def stream_payload(
            request_id: str,
            event_type: str,
            usage: dict[str, object],
        ) -> dict[str, object]:
            event: dict[str, object] = {"type": event_type, "usage": usage}
            if event_type == "message_start":
                event = {
                    "type": event_type,
                    "message": {"id": "private-message", "usage": usage},
                }
            return {
                "type": "stream_event",
                "request_id": request_id,
                "parent_tool_use_id": None,
                "event": event,
            }

        records = [
            log_record(
                stream_payload(
                    "preserve",
                    "message_start",
                    {
                        "input_tokens": 10,
                        "cache_read_input_tokens": 90,
                        "cache_creation_input_tokens": 0,
                    },
                )
            ),
            log_record(
                stream_payload(
                    "preserve",
                    "message_delta",
                    {"output_tokens": 7},
                )
            ),
            log_record(
                stream_payload(
                    "invalid",
                    "message_start",
                    {
                        "input_tokens": 20,
                        "cache_read_input_tokens": 80,
                        "cache_creation_input_tokens": 0,
                    },
                )
            ),
            log_record(
                stream_payload(
                    "invalid",
                    "message_delta",
                    {"cache_read_input_tokens": -1},
                )
            ),
            log_record(
                stream_payload(
                    "conflict",
                    "message_start",
                    {
                        "input_tokens": 30,
                        "cache_read_input_tokens": 70,
                        "cache_creation_input_tokens": 0,
                    },
                )
            ),
            log_record(
                stream_payload(
                    "conflict",
                    "message_delta",
                    {"cache_read_input_tokens": 60},
                )
            ),
        ]

        summary = self.analyze_records(records)

        self.assertEqual(summary["parent_requests"]["reconciled_update_records"], 3)
        self.assertEqual(summary["parent_requests"]["conflicting_request_field_sets"], 1)
        self.assertEqual(summary["parent_requests"]["invalid_request_field_sets"], 1)
        self.assertEqual(summary["cache"]["status"], "partial")
        self.assertEqual(summary["cache"]["contributing_requests"], 1)
        self.assertEqual(summary["cache"]["incomplete_triple_requests"], 2)
        self.assertEqual(
            summary["cache"]["totals"],
            {
                "input_tokens": 10,
                "cache_read_input_tokens": 90,
                "cache_creation_input_tokens": 0,
                "denominator_tokens": 100,
            },
        )
        self.assertEqual(summary["cache"]["weighted_cache_hit_percent"], "90")

    def test_missing_zero_invalid_and_exact_observation_number_rules_remain_distinct(self) -> None:
        zero_usage = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0,
        }
        missing_usage = {
            "input_tokens": 10,
            "cache_read_input_tokens": 5,
        }
        invalid_canonical_usage = {
            "input_tokens": -1,
            "inputTokens": 20,
            "cache_read_input_tokens": -0.0,
            "cache_creation_input_tokens": True,
        }
        exact_usage = {
            "input_tokens": 2.0,
            "output_tokens": "3",
            "cache_read_input_tokens": "8",
            "cache_creation_input_tokens": 0,
        }

        summary = self.analyze_records(
            [
                log_record(assistant_payload("zero", zero_usage)),
                log_record(assistant_payload("missing", missing_usage)),
                log_record(assistant_payload("invalid", invalid_canonical_usage)),
                log_record(assistant_payload("exact", exact_usage)),
            ]
        )

        fields = summary["observation_coverage"]["usage_fields"]
        self.assertEqual(fields["input_tokens"], {"valid": 3, "zero": 1, "missing": 0, "invalid": 1})
        self.assertEqual(
            fields["cache_creation_input_tokens"],
            {"valid": 2, "zero": 2, "missing": 1, "invalid": 1},
        )
        self.assertEqual(fields["cache_read_input_tokens"]["invalid"], 1)
        self.assertEqual(summary["cache"]["contributing_requests"], 1)
        self.assertEqual(summary["cache"]["zero_denominator_requests"], 1)
        self.assertEqual(summary["cache"]["incomplete_triple_requests"], 2)
        self.assertEqual(summary["cache"]["status"], "partial")
        self.assertFalse(summary["cache"]["missing_is_zero"])

    def test_excluded_parent_usage_makes_coverage_partial_without_invented_requests(self) -> None:
        usage = {
            "input_tokens": 10,
            "cache_read_input_tokens": 90,
            "cache_creation_input_tokens": 0,
        }
        summary = self.analyze_records(
            [
                log_record(assistant_payload("identified", usage)),
                log_record(assistant_payload(None, usage)),
                log_record(assistant_payload("invalid-scope", usage), sessionID=None),
                log_record(assistant_payload("ambiguous-lane", usage, parent=" ")),
                log_record(assistant_payload("sidechain", usage, parent="tool-parent")),
            ]
        )

        self.assertEqual(
            summary["parent_requests"]["unique_observed_parent_request_ids"],
            1,
        )
        self.assertEqual(summary["cache"]["contributing_requests"], 1)
        self.assertEqual(summary["cache"]["excluded_requests"], 0)
        self.assertEqual(summary["cache"]["excluded_parent_usage_records"], 3)
        self.assertEqual(
            summary["cache"]["excluded_parent_usage_reasons"],
            {
                "ambiguous_parent_lane": 1,
                "invalid_usage_nesting": 0,
                "result_turn_scope": 0,
                "missing_or_invalid_request_id": 1,
                "ambiguous_scope": 1,
            },
        )
        self.assertEqual(summary["cache"]["sidechain_usage_records_excluded"], 1)
        self.assertTrue(summary["cache"]["coverage_partial_due_to_excluded_parent_usage"])
        self.assertEqual(summary["cache"]["status"], "partial")
        self.assertEqual(summary["cache"]["weighted_cache_hit_percent"], "90")

    def test_malformed_truncated_and_oversize_records_are_bounded_and_reported(self) -> None:
        valid = log_record(
            assistant_payload(
                "valid",
                {
                    "input_tokens": 1,
                    "cache_read_input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                },
            )
        )
        truncated_raw = log_record(
            {
                "encoding": "utf8",
                "byteCount": 100_000,
                "text": "PRIVATE_TRUNCATED_TEXT",
                "truncated": True,
            },
            kind="protocol.inbound.raw",
        )
        oversize = json.dumps(
            log_record({"type": "assistant", "text": "S" * 2_000})
        ).encode("utf-8") + b"\n"
        limits = analyzer.Limits(
            max_file_bytes=8_192,
            max_total_bytes=8_192,
            max_line_bytes=600,
            max_lines=20,
        )

        summary = self.analyze_records(
            [truncated_raw, valid, ["not", "an", "object"]],
            raw_lines=[b'{"malformed":"PRIVATE_MALFORMED"', oversize],
            limits=limits,
        )

        self.assertEqual(summary["input"]["physical_lines"], 5)
        self.assertEqual(summary["input"]["malformed_json_records"], 1)
        self.assertEqual(summary["input"]["non_object_records"], 1)
        self.assertEqual(summary["input"]["oversize_lines_skipped"], 1)
        self.assertEqual(summary["views"]["raw_truncated_records"], 1)
        self.assertEqual(summary["views"]["canonical_decoded_records"], 1)

    def test_file_and_line_limits_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.jsonl"
            path.write_text("{}\n{}\n", encoding="utf-8")
            with self.assertRaisesRegex(analyzer.AnalyzerError, "max file bytes"):
                analyzer.analyze_paths(
                    [path],
                    analyzer.Limits(
                        max_file_bytes=3,
                        max_total_bytes=3,
                        max_line_bytes=3,
                        max_lines=10,
                    ),
                )
            with self.assertRaisesRegex(analyzer.AnalyzerError, "line count"):
                analyzer.analyze_paths(
                    [path],
                    analyzer.Limits(
                        max_file_bytes=100,
                        max_total_bytes=100,
                        max_line_bytes=100,
                        max_lines=1,
                    ),
                )

    def test_sidechain_invalid_parent_replay_and_ambiguous_scope_are_not_owned(self) -> None:
        usage = {
            "input_tokens": 10,
            "cache_read_input_tokens": 90,
            "cache_creation_input_tokens": 0,
        }
        records = [
            log_record(assistant_payload("parent-good", usage)),
            log_record(assistant_payload("child", usage, parent="tool-parent")),
            log_record(assistant_payload("ambiguous-parent", usage, parent=" ")),
            log_record(assistant_payload("missing-session", usage), sessionID=None),
            log_record(
                result_payload(
                    "replay-shaped",
                    usage=usage,
                    cost=2.0,
                    uuid="replay-result",
                    replay=True,
                ),
                run_id="conflicted-run",
                tab_id="tab-one",
            ),
            log_record(
                result_payload(
                    "conflicted",
                    usage=usage,
                    cost=3.0,
                    uuid="conflicted-result",
                ),
                run_id="conflicted-run",
                tab_id="tab-two",
            ),
            log_record(
                result_payload(
                    "child-cost",
                    usage=usage,
                    cost=4.0,
                    uuid="child-result",
                    parent="native-child",
                )
            ),
            log_record(
                result_payload(
                    None,
                    include_usage=False,
                    cost=5.0,
                    uuid="replay-ambiguous-result",
                    replay=True,
                )
            ),
        ]

        summary = self.analyze_records(records)

        self.assertEqual(
            summary["parent_requests"]["unique_observed_parent_request_ids"],
            1,
        )
        self.assertEqual(summary["observation_coverage"]["lane_records"]["sidechain"], 2)
        self.assertEqual(summary["observation_coverage"]["lane_records"]["ambiguous"], 1)
        self.assertEqual(
            summary["observation_coverage"]["envelope_scope"]["conflicting_run_scopes"],
            1,
        )
        self.assertGreaterEqual(
            summary["parent_requests"]["ambiguous_scope_request_records"],
            3,
        )
        checkpoints = summary["cost_checkpoints"]
        self.assertEqual(checkpoints["identified_checkpoint_count"], 1)
        self.assertEqual(
            checkpoints["series"][0]["cumulative_values_usd"],
            ["5.0"],
        )
        self.assertIsNone(checkpoints["aggregate_usd"])
        self.assertFalse(checkpoints["capture_order_establishes_live_ownership"])
        self.assertEqual(checkpoints["excluded_valid_records"]["sidechain"], 1)
        self.assertEqual(checkpoints["excluded_valid_records"]["ambiguous_scope"], 2)
        self.assertEqual(summary["g3_evidence"]["live_replay_cost_ownership"], "unknown_not_logged")
        self.assertIsNone(summary["parent_requests"]["billed_request_count"])

    def test_message_id_uuid_and_raw_byte_count_are_not_request_or_response_evidence(self) -> None:
        payload = assistant_payload(
            None,
            {
                "input_tokens": 1,
                "cache_read_input_tokens": 1,
                "cache_creation_input_tokens": 0,
            },
            message_id="not-a-request-id",
            uuid="also-not-a-request-id",
        )
        summary = self.analyze_records(
            [
                log_record(payload),
                log_record(
                    {
                        "encoding": "utf8",
                        "byteCount": 65_536,
                        "text": "private",
                    },
                    kind="protocol.inbound.raw",
                ),
            ]
        )
        self.assertEqual(
            summary["parent_requests"]["unique_observed_parent_request_ids"],
            0,
        )
        self.assertEqual(summary["g3_evidence"]["response_bytes"], "unknown_not_logged")
        self.assertEqual(summary["g3_evidence"]["response_tokens"], "unknown_not_logged")
        self.assertFalse(summary["g3_evidence"]["bytes_are_tokens"])

    def test_summary_never_echoes_private_payload_identifiers_models_paths_or_errors(self) -> None:
        secrets = [
            "SECRET_REQUEST_7d92",
            "SECRET_RUN_65ab",
            "SECRET_TAB_a911",
            "SECRET_SESSION_83cc",
            "SECRET_WORKSPACE_PATH_51ee",
            "SECRET_MODEL_1ef0",
            "SECRET_ERROR_f673",
            "SECRET_TEXT_b642",
        ]
        payload = {
            "type": "result",
            "request_id": secrets[0],
            "uuid": "SECRET_UUID_f97e",
            "parent_tool_use_id": None,
            "usage": {
                "input_tokens": 1,
                "cache_read_input_tokens": 1,
                "cache_creation_input_tokens": 0,
            },
            "total_cost_usd": 1.25,
            "model": secrets[5],
            "error": secrets[6],
            "result": secrets[7],
        }
        record = log_record(
            payload,
            run_id=secrets[1],
            tab_id=secrets[2],
            session_id=secrets[3],
            workspacePath=secrets[4],
        )

        rendered = json.dumps(self.analyze_records([record]), sort_keys=True)

        for secret in secrets + ["SECRET_UUID_f97e"]:
            self.assertNotIn(secret, rendered)
        self.assertNotIn("SECRET_", rendered)

    def test_hostile_shapes_surrogates_and_deep_json_are_controlled_and_private(self) -> None:
        script = SCRIPT_DIR / "analyze_claude_raw_events.py"
        usage = {
            "input_tokens": 10,
            "cache_read_input_tokens": 90,
            "cache_creation_input_tokens": 0,
        }
        private_markers = [
            "PRIVATE_KIND",
            "PRIVATE_TYPE",
            "PRIVATE_SURROGATE",
            "PRIVATE_NESTING",
        ]
        records = [
            log_record({}, kind=["PRIVATE_KIND"]),  # type: ignore[arg-type]
            log_record({"type": ["PRIVATE_TYPE"]}),
            log_record({"type": "stream_event", "event": ["PRIVATE_NESTING"]}),
            log_record(
                assistant_payload("request-invalid-scope", usage),
                run_id="PRIVATE_SURROGATE_\ud800",
            ),
            log_record(assistant_payload("PRIVATE_SURROGATE_\ud800", usage)),
            log_record(
                result_payload(
                    None,
                    include_usage=False,
                    cost=1,
                    uuid="PRIVATE_SURROGATE_\ud800",
                )
            ),
            log_record(
                {
                    "type": "assistant",
                    "request_id": "invalid-message",
                    "parent_tool_use_id": None,
                    "message": ["PRIVATE_NESTING"],
                }
            ),
        ]
        deep_json = ("[" * 2_000 + "0" + "]" * 2_000).encode("utf-8") + b"\n"

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "PRIVATE_INPUT.jsonl"
            with path.open("wb") as handle:
                for record in records:
                    handle.write(json.dumps(record, separators=(",", ":")).encode("utf-8"))
                    handle.write(b"\n")
                handle.write(deep_json)
            result = subprocess.run(
                [sys.executable, str(script), "--compact", str(path)],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertNotIn("Traceback", result.stdout)
        for marker in private_markers:
            self.assertNotIn(marker, result.stdout)
            self.assertNotIn(marker, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["input"]["malformed_json_records"], 0)
        self.assertEqual(summary["input"]["non_object_records"], 1)
        self.assertEqual(summary["views"]["invalid_record_discriminators"], 1)
        self.assertEqual(summary["views"]["invalid_payload_discriminators"], 1)
        self.assertEqual(summary["views"]["invalid_canonical_nesting"], 1)
        self.assertEqual(
            summary["observation_coverage"]["usage_sources"]["assistant"]["invalid_usage"],
            1,
        )
        self.assertEqual(
            summary["parent_requests"]["unique_observed_parent_request_ids"],
            1,
        )
        self.assertTrue(summary["cache"]["coverage_partial_due_to_excluded_parent_usage"])
        self.assertEqual(
            summary["cost_checkpoints"]["excluded_valid_records"]["unidentified"],
            1,
        )

    def test_mid_read_io_and_growing_oversize_drain_fail_with_bounded_safe_errors(self) -> None:
        class FailingStream:
            def readline(self, _size: int) -> bytes:
                raise OSError("PRIVATE_MID_READ_PATH")

        failing = analyzer._Analyzer(  # noqa: SLF001
            analyzer.Limits(
                max_file_bytes=32,
                max_total_bytes=32,
                max_line_bytes=8,
                max_lines=10,
            )
        )
        with self.assertRaises(analyzer.AnalyzerError) as raised:
            failing._read_handle(FailingStream(), 1)  # noqa: SLF001
        self.assertEqual(str(raised.exception), "unable to read input file 1")
        self.assertNotIn("PRIVATE_MID_READ_PATH", str(raised.exception))

        class GrowingStream:
            def __init__(self) -> None:
                self.calls = 0

            def readline(self, size: int) -> bytes:
                self.calls += 1
                return b"x" * size

        growing_stream = GrowingStream()
        growing = analyzer._Analyzer(  # noqa: SLF001
            analyzer.Limits(
                max_file_bytes=32,
                max_total_bytes=32,
                max_line_bytes=8,
                max_lines=10,
            )
        )
        with self.assertRaisesRegex(analyzer.AnalyzerError, "exceeds max file bytes"):
            growing._read_handle(growing_stream, 1)  # noqa: SLF001
        self.assertEqual(growing_stream.calls, 2)
        self.assertLessEqual(growing.total_bytes, 9)

        recursive = analyzer._Analyzer(  # noqa: SLF001
            analyzer.Limits(
                max_file_bytes=32,
                max_total_bytes=32,
                max_line_bytes=32,
                max_lines=10,
            )
        )
        with mock.patch.object(
            analyzer,
            "_safe_loads",
            side_effect=RecursionError("PRIVATE_DEEP_JSON"),
        ):
            recursive._read_handle(io.BytesIO(b"{}\n"), 1)  # noqa: SLF001
        self.assertEqual(recursive.input_counts["malformed_json_records"], 1)

    def test_main_masks_unexpected_failures_without_traceback_or_private_content(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(
                analyzer,
                "analyze_paths",
                side_effect=RuntimeError("PRIVATE_UNEXPECTED_FAILURE"),
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            return_code = analyzer.main(["ignored.jsonl"])

        self.assertEqual(return_code, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "error: unexpected failure\n")
        self.assertNotIn("PRIVATE_UNEXPECTED_FAILURE", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_aggregate_overflow_is_deterministic_across_hash_seeds(self) -> None:
        script = SCRIPT_DIR / "analyze_claude_raw_events.py"
        records = [
            log_record(
                assistant_payload(
                    f"request-{index}",
                    {
                        "input_tokens": value,
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 0,
                    },
                )
            )
            for index, value in enumerate((analyzer.MAX_COUNT, 1, 1))
        ]

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.jsonl"
            path.write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            summaries = []
            for seed in ("1", "2"):
                result = subprocess.run(
                    [sys.executable, str(script), "--compact", str(path)],
                    capture_output=True,
                    text=True,
                    check=False,
                    env={**os.environ, "PYTHONHASHSEED": seed},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                summaries.append(json.loads(result.stdout))

        self.assertEqual(summaries[0]["cache"], summaries[1]["cache"])
        cache = summaries[0]["cache"]
        self.assertEqual(cache["contributing_requests"], 3)
        self.assertEqual(cache["excluded_requests"], 0)
        self.assertTrue(cache["aggregate_overflow"])
        self.assertEqual(cache["status"], "unavailable")
        self.assertEqual(
            cache["totals"],
            {
                "input_tokens": None,
                "cache_read_input_tokens": None,
                "cache_creation_input_tokens": None,
                "denominator_tokens": None,
            },
        )

    def test_cli_help_success_and_failures_do_not_echo_input_path(self) -> None:
        script = SCRIPT_DIR / "analyze_claude_raw_events.py"
        help_result = subprocess.run(
            [sys.executable, str(script), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("canonical protocol.inbound.streamPayload", help_result.stdout)

        private_path = "/tmp/SECRET_MISSING_RAW_EVENT_PATH.jsonl"
        missing_result = subprocess.run(
            [sys.executable, str(script), private_path],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(missing_result.returncode, 2)
        self.assertEqual(missing_result.stdout, "")
        self.assertNotIn(private_path, missing_result.stderr)
        self.assertIn("input file 1", missing_result.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            oversized_path = Path(temporary) / "SECRET_OVERSIZED_INPUT.jsonl"
            oversized_path.write_text("{}\n", encoding="utf-8")
            limit_result = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--max-file-bytes",
                    "1",
                    "--max-total-bytes",
                    "1",
                    "--max-line-bytes",
                    "1",
                    str(oversized_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(limit_result.returncode, 2)
        self.assertEqual(limit_result.stdout, "")
        self.assertNotIn(str(oversized_path), limit_result.stderr)
        self.assertIn("exceeds max file bytes", limit_result.stderr)

    def test_g3_gap_contract_and_defaults_remain_explicit(self) -> None:
        summary = self.analyze_records([])
        self.assertEqual(summary["gates"]["wait_default_seconds"], 120)
        self.assertEqual(summary["gates"]["g1_native_claude"], "closed_unqualified")
        self.assertEqual(summary["gates"]["g1_codex"], "closed_unqualified")
        self.assertEqual(summary["gates"]["g3_economics"], "closed_unqualified")
        self.assertEqual(summary["g3_evidence"]["matched_pairs"]["required_minimum"], 5)
        self.assertEqual(summary["g3_evidence"]["matched_pairs"]["observed"], 0)
        self.assertFalse(summary["g3_evidence"]["matched_pairs"]["minimum_met"])
        for field in (
            "wait_return_reason",
            "actual_wait_duration",
            "post_wait_request_correlation",
            "response_bytes",
            "response_tokens",
            "export_fallback",
            "export_latency",
            "completion_time",
            "task_quality",
        ):
            self.assertTrue(summary["g3_evidence"][field].startswith("unknown"))


if __name__ == "__main__":
    unittest.main()
