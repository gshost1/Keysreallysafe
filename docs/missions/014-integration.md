# 0.14 integration — closeout report (mission 014)

**Branch note.** The harness renamed this worktree's branch once: it began as
`droid/014-integration`, and at 16:45:43 on 2026-10-28 the reflog records
`Branch: renamed refs/heads/droid/014-integration to
refs/heads/droid/merge-headless-branch-into`. Exactly as the merged mission
reports handled their renames, the current name was accepted for the run:
every worker committed on the checked-out branch (resolved via
`git rev-parse --abbrev-ref HEAD`), nobody renamed, switched or created
branches mid-run, and both merge commits sit on it. Nothing was pushed.

The mission integrated the 0.14 cycle on top of the mcp-core + onboarding base
(`02dd7d8`/`699fdb5`): it merged the headless mission branch
(`droid/execute-headless-lifecycle`, tip `07e152f`) and the feedback mission
branch (`droid/014-feedback`, tip `1b1bd8e`), unified the MCP registry to the
16-tool union across 8 groups, wired the analytics counter producers the
feedback mission left for integration, applied the owner's 23 review fixes
(F1–F6, G1–G3, O1–O9, H1–H8 minus the H6 no-change item, each with a failing
pre-fix regression test), and shipped the 0.14.0 release artifacts in-repo.
Nothing was published: no `wrangler deploy`, no `gh release`, no brew commands,
no repository creation, no push of any remote.

Scope against the merge base `02dd7d8`: 112 files, +22,657/−643 plus this
report — the two merge commits, 34 integration commits after them, all inside
`Sources/KeysCore`, `Tests/KeysreallysafeTests`, `docs/`, `README.md` (body
regions only, below), `scripts/`, `Analytics/` (the four onboarding counters
in the collector vocabulary and its tests, via the feedback merge), `Web/`
(the dashboard surface, via the merges), `Relay/` (nothing), `Skills/`, and
the new `packaging/homebrew/keysrs.rb`. `Site/`, the README headline block
and all Show HN copy are untouched (audit below). The four mission reports
(`docs/missions/014-mcp-core.md`, `014-onboarding.md`, `014-headless.md`,
`014-feedback.md` — the last two arrived with the merges) describe every
feature this mission had to preserve; the merge log below records how each
conflict was resolved so both sides survived.

## What the mission changed

| Feature | Commit(s) | What it landed |
|---|---|---|
| merge the headless mission | `2338f00` | Plain `git merge` of `droid/execute-headless-lifecycle` (5 textual conflicts, all resolved by union; onboarding's additions rewired through headless's throwing, `launch:`-parameterized, isolation-guarded roster signature). |
| merge the feedback mission | `a76522d` | Plain `git merge` of `droid/014-feedback` (8 textual conflicts including `AppRuntime.swift` on the second merge; registry unified to the 16-tool union; feedback's app-bound tools rewired through the launch seam). |
| unified registry audit | `0045cab`, `a7040da` | The exact-set test (16 tools, `neverRegistered = [grant_cancel, unwrap]`, no forbidden kinds), the planted-secret sweep over every tool with runtime-built fakes, and the deferred counter producers (`scan_run` via the app-side vault comparison, `key_import`, `grant_issue` for the MCP caller, `onboarding_finished`) behind the analytics opt-in. |
| F1–F6 scrubber hardening | `ee83d15`, `18b6ef0`, `bff93e5`, `bb59128`, `6d23f42`, `866f472`, `2b6ad4c` | `prompt_text` runs right after `vault_value`; paths matched in any context with the pinned http(s) survivors kept; name/label patterns case-insensitive, escaped via `escapedPattern(for:)`, fail closed (the whole call refuses); obfuscated vault values (whitespace/zero-width inserts, percent-encoded, base64) and line-break-split Keysrs tokens caught; the encoded mailto URL capped at ~2,000 chars with the footer always kept and the cut reported in the result; fullwidth `＠` emails caught with the ASCII support-address exemption unchanged. |
| G1–G2 grant claim security | `cf6ccbf`, `8e001f6` | Each grant ask bound to a random 32-hex poll secret returned only to its creator (never in listings, logs, audit detail or notifications; wrong/missing secret answers the house 404); the no-id listing lists only ids the caller proves; `MCPPendingGrants.approve` re-checks expiry under the lock and a grant approved after its ask lapsed is revoked instead of stranded. |
| O1/O4/O5/O8 unwrap + uninstall safety | `f134a60`, `f6ccfaf`, `dfbaa19`, `e50fcdb` | Companion-derived keys validated per line against the line's own token; a deleted recorded file is stale (record cleared, unwrap proceeds per project, uninstall completes); a token another recorded file still holds is kept with the file named; only the companions the wrap recorded writing are removed (new `companions` column), hand-written ones left and reported, legacy rows keep the documented removal fallback. |
| O2/O3/O6/O7/O9 wrap/import/scan safety | `daeffa8`, `c8f0c8d`, `44aca9c`, `f3b3ba0`, `5b5e541`, `6c21892` | Backups move to `<catalog dir>/backups/<project-hash>/` (0700/0600, catalog-derived so `KEYS_CATALOG` isolation keeps working; legacy in-project backups still restore); the result says a backup was kept without a path; the Docker Touch ID reason names the Docker reach and the preference is written only after a successful rewrite; `scan_project`/`check_exposure`/`import_and_wrap` refuse folders outside the session working directory subtree (`/` and `~` refused, path-free errors); a rewrite failure after mint revokes the token with path-free errors; verify/rewrite go through the realpath-resolved file re-checked under the project root right before writing. |
| G3+H1 test isolation tripwire | `b47e371`, `bb44db6` | Under XCTest (linked-framework detection; the classic env var stays for harness runs) or `KEYS_TEST_ISOLATION`, with `KEYS_CATALOG` unset: resolving the real control.json/catalog/Application Support path throws, `KeychainStore` refuses, no-arg `ControlFile.url()`/`AppConnection.connect()`/`AppFactory.makeService()` throw; the structural belt covers the merged onboarding + feedback rig files; the remaining direct catalog openers route through `Paths.resolvingCatalog()`. |
| H2–H4 update/launch lifecycle | `26ba4f9`, `a93f5e1`, `0af8482` | The background install re-checks idleness right before the swap and right before the quit (busy defers, no relauncher, no quit); the app launches only from `AppConnection.installedAppURL` (a LaunchServices resolution to e.g. `/Volumes/Keysrs/Keysrs.app` is refused); the install also waits while the relay is on or any grant/client token was in active use in the last 5 minutes. |
| H5/H7/H8 headless surface | `bc3b93a`, `bfe0eec`, `459a049` | `applyHeadlessDefaults` keeps an explicitly stored "off" for update checks; guided `keys add` rejects a secret-shaped name (provider prefixes, Keysrs token prefixes, long high-entropy strings) without storing or printing it; `keys dashboard` from a checkout build serves the checkout's `Web/` on :12765 again (honoring `KEYS_NO_OPEN`) while the bundled binary fronts the app's window. |
| README dev-copy reconciliation | `3f284c7` | The three README regions the merged headless branch had written about `keys dashboard` (its paragraph and the two dev recipes) restated to match the restored checkout/bundle branch — headline block untouched (audit below). |
| version + changelog | `b45936e` | `ProductAnalyticsConfiguration.appVersion` → `"0.14.0"` (the single constant; Info.plist verified against it by the tooling tests), `docs/agents.md`'s example output line, and one `## Unreleased (0.14.0)` CHANGELOG entry in the bold-led house style describing the grants-first cycle. |
| Homebrew cask | `93af2d8` | `packaging/homebrew/keysrs.rb` for the unpublished tap `gshost1/homebrew-keysrs` (versioned release-download URL, `sha256 :no` placeholder, `auto_updates true`, `depends_on macos ">= :sonoma"`, `app "Keysrs.app"`, the `binary` stanza, the `zap` stanza over the frozen paths) plus the `--fill-cask`/after-`make_dmg` step in `scripts/prepare-release.py` that fills version and sha256 at release time, its test in `scripts/tests/test_release.py`, and the `docs/release.md` section. |
| manual e2e checklist | `6e7524d` | `docs/manual-e2e-0.14.md`, the 10-minute owner run of the whole 0.14 surface with exact commands/phrases and expected observations, fakes built at runtime inside the recipe. |
| CI closeout (this commit) | `38f6413` + this report | The one compiler warning the mission itself introduced (`MCPGrants.swift:413`, from the G2 fix) cleaned up before the final run; the full 8-suite CI list re-run end to end; the invariants audit; this report. |

## The CI list, end to end

The exact 8-suite list from `.github/workflows/test.yml` (identical to
`commands.test` in the mission's services manifest), run from the worktree
root, one step at a time, sequentially, nothing subsetted, with the CI
environment (`CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/
grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/
droid-home`; the node steps additionally with
`NODE_PATH=scripts/tests/node_modules`, step 8 additionally with
`KEYS_BACKEND_CONTRACT_UI=1`). Exit codes and summary lines are the real
ones from this session, at commit `38f6413` (after the warning cleanup):

| # | Command | Exit | Verbatim summary |
|---|---|---|---|
| 1 | `swift test` | 0 | `Executed 1070 tests, with 5 tests skipped and 0 failures (0 unexpected) in 201.575 (201.767) seconds` |
| 2 | `(cd Relay && npm test)` | 0 | `Test Files  1 passed (1)` / `Tests  43 passed (43)` |
| 3 | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | `Ran 76 tests in 6.604s` / `OK` |
| 4 | `python3 -m unittest Analytics/test_collector.py` | 0 | `Ran 20 tests in 10.677s` / `OK` |
| 5 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | `Keys dashboard UI passed: 146 cases` |
| 6 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | silent on success by design — zero output bytes, the exit code is the verdict |
| 7 | `(cd scripts/tests && npm run test:e2e)` | 0 | dashboard: `Test Files  1 passed (1)` / `Tests  4 passed (4)`; marketing: `Test Files  1 passed (1)` / `Tests  1 passed (1)` |
| 8 | `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=… swift test --filter BackendContractUITests` | 0 | `Backend contract UI passed: 12 cases against http://127.0.0.1:62829` / `Executed 1 test, with 0 failures (0 unexpected) in 4.569 (4.570) seconds` |

### What passed

Every step above. In full: 1,070 XCTest cases (0 failures, 5 pre-existing
opt-in skips), Relay 43/43 in workerd offline, 76 packaging-script tests, 20
collector tests, 146/146 dashboard UI cases, the analytics UI check (silent
pass), e2e 5/5 (vault round trip, rotation, gateway spend, duplicate key,
marketing site), and 12/12 backend-contract browser cases against the real
Swift backend on an ephemeral port. Nothing failed, so there are no failure
transcripts to paste; the only diagnostics in any log are the known benign
ones listed below. All runs were offline: loopback-only fixture servers on
ephemeral ports, synthetic fixtures and temp homes, no Keychain, no Touch ID,
no clipboard, no provider calls, and the owner's live app on ports
12766/12767 was never touched.

### What was skipped

Inside step 1's `swift test`, five pre-existing opt-in skips (none added by
this mission):

- `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` — needs
  `KEYS_BACKEND_CONTRACT_UI=1` and the pinned Playwright Chromium; that is
  exactly step 8 of this same CI list, where it ran green with all 12
  browser cases.
- `RelayEndToEndTests` (3 tests:
  `testRealWebSocketRoundTripThroughWranglerDev`,
  `testACallDuringAShortOutageWaitsForTheAppRelayAndALongOneGetsA503`,
  `testAWrongSecretIsReportedAsTheWorkersRefusal`) — opt-in via
  `KEYS_RELAY_E2E_URL`/`KEYS_RELAY_E2E_SECRET` with `wrangler dev` running;
  deploy tooling is forbidden by the mission boundaries, and the same
  behavior is covered offline by `RelayTests`/`RelayHostTests` and the
  workerd suite (step 2).
- `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation` —
  requires an Apple signing identity; there were no signing-identity changes
  in this mission (the stable-identity DR and its tests are unchanged).

Nothing else was skipped: no CI step was omitted and no suite was narrowed.

### Warnings and noise

- **The one warning this mission introduced, fixed in this closeout.** The
  G2 grant-claim fix ended its stranded-grant cleanup with a bare
  `try? self.revokeGrant(...)`, whose Grant result the compiler flagged:
  `Sources/KeysCore/MCPGrants.swift:413:21: warning: result of 'try?' is
  unused`. It was still present before the final run; commit `38f6413`
  discards the result explicitly with `_ =` (the revoke is side-effectful —
  it ends the grant the lapsed ask minted — so dropping the call was not an
  option; the `try?` stays, since an already-revoked grant must not crash the
  approval thread). `MCPGrantTests` re-ran green after the fix (26/26), and
  a full forced rebuild of every source file now emits exactly the carried
  warnings below — nothing else.
- **Carried pre-existing build warnings** (present on the pre-mission
  baseline, deliberately not fixed): unused `try?` at
  `Sources/KeysCore/AppUpdater.swift:415` and unused `withLock` result at
  `Sources/KeysCore/CatalogDB.swift:544` (line numbers drift as code lands
  above them).
- **Headless-inherited warning** (not merge-caused): the Swift 6 Sendable
  warning for the `scheduleQuit` closure in `Sources/KeysCore/HTTPServer.swift`
  — first at line 145 on headless's own branch, now at line 158 after the
  feedback merge's added initializers. It is headless's own code; changing
  the closure's signature would touch the quit path, so it is left unfixed
  and recorded here.
- **Python suite noise (baseline, not mission-caused).** Step 3 prints, in
  every run, a `ResourceWarning: unclosed file` (Python 3.9's temp-file
  handling in the stdio harness) and three ingest-test `export.jsonl` stderr
  lines (`…/export.jsonl: droid requests 3, claude requests 2, droid session
  totals 1` and variants). The pre-mission readiness baseline (2026-10-28,
  before any mission commit) recorded the same noise; this run shows the
  same lines, so it is baseline, not mission-caused. The suite itself is
  `OK`.
- **workerd teardown line** in the Relay run (pre-existing, a workerd
  shutdown artifact, the suite still reports 43/43):
  `exception = workerd/api/streams/identity-transform-stream.c++:291: disconnected: reader canceled`.
- **Swift-Testing's zero-test line** after the filtered step 8
  (`Test run with 0 tests in 0 suites passed`) — the non-XCTest runner
  reporting zero matches, not a failure.
- The headless-inherited dead no-arg `makeVault()` in
  `Tests/KeysreallysafeTests/ReadToolsTests.swift` (dead on headless's own
  branch too) compiles silently but is noted here as carried dead code.

## Merge conflicts and resolutions

Both merges were plain `git merge` (no rebase, no force, no push; the other
worktrees were read-only and their HEADs are unchanged after both merges:
headless `07e152f`, feedback `1b1bd8e`). Branch names were discovered at
merge time via `git -C <worktree> rev-parse --abbrev-ref HEAD`. In both
merges `git merge-tree --write-tree` predicted the conflict set exactly (5
files, then 8); actual conflicts matched with no surprises.

### Merge 1 — `droid/execute-headless-lifecycle` → `2338f00` (2026-10-28)

Merge-base `02dd7d8`; ours `699fdb5` (onboarding tip), theirs `07e152f`.
Five conflicted files:

- **`Sources/KeysCore/AppConnection.swift`** — onboarding had added
  `presenceCallTimeout` (120 s) as a static let; headless had rewritten
  `connect()` into the launch-policy seam with `appBundleID`/
  `installedAppURL` and `connect(control:launch:)`. Resolution: union —
  kept `presenceCallTimeout` and every headless launch constant; headless's
  `connect(control:launch:)` structure wins and the `call(..., timeout:)`
  parameter survives. The class doc now states `keys unwrap` is on the
  branch and deliberately keeps the plain control client (no auto-launch).
- **`Sources/KeysCore/MCPOnboardingTools.swift`** (semantic, no textual
  conflict) — headless's signature change left onboarding's three
  `AppConnection.connect` calls on the production default launch seam, so
  every onboarding rig attempted a real app launch (~20 s per call, 8
  failing tests before the fix). Resolution: added
  `launch: AppLaunchSeam = .production` and routed all three connects
  through it; production wiring keeps `.production`, every rig passes
  `.neverLaunching`.
- **`Tests/KeysreallysafeTests/MCPServerTestSupport.swift`** — 2 hunks: the
  `MCPRoster` doc comment (onboarding named "the grants and onboarding
  groups", headless the fail-closed note) and the `groups(...)` array
  (onboarding appended `MCPOnboardingTools(...)` on the old signature;
  headless added `launch:` to the read/grant groups). Resolution: union of
  the doc comment; the array adopts headless's launch-parameterized
  signature and adds `MCPOnboardingTools(control:projectFolder:launch:)` —
  the full roster.
- **`Tests/KeysreallysafeTests/ReadToolsTests.swift`** — 2 hunks in
  `makeSite`'s guarded world: onboarding used `makeVault()` +
  `assertNotProductionPath`; headless used
  `AppConnectionIsolationGuard.makeWorld(secrets:)`. Resolution: adopted
  headless's `makeWorld`-based `makeSite` (required — headless's structural
  belt scans this file and demands the IsolationGuard token before any
  control-URL use) and kept onboarding's `assertNotProductionPath(catalog)`
  and `(control)` checks beside it, so both guards stay active on the rig.
  (The now-unused no-arg `makeVault()` is dead on headless's branch too and
  was left in place.)
- **`Tests/KeysreallysafeTests/MCPClientFlowTests.swift`** — 1 hunk: the
  `PipeClient` environment (onboarding's git-config determinism pins vs
  headless's `KEYS_TEST_NO_LAUNCH=1`). Resolution: union — the no-launch
  var first, `extraEnvironment` merged on top. Plus the same belt
  requirement for onboarding's `makeOnboardingRig`: it gained
  `AppConnectionIsolationGuard.assertIsolated(control:launch:
  .neverLaunching)` immediately before `ControlFile.write` (keeping
  `assertNotProductionPath` too).
- **`docs/agents.md`** — 1 hunk: the exit-6 paragraph. Resolution: union —
  headless's accurate auto-launch description (app-bound commands first try
  to launch and wait, then exit 6 with the pinned sentence), plus one
  sentence naming `keys unwrap` as printing the same sentence but never
  launching (onboarding's shipped choice; see decision 2).

Integration fixes the merge required (not textual conflicts):
`ImportAndWrapTests`/`TestKeysToolTests` moved to headless's throwing
`try rig.registry()`; the four onboarding tool rigs pass
`launch: .neverLaunching`; `AppLaunchSeamTests`' caller map gained
`UnwrapCommand` (unwrap keeps the plain control client) and its old "keys
unwrap is not implemented on this branch" assertion became a parse
assertion since unwrap is real now. Auto-merged both-sides files were
reviewed by hand (README.md, `Skills/keysrs/SKILL.md`, `Sources/KeysCore/
{CLI,CatalogDB,Gateway,HTTPServer,KeysService,Preferences,Support,Providers,
Menubar,AppWindow,AppRuntime,MCPGrants}.swift`, the merged test support,
`Web/{app.js,index.html}`, `scripts/{build-app.py,tests/*}`): the
`HTTPServer.swift` route switch carries both sides' routes, and no semantic
conflict was found. Every feature named in `014-onboarding.md` and
`014-headless.md` verified present; all suites green after the merge.

### Merge 2 — `droid/014-feedback` → `a76522d` (2026-10-28)

Merge-base `02dd7d8`; ours `2338f00`, theirs `1b1bd8e`. Eight conflicted
files (the 7 predicted plus `AppRuntime.swift`, as planned for the second
merge):

- **`Sources/KeysCore/MCPToolRegistry.swift`** — the one `groups` line.
  Resolution: union — the 8-group, 16-tool line
  (`MCPVersionTool`, `MCPReadTools`, `MCPGrantTools`, `MCPOnboardingTools`,
  `MCPFeedbackTools`, `MCPAnalyticsTools`, `MCPRevokeTools`,
  `MCPActivityTools`).
- **`Tests/KeysreallysafeTests/MCPRegistryTests.swift`** — the two branches
  pinned mutually-contradictory roster literals (onboarding asserted
  feedback's tools absent; feedback asserted onboarding's absent).
  Resolution: regrew to the 16-tool union in registry order;
  `neverRegistered` is exactly `["grant_cancel", "unwrap"]`; the stale doc
  literal ("the mission's eight tools") became "sixteen tools".
- **`Tests/KeysreallysafeTests/MCPServerTestSupport.swift`** — 2 hunks:
  `MCPRoster.groups` (feedback's four groups on the old signature vs
  onboarding's on headless's) and `MCPSweepRig.argumentRows` (onboarding's
  four rows vs feedback's five). Resolution: union — every app-bound group
  on the launch-parameterized signature, feedback's four groups appended
  with a `launch:` argument, `argumentRows` carrying rows for all 16 tools.
- **`Sources/KeysCore/HTTPServer.swift`** — 5 hunks: the stored-property
  seam block, the init parameter list, the init assignments (onboarding's
  preferences/quit seams vs feedback's `openFeedbackURL` seam), the
  `/api/mcp/*` route dispatch (onboarding's `vault_lookup`/
  `import_and_wrap`/`test_keys` vs feedback's `feedback`/
  `analytics/sharing`/`revoke_all`/`revoke_project`), and the handler region.
  Resolution: union on every hunk — both sides' seams, all seven `/api/mcp/*`
  routes in order, both handler sets; the expiry poll and headless's
  `/api/preferences/*`, `/api/app/quit`, `/api/relay*` routes (already
  present from merge 1) stay.
- **`Sources/KeysCore/KeysService.swift`** — 1 hunk: onboarding's project
  services vs feedback's bulk-revoke services. Resolution: union — all of
  both; the two project-revoke overloads coexist (onboarding's 1-arg
  `revokeGatewayClients(project:)` for `keys unwrap`, feedback's 3-arg
  `revokeGatewayClients(project:caller:now:)` with the audit walk for
  `revoke_project`/`revoke_all`; see decision 18).
- **`Sources/KeysCore/AppRuntime.swift`** — 1 hunk: headless's
  `AppNotifier` line vs feedback's `service.analyticsLog` seam. Resolution:
  union — both lines run, in headless's order, before the site binds.
- **`Tests/KeysreallysafeTests/MCPClientFlowTests.swift`** — 1 hunk: the
  PipeClient roster pin (11 vs 12 tools). Resolution: the 16-tool union —
  and a second, non-conflicted stale 11-tool pin inside
  `testOnboardingDoneCriterionFlow` was regrown to the same union after it
  failed at run time.
- **`docs/agents.md`** — 1 hunk: the tools list. Resolution: union — all
  nine bullets (onboarding's four, feedback's five) in registry order; the
  exit-6 paragraph from merge 1 unchanged.

Semantic merge work the resolution required: the auto-merged
`CatalogDB.swift` carried a duplicate byte-identical
`revokeGatewayClients(project:at:)` (both branches added it) — feedback's
copy removed, onboarding's stays; feedback's four app-bound tool groups
gained `launch: AppLaunchSeam = .production` (the merge changed
`AppConnection.connect`'s default to auto-launch, so they would otherwise
attempt a real launch in any test with an unwritten control file — the
exact isolation failure the guards exist to prevent); all six feedback test
rig constructions pass `.neverLaunching`; the throwing `MCPRoster.registry`
rewired in `ActivityToolsTests`/`AnalyticsToolsTests`/`FeedbackToolsTests`/
`RevokeToolsTests`; `RevokeToolsTests`' CLI subprocess rig sets
`KEYS_TEST_NO_LAUNCH=1`; and its app-down wording pin moved to the unified
"Keysrs isn't running. Open Keysrs from Applications, then try again."
sentence (exit 6 and empty stdout unchanged). Auto-merged both-sides files
were reviewed by hand (README.md with the headline block verified
byte-identical, `Skills/keysrs/SKILL.md`, `CLI.swift` — `RevokeCommand`
carries both headless's launch seam and feedback's `--all` combined route —
`CatalogDB.swift`, `MCPAppConnectionTests.swift`). Every feature named in
`014-feedback.md` verified present (send_feedback + scrubber/delivery, the
counter vocabulary + `set_analytics_sharing` + the `analyticsLog` seam,
`revoke_all`/`revoke_project` + the CLI `--all`, `activity`, and the frozen
server-instructions rule 7 with its byte-pinned test copy); all suites
green after the merge.

## Decisions made without user input

Nobody was available during this run; every choice below was made from the
brief, the architecture, the owner's review list and the validation
contract, and recorded in the mission decision log as it happened. Entries
1–11 are the orchestrator's planning decisions; the rest were made by
workers in order.

1. **Merge order: headless first, then feedback** — the order the mission
   statement names them; the second merge adds the `AppRuntime.swift`
   conflict, which is manageable in the merge that already unions the
   registry.
2. **`keys unwrap` keeps exit-6/no-auto-launch.** The grants-first Owner
   review says "`keys unwrap` auto-launches the app like `keys wrap`", but
   the onboarding mission deliberately shipped no-auto-launch (recorded in
   its report) and the owner's later review of the merged branches (the
   F/G/O/H list) is silent on it. Conservative: keep the shipped behavior
   and record the tension; launch-behavior changes are high-blast.
3. **Feedback's deferred seams are in scope.** The feedback report
   explicitly left the onboarding counter producers (`scan_run`,
   `key_import`, `grant_issue`, `onboarding_finished`) and the
   `KeysService.analyticsLog` seam for integration; without them a shipped
   feature (the vocabulary pinned by both sides' tests and the golden
   fixture) stays producer-less.
4. **F3 fail-closed semantics: the whole call refuses.** If any scrubber
   pattern fails to compile, the whole `send_feedback` call fails (error
   surfaced, nothing opened) rather than sending partially-scrubbed text.
5. **O6 covers `import_and_wrap`'s folder input too.** The owner named
   `scan_project`/`check_exposure`, but the write path takes the same input
   and the same safety property applies; `EnvScan` itself stays permissive
   because the import path calls it with the caller's own folder.
6. **O8 legacy rows keep the removal fallback.** Rows written before the
   companion record exists have no record to consult; the documented
   fallback stays, and only new wraps gain the record.
7. **CHANGELOG heading: `## Unreleased (0.14.0)`** — the mission says "one
   Unreleased (0.14.0) entry"; no Unreleased convention exists yet and the
   release is not cut, so no date in the heading.
8. **Cask URL: the versioned GitHub release download pattern**
   (`releases/download/v<version>/Keysrs-arm64.dmg`) with `version` and
   `sha256` both filled by the new `prepare-release.py` step — the
   Homebrew-idiomatic form of "the latest GitHub release URL pattern"
   (confirmed by the cask worker; see entry 59).
9. **README: this mission's plan made no README changes** — the headline
   block (lines 1–11) is identical across all branches and the mission
   explicitly leaves site, README headline and Show HN copy unchanged. The
   harness later scoped one dedicated feature,
   `readme-dev-copy-reconciliation`, whose spec authorized
   reconciling the specific stale lines a *merged* mission had written
   (H8 had restored the checkout dev copy the headless branch's README text
   said was gone). That feature supersedes the blanket note for exactly
   those lines; the hard constraints held — headline byte-identical, exactly
   three hunks, Site/ and Show HN untouched (audit below). The inherited
   body edits from the merges (the missions' factual feature docs —
   onboarding's `keys unwrap` tour and command-reference entries; headless's
   dashboard paragraph and dev-recipe swap, the two later reconciled) are
   noted here as inherited, not mission-authored.
10. **No change recorded (H6)** — see "No-change items" below.
11. **No change recorded (`vault_lookup`)** — see "No-change items" below.

Merge decisions:

12. Adopted headless's throwing, launch-parameterized roster signature and
    rewired onboarding's additions through it (`MCPOnboardingTools` gained
    `launch: AppLaunchSeam = .production`); without the seam every
    onboarding app-down rig attempted a real app launch.
13. Kept BOTH isolation guards active on the merged rigs
    (`assertNotProductionPath` beside `AppConnectionIsolationGuard`) — the
    mission requires both to survive and headless's structural belt demands
    the IsolationGuard token.
14. `keys unwrap` documented and pinned as exit-6/no-auto-launch in the
    merged `docs/agents.md` and `AppLaunchSeamTests`' caller map (per
    decision 2).
15. Left headless's `HTTPServer.swift:145` `scheduleQuit` Sendable warning
    unfixed — headless's own code, not a merge artifact; changing the
    signature would touch the quit path. (Now at line 158 after the
    feedback merge's initializers; cited throughout as carried.)
16. Ran the second merge on the CURRENT branch `droid/merge-headless-branch-into`
    (the harness rename), not switching or renaming it — AGENTS.md forbids
    branch switches/renames and the first merge commit already sits on the
    branch.
17. The duplicate `revokeGatewayClients(project:at:)` in auto-merged
    `CatalogDB.swift`: removed feedback's byte-equivalent copy, kept
    onboarding's.
18. The two project-revoke overloads BOTH survive rather than collapsing to
    one — the union principle: onboarding's unwrap keeps its no-audit
    project revoke, feedback's `revoke_project`/`revoke_all` keep the
    audited walk; the build resolves both deterministically.
19. Gave `MCPFeedbackTools`, `MCPAnalyticsTools` and `MCPRevokeTools` a
    `launch:` seam and rewired every feedback rig through
    `.neverLaunching`; set `KEYS_TEST_NO_LAUNCH=1` in `RevokeToolsTests`'
    subprocess rig — the feedback-side mirror of decision 12, preventing
    real launches after the merge changed the connect default.

Registry-audit decisions:

20. `scan_run` is produced by the app-side vault comparison
    (`KeysService.vaultLookup`), the one app touchpoint of a scan —
    analytics lives in the app, the MCP process holds none; a scan with the
    app down records nothing (no app, no analytics).
21. `key_import` is recorded when the import stores at least one key;
    `onboarding_finished` when the flow reaches its end after the rewrite
    (they coincide on success and differ when a rewrite fails after the
    keys were stored). Recording `onboarding_finished` at the analytics
    question was rejected — it would only ever count opt-ins and duplicate
    the consent signal.
22. `grant_issue` is produced only when the caller is the MCP flow
    (`caller == "mcp"`) — the key-event audit's `grant_create` already
    counts every issuance, and double-counting is what the feedback report
    warned against.
23. The `analyticsLog` seam was already wired in `AppRuntime.run()` by the
    feedback merge, so the audit feature added a source-level pin test
    instead (the `run()` path needs a signed bundle and a window server
    and cannot be driven in a test).

Scrubber decisions (F1–F6):

24. (F2) The anywhere-path rule is two patterns — an explicit
    `(?i)file://[\w.\-/~]*` plus a boundary-captured general pattern whose
    colon alternative matches only a colon followed by `/` and a non-`/`,
    so `cwd:/Users/x` matches while `https://` and `http://` do not: the
    pinned http(s) survivors are why the boundary guard exists.
25. (F3) `scrub`/`replaceRegex` now `throws` (an uncompilable pattern
    aborts the whole scrub; the route answers 400 and opens nothing), with
    an `APIHandler(scrubFeedback:)` seam so the fail-closed route is
    testable. The fail-closed regression's pre-fix evidence is a compile
    error (the throwing API did not exist); the silent-skip it guards
    against is captured by the escaped-pattern test failing pre-fix.
26. (F4) Deviation from the grounding's literal "join whitespace inside
    long token-like runs": zero-width characters ARE stripped globally, but
    whitespace is NOT joined (it would fuse prose and destroy the name
    rule's word boundaries); instead the vault rule matches through
    inserted whitespace and enumerates percent-encoded/base64 forms, and
    the token rule matches a split token across the break. The F4 test's
    values are shaped so the key-shape rule cannot backstop them.
27. (F5) The cap is 2,000 characters on the encoded mailto URL, footer
    always kept, draft cut from its end on a whole-character boundary; the
    answer gains `"truncated": Bool` and its `"scrubbed"` field is the body
    actually opened, so the pinned `body == answer.scrubbed` invariant
    holds. The github destination is uncapped.
28. (F6) The email pattern and the key-shape `@` guard accept the fullwidth
    `＠`; the support-address exemption stays ASCII-only (a fullwidth
    spelling is not the address the mail goes to).

Grant decisions (G1–G2):

29. The poll secret is 16 random bytes (32 hex) — not the id's 8-hex shape:
    32 bits would be online-guessable at loopback speeds, and a 32-hex
    secret can never be confused with the public id. A missing/wrong secret
    answers the house not-found (same wording as an unknown id) so a
    foreign poller learns not even that an id exists; the tool layer
    refuses an id-only `grant_status` with a usage error naming the
    missing secret so a confused model can self-correct; the no-id listing
    takes a `secrets` array and never renders one.
30. The G1-reworked pinned tests keep their intents: the create-answer
    key-set pins became `["status","id","secret"]`, the listing section
    sends both asks' secrets, and white-box store reads go through
    `mcpPendingGrants.statuses()` directly (the service method gained the
    proof filter).
31. (G2) `approve` returns Bool and settles a lapsed-but-pending record to
    `.expired` itself; `runMCPApproval` revokes the just-minted grant with
    `try?` (notFound can only mean it is already gone; a failed revoke must
    never crash the approval thread). The regression test's Clock fake
    (`expireAfterReads`) lands issuance's live check and the approve flip
    on opposite sides of the expiry deterministically; verified stable over
    8 runs.
32. Recorded for validators: the contract's `--filter GrantMCPTests`
    matches nothing — the suite class is `MCPGrantTests`
    (`GrantMCPTests.swift` is only the file name).

Unwrap/uninstall decisions (O1/O4/O5/O8):

33. (O1) A companion naming a key ABSENT from the catalog is still accepted
    (so the line's "gone" failure names it) — `keys rm` cascades the
    membership deletion, so the strict rule broke the pinned dead-vault-key
    report; nothing can be written for an absent key, so the
    edited-companion write path stays closed: a stranger key that EXISTS is
    still rejected (that is the O1 regression's shape).
34. (O4) The deleted-recorded-file match resolves the parent directory and
    appends the name (realpath cannot resolve a deleted final component) —
    without it the `/var` vs `/private/var` spelling difference would make a
    temp-dir record never match its own file. The offer unwraps per
    project; a dangling project id refuses rather than skipping.
35. (O5) The kept-token report field is `still_used_by` (a flat list of
    file paths, always present; a flat list because naming the token itself
    is forbidden); `revoked` keeps meaning "tokens actually revoked".
36. (O8) The companions record is a JSON array in a `companions` column
    (the `grant_profiles` `paths_json` precedent), DERIVED by the writer
    from the plan items (the same derivation `WrapRunner` makes) rather
    than extending the wire protocol; NULL/unparseable reads as "no record"
    — the documented legacy fallback. The white-box writer/migration
    assertions' pre-fix evidence is a compile error; the hand-written-
    companion regression is the demonstrated pre-fix failure.
37. The blanket-removal pins were reworked into the two halves (writer
    half + hand-written-kept half) with a raw-SQL legacy-fallback pin and a
    guarded-migration test; `docs/agents.md`'s unwrap section was updated
    to the new rules (it is the product's own description of this surface).

Wrap/import/scan decisions (O2/O3/O6/O7/O9):

38. (O6) The folder restriction is enforced at the TOOL layer for all three
    tools (the app process has no session-cwd seam); a hand-rolled
    `POST /api/mcp/import_and_wrap` with an outside folder still reaches
    the app's own scan (origin-token + one Touch ID gated) — the
    conservative reading. The `/` and `~` refusal rows were deliberately
    NOT run pre-fix (they would walk the real disk/home); the safe
    outside-temp-dir variant drives the identical code path and is the
    captured pre-fix failure.
39. (O2) The backup folder is keyed by the SHA-256 of the canonical parent
    directory — the one key `keys wrap`, the app-side import and the
    unwrap reader all compute identically. The payload statement is the
    always-present boolean `backup_kept_outside_project`; the exact-shape
    pins were reworked from five to six keys with intent preserved;
    `keys wrap`'s stdout says the backup exists without saying where.
    `WrapRunner.Options` gained an injectable `backupRoot` because until
    the tripwire landed, the default would resolve the real Application
    Support under XCTest. The new-location white-box tests' pre-fix
    evidence is a compile error; the inverted backup-beside-the-file pins
    are the demonstrated pre-fix failures.
40. (O7) The injected rewrite failure is a deterministic blocker (a regular
    file squatting on the backups tree's root) rather than a racing edit;
    every error text on that path is `lastPathComponent`-based and the
    rethrown error is the original one.
41. (O9) The pre-write recheck reuses the parked test's resolve+containment
    primitive; a mint-race variant was rejected as non-deterministic in
    which check fires.

Isolation decisions (G3+H1):

42. `ControlFile.url()` became a separate throwing no-argument overload
    while `url(beside:)` keeps its pure-math signature — the grounding's
    restructure would have pushed `try` into ~50 catalog-sibling call sites
    for zero behavior change.
43. The "under XCTest" signal is NOT only `XCTestConfigurationFilePath` —
    this toolchain's `swift test` runs every case in-process with the
    variable UNSET (verified empirically), so `TestIsolation.armed` also
    arms on the linked XCTest framework (`NSClassFromString("XCTestCase")`,
    false in every production process). Without this the tripwire would
    have been inert under the mission's own test command.
44. The tool groups' `control` seam is `URL? = nil` deferred to
    `AppConnection.connect()` at call time, so registry construction stays
    non-throwing and offline-safe; the fail-closed moment is the first
    state-bound tool call, and `MCPSession.run`'s default roster builds
    through the guarded `MCPRoster.registry` so a scripted session never
    resolves production paths even as values.
45. `KeychainStore` refuses whenever the tripwire is armed, with no
    `KEYS_CATALOG` escape — the Keychain is not catalog-derived and no test
    constructs the real store.
46. The remaining direct `Paths.catalogDB` state openers route through
    `Paths.resolvingCatalog()`; the app-process-only `Paths.appSupport`
    constants stay (no test process reaches them, and both test guards
    compare against the constant).
47. Pre-fix TDD capture substitutions: the rows that would, pre-fix, read
    the real control.json/catalog (the owner's app is LIVE on this machine)
    were deliberately not run pre-fix; the captured failures are the SAFE
    rows on the identical resolution path, and the hazardous rows are in
    the suite, verified post-fix. The `KEYS_TEST_ISOLATION` leg is covered
    by `TestIsolation.armed(environment:)` unit rows, not a subprocess
    probe (mutating `ProcessInfo` mid-process is unreliable, and a probe is
    not safe by construction).
48. The structural belt's file list was extended to exactly the ten named
    onboarding/feedback files; older pre-mission control-rig suites stay
    out of the belt per the spec's scope — noted here, not fixed.
49. The two guard tests that construct production paths as values were
    adjusted per the grounding (shape-beside-the-constant), intent
    preserved.

Update/launch decisions (H2–H4):

50. (H2) The pre-quit re-check is a single busy reading, not a re-run of
    the bounded wait — the owner's words are "re-check idleness";
    a false busy merely defers, a missed busy is the hazard. The deferral
    logs the existing deferred line verbatim through one shared helper.
51. (H2) The pre-swap gate is verified by a source pin (the real
    `UpdateInstaller.run()` cannot run offline) — the repo's established
    belt pattern; the gate throws `BackgroundInstallBusy`, recognized for
    the deferred line.
52. (H2) The gate sits AFTER the notification (run→notify→re-check→quit),
    so a deferred relaunch still delivers the update-installed
    notification; the pending-relaunch helper takes over at the next quit.
53. (H3) The refusal lives in `AppConnection.openInstalledApp` through a
    `resolve(bundleID:) -> URL?` requirement; a NIL resolution is NOT
    refused (the not-registered case and the pinned bundle-first trace keep
    their shape); comparison is plain URL equality.
54. (H4) Busy gains relay-on AND a stamp within `recentUseInterval`
    (5 minutes) — the literal lastBusy-only reading would hold the install
    only the 5-second quiet interval and would not satisfy "waits while a
    token was in active use in the last few minutes". Per-source consults:
    active grants only, unrevoked client tokens only, and
    `RelayHost.lastRelayedCall` (stamped on open or close, never reset by
    stop).

Headless-surface decisions (H5/H7/H8):

55. (H5) The stored-off-survives case is the flipped assertion inside the
    existing migration test (the feature named that pinned assertion the
    failing-first test to flip); the absent-defaults-on case stays pinned.
56. (H7) The provider-prefix arm carries wrap's 16-character key-shape
    floor — without it the flow refused its own short provider-derived
    suggestions. The entropy bound is length ≥ 32 plus (hex-only OR ≥ 40%
    digits); lowercase non-hex random blobs are an accepted residual (no
    realistic guided-flow paste target has that shape). Whitespace is
    trimmed for detection only. Scope stays the guided name prompt; the
    explicit `keys add <name>` path and the dialog route keep
    `KeyName.validate` alone, and KeyName's usage error echoing an invalid
    name back is a pre-existing surface on every add path, recorded as a
    carried issue rather than widened here.
57. (H8) The branch source is `AppResources.applicationBundle` (the single
    existing "are we the bundled app" helper); every serve-path side
    effect sits behind injectable seams because the real path binds ports
    and parks the main run loop; the headless `DashboardCommandTests`
    source belt was adjusted, not bypassed, and the belt itself was the
    captured pre-fix failure (the same compile-red seam-introduction
    precedent as O2/H2). The real binary was verified by hand against a
    temp catalog; the live app's ports were never touched. `fixture_now.py`'s
    docstring was reconciled; the README was NOT touched by H8 itself (the
    stale text was recorded as a discovered issue for the later
    reconciliation feature — entry 9 above).

Release-artifact decisions:

58. (version-and-changelog) The entry describes the POST-FIX merged
    surface — the review fixes are folded into the feature bullets as the
    final behavior, never named as "fixes", because they shipped inside
    0.14 and never existed as separate releases. The fresh
    notification-permission ask is mentioned; excluded are the checkout
    dev-copy branch (a developer recipe), the isolation work (internal
    safety), internal fix codes, and the onboarding report's deferred
    `keys purge` unwrap offer. The two historical 0.13.0 mentions (the
    CHANGELOG's own `## 0.13.0` heading and the headless report's version
    line) were left untouched.
59. (homebrew-cask) The cask URL is the versioned download form
    `releases/download/v#{version}/Keysrs-arm64.dmg` — the same pattern
    AppUpdater's fixtures pin, with the frozen asset name; the versionless
    `releases/latest/download/…` form cannot carry a per-version checksum,
    which a cask requires.
60. (homebrew-cask) The `binary` stanza IS included — a symlinked launch is
    the app's own documented CLI path (`AppResources.applicationBundle`
    resolves through symlinks; `AppRuntime` re-execs the real bundle; the
    app's repair logic never repoints a foreign link), and the canonical
    precedent is the sublime-text cask's identical form.
61. (homebrew-cask) `--fill-cask <DMG>` is a second entry point to the same
    step because the published release ships the styled, signed DMG built by
    `build-dmg.sh`, whose bytes differ from the plain artifact; the
    maintainer can fill the cask from the FINAL artifact at release time.
62. (homebrew-cask) The zap stanza is trash-only over the whole
    `~/Library/Application Support/Keysreallysafe/` root (every named part
    is a child of it, named in a comment so the stanza greps as complete);
    the status-item autosave key is expressed as its domain's plist file;
    `.Keysrs.app.incoming` joins `.Keysrs.app.previous` beside the app; the
    updater's per-user temp dirs stay out. `auto_updates true` is declared
    because the in-app updater is the canonical path.
63. (homebrew-cask) The committed cask carries `version "0.14.0"` and the
    `sha256 :no` placeholder (valid cask DSL and valid Ruby as committed);
    the step rewrites BOTH lines at release time and is strict on shape.
64. (manual-e2e-checklist) The scratch project holds two env files with the
    same runtime-built fake value — one vault key, two wrapped files — so
    the fixed step order (revoke_all → unwrap → uninstall offer) leaves step
    9 a wrapped-file record to offer on, and step 8 demonstrates the
    kept-token report. The grant is spent against the real provider host
    with the FAKE vault key and the documented expected observation is the
    provider's own 401 through the gateway — the checklist forbids real
    keys, and a provider 401 coming back is the proof the grant authorized
    the call. The Docker and analytics questions are answered No in the run
    (the conservative local-only choices, with what a Yes changes stated).
    The build step follows `docs/release.md` and points at `make app` for
    the locally signed variant when the new bundle replaces a working
    install. Two negative checks are optional extras (the denial path;
    unwrap's no-launch exit 6).
65. (this closeout) The lapsed-ask revoke's unused-result warning was fixed
    by discarding the result explicitly rather than dropping the call —
    the revoke is side-effectful by design (decision 31); dropping it would
    reintroduce the stranded grant G2 exists to prevent.

## No-change items

- **H6 — `POST /api/app/quit` accepted as same-user DoS only.** The
  headless mission's quit endpoint needs only the app's control token; the
  owner's review accepted that as a same-user DoS (any process already
  holding the loopback control token — the same-user boundary — can ask
  the app to quit). No change was made.
- **`vault_lookup`'s constant-time digest comparison is intentional.** Only
  the SHA-256 hex digest of a scanned value crosses the loopback wire; the
  app computes the same digest over each vault secret, compares the
  digests in constant time, and answers with the matching key *name* only.
  Nothing stores or returns hashes, and no secret ever crosses the wire in
  either direction — the comparison is deliberately digest-side and
  constant-time, and this mission left it exactly as designed.

## The invariants audit

- **Site/, README headline, Show HN (VAL-REL-005).** The integration
  commits (everything after the two merge commits, `a76522d..HEAD`) change
  nothing under `Site/` (empty diff — and `Site/` is unchanged over the
  whole mission too, `02dd7d8..HEAD`). The README headline block (lines
  1–11) is byte-identical across the merge base, both merge commits and
  HEAD: SHA-256
  `7d3658dd8d0652b0ea3be101d0e8958df7e69a16b4e946b6f4cb168d0ebf1ad2` at
  every revision. The integration commits' README diff is exactly three
  hunks, all deep in the body (the `keys dashboard` paragraph and the two
  dev recipes — the reconciliation feature, decision 9's region).
  No Show HN copy exists or was added: the only "Show HN" mentions in the
  tree are the two pre-existing lines in `docs/proposals/grants-first.md`
  saying the launch copy stays deferred, byte-identical to the merge base.
- **Frozen identifiers intact.** `Package.swift` is byte-identical to the
  merge base (executable `keys`, targets `KeysCore`/`KeysreallysafeTests`).
  Verified at HEAD at their canonical sites: the signing identifier and
  designated requirement (`StableSigning.swift` — `identifier
  "keysreallysafe" and certificate leaf[subject.OU] = …`), Keychain
  service `keysreallysafe` (`SecretStore.swift:94`), the relay service
  `keysreallysafe.relay` (`KeysService.swift:1514`), the purge-only
  `keysreallysafe.optimizer` (`SecretStore.swift:150`), the launchd label
  `com.keysreallysafe.menubar` (`LoginItem.swift:5`),
  `~/Library/Application Support/Keysreallysafe/` (`Support.swift`), the
  status item autosave `Keysreallysafe.usage` (`MenubarPosition.swift:20`),
  the repo `gshost1/Keysreallysafe` (`AppRuntime.swift:285` update check,
  `FeedbackDelivery.swift:17` issues page) and the DMG name
  `Keysrs-arm64.dmg` (`AppUpdater.swift:24`). Grep counts across the tree
  are equal or grown versus the merge base (growth is new files naming the
  frozen strings — the cask, the checklist, the mission docs); none
  shrank.
- **No key values or secret-shaped literals committed (VAL-CROSS-001).**
  Greps over the committed tree for `sk-ant-api`, `sk-proj-`, real-shaped
  `AKIA…`/`AIza…`/`xai-…` literals, and 30+ character `sk-…` runs find
  nothing real: the committed literals are the obvious-fake markers
  (`sk-contract-typesafe-NEVER-REAL-04`,
  `sk-fixture-ROTATED-NEVER-REAL-1111111111`,
  `sk-add-safety-NEVER-REAL-0000000000`, the `ksfc_0123456789abcdef…`
  counting-hex shapes, asterisk masks). The runtime-built fake convention
  holds (31 `FAKE0TEST0VALUE…`/`fake-vault-…`/concatenation sites, 22
  `NEVER-REAL` markers); the fixtures hold no key-shaped values at all;
  the manual checklist builds its fakes at runtime via `printf` from split
  literals; the mission reports carry token *shapes* (`ksfc_…`) never
  values. A scan of every file the mission touched for secret-shaped
  patterns came back empty.
- **No new outbound endpoint.** The integration commits add loopback
  literals only (`http://127.0.0.1:`). Over the whole mission, the
  non-loopback URL additions in code are: `FeedbackDelivery.issuesURL`
  (`https://github.com/gshost1/Keysreallysafe/issues/new`) — the feedback
  mission's `send_feedback` "github" destination, the project's own issues
  page opened in the *user's* browser for them to review and send
  (github.com was already an allowlisted host for the update path); the
  cask and its docs URL (`…/releases/download/v#{version}/Keysrs-arm64.dmg`)
  — the same frozen GitHub release the updater already reads; and in docs
  only, a Docker Desktop documentation reference link and the
  `host.docker.internal:12767` base-URL form (Docker Desktop's TCP-level
  forward to the Mac's own loopback — not an endpoint). No telemetry,
  analytics or phone-home endpoint was added; product analytics is
  unchanged (opt-in, aggregate, `analytics.keysrs.com`).
- **No grant widened, no presence skipped, tests offline.** The exact-set
  registry test pins the 16 tools with the forbidden kinds absent
  (`MCPRegistryTests` 6/6); the planted-secret sweep over every tool is
  green (`MCPOutputGuardSweepTests` 2/2); every presence-gated flow keeps
  its gate (the F/G/O/H regression suites all green, 1,070 cases). All 8
  suites ran offline in this session as recorded above.

## Carried pre-existing issues (deliberately not fixed)

- The two pre-existing build warnings: unused `try?`
  (`Sources/KeysCore/AppUpdater.swift:415`) and unused `withLock` result
  (`Sources/KeysCore/CatalogDB.swift:544`).
- The headless-inherited `HTTPServer.swift:158` Sendable warning for the
  `scheduleQuit` closure (headless's own code, present on its branch at
  line 145; not merge-caused).
- The headless-inherited dead no-arg `makeVault()` in
  `Tests/KeysreallysafeTests/ReadToolsTests.swift`.
- The dead CRLF check in `AgentSetup.swift` (`CodexSetup.upsert`/
  `GrokSetup.upsert`): a grapheme-level `text.contains("\r")` is false for
  a real CRLF file, so a CRLF config silently takes the append path
  (recorded by the mcp-core mission).
- The `keys tunnel --print` vs `--print-only` help-text mismatch (deferred
  by the headless mission).
- KeyName's usage error echoing an invalid name back to the caller (seen
  live in the H7 pre-fix capture) — a pre-existing surface on every add
  path, recorded by the headless-surface feature rather than widened.
- npm audit findings: Relay (2 moderate, 3 high) and scripts/tests (3
  high); npm 11 skips postinstall scripts (esbuild/fsevents/workerd) —
  verified harmless, workerd runs (43/43).
- The orphan fixture server on port 12799 (another worktree's, pre-existing)
  — flagged, left alone.
- The 5 expected env-gated skips (above), the python-suite baseline noise
  (ResourceWarning + export.jsonl lines, above) and the workerd teardown
  line (above).

## Git evidence

- **Branch:** `droid/merge-headless-branch-into` (the harness renamed
  `droid/014-integration` to it at 16:45:43 on 2026-10-28; reflog
  preserved; nobody renamed or switched branches — AGENTS.md forbids it).
- **Merge commits (the two the mission required):**
  - `2338f00` Merge the 014 headless mission into the integration branch
    (parents `699fdb5` + `07e152f`)
  - `a76522d` Merge the 014 feedback mission into the integration branch
    (parents `2338f00` + `1b1bd8e`)
- **Integration commits after the merges (oldest first):**
  `a7040da`, `0045cab`, `ee83d15`, `18b6ef0`, `bff93e5`, `bb59128`,
  `6d23f42`, `866f472`, `2b6ad4c`, `cf6ccbf`, `8e001f6`, `f134a60`,
  `f6ccfaf`, `dfbaa19`, `e50fcdb`, `44aca9c`, `c8f0c8d`, `daeffa8`,
  `f3b3ba0`, `5b5e541`, `6c21892`, `b47e371`, `bb44db6`, `a93f5e1`,
  `26ba4f9`, `0af8482`, `bc3b93a`, `bfe0eec`, `459a049`, `3f284c7`,
  `b45936e`, `93af2d8`, `6e7524d`, `38f6413` (the warning cleanup), then
  this report's commit.
- **Sibling worktrees untouched:** the headless worktree's checked-out
  branch is `droid/execute-headless-lifecycle` at `07e152f` and the
  feedback worktree's is `droid/014-feedback` at `1b1bd8e` — both the exact
  tips that were merged, unchanged after the merges (read-only checks).
- Nothing was pushed, rebased, force-updated, tagged, released or deployed.
  No tag points at any mission commit. `/Applications/Keysrs.app` and
  ports 12766/12767 were never touched; every test run used the synthetic
  fixture environment, temp homes and loopback-only servers.
- Scope over the whole mission (`git diff --stat 02dd7d8..HEAD`): 112
  files, +22,657/−643, plus this report. Site/ and the README headline
  excluded by the audit above.

## Coverage highlights

All inside the green 1,070-case run, for the merged and fixed surface:
`MCPRegistryTests` 6/6 (the exact 16-tool set, forbidden kinds absent, the
G3 guard), `MCPOutputGuardSweepTests` 2/2 (the planted runtime-built secret
never appears in any of the 16 tools' outputs),
`MCPServerInstructionsTests` 2/2 (the frozen instructions string
byte-for-byte through both merges), `MCPClientFlowTests` 2/2 (the done
criterion over real pipes), `MCPGrantTests` 26/26 (the poll secret, the
expiry re-check), `FeedbackScrubberTests` 15/15 and `FeedbackToolsTests`
10/10 (F1–F6), `AnalyticsToolsTests` 7/7 (the counter producers, the
opt-in, the `analyticsLog` pin), `RevokeToolsTests` 9/9,
`ActivityToolsTests` 12/12, `EnvScanTests` 19/19, `ScanProjectToolTests`
12/12, `CheckExposureToolTests` 12/12 (the O6 refusals),
`ImportAndWrapTests` 28/28 (O2/O3/O7/O9), `TestKeysToolTests` 14/14,
`EnvWrapTests` 17/17, `UnwrapTests` 22/22 (O1/O5/O8),
`UninstallOfferTests` 13/13 (O4), `AppUpdaterTests` 34/34 (H2/H4, including
the BackgroundUpdateTests extension), `AppLaunchSeamTests` 11/11 (H3),
`AppConnectionIsolationGuardTests` 7/7 and the production-side tripwire
guard tests (G3+H1), `PreferencesTests` 13/13 (H5), `GuidedAddTests` 18/18
(H7), `DashboardCommandTests` 6/6 and `DroidIngestTests` 14/14 (H8),
`ProductAnalyticsTests` 22/22 (the golden fixture and the vocabulary),
`MCPAppConnectionTests` 12/12 (every app-bound tool through the guarded,
never-launching roster), and `VersionCommandTests` 5/5 (0.14.0
everywhere). The full XCTest count went from 1,008 after the feedback
merge to 1,070 at this closeout; the python discovery went from 72 to 76
(the cask feature's new step tests) and the collector stayed at 20, all
green.
