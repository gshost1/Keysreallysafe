---
name: keysrs
description: Operate the Keysrs `keys` CLI and the API-key vault on this Mac — check plan-usage status, wire and launch coding agents (Claude Code, Codex, Grok, Droid) against the local gateway, and request scoped grants for one task. Use when the user mentions Keysrs or the `keys` command, an API-key vault or gateway grant, or wants an agent to use a provider key without ever holding the secret.
license: MIT
---

# Keysrs

Keysrs is a local Mac app plus the `keys` command line tool. It is two things at
once: a usage meter that reads the plan and token logs Claude Code, Codex, Grok
and Droid already write, and an API-key vault that keeps your provider secrets in
the macOS Keychain behind Touch ID. Agents you launch through it call the vault's
local gateway and never see the real key.

Keysrs is not an AI subscription. It supplies no provider credits and no model.
You bring your own provider accounts; Keysrs only stores the keys, swaps them into
requests, and counts what the calls spend.

Everything binds to `127.0.0.1`. The gateway listens on `127.0.0.1:12767` and the
dashboard on `127.0.0.1:12766`. Nothing about the vault leaves this Mac, with one
exception the user opts into by hand: `keys relay`, which holds a single outbound
WebSocket to a Worker the user deployed into their own Cloudflare account.

## The safety contract

These rules are not preferences; they are how the product stays safe. Follow them
even when a task would be easier without them.

- **User presence every time.** Reading a secret (`keys get`), copying it
  (`keys copy`), revealing it, putting it in the environment (`keys env`), rotating
  it (`keys rotate`), minting a grant (`keys grant`) or issuing a client token
  (`keys client issue`) each require the user's Touch ID. Never try to script around
  the prompt, cache a secret, or retry a cancelled one.
- **Agent configs hold no secret.** `keys setup` writes only the gateway base URL
  and the *name* of an environment variable into the agent's own config
  (`~/.factory/settings.json`, `~/.codex/config.toml`, `~/.grok/config.toml`).
  `keys agent` fills that variable with a short-lived grant at launch. Keep it that
  way: never write a key value, a grant token or a client token into a config file.
- **Never read the provider auth files.** Do not open `~/.codex/auth.json` or
  `~/.grok/auth.json`, and do not read any provider's own credential store. Keysrs
  does not, and neither should you.
- **Never put a key value in output.** Key values must not reach a log, a command
  line you print, a test fixture, a commit or a chat message. `keys list` shows
  names only for exactly this reason; use it instead of anything that prints values.
- **The gateway needs a grant or a client token.** A request to
  `http://127.0.0.1:12767/<key>` is refused unless it carries a task grant
  (`keys grant`, `ksf_…`) or a long-lived client token (`keys client issue`,
  `ksfc_…`). The ssh tunnel and the relay are pipes for that same check, never a
  way around it.

## Start here: is Keysrs running?

Probe before anything else. `keys version --json` is the cheapest feature check and
works with no site running:

```sh
keys version --json          # {"version":"0.12.0"} — one line, exit 0
```

A site-dependent command that finds no running Keysrs site fails with exit code 6
(see the table below), which tells you to start `Keysrs.app` or run `keys dashboard`
and retry — not to fix your arguments.

## Read the plan windows

`keys status` prints the local plan windows per tool as prose. For a script, read
the machine form:

```sh
keys status --json
```

It prints one sorted-key JSON line with an entry per tool. Every entry states its
`tracked` state. An untracked tool carries **no usage numbers at all**: an absent
figure means "not tracked", never a measured zero. Do not present a number that is
not in the JSON as if it were measured.

## Wire a coding agent to the vault

`keys setup` writes the agent's config so it talks to the gateway, and nothing it
writes holds a secret:

```sh
keys setup droid --key work-anthropic --json
keys setup codex --key router --model vendor/x --json
keys setup grok  --key router --model grok-4.6 --json
keys setup claude --key work-anthropic --json
```

With `--json` you get one sorted-key line naming the `agent`, the `config_path` it
wrote (`null` for Claude Code, which reads its base URL and token from the
environment at launch), the `token_env` variable name, and the `base_url`. Verify
the step from that line instead of parsing the prose. The written config still
contains only the gateway URL and an environment-variable reference.

## Launch a coding agent

```sh
keys agent droid work-anthropic -- droid
keys agent codex router -- codex
keys agent claude work-anthropic
```

`keys agent` asks for one Touch ID, mints a grant whose lifetime matches the
session, fills the agent's environment variable, and revokes the grant when the
agent exits. Pass the agent's own arguments after `--`. For an unattended run that
must outlive a screen lock, mint a client token instead
(`keys client issue <key> --days 30`) and point the SDK's base URL at the gateway.

## Scoped access for one task

When a task needs a key but the user is around, a grant is the narrowest thing to
ask for: one Touch ID, one key, one host, a method/path scope and an expiry.

```sh
keys grant work-anthropic --task "run evals" --minutes 30 \
  --methods POST --paths /v1/messages --json
```

The `--json` line includes the `token` (a `ksf_…` grant token), the `base_url` and
the `auth_header`. Use the token as the API key and point the SDK at the base URL;
the gateway swaps in the real secret. The grant expires, can be revoked
(`keys revoke <id>`), and dies with screen lock or a site restart. Treat the token
as a secret: it is shown for this one task, never log it or write it to a file.

List what is live with `keys grants --json`. Revoke one with `keys revoke <id>`, or
everything for a key with `keys revoke --all --key <name>`.

## Remote and cloud agents

For an agent on another machine you can SSH to, forward the loopback gateway and
give it its own revocable token:

```sh
keys client issue router --label "cloud agent" --days 30   # one Touch ID
keys tunnel user@server.example.com                        # Ctrl-C stops it
keys tunnel user@server.example.com --print                # show the ssh command only
```

For a managed agent that accepts no inbound SSH (GitHub Actions, Claude Code or
Codex cloud sessions, Modal, E2B), the relay is the other route: a Worker the user
deploys into their own Cloudflare account, which the Mac connects *out* to.

```sh
keys relay setup --url https://keysrs-relay.<you>.workers.dev   # prints the secret once
keys relay on        # run the relay inside Keysrs.app
keys relay status    # is it running, and since when
```

The details and the per-agent snippets are in `docs/cloud-agents.md` and
`docs/relay.md` in the Keysrs repository.

## Exit codes

`keys` uses stable exit codes so a script can branch without reading prose:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | a usage or HTTP error |
| 2 | not found — also `keys test` and `keys models` when the provider has no read-only check endpoint |
| 3 | user presence or the Keychain (cancelled, failed, unavailable) |
| 4 | ingest IO or the usage catalog |
| 5 | a failed provider check |
| 6 | no running Keysrs site owns the gateway — start Keysrs.app or `keys dashboard`, then retry |
| 64 | bad arguments (a mistyped command or flag) |

`keys env`, `keys agent` and `keys tunnel` exit with the child command's own code
once it ends.

One pre-existing quirk to know: `keys models --json` exits **5** for a provider
with no check endpoint, while the non-JSON `keys models` exits **2** for the same
condition. The JSON path reports every failed check with one code; this mission
keeps that behavior rather than changing it.

## Machine-readable output

Every `--json` flag prints exactly one line with sorted keys, so a line is a
complete record and needs no text parsing. They exist on: `list`, `spend`,
`grant`, `grants`, `test`, `models`, `providers`, `version`, `status` and `setup`.
`keys log --json` is the one exception: it prints one JSON object per line, newest
last, as calls finish.

## Never do this

- **Never run `keys` with no arguments.** Outside a `.app` bundle it shows a GUI
  alert; inside one it starts the whole app. It is not a status command.
- **Never run a never-returning command in a script.** `keys dashboard`,
  `keys menubar`, `keys relay run` (or bare `keys relay`) and `keys tunnel` without
  `--print` all run until stopped. Use `keys tunnel --print` to see the command,
  and `keys relay on` / `keys relay off` / `keys relay status` to control the app's
  relay without blocking.
- **Treat the stdout of a credential command as a secret.** `keys client issue`
  and `keys relay setup` print a single-use credential on stdout, and `keys grant`
  prints its token. Capture it where the SDK expects the API key; never echo it,
  log it, or paste it into a config or a public place.
- **`keys rm` exits 0 even when you decline.** With no `--yes` it prompts; answering
  no prints `cancelled` and returns success. Check the output, or pass `--yes` when
  you mean it.
- **Never bypass user presence.** If a prompt is cancelled, the command exits 3;
  report that to the user rather than retrying or reaching for a provider auth file.

## Read more

In the Keysrs repository: `README.md` (commands and the exit-code paragraph),
`docs/agents.md` (the full agent guide and where each agent loads skills from),
`docs/cloud-agents.md` (remote agents over ssh), `docs/relay.md` (the relay Worker,
its protocol and threat model).
