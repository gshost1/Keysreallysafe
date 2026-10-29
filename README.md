# Keysrs

Short-lived tokens for AI agents, on your Mac and on cloud VMs. Your real API
keys stay in the macOS Keychain; agents get a scoped token instead.

- **MCP-first.** Agents talk to Keysrs over MCP: they find keys in a project,
  import them, and ask you for access. You approve each grant with Touch ID.
- **Short-lived tokens.** A grant covers one key, one host and minutes to
  hours; a project token lasts 30 days. Revoke everything in one call.
- **Cloud VMs too.** A VM or sandbox gets a token, never the key. Its calls
  come back to the gateway on your Mac, over SSH or a relay you deploy
  yourself, and the real key is swapped in there.

Keysrs also shows what Claude Code, Codex, Grok and Droid are spending.

Free and MIT-licensed. macOS 14+ on Apple Silicon.

## Install

Download `Keysrs-arm64.dmg` from [keysrs.com](https://keysrs.com) or the
[latest release](https://github.com/gshost1/Keysreallysafe/releases/latest),
drag Keysrs to Applications and open it. It runs in the background (no Dock
icon or window until you open it again) and updates itself.

For the `keys` command line, choose **Install Command Line Tool…** in the
Keysrs menu, which links `~/.local/bin/keys`.

## Use it with your agents

```sh
keys setup mcp
```

This registers the Keysrs MCP server with Claude Code, Codex, Cursor, Droid
and Claude Desktop. Restart the agent, then ask it in plain words:

- "Scan this project for API keys with Keysrs." It finds credential-shaped
  variables in your env files and reports names and last-4 hints, never values.
- "Import and wrap this project's keys." One Touch ID moves the keys into the
  macOS Keychain and rewrites the env files to a 30-day project token.
- "Ask me for a Keysrs grant for the key anthropic, 30 minutes." You approve
  with Touch ID; the agent gets a token scoped to one key, one host and a time
  limit.
- "Revoke everything." Ends every grant and project token at once.

`keys unwrap` puts the original values back.

## Cloud VMs

```sh
keys gateway on openai                               # once per key
keys client issue openai --label "my vm" --days 7   # a revocable token for the VM
keys tunnel user@my-vm                               # VM reaches the gateway over SSH
```

On the VM, point the agent at `http://127.0.0.1:12767/openai` and use the
`ksfc_…` token as its API key. For a sandbox you can't SSH into, `keys relay`
carries the same gateway through a Cloudflare Worker you deploy into your own
account. See [cloud agents](docs/cloud-agents.md) and [the relay](docs/relay.md).

## From the command line

```sh
keys add                                  # guided: provider, name, hidden secret
keys list
keys grant openai --minutes 30            # a scoped token for a script
keys env openai OPENAI_API_KEY -- python run.py
keys spend --week
keys help                                 # every command
```

Details: [the full guide](docs/guide.md), [agents and MCP](docs/agents.md),
[cloud agents](docs/cloud-agents.md) and [the relay](docs/relay.md).

## Privacy

- Everything listens on `127.0.0.1` only. The one optional way in from
  outside is a relay Worker you deploy into your own Cloudflare account, and
  keys never travel over it.
- No tool, log, screen or report ever shows a key value. Copy, reveal, env and
  rotate ask for Touch ID every time.
- Keysrs reads only the usage files your AI tools already write. It never
  reads `~/.codex/auth.json`, `~/.grok/auth.json`, browser cookies or provider
  websites.
- Analytics ("share to compare") is off until you turn it on in the app, and
  then sends only aggregate daily counts: no prompts, key or project names,
  paths, dollar amounts or identifiers. See
  [product analytics](docs/product-analytics.md).
- Update checks are one cookieless request to GitHub's release API.

## Build from source

```sh
make build                     # signed debug CLI at .build/debug/keys
python3 scripts/build-app.py   # Keysrs.app from the release build
swift test                     # offline; CI's fixture env is in test.yml
```

Signing setup is in [SIGNING.md](SIGNING.md); `.github/workflows/test.yml` is
the full list of checks CI runs.

Keysrs was called Keysreallysafe; the repository, the Keychain service and the
data folder keep that name so existing installs keep working.

## License

MIT. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
