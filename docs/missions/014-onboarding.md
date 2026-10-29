# Onboarding over MCP — closeout report (mission 014)

**Branch note.** The mission runner assigned this worktree the branch
`droid/build-envscan.swift-module` instead of the brief's `droid/014-onboarding`.
Exactly as the mcp-core mission handled it, the assignment was accepted for the
run (library decision 16): every worker committed on the current branch and
nobody renamed, switched or created branches mid-run. The orchestrator restores
the required name `droid/014-onboarding` at completion — a rename that touches
none of the commits or their order. Nothing was pushed.

The mission builds on the mcp-core base `02dd7d8` and adds the four onboarding
tools (`scan_project`, `check_exposure`, `import_and_wrap`, `test_keys`), the
project client token, Docker Desktop gateway access, `keys unwrap`, the
uninstall unwrap offer and client-token expiry surfacing. Scope: 34 files,
+7,610/−74 plus this report, all inside `Sources/KeysCore`,
`Tests/KeysreallysafeTests`, `docs/` and `README.md`. The frozen MCP
instructions string (`Sources/KeysCore/MCPServer.swift:24-32`) and
`Skills/keysrs/SKILL.md` are untouched (verified by diff and by
`MCPServerInstructionsTests` 2/2). No file outside the mission's scope moved:
the five real agent config files, `/Applications/Keysrs.app`,
`~/.local/bin/keys`, the real Keychain, `~/Library/Application
Support/Keysreallysafe`, `Web/`, `Site/` and the `Relay/` deploy are all
untouched.

## What shipped

| Feature | Commit | What it landed |
|---|---|---|
| env-scan core | `2b8bb57` | The shared `EnvScan` folder walk and classification pass: depth 3, 1 MiB file cap, the 12-directory skip list, the auth-name guard (auth.json, credentials); names and relative paths only, values classified but never returned. |
| scan_project | `6fad652` | `scan_project` over MCP: env files, variable names, Dockerfile/docker-compose detection, last-4 fingerprints, and an in-vault comparison done app-side by SHA-256 hash over the control channel (honest `unavailable` when the app is down). |
| check_exposure | `9c82447` | `check_exposure` over MCP: bounded read-only git facts (tracked, in_history, remote presence) with a rotate recommendation; git contents never read. |
| project client tokens | `a15aaeb` | The `gateway_client_keys` membership table: one `ksfc_` project token serves exactly its member vault keys, with authorize, revoke and per-key authorization checks. |
| docker gateway access | `2158fba` | Exact-match `host.docker.internal:<boundPort>` Host acceptance at the gateway call site only, gated per request on the new `pref_docker_access` catalog preference; `HTTPFrame.swift`/`Support.swift` untouched; the Docker docs section with all caveats. |
| import_and_wrap | `64d6b13` | `import_and_wrap` over MCP: one Touch ID prompt for N keys, hash-based dedupe against the vault, the reserved `imported` provider id for AWS pairs and credential URLs, 0600 backups, per-key gateway base URLs (`host.docker.internal` when `docker:true`, also setting the pref), and the wrapped-file record written at apply time. |
| test_keys | `b755d20` | `test_keys` over MCP: read-only live provider checks app-mediated through `checkProvider` internals with a forced per-call presence confirm; the frozen instructions string unchanged, the ask-each-time rule pinned in the tool description. |
| keys unwrap | `811e1a1` | `keys unwrap [<env file>]`: restores values from the vault byte-for-byte, restores/removes the BASE_URL companions via the wrap backup, revokes the file's (or the cwd project's) client tokens, exit 6 with the app-required sentence when the app is not running. |
| uninstall offer | `daba5d3` | `keys autostart --remove` — the only uninstall code path — now offers to unwrap every recorded wrapped file before tearing down, so uninstall never strands a project pointing at a dead gateway. |
| expiry surfacing | `93c2415` | Client-token expiry surfaced in `gateway_info` and a poll route, so a client can see a project token's expiry without holding a value. |
| docs and report | this commit | The docs (below), the done-criterion end-to-end pipe test, and this report. |

The docs work (VAL-DOC-001/002): `docs/agents.md` (the file git tracks;
`docs/AGENTS.md` is a hardlink to the same inode, so editing one edits both)
gained all four tools in the MCP tool list with inputs, results, the confirm
gate and the docker flag, plus a "Unwrapping an env file" section beside the
wrap documentation carrying the app-required/exit-6 discipline; the exit-6
paragraph now lists both `keys wrap` and `keys unwrap`. The README documents
`keys unwrap` beside `keys wrap` in both the tour and the command reference.
The Docker section (mechanism, exact-match acceptance, Docker-Desktop-only
caveat) was landed by the docker feature and left as is.

## Test results — the full CI list, serialized

The entire CI list from `.github/workflows/test.yml` was run in one serialized
pass with the CI environment (`CLAUDE_CONFIG_DIR=Fixtures/claude-home
GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home
KEYS_DROID_HOME=Fixtures/droid-home`). Every step exited 0. Verbatim
summaries:

| Step | Command | Exit | Verbatim summary |
|---|---|---|---|
| 1 | `swift test` | 0 | `Executed 870 tests, with 5 tests skipped and 0 failures (0 unexpected) in 135.875 (135.993) seconds` |
| 2 | `(cd Relay && npm test)` | 0 | `Test Files  1 passed (1)` / `Tests  43 passed (43)` |
| 3 | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | `Ran 71 tests in 6.187s` / `OK` |
| 4 | `python3 -m unittest Analytics/test_collector.py` | 0 | `Ran 19 tests in 9.921s` / `OK` |
| 5 | `node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | `Keys dashboard UI passed: 143 cases` |
| 6 | `node scripts/tests/test_analytics_ui.cjs` | 0 | silent on success by design (the script prints only on failure, via `.catch`); verified with a tee'd re-run: empty output, exit 0 |
| 7 | `(cd scripts/tests && npm run test:e2e)` | 0 | dashboard: `Test Files  1 passed (1)` / `Tests  4 passed (4)`; marketing: `Test Files  1 passed (1)` / `Tests  1 passed (1)` |
| 8 | `swift test --filter BackendContractUITests` (`KEYS_BACKEND_CONTRACT_UI=1`) | 0 | `Executed 1 test, with 0 failures (0 unexpected) in 4.645 (4.646) seconds` |

### Skipped, and why

Five skips, all pre-existing opt-in environment gates, unchanged from the
mcp-core closeout:

- `RelayEndToEndTests.testRealWebSocketRoundTripThroughWranglerDev`,
  `testACallDuringAShortOutageWaitsForTheAppRelayAndALongOneGetsA503`,
  `testAWrongSecretIsReportedAsTheWorkersRefusal` — need
  `KEYS_RELAY_E2E_URL`/`KEYS_RELAY_E2E_SECRET` and a live `wrangler dev`.
- `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation` —
  needs an Apple signing identity.
- `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` — opt-in via
  `KEYS_BACKEND_CONTRACT_UI=1`; runs green as CI step 8 above.

### Warnings and noise

- Two pre-existing build warnings, still present at HEAD: an unused `try?`
  result at `Sources/KeysCore/AppUpdater.swift:398` and an unused `withLock`
  result at `Sources/KeysCore/CatalogDB.swift:537` (the latter predates the
  mission; its line number drifts as code lands above it). One further
  warning of the same kind was introduced mid-mission at
  `CatalogDB.swift:807` by `a15aaeb` and is fixed in this closeout commit, so
  the mission leaves exactly the two pre-existing warnings it found.
- The workerd teardown noise line after the Relay suite passes (pre-existing,
  a workerd shutdown artifact, not a failure):
  `exception = workerd/api/streams/identity-transform-stream.c++:291: disconnected: reader canceled`
- Two `ResourceWarning: unclosed file` lines from the python stdio harness's
  SIGINT cleanup (pre-existing, already noted in the mcp-core report).

## The done criterion (VAL-CROSS-001, VAL-CROSS-002)

`MCPClientFlowTests.testOnboardingDoneCriterionFlow`
(`Tests/KeysreallysafeTests/MCPClientFlowTests.swift`) runs the whole
onboarding flow for one synthetic project, end to end, exactly as the done
criterion demands: a real `.build/debug/keys mcp` subprocess over pipes (the
mcp-core `PipeClient` rig, extended with `extraEnvironment` so
`GIT_CONFIG_NOSYSTEM`/`GIT_CONFIG_GLOBAL=/dev/null` make the git facts
deterministic) talking to an in-process synthetic app — a temp catalog (pinned
by `assertNotProductionPath`, per the owner's real-app isolation directive), a
`BlockingPresenceGate` recording every prompt, a `MemorySecretStore`, the
consent-ON `ProductAnalytics` with the recording transport, an
`APIHandler`+`LoopbackHTTPServer` control channel with a request log, a real
`GatewayListener` on port 0, and a stub upstream `LoopbackHTTPServer` standing
in for the provider. The project is a real git fixture repo (git init, local
identity, `core.excludesFile /dev/null`, one committed `.env`) with a
`Dockerfile`; the vault holds two synthetic keys whose values are the env
file's own fakes, gateway hosts pointing at the stub.

The flow asserts, in order:

1. `initialize` → `tools/list` returns the exact roster.
2. `scan_project` reports both variables by name with relative file paths,
   last-4 fingerprints only, both `in_vault` via the hash comparison
   (`vault_check: "app"`), and the Dockerfile detected. No value appears
   anywhere in the transcript.
3. `check_exposure` reports the git facts (`tracked`, `in_history`) with the
   rotate recommendation and never any file contents.
4. `import_and_wrap` with a scripted approval: the recorded prompt is exactly
   one, naming `keys` and the project label
   (`import and wrap 2 keys for project e2eproj: openai, anthropic`), and the
   gate observed it before release. Both outcomes `wrapped`, `new: false`
   (the seeded vault keys were reused by hash dedupe).
5. The env file is rewritten: one `ksfc_` token on both lines, per-key base
   URLs `http://127.0.0.1:<port>/<key>`, no raw value, the `export` and
   quoting style preserved, one 0600 backup holding the original bytes, and
   the wrapped-file record listed.
6. The gateway accepts the project token for a member key: a POST with the
   token forwards `Bearer <the key's real value>` to the stub upstream and
   answers 200; `authorizeGatewayClient` reports `.allowed`.
7. The app-side `keys unwrap` path restores the file byte-for-byte (one more
   recorded prompt, naming the unwrap and the file) and revokes the token.
8. The token is dead: a repeat gateway POST is refused 401 with the upstream
   untouched, and authorization reports `.denied("revoked")`.
9. The hygiene invariants: the subprocess transcript (frame-for-frame compact
   JSON) holds no key value, no `ksfc_` token, and no project absolute path
   in either spelling; the token never appears in any tool result; the
   recording analytics transport — consent explicitly ON — stays empty; and
   nothing token- or value-shaped exists on disk outside the env file, its
   backup and the catalog hash (asserted by sentinel sweeps of the whole temp
   tree both mid-flow and at the end). The control-channel request log is
   exactly `["/api/mcp/vault_lookup", "/api/mcp/import_and_wrap"]`, all POST,
   all origin-token gated, no value or token in any body. Shutdown is a clean
   EOF.

The scoped run: `Executed 2 tests, with 0 failures (0 unexpected)`, and the
test is part of the 870-test green run above.

## Decisions made without user input

Nobody was available during this run; every choice below was made from the
brief, the architecture and the validation contract and is recorded here
rather than silently. Entries 1-11 are the architecture's pinned list
(architecture.md §4, kept verbatim in library/decisions.md); 12-17 were made
inside the mission.

1. One-token-per-project via the `gateway_client_keys` membership table —
   required by the brief; minimal additive schema; per-key tokens unchanged.
2. In-vault comparison app-side by SHA-256 hash over the control channel (the
   brief's first option); honest `unavailable` when the app is down.
3. AWS pairs and credential URLs import under the reserved provider id
   `imported`; providerless key-shaped values with no vault match are not
   imported (reported, `keys add` suggested — the `keys wrap` refusal
   precedent).
4. Name conflicts are skipped and reported; never overwritten or renamed
   silently.
5. `test_keys` is app-mediated via `checkProvider` internals with forced
   per-call presence.
6. The frozen instructions string is unchanged; the ask-each-time rule is
   pinned in the `test_keys` tool description instead.
7. Presence-gated app calls (`import_and_wrap`; `test_keys` with confirm) use
   an explicit ~120 s bound; the 10 s default stays pinned everywhere else.
8. Docker: `docker:true` sets the global `pref_docker_access` and writes
   `http://host.docker.internal:12767/<key>` base URLs for that import;
   absent/false leaves the pref alone and writes loopback URLs. The bind
   stays 127.0.0.1 (research-verified for Docker Desktop — verdict below).
   Host acceptance is exact-match-with-port at the gateway call site only,
   and is compatibility, not a security boundary.
9. The uninstall offer lands in `keys autostart --remove` — verified the only
   uninstall-performing code path (`Installer.uninstall()` at
   `LoginItem.swift:150-165`; no installer/uninstaller script exists).
   `keys purge` gets no offer this mission (deferred recommendation below).
10. mcp-core report decision #5 ("headless owns the docker setter and
    enforcement") is superseded: this brief and grants-first's build split
    assign the Docker question and setting to onboarding. This mission
    implements the enforcement and the import-driven setter; a dashboard
    toggle UI remains the headless mission's area.
11. Scan limits pinned: depth 3, 1 MiB file cap, the 12-directory skip list
    (.git, node_modules, .build, .venv, venv, vendor, dist, build, target,
    Pods, DerivedData, __pycache__), the auth-name guard (auth.json,
    credentials, credentials.json); only `.env`, `.env.local`,
    `.env.production`.
12. Unwrap restores values from the vault (the canonical store), with
    BASE_URL companions restored via the wrap backup (appended → removed;
    replaced → restored) — byte-for-byte in the tested unedited case; without
    a backup, gateway-pointing URL lines are removed (documented fallback). A
    dead vault key is a reported per-line failure, never a silent partial
    state. The file form revokes the file's tokens (by hash of the values it
    holds); the no-arg form revokes the cwd project's tokens.
13. `credential_url` means URLs with embedded userinfo only
    (`scheme://user:pass@host`); a bare `postgres://h/db` is not a secret and
    is not reported.
14. Result paths are relative everywhere on the MCP surface (scan, exposure,
    import outcomes). Absolute paths appear only in the local catalog
    (`wrapped_files`) and the local CLI's own output (precedent: `keys wrap`
    prints backup paths), never in a tool result — success payloads bypass
    the scrubber, so this is by construction.
15. The wrapped-file record is written at apply time for both paths (import
    AND `keys wrap`) so the uninstall offer and `keys unwrap` listing cover
    everything ever wrapped by this build. Additive only; existing wrap tests
    stay green.
16. The runner-assigned branch is accepted for the run; the orchestrator
    restores `droid/014-onboarding` at completion (see the branch note at the
    top).
17. Owner directive (2026-10-28, mid-mission): real-app isolation plus a
    fail-closed test guard. A sibling mission's test reached the real
    installed app and added a key to the real vault. Binding: no test reaches
    the installed app, the real control.json, the real Keychain or
    `~/Library/Application Support/Keysreallysafe` — every control-channel
    test uses a temp control file beside a temp catalog, fake presence and a
    fake secret store, and fails closed if the path under test resolves to
    the production location. Enforced by `assertNotProductionPath` in the
    test support (landed by the import_and_wrap feature and used by every
    later control-channel test, including this closeout's rig, which also
    asserts `KEYS_CATALOG` on the subprocess side); `Installer.uninstall` is
    never executed from tests.

## Docker research verdict

Web-researched 2026-10-28 (full text in the mission library,
`library/docker-access.md`). **The 127.0.0.1-only bind stays.** On Docker
Desktop for Mac, a container's connection to `host.docker.internal:PORT` is
intercepted by the VM's network stack and handed to Docker Desktop's backend
process on macOS, which dials the port on the host itself using the host's
loopback — "All outbound container network traffic originates from the
`com.docker.backend` process"
(https://docs.docker.com/desktop/features/networking/). Therefore a service
bound only to 127.0.0.1 IS reachable from containers via
`host.docker.internal`, with no port publishing and no non-loopback bind; the
accepted connection arrives loopback-sourced, and the HTTP Host header is
exactly the client's URL authority because the forward is TCP-level and
rewrites nothing.

Caveats, all documented in `docs/agents.md` (VAL-DOCK-005):

- **Docker Desktop only.** Native Linux Docker resolves
  `host.docker.internal` (via `--add-host=host.docker.internal:host-gateway`)
  to the bridge gateway — a non-loopback address — so a loopback-only bind is
  NOT reachable there.
- **Compatibility, not a security boundary.** Any container on the user's
  Desktop VM can already dial the VM-internal address and spoof
  `Host: 127.0.0.1:12767`; the real boundary is "who can run containers in
  the user's Docker Desktop" and the token is still the gate.
- Non-browser SDK/curl clients from containers send no
  `Origin`/`Sec-Fetch-Site` headers (absent → allowed); a browser page inside
  a container stays blocked by the Origin/Sec-Fetch gates — deliberate, do
  not relax them.

## Deferred recommendations

- **`keys purge` should carry the same unwrap offer** as
  `keys autostart --remove`. The offer machinery and the wrapped-file record
  are in place for both paths; purge was left out of scope this mission
  (decision 9) and is the natural follow-up so a purge cannot strand a
  project pointing at a dead gateway either.

## Known pre-existing issues (not caused by this mission, deliberately not fixed here)

- The two build warnings listed above (`AppUpdater.swift:398`,
  `CatalogDB.swift:537`).
- The five opt-in skips listed above — environment gates, not failures.
- The dead CRLF check in `CodexSetup.upsert`/`GrokSetup.upsert`
  (`Sources/KeysCore/AgentSetup.swift`), inherited from the mcp-core report:
  a grapheme-level `text.contains("\r")` is false for a real CRLF file, so a
  CRLF config silently takes the append path. Unchanged this mission; a
  future owner of `AgentSetup.swift` should replace both checks with a
  byte-level CR test.

## Git evidence

- **Branch:** `droid/build-envscan.swift-module` — see the header note; the
  orchestrator restores `droid/014-onboarding` before completion, a rename
  touching none of the commits.
- **Commit order (oldest first):** `2b8bb57`, `6fad652`, `9c82447`,
  `a15aaeb`, `2158fba`, `64d6b13`, `b755d20`, `811e1a1`, `daba5d3`,
  `93c2415`, then this closeout commit (docs, the end-to-end pipe test, the
  warning fix, this report).
- **Scope:** 34 files, +7,610/−74 against `02dd7d8` before the report commit:
  16 files in `Sources/KeysCore`, 15 in `Tests/KeysreallysafeTests`,
  `docs/agents.md`, `README.md`, and this report. `scripts/tests` untouched
  (the mission added no python harnesses; the discovery count stays 71).
- Nothing was pushed, merged, released or deployed. No key value appears in
  any commit: the one key-shaped literal in the entire diff is the synthetic
  `sk-ant-…NEVER-REAL…` fake built at runtime inside the end-to-end test.

## Coverage highlights

All inside the green CI run, for this mission's surface: `EnvScanTests` 19/19
(the walk, the limits, the skip list, the auth-name guard, classification),
`ScanProjectToolTests` 9/9, `CheckExposureToolTests` 10/10,
`ProjectClientTokenTests` 11/11, `GatewayClientTests` 8/8,
`DockerGatewayAccessTests` 5/5 (default-off refusal before lookup, the
exact-match matrix, per-request toggle, dashboard refusal, the source-level
pin that `HTTPFrame.swift`/`Support.swift` never contain
`host.docker.internal`), `ImportAndWrapTests` 22/22, `TestKeysToolTests`
14/14, `UnwrapTests` 13/13, `UninstallOfferTests` 12/12, `EnvWrapTests` 17/17
(the pre-existing wrap suite plus the record-at-apply additions),
`ReadToolsTests` 14/14 (including the expiry additions), `MCPClientFlowTests`
2/2 (the mcp-core flow plus the done-criterion flow above),
`MCPRegistryTests` 3/3 (the exact literal roster pin), `MCPOutputGuardSweepTests`
2/2 (the planted-secret sweep over every registered tool), and
`MCPServerInstructionsTests` 2/2 (the frozen instructions string
byte-for-byte). The full suite went from 750 XCTest cases at the mcp-core
closeout to 870 here, with the python discovery unchanged at 71 and the five
pre-existing skips unchanged.
