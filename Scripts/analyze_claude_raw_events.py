#!/usr/bin/env python3
"""Privacy-safe offline summary for existing Claude raw-event JSONL logs.

Only `protocol.inbound.streamPayload` records are treated as canonical provider
observations. Raw text and translated stream-result views are counted for
coverage but never parsed into accounting evidence.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, localcontext
import hashlib
import json
from pathlib import Path
import sys
from typing import Any, BinaryIO, Sequence


SCHEMA_VERSION = "rpce.claude-raw-event-summary.v1"
MAX_COUNT = (1 << 63) - 1
MAX_EXACT_FLOAT_COUNT = 1 << 53

DEFAULT_MAX_FILES = 32
DEFAULT_MAX_FILE_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 128 * 1024 * 1024
DEFAULT_MAX_LINE_BYTES = 2 * 1024 * 1024
DEFAULT_MAX_LINES = 250_000

HARD_MAX_FILE_BYTES = 256 * 1024 * 1024
HARD_MAX_TOTAL_BYTES = 512 * 1024 * 1024
HARD_MAX_LINE_BYTES = 8 * 1024 * 1024
HARD_MAX_LINES = 1_000_000

USAGE_FIELDS = {
    "input_tokens": ("input_tokens", "inputTokens"),
    "output_tokens": ("output_tokens", "outputTokens"),
    "cache_read_input_tokens": ("cache_read_input_tokens", "cacheReadInputTokens"),
    "cache_creation_input_tokens": (
        "cache_creation_input_tokens",
        "cacheCreationInputTokens",
    ),
}
CACHE_FIELDS = (
    "input_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
)
USAGE_SOURCES = (
    "message_start",
    "message_delta",
    "assistant",
    "result",
)


class AnalyzerError(Exception):
    """Expected input or limit failure with a privacy-safe message."""


@dataclass(frozen=True)
class Limits:
    max_files: int = DEFAULT_MAX_FILES
    max_file_bytes: int = DEFAULT_MAX_FILE_BYTES
    max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES
    max_line_bytes: int = DEFAULT_MAX_LINE_BYTES
    max_lines: int = DEFAULT_MAX_LINES

    def validate(self) -> None:
        checks = (
            ("max files", self.max_files, DEFAULT_MAX_FILES),
            ("max file bytes", self.max_file_bytes, HARD_MAX_FILE_BYTES),
            ("max total bytes", self.max_total_bytes, HARD_MAX_TOTAL_BYTES),
            ("max line bytes", self.max_line_bytes, HARD_MAX_LINE_BYTES),
            ("max lines", self.max_lines, HARD_MAX_LINES),
        )
        for label, value, maximum in checks:
            if value <= 0 or value > maximum:
                raise AnalyzerError(f"{label} must be between 1 and {maximum}")
        if self.max_line_bytes > self.max_file_bytes:
            raise AnalyzerError("max line bytes cannot exceed max file bytes")
        if self.max_file_bytes > self.max_total_bytes:
            raise AnalyzerError("max file bytes cannot exceed max total bytes")


@dataclass(frozen=True)
class ObservedCount:
    state: str
    value: int | None = None

    @property
    def fingerprint(self) -> tuple[str, int | None]:
        return (self.state, self.value)


@dataclass(frozen=True)
class UsageCandidate:
    ordinal: int
    run_key: bytes | None
    request_key: bytes
    source: str
    fields: tuple[ObservedCount, ObservedCount, ObservedCount, ObservedCount]

    @property
    def fingerprint(self) -> tuple[Any, ...]:
        return (self.source, *(field.fingerprint for field in self.fields))


@dataclass(frozen=True)
class UsageCoverageRecord:
    run_key: bytes | None
    source: str
    lane: str
    request_state: str
    usage_state: str


@dataclass(frozen=True)
class CostCandidate:
    ordinal: int
    run_key: bytes | None
    identity_key: tuple[str, bytes] | None
    lane: str
    value: Decimal


def _identifier_key(value: str) -> bytes | None:
    try:
        encoded = value.encode("utf-8", errors="strict")
    except UnicodeEncodeError:
        return None
    return hashlib.sha256(encoded).digest()


def _nonblank_string(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed if trimmed else None


def _request_identifier(payload: dict[str, Any]) -> tuple[str, bytes | None]:
    canonical_present = "request_id" in payload
    raw = payload.get("request_id") if canonical_present else payload.get("requestId")
    if not canonical_present and "requestId" not in payload:
        return ("missing", None)
    value = _nonblank_string(raw)
    if value is None:
        return ("invalid", None)
    key = _identifier_key(value)
    if key is None:
        return ("invalid", None)
    return ("valid", key)


def _event_identity(
    payload: dict[str, Any],
    request_state: str,
    request_key: bytes | None,
) -> tuple[str, bytes] | None:
    envelope_id = _nonblank_string(payload.get("uuid"))
    if envelope_id is not None:
        envelope_key = _identifier_key(envelope_id)
        return ("uuid", envelope_key) if envelope_key is not None else None
    if request_state == "valid" and request_key is not None:
        return ("request_id", request_key)
    return None


def _lane(payload: dict[str, Any]) -> str:
    if "parent_tool_use_id" not in payload or payload["parent_tool_use_id"] is None:
        return "parent"
    parent = payload["parent_tool_use_id"]
    if isinstance(parent, str) and parent.strip():
        return "sidechain"
    if isinstance(parent, int) and not isinstance(parent, bool):
        return "sidechain"
    return "ambiguous"


def _observed_count(usage: dict[str, Any], snake: str, camel: str) -> ObservedCount:
    if snake in usage:
        raw = usage[snake]
    elif camel in usage:
        raw = usage[camel]
    else:
        return ObservedCount("missing")

    if isinstance(raw, bool):
        return ObservedCount("invalid")
    if isinstance(raw, int):
        if 0 <= raw <= MAX_COUNT:
            return ObservedCount("valid", raw)
        return ObservedCount("invalid")
    if isinstance(raw, Decimal):
        if (
            raw.is_finite()
            and not raw.is_signed()
            and raw == raw.to_integral_value()
            and raw <= MAX_EXACT_FLOAT_COUNT
        ):
            return ObservedCount("valid", int(raw))
        return ObservedCount("invalid")
    if isinstance(raw, str):
        encoded = raw.encode("ascii", errors="ignore")
        if encoded and len(encoded) == len(raw) and all(48 <= byte <= 57 for byte in encoded):
            try:
                value = int(raw)
            except ValueError:
                return ObservedCount("invalid")
            if value <= MAX_COUNT:
                return ObservedCount("valid", value)
    return ObservedCount("invalid")


def _usage_carrier(payload: dict[str, Any]) -> tuple[str, Any] | None:
    payload_type = payload.get("type")
    if not isinstance(payload_type, str):
        return None
    if payload_type in {"assistant", "message"}:
        message = payload.get("message")
        if "message" in payload and not isinstance(message, dict):
            return ("assistant", _INVALID)
        container = message if isinstance(message, dict) else payload
        return ("assistant", container.get("usage", _MISSING))
    if payload_type == "result":
        return ("result", payload.get("usage", _MISSING))
    if payload_type != "stream_event":
        return None
    event = payload.get("event")
    if not isinstance(event, dict):
        return None
    event_type = event.get("type")
    if event_type == "message_start":
        message = event.get("message")
        if not isinstance(message, dict):
            return ("message_start", _INVALID)
        return ("message_start", message.get("usage", _MISSING))
    if event_type == "message_delta":
        return ("message_delta", event.get("usage", _MISSING))
    return None


def _cost_value(payload: dict[str, Any]) -> tuple[str, Decimal | None]:
    if "total_cost_usd" not in payload:
        return ("missing", None)
    raw = payload["total_cost_usd"]
    if isinstance(raw, bool) or not isinstance(raw, (int, Decimal)):
        return ("invalid", None)
    try:
        value = Decimal(raw) if isinstance(raw, int) else raw
    except (InvalidOperation, ValueError):
        return ("invalid", None)
    if not value.is_finite() or value.is_signed():
        return ("invalid", None)
    return ("valid", value)


def _safe_loads(raw: bytes) -> Any:
    text = raw.decode("utf-8")
    return json.loads(
        text,
        parse_float=Decimal,
        parse_int=int,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
    )


def _decimal_text(value: Decimal) -> str:
    if value == 0:
        return "0"
    return str(value)


def _percent_text(numerator: int, denominator: int) -> str:
    with localcontext() as context:
        context.prec = 50
        value = (Decimal(numerator) * Decimal(100) / Decimal(denominator)).quantize(
            Decimal("0.000001"),
            rounding=ROUND_HALF_UP,
        )
    return format(value, "f").rstrip("0").rstrip(".") or "0"


def _checked_add(total: int, value: int) -> int | None:
    result = total + value
    return result if result <= MAX_COUNT else None


def _cache_triple(
    fields: tuple[ObservedCount, ObservedCount, ObservedCount, ObservedCount],
) -> tuple[str, tuple[int, int, int] | None]:
    triple = (fields[0], fields[2], fields[3])
    if any(field.state != "valid" or field.value is None for field in triple):
        return ("incomplete", None)
    values = tuple(field.value for field in triple if field.value is not None)
    denominator = 0
    for value in values:
        updated = _checked_add(denominator, value)
        if updated is None:
            return ("overflow", None)
        denominator = updated
    if denominator == 0:
        return ("zero_denominator", values)
    return ("valid", values)


def _merge_observed_count(
    established: ObservedCount,
    update: ObservedCount,
) -> ObservedCount:
    if update.state == "missing":
        return established
    if established.state == "missing":
        return update
    if established.state in {"invalid", "conflict"}:
        return established
    if update.state == "invalid":
        return update
    if established.value == update.value:
        return established
    return ObservedCount("conflict")


_MISSING = object()
_INVALID = object()


class _Analyzer:
    def __init__(self, limits: Limits) -> None:
        self.limits = limits
        self.input_counts: Counter[str] = Counter()
        self.view_counts: Counter[str] = Counter()
        self.coverage_counts: Counter[str] = Counter()
        self.source_counts: dict[str, Counter[str]] = {
            source: Counter() for source in USAGE_SOURCES
        }
        self.field_counts: dict[str, Counter[str]] = {
            field: Counter() for field in USAGE_FIELDS
        }
        self.run_bindings: dict[bytes, set[tuple[bytes, int]]] = defaultdict(set)
        self.parent_request_records: list[tuple[bytes | None, bytes]] = []
        self.usage_candidates: list[UsageCandidate] = []
        self.usage_coverage_records: list[UsageCoverageRecord] = []
        self.result_usage_counts: Counter[str] = Counter()
        self.cost_candidates: list[CostCandidate] = []
        self.cost_counts: Counter[str] = Counter()
        self.ordinal = 0
        self.total_bytes = 0

    def analyze_paths(self, paths: Sequence[Path]) -> dict[str, Any]:
        self.limits.validate()
        if not paths:
            raise AnalyzerError("at least one input file is required")
        if len(paths) > self.limits.max_files:
            raise AnalyzerError(f"input file count exceeds limit {self.limits.max_files}")

        sizes: list[int] = []
        for index, path in enumerate(paths, start=1):
            try:
                stat = path.stat()
            except OSError as error:
                raise AnalyzerError(f"unable to inspect input file {index}") from error
            if not path.is_file():
                raise AnalyzerError(f"input {index} is not a regular file")
            if stat.st_size > self.limits.max_file_bytes:
                raise AnalyzerError(f"input file {index} exceeds max file bytes")
            sizes.append(stat.st_size)
        if sum(sizes) > self.limits.max_total_bytes:
            raise AnalyzerError("inputs exceed max total bytes")

        for index, path in enumerate(paths, start=1):
            self._read_path(path, index)

        conflicted_runs = {
            run_key for run_key, bindings in self.run_bindings.items() if len(bindings) > 1
        }
        request_summary, cache_summary = self._summarize_requests(conflicted_runs)
        cost_summary = self._summarize_cost(conflicted_runs)

        return {
            "schema_version": SCHEMA_VERSION,
            "status": "diagnostic_only",
            "input": {
                "file_count": len(paths),
                "bytes_read": self.total_bytes,
                "physical_lines": self.input_counts["physical_lines"],
                "blank_lines": self.input_counts["blank_lines"],
                "malformed_json_records": self.input_counts["malformed_json_records"],
                "non_object_records": self.input_counts["non_object_records"],
                "oversize_lines_skipped": self.input_counts["oversize_lines_skipped"],
                "limits": {
                    "max_files": self.limits.max_files,
                    "max_file_bytes": self.limits.max_file_bytes,
                    "max_total_bytes": self.limits.max_total_bytes,
                    "max_line_bytes": self.limits.max_line_bytes,
                    "max_lines": self.limits.max_lines,
                },
            },
            "views": {
                "canonical_decoded_records": self.view_counts["canonical_decoded_records"],
                "invalid_canonical_payloads": self.view_counts["invalid_canonical_payloads"],
                "invalid_record_discriminators": self.view_counts[
                    "invalid_record_discriminators"
                ],
                "invalid_payload_discriminators": self.view_counts[
                    "invalid_payload_discriminators"
                ],
                "invalid_canonical_nesting": self.view_counts["invalid_canonical_nesting"],
                "raw_records_ignored": self.view_counts["raw_records_ignored"],
                "raw_truncated_records": self.view_counts["raw_truncated_records"],
                "translated_records_ignored": self.view_counts["translated_records_ignored"],
                "other_records_ignored": self.view_counts["other_records_ignored"],
                "policy": "canonical_decoded_only",
            },
            "observation_coverage": {
                "usage_sources": {
                    source: {
                        "carriers": counts["carriers"],
                        "usage_objects": counts["usage_objects"],
                        "missing_usage": counts["missing_usage"],
                        "invalid_usage": counts["invalid_usage"],
                    }
                    for source, counts in self.source_counts.items()
                },
                "usage_fields": {
                    field: {
                        "valid": counts["valid"],
                        "zero": counts["zero"],
                        "missing": counts["missing"],
                        "invalid": counts["invalid"],
                    }
                    for field, counts in self.field_counts.items()
                },
                "request_id_records": {
                    "valid": self.coverage_counts["request_id_valid"],
                    "missing": self.coverage_counts["request_id_missing"],
                    "invalid": self.coverage_counts["request_id_invalid"],
                },
                "lane_records": {
                    "parent": self.coverage_counts["lane_parent"],
                    "sidechain": self.coverage_counts["lane_sidechain"],
                    "ambiguous": self.coverage_counts["lane_ambiguous"],
                },
                "envelope_scope": {
                    "valid_records": self.coverage_counts["scope_valid"],
                    "invalid_records": self.coverage_counts["scope_invalid"],
                    "conflicting_run_scopes": len(conflicted_runs),
                    "session_id_present_records": self.coverage_counts["session_id_present"],
                    "session_id_missing_or_invalid_records": self.coverage_counts[
                        "session_id_missing_or_invalid"
                    ],
                },
            },
            "parent_requests": request_summary,
            "cache": cache_summary,
            "turn_level_result_usage": {
                "usage_objects": self.result_usage_counts["usage_objects"],
                "complete_cache_triples": self.result_usage_counts[
                    "complete_cache_triples"
                ],
                "incomplete_or_invalid_cache_triples": self.result_usage_counts[
                    "incomplete_or_invalid_cache_triples"
                ],
                "zero_denominator_triples": self.result_usage_counts[
                    "zero_denominator_triples"
                ],
                "overflow_triples": self.result_usage_counts["overflow_triples"],
                "included_in_request_cache_totals": 0,
                "scope": "aggregate_billed_turn_observation_only",
            },
            "cost_checkpoints": cost_summary,
            "gates": {
                "wait_default_seconds": 120,
                "g1_native_claude": "closed_unqualified",
                "g1_codex": "closed_unqualified",
                "g3_economics": "closed_unqualified",
                "codex_basis": "separate_standard_global_api_equivalent_not_analyzed",
            },
            "g3_evidence": {
                "matched_pairs": {
                    "observed": 0,
                    "required_minimum": 5,
                    "minimum_met": False,
                },
                "unique_billed_parent_model_requests": "unknown_not_logged",
                "wait_return_reason": "unknown_not_logged",
                "actual_wait_duration": "unknown_not_logged",
                "post_wait_request_correlation": "unknown_not_logged",
                "post_wait_cache_split": "unknown_not_correlated",
                "response_bytes": "unknown_not_logged",
                "response_tokens": "unknown_not_logged",
                "bytes_are_tokens": False,
                "export_fallback": "unknown_not_logged",
                "export_latency": "unknown_not_logged",
                "completion_time": "unknown_not_logged",
                "task_quality": "unknown_not_logged",
                "parent_worker_cost_ownership": "unknown_not_logged",
                "live_replay_cost_ownership": "unknown_not_logged",
            },
            "claims": {
                "cost_aggregate_computed": False,
                "native_child_cost_summed_separately": False,
                "savings_established": False,
                "longer_wait_recommended": False,
            },
        }

    def _read_path(self, path: Path, input_index: int) -> None:
        try:
            handle = path.open("rb")
            with handle:
                self._read_handle(handle, input_index)
        except AnalyzerError:
            raise
        except OSError as error:
            raise AnalyzerError(f"unable to read input file {input_index}") from error

    def _readline_with_budget(
        self,
        handle: BinaryIO,
        requested_bytes: int,
        file_bytes: int,
        input_index: int,
    ) -> tuple[bytes, int]:
        file_remaining = self.limits.max_file_bytes - file_bytes
        total_remaining = self.limits.max_total_bytes - self.total_bytes
        read_limit = min(requested_bytes, file_remaining + 1, total_remaining + 1)
        try:
            chunk = handle.readline(max(1, read_limit))
        except OSError as error:
            raise AnalyzerError(f"unable to read input file {input_index}") from error
        next_file_bytes = file_bytes + len(chunk)
        next_total_bytes = self.total_bytes + len(chunk)
        if next_file_bytes > self.limits.max_file_bytes:
            raise AnalyzerError(
                f"input file {input_index} changed while reading and exceeds max file bytes"
            )
        if next_total_bytes > self.limits.max_total_bytes:
            raise AnalyzerError("inputs changed while reading and exceed max total bytes")
        self.total_bytes = next_total_bytes
        return (chunk, next_file_bytes)

    def _read_handle(self, handle: BinaryIO, input_index: int) -> None:
        file_bytes = 0
        while True:
            chunk, file_bytes = self._readline_with_budget(
                handle,
                self.limits.max_line_bytes + 1,
                file_bytes,
                input_index,
            )
            if not chunk:
                break
            oversize = len(chunk) > self.limits.max_line_bytes
            if oversize and not chunk.endswith(b"\n"):
                while True:
                    remainder, file_bytes = self._readline_with_budget(
                        handle,
                        64 * 1024,
                        file_bytes,
                        input_index,
                    )
                    if not remainder or remainder.endswith(b"\n"):
                        break
            self.input_counts["physical_lines"] += 1
            if self.input_counts["physical_lines"] > self.limits.max_lines:
                raise AnalyzerError("input line count exceeds max lines")
            if oversize:
                self.input_counts["oversize_lines_skipped"] += 1
                continue
            if not chunk.strip():
                self.input_counts["blank_lines"] += 1
                continue
            try:
                record = _safe_loads(chunk)
            except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError):
                self.input_counts["malformed_json_records"] += 1
                continue
            if not isinstance(record, dict):
                self.input_counts["non_object_records"] += 1
                continue
            self._consume_record(record)

    def _scope(self, record: dict[str, Any]) -> bytes | None:
        run_id = _nonblank_string(record.get("runID"))
        tab_id = _nonblank_string(record.get("tabID"))
        window_id = record.get("windowID")
        session_id = record.get("sessionID")
        session_id_valid = (
            isinstance(session_id, str) and _identifier_key(session_id) is not None
        )
        if session_id_valid:
            self.coverage_counts["session_id_present"] += 1
        else:
            self.coverage_counts["session_id_missing_or_invalid"] += 1
        if (
            run_id is None
            or tab_id is None
            or not isinstance(window_id, int)
            or isinstance(window_id, bool)
            or not session_id_valid
        ):
            self.coverage_counts["scope_invalid"] += 1
            return None
        run_key = _identifier_key(run_id)
        tab_key = _identifier_key(tab_id)
        if run_key is None or tab_key is None:
            self.coverage_counts["scope_invalid"] += 1
            return None
        self.run_bindings[run_key].add((tab_key, window_id))
        self.coverage_counts["scope_valid"] += 1
        return run_key

    def _consume_record(self, record: dict[str, Any]) -> None:
        kind = record.get("kind")
        if not isinstance(kind, str):
            self.view_counts["invalid_record_discriminators"] += 1
            return
        if kind == "protocol.inbound.raw":
            self.view_counts["raw_records_ignored"] += 1
            payload = record.get("payload")
            if isinstance(payload, dict) and payload.get("truncated") is True:
                self.view_counts["raw_truncated_records"] += 1
            return
        if kind in {"translator.streamResult", "translator.streamResultSuppressed"}:
            self.view_counts["translated_records_ignored"] += 1
            return
        if kind != "protocol.inbound.streamPayload":
            self.view_counts["other_records_ignored"] += 1
            return

        self.view_counts["canonical_decoded_records"] += 1
        payload = record.get("payload")
        if not isinstance(payload, dict):
            self.view_counts["invalid_canonical_payloads"] += 1
            return
        payload_type = payload.get("type")
        if not isinstance(payload_type, str):
            self.view_counts["invalid_payload_discriminators"] += 1
            return
        if payload_type == "stream_event" and not isinstance(payload.get("event"), dict):
            self.view_counts["invalid_canonical_nesting"] += 1
            return

        self.ordinal += 1
        run_key = self._scope(record)
        lane = _lane(payload)
        self.coverage_counts[f"lane_{lane}"] += 1
        request_state, request_key = _request_identifier(payload)
        self.coverage_counts[f"request_id_{request_state}"] += 1

        if lane == "parent" and request_state == "valid" and request_key is not None:
            self.parent_request_records.append((run_key, request_key))

        carrier = _usage_carrier(payload)
        if carrier is not None:
            source, raw_usage = carrier
            source_counts = self.source_counts[source]
            source_counts["carriers"] += 1
            if raw_usage is _MISSING:
                source_counts["missing_usage"] += 1
            elif raw_usage is _INVALID or not isinstance(raw_usage, dict):
                source_counts["invalid_usage"] += 1
                self.usage_coverage_records.append(
                    UsageCoverageRecord(
                        run_key=run_key,
                        source=source,
                        lane=lane,
                        request_state=request_state,
                        usage_state="invalid",
                    )
                )
            else:
                source_counts["usage_objects"] += 1
                fields: list[ObservedCount] = []
                for field_name, aliases in USAGE_FIELDS.items():
                    field = _observed_count(raw_usage, *aliases)
                    self.field_counts[field_name][field.state] += 1
                    if field.state == "valid" and field.value == 0:
                        self.field_counts[field_name]["zero"] += 1
                    fields.append(field)
                field_tuple = (fields[0], fields[1], fields[2], fields[3])
                self.usage_coverage_records.append(
                    UsageCoverageRecord(
                        run_key=run_key,
                        source=source,
                        lane=lane,
                        request_state=request_state,
                        usage_state="object",
                    )
                )
                if source == "result":
                    self.result_usage_counts["usage_objects"] += 1
                    triple_state, _ = _cache_triple(field_tuple)
                    self.result_usage_counts[
                        {
                            "valid": "complete_cache_triples",
                            "incomplete": "incomplete_or_invalid_cache_triples",
                            "zero_denominator": "zero_denominator_triples",
                            "overflow": "overflow_triples",
                        }[triple_state]
                    ] += 1
                elif lane == "parent" and request_state == "valid" and request_key is not None:
                    self.usage_candidates.append(
                        UsageCandidate(
                            ordinal=self.ordinal,
                            run_key=run_key,
                            request_key=request_key,
                            source=source,
                            fields=field_tuple,
                        )
                    )

        if payload_type == "result":
            self.cost_counts["result_records"] += 1
            cost_state, cost = _cost_value(payload)
            self.cost_counts[cost_state] += 1
            if cost_state == "valid" and cost is not None:
                self.cost_candidates.append(
                    CostCandidate(
                        ordinal=self.ordinal,
                        run_key=run_key,
                        identity_key=_event_identity(payload, request_state, request_key),
                        lane=lane,
                        value=cost,
                    )
                )

    def _summarize_requests(
        self,
        conflicted_runs: set[bytes],
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        valid_request_records = [
            item
            for item in self.parent_request_records
            if item[0] is not None and item[0] not in conflicted_runs
        ]
        unique_requests = set(valid_request_records)
        invalid_scope_records = len(self.parent_request_records) - len(valid_request_records)

        grouped: dict[tuple[bytes, bytes], list[UsageCandidate]] = defaultdict(list)
        usage_scope_exclusions = 0
        for candidate in self.usage_candidates:
            if candidate.run_key is None or candidate.run_key in conflicted_runs:
                usage_scope_exclusions += 1
                continue
            grouped[(candidate.run_key, candidate.request_key)].append(candidate)

        excluded_usage_reasons: Counter[str] = Counter()
        sidechain_usage_records = 0
        eligible_request_usage_records = 0
        for observation in self.usage_coverage_records:
            if observation.lane == "sidechain":
                sidechain_usage_records += 1
            elif observation.lane == "ambiguous":
                excluded_usage_reasons["ambiguous_parent_lane"] += 1
            elif observation.usage_state == "invalid":
                excluded_usage_reasons["invalid_usage_nesting"] += 1
            elif observation.source == "result":
                excluded_usage_reasons["result_turn_scope"] += 1
            elif observation.request_state != "valid":
                excluded_usage_reasons["missing_or_invalid_request_id"] += 1
            elif observation.run_key is None or observation.run_key in conflicted_runs:
                excluded_usage_reasons["ambiguous_scope"] += 1
            else:
                eligible_request_usage_records += 1
        excluded_parent_usage_records = sum(excluded_usage_reasons.values())

        duplicate_snapshots = 0
        reconciled_updates = 0
        conflicting_requests = 0
        invalid_requests = 0
        selected: dict[tuple[bytes, bytes], UsageCandidate] = {}
        ordered_groups = sorted(
            grouped.items(),
            key=lambda item: min(candidate.ordinal for candidate in item[1]),
        )
        for key, candidates in ordered_groups:
            unique_by_fingerprint: dict[tuple[Any, ...], UsageCandidate] = {}
            for candidate in sorted(candidates, key=lambda item: item.ordinal):
                if candidate.fingerprint in unique_by_fingerprint:
                    duplicate_snapshots += 1
                else:
                    unique_by_fingerprint[candidate.fingerprint] = candidate
            unique_candidates = sorted(
                unique_by_fingerprint.values(),
                key=lambda item: item.ordinal,
            )
            reconciled_updates += max(0, len(unique_candidates) - 1)
            reconciled_fields = [ObservedCount("missing") for _ in USAGE_FIELDS]
            for candidate in unique_candidates:
                reconciled_fields = [
                    _merge_observed_count(established, update)
                    for established, update in zip(reconciled_fields, candidate.fields)
                ]
            if any(field.state == "conflict" for field in reconciled_fields):
                conflicting_requests += 1
            if any(field.state == "invalid" for field in reconciled_fields):
                invalid_requests += 1
            selected[key] = UsageCandidate(
                ordinal=unique_candidates[0].ordinal,
                run_key=key[0],
                request_key=key[1],
                source="reconciled",
                fields=(
                    reconciled_fields[0],
                    reconciled_fields[1],
                    reconciled_fields[2],
                    reconciled_fields[3],
                ),
            )

        contributing_values: list[tuple[int, int, int]] = []
        incomplete = 0
        zero_denominator = 0
        per_request_overflow = 0
        for key in sorted(unique_requests):
            candidate = selected.get(key)
            if candidate is None:
                continue
            triple_state, values = _cache_triple(candidate.fields)
            if triple_state == "incomplete":
                incomplete += 1
            elif triple_state == "zero_denominator":
                zero_denominator += 1
            elif triple_state == "overflow":
                per_request_overflow += 1
            elif values is not None:
                contributing_values.append(values)

        contributing = len(contributing_values)
        exact_totals = {
            field_name: sum(values[index] for values in contributing_values)
            for index, field_name in enumerate(CACHE_FIELDS)
        }
        exact_denominator = sum(exact_totals.values())
        aggregate_overflow = (
            exact_denominator > MAX_COUNT
            or any(value > MAX_COUNT for value in exact_totals.values())
        )

        requests_without_snapshot = len(unique_requests - set(grouped))
        requests_without_selected_snapshot = len(unique_requests) - len(
            set(selected).intersection(unique_requests)
        )
        excluded_requests = len(unique_requests) - contributing

        denominator_total: int | None = None
        percentage: str | None = None
        reported_totals: dict[str, int | None]
        if not aggregate_overflow and contributing > 0:
            denominator_total = exact_denominator
            percentage = _percent_text(
                exact_totals["cache_read_input_tokens"],
                denominator_total,
            )
            reported_totals = dict(exact_totals)
        else:
            reported_totals = {name: None for name in CACHE_FIELDS}

        if contributing == 0 or aggregate_overflow:
            cache_status = "unavailable"
        elif excluded_requests == 0 and excluded_parent_usage_records == 0:
            cache_status = "complete"
        else:
            cache_status = "partial"

        request_summary = {
            "unique_observed_parent_request_ids": len(unique_requests),
            "billed_request_count": None,
            "valid_parent_request_id_records": len(valid_request_records),
            "ambiguous_scope_request_records": invalid_scope_records,
            "usage_snapshot_records": len(self.usage_candidates),
            "turn_level_result_usage_snapshot_records": self.result_usage_counts[
                "usage_objects"
            ],
            "duplicate_snapshot_records": duplicate_snapshots,
            "reconciled_update_records": reconciled_updates,
            "conflicting_request_field_sets": conflicting_requests,
            "invalid_request_field_sets": invalid_requests,
            "requests_without_usage_snapshot": requests_without_snapshot,
            "requests_without_selected_snapshot": requests_without_selected_snapshot,
            "count_scope": "observed_parent_lane_ids_by_valid_log_run_not_billing_or_live_ownership",
        }
        cache_summary = {
            "status": cache_status,
            "formula": "cache_read/(input+cache_read+cache_creation)",
            "selected_request_snapshots": len(selected),
            "contributing_requests": contributing,
            "excluded_requests": excluded_requests,
            "incomplete_triple_requests": incomplete,
            "zero_denominator_requests": zero_denominator,
            "per_request_overflow_requests": per_request_overflow,
            "aggregate_overflow": aggregate_overflow,
            "scope_excluded_snapshot_records": usage_scope_exclusions,
            "excluded_parent_usage_records": excluded_parent_usage_records,
            "excluded_parent_usage_reasons": {
                "ambiguous_parent_lane": excluded_usage_reasons[
                    "ambiguous_parent_lane"
                ],
                "invalid_usage_nesting": excluded_usage_reasons[
                    "invalid_usage_nesting"
                ],
                "result_turn_scope": excluded_usage_reasons["result_turn_scope"],
                "missing_or_invalid_request_id": excluded_usage_reasons[
                    "missing_or_invalid_request_id"
                ],
                "ambiguous_scope": excluded_usage_reasons["ambiguous_scope"],
            },
            "sidechain_usage_records_excluded": sidechain_usage_records,
            "eligible_request_usage_records": eligible_request_usage_records,
            "coverage_partial_due_to_excluded_parent_usage": (
                excluded_parent_usage_records > 0
            ),
            "totals": {
                **reported_totals,
                "denominator_tokens": denominator_total,
            },
            "weighted_cache_hit_percent": percentage,
            "missing_is_zero": False,
            "post_wait_correlation": "unknown",
        }
        return request_summary, cache_summary

    def _summarize_cost(self, conflicted_runs: set[bytes]) -> dict[str, Any]:
        grouped: dict[tuple[bytes, tuple[str, bytes]], list[CostCandidate]] = defaultdict(list)
        excluded = Counter()
        for candidate in self.cost_candidates:
            if candidate.lane == "sidechain":
                excluded["sidechain"] += 1
                continue
            if candidate.lane == "ambiguous":
                excluded["ambiguous_parent"] += 1
                continue
            if candidate.run_key is None or candidate.run_key in conflicted_runs:
                excluded["ambiguous_scope"] += 1
                continue
            if candidate.identity_key is None:
                excluded["unidentified"] += 1
                continue
            grouped[(candidate.run_key, candidate.identity_key)].append(candidate)

        duplicates = 0
        conflicts = 0
        accepted: list[CostCandidate] = []
        for candidates in grouped.values():
            values = {candidate.value for candidate in candidates}
            if len(values) != 1:
                conflicts += 1
                continue
            duplicates += len(candidates) - 1
            accepted.append(min(candidates, key=lambda item: item.ordinal))

        by_scope: dict[bytes, list[CostCandidate]] = defaultdict(list)
        for candidate in accepted:
            assert candidate.run_key is not None
            by_scope[candidate.run_key].append(candidate)
        ordered_scopes = sorted(
            by_scope.values(),
            key=lambda items: min(item.ordinal for item in items),
        )
        series = []
        for scope_index, items in enumerate(ordered_scopes, start=1):
            ordered = sorted(items, key=lambda item: item.ordinal)
            series.append(
                {
                    "scope_index": scope_index,
                    "checkpoint_count": len(ordered),
                    "cumulative_values_usd": [
                        _decimal_text(item.value) for item in ordered
                    ],
                }
            )

        return {
            "basis": "claude_provider_reported_cumulative_estimate",
            "result_records": self.cost_counts["result_records"],
            "valid_numeric_records": self.cost_counts["valid"],
            "missing_records": self.cost_counts["missing"],
            "invalid_records": self.cost_counts["invalid"],
            "identified_checkpoint_count": len(accepted),
            "duplicate_identity_records": duplicates,
            "conflicting_identity_groups": conflicts,
            "excluded_valid_records": {
                "sidechain": excluded["sidechain"],
                "ambiguous_parent": excluded["ambiguous_parent"],
                "ambiguous_scope": excluded["ambiguous_scope"],
                "unidentified": excluded["unidentified"],
            },
            "series": series,
            "aggregate_usd": None,
            "delta_usd": None,
            "capture_order_establishes_live_ownership": False,
            "reset_inferred_from_decrease": False,
            "native_child_cost_summed_separately": False,
            "savings_claim": False,
        }


def analyze_paths(paths: Sequence[Path | str], limits: Limits | None = None) -> dict[str, Any]:
    """Analyze explicit JSONL files and return a privacy-safe aggregate summary."""
    normalized = [Path(path) for path in paths]
    return _Analyzer(limits or Limits()).analyze_paths(normalized)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Offline, privacy-safe aggregate analysis of existing Claude raw-event JSONL. "
            "Only canonical protocol.inbound.streamPayload records contribute observations."
        )
    )
    parser.add_argument("inputs", nargs="+", help="explicit JSONL file(s); directories are not scanned")
    parser.add_argument(
        "--max-file-bytes",
        type=int,
        default=DEFAULT_MAX_FILE_BYTES,
        help=f"per-file byte limit (default: {DEFAULT_MAX_FILE_BYTES})",
    )
    parser.add_argument(
        "--max-total-bytes",
        type=int,
        default=DEFAULT_MAX_TOTAL_BYTES,
        help=f"combined byte limit (default: {DEFAULT_MAX_TOTAL_BYTES})",
    )
    parser.add_argument(
        "--max-line-bytes",
        type=int,
        default=DEFAULT_MAX_LINE_BYTES,
        help=f"per-JSONL-record byte limit; larger records are skipped (default: {DEFAULT_MAX_LINE_BYTES})",
    )
    parser.add_argument(
        "--max-lines",
        type=int,
        default=DEFAULT_MAX_LINES,
        help=f"combined physical-line limit (default: {DEFAULT_MAX_LINES})",
    )
    parser.add_argument("--compact", action="store_true", help="emit compact JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    limits = Limits(
        max_file_bytes=args.max_file_bytes,
        max_total_bytes=args.max_total_bytes,
        max_line_bytes=args.max_line_bytes,
        max_lines=args.max_lines,
    )
    try:
        summary = analyze_paths(args.inputs, limits)
        rendered = json.dumps(
            summary,
            indent=None if args.compact else 2,
            sort_keys=True,
            separators=(",", ":") if args.compact else None,
        )
        sys.stdout.write(rendered + "\n")
    except AnalyzerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except Exception:
        print("error: unexpected failure", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
