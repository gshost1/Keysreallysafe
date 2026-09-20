# Jev context optimization in Keysreallysafe

Keys includes the existing Vercel Jev compactor as a Claude Code plugin under
`Plugins/jev-optimizer`. The Swift gateway keeps the provider key in the vault,
enforces a temporary grant, and records model, token counts and reported cost.
The plugin decides which eligible old tool content can leave Claude's context.

## Run it

Requirements: Python 3, Claude Code with function-hook support (the original
adapter targets 2.1.274 or later), and a running Keys app built from this checkout.
Add a Vercel AI Gateway key through Keys with provider `vercel-ai-gateway` and
host `ai-gateway.vercel.sh`, or a direct TypeSafe key with provider `typesafe`
and host `api.typesafe.ai`. [Provider support](optimizer-providers.md) lists
the reviewed protocols and limits.

Build and refresh the app once:

```sh
swift build
./scripts/codesign.sh .build/debug/keys
./.build/debug/keys autostart
```

From the project where you want to work, run the launcher from this checkout:

```sh
python3 /path/to/Keysreallysafe/scripts/claude-with-jev.py my-vercel-key
```

Replace the path and vault key name. Claude runs in your current project. The
launcher loads the bundled plugin for that session and requests one Touch ID
grant for `POST /v4/ai/evaluation-model`. Its default limits are 30 minutes and
100 requests. It passes the grant in the child's environment and revokes it
when Claude exits. The Vercel secret is never copied into Claude settings.

For a stored direct TypeSafe key, use
`python3 /path/to/Keysreallysafe/scripts/claude-with-jev.py my-typesafe-key --provider typesafe`.
This selects `POST /v1/systemone` with `jev-latest`; the scoped environment
overrides saved standalone Vercel settings. No provider key is copied to the client.

Launcher options and Claude arguments:

```sh
python3 /path/to/Keysreallysafe/scripts/claude-with-jev.py --help
python3 /path/to/Keysreallysafe/scripts/claude-with-jev.py my-vercel-key --minutes 60 --max-requests 50 -- --continue
```

An expired/revoked grant, unavailable Jev, invalid answers, or inadequate
reduction causes fallback to Claude's built-in compaction. A grant's request
limit is a hard bound; character/token estimates in the optimizer are not a
guaranteed dollar cap.

Do not enable the old standalone compaction plugin in the same session. Both
would intercept compaction. This bundled copy replaces it for the Keys workflow.

## What changes

- Small or unsuitable histories can skip the Jev call entirely.
- Candidate selection and per-compaction request/input budgets bound overhead.
- An exact decision cache avoids paying twice for the same evaluation during
  the same session. It is bounded and memory-only, tied to the model, endpoint
  and credential instance; it is not a shared database of prompts.
- Recent context, errors and structural tool-call pairing are protected. A
  conservative probability threshold keeps uncertain content.
- Automatic compaction waits for enough new context instead of rescoring after
  every turn. Observation mode is available in the plugin configuration.
- Plugin diagnostics distinguish character reduction, estimated decision input,
  actual reported Jev tokens and cache hits. See the [plugin options](../Plugins/jev-optimizer/README.md).

## Where to see cost

In Keys, use the key's **Via gateway** cell to chart requests for that key.
Jev evaluation calls appear under `typesafe-ai/jev`. Valid Vercel
`providerMetadata.gateway.cost` receipts supply the charge; missing or malformed
receipts stay unknown if no list price is available. The gateway ledger is
separate from locally ingested Claude/Codex subscription usage.

Direct TypeSafe calls appear under `jev-latest`. Their reported token counts
are recorded, but their cost remains unknown because the documented response
does not provide a billed-cost receipt and no price is assumed.

A shorter context is not automatically a lower bill. Jev itself uses tokens,
and pruning can disrupt the main model's prompt cache or require information
to be read again. The app does not turn character reduction into a claimed
dollar saving.

## Data and runtime boundary

The Keys catalog continues to store numeric usage and key metadata, not prompts,
tool arguments or responses. For an enabled compaction, the plugin sends fitted
user/assistant text and tool inputs to the selected route (Vercel/TypeSafe, or
direct TypeSafe). It omits full tool
results, so Jev also has limited evidence when judging their usefulness. This
is not a redaction service; enable it only where that existing project content
may be sent to those providers.

The grant token is limited to the evaluation endpoint. It is still a credential
inside the child process and lasts until expiry/revocation. The model's relevance
score never grants permission to execute a tool or bypass Keys authentication.

This integration supports Claude Code's function-hook runtime. Keys can meter
other tools, but this plugin cannot edit the context of a Codex desktop task.
No global plugin installation or background rollout occurs merely by building.

## Validation and sources

The automated checks are offline with synthetic transcripts and a stub Vercel
server. They cover usage/cost parsing, the existing scoped gateway, the launcher,
cache behavior, bounded work and fallback. A real project run is still needed
to evaluate Jev's relevance decisions and net savings on that workload.

Read the [research record](jev-research.md) for the X posts, verified source
implementations, protocol evidence and ideas deferred pending quality evidence.
