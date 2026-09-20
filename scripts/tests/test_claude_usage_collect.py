"""Fixture-only tests for the Claude usage collector. No client, provider or network call.

Every fixture is written here from the shapes observed in real local logs; no
recorded conversation is read, and the privacy test asserts that content given to
the collector never reaches its output.
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "claude-usage-collect.py"
SPEC = importlib.util.spec_from_file_location("claude_usage_collect", SCRIPT)
collect = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collect)

SESSION = "11111111-2222-3333-4444-555555555555"


def usage(input_tokens=2, output=100, read=1000, creation=500, **extra):
    return {"input_tokens": input_tokens, "output_tokens": output, "cache_read_input_tokens": read,
            "cache_creation_input_tokens": creation,
            "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": creation},
            "service_tier": "standard", **extra}


def model_usage(input_tokens, output, read, creation, cost, thinking=0):
    return {"inputTokens": input_tokens, "outputTokens": output, "cacheReadInputTokens": read,
            "cacheCreationInputTokens": creation, "costUSD": cost, "costBasis": "list",
            "provider": "firstParty", "contextWindow": 200000, "thinkingTokens": thinking}


def assistant(request, message_id, blocks, use=None, session=SESSION, stream=True):
    """One record per content block, exactly as both log shapes write them."""
    records = []
    for index, block in enumerate(blocks):
        record = {"type": "assistant", "session_id": session, "uuid": f"{message_id}-{index}",
                  "message": {"id": message_id, "role": "assistant", "model": "claude-test-1",
                              "content": [block], "usage": use or usage()}}
        if stream:
            record["request_id"] = request
        else:
            record["requestId"] = request
            record["apiBlockIndex"] = index
        records.append(record)
    return records


def tool_use(identifier, name="Read", command="a.txt"):
    return {"type": "tool_use", "id": identifier, "name": name, "input": {"file_path": command}}


def result(index, use, models, cost, session=SESSION, subtype="success", uuid=None, **extra):
    return {"type": "result", "subtype": subtype, "session_id": session,
            "uuid": uuid or f"result-{index}",
            "result_index": index, "is_error": subtype != "success", "num_turns": 3,
            "duration_ms": 1000, "duration_api_ms": 900, "permission_denials": [],
            "terminal_reason": "completed", "api_error_status": None,
            "usage": use, "modelUsage": models, "total_cost_usd": cost, **extra}


def init(session=SESSION, **extra):
    return {"type": "system", "subtype": "init", "session_id": session, "model": "claude-test-1",
            "claude_code_version": "2.1.278", "permissionMode": "dontAsk",
            "plugins": [{"name": "keys-jev-optimizer"}], **extra}


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, name, records):
        path = self.root / name
        with path.open("w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record) + "\n")
        return path

    def run_report(self, *paths):
        return collect.report(collect.resolve([str(path) for path in paths]))

    def run_main(self, argv):
        """The command prints its report; the test only needs the exit status."""
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return collect.main(argv)

    def only(self, document):
        self.assertEqual(len(document["sessions"]), 1)
        return document["sessions"][0]

    # Duplicates ---------------------------------------------------------

    def test_content_block_copies_of_one_turn_are_counted_once(self):
        blocks = [{"type": "thinking"}, tool_use("toolu_1"), tool_use("toolu_2", command="b.txt")]
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", blocks))
        row = self.only(self.run_report(path))
        self.assertEqual(row["api_requests"]["counted"], 1)
        self.assertEqual(row["api_requests"]["duplicate_content_block_records_ignored"], 2)
        self.assertEqual(row["cross_check"]["assistant_record_sum"]["cache_read_input_tokens"], 1000)
        self.assertEqual(row["tool_calls"]["total"], 2)

    def test_the_same_session_in_two_log_shapes_is_not_counted_twice(self):
        """A stream transcript reports the usage known at message start; the session
        transcript reports the completed usage. The larger report must win, once."""
        blocks = [tool_use("toolu_1"), tool_use("toolu_2", command="b.txt")]
        stream = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", blocks, use=usage(output=3)))
        session = self.write("session.jsonl", assistant("req_1", "msg_1", blocks, use=usage(output=940), stream=False))
        row = self.only(self.run_report(stream, session))
        self.assertEqual(row["api_requests"]["counted"], 1)
        self.assertEqual(row["api_requests"]["conflicting_duplicate_usage"], 1)
        self.assertEqual(row["cross_check"]["assistant_record_sum"]["output_tokens"], 940)
        self.assertEqual(row["tool_calls"]["total"], 2)

    def test_a_repeated_result_record_is_ignored(self):
        records = [init(), result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5)]
        path = self.write("stream.jsonl", records + records[1:])
        document = self.run_report(path)
        self.assertEqual(document["inputs"]["duplicate_result_records_ignored"], 1)
        self.assertEqual(self.only(document)["completeness"]["result_events"], 1)

    def test_a_replayed_result_without_a_uuid_collapses_wherever_it_reappears(self):
        """Without a uuid the reported numbers are the identity. A replay repeats
        them exactly, so it must not become a second process and a second cost."""
        bare = result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)
        bare.pop("uuid")
        document = self.run_report(self.write("bare.jsonl", [init(), bare, bare, init(), bare]))
        row = self.only(document)
        self.assertEqual(document["inputs"]["duplicate_result_records_ignored"], 2)
        self.assertEqual(row["completeness"]["result_events"], 1)
        self.assertEqual(row["cost"]["client_processes"], 1)
        self.assertEqual(row["cost"]["list_price_estimate_usd"], 0.4)
        self.assertEqual(row["cost"]["results_identified_by_content_digest"], 3)

    def test_distinct_results_without_a_uuid_are_still_two_processes(self):
        """The replay guard must not merge a genuine resumed run, which differs in
        its own reported numbers even when the index restarts at zero."""
        first = result(0, usage(2, 500, 9000, 800), {"claude-test-1": model_usage(2, 500, 9000, 800, 0.5)}, 0.5)
        second = result(0, usage(1, 40, 300, 60), {"claude-test-1": model_usage(1, 40, 300, 60, 1.0)},
                        1.0, duration_ms=2000)
        for record in (first, second):
            record.pop("uuid")
        row = self.only(self.run_report(self.write("bare.jsonl", [init(), first, init(), second])))
        self.assertEqual(row["completeness"]["result_events"], 2)
        self.assertEqual(row["cost"]["client_processes"], 2)
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd"], 1.5)
        self.assertEqual(row["tokens"]["output_tokens"], 540)

    # Cumulative multi-turn results --------------------------------------

    def test_cumulative_model_usage_is_taken_once_and_the_naive_sum_is_reported(self):
        first = result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)
        second = result(1, usage(4, 200, 3000, 700),
                        {"claude-test-1": model_usage(6, 300, 4000, 1200, 0.9)}, 0.9)
        path = self.write("stream.jsonl", [init(), first, second])
        row = self.only(self.run_report(path))
        self.assertEqual(row["tokens"]["basis"], "final_cumulative_model_usage")
        self.assertEqual([row["tokens"][field] for field in collect.TOKEN_FIELDS], [6, 300, 4000, 1200])
        self.assertEqual(row["cross_check"]["sum_of_incremental_result_usage"]["output_tokens"], 300)
        self.assertEqual(row["cross_check"]["naive_sum_of_cumulative_model_usage_avoided"]["output_tokens"], 400)
        self.assertEqual(row["cross_check"]["double_count_avoided_tokens"], 2 + 100 + 1000 + 500)
        self.assertTrue(row["cross_check"]["increments_match_final_cumulative"])
        # total_cost_usd is cumulative as well: the last value, never the sum.
        self.assertEqual(row["cost"]["list_price_estimate_usd"], 0.9)
        self.assertIsNone(row["cost"]["billed_dollars"])

    def test_background_model_tokens_appear_only_in_model_usage(self):
        models = {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4),
                  "claude-small-1": model_usage(2000, 20, 0, 0, 0.002)}
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}])
                          + [result(0, usage(2, 100, 1000, 500), models, 0.402)])
        row = self.only(self.run_report(path))
        self.assertEqual(row["tokens"]["input_tokens"], 2002)
        self.assertEqual(row["cross_check"]["main_model"], "claude-test-1")
        self.assertEqual(row["cross_check"]["background_model_tokens_absent_from_result_usage"]["input_tokens"], 2000)
        self.assertTrue(row["cross_check"]["increments_match_final_cumulative"])

    def test_out_of_turn_usage_is_reported_as_a_residual_and_not_as_a_double_count(self):
        """A built-in compaction summary is charged to the model but is in no turn."""
        path = self.write("stream.jsonl", [
            init(),
            {"type": "system", "subtype": "compact_boundary", "session_id": SESSION,
             "compact_metadata": {"trigger": "manual", "pre_tokens": 19202, "post_tokens": 8838,
                                  "cumulative_dropped_tokens": 10364, "duration_ms": 21394}},
            result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 2293, 20060, 500, 0.9)}, 0.9)])
        row = self.only(self.run_report(path))
        self.assertFalse(row["cross_check"]["increments_match_final_cumulative"])
        self.assertFalse(row["cross_check"]["increments_exceed_cumulative"])
        self.assertEqual(row["cross_check"]["out_of_turn_main_model_tokens"]["output_tokens"], 2193)
        self.assertTrue(all(gate["passed"] for gate in
                            collect.build_gates([row], {"records": 3, "unparsable_lines": 0, "non_object_records": 0})
                            if gate["name"] != "every_session_has_a_final_result"))

    # Interrupted runs resumed into the same session ---------------------

    def test_an_interrupted_run_and_its_continuation_are_reported_as_segments(self):
        """Observed in this run: one session id, two init records, no result yet."""
        path = self.write("resumed.jsonl",
                          [init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=usage(read=1000))
                          + [init()] + assistant("req_2", "msg_2", [{"type": "text"}], use=usage(read=4000)))
        row = self.only(self.run_report(path))
        self.assertEqual(row["init_events"], 2)
        self.assertEqual([segment["api_requests"] for segment in row["segments"]], [1, 1])
        self.assertEqual([segment["assistant_record_sum"]["cache_read_input_tokens"]
                          for segment in row["segments"]], [1000, 4000])
        self.assertEqual([segment["state"] for segment in row["segments"]], ["unfinished", "unfinished"])
        self.assertEqual(row["tokens"]["cache_read_input_tokens"], 5000)

    def test_a_restarted_cumulative_counter_is_banked_rather_than_lost(self):
        """Cumulative totals run per client process. If a resumed session starts
        them again, the last result alone would drop the interrupted run."""
        before = result(0, usage(2, 500, 9000, 800), {"claude-test-1": model_usage(2, 500, 9000, 800, 1.5)},
                        1.5, uuid="result-before")
        after = result(0, usage(1, 40, 300, 60), {"claude-test-1": model_usage(1, 40, 300, 60, 0.2)},
                       0.2, uuid="result-after")
        row = self.only(self.run_report(self.write("restart.jsonl", [init(), before, init(), after])))
        self.assertEqual(row["cost"]["cumulative_counter_restarts"], 1)
        self.assertEqual(row["tokens"]["output_tokens"], 540)
        self.assertEqual(row["tokens"]["cache_read_input_tokens"], 9300)
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd"], 1.7)
        self.assertEqual([segment["result_events"] for segment in row["segments"]], [1, 1])

    def test_a_resumed_process_is_added_even_when_its_counters_are_larger(self):
        """Reproduced from the real run: `result_index` restarting at zero is the
        process boundary. Requiring the totals to fall instead reported 1.00 for a
        session that spent 0.50 and then another 1.00."""
        before = result(0, usage(2, 500, 9000, 800), {"claude-test-1": model_usage(2, 500, 9000, 800, 0.50)},
                        0.50, uuid="result-before")
        after = result(0, usage(9, 900, 40000, 2000),
                       {"claude-test-1": model_usage(9, 900, 40000, 2000, 1.00)}, 1.00, uuid="result-after")
        row = self.only(self.run_report(self.write("resumed.jsonl", [init(), before, init(), after])))
        self.assertEqual(row["cost"]["client_processes"], 2)
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd"], 1.50)
        self.assertEqual(row["tokens"]["output_tokens"], 1400)
        self.assertEqual(row["tokens"]["cache_read_input_tokens"], 49000)
        self.assertEqual(row["cost"]["ambiguous_process_boundaries"], 0)
        self.assertEqual([process["final_cumulative_list_price_usd"] for process in row["processes"]],
                         [0.50, 1.00])
        self.assertEqual([process["sum_of_per_turn_result_usage"]["output_tokens"]
                          for process in row["processes"]], [500, 900])

    def test_a_process_boundary_without_a_result_index_is_marked_ambiguous(self):
        """No index to compare: the weaker falling-counter signal is used and the
        guess is declared rather than presented as identification."""
        first = result(0, usage(2, 500, 9000, 800), {"claude-test-1": model_usage(2, 500, 9000, 800, 0.5)},
                       0.5, uuid="result-first")
        second = result(0, usage(9, 900, 40000, 2000),
                        {"claude-test-1": model_usage(9, 900, 40000, 2000, 1.0)}, 1.0, uuid="result-second")
        second.pop("result_index")
        row = self.only(self.run_report(self.write("ambiguous.jsonl", [init(), first, init(), second])))
        self.assertEqual(row["cost"]["ambiguous_process_boundaries"], 1)
        # Rising counters with no index are indistinguishable from one process.
        self.assertEqual(row["cost"]["client_processes"], 1)
        self.assertEqual(row["tokens"]["output_tokens"], 900)

    def test_an_unidentified_boundary_publishes_no_total_and_fails_its_gate(self):
        """The reported case: two successes separated by an init, neither carrying a
        result_index, counters rising. One epoch reading gives 1.00 and a fresh
        counter gives 1.50; nothing in the log says which, so the collector may not
        report 1.00 as the cost and may not let the run pass as verified."""
        first = result(0, usage(1, 1, 1, 1), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5,
                       uuid="result-first")
        second = result(0, usage(1, 1, 1, 1), {"claude-test-1": model_usage(4, 200, 2000, 1000, 1.0)}, 1.0,
                        uuid="result-second")
        for record in (first, second):
            record.pop("result_index")
        document = self.run_report(self.write("unidentified.jsonl", [init(), first, init(), second]))
        row = self.only(document)
        self.assertEqual(row["cost"]["ambiguous_process_boundaries"], 1)
        self.assertEqual(row["accounting_state"], "ambiguous_counter_epoch_boundaries")
        self.assertFalse(row["accounting_totals_are_identified"])
        # No invented total: unknown, with both readings the records admit.
        self.assertIsNone(row["cost"]["list_price_estimate_usd"])
        self.assertFalse(row["cost"]["cost_total_is_identified"])
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd_if_counters_continued"], 1.0)
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd_if_ambiguous_boundaries_are_restarts"], 1.5)
        self.assertEqual(row["cost"]["client_processes"], 1)
        self.assertEqual(row["cost"]["client_processes_if_ambiguous_boundaries_are_restarts"], 2)
        # The session did finish; it is the accounting, not the run, that is open.
        self.assertEqual(row["state"], "complete")
        self.assertTrue(row["completeness"]["totals_are_partial"])
        self.assertEqual(row["completeness"]["partial_because"], ["ambiguous_counter_epoch_boundaries"])
        self.assertEqual(row["tokens"]["basis"], "final_cumulative_model_usage_lower_bound")
        self.assertEqual(row["tokens"]["output_tokens"], 200)
        self.assertEqual(row["tokens"]["tokens_if_ambiguous_boundaries_are_restarts"]["output_tokens"], 300)
        # Nothing settled to compare assistant records against.
        self.assertIsNone(row["cross_check"]["assistant_sum_within_result_totals"])
        self.assertIsNone(document["totals"]["list_price_estimate_usd"])
        self.assertFalse(document["totals"]["aggregate_cost_is_identified"])
        self.assertEqual(document["totals"]["sessions_with_unidentified_cost"], 1)
        self.assertAlmostEqual(document["totals"]["list_price_estimate_usd_lower_bound"], 1.0)
        self.assertAlmostEqual(document["totals"]["list_price_estimate_usd_upper_bound"], 1.5)
        self.assertFalse(document["gates_passed"])
        self.assertEqual([gate["name"] for gate in document["gates"] if not gate["passed"]],
                         ["accounting_totals_are_identified"])
        self.assertEqual(self.run_main(["check", str(self.root / "unidentified.jsonl")]), 3)

    def test_the_markdown_shows_an_unidentified_total_as_unknown(self):
        first = result(0, usage(1, 1, 1, 1), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5,
                       uuid="result-first")
        second = result(0, usage(1, 1, 1, 1), {"claude-test-1": model_usage(4, 200, 2000, 1000, 1.0)}, 1.0,
                        uuid="result-second")
        for record in (first, second):
            record.pop("result_index")
        rendered = collect.markdown(self.run_report(self.write("md.jsonl", [init(), first, init(), second])))
        self.assertIn("Aggregate list-price cost: unknown.", rendered)
        self.assertIn("1.0", rendered)
        self.assertIn("1.5", rendered)
        self.assertIn("accounting not identified", rendered)
        self.assertIn("ambiguous_counter_epoch_boundaries", rendered)
        self.assertIn("| accounting_totals_are_identified | FAIL |", rendered)
        self.assertIn("inferred cumulative-counter epoch", rendered)

    def test_a_counter_that_fell_without_an_index_is_identified_not_ambiguous(self):
        """The guard against the ambiguity finding over-reaching: a cumulative counter
        never falls inside one epoch, so a fall identifies the restart on its own and
        the total stays reportable."""
        before = result(0, usage(2, 500, 9000, 800), {"claude-test-1": model_usage(2, 500, 9000, 800, 1.5)},
                        1.5, uuid="result-before")
        after = result(0, usage(1, 40, 300, 60), {"claude-test-1": model_usage(1, 40, 300, 60, 0.2)},
                       0.2, uuid="result-after")
        for record in (before, after):
            record.pop("result_index")
        document = self.run_report(self.write("fell.jsonl", [init(), before, init(), after]))
        row = self.only(document)
        self.assertEqual(row["cost"]["ambiguous_process_boundaries"], 0)
        self.assertTrue(row["accounting_totals_are_identified"])
        self.assertEqual(row["cost"]["client_processes"], 2)
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd"], 1.7)
        self.assertTrue(document["gates_passed"])

    def test_a_resumed_session_that_kept_its_counters_is_charged_once(self):
        """The shape of the real run: one native session resumed twice, its counters
        and result_index carrying straight on. Inferred epochs must not split it, or
        the correction for a restarted counter would charge this run three times."""
        records = [init()]
        for index, (tokens, cost) in enumerate((((2, 100, 1000, 500), 0.4), ((6, 300, 4000, 1200), 0.9),
                                                ((9, 450, 6000, 1500), 1.4))):
            records += [result(index, usage(2, 100, 1000, 500),
                               {"claude-test-1": model_usage(*tokens, cost)}, cost,
                               uuid=f"result-{index}")]
            records += [init(uuid=f"init-{index}")]
        document = self.run_report(self.write("resumed-native.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["cost"]["client_processes"], 1)
        self.assertEqual(row["cost"]["cumulative_counter_restarts"], 0)
        self.assertEqual(row["cost"]["ambiguous_process_boundaries"], 0)
        self.assertTrue(row["accounting_totals_are_identified"])
        self.assertAlmostEqual(row["cost"]["list_price_estimate_usd"], 1.4)
        self.assertEqual(row["tokens"]["output_tokens"], 450)
        # The trailing init is an open segment: the accounting is identified, the
        # session is not finished, and the two statements are reported separately.
        self.assertEqual(row["state"], "incomplete_unfinished_segment")
        self.assertEqual(row["completeness"]["partial_because"], ["unfinished_or_uncovered_work"])
        self.assertEqual([gate["name"] for gate in document["gates"] if not gate["passed"]],
                         ["every_session_has_a_final_result"])

    def test_a_replayed_init_does_not_open_a_second_segment(self):
        """The same init reaches the collector twice when a stream log and the
        session transcript are read together."""
        opening = init(uuid="init-1")
        row = self.only(self.run_report(self.write("replay.jsonl", [opening, opening, init(uuid="init-2")])))
        self.assertEqual(row["init_events"], 2)
        self.assertEqual(row["replayed_init_records_ignored"], 1)

    def test_a_counter_that_only_rises_is_still_taken_once(self):
        first = result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)
        second = result(1, usage(4, 200, 3000, 700), {"claude-test-1": model_usage(6, 300, 4000, 1200, 0.9)}, 0.9)
        row = self.only(self.run_report(self.write("rising.jsonl", [init(), first, init(), second])))
        self.assertEqual(row["cost"]["cumulative_counter_restarts"], 0)
        self.assertEqual(row["tokens"]["output_tokens"], 300)
        self.assertEqual(row["cost"]["list_price_estimate_usd"], 0.9)

    def test_results_are_ordered_by_record_order_not_by_a_restarted_index(self):
        first = result(7, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)},
                       0.4, uuid="result-first")
        second = result(0, usage(1, 50, 200, 30), {"claude-test-1": model_usage(1, 50, 200, 30, 0.1)},
                        0.1, uuid="result-second")
        row = self.only(self.run_report(self.write("order.jsonl", [init(), first, init(), second])))
        self.assertEqual(row["cost"]["cumulative_counter_restarts"], 1)
        self.assertEqual(row["tokens"]["output_tokens"], 150)

    # Interrupted and malformed logs -------------------------------------

    def test_an_interrupted_log_is_partial_and_claims_no_cost(self):
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}]))
        row = self.only(self.run_report(path))
        self.assertEqual(row["state"], "incomplete_no_result")
        self.assertEqual(row["tokens"]["basis"], "assistant_records_only")
        self.assertTrue(row["completeness"]["totals_are_partial"])
        self.assertIsNone(row["cost"]["list_price_estimate_usd"])
        self.assertIsNone(row["cross_check"]["increments_exceed_cumulative"])

    def test_work_started_after_a_successful_result_keeps_the_session_open(self):
        """Reproduced from the real run: a success, then a new init and unfinished
        assistant work. Calling that complete hid the new usage and passed a gate
        that exists to catch exactly this."""
        records = ([init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=usage(output=100))
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4), init()]
                   + assistant("req_2", "msg_2", [{"type": "text"}], use=usage(6, 250, 7000, 900)))
        document = self.run_report(self.write("unfinished.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["state"], "incomplete_unfinished_segment")
        self.assertTrue(row["completeness"]["totals_are_partial"])
        # The completed segment is preserved; the open one is reported beside it.
        self.assertEqual(row["completeness"]["completed_segments"], 1)
        self.assertEqual(row["completeness"]["current_segment_state"], "unfinished")
        self.assertEqual(row["completeness"]["api_requests_after_last_result"], 1)
        self.assertEqual(row["completeness"]["usage_after_last_result"]["output_tokens"], 250)
        self.assertEqual(row["completeness"]["usage_after_last_result"]["cache_read_input_tokens"], 7000)
        self.assertEqual(row["tokens"]["usage_after_last_result"]["cache_read_input_tokens"], 7000)
        # The reported totals still cover only what a result reported.
        self.assertEqual(row["tokens"]["output_tokens"], 100)
        self.assertEqual([segment["state"] for segment in row["segments"]], ["complete", "unfinished"])
        self.assertEqual(document["totals"]["usage_after_last_result"]["cache_read_input_tokens"], 7000)
        self.assertFalse(document["gates_passed"])
        failing = [gate for gate in document["gates"] if not gate["passed"]]
        self.assertEqual([gate["name"] for gate in failing], ["every_session_has_a_final_result"])
        self.assertEqual(failing[0]["detail"]["incomplete"][0]["api_requests_after_last_result"], 1)

    def test_work_after_a_result_in_the_same_segment_keeps_the_session_open(self):
        """The second reported case: a success and then another request, with no new
        init. Reading completeness off the presence of a result in the current
        segment called that complete while api_requests_after_last_result was 1."""
        records = ([init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=usage(output=100))
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)]
                   + assistant("req_2", "msg_2", [{"type": "text"}], use=usage(6, 250, 7000, 900)))
        document = self.run_report(self.write("after-result.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["state"], "incomplete_work_after_last_result")
        self.assertTrue(row["completeness"]["totals_are_partial"])
        self.assertEqual(row["completeness"]["api_requests_after_last_result"], 1)
        self.assertEqual(row["completeness"]["usage_after_last_result"]["cache_read_input_tokens"], 7000)
        # One segment, which reported a result and then recorded more work in it.
        self.assertEqual([segment["state"] for segment in row["segments"]], ["work_after_result"])
        self.assertEqual(row["segments"][0]["api_requests_after_segment_result"], 1)
        self.assertEqual(row["completeness"]["completed_segments"], 0)
        self.assertEqual(row["tokens"]["output_tokens"], 100)
        self.assertFalse(document["gates_passed"])
        failing = [gate for gate in document["gates"] if not gate["passed"]]
        self.assertEqual([gate["name"] for gate in failing], ["every_session_has_a_final_result"])
        self.assertEqual(failing[0]["detail"]["incomplete"][0]["api_requests_after_last_result"], 1)

    def test_a_newly_opened_segment_with_no_records_keeps_the_session_open(self):
        """The same case without the assistant record: a success, then a new init and
        nothing yet. The empty segment was left out of the list entirely, so the
        completed earlier segment became the current one and the session read
        complete with no field of the report mentioning the open segment."""
        records = ([init()] + assistant("req_1", "msg_1", [{"type": "text"}])
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4),
                      init(uuid="init-2")])
        document = self.run_report(self.write("opened.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["init_events"], 2)
        self.assertEqual([segment["state"] for segment in row["segments"]], ["complete", "unfinished"])
        self.assertEqual([segment["api_requests"] for segment in row["segments"]], [1, 0])
        self.assertEqual(row["state"], "incomplete_unfinished_segment")
        self.assertEqual(row["completeness"]["current_segment"], 2)
        self.assertEqual(row["completeness"]["segments_opened_without_recorded_work"], 1)
        self.assertEqual(row["completeness"]["api_requests_after_last_result"], 0)
        self.assertTrue(row["completeness"]["totals_are_partial"])
        self.assertIn("recorded no request yet", row["completeness"]["note"])
        self.assertFalse(document["gates_passed"])
        self.assertEqual([gate["name"] for gate in document["gates"] if not gate["passed"]],
                         ["every_session_has_a_final_result"])
        # The markdown must not stay silent about it just because no request exists.
        rendered = collect.markdown(document)
        self.assertIn("current segment 2 is unfinished", rendered)

    def test_work_that_precedes_the_first_cumulative_counter_is_declared(self):
        """Observed in the real run: a stopped process left 76 requests behind, and
        the resumed process's first result counted none of them. Cache counts are
        final at message start, so the shortfall is visible and must not pass as
        covered usage."""
        records = ([init()] + assistant("req_0", "msg_0", [{"type": "text"}], use=usage(read=6000))
                   + [init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=usage(read=1000))
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        row = self.only(self.run_report(self.write("orphan.jsonl", records)))
        self.assertTrue(row["completeness"]["earlier_unreported_client_process_suspected"])
        self.assertEqual(row["completeness"]["usage_before_first_result_not_inside_it"]
                         ["cache_read_input_tokens"], 6000)
        self.assertIn("lower bound", row["completeness"]["earlier_process_note"])

    def test_ordinary_work_before_the_first_result_is_not_called_an_earlier_process(self):
        records = ([init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=usage(read=1000))
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        row = self.only(self.run_report(self.write("plain.jsonl", records)))
        self.assertFalse(row["completeness"]["earlier_unreported_client_process_suspected"])
        self.assertIsNone(row["completeness"]["earlier_process_note"])

    def test_a_session_that_ends_on_its_result_is_still_complete(self):
        """The guard against the fix over-reaching: nothing follows the result."""
        records = ([init()] + assistant("req_1", "msg_1", [{"type": "text"}])
                   + [result(0, usage(2, 100, 1000, 500),
                             {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        document = self.run_report(self.write("finished.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["state"], "complete")
        self.assertFalse(row["completeness"]["totals_are_partial"])
        self.assertEqual(row["completeness"]["api_requests_after_last_result"], 0)
        self.assertEqual(row["completeness"]["usage_after_last_result"]["output_tokens"], 0)
        self.assertTrue(document["gates_passed"])

    def test_an_error_result_is_reported_as_an_error_state(self):
        path = self.write("stream.jsonl", [init(), result(
            0, usage(), {}, 0.2, subtype="error_during_execution", api_error_status=529)])
        row = self.only(self.run_report(path))
        self.assertEqual(row["state"], "error_result")
        self.assertEqual(row["fallback"]["api_error_statuses"], [529])
        self.assertEqual(row["fallback"]["non_success_results"], 1)

    def test_malformed_and_unknown_values_stay_unknown_instead_of_zero(self):
        broken = usage()
        broken["output_tokens"] = "many"
        broken["cache_read_input_tokens"] = None
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}], use=broken))
        row = self.only(self.run_report(path))
        self.assertIsNone(row["tokens"]["output_tokens"])
        self.assertIsNone(row["tokens"]["cache_read_input_tokens"])
        self.assertEqual(row["tokens"]["input_tokens"], 2)
        for value in (True, -1, 10 ** 40, "3", 2.5):
            self.assertIsNone(collect.count(value))
        for value in (True, float("nan"), float("inf"), -1, "1.0"):
            self.assertIsNone(collect.money(value))

    def test_unreadable_lines_and_records_do_not_stop_the_run(self):
        path = self.root / "broken.jsonl"
        path.write_text("\n".join([
            json.dumps(init()),
            "{not json",
            "[1, 2, 3]",
            "",
            json.dumps({"session_id": SESSION}),
            json.dumps(result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5)),
        ]) + "\n", encoding="utf-8")
        document = self.run_report(path)
        self.assertEqual(document["inputs"]["unparsable_lines"], 1)
        self.assertEqual(document["inputs"]["non_object_records"], 1)
        self.assertEqual(document["inputs"]["record_types"]["untyped"], 1)
        self.assertEqual(self.only(document)["tokens"]["output_tokens"], 100)

    def test_records_without_a_session_id_are_grouped_and_counted(self):
        path = self.write("orphan.jsonl", [{"type": "assistant", "message": {
            "id": "msg_1", "model": "claude-test-1", "content": [], "usage": usage()}}])
        document = self.run_report(path)
        self.assertEqual(document["inputs"]["records_without_session_id"], 1)
        self.assertTrue(self.only(document)["session_id"].startswith("unknown:"))

    # Compaction, fallback, repeats --------------------------------------

    def test_compaction_evidence_is_read_from_both_record_shapes(self):
        stream = {"type": "system", "subtype": "compact_boundary", "session_id": SESSION,
                  "compact_metadata": {"trigger": "manual", "pre_tokens": 19213, "post_tokens": 2333,
                                       "cumulative_dropped_tokens": 16880, "duration_ms": 524}}
        transcript = {"type": "system", "subtype": "compact_boundary", "sessionId": SESSION,
                      "compactMetadata": {"trigger": "auto", "preTokens": 100, "postTokens": 40,
                                          "cumulativeDroppedTokens": 60, "durationMs": 9}}
        row = self.only(self.run_report(self.write("mixed.jsonl", [init(), stream, transcript])))
        self.assertEqual(row["compaction"]["count"], 2)
        self.assertEqual(row["compaction"]["context_tokens_dropped"], (19213 - 2333) + 60)
        self.assertEqual(row["compaction"]["triggers"], ["auto", "manual"])
        self.assertEqual(row["compaction"]["events"][0]["duration_ms"], 524)
        self.assertEqual(row["compaction"]["events"][1]["record_shape"], "session_transcript")

    def test_a_compaction_boundary_without_metadata_is_unknown_not_zero(self):
        row = self.only(self.run_report(self.write("bare.jsonl", [
            init(), {"type": "system", "subtype": "compact_boundary", "session_id": SESSION}])))
        self.assertEqual(row["compaction"]["count"], 1)
        self.assertFalse(row["compaction"]["events"][0]["metadata_present"])
        self.assertIsNone(row["compaction"]["events"][0]["pre_tokens"])
        self.assertIsNone(row["compaction"]["context_tokens_dropped"])

    def test_fallback_signals_are_collected(self):
        records = [
            init(),
            {"type": "rate_limit_event", "session_id": SESSION,
             "rate_limit_info": {"status": "allowed_warning", "isUsingOverage": True}},
            {"type": "rate_limit_event", "session_id": SESSION, "rate_limit_info": {}},
            {"type": "system", "subtype": "status", "session_id": SESSION,
             "status": "keys-jev-optimizer: fallback to built-in summary (below 25% minimum)"},
            {"type": "system", "subtype": "stop_hook_summary", "session_id": SESSION,
             "hookCount": 2, "hookErrors": ["boom"], "hookInfos": [{"command": "x"}]},
            result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5,
                   permission_denials=[{"tool_name": "Bash"}]),
        ]
        row = self.only(self.run_report(self.write("fallback.jsonl", records)))
        self.assertEqual(row["fallback"]["rate_limit_events"], 2)
        self.assertEqual(row["fallback"]["rate_limit_statuses"], {"allowed_warning": 1, "unreported": 1})
        self.assertEqual(row["fallback"]["rate_limit_overage_events"], 1)
        self.assertEqual(row["fallback"]["plugin_compaction_fallback_markers"], 1)
        self.assertEqual(row["fallback"]["permission_denials"], 1)
        self.assertEqual(row["fallback"]["hook_records"], 1)
        self.assertEqual(row["fallback"]["hook_errors"], 1)

    def test_live_permission_denied_events_are_counted_and_matched_to_results(self):
        """Reproduced from the real run: five system/permission_denied events were
        emitted and the report said zero, because only the result list was read.
        The result lists one of them again, so the total must be five, not six."""
        def denied(identifier, uuid, tool="Bash", reason="mode"):
            return {"type": "system", "subtype": "permission_denied", "session_id": SESSION,
                    "uuid": uuid, "tool_name": tool, "tool_use_id": identifier,
                    "decision_reason_type": reason,
                    "message": "Claude requested permission to run a command and it was refused."}

        records = [init()] + [denied(f"toolu_{n}", f"pd-{n}") for n in range(4)] + [
            denied("toolu_9", "pd-9", tool="Write", reason="rule"),
            denied("toolu_9", "pd-9-replayed", tool="Write", reason="rule"),
            result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5,
                   permission_denials=[{"tool_name": "Bash", "tool_use_id": "toolu_0",
                                        "tool_input": {"command": "rm -rf /"}}]),
        ]
        document = self.run_report(self.write("denied.jsonl", records))
        row = self.only(document)
        self.assertEqual(row["fallback"]["permission_denied_events"], 5)
        self.assertEqual(row["fallback"]["permission_denials_listed_in_results"], 1)
        self.assertEqual(row["fallback"]["permission_denials"], 5)
        self.assertEqual(row["fallback"]["permission_denials_by_tool"], {"Bash": 4, "Write": 1})
        self.assertEqual(row["fallback"]["permission_denials_by_decision_reason"], {"mode": 4, "rule": 1})
        self.assertEqual(row["fallback"]["permission_denials_without_tool_use_id"], 0)
        self.assertEqual(document["totals"]["permission_denials"], 5)
        # Neither the refusal message nor the refused input may be reported.
        self.assertNotIn("rm -rf", json.dumps(document))
        self.assertNotIn("requested permission", json.dumps(document))

    def test_a_denial_without_a_tool_use_id_is_counted_but_declared_unmatchable(self):
        records = [
            init(),
            {"type": "system", "subtype": "permission_denied", "session_id": SESSION, "uuid": "pd-1"},
            result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5,
                   permission_denials=[{"tool_name": "Bash"}]),
        ]
        row = self.only(self.run_report(self.write("unmatched.jsonl", records)))
        self.assertEqual(row["fallback"]["permission_denials"], 2)
        self.assertEqual(row["fallback"]["permission_denials_without_tool_use_id"], 2)
        self.assertEqual(row["fallback"]["permission_denials_by_tool"], {"unnamed": 1})
        self.assertIn("upper bound", row["fallback"]["permission_denials_note"])

    def test_a_denial_event_is_not_read_as_a_plugin_fallback_marker(self):
        """Its message is prose and must never be scanned for markers."""
        records = [init(), {"type": "system", "subtype": "permission_denied", "session_id": SESSION,
                            "uuid": "pd-1", "tool_use_id": "toolu_1", "tool_name": "Bash",
                            "message": "Denied; fallback to built-in summary was mentioned in the prompt."}]
        row = self.only(self.run_report(self.write("marker.jsonl", records)))
        self.assertEqual(row["fallback"]["plugin_compaction_fallback_markers"], 0)
        self.assertEqual(row["fallback"]["permission_denied_events"], 1)

    def test_a_model_other_than_the_requested_one_is_visible(self):
        path = self.write("stream.jsonl", [init(model="claude-test-9")] +
                          assistant("req_1", "msg_1", [{"type": "text"}]))
        row = self.only(self.run_report(path))
        self.assertEqual(row["fallback"]["models_observed"], ["claude-test-1"])
        self.assertTrue(row["fallback"]["requested_model_differs_from_observed"])

    def test_exact_repeat_tool_calls_are_counted_but_never_called_a_saving(self):
        blocks = [tool_use("toolu_1"), tool_use("toolu_2"), tool_use("toolu_3", command="b.txt")]
        row = self.only(self.run_report(self.write("repeat.jsonl", [init()] + assistant("req_1", "msg_1", blocks))))
        self.assertEqual(row["tool_calls"]["total"], 3)
        self.assertEqual(row["tool_calls"]["distinct_call_signatures"], 2)
        self.assertEqual(row["tool_calls"]["exact_repeat_calls"], 1)
        self.assertIn("not a measured saving", row["tool_calls"]["note"])

    # Quality gates and the command line ---------------------------------

    def test_gates_fail_when_a_session_never_finished(self):
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}]))
        document = self.run_report(path)
        self.assertFalse(document["gates_passed"])
        failing = [gate["name"] for gate in document["gates"] if not gate["passed"]]
        self.assertEqual(failing, ["every_session_has_a_final_result"])

    def test_gates_fail_when_increments_exceed_the_cumulative_total(self):
        """The shape a double-counting regression would produce."""
        path = self.write("stream.jsonl", [
            init(),
            result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4),
            result(1, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        document = self.run_report(path)
        self.assertIn("incremental_usage_never_exceeds_cumulative_main_model_usage",
                      [gate["name"] for gate in document["gates"] if not gate["passed"]])

    def test_gates_fail_when_too_many_lines_are_unparsable(self):
        path = self.root / "noise.jsonl"
        path.write_text("{oops\n" * 5 + json.dumps(init()) + "\n", encoding="utf-8")
        document = self.run_report(path)
        gate = next(gate for gate in document["gates"] if gate["name"] == "records_parsed")
        self.assertFalse(gate["passed"])

    def test_gates_pass_on_a_complete_session(self):
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}]) + [
            result(0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        self.assertTrue(self.run_report(path)["gates_passed"])

    def test_check_exits_three_on_a_failed_gate_and_report_does_not(self):
        path = self.write("stream.jsonl", [init()] + assistant("req_1", "msg_1", [{"type": "text"}]))
        out = self.root / "report.json"
        self.assertEqual(self.run_main(["report", str(path), "--out", str(out)]), 0)
        self.assertEqual(json.loads(out.read_text())["schema_version"], collect.SCHEMA)
        self.assertEqual(self.run_main(["check", str(path)]), 3)

    def test_a_directory_is_searched_for_jsonl_files_and_duplicates_collapse(self):
        self.write("a.jsonl", [init(session="aaaa"), result(
            0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5, session="aaaa")])
        self.write("b.jsonl", [init(session="bbbb"), result(
            0, usage(), {"claude-test-1": model_usage(4, 200, 2000, 600, 0.7)}, 0.7, session="bbbb")])
        (self.root / "ignored.txt").write_text("not a log\n", encoding="utf-8")
        document = self.run_report(self.root, self.root / "a.jsonl")
        self.assertEqual(document["inputs"]["files_read"], 2)
        self.assertEqual(document["totals"]["sessions"], 2)
        self.assertEqual(document["totals"]["input_tokens"], 6)
        self.assertEqual(document["totals"]["list_price_estimate_usd"], 1.2)
        self.assertIsNone(document["totals"]["billed_dollars"])

    def test_bad_input_is_refused_with_a_reason_and_not_a_traceback(self):
        self.assertEqual(self.run_main(["report", str(self.root / "missing.jsonl")]), 2)
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaises(collect.InputError):
            collect.resolve([str(empty)])
        big = self.write("big.jsonl", [init()])
        original = collect.MAX_FILE_BYTES
        collect.MAX_FILE_BYTES = 1
        try:
            with self.assertRaises(collect.InputError):
                self.run_report(big)
        finally:
            collect.MAX_FILE_BYTES = original

    def test_markdown_reports_the_same_numbers_and_names_the_cost_basis(self):
        path = self.write("stream.jsonl", [init(), result(
            0, usage(2, 100, 1000, 500), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4)])
        rendered = collect.markdown(self.run_report(path))
        self.assertIn("list-price", rendered.lower())
        self.assertIn("Billed dollars: unknown", rendered)
        self.assertIn("| 1 | 1 | 0 | 0 | 2 | 100 | 1000 | 500 | 0 | 0 | 0.4 |", rendered)
        # One process, its cumulative view beside its per-turn view.
        self.assertIn("| 11111111 | 1 | 1 | 1 | 100 | 1000 | 100 | 1000 | 0.4 |", rendered)
        self.assertIn("must not be added together", rendered)

    def test_markdown_names_the_open_segment_of_an_unfinished_session(self):
        records = ([init(), result(0, usage(2, 100, 1000, 500),
                                   {"claude-test-1": model_usage(2, 100, 1000, 500, 0.4)}, 0.4), init()]
                   + assistant("req_2", "msg_2", [{"type": "text"}], use=usage(6, 250, 7000, 900)))
        rendered = collect.markdown(self.run_report(self.write("open.jsonl", records)))
        self.assertIn("incomplete_unfinished_segment", rendered)
        self.assertIn("1 API requests after the last result", rendered)
        self.assertIn("7000 cache-read", rendered)

    # Privacy ------------------------------------------------------------

    def test_no_prompt_or_tool_content_reaches_the_output(self):
        secret = "CANARY-do-not-emit-7f3a"
        records = [
            init(),
            {"type": "user", "session_id": SESSION, "message": {"role": "user", "content": secret}},
            *assistant("req_1", "msg_1", [
                {"type": "text", "text": secret},
                {"type": "tool_use", "id": "toolu_1", "name": "Bash",
                 "input": {"command": secret, "description": secret}}]),
            {"type": "user", "session_id": SESSION, "toolUseResult": {"stdout": secret},
             "message": {"role": "user", "content": [{"type": "tool_result", "content": secret}]}},
            {"type": "system", "subtype": "status", "session_id": SESSION, "status": secret},
            result(0, usage(), {"claude-test-1": model_usage(2, 100, 1000, 500, 0.5)}, 0.5, result=secret),
        ]
        document = self.run_report(self.write("secret.jsonl", records))
        encoded = json.dumps(document) + collect.markdown(document)
        self.assertNotIn(secret, encoded)
        self.assertNotIn("CANARY", encoded)
        self.assertEqual(self.only(document)["tool_calls"]["by_name"], {"Bash": 1})


if __name__ == "__main__":
    unittest.main()
