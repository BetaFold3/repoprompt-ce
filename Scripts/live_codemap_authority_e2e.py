#!/usr/bin/env python3
"""One-shot codemap authority E2E against an ALREADY RUNNING CE DEBUG app.

Explicit invocation only:
  python3 Scripts/live_codemap_authority_e2e.py --confirm-isolated-fixtures \
    --window-id W --context-id UUID --app-pid PID

Five independent lanes; first failures stay failures. --churn and --cadence
add 20 paired root/.git directory changes and a 60-second/two-second LOCK-FREE
Git-status cadence, not the separate ordinary/default-status baseline.
Requires Python 3, git, gitleaks >= 8.19 (dir command), xcrun swiftc, and rpce-cli-debug.
Every demand must finish UNDER 10 seconds measured CLI-inclusive (startup,
bind_context, server, transport); the original server deadline is unchanged.
No app lifecycle, agents, settings mutations, existing workspace switches,
cleanup, or product Git mutations. Raw evidence/workspaces are retained.
This focused reproduction is NOT the packaged-app codemap release gate.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

import worktree_startup_live_benchmark as bench

TIMEOUT = 20
PAYLOAD = "struct ControlPayload {\n    let identifier: Int\n    func controlLabel() -> String { \"payload-\\(identifier)\" }\n}\n"
CONSUMER = "struct ControlConsumer {\n    let payload: ControlPayload\n    func consumeControl(_ value: ControlPayload) -> String { value.controlLabel() }\n}\n"
ADDED = "struct ControlAuthorityAdded {\n    let payload: ControlPayload\n    func authorityAddedLabel() -> String { payload.controlLabel() }\n}\n"
BASE = {"ControlPayload.swift": ("ControlPayload", "func controlLabel("),
        "ControlConsumer.swift": ("ControlConsumer", "func consumeControl(")}
THIRD = {"ControlAuthorityAdded.swift": ("ControlAuthorityAdded", "func authorityAddedLabel(")}
LANES = ("index-only", "catalog-only", "metadata-only", "separated-combined", "original-overlap")
STAT_FIELDS = ("dev", "ino", "mode", "size", "mtime_ns", "ctime_ns")
COUNTER_FIELDS = ("capability_resolutions", "repository_authority_changes", "store_root_session_repairs")
ROOT_COUNTER_FIELDS = ("root_capability_resolutions", "root_repository_authority_changes", "root_store_session_repairs")


def stamp():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tool_ok(value):
    """Also reject exit-zero CLI errors, including JSON inside MCP text blocks."""
    return all(not (item.get("isError") is True or item.get("is_error") is True
                    or item.get("ok") is False or item.get("error"))
               for item in bench.structured_json_objects(value))


def validate_structure(value, root, expected, related, elapsed):
    if not tool_ok(value):
        raise ValueError("CLI/tool error, regardless of process exit code")
    record = bench.tool_payload(value, "get_code_structure")
    if record.get("status") != "ready" or record.get("issues") != [] or record.get("retry") is not None:
        raise ValueError(f"not exact ready/empty issues: {record}")
    if elapsed >= 10:
        raise ValueError(f"not under original 10-second acceptance limit: {elapsed:.3f}s")
    if any("worktree_scope" in item for item in bench.structured_json_objects(value)):
        raise ValueError("unexpected worktree_scope")
    wanted = {f"{root.name}/{name}": symbols for name, symbols in expected.items()}
    files = record.get("files")
    if not isinstance(files, list) or len(files) != len(wanted):
        raise ValueError("wrong exact file count")
    if {item.get("path") for item in files} != set(wanted):
        raise ValueError("wrong exact logical filenames")
    for item in files:
        name = Path(item["path"]).name
        is_related = name in related
        if item.get("role") != ("related" if is_related else "seed") or item.get("depth") != int(is_related):
            raise ValueError(f"wrong relationship role/depth: {name}")
        if item.get("reached_by") != (["referrers"] if is_related else []):
            raise ValueError(f"wrong relationship direction: {name}")
        content = item.get("content")
        if not isinstance(content, str) or any(symbol not in content for symbol in wanted[item["path"]]):
            raise ValueError(f"missing expected type/method: {name}")
    return record


class Runner:
    def __init__(self, artifact, cli, window, context):
        self.artifact, self.cli = artifact, cli
        self.window, self.context = window, bench.validate_uuid(context, "context")
        self.lock = threading.Lock()
        self.ordinal = 0
        self.records = []
        self.expected_root = None
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(LC_ALL="C", GIT_OPTIONAL_LOCKS="0",
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_NAME="Fixture E2E",
                        GIT_COMMITTER_NAME="Fixture E2E", GIT_AUTHOR_EMAIL="fixture-e2e@example.invalid",
                        GIT_COMMITTER_EMAIL="fixture-e2e@example.invalid")

    def run(self, label, argv, *, timeout=TIMEOUT):
        started, tick = stamp(), time.monotonic()
        out, err, code, timed_out = b"", b"", None, False
        try:
            process = subprocess.Popen(argv, cwd=self.artifact, env=self.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                out, err = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    out, err = process.communicate(timeout=.5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    out, err = process.communicate()
            code = process.returncode
        except OSError as error:
            err = str(error).encode()
        record = dict(label=label, argv=list(map(str, argv)), command=shlex.join(map(str, argv)),
                      started_at=started, finished_at=stamp(), elapsed_seconds=time.monotonic()-tick,
                      returncode=code, timed_out=timed_out, timeout_seconds=timeout,
                      stdout=out.decode(errors="replace"), stderr=err.decode(errors="replace"))
        with self.lock:
            path = self.artifact / "raw" / f"{self.ordinal:04d}-{bench.safe_name(label)}.json"
            self.ordinal += 1
            record["raw_evidence"] = str(path)
            self.records.append(record)
            bench.save_json(path, record, exclusive=True)
        if code != 0 or timed_out:
            raise ValueError(f"{label}: subprocess failure; see {path}")
        return record

    def owned_fixture(self, root):
        if (root is None or root.parent != self.artifact/"fixtures"
                or root.is_symlink() or root.resolve() != root):
            raise ValueError("target is not a new harness-owned physical fixture")
        return root

    def check_binding(self, binding):
        if (not isinstance(binding, dict) or type(binding.get("window_id")) is not int
                or binding["window_id"] != self.window
                or not isinstance(binding.get("context_id"), str)
                or binding["context_id"].upper() != self.context.upper()):
            raise ValueError("binding does not match requested window/context")
        if self.expected_root is not None:
            roots = binding.get("repo_paths")
            if (not isinstance(roots, list) or any(not isinstance(p, str) for p in roots)
                    or [str(Path(p).resolve()) for p in roots] != [str(self.expected_root)]):
                raise ValueError("binding does not have exactly the owned fixture root")

    def check_edit_path(self, payload):
        root = self.owned_fixture(self.expected_root)
        raw_path = payload.get("path")
        if not isinstance(raw_path, str):
            raise ValueError("edit requires absolute owned physical path")
        path = Path(raw_path)
        if (not path.is_absolute() or path.parent != root or path.resolve() != path
                or path.is_symlink() or path.name != "ControlAuthorityAdded.swift"):
            raise ValueError("edit path is not the absolute owned fixture source")

    def call(self, label, tool, payload):
        routed = {**payload, "_windowID": self.window, "context_id": self.context}
        # Reuse the benchmark's atomic binding verification, but explicitly route
        # BOTH the binding and tool JSON. Never trust -w/-t alone.
        bind = {"op": "bind", "window_id": self.window, "_windowID": self.window, "context_id": self.context}
        if tool == "apply_edits":
            self.check_edit_path(routed)
            # A read-only bind preflight must succeed BEFORE any mutation is dispatched.
            preflight = self.run(label+"-write-preflight",
                                 [str(self.cli), "--raw-json", "-w", str(self.window), "-e",
                                  f"call bind_context {json.dumps(bind)}"])
            document = json.loads(preflight["stdout"])
            if not isinstance(document, dict) or not tool_ok(document):
                raise ValueError("write preflight binding failed")
            self.check_binding(document.get("binding"))
            self.check_edit_path(routed)
            # Absolute physical ownership cannot be redirected by a later root switch.
            # The tool also admits this absolute path against its CURRENT mutation scope.
        command = f"call bind_context {json.dumps(bind)} && call {tool} {json.dumps(routed)}"
        raw = self.run(label, [str(self.cli), "--raw-json", "-w", str(self.window), "-e", command])
        binding, value = bench.parse_atomic_cli_output(raw["stdout"], expected_context_id=self.context,
                                                       expected_window_id=self.window)
        self.check_binding(binding)
        if not tool_ok(value):
            raise ValueError(f"{label}: exit-zero tool error: {value}")
        return value, raw["elapsed_seconds"]

    def git(self, root, label, *args):
        self.owned_fixture(root)
        return self.run(label, ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                               "-c", "tag.gpgsign=false", "-C", str(root), *args])["stdout"]


def discover_created_context(runner, scope):
    # Explicitly approved bootstrap exception: global read-only inventory only.
    # There is no context ID to route to until the newly created window is found.
    raw = runner.run("discover-"+scope["workspace_id"], [str(runner.cli), "--raw-json", "-e", "windows"])
    listing = json.loads(raw["stdout"])
    if not tool_ok(listing) or not isinstance(listing.get("windows"), list):
        raise ValueError("invalid global window-discovery JSON")
    windows = [w for w in listing["windows"] if w.get("window_id") == scope["window_id"]]
    if len(windows) != 1:
        raise ValueError("created window identity missing or ambiguous")
    tabs = [t for t in windows[0]["tabs"] if t.get("workspace_id") == scope["workspace_id"]]
    if len(tabs) != 1 or [str(Path(p).resolve()) for p in tabs[0]["repo_paths"]] != [scope["root_path"]]:
        raise ValueError("created workspace/context/root identity missing or ambiguous")
    return bench.validate_uuid(tabs[0]["context_id"], "fixture context")


def commit(runner, root, label, empty=False):
    # No write-tree probes: those can themselves change index cache-tree metadata.
    before = index_state(root)
    runner.git(root, label+"-status", "--no-optional-locks", "status", "--short")
    runner.git(root, label+"-diff", "diff", "--cached", "--no-ext-diff")
    runner.git(root, label+"-check", "diff", "--cached", "--check")
    exported = runner.artifact / f"{label}-staged-index"
    exported.mkdir()
    runner.git(root, label+"-export", "checkout-index", "--all", "--prefix="+str(exported)+"/")
    runner.run(label+"-secrets", ["gitleaks", "dir", "--no-banner", "--redact", str(exported)])
    after = index_state(root)
    proof = {"observer_mode": "GIT_OPTIONAL_LOCKS=0", "before": before, "after": after,
             "index_unchanged": before == after}
    bench.save_json(runner.artifact/f"{label}-observer-proof.json", proof, exclusive=True)
    if before != after:
        raise ValueError("commit preflight observers changed index SHA/full stat; mutation not dispatched")
    runner.git(root, label, "commit", "--no-gpg-sign", *(["--allow-empty"] if empty else []), "-m", label)


def stat_record(path):
    value = path.stat()
    return {field: getattr(value, "st_"+field) for field in STAT_FIELDS}


def checked_stat(value):
    if not isinstance(value, dict) or any(type(value.get(field)) is not int for field in STAT_FIELDS):
        raise ValueError("missing or invalid full stat proof")
    return value


def index_state(root):
    index = root/".git/index"
    before = stat_record(index)
    sha = digest(index)
    after = stat_record(index)
    if before != after:
        raise ValueError("index changed while capturing SHA/stat; authority proof unproven")
    return dict(index_sha256=sha, index_stat=after)


def git_state(runner, root, label):
    oids = runner.git(root, label, "rev-parse", "HEAD", "HEAD^{tree}").splitlines()
    return dict(head_and_tree=oids, **index_state(root))


def git_changes(before, after):
    """Compare actual authority evidence, not just index content."""
    for state in (before, after):
        if not isinstance(state, dict):
            raise ValueError("missing Git state proof")
        oids = state.get("head_and_tree")
        if (not isinstance(oids, list) or len(oids) != 2
                or any(not isinstance(oid, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", oid) for oid in oids)
                or not isinstance(state.get("index_sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", state["index_sha256"])):
            raise ValueError("missing or invalid Git OID/SHA proof")
        checked_stat(state.get("index_stat"))
    pairs = {"head": (before["head_and_tree"][0], after["head_and_tree"][0]),
             "tree": (before["head_and_tree"][1], after["head_and_tree"][1]),
             "index_sha256": (before["index_sha256"], after["index_sha256"])}
    pairs.update({f"index_stat.{field}": (before["index_stat"][field], after["index_stat"][field])
                  for field in STAT_FIELDS})
    return [field for field, (old, new) in pairs.items() if old != new]


def metadata_proof(before, after):
    try:
        changes = git_changes(before, after)
        classification = "metadata-only" if changes == ["head"] else ("mixed" if changes else "unproven")
        return {"classification": classification, "changed_fields": changes,
                "run_label": "metadata-only" if classification == "metadata-only" else classification+"-metadata-commit",
                "coverage": "proven" if classification == "metadata-only" else "unproven"}
    except ValueError as error:
        return {"classification": "unproven", "run_label": "unproven-metadata-commit",
                "coverage": "unproven", "error": str(error)}


def churn_state(runner, root, label):
    return {"captured_at": stamp(), "git": git_state(runner, root, label),
            "directories": {"root": stat_record(root), ".git": stat_record(root/".git")}}


def churn_proof(before, after):
    checks = {}
    try:
        changes = git_changes(before["git"], after["git"])
        for domain in ("root", ".git"):
            old, new = (checked_stat(state["directories"][domain]) for state in (before, after))
            checks[domain] = {
                "identity_unchanged": all(old[field] == new[field] for field in ("dev", "ino", "mode")),
                "stat_changed_fields": [field for field in ("size", "mtime_ns", "ctime_ns") if old[field] != new[field]]}
        proven = not changes and all(check["identity_unchanged"] and check["stat_changed_fields"] for check in checks.values())
        return {"coverage": "proven" if proven else "unproven", "directories": checks,
                "git_changed_fields": changes}
    except (ValueError, KeyError, TypeError) as error:
        return {"coverage": "unproven", "directories": checks, "error": str(error)}


def parse_app_provenance(raw):
    value = json.loads(raw)
    if (not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1
            or type(value.get("dirty")) is not bool
            or type(value.get("buildTimeEpoch")) not in (int, float)
            or not math.isfinite(value["buildTimeEpoch"]) or value["buildTimeEpoch"] <= 0
            or not isinstance(value.get("commit"), str)
            or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value["commit"])
            or any(not isinstance(value.get(field), str) or not value[field]
                   for field in ("repoRoot", "worktreePath", "buildTimeISO"))):
        raise ValueError("missing/invalid debug app provenance; source binding unproven")
    built = datetime.fromisoformat(value["buildTimeISO"])
    if built.tzinfo is None or not 0 <= value["buildTimeEpoch"]-built.timestamp() < 1:
        raise ValueError("debug provenance build timestamps disagree or lack timezone")
    return value


def process_identity(raw, pid, executable):
    # ps lstart has only whole-second precision. Treat it as the LOWER bound,
    # never round artifact timestamps down to make a same-second build pass.
    match = re.fullmatch(r"\s*(\d+)\s+([A-Za-z]{3})\s+([A-Za-z]{3})\s+(\d{1,2})\s+"
                         r"(\d{2}):(\d{2}):(\d{2})\s+(\d{4})\s+(.+?)\s*", raw)
    if not match or int(match[1]) != pid or match[9] != str(executable):
        raise ValueError("PID does not identify the already-running CE CLI's sibling app executable")
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    if match[3] not in months:
        raise ValueError("unparseable process start month")
    started = datetime(int(match[8]), months.index(match[3])+1, int(match[4]),
                       int(match[5]), int(match[6]), int(match[7])).timestamp()
    return {"pid": pid, "executable": str(executable), "start_epoch_lower_bound": started,
            "start_time_ps": " ".join(match.group(i) for i in range(2, 9)), "precision_seconds": 1}


def verify_build_start(process, provenance, executable_stat):
    checked_stat(executable_stat)
    start = process["start_epoch_lower_bound"]
    thresholds = {"provenance_build": provenance["buildTimeEpoch"],
                  "executable_mtime": executable_stat["mtime_ns"]/1e9,
                  "executable_ctime": executable_stat["ctime_ns"]/1e9}
    if any(start <= timestamp for timestamp in thresholds.values()):
        raise ValueError("running-build proof rejected: process start must be strictly later than buildTimeEpoch "
                         "and executable mtime/ctime; same-second or newer bundle is unproven")
    return {"policy": "conservative timestamp minimum; not an OS executable-mapping hash",
            "process_start_epoch_lower_bound": start, "artifact_timestamps": thresholds,
            "process_started_strictly_after_artifacts": True}


def identity(runner, pid, phase):
    executable = runner.cli.resolve().parent / "RepoPrompt"
    argv = ["/bin/ps", "-p", str(pid), "-o", "pid=,lstart=,comm="]
    process = runner.run("app-process-"+phase, argv)["stdout"].strip()
    process_key = process_identity(process, pid, executable)
    if not executable.is_file():
        raise ValueError("app executable missing")
    executable_stat = stat_record(executable)
    plist = executable.parent.parent / "Info.plist"
    info = plistlib.loads(plist.read_bytes())
    if "repoprompt" not in info.get("CFBundleIdentifier", "").lower() or "debug" not in info.get("CFBundleIdentifier", "").lower():
        raise ValueError("app bundle is not CE DEBUG")
    provenance_path = executable.parent.parent/"Resources/RepoPromptDebugProvenance.json"
    provenance_raw = provenance_path.read_bytes()
    bench.secure_write(runner.artifact/f"app-provenance-{phase}.json", provenance_raw, exclusive=True)
    provenance = parse_app_provenance(provenance_raw)
    proof = verify_build_start(process_key, provenance, executable_stat)
    app_sha = digest(executable)
    if stat_record(executable) != executable_stat or provenance_path.read_bytes() != provenance_raw:
        raise ValueError("bundle changed while capturing running-build proof")
    process_after = process_identity(runner.run("app-process-"+phase+"-verify", argv)["stdout"], pid, executable)
    if process_key != process_after:
        raise ValueError("immutable process identity changed during build capture")
    return dict(pid=pid, process=process, process_identity=process_key, running_build_proof=proof,
                executable=str(executable), app_sha256=app_sha, executable_stat=executable_stat,
                app_provenance_path=str(provenance_path),
                app_provenance_sha256=hashlib.sha256(provenance_raw).hexdigest(), app_provenance=provenance,
                source_binding_limitation="Build provenance preserves dirty-at-build state; commit alone does not identify dirty source bytes.",
                executable_mtime_ns=executable_stat["mtime_ns"], executable_ctime_ns=executable_stat["ctime_ns"],
                cli=str(runner.cli), cli_sha256=digest(runner.cli), bundle=info,
                harness_sha256=digest(Path(__file__)), benchmark_helper_sha256=digest(Path(bench.__file__)),
                captured_at=stamp())


def diagnostic_record(value, op, action=None):
    if not tool_ok(value):
        raise ValueError("diagnostic tool error, regardless of CLI exit code")
    candidates = [item for item in bench.structured_json_objects(value)
                  if item.get("op") == op and (action is None or item.get("action") == action)]
    unique = {bench.canonical_json(item): item for item in candidates}
    if len(unique) != 1 or next(iter(unique.values())).get("ok") is not True:
        raise ValueError("missing/ambiguous successful exact diagnostic action")
    return next(iter(unique.values()))


def scope_identity(scope):
    if (not isinstance(scope, dict) or not isinstance(scope.get("root_path"), str)
            or not Path(scope["root_path"]).is_absolute()):
        raise ValueError("invalid physical scope path")
    if type(scope.get("window_id")) is not int or scope["window_id"] <= 0:
        raise ValueError("invalid scope window")
    return {"window_id": scope["window_id"],
            **{key: bench.validate_uuid(scope[key], key).upper()
               for key in ("workspace_id", "context_id", "root_id")},
            "root_path": str(Path(scope["root_path"]).resolve())}


def single_root_inventory(value, scope):
    payload = diagnostic_record(value, "mcp_read_search_runtime_snapshot")
    runtime = payload.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("missing runtime inventory")
    windows = runtime.get("windows")
    if (type(runtime.get("window_count")) is not int or runtime["window_count"] != 1
            or not isinstance(windows, list) or len(windows) != 1):
        raise ValueError("runtime does not contain exactly the scoped window")
    window = windows[0]
    if not isinstance(window, dict):
        raise ValueError("invalid window inventory")
    if (type(window.get("window_id")) is not int or window["window_id"] != scope["window_id"]
            or type(window.get("root_count")) is not int or window["root_count"] != 1
            or type(window.get("omitted_root_count")) is not int or window["omitted_root_count"] != 0
            or not isinstance(window.get("roots"), list) or len(window["roots"]) != 1):
        raise ValueError("selected window must contain exactly one loaded, non-omitted owned root")
    identity = bench.runtime_root_identity({"roots": window["roots"]}, scope["root_path"])
    if "root_id" in scope and identity["id"] != scope["root_id"]:
        raise ValueError("loaded root identity changed")
    return {"window_id": window["window_id"], "root_count": 1, "omitted_root_count": 0, **identity}


def projection_counters(value):
    # Aggregate diagnostic interpretation ONLY. These values never drive acceptance.
    # This action fails on nil engine snapshots. Never consume root-snapshot fallback zeros.
    payload = diagnostic_record(value, "worktree_startup_benchmark", "codemap_projection_snapshot")
    if "engine_present" in payload and payload["engine_present"] is not True:
        raise ValueError("engine unavailable")
    snapshot = payload.get("codemap_projection")
    if not isinstance(snapshot, dict):
        raise ValueError("missing flattened codemap_projection")
    counters = {}
    for field in COUNTER_FIELDS:
        number = snapshot.get(field)
        if type(number) is not int or not 0 <= number <= 2**64-1:
            raise ValueError(f"missing/invalid UInt64 counter: {field}")
        counters[field] = number
    return snapshot, counters


def root_counters(value, expected_root_id):
    payload = diagnostic_record(value, "worktree_startup_benchmark", "codemap_projection_snapshot")
    if "engine_present" in payload and payload["engine_present"] is not True:
        raise ValueError("engine unavailable")
    attribution = payload.get("codemap_root_attribution")
    if not isinstance(attribution, dict) or attribution.get("scope") != "root_epoch":
        raise ValueError("missing/null root attribution or incorrect root_epoch scope")
    if any(not isinstance(attribution.get(key), str) for key in ("root_id", "root_lifetime_id")):
        raise ValueError("missing/null/invalid root UUID attribution")
    root_id = bench.validate_uuid(attribution["root_id"], "attributed root_id").upper()
    if root_id != bench.validate_uuid(expected_root_id, "expected root_id").upper():
        raise ValueError("attributed root_id does not match owned fixture root")
    lifetime = bench.validate_uuid(attribution.get("root_lifetime_id"), "root_lifetime_id").upper()
    counts = {}
    for field in ROOT_COUNTER_FIELDS:
        number = attribution.get(field)
        if type(number) is not int or not 0 <= number <= 2**64-1:
            raise ValueError(f"missing/null/invalid UInt64 root counter: {field}")
        counts[field] = number
    return {"scope": "root_epoch", "root_id": root_id, "root_lifetime_id": lifetime}, counts


def counter_check(before, after, repairs, idle=False):
    result = {"passed": False, "coverage": "unproven"}
    try:
        counts, scopes, epochs = [], [], []
        for record in (before, after):
            if not isinstance(record, dict):
                raise ValueError("missing counter snapshot")
            if record.get("available") is not True or record.get("single_owned_root_in_window") is not True:
                raise ValueError("real engine snapshot and verified single-owned-root-in-window scope required")
            identity = scope_identity(record["scope"])
            for inventory in (record.get("inventory_before"), record.get("inventory_after")):
                if (not isinstance(inventory, dict) or type(inventory.get("root_count")) is not int
                        or inventory["root_count"] != 1 or type(inventory.get("omitted_root_count")) is not int
                        or inventory["omitted_root_count"] != 0 or inventory.get("window_id") != identity["window_id"]
                        or inventory.get("id") != identity["root_id"] or inventory.get("path") != identity["root_path"]):
                    raise ValueError("single-owned-root inventory proof missing or changed")
            if record["inventory_before"] != record["inventory_after"]:
                raise ValueError("inventory changed during snapshot")
            scopes.append(identity)
            epoch, root_counts = root_counters(record["response"], identity["root_id"])
            epochs.append(epoch)
            counts.append(root_counts)
        if scopes[0] != scopes[1]:
            raise ValueError("counter scope changed; cumulative counts cannot be attributed")
        if epochs[0] != epochs[1]:
            raise ValueError("root_lifetime_id changed; cumulative root counters cannot span root epochs")
        result["root_epoch"] = epochs[0]
        deltas = {field: counts[1][field]-counts[0][field] for field in ROOT_COUNTER_FIELDS}
        result["deltas"] = deltas
        if any(delta < 0 for delta in deltas.values()):
            raise ValueError("cumulative counter regression/reset")
        changes = git_changes(before["git_state"], after["git_state"])
        result["git_changed_fields"] = changes
        if repairs == 1 and not changes:
            raise ValueError("authority transition not demonstrated by Git OID/index SHA/full stat")
        if repairs == 0 and changes:
            raise ValueError("zero-repair control changed Git authority; mixed/unproven")
        if deltas["root_store_session_repairs"] != repairs:
            raise ValueError(f"repair mismatch: expected {repairs}, observed {deltas['root_store_session_repairs']}")
        # Authority observations are root-wide, not repair counts: no unconditional mutation count of one.
        if idle and any(deltas.values()):
            raise ValueError("idle background counters grew")
        result.update(passed=True, coverage="proven")
    except (ValueError, KeyError, TypeError, bench.BenchmarkError) as error:
        result["error"] = str(error)
    return result


def diagnostics(runner, scope, label, enabled):
    if not enabled:
        return {"available": False, "reason": "snapshot collection not opted in or existing benchmark gate disabled; settings unchanged"}
    started, response = stamp(), None
    try:
        root_args = {"op": "mcp_read_search_runtime_snapshot", "window_id": runner.window,
                     "recent_publication_limit": 0, "root_limit": 256}
        roots, _ = runner.call(label+"-roots-before", bench.DEBUG_TOOL, root_args)
        inventory_before = single_root_inventory(roots, scope)
        scope.setdefault("root_id", inventory_before["id"])
        expected = scope_identity(scope)
        value, _ = runner.call(label+"-scope", bench.DEBUG_TOOL,
                              bench.diagnostic_payload({"scope": scope}, "scope"))
        actual = diagnostic_record(value, "worktree_startup_benchmark", "scope")
        if scope_identity({**actual, "root_path": inventory_before["path"]}) != expected:
            raise ValueError("diagnostic workspace/window/context/root scope changed")
        response, _ = runner.call(label, bench.DEBUG_TOOL,
                                 bench.diagnostic_payload({"scope": scope}, "codemap_projection_snapshot"))
        epoch, counters = root_counters(response, expected["root_id"])
        # Preserve aggregate diagnostics, but do not let their values or regressions
        # affect root-attributed acceptance (other windows may share this engine).
        aggregate_error = None
        try:
            snapshot, aggregate_counters = projection_counters(response)
        except (ValueError, KeyError, TypeError, bench.BenchmarkError) as error:
            snapshot = diagnostic_record(response, "worktree_startup_benchmark", "codemap_projection_snapshot").get("codemap_projection")
            aggregate_counters, aggregate_error = None, str(error)
        roots, _ = runner.call(label+"-roots-after", bench.DEBUG_TOOL, root_args)
        inventory_after = single_root_inventory(roots, scope)
        if inventory_before != inventory_after:
            raise ValueError("single-owned-root inventory changed across engine snapshot")
        return {"available": True, "root_id": scope["root_id"], "scope": expected,
                "single_owned_root_in_window": True, "inventory_before": inventory_before, "inventory_after": inventory_after,
                "counter_scope": "root_epoch; inventory proves fixture ownership, NOT engine isolation",
                "root_epoch": epoch, "root_counters": counters, "root_attribution_verified": True,
                "aggregate_snapshot": snapshot, "aggregate_counters": aggregate_counters,
                "aggregate_diagnostic_error": aggregate_error, "response": response,
                "started_at": started, "finished_at": stamp()}
    except (ValueError, KeyError, TypeError, bench.BenchmarkError) as error:
        return {"available": False, "reason": str(error), "response": response,
                "started_at": started, "finished_at": stamp()}


def query(runner, root, label, results, *, expand=True, third=False, seeds=None):
    expected = {**BASE, **(THIRD if third else {})} if expand else {n: ({**BASE, **THIRD})[n] for n in seeds}
    related = set(expected)-{"ControlPayload.swift"} if expand else set()
    args = dict(scope="paths", paths=seeds or ["ControlPayload.swift"],
                limits={"max_files": 10, "max_codemap_tokens": 6000})
    if expand:
        args["expand"] = {"direction": "referrers", "max_depth": 1}
    result = dict(label=label, expected_symbols=expected, expected_related=sorted(related), passed=False)
    try:
        value, elapsed = runner.call(label, "get_code_structure", args)
        result.update(elapsed_seconds=elapsed, response=value)
        result["structure"] = validate_structure(value, root, expected, related, elapsed)
        result["passed"] = True
    except Exception as error:
        result.update(error=str(error), exception_type=type(error).__name__)
    raw = next((r for r in reversed(runner.records) if r["label"] == label), None)
    if raw:
        result["raw_command"] = raw
        result["elapsed_seconds"] = raw["elapsed_seconds"]
    results.append(result)
    print(json.dumps({"label": label, "passed": result["passed"], "elapsed": result.get("elapsed_seconds"),
                      "error": result.get("error")}), flush=True)
    bench.save_json(runner.artifact/"results.json", results)
    return result["passed"]


def capture_phase(runner, root, data, phase, enabled, *, reference=None, repairs=None, idle=False):
    label = root.name+"-snapshot-"+phase
    record = diagnostics(runner, data["scope"], label, enabled)
    data.setdefault("phases", {})[phase] = record
    record["git_state"] = git_state(runner, root, label+"-git")
    if reference is not None:
        expectation = {"before_phase": reference, "after_phase": phase, "expected_repair_delta": repairs}
        if idle:
            expectation["expected_no_growth"] = list(ROOT_COUNTER_FIELDS)
        expectation.update(counter_check(data["phases"].get(reference), record, repairs, idle))
        data.setdefault("counter_expectations", []).append(expectation)
    bench.save_json(runner.artifact/f"{root.name}-phases.json", data)
    return record


def phase_query(runner, root, data, phase, label, results, enabled, *, reference=None, repairs=None, **query_args):
    ready = query(runner, root, label, results, **query_args)
    capture_phase(runner, root, data, phase, enabled, reference=reference, repairs=repairs)
    return ready


def idle_background(runner, root, data, enabled, reference=None):
    before = capture_phase(runner, root, data, "idle-before", enabled, reference=reference, repairs=0)
    record = data["idle_background"] = {"coverage": "unproven"}
    if not before["available"]:
        record["reason"] = "No before counter snapshot; sleep is not idle proof"
        return
    record["started_at"] = stamp()
    tick = time.monotonic()
    time.sleep(2)
    record.update(finished_at=stamp(), elapsed_seconds=time.monotonic()-tick)
    capture_phase(runner, root, data, "idle-after", enabled, reference="idle-before", repairs=0, idle=True)
    check = data["counter_expectations"][-1]
    record["counter_check"] = check
    record["coverage"] = check["coverage"]
    if record["elapsed_seconds"] < 2:
        record.update(coverage="unproven", reason="idle interval shorter than two seconds")
    elif not check["passed"]:
        record["reason"] = check["error"]
    bench.save_json(runner.artifact/f"{root.name}-phases.json", data)


def lane(runner, name, bootstrap, results, snapshots, enabled, args):
    root = runner.artifact/"fixtures"/name
    root.mkdir()
    for filename, content in {"ControlPayload.swift": PAYLOAD, "ControlConsumer.swift": CONSUMER, "Notes.txt": "tracked baseline\n"}.items():
        (root/filename).write_text(content)
    runner.git(root, name+"-init", "init", "--initial-branch=main", "--template="+str(runner.artifact/"empty-template"))
    for key, value in {"user.name": "Fixture E2E", "user.email": "fixture-e2e@example.invalid",
                       "core.hooksPath": "/dev/null", "commit.gpgsign": "false"}.items():
        runner.git(root, name+"-config-"+key, "config", key, value)
    runner.git(root, name+"-stage-baseline", "add", "--", "ControlPayload.swift", "ControlConsumer.swift", "Notes.txt")
    commit(runner, root, name+"-baseline-commit")
    if name == "index-only":
        (root/"Notes.txt").write_text("changed BEFORE registration and baseline; stage only later\n")
    runner.window, runner.context = bootstrap
    runner.expected_root = None
    value, _ = runner.call(name+"-create-workspace", "manage_workspaces",
                          {"action": "create", "name": f"RPCE Search Bench Codemap Authority {runner.artifact.name} {name}",
                           "folder_path": str(root), "open_in_new_window": True})
    workspace = value["workspaces"][0]
    scope = {"workspace_id": workspace["id"], "window_id": value["window_id"], "root_path": str(root)}
    data = snapshots[name] = {"scope": scope}
    bench.save_json(runner.artifact/"lanes.json", snapshots)
    scope["context_id"] = discover_created_context(runner, scope)
    runner.window, runner.context = scope["window_id"], scope["context_id"]
    runner.expected_root = root
    if not phase_query(runner, root, data, "baseline", name+"-baseline", results, enabled):
        data["blocked"] = "baseline was not ready; retained-ready precondition absent"
        return
    data["before"] = data["phases"]["baseline"]
    data["git_before"] = data["before"]["git_state"]
    if name == "index-only":
        runner.git(root, name+"-add-notes", "add", "--", "Notes.txt")
    elif name == "metadata-only":
        commit(runner, root, name+"-empty-commit", empty=True)
        snapshots[name]["git_after_mutation"] = git_state(runner, root, name+"-head-after")
        proof = metadata_proof(snapshots[name]["git_before"], snapshots[name]["git_after_mutation"])
        snapshots[name]["metadata_proof"] = proof
        snapshots[name].update(run_label=proof["run_label"], coverage=proof["coverage"])
    else:
        runner.call(name+"-create-third", "apply_edits",
                    {"path": str(root/"ControlAuthorityAdded.swift"), "rewrite": ADDED, "on_missing": "create"})
        if (root/"ControlAuthorityAdded.swift").read_text() != ADDED:
            raise ValueError("created source bytes mismatch")
        if name == "separated-combined":
            if not phase_query(runner, root, data, "new-file-settlement", name+"-new-file-settlement",
                               results, enabled, reference="baseline", repairs=0, expand=False,
                               seeds=["ControlAuthorityAdded.swift"]):
                snapshots[name]["blocked"] = "new-file structure was not ready; settlement unproven"
                return
        if name != "catalog-only":
            runner.git(root, name+"-add-third", "add", "--", "ControlAuthorityAdded.swift")
    third = name in ("catalog-only", "separated-combined", "original-overlap")
    run_label = data.get("run_label", name)
    first_phase = {"metadata-only": "after-commit-query", "catalog-only": "after-catalog-query"}.get(name, "after-stage-query")
    repeat_phase = {"metadata-only": "commit-repeat", "catalog-only": "catalog-repeat"}.get(name, "stage-repeat")
    reference = "new-file-settlement" if name == "separated-combined" else "baseline"
    first_label = run_label+("-after-commit" if name == "metadata-only" else "-after-change")
    phase_query(runner, root, data, first_phase, first_label, results, enabled,
                reference=reference, repairs=0 if name == "catalog-only" else 1, third=third)
    phase_query(runner, root, data, repeat_phase, run_label+"-unchanged-repeat", results, enabled,
                reference=first_phase, repairs=0, third=third)
    if name in ("index-only", "separated-combined", "original-overlap"):
        commit(runner, root, name+"-commit-change")
        phase_query(runner, root, data, "after-commit-query", name+"-after-commit", results, enabled,
                    reference=repeat_phase, repairs=1, third=third)
        phase_query(runner, root, data, "commit-repeat", name+"-commit-repeat", results, enabled,
                    reference="after-commit-query", repairs=0, third=third)
        repeat_phase = "commit-repeat"
    data["after"] = data["phases"][repeat_phase]
    data["git_after"] = data["after"]["git_state"]
    if name == "metadata-only":
        proof = metadata_proof(snapshots[name]["git_before"], snapshots[name]["git_after"])
        snapshots[name]["metadata_final_proof"] = proof
        if proof["coverage"] != "proven":
            snapshots[name].update(run_label=proof["run_label"], coverage="unproven")
    if name == "catalog-only" and snapshots[name]["git_after"] != snapshots[name]["git_before"]:
        snapshots[name].update(run_label="mixed-catalog-change", coverage="unproven")
        raise ValueError("catalog-only lane changed HEAD/tree/index SHA or full stat")
    if name == "index-only":
        if args.churn:
            capture_phase(runner, root, data, "churn-before", enabled, reference=repeat_phase, repairs=0)
            churn = snapshots[name]["churn"] = []
            try:
                for i in range(20):
                    label = f"churn-{i}"
                    paths = [root/f"DirectoryChurn{i:02}", root/".git"/f"DirectoryChurn{i:02}"]
                    record = {"label": label, "created_directories": list(map(str, paths)),
                              "before": churn_state(runner, root, label+"-before")}
                    churn.append(record)
                    for path in paths:
                        path.mkdir()
                    record["after_creation"] = churn_state(runner, root, label+"-after-creation")
                    record["creation_proof"] = churn_proof(record["before"], record["after_creation"])
                    # Observers must not refresh the index and contaminate directory-only proof.
                    runner.git(root, label+"-status", "--no-optional-locks", "status", "--porcelain=v1")
                    phase_query(runner, root, data, label, label, results, enabled,
                                reference=f"churn-{i-1}" if i else "churn-before", repairs=0,
                                expand=False, seeds=list(BASE))
                    record["after_demand"] = churn_state(runner, root, label+"-after-demand")
                    record["demand_proof"] = churn_proof(record["before"], record["after_demand"])
                    record["coverage"] = "proven" if all(record[phase]["coverage"] == "proven"
                                                         for phase in ("creation_proof", "demand_proof")) else "unproven"
                    if record["coverage"] != "proven":
                        snapshots[name]["coverage"] = "unproven"
                    bench.save_json(runner.artifact/"churn.json", churn)
            finally:
                capture_phase(runner, root, data, "churn-after", enabled, reference="churn-before", repairs=0)
        if args.cadence:
            capture_phase(runner, root, data, "cadence-before", enabled,
                          reference="churn-after" if args.churn else repeat_phase, repairs=0)
            start = time.monotonic()
            def statuses():
                completed = 0
                for i in range(30):
                    time.sleep(max(0, start+2*i-time.monotonic()))
                    if time.monotonic() >= start+60:
                        break
                    runner.git(root, f"cadence-{i}-status", "--no-optional-locks", "status", "--porcelain=v1")
                    completed += 1
                return completed
            completed = None
            try:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(statuses)
                    for i in range(6):
                        time.sleep(max(0, start+10*i-time.monotonic()))
                        phase_query(runner, root, data, f"cadence-{i}", f"cadence-{i}", results, enabled,
                                    reference=f"cadence-{i-1}" if i else "cadence-before", repairs=0,
                                    expand=False, seeds=list(BASE))
                    time.sleep(max(0, start+60-time.monotonic()))
                    completed = future.result()
            finally:
                data["cadence"] = {"mode": "lock-free-status; NOT ordinary/default status baseline",
                                   "git_optional_locks": "0",
                                   "scheduled_status_calls": 30, "completed_status_calls": completed,
                                   "elapsed_seconds": time.monotonic()-start}
                after = capture_phase(runner, root, data, "cadence-after", enabled,
                                      reference="cadence-before", repairs=0)
                changes = git_changes(data["phases"]["cadence-before"]["git_state"], after["git_state"])
                data["cadence"]["git_changed_fields"] = changes
                if changes or completed != 30:
                    data["cadence"]["coverage"] = data["coverage"] = "unproven"
            if completed != 30:
                raise ValueError("60-second cadence missed status calls; not a full cadence pass")
        idle_background(runner, root, data, enabled,
                        reference="cadence-after" if args.cadence else "churn-after" if args.churn else repeat_phase)

def authority_acceptance(snapshots, args):
    missing, missing_checks, invalid, checks = {}, {}, [], []
    for name in LANES:
        data = snapshots.get(name, {})
        phases = data.get("phases", {})
        required = {"baseline"}
        if name == "metadata-only":
            required |= {"after-commit-query", "commit-repeat"}
        elif name == "catalog-only":
            required |= {"after-catalog-query", "catalog-repeat"}
        else:
            required |= {"after-stage-query", "stage-repeat", "after-commit-query", "commit-repeat"}
        if name == "separated-combined":
            required.add("new-file-settlement")
        if name == "index-only":
            required |= {"idle-before", "idle-after"}
            if args.churn:
                required |= {"churn-before", "churn-after", *[f"churn-{i}" for i in range(20)]}
            if args.cadence:
                required |= {"cadence-before", "cadence-after", *[f"cadence-{i}" for i in range(6)]}
        if required-set(phases):
            missing[name] = sorted(required-set(phases))
        baseline = phases.get("baseline")
        baseline_epoch = counter_check(baseline, baseline, 0).get("root_epoch")
        for phase, record in phases.items():
            check = counter_check(record, record, 0)
            if not check["passed"] or check.get("root_epoch") != baseline_epoch:
                invalid.append(f"{name}/{phase}")
        local_checks = data.get("counter_expectations", [])
        checked_phases = {check.get("after_phase") for check in local_checks
                          if check.get("before_phase") in phases
                          and type(check.get("expected_repair_delta")) is int
                          and check["expected_repair_delta"] == int(check.get("after_phase") in
                                                                   ("after-stage-query", "after-commit-query"))}
        absent = required-{"baseline"}-checked_phases
        if absent:
            missing_checks[name] = sorted(absent)
        checks.extend(local_checks)
        if name == "index-only" and data.get("idle_background", {}).get("coverage") != "proven":
            invalid.append("index-only/idle-background")
    failed = sum(check.get("passed") is not True for check in checks)
    return {"required": args.require_authority_counters, "scope": "root_epoch; stable root_id and root_lifetime_id in each lane",
            "coverage": "proven" if checks and not failed and not missing and not missing_checks and not invalid else "unproven",
            "aggregate_policy": "codemap_projection is diagnostic only; never drives root acceptance",
            "total_checks": len(checks), "passed_checks": len(checks)-failed, "failed_checks": failed,
            "missing_phases": missing, "missing_checks": missing_checks, "invalid_phases": invalid}


def preflight_dependencies(runner):
    paths = {name: shutil.which(name, path=runner.env.get("PATH")) for name in ("git", "gitleaks", "xcrun")}
    missing = [name for name, path in paths.items() if not path]
    if missing:
        raise ValueError("missing harness dependencies: "+", ".join(missing)+"; requires gitleaks >= 8.19 and xcrun swiftc")
    version = runner.run("dependency-gitleaks-version", [paths["gitleaks"], "version"])["stdout"].strip()
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", version)
    if not match or tuple(map(int, match.groups())) < (8, 19, 0):
        raise ValueError(f"gitleaks >= 8.19 required for dir scanning; found {version!r}")
    runner.run("dependency-gitleaks-dir", [paths["gitleaks"], "dir", "--help"])
    compiler = runner.run("dependency-swiftc", [paths["xcrun"], "--find", "swiftc"])["stdout"].strip()
    if not Path(compiler).is_absolute():
        raise ValueError("xcrun swiftc dependency unavailable")
    return {"executables": paths, "gitleaks_version": version, "swiftc": compiler}


def finalize_summary(summary, args):
    # Finalize even on malformed CLI schemas/unexpected Python exceptions.
    try:
        summary["counter_acceptance"] = authority_acceptance(summary["lanes"], args)
    except Exception as error:
        summary["errors"].append({"phase": "finalize", "exception_type": type(error).__name__, "error": str(error)})
        summary["counter_acceptance"] = {"required": args.require_authority_counters, "coverage": "unproven", "error": str(error)}
    results, snapshots, errors = summary["results"], summary["lanes"], summary["errors"]
    summary.update(total=len(results), passed=sum(r["passed"] for r in results),
                   failed=sum(not r["passed"] for r in results))
    summary["coverage_unproven"] = {name: data.get("run_label", name) for name, data in snapshots.items()
                                   if data.get("coverage") == "unproven" or data.get("blocked")}
    success = (summary.get("post_run_verification_completed") is True
               and results and not errors and summary["failed"] == 0
               and not summary["coverage_unproven"] and len(snapshots) == len(LANES)
               and (not (args.diagnostics or args.require_diagnostics)
                    or summary["counter_acceptance"]["coverage"] == "proven"))
    level = "authority-acceptance" if args.require_authority_counters else "structure-only"
    summary["validation_level"] = level
    summary["status"] = "pass-"+level if success else "fail"
    summary["finished_at"] = stamp()
    bench.save_json(Path(summary["artifact"])/"summary.json", summary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--confirm-isolated-fixtures", action="store_true")
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--context-id", required=True)
    parser.add_argument("--app-pid", type=int, required=True)
    parser.add_argument("--cli")
    parser.add_argument("--churn", action="store_true")
    parser.add_argument("--cadence", action="store_true", help="Opt-in 60s lock-free git status cadence, NOT ordinary/default status")
    parser.add_argument("--diagnostics", action="store_true", help="Opt in to existing read-only gated snapshots; never enables gate")
    parser.add_argument("--require-diagnostics", action="store_true", help="Implies --diagnostics; fail if any per-phase gated snapshot is unavailable")
    parser.add_argument("--require-authority-counters", action="store_true",
                        help="Implies --require-diagnostics; require strict root-attributed counters, stable root lifetime, exact repairs and idle deltas")
    args = parser.parse_args(argv)
    if args.require_authority_counters:
        args.diagnostics = args.require_diagnostics = True
    if not args.confirm_isolated_fixtures or args.window_id <= 0 or args.app_pid <= 0:
        parser.error("explicit isolated-fixture opt-in and positive window/PID required")
    context = bench.validate_uuid(args.context_id, "context")
    os.umask(0o077)
    artifact = Path(tempfile.mkdtemp(prefix="rpce-codemap-authority-", dir=Path("/tmp").resolve())).resolve()
    (artifact/"raw").mkdir(); (artifact/"fixtures").mkdir(); (artifact/"empty-template").mkdir()
    print(f"Evidence retained: {artifact}", flush=True)
    results, snapshots, errors = [], {}, []
    summary = {"schema_version": 1, "kind": "focused-codemap-authority-live-e2e", "artifact": str(artifact),
               "argv": sys.argv if argv is None else argv, "lanes": snapshots, "results": results, "errors": errors,
               "retention": "All workspaces, repositories and evidence retained; no automatic cleanup",
               "started_at": stamp(), "status": "running", "post_run_verification_completed": False,
               "demand_bound": {"seconds_exclusive": 10, "measurement": "CLI-inclusive: startup + bind_context + server + transport",
                                "server_deadline": "unchanged; no overrides or retries"},
               "git_probe_policy": "GIT_OPTIONAL_LOCKS=0; cadence is lock-free, NOT ordinary/default status baseline",
               "counter_policy": "Only actual gated snapshots; log notices are not repair counts",
               "counter_acceptance": {"required": args.require_authority_counters, "coverage": "unproven",
                                      "reason": "Per-phase root-attributed capture and comparisons not completed"},
               "routing_exception": "User-approved global read-only windows discovery once per new workspace; every targeted call has both IDs"}
    try:
        bench.secure_write(artifact/"harness-source.py", Path(__file__).read_bytes(), exclusive=True)
        bench.secure_write(artifact/"benchmark-helper-source.py", Path(bench.__file__).read_bytes(), exclusive=True)
        runner = Runner(artifact, bench.resolve_cli(args.cli), args.window_id, context)
        summary["dependencies"] = preflight_dependencies(runner)
        before = identity(runner, args.app_pid, "before"); summary["build_identity_before"] = before
        summary["cli_version"] = runner.run("cli-version", [str(runner.cli), "--version"])["stdout"]
        summary["structure_schema"] = runner.run("structure-schema", [str(runner.cli), "-d", "get_code_structure"])["stdout"]
        if re.search(r"\bwait_ms\b", summary["structure_schema"]):
            raise ValueError("schema advertises caller-owned readiness deadline; refusing to tune it")
        settings, _ = runner.call("settings-before", "app_settings", {"op": "get", "group": "code_maps"})
        if bench.find_value(settings, "code_maps.globally_disabled") is not False:
            raise ValueError("code maps disabled or setting unavailable; harness will not change it")
        gate, _ = runner.call("diagnostic-gate", "app_settings", {"op": "get", "key": bench.BENCHMARK_GATE_KEY})
        gate_enabled = bench.find_value(gate, bench.BENCHMARK_GATE_KEY) is True
        summary["diagnostics"] = {"requested": args.diagnostics or args.require_diagnostics,
                                  "required": args.require_diagnostics, "gate_enabled": gate_enabled,
                                  "authority_counter_schema": {"codemap_root_attribution": {
                                      "scope": "root_epoch", "root_id": "UUID", "root_lifetime_id": "UUID",
                                      **{field: "UInt64; null/missing rejected" for field in ROOT_COUNTER_FIELDS}}},
                                  "counter_scope": "root_epoch; aggregate codemap_projection is diagnostic only"}
        enabled = gate_enabled and summary["diagnostics"]["requested"]
        if args.require_diagnostics and not gate_enabled:
            raise ValueError("diagnostics required but existing benchmark gate disabled")
        # Validate all three known Swift sources BEFORE registration/mutations.
        for filename, source in {"ControlPayload.swift": PAYLOAD, "ControlConsumer.swift": CONSUMER,
                                 "ControlAuthorityAdded.swift": ADDED}.items():
            (artifact/filename).write_text(source)
        runner.run("validate-swift-fixtures", ["xcrun", "swiftc", "-frontend", "-parse",
                                             *[str(artifact/n) for n in (*BASE, *THIRD)]])
        bootstrap = (runner.window, runner.context)
        for name in LANES:
            try:
                lane(runner, name, bootstrap, results, snapshots, enabled, args)
            except Exception as error:
                errors.append({"lane": name, "exception_type": type(error).__name__, "error": str(error)})
            finally:
                bench.save_json(artifact/"summary.json", summary)
        runner.window, runner.context = bootstrap
        runner.expected_root = None
        after_settings, _ = runner.call("settings-after", "app_settings", {"op": "get", "group": "code_maps"})
        settings_verified = settings == after_settings
        if not settings_verified:
            errors.append({"error": "read-only code_maps settings changed during run"})
        after = identity(runner, args.app_pid, "after"); summary["build_identity_after"] = after
        identity_verified = all(before[k] == after[k] for k in ("process_identity", "executable_stat", "app_sha256", "cli_sha256", "app_provenance_sha256", "harness_sha256", "benchmark_helper_sha256"))
        if not identity_verified:
            errors.append({"error": "app/CLI process, build or harness/helper source identity changed during run"})
        if args.require_diagnostics:
            for name, data in snapshots.items():
                phases = data.get("phases", {})
                if not phases or not all(record.get("available") for record in phases.values()):
                    errors.append({"lane": name, "error": "required per-phase diagnostic snapshots unavailable"})
        summary["post_run_verification_completed"] = settings_verified and identity_verified
    except Exception as error:
        errors.append({"exception_type": type(error).__name__, "error": str(error)})
    except BaseException as error:
        summary["post_run_verification_completed"] = False
        errors.append({"interrupted": True, "exception_type": type(error).__name__, "error": str(error)})
        raise
    finally:
        finalize_summary(summary, args)
    print(json.dumps({k: summary[k] for k in ("artifact", "status", "total", "passed", "failed", "coverage_unproven", "counter_acceptance", "errors")}), flush=True)
    return 0 if summary["status"].startswith("pass-") else 1


if __name__ == "__main__":
    raise SystemExit(main())
