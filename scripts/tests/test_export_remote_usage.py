#!/usr/bin/env python3
"""export-remote-usage.py must copy usage and nothing else.

The file it writes leaves a cloud container for the user's Mac, so the test plants content
sentinels in every place a real droid log, Claude Code transcript or stream-json capture holds
text, and checks that none survive while every token count does.
"""
import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
