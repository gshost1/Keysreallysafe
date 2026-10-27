# Mission report: the agent skill and predictable CLI

Between `b056ddd` and `fec6eb7` (all 2026-10-27), the `droid/agent-skill` branch
made the `keys` CLI safe and predictable for AI agents and shipped the official
Keysrs agent skill with the app. This report records what the validation
actually ran, what it produced, and why the deliverables are shaped the way
they are. Every command quoted below was executed at the final state of the
branch — `fec6eb7`, the last code commit — and nothing here is reconstructed
from intention. The commit that adds this file changes documentation only, and
no suite in the repository enumerates `docs/`, so it cannot change a result
below.

## What was run, and what passed

The suites `.github/workflows/test.yml` runs, in the worktree, with the
environment CI sets:

| Suite | Command | Result |
|---|---|---|
| Swift, CI env | the four fixture vars + `swift test` | exit 0 — 551 executed, 5 skipped, 0 failures, 46.66 s |
| Packaging | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | exit 0 — 62 tests, OK |
| Analytics collector | `python3 Analytics/test_collector.py` | exit 0 — 19 tests, OK |
| Relay Worker | `cd Relay && npm ci && npm test` | npm ci exit 0; npm test exit 0 — 36 tests passed, 5.16 s |

**The Swift suite** (the CI command, exactly):

```sh
CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home \
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home \
swift test
```

Exit 0, and the suite's own summary:

```text
Executed 551 tests, with 5 tests skipped and 0 failures (0 unexpected) in 46.663 (46.732) seconds
```

The mission's five new test files contribute 27 of those cases —
`VersionCommandTests` (5), `StatusCommandTests` (7), `SetupCommandTests` (5),
`ExitCodeTests` (5), `AgentSkillTests` (5) — and the planning record counted 524
executed at the mission's starting tree, so the count moved 524 → 551 with no
case removed and the same five skips (below) before and after.

**The packaging suite**: exit 0, `Ran 62 tests in 0.975s` / `OK`. The count did
not grow: the skill's coverage went into the existing fixture-repo and
layout-contract cases — `make_repo` now stages `Skills/keysrs/SKILL.md`, the
hardcoded layout set and `prepare-release.py`'s `expected_app_files()` both pin
it — so drift fails the same 62 cases rather than new ones.

**The analytics collector**: `python3 Analytics/test_collector.py` — exit 0,
`Ran 19 tests in 9.964s` / `OK`; CI's exact form
`python3 -m unittest Analytics/test_collector.py` — exit 0,
`Ran 19 tests in 9.944s` / `OK`. `Analytics/` is untouched by this mission.

**The relay Worker** — the suite CI runs offline inside workerd. A skip was
prepared for (the offline sandbox was expected to refuse the registry), but it
did not arise: `npm ci` fetched the pinned toolchain (wrangler 4.151.2,
vitest 4.1.12, `@cloudflare/vitest-plugin` 1.4.5) and `npm test` exited 0:

```text
 Test Files  1 passed (1)
      Tests  36 passed (36)
   Start at  01:48:43
   Duration  5.16s (transform 31ms, setup 0ms, import 66ms, tests 4.33s, environment 0ms)
```

`Relay/` is untouched by this mission, so this is the pre-existing suite re-run
at the final state, not new coverage. Two footnotes about that run: npm 11
printed an allowScripts notice that `esbuild`, `fsevents` and `workerd` carry
install scripts that were not run — the suite passed anyway, because those
packages ship their platform binaries as optional dependencies; and workerd
logged one line
(`exception = workerd/api/streams/identity-transform-stream.c++:291: disconnected: reader canceled`)
during the disconnect-path tests — the run still reports 36/36 and exit 0,
with no `Uncaught (in promise)` line of the kind the suite fails on.

**Binary spot checks** — the built `./.build/debug/keys` in a fresh temp `HOME`
with `KEYS_CATALOG` at a temp catalog file path (the recipe in
"Operational notes"):

```sh
$ ./.build/debug/keys version --json
{"version":"0.12.0"}                 # exit 0
$ KEYS_CATALOG=$tmp/catalog.db ./.build/debug/keys grants
no running Keysrs site owns the gateway; open Keysrs.app or run keys dashboard, then retry
                                     # exit 6, no stdout
$ KEYS_CATALOG=$tmp/catalog.db … keys status --json   # with the CI fixture env
{"tools":[…12 entries…]}             # exit 0, one line, 1752 bytes, parses with python3 -m json.tool
```

All three match the documented contract: the version probe, exit 6 with the
stable stderr line for a site that is down, and one line of sorted-key JSON.

## The five skips inside the Swift suite

All five are opt-ins gated on an environment this run does not provide, and
all five predate the mission (CI runs none of them as part of `swift test`):

| Skipped case | Gate |
|---|---|
| `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation` | `KEYS_SIGNING_IDENTITY`, an Apple signing identity; run before deploying signing changes |
| `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` | `KEYS_BACKEND_CONTRACT_UI=1` plus a Playwright browser; CI runs it as its own final step |
| `RelayEndToEndTests.testRealWebSocketRoundTripThroughWranglerDev` | `KEYS_RELAY_E2E_URL` and `KEYS_RELAY_E2E_SECRET`, with `wrangler dev` running |
| `RelayEndToEndTests.testAWrongSecretIsReportedAsTheWorkersRefusal` | same |
| `RelayEndToEndTests.testACallDuringAShortOutageWaitsForTheAppRelayAndALongOneGetsA503` | same, plus `KEYS_RELAY_E2E_GRACE_MS` |

## What failed

Nothing. Every suite above exited 0 with zero failures, and the final pass
needed no fix. There is no failure output to record.

## What was skipped, and why

- **The dashboard Playwright UI suites** —
  `node scripts/tests/test_keys_dashboard_ui.cjs`,
  `node scripts/tests/test_analytics_ui.cjs`, and the tester-army e2e
  (`npm run test:e2e` in `scripts/tests`), plus the backend-contract UI step
  (`KEYS_BACKEND_CONTRACT_UI=1 swift test --filter BackendContractUITests`)
  that drives the same browser. Three reasons:
  1. `Web/` is untouched by this mission —
     `git diff --stat ffd3df4..fec6eb7 -- Web/` is empty — so nothing that
     landed could change what those suites assert.
  2. The pinned browser toolchain is not installed here: `scripts/tests` has
     no `node_modules` (playwright 1.63.0, e2e 0.16.0 and `@e2e-dev/web` 0.11.2
     are pinned), so the Chromium build those suites drive is absent for this
     checkout, and the mission's environment rules say not to install it. Some
     Chromium builds from other tooling sit in `~/Library/Caches/ms-playwright`,
     but none is tied to this repo's pinned package, which is not present to say
     which revision it wants.
  3. The local node is v26.7.0 where CI pins node 22 (actions/setup-node@v4),
     so even an installed toolchain would not be the one CI runs.
- **The release assembly** — `python3 scripts/build-app.py`, a real
  `scripts/prepare-release.py` run, `make build`'s codesigning. Not run on
  purpose: this mission ships source only (no signing, no publishing, no
  version bump), and the packager's logic is covered where it changed — the
  packaging suite builds synthetic fixture repos through `build-app.py` and
  `prepare-release.py`, pins the `Skills/` layout, and all 62 cases pass.

## What the mission changed

Seven commits, `b056ddd` through `fec6eb7`, on `droid/agent-skill`, tree clean:

- `keys version` and `keys --version` (plus `version --json`),
  `keys status --json`, `keys setup --json` — each with its tests, README
  Commands entry and CHANGELOG entry in the same commit.
- Exit 6 for "no running Keysrs site owns the gateway" — the exit-code table
  in `Support.swift`, `ControlClient`'s connect failures in `Control.swift`,
  and the gateway-not-up paths of `keys tunnel` and `keys relay run`. Stderr
  wording unchanged.
- `Skills/keysrs/SKILL.md` (208 lines) and the packaging chain that ships it:
  `scripts/build-app.py` (`SKILL_FILES`, validation, staging),
  `scripts/prepare-release.py` (`expected_app_files()`),
  `scripts/tests/test_build_app.py` (fixture repo, layout contract),
  `docs/release.md`.
- `docs/agents.md` (270 lines), linked from the README's Coding agents
  section; the README's Commands list and exit-code paragraph updated.
- Five new test files (27 cases). `Web/`, `Relay/` and `Analytics/` untouched;
  grant semantics untouched (only the shared connect-failure plumbing changed);
  the frozen 0.9.x parts lists untouched.

## Why the skill lives in `Skills/`

The skill is `Skills/keysrs/SKILL.md` at the repository root, staged into the
bundle as `Contents/Resources/Skills/keysrs/SKILL.md`. That location was chosen
over the alternatives because it is the only one that actually ships with the
package:

- It rides the existing fail-closed allowlist. `Web/` and `Fixtures/` already
  ship byte-for-byte from repo directories through
  `build-app.py` → `prepare-release.py` → `test_build_app.py`; `Skills/` joined
  that chain, so a missing, renamed or extra file fails the build and the
  tests instead of shipping silently.
- It is byte-for-byte verifiable: the release manifest compares the shipped
  file against the checkout file. Nothing is generated at build time, and no
  symlink is involved.
- It is discoverable in an installed copy, at a path `docs/agents.md` prints,
  without opening the repository.
- The alternatives do not ship: `docs/` does not go into the bundle, and this
  repository uses no SwiftPM resources at all. Adding the directory to the
  frozen 0.9.x parts lists was off the table.

The directory name matches the frontmatter `name`, as the Agent Skills format
requires, and `AgentSkillTests` pins the format in CI: frontmatter name versus
directory, a description present within the format's 1024-character limit, a
body under 500 lines, and no literal token values anywhere in `Skills/`.

## The conservative decisions

These were deliberate; each is reversible later without breaking anything that
shipped.

- **No skill auto-install command.** Not requested, and `keys setup`'s
  semantics stay frozen: it writes agent configs only, never into an agent's
  skills directory, which each framework owns. `docs/agents.md` documents the
  one-line copy per agent instead, from a checkout or from the installed
  bundle.
- **Machine-readable scope = `version`, `status --json`, `setup --json`.**
  Those are the three commands the skill's workflows must consume.
  `keys doctor --json` and `keys client list --json` are real gaps but outside
  "where needed"; they are recorded here as deferred recommendations, not
  silently forgotten.
- **No JSON error mode for `--json` failures.** When a `--json` command fails,
  the contract is the stable stderr line plus the exit code:
  `keys setup droid --key nonesuch --json` prints `not found: nonesuch` on
  stderr and exits 2, with no JSON envelope. An error-JSON mode would be a new
  contract surface; it was deferred rather than half-added.
- **Exit 6 is the one deliberate exit-code change.** Site-down failures moved
  1 → 6 (`keys grant`, `keys grants`, `keys gateway`, the grant path of
  `keys agent`, and the gateway-not-up paths of `keys tunnel` and
  `keys relay run`), with the same stderr wording as before. Every other code
  keeps its meaning, including the pre-existing quirk this mission documented
  rather than changed: `keys test` and `keys models` exit 2 when the provider
  has no check endpoint on the human path, while `keys models --json` exits 5
  for the same condition — the README now states that difference instead of
  implying uniformity.
- **CHANGELOG under `## Unreleased`.** The six user-visible changes landed as
  bold-lead entries under a `## Unreleased` heading at the top of
  `CHANGELOG.md`, the repo's pre-release pattern and the way 0.12.0's entries
  landed. The release commit renames the heading; this mission bumps no
  version and cuts no release.

## Operational notes from the run

- **The final branch name is `droid/agent-skill`.** The session harness renamed
  the worktree's branch mid-mission (once to `droid/add-cli-version-command`);
  the orchestrator renamed it back. All seven mission commits sit on
  `droid/agent-skill` with a clean tree.
- **`Paths.appSupport` is not env-relocatable, which is why `status --json`
  reads this machine's Claude window.** `Paths.appSupport` (`Support.swift`) is
  the user-domain Application Support folder — no environment variable
  redirects it, unlike the catalog (`KEYS_CATALOG`) or `grokHome`
  (`GROK_HOME`). So even under a temp `HOME` and the CI fixture env,
  `keys status --json` on this Mac merges the real
  `~/Library/Application Support/Keysreallysafe/claude-plan.json`, which is
  stale: its windows' `resets_at` are in the past. `isTracked` nulls expired
  windows — a stale percentage must never read as a current figure, the same
  no-fake-numbers rule as the prose — so the Claude entry reports
  `"tracked": false` even with the fixture usage files present. That is the
  intended behavior, reproduced at the final state: exit 0, one line, every
  entry carrying its `tracked` state.
- **The gateway port is hardcoded and the live app holds it.**
  `GatewayListener.port` is `static let port: UInt16 = 12767` in
  `Gateway.swift`, with no env override, and the installed Keysrs.app is
  running on it (it must not be touched). The tunnel and relay exit-6 paths
  therefore could not be exercised against a genuinely down gateway port on
  this machine; milestone validation covered them with `sandbox-exec`
  network-denial plus the in-process `ControlClient` and exit-code-table
  tests, and the spot check above shows the `keys grants` path exiting 6 for
  real.
- **`KEYS_CATALOG` is the catalog database file path, not a directory.**
  `catalogDB` is `env("KEYS_CATALOG") ?? appSupport/catalog.db` in
  `Support.swift`, so the variable names a file; the data directory
  (control.json, the relay lock) is its parent. Pointing it at a directory
  makes `keys status` fail with exit 4 (`open failed` — sqlite cannot open a
  directory as a database). The binary-level recipe is
  `KEYS_CATALOG=<tmp>/catalog.db`.
- **How "human output unchanged" was established.** For `keys status`, by
  source-level comparison — the `--json` branch only adds the JSON printer,
  and the prose path is untouched — plus the pinned human-output assertions in
  `StatusCommandTests`, rather than a pre/post binary byte-diff. The suite at
  the final state is green over both paths.
