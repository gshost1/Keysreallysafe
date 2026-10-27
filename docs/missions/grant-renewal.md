# Mission report: explicit grant renewal (CLI + dashboard)

Run on 2026-10-27 in the worktree
`/Users/Shost2/Projects/Keysreallysafe/.claude/worktrees/droid-renewal`,
branch `droid/execute-renewal-core` (renamed from `droid/grant-renewal` by
the mission runner at session start — see the ledger), over commits
`da89cb3` (store, service, prompt and audit core), `1c93213` (renew route
and `keys renew`), `3c54590` (dashboard renewal surface), `97f3d34`
(grants-header count fix) and the docs commit that adds the README prose and
this report. The branch builds on the permission-profiles mission
(`d762ff4`…`94b286a`), whose run is reported in
[grant-profiles.md](grant-profiles.md). Nothing was pushed.

The mission added **explicit, user-controlled grant renewal**: `keys renew
<id>` and a per-row **Renew** button in the dashboard re-approve an existing
grant in place — same id, same token, same key/host/method/path scope, caps,
task, and profile/unattended labels — for another window of its original
lifetime, behind exactly one Touch ID whose prompt names the full effective
scope. Usage counters reset and `renewals` increments; the audit log gains a
`grant_renew` row (id, task, scope, renewal number — never the token).
Nothing auto-renews; renewal takes no scope parameters (a scope-carrying
request is refused pre-prompt with `renew_scope_immutable`); a revoked grant
is never renewable (revoke deletes the token hash, so the fail-closed check
is "hash gone"). The README "Privacy boundaries" section was not touched
(diff-verified verbatim-identical, see below).

## Test results

The full CI list from `.github/workflows/test.yml`, run offline on this
machine, serialized one command at a time (two `swift test` runs would
corrupt the shared `.build/`, and this 8 GB machine shares memory with the
browser suites). Node was v26.7.0 locally where CI pins 22; all suites pass
on both.

| Command | Exit | Result |
|---|---|---|
| `env CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home swift test` | 0 | `Executed 573 tests, with 5 tests skipped and 0 failures (0 unexpected) in 47.177 (47.246) seconds` |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | `Ran 62 tests in 0.857s — OK` |
| `python3 -m unittest Analytics/test_collector.py` | 0 | `Ran 19 tests in 9.933s — OK` |
| `(cd Relay && npm ci && npm test)` | 0 | `Test Files 1 passed (1)`, `Tests 36 passed (36)` |
| `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | `Keys dashboard UI passed: 98 cases` |
| `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | exit 0; the suite prints nothing on success (run twice, both runs exit 0 with empty output — the exit code is the pass signal) |
| `(cd scripts/tests && npm run test:e2e)` | 0 | dashboard target `Tests 4 passed (4)`, marketing target `Tests 1 passed (1)` |
| `env KEYS_BACKEND_CONTRACT_UI=1 CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home swift test --filter BackendContractUITests` | 0 | `Backend contract UI passed: 11 cases against http://127.0.0.1:61225`, `Executed 1 test, with 0 failures` |

Every command above was run in this session, in this order, and every row
reports its observed exit code and output.

**Skips (all expected, all environment-gated, none a failure):**

- 3 × `RelayEndToEndTests` — `Test skipped - set KEYS_RELAY_E2E_URL and
  KEYS_RELAY_E2E_SECRET with wrangler dev running`.
- 1 × `StableSigningTests` — `Test skipped - requires Apple signing identity;
  run before deploying signing changes`.
- 1 × `BackendContractUITests` inside the unfiltered `swift test` —
  `Test skipped - browser contract harness: set KEYS_BACKEND_CONTRACT_UI=1
  with the pinned Playwright Chromium installed`. Run with the variable set
  (last table row) it passes fully: 11 cases, 0 failures.

Nothing failed. Nothing else was skipped. The workerd stream-teardown line
(`identity-transform-stream … reader canceled`) during the Relay tests is
the documented benign noise, not a failure.

Coverage highlights for this mission's surface, all inside the green runs
above: `RenewalTests` 10/10 (store window math and counter reset,
hashless-row refusal, refusal matrix with an empty prompt log and named
errors, pinned renew prompt, denied-prompt no-op, audit content, control-file
round-trip, wire-code mapping, CLI parse shapes); `RenewalGatewayTests` 7/7
(expired grant renews and the same token passes the real loopback gateway,
every denial class unchanged after renewal, cap reset and re-enforcement,
re-expiry at the new window, revoked/screen-locked unrenewable, restart
forgets); `ServerTests` renew-route cases (`testGrantRenewRouteNeedsTheToken`,
`testGrantRenewRouteReturnsTheRenewedGrantWithoutAToken`,
`testGrantRenewRouteNamesItsRefusals`,
`testGrantRenewRouteRefusesScopeFieldsBeforeAnyPrompt`); the dashboard
suite's two new cases (`grant rows offer Renew on active and expired rows,
never on revoked ones`; `renewing a grant posts to the renew route and
refreshes the row, and a refusal is shown`); and the backend-contract
scenario's new ordered case `a grant renews end to end keeping its token and
scope` against the real Swift backend (taking the suite from 10 to 11
cases).

## Conservative choices ledger

Every judgment call made autonomously during the mission, with its rationale.

1. **In-place renewal: same id, same token.** A running agent keeps working
   with the credential it already holds; renewal re-approves, it does not
   re-issue. No new token is ever minted or printed by renewal.
2. **Active or expired grants only; revoked is never renewable.** Revoke
   (user, screen lock, gateway off, key delete) deletes the token hash;
   expiry keeps it. "Hash still present" is the fail-closed renewable check,
   so a killed grant can never be revived. Pruned (>24 h) or post-restart
   grants are simply gone: `renew_not_found`.
3. **No scope knobs on renewal — refusal, never clamping.** A renew request
   carrying any of key/host/methods/paths/minutes/max_requests/max_usd/task/
   profile/unattended is refused pre-prompt with `renew_scope_immutable`
   (400). Different bounds mean `keys grant`.
4. **The renewed window is the grant's original window.** `windowMinutes` is
   recorded at issuance; renew sets `expiresAt = now + windowMinutes`, and a
   renew of a renew uses the same window. `keys renew` has no `--minutes`:
   the user approved a size once, and one Touch ID buys exactly one more
   window of that size.
5. **Usage counters reset per renewal** (`requests`, `usd`,
   `unpricedCalls`, `lastUsedAt`), and `renewals` counts how many windows
   were approved — the audit trail can always answer "how often was this
   re-approved".
6. **The renewal response never carries the token.** The route returns the
   grant's `jsonObject()` (which has no token field), in contrast to
   issuance, which prints a token once. Pinned by
   `testGrantRenewRouteReturnsTheRenewedGrantWithoutAToken`.
7. **Denial messages and the `keys grants` table stay byte-identical.**
   Renewal touched no gateway denial path and no table column; `renewals`
   is visible via `--json` only. The one deliberate output change is the
   `renew    keys renew <id>` hint line added to the `keys grant` success
   block; its pinned test was updated and is named in the handoff.
8. **No analytics changes, no CHANGELOG entry.** `recordKeyEvent` maps
   `grant_renew` to no analytics event; the branch convention (post-0.12.0
   feature commits) carries no changelog.
9. **A profile is not re-consulted at renewal.** Profiles act at issuance
   only; a profile-issued grant renews self-contained from its stored row,
   and the prompt names the effective scope including the `profile <name>`
   label for honesty, not for re-validation.
10. **One prompt, after all refusals.** `renewGrant` runs the owner gate,
    lookup, revoked check and key/host re-resolution (defense in depth:
    `renew_target_changed` for a state the kill paths missed) before the
    single `presence.require`; `RecordingPresenceGate.reasons` pins zero
    prompts for every refusal class.
11. **Dev-dashboard smoke isolation uses `KEYS_CATALOG=$TMP/catalog.db`,
    never a temp HOME alone** (macOS `applicationSupportDirectory` ignores
    `HOME`), per `library/dev-dashboard-smoke-isolation.md` — a lesson the
    incident below was the price of.
12. **Environmental fact, recorded: the mission runner renamed the worktree
    branch from `droid/grant-renewal` to `droid/execute-renewal-core` at
    session start** (mirroring the profiles mission, ledger item 18 in
    grant-profiles.md). All commits sit on the renamed single linear branch;
    mission documents that still say `droid/grant-renewal` refer to the same
    branch. The branch was NOT renamed back because the runner manages
    branch identity mid-mission.
13. **README docs were kept additive**: the renewal prose and the `keys
    renew` Commands entry were added in the gateway section and command
    list only; the `## Privacy boundaries` section is verbatim-identical to
    `94b286a` (verified with `diff` on the extracted section, not by eye —
    proof below).

## Privacy boundaries: verbatim proof

```
$ git show 94b286a:README.md | awk '/^## Privacy boundaries/,/^## Build from source/' | sed '$d' > /tmp/pb-old.txt
$ awk '/^## Privacy boundaries/,/^## Build from source/' README.md | sed '$d' > /tmp/pb-new.txt
$ diff /tmp/pb-old.txt /tmp/pb-new.txt
$ echo $?
0
```

The diff printed nothing: the section is byte-identical between `94b286a`
and the final tree.

## Scope check

`git diff --stat main...HEAD` includes the permission-profiles mission's
files (`Profiles.swift`, the profile tests, `docs/proposals/
permission-profiles.md`, `docs/missions/grant-profiles.md`, …) because that
mission's commits (`d762ff4`…`94b286a`) sit on this same branch and are not
yet on `main`; their scope was validated in grant-profiles.md. The renewal
mission's own diff, `94b286a...HEAD` plus this commit, touches exactly:

```
 Sources/KeysCore/CLI.swift
 Sources/KeysCore/Grants.swift
 Sources/KeysCore/HTTPServer.swift
 Sources/KeysCore/KeysService.swift
 Tests/KeysreallysafeTests/BackendContractUITests.swift
 Tests/KeysreallysafeTests/RenewalGatewayTests.swift
 Tests/KeysreallysafeTests/RenewalTests.swift
 Tests/KeysreallysafeTests/ServerTests.swift
 Web/app.js
 Web/index.html
 README.md
 docs/missions/grant-renewal.md
 scripts/tests/test_backend_contract_ui.cjs
 scripts/tests/test_keys_dashboard_ui.cjs
```

All inside the allowed list. Nothing under Relay/, Site/, Analytics/,
.github/, Fixtures/; no CHANGELOG.md, CLAUDE.md or AGENTS.md; Web/style.css
untouched (no badge style was needed — the existing `badge` class covered
it).

## No-secrets audit

- The added lines of the renewal-mission diff (`94b286a...HEAD` plus this
  commit) were scanned for grant/client token literals (`ksf_…`,
  `ksfc_…`), provider-key shapes (`sk-ant-`, `sk-proj`, `sk-` + 32,
  `AIza…`, `xai-…`, `gsk_…`, `AKIA…`) and private-key blocks. **Zero
  matches.** The only `secret`-shaped strings are test uses of the fixed
  synthetic `fixtureSecret` (`"unit-test-secret-value-xyz"`), never a
  literal token.
- The same scan over `main...HEAD` matches exactly one line, in
  `docs/missions/grant-profiles.md`, where the profiles report enumerates
  the shapes it scanned for — prose about the pattern list, not a secret.
- Renewal adds no persistence but `grant_renew` audit rows; the sentinel
  tests (`RenewalTests` asserts no `fixtureSecret` bytes under the temp
  catalog dir) passed in the full suite.

## No auto-renewal path

Call-graph inspection (`grep -n renew Sources/KeysCore/`):

- `grants.renew(id:now:)` is called exactly once, from
  `KeysService.renewGrant` (KeysService.swift:631).
- `renewGrant` is called exactly once, from the `POST /api/grants/<id>/renew`
  route (HTTPServer.swift:785).
- No timer, observer, retry loop or background task references renewal
  (`grep -iE 'Timer|scheduledTimer|addObserver|retry' | grep -i renew`:
  no matches).

Renewal is reachable only by an explicit user action — the CLI verb or the
dashboard click — each costing one Touch ID.

## Remaining human checks

Real Touch ID and the real vault cannot be exercised autonomously; presence
behavior is pinned via `RecordingPresenceGate` reason assertions instead.
Before shipping, a human should try, in the real app:

1. `keys renew <id>` on an active grant and read the real Touch ID prompt:
   it must name the task, key, provider, host, lifetime, methods, paths,
   caps and the `unattended`/`profile` labels when present.
2. The dashboard Renew click against the real site: the row refreshes with
   a later expiry and a `renewed N×` marker, and a revoked row offers no
   Renew button.
3. `keys renew <id>` on a revoked grant: the refusal names the revoke
   reason, with no prompt.

## Incidents

**The renewal-api-cli smoke-isolation failure (renewal-api-cli session,
honestly recorded).** An early CLI refusal smoke was run with
`HOME=$(mktemp -d)` as the only isolation. On macOS
`FileManager.urls(for: .applicationSupportDirectory)` resolves from the
passwd entry, not the `HOME` env var, so the temp HOME did not isolate: the
dev dashboard opened the real `~/Library/Application
Support/Keysreallysafe/catalog.db` and the installed app's live
control.json. Consequences, all verified benign:

- One `keys renew deadbeef` reached the installed app on its real port and
  got a 405 (the installed build has no renew route). No state changed and
  no Touch ID prompt appeared — the id was unknown and the refusal paths
  never prompt.
- Five inert `ingest_files` bookkeeping rows for worktree fixture paths
  landed in the real catalog (the dev dashboard ingested the fixture homes).
  Zero new usage rows were written. The rows were left in place because
  deleting rows from the user's live database is destructive and
  unauthorized. Cleanup note for the user: when the installed app is quit,
  rows whose path contains `/droid-renewal/Fixtures/` can be removed.

The working isolation (`KEYS_CATALOG=$TMP/catalog.db`, with a hand-written
control.json beside it for refusal smokes) was verified afterwards and is
recorded in `library/dev-dashboard-smoke-isolation.md` so no later worker
repeats the mistake. All smokes after that point used it.
