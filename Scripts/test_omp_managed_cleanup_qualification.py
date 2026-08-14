#!/usr/bin/env python3
"""Hermetic scaled-duration tests for managed OMP cleanup qualification support."""

from __future__ import annotations

import ast
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import omp_managed_cleanup_qualification as cleanup


RUN_ID = "59616c37-b310-4198-84f5-6346ab39b06a"
CONNECTION_A = "bfac5780-2614-4f48-a063-339d947a05c0"
CONNECTION_B = "58d61ef5-dd07-45fb-8148-a106a4aae5ac"
SESSION_A = "f18ee497-6d75-4ce3-a534-ee7697ef59d1"
SESSION_B = "56ac5672-dd37-4d80-a43a-54f7790ad66d"
WORKSPACE_ID = "11be4fa4-168a-4e26-8e9c-291c50eb5c5b"
LEASE_ID = "bf0292d5-ec71-45b5-b2c7-276466616cb6"
OMP = {"pid": 101, "startSeconds": 11, "startMicroseconds": 12}
HELPER_A = {"pid": 202, "startSeconds": 21, "startMicroseconds": 22}
HELPER_B = {"pid": 303, "startSeconds": 31, "startMicroseconds": 32}
FORBIDDEN_PAYLOAD = "PRIVATE prompt=/secret/path args=[do-not-leak] tool-output"


def identity_event(connection_id: str, helper: dict[str, int]) -> dict[str, object]:
    return {
        "run_id": RUN_ID,
        "event": "client_identity_observed",
        "connection_id": connection_id,
        "fields": {
            "verified_client_name": "omp-coding-agent",
            "helper_peer_pid": str(helper["pid"]),
            "matched_expected_start_seconds": str(OMP["startSeconds"]),
            "matched_expected_start_microseconds": str(OMP["startMicroseconds"]),
            "helper_process_start_seconds": str(helper["startSeconds"]),
            "helper_process_start_microseconds": str(helper["startMicroseconds"]),
        },
    }


def captured_identities(
    *connections: tuple[str, dict[str, int]],
) -> dict[str, dict[str, int]]:
    return {connection_id: dict(helper) for connection_id, helper in connections}


def routing(*connections: tuple[str, dict[str, int]]) -> dict[str, object]:
    return {
        "events": [
            *(identity_event(connection_id, helper) for connection_id, helper in connections),
            {"run_id": RUN_ID, "event": "policy_cleared"},
            {"run_id": RUN_ID, "event": "expected_pid_cleared"},
        ],
    }


def history(helper: dict[str, int], *, removed: int = 1, in_flight: int = 0, scopes: int = 0) -> dict[str, object]:
    terminal = {
        "event": "removed",
        "helper_peer_pid": helper["pid"],
        "helper_peer_start_seconds": helper["startSeconds"],
        "helper_peer_start_microseconds": helper["startMicroseconds"],
        "qualification_raw_in_flight_call_count": in_flight,
        "active_tool_scope_count": scopes,
        "qualification_raw_canonical_tool_names": ["get_file_tree"],
    }
    return {"events": [dict(terminal) for _ in range(removed)]}


def payload_mock(
    routing_samples: list[dict[str, object]],
    histories: dict[str, dict[str, object]],
):
    sample_index = 0

    def fake_call(
        _cli: Path,
        _window_id: int,
        _tool: str,
        payload: dict[str, object],
        _timeout: float,
    ) -> dict[str, object]:
        nonlocal sample_index
        if payload["op"] == "run_routing_history":
            result = routing_samples[min(sample_index, len(routing_samples) - 1)]
            sample_index += 1
            return result
        if payload["op"] == "connection_history":
            return histories[str(payload["connection_id"])]
        raise AssertionError(f"unexpected payload: {payload}")

    return fake_call


class OMPManagedCleanupQualificationTests(unittest.TestCase):
    def cleanup_timeout_summary(
        self,
        routing_samples: list[dict[str, object]],
        histories: dict[str, dict[str, object]],
        *,
        sealed_connection_identities: dict[str, dict[str, int]] | None = None,
    ) -> dict[str, object]:
        fake = payload_mock(routing_samples, histories)
        with (
            mock.patch.object(cleanup, "call", side_effect=fake),
            mock.patch.object(cleanup.time, "sleep"),
            mock.patch.object(cleanup.time, "monotonic", side_effect=[0, 0, 2]),
            self.assertRaises(cleanup.QualificationError) as raised,
        ):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=sealed_connection_identities,
            )
        message = str(raised.exception)
        self.assertNotIn(FORBIDDEN_PAYLOAD, message)
        summary = json.loads(message.split("last_blocker=", 1)[1])
        self.assertEqual(
            set(summary),
            {
                "blocker",
                "canonical_connection_ids",
                "canonical_connection_count",
                "sealed_ids",
                "sealed_count",
                "stable_sample_count",
                "connections",
                "policy_cleared_count",
                "expected_pid_cleared_count",
            },
        )
        for state in summary["connections"].values():
            self.assertEqual(
                set(state),
                {
                    "identity_present",
                    "removed_count",
                    "raw_in_flight_count",
                    "active_scope_count",
                    "initial_tool_activity",
                },
            )
        return summary

    def test_already_fetched_evidence_rejects_omp_request_timeout(self) -> None:
        cleanup.reject_omp_request_timeout({"events": [{"message": "normal"}]}, "connection history")
        with self.assertRaisesRegex(cleanup.QualificationError, "connection history"):
            cleanup.reject_omp_request_timeout(
                {"events": [{"fields": {"error": "Request timeout after 600000ms"}}]},
                "connection history",
            )

    def test_all_mcp_payloads_match_current_operation_shapes(self) -> None:
        contracts = {
            ("__repoprompt_debug_diagnostics", "routing_snapshot", None):
                {"op", "include_records", "include_windows"},
            ("__repoprompt_debug_diagnostics", "connection_history", None):
                {"op", "connection_id", "limit"},
            ("__repoprompt_debug_diagnostics", "run_routing_history", None):
                {"op", "run_id", "limit"},
            ("__repoprompt_debug_diagnostics", "omp_qualification_lease", "acquire"):
                {"op", "action", "owner_pid", "duration_seconds"},
            ("__repoprompt_debug_diagnostics", "omp_qualification_lease", "status"):
                {"op", "action"},
            ("__repoprompt_debug_diagnostics", "omp_qualification_lease", "release"):
                {"op", "action", "lease_id", "owner_pid"},
            ("agent_run", "start", None):
                {"op", "model_id", "workspace_id", "_omp_qualification_lease_id", "detach", "session_name", "message"},
            ("agent_run", "wait", None):
                {"op", "session_id", "timeout"},
            ("agent_run", "cancel", None):
                {"op", "session_id", "run_id"},
            ("agent_manage", "list_sessions", None):
                {"op", "workspace_id", "limit"},
            ("agent_manage", "cleanup_sessions", None):
                {"op", "session_ids"},
        }
        source = Path(cleanup.__file__).read_text(encoding="utf-8")
        observed = 0
        for node in ast.walk(ast.parse(source)):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name) or node.func.id != "call":
                continue
            self.assertGreaterEqual(len(node.args), 4)
            tool = ast.literal_eval(node.args[2])
            payload = node.args[3]
            self.assertIsInstance(payload, ast.Dict, f"{tool} payload must remain an auditable literal dict")
            assert isinstance(payload, ast.Dict)
            keys = [ast.literal_eval(key) for key in payload.keys]
            self.assertEqual(len(keys), len(set(keys)), f"{tool} payload has duplicate keys")
            values = dict(zip(keys, payload.values))
            op = ast.literal_eval(values["op"])
            action_node = values.get("action")
            action = ast.literal_eval(action_node) if action_node is not None else None
            contract = contracts.get((tool, op, action))
            self.assertIsNotNone(contract, f"unaudited payload shape for {tool} {op} {action}")
            self.assertEqual(set(keys), contract)
            if (tool, op, action) == ("agent_run", "start", None):
                self.assertIsInstance(values["detach"], ast.Constant)
                self.assertIs(ast.literal_eval(values["detach"]), True)
            observed += 1
        self.assertEqual(observed, 20)

    def test_dedicated_scratch_window_accepts_a_canonical_symlink_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = root / "scratch"
            scratch_alias = root / "scratch-alias"
            evidence = root / "evidence"
            scratch.mkdir()
            evidence.mkdir()
            try:
                scratch_alias.symlink_to(scratch, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"directory symlinks are unavailable: {error}")
            workspace_id = "11be4fa4-168a-4e26-8e9c-291c50eb5c5b"
            routing_snapshot = {
                "ok": True,
                "windows": [{
                    "window_id": 7,
                    "workspace_id": workspace_id,
                    "repo_paths": [str(scratch_alias)],
                }],
            }
            with mock.patch.object(cleanup, "call", return_value=routing_snapshot):
                target = cleanup.verify_dedicated_scratch_window(
                    Path("/tmp/rpce-cli-debug"), 7, workspace_id, scratch, evidence, 1,
                )
            self.assertEqual(target["window_id"], 7)

    def test_dedicated_scratch_window_rejects_malformed_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = root / "scratch"
            evidence = root / "evidence"
            scratch.mkdir()
            evidence.mkdir()
            workspace_id = "11be4fa4-168a-4e26-8e9c-291c50eb5c5b"
            base_window = {
                "window_id": 7,
                "workspace_id": workspace_id,
                "repo_paths": [str(scratch)],
            }
            rejected_roots = (
                None,
                [],
                [str(scratch), str(scratch)],
                [123],
                [""],
                ["relative/root"],
                [str(root / "missing")],
            )
            for repo_paths in rejected_roots:
                routing_snapshot = {
                    "ok": True,
                    "windows": [{**base_window, "repo_paths": repo_paths}],
                }
                with (
                    self.subTest(repo_paths=repo_paths),
                    mock.patch.object(cleanup, "call", return_value=routing_snapshot),
                    self.assertRaises(cleanup.QualificationError),
                ):
                    cleanup.verify_dedicated_scratch_window(
                        Path("/tmp/rpce-cli-debug"), 7, workspace_id, scratch, evidence, 1,
                    )

    def test_dedicated_scratch_window_rejects_canonical_evidence_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = root / "scratch"
            evidence_alias = root / "evidence-alias"
            scratch.mkdir()
            try:
                evidence_alias.symlink_to(scratch, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"directory symlinks are unavailable: {error}")
            workspace_id = "11be4fa4-168a-4e26-8e9c-291c50eb5c5b"
            routing_snapshot = {
                "ok": True,
                "windows": [{
                    "window_id": 7,
                    "workspace_id": workspace_id,
                    "repo_paths": [str(scratch)],
                }],
            }
            with (
                mock.patch.object(cleanup, "call", return_value=routing_snapshot),
                self.assertRaisesRegex(cleanup.QualificationError, "must not overlap"),
            ):
                cleanup.verify_dedicated_scratch_window(
                    Path("/tmp/rpce-cli-debug"), 7, workspace_id, scratch, evidence_alias, 1,
                )

    def test_bound_lease_uuid_triples_are_canonical_and_fail_closed(self) -> None:
        valid = {
            "active": True,
            "lease_id": LEASE_ID.upper(),
            "session_id": SESSION_B.upper(),
            "run_id": RUN_ID.upper(),
        }
        cleanup.validate_bound_lease(valid, LEASE_ID, SESSION_B, RUN_ID, "bound lease")

        for field, value in (
            ("lease_id", "not-a-uuid"),
            ("session_id", "not-a-uuid"),
            ("run_id", "not-a-uuid"),
            ("lease_id", CONNECTION_A),
            ("session_id", SESSION_A),
            ("run_id", SESSION_A),
        ):
            with self.subTest(field=field, value=value), self.assertRaises(cleanup.QualificationError):
                cleanup.validate_bound_lease(
                    {**valid, field: value},
                    LEASE_ID,
                    SESSION_B,
                    RUN_ID,
                    "bound lease",
                )

    def test_captured_processes_reconciles_routing_identity_before_any_signal(self) -> None:
        events = [
            {
                "run_id": RUN_ID,
                "event": "expected_pid_registered",
                "fields": {"expected_pid": "101"},
            },
            identity_event(CONNECTION_A, HELPER_A),
        ]
        identities = {
            101: {"pid": 101, "parentPID": 1, "startSeconds": 11, "startMicroseconds": 12},
            202: {"pid": 202, "parentPID": 101, "startSeconds": 21, "startMicroseconds": 22},
        }
        uppercase_events = [
            {**event, "run_id": RUN_ID.upper()}
            for event in events
        ]
        with mock.patch.object(cleanup.spike, "capture_live_process_identity", side_effect=lambda pid: identities[pid]):
            captured_connection, omp, helper = cleanup.captured_processes(uppercase_events, RUN_ID.upper())
        self.assertEqual(captured_connection, CONNECTION_A)
        self.assertEqual((omp["pid"], helper["pid"]), (101, 202))

        for bad_run_id in ("not-a-uuid", SESSION_A):
            bad_events = [{**event, "run_id": bad_run_id} for event in events]
            with (
                self.subTest(run_id=bad_run_id),
                mock.patch.object(cleanup.spike, "capture_live_process_identity", side_effect=lambda pid: identities[pid]),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.captured_processes(bad_events, RUN_ID)

        fields = events[1]["fields"]
        assert isinstance(fields, dict)
        fields["helper_process_start_microseconds"] = "23"
        with (
            mock.patch.object(cleanup.spike, "capture_live_process_identity", side_effect=lambda pid: identities[pid]),
            self.assertRaises(cleanup.QualificationError),
        ):
            cleanup.captured_processes(events, RUN_ID)

    def test_identity_capture_seals_two_helpers_after_two_stable_samples(self) -> None:
        samples = [
            routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
            routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
        ]
        with (
            mock.patch.object(cleanup, "call", side_effect=payload_mock(samples, {})),
            mock.patch.object(cleanup.time, "sleep"),
        ):
            identities = cleanup.capture_stable_connection_identities(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
            )
        self.assertEqual(
            identities,
            captured_identities((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
        )

    def test_identity_capture_rejects_missing_duplicate_and_foreign_identity(self) -> None:
        missing = {
            "events": [
                {"run_id": RUN_ID, "event": "connection_seen", "connection_id": CONNECTION_A},
                {"run_id": RUN_ID, "event": "policy_cleared"},
                {"run_id": RUN_ID, "event": "expected_pid_cleared"},
            ],
        }
        with (
            mock.patch.object(cleanup, "call", return_value=missing),
            mock.patch.object(cleanup.time, "sleep"),
            mock.patch.object(cleanup.time, "monotonic", side_effect=[0, 0, 2]),
            self.assertRaisesRegex(cleanup.QualificationError, "did not stabilize"),
        ):
            cleanup.capture_stable_connection_identities(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

        duplicate = routing((CONNECTION_A, HELPER_A))
        events = duplicate["events"]
        assert isinstance(events, list)
        events.insert(1, identity_event(CONNECTION_A, HELPER_A))
        foreign = routing((CONNECTION_A, HELPER_A))
        foreign_events = foreign["events"]
        assert isinstance(foreign_events, list)
        foreign_fields = foreign_events[0]["fields"]
        assert isinstance(foreign_fields, dict)
        foreign_fields["verified_client_name"] = "foreign-client"
        for label, sample in (("duplicate", duplicate), ("foreign", foreign)):
            with (
                self.subTest(label=label),
                mock.patch.object(cleanup, "call", return_value=sample),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.capture_stable_connection_identities(
                    Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
                )

    def test_identity_capture_rejects_foreign_malformed_and_truncated_events(self) -> None:
        foreign = routing((CONNECTION_A, HELPER_A))
        foreign_events = foreign["events"]
        assert isinstance(foreign_events, list)
        foreign_events[0]["run_id"] = SESSION_A
        malformed = {"events": [None]}
        truncated = {"events": [{} for _ in range(500)]}
        for label, sample in (
            ("foreign-run", foreign),
            ("malformed", malformed),
            ("truncated", truncated),
        ):
            with (
                self.subTest(label=label),
                mock.patch.object(cleanup, "call", return_value=sample),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.capture_stable_connection_identities(
                    Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
                )

    def test_terminal_matrix(self) -> None:
        accepted = [
            ("cancel", {"status": "cancelled"}, {}, "exact-cancelled"),
            ("kill-omp", {"status": "failed"}, {}, "exact-root-failure"),
            (
                "kill-helper",
                {"status": "failed"},
                {"helper_signal_succeeded": True, "cleanup_snapshot": {"initialHelperCorrelation": True}},
                "correlated-helper-failure",
            ),
        ]
        for scenario, terminal, kwargs, classification in accepted:
            with self.subTest(scenario=scenario, terminal=terminal):
                self.assertEqual(
                    cleanup.validate_terminal_outcome(scenario, terminal, **kwargs),
                    classification,
                )

        rejected_statuses = [
            ("cancel", "completed"),
            ("cancel", "failed"),
            ("kill-omp", "cancelled"),
            ("kill-omp", "completed"),
            ("kill-helper", "cancelled"),
        ]
        for scenario, status in rejected_statuses:
            with self.subTest(scenario=scenario, status=status), self.assertRaises(cleanup.QualificationError):
                cleanup.validate_terminal_outcome(scenario, {"status": status})

    def test_completed_helper_requires_signal_and_exact_sentinel(self) -> None:
        terminal = {"status": "completed", "assistant_text": cleanup.OMP_MANAGED_CLEANUP_OK}
        self.assertEqual(
            cleanup.validate_terminal_outcome(
                "kill-helper",
                terminal,
                helper_signal_succeeded=True,
            ),
            "exact-completed-sentinel",
        )
        with self.assertRaisesRegex(cleanup.QualificationError, "helper signal"):
            cleanup.validate_terminal_outcome("kill-helper", terminal)

        for text in (None, "", "OMP_MANAGED_CLEANUP_OK ", " OMP_MANAGED_CLEANUP_OK", "changed"):
            with self.subTest(text=text), self.assertRaisesRegex(cleanup.QualificationError, "sentinel"):
                cleanup.validate_terminal_outcome(
                    "kill-helper",
                    {"status": "completed", "assistant_text": text},
                    helper_signal_succeeded=True,
                )

    def test_terminal_drain_phase_selects_completed_helper_post_cleanup_only(self) -> None:
        cases = (
            ("cancel", {"status": "cancelled"}, "pre-session-cleanup"),
            ("kill-omp", {"status": "failed"}, "pre-session-cleanup"),
            ("kill-helper", {"status": "failed"}, "pre-session-cleanup"),
            ("kill-helper", {"status": "completed"}, "post-session-cleanup"),
        )
        for scenario, terminal, expected in cases:
            with self.subTest(scenario=scenario, terminal=terminal):
                self.assertEqual(cleanup.terminal_drain_phase(scenario, terminal), expected)

    def test_failed_helper_requires_signal_and_exact_correlation(self) -> None:
        for signal_succeeded, correlated in ((False, True), (True, False), (False, False)):
            with (
                self.subTest(signal_succeeded=signal_succeeded, correlated=correlated),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.validate_terminal_outcome(
                    "kill-helper",
                    {"status": "failed"},
                    helper_signal_succeeded=signal_succeeded,
                    cleanup_snapshot={"initialHelperCorrelation": correlated},
                )

    def test_cleanup_timeout_reports_missing_initial_connection_safely(self) -> None:
        sample = routing((CONNECTION_B, HELPER_B))
        sample["events"][0]["message"] = FORBIDDEN_PAYLOAD
        summary = self.cleanup_timeout_summary([sample], {})
        self.assertEqual(summary["blocker"], "initial_connection_missing")
        self.assertEqual(summary["canonical_connection_ids"], [CONNECTION_B])
        self.assertEqual(summary["canonical_connection_count"], 1)

    def test_cleanup_timeout_reports_missing_identity_and_removal_safely(self) -> None:
        missing_identity = {
            "events": [
                {
                    "run_id": RUN_ID,
                    "event": "connection_seen",
                    "connection_id": CONNECTION_A,
                    "message": FORBIDDEN_PAYLOAD,
                },
                {"run_id": RUN_ID, "event": "policy_cleared"},
                {"run_id": RUN_ID, "event": "expected_pid_cleared"},
            ],
        }
        summary = self.cleanup_timeout_summary([missing_identity], {})
        self.assertEqual(summary["blocker"], "connection_identity_missing")
        self.assertFalse(summary["connections"][CONNECTION_A]["identity_present"])

        missing_removal = routing((CONNECTION_A, HELPER_A))
        missing_removal["events"][0]["message"] = FORBIDDEN_PAYLOAD
        summary = self.cleanup_timeout_summary(
            [missing_removal],
            {CONNECTION_A: {"events": [{"event": "progress", "message": FORBIDDEN_PAYLOAD}]}},
        )
        self.assertEqual(summary["blocker"], "connection_removal_missing")
        self.assertTrue(summary["connections"][CONNECTION_A]["identity_present"])
        self.assertEqual(summary["connections"][CONNECTION_A]["removed_count"], 0)

    def test_cleanup_timeout_reports_policy_and_pid_counts_safely(self) -> None:
        for omitted, blocker in (
            ("policy_cleared", "policy_cleared_count"),
            ("expected_pid_cleared", "expected_pid_cleared_count"),
        ):
            with self.subTest(omitted=omitted):
                sample = routing((CONNECTION_A, HELPER_A))
                sample["events"] = [
                    event for event in sample["events"]
                    if event.get("event") != omitted
                ]
                sample["events"][0]["message"] = FORBIDDEN_PAYLOAD
                summary = self.cleanup_timeout_summary(
                    [sample], {CONNECTION_A: history(HELPER_A)},
                )
                self.assertEqual(summary["blocker"], blocker)
                self.assertEqual(summary[f"{omitted}_count"], 0)
                self.assertEqual(summary["connections"][CONNECTION_A]["raw_in_flight_count"], 0)
                self.assertEqual(summary["connections"][CONNECTION_A]["active_scope_count"], 0)
                self.assertTrue(summary["connections"][CONNECTION_A]["initial_tool_activity"])

    def test_cleanup_timeout_reports_unstable_and_sealed_sets_safely(self) -> None:
        sample = routing((CONNECTION_A, HELPER_A))
        sample["events"][0]["message"] = FORBIDDEN_PAYLOAD
        summary = self.cleanup_timeout_summary(
            [sample], {CONNECTION_A: history(HELPER_A)},
        )
        self.assertEqual(summary["blocker"], "unstable_connection_set")
        self.assertEqual(summary["stable_sample_count"], 1)

        summary = self.cleanup_timeout_summary(
            [sample],
            {CONNECTION_A: {"events": []}, CONNECTION_B: {"events": []}},
            sealed_connection_identities=captured_identities(
                (CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B),
            ),
        )
        self.assertEqual(summary["blocker"], "connection_removal_missing")
        self.assertEqual(summary["sealed_ids"], sorted([CONNECTION_A, CONNECTION_B]))
        self.assertEqual(summary["sealed_count"], 2)

    def test_cleanup_tracks_replacement_before_stability_and_drains_both(self) -> None:
        no_removal = {"events": []}
        histories = {CONNECTION_A: no_removal, CONNECTION_B: history(HELPER_B)}
        routing_samples = [
            routing((CONNECTION_A, HELPER_A)),
            routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
            routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
        ]

        # Preserve routing sample state while allowing A to become terminal after the first observation.
        routing_index = 0
        first_a = True

        def stateful_call(_cli, _window, _tool, payload, _timeout):
            nonlocal routing_index, first_a
            if payload["op"] == "run_routing_history":
                result = routing_samples[min(routing_index, len(routing_samples) - 1)]
                routing_index += 1
                return result
            if payload["connection_id"] == CONNECTION_A and first_a:
                first_a = False
                return no_removal
            return history(HELPER_A if payload["connection_id"] == CONNECTION_A else HELPER_B)

        with mock.patch.object(cleanup, "call", side_effect=stateful_call), mock.patch.object(cleanup.time, "sleep"):
            snapshot = cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )
        self.assertEqual(snapshot["connectionIDs"], sorted([CONNECTION_A, CONNECTION_B]))
        self.assertEqual(set(snapshot["connectionHistories"]), {CONNECTION_A, CONNECTION_B})
        self.assertTrue(snapshot["initialHelperCorrelation"])

    def test_successor_isolation_seals_the_first_full_cleanup_snapshot(self) -> None:
        first = {
            "connectionIDs": [CONNECTION_A, CONNECTION_B],
            "capturedConnectionIdentities": captured_identities(
                (CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B),
            ),
        }
        successor = {"connectionIDs": [CONNECTION_A, CONNECTION_B], "connectionSetSealed": True}
        with mock.patch.object(cleanup, "verify_cleanup", return_value=successor) as verify:
            result = cleanup.verify_successor_isolation(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                first,
            )
        self.assertIs(result, successor)
        verify.assert_called_once_with(
            Path("/tmp/rpce-cli-debug"),
            7,
            RUN_ID,
            CONNECTION_A,
            OMP,
            HELPER_A,
            1,
            sealed_connection_identities=captured_identities(
                (CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B),
            ),
        )

        with self.assertRaisesRegex(cleanup.QualificationError, "exact connection identities"):
            cleanup.verify_successor_isolation(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                {},
            )

    def test_cleanup_accepts_uppercase_routing_and_input_uuids(self) -> None:
        samples = []
        for _ in range(2):
            sample = routing((CONNECTION_A.upper(), HELPER_A))
            events = sample["events"]
            assert isinstance(events, list)
            sample["events"] = [
                {**event, "run_id": RUN_ID.upper()}
                for event in events
            ]
            samples.append(sample)
        fake = payload_mock(samples, {CONNECTION_A: history(HELPER_A)})
        with mock.patch.object(cleanup, "call", side_effect=fake), mock.patch.object(cleanup.time, "sleep"):
            snapshot = cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID.upper(),
                CONNECTION_A.upper(),
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=captured_identities(
                    (CONNECTION_A.upper(), HELPER_A),
                ),
            )
        self.assertEqual(snapshot["connectionIDs"], [CONNECTION_A])

    def test_cleanup_rejects_malformed_or_foreign_routing_uuids(self) -> None:
        for field, value in (
            ("run_id", "not-a-uuid"),
            ("run_id", SESSION_A),
            ("connection_id", "not-a-uuid"),
        ):
            sample = routing((CONNECTION_A, HELPER_A))
            events = sample["events"]
            assert isinstance(events, list)
            target = 0 if field == "connection_id" else 1
            event = events[target]
            assert isinstance(event, dict)
            event[field] = value
            with (
                self.subTest(field=field, value=value),
                mock.patch.object(cleanup, "call", return_value=sample),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.verify_cleanup(
                    Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
                )

        foreign = payload_mock(
            [routing((CONNECTION_B, HELPER_B))],
            {CONNECTION_B: history(HELPER_B)},
        )
        with mock.patch.object(cleanup, "call", side_effect=foreign), self.assertRaises(cleanup.QualificationError):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=captured_identities(
                    (CONNECTION_A, HELPER_A),
                ),
            )

    def test_cleanup_rejects_malformed_inputs_and_case_only_sealed_duplicates(self) -> None:
        for run_id, connection_id, sealed in (
            ("not-a-uuid", CONNECTION_A, None),
            (RUN_ID, "not-a-uuid", None),
            (RUN_ID, CONNECTION_A, {"not-a-uuid": HELPER_A}),
            (RUN_ID, CONNECTION_A, {CONNECTION_A: {"pid": "202"}}),
        ):
            with self.subTest(run_id=run_id, connection_id=connection_id, sealed=sealed), self.assertRaises(
                cleanup.QualificationError
            ):
                cleanup.verify_cleanup(
                    Path("/tmp/rpce-cli-debug"),
                    7,
                    run_id,
                    connection_id,
                    OMP,
                    HELPER_A,
                    1,
                    sealed_connection_identities=sealed,
                )

    def test_routing_and_connection_history_truncation_fail_closed(self) -> None:
        saturated_routing = {"events": [{} for _ in range(500)]}
        with mock.patch.object(cleanup, "call", return_value=saturated_routing), self.assertRaises(cleanup.QualificationError):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

        saturated_history = {"events": [{} for _ in range(500)]}
        fake = payload_mock(
            [routing((CONNECTION_A, HELPER_A))],
            {CONNECTION_A: saturated_history},
        )
        with mock.patch.object(cleanup, "call", side_effect=fake), self.assertRaises(cleanup.QualificationError):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

    def test_post_delete_absent_identity_is_accepted_only_with_sealed_capture(self) -> None:
        no_identity = routing()
        fake = payload_mock(
            [no_identity, no_identity],
            {CONNECTION_A: history(HELPER_A)},
        )
        with (
            mock.patch.object(cleanup, "call", side_effect=fake),
            mock.patch.object(cleanup.time, "sleep"),
        ):
            snapshot = cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=captured_identities(
                    (CONNECTION_A, HELPER_A),
                ),
            )
        self.assertEqual(snapshot["connectionIDs"], [CONNECTION_A])

        with (
            mock.patch.object(cleanup, "call", return_value=no_identity),
            mock.patch.object(cleanup.time, "sleep"),
            mock.patch.object(cleanup.time, "monotonic", side_effect=[0, 0, 2]),
            self.assertRaises(cleanup.QualificationError),
        ):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

    def test_post_delete_conflicting_identity_is_rejected(self) -> None:
        fake = payload_mock(
            [routing((CONNECTION_A, HELPER_B))],
            {CONNECTION_A: history(HELPER_A)},
        )
        with (
            mock.patch.object(cleanup, "call", side_effect=fake),
            self.assertRaisesRegex(cleanup.QualificationError, "conflicts with captured"),
        ):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=captured_identities(
                    (CONNECTION_A, HELPER_A),
                ),
            )

    def test_post_cleanup_rejects_late_connection(self) -> None:
        fake = payload_mock(
            [routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B))],
            {CONNECTION_A: history(HELPER_A), CONNECTION_B: history(HELPER_B)},
        )
        with mock.patch.object(cleanup, "call", side_effect=fake), self.assertRaises(cleanup.QualificationError):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"),
                7,
                RUN_ID,
                CONNECTION_A,
                OMP,
                HELPER_A,
                1,
                sealed_connection_identities=captured_identities(
                    (CONNECTION_A, HELPER_A),
                ),
            )

    def test_cleanup_rejects_disappearing_or_reappearing_connection_history(self) -> None:
        fake = payload_mock(
            [
                routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
                routing((CONNECTION_A, HELPER_A)),
                routing((CONNECTION_A, HELPER_A), (CONNECTION_B, HELPER_B)),
            ],
            {CONNECTION_A: history(HELPER_A), CONNECTION_B: history(HELPER_B)},
        )
        with (
            mock.patch.object(cleanup, "call", side_effect=fake),
            mock.patch.object(cleanup.time, "sleep"),
            self.assertRaises(cleanup.QualificationError),
        ):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

    def test_cleanup_rejects_identity_removal_and_drain_mutations(self) -> None:
        cases = {
            "helper_pid": history({**HELPER_A, "pid": 999}),
            "helper_start": history({**HELPER_A, "startMicroseconds": 999}),
            "duplicate_removal": history(HELPER_A, removed=2),
            "in_flight": history(HELPER_A, in_flight=1),
            "active_scope": history(HELPER_A, scopes=1),
        }
        for label, bad_history in cases.items():
            fake = payload_mock(
                [routing((CONNECTION_A, HELPER_A))],
                {CONNECTION_A: bad_history},
            )
            with (
                self.subTest(label=label),
                mock.patch.object(cleanup, "call", side_effect=fake),
                self.assertRaises(cleanup.QualificationError),
            ):
                cleanup.verify_cleanup(
                    Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
                )

        wrong_initial = {**HELPER_A, "startMicroseconds": 999}
        fake = payload_mock(
            [routing((CONNECTION_A, wrong_initial))],
            {CONNECTION_A: history(wrong_initial)},
        )
        with mock.patch.object(cleanup, "call", side_effect=fake), self.assertRaises(cleanup.QualificationError):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

    def test_missing_removal_times_out_and_missing_tool_activity_is_uncorrelated(self) -> None:
        fake = payload_mock(
            [routing((CONNECTION_A, HELPER_A))],
            {CONNECTION_A: {"events": []}},
        )
        with (
            mock.patch.object(cleanup, "call", side_effect=fake),
            mock.patch.object(cleanup.time, "sleep"),
            mock.patch.object(cleanup.time, "monotonic", side_effect=[0, 0, 2]),
            self.assertRaises(cleanup.QualificationError),
        ):
            cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )

        no_tool = history(HELPER_A)
        terminal = no_tool["events"][0]
        assert isinstance(terminal, dict)
        terminal["qualification_raw_canonical_tool_names"] = []
        fake = payload_mock(
            [routing((CONNECTION_A, HELPER_A)), routing((CONNECTION_A, HELPER_A))],
            {CONNECTION_A: no_tool},
        )
        with mock.patch.object(cleanup, "call", side_effect=fake), mock.patch.object(cleanup.time, "sleep"):
            snapshot = cleanup.verify_cleanup(
                Path("/tmp/rpce-cli-debug"), 7, RUN_ID, CONNECTION_A, OMP, HELPER_A, 1,
            )
        self.assertFalse(snapshot["initialHelperCorrelation"])
        with self.assertRaises(cleanup.QualificationError):
            cleanup.validate_terminal_outcome(
                "kill-helper",
                {"status": "failed"},
                helper_signal_succeeded=True,
                cleanup_snapshot=snapshot,
            )

    def test_session_inventory_requires_exact_workspace_unique_uuids_and_headroom(self) -> None:
        def inventory(session_ids: list[object], workspace_id: object = WORKSPACE_ID) -> dict[str, object]:
            return {
                "workspace": {"id": workspace_id, "name": "Scratch"},
                "sessions": [
                    item if isinstance(item, dict) else {"session_id": item}
                    for item in session_ids
                ],
            }

        self.assertEqual(
            cleanup.exact_session_ids(
                inventory([SESSION_A, SESSION_B], WORKSPACE_ID.upper()),
                WORKSPACE_ID,
                1000,
            ),
            [SESSION_A, SESSION_B],
        )
        rejected = (
            {"sessions": []},
            inventory([], SESSION_A),
            inventory([SESSION_A, SESSION_A]),
            inventory(["not-a-uuid"]),
            inventory([{"name": "missing"}]),
            {**inventory([]), "sessions": [None]},
            {**inventory([]), "sessions": None},
        )
        for payload in rejected:
            with self.subTest(payload=payload), self.assertRaises(cleanup.QualificationError):
                cleanup.exact_session_ids(payload, WORKSPACE_ID, 1000)

        with self.assertRaisesRegex(cleanup.QualificationError, "may be truncated"):
            cleanup.exact_session_ids(inventory([SESSION_A]), WORKSPACE_ID, 1)

        baseline = set(cleanup.exact_session_ids(inventory([SESSION_A]), WORKSPACE_ID, 1000))
        before = set(cleanup.exact_session_ids(inventory([SESSION_A, SESSION_B]), WORKSPACE_ID, 1000))
        after = set(cleanup.exact_session_ids(inventory([SESSION_A]), WORKSPACE_ID, 1000))
        self.assertEqual(before, baseline | {SESSION_B})
        self.assertEqual(after, baseline)

    def test_running_start_claims_new_session_and_run(self) -> None:
        self.assertEqual(
            cleanup.claim_running_start(
                {"status": "running", "session_id": SESSION_B, "run_id": RUN_ID},
                [SESSION_A],
            ),
            (SESSION_B, RUN_ID),
        )
        with self.assertRaisesRegex(cleanup.QualificationError, "already present"):
            cleanup.claim_running_start(
                {"status": "running", "session_id": SESSION_A, "run_id": RUN_ID},
                [SESSION_A],
            )

    def test_start_rejects_terminal_and_non_running_snapshots_before_claim(self) -> None:
        for status in ("completed", "cancelled", "failed", "pending", None):
            with self.subTest(status=status), self.assertRaisesRegex(
                cleanup.QualificationError,
                "exact running snapshot",
            ):
                cleanup.claim_running_start(
                    {"status": status, "session_id": SESSION_B, "run_id": RUN_ID},
                    [SESSION_A],
                )

    def test_cleanup_receipt_requires_exact_completed_deletion(self) -> None:
        valid = {
            "status": "completed",
            "deleted_count": 1,
            "skipped_count": 0,
            "deleted_sessions": [{"session_id": SESSION_B, "name": "Qualification"}],
            "skipped_sessions": [],
        }
        cleanup.validate_cleanup_receipt(valid, SESSION_B)
        cleanup.validate_cleanup_receipt(
            {**valid, "deleted_sessions": [{"session_id": SESSION_B.upper(), "name": "Qualification"}]},
            SESSION_B.upper(),
        )
        rejected = (
            {**valid, "status": "partial"},
            {**valid, "deleted_count": 0},
            {**valid, "skipped_count": 1},
            {**valid, "deleted_sessions": []},
            {**valid, "deleted_sessions": [{"session_id": SESSION_A}]},
            {**valid, "deleted_sessions": [{"session_id": SESSION_B}, {"session_id": SESSION_A}]},
            {**valid, "skipped_sessions": [{"session_id": SESSION_A}]},
        )
        for receipt in rejected:
            with self.subTest(receipt=receipt), self.assertRaises(cleanup.QualificationError):
                cleanup.validate_cleanup_receipt(receipt, SESSION_B)


if __name__ == "__main__":
    unittest.main()
