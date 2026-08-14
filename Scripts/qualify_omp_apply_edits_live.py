#!/usr/bin/env python3
"""Opt-in OMP file-edit qualification for an already-running verified scratch window."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

import omp_qualification_support as support

SENTINEL = "OMP_APPLY_EDITS_QUALIFICATION_OK"
INITIAL = "OMP_APPLY_EDITS_INITIAL\n"
ACCEPTED = "OMP_APPLY_EDITS_ACCEPTED\n"


class QualificationError(RuntimeError):
    pass


def call(cli: str, window: int, tool: str, payload: dict[str, object], timeout: int) -> dict[str, object]:
    encoded = json.dumps(payload, separators=(",", ":"))
    status, stdout, _ = support._bounded_process(
        [cli, "--raw-json", "-w", str(window), "-c", tool, "-j", encoded],
        timeout,
        support.MAX_COMMAND_OUTPUT,
    )
    if status:
        raise QualificationError(f"{tool} exited with status {status}")
    raw = support._strict_json_loads(stdout)
    if tool == "__repoprompt_debug_diagnostics":
        discriminator = f"diagnostic:{payload['op']}"
    elif tool == "agent_manage":
        discriminator = f"agent_manage:{payload['op']}"
    else:
        discriminator = tool
    return support._normalized_response(raw, discriminator)


def save(root: Path, name: str, value: object) -> None:
    path = root / name
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reject_omp_request_timeout(value: object, evidence_label: str) -> None:
    if "Request timeout after" in json.dumps(value, sort_keys=True):
        raise QualificationError(f"{evidence_label} contains an OMP request timeout")


def exact_review(value: dict[str, object]) -> dict[str, object]:
    review = value.get("interaction")
    if not isinstance(review, dict) or review.get("title") != "Apply Edits Review":
        raise QualificationError("run did not surface the DEBUG Apply Edits Review")
    options = review.get("options")
    labels = {item.get("label") for item in options if isinstance(item, dict)} if isinstance(options, list) else set()
    if review.get("kind") != "approval" or labels != {"accept", "reject"}:
        raise QualificationError("review was not the exact accept/reject interaction")
    return review


def review_decision(value: dict[str, object]) -> str | None:
    metadata = value.get("_meta")
    item = metadata.get("omp_qualification_apply_edits_review") if isinstance(metadata, dict) else None
    return item.get("decision") if isinstance(item, dict) else None


def wait_review(cli: str, window: int, session: str, timeout: int) -> dict[str, object]:
    value = call(cli, window, "agent_run", {
        "op": "wait", "session_id": session, "timeout": timeout,
    }, timeout + 30)
    exact_review(value)
    return value


def verified_workspace(snapshot: dict[str, object], window: int, scratch: Path) -> str:
    windows = snapshot.get("windows")
    if not isinstance(windows, list):
        raise QualificationError("routing snapshot did not expose windows")
    matches = [item for item in windows if isinstance(item, dict) and item.get("window_id") == window]
    if len(matches) != 1:
        raise QualificationError("window id did not identify exactly one live window")
    target = matches[0]
    workspace_id = target.get("workspace_id")
    repo_paths = target.get("repo_paths")
    if (
        not isinstance(workspace_id, str)
        or not isinstance(repo_paths, list)
        or len(repo_paths) != 1
        or not isinstance(repo_paths[0], str)
        or Path(repo_paths[0]).resolve() != scratch
    ):
        raise QualificationError("target window is not bound only to the confirmed scratch workspace")
    for item in windows:
        if item is target or not isinstance(item, dict):
            continue
        for raw in item.get("repo_paths", []):
            if isinstance(raw, str):
                other = Path(raw).resolve()
                if scratch == other or scratch in other.parents or other in scratch.parents:
                    raise QualificationError("scratch workspace overlaps another live window")
    return workspace_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--scratch-workspace", type=Path, required=True)
    parser.add_argument("--confirm-scratch-workspace", type=Path, required=True)
    parser.add_argument("--output-parent", type=Path, default=Path("/tmp"))
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.window_id <= 0 or not args.model_id.startswith("ohMyPi:") or args.model_id == "ohMyPi:":
        raise QualificationError("positive window id and exact ohMyPi model id are required")
    if not 10 <= args.timeout <= 480:
        raise QualificationError("timeout must be in 10...480 seconds")
    cli = shutil.which("rpce-cli-debug")
    if not cli:
        raise QualificationError("rpce-cli-debug is required")
    scratch = args.scratch_workspace.expanduser().resolve()
    confirmed = args.confirm_scratch_workspace.expanduser().resolve()
    output_parent = args.output_parent.expanduser().resolve()
    repo = Path(__file__).resolve().parent.parent
    if scratch != confirmed:
        raise QualificationError("caller confirmation does not exactly match scratch workspace")
    if not scratch.is_dir() or repo in scratch.parents or scratch in repo.parents or scratch == repo:
        raise QualificationError("scratch workspace must be an existing directory outside the repository")
    if not output_parent.is_dir() or scratch in output_parent.parents or output_parent in scratch.parents:
        raise QualificationError("output parent must exist outside the scratch workspace")

    routing = call(cli, args.window_id, "__repoprompt_debug_diagnostics", {
        "op": "routing_snapshot", "include_records": False, "include_windows": True,
    }, args.timeout)
    workspace_id = verified_workspace(routing, args.window_id, scratch)
    if any(scratch.iterdir()):
        raise QualificationError("verified scratch workspace must be empty")

    evidence = Path(tempfile.mkdtemp(prefix="omp-edit-qualification.", dir=output_parent))
    evidence.chmod(0o700)
    print(f"OMP_APPLY_EDITS_QUALIFICATION_EVIDENCE_DIR={evidence}", flush=True)
    save(evidence, "routing_before.json", routing)
    canary = scratch / "omp-qualification-canary.txt"
    canary.write_text(INITIAL, encoding="utf-8")
    canary.chmod(0o600)
    initial_hash = digest(canary)
    lease_id = session_id = run_id = connection_id = None
    failure: BaseException | None = None
    try:
        lease = call(cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "acquire",
            "owner_pid": os.getpid(), "duration_seconds": min(600, args.timeout + 120),
        }, args.timeout)
        lease_id = lease.get("lease_id")
        if not isinstance(lease_id, str) or lease.get("active") is not True:
            raise QualificationError("exclusive lease was not acquired")
        save(evidence, "lease_acquire.json", lease)
        message = (
            "Use only this exact sequence: call get_file_tree on the workspace root; call apply_edits "
            "on omp-qualification-canary.txt changing OMP_APPLY_EDITS_INITIAL to OMP_APPLY_EDITS_ACCEPTED; "
            "after acceptance call apply_edits on it changing OMP_APPLY_EDITS_ACCEPTED to "
            f"OMP_APPLY_EDITS_REJECTED_ATTEMPT; after rejection reply exactly {SENTINEL}."
        )
        start = call(cli, args.window_id, "agent_run", {
            "op": "start", "model_id": args.model_id, "workspace_id": workspace_id,
            "_omp_qualification_lease_id": lease_id,
            "_omp_qualification_apply_edits_review": True,
            "session_name": "PRIVATE OMP edit qualification", "message": message, "detach": True,
        }, args.timeout)
        save(evidence, "start.json", start)
        session_id, run_id = start.get("session_id"), start.get("run_id")
        if not isinstance(session_id, str) or not isinstance(run_id, str):
            raise QualificationError("start omitted exact session/run identifiers")

        first = start if start.get("interaction") else wait_review(cli, args.window_id, session_id, args.timeout)
        first_review = exact_review(first)
        save(evidence, "first_review.json", first)
        log = call(cli, args.window_id, "agent_manage", {
            "op": "get_log", "session_id": session_id, "limit": 20,
        }, args.timeout)
        reject_omp_request_timeout(log, "agent log")
        if "get_file_tree" not in str(log.get("transcript_xml")):
            raise QualificationError("transcript lacked visible get_file_tree representation")
        save(evidence, "tool_transcript.json", log)
        accepted = call(cli, args.window_id, "agent_run", {
            "op": "respond", "session_id": session_id,
            "interaction_id": first_review["id"], "response": "accept",
        }, args.timeout)
        if review_decision(accepted) != "accepted":
            raise QualificationError("accept response lacked accepted review metadata")
        save(evidence, "accept_response.json", accepted)
        if canary.read_text(encoding="utf-8") != ACCEPTED or digest(canary) == initial_hash:
            raise QualificationError("accepted review did not produce the exact canary mutation")
        accepted_hash = digest(canary)
        if sorted(path.name for path in scratch.iterdir()) != [canary.name]:
            raise QualificationError("accepted review mutated outside the canary")

        second = wait_review(cli, args.window_id, session_id, args.timeout)
        second_review = exact_review(second)
        save(evidence, "second_review.json", second)
        rejected = call(cli, args.window_id, "agent_run", {
            "op": "respond", "session_id": session_id,
            "interaction_id": second_review["id"], "response": "reject",
        }, args.timeout)
        if review_decision(rejected) != "rejected":
            raise QualificationError("reject response lacked rejected review metadata")
        save(evidence, "reject_response.json", rejected)
        if digest(canary) != accepted_hash or canary.read_text(encoding="utf-8") != ACCEPTED:
            raise QualificationError("rejected review changed the canary")

        terminal = call(cli, args.window_id, "agent_run", {
            "op": "wait", "session_id": session_id, "timeout": args.timeout,
        }, args.timeout + 30)
        save(evidence, "terminal.json", terminal)
        if terminal.get("status") != "completed" or terminal.get("assistant_text") != SENTINEL:
            raise QualificationError("terminal result lacked the exact sentinel")
        history = call(cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "run_routing_history", "run_id": run_id, "limit": 500,
        }, args.timeout)
        reject_omp_request_timeout(history, "run routing history")
        events = history.get("events")
        encoded = json.dumps(events, sort_keys=True)
        if not isinstance(events, list) or "get_file_tree" not in encoded or "apply_edits" not in encoded:
            raise QualificationError("routing history lacked raw file-tool evidence")
        if "policy_rejected" in encoded or "waitingForApproval" in encoded:
            raise QualificationError("routing history showed rejection or ACP double approval")
        connection_ids = {
            event.get("connection_id")
            for event in events
            if isinstance(event, dict) and isinstance(event.get("connection_id"), str)
        }
        if len(connection_ids) != 1:
            raise QualificationError("routing history did not identify one exact helper connection")
        connection_id = connection_ids.pop()
        save(evidence, "run_routing_history.json", history)
    except BaseException as error:
        failure = error
    finally:
        cleanup_errors: list[str] = []
        if isinstance(session_id, str):
            try:
                cleanup = call(cli, args.window_id, "agent_manage", {
                    "op": "cleanup_sessions", "session_ids": [session_id],
                }, args.timeout)
                if cleanup.get("deleted_count") != 1 or cleanup.get("skipped_count") != 0:
                    raise QualificationError("exact session cleanup was not authoritative")
                save(evidence, "session_cleanup.json", cleanup)
            except BaseException as error:
                cleanup_errors.append(str(error))
        if isinstance(connection_id, str):
            try:
                deadline = time.monotonic() + 30
                while True:
                    history = call(cli, args.window_id, "__repoprompt_debug_diagnostics", {
                        "op": "connection_history", "connection_id": connection_id, "limit": 500,
                    }, min(args.timeout, 30))
                    reject_omp_request_timeout(history, "connection history")
                    events = history.get("events")
                    removed = [
                        event for event in events
                        if isinstance(event, dict) and event.get("event") == "removed"
                    ] if isinstance(events, list) else []
                    if removed:
                        break
                    if time.monotonic() >= deadline:
                        raise QualificationError("exact helper connection did not reach terminal removal")
                    time.sleep(0.25)
                if len(removed) != 1:
                    raise QualificationError("connection history did not expose one terminal event")
                final = removed[0]
                raw_names = final.get("qualification_raw_canonical_tool_names")
                if (
                    final.get("qualification_raw_in_flight_call_count") != 0
                    or final.get("active_tool_scope_count") != 0
                    or not isinstance(raw_names, list)
                    or not {"get_file_tree", "apply_edits"}.issubset(set(raw_names))
                ):
                    raise QualificationError("terminal evidence lacked drained exact file-tool activity")
                save(evidence, "omp_connection_history.json", history)
            except BaseException as error:
                cleanup_errors.append(str(error))
        if isinstance(lease_id, str):
            try:
                release = call(cli, args.window_id, "__repoprompt_debug_diagnostics", {
                    "op": "omp_qualification_lease", "action": "release",
                    "lease_id": lease_id, "owner_pid": os.getpid(),
                }, args.timeout)
                if release.get("active") is not False:
                    raise QualificationError("lease release did not prove inactive")
                save(evidence, "lease_release.json", release)
            except BaseException as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            failure = QualificationError("; ".join(([str(failure)] if failure else []) + cleanup_errors))
    if failure:
        raise failure
    print(f"{SENTINEL} evidence={evidence}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QualificationError, support.SupportError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
