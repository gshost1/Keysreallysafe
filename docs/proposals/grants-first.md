# Grants-first: agents ask, Keysrs approves

## Summary

0.14 makes Keysrs the gate agents ask keys through, not the vault they read: a
fourteen-tool stdio MCP server inside `keys`, a headless app holding the
secrets and showing Touch ID, and imports wrapping `.env` values into scoped
30-day tokens, one per project. Decisions are final; only the build split is
proposed.

**For a new user:** headless install — no window, Dock icon or menu bar item,
the usage meter hidden not removed, restorable by a setting; `keys setup` and
the installer register `keys mcp` for Claude Code, Codex, Cursor, Droid and
Claude Desktop, asking once for notification permission; background updates by
default, disableable by a setting; Spotlight, Applications, `keys dashboard` or
`open_app` shows the window; closing hides it.

**For a 0.13 user:** headless on update too — no keep-old-UI path, no offer —
and frozen identifiers in CLAUDE.md stay. New: wrapped `.env` tokens (30 days,
warned three days before expiry), `revoke_all` and `keys revoke --all`, version
0.14; site, README and Show HN wait until after the build.

## Architecture

Two processes, one binary. `keys mcp` is the stdio JSON-RPC process the agent
client launches, inside Sources/KeysCore, no new dependency unless justified;
the app holds the secrets and shows Touch ID. It reaches the app as the CLI
does: `control.json` beside the catalog (`Control.swift:16-18`) carries `port`,
`pid` and a per-launch `token` (`Control.swift:8-12`, `:27`), mode 0600 (`:29`);
requests are loopback HTTP with `X-KSF-Token` (`Control.swift:61-82`). Provider
calls go to the gateway on 127.0.0.1:12767
(`Sources/KeysCore/Gateway.swift:15`).

`request_grant` returns `pending` with an id at once; the app shows one Touch ID
prompt in its own process (`issueGrant`, `KeysService.swift:551`), and the agent
polls `grant_status` until approval delivers the token and base URL, so no call
times out.

Auto-launch is on demand for `keys mcp`, `keys wrap` and gateway clients: with
no app running — today exit 6 (`Support.swift:37-38`) — the caller opens the
bundle, waits, retries, else fails with "Keysrs isn't running".

## The tool table

Tool | Inputs | Returns | Touch ID | Network
---|---|---|---|---
`scan_project` | folder | name, file, provider, last-4, in-vault, proxyable | no | no
`check_exposure` | folder | files holding them | no | no
`import_and_wrap` | file, project | outcomes, label, expiry | yes | no
`test_keys` | keys | ok or the provider error | yes | explicit yes every time
`request_grant` | key, task, scope, caps | pending id; token via `grant_status` | yes | no
`list_keys` | none | names, providers, expiry | no | no
`grant_status` | id or all | pending; approved (token); denied; expired | no | no
`gateway_info` | none | base URL, grants, labels | no | no
`open_app` | none | ok | no | no
`check_update` | none | current, latest | no | yes
`revoke_all` | optional key | revoked counts | no | no
`activity` | window, project | per-project requests and spend | no | no
`send_feedback` | draft, destination | scrubbed draft; opens email or issue | no | no
`version` | none | app version | no | no

**No tool returns a key value.**

`scan_project` stays inside the given folder (default: agent cwd), follows no
symlinks out, caps sizes, never opens auth files, scans `.env`, `.env.local`,
`.env.production`, skipping `.env.example`.

`keys unwrap`: new CLI surface behind Touch ID, offered by uninstall; keys the
gateway cannot proxy fall back to `keys env`.

Server instructions: ask narrowly, scan before touching a file, never echo a key
or token, report a pending grant as waiting.

## Onboarding

1. `keys setup` or the installer registers `keys mcp`; the first session runs
   `scan_project`, then `check_exposure`.
2. `import_and_wrap`, with the user watching: one Touch ID imports the keys, a
   second issues the token, and the default swaps the `.env` line for the token
   plus gateway URL.
3. Token naming: the label defaults to the project's folder name — one token
   per project.
4. The Docker question: with a `docker-compose.yml` or `Dockerfile` present,
   the agent asks whether to enable Docker access; off by default.
5. The analytics question: share the onboarding counters (scans run, keys
   imported, grants issued, onboarding finished), opt-in, aggregate, off
   unless yes.

## Security

The threat model is the agent: prompt injection telling it to import a key,
request a grant or widen one.
Import, wrap, grants and tokens are minted only by the app, behind Touch ID
prompts naming what they approve
(`Sources/KeysCore/KeysService.swift:1008`). Hard rules: no tool returns a key
value; no `rm`, `rotate`, `reveal`, `copy`, `env`, long-lived-token or relay-on
tools; nothing widens a grant or skips user presence. Reads return names, paths,
counts, dates; `revoke_all` only removes capability; `test_keys` sends nothing
without a fresh explicit yes every time, never remembered.

`send_feedback` scrubs before sending: no key values, no token-prefixed strings,
no paths, no key or project names, no prompt text. The user sends it — by default
a pre-filled email to support@keysrs.com, or a GitHub issue on
gshost1/Keysreallysafe if picked (`Site/terms.html:41`); Keysrs never submits
and adds no outbound endpoint.

A relay client token is a bearer credential: while the relay is up it works
from anywhere, bounded only by scope, caps, expiry, revocation and optional
pairing. Device binding is future work.

The Docker setting: with it on, anything on the host or in a container reaching
`host.docker.internal` can present a token — the token is still the gate. The
Host check is exact loopback equality
(`Sources/KeysCore/HTTPFrame.swift:183-186`); the bind is 127.0.0.1-only
(`HTTPFrame.swift:291`).

## Proposed build split

The suggested split, unchanged. Tests stay offline-only and synthetic: fake
key-shaped strings in `.env` files, asserting no value can appear in any tool
result and the feedback scrubber works, plus a 10-minute manual end-to-end
checklist for the owner.

1. **MCP core and read tools** (no dependencies): the stdio server, five-client
   registration (Droid and Claude Desktop stdio shapes unconfirmed locally; the
   build verifies them), the pending→poll flow, the read tools, and a shortened
   `Skills/keysrs/SKILL.md` pointing at MCP. Done: an agent lists keys and
   receives a grant.
2. **Onboarding** (depends on 1): `scan_project`, `check_exposure`,
   `import_and_wrap`, `test_keys`, `keys unwrap`, the Docker question and
   setting. Done: a synthetic project imports end to end with honest skips.
3. **Headless app** (depends on 1): no window or Dock icon by default, the
   meter and menu-bar settings, reopen-to-show, on-demand auto-launch,
   notifications (expiry warnings, pending grants, kill-switch trips; permission
   at install) and background auto-update. Done: a clean install starts
   headless, auto-launches, notifies.
4. **Feedback, analytics, revoke, packaging** (depends on 1–3):
   `send_feedback` and the scrubber, the onboarding counters behind the opt-in,
   `revoke_all` and `keys revoke --all`, `activity`, the Homebrew cask for
   `gshost1/homebrew-keysrs` (DMG kept; no repo, nothing published),
   `CHANGELOG.md`, the 0.14 bump, and the checklist. Done: it runs clean; site,
   README and Show HN stay deferred.

## Facts checked in the current code

- `wrapPlan`/`wrapApply`: `KeysService.swift:1000`/`:1071`, not `EnvWrap.swift`.
  MCP-reusable: reuse `EnvWrap.swift`'s `EnvFile`/`WrapDetect`/`EnvFileWriter`
  (`EnvWrap.swift:115`, `:300`, `:396`) locally, delegating plan/apply over
  `POST /api/wrap`
  (`HTTPServer.swift:163`) as `ControlWrapBackend` does (`EnvWrap.swift:495`).
- Reopen shows the window (`Menubar.swift:208-211`); Dock icon
  `AppRuntime.swift:118` (`.regular`); no `LSUIElement` (`scripts/build-app.py:105`,
  pinned by `test_build_app.py:130`). For none by default: `.accessory`/
  `LSUIElement`, no launch-time `show()` (`Menubar.swift:193` →
  `AppWindow.swift:47-48`).
- `keys env` works with the app closed: `CLI.swift:577-607` builds an
  in-process, presence-gated service (`KeysService.swift:1968`, `:1880`), no
  control client.
- Grants scope one key, one host, methods, paths, an expiry (`Grants.swift:8`,
  `:14`, `:16`, `:18-19`, `:21`); `profile`/`unattended` are display-only (`:35`,
  `:39`). No credential has a project field (`Grants.swift:8-47`,
  `GatewayClients.swift:6-54`, `CatalogDB.swift:174-196`). One token per project
  fits the client-token model (`GatewayClients.swift:6`, `:57`), but
  listing/revoking needs a new `gateway_clients` column after the `host`
  migration (`CatalogDB.swift:192-193`); a label alone is unenforced
  (`KeysService.swift:1132`). Profiles bound issuance (`Profiles.swift:12`).
- Updates: manual check (`AppWindow.swift:75` → `:142`) or an opt-in, default-off
  24-hour timer (`:76`, `:133-140`); install is always modal (`:161-179`).
  Background install adds a modal-free path ending in quit and relaunch
  (`AppUpdater.swift:324-402`).
- Droid's MCP registry is `~/.factory/mcp.json` (`{"mcpServers": {...}}`), not
  the `settings.json` `customModels` `keys setup` writes (`AgentSetup.swift:246-253`);
  `droid mcp add --type stdio` registers one, but its stdio key names are
  unconfirmed locally. No secret is printed.
- Claude Code `~/.claude.json` `mcpServers` (`type`/`command`/`args`/`env`);
  Codex `~/.codex/config.toml` `[mcp_servers.<name>]` (`command`/`args`/optional
  `env`); Cursor `~/.cursor/mcp.json`
  `{"mcpServers":{"<name>":{"command":…,"args":[…]}}}`, no `type` key —
  confirmed locally. Claude Desktop's path
  `~/Library/Application Support/Claude/claude_desktop_config.json` is
  confirmed, its shape unconfirmed.
- `keys unwrap` does not exist today. Keys the gateway cannot proxy fall back to
  `keys env`: providers marked `"gateway": false` (`Web/providers.json:470`,
  `:478`, `:493` — Bedrock, Vertex, watsonx; `Providers.swift:12`, `:96`) are
  skipped by `wrapPlan` (`KeysService.swift:1025`).

## Open questions

- **Where quit and the relay toggles live once the menu bar item is hidden** —
  today only there (`Menubar.swift:491`, `:519`). Recommended: the dashboard's
  Settings, status item behind the setting.
- **What defines a "project"** for one token per project. Recommended: the first
  `scan_project` folder name, a new `gateway_clients` column.
- **When background install runs and whether it restarts at once** — every
  install ends in quit and relaunch. Recommended: install on the daily check,
  relaunch at once, notify.
- **Whether `keys unwrap` needs the app running** — `keys wrap` does.
  Recommended: follow `keys env` (in-process); it only reads and rewrites.
