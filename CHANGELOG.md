# Changelog

## 0.10.1 — 2026-09-26

- **Sort your API keys.** A Sort by menu above the key table orders them by name, recently used, most used this month (requests through the gateway), newest or oldest. Keys never used sort last, and the choice is remembered in that browser view.
- The disk image opens as a laid-out install window: the Keysrs name, a one-line description and an arrow from the app to Applications.

## 0.10.0 — 2026-09-25

- **Keysrs.app.** The disk image now holds `Keysrs.app` and an Applications shortcut: drag it to Applications and open it. No folder to keep and no Terminal step. It is a regular Mac app with a Dock icon, a main menu and a window showing the dashboard; the menu bar meter stays. Closing the window keeps the meter, usage tracking and the gateway running, the Dock icon or Open Keysrs brings the window back, and `⌘Q` quits.
- The app adds itself as a login item on first launch through macOS's own login-item service; Start at Login in the Keysrs menu turns it off and on, as does System Settings > General > Login Items. The launchd agent that `keys autostart` installed is no longer how Keysrs starts.
- **Upgrading from 0.9.x:** open the new app once. It stops the `com.keysreallysafe.menubar` agent, deletes its plist and the old `bin/`, `Web/`, `Fixtures/`, `Plugins/` and `scripts/` under `~/Library/Application Support/Keysreallysafe/`, and writes what it did to `menubar.log`. The catalog, preferences, logs, `.previous/` and every Keychain item stay. The app keeps the signing identifier `keysreallysafe` and the 0.9.2 designated requirement, so Keychain items stored by 0.9.x keep trusting it.
- The `keys` command line lives inside the app (`Keysrs.app/Contents/MacOS/keys`). Install Command Line Tool… in the Keysrs menu links it as `~/.local/bin/keys`; it asks for no administrator access and does not replace an existing file. `keys autostart` now only accepts `--remove`, which still cleans up a 0.9.x install.
- The menu bar title shows Claude's weekly usage, like Codex and Grok; the Fable window stays on the Claude tab. Start at Login and Install Command Line Tool… are also in the meter's dropdown, and an existing `~/.local/bin/keys` link to the 0.9.x runtime is moved to the app automatically.
- **Update check, off by default.** Check for Updates… asks GitHub's latest-release API for the newest version number and says whether it is newer; Automatically Check for Updates repeats that at launch and daily once turned on. Nothing is downloaded or installed, and no cookies are sent. It is the only network request 0.10.0 adds.
- Unchanged: the gateway on `127.0.0.1:12767`, the dashboard API bound to `127.0.0.1`, the Keychain service, the catalog and its location. Apple Silicon only, macOS 14 or newer.
- Development: `scripts/build-app.py` assembles and signs `Keysrs.app` from the release build, and the release packager puts it in `Keysrs-arm64.dmg`.

## 0.9.2 — 2026-09-25

- **Security fixes.** The gateway forwarded a grant token sent in `X-KSF-Grant`, and a token in `?key=` (including `%6Bey=` or `KEY=`) whenever a header also carried one, to the provider; every token is now stripped. A chunked request with a chunk size near the integer limit crashed the app before authentication; it now gets 413.
- `keys get` is written to the key's audit log like every other read. `keys purge` empties every catalog table, including provider checks and the license rows 0.6 to 0.8 left behind. A 401 from the gateway sends one `WWW-Authenticate` header. The model name a gateway caller sends is capped at 128 characters before it is stored.
- The gateway no longer accepts a grant token in the undocumented `X-KSF-Grant` header; send it where the SDK puts the provider key (`Authorization`, `x-api-key`, `x-goog-api-key` or `api-key`). The header is still stripped before forwarding.
- **Removed the experimental optimizer.** The Optimizer pane and its `⌘4` shortcut, the per-key Optimizer button, `keys optimizer`, `keys grant --jev-provider`, the `/api/optimizer/*` routes, the Jev context-compaction plugin, its MCP server and launcher, and the research and benchmark scripts are gone. The dashboard has three panes again (`⌘1`–`⌘3`). The vault, the gateway (including metering direct TypeSafe and Vercel evaluation traffic through ordinary grants) and the usage meter are unchanged.
- Upgrading moves the `Plugins` and `scripts` directories that 0.9.0 and 0.9.1 installed aside with the previous version, and `keys autostart --remove` deletes them. `keys purge` still deletes the optimizer's encrypted archive next to the catalog and its Keychain key (service `keysreallysafe.optimizer`).
- Share to compare: the dashboard no longer sends an Optimizer pane visit, and no optimizer or context-pack counter is recorded. Reports and consent from 0.9.0 and 0.9.1 keep decoding; the collector accepts the same event names.
- `/api/spend` and `keys spend --json` totals no longer carry the prose fields `usd_estimate_scope`, `token_rule` and the three `*_usd_estimate_label` strings; every number stays. `/api/keys` and `keys list --json` drop `provider_name`, `gateway_base_url` and `gateway_month_unpriced_tokens`. Nothing in the dashboard read them.
- Gateway calls are recorded once, in the usage table, with their HTTP status. The key list's month cost, grant spend caps and share-to-compare's gateway rows all read that one ledger with one pricing rule, so a call whose provider reported zero tokens and no cost now shows as unknown everywhere instead of $0 on the key list. The old `gateway_usage` table is left for earlier versions and cleared by `keys purge`.
- `keys dashboard` and the menu bar bind their fixed ports (12765 and 12766) or fail with "bind 127.0.0.1:N failed" in the log. They used to walk up to 20 ports on, which could land a second dashboard on the menu bar's port or take the gateway's 12767. Provider checks send the user agent `keysrs (+https://keysrs.com)`.
- The local site no longer serves `/api/doctor`, `/api/providers` or `/api/analytics/clear`, and `/api/keys` and `/api/grants` drop `gateway_owner_pid`, `gateway_owned` and `gateway_resets_on_restart`; the dashboard used none of them (`keys doctor` is unchanged, and the dashboard reads `/providers.json`). Which process owns the gateway is read only from `control.json` beside the catalog; the `gateway_owner_pid` catalog entry is no longer written, and the `KEYS_CONTROL` override is gone.
- `keys doctor` prints one `binary` line comparing the installed binary's SHA-256 with the running one's (`match` or `differs`) and a `site control=` line in place of the active-grant count. `keys autostart` no longer writes `bin/keys.sha256`; installation stopped re-signing, so the installed binary is hashed directly.
- The command line leaves argument errors to its parser: a usage mistake such as `keys add` with no name now exits 64 (was 1), `--help` prints to stdout, and errors that are not Keysrs's own carry an `Error:` prefix. Keysrs errors keep their messages and exit codes (2 not found, 3 authentication or Keychain). `keys env` no longer echoes its parsed arguments after a usage error.
- Development: the release packager is `scripts/prepare-release.py` (documented in `docs/release.md`) and packages only the binary, the Web files, the model fixture and the docs. The browser suites take Playwright from `scripts/tests/package.json`.

## 0.9.1 — 2026-09-24

- The new Keysrs icon (graphite tile, blue usage ring, house key) replaces the brass placeholder: in the dashboard's browser tab, the About window and on the disk image.

## 0.9.0 — 2026-09-24

- **Free and MIT-licensed.** Keysrs no longer has a trial, license key or paid tier, and the root `LICENSE` is MIT again, covering the whole repository. An install whose 0.6–0.8 trial ended, or whose license could not be confirmed, starts measuring and issuing grants again on update; the catalog, keys and history carry over.
- Removed: the `keys license` command, `/api/license`, the dashboard's license banner and the menu bar's "trial ended" / "confirm license" titles. The app no longer contacts keysrs.com at all; the only outbound call to us is opt-in "share to compare".
- `keys purge` also deletes the `keysrs.install` Keychain item that 0.6–0.8 created for license activation.
- keysrs.com is a static site again: the `/license` page, the Stripe webhook, activation endpoints and their D1 database are gone. The site offers the download directly.

## 0.8.0 — 2026-09-23

- **Share to compare** (opt-in). The first launch of this version asks once, with the box unticked, whether to share daily usage totals. People who share get a **Compare** line on the Usage page: their typical day's tokens per tool against everyone who shares, and how often sharers hit each plan limit. A figure appears only once at least 50 reports contribute to it, so the line stays hidden until then rather than showing a guess.
- Analytics report v2 (new consent, so everyone is asked again): besides the feature counters, a day's report now carries token totals per tool (Claude Code, Codex, Grok), provider and public model name, gateway request and token totals per provider, and each plan window's peak percentage. It still never includes prompts, keys or key names, projects, sessions, paths, dollar amounts or exact times; a model or provider name that is not public (fine-tunes, Azure deployments, custom providers) is sent as `unknown`/`other`. Nothing from before opting in is summarized. Privacy in the dashboard shows exactly what today's report would contain.
- Reports go to `https://analytics.keysrs.com`, a self-hosted collector (`Analytics/collector.py`) behind a Cloudflare Tunnel. With sharing on, the app also downloads the public comparison table from the same host once a day; the request carries nothing about the Mac. Turning sharing off stops both.

## 0.7.0 — 2026-09-23

- License activation: a key now works on **up to two Macs**. Entering it activates this Mac at keysrs.com; the app checks in every 30 days and keeps working for 14 days without a check-in, so a leaked, refunded or disputed key stops at the next check-in. Each call carries only the key, a random install ID and the Mac's model identifier. The install ID lives in the login Keychain beside a local hash of the hardware UUID (never sent), so a Mac cloned with Migration Assistant needs its own place, and a catalog copied to another Mac does not carry the activation. `keys license remove` (or removing the key in the dashboard) frees the place; the license page lists the Macs and can remove one. New state **unconfirmed** (key stored, no current activation, trial over) behaves like an ended trial and says why; the menu bar reads "Keysrs · confirm license".
- keysrs.com: `/api/license/activate` (activation and check-in), `/api/license/deactivate`, `/api/license/release`, backed by a D1 database (`migrations/`); a full refund or a dispute (`charge.refunded`, `charge.dispute.created`) revokes the license automatically.
- The CLI's gateway-owner error says to use the dashboard; `scripts/resend-license-email.mjs` re-sends a lost license email.

## 0.6.1 — 2026-09-23

Includes everything since 0.4.0 (0.5.0 and 0.6.0 shipped as DMGs without their own entries).

- License review fixes: the trial gate covers every ingest path, including the dashboard's stale refresh; trial status no longer takes the catalog write lock; checkout delivery retries on Stripe errors, mails delayed payments, accepts rolled webhook secrets and rate-limits `/license`.
- About shows the real version.
- First launch: the menu bar app opens one welcome window before anything else. Every box starts unticked and Continue with nothing ticked is a full answer, never asked again. It asks whether to keep Claude plan limits fresh and, in a build with an analytics collector configured, whether to share anonymous usage counts (asked once per consent version; people who already opted in are not asked). **Continue and Open Keysrs** also opens the dashboard.
- Claude limits: running Claude Code's `/usage` in the background every five minutes is now **opt-in** (welcome window, or **Keep Claude Limits Fresh** in the menu). Off, Claude limits come from the cache Claude Code writes itself; choosing **Refresh** asks Claude Code once. Upgrades start with it off.
- Trial and license: Keysrs runs in full for 14 days from first launch, then asks for a license to keep ingesting usage and issuing gateway grants. The vault never depends on it: list, copy, reveal, env, rotate, delete, purge and `autostart --remove` work in every state. A license is an Ed25519-signed key (`keysrs1.…`) checked offline against a public key built into the app; `keys license`, `keys license set <key>` and `keys license remove` manage it, the dashboard shows a banner with a key field when the trial has a week or less left, and the menu bar reads "Keysrs · trial ended" when it lapses. Trial start and key live in the catalog's meta table; winding the clock back does not restart a trial. Stripe checkout now lands on keysrs.com/license, which shows the key and emails it from support@keysrs.com.
- Name: the product is now **Keysrs**, matching keysrs.com. Every user-facing string (menu bar, About, dashboard title and brand, CLI help and messages, presence prompts) says Keysrs. Nothing that existing installs depend on changed: the `keys` executable, the signing identifier and designated requirement, the Keychain services, the launchd label, `~/Library/Application Support/Keysreallysafe/` and the menu bar autosave name are unchanged, so an upgrade keeps every key and setting.
- Display: figures lead with what this Mac measured. Tokens — and requests, where the gateway ledger counts them — are the default unit everywhere: the chart, its totals and model rows, the Usage pane's monthly summary and the Keys table's gateway column. A dollar figure is this repo's list-price table applied afterwards, so none appears until **USD** is chosen, and that choice is remembered. The switch sits beside what it changes: the chart's unit chips, a switch on the Usage summary line, and one above the Keys table's gateway column. Everything the honest-cost work established survives in USD — unknown is not zero, a partly priced range is a floor — and absent token counts are now distinguished from measured ones too: a provider that reports none reads as "no reported tokens" beside the requests that are counted, never as `0`. The token headline carries its input / output / cached-read / cache-write breakdown, and says that cached input is counted on each request that reads it again rather than being new output. The CSV export is unchanged: an explicit export still carries the raw token and cost columns whatever the screen is in; the copied totals line follows the unit.
- Chart: a family with more models than the four hand-picked palette shades no longer loses the extra names to "Other models". The palette extends deterministically past four, so every model — `claude-fable-5-1` included — keeps its own name, colour, legend row, filter and bars, and a long legend scrolls instead of merging rows. A model no provider named still reads as `unknown`.
- Dashboard: a first run with an empty vault gets a short getting-started guide on the Usage pane — add a key, use it through a child process or a scoped gateway grant, watch and revoke it — with the Keychain and Touch ID boundary, the login-password fallback, the fact that no `.env` file is needed, and the limit that only routed calls are observable. It is dismissible, never shown to a vault that already has keys, and always reachable from **?**, which now opens "How Keys works" above the shortcut list.
- Optimizer: the pane, the help guide, the README and the optimizer docs label the Optimizer and Jev context compaction **optional and experimental**. The vault, the gateway, the usage meter and the dashboard are usable without enabling either, and no proven net saving is claimed.
- Release: `docs/mvp-quickstart.md` and `docs/mvp-acceptance.md` describe installing a prepared package on a second Mac (macOS 14+, matching architecture, no Swift toolchain needed there, optional Node 18+/`python3` for the experimental Optimizer) and the pending acceptance checks. Both are in the offline packager's documentation allowlist, so they travel inside the artifact. The package remains a signed private preview, separate from a notarized public release; no Gatekeeper workaround is documented.

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

Agent key access. Verified live on 2026-09-06: grant from a Terminal and
from a Codex sandbox (the prompt comes from the menubar site), cancel gives
exit 3, screen lock revokes, and `keys test` lists 68 Ramp Router models.

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


All notable changes to Keysrs (formerly Keysreallysafe). Each entry is a GitHub release.

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
