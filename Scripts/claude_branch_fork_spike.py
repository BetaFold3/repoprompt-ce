#!/usr/bin/env python3
"""Opt-in, isolated Claude CLI native-branching diagnostic.

The root XCTest suite is the public entry point. This helper refuses to resolve or
spawn Claude unless RPCE_CLAUDE_BRANCH_SPIKE is exactly "1".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


GATE = "RPCE_CLAUDE_BRANCH_SPIKE"
INITIALIZE_REQUEST_ID = "rp-claude-1"
INITIALIZE_FRAME = b'{"type":"control_request","request_id":"rp-claude-1","request":{"subtype":"initialize"}}\n'
OUTPUT_LIMIT = 256 * 1024
ERROR_EXCERPT_LIMIT = 512
PROCESS_TIMEOUT = 8.0
STABILITY_WINDOW = 0.25
EOF_GRACE = 0.35
TERM_GRACE = 0.75
KILL_GRACE = 0.75
MAX_PROTOCOL_LINE = 1024 * 1024
REDACTED = "<redacted>"
SENSITIVE_KEY_PARTS = (
    "API_KEY", "AUTH", "BEARER", "CREDENTIAL", "PASSWORD", "SECRET", "TOKEN",
)


def gate_enabled(environment: dict[str, str] | None = None) -> bool:
    return (environment or os.environ).get(GATE) == "1"


def redact(text: str, roots: Iterable[Path] = ()) -> str:
    value = text
    for root in sorted({str(path) for path in roots if str(path)}, key=len, reverse=True):
        value = value.replace(root, "<isolated-root>")
    home = os.environ.get("HOME")
    if home:
        value = value.replace(home, "<home>")
    value = re.sub(r"(?i)(Authorization\s*:\s*Bearer\s+)[^\s,;]+", r"\1" + REDACTED, value)
    value = re.sub(
        r'(?i)(["\']?(?:api[_-]?key|authorization|bearer|password|secret|token)["\']?\s*[:=]\s*)'
        r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[^\s,;]+)',
        lambda match: match.group(1) + ('"' + REDACTED + '"' if match.group(2).startswith('"') else REDACTED),
        value,
    )
    value = re.sub(
        r"(?:/Users|/home|/private/var/folders|/var/folders|/private/tmp|/tmp)/[^\s`\"']+",
        "<machine-path>",
        value,
    )
    value = re.sub(
        r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b",
        "<uuid>",
        value,
    )
    value = re.sub(r"sk-[A-Za-z0-9_-]{8,}", REDACTED, value)
    return value


def digest_json(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()[:12]


@dataclass(frozen=True)
class ParsedJSONL:
    entries: list[dict[str, Any]]
    integrity: dict[str, Any]


def parse_jsonl_bytes_with_integrity(contents: bytes) -> ParsedJSONL:
    entries: list[dict[str, Any]] = []
    malformed_line_count = 0
    oversized_line_count = 0
    non_object_line_count = 0
    lines = contents.splitlines()
    for raw in lines:
        if len(raw) > 1024 * 1024:
            oversized_line_count += 1
            continue
        try:
            value = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            malformed_line_count += 1
            continue
        if isinstance(value, dict):
            entries.append(value)
        else:
            non_object_line_count += 1
    complete_tail = not contents or contents.endswith(b"\n")
    integrity = {
        "file_present": True,
        "complete_tail": complete_tail,
        "line_count": len(lines),
        "valid_entry_count": len(entries),
        "malformed_line_count": malformed_line_count,
        "oversized_line_count": oversized_line_count,
        "non_object_line_count": non_object_line_count,
        "read_error": None,
    }
    integrity["valid"] = bool(
        complete_tail
        and malformed_line_count == 0
        and oversized_line_count == 0
        and non_object_line_count == 0
    )
    return ParsedJSONL(entries, integrity)


def parse_jsonl_bytes(contents: bytes) -> list[dict[str, Any]]:
    return parse_jsonl_bytes_with_integrity(contents).entries


def parse_jsonl_with_integrity(path: Path | None) -> ParsedJSONL:
    if path is None or not path.exists():
        return ParsedJSONL([], {
            "file_present": False,
            "complete_tail": False,
            "line_count": 0,
            "valid_entry_count": 0,
            "malformed_line_count": 0,
            "oversized_line_count": 0,
            "non_object_line_count": 0,
            "read_error": None,
            "valid": False,
        })
    try:
        return parse_jsonl_bytes_with_integrity(path.read_bytes())
    except OSError as error:
        return ParsedJSONL([], {
            "file_present": True,
            "complete_tail": False,
            "line_count": 0,
            "valid_entry_count": 0,
            "malformed_line_count": 0,
            "oversized_line_count": 0,
            "non_object_line_count": 0,
            "read_error": type(error).__name__,
            "valid": False,
        })


def parse_jsonl(path: Path) -> list[dict[str, Any]]:
    return parse_jsonl_with_integrity(path).entries


def summarize_entries(entries: list[dict[str, Any]]) -> dict[str, Any]:
    types: dict[str, int] = {}
    session_ids: set[str] = set()
    main_uuids: list[str] = []
    sidechain_count = 0
    user_roles: list[str] = []
    for entry in entries:
        kind = str(entry.get("type", "unknown"))
        types[kind] = types.get(kind, 0) + 1
        session_id = entry.get("sessionId") or entry.get("session_id")
        if isinstance(session_id, str):
            session_ids.add(session_id)
        if entry.get("isSidechain") is True or entry.get("parent_tool_use_id") is not None:
            sidechain_count += 1
        elif isinstance(entry.get("uuid"), str):
            main_uuids.append(entry["uuid"])
        message = entry.get("message")
        if isinstance(message, dict) and isinstance(message.get("role"), str):
            user_roles.append(message["role"])
    return {
        "entry_count": len(entries),
        "types": dict(sorted(types.items())),
        "session_id_count": len(session_ids),
        "main_uuid_count": len(main_uuids),
        "sidechain_count": sidechain_count,
        "roles": user_roles,
    }


def safe_environment(home: Path, config: Path) -> dict[str, str]:
    kept = {"PATH", "SHELL", "LANG", "LC_ALL", "TMPDIR", "TERM"}
    environment = {key: value for key, value in os.environ.items() if key in kept}
    for key in list(environment):
        if any(part in key.upper() for part in SENSITIVE_KEY_PARTS):
            environment.pop(key, None)
    environment.update({
        "HOME": str(home),
        "CLAUDE_CONFIG_DIR": str(config),
        "HTTP_PROXY": "http://127.0.0.1:9",
        "HTTPS_PROXY": "http://127.0.0.1:9",
        "ALL_PROXY": "http://127.0.0.1:9",
        "NO_PROXY": "",
        "DISABLE_TELEMETRY": "1",
    })
    return environment


class StoreDiscoveryError(RuntimeError):
    pass


def _entry_cwd_matches(path: Path, cwd: Path) -> bool:
    expected = cwd.resolve()
    for entry in parse_jsonl(path):
        entry_cwd = entry.get("cwd")
        if isinstance(entry_cwd, str):
            try:
                return Path(entry_cwd).resolve() == expected
            except OSError:
                return False
    return False


def find_store_path(config: Path, cwd: Path, session_id: str) -> tuple[Path | None, str]:
    matches = []
    try:
        candidates = config.rglob(f"{session_id}.jsonl")
        for candidate in candidates:
            try:
                resolved = candidate.resolve(strict=True)
            except OSError:
                continue
            if _entry_cwd_matches(resolved, cwd):
                matches.append(resolved)
    except OSError:
        return None, "store-scan-failed"
    unique = sorted(set(matches))
    if len(unique) == 1:
        return unique[0], "found"
    if len(unique) > 1:
        return None, "ambiguous-store-path"
    any_named = list(config.rglob(f"{session_id}.jsonl"))
    return None, "cwd-encoding-mismatch" if any_named else "session-store-absent"


def project_dir(config: Path, cwd: Path) -> Path:
    candidates: set[Path] = set()
    if config.exists():
        for path in config.rglob("*.jsonl"):
            try:
                resolved = path.resolve(strict=True)
            except OSError:
                continue
            if _entry_cwd_matches(resolved, cwd):
                candidates.add(resolved.parent)
    if len(candidates) != 1:
        reason = "source-store-undiscoverable" if not candidates else "source-store-ambiguous"
        raise StoreDiscoveryError(reason)
    return candidates.pop()


def store_path(config: Path, cwd: Path, session_id: str) -> Path:
    found, _ = find_store_path(config, cwd, session_id)
    return found if found is not None else project_dir(config, cwd) / f"{session_id}.jsonl"


def _child_candidate_metadata(candidate: Path) -> tuple[Path, int]:
    try:
        resolved = candidate.resolve(strict=True)
        return resolved, resolved.stat().st_size
    except OSError:
        return candidate.absolute(), candidate.lstat().st_size


def discover_child_store(config: Path, cwd: Path, session_id: str,
                         expected_path: Path) -> tuple[Path | None, dict[str, Any]]:
    target_name = f"{session_id}.jsonl"
    traversal_error_count = 0
    enumerated: list[Path] = []

    def record_traversal_error(_error: OSError) -> None:
        nonlocal traversal_error_count
        traversal_error_count += 1

    try:
        for directory, _, filenames in os.walk(
            config, topdown=True, onerror=record_traversal_error, followlinks=False
        ):
            if target_name in filenames:
                enumerated.append(Path(directory) / target_name)
    except OSError:
        traversal_error_count += 1

    named: dict[str, tuple[Path, int]] = {}
    unresolved_metadata_count = 0
    for candidate in enumerated:
        try:
            resolved, size = _child_candidate_metadata(candidate)
        except OSError:
            unresolved_metadata_count += 1
            continue
        named[str(resolved)] = (resolved, size)

    physical = sorted(named.values(), key=lambda item: str(item[0]))
    byte_sizes = [size for _, size in physical]
    qualified = [
        path for path, _ in physical
        if _entry_cwd_matches(path, cwd)
    ]
    scan_complete = traversal_error_count == 0 and unresolved_metadata_count == 0
    evidence = {
        "physical_presence_established": bool(enumerated) or scan_complete,
        "physical_absence_established": scan_complete and not enumerated,
        "scan_complete": scan_complete,
        "enumerated_candidate_count": len(enumerated),
        "exact_name_candidate_count": len(enumerated),
        "exact_name_candidate_byte_sizes": byte_sizes,
        "resolved_candidate_count": len(physical),
        "unresolved_metadata_count": unresolved_metadata_count,
        "traversal_error_count": traversal_error_count,
        "cwd_qualified_candidate_count": len(qualified),
    }
    if not scan_complete:
        return None, {"classification": "incomplete-scan", **evidence}
    if not physical:
        return None, {"classification": "absent", **evidence}
    if len(physical) > 1:
        return None, {"classification": "ambiguous", **evidence}
    if len(qualified) != 1:
        return None, {"classification": "cwd-mismatch", **evidence}

    child = qualified[0]
    try:
        found_expected = child == expected_path.resolve()
    except OSError:
        found_expected = False
    return child, {
        "classification": "found-expected" if found_expected else "found-elsewhere",
        **evidence,
    }


def child_candidate_presence(evidence: dict[str, Any]) -> bool | None:
    candidate_count = evidence["exact_name_candidate_count"]
    if isinstance(candidate_count, int) and candidate_count > 0:
        return True
    if evidence["scan_complete"] is True and candidate_count == 0:
        return False
    return None


def child_candidate_bytes(evidence: dict[str, Any]) -> int | None:
    sizes = evidence["exact_name_candidate_byte_sizes"]
    candidate_count = evidence["exact_name_candidate_count"]
    if (
        evidence["scan_complete"] is True
        and isinstance(sizes, list)
        and len(sizes) == candidate_count
    ):
        return sum(sizes)
    return None


def child_absence_established(evidence: dict[str, Any]) -> bool:
    return child_candidate_presence(evidence) is False


def missing_session_status(recognized: bool, timed_out: bool,
                           discovery: dict[str, Any]) -> str:
    return (
        "supported"
        if recognized and not timed_out and child_absence_established(discovery)
        else "inconclusive"
    )


def child_store_durable(path: Path | None) -> bool:
    if path is None:
        return False
    try:
        return path.stat().st_size > 0
    except OSError:
        return False


def fixture_entry(session_id: str, cwd: Path, entry_uuid: str, parent_uuid: str | None,
                  role: str, content: Any, *, sidechain: bool = False,
                  entry_type: str | None = None) -> dict[str, Any]:
    return {
        "parentUuid": parent_uuid,
        "isSidechain": sidechain,
        "userType": "external",
        "cwd": str(cwd),
        "sessionId": session_id,
        "version": "2.1.258",
        "gitBranch": "",
        "type": entry_type or role,
        "message": {"role": role, "content": content},
        "uuid": entry_uuid,
        "timestamp": "2026-01-01T00:00:00.000Z",
    }


def make_fixture(config: Path, cwd: Path, session_id: str, *, compact: bool = False,
                 sidechain: bool = False, directory: Path | None = None) -> tuple[Path, list[str]]:
    ids = [str(uuid.uuid4()) for _ in range(6)]
    entries: list[dict[str, Any]] = []
    parent: str | None = None
    for index in range(3):
        prompt_id, answer_id = ids[index * 2:index * 2 + 2]
        entries.append(fixture_entry(session_id, cwd, prompt_id, parent, "user", f"fixture-prompt-{index + 1}"))
        entries.append(fixture_entry(
            session_id, cwd, answer_id, prompt_id, "assistant",
            [{"type": "text", "text": f"fixture-answer-{index + 1}"}],
        ))
        parent = answer_id
        if compact and index == 0:
            boundary_id = str(uuid.uuid4())
            entries.append(fixture_entry(
                session_id, cwd, boundary_id, parent, "system", "compact-boundary",
                entry_type="system",
            ) | {"subtype": "compact_boundary"})
            parent = boundary_id
        if sidechain and index == 1:
            reminder_id = str(uuid.uuid4())
            entries.append(fixture_entry(
                session_id, cwd, reminder_id, parent, "user", "fixture-system-reminder",
            ) | {"isMeta": True})
            parent = reminder_id
    if sidechain:
        side_id = str(uuid.uuid4())
        entries.append(fixture_entry(
            session_id, cwd, side_id, ids[3], "assistant",
            [{"type": "tool_use", "name": "Task", "input": {}}], sidechain=True,
        ) | {"parent_tool_use_id": str(uuid.uuid4())})
    path = (directory / f"{session_id}.jsonl") if directory is not None else store_path(config, cwd, session_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(entry, separators=(",", ":")) + "\n" for entry in entries), encoding="utf-8")
    return path, ids


@dataclass
class ProcessObservation:
    status: int | None
    timed_out: bool
    output: bytes
    output_truncated: bool
    watched_file_seen: bool
    watched_file_stable: bool
    killed_intentionally: bool
    handshake_sent: bool
    prompt_sent: bool
    requested_id_system_init_match: bool | None
    initialize_control_response_match: bool
    successful_result_seen: bool
    argv: tuple[str, ...]
    environment: dict[str, str]
    stdin_write_error: str | None
    cwd: str


def run_owned(executable: Path, arguments: list[str], environment: dict[str, str], cwd: Path,
              *, stdin_lines: tuple[bytes, ...] = (), prompt_sent: bool = False,
              requested_session_id: str | None = None, watch_path: Path | None = None,
              timeout: float = PROCESS_TIMEOUT,
              kill_after_control_response: bool = False) -> ProcessObservation:
    argv = (str(executable), *arguments)
    process = subprocess.Popen(
        argv, cwd=cwd, env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    captured = bytearray()
    truncated = False
    init_session_ids: set[str] = set()
    initialize_control_response_match = False
    successful_result_seen = False
    stdin_write_error: str | None = None
    line_buffer = bytearray()

    def observe_protocol_line(raw_line: bytes) -> None:
        nonlocal initialize_control_response_match, successful_result_seen
        try:
            value = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return
        if not isinstance(value, dict):
            return
        if (
            value.get("type") == "system"
            and value.get("subtype") == "init"
            and isinstance(value.get("session_id"), str)
        ):
            init_session_ids.add(value["session_id"])
        if value.get("type") == "control_response":
            response = value.get("response")
            if (
                isinstance(response, dict)
                and response.get("request_id") == INITIALIZE_REQUEST_ID
                and response.get("subtype") == "success"
            ):
                initialize_control_response_match = True
        if value.get("type") == "result" and value.get("is_error") is not True:
            successful_result_seen = True

    def drain() -> None:
        nonlocal truncated
        assert process.stdout is not None
        while True:
            try:
                chunk = os.read(process.stdout.fileno(), 65536)
            except OSError:
                return
            if not chunk:
                if line_buffer:
                    observe_protocol_line(bytes(line_buffer))
                return
            remaining = OUTPUT_LIMIT - len(captured)
            if remaining > 0:
                captured.extend(chunk[:remaining])
            if len(chunk) > remaining:
                truncated = True
            line_buffer.extend(chunk)
            while True:
                newline = line_buffer.find(b"\n")
                if newline < 0:
                    if len(line_buffer) > MAX_PROTOCOL_LINE:
                        line_buffer.clear()
                    break
                observe_protocol_line(bytes(line_buffer[:newline]))
                del line_buffer[:newline + 1]

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    handshake_sent = False

    def close_stdin() -> None:
        if process.stdin is None:
            return
        try:
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        process.stdin = None

    def signal_group(signum: int) -> None:
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    def group_exists() -> bool:
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    old_handlers: dict[int, Any] = {}
    cancellation_signum: int | None = None

    def forward_signal(signum: int, _frame: Any) -> None:
        nonlocal cancellation_signum
        cancellation_signum = cancellation_signum or signum
        signal_group(signum)

    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            old_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, forward_signal)

    started = time.monotonic()
    last_signature: tuple[int, int] | None = None
    stable_since: float | None = None
    seen = False
    stable = False
    killed = False
    timed_out = False
    try:
        if process.stdin is not None:
            for index, stdin_line in enumerate(stdin_lines):
                try:
                    process.stdin.write(stdin_line)
                    if not stdin_line.endswith(b"\n"):
                        process.stdin.write(b"\n")
                    process.stdin.flush()
                    if index == 0 and stdin_line == INITIALIZE_FRAME:
                        handshake_sent = True
                except (BrokenPipeError, OSError) as error:
                    stdin_write_error = type(error).__name__
                    close_stdin()
                    break
        if not stdin_lines:
            close_stdin()

        while process.poll() is None:
            if cancellation_signum is not None:
                break
            now = time.monotonic()
            if watch_path is not None and watch_path.exists():
                try:
                    stat = watch_path.stat()
                except OSError:
                    stat = None
                if stat is not None:
                    seen = True
                    signature = (stat.st_size, stat.st_mtime_ns)
                    if signature == last_signature and stat.st_size > 0:
                        stable_since = stable_since or now
                        stable = now - stable_since >= STABILITY_WINDOW
                    else:
                        last_signature = signature
                        stable_since = now
            if kill_after_control_response and initialize_control_response_match:
                close_stdin()
                signal_group(signal.SIGKILL)
                killed = True
                break
            if now - started >= timeout:
                timed_out = not successful_result_seen
                close_stdin()
                try:
                    process.wait(timeout=EOF_GRACE)
                except subprocess.TimeoutExpired:
                    signal_group(signal.SIGTERM)
                break
            if stable or init_session_ids or successful_result_seen:
                close_stdin()
            time.sleep(0.025)
    finally:
        close_stdin()
        if process.poll() is None:
            try:
                process.wait(timeout=EOF_GRACE)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGTERM)
        if process.poll() is None:
            try:
                process.wait(timeout=TERM_GRACE)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGKILL)
        if process.poll() is None:
            try:
                process.wait(timeout=KILL_GRACE)
            except subprocess.TimeoutExpired:
                pass
        try:
            process.wait(timeout=KILL_GRACE)
        except subprocess.TimeoutExpired:
            signal_group(signal.SIGKILL)
            process.wait(timeout=KILL_GRACE)
        # The leader may exit while descendants still own stdout or other resources.
        signal_group(signal.SIGTERM)
        descendant_deadline = time.monotonic() + TERM_GRACE
        while group_exists() and time.monotonic() < descendant_deadline:
            time.sleep(0.025)
        if group_exists():
            signal_group(signal.SIGKILL)
        for signum, old_handler in old_handlers.items():
            signal.signal(signum, old_handler)
        reader.join(timeout=1.0)
        if process.stdout is not None:
            try:
                process.stdout.close()
            except OSError:
                pass
    if cancellation_signum is not None:
        raise InterruptedError(f"received signal {cancellation_signum}")
    if watch_path is not None and watch_path.exists() and watch_path.stat().st_size > 0 and not stable:
        seen = True
        first = (watch_path.stat().st_size, watch_path.stat().st_mtime_ns)
        time.sleep(STABILITY_WINDOW)
        stable = watch_path.exists() and (watch_path.stat().st_size, watch_path.stat().st_mtime_ns) == first
    requested_id_match = (
        requested_session_id in init_session_ids if requested_session_id is not None and init_session_ids else None
    )
    return ProcessObservation(
        status=process.returncode,
        timed_out=timed_out,
        output=bytes(captured),
        output_truncated=truncated,
        watched_file_seen=seen,
        watched_file_stable=stable,
        killed_intentionally=killed,
        handshake_sent=handshake_sent,
        prompt_sent=prompt_sent,
        requested_id_system_init_match=requested_id_match,
        initialize_control_response_match=initialize_control_response_match,
        successful_result_seen=successful_result_seen,
        argv=argv,
        environment=dict(environment),
        stdin_write_error=stdin_write_error,
        cwd=str(cwd.resolve()),
    )


def base_args(empty_mcp: Path) -> list[str]:
    return [
        "-p", "--verbose", "--output-format", "stream-json",
        "--input-format", "stream-json", "--permission-prompt-tool", "stdio",
        "--mcp-config", str(empty_mcp), "--strict-mcp-config",
    ]


def fork_args(empty_mcp: Path, source_id: str, child_id: str, anchor: str) -> list[str]:
    return base_args(empty_mcp) + [
        "--resume", source_id, "--fork-session", "--session-id", child_id,
        "--resume-session-at", anchor,
    ]


def protocol_evidence(observation: ProcessObservation) -> dict[str, Any]:
    return {
        "handshake_sent": observation.handshake_sent,
        "prompt_sent": observation.prompt_sent,
        "requested_id_system_init_match": observation.requested_id_system_init_match,
        "initialize_control_response_match": observation.initialize_control_response_match,
    }


def error_evidence(observation: ProcessObservation, roots: Iterable[Path] = ()) -> dict[str, Any]:
    text = observation.output.decode("utf-8", errors="replace")
    non_json_lines: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError:
            non_json_lines.append(line)

    lowered = "\n".join(non_json_lines).lower()
    if "requires --resume" in lowered:
        classification = "requires-resume"
    elif "unknown option" in lowered or "unknown argument" in lowered:
        classification = "unknown-option"
    elif "no conversation found with session id" in lowered or (
        "session" in lowered
        and any(word in lowered for word in ("missing", "not found", "does not exist", "unknown"))
    ):
        classification = "missing-session"
    elif non_json_lines:
        classification = "other-error"
    else:
        classification = "no-non-json-error"

    if observation.timed_out:
        exit_classification = "timed-out"
    elif observation.status is None:
        exit_classification = "no-exit-status"
    elif observation.status == 0:
        exit_classification = "exited-zero"
    elif observation.status < 0:
        exit_classification = "signal"
    else:
        exit_classification = "exited-nonzero"

    redacted_excerpt = redact("\n".join(non_json_lines), roots)
    excerpt_truncated = len(redacted_excerpt) > ERROR_EXCERPT_LIMIT
    return {
        "exit_classification": exit_classification,
        "error_classification": classification,
        "non_json_error_line_count": len(non_json_lines),
        "non_json_error_excerpt": redacted_excerpt[:ERROR_EXCERPT_LIMIT],
        "non_json_error_excerpt_truncated": excerpt_truncated,
    }


def classify_output(observation: ProcessObservation) -> dict[str, Any]:
    text = observation.output.decode("utf-8", errors="replace")
    event_types: dict[str, int] = {}
    init_ids: list[str] = []
    stream_uuids: list[str] = []
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        kind = str(value.get("type", "unknown"))
        event_types[kind] = event_types.get(kind, 0) + 1
        if kind == "system" and value.get("subtype") == "init" and isinstance(value.get("session_id"), str):
            init_ids.append(value["session_id"])
        if isinstance(value.get("uuid"), str):
            stream_uuids.append(value["uuid"])
    lowered = text.lower()
    return {
        "exit_status": observation.status,
        "timed_out": observation.timed_out,
        "successful_result_seen": observation.successful_result_seen,
        **protocol_evidence(observation),
        "output_bytes": len(observation.output),
        "output_truncated": observation.output_truncated,
        "output_sha256": hashlib.sha256(observation.output).hexdigest()[:12],
        "event_types": dict(sorted(event_types.items())),
        "init_session_count": len(init_ids),
        "requested_id_system_init_match": observation.requested_id_system_init_match,
        "stdin_write_error": observation.stdin_write_error,
        "stream_uuid_count": len(stream_uuids),
        "mentions_resume_requirement": "requires --resume" in lowered,
        "mentions_missing_session": "session" in lowered and any(word in lowered for word in ("missing", "not found", "does not exist")),
    }


def structural_entries(entries: list[dict[str, Any]]) -> list[tuple[str, bool, str, str]]:
    result = []
    for entry in entries:
        message = entry.get("message")
        result.append((
            str(entry.get("type", "unknown")),
            bool(entry.get("isSidechain", False)),
            str(entry.get("uuid", "")),
            digest_json(message),
        ))
    return result


def stream_uuid_observation(output: bytes, target_uuid: str) -> dict[str, Any]:
    user_event_count = 0
    target_uuid_echoed = False
    for line in output.decode("utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("type") == "user":
            user_event_count += 1
            target_uuid_echoed = target_uuid_echoed or value.get("uuid") == target_uuid
    return {
        "user_event_count": user_event_count,
        "target_uuid_echoed": target_uuid_echoed if user_event_count else None,
    }


def main_chain(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        entry for entry in entries
        if entry.get("isSidechain") is not True and entry.get("parent_tool_use_id") is None
    ]


def chain_evidence(source: ParsedJSONL, child: ParsedJSONL, anchor: str) -> dict[str, Any]:
    source_chain = main_chain(source.entries)
    anchor_index = next((index for index, entry in enumerate(source_chain) if entry.get("uuid") == anchor), None)
    expected = source_chain[:anchor_index + 1] if anchor_index is not None else []
    actual = main_chain(child.entries)

    def shape(entry: dict[str, Any]) -> tuple[str, str, bool, str, str]:
        message = entry.get("message")
        role = str(message.get("role", "")) if isinstance(message, dict) else ""
        return (
            str(entry.get("type", "unknown")),
            str(entry.get("subtype", "")),
            bool(entry.get("isMeta", False)),
            role,
            digest_json(message),
        )

    def linked_shape(chain: list[dict[str, Any]]) -> tuple[list[tuple[Any, ...]], bool]:
        positions = {
            entry["uuid"]: index for index, entry in enumerate(chain)
            if isinstance(entry.get("uuid"), str)
        }
        linked: list[tuple[Any, ...]] = []
        references_valid = True
        for entry in chain:
            parent = entry.get("parentUuid")
            if parent is None:
                parent_link: tuple[str, int | None] = ("root", None)
            elif isinstance(parent, str) and parent in positions:
                parent_link = ("position", positions[parent])
            else:
                parent_link = ("dangling", None)
                references_valid = False
            linked.append((*shape(entry), parent_link))
        return linked, references_valid

    expected_shape, source_parent_references_valid = linked_shape(expected)
    actual_shape, child_parent_references_valid = linked_shape(actual)
    expected_uuids = [entry.get("uuid") for entry in expected]
    actual_uuids = [entry.get("uuid") for entry in actual]
    parse_integrity_valid = bool(source.integrity["valid"] and child.integrity["valid"])
    parent_references_valid = source_parent_references_valid and child_parent_references_valid
    structurally_equal = bool(
        parse_integrity_valid
        and parent_references_valid
        and expected_shape == actual_shape
    )
    return {
        "anchor_found": anchor_index is not None,
        "source_subchain_count": len(expected),
        "child_main_chain_count": len(actual),
        "exact_entry_count": len(expected) == len(actual),
        "no_extra_main_chain_entries": len(actual) == len(expected),
        "source_parse_integrity": source.integrity,
        "child_parse_integrity": child.integrity,
        "source_parent_references_valid": source_parent_references_valid,
        "child_parent_references_valid": child_parent_references_valid,
        "parent_linkage_equal": (
            parent_references_valid
            and [item[-1] for item in expected_shape] == [item[-1] for item in actual_shape]
        ),
        "structural_equality_ignoring_uuid": structurally_equal,
        "uuid_chain_equality": parse_integrity_valid and expected_uuids == actual_uuids,
        "source_structure_sha256": digest_json(expected_shape),
        "child_structure_sha256": digest_json(actual_shape),
    }


def ancestor_uuid_set(entries: list[dict[str, Any]], anchor: str) -> set[str]:
    by_uuid = {
        entry["uuid"]: entry for entry in entries
        if isinstance(entry.get("uuid"), str)
    }
    ancestry: set[str] = set()
    current: str | None = anchor
    while current is not None and current not in ancestry:
        entry = by_uuid.get(current)
        if entry is None:
            break
        ancestry.add(current)
        parent = entry.get("parentUuid")
        current = parent if isinstance(parent, str) else None
    return ancestry


def history_shape_counts(entries: list[dict[str, Any]]) -> dict[str, int]:
    sidechains = [entry for entry in entries if entry.get("isSidechain") is True or entry.get("parent_tool_use_id") is not None]
    main = main_chain(entries)

    def contains_task_tool(entry: dict[str, Any]) -> bool:
        message = entry.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        return isinstance(content, list) and any(
            isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Task"
            for block in content
        )

    def is_user(entry: dict[str, Any]) -> bool:
        message = entry.get("message")
        return isinstance(message, dict) and message.get("role") == "user"

    return {
        "sidechain_entry_count": len(sidechains),
        "task_sidechain_entry_count": sum(contains_task_tool(entry) for entry in sidechains),
        "main_chain_user_entry_count": sum(is_user(entry) for entry in main),
        "non_prompt_main_chain_user_entry_count": sum(is_user(entry) and entry.get("isMeta") is True for entry in main),
    }


def status(supported: bool | None) -> str:
    return "supported" if supported is True else "unsupported" if supported is False else "inconclusive"


def safety_evidence(runs: list[ProcessObservation], home: Path, configs: Iterable[Path],
                    allowed_cwds: Iterable[Path], empty_mcp: Path,
                    source_unchanged: bool | None) -> dict[str, Any]:
    allowed = {str(path.resolve()) for path in allowed_cwds}
    allowed_configs = {str(path) for path in configs}
    empty_mcp_valid = False
    try:
        empty_mcp_valid = json.loads(empty_mcp.read_text(encoding="utf-8")) == {"mcpServers": {}}
    except (OSError, json.JSONDecodeError):
        pass
    fork_runs = [run for run in runs if "--fork-session" in run.argv]
    child_ids = []
    for run in fork_runs:
        if "--session-id" in run.argv:
            index = run.argv.index("--session-id")
            child_ids.append(run.argv[index + 1] if index + 1 < len(run.argv) else "")
    mcp_paths = []
    for run in runs:
        if "--mcp-config" in run.argv:
            index = run.argv.index("--mcp-config")
            mcp_paths.append(run.argv[index + 1] if index + 1 < len(run.argv) else "")
    return {
        "isolated_home": bool(runs) and all(run.environment.get("HOME") == str(home) for run in runs),
        "isolated_claude_config_dir": bool(runs) and all(
            run.environment.get("CLAUDE_CONFIG_DIR") in allowed_configs for run in runs
        ),
        "isolated_working_directories": bool(runs) and all(run.cwd in allowed for run in runs),
        "credential_variables_removed": all(
            not any(part in key.upper() for part in SENSITIVE_KEY_PARTS)
            for run in runs for key in run.environment
        ),
        "network_proxies_fail_closed": bool(runs) and all(
            run.environment.get(key) == "http://127.0.0.1:9"
            for run in runs for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")
        ),
        "repo_prompt_mcp_never_configured": empty_mcp_valid and all(
            path == str(empty_mcp) for path in mcp_paths
        ),
        "empty_mcp_config_verified": empty_mcp_valid,
        "rewind_files_never_used": all("--rewind-files" not in run.argv for run in runs),
        "source_bytes_preserved_in_base_scenario": source_unchanged,
        "one_fork_attempt_per_scenario": len(child_ids) == len(set(child_ids)),
        "fork_invocation_count": len(fork_runs),
        "subprocess_timeout_seconds": PROCESS_TIMEOUT,
        "subprocess_output_limit_bytes": OUTPUT_LIMIT,
    }


def diagnostic() -> tuple[dict[str, Any], bool]:
    if not gate_enabled():
        raise PermissionError(f"{GATE}=1 is required")
    executable_name = os.environ.get("RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE")
    if not executable_name or not Path(executable_name).is_absolute():
        raise ValueError("RPCE_CLAUDE_BRANCH_SPIKE_EXECUTABLE must be an absolute path")
    resolved = shutil.which(executable_name)
    if resolved is None:
        raise FileNotFoundError("Claude executable was not found")
    executable = Path(resolved).resolve()
    observations: dict[str, Any] = {}
    with tempfile.TemporaryDirectory(prefix="rpce-claude-branch-spike-") as raw_root:
        root = Path(raw_root)
        root.chmod(0o700)
        home, config, cwd = root / "home", root / "config", root / "workspace"
        for path in (home, config, cwd):
            path.mkdir(parents=True)
        empty_mcp = root / "empty-mcp.json"
        empty_mcp.write_text('{"mcpServers":{}}\n', encoding="utf-8")
        environment = safe_environment(home, config)
        runs: list[ProcessObservation] = []

        def owned(*args: Any, **kwargs: Any) -> ProcessObservation:
            observation = run_owned(*args, **kwargs)
            runs.append(observation)
            return observation

        version = owned(executable, ["--version"], environment, cwd, timeout=3.0)
        version_text = version.output.decode("utf-8", errors="replace")
        version_match = re.search(r"\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b", version_text)
        parsed_version = version_match.group(0) if version_match else "unparsed"
        observations["cli"] = {
            "parsed_version": parsed_version,
            "matches_report_name_version": parsed_version == "2.1.258",
            "version_output_sha256": hashlib.sha256(version.output).hexdigest()[:12],
            "version_output_bytes": len(version.output),
            "version_exit_status": version.status,
        }

        probe = owned(
            executable, base_args(empty_mcp) + ["--resume-session-at", str(uuid.uuid4())],
            environment, cwd, timeout=3.0,
        )
        observations["S1"] = {
            "status": status(classify_output(probe)["mentions_resume_requirement"]),
            "flag_probe": classify_output(probe),
            "error_evidence": error_evidence(probe, (root, home, config, cwd)),
            "minimal_fork_argv": [
                "-p", "--verbose", "--output-format stream-json", "--input-format stream-json",
                "--permission-prompt-tool stdio", "--resume <source>", "--fork-session",
                "--session-id <child>", "--resume-session-at <anchor>",
                "--mcp-config <empty>", "--strict-mcp-config",
            ],
        }

        discovery_id = str(uuid.uuid4())
        discovery_uuid = str(uuid.uuid4())
        discovery_payload = json.dumps({
            "type": "user", "session_id": discovery_id, "uuid": discovery_uuid,
            "message": {"role": "user", "content": "fixture-store-discovery"},
            "parent_tool_use_id": None,
        }).encode()
        discovery = owned(
            executable, base_args(empty_mcp) + ["--session-id", discovery_id], environment, cwd,
            stdin_lines=(INITIALIZE_FRAME, discovery_payload), prompt_sent=True,
            requested_session_id=discovery_id, timeout=5.0,
        )
        discovered_path, discovery_reason = find_store_path(config, cwd, discovery_id)
        observations["store_discovery"] = {
            "status": discovery_reason,
            "store_exists": discovered_path is not None,
            "matching_store_count": 1 if discovered_path is not None else 0,
            "realpath_cwd_match": discovered_path is not None,
            "process": classify_output(discovery),
        }
        if discovered_path is None:
            observations["S0"] = {
                "status": "unsupported",
                "failure_reason": discovery_reason,
                "source_store_discoverable": False,
            }
            for key in ("S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11"):
                observations[key] = {
                    "status": "inconclusive",
                    "blocked_by": "S0-store-discovery",
                }
            observations["S2"]["a_child_durable_before_prompt"] = False
            observations["safety"] = safety_evidence(
                runs, home, (config,), (cwd,), empty_mcp, source_unchanged=None
            )
            return observations, False

        source_id, child_id = str(uuid.uuid4()), str(uuid.uuid4())
        source_path, ids = make_fixture(
            config, cwd, source_id, directory=discovered_path.parent
        )
        source_bytes = source_path.read_bytes()
        source_entries_before = parse_jsonl_bytes_with_integrity(source_bytes)
        expected_child_path = source_path.parent / f"{child_id}.jsonl"
        base = owned(
            executable, fork_args(empty_mcp, source_id, child_id, ids[3]), environment, cwd,
            stdin_lines=(INITIALIZE_FRAME,), requested_session_id=child_id,
            watch_path=expected_child_path,
        )
        base_output = classify_output(base)
        child_path, child_discovery = discover_child_store(
            config, cwd, child_id, expected_child_path
        )
        child_parse = parse_jsonl_with_integrity(child_path)
        child_entries = child_parse.entries
        child_summary = summarize_entries(child_entries)
        source_unchanged = source_path.read_bytes() == source_bytes
        equality = chain_evidence(source_entries_before, child_parse, ids[3])
        uuids_preserved = equality["uuid_chain_equality"]
        child_session_ids = {
            entry.get("sessionId") for entry in child_entries if isinstance(entry.get("sessionId"), str)
        }
        base_child_durable = child_store_durable(child_path)
        s0_supported = base_child_durable
        observations["S0"] = {
            "status": status(s0_supported),
            "process_spawned": base.status is not None or bool(base.output),
            "resume_and_fork_requested": "--resume" in base.argv and "--fork-session" in base.argv,
            "source_store_discoverable": True,
            "child_store_discovery": child_discovery,
            **protocol_evidence(base),
        }
        observations["S2"] = {
            "status": status(equality["structural_equality_ignoring_uuid"] if base_child_durable else None),
            "a_child_durable_before_prompt": base_child_durable,
            "child_store_discovery": child_discovery,
            "b_uuid_policy": "preserved" if uuids_preserved else "re-minted-or-inconclusive",
            "c_source_bytes_unchanged": source_unchanged,
            "d_child_session_ids_match_child": child_session_ids == {child_id} if child_entries else None,
            "e_system_init": base_output,
            "main_chain_evidence": equality,
            "child_summary": child_summary,
        }

        prompt_session = str(uuid.uuid4())
        prompt_uuid = str(uuid.uuid4())
        prompt_payload = json.dumps({
            "type": "user", "session_id": prompt_session, "uuid": prompt_uuid,
            "message": {"role": "user", "content": "fixture-probe"},
            "parent_tool_use_id": None,
        }).encode()
        prompt_run = owned(
            executable, base_args(empty_mcp) + ["--session-id", prompt_session], environment, cwd,
            stdin_lines=(INITIALIZE_FRAME, prompt_payload), prompt_sent=True,
            requested_session_id=prompt_session, timeout=5.0,
        )
        prompt_store, prompt_store_reason = find_store_path(config, cwd, prompt_session)
        prompt_entries = parse_jsonl(prompt_store) if prompt_store is not None else []
        prompt_user_uuids = {
            entry.get("uuid") for entry in prompt_entries
            if isinstance(entry.get("message"), dict) and entry["message"].get("role") == "user"
        }
        standard_stream_uuid = stream_uuid_observation(prompt_run.output, prompt_uuid)

        replay_session = str(uuid.uuid4())
        replay_uuid = str(uuid.uuid4())
        replay_payload = json.dumps({
            "type": "user", "session_id": replay_session, "uuid": replay_uuid,
            "message": {"role": "user", "content": "fixture-replay-probe"},
            "parent_tool_use_id": None,
        }).encode()
        replay_run = owned(
            executable,
            base_args(empty_mcp) + ["--session-id", replay_session, "--replay-user-messages"],
            environment, cwd, stdin_lines=(INITIALIZE_FRAME, replay_payload),
            prompt_sent=True, requested_session_id=replay_session, timeout=5.0,
        )
        replay_store, replay_store_reason = find_store_path(config, cwd, replay_session)
        replay_entries = parse_jsonl(replay_store) if replay_store is not None else []
        replay_user_uuids = {
            entry.get("uuid") for entry in replay_entries
            if isinstance(entry.get("message"), dict) and entry["message"].get("role") == "user"
        }
        replay_persisted = replay_uuid in replay_user_uuids if replay_store is not None else None
        replay_echo = stream_uuid_observation(replay_run.output, replay_uuid)
        replay_determined = (
            replay_echo["target_uuid_echoed"]
            if prompt_store is not None and replay_store is not None and replay_persisted is True
            else None
        )
        observations["S3"] = {
            "status": status(replay_determined),
            "standard": {
                "store_exists": prompt_store is not None,
                "store_discovery": prompt_store_reason,
                "disk_user_entry_count": len(prompt_user_uuids),
                "caller_uuid_persisted": (
                    prompt_uuid in prompt_user_uuids if prompt_store is not None else None
                ),
                "disk_user_uuid_matches_stream_uuid": (
                    prompt_uuid in prompt_user_uuids
                    if prompt_store is not None and standard_stream_uuid["target_uuid_echoed"] is True
                    else None
                ),
                "stream_uuid_observation": standard_stream_uuid,
                "process": classify_output(prompt_run),
            },
            "replay_enabled": {
                "store_exists": replay_store is not None,
                "store_discovery": replay_store_reason,
                "disk_user_entry_count": len(replay_user_uuids),
                "caller_uuid_persisted": replay_persisted,
                "disk_user_uuid_matches_stream_uuid": (
                    replay_persisted
                    if replay_echo["target_uuid_echoed"] is True and replay_store is not None
                    else None
                ),
                "persisted_uuid_echoed": replay_echo["target_uuid_echoed"],
                "classification": status(replay_determined),
                "stream_uuid_observation": replay_echo,
                "process": classify_output(replay_run),
            },
        }

        drops_id = str(uuid.uuid4())
        drops_path, drops_ids = make_fixture(
            config, cwd, drops_id, directory=discovered_path.parent
        )
        drops_before = drops_path.read_bytes()
        drops_payload = json.dumps({
            "type": "user", "session_id": drops_id, "uuid": str(uuid.uuid4()),
            "message": {"role": "user", "content": "fixture-drops-probe"},
            "parent_tool_use_id": None,
        }).encode()
        drops = owned(
            executable,
            base_args(empty_mcp) + [
                "--resume", drops_id,
                "--resume-session-at", drops_ids[3],
                "--resume-drops-turn", drops_ids[4],
            ],
            environment, cwd, stdin_lines=(INITIALIZE_FRAME, drops_payload),
            prompt_sent=True, requested_session_id=drops_id, timeout=5.0,
        )
        drops_changed = drops_path.read_bytes() != drops_before
        if drops_changed:
            drops_path.write_bytes(drops_before)
        observations["S4"] = {
            "status": "inconclusive",
            "output": classify_output(drops),
            "source_changed_during_probe": drops_changed,
            "source_restored": drops_path.read_bytes() == drops_before,
            "error_evidence": error_evidence(drops, (root, home, config, cwd)),
        }

        compact_results = []
        for label, anchor_index in (("before", 1), ("after", 5)):
            scenario_id, scenario_child = str(uuid.uuid4()), str(uuid.uuid4())
            scenario_path, scenario_ids = make_fixture(
                config, cwd, scenario_id, compact=True, directory=discovered_path.parent
            )
            scenario_source_bytes = scenario_path.read_bytes()
            scenario_source_entries = parse_jsonl_bytes_with_integrity(scenario_source_bytes)
            expected_child = scenario_path.parent / f"{scenario_child}.jsonl"
            result = owned(
                executable, fork_args(empty_mcp, scenario_id, scenario_child, scenario_ids[anchor_index]),
                environment, cwd, stdin_lines=(INITIALIZE_FRAME,),
                requested_session_id=scenario_child, watch_path=expected_child,
            )
            child, child_discovery = discover_child_store(
                config, cwd, scenario_child, expected_child
            )
            child_parse = parse_jsonl_with_integrity(child)
            child_entries = child_parse.entries
            equality = chain_evidence(scenario_source_entries, child_parse, scenario_ids[anchor_index])
            compact_results.append({
                "anchor": label,
                "child_durable": child_store_durable(child),
                "child_store_discovery": child_discovery,
                "source_unchanged": scenario_path.read_bytes() == scenario_source_bytes,
                "main_chain_evidence": equality,
                "child_summary": summarize_entries(child_entries),
                "protocol": protocol_evidence(result),
            })
        compact_comparable = all(item["child_durable"] for item in compact_results)
        compact_equal = compact_comparable and all(
            item["main_chain_evidence"]["structural_equality_ignoring_uuid"]
            for item in compact_results
        )
        observations["S5"] = {
            "status": status(compact_equal if compact_comparable else None),
            "history_lockout_triggered": not compact_equal if compact_comparable else None,
            "scenarios": compact_results,
        }

        side_id, side_child = str(uuid.uuid4()), str(uuid.uuid4())
        side_source_path, side_ids = make_fixture(
            config, cwd, side_id, sidechain=True, directory=discovered_path.parent
        )
        side_source_entries = parse_jsonl_bytes(side_source_path.read_bytes())
        expected_side_child_path = side_source_path.parent / f"{side_child}.jsonl"
        side_result = owned(
            executable, fork_args(empty_mcp, side_id, side_child, side_ids[5]), environment, cwd,
            stdin_lines=(INITIALIZE_FRAME,), requested_session_id=side_child,
            watch_path=expected_side_child_path,
        )
        side_child_path, side_child_discovery = discover_child_store(
            config, cwd, side_child, expected_side_child_path
        )
        side_child_entries = parse_jsonl(side_child_path) if side_child_path is not None else []
        side_child_durable = child_store_durable(side_child_path)
        source_shape = history_shape_counts(side_source_entries)
        child_shape = history_shape_counts(side_child_entries)
        retained_ancestry = ancestor_uuid_set(side_source_entries, side_ids[5])
        expected_meta_uuids = {
            entry["uuid"] for entry in side_source_entries
            if entry.get("isMeta") is True and entry.get("uuid") in retained_ancestry
        }
        expected_sidechain_uuids = {
            entry["uuid"] for entry in side_source_entries
            if (entry.get("isSidechain") is True or entry.get("parent_tool_use_id") is not None)
            and entry.get("parentUuid") in retained_ancestry
        }
        child_uuids = {
            entry["uuid"] for entry in side_child_entries if isinstance(entry.get("uuid"), str)
        }

        def shape_outcome(key: str) -> str:
            if not side_child_durable:
                return "inconclusive"
            if child_shape[key] == source_shape[key]:
                return "preserved"
            if child_shape[key] == 0 and source_shape[key] > 0:
                return "dropped"
            return "changed"

        observations["S6"] = {
            "status": status(True if side_child_durable else None),
            "child_store_discovery": side_child_discovery,
            "source_shape": source_shape,
            "child_shape": child_shape,
            "task_sidechain_outcome": shape_outcome("task_sidechain_entry_count"),
            "non_prompt_main_chain_user_outcome": shape_outcome("non_prompt_main_chain_user_entry_count"),
            "retained_parent_ancestry_count": len(retained_ancestry),
            "expected_non_prompt_user_membership_preserved": (
                expected_meta_uuids <= child_uuids if side_child_durable else None
            ),
            "expected_task_sidechain_membership_preserved": (
                expected_sidechain_uuids <= child_uuids if side_child_durable else None
            ),
            "child_summary": summarize_entries(side_child_entries),
            "protocol": protocol_evidence(side_result),
        }

        invalid_results = []
        for label, anchor in (("bogus", str(uuid.uuid4())), ("mid-turn", ids[2])):
            invalid_child = str(uuid.uuid4())
            expected_invalid_child = source_path.parent / f"{invalid_child}.jsonl"
            result = owned(
                executable, fork_args(empty_mcp, source_id, invalid_child, anchor), environment, cwd,
                stdin_lines=(INITIALIZE_FRAME,), requested_session_id=invalid_child,
                watch_path=expected_invalid_child, timeout=4.0,
            )
            invalid_child_path, invalid_child_discovery = discover_child_store(
                config, cwd, invalid_child, expected_invalid_child
            )
            invalid_results.append({
                "anchor": label,
                "child_created": child_store_durable(invalid_child_path),
                "child_store_discovery": invalid_child_discovery,
                "output": classify_output(result),
                "error_evidence": error_evidence(result, (root, home, config, cwd)),
            })
        observations["S7"] = {"status": "inconclusive", "scenarios": invalid_results}

        cwd_results = []
        real_unicode = root / "work space-Đ"
        real_unicode.mkdir()
        symlink = root / "workspace-link"
        symlink.symlink_to(real_unicode, target_is_directory=True)
        for label, scenario_cwd in (("spaces-unicode", real_unicode), ("symlink", symlink)):
            discovery_session = str(uuid.uuid4())
            discovery_uuid = str(uuid.uuid4())
            discovery_payload = json.dumps({
                "type": "user", "session_id": discovery_session, "uuid": discovery_uuid,
                "message": {"role": "user", "content": "fixture-cwd-store-discovery"},
                "parent_tool_use_id": None,
            }).encode()
            discovery_run = owned(
                executable, base_args(empty_mcp) + ["--session-id", discovery_session],
                environment, scenario_cwd,
                stdin_lines=(INITIALIZE_FRAME, discovery_payload), prompt_sent=True,
                requested_session_id=discovery_session, timeout=5.0,
            )
            discovered, discovery_reason = find_store_path(config, scenario_cwd, discovery_session)
            if discovered is None:
                cwd_results.append({
                    "cwd_shape": label,
                    "store_discovery": discovery_reason,
                    "child_durable": None,
                    "protocol": protocol_evidence(discovery_run),
                })
                continue
            scenario_id, scenario_child = str(uuid.uuid4()), str(uuid.uuid4())
            scenario_source, scenario_ids = make_fixture(
                config, scenario_cwd, scenario_id, directory=discovered.parent
            )
            expected_child = scenario_source.parent / f"{scenario_child}.jsonl"
            result = owned(
                executable, fork_args(empty_mcp, scenario_id, scenario_child, scenario_ids[3]),
                environment, scenario_cwd, stdin_lines=(INITIALIZE_FRAME,),
                requested_session_id=scenario_child, watch_path=expected_child,
            )
            child, child_discovery = discover_child_store(
                config, scenario_cwd, scenario_child, expected_child
            )
            cwd_results.append({
                "cwd_shape": label,
                "store_discovery": discovery_reason,
                "child_store_discovery": child_discovery,
                "empirically_discovered_location_used": child is not None,
                "child_durable": child_store_durable(child),
                "protocol": protocol_evidence(result),
            })
        s8_durable = all(item["child_durable"] is True for item in cwd_results)
        observations["S8"] = {
            "status": status(s8_durable) if s0_supported else "inconclusive",
            "blocked_by": None if s0_supported else "S0",
            "scenarios": cwd_results,
        }

        missing_id, missing_child = str(uuid.uuid4()), str(uuid.uuid4())
        expected_missing_child = discovered_path.parent / f"{missing_child}.jsonl"
        missing = owned(
            executable, fork_args(empty_mcp, missing_id, missing_child, str(uuid.uuid4())), environment, cwd,
            watch_path=expected_missing_child, timeout=4.0,
        )
        _, missing_child_discovery = discover_child_store(
            config, cwd, missing_child, expected_missing_child
        )
        missing_error = error_evidence(missing, (root, home, config, cwd))
        missing_recognized = missing_error["error_classification"] == "missing-session"
        missing_child_created = child_candidate_presence(missing_child_discovery)
        observations["S9"] = {
            "status": missing_session_status(
                missing_recognized, missing.timed_out, missing_child_discovery
            ),
            "failed_fast": not missing.timed_out,
            "child_created": missing_child_created,
            "child_store_discovery": missing_child_discovery,
            "output": classify_output(missing),
            "error_evidence": missing_error,
        }

        killed_id, killed_child = str(uuid.uuid4()), str(uuid.uuid4())
        killed_source, killed_ids = make_fixture(
            config, cwd, killed_id, directory=discovered_path.parent
        )
        expected_killed_path = killed_source.parent / f"{killed_child}.jsonl"
        killed = owned(
            executable, fork_args(empty_mcp, killed_id, killed_child, killed_ids[3]), environment, cwd,
            stdin_lines=(INITIALIZE_FRAME,), requested_session_id=killed_child,
            watch_path=expected_killed_path, kill_after_control_response=True,
        )
        _, killed_child_discovery = discover_child_store(
            config, cwd, killed_child, expected_killed_path
        )
        killed_child_exists = child_candidate_presence(killed_child_discovery)
        killed_child_bytes = child_candidate_bytes(killed_child_discovery)
        observations["S10"] = {
            "status": "inconclusive",
            "kill_sent": killed.killed_intentionally,
            "child_store_discovery": killed_child_discovery,
            "child_exists_after_kill": killed_child_exists,
            "child_bytes_after_kill": killed_child_bytes,
            **protocol_evidence(killed),
        }

        hook_config = root / "hook-config"
        hook_config.mkdir()
        hook_cwd = root / "hook-workspace"
        hook_cwd.mkdir()
        hook_marker = root / "hook-fired"
        hook_settings = {
            "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": f"/usr/bin/touch {hook_marker}"}]}]},
        }
        (hook_config / "settings.json").write_text(json.dumps(hook_settings), encoding="utf-8")
        hook_env = safe_environment(home, hook_config)
        hook_discovery_id = str(uuid.uuid4())
        hook_discovery_payload = json.dumps({
            "type": "user", "session_id": hook_discovery_id, "uuid": str(uuid.uuid4()),
            "message": {"role": "user", "content": "fixture-hook-store-discovery"},
            "parent_tool_use_id": None,
        }).encode()
        hook_discovery = owned(
            executable, base_args(empty_mcp) + ["--session-id", hook_discovery_id],
            hook_env, hook_cwd, stdin_lines=(INITIALIZE_FRAME, hook_discovery_payload),
            prompt_sent=True, requested_session_id=hook_discovery_id, timeout=5.0,
        )
        hook_store, hook_store_reason = find_store_path(hook_config, hook_cwd, hook_discovery_id)
        try:
            hook_marker.unlink()
        except FileNotFoundError:
            pass
        if hook_store is None:
            observations["S11"] = {
                "status": "inconclusive",
                "blocked_by": hook_store_reason,
                "store_discovery_protocol": protocol_evidence(hook_discovery),
            }
            observations["safety"] = safety_evidence(
                runs, home, (config, hook_config), (cwd, real_unicode, symlink, hook_cwd),
                empty_mcp, source_unchanged
            )
            blockers_pass = bool(
                observations["S0"]["status"] == "supported"
                and observations["S2"]["a_child_durable_before_prompt"]
            )
            return observations, blockers_pass
        hook_id, hook_child = str(uuid.uuid4()), str(uuid.uuid4())
        hook_source, hook_ids = make_fixture(
            hook_config, hook_cwd, hook_id, directory=hook_store.parent
        )
        expected_hook_child_path = hook_source.parent / f"{hook_child}.jsonl"
        hook = owned(
            executable, fork_args(empty_mcp, hook_id, hook_child, hook_ids[3]), hook_env, hook_cwd,
            stdin_lines=(INITIALIZE_FRAME,), requested_session_id=hook_child,
            watch_path=expected_hook_child_path,
        )
        _, hook_child_discovery = discover_child_store(
            hook_config, hook_cwd, hook_child, expected_hook_child_path
        )
        hook_events = classify_output(hook)
        observations["S11"] = {
            "status": "inconclusive",
            "session_start_hook_fired": hook_marker.exists(),
            "store_discovery": hook_store_reason,
            "child_store_discovery": hook_child_discovery,
            **protocol_evidence(hook),
            "repo_prompt_mcp_configured": any(
                value != str(empty_mcp)
                for index, value in enumerate(hook.argv)
                if index > 0 and hook.argv[index - 1] == "--mcp-config"
            ),
            "stream_event_types": hook_events["event_types"],
            "model_or_tool_request_evidence": hook_events["event_types"].get("assistant", 0) > 0,
        }

        observations["safety"] = safety_evidence(
            runs, home, (config, hook_config), (cwd, real_unicode, symlink, hook_cwd),
            empty_mcp, source_unchanged
        )
        blockers_pass = bool(observations["S0"]["status"] == "supported" and observations["S2"]["a_child_durable_before_prompt"])
        return observations, blockers_pass


def render_report(observations: dict[str, Any], blockers_pass: bool) -> str:
    lines = [
        "# Claude native branching spike",
        "",
        "Local diagnostic evidence. Raw prompts, responses, credentials, UUIDs, and machine paths are intentionally omitted.",
        "",
        f"- Blocking result (S0 + S2(a)): **{'PASS' if blockers_pass else 'FAIL'}**",
        f"- Installed CLI version: `{observations.get('cli', {}).get('parsed_version', 'unavailable')}`",
        f"- Report-name version match: `{observations.get('cli', {}).get('matches_report_name_version', False)}`",
        "- Gate: `RPCE_CLAUDE_BRANCH_SPIKE=1`",
        "- Runtime isolation and fork-safety claims are derived from recorded argv/environment and the verified empty MCP document; see Safety envelope.",
        "",
        "## Observations",
        "",
    ]
    for key in [f"S{i}" for i in range(12)]:
        value = observations.get(key, {"status": "inconclusive"})
        lines.extend([f"### {key} — {value.get('status', 'inconclusive')}", "", "```json", json.dumps(value, indent=2, sort_keys=True), "```", ""])
    lines.extend(["## Safety envelope", "", "```json", json.dumps(observations.get("safety", {}), indent=2, sort_keys=True), "```", ""])
    return redact("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate-status", action="store_true")
    parser.add_argument("--summarize-jsonl")
    parser.add_argument("--redact-text")
    parser.add_argument("--report")
    args = parser.parse_args()
    if args.gate_status:
        print("enabled" if gate_enabled() else "disabled")
        return 0
    if args.summarize_jsonl:
        print(json.dumps(summarize_entries(parse_jsonl(Path(args.summarize_jsonl))), sort_keys=True))
        return 0
    if args.redact_text:
        print(redact(Path(args.redact_text).read_text(encoding="utf-8")))
        return 0
    if not args.report:
        parser.error("--report is required for the live diagnostic")
    if not gate_enabled():
        print(f"refusing live diagnostic: {GATE}=1 is required", file=sys.stderr)
        return 64
    report_path = Path(args.report)
    try:
        observations, blockers_pass = diagnostic()
    except Exception as error:  # Write a bounded, redacted failure report without raw CLI output.
        observations = {
            "S0": {
                "status": "unsupported",
                "failure_type": type(error).__name__,
                "failure_cause": redact(str(error)),
            },
            "S2": {"status": "inconclusive", "a_child_durable_before_prompt": False},
        }
        blockers_pass = False
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(render_report(observations, blockers_pass), encoding="utf-8")
    return 0 if blockers_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
