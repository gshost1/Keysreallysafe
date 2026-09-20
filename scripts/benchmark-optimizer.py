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
ENGINE_BUILD = ROOT / "Plugins" / "jev-optimizer" / "dist" / "index.js"
BUILD_HINT = "Compiled optimizer engine not found. Build it first: cd Plugins/jev-optimizer && npm ci && npm run build"


class MissingEngineBuild(RuntimeError):
    pass


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
        "threshold": 0.9,  # the value Keys sets for live evaluations (OptimizerAPI.swift)
        "optimizer_cost_usd": 0.001,
    },
}


def tool_case(case_id, kind, candidate, expected_reason):
    arguments = {"request_text": "read parser source", "candidates": [candidate]}
    return {
        "id": case_id,
        "kind": kind,
        "fallback": {"selected_ids": []},
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
        "fallback": {},
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
        "fallback": {"selected_id": "large"},
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


# Opt-in, one call. The default cases are terse on purpose (three-word request, a
# description that repeats it); this one resembles what a client really sends so a
# live run can show whether an abstention follows the input or the protocol.
REALISTIC_TOOLS = [
    {"id": "Read", "name": "Read", "description": "Reads a file from the local filesystem and returns its contents with line numbers."},
    {"id": "Grep", "name": "Grep", "description": "Searches file contents in the project with a regular expression."},
    {"id": "Deploy", "name": "Deploy", "description": "Deploys the current build to the production environment."},
]
REALISTIC_ARGS = {
    "request_text": "Open src/parser.ts and show me the tokenizer function so I can see how it handles escaped quotes. Do not change anything.",
    "candidates": REALISTIC_TOOLS,
}
REALISTIC_CASES = (
    {
        "id": "tools_realistic_read",
        "kind": "semantic",
        "tool": "keys_tools_select",
        "fallback": {"selected_ids": []},
        "expected": {"reason": "tool_candidates_ranked"},
        "expected_includes": {"selected_ids": ["Read"]},
        "expected_excludes": {"selected_ids": ["Deploy"]},
        "args": REALISTIC_ARGS,
        "engine": {"command": "select_tools", **REALISTIC_ARGS},
        "mock": {"unsuitable_ids": ["Deploy"]},
    },
)
SUITES = {"structural": CASES, "realistic": REALISTIC_CASES, "all": CASES + REALISTIC_CASES}

STRUCTURAL_KINDS = {"stale", "expired", "duplicate"}
# Abstentions with these reasons never received an evaluator judgment.
UNAVAILABLE_REASONS = {
    "provider_unavailable", "evaluation_failed", "invalid_evaluation", "engine_unavailable", "circuit_open",
    "budget_exhausted", "jev_not_authorized", "provider_disabled", "project_disabled", "project_off",
    "feature_disabled", "policy_expired", "input_limit", "evaluation_unavailable",
}


def category(kind):
    return "structural" if kind in STRUCTURAL_KINDS else "semantic"


def conservative(actual, fallback):
    """True when an abstention kept the do-nothing default (full catalog / current model)."""
    if not isinstance(fallback, dict):
        return False
    return all(actual.get(key) == value for key, value in fallback.items())


def classify(item, fallback):
    """Separate label misses that changed nothing from ones that acted wrongly.

    match            the labelled outcome
    safe_abstention  semantic label missed; the engine abstained and kept the default
    safe_mismatch    structural label missed, yet nothing was selected or switched
    unsafe_error     a selection the label did not allow, or an abstention that still moved the default
    """
    if item.get("correct") is True:
        return "match"
    actual = item.get("actual") if isinstance(item.get("actual"), dict) else {}
    if item.get("abstained") is True and conservative(actual, fallback):
        return "safe_abstention" if category(item.get("kind")) == "semantic" else "safe_mismatch"
    return "unsafe_error"


def abstention_cause(item, evidence):
    if item.get("abstained") is not True:
        return None
    actual = item.get("actual") if isinstance(item.get("actual"), dict) else {}
    if actual.get("reason") in UNAVAILABLE_REASONS:
        return "evaluator_unavailable"
    if evidence:
        return evidence["outcome"]
    usage_row = item.get("usage") if isinstance(item.get("usage"), dict) else {}
    if usage_row.get("requests") or usage_row.get("cache_hits"):
        # Engines before decision_evidence answered but did not say which score fell short.
        return "evaluator_declined_scores_not_reported"
    return "rejected_before_evaluation"


def decision_evidence(body):
    raw = body.get("decision_evidence")
    if not isinstance(raw, dict):
        return None

    def probability(value):
        return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1

    rows = raw.get("candidates")
    if not (probability(raw.get("threshold")) and probability(raw.get("none_fit")) and isinstance(rows, list)
            and isinstance(raw.get("outcome"), str) and len(rows) <= 64
            and all(isinstance(row, dict) and probability(row.get("suitable")) and probability(row.get("conflict")) for row in rows)):
        return None
    # Candidate ids are caller data; keep positions and numbers only.
    return {
        "threshold": raw["threshold"],
        "none_fit": raw["none_fit"],
        "outcome": raw["outcome"][:64],
        "scores": [{"index": index, "suitable": row["suitable"], "conflict": row["conflict"]} for index, row in enumerate(rows)],
    }


def label_correct(case, body):
    if not all(body.get(key) == value for key, value in case["expected"].items()):
        return False
    for key, values in case.get("expected_includes", {}).items():
        if not isinstance(body.get(key), list) or any(value not in body[key] for value in values):
            return False
    for key, values in case.get("expected_excludes", {}).items():
        if not isinstance(body.get(key), list) or any(value in body[key] for value in values):
            return False
    return True


def summarize(results):
    """Schema 4 breakdown. Counts only; none of it is routing accuracy or savings."""
    def bucket(name):
        rows = [item for item in results if item["category"] == name]
        return {
            "cases": len(rows),
            "matched": sum(item["outcome"] == "match" for item in rows),
            "safe_abstentions": sum(item["outcome"] == "safe_abstention" for item in rows),
            "safe_mismatches": sum(item["outcome"] == "safe_mismatch" for item in rows),
            "unsafe_errors": sum(item["outcome"] == "unsafe_error" for item in rows),
        }

    thresholds = sorted({item["decision_evidence"]["threshold"] for item in results if item.get("decision_evidence")})
    return {
        "structural": bucket("structural"),
        "semantic": bucket("semantic"),
        "unsafe_errors": sum(item["outcome"] == "unsafe_error" for item in results),
        "safe_abstentions": sum(item["outcome"] == "safe_abstention" for item in results),
        "safe_mismatches": sum(item["outcome"] == "safe_mismatch" for item in results),
        "observed_thresholds": thresholds,
        "accuracy_note": "accuracy is the label match rate over these fixtures only; a semantic miss "
                         "classified safe_abstention changed nothing. Not routing accuracy or savings.",
    }


def reclassify(report):
    """Add the schema 4 outcome view to an existing report (schema 3 or 4) without running anything."""
    if not isinstance(report, dict) or not isinstance(report.get("results"), list) or not isinstance(report.get("summary"), dict):
        raise ValueError("not_a_benchmark_report")
    fallbacks = {case["id"]: case["fallback"] for case in SUITES["all"]}
    results = []
    for item in report["results"]:
        if not isinstance(item, dict) or not isinstance(item.get("kind"), str):
            raise ValueError("not_a_benchmark_report")
        evidence = item.get("decision_evidence") if isinstance(item.get("decision_evidence"), dict) else None
        # An unknown case id has no known default, so a miss there is never called safe.
        row = {**item, "category": category(item["kind"]), "outcome": classify(item, fallbacks.get(item.get("case_id")))}
        row["abstention_cause"] = abstention_cause(item, evidence)
        row.setdefault("decision_evidence", None)
        results.append(row)
    return {
        **report,
        "schema_version": 4,
        "reclassified_from_schema_version": report.get("schema_version"),
        "summary": {**report["summary"], **summarize(results)},
        "results": results,
    }


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
    cases = SUITES[getattr(args, "suite", "structural")]
    return [case for _ in range(args.repetitions) for case in cases][: args.max_calls]


def offline(cases):
    # dist/ is a build product and absent from a fresh checkout.
    if not ENGINE_BUILD.is_file():
        raise MissingEngineBuild(BUILD_HINT)
    payload = [{"case_id": case["id"], "input": {**BASE, **case["engine"]}, "mock": case.get("mock", {})} for case in cases]
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
        return {"schema_version": 4, "benchmark": "optimizer_structural", "dry_run": True, "plan": plan}

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
        fields = [*expected, *case.get("expected_includes", {}), *case["fallback"]]
        row = {
            "sequence": index,
            "case_id": case["id"],
            "kind": case["kind"],
            "category": category(case["kind"]),
            "expected": {
                **expected,
                **{f"{key}_include": value for key, value in case.get("expected_includes", {}).items()},
                **{f"{key}_exclude": value for key, value in case.get("expected_excludes", {}).items()},
            },
            "actual": {key: body.get(key) for key in dict.fromkeys(fields)},
            "correct": label_correct(case, body),
            "abstained": body.get("status") == "abstained",
            "latency_ms": item["latency_ms"],
            "usage": numeric,
            "usage_unknown_fields": unknown,
        }
        evidence = decision_evidence(body)
        row["outcome"] = classify(row, case["fallback"])
        row["abstention_cause"] = abstention_cause(row, evidence)
        row["decision_evidence"] = evidence
        results.append(row)
    costs = [item["usage"]["optimizer_cost_usd"] for item in results if "optimizer_cost_usd" in item["usage"]]
    correct = sum(item["correct"] for item in results)
    cost_label = "synthetic_mock_cost_usd" if mode == "offline" else "provider_reported_cost_usd"
    return {
        "schema_version": 4,
        "benchmark": "optimizer_structural",
        "suite": getattr(args, "suite", "structural"),
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
            **summarize(results),
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
    result.add_argument("--suite", choices=sorted(SUITES), default="structural",
                        help="realistic adds one opt-in tool-selection call with client-like input")
    result.add_argument("--reclassify", type=Path, metavar="REPORT",
                        help="print the schema 4 outcome view of an existing report; runs nothing")
    return result


def main(argv=None):
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if args.reclassify:
        if args.live or args.dry_run:
            argument_parser.error("--reclassify reads a report and cannot be combined with --live or --dry-run")
        try:
            report = reclassify(json.loads(args.reclassify.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            print("not a readable optimizer benchmark report", file=sys.stderr)
            return 2
        encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
        if args.report:
            args.report.write_text(encoded, encoding="utf-8")
        sys.stdout.write(encoded)
        return 0
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
    try:
        report = run(args, transport)
    except MissingEngineBuild as error:
        print(str(error), file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.report:
        args.report.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
