#!/usr/bin/env python3
"""Fail-closed support primitives for the private OMP qualification smoke."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

MAX_COMMAND_OUTPUT = 1024 * 1024
MAX_GIT_OUTPUT = 32 * 1024 * 1024
MAX_SNAPSHOT_PATHS = 100_000
MAX_SNAPSHOT_FILE_BYTES = 256 * 1024 * 1024
MAX_SNAPSHOT_TOTAL_BYTES = 1024 * 1024 * 1024
MAX_SNAPSHOT_SECONDS = 30.0


class SupportError(RuntimeError):
    pass


def _reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise SupportError(f"JSON response contains duplicate key: {key}")
        result[key] = value
    return result


def _strict_json_loads(raw: str | bytes) -> object:
    try:
        return json.loads(raw, object_pairs_hook=_reject_duplicate_json_keys)
    except json.JSONDecodeError as error:
        raise SupportError("CLI response was malformed JSON") from error


def _strict_json_load_file(path: str) -> object:
    with open(path, encoding="utf-8") as handle:
        return _strict_json_loads(handle.read())


def _process_group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _terminate_group(process: subprocess.Popen[bytes], group_id: int) -> None:
    try:
        os.killpg(group_id, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 2
    while _process_group_exists(group_id) and time.monotonic() < deadline:
        time.sleep(0.02)
    if _process_group_exists(group_id):
        try:
            os.killpg(group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except (ChildProcessError, subprocess.TimeoutExpired):
            pass
    kill_deadline = time.monotonic() + 2
    while _process_group_exists(group_id) and time.monotonic() < kill_deadline:
        time.sleep(0.02)
    if _process_group_exists(group_id):
        raise SupportError("process group survived SIGKILL cleanup bound")


def _bounded_process(command: list[str], timeout: float, limit: int) -> tuple[int, bytes, bytes]:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    group_id = process.pid
    previous_handlers: dict[int, object] = {}

    def interrupted(signum: int, _frame: object) -> None:
        _terminate_group(process, group_id)
        raise KeyboardInterrupt(signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous_handlers[signum] = signal.signal(signum, interrupted)

    selector = selectors.DefaultSelector()
    assert process.stdout is not None and process.stderr is not None
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SupportError("command timed out")
            for key, _ in selector.select(min(remaining, 0.25)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                if len(buffer) + len(chunk) > limit:
                    raise SupportError(f"{key.data} exceeded the output bound")
                buffer.extend(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SupportError("command timed out")
        returncode = process.wait(timeout=remaining)
        # The CLI must not leave descendants holding inherited pipes or state.
        _terminate_group(process, group_id)
        return returncode, bytes(buffers["stdout"]), bytes(buffers["stderr"])
    except (BaseException, subprocess.TimeoutExpired):
        _terminate_group(process, group_id)
        raise
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def run_cli(arguments: argparse.Namespace) -> None:
    command = [
        arguments.cli,
        "--raw-json",
        "-w",
        arguments.window,
        "-c",
        arguments.tool,
        "-j",
        arguments.payload,
    ]
    returncode, stdout, stderr = _bounded_process(command, arguments.timeout, MAX_COMMAND_OUTPUT)
    Path(arguments.stdout).write_bytes(stdout)
    Path(arguments.stderr).write_bytes(stderr)
    if returncode != 0:
        raise SupportError(f"CLI exited with status {returncode}")


def _normalized_response(raw: object, expected_discriminator: str) -> dict[str, object]:
    if not isinstance(raw, dict):
        raise SupportError("CLI response is not an object")

    def reject_error_envelope(value: dict[str, object], label: str) -> None:
        if "error" in value or ("isError" in value and value["isError"] is not False):
            raise SupportError(f"CLI response contains a failed or malformed {label} envelope")

    def append_candidate(value: object, label: str, candidates: list[dict[str, object]]) -> None:
        if not is_payload(value):
            return
        assert isinstance(value, dict)
        reject_error_envelope(value, label)
        if set(value).intersection({"result", "structuredContent", "structured_content"}):
            raise SupportError(f"CLI response contains a nested wrapper hybrid in {label}")
        candidates.append(value)

    def is_payload(value: object) -> bool:
        if not isinstance(value, dict):
            return False
        if expected_discriminator.startswith("diagnostic:"):
            return value.get("ok") is True and value.get("op") == expected_discriminator.removeprefix("diagnostic:")
        if expected_discriminator == "agent_run":
            return (
                isinstance(value.get("status"), str)
                and isinstance(value.get("session_id"), str)
                and bool(value["session_id"])
            )
        if expected_discriminator == "agent_manage:list_agents":
            return isinstance(value.get("agents"), list) and set(value).isdisjoint({"ok", "status", "session_id"})
        if expected_discriminator == "agent_manage:cleanup_sessions":
            return (
                isinstance(value.get("status"), str)
                and type(value.get("deleted_count")) is int
                and type(value.get("skipped_count")) is int
                and isinstance(value.get("deleted_sessions"), list)
                and isinstance(value.get("skipped_sessions"), list)
                and "agents" not in value
            )
        return False

    reject_error_envelope(raw, "top-level")

    candidates: list[dict[str, object]] = []
    append_candidate(raw, "top-level payload", candidates)
    result = raw.get("result")
    if isinstance(result, dict):
        reject_error_envelope(result, "result")
        append_candidate(result, "result payload", candidates)
        for key in ("structuredContent", "structured_content"):
            append_candidate(result.get(key), f"result.{key} payload", candidates)
    for key in ("structuredContent", "structured_content"):
        append_candidate(raw.get(key), f"top-level {key} payload", candidates)
    if len(candidates) != 1:
        raise SupportError("CLI response did not contain exactly one documented result payload")
    return candidates[0]


def normalize_response(arguments: argparse.Namespace) -> None:
    raw = _strict_json_load_file(arguments.input)
    if arguments.tool == "__repoprompt_debug_diagnostics":
        request = json.loads(arguments.payload)
        op = request.get("op") if isinstance(request, dict) else None
        if not isinstance(op, str) or not op:
            raise SupportError("diagnostic request lacks an exact op discriminator")
        discriminator = f"diagnostic:{op}"
    elif arguments.tool == "agent_run":
        discriminator = arguments.tool
    elif arguments.tool == "agent_manage":
        request = json.loads(arguments.payload)
        op = request.get("op") if isinstance(request, dict) else None
        if op not in {"list_agents", "cleanup_sessions"}:
            raise SupportError("unsupported qualification agent_manage operation")
        discriminator = f"agent_manage:{op}"
    else:
        raise SupportError("unsupported qualification response tool")
    normalized = _normalized_response(raw, discriminator)
    with open(arguments.output, "w", encoding="utf-8") as handle:
        json.dump(normalized, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _validate_routing(
    value: object,
    window_id: int,
    overlap_path: str,
) -> tuple[list[dict[str, object]], list[str], list[str]]:
    if not isinstance(value, dict):
        raise SupportError("routing snapshot top-level value must be an object")
    windows = value.get("windows")
    if value.get("ok") is not True or not isinstance(windows, list) or not all(isinstance(item, dict) for item in windows):
        raise SupportError("routing snapshot is invalid")
    typed_windows = windows
    window_ids: list[int] = []
    for window in typed_windows:
        candidate = window.get("window_id")
        if type(candidate) is not int or candidate <= 0:
            raise SupportError("routing snapshot window_id values must be positive integers")
        window_ids.append(candidate)
    if len(set(window_ids)) != len(window_ids):
        raise SupportError("routing snapshot window_id values must be unique")
    target = [window for window in typed_windows if window.get("window_id") == window_id]
    if len(target) != 1:
        raise SupportError("qualification target is unavailable")
    workspace_id = target[0].get("workspace_id")
    try:
        normalized_workspace_id = str(uuid.UUID(workspace_id)) if isinstance(workspace_id, str) else None
    except ValueError as error:
        raise SupportError("qualification target workspace UUID is invalid") from error
    if normalized_workspace_id is None:
        raise SupportError("qualification target workspace UUID is invalid")

    all_roots: set[str] = set()
    target_roots: set[str] = set()
    for window in typed_windows:
        repo_paths = window.get("repo_paths")
        if repo_paths is None:
            repo_paths = []
        if not isinstance(repo_paths, list) or (window is target[0] and not repo_paths):
            raise SupportError("routing snapshot repo_paths must be an array and the qualification target must be non-empty")
        validated: set[str] = set()
        for root in repo_paths:
            if not isinstance(root, str) or not root or not os.path.isabs(root):
                raise SupportError("routing snapshot repo_paths entries must be non-empty absolute strings")
            validated.add(os.path.realpath(root))
        all_roots.update(validated)
        if window is target[0]:
            target_roots = validated

    roots = sorted(all_roots)
    target[0]["workspace_id"] = normalized_workspace_id
    overlap = os.path.realpath(overlap_path)
    for root in roots:
        if os.path.commonpath([overlap, root]) in (overlap, root):
            raise SupportError("evidence path overlaps an active workspace")
    return target, roots, sorted(target_roots)


def preflight_routing(arguments: argparse.Namespace) -> None:
    command = [
        arguments.cli,
        "--raw-json",
        "-w",
        str(arguments.window_id),
        "-c",
        "__repoprompt_debug_diagnostics",
        "-j",
        '{"op":"routing_snapshot","include_records":false,"include_windows":true}',
    ]
    returncode, stdout, _ = _bounded_process(command, arguments.timeout, MAX_COMMAND_OUTPUT)
    if returncode != 0:
        raise SupportError(f"CLI exited with status {returncode}")
    value = _normalized_response(_strict_json_loads(stdout), "diagnostic:routing_snapshot")
    _validate_routing(value, arguments.window_id, arguments.overlap)


def _git(root: str, arguments: list[str]) -> bytes:
    returncode, stdout, _ = _bounded_process(
        ["git", "-C", root, *arguments],
        timeout=20,
        limit=MAX_GIT_OUTPUT,
    )
    if returncode != 0:
        raise SupportError(f"git {' '.join(arguments)} failed for {root}")
    return stdout


def _snapshot_deadline_check(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise SupportError("workspace content snapshot exceeded its deadline")


def _reject_nested_repository(directory_descriptor: int, relative_text: str) -> None:
    try:
        os.stat(b".git", dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise SupportError(f"nested repository is unsupported in workspace fingerprint: {relative_text}")


def _stable_metadata(info: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        stat.S_IFMT(info.st_mode),
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _hash_worktree_path(
    root_descriptor: int,
    relative: bytes,
    digest: hashlib._Hash,
    deadline: float,
) -> int:
    if b"\0" in relative or relative.startswith(b"/"):
        raise SupportError("invalid Git path")
    components = [component for component in relative.rstrip(b"/").split(b"/") if component]
    if not components or any(component in {b".", b".."} for component in components):
        raise SupportError("invalid Git path components")
    relative_text = os.fsdecode(relative)
    parent_descriptor = os.dup(root_descriptor)
    try:
        try:
            for component in components[:-1]:
                _snapshot_deadline_check(deadline)
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent_descriptor,
                )
                os.close(parent_descriptor)
                parent_descriptor = next_descriptor
                _reject_nested_repository(parent_descriptor, os.fsdecode(b"/".join(components[:-1])))
            _snapshot_deadline_check(deadline)
            name = components[-1]
            info = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            digest.update(relative)
            digest.update(b"\0")
            if stat.S_ISLNK(info.st_mode):
                target_value = os.readlink(name, dir_fd=parent_descriptor)
                target = (
                    target_value
                    if isinstance(target_value, bytes)
                    else target_value.encode(errors="surrogateescape")
                )
                after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
                if _stable_metadata(after) != _stable_metadata(info):
                    raise SupportError(f"symlink changed during snapshot: {relative_text}")
                digest.update(b"link\0" + target + b"\0")
                return len(target)
            if stat.S_ISDIR(info.st_mode):
                directory_descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent_descriptor,
                )
                try:
                    _reject_nested_repository(directory_descriptor, relative_text)
                finally:
                    os.close(directory_descriptor)
                digest.update(b"directory\0")
                return 0
            if not stat.S_ISREG(info.st_mode):
                raise SupportError(f"unsupported special file in snapshot: {relative_text}")
            if info.st_size > MAX_SNAPSHOT_FILE_BYTES:
                raise SupportError(f"file exceeds snapshot bound: {relative_text}")
            descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            if isinstance(error, FileNotFoundError):
                raise
            raise SupportError(f"unsafe or unstable workspace path: {relative_text}") from error
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or _stable_metadata(opened) != _stable_metadata(info):
                raise SupportError(f"file changed during snapshot: {relative_text}")
            digest.update(f"file\0{opened.st_size}\0".encode())
            consumed = 0
            while True:
                _snapshot_deadline_check(deadline)
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                consumed += len(chunk)
                if consumed > MAX_SNAPSHOT_FILE_BYTES:
                    raise SupportError(f"file exceeded snapshot bound: {relative_text}")
                digest.update(chunk)
            after = os.fstat(descriptor)
            if consumed != opened.st_size or _stable_metadata(after) != _stable_metadata(opened):
                raise SupportError(f"file changed during snapshot: {relative_text}")
            return consumed
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_descriptor)


def _repository_snapshot(root: str, snapshot_seconds: float = MAX_SNAPSHOT_SECONDS) -> dict[str, object]:
    root = os.path.realpath(root)
    head = _git(root, ["rev-parse", "HEAD"]).strip().decode("ascii")
    index = _git(root, ["ls-files", "--stage", "-z"])
    untracked = _git(root, ["ls-files", "--others", "--exclude-standard", "-z"])
    paths: set[bytes] = set()
    for record in index.split(b"\0"):
        if not record:
            continue
        try:
            header, relative = record.split(b"\t", 1)
            mode, _, stage = header.split(b" ", 2)
        except ValueError as error:
            raise SupportError("malformed git index record") from error
        if stage != b"0":
            raise SupportError("unmerged index entries are unsupported in workspace fingerprint")
        if mode == b"160000":
            raise SupportError("gitlink is unsupported in workspace fingerprint")
        if mode not in {b"100644", b"100755", b"120000"}:
            raise SupportError(f"unsupported git index mode: {os.fsdecode(mode)}")
        paths.add(relative)
    paths.update(path for path in untracked.split(b"\0") if path)
    if len(paths) > MAX_SNAPSHOT_PATHS:
        raise SupportError("workspace path count exceeded snapshot bound")
    worktree = hashlib.sha256()
    total = 0
    deadline = time.monotonic() + snapshot_seconds
    root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        for relative in sorted(paths):
            _snapshot_deadline_check(deadline)
            try:
                total += _hash_worktree_path(root_descriptor, relative, worktree, deadline)
            except FileNotFoundError:
                worktree.update(relative + b"\0missing\0")
            if total > MAX_SNAPSHOT_TOTAL_BYTES:
                raise SupportError("workspace content exceeded snapshot bound")
    finally:
        os.close(root_descriptor)
    return {
        "head": head,
        "index_sha256": hashlib.sha256(index).hexdigest(),
        "worktree_sha256": worktree.hexdigest(),
        "tracked_and_existing_untracked_path_count": len(paths),
        "content_bytes_hashed": total,
        "ignored_path_scope": "excluded according to git ls-files --others --exclude-standard",
        "symlink_policy": "link target text hashed; targets never followed",
    }


def _snapshot_roots(roots: list[str]) -> dict[str, dict[str, object]]:
    return {root: _repository_snapshot(root) for root in roots}


def snapshot(arguments: argparse.Namespace) -> None:
    with open(arguments.routing, encoding="utf-8") as handle:
        value = json.load(handle)
    target, roots, target_roots = _validate_routing(value, arguments.window_id, arguments.overlap)
    value["qualification_target"] = target[0]
    content_snapshots = _snapshot_roots(roots)
    missing_target_roots = sorted(set(target_roots) - set(content_snapshots))
    if missing_target_roots:
        raise SupportError("qualification target roots are missing from the content snapshot")
    value["active_workspace_content_snapshots"] = content_snapshots
    with open(arguments.output, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    cli = subparsers.add_parser("run-cli")
    cli.add_argument("cli")
    cli.add_argument("window")
    cli.add_argument("tool")
    cli.add_argument("payload")
    cli.add_argument("stdout")
    cli.add_argument("stderr")
    cli.add_argument("timeout", type=float)
    cli.set_defaults(function=run_cli)

    normalize = subparsers.add_parser("normalize-response")
    normalize.add_argument("input")
    normalize.add_argument("output")
    normalize.add_argument("tool")
    normalize.add_argument("payload")
    normalize.set_defaults(function=normalize_response)

    preflight = subparsers.add_parser("preflight-routing")
    preflight.add_argument("cli")
    preflight.add_argument("window_id", type=int)
    preflight.add_argument("overlap")
    preflight.add_argument("timeout", type=float)
    preflight.set_defaults(function=preflight_routing)

    state = subparsers.add_parser("snapshot")
    state.add_argument("routing")
    state.add_argument("output")
    state.add_argument("window_id", type=int)
    state.add_argument("overlap")
    state.set_defaults(function=snapshot)

    arguments = parser.parse_args()
    try:
        arguments.function(arguments)
        return 0
    except (SupportError, OSError, ValueError, json.JSONDecodeError, KeyboardInterrupt) as error:
        print(f"omp qualification support: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
