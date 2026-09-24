# Keysrs (formerly Keysreallysafe)

The product is called Keysrs since 2026-09-23 and every user-facing string
says so. Deliberately unchanged, because existing installs depend on them:
the `keys` executable, the signing identifier `keysreallysafe` and its
designated requirement, the Keychain services `keysreallysafe` and
`keysreallysafe.optimizer`, the launchd label `com.keysreallysafe.menubar`,
`~/Library/Application Support/Keysreallysafe/`, the status item autosave
name `Keysreallysafe.usage`, the Swift package/target names and the GitHub
repo `gshost1/Keysreallysafe`. Don't rename those without a migration.

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
`Site/` is the public marketing site at https://keysrs.com (static, no
scripts; Google Fonts is the only external resource). It is served by a
Cloudflare Worker with static assets (`wrangler.jsonc`, name `keysrs`,
custom domains keysrs.com and www.keysrs.com); deploy with `npx wrangler
deploy` after `wrangler login`. Support mail is support@keysrs.com via
Cloudflare Email Routing. PostHog (US cloud, project key in the pages, a
public client token) counts page views and download clicks, cookieless,
no session replay; privacy.html describes exactly that and must stay true.
Download links point at the latest GitHub release's `Keysrs-arm64.dmg`.

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
- Product analytics (v2, "share to compare") is opt-in and aggregate: daily
  counters, token totals per tool/provider/public model, gateway totals and
  plan-window peaks, sent to https://analytics.keysrs.com (the collector on
  the home Ubuntu server behind a Cloudflare Tunnel). Prompt content,
  credentials, key/project/session names, paths, dollar amounts, exact times
  and persistent identifiers must never enter it; non-public model and
  provider ids become "unknown"/"other". Schema and exclusions:
  `docs/product-analytics.md`, `Analytics/README.md`.
- No fake numbers: untracked quota is shown as "not tracked", never estimated
  as if measured. Don't promise optimizer savings; it is experimental.

## Licensing

MIT (root `LICENSE`, since 2026-09-24; the 2026-09-22 proprietary notice
is withdrawn). `licenses/Keysreallysafe-legacy-MIT.txt`,
`Plugins/jev-optimizer/LICENSE` and `THIRD_PARTY_NOTICES.md` must stay intact
and ship in every package (`scripts/prepare-optimizer-release.py` and its
test enforce this). The plugin package is `private: true`; never publish it
to npm.

## Distribution

Free, decided 2026-09-24: no trial, license key, payments or legal entity.
0.9.0 removed the license gate that 0.6–0.8 shipped; don't reintroduce
anything that phones home. keysrs.com is static (no Worker code, no D1).
The Stripe account and Payment Link are the owner's to deactivate in the
Stripe dashboard; the repo no longer references them.

## Conventions

- Match the existing style: comments explain why, not what; commit messages
  are a subject line and a short prose body naming the observed problem.
- `git status` before staging; keep unrelated work in separate commits.
- Read `docs/menubar-recovery.md` before touching `MenubarItemController.swift`:
  the original disappearance was never reproduced, so recovery is a
  mitigation, not a proven fix.
- Long docs and fixtures: read with `offset`/`limit`, don't dump them.
