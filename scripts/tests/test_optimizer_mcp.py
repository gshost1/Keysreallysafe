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
TASK = str(uuid.uuid4())
ORIGIN = "a" * 64
SESSION = "kso_" + "b" * 64
CJK = chr(0x8A18)  # three UTF-8 bytes, six characters when ASCII-escaped


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
        args = {"task_id": TASK, "query": "parser failure", "context_constraints": ["run tests"],
                "engine_constraints": {"requirements": ["do not deploy"]}}
        response = server.handle({"jsonrpc": "2.0", "id": 21, "method": "tools/call",
                                  "params": {"name": "keys_task_prepare", "arguments": args}})
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(client.calls, [("context_prepare", {"query": "parser failure", "available_tools": [],
            "current_constraints": ["run tests"], "max_bytes": 12000, "max_estimated_tokens": 4000, "max_entries": 8})])
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
        args = {"task_id": TASK, "query": "parser", "context": "bounded context", "include_evaluations": True,
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
        capture = {"task_id": TASK, "kind": "plan", "title": "Fix parser", "content": "Curated plan",
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
        bad_args = server.handle({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "keys_usage_record", "arguments": {"task_id": TASK, "event_id": "e", "source": "local", "kind": "main", "model": "m", "reported_cost_usd": math.inf}}})
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
        args = {"task_id": TASK, "event_id": "e", "source": "local", "kind": "main", "model": "m"}
        response = server.handle({"jsonrpc": "2.0", "id": 12, "method": "tools/call",
                                  "params": {"name": "keys_usage_record", "arguments": args}})
        self.assertEqual(response["error"]["code"], -32602)


class ScriptedClient(FakeClient):
    """Returns or raises a scripted outcome per operation; records every call."""

    def __init__(self, outcomes, task_id=None):
        super().__init__(jev_enabled=True)
        self.outcomes = outcomes
        self.task_id = task_id

    def call(self, operation, payload):
        self.calls.append((operation, payload))
        outcome = self.outcomes.get(operation, {"operation": operation})
        if isinstance(outcome, list):
            outcome = outcome.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class TrackedBody(io.BytesIO):
    closed_count = 0

    def close(self):
        TrackedBody.closed_count += 1
        super().close()


class TaskPrepareContractTests(unittest.TestCase):
    CONTEXT = {"pack": "decrypted project context", "fingerprint": "f" * 8}
    USAGE = {"requests": 1, "cache_hits": 0, "actual_input_tokens": 10, "actual_output_tokens": 2}

    def prepare(self, client, **extra):
        server = mcp.Server(client)
        server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        args = {"query": "parser", "include_evaluations": True, **extra}
        return server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                              "params": {"name": "keys_task_prepare", "arguments": args}})

    def test_task_id_is_optional_and_falls_back_to_the_session_task(self):
        client = ScriptedClient({"context_prepare": self.CONTEXT})
        response = self.prepare(client)
        self.assertFalse(response["result"]["isError"])
        self.assertTrue(all("task_id" not in payload for _, payload in client.calls))
        session_task = str(uuid.uuid4())
        client = ScriptedClient({"context_prepare": self.CONTEXT}, task_id=session_task)
        self.prepare(client)
        self.assertEqual([payload["task_id"] for op, payload in client.calls if op != "context_prepare"], [session_task] * 3)
        client = ScriptedClient({"context_prepare": self.CONTEXT}, task_id=session_task)
        self.prepare(client, task_id=TASK)
        self.assertEqual([payload["task_id"] for op, payload in client.calls if op != "context_prepare"], [TASK] * 3)
        self.assertNotIn("task_id", client.calls[0][1])

    def test_task_ids_must_be_canonical_uuids(self):
        for bad in ("task-1", "", TASK + " ", TASK.replace("-", ""), "{" + TASK + "}", "urn:uuid:" + TASK, 7, None):
            response = self.prepare(ScriptedClient({}), task_id=bad)
            self.assertEqual(response["error"]["code"], -32602, bad)
        self.assertTrue(mcp.validate(TASK.upper(), mcp.TASK_ID))
        config = {"port": 12767, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT}
        self.assertIsNone(mcp.KeysClient(dict(config, task_id=None)).task_id)
        self.assertEqual(mcp.KeysClient(dict(config, task_id=TASK)).task_id, TASK)
        for bad in ("task-1", 7, [TASK]):
            with self.assertRaises(mcp.SafeError):
                mcp.KeysClient(dict(config, task_id=bad))

    def test_task_start_requires_a_valid_client_and_plan_candidates_are_rejected(self):
        client = FakeClient(writable=True)
        server = MCPServerTests.ready_server(self, client)
        def start(arguments):
            return server.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                  "params": {"name": "keys_task_start", "arguments": arguments}})
        for bad in ({}, {"client": ""}, {"client": "claude code"}, {"client": "x" * 129}, {"client": "claude-code\n"},
                    {"client": "claude-code", "parent_id": "task-1"}):
            self.assertEqual(start(bad)["error"]["code"], -32602, bad)
        self.assertEqual(client.calls, [])
        self.assertFalse(start({"client": "claude-code", "parent_id": TASK})["result"]["isError"])
        self.assertEqual(client.calls[-1], ("task_start", {"client": "claude-code", "parent_id": TASK}))
        response = self.prepare(ScriptedClient({}), plan_candidates=[{"id": "p"}])
        self.assertEqual(response["error"]["code"], -32602)
        properties = mcp.TOOLS["keys_task_prepare"][2]["properties"]
        self.assertNotIn("plan_candidates", properties)
        self.assertEqual(mcp.TOOLS["keys_task_prepare"][2]["required"], ["query"])

    def test_routing_inputs_reach_only_the_model_stage(self):
        routing = {"explicit_model_id": "model-a", "current_model_id": "model-b", "optimizer_cost_usd": 0.001,
                   "cache_rebuild_cost_usd": 0.02, "fallback_cost_usd": 0.3}
        client = ScriptedClient({"context_prepare": self.CONTEXT})
        catalog = [{"id": "model-a"}]
        response = self.prepare(client, model_catalog=catalog, tool_catalog=[{"name": "Read"}], **routing)
        self.assertFalse(response["result"]["isError"])
        calls = dict(client.calls)
        self.assertEqual({key: calls["route_model"][key] for key in routing}, routing)
        self.assertEqual(calls["route_model"]["candidates"], catalog)
        self.assertEqual(calls["select_tools"]["candidates"], [{"name": "Read"}])
        self.assertNotIn("candidates", calls["retrieve"])
        for operation in ("context_prepare", "retrieve", "select_tools"):
            self.assertFalse(set(routing) & set(calls[operation]), operation)
        client = ScriptedClient({"context_prepare": self.CONTEXT})
        self.prepare(client)
        self.assertFalse(set(routing) & set(dict(client.calls)["route_model"]))
        self.assertEqual(self.prepare(ScriptedClient({}), fallback_cost_usd=-1)["error"]["code"], -32602)

    def test_recoverable_stage_failure_returns_context_only_after_fresh_authorization(self):
        for reason in ("operation_denied", "optimizer_limit", "operation_refused"):
            client = ScriptedClient({"context_prepare": self.CONTEXT, "select_tools": mcp.SafeError(reason),
                                     "retrieve": {"usage": dict(self.USAGE)}, "route_model": {"usage": dict(self.USAGE)}})
            response = self.prepare(client)
            self.assertFalse(response["result"]["isError"], reason)
            result = response["result"]["structuredContent"]
            self.assertEqual(result["evaluations"], "partial")
            self.assertEqual(result["stages"]["context"], self.CONTEXT)
            self.assertEqual(result["stages"]["tools"], {"status": "unavailable", "reason": reason})
            self.assertEqual(result["usage"], {"unknown": True, "requests": 2, "cache_hits": 0})
            # The authorization recheck happens after every stage, immediately before returning.
            self.assertEqual([op for op, _ in client.calls], ["context_prepare", "retrieve", "select_tools", "route_model", "summary"])

    def test_partial_result_is_suppressed_when_the_authorization_recheck_fails(self):
        for recheck in ("session_locked_or_expired", "keys_unavailable", "operation_denied", "operation_refused"):
            client = ScriptedClient({"context_prepare": self.CONTEXT, "retrieve": mcp.SafeError("operation_denied"),
                                     "summary": mcp.SafeError(recheck)})
            response = self.prepare(client)
            self.assertTrue(response["result"]["isError"], recheck)
            self.assertEqual(response["result"]["content"], [{"type": "text", "text": recheck}])
            self.assertNotIn("structuredContent", response["result"])
            self.assertNotIn("decrypted", json.dumps(response))

    def test_lock_network_and_unknown_failures_suppress_context_without_a_recheck(self):
        for reason in ("session_locked_or_expired", "keys_unavailable", "response_too_large", "invalid_response", "unexpected"):
            client = ScriptedClient({"context_prepare": self.CONTEXT, "route_model": mcp.SafeError(reason)})
            response = self.prepare(client)
            self.assertTrue(response["result"]["isError"], reason)
            self.assertNotIn("decrypted", json.dumps(response))
            self.assertNotIn("summary", [op for op, _ in client.calls])

    def test_complete_result_needs_no_recheck_and_usage_rejects_bools_and_negatives(self):
        client = ScriptedClient({"context_prepare": self.CONTEXT, "retrieve": {"usage": dict(self.USAGE)},
                                 "select_tools": {"usage": dict(self.USAGE, requests=True, cache_hits=-4)},
                                 "route_model": {"usage": dict(self.USAGE, cache_hits=2)}})
        result = self.prepare(client)["result"]["structuredContent"]
        self.assertEqual(result["evaluations"], "advisory")
        self.assertEqual(result["usage"], {"unknown": False, "requests": 2, "cache_hits": 2})
        self.assertNotIn("summary", [op for op, _ in client.calls])

    def test_stage_bound_counts_utf8_bytes_without_ascii_expansion(self):
        # 2,900 astral characters: 11.6 KB of UTF-8 but 34,800 characters once ASCII-escaped.
        text = chr(0x1F511) * 2900
        self.assertLess(len(text.encode("utf-8")), 12000)
        stage = {"pack": text}
        self.assertGreater(len(json.dumps(stage)), 24000)
        self.assertIs(mcp.compact_stage(stage), stage)
        self.assertEqual(mcp.compact_stage({"pack": CJK * 8000}), {"status": "stage_too_large"})
        self.assertEqual(mcp.compact_stage({"pack": "\ud800"}), {"status": "invalid_stage"})
        self.assertEqual(mcp.compact_stage({"pack": float("nan")}), {"status": "invalid_stage"})
        client = ScriptedClient({"context_prepare": stage})
        response = self.prepare(client, include_evaluations=False)
        self.assertEqual(response["result"]["structuredContent"]["stages"]["context"], stage)
        inner = response["result"]["content"][0]["text"]
        self.assertIn(text, inner)
        self.assertNotIn("\\ud83d", inner)
        self.assertEqual(json.loads(inner), response["result"]["structuredContent"])

    def test_request_limit_counts_utf8_bytes_and_unpaired_surrogates_are_refused(self):
        client = mcp.KeysClient({"port": 12767, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT})
        sent = []

        class Opener:
            def open(self, request, timeout):
                sent.append(request.data)
                raise urllib.error.URLError("offline")

        client.opener = Opener()
        with self.assertRaises(mcp.SafeError) as caught:
            client.call("search", {"query": CJK * 30000})  # 90 KB UTF-8, 180 KB if escaped
        self.assertEqual(str(caught.exception), "keys_unavailable")
        self.assertIn(CJK.encode("utf-8") * 3, sent[0])
        self.assertLessEqual(len(sent[0]), mcp.MAX_MESSAGE)
        with self.assertRaises(mcp.SafeError) as caught:
            client.call("search", {"query": CJK * 43000})
        self.assertEqual(str(caught.exception), "request_too_large")
        with self.assertRaises(mcp.SafeError) as caught:
            client.call("search", {"query": "\ud800"})
        self.assertEqual(str(caught.exception), "invalid_request")
        self.assertEqual(len(sent), 1)

    def test_http_403_known_denial_is_distinct_from_locked_and_unknown_bodies(self):
        client = mcp.KeysClient({"port": 12767, "token": SESSION, "origin_token": ORIGIN, "project_id": PROJECT})

        class Opener:
            def __init__(self, code, body):
                self.code, self.body = code, body

            def open(self, request, timeout):
                raise urllib.error.HTTPError(request.full_url, self.code, "error", {}, TrackedBody(self.body))

        cases = [
            (403, b'{"error":"optimizer_access_denied"}', "operation_denied"),
            (403, b'{"error":"optimizer_locked","message":"Unlock"}', "session_locked_or_expired"),
            (403, b'{"error":"something_new"}', "session_locked_or_expired"),
            (403, b'["optimizer_access_denied"]', "session_locked_or_expired"),
            (403, b'{"error":["optimizer_access_denied"]}', "session_locked_or_expired"),
            (403, b'optimizer_access_denied', "session_locked_or_expired"),
            (403, b'', "session_locked_or_expired"),
            (403, b'{"error":"optimizer_access_denied","pad":"' + b"x" * 5000 + b'"}', "session_locked_or_expired"),
            (403, b'[' * 100_000, "session_locked_or_expired"),
            (401, b'{"error":"optimizer_access_denied"}', "session_locked_or_expired"),
            (423, b'{"error":"optimizer_access_denied"}', "session_locked_or_expired"),
            (429, b'{"error":"optimizer_limit"}', "optimizer_limit"),
            (503, b'{"error":"optimizer_access_denied"}', "operation_refused"),
        ]
        for code, body, expected in cases:
            TrackedBody.closed_count = 0
            client.opener = Opener(code, body)
            with self.assertRaises(mcp.SafeError) as caught:
                client.call("summary", {})
            self.assertEqual(str(caught.exception), expected, (code, body[:40]))
            self.assertGreaterEqual(TrackedBody.closed_count, 1, (code, body[:40]))


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
            "task_id": TASK, "event_id": "e", "source": "local", "kind": "main", "model": "m", "status": "success", "latency_ms": 10 ** 400}}}
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
