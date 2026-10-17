#!/usr/bin/env python3
"""Write the usage a cloud session spent as a small file Keysrs can import.

Run this where the usage happened — inside a Claude Code cloud session, or any machine that
ran droid — then bring the file to the Mac and run `keys usage import <file>` (or drop it into
the `imports/` folder beside the Keysrs catalog).

Only usage leaves: token counts, model ids, session and request ids, timestamps. Droid's log
holds hundreds of record types that carry message content, and Claude Code transcripts hold
prompts, code and tool output; none of that is copied. Each output line is rebuilt from an
allow-list of fields, so a field a tool adds later is dropped rather than exported.

Standard library only, so it runs in a bare container.
"""
import argparse
import glob
import json
import os
import re
import sys
from pathlib import Path

# Byte-for-byte the record DroidIngest.swift parses; every other droid log line is skipped.
DROID_MARKER = "] INFO: [Agent] Streaming result | Context: "
DROID_FIELDS = ("inputTokens", "cacheReadInputTokens", "cachedTokensWritten", "outputTokens",
                "reasoningTokens", "upstreamResponseId", "upstreamRequestId")
DROID_TAGS = ("modelId", "sessionId")
CLAUDE_USAGE = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
COMPLETION_USAGE = CLAUDE_USAGE + ("thinking_tokens",)


def pick(source, fields):
    return {k: source[k] for k in fields if k in source and isinstance(source[k], (int, float, str))}


def droid_line(line):
    at = line.find(DROID_MARKER)
    if at < 0:
        return None
    try:
        record = json.loads(line[at + len(DROID_MARKER):])
    except ValueError:
        return None
    if not isinstance(record, dict):
        return None
    kept = pick(record, DROID_FIELDS)
    tags = record.get("tags")
    if isinstance(tags, dict):
        kept["tags"] = pick(tags, DROID_TAGS)
    # The bracketed instant in front of the marker is the only part of the prefix kept.
    stamp = ""
    if line.startswith("[") and "]" in line[:at + 1]:
        stamp = line[1:line.index("]")]
    return f"[{stamp}{DROID_MARKER}{json.dumps(kept, separators=(',', ':'))}"


def claude_line(line):
    if '"type":"assistant"' not in line and '"type": "assistant"' not in line:
        return None
    try:
        record = json.loads(line)
    except ValueError:
        return None
    if not isinstance(record, dict) or record.get("type") != "assistant":
        return None
    message = record.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
        return None
    out = pick(record, ("sessionId", "requestId", "timestamp"))
    out["type"] = "assistant"
    out["message"] = pick(message, ("id", "model"))
    out["message"]["usage"] = pick(message["usage"], CLAUDE_USAGE)
    return json.dumps(out, separators=(",", ":"))


def completion_line(line):
    if '"completion"' not in line:
        return None
    try:
        record = json.loads(line)
    except ValueError:
        return None
    if not isinstance(record, dict) or record.get("type") != "completion" or not isinstance(record.get("usage"), dict):
        return None
    # finalText is the model's closing message; it is never exported.
    out = pick(record, ("session_id", "timestamp"))
    out["type"] = "completion"
    out["usage"] = pick(record["usage"], COMPLETION_USAGE)
    return json.dumps(out, separators=(",", ":"))


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            yield from handle
    except OSError as error:
        print(f"skipped {path}: {error.strerror}", file=sys.stderr)


def droid_logs(factory_home):
    """Dated rotations oldest first, then the active log; the same files DroidIngest reads."""
    logs = Path(factory_home) / "logs"
    if not logs.is_dir():
        return []
    rotated = sorted(p for p in logs.glob("droid-log-single.log.*")
                     if p.is_file() and re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.name.rsplit(".log.", 1)[1]))
    active = logs / "droid-log-single.log"
    return rotated + ([active] if active.is_file() else [])


def claude_transcripts(claude_home):
    projects = Path(claude_home) / "projects"
    if not projects.is_dir():
        return []
    return sorted(Path(p) for p in glob.glob(str(projects / "**" / "*.jsonl"), recursive=True))


def export(factory_home, claude_home, streams, out):
    counts = {"droid": 0, "claude": 0, "completion": 0}
    for path in droid_logs(factory_home):
        for line in read_lines(path):
            row = droid_line(line.rstrip("\n"))
            if row:
                out.write(row + "\n")
                counts["droid"] += 1
    for path in claude_transcripts(claude_home):
        for line in read_lines(path):
            row = claude_line(line)
            if row:
                out.write(row + "\n")
                counts["claude"] += 1
    for path in streams:
        for line in read_lines(path):
            row = completion_line(line)
            if row:
                out.write(row + "\n")
                counts["completion"] += 1
    return counts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("-o", "--output", required=True, help="file to write (usage lines only)")
    parser.add_argument("--factory-home", default=os.path.expanduser("~/.factory"),
                        help="droid's data folder (default ~/.factory); its logs/droid-log-single.log* are read")
    parser.add_argument("--claude-home", default=os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                        help="Claude Code's folder (default $CLAUDE_CONFIG_DIR or ~/.claude); projects/**/*.jsonl are read")
    parser.add_argument("--no-claude", action="store_true", help="skip Claude Code transcripts")
    parser.add_argument("--no-droid", action="store_true", help="skip droid's log")
    parser.add_argument("--stream", action="append", default=[],
                        help="a droid -o stream-json capture; only its completion total is kept (repeatable)")
    args = parser.parse_args(argv)
    with open(args.output, "w", encoding="utf-8") as out:
        counts = export(
            os.devnull if args.no_droid else args.factory_home,
            os.devnull if args.no_claude else args.claude_home,
            args.stream, out,
        )
    print(f"{args.output}: droid requests {counts['droid']}, claude requests {counts['claude']}, "
          f"droid session totals {counts['completion']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
