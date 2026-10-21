# The relay: reaching the gateway from a managed cloud agent

`keys tunnel` carries the gateway to a machine you can SSH into. A managed
cloud agent — a GitHub Actions job, a Claude Code or Codex cloud session, a
Modal or E2B sandbox — accepts no inbound SSH, so the tunnel cannot reach it.
The relay closes that gap with one outbound connection from the Mac to a
Cloudflare Worker that **you** deploy in **your own** Cloudflare account.

The relay is a dumb pipe. The Worker never sees, stores or handles a provider
key, and it makes no decision about who may use one. Every relayed request
lands in the same local gateway that answers `127.0.0.1:12767`, is checked
against the same grants and client tokens, has the real secret swapped in by
the same code, and is metered into the same catalog. If the Mac is off, asleep
or offline, the Worker says so and nothing is served.

Keysrs runs no hosted relay. keysrs.com stays static, and the `Site/` Worker
is unrelated to this one. The Worker source lives in `Relay/` in this
repository so you can read every line of what you deploy.

## How a call travels

```
cloud agent ──HTTPS──▶ your Worker ──WebSocket (opened by the Mac)──▶ keys relay ──loopback──▶ gateway ──▶ provider
   ksfc_…/ksf_… token          relay secret                               127.0.0.1:12767      real key
```

1. `keys relay` on the Mac opens `wss://<your worker>/connect`, presenting the
   relay secret. The Worker keeps that one socket in a Durable Object.
2. The agent calls `https://<your worker>/<key name>/v1/…` with its usual
   `ksfc_…` client token or `ksf_…` grant as the API key, exactly as it would
   call `http://127.0.0.1:12767/<key name>/v1/…` through a tunnel.
3. The Worker frames the request over the socket. `keys relay` replays it as
   an HTTP request to the local gateway on loopback, with the `Host` header
   rewritten to `127.0.0.1:12767` and a marker header (`X-KSF-Via: relay`) so
   the audit log can show the path the call took.
4. The gateway does what it always does: refuses without a valid token,
   checks scope, swaps in the Keychain secret, forwards, streams the response
   and records usage. `keys relay` streams the response back through the
   Worker as it arrives, so SSE and other streaming bodies work.

Nothing on the Mac listens on a new port. The gateway keeps its loopback bind;
the only addition is one outbound TLS connection from the Mac to the Worker.

## Setup

You need a Cloudflare account (the free Workers plan is enough: the relay uses
a SQLite-backed Durable Object, which the free plan includes) and Node 22 or
newer on the Mac.

```sh
# 1. Deploy the Worker into your own account (from a checkout of this repo).
cd Relay
npm ci                                  # pinned wrangler + test tooling
npx wrangler login                      # browser sign-in to YOUR Cloudflare account
npx wrangler deploy                     # prints https://keysrs-relay.<your-subdomain>.workers.dev

# 2. On the Mac, mint the relay secret and remember the Worker URL.
keys relay setup --url https://keysrs-relay.<your-subdomain>.workers.dev
#    prints the secret once, plus the exact command for step 3

# 3. Give the Worker the same secret (paste when prompted; it is stored as a
#    Worker secret, never in wrangler.jsonc or in the repo).
npx wrangler secret put RELAY_SECRET

# 4. Connect. One Touch ID; Ctrl-C stops the relay.
keys relay
```

Then, for the agent, issue a token as for any remote machine and point it at
the Worker instead of a forwarded port:

```sh
keys client issue router --label "github actions" --days 30 --method POST --path-prefix v1/messages
# in the agent's environment:
export ANTHROPIC_BASE_URL=https://keysrs-relay.<your-subdomain>.workers.dev/router
export ANTHROPIC_AUTH_TOKEN=ksfc_…
```

`keys relay status` shows the stored URL and whether a secret exists (its last
four characters, never the secret). `keys relay reset` forgets both; run
`npx wrangler secret delete RELAY_SECRET` or `npx wrangler delete` on the
Cloudflare side to finish. `keys purge` removes the relay secret and URL with
everything else.

The `keys relay` process needs the gateway to be running (Keysrs.app or
`keys dashboard`) and turned on for the key, the same precondition as
`keys tunnel`. It reconnects on its own when the socket drops (see
[Reconnection](#reconnection)).

## The protocol

One WebSocket per Mac, opened by the Mac. Every message is a binary frame:

```
byte 0        frame type
bytes 1–4     request id, unsigned 32-bit big-endian (0 for connection-level frames)
bytes 5–      payload (raw bytes, or UTF-8 JSON where the type says so)
```

| type | name     | direction     | payload                                                                 |
|------|----------|---------------|-------------------------------------------------------------------------|
| 0x01 | REQUEST  | Worker → Mac  | JSON `{"method","target","headers":[[name,value],…]}`                   |
| 0x02 | BODY     | both          | one chunk of request or response body, at most 64 KiB                   |
| 0x03 | END      | both          | none; the body of that request (Worker → Mac) or response (Mac → Worker) is complete |
| 0x04 | RESPONSE | Mac → Worker  | JSON `{"status","headers":[[name,value],…]}`                            |
| 0x05 | CANCEL   | Worker → Mac  | JSON `{"reason"}`; the agent went away, the Mac drops the request       |
| 0x06 | ERROR    | Mac → Worker  | JSON `{"code","message"}`; sent instead of RESPONSE, or to abort a body |

`target` is the request path and query as the Worker received them, with the
Worker's origin removed (`/router/v1/messages?beta=true`). `headers` is a
list of pairs so repeated headers survive; names are lower-cased. The
gateway reads a repeated header as one comma-separated list (RFC 9110 §5.3),
so several `anthropic-beta` lines reach the provider as one, and answers 400
when a credential header (`Authorization`, `x-api-key`, `x-goog-api-key`,
`api-key`, `X-KSF-Client`) or `Host` appears twice, so a second token cannot
ride past the grant check in a line the check did not read. The Worker
strips hop-by-hop headers and the `cf-*`, `x-forwarded-*`, `x-real-ip` and
`cdn-loop` headers Cloudflare adds before framing; the Mac strips them again,
sets `Host`, `Content-Length`, `Connection: close` and `X-KSF-Via: relay`,
and never trusts a client-supplied `X-KSF-Via`. The agent's own
`Authorization` / `x-api-key` header (the `ksfc_`/`ksf_` token) passes
through untouched, because the gateway on the Mac is what checks it.

A request is REQUEST, zero or more BODY frames, END. The Mac buffers the body
(the gateway reads whole request bodies) and forwards once END arrives. A
response is RESPONSE, zero or more BODY frames as the gateway produces them,
END. If the Mac cannot reach the gateway it sends ERROR with code
`gateway_unreachable` and the Worker answers the agent with 502. After
RESPONSE has been sent, an ERROR aborts the stream mid-body; the Worker
fails the agent's download at once whether the stream is already being read
or is still being set up. A RESPONSE with status 204, 205 or 304, or to a
HEAD request, is answered without a body and needs no END. Statuses below
200 are not part of the protocol (the gateway never produces one) and are
refused as a malformed head.

CANCEL carries why the Worker gave up, for the Mac's log only:
`client_gone` (the agent stopped reading, or its upload ended early),
`upload_timeout`, `payload_too_large`, `relay_timeout`. Whatever the reason,
the Mac drops the buffered body or shuts down its gateway connection, and the
gateway then treats the call like any dropped loopback client. Besides
`gateway_unreachable`, the Mac's ERROR codes are `bad_request_frame`,
`payload_too_large`, `gateway_write_failed`, `gateway_read_failed`,
`upload_timeout` (a REQUEST whose END did not arrive within the Mac's buffer
timeout) and `relay_buffer_full` (the oldest unfinished upload, evicted to
stay within the Mac's buffer bounds).

Request ids are chosen by the Worker (random 32-bit, unique among requests
in flight on that socket) and echoed by the Mac. Frames for an unknown id are
ignored. A REQUEST that repeats an id still open on the Mac cancels the
earlier request: the Worker never reuses an id while it is in flight, so a
repeat means the Worker has already forgotten the first one.

Keepalive: the Mac sends the text frame `ping` every 30 seconds and the
Worker answers `pong` from the Durable Object's auto-response table, which
does not wake it from hibernation. The Mac treats a ping the transport
refuses, or 60 seconds (two intervals) without any frame, pong included, as a
dead socket: it closes it and reconnects, so a connection left half-open by
sleep, a NAT timeout or a Wi-Fi roam does not hang. Any other text frame
closes the socket.

Connecting: `GET /connect` with `Upgrade: websocket`,
`Authorization: Bearer <relay secret>` and `X-Keysrs-Relay-Protocol: 1`. A
wrong or missing secret gets 401 with no further detail; a missing upgrade
426; an unknown protocol version 400 `unsupported_protocol`. **A new Mac
connection replaces the previous one**, which is closed with code 4000
(`replaced`) and whose in-flight requests fail with 502 `mac_disconnected`.
This is deliberate: a Mac that crashed or changed networks must be able to
reconnect without waiting for the stale socket to time out, and one relay
secret is meant for one Mac. Run two Macs against two Workers.

## Limits and timeouts

| what                               | limit | who enforces                              |
|------------------------------------|-------|-------------------------------------------|
| request body                       | 8 MiB | Worker (413 `payload_too_large`) and Mac  |
| requests in flight per connection  | 32    | Worker (503 `relay_busy`)                 |
| time for the request body to arrive | 60 s | Worker (408 `upload_timeout`)             |
| unfinished uploads held on the Mac | 64 requests, 32 MiB, 90 s each | Mac (ERROR `relay_buffer_full` / `upload_timeout`) |
| body chunk per frame               | 64 KiB| both                                      |
| time to first response byte        | 960 s | Worker (504 `relay_timeout`)              |
| silence between response chunks    | 300 s | Worker (stream aborted)                   |
| one response frame waiting for the socket | 60 s | Mac (replay abandoned)              |
| silence on the socket              | 60 s  | Mac (closes and reconnects)               |
| gateway request timeout (no separate connect timeout) | 900 s | the gateway (502 `upstream_error`, reason `gateway_timeout`; the response head of a non-streaming call can take minutes) |

Response bodies are streamed and not capped; the idle timeout bounds a stalled
stream. The in-flight slot is taken when the request arrives, before its body,
which is why the upload has its own deadline: without it, 32 agents sending a
byte a minute would hold every slot. The Mac's bounds exist because the Worker
checks no grant, so anyone who knows its URL can start uploads; whatever the
Worker does, what the Mac keeps for a request that has not finished arriving
is capped in number, in bytes and in time. The Worker's own platform limits
(request headers, CPU time per invocation, free-plan request counts) apply on
top. Agent errors from the Worker itself are JSON with an `error` code and a
`message`:

| status | error            | meaning                                                   |
|--------|------------------|-----------------------------------------------------------|
| 503    | `mac_offline`    | no `keys relay` is connected: the Mac is off, asleep or offline |
| 502    | `mac_disconnected` | the Mac dropped while this request was in flight         |
| 502    | `gateway_unreachable` | `keys relay` is up but the gateway on 127.0.0.1:12767 is not |
| 502    | other Mac codes  | `keys relay` could not serve it: `gateway_read_failed`, `upload_timeout`, `relay_buffer_full`, … |
| 503    | `relay_busy`     | 32 requests are already in flight                         |
| 504    | `relay_timeout`  | the Mac sent no response head within 960 s                |
| 408    | `upload_timeout` | the request body did not finish arriving within 60 s      |
| 413    | `payload_too_large` | request body over 8 MiB                                |
| 400    | `client_gone`    | the request body ended before it was complete (normally unseen: the agent has gone) |

Everything else comes from the gateway on the Mac and is unchanged: 401
`client_required`, 403 grant denials, 404 `not_found` for a key whose gateway
is off, upstream statuses (a provider's own 502 or 504 included), and the
gateway's own 502 `upstream_error` for a call that got no response head, whose
`reason` says why: `gateway_timeout` (its 900 s limit), `connect_failed`,
`tls_failed`, `connection_lost` or `network_error`. `keys log` on the Mac
shows each call with its status, duration, reason and whether it came
through the relay.

## Reconnection

`keys relay` reconnects after any close or failure with exponential backoff:
1 s, 2 s, 4 s … capped at 60 s, with ±20 % jitter, reset after a connection
that stayed up for a minute. A socket that goes quiet counts as a failure
(see Keepalive above), so a Mac coming back from sleep is relaying again
within about a minute plus one backoff step instead of waiting for the kernel
to notice. Every request open on the old socket is cancelled on the Mac,
buffered or replaying; the Worker has already answered those agents with 502
`mac_disconnected`. A 401 from the Worker (wrong secret) is reported
on stderr with the fix (`keys relay setup` again, then `wrangler secret put`)
and still retried at the capped interval, so a secret rotated on one side
first does not strand the process. Ctrl-C stops it.

## Testing it

`cd Relay && npm test` runs the Worker inside workerd with a throwaway
secret (no account, no network); `swift test --filter RelayTests` drives the
Mac side with a fake socket against the real gateway on loopback. Both are in
CI. The real transport end to end is opt-in: start `npx wrangler dev --port
8787` in `Relay/` with a `.dev.vars` holding `RELAY_SECRET=…` (git-ignored),
then run `swift test --filter RelayEndToEndTests` with `KEYS_RELAY_E2E_URL`
and `KEYS_RELAY_E2E_SECRET` set. `RELAY_UPLOAD_TIMEOUT_MS`,
`RELAY_HEAD_TIMEOUT_MS` and `RELAY_IDLE_TIMEOUT_MS` are Worker knobs for that
test suite only; a deployed Worker leaves them unset. The Worker suite must
finish with no `Uncaught (in promise)` line from workerd: the response body
is an `IdentityTransformStream` precisely because erroring a controller-driven
`ReadableStream` the agent is reading leaves two such rejections behind.

## The 401/403 circuit breaker

Independent of the relay, the gateway now pauses a key after **5 consecutive
upstream 401 or 403 responses**: for the next **60 seconds** every call with
that key is answered locally with 503 `upstream_auth_blocked`, a
`Retry-After` header and a message naming the key, without reaching the
provider. Any other upstream status resets the count; turning the gateway off
and on for the key clears the pause, and so does rotating the key (the pause
was earned by the old value). The trip is written to the key's audit
log once (`gateway_denied`, `upstream_auth_blocked`). The point is to stop an
agent's infinite retry loop against a revoked or wrong key, whether it arrives
over loopback, a tunnel or the relay.

## Threat model

The relay adds one component you do not run on the Mac: a Worker in your
Cloudflare account, speaking TLS to the agent and to the Mac. What follows is
what an attacker who controls that Worker, or your Cloudflare account, or
Cloudflare's edge, can and cannot do.

**Cannot:**

- Obtain a provider key. The Worker never receives one in either direction;
  the gateway injects the secret after the request has left the relay, on the
  Mac, and only the response body comes back. Nothing in the protocol carries
  a key, and the Mac has no frame type that would send one.
- Call the provider without a valid grant or client token. The relay secret
  authenticates the Mac to the Worker; it is not accepted by the gateway as a
  credential. A relayed request without a `ksf_`/`ksfc_` token gets the same
  401 a loopback request gets, before the key is looked up.
- Exceed a token's scope: key, methods, path prefix, expiry, grant request and
  dollar caps are all enforced on the Mac per request, and revoking the token
  stops the Worker's requests at the next call.
- Reach anything on the Mac but the gateway. `keys relay` only ever connects
  to `127.0.0.1:12767` and only replays an HTTP request there; the frame
  format has no way to name another port, host or path root.
- Read the usage catalog, the audit log, the dashboard, or other keys. The
  dashboard API is a different listener and its CSRF token is not accepted
  by the gateway.

**Can:**

- Read and alter prompts and responses in transit, because the Worker
  terminates TLS on both legs. That is the same position a tunnel host or any
  proxy holds. Treat relayed traffic as visible to whoever controls the
  Worker.
- Replay a captured request while its token is valid and within its scope,
  and so spend against your provider account up to the grant's caps. Short
  grants with `--max-requests`/`--max-usd`, narrow client scopes and prompt
  revocation bound the damage; `keys client list` shows `last used`.
- Deny service: drop or delay frames, answer the agent with errors, or hold
  the socket. The Mac keeps reconnecting; nothing persistent breaks.
- Learn when the Mac is online (503 `mac_offline` versus a gateway answer)
  and how many requests flow. The Worker does not log request or response
  bodies, tokens or `Authorization` headers, and `observability` is disabled
  in `Relay/wrangler.jsonc`; what Cloudflare records about requests to a
  Worker is governed by your account settings.

Someone who learns the **relay secret** can impersonate the Mac: connect to
your Worker, replace the real Mac's socket and receive the agent's requests,
including their tokens. They still cannot reach the gateway with those tokens
unless they can also reach your Mac's loopback. Keep the secret out of CI
logs; `keys relay setup` shows it once, stores it in the Mac's Keychain under
its own service, and `keys relay status` only ever shows its last four
characters.

Someone who learns the **Worker URL** alone can send it requests and burn
your Cloudflare request quota, and will be told whether the Mac is online.
Every one of those requests is refused on the Mac without a token.

## What changes in the privacy contract

- The Mac may hold **one outbound** connection, opened by `keys relay` and
  only while it runs, to a Worker URL you chose and deployed yourself.
  Nothing new binds on the Mac; the gateway and dashboard stay on
  `127.0.0.1`.
- Key values still never leave the Mac. Request bodies still never reach the
  usage catalog.
- Relayed calls are visible as such: the key's audit log shows
  `gateway call` with caller `relay`, and the usage rows carry the session id
  `gw-relay:<key>` instead of `gw:<key>`. The marker is a label for the
  ledger, not a privilege; a local process that forges it gains nothing.
- The relay secret is a Keysrs credential (prefix `ksfr_`), stored in the
  macOS Keychain under the service `keysreallysafe.relay`, shown once at
  setup, and never written to a config file. The Worker URL is stored in the
  catalog's `meta` table. `keys purge` removes both.
- Keysrs the project sends nothing to and receives nothing from your Worker;
  the only parties are your Mac, your Worker and your agent.
