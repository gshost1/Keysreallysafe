# Project-local client setup (Claude Code and Codex)

These commands attach the project-scoped Keys Optimizer MCP server, and optionally
the Jev compaction launcher, to **one client session in one project**. They do not
edit `~/.claude`, `~/.claude.json`, `~/.codex/config.toml` or any other client
configuration, and they contain no credential: only the Optimizer project UUID and
the *name* of a key stored in Keys. The secret never leaves Keys.

Values used below:

| Value | Here |
| --- | --- |
| Project directory | `/Users/Shost2/keys-jev-savings` |
| Stored key name (Vercel AI Gateway) | `jev-ass` |
| Optimizer project UUID | `PROJECT_UUID` — replace with the UUID shown for this project in the Optimizer pane. The UUID from the live validation run belongs to a synthetic scratch project, not to this directory. |
| Keys executable | `/Users/Shost2/.local/bin/keys` |

## Generate and verify

```sh
python3 scripts/optimizer-client-setup.py --project PROJECT_UUID --jev-key jev-ass --check
```

This prints the commands below with your values and checks, using `--help` output
and file presence only, that: the UUID is well formed, `keys optimizer mcp` accepts
`--project/--minutes/--writable/--jev-key`, the MCP adapter script and the bundled
Claude plugin exist, `claude` offers `--mcp-config` and `--plugin-dir`, and `codex`
offers `-c/--config` and `--cd`. It exits 3 when a required check fails (including
a placeholder UUID). It never unlocks the Optimizer, requests a grant, or starts a
client. Add `--writable` to let the session save entries and record task usage.

Verified on this machine on 2026-09-19 against Claude Code 2.1.276, codex-cli
0.154.0 and the installed Keys build: every check passed except the placeholder UUID.

## Claude Code

Write the session's MCP file once into the project (ignored by git, never overwritten):

```sh
python3 scripts/optimizer-client-setup.py --project PROJECT_UUID --jev-key jev-ass \
  --write-example /Users/Shost2/keys-jev-savings/.keys
```

It contains:

```json
{
  "mcpServers": {
    "keys_optimizer": {
      "type": "stdio",
      "command": "/Users/Shost2/.local/bin/keys",
      "args": ["optimizer", "mcp", "--project", "PROJECT_UUID", "--minutes", "30", "--jev-key", "jev-ass"]
    }
  }
}
```

MCP tools only:

```sh
cd /Users/Shost2/keys-jev-savings && MCP_TIMEOUT=120000 claude --mcp-config /Users/Shost2/keys-jev-savings/.keys/keys-optimizer.mcp.json
```

MCP tools plus Jev compaction (the launcher loads the bundled plugin with
`--plugin-dir` and passes everything after `--` to Claude):

```sh
cd /Users/Shost2/keys-jev-savings && MCP_TIMEOUT=120000 python3 /Users/Shost2/keys-jev-savings/scripts/claude-with-jev.py jev-ass \
  --keys /Users/Shost2/.local/bin/keys -- --mcp-config /Users/Shost2/keys-jev-savings/.keys/keys-optimizer.mcp.json
```

`MCP_TIMEOUT` (milliseconds) gives the presence prompt time to be approved while
the server starts. It is an environment variable of the installed Claude Code, not
a flag, so `--help` cannot confirm it; the installed binary does reference it.
Add `--strict-mcp-config` after `--mcp-config …` to ignore other configured MCP servers for that session.

## Codex

Per-invocation overrides; `~/.codex/config.toml` is not touched:

```sh
codex --cd /Users/Shost2/keys-jev-savings \
  -c 'mcp_servers.keys_optimizer.command="/Users/Shost2/.local/bin/keys"' \
  -c 'mcp_servers.keys_optimizer.args=["optimizer", "mcp", "--project", "PROJECT_UUID", "--minutes", "30", "--jev-key", "jev-ass"]' \
  -c mcp_servers.keys_optimizer.startup_timeout_sec=120 \
  -c mcp_servers.keys_optimizer.tool_timeout_sec=45
```

Codex gets MCP tools only. There is no supported way for Keys to compact or
rewrite Codex's context, and nothing here switches its model.

If you later decide to make this permanent, the helper also prints the equivalent
`[mcp_servers.keys_optimizer]` TOML block. Adding it to a configuration file is a
deliberate manual step and makes the server available in every Codex project.

## What to expect

- Each client start raises a presence prompt in Keys for the MCP session. The
  compaction launcher raises one more for its scoped grant and revokes it on exit.
- Sessions default to 30 minutes (`--minutes` 1–120). After expiry, tools report
  `session_locked_or_expired`; restart the client to re-approve.
- Tool and model results are suggestions. Nothing is applied or routed automatically.
- Not validated here: a live Claude Code or Codex session using these commands.
  That needs the real project UUID and your approval.

### Direct TypeSafe

Pass `--provider typesafe --jev-key YOUR_STORED_TYPESAFE_KEY_NAME` to the setup
helper to select the direct protocol in generated compaction-launcher commands.
The MCP server discovers the protocol from the vault catalog. Never put the key
value in a configuration file. If an MCP server is already registered locally,
use that connection instead of adding a second server for the same project.
