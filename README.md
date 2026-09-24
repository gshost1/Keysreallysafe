# Keysrs

Formerly Keysreallysafe; the repository, the Application Support folder, the
Keychain service and the signing identifier keep the old name on purpose.

A local spend meter and API-key vault for the AI command-line tools on your Mac.

It reads the usage numbers that Claude Code, Grok and Codex already write to
your home folder, prices them from a checked-in list-price table, and shows the
result on a loopback web page and in the menu bar. Secrets live in the macOS
Keychain, and the app asks for Touch ID before it reads one out. The dashboard
stays local; Claude's built-in `/usage` command refreshes subscription limits
through its existing login.

## Trial and license

Everything works for 14 days from first launch. After that the usage meter
stops ingesting and new gateway grants are refused until a license is
entered; keys stay fully available. Buy at https://keysrs.com ($29, one
major version), then paste the key into the dashboard banner or run
`keys license set <key>`. `keys license` shows the state. The key is verified
against a public key in `Sources/KeysCore/License.swift` and activated at
keysrs.com on at most two Macs; the app checks in every 30 days (key, a
random install ID and the Mac model only) and keeps working for 14 days
without a check-in. `keys license remove` frees the Mac's place.

## Privacy boundaries

- The dashboard and its API bind to `127.0.0.1` only. Optional product analytics
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
- No scraping. It does not open provider websites, cookies or browser sessions.
- The usage catalog stores only counters and metadata. Gateway request bodies
  never reach that catalog. The optional Optimizer library stores explicitly
  saved project memories and plans in a separate encrypted local archive.
- No credentials from other tools. `~/.codex/auth.json` and
  `~/.grok/auth.json` are never read.
- No fake numbers. A provider whose remaining quota is not in a local file is
  listed as "not tracked" with a link to its own dashboard.
- No secret on screen by default. The key list shows names, never values.
  Copy, reveal, env and rotate ask for user presence every time.
- No open gateway. A request through the gateway needs a grant token: one
  Touch ID per task, bound to one key, one host, a method and path scope and
  an expiry. Screen lock, revoke, gateway off or a restart kills it.

## Install

Requires macOS and Swift.

Local builds need an Apple Development or Developer ID Application signing
certificate in the login Keychain. Create one in Xcode Settings → Apple Accounts
→ your team → Manage Certificates. Use the same team for every build.
`security find-identity -v -p codesigning` lists the certificate fingerprints.
Set `KEYS_SIGNING_IDENTITY` to the chosen 40-character SHA-1 fingerprint, or save
that fingerprint alone in `~/.config/keysreallysafe/signing-identity`.
The build never falls back to ad-hoc signing. Installation preserves the signed
binary and rejects a changed identity before stopping the running app.

```sh
git clone <this repo> && cd Keysreallysafe
swift build
./scripts/codesign.sh .build/debug/keys
./.build/debug/keys autostart
```

`keys autostart` installs a per-user login item that serves the site at
`http://127.0.0.1:12766/` and puts Claude's Fable percentage and the other tools'
weekly percentages in the menu bar (`C 39%  X 46%  G 8%`). Missing Fable usage
shows `C —`. All plan windows are in the dropdown. Re-run it
after every build; the login item serves a snapshot. Put `.build/debug/keys`
on your `PATH` as `keys` for the commands below.

The repository also includes an optional, experimental
[Jev context optimizer](docs/jev-optimizer.md)
for Claude Code. Everything above works without it, and no proven net saving is
claimed for it. It prunes eligible old tool content, reuses identical decisions,
and bounds the work spent deciding what to remove. Keys supplies a scoped grant
and records Jev usage and available provider-reported cost. The optimizer is
enabled explicitly per launch; unlike the local usage meter, it sends selected
conversation state to the selected provider for evaluation. It supports Vercel
AI Gateway and direct TypeSafe Jev through stored Keys credentials; see
[provider support](docs/optimizer-providers.md).

When migrating from an older ad-hoc build, each existing key may need one native
Keychain password approval using **Always Allow** for the newly signed app.
Touch ID remains required by the app when reading secrets. Subsequent builds
use the same designated requirement and Apple team Keychain partition, so
ordinary updates do not repeat this migration. A local self-signed certificate
does not fix this: macOS still assigns it a build-specific partition.

Before installing a new signing configuration, run
`python3 scripts/test-signing-upgrade.py` outside a sandbox. It creates one
disposable item, reads it from two different signed builds at the same path with
interaction disabled, rejects an unrelated ad-hoc signer, and deletes the item.
It never accesses vault items. Do not claim upgrade continuity until this test
passes on the target Mac.

Claude's Fable quota comes from Claude Code's account-matched `/usage` cache in
`~/.claude.json`. While the menu-bar app runs, it refreshes that cache every five
minutes through Claude's built-in `/usage` command (no model request), using the
existing Claude login. Readings older than one hour or past their reset are ignored.

Remove everything with `keys autostart --remove` (login item and snapshot) and
`keys purge` (catalog and every Keychain item, after Touch ID).

To run a prepared package on a second Mac without a Swift toolchain there, see
the [MVP quickstart](docs/mvp-quickstart.md) and the
[acceptance checklist](docs/mvp-acceptance.md), which records what has been
verified on a second Mac. Releases are Developer ID signed, notarized and
stapled DMGs published on the GitHub Releases page and linked from
https://keysrs.com. A candidate that has not been through notarization must be
verified as the quickstart describes before it is trusted.

## The site

Four panes, switched with the segmented control or `⌘1` through `⌘4`.

**Usage** is the first thing you see: the plan windows each tool reports
locally, as `plan · % used · resets in`. Claude has five-hour, Fable, and weekly
windows; Codex has five-hour and weekly windows; Grok has a weekly one. Tools whose quota is not in any local file
sit in a collapsed "not tracked" group with a link to their own dashboard. One
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
a family has, and clicking one shows it alone. `X` downloads the rows as CSV, `⇧C` copies the
totals line as Markdown.

Under **Subscriptions**, chips narrow the view to Grok, Claude or OpenAI.
Everything here is estimated from what those tools wrote to their own logs on
this Mac — not from a plan invoice, and the plan windows themselves stay in the
Usage pane rather than being redrawn as bars. Claude and Codex dollars are
list-price estimates and are labelled as such; Grok's come from its own cost
log. With the Claude chip selected, `P` switches the breakdown to projects.

Under **API keys** the chart is a different ledger: the calls this Mac routed
through the local gateway with a key from the vault. Two pickers narrow it, in
the order the billing works — first the provider (TypeSafe, the Vercel AI
Gateway, or any other provider a vault key reached), then the key, both
defaulting to all and both naming keys only, never values. A workload that runs
on more than one provider, such as Jev, is a model under each of them rather
than a source of its own. Requests lead the totals because every routed call is
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
secret with a recognisable prefix pre-fills it. `?` lists every shortcut.

**Optimizer** is an optional encrypted project library and task ledger. Unlocking
it requires user presence and creates an expiring capability kept in memory.
Projects start off; local storage and external Jev evaluation are separate
settings. Save and inspect memories and verified plans, archive obsolete entries,
set request/input budgets, and inspect known versus unknown usage. Jev plan,
tool, and model decisions are suggestions pending workload evaluation. See the
[optimizer guide](docs/optimizer-library.md) for MCP/CLI access and exact limits.

Compatible stored keys have an **Optimizer** action that preselects the key
without unlocking it. The Optimizer selector also offers local-only memory.
Optional [candidate capture](docs/optimizer-candidates.md) stages curated
successful-task outcomes for review; pending candidates cannot enter retrieval.
[Task preparation](docs/optimizer-task-workflow.md) combines local context and
optional Jev suggestions in one MCP call. A [supported-host TypeScript adapter](docs/optimizer-client-adapter.md)
provides selective tool loading and permission-aware read-result reuse where a
client explicitly integrates it. These are not global interception hooks.

Run `python3 scripts/optimizer-preflight.py --strict` for local prerequisites
without live authorization. [Analytics deployment assets](docs/optimizer-deployment.md)
are prepared separately; the analytics collector runs at `analytics.keysrs.com`.

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
  later. Reveal on the site hides it again after 15 seconds.
- `keys env <name> VAR -- <command>` hands it to one child process as an
  environment variable, so it never touches the clipboard at all.
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

One Touch ID, whose prompt names the task, the provider, the host and the
lifetime. Back comes a token that the client uses *as its API key*, plus the
base URL:

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
site restart all revoke. Grants live only in the site's memory; the audit log
keeps the id, task and scope, never the token. `--max-requests` is a hard cap.
`--max-usd` is an estimate from list prices checked after each call, so one
call can overshoot it.

If the gateway is off for the key, `keys grant` turns it on with the same
single prompt. `keys grants` lists what is active, `keys revoke <id>` or
`keys revoke --all [--key name]` ends it. The dashboard has the same three
under Grant (`A`).

`keys grant` talks to the running site (menubar or dashboard) through a
0600 file under Application Support; without one it says so and stops. The
token in that file only lets a local process *ask*; the grant itself still
needs Touch ID in the site.

**A client** is for a program you keep: a capability that lives in the
catalog as a hash, expires in days (default 30, at most 365), and is scoped
to HTTP methods and an upstream path prefix.

```sh
keys client issue <key name> --label "my script" --days 30 --method POST --path-prefix v1/messages
# prints ksfc_… once
export ANTHROPIC_BASE_URL=http://127.0.0.1:12767/<key name>
export ANTHROPIC_API_KEY=ksfc_…
```

Either token goes where the SDK expects the API key. A client is bound to one
key and revoked with `keys client revoke`. The dashboard's per-launch token
is never accepted as either. Both narrow accidental or unauthorized local
use; neither is a boundary against a process that can already read your
files or memory.

The gateway forwards to the provider host from `Web/providers.json` or the
host you set, replaces the token with the secret in the right header, never
follows a redirect, streams the response back, and records the `usage`
object from OpenAI chat-completions and responses, Anthropic messages and
Gemini bodies, plus Vercel evaluation-model responses and the upstream `request-id`.
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

## Commands

```text
keys add <name> --provider <provider> [--kind runtime|billing] [--notes <notes>] [--clipboard]
keys list [--json]
keys get <name>
keys copy <name>
keys rm <name> [--yes]
keys rotate <name>
keys env <name> <VAR> -- <command> [args...]
keys grant <name> [--task <text>] [--minutes N] [--methods GET,POST] [--paths /a,/b] [--max-requests N] [--max-usd X] [--json]
keys grants [--all] [--json]
keys revoke <id> | --all [--key <name>]
keys test <name> [--json]
keys models <name> [--grep <text>] [--cached] [--json]
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
the clipboard. It prints the provider and host the key belongs to before the
prompt, so a similarly named key for a different provider is caught early.
Prefer `keys grant` when the child only needs to call that provider. `keys doctor` prints every local source it looked for, whether
it was found, when it last changed, which row on the site it feeds, and why a
row is empty. Start there when a number is missing.

## Local sources

| Source | Path | Feeds |
|---|---|---|
| Claude Code sessions | `~/.claude/projects/**/*.jsonl` | Claude tokens, estimate, per-project view |
| claude-hud snapshot | `~/Library/Application Support/Keysreallysafe/claude-plan.json` | Claude 5-hour and weekly % |
| Claude Code usage cache | `~/.claude.json` → `cachedUsageUtilization` | Claude Fable, five-hour, and weekly %; refreshed every five minutes while the menu-bar app runs |
| Grok sessions | `~/.grok/sessions` | Grok dollars |
| Grok billing log | `~/.grok/logs/unified.jsonl` | Grok weekly % |
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

Everything lives under `~/Library/Application Support/Keysreallysafe/`
(SQLite catalog, snapshot of the site) and in the Keychain service
`keysreallysafe`. `keys autostart` stages a new version beside the old one
and puts the old one back if signing or launch fails.

## Development

```sh
swift test                      # synthetic fixtures only, no network
python3 -m unittest discover -s scripts/tests -p 'test_jev_launcher.py'
./.build/debug/keys dashboard   # dev copy on :12765, serves Web/ from the checkout
```

`Web/` is plain HTML, CSS and JavaScript with no build step and no external
resources. `Fixtures/` holds synthetic session logs for the tests, the price
table, and the provider catalog. CI runs `swift test` on macOS.
The bundled optimizer has its own `npm ci`, `npm test`, `npm run typecheck` and
`npm run build` checks in `Plugins/jev-optimizer`; CI runs those with mocked
provider responses. See the [research and source notes](docs/jev-research.md).

## License

Future first-party additions are proprietary unless explicitly stated otherwise.
See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
Previously granted MIT permissions and third-party licenses remain in effect.
See [the licensing transition audit](docs/licensing-transition.md) for scope and
remaining commercial-release work.
