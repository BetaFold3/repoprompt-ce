#!/usr/bin/python3
"""Deterministic fake Claude CLI for the branch-fork diagnostic tests."""

from __future__ import annotations

import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path


def argument(name: str) -> str | None:
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except (ValueError, IndexError):
        return None


def project_dir() -> Path:
    config = Path(os.environ["CLAUDE_CONFIG_DIR"])
    digest = hashlib.sha256(str(Path.cwd().resolve()).encode()).hexdigest()[:12]
    path = config / "projects" / f"empirical-{digest}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def store(session_id: str) -> Path:
    if os.environ.get("FAKE_CLAUDE_CHILD_ELSEWHERE") == "1" and "--fork-session" in sys.argv:
        path = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "alternate-child-location"
        path.mkdir(parents=True, exist_ok=True)
        return path / f"{session_id}.jsonl"
    return project_dir() / f"{session_id}.jsonl"


def read_entries(path: Path) -> list[dict]:
    if not path.exists():
        return []
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            result.append(value)
    return result


def find_source(session_id: str) -> Path | None:
    config = Path(os.environ["CLAUDE_CONFIG_DIR"])
    matches = list(config.rglob(f"{session_id}.jsonl"))
    return matches[0] if len(matches) == 1 else None


def write_entries(path: Path, entries: list[dict]) -> None:
    path.write_text("".join(json.dumps(entry, separators=(",", ":")) + "\n" for entry in entries), encoding="utf-8")


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":")), flush=True)


def fire_hook() -> None:
    settings = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "settings.json"
    if not settings.exists():
        return
    try:
        document = json.loads(settings.read_text(encoding="utf-8"))
        command = document["hooks"]["SessionStart"][0]["hooks"][0]["command"]
    except (KeyError, IndexError, TypeError, json.JSONDecodeError):
        return
    prefix = "/usr/bin/touch "
    if command.startswith(prefix):
        Path(command[len(prefix):]).touch()


if "--version" in sys.argv:
    print("2.1.258")
    raise SystemExit(0)

if "--resume-session-at" in sys.argv and "--resume" not in sys.argv:
    print("Error: --resume-session-at requires --resume", file=sys.stderr)
    raise SystemExit(2)

frames = []
for line in sys.stdin.buffer:
    try:
        frame = json.loads(line)
    except json.JSONDecodeError:
        continue
    frames.append(frame)
    if frame.get("type") == "control_request":
        if (
            "--fork-session" in sys.argv
            and os.environ.get("FAKE_CLAUDE_PARTIAL_CHILD_BEFORE_CONTROL") == "1"
        ):
            partial_store = store(argument("--session-id"))
            partial_store.write_bytes(b'{"cwd":')
        emit({
            "type": "control_response",
            "response": {
                "request_id": frame.get("request_id"),
                "subtype": "success",
            },
        })
        if "--fork-session" in sys.argv:
            time.sleep(0.15)
            break
    elif frame.get("type") == "user":
        break

fire_hook()
session_id = argument("--session-id")
source_id = argument("--resume")
anchor = argument("--resume-session-at")

if source_id is not None and "--fork-session" in sys.argv:
    source_path = find_source(source_id)
    if source_path is None:
        if os.environ.get("FAKE_CLAUDE_MISSING_CHILD_CWD_MISMATCH") == "1":
            write_entries(store(session_id), [{
                "cwd": str(Path.cwd().parent / "different-workspace"),
                "sessionId": session_id,
                "uuid": "00000000-0000-4000-8000-000000000002",
            }])
        print("Error: session not found", file=sys.stderr)
        raise SystemExit(3)
    if os.environ.get("FAKE_CLAUDE_NO_FORK_CHILD") == "1":
        emit({"type": "system", "subtype": "init", "session_id": session_id})
        emit({"type": "result", "is_error": False})
        raise SystemExit(0)
    entries = read_entries(source_path)
    by_uuid = {entry.get("uuid"): entry for entry in entries}
    if anchor not in by_uuid:
        print(f"Error: No message found with message.uuid of: {anchor}", file=sys.stderr)
        raise SystemExit(4)
    ancestry = set()
    current = anchor
    while current is not None and current not in ancestry and current in by_uuid:
        ancestry.add(current)
        parent = by_uuid[current].get("parentUuid")
        current = parent if isinstance(parent, str) else None
    retained = []
    for entry in entries:
        is_sidechain = entry.get("isSidechain") is True or entry.get("parent_tool_use_id") is not None
        if entry.get("uuid") in ancestry or (is_sidechain and entry.get("parentUuid") in ancestry):
            copy = dict(entry)
            copy["sessionId"] = session_id
            retained.append(copy)
    if os.environ.get("FAKE_CLAUDE_APPEND_EXTRA") == "1":
        retained.append({
            "parentUuid": anchor,
            "isSidechain": False,
            "cwd": str(Path.cwd()),
            "sessionId": session_id,
            "type": "system",
            "message": {"role": "system", "content": "unexpected"},
            "uuid": "00000000-0000-4000-8000-000000000001",
        })
    write_entries(store(session_id), retained)
    emit({"type": "system", "subtype": "init", "session_id": session_id})
    emit({"type": "result", "is_error": False})
    raise SystemExit(0)

user_frames = [frame for frame in frames if frame.get("type") == "user"]
if source_id is not None and "--resume-drops-turn" in sys.argv:
    source_path = find_source(source_id)
    if source_path is None:
        print("Error: session not found", file=sys.stderr)
        raise SystemExit(3)
    entries = read_entries(source_path)
    for frame in user_frames:
        entries.append({
            "parentUuid": anchor,
            "isSidechain": False,
            "cwd": str(Path.cwd()),
            "sessionId": source_id,
            "type": "user",
            "message": frame.get("message"),
            "uuid": frame.get("uuid"),
        })
    write_entries(source_path, entries)
    emit({"type": "system", "subtype": "init", "session_id": source_id})
    emit({"type": "result", "is_error": False})
    raise SystemExit(0)

if session_id is not None and user_frames:
    entries = []
    for frame in user_frames:
        entries.append({
            "parentUuid": None,
            "isSidechain": False,
            "cwd": str(Path.cwd()),
            "sessionId": session_id,
            "type": "user",
            "message": frame.get("message"),
            "uuid": frame.get("uuid"),
        })
        if "--replay-user-messages" in sys.argv:
            emit({"type": "user", "session_id": session_id, "uuid": frame.get("uuid")})
    write_entries(store(session_id), entries)
    emit({"type": "system", "subtype": "init", "session_id": session_id})
    emit({"type": "result", "is_error": False})
    raise SystemExit(0)

emit({"type": "result", "is_error": False})
