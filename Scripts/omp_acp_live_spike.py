#!/usr/bin/env python3
"""Run a bounded, direct compatibility probe for the managed OMP ACP provider.

This is intentionally a developer spike, not an application launcher.  It never
starts, stops, or relaunches RepoPrompt.  The default ``bootstrap`` phase starts
the already-built MCP helper and OMP ACP server from a disposable workspace,
performs protocol initialization plus ``session/new``, and exits without asking a
model to act.  ``prompt`` is a separate authenticated no-tool lifecycle check.
``roundtrip`` is opt-in because it consumes model access and asks OMP to make
exactly one call to a test-only, read-only MCP proxy; the real bundled helper
is independently checked by the ``helper`` phase.  ``production-bootstrap``
injects that bundled helper and captures DEBUG connection/process identity while
the ACP session is open, without dispatching ``session/prompt``.  ``cli-prompt`` is a bounded
bare OMP print-mode check that helps distinguish an OMP auth/model problem from
an ACP-specific lifecycle problem.

All protocol evidence is written outside the repository, by default into a fresh
temporary directory.  The script rejects a repository workspace on purpose.
"""

from __future__ import annotations

import argparse
from collections import deque
import ctypes
import hashlib
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
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
DEFAULT_STREAM_LIMIT_BYTES = 64 * 1024 * 1024
DEFAULT_MESSAGE_LIMIT = 100_000
DEFAULT_FRAME_LIMIT_BYTES = 1024 * 1024
DEFAULT_PROXY_REJECTION_LIMIT = 32
DEFAULT_TERMINATION_GRACE_SECONDS = 2.0
PUMP_JOIN_TIMEOUT_SECONDS = 2.0
DEFAULT_SNAPSHOT_ENTRY_LIMIT = 10_000
DEFAULT_SNAPSHOT_FILE_BYTE_LIMIT = 64 * 1024 * 1024
DEFAULT_SNAPSHOT_AGGREGATE_BYTE_LIMIT = 256 * 1024 * 1024
DEFAULT_SNAPSHOT_DEADLINE_SECONDS = 30.0
PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS = 10.0
PRODUCTION_DIAGNOSTICS_POLL_SECONDS = 0.1
PROCESS_INSPECTION_TIMEOUT_SECONDS = 3.0
PROCESS_INSPECTION_ROW_LIMIT = 4096
PROCESS_INSPECTION_OUTPUT_LIMIT_BYTES = 4 * 1024 * 1024
PROCESS_EXECUTABLE_PATH_LIMIT_BYTES = 4096
PRODUCTION_HISTORY_LIMIT = 500
PRODUCTION_HELPER_BOOTSTRAP_CLIENT_NAME = "repoprompt-mcp"
READONLY_TREE_ENTRY_LIMIT = 128
WORKSPACE_NAME_LIMIT = 200
WORKSPACE_NAME_DEADLINE_SECONDS = 1.0
PERMISSION_EVENT_LIMIT = 1
UNEXPECTED_INBOUND_REQUEST_LIMIT = 1
UNEXPECTED_INBOUND_PARAMS_LIMIT = 512
TAIL_CAUSE_LIMIT = DEFAULT_PROXY_REJECTION_LIMIT
SESSION_OPEN_UPDATE_KINDS = frozenset({"available_commands_update", "session_info_update"})
PROMPT_ONLY_UPDATE_KINDS = frozenset({
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "usage_update",
    "user_message_chunk",
})
RECOGNIZED_SESSION_UPDATE_KINDS = frozenset({
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "usage_update",
    "session_info_update",
    "available_commands_update",
    "user_message_chunk",
})


class ProbeError(RuntimeError):
    """An evidence-bearing live probe failed or could not safely start."""

    def __init__(self, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.details = details or {}


class TerminalInboundRequestError(ProbeError):
    """An inbound ACP request made the live probe terminal."""


class PermissionTerminalError(TerminalInboundRequestError):
    """An ACP permission request made the live probe terminal."""


class UnexpectedInboundRequestError(TerminalInboundRequestError):
    """An unsupported inbound ACP request made the live probe terminal."""


def combine_probe_errors(*causes: tuple[str, BaseException | None]) -> ProbeError | None:
    retained = [(label, error) for label, error in causes if error is not None]
    if not retained:
        return None

    def survivor_priority(item: tuple[str, BaseException]) -> int:
        label, error = item
        message = str(error).lower()
        if "surviv" in message or "could not signal subprocess group" in message:
            return 0
        if "cleanup" in label or "teardown" in label or "pump" in label or "close" in label:
            return 1
        return 2

    ordered = sorted(retained, key=survivor_priority)
    details = {
        "causes": [
            {
                "stage": label,
                "message": str(error) or type(error).__name__,
                "details": error.details if isinstance(error, ProbeError) and error.details else None,
            }
            for label, error in ordered
        ]
    }
    message = "; ".join(f"{label}: {str(error) or type(error).__name__}" for label, error in ordered)
    return ProbeError(message, details)


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


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(
    process: subprocess.Popen[Any],
    command: list[str],
    grace_seconds: float = DEFAULT_TERMINATION_GRACE_SECONDS,
) -> None:
    """Reap a new-session process and every surviving member of its original group."""
    process_group_id = process.pid
    if process.poll() is None:
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            pass
    if process_group_exists(process_group_id):
        try:
            os.killpg(process_group_id, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            raise ProbeError(f"could not signal subprocess group: {' '.join(command)}: {error}") from error
        if process.poll() is None:
            try:
                process.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                pass
        deadline = time.monotonic() + grace_seconds
        while process_group_exists(process_group_id) and time.monotonic() < deadline:
            time.sleep(0.01)
    if process_group_exists(process_group_id):
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            raise ProbeError(f"could not signal subprocess group: {' '.join(command)}: {error}") from error
        if process.poll() is None:
            try:
                process.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                pass
        deadline = time.monotonic() + grace_seconds
        while process_group_exists(process_group_id) and time.monotonic() < deadline:
            time.sleep(0.01)
    if process.poll() is None:
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired as error:
            raise ProbeError(f"subprocess did not exit after forced teardown: {' '.join(command)}") from error
    if process_group_exists(process_group_id):
        raise ProbeError(f"subprocess group survived forced teardown: {' '.join(command)}")


def rollback_process_construction(
    process: subprocess.Popen[Any],
    command: list[str],
    grace_seconds: float,
    started_threads: list[threading.Thread],
) -> ProbeError | None:
    """Boundedly undo a successful Popen when wrapper initialization fails."""
    causes: list[tuple[str, BaseException | None]] = []
    stdin = getattr(process, "stdin", None)
    if stdin is not None and not stdin.closed:
        try:
            stdin.close()
        except BaseException as error:
            causes.append(("constructor stdin close", error))
    try:
        terminate_process_group(process, command, grace_seconds)
    except BaseException as error:
        causes.append(("constructor process-group teardown", error))
    for name in ("stdout", "stderr"):
        stream = getattr(process, name, None)
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException as error:
                causes.append((f"constructor {name} close", error))
    for thread in started_threads:
        try:
            thread.join(PUMP_JOIN_TIMEOUT_SECONDS)
            if thread.is_alive():
                causes.append(("constructor pump join", ProbeError("started subprocess pump did not stop")))
        except BaseException as error:
            causes.append(("constructor pump join", error))
    return combine_probe_errors(*causes)


class BoundedTextProcess:
    """Capture a subprocess without allowing retained stdout or stderr to grow unbounded."""

    def __init__(
        self,
        command: list[str],
        cwd: Path | None = None,
        stream_limit_bytes: int = DEFAULT_STREAM_LIMIT_BYTES,
        termination_grace_seconds: float = DEFAULT_TERMINATION_GRACE_SECONDS,
    ) -> None:
        self.command = command
        self.stream_limit_bytes = stream_limit_bytes
        self.termination_grace_seconds = termination_grace_seconds
        process: subprocess.Popen[Any] | None = None
        started_threads: list[threading.Thread] = []
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            self.process = process
            self._chunks: dict[str, list[bytes]] = {"stdout": [], "stderr": []}
            self._sizes = {"stdout": 0, "stderr": 0}
            self._overflow: str | None = None
            self._lock = threading.Lock()
            self._threads = [
                threading.Thread(target=self._pump, args=("stdout", self.process.stdout), daemon=True),
                threading.Thread(target=self._pump, args=("stderr", self.process.stderr), daemon=True),
            ]
            for thread in self._threads:
                thread.start()
                started_threads.append(thread)
        except BaseException as primary:
            for thread in getattr(self, "_threads", []):
                if thread.ident is not None and thread not in started_threads:
                    started_threads.append(thread)
            if process is None:
                raise
            cleanup = rollback_process_construction(process, self.command, self.termination_grace_seconds, started_threads)
            if cleanup is not None:
                try:
                    primary.add_note(f"constructor rollback: {cleanup}")
                except BaseException:
                    pass
                raise primary from cleanup
            raise

    def _pump(self, name: str, stream: Any) -> None:
        try:
            while True:
                chunk = stream.read(8192)
                if not chunk:
                    return
                with self._lock:
                    remaining = self.stream_limit_bytes - self._sizes[name]
                    if remaining > 0:
                        retained = chunk[:remaining]
                        self._chunks[name].append(retained)
                        self._sizes[name] += len(retained)
                    if len(chunk) > remaining and self._overflow is None:
                        self._overflow = f"{name} exceeded {self.stream_limit_bytes} retained bytes"
        except (OSError, ValueError) as error:
            with self._lock:
                if self._overflow is None:
                    self._overflow = f"{name} pump failed: {error}"

    def _join_pumps(self) -> None:
        for thread in self._threads:
            thread.join(PUMP_JOIN_TIMEOUT_SECONDS)
        if any(thread.is_alive() for thread in self._threads):
            raise ProbeError(f"subprocess output pump did not stop: {' '.join(self.command)}")
        for stream in (self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()

    def close(self) -> None:
        terminate_error: BaseException | None = None
        retry_error: BaseException | None = None
        join_error: BaseException | None = None
        try:
            terminate_process_group(self.process, self.command, self.termination_grace_seconds)
        except BaseException as error:
            terminate_error = error
            try:
                terminate_process_group(self.process, self.command, self.termination_grace_seconds)
            except BaseException as retry:
                retry_error = retry
        try:
            self._join_pumps()
        except BaseException as error:
            join_error = error
        with self._lock:
            overflow = self._overflow
        combined = combine_probe_errors(
            ("process-group teardown", terminate_error),
            ("process-group teardown retry", retry_error),
            ("pump completion", join_error),
            ("output overflow", ProbeError(overflow) if overflow is not None else None),
        )
        if combined is not None:
            raise combined

    def text(self, name: str) -> str:
        return b"".join(self._chunks[name]).decode("utf-8", errors="replace")

    def wait(self, timeout: float) -> tuple[int, str, str]:
        deadline = time.monotonic() + timeout
        failure: ProbeError | None = None
        return_code = -1
        try:
            while True:
                if self.process.poll() is not None:
                    break
                with self._lock:
                    overflow = self._overflow
                if overflow:
                    raise ProbeError(overflow)
                if time.monotonic() >= deadline:
                    raise ProbeError(f"command timed out after {timeout}s: {' '.join(self.command)}")
                time.sleep(0.01)
            with self._lock:
                overflow = self._overflow
            if overflow:
                raise ProbeError(overflow)
            return_code = self.process.returncode
        except BaseException as error:
            failure = error
            return_code = self.process.returncode if self.process.returncode is not None else -1
        finally:
            try:
                self.close()
            except BaseException as error:
                combined = combine_probe_errors(("primary operation", failure), ("cleanup", error))
                if combined is not None:
                    raise combined
        if failure is not None:
            raise failure
        return return_code, self.text("stdout"), self.text("stderr")


def run_text(
    command: list[str],
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    stream_limit_bytes: int = DEFAULT_STREAM_LIMIT_BYTES,
    cwd: Path | None = None,
) -> str:
    process = BoundedTextProcess(command, cwd=cwd, stream_limit_bytes=stream_limit_bytes)
    return_code, stdout, stderr = process.wait(timeout)
    if return_code != 0:
        raise ProbeError(
            f"command failed with exit {return_code}: {' '.join(command)}\n"
            f"stderr: {stderr.strip()}"
        )
    return stdout


def _open_directory_fd(name: str | os.PathLike[str], *, dir_fd: int | None = None) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    return os.open(name, flags, dir_fd=dir_fd)


def _open_regular_fd(name: str | os.PathLike[str], *, dir_fd: int) -> int:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    return os.open(name, flags, dir_fd=dir_fd)


def _entry_identity(metadata: os.stat_result) -> tuple[int, int, int]:
    return metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode)


def hash_regular_file(
    name: str,
    *,
    dir_fd: int,
    observed_metadata: os.stat_result,
    display_path: str,
    byte_limit: int,
    aggregate_remaining: int,
    deadline: float,
) -> tuple[str, int]:
    """Hash one parent-anchored file without reading past either byte budget."""
    try:
        descriptor = _open_regular_fd(name, dir_fd=dir_fd)
    except OSError as error:
        raise ProbeError(f"cannot safely read workspace snapshot file: {display_path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or _entry_identity(before) != _entry_identity(observed_metadata):
            raise ProbeError(f"workspace snapshot entry changed before open: {display_path}")
        if before.st_size > byte_limit:
            raise ProbeError(f"workspace snapshot file exceeds {byte_limit} bytes: {display_path}")
        if before.st_size > aggregate_remaining:
            raise ProbeError(f"workspace snapshot content exceeds aggregate byte limit at: {display_path}")
        digest = hashlib.sha256()
        hashed = 0
        while hashed < before.st_size:
            if time.monotonic() >= deadline:
                raise ProbeError("workspace snapshot deadline exceeded while hashing")
            remaining = min(before.st_size - hashed, byte_limit - hashed, aggregate_remaining - hashed)
            if remaining <= 0:
                raise ProbeError(f"workspace snapshot content exceeds aggregate byte limit at: {display_path}")
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ProbeError(f"workspace snapshot file changed while reading: {display_path}")
            hashed += len(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            _entry_identity(after) != _entry_identity(before)
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
            or after.st_ctime_ns != before.st_ctime_ns
            or hashed != before.st_size
        ):
            raise ProbeError(f"workspace snapshot file changed while reading: {display_path}")
        return digest.hexdigest(), hashed
    finally:
        os.close(descriptor)


def snapshot_workspace(
    workspace: Path,
    entry_limit: int = DEFAULT_SNAPSHOT_ENTRY_LIMIT,
    file_byte_limit: int = DEFAULT_SNAPSHOT_FILE_BYTE_LIMIT,
    aggregate_byte_limit: int = DEFAULT_SNAPSHOT_AGGREGATE_BYTE_LIMIT,
    deadline_seconds: float = DEFAULT_SNAPSHOT_DEADLINE_SECONDS,
) -> dict[str, dict[str, Any]]:
    """Capture durable workspace state with strict traversal and I/O budgets."""
    if min(entry_limit, file_byte_limit, aggregate_byte_limit) < 0 or deadline_seconds <= 0:
        raise ProbeError("workspace snapshot limits must be non-negative and deadline must be positive")
    snapshot: dict[str, dict[str, Any]] = {}
    deadline = time.monotonic() + deadline_seconds
    aggregate_bytes = 0
    entry_count = 0
    pending: deque[tuple[int, str]] = deque()
    try:
        try:
            root_fd = _open_directory_fd(workspace)
        except OSError as error:
            raise ProbeError(f"workspace root is not a directory: {workspace}: {error}") from error
        root_metadata = os.fstat(root_fd)
        if not stat.S_ISDIR(root_metadata.st_mode):
            os.close(root_fd)
            raise ProbeError(f"workspace root is not a directory: {workspace}")
        pending.append((root_fd, "."))
        snapshot["."] = {"kind": "directory", "mode": stat.S_IMODE(root_metadata.st_mode)}
        while pending:
            if time.monotonic() >= deadline:
                raise ProbeError("workspace snapshot deadline exceeded during traversal")
            directory_fd, relative_directory = pending.popleft()
            try:
                bounded_entries: list[tuple[str, os.stat_result]] = []
                with os.scandir(directory_fd) as iterator:
                    for entry in iterator:
                        if time.monotonic() >= deadline:
                            raise ProbeError("workspace snapshot deadline exceeded during traversal")
                        entry_count += 1
                        if entry_count > entry_limit:
                            raise ProbeError(f"workspace snapshot entry count exceeded {entry_limit}")
                        bounded_entries.append((entry.name, entry.stat(follow_symlinks=False)))
                for name, metadata in sorted(bounded_entries):
                    relative_path = name if relative_directory == "." else f"{relative_directory}/{name}"
                    mode = stat.S_IMODE(metadata.st_mode)
                    if stat.S_ISDIR(metadata.st_mode):
                        try:
                            child_fd = _open_directory_fd(name, dir_fd=directory_fd)
                            opened = os.fstat(child_fd)
                            if not stat.S_ISDIR(opened.st_mode) or _entry_identity(opened) != _entry_identity(metadata):
                                raise ProbeError(f"workspace directory changed before open: {relative_path}")
                        except BaseException:
                            if "child_fd" in locals():
                                os.close(child_fd)
                                del child_fd
                            raise
                        snapshot[relative_path] = {"kind": "directory", "mode": mode}
                        pending.append((child_fd, relative_path))
                        del child_fd
                    elif stat.S_ISREG(metadata.st_mode):
                        if metadata.st_size > file_byte_limit:
                            raise ProbeError(f"workspace snapshot file exceeds {file_byte_limit} bytes: {relative_path}")
                        digest, actual_size = hash_regular_file(
                            name,
                            dir_fd=directory_fd,
                            observed_metadata=metadata,
                            display_path=relative_path,
                            byte_limit=file_byte_limit,
                            aggregate_remaining=aggregate_byte_limit - aggregate_bytes,
                            deadline=deadline,
                        )
                        aggregate_bytes += actual_size
                        snapshot[relative_path] = {
                            "kind": "file", "mode": mode, "size": actual_size, "sha256": digest
                        }
                    elif stat.S_ISLNK(metadata.st_mode):
                        snapshot[relative_path] = {
                            "kind": "symlink", "mode": mode, "target": os.readlink(name, dir_fd=directory_fd)
                        }
                    else:
                        raise ProbeError(f"refusing workspace with unsupported entry type: {relative_path}")
            finally:
                os.close(directory_fd)
    except OSError as error:
        raise ProbeError(f"cannot snapshot disposable workspace {workspace}: {error}") from error
    finally:
        while pending:
            descriptor, _ = pending.popleft()
            os.close(descriptor)
    return snapshot


def snapshot_digest(snapshot: dict[str, dict[str, Any]]) -> str:
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def changed_snapshot_paths(
    before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]]
) -> list[str]:
    return [path for path in sorted(set(before) | set(after)) if before.get(path) != after.get(path)]


def phase_requires_workspace_snapshot(phase: str) -> bool:
    return phase in {"preflight", "cli-prompt", "helper", "bootstrap", "production-bootstrap", "prompt", "roundtrip"}


def prepare_output_directory(supplied_parent: Path | None, repo_root: Path) -> Path:
    """Create a fresh private evidence directory; a supplied path is only its parent."""
    if supplied_parent is None:
        created_path = Path(tempfile.mkdtemp(prefix="repoprompt-omp-acp-spike."))
    else:
        parent = supplied_parent.expanduser()
        if not parent.is_absolute():
            raise ProbeError(f"output directory parent must be absolute: {parent}")
        parent = parent.resolve()
        if is_within(parent, repo_root):
            raise ProbeError(f"refusing repository-local evidence parent: {parent}")
        parent.mkdir(parents=True, exist_ok=True)
        if not parent.is_dir():
            raise ProbeError(f"output directory parent is not a directory: {parent}")
        created_path = Path(tempfile.mkdtemp(prefix="omp-acp-run.", dir=parent))
    try:
        output_dir = created_path.resolve()
        os.chmod(output_dir, 0o700)
        if is_within(output_dir, repo_root):
            raise ProbeError(f"refusing repository-local evidence directory: {output_dir}")
        if not output_dir.is_dir():
            raise ProbeError(f"evidence run path is not a directory: {output_dir}")
        return output_dir
    except BaseException as error:
        cleanup_error: BaseException | None = None
        try:
            created_path.rmdir()
        except BaseException as cleanup:
            cleanup_error = cleanup
        combined = combine_probe_errors(("evidence validation", error), ("evidence cleanup", cleanup_error))
        assert combined is not None
        raise combined


def paths_overlap(first: Path, second: Path) -> bool:
    return is_within(first, second) or is_within(second, first)


def prepare_workspace(args: argparse.Namespace, output_dir: Path, repo_root: Path) -> tuple[Path, bool]:
    """Create the default private scratch directory or validate a caller-provided one."""
    if args.workspace is None:
        created_path = Path(tempfile.mkdtemp(prefix="repoprompt-omp-acp-workspace."))
        try:
            workspace = created_path.resolve()
            if paths_overlap(workspace, repo_root):
                raise ProbeError(f"refusing workspace that overlaps the repository root: {workspace}")
            if paths_overlap(workspace, output_dir):
                raise ProbeError(f"workspace and evidence directory overlap: {workspace} / {output_dir}")
            return workspace, True
        except BaseException as error:
            cleanup_error: BaseException | None = None
            try:
                created_path.rmdir()
            except BaseException as cleanup:
                cleanup_error = cleanup
            combined = combine_probe_errors(("workspace validation", error), ("workspace cleanup", cleanup_error))
            assert combined is not None
            raise combined

    supplied = args.workspace.expanduser()
    if not supplied.is_absolute():
        raise ProbeError(f"workspace must be an absolute disposable path: {supplied}")
    workspace = supplied.resolve()
    if paths_overlap(workspace, repo_root):
        raise ProbeError(f"refusing workspace that overlaps the repository root: {workspace}")
    if paths_overlap(workspace, output_dir):
        raise ProbeError(f"workspace and evidence directory overlap: {workspace} / {output_dir}")
    if workspace.exists():
        if not workspace.is_dir():
            raise ProbeError(f"workspace is not a directory: {workspace}")
        if not args.unsafe_allow_nonempty_workspace:
            raise ProbeError(
                "refusing a pre-existing supplied workspace without proof of harness ownership; "
                "use a nonexistent disposable path, or explicitly waive ownership/exclusivity with "
                "--unsafe-allow-unverified-workspace"
            )
    else:
        workspace.mkdir(mode=0o700)
        return workspace, True
    return workspace, False


class FrameOverflow(ProbeError):
    pass


def iter_bounded_frames(stream: Any, frame_limit_bytes: int) -> Any:
    """Yield newline-delimited byte frames without buffering beyond the frame limit."""
    buffer = bytearray()
    read_chunk = getattr(stream, "read1", stream.read)
    while True:
        chunk = read_chunk(min(8192, frame_limit_bytes + 1))
        if not chunk:
            if buffer:
                yield bytes(buffer)
            return
        start = 0
        while start < len(chunk):
            newline = chunk.find(b"\n", start)
            end = len(chunk) if newline < 0 else newline
            piece = chunk[start:end]
            if len(buffer) + len(piece) > frame_limit_bytes:
                raise FrameOverflow(f"frame exceeded {frame_limit_bytes} bytes before newline")
            buffer.extend(piece)
            if newline < 0:
                break
            yield bytes(buffer)
            buffer.clear()
            start = newline + 1


class JSONLProcess:
    """A bounded JSONL-RPC subprocess driver with process-group ownership."""

    def __init__(
        self,
        command: list[str],
        cwd: Path,
        stream_limit_bytes: int = DEFAULT_STREAM_LIMIT_BYTES,
        frame_limit_bytes: int = DEFAULT_FRAME_LIMIT_BYTES,
        message_limit: int = DEFAULT_MESSAGE_LIMIT,
        termination_grace_seconds: float = DEFAULT_TERMINATION_GRACE_SECONDS,
        pump_join_timeout_seconds: float = PUMP_JOIN_TIMEOUT_SECONDS,
    ) -> None:
        self.command = command
        self.stream_limit_bytes = stream_limit_bytes
        self.frame_limit_bytes = frame_limit_bytes
        self.message_limit = message_limit
        self.termination_grace_seconds = termination_grace_seconds
        self.pump_join_timeout_seconds = pump_join_timeout_seconds
        process: subprocess.Popen[Any] | None = None
        started_threads: list[threading.Thread] = []
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            self.process = process
            self.stdout_lines: list[str] = []
            self.stderr_lines: list[str] = []
            self.messages: list[dict[str, Any]] = []
            self._processed_lines = 0
            self._stream_sizes = {"stdout": 0, "stderr": 0}
            self._overflow: str | None = None
            self._protocol_error: ProbeError | None = None
            self._pending_requests: dict[int, str] = {}
            self._completed_response_ids: set[int] = set()
            self._lock = threading.Lock()
            self._pumps_joined = False
            self._close_complete = False
            self._close_error: ProbeError | None = None
            self._threads = [
                threading.Thread(target=self._pump, args=("stdout", self.process.stdout, self.stdout_lines), daemon=True),
                threading.Thread(target=self._pump, args=("stderr", self.process.stderr, self.stderr_lines), daemon=True),
            ]
            for thread in self._threads:
                thread.start()
                started_threads.append(thread)
        except BaseException as primary:
            for thread in getattr(self, "_threads", []):
                if thread.ident is not None and thread not in started_threads:
                    started_threads.append(thread)
            if process is None:
                raise
            cleanup = rollback_process_construction(process, self.command, self.termination_grace_seconds, started_threads)
            if cleanup is not None:
                try:
                    primary.add_note(f"constructor rollback: {cleanup}")
                except BaseException:
                    pass
                raise primary from cleanup
            raise

    def _pump(self, name: str, stream: Any, sink: list[str]) -> None:
        try:
            for frame in iter_bounded_frames(stream, self.frame_limit_bytes):
                line_bytes = len(frame) + 1
                try:
                    decoded = frame.decode("utf-8") if name == "stdout" else frame.decode("utf-8", errors="replace")
                except UnicodeDecodeError as error:
                    decoded = frame.decode("utf-8", errors="replace")
                    with self._lock:
                        if self._protocol_error is None:
                            self._protocol_error = ProbeError(f"stdout contains invalid UTF-8: {error}")
                with self._lock:
                    if self._stream_sizes[name] + line_bytes <= self.stream_limit_bytes:
                        sink.append(decoded)
                        self._stream_sizes[name] += line_bytes
                    elif self._overflow is None:
                        self._overflow = f"{name} exceeded {self.stream_limit_bytes} retained bytes"
        except FrameOverflow as error:
            with self._lock:
                if self._overflow is None:
                    self._overflow = f"{name} {error}"
        except (OSError, ValueError) as error:
            with self._lock:
                if self._overflow is None:
                    self._overflow = f"{name} pump failed: {error}"

    def _check_terminal(self) -> None:
        with self._lock:
            overflow = self._overflow
            protocol_error = getattr(self, "_protocol_error", None)
        if overflow is not None:
            raise ProbeError(overflow)
        if protocol_error is not None:
            raise protocol_error

    def latch_protocol_error(self, error: BaseException) -> ProbeError:
        protocol_error = error if isinstance(error, ProbeError) else ProbeError(str(error) or type(error).__name__)
        with self._lock:
            if getattr(self, "_protocol_error", None) is None:
                self._protocol_error = protocol_error
            return self._protocol_error

    def send(self, payload: dict[str, Any]) -> None:
        self._check_terminal()
        envelope = validate_jsonrpc_message(payload)
        if self.process.stdin is None or self.process.stdin.closed:
            raise ProbeError("cannot send JSON-RPC message: subprocess stdin is closed")
        if envelope == "request":
            request_id = payload["id"]
            pending = getattr(self, "_pending_requests", None)
            if pending is None:
                self._pending_requests = {}
                pending = self._pending_requests
            completed = getattr(self, "_completed_response_ids", set())
            if request_id in pending or request_id in completed:
                raise self.latch_protocol_error(ProbeError(f"duplicate outbound JSON-RPC request id {request_id}"))
            pending[request_id] = payload["method"]
        self.process.stdin.write((json_line(payload) + "\n").encode("utf-8"))
        self.process.stdin.flush()

    def drain(
        self,
        handler: Callable[[dict[str, Any]], None] | None = None,
        stop_after_response_id: int | None = None,
    ) -> None:
        self._check_terminal()
        while self._processed_lines < len(self.stdout_lines):
            line = self.stdout_lines[self._processed_lines]
            self._processed_lines += 1
            try:
                message = strict_json_loads(line)
                envelope = validate_inbound_jsonrpc_message(message)
            except (UnicodeDecodeError, ValueError, json.JSONDecodeError, ProbeError) as error:
                protocol_error = error if isinstance(error, ProbeError) else ProbeError(f"invalid JSON-RPC stdout: {error}")
                with self._lock:
                    if getattr(self, "_protocol_error", None) is None:
                        self._protocol_error = protocol_error
                raise protocol_error
            if len(self.messages) >= self.message_limit:
                raise ProbeError(f"parsed message count exceeded {self.message_limit}")
            self.messages.append(message)
            if envelope == "response":
                response_id = message["id"]
                pending = getattr(self, "_pending_requests", {})
                completed = getattr(self, "_completed_response_ids", set())
                if response_id in completed:
                    raise self.latch_protocol_error(ProbeError(f"duplicate JSON-RPC response id {response_id}"))
                if response_id not in pending:
                    raise self.latch_protocol_error(ProbeError(f"unsolicited JSON-RPC response id {response_id}"))
                pending.pop(response_id)
                completed.add(response_id)
                self._completed_response_ids = completed
            if handler is not None:
                try:
                    handler(message)
                except BaseException as error:
                    raise self.latch_protocol_error(error)
            if envelope == "response" and message["id"] == stop_after_response_id:
                break
        self._check_terminal()

    def _response(self, request_id: int) -> dict[str, Any] | None:
        for message in reversed(self.messages):
            message_id = message.get("id")
            if type(message_id) is int and message_id == request_id and ("result" in message or "error" in message):
                return message
        return None

    def wait_for_response(
        self,
        request_id: int,
        timeout: float,
        handler: Callable[[dict[str, Any]], None] | None = None,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self._response(request_id)
            if response is not None:
                return response
            self.drain(handler, stop_after_response_id=request_id)
            response = self._response(request_id)
            if response is not None:
                return response
            if self.process.poll() is not None:
                self._join_pumps()
                break
            time.sleep(0.01)
        if self.process.poll() is not None:
            self._join_pumps()
        self.drain(handler, stop_after_response_id=request_id)
        response = self._response(request_id)
        if response is not None:
            return response
        raise ProbeError(
            f"timed out waiting for JSON-RPC response {request_id} after {timeout}s; "
            f"subprocess exit={self.process.poll()}"
        )

    def drain_for(self, seconds: float, handler: Callable[[dict[str, Any]], None] | None = None) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.drain(handler)
            if self.process.poll() is not None:
                self._join_pumps()
                break
            time.sleep(0.01)
        if self.process.poll() is not None:
            self._join_pumps()
        self.drain(handler)

    def _join_pumps(self) -> None:
        if self._pumps_joined:
            return
        for thread in self._threads:
            thread.join(self.pump_join_timeout_seconds)
        if any(thread.is_alive() for thread in self._threads):
            raise ProbeError(f"JSONL output pump did not stop: {' '.join(self.command)}")
        for stream in (self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        self._pumps_joined = True

    def write_evidence(self, prefix: Path) -> None:
        if not self._pumps_joined:
            raise ProbeError("refusing evidence I/O before JSONL output pumps are joined")
        try:
            write_private_text(prefix.with_suffix(".stdout.jsonl"), "\n".join(self.stdout_lines) + "\n")
            write_private_text(prefix.with_suffix(".stderr.txt"), "\n".join(self.stderr_lines) + "\n")
        except OSError as error:
            raise ProbeError(f"could not write JSONL subprocess evidence at {prefix}: {error}") from error

    def close(self) -> None:
        """Close stdin, then reap the leader and every survivor in its process group."""
        if self._close_complete:
            close_error = getattr(self, "_close_error", None)
            if close_error is not None:
                raise close_error
            return
        stdin_error: BaseException | None = None
        terminate_error: BaseException | None = None
        retry_error: BaseException | None = None
        join_error: BaseException | None = None
        terminal_error: BaseException | None = None
        if self.process.stdin is not None and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BaseException as error:
                stdin_error = error
        try:
            terminate_process_group(self.process, self.command, self.termination_grace_seconds)
        except BaseException as error:
            terminate_error = error
            try:
                terminate_process_group(self.process, self.command, self.termination_grace_seconds)
            except BaseException as retry:
                retry_error = retry
        try:
            self._join_pumps()
        except BaseException as error:
            join_error = error
        try:
            self._check_terminal()
        except BaseException as error:
            terminal_error = error
        combined = combine_probe_errors(
            ("process-group teardown", terminate_error),
            ("process-group teardown retry", retry_error),
            ("pump completion", join_error),
            ("stdin close", stdin_error),
            ("terminal output", terminal_error),
        )
        self._close_complete = True
        self._close_error = combined
        if combined is not None:
            raise combined


def require_result(label: str, response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error")
    if error is not None:
        raise ProbeError(f"{label} returned JSON-RPC error: {error}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise ProbeError(f"{label} returned a non-object result")
    return result


def validate_known_update_payload(kind: str, update: dict[str, Any]) -> dict[str, Any]:
    if kind in {"agent_message_chunk", "agent_thought_chunk", "user_message_chunk"}:
        content = update.get("content")
        elements = content if isinstance(content, list) else [content]
        if not elements or any(
            not (
                isinstance(element, str)
                or (isinstance(element, dict) and isinstance(element.get("text"), str))
            )
            for element in elements
        ):
            raise ProbeError(f"malformed {kind} content")
        text = "".join(
            element if isinstance(element, str) else element["text"]
            for element in elements
        )
        return {"text": text}
    if kind in {"tool_call", "tool_call_update"}:
        nested = update.get("toolCall")
        if "toolCall" in update and not isinstance(nested, dict):
            raise ProbeError("known tool event has malformed nested toolCall")
        nested_object = nested if isinstance(nested, dict) else {}
        title_values: list[str] = []
        id_values: list[str] = []
        for source in (update, nested_object):
            if "title" in source:
                if not isinstance(source["title"], str):
                    raise ProbeError("known tool event title must be a string")
                title_values.append(source["title"])
            for key in ("toolCallId", "id"):
                if key in source:
                    if not isinstance(source[key], str):
                        raise ProbeError("known tool event id must be a string")
                    id_values.append(source[key])
        if any(not value.strip() for value in id_values):
            raise ProbeError("known tool event id must be non-empty after trimming")
        if len(set(title_values)) > 1:
            raise ProbeError(f"conflicting tool titles: {title_values}")
        if len(set(id_values)) > 1:
            raise ProbeError(f"conflicting tool ids: {id_values}")
        if not id_values or (kind == "tool_call" and not title_values):
            raise ProbeError("known tool event is missing required string id or title")
        return {
            "title": title_values[0] if title_values else None,
            "toolCallId": id_values[0],
        }
    if kind == "usage_update":
        def finite_number(value: Any, label: str) -> float:
            if isinstance(value, bool) or not isinstance(value, (int, float, str)):
                raise ProbeError(f"usage_update {label} must be numeric")
            try:
                number = float(value.strip() if isinstance(value, str) else value)
            except ValueError as error:
                raise ProbeError(f"usage_update {label} must be numeric") from error
            if not math.isfinite(number) or number < 0:
                raise ProbeError(f"usage_update {label} must be finite and non-negative")
            return number

        present = False
        for key in ("used", "size"):
            if key in update:
                present = True
                number = finite_number(update[key], key)
                if not number.is_integer():
                    raise ProbeError(f"usage_update {key} must be an integer")
        if "cost" in update:
            present = True
            cost = update["cost"]
            if isinstance(cost, dict):
                if set(cost) - {"amount", "currency"} or "amount" not in cost:
                    raise ProbeError("usage_update cost object must contain only amount and optional currency")
                finite_number(cost["amount"], "cost.amount")
                if "currency" in cost and (
                    not isinstance(cost["currency"], str) or not cost["currency"].strip()
                ):
                    raise ProbeError("usage_update cost.currency must be a non-empty string")
            else:
                finite_number(cost, "cost")
        if not present:
            raise ProbeError("usage_update requires used, size, or cost")
        return {}
    if kind == "available_commands_update":
        if not isinstance(update.get("availableCommands"), list):
            raise ProbeError("available_commands_update requires an availableCommands array")
        return {}
    if kind == "session_info_update":
        if "title" in update and not isinstance(update["title"], str):
            raise ProbeError("session_info_update title must be a string when supplied")
        return {}
    raise ProbeError(f"unsupported ACP session-update kind: {kind}")


def text_chunks(update: dict[str, Any]) -> str:
    return str(validate_known_update_payload("agent_message_chunk", update)["text"])


def tool_title(update: dict[str, Any], kind: str = "tool_call") -> str | None:
    return validate_known_update_payload(kind, update).get("title")


def tool_event_id(update: dict[str, Any], kind: str = "tool_call") -> str | None:
    value = validate_known_update_payload(kind, update).get("toolCallId")
    return value if isinstance(value, str) else None


def _unlink_exclusively_created_file(path: Path, created: os.stat_result) -> None:
    parent_fd = _open_directory_fd(path.parent)
    operation_error: BaseException | None = None
    try:
        try:
            current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None:
            if not stat.S_ISREG(current.st_mode) or _entry_identity(current) != _entry_identity(created):
                raise ProbeError(f"refusing to unlink replaced private file after write failure: {path}")
            os.unlink(path.name, dir_fd=parent_fd)
    except BaseException as error:
        operation_error = error
    close_error: BaseException | None = None
    try:
        os.close(parent_fd)
    except BaseException as error:
        close_error = error
    combined = combine_probe_errors(("owned private file unlink", operation_error), ("parent descriptor close", close_error))
    if combined is not None:
        raise combined


def write_private_text(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    created: os.stat_result | None = None
    stream: Any = None
    try:
        created = os.fstat(descriptor)
        stream = os.fdopen(descriptor, "w", encoding="utf-8")
        descriptor = -1
        stream.write(content)
        stream.flush()
        stream.close()
        stream = None
    except BaseException as primary:
        cleanup_causes: list[tuple[str, BaseException | None]] = []
        if created is None:
            try:
                if descriptor < 0:
                    raise ProbeError("private file identity recovery lacks an open descriptor")
                created = os.fstat(descriptor)
            except BaseException as error:
                cleanup_causes.append(("private file identity recovery", error))
        if created is not None:
            try:
                _unlink_exclusively_created_file(path, created)
            except BaseException as error:
                cleanup_causes.append(("private file cleanup", error))
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException as error:
                cleanup_causes.append(("private file stream close", error))
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except BaseException as error:
                cleanup_causes.append(("private file descriptor close", error))
        cleanup = combine_probe_errors(*cleanup_causes)
        if cleanup is not None:
            try:
                primary.add_note(f"private file cleanup: {cleanup}")
            except BaseException:
                pass
            raise primary from cleanup
        raise


def write_json_atomically(path: Path, payload: dict[str, Any]) -> None:
    temporary_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        write_private_text(temporary_path, json.dumps(payload, indent=2, sort_keys=True) + "\n")
        if path.exists() or path.is_symlink():
            raise FileExistsError(f"refusing to replace existing evidence: {path}")
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def read_private_json(path: Path) -> Any:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError(f"evidence is not a regular file: {path}")
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            descriptor = -1
            return json.load(stream)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def readonly_workspace_tree(
    workspace: Path,
    entry_limit: int = READONLY_TREE_ENTRY_LIMIT,
    deadline_seconds: float = DEFAULT_SNAPSHOT_DEADLINE_SECONDS,
) -> list[dict[str, str]]:
    """Return a bounded metadata-only view without hashing workspace contents."""
    if entry_limit < 0 or deadline_seconds <= 0:
        raise ProbeError("read-only workspace tree limits are invalid")
    deadline = time.monotonic() + deadline_seconds
    result: list[dict[str, str]] = [{"path": ".", "kind": "directory"}]
    pending: deque[tuple[int, str]] = deque()
    try:
        try:
            root_fd = _open_directory_fd(workspace)
        except OSError as error:
            raise ProbeError(f"read-only workspace root is not a directory: {workspace}: {error}") from error
        root_metadata = os.fstat(root_fd)
        if not stat.S_ISDIR(root_metadata.st_mode):
            os.close(root_fd)
            raise ProbeError(f"read-only workspace root is not a directory: {workspace}")
        pending.append((root_fd, "."))
        while pending and len(result) < entry_limit:
            if time.monotonic() >= deadline:
                raise ProbeError("read-only workspace tree deadline exceeded")
            directory_fd, relative_directory = pending.popleft()
            try:
                entries: list[tuple[str, os.stat_result]] = []
                with os.scandir(directory_fd) as iterator:
                    for entry in iterator:
                        if len(result) + len(entries) >= entry_limit:
                            break
                        if time.monotonic() >= deadline:
                            raise ProbeError("read-only workspace tree deadline exceeded")
                        entries.append((entry.name, entry.stat(follow_symlinks=False)))
                for name, metadata in sorted(entries):
                    relative_path = name if relative_directory == "." else f"{relative_directory}/{name}"
                    if stat.S_ISDIR(metadata.st_mode):
                        try:
                            child_fd = _open_directory_fd(name, dir_fd=directory_fd)
                            opened = os.fstat(child_fd)
                            if not stat.S_ISDIR(opened.st_mode) or _entry_identity(opened) != _entry_identity(metadata):
                                raise ProbeError(f"read-only workspace directory changed before open: {relative_path}")
                        except BaseException:
                            if "child_fd" in locals():
                                os.close(child_fd)
                                del child_fd
                            raise
                        kind = "directory"
                        pending.append((child_fd, relative_path))
                        del child_fd
                    elif stat.S_ISREG(metadata.st_mode):
                        kind = "file"
                    elif stat.S_ISLNK(metadata.st_mode):
                        kind = "symlink"
                    else:
                        raise ProbeError(f"unsupported read-only workspace tree entry: {relative_path}")
                    result.append({"path": relative_path, "kind": kind})
            finally:
                os.close(directory_fd)
    except OSError as error:
        raise ProbeError(f"cannot inspect read-only workspace tree: {error}") from error
    finally:
        while pending:
            descriptor, _ = pending.popleft()
            os.close(descriptor)
    return result


def strict_json_loads(data: bytes | str) -> Any:
    def reject_constant(value: str) -> Any:
        raise ValueError(f"non-standard JSON constant: {value}")

    return json.loads(data, parse_constant=reject_constant)


def valid_jsonrpc_id(value: Any) -> bool:
    return isinstance(value, str) or type(value) is int


def valid_client_jsonrpc_id(value: Any) -> bool:
    return type(value) is int


def validate_inbound_jsonrpc_message(message: Any) -> str:
    if isinstance(message, dict) and "method" in message:
        return validate_jsonrpc_message(message, valid_jsonrpc_id)
    return validate_jsonrpc_message(message)


def validate_jsonrpc_message(
    message: Any,
    id_validator: Callable[[Any], bool] = valid_client_jsonrpc_id,
) -> str:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        raise ProbeError("invalid JSON-RPC 2.0 envelope")
    has_method = "method" in message
    has_result = "result" in message
    has_error = "error" in message
    if has_method:
        allowed = {"jsonrpc", "id", "method", "params"}
        if set(message) - allowed or not isinstance(message.get("method"), str) or has_result or has_error:
            raise ProbeError("invalid JSON-RPC request or notification envelope")
        if "id" in message and not id_validator(message["id"]):
            raise ProbeError("JSON-RPC request id has an invalid type")
        if "params" in message and not isinstance(message["params"], (dict, list)):
            raise ProbeError("JSON-RPC params must be an object or array")
        return "request" if "id" in message else "notification"
    allowed = {"jsonrpc", "id", "result", "error"}
    if set(message) - allowed or not id_validator(message.get("id")) or has_result == has_error:
        raise ProbeError("invalid JSON-RPC response envelope")
    if has_error:
        error = message["error"]
        if (
            not isinstance(error, dict)
            or type(error.get("code")) is not int
            or not isinstance(error.get("message"), str)
        ):
            raise ProbeError("invalid JSON-RPC error response envelope")
    return "response"


def readonly_mcp_proxy_main(argv: list[str]) -> int:
    """Serve one synthetic, read-only MCP tool to an OMP ACP subprocess.

    This mode is launched only by the round-trip probe.  It is intentionally a
    test double rather than the production helper: OMP must complete exactly the
    minimal initialize/initialized/tools-list/tools-call sequence.  The sole tool
    accepts no arguments and returns only disposable-workspace metadata.
    """
    parser = argparse.ArgumentParser(description=readonly_mcp_proxy_main.__doc__)
    parser.add_argument("--mode", choices=("discovery", "roundtrip"), required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--audit-file", type=Path, required=True)
    parser.add_argument("--frame-limit-bytes", type=int, default=DEFAULT_FRAME_LIMIT_BYTES, help=argparse.SUPPRESS)
    # The live harness needs the audit before OMP's process-group teardown. Keep
    # this hidden and opt-in: normal proxy tests continue reading to EOF and
    # reject any post-completion request.
    parser.add_argument("--exit-on-complete", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    workspace = args.workspace.expanduser().resolve()
    audit_file = args.audit_file.expanduser().resolve()
    advertised_tools = [] if args.mode == "discovery" else ["get_file_tree"]
    audit: dict[str, Any] = {
        "kind": "test-only-readonly-mcp-proxy",
        "mode": args.mode,
        "advertisedToolNames": advertised_tools,
        "allowedToolCallCount": 0,
        "rejectedRequests": [],
        "rejectedRequestCount": 0,
        "protocolSequence": [],
        "pingCount": 0,
        "benignNotificationCounts": {},
        "protocolComplete": False,
        "exitedOnComplete": False,
        "exitCode": 1,
    }
    expected_step = "initialize"
    exit_code = 1
    abnormal_error: BaseException | None = None
    benign_notifications = {
        "notifications/cancelled",
        "notifications/progress",
        "notifications/roots/list_changed",
    }

    def send(payload: dict[str, Any]) -> None:
        sys.stdout.write(json_line(payload) + "\n")
        sys.stdout.flush()

    def reject(request_id: Any, method: str | None, detail: str, tool_name: str | None = None) -> None:
        audit["rejectedRequestCount"] += 1
        if len(audit["rejectedRequests"]) < DEFAULT_PROXY_REJECTION_LIMIT:
            audit["rejectedRequests"].append(
                {"method": method, "toolName": tool_name, "reason": detail}
            )
        if valid_jsonrpc_id(request_id):
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
        if args.frame_limit_bytes <= 0:
            raise ProbeError("proxy frame limit must be positive")
        for frame in iter_bounded_frames(sys.stdin.buffer, args.frame_limit_bytes):
            try:
                message = strict_json_loads(frame)
            except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
                reject(None, None, "invalid-json")
                continue
            if not isinstance(message, dict):
                reject(None, None, "non-object-message")
                continue
            request_id = message.get("id")
            method = message.get("method")
            try:
                envelope = validate_jsonrpc_message(message, valid_jsonrpc_id)
            except ProbeError as error:
                reject(request_id, method if isinstance(method, str) else None, str(error))
                continue
            if envelope not in {"request", "notification"}:
                reject(request_id, method if isinstance(method, str) else None, "proxy accepts only JSON-RPC requests and notifications")
                continue
            assert isinstance(method, str)
            if method == "ping":
                if not valid_jsonrpc_id(request_id) or ("params" in message and message["params"] != {}):
                    reject(request_id, method, "ping requires a scalar id and absent or empty params")
                    continue
                audit["pingCount"] += 1
                send({"jsonrpc": "2.0", "id": request_id, "result": {}})
                continue
            if method in benign_notifications:
                parameters = message.get("params", {})
                valid = "id" not in message and isinstance(parameters, dict)
                if method == "notifications/progress":
                    progress = parameters.get("progress")
                    valid = (
                        valid
                        and valid_jsonrpc_id(parameters.get("progressToken"))
                        and type(progress) in {int, float}
                        and math.isfinite(progress)
                    )
                elif method == "notifications/cancelled":
                    valid = valid and valid_jsonrpc_id(parameters.get("requestId"))
                else:
                    valid = valid and parameters == {}
                if not valid:
                    reject(request_id, method, "benign notification has invalid required params")
                    continue
                counts = audit["benignNotificationCounts"]
                counts[method] = int(counts.get(method, 0)) + 1
                continue
            if method == "initialize":
                if not valid_jsonrpc_id(request_id):
                    reject(request_id, method, "initialize requires a string or integer request id")
                    continue
                if expected_step != "initialize":
                    reject(request_id, method, "duplicate or out-of-order initialize")
                    continue
                parameters = message.get("params")
                if (
                    not isinstance(parameters, dict)
                    or not isinstance(parameters.get("protocolVersion"), str)
                    or not isinstance(parameters.get("capabilities"), dict)
                    or not isinstance(parameters.get("clientInfo"), dict)
                    or not isinstance(parameters["clientInfo"].get("name"), str)
                    or not isinstance(parameters["clientInfo"].get("version"), str)
                ):
                    reject(request_id, method, "initialize requires protocolVersion, capabilities, and clientInfo")
                    continue
                audit["protocolSequence"].append(method)
                audit["initializeRequestObserved"] = True
                expected_step = "initialized"
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "protocolVersion": MCP_PROTOCOL_VERSION,
                            "capabilities": {"tools": {"listChanged": False}},
                            "serverInfo": {"name": "RepoPromptCE-readonly-spike-proxy", "version": "1"},
                        },
                    }
                )
                continue
            if method == "notifications/initialized":
                if "id" in message or ("params" in message and message["params"] != {}) or expected_step != "initialized":
                    reject(request_id, method, "duplicate or out-of-order initialized notification")
                    continue
                audit["initializedNotificationObserved"] = True
                audit["protocolSequence"].append(method)
                expected_step = "tools/list"
                continue
            if method == "tools/list":
                if not valid_jsonrpc_id(request_id):
                    reject(request_id, method, "tools/list requires a string or integer request id")
                    continue
                if expected_step != "tools/list":
                    reject(request_id, method, "duplicate or out-of-order tools/list")
                    continue
                if "params" in message and message["params"] != {}:
                    reject(request_id, method, "tools/list params must be absent or empty")
                    continue
                audit["toolsListObserved"] = True
                audit["protocolSequence"].append(method)
                expected_step = "complete" if args.mode == "discovery" else "tools/call"
                tools = [] if args.mode == "discovery" else [
                    {
                        "name": "get_file_tree",
                        "description": "Read-only disposable-workspace tree for OMP ACP transport testing.",
                        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
                    }
                ]
                send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": tools}})
                if args.mode == "discovery" and args.exit_on_complete:
                    audit["exitedOnComplete"] = True
                    break
                continue
            if method == "tools/call":
                if args.mode != "roundtrip":
                    reject(request_id, method, "tools/call is forbidden in discovery mode")
                    continue
                if not valid_jsonrpc_id(request_id):
                    reject(request_id, method, "tools/call requires a string or integer request id")
                    continue
                parameters = message.get("params")
                if not isinstance(parameters, dict):
                    reject(request_id, method, "tools/call params must be an object")
                    continue
                tool_name = parameters.get("name")
                if expected_step != "tools/call":
                    reject(request_id, method, "duplicate or out-of-order tools/call", tool_name if isinstance(tool_name, str) else None)
                    continue
                if tool_name != "get_file_tree":
                    reject(request_id, method if isinstance(method, str) else None, "tool is not available in the read-only spike proxy", tool_name if isinstance(tool_name, str) else None)
                    continue
                arguments = parameters.get("arguments", {})
                if arguments != {}:
                    reject(request_id, method, "get_file_tree arguments must be absent or empty", tool_name)
                    continue
                audit["observedToolArguments"] = arguments
                audit["toolArgumentsSchemaViolation"] = False
                audit["allowedToolCallCount"] = 1
                audit["workspaceTreeServed"] = True
                audit["protocolSequence"].append(method)
                expected_step = "complete"
                tree = readonly_workspace_tree(workspace)
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
                if args.exit_on_complete:
                    audit["exitedOnComplete"] = True
                    break
                continue
            reject(request_id, method if isinstance(method, str) else None, "method is not available in the read-only spike proxy")
    except BaseException as error:
        if isinstance(error, FrameOverflow):
            reject(None, None, "oversized-line")
        else:
            print(f"read-only MCP proxy failed: {error}", file=sys.stderr)
        audit["error"] = str(error) or type(error).__name__
        abnormal_error = error
        exit_code = 1
    finally:
        protocol_complete = expected_step == "complete"
        clean_completion = protocol_complete and audit["rejectedRequestCount"] == 0 and abnormal_error is None
        exit_code = 0 if clean_completion else 1
        audit["protocolComplete"] = protocol_complete
        audit["exitCode"] = exit_code
        try:
            audit_file.parent.mkdir(parents=True, exist_ok=True)
            write_json_atomically(audit_file, audit)
        except BaseException as error:
            print(f"read-only MCP proxy could not write audit evidence: {error}", file=sys.stderr)
            exit_code = 1
    if isinstance(abnormal_error, (KeyboardInterrupt, SystemExit)):
        raise abnormal_error
    return exit_code


def load_readonly_proxy_audit(
    path: Path,
    expected_mode: str,
    *,
    require_exit_on_complete: bool = False,
) -> dict[str, Any]:
    try:
        payload = read_private_json(path)
    except (OSError, json.JSONDecodeError) as error:
        raise ProbeError(f"read-only MCP proxy did not leave valid audit evidence: {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("mode") != expected_mode:
        raise ProbeError(f"read-only MCP proxy audit mode is not {expected_mode}")
    if not isinstance(payload.get("exitedOnComplete"), bool):
        raise ProbeError("read-only MCP proxy audit has an invalid completion-exit marker")
    if require_exit_on_complete and not payload["exitedOnComplete"]:
        raise ProbeError("read-only MCP proxy did not finalize its audit before teardown")
    expected_sequence = ["initialize", "notifications/initialized", "tools/list"]
    expected_tools: list[str] = []
    expected_calls = 0
    if expected_mode == "roundtrip":
        expected_sequence.append("tools/call")
        expected_tools = ["get_file_tree"]
        expected_calls = 1
    elif expected_mode != "discovery":
        raise ProbeError(f"unknown read-only MCP proxy audit mode: {expected_mode}")
    if payload.get("advertisedToolNames") != expected_tools:
        raise ProbeError("read-only MCP proxy advertised an unexpected tool surface")
    if payload.get("allowedToolCallCount") != expected_calls:
        raise ProbeError(f"{expected_mode} proxy observed an unexpected tool-call count")
    if payload.get("protocolSequence") != expected_sequence or not payload.get("protocolComplete"):
        raise ProbeError(f"{expected_mode} proxy did not complete its exact MCP sequence")
    if expected_mode == "roundtrip" and (
        payload.get("observedToolArguments") != {} or payload.get("toolArgumentsSchemaViolation")
    ):
        raise ProbeError("roundtrip supplied unexpected arguments to the read-only MCP tool")
    if payload.get("rejectedRequestCount") or payload.get("rejectedRequests"):
        raise ProbeError(f"{expected_mode} attempted an MCP request outside the proxy surface")
    if payload.get("exitCode") != 0:
        raise ProbeError("read-only MCP proxy exited with an error")
    return payload


def close_and_write_jsonl_evidence(
    process: JSONLProcess,
    prefix: Path,
    tail_handler: Callable[[dict[str, Any]], None] | None = None,
) -> None:
    close_error: BaseException | None = None
    tail_error: BaseException | None = None
    evidence_error: BaseException | None = None
    try:
        process.close()
    except BaseException as error:
        close_error = error
    if tail_handler is not None:
        latched_before_tail = process._protocol_error
        first_tail_latch: ProbeError | None = None
        tail_causes: list[tuple[str, BaseException | None]] = []
        while True:
            processed_before = getattr(process, "_processed_lines", 0)
            process._protocol_error = None
            try:
                process.drain(tail_handler)
            except BaseException as error:
                if error is not latched_before_tail:
                    tail_causes.append((f"tail frame {len(tail_causes) + 1}", error))
            current_latch = process._protocol_error
            if first_tail_latch is None and current_latch is not None:
                first_tail_latch = current_latch
            processed_after = getattr(process, "_processed_lines", processed_before)
            stdout_lines = getattr(process, "stdout_lines", [])
            if len(tail_causes) >= TAIL_CAUSE_LIMIT - 1:
                remaining = len(stdout_lines) - processed_after
                if remaining > 0:
                    tail_causes.append(
                        (
                            "tail adjudication cap",
                            ProbeError(
                                f"stopped after {TAIL_CAUSE_LIMIT - 1} tail causes; "
                                f"{remaining} retained frames left unadjudicated; "
                                "raw stdout evidence retains all frames",
                                {"omittedOrUnadjudicatedRetainedFrameCount": remaining},
                            ),
                        )
                    )
                break
            if processed_after >= len(stdout_lines) or processed_after <= processed_before:
                break
        process._protocol_error = latched_before_tail or first_tail_latch
        tail_error = combine_probe_errors(*tail_causes)
    try:
        process.write_evidence(prefix)
    except BaseException as error:
        evidence_error = error
    combined = combine_probe_errors(
        ("process close", close_error),
        ("tail drain", tail_error),
        ("evidence write", evidence_error),
    )
    if combined is not None:
        raise combined


def helper_preflight(helper: Path, workspace: Path, output_dir: Path) -> dict[str, Any]:
    process = JSONLProcess([str(helper)], workspace)
    result: dict[str, Any] | None = None
    primary_error: BaseException | None = None

    def helper_inbound_handler(message: dict[str, Any]) -> None:
        method = message.get("method")
        if "id" not in message or not isinstance(method, str):
            return
        safe_method = "".join(character if 32 <= ord(character) < 127 else "?" for character in method)[:128]
        error = UnexpectedInboundRequestError(
            f"helper rejected inbound request method={safe_method!r} id={message['id']!r}"
        )
        process.latch_protocol_error(error)
        raise error

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
        initialize = require_result(
            "MCP initialize",
            process.wait_for_response(1, DEFAULT_TIMEOUT_SECONDS, handler=helper_inbound_handler),
        )
        process.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        process.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools_result = require_result(
            "MCP tools/list",
            process.wait_for_response(2, DEFAULT_TIMEOUT_SECONDS, handler=helper_inbound_handler),
        )
        tools = tools_result.get("tools")
        if not isinstance(tools, list):
            raise ProbeError("MCP tools/list result does not contain a tools array")
        result = {
            "serverInfo": initialize.get("serverInfo"),
            "capabilityKeys": sorted((initialize.get("capabilities") or {}).keys()),
            "toolCount": len(tools),
            "toolNames": [item.get("name") for item in tools if isinstance(item, dict) and isinstance(item.get("name"), str)],
        }
    except BaseException as error:
        primary_error = error
    cleanup_error: BaseException | None = None
    try:
        close_and_write_jsonl_evidence(
            process,
            output_dir / "repoprompt-mcp",
            tail_handler=helper_inbound_handler,
        )
    except BaseException as error:
        cleanup_error = error
    combined = combine_probe_errors(("helper probe", primary_error), ("helper finalization", cleanup_error))
    if combined is not None:
        raise combined
    assert result is not None
    return result


def normalize_acknowledgement(value: str) -> str:
    return " ".join(value.split())


def has_unique_final_acknowledgement_token(value: str, acknowledgement: str) -> bool:
    normalized = normalize_acknowledgement(value)
    matches = list(re.finditer(re.escape(acknowledgement), normalized))
    if len(matches) != 1 or matches[0].end() != len(normalized):
        return False
    start = matches[0].start()
    return start == 0 or not ("a" + normalized[start - 1]).isidentifier()


def bounded_workspace_names(
    workspace: Path,
    limit: int = WORKSPACE_NAME_LIMIT,
    deadline_seconds: float = WORKSPACE_NAME_DEADLINE_SECONDS,
) -> tuple[list[str], bool]:
    deadline = time.monotonic() + deadline_seconds
    names: list[str] = []
    try:
        with os.scandir(workspace) as iterator:
            for entry in iterator:
                if time.monotonic() >= deadline:
                    raise ProbeError("workspace filename evidence deadline exceeded")
                names.append(entry.name)
                if len(names) > limit:
                    break
    except OSError as error:
        raise ProbeError(f"cannot collect bounded workspace filename evidence: {error}") from error
    truncated = len(names) > limit
    return sorted(names[:limit]), truncated


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
    process = BoundedTextProcess(command, cwd=workspace)
    stdout = ""
    stderr = ""
    primary_error: BaseException | None = None
    return_code = -1
    try:
        return_code, stdout, stderr = process.wait(timeout + 20)
    except BaseException as error:
        primary_error = error
        stdout = process.text("stdout")
        stderr = process.text("stderr")
    evidence_errors: list[tuple[str, BaseException | None]] = []
    try:
        write_private_text(output_dir / "omp-cli-prompt.stdout.txt", stdout)
    except BaseException as error:
        evidence_errors.append(("stdout evidence", error))
    try:
        write_private_text(output_dir / "omp-cli-prompt.stderr.txt", stderr)
    except BaseException as error:
        evidence_errors.append(("stderr evidence", error))
    combined = combine_probe_errors(("CLI prompt", primary_error), *evidence_errors)
    if combined is not None:
        raise combined
    if return_code != 0:
        raise ProbeError(f"bare OMP print-mode prompt exited {return_code}")
    if normalize_acknowledgement(stdout) != acknowledgement:
        raise ProbeError("bare OMP print-mode prompt did not return only the exact acknowledgement")
    return {
        "command": ["omp", "--no-session", *MANAGED_OMP_ARGUMENTS[1:], f"--max-time={timeout}", "--print"],
        "acknowledgementObserved": True,
    }


def resolve_debug_cli(raw: str | None, _bundled_helper: Path) -> tuple[Path, str]:
    explicit = raw if raw is not None else os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH")
    if explicit is not None:
        path = Path(explicit).expanduser()
        if not path.is_file() or not os.access(path, os.X_OK):
            source = "--debug-cli" if raw is not None else "REPOPROMPT_DEBUG_CLI_INSTALL_PATH"
            raise ProbeError(f"explicit {source} override is not an executable file")
        return path.resolve(strict=True), "--debug-cli" if raw is not None else "environment"

    candidates = [
        (shutil.which("rpce-cli-debug"), "PATH"),
        (str(Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"), "user-install"),
    ]
    for candidate, provenance in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path.resolve(strict=True), provenance
    raise ProbeError(
        "rpce-cli-debug was not found via PATH or the user-space fallback"
    )


def strict_response_json(raw: str) -> object:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ProbeError(f"rpce-cli-debug response contains duplicate key: {key}")
            result[key] = value
        return result

    try:
        return json.loads(raw, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise ProbeError("rpce-cli-debug response was malformed JSON") from error


def strict_diagnostic_payload(document: object, op: str, required_key: str) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise ProbeError(f"rpce-cli-debug {op} response was not an object")

    def reject_error_envelope(value: dict[str, Any], label: str) -> None:
        if "error" in value or ("isError" in value and value["isError"] is not False):
            raise ProbeError(f"rpce-cli-debug {op} returned a failed or malformed {label} envelope")

    def append_candidate(value: object, label: str, candidates: list[dict[str, Any]]) -> None:
        if not matches(value):
            return
        assert isinstance(value, dict)
        reject_error_envelope(value, label)
        if set(value).intersection({"result", "structuredContent", "structured_content"}):
            raise ProbeError(f"rpce-cli-debug {op} returned a nested wrapper hybrid in {label}")
        candidates.append(value)

    def matches(value: object) -> bool:
        return (
            isinstance(value, dict)
            and value.get("ok") is True
            and value.get("op") == op
            and required_key in value
        )

    reject_error_envelope(document, "top-level")
    candidates: list[dict[str, Any]] = []
    append_candidate(document, "top-level payload", candidates)
    result = document.get("result")
    if isinstance(result, dict):
        reject_error_envelope(result, "result")
        append_candidate(result, "result payload", candidates)
        for key in ("structuredContent", "structured_content"):
            append_candidate(result.get(key), f"result.{key} payload", candidates)
    for key in ("structuredContent", "structured_content"):
        append_candidate(document.get(key), f"top-level {key} payload", candidates)
    if len(candidates) != 1:
        raise ProbeError(f"rpce-cli-debug {op} response did not contain exactly one documented diagnostic payload")
    return candidates[0]


def debug_diagnostics_payload(
    cli: Path,
    op: str,
    arguments: dict[str, Any],
    required_key: str,
) -> dict[str, Any]:
    command = [
        str(cli),
        "--raw-json",
        "-c",
        "__repoprompt_debug_diagnostics",
        "-j",
        json.dumps({"op": op, **arguments}, separators=(",", ":"), sort_keys=True),
    ]
    raw = run_text(
        command,
        timeout=DEFAULT_TIMEOUT_SECONDS,
        stream_limit_bytes=PROCESS_INSPECTION_OUTPUT_LIMIT_BYTES,
    )
    document = strict_response_json(raw)
    return strict_diagnostic_payload(document, op, required_key)


def debug_connection_history(cli: Path, connection_id: str | None = None) -> list[dict[str, Any]]:
    expected_connection_id = connection_id
    arguments: dict[str, Any] = {"limit": PRODUCTION_HISTORY_LIMIT}
    if expected_connection_id is not None:
        arguments["connection_id"] = expected_connection_id
    payload = debug_diagnostics_payload(
        cli,
        "connection_history",
        arguments,
        "events",
    )
    events = payload.get("events")
    if not isinstance(events, list) or len(events) > PRODUCTION_HISTORY_LIMIT:
        raise ProbeError("DEBUG connection history has an invalid or excessive event count")
    previous_seq = -1
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("seq"), int):
            raise ProbeError("DEBUG connection history contains a malformed event")
        if event["seq"] <= previous_seq:
            raise ProbeError("DEBUG connection history sequence is not strictly increasing")
        previous_seq = event["seq"]
        event_connection_id = event.get("connection_id")
        if event_connection_id is not None:
            try:
                uuid.UUID(event_connection_id)
            except (ValueError, TypeError) as error:
                raise ProbeError("DEBUG connection history contains an invalid connection UUID") from error
        if expected_connection_id is not None and event_connection_id != expected_connection_id:
            raise ProbeError("DEBUG connection history returned an event for the wrong connection UUID")
    return events


def debug_connection_snapshot(cli: Path, connection_id: str) -> dict[str, Any]:
    payload = debug_diagnostics_payload(
        cli,
        "connection_snapshot",
        {"connection_id": connection_id, "include_history": False},
        "connection",
    )
    connection = payload.get("connection")
    if payload.get("missing") is True or connection is None:
        raise ProbeError("production helper connection disappeared before identity capture")
    if not isinstance(connection, dict) or connection.get("id") != connection_id:
        raise ProbeError("DEBUG connection snapshot did not match the requested UUID")
    return connection


def parse_process_snapshot(raw: str) -> dict[int, dict[str, Any]]:
    rows: dict[int, dict[str, Any]] = {}
    lines = raw.splitlines()
    if len(lines) > PROCESS_INSPECTION_ROW_LIMIT:
        raise ProbeError(f"process inspection exceeded {PROCESS_INSPECTION_ROW_LIMIT} rows")
    for line in lines:
        fields = line.strip().split(None, 7)
        if not fields:
            continue
        if len(fields) != 8:
            raise ProbeError("process inspection returned a malformed row")
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError as error:
            raise ProbeError("process inspection returned a non-numeric PID") from error
        if pid <= 0 or ppid < 0 or pid in rows:
            raise ProbeError("process inspection returned an invalid or duplicate PID")
        rows[pid] = {
            "pid": pid,
            "parent_pid": ppid,
            "start_time": " ".join(fields[2:7]),
            "executable": fields[7],
        }
    return rows


def live_process_executable(pid: int) -> Path:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidpath = libproc.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(PROCESS_EXECUTABLE_PATH_LIMIT_BYTES)
        length = proc_pidpath(pid, buffer, len(buffer))
    except (AttributeError, OSError) as error:
        raise ProbeError(f"cannot resolve executable path for PID {pid}: {error}") from error
    if length <= 0:
        errno_value = ctypes.get_errno()
        raise ProbeError(f"cannot resolve executable path for PID {pid}: errno={errno_value}")
    try:
        decoded = os.fsdecode(buffer.raw[:length]).rstrip("\x00")
    except UnicodeError as error:
        raise ProbeError(f"executable path for PID {pid} is not decodable") from error
    path = Path(decoded)
    if not path.is_absolute():
        raise ProbeError(f"executable path for PID {pid} is not absolute")
    return path.resolve()


def capture_executable_file_identity(path: Path) -> dict[str, Any]:
    canonical = path.resolve(strict=True)
    info = canonical.stat()
    if not stat.S_ISREG(info.st_mode) or not os.access(canonical, os.X_OK):
        raise ProbeError(f"executable identity path is not an executable regular file: {canonical}")
    return {
        "canonicalPath": str(canonical),
        "device": info.st_dev,
        "inode": info.st_ino,
        "size": info.st_size,
        "modificationNanoseconds": info.st_mtime_ns,
        "statusChangeNanoseconds": info.st_ctime_ns,
    }


def live_process_start_identity(pid: int) -> dict[str, int]:
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
            ("xstatus", ctypes.c_uint32), ("process_id", ctypes.c_uint32),
            ("parent_pid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
            ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
            ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
            ("svgid", ctypes.c_uint32), ("reserved", ctypes.c_uint32),
            ("command", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
            ("open_files", ctypes.c_uint32), ("process_group", ctypes.c_uint32),
            ("job_control", ctypes.c_uint32), ("terminal_device", ctypes.c_uint32),
            ("terminal_process_group", ctypes.c_uint32), ("nice", ctypes.c_int32),
            ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64),
        ]
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBSDInfo()
        size = proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    except (AttributeError, OSError) as error:
        raise ProbeError(f"cannot capture process identity for PID {pid}: {error}") from error
    if (
        size != ctypes.sizeof(info)
        or info.process_id != pid
        or info.start_seconds <= 0
        or info.start_microseconds >= 1_000_000
    ):
        raise ProbeError(f"process identity capture lost PID {pid}")
    return {
        "pid": pid,
        "parentPID": int(info.parent_pid),
        "startSeconds": int(info.start_seconds),
        "startMicroseconds": int(info.start_microseconds),
    }


def capture_live_process_identity(
    pid: int,
    *,
    executable_resolver: Callable[[int], Path] = live_process_executable,
    process_identity_resolver: Callable[[int], dict[str, int]] = live_process_start_identity,
) -> dict[str, Any]:
    identity = process_identity_resolver(pid)
    if identity.get("pid") != pid:
        raise ProbeError(f"process identity capture lost PID {pid}")
    executable = executable_resolver(pid).resolve()
    return {
        "pid": pid,
        "parentPID": identity["parentPID"],
        "startSeconds": identity["startSeconds"],
        "startMicroseconds": identity["startMicroseconds"],
        "runtimeExecutable": str(executable),
        "runtimeExecutableFileIdentity": capture_executable_file_identity(executable),
    }


def inspect_helper_descendant(
    omp_process: subprocess.Popen[Any],
    omp: Path,
    helper: Path,
    *,
    expected_omp_process_identity: dict[str, Any],
    expected_omp_launch_file_identity: dict[str, Any],
    expected_helper_file_identity: dict[str, Any],
    snapshot_text: str | None = None,
    executable_resolver: Callable[[int], Path] = live_process_executable,
    process_identity_resolver: Callable[[int], dict[str, int]] = live_process_start_identity,
) -> dict[str, Any]:
    raw = snapshot_text
    if raw is None:
        raw = run_text(
            ["ps", "-ww", "-axo", "pid=,ppid=,lstart=,comm="],
            timeout=PROCESS_INSPECTION_TIMEOUT_SECONDS,
            stream_limit_bytes=PROCESS_INSPECTION_OUTPUT_LIMIT_BYTES,
        )
    if omp_process.poll() is not None:
        raise ProbeError("OMP ACP process exited before process inspection")
    command = omp_process.args
    launched_executable = command[0] if isinstance(command, (list, tuple)) and command else None
    if not isinstance(launched_executable, str) or Path(launched_executable).resolve() != omp.resolve():
        raise ProbeError("live OMP process handle does not match the launched executable")
    omp_pid = omp_process.pid
    rows = parse_process_snapshot(raw)
    omp_row = rows.get(omp_pid)
    if omp_row is None:
        raise ProbeError("OMP ACP PID disappeared during process inspection")
    if omp_process.poll() is not None:
        raise ProbeError("OMP ACP process exited during inspection; possible PID reuse")
    current_omp_process_identity = process_identity_resolver(omp_pid)
    if (
        expected_omp_process_identity.get("pid") != omp_pid
        or current_omp_process_identity.get("pid") != omp_pid
        or expected_omp_process_identity.get("startSeconds") != current_omp_process_identity.get("startSeconds")
        or expected_omp_process_identity.get("startMicroseconds") != current_omp_process_identity.get("startMicroseconds")
    ):
        raise ProbeError("OMP ACP process start identity changed during inspection")
    if capture_executable_file_identity(omp) != expected_omp_launch_file_identity:
        raise ProbeError("launched OMP executable file identity changed during inspection")
    expected_helper = helper.resolve()
    if capture_executable_file_identity(expected_helper) != expected_helper_file_identity:
        raise ProbeError("bundled helper executable file identity changed before descendant inspection")
    descendant_chains: list[list[dict[str, Any]]] = []
    wrong_path_pids: list[int] = []
    resolved_executables: dict[int, Path] = {}
    for match in rows.values():
        chain: list[dict[str, Any]] = []
        seen: set[int] = set()
        current = match
        while True:
            pid = current["pid"]
            if pid in seen or len(chain) >= PROCESS_INSPECTION_ROW_LIMIT:
                raise ProbeError("process inspection found a cyclic or excessive parent chain")
            seen.add(pid)
            chain.append(current)
            if pid == omp_pid:
                break
            parent = rows.get(current["parent_pid"])
            if parent is None:
                break
            current = parent
        if not chain or chain[-1]["pid"] != omp_pid:
            continue
        executable = executable_resolver(match["pid"]).resolve()
        resolved_executables[match["pid"]] = executable
        if executable.name == expected_helper.name and executable.resolve() != expected_helper:
            wrong_path_pids.append(match["pid"])
        if executable.resolve() == expected_helper:
            descendant_chains.append(chain)
    if wrong_path_pids:
        raise ProbeError(
            "OMP ACP tree contains a helper-named process with the wrong executable path",
            {"wrongPathHelperPIDs": sorted(wrong_path_pids)},
        )
    if len(descendant_chains) != 1:
        raise ProbeError(
            f"expected exactly one bundled-helper descendant, found {len(descendant_chains)}",
            {"matchingDescendantCount": len(descendant_chains)},
        )
    chain = descendant_chains[0]
    process_identities: dict[int, dict[str, int]] = {omp_pid: current_omp_process_identity}
    for row in chain:
        if row["pid"] not in resolved_executables:
            resolved_executables[row["pid"]] = executable_resolver(row["pid"]).resolve()
        if row["pid"] not in process_identities:
            process_identities[row["pid"]] = process_identity_resolver(row["pid"])
        if process_identities[row["pid"]].get("pid") != row["pid"]:
            raise ProbeError("process identity changed during descendant inspection")

    helper_pid = chain[0]["pid"]
    authoritative_chain_pids: list[int] = []
    current_pid = helper_pid
    for _ in range(PROCESS_INSPECTION_ROW_LIMIT):
        if current_pid in authoritative_chain_pids:
            raise ProbeError("authoritative process identity chain is cyclic")
        identity = process_identities.get(current_pid)
        if identity is None:
            identity = process_identity_resolver(current_pid)
            process_identities[current_pid] = identity
        if identity.get("pid") != current_pid:
            raise ProbeError("authoritative process identity chain lost its PID")
        if current_pid not in resolved_executables:
            resolved_executables[current_pid] = executable_resolver(current_pid).resolve()
        authoritative_chain_pids.append(current_pid)
        if current_pid == omp_pid:
            break
        parent_pid = identity.get("parentPID")
        if not isinstance(parent_pid, int) or parent_pid <= 1 or parent_pid == current_pid:
            raise ProbeError(
                "bundled helper was reparented and is no longer an authoritative OMP descendant"
            )
        current_pid = parent_pid
    if not authoritative_chain_pids or authoritative_chain_pids[-1] != omp_pid:
        raise ProbeError("bundled helper is not an authoritative OMP descendant")

    current_omp_runtime_identity = capture_executable_file_identity(resolved_executables[omp_pid])
    if (
        str(resolved_executables[omp_pid]) != expected_omp_process_identity.get("runtimeExecutable")
        or current_omp_runtime_identity != expected_omp_process_identity.get("runtimeExecutableFileIdentity")
    ):
        raise ProbeError("OMP ACP current runtime executable identity does not match launch-time process identity")
    current_helper_identity = capture_executable_file_identity(resolved_executables[helper_pid])
    if current_helper_identity != expected_helper_file_identity:
        raise ProbeError("helper descendant current executable identity does not match the bundled helper")
    identity_fields = ("pid", "parentPID", "startSeconds", "startMicroseconds")
    resampled_identities: dict[int, dict[str, int]] = {}
    for pid in authoritative_chain_pids:
        before = process_identities[pid]
        after = process_identity_resolver(pid)
        if any(before.get(key) != after.get(key) for key in identity_fields):
            raise ProbeError("authoritative parent-chain process identity drifted during executable inspection")
        resampled_identities[pid] = after
    for index, pid in enumerate(authoritative_chain_pids[:-1]):
        if resampled_identities[pid]["parentPID"] != authoritative_chain_pids[index + 1]:
            raise ProbeError("authoritative parent-chain linkage drifted during executable inspection")
    if omp_process.poll() is not None:
        raise ProbeError("OMP ACP process exited during descendant identity inspection")
    current_omp_process_identity = process_identity_resolver(omp_pid)
    if any(
        resampled_identities[omp_pid].get(key) != current_omp_process_identity.get(key)
        for key in identity_fields
    ):
        raise ProbeError("OMP ACP process identity drifted before evidence publication")
    resampled_identities[omp_pid] = current_omp_process_identity
    helper_identity_after = resampled_identities[helper_pid]
    return {
        "ompACPProcess": {
            "pid": omp_row["pid"],
            "parentPID": current_omp_process_identity["parentPID"],
            "startSeconds": current_omp_process_identity["startSeconds"],
            "startMicroseconds": current_omp_process_identity["startMicroseconds"],
            "launchedExecutable": str(omp.resolve()),
            "runtimeExecutable": str(resolved_executables[omp_pid]),
            "startIdentityMatch": True,
            "currentExecutableIdentityMatch": True,
            "launchCommandExecutableIdentityMatch": True,
            "runtimeExecutableFileIdentity": current_omp_runtime_identity,
        },
        "helperProcess": {
            "pid": chain[0]["pid"],
            "parentPID": helper_identity_after["parentPID"],
            "startSeconds": helper_identity_after["startSeconds"],
            "startMicroseconds": helper_identity_after["startMicroseconds"],
            "executable": str(resolved_executables[helper_pid]),
            "currentExecutableIdentityMatch": True,
            "executableFileIdentity": current_helper_identity,
        },
        "parentChain": [
            {
                "pid": pid,
                "parentPID": resampled_identities[pid]["parentPID"],
                "startSeconds": resampled_identities[pid]["startSeconds"],
                "startMicroseconds": resampled_identities[pid]["startMicroseconds"],
                "executable": str(resolved_executables[pid]),
            }
            for pid in authoritative_chain_pids
        ],
        "inspectionBounds": {
            "timeoutSeconds": PROCESS_INSPECTION_TIMEOUT_SECONDS,
            "rowLimit": PROCESS_INSPECTION_ROW_LIMIT,
            "outputByteLimit": PROCESS_INSPECTION_OUTPUT_LIMIT_BYTES,
            "executablePathByteLimit": PROCESS_EXECUTABLE_PATH_LIMIT_BYTES,
        },
    }


def production_transport_identity_evidence(
    cli: Path,
    before_history: list[dict[str, Any]],
    omp_process: subprocess.Popen[Any],
    omp: Path,
    helper: Path,
    launch_identities: dict[str, Any],
) -> dict[str, Any]:
    before_seq = max((event["seq"] for event in before_history), default=0)
    deadline = time.monotonic() + PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS
    last_candidate_count = 0
    while True:
        during_history = debug_connection_history(cli)
        if before_seq and not any(event["seq"] == before_seq for event in during_history):
            raise ProbeError("production-bootstrap connection history window lost its baseline")
        registrations = {
            event["connection_id"]: event
            for event in during_history
            if event["seq"] > before_seq
            and event.get("event") == "registered"
            and event.get("reason") == "bootstrap"
            and event.get("client_name") == PRODUCTION_HELPER_BOOTSTRAP_CLIENT_NAME
            and isinstance(event.get("connection_id"), str)
        }
        last_candidate_count = len(registrations)
        if len(registrations) == 1:
            connection_id = next(iter(registrations))
            connection = debug_connection_snapshot(cli, connection_id)
            if connection.get("state") != "ready":
                if time.monotonic() < deadline:
                    time.sleep(PRODUCTION_DIAGNOSTICS_POLL_SECONDS)
                    continue
                raise ProbeError("production helper connection did not become ready")
            process_evidence = inspect_helper_descendant(
                omp_process,
                omp,
                helper,
                expected_omp_process_identity=launch_identities["ompProcess"],
                expected_omp_launch_file_identity=launch_identities["ompLaunchFile"],
                expected_helper_file_identity=launch_identities["helperFile"],
            )
            helper_process = process_evidence.get("helperProcess", {})
            helper_pid = helper_process.get("pid") if isinstance(helper_process, dict) else None
            if (
                connection.get("client_name") != "omp-coding-agent"
                or connection.get("normalized_client_id") != "omp-coding-agent"
            ):
                raise ProbeError("production helper connection identity is not exactly omp-coding-agent")
            if not isinstance(helper_pid, int) or connection.get("helper_peer_pid") != helper_pid:
                raise ProbeError("production helper connection peer PID does not match the observed bundled helper")
            if (
                connection.get("helper_peer_start_seconds") != helper_process.get("startSeconds")
                or connection.get("helper_peer_start_microseconds") != helper_process.get("startMicroseconds")
            ):
                raise ProbeError("production helper connection peer start identity does not match the observed bundled helper")
            if (
                connection.get("total_tool_calls") != 0
                or connection.get("has_in_flight_calls") is not False
                or connection.get("active_tool_scope_count") != 0
                or connection.get("active_tool_scopes") != []
            ):
                raise ProbeError("production helper connection observed historical or in-flight tool activity")
            fingerprint = connection.get("session_fingerprint")
            if fingerprint is not None and (
                not isinstance(fingerprint, str)
                or re.fullmatch(r"sha256:[0-9a-f]{16}", fingerprint) is None
            ):
                raise ProbeError("DEBUG diagnostics exposed an unsafe session fingerprint shape")
            result = {
                "evidenceLabel": "production transport/identity evidence",
                "policyProof": False,
                "connection": {
                    "client_name": connection.get("client_name"),
                    "normalized_client_id": connection.get("normalized_client_id"),
                    "connection_id": connection_id,
                    "state": connection.get("state"),
                    "transport": connection.get("transport"),
                    "helper_peer_pid": connection.get("helper_peer_pid"),
                    "helper_peer_start_seconds": connection.get("helper_peer_start_seconds"),
                    "helper_peer_start_microseconds": connection.get("helper_peer_start_microseconds"),
                    "total_tool_calls": connection.get("total_tool_calls"),
                    "has_in_flight_calls": connection.get("has_in_flight_calls"),
                    "active_tool_scope_count": connection.get("active_tool_scope_count"),
                    "active_tool_scopes": connection.get("active_tool_scopes"),
                },
                "process": process_evidence,
                "delta": {
                    "beforeHistorySequence": before_seq,
                    "registrationHistorySequence": registrations[connection_id]["seq"],
                    "duringHistorySequence": max((event["seq"] for event in during_history), default=before_seq),
                    "bootstrapHelperRegistrationCount": 1,
                    "newReadyAttributableConnectionCount": 1,
                },
                "captureBounds": {
                    "timeoutSeconds": PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS,
                    "pollSeconds": PRODUCTION_DIAGNOSTICS_POLL_SECONDS,
                    "historyEventLimit": PRODUCTION_HISTORY_LIMIT,
                    "cliCallTimeoutSeconds": DEFAULT_TIMEOUT_SECONDS,
                    "cliOutputByteLimit": PROCESS_INSPECTION_OUTPUT_LIMIT_BYTES,
                },
            }
            if fingerprint is not None:
                result["connection"]["session_fingerprint"] = fingerprint
            return result
        if len(registrations) > 1:
            raise ProbeError(
                "production-bootstrap connection delta is ambiguous",
                {"newReadyAttributableConnectionCount": len(registrations)},
            )
        if time.monotonic() >= deadline:
            raise ProbeError(
                "production-bootstrap did not produce exactly one new ready connection",
                {"newReadyAttributableConnectionCount": last_candidate_count},
            )
        time.sleep(PRODUCTION_DIAGNOSTICS_POLL_SECONDS)


def production_terminal_connection_evidence(
    cli: Path,
    transport_evidence: dict[str, Any],
) -> dict[str, Any]:
    connection = transport_evidence.get("connection")
    process = transport_evidence.get("process")
    delta = transport_evidence.get("delta")
    if not isinstance(connection, dict) or not isinstance(process, dict) or not isinstance(delta, dict):
        raise ProbeError("production transport evidence is incomplete before terminal polling")
    connection_id = connection.get("connection_id")
    helper_process = process.get("helperProcess")
    helper_pid = helper_process.get("pid") if isinstance(helper_process, dict) else None
    registration_seq = delta.get("registrationHistorySequence")
    if not isinstance(connection_id, str) or not isinstance(helper_pid, int) or not isinstance(registration_seq, int):
        raise ProbeError("production transport evidence lacks terminal correlation fields")

    deadline = time.monotonic() + PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS
    while True:
        events = debug_connection_history(cli, connection_id)
        if any(event.get("connection_id") != connection_id for event in events):
            raise ProbeError("production-bootstrap exact connection history contained a wrong connection UUID")
        if not any(event.get("seq") == registration_seq and event.get("event") == "registered" for event in events):
            raise ProbeError("production-bootstrap exact connection history lost its registration baseline")
        removed = [event for event in events if event.get("event") == "removed" and event.get("seq", 0) > registration_seq]
        if len(removed) > 1:
            raise ProbeError("production-bootstrap exact connection history has ambiguous terminal removal events")
        if len(removed) == 1:
            terminal = removed[0]
            if (
                terminal.get("client_name") != "omp-coding-agent"
                or terminal.get("normalized_client_id") != "omp-coding-agent"
                or terminal.get("helper_peer_pid") != helper_pid
                or terminal.get("helper_peer_start_seconds") != helper_process.get("startSeconds")
                or terminal.get("helper_peer_start_microseconds") != helper_process.get("startMicroseconds")
                or terminal.get("qualification_raw_tool_call_count") != 0
                or terminal.get("qualification_raw_in_flight_call_count") != 0
                or terminal.get("active_tool_scope_count") != 0
            ):
                raise ProbeError("production-bootstrap terminal connection record failed zero-tool identity correlation")
            return {
                "evidenceLabel": "terminal exact-connection history evidence",
                "connection_id": connection_id,
                "registration_history_sequence": registration_seq,
                "removed_event_count": 1,
                "baseline_preserved": True,
                "removed_event": terminal,
                "captureBounds": {
                    "timeoutSeconds": PRODUCTION_DIAGNOSTICS_TIMEOUT_SECONDS,
                    "pollSeconds": PRODUCTION_DIAGNOSTICS_POLL_SECONDS,
                    "historyEventLimit": PRODUCTION_HISTORY_LIMIT,
                },
            }
        if time.monotonic() >= deadline:
            raise ProbeError("production-bootstrap exact connection history is missing its terminal removal event")
        time.sleep(PRODUCTION_DIAGNOSTICS_POLL_SECONDS)


def acp_probe(
    omp: Path,
    helper: Path,
    workspace: Path,
    output_dir: Path,
    phase: str,
    prompt_timeout: int,
    session_open_inspector: Callable[[subprocess.Popen[Any], dict[str, Any]], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    mcp_servers: list[dict[str, Any]] = []
    mcp_server_kind = "none"
    readonly_proxy_audit: Path | None = None
    proxy_mode: str | None = None
    if phase == "prompt":
        pass
    elif phase == "production-bootstrap":
        mcp_servers = [
            {
                "type": "stdio",
                "name": "RepoPromptCE",
                "command": str(helper.resolve()),
                "args": [],
                "env": [],
            }
        ]
        mcp_server_kind = "production-bundled-repoprompt-mcp"
    elif phase in {"bootstrap", "roundtrip"}:
        proxy_mode = "discovery" if phase == "bootstrap" else "roundtrip"
        audit_name = "discovery-mcp-proxy.audit.json" if phase == "bootstrap" else "readonly-mcp-proxy.audit.json"
        readonly_proxy_audit = output_dir / audit_name
        if readonly_proxy_audit.exists() or readonly_proxy_audit.is_symlink():
            raise ProbeError(f"refusing pre-existing read-only MCP proxy audit path: {readonly_proxy_audit}")
        mcp_servers = [
            {
                "type": "stdio",
                "name": "RepoPromptCE",
                "command": str(Path(sys.executable).resolve()),
                "args": [
                    str(Path(__file__).resolve()),
                    "--readonly-mcp-proxy",
                    "--mode",
                    proxy_mode,
                    "--workspace",
                    str(workspace),
                    "--audit-file",
                    str(readonly_proxy_audit),
                    "--exit-on-complete",
                ],
                "env": [],
            }
        ]
        mcp_server_kind = f"test-only-{proxy_mode}-mcp-proxy"
    else:
        raise ProbeError(f"unknown ACP probe phase: {phase}")
    launch_identities: dict[str, Any] = {}
    if session_open_inspector is not None:
        launch_identities = {
            "ompLaunchFile": capture_executable_file_identity(omp),
            "helperFile": capture_executable_file_identity(helper),
        }
    process = JSONLProcess([str(omp), *MANAGED_OMP_ARGUMENTS], workspace)
    permission_events: list[dict[str, Any]] = []
    unexpected_inbound_request_records: list[dict[str, Any]] = []
    unknown_notification_records: list[dict[str, Any]] = []
    update_kinds: list[str] = []
    unknown_update_kinds: list[str] = []
    observed_tool_titles: list[str] = []
    tool_event_records: list[dict[str, Any]] = []
    session_event_records: list[dict[str, Any]] = []
    agent_text: list[str] = []
    session_id: str | None = None
    lifecycle_phase = "initializing"
    initialize: dict[str, Any] = {}
    auth_method_ids: list[str] = []
    opened: dict[str, Any] = {}
    acknowledgement: str | None = None
    production_evidence: dict[str, Any] | None = None

    def inbound_handler(message: dict[str, Any]) -> None:
        method = message.get("method")
        if "id" in message and isinstance(method, str) and method != "session/request_permission":
            if len(unexpected_inbound_request_records) < UNEXPECTED_INBOUND_REQUEST_LIMIT:
                params = message.get("params")
                try:
                    params_excerpt = json.dumps(params, separators=(",", ":"), ensure_ascii=False)
                except BaseException:
                    params_excerpt = "<unavailable>"
                unexpected_inbound_request_records.append({
                    "method": method,
                    "id": message["id"],
                    "sessionId": params.get("sessionId") if isinstance(params, dict) else None,
                    "activeSessionId": session_id,
                    "lifecyclePhase": lifecycle_phase,
                    "paramsExcerpt": params_excerpt[:UNEXPECTED_INBOUND_PARAMS_LIMIT],
                })
            error = UnexpectedInboundRequestError(f"unsupported inbound ACP request: {method}")
            process.latch_protocol_error(error)
            raise error
        if method not in {"session/update", "session/request_permission"}:
            if isinstance(method, str) and "id" not in message:
                if len(unknown_notification_records) < UNEXPECTED_INBOUND_REQUEST_LIMIT:
                    unknown_notification_records.append({
                        "method": method,
                        "lifecyclePhase": lifecycle_phase,
                    })
                error = UnexpectedInboundRequestError(f"unsupported inbound ACP notification: {method}")
                process.latch_protocol_error(error)
                raise error
            return
        params = message.get("params")
        params_object = params if isinstance(params, dict) else {}
        event_session_id = params_object.get("sessionId")
        if method == "session/request_permission":
            tool_call = params_object.get("toolCall")
            tool_call_object = tool_call if isinstance(tool_call, dict) else {}
            if len(permission_events) < PERMISSION_EVENT_LIMIT:
                permission_events.append({
                    "title": tool_call_object.get("title"),
                    "sessionId": event_session_id,
                    "lifecyclePhase": lifecycle_phase,
                    "response": "terminal-no-response",
                })
            error = PermissionTerminalError("ACP permission request made the probe terminal")
            process.latch_protocol_error(error)
            raise error

        update = params_object.get("update")
        kind = update.get("sessionUpdate") if isinstance(update, dict) else None
        session_record = {
            "kind": kind,
            "sessionId": event_session_id,
            "lifecyclePhase": lifecycle_phase,
        }
        session_event_records.append(session_record)
        if isinstance(kind, str):
            update_kinds.append(kind)
            if kind not in RECOGNIZED_SESSION_UPDATE_KINDS:
                unknown_update_kinds.append(kind)

        tool_record: dict[str, Any] | None = None
        if kind in {"tool_call", "tool_call_update"} and isinstance(update, dict):
            nested = update.get("toolCall")
            nested_object = nested if isinstance(nested, dict) else {}
            tool_record = {
                "kind": kind,
                "toolCallId": None,
                "title": None,
                "sessionId": event_session_id,
                "lifecyclePhase": lifecycle_phase,
                "titleRepresentations": [
                    value for value in (update.get("title"), nested_object.get("title"))
                    if value is not None
                ],
                "idRepresentations": [
                    source[key]
                    for source in (update, nested_object)
                    for key in ("toolCallId", "id")
                    if key in source
                ],
            }
            tool_event_records.append(tool_record)

        if not isinstance(update, dict) or not isinstance(kind, str):
            raise ProbeError("session/update has malformed update params")
        if session_id is None or event_session_id != session_id:
            raise ProbeError("session/update has a missing or wrong sessionId")
        if lifecycle_phase in {"closing", "closed"}:
            raise ProbeError("session/update arrived after session close began")
        if lifecycle_phase in {"initializing", "session-opening"}:
            raise ProbeError("session/update arrived before session opening completed")
        if lifecycle_phase == "session-open" and kind not in SESSION_OPEN_UPDATE_KINDS:
            raise ProbeError(f"prompt-specific or unknown update arrived before prompt dispatch: {kind}")
        if lifecycle_phase != "prompt-dispatched" and kind in PROMPT_ONLY_UPDATE_KINDS:
            raise ProbeError(f"prompt-specific update arrived outside prompt dispatch: {kind}")

        canonical = validate_known_update_payload(kind, update)
        if tool_record is not None:
            tool_record["title"] = canonical.get("title")
            tool_record["toolCallId"] = canonical.get("toolCallId")
            title = canonical.get("title")
            if isinstance(title, str):
                observed_tool_titles.append(title)
        if kind == "agent_message_chunk":
            agent_text.append(str(canonical["text"]))

    def partial_summary_without_workspace_names() -> dict[str, Any]:
        result = {
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
            "unknownUpdateKinds": sorted(set(unknown_update_kinds)),
            "observedToolTitles": sorted(set(observed_tool_titles)),
            "toolEventRecords": list(tool_event_records),
            "sessionEventRecords": list(session_event_records),
            "unattributedToolEventCount": sum(record["toolCallId"] is None for record in tool_event_records),
            "permissionEvents": list(permission_events),
            "unexpectedInboundRequests": {
                "count": len(unexpected_inbound_request_records),
                "records": list(unexpected_inbound_request_records),
            },
            "unknownNotifications": {
                "count": len(unknown_notification_records),
                "records": list(unknown_notification_records),
            },
            "mcpServerKind": mcp_server_kind,
            "restrictedMCPProxyAuditPath": str(readonly_proxy_audit) if readonly_proxy_audit else None,
            "promptDispatched": lifecycle_phase in {"prompt-dispatched", "prompt-complete"},
        }
        if production_evidence is not None:
            result["productionTransportIdentityEvidence"] = production_evidence
        return result

    def partial_summary() -> dict[str, Any]:
        result = partial_summary_without_workspace_names()
        workspace_names, workspace_names_truncated = bounded_workspace_names(workspace)
        result["workspaceFileNames"] = workspace_names
        result["workspaceFileNamesTruncated"] = workspace_names_truncated
        return result

    def safe_partial_summary() -> dict[str, Any]:
        try:
            return partial_summary()
        except BaseException as error:
            try:
                result = partial_summary_without_workspace_names()
                try:
                    message = str(error)
                except BaseException:
                    message = type(error).__name__
                result["partialSummaryUnavailable"] = {
                    "type": type(error).__name__[:128],
                    "message": message[:512],
                }
                return result
            except BaseException:
                return {"partialSummaryUnavailable": {"type": "unavailable", "message": "unavailable"}}

    summary: dict[str, Any] = {}
    primary_error: BaseException | None = None
    try:
        if session_open_inspector is not None:
            launch_identities["ompProcess"] = capture_live_process_identity(process.process.pid)
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
        process.drain(inbound_handler)
        if "agent" in auth_method_ids:
            process.send({"jsonrpc": "2.0", "id": 2, "method": "authenticate", "params": {"methodId": "agent"}})
            require_result("ACP authenticate", process.wait_for_response(2, DEFAULT_TIMEOUT_SECONDS, inbound_handler))
            process.drain(inbound_handler)

        lifecycle_phase = "session-opening"
        process.send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "session/new",
                "params": {
                    "cwd": str(workspace),
                    "mcpServers": mcp_servers,
                },
            }
        )
        opened = require_result("ACP session/new", process.wait_for_response(3, BOOTSTRAP_TIMEOUT_SECONDS, inbound_handler))
        raw_session_id = opened.get("sessionId")
        if not isinstance(raw_session_id, str) or not raw_session_id:
            raise ProbeError("ACP session/new did not return a non-empty sessionId")
        session_id = raw_session_id
        lifecycle_phase = "session-open"
        process.drain_for(POST_RESPONSE_DRAIN_SECONDS, inbound_handler)

        if session_open_inspector is not None:
            production_evidence = session_open_inspector(process.process, launch_identities)

        summary = {
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
            "promptDispatched": False,
        }
        if production_evidence is not None:
            summary["productionTransportIdentityEvidence"] = production_evidence

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
            lifecycle_phase = "prompt-dispatched"
            summary["promptDispatched"] = True
            prompt_result = require_result(
                "ACP session/prompt",
                process.wait_for_response(4, prompt_timeout, inbound_handler),
            )
            lifecycle_phase = "prompt-complete"
            process.drain_for(POST_RESPONSE_DRAIN_SECONDS, inbound_handler)
            summary["promptStopReason"] = prompt_result.get("stopReason")
            summary["promptResultKeys"] = sorted(prompt_result.keys())

    except BaseException as error:
        primary_error = error

    close_handshake_error: BaseException | None = None
    terminal_inbound_request = isinstance(process._protocol_error, TerminalInboundRequestError)
    if session_id and not terminal_inbound_request:
        try:
            lifecycle_phase = "closing"
            process.send({"jsonrpc": "2.0", "id": 99, "method": "session/close", "params": {"sessionId": session_id}})
            require_result("ACP session/close", process.wait_for_response(99, 10, inbound_handler))
            lifecycle_phase = "closed"
        except BaseException as error:
            close_handshake_error = error

    close_error: BaseException | None = None
    try:
        process.close()
    except BaseException as error:
        close_error = error

    tail_error: BaseException | None = None
    try:
        process.drain(inbound_handler)
    except BaseException as error:
        tail_error = error

    evidence_error: BaseException | None = None
    try:
        process.write_evidence(output_dir / "omp-acp")
    except BaseException as error:
        evidence_error = error

    combined = combine_probe_errors(
        ("ACP operation", primary_error),
        ("session close", close_handshake_error),
        ("process cleanup", close_error),
        ("final tail drain", tail_error),
        ("evidence write", evidence_error),
    )
    if combined is not None:
        details = dict(combined.details)
        details["ompACPPartial"] = safe_partial_summary()
        raise ProbeError(str(combined), details) from combined

    if acknowledgement is not None:
        summary["expectedAcknowledgement"] = acknowledgement
        acknowledgement_text = "".join(agent_text)
        # OMP can emit narration chunks after the tool-complete update even when
        # they describe the already-started call. Roundtrip transport is proved
        # independently by the exact tool-event and proxy-audit contracts, so
        # accept one final sentinel token but reject duplicates and suffix text.
        summary["agentAcknowledgementObserved"] = (
            has_unique_final_acknowledgement_token(acknowledgement_text, acknowledgement)
            if phase == "roundtrip"
            else normalize_acknowledgement(acknowledgement_text) == acknowledgement
        )
    summary.update(partial_summary())
    return summary


def tool_activity_present(acp: dict[str, Any]) -> bool:
    tool_events = {"tool_call", "tool_call_update"} & set(acp.get("observedUpdateKinds", []))
    return bool(
        tool_events
        or acp.get("observedToolTitles")
        or acp.get("toolEventRecords")
        or acp.get("permissionEvents")
    )


def unexpected_inbound_requests_present(acp: dict[str, Any]) -> bool:
    value = acp.get("unexpectedInboundRequests")
    return not isinstance(value, dict) or value.get("count") != 0 or value.get("records") != []


def unknown_update_kinds_present(acp: dict[str, Any]) -> bool:
    value = acp.get("unknownUpdateKinds", [])
    return not isinstance(value, list) or bool(value)


def validate_bootstrap_summary(acp: dict[str, Any]) -> None:
    if unknown_update_kinds_present(acp):
        raise ProbeError("bootstrap observed an unknown ACP session-update kind")
    if unexpected_inbound_requests_present(acp):
        raise ProbeError("bootstrap observed an unsupported inbound request")
    if tool_activity_present(acp):
        raise ProbeError("bootstrap emitted a tool or permission event")
    audit = acp.get("discoveryMCPProxy")
    expected_sequence = ["initialize", "notifications/initialized", "tools/list"]
    if (
        not isinstance(audit, dict)
        or audit.get("mode") != "discovery"
        or audit.get("protocolSequence") != expected_sequence
        or not audit.get("protocolComplete")
        or audit.get("advertisedToolNames") != []
        or audit.get("allowedToolCallCount") != 0
        or audit.get("rejectedRequestCount") != 0
        or audit.get("exitCode") != 0
    ):
        raise ProbeError("bootstrap lacks a clean discovery-only zero-tool MCP audit")


def validate_production_bootstrap_summary(acp: dict[str, Any]) -> None:
    if acp.get("mcpServerKind") != "production-bundled-repoprompt-mcp":
        raise ProbeError("production-bootstrap did not inject the bundled helper")
    if acp.get("promptDispatched") is not False:
        raise ProbeError("production-bootstrap dispatched a prompt")
    if unknown_update_kinds_present(acp):
        raise ProbeError("production-bootstrap observed an unknown ACP session-update kind")
    if unexpected_inbound_requests_present(acp):
        raise ProbeError("production-bootstrap observed an unsupported inbound request")
    unknown_notifications = acp.get("unknownNotifications")
    if not isinstance(unknown_notifications, dict) or unknown_notifications.get("count") != 0:
        raise ProbeError("production-bootstrap observed an unknown ACP notification")
    if tool_activity_present(acp) or set(acp.get("observedUpdateKinds", [])) & PROMPT_ONLY_UPDATE_KINDS:
        raise ProbeError("production-bootstrap emitted a prompt, tool, or permission event")
    evidence = acp.get("productionTransportIdentityEvidence")
    process_evidence = evidence.get("process") if isinstance(evidence, dict) else None
    omp_process = process_evidence.get("ompACPProcess") if isinstance(process_evidence, dict) else None
    helper_process = process_evidence.get("helperProcess") if isinstance(process_evidence, dict) else None
    terminal = evidence.get("terminalConnectionEvidence") if isinstance(evidence, dict) else None
    terminal_event = terminal.get("removed_event") if isinstance(terminal, dict) else None
    connection = evidence.get("connection") if isinstance(evidence, dict) else None
    parent_chain = process_evidence.get("parentChain") if isinstance(process_evidence, dict) else None

    def has_numeric_start_identity(process: Any) -> bool:
        return (
            isinstance(process, dict)
            and type(process.get("pid")) is int
            and process["pid"] > 0
            and type(process.get("parentPID")) is int
            and process["parentPID"] >= 0
            and type(process.get("startSeconds")) is int
            and process["startSeconds"] > 0
            and type(process.get("startMicroseconds")) is int
            and 0 <= process["startMicroseconds"] < 1_000_000
        )

    def has_exact_peer_identity(record: Any) -> bool:
        return (
            isinstance(record, dict)
            and type(record.get("helper_peer_pid")) is int
            and record["helper_peer_pid"] > 0
            and type(record.get("helper_peer_start_seconds")) is int
            and record["helper_peer_start_seconds"] > 0
            and type(record.get("helper_peer_start_microseconds")) is int
            and 0 <= record["helper_peer_start_microseconds"] < 1_000_000
        )

    def has_linked_parent_chain() -> bool:
        if (
            not isinstance(parent_chain, list)
            or len(parent_chain) < 2
            or not all(has_numeric_start_identity(row) for row in parent_chain)
        ):
            return False
        chain_pids = [row["pid"] for row in parent_chain]
        if len(set(chain_pids)) != len(chain_pids):
            return False
        if parent_chain[0].get("pid") != helper_process.get("pid"):
            return False
        if parent_chain[-1].get("pid") != omp_process.get("pid"):
            return False
        for current, parent in zip(parent_chain, parent_chain[1:]):
            if current.get("parentPID") != parent.get("pid"):
                return False
        for endpoint, process in ((parent_chain[0], helper_process), (parent_chain[-1], omp_process)):
            for key in ("pid", "parentPID", "startSeconds", "startMicroseconds"):
                if endpoint.get(key) != process.get(key):
                    return False
        return True

    if (
        not isinstance(evidence, dict)
        or evidence.get("evidenceLabel") != "production transport/identity evidence"
        or evidence.get("policyProof") is not False
        or evidence.get("delta", {}).get("newReadyAttributableConnectionCount") != 1
        or evidence.get("connection", {}).get("client_name") != "omp-coding-agent"
        or evidence.get("connection", {}).get("normalized_client_id") != "omp-coding-agent"
        or not has_numeric_start_identity(omp_process)
        or not has_numeric_start_identity(helper_process)
        or omp_process.get("startIdentityMatch") is not True
        or not has_linked_parent_chain()
        or omp_process.get("pid") == helper_process.get("pid")
        or not has_exact_peer_identity(connection)
        or connection.get("helper_peer_pid") != helper_process.get("pid")
        or connection.get("helper_peer_start_seconds") != helper_process.get("startSeconds")
        or connection.get("helper_peer_start_microseconds") != helper_process.get("startMicroseconds")
        or evidence.get("connection", {}).get("total_tool_calls") != 0
        or omp_process.get("currentExecutableIdentityMatch") is not True
        or omp_process.get("launchCommandExecutableIdentityMatch") is not True
        or helper_process.get("currentExecutableIdentityMatch") is not True
        or evidence.get("connection", {}).get("has_in_flight_calls") is not False
        or evidence.get("connection", {}).get("active_tool_scope_count") != 0
        or evidence.get("connection", {}).get("active_tool_scopes") != []
        or not isinstance(terminal, dict)
        or terminal.get("evidenceLabel") != "terminal exact-connection history evidence"
        or terminal.get("connection_id") != evidence.get("connection", {}).get("connection_id")
        or terminal.get("registration_history_sequence") != evidence.get("delta", {}).get("registrationHistorySequence")
        or terminal.get("removed_event_count") != 1
        or terminal.get("baseline_preserved") is not True
        or not isinstance(terminal_event, dict)
        or terminal_event.get("event") != "removed"
        or terminal_event.get("client_name") != "omp-coding-agent"
        or terminal_event.get("normalized_client_id") != "omp-coding-agent"
        or not has_exact_peer_identity(terminal_event)
        or terminal_event.get("helper_peer_pid") != helper_process.get("pid")
        or terminal_event.get("helper_peer_start_seconds") != helper_process.get("startSeconds")
        or terminal_event.get("helper_peer_start_microseconds") != helper_process.get("startMicroseconds")
        or terminal_event.get("qualification_raw_tool_call_count") != 0
        or terminal_event.get("qualification_raw_in_flight_call_count") != 0
        or terminal_event.get("active_tool_scope_count") != 0
    ):
        raise ProbeError("production-bootstrap lacks bounded production transport/identity evidence")


def validate_prompt_summary(acp: dict[str, Any]) -> None:
    if unknown_update_kinds_present(acp):
        raise ProbeError("no-tool prompt observed an unknown ACP session-update kind")
    if unexpected_inbound_requests_present(acp):
        raise ProbeError("no-tool prompt observed an unsupported inbound request")
    if not acp.get("agentAcknowledgementObserved"):
        raise ProbeError("no-tool prompt did not observe the exact acknowledgement")
    if tool_activity_present(acp):
        raise ProbeError("no-tool prompt emitted a tool or permission event")


def validate_roundtrip_summary(acp: dict[str, Any]) -> None:
    if unknown_update_kinds_present(acp):
        raise ProbeError("roundtrip observed an unknown ACP session-update kind")
    if unexpected_inbound_requests_present(acp):
        raise ProbeError("roundtrip observed an unsupported inbound request")
    if acp.get("permissionEvents"):
        raise ProbeError("OMP emitted ACP permission requests; the harness treated them terminally without responding")
    if not acp.get("agentAcknowledgementObserved"):
        raise ProbeError("roundtrip did not observe the exact acknowledgement")
    records = acp.get("toolEventRecords")
    if not isinstance(records, list):
        raise ProbeError("roundtrip lacks attributable tool-event records")
    initial = [record for record in records if isinstance(record, dict) and record.get("kind") == "tool_call"]
    # The first spelling is the exact OMP 17.2.12 title observed on the wire;
    # the second is RepoPrompt's canonical MCP spelling. Do not accept a bare
    # tool name, a fuzzy prefix, or a lookalike server name as attribution.
    allowed_titles = {"mcp__repopromptce_get_file_tree", "mcp__RepoPromptCE__get_file_tree"}
    if len(initial) != 1:
        raise ProbeError("roundtrip must contain exactly one initial get_file_tree tool event")
    expected_id = initial[0].get("toolCallId")
    if (
        not isinstance(expected_id, str)
        or not expected_id.strip()
        or initial[0].get("title") not in allowed_titles
    ):
        raise ProbeError("roundtrip initial tool event is unattributed or not RepoPrompt get_file_tree")
    for record in records:
        if not isinstance(record, dict):
            raise ProbeError("roundtrip contains a malformed tool-event record")
        if record.get("kind") not in {"tool_call", "tool_call_update"}:
            raise ProbeError("roundtrip contains an unexpected tool-event kind")
        if record.get("toolCallId") != expected_id:
            raise ProbeError("roundtrip contains an unattributed or extra tool event")
        title = record.get("title")
        if title is not None and title not in allowed_titles:
            raise ProbeError("roundtrip contains a spoofed or unexpected tool title")
    if acp.get("unattributedToolEventCount"):
        raise ProbeError("roundtrip contains an unattributed tool event")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--phase",
        choices=("preflight", "cli-prompt", "helper", "bootstrap", "production-bootstrap", "prompt", "roundtrip"),
        default="bootstrap",
        help="preflight, bare OMP print prompt, helper MCP, safe proxy bootstrap (default), production-helper diagnostic bootstrap, no-tool ACP prompt, or safety-enforced read-only MCP roundtrip",
    )
    parser.add_argument("--omp", default=os.environ.get("OMP_EXECUTABLE", "omp"), help="OMP executable or absolute path")
    parser.add_argument(
        "--debug-cli",
        help="rpce-cli-debug path; otherwise resolve from env, PATH, user fallback, then the bundled DEBUG helper",
    )
    parser.add_argument(
        "--app-bundle",
        type=Path,
        default=Path.home() / "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app",
        help="fresh coordinated debug app bundle containing repoprompt-mcp",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        help="absolute empty disposable workspace; defaults to a separate fresh private temporary directory",
    )
    parser.add_argument(
        "--unsafe-allow-unverified-workspace",
        "--unsafe-allow-nonempty-workspace",
        dest="unsafe_allow_nonempty_workspace",
        action="store_true",
        help="UNSAFE: waive harness ownership and exclusivity for a pre-existing supplied workspace",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="outside-repository parent under which a fresh private per-run evidence directory is created",
    )
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
    output_dir: Path | None = None
    workspace: Path | None = None
    workspace_owned = False
    marker: Path | None = None
    marker_owned = False
    workspace_before: dict[str, dict[str, Any]] | None = None
    try:
        output_dir = prepare_output_directory(args.output_dir, repo_root)
        workspace, workspace_owned = prepare_workspace(args, output_dir, repo_root)
        marker = workspace / ".omp-live-spike-readonly-marker"
        write_private_text(marker, "This disposable workspace is owned by omp_acp_live_spike.py.\n")
        marker_owned = True
        if phase_requires_workspace_snapshot(args.phase):
            workspace_before = snapshot_workspace(workspace)
    except BaseException as error:
        cleanup_causes: list[tuple[str, BaseException | None]] = [("preparation", error)]
        if marker_owned and marker is not None:
            try:
                marker.unlink()
            except BaseException as cleanup:
                cleanup_causes.append(("marker cleanup", cleanup))
        if workspace_owned and workspace is not None:
            try:
                workspace.rmdir()
            except BaseException as cleanup:
                cleanup_causes.append(("workspace cleanup", cleanup))
        if output_dir is not None:
            try:
                output_dir.rmdir()
            except BaseException as cleanup:
                cleanup_causes.append(("evidence cleanup", cleanup))
        combined = combine_probe_errors(*cleanup_causes)
        assert combined is not None
        print(f"ERROR: {combined}", file=sys.stderr)
        return 2
    assert output_dir is not None and workspace is not None and marker is not None

    summary: dict[str, Any] = {
        "phase": args.phase,
        "outputDirectory": str(output_dir),
        "workspace": str(workspace),
        "workspaceFreshDefault": args.workspace is None,
        "workspaceOwnedByHarness": workspace_owned,
        "unsafeUnverifiedWorkspaceOverride": args.unsafe_allow_nonempty_workspace,
        "managedOMPArguments": MANAGED_OMP_ARGUMENTS,
        "success": False,
    }
    if workspace_before is not None:
        summary["workspaceSnapshotBeforeSHA256"] = snapshot_digest(workspace_before)
    exit_code = 0
    reported_error: BaseException | None = None
    try:
        omp = find_executable(args.omp, "OMP executable")
        helper = find_executable(str(args.app_bundle.expanduser() / "Contents/MacOS/repoprompt-mcp"), "bundled RepoPrompt MCP helper")
        summary["ompExecutable"] = str(omp)
        summary["helperExecutable"] = str(helper)
        version = run_text([str(omp), "--version"], cwd=workspace).strip()
        global_help = run_text([str(omp), "--help"], cwd=workspace)
        acp_help = run_text([str(omp), "acp", "--help"], cwd=workspace)
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
        if args.phase in {"bootstrap", "production-bootstrap", "prompt", "roundtrip"}:
            inspector: Callable[[subprocess.Popen[Any], dict[str, Any]], dict[str, Any]] | None = None
            if args.phase == "production-bootstrap":
                cli, cli_provenance = resolve_debug_cli(getattr(args, "debug_cli", None), helper)
                before_history = debug_connection_history(cli)
                cli_build_identity = run_text(
                    [str(cli), "--version"],
                    timeout=DEFAULT_TIMEOUT_SECONDS,
                    stream_limit_bytes=4096,
                ).strip()
                if not cli_build_identity or len(cli_build_identity) > 1024:
                    raise ProbeError("resolved DEBUG CLI did not expose a bounded build identity")
                summary["debugCLI"] = {
                    "resolvedExecutable": str(cli),
                    "provenance": cli_provenance,
                    "buildIdentity": cli_build_identity,
                }
                inspector = lambda omp_process, launch_identities: production_transport_identity_evidence(
                    cli, before_history, omp_process, omp, helper, launch_identities
                )
            summary["ompACP"] = acp_probe(
                omp,
                helper,
                workspace,
                output_dir,
                args.phase,
                args.prompt_timeout,
                session_open_inspector=inspector,
            )
            if args.phase == "bootstrap":
                discovery_audit = load_readonly_proxy_audit(
                    output_dir / "discovery-mcp-proxy.audit.json",
                    "discovery",
                    require_exit_on_complete=True,
                )
                summary["ompACP"]["discoveryMCPProxy"] = discovery_audit
                validate_bootstrap_summary(summary["ompACP"])
            elif args.phase == "production-bootstrap":
                transport_evidence = summary["ompACP"].get("productionTransportIdentityEvidence")
                if not isinstance(transport_evidence, dict):
                    raise ProbeError("production-bootstrap did not retain transport identity evidence")
                transport_evidence["terminalConnectionEvidence"] = production_terminal_connection_evidence(
                    cli,
                    transport_evidence,
                )
                validate_production_bootstrap_summary(summary["ompACP"])
            elif args.phase == "prompt":
                validate_prompt_summary(summary["ompACP"])
            elif args.phase == "roundtrip":
                acp = summary["ompACP"]
                proxy_audit = load_readonly_proxy_audit(
                    output_dir / "readonly-mcp-proxy.audit.json",
                    "roundtrip",
                    require_exit_on_complete=True,
                )
                acp["restrictedMCPProxy"] = proxy_audit
                validate_roundtrip_summary(acp)

        if not marker.exists():
            raise ProbeError("read-only workspace marker was removed")
        summary["readOnlyMarkerStillPresent"] = True
        summary["success"] = True
    except BaseException as error:
        reported_error = error
        exit_code = 1
        summary["success"] = False
    finally:
        snapshot_error: BaseException | None = None
        if workspace_before is not None:
            try:
                workspace_after = snapshot_workspace(workspace)
                changed_paths = changed_snapshot_paths(workspace_before, workspace_after)
                summary["workspaceSnapshotAfterSHA256"] = snapshot_digest(workspace_after)
                summary["workspaceUnchanged"] = not changed_paths
                if changed_paths:
                    summary["workspaceChangedPaths"] = changed_paths[:50]
                    snapshot_error = ProbeError(f"{args.phase} changed the disposable workspace")
            except BaseException as error:
                snapshot_error = error
        final_error = combine_probe_errors(
            ("probe operation", reported_error),
            ("final workspace snapshot", snapshot_error),
        )
        if final_error is not None:
            exit_code = 1
            summary["success"] = False
            summary["error"] = str(final_error)
            summary["failureDetails"] = final_error.details
            print(f"OMP ACP live spike did not pass: {final_error}", file=sys.stderr)
        evidence_error: BaseException | None = None
        try:
            write_json_atomically(output_dir / "safe-summary.json", summary)
        except BaseException as error:
            evidence_error = error
        if evidence_error is not None:
            exit_code = 1
            combined = combine_probe_errors(("probe failure", final_error), ("safe-summary evidence write", evidence_error))
            assert combined is not None
            print(f"ERROR: {combined}", file=sys.stderr)
        print(f"Evidence directory: {output_dir}")
    if exit_code == 0:
        print("OMP ACP live spike passed")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
