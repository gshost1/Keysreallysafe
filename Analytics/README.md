# Self-hosted aggregate analytics collector

This opt-in collector accepts an aggregate report at `POST /v1/reports` and publishes a comparison table at `GET /v1/benchmarks`. It stores only the report UUID, day, app version, macOS major version, architecture, a payload digest, aggregate count JSON, receipt time, and the report's usage, gateway and plan-window rows (tool, provider, public model name and totals). It does not persist IP addresses, User-Agent values, raw headers, request bodies, URLs, arbitrary properties, prompt content, or access logs.

Run locally:

```sh
python3 Analytics/collector.py serve --database /var/lib/keys-analytics/reports.sqlite
```

The default listener is `127.0.0.1:8787`. A non-loopback bind fails unless `--allow-nonloopback` is explicit. For deployment, keep the collector on loopback and place an HTTPS reverse proxy in front of it. Configure the proxy to accept only `POST /v1/reports`, `GET /v1/benchmarks` and `GET /healthz`, cap request bodies at 32 KB, apply its own rate and connection limits, disable request/access logging for this route, and avoid forwarding unneeded headers. Hosting and certificates are intentionally not configured here.

The in-process limiter (20 requests per minute per client) hashes the client IP with an ephemeral key and never persists it. With `--trust-cloudflare-ip`, a request arriving from loopback (that is, from cloudflared) is counted by its `CF-Connecting-IP` header instead of the shared tunnel address; without the flag, or from any other peer, the header is ignored. Behind a proxy, every request may share one peer IP, so application rate limits can unfairly group clients. Proxy-provided IP headers are deliberately ignored because unauthenticated forwarding is forgeable. Set trustworthy edge limits independently. Public aggregate metrics are also forgeable; they measure submitted opt-in events, not verified people.

The report schema, its limits and its exclusions are described once, in the "Collected fields" and "Compare" sections of `docs/product-analytics.md`; the collector rejects anything outside them. It also rejects duplicate JSON keys, nonfinite values, nested row values and bodies over 32 KB. Identical retries return 204; reuse of a report ID with different content returns 409.

SQLite rows are pruned after 30 days on startup and every five minutes while serving (the summary CLI prunes when it opens the database). The collector caps stored reports, concurrent requests, global requests, and per-peer requests. These controls are intentionally small and operational rather than a complete production abuse defense.

`/v1/benchmarks` is the only public read. It is recomputed at most hourly from reports of the last 28 days and publishes a cell (daily-token percentiles per tool, cap-hit rate per plan window) only when at least 50 reports contribute; percentiles are rounded to two significant figures. The `models` array is always empty; it stays because 0.9.1 requires the key when decoding.

Owner-only export is a local CLI; there is no public dashboard or per-report endpoint:

```sh
python3 Analytics/collector.py summary --database /var/lib/keys-analytics/reports.sqlite > summary.json
```

The output has `counts` (summed event counts by day, app version, OS major version, architecture and event name) plus `usage`, `gateway` and `windows` totals by day, tool, provider and model. These bounded platform dimensions are stored as typed columns. It has no unique-user metric because the product sends no persistent installation ID. Deletion tracking and per-user deletion are unavailable for the same reason. Operators must also apply retention to backups and ensure the reverse proxy does not retain request logs. This implementation has local automated HTTP tests; it is not claimed to be fully production tested.

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

## Live deployment (2026-09-23)

The collector runs on the home server `keysrs-server` (Ubuntu) as the systemd
service `keysrs-analytics` on `127.0.0.1:8787`, database
`/var/lib/keys-analytics/reports.sqlite`, and is reached only through the
Cloudflare Tunnel `keysrs-analytics` at `https://analytics.keysrs.com`. The
tunnel's ingress (`/etc/cloudflared/config.yml`) routes exactly
`^/v1/reports$`, `^/v1/benchmarks$` and `^/healthz$`; everything else gets 404
at the edge. cloudflared runs with `loglevel: warn`, so request lines are not
logged. The service runs with `--trust-cloudflare-ip`.
