#!/usr/bin/env python3
"""Write synthetic Droid and Claude Code homes dated relative to the current time.

The fixtures under Fixtures/ are pinned to fixed dates that the Swift tests assert
against, so on a live clock almost all of their records sit outside the dashboard's
today/week/month windows and the Chart's current ranges come up nearly empty. This
helper writes throwaway homes whose records are a few minutes old, so the Chart
(and the Droid row's 5-hour window) have data in every current range, every vendor
family wears its own colour, and a model shared by Claude Code and Droid merges
into one series. When the run starts so soon after local midnight that the records'
spread would straddle it, the ages are clamped to stay after the most recent local
midnight, so Today and This week stay populated right after midnight too. Everything
is invented: no line is copied from a real ~/.factory/logs file, no real home is
read, and the checked-in fixtures are never touched.

Usage:
    python3 scripts/tests/fixture_now.py --out /tmp/keys-now

Then point an isolated Keysrs at it (KEYS_CATALOG temp, never the real one) and
open the URL the command prints — `keys dashboard` no longer serves a site, it
shows the installed app's window, so the checkout copy that still binds its own
loopback site is `keys menubar`:

    KEYS_CATALOG=/tmp/keys-now/catalog.db \\
      KEYS_DROID_HOME=/tmp/keys-now/droid-home \\
      CLAUDE_CONFIG_DIR=/tmp/keys-now/claude-home \\
      ./.build/debug/keys menubar
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path

# Byte-for-byte the marker DroidIngest.keepLine requires
# (Sources/KeysCore/DroidIngest.swift); test_fixture_now.py pins the two together.
MARKER = "] INFO: [Agent] Streaming result | Context: "

# One record per vendor family the Chart colours. The claude, gpt, gemini, glm,
# kimi and grok numbers mirror Fixtures/droid-home/README.md so the two fixtures
# stay comparable; deepseek-r2 has no checked-in record and is invented here.
# (model, session, age_minutes, input, cache_read, cache_written, output, reasoning, upstream_id)
DROID_RECORDS = [
    ("claude-sonnet-5", "aaaaaaaa-0000-4000-8000-000000000001", 110, 1200, 30000, 500, 340, 0, "up-resp-now-1"),
    ("claude-sonnet-5", "aaaaaaaa-0000-4000-8000-000000000001", 100, 800, 41000, 0, 512, 0, None),
    ("gpt-6-pro", "bbbbbbbb-0000-4000-8000-000000000002", 90, 640, 0, 0, 220, 96, "up-req-now-2"),
    ("gemini-3-pro", "cccccccc-0000-4000-8000-000000000003", 80, 2100, 0, 0, 430, 0, "up-resp-now-3"),
    ("glm-5.3", "dddddddd-0000-4000-8000-000000000004", 70, 900, 1200, 60, 150, 0, "up-req-now-4"),
    ("kimi-k3", "eeeeeeee-0000-4000-8000-000000000005", 60, 450, 0, 0, 90, 0, None),
    ("deepseek-r2", "77777777-0000-4000-8000-000000000007", 50, 300, 0, 0, 60, 0, "up-resp-now-5"),
    ("grok-4-fast", "ffffffff-0000-4000-8000-000000000006", 40, 700, 0, 0, 130, 64, "up-resp-now-6"),
]

# Claude Code sessions carry one of the same model ids, so the Chart must merge
# the two tools' rows for it into a single series whose total counts each record
# under its own tool's rule.
# (model, session, age_minutes, input, cache_read, cache_creation, output)
CLAUDE_RECORDS = [
    ("claude-sonnet-5", "claude-sess-now-1", 30, 200, 40, 0, 80),
]

ZERO_SESSION = "99999999-0000-4000-8000-000000000009"
NOISE_SESSION = "88888888-0000-4000-8000-000000000008"

# Every age `write` stamps, before any clamping: the two noise records, the zero-token
# record, the Claude Code lines and each Droid record. The widest spread is what the
# midnight clamp below has to fit inside the time since the last local midnight.
RAW_AGES = [115, 114, 35, 31, 30] + [record[2] for record in DROID_RECORDS]


def age_adjustment(now):
    """Return (adjust, clamped) for stamping records at this `now`.

    A run started soon after local midnight would otherwise stamp its oldest records
    on yesterday — or even on the previous calendar week, when the boundary falls on a
    Sunday — and the dashboard's Today and Week ranges would come up empty even though
    the homes are full. When less time has passed since the most recent local midnight
    than the records' spread, the ages are compressed onto that span: the youngest
    record stays a few seconds old and the oldest lands just after midnight. Every
    record then sits inside today, and because a calendar week can only begin at a
    midnight, inside the current week as well.
    """
    oldest, youngest = max(RAW_AGES), min(RAW_AGES)
    local = now.astimezone()
    floor = local.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc)
    span = (now - floor).total_seconds() / 60.0
    if span >= oldest:
        return (lambda age: age), False
    if span < 0.2:
        # At midnight itself there is no room after it; leave the ages alone and let
        # Today be empty for the moment, exactly as it honestly is.
        return (lambda age: age), False

    def adjust(age):
        frac = (age - youngest) / float(oldest - youngest)
        return 0.05 + (span - 0.1) * frac

    return adjust, True


def droid_total(record):
    """The dashboard's droid-local rule: every bucket the log reports."""
    _, _, _, tokens, cache_read, cache_written, output, reasoning, _ = record
    return tokens + cache_read + cache_written + output + reasoning


def claude_total(record):
    """The dashboard's claude-local rule: input, output and the cache buckets."""
    _, _, _, tokens, cache_read, cache_creation, output = record
    return tokens + cache_read + cache_creation + output


def iso(moment):
    """Droid's and Claude Code's shared timestamp shape, milliseconds and Z (always UTC)."""
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)


def droid_line(now, age, record):
    """One usage line, stamped `age` minutes before `now` (the age may be clamped)."""
    model, session, _, tokens, cache_read, cache_written, output, reasoning, upstream = record
    context = {
        "count": 1,
        "inputTokens": tokens,
        "cacheReadInputTokens": cache_read,
        "cachedTokensWritten": cache_written,
        "totalInputTokens": tokens + cache_read + cache_written,
        "outputTokens": output,
        "reasoningTokens": reasoning,
        "type": "message_delta",
        "tags": {"sessionId": session, "modelId": model},
    }
    if upstream:
        context["upstreamResponseId" if upstream.startswith("up-resp") else "upstreamRequestId"] = upstream
    # The marker opens with the timestamp bracket's closing "]", so the line is
    # "[" + timestamp + marker + context, byte-for-byte the shape DroidIngest reads.
    return "[%s%s%s" % (iso(now - timedelta(minutes=age)), MARKER,
                        json.dumps(context, separators=(",", ":")))


def claude_line(index, now, age, record):
    model, session, _, tokens, cache_read, cache_creation, output = record
    entry = {
        "type": "assistant",
        "uuid": "u-now-%d" % index,
        "requestId": "u-now-%d" % index,
        "sessionId": session,
        "timestamp": iso(now - timedelta(minutes=age)),
        "cwd": "/tmp/keysrs-fixture-now",
        "message": {
            "id": "msg-now-%d" % index,
            "model": model,
            "role": "assistant",
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": tokens,
                "output_tokens": output,
                "cache_creation_input_tokens": cache_creation,
                "cache_read_input_tokens": cache_read,
            },
        },
    }
    return json.dumps(entry, separators=(",", ":"))


def droid_totals():
    totals = {}
    for record in DROID_RECORDS:
        totals[record[0]] = totals.get(record[0], 0) + droid_total(record)
    return totals


def claude_totals():
    totals = {}
    for record in CLAUDE_RECORDS:
        totals[record[0]] = totals.get(record[0], 0) + claude_total(record)
    return totals


def merged_totals():
    """Chart rows group on the model id and count each tool's records by its own rule."""
    merged = dict(droid_totals())
    for model, total in claude_totals().items():
        merged[model] = merged.get(model, 0) + total
    return merged


def write(out_dir, now=None):
    """Write <out>/droid-home and <out>/claude-home and return what to expect of them."""
    now = now or datetime.now(timezone.utc)
    # Stamp every record inside today whenever the clock is close to local midnight, so
    # the dashboard's Today and Week ranges stay populated right after midnight too.
    adjust, clamped = age_adjustment(now)
    out = Path(out_dir)
    logs = out / "droid-home" / "logs"
    logs.mkdir(parents=True, exist_ok=True)

    lines = [
        # The real log holds far more record types than usage ones; one of each kind
        # the parser must count past keeps the shape honest without any content.
        "[%s] INFO: [Agent] Streaming text | Context: %s" % (
            iso(now - timedelta(minutes=adjust(115))),
            json.dumps({"sessionId": NOISE_SESSION, "text": "SYNTHETIC-STREAMING-TEXT"},
                       separators=(",", ":"))),
        "[%s] INFO: [Gateway] Request | Context: %s" % (
            iso(now - timedelta(minutes=adjust(114))),
            json.dumps({"sessionId": NOISE_SESSION, "url": "https://api.synthetic.example/v1/responses"},
                       separators=(",", ":"))),
    ]
    lines.extend(droid_line(now, adjust(record[2]), record) for record in DROID_RECORDS)
    lines.append(droid_line(now, adjust(35), (
        "claude-sonnet-5", ZERO_SESSION, 35, 0, 0, 0, 0, 0, None)))
    droid_log = logs / "droid-log-single.log"
    droid_log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    projects = out / "claude-home" / "projects" / "now"
    projects.mkdir(parents=True, exist_ok=True)
    claude_lines = [
        json.dumps({"type": "user", "uuid": "u-now-user", "sessionId": CLAUDE_RECORDS[0][1],
                    "timestamp": iso(now - timedelta(minutes=adjust(31))),
                    "cwd": "/tmp/keysrs-fixture-now",
                    "message": {"role": "user", "content": "SYNTHETIC-CLAUDE-CONTENT"}},
                   separators=(",", ":")),
    ]
    claude_lines.extend(claude_line(index, now, adjust(record[2]), record)
                       for index, record in enumerate(CLAUDE_RECORDS, start=1))
    claude_log = projects / "session.jsonl"
    claude_log.write_text("\n".join(claude_lines) + "\n", encoding="utf-8")

    ages = [adjust(record[2]) for record in DROID_RECORDS] + [record[2] for record in CLAUDE_RECORDS]
    return {
        "now": now,
        "droid_log": droid_log,
        "claude_log": claude_log,
        "droid_totals": droid_totals(),
        "claude_totals": claude_totals(),
        "merged_totals": merged_totals(),
        "youngest_age_minutes": min(ages),
        "oldest_age_minutes": max(ages),
        "clamped": clamped,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Write synthetic Droid and Claude Code homes dated a few minutes ago, "
                    "with the totals the dashboard should show for them.")
    parser.add_argument("--out", required=True,
                        help="directory to create droid-home/ and claude-home/ under")
    args = parser.parse_args(argv)
    info = write(args.out)
    out = Path(args.out)

    print("Wrote %s (%d usage records, plus one zero-token and two non-usage records)"
          % (info["droid_log"], len(DROID_RECORDS)))
    print("Wrote %s (%d assistant record)" % (info["claude_log"], len(CLAUDE_RECORDS)))
    print("Records are %.0f-%.0f minutes old: today, this week, this month and the Droid 5-hour"
          % (info["youngest_age_minutes"], info["oldest_age_minutes"]))
    print("window all hold them.")
    if info["clamped"]:
        print("The ages were clamped so every record stays after today's local midnight, so a"
              " run just after midnight keeps Today and Week populated too.")
    else:
        print("Rerun later if the local clock sits inside that span of a day, week or month"
              " boundary.")
    print()
    print("Expected per-model Droid totals (droid-local rule: input + cache read"
          " + cache write + output + reasoning):")
    for model, total in info["droid_totals"].items():
        print("  %-16s %7d" % (model, total))
    print("Expected Claude Code totals (claude-local rule: input + output + cache):")
    for model, total in info["claude_totals"].items():
        print("  %-16s %7d" % (model, total))
    print("Expected Chart rows (range=month, source=all, by=model; each record under its"
          " own tool's rule, same model id merged across tools):")
    for model, total in info["merged_totals"].items():
        print("  %-16s %7d" % (model, total))
    for model in sorted(set(info["droid_totals"]) & set(info["claude_totals"])):
        print("  %s: %d (droid-local) + %d (claude-local) = %d merged, one series"
              % (model, info["droid_totals"][model], info["claude_totals"][model],
                 info["merged_totals"][model]))
    print()
    print("Point an isolated dashboard at it (temp KEYS_CATALOG, never the real one):")
    print("  KEYS_DROID_HOME=%s" % (out / "droid-home"))
    print("  CLAUDE_CONFIG_DIR=%s" % (out / "claude-home"))
    return info


if __name__ == "__main__":
    main()
