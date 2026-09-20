"""Offline MCP adapter tests: fake local transport only, never Touch ID or provider keys."""

import http.server
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest
import urllib.error
import uuid


SPEC = importlib.util.spec_from_file_location(
    "optimizer_mcp", Path(__file__).resolve().parents[1] / "optimizer-mcp.py"
)
mcp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp)

PROJECT = str(uuid.uuid4())
ORIGIN = "a" * 64
SESSION = "kso_" + "b" * 64


class FakeClient:
    def __init__(self, writable=False, jev_enabled=False):
        self.writable = writable
        self.jev_enabled = jev_enabled
        self.calls = []

    def call(self, operation, payload):
        self.calls.append((operation, payload))
        return {"operation": operation, "project_id": payload.get("project_id")}


class MCPServerTests(unittest.TestCase):
    def ready_server(self, client=None):
        server = mcp.Server(client or FakeClient())
        init = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(init["result"]["serverInfo"]["name"], "keys-optimizer")
        self.assertIsNone(server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        return server

    def test_initialize_notification_and_read_only_catalog(self):
        server = self.ready_server()
        listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = {tool["name"] for tool in listed["result"]["tools"]}
        self.assertIn("keys_optimizer_status", names)
        self.assertIn("keys_memory_get", names)
        self.assertIn("keys_context_prepare", names)
        self.assertNotIn("keys_memory_save", names)
        self.assertNotIn("keys_task_start", names)
        result = server.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "keys_optimizer_status", "arguments": {}}})
        self.assertFalse(result["result"]["isError"])

    def test_writes_require_writable_capability(self):
        server = self.ready_server(FakeClient(writable=False))
        result = server.handle({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "keys_memory_save", "arguments": {"kind": "plan", "title": "p", "content": "c", "source": "test"}}})
        self.assertEqual(result["error"]["code"], -32602)
        writable = FakeClient(writable=True)
        server = self.ready_server(writable)
        result = server.handle({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "keys_memory_save", "arguments": {"kind": "plan", "title": "p", "content": "c", "source": "test", "verification": ["run tests"]}}})
        self.assertFalse(result["result"]["isError"])
        self.assertEqual(writable.calls[-1][0], "entry_save")

    def test_local_context_requires_no_jev_and_rejects_client_hashes(self):
        client = FakeClient(writable=False, jev_enabled=False)
        server = self.ready_server(client)
        arguments = {"query": "parser tests", "current_constraints": ["run tests"], "max_bytes": 2000}
        call = {"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {"name": "keys_context_prepare", "arguments": arguments}}
        self.assertFalse(server.handle(call)["result"]["isError"])
        self.assertEqual(client.calls[-1][0], "context_prepare")
        arguments["validated_dependencies"] = {"source": "forged"}
        self.assertEqual(server.handle(call)["error"]["code"], -32602)

    def test_task_prepare_is_local_by_default_and_evaluations_are_explicit(self):
        client = FakeClient(writable=False, jev_enabled=False)
        server = self.ready_server(client)
        args = {"task_id": "task-1", "query": "parser failure", "context_constraints": ["run tests"],
                "engine_constraints": {"requirements": ["do not deploy"]}}
        response = server.handle({"jsonrpc": "2.0", "id": 21, "method": "tools/call",
                                  "params": {"name": "keys_task_prepare", "arguments": args}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls, [("context_prepare", {"query": "parser failure", "available_tools": [],
            "current_constraints": ["run tests"], "max_bytes": 12000, "max_estimated_tokens": 4096, "max_entries": 8})])
        args["include_evaluations"] = True
        response = server.handle({"jsonrpc": "2.0", "id": 22, "method": "tools/call",
                                  "params": {"name": "keys_task_prepare", "arguments": args}})
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(response["result"]["content"][0]["text"], "jev_not_enabled")

    def test_task_prepare_preserves_constraint_types_and_fails_closed(self):
        class RecordingClient(FakeClient):
            def call(self, operation, payload):
                self.calls.append((operation, payload))
                if operation == "retrieve":
                    raise mcp.SafeError("session_locked_or_expired")
                return {"operation": operation, "usage": {"requests": 1}}
        client = RecordingClient(jev_enabled=True)
        server = self.ready_server(client)
        args = {"task_id": "task-1", "query": "parser", "context": "bounded context", "include_evaluations": True,
                "context_constraints": ["local constraint"], "engine_constraints": {"requirements": ["engine constraint"]}}
        response = server.handle({"jsonrpc": "2.0", "id": 23, "method": "tools/call",
                                  "params": {"name": "keys_task_prepare", "arguments": args}})
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(response["result"]["content"][0]["text"], "session_locked_or_expired")
        self.assertEqual(client.calls[0][1]["current_constraints"], ["local constraint"])
        self.assertEqual(client.calls[1][1]["current_constraints"], {"requirements": ["engine constraint"]})

    def test_finish_evidence_and_candidate_capture_require_writable(self):
        client = FakeClient(writable=True)
        server = self.ready_server(client)
        finish = {"id": "task-1", "outcome": "success", "verification": ["tests passed"]}
        response = server.handle({"jsonrpc": "2.0", "id": 24, "method": "tools/call",
                                  "params": {"name": "keys_task_finish", "arguments": finish}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls[-1], ("task_finish", finish))
        capture = {"task_id": "task-1", "kind": "plan", "title": "Fix parser", "content": "Curated plan",
                   "source": "verified task", "verification": ["tests passed"], "required_tools": ["Read"],
                   "constraints": ["no deploy"], "dependencies": {"src/parser.ts": "v1"}}
        response = server.handle({"jsonrpc": "2.0", "id": 25, "method": "tools/call",
                                  "params": {"name": "keys_candidate_capture", "arguments": capture}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls[-1], ("candidate_capture", capture))
        capture["verification"] = []
        response = server.handle({"jsonrpc": "2.0", "id": 26, "method": "tools/call",
                                  "params": {"name": "keys_candidate_capture", "arguments": capture}})
        self.assertEqual(response["error"]["code"], -32602)

    def test_malformed_and_non_finite_arguments_are_rejected(self):
        server = self.ready_server()
        bad_id = server.handle({"jsonrpc": "2.0", "id": [], "method": "ping", "params": {}})
        self.assertEqual(bad_id["error"]["code"], -32600)
        bad_args = server.handle({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "keys_usage_record", "arguments": {"task_id": "t", "event_id": "e", "source": "local", "kind": "main", "model": "m", "reported_cost_usd": math.inf}}})
        self.assertEqual(bad_args["error"]["code"], -32602)
        self.assertFalse(mcp.validate(float("nan"), {"type": "number"}))
        self.assertFalse(mcp.validate(10 ** 400, {"type": "integer"}))

    def test_client_scope_and_redirect_guards(self):
        client = mcp.KeysClient({"port": 12767, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT, "writable": True})
        client.request = lambda path, body: body
        sent = client.call("summary", {})
        self.assertEqual(sent["payload"]["project_id"], PROJECT)
        with self.assertRaises(mcp.SafeError):
            client.call("summary", {"project_id": str(uuid.uuid4())})

        class RedirectOpener:
            def open(self, request, timeout):
                raise urllib.error.HTTPError(request.full_url, 302, "redirect", {}, io.BytesIO())

        client = mcp.KeysClient({"port": 12767, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT, "writable": True})
        client.opener = RedirectOpener()
        with self.assertRaises(mcp.SafeError) as caught:
            client.request("/api/optimizer/rpc", {"operation": "summary", "payload": {}})
        self.assertEqual(str(caught.exception), "operation_refused")

    def test_jev_read_only_session_can_use_implicit_task_and_routing_cost(self):
        client = FakeClient(jev_enabled=True)
        server = self.ready_server(client)
        args = {"request_text": "run tests", "proposed_memory": "verify fixtures"}
        response = server.handle({"jsonrpc": "2.0", "id": 10, "method": "tools/call",
                                  "params": {"name": "keys_memory_assess", "arguments": args}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls[-1], ("assess_memory", args))
        args = {"request_text": "run tests", "candidates": [], "explicit_model_id": "chosen-model",
                "current_model_id": "chosen-model", "optimizer_cost_usd": 0.001}
        response = server.handle({"jsonrpc": "2.0", "id": 11, "method": "tools/call",
                                  "params": {"name": "keys_models_recommend", "arguments": args}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls[-1][1]["optimizer_cost_usd"], 0.001)

    def test_protocol_version_and_usage_required_fields_fail_safely(self):
        server = mcp.Server(FakeClient())
        response = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                  "params": {"protocolVersion": ["invalid"]}})
        self.assertEqual(response["result"]["protocolVersion"], "2025-06-18")
        server = self.ready_server(FakeClient(writable=True))
        args = {"task_id": "t", "event_id": "e", "source": "local", "kind": "main", "model": "m"}
        response = server.handle({"jsonrpc": "2.0", "id": 12, "method": "tools/call",
                                  "params": {"name": "keys_usage_record", "arguments": args}})
        self.assertEqual(response["error"]["code"], -32602)


class FakeBackend(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size)
        FakeBackend.calls.append((self.path, dict(self.headers), body))
        payload = {"aggregate": {"events": 0}, "projects": [], "tasks": []}
        if self.path.endswith("/close"):
            payload = {"closed": True}
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        return


class SubprocessSmokeTests(unittest.TestCase):
    def test_bad_numeric_and_deep_json_do_not_terminate_session(self):
        config = {"port": 1, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT, "writable": True}
        oversized = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "keys_usage_record", "arguments": {
            "task_id": "t", "event_id": "e", "source": "local", "kind": "main", "model": "m", "status": "success", "latency_ms": 10 ** 400}}}
        lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
                 json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}), json.dumps(oversized),
                 '{"jsonrpc":"2.0","id":3,"method":"ping","params":{"nested":' + '[' * 2_000 + '0' + ']' * 2_000 + '}}',
                 json.dumps({"jsonrpc": "2.0", "id": 4, "method": "ping"})]
        process = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "optimizer-mcp.py")],
            input="\n".join(lines) + "\n", text=True, capture_output=True,
            env={"KEYS_OPTIMIZER_SESSION": json.dumps(config)}, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(responses[1]["error"]["code"], -32602)
        self.assertEqual(responses[2]["error"]["code"], -32700)
        self.assertEqual(responses[-1], {"jsonrpc": "2.0", "id": 4, "result": {}})
        self.assertNotIn(SESSION, process.stdout + process.stderr)

    def test_stdio_smoke_uses_fake_local_backend_and_never_prints_capability(self):
        FakeBackend.calls = []
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeBackend)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        config = {"port": httpd.server_address[1], "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT, "writable": False}
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "keys_optimizer_status", "arguments": {}}},
        ]
        try:
            env = dict(os.environ, KEYS_OPTIMIZER_SESSION=json.dumps(config))
            proc = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "optimizer-mcp.py")], input="\n".join(json.dumps(item) for item in messages) + "\n", text=True, capture_output=True, env=env, timeout=10)
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=2)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn(SESSION, proc.stdout + proc.stderr)
        responses = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "keys-optimizer")
        self.assertFalse(responses[-1]["result"]["isError"])
        rpc = next(item for item in FakeBackend.calls if item[0].endswith("/rpc"))
        self.assertEqual(rpc[1]["X-Ksf-Token"], ORIGIN)
        self.assertEqual(rpc[1]["X-Ksf-Optimizer"], SESSION)


if __name__ == "__main__":
    unittest.main()
