#!/usr/bin/env python3
"""Quarantine leaked XCTest fixture workspaces from the RepoPrompt CE workspace store.

Modes (stdlib only, Python 3):

  --dry-run (default)    Scan <app-support>/Workspaces read-only, write a JSON manifest
                         (refuses to write it inside <app-support>), print a summary.
  --apply                Re-validate every manifest candidate of the selected --class
                         values immediately before moving it, then atomically rename it into
                         <app-support>/Workspaces-Quarantine-<UTC timestamp>/ (same volume,
                         never deletes). restore-manifest.jsonl there is a write-ahead journal:
                         an fsynced "moving" intent record precedes every rename and a "moved"
                         (or "failed") record follows it. A failed rename is counted and skipped.
  --restore FILE         Move the entries listed in a restore-manifest.jsonl back. Reconciles
                         interrupted runs (an intent whose target exists and whose origin does
                         not is restored), skips a truncated/corrupt trailing line (reported),
                         and refuses any entry whose original location exists again.
  --self-test            Exercise dry-run/apply/restore against a temporary fake store.

--apply and --restore refuse to run while any RepoPrompt CE app (Dev, release, or an
unbundled SwiftPM .build product), its repoprompt-mcp / CLI helpers, `swift run`, or a
RepoPrompt XCTest bundle is running. There is no override. The app and its helpers MUST stay
quit for the whole run: the script re-checks processes and re-collects the hard-reference set
at start, every 100 moves and at least every ~5 s, and stops cleanly (exit 3) if a process
appears or the references change, but it cannot prevent a launch mid-run (an in-app maintenance
lock is out of scope). An exclusive lock file <app-support>/.rpce-quarantine.lock prevents two
--apply/--restore runs from overlapping.

Candidate classes (a directory must match one exactly; everything else is kept):

  A  index-only fixture: name parses as Workspace-<name>-<UUID>; contents are exactly
     AgentSessions/AgentSessionIndex.json plus optional truly-empty Chats/ and _git_data/;
     the index is an empty AgentSessionMetadataIndex; nothing modified in the last 24 h.
  B  ephemeral fixture: as A, plus workspace.json with ephemeralFlag == true whose id/name
     reproduce the directory name; the empty index is optional. Needs separate approval.

Workspaces referenced by app state (workspacesIndex.json, windowSessions.json, MCP routing
state, AgentRecovery/v1, Partitions) are always excluded. Settings/globalSettings.json
per-workspace maps are a soft reference: flagged and counted, not excluded. Any reference
store that exists but is unreadable or has an unknown shape aborts the run (fail closed); a
reference container (MCP, AgentRecovery, AgentRecovery/v1/*, Partitions, Settings) that exists
but is not a real directory (regular file, symlink, dangling symlink, unreadable) also aborts.
"""

from __future__ import annotations

import argparse
import collections
import datetime as _dt
import errno
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

MANIFEST_SCHEMA = "rpce-fixture-workspace-quarantine-manifest/v1"
RESTORE_SCHEMA = "rpce-fixture-workspace-quarantine-restore/v1"
DEFAULT_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/RepoPrompt CE")
MIN_AGE_NS = 24 * 3600 * 1_000_000_000
LOCK_NAME = ".rpce-quarantine.lock"
CHECK_EVERY_MOVES = 100
CHECK_EVERY_SECONDS = 5.0

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
UUID_ANY_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
NAME_GROUP_SUFFIX_RE = re.compile(r"[ -][0-9A-Fa-f]{8}$")
PARTITION_FILE_RE = re.compile(
    r"^filepartitions-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
    r"(?:-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?\.json$"
)

DIR_PREFIX = "Workspace-"  # WorkspaceDirectoryName.prefix
INDEX_DIR = "AgentSessions"
INDEX_REL = "AgentSessions/AgentSessionIndex.json"
WORKSPACE_JSON = "workspace.json"
ALLOWED_EMPTY_DIRS = ("Chats", "_git_data")
MAX_TREE_ENTRIES = 32
MAX_INDEX_BYTES = 64 * 1024
MAX_WORKSPACE_JSON_BYTES = 4 * 1024 * 1024

# AgentSessionMetadataIndex (Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionMetadataIndex.swift).
INDEX_KEYS = {"schemaVersion", "generatedAt", "lastReconciledAt", "entries", "quarantinedFiles"}
INDEX_MAX_SCHEMA = 8  # AgentSessionMetadataIndex.currentSchemaVersion
# WorkspaceIndexEntry (WorkspaceManagerViewModel.swift).
WORKSPACE_INDEX_KEYS = {"id", "name", "customStoragePath", "isSystemWorkspace", "isHiddenInMenus"}
# WindowSessionSnapshot / WindowSessionEntry (WindowStateManager.swift); written with version 4.
WINDOW_SESSION_MAX_VERSION = 4
WINDOW_ENTRY_KEYS = {
    "windowKind", "workspaceID", "workspaceName", "isSystemWorkspace", "isEphemeral",
    "primaryRepoPath", "lastFocused", "workspaceInstanceNumber",
}
# MCPRoutingState.ClientRecord (MCPRoutingState.swift); file names from MCPFilesystemIdentity.
ROUTING_FILES = ("mcp-routing.json", "mcp-routing_debug.json")
ROUTING_RECORD_KEYS = {
    "clientID", "lastTransport", "sessionKey", "lastWindowID", "lastWorkspaceID",
    "lastWorkspaceInstanceNumber", "lastConnectionUUID", "lastSeenAt",
}
# GlobalSettingsDocument (GlobalSettingsDocument.swift).
GLOBAL_SETTINGS_KEYS = {
    "schemaVersion", "schemaLineage", "updatedAt", "copySettingsByWorkspaceID",
    "chatSettingsByWorkspaceID", "agentModelsSettingsByWorkspaceID", "globalDefaults",
    "scalarPreferences",
}
GLOBAL_SETTINGS_MAX_SCHEMA = 5
GLOBAL_SETTINGS_LINEAGE = "repoprompt-ce.global-settings"
GLOBAL_SETTINGS_MAPS = ("copySettingsByWorkspaceID", "chatSettingsByWorkspaceID", "agentModelsSettingsByWorkspaceID")
RECOVERY_V1_ENTRIES = {"launch-state.json", "sessions", "tombstones", "attachments"}
IGNORABLE_NAMES = {".DS_Store"}

APP_PROCESS_PATTERNS = (
    r"RepoPrompt[^/]*\.app/Contents/MacOS/",
    r"repoprompt-mcp",
    r"repoprompt_ce_cli",
    r"repoprompt-gateway",
    r"RepoPrompt[A-Za-z]*Tests\.xctest",
    r"RepoPromptPackageTests",
    r"/\.build/[^ ]*/RepoPrompt( |$)",  # unbundled SwiftPM dev build
    r"swift-run",
)


class ReferenceStoreError(Exception):
    """A reference store exists but cannot be read or has an unknown shape."""


# --------------------------------------------------------------------------------------
# Name grammar (mirrors WorkspaceDirectoryName / WorkspaceManagerViewModel.directoryName)
# --------------------------------------------------------------------------------------

def is_uuid(value) -> bool:
    return isinstance(value, str) and UUID_RE.match(value) is not None


def parse_dir_name(dir_name: str):
    """Mirror of WorkspaceDirectoryName.parse; returns (name, UUID upper) or None when no id."""
    if not dir_name.startswith(DIR_PREFIX):
        return None
    components = dir_name[len(DIR_PREFIX):].split("-")
    for i in range(len(components) - 1, 0, -1):
        potential = "-".join(components[i:])
        if UUID_RE.match(potential):
            name_part = "-".join(components[:i])
            return (name_part if name_part else dir_name), potential.upper()
    return None


def _swift_is_whitespace_or_newline(ch: str) -> bool:
    # CharacterSet.whitespacesAndNewlines: Unicode Z* categories, U+0009...U+000D, U+0085.
    return ch in "\t\n\v\f\r\x85" or unicodedata.category(ch) in ("Zs", "Zl", "Zp")


def swift_trim(value: str) -> str:
    start, end = 0, len(value)
    while start < end and _swift_is_whitespace_or_newline(value[start]):
        start += 1
    while end > start and _swift_is_whitespace_or_newline(value[end - 1]):
        end -= 1
    return value[start:end]


def expected_dir_name(name: str, workspace_id: str) -> str:
    safe_name = swift_trim(name.replace("/", "_"))
    return f"{DIR_PREFIX}{safe_name}-{workspace_id.upper()}"


def name_group(name: str) -> str:
    return NAME_GROUP_SUFFIX_RE.sub("", name)


# --------------------------------------------------------------------------------------
# Reference stores
# --------------------------------------------------------------------------------------

def _load_json(path: str, what: str, max_bytes: int | None = None):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            raise ReferenceStoreError(f"{what}: {path} is not a regular file")
        if max_bytes is not None and st.st_size > max_bytes:
            raise ReferenceStoreError(f"{what}: {path} is larger than {max_bytes} bytes")
        with open(path, "rb") as handle:
            data = handle.read()
        return json.loads(data.decode("utf-8")), data, st
    except ReferenceStoreError:
        raise
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise ReferenceStoreError(f"{what}: cannot read {path}: {error}") from error


def _container(path: str, what: str, required: bool = False) -> bool:
    """Return True for a readable real directory, False when absent; raise otherwise (fail closed)."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if required:
            raise ReferenceStoreError(f"{what}: {path} does not exist") from None
        return False
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot stat {path}: {error}") from error
    if stat.S_ISLNK(st.st_mode):
        raise ReferenceStoreError(f"{what}: {path} is a symlink (unsupported)")
    if not stat.S_ISDIR(st.st_mode):
        raise ReferenceStoreError(f"{what}: {path} exists but is not a directory")
    try:
        with os.scandir(path):
            pass
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read directory {path}: {error}") from error
    return True


def _require(condition: bool, what: str, message: str):
    if not condition:
        raise ReferenceStoreError(f"{what}: unknown schema: {message}")


def _store_record(path, kind, strength, ids, st=None, extra=None):
    record = {
        "path": path,
        "kind": kind,
        "strength": strength,
        "workspaceIDs": len(ids),
    }
    if st is not None:
        record["size"] = st.st_size
        record["mtime_ns"] = st.st_mtime_ns
    if extra:
        record.update(extra)
    return record


def _collect_workspaces_index(workspaces_dir, hard, stores):
    path = os.path.join(workspaces_dir, "workspacesIndex.json")
    if not os.path.lexists(path):
        stores.append({"path": path, "kind": "workspacesIndex", "strength": "hard", "present": False})
        return
    what = "workspacesIndex.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, list), what, "top level is not an array")
    ids = set()
    for entry in data:
        _require(isinstance(entry, dict), what, "entry is not an object")
        _require(set(entry) <= WORKSPACE_INDEX_KEYS, what, f"unexpected keys {sorted(set(entry) - WORKSPACE_INDEX_KEYS)}")
        _require(is_uuid(entry.get("id")), what, "entry id is not a UUID")
        _require(isinstance(entry.get("name"), str), what, "entry name is not a string")
        _require(isinstance(entry.get("isSystemWorkspace"), bool), what, "isSystemWorkspace is not a bool")
        _require(isinstance(entry.get("isHiddenInMenus"), bool), what, "isHiddenInMenus is not a bool")
        _require(entry.get("customStoragePath") is None or isinstance(entry.get("customStoragePath"), str), what, "customStoragePath is not a string")
        ids.add(entry["id"].upper())
    for workspace_id in ids:
        hard[workspace_id].add("workspacesIndex")
    stores.append(_store_record(path, "workspacesIndex", "hard", ids, st, {"present": True, "entries": len(data)}))


def _collect_window_sessions(app_support, hard, stores):
    path = os.path.join(app_support, "windowSessions.json")
    if not os.path.lexists(path):
        stores.append({"path": path, "kind": "windowSessions", "strength": "hard", "present": False})
        return
    what = "windowSessions.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, dict) and set(data) == {"version", "windows"}, what, "expected {version, windows}")
    version = data["version"]
    _require(isinstance(version, int) and not isinstance(version, bool) and 1 <= version <= WINDOW_SESSION_MAX_VERSION, what, f"unsupported version {version!r}")
    _require(isinstance(data["windows"], list), what, "windows is not an array")
    ids = set()
    for window in data["windows"]:
        _require(isinstance(window, dict), what, "window entry is not an object")
        _require(set(window) <= WINDOW_ENTRY_KEYS, what, f"unexpected keys {sorted(set(window) - WINDOW_ENTRY_KEYS)}")
        workspace_id = window.get("workspaceID")
        _require(workspace_id is None or is_uuid(workspace_id), what, "workspaceID is not a UUID")
        if workspace_id:
            ids.add(workspace_id.upper())
    for workspace_id in ids:
        hard[workspace_id].add("windowSessions")
    stores.append(_store_record(path, "windowSessions", "hard", ids, st, {"present": True, "version": version}))


def _collect_mcp_routing(app_support, hard, stores):
    mcp_dir = os.path.join(app_support, "MCP")
    if _container(mcp_dir, "MCP"):
        try:
            names = os.listdir(mcp_dir)
        except OSError as error:
            raise ReferenceStoreError(f"MCP: cannot list {mcp_dir}: {error}") from error
        unknown = sorted(n for n in names if n.startswith("mcp-routing") and n.endswith(".json") and n not in ROUTING_FILES)
        if unknown:
            raise ReferenceStoreError(f"MCP routing: unknown routing-state files {unknown}")
    for file_name in ROUTING_FILES:
        path = os.path.join(mcp_dir, file_name)
        if not os.path.lexists(path):
            stores.append({"path": path, "kind": "mcpRouting", "strength": "hard", "present": False})
            continue
        what = f"MCP/{file_name}"
        data, _, st = _load_json(path, what)
        _require(isinstance(data, dict) and set(data) == {"records"}, what, "expected {records}")
        _require(isinstance(data["records"], dict), what, "records is not an object")
        ids = set()
        for client_records in data["records"].values():
            _require(isinstance(client_records, list), what, "client records is not an array")
            for record in client_records:
                _require(isinstance(record, dict), what, "record is not an object")
                _require(set(record) <= ROUTING_RECORD_KEYS, what, f"unexpected keys {sorted(set(record) - ROUTING_RECORD_KEYS)}")
                workspace_id = record.get("lastWorkspaceID")
                _require(workspace_id is None or is_uuid(workspace_id), what, "lastWorkspaceID is not a UUID")
                if workspace_id:
                    ids.add(workspace_id.upper())
        for workspace_id in ids:
            hard[workspace_id].add("mcpRouting")
        stores.append(_store_record(path, "mcpRouting", "hard", ids, st, {"present": True}))


def _scan_recovery_json_dir(directory, what, ids, require_session_id):
    count = 0
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.name in IGNORABLE_NAMES:
                continue
            stem, ext = os.path.splitext(entry.name)
            _require(entry.is_file(follow_symlinks=False) and ext == ".json" and is_uuid(stem), what, f"unexpected entry {entry.name!r}")
            data, raw, _ = _load_json(entry.path, what)
            _require(isinstance(data, dict), what, f"{entry.name} is not an object")
            _require(data.get("schemaVersion") == 1, what, f"{entry.name} schemaVersion {data.get('schemaVersion')!r}")
            if require_session_id:
                _require(isinstance(data.get("sessionID"), str) and data["sessionID"].upper() == stem.upper(), what, f"{entry.name} sessionID mismatch")
            ids.update(match.upper() for match in UUID_ANY_RE.findall(raw.decode("utf-8")))
            count += 1
    return count


def _collect_agent_recovery(app_support, hard, stores):
    root = os.path.join(app_support, "AgentRecovery")
    if not _container(root, "AgentRecovery"):
        stores.append({"path": root, "kind": "agentRecovery", "strength": "hard", "present": False})
        return
    what = "AgentRecovery"
    try:
        top = [n for n in os.listdir(root) if n not in IGNORABLE_NAMES]
        _require(set(top) <= {"v1"}, what, f"unknown versions {sorted(set(top) - {'v1'})}")
        v1 = os.path.join(root, "v1")
        ids = set()
        counts = {}
        if _container(v1, "AgentRecovery/v1"):
            v1_names = [n for n in os.listdir(v1) if n not in IGNORABLE_NAMES]
            _require(set(v1_names) <= RECOVERY_V1_ENTRIES, what, f"unknown v1 entries {sorted(set(v1_names) - RECOVERY_V1_ENTRIES)}")
            launch = os.path.join(v1, "launch-state.json")
            if os.path.lexists(launch):
                data, raw, _ = _load_json(launch, what)
                _require(isinstance(data, dict) and data.get("schemaVersion") == 1, what, "launch-state.json schemaVersion")
                ids.update(m.upper() for m in UUID_ANY_RE.findall(raw.decode("utf-8")))
            for sub, needs_session in (("sessions", True), ("tombstones", True)):
                path = os.path.join(v1, sub)
                if _container(path, f"AgentRecovery/v1/{sub}"):
                    counts[sub] = _scan_recovery_json_dir(path, f"AgentRecovery/v1/{sub}", ids, needs_session)
            attachments = os.path.join(v1, "attachments")
            if _container(attachments, "AgentRecovery/v1/attachments"):
                n = 0
                for name in os.listdir(attachments):
                    if name in IGNORABLE_NAMES:
                        continue
                    _require(is_uuid(name) and stat.S_ISDIR(os.lstat(os.path.join(attachments, name)).st_mode), what, f"unexpected attachment entry {name!r}")
                    ids.add(name.upper())
                    n += 1
                counts["attachments"] = n
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read {root}: {error}") from error
    for workspace_id in ids:
        hard[workspace_id].add("agentRecovery")
    stores.append(_store_record(root, "agentRecovery", "hard", ids, None, {"present": True, "files": counts, "note": "every UUID string in recovery data counts"}))


def _collect_partitions(app_support, hard, stores):
    root = os.path.join(app_support, "Partitions")
    if not _container(root, "Partitions"):
        stores.append({"path": root, "kind": "partitions", "strength": "hard", "present": False})
        return
    what = "Partitions"
    ids = set()
    files = 0
    try:
        with os.scandir(root) as repos:
            for repo in repos:
                if repo.name in IGNORABLE_NAMES:
                    continue
                _require(repo.is_dir(follow_symlinks=False), what, f"unexpected entry {repo.name!r}")
                with os.scandir(repo.path) as entries:
                    for entry in entries:
                        if entry.name in IGNORABLE_NAMES:
                            continue
                        match = PARTITION_FILE_RE.match(entry.name)
                        _require(match is not None and entry.is_file(follow_symlinks=False), what, f"unexpected file {repo.name}/{entry.name}")
                        ids.add(match.group(1).upper())
                        files += 1
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read {root}: {error}") from error
    for workspace_id in ids:
        hard[workspace_id].add("partitions")
    stores.append(_store_record(root, "partitions", "hard", ids, None, {"present": True, "files": files}))


def _collect_global_settings(app_support, soft, stores):
    path = os.path.join(app_support, "Settings", "globalSettings.json")
    if not _container(os.path.dirname(path), "Settings") or not os.path.lexists(path):
        stores.append({"path": path, "kind": "globalSettings", "strength": "soft", "present": False})
        return
    what = "Settings/globalSettings.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, dict), what, "top level is not an object")
    _require(set(data) <= GLOBAL_SETTINGS_KEYS, what, f"unexpected keys {sorted(set(data) - GLOBAL_SETTINGS_KEYS)}")
    version = data.get("schemaVersion")
    _require(isinstance(version, int) and not isinstance(version, bool) and 1 <= version <= GLOBAL_SETTINGS_MAX_SCHEMA, what, f"unsupported schemaVersion {version!r}")
    lineage = data.get("schemaLineage")
    _require(lineage == GLOBAL_SETTINGS_LINEAGE or (lineage is None and version <= 2), what, f"unknown lineage {lineage!r}")
    ids = set()
    for key in GLOBAL_SETTINGS_MAPS:
        mapping = data.get(key)
        if mapping is None and key == "agentModelsSettingsByWorkspaceID":
            continue
        _require(isinstance(mapping, dict), what, f"{key} is not an object")
        for workspace_id in mapping:
            _require(is_uuid(workspace_id), what, f"{key} has non-UUID key")
            ids.add(workspace_id.upper())
    for workspace_id in ids:
        soft[workspace_id].add("globalSettings")
    stores.append(_store_record(path, "globalSettings", "soft", ids, st, {"present": True, "schemaVersion": version}))


def collect_references(app_support: str, workspaces_dir: str):
    hard = collections.defaultdict(set)
    soft = collections.defaultdict(set)
    stores = []
    _container(app_support, "app support", required=True)
    _container(workspaces_dir, "Workspaces", required=True)
    _collect_workspaces_index(workspaces_dir, hard, stores)
    _collect_window_sessions(app_support, hard, stores)
    _collect_mcp_routing(app_support, hard, stores)
    _collect_agent_recovery(app_support, hard, stores)
    _collect_partitions(app_support, hard, stores)
    _collect_global_settings(app_support, soft, stores)
    return hard, soft, stores


# --------------------------------------------------------------------------------------
# Directory classification
# --------------------------------------------------------------------------------------

def _kind(mode: int) -> str:
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def scan_tree(path: str, limit: int = MAX_TREE_ENTRIES):
    """Return ([rel, kind, size, mtime_ns, allocated], overflow) for path ('.') and descendants."""
    st = os.lstat(path)
    out = [[".", _kind(st.st_mode), st.st_size, st.st_mtime_ns, st.st_blocks * 512]]
    if out[0][1] != "dir":
        return out, False
    stack = [(path, "")]
    while stack:
        directory, prefix = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                est = entry.stat(follow_symlinks=False)
                rel = prefix + entry.name
                kind = _kind(est.st_mode)
                out.append([rel, kind, est.st_size, est.st_mtime_ns, est.st_blocks * 512])
                if len(out) > limit:
                    return out, True
                if kind == "dir":
                    stack.append((entry.path, rel + "/"))
    out.sort(key=lambda item: item[0])
    return out, False


def validate_index(path: str, size: int):
    """Return (ok, reason, schemaVersion) for an AgentSessionIndex.json that must be empty."""
    if size > MAX_INDEX_BYTES:
        return False, "index_too_large", None
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return False, "index_unreadable", None
    if not isinstance(data, dict) or not set(data) <= INDEX_KEYS:
        return False, "index_unsupported_shape", None
    version = data.get("schemaVersion")
    if not isinstance(version, int) or isinstance(version, bool) or not 1 <= version <= INDEX_MAX_SCHEMA:
        return False, "index_unsupported_schema", version
    generated = data.get("generatedAt")
    if not isinstance(generated, (int, float)) or isinstance(generated, bool):
        return False, "index_unsupported_shape", version
    reconciled = data.get("lastReconciledAt")
    if reconciled is not None and (not isinstance(reconciled, (int, float)) or isinstance(reconciled, bool)):
        return False, "index_unsupported_shape", version
    if "entries" not in data or not isinstance(data["entries"], list):
        return False, "index_unsupported_shape", version
    quarantined = data.get("quarantinedFiles", [])
    if not isinstance(quarantined, list):
        return False, "index_unsupported_shape", version
    if data["entries"] or quarantined:
        return False, "index_not_empty", version
    return True, None, version


def validate_workspace_json(path: str, size: int, dir_name: str, dir_uuid: str):
    """Return (ok, reason, info) for class B workspace.json."""
    if size > MAX_WORKSPACE_JSON_BYTES:
        return False, "workspace_json_too_large", None
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return False, "workspace_json_unreadable", None
    if not isinstance(data, dict):
        return False, "workspace_json_unreadable", None
    if data.get("ephemeralFlag") is not True:
        return False, "workspace_not_ephemeral", None
    workspace_id, name = data.get("id"), data.get("name")
    if not is_uuid(workspace_id) or not isinstance(name, str):
        return False, "workspace_identity_mismatch", None
    if workspace_id.upper() != dir_uuid or expected_dir_name(name, workspace_id) != dir_name:
        return False, "workspace_identity_mismatch", None
    if data.get("isSystemWorkspace") is not False:
        return False, "workspace_system_or_unknown", None
    if data.get("customStoragePath") is not None:
        return False, "workspace_custom_storage", None
    repo_paths = data.get("repoPaths") if isinstance(data.get("repoPaths"), list) else []
    info = {
        "repoPaths": [p for p in repo_paths if isinstance(p, str)][:8],
        "repoPathsExisting": sum(1 for p in repo_paths if isinstance(p, str) and os.path.exists(p)),
    }
    return True, None, info


def classify(workspaces_dir: str, dir_name: str, now_ns: int, hard, soft):
    """Classify one entry of the Workspaces directory. Never mutates anything."""
    path = os.path.join(workspaces_dir, dir_name)
    result = {"dir": dir_name, "class": None, "reason": None}
    try:
        top = os.lstat(path)
    except OSError:
        result["reason"] = "missing"
        return result
    if stat.S_ISLNK(top.st_mode):
        result["reason"] = "symlink_entry"
        return result
    if not stat.S_ISDIR(top.st_mode):
        result["reason"] = "not_directory"
        return result
    parsed = parse_dir_name(dir_name)
    if parsed is None:
        result["reason"] = "name_unparsed"
        return result
    name, workspace_id = parsed
    result.update({"workspaceID": workspace_id, "name": name, "nameGroup": name_group(name)})
    if workspace_id in hard:
        result["reason"] = "referenced"
        result["detail"] = sorted(hard[workspace_id])
        return result
    try:
        tree, overflow = scan_tree(path)
    except OSError as error:
        result["reason"] = "scan_failed"
        result["detail"] = str(error)
        return result
    if overflow:
        result["reason"] = "unexpected_content"
        result["detail"] = "more than %d entries" % MAX_TREE_ENTRIES
        return result
    entries = {item[0]: item for item in tree}
    expected_kinds = {".": "dir", INDEX_DIR: "dir", INDEX_REL: "file", WORKSPACE_JSON: "file"}
    expected_kinds.update({d: "dir" for d in ALLOWED_EMPTY_DIRS})
    unexpected = sorted(rel for rel in entries if rel not in expected_kinds)
    if unexpected:
        if any(rel.startswith(INDEX_DIR + "/AgentSession-") for rel in unexpected):
            result["reason"] = "has_agent_sessions"
        elif any(rel.startswith("Chats/") for rel in unexpected):
            result["reason"] = "chats_not_empty"
        elif any(rel.startswith("_git_data/") for rel in unexpected):
            result["reason"] = "git_data_not_empty"
        else:
            result["reason"] = "unexpected_content"
        result["detail"] = unexpected[:5]
        return result
    wrong_kind = sorted(rel for rel, item in entries.items() if item[1] != expected_kinds[rel])
    if wrong_kind:
        result["reason"] = "unexpected_entry_type"
        result["detail"] = wrong_kind
        return result
    has_index = INDEX_REL in entries
    has_workspace_json = WORKSPACE_JSON in entries
    if INDEX_DIR in entries and not has_index:
        result["reason"] = "agentsessions_without_index"
        return result
    if not has_index and not has_workspace_json:
        result["reason"] = "no_index_no_workspace_json"
        return result
    too_recent = sorted(rel for rel, item in entries.items() if now_ns - item[3] < MIN_AGE_NS)
    if too_recent:
        result["reason"] = "too_recent"
        result["detail"] = too_recent
        return result
    index_version = None
    if has_index:
        ok, reason, index_version = validate_index(os.path.join(path, INDEX_REL), entries[INDEX_REL][2])
        if not ok:
            result["reason"] = reason
            return result
    workspace_info = None
    if has_workspace_json:
        ok, reason, workspace_info = validate_workspace_json(
            os.path.join(path, WORKSPACE_JSON), entries[WORKSPACE_JSON][2], dir_name, workspace_id
        )
        if not ok:
            result["reason"] = reason
            return result
    klass = "B" if has_workspace_json else "A"
    empty_dirs = [d for d in ALLOWED_EMPTY_DIRS if d in entries]
    files = [item[:4] for item in tree]
    result.update({
        "class": klass,
        "emptyDirs": empty_dirs,
        "files": files,
        "bytes": sum(item[2] for item in tree if item[1] == "file"),
        "allocatedBytes": sum(item[4] for item in tree),
        "indexSchemaVersion": index_version,
        "softReferences": sorted(soft.get(workspace_id, ())),
    })
    parts = ["ephemeral workspace.json matching dir name" if klass == "B" else "index-only"]
    if has_index:
        parts.append(f"empty AgentSessionIndex (schemaVersion {index_version})")
    if empty_dirs:
        parts.append("empty " + "+".join(d + "/" for d in empty_dirs))
    parts.append("all mtimes > 24h")
    parts.append("unreferenced")
    result["reason"] = "; ".join(parts)
    if workspace_info is not None:
        result["workspaceJSON"] = workspace_info
    return result


# --------------------------------------------------------------------------------------
# Dry run
# --------------------------------------------------------------------------------------

def _is_within(path: str, root: str) -> bool:
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _atomic_write_json(path: str, payload) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=1, sort_keys=False)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def run_dry(app_support: str, manifest_path: str, now_ns: int | None = None, quiet: bool = False):
    started = time.monotonic()
    app_support = os.path.abspath(app_support)
    workspaces_dir = os.path.join(app_support, "Workspaces")
    if _is_within(manifest_path, app_support):
        raise SystemExit(f"refusing to write the manifest inside {app_support}")
    hard, soft, stores = collect_references(app_support, workspaces_dir)
    now_ns = time.time_ns() if now_ns is None else now_ns
    candidates, excluded = [], []
    scanned = 0
    with os.scandir(workspaces_dir) as entries:
        for entry in entries:
            scanned += 1
            result = classify(workspaces_dir, entry.name, now_ns, hard, soft)
            if result["class"]:
                candidates.append(result)
            else:
                record = {"dir": result["dir"], "reason": result["reason"]}
                if "detail" in result:
                    record["detail"] = result["detail"]
                excluded.append(record)
    candidates.sort(key=lambda c: c["dir"])
    excluded.sort(key=lambda c: c["dir"])
    summary = summarize(candidates, excluded, stores, scanned, time.monotonic() - started)
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "generatedAt": _dt.datetime.fromtimestamp(now_ns / 1e9, _dt.timezone.utc).isoformat(),
        "generatedAtNs": now_ns,
        "appSupport": app_support,
        "workspacesDir": workspaces_dir,
        "workspacesDev": os.stat(workspaces_dir).st_dev,
        "minAgeHours": MIN_AGE_NS / 3.6e12,
        "allowedEmptyDirs": list(ALLOWED_EMPTY_DIRS),
        "referenceStores": stores,
        "summary": summary,
        "candidates": candidates,
        "excluded": excluded,
    }
    _atomic_write_json(manifest_path, manifest)
    if not quiet:
        print_summary(summary, manifest_path)
    return manifest


def summarize(candidates, excluded, stores, scanned, seconds):
    by_class = {}
    for klass in ("A", "B"):
        members = [c for c in candidates if c["class"] == klass]
        combos = collections.Counter("+".join(c["emptyDirs"]) or "(none)" for c in members)
        by_class[klass] = {
            "count": len(members),
            "bytes": sum(c["bytes"] for c in members),
            "allocatedBytes": sum(c["allocatedBytes"] for c in members),
            "softReferencedGlobalSettings": sum(1 for c in members if "globalSettings" in c["softReferences"]),
            "emptyDirCombos": dict(combos.most_common()),
        }
    groups = collections.defaultdict(lambda: {"A": 0, "B": 0})
    for c in candidates:
        groups[c["nameGroup"]][c["class"]] += 1
    top = sorted(groups.items(), key=lambda kv: (-(kv[1]["A"] + kv[1]["B"]), kv[0]))[:30]
    reasons = collections.Counter(e["reason"] for e in excluded)
    referenced_by = collections.Counter()
    for e in excluded:
        if e["reason"] == "referenced":
            for store in e.get("detail", []):
                referenced_by[store] += 1
    return {
        "scanned": scanned,
        "runtimeSeconds": round(seconds, 2),
        "classes": by_class,
        "excludedByReason": dict(reasons.most_common()),
        "referencedByStore": dict(referenced_by.most_common()),
        "topNameGroups": [{"group": g, "A": v["A"], "B": v["B"], "total": v["A"] + v["B"]} for g, v in top],
        "referenceStores": [{k: s[k] for k in ("kind", "strength", "path", "workspaceIDs", "present") if k in s} for s in stores],
    }


def _human(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return str(n)


def print_summary(summary, manifest_path):
    print(f"Manifest: {manifest_path}")
    print(f"Scanned {summary['scanned']} entries in {summary['runtimeSeconds']} s")
    print("Reference stores:")
    for store in summary["referenceStores"]:
        state = f"{store.get('workspaceIDs', 0)} workspace IDs" if store.get("present", True) else "absent"
        print(f"  [{store['strength']}] {store['kind']}: {state}  ({store['path']})")
    for klass, info in summary["classes"].items():
        print(
            f"Class {klass}: {info['count']} dirs, {_human(info['bytes'])} logical, "
            f"{_human(info['allocatedBytes'])} allocated, {info['softReferencedGlobalSettings']} also in globalSettings"
        )
        for combo, count in info["emptyDirCombos"].items():
            print(f"    empty dirs {combo}: {count}")
    print("Excluded by reason:")
    for reason, count in summary["excludedByReason"].items():
        print(f"  {count:7d}  {reason}")
    if summary["referencedByStore"]:
        print("  referenced, by store: " + ", ".join(f"{k}={v}" for k, v in summary["referencedByStore"].items()))
    print("Top name groups (candidates):")
    for group in summary["topNameGroups"]:
        print(f"  {group['total']:7d}  A={group['A']:<6d} B={group['B']:<5d} {group['group']}")


# --------------------------------------------------------------------------------------
# Apply / restore
# --------------------------------------------------------------------------------------

def running_app_processes():
    """Return matching process descriptions; raise RuntimeError when listing fails."""
    own = {os.getpid(), os.getppid()}
    found = {}
    combined = re.compile("|".join(APP_PROCESS_PATTERNS))
    for pattern in APP_PROCESS_PATTERNS:
        proc = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
        if proc.returncode not in (0, 1):
            raise RuntimeError(f"pgrep failed: {proc.stderr.strip()}")
        for line in proc.stdout.split():
            if line.isdigit() and int(line) not in own:
                found.setdefault(int(line), f"pgrep -f {pattern}")
    # pgrep -f can miss processes whose arguments it cannot read; cross-check with ps.
    proc = subprocess.run(["ps", "-axww", "-o", "pid=,comm=,args="], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ps failed: {proc.stderr.strip()}")
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and int(parts[0]) not in own and combined.search(parts[1]):
            found[int(parts[0])] = parts[1][:160]
    return [f"{pid}: {desc}" for pid, desc in sorted(found.items())]


def refuse_if_app_running(process_check):
    try:
        running = process_check()
    except RuntimeError as error:
        raise SystemExit(f"refusing: cannot verify that RepoPrompt CE is quit ({error})")
    if running:
        listing = "\n  ".join(running[:20])
        raise SystemExit(f"refusing: RepoPrompt CE / repoprompt-mcp processes are running:\n  {listing}\nQuit them and retry.")


def _errno_name(error: OSError) -> str:
    return errno.errorcode.get(error.errno, str(error.errno)) if error.errno is not None else "unknown"


def _is_real_dir(path: str) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _fsync_dir(path: str) -> None:
    """Best-effort fsync of a directory so renames/creations in it are durable."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _journal_append(handle, record, sync: bool) -> None:
    handle.write(json.dumps(record) + "\n")
    handle.flush()
    if sync:
        os.fsync(handle.fileno())


class _SimulatedCrash(BaseException):
    """Self-test only: simulates the process dying at an injected point (not caught as Exception)."""


class _ExclusiveLock:
    """Non-blocking exclusive flock on <app-support>/.rpce-quarantine.lock (never unlinked)."""

    def __init__(self, app_support: str):
        self.path = os.path.join(app_support, LOCK_NAME)
        self.fd = None

    def __enter__(self):
        try:
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError as error:
            raise SystemExit(f"refusing: cannot open lock file {self.path}: {error}")
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise SystemExit(f"refusing: lock file {self.path} is not a regular file")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            os.close(fd)
            if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                raise SystemExit(f"refusing: another quarantine run holds the lock {self.path}")
            raise SystemExit(f"refusing: cannot lock {self.path}: {error}")
        except BaseException:
            os.close(fd)
            raise
        self.fd = fd
        return self

    def __exit__(self, *exc_info):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = None
        return False


def _reference_fingerprint(hard, stores):
    ids = tuple(sorted((workspace_id, tuple(sorted(kinds))) for workspace_id, kinds in hard.items()))
    return ids, tuple(sorted(json.dumps(store, sort_keys=True) for store in stores))


class _RunGuard:
    """Process exclusion and reference-set stability, checked at start and periodically."""

    def __init__(self, app_support, workspaces_dir, process_check, check_every, check_seconds, hooks):
        self.app_support = app_support
        self.workspaces_dir = workspaces_dir
        self.process_check = process_check
        self.check_every = check_every
        self.check_seconds = check_seconds
        self.hooks = hooks
        self.baseline = None
        self.last_count = 0
        self.last_time = 0.0
        self.checks = 0
        self.detail = None

    def start(self):
        refuse_if_app_running(self.process_check)
        hard, soft, stores = collect_references(self.app_support, self.workspaces_dir)
        self.baseline = _reference_fingerprint(hard, stores)
        self.last_count, self.last_time = 0, time.monotonic()
        return hard, soft

    def poll(self, count: int):
        """Run the periodic check when due (every check_every moves or check_seconds); return a stop reason or None."""
        if count - self.last_count < self.check_every and time.monotonic() - self.last_time < self.check_seconds:
            return None
        self.last_count = count
        self.checks += 1
        try:
            hook = self.hooks.get("periodic_check")
            if hook:
                hook(count)
            try:
                if self.process_check():
                    return "stopped_app_started"
            except RuntimeError as error:
                self.detail = str(error)
                return "stopped_process_check_failed"
            try:
                hard, _, stores = collect_references(self.app_support, self.workspaces_dir)
            except ReferenceStoreError as error:
                self.detail = str(error)
                return "stopped_reference_store_error"
            if _reference_fingerprint(hard, stores) != self.baseline:
                return "stopped_references_changed"
            return None
        finally:
            self.last_time = time.monotonic()


def run_apply(app_support, manifest_path, classes, process_check=running_app_processes, quiet=False,
              check_every=CHECK_EVERY_MOVES, check_seconds=CHECK_EVERY_SECONDS, hooks=None):
    hooks = hooks or {}
    app_support = os.path.abspath(app_support)
    workspaces_dir = os.path.join(app_support, "Workspaces")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise SystemExit("refusing: unknown manifest schema")
    if os.path.abspath(manifest.get("appSupport", "")) != app_support:
        raise SystemExit(f"refusing: manifest is for {manifest.get('appSupport')!r}, not {app_support!r}")
    rename = hooks.get("rename", os.rename)
    with _ExclusiveLock(app_support):
        guard = _RunGuard(app_support, workspaces_dir, process_check, check_every, check_seconds, hooks)
        hard, soft = guard.start()
        stamp = hooks.get("stamp") or _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        quarantine_dir = os.path.join(app_support, f"Workspaces-Quarantine-{stamp}")
        os.mkdir(quarantine_dir)  # FileExistsError aborts; never reuses a quarantine directory
        if os.stat(quarantine_dir).st_dev != os.stat(workspaces_dir).st_dev:
            os.rmdir(quarantine_dir)
            raise SystemExit("refusing: quarantine directory is on a different volume")
        restore_path = os.path.join(quarantine_dir, "restore-manifest.jsonl")
        moved, skipped, stopped = 0, collections.Counter(), None
        now_ns = time.time_ns()
        with open(restore_path, "x", encoding="utf-8") as journal:
            _journal_append(journal, {
                "schema": RESTORE_SCHEMA, "appSupport": app_support, "workspacesDir": workspaces_dir,
                "quarantineDir": quarantine_dir, "sourceManifest": os.path.abspath(manifest_path),
                "classes": sorted(classes), "startedAt": stamp,
            }, sync=True)
            _fsync_dir(quarantine_dir)
            for candidate in manifest.get("candidates", []):
                if candidate.get("class") not in classes:
                    continue
                dir_name = candidate.get("dir", "")
                if not isinstance(dir_name, str) or os.path.basename(dir_name) != dir_name or not dir_name.startswith(DIR_PREFIX):
                    skipped["invalid_manifest_entry"] += 1
                    continue
                stopped = guard.poll(moved)
                if stopped:
                    skipped[stopped] += 1
                    break
                fresh = classify(workspaces_dir, dir_name, now_ns, hard, soft)
                if fresh["class"] is None:
                    skipped["revalidation:" + str(fresh["reason"])] += 1
                    continue
                if fresh["class"] != candidate["class"] or fresh["files"] != candidate.get("files"):
                    skipped["revalidation:changed_since_manifest"] += 1
                    continue
                source = os.path.join(workspaces_dir, dir_name)
                target = os.path.join(quarantine_dir, dir_name)
                if os.path.lexists(target):
                    skipped["target_exists"] += 1
                    continue
                try:
                    # Write-ahead: the intent is durable before the rename can happen.
                    _journal_append(journal, {
                        "dir": dir_name, "class": fresh["class"], "from": source, "to": target,
                        "files": fresh["files"], "state": "moving", "intentAtNs": time.time_ns(),
                    }, sync=True)
                except OSError as error:
                    stopped = f"stopped_journal_write_failed:{_errno_name(error)}"
                    skipped[stopped] += 1
                    break
                if "after_intent" in hooks:
                    hooks["after_intent"](dir_name)
                try:
                    rename(source, target)
                except OSError as error:
                    code = _errno_name(error)
                    skipped[f"rename_failed:{code}"] += 1
                    try:
                        _journal_append(journal, {"dir": dir_name, "state": "failed", "errno": code}, sync=False)
                    except OSError as journal_error:
                        stopped = f"stopped_journal_write_failed:{_errno_name(journal_error)}"
                        skipped[stopped] += 1
                        break
                    continue
                moved += 1
                if "after_rename" in hooks:
                    hooks["after_rename"](dir_name)
                try:
                    _journal_append(journal, {"dir": dir_name, "state": "moved", "movedAtNs": time.time_ns()}, sync=False)
                except OSError as error:
                    stopped = f"stopped_journal_write_failed:{_errno_name(error)}"
                    skipped[stopped] += 1
                    break
            try:
                journal.flush()
                os.fsync(journal.fileno())
            except OSError as error:
                skipped[f"final_journal_fsync_failed:{_errno_name(error)}"] += 1
        _fsync_dir(quarantine_dir)
        _fsync_dir(workspaces_dir)
        result = {"quarantineDir": quarantine_dir, "restoreManifest": restore_path, "moved": moved,
                  "skipped": dict(skipped), "stopped": stopped, "periodicChecks": guard.checks}
        if guard.detail:
            result["stopDetail"] = guard.detail
        _atomic_write_json(os.path.join(quarantine_dir, "apply-summary.json"), result)
    if stopped and not quiet:
        print(f"stopping early ({stopped}); everything moved so far is journaled in {restore_path}", file=sys.stderr)
    if not quiet:
        print(json.dumps(result, indent=1))
    return result


def _read_journal(restore_path: str):
    """Return (records, bad_trailing). A corrupt final line is skipped and reported; any other corrupt line refuses."""
    with open(restore_path, "rb") as handle:
        raw = handle.read()
    lines = [(number, line) for number, line in enumerate(raw.split(b"\n"), 1) if line.strip()]
    records, bad_trailing = [], None
    for position, (number, line) in enumerate(lines):
        try:
            record = json.loads(line.decode("utf-8"))
            if not isinstance(record, dict):
                raise ValueError("not an object")
        except (UnicodeDecodeError, ValueError) as error:
            if position == len(lines) - 1 and position > 0:
                bad_trailing = {"line": number, "bytes": len(line), "error": str(error)[:120]}
                break
            raise SystemExit(f"refusing: restore manifest line {number} is corrupt and is not the trailing line ({error})")
        records.append(record)
    return records, bad_trailing


def _journal_entries(records, skipped):
    """Fold intent/moved/failed records (and legacy post-rename records) into per-dir entries, in order."""
    entries, order = {}, []
    for record in records:
        dir_name, state = record.get("dir"), record.get("state")
        if not isinstance(dir_name, str):
            skipped["invalid_record"] += 1
            continue
        is_legacy = state is None and "from" in record and "to" in record
        if state == "moving" or is_legacy:
            if not isinstance(record.get("from"), str) or not isinstance(record.get("to"), str):
                skipped["invalid_record"] += 1
                continue
            if dir_name not in entries:
                order.append(dir_name)
            entries[dir_name] = {"record": record, "state": "moved" if is_legacy else "moving"}
        elif state in ("moved", "failed"):
            if dir_name in entries:
                entries[dir_name]["state"] = state
            else:
                skipped["orphan_record"] += 1
        else:
            skipped["invalid_record"] += 1
    return entries, order


def run_restore(restore_path, process_check=running_app_processes, quiet=False,
                check_every=CHECK_EVERY_MOVES, check_seconds=CHECK_EVERY_SECONDS, hooks=None):
    hooks = hooks or {}
    records, bad_trailing = _read_journal(restore_path)
    if not records or records[0].get("schema") != RESTORE_SCHEMA:
        raise SystemExit("refusing: unknown restore manifest schema")
    header = records[0]
    if not all(isinstance(header.get(key), str) for key in ("appSupport", "workspacesDir", "quarantineDir")):
        raise SystemExit("refusing: restore manifest header is incomplete")
    app_support = os.path.abspath(header["appSupport"])
    workspaces_dir = os.path.abspath(header["workspacesDir"])
    quarantine_dir = os.path.abspath(header["quarantineDir"])
    if workspaces_dir != os.path.join(app_support, "Workspaces") or os.path.dirname(quarantine_dir) != app_support:
        raise SystemExit("refusing: restore manifest header paths are inconsistent")
    if os.path.dirname(os.path.abspath(restore_path)) != quarantine_dir:
        raise SystemExit("refusing: restore manifest is not inside its quarantine directory")
    skipped = collections.Counter()
    entries, order = _journal_entries(records[1:], skipped)
    if bad_trailing and not quiet:
        print(f"warning: skipped a truncated/corrupt trailing line in {restore_path}: {bad_trailing}", file=sys.stderr)
    rename = hooks.get("rename", os.rename)
    restored, reconciled, changed, stopped = 0, 0, [], None
    with _ExclusiveLock(app_support):
        guard = _RunGuard(app_support, workspaces_dir, process_check, check_every, check_seconds, hooks)
        guard.start()
        for dir_name in order:
            entry = entries[dir_name]
            record, state = entry["record"], entry["state"]
            source, target = os.path.abspath(record["to"]), os.path.abspath(record["from"])
            if (os.path.dirname(source) != quarantine_dir or os.path.dirname(target) != workspaces_dir
                    or os.path.basename(source) != dir_name or os.path.basename(target) != dir_name):
                skipped["path_outside_stores"] += 1
                continue
            if os.path.lexists(target):
                # Intent-only/failed entries whose origin is still in place were never moved.
                skipped["destination_exists" if state == "moved" or os.path.lexists(source) else "not_moved"] += 1
                continue
            if not _is_real_dir(source):
                skipped["quarantined_entry_missing"] += 1
                continue
            stopped = guard.poll(restored)
            if stopped:
                skipped[stopped] += 1
                break
            try:
                rename(source, target)
            except OSError as error:
                skipped[f"rename_failed:{_errno_name(error)}"] += 1
                continue
            restored += 1
            if state != "moved":
                reconciled += 1
            try:
                tree, _ = scan_tree(target)
                if [item[:4] for item in tree] != record.get("files"):
                    changed.append(dir_name)
            except OSError:
                changed.append(dir_name)
        _fsync_dir(workspaces_dir)
    result = {"restored": restored, "reconciledInterrupted": reconciled, "skipped": dict(skipped),
              "changedWhileQuarantined": changed[:50], "changedCount": len(changed),
              "truncatedTrailingLine": bad_trailing, "stopped": stopped, "periodicChecks": guard.checks}
    if guard.detail:
        result["stopDetail"] = guard.detail
    if stopped and not quiet:
        print(f"stopping early ({stopped}); re-run --restore after fixing the cause", file=sys.stderr)
    if not quiet:
        print(json.dumps(result, indent=1))
    return result


# --------------------------------------------------------------------------------------
# Self-test (temporary fake store only)
# --------------------------------------------------------------------------------------

class SelfTestFailure(Exception):
    """Raised by _check; unlike assert, it is not stripped by python3 -O."""


def _check(condition, message="self-test check failed") -> None:
    if not condition:
        raise SelfTestFailure(message)


def _expect_raises(exc_types, func, message):
    try:
        func()
    except exc_types as error:
        return error
    raise SelfTestFailure(message)


def _self_test() -> int:
    old_ns = time.time_ns() - 3 * MIN_AGE_NS
    empty_index = {"generatedAt": 813960026.5, "quarantinedFiles": [], "schemaVersion": 7, "lastReconciledAt": 813960026.5, "entries": []}

    def uid(n):
        return f"{n:08X}-0000-4000-8000-{n:012X}"

    with tempfile.TemporaryDirectory(prefix="rpce-quarantine-selftest-") as tmp:
        app = os.path.join(tmp, "RepoPrompt CE")
        ws = os.path.join(app, "Workspaces")
        os.makedirs(ws)
        layouts = {}

        def make(name, files, dirs=(), recent=False):
            root = os.path.join(ws, name)
            os.makedirs(root)
            for d in dirs:
                os.makedirs(os.path.join(root, d), exist_ok=True)
            for rel, payload in files.items():
                os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
                with open(os.path.join(root, rel), "w", encoding="utf-8") as handle:
                    handle.write(payload if isinstance(payload, str) else json.dumps(payload))
            if not recent:
                for current, _, names in os.walk(root, topdown=False):
                    for n in names:
                        os.utime(os.path.join(current, n), ns=(old_ns, old_ns))
                    os.utime(current, ns=(old_ns, old_ns))
            layouts[name] = root
            return name

        idx = {INDEX_REL: empty_index}
        a1 = make(f"Workspace-Request Idempotency E7677C37-{uid(1)}", idx, ("Chats",))
        a2 = make(f"Workspace-Default-{uid(2)}", idx)
        a3 = make(f"Workspace-Lookup-{uid(3)}", idx, ("Chats", "_git_data"))
        make(f"Workspace-DSStore-{uid(4)}", {**idx, "Chats/.DS_Store": "x"})
        make(f"Workspace-Recent-{uid(5)}", idx, ("Chats",), recent=True)
        make(f"Workspace-NonEmpty-{uid(6)}", {INDEX_REL: {**empty_index, "entries": [{}]}})
        make(f"Workspace-Session-{uid(7)}", {**idx, f"AgentSessions/AgentSession-{uid(70)}.json": "{}"})
        make(f"Workspace-Referenced-{uid(8)}", idx)
        make(f"Workspace-Partitioned-{uid(9)}", idx)
        make("Workspace-NoUUID", idx)
        b_name = "Agent Mode Chat Switch 07A925F5"
        b1 = make(f"Workspace-{b_name}-{uid(10)}", {**idx, WORKSPACE_JSON: {"id": uid(10), "name": b_name, "ephemeralFlag": True, "isSystemWorkspace": False, "repoPaths": []}}, ("Chats", "_git_data"))
        make(f"Workspace-Wrong Name-{uid(11)}", {WORKSPACE_JSON: {"id": uid(11), "name": "Other", "ephemeralFlag": True, "isSystemWorkspace": False}})
        make(f"Workspace-Real-{uid(12)}", {**idx, WORKSPACE_JSON: {"id": uid(12), "name": "Real", "ephemeralFlag": False, "isSystemWorkspace": False}})
        make(f"Workspace-Soft-{uid(13)}", idx)
        with open(os.path.join(ws, "workspacesIndex.json"), "w") as handle:
            json.dump([{"id": uid(8), "name": "Referenced", "isSystemWorkspace": False, "isHiddenInMenus": False}], handle)
        with open(os.path.join(app, "windowSessions.json"), "w") as handle:
            json.dump({"version": 4, "windows": [{"windowKind": "standard", "workspaceID": uid(12), "isSystemWorkspace": False, "isEphemeral": False, "lastFocused": True}]}, handle)
        os.makedirs(os.path.join(app, "Partitions", "repo-abc"))
        open(os.path.join(app, "Partitions", "repo-abc", f"filepartitions-{uid(9).lower()}.json"), "w").close()
        os.makedirs(os.path.join(app, "Settings"))
        with open(os.path.join(app, "Settings", "globalSettings.json"), "w") as handle:
            json.dump({"schemaVersion": 5, "schemaLineage": GLOBAL_SETTINGS_LINEAGE, "updatedAt": 1.0, "copySettingsByWorkspaceID": {uid(13): {}}, "chatSettingsByWorkspaceID": {}, "globalDefaults": {}}, handle)

        manifest_path = os.path.join(tmp, "manifest.json")
        manifest = run_dry(app, manifest_path, quiet=True)
        got = {c["dir"]: c["class"] for c in manifest["candidates"]}
        reasons = {e["dir"]: e["reason"] for e in manifest["excluded"]}
        expected = {a1: "A", a2: "A", a3: "A", b1: "B", f"Workspace-Soft-{uid(13)}": "A"}
        _check(got == expected, (got, reasons))
        _check(reasons[f"Workspace-DSStore-{uid(4)}"] == "chats_not_empty", reasons)
        _check(reasons[f"Workspace-Recent-{uid(5)}"] == "too_recent", reasons)
        _check(reasons[f"Workspace-NonEmpty-{uid(6)}"] == "index_not_empty", reasons)
        _check(reasons[f"Workspace-Session-{uid(7)}"] == "has_agent_sessions", reasons)
        _check(reasons[f"Workspace-Referenced-{uid(8)}"] == "referenced", reasons)
        _check(reasons[f"Workspace-Partitioned-{uid(9)}"] == "referenced", reasons)
        _check(reasons["Workspace-NoUUID"] == "name_unparsed", reasons)
        _check(reasons[f"Workspace-Wrong Name-{uid(11)}"] == "workspace_identity_mismatch", reasons)
        _check(reasons[f"Workspace-Real-{uid(12)}"] == "referenced", reasons)
        _check(reasons["workspacesIndex.json"] == "not_directory", reasons)
        soft_flag = [c for c in manifest["candidates"] if c["softReferences"]]
        _check([c["workspaceID"] for c in soft_flag] == [uid(13)], soft_flag)
        _check(parse_dir_name(f"Workspace-a-b-{uid(1)}") == ("a-b", uid(1)), "parse_dir_name a-b")
        _check(parse_dir_name(f"Workspace--{uid(1)}") == (f"Workspace--{uid(1)}", uid(1)), "parse_dir_name empty name")
        _check(name_group("List Sessions 5D314EF2") == "List Sessions", "name_group")
        process_re = re.compile("|".join(APP_PROCESS_PATTERNS))
        for line in ("/Users/x/repo/.build/arm64-apple-macosx/debug/RepoPrompt",
                     "/Users/x/repo/.build/debug/RepoPrompt --flag",
                     "/usr/bin/swift-run RepoPrompt",
                     "/x/swiftpm-testing-helper --test-bundle-path RepoPromptPackageTests.xctest/Contents/MacOS/RepoPromptPackageTests"):
            _check(process_re.search(line) is not None, f"process pattern missed {line!r}")
        _check(process_re.search("/Users/x/repo/.build/debug/RepoPromptCore.swiftmodule") is None, "process pattern overmatched")

        no_proc = lambda: []  # noqa: E731
        counter = [0]

        def stamp():
            counter[0] += 1
            return f"selftest-{counter[0]:03d}"

        def quarantine_dirs():
            return sorted(n for n in os.listdir(app) if n.startswith("Workspaces-Quarantine-"))

        def qpaths(stamp_value):
            qdir = os.path.join(app, f"Workspaces-Quarantine-{stamp_value}")
            return os.path.join(qdir, "restore-manifest.jsonl"), os.path.join(qdir, "apply-summary.json")

        def journal_states(path):
            with open(path, encoding="utf-8") as handle:
                return [json.loads(line).get("state") for line in handle.read().splitlines()[1:]]

        def fresh_a():
            names = sorted(c["dir"] for c in run_dry(app, manifest_path, quiet=True)["candidates"] if c["class"] == "A")
            _check(len(names) == 3, names)
            _check(all_in_place(names), names)
            return names

        def all_in_place(names):
            return all(_is_real_dir(os.path.join(ws, n)) for n in names)

        def apply_a(stamp_value, **kwargs):
            kwargs.setdefault("process_check", no_proc)
            hooks = kwargs.pop("hooks", {})
            hooks["stamp"] = stamp_value
            return run_apply(app, manifest_path, {"A"}, quiet=True, hooks=hooks, **kwargs)

        def restore(path, **kwargs):
            kwargs.setdefault("process_check", no_proc)
            return run_restore(path, quiet=True, **kwargs)

        # Refusal when an app process is reported.
        _expect_raises(SystemExit, lambda: apply_a(stamp(), process_check=lambda: ["1: RepoPrompt"]),
                       "apply did not refuse while app is running")
        _check(not quarantine_dirs(), quarantine_dirs())

        # A candidate modified after the manifest is not moved.
        with open(os.path.join(layouts[a2], "Chats-extra"), "w"):
            pass
        result = apply_a(stamp())
        _check(result["moved"] == 3 and result["stopped"] is None and result["periodicChecks"] == 0, result)
        _check(os.path.isdir(layouts[a2]) and os.path.isdir(layouts[b1]), "unmoved dirs missing")
        _check(not os.path.exists(layouts[a1]), "a1 not moved")
        _check(journal_states(result["restoreManifest"]) == ["moving", "moved"] * 3, journal_states(result["restoreManifest"]))
        restored = restore(result["restoreManifest"])
        _check(restored["restored"] == 3 and restored["changedCount"] == 0 and restored["truncatedTrailingLine"] is None, restored)
        _check(os.path.isdir(layouts[a1]) and os.path.isdir(layouts[a3]), "restore incomplete")

        # Restore refuses when the destination exists again.
        result = run_apply(app, manifest_path, {"B"}, process_check=no_proc, quiet=True, hooks={"stamp": stamp()})
        _check(result["moved"] == 1, result)
        os.makedirs(layouts[b1])
        restored = restore(result["restoreManifest"])
        _check(restored["restored"] == 0 and restored["skipped"] == {"destination_exists": 1}, restored)

        # Interruption between the fsynced intent and the rename: the second entry was never moved.
        names = fresh_a()
        s = stamp()
        seen = []

        def crash_before_rename(dir_name):
            seen.append(dir_name)
            if len(seen) == 2:
                raise _SimulatedCrash()

        _expect_raises(_SimulatedCrash, lambda: apply_a(s, hooks={"after_intent": crash_before_rename}), "intent crash not raised")
        journal, summary_path = qpaths(s)
        _check(not os.path.exists(summary_path), "summary written despite crash")
        _check(not os.path.lexists(os.path.join(ws, names[0])) and all_in_place(names[1:]), "unexpected moves before crash")
        _check(journal_states(journal) == ["moving", "moved", "moving"], journal_states(journal))
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["reconciledInterrupted"] == 0 and restored["skipped"] == {"not_moved": 1}, restored)
        _check(all_in_place(names), "intent-crash restore incomplete")

        # Interruption between the rename and its "moved" record: reconciled from the intent alone.
        names = fresh_a()
        s = stamp()
        seen.clear()
        _expect_raises(_SimulatedCrash, lambda: apply_a(s, hooks={"after_rename": crash_before_rename}), "rename crash not raised")
        journal, summary_path = qpaths(s)
        _check(not os.path.exists(summary_path), "summary written despite crash")
        _check(journal_states(journal) == ["moving", "moved", "moving"], journal_states(journal))
        _check(not os.path.lexists(os.path.join(ws, names[1])), "second entry not renamed")
        restored = restore(journal)
        _check(restored["restored"] == 2 and restored["reconciledInterrupted"] == 1 and restored["skipped"] == {}, restored)
        _check(all_in_place(names), "rename-crash restore incomplete")

        # Per-entry rename failure (apply and restore) is counted, does not abort, and keeps the summary.
        names = fresh_a()
        s = stamp()

        def failing_rename_for(victim):
            def rename(src, dst):
                if os.path.basename(src) == victim:
                    raise OSError(errno.EACCES, "injected failure", src)
                os.rename(src, dst)
            return rename

        result = apply_a(s, hooks={"rename": failing_rename_for(names[1])})
        journal, summary_path = qpaths(s)
        _check(result["moved"] == 2 and result["skipped"] == {"rename_failed:EACCES": 1} and result["stopped"] is None, result)
        _check(os.path.isfile(summary_path), "apply-summary.json missing after rename failure")
        _check(journal_states(journal) == ["moving", "moved", "moving", "failed", "moving", "moved"], journal_states(journal))
        restored = restore(journal, hooks={"rename": failing_rename_for(names[0])})
        _check(restored["restored"] == 1 and restored["skipped"] == {"rename_failed:EACCES": 1, "not_moved": 1}, restored)
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["skipped"] == {"not_moved": 1, "destination_exists": 1}, restored)
        _check(all_in_place(names), "rename-failure restore incomplete")

        # A truncated trailing journal line is skipped and reported without losing earlier entries.
        names = fresh_a()
        s = stamp()
        result = apply_a(s)
        journal, _ = qpaths(s)
        with open(journal, "a", encoding="utf-8") as handle:
            handle.write('{"dir": "Workspace-Trunc')
        restored = restore(journal)
        _check(restored["restored"] == 3 and restored["skipped"] == {} and restored["truncatedTrailingLine"] is not None, restored)
        _check(all_in_place(names), "truncated-journal restore incomplete")

        # A corrupt line that is not the trailing line refuses the whole restore.
        names = fresh_a()
        s = stamp()
        apply_a(s)
        journal, _ = qpaths(s)
        with open(journal, encoding="utf-8") as handle:
            lines = handle.read().splitlines(True)
        with open(journal, "w", encoding="utf-8") as handle:
            handle.writelines(lines[:2] + ["{corrupt\n"] + lines[2:])
        _expect_raises(SystemExit, lambda: restore(journal), "mid-file corruption accepted")
        _check(not any(os.path.lexists(os.path.join(ws, n)) for n in names), "restore ran despite corruption")
        with open(journal, "w", encoding="utf-8") as handle:
            handle.writelines(lines)
        _check(restore(journal)["restored"] == 3, "repaired journal did not restore")

        # Lock contention: a second run refuses while the lock is held.
        names = fresh_a()
        before = quarantine_dirs()
        with _ExclusiveLock(app):
            error = _expect_raises(SystemExit, lambda: apply_a(stamp()), "apply ran despite held lock")
            _check("lock" in str(error), str(error))
            error = _expect_raises(SystemExit, lambda: restore(journal), "restore ran despite held lock")
            _check("lock" in str(error), str(error))
        _check(quarantine_dirs() == before and all_in_place(names), "lock contention mutated the store")

        # Reference-set change mid-run stops apply cleanly (summary written, journal restorable).
        names = fresh_a()
        s = stamp()
        index_path = os.path.join(ws, "workspacesIndex.json")
        with open(index_path, encoding="utf-8") as handle:
            original_index = handle.read()

        def add_reference(_count):
            entries = json.loads(original_index)
            entries.append({"id": uid(99), "name": "New", "isSystemWorkspace": False, "isHiddenInMenus": False})
            with open(index_path, "w", encoding="utf-8") as handle:
                json.dump(entries, handle)

        result = apply_a(s, check_every=1, hooks={"periodic_check": add_reference})
        journal, summary_path = qpaths(s)
        _check(result["moved"] == 1 and result["stopped"] == "stopped_references_changed"
               and result["skipped"] == {"stopped_references_changed": 1} and result["periodicChecks"] == 1, result)
        _check(os.path.isfile(summary_path), "apply-summary.json missing after reference change")
        with open(index_path, "w", encoding="utf-8") as handle:
            handle.write(original_index)
        _check(restore(journal)["restored"] == 1 and all_in_place(names), "reference-change restore incomplete")

        # A process appearing mid-run stops apply at the next periodic check; restore also stops on reference change.
        names = fresh_a()
        s = stamp()
        calls = [0]

        def process_appears():
            calls[0] += 1
            return [] if calls[0] <= 2 else ["4242: /Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt CE"]

        result = apply_a(s, check_every=1, process_check=process_appears)
        journal, _ = qpaths(s)
        _check(result["moved"] == 2 and result["stopped"] == "stopped_app_started" and result["periodicChecks"] == 2, result)
        restored = restore(journal, check_every=1, hooks={"periodic_check": add_reference})
        _check(restored["restored"] == 1 and restored["stopped"] == "stopped_references_changed", restored)
        with open(index_path, "w", encoding="utf-8") as handle:
            handle.write(original_index)
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["skipped"] == {"destination_exists": 1}, restored)
        _check(all_in_place(names), "process-start restore incomplete")

        # Malformed reference containers fail closed instead of reading as empty.
        elsewhere = os.path.join(tmp, "elsewhere")
        os.makedirs(elsewhere)
        missing = os.path.join(tmp, "missing")
        mcp, recovery = os.path.join(app, "MCP"), os.path.join(app, "AgentRecovery")
        partitions, settings = os.path.join(app, "Partitions"), os.path.join(app, "Settings")

        def write_file(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{}")

        def swap_aside(path, replacement):
            def setup():
                os.rename(path, path + ".bak")
                replacement()
            def teardown():
                os.remove(path)
                os.rename(path + ".bak", path)
            return setup, teardown

        cases = [
            ("MCP regular file", lambda: write_file(mcp), lambda: os.remove(mcp)),
            ("MCP dangling symlink", lambda: os.symlink(missing, mcp), lambda: os.remove(mcp)),
            ("MCP symlink to directory", lambda: os.symlink(elsewhere, mcp), lambda: os.remove(mcp)),
            ("AgentRecovery dangling symlink", lambda: os.symlink(missing, recovery), lambda: os.remove(recovery)),
            ("AgentRecovery/v1 regular file", lambda: write_file(os.path.join(recovery, "v1")), lambda: shutil.rmtree(recovery)),
            ("AgentRecovery/v1/sessions regular file", lambda: write_file(os.path.join(recovery, "v1", "sessions")), lambda: shutil.rmtree(recovery)),
            ("AgentRecovery attachment symlink", lambda: (os.makedirs(os.path.join(recovery, "v1", "attachments")),
                                                          os.symlink(elsewhere, os.path.join(recovery, "v1", "attachments", uid(50)))),
             lambda: shutil.rmtree(recovery)),
            ("Partitions dangling symlink", *swap_aside(partitions, lambda: os.symlink(missing, partitions))),
            ("Partitions symlink to directory", *swap_aside(partitions, lambda: os.symlink(partitions + ".bak", partitions))),
            ("Settings regular file", *swap_aside(settings, lambda: write_file(settings))),
        ]
        if os.geteuid() != 0:
            cases.append(("MCP unreadable", lambda: (os.mkdir(mcp), os.chmod(mcp, 0)),
                          lambda: (os.chmod(mcp, 0o700), os.rmdir(mcp))))
        for label, setup, teardown in cases:
            setup()
            try:
                _expect_raises(ReferenceStoreError, lambda: run_dry(app, manifest_path, quiet=True),
                               f"dry run accepted malformed container: {label}")
            finally:
                teardown()
        fresh_a()  # store is valid again after every teardown

        # Unknown reference-store schema fails closed.
        with open(os.path.join(app, "windowSessions.json"), "w") as handle:
            json.dump({"version": 99, "windows": []}, handle)
        _expect_raises(ReferenceStoreError, lambda: run_dry(app, manifest_path, quiet=True), "dry run did not fail closed")
        # Manifest inside app support is refused.
        _expect_raises((SystemExit, ReferenceStoreError), lambda: run_dry(app, os.path.join(app, "m.json"), quiet=True),
                       "manifest inside app support accepted")
    print(f"self-test passed ({len(cases)} malformed-container cases)")
    return 0


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="scan and write a manifest (default)")
    mode.add_argument("--apply", action="store_true", help="move manifest candidates of --class into quarantine")
    mode.add_argument("--restore", metavar="RESTORE_MANIFEST", help="move entries of a restore-manifest.jsonl back")
    mode.add_argument("--self-test", action="store_true", help="run the built-in self-test on a temporary store")
    parser.add_argument("--manifest", help="dry-run output / apply input manifest path")
    parser.add_argument("--class", dest="classes", action="append", choices=("A", "B"),
                        help="apply only: candidate class to move (repeatable; required)")
    parser.add_argument("--app-support", default=DEFAULT_APP_SUPPORT, help="RepoPrompt CE app-support root")
    args = parser.parse_args(argv)

    if args.self_test:
        try:
            return _self_test()
        except SelfTestFailure as error:
            print(f"self-test FAILED: {error}", file=sys.stderr)
            return 1
    try:
        if args.restore:
            return 3 if run_restore(args.restore)["stopped"] else 0
        if args.apply:
            if not args.manifest or not args.classes:
                parser.error("--apply requires --manifest and at least one --class")
            return 3 if run_apply(args.app_support, args.manifest, set(args.classes))["stopped"] else 0
        manifest = args.manifest or os.path.join(
            tempfile.gettempdir(),
            "rpce-fixture-quarantine-" + _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json",
        )
        run_dry(args.app_support, manifest)
        return 0
    except ReferenceStoreError as error:
        print(f"aborting (fail closed): {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
