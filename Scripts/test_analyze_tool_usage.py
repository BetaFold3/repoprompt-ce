#!/usr/bin/env python3
"""Synthetic-only regressions for the offline tool-usage analyzer."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import analyze_tool_usage as analyzer

APRIL = "2026-04-04T00:00:00Z"
MAY = "2026-05-04T00:00:00Z"


def codex(kind, timestamp=APRIL, **payload):
    return {"timestamp": timestamp, "type": "event_msg" if kind == "token_count" else "response_item",
            "payload": {"type": kind, **payload}}


def call(identifier, name="read_file", namespace="mcp__RepoPromptCE", args=None, timestamp=APRIL):
    return codex("function_call", timestamp, call_id=identifier, name=name,
                 namespace=namespace, arguments=json.dumps(args or {}))


def output(identifier, value, timestamp=APRIL):
    return codex("function_call_output", timestamp, call_id=identifier, output=value)


def user(timestamp=APRIL):
    return codex("message", timestamp, role="user", content=[{"type": "input_text", "text": "synthetic private prompt"}])


def claude(kind, content, timestamp=APRIL, **message):
    return {"type": kind, "timestamp": timestamp, "sessionId": "synthetic-session",
            "message": {"content": content, **message}}


def use(identifier, name, **args):
    return {"type": "tool_use", "id": identifier, "name": name, "input": args}


def result(identifier, content):
    return {"type": "tool_result", "tool_use_id": identifier, "content": content}


class ToolUsageTests(unittest.TestCase):
    def analyze(self, claude_records=(), codex_records=(), **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for provider, records in (("claude", claude_records), ("codex", codex_records)):
                path = root / (provider + ".jsonl")
                with path.open("w", encoding="utf-8") as stream:
                    for record in records:
                        stream.write(record if isinstance(record, str) else json.dumps(record, ensure_ascii=False) + "\n")
            return analyzer.analyze_roots([root / "claude.jsonl"], [root / "codex.jsonl"], **kwargs)

    def row(self, summary, tool, provider="all", month="all"):
        return next(row for row in summary["tools"]
                    if (row["tool"], row["provider"], row["month"]) == (tool, provider, month))

    def test_claude_multiblock_list_user_unicode_and_tokens(self):
        summary = self.analyze(claude_records=[
            claude("user", [{"type": "text", "text": "synthetic prompt"}]),
            claude("assistant", [use("c1", "mcp__RepoPromptCE__read_file", path="src/example.py"),
                                 use("c2", "mcp__AnotherServer__lookup")], id="message-one",
                   usage={"input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5, "output_tokens": 2}),
            claude("user", [result("c1", [{"type": "text", "text": "é"},
                                        {"type": "text", "text": "🙂"}]),
                            result("c2", "ok")]),
        ])
        read = self.row(summary, "RP:read_file")
        self.assertEqual((read["calls"], read["chars"]["total"], read["bytes"]["total"]), (1, 2, 6))
        data = summary["providers"]["Claude"]
        self.assertEqual(data["turns"]["all_observed"]["rp_calls"]["count"], 1)
        self.assertEqual(data["parallelism"]["multi_call_batches"], 1)
        self.assertEqual(data["tokens"]["reported_input_including_cache"], 35)
        self.assertEqual(data["tokens"]["totals"]["cached_input"], 20)
        self.assertEqual(self.row(summary, "MCP_OTHER:lookup")["calls"], 1)

    def test_codex_namespace_attribution_unmatched_and_native(self):
        summary = self.analyze(codex_records=[
            user(), call("d1"), call("d2", "git", "mcp__RepoPrompt__", {"op": "diff", "artifacts": True}),
            call("d3", "read_file", ""), call("d4", "lookup", "mcp__Other"),
            output("d1", "aaaa"), output("d2", "b"), output("d3", "cc"),
            output("d4", "d"), output("missing", "unknown output"),
        ])
        self.assertEqual(self.row(summary, "RP:read_file")["calls"], 1)
        self.assertEqual(self.row(summary, "NATIVE:read_file")["calls"], 1)
        self.assertEqual(self.row(summary, "MCP_OTHER:lookup")["calls"], 1)
        self.assertEqual(summary["providers"]["Codex"]["coverage"]["unmatched_outputs"], 1)
        self.assertEqual(summary["providers"]["Codex"]["git"]["repoprompt_op_artifacts"], {"diff:true": 1})
        self.assertEqual(summary["providers"]["Codex"]["parallelism"]["assistant_tool_batch_sizes"], {4: 1})

    def test_exec_nested_promise_all_no_output_double_counting(self):
        script = """// tools.mcp__RepoPromptCE__git({})
const prose = "tools.mcp__RepoPromptCE__apply_edits({})";
const results = await Promise.all([
  tools.mcp__RepoPromptCE__read_file({path:"src/example.py"}),
  tools.mcp__RepoPrompt____file_search({pattern:"x"}),
  tools.exec_command({cmd:"true"})
]);"""
        summary = self.analyze(codex_records=[
            user(), codex("custom_tool_call", call_id="x1", name="exec", input=script),
            codex("custom_tool_call_output", call_id="x1", output="script output"),
            codex("custom_tool_call", call_id="x2", name="js", input="await tools.mcp__RepoPromptCE__get_file_tree({});"),
            codex("custom_tool_call_output", call_id="x2", output="second"),
        ])
        ex = summary["codex_exec"]
        self.assertEqual((ex["scripts"], ex["scripts_calling_repoprompt"], ex["promise_all_scripts"], ex["multiple_tool_call_scripts"]), (2, 2, 1, 1))
        self.assertEqual(ex["nested_call_sites_by_tool"], {
            "RP:read_file": 1, "RP:file_search": 1, "NATIVE:exec_command": 1, "RP:get_file_tree": 1,
        })
        self.assertEqual(summary["totals"]["repoprompt_output_chars"], 0)
        self.assertEqual(summary["totals"]["tool_output_chars"], len("script outputsecond"))
        self.assertEqual(summary["providers"]["Codex"]["coverage"]["files_with_repoprompt_calls"], 1)
        self.assertEqual(summary["providers"]["Codex"]["turns"]["estimated_rp_calls_including_script_sites"]["median"], 3)
        self.assertEqual(summary["providers"]["Codex"]["turns"]["composition_opportunities_including_script_sites_estimate"], 1)

    def test_duplicate_calls_outputs_and_streamed_claude_usage(self):
        assistant = claude("assistant", [use("c1", "mcp__RepoPromptCE__read_file")], id="same",
                           usage={"input_tokens": 10, "output_tokens": 1})
        summary = self.analyze(claude_records=[
            claude("user", "prompt"), assistant, assistant,
            claude("assistant", [], id="same", usage={"input_tokens": 10, "output_tokens": 4}),
            claude("user", [result("c1", "same output")]),
            claude("user", [result("c1", "same output")]),
        ])
        self.assertEqual(self.row(summary, "RP:read_file")["calls"], 1)
        self.assertEqual(self.row(summary, "RP:read_file")["chars"]["count"], 1)
        self.assertEqual(summary["providers"]["Claude"]["tokens"]["totals"]["input"], 10)
        self.assertEqual(summary["providers"]["Claude"]["tokens"]["totals"]["output"], 4)
        self.assertEqual(summary["providers"]["Claude"]["coverage"]["duplicate_records"], 2)

    def test_window_boundaries_months_and_pre_window_attribution(self):
        before = "2026-04-02T23:59:59Z"
        until = analyzer.DEFAULT_UNTIL
        summary = self.analyze(codex_records=[
            call("old", timestamp=before), output("old", "old output"),
            user(), call("a"), output("a", "april"),
            user(MAY), call("b", timestamp=MAY), output("b", "may", MAY),
            call("excluded", timestamp=until), output("excluded", "excluded", until),
            {"timestamp": "not-a-date", "payload": {}},
        ])
        row = self.row(summary, "RP:read_file")
        self.assertEqual((row["calls"], row["chars"]["count"]), (2, 3))
        self.assertEqual(self.row(summary, "RP:read_file", "Codex", "2026-05")["chars"]["total"], 3)
        cov = summary["providers"]["Codex"]["coverage"]
        self.assertEqual(cov["records_outside_window"], 3)
        self.assertEqual(cov["outputs_for_calls_outside_window"], 1)
        self.assertEqual(cov["missing_or_invalid_timestamps"], 1)
        self.assertEqual(cov["unmatched_outputs"], 0)

    def test_malformed_truncated_oversized_and_nonobject_lines(self):
        summary = self.analyze(codex_records=[
            "{not-json}\n", '{"timestamp":\n', "\n", "null\n",
            "x" * 501 + "\n",
            call("one"), output("one", "ok"),
        ], max_line_bytes=500)
        cov = summary["providers"]["Codex"]["coverage"]
        self.assertEqual(cov["malformed_lines"], 3)
        self.assertEqual(cov["non_object_records"], 1)
        self.assertEqual(cov["oversized_lines"], 1)
        self.assertEqual(self.row(summary, "RP:read_file")["chars"]["total"], 2)

    def test_search_join_read_shape_repeats_chains_and_turn_reset(self):
        summary = self.analyze(codex_records=[
            user(), call("s1", "file_search"), output("s1", "`src/example.py`\nLimit reached"),
            call("r1", args={"path": "src/example.py", "start_line": 2, "limit": 4}), output("r1", "abc"),
            call("r2", args={"path": "src/example.py"}), output("r2", "12345"),
            call("native", "exec_command", "", {"cmd": "true"}), output("native", ""),
            user(MAY), call("r3", args={"path": "src/example.py"}, timestamp=MAY), output("r3", "xx", MAY),
        ])
        data = summary["providers"]["Codex"]
        read = data["read_file"]
        self.assertEqual((read["calls"], read["ranged"], read["repeated"], read["repeated_output_chars"]), (3, 1, 2, 7))
        self.assertEqual(read["search_to_read_joins"], 2)
        self.assertEqual(data["file_search"]["truncation_rate"], 1)
        self.assertEqual(data["turns"]["composition_opportunities"], 1)
        self.assertEqual(data["turns"]["exploration_chains"]["total"], 4)
        self.assertEqual(data["turns"]["with_repoprompt"]["rp_calls"]["median"], 2)

    def test_json_truncation_markers_and_nontext_content(self):
        for value in ({"truncated": True}, {"omitted_count": 2},
                      [{"type": "text", "text": '{"limitReached":true}'}]):
            with self.subTest(value=value):
                summary = self.analyze(codex_records=[call("s", "file_search"), output("s", value)])
                self.assertEqual(summary["providers"]["Codex"]["file_search"]["truncation_rate"], 1)
        value = [{"type": "image", "data": "synthetic"}]
        summary = self.analyze(codex_records=[call("r"), output("r", value)])
        self.assertEqual(self.row(summary, "RP:read_file")["chars"]["total"],
                         len(json.dumps(value[0], ensure_ascii=False, sort_keys=True)))
        self.assertFalse(analyzer.is_truncated({"truncated": False}, "Status: Complete"))

    def test_token_deltas_repeated_checkpoints_and_missing_usage(self):
        def tokens(total, last, time=APRIL):
            return codex("token_count", time, info={"total_token_usage": {
                "input_tokens": total, "cached_input_tokens": total // 2, "output_tokens": total // 10,
            }, "last_token_usage": {"input_tokens": last, "cached_input_tokens": last // 2, "output_tokens": last // 10}})
        summary = self.analyze(codex_records=[
            tokens(100, 100, "2026-04-02T23:59:59Z"), user(),
            tokens(120, 20), tokens(120, 20), tokens(160, 40),
            codex("token_count", info=None),
        ])
        data = summary["providers"]["Codex"]["tokens"]
        self.assertEqual(data["totals"], {"input": 60, "cached_input": 30, "cache_creation_input": 0, "output": 6})
        self.assertEqual(data["turns_with_usage"], 1)
        self.assertEqual(data["per_observed_turn_with_usage"]["input"]["median"], 60)
        self.assertEqual(summary["providers"]["Codex"]["coverage"]["token_count_events_without_valid_usage"], 1)

    def test_git_shell_multiple_commands_flags_quotes_and_list(self):
        summary = self.analyze(
            claude_records=[claude("assistant", [use("b1", "Bash", command='git status; git -C "a directory" diff; echo "git push"')])],
            codex_records=[call("b2", "exec_command", "", {"cmd": "cd synthetic && git -c color.ui=false log | cat\ngit --no-pager show"}),
                           call("b3", "shell", "", {"command": ["bash", "-lc", "git status && git diff"]})],
        )
        self.assertEqual(summary["providers"]["Claude"]["git"]["shell_subcommands"], {"status": 1, "diff": 1})
        self.assertEqual(summary["providers"]["Codex"]["git"]["shell_subcommands"], {"log": 1, "show": 1, "status": 1, "diff": 1})

    def test_exact_percentiles_and_multi_output_invocation(self):
        records = [call("r")]
        records += [output("r", "x" * n) for n in range(1, 11)]
        summary = self.analyze(codex_records=records)
        row = self.row(summary, "RP:read_file")
        self.assertEqual(row["calls"], 1)
        self.assertEqual(row["calls_with_output"], 1)
        self.assertEqual(row["chars"], {"count": 10, "total": 55, "median": 5.5, "p90": 9, "p99": 10, "max": 10})

    def test_cli_report_privacy_and_explicit_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "private-workspace.jsonl"
            secret = "DO_NOT_EXPORT_PRIVATE_SENTINEL"
            source.write_text("\n".join(json.dumps(r) for r in [
                user(), call("private-session-id", args={"path": "src/" + secret + ".py"}),
                output("private-session-id", secret),
            ]) + "\n")
            report_json, report_md = root / "report.json", root / "report.md"
            process = subprocess.run([
                sys.executable, str(Path(analyzer.__file__)), "--codex-root", str(source),
                "--claude-root", str(root / "absent"), "--json", str(report_json), "--markdown", str(report_md),
            ], capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout, "")
            for report in (report_json, report_md):
                text = report.read_text()
                for private in (secret, "private-session-id", "private-workspace", str(root)):
                    self.assertNotIn(private, text)
            parsed = json.loads(report_json.read_text())
            self.assertEqual(parsed["providers"]["Claude"]["coverage"]["missing_roots"], 1)

    def test_duplicate_user_boundary_preserves_exploration_chain(self):
        boundary = user()
        summary = self.analyze(codex_records=[
            boundary, call("r1"), output("r1", "one"), boundary,
            call("r2"), output("r2", "two"), call("r2"), output("r2", "two"),
            call("r3"), output("r3", "three"),
        ])
        data = summary["providers"]["Codex"]
        self.assertEqual(data["turns"]["all_observed"]["rp_calls"]["count"], 1)
        self.assertEqual(data["turns"]["exploration_chains"]["max"], 3)
        self.assertEqual(data["turns"]["composition_opportunities"], 1)
        self.assertEqual(data["coverage"]["duplicate_records"], 3)

    def test_token_initial_checkpoint_and_reset_use_last_not_inherited_total(self):
        def event(total, last, date):
            return codex("token_count", date, info={
                "total_token_usage": {"input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0},
                "last_token_usage": {"input_tokens": last, "cached_input_tokens": 0, "output_tokens": 0},
            })
        summary = self.analyze(codex_records=[
            user(), event(1000, 10, APRIL), event(5, 5, MAY),
        ])
        data = summary["providers"]["Codex"]
        self.assertEqual(data["tokens"]["totals"]["input"], 15)
        self.assertEqual(data["coverage"]["initial_token_checkpoints_using_last"], 1)
        self.assertEqual(data["coverage"]["token_counter_resets_using_last"], 1)

    def test_legacy_js_code_argument_preserves_namespace_attribution(self):
        summary = self.analyze(codex_records=[
            user(), call("legacy", "js", "mcp__SyntheticRuntime", {
                "code": "await tools.mcp__RepoPromptCE__read_file({});",
            }), output("legacy", "synthetic JS output"),
        ])
        self.assertEqual(self.row(summary, "MCP_OTHER:js")["calls"], 1)
        self.assertEqual(summary["codex_exec"]["scripts"], 1)
        self.assertEqual(summary["codex_exec"]["scripts_calling_repoprompt"], 1)
        self.assertEqual(summary["codex_exec"]["nested_call_sites_by_tool"], {"RP:read_file": 1})

    def test_replayed_ids_with_changed_timestamps_deduplicate_but_keep_new_fragments(self):
        summary = self.analyze(codex_records=[
            call("replay"), output("replay", "first"),
            call("replay", timestamp=MAY), output("replay", "first", MAY),
            output("replay", "second", MAY),
        ])
        row = self.row(summary, "RP:read_file")
        self.assertEqual((row["calls"], row["chars"]["count"], row["chars"]["total"]), (1, 2, 11))
        coverage = summary["providers"]["Codex"]["coverage"]
        self.assertEqual(coverage["duplicate_call_ids"], 1)
        self.assertEqual(coverage["duplicate_outputs"], 1)

    def test_invalid_window_and_limit_fail_closed(self):
        for kwargs in ({"since": "2026-10-04", "until": "2026-04-03"},
                       {"since": analyzer.DEFAULT_UNTIL}, {"max_line_bytes": 0}):
            with self.subTest(kwargs=kwargs), self.assertRaises(analyzer.AnalyzerError):
                self.analyze(**kwargs)


if __name__ == "__main__":
    unittest.main()
