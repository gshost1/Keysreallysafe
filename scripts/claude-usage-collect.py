#!/usr/bin/env python3
"""Local usage collection for Claude Code JSONL logs. Arithmetic and metadata only.

Reads `--output-format stream-json` transcripts and `~/.claude/projects/*/*.jsonl`
session transcripts and reports, per session and per model, the provider-reported
input / output / cache-read / cache-creation counts, compaction evidence and
fallback status. It launches nothing, contacts no provider, and never copies
prompt, message or tool content into its output: only names, counts, digests kept
in memory, and numbers taken from the log schema.

The two counting hazards this tool exists to avoid, both confirmed against real
logs (see `docs/overnight-usage-results.md`):

  * One assistant turn is written once per content block. Every copy carries the
    same `message.usage`, so summing the records multiplies the turn's usage by
    the number of blocks. Records are deduplicated per API request.
  * A `result` event's `usage` is that turn's own increment, while its
    `modelUsage` and `total_cost_usd` are cumulative for the session so far.
    Summing `modelUsage` over the results of one session double counts; the
    final cumulative value is used instead, and the naive sum is shown only as
    the error that was avoided.
  * Those cumulative counters belong to one counter epoch, not to the session
    id. A restarted run restarts them and restarts `result_index` with them, so
    each epoch contributes its own final cumulative value and the session total
    is the sum over epochs. Taking only the last result would drop the
    interrupted run whenever the resumed one happened to count higher. An epoch
    is inferred from the records, not an observed operating system process: a
    resumed native session that kept counting is one epoch and is charged once.
  * Where no `result_index` is written and the counters did not fall, the two
    readings — one continuing epoch, or a fresh counter — are indistinguishable.
    The total is then not identified: the cost is reported unknown, both
    readings are published, and the accounting gate fails rather than passing
    off the smaller reading as verified.
  * A result does not end the session, and a success does not end it either.
    Completeness is read from the recorded order of events: work after the last
    result, or a segment the client has opened and not finished — with or
    without a record in it yet — is real work no cumulative counter has
    reported, kept as a separate partial observation with the session not called
    complete.

`usage` also covers the main model alone, so background models are visible only
in `modelUsage`; both views are reported and reconciled against each other.

  report  per-session and per-model usage, compaction, fallback and tool repeats
  check   the same run, exiting non-zero when a quality gate fails

Costs are list-price estimates published by the client, never billed dollars, and
a repeated identical tool call is a structural observation, not a measured
saving; net matched-pair savings stay with `scripts/paired-savings-eval.py`.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys

SCHEMA = 1
MAX_FILES = 500
MAX_FILE_BYTES = 64_000_000
MAX_LINE_BYTES = 8_000_000
MAX_RECORDS = 2_000_000
MAX_COMPACTIONS = 500
MAX_TOP_TOOLS = 25

TOKEN_FIELDS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
MODEL_USAGE_FIELDS = {
    "inputTokens": "input_tokens",
    "outputTokens": "output_tokens",
    "cacheReadInputTokens": "cache_read_input_tokens",
    "cacheCreationInputTokens": "cache_creation_input_tokens",
}

INTERPRETATION = (
    "Provider-reported counts for the supplied local logs only. Cost is the client's list-price "
    "estimate, not a billed amount. Repeated identical tool calls are a structural observation, not "
    "a measured saving; net matched-pair savings require scripts/paired-savings-eval.py."
)


class InputError(Exception):
    pass


def count(value):
    """Strictly valid non-negative integers only; anything else is unknown, not zero."""
    return value if type(value) is int and 0 <= value <= 1_000_000_000_000 else None


def money(value):
    """NaN and infinity fail every comparison below, so they stay unknown."""
    if type(value) is bool or type(value) not in (int, float):
        return None
    return float(value) if 0 <= value <= 1_000_000_000 else None


def text(value, limit=200):
    """Schema-level identifiers and enum labels only. Never message or tool content."""
    return value[:limit] if isinstance(value, str) and value else None


def add(*values):
    """None is unknown and poisons the sum, so a partial total never looks complete."""
    total = 0
    for value in values:
        if value is None:
            return None
        total += value
    return total


def zero_tokens():
    return {field: 0 for field in TOKEN_FIELDS}


def accumulate(target, source):
    for field in TOKEN_FIELDS:
        target[field] = add(target.get(field), source.get(field))


def tokens_from_usage(raw):
    """The top-level usage of one API response. `iterations` is a breakdown of this
    same total, so it is counted only as evidence that the turn had several."""
    raw = raw if isinstance(raw, dict) else {}
    creation = raw.get("cache_creation") if isinstance(raw.get("cache_creation"), dict) else {}
    details = raw.get("output_tokens_details") if isinstance(raw.get("output_tokens_details"), dict) else {}
    iterations = raw.get("iterations") if isinstance(raw.get("iterations"), list) else []
    return {
        "input_tokens": count(raw.get("input_tokens")),
        "output_tokens": count(raw.get("output_tokens")),
        "cache_read_input_tokens": count(raw.get("cache_read_input_tokens")),
        "cache_creation_input_tokens": count(raw.get("cache_creation_input_tokens")),
        "thinking_tokens": count(details.get("thinking_tokens")),
        "ephemeral_5m_cache_creation_tokens": count(creation.get("ephemeral_5m_input_tokens")),
        "ephemeral_1h_cache_creation_tokens": count(creation.get("ephemeral_1h_input_tokens")),
        "iterations": len(iterations),
        "service_tier": text(raw.get("service_tier"), 40),
    }


def tokens_from_model_usage(raw):
    raw = raw if isinstance(raw, dict) else {}
    out = {target: count(raw.get(source)) for source, target in MODEL_USAGE_FIELDS.items()}
    out["thinking_tokens"] = count(raw.get("thinkingTokens"))
    out["list_price_estimate_usd"] = money(raw.get("costUSD"))
    out["cost_basis"] = text(raw.get("costBasis"), 40)
    out["provider"] = text(raw.get("provider"), 40)
    out["context_window"] = count(raw.get("contextWindow"))
    return out


def canonical_digest(*parts):
    """A local digest of a tool call, so exact repeats can be counted without
    keeping, printing or transmitting the call itself."""
    digest = hashlib.sha256()
    for part in parts:
        digest.update(json.dumps(part, sort_keys=True, default=str).encode("utf-8", "replace"))
        digest.update(b"\x00")
    return digest.hexdigest()


class Session:
    def __init__(self, session_id):
        self.session_id = session_id
        self.files = []
        self.version = None
        self.requested_model = None
        self.permission_mode = None
        self.plugins = []
        self.init_events = 0
        self.init_uuids = set()
        self.replayed_init_records = 0
        self.segment = 0
        self.order = 0
        self.requests = {}
        self.duplicate_block_records = 0
        self.conflicting_duplicate_usage = 0
        self.results = {}
        self.results_identified_by_content = 0
        self.permission_denied_events = {}
        self.permission_denied_events_without_tool_use_id = 0
        self.compactions = []
        self.compactions_dropped = 0
        self.rate_limit_statuses = {}
        self.rate_limit_overage = 0
        self.tool_calls = {}
        self.tool_signatures = {}
        self.seen_tool_blocks = set()
        self.tool_exact_repeats = 0
        self.plugin_fallback_markers = 0
        self.hook_records = 0
        self.hook_errors = 0
        self.estimated_thinking_tokens = None

    def touch_file(self, name):
        if name not in self.files:
            self.files.append(name)


def merge_init(session, record):
    # An init opens a segment. The client writes one per prompt in stream-json
    # input mode and one per restart, so a segment is a boundary, not a session.
    # The same init reaches us twice when a stream log and the session transcript
    # are read together; a replay must not open a second segment.
    uuid = text(record.get("uuid"), 80)
    if uuid is not None:
        if uuid in session.init_uuids:
            session.replayed_init_records += 1
            return
        session.init_uuids.add(uuid)
    session.init_events += 1
    session.segment = session.init_events
    session.version = session.version or text(record.get("claude_code_version"), 40)
    session.requested_model = session.requested_model or text(record.get("model"), 80)
    session.permission_mode = session.permission_mode or text(record.get("permissionMode"), 40)
    for plugin in record.get("plugins") or []:
        name = text(plugin.get("name"), 80) if isinstance(plugin, dict) else None
        if name and name not in session.plugins:
            session.plugins.append(name)


def merge_assistant(session, record):
    """One key per API request. Content-block copies of the same request carry the
    same usage and must not be added a second time."""
    message = record.get("message") if isinstance(record.get("message"), dict) else {}
    request_id = text(record.get("request_id") or record.get("requestId"), 80)
    message_id = text(message.get("id"), 80)
    key = (request_id, message_id) if (request_id or message_id) else ("uuid", text(record.get("uuid"), 80))
    usage = tokens_from_usage(message.get("usage"))
    entry = {
        "model": text(message.get("model"), 80),
        "effort": text(record.get("effort"), 40),
        "usage": usage,
        "segment": session.segment,
        # How many results the session had already reported when this request was
        # recorded: a request that follows them all is work no result covers yet.
        "results_recorded_before": len(session.results),
    }
    for index, block in enumerate(message.get("content") or []):
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        # The same turn is written once per block, and the same turn may reach us
        # from both a stream transcript and a session transcript. The tool_use id
        # identifies the call itself, so neither shape counts it twice.
        identity = text(block.get("id"), 80) or f"{key}:{index}"
        if identity in session.seen_tool_blocks:
            continue
        session.seen_tool_blocks.add(identity)
        name = text(block.get("name"), 80) or "unnamed"
        session.tool_calls[name] = session.tool_calls.get(name, 0) + 1
        signature = canonical_digest(name, block.get("input"))
        seen = session.tool_signatures.get(signature, 0)
        session.tool_signatures[signature] = seen + 1
        if seen:
            session.tool_exact_repeats += 1

    existing = session.requests.get(key)
    if existing is None:
        session.requests[key] = entry
        return
    session.duplicate_block_records += 1
    if existing["usage"] != usage:
        session.conflicting_duplicate_usage += 1
        # Keep the larger report: a truncated duplicate must not shrink a known total.
        if (add(*[usage.get(field) or 0 for field in TOKEN_FIELDS]) or 0) > (
                add(*[existing["usage"].get(field) or 0 for field in TOKEN_FIELDS]) or 0):
            existing["usage"] = usage


def result_identity(session, record):
    """The uuid identifies a result. Without one the record's own reported numbers
    are the identity: a replay, from a second file or a re-read transcript, repeats
    them exactly, while a genuinely later result differs in at least its duration
    or its cumulative totals. Inferred identities are counted and reported, because
    two distinct results that agree on every number would be collapsed here."""
    uuid = text(record.get("uuid"), 80)
    if uuid is not None:
        return uuid
    session.results_identified_by_content += 1
    return "content:" + canonical_digest(
        record.get("result_index"), record.get("subtype"), record.get("num_turns"),
        record.get("duration_ms"), record.get("duration_api_ms"),
        record.get("total_cost_usd"), record.get("modelUsage"), record.get("usage"))


def merge_result(session, record):
    key = result_identity(session, record)
    if key in session.results:
        return False
    denials = record.get("permission_denials")
    denials = denials if isinstance(denials, list) else []
    model_usage = record.get("modelUsage") if isinstance(record.get("modelUsage"), dict) else {}
    session.order += 1
    session.results[key] = {
        "order": session.order,
        "segment": session.segment,
        "result_index": count(record.get("result_index")),
        "subtype": text(record.get("subtype"), 40),
        "is_error": record.get("is_error") if type(record.get("is_error")) is bool else None,
        "terminal_reason": text(record.get("terminal_reason"), 40),
        "api_error_status": record.get("api_error_status"),
        "stop_reason": text(record.get("stop_reason"), 40),
        "num_turns": count(record.get("num_turns")),
        "duration_ms": count(record.get("duration_ms")),
        "duration_api_ms": count(record.get("duration_api_ms")),
        "permission_denials": len(denials),
        # Only the identifier, never the refused tool_input the entry also carries.
        "permission_denial_ids": [text(entry.get("tool_use_id"), 80) for entry in denials
                                  if isinstance(entry, dict)],
        "subagents_spawned": count((record.get("subagent_stats") or {}).get("spawned"))
        if isinstance(record.get("subagent_stats"), dict) else None,
        "usage_increment": tokens_from_usage(record.get("usage")),
        "cumulative_model_usage": {
            text(name, 80) or "unknown": tokens_from_model_usage(value)
            for name, value in model_usage.items()
        },
        "cumulative_list_price_usd": money(record.get("total_cost_usd")),
    }
    return True


def merge_compaction(session, record):
    metadata = record.get("compact_metadata")
    shape = "stream_json"
    if not isinstance(metadata, dict):
        metadata = record.get("compactMetadata")
        shape = "session_transcript"
    metadata = metadata if isinstance(metadata, dict) else {}

    def pick(*names):
        for name in names:
            if name in metadata:
                return count(metadata.get(name))
        return None

    pre, post = pick("pre_tokens", "preTokens"), pick("post_tokens", "postTokens")
    dropped = pick("cumulative_dropped_tokens", "cumulativeDroppedTokens")
    if len(session.compactions) < MAX_COMPACTIONS:
        session.compactions.append({
            "trigger": text(metadata.get("trigger"), 40),
            "pre_tokens": pre,
            "post_tokens": post,
            "reported_cumulative_dropped_tokens": dropped,
            "duration_ms": pick("duration_ms", "durationMs"),
            "metadata_present": bool(metadata),
            "record_shape": shape,
        })
    turn_dropped = None if pre is None or post is None else pre - post
    session.compactions_dropped = add(session.compactions_dropped, turn_dropped)


PLUGIN_FALLBACK_MARKERS = ("fallback to built-in summary", "fallback to built in summary")


def merge_permission_denied(session, record):
    """`system/permission_denied` is emitted as the call is refused. The same denial
    may also be listed in a later result's `permission_denials`, so both are read
    and matched on `tool_use_id`. The event's `message` explains the refusal in
    prose and is never read; only the tool name and the decision reason label are
    kept, and an event without a `tool_use_id` cannot be matched, so it says so."""
    identity = text(record.get("tool_use_id"), 80)
    if identity is None:
        session.permission_denied_events_without_tool_use_id += 1
        identity = "event:" + (text(record.get("uuid"), 80) or str(len(session.permission_denied_events)))
    if identity in session.permission_denied_events:
        return
    session.permission_denied_events[identity] = {
        "tool_name": text(record.get("tool_name"), 80) or "unnamed",
        "decision_reason_type": text(record.get("decision_reason_type"), 40) or "unreported",
    }


def merge_system(session, record):
    subtype = record.get("subtype")
    if subtype == "compact_boundary":
        merge_compaction(session, record)
        return
    if subtype == "permission_denied":
        merge_permission_denied(session, record)
        return
    if subtype == "thinking_tokens":
        estimate = count(record.get("estimated_tokens"))
        if estimate is not None:
            session.estimated_thinking_tokens = max(session.estimated_thinking_tokens or 0, estimate)
        return
    if count(record.get("hookCount")) is not None or record.get("hookInfos") is not None:
        session.hook_records += 1
        session.hook_errors += len(record.get("hookErrors") or [])
    # Only a fixed marker is looked for, and only its presence is recorded.
    for field in ("status", "content", "message"):
        value = record.get(field)
        if isinstance(value, str) and any(marker in value.lower() for marker in PLUGIN_FALLBACK_MARKERS):
            session.plugin_fallback_markers += 1
            return


def merge_rate_limit(session, record):
    info = record.get("rate_limit_info") if isinstance(record.get("rate_limit_info"), dict) else {}
    status = text(info.get("status"), 40) or "unreported"
    session.rate_limit_statuses[status] = session.rate_limit_statuses.get(status, 0) + 1
    if info.get("isUsingOverage") is True:
        session.rate_limit_overage += 1


def ingest(paths):
    sessions = {}
    stats = {
        "files_read": 0,
        "bytes_read": 0,
        "records": 0,
        "unparsable_lines": 0,
        "oversize_lines_skipped": 0,
        "non_object_records": 0,
        "records_without_session_id": 0,
        "duplicate_result_records_ignored": 0,
        "record_types": {},
    }
    for path in paths:
        try:
            size = path.stat().st_size
        except OSError:
            raise InputError(f"unreadable_file:{path.name}") from None
        if size > MAX_FILE_BYTES:
            raise InputError(f"file_too_large:{path.name}")
        stats["files_read"] += 1
        stats["bytes_read"] += size
        unknown_session = f"unknown:{path.name}"
        try:
            handle = path.open("r", encoding="utf-8", errors="replace")
        except OSError:
            raise InputError(f"unreadable_file:{path.name}") from None
        with handle:
            for line in handle:
                if stats["records"] >= MAX_RECORDS:
                    raise InputError("too_many_records")
                if len(line) > MAX_LINE_BYTES:
                    stats["oversize_lines_skipped"] += 1
                    continue
                line = line.strip()
                if not line:
                    continue
                stats["records"] += 1
                try:
                    record = json.loads(line)
                except (ValueError, RecursionError):
                    stats["unparsable_lines"] += 1
                    continue
                if not isinstance(record, dict):
                    stats["non_object_records"] += 1
                    continue
                kind = text(record.get("type"), 40) or "untyped"
                subtype = text(record.get("subtype"), 40)
                label = f"{kind}/{subtype}" if subtype else kind
                stats["record_types"][label] = stats["record_types"].get(label, 0) + 1

                session_id = text(record.get("session_id") or record.get("sessionId"), 80)
                if session_id is None:
                    stats["records_without_session_id"] += 1
                    session_id = unknown_session
                session = sessions.get(session_id)
                if session is None:
                    session = sessions[session_id] = Session(session_id)
                session.touch_file(path.name)

                if kind == "system" and subtype == "init":
                    merge_init(session, record)
                elif kind == "system":
                    merge_system(session, record)
                elif kind == "assistant":
                    merge_assistant(session, record)
                elif kind == "result":
                    if not merge_result(session, record):
                        stats["duplicate_result_records_ignored"] += 1
                elif kind == "rate_limit_event":
                    merge_rate_limit(session, record)
    return sessions, stats


def ordered_results(session):
    """Record order, not `result_index`: a resumed session restarts that counter."""
    values = list(session.results.values())
    values.sort(key=lambda row: row["order"])
    return values


CARRIED_FIELDS = ("thinking_tokens", "list_price_estimate_usd")


def counters_fell(previous, current):
    """Cumulative totals only ever rise inside one client process, so a fall is a
    second counter even when nothing else says so."""
    for name, value in current["cumulative_model_usage"].items():
        prior = previous["cumulative_model_usage"].get(name)
        if prior is not None and any(
                (value.get(field) or 0) < (prior.get(field) or 0) for field in TOKEN_FIELDS):
            return True
    cost, prior_cost = current["cumulative_list_price_usd"], previous["cumulative_list_price_usd"]
    return cost is not None and prior_cost is not None and cost < prior_cost


def counter_epochs(results, ambiguous_boundary_restarts=False):
    """Group results into cumulative-counter epochs. An epoch is a span over which
    `modelUsage` and `total_cost_usd` accumulate from zero, and the client numbers
    its own results 0, 1, 2 ... inside one, so the restart of `result_index` is the
    boundary. These are inferred counter epochs, not observed operating-system
    processes: a resumed native session that keeps counting where it left off is
    one epoch and must be charged once.

    Requiring the totals to fall instead loses the interrupted run whenever the
    resumed one counts higher: 0.50 followed by a fresh 1.00 is 1.50, not 1.00.

    When either side of a pair has no `result_index`, a fall in the counters still
    identifies a restart, because a cumulative counter never falls inside one
    epoch. Anything else is genuinely indistinguishable from a continuation, so the
    boundary is counted as ambiguous and the caller reads the log both ways instead
    of presenting either reading as identified.

    Returns the epoch number of each result, the segments at which a new epoch
    began, and the number of ambiguous boundaries."""
    numbers, epoch, previous, boundaries, ambiguous = [], 1, None, {}, 0
    for result in results:
        restarted, uncertain = False, False
        if previous is not None:
            index, prior = result["result_index"], previous["result_index"]
            fell = counters_fell(previous, result)
            if index is None or prior is None:
                restarted, uncertain = fell, not fell
            else:
                restarted = index <= prior or fell
        if uncertain:
            ambiguous += 1
            restarted = ambiguous_boundary_restarts
        if restarted:
            epoch += 1
            boundaries[result["segment"]] = epoch
        numbers.append(epoch)
        previous = result
    return numbers, boundaries, ambiguous


def totals_over_epochs(results, numbers):
    """Each epoch reports its own final cumulative value; the session total is their
    sum. Within an epoch this stays a plain "last wins"."""
    final = {}
    for number, result in zip(numbers, results):
        final[number] = result

    totals, costs, unknown_costs = {}, [], 0
    for result in final.values():
        for name, value in result["cumulative_model_usage"].items():
            row = totals.get(name)
            if row is None:
                row = totals[name] = {field: 0 for field in TOKEN_FIELDS + CARRIED_FIELDS}
            # Descriptive fields describe the model, not the process: latest wins.
            row.update({key: item for key, item in value.items()
                        if key not in TOKEN_FIELDS + CARRIED_FIELDS})
            for field in TOKEN_FIELDS + CARRIED_FIELDS:
                row[field] = add(row[field], value.get(field))
        cost = result["cumulative_list_price_usd"]
        if cost is None:
            unknown_costs += 1
        else:
            costs.append(cost)
    return totals, (sum(costs) if costs else None), unknown_costs


def cumulative_by_process(results):
    """The reported reading treats an ambiguous boundary as a continuation, which is
    the smaller of the two totals the log admits. The other reading — every
    ambiguous boundary a fresh counter — is computed as well, so the uncertainty
    can be published rather than settled by assumption. Neither is invented: each
    is a total the same records support, and the log does not say which holds."""
    numbers, boundaries, ambiguous = counter_epochs(results)
    totals, cost, unknown_costs = totals_over_epochs(results, numbers)
    for number, result in zip(numbers, results):
        result["process"] = number
    restarted_numbers, _, _ = counter_epochs(results, ambiguous_boundary_restarts=True)
    restarted_totals, restarted_cost, _ = totals_over_epochs(results, restarted_numbers)
    info = {
        "client_processes": numbers[-1] if numbers else 1,
        "client_processes_if_ambiguous_boundaries_are_restarts":
            restarted_numbers[-1] if restarted_numbers else 1,
        "process_boundary_segments": boundaries,
        "ambiguous_process_boundaries": ambiguous,
        "processes_without_reported_cost": unknown_costs,
        "cost_if_ambiguous_boundaries_are_restarts": restarted_cost,
        "tokens_if_ambiguous_boundaries_are_restarts": sum_token_maps(restarted_totals.values()),
    }
    return totals, cost, info


def process_rows(results):
    """Per-epoch detail, so a reader can see each cumulative result separately from
    the per-turn increments that make up the same run. The key stays `process` for
    compatibility; it names an inferred counter epoch, not an observed process."""
    rows = []
    for number in sorted({result["process"] for result in results}):
        members = [result for result in results if result["process"] == number]
        last = members[-1]
        rows.append({
            "process": number,
            "process_identity_basis": "inferred_cumulative_counter_epoch",
            "segments": sorted({result["segment"] for result in members}),
            "result_events": len(members),
            "result_index_range": [members[0]["result_index"], last["result_index"]],
            "final_subtype": last["subtype"],
            "final_cumulative_model_usage": {
                name: {field: value.get(field) for field in TOKEN_FIELDS}
                for name, value in last["cumulative_model_usage"].items()},
            "final_cumulative_list_price_usd": last["cumulative_list_price_usd"],
            "sum_of_per_turn_result_usage": sum_token_maps(
                result["usage_increment"] for result in members),
        })
    return rows


def sum_token_maps(maps):
    total = zero_tokens()
    for item in maps:
        accumulate(total, item)
    return total


def summarize_permission_denials(session, results):
    """A refused tool call is reported twice by the client: once as a live
    `system/permission_denied` event and again, if a result follows, in that
    result's `permission_denials` list. Reading the list alone loses every denial
    in a run that was interrupted before its result. The two views are matched on
    `tool_use_id`; entries without one cannot be matched and are added as their own
    count rather than being silently merged or dropped."""
    matched = dict(session.permission_denied_events)
    unmatchable_in_results = 0
    for result in results:
        for identifier in result["permission_denial_ids"]:
            if identifier is None:
                unmatchable_in_results += 1
            else:
                matched.setdefault(identifier, {"tool_name": "unreported",
                                                "decision_reason_type": "unreported"})
    by_tool, by_reason = {}, {}
    for entry in matched.values():
        by_tool[entry["tool_name"]] = by_tool.get(entry["tool_name"], 0) + 1
        reason = entry["decision_reason_type"]
        by_reason[reason] = by_reason.get(reason, 0) + 1
    return {
        "permission_denials": len(matched) + unmatchable_in_results,
        "permission_denied_events": len(session.permission_denied_events),
        "permission_denials_listed_in_results": sum(result["permission_denials"] for result in results),
        "permission_denials_by_tool": by_tool,
        "permission_denials_by_decision_reason": by_reason,
        "permission_denials_without_tool_use_id":
            session.permission_denied_events_without_tool_use_id + unmatchable_in_results,
        "permission_denials_note": "Distinct denials, matched on tool_use_id across live "
                                   "system/permission_denied events and the permission_denials list of each "
                                   "result. Entries without a tool_use_id cannot be matched and are counted "
                                   "separately, so this figure is an upper bound when that field is absent.",
    }


def completeness_note(state, current):
    """Says, in the report itself, what the totals do and do not cover."""
    if state == "incomplete_no_result":
        return ("No result event: the log is interrupted or still running, so totals cover observed API "
                "responses only.")
    if state == "incomplete_unfinished_segment":
        if current and not current["api_requests"]:
            return ("A result completed an earlier segment and the client then opened a new one that has "
                    "recorded no request yet: the session is open, its current segment has no result, and "
                    "any work it goes on to do is outside these totals.")
        return ("A result completed an earlier segment, but the current segment has no result: the totals "
                "cover the reported segments and usage_after_last_result is the open segment's observed "
                "per-request usage, which no cumulative counter has reported yet.")
    if state == "incomplete_work_after_last_result":
        return ("Requests were recorded after the last result, in the same segment that result closed and "
                "without a new init: that work is real usage no cumulative counter has reported, held in "
                "usage_after_last_result rather than in the totals.")
    return None


def summarize_session(session):
    results = ordered_results(session)
    requests = list(session.requests.values())

    assistant_total = sum_token_maps(request["usage"] for request in requests)
    increments = sum_token_maps(result["usage_increment"] for result in results)

    # modelUsage is cumulative per counter epoch: each epoch contributes its own
    # final value once, and a resumed epoch is added rather than replacing.
    final_models, final_cost, process_info = cumulative_by_process(results)
    counter_restarts = process_info["client_processes"] - 1 if results else 0
    final_total = sum_token_maps(final_models.values())

    # Whether the accounting can be identified at all is a separate question from
    # whether the session finished. An ambiguous boundary leaves two totals the same
    # records support — the counters continued, or a fresh counter started — and the
    # log does not say which. The smaller is reported as a lower bound, the larger
    # beside it, and no figure is published as the total.
    ambiguous_boundaries = process_info["ambiguous_process_boundaries"]
    restarted_cost = process_info["cost_if_ambiguous_boundaries_are_restarts"]
    restarted_tokens = process_info["tokens_if_ambiguous_boundaries_are_restarts"]
    accounting_identified = None if not results else not ambiguous_boundaries
    accounting_state = ("no_result_to_account_for" if not results else "identified"
                        if accounting_identified else "ambiguous_counter_epoch_boundaries")

    naive_models = {}
    for result in results:
        for name, value in result["cumulative_model_usage"].items():
            row = naive_models.setdefault(name, zero_tokens())
            accumulate(row, value)
    naive_total = sum_token_maps(naive_models.values())

    if results and final_models:
        basis = ("final_cumulative_model_usage" if accounting_identified
                 else "final_cumulative_model_usage_lower_bound")
        totals = final_total
    elif results:
        basis, totals = "sum_of_incremental_result_usage", increments
    else:
        basis, totals = "assistant_records_only", assistant_total

    # `usage` reports the main model alone; background models reach modelUsage only.
    main_model = None
    for request in requests:
        if request["model"] in final_models:
            main_model = request["model"]
            break
    if main_model is None and final_models:
        main_model = max(final_models, key=lambda name: final_models[name].get("output_tokens") or 0)
    main_tokens = zero_tokens() if main_model is None else {
        field: final_models[main_model].get(field) for field in TOKEN_FIELDS}
    side_tokens = {field: add(final_total[field], -(main_tokens[field] or 0)) for field in TOKEN_FIELDS}

    final = results[-1] if results else None
    success = [result for result in results if result["subtype"] == "success" and result["is_error"] is not True]

    reconciles = None
    exceeds = None
    out_of_turn = {field: None for field in TOKEN_FIELDS}
    if results and final_models:
        reconciles = all(increments[field] == main_tokens[field] for field in TOKEN_FIELDS)
        exceeds = any((increments[field] or 0) > (main_tokens[field] or 0) for field in TOKEN_FIELDS)
        out_of_turn = {field: add(main_tokens[field], -(increments[field] or 0)) for field in TOKEN_FIELDS}

    # `result.usage` covers in-turn requests. Work the client does outside a turn,
    # a built-in compaction summary above all, reaches modelUsage alone. The
    # residual is reported, not attributed: this tool does not know what caused it.
    partial_output = None
    if results and main_tokens["output_tokens"]:
        partial_output = (assistant_total["output_tokens"] or 0) * 2 < main_tokens["output_tokens"]

    models = {}
    for name, value in (final_models or {}).items():
        models[name] = {key: value.get(key) for key in
                        ("input_tokens", "output_tokens", "cache_read_input_tokens",
                         "cache_creation_input_tokens", "thinking_tokens", "provider", "context_window")}
        models[name]["list_price_estimate_usd"] = value.get("list_price_estimate_usd")
        models[name]["cost_basis"] = value.get("cost_basis")
        models[name]["billed_dollars"] = None
    for request in requests:
        name = request["model"] or "unreported"
        models.setdefault(name, {"observed_in_assistant_records_only": True})
    observed_models = sorted({request["model"] for request in requests if request["model"]})

    # Segments separate an interrupted run from the run that resumed it, using
    # only incremental per-request numbers, which no restart can double count.
    boundaries = process_info["process_boundary_segments"]
    # Every init opens a segment, including the one the client has opened without
    # recording anything in it yet. Listing only the segments that carry a record
    # hid exactly that case: a session whose last act was to open a new segment
    # then had a completed earlier segment as its "current" one and read complete.
    opened = set(range(1, session.init_events + 1))
    segments = []
    for index in sorted(opened | {request["segment"] for request in requests} |
                        {result["segment"] for result in results}):
        members = [request for request in requests if request["segment"] == index]
        finals = [result for result in results if result["segment"] == index]
        # Event order decides this, not the presence of a result: a request whose
        # `results_recorded_before` reaches the order of the segment's last result
        # was recorded after it and no counter in this segment has reported it.
        after_result = [request for request in members
                        if finals and request["results_recorded_before"] >= finals[-1]["order"]]
        if finals and after_result:
            segment_state = "work_after_result"
        elif finals:
            segment_state = "complete" if finals[-1]["subtype"] == "success" else "error_result"
        else:
            segment_state = "unfinished"
        segments.append({
            "segment": index,
            "process": finals[-1]["process"] if finals else
            max([number for segment, number in boundaries.items() if segment <= index] or [1]),
            "api_requests": len(members),
            "api_requests_after_segment_result": len(after_result),
            "result_events": len(finals),
            "final_subtype": finals[-1]["subtype"] if finals else None,
            "state": segment_state,
            "assistant_record_sum": sum_token_maps(request["usage"] for request in members),
            "incremental_result_usage": sum_token_maps(result["usage_increment"] for result in finals),
        })

    # Usage recorded after every result event belongs to work no cumulative counter
    # has reported. It is kept apart from the totals instead of being dropped.
    unreported_requests = [request for request in requests
                           if request["results_recorded_before"] >= len(results)]
    unreported = sum_token_maps(request["usage"] for request in unreported_requests)
    covered = sum_token_maps(request["usage"] for request in requests
                             if request["results_recorded_before"] < len(results))

    # A result ends its own segment, not the session, and a success anywhere in the
    # log ends nothing at all. Completeness is read off the recorded order of
    # events: work that follows the last result, or a segment the client opened and
    # has not finished — with or without a record in it yet — leaves the session
    # open and its totals partial.
    current = segments[-1] if segments else None
    if current is None or not results:
        state = "incomplete_no_result"
    elif current["state"] == "unfinished":
        state = "incomplete_unfinished_segment"
    elif unreported_requests or current["state"] == "work_after_result":
        state = "incomplete_work_after_last_result"
    elif current["state"] == "error_result" or final["is_error"] is True:
        state = "error_result"
    else:
        state = "complete"

    # The mirror image: work recorded before the first cumulative counter of the
    # session. Input and cache counts are final at message start, so if those
    # records already exceed the first result's cumulative total, that counter did
    # not begin with them and an earlier client process ended without a result.
    leading = sum_token_maps(request["usage"] for request in requests
                             if request["results_recorded_before"] == 0)
    leading_excess = {field: None for field in TOKEN_FIELDS}
    earlier_process_suspected = None
    first_cumulative = results[0]["cumulative_model_usage"].get(main_model) if results else None
    if first_cumulative:
        leading_excess = {field: max(0, (leading[field] or 0) - (first_cumulative.get(field) or 0))
                          for field in TOKEN_FIELDS}
        earlier_process_suspected = any(value > 0 for value in leading_excess.values())

    permission_denials = summarize_permission_denials(session, results)
    top_tools = sorted(session.tool_calls.items(), key=lambda item: (-item[1], item[0]))[:MAX_TOP_TOOLS]
    return {
        "session_id": session.session_id,
        "files": sorted(session.files),
        "claude_code_version": session.version,
        "requested_model": session.requested_model,
        "permission_mode": session.permission_mode,
        "plugins_loaded": sorted(session.plugins),
        "init_events": session.init_events,
        "replayed_init_records_ignored": session.replayed_init_records,
        "state": state,
        "accounting_state": accounting_state,
        "accounting_totals_are_identified": accounting_identified,
        "segments": segments,
        "segments_note": "One segment per init record, including a segment the client has opened without "
                         "recording anything in it yet. The client writes an init per prompt in stream-json "
                         "input mode and again when a saved session is resumed, so segments separate an "
                         "interrupted run from its continuation without re-adding shared cumulative totals. "
                         "state is read from the recorded order of events: work_after_result means the "
                         "segment reported a result and then recorded further requests.",
        "processes": process_rows(results),
        "processes_note": "A process here is an inferred cumulative-counter epoch, not an observed operating "
                          "system process: one span over which modelUsage and total_cost_usd accumulate and "
                          "results are numbered from zero. A resumed native session that keeps its counters "
                          "is one epoch and is counted once. Each epoch contributes its own final cumulative "
                          "value once; the per-turn increments beside it are the same run counted "
                          "incrementally.",
        "completeness": {
            "result_events": len(results),
            "successful_results": len(success),
            "completed_segments": sum(1 for segment in segments if segment["state"] == "complete"),
            "segments_opened_without_recorded_work": sum(
                1 for segment in segments if segment["state"] == "unfinished" and not segment["api_requests"]),
            "current_segment": current["segment"] if current else None,
            "current_segment_state": current["state"] if current else None,
            "final_subtype": final["subtype"] if final else None,
            "final_is_error": final["is_error"] if final else None,
            "final_terminal_reason": final["terminal_reason"] if final else None,
            "api_requests_after_last_result": len(unreported_requests),
            "usage_after_last_result": unreported,
            "usage_before_first_result_not_inside_it": leading_excess,
            "earlier_unreported_client_process_suspected": earlier_process_suspected,
            "earlier_process_note": "Assistant records preceding the first result already exceed that "
                                    "result's own cumulative total, which only happens when a previous "
                                    "client process ran and ended without reporting one. The excess is a "
                                    "lower bound: stream records do not carry final output_tokens, and any "
                                    "background-model record is included in the comparison."
            if earlier_process_suspected else None,
            "totals_are_partial": state != "complete" or accounting_identified is False,
            "partial_because": [reason for reason in (
                "unfinished_or_uncovered_work" if state != "complete" else None,
                "ambiguous_counter_epoch_boundaries" if accounting_identified is False else None,
            ) if reason],
            "note": completeness_note(state, current),
        },
        "api_requests": {
            "counted": len(requests),
            "duplicate_content_block_records_ignored": session.duplicate_block_records,
            "conflicting_duplicate_usage": session.conflicting_duplicate_usage,
            "turns_with_multiple_iterations": sum(
                1 for request in requests if (request["usage"]["iterations"] or 0) > 1),
        },
        "tokens": {"basis": basis, **totals,
                   "basis_note": "final_cumulative_model_usage is the sum over counter epochs of each "
                                 "epoch's own final cumulative modelUsage, never a sum over results. It "
                                 "excludes usage_after_last_result, which no result has reported yet. With "
                                 "an ambiguous epoch boundary the basis is named _lower_bound and the other "
                                 "reading is tokens_if_ambiguous_boundaries_are_restarts; the true total is "
                                 "one of the two and the log does not say which.",
                   "tokens_if_ambiguous_boundaries_are_restarts":
                       restarted_tokens if accounting_identified is False else None,
                   "usage_after_last_result": unreported,
                   "thinking_tokens": add(*[value.get("thinking_tokens") for value in final_models.values()])
                   if final_models else assistant_total.get("thinking_tokens"),
                   "estimated_thinking_tokens_stream_max": session.estimated_thinking_tokens,
                   "estimate_note": "estimated_thinking_tokens_stream_max is a client estimate, not a provider count."},
        "by_model": models,
        "cost": {
            # Unknown, not a guess, when the log admits two totals: publishing the
            # continuation reading here would have reported 0.50 then a fresh 1.00
            # as 1.00.
            "list_price_estimate_usd": final_cost if accounting_identified is not False else None,
            "cost_total_is_identified": accounting_identified,
            "list_price_estimate_usd_if_counters_continued": final_cost,
            "list_price_estimate_usd_if_ambiguous_boundaries_are_restarts": restarted_cost,
            "cost_basis": "list",
            "billed_dollars": None,
            "client_processes": process_info["client_processes"] if results else 0,
            "client_processes_if_ambiguous_boundaries_are_restarts":
                process_info["client_processes_if_ambiguous_boundaries_are_restarts"] if results else 0,
            "cumulative_counter_restarts": counter_restarts,
            "processes_without_reported_cost": process_info["processes_without_reported_cost"],
            "ambiguous_process_boundaries": process_info["ambiguous_process_boundaries"],
            "results_identified_by_content_digest": session.results_identified_by_content,
            "note": "total_cost_usd is cumulative within one counter epoch and is a list-price estimate "
                    "published by the client. It must not be summed across the results of one epoch; it is "
                    "summed across epochs, each contributing its own final value. On a subscription it is "
                    "not a cash charge.",
            "ambiguity_note": "A boundary with no result_index on either side and counters that did not "
                              "fall is indistinguishable from one continuing epoch, so the total is not "
                              "identified: list_price_estimate_usd is unknown and the two readings are "
                              "given beside it. A resumed native session that preserved its counters is the "
                              "continuation reading and must not be charged twice."
            if accounting_identified is False else None,
        },
        "cross_check": {
            "assistant_record_sum": assistant_total,
            "assistant_record_sum_covered_by_results": covered,
            "coverage_note": "Assistant records are compared against the cumulative totals only up to the "
                             "last result. Requests made after it are real usage that no result has reported, "
                             "so including them would look like a double count rather than an open segment. "
                             "With an unidentified total there is nothing settled to compare against, so the "
                             "comparison is unknown rather than a reported double count.",
            "sum_of_incremental_result_usage": increments,
            "final_cumulative_model_usage": final_total,
            "main_model": main_model,
            "final_cumulative_main_model_usage": main_tokens,
            "background_model_tokens_absent_from_result_usage": side_tokens,
            "out_of_turn_main_model_tokens": out_of_turn,
            "out_of_turn_note": "Cumulative main-model usage minus the sum of per-turn increments. A "
                                "built-in compaction summary is the usual source; the residual is not attributed here.",
            "increments_match_final_cumulative": reconciles,
            "increments_exceed_cumulative": exceeds,
            "assistant_output_tokens_look_partial": partial_output,
            "assistant_sum_note": "In stream-json transcripts an assistant record carries the usage known at "
                                  "message start: input and cache counts are final, output_tokens is not. Session "
                                  "transcripts under ~/.claude/projects carry the completed usage.",
            "naive_sum_of_cumulative_model_usage_avoided": naive_total,
            "double_count_avoided_tokens": None if not results else
            add(*[add(naive_total[field], -(final_total[field] or 0)) for field in TOKEN_FIELDS]),
            # Unknown when the cumulative total itself is unidentified: an ambiguous
            # boundary reported at its lower bound would show honest records as a
            # double count, which is the wrong finding for that log.
            "assistant_sum_within_result_totals":
                None if not (results and final_models) or accounting_identified is False else all(
                    (covered[field] or 0) <= (main_tokens[field] or 0) for field in TOKEN_FIELDS),
        },
        "compaction": {
            "events": session.compactions,
            "count": len(session.compactions),
            "context_tokens_dropped": session.compactions_dropped,
            "triggers": sorted({event["trigger"] or "unreported" for event in session.compactions}),
        },
        "fallback": {
            "rate_limit_events": sum(session.rate_limit_statuses.values()),
            "rate_limit_statuses": session.rate_limit_statuses,
            "rate_limit_overage_events": session.rate_limit_overage,
            **permission_denials,
            "api_error_statuses": [result["api_error_status"] for result in results
                                   if result["api_error_status"] is not None],
            "non_success_results": sum(1 for result in results if result["subtype"] != "success"),
            "models_observed": observed_models,
            "requested_model_differs_from_observed": None if not observed_models or not session.requested_model
            else not any(session.requested_model.startswith(model) for model in observed_models),
            "plugin_compaction_fallback_markers": session.plugin_fallback_markers,
            "hook_records": session.hook_records,
            "hook_errors": session.hook_errors,
        },
        "tool_calls": {
            "total": sum(session.tool_calls.values()),
            "distinct_tools": len(session.tool_calls),
            "by_name": dict(top_tools),
            "distinct_call_signatures": len(session.tool_signatures),
            "exact_repeat_calls": session.tool_exact_repeats,
            "note": "An exact repeat is the same tool with byte-identical input, matched by local digest. "
                    "It is a structural observation, not a measured saving.",
        },
        "turns": {
            "num_turns": add(*[result["num_turns"] for result in results]) if results else None,
            "duration_ms": add(*[result["duration_ms"] for result in results]) if results else None,
            "duration_api_ms": add(*[result["duration_api_ms"] for result in results]) if results else None,
            "subagents_spawned": add(*[result["subagents_spawned"] for result in results]) if results else None,
        },
    }


def build_gates(rows, stats):
    complete = [row for row in rows if row["state"] == "complete"]
    reconciled = [row for row in rows if row["cross_check"]["increments_exceed_cumulative"] is True]
    exceeded = [row for row in rows if row["cross_check"]["assistant_sum_within_result_totals"] is False]
    unidentified = [row for row in rows if row["accounting_totals_are_identified"] is False]
    parse_ratio = (stats["unparsable_lines"] + stats["non_object_records"]) / stats["records"] if stats["records"] else 0.0
    gates = [
        {"name": "records_parsed", "passed": parse_ratio <= 0.01,
         "detail": {"unparsable_lines": stats["unparsable_lines"],
                    "non_object_records": stats["non_object_records"],
                    "records": stats["records"], "ratio": round(parse_ratio, 6), "limit": 0.01}},
        # Increments above the cumulative total mean a turn was counted twice.
        {"name": "incremental_usage_never_exceeds_cumulative_main_model_usage", "passed": not reconciled,
         "detail": {"sessions_failing": [row["session_id"] for row in reconciled]}},
        {"name": "assistant_records_within_result_totals", "passed": not exceeded,
         "detail": {"sessions_failing": [row["session_id"] for row in exceeded]}},
        # Completeness is read from the recorded order of events: a session whose
        # last result succeeded but which then recorded further work, or opened a
        # further segment, is not finished.
        {"name": "every_session_has_a_final_result", "passed": len(complete) == len(rows),
         "detail": {"sessions": len(rows), "complete": len(complete),
                    "incomplete": [{"session_id": row["session_id"], "state": row["state"],
                                    "current_segment_state": row["completeness"]["current_segment_state"],
                                    "api_requests_after_last_result":
                                        row["completeness"]["api_requests_after_last_result"]}
                                   for row in rows if row["state"] != "complete"]}},
        # An unidentified total is not an accounting result. This gate fails rather
        # than letting the smaller of two possible totals pass as verified.
        {"name": "accounting_totals_are_identified", "passed": not unidentified,
         "detail": {"sessions_unidentified": [
             {"session_id": row["session_id"], "accounting_state": row["accounting_state"],
              "ambiguous_process_boundaries": row["cost"]["ambiguous_process_boundaries"],
              "list_price_estimate_usd_if_counters_continued":
                  row["cost"]["list_price_estimate_usd_if_counters_continued"],
              "list_price_estimate_usd_if_ambiguous_boundaries_are_restarts":
                  row["cost"]["list_price_estimate_usd_if_ambiguous_boundaries_are_restarts"]}
             for row in unidentified],
             "note": "A counter-epoch boundary with no result_index and no fall in the counters is "
                     "indistinguishable from one continuing epoch. The two readings are given; the log "
                     "does not establish which holds, so no total is published for these sessions."}},
    ]
    return gates


def report(paths):
    sessions, stats = ingest(paths)
    rows = [summarize_session(session) for session in sessions.values()]
    rows.sort(key=lambda row: row["session_id"])
    totals = sum_token_maps(row["tokens"] for row in rows)
    known_costs = [row["cost"]["list_price_estimate_usd"] for row in rows
                   if row["cost"]["list_price_estimate_usd"] is not None]
    unidentified = [row for row in rows if row["accounting_totals_are_identified"] is False]
    # Bounds over the whole report: each session contributes its identified total
    # where it has one, and both of its possible totals where it does not.
    bounds = {key: [row["cost"][key] for row in rows if row["cost"][key] is not None] for key in
              ("list_price_estimate_usd_if_counters_continued",
               "list_price_estimate_usd_if_ambiguous_boundaries_are_restarts")}
    gates = build_gates(rows, stats)
    return {
        "schema_version": SCHEMA,
        "tool": "claude_usage_collect",
        "interpretation": INTERPRETATION,
        "inputs": {"files": [path.name for path in paths], **stats},
        "sessions": rows,
        "totals": {
            "sessions": len(rows),
            "complete_sessions": sum(1 for row in rows if row["state"] == "complete"),
            "api_requests": sum(row["api_requests"]["counted"] for row in rows),
            "duplicate_content_block_records_ignored":
                sum(row["api_requests"]["duplicate_content_block_records_ignored"] for row in rows),
            **totals,
            "client_processes": sum(row["cost"]["client_processes"] for row in rows),
            "usage_after_last_result": sum_token_maps(
                row["completeness"]["usage_after_last_result"] for row in rows),
            "permission_denials": sum(row["fallback"]["permission_denials"] for row in rows),
            "compaction_events": sum(row["compaction"]["count"] for row in rows),
            "tool_calls": sum(row["tool_calls"]["total"] for row in rows),
            "exact_repeat_tool_calls": sum(row["tool_calls"]["exact_repeat_calls"] for row in rows),
            "list_price_estimate_usd": sum(known_costs) if known_costs else None,
            "sessions_without_reported_cost": len(rows) - len(known_costs),
            "sessions_with_unidentified_cost": len(unidentified),
            "aggregate_cost_is_identified": not unidentified,
            "list_price_estimate_usd_lower_bound":
                sum(bounds["list_price_estimate_usd_if_counters_continued"])
                if bounds["list_price_estimate_usd_if_counters_continued"] else None,
            "list_price_estimate_usd_upper_bound":
                sum(bounds["list_price_estimate_usd_if_ambiguous_boundaries_are_restarts"])
                if bounds["list_price_estimate_usd_if_ambiguous_boundaries_are_restarts"] else None,
            "cost_note": "list_price_estimate_usd omits every session whose counter-epoch boundaries could "
                         "not be identified, so with sessions_with_unidentified_cost above zero it is not "
                         "the report's total: the total lies between the lower and upper bounds."
            if unidentified else None,
            "billed_dollars": None,
        },
        "gates": gates,
        "gates_passed": all(gate["passed"] for gate in gates),
    }


def markdown(document):
    lines = ["# Claude usage report", "", document["interpretation"], "",
             f"Files: {document['inputs']['files_read']}; records: {document['inputs']['records']}; "
             f"unparsable lines: {document['inputs']['unparsable_lines']}.", ""]
    totals = dict(document["totals"])
    # An unidentified total is rendered as unknown, never as the smaller reading.
    totals["list_price_estimate_usd"] = (
        "unknown" if totals["list_price_estimate_usd"] is None else totals["list_price_estimate_usd"])
    lines += ["## Totals", "",
              "| Sessions | Complete | API requests | Duplicate block records ignored | Input | Output | Cache read | Cache creation | Tool calls | Exact repeats | List-price estimate (USD) |",
              "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
              "| {sessions} | {complete_sessions} | {api_requests} | {duplicate_content_block_records_ignored} | "
              "{input_tokens} | {output_tokens} | {cache_read_input_tokens} | {cache_creation_input_tokens} | "
              "{tool_calls} | {exact_repeat_tool_calls} | {list_price_estimate_usd} |".format(**totals),
              "", "Billed dollars: unknown (list price only)."]
    if not document["totals"]["aggregate_cost_is_identified"]:
        raw = document["totals"]
        lines += ["", f"**Aggregate list-price cost: unknown.** "
                      f"{raw['sessions_with_unidentified_cost']} session(s) have a counter-epoch boundary "
                      f"this log does not identify, so their cost is not in the total above. Reading every "
                      f"ambiguous boundary as a continuation gives "
                      f"{raw['list_price_estimate_usd_lower_bound']}; reading each as a fresh counter gives "
                      f"{raw['list_price_estimate_usd_upper_bound']}. The true figure is one of the two and "
                      f"the records do not say which."]
    lines += ["", "## Sessions", "",
              "| Session | State | Accounting | Basis | Requests | Input | Output | Cache read | Cache creation | Compactions | List-price USD |",
              "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for row in document["sessions"]:
        tokens = row["tokens"]
        cost = row["cost"]["list_price_estimate_usd"]
        lines.append("| {id} | {state} | {accounting} | {basis} | {requests} | {input} | {output} | {read} | "
                     "{creation} | {compactions} | {cost} |".format(
                         id=row["session_id"][:8], state=row["state"],
                         accounting=row["accounting_state"], basis=tokens["basis"],
                         requests=row["api_requests"]["counted"], input=tokens["input_tokens"],
                         output=tokens["output_tokens"], read=tokens["cache_read_input_tokens"],
                         creation=tokens["cache_creation_input_tokens"],
                         compactions=row["compaction"]["count"],
                         cost="unknown" if cost is None else cost))
    # Cumulative and per-turn are two views of one run, never a pair to add.
    lines += ["", "## Client processes", "",
              "| Session | Process | Segments | Results | Cumulative output | Cumulative cache read | "
              "Per-turn output | Per-turn cache read | List-price USD |",
              "|---|---:|---|---:|---:|---:|---:|---:|---:|"]
    for row in document["sessions"]:
        for entry in row["processes"]:
            # No modelUsage at all is unknown, not zero.
            cumulative = (sum_token_maps(entry["final_cumulative_model_usage"].values())
                          if entry["final_cumulative_model_usage"] else
                          {field: None for field in TOKEN_FIELDS})
            turns = entry["sum_of_per_turn_result_usage"]
            lines.append("| {id} | {process} | {segments} | {results} | {out} | {read} | {turn_out} | "
                         "{turn_read} | {cost} |".format(
                             id=row["session_id"][:8], process=entry["process"],
                             segments=",".join(str(number) for number in entry["segments"]),
                             results=entry["result_events"], out=cumulative["output_tokens"],
                             read=cumulative["cache_read_input_tokens"],
                             turn_out=turns["output_tokens"], turn_read=turns["cache_read_input_tokens"],
                             cost=entry["final_cumulative_list_price_usd"]))
    lines += ["", "A process here is an inferred cumulative-counter epoch, not an observed operating system "
                  "process. Cumulative columns are each epoch's own final counter, taken once and summed "
                  "across epochs; a resumed session that kept its counters is one epoch and is counted "
                  "once. Per-turn columns are the same run counted incrementally. The two are "
                  "different views of one run and must not be added together.", "", "## Limits on these totals", ""]
    limits = []
    for row in document["sessions"]:
        short = row["session_id"][:8]
        if row["completeness"]["api_requests_after_last_result"]:
            open_usage = row["completeness"]["usage_after_last_result"]
            limits.append(f"- {short}: {row['state']}; "
                          f"{row['completeness']['api_requests_after_last_result']} API requests after the "
                          f"last result, carrying {open_usage['cache_read_input_tokens']} cache-read and "
                          f"{open_usage['output_tokens']} output tokens that no result has reported.")
        elif row["state"] != "complete" and row["completeness"]["result_events"]:
            limits.append(f"- {short}: {row['state']}; current segment "
                          f"{row['completeness']['current_segment']} is "
                          f"{row['completeness']['current_segment_state']}, so the session is open and any "
                          f"work it records next is outside these totals.")
        if row["accounting_totals_are_identified"] is False:
            limits.append(
                f"- {short}: accounting not identified; "
                f"{row['cost']['ambiguous_process_boundaries']} counter-epoch boundary(ies) with no "
                f"result_index and no fall in the counters. Cost is unknown: "
                f"{row['cost']['list_price_estimate_usd_if_counters_continued']} if the counters continued, "
                f"{row['cost']['list_price_estimate_usd_if_ambiguous_boundaries_are_restarts']} if a fresh "
                f"counter started. Token totals are the lower of the two readings.")
    lines += limits or ["- None: every session is finished and its counter epochs are identified."]
    lines += ["", "## Quality gates", "", "| Gate | Result |", "|---|---|"]
    for gate in document["gates"]:
        lines.append(f"| {gate['name']} | {'pass' if gate['passed'] else 'FAIL'} |")
    lines.append("")
    return "\n".join(lines)


def resolve(values):
    paths = []
    for value in values:
        path = Path(value)
        if path.is_dir():
            paths += sorted(item for item in path.glob("*.jsonl") if item.is_file())
        else:
            paths.append(path)
    if not paths:
        raise InputError("no_jsonl_inputs")
    if len(paths) > MAX_FILES:
        raise InputError("too_many_files")
    seen, unique = set(), []
    for path in paths:
        try:
            key = path.resolve()
        except OSError:
            raise InputError(f"unreadable_file:{path.name}") from None
        if key not in seen:
            seen.add(key)
            unique.append(path)
    return unique


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("report", "check"):
        item = commands.add_parser(name)
        item.add_argument("paths", nargs="+", help="JSONL files, or directories searched for *.jsonl")
        item.add_argument("--out", type=Path)
        item.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)
    try:
        document = report(resolve(args.paths))
    except InputError as error:
        print(str(error), file=sys.stderr)
        return 2
    encoded = (markdown(document) if args.format == "markdown"
               else json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n")
    if args.out:
        args.out.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    if args.command == "check" and not document["gates_passed"]:
        print("quality_gate_failed", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
