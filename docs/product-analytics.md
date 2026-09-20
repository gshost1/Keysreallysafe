# Optional product analytics

Keys can collect aggregate feature and reliability counts from users who explicitly opt in. This is separate from the private usage meter and encrypted Optimizer library. It does not turn local task history or prompt content into a product dataset.

The current build has **no configured destination**. Collection is off by default, the Privacy dialog cannot enable it, and no analytics upload can run. Hosting is a later step.

## What users control

The dashboard's **Privacy** button shows the collector URL, the current preference, unsent counters and a downloadable preview. The user must select **Enable product analytics** and save. Changing the release's collector URL or consent/schema version invalidates the previous consent and discards unsent data. Existing activity is never backfilled.

Turning analytics off stops new collection, clears unsent reports and cancels the dashboard's active upload. A request already received by the server cannot be recalled. The collector has no persistent account/device identifier with which to locate a person's historical reports.

## Collected fields

Every report contains only:

- Report schema and consent versions.
- A random report UUID, reused only when retrying that report.
- The UTC day summarized.
- App version, macOS major version and CPU architecture.
- Counts from a fixed set of event names.

The counters cover dashboard pane visits; key add/copy/delete and grant/client creation; ingestion outcomes; gateway outcomes; optimizer outcomes, abstentions and cache hits; and prepared/unchanged/empty context packs. Gateway and optimizer durations use four buckets: under 100 ms, under one second, under ten seconds, and ten seconds or longer.

There are no prompts, responses, raw error messages, key values, key names, project identifiers or paths, tool arguments, provider/model names, account IDs, persistent installation IDs, exact event timestamps, exact token totals or financial totals. The analytics component accepts typed event enums and never queries the vault, prompt library or past usage tables. Unknown fields and event names are rejected.

These are operational counters, not task-quality labels. An optimizer success means the API returned a recognized successful result; it does not prove that a suggested plan was correct. Abstentions include disabled features and unavailable authorization as well as evaluator fallback. A context-empty count includes disabled context preparation. Nothing in these reports establishes net savings, active-user counts, or user retention.

## Storage and delivery

Unsent daily counters and consent live in the existing private local SQLite catalog under `product_analytics_v1`. This is aggregate metadata, not an encrypted vault archive. Clearing it is logical deletion; normal catalog backups and filesystem behavior still apply.

The active UTC day's report stays local. Once that day ends, the dashboard process can send the completed immutable report. It checks after about one minute at startup, then every fifteen minutes, at most one queued day per check. The app must be running. Failed uploads wait before retrying, using the same report UUID so a received-but-unacknowledged request is not counted twice. Reports older than seven days are discarded; no more than eight UTC-day buckets are retained, including today.

The transport uses HTTPS, an ephemeral URL session, no cookies or stored credentials, no redirects, a small request body, a bounded response and short deadlines. Only a 204 response acknowledges delivery. Changing preferences needs no vault unlock or Touch ID.

The self-hosted collector retains received reports for 30 days and offers an owner-only local CLI summary. It does not publish a dashboard or store IP addresses, request logs, raw headers or raw bodies. Network infrastructure necessarily sees the connection IP; operators must also disable proxy access logs and set retention for backups. These reports are not described as anonymous or end-to-end encrypted. Public submissions can be forged, so they are not authoritative billing or identity data.

## Configure a release later

1. Follow `Analytics/README.md` to run the collector on a private server behind HTTPS. Apply the documented proxy request limits and logging settings. Do not expose the stdlib HTTP listener directly to the internet.
2. Set `ProductAnalyticsConfiguration.endpoint` in `Sources/KeysCore/ProductAnalytics.swift` to the actual HTTPS `/v1/reports` URL. Credentials, query strings and fragments are not supported. Set `appVersion` to the release version.
3. Build, sign and install through the normal Keys release process. Confirm the displayed destination and disclosure before opting in. Endpoint or consent/schema changes require a new opt-in.
4. Run a bounded end-to-end trial with synthetic events, confirming delivery, retry deduplication, opt-out and retention on the deployed infrastructure.

The supplied build leaves the endpoint `nil`; no server, account, deployment, tracking service or user consent has been created automatically.

## Offline verification

```sh
swift test
python3 -m unittest Analytics/test_collector.py
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
node --check Web/analytics.js
node scripts/tests/test_analytics_ui.cjs
```

The last command requires Playwright and its Chromium browser in the Node environment. The repository pins Playwright 1.62.1 as a development dependency of `Plugins/jev-optimizer`; after `npm ci` there, run `npx --no-install playwright install chromium` in that directory and start the browser scripts with `NODE_PATH=Plugins/jev-optimizer/node_modules`, as CI does for this script and `scripts/tests/test_optimizer_workflow_ui.cjs`. The schema shared by the app and the collector is pinned by the synthetic `Fixtures/analytics/report-golden.json`, which both the Swift and the collector tests parse. Its API is a local synthetic fixture; it does not use the running Keys app or send reports externally. Swift tests use temporary catalogs, a fake transport and in-memory credentials. Collector tests use a temporary database and loopback HTTP sockets. Live deployment and Apple signing are separate validation steps.
