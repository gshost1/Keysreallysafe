"""Offline-only tests for the production-engine Optimizer benchmark."""

import argparse
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

SCRIPT = Path(__file__).resolve().parents[1] / "benchmark-optimizer.py"
SPEC = importlib.util.spec_from_file_location("optimizer_benchmark", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class StubTransport:
    def __init__(self, response):
        self.response = response

    def exchange(self, _message, **_kwargs):
        return self.response


class BenchmarkTests(unittest.TestCase):
    def args(self, **changes):
        values = {
            "live": False,
            "project": None,
            "jev_key": None,
            "keys": "keys",
            "minutes": 5,
            "repetitions": 1,
            "max_calls": 5,
            "timeout": 2.0,
            "initialize_timeout": 3.0,
            "dry_run": False,
            "report": None,
            "suite": "structural",
            "reclassify": None,
        }
        values.update(changes)
        return argparse.Namespace(**values)

    def test_real_compiled_engine_fixtures(self):
        report = benchmark.run(self.args())
        self.assertEqual((report["summary"]["correct"], report["summary"]["cases_run"]), (5, 5))
        self.assertEqual(report["summary"]["accuracy"], 1)
        self.assertEqual(report["usage_source"], "synthetic_mock")
        self.assertEqual(report["summary"]["synthetic_mock_cost_usd"], 0.004)
        self.assertNotIn("provider_reported_cost_usd", report["summary"])
        actual = {item["case_id"]: item["actual"] for item in report["results"]}
        self.assertEqual(actual["tools_stale_dependency"]["reason"], "full_catalog_fallback")
        self.assertEqual(actual["tools_expired"]["reason"], "full_catalog_fallback")
        self.assertEqual(actual["memory_duplicate"]["disposition"], "duplicate")
        self.assertEqual(actual["model_semantic"]["selected_id"], "small")

    def live_row(self, case_id, kind, correct, abstained, actual, requests=1):
        return {"sequence": 1, "case_id": case_id, "kind": kind, "expected": {}, "actual": actual, "correct": correct,
                "abstained": abstained, "latency_ms": 1.0, "usage": {"requests": requests, "cache_hits": 0},
                "usage_unknown_fields": []}

    def test_schema_three_live_report_separates_safe_abstentions_from_unsafe_errors(self):
        # Mirrors the shape of the first live run: both semantic labels missed by abstaining.
        old = {"schema_version": 3, "mode": "live", "summary": {"correct": 3, "accuracy": 0.6, "cases_run": 5}, "results": [
            self.live_row("tools_semantic", "semantic", False, True, {"reason": "full_catalog_fallback", "selected_ids": []}),
            self.live_row("tools_stale_dependency", "stale", True, True, {"reason": "full_catalog_fallback", "selected_ids": []}, 0),
            self.live_row("model_semantic", "semantic", False, True, {"reason": "retain_current_uncertain", "selected_id": "large"}),
        ]}
        report = benchmark.reclassify(old)
        self.assertEqual([item["outcome"] for item in report["results"]], ["safe_abstention", "match", "safe_abstention"])
        self.assertEqual(report["results"][0]["abstention_cause"], "evaluator_declined_scores_not_reported")
        self.assertEqual(report["results"][1]["abstention_cause"], "rejected_before_evaluation")
        summary = report["summary"]
        self.assertEqual((summary["accuracy"], summary["correct"]), (0.6, 3), "legacy fields are preserved")
        self.assertEqual((summary["unsafe_errors"], summary["safe_abstentions"]), (0, 2))
        self.assertEqual(summary["semantic"], {"cases": 2, "matched": 0, "safe_abstentions": 2, "safe_mismatches": 0, "unsafe_errors": 0})
        self.assertEqual(summary["structural"]["matched"], 1)
        self.assertEqual(report["reclassified_from_schema_version"], 3)
        with self.assertRaises(ValueError):
            benchmark.reclassify({"results": "no"})

    def test_acting_against_a_label_is_never_reported_as_safe(self):
        tools = {"selected_ids": []}
        cases = [
            # A stale candidate was selected.
            (self.live_row("tools_stale_dependency", "stale", False, False, {"reason": "tool_candidates_ranked", "selected_ids": ["Read"]}), tools, "unsafe_error"),
            # Status says abstained but the default moved anyway.
            (self.live_row("model_semantic", "semantic", False, True, {"reason": "retain_current_uncertain", "selected_id": "small"}), {"selected_id": "large"}, "unsafe_error"),
            (self.live_row("tools_semantic", "semantic", False, True, {"reason": "full_catalog_fallback", "selected_ids": ["Deploy"]}), tools, "unsafe_error"),
            # No known default for this case: a miss cannot be called safe.
            (self.live_row("unknown_case", "semantic", False, True, {"reason": "full_catalog_fallback", "selected_ids": []}), None, "unsafe_error"),
            (self.live_row("tools_expired", "expired", False, True, {"reason": "evaluation_failed", "selected_ids": []}), tools, "safe_mismatch"),
        ]
        for row, fallback, expected in cases:
            self.assertEqual(benchmark.classify(row, fallback), expected, row["case_id"])
        unavailable = self.live_row("tools_semantic", "semantic", False, True, {"reason": "evaluation_failed", "selected_ids": []})
        self.assertEqual(benchmark.abstention_cause(unavailable, None), "evaluator_unavailable")

    def test_decision_evidence_is_numeric_positional_and_strict(self):
        body = {"decision_evidence": {"threshold": 0.9, "none_fit": 0.2, "outcome": "no_candidate_met_threshold",
                                      "candidates": [{"id": "secret-tool-name", "suitable": 0.82, "conflict": 0.05}]}}
        evidence = benchmark.decision_evidence(body)
        self.assertEqual(evidence["scores"], [{"index": 0, "suitable": 0.82, "conflict": 0.05}])
        self.assertNotIn("secret-tool-name", json.dumps(evidence))
        for bad in ({"threshold": 1.5}, {"none_fit": float("nan")}, {"candidates": [{"suitable": True, "conflict": 0}]}, {"outcome": 3}):
            self.assertIsNone(benchmark.decision_evidence({"decision_evidence": {**body["decision_evidence"], **bad}}))
        self.assertIsNone(benchmark.decision_evidence({}))

    def test_offline_fixture_uses_the_live_threshold_and_reports_evidence(self):
        report = benchmark.run(self.args())
        self.assertEqual(report["schema_version"], 4)
        self.assertEqual(report["summary"]["observed_thresholds"], [0.9])
        self.assertEqual(report["summary"]["unsafe_errors"], 0)
        first = report["results"][0]
        self.assertEqual((first["category"], first["outcome"], first["decision_evidence"]["outcome"]),
                         ("semantic", "match", "candidate_met_threshold"))

    def test_realistic_suite_is_opt_in_and_labels_inclusion_and_exclusion(self):
        self.assertEqual(len(benchmark.chosen(self.args())), 5)
        report = benchmark.run(self.args(suite="realistic"))
        self.assertEqual(report["summary"]["cases_run"], 1)
        row = report["results"][0]
        self.assertEqual((row["case_id"], row["outcome"]), ("tools_realistic_read", "match"))
        self.assertIn("Read", row["actual"]["selected_ids"])
        self.assertNotIn("Deploy", row["actual"]["selected_ids"])
        case = benchmark.REALISTIC_CASES[0]
        self.assertFalse(benchmark.label_correct(case, {"reason": "tool_candidates_ranked", "selected_ids": ["Read", "Deploy"]}))
        self.assertFalse(benchmark.label_correct(case, {"reason": "tool_candidates_ranked", "selected_ids": ["Grep"]}))
        encoded = json.dumps(report)
        self.assertNotIn("tokenizer", encoded)

    def test_reclassify_cli_runs_nothing_and_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "old.json"
            path.write_text(json.dumps({"schema_version": 3, "summary": {"accuracy": 0}, "results": [
                self.live_row("tools_semantic", "semantic", False, True, {"reason": "full_catalog_fallback", "selected_ids": []})]}))
            done = subprocess.run([sys.executable, str(SCRIPT), "--reclassify", str(path), "--keys", "/missing/keys"],
                                  text=True, capture_output=True, timeout=10)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(done.stdout)["summary"]["safe_abstentions"], 1)
            path.write_text("[]")
            self.assertEqual(subprocess.run([sys.executable, str(SCRIPT), "--reclassify", str(path)], capture_output=True, timeout=10).returncode, 2)

    def test_repetitions_preserve_order_and_exercise_shared_engine_cache(self):
        report = benchmark.run(self.args(repetitions=2, max_calls=10))
        self.assertEqual(len(report["results"]), 10)
        self.assertEqual([item["sequence"] for item in report["results"]], list(range(1, 11)))
        first = report["results"][0]
        repeated = report["results"][5]
        self.assertEqual((first["case_id"], repeated["case_id"]), ("tools_semantic", "tools_semantic"))
        self.assertEqual(first["usage"]["requests"], 1)
        self.assertEqual(first["usage"]["cache_hits"], 0)
        self.assertEqual(repeated["usage"]["requests"], 0)
        self.assertEqual(repeated["usage"]["cache_hits"], 1)

    def test_report_is_redacted_and_metrics_are_strict(self):
        encoded = json.dumps(benchmark.run(self.args()))
        for forbidden in ('"request_text"', '"candidates"', '"capabilities"', "project-a"):
            self.assertNotIn(forbidden, encoded)
        known, unknown = benchmark.usage(
            {
                "usage": {
                    "requests": -1,
                    "cache_hits": 0.5,
                    "actual_input_tokens": "bad",
                    "actual_output_tokens": float("nan"),
                    "optimizer_cost_usd": float("inf"),
                }
            }
        )
        self.assertEqual(known, {})
        self.assertEqual(
            set(unknown),
            {"requests", "cache_hits", "actual_input_tokens", "actual_output_tokens", "optimizer_cost_usd"},
        )

    def test_offline_subprocess_environment_is_allowlisted(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout='[{"case_id":"tools_semantic","result":{},"latency_ms":0}]',
            stderr="",
        )
        with mock.patch.dict(
            benchmark.os.environ,
            {"PATH": "/bin", "HOME": "/tmp/home", "NODE_OPTIONS": "--inspect", "AI_GATEWAY_API_KEY": "secret"},
            clear=True,
        ), mock.patch.object(benchmark, "ENGINE_BUILD", benchmark.HARNESS), \
                mock.patch.object(benchmark.subprocess, "run", return_value=completed) as run:
            benchmark.offline([benchmark.CASES[0]])
        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment, {"PATH": "/bin", "HOME": "/tmp/home"})

    def test_fresh_checkout_without_compiled_engine_gets_an_actionable_error(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "dist" / "index.js"
            with mock.patch.object(benchmark, "ENGINE_BUILD", missing), \
                    mock.patch.object(benchmark.subprocess, "run") as run, \
                    mock.patch.object(benchmark.sys, "stderr", new=io.StringIO()) as stderr:
                with self.assertRaises(benchmark.MissingEngineBuild):
                    benchmark.offline([benchmark.CASES[0]])
                self.assertEqual(benchmark.main([]), 2)
            run.assert_not_called()
            self.assertIn("npm ci && npm run build", stderr.getvalue())

    def test_dry_run_does_not_launch_and_minutes_are_bounded(self):
        report = benchmark.run(self.args(repetitions=3, max_calls=7, dry_run=True, live=True))
        self.assertEqual(report["plan"]["planned_optimizer_calls"], 7)
        self.assertFalse(report["plan"]["will_launch_keys"])
        base = [
            sys.executable,
            str(SCRIPT),
            "--live",
            "--project",
            str(uuid.uuid4()),
            "--jev-key",
            "jev",
            "--keys",
            "/missing/keys",
            "--dry-run",
        ]
        self.assertEqual(subprocess.run(base, capture_output=True, timeout=5).returncode, 0)
        self.assertNotEqual(subprocess.run(base + ["--minutes", "0"], capture_output=True, timeout=5).returncode, 0)
        self.assertNotEqual(subprocess.run(base + ["--minutes", "121"], capture_output=True, timeout=5).returncode, 0)

    def helper(self, body, timeout=1):
        return benchmark.StdioTransport(
            [sys.executable, "-c", body],
            call_timeout=timeout,
            initialize_timeout=timeout,
        )

    def test_partial_line_is_bounded_and_delayed(self):
        code = (
            "import sys,time,json;"
            "m=json.loads(sys.stdin.buffer.readline());"
            "sys.stdout.write('{\"jsonrpc\":\"2.0\",');sys.stdout.flush();time.sleep(.05);"
            "sys.stdout.write('\"id\":%s,\"result\":{}}\\n'%m['id']);sys.stdout.flush()"
        )
        transport = self.helper(code)
        response = transport.exchange({"jsonrpc": "2.0", "id": 4, "method": "ping", "params": {}})
        self.assertEqual(response["id"], 4)
        transport.close()
        self.assertIsNotNone(transport.process.returncode)

    def test_protocol_and_tool_errors_are_rejected(self):
        code = "import sys;sys.stdin.buffer.readline();sys.stdout.write('not json\\n');sys.stdout.flush()"
        transport = self.helper(code)
        with self.assertRaisesRegex(RuntimeError, "invalid_mcp_json"):
            transport.exchange({"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}})
        transport.close()

        client = benchmark.MCPClient(
            StubTransport({"jsonrpc": "2.0", "id": 1, "result": ["not", "object"]})
        )
        with self.assertRaisesRegex(RuntimeError, "invalid_mcp_result"):
            client.request("ping", {})
        client = benchmark.MCPClient(
            StubTransport({"jsonrpc": "2.0", "id": 1, "result": {"isError": True}})
        )
        with self.assertRaisesRegex(RuntimeError, "mcp_tool_error"):
            client.call("keys_tools_select", {})

    def test_read_only_cleanup_closes_stdin(self):
        transport = self.helper("import sys;sys.stdin.buffer.read()")
        transport.close()
        self.assertEqual(transport.process.returncode, 0)

    def test_cli_export_matches_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            process = subprocess.run(
                [sys.executable, str(SCRIPT), "--report", str(path)],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(json.loads(process.stdout), json.loads(path.read_text()))


if __name__ == "__main__":
    unittest.main()
