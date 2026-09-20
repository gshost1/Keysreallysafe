"""Offline-only tests for the production-engine Optimizer benchmark."""

import argparse
import importlib.util
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
        ), mock.patch.object(benchmark.subprocess, "run", return_value=completed) as run:
            benchmark.offline([benchmark.CASES[0]])
        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment, {"PATH": "/bin", "HOME": "/tmp/home"})

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
