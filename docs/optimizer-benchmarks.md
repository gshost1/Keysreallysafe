# Optimizer benchmark

`scripts/benchmark-optimizer.py` is a bounded evaluation harness for the Optimizer. Its default mode executes the repository's compiled TypeScript `OptimizerEngine` with a deterministic mock Jev asker. It opens no sockets, launches no Keys process, reads no provider secret, and requests no user presence.

The offline result is a structural check of production engine logic. It validates semantic selection, recognized dependency and expiry rejection, exact duplicate assessment, model routing with complete cost/capability inputs, repetition/call limits, and report generation. Transport framing is tested separately with bounded fake stdio peers. This is not evidence of general model quality, production savings, human quality, or safe unattended automation.

The harness imports the compiled engine from `Plugins/jev-optimizer/dist`, a build product that is not committed. On a fresh checkout, build it once first (this installs development dependencies from the npm registry; the benchmark itself stays offline). Without it the benchmark exits with status 2 and prints this same instruction instead of a Node module error.

Run the offline benchmark and its tests:

```sh
(cd Plugins/jev-optimizer && npm ci && npm run build)
python3 scripts/benchmark-optimizer.py
python3 -m unittest scripts/tests/test_optimizer_benchmark.py
```

Use `--repetitions` and `--max-calls` to bound the corpus. The hard limits are 20 repetitions and 100 Optimizer calls. Repetitions run in order through the same engine instance, so exact repeats exercise its decision cache. The default is one five-case pass. `--report PATH` writes the same JSON printed to stdout. Exported results include benchmark metadata, case IDs, expected and actual reasons/dispositions/selections, measured local latencies, abstention counts, and strictly valid numeric usage fields only when supplied. Negative or fractional counters and nonfinite values are treated as unknown.

Offline reports set `usage_source` to `synthetic_mock` and label their deterministic cost as `synthetic_mock_cost_usd`; it is not paid or provider-reported usage. Live reports use `provider_reported` and `provider_reported_cost_usd`. Both modes include explicit cost known/unknown coverage. Reports exclude fixture prompts, candidate contents/capabilities, project IDs, key names, tokens, and MCP response bodies. Baseline savings, net savings, and human quality remain `null`.

Inspect a live plan without launching Keys or prompting for presence:

```sh
python3 scripts/benchmark-optimizer.py --live --project 00000000-0000-0000-0000-000000000000 --jev-key jev --max-calls 4 --dry-run
```

Live mode is deliberately explicit and read-only. It requires `--live`, an approved project UUID, and a Vercel AI Gateway key name. It launches the existing command below over stdio without `--writable`, so user presence and scoped grant authorization remain in the normal Keys path:

```sh
python3 scripts/benchmark-optimizer.py --live --project PROJECT_UUID --jev-key KEY_NAME --max-calls 4 --report optimizer-live.json
```

The live suite only asks for tool selection, model recommendations, and memory assessment from supplied synthetic candidates. It includes two semantically judged cases and structural negatives using recognized dependency hashes and expiry. It does not save, archive, delete, retrieve, or modify project library entries. The default session lifetime is five minutes, initialization timeout is 120 seconds for presence approval, per-call timeout is 40 seconds, and call budget is five. Live labels compare reason, disposition, and selected IDs rather than mode-dependent status. Interpret it as a small labeled smoke test. Paid provider requests and user-presence approval can occur only after explicitly choosing live mode without `--dry-run`.

## Reading the outcome (report schema 4)

`accuracy` and `correct` are kept for older tooling, but they are only the label
match rate over these fixtures. Schema 4 adds, per result:

| Field | Meaning |
| --- | --- |
| `category` | `structural` (deterministic rejection or duplicate: `stale`, `expired`, `duplicate`) or `semantic` (the label depends on an evaluator judgment). |
| `outcome` | `match`; `safe_abstention` (semantic label missed, the engine abstained and kept the full catalog / current model); `safe_mismatch` (structural label missed, nothing selected or switched); `unsafe_error` (a selection the label did not allow, or an "abstention" that still moved the default). A case with no known default is never called safe. |
| `abstention_cause` | `rejected_before_evaluation`, `evaluator_unavailable`, `none_fit_at_or_above_threshold`, `no_candidate_met_threshold`, or `evaluator_declined_scores_not_reported` for engines that predate `decision_evidence`. |
| `decision_evidence` | Threshold, `none_fit`, and per-position `suitable` / `conflict` probabilities. Numbers only; candidate ids and text are dropped. `null` when no evaluator answered. |

The summary adds `structural` and `semantic` buckets, `unsafe_errors`,
`safe_abstentions`, `safe_mismatches`, and `observed_thresholds`. The number that
matters for safety is `unsafe_errors`. None of these fields measure routing
accuracy or savings.

An existing report can be re-read without running anything:

```sh
python3 scripts/benchmark-optimizer.py --reclassify keys-live-mcp-benchmark.json
```

### What the first live run showed

Re-reading the 2026-09-19 live report this way gives: structural 3/3 matched,
semantic 0/2 matched with 2 safe abstentions, 0 unsafe errors. Both semantic
cases reached the evaluator (one provider request each, 617 and 1,006 input
tokens) and the engine declined. The causes, in order of evidence:

1. **Threshold mismatch between fixture and product.** Keys sets `threshold: 0.9`
   for every live evaluation (`OptimizerAPI.swift`); a candidate needs
   `suitable >= 0.9`, `conflict <= 0.1` and `none_fit < 0.9`. The offline fixture
   ran at 0.75 against a mock that always answers 0.98, so it could never show
   this. The offline fixture now uses 0.9 as well. The product threshold was not
   changed.
2. **Terse synthetic input.** `tools_semantic` sends a three-word request and a
   tool whose description is the same three words, with no available tools or
   constraints (the MCP tool does not accept them). The activation smoke test,
   with a fuller request, selected `Read` under the same 0.9 threshold. That is
   one observation, not a rate.
3. **`model_semantic` is not verifiable by an evaluator.** Its label comes from
   cost arithmetic over invented models named "parser large/small". The evaluator
   is asked whether each is "directly suitable … without inventing missing
   prerequisites" and has nothing to base a 0.9 on. Retaining the current model
   is the designed behaviour; the label is only reachable with the mock.
4. **Scores were not reported**, so the run cannot say which condition failed.
   The engine now returns `decision_evidence`, and live reports carry it once the
   installed Keys build includes this engine.

One structural caveat: `keys_tools_select` accepts no dependency hashes, so live,
any candidate that declares dependencies is rejected. `tools_stale_dependency`
therefore passes live without distinguishing stale from current. That is
fail-closed, and the offline run (which does supply hashes) covers the distinction.

`--suite realistic` adds one opt-in tool-selection call with client-like input
(a sentence-long request, three described tools, one of them a deployment tool).
Its label is inclusion/exclusion (`Read` selected, `Deploy` not) rather than an
exact list. It has been run offline only; a live result would show whether the
abstention follows the input. `--suite all` runs six calls, so raise
`--max-calls` and the project request budget deliberately.
