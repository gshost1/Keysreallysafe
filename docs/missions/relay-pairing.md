# Mission report: paired remote requests for the Keysrs relay

Date: 2026-10-27. Branch: `droid/relay-pairing` in the `droid-relay` worktree.
Everything below was run this session on the branch HEAD with a clean working
tree (`git status --short --branch` printed only `## droid/relay-pairing`).

## What was built

Pairing for the relay, exactly as proposed in `docs/proposals/relay-pairing.md`
(committed first, before any code). A user mints a `ksfp_…` pairing credential
with `keys relay pair issue` (one Touch ID, credential printed once, only its
SHA-256 hash stored in a new `relay_pairings` catalog table alongside a
`relay_pairing_required` meta flag, default off). When enforcement is on, the
Mac's `RelayClient` verifies the `x-ksf-pair` header at REQUEST time, before
the body is buffered: missing/malformed/unknown credentials get
`pairing_required`, expired ones `pairing_expired` (exclusive at the boundary),
revoked ones `pairing_revoked`, and a pairing whose key list does not cover
the target key gets `pairing_out_of_scope`; the credential header is stripped
before replay so it never reaches the gateway, the provider, or any log. The
gateway's grant/client-token checks run unchanged on every replayed request —
pairing never substitutes. The Worker stays a dumb pipe: it passes
`x-ksf-pair` through untouched and maps exactly the four pairing ERROR codes
to HTTP 403 (every other Mac code stays 502, so an older Worker degrades
fail-closed). Protocol stays v1. The CLI gains `keys relay pair
issue/list/revoke/require` plus pairing mode and count in `keys relay status`,
all through the app's `/api/relay/pairings` routes behind the existing
mutating-API token gate; `keys purge` clears the table and the flag.
`docs/relay.md` and the README's relay bullet were updated in sync.

## Commands run

All run in this session; exit codes are the real ones. Fixture environment for
the swift run: `CLAUDE_CONFIG_DIR=Fixtures/claude-home
GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home
KEYS_DROID_HOME=Fixtures/droid-home`.

| Command | Exit | Result |
|---|---|---|
| `git status --short --branch` (before the gate) | 0 | clean; only `## droid/relay-pairing` |
| `env CLAUDE_CONFIG_DIR=… KEYS_DROID_HOME=… swift test` | 0 | 554 tests executed, 0 failures, 5 skipped (all pre-existing opt-in skips, listed below), 47.8s |
| `cd Relay && npm ci` | 0 | dependencies installed, no lockfile change |
| `cd Relay && npm test` | 0 | 43/43 tests passed (1 file, workerd, offline); zero `Uncaught (in promise)` lines (grep count 0); no `.skip`/`.only` in `Relay/test/relay.test.js` |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | 62 tests, OK |
| `python3 -m unittest Analytics/test_collector.py` | 0 | 19 tests, OK |
| `git log --oneline --diff-filter=A main..HEAD -- docs/proposals/relay-pairing.md` | 0 | `cbbedd3 Propose paired remote requests for the relay` |
| `git log --oneline main..HEAD -- Sources/ Relay/src/` | 0 | first (oldest) code commit on the branch: `fd15407 Verify relay pairings on the Mac before buffering a request` |
| `git merge-base --is-ancestor cbbedd3 fd15407` | 0 | proposal commit is an ancestor of the first code commit; the reversed check exits non-zero, so it is strictly older |
| `git diff --stat main...HEAD` | 0 | only mission-scope paths (see Scope diff below) |
| `git diff --stat main...HEAD -- .github/ scripts/prepare-release.py Site/ Web/ Analytics/` | 0 | empty — nothing outside scope touched |
| `grep -c 'Uncaught (in promise)' /tmp/mission-relay.log` | 1 (grep: no matches) | 0 occurrences |
| `grep -nE '\.skip\|\.only' Relay/test/relay.test.js` | 1 (grep: no matches) | no skipped or focused tests |

Nothing failed, so there are no failure transcripts to paste. The only
non-empty diagnostic in any log is workerd's pre-existing
`identity-transform-stream … disconnected: reader canceled` line during test
teardown (a known, deliberate teardown artifact; the suite's
"Uncaught (in promise)" gate is what matters and it stayed clean).

## Git evidence

Branch order, oldest last (`git log --oneline main..HEAD`):

```
35fe590 Map the Mac's pairing refusals to 403 and sync the relay docs
e26952d Manage relay pairings from the CLI and the app API
fd15407 Verify relay pairings on the Mac before buffering a request
cbbedd3 Propose paired remote requests for the relay
```

The proposal (`cbbedd3`, adds only `docs/proposals/relay-pairing.md`) is
strictly older than the first commit touching `Sources/` or `Relay/src/`
(`fd15407`); `git merge-base --is-ancestor cbbedd3 fd15407` exits 0.

Scope diff (`git diff --stat main...HEAD`):

```
 README.md                                         |   3 +-
 Relay/src/worker.js                               |  12 +-
 Relay/test/relay.test.js                          |  59 +++-
 Sources/KeysCore/CLI.swift                        | 138 ++++++--
 Sources/KeysCore/CatalogDB.swift                  |  82 +++++
 Sources/KeysCore/HTTPServer.swift                 |  64 ++++
 Sources/KeysCore/KeysService.swift                | 140 ++++++--
 Sources/KeysCore/Relay.swift                      |  43 +++
 Sources/KeysCore/RelayHost.swift                  |   8 +-
 Sources/KeysCore/RelayPairing.swift               |  80 +++++
 Tests/KeysreallysafeTests/RelayHostTests.swift    | 160 ++++++++++
 Tests/KeysreallysafeTests/RelayPairingTests.swift | 828 ++++++++++++++++++++++
 docs/proposals/relay-pairing.md                   | 191 ++++++++
 docs/relay.md                                     |  99 +++--
 14 files changed, 1889 insertions(+), 18 deletions(-)
```

(This report itself adds `docs/missions/relay-pairing.md`, the fifteenth
in-scope path.) Nothing under `.github/`, `Site/`, `Web/`, `Analytics/` or
`scripts/prepare-release.py` changed.

## Skipped

- **Playwright dashboard UI suites** (`scripts/tests/test_keys_dashboard_ui.cjs`
  and the opt-in `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs`,
  which needs `KEYS_BACKEND_CONTRACT_UI=1` and the pinned Playwright Chromium):
  the dashboard UI is untouched by this mission, so these were not run.
- **RelayEndToEndTests** (3 tests, shown as skipped inside `swift test`):
  opt-in via `KEYS_RELAY_E2E_URL`/`KEYS_RELAY_E2E_SECRET` and require
  `wrangler dev` running; deploy tooling is forbidden by the mission
  boundaries. Coverage of the same behavior is provided offline by RelayTests
  and the workerd suite.
- **`StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation`**:
  requires the Apple signing identity (run before deploying signing changes);
  no signing changes in this mission, so not run.
- **Live mutating CLI verbs** (`keys relay pair issue/revoke/require` against
  the real app): the real Keychain and the installed `/Applications/Keysrs.app`
  are off-limits. The same code paths are validated offline instead:
  `RelayPairingTests` and `RelayHostTests` drive the real API handlers and
  enforcement in-process with `MemorySecretStore`/`RecordingPresenceGate`, and
  `testPairCLIParsingRefusesBadInputBeforeAnyAppContact` covers CLI argument
  parsing without any app contact.

## Lifecycle coverage: issue → require on → paired request succeeds → revoke → 403 pairing_revoked

| Step | Tests (exact names) |
|---|---|
| Issue | `RelayPairingTests.testIssueMintsUnderOnePromptAndStoresOnlyTheHash`, `RelayPairingTests.testIssueRouteMintsOnceAndStoresOnlyTheHash`, `RelayHostTests.testPairingMintRefusalsHappenBeforeTouchID` |
| Require on | `RelayPairingTests.testRequireFlagDefaultsOffAndPersistsAcrossReopen`, `RelayHostTests.testTheAppRelayEnforcesPairingWhenRequired` |
| Paired request succeeds | `RelayPairingTests.testPairedRelayedCallRoundTripsThroughTheGateway`, `RelayPairingTests.testAcceptedPairingUpdatesLastUsedAtRefusalsDoNot` |
| Revoke | `RelayPairingTests.testRevokeByLabelOrHintRefusesAmbiguity` |
| 403 pairing_revoked | `RelayPairingTests.testRevokedPairingStaysRevokedAcrossReconnect` (Mac emits ERROR `pairing_revoked`); Worker: `answers 403 pairing_revoked when the Mac refuses the pairing, without retry guidance` (in `Relay/test/relay.test.js`, "the Mac's pairing refusals" describe block) |

Supporting refusal/edge coverage: `testPairingRequiredRefusalNeverReachesTheGateway`,
`testUnknownPairingCredentialIsRefusedIdenticallyToMissing`,
`testMalformedPairingCredentialsAreRefusedAsPairingRequired`,
`testExpiredPairingIsRefusedAtTheBoundary`,
`testPairingScopeIsCheckedAgainstTheTargetKey`,
`testPairedRequestWithoutATokenGetsTheGatewaysOwn401`,
`testGrantScopeStillAppliesToPairedRequests`,
`testPairingVerificationNeverPrompts`,
`testPairingRefusalPrecedesBodyBuffering`,
`testPairingOffKeepsTodaysBehavior`,
`testIssuePersistsKeyScopesAndExpiryWithThirtyDayDefault`,
`testIssueRefusesADuplicateLiveLabelBeforePrompting`,
`testIssueRoutePersistsKeyScopesAndExpiryAndListShowsMetadataOnly`,
`testStatusReportsPairingModeAndActiveCount`,
`testPurgeClearsRelayPairingsAndTheFlag`,
`testPairingCredentialShapeMirrorsClientTokens`,
plus `RelayHostTests.testPairingRoutesTakeTheMutatingToken`,
`testPairingListAndRevokeRoutesShowHintsNeverHashes`,
`testRelayStateReportsThePairingModeAndCount`. Worker side additionally:
`answers 403 pairing_required/pairing_expired/pairing_out_of_scope …`,
`keeps answering 502 for the Mac's other error codes`,
`passes x-ksf-pair through to the REQUEST frame untouched`,
`reveals no pairing state at / either`.

## Conservative choices (made without user input)

- **Protocol stays v1.** Pairing adds no frame types and no handshake change;
  the four ERROR codes are additive, and an older Worker degrades them to 502
  (fail-closed), so no forced redeploy.
- **Enforcement is opt-in, default off.** `relay_pairing_required` absent means
  byte-for-byte the pre-feature behavior; existing deployments are untouched
  (pinned by `testPairingOffKeepsTodaysBehavior` and the unmodified
  pre-existing suites).
- **Pairing scope is limited to key names.** Method/path/host scoping stays
  the grant's job; a pairing only narrows which keys a relayed request may
  target (empty list = all keys).
- **`--days` defaults to 30 and expiry is always set.** Every pairing gets an
  `expires_at`; there is no "never expires" option.
- **Expiry is exclusive at the boundary.** A request at exactly `expires_at`
  is refused (pinned with the injected clock).
- **Revoked labels may be re-issued as new rows.** Revocation sets
  `revoked_at` and keeps the row (audit trail); a live duplicate label is
  refused rather than silently overwritten.
- **Distinct rejection codes kept as a documented trade-off.**
  `pairing_expired`/`pairing_revoked`/`pairing_out_of_scope` reveal credential
  state to someone who can already reach the Worker; `docs/relay.md` documents
  this deliberately (a stolen credential is still useless without a valid
  grant).
- **No dashboard or menubar UI.** Pairing is managed from the CLI and the
  loopback app API only.
- **No analytics vocabulary changes.** Pairing adds no counters; the aggregate
  schema is untouched.
