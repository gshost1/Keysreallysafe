"""Mock-only tests for the paired savings evaluation. No model, provider or Keys process runs."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "paired-savings-eval.py"
SPEC = importlib.util.spec_from_file_location("paired_savings_eval", SCRIPT)
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)

PASS = [{"name": "unit tests", "passed": True}]
NONE = {"occurred": False}


def arm(input_tokens, output_tokens, cost, checks=PASS, **extra):
    usage = {"input_tokens": input_tokens, "output_tokens": output_tokens}
    if cost is not None:
        usage["reported_cost_usd"] = cost
    return {"task_fingerprint": "t1", "context_fingerprint": "c1", "model": "client-model",
            "provider_usage": usage, "checks": checks, **extra}


def treatment(input_tokens, output_tokens, cost, overhead=None, **extra):
    overhead = {"input_tokens": 600, "output_tokens": 60, "reported_cost_usd": 0.01} if overhead is None else overhead
    return arm(input_tokens, output_tokens, cost, optimizer_usage=overhead,
               **{"cache_rebuild": NONE, "fallback": NONE, **extra})


class PairedSavingsTests(unittest.TestCase):
    def test_mismatched_or_duplicate_quality_checks_are_not_comparable(self):
        for checks in ([{"name": "different check", "passed": True}], PASS + PASS):
            result = self.one(arm(10000, 1000, 0.2), treatment(100, 10, 0.01, checks=checks))
            self.assertFalse(result["pairs"][0]["counts_toward_measured_savings"])
            self.assertIn("quality_check_set", result["pairs"][0]["not_comparable_fields"])

    def test_extreme_numbers_and_missing_event_counts_stay_unknown(self):
        for value in (10 ** 400, True, float("inf"), -1):
            self.assertIsNone(paired.money(value))
            self.assertIsNone(paired.count(value))
        for optimizer in ({}, {"events": False}, {"events": "0"}):
            result = paired.collect({"pairs": [{"treatment": {"task_id": "t"}}]},
                                    {"tasks": [{"id": "t", "aggregate": {"optimizer": optimizer}}]})
            self.assertEqual(result["pairs"][0]["treatment"]["optimizer_usage"], {})
        self.assertEqual(paired.ledger_usage({"events": 1, "input_tokens_known": 0,
                                             "input_tokens_unknown_events": False}), {})

    def one(self, baseline, treated):
        return paired.report({"pairs": [{"pair_id": "p", "baseline": baseline, "treatment": treated}]})

    def test_net_savings_subtract_optimizer_overhead_rebuild_and_fallback(self):
        treated = treatment(6000, 900, 0.10,
                            cache_rebuild={"occurred": True, "input_tokens": 1500, "output_tokens": 0, "reported_cost_usd": 0.02},
                            fallback={"occurred": True, "input_tokens": 400, "output_tokens": 40, "reported_cost_usd": 0.005})
        row = self.one(arm(10000, 1000, 0.20), treated)["pairs"][0]
        self.assertEqual(row["gross_client_token_savings_before_overhead"], 4100)
        self.assertEqual(row["net_token_savings"], 11000 - (6900 + 660 + 1500 + 440))
        self.assertAlmostEqual(row["net_reported_cost_savings_usd"], 0.20 - (0.10 + 0.01 + 0.02 + 0.005))
        self.assertTrue(row["counts_toward_measured_savings"])
        self.assertEqual(row["unknown_fields"], [])

    def test_overhead_can_make_the_treatment_more_expensive(self):
        report = self.one(arm(1000, 100, 0.01), treatment(900, 100, 0.009))
        row = report["pairs"][0]
        self.assertEqual(row["net_token_savings"], 1100 - (1000 + 660))
        self.assertEqual(report["summary"]["general_task_pairs"]["net_token_savings"]["pairs_where_treatment_used_more"], 1)

    def test_unknown_cost_stays_unknown_and_is_never_estimated(self):
        report = self.one(arm(10000, 1000, None, estimated_input_bytes=40000), treatment(6000, 900, 0.10, estimated_input_bytes=30000))
        row = report["pairs"][0]
        self.assertIsNone(row["net_reported_cost_savings_usd"])
        self.assertIn("baseline.reported_cost_usd", row["unknown_fields"])
        self.assertIsNotNone(row["net_token_savings"], "tokens were reported, so they remain measurable")
        cost = report["summary"]["general_task_pairs"]["net_reported_cost_savings_usd"]
        self.assertEqual((cost["pairs_known"], cost["pairs_unknown"], cost["sum_of_known"]), (0, 1, None))
        estimate = row["estimate_vs_provider"]["baseline"]
        self.assertEqual((estimate["estimated_input_tokens_at_4_bytes"], estimate["provider_input_tokens"]), (10000, 10000))

    def test_unstated_rebuild_or_fallback_and_missing_overhead_block_a_net_figure(self):
        treated = treatment(6000, 900, 0.10)
        del treated["cache_rebuild"]
        row = self.one(arm(10000, 1000, 0.20), treated)["pairs"][0]
        self.assertIsNone(row["net_token_savings"])
        self.assertIn("cache_rebuild.input_tokens", row["unknown_fields"])
        self.assertFalse(row["counts_toward_measured_savings"])
        row = self.one(arm(10000, 1000, 0.20), treatment(6000, 900, 0.10, overhead={}))["pairs"][0]
        self.assertIsNone(row["net_token_savings"])
        for bad in (-1, 1.5, True, "7", float("nan")):
            self.assertIsNone(paired.known_usage({"input_tokens": bad})["input_tokens"], bad)

    def test_quality_regression_or_unknown_quality_never_counts_as_savings(self):
        failed = [{"name": "unit tests", "passed": False}]
        for treated_checks, baseline_checks, verdict in ((failed, PASS, "regression"), (PASS, failed, "baseline_failed"), ([], PASS, "unknown")):
            report = self.one(arm(10000, 1000, 0.2, checks=baseline_checks), treatment(100, 10, 0.01, checks=treated_checks))
            row = report["pairs"][0]
            self.assertEqual(row["quality_verdict"], verdict)
            self.assertFalse(row["counts_toward_measured_savings"])
            self.assertEqual(report["summary"]["general_task_pairs"]["eligible"], 0)
            self.assertIsNone(report["summary"]["measured_savings_claim"])

    def test_different_context_or_model_is_not_a_pair(self):
        other = treatment(100, 10, 0.01)
        other["context_fingerprint"] = "c2"
        other["model"] = "cheaper-model"
        report = self.one(arm(10000, 1000, 0.2), other)
        self.assertEqual(report["pairs"][0]["not_comparable_fields"], ["context_fingerprint", "model"])
        self.assertEqual(report["summary"]["general_task_pairs"]["eligible"], 0)

    def test_cache_replay_is_reported_apart_from_general_tasks(self):
        replay = treatment(0, 0, 0, overhead={"input_tokens": 0, "output_tokens": 0, "reported_cost_usd": 0}, cache_replay=True)
        report = paired.report({"pairs": [
            {"pair_id": "replay", "baseline": arm(635, 60, 0), "treatment": replay},
            {"pair_id": "general", "baseline": arm(10000, 1000, 0.2), "treatment": treatment(9000, 1000, 0.18)},
        ]})
        summary = report["summary"]
        self.assertEqual(summary["cache_replay_pairs"]["net_token_savings"]["sum_of_known"], 695)
        self.assertEqual(summary["general_task_pairs"]["eligible"], 1)
        self.assertEqual(summary["general_task_pairs"]["net_token_savings"]["sum_of_known"], 11000 - 10660)
        self.assertFalse(report["pairs"][0]["counts_toward_measured_savings"])

    def test_collect_reads_keys_task_accounting_and_keeps_incomplete_totals_unknown(self):
        def totals(events, tokens, unknown=0, cost_unknown=0):
            return {"events": events, "input_tokens_known": tokens, "input_tokens_unknown_events": unknown,
                    "output_tokens_known": 50, "output_tokens_unknown_events": 0, "cache_read_tokens_known": 0,
                    "cache_read_tokens_unknown_events": 0, "reported_cost_usd_known": 0.1, "reported_cost_usd_unknown_events": cost_unknown}
        status = {"tasks": [
            {"id": "base-1", "aggregate": {"client": totals(3, 9000), "optimizer": totals(0, 0)}},
            {"id": "treat-1", "aggregate": {"client": totals(3, 7000, cost_unknown=1), "optimizer": totals(2, 1200)}},
            {"id": "base-2", "aggregate": {"client": totals(2, 500, unknown=1), "optimizer": totals(1, 600)}},
        ]}
        shared = {"task_fingerprint": "t", "context_fingerprint": "c", "model": "m", "checks": PASS}
        manifest = {"pairs": [
            {"pair_id": "one", "baseline": {**shared, "task_id": "base-1"}, "treatment": {**shared, "task_id": "treat-1", "cache_rebuild": NONE, "fallback": NONE}},
            {"pair_id": "two", "baseline": {**shared, "task_id": "base-2"}, "treatment": {**shared, "task_id": "missing", "cache_rebuild": NONE, "fallback": NONE}},
        ]}
        report = paired.report(paired.collect(manifest, status))
        first, second = report["pairs"]
        self.assertEqual(first["net_token_savings"], 9050 - (7050 + 1250))
        self.assertIsNone(first["net_reported_cost_savings_usd"], "one treatment event had no reported cost")
        self.assertIn("treatment_client.reported_cost_usd", first["unknown_fields"])
        self.assertIn("baseline_has_optimizer_events", second["not_comparable_fields"])
        self.assertIn("baseline.input_tokens", second["unknown_fields"], "a total with unknown events is incomplete")
        self.assertIn("optimizer_overhead.input_tokens", second["unknown_fields"], "a task absent from the ledger has unknown overhead")

    def test_plan_is_a_dry_run_and_cli_round_trips(self):
        plan = paired.plan({"tasks": [{"id": "a", "checks": ["swift test"]}, {"id": "b"}]})
        self.assertEqual(plan["will_launch"], {"models": False, "provider_requests": False, "keys": False, "presence_prompt": False})
        self.assertEqual([item["order"][0] for item in plan["run_sheet"]], ["baseline", "treatment"], "arm order alternates")
        self.assertTrue(plan["run_sheet"][1]["checks_missing"])
        with tempfile.TemporaryDirectory() as directory:
            pairs = Path(directory) / "pairs.json"
            pairs.write_text(json.dumps({"pairs": [{"pair_id": "p", "baseline": arm(10, 1, 0), "treatment": treatment(5, 1, 0)}]}))
            out = Path(directory) / "report.json"
            done = subprocess.run([sys.executable, str(SCRIPT), "report", "--pairs", str(pairs), "--out", str(out)], text=True, capture_output=True, timeout=10)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(done.stdout), json.loads(out.read_text()))
            self.assertIn("Not a general savings rate", json.loads(done.stdout)["interpretation"])
            pairs.write_text("{not json")
            self.assertEqual(subprocess.run([sys.executable, str(SCRIPT), "report", "--pairs", str(pairs)], capture_output=True, timeout=10).returncode, 2)
        with self.assertRaises(paired.InputError):
            paired.report({"pairs": [{}] * (paired.MAX_PAIRS + 1)})


if __name__ == "__main__":
    unittest.main()
