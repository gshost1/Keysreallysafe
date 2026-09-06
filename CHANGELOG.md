# Changelog

All notable changes to Keysreallysafe. Each entry is a GitHub release.

## Unreleased

Source review of 2026-09-05, all seven findings addressed.

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
