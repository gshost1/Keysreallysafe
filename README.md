# Keysreallysafe

A local spend meter and API-key vault for the AI command-line tools on your Mac.

It reads the usage numbers that Claude Code, Grok and Codex already write to
your home folder, prices them from a checked-in list-price table, and shows the
result on a loopback web page and in the menu bar. Secrets live in the macOS
Keychain, and the app asks for Touch ID before it reads one out. Nothing
leaves the machine.

## What it never does

- No cloud. The site and the API bind to `127.0.0.1` only.
- No scraping. It does not open provider websites, cookies or browser sessions.
- No message text. Only token counts, model names, timestamps and the working
  directory are stored. A test proves that request bodies routed through the
  gateway never reach disk.
- No credentials from other tools. `~/.codex/auth.json` and
  `~/.grok/auth.json` are never read.
- No fake numbers. A provider whose remaining quota is not in a local file is
  listed as "not tracked" with a link to its own dashboard.
- No secret on screen by default. The key list shows names, never values.
  Copy, reveal, env and rotate ask for user presence every time.

## Install

Requires macOS and Swift.

```sh
git clone <this repo> && cd Keysreallysafe
swift build
./scripts/codesign.sh .build/debug/keys
./.build/debug/keys autostart
```

`keys autostart` installs a per-user login item that serves the site at
`http://127.0.0.1:12766/` and puts a spend sparkline in the menu bar. Re-run it
after every build; the login item serves a snapshot. Put `.build/debug/keys`
on your `PATH` as `keys` for the commands below.

Remove everything with `keys autostart --remove` (login item and snapshot) and
`keys purge` (catalog and every Keychain item, after Touch ID).

## The site

Three panes, switched with the segmented control or `⌘1` / `⌘2` / `⌘3`.

**Usage** is the first thing you see: the plan windows each tool reports
locally, as `plan · % used · resets in`. Claude and Codex have a 5-hour and a
weekly window, Grok a weekly one. Tools whose quota is not in any local file
sit in a collapsed "not tracked" group with a link to their own dashboard. One
quiet line underneath gives this month's local dollars.

**Chart** starts on today by hour and switches to this week or this month by
day (`D` / `W` / `M`). Chips narrow it to Grok, Claude or OpenAI; `T` flips
tokens and USD. The model list under the chart shows every model by default;
click one to see it alone. Dollar figures for Claude and Codex are estimates
from list prices and are labelled as such; Grok's dollars come from its own
cost log. With the Claude chip selected, `P` switches the breakdown to
projects. `X` downloads the rows as CSV, `⇧C` copies the totals line as
Markdown.

**Keys** is a dense table: name, provider, kind, created, last used, dollars
routed through the gateway this month. Actions
per row: Copy (`C`, clipboard wipes itself after 20 s), Reveal (`V`, hides
after 15 s), Edit (`E`, provider, kind and notes; name and secret are
immutable), History (`H`, the audit log), Rotate (`R`, new secret under the
same name), Gateway (`G`) and Delete (`⌫`). `N` adds a key; the provider
picker is grouped into Labs, Routers, Hosts, Clouds and Non-chat, and a pasted
secret with a recognisable prefix pre-fills it. `?` lists every shortcut.

Every request the page makes is same-origin. Mutating calls carry a token the
server generates per launch. That token is a browser CSRF defense: it stops a
web page you have open from driving the dashboard. It is not authentication
of local processes. Any program running as you can fetch `index.html`, read
the token and edit key metadata (provider, kind, notes). What stands between
such a program and a secret is the presence prompt on copy, reveal, env,
rotate and delete, not the token.

## The vault

`keys add` stores a secret in the macOS Keychain under the service
`keysreallysafe`, tied to your login. The catalog keeps only the name,
provider, kind, notes and timestamps; the value never enters SQLite, a log,
the page, or the API response for the key list.

Getting a value back asks for user presence, Touch ID or your login password.
The prompt is the app's own (LocalAuthentication before an ordinary Keychain
read); the Keychain item itself carries no access-control attribute, because
an ad-hoc signed command-line tool cannot use one. A properly signed and
entitled helper is the way to make the OS enforce presence per item, and that
is not yet done. Treat this as app-level prompting:

- `keys copy` puts it on the clipboard and wipes the clipboard 20 seconds
  later. Reveal on the site hides it again after 15 seconds.
- `keys env <name> VAR -- <command>` hands it to one child process as an
  environment variable, so it never touches the clipboard at all.
- `keys rotate` swaps in a new value under the same name and bumps a version.
- Delete and purge also require presence, so a script on the machine cannot
  quietly empty the vault.

Every read, copy, env use, rotate, gateway call, gateway denial, client issue
and delete is written to a per-key audit log you can open from the Keys pane.
The gateway, when you turn it on for a key, keeps the value in process memory
only and forgets it on restart.

## The gateway

Turn the gateway on for a key (one Touch ID), issue a client capability for
the program that will call it (one more Touch ID), and point the SDK at the
gateway with that capability where the SDK expects the API key:

```sh
keys client issue <key name> --label "my script" --days 30 --method POST --path-prefix v1/messages
# prints ksfc_… once; the catalog keeps only its hash
export ANTHROPIC_BASE_URL=http://127.0.0.1:12767/<key name>
export ANTHROPIC_API_KEY=ksfc_…
```

A request without a valid client gets 401 before the gateway even looks the
key up, so being on loopback proves nothing by itself. A client is bound to
one key, expires (default 30 days, at most 365), can be revoked with
`keys client revoke`, and can be limited to HTTP methods and an upstream path
prefix. The dashboard's per-launch token is never accepted as a client. This
narrows accidental or unauthorized local use; it is not a boundary against a
process that can already read your files or memory.

The gateway forwards to the provider host from `Web/providers.json`, replaces
the client capability with the secret in the right header, streams the
response back, and records the `usage` object from OpenAI chat-completions
and responses, Anthropic messages and Gemini bodies, plus the upstream
`request-id`. Those calls show up as a "Via gateway" column in Keys and can
be charted per key. A call that no model or price could be attached to is
shown as unpriced, never as $0. The secret is held in process memory only
while the gateway is on and is forgotten on restart. Providers that need
request signing or OAuth (Bedrock, Vertex, watsonx) cannot be proxied and say so.

Gateway dollars are a separate ledger from the local-log estimate. A Claude
Code or Codex call routed through the gateway appears in both places; when
the gateway's `request-id` matches a local event the local one wins and the
gateway copy is dropped, and otherwise the two totals are shown side by side
rather than added.

For an OpenRouter key of kind `billing` with the gateway on, the engine polls
OpenRouter's key endpoint every 15 minutes and shows the remaining credit.
That is the only outbound host besides the gateway targets.

## Commands

```text
keys add <name> --provider <provider> [--kind runtime|billing] [--notes <notes>] [--clipboard]
keys list [--json]
keys get <name>
keys copy <name>
keys rm <name> [--yes]
keys rotate <name>
keys env <name> <VAR> -- <command> [args...]
keys ingest [all|grok|claude|openai]
keys spend [--month|--week] [--json] [--by model|session|project]
keys status
keys doctor
keys dashboard [--month|--week]
keys menubar
keys autostart [--remove]
keys client issue <name> [--label <text>] [--days 30] [--method POST]... [--path-prefix <prefix>]
keys client list <name>
keys client revoke <name> <id>
keys purge
```

`keys env` puts the secret in the child's environment only; nothing touches
the clipboard. `keys doctor` prints every local source it looked for, whether
it was found, when it last changed, which row on the site it feeds, and why a
row is empty. Start there when a number is missing.

## Local sources

| Source | Path | Feeds |
|---|---|---|
| Claude Code sessions | `~/.claude/projects/**/*.jsonl` | Claude tokens, estimate, per-project view |
| claude-hud snapshot | `~/Library/Application Support/Keysreallysafe/claude-plan.json` | Claude 5-hour and weekly % |
| Grok sessions | `~/.grok/sessions` | Grok dollars |
| Grok billing log | `~/.grok/logs/unified.jsonl` | Grok weekly % |
| Codex rollouts | `~/.codex/sessions/**/rollout-*.jsonl` | Codex tokens, estimate, 5-hour and weekly % |
| Gateway | in-process | dollars per key |

Ingest is incremental, reads logs in bounded chunks, commits in batches, and
runs on a background queue on start, every five minutes, and on demand
(`⌘R`). The cursor it keeps per file is a SHA-256 of the last 32 bytes, never
the bytes themselves. Claude turns are counted once per message id even though Claude Code
writes one log line per content block. Prices come from `Fixtures/models.json`
(OpenRouter's list, refreshed by hand with `scripts/refresh-models.sh`) with a
few hand-maintained rows that win on exact match.

Everything lives under `~/Library/Application Support/Keysreallysafe/`
(SQLite catalog, snapshot of the site) and in the Keychain service
`keysreallysafe`. `keys autostart` stages a new version beside the old one
and puts the old one back if signing or launch fails.

## Development

```sh
swift test                      # synthetic fixtures only, no network
./.build/debug/keys dashboard   # dev copy on :12765, serves Web/ from the checkout
```

`Web/` is plain HTML, CSS and JavaScript with no build step and no external
resources. `Fixtures/` holds synthetic session logs for the tests, the price
table, and the provider catalog. CI runs `swift test` on macOS.

## License

MIT. See `LICENSE`.
