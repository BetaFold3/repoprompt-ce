#!/usr/bin/env python3
"""Offline, aggregate-only Claude Code / Codex tool-usage measurement.

JSONL is streamed with a bounded record size. A disposable SQLite database holds
hashes, counters and sizes (never prompts, arguments, paths or output text).
Exact percentiles and deduplication use disk, not corpus-sized Python lists.
No network, app interaction, or source-log mutation.
"""

from __future__ import annotations

import argparse
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import sqlite3
import sys
import tempfile
from typing import Any, Iterable, Sequence

SCHEMA_VERSION = "rpce.tool-usage-summary.v1"
DEFAULT_SINCE = "2026-04-03T00:00:00Z"
DEFAULT_UNTIL = "2026-10-04T00:00:00Z"
MAX_LINE_BYTES = 16 * 1024 * 1024
EXPLORATION = {"read_file", "file_search", "get_code_structure", "get_file_tree"}
SEARCH_TOOLS = {"file_search", "get_code_structure", "get_file_tree"}
TOKEN_FIELDS = ("input", "cached_input", "cache_creation_input", "output")
NESTED_CALL = re.compile(r"\btools\.([A-Za-z_$][\w$]*)\s*\(")
PATH_TOKEN = re.compile(r"[^\s\x00\x60\"'<>│├└─=,;(){}\[\]]+")
TRUNCATION = re.compile(
    r"(?:limit\s+reached|(?:results?|matches?|output|response)\s+(?:were\s+)?truncated"
    r"|truncated\s+(?:results?|output|to)|(?:size|character|byte|result)\s+(?:cap|limit)\s+(?:reached|exceeded)"
    r"|(?:additional|excess|remaining)\s+(?:results?|matches?)\s+(?:omitted|not shown)"
    r"|\b\d+\s+(?:results?|matches?)\s+omitted|max_results\s+reached)", re.I,
)
GIT_COMMANDS = set(
    "add am apply archive bisect blame branch checkout cherry-pick clean clone commit "
    "config describe diff fetch format-patch gc grep init log ls-files ls-tree merge "
    "mv notes pull push range-diff rebase reflog remote reset restore revert rev-list "
    "rev-parse rm show show-ref sparse-checkout stash status submodule switch tag "
    "update-index worktree".split()
)


class AnalyzerError(Exception):
    """An expected failure whose message contains no private input."""


def digest(value: Any) -> str:
    encoded = value if isinstance(value, str) else json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    )
    return hashlib.sha256(encoded.encode("utf-8", errors="replace")).hexdigest()


def timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def tool_name(name: Any, namespace: Any = "") -> str:
    """Namespace is authoritative for Codex bare MCP names; omit server names."""
    name = name if isinstance(name, str) else "unknown"
    namespace = namespace if isinstance(namespace, str) else ""
    prefix = "NATIVE"
    if "repoprompt" in namespace.lower():
        prefix = "RP"
    elif namespace.startswith("mcp"):
        prefix = "MCP_OTHER"
    match = re.fullmatch(r"mcp__(.+)__(.+)", name)
    if match:
        prefix = "RP" if "repoprompt" in match[1].lower() else "MCP_OTHER"
        name = match[2]
    elif re.fullmatch(r"RepoPrompt\w*\.\w+", name):
        prefix, name = "RP", name.split(".", 1)[1]
    if not re.fullmatch(r"[A-Za-z_$][\w$]{0,79}", name):
        name = "unknown"
    return prefix + ":" + name


def content_text(value: Any) -> str:
    """Text blocks contribute their text, not transport wrapper keys.

    Non-text blocks/objects use Unicode JSON serialization. These sizes measure
    logged payload, not network framing, tokenizer output, or billed tokens.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(content_text(item) for item in value)
    if isinstance(value, dict) and value.get("type") in ("text", "input_text", "output_text"):
        return content_text(value.get("text"))
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def arguments(value: Any) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def strip_js_comments_strings(source: str) -> str:
    """Lexical estimate only: ignore comments/quoted strings, including templates.

    Dynamic dispatch, template interpolations, loops and aliases are not resolved.
    """
    pattern = r"//[^\n]*|/\*[\s\S]*?\*/|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|`(?:\\.|[^`\\])*`"
    return re.sub(pattern, lambda m: " " * len(m[0]), source)


def script_tools(source: str) -> tuple[list[str], bool]:
    code = strip_js_comments_strings(source)
    return [tool_name(name) for name in NESTED_CALL.findall(code)], bool(
        re.search(r"\bPromise\s*\.\s*all\s*\(", code)
    )


def path_key(value: str) -> str:
    # No resolution, root inference, basename-only matching, or case folding.
    return digest(value.replace("\\", "/").removeprefix("./"))


def candidate_paths(text: str) -> Iterable[str]:
    # Literal token matching, not semantic dependency inference. Tree indentation
    # and paths containing whitespace can be missed; this is a lower-bound proxy.
    for token in PATH_TOKEN.findall(text):
        token = re.sub(r":\d+(?:[-:]\d+)*$", "", token.strip("*"))
        if "/" in token or re.search(r"\.[A-Za-z0-9]{1,12}$", token):
            yield path_key(token)


def is_truncated(value: Any, text: str) -> bool:
    if TRUNCATION.search(text):
        return True
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return False
    if isinstance(value, list):
        return any(is_truncated(item, "") for item in value)
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r"[_-]", "", key).lower()
            if normalized in {"truncated", "istruncated", "limitreached", "sizelimitreached", "resultlimitreached", "hasmore"} and item is True:
                return True
            if normalized in {"omittedcount", "omittedresults", "truncatedcount"} and isinstance(item, int) and item > 0:
                return True
            if normalized == "text" and isinstance(item, str) and is_truncated(item, item):
                return True
            if isinstance(item, (dict, list)) and is_truncated(item, ""):
                return True
    return False


def shell_git(command: Any) -> Counter[str]:
    """Lexical shell-command-position heuristic; never execute a command.

    Handles separators, git -C/-c and common global options; excludes quoted
    prose such as echo "git status". Does not interpret shell variables/aliases.
    """
    if isinstance(command, list):
        if len(command) >= 3 and command[1] in ("-c", "-lc"):
            command = command[2]
        else:
            command = shlex.join(str(x) for x in command)
    if not isinstance(command, str):
        return Counter()
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return Counter()
    result: Counter[str] = Counter()
    position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token and all(c in ";&|()\n" for c in token):
            position = True
        elif position and (token in ("env", "command", "sudo") or re.match(r"^\w+=", token)):
            pass
        elif position and token.rsplit("/", 1)[-1] == "git":
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                option = tokens[index]
                index += 1
                if option in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
                    index += 1
            if index < len(tokens):
                subcommand = tokens[index]
                result[subcommand if subcommand in GIT_COMMANDS else "other"] += 1
            position = False
        else:
            position = False
        index += 1
    return result


def counts(usage: Any, provider: str) -> tuple[int, int, int, int] | None:
    if not isinstance(usage, dict):
        return None
    keys = (
        ("input_tokens", "cached_input_tokens", None, "output_tokens")
        if provider == "Codex" else
        ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")
    )
    values = []
    for key in keys:
        raw = usage.get(key, 0) if key else 0
        if not isinstance(raw, int) or isinstance(raw, bool) or raw < 0:
            return None
        values.append(raw)
    return tuple(values) if "input_tokens" in usage and "output_tokens" in usage else None


def jsonl_files(roots: Sequence[Path | str]) -> Iterable[Path]:
    for root in roots:
        root = Path(root).expanduser()
        if root.is_file():
            yield root
        elif root.is_dir():
            for directory, subdirs, filenames in os.walk(root, followlinks=False):
                subdirs.sort()
                for filename in sorted(filenames):
                    if filename.endswith(".jsonl"):
                        yield Path(directory) / filename


class Analyzer:
    def __init__(self, db: sqlite3.Connection, since: datetime, until: datetime, max_line_bytes: int):
        self.db, self.since, self.until = db, since, until
        self.max_line_bytes = max_line_bytes
        db.executescript("""
            PRAGMA cache_size=-8192;
            PRAGMA temp_store=FILE;
            -- Disposable aggregate scratch: no durability or crash recovery needed.
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE files(key TEXT PRIMARY KEY);
            CREATE TABLE records(provider TEXT, key TEXT, PRIMARY KEY(provider,key));
            CREATE TABLE file_records(file TEXT, key TEXT, PRIMARY KEY(file,key));
            CREATE TABLE turns(id TEXT PRIMARY KEY, provider TEXT, month TEXT, observed INTEGER);
            CREATE TABLE calls(
                id TEXT PRIMARY KEY, provider TEXT, tool TEXT, month TEXT, included INTEGER,
                turn_id TEXT, session TEXT, batch TEXT, path TEXT, ranged INTEGER,
                repeated INTEGER, joined INTEGER, script INTEGER, script_rp INTEGER,
                promise_all INTEGER, nested_count INTEGER);
            CREATE TABLE outputs(
                id TEXT PRIMARY KEY, call_id TEXT, provider TEXT, month TEXT,
                turn_id TEXT, chars INTEGER, bytes INTEGER, truncated INTEGER);
            CREATE INDEX output_call ON outputs(call_id);
            CREATE INDEX call_turn ON calls(turn_id);
            CREATE TABLE paths(turn_id TEXT, path TEXT, PRIMARY KEY(turn_id,path));
            CREATE TABLE reads(session TEXT, path TEXT, PRIMARY KEY(session,path));
            CREATE TABLE chains(provider TEXT, length INTEGER);
            CREATE TABLE nested_sites(call_id TEXT, tool TEXT);
            CREATE INDEX nested_call ON nested_sites(call_id);
            CREATE TABLE usage(
                id TEXT PRIMARY KEY, provider TEXT, turn_id TEXT,
                input INTEGER, cached_input INTEGER, cache_creation_input INTEGER, output INTEGER);
            CREATE TABLE events(provider TEXT, metric TEXT, label TEXT, count INTEGER);
        """)
        self.coverage: dict[str, Counter[str]] = {p: Counter() for p in ("Claude", "Codex")}

    def event(self, provider: str, metric: str, label: str, count: int = 1) -> None:
        self.db.execute("INSERT INTO events VALUES(?,?,?,?)", (provider, metric, label, count))

    def scan(self, provider: str, path: Path) -> None:
        cov = self.coverage[provider]
        file_key = digest(str(path.absolute()))
        if not self.db.execute("INSERT OR IGNORE INTO files VALUES(?)", (file_key,)).rowcount:
            cov["duplicate_input_files"] += 1
            return
        try:
            stream = path.open("rb")
        except OSError:
            cov["unreadable_files"] += 1
            return
        cov["files_scanned"] += 1
        session = file_key
        turn: str | None = None
        turn_included = False
        chain = 0
        used_rp = False
        batch = 0
        previous_total: tuple[int, int, int, int] | None = None

        def finish_chain() -> None:
            nonlocal chain
            if chain:
                self.db.execute("INSERT INTO chains VALUES(?,?)", (provider, chain))
                chain = 0

        def new_turn(record: dict[str, Any], included: bool, month: str) -> None:
            nonlocal turn, turn_included, batch
            finish_chain()
            batch += 1
            turn = digest([provider, session, record.get("uuid") or record.get("timestamp"), record])
            turn_included = included
            inserted = self.db.execute("INSERT OR IGNORE INTO turns VALUES(?,?,?,1)",
                                       (turn, provider, month)).rowcount if included else 0
            cov["user_turns"] += inserted

        with stream:
            while True:
                line = stream.readline(self.max_line_bytes + 1)
                if not line:
                    break
                cov["physical_lines"] += 1
                if len(line) > self.max_line_bytes:
                    while line and not line.endswith(b"\n"):
                        line = stream.readline(self.max_line_bytes + 1)
                    cov["oversized_lines"] += 1
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeDecodeError, RecursionError):
                    cov["malformed_lines"] += 1
                    continue
                if not isinstance(record, dict):
                    cov["non_object_records"] += 1
                    continue
                when = timestamp(record.get("timestamp"))
                if when is None:
                    cov["missing_or_invalid_timestamps"] += 1
                    continue
                included = self.since <= when < self.until
                cov["records_in_window" if included else "records_outside_window"] += 1
                month = when.strftime("%Y-%m")
                if when >= self.until:
                    continue
                payload = record.get("payload")
                payload = payload if isinstance(payload, dict) else {}
                # Identity only affects ephemeral state; never emitted.
                if provider == "Claude" and isinstance(record.get("sessionId"), str):
                    session = digest([provider, record["sessionId"]])
                elif provider == "Codex" and record.get("type") == "session_meta":
                    session = digest([provider, payload.get("id") or file_key])
                relevant = (
                    record.get("type") in ("user", "assistant") if provider == "Claude" else
                    (record.get("type") == "response_item" and payload.get("type") in (
                        "message", "function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output"
                    )) or (record.get("type") == "event_msg" and payload.get("type") == "token_count")
                )
                if not relevant:
                    cov["non_tool_or_usage_records"] += int(included)
                    continue
                record_key = digest(record)
                if not self.db.execute("INSERT OR IGNORE INTO records VALUES(?,?)",
                                       (provider, record_key)).rowcount:
                    if included:
                        cov["duplicate_records"] += 1
                    # Advance local turn/baseline state for copied file prefixes.
                    # Calls/outputs below still deduplicate by their own identities.
                    duplicate_record = True
                else:
                    duplicate_record = False
                if not self.db.execute("INSERT OR IGNORE INTO file_records VALUES(?,?)", (file_key, record_key)).rowcount:
                    continue

                calls = []
                results = []
                usage = None
                usage_id = None
                if provider == "Claude":
                    message = record.get("message")
                    message = message if isinstance(message, dict) else {}
                    content = message.get("content")
                    blocks = content if isinstance(content, list) else []
                    results = [(b.get("tool_use_id"), b.get("content")) for b in blocks
                               if isinstance(b, dict) and b.get("type") == "tool_result"]
                    if record.get("type") == "user" and not results and (
                        isinstance(content, str) or any(isinstance(b, dict) and b.get("type") == "text" for b in blocks)
                    ):
                        new_turn(record, included, month)
                    if record.get("type") == "assistant":
                        batch_key = digest([provider, message.get("id") or record_key])
                        calls = [(b.get("id"), b.get("name"), "", b.get("input"), "", batch_key)
                                 for b in blocks if isinstance(b, dict) and b.get("type") == "tool_use"]
                        usage = counts(message.get("usage"), provider)
                        usage_id = digest([provider, "usage", message.get("id") or record_key])
                        if included and not duplicate_record:
                            cov["assistant_records"] += 1
                            if usage is None:
                                cov["assistant_records_without_valid_usage"] += 1
                else:
                    kind = payload.get("type")
                    if kind == "message" and payload.get("role") == "user" and record.get("type") == "response_item":
                        new_turn(record, included, month)
                    if kind in ("function_call", "custom_tool_call") and record.get("type") == "response_item":
                        raw_args = payload.get("arguments")
                        script = payload.get("input") if kind == "custom_tool_call" else raw_args
                        calls = [(payload.get("call_id"), payload.get("name"), payload.get("namespace"),
                                  raw_args, script, digest([provider, session, batch]) if kind == "function_call" else None)]
                    elif kind in ("function_call_output", "custom_tool_call_output") and record.get("type") == "response_item":
                        results = [(payload.get("call_id"), payload.get("output"))]
                        batch += 1
                    elif kind == "message" and payload.get("role") == "assistant":
                        batch += 1
                    elif kind == "token_count":
                        info = payload.get("info")
                        info = info if isinstance(info, dict) else {}
                        total = counts(info.get("total_token_usage"), provider)
                        last = counts(info.get("last_token_usage"), provider)
                        if included and not duplicate_record:
                            cov["token_count_events"] += 1
                        if total is not None:
                            if previous_total is None:
                                usage = last
                                if included and not duplicate_record:
                                    cov["initial_token_checkpoints_using_last"] += 1
                            elif any(a < b for a, b in zip(total, previous_total)):
                                usage = last
                                if included and not duplicate_record:
                                    cov["token_counter_resets_using_last"] += 1
                            else:
                                usage = tuple(a - b for a, b in zip(total, previous_total))
                            previous_total = total
                            usage_id = digest([provider, "tokens", session, record_key])
                        elif included and not duplicate_record:
                            cov["token_count_events_without_totals"] += 1
                        if included and usage is None and not duplicate_record:
                            cov["token_count_events_without_valid_usage"] += 1
                if included and usage is not None and usage_id is not None and any(usage):
                    # Claude's streamed partial usage is one request: retain maxima.
                    if provider == "Claude":
                        self.db.execute("""
                            INSERT INTO usage VALUES(?,?,?,?,?,?,?)
                            ON CONFLICT(id) DO UPDATE SET
                              input=max(input,excluded.input),
                              cached_input=max(cached_input,excluded.cached_input),
                              cache_creation_input=max(cache_creation_input,excluded.cache_creation_input),
                              output=max(output,excluded.output)
                        """, (usage_id, provider, turn if turn_included else None, *usage))
                    else:
                        self.db.execute("INSERT OR IGNORE INTO usage VALUES(?,?,?,?,?,?,?)",
                                        (usage_id, provider, turn if turn_included else None, *usage))

                for call_id, name, namespace, raw_args, source, batch_key in calls:
                    if not isinstance(call_id, str) or not call_id:
                        if included:
                            cov["calls_missing_ids"] += 1
                        continue
                    key = digest([provider, "call", call_id])
                    tool = tool_name(name, namespace)
                    args = arguments(raw_args)
                    is_script = provider == "Codex" and name in ("exec", "js") and not tool.startswith("RP:")
                    if is_script and isinstance(args.get("code"), str):
                        source = args["code"]
                    nested, promise = script_tools(source if isinstance(source, str) else "") if is_script else ([], False)
                    nested_rp = [n for n in nested if n.startswith("RP:")]
                    rp = tool.startswith("RP:") or bool(nested_rp)
                    if included and rp:
                        used_rp = True
                    path_hash = path_key(args["path"]) if tool == "RP:read_file" and isinstance(args.get("path"), str) else None
                    ranged = int(any(args.get(k) is not None for k in ("start_line", "limit", "end_line", "line_range")))
                    repeated = int(bool(path_hash) and self.db.execute(
                        "SELECT 1 FROM reads WHERE session=? AND path=?", (session, path_hash)
                    ).fetchone() is not None)
                    joined = int(bool(path_hash) and turn_included and self.db.execute(
                        "SELECT 1 FROM paths WHERE turn_id=? AND path=?", (turn, path_hash)
                    ).fetchone() is not None)
                    added = self.db.execute("INSERT OR IGNORE INTO calls VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                                            (key, provider, tool, month, int(included),
                                             turn if turn_included else None, session, batch_key, path_hash,
                                             ranged, repeated, joined, int(is_script), int(bool(nested_rp)),
                                             int(promise), len(nested))).rowcount
                    if not added:
                        if included:
                            cov["duplicate_call_ids"] += 1
                        continue
                    if path_hash:
                        self.db.execute("INSERT OR IGNORE INTO reads VALUES(?,?)", (session, path_hash))
                    if not included:
                        continue
                    # Exploration chains are maximal adjacent exploration invocations;
                    # results/reasoning do not break them; any other tool or user does.
                    if tool.removeprefix("RP:") in EXPLORATION and tool.startswith("RP:"):
                        chain += 1
                    else:
                        finish_chain()
                    if is_script:
                        for nested_tool in nested:
                            self.event(provider, "nested_tools", nested_tool)
                            self.db.execute("INSERT INTO nested_sites VALUES(?,?)", (key, nested_tool))
                        for nested_tool in nested_rp:
                            if nested_tool.removeprefix("RP:") in EXPLORATION:
                                self.event(provider, "nested_exploration", "call_sites")
                    if tool == "RP:git":
                        op = args.get("op", "status")
                        op = op if op in ("status", "diff", "log", "show", "blame") else "other"
                        artifacts = "true" if args.get("artifacts") is True else "false" if args.get("artifacts") is False else "omitted"
                        self.event(provider, "rp_git", op + ":" + artifacts)
                    if tool in ("NATIVE:Bash", "NATIVE:exec_command", "NATIVE:shell", "NATIVE:local_shell"):
                        self.event(provider, "shell", "calls")
                        for op, count in shell_git(args.get("cmd", args.get("command"))).items():
                            self.event(provider, "shell_git", op, count)

                for call_id, value in results:
                    if not included:
                        continue
                    key = digest([provider, "call", call_id]) if isinstance(call_id, str) else None
                    text = content_text(value)
                    out_key = digest([provider, key, value])
                    inserted = self.db.execute("INSERT OR IGNORE INTO outputs VALUES(?,?,?,?,?,?,?,?)",
                                               (out_key, key, provider, month, turn if turn_included else None,
                                                len(text), len(text.encode("utf-8", errors="replace")),
                                                int(is_truncated(value, text)))).rowcount
                    if not inserted:
                        cov["duplicate_outputs"] += 1
                        continue
                    match = self.db.execute("SELECT tool,turn_id FROM calls WHERE id=?", (key,)).fetchone()
                    if match and match[0] in {"RP:" + n for n in SEARCH_TOOLS} and match[1] == turn and turn_included:
                        self.db.executemany("INSERT OR IGNORE INTO paths VALUES(?,?)",
                                            ((turn, candidate) for candidate in candidate_paths(text)))
        finish_chain()
        cov["files_with_repoprompt_calls"] += int(used_rp)
        self.db.commit()

    def distribution(self, query: str, params: tuple = ()) -> dict[str, Any]:
        count, total, maximum = self.db.execute(
            "SELECT count(*),coalesce(sum(value),0),max(value) FROM (" + query + ")", params
        ).fetchone()
        if not count:
            return {"count": 0, "total": 0, "median": None, "p90": None, "p99": None, "max": None}
        def at(rank: int) -> int:
            return self.db.execute(
                "SELECT value FROM (" + query + ") ORDER BY value LIMIT 1 OFFSET ?", (*params, rank)
            ).fetchone()[0]
        median = (at((count - 1) // 2) + at(count // 2)) / 2
        return {"count": count, "total": total, "median": median,
                "p90": at(math.ceil(.90 * count) - 1), "p99": at(math.ceil(.99 * count) - 1),
                "max": maximum}

    def histogram(self, provider: str | None, metric: str) -> dict[str, int]:
        rows = self.db.execute(
            "SELECT label,sum(count) FROM events WHERE metric=? AND (? IS NULL OR provider=?) GROUP BY label",
            (metric, provider, provider),
        )
        return dict(rows)

    def summary(self) -> dict[str, Any]:
        db = self.db
        db.executescript("""
            CREATE TABLE sized AS
              SELECT o.*,coalesce(c.tool,'UNMATCHED') AS tool,c.script,c.script_rp,c.repeated
              FROM outputs o LEFT JOIN calls c ON c.id=o.call_id;
            CREATE INDEX sized_tool_scope ON sized(tool,provider,month);
            CREATE INDEX sized_scope ON sized(provider,month);
            CREATE TABLE turn_stats AS
              SELECT t.*,
                (SELECT count(*) FROM calls c WHERE c.turn_id=t.id AND included=1 AND tool LIKE 'RP:%') AS rp_calls,
                (SELECT count(*) FROM calls c WHERE c.turn_id=t.id AND included=1 AND tool IN
                  ('RP:read_file','RP:file_search','RP:get_code_structure','RP:get_file_tree')) AS exploration_calls
              FROM turns t;
            CREATE TABLE estimated_turn_stats AS
              SELECT t.*,
                rp_calls + (SELECT count(*) FROM nested_sites n JOIN calls c ON c.id=n.call_id
                  WHERE c.turn_id=t.id AND c.included=1 AND n.tool LIKE 'RP:%') AS estimated_rp_calls,
                exploration_calls + (SELECT count(*) FROM nested_sites n JOIN calls c ON c.id=n.call_id
                  WHERE c.turn_id=t.id AND c.included=1 AND n.tool IN
                  ('RP:read_file','RP:file_search','RP:get_code_structure','RP:get_file_tree')) AS estimated_exploration_calls
              FROM turn_stats t;
        """)
        total_chars, total_bytes = db.execute("SELECT coalesce(sum(chars),0),coalesce(sum(bytes),0) FROM outputs").fetchone()
        tools = []
        scopes = [(None, None)] + [(p, None) for p in self.coverage] + list(
            db.execute("SELECT provider,month FROM calls WHERE included=1 UNION SELECT provider,month FROM outputs ORDER BY 1,2")
        )
        for provider, month in scopes:
            condition = "(? IS NULL OR provider=?) AND (? IS NULL OR month=?)"
            scope = (provider, provider, month, month)
            names = db.execute("SELECT tool FROM calls WHERE included=1 AND " + condition +
                               " UNION SELECT tool FROM sized WHERE " + condition + " ORDER BY 1", scope + scope)
            scope_chars = db.execute("SELECT coalesce(sum(chars),0) FROM sized WHERE " + condition, scope).fetchone()[0]
            scope_bytes = db.execute("SELECT coalesce(sum(bytes),0) FROM sized WHERE " + condition, scope).fetchone()[0]
            for (name,) in names:
                calls = db.execute("SELECT count(*) FROM calls WHERE included=1 AND tool=? AND " + condition,
                                   (name, *scope)).fetchone()[0]
                sizes = {unit: self.distribution("SELECT " + unit + " AS value FROM sized WHERE tool=? AND " + condition,
                                                 (name, *scope)) for unit in ("chars", "bytes")}
                matched = db.execute("SELECT count(DISTINCT call_id) FROM sized WHERE tool=? AND " + condition,
                                     (name, *scope)).fetchone()[0]
                tools.append({"provider": provider or "all", "month": month or "all", "tool": name,
                              "calls": calls, "calls_with_output": matched, **sizes,
                              "share_all_output_chars": sizes["chars"]["total"] / scope_chars if scope_chars else 0,
                              "share_all_output_bytes": sizes["bytes"]["total"] / scope_bytes if scope_bytes else 0})
        providers = {}
        for provider, cov in self.coverage.items():
            cov["unmatched_outputs"] = db.execute("SELECT count(*) FROM sized WHERE provider=? AND tool='UNMATCHED'", (provider,)).fetchone()[0]
            cov["calls_without_output"] = db.execute(
                "SELECT count(*) FROM calls c WHERE included=1 AND provider=? AND NOT EXISTS(SELECT 1 FROM outputs o WHERE o.call_id=c.id)", (provider,)
            ).fetchone()[0]
            cov["outputs_for_calls_outside_window"] = db.execute(
                "SELECT count(*) FROM outputs o JOIN calls c ON c.id=o.call_id WHERE o.provider=? AND c.included=0", (provider,)
            ).fetchone()[0]
            cov["calls_without_observed_user_turn"] = db.execute(
                "SELECT count(*) FROM calls WHERE included=1 AND provider=? AND turn_id IS NULL", (provider,)
            ).fetchone()[0]
            turn_condition = "provider=?"
            turns = {}
            for label, extra in (("all_observed", ""), ("with_repoprompt", " AND rp_calls>0")):
                turns[label] = {
                    "rp_calls": self.distribution("SELECT rp_calls AS value FROM turn_stats WHERE " + turn_condition + extra, (provider,)),
                    "exploration_calls": self.distribution("SELECT exploration_calls AS value FROM turn_stats WHERE " + turn_condition + extra, (provider,)),
                }
            turns["composition_opportunities"] = db.execute(
                "SELECT count(*) FROM turn_stats WHERE provider=? AND exploration_calls>=3", (provider,)
            ).fetchone()[0]
            turns["estimated_rp_calls_including_script_sites"] = self.distribution(
                "SELECT estimated_rp_calls AS value FROM estimated_turn_stats WHERE provider=? AND estimated_rp_calls>0", (provider,)
            )
            turns["composition_opportunities_including_script_sites_estimate"] = db.execute(
                "SELECT count(*) FROM estimated_turn_stats WHERE provider=? AND estimated_exploration_calls>=3", (provider,)
            ).fetchone()[0]
            turns["exploration_chains"] = self.distribution("SELECT length AS value FROM chains WHERE provider=?", (provider,))
            read_count, known, ranged, repeated, joined = db.execute("""
                SELECT count(*),count(path),coalesce(sum(ranged),0),coalesce(sum(repeated),0),coalesce(sum(joined),0)
                FROM calls WHERE included=1 AND provider=? AND tool='RP:read_file'
            """, (provider,)).fetchone()
            repeated_chars = db.execute("SELECT coalesce(sum(chars),0) FROM sized WHERE provider=? AND tool='RP:read_file' AND repeated=1", (provider,)).fetchone()[0]
            search_outputs, truncated = db.execute("SELECT count(*),coalesce(sum(truncated),0) FROM sized WHERE provider=? AND tool='RP:file_search'", (provider,)).fetchone()
            batches = dict(db.execute("""
                SELECT n,count(*) FROM (
                  SELECT count(*) AS n FROM calls WHERE included=1 AND provider=?
                    AND batch IS NOT NULL GROUP BY batch
                ) GROUP BY n ORDER BY n
            """, (provider,)))
            usage_totals = db.execute("""
                SELECT count(*),coalesce(sum(input),0),coalesce(sum(cached_input),0),
                  coalesce(sum(cache_creation_input),0),coalesce(sum(output),0)
                FROM usage WHERE provider=?
            """, (provider,)).fetchone()
            token_totals = dict(zip(TOKEN_FIELDS, usage_totals[1:]))
            # Codex input includes cached input. Claude input excludes both cache
            # buckets, so total reported input must add them.
            reported_input = token_totals["input"] + (
                token_totals["cached_input"] + token_totals["cache_creation_input"] if provider == "Claude" else 0
            )
            chars = db.execute("SELECT coalesce(sum(chars),0) FROM outputs WHERE provider=?", (provider,)).fetchone()[0]
            usage_turns = {}
            for field in TOKEN_FIELDS:
                usage_turns[field] = self.distribution(
                    "SELECT sum(" + field + ") AS value FROM usage WHERE provider=? AND turn_id IS NOT NULL GROUP BY turn_id", (provider,)
                )
            usage_turn_count = db.execute("SELECT count(DISTINCT turn_id) FROM usage WHERE provider=?", (provider,)).fetchone()[0]
            providers[provider] = {
                "coverage": dict(cov), "turns": turns,
                "read_file": {"calls": read_count, "calls_with_path": known, "ranged": ranged,
                              "whole_file_or_unspecified": read_count - ranged, "repeated": repeated,
                              "redundancy_rate": repeated / known if known else None,
                              "repeated_output_chars": repeated_chars, "search_to_read_joins": joined,
                              "join_rate_known_paths": joined / known if known else None,
                              "ranged_share": ranged / read_count if read_count else None},
                "file_search": {"output_records": search_outputs, "truncated_output_records": truncated,
                                "truncation_rate": truncated / search_outputs if search_outputs else None},
                "parallelism": {"assistant_tool_batch_sizes": batches, "multi_call_batches": sum(v for k, v in batches.items() if k > 1)},
                "git": {"repoprompt_op_artifacts": self.histogram(provider, "rp_git"),
                        "shell_subcommands": self.histogram(provider, "shell_git"),
                        "shell": self.histogram(provider, "shell")},
                "tokens": {"observations": usage_totals[0], "totals": token_totals,
                           "reported_input_including_cache": reported_input, "turns_with_usage": usage_turn_count,
                           "per_observed_turn_with_usage": usage_turns,
                           "tool_result_chars_per_1k_reported_input": chars * 1000 / reported_input if reported_input else None},
            }
        rp_chars = sum(row["chars"]["total"] for row in tools if row["provider"] == row["month"] == "all" and row["tool"].startswith("RP:"))
        exploration_chars = sum(row["chars"]["total"] for row in tools if row["provider"] == row["month"] == "all" and row["tool"] in {"RP:" + n for n in EXPLORATION})
        script_counts = db.execute("""
            SELECT count(*),coalesce(sum(script_rp),0),coalesce(sum(promise_all),0),
              coalesce(sum(nested_count>=2),0) FROM calls WHERE included=1 AND script=1
        """).fetchone()
        exec_summary = dict(zip(("scripts", "scripts_calling_repoprompt", "promise_all_scripts", "multiple_tool_call_scripts"), script_counts))
        exec_summary["by_native_tool"] = dict(db.execute("SELECT tool,count(*) FROM calls WHERE included=1 AND script=1 GROUP BY tool"))
        exec_summary["per_native_tool"] = {tool: dict(zip(
            ("scripts", "scripts_calling_repoprompt", "promise_all_scripts", "multiple_tool_call_scripts"), values
        )) for tool, *values in db.execute("""
            SELECT tool,count(*),coalesce(sum(script_rp),0),coalesce(sum(promise_all),0),coalesce(sum(nested_count>=2),0)
            FROM calls WHERE included=1 AND script=1 GROUP BY tool
        """)}
        exec_summary["nested_call_sites_by_tool"] = self.histogram("Codex", "nested_tools")
        exec_summary["output_sizes"] = self.distribution("SELECT chars AS value FROM sized WHERE script=1")
        exec_summary["repoprompt_script_output_sizes"] = self.distribution("SELECT chars AS value FROM sized WHERE script_rp=1")
        exec_summary["direct_repoprompt_output_sizes"] = self.distribution("SELECT chars AS value FROM sized WHERE tool LIKE 'RP:%'")
        exec_summary["output_bytes"] = self.distribution("SELECT bytes AS value FROM sized WHERE script=1")
        return {
            "schema_version": SCHEMA_VERSION,
            "window": {"since_inclusive": self.since.isoformat(), "until_exclusive": self.until.isoformat()},
            "totals": {"tool_output_chars": total_chars, "tool_output_utf8_bytes": total_bytes,
                       "chars_div_4_estimate_not_billed_tokens": total_chars / 4,
                       "repoprompt_output_chars": rp_chars,
                       "repoprompt_share": rp_chars / total_chars if total_chars else 0,
                       "exploration_output_chars": exploration_chars,
                       "exploration_share_all": exploration_chars / total_chars if total_chars else 0,
                       "exploration_share_repoprompt": exploration_chars / rp_chars if rp_chars else 0},
            "tools": tools, "providers": providers, "codex_exec": exec_summary,
            "coverage_notes": [
                "Window is [since,until) in UTC; invocations use call time, output sizes use output time. Pre-window calls remain available for attribution and session read history.",
                "Calls are deduplicated by provider + call ID globally, including replayed/forked histories. Exact canonical message/tool/usage records and identical outputs per call are deduplicated. Legitimate identical repeated fragments cannot be distinguished.",
                "Percentiles are exact nearest-rank over output records, not per-invocation combined output; median averages middle values. Missing outputs are not zero-size observations.",
                "Text/list blocks concatenate logged text; non-text blocks/objects use ensure_ascii=False JSON. UTF-8 bytes exclude JSONL/framing; binary blocks may be encoded payload, not model-visible text.",
                "Codex script analysis includes exec/js input and legacy js arguments.code, even with a non-RP MCP namespace. Per-tool labels still honor the namespace; legacy js may appear as MCP_OTHER:js. Nested exec/js tools are lexical call sites, not runtime invocations. Comments/strings are ignored; dynamic names, aliases, loops, computed dispatch and template interpolations are unknown. Nested outputs stay solely under native exec/js, never RP tool sizes.",
                "Per-turn statistics include observed user messages (Claude list text too), exclude tool-result-only user messages, and report zero-call turns separately. Missing initial user boundaries are excluded; concurrent/sidechain and copied-history ownership cannot be fully reconstructed.",
                "Direct per-turn counts exclude nested calls; an additional including-static-script-sites estimate is reported separately. Exploration chains are maximal adjacent direct exploration invocations in log order; outputs/reasoning do not break chains. Nested call sites are excluded from turn/chains/path/Git metrics.",
                "Search-to-read is a literal path-token match from an earlier same-turn search/structure/tree output. Hashes only are kept. No basename/root inference; paths with spaces, indented trees and aliases can be missed; incidental mentions can match. It is a mechanical proxy, not proof of a dependency.",
                "Read ranges mean presence of non-null start_line/limit/end_line/line_range. Repeats use exact normalized path per logged session, including pre-window history; they do not prove avoidable redundancy or unchanged content.",
                "Search truncation heuristic: explicit result/output truncation, max_results reached, or reached/exceeded size/result-limit markers; JSON true truncated/isTruncated/limitReached/sizeLimitReached/resultLimitReached/hasMore or positive omittedCount/omittedResults/truncatedCount. May include source-text false positives and miss unknown markers.",
                "Claude parallel batches group distinct tool IDs per assistant message ID; Codex groups consecutive direct function calls before first output or assistant/user message. Neither proves simultaneous execution.",
                "Shell Git is lexical command-position counting with separators and common global flags, not shell execution; aliases, variables, nested quoted shells, scripts and Git called inside exec/js are not covered.",
                "Codex tokens use cumulative total_token_usage deltas, not repeatedly summing last_token_usage. Initial/reset checkpoints use last only and flag gaps; decreases do not establish billing resets. Claude streamed usage takes per-message field maxima and cache buckets are separate from input.",
                "Token totals are provider-reported, not billing evidence. Only turns with valid nonzero usage enter token distributions; chars per 1k input is a descriptive ratio over all logged outputs, not causal cost/savings. Missing usage, inherited histories and compaction can affect coverage.",
                "Only explicit/default native JSONL roots are read. Web/search built-in events without function-call output, deleted logs, app-only logs, unknown schemas and skipped oversized/malformed records are not measured.",
                "Temporary SQLite stores hashes/numeric aggregates only. Reports contain no log paths, prompts, arguments, output text, session IDs, server/workspace names. No app-source changes or live structuredContent probe.",
            ],
        }


def analyze_roots(
    claude_roots: Sequence[Path | str], codex_roots: Sequence[Path | str],
    since: str = DEFAULT_SINCE, until: str = DEFAULT_UNTIL,
    max_line_bytes: int = MAX_LINE_BYTES,
) -> dict[str, Any]:
    start, end = timestamp(since), timestamp(until)
    if start is None or end is None or start >= end:
        raise AnalyzerError("since/until must be timezone-qualified ISO timestamps with since < until")
    if not 0 < max_line_bytes <= 64 * 1024 * 1024:
        raise AnalyzerError("max-line-bytes must be between 1 and 67108864")
    with tempfile.TemporaryDirectory(prefix="rpce-tool-usage-") as directory:
        with closing(sqlite3.connect(str(Path(directory) / "aggregate.sqlite"))) as db:
            analyzer = Analyzer(db, start, end, max_line_bytes)
            for provider, roots in (("Claude", claude_roots), ("Codex", codex_roots)):
                analyzer.coverage[provider]["input_roots"] = len(roots)
                analyzer.coverage[provider]["missing_roots"] = sum(not Path(r).expanduser().exists() for r in roots)
                for path in jsonl_files(roots):
                    analyzer.scan(provider, path)
            return analyzer.summary()


def render_markdown(summary: dict[str, Any]) -> str:
    total = summary["totals"]
    lines = [
        "# Offline tool-usage baseline",
        "", "Aggregate-only local evidence; characters / 4 is an estimate, never billed tokens.",
        "", f"Window: {summary['window']['since_inclusive']} ≤ timestamp < {summary['window']['until_exclusive']}.",
        "", "## a–b. Tool output",
        "", f"All tool output: **{total['tool_output_chars']:,} chars**, **{total['tool_output_utf8_bytes']:,} UTF-8 bytes**.",
        f"RepoPrompt: **{total['repoprompt_share']:.2%}**; exploration: **{total['exploration_share_all']:.2%}** of all / **{total['exploration_share_repoprompt']:.2%}** of RP.",
        f"Chars / 4 estimate (not billed): {total['chars_div_4_estimate_not_billed_tokens']:,.0f}.",
    ]
    def tool_table(rows: Iterable[dict[str, Any]]) -> None:
        lines.extend(["", "| Tool | Calls | Outputs | Chars | UTF-8 bytes | Char / byte share | Median / p90 / p99 / max chars | Median / p90 / p99 / max bytes |",
                      "|---|---:|---:|---:|---:|---:|---|---|"])
        for row in rows:
            d = row["chars"]
            dist = " / ".join(f"{d[k]:,.0f}" if d[k] is not None else "—" for k in ("median", "p90", "p99", "max"))
            byte_dist = " / ".join(f"{row['bytes'][k]:,.0f}" if row["bytes"][k] is not None else "—" for k in ("median", "p90", "p99", "max"))
            lines.append(f"| {row['tool']} | {row['calls']:,} | {d['count']:,} | {d['total']:,} | {row['bytes']['total']:,} | {row['share_all_output_chars']:.2%} / {row['share_all_output_bytes']:.2%} | {dist} | {byte_dist} |")
    tool_table(r for r in summary["tools"] if r["provider"] == r["month"] == "all")
    for provider, data in summary["providers"].items():
        lines.extend(["", f"## {provider}: c–g, i–k", ""])
        turns = data["turns"]
        rp = turns["with_repoprompt"]["rp_calls"]
        lines.append(f"Observed user turns: {turns['all_observed']['rp_calls']['count']:,}; with RP: {rp['count']:,}; RP calls/turn median/p90: {rp['median']} / {rp['p90']}; ≥3 exploration calls: {turns['composition_opportunities']:,}.")
        lines.append("All-turn RP-call distribution: " + json.dumps(turns["all_observed"]["rp_calls"], sort_keys=True))
        lines.append("RP-call distribution including static script call sites (estimate): " + json.dumps(turns["estimated_rp_calls_including_script_sites"], sort_keys=True))
        lines.append(f"Composition opportunities including static script sites (estimate): {turns['composition_opportunities_including_script_sites_estimate']:,}.")
        for name in ("read_file", "file_search", "parallelism", "git", "tokens", "coverage"):
            lines.extend(["", f"### {name}", "", "```json", json.dumps(data[name], indent=2, sort_keys=True), "```"])
        chains = turns["exploration_chains"]
        lines.extend(["", "Exploration-chain distribution: " + json.dumps(chains, sort_keys=True)])
        lines.extend(["", "### Provider tool breakdown"])
        tool_table(r for r in summary["tools"] if r["provider"] == provider and r["month"] == "all")
    lines.extend(["", "## h. Codex native exec/js", "", "```json", json.dumps(summary["codex_exec"], indent=2, sort_keys=True), "```",
                  "", "Native script and direct-call distributions are descriptive, not paired or causal savings evidence.",
                  "", "## a. Monthly/provider breakdown"])
    groups = sorted({(r["provider"], r["month"]) for r in summary["tools"] if r["month"] != "all"})
    for provider, month in groups:
        lines.extend(["", f"### {provider} · {month}"])
        tool_table(r for r in summary["tools"] if (r["provider"], r["month"]) == (provider, month))
    lines.extend(["", "## k. Coverage table", "",
                  "| Provider | Files scanned | Files with RP calls (direct or script sites) | Malformed lines | Oversized lines | Unmatched outputs | Records outside window | Duplicate records |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|"])
    for provider, data in summary["providers"].items():
        cov = data["coverage"]
        values = [cov.get(k, 0) for k in ("files_scanned", "files_with_repoprompt_calls", "malformed_lines", "oversized_lines", "unmatched_outputs", "records_outside_window", "duplicate_records")]
        lines.append("| " + provider + " | " + " | ".join(f"{n:,}" for n in values) + " |")
    lines.extend(["", "## Coverage and methodology"])
    lines.extend("- " + note for note in summary["coverage_notes"])
    lines.append("")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Privacy-safe offline tool-usage aggregates; Python standard library only.")
    parser.add_argument("--claude-root", action="append", help="Claude JSONL root/file; repeatable, replaces default")
    parser.add_argument("--codex-root", action="append", help="Codex JSONL root/file; repeatable, replaces both defaults")
    parser.add_argument("--since", default=DEFAULT_SINCE)
    parser.add_argument("--until", default=DEFAULT_UNTIL)
    parser.add_argument("--max-line-bytes", type=int, default=MAX_LINE_BYTES)
    parser.add_argument("--json", type=Path, help="write aggregate JSON")
    parser.add_argument("--markdown", type=Path, help="write Markdown instead of stdout")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    home = Path.home()
    try:
        summary = analyze_roots(
            args.claude_root or [home / ".claude/projects"],
            args.codex_root or [home / ".codex/sessions", home / ".codex/archived_sessions"],
            args.since, args.until, args.max_line_bytes,
        )
        if args.json:
            args.json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        markdown = render_markdown(summary)
        if args.markdown:
            args.markdown.write_text(markdown, encoding="utf-8")
        else:
            sys.stdout.write(markdown)
    except KeyboardInterrupt:
        print("error: analysis interrupted", file=sys.stderr)
        return 130
    except AnalyzerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except Exception:
        # Never disclose an input record or private source pathname in a traceback.
        print("error: analysis or report writing failed", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
