#!/usr/bin/env python3
"""export-remote-usage.py must copy usage and nothing else.

The file it writes leaves a cloud container for the user's Mac, so the test plants content
sentinels in every place a real droid log, Claude Code transcript or stream-json capture holds
text, and checks that none survive while every token count does.
"""
import contextlib
import importlib.util
import io
import json
import os
import stat
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "export-remote-usage.py"
SPEC = importlib.util.spec_from_file_location("export_remote_usage", SCRIPT)
exporter = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(exporter)

MARKER = "] INFO: [Agent] Streaming result | Context: "


def droid_record(model, response, text_field=True):
    record = {
        "count": 1, "inputTokens": 100, "cacheReadInputTokens": 2000, "cachedTokensWritten": 5,
        "totalInputTokens": 2105, "outputTokens": 50, "reasoningTokens": 10,
        "upstreamResponseId": response,
        "tags": {"modelId": model, "sessionId": "s-1", "hostId": "SENTINEL-HOST", "traceId": "SENTINEL-TRACE"},
    }
    if text_field:
        record["prompt"] = "SENTINEL-PROMPT"
    return "[2026-10-16T21:40:00.000Z" + MARKER + json.dumps(record)


class ExportRemoteUsageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        logs = self.root / "factory" / "logs"
        logs.mkdir(parents=True)
        (logs / "droid-log-single.log").write_text("\n".join([
            "[2026-10-16T21:39:00.000Z] INFO: [Agent] Streaming text | Context: {\"text\":\"SENTINEL-STREAM\"}",
            droid_record("claude-opus-5-5", "r1"),
            "[2026-10-16T21:40:01.000Z] INFO: [Model-Router] Model transition claude-opus-5-5 -> kimi-k3",
            droid_record("kimi-k3", "r2"),
        ]) + "\n")
        (logs / "droid-log-single.log.2026-10-15").write_text(droid_record("glm-5", "r0") + "\n")
        project = self.root / "claude" / "projects" / "-home-user-repo" / "sess" / "subagents"
        project.mkdir(parents=True)
        (project.parent.parent / "sess.jsonl").write_text("\n".join([
            json.dumps({"type": "user", "message": {"content": "SENTINEL-USER-PROMPT"}}),
            json.dumps({"type": "assistant", "sessionId": "cloud-1", "requestId": "req_1",
                        "timestamp": "2026-10-16T18:00:00.000Z", "cwd": "/home/user/SENTINEL-PATH",
                        "message": {"id": "msg_1", "model": "claude-opus-5-5",
                                    "content": [{"type": "text", "text": "SENTINEL-ANSWER"}],
                                    "usage": {"input_tokens": 10, "output_tokens": 20,
                                              "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40,
                                              "server_tool_use": {"web_search_requests": 1}}}}),
        ]) + "\n")
        (project / "agent-1.jsonl").write_text(json.dumps({
            "type": "assistant", "sessionId": "cloud-1", "requestId": "req_2", "timestamp": "2026-10-16T18:01:00.000Z",
            "message": {"id": "msg_2", "model": "claude-sonnet-5-5", "usage": {"input_tokens": 1, "output_tokens": 2}}}) + "\n")
        self.stream = self.root / "stream.jsonl"
        self.stream.write_text("\n".join([
            json.dumps({"type": "message", "text": "SENTINEL-MESSAGE", "session_id": "s-1"}),
            json.dumps({"type": "completion", "finalText": "SENTINEL-FINAL", "numTurns": 31, "session_id": "s-1",
                        "timestamp": 1792118855901, "usage": {"input_tokens": 138, "output_tokens": 165253,
                                                              "factory_credits": 2899529, "thinking_tokens": 56728}}),
        ]) + "\n")
        self.out = self.root / "export.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def run_export(self, *extra):
        code = exporter.main(["-o", str(self.out), "--factory-home", str(self.root / "factory"),
                              "--claude-home", str(self.root / "claude"), "--stream", str(self.stream), *extra])
        self.assertEqual(code, 0)
        return self.out.read_text().splitlines()

    def test_only_usage_leaves(self):
        text = "\n".join(self.run_export())
        self.assertNotIn("SENTINEL", text)
        self.assertNotIn("factory_credits", text, "Factory's unit is not tokens and stays behind")
        self.assertNotIn("totalInputTokens", text)

    def test_every_usage_record_is_kept_in_the_shape_keysrs_reads(self):
        lines = self.run_export()
        droid = [l for l in lines if MARKER in l]
        self.assertEqual(len(droid), 3, "the active log and its dated rotation")
        record = json.loads(droid[-1].split(MARKER, 1)[1])
        self.assertEqual(record["tags"], {"modelId": "kimi-k3", "sessionId": "s-1"})
        self.assertEqual(record["inputTokens"], 100)
        self.assertTrue(droid[-1].startswith("[2026-10-16T21:40:00.000Z] INFO:"))
        claude = [json.loads(l) for l in lines if l.startswith("{") and '"assistant"' in l]
        self.assertEqual(sorted(c["requestId"] for c in claude), ["req_1", "req_2"], "subagent transcripts too")
        self.assertEqual(claude[0]["message"]["usage"] if claude[0]["requestId"] == "req_1" else claude[1]["message"]["usage"],
                         {"input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 300,
                          "cache_creation_input_tokens": 40})
        completion = [json.loads(l) for l in lines if '"completion"' in l]
        self.assertEqual(completion, [{"session_id": "s-1", "timestamp": 1792118855901, "type": "completion",
                                       "usage": {"input_tokens": 138, "output_tokens": 165253, "thinking_tokens": 56728}}])

    def test_sources_can_be_left_out(self):
        lines = self.run_export("--no-claude", "--no-droid")
        self.assertEqual(len(lines), 1)
        self.assertIn('"completion"', lines[0])


STAMP = "[2026-10-16T21:40:00.000Z"


def droid_with(**fields):
    record = {"inputTokens": 1, "upstreamResponseId": "r1", "tags": {"modelId": "m", "sessionId": "s"}}
    record.update(fields)
    return STAMP + MARKER + json.dumps(record)


def claude_with(usage=None, **top):
    record = {"type": "assistant", "sessionId": "c", "requestId": "req_1", "timestamp": "2026-10-16T18:00:00.000Z",
              "message": {"id": "msg_1", "model": "claude-opus-5-5", "usage": usage or {"input_tokens": 1}}}
    record.update(top)
    return json.dumps(record)


class HostileInputTests(unittest.TestCase):
    """Free text and out-of-range numbers must not ride along in allow-listed fields."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "factory" / "logs").mkdir(parents=True)
        (self.root / "claude" / "projects" / "p").mkdir(parents=True)
        self.out = self.root / "out.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *args, droid=(), claude=(), stream=()):
        (self.root / "factory" / "logs" / "droid-log-single.log").write_text("\n".join(droid) + "\n")
        (self.root / "claude" / "projects" / "p" / "s.jsonl").write_text("\n".join(claude) + "\n")
        argv = ["-o", str(self.out), "--factory-home", str(self.root / "factory"),
                "--claude-home", str(self.root / "claude")]
        if stream:
            sp = self.root / "stream.jsonl"
            sp.write_text("\n".join(stream) + "\n")
            argv += ["--stream", str(sp)]
        argv += list(args)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = exporter.main(argv)
        lines = self.out.read_text().splitlines() if self.out.exists() else None
        return code, lines, err.getvalue()

    def test_token_counts_must_be_plain_ints_in_range(self):
        for bad in (1e30, float("nan"), True, -5, 10**12 + 1, "7", [1], {"a": 1}, 2**63):
            with self.subTest(bad=bad):
                code, lines, err = self.run_main(droid=[droid_with(inputTokens=bad)],
                                                 claude=[claude_with(usage={"input_tokens": bad})],
                                                 stream=[json.dumps({"type": "completion", "session_id": "s", "timestamp": 1,
                                                                     "usage": {"input_tokens": bad}})])
                self.assertEqual(code, 0)
                self.assertEqual(lines, [], "every record with a bad count is dropped")
                self.assertIn("dropped", err)
                self.assertNotIn("NaN", "".join(lines))
        code, lines, _ = self.run_main(droid=[droid_with(inputTokens=10**12, outputTokens=0)])
        self.assertEqual(len(lines), 1)

    def test_droid_stamp_must_be_an_instant(self):
        long_prefix = "[" + "A" * 10240
        for bad in ("[SENTINEL not a timestamp", long_prefix, "[2026-10-16", "[2026-10-16T21:40:00",
                    "[2026-10-16T21:40:00.000Z\nSENTINEL"):
            with self.subTest(bad=bad[:30]):
                line = bad + MARKER + json.dumps({"inputTokens": 1})
                code, lines, err = self.run_main(droid=[line])
                self.assertEqual(lines, [])
                self.assertNotIn("SENTINEL", err + "".join(lines))
                self.assertIn("dropped", err)
        code, lines, err = self.run_main(droid=[MARKER[1:] + json.dumps({"inputTokens": 1})])
        self.assertEqual(lines, [], "no leading [ means no stamp")
        for good in ("2026-10-16T21:40:00Z", "2026-10-16T21:40:00.123456789+02:00", "2026-10-16T21:40:00-0700"):
            code, lines, _ = self.run_main(droid=["[" + good + MARKER + json.dumps({"inputTokens": 1})])
            self.assertEqual(len(lines), 1, good)
            self.assertTrue(lines[0].startswith("[" + good + "] INFO:"))

    def test_ids_and_times_are_bounded_and_typed(self):
        bad_ids = ("x" * 129, "has space", "new\nline", "SENT\x00", True, 5, ["a"], {"a": "b"}, "")
        for bad in bad_ids:
            with self.subTest(bad=repr(bad)[:20]):
                code, lines, err = self.run_main(
                    droid=[droid_with(tags={"modelId": bad, "sessionId": "s"}), droid_with(upstreamResponseId=bad)],
                    claude=[claude_with(requestId=bad), claude_with(sessionId=bad),
                            claude_with(message={"id": bad, "model": "m", "usage": {"input_tokens": 1}})],
                    stream=[json.dumps({"type": "completion", "session_id": bad, "timestamp": 1,
                                        "usage": {"input_tokens": 1}})])
                self.assertEqual(lines, [])
        for bad_time in ("yesterday", 5, True, float("nan"), "2026-10-16T18:00:00.000Z\nX", "x" * 10240):
            with self.subTest(claude_time=repr(bad_time)[:20]):
                self.assertEqual(self.run_main(claude=[claude_with(timestamp=bad_time)])[1], [])
        for bad_time in ("2026-10-16T18:00:00Z", 1.5, True, -1, float("nan"), None, 10**30):
            with self.subTest(stream_time=repr(bad_time)[:20]):
                line = json.dumps({"type": "completion", "session_id": "s", "timestamp": bad_time,
                                   "usage": {"input_tokens": 1}})
                self.assertEqual(self.run_main(stream=[line])[1], [])
        edge = "a" * 128
        code, lines, _ = self.run_main(claude=[claude_with(requestId=edge + ".:@/-_Z9")[:0] or claude_with(requestId=edge)])
        self.assertEqual(len(lines), 1)
        self.assertIn(edge, lines[0])

    def test_fixture_ids_export_unchanged(self):
        uuid = "bbbbbbbb-0000-4000-8000-000000000001"
        code, lines, err = self.run_main(
            droid=[droid_with(upstreamResponseId="req_011CXYZ", tags={"modelId": "claude-opus-5-5", "sessionId": uuid})],
            claude=[claude_with(sessionId=uuid, requestId="req_011CXYZ")])
        self.assertEqual(code, 0)
        self.assertIn(uuid, lines[0])
        self.assertIn('"requestId":"req_011CXYZ"', lines[1])
        self.assertIn('"model":"claude-opus-5-5"', lines[1])
        self.assertEqual(err.count("dropped"), 0)


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "factory" / "logs").mkdir(parents=True)
        (self.root / "factory" / "logs" / "droid-log-single.log").write_text(droid_with() + "\n")
        (self.root / "claude" / "projects" / "p").mkdir(parents=True)
        self.out = self.root / "out.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *args, base=True):
        argv = list(args)
        if base:
            argv += ["--factory-home", str(self.root / "factory"), "--claude-home", str(self.root / "claude")]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            try:
                code = exporter.main(argv)
            except SystemExit as exit_:
                code = exit_.code
        return code, err.getvalue()

    def one_line(self, err):
        self.assertEqual(len(err.strip().splitlines()), 1, err)
        self.assertNotIn("Traceback", err)

    def test_unwritable_output(self):
        for target in (self.root / "missing" / "o.jsonl", self.root):
            code, err = self.run_main("-o", str(target))
            self.assertEqual(code, 2)
            self.one_line(err)
            self.assertTrue(err.startswith(f"cannot write {target}: "), err)
        self.assertFalse((self.root / "missing").exists())

    def test_missing_named_inputs_fail_without_leaving_output(self):
        cases = (("--stream", str(self.root / "nope.jsonl")),
                 ("--factory-home", str(self.root / "nofactory")),
                 ("--claude-home", str(self.root / "noclaude")))
        for extra in cases:
            with self.subTest(extra=extra):
                base = [a for a in ("--factory-home", str(self.root / "factory"), "--claude-home", str(self.root / "claude"))]
                argv = ["-o", str(self.out)] + base + list(extra)
                # a later duplicate wins in argparse
                code, err = self.run_main(*argv, base=False)
                self.assertNotEqual(code, 0)
                self.one_line(err)
                self.assertFalse(self.out.exists())

    def test_default_homes_may_be_absent(self):
        # nothing was named, so nothing is an error; the sources just yield zero rows
        old = os.environ.get("CLAUDE_CONFIG_DIR")
        try:
            os.environ["CLAUDE_CONFIG_DIR"] = str(self.root / "noclaude")
            code, err = self.run_main("-o", str(self.out), "--no-droid", base=False)
        finally:
            if old is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = old
        self.assertEqual(code, 0, err)

    def test_fifo_input_is_refused_without_blocking(self):
        fifo = self.root / "fifo.jsonl"
        os.mkfifo(fifo)
        code, err = self.run_main("-o", str(self.out), "--stream", str(fifo))
        self.assertNotEqual(code, 0)
        self.one_line(err)
        self.assertFalse(self.out.exists())
        # one found while walking the Claude projects folder is skipped, not opened
        os.mkfifo(self.root / "claude" / "projects" / "p" / "pipe.jsonl")
        code, err = self.run_main("-o", str(self.out))
        self.assertEqual(code, 0)
        self.assertIn("not a regular file", err)

    def test_output_may_not_be_an_input_or_inside_projects(self):
        stream = self.root / "stream.jsonl"
        stream.write_text(json.dumps({"type": "completion", "session_id": "s", "timestamp": 1,
                                      "usage": {"input_tokens": 1}}) + "\n")
        before = stream.read_text()
        code, err = self.run_main("-o", str(stream), "--stream", str(stream))
        self.assertEqual(code, 2)
        self.one_line(err)
        self.assertEqual(stream.read_text(), before)
        link = self.root / "link.jsonl"
        link.symlink_to(stream)
        code, err = self.run_main("-o", str(link), "--stream", str(stream))
        self.assertEqual(code, 2)
        self.assertEqual(stream.read_text(), before)
        log = self.root / "factory" / "logs" / "droid-log-single.log"
        logged = log.read_text()
        code, err = self.run_main("-o", str(log))
        self.assertEqual(code, 2)
        self.assertEqual(log.read_text(), logged)
        inside = self.root / "claude" / "projects" / "p" / "export.jsonl"
        code, err = self.run_main("-o", str(inside))
        self.assertEqual(code, 2)
        self.one_line(err)
        self.assertFalse(inside.exists())

    def test_help_warns_about_the_mac_running_keysrs(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            exporter.main(["--help"])
        text = " ".join(out.getvalue().split()).replace("- ", "-")
        self.assertIn("double-count", text)

    def test_failure_while_writing_removes_the_output(self):
        original = exporter.export

        def boom(*args, **kwargs):
            args[3].write("partial\n")
            raise OSError(28, "No space left on device")
        exporter.export = boom
        try:
            code, err = self.run_main("-o", str(self.out))
        finally:
            exporter.export = original
        self.assertEqual(code, 2)
        self.one_line(err)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
