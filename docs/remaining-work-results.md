# Remaining local work — results (2026-09-19)

Claude handoff over base `2bbf562`, branch `codex/jev-savings`. At that handoff: nothing was
committed, pushed, signed or installed. No vault or key was read, no presence
prompt was raised, no provider was called, and no client configuration was edited.
The only executables run outside the repository were `keys`, `claude` and `codex`
with `--help` / `--version`.

## 1. Optimizer summary cards (implemented, verified in a browser)

**Defect.** Cards rendered as `Tasks0Recorded task identities` on one line. The
label, value and note are `<span>`/`<strong>` elements and `Web/optimizer.css` gave
them no `display`, so they flowed inline and the value's vertical margins were ignored.

**Fix** (`Web/optimizer.css`, no redesign): the three card children are
`display: block` with explicit line heights; the accounting label is block too;
values get `overflow-wrap: anywhere` so a long figure wraps inside its cell. The
existing 4 → 2 column breakpoints are unchanged.

**Regression test.** `scripts/tests/test_optimizer_layout_ui.cjs` loads the real
`index.html`, `styles.css`, `optimizer.css` and `optimizer.js` in Chromium against a
synthetic fixture and measures boxes at 1280, 820, 390 and 320 px, for a populated
summary and for the reported state (zero tasks, unknown savings). It asserts that
children stack without sharing a line, stay left-aligned inside their card, keep a
2–12 px label/value gap, that cards and accounting cells form 4 or 2 columns without
overlap, that no text box or the page overflows horizontally, and that activity rows
stay inside their list. As a negative control it re-applies inline display and
requires the same measurement to fail. Added to CI beside the workflow UI test.

**Screenshots** (synthetic fixture): `.build/optimizer-ui-screenshots/`, copied to
`…/can-x20/outputs/keys-optimizer-ui-screenshots/` — full-page populated and
card-strip empty images per viewport.

## 2. Live benchmark semantic misses (diagnosed; reporting and one engine gap fixed)

Full diagnosis: [optimizer-benchmarks.md](optimizer-benchmarks.md#what-the-first-live-run-showed). In short:

- Both misses were **safe abstentions after a real evaluator answer**, not errors:
  full catalog kept, current model retained. Re-read with the new classifier the
  live report is structural 3/3, semantic 0/2 with 2 safe abstentions, **0 unsafe errors**
  (`…/outputs/keys-live-mcp-benchmark-reclassified.json`).
- **Threshold:** Keys evaluates live at 0.9; the offline fixture ran at 0.75 with a
  0.98 mock and could not expose this. The fixture now uses 0.9. The product
  threshold and all confidence rules are unchanged; nothing was tuned to pass.
- **Input:** the terse case is a three-word request against a description repeating
  it. The activation request that did select `Read` was fuller. One observation each.
- **Expectation:** `model_semantic`'s label comes from cost arithmetic over invented
  models; an evaluator cannot verify it, so retaining the current model is the
  designed result. The label is reachable only with the mock.
- **Protocol:** no request/response defect found. Usage, caching and the exact-repeat
  path behaved as designed (repeat: 0 requests, 1 cache hit).
- **Engine gap (fixed):** results never said which score fell short. Ranked results
  now carry `decision_evidence` — threshold, `none_fit`, per-candidate
  `suitable`/`conflict`, and an outcome — numbers and caller ids only
  (`Plugins/jev-optimizer/src/optimizer.ts`). Selection logic is unchanged.
- **Reporting (schema 4):** per-result `category`, `outcome`
  (`match`/`safe_abstention`/`safe_mismatch`/`unsafe_error`), `abstention_cause`, numeric
  `decision_evidence`; summary buckets for structural vs semantic plus `unsafe_errors`.
  `accuracy`/`correct` and all schema 3 fields are retained; `--reclassify REPORT`
  upgrades an old report without running anything.
- **Opt-in `--suite realistic`:** one client-like tool-selection case with an
  include/exclude label. Offline only so far.

Noted, not changed: the evaluator state labels the client's *available* tools
`required_tools`. It was empty in the live run, so it did not cause these results,
and changing text sent to a paid evaluator without a live check was out of scope.

## 3. Paired savings evaluation (implemented, mock-tested)

`scripts/paired-savings-eval.py` (`plan` / `collect` / `report`) and
[optimizer-paired-evaluation.md](optimizer-paired-evaluation.md). Same task, context
and model in both arms; quality gate before any saving; net of optimizer overhead,
cache rebuild and fallback; provider tokens beside byte estimates, never mixed;
unknown cost stays unknown; cache replays reported apart from general tasks;
`measured_savings_claim` is `null` until a pair is comparable, quality-held,
non-replay and fully known. `collect` reads per-task accounting from a saved
`keys_optimizer_status` result and treats any total with unknown events as unknown.

The infrastructure cannot run a fair live baseline by itself (no client or paid
model is launched), so `plan` is a dry-run run sheet that lists what is unavailable.
**No savings figure exists yet**; none is claimed.

## 4. Client setup (implemented, verified against local CLIs)

`scripts/optimizer-client-setup.py` and [optimizer-client-setup.md](optimizer-client-setup.md):
per-session commands for Claude Code (`--mcp-config`, optionally through
`claude-with-jev.py`) and Codex (`-c mcp_servers.…` overrides, `--cd`) for
`/Users/Shost2/keys-jev-savings` with key name `jev-ass` and a `PROJECT_UUID`
placeholder. `--check` verified every option against Claude Code 2.1.276,
codex-cli 0.154.0 and the installed `keys` via `--help` only. The helper refuses to
write into `~/.claude` or `~/.codex` and never overwrites a file; `.keys/` is git-ignored.

## 5. Analytics

Unchanged. `ProductAnalyticsConfiguration.endpoint` is still `nil`, analytics stay
disabled, the collector deployment files and `LICENSE` (MIT) are untouched, and no
endpoint was invented. Strict preflight still lists `collector_hosting` as pending.

## Test evidence

| Check | Command | Result |
| --- | --- | --- |
| Plugin typecheck, tests, build | `npm run typecheck && npm test && npm run build` in `Plugins/jev-optimizer` | passed, 161 tests |
| Script tests (benchmark, paired, client setup, MCP, launcher, preflight, release) | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | passed, 81 tests |
| Layout geometry, real styles, 4 viewports | `NODE_PATH=Plugins/jev-optimizer/node_modules node scripts/tests/test_optimizer_layout_ui.cjs` | passed |
| Existing workflow UI | `… node scripts/tests/test_optimizer_workflow_ui.cjs` | passed |
| Offline benchmark, all suites | `python3 scripts/benchmark-optimizer.py --suite all --max-calls 6` | 6/6 match, 0 unsafe (mock evaluator) |
| Live report re-read | `python3 scripts/benchmark-optimizer.py --reclassify …/keys-live-mcp-benchmark.json` | 3 match, 2 safe abstentions, 0 unsafe |
| Client setup check | `python3 scripts/optimizer-client-setup.py --jev-key jev-ass --check` | all pass except placeholder UUID (exit 3, expected) |
| Release preflight | `python3 scripts/optimizer-preflight.py --root . --strict` | no blockers |

Not run: `swift test` (no Swift source changed) and the analytics UI test (untouched).

## Needs the user's configuration or approval

- The real Optimizer **project UUID** for `/Users/Shost2/keys-jev-savings`, then
  `optimizer-client-setup.py --project UUID --jev-key jev-ass --check --write-example .keys`.
- **Rebuild and install Keys** before live reports contain `decision_evidence`; the
  installed app still bundles the previous engine.
- A deliberate **live run** of `--suite realistic` (one provider request, presence
  approval, project request budget) to test the input hypothesis.
- **Paired runs** of real tasks in both arms, with usage recorded per task.
- Analytics hosting and direct TypeSafe: server, domain and key.

## Limitations

- No claim of routing accuracy or savings is made anywhere. The live evidence is
  five calls; the activation evidence is one request and one repeat.
- `decision_evidence` and the realistic suite are verified with mock evaluators only.
- The safe/unsafe classification compares against each fixture's known default;
  unknown case ids are reported as unsafe rather than guessed.
- The layout test covers the Overview tab in the light theme; other tabs are covered
  only by the no-horizontal-overflow check while Overview is shown.
- The client commands were checked for option support, not exercised in a live session.
- New scripts are developer tools and are not added to the offline release bundle.

## Integration follow-up

The integration owner corrected three additional issues: paired measurements require
the same nonempty, unique quality-check names; oversized numbers and missing/bool
event counters remain unknown instead of crashing or becoming zero; and the client
setup helper accepts `--provider typesafe` and forwards it to the compaction launcher.
Three additional regressions cover these cases.

The user selected Claude Code and stored a direct TypeSafe key named `codex-jev`.
Live TypeSafe selection and exact-repeat caching passed. A real Keys project was
created and a project-local Claude MCP connection was added using the supported CLI;
`claude mcp get` reported Connected. The real Claude launcher loaded the plugin with
a temporary TypeSafe grant. Actual compaction remains unverified: headless tests
produced no callback evidence, and the tool-controlled terminal selected print mode.
No confidence threshold was relaxed. Analytics hosting was explicitly deferred.

One live exact repeat avoided 695 provider tokens. This is a cache-replay observation,
not a general-task savings rate. A fair baseline/treatment run of a real coding task
is still outstanding. Final installation and numeric evidence are recorded separately
in the user-facing outputs directory.
