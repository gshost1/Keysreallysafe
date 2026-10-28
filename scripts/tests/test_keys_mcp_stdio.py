#!/usr/bin/env python3
"""The `keys mcp` stdio server over real pipes: framing, shutdown, signals.

Spawns the built `.build/debug/keys` (never the installed app) with a temp
KEYS_CATALOG, so nothing real is read or written: no keychain, no Touch ID, no
network, no real credential. This is the process half of VAL-MCP-LIFECYCLE-008/009/010
(exit codes, timing, SIGINT/SIGTERM, --help/--bogus); the in-process half is
MCPServerShutdownTests. CI runs this via
`python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, after `swift test`
has built the binary.
"""
import json
import os
import select
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
KEYS = REPO / ".build" / "debug" / "keys"
SHUTDOWN_BOUND_S = 2.0  # the documented shutdown bound
IDLE_S = 5.0            # the no-idle-timeout probe must outlive this


def frame(method, id, params=None):
    out = '{"jsonrpc":"2.0","id":%s,"method":"%s"' % (json.dumps(id), method)
    if params is not None:
        out += ',"params":%s' % json.dumps(params)
    return out + "}"


def initialize(id=1, version="2025-06-18"):
    return frame("initialize", id, {"protocolVersion": version, "capabilities": {},
                                    "clientInfo": {"name": "stdio-harness", "version": "0"}})


class Session:
    """One spawned `keys mcp` speaking JSON-RPC over its pipes."""

    def __init__(self, test):
        self.test = test
        self.tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self.tmp.cleanup)
        env = dict(os.environ)
        env["KEYS_CATALOG"] = str(Path(self.tmp.name) / "catalog.db")
        self.proc = subprocess.Popen(
            [str(KEYS), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env)
        test.addCleanup(self.close)

    def send(self, text):
        self.proc.stdin.write((text + "\n").encode())
        self.proc.stdin.flush()

    def read_line(self, timeout=SHUTDOWN_BOUND_S):
        """One stdout line, or None on timeout/EOF. Whole lines are written whole,
        so a ready pipe means a complete frame."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                return None
            line = self.proc.stdout.readline()
            return line.decode() if line else None

    def read_frame(self, timeout=SHUTDOWN_BOUND_S):
        """One stdout line asserted present, decoded as the response JSON object."""
        line = self.read_line(timeout)
        self.test.assertIsNotNone(line, "the server did not answer within %.1fs" % timeout)
        return json.loads(line)

    def close_stdin(self):
        if not self.proc.stdin.closed:
            self.proc.stdin.close()

    def wait(self, timeout=SHUTDOWN_BOUND_S):
        return self.proc.wait(timeout=timeout)

    def close(self):
        """Never leave a spawned server behind a failed assertion."""
        if self.proc.poll() is None:
            try:
                self.close_stdin()
                self.proc.wait(timeout=SHUTDOWN_BOUND_S)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        try:
            self.proc.stdout.close()
            self.proc.stderr.close()
        except OSError:
            pass

    def stderr_text(self):
        return self.proc.stderr.read().decode(errors="replace")

    def drain_stdout_after_exit(self):
        leftovers = self.proc.stdout.read()
        self.test.assertEqual(leftovers, b"", "no bytes after the final frame")
        return leftovers


@unittest.skipUnless(KEYS.exists() and os.access(KEYS, os.X_OK),
                     "build first: swift build (the harness drives .build/debug/keys)")
class KeysMCPStdioTests(unittest.TestCase):

    def test_initialize_tools_list_and_clean_eof(self):
        s = Session(self)
        s.send(initialize())
        first = s.read_frame()
        self.assertEqual(first["id"], 1)
        self.assertEqual(first["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(first["result"]["serverInfo"]["name"], "keysrs")
        self.assertEqual(first["result"]["capabilities"], {"tools": {}})
        self.assertIn("instructions", first["result"])

        s.send(frame("tools/list", 2))
        second = s.read_frame()
        self.assertEqual(second["id"], 2)
        tools = second["result"]["tools"]
        self.assertGreater(len(tools), 0)
        self.assertIn("version", [t["name"] for t in tools])
        self.assertNotIn("nextCursor", second["result"])

        s.send(frame("tools/call", 3, {"name": "version"}))
        third = s.read_frame()
        self.assertEqual(third["id"], 3)
        self.assertTrue(third["result"]["content"][0]["text"].strip())

        s.send(frame("ping", "last"))
        fourth = s.read_frame()
        self.assertEqual(fourth["result"], {})

        # stdin EOF: the process exits 0 within the bound, and nothing else was
        # ever written to stdout.
        s.close_stdin()
        self.assertEqual(s.wait(), 0)
        s.drain_stdout_after_exit()
        stderr = s.stderr_text()
        self.assertNotIn("jsonrpc", stderr, "stderr is prose only, never frames")
        self.assertNotIn('"result"', stderr)

    def test_immediate_eof_writes_nothing_and_exits_zero(self):
        s = Session(self)
        s.close_stdin()
        self.assertEqual(s.wait(), 0)
        s.drain_stdout_after_exit()
        self.assertEqual(s.stderr_text(), "")

    def test_no_idle_timeout_then_clean_exit(self):
        s = Session(self)
        s.send(initialize())
        s.read_frame()
        time.sleep(IDLE_S)
        self.assertIsNone(s.proc.poll(), "an idle server must not exit on its own")
        s.send(frame("ping", "still-here"))
        line = s.read_frame()
        self.assertEqual(line["id"], "still-here")
        s.close_stdin()
        self.assertEqual(s.wait(), 0)

    def test_sigterm_exits_zero_with_complete_last_line(self):
        s = Session(self)
        s.send(initialize())
        s.read_frame()
        s.send(frame("ping", "last-frame"))
        self.assertEqual(s.read_frame()["id"], "last-frame")
        s.proc.send_signal(signal.SIGTERM)
        self.assertEqual(s.wait(), 0, "SIGTERM is handled, not default signal death (-15)")
        s.drain_stdout_after_exit()
        self.assertNotIn("jsonrpc", s.stderr_text())

    def test_sigint_exits_zero_with_complete_last_line(self):
        s = Session(self)
        s.send(initialize())
        s.read_frame()
        s.proc.send_signal(signal.SIGINT)
        self.assertEqual(s.wait(), 0, "SIGINT is handled, not default signal death (-2)")
        s.drain_stdout_after_exit()
        self.assertNotIn("jsonrpc", s.stderr_text())

    def test_failure_laden_transcript_exits_zero(self):
        s = Session(self)
        s.send(initialize())
        s.read_frame()
        s.send('{"jsonrpc":"2.0","id":1,"meth')                                # parse error
        s.send('[{"jsonrpc":"2.0","id":9,"method":"ping"}]')                   # batch
        s.send(frame("resources/list", "u1"))                                   # unknown method
        s.send('{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}')  # silent
        s.send(frame("tools/call", "u2", {"name": "definitely_not_a_tool"}))    # unknown tool
        codes = [-32700, -32600, -32601, -32602]
        for index in range(4):
            line = s.read_frame()
            self.assertEqual(line["error"]["code"], codes[index])
            self.assertIn("id", line)
        s.send(frame("ping", "survivor"))
        self.assertEqual(s.read_frame()["result"], {})
        s.close_stdin()
        self.assertEqual(s.wait(), 0, "no message-level failure may exit the process")
        s.drain_stdout_after_exit()
        self.assertNotIn("jsonrpc", s.stderr_text())

    def test_help_and_bogus_flag_start_no_server(self):
        help_run = subprocess.run([str(KEYS), "mcp", "--help"], capture_output=True,
                                  timeout=SHUTDOWN_BOUND_S)
        self.assertEqual(help_run.returncode, 0)
        self.assertIn(b"mcp", help_run.stdout)
        # A bad flag is a usage error (exit 64); neither invocation starts a server,
        # which is why both return on their own within the bound.
        bogus = subprocess.run([str(KEYS), "mcp", "--bogus"], capture_output=True,
                               timeout=SHUTDOWN_BOUND_S)
        self.assertEqual(bogus.returncode, 64)


if __name__ == "__main__":
    unittest.main()
