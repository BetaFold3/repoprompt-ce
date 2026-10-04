#!/usr/bin/env python3
"""Offline safety/protocol selftests; no app calls, workspace creation or Git commits."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import live_codemap_authority_e2e as live

CONTEXT = "00000000-0000-4000-8000-000000000001"
WORKSPACE = "00000000-0000-4000-8000-000000000002"
ROOT_ID = "00000000-0000-4000-8000-000000000003"
ROOT_LIFETIME = "00000000-0000-4000-8000-000000000004"


def counter_frame(counts=None, changed=False):
    scope = {"window_id": 4, "context_id": CONTEXT, "workspace_id": WORKSPACE,
             "root_id": ROOT_ID, "root_path": "/private/tmp/owned"}
    state = {"head_and_tree": ["a"*40, "b"*40], "index_sha256": ("d" if changed else "c")*64,
             "index_stat": dict(dev=1, ino=2, mode=0o100600, size=64, mtime_ns=100, ctime_ns=100)}
    inventory = {"window_id": 4, "root_count": 1, "omitted_root_count": 0,
                 "id": ROOT_ID, "path": scope["root_path"], "type": "workspace"}
    payload = {"ok": True, "op": "worktree_startup_benchmark", "action": "codemap_projection_snapshot",
               "codemap_projection": dict(zip(live.COUNTER_FIELDS, counts or (0, 0, 0))),
               "codemap_root_attribution": {"scope": "root_epoch", "root_id": ROOT_ID,
                                           "root_lifetime_id": ROOT_LIFETIME,
                                           **dict(zip(live.ROOT_COUNTER_FIELDS, counts or (0, 0, 0)))}}
    return {"available": True, "single_owned_root_in_window": True, "scope": scope, "response": payload,
            "inventory_before": inventory, "inventory_after": copy.deepcopy(inventory), "git_state": state}


def root_inventory(scope):
    return {"ok": True, "op": "mcp_read_search_runtime_snapshot",
            "runtime": {"window_count": 1, "windows": [{
                "window_id": scope["window_id"], "root_count": 1, "omitted_root_count": 0,
                "roots": [{"root_id": scope["root_id"], "root_path": scope["root_path"], "root_kind": "workspace"}]}]}}


def structure(root):
    files = []
    for index, (name, markers) in enumerate(live.BASE.items()):
        files.append({"path": f"{root.name}/{name}", "content": " ".join(markers),
                      "role": "related" if index else "seed", "depth": index,
                      "reached_by": ["referrers"] if index else []})
    return {"status": "ready", "issues": [], "files": files, "summary": {}}


class CodemapAuthorityHarnessTests(unittest.TestCase):
    def test_explicit_opt_in_precedes_any_side_effect(self):
        with patch.object(live.tempfile, "mkdtemp") as make, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                live.main(["--window-id", "1", "--context-id", CONTEXT, "--app-pid", "1"])
            make.assert_not_called()

    def test_ready_requires_exact_paths_symbols_and_relationships(self):
        root = Path("/private/tmp/owned")
        good = structure(root)
        live.validate_structure(good, root, live.BASE, {"ControlConsumer.swift"}, 1)
        bad_records = []
        for status in ("timeout", "stale", "busy", "partial"):
            value = copy.deepcopy(good); value["status"] = status; bad_records.append(value)
        value = copy.deepcopy(good); value["issues"] = [{"code": "publication_stale"}]; bad_records.append(value)
        value = copy.deepcopy(good); value["files"][1]["role"] = "seed"; bad_records.append(value)
        value = copy.deepcopy(good); value["files"][1]["reached_by"] = []; bad_records.append(value)
        value = copy.deepcopy(good); value["files"][1]["content"] = "unrelated"; bad_records.append(value)
        value = copy.deepcopy(good); value["files"][1]["path"] = "other/ControlConsumer.swift"; bad_records.append(value)
        value = copy.deepcopy(good); value["files"][1] = value["files"][0]; bad_records.append(value)
        value = copy.deepcopy(good); value["worktree_scope"] = {}; bad_records.append(value)
        for index, value in enumerate(bad_records):
            with self.subTest(index=index), self.assertRaises(ValueError):
                live.validate_structure(value, root, live.BASE, {"ControlConsumer.swift"}, 1)
        with self.assertRaises(ValueError):
            live.validate_structure(good, root, live.BASE, {"ControlConsumer.swift"}, 10)

    def test_atomic_routing_forces_both_ids_and_rejects_exit_zero_tool_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = live.Runner(Path(folder), Path("/fake/rpce-cli-debug"), 4, CONTEXT)
            binding = {"binding": {"window_id": 4, "context_id": CONTEXT}}
            runner.run = Mock(return_value={"stdout": json.dumps(binding)+"\n\n---\n\n"+json.dumps({"is_error": True, "error": "denied"}),
                                            "elapsed_seconds": .1})
            with self.assertRaises(ValueError):
                runner.call("failure", "get_code_structure", {"_windowID": 99, "context_id": "wrong"})
            argv = runner.run.call_args.args[1]
            command = argv[argv.index("-e")+1]
            for call in command.split(" && "):
                payload = json.loads(call.split(" ", 2)[2])
                self.assertEqual(payload["_windowID"], 4)
                self.assertEqual(payload["context_id"], CONTEXT)
            binding["binding"]["window_id"] = 99
            runner.run.return_value["stdout"] = json.dumps(binding)+"\n\n---\n\n{}"
            with self.assertRaises(live.bench.BenchmarkError):
                runner.call("wrong-binding", "app_settings", {"op": "get"})

    def test_write_preflight_mismatch_dispatches_no_edit_and_late_root_change_cannot_redirect(self):
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder).resolve(); root = artifact/"fixtures/owned"; root.mkdir(parents=True)
            other = artifact/"other-checkout"; other.mkdir()
            runner = live.Runner(artifact, Path("/fake/cli"), 4, CONTEXT); runner.expected_root = root
            owned_binding = {"binding": {"window_id": 4, "context_id": CONTEXT, "repo_paths": [str(root)]}}
            wrong_binding = copy.deepcopy(owned_binding); wrong_binding["binding"]["repo_paths"] = [str(other)]
            payload = {"path": str(root/"ControlAuthorityAdded.swift"), "rewrite": live.ADDED, "on_missing": "create"}
            runner.run = Mock(return_value={"stdout": json.dumps(wrong_binding), "elapsed_seconds": .01})
            with self.assertRaisesRegex(ValueError, "owned fixture root"):
                runner.call("mismatch", "apply_edits", payload)
            self.assertEqual(runner.run.call_count, 1)
            self.assertNotIn("apply_edits", runner.run.call_args.args[1][-1])
            for path in ("ControlAuthorityAdded.swift", str(other/"ControlAuthorityAdded.swift")):
                runner.run.reset_mock()
                with self.assertRaises(ValueError):
                    runner.call("unowned", "apply_edits", {**payload, "path": path})
                runner.run.assert_not_called()
            (root/"ControlAuthorityAdded.swift").symlink_to(other/"ControlAuthorityAdded.swift")
            runner.run.reset_mock()
            with self.assertRaises(ValueError):
                runner.call("symlink", "apply_edits", payload)
            runner.run.assert_not_called()
            (root/"ControlAuthorityAdded.swift").unlink()

            dispatched, writes = [], []
            def changed_after_preflight(label, argv):
                command = argv[-1]
                for part in command.split(" && "):
                    routed = json.loads(part.split(" ", 2)[2])
                    self.assertEqual((routed["_windowID"], routed["context_id"]), (4, CONTEXT))
                if "apply_edits" not in command:
                    return {"stdout": json.dumps(owned_binding), "elapsed_seconds": .01}
                edit = json.loads(command.split(" && ")[1].split(" ", 2)[2])
                dispatched.append(edit)
                # Simulate CURRENT server path admission after switching to another root.
                if Path(edit["path"]).parent == other:
                    writes.append(edit["path"])
                    Path(edit["path"]).write_text(edit["rewrite"])
                return {"stdout": json.dumps(wrong_binding)+"\n\n---\n\n"+
                        json.dumps({"isError": True, "error": "absolute path outside current root"}), "elapsed_seconds": .01}
            runner.run = Mock(side_effect=changed_after_preflight)
            with self.assertRaises(ValueError):
                runner.call("late-root-change", "apply_edits", payload)
            self.assertEqual([edit["path"] for edit in dispatched], [str(root/"ControlAuthorityAdded.swift")])
            self.assertEqual(writes, [])
            self.assertFalse((other/"ControlAuthorityAdded.swift").exists())
            self.assertFalse((root/"ControlAuthorityAdded.swift").exists())

    def test_global_discovery_accepts_only_exact_created_window_workspace_and_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root = str(Path(folder).resolve())
            runner = live.Runner(Path(folder), Path("/fake/cli"), 4, CONTEXT)
            scope = {"window_id": 5, "workspace_id": "owned", "root_path": root}
            tab = {"workspace_id": "owned", "repo_paths": [root], "context_id": CONTEXT}
            inventory = {"windows": [{"window_id": 5, "tabs": [tab]}]}
            runner.run = Mock(return_value={"stdout": json.dumps(inventory)})
            self.assertEqual(live.discover_created_context(runner, scope), CONTEXT)
            tab["repo_paths"] = [str(Path(root).parent)]
            runner.run.return_value["stdout"] = json.dumps(inventory)
            with self.assertRaises(ValueError):
                live.discover_created_context(runner, scope)

    def test_wrapped_exit_zero_error_is_not_success(self):
        for value in ({"isError": True}, {"is_error": True}, {"ok": False}, {"error": "failed"},
                      {"content": [{"type": "text", "text": '{"is_error":true,"error":"failed"}'}]}):
            with self.subTest(value=value):
                self.assertFalse(live.tool_ok(value))

    def test_unowned_git_target_is_rejected_before_subprocess(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = live.Runner(Path(folder), Path("/fake/cli"), 4, CONTEXT)
            runner.run = Mock()
            with self.assertRaises(ValueError):
                runner.git(Path(folder).parent, "unsafe", "add", ".")
            runner.run.assert_not_called()

    def test_timeout_is_bounded_and_keeps_partial_raw_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root/"raw").mkdir()
            runner = live.Runner(root, Path("/fake/cli"), 4, CONTEXT)
            with self.assertRaises(ValueError):
                runner.run("deadline", [sys.executable, "-c",
                                       "import time; print('partial evidence', flush=True); time.sleep(60)"], timeout=.5)
            raw = json.loads(next((root/"raw").glob("*.json")).read_text())
            self.assertTrue(raw["timed_out"])
            self.assertNotEqual(raw["returncode"], 0)
            self.assertLess(raw["elapsed_seconds"], 2)
            self.assertIn("partial evidence", raw["stdout"])

    def test_lock_free_commit_observers_have_pre_post_proof_and_abort_on_contamination(self):
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder).resolve(); root = artifact/"fixtures/owned"; (root/".git").mkdir(parents=True)
            index = root/".git/index"; index.write_bytes(b"offline index")
            runner = live.Runner(artifact, Path("/fake/cli"), 4, CONTEXT)
            self.assertEqual(runner.env["GIT_OPTIONAL_LOCKS"], "0")
            runner.run = Mock(return_value={"stdout": ""})
            live.commit(runner, root, "offline-clean", empty=True)
            proof = json.loads((artifact/"offline-clean-observer-proof.json").read_text())
            self.assertTrue(proof["index_unchanged"])
            self.assertEqual(proof["before"], proof["after"])
            status = [call.args[1] for call in runner.run.call_args_list if call.args[0].endswith("-status")][0]
            self.assertIn("--no-optional-locks", status)
            commit = runner.run.call_args.args[1]
            self.assertIn("commit", commit); self.assertIn("--allow-empty", commit)
            def contaminated(label, argv):
                if label.endswith("-status"):
                    index.write_bytes(b"unexpected observer index refresh")
                return {"stdout": ""}
            runner.run = Mock(side_effect=contaminated)
            with self.assertRaisesRegex(ValueError, "observers changed index"):
                live.commit(runner, root, "offline-contaminated")
            self.assertFalse(any("commit" in call.args[1] for call in runner.run.call_args_list))
            proof = json.loads((artifact/"offline-contaminated-observer-proof.json").read_text())
            self.assertFalse(proof["index_unchanged"])

    def test_full_index_stat_proof_prevents_false_metadata_only_label(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root/".git").mkdir()
            (root/".git/index").write_bytes(b"offline fixture index bytes")
            runner = Mock()
            runner.git.return_value = "a"*40+"\n"+"b"*40+"\n"
            before = live.git_state(runner, root, "offline-state")
            self.assertEqual(before["index_stat"], live.stat_record(root/".git/index"))
            self.assertEqual(set(before["index_stat"]), set(live.STAT_FIELDS))
            self.assertEqual(before["index_sha256"], live.digest(root/".git/index"))
            pure = copy.deepcopy(before); pure["head_and_tree"][0] = "c"*40
            proof = live.metadata_proof(before, pure)
            self.assertEqual((proof["classification"], proof["coverage"]), ("metadata-only", "proven"))
            self.assertEqual(live.metadata_proof(before, before)["coverage"], "unproven")
            for field in live.STAT_FIELDS:
                with self.subTest(changed_stat=field):
                    mixed = copy.deepcopy(pure); mixed["index_stat"][field] += 1
                    proof = live.metadata_proof(before, mixed)
                    self.assertEqual((proof["classification"], proof["coverage"]), ("mixed", "unproven"))
                    self.assertTrue(proof["run_label"].startswith("mixed-"))
                    self.assertIn("index_stat."+field, proof["changed_fields"])
                with self.subTest(missing_stat=field):
                    missing = copy.deepcopy(pure); del missing["index_stat"][field]
                    self.assertEqual(live.metadata_proof(before, missing)["coverage"], "unproven")
            with patch.object(live, "stat_record", side_effect=[before["index_stat"], mixed["index_stat"]]):
                with self.assertRaisesRegex(ValueError, "capturing SHA/stat"):
                    live.git_state(runner, root, "racing-state")

    def test_churn_proof_requires_both_directory_deltas_and_stable_full_index(self):
        fields = dict(dev=1, ino=2, mode=0o40700, size=64, mtime_ns=100, ctime_ns=100)
        before = {"git": {"head_and_tree": ["a"*40, "b"*40], "index_sha256": "c"*64,
                          "index_stat": {**fields, "mode": 0o100600}},
                  "directories": {"root": dict(fields), ".git": {**fields, "ino": 3}}}
        after = copy.deepcopy(before)
        after["directories"]["root"]["mtime_ns"] += 1
        self.assertEqual(live.churn_proof(before, after)["coverage"], "unproven")
        after["directories"][".git"]["ctime_ns"] += 1
        proof = live.churn_proof(before, after)
        self.assertEqual(proof["coverage"], "proven")
        self.assertEqual(proof["git_changed_fields"], [])
        for domain in ("root", ".git"):
            self.assertTrue(proof["directories"][domain]["identity_unchanged"])
            self.assertTrue(proof["directories"][domain]["stat_changed_fields"])
            invalid = copy.deepcopy(after); invalid["directories"][domain]["ino"] += 1
            self.assertEqual(live.churn_proof(before, invalid)["coverage"], "unproven")
        for field in live.STAT_FIELDS:
            invalid = copy.deepcopy(after); invalid["git"]["index_stat"][field] += 1
            self.assertEqual(live.churn_proof(before, invalid)["coverage"], "unproven")
        for invalid in ({}, {"git": before["git"], "directories": None}):
            self.assertEqual(live.churn_proof(before, invalid)["coverage"], "unproven")

    def test_query_phase_capture_preserves_failure_and_repeat_with_counter_receipts(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)/"fixture"
            runner = Mock(); runner.artifact = Path(folder); runner.records = []
            events = []
            def demand(label, *_):
                events.append(("query", label))
                return ({"status": "timeout", "files": [], "issues": [], "summary": {}}, 10.1) if label == "first" else (structure(root), 1)
            def snapshot(*args):
                events.append(("snapshot", args[2]))
                return counter_frame((4, 3, 1), changed=True)
            runner.call.side_effect = demand
            results, data = [], {"scope": {}, "phases": {"baseline": counter_frame()}}
            with patch.object(live, "diagnostics", side_effect=snapshot), patch.object(live, "git_state", return_value=counter_frame(changed=True)["git_state"]), contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(live.phase_query(runner, root, data, "after-stage-query", "first", results, True,
                                                 reference="baseline", repairs=1))
                self.assertTrue(live.phase_query(runner, root, data, "stage-repeat", "repeat", results, True,
                                                reference="after-stage-query", repairs=0))
            self.assertEqual(events, [("query", "first"), ("snapshot", "fixture-snapshot-after-stage-query"),
                                      ("query", "repeat"), ("snapshot", "fixture-snapshot-stage-repeat")])
            self.assertEqual([item["passed"] for item in results], [False, True])
            self.assertEqual([item["expected_repair_delta"] for item in data["counter_expectations"]], [1, 0])
            self.assertTrue(all(item["coverage"] == "proven" for item in data["counter_expectations"]))
            self.assertEqual(data["counter_expectations"][0]["deltas"]["root_repository_authority_changes"], 3)
            self.assertEqual(set(data["phases"]), {"baseline", "after-stage-query", "stage-repeat"})

    def test_counter_schema_is_flattened_uint64_and_never_fallback_zeros(self):
        good = counter_frame()["response"]
        self.assertEqual(live.projection_counters(good)[1], dict.fromkeys(live.COUNTER_FIELDS, 0))
        for field in live.COUNTER_FIELDS:
            maximum = copy.deepcopy(good); maximum["codemap_projection"][field] = 2**64-1
            self.assertEqual(live.projection_counters(maximum)[1][field], 2**64-1)
            missing = copy.deepcopy(good); del missing["codemap_projection"][field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                live.projection_counters(missing)
            for invalid in (True, False, None, -1, 1.0, "1", 2**64, float("nan")):
                bad = copy.deepcopy(good); bad["codemap_projection"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    live.projection_counters(bad)
        for changes in ({"action": "codemap_root_snapshot", "engine_present": False},
                        {"engine_present": False}, {"ok": False}, {"isError": True},
                        {"codemap_projection": {"metrics": good["codemap_projection"]}}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                live.projection_counters({**good, **changes})

    def test_root_attribution_is_sibling_exact_scope_uuid_and_strict_uint64(self):
        good = counter_frame()["response"]
        epoch, counts = live.root_counters(good, ROOT_ID)
        self.assertEqual(epoch, {"scope": "root_epoch", "root_id": ROOT_ID, "root_lifetime_id": ROOT_LIFETIME})
        self.assertEqual(counts, dict.fromkeys(live.ROOT_COUNTER_FIELDS, 0))
        for field in live.ROOT_COUNTER_FIELDS:
            maximum = copy.deepcopy(good); maximum["codemap_root_attribution"][field] = 2**64-1
            self.assertEqual(live.root_counters(maximum, ROOT_ID)[1][field], 2**64-1)
            missing = copy.deepcopy(good); del missing["codemap_root_attribution"][field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                live.root_counters(missing, ROOT_ID)
            for invalid in (None, True, False, -1, 1.0, "1", 2**64, float("nan")):
                bad = copy.deepcopy(good); bad["codemap_root_attribution"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    live.root_counters(bad, ROOT_ID)
                self.assertFalse(live.counter_check(counter_frame(), {**counter_frame(), "response": bad}, 0)["passed"])
        for field, invalid in (("scope", "engine"), ("scope", "ROOT_EPOCH"), ("scope", None),
                               ("root_id", WORKSPACE), ("root_id", None), ("root_id", "not-a-uuid"),
                               ("root_lifetime_id", None), ("root_lifetime_id", "invalid")):
            bad = copy.deepcopy(good); bad["codemap_root_attribution"][field] = invalid
            with self.subTest(field=field, invalid=invalid), self.assertRaises((ValueError, live.bench.BenchmarkError)):
                live.root_counters(bad, ROOT_ID)
        for bad in ({key: value for key, value in good.items() if key != "codemap_root_attribution"},
                    {**good, "codemap_root_attribution": None}):
            with self.assertRaises(ValueError):
                live.root_counters(bad, ROOT_ID)
        nested = copy.deepcopy(good)
        nested["codemap_projection"]["codemap_root_attribution"] = nested.pop("codemap_root_attribution")
        with self.assertRaises(ValueError):
            live.root_counters(nested, ROOT_ID)  # nested/aggregate attribution is not the contract

    def test_root_lifetime_change_and_wrong_root_fail_closed(self):
        before, after = counter_frame((5, 7, 3)), counter_frame((5, 7, 3))
        after["response"]["codemap_root_attribution"]["root_lifetime_id"] = CONTEXT
        check = live.counter_check(before, after, 0, idle=True)
        self.assertEqual(check["coverage"], "unproven")
        self.assertIn("root_lifetime_id changed", check["error"])
        after = counter_frame((5, 7, 3))
        after["response"]["codemap_root_attribution"]["root_id"] = WORKSPACE
        self.assertIn("root_id does not match", live.counter_check(before, after, 0)["error"])
        after = counter_frame((5, 7, 3))
        after["response"]["engine_present"] = False
        self.assertFalse(live.counter_check(before, after, 0)["passed"])

    def test_aggregate_values_never_drive_root_acceptance_or_diagnostic_availability(self):
        base = counter_frame((4, 5, 2)); scope = base["scope"]
        inventory = root_inventory(scope)
        scope_reply = {"ok": True, "op": "worktree_startup_benchmark", "action": "scope",
                       **{key: scope[key] for key in ("window_id", "workspace_id", "context_id", "root_id")}}
        for aggregates in (dict(zip(live.COUNTER_FIELDS, (100, 200, 30))),
                           dict.fromkeys(live.COUNTER_FIELDS, 0), None, {}, {"capability_resolutions": "invalid"}):
            other = copy.deepcopy(base); other["response"]["codemap_projection"] = aggregates
            with self.subTest(aggregates=aggregates):
                check = live.counter_check(base, other, 0, idle=True)
                self.assertTrue(check["passed"])
                self.assertEqual(check["deltas"], dict.fromkeys(live.ROOT_COUNTER_FIELDS, 0))
                runner = Mock()
                runner.call.side_effect = [(value, .01) for value in (inventory, scope_reply, other["response"], inventory)]
                receipt = live.diagnostics(runner, copy.deepcopy(scope), "offline-aggregate", True)
                self.assertTrue(receipt["available"])
                self.assertTrue(receipt["root_attribution_verified"])
                self.assertEqual(receipt["root_counters"], live.root_counters(base["response"], ROOT_ID)[1])
                if aggregates in (None, {}, {"capability_resolutions": "invalid"}):
                    self.assertIsNotNone(receipt["aggregate_diagnostic_error"])

    def test_exact_repairs_reject_mismatch_regression_and_scope_change(self):
        before, after = counter_frame((5, 7, 3)), counter_frame((9, 12, 4), changed=True)
        result = live.counter_check(before, after, 1)
        self.assertTrue(result["passed"])
        self.assertEqual(result["deltas"]["root_repository_authority_changes"], 5)  # observations are not repairs
        repeat = copy.deepcopy(after)
        repeat["response"]["codemap_root_attribution"]["root_capability_resolutions"] += 2
        self.assertTrue(live.counter_check(after, repeat, 0)["passed"])
        self.assertFalse(live.counter_check(after, repeat, 0, idle=True)["passed"])
        for observed in (3, 5):
            bad = copy.deepcopy(after); bad["response"]["codemap_root_attribution"]["root_store_session_repairs"] = observed
            check = live.counter_check(before, bad, 1)
            self.assertFalse(check["passed"])
            self.assertEqual(check["deltas"]["root_store_session_repairs"], observed-3)
        for field in live.ROOT_COUNTER_FIELDS:
            bad = copy.deepcopy(after); bad["response"]["codemap_root_attribution"][field] = before["response"]["codemap_root_attribution"][field]-1
            self.assertIn("regression", live.counter_check(before, bad, 1)["error"])
        for key, value in (("window_id", 99), ("workspace_id", ROOT_ID), ("context_id", ROOT_ID),
                           ("root_id", WORKSPACE), ("root_path", "/private/tmp/other")):
            bad = copy.deepcopy(after); bad["scope"][key] = value
            self.assertFalse(live.counter_check(before, bad, 1)["passed"])
        for key, value in (("available", False), ("single_owned_root_in_window", False), ("response", {}),
                           ("inventory_after", None), ("scope", None)):
            bad = copy.deepcopy(after); bad[key] = value
            self.assertFalse(live.counter_check(before, bad, 1)["passed"])
        self.assertFalse(live.counter_check(before, before, 1)["passed"])  # no demonstrated transition

    def test_window_inventory_does_not_isolate_shared_engine_counters(self):
        base = counter_frame((4, 5, 2))
        scope = base["scope"]
        inventory = root_inventory(scope)
        scope_reply = {"ok": True, "op": "worktree_startup_benchmark", "action": "scope",
                       **{key: scope[key] for key in ("window_id", "workspace_id", "context_id", "root_id")}}
        runner = Mock()
        runner.call.side_effect = [(value, .01) for value in (inventory, scope_reply, base["response"], inventory)]
        receipt = live.diagnostics(runner, copy.deepcopy(scope), "offline", True)
        self.assertTrue(receipt["available"])
        self.assertTrue(receipt["single_owned_root_in_window"])
        self.assertNotIn("single_owned_root", receipt)
        self.assertTrue(receipt["root_attribution_verified"])
        # Another window/root can share this engine and grow aggregates, but the
        # sibling root attribution remains stable and its zero-delta idle check passes.
        for counts in ((4, 5, 2), (8, 9, 3)):
            other = copy.deepcopy(base)
            other["response"]["codemap_projection"] = dict(zip(live.COUNTER_FIELDS, counts))
            check = live.counter_check(base, other, 0, idle=True)
            self.assertEqual(check["coverage"], "proven")
            self.assertTrue(check["passed"])
        aggregate_only = copy.deepcopy(base); del aggregate_only["response"]["codemap_root_attribution"]
        self.assertFalse(live.counter_check(aggregate_only, aggregate_only, 0)["passed"])
        self.assertEqual(receipt["root_counters"]["root_store_session_repairs"], 2)
        actions = [call.args[2].get("action") for call in runner.call.call_args_list]
        self.assertEqual(actions, [None, "scope", "codemap_projection_snapshot", None])
        multiple = copy.deepcopy(inventory)
        window = multiple["runtime"]["windows"][0]
        window["root_count"] = 2; window["roots"].append(copy.deepcopy(window["roots"][0]))
        omitted = copy.deepcopy(inventory); omitted["runtime"]["windows"][0]["omitted_root_count"] = 1
        changed_scope = {**scope_reply, "context_id": ROOT_ID}
        fallback = {**base["response"], "action": "codemap_root_snapshot", "engine_present": False}
        for values in ((multiple,), (omitted,), (inventory, changed_scope),
                       (inventory, scope_reply, fallback),
                       (inventory, scope_reply, base["response"], multiple)):
            runner.call.side_effect = [(value, .01) for value in values]
            with self.subTest(values=values):
                self.assertFalse(live.diagnostics(runner, copy.deepcopy(scope), "offline-invalid", True)["available"])

    def test_failed_first_counter_assertion_cannot_be_erased_by_green_repeat(self):
        phase_names = {"baseline", "after-stage-query", "stage-repeat", "after-commit-query", "commit-repeat",
                       "after-catalog-query", "catalog-repeat", "new-file-settlement", "idle-before", "idle-after"}
        before, too_many = counter_frame(), counter_frame((3, 4, 2), changed=True)
        first = live.counter_check(before, too_many, 1)
        repeat = live.counter_check(too_many, too_many, 0)
        self.assertEqual((first["passed"], repeat["passed"]), (False, True))
        # Aggregation test uses already-validated check outcomes; live capture computes each from its phase frames.
        snapshots = {name: {"phases": {phase: counter_frame() for phase in phase_names},
                            "idle_background": {"coverage": "proven"},
                            "counter_expectations": [{**repeat, "before_phase": "baseline", "after_phase": phase,
                                                      "expected_repair_delta": int(phase in ("after-stage-query", "after-commit-query"))}
                                                     for phase in phase_names-{"baseline"}]}
                     for name in live.LANES}
        args = Mock(require_authority_counters=True, churn=False, cadence=False)
        self.assertEqual(live.authority_acceptance(snapshots, args)["coverage"], "proven")
        changed_epoch = copy.deepcopy(snapshots)
        changed_epoch["catalog-only"]["phases"]["catalog-repeat"]["response"]["codemap_root_attribution"]["root_lifetime_id"] = CONTEXT
        epoch_receipt = live.authority_acceptance(changed_epoch, args)
        self.assertEqual(epoch_receipt["coverage"], "unproven")
        self.assertIn("catalog-only/catalog-repeat", epoch_receipt["invalid_phases"])
        snapshots["original-overlap"]["counter_expectations"].append(first)
        receipt = live.authority_acceptance(snapshots, args)
        self.assertEqual(receipt["coverage"], "unproven")
        self.assertGreaterEqual(receipt["failed_checks"], 1)
        self.assertFalse(first["passed"])
        del snapshots["metadata-only"]["phases"]["commit-repeat"]
        self.assertIn("commit-repeat", live.authority_acceptance(snapshots, args)["missing_phases"]["metadata-only"])
        snapshots["catalog-only"]["counter_expectations"] = []
        self.assertIn("catalog-repeat", live.authority_acceptance(snapshots, args)["missing_checks"]["catalog-only"])

    def test_app_provenance_is_archived_verbatim_and_dirty_is_not_lost(self):
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder).resolve()
            macos = artifact/"Test.app/Contents/MacOS"; macos.mkdir(parents=True)
            resources = macos.parent/"Resources"; resources.mkdir()
            cli = macos/"rpce-cli-debug"; cli.write_bytes(b"offline fake CLI")
            executable = macos/"RepoPrompt"; executable.write_bytes(b"offline fake app")
            (macos.parent/"Info.plist").write_bytes(live.plistlib.dumps({"CFBundleIdentifier": "com.repoprompt.ce.debug"}))
            start = live.datetime(2026, 10, 4).timestamp()
            built = start-10+.4
            payload = {"version": 1, "repoRoot": str(artifact), "worktreePath": str(artifact),
                       "commit": "a"*40, "dirty": True, "buildTimeEpoch": built,
                       "buildTimeISO": live.datetime.fromtimestamp(built, live.timezone.utc).isoformat(timespec="seconds")}
            raw = (json.dumps(payload, indent=2)+"\n").encode()
            (resources/"RepoPromptDebugProvenance.json").write_bytes(raw)
            runner = Mock(); runner.cli = cli; runner.artifact = artifact
            runner.run.return_value = {"stdout": f"123 Sun Oct 4 00:00:00 2026 {executable}"}
            earlier = live.stat_record(executable)
            earlier.update(mtime_ns=int((start-5)*1e9), ctime_ns=int((start-5)*1e9))
            with patch.object(live, "stat_record", return_value=earlier):
                value = live.identity(runner, 123, "offline")
            self.assertTrue(value["running_build_proof"]["process_started_strictly_after_artifacts"])
            self.assertEqual(value["process_identity"]["start_epoch_lower_bound"], start)
            # Old process/new bundle at the same executable path must fail.
            runner.run.return_value = {"stdout": f"123 Sat Jan 1 00:00:00 2000 {executable}"}
            with self.assertRaisesRegex(ValueError, "process start must be strictly later"):
                live.identity(runner, 123, "old-process-new-bundle")
            self.assertEqual(value["app_provenance"], payload)
            self.assertTrue(value["app_provenance"]["dirty"])
            self.assertEqual((artifact/"app-provenance-offline.json").read_bytes(), raw)
            self.assertIn("commit alone", value["source_binding_limitation"])
            for invalid in ({}, {**payload, "dirty": "true"}, {**payload, "commit": None}, {**payload, "version": True},
                            {**payload, "buildTimeEpoch": True}, {**payload, "buildTimeEpoch": float("nan")},
                            {**payload, "buildTimeEpoch": built+20}, {**payload, "buildTimeISO": "2026-10-04T00:00:00"}):
                with self.subTest(value=invalid), self.assertRaises(ValueError):
                    live.parse_app_provenance(json.dumps(invalid))

    def test_running_build_start_rejects_each_newer_artifact_and_same_second_ambiguity(self):
        executable = Path("/physical/Test.app/Contents/MacOS/RepoPrompt")
        process = live.process_identity(f"123 Sun Oct 4 00:00:00 2026 {executable}", 123, executable)
        start = process["start_epoch_lower_bound"]
        provenance = {"buildTimeEpoch": start-2}
        fields = dict(dev=1, ino=2, mode=0o100755, size=64,
                      mtime_ns=int((start-2)*1e9), ctime_ns=int((start-2)*1e9))
        self.assertTrue(live.verify_build_start(process, provenance, fields)["process_started_strictly_after_artifacts"])
        for delta in (0, .1, 1):
            with self.subTest(artifact="build", delta=delta), self.assertRaises(ValueError):
                live.verify_build_start(process, {"buildTimeEpoch": start+delta}, fields)
            for field in ("mtime_ns", "ctime_ns"):
                with self.subTest(artifact=field, delta=delta), self.assertRaises(ValueError):
                    live.verify_build_start(process, provenance, {**fields, field: int((start+delta)*1e9)})
        for raw in (f"124 Sun Oct 4 00:00:00 2026 {executable}",
                    "123 Sun Oct 4 00:00:00 2026 /different/RepoPrompt"):
            with self.assertRaises(ValueError):
                live.process_identity(raw, 123, executable)

    def test_dependencies_fail_clearly_before_fixture_operations(self):
        runner = Mock(); runner.env = {"PATH": "/offline"}
        with patch.object(live.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "missing harness dependencies"):
                live.preflight_dependencies(runner)
            runner.run.assert_not_called()
        with patch.object(live.shutil, "which", side_effect=lambda name, **_: "/fake/"+name):
            runner.run.return_value = {"stdout": "8.18.9"}
            with self.assertRaisesRegex(ValueError, "gitleaks >= 8.19"):
                live.preflight_dependencies(runner)
            runner.run.side_effect = [{"stdout": "8.19.0"}, {"stdout": "dir help"}, {"stdout": "/fake/swiftc"}]
            self.assertEqual(live.preflight_dependencies(runner)["gitleaks_version"], "8.19.0")

    def test_unexpected_exceptions_finalize_evidence_without_live_calls(self):
        for exception in (IndexError("empty workspace"), TypeError("wrong JSON type"), AttributeError("missing field")):
            with self.subTest(exception=type(exception).__name__), tempfile.TemporaryDirectory() as folder:
                artifact = Path(folder).resolve()
                with patch.object(live.tempfile, "mkdtemp", return_value=str(artifact)), patch.object(live.bench, "resolve_cli", return_value=Path("/fake/cli")), patch.object(live, "preflight_dependencies", side_effect=exception), patch.object(live, "identity") as identity, contextlib.redirect_stdout(io.StringIO()):
                    code = live.main(["--confirm-isolated-fixtures", "--window-id", "4", "--context-id", CONTEXT, "--app-pid", "123"])
                self.assertEqual(code, 1); identity.assert_not_called()
                summary = json.loads((artifact/"summary.json").read_text())
                self.assertEqual(summary["status"], "fail")
                self.assertEqual(summary["errors"][0]["exception_type"], type(exception).__name__)
                self.assertEqual(summary["total"], 0)
                self.assertEqual(summary["counter_acceptance"]["coverage"], "unproven")
                self.assertEqual(summary["demand_bound"]["seconds_exclusive"], 10)
                self.assertEqual(list((artifact/"fixtures").iterdir()), [])

    def test_final_identity_interruption_after_green_lanes_retains_failure_and_reraises(self):
        for scenario in ("interrupted", "settings-changed", "identity-changed", "completed"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                artifact = Path(folder).resolve()
                runner = Mock(); runner.cli = Path("/fake/cli"); runner.window = 4; runner.context = CONTEXT
                runner.run.return_value = {"stdout": "offline CLI schema"}
                settings = {"code_maps": {"globally_disabled": False}}
                after_settings = settings if scenario != "settings-changed" else {"code_maps": {"globally_disabled": True}}
                runner.call.side_effect = [(settings, .01), ({}, .01), (after_settings, .01)]
                before = {key: "unchanged" for key in ("process_identity", "executable_stat", "app_sha256", "cli_sha256",
                                                     "app_provenance_sha256", "harness_sha256", "benchmark_helper_sha256")}
                interruption = KeyboardInterrupt("offline final identity interruption")
                after = interruption if scenario == "interrupted" else {**before, **({"app_sha256": "changed"} if scenario == "identity-changed" else {})}
                def green_lane(_runner, name, _bootstrap, results, snapshots, _enabled, _args):
                    results.append({"label": name+"-mock-ready", "passed": True})
                    snapshots[name] = {"phases": {"baseline": counter_frame()}}
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.object(live.tempfile, "mkdtemp", return_value=str(artifact)))
                    stack.enter_context(patch.object(live.bench, "resolve_cli", return_value=runner.cli))
                    stack.enter_context(patch.object(live, "Runner", return_value=runner))
                    stack.enter_context(patch.object(live, "preflight_dependencies", return_value={}))
                    stack.enter_context(patch.object(live.bench, "find_value", side_effect=[False, True]))
                    stack.enter_context(patch.object(live, "identity", side_effect=[before, after]))
                    lanes = stack.enter_context(patch.object(live, "lane", side_effect=green_lane))
                    stack.enter_context(patch.object(live, "authority_acceptance", return_value={"coverage": "proven", "required": True}))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    argv = ["--confirm-isolated-fixtures", "--window-id", "4", "--context-id", CONTEXT,
                            "--app-pid", "123", "--require-authority-counters"]
                    if scenario == "interrupted":
                        with self.assertRaises(KeyboardInterrupt) as raised:
                            live.main(argv)
                        self.assertIs(raised.exception, interruption)
                    else:
                        self.assertEqual(live.main(argv), 0 if scenario == "completed" else 1)
                self.assertEqual(lanes.call_count, len(live.LANES))
                summary = json.loads((artifact/"summary.json").read_text())
                self.assertEqual((summary["total"], summary["passed"], summary["failed"]), (len(live.LANES), len(live.LANES), 0))
                self.assertEqual(summary["counter_acceptance"]["coverage"], "proven")
                self.assertIs(summary["post_run_verification_completed"], scenario == "completed")
                self.assertEqual(summary["status"], "pass-authority-acceptance" if scenario == "completed" else "fail")
                if scenario == "interrupted":
                    self.assertNotIn("build_identity_after", summary)
                    self.assertTrue(summary["errors"][0]["interrupted"])
                    self.assertEqual(summary["errors"][0]["exception_type"], "KeyboardInterrupt")

    def test_missing_false_or_invalid_post_run_verification_cannot_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            args = Mock(require_authority_counters=True, diagnostics=True, require_diagnostics=True, churn=False, cadence=False)
            for value in ("missing", False, None, 1, "true", True):
                summary = {"artifact": folder, "results": [{"passed": True}], "errors": [],
                           "lanes": {name: {} for name in live.LANES}}
                if value != "missing":
                    summary["post_run_verification_completed"] = value
                with self.subTest(value=value), patch.object(live, "authority_acceptance", return_value={"coverage": "proven"}):
                    live.finalize_summary(summary, args)
                    self.assertEqual(summary["status"], "pass-authority-acceptance" if value is True else "fail")

    def test_structure_only_success_is_not_authority_acceptance(self):
        with tempfile.TemporaryDirectory() as folder:
            summary = {"artifact": folder, "results": [{"passed": True}], "errors": [],
                       "lanes": {name: {} for name in live.LANES}, "post_run_verification_completed": True}
            args = Mock(require_authority_counters=False, diagnostics=False, require_diagnostics=False, churn=False, cadence=False)
            live.finalize_summary(summary, args)
            self.assertEqual(summary["status"], "pass-structure-only")
            self.assertEqual(summary["counter_acceptance"]["coverage"], "unproven")
            args.diagnostics = args.require_diagnostics = args.require_authority_counters = True
            live.finalize_summary(summary, args)
            self.assertEqual(summary["status"], "fail")

    def test_idle_requires_real_snapshots_two_seconds_and_no_counter_growth(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = Mock(); runner.artifact = Path(folder)
            root, data = Path(folder)/"offline", {"scope": {}}
            with patch.object(live, "diagnostics", return_value={"available": False}), patch.object(live, "git_state", return_value={}), patch.object(live.time, "sleep") as sleep:
                live.idle_background(runner, root, data, False)
                sleep.assert_not_called()
                self.assertEqual(data["idle_background"]["coverage"], "unproven")
            for growing in (False, *live.ROOT_COUNTER_FIELDS):
                with self.subTest(growing=growing):
                    before, after = counter_frame((5, 7, 3)), counter_frame((5, 7, 3))
                    if growing:
                        after["response"]["codemap_root_attribution"][growing] += 1
                    data = {"scope": {}}
                    with patch.object(live, "diagnostics", side_effect=[before, after]), patch.object(live, "git_state", return_value=before["git_state"]), patch.object(live.time, "sleep") as sleep, patch.object(live.time, "monotonic", side_effect=[100, 102]):
                        live.idle_background(runner, root, data, True)
                    sleep.assert_called_once_with(2)
                    self.assertEqual(data["idle_background"]["coverage"], "unproven" if growing else "proven")

    def test_unchanged_repeat_cannot_erase_failed_first_attempt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)/"fixture"
            runner = Mock()
            runner.artifact = Path(folder); runner.records = []
            runner.call.side_effect = [
                ({"status": "timeout", "files": [], "issues": [{"code": "readiness_timeout"}], "summary": {}}, 10.1),
                (structure(root), 1)]
            results = []
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(live.query(runner, root, "first", results))
                self.assertTrue(live.query(runner, root, "unchanged-repeat", results))
            self.assertEqual([r["passed"] for r in results], [False, True])
            self.assertEqual(runner.call.call_count, 2)


if __name__ == "__main__":
    unittest.main()
