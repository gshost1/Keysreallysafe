# Mission report: 0.14 feedback — `send_feedback`, onboarding counters, `revoke_all`, `activity`

Run on 2026-10-28 in the worktree
`/Users/Shost2/Projects/Keysreallysafe/.claude/worktrees/droid-014-feedback`,
on branch `droid/implement-send_feedback` — **not** the `droid/014-feedback`
the mission brief names. As in the base mission, the runner assigned every
worker the same checked-out branch and forbade a mid-mission rename, so every
mission commit landed there, in the order below; the orchestrator restores the
required name `droid/014-feedback` before completion, which renames the branch
and touches none of the commits. Nothing was pushed, merged, released or
deployed.

This mission is build-split item 4 of the approved design
(`docs/proposals/grants-first.md`, whose "Owner review" section overrides the
text above it), branching from the completed `014-mcp-core` base
(`02dd7d8`; `origin/main` is `763e623`). It adds four capabilities to the
`keys mcp` stdio server and the CLI, each landing through the registry seam the
mcp-core mission left, with every result passing its output guard:

1. **`send_feedback(draft, destination?, prompt?)`** — the app scrubs the
   agent's draft (vault values by exact match, provider-key shapes, Keysrs
   token shapes and prefixes, absolute/home-relative paths, catalog key names
   and project labels, non-support emails, agent-marked prompt text, a length
   cap), appends the Keysrs and macOS version, and opens a prefilled `mailto:`
   or GitHub issue URL behind an injectable opener seam. Keysrs never submits;
   no new outbound endpoint; no Touch ID.
2. **Onboarding analytics counters** — `scan_run`, `key_import`, `grant_issue`,
   `onboarding_finished` join the share-to-compare v2 vocabulary on **both
   sides** (Swift `ProductAnalyticsEvent`, `collector.py COUNT_KEYS`, the shared
   golden fixture, schema tests both sides, the docs), pinned to each other the
   way the existing counters are — plus the **`set_analytics_sharing(enabled)`**
   tool that records the onboarding answer through the running app (consent
   version 2 unchanged) and logs one content-free confirmation line.
3. **`revoke_all(key?)`** + `keys revoke --all [--key NAME]`** — revoke every
   grant and every client token (or one key's), no Touch ID, returning counts —
   plus **`revoke_project(label)`**, which revokes a project's active client
   tokens by label.
4. **`activity(window?, project?)`** — recent gateway use read locally from the
   catalog (the `list_keys` precedent — works with the app closed): rows per key
   name with request counts, refusals, project labels, and estimated spend only
   where already computed.

Everything below ran offline on this machine: temp homes, temp catalogs,
`MemorySecretStore`, `RecordingPresenceGate`/`BlockingPresenceGate`, ephemeral
loopback ports only (never 12765/12766/12767, which belong to the installed
`/Applications/Keysrs.app`), no Keychain, no Touch ID, no network beyond
loopback, no real credential, no mail client, and the five real agent config
files untouched. No key value, token or real credential appears in this report.

## What changed, feature by feature

| Commit | Feature | What it added |
|---|---|---|
| `d35fe20` | F1 — feedback-scrubber-send-feedback | `Sources/KeysCore/FeedbackScrubber.swift` (the pure, eight-category scrubber), `Sources/KeysCore/FeedbackDelivery.swift` (the destination URLs, the percent-encoder, the injectable opener), the app-side `POST /api/mcp/feedback` route that enumerates vault values in memory with no Touch ID, `MCPFeedbackTools` (`send_feedback`), the registry line, all five test seams, the docs entries, and the planted-secret end-to-end over real dispatch |
| `481b5a5` | F2 — analytics-counters-set-sharing | the four counters in `ProductAnalyticsEvent` + `Analytics/collector.py` `COUNT_KEYS` + `Fixtures/analytics/report-golden.json`; `MCPAnalyticsTools` (`set_analytics_sharing`) over `POST /api/mcp/analytics/sharing` → `setEnabled` (consent v2) + the new `KeysService.analyticsLog` seam wired in `AppRuntime.run()`; frozen-instruction rule 7 in both byte-pinned copies; the docs |
| `111823c` | F3 — revoke-all-and-project | `CatalogDB.revokeGatewayClients(key:/project:)` bulk revokes + the active-client reads the audit walk needs, `KeysService` wrappers (one `client_revoke` audit row per affected key), `Projects.revokeProjectClients(label:)`, the combined `POST /api/mcp/revoke_all` and `POST /api/mcp/revoke_project` routes (the dashboard's `DELETE /api/grants` untouched), `MCPRevokeTools` (`revoke_all`, `revoke_project`), the CLI `keys revoke --all` switch to the combined route with both counts, and the docs |
| `061d0ba` | F4 — activity-tool | `MCPActivityTools` (`activity`), catalog-local (no app), rolling-hours window, per-key request/refusal counts, project labels from active client tokens, spend reusing `SpendQueries.gatewayUsd` with the `GatewayMonth` honesty vocabulary, the registry line, all five test seams, the docs |
| (this commit) | F5 — closeout-report | this report; the full nine-step CI list run serialized below |

Scope diff against the base (`02dd7d8`) before this commit: **36 files,
+3,466/−43** — six new `Sources/KeysCore` files (`FeedbackScrubber`,
`FeedbackDelivery`, `MCPFeedbackTools`, `MCPAnalyticsTools`, `MCPRevokeTools`,
`MCPActivityTools`), five new test files plus additions to `MCPRegistryTests`,
`MCPClientFlowTests`, `MCPServerInstructionsTests`, `MCPServerTestSupport`,
`MCPAppConnectionTests`, `ProductAnalyticsTests`, `ProjectIdentityTests`,
`GatewayClientTests`, `GrantTests`, and the doc edits (`docs/agents.md`,
`docs/product-analytics.md`, `Skills/keysrs/SKILL.md`, `README.md`). No file
outside the mission's areas is touched; `CLAUDE.md`/`AGENTS.md` are unchanged
and the frozen identifiers are intact.

## Test results — the full CI list

`.github/workflows/test.yml` is the full list CI runs; every step below was
run in this session, in CI order, with the CI env
(`CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home`),
serialized one command at a time (this 8 GiB machine shares memory with the
browser suites). Node is 26.7.0 locally where CI pins 22; every suite passes on
both. No step was narrowed or subsetted.

| # | Command | Exit | Wall | The suite's own summary |
|---|---|---|---|---|
| 1 | `swift test` (CI env) | 0 | 162 s | `Executed 802 tests, with 5 tests skipped and 0 failures (0 unexpected) in 157.026 (157.107) seconds` |
| 2 | `(cd Relay && npm ci && npm test)` | 0 | 13 s | `Test Files 1 passed (1)`, `Tests 43 passed (43)` — workerd, offline |
| 3 | `(cd scripts/tests && npm ci && npx --no-install playwright install chromium)` | 0 | 2 s | `added 33 packages, and audited 34 packages in 1s`; chromium already cached (the install is a no-op) |
| 4 | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | 6 s | `Ran 71 tests in 6.391s` — `OK` |
| 5 | `python3 -m unittest Analytics/test_collector.py` | 0 | 11 s | `Ran 20 tests in 10.451s` — `OK` |
| 6 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | 153 s | `Keys dashboard UI passed: 143 cases` |
| 7 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | 5 s | silent on success — the exit code is the pass signal (observed empty output, exit 0) |
| 8 | `(cd scripts/tests && npm run test:e2e)` | 0 | 11 s | dashboard target `Tests 4 passed (4)`, marketing target `Tests 1 passed (1)` |
| 9 | `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=scripts/tests/node_modules swift test --filter BackendContractUITests` (CI env) | 0 | 10 s | `Backend contract UI passed: 12 cases against http://127.0.0.1:58327`, `Executed 1 test, with 0 failures (0 unexpected) in 5.014 (5.015) seconds` |

**Passed:** all nine steps, nothing red. Nothing this mission caused needed
fixing during closeout, and nothing was already red on the base: the same nine
steps were verified green at mission readiness (2026-10-28, 750 XCTest cases,
5 pre-existing opt-in skips, full table captured in `library/environment.md`).
The suite grew from 750 to **802** XCTest cases (+52), the collector from 19 to
**20**, and `scripts/tests` discovery stayed at **71**.

**Skipped (5, all pre-existing, all opt-in, none a failure):**

- 3 × `RelayEndToEndTests` — need `KEYS_RELAY_E2E_URL` and
  `KEYS_RELAY_E2E_SECRET` with a `wrangler dev` running
  (`testRealWebSocketRoundTripThroughWranglerDev`,
  `testAWrongSecretIsReportedAsTheWorkersRefusal`,
  `testACallDuringAShortOutageWaitsForTheAppRelayAndALongOneGetsA503`).
- 1 × `StableSigningTests` — needs an Apple signing identity.
- 1 × `BackendContractUITests` inside the unfiltered `swift test` — the
  browser contract harness; run with `KEYS_BACKEND_CONTRACT_UI=1` (table row 9)
  it passes fully: 12 cases, 0 failures.

Known non-failing noise, unchanged from before the mission: two
`ResourceWarning: unclosed file` lines from the python stdio harness's
SIGINT-test cleanup during step 4's discovery, and the workerd
`identity-transform-stream` teardown line during the Relay tests (step 2).

## Decisions made without user input

Nobody was available during this run; every choice below is the conservative
one the mission's `architecture.md` pinned and is restated here rather than
left implicit. The parallel integration mission inherits these answers.

1. **The scrub runs in the app, by the app, with no Touch ID.** The MCP tool is
   a thin delegate that posts the raw draft to `POST /api/mcp/feedback` and
   relays the scrubbed answer; the MCP process never holds a vault value. The
   app enumerates vault values in memory **solely for exact-match removal** —
   compared and discarded, never logged, persisted, returned or hinted
   (`wrapPlan`'s constant-time precedent). This is removal, not a reveal: the
   presence-gated operation list is unchanged, and tests sweep the result, the
   app log and the whole temp tree for planted values.
2. **Length cap 10,000 characters on the scrubbed text, scrub-then-cap**
   (`ProviderCheck`'s scrub-before-shorten rule — a cut inside a secret would
   leave a prefix). Truncation is reported under the `length` category.
3. **The `prompt` argument is the prompt-text marker.** Whatever string it
   holds is removed from the draft (exact-substring, category `prompt_text`).
   Machine-checkable, no magic markers; the tool description says so.
4. **Consent version stays 2.** The four counters are aggregate per-day
   integers inside the existing consent class; bumping to 3 would invalidate
   every existing consent for a vocabulary addition the collector tolerates by
   design. `schema_version`, `consent_version` and `FIELDS` are unchanged.
5. **Vocabulary-only counters, no producers in this branch.** The producers
   belong to the onboarding mission's tools (`scan_project`, `import_and_wrap`,
   the onboarding-finished transition); wiring them here would edit that
   mission's areas and double-count (`grant_create`/`key_add` already count).
   The enum comment, the docs and this report say so — the integration mission
   wires them (seams below).
6. **One combined revoke route + the CLI's two-count wording.** A single
   `POST /api/mcp/revoke_all {key?}` revokes grants (app memory) and client
   tokens (catalog) and answers `{revoked_grants, revoked_clients}`, counts =
   still-live-only. The CLI `keys revoke --all [--key NAME]` uses it and prints
   both counts in the house singular/plural style — `revoked 2 grants and 1
   client token` / `revoked 0 grants and 0 client tokens` — exit 0 at zero,
   exit 6 app-down, exit 1 for an invalid `--key`, the single-id path
   unchanged. The dashboard's grants-only `DELETE /api/grants` is untouched.
7. **`revoke_project` is an MCP tool only** (no CLI spelling — the brief gives
   none). Client tokens only (grants carry no project), and the tool
   description says so; an unknown label is a not-found error, a known label
   with nothing active answers `{revoked_clients: 0}`.
8. **No `--json` is added to `keys revoke`** (not requested).
9. **Activity window semantics:** `window` is whole hours (integer), default
   **24**, valid range **1…720**; outside the range is a local argument error.
   The window is rolling (`now − hours·3600` to `now`, half-open, ISO-string
   boundaries like `usageEvents(from:to:)`).
10. **Activity's project-filter emptiness:** `activity(project=<label>)`
    filters to the keys whose active clients are bound to that label; an
    unknown label yields **empty rows, not an error** (a project with no
    traffic is an empty answer). A key used with no project client carries an
    absent project field — honest, no invention. Spend appears only where
    already computed (`SpendQueries.gatewayUsd`); nothing priced means the
    spend is absent/nil, never a fake zero.

Two further in-mission choices worth recording: the feedback **destination** is
only `"email"` (default) or `"github"` — anything else is a local argument error
with nothing opened and no round trip; and the feedback flow's **opener is the
one documented exception** to the no-opening rule `open_app` carries (the tool
exists to put a prefilled mail or issue page in front of the user), behind the
injectable seam with a structural belt.

## The seams left for the integration mission

These are the exact places the integration mission (or the onboarding mission)
extends. Each is deliberate and recorded so it is not re-derived.

1. **The counter producers.** `scan_run`, `key_import`, `grant_issue` and
   `onboarding_finished` are in the vocabulary on both sides and the shared
   golden, but **nothing records them yet**. The onboarding flow's tools
   (`scan_project`, `import_and_wrap`, the onboarding-finished transition) wire
   the producers; the enum comment (`ProductAnalytics.swift`), the
   `counts` bullet in `docs/product-analytics.md` and this report all state it.
2. **The `analyticsLog` seam.** `KeysService.analyticsLog: (String) -> Void`
   (default no-op) is wired in `AppRuntime.run()` as
   `service.analyticsLog = { logFile.write($0) }` beside the relay host;
   `AppLogFile.write` prepends the `<UTC ISO> `, so the route passes the bare
   body `"analytics sharing turned on|off"`. The integration mission reuses it
   for any other content-free app log line.
3. **The combined revoke route.** `POST /api/mcp/revoke_all {key?}` is the one
   route both the tool and the CLI `--all` use; the dashboard's grants-only
   `DELETE /api/grants` stays separate. A future surface that must revoke both
   kinds goes through this route, never a second one.
4. **The feedback opener seam.** `FeedbackDelivery`'s production default
   (`NSWorkspace.shared.open`) is the only place the app opens anything on this
   path; tests inject a counting spy.
5. **The roster pins.** `MCPRegistryTests.milestoneOneRoster + … +
   activityRoster` and the independent literal in `MCPClientFlowTests` both list
   exactly the twelve tools; the integration mission that appends a tool grows
   both knowingly, and `neverRegistered` keeps `scan_project`, `check_exposure`,
   `import_and_wrap`, `test_keys` and `grant_cancel` absent. The frozen
   instruction string (`MCPServer.swift`) and its byte-identical test copy move
   in lockstep (LF-only, no trailing newline, the line count pinned, no `/`).

## Known pre-existing issues carried forward (not caused by this mission, deliberately not fixed here)

- **The dead CRLF check in the gateway config writers.** `CodexSetup.upsert`
  and `GrokSetup.upsert` in `Sources/KeysCore/AgentSetup.swift` test
  `text.contains("\r")`, which is false for a real CRLF file (a CRLF pair is
  one grapheme cluster in Swift), so a CRLF `~/.codex/config.toml` silently
  takes the append path and duplicates the section instead of being refused.
  Carried from the base mission; a future mission that owns `AgentSetup.swift`
  should replace both checks with a byte-level CR test.
- **Two pre-existing source build warnings**, still present at HEAD (verified in
  the source; a warm build does not re-emit them): an unused `try?` result at
  `Sources/KeysCore/AppUpdater.swift:398` and an unused `withLock` result at
  `Sources/KeysCore/CatalogDB.swift:511`.
- **One pre-existing test-target build warning**, reported by the F3 worker and
  not in the base mission's list: `no calls to throwing functions occur within
  try expression` at `Tests/KeysreallysafeTests/RenewalGatewayTests.swift:33`.
  The file was not modified by this mission and the warning predates it, so it
  was left untouched rather than fixed here; a housekeeping change should drop
  the spurious `try`.
- **Five pre-existing opt-in test skips** (listed in the test-results section):
  three relay e2e cases needing `wrangler dev`, the Apple-signing test, and the
  backend-contract UI case that CI runs explicitly as its own step. They are
  environment gates, not failures.
- **Non-failing noise:** two `ResourceWarning: unclosed file` lines from the
  python stdio harness's SIGINT-test cleanup, and the workerd
  `identity-transform-stream` teardown line.

## Git evidence

- **Branch:** `droid/implement-send_feedback` — see the header note. The
  brief's required name `droid/014-feedback` is restored by the orchestrator
  before completion; the commits and their order are untouched by it. The
  branch has no upstream, so nothing is pushed.
- **Commit order (oldest first):** `d35fe20` (F1, send_feedback), `481b5a5`
  (F2, counters + set_analytics_sharing), `111823c` (F3, revoke_all +
  revoke_project + CLI), `061d0ba` (F4, activity), then this commit (F5, the
  report).
- **Base:** `02dd7d8` "Record the 0.14 mcp-core mission report" — the mcp-core
  final state; `origin/main` is `763e623`.
- **Scope:** 36 files, +3,466/−43 against the base before this commit (the
  per-feature table above maps every commit). No file outside the mission's
  scope is touched; the frozen identifiers (`keys` executable, `keysreallysafe`
  signing id, the Keychain service, the launchd label, the support dir, the
  status-item autosave name, the Swift package/target names, the repo name),
  `/Applications/Keysrs.app`, the five real config files, the Site and Relay
  workers, `CHANGELOG.md` and the version string are all untouched.
- Nothing was pushed, merged, released or deployed.

## Coverage highlights

All inside the green CI run, for this mission's surface: `FeedbackScrubberTests`
9/9 (every removal category, runtime-built fake keys, the scrub-then-cap),
`FeedbackToolsTests` 8/8 (route, tool, opener spy, the not-running sentence,
the planted-secret end-to-end), `AnalyticsToolsTests` 6/6 (route + tool over
the in-process rig, the capturing log seam, the bounded answer, the default-off
and silence pins), `RevokeToolsTests` 9/9 (counts, scoping by key, unknown
label, not-running, no-prompt pins), `ActivityToolsTests` 12/12 (seeded counts,
exact JSON key sets, window boundaries, project filter, empty catalog,
nil-vs-zero spend, planted-value sweep, app-down), `MCPRegistryTests` 3/3 and
`MCPClientFlowTests` 1/1 (both roster pins, the twelve tools in registry
order), `MCPOutputGuardSweepTests` 2/2 (the roster-derived planted-secret and
offline-and-silent sweeps over all five new tools), `MCPServerInstructionsTests`
2/2 (the frozen seven-rule string byte-for-byte, both copies),
`ProductAnalyticsTests` 21/21 (the golden three-way pin), `ProjectIdentityTests`
12/12, `GatewayClientTests` 9/9 (bulk revocation, other keys survive),
`GrantTests` 17/17 (the combined route, the untouched grants-only route), plus
the python side: `Analytics/test_collector.py` 20/20 (the four names accepted,
unknowns still 400, the golden pin). The full suite went from 750 XCTest cases
at readiness to 802, with the five pre-existing skips unchanged.
