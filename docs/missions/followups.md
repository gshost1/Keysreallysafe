# Mission report: post-merge follow-ups

Date: 2026-10-27. Branch: `droid/followups` in the `droid-followups`
worktree. The four feature commits had landed and the working tree was clean
(`git status --short --branch` printed only `## droid/followups`) when the
CI list below was run; this report is the mission's fifth and last commit.

## What the mission changed

Four follow-ups on the merged main-line work (grant renewal, key rotation,
relay pairing, permission profiles, vault redesign), one commit each:

- `347dbe9` **Fail the relay pairing flag closed and gate require-off on
  presence** — turning enforcement off now costs one presence prompt in
  `setRelayPairingRequired`, asked before the catalog write so a cancelled
  prompt leaves the flag set; the CLI `require` verb delegates to the
  running app like `issue` and falls back to the local service; a new
  token-gated `POST /api/relay/pairings/required` route carries the same
  toggle; `verifyRelayPairing` reads the flag with `do/catch`, so a thrown
  catalog read refuses with `pairing_required` while an absent row still
  means off. `docs/relay.md` and `docs/proposals/relay-pairing.md` updated
  in sync.
- `c2af3dc` **Name key rotation in the grant kill lists and stop calling
  expiry a death** — the grants hint, grant-dialog hint, help text,
  revoked-badge title, issued-grant Expires line and the three README kill
  lists all name key rotation; the grants hint conveys an expired grant can
  be renewed; the README Keys-pane list mentions Renew. The README Privacy
  boundaries section is untouched.
- `75ee9d3` **Catch typed secrets in the DOM scan and make the Revoke test
  deterministic** — `safetyFree` joins every input and textarea value with
  the markup (all five call sites fixed); the Grants Revoke test seeds a
  persistent grant and revokes through a mutating `DELETE
  /api/grants/<id>` fixture route, no transient override, no retry.
- `2cf973c` **List the merged profiles, renewal, rotation, pairing and vault
  work under Unreleased** — five house-style entries under the existing
  `## Unreleased` heading; the already-listed exit-code-6 and agent-skill
  entries neither duplicated nor amended (the diff is exactly five added
  bullets).

## The CI list, end to end

The full `.github/workflows/test.yml` list, in CI order, from the worktree
root, one step at a time, nothing subsetted. Every swift and python step
ran with the CI fixture environment (`CLAUDE_CONFIG_DIR=Fixtures/claude-home
GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home
KEYS_DROID_HOME=Fixtures/droid-home`); the node steps ran with
`NODE_PATH=scripts/tests/node_modules` and the contract step additionally
with `KEYS_BACKEND_CONTRACT_UI=1`. Exit codes, durations and output tails
are the real ones from this session.

| # | Command | Exit | Wall | Result (output tail) |
|---|---|---|---|---|
| 1 | `env CLAUDE_CONFIG_DIR=… KEYS_DROID_HOME=… swift test` | 0 | 54 s | `Executed 640 tests, with 5 tests skipped and 0 failures (0 unexpected) in 49.204 (49.293) seconds` |
| 2 | `sh -c 'cd Relay && npm ci && npm test'` | 0 | 12 s | `Test Files  1 passed (1)` / `Tests  43 passed (43)` in workerd, offline (test duration 5.17 s) |
| 3 | `env … python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | 1 s | `Ran 62 tests in 0.889s` / `OK` |
| 4 | `env … python3 -m unittest Analytics/test_collector.py` | 0 | 10 s | `Ran 19 tests in 9.961s` / `OK` |
| 5 | `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | 153 s | `Keys dashboard UI passed: 143 cases` |
| 6 | `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | 5 s | silent on success — zero output bytes, exit code is the verdict |
| 7 | `sh -c 'cd scripts/tests && npm run test:e2e'` | 0 | 13 s | `|dashboard| dashboard.e2e.ts (4 tests) … 4 passed (4)` then `|marketing| site.e2e.ts (1 test) … 1 passed (1)` |
| 8 | `env KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=… CLAUDE_CONFIG_DIR=… swift test --filter BackendContractUITests` | 0 | 9 s | `Backend contract UI passed: 12 cases against http://127.0.0.1:50975` / `Executed 1 test, with 0 failures (0 unexpected) in 4.727 seconds` |

## What passed

Every step above. In full: 640 XCTest cases (0 failures, 5 pre-existing
opt-in skips), Relay 43/43 in workerd offline, 62 packaging-script tests,
19 collector tests, 143/143 dashboard UI cases, the analytics UI check
(silent pass), e2e 5/5 (vault round trip, rotation, gateway spend, duplicate
key, marketing site), and 12/12 backend-contract browser cases against the
real Swift backend on an ephemeral port. Total wall time about 4.5 minutes.
Nothing failed, so there are no failure transcripts to paste.

The only diagnostics in any log are the known benign ones: workerd's
`identity-transform-stream … disconnected: reader canceled` teardown line
during the Relay run (it still reports 43/43), the two pre-existing Swift
build warnings (unused `try?` at `AppUpdater.swift:398`, unused `withLock`
result at `CatalogDB.swift:489`), and Swift-Testing's
`Test run with 0 tests in 0 suites passed` after the filtered step 8 — the
non-XCTest runner reporting zero matches, not a failure.

## What was skipped

Inside step 1's `swift test`, five pre-existing opt-in skips (none added by
this mission):

- `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` — needs
  `KEYS_BACKEND_CONTRACT_UI=1` and the pinned Playwright Chromium; that is
  exactly step 8 of this same CI list, where it ran green with all 12
  browser cases.
- `RelayEndToEndTests` (3 tests) — opt-in via `KEYS_RELAY_E2E_URL` /
  `KEYS_RELAY_E2E_SECRET` with `wrangler dev` running; deploy tooling is
  forbidden by the mission boundaries, and the same behavior is covered
  offline by `RelayTests`/`RelayHostTests` and the workerd suite (step 2).
- `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation`
  — requires the Apple signing identity; there were no signing changes in
  this mission.

Nothing else was skipped: no CI step was omitted and no suite was narrowed.

## Run notes (recorded by the orchestrator; verified against the reflog)

1. **Transient branch rename.** At the start of feature 1 a worker session
   renamed `droid/followups` to `droid/harden-relay-pairing` (12:49 local);
   run tooling renamed it back to `droid/followups` after feature 2 (13:10).
   Reflog evidence: `17f3c06 … Branch: renamed refs/heads/droid/followups
   to refs/heads/droid/harden-relay-pairing` at 12:49:54 and `c2af3dc …
   Branch: renamed refs/heads/droid/harden-relay-pairing to
   refs/heads/droid/followups` at 13:10:37. End state verified this session:
   the branch is `droid/followups`, all four feature commits sit on it, it
   branches from `main` at `17f3c06` (`git merge-base main HEAD`), and
   nothing was pushed, merged or lost. The wording worker flagged the
   incident in its handoff and the orchestrator confirmed the resolution.
2. **Duplicate worker sessions.** The runner briefly assigned two workers
   each to features 1 and 3. Sessions `d4299191` and `6cbb2baa` ended
   without handoffs and were orphan-cleaned; the replacement workers
   `fea6e2b9` (relay hardening) and `cb1ca1de` (test fixes) completed those
   features and committed (`347dbe9`, `75ee9d3`). The uncommitted
   `safetyFree` helper edit left in the tree by the orphaned session was
   verified against the library design and adopted into `75ee9d3` rather
   than rewritten. Each feature still has exactly one commit and the
   working tree ended clean.

## Conservative choices (made without user input)

The five decided up front in the mission proposal:

1. **`Web/app.js` kill lists are inside the wording scope.** The mission
   names `Web/index.html` and `README.md`; the two `app.js` dashboard strings
   (revoked-badge title, issued-grant Expires line) are the same
   user-facing kill lists and were as incomplete as the HTML ones, so they
   were fixed in the same commit. CLI help strings, `Skills/keysrs/SKILL.md`
   and historical `docs/*.md` wording were left alone (out of scope,
   recorded, not changed).
2. **The pairing toggle API route is added, none existed.** `POST
   /api/relay` only takes `enabled`/`stay_awake`, so a new token-gated
   `POST /api/relay/pairings/required` carries the toggle — the mission
   names "its API route" and `HTTPServer.swift`, and it makes the proposal
   doc's ControlClient claim true. `POST /api/relay` keeps refusing a
   `pairing_required` body key.
3. **No changelog duplicates.** `## Unreleased` already listed exit code 6
   and the agent skill (lines 8-9); those were neither duplicated nor
   amended — the commit adds exactly the five missing entries.
4. **The display-only `relayPairingRequired()` read is unchanged.** The
   mission names only `verifyRelayPairing`, so the display read keeps its
   `try?`: under a broken catalog `keys relay status` can say "off" while
   the verifier fails closed. A known, deliberate display inconsistency,
   not a hole — the enforcing read refuses.
5. **This report is its own fifth commit.**

Choices the workers recorded as they went:

6. The require-off presence reason is `"stop requiring paired agents on the
   relay"`, house-style with the existing reasons, pinned in five
   `RelayPairingTests` assertions.
7. The fail-closed test induces the catalog read error with a second raw
   SQLite connection dropping the `meta` table (sqlite's schema-cookie
   invalidation makes the first connection's next prepare throw) —
   deterministic, sleep-free, and no production seam was added for
   testability.
8. `JSONValue.bool` coerces JSON `1` to `true` on this toolchain (an
   NSNumber-bridging quirk of `JSONSerialization`), so `{"required": 1}`
   toggles on rather than being refused; tests deliberately do not pin it
   as a 4xx. The coercion cannot bypass presence — only `false` costs the
   prompt, and the gated service method decides direction.
9. The CLI delegation test drives the exact delegated call through an
   in-process `LoopbackHTTPServer` with an explicit control URL (the
   suite's existing control-file round-trip pattern) instead of running the
   command against the default control file, because `ControlClient` would
   read the user's real control file and the user's real app is running.
10. No dashboard or menubar pairing UI was added; pairing stays CLI plus
    loopback API.
11. The wording commit also made the proposal's optional README addition —
    the Keys-pane action list now says an active or expired row also offers
    Renew. The two dashboard "Dies" hints stopped naming expiry as a kill
    (the grants hint instead says an expired grant can be renewed), while
    the help text and the README unattended paragraph keep expiry, since
    the window's close is still worth naming there, now alongside key
    rotation.
12. The rewritten Revoke test gates its revoked-row reads on the
    post-revoke render (revoked badge / flipped count line), not the
    `#status` line, closing the assertion-side race the in-run review found
    in the first rewrite; that worker proved determinism with ten
    consecutive isolated `KEYS_UI_ONLY` runs plus the full suite, and this
    session re-proved the full suite green.
13. No CHANGELOG entries for this mission's own changes (the hardening,
    the wording, the test fixes, this report) — the mission's enumerated
    list covers the five merged features only; adjacent unlisted work
    (`7d5df09` skill wording tightening, `17f3c06` tests-only) also stays
    out.

## Git evidence

Branch order, oldest last (`git log --oneline 17f3c06..HEAD`):

```
2cf973c List the merged profiles, renewal, rotation, pairing and vault work under Unreleased
75ee9d3 Catch typed secrets in the DOM scan and make the Revoke test deterministic
c2af3dc Name key rotation in the grant kill lists and stop calling expiry a death
347dbe9 Fail the relay pairing flag closed and gate require-off on presence
```

Scope diff (`git diff --stat 17f3c06..HEAD`; this report adds
`docs/missions/followups.md` as the twelfth in-scope path):

```
 CHANGELOG.md                                      |   5 +
 README.md                                         |  11 +-
 Sources/KeysCore/CLI.swift                        |  13 +-
 Sources/KeysCore/HTTPServer.swift                 |  18 +++
 Sources/KeysCore/KeysService.swift                |  16 +-
 Tests/KeysreallysafeTests/RelayPairingTests.swift | 189 +++++++++++++++++++++-
 Web/app.js                                        |   8 +-
 Web/index.html                                    |   6 +-
 docs/proposals/relay-pairing.md                   |  33 ++--
 docs/relay.md                                     |  18 ++-
 scripts/tests/test_keys_dashboard_ui.cjs          |  61 ++++---
 11 files changed, 324 insertions(+), 54 deletions(-)
```

Boundary checklist, verified this session:

- One commit per item plus this report; the working tree ends clean.
- Nothing pushed, merged, tagged or deployed; no version bump. No tag
  points at any of the five commits and none is on `origin/main`.
- `CLAUDE.md`, the repo `AGENTS.md` symlink, `Site/`, `.github/` and the
  historical `docs/missions/*.md` are untouched by the four feature commits
  (empty diff); this report is the one new file under `docs/missions/`.
- README Privacy boundaries (lines 68-125) byte-identical: all four README
  hunks start at lines 246, 335, 361 and 394 — none touches the section.
- The installed `/Applications/Keysrs.app` and ports 12766/12767 were never
  touched; every test run was offline with the synthetic fixture
  environment and synthetic sentinels only.
