# Mission report: permission profiles and unattended grants

Run on 2026-10-27 in the worktree
`/Users/Shost2/Projects/Keysreallysafe/.claude/worktrees/droid-profiles`,
branch `droid/write-permission-profiles`, over commits `f64114b` (proposal),
`d762ff4` (profile model, storage, CLI), `b271e08` (bounded issuance),
`d0ad905` (gateway denial tests), `bfedfe5` (dashboard picker and badges) and
the docs commit that adds this report. Nothing was pushed.

The mission added **permission profiles** — named, saved issuance-time bounds
(key names, methods, path scopes, minutes, a request cap, a dollar cap, an
unattended flag), stored in the catalog with no secret and no token — and made
unattended grant use an explicit, bounded flow. A profile is consulted only
when a grant is issued; the gateway request path never reads it. Every grant
still costs exactly one Touch ID whose prompt names the effective scope, a
request may tighten a profile's values but never exceed them, an unattended
profile must carry at least one hard cap, and an unattended grant still dies
on screen lock, expiry, revoke, gateway off and restart — a job that must
outlive a lock still needs a client token. The README "Privacy boundaries"
section was not touched (diff-verified verbatim-identical, see below).

## Test results

The full CI list, run offline on this machine, serialized one command at a
time (two `swift test` runs would corrupt the shared `.build/`, and this 8 GB
machine shares memory with a sibling worktree's browser tests). Node was
v26.7.0 locally where CI pins 22; all suites pass on both.

| Command | Exit | Result |
|---|---|---|
| `env CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home swift test` | 0 | `Executed 552 tests, with 5 tests skipped and 0 failures (0 unexpected) in 46.897 (46.964) seconds` |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | `Ran 62 tests in 0.972s — OK` |
| `python3 -m unittest Analytics/test_collector.py` | 0 | `Ran 19 tests in 9.805s — OK` |
| `(cd Relay && npm ci && npm test)` | 0 | `Test Files 1 passed (1)`, `Tests 36 passed (36)` |
| `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | `Keys dashboard UI passed: 96 cases` |
| `env NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | exit 0; the suite prints nothing on success (run twice to confirm — the exit code is the pass signal) |
| `(cd scripts/tests && npm run test:e2e)` | 0 | dashboard target `Tests 4 passed (4)`, marketing target `Tests 1 passed (1)` |
| `env KEYS_BACKEND_CONTRACT_UI=1 CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home swift test --filter BackendContractUITests` | 0 | `Backend contract UI passed: 10 cases`, `Executed 1 test, with 0 failures` |

**Skips (all expected, all environment-gated, none a failure):**

- 3 × `RelayEndToEndTests` — `Test skipped - set KEYS_RELAY_E2E_URL and
  KEYS_RELAY_E2E_SECRET with wrangler dev running`.
- 1 × `StableSigningTests` — `Test skipped - requires Apple signing identity;
  run before deploying signing changes`.
- 1 × `BackendContractUITests` inside the unfiltered `swift test` —
  `Test skipped - browser contract harness: set KEYS_BACKEND_CONTRACT_UI=1
  with the pinned Playwright Chromium installed`. Run with the variable set
  (last table row) it passes fully: 10 cases, 0 failures.

Nothing failed. The workerd stream-teardown line (`identity-transform-stream
… reader canceled`) during the Relay tests is the documented benign noise, not
a failure. No transient `RelayHostTests` flake occurred in this run.

Coverage highlights for this mission's surface, all inside the green runs
above: `ProfileTests` 8/8 (validation matrix, CRUD round-trip storing bounds
only, unattended-requires-cap, CLI shapes); `GrantTests` profile-bounded
issuance including the refusal matrix with an empty prompt log and the pinned
profile-grant prompt string; `ProfileGrantGatewayTests` 9/9 (method, path,
key/host, expiry, request/USD/unpriced caps, screen lock, restart — all
through the real loopback gateway); the dashboard suite's three new cases
(`the grant dialog offers only this key's profiles, and picking one prefills
the scope`; `grant rows show the profile and the unattended badge, and
unpriced spend never reads $0`; `the grants area lists saved profiles with
their bounds, and Remove deletes them`); and the backend-contract scenario's
new case `a profile bounds a real grant end to end and removes cleanly`
against the real Swift backend.

## Conservative choices ledger

Every judgment call made autonomously during the mission, with its rationale.

1. **Unattended grants do not outlive a screen lock.** The kill paths are
   unchanged; the README sentence answering that case (a job that must outlive
   a lock needs a client token) stays literally true and is cross-referenced,
   never amended.
2. **An unattended profile requires a hard cap** (`--max-requests` or
   `--max-usd`), validated at save and re-checked at issuance: an unwatched
   grant is pre-committed to a number the user read at approval.
3. **No auto-renewal, no auto-reissue.** A new grant is a new prompt; renewal
   would mint capability while the user is away. Rejected alternative.
4. **No analytics changes.** Nothing new is sent — no profile counters, no new
   vocabulary; `recordKeyEvent` maps no new events for profile actions.
5. **No CHANGELOG entry.** The three feature commits after the 0.12.0 release
   (`ffd3df4`, `de970af`, `6731218`) did not touch `CHANGELOG.md`; this
   mission follows that convention and records the choice here instead.
6. **No `updateProfile`.** Editing a profile is remove + re-add: a deliberate
   scope cut with no committed surface needing updates (VAL-PROFILE-001 asks
   for create/list/remove only). If a surface later needs in-place edit, it is
   added with tests then.
7. **`ProfileError` shares two wire codes across case pairs**: `.keysMissing`
   and `.keyUnknown` both send `profile_key_unknown`; `.methodMissing` and
   `.methodUnknown` both send `profile_method_unknown`. They remain distinct
   enum cases with distinct messages — satisfying the distinct-named-error
   contract — and no caller needs to distinguish "empty" from "unknown" on the
   wire. Recorded as a choice, not hidden.
8. **Agent revoke-on-exit on a NORMAL exit is covered by mechanism, not by a
   dedicated new test.** `keys agent` cleans up through the same
   `defer { cleanup() }` path this mission never modified, and that path is
   proven directly by the pre-existing signal-death and failed-launch tests.
   Disclosed as a residual so this report does not overstate direct coverage.
9. **Host-edit kill over HTTP surfaces as 404, not 403.** Retargeting a key
   turns its gateway off (the edit revokes with reason `target_changed`
   first), so a caller sees `404 not_found`; the `grant_target_changed` code
   is pinned at unit level on the authorize path.
10. **Profiles act only at issuance; profile CRUD prompts nothing.** A profile
    row holds no secret and no capability, so `keys profile` works straight
    off the catalog with no Touch ID; the issuance prompt remains the only
    gate that mints anything. Recorded because it is new prompt-free surface.
11. **Hosts are not a profile field.** The host follows the key's provider;
    key choice bounds the host transitively and the `grant_target_changed`
    kill path keeps its exact meaning.
12. **Paths are stored as a JSON array**, not CSV: `GrantPath.normalize`
    allows characters (commas) a CSV would corrupt, and grant behavior must
    not change to make storage easier.
13. **No cascade delete of profiles when a key is deleted.** Profiles
    reference names; issuance under a profile whose key is gone fails closed.
    Removing a stale profile is the user's deliberate act.
14. **`unattended` never appears as a per-grant CLI flag**; it comes only from
    a saved, validated profile.
15. **Grant + gateway-on still folds into one prompt**, unchanged.
16. **The `BackendContractUITests` profile case was added, not deferred**: the
    ordered real-backend scenario gained `a profile bounds a real grant end to
    end and removes cleanly` (`scripts/tests/test_backend_contract_ui.cjs`),
    taking the suite from 9 to 10 cases.
17. **Gateway-test seams stayed honest about time**: past-expiry is reached by
    issuing through the store with a back-dated `now` (the same store method
    `issueGrant` calls), because `issueGrant` has no clock seam and minutes
    are ≥ 1. Request and USD caps remain post-hoc checks, as documented in the
    gateway docs.
18. **Environmental fact, recorded: the mission runner renamed the worktree
    branch from `droid/grant-profiles` to `droid/write-permission-profiles`
    at session start.** All commits sit on the renamed branch; mission
    documents that still say `droid/grant-profiles` refer to the same branch.
    A near-duplicate proposal snapshot commit exists only in a snapshot ref
    and on no branch; it is ignored.
19. **README docs were kept additive**: the profiles prose and the Commands
    block entries were added in the feature sections only; the
    `## Privacy boundaries` section is verbatim-identical to `ffd3df4`
    (verified with `diff` on the extracted section, not by eye).

## No-secrets audit

- The sentinel tests pass in the full suite:
  `ProfileTests.testProfileCRUDRoundTripsThroughTheCatalogStoringBoundsOnly`
  (proves a profile round-trip leaves no sentinel on disk in the temp
  catalog), plus the pre-existing sentinel guards
  (`GatewayTests.testRoundTripStripsClientAuthInjectsSecretAndOmitsSentinelFromCatalog`,
  `ClaudeIngestTests.testCostUsdTicksNullAndSentinelNotStored`,
  `RemoteImportHardeningTests.testReimportNeverReplacesAValidTimeWithTheEpochSentinel`)
  all passed.
- Every line this mission added (all commits `ffd3df4..HEAD` plus the README
  and this report) was scanned for secret-shaped strings — grant/client token
  shapes (`ksf_…`, `ksfc_…`), provider key shapes (`sk-ant-`, `sk-proj`,
  `sk-` + 32, `AIza…`, `xai-…`, `gsk_…`, `AKIA…`) and private-key blocks. **No
  matches.** The only `secret:`/`token:` occurrences in added lines are test
  fixtures passing the synthetic `fixtureSecret`
  (`"unit-test-secret-value-xyz"`), `"synthetic-vck"`, or runtime-issued
  token variables — never literals.
- Profile rows hold bounds and names only; the `grant_profiles` table has no
  secret, token or hash column. Agent config files were not touched and remain
  env-var references.

## Remaining human checks

Real Touch ID and the real vault cannot be exercised autonomously; presence
behavior is pinned via `RecordingPresenceGate` reason assertions instead.
Before shipping, a human should try, in the real app:

1. `keys profile add evals --keys <key> --methods POST --paths /v1/messages
   --minutes 480 --max-requests 500 --max-usd 2 --unattended`, then
   `keys profile list` and `keys profile remove evals`.
2. `keys grant <key> --profile evals` and read the real Touch ID prompt: it
   must name the task, key, provider, host, lifetime, the profile, the
   effective methods/paths/caps and the word "unattended".
3. The grant dialog's profile picker in the real dashboard: only profiles
   naming the opened key appear, and picking one prefills the scope.
4. `keys grants` and the dashboard grant rows showing the profile name and
   the unattended badge.
5. Locking the screen with an unattended grant active: the grant dies, exactly
   like a watched one.
