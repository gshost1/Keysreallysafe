#!/usr/bin/env python3
"""fixture_now.py must emit the exact Streaming-result shape DroidIngest parses.

The helper is the stand-in for a real Droid home when the dashboard's live ranges
(today/week/month) need data in them, so its output is only useful if it would
actually ingest: every usage line must carry DroidIngest's byte-for-byte marker,
the JSON behind it must hold the fields the parser reads, and the totals it
promises must be the ones the two tools' own counting rules produce.
"""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture_now  # noqa: E402

REPO = HERE.parent.parent
DROID_INGEST_SWIFT = REPO / "Sources" / "KeysCore" / "DroidIngest.swift"
CHECKED_IN_DROID_LOGS = sorted((REPO / "Fixtures" / "droid-home" / "logs").glob("droid-log-single.log*"))


def swift_marker():
    """The marker out of the parser itself, so the helper can never drift from it."""
    text = DROID_INGEST_SWIFT.read_text(encoding="utf-8")
    found = re.search(r'marker = Array\(#"(.+?)"#\.utf8\)', text)
    assert found is not None, "DroidIngest's marker literal moved; update this test"
    return found.group(1)


def parse_usage_line(line):
    """Mirror of DroidIngest.parseLine up to the fields it keeps."""
    assert line.startswith("["), "the timestamp bracket opens the line"
    timestamp = line[1:line.index("]")]
    # The whole prefix is pinned, not just the marker inside it: the bracket's
    # "]" is the marker's first byte, so the line is "[" + timestamp + marker.
    prefix = "[" + timestamp + fixture_now.MARKER
    assert line.startswith(prefix), "the prefix must be the real log shape"
    root = json.loads(line[len(prefix):])
    return root, timestamp


def droid_tokens(root):
    """The dashboard's droid-local rule: every bucket the log reports."""
    return (root["inputTokens"] + root["cacheReadInputTokens"] + root["cachedTokensWritten"]
            + root["outputTokens"] + root["reasoningTokens"])


def claude_tokens(usage):
    """The dashboard's claude-local rule: input, output and the cache buckets."""
    return (usage["input_tokens"] + usage["output_tokens"]
            + usage["cache_read_input_tokens"] + usage["cache_creation_input_tokens"])


class FixtureNowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)
        self.now = datetime.now(timezone.utc)
        self.info = fixture_now.write(self.out, now=self.now)
        self.droid_lines = self.info["droid_log"].read_text(encoding="utf-8").splitlines()
        self.usage = [line for line in self.droid_lines if fixture_now.MARKER in line]

    def test_marker_is_pinned_to_droidingests_own_literal(self):
        self.assertEqual(fixture_now.MARKER, swift_marker())

    def test_every_usage_line_parses_behind_the_marker(self):
        self.assertEqual(len(self.usage), len(fixture_now.DROID_RECORDS) + 1,
                         "one marker line per record, zero-token record included")
        for line in self.usage:
            root, _ = parse_usage_line(line)
            self.assertEqual(root["type"], "message_delta")
            self.assertIn("tags", root)
            self.assertTrue(root["tags"]["sessionId"])
            self.assertTrue(root["tags"]["modelId"])
            for field in ("inputTokens", "cacheReadInputTokens", "cachedTokensWritten",
                          "outputTokens", "reasoningTokens"):
                self.assertIsInstance(root[field], int)
            self.assertEqual(root["totalInputTokens"],
                             root["inputTokens"] + root["cacheReadInputTokens"] + root["cachedTokensWritten"],
                             "totalInputTokens repeats the parts and must never exceed them")

    def test_zero_token_and_non_usage_records_are_present_but_unguarded(self):
        # The real log mixes record types around the usage ones; the helper keeps that
        # shape so the marker filter is exercised, not assumed.
        noise = [line for line in self.droid_lines if fixture_now.MARKER not in line]
        self.assertTrue(noise, "the log must still carry records the parser counts past")
        zeros = [line for line in self.usage if droid_tokens(parse_usage_line(line)[0]) == 0]
        self.assertEqual(len(zeros), 1, "exactly one all-zero record")

    def test_per_model_totals_match_the_records_under_the_droid_rule(self):
        counted = {}
        for line in self.usage:
            root, _ = parse_usage_line(line)
            counted[root["tags"]["modelId"]] = counted.get(root["tags"]["modelId"], 0) + droid_tokens(root)
        self.assertEqual(counted, self.info["droid_totals"])

    def test_every_vendor_family_is_covered(self):
        families = {model.split("-")[0] for model in self.info["droid_totals"]}
        self.assertEqual(families, {"claude", "gpt", "gemini", "glm", "kimi", "deepseek", "grok"})

    def test_records_are_recent_enough_for_every_current_range(self):
        for line in self.usage:
            _, timestamp = parse_usage_line(line)
            age = self.now - datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
            self.assertGreater(age, timedelta(0))
            self.assertLess(age, timedelta(hours=3), "records must sit inside today, week, month and the 5-hour window")

    def local_midnight(self, now):
        return now.astimezone().replace(hour=0, minute=0, second=0, microsecond=0)

    def assert_records_inside_today(self, info, now):
        """Every stamped record, Droid's and Claude Code's, sits after local midnight."""
        midnight = self.local_midnight(now).astimezone(timezone.utc)
        stamps = []
        for line in info["droid_log"].read_text(encoding="utf-8").splitlines():
            stamps.append(datetime.strptime(line[1:line.index("]")], "%Y-%m-%dT%H:%M:%S.%fZ")
                          .replace(tzinfo=timezone.utc))
        for entry in (json.loads(line) for line in
                      info["claude_log"].read_text(encoding="utf-8").splitlines()):
            stamps.append(datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc))
        for stamp in stamps:
            self.assertGreaterEqual(stamp, midnight,
                                    "a record stamped before local midnight empties the Today range")
            self.assertLessEqual(stamp, now, "records are stamped in the past")
        return stamps

    def test_a_run_just_after_midnight_clamps_records_into_today(self):
        # Twelve minutes past local midnight, a raw 30-115 minute spread would stamp every
        # record on yesterday (and on the previous week when midnight opens one). The helper
        # compresses the spread onto the time since midnight instead, so Today and Week both
        # stay populated, and it says so in its report.
        midnight = self.local_midnight(datetime.now(timezone.utc))
        now = midnight + timedelta(minutes=12)
        info = fixture_now.write(self.out, now=now)
        self.assertTrue(info["clamped"], "the helper must report that it clamped the ages")
        stamps = self.assert_records_inside_today(info, now)
        # The clamp preserves each log's own order and fits the whole spread into the
        # twelve minutes since midnight.
        self.assertEqual(stamps[0], min(stamps), "the first line of the log stays the oldest record")
        self.assertEqual(stamps[-1], max(stamps), "the last record stays the youngest")
        self.assertLessEqual(max(stamps) - min(stamps), timedelta(minutes=12))
        self.assertGreaterEqual(min(stamps), midnight.astimezone(timezone.utc))

    def test_a_run_just_before_the_spread_needs_no_clamp(self):
        # Ten in the morning has far more room than the spread needs, so the ages are the
        # plain 30-115 minutes and the records still land after this morning's midnight.
        midnight = self.local_midnight(datetime.now(timezone.utc))
        now = midnight + timedelta(hours=10)
        info = fixture_now.write(self.out, now=now)
        self.assertFalse(info["clamped"])
        stamps = self.assert_records_inside_today(info, now)
        spread = max(stamps) - min(stamps)
        self.assertGreater(spread, timedelta(minutes=80), "an unclamped run keeps its age spread")

    def test_at_midnight_itself_the_clamp_gives_up_honestly(self):
        # In the first seconds after midnight there is no room after it at all; the helper
        # leaves the ages alone rather than inventing timestamps, and says it did not clamp.
        midnight = self.local_midnight(datetime.now(timezone.utc))
        info = fixture_now.write(self.out, now=midnight + timedelta(seconds=6))
        self.assertFalse(info["clamped"])

    def test_claude_home_shares_a_model_with_the_droid_home(self):
        lines = [json.loads(line) for line in
                 self.info["claude_log"].read_text(encoding="utf-8").splitlines()]
        assistants = [entry for entry in lines if entry["type"] == "assistant"]
        self.assertEqual(len(assistants), len(fixture_now.CLAUDE_RECORDS))
        models = {entry["message"]["model"] for entry in assistants}
        self.assertEqual(self.info["claude_totals"], {
            model: sum(claude_tokens(entry["message"]["usage"])
                       for entry in assistants if entry["message"]["model"] == model)
            for model in models})
        shared = models & set(self.info["droid_totals"])
        self.assertTrue(shared, "a model id must exist in both tools' homes")
        for model in shared:
            self.assertEqual(self.info["merged_totals"][model],
                             self.info["droid_totals"][model] + self.info["claude_totals"][model])

    def test_cli_writes_the_homes_and_prints_the_expected_totals(self):
        with tempfile.TemporaryDirectory() as second:
            out = Path(second) / "now"
            done = subprocess.run(
                [sys.executable, str(HERE / "fixture_now.py"), "--out", str(out)],
                capture_output=True, text=True, check=True)
            text = done.stdout
            self.assertIn(str(out / "droid-home"), text)
            self.assertIn(str(out / "claude-home"), text)
            for model, total in self.info["merged_totals"].items():
                self.assertIn(model, text)
                self.assertIn(str(total), text)
            shared = sorted(set(self.info["droid_totals"]) & set(self.info["claude_totals"]))
            self.assertEqual(len(shared), 1)
            model = shared[0]
            self.assertIn(f"{model}: {self.info['droid_totals'][model]} (droid-local)"
                          f" + {self.info['claude_totals'][model]} (claude-local)"
                          f" = {self.info['merged_totals'][model]} merged", text)
            self.assertTrue((out / "droid-home" / "logs" / "droid-log-single.log").is_file())

    def test_checked_in_fixture_dates_are_untouched(self):
        # Swift tests pin those dates; the helper must never rewrite the fixtures.
        self.assertGreaterEqual(len(CHECKED_IN_DROID_LOGS), 2)
        for log in CHECKED_IN_DROID_LOGS:
            text = log.read_text(encoding="utf-8")
            self.assertTrue("2026-09-30" in text or "2026-10-10" in text,
                            f"{log.name} lost its pinned dates")


if __name__ == "__main__":
    unittest.main()
