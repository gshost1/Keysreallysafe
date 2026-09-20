# Review fixes: dispositions and validation

Scope: fixes for the Claude Fable 5.1 review of `9f92e66..a9c19d4`, applied as
uncommitted work on `codex/jev-savings` over base `a9c19d4`. Claude implementation checks below were
run offline on 2026-09-19 with synthetic fixtures. At that handoff, nothing had been committed, pushed,
signed, installed or deployed; no Touch ID prompt, provider call, live hook call
or network service was used. The license remains MIT.

**This records implementation validation; activation is recorded separately.** See
[Unresolved limitations](#unresolved-limitations).

## Finding dispositions

| # | Finding (priority) | Disposition | Where | Regression coverage |
| --- | --- | --- | --- | --- |
| 1 | New project sends `id:null`; default library listing sends an empty query; entry save fails on blank Source / no expiry (P1) | Fixed. The dashboard omits blank or null optional fields instead of sending them. | `Web/optimizer.js` | `scripts/tests/test_optimizer_workflow_ui.cjs` asserts the real form payloads in Chromium. |
| 2 | Policy/capability denial confused with session expiry in controller, HTTP and clients (P2) | Fixed. Swift distinguishes `locked` from `denied`; HTTP returns `optimizer_locked` vs `optimizer_access_denied` (both 403); the UI keeps a valid session on a denial; MCP maps only the exact known denial body to `operation_denied` and treats every other 403 (locked, unknown, malformed, oversized, empty) as `session_locked_or_expired`. | `OptimizerAPI.swift`, `OptimizerStore.swift`, `HTTPServer.swift`, `Web/optimizer.js`, `scripts/optimizer-mcp.py` | `OptimizerAPITests`, browser suite, `test_http_403_known_denial_is_distinct_from_locked_and_unknown_bodies` (13 cases). |
| 3 | Pre-dispatch failures consume persistent budget; pending reservations never age (P2) | Fixed conservatively, following the summary's qualification: only provably never-started work is released; unknown dispatch keeps conservative accounting; numeric settlement is deferred; cumulative reservation ledger and capacity. No blanket refund on lock, timeout, `.unavailable` or TTL. | `OptimizerAPI.swift`, `OptimizerStore.swift` | `OptimizerAPITests`, `OptimizerStoreTests`, `OptimizerProcessTests`. |
| 4 | Engine exiting before reading a large request kills the runner with SIGPIPE (P2, isolated reproduction) | Fixed in the runner; failure now surfaces as an error. | `OptimizerAPI.swift` | `OptimizerProcessTests`. The installed menu-bar app was not exercised. |
| 5 | MCP task-ID and model-cost contract gaps | Fixed. `task_id` is optional and falls back to the session task; when present it must use the canonical hyphenated UUID form; the session config also validates its UUID. `keys_task_start` requires a valid `client`. The ignored `plan_candidates` argument is removed (plans come from the approved library). `explicit_model_id`, `current_model_id`, `optimizer_cost_usd`, `cache_rebuild_cost_usd`, `fallback_cost_usd` are forwarded to the model stage only. | `scripts/optimizer-mcp.py` | `TaskPrepareContractTests`: optional/session/explicit task ID, UUID validation, `task_start` client, `plan_candidates` rejected, routing fields. |
| 6 | One failed advisory stage discarded the prepared context; conversely context must not leak after lock | Fixed. `operation_denied`, `optimizer_limit` and `operation_refused` mark the stage `unavailable` and the result `partial`, but context is returned only after a fresh `summary` authorization check succeeds. Lock/expiry, network loss and unknown errors still suppress everything, without a recheck. | `scripts/optimizer-mcp.py` | `test_recoverable_stage_failure_returns_context_only_after_fresh_authorization`, `test_partial_result_is_suppressed_when_the_authorization_recheck_fails`, `test_lock_network_and_unknown_failures_suppress_context_without_a_recheck`. |
| 7 | Non-ASCII context expands past the stage bound after ASCII escaping | Fixed. Stage (24,000) and request (128,000) bounds count UTF-8 bytes; request bodies and the inner tool text are emitted as UTF-8. Defect found while testing: an unpaired surrogate raised an unhandled `UnicodeEncodeError` that surfaced as a JSON-RPC parse error; it is now a `SafeError` (`invalid_request`) / `invalid_stage`. | `scripts/optimizer-mcp.py` | `test_stage_bound_counts_utf8_bytes_without_ascii_expansion`, `test_request_limit_counts_utf8_bytes_and_unpaired_surrogates_are_refused`. |
| 8 | Bounded `HTTPError` body stream left open | Fixed: the error response is closed on every HTTP error path after at most 4,097 bytes are read. | `scripts/optimizer-mcp.py` | Close is asserted in each of the 13 HTTP error cases. |
| 9 | Zero-request usage recorded as unknown; bool/negative counters accepted | Fixed in the adapter (`requests > 0` gate) and MCP (strict non-negative `int`, bools rejected). | `session.ts`, `scripts/optimizer-mcp.py` | `session.test.ts`, `test_complete_result_needs_no_recheck_and_usage_rejects_bools_and_negatives`. |
| 10 | Tool shortlist / full-catalog fallback ambiguity; dependency-cap mismatch | Fixed. A lexical prefilter or candidate bound never hides unevaluated tools: `full_catalog_fallback` is true unless every optional tool was evaluated; `evaluated_ids` and `suggestedToolIds` are reported; host-required and selected-plan tools are retained. | `optimizer.ts`, `session.ts` | `optimizer.test.ts`, `session.test.ts` (9/25/65/130-tool catalogs). |
| 11 | Unbounded advice map; stale advice | Fixed: 64 entries, 5-minute TTL, SHA-256 binding. Defect found on final inspection: apply paths bound the raw `requiredTools` while `advise` bound the normalized list, so a padded name could never be applied; both now normalize. | `session.ts` | Eviction/expiry test; `binds normalized required tools so padded names still apply and changed ones do not`. |
| 12 | Weak credential-content cache heuristics | Improved: more key names and token formats, host `sensitive` classification never cached. Documented in code as conservative heuristics, not a guarantee. | `optimizer-tools.ts`, `session.ts` | `optimizer.test.ts`, `session.test.ts`. |
| 13 | Model switch applied without a valid gate | Fixed: only `lower_estimated_cost_with_quality_gate` advice is applicable, never over an explicit selection. | `session.ts` | `session.test.ts`. |
| 14 | Incomplete candidate applicability details in review UI; retention disclosure | Fixed. | `Web/optimizer.js`, `Web/optimizer.css` | Browser suite (real CSS). |
| 15 | Workflow fixture stylesheet mismatch | Fixed: the fixture serves the real `Web/optimizer.css`. | `test_optimizer_workflow_ui.cjs` | Browser suite. |
| 16 | `--bundle` validated the checkout's collector instead of the selected bundle | Fixed. The selected bundle's `collector.py` is imported and exercised; import errors, `SystemExit`, syntax errors and a missing `Store` are a `collector_self_test` blocker. Malformed compose (no `proxy:` section, previously an unhandled `ValueError`) is a `private_network` blocker; non-UTF-8 or unreadable assets are an `assets_readable` blocker. No `__pycache__` is written into the bundle. | `Analytics/validate_deployment.py` | 5 new tests in `Analytics/test_deployment.py`. |
| 17 | Build/typecheck test gaps | Fixed: `npm run typecheck` now also typechecks non-hook tests (`tsconfig.tests.json`); hook tests via `typecheck:hooks` (`tsconfig.hooks-tests.json`); TypeSafe direct fixture added. Playwright pinned at 1.62.1 as a plugin dev dependency. | `Plugins/jev-optimizer` | See results. |
| 18 | Browser tests not in CI | Fixed in the workflow: installs Chromium through the plugin's pinned Playwright and runs both `scripts/tests/*.cjs` suites with `NODE_PATH` set to the plugin `node_modules`. Existing steps are retained. | `.github/workflows/test.yml` | Locally reproduced after handoff using the pinned plugin dependency; remote GitHub Actions has not run. |
| 19 | Benchmark fails obscurely on a fresh checkout | Fixed: exits 2 with `cd Plugins/jev-optimizer && npm ci && npm run build`; documented. | `scripts/benchmark-optimizer.py`, `docs/optimizer-benchmarks.md` | `test_fresh_checkout_without_compiled_engine_gets_an_actionable_error`. |
| 20 | Analytics contract drift between app and collector untested | Fixed: shared synthetic `Fixtures/analytics/report-golden.json` holds every field and all 29 counters. Swift decodes it, compares counters with `ProductAnalyticsEvent.allCases`, and compares a real uploaded payload's shape; Python parses it with the production parser and compares `FIELDS`/`COUNT_KEYS`. | `ProductAnalyticsTests.swift`, `Analytics/test_collector.py` | Both suites. |
| 21 | Task workflow documentation out of date | Updated: optional session task ID, `keys_task_start` with `client: claude-code` on writable sessions, approved library plans instead of `plan_candidates`, model inputs, recoverable stage results with fresh authorization, UTF-8 bounds. | `docs/optimizer-task-workflow.md`, `docs/product-analytics.md` | n/a |
| 22 | Live provider protocol, live Jev quality/savings, production container, dependency audit | Not addressed: outside offline scope. | n/a | n/a |

## Tests run and results

| Check | Command (each run with the required `rtk` prefix) | Result |
| --- | --- | --- |
| Full Swift suite | `CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home swift test` | 280 tests, 0 failures, 2 skipped by design (`testLiveKeychainUserPresenceGated`, `testAppleSignedBuildPassesFreshAndUpgradeValidation`) |
| Plugin typecheck | `npm run typecheck` (library + non-hook tests) | pass |
| Plugin hook typecheck | `npm run typecheck:hooks` | pass, against the locally generated, gitignored `types/claude-code.d.ts` (written by Claude Code 2.1.274 via `/plugin-types`); no typings were fabricated |
| Plugin tests | `npm test` | 8 files, 160 tests passed |
| Plugin build | `npm run build` | pass |
| Script tests | `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | 62 passed (MCP file: 23) |
| Analytics tests | `python3 -m unittest Analytics/test_collector.py Analytics/test_deployment.py` | 18 passed |
| Deployment validator | `python3 Analytics/validate_deployment.py` | no blockers; `docker_build` untested |
| Optimizer workflow browser suite | `NODE_PATH=<codex runtime>/node_modules <codex runtime>/bin/node scripts/tests/test_optimizer_workflow_ui.cjs` | passed |
| Analytics browser suite | same runtime, `scripts/tests/test_analytics_ui.cjs` | passed (exit 0; silent on success) |
| Static JS | `node --check` on `Web/app.js`, `Web/optimizer.js`, `Web/analytics.js`, both browser scripts, benchmark harness | pass |
| Strict preflight | `python3 scripts/optimizer-preflight.py --root . --strict` | `blockers: []`, `live_auth_invoked: false`, `secrets_examined: false` |
| Offline benchmark | `python3 scripts/benchmark-optimizer.py` | 5/5 structural cases correct (synthetic mock) |
| Whitespace | `git diff --check` | clean |

## Unresolved limitations

- **Pinned browser integration verified after handoff:** the integration owner ran
  `npm ci --ignore-scripts`, `npx --no-install playwright install chromium`, and both
  browser suites with `NODE_PATH` pointing to the plugin's installed dependencies.
  All succeeded. npm's install audit reported zero vulnerabilities in the dependency
  tree; this is not a full security audit. Remote GitHub Actions has not run.
- Mutation checks of the new MCP regressions were not run (declined by the
  session's permission mode). The assertions were written against exact call
  sequences, payloads and error strings instead.
- The golden fixture pins field and counter names and the value rules the
  collector enforces. It does not pin Swift-side limits that live only in
  `ProductAnalytics.swift` (for example state validation), and the uploaded
  report's `day` equality depends on the test clock's fixed UTC day.
- `load_collector` executes the selected bundle's `collector.py`. Validate only
  bundles you trust; the validator is not a sandbox.
- `operation_refused` covers every non-auth HTTP refusal (400/404/5xx,
  redirects). It is treated as recoverable only behind the fresh authorization
  check; the refusal reason itself is not further classified.
- SIGPIPE protection was verified in the process runner tests, not in the
  installed AppKit app, whose signal disposition was not examined.
- Credential detection in the read cache remains heuristic.
- Not performed: live Touch ID/Keychain and Apple-signing tests, live provider
  or Jev evaluation, live Claude hook calls, `claude plugin validate`, Docker
  build or Compose config check, collector hosting, dependency vulnerability
  audit, commit, push, signing, installation or deployment.
