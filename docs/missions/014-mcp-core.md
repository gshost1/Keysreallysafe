# Mission report: 0.14 mcp-core — `keys mcp`, project identity, grants over MCP, read tools

Run on 2026-10-28 in the worktree
`/Users/Shost2/Projects/Keysreallysafe/.claude/worktrees/droid-014-mcp-core`,
on branch `droid/build-mcp-server-core-in` — **not** the `droid/014-mcp-core`
the mission brief names. The runner assigned every worker the
`droid/build-mcp-server-core-in` branch and forbade branch renames mid-mission,
so every mission commit landed there, in this order; the orchestrator restores
the required name `droid/014-mcp-core` before completion, which renames the
branch and touches none of the commits below. Nothing was pushed, merged or
deployed.

The mission is build-split item 1 of the approved design
(`docs/proposals/grants-first.md`, whose "Owner review" section overrides the
text above it): **`keys mcp`** — a stdio JSON-RPC 2.0 MCP server inside the
`keys` binary — plus the tool registry, one output guard, one app-connection
seam, project identity in the catalog, grants asked over MCP and approved with
Touch ID in the app, five read tools, `keys setup mcp` registration for five
agent clients, the shortened agent skill, and this end-to-end closeout. Three
later missions (onboarding, headless app, feedback/analytics) branch from this
one in parallel, so the seams are a first-class deliverable (below).

Everything below ran offline on this machine: temp homes, temp catalogs,
`MemorySecretStore`, `RecordingPresenceGate`/`BlockingPresenceGate`, ephemeral
loopback ports only (never 12766/12767, which belong to the installed
`/Applications/Keysrs.app`), no Keychain, no Touch ID, no network beyond
loopback, no real credential, and the five real agent config files untouched.

## What changed, feature by feature

| Commit | Feature | What it added |
|---|---|---|
| `34afbba` → `930eb29` | design gate (5 commits: propose `34afbba`, fact-check `d01d004`, decided items `5bbdfeb`, threat-model fix `867d40b`, owner review `930eb29`) | `docs/proposals/grants-first.md`, the approved design and its owner review |
| `4679cf2` | mcp-server-core | `Sources/KeysCore/MCPServer.swift` (read loop → dispatch → one serialized writer, the five-code error table, tool failures as `isError` results through a path-scrubbing formatter, legacy-era `initialize` with version negotiation, `notifications/initialized`, `ping`, `tools/list`, `tools/call`, EOF and SIGINT/SIGTERM exit 0), `McpCommand` + the `MCPRun.runStdio` wiring in `CLI.swift`, the `MCPToolGroup` protocol with the `version` group, and the injected run seam the in-process tests drive |
| `a29f442` | mcp-tool-registry | `MCPToolRegistry` (deterministic roster, per-group refusal as a unit, containment), the registry tests including the literal mission-roster pin, and the test-only group that proves additivity |
| `1c55a37` | mcp-output-guard | `MCPOutputGuard` — the unconditional `ksf_`/`ksfc_`/`ksfp_` token-shape rule with the one `grant_status` handover exemption, the injected exact-value rule, replace-not-scrub, fail-closed, never logs; the single write path; the empty-by-construction production wiring; the roster-derived planted-secret sweep |
| `1210df5` | mcp-app-connection | `Sources/KeysCore/AppConnection.swift` — `connect()` as the one "is the app running?" decision, the exact not-running sentence, the 10 s app-call timeout, and the roster-wide rule that no tool calls `ControlClient.connect()` directly |
| `0ab4577` | project-identity | `Sources/KeysCore/Projects.swift` — the `projects` table, the nullable `gateway_clients.project` column (fresh DBs and the guarded `ALTER` for old ones), `Project.canonicalFolder`, `KeysService.resolveProject`, label collision disambiguation, `project`/`project_label` in `GatewayClient.jsonObject` — never the path |
| `5a22384` | mcp-read-tools | `MCPReadTools` (`list_keys`, `gateway_info`, `open_app`, `check_update`) with offline-safe construction, the app-side `POST /api/mcp/gateway_info` and `POST /api/mcp/app/show` routes, the `pref_docker_access` read, and the literal roster pin |
| `b3cc98a` | mcp-client-registration | `keys setup mcp` (`Sources/KeysCore/MCPRegistration.swift` + the agent-argument branch above vault-key resolution), `TOMLFile.removeSection`, the five client writers with their merge/`.bak`/idempotency/refusal rules, the documented home overrides (`CODEX_HOME`, `KEYS_CURSOR_HOME`, `KEYS_CLAUDE_JSON`, `KEYS_CLAUDE_DESKTOP_HOME`), `scripts/tests/test_keys_setup_mcp.py`, and the shortened `Skills/keysrs/SKILL.md` (pointer note, ≤200-line body, all six pins) |
| `5da189c` | grants-over-mcp | `Sources/KeysCore/MCPGrants.swift` (the app-side lock-guarded pending store, 300 s TTL with injected clocks, cap 8, synchronous refusals, owner check at create, one presence prompt naming key/host/label, the token captured and delivered exactly once) and `MCPGrantTools` (`request_grant`, `grant_status`), over `POST /api/mcp/grants` and `POST /api/mcp/grants/<id>/status` |
| `8f9bb59` | mcp-end-to-end-and-closeout (a) | `Tests/KeysreallysafeTests/MCPClientFlowTests.swift` — the done-criterion test: the real `.build/debug/keys mcp` subprocess over pipes against the in-process synthetic app, driving the whole flow (below) |
| `b3d8f33` | mcp-end-to-end-and-closeout (f,g) | `README.md` (the `keys mcp` and `keys setup mcp` entries, the truthful shortened-skill description) and `docs/agents.md` (the intro reworded, the MCP-server workflow section, the never-returning rule covering `keys mcp`) |
| (this commit) | mcp-end-to-end-and-closeout (d,e,h,i) | this report |

Scope diff against `origin/main` before the report commit: 46 files,
9,908 insertions, 256 deletions — nine new `Sources/KeysCore/MCP*` files,
16 new test files plus additions to `TestSupport.swift`, `AgentSetupTests`
and `AgentSkillTests`, two new python harnesses in `scripts/tests/`, the
shortened skill, `docs/proposals/grants-first.md`, and the README/docs edits.

## Test results — the full CI list

`.github/workflows/test.yml` is the full list CI runs; every step below was
run in this session, in CI order, with the CI env
(`CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home`),
serialized one command at a time (this 8 GB machine shares memory with the
browser suites). Node is 26.7.0 locally where CI pins 22; every suite passes
on both. No step was narrowed or subsetted.

| # | Command | Exit | Wall | The suite's own summary |
|---|---|---|---|---|
| 1 | `swift test` (CI env) | 0 | 113 s | `Executed 750 tests, with 5 tests skipped and 0 failures (0 unexpected) in 112.276 (112.383) seconds` |
| 2 | `(cd Relay && npm ci && npm test)` | 0 | 12 s | `Test Files 1 passed (1)`, `Tests 43 passed (43)` — workerd, offline |
| 3 | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 0 | 7 s | `Ran 71 tests in 6.177s — OK` (includes the 7 `keys mcp` stdio cases and the 2 `keys setup mcp` end-to-end cases) |
| 4 | `python3 -m unittest Analytics/test_collector.py` | 0 | 10 s | `Ran 19 tests in 9.964s — OK` |
| 5 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs` | 0 | 152 s | `Keys dashboard UI passed: 143 cases` |
| 6 | `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs` | 0 | 4 s | silent on success — the exit code is the pass signal (observed empty output, exit 0) |
| 7 | `(cd scripts/tests && npm run test:e2e)` | 0 | 10 s | dashboard target `Tests 4 passed (4)`, marketing target `Tests 1 passed (1)` |
| 8 | `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=scripts/tests/node_modules swift test --filter BackendContractUITests` (CI env) | 0 | 8 s | `Backend contract UI passed: 12 cases against http://127.0.0.1:50244`, `Executed 1 test, with 0 failures (0 unexpected) in 4.443 (4.443) seconds` |

**Passed:** all eight steps, nothing red. Nothing this mission caused needed
fixing during closeout, and nothing was already red on `main`: the same eight
steps were verified green during mission readiness before any implementation
landed (640 XCTest cases then; 750 now — the mission added roughly 110).

**Skipped (5, all pre-existing, all opt-in, none a failure):**

- 3 × `RelayEndToEndTests` — need `KEYS_RELAY_E2E_URL` and
  `KEYS_RELAY_E2E_SECRET` with a `wrangler dev` running.
- 1 × `StableSigningTests` — needs an Apple signing identity.
- 1 × `BackendContractUITests` inside the unfiltered `swift test` — the
  browser contract harness; run with `KEYS_BACKEND_CONTRACT_UI=1` (table row
  8) it passes fully: 12 cases, 0 failures.

Known non-failing noise, unchanged from before the mission: two
`ResourceWarning: unclosed file` lines from the python stdio harness's
SIGINT-test cleanup during step 3's discovery, and the workerd
identity-transform-stream teardown line during the Relay tests.

## The done-criterion end-to-end test

`Tests/KeysreallysafeTests/MCPClientFlowTests/testDoneCriterionFlow`
(VAL-CROSS-001) spawns the built `.build/debug/keys mcp` as a real subprocess
with `KEYS_CATALOG` pointing at a temp catalog, and runs an in-process
synthetic app beside that same catalog — a real `APIHandler` behind a
`LoopbackHTTPServer(port: 0)` (never 12767), `control.json` written beside the
catalog, `MemorySecretStore` secrets and a `BlockingPresenceGate` standing in
for Touch ID. It drives, over the subprocess's real stdin/stdout pipes:
initialize → `notifications/initialized` → `tools/list` (the exact
deterministic roster) → `tools/call list_keys` (name, provider, kind and the
project label — never a value) → `tools/call request_grant` →
`{"status":"pending","id":…}`, tokenless, while the app's one prompt is
provably up → two `grant_status` polls reading pending → the gate released
(the faked approval) → polls until `approved` with the `ksf_` token,
`base_url` `http://127.0.0.1:12767/demo/v1`, `gateway_url` and
`auth_header` → one more poll reading `{"status":"approved","id":…,
"delivered":true}` with no token. Then it proves the process contract:
stdout holds exactly one compact sorted-key JSON-RPC response per
request-bearing line (byte-identical round-trip through the repo encoder)
and zero bytes for the notification; the token crossed the pipe exactly
once; the vault secret and the project path crossed never; closing stdin
exited 0 within the 2 s bound; stderr held prose only. It ran green four
times in a row (0.47–0.49 s each) and left no orphaned process.

The same session carries the offline-and-silent proof at the subprocess level
(VAL-CROSS-003): every HTTP request the subprocess sent was recorded arriving
at the loopback server — all of them on the `/api/mcp/…` routes, one create
plus every poll — and the recording analytics transport (consent explicitly
ON) held zero calls and zero fetches. The delivered token was also swept out
of the whole temp tree: nothing token-shaped touched disk. The in-process
half of the assertion already existed and stayed green
(`MCPOutputGuardSweepTests.testOfflineAndSilent`: empty analytics transport,
≤ 2 s per tool, nothing fetched).

**Why the driver is XCTest, not python.** The flow needs the in-process
synthetic app to approve while the subprocess polls, and that rig
(`APIHandler` + `LoopbackHTTPServer` + `BlockingPresenceGate`) is Swift test
support — so the driver that spawns the real binary lives beside it, as
`MCPClientFlowTests`. The python stdio harness
(`scripts/tests/test_keys_mcp_stdio.py`, from the server-core feature) keeps
the process half that does not need an app: framing, `--help`/`--bogus`, EOF
and SIGINT/SIGTERM exit codes. **`.github/workflows/test.yml` needed no edit**
for either: the XCTest flow runs inside step 1 (`swift test`), and the python
harness is picked up by the existing discovery in step 3 — both were green in
the table above without any workflow change.

## The seams for the parallel missions

These are the exact places a later mission extends. **The parallel missions
(onboarding, headless app, feedback/analytics) branch from this branch and
must land their changes through these seams only.**

1. **The tool registry — one file plus one line.** To register a tool group,
   create `Sources/KeysCore/MCP<Topic>Tools.swift` conforming to
   `MCPToolGroup` (the protocol is documented at
   `Sources/KeysCore/MCPToolRegistry.swift:90`: `groupName`, `tools()`,
   `call(_:arguments:)`), and add **one line** to the groups list at
   `Sources/KeysCore/MCPToolRegistry.swift:155`:

   ```swift
   static var groups: [any MCPToolGroup] { [MCPVersionTool(), MCPReadTools(), MCPGrantTools()] }
   ```

   Nothing else changes: `tools/list` and `tools/call` follow the roster, the
   guard screens the results, and a group that breaks the contract (bad name,
   non-object schema, name collision) is refused as a unit with one stderr
   line while the server keeps serving. Three follow-ups a new group must
   make deliberately, or existing tests fail by name: wire the group over
   the test seams in `MCPRoster.groups`
   (`Tests/KeysreallysafeTests/MCPServerTestSupport.swift:211`); give every
   new tool an offline-safe argument row in `MCPSweepRig.argumentRows`
   (`MCPServerTestSupport.swift`, the sweep's roster comparison fails naming
   any unwired group); and update the literal roster pin in
   `MCPRegistryTests`/`MCPClientFlowTests` knowingly — that pin is what stops
   a wrongly-named tool shipping.

2. **App-side routes — `/api/mcp/…`, POST and token-gated.** The route switch
   at `Sources/KeysCore/HTTPServer.swift:175-185` holds the convention:
   exact paths under `/api/mcp/` (`gateway_info`, `app/show`, `grants`,
   `grants/status`) plus the `/api/mcp/grants/<id>/status` prefix case, all
   POST, all inheriting the existing `mutatingAPI` origin-token gate. A new
   app-side surface is a new case in that block, answering through
   `APIHandler` with the house error envelope; a GET under `/api/` would be
   ungated by the house rule and must never be added for anything that can
   carry state or a token.

3. **Project identity — one resolution function.**
   `KeysService.resolveProject(folder:now:)`
   (`Sources/KeysCore/Projects.swift:114`) is the only place a folder becomes
   a project; `Project.canonicalFolder(_:)` (`Projects.swift:25`) is the
   symlink-resolving canonicalization (`/var` → `/private/var`, one row per
   folder). The label (folder name, parent-qualified on collision) is the only
   project fact any tool, prompt, log or analytics row may carry — the
   canonical path never leaves the Mac.

4. **The output guard — the single write path.** Every `tools/call` result is
   screened at `Sources/KeysCore/MCPServer.swift:225-226` before the one
   stdout writer; the guard itself (`Sources/KeysCore/MCPOutputGuard.swift`,
   production construction at `:65`) rejects full `ksf_`/`ksfc_`/`ksfp_`
   token shapes except the one value a `grant_status` approval hands over
   (`MCPToolResult.handover`), replaces rather than scrubs, never logs, and
   fails closed. No tool may build its own output path, and no MCP tool may
   call a presence-gated read — that structural rule, not a runtime check, is
   what keeps the production forbidden-value set empty by construction.

5. **`AppConnection.connect()` — the one "is the app up?" decision.**
   `Sources/KeysCore/AppConnection.swift:46` wraps `ControlClient.connect()`
   and translates failure into exactly "Keysrs isn't running. Open Keysrs
   from Applications, then try again." The app-call timeout is 10 s, the
   not-running condition is a tool result and never a process exit, and no
   tool may call `ControlClient.connect()` directly. **When the headless-app
   mission adds auto-launch, it lands inside this one function only.**

## Decisions made without user input

Nobody was available during this run; every choice below was made from the
approved proposal and the validation contract and is recorded here rather
than silently. The first twelve are the orchestrator's pinned list, carried
from the contract so the parallel missions inherit the same answers; the rest
were made inside the mission.

1. Legacy MCP era only: `initialize` with versions `2024-11-05`…`2025-11-25`
   (echo a supported client version, else the newest); an unknown method —
   including `server/discover` — answers `-32601`, the documented dual-era
   fallback.
2. `list_keys` returns the brief's reduced shape (`name`, `provider`, `kind`,
   `projects` as labels); no per-key last-4 and no per-key expiry exist in the
   model, so none is invented.
3. `gateway_info` requires the app and fails as a whole with the not-running
   error, so "no grants" is never indistinguishable from "cannot see grants".
4. `open_app` uses a dedicated show path; it never touches
   `openDashboard()`'s browser fallback or LaunchServices.
5. `docker_access` reads the new catalog-meta preference `pref_docker_access`
   (`"on"`/`"off"`, default off); this mission only reads it, the headless
   mission owns the setter and enforcement.
6. `request_grant` takes no host: the host is derived from the key and shown
   in the prompt, so a caller can never retarget it.
7. Both app-side grant routes are POST and explicitly token-gated, never GET.
8. The project reaches the prompt as a label: the MCP process sends its
   folder, the app canonicalizes, derives the label and owns the row.
9. Pending requests live 300 s with injected clocks; the token is delivered
   on exactly the first approved poll, and later polls report `delivered`
   with no token.
10. Registration is `keys setup mcp`, handled above vault-key resolution;
    `--remove` covers all five clients; the server name is `keysrs`; a
    wrong-typed own entry is refused rather than replaced.
11. New home overrides (`CODEX_HOME`, `KEYS_CURSOR_HOME`, `KEYS_CLAUDE_JSON`,
    `KEYS_CLAUDE_DESKTOP_HOME`) make each client testable in a temp home;
    `CLAUDE_CONFIG_DIR` is not claimed to relocate `~/.claude.json`, and
    `HOME=$tmp` is never used as confinement.
12. The skill keeps all five existing pins plus the ≤200-line pin; only the
    stale gateway-path sentences were reworded.
13. (Contract consolidation rulings, binding:) `ping` before `initialize`
    answers `-32600` like every pre-initialize request; the `open_app` show
    route is a POST so it inherits the token gate; pending ids are 8-hex like
    grant and project ids; registration is unconditional for all five clients
    (missing directories created); the guard's token-shape list is
    `ksf_`/`ksfc_`/`ksfp_` in one constant.
14. (Closeout's own:) the done-criterion driver is XCTest beside the Swift
    synthetic-app rig, with the python harness keeping the process half (see
    above); the E2E asserts the loopback-only and analytics-silent contract
    from the subprocess side too, with the app's analytics consent explicitly
    ON to prove MCP activity never enrolls the user; the subprocess's project
    folder is its own working directory (a temp folder), which is exactly what
    production sends; the docs commits landed before this report so the CI
    table above covers the final code tree.

## The owner checklist (VAL-MANUAL-001…010)

These ten need the owner's machine or a real client and are **not automated**
— this section is the deliverable for them, not a test. Each item records what
the offline suites already proved and what only the owner can observe; every
status is pending until the owner records the observation.

| Item | What the offline side proved | What only the owner can observe | Status |
|---|---|---|---|
| VAL-MANUAL-001 — the real Touch ID sheet | The recorded reason names the key, the resolved host and the project **label**, one prompt per request, no path, no token (GrantMCPTests; the E2E flow asserts it too) | The rendered sheet on a logged-in Mac: approve and cancel one real MCP request, read the names | pending owner observation |
| VAL-MANUAL-002 — real screen lock | `handleScreenLock()` driven directly fails pending requests closed, existing grants revoked (GrantMCPTests) | The real `screenIsLocked` event with an in-flight sheet: lock the screen during a pending request, watch it end denied, never approved after unlock | pending owner observation |
| VAL-MANUAL-003 — open_app fronts the window | The route + show seam pinned; no LaunchServices, no browser (ReadToolsTests) | On a built `Keysrs.app`, invoke `open_app` through a real client and watch the window come front-most | pending owner observation |
| VAL-MANUAL-004 — real check_update | The fetch faked; every failure mode a plain tool error, nothing installed (ReadToolsTests) | One real run against GitHub's latest-release API: record current/latest/update_available and that nothing was downloaded | pending owner observation |
| VAL-MANUAL-005 — Claude Desktop loads the entry | The documented stdio shape written and merged around `coworkUserFilesPath`/`preferences` (MCPRegistrationTests) | The real app: register on a scratch home, restart Claude Desktop, confirm `keysrs` is listed and answers; if the real app needs a `type` key, the documented shape (and VAL-REG-007) flip with the docs | pending owner observation |
| VAL-MANUAL-006 — the real clients list the server | Five registration shapes written and verified in temp homes (MCPRegistrationTests, `test_keys_setup_mcp.py`) | Each real client (Claude Code, Codex, Cursor, Droid) on a scratch home listing the `keysrs` server, and Droid accepting the entry in practice (which also settles the trailing-newline format question) | pending owner observation |
| VAL-MANUAL-007 — CLAUDE_CONFIG_DIR and `~/.claude.json` | Production writes `~/.claude.json` and is not claimed otherwise; tests use `KEYS_CLAUDE_JSON` | Whether the real `claude` binary relocates `~/.claude.json` under `CLAUDE_CONFIG_DIR`, and whether the two overrides coexist | pending owner observation |
| VAL-MANUAL-008 — the production guard under the real Keychain | The production guard references no secret store and never reads one; the token-shape rule and the no-presence-gated-read structure are pinned (VAL-MCP-GUARD-008/009, the sweep) | On a real install with real keys: a session spot check that no tool result ever carries a value (e.g. a `list_keys` transcript with the secret absent) | pending owner observation |
| VAL-MANUAL-009 — the five real config files untouched | The structural proof: writer signatures take injected URLs, every test confined by explicit homes, the CLI tests parse only (VAL-REG-012) | Optional belt, not a gate: attribute-only snapshots (exists, size, mtime — never content) of the five real paths before and after running the registration suite; note `~/.claude.json`'s mtime moves whenever the running Claude Code rewrites it | pending owner observation (optional) |
| VAL-MANUAL-010 — docs/agents.md consistent with the shortened skill | **Addressed in this feature** (`b3d8f33`): the intro no longer claims the rules exist in short form in the skill (it is a pointer note), the MCP-server workflow section exists (tools, the grant handover, where registration writes, loopback-only), and the never-returning rule covers `keys mcp` | Read the updated page and confirm it reads right | code done; owner review pending |

## Known pre-existing issues (not caused by this mission, deliberately not fixed here)

- **The dead CRLF check in the gateway config writers.**
  `CodexSetup.upsert` and `GrokSetup.upsert` in `Sources/KeysCore/AgentSetup.swift`
  test `text.contains("\r")`, which is false for a real CRLF file (a CRLF pair
  is one grapheme cluster in Swift), so a CRLF `~/.codex/config.toml`
  silently takes the append path and duplicates the section instead of being
  refused. Reported by the mcp-client-registration worker, which left it
  alone because VAL-REG-015 requires the existing setup surface to stay
  purely additive. The mission's own MCP registration is correct — it checks
  the bytes (`Data.contains(0x0D)`) — so no MCP deliverable is affected. A
  future mission that owns `AgentSetup.swift` should replace both checks with
  a byte-level CR test and add a CRLF refusal test per writer.
- **Five pre-existing opt-in test skips** (listed in the test-results
  section): three relay e2e cases needing `wrangler dev`, the Apple-signing
  test, and the backend-contract UI case that CI runs explicitly as its own
  step. They are environment gates, not failures.
- **Two pre-existing build warnings**, still present at HEAD (confirmed by
  recompiling the two files after the CI run): an unused `try?` result at
  `Sources/KeysCore/AppUpdater.swift:398` and an unused `withLock` result at
  `Sources/KeysCore/CatalogDB.swift:511` (the line drifted from the
  previously documented 489 when the grants feature added code above it).

## Git evidence

- **Branch:** `droid/build-mcp-server-core-in` — see the header note. The
  brief's required name `droid/014-mcp-core` is restored by the orchestrator
  before completion; the commits and their order are untouched by it.
- **Commit order (oldest first):** `34afbba`, `d01d004`, `5bbdfeb`,
  `867d40b`, `930eb29` (the design gate), then the eight implementation
  features `4679cf2`, `a29f442`, `1c55a37`, `1210df5`, `0ab4577`, `5a22384`,
  `b3cc98a`, `5da189c`, then this feature's `8f9bb59` (the end-to-end pipe
  test), `b3d8f33` (README + docs/agents.md) and the report commit that adds
  this file.
- **Scope:** 46 files, +9,908/−256 against `origin/main` before the report
  commit (the per-feature table above maps every commit). No file outside the
  mission's scope is touched; the frozen identifiers, the five real config
  files, `/Applications/Keysrs.app`, the Site and Relay workers are all
  untouched.
- Nothing was pushed, merged, released or deployed.

## Coverage highlights

All inside the green CI run, for this mission's surface: `MCPServerTransportTests`
8/8 (framing, envelope, malformed lines, terminators, the 4 MiB cap,
pipelining, parser robustness), `MCPServerInitializeTests` 3/3,
`MCPServerLifecycleTests` 4/4, `MCPServerShutdownTests` 2/2,
`MCPServerToolsTests` 7/7, `MCPServerInstructionsTests` 2/2 (the frozen
instructions string byte-for-byte), `McpCommandTests` 1/1, `MCPRegistryTests`
3/3 (the seam's additivity, the exact literal roster, the absence of the
eight not-yet-built tools), `MCPOutputGuardTests` 9/9 (both rules, the one
handover, fail-closed, the empty production wiring, no presence-gated read),
`MCPOutputGuardSweepTests` 2/2 (the planted-secret sweep over every registered
tool; offline-and-silent), `MCPAppConnectionTests` 6/6, `ProjectIdentityTests`
11/11, `ReadToolsTests` 10/10, `GrantMCPTests` 22/22 (the whole grants-over-MCP
contract: pending/immediate, prompt content, delivered-exactly-once, refusals,
no-widening, TTL with injected clocks, cap 8, owner check at create, concurrency,
app lifecycle edges), `MCPRegistrationTests` 14/14 (five clients, `.bak`,
idempotency, removal, corrupt-refusal, no-secret, confinement),
`MCPClientFlowTests` 1/1 (the done-criterion flow over real pipes), the
shortened skill's pins in `AgentSkillTests` 9/9, `TOMLFile.removeSection` and
the existing-setup regression pins in `AgentSetupTests` 12/12, plus the python
side: `test_keys_mcp_stdio.py` 7/7 (process-half framing, shutdown, signals,
`--help`/`--bogus`) and `test_keys_setup_mcp.py` 2/2 (register five, verify
five, remove five, exit codes). The full suite went from 640 XCTest cases at
readiness to 750, and the python discovery from 62 to 71, with the five
pre-existing skips unchanged.
