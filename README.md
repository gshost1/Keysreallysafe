# Keysrs

Formerly Keysreallysafe; the repository, the Application Support folder, the
Keychain service and the signing identifier keep the old name on purpose.

A local spend meter and API-key vault for the AI command-line tools on your Mac.

Scripts, coding agents and cloud VMs get scoped dummy keys instead of the real
ones. A gateway on loopback swaps the real key in, and for a machine that cannot
reach your Mac, a small relay Worker you deploy into your own Cloudflare account
carries the call home. The real keys never leave the Mac.

It reads the usage numbers that Claude Code, Grok and Codex already write to
your home folder, prices them from a checked-in list-price table, and shows the
result in the Keysrs window and in the menu bar. Secrets live in the macOS
Keychain, and the app asks for Touch ID before it reads one out. The dashboard
stays local. If you turn on Keep Claude Limits Fresh (off by default), Claude's
built-in `/usage` command refreshes subscription limits through its existing login.

## Install

Free and MIT-licensed. Download the signed, notarized disk image from
https://keysrs.com or the [latest release](https://github.com/gshost1/Keysreallysafe/releases/latest).
There is no trial, license key or account.

macOS 14 or newer on Apple Silicon; there is no Intel build.

Open `Keysrs-arm64.dmg`, drag Keysrs to Applications, and open it from
Applications. Keysrs is an ordinary Mac app: a Dock icon, a window with the
dashboard, and the usage meter in the menu bar. Closing the window keeps it
running, so the menu bar meter, usage tracking and the gateway carry on;
click the Dock icon or choose Open Keysrs from the menu bar to bring the
window back. `⌘Q` quits all of it.

On first launch Keysrs adds itself as a login item. Turn that off or on again
with Start at Login in the Keysrs menu, or in System Settings > General >
Login Items.

The `keys` command line is inside the app. Choose Install Command Line
Tool… in the Keysrs menu to link it as `~/.local/bin/keys`, and add
`~/.local/bin` to your `PATH` if it is not there already. If you move the
app, install the link again.

**Updates.** Keysrs updates itself. Check for Updates… in the Keysrs menu
asks GitHub's latest-release API what is newest; when there is a newer
version, Update Now downloads the release's `Keysrs-arm64.dmg` from GitHub,
checks its SHA-256 checksum and Apple code signature, replaces Keysrs where
it is and restarts it. No Terminal, and keys, history and settings are
untouched. Automatically Check for Updates does the same check at launch and
once a day and is off until you turn it on; it reports the release and
installs nothing until you click Update Now. The check sends no cookies and
nothing from your data.

**Upgrading from 0.9.x.** Open the new app once. It stops the old background
agent (`com.keysreallysafe.menubar`), deletes its launchd plist and the old
program files under `~/Library/Application Support/Keysreallysafe/` (`bin/`,
`Web/`, `Fixtures/`, `Plugins/`, `scripts/`), and keeps everything else: the
catalog, preferences, logs, the retained `.previous/` copy, and every key in
the Keychain. The folder you copied out of the old disk image is no longer
used and can go in the Trash.

**Uninstalling.** Quit Keysrs and drag it from Applications to the Trash;
macOS drops its login item once the app is gone. Your data stays. To delete
it as well, run `keys purge` first (catalog and every Keychain item, after
Touch ID). On a Mac whose 0.9.x install was never upgraded, `keys autostart
--remove` removes the old agent, its program files and `.previous/`.

## Privacy boundaries

- The dashboard and its API bind to `127.0.0.1` only; the Keysrs window loads
  the dashboard from there, and nothing off this Mac can reach it. Nothing
  else listens either: the one optional way in from outside is the relay,
  which holds a single **outbound** connection from this Mac to a Cloudflare
  Worker **you** deployed into your own account, only while it is on (in
  Keysrs from the moment you turn it on, with Touch ID, until you turn it off
  or quit; never at launch by itself; or while `keys relay` runs in a
  Terminal), and feeds what arrives into the same loopback gateway with the
  same token checks. Keys never leave the Mac over it; see
  [docs/relay.md](docs/relay.md).
  Optional product analytics
  ("share to compare") is off until the user opts in. Then, once a day, it
  sends one aggregate report to `analytics.keysrs.com`: feature counters, token
  totals per tool, provider and public model name, gateway totals per provider,
  and plan-window peaks, never from before opting in.
- Product analytics excludes prompt content, credentials, key/project/session
  names, paths, dollar amounts, exact times, and persistent device/user
  identifiers. The Privacy dialog shows the destination and unsent reports and
  can stop collection and discard them.
- With sharing on, the app also downloads the public comparison table from the
  same host once a day. These two requests are the only analytics network
  traffic, and neither happens without opting in.
  See [product analytics](docs/product-analytics.md) and the
  [self-hosted collector](Analytics/README.md).
- Update checks are off by default. Check for Updates…, and Automatically
  Check for Updates once turned on, send one cookieless request to GitHub's
  public latest-release API and read only the release's version and download
  address. Nothing from the catalog goes with it. A download happens only
  after you click Update Now, and it comes from GitHub's release for Keysrs.
- No scraping. It does not open provider websites, cookies or browser sessions.
- The usage catalog stores only counters and metadata. Gateway request bodies
  never reach that catalog.
- No credentials from other tools. `~/.codex/auth.json` and
  `~/.grok/auth.json` are never read, and from Grok Bot's folder only the chat
  replicas in `sand-client-persistence/` are opened, never its cookies or
  `sand-secrets.json`. Message text is not kept; only prompts are counted.
  Nothing under `~/.factory/sessions/` is read, and Droid's transcripts
  (`*.jsonl`) and its auth files are never opened. From `~/.factory/logs/` only the
  `[Agent] Streaming result` records of `droid-log-single.log` and its dated
  rotations are read, and of those only the token counts, model id, session
  id and timestamp are kept; the log's other record types carry message
  content and are never parsed.
- No fake numbers. A provider whose remaining quota is not in a local file is
  listed as "not tracked" with a link to its own dashboard.
- No secret on screen by default. The key list shows names, never values.
  Copy, reveal, env and rotate ask for user presence every time.
- No open gateway. A request through the gateway needs a grant token: one
  Touch ID per task, bound to one key, one host, a method and path scope and
  an expiry. Screen lock, revoke, gateway off or a restart kills it. That
  holds for a relayed request too: the relay secret lets a Worker talk to
  this Mac, never to a provider. After five consecutive upstream 401/403
  answers the gateway pauses the key for a minute and says so, instead of
  letting an agent retry against a dead key.

## Build from source

Requires macOS and Swift. Builds need an Apple Development or Developer ID
Application certificate and never fall back to ad-hoc signing; setup,
`KEYS_SIGNING_IDENTITY` and upgrade checks are in [SIGNING.md](SIGNING.md).

```sh
git clone <this repo> && cd Keysreallysafe
make build                     # signed debug command line, .build/debug/keys
python3 scripts/build-app.py   # signed Keysrs.app from the release build
```

`scripts/build-app.py` assembles `Keysrs.app` around the one release `keys`
binary, with the dashboard, fixtures and licence files in
`Contents/Resources`; [docs/release.md](docs/release.md) has the details.
Copy the app to `/Applications` and open it as in [Install](#install). The
binary starts the app when it is opened with no arguments and is the command
line otherwise, so `.build/debug/keys` works directly for the commands below.

The menu bar shows Claude's Fable percentage and the other tools' weekly
percentages (`C 39%  X 46%  G 8%`). Missing Fable usage shows `C —`. All plan
windows are in the dropdown.

Claude's Fable quota comes from Claude Code's account-matched `/usage` cache in
`~/.claude.json`. With Keep Claude Limits Fresh on (menu bar or welcome window; off
by default), the menu-bar app refreshes that cache every five minutes through
Claude's built-in `/usage` command (no model request), using the existing Claude
login. Otherwise the limits are as fresh as Claude Code last left them. Readings
older than one hour or past their reset are ignored.

Remove everything with `keys purge` (catalog and every Keychain item, after
Touch ID), then move the app to the Trash.

## The dashboard

The Keysrs window has four panes, switched with the segmented control or `⌘1` through `⌘4`:
Usage, Chart, Keys and Settings.

The dashboard is dark by default (neutral grey, not blue-tinted). **Settings → Light theme** switches it to the
keysrs.com light look; the choice is remembered on this Mac and does not follow the
system appearance.

**Usage** is the first thing you see: the plan windows each tool reports
locally, as `plan · % used · resets in`. Claude has five-hour, Fable, and weekly
windows; Codex has five-hour and weekly windows; Grok has a weekly one. Grok Bot
is a separate plan from SuperGrok and keeps no usage figures on disk, so its row
counts this week's prompts from the chats it stores locally and says its limits
are not tracked. Droid's row shows three token windows — a rolling 5-hour one,
the calendar week and the calendar month — counted from the per-request
records in its local logs, and **Set limits** on the row adds an optional
token limit for each window, turning that window into a percent meter; Factory's
own plan limits are not in local files. Tools whose quota is not in any local file
sit in a collapsed "not tracked" group with a link to their own dashboard.
**+ Add subscription** under the rows pins a plan you pay for: pick Cursor,
Gemini, Copilot, Perplexity, ChatGPT, Factory or a custom tool you name, name
the plan, and optionally give it a limit — an amount, a unit (tokens, requests,
credits or USD) and a window (5-hour, week or month), all three together or
none. Keysrs measures none of those tools locally, so the row shows exactly the
plan and the limit, says "usage not tracked locally", and never dresses a note
up as a percent; it takes over that tool's placeholder in the collapsed group
until you remove it. A Factory subscription instead attaches to the Droid row —
Droid's usage is the one that is measured — so its plan names the row, a token
limit is that window's limit (the same single fact as the row's **Set limits**
dialog, stored in the same place), and any other unit stays text. Edit and
Remove sit on each row, and Remove asks first. One
quiet line underneath gives this month from the local logs, in tokens by
default, with a switch on the line itself for USD. A first run with an empty
vault also gets a short getting-started guide there; it stays available under
**?** in the toolbar.

**Chart** starts on today by hour and switches to this week or this month by
day (`D` / `W` / `M`). Two things this Mac pays for are charted, and `S`
switches between them: **Subscriptions**, the tools' own local logs, and **API
keys**, the local gateway's ledger. The filters underneath belong to whichever
is chosen, and switching drops the ones that do not carry over. Figures are in
tokens — and requests, where the ledger counts them — until USD is chosen: a
token count is what this Mac measured, while a dollar figure is this repo's
list-price table applied to it afterwards. `T` flips tokens and USD, the choice
is remembered, and the Usage summary and the Keys table's gateway column follow
the same unit from their own switches. The model list under the chart shows
every model by default, each with its own name, colour and filter however many
a family has, and clicking one shows it alone. Each model wears its vendor's
colour — Claude orange, OpenAI green, Grok blue, and the vendors Droid runs
(Gemini, GLM, Kimi, DeepSeek, and anything unrecognized in grey) each their own
palette — and the same model id coming from several tools is one series. `X` downloads the rows as CSV, `⇧C` copies the
totals line as Markdown (both are also buttons in Settings).

Under **Subscriptions**, chips narrow the view to Grok, Claude, OpenAI or
Droid. Everything here is estimated from what those tools wrote to their own logs on
this Mac — not from a plan invoice, and the plan windows themselves stay in the
Usage pane rather than being redrawn as bars. Claude and Codex dollars are
list-price estimates and are labelled as such; Grok's come from its own cost
log. With the Claude chip selected, `P` switches the breakdown to projects.

Under **API keys** the chart is a different ledger: the calls this Mac routed
through the local gateway with a key from the vault. Two pickers narrow it, in
the order the billing works — first the provider (TypeSafe, the Vercel AI
Gateway, or any other provider a vault key reached), then the key, both
defaulting to all and both naming keys only, never values. A model served by
more than one provider is a model under each of them rather than a source of
its own. Requests lead the totals because every routed call is
countable, and `T` adds a requests unit here alongside tokens and USD — a provider like TypeSafe's
System One reports no tokens and no cost, so those calls are shown as requests
with the cost left unknown rather than counted as zero. A partly priced range
is shown as a floor (`≥ ≈ $…`), and that label stays visible under a model,
provider, day or hour, because a bucket that mixes a priced call with an
unpriced one still carries a number. Only routed requests are observable: a
provider called directly, or with a key this Mac never proxied, leaves nothing
to chart, so this view will not match a provider's own dashboard. The
subscription sources are unaffected — gateway dollars are never folded into
them, because a routed Claude Code or Codex call also appears in a local log.

**Keys** is a dense table: name, provider and the host requests are bound to,
kind, created, last used, dollars routed through the gateway this month, and
the last read-only check. Actions
per row: Copy (`C`, clipboard wipes itself after 20 s), Reveal (`V`, hides
after 15 s), Edit (`E`, provider, kind and notes; name and secret are
immutable), History (`H`, the audit log), Rotate (`R`, new secret under the
same name), Gateway (`G`), Grant (`A`, a temporary scoped token, see below),
Check (`T`, authentication status and model list from the provider's
read-only endpoint, with a filter box) and Delete (`⌫`). Active grants sit
above the table with a Revoke button each. `N` adds a key; the provider
picker is grouped into Labs, Routers, Hosts, Clouds and Non-chat, and a pasted
secret with a recognisable prefix pre-fills it. Rows are grouped under a header
per provider, and the search box (`/`) narrows them by name, provider or host —
the count reads "N of M keys" while it does, and `Esc` clears it. `?` lists
every shortcut.

**Settings** holds what used to crowd the toolbar: the theme switch, which
cards Usage shows, **Ingest now** with the last ingest time, the CSV export and
Copy totals, and the Agents and Privacy dialogs. Turning a card off only takes
it off Usage — the subscription, its history and the Chart are untouched, and
Usage says how many cards are hidden rather than showing nothing. Droid's row
is off by default (**Show Droid on Usage** turns it on); its usage is ingested
and charted either way. These choices live in this browser's storage, not in
the catalog.

The [analytics collector](Analytics/README.md) runs at `analytics.keysrs.com`
and is deployed separately from the app.

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
read). Items use the login Keychain's application ACLs. Apple signing preserves
the app identity across builds; biometric presence is still enforced by the
app, not by a per-item biometric access-control attribute. Treat this as
app-level presence prompting:

- `keys copy` puts it on the clipboard and wipes the clipboard 20 seconds
  later. Reveal in the dashboard hides it again after 15 seconds.
- `keys env <name> VAR -- <command>` hands it to one child process as an
  environment variable, so it never touches the clipboard at all. More
  `<name> VAR` pairs before the `--` share the same prompt.
- `keys rotate` swaps in a new value under the same name and bumps a version.
- Delete and purge also require presence, so a script on the machine cannot
  quietly empty the vault.

Every read, copy, env use, rotate, gateway call, gateway denial, client issue,
grant, check and delete is written to a per-key audit log you can open from
the Keys pane. The gateway, when you turn it on for a key, keeps the value in
process memory only and forgets it on restart.

Presence failures are told apart: `Mac authentication cancelled`, `failed`
(wrong password), or `unavailable` with the reason (no GUI session, a sandbox,
nothing enrolled). The exit code is 3 for all three.

## The gateway

Two kinds of credential open the gateway, and a request without one of them
gets 401 before the key is even looked up, so being on loopback proves
nothing by itself.

**A grant** is for one task: short-lived, in memory only, one Touch ID whose
prompt names the task, provider, host and lifetime.

```sh
keys grant router --task "list models" --minutes 30 --methods GET --paths /models
# prints ksf_… once, plus the base URL http://127.0.0.1:12767/router/v1
```

Back comes a token that the client uses *as its API key*, plus the base URL:

```
base url http://127.0.0.1:12767/router/v1
token    ksf_1f2e3d4c_…
```

Point the SDK at the base URL, give it the token as the key, and every call
inside the scope goes through with no further prompt. Anything else fails
closed with a named reason: `grant_required`, `grant_expired`,
`grant_revoked`, `grant_method_not_allowed`, `grant_path_not_allowed`,
`grant_request_limit`, `grant_usd_limit`, `grant_target_changed`. A grant is
bound to one key and the host recorded when it was issued; editing the
provider or host revokes it. Screen lock, `keys revoke`, gateway off and a
restart of the app all revoke. Grants live only in the app's memory; the audit log
keeps the id, task and scope, never the token. `--max-requests` is a hard cap.
`--max-usd` is an estimate from list prices checked after each call, so one
call can overshoot it.

If the gateway is off for the key, `keys grant` turns it on with the same
single prompt. `keys grants` lists what is active, `keys revoke <id>` or
`keys revoke --all [--key name]` ends it. The dashboard has the same three
under Grant (`A`).

`keys grant` talks to the running app (or a `keys dashboard` dev copy)
through a 0600 file under Application Support; without one it says so and
stops. The token in that file only lets a local process *ask*; the grant
itself still needs Touch ID in the app.

**A client** is for a program you keep: a capability that lives in the
catalog as a hash, expires in days (default 30, at most 365), and is scoped
to HTTP methods and an upstream path prefix. It is bound to the host the key
pointed at when it was issued: change the key's host and the client stops
working until the host is back or you issue a new one.

```sh
keys client issue <key name> --label "my script" --days 30 --method POST --path-prefix v1/messages
# prints ksfc_… once
export ANTHROPIC_BASE_URL=http://127.0.0.1:12767/<key name>
export ANTHROPIC_API_KEY=ksfc_…
```

When Keysrs is running, `keys client issue` asks it for the token and turns
the gateway on for the key under the same Touch ID; without the app it still
issues the token and tells you to turn the gateway on later with
`keys gateway on <key>`. The gateway holds keys in the app's memory only, so
it forgets every key when Keysrs quits: client tokens stay valid across a
relaunch but get `404 not_found` until `keys gateway on <key>` (or the
dashboard toggle) runs again. `keys gateway off <key>` turns it off and
revokes the key's grants.

**Wrapping an env file.** `keys wrap path/to/.env` does the whole client
setup for a project in one step. It finds the values that look like provider
keys (by variable name, key prefix, or a base URL already in the file),
matches each to a vault key by comparing secrets inside the running app
(nothing is printed), and offers to add the ones the vault lacks under a
suggested name. One Touch ID covers the batch; it comes before the plan,
because telling an existing key from a new one means reading the vault. The
plan lists variable, key name and new/existing, never a value. After you
confirm (or with `--yes`), each key gets the gateway turned on and one client
token (POST and GET, 30 days unless `--days`), the value in the file becomes
that token, and `OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL` or `GROQ_BASE_URL` is
set to `http://127.0.0.1:12767/<key>` for the matching key variable (to your
relay Worker with `--relay https://…`). The original file is copied beside
itself as `<file>.keysrs-backup-<time>` (0600; it still holds the real
values, so delete it once the agent works), then replaced in one rename with
its permissions kept. Comments, blank lines, `export`, quotes and inline
comments stay as written, and the file always ends with a newline.
`--dry-run` stops after the plan.

```sh
keys wrap ~/code/agent/.env --dry-run
keys wrap ~/code/agent/.env
```

Either token goes where the SDK expects the API key. A client is bound to one
key and revoked with `keys client revoke`. The dashboard's per-launch token
is never accepted as either. Both narrow accidental or unauthorized local
use; neither is a boundary against a process that can already read your
files or memory.

The gateway forwards to the provider host from `Web/providers.json`, from a
provider you added yourself, or the host you set, replaces the token with the
secret in the right header, never follows a redirect, streams the response
back, and records the `usage` object from OpenAI chat-completions and
responses, Anthropic messages and Gemini bodies, plus Vercel evaluation-model
responses and the upstream `request-id`.
For evaluation requests the model comes from the `ai-model-id` header. Valid
provider-reported Vercel evaluation cost is preferred over a list-price estimate;
missing cost with no price remains unpriced. Those calls show up as a "Via
gateway" column in Keys and can be charted per key. A call that no model or
price could be attached to is shown as unpriced, never as $0. The secret is
held in process memory only while the gateway is on and is forgotten on
restart. Providers that need request signing or OAuth (Bedrock, Vertex,
watsonx) cannot be proxied and say so.

Gateway dollars are a separate ledger from the local-log estimate. A Claude
Code or Codex call routed through the gateway appears in both places; when
the gateway's `request-id` matches a local event the local one wins and the
gateway copy is dropped, and otherwise the two totals are shown side by side
rather than added.

For an OpenRouter key of kind `billing` with the gateway on, the engine polls
OpenRouter's key endpoint every 15 minutes and shows the remaining credit.

## Checks

`keys test <name>` hits the provider's read-only model list (`/v1/models` for
OpenAI-shaped APIs, Anthropic's `/v1/models`, Gemini's `/v1beta/models`)
with a plain `Accept` and `User-Agent`, and reports one of: ok with the model
count, provider rejected the key (401), provider refused the request (403,
which is *not* the same as a bad key), provider error, network failure, or
no check endpoint for this provider. It never falls back to a paid
generation call. The provider's own error text and request id are kept,
with the key scrubbed. The result (status, model ids, time) is stored so
`keys models <name> --cached` and the dashboard's Check can reuse it without
another unlock; `keys models <name> --grep sonnet` narrows the list. With the
gateway on the check uses the in-memory secret and prompts for nothing.

## Providers

`keys providers` lists the catalog: the shipped entries plus yours. Add one
with `keys provider add` (the dashboard's **Providers** button does the same):

```sh
keys provider add acme --name "Acme" --host api.acme.dev --api openai --path-prefix v1
```

A provider is routing metadata (host, auth header, usage parser), never a
secret; it lives in the catalog beside your keys and survives restarts. An id
that matches a shipped entry wins over it, so a wrong host in the shipped file
can be fixed locally. `keys provider rm <id>` removes yours — it refuses while
a key still uses it. A built-in provider you do not want in the Add dialog is
taken out with `keys provider hide <id>` and brought back with `unhide`; keys
that already use it keep their gateway, checks and name. OpenAI is retired
from the catalog (2026-10-10): it is no longer offered for new keys, but keys
that already name it keep working exactly as before. Adding it back as a
custom provider is a one-liner if you want it offered again.

## Coding agents

`keys setup <agent> --key <name>` writes the agent's own config so it talks to
the local gateway, and `keys agent <agent> <name>` launches it on one Touch ID.
Nothing the setup writes holds a secret: each agent's config names an
environment variable, and the launcher fills it with a fresh grant whose
lifetime matches the session (revoked when the agent exits, and dead on screen
lock or expiry). Agents supported: **Claude Code**, **Codex**, **Grok**,
**Droid**.

```sh
keys setup droid --key work-anthropic            # ~/.factory/settings.json customModels
keys agent droid work-anthropic                  # one Touch ID, then droid with /model
keys setup codex --key router --model vendor/x   # ~/.codex/config.toml model_providers
keys setup grok --key router --model grok-4.6    # ~/.grok/config.toml [model.keysrs]
keys agent claude work-anthropic                 # no setup needed; env vars at launch
```

A backup of the file sits beside it after the first edit, and each edit is
owner-only. `--client` on the launcher (or `keys client issue` by hand) gives
an unattended setup a token that lives for days instead of a session. Droid
calls through the gateway are metered like any other API-key call (Chart →
API keys); a Droid session run outside the gateway is not observable on this
Mac. Claude Code needs an Anthropic-wire provider key; Codex and Grok need an
OpenAI-compatible one; Droid takes either. The dashboard's **Agents** button (in Settings)
shows the same recipes personalized to your key names, with copy buttons.

## Cloud agents

An agent on another machine — a server, a VM, a self-hosted CI runner, a
container you can SSH to — uses the same vault through an SSH reverse forward.
Nothing new listens on this Mac: the gateway keeps binding `127.0.0.1:12767`
only, and the ssh session carries it to the remote loopback.

```sh
keys client issue router --label "cloud agent" --days 30   # one Touch ID, revocable
keys tunnel user@server.example.com                        # Ctrl-C stops it
# on the server: http://127.0.0.1:12767/router is the gateway, token as the API key
```

`keys tunnel --print` shows the ssh command instead of running it. The remote
side sees a plain localhost port and still needs the client token, so ssh is
the trust boundary: anyone who can open that port on the server can spend
through your key until the token expires or you revoke it. GitHub-hosted
runners cannot reach your Mac; run the agent on a machine you can SSH to
(Tailscale hosts work with the same command). [docs/cloud-agents.md](docs/cloud-agents.md)
has the details and the per-agent remote snippets.

For a managed agent that accepts no inbound SSH at all — GitHub Actions,
Claude Code or Codex cloud sessions, Modal, E2B — the relay is the other
route: you deploy the small Worker in [`Relay/`](Relay/) into your own
Cloudflare account, and the Mac keeps one outbound WebSocket to it. The
Worker is a pipe and nothing more; every request it carries still lands in
the loopback gateway with the same token checks, key swap and usage row, and
the Worker never sees a key. Agents call `https://<your worker>/<key name>`
with their usual token. If the Mac drops off for a moment (the relay redialing,
a short sleep), the Worker holds new requests for up to a minute and sends
them once the Mac is back.

```sh
(cd Relay && npm ci && npx wrangler login && npx wrangler deploy)   # your account
keys relay setup --url https://keysrs-relay.<you>.workers.dev        # prints the secret once
(cd Relay && npx wrangler secret put RELAY_SECRET)                  # paste it
keys relay on                                                        # in Keysrs.app; one Touch ID
```

The relay then runs inside Keysrs, with no Terminal open: **Relay for Cloud
Agents** in the menu bar (or Settings → Relay in the dashboard, or `keys relay
on` / `keys relay off`) turns it on and off, its lines go to `menubar.log`,
and it stays on until you turn it off or quit; each launch starts with it off,
because the secret leaves the Keychain only after Touch ID. `keys relay` alone
still runs it in the foreground of a Terminal until Ctrl-C. Only one of the two
runs at a time, since the Worker keeps a single Mac connection: each refuses
to start while the other is on.

The Mac has to be awake and online for a call to get through. A call in
flight when the Mac sleeps or loses its network fails (502 `mac_disconnected`,
marked retryable), and one that arrives while it sleeps waits the Worker's
minute and then gets 503 `mac_offline`. Sleep does not turn the app's relay
off, though: it reconnects by itself once the Mac is awake and online again,
within about a minute plus one retry step, since it first has to notice that
the old socket went quiet (Reconnection in [docs/relay.md](docs/relay.md)),
and the requests still waiting in the Worker are sent to it then. **Keep Mac
Awake for Relay Calls** (menu bar and Settings, off by default) stops idle
sleep while a relayed call is open and for five minutes after the last one,
so a long generation or an agent's next call does not find the Mac asleep;
the display can still sleep, and closing the lid still sleeps the Mac.

[docs/relay.md](docs/relay.md) has the protocol, the limits, the threat model
and what a compromised Worker can and cannot do.

## Commands

```text
keys add <name> --provider <provider> [--kind runtime|billing] [--notes <notes>] [--clipboard]
keys list [--json]
keys get <name>
keys copy <name>
keys rm <name> [--yes]
keys rotate <name>
keys env <name> <VAR> [<name> <VAR> ...] -- <command> [args...]
keys grant <name> [--task <text>] [--minutes N] [--methods GET,POST] [--paths /a,/b] [--max-requests N] [--max-usd X] [--json]
keys grants [--all] [--json]
keys revoke <id> | --all [--key <name>]
keys test <name> [--json]
keys models <name> [--grep <text>] [--cached] [--json]
keys ingest [all|grok|claude|openai|droid]
keys usage import <file>...
keys spend [--month|--week] [--json] [--by model|session|project]
keys status
keys doctor
keys log [--key <name>] [--failed] [--tail] [--limit N] [--json]
keys dashboard [--month|--week]
keys menubar
keys autostart --remove
keys client issue <name> [--label <text>] [--days 30] [--method POST]... [--path-prefix <prefix>]
keys client list <name>
keys client revoke <name> <id>
keys gateway on|off <name>
keys wrap <env file> [--dry-run] [--yes] [--relay <worker url>] [--label <text>] [--days N]
keys providers [--json]
keys provider add <id> --name <name> [--host <host>] [--api openai|anthropic|gemini|other] [--auth-header <header>] [--auth-prefix <prefix>] [--path-prefix <path>] [--key-prefix <hint>] [--note <text>] [--no-gateway]
keys provider rm <id>
keys provider hide <id>
keys provider unhide <id>
keys setup <agent> [--key <name>] [--model <id>] [--display-name <text>] [--wire <kind>] [--set-default]
keys agent <agent> <key> [--minutes N] [--client] [--label <text>] [--] [args...]
keys tunnel <user@host> [--remote-port N] [--key <name>] [--print]
keys relay [run] [--url <worker url>] | on | off | setup --url <worker url> | status | reset
keys purge
```

`keys env` puts the secret in the child's environment only; nothing touches
the clipboard. It prints the provider and host the key belongs to before the
prompt, so a similarly named key for a different provider is caught early.
A command that needs several secrets takes several pairs under one Touch ID:

```sh
keys env modal-id MODAL_TOKEN_ID modal-secret MODAL_TOKEN_SECRET -- python run.py
```

Every key is read before the command starts, so a missing one runs nothing.
The command stays in keys' process group (the shell's job), as it would
without keys: Ctrl-C reaches it, a coding agent can take over the terminal,
and keys exits the way the command did (`keys agent` revokes its grant
first). Prefer `keys grant` when the child only needs to call that provider.

`keys doctor` prints every local source it looked for, whether
it was found, when it last changed, which row in the dashboard it feeds, and why a
row is empty. It also reports the install: which `Keysrs.app` it found, whether
Start at Login is on, whether the `keys` on PATH is that bundle's binary, and any
0.9.x leftovers to remove with `keys autostart --remove`. Start there when a
number is missing or the menu bar item does not behave like the copy you built.
For the gateway it prints the limits it runs with (900 s per call, no separate
connect timeout, 8 MiB request bodies, 32 connections, the 401/403 pause) and
its last few failures on this side of the provider: timeouts and connection
errors, breaker pauses, and clients calling a key whose gateway is off. Token
refusals are left out there, since anyone who can reach the gateway can cause
them; `keys log --failed` has them.

`keys log` is the gateway's request log: the last 50 calls it forwarded or
refused, newest last, one line each with the time, key, provider, upstream
host, status, duration, reason, and whether the call came in on loopback or
through `keys relay`. `--key` keeps one key, `--failed` keeps non-2xx answers,
gateway-side failures and refusals, `--tail` keeps printing as calls finish (a
call is written when it ends) and `--json` prints one object per line. The
reason is `upstream_status` when the provider answered, and then its status
went to the caller unchanged; `gateway_timeout` (the 900-second limit ran
out), `connect_failed`, `tls_failed`, `connection_lost`, `network_error` and
`client_closed` (the caller went away, or stopped reading for 30 seconds) are
failures on this side of the provider, and a refused call shows the code it
was refused with (`no_client_token`, `grant_path_not_allowed`, …; `gateway_off`
when a valid client token met a key whose gateway is off, while a grant is not
logged then because it can no longer be checked). VIA is a label: `keys relay`
always sets it and drops a caller's copy, but a program on this Mac can claim
it too. A call that got no response head is answered 502
`{"error":"upstream_error","reason":"gateway_timeout","detail":"NSURLErrorDomain -1001"}`,
so a script can tell the gateway's failures from a provider's own 502 by
`reason`. The log holds no body, token or key value; calls stored before it
existed show `-` for what was not kept.

## Local sources

| Source | Path | Feeds |
|---|---|---|
| Claude Code sessions | `~/.claude/projects/**/*.jsonl` | Claude tokens, estimate, per-project view |
| claude-hud snapshot | `~/Library/Application Support/Keysreallysafe/claude-plan.json` | Claude 5-hour and weekly % |
| Claude Code usage cache | `~/.claude.json` → `cachedUsageUtilization` | Claude Fable, five-hour, and weekly %; refreshed every five minutes when Keep Claude Limits Fresh is on |
| Grok sessions | `~/.grok/sessions` | Grok dollars |
| Grok billing log | `~/.grok/logs/unified.jsonl` | Grok weekly % |
| Grok Bot chats | `~/Library/Application Support/Grok Bot/sand-client-persistence/*.blob` | Grok Bot prompt count (kind, role and timestamp only) |
| Droid logs | `~/.factory/logs/droid-log-single.log` and its dated rotations | Droid 5-hour, weekly and month tokens (only the Streaming-result token fields, model id, session id and timestamp) |
| Codex rollouts | `~/.codex/sessions/**/rollout-*.jsonl` | Codex tokens, estimate, 5-hour and weekly % |
| Gateway | in-process | dollars per key |

Ingest is incremental, reads logs in bounded chunks, commits in batches, and
runs on a background queue on start, every five minutes, and on demand
(`⌘R`). Claude subagent transcripts and Codex subagent rollouts are included
in local token totals and estimated spend when their logs are present. Existing
Claude subagent logs are picked up on the next scan. Subagent usage appears in
the existing model/session/project breakdowns, without a separate subagent view.
Provider-reported plan percentages remain separate from these local estimates.
The cursor it keeps per file is a SHA-256 of the last 32 bytes, never
the bytes themselves. Claude turns are counted once per message id even though Claude Code
writes one log line per content block. Prices come from `Fixtures/models.json`
(OpenRouter's list, refreshed by hand with `scripts/refresh-models.sh`) with a
few hand-maintained rows that win on exact match.

### Usage from off this Mac

Claude Code cloud sessions and droid runs on another machine write their logs
there, not here, so nothing above sees them. To count them, make an export
where the usage happened and bring the file over:

```sh
python3 scripts/export-remote-usage.py -o usage.jsonl [--stream droid-stream.jsonl]   # in the cloud session
keys usage import usage.jsonl                                                          # on the Mac
```

The script copies only usage: droid's Streaming-result token fields with the
model and session ids, the `usage` block, model and ids of each Claude Code
assistant turn, and, for a `droid exec -o stream-json` capture passed with
`--stream`, the closing event's token totals. Prompts, answers, tool output,
paths and Factory credits stay behind. Rows are stored as `droid-remote` and
`claude-remote` and appear in the Chart under **Cloud** (and in All); they never
feed the local Droid or Claude plan windows, carry no dollar estimate, and are
not part of share-to-compare analytics. Droid's per-request lines keep each
request's model, so a run that fell back from Claude to `kimi-k3` shows both. A
stream-json total covers a whole session and is stored under the model
`unattributed`; if the same session's per-request lines are imported too, they
replace the part of the total they account for and the rest stays as
`unattributed`. Rows this Mac already has from its own logs are skipped on
import, in either order. Re-importing a file updates rows rather than adding
them twice.
Run the exporter where the usage happened, not on the Mac that runs Keysrs:
exporting this Mac's own logs and importing them double-counts them. Keysrs
skips rows it already has locally, but do not rely on that. The exporter keeps
only plain token counts from 0 to 10^12, ids of up to 128 printable ASCII
characters (no quotes, backslashes or control characters), and ISO-8601
timestamps; a record with anything else is dropped and counted on stderr. A named `--stream` file or `--factory-home` /
`--claude-home` that does not exist, a non-regular input, or an `-o` that is an
input or lies inside the Claude projects folder is refused with one line and
exit 2, and a failed run leaves no output file.
Files dropped into `~/Library/Application Support/Keysreallysafe/imports/` are
imported on the next ingest and moved to `imports/imported/`.

The program is `/Applications/Keysrs.app`. Your data lives under
`~/Library/Application Support/Keysreallysafe/` (SQLite catalog, preferences,
`menubar.log`) and in the Keychain service `keysreallysafe`; replacing or
deleting the app leaves both alone.

## Development

```sh
CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home swift test
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
KEYS_NO_OPEN=1 ./.build/debug/keys dashboard   # dev copy on :12765, serves Web/ from the checkout
```

`Web/` is plain HTML, CSS and JavaScript with no build step and no external
resources. `Fixtures/` holds synthetic session logs for the tests, the price
table, and the provider catalog. `.github/workflows/test.yml` is the full list
of checks CI runs, including the dashboard browser suites, with Playwright
pinned in `scripts/tests/package.json`.

The fixtures are pinned to fixed dates the Swift tests assert against, so on a
live clock most of their records sit outside the dashboard's today/week/month
windows and the Chart's current ranges come up nearly empty. To drive those
ranges with data (vendor colours across every Droid family, a model merged
across Claude Code and Droid), write throwaway homes dated a few minutes ago:

```sh
python3 scripts/tests/fixture_now.py --out /tmp/keys-now
KEYS_NO_OPEN=1 KEYS_CATALOG=/tmp/keys-now/catalog.db \
  KEYS_DROID_HOME=/tmp/keys-now/droid-home CLAUDE_CONFIG_DIR=/tmp/keys-now/claude-home \
  ./.build/debug/keys dashboard
```

The helper prints the per-model and merged totals the Chart should show for the
current month. Its homes are synthetic and throwaway; the checked-in fixtures
are never touched, and `scripts/tests/test_fixture_now.py` pins the helper's
line format to DroidIngest's exact marker. When the helper runs so soon after
local midnight that its records would land on yesterday (or on the previous
calendar week), it clamps their timestamps to stay after the most recent local
midnight, so the Today and Week ranges keep data even right after midnight.

## License

MIT. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
