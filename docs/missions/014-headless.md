# Mission report: 0.14 headless app — headless launch, settings, on-demand launch, notifications, background updates, guided `keys add`

Run on 2026-10-28 in the worktree
`/Users/Shost2/Projects/Keysreallysafe/.claude/worktrees/droid-014-headless`,
on branch `droid/execute-headless-lifecycle` — the Factory-managed mission
branch the runner held at every session (the user authorized Factory-managed
renames and forbade manual branch changes; none were made). This mission
continues `droid/014-mcp-core`; its report is
[docs/missions/014-mcp-core.md](014-mcp-core.md). Nothing was pushed, merged,
released or deployed, and `/Applications/Keysrs.app` and its
`127.0.0.1:12766`/`:12767` listeners were never touched, stopped or queried.

The mission implements the headless-app slice of the approved design
(`docs/proposals/grants-first.md`, whose "Owner review" section is
authoritative) plus the owner-approved guided `keys add`: the app launches
headless (`.accessory`, no window, no Dock icon, no menu bar item) and keeps
every background service running; the window shows on reopen, `keys
dashboard` and MCP `open_app` and hides — never quits — on close; the meter,
menu-bar item and automatic-update settings are persisted with a one-time
0.13 migration; `AppConnection.connect()` owns on-demand app launch for every
eligible caller; the app asks notification permission once per installed
version and warns about expiring credentials, pending Touch ID asks and
breaker trips with fixed non-sensitive templates; the daily update check
installs a verified release in the background once the app is idle; and a
bare `keys add` in a terminal guides provider → name → hidden confirmed
secret.

Everything below ran offline on this machine: temp homes, temp catalogs,
`MemorySecretStore`, injected launchers/clocks/presence/notifiers/installers,
ephemeral loopback ports only (never 12766/12767), no Keychain, no Touch ID,
no real OS permission dialog, no network beyond loopback, and no real
credential anywhere.

## What changed, feature by feature

| Commit | Feature | What it added |
|---|---|---|
| `77d17b1` | headless-lifecycle-settings | `AppActivation` state machine (`.accessory` at launch, `.regular` while the window is shown, `.accessory` again on close/hide); launch-time app alerts deferred to the first `show()`; persisted `pref_show_usage_meter` (off), `pref_menubar_item` (off), `pref_update_checks` (on) with the one-time `headless_defaults_applied` migration; token-gated `/api/preferences/*` routes and `/api/app/quit` (200 before termination is dispatched); dashboard Settings carrying the three switches, Quit and the relay controls; the direct second-instance show path; `keys menubar` still creating its item on demand; `LSUIElement` pinned false in `scripts/build-app.py`/`test_build_app.py` |
| `9512a70` | app-autolaunch-and-window-entrypoints | `AppConnection.connect(control:launch:)` as the one launch policy (bundle id → `/Applications/Keysrs.app` fallback → bounded health-gated backoff → one retry → the plain not-running sentence, CLI exit 6); `AppLaunchSeam` with injected launcher and clock; every eligible caller routed through the seam and pinned by a caller-map source check; `keys tunnel`/`keys relay run` keeping `gatewayDown` when the app is healthy but its gateway is down; `keys dashboard` showing the app window through the seam (no browser, no second site, `KEYS_NO_OPEN` removed); the graceful no-app population unchanged |
| `d863b79` | app-connection-test-isolation-guard | `AppConnectionIsolationGuard` — the shared fail-closed guard that rejects the production app-support path, the installed bundle, non-temporary control URLs and the production launcher/clock/Keychain implementations by throwing before any file, socket, Keychain or app operation (path strings and types only; it never inspects the real `control.json`); `KEYS_TEST_NO_LAUNCH` for spawned `keys` processes; the belt test that fails any rig block using a control URL without the guard, naming file and declaration |
| `06d3817` | safe-app-notifications | `Sources/KeysCore/Notifications.swift` — fixed non-sensitive templates, injected `NotificationAuthorizing`/`NotificationDelivering` seams, authorization asked once per installed version, the ~3-day expiry horizon with per-entity dedupe, pending-ask and breaker-trip notifications, an absent optional onboarding endpoint tolerated, and the poller retained on the service |
| `bb656a0` | background-auto-updates | `Sources/KeysCore/BackgroundUpdates.swift` — the scheduled check's install half: quiet gate (no Touch ID prompt, no unsettled grant ask, no in-flight gateway request for five seconds, sampled repeatedly and restarted by new activity, bounded at ten minutes), the manual flow's own `UpdateInstaller` (so checksum and stable-signing gates are identical), notification before the quit that hands over to the relaunch helper; the manual Check for Updates choice behind injectable seams, never installing before Update Now; both paths guarded against a double install |
| `953d2ee` | guided-keys-add | `Sources/KeysCore/GuidedAdd.swift` — the provider-first picker with type-ahead over the shipped catalog plus user overlay (`o` leads OpenAI, OpenRouter, Ollama; the hidden OpenAI row is a picker-only exception), the unique provider-derived name suggestion, the existing hidden confirmed `SecretPrompt`, the non-TTY usage error, and did-you-mean suggestions for an unknown `--provider` |
| (this commit) | readme-full-ci-closeout | `README.md`, `docs/agents.md`, `docs/relay.md`, one line of `Skills/keysrs/SKILL.md` (the never-returning list) and this report |

Scope diff for this mission (`02dd7d8..HEAD`, i.e. after the mcp-core report
commit): 50 files, +5,982/−292. The branch as a whole (`origin/main...HEAD`)
is 76 files, +16,117/−429 including the mcp-core mission this one continues.

## Test results — the full CI list

The complete user-required sequence from `services.yaml` (`commands.full-ci`,
which mirrors `.github/workflows/test.yml`) was run in this session, serially,
in the written order, with the exact CI fixture environment
(`CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home`), as
one `set -e` block so any red step would have stopped the run. The whole block
exited **0**; every command's own summary below is copied from the run's log.
No step was skipped, narrowed or subsetted.

| # | Command | Exit | The suite's own summary |
|---|---|---|---|
| 1 | `swift test` | 0 | `Executed 836 tests, with 5 tests skipped and 0 failures (0 unexpected) in 122.383 (122.466) seconds` (swift-testing half: `Test run with 0 tests in 0 suites passed`) |
| 2 | `(cd Relay && npm ci && npm test)` | 0 | `Test Files 1 passed (1)`, `Tests 43 passed (43)` (workerd, offline; Duration 5.11s) |
| 3 | `(cd scripts/tests && npm ci && npx --no-install playwright install chromium)` | 0 | `added 33 packages, and audited 34 packages in 1s`; the Playwright install printed nothing — Chromium 1243 was already cached, so there was nothing to download |
| 4 | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | `Ran 72 tests in 6.361s` — `OK` |
| 5 | `python3 -m unittest Analytics/test_collector.py` | 0 | `Ran 19 tests in 9.879s` — `OK` |
| 6 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | `Keys dashboard UI passed: 146 cases` |
| 7 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | silent on success — observed empty output; the exit code is the pass signal, as in the mcp-core closeout |
| 8 | `(cd scripts/tests && npm run test:e2e)` | 0 | dashboard target `Test Files 1 passed (1)`, `Tests 4 passed (4)` (6.78s); marketing target `Test Files 1 passed (1)`, `Tests 1 passed (1)` (2.29s) |
| 9 | `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=scripts/tests/node_modules swift test --filter BackendContractUITests` | 0 | `Backend contract UI passed: 12 cases against http://127.0.0.1:49766`; `Executed 1 test, with 0 failures (0 unexpected) in 4.986 (4.986) seconds` |

**Failures: none.** No command exited non-zero and no test failed.

**Skipped (5, all inside step 1's unfiltered `swift test`, all pre-existing
opt-in gates, none a failure):**

- 3 × `RelayEndToEndTests` — the runner's own reason: `set KEYS_RELAY_E2E_URL
  and KEYS_RELAY_E2E_SECRET with wrangler dev running`.
- 1 × `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation`
  — the runner's own reason: `requires Apple signing identity; run before
  deploying signing changes`.
- 1 × `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` — the
  runner's own reason: `browser contract harness: set KEYS_BACKEND_CONTRACT_UI=1
  with the pinned Playwright Chromium installed`. Step 9 runs exactly that
  configuration and it passed in full (12 cases, 0 failures).

No other suite reported a skip, and no skipped or unrun check is claimed to
pass anywhere in this report.

**Environment note.** This host runs Node 26.7.0 where CI pins Node 22
(readiness-verified: Apple Swift 6.3.3, arm64 macOS 26, Python 3.9.6). The
difference affected no result: every Node-driven suite above passed.

**Known non-failing noise, unchanged from before this mission:** the two
`ResourceWarning: unclosed file` lines from the python stdio harness's
SIGINT-test cleanup (step 4), the workerd identity-transform-stream disconnect
teardown line (step 2), and `npm audit` counts from the pinned lockfiles
(Relay: 5 vulnerabilities — 2 moderate, 3 high; scripts/tests: 3 high) plus
npm's install-scripts allowlist warnings for `esbuild`, `fsevents` and
`workerd`. None of these is a test result; the lockfiles are pinned and were
not changed.

## Readiness evidence (separate from the final run)

Verified at mission readiness, before implementation landed: the toolchain
(Swift 6.3.3, Python 3.9.6, Node 26.7.0, npm 11.19.0); both pinned `npm ci`
installs (`Relay/`, `scripts/tests/`); cached Playwright 1.63.0 Chromium 1243;
and the existing synthetic e2e path green — dashboard 4/4 and marketing 1/1,
exit 0, against the synthetic fixture server only, with its processes and
ports cleaned up afterwards. The installed app was already listening on
12766/12767 during readiness and was left alone; a pre-existing node process
on port 12799 was observed and left alone. The final full-CI table above is
independent of all of this and was run after the last implementation commit.

## The installed-app test incident, and its cleanup

Recorded transparently, with no key or token value anywhere. An intermediate
run of the auto-launch caller tests (during the
`app-autolaunch-and-window-entrypoints` feature, before isolation was fixed)
used the default control file instead of a temporary one and reached the
user's real installed app. That run added a synthetic key named `openai`,
issued client token ID 13 for it, enabled its gateway, and attempted relay
on/off calls whose final state was not verified. The token-bearing temporary
env/backup files were deleted at the time. The user then confirmed cleanup:
client 13 was revoked, the synthetic `openai` key was removed, and the relay
was confirmed off. That confirmation is recorded in the mission `AGENTS.md`
and was the precondition for every later test run.

The approved fix landed as `d863b79` (above): the fail-closed
`AppConnectionIsolationGuard`, the `KEYS_TEST_NO_LAUNCH` no-launch pair for
spawned processes, and the belt test that names any unguarded rig. Every
app-connection/auto-launch test since — including the whole final full-CI run
in this report — executes behind that guard: explicit temporary control-file
URLs, fake launchers and `MemorySecretStore` only, with production-shaped
configurations rejected before any I/O. The final runs are therefore guarded
runs, distinct from the incident run, and no test in them reached the
installed app, its control file, the real Keychain or
`~/Library/Application Support/Keysreallysafe`.

## Decisions made without input

Nobody was available during the run; every choice below was made from the
approved proposal, the validation contract and the mission directives, and is
recorded here rather than silently.

1. **Activation:** `LSUIElement` stays explicitly false in the bundle;
   runtime activation policy (`.accessory` at launch, `.regular` while the
   dashboard is shown, `.accessory` again on close/hide) is what hides the
   Dock icon headless, so the app can still become a normal Dock-capable app
   while its window is up. `scripts/build-app.py` and `test_build_app.py` pin
   this reasoned contract.
2. **Migration:** the 0.13→0.14 defaults apply once via the
   `headless_defaults_applied` marker, with no prompt and no keep-old-UI
   choice; a later launch never reapplies them over a user's changes, and
   existing usage rows and unrelated preferences are untouched.
3. **Settings storage:** the three choices persist as
   `pref_show_usage_meter` (off), `pref_menubar_item` (off) and the existing
   `pref_update_checks` (on) — the automatic-update setting reuses the
   existing key rather than gaining a second preference. The Playwright
   dashboard fixture deliberately keeps `show_usage_meter: true` because that
   suite exercises the meter's own UI; the fresh-store default (off) is
   pinned in `PreferencesTests` instead.
4. **Menu-bar preference vs recovery:** `MenubarExtra`'s `itemVisible` is nil
   (read the preference) in app mode and true for the explicit legacy
   `keys menubar` command; with the preference off no `MenubarItemController`
   exists, so recovery cannot re-show an intentionally hidden item.
5. **Quit ordering:** the dashboard Quit route returns its 200 before the
   scheduled termination stops the loopback server, so a successful user
   action is never a dropped fetch.
6. **Auto-launch policy:** it exists only in `AppConnection.connect()` —
   bundle id `com.keysreallysafe.keysrs`, fallback `/Applications/Keysrs.app`,
   bounded backoff `[0.25, 0.5, 1, 1, 2, 2]` (capped, budget-clamped to
   exactly 10 s per attempt), one retry, then exactly `Keysrs isn't running.
   Open Keysrs from Applications, then try again.` (CLI exit 6, MCP tool
   result). The health probe is the token-gated read-only
   `POST /api/mcp/grants/status`, which exists before any window. The seams
   are method parameters (`run(launch:control:)`), not stored properties,
   because `ParsableCommand` structs cannot hold non-Decodable stored
   properties.
7. **Caller routing:** the approved caller table (`keys grant`, `grants`,
   `revoke`, `renew`, `gateway on|off`, `gateway cheapest on|off`,
   `relay on|off`, `wrap`, `tunnel`, `relay run`, `dashboard`, the grant path
   of `keys agent`, and the app-bound MCP tools) goes through the one seam,
   pinned by a caller-map source check; `keys tunnel`/`keys relay run` keep
   their `gatewayDown` error when the app is healthy but its gateway is down;
   the graceful no-app population never launches; `keys unwrap` belongs to the
   parallel onboarding slice and gets the documented seam only.
8. **`keys dashboard`:** it now fronts the app window through the seam and
   returns — no browser, no second dashboard site. `--month`/`--week` still
   parse (and still refuse to combine) but no longer select a range;
   `KEYS_NO_OPEN` was removed with the browser path.
9. **Test isolation:** the guard compares configured paths as strings and
   implementations as types only, before any I/O, and never inspects the real
   `control.json`; spawned `keys` processes (which cannot be handed a Swift
   closure) are confined with `KEYS_TEST_NO_LAUNCH=1` plus an explicit
   temporary `KEYS_CATALOG`; the belt test scans the rig files and fails an
   unguarded block by name.
10. **Notifications:** the expiry horizon is about three days and grant
    lifetimes are never extended to fit it — the product's own grants live at
    most 24 hours, so an active grant is always already inside the horizon
    and is warned at its first eligible poll (the short-lived-grant reading
    the mission asked to have recorded); one warning per entity, deduped
    across polls; authorization is asked once per installed version (the
    version stays `0.13.0` here — the bump is the integration mission's, and
    it will trigger one fresh ask); an absent optional onboarding endpoint is
    tolerated; every payload is a fixed template with no key value, token,
    path or prompt text.
11. **Background updates:** the automatic path runs the manual flow's own
    `UpdateInstaller`, so the checksum and stable-signing gates are identical
    by construction; the quiet gate is five seconds with no Touch ID prompt,
    no unsettled grant ask and no in-flight gateway request, enforced by
    repeated sampling plus an activity stamp (never one instantaneous
    reading), bounded at ten minutes so a busy Mac defers to the next daily
    check; the installer's own quit hook stays unset on the background path so
    the order is always install → notify → quit; the OS
    notification-permission dialog is not part of the quiet gate (the mission
    names Touch ID prompts and gateway requests only); a Touch ID prompt
    raised by a `keys` CLI subprocess in another process is unobservable and
    out of scope; turning the setting off does not cancel an in-flight
    install; a failed check or verification logs to `menubar.log` and never
    installs, quits or alerts.
12. **Guided `keys add`:** the picker merges the shipped catalog and the user
    overlay and includes the hidden OpenAI row as the approved picker-only
    exception (typing `o` ranks OpenAI, OpenRouter, Ollama); the catalog's
    hidden flag, the dashboard picker and the other retired providers are
    unchanged. The suggested name is provider-derived and disambiguated
    against existing names; the secret still goes through the existing hidden,
    confirmed `SecretPrompt`; a non-TTY bare run is a clear usage error; an
    unknown `--provider` fails with did-you-mean suggestions and saves
    nothing.
13. **Closeout's own:** the shipped agent skill (`Skills/keysrs/SKILL.md`,
    carried byte-for-byte inside the app bundle) had one stale floor-rule
    line — `keys dashboard` in the never-returning list — so that one list was
    corrected (`keys menubar` replaces it; all nine `AgentSkillTests` pins
    still pass inside step 1). The closeout also added one README sentence on
    the guided bare `keys add` flow, since the vault section named no
    invocation form. Both are documentation-only changes recorded here.

## Deferred pre-existing issue (not caused by this mission, not fixed here)

**`keys tunnel` help-text mismatch.** The flag is `--print-only` in
`TunnelCommand`, but the command's hand-written usage string and
`docs/agents.md`'s never-returning bullet say `--print`. This predates the
mission and was left untouched (the mission's doc edits kept the `--print`
spelling to stay consistent with the rest of the page). A future pass should
align the usage string and both docs on `--print-only`.

## Checks that remain manual in a separately built Keysrs.app

These need a real, separately built and installed `Keysrs.app` (or real OS
UI) and are **not** automated passes. None of them was exercised in this
mission: no installed app was launched, no built app was installed, and no
real permission UI was shown.

- Real Dock/activation/window behavior: a headless launch shows no Dock icon
  and no window; Spotlight/Applications reopen and the direct second-instance
  path show it; closing hides without quitting; usage ingestion, the gateway
  and the control server visibly carry on across all of it.
- The deferred first-run welcome appearing, with its existing content, on the
  first window show rather than at launch.
- The menu bar item's real rendering and placement with **Show menu bar item**
  on, and recovery not re-showing it when the preference is off.
- The real macOS notification-authorization dialog (once per installed
  version) and actual delivery of the four notification kinds — expiring
  credential, pending Touch ID ask, breaker trip, update installed.
- A real idle background update end to end: the daily check finding a newer
  release, the download, checksum and stable-signing verification, the quiet
  wait, the install, the headless relaunch and the notification. (Automated
  tests fake the release, download and installer by design.)
- Real Touch ID observation: approving and denying a grant ask, and the
  guided `keys add` hidden/confirmed prompt on a real terminal.
- `keys dashboard` and MCP `open_app` against the installed app: fronting its
  window, and the launch-and-wait path when it is not running.
- Start at Login registration and its System Settings reflection.

## Observed ingest behavior behind the meter preference

Recorded per the validation contract: **Show usage meter** is presentation
only. With it off, the dashboard hides `#live-status` (the plan-window meter)
while `#usage-totals` and the Chart still render from stored data; the ingest
scheduler, the OpenRouter poll and the catalog rows are untouched, and turning
it back on restores the meter from the same data. Pinned by the XCTest
temp-catalog row/totals and ingest-schedule assertions and by the Playwright
case `Show usage meter off hides the meter without removing the data, and on
restores it` (step 6, green).

## Git evidence

- **Branch:** `droid/execute-headless-lifecycle` throughout; Factory-managed,
  never manually renamed or switched.
- **Commit order (this mission, oldest first):** `77d17b1` (headless
  lifecycle/settings), `9512a70` (on-demand launch and window entrypoints),
  `d863b79` (fail-closed isolation guard), `06d3817` (notifications),
  `bb656a0` (background auto-updates), `953d2ee` (guided `keys add`), then
  this closeout commit (README, docs/agents.md, docs/relay.md, the one skill
  line, this report).
- **Scope:** 50 files, +5,982/−292 since the mcp-core report commit
  (`02dd7d8..HEAD`). No file outside the mission's scope is touched; the
  frozen identifiers, the root `CLAUDE.md`/`AGENTS.md` symlink target, the
  user-owned `docs/release.md`, the installed app, and the Site/Relay
  deployment surfaces are all untouched.
- The full-CI run whose results are tabulated above was executed at
  `953d2ee` plus only the documentation edits in this commit — documentation
  that no suite reads — so the table covers the final tree. Nothing was
  pushed, merged, released or deployed.
