# Self-hosted aggregate analytics collector

This opt-in collector accepts an aggregate report at `POST /v1/reports`. It stores only the report UUID, day, app version, macOS major version, architecture, a payload digest, aggregate count JSON, and receipt time. It does not persist IP addresses, User-Agent values, raw headers, request bodies, URLs, arbitrary properties, prompt content, or access logs.

Run locally:

```sh
python3 Analytics/collector.py serve --database /var/lib/keys-analytics/reports.sqlite
```

The default listener is `127.0.0.1:8787`. A non-loopback bind fails unless `--allow-nonloopback` is explicit. For deployment, keep the collector on loopback and place an HTTPS reverse proxy in front of it. Configure the proxy to accept only `POST /v1/reports`, cap request bodies at 16 KB, apply its own rate and connection limits, disable request/access logging for this route, and avoid forwarding unneeded headers. Hosting and certificates are intentionally not configured here.

The in-process limiter hashes the direct peer IP with an ephemeral key and never persists it. Behind a proxy, every request may share one peer IP, so application rate limits can unfairly group clients. Proxy-provided IP headers are deliberately ignored because unauthenticated forwarding is forgeable. Set trustworthy edge limits independently. Public aggregate metrics are also forgeable; they measure submitted opt-in events, not verified people.

Reports use exactly schema and consent version 1, a canonical UUID, a UTC day no more than seven days old, bounded platform fields, and 1–29 allowlisted positive integer counters. `optimizer_abstained` records disabled, unauthorized, or fallback abstention separately from `optimizer_failure`. Unknown fields, duplicate JSON keys, nonfinite values, free text, future days, old days, oversized/deep JSON, and unknown event names are rejected. Identical retries return 204; reuse of a report ID with different content returns 409.

SQLite rows are pruned after 30 days on startup, writes, summary reads, and every five minutes while serving. The collector caps stored reports, concurrent requests, global requests, and per-peer requests. These controls are intentionally small and operational rather than a complete production abuse defense.

Owner-only export is a local CLI; there is no public dashboard or summary endpoint:

```sh
python3 Analytics/collector.py summary --database /var/lib/keys-analytics/reports.sqlite > summary.json
```

The output groups summed event counts by day, app version, OS major version, architecture, and outcome/event name. These bounded platform dimensions are stored as typed columns. It has no unique-user metric because the product sends no persistent installation ID. Deletion tracking and per-user deletion are unavailable for the same reason. Operators must also apply retention to backups and ensure the reverse proxy does not retain request logs. This implementation has local automated HTTP tests; it is not claimed to be fully production tested.

Restrict the database directory and exported summaries to the collector owner at the filesystem level. The collector publishes no administrative endpoint or authentication secret; anyone with local database-file access can read the aggregate rows.

## Container deployment preparation

`compose.yaml` runs the collector as numeric uid/gid 10001 with no capabilities, a read-only root filesystem, bounded CPU/memory/PIDs, an internal network, and a persistent `analytics-data` volume. Caddy is the only published service. Its template enables automatic TLS only after `ANALYTICS_DOMAIN` is deliberately set, routes only the report and content-free health paths, caps request bodies, and contains no access-log directive. The collector retains its independent rate, concurrency, row, and body limits.

Before deployment, pin the Python and Caddy images to digests verified on the target registry, run the validator and tests, then run Docker Compose configuration/build checks on the actual host. Docker pulls/builds are intentionally absent from the offline validator.

The Caddy global logger excludes both `http.log.access` and `http.log.error`:
proxy failures otherwise log peer addresses and request headers even without
access logging. Header size and read/write/idle deadlines bound slow requests.
These directives were checked against the pinned Caddy source; Compose syntax
validation does not replace a container test on the chosen host.

Back up the private SQLite volume with a SQLite-consistent snapshot, such as the SQLite backup API or `sqlite3 reports.sqlite '.backup ...'`, rather than copying an active database file. Encrypt backups, restrict their access, and expire them within the same 30-day policy. Restore tests should use an isolated volume and must not send reports to a live endpoint.

```sh
python3 Analytics/validate_deployment.py
ANALYTICS_DOMAIN="$ANALYTICS_DOMAIN" docker compose -f Analytics/compose.yaml config --quiet
# Run only on the selected deployment host after image/digest review:
ANALYTICS_DOMAIN="$ANALYTICS_DOMAIN" docker compose -f Analytics/compose.yaml build
```

The hostname above is illustrative syntax, not a selected service endpoint. Keep the product endpoint unset until hosting and TLS are verified.
