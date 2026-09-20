# Overnight checkpoint — 20 September 2026

Durable state for the authorized overnight run, written so work survives a
compaction or a session restart. Plan:
`/Users/Shost2/Documents/Codex/2026-09-20/overnight-keys/PLAN.md`.
Worktree: `/Users/Shost2/keys-overnight-20260920`, branch
`codex/overnight-20260920`, base `eb2bac2`.

## Standing constraints

- Prefix every shell command with `rtk`. Work only in this worktree and the
  overnight run directory; prior artifacts and `/Users/Shost2/keys-jev-savings`
  are read-only.
- Do not commit, push, deploy, install, or request native authorization. Do not
  read or print secret values. Do not delegate.
- Preserve the inherited uncommitted changes: `Web/optimizer.js` and
  `scripts/tests/test_optimizer_workflow_ui.cjs`. Neither has been touched; their
  diff still hashes to `b32c4904…`, matching `work/inherited-changes.patch` and
  `run.json`. Overnight edits to tracked files are `Web/app.js` and
  `.github/workflows/test.yml` only, and are listed in the phase sections below.
- The owner records this run's provider usage separately. Do not duplicate usage
  or trial logging.
- Deadline 08:00 America/Los_Angeles, 20 September.

## Phase 1 — usage tracking: COMPLETE

Added, all new files, nothing existing rewritten:

- `scripts/claude-usage-collect.py` — ingests Claude Code JSONL (stream-json
  transcripts and `~/.claude/projects` session transcripts); per-session and
  per-model input / output / cache-read / cache-creation counts, compaction
  evidence, fallback status, tool-call repeats, quality gates. `report` exits 0;
  `check` exits 3 on a failed gate.
- `scripts/tests/test_claude_usage_collect.py` — 30 fixture tests.
- `scripts/tests/test_jev_hook_modules.py` — 5 offline hook-module guards.
- `work/canx20-usage.json`, `work/thisrun-usage.json` — generated reports.
- `work/jev-hook-check/driver-as-found.mjs` — copy of the prior truncated driver,
  kept as the evidence for the `node --check` result.

Evidence written:

- `docs/overnight-usage-results.md` — commands, results, root-cause analysis,
  limitations.
- `/Users/Shost2/Documents/Codex/2026-09-20/overnight-keys/outputs/usage-analysis.md`
  — actual counts and structural patterns.

Results to carry forward:

- Five counting hazards confirmed in the real schema: per-content-block duplicate
  assistant records (2.42× inflation); `result.usage` incremental vs `modelUsage`
  and `total_cost_usd` cumulative; `result.usage` main-model only; stream-json
  `output_tokens` is a message-start value while the session transcript is final;
  a resumed session reuses its session id and writes a second `init`.
- can-x20, 9 sessions: 320 requests, 14,360 input, 320,338 output, 52,298,306
  cache read, 1,372,031 cache creation, $56.57 list-price estimate, billed dollars
  unknown. 476 tool calls, **0 exact repeats**. 97.42% of processed input is cache
  reads.
- This session `3fa64b97`: segment 1 (interrupted) 76 requests, segment 2
  (resumed) 33 requests, no result event yet, totals partial, cost unknown.
- Headless Jev hook failure root cause: the 19 September scratch driver
  `live-compaction/driver/hooks/driver.ts` is truncated (unbalanced braces,
  `SyntaxError: Unexpected end of input`), so `register` never ran. The plugin was
  still listed as loaded in `system/init`. Not a defect in this repository; the
  repo's own hook module is intact and already import-tested.
- Jev-applied compaction: **verified** for the 19 September calibration pair
  (Jev arm 524 ms and 0 out-of-turn tokens vs baseline 21,394 ms and 2,128 in /
  2,193 out / 19,060 cache read), but that pair **failed its quality checks**.
  Fell back to the built-in summary in the 2026-09-20T06:21 interactive session.
  **No compaction has occurred in this session**, and none was forced.
- A scoped TypeSafe grant (10 h, 60 calls) is now attached;
  `work/worker-status.json` shows `jev_scoped_grant_available: true`.
  `jev_compaction_verified` should stay `false` for this run unless a compaction
  actually occurs here and is measured the same way.

Limitation recorded in phase 1 and since **resolved**: six
`test_optimizer_benchmark.BenchmarkTests` failures needed
`Plugins/jev-optimizer/dist`, absent at 00:37 and present at 00:43. This session
ran no build or install; the directory is gitignored. The Python suite now passes
119 of 119.

## Phase 2 — reliability: COMPLETE

Added `scripts/tests/test_keys_dashboard_ui.cjs`: 24 browser cases plus six
screenshots, covering the Keys pane, which had no browser coverage at all. Real
`index.html`/`styles.css`/`app.js` in Chromium against a synthetic in-memory
fixture; `page.clock` drives the reveal countdown, the deferred refresh after a
copy and the status poll. Fixture secrets are the invented literal
`sk-fixture-NEVER-REAL-0000000000`.

Three product defects reproduced as failing cases, then fixed in `Web/app.js`
(29 insertions, 5 deletions):

1. `loadKeys` had no sequence guard, so a slow reply resurrected a deleted key
   and dropped a newly added one. Fixed with `keysSeq`, mirroring `spendSeq`.
2. The engine-down banner outlived the outage: `setEngineDown(false)` cleared
   only one of the two notices a failed fetch can post.
3. A failed chart load stayed on screen after the chart loaded.

2 and 3 share one fix: `sayError` records the exact sticky text and `clearError`
removes it only if that text is still displayed. Used by `loadKeys`, `loadSpend`
and `setEngineDown`.

Two suspected defects were disproved by measurement and are recorded as such: the
blank mobile screenshot was the pane's 160 ms fade caught mid-flight (harness
fixed with `animations: "disabled"`), and `dlg-rotate` does clear its secret on
close (`app.js:1504`).

CI: one line added to the existing browser step in `.github/workflows/test.yml`.
No new action or dependency.

Evidence: `docs/overnight-reliability-results.md`; screenshots in
`outputs/keys-dashboard-screenshots/` of the run directory.

Run the suite locally with:

```sh
rtk env NODE_PATH=/Users/Shost2/keys-jev-savings/Plugins/jev-optimizer/node_modules \
  node scripts/tests/test_keys_dashboard_ui.cjs
```

This worktree has no `Plugins/jev-optimizer/node_modules`; the source checkout's
Playwright 1.62.1 and pinned Chromium are reused read-only through `NODE_PATH`.
`KEYS_UI_ONLY=<substring>` runs a single case. Do not edit the source checkout.

Largest remaining Keys-pane gaps, in order: grants and long-lived clients, the
gateway toggle and host dialog, provider check, key history, export and ingest.

## Phase 3 — privacy: COMPLETE

Bounded read-only audit of the six named areas against the commitments in
`README.md` and `docs/optimizer-library.md`, with the 19 September review read
first to avoid re-reporting known findings.

**One defect confirmed and fixed.** `OptimizerStore.eventRecord` deduplicated the
`event_id` idempotency key on project alone, so the same id under a different task
in one project silently folded the second task's usage into the first and returned
that other task's event. The documented contract is that repeated identities
deduplicate "only within compatible task/model identities". This is the accounting
path a paired baseline/treatment measurement depends on, so a client deriving
event ids deterministically could manufacture a saving from a bookkeeping
accident. Fixed in 6 lines: idempotency is scoped to the task and a cross-task
reuse is refused with `.conflict` → 409 `optimizer_changed`. Refusal was chosen
over recording a second event because recording would double count a retry sent
with a wrong `task_id`.

Regression tests in `Tests/KeysreallysafeTests/OptimizerStoreTests.swift`:
`testEventIdReusedUnderADifferentTaskIsRefusedNotSilentlyFolded` (written first,
failed against the unfixed code) and
`testEventIdRepeatedUnderTheSameTaskStaysIdempotent` (pins the retry behaviour the
fix must not break).

**Five areas verified with no change:** grant scope and exact paths (ordered
fail-closed denials, constant-time token compare, Jev exact-path binding, upstream
path bytes never decoded before matching); revocation (every documented trigger
reaches `revokeGrants`; a grant without a gateway cache entry is inert via
`lookupGateway`; no token is ever persisted); request-body privacy (only `model`
is read from a gateway request body, engine stderr goes to `nullDevice`, upstream
error bodies never surface); optimizer authorization (re-verified at all four
checkpoints, already covered by the prior review); logging (every `stderr` write
in `KeysCore` read — names, actions and errors only, no secret, token or body).

**Two defects reported, deliberately not fixed:** the gateway `model` field is
copied from the request body with no length bound, and a gateway 401 emits two
conflicting `WWW-Authenticate` realms (`Gateway.swift:387,389`). Neither is a
privacy breach; both touch more code than the evidence justified.

Checked and cleared, not a finding: a path list that normalizes away entirely
yields an unrestricted grant, but both the CLI (`paths any`) and the dashboard
(`any path`) disclose the effective scope.

Evidence: `docs/overnight-privacy-results.md`; handoff in
`outputs/coding-handoff.md` of the run directory.

## Final state of the run

Product changes across all three phases total 39 lines in three files:
`Web/app.js` (+28 −5), `Sources/KeysCore/OptimizerStore.swift` (+6),
`.github/workflows/test.yml` (+1). Everything else added is tests, tools or
evidence. Inherited changes verified byte-identical throughout.

| Suite | Result |
|---|---|
| `swift test` (fixture env) | 282 tests, 0 failures, 2 skipped by design |
| `python3 -m unittest discover -s scripts/tests` | 119 tests, OK |
| `python3 -m unittest Analytics/test_*.py` | 18 tests, OK |
| `node scripts/tests/test_keys_dashboard_ui.cjs` | 24 cases, passed |
| three pre-existing browser suites | passed |
| `optimizer-preflight.py --root . --strict` | `blockers: []`, no live auth, no secrets examined |
| `git diff --check` | clean |

Open risks are listed in `outputs/coding-handoff.md`. The largest: any paired
savings number produced before tonight's deduplication fix could have folded one
arm's usage into the other's task and deserves a re-check against the raw ledger.
