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
or offline, nothing is served: the Worker holds a new request for up to a
minute in case the Mac comes back, then says so.

Keysrs runs no hosted relay. keysrs.com stays static, and the `Site/` Worker
is unrelated to this one. The Worker source lives in `Relay/` in this
repository so you can read every line of what you deploy.

## How a call travels

```
cloud agent ──HTTPS──▶ your Worker ──WebSocket (opened by the Mac)──▶ the relay ──loopback──▶ gateway ──▶ provider
   ksfc_…/ksf_… token          relay secret                                 127.0.0.1:12767      real key
```

1. The relay on the Mac — inside Keysrs.app once you turn it on, or
   `keys relay` in a Terminal — opens `wss://<your worker>/connect`,
   presenting the relay secret. The Worker keeps that one socket in a Durable
   Object.
2. The agent calls `https://<your worker>/<key name>/v1/…` with its usual
   `ksfc_…` client token or `ksf_…` grant as the API key, exactly as it would
   call `http://127.0.0.1:12767/<key name>/v1/…` through a tunnel. When the
   Mac requires pairing, it also sends `X-KSF-Pair: ksfp_…`
   ([Pairing](#pairing)).
3. The Worker frames the request over the socket, the pairing credential
   included: the Worker is a pipe and checks nothing. The relay verifies the
   pairing, strips the credential header so it can never reach the gateway,
   and replays the request to the local gateway on loopback, with the `Host`
   header rewritten to `127.0.0.1:12767` and a marker header (`X-KSF-Via:
   relay`) so the audit log can show the path the call took.
4. The gateway does what it always does: refuses without a valid token,
   checks scope, swaps in the Keychain secret, forwards, streams the response
   and records usage. The relay streams the response back through the
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

# 4. Connect, in Keysrs.app: one Touch ID, then it stays on until off or quit.
keys relay on                           # or: menu bar → Relay for Cloud Agents
```

The relay runs inside Keysrs.app from then on, without a Terminal: **Relay
for Cloud Agents** in the menu bar, Settings → Relay in the dashboard, and
`keys relay on` / `keys relay off` are the same switch. It lasts until you
turn it off or quit Keysrs, reconnects on its own after a dropped socket or
sleep ([Reconnection](#reconnection)), and writes its lines to
`~/Library/Application Support/Keysreallysafe/menubar.log`. The menu and
Settings show whether it is connected, how many calls are open and the last
connection error. Each launch starts with it off, like the gateway forgets
its keys: the secret leaves the Keychain only after Touch ID.

`keys relay` on its own runs the same relay in the foreground of a Terminal
instead, logging to stderr, until Ctrl-C. Only one relay runs per Mac,
because the Worker keeps a single Mac connection and gives it to whichever
connected last: `keys relay` refuses to start while the app's relay is on,
and the app's switch refuses while `keys relay` runs. Both hold `relay.lock`
beside the catalog while they run, and the kernel releases it if either
crashes.

Then, for the agent, issue a token as for any remote machine and point it at
the Worker instead of a forwarded port:

```sh
keys client issue router --label "github actions" --days 30 --method POST --path-prefix v1/messages
# in the agent's environment:
export ANTHROPIC_BASE_URL=https://keysrs-relay.<your-subdomain>.workers.dev/router
export ANTHROPIC_AUTH_TOKEN=ksfc_…
```

`keys relay status` shows the stored URL, whether a secret exists (its last
four characters, never the secret) and which relay is running. `keys relay
setup` run again mints a new secret; a relay that is on keeps the old one until
it is turned off and on. `keys relay reset` turns the app's relay off and
forgets the URL and the secret; run
`npx wrangler secret delete RELAY_SECRET` or `npx wrangler delete` on the
Cloudflare side to finish. `keys purge` removes the relay secret and URL with
everything else.

The relay needs the gateway running (it always is inside Keysrs.app; for
`keys relay`, Keysrs.app or `keys dashboard`) and turned on for the key, the
same precondition as `keys tunnel`. It reconnects on its own when the socket
drops (see [Reconnection](#reconnection)).

## Pairing

By default any agent that holds a valid `ksfc_…`/`ksf_…` token can relay
requests. Pairing narrows that to agents you have explicitly paired with the
Mac. It is opt-in (`keys relay pair require on`, off by default, so an
existing deployment behaves exactly as before) and it is **in addition to,
never instead of, the gateway's grant and client-token checks**: a paired
request without a valid token still gets the gateway's 401, and a grant's
key/method/path scope still applies.

A pairing is a credential, `ksfp_…` (24 random bytes, hex), that the Mac
shows once at issue and stores only as a SHA-256 hash with a last-4 hint, in
the catalog next to the gateway's client tokens. The agent sends it as the
`X-KSF-Pair: ksfp_…` header on every relayed request. The Worker passes the
header through untouched — it arrives framed as `x-ksf-pair`, header names
being lower-cased — and the Mac verifies it at REQUEST time, after the head
parses and before the body is buffered, then strips the header before the
request is replayed, so the gateway, the provider and the audit log never
see the credential. A refused request costs the Mac no memory and the gateway
is never contacted; the Worker's answer is one of the four 403 codes in the
error table below. An accepted pairing's scope is a list of key names (empty
means every key), matched against the first path segment of the target, and
its `last_used_at` is updated on each accepted request.

```sh
keys relay pair issue "github actions" --key router --days 30
#    one Touch ID; prints the ksfp_… credential once (default expiry 30 days)
keys relay pair list        # labels, hints, key scopes, expiry, last used — never the credential
keys relay pair revoke "github actions"   # by label or by last-4 hint
keys relay pair require on  # the enforcement switch; `keys relay status` shows the mode
```

Because the codes are new but the frame types are not, the protocol stays
version 1: an older Worker that predates this mapping degrades a pairing
rejection to its default 502 with the code preserved — a refusal either way,
so the mismatch fails closed. Redeploying the Worker from this checkout turns
the 502 into the precise 403.

## Sleep

The Mac has to be awake and online for a call to get through; the relay does
not serve anything while the Mac sleeps. A call in flight when the Mac sleeps
or loses its network fails with 502 `mac_disconnected` (marked retryable),
because the gateway's call to the provider dies with the socket. A call that
arrives while the Mac sleeps waits in the Worker for the window (60 s by
default, [While the Mac is away](#while-the-mac-is-away)) and then gets 503
`mac_offline`. Sleep does not turn the app's relay off, though: after the Mac
wakes it notices the dead socket (the keepalive below, or the transport
failing first), redials, and is relaying again within about a minute plus one
retry step ([Reconnection](#reconnection)); requests still waiting in the
Worker are sent to it then.

**Keep Mac Awake for Relay Calls** (menu bar and Settings → Relay, off by
default, remembered across launches) takes the `PreventUserIdleSystemSleep`
power assertion, the one `caffeinate -i` takes, while a relayed call is open
and for five minutes after the last one closes, so an idle Mac does not fall
asleep under a long generation or between an agent's calls. The display can
still sleep, and closing the lid, choosing Sleep or a critical battery still
sleeps the Mac. While the assertion is held the menu's relay line and
Settings say "keeping the Mac awake", `pmset -g assertions` lists it, and
menubar.log notes when it is taken and released. `keys relay` in a Terminal
never takes it; `caffeinate -i keys relay` keeps an idle Mac awake for as
long as it runs.

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
stay within the Mac's buffer bounds). With pairing on, a request the pairing
check refuses is answered with one of the four `pairing_*` codes from the
error table below, sent instead of RESPONSE, at REQUEST time, before the body
is buffered.

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
closes the socket. The Worker reads the same pings from the other side: the
auto-response records when it last answered one, and a socket with no ping
for 45 seconds (one and a half intervals) is sent no new request, because a
Mac that fell asleep or lost its network leaves its socket open on the
Cloudflare side until TCP gives up. Such a request waits as if no Mac were
connected (see [While the Mac is away](#while-the-mac-is-away)) and goes to
the socket after all if a ping arrives in time; requests already in flight on
it are left alone.

Connecting: `GET /connect` with `Upgrade: websocket`,
`Authorization: Bearer <relay secret>` and `X-Keysrs-Relay-Protocol: 1`. A
wrong or missing secret gets 401 with no further detail; a missing upgrade
426; an unknown protocol version 400 `unsupported_protocol`. **A new Mac
connection replaces the previous one**, which is closed with code 4000
(`replaced`) and whose in-flight requests fail with 502 `mac_disconnected`
(marked retryable). This is deliberate: a Mac that crashed or changed
networks must be able to reconnect without waiting for the stale socket to
time out, and one relay secret is meant for one Mac. Run two Macs against two
Workers. For the Mac, the dial ends at the 101: it does not wait for a pong
first, because a Worker that kept requests for it sends them right behind the
101, and URLSession hands over no pong while data frames sit unread ahead of
it.

## While the Mac is away

A request that arrives while no Mac is connected — the relay on the Mac is
redialing, the Mac is asleep or offline, or its socket has gone silent — is
not refused at once. The Worker reads its body as usual (8 MiB at most, within
the 60-second upload deadline, which keeps running from arrival) and keeps it
in the Durable Object's memory, never in its storage, then waits for a Mac
until 60 seconds after the request arrived. If a Mac connects in that window
it is sent the request whole (REQUEST, BODY…, END in one go) and the agent is
answered as if nothing had happened; every request waiting at that moment
goes to it together. If the window passes first, the agent gets the 503
`mac_offline` with `Retry-After: 30` it would otherwise have got at once.

What waiting can hold is bounded: each waiting request takes one of the 32
in-flight slots (503 `relay_busy` beyond them), the bodies of all waiting
requests together are capped at 32 MiB (`relay_busy` again), and none waits
past its window, so a slot is never held longer than the longer of the
window and the upload deadline before its request is sent. Once sent, the
Mac's own buffer bounds apply as for any request.

The window is for new requests only. A request already sent to a Mac whose
socket then drops cannot be resumed: the gateway's call to the provider died
with that socket, and the provider may already have started, and billed,
it. Such a request still fails with 502 `mac_disconnected`, whose JSON says
`"retryable": true`; an agent that sends it again while the Mac is still
reconnecting has its retry wait in the window like any new request. Nor can
the Worker tell whether a waiting request's agent has given up: such a
request is still sent when the Mac comes back, the gateway makes the call,
and the Worker, finding nobody to stream the answer to, cancels it on the
Mac.

`RELAY_OFFLINE_GRACE_MS` sets the window in milliseconds. `0` turns waiting
off and restores the immediate 503; values above 600000 (ten minutes, the
default request timeout of the Anthropic and OpenAI SDKs) are held to that.
It is a plain Worker variable, not a secret: `npx wrangler deploy --var
RELAY_OFFLINE_GRACE_MS:0`, or a `vars` entry in `Relay/wrangler.jsonc`.

## Limits and timeouts

| what                               | limit | who enforces                              |
|------------------------------------|-------|-------------------------------------------|
| request body                       | 8 MiB | Worker (413 `payload_too_large`) and Mac  |
| requests in flight or waiting for the Mac | 32 | Worker (503 `relay_busy`)            |
| time for the request body to arrive | 60 s | Worker (408 `upload_timeout`)             |
| time a request waits for a Mac when none is connected | 60 s from arrival; `RELAY_OFFLINE_GRACE_MS`, 0 to 600 s | Worker (503 `mac_offline`) |
| bodies kept for waiting requests   | 32 MiB in total | Worker (503 `relay_busy`)       |
| no ping on a socket                | 45 s  | Worker (sends it no new request)          |
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
byte a minute would hold every slot. A request waiting for the Mac keeps its
slot too, which is what stops the wait from growing into a queue. The Mac's
bounds exist because the Worker
checks no grant, so anyone who knows its URL can start uploads; whatever the
Worker does, what the Mac keeps for a request that has not finished arriving
is capped in number, in bytes and in time. The Worker's own platform limits
(request headers, CPU time per invocation, free-plan request counts) apply on
top. Agent errors from the Worker itself are JSON with an `error` code and a
`message`, and the three an agent may simply send again (`mac_offline`,
`mac_disconnected`, `relay_busy`) also carry `"retryable": true`. The four
pairing codes carry neither that flag nor a `Retry-After`: resending the
identical request cannot change the answer, only a change on the Mac can.

| status | error            | meaning                                                   |
|--------|------------------|-----------------------------------------------------------|
| 503    | `mac_offline`    | no Mac connected within the window (60 s by default, at once with `RELAY_OFFLINE_GRACE_MS=0`): the relay is not running, or the Mac is off, asleep or offline; `Retry-After: 30` |
| 502    | `mac_disconnected` | the Mac dropped while this request was in flight; it may be retried (see [While the Mac is away](#while-the-mac-is-away)) |
| 502    | `gateway_unreachable` | the relay is up but the gateway on 127.0.0.1:12767 is not |
| 403    | `pairing_required` | the Mac requires paired agents and this request carried no usable `X-KSF-Pair` credential (missing, malformed or unknown); refused at REQUEST time, before the body was buffered |
| 403    | `pairing_expired` | the pairing has expired; issue a new one with `keys relay pair issue` |
| 403    | `pairing_revoked` | the pairing was revoked on the Mac |
| 403    | `pairing_out_of_scope` | the pairing is valid but does not cover the key this request targets |
| 502    | other Mac codes  | the relay on the Mac could not serve it: `gateway_read_failed`, `upload_timeout`, `relay_buffer_full`, … |
| 503    | `relay_busy`     | 32 requests are already in flight or waiting, or the waiting ones hold 32 MiB of bodies; `Retry-After: 5` |
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

The relay, in the app or in a Terminal, reconnects after any close or failure
with exponential backoff:
1 s, 2 s, 4 s … capped at 60 s, with ±20 % jitter, reset after a connection
that stayed up for a minute. A socket that goes quiet counts as a failure
(see Keepalive above), so a Mac coming back from sleep is relaying again
within about a minute plus one backoff step instead of waiting for the kernel
to notice. Every request open on the old socket is cancelled on the Mac,
buffered or replaying; the Worker has already answered those agents with 502
`mac_disconnected`. Requests that arrived while the Mac was away have been
waiting in the Worker and arrive the moment the new socket is up, at most 32
of them at once, each one whole. A 401 from the Worker (wrong secret) is reported
with the fix (`keys relay setup` again, then `wrangler secret put`) in the
relay's log, menubar.log for the app and stderr for `keys relay`, and as the
last error in the menu and Settings, and still retried at the capped
interval, so a secret rotated on one side first does not strand the relay.
Turning it off, quitting Keysrs or Ctrl-C closes the socket at once, even
mid-dial, and the Worker fails what was in flight on it with 502
`mac_disconnected`.

## Testing it

`cd Relay && npm test` runs the Worker inside workerd with a throwaway
secret (no account, no network); `swift test --filter RelayTests` drives the
Mac side with a fake socket against the real gateway on loopback, and
`RelayHostTests` the app's relay (the lock, turning it on and off, the
idle-sleep assertion with a fake in place of IOKit, `/api/relay`). The Worker
suite also pins the pairing surface: each of the four `pairing_*` ERROR codes
becoming its 403 with no retry guidance, the other Mac codes staying 502, and
`x-ksf-pair` passing through into the REQUEST frame untouched. On the Mac
side `RelayTests` covers the verification (accept; missing, unknown and
malformed credentials; expiry at the boundary; revocation across a
reconnect; out-of-scope keys; the credential stripped before replay) and
`RelayPairingTests` the management surface (issue, list, revoke, require
on/off). All are in CI. The real transport end to end is opt-in: start `npx wrangler dev --port
8787` in `Relay/` with a `.dev.vars` holding `RELAY_SECRET=…` (git-ignored),
then run `swift test --filter RelayEndToEndTests` with `KEYS_RELAY_E2E_URL`
and `KEYS_RELAY_E2E_SECRET` set. Add `--var RELAY_OFFLINE_GRACE_MS:3000` to
`wrangler dev` and `KEYS_RELAY_E2E_GRACE_MS=3000` to the test to cover the
outage case: a call made while the app's relay is off waits and is answered
once it is on again, and one made with the relay off past the window gets the
JSON 503. `RELAY_UPLOAD_TIMEOUT_MS`,
`RELAY_HEAD_TIMEOUT_MS` and `RELAY_IDLE_TIMEOUT_MS` are Worker knobs for that
test suite only; a deployed Worker leaves them unset (`RELAY_OFFLINE_GRACE_MS`
is the one meant for deployments). The Worker suite must finish with no
`Uncaught (in promise)` line from workerd: the response body is an
`IdentityTransformStream` precisely because erroring a controller-driven
`ReadableStream` the agent is reading leaves two such rejections behind.
`npm test` runs the suite through `test/run.mjs`, which fails the run when
such a line appears.

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
- Reach anything on the Mac but the gateway. The relay only ever connects
  to `127.0.0.1:12767` and only replays an HTTP request there; the frame
  format has no way to name another port, host or path root.
- Read the usage catalog, the audit log, the dashboard, or other keys. The
  dashboard API is a different listener and its CSRF token is not accepted
  by the gateway.
- Spend anything with a stolen `ksfp_…` pairing credential on its own.
  Pairing is verified by the Mac in addition to the gateway's grant and
  client-token checks, never instead of them: without a valid token the
  request still gets the gateway's 401, and with one it stays inside that
  token's scope and caps.

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
- Learn when the Mac is online (a gateway answer versus 503 `mac_offline`
  once the window passes) and how many requests flow. The Worker does not log request or response
  bodies, tokens or `Authorization` headers, and `observability` is disabled
  in `Relay/wrangler.jsonc`; what Cloudflare records about requests to a
  Worker is governed by your account settings.
- Tell `pairing_expired` and `pairing_revoked` apart from `pairing_required`
  when the Mac requires pairing. The distinct codes are a deliberate,
  documented trade-off: they tell the agent's owner which fix applies, and
  they are visible to anyone who can already reach the Worker.
  `pairing_required` itself covers missing, malformed and unknown credentials
  alike, so it gives away nothing about whether a credential ever existed.

Pairing state — the `relay_pairings` table and the `relay_pairing_required`
flag — lives only on the Mac, in the catalog beside the gateway's client
tokens; the Worker stores none of it and frames `X-KSF-Pair` like any other
header. Brute-forcing a `ksfp_…` against the relay is bounded by the
constant-time comparison the Mac applies to it, by the existing bounds on
both sides (the Worker's 32 in-flight slots and the Mac's buffer caps) and by
the credential being 24 random bytes.

Someone who learns the **relay secret** can impersonate the Mac: connect to
your Worker, replace the real Mac's socket and receive the agent's requests,
including their tokens. They still cannot reach the gateway with those tokens
unless they can also reach your Mac's loopback. Keep the secret out of CI
logs; `keys relay setup` shows it once, stores it in the Mac's Keychain under
its own service, and `keys relay status` only ever shows its last four
characters. While a relay is on, the secret is in the memory of the process
running it, as a key is while the gateway holds it; the dashboard's
`/api/relay` reports the state and the Worker URL, never the secret or its
hint.

Someone who learns the **Worker URL** alone can send it requests and burn
your Cloudflare request quota, and will be told whether the Mac is online.
While the Mac is away they can also fill the 32 waiting slots and the 32 MiB
of kept bodies, a minute at a time, so that your agents get `relay_busy`
instead of waiting; that is all the window adds. Every one of those requests
is refused on the Mac without a token, the waiting ones included once it is
back.

## What changes in the privacy contract

- The Mac may hold **one outbound** connection, to a Worker URL you chose and
  deployed yourself, and only while the relay is on: in Keysrs.app from the
  moment you turn it on (one Touch ID) until you turn it off or quit, never
  at launch by itself, or while `keys relay` runs in a Terminal. One relay
  at a time.
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
- Pairing credentials (`ksfp_…`) follow the same discipline as the gateway's
  client tokens: shown once at issue, stored on the Mac as SHA-256 hashes
  with a last-4 hint, never held or logged by the Worker. `keys purge`
  removes them and the pairing-required flag.
- Keysrs the project sends nothing to and receives nothing from your Worker;
  the only parties are your Mac, your Worker and your agent.
