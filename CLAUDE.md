# Keysrs (formerly Keysreallysafe)

The product is called Keysrs since 2026-09-23 and every user-facing string
says so. Deliberately unchanged, because existing installs depend on them:
the `keys` executable, the signing identifier `keysreallysafe` and its
designated requirement, the Keychain service `keysreallysafe`, the launchd
label `com.keysreallysafe.menubar`,
`~/Library/Application Support/Keysreallysafe/`, the status item autosave
name `Keysreallysafe.usage`, the Swift package/target names and the GitHub
repo `gshost1/Keysreallysafe`. Don't rename those without a migration.

The experimental optimizer (Jev plugin, Optimizer pane, `keys optimizer`) was
removed after 0.9.1. Because 0.9.0 and 0.9.1 are public, purge still deletes
the retired Keychain service `keysreallysafe.optimizer` and the `optimizer/`
directory next to the catalog, the installer keeps `Plugins` and `scripts` in
its parts list so upgrade and uninstall clear what those versions installed,
and the analytics vocabulary keeps the `optimizer_*`, `context_*` and
`view_optimizer` counters so stored reports still decode.

Local Mac usage meter and API-key vault. Reads the usage files Claude Code,
Codex and Grok already write, shows plan windows and estimated spend in a menu
bar item and a loopback dashboard, and keeps API secrets in the macOS Keychain
behind Touch ID and scoped gateway grants. It is not an AI subscription and
never supplies provider credits; customers use their own provider accounts.

Swift 6 package, macOS 14+. Executable `keys`, core in `Sources/KeysCore`,
tests in `Tests/KeysreallysafeTests`. `Web/` is the local dashboard (plain
HTML/CSS/JS, no build step, no external resources), not a marketing site.
`Analytics/` is the self-hosted aggregate collector.
`Fixtures/` holds synthetic session logs and the price table; the provider catalog is `Web/providers.json`.
`Site/` is the public marketing site at https://keysrs.com (static; the only script is `Site/posthog.js`, and Google Fonts is the only external resource). It is served by a
Cloudflare Worker with static assets (`wrangler.jsonc`, name `keysrs`,
custom domains keysrs.com and www.keysrs.com); deploy with `npx wrangler
deploy` after `wrangler login`. Support mail is support@keysrs.com via
Cloudflare Email Routing. PostHog (US cloud, project key in `Site/posthog.js`, a
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
./.build/debug/keys dashboard   # dev copy on :12765, serves Web/ from the checkout
python3 scripts/build-app.py    # release build assembled and signed as Keysrs.app
```

One binary: `keys` with no arguments (or launched by LaunchServices) is the
app, with arguments it is the CLI. App mode refuses to run outside a `.app`
bundle, so test the window, login item and migration from a built
`Keysrs.app`, not `.build/*/keys`. The bundle layout, Info.plist values and
signing command are fixed in `docs/release.md`; keep the bundle's code
signing identifier `keysreallysafe` (`codesign -d -r-` must print the 0.9.2
designated requirement) or the Keychain stops trusting it.

Dashboard browser tests need Playwright, pinned in `scripts/tests/package.json`:
`cd scripts/tests && npm ci && npx --no-install playwright install chromium`,
then `NODE_PATH=scripts/tests/node_modules node scripts/tests/test_keys_dashboard_ui.cjs`
(`KEYS_UI_ONLY=<test name>` narrows it). `.github/workflows/test.yml`
is the full list CI runs; match it before claiming a change is verified.

Tests must stay offline: no keychain, Touch ID, clipboard, provider calls or
real credentials. Use `CLAUDE_CONFIG_DIR=Fixtures/claude-home` and
`GROK_HOME=Fixtures/grok-home` as CI does.

## Installed copy vs checkout

From 0.10.0 the running app is `/Applications/Keysrs.app` (bundle id
`com.keysreallysafe.keysrs`, signing identifier `keysreallysafe`),
executable `Contents/MacOS/keys`, with `Web/` and `Fixtures/` under
`Contents/Resources`. It starts at login through `SMAppService.mainApp`
(Start at Login in the Keysrs menu), not a launchd agent. The window loads
the dashboard from `http://127.0.0.1:12766/`, the gateway is `:12767`, and
data plus `menubar.log` stay in `~/Library/Application Support/Keysreallysafe/`.
`keys` on PATH is normally the `~/.local/bin/keys` symlink into the bundle
(Install Command Line Tool…).

Building the checkout does not change it; installing means
`scripts/build-app.py`, then replacing `/Applications/Keysrs.app` and
opening it. Compare SHA-256 of the built bundle's `Contents/MacOS/keys` and
the installed one to confirm. Don't quit and relaunch the app to "test" a
menu bar fix without collecting evidence first (`menubar.log`, a process
sample).

0.9.x ran as the launchd agent `com.keysreallysafe.menubar` from
`Application Support/Keysreallysafe/bin/keys`. That label and the plist path
stay frozen because the app's first-launch migration and
`keys autostart --remove` look for them to boot the agent out and delete
`bin/`, `Web/`, `Fixtures/`, `Plugins/` and `scripts/`. The migration leaves
the catalog, preferences, logs and `.previous/` alone; `--remove` also
deletes `.previous/`.

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
  as if measured.

## Licensing

MIT (root `LICENSE`, since 2026-09-24; the 2026-09-22 proprietary notice
is withdrawn). `licenses/Keysreallysafe-legacy-MIT.txt` and
`THIRD_PARTY_NOTICES.md` must stay intact and ship in every package
(`scripts/prepare-release.py` and its test enforce this; `docs/release.md`
describes the packager).

## Distribution

Free, decided 2026-09-24: no trial, license key, payments or legal entity.
0.9.0 removed the license gate that 0.6–0.8 shipped; don't reintroduce
anything that phones home. keysrs.com is static (no Worker code, no D1).
The Stripe account stays open but idle (kept on purpose, 2026-09-24): the
Payment Link is deactivated, the webhook deleted and the restricted key
expired. The license D1 database is deleted and Workers Paid ends 2026-10-23.

## Conventions

- Match the existing style: comments explain why, not what; commit messages
  are a subject line and a short prose body naming the observed problem.
- `git status` before staging; keep unrelated work in separate commits.
- Read `docs/menubar-recovery.md` before touching `MenubarItemController.swift`:
  the original disappearance was never reproduced, so recovery is a
  mitigation, not a proven fix.
- Long docs and fixtures: read with `offset`/`limit`, don't dump them.
