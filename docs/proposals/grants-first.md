# Grants-first: agents ask, Keysrs approves

## Summary

0.14 makes Keysrs the gate an agent asks for keys through, not the vault it
reads from: a stdio MCP server with fourteen tools inside the `keys` binary,
a headless app that alone holds secrets and shows Touch ID, imports that wrap
`.env` values into scoped 30-day tokens, one token per project. Decisions
below are final; only the build split is proposed.

**For a new user:** headless install — no window, no Dock icon, no menu bar
item, the usage meter hidden, not removed, with a setting to turn it back
on; `keys setup` and the installer register `keys mcp` for Claude Code, Codex,
Cursor, Droid and Claude Desktop, ask once for notification permission,
background updates by default, a setting turns that off; Spotlight,
Applications, `keys dashboard` or `open_app` shows the window, and closing it
hides the app.

**For a 0.13 user:** headless on update too — no keep-old-UI path, no offer
— and every frozen identifier in CLAUDE.md stays. New: wrapped `.env` tokens
(30 days, warned three days before expiry), `revoke_all` and
`keys revoke --all`, version 0.14; site, README and Show HN wait until after
the build.

## Architecture

Two processes, one binary. `keys mcp` is the stdio JSON-RPC process the
agent client launches — inside Sources/KeysCore, no new dependency unless a
mission justifies one — and the app process holds the secrets and alone
shows Touch ID. It reaches the app the way the CLI does: `control.json`
beside the catalog carries `port`, `pid` and a per-launch `token`, mode 0600
(Sources/KeysCore/Control.swift:16-18, :29); requests are loopback HTTP with
`X-KSF-Token` (Sources/KeysCore/Control.swift:61-82). Provider calls go to
the gateway on 127.0.0.1:12767 (Sources/KeysCore/Gateway.swift:15).

`request_grant` never blocks on a fingerprint: it posts the request, returns
`pending` with an id at once, the app shows its one Touch ID prompt in its
own process (`issueGrant`, Sources/KeysCore/KeysService.swift:551), and the
agent polls `grant_status` until approval delivers the scoped token and
base URL. Every prompt the tools wait on uses the same pending→poll
pattern, so no call times out while Touch ID is on screen.

Auto-launch is on demand for `keys mcp`, `keys wrap` and gateway clients:
with no app running — today exit 6 (Sources/KeysCore/Support.swift:37-38) —
the caller opens the bundle, waits, retries, else fails with a clear
"Keysrs isn't running" error.

## The tool table

| Tool | Inputs | Returns | Touch ID | Network |
|---|---|---|---|---|
| `scan_project` | folder | name, file, provider, last-4, in-vault, proxyable | no | no |
| `check_exposure` | folder | tracked files holding those values | no | no |
| `import_and_wrap` | file, project | outcomes, label, expiry; rewrites the file | yes | no |
| `test_keys` | keys | ok or the provider's error | yes | yes, gated |
| `request_grant` | key, task, scope, caps | pending id; token and base URL via `grant_status` | yes | no |
| `list_keys` | none | names, providers, expiry — never values | no | no |
| `grant_status` | id or all | pending; approved (token, scope); denied; expired | no | no |
| `gateway_info` | none | base URL, live grants, token labels | no | no |
| `open_app` | none | ok; window shows | no | no |
| `check_update` | none | current, latest | no | yes |
| `revoke_all` | optional key | revoked counts | no | no |
| `activity` | window, project | requests and spend per project, as tracked | no | no |
| `send_feedback` | draft, destination | scrubbed draft; opens email or issue | no | no |
| `version` | none | app version | no | no |

**No tool returns a key value.**

`scan_project` stays inside the given folder (default: agent cwd), follows
no symlinks out, caps sizes and counts, never opens auth files, scans `.env`,
`.env.local` and `.env.production`, and skips `.env.example`.

`keys unwrap` is new CLI surface behind Touch ID, offered by uninstall; keys
the gateway cannot proxy fall back to `keys env`.

Server instructions: ask narrowly, scan before touching a file, never echo
a key or token, report a pending grant as waiting on the user.

## Onboarding

1. `keys setup` or the installer registers `keys mcp`; the first session
   runs `scan_project`, then `check_exposure`.
2. `import_and_wrap`, with the user watching: one Touch ID imports the keys,
   a second issues the token, and the default swaps the `.env` line for the
   token plus the gateway base URL.
3. Token naming: the label defaults to the project's folder name — one token
   per project.
4. The Docker question: with a `docker-compose.yml` or `Dockerfile` present,
   the agent asks whether to enable Docker access; off by default.
5. The analytics question: the user is asked whether to share the onboarding
   counters — scans run, keys imported, grants issued, onboarding finished;
   opt-in and aggregate, off unless yes.

## Security

The threat model is the agent itself: prompt injection telling it to import
a key, request a wide grant or widen one. Structurally: import, wrap, grants
and tokens are minted only by the app, behind Touch ID prompts that name
exactly what they approve (Sources/KeysCore/KeysService.swift:1008). Hard
rules: no tool returns a key value; no `rm`, `rotate`, `reveal`, `copy`,
`env`, long-lived-token or relay-on tools; nothing widens a grant or skips
user presence. The read tools return names, paths, counts and dates;
`revoke_all` only removes capability; `test_keys` sends nothing without an
explicit yes, every time.

`send_feedback` scrubs before anything leaves: no key values, no
token-prefixed strings, no paths, no key or project names, no prompt text.
The user sends it — a pre-filled email to support@keysrs.com by default, or
a GitHub issue on gshost1/Keysreallysafe; Keysrs never submits anything and
adds no outbound endpoint (the standing rule, Site/terms.html:41).

A relay client token is a bearer credential: while the relay is up it works
from anywhere, bounded only by scope, caps, expiry, revocation and optional
pairing. Device binding is future work, not 0.14.

The Docker setting: with it on, anything on the host or in any container
that can reach `host.docker.internal` on that port can present a token — the
token is still the gate. Today the Host check is exact loopback equality
(Sources/KeysCore/HTTPFrame.swift:183-186) and the bind is 127.0.0.1-only
(Sources/KeysCore/HTTPFrame.swift:291).

## Proposed build split

The suggested split, unchanged. Tests stay offline and synthetic, with
fake key-shaped strings, asserting no value can appear in any tool result
and that the scrubber works.

1. **MCP core and read tools** (no dependencies): the stdio server,
   five-client registration (Droid and Claude Desktop stdio entry shapes
   unconfirmed locally; the build verifies them), the pending→poll grant
   flow, the read tools, and `Skills/keysrs/SKILL.md` shortened to point at
   it. Done: an agent lists keys and receives a grant.
2. **Onboarding** (depends on 1): `scan_project`, `check_exposure`,
   `import_and_wrap`, `test_keys`, `keys unwrap`, the Docker question and
   setting. Done: a synthetic project imports end to end with honest skip
   reasons.
3. **Headless app** (depends on 1): no window or Dock icon by default, the
   meter and menu-bar settings, reopen-to-show, on-demand auto-launch,
   notifications for expiry warnings, pending grants and kill-switch trips
   (permission asked at install), and background auto-update. Done: a clean
   install starts headless, auto-launches and notifies.
4. **Feedback, analytics, revoke, packaging** (depends on 1–3):
   `send_feedback` and the scrubber, the onboarding counters behind the
   opt-in, `revoke_all` and `keys revoke --all`, `activity`, the Homebrew
   cask for `gshost1/homebrew-keysrs` (DMG kept; no repo created, nothing
   published), `CHANGELOG.md`, the 0.14 bump, and the 10-minute manual
   checklist. Done: the checklist runs clean; site, README and Show HN stay
   deferred.
