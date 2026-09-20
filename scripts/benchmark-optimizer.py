#!/usr/bin/env python3
"""Bounded structural benchmark for the production Keys Optimizer engine and MCP."""

import argparse
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid

PROTOCOL = "2025-06-18"
MAX_LINE = 256_000
ROOT = Path(__file__).resolve().parents[1]
HARNESS = Path(__file__).with_name("optimizer-benchmark-engine.mjs")


def model(model_id, input_cost, output_cost, current=False):
    return {
        "id": model_id,
        "name": f"parser {model_id}",
        "description": "classify parser text",
        "provider": "allowed",
        "capabilities": ["tools"],
        "context_limit": 200_000,
        "route_type": "gateway",
        "privacy_route": "scoped",
        "billing_mode": "api",
        "input_cost_per_million": input_cost,
        "output_cost_per_million": output_cost,
        "observed_success_rate": 0.95,
        "is_current": current,
    }


MODELS = [model("large", 10, 20, True), model("small", 1, 2)]
MODEL_REQUIREMENTS = {
    "required_capabilities": ["tools"],
    "allowed_providers": ["allowed"],
    "estimated_input_tokens": 100_000,
    "estimated_output_tokens": 10_000,
    "cache_rebuild_cost_usd": 0.01,
    "fallback_cost_usd": 0,
    "privacy_route": "scoped",
    "billing_mode": "api",
    "route_type": "gateway",
    "at_task_boundary": True,
}
BASE = {
    "project_id": "project-a",
    "task_id": "benchmark-task",
    "project_enabled": True,
    "provider_enabled": True,
    "mode": "suggest",
    "permission_fingerprint": "benchmark-read-only",
    "current_constraints": {"requirements": ["read only"]},
    "available_tools": ["Read"],
    "dependency_hashes": {"src/parser.ts": "current"},
    "policy": {
        "max_requests": 100,
        "max_input_tokens": 30_000,
        "threshold": 0.75,
        "optimizer_cost_usd": 0.001,
    },
}


def tool_case(case_id, kind, candidate, expected_reason):
    arguments = {"request_text": "read parser source", "candidates": [candidate]}
    return {
        "id": case_id,
        "kind": kind,
        "tool": "keys_tools_select",
        "expected": {"reason": expected_reason, "selected_ids": ["Read"] if kind == "semantic" else []},
        "args": arguments,
        "engine": {"command": "select_tools", **arguments},
    }


CASES = (
    tool_case(
        "tools_semantic",
        "semantic",
        {"id": "Read", "name": "Read", "description": "read parser source"},
        "tool_candidates_ranked",
    ),
    tool_case(
        "tools_stale_dependency",
        "stale",
        {
            "id": "Read",
            "name": "Read",
            "description": "read parser source",
            "dependencies": {"src/parser.ts": "stale"},
        },
        "full_catalog_fallback",
    ),
    tool_case(
        "tools_expired",
        "expired",
        {
            "id": "Read",
            "name": "Read",
            "description": "read parser source",
            "expires_at": "2000-01-01T00:00:00Z",
        },
        "full_catalog_fallback",
    ),
    {
        "id": "memory_duplicate",
        "kind": "duplicate",
        "tool": "keys_memory_assess",
        "expected": {"reason": "exact_duplicate", "disposition": "duplicate", "related_id": "m1"},
        "args": {
            "request_text": "parser tests",
            "proposed_memory": "Run parser tests",
            "candidates": [{"id": "m1", "content": "run parser tests"}],
        },
        "engine": {
            "command": "assess_memory",
            "request_text": "parser tests",
            "proposed_memory": {"content": "Run parser tests"},
            "candidates": [{"id": "m1", "project_id": "project-a", "content": "run parser tests"}],
        },
    },
    {
        "id": "model_semantic",
        "kind": "semantic",
        "tool": "keys_models_recommend",
        "expected": {"reason": "lower_estimated_cost_with_quality_gate", "selected_id": "small"},
        "args": {
            "request_text": "classify parser text with tools",
            "current_model_id": "large",
            "optimizer_cost_usd": 0.001,
            "candidates": MODELS,
            "task_requirements": MODEL_REQUIREMENTS,
        },
        "engine": {
            "command": "route_model",
            "request_text": "classify parser text with tools",
            "current_model_id": "large",
            "candidates": MODELS,
            "task_requirements": MODEL_REQUIREMENTS,
        },
    },
)


class StdioTransport:
    def __init__(self, command, call_timeout=40, initialize_timeout=120):
        self.call_timeout = call_timeout
        self.initialize_timeout = initialize_timeout
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            env=dict(os.environ),
        )
        os.set_blocking(self.process.stdout.fileno(), False)
        self.buffer = bytearray()

    def exchange(self, message, expect_response=True, initialize=False):
        encoded = json.dumps(message, allow_nan=False, separators=(",", ":")).encode()
        self.process.stdin.write(encoded + b"\n")
        self.process.stdin.flush()
        if not expect_response:
            return None
        timeout = self.initialize_timeout if initialize else self.call_timeout
        deadline = time.monotonic() + timeout
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError("optimizer_mcp_timeout")
                limit = min(65_536, MAX_LINE + 1 - len(self.buffer))
                chunk = os.read(self.process.stdout.fileno(), limit)
                if not chunk:
                    raise RuntimeError("optimizer_mcp_closed")
                self.buffer.extend(chunk)
                if len(self.buffer) > MAX_LINE:
                    raise RuntimeError("optimizer_mcp_response_too_large")
            position = self.buffer.index(10)
            raw = bytes(self.buffer[:position])
            del self.buffer[: position + 1]
        finally:
            selector.close()
        try:
            response = json.loads(raw)
        except (UnicodeError, ValueError):
            raise RuntimeError("invalid_mcp_json") from None
        if not isinstance(response, dict):
            raise RuntimeError("invalid_mcp_response")
        if response.get("jsonrpc") != "2.0" or response.get("id") != message.get("id"):
            raise RuntimeError("invalid_mcp_response")
        return response

    def close(self):
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(self.process.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    self.process.wait(timeout=3)
                    break
                except subprocess.TimeoutExpired:
                    pass
        for stream in (self.process.stdout, self.process.stderr):
            try:
                stream.close()
            except (AttributeError, OSError):
                pass


class MCPClient:
    def __init__(self, transport):
        self.transport = transport
        self.next_id = 1

    def request(self, method, params, initialize=False):
        identifier = self.next_id
        self.next_id += 1
        response = self.transport.exchange(
            {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params},
            initialize=initialize,
        )
        if "error" in response:
            error = response["error"] if isinstance(response["error"], dict) else {}
            raise RuntimeError("mcp_error_%s" % error.get("code", "unknown"))
        if not isinstance(response.get("result"), dict):
            raise RuntimeError("invalid_mcp_result")
        return response["result"]

    def initialize(self):
        result = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL,
                "capabilities": {},
                "clientInfo": {"name": "optimizer-benchmark", "version": "1"},
            },
            initialize=True,
        )
        if result.get("protocolVersion") != PROTOCOL:
            raise RuntimeError("unsupported_protocol_version")
        self.transport.exchange(
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            expect_response=False,
        )
        return self.request("tools/list", {})

    def call(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError") is True:
            raise RuntimeError("mcp_tool_error")
        return result


def extract(result):
    body = result.get("structuredContent")
    if not isinstance(body, dict):
        try:
            body = json.loads(result["content"][0]["text"])
        except (KeyError, IndexError, TypeError, ValueError):
            raise RuntimeError("missing_structured_result") from None
    if not isinstance(body, dict):
        raise RuntimeError("invalid_structured_result")
    return body


def chosen(args):
    return [case for _ in range(args.repetitions) for case in CASES][: args.max_calls]


def offline(cases):
    payload = [{"case_id": case["id"], "input": {**BASE, **case["engine"]}} for case in cases]
    clean_env = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
    process = subprocess.run(
        ["node", str(HARNESS)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        cwd=ROOT,
        env=clean_env,
        timeout=30,
    )
    if process.returncode:
        raise RuntimeError("offline_engine_failed")
    response = json.loads(process.stdout)
    if not isinstance(response, list) or len(response) != len(cases):
        raise RuntimeError("invalid_offline_engine_response")
    return response


def usage(body):
    raw = body.get("usage") if isinstance(body.get("usage"), dict) else {}
    integer_fields = ("requests", "cache_hits", "actual_input_tokens", "actual_output_tokens")
    known = {
        key: raw[key]
        for key in integer_fields
        if type(raw.get(key)) is int and raw[key] >= 0
    }
    cost = raw.get("optimizer_cost_usd")
    if type(cost) in (int, float) and not isinstance(cost, bool) and math.isfinite(cost) and cost >= 0:
        known["optimizer_cost_usd"] = cost
    fields = set(integer_fields) | {"optimizer_cost_usd"}
    return known, sorted(fields - set(known))


def run(args, transport=None):
    cases = chosen(args)
    mode = "live" if args.live else "offline"
    plan = {
        "mode": mode,
        "planned_optimizer_calls": len(cases),
        "planned_protocol_requests": len(cases) + 2 if args.live else 0,
        "repetitions": args.repetitions,
        "max_calls": args.max_calls,
        "call_timeout_seconds": args.timeout,
        "initialize_timeout_seconds": args.initialize_timeout,
        "will_launch_keys": bool(args.live and not args.dry_run),
    }
    if args.dry_run:
        return {"schema_version": 3, "benchmark": "optimizer_structural", "dry_run": True, "plan": plan}

    outputs = []
    if args.live:
        client = MCPClient(transport)
        try:
            available = {item.get("name") for item in client.initialize().get("tools", [])}
            for case in cases:
                if case["tool"] not in available:
                    raise RuntimeError("required_tool_unavailable")
                started = time.monotonic()
                body = extract(client.call(case["tool"], case["args"]))
                outputs.append({"result": body, "latency_ms": (time.monotonic() - started) * 1000})
        finally:
            transport.close()
    else:
        outputs = offline(cases)

    results = []
    for index, (case, item) in enumerate(zip(cases, outputs), 1):
        if item.get("case_id") not in (None, case["id"]) or not isinstance(item.get("result"), dict):
            raise RuntimeError("invalid_offline_engine_response")
        body = item["result"]
        numeric, unknown = usage(body)
        expected = case["expected"]
        results.append(
            {
                "sequence": index,
                "case_id": case["id"],
                "kind": case["kind"],
                "expected": expected,
                "actual": {key: body.get(key) for key in expected},
                "correct": all(body.get(key) == value for key, value in expected.items()),
                "abstained": body.get("status") == "abstained",
                "latency_ms": item["latency_ms"],
                "usage": numeric,
                "usage_unknown_fields": unknown,
            }
        )
    costs = [item["usage"]["optimizer_cost_usd"] for item in results if "optimizer_cost_usd" in item["usage"]]
    correct = sum(item["correct"] for item in results)
    cost_label = "synthetic_mock_cost_usd" if mode == "offline" else "provider_reported_cost_usd"
    return {
        "schema_version": 3,
        "benchmark": "optimizer_structural",
        "mode": mode,
        "usage_source": "synthetic_mock" if mode == "offline" else "provider_reported",
        "interpretation": "production-engine structural fixtures; not general model quality or savings",
        "plan": plan,
        "summary": {
            "cases_run": len(results),
            "correct": correct,
            "accuracy": correct / len(results) if results else None,
            "abstentions": sum(item["abstained"] for item in results),
            cost_label: sum(costs) if costs else None,
            "cost_known_cases": len(costs),
            "cost_unknown_cases": len(results) - len(costs),
            "baseline_savings": None,
            "net_savings": None,
            "human_quality": None,
        },
        "results": results,
    }


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--live", action="store_true")
    result.add_argument("--project")
    result.add_argument("--jev-key")
    result.add_argument("--keys", default="keys")
    result.add_argument("--minutes", type=int, default=5)
    result.add_argument("--repetitions", type=int, default=1)
    result.add_argument("--max-calls", type=int, default=5)
    result.add_argument("--timeout", type=float, default=40)
    result.add_argument("--initialize-timeout", type=float, default=120)
    result.add_argument("--dry-run", action="store_true")
    result.add_argument("--report", type=Path)
    return result


def main(argv=None):
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if not 1 <= args.repetitions <= 20 or not 1 <= args.max_calls <= 100:
        argument_parser.error("repetitions must be 1-20 and max-calls 1-100")
    if not 1 <= args.minutes <= 120:
        argument_parser.error("minutes must be 1-120")
    if not 0 < args.timeout <= 40 or not 1 <= args.initialize_timeout <= 120:
        argument_parser.error("timeout must be <=40 and initialize-timeout <=120")
    if args.live:
        try:
            uuid.UUID(args.project or "")
        except ValueError:
            argument_parser.error("--live requires --project UUID")
        if not args.jev_key:
            argument_parser.error("--live requires --jev-key")
    elif args.project or args.jev_key:
        argument_parser.error("project and jev-key require --live")

    transport = None
    if args.live and not args.dry_run:
        command = [
            args.keys,
            "optimizer",
            "mcp",
            "--project",
            args.project,
            "--minutes",
            str(args.minutes),
            "--jev-key",
            args.jev_key,
        ]
        transport = StdioTransport(command, args.timeout, args.initialize_timeout)
    report = run(args, transport)
    encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.report:
        args.report.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
