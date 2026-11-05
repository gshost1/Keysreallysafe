# Security policy

Keysrs holds API keys, so security reports get priority over everything else.

## Reporting a vulnerability

Email **support@keysrs.com** with "security" in the subject. Please don't open
a public issue for anything that could expose a key, bypass Touch ID, widen a
grant, or let something other than a granted request through the gateway or
relay.

Include the Keysrs version (`keys --version`), macOS version, and steps to
reproduce. Never send a real API key; a placeholder is enough.

Fixes ship as a new release through the app's built-in updater and the
Homebrew cask.

## Supported versions

Only the latest release gets security fixes. The app updates itself, so
staying current is the fix.

## Scope

- The `keys` app and CLI, its MCP server, the local gateway and grants.
- The relay Worker in `Relay/` (each user deploys their own copy).
- The agent plugin in `plugins/keysrs`.
- keysrs.com and its `/api/notify` form.

The Privacy section of the README is the contract: anything that breaks it is
in scope.
