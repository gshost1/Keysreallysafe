# Optional product analytics ("share to compare")

Keysrs can send one aggregate report a day from users who explicitly opt in, and in return shows them a **Compare** line on the Usage page: how their typical day compares with everyone who shares. This is separate from the private usage meter. It does not turn prompt content or task history into a product dataset.

The destination is `https://analytics.keysrs.com/v1/reports`, served by `Analytics/collector.py` on a self-hosted server behind a Cloudflare Tunnel that routes only `/v1/reports`, `/v1/benchmarks` and `/healthz`. Collection is off by default.

## What users control

The first-launch welcome window asks once per consent version, with the box unticked. The dashboard's **Privacy** button shows the collector URL, the current preference, unsent reports (including what today's report would contain if the day ended now) and a downloadable preview. Changing the release's collector URL or consent/schema version invalidates the previous consent and discards unsent data. Usage from before opting in, or from before "discard unsent reports", is never summarized.

Turning analytics off stops new collection, clears unsent reports and the cached comparison table, and cancels an active upload. A request already received by the server cannot be recalled. The collector has no persistent account or device identifier with which to locate a person's historical reports.

## Collected fields (schema and consent version 2)

Every report contains only:

- Report schema and consent versions, a random report UUID (reused only when retrying that report), the UTC day summarized, app version, macOS major version and CPU architecture.
- `counts`: counts from a fixed set of event names (dashboard pane visits; key add/copy/delete and grant/client creation; ingestion and gateway outcomes; four gateway duration buckets). May be empty. The vocabulary still accepts the optimizer, context-pack and Optimizer pane counters that 0.9.0 and 0.9.1 recorded, so their stored reports stay valid; nothing records them since the optimizer was removed.
- `usage`: at most 40 rows, one per (tool, provider, model) with activity that day, from the local usage catalog: tool is `claude_code`, `codex` or `grok`; prompts, model calls, and input, output, cache-read, cache-write and reasoning token totals.
- `gateway`: at most 40 rows, one per (provider, model) the local gateway routed that day: requests, succeeded, failed, and token totals. Rows are per provider, never per key.
- `windows`: one row per plan window the app saw that day (Claude Code 5-hour, weekly and Fable; Codex 5-hour and weekly; Grok weekly): the peak percentage rounded to 5, whether it reached 100%, and how many UTC hours had a live reading.

Provider ids must be in the shipped provider catalog (`Fixtures/providers.json`); anything else, such as a custom provider name, is sent as `other`. Model ids must be public model names: charset `[A-Za-z0-9._-]`, at most 64 characters, a known family first (`claude`, `gpt`, `o3`, `grok`, `gemini`, `llama`, `qwen`, …) and every further part a version number, size, date or word from a fixed public vocabulary (`sonnet`, `mini`, `pro`, `codex`, `fast`, …). Anything else, including fine-tune ids and deployment names such as `gpt-4-acme-prod`, is sent as `unknown`. The app and the collector apply the same rule, and a test pins the two lists together. Every integer is between 0 and 10^12, and a report is at most 32 KiB.

There are no prompts, responses, raw error messages, key values or key names, project, session or agent names, paths, tool arguments, account IDs, persistent installation IDs, exact event timestamps or dollar amounts. Unknown fields, providers, models and event names are rejected by both the app and the collector.

The counters are operational, not task-quality labels. A gateway success means the provider answered with a success status; it says nothing about the answer. Nothing in these reports establishes net savings, active-user counts or retention.

## Compare

While sharing is on, the app downloads `GET /v1/benchmarks` from the same host at most once a day (one attempt per six hours), through the same ephemeral transport, and caches it in the local catalog. The request carries nothing about the user. The table contains, over the last 28 days of received reports: percentiles (5% steps, rounded to two significant figures) of daily tokens per tool, plan-window cap-hit rates, and model shares. A cell appears only when at least 50 reports contribute to it.

The app computes the comparison locally: this Mac's typical day is the median of its active days in the last seven closed UTC days, using the dashboard's own token rule (Claude Code includes cache reads and writes; Codex and Grok include reasoning). A tool without a published cell or without local activity gets no line; nothing is estimated. Reports are per day, not per person, so the line compares days ("more than 80% of shared days"), not users.

## Storage and delivery

Unsent reports, plan-window readings and consent live in the private local catalog under `product_analytics_v1`; the comparison table under `product_analytics_benchmarks`. This is aggregate metadata, not an encrypted vault archive.

The active UTC day's report stays local. When the day ends, the report is sealed once: its usage, gateway and window arrays are filled and never change again, so a retry sends identical bytes. The dashboard process checks about a minute after start and then every fifteen minutes, sending at most one day per check. Failed uploads wait fifteen minutes before retrying with the same report UUID. Reports older than seven days are discarded; at most eight UTC-day buckets are kept.

The transport uses HTTPS, an ephemeral URL session, no cookies or stored credentials, no redirects, a bounded response and short deadlines. Only a 204 acknowledges a report. Changing preferences needs no vault unlock or Touch ID.

The collector keeps received reports for 30 days and offers an owner-only local CLI summary. It does not store IP addresses, request logs, raw headers or raw bodies. Cloudflare necessarily sees the connection IP. Reports are not described as anonymous or end-to-end encrypted; public submissions can be forged, so they are not authoritative data.

## Changing the destination

`ProductAnalyticsConfiguration.endpoint` in `Sources/KeysCore/ProductAnalytics.swift` holds the HTTPS `/v1/reports` URL and `appVersion` the release version. Credentials, query strings and fragments are not supported. A new endpoint, schema or consent version requires a fresh opt-in. Before a release changes any of them, run a bounded end-to-end trial with synthetic reports on the deployed collector (delivery, retry deduplication, conflict, benchmarks) and delete the trial rows afterwards.

## Offline verification

```sh
swift test
python3 -m unittest Analytics/test_collector.py
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
node --check Web/analytics.js
node scripts/tests/test_analytics_ui.cjs
```

The last command requires Playwright and its Chromium browser in the Node environment. The repository pins Playwright 1.62.1 in `scripts/tests/package.json`; after `npm ci` there, run `npx --no-install playwright install chromium` in that directory and start the browser scripts with `NODE_PATH=scripts/tests/node_modules`, as CI does for this script and `scripts/tests/test_keys_dashboard_ui.cjs`. The schema shared by the app and the collector is pinned by the synthetic `Fixtures/analytics/report-golden.json`, which both the Swift and the collector tests parse, and both sides pin their provider allowlist to `Fixtures/providers.json`. Its API is a local synthetic fixture; it does not use the running Keys app or send reports externally. Swift tests use temporary catalogs, a fake transport and in-memory credentials. Collector tests use a temporary database and loopback HTTP sockets. Live deployment and Apple signing are separate validation steps.
