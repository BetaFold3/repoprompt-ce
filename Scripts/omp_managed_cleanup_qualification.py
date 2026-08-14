#!/usr/bin/env python3
"""Opt-in cleanup qualification against an already-running RepoPrompt DEBUG app.

The caller must dedicate an existing scratch-workspace window. This script never
launches, stops, relaunches, or switches RepoPrompt and never targets a process by
name. It acts only on run-correlated PIDs captured from DEBUG routing evidence.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import omp_acp_live_spike as spike
import omp_qualification_support as support


OMP_MANAGED_CLEANUP_OK = "OMP_MANAGED_CLEANUP_OK"


class QualificationError(RuntimeError):
    pass


def reject_omp_request_timeout(value: object, evidence_label: str) -> None:
    if "Request timeout after" in json.dumps(value, sort_keys=True):
        raise QualificationError(f"{evidence_label} contains an OMP request timeout")


def strict_uuid(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise QualificationError(f"{label} is not a UUID string")
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise QualificationError(f"{label} is not a UUID string") from error


def uuid_equal(left: Any, left_label: str, right: Any, right_label: str) -> bool:
    return strict_uuid(left, left_label) == strict_uuid(right, right_label)


def validate_bound_lease(
    payload: dict[str, Any],
    lease_id: str,
    session_id: str,
    run_id: str,
    evidence_label: str,
) -> None:
    if (
        payload.get("active") is not True
        or not uuid_equal(payload.get("lease_id"), f"{evidence_label} lease_id", lease_id, "expected lease_id")
        or not uuid_equal(payload.get("session_id"), f"{evidence_label} session_id", session_id, "expected session_id")
        or not uuid_equal(payload.get("run_id"), f"{evidence_label} run_id", run_id, "expected run_id")
    ):
        raise QualificationError(f"{evidence_label} did not preserve the exact bound lease")


def call(cli: Path, window_id: int, tool: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    command = [str(cli), "--raw-json", "-w", str(window_id), "-c", tool, "-j", json.dumps(payload, separators=(",", ":"))]
    returncode, stdout, stderr = support._bounded_process(command, timeout, support.MAX_COMMAND_OUTPUT)
    if returncode != 0:
        raise QualificationError(f"{tool} exited {returncode}: {stderr.decode(errors='replace')[:512]}")
    raw = support._strict_json_loads(stdout)
    if tool == "__repoprompt_debug_diagnostics":
        discriminator = f"diagnostic:{payload.get('op')}"
    elif tool == "agent_run":
        discriminator = "agent_run"
    elif tool == "agent_manage":
        discriminator = f"agent_manage:{payload.get('op')}"
    else:
        raise QualificationError("unsupported qualification tool")
    try:
        return support._normalized_response(raw, discriminator)
    except support.SupportError as error:
        raise QualificationError(str(error)) from error


def verify_dedicated_scratch_window(
    cli: Path,
    window_id: int,
    workspace_id: str,
    scratch_workspace: Path,
    evidence_parent: Path,
    timeout: float,
) -> dict[str, Any]:
    routing = call(
        cli,
        window_id,
        "__repoprompt_debug_diagnostics",
        {"op": "routing_snapshot", "include_records": False, "include_windows": True},
        timeout,
    )
    windows = routing.get("windows")
    if not isinstance(windows, list):
        raise QualificationError("routing snapshot has no windows array")
    targets = [item for item in windows if isinstance(item, dict) and item.get("window_id") == window_id]
    if len(targets) != 1:
        raise QualificationError("dedicated scratch window is not uniquely present")
    target = targets[0]
    if strict_uuid(target.get("workspace_id"), "routing workspace_id") != workspace_id:
        raise QualificationError("dedicated scratch window workspace_id changed")
    roots = target.get("repo_paths")
    if (
        not isinstance(roots, list)
        or len(roots) != 1
        or not isinstance(roots[0], str)
        or not roots[0]
        or not Path(roots[0]).is_absolute()
    ):
        raise QualificationError("dedicated scratch window must contain exactly one nonempty absolute root")
    try:
        expected_root = scratch_workspace.resolve(strict=True)
        routed_root = Path(roots[0]).resolve(strict=True)
        canonical_evidence_parent = evidence_parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise QualificationError("dedicated scratch paths must strictly resolve") from error
    if routed_root != expected_root:
        raise QualificationError("dedicated scratch window must contain exactly the caller-verified scratch root")
    if os.path.commonpath([str(canonical_evidence_parent), str(expected_root)]) in {
        str(canonical_evidence_parent),
        str(expected_root),
    }:
        raise QualificationError("evidence parent must not overlap the scratch workspace")
    return target


def parse_decimal(value: Any, label: str, *, positive: bool = True) -> int:
    if not isinstance(value, str) or not value.isascii() or not value.isdecimal():
        raise QualificationError(f"{label} is not canonical decimal evidence")
    parsed = int(value)
    if (positive and parsed <= 0) or (len(value) > 1 and value.startswith("0")):
        raise QualificationError(f"{label} is not canonical decimal evidence")
    return parsed


def captured_processes(events: list[dict[str, Any]], run_id: str) -> tuple[str, dict[str, Any], dict[str, Any]]:
    run_id = strict_uuid(run_id, "expected run_id")
    identity = [event for event in events if event.get("event") == "client_identity_observed"]
    registered = [event for event in events if event.get("event") == "expected_pid_registered"]
    if len(identity) != 1 or len(registered) != 1:
        raise QualificationError("run routing lacks one exact OMP/helper identity pair")
    fields = identity[0].get("fields")
    registered_fields = registered[0].get("fields")
    if not isinstance(fields, dict) or not isinstance(registered_fields, dict):
        raise QualificationError("run routing identity fields are malformed")
    if fields.get("verified_client_name") != "omp-coding-agent":
        raise QualificationError("run routing client identity is not OMP")
    omp_pid = parse_decimal(registered_fields.get("expected_pid"), "OMP PID")
    helper_pid = parse_decimal(fields.get("helper_peer_pid"), "helper PID")
    if omp_pid == helper_pid:
        raise QualificationError("OMP and helper PIDs are not distinct")
    omp = spike.capture_live_process_identity(omp_pid)
    helper = spike.capture_live_process_identity(helper_pid)
    if (
        omp["startSeconds"] != parse_decimal(fields.get("matched_expected_start_seconds"), "OMP start seconds")
        or omp["startMicroseconds"] != parse_decimal(fields.get("matched_expected_start_microseconds"), "OMP start microseconds", positive=False)
        or helper["startSeconds"] != parse_decimal(fields.get("helper_process_start_seconds"), "helper start seconds")
        or helper["startMicroseconds"] != parse_decimal(fields.get("helper_process_start_microseconds"), "helper start microseconds", positive=False)
    ):
        raise QualificationError("captured process start identity disagrees with routing evidence")
    connection_id = strict_uuid(identity[0].get("connection_id"), "connection_id")
    if any(
        not uuid_equal(event.get("run_id"), "routing event run_id", run_id, "expected run_id")
        for event in events
    ):
        raise QualificationError("run routing evidence contains a foreign run")
    return connection_id, omp, helper


def wait_routing(cli: Path, window_id: int, run_id: str, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        payload = call(
            cli,
            window_id,
            "__repoprompt_debug_diagnostics",
            {"op": "run_routing_history", "run_id": run_id, "limit": 500},
            min(10, timeout),
        )
        reject_omp_request_timeout(payload, "run routing history")
        events = payload.get("events")
        if isinstance(events, list) and any(event.get("event") == "client_identity_observed" for event in events):
            return payload
        time.sleep(0.1)
    raise QualificationError("run did not publish correlated routing identity")


def allowed_terminal_statuses(scenario: str) -> frozenset[str]:
    allowed = {
        "cancel": frozenset({"cancelled"}),
        "kill-omp": frozenset({"failed"}),
        "kill-helper": frozenset({"completed", "failed"}),
    }
    try:
        return allowed[scenario]
    except KeyError as error:
        raise QualificationError(f"unknown cleanup scenario {scenario!r}") from error


def wait_terminal(
    cli: Path,
    window_id: int,
    session_id: str,
    allowed: frozenset[str],
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] | None = None
    terminal_statuses = {"completed", "cancelled", "failed"}
    while time.monotonic() < deadline:
        last = call(cli, window_id, "agent_run", {"op": "wait", "session_id": session_id, "timeout": 1}, 10)
        if last.get("status") in terminal_statuses:
            break
    status = None if last is None else last.get("status")
    if status not in allowed:
        raise QualificationError(f"terminal outcome was {status!r}, expected one of {sorted(allowed)!r}")
    assert last is not None
    return last


def validate_terminal_outcome(
    scenario: str,
    terminal: dict[str, Any],
    *,
    helper_signal_succeeded: bool = False,
    cleanup_snapshot: dict[str, Any] | None = None,
) -> str:
    status = terminal.get("status")
    if status not in allowed_terminal_statuses(scenario):
        raise QualificationError(f"terminal outcome {status!r} is invalid for {scenario!r}")
    if scenario == "cancel":
        return "exact-cancelled"
    if scenario == "kill-omp":
        return "exact-root-failure"
    if status == "completed":
        if helper_signal_succeeded is not True:
            raise QualificationError("completed helper-loss run lacked the exact helper signal")
        if terminal.get("assistant_text") != OMP_MANAGED_CLEANUP_OK:
            raise QualificationError("completed helper-loss run lacked the exact sentinel")
        return "exact-completed-sentinel"
    correlation = None if cleanup_snapshot is None else cleanup_snapshot.get("initialHelperCorrelation")
    if helper_signal_succeeded is not True or correlation is not True:
        raise QualificationError("failed helper-loss run lacked exact initial-helper/run/tool correlation")
    return "correlated-helper-failure"


def terminal_drain_phase(scenario: str, terminal: dict[str, Any]) -> str:
    if scenario == "kill-helper" and terminal.get("status") == "completed":
        return "post-session-cleanup"
    return "pre-session-cleanup"


def verify_successor_isolation(
    cli: Path,
    window_id: int,
    run_id: str,
    initial_connection_id: str,
    omp_identity: dict[str, Any],
    initial_helper_identity: dict[str, Any],
    timeout: float,
    first_cleanup_snapshot: dict[str, Any],
) -> dict[str, Any]:
    connection_identities = first_cleanup_snapshot.get("capturedConnectionIdentities")
    if not isinstance(connection_identities, dict):
        raise QualificationError("first cleanup snapshot did not provide exact connection identities")
    return verify_cleanup(
        cli,
        window_id,
        run_id,
        initial_connection_id,
        omp_identity,
        initial_helper_identity,
        timeout,
        sealed_connection_identities=connection_identities,
    )


def _routing_connection_identity(
    event: dict[str, Any],
    omp_identity: dict[str, Any],
) -> dict[str, int]:
    fields = event.get("fields")
    if not isinstance(fields, dict) or fields.get("verified_client_name") != "omp-coding-agent":
        raise QualificationError("run routing client identity is not exact OMP")
    if (
        parse_decimal(fields.get("matched_expected_start_seconds"), "OMP start seconds") != omp_identity["startSeconds"]
        or parse_decimal(fields.get("matched_expected_start_microseconds"), "OMP start microseconds", positive=False)
        != omp_identity["startMicroseconds"]
    ):
        raise QualificationError("run routing connection has mismatched OMP start identity")
    return {
        "pid": parse_decimal(fields.get("helper_peer_pid"), "helper PID"),
        "startSeconds": parse_decimal(fields.get("helper_process_start_seconds"), "helper start seconds"),
        "startMicroseconds": parse_decimal(
            fields.get("helper_process_start_microseconds"), "helper start microseconds", positive=False,
        ),
    }


def capture_stable_connection_identities(
    cli: Path,
    window_id: int,
    run_id: str,
    initial_connection_id: str,
    omp_identity: dict[str, Any],
    initial_helper_identity: dict[str, Any],
    timeout: float,
) -> dict[str, dict[str, int]]:
    run_id = strict_uuid(run_id, "expected run_id")
    initial_connection_id = strict_uuid(initial_connection_id, "initial connection_id")
    deadline = time.monotonic() + timeout
    stable_identities: dict[str, dict[str, int]] | None = None
    stable_count = 0
    observed_connection_ids: set[str] | None = None

    while time.monotonic() < deadline:
        routing = call(cli, window_id, "__repoprompt_debug_diagnostics", {
            "op": "run_routing_history", "run_id": run_id, "limit": 500,
        }, 10)
        reject_omp_request_timeout(routing, "run routing history")
        routing_events = routing.get("events")
        if not isinstance(routing_events, list):
            raise QualificationError("run routing history events are malformed")
        if len(routing_events) >= 500:
            raise QualificationError("run routing history is truncated")

        connection_ids: set[str] = set()
        identity_events: dict[str, list[dict[str, Any]]] = {}
        for event in routing_events:
            if not isinstance(event, dict) or not isinstance(event.get("event"), str):
                raise QualificationError("run routing history contains a malformed event")
            if not uuid_equal(event.get("run_id"), "routing event run_id", run_id, "expected run_id"):
                raise QualificationError("routing event belongs to a foreign run")
            raw_connection_id = event.get("connection_id")
            if event.get("event") == "client_identity_observed" or raw_connection_id is not None:
                connection_id = strict_uuid(raw_connection_id, "routing connection_id")
                connection_ids.add(connection_id)
                if event.get("event") == "client_identity_observed":
                    identity_events.setdefault(connection_id, []).append(event)
        if observed_connection_ids is not None and not observed_connection_ids.issubset(connection_ids):
            raise QualificationError("run routing history lost an already observed connection")
        observed_connection_ids = set(connection_ids)
        if initial_connection_id not in connection_ids:
            stable_identities = None
            stable_count = 0
            time.sleep(0.1)
            continue

        identities: dict[str, dict[str, int]] = {}
        incomplete = False
        for connection_id in sorted(connection_ids):
            matches = identity_events.get(connection_id, [])
            if len(matches) > 1:
                raise QualificationError("connection has duplicate client identity evidence")
            if not matches:
                incomplete = True
                break
            identities[connection_id] = _routing_connection_identity(matches[0], omp_identity)
        if incomplete:
            stable_identities = None
            stable_count = 0
            time.sleep(0.1)
            continue
        if identities[initial_connection_id] != {
            "pid": initial_helper_identity["pid"],
            "startSeconds": initial_helper_identity["startSeconds"],
            "startMicroseconds": initial_helper_identity["startMicroseconds"],
        }:
            raise QualificationError("initial connection does not identify the exact captured helper")

        if identities == stable_identities:
            stable_count += 1
        else:
            stable_identities = identities
            stable_count = 1
        if stable_count >= 2:
            return identities
        time.sleep(0.1)

    raise QualificationError("run-correlated connection identities did not stabilize")


def _canonical_connection_identities(
    identities: dict[str, dict[str, int]] | None,
) -> dict[str, dict[str, int]] | None:
    if identities is None:
        return None
    canonical: dict[str, dict[str, int]] = {}
    for raw_connection_id, raw_identity in identities.items():
        connection_id = strict_uuid(raw_connection_id, "sealed connection_id")
        if connection_id in canonical:
            raise QualificationError("sealed connection identities contain duplicate connection IDs")
        if not isinstance(raw_identity, dict):
            raise QualificationError("sealed connection identity is malformed")
        identity = {
            "pid": raw_identity.get("pid"),
            "startSeconds": raw_identity.get("startSeconds"),
            "startMicroseconds": raw_identity.get("startMicroseconds"),
        }
        if (
            type(identity["pid"]) is not int
            or identity["pid"] <= 0
            or type(identity["startSeconds"]) is not int
            or identity["startSeconds"] <= 0
            or type(identity["startMicroseconds"]) is not int
            or identity["startMicroseconds"] < 0
        ):
            raise QualificationError("sealed connection identity is malformed")
        canonical[connection_id] = identity
    return canonical


def _cleanup_blocker_summary(
    blocker: str,
    connection_ids: set[str],
    sealed: set[str] | None,
    stable_count: int,
    connection_states: dict[str, dict[str, Any]],
    policy_cleared_count: int,
    expected_pid_cleared_count: int,
) -> dict[str, Any]:
    canonical_ids = sorted(connection_ids)
    return {
        "blocker": blocker,
        "canonical_connection_ids": canonical_ids,
        "canonical_connection_count": len(canonical_ids),
        "sealed_ids": [] if sealed is None else sorted(sealed),
        "sealed_count": 0 if sealed is None else len(sealed),
        "stable_sample_count": stable_count,
        "connections": {
            connection_id: connection_states[connection_id]
            for connection_id in canonical_ids
        },
        "policy_cleared_count": policy_cleared_count,
        "expected_pid_cleared_count": expected_pid_cleared_count,
    }


def verify_cleanup(
    cli: Path,
    window_id: int,
    run_id: str,
    initial_connection_id: str,
    omp_identity: dict[str, Any],
    initial_helper_identity: dict[str, Any],
    timeout: float,
    sealed_connection_identities: dict[str, dict[str, int]] | None = None,
) -> dict[str, Any]:
    run_id = strict_uuid(run_id, "expected run_id")
    initial_connection_id = strict_uuid(initial_connection_id, "initial connection_id")
    expected_identities = _canonical_connection_identities(sealed_connection_identities)
    sealed = None if expected_identities is None else set(expected_identities)
    deadline = time.monotonic() + timeout
    stable_ids: tuple[str, ...] | None = None
    stable_count = 0
    observed_connection_ids: set[str] | None = None
    latest_snapshot: dict[str, Any] | None = None
    last_blocker = _cleanup_blocker_summary(
        "cleanup_not_sampled", set(), sealed, stable_count, {}, 0, 0,
    )

    while time.monotonic() < deadline:
        routing = call(cli, window_id, "__repoprompt_debug_diagnostics", {
            "op": "run_routing_history", "run_id": run_id, "limit": 500,
        }, 10)
        reject_omp_request_timeout(routing, "run routing history")
        routing_events = routing.get("events")
        if not isinstance(routing_events, list):
            raise QualificationError("run routing history events are malformed")
        if len(routing_events) >= 500:
            raise QualificationError("run routing history is truncated")

        connection_ids: set[str] = set()
        for event in routing_events:
            if not isinstance(event, dict) or not isinstance(event.get("event"), str):
                raise QualificationError("run routing history contains a malformed event")
            if not uuid_equal(event.get("run_id"), "routing event run_id", run_id, "expected run_id"):
                raise QualificationError("routing event belongs to a foreign run")
            raw_connection_id = event.get("connection_id")
            if event.get("event") == "client_identity_observed" or raw_connection_id is not None:
                connection_ids.add(strict_uuid(raw_connection_id, "routing connection_id"))
        if (
            sealed is None
            and observed_connection_ids is not None
            and not observed_connection_ids.issubset(connection_ids)
        ):
            raise QualificationError("run routing history lost an already observed connection")
        observed_connection_ids = set(connection_ids)
        names = [event.get("event") for event in routing_events]
        policy_cleared_count = names.count("policy_cleared")
        expected_pid_cleared_count = names.count("expected_pid_cleared")
        state_connection_ids = connection_ids if sealed is None else sealed
        connection_states: dict[str, dict[str, Any]] = {
            connection_id: {
                "identity_present": False,
                "removed_count": 0,
                "raw_in_flight_count": None,
                "active_scope_count": None,
                "initial_tool_activity": False,
            }
            for connection_id in sorted(state_connection_ids)
        }
        if sealed is not None and connection_ids - sealed:
            raise QualificationError("late run-correlated connection appeared after connection-set sealing")
        if sealed is None and initial_connection_id not in connection_ids:
            stable_ids = None
            stable_count = 0
            last_blocker = _cleanup_blocker_summary(
                "initial_connection_missing", connection_ids, sealed, stable_count,
                connection_states, policy_cleared_count, expected_pid_cleared_count,
            )
            time.sleep(0.1)
            continue

        identities = {} if expected_identities is None else dict(expected_identities)
        incomplete = False
        identity_connection_ids: set[str] = set()
        for event in routing_events:
            if event.get("event") != "client_identity_observed":
                continue
            identity_connection_id = strict_uuid(event.get("connection_id"), "identity connection_id")
            identity_connection_ids.add(identity_connection_id)
        for connection_id in sorted(connection_ids if sealed is None else sealed):
            matches = [
                event for event in routing_events
                if event.get("event") == "client_identity_observed"
                and strict_uuid(event.get("connection_id"), "identity connection_id") == connection_id
            ]
            if len(matches) > 1:
                raise QualificationError("connection has duplicate client identity evidence")
            if not matches:
                if expected_identities is not None:
                    continue
                incomplete = True
                last_blocker = _cleanup_blocker_summary(
                    "connection_identity_missing", connection_ids, sealed, 0,
                    connection_states, policy_cleared_count, expected_pid_cleared_count,
                )
                break
            observed_identity = _routing_connection_identity(matches[0], omp_identity)
            if expected_identities is not None and observed_identity != expected_identities[connection_id]:
                raise QualificationError("post-sealing client identity conflicts with captured identity")
            connection_states[connection_id]["identity_present"] = True
            identities[connection_id] = observed_identity
        if identity_connection_ids - set(identities):
            raise QualificationError("late run-correlated connection appeared after connection-set sealing")
        if incomplete:
            stable_ids = None
            stable_count = 0
            time.sleep(0.1)
            continue
        if identities[initial_connection_id] != {
            "pid": initial_helper_identity["pid"],
            "startSeconds": initial_helper_identity["startSeconds"],
            "startMicroseconds": initial_helper_identity["startMicroseconds"],
        }:
            raise QualificationError("initial connection no longer identifies the exact captured helper")

        histories: dict[str, dict[str, Any]] = {}
        initial_tool_activity = False
        verification_connection_ids = connection_ids if sealed is None else sealed
        for connection_id in sorted(verification_connection_ids):
            history = call(cli, window_id, "__repoprompt_debug_diagnostics", {
                "op": "connection_history", "connection_id": connection_id, "limit": 500,
            }, 10)
            reject_omp_request_timeout(history, "connection history")
            events = history.get("events")
            if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
                raise QualificationError("connection history events are malformed")
            if len(events) >= 500:
                raise QualificationError("connection history is truncated")
            removed = [event for event in events if event.get("event") == "removed"]
            connection_states[connection_id]["removed_count"] = len(removed)
            if len(removed) > 1:
                raise QualificationError("connection has duplicate terminal removals")
            if not removed:
                incomplete = True
                last_blocker = _cleanup_blocker_summary(
                    "connection_removal_missing", connection_ids, sealed, 0,
                    connection_states, policy_cleared_count, expected_pid_cleared_count,
                )
                break
            final = removed[0]
            raw_in_flight = final.get("qualification_raw_in_flight_call_count")
            active_scopes = final.get("active_tool_scope_count")
            connection_states[connection_id]["raw_in_flight_count"] = (
                raw_in_flight if type(raw_in_flight) is int else None
            )
            connection_states[connection_id]["active_scope_count"] = (
                active_scopes if type(active_scopes) is int else None
            )
            helper = identities[connection_id]
            if (
                final.get("helper_peer_pid") != helper["pid"]
                or final.get("helper_peer_start_seconds") != helper["startSeconds"]
                or final.get("helper_peer_start_microseconds") != helper["startMicroseconds"]
            ):
                raise QualificationError("terminal removal has mismatched helper identity")
            if (
                final.get("qualification_raw_in_flight_call_count") != 0
                or final.get("active_tool_scope_count") != 0
            ):
                raise QualificationError("terminal connection did not drain raw in-flight/tool-scope state")
            raw_names = final.get("qualification_raw_canonical_tool_names")
            if not isinstance(raw_names, list) or any(not isinstance(name, str) for name in raw_names):
                raise QualificationError("terminal connection canonical tool activity is malformed")
            connection_states[connection_id]["initial_tool_activity"] = "get_file_tree" in raw_names
            if connection_id == initial_connection_id:
                initial_tool_activity = connection_states[connection_id]["initial_tool_activity"]
            histories[connection_id] = history
        if incomplete:
            stable_ids = None
            stable_count = 0
            time.sleep(0.1)
            continue

        if policy_cleared_count > 1 or expected_pid_cleared_count > 1:
            raise QualificationError("run routing has duplicate policy or PID cleanup")
        if policy_cleared_count != 1:
            stable_ids = None
            stable_count = 0
            last_blocker = _cleanup_blocker_summary(
                "policy_cleared_count", connection_ids, sealed, stable_count,
                connection_states, policy_cleared_count, expected_pid_cleared_count,
            )
            time.sleep(0.1)
            continue
        if expected_pid_cleared_count != 1:
            stable_ids = None
            stable_count = 0
            last_blocker = _cleanup_blocker_summary(
                "expected_pid_cleared_count", connection_ids, sealed, stable_count,
                connection_states, policy_cleared_count, expected_pid_cleared_count,
            )
            time.sleep(0.1)
            continue

        current_ids = tuple(sorted(connection_ids if sealed is None else sealed))
        if current_ids == stable_ids:
            stable_count += 1
        else:
            stable_ids = current_ids
            stable_count = 1
        latest_snapshot = {
            "connectionIDs": list(current_ids),
            "capturedConnectionIdentities": identities,
            "connectionHistories": histories,
            "routingHistory": routing,
            "initialHelperCorrelation": initial_tool_activity,
            "connectionSetSealed": True,
        }
        if stable_count >= 2:
            return latest_snapshot
        last_blocker = _cleanup_blocker_summary(
            "unstable_connection_set", connection_ids, sealed, stable_count,
            connection_states, policy_cleared_count, expected_pid_cleared_count,
        )
        time.sleep(0.1)

    raise QualificationError(
        "run-correlated connections did not reach a stable fully drained state; "
        f"last_blocker={json.dumps(last_blocker, sort_keys=True, separators=(',', ':'))}"
    )


def exact_session_ids(
    payload: dict[str, Any],
    workspace_id: str,
    limit: int,
) -> list[str]:
    if type(limit) is not int or limit <= 0:
        raise QualificationError("session list limit is invalid")
    workspace = payload.get("workspace")
    if not isinstance(workspace, dict):
        raise QualificationError("session list workspace is malformed")
    expected_workspace_id = strict_uuid(workspace_id, "expected workspace_id")
    actual_workspace_id = strict_uuid(workspace.get("id"), "session list workspace_id")
    if actual_workspace_id != expected_workspace_id:
        raise QualificationError("session list workspace_id does not match the dedicated workspace")
    sessions = payload.get("sessions")
    if not isinstance(sessions, list):
        raise QualificationError("session list is malformed")
    if len(sessions) >= limit:
        raise QualificationError("session list may be truncated at the requested limit")
    ids: list[str] = []
    for item in sessions:
        if not isinstance(item, dict):
            raise QualificationError("session list contains a malformed item")
        ids.append(strict_uuid(item.get("session_id"), "listed session_id"))
    if len(ids) != len(set(ids)):
        raise QualificationError("session list contains duplicate session IDs")
    return ids


def claim_running_start(start: dict[str, Any], baseline_ids: list[str]) -> tuple[str, str]:
    if start.get("status") != "running":
        raise QualificationError("start did not return an exact running snapshot")
    session_id = strict_uuid(start.get("session_id"), "session_id")
    if session_id in set(baseline_ids):
        raise QualificationError("start returned a session ID already present in the baseline")
    run_id = strict_uuid(start.get("run_id"), "run_id")
    return session_id, run_id


def validate_cleanup_receipt(payload: dict[str, Any], session_id: str) -> None:
    if (
        payload.get("status") != "completed"
        or type(payload.get("deleted_count")) is not int
        or payload.get("deleted_count") != 1
        or type(payload.get("skipped_count")) is not int
        or payload.get("skipped_count") != 0
        or payload.get("skipped_sessions") != []
    ):
        raise QualificationError("exact qualification session cleanup failed")
    deleted = payload.get("deleted_sessions")
    if not isinstance(deleted, list) or len(deleted) != 1 or not isinstance(deleted[0], dict):
        raise QualificationError("cleanup receipt did not identify exactly one deleted session")
    if not uuid_equal(
        deleted[0].get("session_id"),
        "deleted session_id",
        session_id,
        "expected deleted session_id",
    ):
        raise QualificationError("cleanup receipt identified the wrong deleted session")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--scratch-workspace", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--scenario", choices=("cancel", "kill-omp", "kill-helper"), required=True)
    parser.add_argument("--output-parent", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--confirm-dedicated-scratch-window", action="store_true", required=True)
    args = parser.parse_args()
    lease_id: str | None = None
    session_id: str | None = None
    run_id: str | None = None
    evidence_dir: Path | None = None
    session_cleanup_completed = False
    try:
        if args.window_id <= 0 or args.timeout < 30 or not args.cli.is_absolute() or not args.cli.is_file():
            raise QualificationError("CLI/window/timeout arguments are invalid")
        if not args.model_id.startswith("ohMyPi:") or args.model_id == "ohMyPi:":
            raise QualificationError("model-id must be one exact OMP model identifier")
        workspace_id = strict_uuid(args.workspace_id, "workspace_id")
        scratch = args.scratch_workspace.resolve(strict=True)
        parent = args.output_parent.resolve(strict=True)
        if not scratch.is_dir() or not parent.is_dir():
            raise QualificationError("scratch workspace and output parent must be existing directories")
        verify_dedicated_scratch_window(args.cli, args.window_id, workspace_id, scratch, parent, args.timeout)
        evidence_dir = Path(os.path.realpath(Path(os.path.join(parent, f"omp-managed-cleanup-{uuid.uuid4()}"))))
        evidence_dir.mkdir(mode=0o700)

        session_list_limit = 1000
        baseline = call(args.cli, args.window_id, "agent_manage", {
            "op": "list_sessions", "workspace_id": workspace_id, "limit": session_list_limit,
        }, 30)
        baseline_ids = exact_session_ids(baseline, workspace_id, session_list_limit)
        lease = call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "acquire", "owner_pid": os.getpid(),
            "duration_seconds": min(600, max(60, int(args.timeout) + 60)),
        }, 30)
        lease_id = strict_uuid(lease.get("lease_id"), "lease_id")
        start = call(args.cli, args.window_id, "agent_run", {
            "op": "start", "model_id": args.model_id, "workspace_id": workspace_id,
            "_omp_qualification_lease_id": lease_id, "detach": True,
            "session_name": f"PRIVATE OMP cleanup qualification: {args.scenario}",
            "message": f"Call mcp__RepoPromptCE__get_file_tree exactly once on the dedicated scratch workspace, then reply {OMP_MANAGED_CLEANUP_OK}.",
        }, 60)
        session_id, run_id = claim_running_start(start, baseline_ids)

        bound = call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "status",
        }, 30)
        validate_bound_lease(bound, lease_id, session_id, run_id, "delivered start response")

        routing = wait_routing(args.cli, args.window_id, run_id, args.timeout)
        events = routing.get("events")
        assert isinstance(events, list)
        connection_id, omp, helper = captured_processes(events, run_id)
        helper_signal_succeeded = False
        if args.scenario == "cancel":
            cancelled = call(args.cli, args.window_id, "agent_run", {
                "op": "cancel", "session_id": session_id, "run_id": run_id,
            }, 30)
            if cancelled.get("status") != "cancelled":
                raise QualificationError("exact run cancellation was not accepted")
        elif args.scenario == "kill-omp":
            spike.signal_exact_captured_process(omp, signal.SIGKILL)
        else:
            spike.signal_exact_captured_process(helper, signal.SIGKILL)
            helper_signal_succeeded = True

        terminal = wait_terminal(
            args.cli, args.window_id, session_id, allowed_terminal_statuses(args.scenario), args.timeout,
        )
        drain_phase = terminal_drain_phase(args.scenario, terminal)
        first_cleanup: dict[str, Any] | None = None
        sealed_connection_identities: dict[str, dict[str, int]] | None = None
        if drain_phase == "pre-session-cleanup":
            first_cleanup = verify_cleanup(
                args.cli, args.window_id, run_id, connection_id, omp, helper, args.timeout,
            )
            sealed_connection_identities = first_cleanup["capturedConnectionIdentities"]
        else:
            sealed_connection_identities = capture_stable_connection_identities(
                args.cli, args.window_id, run_id, connection_id, omp, helper, args.timeout,
            )
        terminal_classification = validate_terminal_outcome(
            args.scenario,
            terminal,
            helper_signal_succeeded=helper_signal_succeeded,
            cleanup_snapshot=first_cleanup,
        )
        before_cleanup = call(args.cli, args.window_id, "agent_manage", {
            "op": "list_sessions", "workspace_id": workspace_id, "limit": session_list_limit,
        }, 30)
        before_cleanup_ids = exact_session_ids(before_cleanup, workspace_id, session_list_limit)
        if set(before_cleanup_ids) != set(baseline_ids) | {session_id}:
            raise QualificationError("pre-cleanup agent set was not baseline plus exact qualification session")

        cleanup = call(args.cli, args.window_id, "agent_manage", {
            "op": "cleanup_sessions", "session_ids": [session_id],
        }, 30)
        validate_cleanup_receipt(cleanup, session_id)
        session_cleanup_completed = True
        after_cleanup = call(args.cli, args.window_id, "agent_manage", {
            "op": "list_sessions", "workspace_id": workspace_id, "limit": session_list_limit,
        }, 30)
        after_cleanup_ids = exact_session_ids(after_cleanup, workspace_id, session_list_limit)
        if set(after_cleanup_ids) != set(baseline_ids):
            raise QualificationError("post-cleanup agent set did not exactly restore the baseline")
        if drain_phase == "post-session-cleanup":
            assert sealed_connection_identities is not None
            first_cleanup = verify_cleanup(
                args.cli,
                args.window_id,
                run_id,
                connection_id,
                omp,
                helper,
                args.timeout,
                sealed_connection_identities=sealed_connection_identities,
            )
        assert first_cleanup is not None
        successor_cleanup = verify_successor_isolation(
            args.cli,
            args.window_id,
            run_id,
            connection_id,
            omp,
            helper,
            args.timeout,
            first_cleanup,
        )
        pre_release = call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "status",
        }, 30)
        validate_bound_lease(pre_release, lease_id, session_id, run_id, "pre-release lease")
        released = call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "release", "lease_id": lease_id, "owner_pid": os.getpid(),
        }, 30)
        lease_id = None
        if released.get("active") is not False:
            raise QualificationError("exact lease release did not report inactive")
        inactive = call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
            "op": "omp_qualification_lease", "action": "status",
        }, 30)
        if inactive.get("active") is not False:
            raise QualificationError("qualification lease remained active")

        captured_connection_ids = first_cleanup["connectionIDs"]
        evidence = {
            "scenario": args.scenario,
            "workspaceID": workspace_id,
            "sessionID": session_id,
            "runID": run_id,
            "connectionID": connection_id,
            "terminalOutcomeClassification": terminal_classification,
            "terminalDrainBegan": drain_phase,
            "capturedConnectionIDs": captured_connection_ids,
            "capturedConnectionCount": len(captured_connection_ids),
            "connectionSetSealed": successor_cleanup["connectionSetSealed"],
            "leaseInactive": inactive.get("active") is False,
            "successorIsolation": True,
        }
        spike.write_json_atomically(evidence_dir / "summary.json", evidence)
        print(f"OMP_MANAGED_CLEANUP_EVIDENCE_DIR={evidence_dir}")
        return 0
    except (QualificationError, support.SupportError, spike.ProbeError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    finally:
        if session_id is not None and not session_cleanup_completed:
            if run_id is not None:
                try:
                    call(args.cli, args.window_id, "agent_run", {
                        "op": "cancel", "session_id": session_id, "run_id": run_id,
                    }, 30)
                except BaseException as error:
                    print(f"ERROR: emergency exact-run cancellation failed: {error}", file=sys.stderr)
            try:
                call(args.cli, args.window_id, "agent_manage", {
                    "op": "cleanup_sessions", "session_ids": [session_id],
                }, 30)
            except BaseException as error:
                print(f"ERROR: emergency exact-session cleanup failed: {error}", file=sys.stderr)
        if lease_id is not None:
            try:
                call(args.cli, args.window_id, "__repoprompt_debug_diagnostics", {
                    "op": "omp_qualification_lease", "action": "release", "lease_id": lease_id, "owner_pid": os.getpid(),
                }, 30)
            except BaseException as error:
                print(f"ERROR: emergency exact lease release failed: {error}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
