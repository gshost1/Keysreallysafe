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

MAX_BODY = 16 * 1024
MAX_DEPTH = 6
RETENTION_DAYS = 30
COUNT_KEYS = frozenset(
    "view_usage view_chart view_keys view_optimizer key_add key_copy key_delete grant_create "
    "client_create ingest_success ingest_failure gateway_success gateway_failure optimizer_success "
    "optimizer_failure optimizer_abstained optimizer_cache_hit context_prepared context_unchanged context_empty "
    "context_failure gateway_lt_100ms gateway_lt_1s gateway_lt_10s gateway_gte_10s "
    "optimizer_lt_100ms optimizer_lt_1s optimizer_lt_10s optimizer_gte_10s".split()
)
FIELDS = frozenset(
    {"schema_version", "consent_version", "report_id", "day", "app_version", "os_major", "architecture", "counts"}
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


def depth(value, level=1):
    if level > MAX_DEPTH:
        raise InvalidReport("json_too_deep")
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise InvalidReport("invalid_json_key")
            depth(child, level + 1)
    elif isinstance(value, list):
        for child in value:
            depth(child, level + 1)


def parse_report(body, today=None):
    if not body or len(body) > MAX_BODY:
        raise InvalidReport("invalid_size")
    try:
        value = json.loads(
            body,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(InvalidReport("nonfinite_number")),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, InvalidReport) as error:
        if isinstance(error, InvalidReport):
            raise
        raise InvalidReport("invalid_json") from None
    depth(value)
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise InvalidReport("invalid_fields")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise InvalidReport("invalid_schema_version")
    if type(value["consent_version"]) is not int or value["consent_version"] != 1:
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
    if not isinstance(counts, dict) or not 1 <= len(counts) <= len(COUNT_KEYS) or any(key not in COUNT_KEYS for key in counts):
        raise InvalidReport("invalid_counts")
    if any(type(count) is not int or not 1 <= count <= 1_000_000 for count in counts.values()):
        raise InvalidReport("invalid_count_value")
    return value


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
        columns = {row[1] for row in self.connection.execute("PRAGMA table_info(reports)")}
        if "os_major" not in columns:
            self.connection.execute("ALTER TABLE reports ADD COLUMN os_major INTEGER NOT NULL DEFAULT 10")
        if "architecture" not in columns:
            self.connection.execute("ALTER TABLE reports ADD COLUMN architecture TEXT NOT NULL DEFAULT 'unknown'")
        self.connection.execute("CREATE INDEX IF NOT EXISTS reports_received_at ON reports(received_at)")
        self.connection.commit()
        self.prune()

    def prune(self):
        cutoff = int((self.now() - dt.timedelta(days=RETENTION_DAYS)).timestamp())
        with self.lock:
            self.connection.execute("DELETE FROM reports WHERE received_at < ?", (cutoff,))
            self.connection.commit()

    def insert(self, report):
        encoded = canonical(report)
        digest = hashlib.sha256(encoded).digest()
        received = int(self.now().timestamp())
        cutoff = int((self.now() - dt.timedelta(days=RETENTION_DAYS)).timestamp())
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                self.connection.execute("DELETE FROM reports WHERE received_at < ?", (cutoff,))
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
                        outcome = "accepted"
                self.connection.commit()
                return outcome
            except Exception:
                self.connection.rollback()
                raise

    def summary(self):
        self.prune()
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

    def close(self):
        with self.lock:
            self.connection.close()


class Limiter:
    def __init__(self, per_minute=120, global_per_minute=3_000, max_clients=10_000, now=time.monotonic):
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

    def __init__(self, address, store, limiter=None, max_concurrency=32, read_timeout=15):
        self.store = store
        self.limiter = limiter or Limiter()
        self.slots = threading.BoundedSemaphore(max_concurrency)
        self.last_prune = time.monotonic()
        self.read_timeout = read_timeout
        super().__init__(address, Handler)

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
        if not self.server.limiter.allow(self.client_address[0]):
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
    summary = subparsers.add_parser("summary")
    summary.add_argument("--database", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == "summary":
        store = Store(args.database)
        try:
            print(json.dumps(store.summary(), separators=(",", ":"), allow_nan=False))
        finally:
            store.close()
        return 0
    if not is_loopback(args.bind) and not args.allow_nonloopback:
        parser.error("non-loopback bind requires --allow-nonloopback and an HTTPS reverse proxy")
    if not 1 <= args.port <= 65535 or not 1 <= args.max_reports <= 10_000_000:
        parser.error("port or max-reports out of range")
    server = create_server(args.bind, args.port, args.database, max_reports=args.max_reports)
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
