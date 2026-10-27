#!/usr/bin/env python3
"""Opt-in live acceptance for Claude native RepoPrompt MCP loss and recovery.

Runs against an already-running RepoPrompt CE DEBUG app through ``rpce-cli-debug``.
This script never launches, quits, relaunches, or switches the app, never targets a
process by name, and only signals a helper PID after the kill guard passes (see
``kill_refusal``): its start time matches the one captured at admission, its
executable is the RepoPrompt MCP helper, its live ancestry contains the Claude PID
that owns the run and that process's arguments look like the Claude CLI, and it is
neither this script nor one of its ancestors.

Residual race: macOS has no pidfd, so between the final start-time re-check and
``os.kill`` the helper could exit and its PID be reused. The window is a few
milliseconds after a fresh re-check; a reused PID inside it is improbable but not
impossible, so run this only on a dedicated test machine/session. The start-time
comparison is second-granular: the app reports the helper start as
``seconds.microseconds``, but ``ps -o lstart`` only gives whole seconds, so a PID
reused within the same second as the original start would pass that one check (the
executable, Claude-ancestry and Claude-arguments checks still apply).

Scenarios (each uses its own fresh Agent session, cleaned up at the end):

  idle-kill        SIGKILL the run's ``repoprompt-mcp`` helper while the session is
                   idle, then steer.        Expect helper_exited, Claude restart.
  midturn-kill     SIGKILL the helper while a turn is running, then steer.
                   Expect a non-terminal error, then Claude restart on the steer.
                   Aborts before killing when turn 1 is not running (for example
                   waiting for input on a permission prompt).
  watchdog         DEBUG ``force_execution_watchdog_abort`` on the idle helper
                   connection, then steer. Expect the watchdog loss, Claude restart.
  soft-disconnect  DEBUG ``soft_disconnect_connection`` (no kill). Expect the helper
                   to reconnect, no loss, and no Claude restart.
  baseline         Two plain turns. Expect no loss and no Claude restart.

Evidence per scenario: the transcript error via ``agent_manage get_log``; the
Claude PID before/after and its ``--resume``/``--session-id`` conversation ID; the
turn-2 reply in an assistant message; a turn-2 RepoPrompt tool completion that is
not an error (``get_log`` of the turn-2 slice plus a run-routed tool-call count
increase across the steer); turn 1 not replayed (its prompt occurs exactly once in
Claude's own ``<projects>/**/<conversation-id>.jsonl``, read-only); and, when
``--app-log`` is given, ``mcp.health.*`` lines written during the scenario.

Example:
  python3 Scripts/claude_mcp_recovery_live.py \\
      --cli /abs/path/to/rpce-cli-debug --window-id 1 \\
      --confirm-dedicated-window --scenario all

Self-test (no app, no processes signalled):
  python3 -I Scripts/claude_mcp_recovery_live_selftest.py
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import omp_qualification_support as support  # noqa: E402 - after the script-directory path setup


DIAGNOSTICS_TOOL = "__repoprompt_debug_diagnostics"
SCENARIOS = ("idle-kill", "midturn-kill", "watchdog", "soft-disconnect", "baseline")
DISCONNECT_MARKER = "RepoPrompt MCP disconnected from Claude"
REASON_MARKERS = {
    "idle-kill": "the RepoPrompt MCP helper process exited",
    "midturn-kill": "the RepoPrompt MCP helper process exited",
    "watchdog": "did not stop after its deadline",
}
# The tool every turn calls; transcript tool names may carry an MCP server prefix.
PROBE_TOOL = "get_file_tree"
# The executable the app writes into Claude's MCP config is the user-space CLI symlink
# (`repoprompt_ce_cli_debug` / `repoprompt_ce_cli`) to the bundled `repoprompt-mcp`.
HELPER_EXECUTABLE_NAMES = ("repoprompt-mcp", "repoprompt_ce_cli_debug", "repoprompt_ce_cli")
# macOS truncates the kernel process name (`p_comm`) to MAXCOMLEN characters.
MAXCOMLEN = 16
# The manager's helper-exit grace is 2 s and the route-restore deadline 20 s; a 1 s
# poller resolves them. Leave headroom before steering.
HELPER_EXIT_SETTLE_SECONDS = 6.0
ROUTE_RESTORE_SETTLE_SECONDS = 25.0
MAX_ANCESTRY_DEPTH = 16


class LiveAcceptanceError(RuntimeError):
    pass


# MARK: - Identifiers


def uuid_key(value: Any) -> str | None:
    """Canonical lowercase form of a UUID string, or None. Swift reports `uuidString`
    in uppercase; every comparison goes through this on both sides."""
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def strict_uuid(value: Any, label: str) -> str:
    key = uuid_key(value)
    if key is None:
        raise LiveAcceptanceError(f"{label} is not a UUID string")
    return key


# MARK: - CLI transport


def call(cli: Path, window_id: int, tool: str, payload: dict[str, Any], timeout: float = 30) -> dict[str, Any]:
    command = [str(cli), "--raw-json", "-w", str(window_id), "-c", tool, "-j", json.dumps(payload, separators=(",", ":"))]
    returncode, stdout, stderr = support._bounded_process(command, timeout, support.MAX_COMMAND_OUTPUT)
    if returncode != 0:
        raise LiveAcceptanceError(f"{tool} exited {returncode}: {stderr.decode(errors='replace')[:512]}")
    raw = support._strict_json_loads(stdout)
    if tool == DIAGNOSTICS_TOOL:
        discriminator = f"diagnostic:{payload.get('op')}"
    elif tool == "agent_run":
        discriminator = "agent_run"
    elif tool == "agent_manage":
        discriminator = f"agent_manage:{payload.get('op')}"
    else:
        raise LiveAcceptanceError(f"unsupported tool {tool!r}")
    try:
        return support._normalized_response(raw, discriminator)
    except support.SupportError as error:
        raise LiveAcceptanceError(f"{discriminator}: {error}") from error


# MARK: - Process inspection (read-only `ps`, never by name)


def ps_field(pid: int, field_name: str) -> str | None:
    result = subprocess.run(
        ["/bin/ps", "-ww", "-o", f"{field_name}=", "-p", str(pid)],
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C"},
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def process_start_epoch_seconds(pid: int) -> int | None:
    """The process start time in whole epoch seconds (`ps -o lstart` has no sub-second
    field), compared with the integer part of the app's ``seconds.microseconds`` start."""
    lstart = ps_field(pid, "lstart")
    if lstart is None:
        return None
    try:
        return int(time.mktime(time.strptime(" ".join(lstart.split()), "%a %b %d %H:%M:%S %Y")))
    except ValueError:
        return None


def parent_pid(pid: int) -> int | None:
    raw = ps_field(pid, "ppid")
    try:
        return None if raw is None else int(raw)
    except ValueError:
        return None


def live_ancestry(pid: int) -> list[int]:
    chain: list[int] = []
    current = pid
    for _ in range(MAX_ANCESTRY_DEPTH):
        parent = parent_pid(current)
        if parent is None or parent <= 1 or parent == current:
            break
        chain.append(parent)
        current = parent
    return chain


def process_alive(pid: int) -> bool:
    stat = ps_field(pid, "stat")
    return stat is not None and not stat.startswith("Z")


def conversation_flag_value(args: str | None, flags: Iterable[str]) -> str | None:
    """The value of the first of `flags` (in `flags` order) in a command line, accepting
    both `--flag value` and `--flag=value`."""
    if args is None:
        return None
    tokens = args.split()
    for flag in flags:
        for index, token in enumerate(tokens):
            if token == flag and index + 1 < len(tokens):
                return tokens[index + 1]
            if token.startswith(flag + "="):
                return token.split("=", 1)[1]
    return None


def conversation_id_from_marker(projects_dir: Path, marker: str, since_epoch: float) -> str | None:
    """The conversation ID (file stem) of the one Claude transcript, modified since
    `since_epoch`, that contains `marker`. A first launch carries no conversation ID on
    its command line, so the unique per-scenario turn-1 marker locates it (read-only)."""
    matches: list[Path] = []
    for path in projects_dir.rglob("*.jsonl"):
        try:
            if not path.is_file() or path.stat().st_mtime < since_epoch:
                continue
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                if any(marker in line for line in handle):
                    matches.append(path)
        except OSError:
            continue
    return uuid_key(matches[0].stem) if len(matches) == 1 else None


def claude_conversation_id(pid: int, flags: Iterable[str] = ("--resume", "--session-id")) -> str | None:
    """The canonical `--resume` (or first-launch `--session-id`) conversation ID of a
    Claude process; pass `flags=("--resume",)` for the resume ID only."""
    return uuid_key(conversation_flag_value(ps_field(pid, "args"), flags))


def is_helper_executable(name: str | None) -> bool:
    """Whether a `ps` executable path (`comm`) or kernel accounting name (`ucomm`) names
    the RepoPrompt MCP helper, allowing for the kernel's MAXCOMLEN truncation of `ucomm`."""
    if not name:
        return False
    base = os.path.basename(name.strip())
    if base in HELPER_EXECUTABLE_NAMES:
        return True
    return len(base) >= MAXCOMLEN - 1 and any(known.startswith(base) for known in HELPER_EXECUTABLE_NAMES)


def looks_like_claude_cli(args: str | None) -> bool:
    """Whether a command line looks like the app's Claude CLI launch: stream-json input and
    output plus either a `--resume`/`--session-id` conversation or an `--mcp-config` from
    the app's `MCP/LaunchConfigs/` directory (a first launch carries no conversation flag;
    only restarts add `--resume`). The executable may be a custom command or wrapper, so
    its name is not required."""
    if not args:
        return False
    tokens = args.split()

    def flag_value(flag: str) -> str | None:
        return conversation_flag_value(args, (flag,))

    has_conversation = any(
        token in ("--resume", "--session-id") or token.startswith(("--resume=", "--session-id=")) for token in tokens
    )
    # The config path contains spaces ("Application Support/RepoPrompt CE/..."), so match
    # the flag and the app's launch-config directory rather than a split token value.
    has_app_mcp_config = (
        any(token == "--mcp-config" or token.startswith("--mcp-config=") for token in tokens)
        and "/MCP/LaunchConfigs/" in args
    )
    return (
        flag_value("--input-format") == "stream-json"
        and flag_value("--output-format") == "stream-json"
        and (has_conversation or has_app_mcp_config)
    )


# MARK: - Helper discovery


@dataclass
class HelperIdentity:
    connection_id: str
    pid: int
    start: str
    ancestors: list[int]

    @property
    def claude_pid(self) -> int:
        return self.ancestors[0]

    @property
    def start_seconds(self) -> int:
        return int(self.start.split(".", 1)[0])


def connection_rows(cli: Path, window_id: int) -> list[dict[str, Any]]:
    payload = call(cli, window_id, DIAGNOSTICS_TOOL, {"op": "connections"})
    rows = payload.get("connections")
    if not isinstance(rows, list):
        raise LiveAcceptanceError("connections payload has no rows")
    return [row for row in rows if isinstance(row, dict)]


def helper_from_row(row: dict[str, Any]) -> HelperIdentity | None:
    pid = row.get("helper_peer_pid")
    start = row.get("helper_process_start")
    ancestors = row.get("helper_ancestor_pids")
    connection_id = uuid_key(row.get("id"))
    if (
        type(pid) is not int
        or pid <= 1
        or not isinstance(start, str)
        or not re.fullmatch(r"\d+(\.\d+)?", start)
        or not isinstance(ancestors, list)
        or not ancestors
        or not all(type(item) is int for item in ancestors)
        or connection_id is None
    ):
        return None
    return HelperIdentity(connection_id=connection_id, pid=pid, start=start, ancestors=list(ancestors))


def select_run_helpers(
    rows: Iterable[dict[str, Any]],
    run_ids: set[str],
    claude_pid: int | None,
    exclude_connection_ids: frozenset[str] = frozenset(),
) -> list[HelperIdentity]:
    """Helper connections routed to one of `run_ids` (canonical keys), optionally under
    `claude_pid`, excluding `exclude_connection_ids` (canonical keys)."""
    candidates: list[HelperIdentity] = []
    for row in rows:
        if uuid_key(row.get("run_id")) not in run_ids:
            continue
        helper = helper_from_row(row)
        if helper is None or helper.connection_id in exclude_connection_ids:
            continue
        if claude_pid is not None and claude_pid not in helper.ancestors:
            continue
        candidates.append(helper)
    return candidates


def tool_call_counts_by_connection(rows: Iterable[dict[str, Any]]) -> dict[str, int]:
    """Non-bookkeeping RepoPrompt tool calls per live connection (canonical keys). The app
    clears a connection's run route when the run ends, so counts are keyed by connection,
    not by run."""
    counts: dict[str, int] = {}
    for row in rows:
        connection_id = uuid_key(row.get("id"))
        count = row.get("non_bookkeeping_tool_call_count")
        if connection_id is not None and type(count) is int:
            counts[connection_id] = count
    return counts


def find_run_helper(
    cli: Path,
    window_id: int,
    run_ids: set[str],
    claude_pid: int | None,
    timeout: float,
    exclude_connection_ids: frozenset[str] = frozenset(),
) -> HelperIdentity:
    deadline = time.monotonic() + timeout
    last_candidates: list[HelperIdentity] = []
    while time.monotonic() < deadline:
        candidates = select_run_helpers(connection_rows(cli, window_id), run_ids, claude_pid, exclude_connection_ids)
        if len(candidates) == 1:
            return candidates[0]
        last_candidates = candidates
        time.sleep(0.5)
    raise LiveAcceptanceError(
        f"expected exactly one run-routed helper connection, found {len(last_candidates)}"
    )


# MARK: - Kill guard


def kill_refusal(
    helper: HelperIdentity,
    *,
    observed_start: int | None,
    executable: str | None,
    accounting_name: str | None,
    live_chain: list[int],
    args_by_pid: dict[int, str | None],
    own_pid: int,
    own_ancestors: list[int],
) -> str | None:
    """Why the captured helper must not be signalled, or None when every check passes."""
    if helper.pid <= 1:
        return f"pid {helper.pid} is not a helper pid"
    if helper.pid == own_pid or helper.pid in own_ancestors:
        return f"pid {helper.pid} is this script or one of its ancestors"
    if observed_start != helper.start_seconds:
        return f"start {observed_start} != captured {helper.start_seconds}"
    if not (is_helper_executable(executable) or is_helper_executable(accounting_name)):
        return f"executable {executable!r} (ucomm {accounting_name!r}) is not the RepoPrompt MCP helper"
    if helper.claude_pid not in live_chain:
        return f"live ancestry {live_chain} lacks Claude pid {helper.claude_pid}"
    if not looks_like_claude_cli(args_by_pid.get(helper.claude_pid)):
        return f"ancestor {helper.claude_pid} does not look like the Claude CLI"
    return None


def verify_and_kill_helper(helper: HelperIdentity) -> None:
    """SIGKILL exactly the captured helper after `kill_refusal` passes (see the module
    docstring for the residual check-then-kill race)."""
    live_chain = live_ancestry(helper.pid)
    # Both names come whole from `ps` fields; a command line is never split on spaces
    # (helper paths live under "Application Support").
    refusal = kill_refusal(
        helper,
        observed_start=process_start_epoch_seconds(helper.pid),
        executable=ps_field(helper.pid, "comm"),
        accounting_name=ps_field(helper.pid, "ucomm"),
        live_chain=live_chain,
        args_by_pid={pid: ps_field(pid, "args") for pid in live_chain},
        own_pid=os.getpid(),
        own_ancestors=live_ancestry(os.getpid()),
    )
    if refusal is not None:
        raise LiveAcceptanceError(f"refusing to kill pid {helper.pid}: {refusal}")
    # Re-check the identity immediately before signalling to keep the race window minimal.
    if process_start_epoch_seconds(helper.pid) != helper.start_seconds:
        raise LiveAcceptanceError(f"refusing to kill pid {helper.pid}: identity changed during verification")
    os.kill(helper.pid, signal.SIGKILL)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not process_alive(helper.pid) or process_start_epoch_seconds(helper.pid) != helper.start_seconds:
            return
        time.sleep(0.1)
    raise LiveAcceptanceError(f"helper pid {helper.pid} survived SIGKILL")


# MARK: - Transcript evidence


# `get_log` (`AgentTranscriptServices` fork transcript) writes row text raw, unescaped
# (`&`, `<dir>` and quotes appear literally), and escapes only attribute values such as
# the tool `name`. So row text is never entity-decoded; attribute values are.
# Built by concatenation so the entity spellings stay literal in this source.
_AMP = "&"
_XML_ENTITIES = (
    (_AMP + "quot;", '"'),
    (_AMP + "apos;", "'"),
    (_AMP + "lt;", "<"),
    (_AMP + "gt;", ">"),
    (_AMP + "amp;", _AMP),
)


def _decode_xml(text: str) -> str:
    for entity, replacement in _XML_ENTITIES:
        text = text.replace(entity, replacement)
    return text


def tagged_texts(transcript_xml: str, tag: str) -> list[str]:
    """Raw texts of `<tag ...>text</tag>` rows of a `get_log` transcript (`user`,
    `assistant`, `system` or `error`), exactly as the app wrote them (not decoded)."""
    pattern = rf"(?s)<{re.escape(tag)}(?:\s[^>]*)?>(.*?)</{re.escape(tag)}>"
    return re.findall(pattern, transcript_xml)


def tool_results(transcript_xml: str) -> list[tuple[str, str]]:
    """(tool name, status word) for every `<tool_result name=".." status=".."/>` row."""
    results: list[tuple[str, str]] = []
    for attributes in re.findall(r"<tool_result\b([^>]*)/>", transcript_xml):
        name = re.search(r'(?:^|\s)name\s*=\s*"([^"]*)"', attributes)
        status = re.search(r'(?:^|\s)status\s*=\s*"([^"]*)"', attributes)
        if name and status:
            results.append((_decode_xml(name.group(1)), status.group(1)))
    return results


def tool_succeeded(transcript_xml: str, tool_suffix: str = PROBE_TOOL) -> bool:
    """A completed, non-error result for the tool, and no failed result for it."""
    statuses = [status for name, status in tool_results(transcript_xml) if name.endswith(tool_suffix)]
    return "success" in statuses and "failed" not in statuses


def reply_in_assistant_message(transcript_xml: str, reply: str) -> bool:
    return any(reply in text for text in tagged_texts(transcript_xml, "assistant"))


def count_user_prompt_occurrences(lines: Iterable[str], marker: str) -> int:
    """User-role prompt records in a Claude JSONL transcript that contain `marker`."""
    count = 0
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("type") != "user":
            continue
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "\n".join(
                block.get("text", "")
                for block in content
                if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str)
            )
        else:
            continue
        if marker in text:
            count += 1
    return count


def find_claude_transcript(projects_dir: Path, conversation_id: str) -> Path | None:
    """The single `<projects_dir>/**/<conversation_id>.jsonl`, or None (missing or ambiguous)."""
    name = f"{strict_uuid(conversation_id, 'conversation_id')}.jsonl"
    matches = [path for path in projects_dir.rglob(name) if path.is_file()]
    return matches[0] if len(matches) == 1 else None


def default_claude_projects_dir() -> Path:
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(config_dir) if config_dir else Path.home() / ".claude") / "projects"


# MARK: - Agent session helpers


def validate_model(cli: Path, window_id: int, model_id: str) -> None:
    payload = call(cli, window_id, "agent_manage", {"op": "list_agents"})
    known: set[str] = set()
    for agent in payload.get("agents", []):
        if not isinstance(agent, dict):
            continue
        for model in agent.get("models", []) or []:
            if isinstance(model, dict) and isinstance(model.get("model_id"), str):
                known.add(model["model_id"])
    if model_id not in known:
        claude = sorted(item for item in known if item.startswith("claudeCode:"))
        raise LiveAcceptanceError(f"model {model_id!r} is not offered by list_agents; Claude models: {claude}")
    if not model_id.startswith("claudeCode:"):
        raise LiveAcceptanceError("model must be a Claude Code native model (claudeCode:*)")


WAITING_FOR_INPUT_MESSAGE = (
    "session is waiting_for_input (most likely a tool permission prompt); answer or allow it "
    "in the app, or use a model/profile that runs the probe tools without prompting"
)


def session_status(cli: Path, window_id: int, session_id: str) -> str | None:
    status = call(cli, window_id, "agent_run", {"op": "poll", "session_id": session_id}, 15).get("status")
    return status if isinstance(status, str) else None


def wait_terminal(cli: Path, window_id: int, session_id: str, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        last = call(cli, window_id, "agent_run", {"op": "wait", "session_id": session_id, "timeout": 2}, 15)
        if last.get("status") in {"completed", "cancelled", "failed"}:
            return last
        if last.get("status") == "waiting_for_input":
            raise LiveAcceptanceError(WAITING_FOR_INPUT_MESSAGE)
    raise LiveAcceptanceError(f"session did not reach a terminal state; last status {None if last is None else last.get('status')!r}")


def run_id_of(payload: dict[str, Any]) -> str | None:
    return uuid_key(payload.get("run_id"))


def await_run_id(
    cli: Path,
    window_id: int,
    session_id: str,
    payload: dict[str, Any],
    exclude: set[str],
    timeout: float = 30,
) -> str | None:
    """The run ID of a `start`/`steer`. The raw-JSON `start` reply omits `run_id`
    (a `steer` reply carries it), while `poll` reports the session's current run, so
    poll (bounded) until it names a run not in `exclude`."""
    direct = run_id_of(payload)
    if direct is not None and direct not in exclude:
        return direct
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        polled = run_id_of(call(cli, window_id, "agent_run", {"op": "poll", "session_id": session_id}, 30))
        if polled is not None and polled not in exclude:
            return polled
        time.sleep(0.5)
    return None


def get_log(cli: Path, window_id: int, session_id: str, offset: int = 0) -> dict[str, Any]:
    return call(cli, window_id, "agent_manage", {
        "op": "get_log", "session_id": session_id, "offset": offset, "limit": 100,
    }, 30)


def total_turns_of(payload: dict[str, Any]) -> int:
    value = payload.get("total_turns")
    if type(value) is not int or value < 0:
        raise LiveAcceptanceError("get_log returned no total_turns")
    return value


def transcript_slice(payload: dict[str, Any], offset: int) -> str:
    """The transcript of a `get_log` page that starts at turn `offset`. Turns are counted
    oldest-first, so offset N (N = the turn count before a steer) is the steer's turn."""
    if payload.get("turn_offset") != offset:
        raise LiveAcceptanceError(f"get_log returned turn_offset {payload.get('turn_offset')!r}, expected {offset}")
    xml = payload.get("transcript_xml")
    if not isinstance(xml, str):
        raise LiveAcceptanceError("get_log returned no transcript_xml")
    return xml


def transcript(cli: Path, window_id: int, session_id: str, offset: int = 0) -> str:
    return transcript_slice(get_log(cli, window_id, session_id, offset), offset)


def total_turns(cli: Path, window_id: int, session_id: str) -> int:
    return total_turns_of(get_log(cli, window_id, session_id))


def turn_prompt(marker: str, reply: str) -> str:
    return (
        f"[{marker}] Call mcp__RepoPromptCE__{PROBE_TOOL} exactly once with max_depth 1, "
        f"then reply with exactly {reply} and nothing else."
    )


def midturn_prompt(marker: str, reply: str) -> str:
    return (
        f"[{marker}] First call mcp__RepoPromptCE__{PROBE_TOOL} once with max_depth 1. "
        "Then run the shell command `sleep 30` with your Bash tool. "
        f"Then reply with exactly {reply}. Do not retry failed tools."
    )


def cleanup_session(cli: Path, window_id: int, session_id: str, scenario: str) -> None:
    """Best-effort cancel and cleanup. A KeyboardInterrupt still gets one best-effort cancel
    and is then re-raised; other errors are reported and swallowed."""

    def cancel_if_active() -> None:
        if session_status(cli, window_id, session_id) in {"running", "waiting_for_input"}:
            call(cli, window_id, "agent_run", {"op": "cancel", "session_id": session_id}, 30)

    try:
        cancel_if_active()
    except KeyboardInterrupt:
        try:
            call(cli, window_id, "agent_run", {"op": "cancel", "session_id": session_id}, 30)
        except Exception as error:  # noqa: BLE001 - best-effort cleanup
            print(f"WARNING: [{scenario}] cancel after interrupt failed: {error}", file=sys.stderr)
        raise
    except Exception as error:  # noqa: BLE001 - best-effort cleanup
        print(f"WARNING: [{scenario}] cancel failed: {error}", file=sys.stderr)
    try:
        call(cli, window_id, "agent_manage", {"op": "cleanup_sessions", "session_ids": [session_id]}, 30)
    except Exception as error:  # noqa: BLE001 - best-effort cleanup
        print(f"WARNING: [{scenario}] session cleanup failed: {error}", file=sys.stderr)


# MARK: - Scenario


@dataclass
class ScenarioResult:
    scenario: str
    checks: list[tuple[str, bool | None, str]] = field(default_factory=list)
    error: str | None = None

    def check(self, name: str, ok: bool | None, detail: str = "") -> None:
        self.checks.append((name, ok, detail))

    @property
    def passed(self) -> bool:
        return self.error is None and all(ok is not False for _, ok, _ in self.checks)


def health_lines_since(app_log: Path | None, offset: int) -> list[str]:
    if app_log is None:
        return []
    try:
        with app_log.open("rb") as handle:
            handle.seek(offset)
            data = handle.read(4 * 1024 * 1024)
    except OSError:
        return []
    return [line for line in data.decode(errors="replace").splitlines() if "mcp.health" in line]


def log_offset(app_log: Path | None) -> int:
    if app_log is None:
        return 0
    try:
        return app_log.stat().st_size
    except OSError:
        return 0


def run_scenario(args: argparse.Namespace, scenario: str) -> ScenarioResult:
    result = ScenarioResult(scenario=scenario)
    cli, window_id = args.cli, args.window_id
    nonce = uuid.uuid4().hex[:10]
    turn1_marker, turn1_reply = f"TURN1-PROMPT-{nonce}", f"TURN1_OK_{nonce}"
    turn2_marker, turn2_reply = f"TURN2-PROMPT-{nonce}", f"TURN2_OK_{nonce}"
    session_id: str | None = None
    scenario_started = time.time() - 5
    offset = log_offset(args.app_log)
    expects_loss = scenario in {"idle-kill", "midturn-kill", "watchdog"}
    try:
        start_payload: dict[str, Any] = {
            "op": "start",
            "model_id": args.model_id,
            "detach": True,
            "session_name": f"PRIVATE Claude MCP recovery live: {scenario}",
            "message": (midturn_prompt if scenario == "midturn-kill" else turn_prompt)(turn1_marker, turn1_reply),
        }
        if args.workspace_id:
            start_payload["workspace_id"] = args.workspace_id
        start = call(cli, window_id, "agent_run", start_payload, 60)
        session_id = strict_uuid(start.get("session_id"), "session_id")
        active_run_id = await_run_id(cli, window_id, session_id, start, set())
        if active_run_id is None:
            raise LiveAcceptanceError("start did not return a run_id")
        run_ids = {active_run_id}

        helper = find_run_helper(cli, window_id, run_ids, None, args.timeout)
        claude_before = helper.claude_pid
        conversation_before = claude_conversation_id(claude_before)
        result.check("claude pid captured", True, f"pid={claude_before} conversation={conversation_before}")

        if scenario == "midturn-kill":
            # Wait until the first RepoPrompt tool ran, so the kill lands mid-turn.
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                row = next((r for r in connection_rows(cli, window_id) if uuid_key(r.get("id")) == helper.connection_id), None)
                names = (row or {}).get("non_bookkeeping_tool_names") or []
                if PROBE_TOOL in names:
                    break
                status = session_status(cli, window_id, session_id)
                if status == "waiting_for_input":
                    raise LiveAcceptanceError(f"turn 1 {WAITING_FOR_INPUT_MESSAGE}")
                if status in {"completed", "cancelled", "failed"}:
                    raise LiveAcceptanceError(f"turn 1 ended ({status}) before calling {PROBE_TOOL}; nothing killed")
                time.sleep(0.5)
            else:
                raise LiveAcceptanceError(f"turn 1 never called {PROBE_TOOL}; nothing killed")
            status = session_status(cli, window_id, session_id)
            if status == "waiting_for_input":
                raise LiveAcceptanceError(f"turn 1 {WAITING_FOR_INPUT_MESSAGE}; nothing killed")
            if status != "running":
                raise LiveAcceptanceError(f"turn 1 is not running (status={status}); aborting before the kill")
            result.check("turn 1 still running at kill", True, f"status={status}")
            verify_and_kill_helper(helper)
            terminal1 = wait_terminal(cli, window_id, session_id, args.timeout)
            result.check(
                "mid-turn loss was non-terminal (turn 1 completed)",
                terminal1.get("status") == "completed",
                f"status={terminal1.get('status')}",
            )
            time.sleep(HELPER_EXIT_SETTLE_SECONDS)
        else:
            terminal1 = wait_terminal(cli, window_id, session_id, args.timeout)
            result.check("turn 1 completed", terminal1.get("status") == "completed", f"status={terminal1.get('status')}")
            if scenario == "idle-kill":
                verify_and_kill_helper(helper)
                time.sleep(HELPER_EXIT_SETTLE_SECONDS)
            elif scenario == "watchdog":
                aborted = call(cli, window_id, DIAGNOSTICS_TOOL, {
                    "op": "force_execution_watchdog_abort",
                    "allow_destructive": True,
                    "connection_id": helper.connection_id,
                    "run_id": active_run_id,
                })
                result.check("watchdog abort applied", aborted.get("aborted") is True, json.dumps(aborted, sort_keys=True))
                time.sleep(HELPER_EXIT_SETTLE_SECONDS)
            elif scenario == "soft-disconnect":
                disconnected = call(cli, window_id, DIAGNOSTICS_TOOL, {
                    "op": "soft_disconnect_connection",
                    "allow_destructive": True,
                    "connection_id": helper.connection_id,
                })
                result.check("soft disconnect applied", disconnected.get("disconnected") is True)
                successor = find_run_helper(
                    cli, window_id, run_ids, claude_before, args.timeout,
                    exclude_connection_ids=frozenset({helper.connection_id}),
                )
                result.check(
                    "helper reconnected and restored the route",
                    successor.pid == helper.pid,
                    f"connection={successor.connection_id} helper_pid={successor.pid}",
                )
                time.sleep(ROUTE_RESTORE_SETTLE_SECONDS)

        log_before_steer = transcript(cli, window_id, session_id)
        has_error = DISCONNECT_MARKER in log_before_steer
        if expects_loss:
            marker = REASON_MARKERS[scenario]
            result.check("transcript shows the loss error", has_error and marker in log_before_steer, marker)
        else:
            result.check("transcript shows no loss error", not has_error)

        if conversation_before is None:
            conversation_before = conversation_id_from_marker(args.claude_projects_dir, turn1_marker, scenario_started)
            result.check(
                "conversation located by turn-1 marker",
                conversation_before is not None,
                f"conversation={conversation_before} (needs exactly one recent *.jsonl under {args.claude_projects_dir})",
            )
        turns_before_steer = total_turns(cli, window_id, session_id)
        tool_calls_before_steer = tool_call_counts_by_connection(connection_rows(cli, window_id))
        steer = call(cli, window_id, "agent_run", {
            "op": "steer",
            "session_id": session_id,
            "message": turn_prompt(turn2_marker, turn2_reply),
        }, 60)
        # A steer usually continues the same run ID; accept it as returned.
        steer_run_id = await_run_id(cli, window_id, session_id, steer, set())
        if steer_run_id:
            run_ids.add(steer_run_id)
        # Capture turn 2's helper while its run is still routed (the route clears at run end).
        helper_after = find_run_helper(
            cli, window_id, run_ids, None if expects_loss else claude_before, args.timeout,
            exclude_connection_ids=frozenset({helper.connection_id}) if expects_loss else frozenset(),
        )
        terminal2 = wait_terminal(cli, window_id, session_id, args.timeout)
        result.check("turn 2 completed", terminal2.get("status") == "completed", f"status={terminal2.get('status')}")

        claude_after = helper_after.claude_pid
        if expects_loss:
            resumed = claude_conversation_id(claude_after, flags=("--resume",))
            result.check(
                "new Claude process resumed the same conversation",
                claude_after != claude_before and conversation_before is not None and resumed == conversation_before,
                f"before={claude_before}/{conversation_before} after={claude_after}/--resume {resumed}",
            )
            result.check("old Claude process is gone", not process_alive(claude_before), f"pid={claude_before}")
        else:
            result.check("Claude process was not restarted", claude_after == claude_before, f"pid={claude_after}")

        # Turn-2 evidence from the turn-2 slice of the transcript only.
        turn2_log = transcript(cli, window_id, session_id, offset=turns_before_steer)
        result.check(
            "turn 2 reply is in an assistant message",
            reply_in_assistant_message(turn2_log, turn2_reply),
            f"assistant_rows={len(tagged_texts(turn2_log, 'assistant'))}",
        )
        calls_before = tool_calls_before_steer.get(helper_after.connection_id, 0)
        calls_after = tool_call_counts_by_connection(connection_rows(cli, window_id)).get(helper_after.connection_id, 0)
        result.check(
            "a RepoPrompt tool completed without error in turn 2",
            tool_succeeded(turn2_log) and calls_after > calls_before,
            f"turn2_results={tool_results(turn2_log)} helper_tool_calls {calls_before}->{calls_after}",
        )

        # Non-replay: turn 1's prompt occurs exactly once in Claude's own transcript.
        if conversation_before is None:
            result.check("turn 1 was not replayed to Claude", False, "no conversation ID on the Claude command line")
        else:
            jsonl = find_claude_transcript(args.claude_projects_dir, conversation_before)
            if jsonl is None:
                result.check(
                    "turn 1 was not replayed to Claude", False,
                    f"no unique {conversation_before}.jsonl under {args.claude_projects_dir} (pass --claude-projects-dir)",
                )
            else:
                with jsonl.open("r", encoding="utf-8", errors="replace") as handle:
                    turn1_count = count_user_prompt_occurrences(handle, turn1_marker)
                result.check("turn 1 was not replayed to Claude", turn1_count == 1, f"{jsonl.name}: occurrences={turn1_count}")
        if not expects_loss:
            result.check("still no loss error after turn 2", DISCONNECT_MARKER not in transcript(cli, window_id, session_id))

        health = health_lines_since(args.app_log, offset)
        if args.app_log is not None:
            result.check("mcp.health log lines (informational)", None, f"{len(health)} line(s)")
            for line in health[-8:]:
                print(f"  [{scenario}] {line}")
    except (LiveAcceptanceError, support.SupportError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        result.error = str(error)
    finally:
        if session_id is not None and not args.keep_sessions:
            cleanup_session(cli, window_id, session_id, scenario)
    return result


def print_table(results: list[ScenarioResult]) -> None:
    rows: list[tuple[str, str, str, str]] = []
    for result in results:
        for name, ok, detail in result.checks:
            verdict = "INFO" if ok is None else ("PASS" if ok else "FAIL")
            rows.append((result.scenario, name, verdict, detail))
        if result.error is not None:
            rows.append((result.scenario, "scenario error", "FAIL", result.error))
        rows.append((result.scenario, "OVERALL", "PASS" if result.passed else "FAIL", ""))
    widths = [max(len(row[index]) for row in rows + [("SCENARIO", "CHECK", "RESULT", "DETAIL")]) for index in range(3)]
    header = ("SCENARIO", "CHECK", "RESULT", "DETAIL")
    print("  ".join(header[index].ljust(widths[index]) for index in range(3)) + "  " + header[3])
    for row in rows:
        print("  ".join(row[index].ljust(widths[index]) for index in range(3)) + "  " + row[3][:160])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", type=Path, required=True, help="absolute path to rpce-cli-debug")
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--workspace-id", help="optional workspace UUID guard for agent_run start")
    parser.add_argument("--model-id", default="claudeCode:sonnet:medium")
    parser.add_argument("--scenario", choices=(*SCENARIOS, "all"), default="all")
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--app-log", type=Path, help="optional app log file to scan for mcp.health lines")
    parser.add_argument(
        "--claude-projects-dir",
        type=Path,
        default=default_claude_projects_dir(),
        help="Claude's projects directory, read-only (default: $CLAUDE_CONFIG_DIR/projects or ~/.claude/projects)",
    )
    parser.add_argument("--evidence-json", type=Path, help="optional path for a JSON summary")
    parser.add_argument("--keep-sessions", action="store_true", help="do not clean up the scenario sessions")
    parser.add_argument("--confirm-dedicated-window", action="store_true", required=True)
    args = parser.parse_args()

    if not args.cli.is_absolute() or not args.cli.is_file():
        print("ERROR: --cli must be an absolute path to an existing file", file=sys.stderr)
        return 2
    if args.cli.name in {"rp-cli", "rp-cli-debug"} or "rpce" not in args.cli.name:
        print("ERROR: use rpce-cli-debug; production rp-cli must not validate CE", file=sys.stderr)
        return 2
    if args.window_id <= 0 or args.timeout < 60:
        print("ERROR: window-id must be positive and timeout >= 60", file=sys.stderr)
        return 2
    if args.workspace_id:
        args.workspace_id = strict_uuid(args.workspace_id, "workspace_id")
    try:
        call(args.cli, args.window_id, DIAGNOSTICS_TOOL, {"op": "ping"})
        validate_model(args.cli, args.window_id, args.model_id)
    except (LiveAcceptanceError, support.SupportError) as error:
        print(f"ERROR: preflight failed: {error}", file=sys.stderr)
        return 2

    scenarios = SCENARIOS if args.scenario == "all" else (args.scenario,)
    results = [run_scenario(args, scenario) for scenario in scenarios]
    print_table(results)
    if args.evidence_json is not None:
        args.evidence_json.write_text(json.dumps([
            {
                "scenario": result.scenario,
                "passed": result.passed,
                "error": result.error,
                "checks": [{"name": name, "ok": ok, "detail": detail} for name, ok, detail in result.checks],
            }
            for result in results
        ], indent=2))
    return 0 if all(result.passed for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
