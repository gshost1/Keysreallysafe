#!/usr/bin/env python3
"""Minimal self-hosted collector for opt-in aggregate Keys reports."""

import argparse
import collections
import datetime as dt
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import uuid

MAX_BODY = 32 * 1024
RETENTION_DAYS = 30
MAX_TOKENS = 10**12
MAX_USAGE_ROWS = 40
MAX_WINDOW_ROWS = 8
MAX_GATEWAY_ROWS = 40
# Benchmarks publish a cell only when this many reports contribute to it.
MIN_CELL = 50
BENCHMARK_DAYS = 28
BENCHMARK_TTL = 3600
COUNT_KEYS = frozenset(
    "view_usage view_chart view_keys view_optimizer key_add key_copy key_delete grant_create "
    "client_create ingest_success ingest_failure gateway_success gateway_failure optimizer_success "
    "optimizer_failure optimizer_abstained optimizer_cache_hit context_prepared context_unchanged context_empty "
    "context_failure gateway_lt_100ms gateway_lt_1s gateway_lt_10s gateway_gte_10s "
    "optimizer_lt_100ms optimizer_lt_1s optimizer_lt_10s optimizer_gte_10s".split()
)
FIELDS = frozenset(
    {"schema_version", "consent_version", "report_id", "day", "app_version", "os_major", "architecture", "counts",
     "usage", "windows", "gateway"}
)
# Each report array, its table, its text columns and its integer columns, in stored order.
ROW_TABLES = {
    "usage": ("usage_rows", ("source", "provider", "model"),
              ("prompts", "model_calls", "input_tokens", "output_tokens", "cached_read_tokens",
               "cache_creation_tokens", "reasoning_tokens")),
    "windows": ("window_rows", ("source", "window"), ("peak_percent", "hit_cap", "readings")),
    "gateway": ("gateway_rows", ("provider", "model"),
                ("requests", "ok", "failed", "input_tokens", "output_tokens", "cache_read_tokens",
                 "cache_write_tokens")),
}
SOURCES = ("claude_code", "codex", "grok")
WINDOWS = frozenset({("claude_code", "5h"), ("claude_code", "weekly"), ("claude_code", "fable"),
                     ("codex", "5h"), ("codex", "weekly"), ("grok", "weekly")})
# The ids in Web/providers.json, plus "other" for anything outside it
# (a custom provider id is user-chosen text). test_collector pins the match.
PROVIDERS = frozenset(
    "openai typesafe anthropic google xai mistral cohere deepseek moonshot zhipu dashscope minimax meta "
    "perplexity openrouter haimaker ramp-router requesty portkey helicone kilo vercel-ai-gateway "
    "cloudflare-ai-gateway groq together fireworks deepinfra cerebras sambanova novita hyperbolic nebius "
    "baseten replicate huggingface lambda featherless azure-openai bedrock vertex cloudflare-workers-ai "
    "watsonx nvidia elevenlabs deepgram assemblyai voyage jina tavily exa firecrawl brave-search fal "
    "stability experiential-labs other".split()
)
# Model ids are free text a provider or deployment can choose (fine-tunes and
# Azure deployments carry organisation names, often after a public prefix like
# "gpt-4-acme-prod"), so a model passes only if every part of it is public
# vocabulary: a known family first, then version numbers, sizes, dates or words
# from MODEL_WORDS. Anything else arrives as "unknown". ProductAnalytics.swift
# keeps the same lists.
MODEL = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
MODEL_FAMILIES = re.compile(
    r"(claude|gpt|o[1-9]|codex|grok|gemini|gemma|mistral|magistral|codestral|devstral|ministral|pixtral|llama|"
    r"deepseek|qwen|command|sonar|kimi|glm|minimax)[0-9]*\Z"
)
MODEL_NUMBER = re.compile(r"(?:[0-9]+[a-z]{0,2}|[a-z][0-9]+[a-z]?|[a-z])\Z")
MODEL_WORDS = frozenset(
    "sonnet opus haiku fable instant mini nano pro max plus turbo preview latest lite flash thinking reasoning "
    "non chat coder code codex instruct vision beta exp experimental fast high medium low small large tiny base "
    "audio realtime search deep research online spark astra xl xs ultra it embed embedding image omni oss "
    "maverick scout nemotron distill".split()
)
VERSION = re.compile(r"(?:development|[0-9]+(?:\.[0-9]+){1,3})\Z")


class InvalidReport(Exception):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidReport("duplicate_json_key")
        result[key] = value
    return result


def parse_report(body, today=None):
    if not body or len(body) > MAX_BODY:
        raise InvalidReport("invalid_size")
    try:
        value = json.loads(
            body,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(InvalidReport("nonfinite_number")),
        )
    except (UnicodeDecodeError, ValueError, RecursionError, InvalidReport) as error:
        if isinstance(error, InvalidReport):
            raise
        raise InvalidReport("invalid_json") from None
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise InvalidReport("invalid_fields")
    if type(value["schema_version"]) is not int or value["schema_version"] != 2:
        raise InvalidReport("invalid_schema_version")
    if type(value["consent_version"]) is not int or value["consent_version"] != 2:
        raise InvalidReport("invalid_consent_version")
    if not isinstance(value["report_id"], str):
        raise InvalidReport("invalid_report_id")
    try:
        identifier = str(uuid.UUID(value["report_id"]))
    except (ValueError, TypeError, AttributeError):
        raise InvalidReport("invalid_report_id") from None
    if identifier != value["report_id"]:
        raise InvalidReport("noncanonical_report_id")
    try:
        day = dt.date.fromisoformat(value["day"])
    except (ValueError, TypeError):
        raise InvalidReport("invalid_day") from None
    if day.isoformat() != value["day"]:
        raise InvalidReport("invalid_day")
    today = today or dt.datetime.now(dt.timezone.utc).date()
    age = (today - day).days
    if age < 0 or age > 7:
        raise InvalidReport("day_out_of_range")
    app_version = value["app_version"]
    if not isinstance(app_version, str) or len(app_version) > 32 or not VERSION.fullmatch(app_version):
        raise InvalidReport("invalid_app_version")
    if type(value["os_major"]) is not int or not 10 <= value["os_major"] <= 99:
        raise InvalidReport("invalid_os_major")
    if value["architecture"] not in ("arm64", "x86_64", "unknown"):
        raise InvalidReport("invalid_architecture")
    counts = value["counts"]
    # A day can carry usage without a feature event, so counts may be empty.
    if not isinstance(counts, dict) or len(counts) > len(COUNT_KEYS) or any(key not in COUNT_KEYS for key in counts):
        raise InvalidReport("invalid_counts")
    if any(type(count) is not int or not 1 <= count <= 1_000_000 for count in counts.values()):
        raise InvalidReport("invalid_count_value")
    usage = rows(value, "usage", MAX_USAGE_ROWS)
    for row in usage:
        if row["source"] not in SOURCES or row["provider"] not in PROVIDERS or not valid_model(row["model"]):
            raise InvalidReport("invalid_usage")
        integers(row, ROW_TABLES["usage"][2], "usage")
        if row["prompts"] < 1:
            raise InvalidReport("invalid_usage")
    unique(usage, ("source", "provider", "model"), "usage")
    windows = rows(value, "windows", MAX_WINDOW_ROWS)
    for row in windows:
        if (row["source"], row["window"]) not in WINDOWS or type(row["hit_cap"]) is not bool:
            raise InvalidReport("invalid_windows")
        peak, readings = row["peak_percent"], row["readings"]
        if type(peak) is not int or not 0 <= peak <= 100 or peak % 5:
            raise InvalidReport("invalid_windows")
        if type(readings) is not int or not 1 <= readings <= 24:
            raise InvalidReport("invalid_windows")
    unique(windows, ("source", "window"), "windows")
    gateway = rows(value, "gateway", MAX_GATEWAY_ROWS)
    for row in gateway:
        if row["provider"] not in PROVIDERS or not valid_model(row["model"]):
            raise InvalidReport("invalid_gateway")
        integers(row, ROW_TABLES["gateway"][2], "gateway")
        if row["requests"] < 1 or row["ok"] + row["failed"] != row["requests"]:
            raise InvalidReport("invalid_gateway")
    unique(gateway, ("provider", "model"), "gateway")
    return value


def valid_model(model):
    if model == "unknown":
        return True
    if not isinstance(model, str) or not MODEL.fullmatch(model):
        return False
    parts = re.split(r"[-._]", model.lower())
    return bool(MODEL_FAMILIES.fullmatch(parts[0])) and all(
        MODEL_NUMBER.fullmatch(part) or part in MODEL_WORDS for part in parts[1:]
    )


def rows(report, name, limit):
    value = report[name]
    _, text, numbers = ROW_TABLES[name]
    if not isinstance(value, list) or len(value) > limit:
        raise InvalidReport(f"invalid_{name}")
    for row in value:
        # Every row value is a scalar, so nested input is a clean 400 rather than an
        # unhashable lookup further down.
        if (not isinstance(row, dict) or set(row) != set(text + numbers)
                or any(isinstance(v, (dict, list)) for v in row.values())):
            raise InvalidReport(f"invalid_{name}")
    return value


def integers(row, fields, name):
    for field in fields:
        if type(row[field]) is not int or not 0 <= row[field] <= MAX_TOKENS:
            raise InvalidReport(f"invalid_{name}_value")


def unique(values, fields, name):
    keys = [tuple(row[field] for field in fields) for row in values]
    if len(set(keys)) != len(keys):
        raise InvalidReport(f"duplicate_{name}_row")


def day_tokens(source, row):
    """The dashboard's own rule (TokenTotals in Spend.swift): Claude Code's
    total includes cache reads and writes; Codex and Grok count reasoning."""
    if source == "claude_code":
        return row["input_tokens"] + row["output_tokens"] + row["cached_read_tokens"] + row["cache_creation_tokens"]
    return row["input_tokens"] + row["output_tokens"] + row["reasoning_tokens"]


def significant(value, digits=2):
    # Published cut points are rounded so no single report's exact total is echoed.
    if value <= 0:
        return 0
    scale = 10 ** max(0, len(str(value)) - digits)
    return (value + scale // 2) // scale * scale


def nearest_rank(values, percent):
    index = max(0, -(-percent * len(values) // 100) - 1)
    return values[min(index, len(values) - 1)]


def canonical(report):
    return json.dumps(report, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


class Store:
    def __init__(self, path, max_reports=1_000_000, now=None):
        self.path = str(path)
        self.max_reports = max_reports
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.lock = threading.Lock()
        self.connection = sqlite3.connect(self.path, check_same_thread=False, timeout=5)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS reports ("
            "report_id TEXT PRIMARY KEY, day TEXT NOT NULL, app_version TEXT NOT NULL, "
            "os_major INTEGER NOT NULL, architecture TEXT NOT NULL, payload_hash BLOB NOT NULL, "
            "counts_json TEXT NOT NULL, received_at INTEGER NOT NULL)"
        )
        self.connection.execute("CREATE INDEX IF NOT EXISTS reports_received_at ON reports(received_at)")
        for table, text, numbers in ROW_TABLES.values():
            columns = ", ".join([f"{c} TEXT NOT NULL" for c in ("report_id",) + text]
                                + [f"{c} INTEGER NOT NULL" for c in numbers])
            self.connection.execute(f"CREATE TABLE IF NOT EXISTS {table} ({columns})")
            self.connection.execute(f"CREATE INDEX IF NOT EXISTS {table}_report ON {table}(report_id)")
        self.connection.commit()
        self.prune()

    def prune(self):
        cutoff = int((self.now() - dt.timedelta(days=RETENTION_DAYS)).timestamp())
        with self.lock:
            self.connection.execute("DELETE FROM reports WHERE received_at < ?", (cutoff,))
            for table, _, _ in ROW_TABLES.values():
                self.connection.execute(f"DELETE FROM {table} WHERE report_id NOT IN (SELECT report_id FROM reports)")
            self.connection.commit()

    def insert(self, report):
        encoded = canonical(report)
        digest = hashlib.sha256(encoded).digest()
        received = int(self.now().timestamp())
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                existing = self.connection.execute(
                    "SELECT payload_hash FROM reports WHERE report_id = ?", (report["report_id"],)
                ).fetchone()
                if existing:
                    outcome = "duplicate" if hmac.compare_digest(existing[0], digest) else "conflict"
                else:
                    count = self.connection.execute("SELECT COUNT(*) FROM reports").fetchone()[0]
                    if count >= self.max_reports:
                        outcome = "full"
                    else:
                        self.connection.execute(
                            "INSERT INTO reports "
                            "(report_id, day, app_version, os_major, architecture, payload_hash, counts_json, received_at) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (
                                report["report_id"],
                                report["day"],
                                report["app_version"],
                                report["os_major"],
                                report["architecture"],
                                digest,
                                json.dumps(report["counts"], sort_keys=True, separators=(",", ":")),
                                received,
                            ),
                        )
                        for name, (table, text, numbers) in ROW_TABLES.items():
                            columns = ("report_id",) + text + numbers
                            self.connection.executemany(
                                f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                                [(report["report_id"],) + tuple(row[c] for c in text + numbers)
                                 for row in report[name]],
                            )
                        outcome = "accepted"
                self.connection.commit()
                return outcome
            except Exception:
                self.connection.rollback()
                raise

    def summary(self):
        result = collections.defaultdict(int)
        with self.lock:
            rows = self.connection.execute(
                "SELECT day, app_version, os_major, architecture, counts_json FROM reports"
            ).fetchall()
        for day, version, os_major, architecture, raw in rows:
            for outcome, count in json.loads(raw).items():
                result[(day, version, os_major, architecture, outcome)] += count
        return [
            {
                "day": day,
                "app_version": version,
                "os_major": os_major,
                "architecture": architecture,
                "outcome": outcome,
                "count": count,
            }
            for (day, version, os_major, architecture, outcome), count in sorted(result.items())
        ]

    def usage_summary(self):
        """Owner-only CLI totals per day, source, provider and model, plus the
        gateway's per-provider totals and plan-window cap hits."""
        with self.lock:
            usage = self.connection.execute(
                "SELECT r.day, u.source, u.provider, u.model, COUNT(*), SUM(u.prompts), SUM(u.model_calls), "
                "SUM(u.input_tokens), SUM(u.output_tokens), SUM(u.cached_read_tokens), "
                "SUM(u.cache_creation_tokens), SUM(u.reasoning_tokens) "
                "FROM usage_rows u JOIN reports r USING (report_id) GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4"
            ).fetchall()
            gateway = self.connection.execute(
                "SELECT r.day, g.provider, g.model, COUNT(*), SUM(g.requests), SUM(g.ok), SUM(g.failed), "
                "SUM(g.input_tokens), SUM(g.output_tokens), SUM(g.cache_read_tokens), SUM(g.cache_write_tokens) "
                "FROM gateway_rows g JOIN reports r USING (report_id) GROUP BY 1, 2, 3 ORDER BY 1, 2, 3"
            ).fetchall()
            windows = self.connection.execute(
                "SELECT r.day, w.source, w.window, COUNT(*), SUM(w.hit_cap), MAX(w.peak_percent) "
                "FROM window_rows w JOIN reports r USING (report_id) GROUP BY 1, 2, 3 ORDER BY 1, 2, 3"
            ).fetchall()
        usage_keys = ("day", "source", "provider", "model", "reports", "prompts", "model_calls", "input_tokens",
                      "output_tokens", "cached_read_tokens", "cache_creation_tokens", "reasoning_tokens")
        gateway_keys = ("day", "provider", "model", "reports", "requests", "ok", "failed", "input_tokens",
                        "output_tokens", "cache_read_tokens", "cache_write_tokens")
        window_keys = ("day", "source", "window", "reports", "hit_cap", "max_peak_percent")
        return {
            "usage": [dict(zip(usage_keys, row)) for row in usage],
            "gateway": [dict(zip(gateway_keys, row)) for row in gateway],
            "windows": [dict(zip(window_keys, row)) for row in windows],
        }

    def benchmarks(self):
        """Public aggregate table for the app's Compare line. Every cell needs
        MIN_CELL contributing reports; smaller cells are left out, not guessed."""
        today = self.now().date()
        since = (today - dt.timedelta(days=BENCHMARK_DAYS)).isoformat()
        with self.lock:
            usage = self.connection.execute(
                "SELECT u.report_id, u.source, u.input_tokens, u.output_tokens, u.cached_read_tokens, "
                "u.cache_creation_tokens, u.reasoning_tokens FROM usage_rows u JOIN reports r USING (report_id) "
                "WHERE r.day >= ?", (since,)
            ).fetchall()
            windows = self.connection.execute(
                "SELECT w.source, w.window, COUNT(*), SUM(w.hit_cap) FROM window_rows w "
                "JOIN reports r USING (report_id) WHERE r.day >= ? GROUP BY 1, 2 ORDER BY 1, 2", (since,)
            ).fetchall()
        per_day = collections.defaultdict(int)
        names = ("input_tokens", "output_tokens", "cached_read_tokens", "cache_creation_tokens", "reasoning_tokens")
        for report_id, source, *numbers in usage:
            per_day[(source, report_id)] += day_tokens(source, dict(zip(names, numbers)))
        daily = []
        for source in SOURCES:
            values = sorted(tokens for (name, _), tokens in per_day.items() if name == source)
            if len(values) >= MIN_CELL:
                daily.append({
                    "source": source,
                    "reports": len(values),
                    "percentiles": [significant(nearest_rank(values, percent)) for percent in range(5, 100, 5)],
                })
        caps = [
            {"source": source, "window": window, "reports": count, "hit_rate": round(hits / count, 3)}
            for source, window, count, hits in windows
            if count >= MIN_CELL
        ]
        return {
            "schema_version": 1,
            "generated_day": today.isoformat(),
            "window_days": BENCHMARK_DAYS,
            "min_reports": MIN_CELL,
            "daily_tokens": daily,
            "cap_hits": caps,
            # 0.9.1 decodes this key as required and cannot update itself, so it stays, empty.
            "models": [],
        }

    def close(self):
        with self.lock:
            self.connection.close()


class Limiter:
    def __init__(self, per_minute=20, global_per_minute=3_000, max_clients=10_000, now=time.monotonic):
        self.per_minute = per_minute
        self.global_per_minute = global_per_minute
        self.max_clients = max_clients
        self.now = now
        self.secret = secrets.token_bytes(32)
        self.clients = collections.OrderedDict()
        self.global_events = collections.deque()
        self.lock = threading.Lock()

    def allow(self, address):
        key = hmac.new(self.secret, address.encode("utf-8", "replace"), hashlib.sha256).digest()
        current = self.now()
        cutoff = current - 60
        with self.lock:
            while self.global_events and self.global_events[0] <= cutoff:
                self.global_events.popleft()
            events = self.clients.pop(key, collections.deque())
            while events and events[0] <= cutoff:
                events.popleft()
            if len(self.global_events) >= self.global_per_minute or len(events) >= self.per_minute:
                if events:
                    self.clients[key] = events
                    while len(self.clients) > self.max_clients:
                        self.clients.popitem(last=False)
                return False
            events.append(current)
            self.global_events.append(current)
            self.clients[key] = events
            while len(self.clients) > self.max_clients:
                self.clients.popitem(last=False)
            return True


class CollectorServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, limiter=None, max_concurrency=32, read_timeout=15, trust_cloudflare_ip=False):
        self.store = store
        self.trust_cloudflare_ip = trust_cloudflare_ip
        self.limiter = limiter or Limiter()
        self.slots = threading.BoundedSemaphore(max_concurrency)
        self.last_prune = time.monotonic()
        self.read_timeout = read_timeout
        self.benchmark_lock = threading.Lock()
        self.benchmark_body = None
        self.benchmark_at = 0.0
        super().__init__(address, Handler)

    def benchmarks(self):
        # Recomputed at most hourly; every request in between gets the same bytes.
        with self.benchmark_lock:
            if self.benchmark_body is None or time.monotonic() - self.benchmark_at >= BENCHMARK_TTL:
                self.benchmark_body = json.dumps(
                    self.store.benchmarks(), separators=(",", ":"), allow_nan=False
                ).encode("utf-8")
                self.benchmark_at = time.monotonic()
            return self.benchmark_body

    def handle_error(self, _request, _client_address):
        # The stdlib implementation prints the peer address and traceback.
        # Public request failures must not become an implicit access log.
        return

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def service_actions(self):
        if time.monotonic() - self.last_prune >= 300:
            self.store.prune()
            self.last_prune = time.monotonic()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(self.server.read_timeout)

    def log_message(self, _format, *_args):
        return

    def client_key(self):
        """The address the rate limiter counts (hashed, never stored). Behind a
        Cloudflare Tunnel every request arrives from cloudflared on loopback, so
        only then is CF-Connecting-IP used; from anywhere else it is forgeable."""
        peer = self.client_address[0]
        if self.server.trust_cloudflare_ip and is_loopback(peer):
            values = self.headers.get_all("CF-Connecting-IP", [])
            if len(values) == 1:
                try:
                    return str(ipaddress.ip_address(values[0].strip()))
                except ValueError:
                    pass
        return peer

    def reply(self, status):
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        if self.path != "/v1/reports":
            self.reply(HTTPStatus.NOT_FOUND)
            return
        if not self.server.limiter.allow(self.client_key()):
            self.reply(HTTPStatus.TOO_MANY_REQUESTS)
            return
        if self.headers.get("Transfer-Encoding") is not None:
            self.reply(HTTPStatus.BAD_REQUEST)
            return
        if self.headers.get("Content-Type") != "application/json":
            self.reply(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1:
            self.reply(HTTPStatus.BAD_REQUEST)
            return
        raw_length = lengths[0]
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            self.reply(HTTPStatus.LENGTH_REQUIRED)
            return
        if str(length) != raw_length or not 1 <= length <= MAX_BODY:
            self.reply(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length > MAX_BODY else HTTPStatus.BAD_REQUEST)
            return
        try:
            body = self.rfile.read(length)
        except OSError:
            self.reply(HTTPStatus.REQUEST_TIMEOUT)
            return
        if len(body) != length:
            self.reply(HTTPStatus.BAD_REQUEST)
            return
        try:
            report = parse_report(body)
        except InvalidReport:
            self.reply(HTTPStatus.BAD_REQUEST)
            return
        try:
            outcome = self.server.store.insert(report)
        except Exception:
            self.reply(HTTPStatus.SERVICE_UNAVAILABLE)
            return
        status = {
            "accepted": HTTPStatus.NO_CONTENT,
            "duplicate": HTTPStatus.NO_CONTENT,
            "conflict": HTTPStatus.CONFLICT,
            "full": HTTPStatus.SERVICE_UNAVAILABLE,
        }[outcome]
        self.reply(status)

    def do_GET(self):
        if self.path == "/v1/benchmarks":
            if not self.server.limiter.allow(self.client_key()):
                self.reply(HTTPStatus.TOO_MANY_REQUESTS)
                return
            try:
                body = self.server.benchmarks()
            except Exception:
                self.reply(HTTPStatus.SERVICE_UNAVAILABLE)
                return
            self.close_connection = True
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=3600")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        self.reply(HTTPStatus.NO_CONTENT if self.path == "/healthz" else HTTPStatus.NOT_FOUND)


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def create_server(bind, port, database, **kwargs):
    return CollectorServer((bind, port), Store(database, kwargs.pop("max_reports", 1_000_000)), **kwargs)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve = subparsers.add_parser("serve")
    serve.add_argument("--database", type=Path, required=True)
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8787)
    serve.add_argument("--allow-nonloopback", action="store_true")
    serve.add_argument("--max-reports", type=int, default=1_000_000)
    serve.add_argument(
        "--trust-cloudflare-ip", action="store_true",
        help="rate-limit by CF-Connecting-IP on loopback connections (only behind cloudflared)",
    )
    summary = subparsers.add_parser("summary")
    summary.add_argument("--database", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == "summary":
        store = Store(args.database)
        try:
            print(json.dumps({"counts": store.summary(), **store.usage_summary()},
                             separators=(",", ":"), allow_nan=False))
        finally:
            store.close()
        return 0
    if not is_loopback(args.bind) and not args.allow_nonloopback:
        parser.error("non-loopback bind requires --allow-nonloopback and an HTTPS reverse proxy")
    if not 1 <= args.port <= 65535 or not 1 <= args.max_reports <= 10_000_000:
        parser.error("port or max-reports out of range")
    server = create_server(args.bind, args.port, args.database, max_reports=args.max_reports,
                           trust_cloudflare_ip=args.trust_cloudflare_ip)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        server.store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
