# Coding agents: operating the vault from an agent

`keys` is built to be driven by an AI agent as well as by a person: it answers
a version probe, reports the plan windows as one JSON line, and exits with a
code a script can branch on instead of parsing prose. This page is the manual
for that surface — the supported workflows, the exit codes, the
machine-readable flags, and the privacy rules that are part of the product
rather than a preference. The agent skill that ships with the source and with
the app is a short pointer note: it names the Keysrs MCP server, states the
safety floor, and sends everything else here.

The agents here are the four Keysrs supports — Claude Code, Codex, Grok and
Droid — running on the Mac that holds the vault. For an agent on another
machine, start with [cloud-agents.md](cloud-agents.md) (an ssh tunnel) and
[relay.md](relay.md) (a Worker the user deploys into their own Cloudflare
account); every rule on this page applies to those unchanged.

## The skill, and where it ships

The official Keysrs agent skill is
[Skills/keysrs/SKILL.md](../Skills/keysrs/SKILL.md) in this repository: one
file in the [Agent Skills](https://agentskills.io/specification) format — a
directory named `keysrs` holding a `SKILL.md` whose frontmatter says
`name: keysrs` — that points an agent at the Keysrs MCP server (`keys mcp`,
registered with `keys setup mcp`), states the safety floor, and sends the rest
of the manual here. The app bundle ships it unchanged, so an
installed copy carries it at:

```text
/Applications/Keysrs.app/Contents/Resources/Skills/keysrs/SKILL.md
```

the same file, byte for byte, as the repository's. The format keeps a skill
short — the body stays under 200 lines — so the skill is a pointer note and
this page the full manual; the floor rules are the same in both.

Keysrs does not install the skill, and `keys setup` never writes into an
agent's skills directory: it writes agent configs only (below). Each agent
framework owns its skills directory, so copy the skill there yourself, from a
checkout or from the installed app.

## Where each agent loads skills from

Each agent reads a personal skills directory in your home folder, and most also
read one inside the project they are working in. The personal directories, with
a one-line copy from a checkout of this repository:

```sh
mkdir -p ~/.claude/skills    && cp -R Skills/keysrs ~/.claude/skills/    # Claude Code
mkdir -p ~/.factory/skills  && cp -R Skills/keysrs ~/.factory/skills/    # Droid
mkdir -p ~/.agents/skills    && cp -R Skills/keysrs ~/.agents/skills/     # Codex
mkdir -p ~/.grok/skills      && cp -R Skills/keysrs ~/.grok/skills/       # Grok
```

To copy from an installed app instead, replace `Skills/keysrs` with
`/Applications/Keysrs.app/Contents/Resources/Skills/keysrs`.

What each agent reads beyond its personal directory:

- **Claude Code**: `.claude/skills/` inside the project, plus enterprise and
  plugin directories; `CLAUDE_CONFIG_DIR` relocates the whole `~/.claude`.
- **Droid**: `.factory/skills/` inside the repository.
- **Codex**: `.agents/skills/` from the repository root and the working
  directory. It does not read `~/.codex/skills`; the shared `~/.agents`
  convention is its skills home.
- **Grok**: `.grok/skills/` walking up from the working directory, plus
  `~/.agents/skills/`, and — for compatibility with Claude Code —
  `.claude/skills/` too, so a copy made for Claude Code in a project serves
  Grok as well. Extra directories can be named under `[skills]` in
  `~/.grok/config.toml`.

No single directory is native to all four. That is why the skill ships once
and this page documents the copy, instead of the app writing into four
directories it does not own.

## The supported workflows

The safe paths are: probe, read, wire, launch, and grant — the Keysrs MCP
server (below) is the preferred surface for an agent whose client loads one —
and a client token for a program that must run unattended or from another
machine. A workflow that needs the key's value in a file, a saved environment
or your own output is not one of these paths; it is what these paths replace.

## Probe and read

Probe with the cheapest call first. `keys version --json` needs no running
site and no Touch ID:

```sh
keys version --json      # {"version":"0.14.0"} — one line, exit 0
```

An install old enough to answer exit 64 here does not know this surface yet;
ask the user to update Keysrs instead of falling back to parsing prose.

Then read the plan windows:

```sh
keys status --json       # one line, a "tools" array with an entry per tool
```

Every entry states `"tracked"`: true or false, and an untracked tool carries
no usage numbers at all — an absent figure means not tracked, never a measured
zero, and a percent whose window already reset is left out rather than shown
as current. Never present a number the JSON does not give you as if it were
measured.

## Wire and launch an agent

`keys setup` writes the agent's own config so it talks to the local gateway,
and `keys agent` launches it on one Touch ID. Nothing written holds a secret:
the config names an environment variable, and the launcher fills it with a
fresh grant whose lifetime matches the session — revoked when the agent exits,
dead on screen lock or expiry.

```sh
keys setup droid --key work-anthropic --json
keys setup codex --key router --model vendor/x --json
keys setup grok  --key router --model grok-4.6 --json
keys setup claude --key work-anthropic --json
```

`keys setup` writes `~/.factory/settings.json` (Droid), `~/.codex/config.toml`
(Codex) and `~/.grok/config.toml` (Grok); Claude Code reads two variables from
the environment at launch, so this gateway step writes it no file. Registering
the MCP server — `keys setup mcp` — is the step that writes `~/.claude.json`
and the other clients' MCP config files. With `--json` you get one line
naming the `agent`, the `config_path` written (`null` for Claude Code), the
`token_env` variable and the gateway `base_url` — verify the step from that
line rather than parsing prose.

```sh
keys agent droid work-anthropic -- droid
keys agent codex router -- codex
keys agent claude work-anthropic
```

Pass the agent's own arguments after `--`. `keys agent` asks for one Touch ID,
exits with the agent's own code, and revokes the grant when the agent ends.

## The Keysrs MCP server

An agent whose client loads MCP servers (Claude Code, Codex, Cursor, Droid,
Claude Desktop) should use the Keysrs server instead of parsing CLI prose.
`keys mcp` serves it over stdio — newline-delimited JSON-RPC 2.0, responses
on stdout, diagnostics on stderr, and it exits 0 when the client closes its
stdin. The client owns the process; a script never starts it by hand.

Register it once:

```sh
keys setup mcp            # writes the keysrs server into the five clients
keys setup mcp --json     # one line: action, per-client config_path, server, command
keys setup mcp --remove   # undoes all five, leaving every other entry alone
```

Registration needs no vault key, no running site, no Keychain and no Touch ID,
and never writes a secret: each entry holds the resolved absolute path of the
installed `keys` binary plus the `mcp` argument. It writes `~/.claude.json`
(mcpServers), `~/.codex/config.toml` (`[mcp_servers.keysrs]`),
`~/.cursor/mcp.json`, `~/.factory/mcp.json` and
`~/Library/Application Support/Claude/claude_desktop_config.json`, merging
without dropping the file's other entries and keeping a one-step `.bak` beside
each (0600). It is idempotent; running it again after moving the app updates
the path.

The tools the server offers:

- `version` — the Keysrs version.
- `list_keys` — the vault's key names, providers, kinds and the projects
  using each one, by label. Reads the local catalog; the app does not need to
  be running. Never a key value.
- `gateway_info` — the gateway's base URL, the app's live grants and the
  active project client tokens by label. Requires the app; the server
  launches it on demand, and if it cannot be started the whole call fails
  with the not-running answer, so "no grants" is never mistaken for
  "cannot see grants".
- `open_app` — bring the Keysrs app's window to the front, launching the
  app when none is running. Never opens a browser.
- `check_update` — whether a newer release exists. Read-only; it downloads
  and installs nothing.
- `request_grant` — ask the user for a scoped, time-boxed grant for one key.
  No host input: the host is the key's own, so a caller cannot retarget it.
- `grant_status` — poll the ask by its id, passing the secret the create answer
  carried: `pending`, then `approved` with the token, `base_url` and
  `auth_header` on exactly the first approved poll (the only time a token is
  returned; later polls say `delivered`), or `denied`, `expired`, `not_found`.
  With no id, pass every secret you hold as `secrets` and the answer lists
  exactly the asks they prove — ids, keys and states only.
- `scan_project` — scan a project folder for credential-shaped environment
  variables without reading the files yourself: each one's name, relative
  file, likely provider, category (`provider_key`, `aws_pair`,
  `credential_url`, `wrapped`), a last-4 hint, whether the value is already
  in the vault and whether the gateway could proxy it, plus the env files
  read and the Docker files at the root. The one input, `folder`, is
  optional and defaults to the server process's working directory, and is
  refused when it is outside that working directory's subtree — the session
  working directory is the folder the user pointed the agent at, and it is
  the only subtree a session may scan or rewrite. Never
  returns a key value — at most the last 4 characters. The in-vault answer
  needs the app (a hash-only comparison); without it the scan still answers
  and `in_vault` is null.
- `check_exposure` — which of those env files git has ever seen: three
  read-only booleans per file (`gitignored`, `tracked`, `in_history`), the
  relative paths, and a rotate-the-keys recommendation for any file that
  was ever committed. Never file contents or diffs. Same optional `folder`
  with the same working-directory restriction as `scan_project`; needs no
  app, no vault and no network, and answers null booleans with a
  plain statement when git or the repository is missing.
- `import_and_wrap` — import the found keys into the vault and rewrite each
  line to a single 30-day project gateway token, inside the app under one
  Touch ID prompt naming the keys and the project. Ask the user first in
  the same call. Inputs: the optional `folder` (same default and the same
  working-directory restriction as `scan_project`), an optional
  `variables` list restricting the import to those names, and the `docker`
  flag — pass true only on the user's explicit yes, because it also lets
  Docker containers reach the gateway (the host.docker.internal section
  below) and writes those base URLs. The request carries names and flags
  only — never a value; the app re-reads the files itself. The result is
  per-variable outcomes (`wrapped`, `imported_not_wrapped`, `skipped`,
  `not_found`, each with its reason), the project label, the token's
  expiry, the docker setting, the base-URL host, and whether a backup of
  the original values was kept outside the project (backups live beside
  the catalog, never inside the project) — never a value, a
  token or an absolute path. Values the gateway cannot proxy (AWS SigV4 pairs,
  credential URLs) import but keep their lines; a value with no recognized
  provider and no vault match is not imported. Requires the app; without it
  the whole call fails with the not-running sentence.
- `test_keys` — whether named vault keys still work, read-only: one GET to
  each key's model-list endpoint, answered per key (outcome, summary, model
  list, a confirmed flag) — never a key value. `keys` is a required list of
  vault key names. Confirmation is the user's alone, every time: ask the
  user in this same call and pass `confirm` true only after they say yes —
  never remember an earlier yes, never treat one approval as covering a
  later call. With `confirm` absent or false nothing is sent to any
  provider, no prompt appears, and the result says so per key; with it the
  app shows one Touch ID prompt naming the keys. A provider with no
  read-only check endpoint reports `no_check_endpoint` with nothing sent.
  Requires the app.
- `send_feedback` — hand feedback about Keysrs to the maintainer: the running
  app scrubs the draft first (key values by exact match, Keysrs token shapes
  and prefixes, provider-key-shaped strings, absolute and `~` paths, key
  names, project labels, emails except support@keysrs.com, whatever the
  optional `prompt` argument marks, and over-length text capped at 10,000
  characters), adds the Keysrs and macOS version, and opens the user's mail
  client (`destination` `"email"`, the default) or the GitHub issue page
  (`destination` `"github"`) prefilled with the scrubbed text. Requires the
  app; no Touch ID — scrubbing removes secrets, it never reads one out.
  Returns the scrubbed text and per-category removal counts. Keysrs never
  submits the feedback: the user reviews and sends what opens.
- `set_analytics_sharing` — record the user's answer to the analytics
  question: `enabled` false keeps it local and turns sharing off at once.
  `enabled` true does not turn it on: the answer is
  `{"enabled": false, "status": "pending_user_confirmation"}`, and the agent
  asks the user to switch sharing on in the Keysrs app, where that switch is
  the confirmation. Requires the app, and it changes nothing
  else — no report is sent (only the dashboard's own timer uploads), the
  pending report preview is never returned, and no Touch ID is asked. Off
  unless set. Call it only after the user has explicitly answered the
  analytics question; never enable sharing on your own.
- `revoke_all` — the kill switch: revoke every active grant and client token
  at once, or only one vault key's with `key`. Requires the app; no Touch ID,
  because revocation only removes access. Answers `{revoked_grants,
  revoked_clients}` — counts of what was still live and is now dead, so a
  second call answers zeros. Afterwards the grants stop authorizing and the
  client tokens are refused. The vault's keys themselves are untouched.
- `revoke_project` — revoke one project's active client tokens by their
  label — client tokens only; grants carry no project and are untouched.
  Requires the app; no Touch ID. An unknown label is a not-found error; a
  known label with nothing active answers `{revoked_clients: 0}`.
- `activity` — recent gateway use read from the local catalog, so the app does
  not need to be running: one row per key used in the window, carrying its
  forwarded request count, its refused request count, the projects using the
  key by label (empty when none), and the spend the ledger already computed
  (priced and unpriced call counts; `usd` is null when no call could be
  priced, never a fake zero). `window` is whole hours (default 24, 1 to 720);
  `project` keeps one label's keys, and an unknown label answers no rows
  rather than an error. Never a token, a key value or a request body.

The grant ask returns `{"status":"pending","id":…,"secret":…}` immediately,
while the Keysrs app shows one Touch ID prompt naming the key, the host and the
project's label — never a path, never a token. Poll `grant_status` with the id
and the secret: the secret proves the ask is yours, no listing, log or audit
carries it, and a process that read only the app's control token can neither
poll the ask nor list it. The user's answer decides it, and a denial is the
user cancelling the prompt. Treat the handed-over token exactly like a
`keys grant` token: it is printed for this one task and never belongs in a
log, a file or a message.

Everything the server does stays on this Mac: it reads the catalog locally,
reaches the app over the same loopback control channel the CLI uses, and adds
no outbound endpoint. It sends no product analytics itself —
`set_analytics_sharing` only records the user's own answer in the app, and only
the dashboard's timer ever uploads a report.

## Scoped access for one task

When a task needs the key and the user is around, a grant is the narrowest
thing to ask for: one Touch ID, one key, one host, a method and path scope,
an expiry.

```sh
keys grant work-anthropic --task "run evals" --minutes 30 \
  --methods POST --paths /v1/messages --json
```

The `--json` line carries the `token` (a `ksf_…` grant token), the `base_url`
and the `auth_header`. Use the token as the API key and point the SDK at the
base URL; the gateway swaps in the real secret. The grant expires, can be
revoked, and dies with screen lock or a site restart — on purpose, because it
is for a task the user is around for. Treat the token as a secret: it is
printed for this one task, and never belongs in a log, a file or a message.

List what is live with `keys grants --json`; end one with `keys revoke <id>`,
one key's everything with `keys revoke --all --key <name>`, or every grant
AND client token at once with `keys revoke --all` — it prints both counts
(`revoked 2 grants and 1 client token`) and needs no Touch ID. The dashboard's
own Revoke-all button stays grants-only.

## Unattended and remote: a client token

A grant needs the user present. A program that must outlive a screen lock — a
nightly job, an agent on another machine — gets a client token instead: a
capability stored in the catalog as a hash, expiring in days, scoped to HTTP
methods and a path prefix, revocable with `keys client revoke`, or in bulk
with `keys revoke --all` (one key's with `--key`) and one project's with the
`revoke_project` tool.

```sh
keys client issue router --label "nightly job" --days 30   # one Touch ID
```

`keys client issue` prints the token (`ksfc_…`) once, on stdout; treat that
stdout as a single-use secret, capture it where the SDK expects the API key,
and never echo or log it. Point the program at the gateway,
`http://127.0.0.1:12767/<key name>`, with the token as its API key.

For a machine you can SSH to, `keys tunnel` carries the loopback gateway there
without opening a port on the Mac. For a managed agent that accepts no inbound
SSH — GitHub Actions, Claude Code or Codex cloud sessions, Modal, E2B — the
relay is the other route. Both keep every check this page describes; the
details and the per-agent snippets are in [cloud-agents.md](cloud-agents.md)
and [relay.md](relay.md).

## Unwrapping an env file

`keys unwrap path/to/.env` is the inverse of `keys wrap` and
`import_and_wrap`: under one Touch ID the app restores each wrapped line's
real value from the vault and revokes that file's gateway client tokens,
so the token left in the file dies immediately — except a token another
recorded wrapped file still holds, which is kept (the report names the
file that still uses it) until the last of its files unwraps. An unedited
file comes back byte-for-byte — the wrap-time backup is the restore
source for the BASE_URL companions (restored where the wrap replaced one,
removed where it appended one or where no backup holds an original).
Backups live outside the project, in Keysrs' own backups folder beside
its catalog (owner-only folders, 0600 files); a backup a wrap wrote beside
the file before that move is still read. Only the companions the wrap
recorded writing are removed: a gateway-pointing URL the wrap never wrote
is left as written and
reported, while files wrapped before that record existed keep the
blanket removal as the documented fallback. With no argument,
`keys unwrap` restores every wrapped file recorded for the working
directory's project. It writes no new backup, prints no value, and a token
already revoked is a no-op, not a failure.

Like `keys wrap`, it needs the running app — the vault and the tokens live
there. When no Keysrs site owns the gateway it prints the not-running
sentence and exits 6, changing nothing; open Keysrs.app (or run
`keys dashboard`) and retry.

## Docker containers: the host.docker.internal setting

A container cannot use `http://127.0.0.1:12767` — that is the container's own
loopback, not the Mac's. On Docker Desktop for Mac, `host.docker.internal`
works instead: the Desktop VM intercepts the connection and its backend dials
the Mac itself over the host's loopback, so the gateway keeps its
127.0.0.1-only bind and needs no published port. That forward is also why the
path is Docker-Desktop-only: native Linux resolves the name to the bridge
gateway — a non-loopback address — when it works at all, and a loopback-only
bind is not reachable there.

The forward is TCP-level, so the SDK's URL authority arrives verbatim in the
`Host` header, which the gateway's loopback Host check normally refuses. The
Docker setting (`pref_docker_access`, off until the person turns it on — an
import that passes `docker: true` writes "on", and `gateway_info` reports it)
lets the gateway accept exactly `host.docker.internal:<gateway port>` — the
port included, one spelling, no other Host. It is read per request, so
toggling it takes effect on the next call with no restart. Nothing else
widens: the dashboard site refuses that Host in every state of the setting,
and the shared loopback checks the relay and the egress guards use never
learn the name.

The acceptance is compatibility, not a security boundary: the token is still
the gate. A container that can reach the Mac at all can also send a loopback
Host; what the setting buys is well-behaved containerized SDKs working with
the URL they already have.

## Exit codes

`keys` exits with a stable code so a script can branch without reading prose:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | a usage or HTTP error |
| 2 | not found |
| 3 | user presence or the Keychain (cancelled, failed or unavailable) |
| 4 | ingest IO or the usage catalog |
| 5 | a failed provider check |
| 6 | no running Keysrs site owns the gateway |
| 64 | bad arguments (a mistyped command or flag) |

`keys env`, `keys agent` and `keys tunnel` exit with the child command's own
code once it ends.

Exit 6 is the one that says the app could not be reached, not "fix your
arguments": `keys grant`, `keys grants`, `keys revoke`, `keys renew`,
`keys gateway`, the grant path of `keys agent`, `keys wrap`, `keys relay
on`/`off`, `keys dashboard`, and the app-bound MCP tools first try to
launch Keysrs.app and wait for its control endpoint, and only when that
fails do they answer exit 6 with `Keysrs isn't running. Open Keysrs from
Applications, then try again.` `keys unwrap` prints the same sentence and
exits 6 but never launches the app — a script gets exit 6 and nothing
changes when no site owns the gateway. `keys tunnel` and `keys relay run`
use the same launch, but keep their own gateway-down error when the app is
up and its gateway is not listening. Commands that need no site — `keys
list`, `keys status`, `keys version`, `keys setup` — run without one and
never launch the app.

Exit 2 covers a missing key or grant, and one more case worth stating
precisely: `keys test` and `keys models` also exit 2 when the provider has no
read-only check endpoint, because nothing was sent to the provider. That is
the human path's contract. The `--json` path of `keys models` is deliberately
different, and predates this page: it exits **5** for the same condition,
because it reports every failed check with one code. Read the `outcome` field
(`no_check_endpoint`) in its JSON when you need the distinction; do not assume
2 from `keys models --json`.

## Machine-readable output

Every `--json` flag prints exactly one line with sorted keys, so one line is a
whole record and needs no text parsing:

```text
keys list --json
keys spend --json
keys grant … --json
keys grants --json
keys test … --json
keys models … --json
keys providers --json
keys version --json
keys status --json
keys setup … --json
```

`keys log --json` is the one exception: it prints one JSON object per line,
newest last, as calls finish.

## The privacy contract, and what an agent must never do

The README's "Privacy boundaries" section is the product's contract; these are
the parts that bind an agent, stated as rules:

- **Never read the provider auth files.** `~/.codex/auth.json` and
  `~/.grok/auth.json` are off limits, and so is any provider's own credential
  store. Keysrs never opens them; neither do you.
- **Never write a key value, a grant token or a client token into a config
  file, a log, a test or a message.** `keys setup` configs hold the gateway
  URL and an environment-variable *name*; the launcher fills the value. Key
  values never appear on screen, in logs, in tests or in fixtures — `keys
  list` shows names only, for exactly this reason.
- **Never bypass user presence.** Reading a secret out (`keys get`, `copy`,
  `env`), rotating it, minting a grant and issuing a client token each ask for
  Touch ID. A cancelled prompt exits 3; report that to the user instead of
  retrying or reaching for a credential file.
- **Treat credential stdout as a secret.** `keys grant`, `keys client issue`
  and `keys relay setup` print a token once, on stdout. Capture it where the
  SDK expects the API key; never echo it, log it or paste it anywhere.
- **Never run `keys` with no arguments.** Outside a `.app` bundle it shows a
  GUI alert; inside one it starts the whole app. It is not a status command.
- **Never run a never-returning command in a script.** `keys menubar`,
  `keys relay run` (or bare `keys relay`) and `keys tunnel`
  without `--print` run until stopped. `keys mcp` also runs until its stdin
  closes — that is the protocol, its MCP client keeps it open, so only a
  client starts it. `keys tunnel --print` prints the ssh command instead;
  `keys relay on`, `off` and `status` control the app's relay without
  blocking. `keys dashboard` is safe in a script: it fronts the app's
  window (launching Keysrs when needed), prints one line and returns.
- **`keys rm` exits 0 even when the confirm was declined.** Check the
  output for `cancelled`. An agent should never pass `--yes`, and should
  delete a key only when the user asked for that key to be deleted.
- **No fake numbers.** An untracked tool is not tracked, never an estimate
  dressed up as a measurement; a number you were not given does not exist.

The gateway enforces most of this itself: a request without a grant or client
token is refused before the key is even looked up, and the tunnel and the
relay carry that same check rather than bypassing it. What it cannot enforce
is what you write, echo and log — that part is yours.
