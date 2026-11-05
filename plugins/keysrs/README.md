# Keysrs plugin

Gives Claude Code, Claude Desktop and Codex the Keysrs agent surface: the
`keysrs` skill and the `keys mcp` MCP server. Keysrs is a local Mac API-key
vault. It keeps provider keys in the macOS Keychain behind Touch ID and hands
agents scoped, expiring gateway grants instead of the keys themselves.

## Requirements

This plugin does not install Keysrs. It needs **Keysrs.app on macOS 14 or
newer**, in `/Applications`:

```sh
brew install --cask gshost1/keysrs/keysrs
```

or download the DMG from [keysrs.com](https://keysrs.com). Without the app the
MCP server fails to start and the skill has nothing to drive.

## What it runs

The plugin runs one local process, over stdio, started by your client:
`/Applications/Keysrs.app/Contents/MacOS/keys mcp`. That is the signed binary
from the app, not code from this plugin. The server returns key names, grant
state and spend figures, never a key value, and approving a grant still needs
Touch ID in the app. Nothing in this plugin sends data anywhere, holds a
secret, or phones home; the app sends no analytics.

## Install

Claude Code:

```sh
/plugin marketplace add gshost1/Keysreallysafe
/plugin install keysrs@keysrs
```

Codex:

```sh
codex plugin marketplace add gshost1/Keysreallysafe
codex plugin add keysrs@keysrs
```

Start a new session afterwards. The MCP entry assumes the app is in
`/Applications`; if you keep it elsewhere, run `keys setup mcp` instead, which
writes the real path. Details: the agent manual,
[docs/agents.md](https://github.com/gshost1/Keysreallysafe/blob/main/docs/agents.md).

MIT licensed. Privacy: [keysrs.com/privacy](https://keysrs.com/privacy).
