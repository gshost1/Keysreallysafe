# Cloud agents: using the vault from another machine

An agent that runs somewhere else — a server, a VM, a container, a self-hosted
CI runner, a Droid computer you can SSH into — can use a key from the Keysrs
vault without the key ever leaving the Mac. The mechanism is the same gateway a
local agent uses, carried over an SSH reverse forward.

The rules that make this safe are the same ones the local gateway follows:

- The gateway keeps binding `127.0.0.1:12767` on the Mac. `keys tunnel` does
  not open a port on the Mac; it opens a port on the *remote* machine that
  forwards back through the ssh connection to the Mac's loopback.
- The remote side still needs a credential: a long-lived client token
  (`ksfc_…`, a hash in the catalog, revocable, expiring in days) presented
  where the agent would put an API key. The ssh session is the trust boundary.
- The token is scoped: one key, chosen HTTP methods, an optional upstream path
  prefix. Revoke it from the dashboard or `keys client revoke` and the remote
  stops working at the next request.

## The three steps

On the Mac (the machine with the vault):

```sh
# 1. Enable the gateway for the key once (the dashboard's G, or keys grant once).
# 2. A long-lived token for the remote machine:
keys client issue router --label "cloud agent" --days 30
# 3. Carry the gateway there:
keys tunnel user@server.example.com
```

`keys tunnel` runs `ssh -N -R 12767:127.0.0.1:12767 user@server.example.com`
with keepalives and `ExitOnForwardFailure=yes`, so a dead forward fails loudly
instead of hanging. `--remote-port` changes the port on the remote side, and
`--print` shows the command instead of running it. Ctrl-C stops the tunnel; the
gateway keeps its loopback bind and the token stays valid.

On the remote machine, the vault is now a plain local URL:

```sh
export OPENAI_BASE_URL=http://127.0.0.1:12767/router
export OPENAI_API_KEY=ksfc_…            # the client token, not the real key
```

Every call is routed, metered on the Mac like any other gateway call (Chart →
API keys), and refused once the token is revoked or expired.

## What each agent needs there

The recipes are the same as local ones, with the base URL pointing at the
forwarded port:

- **Droid**: `~/.factory/settings.json` on the remote machine gets a
  `customModels` entry with `"baseUrl": "http://127.0.0.1:12767/router"` and
  `"apiKey": "ksfc_…"` (or an env reference the shell profile fills). Run
  `keys setup droid` on the Mac and copy the entry it prints; the paths are
  the only difference.
- **Codex**: `~/.codex/config.toml` there gets the same
  `[model_providers.keysrs]` block, with the base URL on the forwarded port and
  `api_key` set directly (no `env_key` indirection needed for unattended runs).
- **Grok**: `[model.keysrs]` in `~/.grok/config.toml` there, same change.
- **Claude Code**: `ANTHROPIC_BASE_URL=http://127.0.0.1:12767/router` and
  `ANTHROPIC_AUTH_TOKEN=ksfc_…` in the environment there.

Because these configs hold a revocable, expiring token and not the real key, a
compromised remote machine leaks a scoped credential, not the provider key.
Treat the token like a password anyway: revoke it when the work is done, and
give each remote machine its own token with its own label so the dashboard's
client list shows which one to pull.

## Where this works

- **Any machine you can SSH to from the Mac**: the tunnel is outbound from the
  Mac, so the remote needs no inbound access to your Mac. Cloud VMs, colo
  boxes, Raspberry Pis, and Tailscale hosts all work (with Tailscale, the
  user@host is the server's tailnet name).
- **Self-hosted CI runners**: start the tunnel from the Mac in one terminal, or
  run `ssh -R` as a service on the runner's side pointing at your Mac over
  Tailscale, and put the token in the runner's secret store.
- **GitHub-hosted runners do not work**: they cannot reach your Mac and you
  cannot hold a tunnel open to them. Use a self-hosted runner, or run the agent
  on a machine you control.
- **Containers**: tunnel into the host; from inside a container on that host
  use the host's `127.0.0.1:12767` (or publish the forwarded port to the
  container's loopback).

## Trust boundaries, stated plainly

- Someone with a shell on the remote machine can use the key until the token
  expires or is revoked. Scope it: `--method POST --path-prefix v1/messages`
  narrows what that machine can do with your provider account.
- The token is a bearer credential on the wire between the remote and the
  gateway; the ssh tunnel encrypts that hop. Do not paste a token into a
  shared CI log or a public repository.
- Tokens are one per purpose, not one per person: a second remote machine gets
  its own token, so revoking one does not disturb the other.
- Everything the local privacy contract says still applies: request bodies
  never reach the usage catalog, key values never appear on screen or in logs,
  and the gateway forgets the secret when the app restarts until you turn it
  on again.
