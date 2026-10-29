---
name: keysrs
description: Operate the Keysrs API-key vault on this Mac through the Keysrs MCP server — register it with `keys setup mcp`, call its tools to list key names, read gateway state and ask for Touch-ID-approved scoped grants, and hold the safety floor. Use when the user mentions Keysrs or the `keys` command, an API-key vault or gateway grant, or wants an agent to use a provider key without ever holding the secret.
license: MIT
---

# Keysrs

Keysrs is a local Mac app plus the `keys` command line tool: a usage meter that
reads the plan logs coding agents already write, and an API-key vault that keeps
provider secrets in the macOS Keychain behind Touch ID. It is not an AI
subscription: it supplies no credits and no model, and everything it runs binds
to `127.0.0.1` on this Mac.

## Use the Keysrs MCP server

The supported agent surface is the MCP server named **keysrs**, served by
`keys mcp`. Register it once:

```sh
keys setup mcp          # writes the resolved keys binary into Claude Code,
                        # Codex, Cursor, Droid and Claude Desktop
```

Then call its tools: `list_keys`, `gateway_info`, `version`, `open_app`,
`check_update`, the grant pair `request_grant` / `grant_status` (a request
returns pending; the user approves it with Touch ID in the Keysrs app; the poll
returns the scoped token once), `send_feedback` (the app scrubs the draft
— key values, tokens, paths, names, emails — opens the prefilled mail or
GitHub issue page, and never submits), `set_analytics_sharing` (records
the user's own answer to the analytics question, and only after they give it),
and the revoke pair `revoke_all` / `revoke_project` (the kill switches:
every grant and client token at once, one key's, or one project's client
tokens by label — each needs the running app and asks for no Touch ID),
and `activity` (recent gateway use from the local catalog — per-key requests,
refusals and spend for a window, with project labels — which works with the
app closed). Every tool answers with names, labels
and state — never a key value. When no MCP client is available, the plain
`keys` CLI does the same work; `keys version --json` is the cheapest probe and
needs no running app.

Remove the registration with `keys setup mcp --remove`.

## The safety floor

These rules hold whichever surface you use; an agent that reads only this file
still gets all of them:

- **User presence (Touch ID) is required for anything that reads or mints a
  secret.** `keys get`, `keys copy`, `keys env`, `keys rotate`, `keys grant` and
  `keys client issue` each prompt, and a cancelled prompt is an answer — never
  script around it, cache the secret, or retry the prompt.
- **Never echo a key value or a token** into output, a log, a config file, a
  test or a message. `keys list` shows names only, and the MCP tools return
  labels only, for exactly this reason.
- **Never open a provider's own credential store** — `~/.codex/auth.json`,
  `~/.grok/auth.json` or equivalent. Keysrs never reads them; neither do you.
- **Configs hold no secret.** Files Keysrs writes (agent configs, the MCP
  registrations) carry URLs, paths and variable names only. Keep it that way.
- **The gateway needs a grant or a client token.** A request to
  `http://127.0.0.1:12767/<key>` is refused without one, and nothing widens a
  grant or skips user presence — the tunnel and the relay carry that check,
  they are never a way around it.

## The short reference

- `keys status --json` — plan windows; an untracked tool has no numbers at all,
  so never present an absent figure as a measured zero.
- `keys grant <key> --task "…" --minutes N --json` — one Touch ID, one scoped
  token; treat the token as a secret.
- Never run `keys` with no arguments (it starts the app or shows an alert), and
  never run a never-returning command (`keys menubar`, `keys relay run`,
  `keys tunnel` without `--print`); `keys dashboard` just shows the app's
  window and returns.

The full manual for the agent surface — the workflows, the exit codes, remote
agents and what never to do — is `docs/agents.md` in the Keysrs repository
checkout; the installed app bundle does not ship `docs/`.
