#!/usr/bin/env bash
set -euo pipefail

LEASE_OP="omp_qualification_lease"
ACK="OMP_AGENT_MODE_SMOKE_OK"
OMP_CLIENT_NAME="omp-coding-agent"
WINDOW_ID=""
MODEL_ID=""
OUTPUT_PARENT="/tmp"
TIMEOUT_SECONDS="180"
LEASE_MARGIN_SECONDS="120"
WAIT_CLI_MARGIN_SECONDS="30"
MAX_TIMEOUT_SECONDS="480"
MAX_BOOKKEEPING_RAW_CALLS="64"
EVIDENCE_DIR=""
CLI=""
PYTHON=""
SUPPORT=""
LEASE_ID=""
SESSION_ID=""
RUN_ID=""
START_AGENT_MODEL=""
RUN_COMPLETED=0
SESSION_CLEANUP_COMPLETED=0

usage() {
  cat <<'EOF'
Usage: smoke_omp_agent_mode.sh --window-id <positive-int> --model-id <exact-ohMyPi-model-id> [--output-parent <existing-dir>] [--timeout <10-480>]

Runs one fresh, detached, no-edit OMP Agent Mode smoke against an already-running RepoPrompt DEBUG app.
It never launches, stops, relaunches, resumes, or switches workspaces.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-id)
      [[ $# -ge 2 ]] || fail "--window-id requires a value."
      WINDOW_ID="$2"
      shift 2
      ;;
    --model-id)
      [[ $# -ge 2 ]] || fail "--model-id requires a value."
      MODEL_ID="$2"
      shift 2
      ;;
    --output-parent)
      [[ $# -ge 2 ]] || fail "--output-parent requires a value."
      OUTPUT_PARENT="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout requires a value."
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument '$1'."
      ;;
  esac
done

[[ "$WINDOW_ID" =~ ^[1-9][0-9]*$ ]] || fail "--window-id must be a positive integer."
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail "--timeout must be an integer."
(( TIMEOUT_SECONDS >= 10 && TIMEOUT_SECONDS <= MAX_TIMEOUT_SECONDS )) || fail "--timeout must be in 10...480 seconds."
[[ "$MODEL_ID" == ohMyPi:* && "$MODEL_ID" != "ohMyPi:" ]] || fail "--model-id must be the caller-provided exact OMP model_id beginning with 'ohMyPi:'."

PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || fail "Python 3 is required."
CLI="$(command -v rpce-cli-debug || true)"
[[ -n "$CLI" ]] || fail "rpce-cli-debug is required; install the current CE DEBUG CLI first."
[[ -d "$OUTPUT_PARENT" ]] || fail "--output-parent must be an existing directory."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SUPPORT="$SCRIPT_DIR/omp_qualification_support.py"
[[ -f "$SUPPORT" ]] || fail "The bounded OMP qualification support module is missing."
OUTPUT_PARENT="$("$PYTHON" - "$OUTPUT_PARENT" "$REPO_ROOT" <<'PY'
import os
import sys
parent = os.path.realpath(sys.argv[1])
repo = os.path.realpath(sys.argv[2])
if os.path.commonpath([parent, repo]) == repo:
    raise SystemExit(2)
print(parent)
PY
)" || fail "--output-parent must resolve outside the repository."
[[ -w "$OUTPUT_PARENT" ]] || fail "--output-parent is not writable."

umask 077

try_call_tool() {
  local tool="$1"
  local args_json="$2"
  local output_path="$3"
  local call_timeout="${4:-$TIMEOUT_SECONDS}"
  local raw_path="$EVIDENCE_DIR/.response.$$.raw.json"
  local temp_path="$EVIDENCE_DIR/.response.$$.json"
  local error_path="$EVIDENCE_DIR/.response.$$.stderr"
  rm -f "$raw_path" "$temp_path" "$error_path"
  if ! "$PYTHON" "$SUPPORT" run-cli "$CLI" "$WINDOW_ID" "$tool" "$args_json" "$raw_path" "$error_path" "$call_timeout"; then
    rm -f "$raw_path" "$temp_path" "$error_path"
    return 1
  fi
  if ! "$PYTHON" "$SUPPORT" normalize-response "$raw_path" "$temp_path" "$tool" "$args_json"; then
    rm -f "$raw_path" "$temp_path" "$error_path"
    return 2
  fi
  rm -f "$raw_path" "$error_path"
  mv "$temp_path" "$output_path"
  chmod 600 "$output_path"
}

call_tool() {
  local tool="$1"
  if ! try_call_tool "$@"; then
    fail "$tool call failed, overflowed, timed out, or returned an invalid JSON response envelope."
  fi
}

"$PYTHON" "$SUPPORT" preflight-routing "$CLI" "$WINDOW_ID" "$OUTPUT_PARENT" "$TIMEOUT_SECONDS" \
  || fail "Active workspace discovery or overlap preflight failed."

EVIDENCE_DIR="$(mktemp -d "$OUTPUT_PARENT/omp-agent-mode-smoke.XXXXXX")"
chmod 700 "$EVIDENCE_DIR"
printf 'OMP_AGENT_MODE_EVIDENCE_DIR=%s\n' "$EVIDENCE_DIR"

cleanup_call_tool() {
  local action="$1"
  shift
  if ! (call_tool "$@"); then
    printf 'ERROR: cleanup action %s failed; continuing remaining cleanup.\n' "$action" >&2
    return 1
  fi
}

cleanup_exact_session() {
  local cleanup_args
  cleanup_args="$("$PYTHON" - "$SESSION_ID" <<'PY'
import json
import sys
print(json.dumps({
    "op": "cleanup_sessions",
    "session_ids": [sys.argv[1]],
}, separators=(",", ":")))
PY
)"
  if ! cleanup_call_tool exact-session agent_manage "$cleanup_args" "$EVIDENCE_DIR/session_cleanup.json"; then
    return 1
  fi
  if ! "$PYTHON" - "$EVIDENCE_DIR/session_cleanup.json" "$SESSION_ID" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
try:
    expected_session_id = str(uuid.UUID(sys.argv[2]))
except Exception:
    raise SystemExit(2)
deleted = value.get("deleted_sessions")
skipped = value.get("skipped_sessions")
if (
    value.get("status") != "completed"
    or type(value.get("deleted_count")) is not int
    or value.get("deleted_count") != 1
    or type(value.get("skipped_count")) is not int
    or value.get("skipped_count") != 0
    or not isinstance(deleted, list)
    or len(deleted) != 1
    or not isinstance(deleted[0], dict)
    or not isinstance(deleted[0].get("name"), str)
    or not deleted[0]["name"]
    or skipped != []
):
    raise SystemExit(2)
try:
    deleted_session_id = str(uuid.UUID(deleted[0].get("session_id")))
except Exception:
    raise SystemExit(2)
if deleted_session_id != expected_session_id:
    raise SystemExit(2)
PY
  then
    printf 'ERROR: exact-session cleanup did not prove deletion of only session %s; continuing remaining cleanup.\n' "$SESSION_ID" >&2
    return 1
  fi
  SESSION_CLEANUP_COMPLETED=1
}

recover_rejected_acquire() {
  local status_path="$EVIDENCE_DIR/lease_acquire_recovery_status.json"
  local release_path="$EVIDENCE_DIR/lease_acquire_recovery_release.json"
  local inactive_path="$EVIDENCE_DIR/lease_acquire_recovery_inactive.json"
  if ! cleanup_call_tool acquire-recovery-status __repoprompt_debug_diagnostics \
    '{"op":"omp_qualification_lease","action":"status"}' "$status_path"; then
    return 1
  fi

  local recovery_result
  if ! recovery_result="$("$PYTHON" - "$status_path" "$$" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("ok") is not True:
    raise SystemExit(2)
if value.get("active") is False:
    print("inactive")
    raise SystemExit(0)
if value.get("active") is not True or value.get("owner_pid") != int(sys.argv[2]):
    raise SystemExit(3)
try:
    lease_id = str(uuid.UUID(value.get("lease_id")))
except Exception:
    raise SystemExit(2)
if not isinstance(value.get("owner_process_start_seconds"), int) or not isinstance(
    value.get("owner_process_start_microseconds"), int
):
    raise SystemExit(2)
print(lease_id)
PY
  )"; then
    return 2
  fi
  if [[ "$recovery_result" == "inactive" ]]; then
    return 0
  fi

  LEASE_ID="$recovery_result"
  local release_args
  release_args="$("$PYTHON" - "$LEASE_ID" "$$" <<'PY'
import json
import sys
print(json.dumps({
    "op": "omp_qualification_lease",
    "action": "release",
    "lease_id": sys.argv[1],
    "owner_pid": int(sys.argv[2]),
}, separators=(",", ":")))
PY
  )"
  cleanup_call_tool acquire-recovery-release __repoprompt_debug_diagnostics \
    "$release_args" "$release_path" || return 1
  cleanup_call_tool acquire-recovery-inactive __repoprompt_debug_diagnostics \
    '{"op":"omp_qualification_lease","action":"status"}' "$inactive_path" || return 1
  if ! "$PYTHON" - "$inactive_path" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("ok") is not True or value.get("active") is not False:
    raise SystemExit(2)
PY
  then
    return 1
  fi
  LEASE_ID=""
}

cleanup_qualification() {
  local original_status=$?
  local cleanup_failed=0
  trap - EXIT
  set +e

  if [[ -n "$SESSION_ID" && -n "$RUN_ID" && "$RUN_ID" != "MISSING" && "$RUN_COMPLETED" != "1" ]]; then
    local cancel_args
    cancel_args="$("$PYTHON" - "$SESSION_ID" "$RUN_ID" <<'PY'
import json
import sys
print(json.dumps({
    "op": "cancel",
    "session_id": sys.argv[1],
    "run_id": sys.argv[2],
}, separators=(",", ":")))
PY
)"
    cleanup_call_tool cancel agent_run "$cancel_args" "$EVIDENCE_DIR/run_cleanup_cancel.json" || cleanup_failed=1
  fi

  if [[ -n "$SESSION_ID" && "$SESSION_CLEANUP_COMPLETED" != "1" ]]; then
    cleanup_exact_session || cleanup_failed=1
  fi

  if [[ -n "$LEASE_ID" ]]; then
    local release_args
    release_args="$("$PYTHON" - "$LEASE_ID" "$$" <<'PY'
import json
import sys
print(json.dumps({
    "op": "omp_qualification_lease",
    "action": "release",
    "lease_id": sys.argv[1],
    "owner_pid": int(sys.argv[2]),
}, separators=(",", ":")))
PY
)"
    cleanup_call_tool release __repoprompt_debug_diagnostics "$release_args" "$EVIDENCE_DIR/lease_cleanup_release.json" || cleanup_failed=1
  fi

  if cleanup_call_tool status __repoprompt_debug_diagnostics '{"op":"omp_qualification_lease","action":"status"}' "$EVIDENCE_DIR/lease_cleanup_status.json"; then
    if ! "$PYTHON" - "$EVIDENCE_DIR/lease_cleanup_status.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("ok") is not True or value.get("active") is not False:
    raise SystemExit(2)
PY
    then
      printf 'ERROR: OMP qualification lease cleanup was not authoritatively verified disabled.\n' >&2
      cleanup_failed=1
    fi
  else
    cleanup_failed=1
  fi
  if (( cleanup_failed != 0 )); then
    original_status=1
  fi
  exit "$original_status"
}
trap cleanup_qualification EXIT

"$PYTHON" - "$EVIDENCE_DIR/manifest.json" "$WINDOW_ID" "$MODEL_ID" <<'PY'
import json
import sys
manifest = {
    "evidence_kind": "omp_agent_mode_live_qualification",
    "classification": "private",
    "scenario": "synthetic_deterministic_no_edit_acknowledgement",
    "window_id": int(sys.argv[2]),
    "caller_supplied_exact_model_id": sys.argv[3],
    "contains_raw_credentials_or_tokens": False,
    "resume_used": False,
    "workspace_switch_used": False,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
chmod 600 "$EVIDENCE_DIR/manifest.json"

call_tool __repoprompt_debug_diagnostics '{"op":"routing_snapshot","include_records":false,"include_windows":true}' "$EVIDENCE_DIR/workspace_before_raw.json"
"$PYTHON" "$SUPPORT" snapshot "$EVIDENCE_DIR/workspace_before_raw.json" "$EVIDENCE_DIR/workspace_before.json" "$WINDOW_ID" "$EVIDENCE_DIR" \
  || fail "Target workspace identity, overlap check, or bounded content snapshot failed."
rm -f "$EVIDENCE_DIR/workspace_before_raw.json"
WORKSPACE_ID="$("$PYTHON" - "$EVIDENCE_DIR/workspace_before.json" "$WINDOW_ID" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
target = value.get("qualification_target")
if not isinstance(target, dict) or target.get("window_id") != int(sys.argv[2]):
    raise SystemExit(2)
try:
    workspace_id = str(uuid.UUID(target.get("workspace_id")))
except Exception:
    raise SystemExit(2)
print(workspace_id)
PY
)" || fail "The fingerprinted qualification target did not expose one exact workspace UUID."

call_tool __repoprompt_debug_diagnostics '{"op":"routing_sequence_baseline"}' "$EVIDENCE_DIR/routing_baseline.json"

LEASE_ARGS="$("$PYTHON" - "$$" "$TIMEOUT_SECONDS" "$LEASE_MARGIN_SECONDS" <<'PY'
import json
import sys
duration = int(sys.argv[2]) + int(sys.argv[3])
if duration > 600:
    raise SystemExit(2)
print(json.dumps({
    "op": "omp_qualification_lease",
    "action": "acquire",
    "owner_pid": int(sys.argv[1]),
    "duration_seconds": duration,
}, separators=(",", ":")))
PY
)"
ACQUIRE_FAILURE=""
if ! try_call_tool __repoprompt_debug_diagnostics "$LEASE_ARGS" "$EVIDENCE_DIR/lease_acquire.json"; then
  ACQUIRE_FAILURE="The exclusive process-owned OMP qualification lease response was lost or unparseable."
elif ! LEASE_ID="$("$PYTHON" - "$EVIDENCE_DIR/lease_acquire.json" "$$" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
try:
    lease_id = str(uuid.UUID(value.get("lease_id")))
except Exception:
    raise SystemExit(2)
if (
    value.get("ok") is not True
    or value.get("op") != "omp_qualification_lease"
    or value.get("action") != "acquire"
    or value.get("active") is not True
    or value.get("owner_pid") != int(sys.argv[2])
    or not isinstance(value.get("owner_process_start_seconds"), int)
    or not isinstance(value.get("owner_process_start_microseconds"), int)
):
    raise SystemExit(2)
print(lease_id)
PY
)"; then
  ACQUIRE_FAILURE="The exclusive process-owned OMP qualification lease response failed local validation."
fi
if [[ -n "$ACQUIRE_FAILURE" ]]; then
  recovery_status=0
  recover_rejected_acquire || recovery_status=$?
  if (( recovery_status == 2 )); then
    fail "$ACQUIRE_FAILURE Authoritative status did not match the active controller-owned lease; refusing to release another process's lease."
  elif (( recovery_status != 0 )); then
    fail "$ACQUIRE_FAILURE Authoritative recovery did not prove a matching controller-owned lease was released and inactive."
  fi
  fail "$ACQUIRE_FAILURE The matching controller-owned lease was released and verified inactive."
fi

call_tool agent_manage '{"op":"list_agents"}' "$EVIDENCE_DIR/list_agents.json"
"$PYTHON" - "$EVIDENCE_DIR/list_agents.json" "$MODEL_ID" <<'PY' || fail "list_agents did not advertise the caller-provided exact OMP model_id as available."
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
model_id = sys.argv[2]
matches = []
for agent in value.get("agents", []):
    if agent.get("available") is True and agent.get("name") == "Oh My Pi":
        matches.extend(model for model in agent.get("models", []) if model.get("model_id") == model_id and model.get("agent_id") == "ohMyPi")
if len(matches) != 1:
    raise SystemExit(2)
PY

START_ARGS="$("$PYTHON" - "$MODEL_ID" "$ACK" "$LEASE_ID" "$WORKSPACE_ID" <<'PY'
import json
import sys
print(json.dumps({
    "op": "start",
    "model_id": sys.argv[1],
    "_omp_qualification_lease_id": sys.argv[3],
    "workspace_id": sys.argv[4],
    "session_name": "PRIVATE SYNTHETIC OMP Agent Mode smoke",
    "message": f"Reply exactly with {sys.argv[2]} and stop. Do not call tools. Do not edit files.",
    "detach": True,
}, separators=(",", ":")))
PY
)"
call_tool agent_run "$START_ARGS" "$EVIDENCE_DIR/start.json"

SESSION_ID="$("$PYTHON" - "$EVIDENCE_DIR/start.json" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
session_id = value.get("session_id")
if not isinstance(session_id, str) or not session_id:
    raise SystemExit(2)
try:
    uuid.UUID(session_id)
except Exception:
    raise SystemExit(2)
print(session_id)
PY
)" || fail "agent_run start did not expose a valid session_id."

RUN_ID="$("$PYTHON" - "$EVIDENCE_DIR/start.json" <<'PY'
import json
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
run_id = value.get("run_id")
if not run_id:
    print("MISSING")
    raise SystemExit(0)
if not isinstance(run_id, str):
    raise SystemExit(2)
try:
    uuid.UUID(run_id)
except Exception:
    raise SystemExit(2)
print(run_id)
PY
)" || fail "agent_run start returned an invalid run_id."

[[ "$RUN_ID" != "MISSING" ]] || fail "agent_run start did not expose an authoritative run_id; run_routing_history cannot be correlated safely. Update the app/CLI response contract before retrying."

START_AGENT_MODEL="$("$PYTHON" - "$EVIDENCE_DIR/start.json" "$SESSION_ID" "$RUN_ID" "$MODEL_ID" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
agent = value.get("agent")
requested_model = sys.argv[4].split(":", 1)[1]
if (
    value.get("status") not in {"starting", "running", "completed"}
    or value.get("session_id") != sys.argv[2]
    or value.get("run_id") != sys.argv[3]
    or not isinstance(agent, dict)
    or agent.get("id") != "ohMyPi"
):
    raise SystemExit(2)
agent_model = agent.get("model")
if requested_model == "default":
    if agent_model != "default" and not (
        isinstance(agent_model, str) and "/" in agent_model and all(agent_model.split("/", 1))
    ):
        raise SystemExit(2)
elif agent_model != requested_model:
    raise SystemExit(2)
print(agent_model)
PY
)" || fail "agent_run start returned an invalid status or agent/model qualification."

WAIT_ARGS="$("$PYTHON" - "$SESSION_ID" "$TIMEOUT_SECONDS" <<'PY'
import json
import sys
print(json.dumps({
    "op": "wait",
    "session_id": sys.argv[1],
    "timeout": int(sys.argv[2]),
}, separators=(",", ":")))
PY
)"
call_tool agent_run "$WAIT_ARGS" "$EVIDENCE_DIR/wait.json" "$((TIMEOUT_SECONDS + WAIT_CLI_MARGIN_SECONDS))"
WAIT_RESULT="$($PYTHON - "$EVIDENCE_DIR/wait.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print(value.get("_meta", {}).get("wait_result", ""))
PY
)"
[[ "$WAIT_RESULT" != "timed_out" ]] || fail "agent_run wait returned app-side wait_result=timed_out."
WAIT_STATUS="$("$PYTHON" - "$EVIDENCE_DIR/wait.json" "$SESSION_ID" "$RUN_ID" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
status = value.get("status")
if (
    not isinstance(status, str)
    or value.get("session_id") != sys.argv[2]
    or value.get("run_id") != sys.argv[3]
):
    raise SystemExit(2)
print(status)
PY
)" || fail "agent_run wait returned mismatched identifiers or an invalid status."
if [[ "$WAIT_STATUS" == "completed" ]]; then
  RUN_COMPLETED=1
else
  fail "agent_run wait did not reach completed status."
fi

"$PYTHON" - "$EVIDENCE_DIR/wait.json" "$SESSION_ID" "$RUN_ID" "$ACK" "$MODEL_ID" "$START_AGENT_MODEL" <<'PY' || fail "agent_run wait did not complete with the exact deterministic acknowledgement and correlated model."
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
agent = value.get("agent")
requested_model = sys.argv[5].split(":", 1)[1]
start_model = sys.argv[6]
if (
    value.get("status") != "completed"
    or value.get("session_id") != sys.argv[2]
    or value.get("run_id") != sys.argv[3]
    or value.get("assistant_text") != sys.argv[4]
    or not isinstance(agent, dict)
    or agent.get("id") != "ohMyPi"
):
    raise SystemExit(2)
wait_model = agent.get("model")
if requested_model == "default":
    wait_is_concrete = (
        isinstance(wait_model, str) and "/" in wait_model and all(wait_model.split("/", 1))
    )
    if not wait_is_concrete or (start_model != "default" and wait_model != start_model):
        raise SystemExit(2)
elif start_model != requested_model or wait_model != requested_model:
    raise SystemExit(2)
PY

call_tool __repoprompt_debug_diagnostics '{"op":"routing_snapshot","include_records":false,"include_windows":true}' "$EVIDENCE_DIR/workspace_after_raw.json"
"$PYTHON" "$SUPPORT" snapshot "$EVIDENCE_DIR/workspace_after_raw.json" "$EVIDENCE_DIR/workspace_after.json" "$WINDOW_ID" "$EVIDENCE_DIR" \
  || fail "The post-run workspace identity, overlap check, or bounded content snapshot failed."
rm -f "$EVIDENCE_DIR/workspace_after_raw.json"
"$PYTHON" - "$EVIDENCE_DIR/workspace_before.json" "$EVIDENCE_DIR/workspace_after.json" <<'PY' \
  || fail "Workspace identity or tracked/index/existing-untracked content changed during the OMP run."
import json
import os
import sys
import uuid
with open(sys.argv[1], encoding="utf-8") as handle:
    before = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    after = json.load(handle)

def stable_target(value):
    if not isinstance(value, dict):
        raise SystemExit(2)
    window_id = value.get("window_id")
    workspace_id = value.get("workspace_id")
    workspace_instance_number = value.get("workspace_instance_number")
    repo_paths = value.get("repo_paths")
    if (
        type(window_id) is not int
        or window_id <= 0
        or not isinstance(workspace_id, str)
        or type(workspace_instance_number) is not int
        or workspace_instance_number <= 0
        or not isinstance(repo_paths, list)
        or not repo_paths
        or any(not isinstance(path, str) or not path or not os.path.isabs(path) for path in repo_paths)
    ):
        raise SystemExit(2)
    try:
        canonical_workspace_id = str(uuid.UUID(workspace_id))
    except Exception:
        raise SystemExit(2)
    if workspace_id != canonical_workspace_id:
        raise SystemExit(2)
    return {
        "window_id": window_id,
        "workspace_id": canonical_workspace_id,
        "workspace_instance_number": workspace_instance_number,
        "repo_paths": repo_paths,
    }

before_snapshots = before.get("active_workspace_content_snapshots")
after_snapshots = after.get("active_workspace_content_snapshots")
if (
    not isinstance(before_snapshots, dict)
    or not isinstance(after_snapshots, dict)
    or stable_target(after.get("qualification_target")) != stable_target(before.get("qualification_target"))
    or after_snapshots != before_snapshots
):
    raise SystemExit(2)
PY

ROUTING_ARGS="$("$PYTHON" - "$RUN_ID" <<'PY'
import json
import sys
print(json.dumps({"op": "run_routing_history", "run_id": sys.argv[1], "limit": 500}, separators=(",", ":")))
PY
)"
call_tool __repoprompt_debug_diagnostics "$ROUTING_ARGS" "$EVIDENCE_DIR/run_routing_history.json"
ROUTING_IDENTIFIERS="$("$PYTHON" - "$EVIDENCE_DIR/run_routing_history.json" "$EVIDENCE_DIR/routing_baseline.json" "$RUN_ID" "$OMP_CLIENT_NAME" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    baseline = json.load(handle)
if value.get("ok") is not True or value.get("run_id") != sys.argv[3] or value.get("dropped_event_count") != 0:
    raise SystemExit(2)
events = value.get("events")
baseline_seq = baseline.get("run_routing_sequence")
if not isinstance(events, list) or not events or not isinstance(baseline_seq, int):
    raise SystemExit(2)
if any(event.get("run_id") != sys.argv[3] or not isinstance(event.get("seq"), int) or event["seq"] <= baseline_seq for event in events):
    raise SystemExit(2)
if any(left["seq"] >= right["seq"] for left, right in zip(events, events[1:])):
    raise SystemExit(2)
forbidden = {"tool_call_observed", "policy_rejected", "pid_gate_wait_rejected", "run_route_mapping_failed"}
if any(event.get("event") in forbidden or "timeout" in str(event.get("event")) for event in events):
    raise SystemExit(2)
ordered = [
    "policy_installed",
    "expected_pid_policy_armed",
    "expected_pid_registered",
    "client_identity_observed",
    "run_route_mapped",
    "routing_waiter_signalled",
    "policy_applied",
    "route_wait_completed",
]
positions = []
for name in ordered:
    matches = [index for index, event in enumerate(events) if event.get("event") == name]
    if len(matches) != 1:
        raise SystemExit(2)
    positions.append(matches[0])
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit(2)
pid_gate_started = [index for index, event in enumerate(events) if event.get("event") == "pid_gate_wait_started"]
pid_gate_completed = [index for index, event in enumerate(events) if event.get("event") == "pid_gate_wait_completed"]
if pid_gate_started or pid_gate_completed:
    if (
        len(pid_gate_started) != 1
        or len(pid_gate_completed) != 1
        or pid_gate_started[0] >= pid_gate_completed[0]
        or pid_gate_completed[0] >= positions[4]
    ):
        raise SystemExit(2)
identity = events[positions[3]]
fields = identity.get("fields", {})
if fields.get("verified_client_name") != sys.argv[4]:
    raise SystemExit(2)
connection_id = identity.get("connection_id")
helper_pid = fields.get("helper_peer_pid")
expected_pid = events[positions[2]].get("fields", {}).get("expected_pid")
def canonical_decimal(value, *, positive=False, microseconds=False):
    if not isinstance(value, str) or not value.isascii() or not value.isdecimal():
        raise SystemExit(2)
    if len(value) > 1 and value.startswith("0"):
        raise SystemExit(2)
    parsed = int(value)
    if positive and parsed <= 0:
        raise SystemExit(2)
    if microseconds and not 0 <= parsed < 1_000_000:
        raise SystemExit(2)
    return parsed
helper_pid = canonical_decimal(helper_pid, positive=True)
expected_pid = canonical_decimal(expected_pid, positive=True)
matched_expected_start_seconds = canonical_decimal(fields.get("matched_expected_start_seconds"), positive=True)
matched_expected_start_microseconds = canonical_decimal(fields.get("matched_expected_start_microseconds"), microseconds=True)
helper_start_seconds = canonical_decimal(fields.get("helper_process_start_seconds"), positive=True)
helper_start_microseconds = canonical_decimal(fields.get("helper_process_start_microseconds"), microseconds=True)
if (
    not connection_id
    or not helper_pid
    or not expected_pid
    or helper_pid == expected_pid
    or fields.get("process_correlation_ok") != "true"
    or fields.get("matched_expected_pid") != str(expected_pid)
    or fields.get("omp_current_executable_identity_match") != "true"
    or fields.get("helper_bundled_identity_match") != "true"
    or fields.get("helper_current_executable_identity_match") != "true"
    or fields.get("helper_strict_descendant") != "true"
    or fields.get("matched_expected_start_seconds") != str(matched_expected_start_seconds)
    or fields.get("matched_expected_start_microseconds") != str(matched_expected_start_microseconds)
    or not fields.get("matched_expected_executable_path")
    or fields.get("helper_process_start_seconds") != str(helper_start_seconds)
    or fields.get("helper_process_start_microseconds") != str(helper_start_microseconds)
    or not fields.get("helper_executable_path")
):
    raise SystemExit(2)
correlated = [event.get("connection_id") for event in events if event.get("connection_id") is not None]
if any(candidate != connection_id for candidate in correlated):
    raise SystemExit(2)
if events[positions[1]].get("fields", {}).get("armed") != "true":
    raise SystemExit(2)
if events[positions[5]].get("fields", {}).get("outcome") != "routed":
    raise SystemExit(2)
if events[positions[7]].get("fields", {}).get("routed") != "true":
    raise SystemExit(2)
print(
    connection_id,
    helper_pid,
    expected_pid,
    helper_start_seconds,
    helper_start_microseconds,
)
PY
)" || fail "run_routing_history did not prove one fresh, ordered, PID-consistent route with zero tool calls."
read -r OMP_CONNECTION_ID OMP_HELPER_PID OMP_EXPECTED_PID OMP_HELPER_START_SECONDS OMP_HELPER_START_MICROSECONDS <<< "$ROUTING_IDENTIFIERS"
[[ -n "$OMP_CONNECTION_ID" && -n "$OMP_HELPER_PID" && -n "$OMP_EXPECTED_PID" && -n "$OMP_HELPER_START_SECONDS" && -n "$OMP_HELPER_START_MICROSECONDS" ]] \
  || fail "The routing correlation identifiers were incomplete."

call_tool __repoprompt_debug_diagnostics '{"op":"connections","include_identity":true}' "$EVIDENCE_DIR/connections.json"
"$PYTHON" - "$EVIDENCE_DIR/connections.json" <<'PY' || fail "connections diagnostics returned an invalid status."
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("ok") is not True or not isinstance(value.get("connections"), list):
    raise SystemExit(2)
PY

cleanup_exact_session || fail "Exact synthetic session cleanup failed or did not prove deletion of only the smoke-created session."

CONNECTION_HISTORY_ARGS="$("$PYTHON" - "$OMP_CONNECTION_ID" <<'PY'
import json
import sys
print(json.dumps({
    "op": "connection_history",
    "connection_id": sys.argv[1],
    "limit": 500,
}, separators=(",", ":")))
PY
)"
TERMINAL_DEADLINE=$((SECONDS + 30))
while true; do
  call_tool __repoprompt_debug_diagnostics "$CONNECTION_HISTORY_ARGS" "$EVIDENCE_DIR/omp_connection_history.json" 5
  if "$PYTHON" - "$EVIDENCE_DIR/omp_connection_history.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
raise SystemExit(0 if any(event.get("event") == "removed" for event in value.get("events", [])) else 1)
PY
  then
    break
  fi
  (( SECONDS < TERMINAL_DEADLINE )) || fail "The exact OMP helper connection did not reach terminal removal within 30 seconds."
  sleep 0.25
done

"$PYTHON" - "$EVIDENCE_DIR/omp_connection_history.json" "$OMP_CLIENT_NAME" "$OMP_CONNECTION_ID" "$EVIDENCE_DIR/routing_baseline.json" "$OMP_HELPER_PID" "$MAX_BOOKKEEPING_RAW_CALLS" "$OMP_HELPER_START_SECONDS" "$OMP_HELPER_START_MICROSECONDS" <<'PY' || fail "OMP connection_history did not prove terminal exact-connection zero non-bookkeeping calls, in-flight calls, and scopes."
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
events = value.get("events")
with open(sys.argv[4], encoding="utf-8") as handle:
    baseline = json.load(handle)
if value.get("ok") is not True or not isinstance(events, list) or not events:
    raise SystemExit(2)
if any(event.get("connection_id") != sys.argv[3] for event in events):
    raise SystemExit(2)
identity = [
    event for event in events
    if event.get("client_name") == sys.argv[2]
    and event.get("normalized_client_id") == sys.argv[2]
    and event.get("seq", 0) > baseline.get("connection_sequence", -1)
]
terminal = [event for event in events if event.get("event") == "removed"]
if len(identity) < 1 or len(terminal) != 1:
    raise SystemExit(2)
final = terminal[0]
required_tool_evidence = {
    "qualification_raw_tool_call_count",
    "qualification_raw_tool_names",
    "qualification_raw_canonical_tool_names",
    "non_bookkeeping_tool_call_count",
    "non_bookkeeping_tool_names",
}
missing = sorted(required_tool_evidence - final.keys())
if missing:
    print(
        "missing terminal tool evidence: " + ", ".join(missing),
        file=sys.stderr,
    )
    raise SystemExit(2)
raw_count = final["qualification_raw_tool_call_count"]
raw_names = final["qualification_raw_tool_names"]
canonical_names = final["qualification_raw_canonical_tool_names"]
non_bookkeeping_count = final["non_bookkeeping_tool_call_count"]
non_bookkeeping_names = final["non_bookkeeping_tool_names"]
bookkeeping_names = {"set_status", "bind_context"}
raw_name_set = set(raw_names) if isinstance(raw_names, list) and all(isinstance(name, str) for name in raw_names) else set()
canonical_name_set = set(canonical_names) if isinstance(canonical_names, list) and all(isinstance(name, str) for name in canonical_names) else set()
if (
    type(raw_count) is not int
    or raw_count < 0
    or not isinstance(raw_names, list)
    or len(raw_name_set) != len(raw_names)
    or not isinstance(canonical_names, list)
    or len(canonical_name_set) != len(canonical_names)
    or type(non_bookkeeping_count) is not int
    or not isinstance(non_bookkeeping_names, list)
):
    print("terminal zero-tool evidence contained non-bookkeeping or invalid raw tool activity", file=sys.stderr)
    raise SystemExit(2)
if raw_count == 0 and (raw_names or canonical_names or non_bookkeeping_count or non_bookkeeping_names):
    print("zero raw call count contradicts observed tool names", file=sys.stderr)
    raise SystemExit(2)
if (
    raw_count > int(sys.argv[6])
    or (raw_count > 0 and not raw_names)
    or (raw_count > 0 and not canonical_names)
    or len(raw_names) > 32
    or len(canonical_names) > len(bookkeeping_names)
    or not canonical_name_set.issubset(bookkeeping_names)
    or raw_count < len(raw_names)
    or raw_count < len(canonical_names)
    or non_bookkeeping_count != 0
    or non_bookkeeping_names != []
):
    print("terminal zero-tool evidence contained non-bookkeeping or invalid raw tool activity", file=sys.stderr)
    raise SystemExit(2)
if (
    final.get("qualification_raw_in_flight_call_count") != 0
    or final.get("active_tool_scope_count") != 0
    or type(final.get("helper_peer_pid")) is not int
    or final.get("helper_peer_pid") <= 0
    or type(final.get("helper_peer_start_seconds")) is not int
    or final.get("helper_peer_start_seconds") <= 0
    or type(final.get("helper_peer_start_microseconds")) is not int
    or not 0 <= final.get("helper_peer_start_microseconds") < 1_000_000
    or final.get("helper_peer_pid") != int(sys.argv[5])
    or final.get("helper_peer_start_seconds") != int(sys.argv[7])
    or final.get("helper_peer_start_microseconds") != int(sys.argv[8])
):
    raise SystemExit(2)
PY

"$PYTHON" -   "$EVIDENCE_DIR/start.json"   "$EVIDENCE_DIR/wait.json"   "$EVIDENCE_DIR/run_routing_history.json"   "$EVIDENCE_DIR/connections.json"   "$EVIDENCE_DIR/session_cleanup.json"   "$EVIDENCE_DIR/omp_connection_history.json" <<'PY' || fail "Captured evidence failed privacy-safe JSON validation."
import json
import sys
sensitive_keys = {"authorization", "password", "secret", "token", "api_key", "private_key", "credential"}
allowed_keys = {"session_key_present", "session_fingerprint"}
def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = key.lower().replace("-", "_")
            if normalized not in allowed_keys and normalized in sensitive_keys:
                raise SystemExit(2)
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)
    elif isinstance(value, str):
        lowered = value.lower()
        if "authorization:" in lowered or "bearer " in lowered or "token=" in lowered:
            raise SystemExit(2)
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        walk(json.load(handle))
PY

printf 'OMP_AGENT_MODE_SMOKE_OK evidence=%s\n' "$EVIDENCE_DIR"
