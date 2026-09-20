# Jev savings research — 19 September 2026

We searched signed-in X Top and Latest results for Jev combined with compaction,
tokens, tools, routing and cache, then checked the strongest relevant patterns
against source code. This is a curated review of a newly launched model, not an
exhaustive archive of X or an independent benchmark of every claim.

## What informed this implementation

| Pattern | Evidence | Applied in Keys |
| --- | --- | --- |
| Prune old tool content without rewriting conversation text | [Tamara's original X demonstration](https://x.com/tamarajtran/status/2100694549362553153) and [fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) | Import the existing Vercel adaptation as the bundled optimizer; preserve attribution and MIT license. |
| Evaluate only substantial eligible outputs; wait for context growth | [Pi implementation](https://github.com/nourhelmi/pi-jev-compaction/blob/648741aabe7eb68a84a31cf5989a17f484acb86d/src/pruning.ts) | Preflight threshold, bounded candidate count, growth gate and protected recent/error context. |
| Keep tool-call pairing and validate probabilities in code | [LiteLLM Jev implementation](https://github.com/BerriAI/litellm/blob/c3fa53be8d01105121bfeb13754acb763465da99/litellm/proxy/guardrails/guardrail_hooks/typesafe/typesafe.py) | Conservative deletion threshold, structural tests and fallback on missing or invalid decisions. |
| Reuse decisions and bound decision-model work | [daf-jev Decider](https://github.com/docxology/daf-jev/blob/ff7b28515d7f60c9f7182b128b76b90fbfcba66f/src/daf_jev/decider.py) | Bounded memory cache for identical decision requests, request/input budgets and bounded concurrency. |
| Batch independent questions over shared state | [TypeSafe fan-out pattern](https://docs.typesafe.ai/patterns/fan-out) | Keep batching and account for state repeated across requests. |
| Observe before applying | [Jev Codex router](https://github.com/0xNatoshi/jev-codex-router/blob/8292b519659280884627a962c826ac7721136a64/server/jev_server.py) | Optional observation mode; no automatic change of the user's main model. |

These are adaptations of engineering patterns. Only the existing MIT-licensed
Vercel compactor was imported; no other external package is added at runtime.
Its source is [gshost1/vercel-compaction at a23e181](https://github.com/gshost1/vercel-compaction/tree/a23e181fbd3a0195788bc729d80238d10f5d1b9a),
derived from Tamara's project. The original working copies remain available;
the integrated copy under `Plugins/jev-optimizer` is the implementation for Keys.

## Other ideas found on X

- [Sydney Runkle's harness article](https://x.com/sydneyrunkle/status/2100754364545761643)
  and its [LangChain version](https://www.langchain.com/blog/building-a-harness-with-jev)
  demonstrate model routing and tool risk classification. Routing chooses a
  model for the run. That is promising future work, but requires quality and
  cache-loss measurements before automatic model changes.
- [John Yeo's skill/tool selection report](https://x.com/johnyeo_/status/2100987661926252737)
  claims lower Slack-agent latency. The transferable idea is to shortlist
  relevant skills before the main model reads them; the post's claimed speedup
  was not independently measured here.
- [Pydantic's tool-selection example](https://x.com/pydantic/status/2100812324713943469)
  distinguishes selecting a tool from generating its arguments. Jev selects
  structured answers; a generative model still handles open-ended arguments.
- [A production-adoption report](https://x.com/yonyoniz/status/2101241236107542549)
  emphasizes shadow evaluation and misses. This supports collecting evidence
  before expanding automatic decisions.
- [Varun Mathur's decision-cache thread](https://x.com/varun_mathur/status/2101371148856328270)
  links to [jevcache](https://github.com/hyperspaceai/jevcache). Its documentation
  describes memoizing model/schema/state decisions. Its distributed binary and
  shared-cache service were not installed or audited; Keys uses a bounded
  memory-only exact-request cache instead.
- [Jev Codex Bridge](https://x.com/se7enws/status/2101356673432465738) links to
  [an implementation](https://github.com/ansidium/jev-codex-bridge) that estimates
  cache-rebuild cost before a model downgrade. Its README explicitly says there
  is no comparative cost benchmark. Adopting its Codex provider bridge would be
  a separate integration with configuration and authentication implications.
- [Alex Volkov's compaction report](https://x.com/altryne/status/2100739055923425589)
  is a useful demonstration, but its dramatic token reduction is an anecdote,
  not a savings target for this app.

Trading, advertising analysis and database classification demonstrations were
outside the key vault and token-optimization scope. Popularity was not treated
as evidence that an implementation preserves task quality.

## Protocol and cost evidence

The [Vercel SDK evaluation implementation](https://github.com/vercel/ai/blob/20dd00abba618d5a516e0fee40ccd3e18a2bd1fb/packages/gateway/src/gateway-evaluation-model.ts)
uses `POST /v4/ai/evaluation-model`, `ai-model-id: typesafe-ai/jev`, and
`ai-evaluation-model-specification-version: 4`. Its JSON body contains state and
questions; it need not contain a model. Usage uses `inputTokens` and
`outputTokens`. Keys must recognize this route separately from OpenAI chat.

The [Vercel model catalog](https://vercel.com/ai-gateway/models/jev) currently lists
$0.042 per million input tokens and a 32,000-token context. This dated reference
is not a permanent free-price assumption. [Vercel's cost documentation](https://vercel.com/academy/ai-gateway/ai-gateway-pricing)
identifies `providerMetadata.gateway.cost` as the request's dollar charge.
Missing cost remains unknown instead of becoming zero.

The [TypeSafe model limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
recommend filtering irrelevant state and enforcing structural invariants in
code. Probabilities do not prove that content is safe to discard.

## Savings claims and remaining evaluation

Character reduction is a size measurement, not a tokenizer result or a dollar
saving. Reported Jev tokens and charges measure optimizer overhead. Net savings
also depend on downstream model input/cache usage, retries, tool rereads and
task correctness. Changing old context can invalidate a provider's prompt cache.

The local checks use synthetic transcripts and mocked provider responses. They
verify protocol, bounds, reuse, fallback and accounting. They do not establish
live Jev judgment quality or an end-to-end percentage saving.

Cross-task semantic plan reuse remains separate: similar wording is insufficient
when code revisions, task constraints or tool results differ. A future design can
follow TypeSafe's [skill-suggestion cookbook](https://docs.typesafe.ai/cookbooks/skill_suggestion):
retrieve a short list, permit “none fit,” and validate applicability before reuse.
