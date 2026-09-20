# Keys Jev Optimizer

Optional Claude Code context optimizer bundled with KeysReallySafe. It adapts
[gshost1/vercel-compaction](https://github.com/gshost1/vercel-compaction) at
`a23e181`, itself derived from
[fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction).
The package and plugin name is `keys-jev-optimizer`, version `0.1.0`.

Jev evaluates whether older tool calls and results still matter. The optimizer
can keep them verbatim, retain a short result excerpt, or remove a call and its
result together. User and assistant text remain in order and unchanged. It does
not generate summaries or cache answers to similar user prompts.

## Savings controls

- Skip evaluation when eligible output text offers less than 4,000 removable
  characters. Score at most the 16 largest eligible outputs.
- Preserve the first and newest six messages, failed tool calls, known
  instruction-file reads (`AGENTS.md`, `CLAUDE.md`, `SKILL.md`), and known
  coordination/tool-loading calls. Unmatched calls remain untouched.
- Keep uncertain evidence: the default keep threshold is `0.2`. Only lower
  probabilities permit removal. Missing, non-finite, or out-of-range answers
  fail the entire operation before any history is installed.
- Check the total estimated evaluator input budget (60,000 tokens, including
  repeated state) and request limit (three) before sending anything. At most two
  requests run concurrently; after a failure, no more are scheduled.
- Reuse an exact serialized evaluator state-plus-questions request on the same
  transport instance. This is a five-minute memory-only cache, bounded to 32
  entries and one million key characters. Changing model, endpoint or credential
  creates a fresh hook transport. No fuzzy or cross-session reuse occurs.
- Wait for 8,000 new context tokens between early automatic attempts. Subagent
  turn events never trigger compaction of the main conversation.

The hook reports **character reduction**, evaluator requests/cache hits, actual
reported Jev input/output tokens, and separately labeled request-token estimates.
An absent/invalid token count is `unknown`, never zero. Cached decisions contribute
zero new request usage. Character reduction is not measured token or dollar
savings: future input usage, provider prompt-cache effects, retries and quality
also matter. Failed evaluation requests can still be billed; the gateway usage
ledger remains the source for those requests.

## Using it with KeysReallySafe

Use the repository's Jev launcher described in the [main README](../../README.md)
to obtain a scoped temporary gateway grant without exposing the upstream key to
Claude. Function hooks require an early-access Claude Code build compatible with
2.1.274 or later; the hook uses the gateway's experimental evaluation protocol.

The launcher sets `KEYS_JEV_SCOPED_GRANT=1`. In that mode the paired environment
values `AI_GATEWAY_API_KEY` and `AI_GATEWAY_BASE_URL` are authoritative; saved
plugin credentials and endpoints cannot override them. Missing/invalid values
fail closed. The endpoint must be the literal local Keys URL:
`http://127.0.0.1:12767/<vault-key>/v4/ai/evaluation-model`, or
`http://127.0.0.1:12767/<vault-key>/v1/systemone` when the launcher sets
`KEYS_JEV_PROVIDER=typesafe`. Provider, path and model are bound together;
saved standalone settings cannot override a scoped route. See the
[provider guide](../../docs/optimizer-providers.md).

For a standalone development session, supply `AI_GATEWAY_API_KEY`, enable
`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, and run Claude with `--plugin-dir` pointing
at this directory. Outside Keys scoped mode, options override environment values;
`baseUrl` must be HTTPS or loopback HTTP. Do not commit credentials to settings.

## Apply and observe modes

`mode: "apply"` is the default. `/compact` and host compaction use the pruned
history when character reduction reaches `minReductionRatio`. Otherwise, or if
evaluation fails, the built-in summarizer handles compaction. A tiny **early
plugin-triggered** attempt is skipped without invoking either evaluator or
summarizer. Explicit `/compact` instructions always go straight to the built-in
summarizer so the optimizer cannot discard the user's requested focus.

`mode: "observe"` evaluates and reports a proposed reduction without changing
the transcript during the plugin's early automatic attempts. A user `/compact`
or host-required compaction still delegates to the built-in summarizer; observe
mode does not block the host from freeing a full context window. Observation
itself incurs evaluator usage unless preflight skips it or the exact cache hits.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `mode` | `apply` | `apply` or `observe` |
| `model` | `typesafe-ai/jev` | Gateway evaluation model |
| `keepThreshold` | `0.2` | Keep probability at or above which evidence stays |
| `preserveRecentMessages` | `6` | Newest messages protected, in addition to the first |
| `minRemovableChars` | `4000` | Minimum potential result-text reduction before evaluation |
| `maxCandidates` | `16` | Largest eligible outputs to score |
| `maxStateTokens` | `25000` | Estimated shared-state ceiling |
| `maxRequestTokens` | `30000` | Estimated state-plus-questions ceiling per batch |
| `maxDecisionInputTokens` | `60000` | Estimated total uncached request input; includes repeated state |
| `maxRequests` | `3` | Maximum uncached requests per operation; zero permits exact cache hits only |
| `maxConcurrency` | `2` | Concurrent requests, clamped to 1–8 |
| `truncateHeadChars` | `300` | Result excerpt characters to retain |
| `compactAtPercent` | `60` | Context percentage for early automatic attempts |
| `minContextGrowthTokens` | `8000` | Context growth before another early automatic attempt |
| `minReductionRatio` | `0.25` | Character reduction needed to install pruning |
| `goal` | Recent user prompts | Task description for the evaluator |
| `apiKey` | `AI_GATEWAY_API_KEY` | Standalone key; Keys scoped mode requires the environment grant |
| `baseUrl` | `AI_GATEWAY_BASE_URL`, then public Vercel evaluation endpoint | Trusted destination for credentials and state |

## Data and limits

Evaluation sends prompts, assistant text and tool inputs to the configured
evaluation provider. Tool results are omitted from evaluator state and
replaced with size/status notes. Jev therefore cannot inspect the exact evidence
it judges; this is a heuristic, not a guarantee of safe deletion. Instruction and
coordination protection covers known names and paths, not every custom tool.
Only enable this optional plugin where transmitting conversation content is
appropriate. Numeric usage accounting in the Keys app remains separate.

State is fitted by progressively shortening inputs and abridging text **in the
evaluator request only**. Protected original transcript text is not rewritten.
The exact decision cache also contains evaluator state in process memory, with
no persistent prompt store. Logs contain tool names, decisions and usage, not
conversation content or upstream error bodies. A truncation note directs the
assistant to original history or a safe re-read; it never authorizes rerunning a
side-effecting command.

Transport/cache instances must keep their model, endpoint and credentials
immutable. The hook enforces this when configuration changes. Library consumers
can reuse a `JevClient` with `compact(messages, client, options)`; the convenience
`compactMessages` constructs a fresh client per call and does not reuse decisions
across calls.

## Development

Use Node 22.12+ (or 24+) for the development tooling. The runtime library has no
SDK dependencies. From this directory:

```sh
npm ci
npm test
npm run typecheck
npm run build
npm run typecheck:hooks
```

`npm run typecheck` checks the library and every non-hook test, including the
provider transport, session adapter and fixture harness. Hook tests run under
`npm test`; their static checking is included in `npm run typecheck:hooks`.
Hook typechecking requires generated `types/claude-code.d.ts`: run
`/plugin-types types` in a compatible Claude Code build. It is intentionally not
redistributed. Tests use fake evaluator responses; a live host/gateway smoke test
is still needed to validate a particular deployed Claude build and credentials.
No local substitute declarations stand in for the private upstream hook contract.

The gated `runLiveModelJudgeFixtures` harness accepts the Keys launcher's
`KEYS_JEV_PROVIDER` selection (`typesafe` or `vercel-ai-gateway`) and paired scoped
grant/endpoint. It requires `KEYS_JEV_LIVE_EVAL=1`; it uses the matching reviewed
request adapter and rejects mismatched routes before dispatch. Automated tests
inject a synthetic fetch transport and make no live evaluation calls.
MIT licensed; original attribution is retained in `LICENSE`.
