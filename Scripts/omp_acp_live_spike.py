#!/usr/bin/env python3
"""Run a bounded, direct compatibility probe for the managed OMP ACP provider.

This is intentionally a developer spike, not an application launcher.  It never
starts, stops, or relaunches RepoPrompt.  The default ``bootstrap`` phase starts
the already-built MCP helper and OMP ACP server from a disposable workspace,
performs protocol initialization plus ``session/new``, and exits without asking a
model to act.  ``prompt`` is a separate authenticated no-tool lifecycle check.
``roundtrip`` is opt-in because it consumes model access and asks OMP to make
exactly one call to a test-only, read-only MCP proxy; the real bundled helper
is independently checked by the ``helper`` phase.  ``cli-prompt`` is a bounded
bare OMP print-mode check that helps distinguish an OMP auth/model problem from
an ACP-specific lifecycle problem.

All protocol evidence is written outside the repository, by default into a fresh
temporary directory.  The script rejects a repository workspace on purpose.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable


MANAGED_OMP_ARGUMENTS = [
    "acp",
    "--no-tools",
    "--no-extensions",
    "--no-skills",
    "--no-rules",
    "--approval-mode",
    "yolo",
]
MCP_PROTOCOL_VERSION = "2025-11-25"
DEFAULT_TIMEOUT_SECONDS = 30
BOOTSTRAP_TIMEOUT_SECONDS = 90
ROUNDTRIP_TIMEOUT_SECONDS = 180
POST_RESPONSE_DRAIN_SECONDS = 0.35


class ProbeError(RuntimeError):
    """An evidence-bearing live probe failed or could not safely start."""

    def __init__(self, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.details = details or {}


def json_line(payload: dict[str, Any]) -> str:
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def find_executable(value: str, label: str) -> Path:
    candidate = Path(value).expanduser()
    if candidate.is_absolute() or "/" in value:
        candidate = candidate.resolve()
    else:
        resolved = shutil.which(value)
        if resolved is None:
            raise ProbeError(f"{label} was not found on PATH: {value}")
        candidate = Path(resolved).resolve()
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise ProbeError(f"{label} is not an executable file: {candidate}")
    return candidate


def run_text(command: list[str], timeout: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    try:
        completed = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ProbeError(f"command timed out after {timeout}s: {' '.join(command)}") from error
    if completed.returncode != 0:
        raise ProbeError(
            f"command failed with exit {completed.returncode}: {' '.join(command)}\n"
            f"stderr: {completed.stderr.strip()}"
        )
    return completed.stdout


def timeout_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def hash_regular_file(path: Path) -> str:
    """Return a no-follow content digest for a workspace file snapshot."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ProbeError(f"cannot safely read workspace snapshot file: {path}: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ProbeError(f"workspace snapshot entry stopped being a regular file: {path}")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def snapshot_workspace(workspace: Path) -> dict[str, dict[str, Any]]:
    """Capture all durable workspace entries without following symlinks.

    The round-trip probe must fail if OMP (or any injected process) changes its
    scratch directory.  A content-and-mode snapshot catches additions,
    removals, replacements, permission changes, and file edits without treating
    harmless directory access-time changes as writes.
    """
    snapshot: dict[str, dict[str, Any]] = {}
    try:
        iterator = os.walk(workspace, topdown=True, followlinks=False)
        for root, directory_names, file_names in iterator:
            directory_names.sort()
            file_names.sort()
            root_path = Path(root)
            for name in [*directory_names, *file_names]:
                path = root_path / name
                relative_path = path.relative_to(workspace).as_posix()
                metadata = path.lstat()
                mode = stat.S_IMODE(metadata.st_mode)
                if stat.S_ISDIR(metadata.st_mode):
                    snapshot[relative_path] = {"kind": "directory", "mode": mode}
                elif stat.S_ISREG(metadata.st_mode):
                    snapshot[relative_path] = {
                        "kind": "file",
                        "mode": mode,
                        "size": metadata.st_size,
                        "sha256": hash_regular_file(path),
                    }
                elif stat.S_ISLNK(metadata.st_mode):
                    snapshot[relative_path] = {
                        "kind": "symlink",
                        "mode": mode,
                        "target": os.readlink(path),
                    }
                else:
                    raise ProbeError(f"refusing workspace with unsupported entry type: {path}")
    except OSError as error:
        raise ProbeError(f"cannot snapshot disposable workspace {workspace}: {error}") from error
    return snapshot


def snapshot_digest(snapshot: dict[str, dict[str, Any]]) -> str:
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def changed_snapshot_paths(
    before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]]
) -> list[str]:
    return [path for path in sorted(set(before) | set(after)) if before.get(path) != after.get(path)]


def prepare_workspace(args: argparse.Namespace, output_dir: Path, repo_root: Path) -> tuple[Path, bool]:
    """Create the default private scratch directory or validate a caller-provided one."""
    if args.workspace is None:
        workspace = Path(tempfile.mkdtemp(prefix="workspace.", dir=output_dir)).resolve()
        return workspace, True

    supplied = args.workspace.expanduser()
    if not supplied.is_absolute():
        raise ProbeError(f"workspace must be an absolute disposable path: {supplied}")
    workspace = supplied.resolve()
    if is_within(workspace, repo_root):
        raise ProbeError(f"refusing repository workspace: {workspace}")
    if workspace.exists():
        if not workspace.is_dir():
            raise ProbeError(f"workspace is not a directory: {workspace}")
        if any(workspace.iterdir()) and not args.unsafe_allow_nonempty_workspace:
            raise ProbeError(
                "refusing non-empty supplied workspace; use a fresh empty disposable directory, "
                "or pass --unsafe-allow-nonempty-workspace only if you accept the loss of exclusivity"
            )
    else:
        workspace.mkdir(parents=True, mode=0o700)
    return workspace, False


class JSONLProcess:
    """A small JSONL-RPC subprocess driver that safely demultiplexes interleaved frames."""

    def __init__(self, command: list[str], cwd: Path) -> None:
        self.command = command
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self.stdout_lines: list[str] = []
        self.stderr_lines: list[str] = []
        self.messages: list[dict[str, Any]] = []
        self._processed_lines = 0
        self._threads = [
            threading.Thread(target=self._pump, args=(self.process.stdout, self.stdout_lines), daemon=True),
            threading.Thread(target=self._pump, args=(self.process.stderr, self.stderr_lines), daemon=True),
        ]
        for thread in self._threads:
            thread.start()

    @staticmethod
    def _pump(stream: Any, sink: list[str]) -> None:
        for line in iter(stream.readline, ""):
            sink.append(line.rstrip("\n"))

    def send(self, payload: dict[str, Any]) -> None:
        if self.process.stdin is None or self.process.stdin.closed:
            raise ProbeError("cannot send JSON-RPC request: subprocess stdin is closed")
        self.process.stdin.write(json_line(payload) + "\n")
        self.process.stdin.flush()

    def drain(self, handler: Callable[[dict[str, Any]], None] | None = None) -> None:
        while self._processed_lines < len(self.stdout_lines):
            line = self.stdout_lines[self._processed_lines]
            self._processed_lines += 1
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict):
                continue
            self.messages.append(message)
            if handler is not None:
                handler(message)

    def wait_for_response(
        self,
        request_id: int,
        timeout: int,
        handler: Callable[[dict[str, Any]], None] | None = None,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain(handler)
            for message in reversed(self.messages):
                if message.get("id") == request_id and ("result" in message or "error" in message):
                    return message
            if self.process.poll() is not None:
                break
            time.sleep(0.05)
        self.drain(handler)
        raise ProbeError(
            f"timed out waiting for JSON-RPC response {request_id} after {timeout}s; "
            f"subprocess exit={self.process.poll()}"
        )

    def drain_for(self, seconds: float, handler: Callable[[dict[str, Any]], None] | None = None) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.drain(handler)
            if self.process.poll() is not None:
                break
            time.sleep(0.05)
        self.drain(handler)

    def write_evidence(self, prefix: Path) -> None:
        try:
            prefix.with_suffix(".stdout.jsonl").write_text("\n".join(self.stdout_lines) + "\n", encoding="utf-8")
            prefix.with_suffix(".stderr.txt").write_text("\n".join(self.stderr_lines) + "\n", encoding="utf-8")
        except OSError as error:
            raise ProbeError(f"could not write JSONL subprocess evidence at {prefix}: {error}") from error

    def close(self) -> None:
        """Reap the whole process group even when a pipe has already failed."""
        if self.process.stdin is not None and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        if self.process.poll() is not None:
            return
        try:
            self.process.wait(timeout=8)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=8)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired as error:
            raise ProbeError(f"subprocess did not exit after forced teardown: {' '.join(self.command)}") from error


def require_result(label: str, response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error")
    if error is not None:
        raise ProbeError(f"{label} returned JSON-RPC error: {error}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise ProbeError(f"{label} returned a non-object result")
    return result


def text_chunks(update: dict[str, Any]) -> str:
    content = update.get("content")
    if isinstance(content, dict) and isinstance(content.get("text"), str):
        return content["text"]
    if isinstance(content, str):
        return content
    return ""


def tool_title(update: dict[str, Any]) -> str | None:
    title = update.get("title")
    if isinstance(title, str):
        return title
    nested = update.get("toolCall")
    if isinstance(nested, dict) and isinstance(nested.get("title"), str):
        return nested["title"]
    return None


def choose_cancel_response(process: JSONLProcess, message: dict[str, Any], permission_events: list[dict[str, Any]]) -> None:
    """Never approve an unexpected ACP permission in this direct harness.

    The production controller has a stricter OMP-specific duplicate-approval path.
    This script intentionally does not emulate it: a request is evidence that the
    yolo launch flag did not suppress the ACP-side approval, so the safe outcome is
    cancellation rather than a potentially broad approval.
    """
    if message.get("method") != "session/request_permission" or "id" not in message:
        return
    params = message.get("params")
    if not isinstance(params, dict):
        params = {}
    tool_call = params.get("toolCall")
    if not isinstance(tool_call, dict):
        tool_call = {}
    title = tool_call.get("title") if isinstance(tool_call.get("title"), str) else None
    permission_events.append({"title": title, "response": "cancelled-by-live-spike-harness"})
    process.send(
        {
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {"outcome": {"outcome": "cancelled"}},
        }
    )


def write_json_atomically(path: Path, payload: dict[str, Any]) -> None:
    temporary_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def readonly_workspace_tree(workspace: Path) -> list[dict[str, str]]:
    """Return a deliberately small, metadata-only view for the test MCP tool."""
    snapshot = snapshot_workspace(workspace)
    return [
        {"path": path, "kind": str(entry["kind"])}
        for path, entry in list(sorted(snapshot.items()))[:128]
    ]


def readonly_mcp_proxy_main(argv: list[str]) -> int:
    """Serve one synthetic, read-only MCP tool to an OMP ACP subprocess.

    This mode is launched only by the round-trip probe.  It is intentionally a
    test double rather than the production helper: OMP can discover and invoke
    exactly one tool, `get_file_tree`, once.  All supplied arguments are ignored
    and the tool returns only a metadata-only tree of the disposable workspace.
    That makes the live transport check safe even if the model disregards its
    prompt instructions.
    """
    parser = argparse.ArgumentParser(description=readonly_mcp_proxy_main.__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--audit-file", type=Path, required=True)
    args = parser.parse_args(argv)
    workspace = args.workspace.expanduser().resolve()
    audit_file = args.audit_file.expanduser().resolve()
    audit: dict[str, Any] = {
        "kind": "test-only-readonly-mcp-proxy",
        "advertisedToolNames": ["get_file_tree"],
        "allowedToolCallCount": 0,
        "rejectedRequests": [],
        "sanitizedToolArguments": {"type": "files", "mode": "auto", "max_depth": 1},
    }
    exit_code = 0

    def send(payload: dict[str, Any]) -> None:
        sys.stdout.write(json_line(payload) + "\n")
        sys.stdout.flush()

    def reject(request_id: Any, method: str | None, detail: str, tool_name: str | None = None) -> None:
        audit["rejectedRequests"].append(
            {
                "method": method,
                "toolName": tool_name,
                "reason": detail,
            }
        )
        if request_id is not None:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": detail},
                }
            )

    try:
        if not workspace.is_dir():
            raise ProbeError(f"test-only MCP workspace is not a directory: {workspace}")
        for line in sys.stdin:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                audit["rejectedRequests"].append({"method": None, "toolName": None, "reason": "invalid-json"})
                continue
            if not isinstance(message, dict):
                audit["rejectedRequests"].append({"method": None, "toolName": None, "reason": "non-object-message"})
                continue
            request_id = message.get("id")
            method = message.get("method")
            if method == "initialize":
                if request_id is not None:
                    send(
                        {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "protocolVersion": MCP_PROTOCOL_VERSION,
                                "capabilities": {"tools": {"listChanged": False}},
                                "serverInfo": {
                                    "name": "RepoPromptCE-readonly-spike-proxy",
                                    "version": "1",
                                },
                            },
                        }
                    )
                continue
            if method == "notifications/initialized":
                audit["initializedNotificationObserved"] = True
                continue
            if isinstance(method, str) and method.startswith("notifications/"):
                audit["otherNotificationCount"] = int(audit.get("otherNotificationCount", 0)) + 1
                continue
            if method == "ping":
                if request_id is not None:
                    send({"jsonrpc": "2.0", "id": request_id, "result": {}})
                continue
            if method == "tools/list":
                audit["toolsListObserved"] = True
                if request_id is not None:
                    send(
                        {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "tools": [
                                    {
                                        "name": "get_file_tree",
                                        "description": "Read-only disposable-workspace tree for OMP ACP transport testing.",
                                        "inputSchema": {
                                            "type": "object",
                                            "properties": {},
                                            "additionalProperties": False,
                                        },
                                    }
                                ]
                            },
                        }
                    )
                continue
            if method == "tools/call":
                parameters = message.get("params")
                tool_name = parameters.get("name") if isinstance(parameters, dict) else None
                if tool_name != "get_file_tree":
                    reject(request_id, method if isinstance(method, str) else None, "tool is not available in the read-only spike proxy", tool_name if isinstance(tool_name, str) else None)
                    continue
                if audit["allowedToolCallCount"] != 0:
                    reject(request_id, method, "get_file_tree may be called only once in the live spike", tool_name)
                    continue
                audit["allowedToolCallCount"] = 1
                audit["workspaceTreeServed"] = True
                tree = readonly_workspace_tree(workspace)
                if request_id is not None:
                    send(
                        {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "content": [
                                    {
                                        "type": "text",
                                        "text": json.dumps({"type": "files", "entries": tree}, separators=(",", ":")),
                                    }
                                ],
                                "isError": False,
                            },
                        }
                    )
                continue
            reject(request_id, method if isinstance(method, str) else None, "method is not available in the read-only spike proxy")
    except (BrokenPipeError, OSError, ProbeError) as error:
        print(f"read-only MCP proxy failed: {error}", file=sys.stderr)
        audit["error"] = str(error)
        exit_code = 1
    finally:
        audit["exitCode"] = exit_code
        try:
            audit_file.parent.mkdir(parents=True, exist_ok=True)
            write_json_atomically(audit_file, audit)
        except OSError as error:
            print(f"read-only MCP proxy could not write audit evidence: {error}", file=sys.stderr)
            exit_code = 1
    return exit_code


def load_readonly_proxy_audit(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProbeError(f"read-only MCP proxy did not leave valid audit evidence: {path}: {error}") from error
    if not isinstance(payload, dict):
        raise ProbeError("read-only MCP proxy audit is not a JSON object")
    if payload.get("advertisedToolNames") != ["get_file_tree"]:
        raise ProbeError("read-only MCP proxy advertised an unexpected tool surface")
    if payload.get("allowedToolCallCount") != 1:
        raise ProbeError("roundtrip did not invoke exactly one read-only MCP tool")
    if not payload.get("initializedNotificationObserved") or not payload.get("toolsListObserved"):
        raise ProbeError("roundtrip did not complete MCP initialization and tool discovery through the proxy")
    if payload.get("rejectedRequests"):
        raise ProbeError("roundtrip attempted an MCP request outside the read-only proxy surface")
    if payload.get("exitCode") != 0:
        raise ProbeError("read-only MCP proxy exited with an error")
    return payload


def helper_preflight(helper: Path, workspace: Path, output_dir: Path) -> dict[str, Any]:
    process = JSONLProcess([str(helper)], workspace)
    try:
        process.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "OMP-live-spike", "version": "1"},
                },
            }
        )
        initialize = require_result("MCP initialize", process.wait_for_response(1, DEFAULT_TIMEOUT_SECONDS))
        process.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        process.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools_result = require_result("MCP tools/list", process.wait_for_response(2, DEFAULT_TIMEOUT_SECONDS))
        tools = tools_result.get("tools")
        if not isinstance(tools, list):
            raise ProbeError("MCP tools/list result does not contain a tools array")
        return {
            "serverInfo": initialize.get("serverInfo"),
            "capabilityKeys": sorted((initialize.get("capabilities") or {}).keys()),
            "toolCount": len(tools),
            "toolNames": [item.get("name") for item in tools if isinstance(item, dict) and isinstance(item.get("name"), str)],
        }
    finally:
        # Reap the helper before evidence I/O: a full disk or bad evidence path
        # must never leave the real RepoPrompt helper running.
        try:
            process.close()
        finally:
            process.write_evidence(output_dir / "repoprompt-mcp")


def cli_prompt_probe(omp: Path, workspace: Path, output_dir: Path, timeout: int) -> dict[str, Any]:
    acknowledgement = "OMP_CLI_PROMPT_OK"
    command = [
        str(omp),
        "--no-session",
        "--no-tools",
        "--no-extensions",
        "--no-skills",
        "--no-rules",
        "--approval-mode",
        "yolo",
        f"--max-time={timeout}",
        "--print",
        f"Reply exactly: {acknowledgement}",
    ]
    stdout = ""
    stderr = ""
    try:
        completed = subprocess.run(
            command,
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=timeout + 20,
        )
    except subprocess.TimeoutExpired as error:
        stdout = timeout_text(error.stdout)
        stderr = timeout_text(error.stderr)
        (output_dir / "omp-cli-prompt.stdout.txt").write_text(stdout, encoding="utf-8")
        (output_dir / "omp-cli-prompt.stderr.txt").write_text(stderr, encoding="utf-8")
        raise ProbeError(
            f"bare OMP print-mode prompt timed out after {timeout + 20}s",
            {"ompCLIPrompt": {"timedOut": True, "stdoutBytes": len(stdout), "stderrBytes": len(stderr)}},
        ) from error
    stdout = completed.stdout
    stderr = completed.stderr
    (output_dir / "omp-cli-prompt.stdout.txt").write_text(stdout, encoding="utf-8")
    (output_dir / "omp-cli-prompt.stderr.txt").write_text(stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise ProbeError(f"bare OMP print-mode prompt exited {completed.returncode}")
    if acknowledgement not in stdout:
        raise ProbeError("bare OMP print-mode prompt did not return the exact acknowledgement")
    return {
        "command": ["omp", "--no-session", *MANAGED_OMP_ARGUMENTS[1:], f"--max-time={timeout}", "--print"],
        "acknowledgementObserved": True,
    }


def acp_probe(
    omp: Path,
    helper: Path,
    workspace: Path,
    output_dir: Path,
    phase: str,
    prompt_timeout: int,
) -> dict[str, Any]:
    process = JSONLProcess([str(omp), *MANAGED_OMP_ARGUMENTS], workspace)
    mcp_command = str(helper)
    mcp_args: list[str] = []
    mcp_server_kind = "bundled-repoprompt-helper"
    readonly_proxy_audit: Path | None = None
    if phase == "roundtrip":
        readonly_proxy_audit = output_dir / "readonly-mcp-proxy.audit.json"
        try:
            readonly_proxy_audit.unlink()
        except FileNotFoundError:
            pass
        mcp_command = str(Path(sys.executable).resolve())
        mcp_args = [
            str(Path(__file__).resolve()),
            "--readonly-mcp-proxy",
            "--workspace",
            str(workspace),
            "--audit-file",
            str(readonly_proxy_audit),
        ]
        mcp_server_kind = "test-only-readonly-mcp-proxy"
    permission_events: list[dict[str, Any]] = []
    update_kinds: list[str] = []
    observed_tool_titles: list[str] = []
    agent_text: list[str] = []

    def inbound_handler(message: dict[str, Any]) -> None:
        choose_cancel_response(process, message, permission_events)
        if message.get("method") != "session/update":
            return
        params = message.get("params")
        update = params.get("update") if isinstance(params, dict) else None
        if not isinstance(update, dict):
            return
        kind = update.get("sessionUpdate")
        if isinstance(kind, str):
            update_kinds.append(kind)
        if kind in {"tool_call", "tool_call_update"}:
            title = tool_title(update)
            if title:
                observed_tool_titles.append(title)
        if kind == "agent_message_chunk":
            agent_text.append(text_chunks(update))

    session_id: str | None = None
    initialize: dict[str, Any] = {}
    auth_method_ids: list[str] = []
    opened: dict[str, Any] = {}

    def partial_summary() -> dict[str, Any]:
        return {
            "agentInfo": initialize.get("agentInfo"),
            "authMethodIDs": auth_method_ids,
            "sessionIdPresent": session_id is not None,
            "sessionNewResultKeys": sorted(opened.keys()),
            "configOptionIDs": [
                item.get("id")
                for item in opened.get("configOptions", [])
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            ],
            "observedUpdateKinds": sorted(set(update_kinds)),
            "observedToolTitles": sorted(set(observed_tool_titles)),
            "permissionEvents": permission_events,
            "workspaceFileNames": sorted(path.name for path in workspace.iterdir()),
            "mcpServerKind": mcp_server_kind,
            "restrictedMCPProxyAuditPath": str(readonly_proxy_audit) if readonly_proxy_audit else None,
        }

    try:
        process.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": 1,
                    "clientInfo": {"name": "RepoPrompt", "version": "1.0.29-live-spike"},
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                },
            }
        )
        initialize = require_result("ACP initialize", process.wait_for_response(1, DEFAULT_TIMEOUT_SECONDS, inbound_handler))
        auth_method_ids = [
            item.get("id")
            for item in initialize.get("authMethods", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ]
        if "agent" in auth_method_ids:
            process.send({"jsonrpc": "2.0", "id": 2, "method": "authenticate", "params": {"methodId": "agent"}})
            require_result("ACP authenticate", process.wait_for_response(2, DEFAULT_TIMEOUT_SECONDS, inbound_handler))

        process.send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "session/new",
                "params": {
                    "cwd": str(workspace),
                    "mcpServers": [
                        {
                            "type": "stdio",
                            "name": "RepoPromptCE",
                            "command": mcp_command,
                            "args": mcp_args,
                            "env": [],
                        }
                    ],
                },
            }
        )
        opened = require_result("ACP session/new", process.wait_for_response(3, BOOTSTRAP_TIMEOUT_SECONDS, inbound_handler))
        raw_session_id = opened.get("sessionId")
        if not isinstance(raw_session_id, str) or not raw_session_id:
            raise ProbeError("ACP session/new did not return a non-empty sessionId")
        session_id = raw_session_id
        process.drain_for(POST_RESPONSE_DRAIN_SECONDS, inbound_handler)

        summary: dict[str, Any] = {
            "agentInfo": initialize.get("agentInfo"),
            "authMethodIDs": auth_method_ids,
            "agentCapabilityKeys": sorted((initialize.get("agentCapabilities") or {}).keys()),
            "sessionIdPresent": True,
            "sessionNewResultKeys": sorted(opened.keys()),
            "configOptionIDs": [
                item.get("id")
                for item in opened.get("configOptions", [])
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            ],
            "mcpServerKind": mcp_server_kind,
        }

        if phase in {"prompt", "roundtrip"}:
            acknowledgement = "OMP_ACP_PROMPT_OK" if phase == "prompt" else "OMP_REPOPROMPT_MCP_ROUNDTRIP_OK"
            prompt_text = (
                "Reply exactly: OMP_ACP_PROMPT_OK. Do not invoke tools, read files, or make changes."
                if phase == "prompt"
                else (
                    "Use the injected read-only test MCP tool "
                    "mcp__RepoPromptCE__get_file_tree exactly once to inspect the disposable workspace root. "
                    "It exposes no other tool. After that tool returns, "
                    "reply exactly: OMP_REPOPROMPT_MCP_ROUNDTRIP_OK"
                )
            )
            process.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "session/prompt",
                    "params": {
                        "sessionId": session_id,
                        "prompt": [
                            {
                                "type": "text",
                                "text": prompt_text,
                            }
                        ],
                    },
                }
            )
            prompt_result = require_result(
                "ACP session/prompt",
                process.wait_for_response(4, prompt_timeout, inbound_handler),
            )
            process.drain_for(POST_RESPONSE_DRAIN_SECONDS, inbound_handler)
            summary["promptStopReason"] = prompt_result.get("stopReason")
            summary["promptResultKeys"] = sorted(prompt_result.keys())
            summary["expectedAcknowledgement"] = acknowledgement
            summary["agentAcknowledgementObserved"] = acknowledgement in "".join(agent_text)

        summary.update(partial_summary())
        return summary
    except ProbeError as error:
        details = dict(error.details)
        details["ompACPPartial"] = partial_summary()
        raise ProbeError(str(error), details) from error
    finally:
        try:
            if session_id:
                try:
                    process.send({"jsonrpc": "2.0", "id": 99, "method": "session/close", "params": {"sessionId": session_id}})
                    process.wait_for_response(99, 10, inbound_handler)
                except (ProbeError, OSError):
                    pass
        finally:
            # Always reap OMP and its MCP child before evidence I/O so a failed
            # close request or disk write cannot leave an authenticated ACP
            # server running.
            try:
                process.close()
            finally:
                process.write_evidence(output_dir / "omp-acp")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--phase",
        choices=("preflight", "cli-prompt", "helper", "bootstrap", "prompt", "roundtrip"),
        default="bootstrap",
        help="preflight, bare OMP print prompt, helper MCP, safe ACP bootstrap (default), no-tool ACP prompt, or safety-enforced read-only MCP roundtrip",
    )
    parser.add_argument("--omp", default=os.environ.get("OMP_EXECUTABLE", "omp"), help="OMP executable or absolute path")
    parser.add_argument(
        "--app-bundle",
        type=Path,
        default=Path.home() / "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app",
        help="fresh coordinated debug app bundle containing repoprompt-mcp",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        help="absolute empty disposable workspace; defaults to a fresh private directory under the output directory",
    )
    parser.add_argument(
        "--unsafe-allow-nonempty-workspace",
        action="store_true",
        help="UNSAFE: allow a non-empty supplied workspace and waive the normal exclusivity check",
    )
    parser.add_argument("--output-dir", type=Path, help="outside-repository directory for local JSONL evidence")
    parser.add_argument(
        "--prompt-timeout",
        type=int,
        default=ROUNDTRIP_TIMEOUT_SECONDS,
        help=f"seconds to wait for the opt-in prompt phase (default: {ROUNDTRIP_TIMEOUT_SECONDS})",
    )
    return parser.parse_args()


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--readonly-mcp-proxy":
        return readonly_mcp_proxy_main(sys.argv[2:])
    args = parse_args()
    if args.prompt_timeout <= 0:
        print("ERROR: --prompt-timeout must be positive", file=sys.stderr)
        return 2
    repo_root = Path(__file__).resolve().parents[1]
    output_dir = (args.output_dir or Path(tempfile.mkdtemp(prefix="repoprompt-omp-acp-spike."))).expanduser().resolve()
    if is_within(output_dir, repo_root):
        print(f"ERROR: refusing repository-local evidence directory: {output_dir}", file=sys.stderr)
        return 2
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        workspace, workspace_is_fresh_default = prepare_workspace(args, output_dir, repo_root)
    except ProbeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    marker = workspace / ".omp-live-spike-readonly-marker"
    if marker.exists() or marker.is_symlink():
        print(f"ERROR: refusing workspace with an existing spike marker: {marker}", file=sys.stderr)
        return 2
    marker.write_text("This disposable workspace is owned by omp_acp_live_spike.py.\n", encoding="utf-8")
    workspace_before: dict[str, dict[str, Any]] | None = None
    if args.phase == "roundtrip":
        try:
            workspace_before = snapshot_workspace(workspace)
        except ProbeError as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2

    summary: dict[str, Any] = {
        "phase": args.phase,
        "outputDirectory": str(output_dir),
        "workspace": str(workspace),
        "workspaceFreshDefault": workspace_is_fresh_default,
        "unsafeNonemptyWorkspaceOverride": args.unsafe_allow_nonempty_workspace,
        "managedOMPArguments": MANAGED_OMP_ARGUMENTS,
        "success": False,
    }
    if workspace_before is not None:
        summary["workspaceSnapshotBeforeSHA256"] = snapshot_digest(workspace_before)
    exit_code = 0
    reported_error: ProbeError | None = None
    try:
        omp = find_executable(args.omp, "OMP executable")
        helper = find_executable(str(args.app_bundle.expanduser() / "Contents/MacOS/repoprompt-mcp"), "bundled RepoPrompt MCP helper")
        summary["ompExecutable"] = str(omp)
        summary["helperExecutable"] = str(helper)
        version = run_text([str(omp), "--version"]).strip()
        global_help = run_text([str(omp), "--help"])
        acp_help = run_text([str(omp), "acp", "--help"])
        missing_flags = [flag for flag in ("--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--approval-mode") if flag not in global_help]
        if missing_flags:
            raise ProbeError(f"OMP global help is missing managed flags: {', '.join(missing_flags)}")
        if "Run Oh My Pi as an ACP" not in acp_help:
            raise ProbeError("OMP ACP subcommand help did not identify the ACP server")
        summary["ompVersion"] = version
        summary["managedFlagPreflight"] = "passed"

        if args.phase == "cli-prompt":
            summary["ompCLIPrompt"] = cli_prompt_probe(omp, workspace, output_dir, args.prompt_timeout)
        if args.phase in {"helper", "bootstrap", "prompt", "roundtrip"}:
            summary["helperMCP"] = helper_preflight(helper, workspace, output_dir)
        if args.phase in {"bootstrap", "prompt", "roundtrip"}:
            summary["ompACP"] = acp_probe(omp, helper, workspace, output_dir, args.phase, args.prompt_timeout)
            if args.phase == "prompt" and not summary["ompACP"].get("agentAcknowledgementObserved"):
                raise ProbeError("no-tool prompt did not observe the exact acknowledgement")
            if args.phase == "roundtrip":
                acp = summary["ompACP"]
                proxy_audit = load_readonly_proxy_audit(output_dir / "readonly-mcp-proxy.audit.json")
                acp["restrictedMCPProxy"] = proxy_audit
                known_tool_seen = any(
                    title == "get_file_tree" or title.endswith("__get_file_tree")
                    for title in acp["observedToolTitles"]
                )
                if acp["permissionEvents"]:
                    raise ProbeError("OMP emitted ACP permission requests; the harness cancelled them instead of approving a live tool call")
                if not known_tool_seen or not acp.get("agentAcknowledgementObserved"):
                    raise ProbeError("roundtrip did not observe both the restricted MCP tool event and the exact acknowledgement")

        if not marker.exists():
            raise ProbeError("read-only workspace marker was removed")
        if workspace_before is not None:
            workspace_after = snapshot_workspace(workspace)
            changed_paths = changed_snapshot_paths(workspace_before, workspace_after)
            summary["workspaceSnapshotAfterSHA256"] = snapshot_digest(workspace_after)
            summary["workspaceUnchanged"] = not changed_paths
            if changed_paths:
                summary["workspaceChangedPaths"] = changed_paths[:50]
                raise ProbeError("roundtrip changed the disposable workspace")
        summary["readOnlyMarkerStillPresent"] = True
        summary["success"] = True
    except ProbeError as error:
        reported_error = error
        exit_code = 1
        summary["error"] = str(error)
        if error.details:
            summary["failureDetails"] = error.details
        print(f"OMP ACP live spike did not pass: {error}", file=sys.stderr)
    finally:
        if workspace_before is not None:
            try:
                workspace_after = snapshot_workspace(workspace)
                changed_paths = changed_snapshot_paths(workspace_before, workspace_after)
                summary["workspaceSnapshotAfterSHA256"] = snapshot_digest(workspace_after)
                summary["workspaceUnchanged"] = not changed_paths
                if changed_paths:
                    summary["workspaceChangedPaths"] = changed_paths[:50]
                    summary["success"] = False
                    if reported_error is None:
                        error = ProbeError("roundtrip changed the disposable workspace")
                        reported_error = error
                        exit_code = 1
                        summary["error"] = str(error)
                        print(f"OMP ACP live spike did not pass: {error}", file=sys.stderr)
            except ProbeError as error:
                summary["success"] = False
                if reported_error is None:
                    reported_error = error
                    exit_code = 1
                    summary["error"] = str(error)
                    print(f"OMP ACP live spike did not pass: {error}", file=sys.stderr)
        try:
            write_json_atomically(output_dir / "safe-summary.json", summary)
        except OSError as error:
            print(f"ERROR: could not write safe summary: {error}", file=sys.stderr)
            exit_code = 1
        print(f"Evidence directory: {output_dir}")
    if exit_code == 0:
        print("OMP ACP live spike passed")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
