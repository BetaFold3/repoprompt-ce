#!/usr/bin/env python3

import ast
import tempfile
import unittest
from pathlib import Path

import qualify_omp_apply_edits_live as qualification


class OMPApplyEditsLiveQualificationTests(unittest.TestCase):
    def test_already_fetched_evidence_rejects_omp_request_timeout(self) -> None:
        qualification.reject_omp_request_timeout({"nested": ["ordinary evidence"]}, "log")
        with self.assertRaisesRegex(qualification.QualificationError, "run routing"):
            qualification.reject_omp_request_timeout(
                {"events": [{"message": "Request timeout after 60000ms"}]},
                "run routing",
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
            ("__repoprompt_debug_diagnostics", "omp_qualification_lease", "release"):
                {"op", "action", "lease_id", "owner_pid"},
            ("agent_run", "start", None): {
                "op", "model_id", "workspace_id", "_omp_qualification_lease_id",
                "_omp_qualification_apply_edits_review", "session_name", "message", "detach",
            },
            ("agent_run", "wait", None):
                {"op", "session_id", "timeout"},
            ("agent_run", "respond", None):
                {"op", "session_id", "interaction_id", "response"},
            ("agent_manage", "get_log", None):
                {"op", "session_id", "limit"},
            ("agent_manage", "cleanup_sessions", None):
                {"op", "session_ids"},
        }
        source = Path(qualification.__file__).read_text(encoding="utf-8")
        observed = 0
        respond_tokens = []
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
            if tool == "agent_run" and op == "respond":
                respond_tokens.append(ast.literal_eval(values["response"]))
            observed += 1
        self.assertEqual(observed, 12)
        self.assertCountEqual(respond_tokens, ["accept", "reject"])

    def test_verified_workspace_requires_exact_single_root_and_rejects_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp).resolve()
            snapshot = {
                "windows": [{
                    "window_id": 7,
                    "workspace_id": "55555555-5555-4555-8555-555555555555",
                    "repo_paths": [str(scratch)],
                }]
            }
            self.assertEqual(
                qualification.verified_workspace(snapshot, 7, scratch),
                "55555555-5555-4555-8555-555555555555",
            )
            mismatched = {"windows": [dict(snapshot["windows"][0], repo_paths=[str(scratch / "other")])]}
            with self.assertRaises(qualification.QualificationError):
                qualification.verified_workspace(mismatched, 7, scratch)
            malformed = {"windows": [dict(snapshot["windows"][0], repo_paths=[42])]}
            with self.assertRaises(qualification.QualificationError):
                qualification.verified_workspace(malformed, 7, scratch)
            overlapping = {
                "windows": snapshot["windows"] + [{
                    "window_id": 8,
                    "workspace_id": "66666666-6666-4666-8666-666666666666",
                    "repo_paths": [str(scratch / "nested")],
                }]
            }
            with self.assertRaises(qualification.QualificationError):
                qualification.verified_workspace(overlapping, 7, scratch)

    def test_verified_workspace_resolves_single_symlink_alias_but_rejects_two_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = (root / "scratch").resolve()
            scratch.mkdir()
            alias = root / "scratch-alias"
            try:
                alias.symlink_to(scratch, target_is_directory=True)
            except (NotImplementedError, OSError) as error:
                self.skipTest(f"directory symlinks unavailable: {error}")
            window = {
                "window_id": 7,
                "workspace_id": "55555555-5555-4555-8555-555555555555",
                "repo_paths": [str(alias)],
            }
            self.assertEqual(
                qualification.verified_workspace({"windows": [window]}, 7, scratch),
                "55555555-5555-4555-8555-555555555555",
            )
            duplicate = {
                "windows": [dict(window, repo_paths=[str(alias), str(scratch)])],
            }
            with self.assertRaises(qualification.QualificationError):
                qualification.verified_workspace(duplicate, 7, scratch)

    def test_review_contract_requires_exact_projection_and_metadata(self) -> None:
        review = {
            "interaction": {
                "id": "77777777-7777-4777-8777-777777777777",
                "title": "Apply Edits Review",
                "kind": "approval",
                "options": [{"label": "accept"}, {"label": "reject"}],
            }
        }
        self.assertEqual(qualification.exact_review(review)["id"], review["interaction"]["id"])
        with self.assertRaises(qualification.QualificationError):
            qualification.exact_review({
                "interaction": dict(review["interaction"], options=[{"label": "accept"}, {"label": "cancel"}])
            })
        self.assertEqual(
            qualification.review_decision({
                "_meta": {"omp_qualification_apply_edits_review": {"decision": "accepted"}}
            }),
            "accepted",
        )

    def test_script_contains_no_app_or_workspace_lifecycle_commands(self) -> None:
        source = Path(qualification.__file__).read_text(encoding="utf-8")
        for forbidden in ("--launch-app", "switch_workspace", "close_workspace", '"op": "stop"'):
            self.assertNotIn(forbidden, source)
        for required in (
            "get_file_tree",
            "apply_edits",
            "cleanup_sessions",
            "qualification_raw_in_flight_call_count",
            "_omp_qualification_apply_edits_review",
        ):
            self.assertIn(required, source)


if __name__ == "__main__":
    unittest.main()
