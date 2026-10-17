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
EPILOG = ("Run it where the usage happened, not on the Mac that runs Keysrs: that Mac's own logs are already "
          "counted, so importing an export of them would double-count. Keysrs skips rows it already has "
          "locally, but do not rely on that. Records with a malformed token count, id or timestamp are "
          "dropped and counted on stderr.")
import argparse
import glob
import json
import os
import re
import stat
import sys
from pathlib import Path

# Byte-for-byte the record DroidIngest.swift parses; every other droid log line is skipped.
DROID_MARKER = "] INFO: [Agent] Streaming result | Context: "
DROID_COUNTS = ("inputTokens", "cacheReadInputTokens", "cachedTokensWritten", "outputTokens", "reasoningTokens")
DROID_IDS = ("upstreamResponseId", "upstreamRequestId")
DROID_TAGS = ("modelId", "sessionId")
CLAUDE_USAGE = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
COMPLETION_USAGE = CLAUDE_USAGE + ("thinking_tokens",)


TOKEN_CAP = 10 ** 12
EPOCH_MS_CAP = 10 ** 14
ID_RE = re.compile(r"[A-Za-z0-9._:@/-]{1,128}")
# The instant a droid log line opens with and a Claude Code transcript stamps on a turn.
INSTANT_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})")


class Drop(Exception):
    """A usage record whose fields failed validation; it is counted and never exported."""


def pick_count(source, keys):
    """Token counts: plain ints in 0..TOKEN_CAP. A float, bool, string or out-of-range value
    would otherwise reach the importer's arithmetic, so the whole record is dropped."""
    out = {}
    for k in keys:
        if k not in source:
            continue
        v = source[k]
        if type(v) is not int or not 0 <= v <= TOKEN_CAP:
            raise Drop("token count")
        out[k] = v
    return out


def pick_id(source, keys):
    out = {}
    for k in keys:
        if k not in source:
            continue
        v = source[k]
        if type(v) is not str or not ID_RE.fullmatch(v):
            raise Drop("id")
        out[k] = v
    return out


def pick_time(source, key, epoch_ms=False):
    """An ISO instant string (Claude Code), or integer epoch milliseconds (stream-json)."""
    if key not in source:
        return {}
    v = source[key]
    if epoch_ms:
        if type(v) is not int or not 0 <= v <= EPOCH_MS_CAP:
            raise Drop("time")
    elif type(v) is not str or not INSTANT_RE.fullmatch(v):
        raise Drop("time")
    return {key: v}


def load(text):
    try:
        return json.loads(text)
    except (ValueError, RecursionError):
        return None


def droid_line(line):
    at = line.find(DROID_MARKER)
    if at < 0:
        return None
    record = load(line[at + len(DROID_MARKER):])
    if not isinstance(record, dict):
        return None
    # The bracketed instant in front of the marker is the only part of the prefix kept.
    stamp = line[1:at] if line.startswith("[") else ""
    if not INSTANT_RE.fullmatch(stamp):
        raise Drop("timestamp prefix")
    kept = pick_count(record, DROID_COUNTS)
    kept.update(pick_id(record, DROID_IDS))
    tags = record.get("tags")
    if isinstance(tags, dict):
        kept["tags"] = pick_id(tags, DROID_TAGS)
    return f"[{stamp}{DROID_MARKER}{json.dumps(kept, separators=(',', ':'))}"


def claude_line(line):
    if '"type":"assistant"' not in line and '"type": "assistant"' not in line:
        return None
    record = load(line)
    if not isinstance(record, dict) or record.get("type") != "assistant":
        return None
    message = record.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
        return None
    out = pick_id(record, ("sessionId", "requestId"))
    out.update(pick_time(record, "timestamp"))
    out["type"] = "assistant"
    out["message"] = pick_id(message, ("id", "model"))
    out["message"]["usage"] = pick_count(message["usage"], CLAUDE_USAGE)
    return json.dumps(out, separators=(",", ":"), allow_nan=False)


def completion_line(line):
    if '"completion"' not in line:
        return None
    record = load(line)
    if not isinstance(record, dict) or record.get("type") != "completion" or not isinstance(record.get("usage"), dict):
        return None
    # finalText is the model's closing message; it is never exported.
    out = pick_id(record, ("session_id",))
    out.update(pick_time(record, "timestamp", epoch_ms=True))
    out["type"] = "completion"
    out["usage"] = pick_count(record["usage"], COMPLETION_USAGE)
    return json.dumps(out, separators=(",", ":"), allow_nan=False)


def is_regular(path):
    """Checked with stat before open: opening a FIFO for reading blocks until a writer shows up."""
    try:
        return stat.S_ISREG(os.stat(path).st_mode)
    except OSError:
        return False


def read_lines(path):
    if not is_regular(path):
        print(f"skipped {path}: not a regular file", file=sys.stderr)
        return
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


def export(factory_home, claude_home, streams, out, drops=None):
    drops = {} if drops is None else drops
    counts = {"droid": 0, "claude": 0, "completion": 0}
    sources = (("droid", droid_line, droid_logs(factory_home)),
               ("claude", claude_line, claude_transcripts(claude_home)),
               ("completion", completion_line, streams))
    for kind, parse, paths in sources:
        for path in paths:
            for line in read_lines(path):
                try:
                    row = parse(line.rstrip("\n") if kind == "droid" else line)
                except Drop as drop:
                    drops[str(drop)] = drops.get(str(drop), 0) + 1
                    continue
                if row:
                    out.write(row + "\n")
                    counts[kind] += 1
    return counts


def fail(message):
    print(message, file=sys.stderr)
    return 2


def inside(path, folder):
    return os.path.commonpath([path, folder]) == folder


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], epilog=EPILOG)
    parser.add_argument("-o", "--output", required=True, help="file to write (usage lines only)")
    parser.add_argument("--factory-home", default=None,
                        help="droid's data folder (default ~/.factory); its logs/droid-log-single.log* are read. "
                             "Naming one that does not exist is an error")
    parser.add_argument("--claude-home", default=None,
                        help="Claude Code's folder (default $CLAUDE_CONFIG_DIR or ~/.claude); projects/**/*.jsonl are "
                             "read. Naming one that does not exist is an error")
    parser.add_argument("--no-claude", action="store_true", help="skip Claude Code transcripts")
    parser.add_argument("--no-droid", action="store_true", help="skip droid's log")
    parser.add_argument("--stream", action="append", default=[],
                        help="a droid -o stream-json capture; only its completion total is kept (repeatable)")
    args = parser.parse_args(argv)
    for flag, named in (("--factory-home", args.factory_home), ("--claude-home", args.claude_home)):
        if named is not None and not os.path.isdir(named):
            return fail(f"{flag} {named}: no such folder")
    for stream in args.stream:
        if not os.path.exists(stream):
            return fail(f"--stream {stream}: no such file")
        if not is_regular(stream):
            return fail(f"--stream {stream}: not a regular file")
    factory_home = args.factory_home or os.path.expanduser("~/.factory")
    claude_home = args.claude_home or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    factory_home = os.devnull if args.no_droid else factory_home
    claude_projects = os.path.realpath(os.path.join(claude_home, "projects"))
    claude_home = os.devnull if args.no_claude else claude_home

    target = os.path.realpath(args.output)
    inputs = [*droid_logs(factory_home), *claude_transcripts(claude_home), *args.stream]
    if inside(target, claude_projects):
        return fail(f"cannot write {args.output}: it is inside the Claude projects folder, which is read as input")
    for path in inputs:
        if os.path.realpath(path) == target or (os.path.exists(target) and os.path.samefile(path, target)):
            return fail(f"cannot write {args.output}: it is one of the input files")

    try:
        out = open(args.output, "w", encoding="utf-8")
    except OSError as error:
        return fail(f"cannot write {args.output}: {error.strerror or error}")
    drops = {}
    try:
        with out:
            counts = export(factory_home, claude_home, args.stream, out, drops)
    except OSError as error:
        try:
            os.unlink(args.output)
        except OSError:
            pass
        return fail(f"cannot write {args.output}: {error.strerror or error}")
    if drops:
        why = ", ".join(f"{n} with a bad {reason}" for reason, n in sorted(drops.items()))
        print(f"dropped {sum(drops.values())} record(s): {why}", file=sys.stderr)
    print(f"{args.output}: droid requests {counts['droid']}, claude requests {counts['claude']}, "
          f"droid session totals {counts['completion']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
