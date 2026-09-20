# Optimizer benchmark

`scripts/benchmark-optimizer.py` is a bounded evaluation harness for the Optimizer. Its default mode executes the repository's compiled TypeScript `OptimizerEngine` with a deterministic mock Jev asker. It opens no sockets, launches no Keys process, reads no provider secret, and requests no user presence.

The offline result is a structural check of production engine logic. It validates semantic selection, recognized dependency and expiry rejection, exact duplicate assessment, model routing with complete cost/capability inputs, repetition/call limits, and report generation. Transport framing is tested separately with bounded fake stdio peers. This is not evidence of general model quality, production savings, human quality, or safe unattended automation.

Run the offline benchmark and its tests:

```sh
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
