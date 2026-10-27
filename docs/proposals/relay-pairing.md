# Paired remote requests for the relay

A proposal, before any code. It describes the problem, the pairing flow, what
changes on the wire and at the CLI, and why the result does not weaken the
threat model in [docs/relay.md](../relay.md) or the README's privacy
boundaries. Alternatives that were considered and rejected are listed last.

## The problem

Today the relay gates on two things: the agent must know the Worker's URL, and
it must carry a valid `ksfc_…` client token or `ksf_…` grant, which the
gateway on the Mac checks per request. That is enough for a single agent you
set up yourself, but it is not per-agent admission control. Every agent that
holds a valid token for a key is interchangeable with every other: there is no
way to say "this specific GitHub Actions workflow may reach the Mac, that one
may not", no way to see which agent called, and no way to cut one agent off
without revoking the token it shares with the rest. The Worker cannot help:
it is a dumb pipe by design and stores nothing, so on the Mac side of the
relay there is simply no place where one remote caller is distinguished from
another.

Pairing adds that place. The user pairs a remote agent with the Mac, the agent
presents a pairing credential (`ksfp_…`) on every relayed request, and the Mac
verifies it — with expiry and revocation — before the request body is even
buffered. Pairing is an additional gate, never a substitute: a paired request
still passes through the same loopback gateway and its unchanged grant and
client-token checks.

## The flow, end to end

1. **Issue.** `keys relay pair issue "github actions" [--key <name>]…
   [--days <n>]` runs against the running app. One Touch ID (the same presence
   gate as `keys client issue`) mints a `ksfp_…` credential — 24 random bytes,
   hex-encoded, mirroring `GatewayClientToken` — and prints it exactly once,
   with the exact environment lines for the agent. Only its SHA-256 hash and
   last-4 hint are stored, in a new `relay_pairings` table in the catalog
   database next to `gateway_clients`: `label`, `token_hash` (UNIQUE),
   `hint`, `keys` (comma-separated key names; empty = all keys),
   `created_at`, `expires_at`, `revoked_at`, `last_used_at`. Pairing records
   are hashes, not secrets, so the catalog — not the Keychain — is the right
   home, same posture as client tokens. A live label cannot be issued twice;
   revoking a label frees it for re-issue as a new row.
2. **Install.** The agent gets the credential as one extra default header
   beside its token:

   ```sh
   export ANTHROPIC_BASE_URL=https://<your worker>/router
   export ANTHROPIC_AUTH_TOKEN=ksfc_…
   # one new default header on the agent's HTTP client:
   X-KSF-Pair: ksfp_…
   ```

   The Worker passes the header through untouched (it is not in the hop-by-hop
   strip set and matches none of the `cf-*` / `x-forwarded-*` / `x-real-ip` /
   `cdn-loop` prefixes).
3. **Require.** Pairing enforcement is opt-in: `keys relay pair require on`
   sets a `relay_pairing_required` flag in the catalog's `meta` table.
   Default is off, and off is byte-for-byte today's behavior — existing
   deployments and tests are untouched. `keys relay status` shows the mode
   and the live pairing count.
4. **Verify, per request.** With the flag on, the Mac's relay checks the
   credential when a REQUEST frame arrives: after the head is parsed, before
   the request id enters the body buffer. The check is a sub-millisecond
   SQLite read of hashes — no Keychain access, no per-request Touch ID. A
   missing, malformed or unknown credential is refused with
   `pairing_required`; an expired one with `pairing_expired`; a revoked one
   with `pairing_revoked`; a valid pairing whose key list does not cover the
   request's target key (the first path segment of `target`) with
   `pairing_out_of_scope`. The refusal is an ERROR frame on that id; the id is
   never buffered and the gateway is never contacted. On acceptance,
   `last_used_at` updates, `X-KSF-Pair` is **stripped** from the headers
   replayed to the gateway (the gateway forwards unknown headers upstream, so
   without the strip the credential would reach the provider and the audit
   log), and the request continues through the gateway's normal checks —
   401 `client_required` without a token, 403 on a grant-scope miss, exactly
   as for any relayed call today.
5. **Expire and revoke.** Every pairing carries an expiry: `--days` sets it,
   the default is 30, and expiry is always set (a request at exactly
   `expires_at` is expired). `keys relay pair revoke <label-or-hint>` sets
   `revoked_at` (an ambiguous hint is refused with the colliding labels
   named); the row stays, the hash stays, and the next request carrying that
   credential gets `pairing_revoked` — across reconnects, because revocation
   lives in the catalog, not in connection state.
6. **Purge.** `keys purge` clears the `relay_pairings` rows and the
   `relay_pairing_required` flag with everything else, returning the relay to
   default-off with zero pairings.

## Wire impact

- **No new frame types.** REQUEST, BODY, END, RESPONSE, CANCEL, ERROR stay
  0x01–0x06 with the same payloads.
- **Protocol stays v1.** The pairing credential rides in a header inside the
  REQUEST payload, and the four rejection codes are values of the existing
  ERROR frame's `code` field. Nothing an older Worker must parse differently:
  an older Worker maps the unknown codes to 502 like any other Mac error,
  which is a refusal — the design fails closed, so no redeploy is forced.
- **One passthrough header.** `X-KSF-Pair: ksfp_…` travels from agent to Mac
  inside the framed request, is verified there, and is stripped before replay.
  The Worker treats it as just another header and stores nothing about it.
- **Four new Mac ERROR codes**, sent instead of RESPONSE at REQUEST time:
  `pairing_required`, `pairing_expired`, `pairing_revoked`,
  `pairing_out_of_scope`. The Worker's one change is to map these four to
  HTTP **403** with the usual `{"error","message"}` JSON body (no
  `retryable`, no `Retry-After`: resending the identical request cannot fix an
  expired, revoked or out-of-scope pairing). Every other Mac code stays 502.

## CLI and API surface

Mirrors `keys client issue/list/revoke`, nested under `keys relay`:

| Command | Effect |
|---|---|
| `keys relay pair issue <label> [--key <name>]… [--days <n>]` | mints under one Touch ID; prints the credential once |
| `keys relay pair list` | label, hint, key scope, expiry, revoked, last used — never the credential or its hash |
| `keys relay pair revoke <label-or-hint>` | sets `revoked_at`; ambiguous hint refuses |
| `keys relay pair require on\|off` | flips the `relay_pairing_required` flag |
| `keys relay status` | additionally shows the pairing mode and live pairing count |

The commands talk to the running app through `ControlClient`, exactly like
`keys client issue`, against a new `/api/relay/pairings` route family in the
loopback HTTP server: mutating routes take the existing mutating-API token
gate, mint additionally requires presence, and JSON responses carry hints and
metadata only — the single exception being the one-time mint response that
returns the credential, the same contract as client issue. Parse errors
(unknown flags, zero or negative `--days`) fail before any app contact.

## Threat model: what pairing does not change

The adversary is the one docs/relay.md already considers: someone who controls
the Worker, your Cloudflare account, or Cloudflare's edge — now additionally
holding, or guessing at, a pairing credential. In the same Cannot/Can style:

**Cannot:**

- Turn a pairing credential into provider access. A `ksfp_…` is not accepted
  by the gateway as anything; a relayed request without a valid grant or
  client token still gets the gateway's own 401 `client_required`, pairing or
  not, and an out-of-scope grant still gets the gateway's 403. A stolen
  `ksfp_…` is useless without a valid token, exactly as a stolen token without
  the Worker URL gets nothing.
- Obtain a provider key through the pairing machinery. No frame type carries
  a key (the frame set is unchanged), and the pairing credential itself is
  stripped on the Mac before replay, so it never reaches the gateway, the
  provider or the audit log.
- Learn the credential from storage. The catalog holds a SHA-256 hash and a
  last-4 hint; the credential is printed once at issue and appears in no log,
  no list output and no API response afterwards.
- Move verification off the Mac. The Worker stores no pairing state and makes
  no access decision; pairing state lives only in the catalog on the Mac,
  which an attacker at the Worker cannot read or write.
- Brute-force a pairing online at useful speed. Guesses are bounded by the
  relay's existing buffer caps (32 requests in flight, 8 MiB per body, the
  Mac's 64-request/32 MiB/90 s upload bounds) and each guess costs a
  constant-time hash comparison of a 192-bit space; there is no oracle —
  missing, malformed and never-issued credentials all answer
  `pairing_required` identically.
- Weaken an existing deployment. Pairing is opt-in; with the flag off the
  code path is byte-for-byte today's, and a Mac running this build against an
  older Worker still refuses unpaired requests — they surface as 502 instead
  of 403, never as acceptance.

**Can:**

- Tell a rejected paired request apart from a rejected unpaired one. Distinct
  codes (`pairing_expired`, `pairing_revoked`, `pairing_out_of_scope` versus
  `pairing_required`) reveal pairing state to anyone who can already reach the
  Worker and knows a valid credential exists. This is deliberate: the
  operational value of "revoke it, the agent sees why" outweighs hiding state
  from an observer who already sees every request and response body. The
  codes are documented, and an operator who disagrees leaves pairing off.
- Keep guessing within the bounds above, and learn when the Mac is online —
  the same visibility docs/relay.md already grants whoever controls the
  Worker. Pairing adds nothing to log: the Worker keeps its no-observability
  posture and gains no console output.

And the privacy contract holds as written: no Keysrs-hosted service is added
(the Worker remains user-deployed, and pairing adds nothing to deploy),
nothing new binds on the Mac, key values still never leave it, request bodies
still never reach the catalog, and the credential never crosses the relay in
the Mac→Worker direction at all.

## Considered and rejected

| Alternative | Why rejected |
|---|---|
| Pairing state in the Worker (Durable Object storage, Worker-side verification) | Violates the dumb-pipe design: the Worker would hold access-control state and make access decisions, and every pairing operation would need a write path to the edge. Verification belongs on the Mac, where the catalog already lives. |
| Pairing credential replacing the grant/client token | Violates the brief and the layered design: the gateway's grant checks (key, scope, caps, expiry) are the authorization decision; pairing only decides which remote agent may present a request to them. One credential doing both would also put a usable credential on the wire instead of a gate key. |
| Protocol v2 bump | Buys nothing and costs every user a redeploy. The change is additive — one header inside an existing frame, four values of an existing error field — and older Worker's degrade rejections to 502, still refusing. v1 stays. |
| Always-on enforcement | Breaks every existing deployment and tunnel-style ad-hoc use the day the code ships. Opt-in (default off) keeps today's behavior byte-for-byte until the user asks for the gate. |
| Dashboard / menu bar UI for pairing | Out of scope for this change; the CLI plus the `/api/relay/pairings` routes come first and leave the UI a purely additive follow-up. |
| Any Keysrs-hosted component (hosted pairing registry, hosted relay) | Contradicts the distribution and privacy contract: Keysrs hosts nothing, keysrs.com stays static, and the only parties remain your Mac, your Worker and your agent. |
