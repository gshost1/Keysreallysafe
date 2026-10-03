# Dashboard testing with tester-army

Approach: Codex-only, using the real dashboard assets against the existing synthetic in-memory fixture server. The macOS app requires Keychain and user presence, so browser tests must never target the installed app or its vault. The existing Swift backend contract gate separately verifies the production API and service with injected memory secrets, presence and clipboard boundaries.

From `scripts/tests`, run `npm ci`, `npx --no-install playwright install chromium`, then `npm run test:e2e`. Node 22.12 or newer is required. Dependencies are pinned: e2e 0.16.0, @e2e-dev/web 0.11.2, Playwright 1.63.0 (the web engine requires >=1.63).

The runner starts and stops its own fixture process, binds only 127.0.0.1 on an allocated port, and resets state before every test. One worker prevents shared fixture writes racing. CLI telemetry is disabled by the npm script. No model, provider login, credentials, personal usage logs, Keychain, Touch ID or clipboard is needed. All typed values are invented fixture values. The reset endpoint exists only in the standalone fixture process, never the application API.

The marketing config serves `Site/` locally, checks homepage anchor navigation, the three frozen release-download URLs, privacy, terms and the home link. It removes Google Fonts links and replaces PostHog with an empty fixture script. External links are inspected without navigating or downloading.

Flows cover key creation, metadata edit, confirmed deletion, reveal cleanup, successful rotation, duplicate rejection, gateway usage and unknown cost semantics. `.e2e/report.json` and per-attempt evidence remain local and ignored by Git. CI runs this suite alongside the existing browser reliability and real Swift backend contract gates.

References: https://e2e.tester.army/docs/quickstart, https://e2e.tester.army/docs/starting-your-app, https://e2e.tester.army/docs/api-testing.

The web engine refuses reading password field values. This suite checks successful rotation and dialog closure; the existing 58-case Playwright suite directly checks secure input cleanup with synthetic values.

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
