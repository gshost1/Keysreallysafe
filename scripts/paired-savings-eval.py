#!/usr/bin/env python3
"""Paired savings evaluation for the Keys Optimizer. Local arithmetic only.

Compares a baseline arm (optimizer off) with a treatment arm (optimizer on) of the
same task, context and client model. It never launches a model, a provider request,
Keys, or a presence prompt: arm usage comes from records you supply, normally the
per-task accounting in a saved `keys_optimizer_status` result. A number that was not
reported stays unknown; estimates are shown beside measurements, never inside them.

  plan     print the two-arm run sheet for a task list and what each arm must record
  collect  build pair records from a manifest plus a saved keys_optimizer_status result
  report   compute paired deltas from pair records
"""

import argparse
import json
import math
from pathlib import Path
import statistics
import sys

SCHEMA = 1
MAX_FILE = 2_000_000
MAX_PAIRS = 200
USAGE_FIELDS = ("input_tokens", "output_tokens", "reported_cost_usd")
INTERPRETATION = (
    "Paired deltas over the supplied records only. Not a general savings rate, not routing accuracy; "
    "cache-replay pairs are reported apart and say nothing about new tasks."
)


class InputError(Exception):
    pass


def load(path):
    try:
        raw = Path(path).read_bytes()
    except OSError:
        raise InputError("unreadable_file") from None
    if len(raw) > MAX_FILE:
        raise InputError("file_too_large")
    try:
        return json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError, RecursionError):
        raise InputError("invalid_json") from None


def count(value):
    return value if type(value) is int and 0 <= value <= 1_000_000_000_000 else None


def money(value):
    return value if type(value) in (int, float) and 0 <= value <= 1_000_000_000_000 and math.isfinite(value) else None


def known_usage(raw):
    """Strictly valid numbers only; everything else is unknown, not zero."""
    raw = raw if isinstance(raw, dict) else {}
    return {
        "input_tokens": count(raw.get("input_tokens")),
        "output_tokens": count(raw.get("output_tokens")),
        "cache_read_tokens": count(raw.get("cache_read_tokens")),
        "reported_cost_usd": money(raw.get("reported_cost_usd")),
    }


def extra_cost(raw):
    """Cache rebuild / fallback: must be stated. Absent means unknown, not free."""
    if not isinstance(raw, dict) or type(raw.get("occurred")) is not bool:
        return {"stated": False, "occurred": None, **known_usage({})}
    if raw["occurred"] is False or raw.get("included_in_client_usage") is True:
        zero = {"input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0, "reported_cost_usd": 0}
        return {"stated": True, "occurred": raw["occurred"], **zero}
    return {"stated": True, "occurred": True, **known_usage(raw)}


def quality(arm):
    checks = arm.get("checks") if isinstance(arm.get("checks"), list) else []
    valid = [item for item in checks if isinstance(item, dict) and isinstance(item.get("name"), str) and type(item.get("passed")) is bool]
    if not valid or len(valid) != len(checks):
        return {"checks": len(valid), "passed": None}
    return {"checks": len(valid), "passed": all(item["passed"] for item in valid)}


def add(*values):
    return None if any(value is None for value in values) else sum(values)


def evaluate_pair(pair):
    baseline = pair.get("baseline") if isinstance(pair.get("baseline"), dict) else {}
    treatment = pair.get("treatment") if isinstance(pair.get("treatment"), dict) else {}
    row = {"pair_id": str(pair.get("pair_id", ""))[:128], "cache_replay": treatment.get("cache_replay") is True}

    mismatched = [field for field in ("task_fingerprint", "context_fingerprint", "model")
                  if not isinstance(baseline.get(field), str) or not baseline.get(field) or baseline.get(field) != treatment.get(field)]
    def check_names(arm):
        checks = arm.get("checks")
        if not isinstance(checks, list) or not checks:
            return None
        names = [item.get("name") for item in checks if isinstance(item, dict)]
        if (len(names) != len(checks) or any(not isinstance(name, str) or not name.strip() for name in names)
                or len(set(names)) != len(names)):
            return None
        return set(names)
    names = check_names(baseline)
    if names is None or names != check_names(treatment):
        mismatched.append("quality_check_set")
    # An "optimizer off" arm that still recorded optimizer events is not a baseline.
    if baseline.get("contaminated_by_optimizer_events") is True:
        mismatched.append("baseline_has_optimizer_events")
    row["comparable"] = not mismatched
    row["not_comparable_fields"] = mismatched

    base_quality, treat_quality = quality(baseline), quality(treatment)
    row["quality"] = {"baseline": base_quality, "treatment": treat_quality}
    if base_quality["passed"] is None or treat_quality["passed"] is None:
        row["quality_verdict"] = "unknown"
    elif base_quality["passed"] and not treat_quality["passed"]:
        row["quality_verdict"] = "regression"
    elif not base_quality["passed"]:
        row["quality_verdict"] = "baseline_failed"
    else:
        row["quality_verdict"] = "held"

    base = known_usage(baseline.get("provider_usage"))
    client = known_usage(treatment.get("provider_usage"))
    overhead = known_usage(treatment.get("optimizer_usage"))
    rebuild = extra_cost(treatment.get("cache_rebuild"))
    fallback = extra_cost(treatment.get("fallback"))
    row["usage"] = {"baseline": base, "treatment_client": client, "optimizer_overhead": overhead,
                    "cache_rebuild": rebuild, "fallback": fallback}

    unknown = []
    for label, source in (("baseline", base), ("treatment_client", client), ("optimizer_overhead", overhead),
                          ("cache_rebuild", rebuild), ("fallback", fallback)):
        unknown += [f"{label}.{field}" for field in USAGE_FIELDS if source[field] is None]
    row["unknown_fields"] = unknown

    def net(field):
        treatment_total = add(client[field], overhead[field], rebuild[field], fallback[field])
        return None if treatment_total is None or base[field] is None else base[field] - treatment_total

    token_parts = [net("input_tokens"), net("output_tokens")]
    row["net_token_savings"] = add(*token_parts)
    row["net_reported_cost_savings_usd"] = net("reported_cost_usd")
    gross = add(base["input_tokens"], base["output_tokens"])
    gross_treatment = add(client["input_tokens"], client["output_tokens"])
    row["gross_client_token_savings_before_overhead"] = None if gross is None or gross_treatment is None else gross - gross_treatment

    # Byte estimates never enter a saving; they only show how far an estimate sits from the receipt.
    estimates = {}
    for label, arm, usage_row in (("baseline", baseline, base), ("treatment", treatment, client)):
        size = count(arm.get("estimated_input_bytes"))
        estimates[label] = {
            "estimated_input_bytes": size,
            "estimated_input_tokens_at_4_bytes": None if size is None else math.ceil(size / 4),
            "provider_input_tokens": usage_row["input_tokens"],
        }
    row["estimate_vs_provider"] = estimates

    row["counts_toward_measured_savings"] = bool(
        row["comparable"] and row["quality_verdict"] == "held" and not row["cache_replay"] and row["net_token_savings"] is not None)
    return row


def total(rows, field):
    values = [row[field] for row in rows if row[field] is not None]
    return {"pairs_known": len(values), "pairs_unknown": len(rows) - len(values),
            "sum_of_known": sum(values) if values else None,
            "median_of_known": statistics.median(values) if values else None,
            "pairs_where_treatment_used_more": sum(value < 0 for value in values)}


def report(document):
    pairs = document.get("pairs") if isinstance(document, dict) else None
    if not isinstance(pairs, list) or not all(isinstance(pair, dict) for pair in pairs):
        raise InputError("pairs_must_be_a_list_of_objects")
    if len(pairs) > MAX_PAIRS:
        raise InputError("too_many_pairs")
    rows = [evaluate_pair(pair) for pair in pairs]
    eligible = [row for row in rows if row["comparable"] and row["quality_verdict"] == "held" and not row["cache_replay"]]
    replay = [row for row in rows if row["comparable"] and row["cache_replay"]]
    verdicts = {name: sum(row["quality_verdict"] == name for row in rows) for name in ("held", "regression", "baseline_failed", "unknown")}
    return {
        "schema_version": SCHEMA,
        "evaluation": "optimizer_paired_savings",
        "interpretation": INTERPRETATION,
        "summary": {
            "pairs": len(rows),
            "comparable_pairs": sum(row["comparable"] for row in rows),
            "quality": verdicts,
            "general_task_pairs": {
                "eligible": len(eligible),
                "net_token_savings": total(eligible, "net_token_savings"),
                "net_reported_cost_savings_usd": total(eligible, "net_reported_cost_savings_usd"),
            },
            "cache_replay_pairs": {
                "pairs": len(replay),
                "net_token_savings": total(replay, "net_token_savings"),
                "note": "An exact repeat answered from the decision cache. Not evidence about new tasks.",
            },
            "pairs_with_unknown_fields": sum(bool(row["unknown_fields"]) for row in rows),
            "measured_savings_claim": None if not any(row["counts_toward_measured_savings"] for row in rows) else "see general_task_pairs; sample-bound",
        },
        "pairs": rows,
    }


ARM_REQUIREMENTS = {
    "both_arms": [
        "same task_fingerprint, context_fingerprint (hash of the starting context) and client model",
        "a fresh client session per arm so neither inherits the other's prompt cache",
        "provider-reported input/output tokens and cost recorded with keys_usage_record against the arm's own Keys task",
        "the same named checks (tests, linters, reviewer verdict) with pass/fail",
    ],
    "baseline": ["project mode off, or a client started without the Keys optimizer MCP server"],
    "treatment": [
        "optimizer overhead: recorded automatically on the task by Keys (optimizer events)",
        "cache_rebuild and fallback: state occurred true/false; give tokens and cost, or included_in_client_usage",
        "mark cache_replay true when the arm repeats an earlier identical request",
    ],
}


def plan(document):
    tasks = document.get("tasks") if isinstance(document, dict) else None
    if not isinstance(tasks, list) or not tasks or len(tasks) > MAX_PAIRS:
        raise InputError("tasks_must_be_a_bounded_list")
    sheet = []
    for index, task in enumerate(tasks, 1):
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not task["id"]:
            raise InputError("task_needs_id")
        checks = [name for name in task.get("checks", []) if isinstance(name, str)]
        sheet.append({"pair_id": task["id"][:128], "order": ["baseline", "treatment"] if index % 2 else ["treatment", "baseline"],
                      "checks": checks, "checks_missing": not checks})
    return {
        "schema_version": SCHEMA, "evaluation": "optimizer_paired_savings", "dry_run": True,
        "will_launch": {"models": False, "provider_requests": False, "keys": False, "presence_prompt": False},
        "unavailable_from_this_harness": [
            "running either arm: no client or paid model is launched here",
            "baseline usage for a task that was only ever run with the optimizer on",
            "cost for providers that report none (stays unknown)",
        ],
        "arm_requirements": ARM_REQUIREMENTS,
        "run_sheet": sheet,
        "next": "Run both arms, save keys_optimizer_status to a file, then: collect --manifest MANIFEST --status STATUS",
    }


def ledger_usage(group):
    """A known total is only complete when no event left that number unknown."""
    group = group if isinstance(group, dict) else {}
    if count(group.get("events")) in (None, 0):
        return {}
    out = {}
    for field in ("input_tokens", "output_tokens", "cache_read_tokens", "reported_cost_usd"):
        if count(group.get(f"{field}_unknown_events")) == 0:
            out[field] = group.get(f"{field}_known")
    return out


def collect(manifest, status):
    pairs = manifest.get("pairs") if isinstance(manifest, dict) else None
    tasks = status.get("tasks") if isinstance(status, dict) else None
    if not isinstance(pairs, list) or len(pairs) > MAX_PAIRS or not isinstance(tasks, list):
        raise InputError("manifest_pairs_and_status_tasks_required")
    by_id = {task.get("id") or task.get("task_id"): task for task in tasks if isinstance(task, dict)}
    out = []
    for pair in pairs:
        if not isinstance(pair, dict):
            raise InputError("invalid_pair")
        record = {"pair_id": pair.get("pair_id")}
        for arm_name in ("baseline", "treatment"):
            arm = dict(pair.get(arm_name)) if isinstance(pair.get(arm_name), dict) else {}
            aggregate = (by_id.get(arm.get("task_id")) or {}).get("aggregate")
            aggregate = aggregate if isinstance(aggregate, dict) else {}
            arm["provider_usage"] = ledger_usage(aggregate.get("client"))
            optimizer = aggregate.get("optimizer") if isinstance(aggregate.get("optimizer"), dict) else {}
            if arm_name == "treatment":
                # A treatment task with no optimizer events has zero overhead only if the task itself was found.
                events = count(optimizer.get("events"))
                arm["optimizer_usage"] = (
                    {"input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0, "reported_cost_usd": 0}
                    if events == 0 else ledger_usage(optimizer))
            elif count(optimizer.get("events")):
                arm["contaminated_by_optimizer_events"] = True
            record[arm_name] = arm
        out.append(record)
    return {"schema_version": SCHEMA, "pairs": out}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    item = commands.add_parser("plan")
    item.add_argument("--tasks", required=True, type=Path)
    item = commands.add_parser("collect")
    item.add_argument("--manifest", required=True, type=Path)
    item.add_argument("--status", required=True, type=Path)
    item = commands.add_parser("report")
    item.add_argument("--pairs", required=True, type=Path)
    for item in commands.choices.values():
        item.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            result = plan(load(args.tasks))
        elif args.command == "collect":
            result = collect(load(args.manifest), load(args.status))
        else:
            result = report(load(args.pairs))
    except InputError as error:
        print(str(error), file=sys.stderr)
        return 2
    encoded = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.out:
        args.out.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
