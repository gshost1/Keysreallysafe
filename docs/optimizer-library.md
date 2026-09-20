# Optimizer library and clients

The Optimizer extends the existing Keys vault and usage meter with optional
encrypted project knowledge, plan retrieval, and bounded Jev decisions. It is
disabled until configured. Its automated checks use synthetic data. Live
quality, billed savings, and native Keychain upgrade behavior remain manual
release checks; successful unit tests do not establish those outcomes.

## Build and prepare

Use Node 22.12+ or Node 24 for development and Python 3 for the MCP adapter.

```sh
cd Plugins/jev-optimizer
npm ci
npm run typecheck
npm test
npm run build
cd ../..
swift test
swift build
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The existing signing and installation procedure still applies. Installation
stages the compiled decision engine, Claude plugin, and MCP/launcher scripts
with the dashboard, preserving rollback. It refuses an incomplete optimizer
bundle. It does not copy node_modules, local configuration, or credentials.
The installed engine finds Node at `~/.local/bin/node`, `/opt/homebrew/bin/node`,
or `/usr/local/bin/node`; `KEYS_OPTIMIZER_NODE` can select another absolute path.

Building does not replace the running app. Native Touch ID, Keychain access and
live evaluation must be checked on the final signed build before deployment.

## Configure a project

Open **Optimizer** (`⌘4`) and unlock the library. The default session is local
only. Select a compatible stored **Vercel AI Gateway** or **TypeSafe** key to
request a temporary Jev grant restricted to that provider's reviewed evaluation
endpoint, capped at 100 requests. A compatible key's Optimizer action opens this
selector without unlocking. See [provider routes](optimizer-providers.md).
No provider secret is returned to the dashboard or MCP client.

Create a project with its approved root. Enable content storage to save curated
memories/plans; separately allow provider evaluation if its selected content
may be sent to Vercel/TypeSafe. Set retention and cumulative project request/input
budgets. Modes are Off, Observe and Suggest. Auto requests are downgraded to
Suggest until a separate quality promotion mechanism is implemented and
validated. Feature switches disable individual retrieval/selection operations.

Save facts as memories. A plan requires a source and verification steps. Records
carry versions, project scope, tools, constraints, expiry, and optional file
dependencies. Obtain dependency fingerprints through the library's capture
action or the scoped `dependency_fingerprints` operation; they are keyed to the
project, not raw public hashes. Recalculate them only after verifying the plan
against the new file state. A pinned record can still expire or fail validity.

Nothing imports historical conversations automatically. Known secret-shaped
values are rejected, but this is not a guarantee that arbitrary text contains
no confidential information. Only save content approved for this project.

Optional **candidate capture** is disabled by default. Supported clients can
stage curated outcomes from finished successful tasks with verification evidence.
They remain encrypted and pending until an administrative review approves the
current version. Editing an approved captured entry returns it to pending.
See [capture and review](optimizer-candidates.md) and the
[compound MCP task workflow](optimizer-task-workflow.md).

## Connect an MCP client

The project UUID appears in the Optimizer pane. A supported stdio client can run:

```sh
/absolute/path/to/keys optimizer mcp --project PROJECT_UUID --writable --jev-key jev
```

Omit `--writable` for read-only library access. Omit `--jev-key` for local
search without external evaluation. Session lifetime defaults to 30 minutes;
`--minutes` accepts 1–120. Connection requests user presence in the running
Keys app. Configure a startup timeout of at least 120 seconds to allow time for
that prompt. The content capability is passed only to the child process,
removed from its environment at startup, and closed on normal exit.
Each project connection gets a task identity for optimizer accounting. Evaluation
tools use it when no explicit `task_id` is supplied, including read-only
connections. Explicit outcome and client-usage recording require `--writable`.

For Codex, the locally installed CLI exposes `codex mcp add`. A configuration
example, to apply deliberately after installing the signed Keys build:

```toml
[mcp_servers.keys_optimizer]
command = "/absolute/path/to/keys"
args = ["optimizer", "mcp", "--project", "PROJECT_UUID", "--writable", "--jev-key", "jev"]
startup_timeout_sec = 120
tool_timeout_sec = 45
```

For per-session commands that leave every client configuration untouched, and a
helper that verifies them against the installed CLIs, see
[project-local client setup](optimizer-client-setup.md).

No user-level Codex configuration is changed by building this project.
The [official Codex MCP documentation](https://developers.openai.com/codex/mcp)
describes stdio configuration. MCP provides tools; it does not grant permission
to rewrite Codex's conversation context or silently change its active model.

Exposed operations include local memory search/read, task accounting, optional
memory saves, Jev plan retrieval, advisory memory assessment, tool selection,
and model recommendations. Clients send compact metadata rather than complete
tool implementations. Retrieved text is reference material, never permission
to execute its instructions. Use normal client approval rules for subsequent
actions.

### Bounded local context and conditional reads

`keys_context_prepare` (HTTP operation `context_prepare`) assembles a small
context pack from current approved memories and plans without a Jev call. Supply
`query`, optional `available_tools` and `current_constraints` arrays, and optional
`max_bytes`, `max_estimated_tokens`, and `max_entries`. Defaults are 12,000 bytes,
4,000 estimated tokens and eight entries; the tighter size limit wins. Estimates
use UTF-8 bytes divided by three, not a model tokenizer. The complete JSON pack,
including provenance, verification and metadata, must fit. Entries are included
whole or omitted; old revision bodies are never included.

The server rechecks project settings, expiry, available tools, exact declared
constraints and current file fingerprints. It computes freshness from the
approved project root rather than accepting hashes supplied by the client.
These are local checks; relevance and semantic correctness still need review.
The result always says `local_checks_only`, `verification_required: true` and
`applied: false`.

Keep the returned project-keyed `fingerprint` alongside the pack in the current
conversation. A later identical request can supply it as `if_fingerprint`.
After rerunning current eligibility checks, Keys returns `unchanged` with no
repeated entry bodies when that is smaller. This reduces transmitted context;
it does not prove a lower model bill. If the caller no longer retains the
matching pack (for example, after compaction), omit the fingerprint to fetch it
again. Fingerprints do not authorize access or skip revocation checks.

For reproducible release staging and the bounded offline/live benchmark harness,
see [optimizer-release.md](optimizer-release.md) and
[optimizer-benchmarks.md](optimizer-benchmarks.md). Neither runs a live trial by
default.

The original Claude compaction launcher remains supported as documented in
[jev-optimizer.md](jev-optimizer.md). Do not enable both the bundled and old
standalone compaction plugins. MCP tools and the compaction hook are distinct
capabilities; the library does not secretly intercept every tool call.

## CLI and HTTP surface

```sh
keys optimizer status
keys optimizer rpc --project PROJECT_UUID --operation search
```

`rpc` accepts one JSON object from stdin, requests scoped presence approval,
returns JSON, and closes its capability. For example, supply a payload containing
`query`, `available_tools`, and `max_candidates` to search. It does not accept
arbitrary project changes through a project-scoped session.

The local dashboard API is:

- `GET /api/optimizer/status`: limited non-content capability status.
- `POST /api/optimizer/unlock`: native presence; returns a temporary content token.
- `POST /api/optimizer/rpc`: requires both `X-KSF-Token` (CSRF) and
  `X-KSF-Optimizer` (content capability), with `{operation,payload}`.
- `POST /api/optimizer/close`: closes only the presented session.
- `POST /api/optimizer/lock`: an administrative capability locks all sessions.

Only the approved project is visible to a scoped client. Administrative project
settings require an administrative unlock. Tokens, encryption keys, and
decrypted search indexes remain in memory. Screen lock, expiry or restart ends
access. An explicit lock also revokes linked Jev grants. Ordinary local processes
with the same user account are not a hardware-isolated security boundary.

## Storage, accounting, and limits

Content and the task ledger are separate AES-GCM archives under the catalog's
`optimizer` directory. Their key is in the `keysreallysafe.optimizer` Keychain
service. Private file permissions, process locking, atomic replacement and an
encrypted recovery journal guard updates. Retention and project deletion remove
entries and derived state from this archive; they cannot erase an external
backup or an explicit export the user has kept.

The local shortlist precedes Jev. Applicability checks reject expired or
cross-project candidates, changed dependencies, missing tools and mismatched
constraints. Jev may return no match. Successful suggestions still require
verification. Model routing preserves explicit model selections, compares an
allowed catalog, and retains the current model when cost/capability evidence is
missing. It never performs a model switch itself.

Request/input reservations survive restart in the task ledger. Unknown dispatched
work retains a conservative reservation. Actual provider usage reconciles known
amounts. Limits on estimated tokens or post-call dollars are not a guarantee
that the provider cannot bill an in-flight request above an estimate.
The input ceiling is reserved atomically and clamped to the project's remaining
capacity; the engine must fit within that granted estimate before dispatch.

Exact decision caches are bounded and scoped to immutable relevant inputs.
The engine also supplies an allowlisted read-result cache for supported adapters;
it is not a transparent cache of the user's existing shell/tools. Side-effecting
and credential-bearing actions are ineligible.

Task metrics distinguish actual provider reports, estimates, and unknown data.
Optimizer and client usage are grouped separately, with per-task totals and
unknown-cost counts. Local search returns at most 64 KB of current candidate
bodies; historical versions remain in the library/export and are not sent to
Jev as part of retrieval. MCP entry reads omit historical bodies as well.
Cache hits have no new provider charge. Repeated request IDs are deduplicated
only within compatible task/model identities. Existing usage-meter totals remain
separate from this task ledger; it does not fabricate correlation with unrelated
session logs. Clients must report or supply reliable identities for attribution.

## Evaluation and release gates

The engine's frozen synthetic fixtures and mocked judge test structural guards,
parsing, budgets, routing arithmetic, cache isolation and fallback. They are not
independent held-out evidence of Jev accuracy, prompt-injection resistance, or
end-to-end savings. The gated live evaluation runner requires an explicit scoped
grant and does not run in ordinary tests.

Before automatic behavior is promoted, evaluate permitted real tasks against
matched baselines. Count Jev, extraction, main-model cache rebuilds, retries,
tool rereads, and corrections. Record verified outcomes and uncertainty. A
single live task has no directly observed counterfactual bill; any avoided-cost
figure must be labeled as an estimate. No automatic promotion is shipped in
this implementation.
