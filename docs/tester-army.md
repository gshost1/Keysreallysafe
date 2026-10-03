# Dashboard testing with tester-army

Approach: Codex-only, using the real dashboard assets against the existing synthetic in-memory fixture server. The macOS app requires Keychain and user presence, so browser tests must never target the installed app or its vault. The existing Swift backend contract gate separately verifies the production API and service with injected memory secrets, presence and clipboard boundaries.

From `scripts/tests`, run `npm ci`, `npx --no-install playwright install chromium`, then `npm run test:e2e`. Node 22.12 or newer is required. Dependencies are pinned: e2e 0.16.0, @e2e-dev/web 0.11.2, Playwright 1.63.0 (the web engine requires >=1.63).

The runner starts and stops its own fixture process, binds only 127.0.0.1 on an allocated port, and resets state before every test. One worker prevents shared fixture writes racing. CLI telemetry is disabled by the npm script. No model, provider login, credentials, personal usage logs, Keychain, Touch ID or clipboard is needed. All typed values are invented fixture values. The reset endpoint exists only in the standalone fixture process, never the application API.

The marketing config serves `Site/` locally, checks homepage anchor navigation, the three frozen release-download URLs, privacy, terms and the home link. It removes Google Fonts links and replaces PostHog with an empty fixture script. External links are inspected without navigating or downloading.

Flows cover key creation, metadata edit, confirmed deletion, reveal cleanup, rotation payload and persisted replacement, duplicate rejection, gateway usage and unknown cost semantics. `.e2e/report.json` and per-attempt evidence remain local and ignored by Git. CI runs this suite alongside the existing browser reliability and real Swift backend contract gates.

References: https://e2e.tester.army/docs/quickstart, https://e2e.tester.army/docs/starting-your-app, https://e2e.tester.army/docs/api-testing.

The web engine refuses reading password field values. This suite checks rotation payload and persisted replacement and dialog closure; the existing 58-case Playwright suite directly checks secure input cleanup with synthetic values.

## Validation evidence

Validated 2026-10-02 on macOS arm64, isolated worktree `/tmp/keysrs-tester-army`, branch `test/tester-army-keysrs`. All commands below were run through `rtk proxy`.

- `cd scripts/tests && npm run test:e2e`: dashboard 4/4 and marketing 1/1 passed. Final dashboard run `01a10020-5101-78b3-ad76-7d2144d25851` (10.60 s); marketing run `01a10020-80a7-744b-b3d5-f77cc2875387` (3.38 s). Both servers started on allocated loopback ports and stopped by the runner.
- `swift test` with CLAUDE_CONFIG_DIR, GROK_HOME and GROK_BOT_HOME pointing at this worktree's Fixtures: 276 executed, 2 expected skips (opt-in browser contract and local signing), 0 failures.
- `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=/tmp/keysrs-tester-army/scripts/tests/node_modules swift test --jobs 2 --filter BackendContractUITests`, with the same fixture environment: 1 XCTest passed, 9 real dashboard/backend flows passed; no analytics calls, real clipboard or Keychain access.
- `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs`: all 58 cases passed on Playwright 1.63.0.
- `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_analytics_ui.cjs`: exit 0.
- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`: 35 passed.
- `python3 -m unittest Analytics/test_collector.py`: 18 passed.
- `git diff --check`: clean.

Initial tester-army runs identified integration errors (default test glob, trailing slash in app.baseUrl and unsupported chained locator). These were corrected in the test integration. Its secure-field read policy rejected a password-value assertion; that assertion was replaced with rotation success/dialog closure while the existing offline Playwright regression verifies field cleanup. No reproducible product defect was found, so production app code was not changed.


Independent Luna 6 verification passed dashboard 4/4, marketing 1/1 and `git diff --check`; no concrete regression found.

## Rotation coverage follow-up (2026-10-02)

Astra identified that the original browser fixture returned success without storing the replacement and always revealed the seeded constant. The fixture now keeps per-key synthetic secrets outside list metadata, validates that rotation contains a nonempty string, captures accepted rotation bodies in memory and serves the persisted value on reveal. Its audit endpoint exists only in standalone fixture mode.

The tester-army test types a distinct invented replacement, asserts exactly one alpha rotation with exactly that submitted body, reloads the page, then opens and closes reveal twice and checks the replacement both times. A missing or incorrect payload cannot pass the body assertion and persisted-value checks. Password-field values remain unread; no framework policy is bypassed.

Validation in `/tmp/keysrs-tester-army` (all commands through `rtk proxy`):

- `npm run test:e2e` in `scripts/tests`: dashboard 4/4 passed (run `01a1006a-de6f-7aea-81a1-3cc543311a58`, 6.66 s); marketing 1/1 passed (run `01a1006a-fc8d-78ad-8d93-5a17c8fa346d`, 3.05 s). Existing pinned local dependencies were used; no install or provider call was required.
- `KEYS_BACKEND_CONTRACT_UI=1 NODE_PATH=/tmp/keysrs-tester-army/scripts/tests/node_modules swift test --jobs 2 --filter 'BackendContractUITests|KeyLifecycleAndDedupTests'`, with CLAUDE_CONFIG_DIR, GROK_HOME and GROK_BOT_HOME pointing to this worktree's Fixtures: 14 XCTest cases passed, zero failures. This independently covers real service rotation presence/version behavior and real API token/non-echo behavior. The backend browser contract separately passed its 9 existing flows; that browser contract does not test rotation.
- `NODE_PATH=scripts/tests/node_modules KEYS_UI_ONLY=rotate node scripts/tests/test_keys_dashboard_ui.cjs`: existing rotation failure/retry/cleanup regression passed.
- `git diff --check`: clean.

This follow-up strengthens synthetic browser evidence; it does not claim that the browser fixture is native Keychain storage. Production code and app data remain unchanged. Awaiting focused Astra recheck before committing.
