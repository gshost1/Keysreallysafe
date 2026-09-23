# Keysreallysafe

Local Mac usage meter and API-key vault. Reads the usage files Claude Code,
Codex and Grok already write, shows plan windows and estimated spend in a menu
bar item and a loopback dashboard, and keeps API secrets in the macOS Keychain
behind Touch ID and scoped gateway grants. It is not an AI subscription and
never supplies provider credits; customers use their own provider accounts.

Swift 6 package, macOS 14+. Executable `keys`, core in `Sources/KeysCore`,
tests in `Tests/KeysreallysafeTests`. `Web/` is the local dashboard (plain
HTML/CSS/JS, no build step, no external resources), not a marketing site.
`Plugins/jev-optimizer` is the optional, experimental optimizer (TypeScript,
imported MIT code). `Analytics/` is the self-hosted aggregate collector.
`Fixtures/` holds synthetic session logs, the price table and provider catalog.

## Build and test

```sh
swift build                     # debug; `make build` also codesigns
swift build -c release
swift test                      # synthetic fixtures only, no network
swift test --filter Menubar     # one area
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/optimizer-preflight.py --root . --strict
./.build/debug/keys dashboard   # dev copy on :12765, serves Web/ from the checkout
```

Dashboard browser tests need the plugin's Playwright:
`cd Plugins/jev-optimizer && npm ci && npx --no-install playwright install chromium`,
then `NODE_PATH=Plugins/jev-optimizer/node_modules node scripts/tests/test_keys_dashboard_ui.cjs`
(`KEYS_UI_ONLY=<test name>` narrows it). Plugin checks: `npm run typecheck`,
`npm test`, `npm run build` in `Plugins/jev-optimizer`. `.github/workflows/test.yml`
is the full list CI runs; match it before claiming a change is verified.

Tests must stay offline: no keychain, Touch ID, clipboard, provider calls or
real credentials. Use `CLAUDE_CONFIG_DIR=Fixtures/claude-home` and
`GROK_HOME=Fixtures/grok-home` as CI does.

## Installed copy vs checkout

The running app is the launchd agent `com.keysreallysafe.menubar`, executable
`~/Library/Application Support/Keysreallysafe/bin/keys` with sibling `Web/`,
`Fixtures/` and `menubar.log`. Dashboard `http://127.0.0.1:12766/`, gateway
`:12767`. There is no `.app` bundle. Building the checkout does not change it;
installing means `scripts/sign-local.py` on the release binary, then
`keys autostart` with `KEYS_WEB_ROOT` pointing at the installed `Web/` so
installed assets survive. Compare SHA-256 of `.build/release/keys` and the
installed binary to confirm. Don't restart the agent to "test" a menu bar fix
without collecting evidence first (`menubar.log`, a process sample).

Signing uses a stable local team identity (`StableSigning.swift`,
`SIGNING.md`); a locally signed install is not a notarized release. Don't
describe a build as notarized or published unless the release process ran.

## Privacy and security rules

The README's "Privacy boundaries" section is the contract. In short:

- Everything binds to `127.0.0.1`. No scraping, no provider websites, never
  read `~/.codex/auth.json` or `~/.grok/auth.json`.
- Key values never appear on screen, in logs, in tests or in fixtures. Copy,
  reveal, env and rotate require user presence every time.
- Gateway requests need a grant: one Touch ID, one key, one host, method/path
  scope, expiry. Request bodies never reach the usage catalog.
- Product analytics is opt-in, aggregate counters only, and currently has no
  upload destination. Prompt content, credentials, provider/key/project
  names, paths and persistent identifiers must never enter it. Schema and
  exclusions: `docs/product-analytics.md`, `Analytics/README.md`.
- No fake numbers: untracked quota is shown as "not tracked", never estimated
  as if measured. Don't promise optimizer savings; it is experimental.

## Licensing

New first-party work is proprietary (root `LICENSE`). Earlier MIT grants
cannot be withdrawn: `licenses/Keysreallysafe-legacy-MIT.txt`,
`Plugins/jev-optimizer/LICENSE` and `THIRD_PARTY_NOTICES.md` must stay intact
and ship in every package (`scripts/prepare-optimizer-release.py` and its
test enforce this). Never claim historic or third-party code is proprietary.
The customer EULA and rights-holder identity are still open; see
`docs/licensing-transition.md`. The plugin package is `private: true`; never
publish it to npm.

## Commercial state

The repo is public. Pricing, trial policy, billing model, business country,
support contact, refund terms and domain are all undecided; don't invent
them in docs, the dashboard or a website. Cloudflare Pages was chosen for a
future marketing site and Stripe for checkout, but nothing has been created.

## Conventions

- Match the existing style: comments explain why, not what; commit messages
  are a subject line and a short prose body naming the observed problem.
- `git status` before staging; keep unrelated work in separate commits.
- Read `docs/menubar-recovery.md` before touching `MenubarItemController.swift`:
  the original disappearance was never reproduced, so recovery is a
  mitigation, not a proven fix.
- Long docs and fixtures: read with `offset`/`limit`, don't dump them.
