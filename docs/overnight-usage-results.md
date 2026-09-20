# Overnight usage tracking — results, 20 September 2026

Phase 1 of the authorized overnight run. Everything here is local arithmetic over
JSONL logs already on this Mac. No provider request, client launch, installation,
native authorization prompt or upload took place, and no secret value was read.

## What was added

| Path | Purpose |
|---|---|
| `scripts/claude-usage-collect.py` | Ingests Claude Code JSONL logs; reports per-session and per-model usage, compaction evidence, fallback status and tool-call repeats; `check` fails on a quality gate |
| `scripts/tests/test_claude_usage_collect.py` | 48 fixture tests: duplicates and replays, resumed counter epochs and unidentifiable boundaries, cumulative multi-turn results, unfinished and newly opened segments, work recorded after a result, permission denials, interrupted and malformed logs, gates, privacy |
| `scripts/tests/test_jev_hook_modules.py` | 5 offline guards that a hook module named in `hooks.json` exists and is not truncated |

`scripts/paired-savings-eval.py` was read first and is unchanged. The two tools do
different jobs and the collector defers to it: the collector reports what a log
says was consumed; the paired evaluator is the only place a *saving* is computed,
and it still requires matching task, context and model fingerprints, equal passing
checks, and stated Jev overhead, cache-rebuild and fallback numbers. The collector
never emits a savings figure.

CI needs no change: `.github/workflows/test.yml` already runs
`python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, which picks up both
new test files.

## The schema, as the logs actually are

Nine properties of the real event stream make a naive sum wrong. Each is
evidenced, and each is handled. Properties 5 to 7 are corrections made after an
independent review reproduced three accounting defects the first thirty tests
missed; `outputs/accounting-correction-handoff.md` in the run directory records
the reproductions and the regressions that now pin them. Properties 8 and 9 are a
second round of corrections, after a further review found two related cases that
the first round still reported as finished and verified;
`outputs/accounting-second-correction-handoff.md` records those.

1. **One assistant turn is written once per content block.** Every copy carries the
   same `message.usage`. Across the nine can-x20 logs, 776 assistant records are
   320 API requests: a naive sum inflates usage 2.42×. Deduplicated on
   `(request_id | requestId, message.id)`.
2. **`result.usage` is incremental; `result.modelUsage` and `total_cost_usd` are
   cumulative.** In `jev-events.jsonl` one session emitted four results whose
   `modelUsage.outputTokens` ran 762 → 870 → 870 → 1,170 while `usage.output_tokens`
   ran 762 → 108 → 0 → 300. Summing `modelUsage` reports 3,672 instead of 1,170.
   The collector takes the final cumulative value and shows the naive sum only as
   `naive_sum_of_cumulative_model_usage_avoided`.
3. **`result.usage` covers the main model only.** Seven of the nine sessions ran
   `claude-haiku-4-5-20251001` in the background for 1,230–2,073 input tokens, all
   of it absent from every `usage` increment. Reported as
   `background_model_tokens_absent_from_result_usage`.
4. **In stream-json transcripts `usage.output_tokens` is the message-start value.**
   Session `3fa64b97` this run: 452 output tokens in the stream log against 45,643
   in its own session transcript, with input and cache counts equal. When both
   shapes are supplied the collector deduplicates per request and keeps the larger
   report, counting each as `conflicting_duplicate_usage`.
5. **A resumed session reuses its session id and writes a second `init`.** This
   run's log now carries four `system/init` records for `3fa64b97`. Cumulative
   counters run per counter epoch, so the collector splits the session into
   segments at each init and groups results into epochs, each contributing its own
   final cumulative value once (`processes`, `client_processes`). The boundary is
   `result_index` restarting at zero, not the totals falling: a restarted counter
   that counts higher than the interrupted one is still a second counter. An init
   that arrives twice, because a stream log and a session transcript are read
   together, is recognised by its uuid and does not open a second segment. The
   epochs are **inferred from the records, not observed processes**: a resumed
   native session that carried its counters on — which is what this run did, its
   `result_index` running 0 → 1 → 2 across four inits — is one epoch and is
   counted once.
6. **A `result` ends its segment, not the session, and a success ends nothing.**
   Completeness is read from the recorded order of events, in three shapes the
   collector now separates: a success followed by a new `init` and further
   assistant work (`state: incomplete_unfinished_segment`); a success followed by
   further requests in the same segment, with no new init
   (`incomplete_work_after_last_result`); and a success followed by a new `init`
   alone, a segment opened with nothing recorded in it yet, which is listed as an
   unfinished segment rather than omitted (`incomplete_unfinished_segment`, with
   `segments_opened_without_recorded_work`). In each case the open work is kept as
   `usage_after_last_result` instead of being discarded and the completeness gate
   fails.
7. **A refused tool call is reported twice, and once may be missing.** Live
   `system/permission_denied` events carry `tool_name`, `tool_use_id` and
   `decision_reason_type`; a later `result` lists the same denial again in
   `permission_denials`. A run interrupted before its result has the events and no
   list at all. Both are read and matched on `tool_use_id`.
8. **An epoch boundary is not always identifiable.** When neither result across a
   boundary carries a `result_index`, a fall in the counters still identifies a
   restart — a cumulative counter never falls inside one epoch — but counters that
   rise are indistinguishable from one continuing epoch. The log then admits two
   totals, and the collector publishes neither as the total: `cost.list_price_
   estimate_usd` is `null`, `cost_total_is_identified` is `false`, both readings
   are given as `..._if_counters_continued` and
   `..._if_ambiguous_boundaries_are_restarts`, the token basis is named
   `final_cumulative_model_usage_lower_bound`, and the new
   `accounting_totals_are_identified` gate **fails**. Counting such a boundary as a
   restart anyway would charge a resumed native session twice; reporting the
   continuation reading as the total was how $0.50 followed by a fresh $1.00 could
   still be reported as $1.00.
9. **Partial and unidentified are different statements.** `state` says whether the
   run finished; `accounting_state` says whether its totals can be identified.
   `totals_are_partial` is true for either, and `partial_because` names which. A
   session can be `complete` with `ambiguous_counter_epoch_boundaries`, and the
   markdown's "Limits on these totals" section names every such session and every
   open segment, including one with no request recorded in it yet.

Beyond those, `result.usage` also excludes work the client does outside a turn. The
residual is reported as `out_of_turn_main_model_tokens` and is **not attributed**
by the tool; section "Jev compaction" shows what it was in one measured case.

## Exact commands and results

All run from `/Users/Shost2/keys-overnight-20260920`, every command prefixed `rtk`.

```sh
python3 -m unittest discover -s scripts/tests -p 'test_claude_usage_collect.py'
# Ran 48 tests ... OK

python3 -m unittest discover -s scripts/tests -p 'test_jev_hook_modules.py'
# Ran 5 tests ... OK

python3 -m unittest discover -s scripts/tests -p 'test_*.py'
# Ran 137 tests ... OK
# The six test_optimizer_benchmark failures seen earlier were an unbuilt
# checkout, not a product defect: they need Plugins/jev-optimizer/dist, which
# the owner then built locally with npm ci --ignore-scripts && npm run build.
```

Collection over the nine can-x20 Claude logs of 19 September:

```sh
python3 scripts/claude-usage-collect.py report \
  ~/Documents/Codex/2026-09-19/can-x20/work/claude-review-20260919/events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/claude-review-20260919/completion-events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/claude-implementation/medium-events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/claude-remaining/events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/live-compaction/events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/live-compaction/instrumented-events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/jev-calibration/claude-pair/baseline-events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/jev-calibration/claude-pair/jev-events.jsonl \
  ~/Documents/Codex/2026-09-19/can-x20/work/live-activation/claude-smoke.jsonl \
  --out work/canx20-usage.json
```

9 sessions, all complete, one counter epoch each, all five gates passing. 3,182
records, 0 unparsable. 320 API requests, 456 duplicate content-block records
ignored. 14,360 input, 320,338 output, 52,298,306 cache read, 1,372,031 cache
creation, 489 turns, $56.56611 list-price estimate, billed dollars unknown. 476
tool calls, **0 exact repeats** — see the limitation on what that does and does
not mean.

Every one of those figures is unchanged by the accounting corrections, both
rounds, which is the point: the corrections alter only sessions that were
resumed, interrupted after a result, or refused a tool call outside a completed
result. The second round was re-checked the same way — `work/canx20-usage-second-
correction.json` reproduces every total, every per-session cost and every segment
state of the preserved `work/canx20-usage.json`, with the added accounting fields
reading `identified` throughout. These nine sessions each ran as one
uninterrupted counter epoch, and their 8 refused tool
calls appear both as `system/permission_denied` events and in the matching result
lists, so the count is 8 before and after — the two views agree and are matched
on `tool_use_id` rather than added.

This run, both log shapes of the same session:

```sh
python3 scripts/claude-usage-collect.py report \
  ~/Documents/Codex/2026-09-20/overnight-keys/work/claude-events.jsonl \
  ~/.claude/projects/-Users-Shost2-keys-overnight-20260920/3fa64b97-*.jsonl \
  --out work/thisrun-usage.json
```

Re-run after the accounting corrections, against a log that has since grown three
`result` events. One session, one counter epoch, four segments, 302 API requests
from 1,029 assistant records (727 duplicate content-block records ignored, 301
conflicting duplicates resolved in favour of the session transcript), 241 turns,
no compaction event:

| Segment | State | Requests | Input | Output | Cache read | Cache creation |
|---:|---|---:|---:|---:|---:|---:|
| 1 | unfinished | 76 | 152 | 67,923 | 6,336,801 | 137,818 |
| 2 | complete | 45 | 90 | 33,376 | 7,298,552 | 45,601 |
| 3 | complete | 111 | 222 | 73,067 | 28,729,652 | 122,822 |
| 4 | work_after_result | 70 | 138 | 34,809 | 23,995,888 | 72,961 |

Segment 4's state is the second round's correction on real data, and the earlier
reading is preserved in `work/thisrun-usage.json`: that report called this session
`complete` with `totals_are_partial: false` and all four gates passing, while its
own `api_requests_after_last_result` was 1. One request was recorded after the
last result, in the same segment and with no new init, and a segment holding a
success was read as a finished session. The session now reads
`state: incomplete_work_after_last_result` and the completeness gate fails,
naming that request. The usage it carries is 0 in every field — the material
error was the status and the passing gate, not a hidden token count.

The one counter epoch reports 602 input, 209,175 output, 66,360,893 cache read,
379,202 cache creation and a **$42.20485 list-price estimate**; billed dollars
unknown. Those are the process's own final cumulative counters, taken once. The
per-turn increments beside them sum to 450 / 141,252 / 60,024,092 / 241,384 — a
different and equally correct view of the same run, not a second total to add.

The gap between the two, `out_of_turn_main_model_tokens`, is 152 / 67,923 /
6,336,801 / 137,818: exactly segment 1. That segment was interrupted before it
emitted a result, so its work is inside the process's cumulative counters and
outside every per-turn increment. It is a worked example of why the residual is
reported and never attributed to compaction.

Five `system/permission_denied` events, all `Bash`, all `decision_reason_type:
mode`; one of them is also listed by a later result. Distinct denials: 5.

`report` always exits 0; `check` exits 3 when a gate fails, which is the form
intended for future runs:

```sh
python3 scripts/claude-usage-collect.py check work/some-run.jsonl --format markdown
```

The full analysis, including the structural patterns, is in the run directory at
`outputs/usage-analysis.md`.

## Privacy of the collector

The report contains identifiers, enum labels, counts and numbers only. Tool
**names** are kept; tool inputs are hashed in memory to count exact repeats and are
never stored or printed. Prompt text, message text, tool results, `result.result`
and system status text never reach the output; the one string the collector looks
for is the fixed marker `fallback to built-in summary`, and only its presence is
recorded. `test_no_prompt_or_tool_content_reaches_the_output` puts a canary string
into every content-bearing field of a fixture and asserts it is absent from both
the JSON and the markdown rendering.

## Why the headless Jev test never triggered a hook callback

**Root cause: the synthetic driver module was truncated, so it could not be
imported and its `register` never ran.**

The 19 September headless check at
`~/Documents/Codex/2026-09-19/can-x20/work/live-compaction/` loaded a scratch
plugin, `keys-synthetic-compaction-check`, whose single module
`driver/hooks/driver.ts` registers `turn.complete`, calls `$.session.compact()` and
writes `hook-evidence.json`. That run produced no `hook-evidence.json`, no
`KEYS_SYNTHETIC_COMPACT_*` log line, and no `system/compact_boundary` event.

The file is 789 bytes and ends at `});` closing the `on(...)` call. The arrow
function body opened on line 1 is never closed: 6 opening braces, 5 closing. A
byte-identical copy was placed in this worktree at
`work/jev-hook-check/driver-as-found.mjs` and checked with the installed runtime:

```sh
node --check work/jev-hook-check/driver-as-found.mjs
# SyntaxError: Unexpected end of input   (exit 1, node v26.7.0)
```

The consequence that matters operationally: the client's `system/init` event for
that run **still lists the plugin as loaded** (`keys-synthetic-compaction-check@inline`),
and no error appears anywhere in the stream. A plugin reported as loaded is not
evidence that any hook is registered.

Two things follow, and neither is a defect in this repository's code. The
truncated file is a prior run's scratch artifact outside the repo; it was read
only, and was not modified. The Jev plugin's own hook module
`Plugins/jev-optimizer/hooks/vercel-compaction.ts` is intact, registers
`session.compact` and `turn.complete` at lines 346 and 399, and is imported by
`Plugins/jev-optimizer/tests/hook.test.ts`, so a syntax error there already fails
the CI vitest run.

The gap worth closing was the silence. `scripts/tests/test_jev_hook_modules.py`
now asserts that every module named in `Plugins/jev-optimizer/hooks/hooks.json`
exists, stays inside the plugin, closes its delimiters and registers a known
event; its truncation check is cross-validated against `node --check` on the exact
failing shape, and skips when node is absent.

What could not be done: no live headless hook run was performed for this
investigation, because that would be a new client launch and provider calls. The
finding rests on the log record, the file on disk and the offline syntax check.

## Is Jev-applied compaction verified, or only loaded?

**Verified for one specific prior run; not verified in general; not applied in
this session.** Three distinct states appear in the evidence.

1. **Applied and verified — 19 September calibration pair.** The Jev arm
   (`36419a9f`) and the baseline arm (`523cc377`) each compacted once, both
   `trigger: "manual"`, from almost the same context size.

   | | Jev arm | Baseline arm |
   |---|---:|---:|
   | Context before → after | 19,213 → 2,333 | 19,202 → 8,838 |
   | Compaction duration | 524 ms | 21,394 ms |
   | Out-of-turn main-model tokens | 0 / 0 / 0 | 2,128 in / 2,193 out / 19,060 cache read |

   The host says so directly, in
   `~/Documents/Codex/2026-09-19/can-x20/work/jev-calibration/claude-pair/jev-debug.log`:

   ```
   251  [keys-jev-optimizer] $.ui.log: kept 11/21 messages, no summary (81% character
        reduction; ... Jev reported input=2252, output=220 tokens (complete))
   254  keys-jev-optimizer (user) answered session.compact without next() in 515.3ms;
        nothing beneath it ran for this dispatch
   256  session.compact (manual): a hook's 11 messages stand (hooked by
        keys-jev-optimizer); core never ran
   ```

   That is the evidence the claim rests on. The out-of-turn residual between
   cumulative `modelUsage` and the sum of per-turn `usage` increments — zero in the
   Jev arm, a whole summarizer request in the baseline arm — and the forty-fold
   difference in boundary duration agree with it, but neither would prove it
   alone: a zero residual and a short duration are consistent with other causes.

   This is a **different pair** from `work/jev-paired-compaction`, whose own
   `jev-debug.log:252` records `fallback to built-in summary (below 25% minimum:
   0% character reduction)`. Nothing here is transferable to that one.

   Applied is not beneficial. `keys-jev-calibration-results.md` records that the
   same pair failed its quality checks: the Jev arm falsely denied having read
   files whose tool-call records were removed, and missed the JSON-only output
   requirement. No savings claim follows.

2. **Loaded, executed, fell back — interactive session of 2026-09-20T06:21.** The
   plugin ran, reported 3,813 input and 256 output Jev tokens, achieved 0%
   character reduction against a 25% minimum, and delegated to the built-in
   summary. Overhead spent, no pruning applied.

3. **Loaded, idle — this session.** `keys-jev-optimizer` is loaded in both
   segments of `3fa64b97`. There is no `compact_boundary` record in this session
   from either the host or Jev, because the context never required compaction.
   None was forced: forcing one would spend Jev calls and Claude tokens to
   manufacture evidence rather than measure it.

A scoped TypeSafe grant (10 hours, 60 calls) is now attached, and
`work/worker-status.json` shows `jev_scoped_grant_available: true`. It changes
nothing above: it makes a future live compaction possible, it does not make the
past one general, and `jev_compaction_verified` should stay `false` for this run
unless and until a compaction actually occurs here and is measured the same way.

## Limitations

- **No live provider measurement was made by this phase.** Every number is read
  from logs written by earlier runs or by this run's own client.
- **This run's own totals are still partial.** Three `result` events have been
  emitted, so the earlier "no result event, cost unknown" reading is superseded by
  the table above, but the session has recorded a request since its last result
  and is therefore reported open, with `totals_are_partial: true`. The earlier
  claim that these totals were "no longer partial" was itself a product of the
  defect corrected in the second round and is withdrawn. A later reading may
  supersede this one in turn: the run is still in progress, and the collector
  reports the log it is given, not the run.
- **The resumed-counter arithmetic has no real-data instance here.** Defect 2 is
  fixed and pinned by regressions, but every local log available — the nine
  can-x20 sessions and this run's — contains exactly one counter epoch, so the
  summing of two independent cumulative counters is verified against fixtures
  only. `client_processes: 1` everywhere is a fact about the sample, not a
  demonstration that the fix works on real data.
- **A "process" in this report is an inferred counter epoch, not an observed
  operating system process.** It is a span over which `modelUsage` and
  `total_cost_usd` accumulate and results are numbered from zero, inferred from
  `result_index` and the counters themselves. Nothing here observes a client
  process starting or ending. This run is the case that matters: it was resumed
  and its counters carried on, so it is one epoch and is charged once.
- **Unidentifiable epoch boundaries have no real-data instance either.** Every
  `result` in every local log carries a `result_index`, so
  `ambiguous_process_boundaries` is 0 throughout and the new
  `accounting_totals_are_identified` gate has only ever been observed passing on
  real data. The unknown-total path is verified against fixtures alone.
- **The six `test_optimizer_benchmark.py` failures were an unbuilt checkout, not a
  product defect.** The owner ran `npm ci --ignore-scripts` and `npm run build` in
  `Plugins/jev-optimizer` — authorized as routine local verification, not an
  installation of the app — and all 16 tests then passed. The earlier reading of
  these as "pre-existing failures" was wrong and is withdrawn.
- **Hook-event records were never observed.** The runner passes
  `--include-hook-events`, but no log available here contains a function-hook
  event, so the collector's `hook_records` and `hook_errors` counters are written
  against the `stop_hook_summary` shape found in session transcripts and are
  untested against live function-hook events.
- **Zero exact repeats means no byte-identical tool call was observed twice
  within a session in this sample.** It covers nine prior sessions and one
  partial session of one project. It is not evidence that no redundant work
  occurred: semantically equivalent calls, near-duplicate inputs, repeats across
  sessions and re-derived reasoning are all outside what the digest matches. No
  saving, potential or realised, follows from it.
- **List price is not money.** Subscription billing means no figure here is a cash
  charge, and the collector reports `billed_dollars: null` everywhere.
- The `<synthetic>` entry in this session's `models_observed` comes from a
  synthetic record in the session transcript and is reported as found rather than
  filtered.
