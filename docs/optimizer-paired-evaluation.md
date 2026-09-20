# Paired savings evaluation

`scripts/paired-savings-eval.py` answers one narrow question: for the *same task,
starting context and client model*, did the run with the Optimizer use fewer
provider-reported tokens or dollars than the run without it, after the
Optimizer's own cost is added back, and did the output still pass the same checks?

It is arithmetic over records you supply. It launches no model, provider request,
Keys process or presence prompt, and it has no opinion about tasks it was not given.

## What it cannot do

- It does not run either arm. No baseline or paid model run is invented; an arm
  that was never run has unknown usage.
- It does not turn bytes into tokens. `estimated_input_bytes` is shown next to the
  provider's count (`estimate_vs_provider`) and never enters a saving.
- It does not fill in cost. A provider that reports none leaves
  `net_reported_cost_savings_usd` as `null` for that pair.
- An exact repeat answered from the decision cache is reported under
  `cache_replay_pairs`, apart from `general_task_pairs`. A replay avoiding its own
  evaluator call says nothing about savings on new tasks.

## Procedure

1. **Plan.** List tasks with the checks that decide success, then print the run sheet:

   ```sh
   python3 scripts/paired-savings-eval.py plan --tasks tasks.json
   ```

   ```json
   {"tasks": [{"id": "fix-parser-escape", "checks": ["swift test --filter ParserTests"]}]}
   ```

   The sheet alternates which arm goes first and restates what each arm must record.

2. **Run both arms yourself**, each in a fresh client session so neither inherits
   the other's prompt cache, from the same commit and starting context, with the
   same client model.
   - Baseline: project mode `off`, or a client started without the Keys MCP server.
   - Treatment: Optimizer on, through a `--writable` MCP session.
   - In both, start a Keys task (`keys_task_start`) and record the client's
     provider-reported usage against it with `keys_usage_record`. Keys records the
     Optimizer's own requests on the treatment task automatically.

3. **Collect.** Save a `keys_optimizer_status` result to a file and describe the pairs:

   ```json
   {"pairs": [{
     "pair_id": "fix-parser-escape",
     "baseline":  {"task_id": "BASELINE_TASK_UUID",  "task_fingerprint": "sha256:…", "context_fingerprint": "sha256:…", "model": "client-model-id",
                   "checks": [{"name": "swift test --filter ParserTests", "passed": true}], "estimated_input_bytes": 41234},
     "treatment": {"task_id": "TREATMENT_TASK_UUID", "task_fingerprint": "sha256:…", "context_fingerprint": "sha256:…", "model": "client-model-id",
                   "checks": [{"name": "swift test --filter ParserTests", "passed": true}],
                   "cache_rebuild": {"occurred": false}, "fallback": {"occurred": false}}
   }]}
   ```

   ```sh
   python3 scripts/paired-savings-eval.py collect --manifest manifest.json --status status.json --out pairs.json
   python3 scripts/paired-savings-eval.py report --pairs pairs.json --out paired-report.json
   ```

   Pair records can also be written by hand with `provider_usage` and
   `optimizer_usage` objects (`input_tokens`, `output_tokens`, `reported_cost_usd`).

## Rules the report applies

- **Comparable** only when `task_fingerprint`, `context_fingerprint` and `model`
  are present and equal, and the baseline task recorded no Optimizer events.
- **Quality first.** `held` needs every named check to pass in both arms.
  `regression`, `baseline_failed` and `unknown` pairs never count toward savings.
- **Net, not gross.** `net_token_savings = baseline − (treatment client + optimizer
  overhead + cache rebuild + fallback)`, for input and output tokens, and likewise
  for reported cost. `gross_client_token_savings_before_overhead` is shown separately.
- **Cache rebuild and fallback must be stated.** `{"occurred": false}`, numbers, or
  `"included_in_client_usage": true`. Left out, they are unknown and the net figure
  is `null`.
- **Unknown stays unknown.** A Keys total is used only when its
  `*_unknown_events` count is zero; otherwise the field is listed in
  `unknown_fields`. Negative, fractional, boolean or non-finite values are unknown.
- `measured_savings_claim` stays `null` until at least one pair is comparable,
  quality-held, not a replay, and fully known. Even then the report is bound to
  its sample: it gives sums, medians and the number of pairs where the treatment
  used more, not a rate.

Limits: 200 pairs and 2 MB per input file. Tests (`scripts/tests/test_paired_savings_eval.py`)
use mock records only.
