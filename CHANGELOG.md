# Changelog

## Unreleased

- Chart: the pane now leads with what is being charted — **Subscriptions**, the tools' own local logs, or **API keys**, the local gateway's ledger (`S`) — and the filters underneath belong to whichever is chosen. Subscriptions keeps the Grok / Claude / OpenAI chips and the project grouping, and says plainly that its figures are estimated from local logs rather than from plan invoices. Switching drops the filters that do not carry over, so no request goes out under a filter the page is no longer showing — and a link that asks for a local source while also naming a key or a provider drops both and rewrites its own URL, rather than filtering the local rows by a gateway key.
- Chart: the **API keys** scope charts the calls this Mac routed through a vault key, narrowed by provider and then by key — both defaulting to all, both naming keys only. TypeSafe, the Vercel AI Gateway and any other provider a vault key reached are separate choices on the same axis; a workload that runs on several of them, such as Jev, stays a model under each provider rather than becoming a source of its own. Requests lead the totals and are a chartable unit here, so a provider that reports no tokens and no cost (TypeSafe's System One) still shows its calls, with the cost left unknown instead of zero; a partly priced range reads as a floor and says so in the totals line, in each model row and in the day and hour tooltips, because a bucket that mixes a priced call with an unpriced one still carries a number. The engine serves it as `/api/spend?source=keys`, optionally `&provider=…` and `&key=…` (both applied in SQL before aggregation, and `provider` outside `source=keys` is a 400). The report keeps a gateway call that a local log also recorded, names each gateway row's `provider`, and carries `model_calls` on the daily and hourly buckets. Charting a key from the Keys table takes that key's own provider instead of whichever provider filter the chart was left on, and a call the provider named no model for is charted under `unknown` rather than dropped from the bars. The subscription sources are unchanged: gateway dollars and tokens are still reported separately there, because a routed Claude Code or Codex call also appears in a local log.
- Gateway accounting: a routed call whose response carried neither usage nor a cost receipt is no longer priced from its request's model name. Estimating over the recorder's normalized zeros reported `$0.00` as known spend for a call nothing is known about; such calls now count as unpriced, in the Chart, the totals and the Keys table's monthly cell. An explicitly reported zero cost stays a known zero. A genuine zero-token call with no receipt is also treated as unknown.
- Gateway: a request that names its own API version is forwarded verbatim when the provider's `path_prefix` is only a version. Vercel AI Gateway serves the OpenAI-compatible API under `/v1` and the AI SDK's native endpoints (`evaluation-model`) under `/v4/ai`; before this, `<gateway_url>/v4/ai/...` reached upstream as `/v1/v4/ai/...`. Gemini's `/v1` beside `/v1beta` follows the same rule. Prefixes with a real path (`/api/gateway`) still apply to everything.

## 0.4.0 — 2026-09-09

- Claude's menu-bar percentage now shows Fable quota used as `C 72%`, with no five-hour value or extra label in the title. If Fable data is unavailable, it shows `C —` rather than substituting weekly usage.
- The website and Claude dropdown tab show five-hour, Fable, and weekly usage. Dropdown bars now fill with usage consumed instead of usage remaining.
- Fable reads Claude Code's account-matched `/usage` cache. While the menu-bar app runs, it refreshes through Claude's built-in `/usage` command every five minutes using the existing login, without a model request. Cached readings older than one hour, from another account, or past their reset are ignored.
- `keys status` includes Fable; `keys doctor` reports the Claude usage cache separately from the HUD export.

Upgrade: build with `swift build`, then run `.build/debug/keys autostart` to update the installed app. Automatic quota refresh requires a signed-in Claude Code version supporting non-interactive `/usage` (verified with 2.1.266).

## 0.3.1 — 2026-09-06

- Dashboard: the Grant dialog has a kind switch, task grant (minutes, in
  memory) or long-lived client (days, hash in the catalog), so `keys client`
  has a UI. Active clients are listed with the grants, each with Revoke.
- Keys table: action buttons wrap into rows on narrower windows instead of
  stacking one per line.
- Check: a redirect is its own outcome, naming the host it points to; the key
  is never sent there. Ramp Router's API host is `api.router.com`;
  Experiential Labs added to the catalog.

## 0.3.0 — 2026-09-06

Agent key access, from `notes/2026-09-06-agent-key-access.md`. Verified live
on 2026-09-06: grant from a Terminal and from a Codex sandbox (the prompt
comes from the menubar site), cancel gives exit 3, screen lock revokes, and
`keys test` lists 68 Ramp Router models.

- Grants: `keys grant`, `keys grants`, `keys revoke` and a Grant action in the
  dashboard. One Touch ID per task; the token is used as the API key; bound to
  key, host, methods, path prefixes, expiry, optional request and USD caps.
  Revoked on screen lock, gateway off, key edit or delete, and site restart.
- The gateway now requires a grant token. A request without one gets
  `401 grant_required`; out-of-scope requests get a named 403 or 429. The
  old open-once-enabled behaviour is gone.
- Checks: `keys test`, `keys models [--cached] [--grep]` and a Check action
  with a filter box. Read-only, provider-specific, never a generation call;
  result stored per key and reused without a second unlock.
- Errors: presence failures split into cancelled, failed and unavailable
  (with the reason); provider 401 and 403 reported differently; provider
  message and request id kept, key scrubbed from every message.
- Keys list and `keys env` show the provider and the host a key is bound to.
- README now says what the per-launch token is (browser cross-site defence),
  not local-process authentication.
- Menubar dropdown: a tab strip (Overview, then one tab per subscription)
  over bars with "% left" and reset times; the tab is remembered. Rows below:
  Plan Usage, Status Page submenu, Refresh (was Ingest), About.
- providers.json: Ramp Router API host is `api.router.com`; a check that
  gets a web page back says so.


All notable changes to Keysreallysafe. Each entry is a GitHub release.

## 0.2.0 — 2026-09-05

Source review of 2026-09-05, all seven findings addressed, plus an eight-item review pass on the fixes. Upgrade note: the first open after this release clears the old ingest cursors and replays every log once in the background; on a large `~/.claude/projects` that is a few minutes of catch-up, not a hang. Verified on a real install: `keys autostart` upgraded in place and kept the previous version, `keys client issue` prompted once and the gateway returned 401 without the token.

### Security
- Ingest cursors no longer hold raw log bytes. `ingest_files.tail_sig` stored the last 32 bytes of each log as hex, which could carry a fragment of a user message; it is now a versioned SHA-256 digest. On first open the catalog clears legacy signatures, checkpoints the WAL and vacuums, and `secure_delete` is on. Scope: the catalog file only; copies made outside the app are out of reach.
- Gateway requests need a per-client capability. `keys client issue|list|revoke` (and `/api/keys/<name>/clients`) mint revocable, expiring tokens bound to one key, with method and upstream path-prefix scope. Issuing asks for presence; only the token's hash is stored. Auth runs before key lookup. The dashboard's per-launch token is never accepted.
- README now describes the dashboard token as a browser CSRF defense, not local-process authentication, and describes the Keychain presence prompt as app-level rather than an OS-enforced per-item ACL.

### Fixed
- Combined spend double-counted a call seen by both a local log and the gateway. The headline estimate is local logs only; gateway dollars, tokens and calls are reported beside it. The gateway records the upstream `request-id`, and a gateway row whose id matches a local event is dropped as the same call.
- A gateway call with no model or price was shown as $0. Per-key month figures now distinguish none, estimate, partial and unknown, with unpriced call and token counts; the spend report carries the same for the gateway ledger.
- Ingest read whole files into memory, held every pending row until the end, and ran on the menu bar run loop under the gateway's lock. Reads are bounded chunks, importers commit every 2,000 lines with a cursor valid at that offset, the timer enqueues onto a background queue, and gateway state has its own lock.
- `keys autostart` could leave the install missing or stopped. A new version is staged, signed and verified first; the previous version is kept one back and restored, with its agent restarted, if activation fails.
- An oversized gateway body is drained before the socket closes so the client sees the 413.
- Post-review pass: rollback also covers a failure while moving the live parts; request paths with `.`/`..` segments (raw or percent-encoded) are out of scope for every client and a trailing slash on `--path-prefix` is trimmed; a made-up key name no longer writes an audit row and `last_used_at` is stamped only when a call is forwarded; a proxy that repeats `request-id` values no longer collapses two gateway calls into one row; chart rows, daily and hourly buckets follow the headline (local ledger unkeyed, gateway ledger keyed); the legacy-signature purge is gated on a marker and a busy vacuum is retried on the next open instead of failing startup; the menu bar Ingest action and the dashboard's stale check never block behind a running pass.

### Changed
- `usd_month` in `/api/keys` is null (not 0) when calls exist but none could be priced; `usd_month_kind` and `gateway_month_*` counts accompany it. Spend totals gain `gateway_tokens`, `gateway_calls`, `gateway_unpriced_*`, `gateway_correlated_calls` and `usd_estimate_scope`.
- Test suites named after the behaviour they protect (`KeyLifecycleAndDedupTests`, `GatewayHardeningAndCursorTests`); new suites for tail-digest privacy, gateway accounting, gateway clients, bounded ingest and installer rollback.

### Not done
- Browser integration tests for the dashboard (reveal expiry, copy feedback, CRUD, filtering, failed requests) and packaged releases. CI still runs Swift unit tests only.

## 0.1.0 — 2026-09-04

First public release.

### Added
- Local spend meter: reads Claude Code, Grok and Codex usage logs incrementally, prices from a checked-in list-price table (`Fixtures/models.json`) with hand overrides.
- Site on `127.0.0.1` with three panes: Usage (plan windows as `plan · % used · resets in`), Chart (today by hour, week and month by day, tokens or USD, model and project breakdown), Keys.
- Key vault in the macOS Keychain: add, copy with clipboard wipe, reveal, env injection, edit, rotate, delete, per-key audit log. Touch ID on every read.
- Local gateway on `127.0.0.1:12767` that injects a vault key into SDK traffic, records usage, and never stores message text.
- Menu bar item with the weekly window of each tool; 5-hour windows, reset times and Grok dollars in the dropdown. Refreshes every minute and on open.
- `keys doctor`, `keys purge`, `keys autostart --remove`, OpenRouter credit poll, CSV and Markdown export.
- Grouped provider catalog (`Web/providers.json`, 53 providers).

### Security
- Origin token on every mutating request, `Host` and `Sec-Fetch-Site` checks on both servers, redirect refusal on all outbound calls, content-length and body-size validation, no auth files ever read.

### Fixed
- Claude turns are counted once per message id; the previous count was roughly three times too high.
