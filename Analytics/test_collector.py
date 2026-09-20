import datetime as dt
import contextlib
import http.client
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collector.py"))
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


def report(**changes):
    value = {
        "schema_version": 1,
        "consent_version": 1,
        "report_id": str(uuid.uuid4()),
        "day": dt.datetime.now(dt.timezone.utc).date().isoformat(),
        "app_version": "1.2.3",
        "os_major": 15,
        "architecture": "arm64",
        "counts": {"view_usage": 2, "gateway_success": 1, "optimizer_abstained": 1},
    }
    value.update(changes)
    return value


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = collector.create_server("127.0.0.1", 0, Path(self.directory.name) / "reports.sqlite")
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
        self.assertEqual(self.post(b"{" + b"x" * 15_000), 400)
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
