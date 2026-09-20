# Keys unattended work results

Completed September 19, 2026 in the `codex/jev-savings` checkout. MIT remains unchanged. This is locally built and verified work; it does not replace the running app, enable analytics, or establish live model quality or financial savings.

## Implemented in this work

| Area | Result |
| --- | --- |
| Direct TypeSafe Jev | Added the official System One protocol alongside Vercel, including scoped Claude launcher support. Direct token counts are recorded; cost stays unknown when no receipt or verified price exists. |
| Stored-key workflow | Metadata-only compatible-key discovery, distinct key names in the selector, local-only mode, and a key-row Optimizer action that preselects without unlocking. |
| Restricted evaluation grants | Explicit reviewed-provider marker; exact POST evaluation routes; provider/host/auth/prefix validation before presence, after presence, and at use. Ordinary grants keep their existing prefix behavior. |
| Encrypted candidate capture | Opt-in capture from successful finished tasks with verification evidence. Pending candidates are excluded from library retrieval/context. Only an administrative session can approve the displayed version. Approved captured edits require fresh review. |
| Capture privacy | Curated content stays in the encrypted library. Task verification is represented by a project-keyed digest in the numeric ledger. No conversation import or analytics upload is added by capture. |
| MCP task preparation | One compound tool supplies bounded local context and, only when requested and authorized, plan/tool/model suggestions. Session failure suppresses partial context. |
| Supported-host adapter | Bounded advisory orchestration, lazy tool-definition callbacks, required-tool preservation and full fallback; permission/dependency-aware read-result caching; normal host execution retained when optimization is off or fails. |
| Application gates | Plan/model callbacks require explicit host confirmation, enabled policy, previously selected advice, unchanged current task/catalog/policy state and unexpired data. They are integration points, not enabled automatic routing. |
| Collector deployment preparation | Non-root container, private persistent volume, TLS proxy template, disabled HTTP request/error logs, resource/body/header/time bounds, health route and backup/retention guidance. Actual hosting remains unset. |
| Preflight and onboarding | Offline prerequisite checker, deployment validator, refreshed provider/capture/client guides and CI checks. |

## Verification

- Swift: **269 tests executed, 2 environment-dependent skips, 0 failures**. The skips require real Keychain/signing conditions.
- TypeScript optimizer: **126 tests passed**, typecheck and distribution build passed.
- Python client/release/benchmark/preflight suite: **50 tests passed**.
- Analytics collector and deployment checks: **12 tests passed**.
- Analytics and key/candidate workflow Playwright regressions passed with loopback fixtures. Tests cover distinct keys, provider failures, no automatic unlock, version conflicts, project/filter changes, and responses arriving after lock.
- Release build passed; existing `Ingest.swift` warnings remain.
- Offline benchmark: **10/10 structural fixtures**, including two repeated semantic evaluations served from the exact cache. Costs in this report are synthetic; real net savings and task quality remain unknown.
- Offline Compose configuration validation and strict prerequisite preflight passed.
- Two independent review tracks found and verified fixes for candidate approval bypass, provider path normalization, exact authorization scope, proxy error logging, UI races, required-tool truncation, normal-tool fallback, and stale application advice.

Docker is installed but its daemon is unavailable on this machine. Container execution, DNS, TLS issuance, production load, backups/restore and live collector delivery are therefore unverified. No actual collector deployment was attempted.

## Remaining work and inputs

1. **Native release checks:** complete the final signing identity, real Keychain upgrade and Touch ID flow, then install through the supported installer. The current running Keys application was not replaced.
2. **Live client/project authorization:** select a permitted project and stored provider key, issue a temporary grant, configure the live client and run the bounded observation trial. No real provider call or paid request was made here.
3. **Measured quality/savings:** compare representative real tasks with matched baselines before promoting automatic plan/model behavior or making savings claims.
4. **Actual hosting:** choose the domain/server, validate containers there, configure HTTPS and retention, and only then set the app's analytics destination and opt in. The endpoint remains nil and collection cannot be enabled in this build.
5. **Broader client integration:** the TypeScript adapter is available to capable hosts and MCP preparation is callable, but no global tool interception, automatic Codex context rewriting or automatic mid-task model switching is installed. Clients must invoke the supported boundaries.
6. **Complete accounting coverage:** usage attribution works when clients provide task/request identities. Unrelated subscription/session records remain separate; storing a key alone does not reveal all external usage.
7. **Public distribution:** source publication/merge and a signed public release remain separate from this local checkpoint.

Historical conversation import, shared cloud/general response caches, automatic cross-project sharing, database embeddings, background X scraping and model training remain deferred, not silently enabled.
