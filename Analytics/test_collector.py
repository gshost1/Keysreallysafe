import datetime as dt
import contextlib
import http.client
import importlib.util
import io
import json
import re
from pathlib import Path
import socket
import tempfile
import threading
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collector.py"))
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


def usage_row(**changes):
    row = {
        "source": "claude_code", "provider": "anthropic", "model": "claude-fable-5-1", "prompts": 3,
        "model_calls": 9, "input_tokens": 100, "output_tokens": 200, "cached_read_tokens": 3000,
        "cache_creation_tokens": 400, "reasoning_tokens": 0,
    }
    row.update(changes)
    return row


def gateway_row(**changes):
    row = {
        "provider": "openrouter", "model": "unknown", "requests": 2, "ok": 1, "failed": 1,
        "input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 0, "cache_write_tokens": 0,
    }
    row.update(changes)
    return row


def window_row(**changes):
    row = {"source": "claude_code", "window": "5h", "peak_percent": 60, "hit_cap": False, "readings": 4}
    row.update(changes)
    return row


def report(**changes):
    value = {
        "schema_version": 2,
        "consent_version": 2,
        "report_id": str(uuid.uuid4()),
        "day": dt.datetime.now(dt.timezone.utc).date().isoformat(),
        "app_version": "1.2.3",
        "os_major": 15,
        "architecture": "arm64",
        "counts": {"view_usage": 2, "gateway_success": 1, "optimizer_abstained": 1},
        "usage": [usage_row()],
        "windows": [window_row()],
        "gateway": [gateway_row()],
    }
    value.update(changes)
    return value


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        # Tests post far more than one Mac would; the default limit has its own test.
        self.server = collector.create_server("127.0.0.1", 0, Path(self.directory.name) / "reports.sqlite",
                                              limiter=collector.Limiter(per_minute=10_000))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server.store.close()
        self.thread.join(timeout=2)
        self.directory.cleanup()

    def post(self, body, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        request_headers = {"Content-Type": "application/json"}
        request_headers.update(headers or {})
        connection.request("POST", "/v1/reports", body=body, headers=request_headers)
        response = connection.getresponse()
        status = response.status
        response.read()
        connection.close()
        return status

    def raw(self, request):
        with socket.create_connection(self.server.server_address, timeout=2) as connection:
            connection.sendall(request)
            chunks = []
            while True:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
        return b"".join(chunks)

    def test_accepts_retry_and_conflicts_on_changed_payload(self):
        value = report()
        body = json.dumps(value).encode()
        self.assertEqual(self.post(body), 204)
        self.assertEqual(self.post(body), 204)
        changed = dict(value, counts={"view_usage": 3})
        self.assertEqual(self.post(json.dumps(changed).encode()), 409)
        self.assertEqual(len(self.server.store.summary()), 3)

    def test_shared_golden_report_matches_the_app_schema(self):
        # Also decoded by ProductAnalyticsTests.swift; drift on either side fails a suite.
        body = (Path(__file__).resolve().parents[1] / "Fixtures" / "analytics" / "report-golden.json").read_bytes()
        value = collector.parse_report(body, today=dt.date(2026, 5, 19))
        self.assertEqual(set(value), set(collector.FIELDS))
        self.assertEqual(set(value["counts"]), set(collector.COUNT_KEYS))
        self.assertTrue(value["usage"] and value["windows"] and value["gateway"])
        self.assertEqual(self.server.store.insert(value), "accepted")
        self.assertEqual(self.server.store.insert(value), "duplicate")

    def test_rejects_unknowns_bool_bad_days_and_free_text(self):
        tomorrow = (dt.datetime.now(dt.timezone.utc).date() + dt.timedelta(days=1)).isoformat()
        old = (dt.datetime.now(dt.timezone.utc).date() - dt.timedelta(days=8)).isoformat()
        invalid = [
            report(extra="no"),
            report(os_major=True),
            report(day=tomorrow),
            report(day=old),
            report(app_version="release candidate"),
            report(app_version="1"),
            report(app_version="1.2.3.4.5"),
            report(report_id=str(uuid.uuid4()).upper()),
            report(counts={"unknown": 1}),
            report(counts={"view_usage": True}),
            report(counts={"view_usage": 0}),
            report(schema_version=1),
            report(consent_version=1),
            report(usage=[usage_row(extra=1)]),
            report(usage=[usage_row(source="cursor")]),
            report(usage=[usage_row(provider="acme-internal")]),
            report(usage=[usage_row(model="ft:gpt-4o:acme:secret:1")]),
            report(usage=[usage_row(model="acme-prod-deployment")]),
            report(usage=[usage_row(model="claude-" + "x" * 64)]),
            report(usage=[usage_row(model="gpt-4-acmecorp-prod")]),
            report(usage=[usage_row(prompts=0)]),
            report(usage=[usage_row(input_tokens=10**12 + 1)]),
            report(usage=[usage_row(output_tokens=-1)]),
            report(usage=[usage_row(output_tokens=1.5)]),
            report(usage=[usage_row(), usage_row()]),
            report(usage=[usage_row(model=f"claude-{index}") for index in range(41)]),
            report(windows=[window_row(window="monthly")]),
            report(windows=[window_row(source="grok", window="5h")]),
            report(windows=[window_row(peak_percent=62)]),
            report(windows=[window_row(peak_percent=105)]),
            report(windows=[window_row(hit_cap=1)]),
            report(windows=[window_row(readings=0)]),
            report(windows=[window_row(), window_row()]),
            report(gateway=[gateway_row(ok=2)]),
            report(gateway=[gateway_row(requests=0, ok=0, failed=0)]),
            report(gateway=[gateway_row(key="prod-key")]),
            report(gateway=[gateway_row(model="my-azure-deployment")]),
        ]
        for value in invalid:
            with self.subTest(value=value):
                self.assertEqual(self.post(json.dumps(value).encode()), 400)

    def test_rejects_duplicate_keys_nonfinite_depth_and_oversize(self):
        value = report()
        raw = json.dumps(value)[:-1] + ',"day":"' + value["day"] + '"}'
        self.assertEqual(self.post(raw.encode()), 400)
        raw = json.dumps(value).replace('"os_major": 15', '"os_major": NaN')
        self.assertEqual(self.post(raw.encode()), 400)
        self.assertEqual(self.post(b"[" * 8 + b"0" + b"]" * 8), 400)
        self.assertEqual(self.post(b"{" + b"x" * 30_000), 400)
        self.assertEqual(self.post(b"x" * (collector.MAX_BODY + 1)), 413)

    def test_http_framing_content_type_and_path(self):
        body = json.dumps(report()).encode()
        duplicate_length = (
            b"POST /v1/reports HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\nContent-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        self.assertEqual(int(self.raw(duplicate_length).split(b" ", 2)[1]), 400)
        transfer_encoding = (
            b"POST /v1/reports HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        )
        self.assertEqual(int(self.raw(transfer_encoding).split(b" ", 2)[1]), 400)
        self.assertEqual(self.post(body, {"Content-Type": "text/plain"}), 415)
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request("POST", "/wrong", body=body, headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(response.status, 404)
        response.read()
        connection.close()
        pipelined = (
            b"POST /wrong HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody"
            b"GET /v1/reports HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        raw_response = self.raw(pipelined)
        self.assertEqual(raw_response.count(b"HTTP/1.1"), 1)
        self.assertIn(b"Connection: close", raw_response)

    def test_no_public_reads_or_header_persistence(self):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request("GET", "/v1/reports", headers={"User-Agent": "private-agent"})
        response = connection.getresponse()
        self.assertEqual(response.status, 404)
        response.read()
        connection.close()
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request("GET", "/healthz")
        response = connection.getresponse()
        self.assertEqual(response.status, 204)
        self.assertEqual(response.read(), b"")
        connection.close()
        self.assertEqual(self.post(json.dumps(report()).encode(), {"User-Agent": "private-agent"}), 204)
        columns = [row[1] for row in self.server.store.connection.execute("PRAGMA table_info(reports)")]
        self.assertEqual(
            columns,
            ["report_id", "day", "app_version", "os_major", "architecture", "payload_hash", "counts_json", "received_at"],
        )

    def test_retention_storage_cap_and_summary_grouping(self):
        self.server.store.max_reports = 1
        self.assertEqual(self.post(json.dumps(report(counts={"view_usage": 3})).encode()), 204)
        self.assertEqual(self.post(json.dumps(report()).encode()), 503)
        summary = self.server.store.summary()
        self.assertEqual(summary[0]["outcome"], "view_usage")
        self.assertEqual(summary[0]["count"], 3)
        self.assertEqual(summary[0]["os_major"], 15)
        self.assertEqual(summary[0]["architecture"], "arm64")
        cutoff = int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=31)).timestamp())
        self.server.store.connection.execute("UPDATE reports SET received_at = ?", (cutoff,))
        self.server.store.connection.commit()
        self.assertEqual(self.server.store.summary(), [])

    def test_accepts_empty_counts_and_arrays_and_stores_rows(self):
        self.assertEqual(self.post(json.dumps(report(counts={}, usage=[], windows=[], gateway=[])).encode()), 204)
        self.assertEqual(self.post(json.dumps(report(counts={})).encode()), 204)
        summary = self.server.store.usage_summary()
        self.assertEqual(summary["usage"][0]["model"], "claude-fable-5-1")
        self.assertEqual(summary["usage"][0]["cached_read_tokens"], 3000)
        self.assertEqual(summary["gateway"][0]["failed"], 1)
        self.assertEqual(summary["windows"][0]["max_peak_percent"], 60)
        cutoff = int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=31)).timestamp())
        self.server.store.connection.execute("UPDATE reports SET received_at = ?", (cutoff,))
        self.server.store.connection.commit()
        self.assertEqual(self.server.store.usage_summary(), {"usage": [], "gateway": [], "windows": []})
        for table in ("usage_rows", "window_rows", "gateway_rows"):
            self.assertEqual(self.server.store.connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0)

    def test_provider_allowlist_matches_the_shipped_catalog(self):
        catalog = json.loads((Path(__file__).resolve().parents[1] / "Fixtures" / "providers.json").read_text())
        self.assertEqual(collector.PROVIDERS, {entry["id"] for entry in catalog["providers"]} | {"other"})

    def get(self, path):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request("GET", path)
        response = connection.getresponse()
        result = (response.status, response.getheader("Cache-Control"), response.read())
        connection.close()
        return result

    def test_benchmarks_publish_only_cells_with_enough_reports(self):
        status, cache, body = self.get("/v1/benchmarks")
        self.assertEqual(status, 200)
        self.assertEqual(cache, "public, max-age=3600")
        empty = json.loads(body)
        self.assertEqual((empty["daily_tokens"], empty["cap_hits"], empty["models"]), ([], [], []))
        self.assertEqual(empty["min_reports"], collector.MIN_CELL)
        store = self.server.store
        for index in range(collector.MIN_CELL):
            hit = index < 10
            value = report(
                counts={},
                usage=[
                    usage_row(input_tokens=0, output_tokens=0, cached_read_tokens=(index + 1) * 1_000_000,
                              cache_creation_tokens=0),
                    usage_row(source="codex", provider="openai", model="gpt-6-astra", input_tokens=10,
                              output_tokens=0, cached_read_tokens=0, cache_creation_tokens=0, reasoning_tokens=5),
                ][: 1 if index % 2 else 2],
                windows=[window_row(hit_cap=hit, peak_percent=100 if hit else 50)],
                gateway=[],
            )
            self.assertEqual(store.insert(collector.parse_report(json.dumps(value).encode())), "accepted")
        table = store.benchmarks()
        self.assertEqual([row["source"] for row in table["daily_tokens"]], ["claude_code"])
        claude = table["daily_tokens"][0]
        self.assertEqual(claude["reports"], collector.MIN_CELL)
        self.assertEqual(len(claude["percentiles"]), 19)
        self.assertEqual(claude["percentiles"][0], 3_000_000)
        self.assertEqual(claude["percentiles"][9], 25_000_000)
        self.assertEqual(claude["percentiles"], sorted(claude["percentiles"]))
        self.assertEqual(table["cap_hits"], [{"source": "claude_code", "window": "5h", "reports": 50, "hit_rate": 0.2}])
        # Codex appeared in 25 reports, under the minimum: no daily cell and no model share.
        self.assertEqual(table["models"], [{"source": "claude_code", "model": "claude-fable-5-1", "share": 1.0}])
        # The published response is cached, so it still reads as empty until the TTL passes.
        self.assertEqual(json.loads(self.get("/v1/benchmarks")[2])["daily_tokens"], [])
        self.server.benchmark_at -= collector.BENCHMARK_TTL
        self.assertEqual(json.loads(self.get("/v1/benchmarks")[2])["daily_tokens"], table["daily_tokens"])
        self.assertLess(len(self.get("/v1/benchmarks")[2]), 32 * 1024)

    def test_model_vocabulary_rejects_names_hidden_behind_public_prefixes(self):
        for model in ["claude-fable-5-1", "claude-opus-4-1-20250805", "gpt-4o-mini", "gpt-5.1-codex-max", "o3-mini",
                      "o4-mini-high", "grok-code-fast-1", "grok-4-fast-reasoning", "gemini-2.5-flash-lite",
                      "llama3.1-70b-instruct", "qwen3-coder-480b", "gpt-oss-120b", "GPT-6-astra-pro", "unknown"]:
            self.assertTrue(collector.valid_model(model), model)
        for model in ["gpt-4-acmecorp-prod", "claude-widgetco-eval", "ft:gpt-4o:acme:x:1", "acme-gpt-4",
                      "gpt-4o-mini-johnsmith", "gpt--", "", None, 7]:
            self.assertFalse(collector.valid_model(model), model)

    def test_model_rule_matches_the_app(self):
        swift = (Path(__file__).resolve().parents[1] / "Sources" / "KeysCore" / "ProductAnalytics.swift").read_text()
        words = swift[swift.index("static let modelWords"):swift.index(").split(separator", swift.index("static let modelWords"))]
        self.assertEqual(set(" ".join(re.findall(r'"([^"]*)"', words)).split()), collector.MODEL_WORDS)
        families = re.search(r'static let modelFamilies = "\^(.*)\$"', swift).group(1)
        self.assertEqual(families + r"\Z", collector.MODEL_FAMILIES.pattern)

    def test_oversized_integer_literal_is_a_clean_400(self):
        body = json.dumps(report()).replace('"os_major": 15', '"os_major": ' + "9" * 5000).encode()
        self.assertEqual(self.post(body), 400)

    def test_cloudflare_ip_is_used_only_when_trusted_and_from_loopback(self):
        self.server.limiter = collector.Limiter(per_minute=1, global_per_minute=100)
        self.server.trust_cloudflare_ip = True
        first = {"CF-Connecting-IP": "203.0.113.7"}
        self.assertEqual(self.post(json.dumps(report()).encode(), first), 204)
        self.assertEqual(self.post(json.dumps(report()).encode(), first), 429)
        self.assertEqual(self.post(json.dumps(report()).encode(), {"CF-Connecting-IP": "203.0.113.8"}), 204)
        self.assertEqual(self.post(json.dumps(report()).encode(), {"CF-Connecting-IP": "not-an-ip"}), 204)
        self.server.trust_cloudflare_ip = False
        self.assertEqual(self.post(json.dumps(report()).encode(), {"CF-Connecting-IP": "203.0.113.9"}), 429)

    def test_significant_rounding_and_nearest_rank(self):
        self.assertEqual(collector.significant(0), 0)
        self.assertEqual(collector.significant(7), 7)
        self.assertEqual(collector.significant(1_234_567), 1_200_000)
        self.assertEqual(collector.significant(1_250_000), 1_300_000)
        self.assertEqual(collector.nearest_rank([1, 2, 3, 4], 50), 2)
        self.assertEqual(collector.nearest_rank([1, 2, 3, 4], 95), 4)
        self.assertEqual(collector.nearest_rank([9], 5), 9)

    def test_rate_limit_and_nonloopback_guard(self):
        self.server.limiter = collector.Limiter(per_minute=1, global_per_minute=10)
        self.assertEqual(self.post(json.dumps(report()).encode()), 204)
        self.assertEqual(self.post(json.dumps(report()).encode()), 429)
        self.assertTrue(collector.is_loopback("127.0.0.1"))
        self.assertFalse(collector.is_loopback("0.0.0.0"))

    def test_limiter_rejection_does_not_grow_client_map(self):
        limiter = collector.Limiter(per_minute=10, global_per_minute=1, max_clients=2, now=lambda: 10)
        self.assertTrue(limiter.allow("192.0.2.1"))
        for suffix in range(2, 20):
            self.assertFalse(limiter.allow(f"192.0.2.{suffix}"))
        self.assertLessEqual(len(limiter.clients), 2)

    def test_operational_failures_do_not_log_peer_body_or_traceback(self):
        captured = io.StringIO()
        original_insert = self.server.store.insert
        self.server.store.insert = lambda _report: (_ for _ in ()).throw(RuntimeError("private-db-detail"))
        try:
            with contextlib.redirect_stderr(captured):
                self.assertEqual(self.post(json.dumps(report()).encode()), 503)
                self.server.read_timeout = 0.05
                with socket.create_connection(self.server.server_address, timeout=2) as connection:
                    connection.sendall(
                        b"POST /v1/reports HTTP/1.1\r\nHost: localhost\r\n"
                        b"Content-Type: application/json\r\nContent-Length: 100\r\n\r\nprivate-body"
                    )
                    response = connection.recv(4096)
                self.assertIn(b" 408 ", response)
        finally:
            self.server.store.insert = original_insert
        output = captured.getvalue()
        self.assertNotIn("127.0.0.1", output)
        self.assertNotIn("private-body", output)
        self.assertNotIn("private-db-detail", output)
        self.assertNotIn("Traceback", output)


if __name__ == "__main__":
    unittest.main()
