# Permission profiles: saved grant bounds, and honest unattended use

Every grant today is decided at the prompt, all at once: which key, which
methods, which paths, how many minutes, what caps. That is the right shape for
a task you are around for, but it leaves the recurring cases to be re-decided
from scratch each time, and it leaves one case dishonest: a job meant to run
while you are away — an overnight eval sweep, a long agent session started
before dinner — has no way to say so. Today that job either gets a wide,
long grant and the user leaves, or the grant dies at the first screen lock.
The README already answers the extreme end: a job that has to outlive a
screen lock needs a client token. Between "I am at the keyboard" and "it must
survive my Mac locking" there is a real middle — a grant the user approved
*as* unattended, bounded so it can be trusted unwatched — and right now that
middle is implicit: nothing on the grant records what it was for.

The design in one sentence: a **permission profile** is a named, saved set of
issuance-time bounds — key names, methods, path scopes, minutes, a request
cap, a dollar cap, and an `unattended` flag — consulted only when a grant is
*issued*, never when a request is *authorized*. Profiles bound; they are not
authority. A grant minted under a profile is an ordinary, self-contained
grant: editing or deleting the profile afterwards changes nothing about it.

This serves the person who runs agents against their own keys. `keys profile
add evals --keys router --methods POST --paths /v1/messages --minutes 480
--max-requests 500 --max-usd 2 --unattended`, then `keys grant router
--profile evals` — one Touch ID whose prompt names the profile *and the
effective scope*, and an overnight run that dies at screen lock, expiry or
its caps exactly as a watched grant would.

## The grant model today

The README "Privacy boundaries" section is the contract. The sentences this
proposal must not weaken, quoted verbatim:

> No open gateway. A request through the gateway needs a grant token: one
> Touch ID per task, bound to one key, one host, a method and path scope and
> an expiry. Screen lock, revoke, gateway off or a restart kills it. That
> holds for a relayed request too: the relay secret lets a Worker talk to
> this Mac, never to a provider. After five consecutive upstream 401/403
> answers the gateway pauses the key for a minute and says so, instead of
> letting an agent retry against a dead key.

> That is deliberate: a grant is for a task you are around for, so an
> unattended job that has to outlive a screen lock needs a client token
> (`keys client issue`) instead. Grants live only in the app's memory; the
> audit log keeps the id, task and scope, never the token.

> The usage catalog stores only counters and metadata. Gateway request
> bodies never reach that catalog.

> No secret on screen by default. The key list shows names, never values.
> Copy, reveal, env and rotate ask for user presence every time.

And from the gateway docs:

> **A grant** is for one task: short-lived, in memory only, one Touch ID
> whose prompt names the task, provider, host and lifetime.

How that works in the source, re-verified at `ffd3df4` (line numbers are
from that commit):

1. `KeysService.issueGrant` (`KeysService.swift:547-578`) is the only issuer.
   Order: `requireGatewayOwner()` (only the gateway-owning process named in
   `control.json` mints grants, `:1471`), key row, `request.validated()`
   (`:554` — task ≤120 chars, minutes 1…1440, methods ⊆ `Grant.allMethods`,
   `maxRequests ≥ 1`, `maxUsd > 0`, paths normalized) — **all of it before
   any prompt**. Then one presence prompt: `presence.require(reason:)` if
   the gateway is already on for that host, else `setGateway(enabled: true,
   …, reason:)` folds gateway-on into the same single prompt (`:564-568`).
   Then `grants.prune()`, `grants.issue(…)`, and an audit row
   (`action: "grant"`, detail = id, task, expiry, host, scope, caps — never
   the token, `grantDetail` `:587-594`).
2. The prompt string is `grant "<task>" the key <key> for <Provider> at
   <host>, <span>` with span `N h` for whole hours ≥60, else `N min`
   (`grantReason`, `KeysService.swift:582-585`). It is pinned byte-for-byte
   by `GrantTests.swift:184`.
3. A grant lands in `GrantStore` (`Grants.swift:263-419`): memory only,
   `[String: Grant]` plus SHA-256 token hashes, never the tokens
   themselves. `authorize` (`:343-381`) checks, in order: token present →
   shape → hash lookup → revoked → constant-time hash compare → expired →
   key match → host match → method → path → request cap → USD cap → the
   fail-closed unpriced rule (`:373-376`: on a `maxUsd` grant, one billable
   call that returned no price ends the grant at the next authorize with
   429 `grant_usd_unpriced`).
4. `GrantPath.matches` (`:108-118`): dot segments never match; empty
   `allowed` = any path; otherwise exact-or-subdirectory prefix, both sides
   made relative to the provider's `pathPrefix`.
5. The gateway's request path (`Gateway.swift:81-249`) never touches grant
   internals: loopback origin gates → key name → token extraction →
   `service.authorizeGateway` (`KeysService.swift:634-648`, a direct
   forward to `grants.authorize`) → breaker → upstream with the real secret
   injected. It knows nothing but the presented token.
6. Kill paths, all reaching `GrantStore.revoke*` which deletes the hash:
   expiry (per request), `keys revoke`/dashboard ("revoked"), gateway off
   (`gateway_off`, `KeysService.swift:531-532`), stop/quit
   (`gateway_stopped`, `:719-724`), screen lock
   (`com.apple.screenIsLocked` → `handleScreenLock` → `screen_lock`,
   `:617-632`, registered at gateway start), target change
   (`target_changed`, `lookupGateway` `:460-477`), key delete, and restart
   itself: grants are process memory, so after one the token gets 401
   `grant_invalid`.

```
              issuance time                        request time (unchanged)
 ┌──────────┐   ┌──────────────────┐   ┌─────────┐   ┌─────────────────────────┐
 │ Profile   │──▶│ issueGrant(      │──▶│ Grant   │   │ GatewayListener.handle  │
 │ (catalog  │   │  profile bounds, │   │ (memory │──▶│  token → GrantStore.    │
 │  row, no  │   │  validate BEFORE │   │  only,  │   │  authorize: key/host/  │
 │  secrets)│   │  presence, inter- │   │  hash)  │   │  method/path/expiry/    │
 └──────────┘   │  sect, 1 prompt)  │   └─────────┘   │  caps — never profiles  │
                └──────────────────┘                  └─────────────────────────┘
```

## What a profile is

A profile is a catalog row, strictly less sensitive than a `gateway_clients`
row: **no secret, no token, no hash — only bounds and names.** Stored in a
new `grant_profiles` table following the existing table pattern
(`CatalogDB.swift:174-196`).

```swift
struct Profile {
    let id: String            // 8 lowercase hex, Grant.newID() pattern
    let name: String          // unique, user-chosen
    let keys: [String]        // vault key names, non-empty, must exist at save time
    let methods: Set<String>  // subset of Grant.allMethods; the AND-ceiling
    let paths: [String]       // GrantPath-normalized scopes; empty = any path
    let minutes: Int          // 1...1440 — default AND ceiling for grants under it
    let maxRequests: Int?     // default AND ceiling (nil = uncapped)
    let maxUsd: Double?       // default AND ceiling (nil = uncapped)
    let unattended: Bool      // requires maxRequests or maxUsd (validated at save)
    let createdAt, updatedAt: Date
}
```

Hosts are deliberately **not** a profile field: a grant's host comes from the
key's provider (`row.gatewayHost ?? provider.host`), and grants already die
on target change. Key choice bounds the host transitively, exactly as today.

Every profile value is a **default-and-ceiling**: an issuance request may
tighten it, never exceed it, and there is **no silent clamping** — an
out-of-bounds request is refused with a distinct named error *before any
Touch ID prompt is consumed*. Refusing rather than clamping is honest in both
directions: the caller learns which bound it hit instead of silently getting
a different grant than it asked for, and the user is never shown a prompt for
a request that was quietly rewritten.

| what              | limit                       | who enforces                                  |
|-------------------|-----------------------------|-----------------------------------------------|
| profile name      | non-empty, unique           | save — `profile_name_invalid` / `profile_name_taken` |
| profile keys      | non-empty, every name a vault row at save | save — `profile_key_unknown`      |
| profile methods   | subset of `Grant.allMethods` | save — `profile_method_unknown`              |
| profile paths     | `GrantPath.normalize` rules (no `?`, `..`, space; leading `/`; no trailing slash) | save — `profile_path_invalid` |
| profile minutes   | 1…1440                      | save — `profile_minutes_range`; issuance — `profile_minutes_over` |
| request cap       | ≥ 1                         | save — `profile_request_cap_invalid`; issuance — `profile_request_cap_over` |
| USD cap           | > 0                         | save — `profile_usd_cap_invalid`; issuance — `profile_usd_cap_over` |
| unattended        | requires ≥ 1 hard cap        | save and re-checked at issuance — `profile_requires_cap` |
| issuance under a profile | request ⊆ profile on every bound, refused pre-prompt | issuance — `profile_not_found`, `profile_key_not_allowed`, `profile_method_not_allowed`, `profile_path_not_allowed`, `profile_minutes_over`, `profile_request_cap_over`, `profile_usd_cap_over` |

Bounded issuance slots into `issueGrant` between `request.validated()` and
the presence prompt — the slot validation already occupies. In order:

1. Load the profile by name (names are unique). Missing → `profile_not_found`.
2. The requested key must be in `profile.keys`, else `profile_key_not_allowed`.
3. Methods: unspecified in the request → use the profile's. Specified → every
   requested method must be in the profile's set, else
   `profile_method_not_allowed`. The effective set is the *requested* set
   (intersection is request ⊆ profile).
4. Paths: unspecified → use the profile's. Specified → every requested scope
   must be *within* an allowed scope, using `GrantPath.matches` semantics
   (exact-or-subdirectory; a profile allowing `/v1` covers a requested
   `/v1/messages`; the reverse is refused → `profile_path_not_allowed`). A
   profile with empty paths allows any requested path.
5. Minutes: unspecified → the profile's. Specified → must be ≤ the profile's,
   else `profile_minutes_over`.
6. Caps: for each of `maxRequests`/`maxUsd`: unspecified → the profile's;
   specified → must be ≤ the profile's *when the profile has one*
   (`profile_request_cap_over` / `profile_usd_cap_over`). A profile without a
   cap lets a request set its own — tightening only.
7. `unattended` comes from the profile, never from a per-grant flag. Issuance
   re-checks it fail-closed: a profile-flagged grant must end up with at
   least one hard cap, else `profile_requires_cap` (in case save-time
   validation was somehow bypassed).
8. Then the unchanged flow: owner gate, key row, provider gateway check, host
   resolution, **one** presence prompt, `grants.issue`, audit.

Errors are a typed enum in `Profiles.swift` with a code and a human message,
following the `GrantDenial`/`AppError` house shapes: the CLI prints the
message, the API answers `{"error": <code>, "message": …}`, with
`profile_not_found` surfacing as 404 and the rest as 400-usage, through the
existing paths. A refused request leaves `RecordingPresenceGate.reasons`
empty — that is the pinned proof the prompt was not consumed.

## The prompt

**Non-profile grants: byte-identical to today.** The pinned format stays
exactly `grant "<task>" the key <key> for <Provider> at <host>, <span>`;
the tests pinning it (`GrantTests.swift:184`) stay green without edits to
their expectations.

**Profile grants: the same skeleton plus the effective scope.** The reason
is:

```
grant "<task>" the key <key> for <Provider> at <host>, <span>, profile <name>: <Methods>, <Paths>, max <n> req, max $<amount>, unattended
```

- `<Methods>` is the effective method set, sorted, comma-joined (`GET,POST`).
- `<Paths>` is the effective path scopes comma-joined, or the words `any
  path` when the effective scope is empty.
- `max <n> req` appears exactly when the effective request cap is set, `max
  $<amount>` exactly when the effective USD cap is set (same wording as the
  audit detail).
- `unattended` appears, last, exactly when the profile is unattended.

Nothing is elided for profile grants — even "all methods" is spelled out —
because the prompt is the one line a local process cannot cross. A grant +
gateway-on still folds into the same single prompt.

The audit detail gains `profile <name>` (after the task) and `unattended`
(last) for profile grants; it still never contains the token.

## Unattended grants

"Unattended" changes exactly four things, nothing else:

1. A profile flagged `unattended` must carry at least one hard cap
   (`maxRequests` or `maxUsd`), validated at save and re-checked at issuance.
2. The prompt says `unattended`.
3. The grant records its profile name and `unattended: true` — additive
   `profile`/`unattended` fields on `Grant` and in `jsonObject()`, shown in
   `keys grants` and the dashboard as a badge.
4. Docs and UI badge it and keep pointing to client tokens for jobs that
   must outlive a screen lock.

Unchanged, and pinned by tests: every kill path (screen lock, revoke,
gateway off, restart, expiry, target change, key delete, agent exit);
memory-only grant storage; the token format; the `grant_usd_unpriced`
fail-closed rule; the 401/403 breaker; relay behavior; per-request
enforcement in `GrantStore.authorize`. **An unattended grant still dies on
screen lock.** No auto-renewal and no auto-reissue exist; a new grant is a
new prompt.

Why the hard cap is the conservative bound: an unwatched grant is
pre-committed at approval time to what it can do while nobody looks. Without
a cap, "unattended" would mean "spend against this key for up to 24 hours
bounded by nothing but the clock"; with one, the exposure is a number the
user read on the Touch ID prompt. A job that must survive the Mac locking
still needs a client token — that README sentence is cross-referenced
everywhere the badge appears, not amended.

## Threat model

Profiles add one new kind of stored data and one new prompt-free surface.
The attackers: a process already on the Mac (malware, or any app the user
runs — it can read user-owned files, so the 0600 `control.json` and the
catalog are within its reach), the agent process holding a token, an
attacker who controls the relay Worker or the Cloudflare account (the
`docs/relay.md` attacker), and the honest user making mistakes.

**A process already on the Mac.** **Cannot:**

- Mint a grant. Issuance requires the presence prompt (`LocalPresenceGate`
  → `LAContext` in the gateway-owning process); a profile mints nothing by
  itself, and the `control.json` token "only lets a local process *ask*; the
  grant itself still needs Touch ID in the app" (README, gateway docs).
- Read a key value: the Keychain is presence-gated, and the gateway injects
  the secret only after a presented token passes `GrantStore.authorize`.
- Widen an issued grant by editing its profile: the grant is self-contained;
  `authorize` never reads the profile table. Editing a profile after
  issuance changes nothing.
- Make a refused issuance consume a Touch ID prompt: every profile check runs
  before the prompt, and refusals are named.
- Keep any grant alive across a screen lock, a restart, gateway-off or a
  revoke — profile-issued or not.

**Can:**

- Create, edit or delete profile rows directly in the catalog. This is real
  and new, and the whole design leans on the answer: a profile only bounds
  issuance, so the worst a forged row can do is *ask* under bounds the user
  still has to approve.
- Ask for grants repeatedly; each accepted ask costs the user a Touch ID,
  and each refused one costs no prompt.
- Try the name trick: rename or widen a profile ("read-only-models") and
  hope the user approves the name. Defeated by the prompt naming the
  *effective* methods, paths, caps and lifetime, and the word `unattended`,
  not just the profile name.

**The agent process holding a grant token.** **Cannot:**

- Exceed the issued scope: key, host, methods, paths, expiry and caps are
  enforced per request by the unchanged `GrantStore.authorize`, which never
  reads profiles.
- Outlive screen lock, restart, revoke, gateway off, target change or key
  delete.
- Renew itself: no renewal path exists.

**Can:** use the grant within scope until it dies — including while the user
is away, which is the unattended case, bounded by the caps and expiry
approved at issuance. A `maxUsd` cap is checked after each call, so one call
or several in flight can overshoot it: pre-existing, stated in the README,
unchanged.

**A relay-side attacker** (controls the Worker, the Cloudflare account or
the edge — the `docs/relay.md` attacker). **Cannot:**

- Obtain a provider key: the Worker never sees one, and the gateway injects
  the secret only after the unchanged `GrantStore.authorize` passes.
- Exceed a token's scope: a relayed request with a grant token is checked
  by the same per-request authorization, which never reads profiles.
- Read a profile row: nothing in the relay protocol names them, and a
  profile row never leaves the Mac.
- Keep a replayed grant alive: an unattended grant replayed through the
  Worker dies at screen lock like any other.

**Can:**

- Read and alter prompts and responses in transit (the Worker terminates TLS
  on both legs — the pre-existing relay position), replay a captured
  request within its token's scope until that token dies, and deny service.
  Replay spending is bounded by the caps the profile forced at issuance —
  for this actor, profiles only narrow.

**The honest user.** **Cannot:**

- Create an unbounded unattended grant: `unattended` requires a hard cap,
  at save and again at issuance.
- Approve a hidden scope: the profile-grant prompt names the effective
  bounds and the word `unattended`.
- Silently widen a live grant by editing its profile: issuance-time only.

**Can:** approve too readily (Touch ID muscle memory) — the mitigations are
the honest prompt, the unattended badge in `keys grants` and the dashboard,
and the instant off-switches that already exist: `keys revoke`, gateway off,
locking the screen. The user can also be surprised that a grant keeps its
scope after its profile was deleted; that is by design (the grant is
self-contained), and the docs and dashboard answer it with `keys revoke`.

Per new surface:

- **The profiles table** holds bounds and key names only — no secret, no
  token, no hash. A leaked catalog discloses which keys exist and what
  scopes the user habitually grants, the same class of information the
  existing catalog rows, audit log and client rows already hold. It
  discloses no credential and opens no request path. `keys purge` removes
  it with everything else.
- **The widened-profile attack**: local code edits the "evals" profile to
  allow every method and any path, then asks for a grant under it. The user
  still has to put a finger on the sensor, and the prompt shows `profile
  evals: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS, any path` — a widened
  profile cannot hide behind its name at the moment of approval.
- **The unattended grant**: what makes it safe unwatched is what was true
  before the user walked away — one explicit prompt naming the caps and
  lifetime, then the same per-request enforcement and the same kill paths.
  It dies at screen lock; the client token remains the only credential that
  outlives one, and the docs keep saying so.

## What changes in the privacy contract

Nothing. The README "Privacy boundaries" section stays verbatim-identical;
new prose goes only into the gateway/grants feature sections and this
document. No new listener, no new network path (the gateway and dashboard
keep their loopback binds; the relay is untouched), no new secret anywhere
(a profile row is bounds and names), nothing new sent to product analytics,
and request bodies still never reach the usage catalog. Grants live only in
the app's memory, as before; the profile row is issuance policy, not a
grant.

## Conflict check

The gate. Each mission requirement mapped to the quoted contract, with a
verdict and the conservative reading that preserves it. A would-weaken
verdict with no conservative reading would stop the mission at this
document.

| # | mission requirement | quoted contract sentence (verbatim) | verdict | conservative reading |
|---|--------------------|--------------------------------------|---------|----------------------|
| 1 | Profiles are bounded policies consulted only at issuance, never authority | "No open gateway. A request through the gateway needs a grant token: one Touch ID per task, bound to one key, one host, a method and path scope and an expiry." | **keep** | Every request still needs a grant token. `GrantStore.authorize` and `GatewayListener.handle` are untouched and never read profiles; a profile can only refuse or narrow an issuance, never authorize a request. |
| 2 | Grants stay limited to one key, one host, method+path scope, expiry and caps | "…bound to one key, one host, a method and path scope and an expiry. Screen lock, revoke, gateway off or a restart kills it." and "**A grant** is for one task: short-lived, in memory only, one Touch ID whose prompt names the task, provider, host and lifetime." | **keep** | Bounded issuance intersects request ⊆ profile; the grant that lands is an ordinary `Grant` with one key, one host, methods, paths, expiry, caps. All kill paths unchanged and pinned by tests. |
| 3 | Unattended = explicit approval, never silent creation or widening | "That is deliberate: a grant is for a task you are around for, so an unattended job that has to outlive a screen lock needs a client token (`keys client issue`) instead." | **keep** | An unattended grant is issued while the user *is* around — one explicit prompt that says `unattended` — and **does not outlive a screen lock**. It dies with lock, restart, revoke, gateway off and expiry like any grant. The sentence stays literally true: to outlive a lock you still need a client token. No auto-renewal, no auto-reissue. Cross-referenced, not amended. |
| 4 | Touch ID preserved: one prompt per grant, honest prompt text | "…one Touch ID per task…" and "Copy, reveal, env and rotate ask for user presence every time." | **keep** | Exactly one presence prompt per issuance, folded with gateway-on as today. Refusals happen before the prompt, so no prompt is ever consumed by a refused request. The plain-grant prompt string is byte-identical; the profile prompt names strictly more (profile name, effective methods, paths, caps, `unattended`). Profile CRUD itself prompts nothing — new prompt-free surface, recorded below: rows hold no secret and no capability, the same reasoning as other catalog metadata; the issuance prompt is the gate. |
| 5 | Nothing new in the catalog but metadata; grants stay memory-only; offline tests | "The usage catalog stores only counters and metadata. Gateway request bodies never reach that catalog." and "Grants live only in the app's memory; the audit log keeps the id, task and scope, never the token." | **keep** | A profile row is bounds and names — metadata, no request bodies, no tokens, no secrets; a sentinel test proves no secret reaches the catalog's temp dir. Grants themselves remain memory-only. Tests stay offline and synthetic with the CI fixture env; no keychain, no Touch ID, no network. |
| 6 | The README contract section itself | "No secret on screen by default. The key list shows names, never values." (and the whole "Privacy boundaries" section) | **keep** | The section is edited never; new README prose goes in the feature sections only, additively. No secret appears on screen, in logs, in tests or in fixtures. |

**Conclusion: no conflict, proceed.** Every requirement maps to a keep; no
requirement forces a weakening, and no conservative reading above changes a
behavior the contract names. The stop condition did not trigger.

## Implementation plan

Files, one line each; the milestone 2 and 3 workers expand these into TDD
steps.

- **new `Sources/KeysCore/Profiles.swift`** — the `Profile` struct, the
  typed `ProfileError` enum (codes + human messages, the table above),
  save-time validation, and path containment (request-within-profile using
  `GrantPath.matches` semantics).
- **`Sources/KeysCore/CatalogDB.swift`** — `grant_profiles` table in
  `migrate()` (`CREATE TABLE IF NOT EXISTS`, following the `gateway_clients`
  pattern), CRUD: insert, update by name, list, delete by id, fetch by name.
  No cascade when a key is deleted (a profile naming a gone key simply
  fails closed at issuance; recorded below).
- **`Sources/KeysCore/KeysService.swift`** — profile CRUD surface with
  validation; bounded `issueGrant` (profile checks between `validated()` and
  the prompt, the eight-step order above); the extended `grantReason`;
  `grantDetail` gains `profile`/`unattended`; per-key audit rows for profile
  add/remove.
- **`Sources/KeysCore/Grants.swift`** — additive `Grant.profile: String?`
  and `Grant.unattended: Bool`, serialized as `profile`/`unattended` in
  `jsonObject()`. Nothing else in the file changes: `GrantStore`,
  `GrantToken`, `GrantPath`, `GrantDenial` and `authorize` untouched.
- **`Sources/KeysCore/CLI.swift`** — `keys profile add <name> --keys <a,b>
  [--methods GET,POST] [--paths /v1/messages] [--minutes N] [--max-requests
  N] [--max-usd X] [--unattended] [--json]`, `keys profile list [--json]`,
  `keys profile remove <name>`; `--profile <name>` on `keys grant` and the
  agent command; `keys grants` shows the profile name and an unattended
  marker.
- **`Sources/KeysCore/AgentSetup.swift`** — the agent path issues its grant
  within profile bounds when `--profile` is given; revoke-on-exit (normal
  exit, signal, failed launch) preserved; config-file writes still hold the
  base URL and an environment-variable name, never a secret.
- **`Sources/KeysCore/HTTPServer.swift`** — `GET /api/profiles`, `POST
  /api/profiles`, `DELETE /api/profiles/<id>`, all behind the existing
  same-origin + `x-ksf-token` gate for mutations (`HTTPServer.swift:128-130`);
  an optional `profile` field on `POST /api/keys/<name>/grants`; refusal
  codes surface as named JSON errors.
- **`Web/index.html` + `Web/app.js`** — a profile picker in the grant dialog
  (profiles whose keys include the opened key; picking one prefills
  minutes/methods/paths/caps — the server re-enforces), a compact profiles
  list with bounds, unattended badge and remove in the grants area, and the
  profile name + unattended badge on active grant rows. Unpriced spend keeps
  rendering as unpriced, never $0.
- **`README.md`** — a profiles/unattended section in the gateway/grants
  feature docs, additive; "Privacy boundaries" untouched.
- **`docs/missions/grant-profiles.md`** — the final report (milestone 3).

Explicitly **not** touched: `Sources/KeysCore/Gateway.swift` (zero changes —
the request path never learns profiles exist), `GrantStore.authorize`,
token formats, `GrantPath` rules, every kill path, `Relay/`, `Site/`,
`Analytics/`, product analytics (nothing new is sent), `CHANGELOG.md` (the
cycle's convention; recorded in the report), the installed app,
`docs/relay.md`, `docs/release.md`, `CLAUDE.md`/`AGENTS.md`.

## Testing it

All offline, synthetic, no keychain, no Touch ID, no network, with the CI
fixture env. TDD: a failing test first per behavior. Presence behavior is
pinned via `RecordingPresenceGate` reason assertions — the established seam.

- **new `Tests/KeysreallysafeTests/ProfileTests.swift`** — the save-time
  validation matrix (duplicate name, unknown/empty key, unknown method,
  `GrantPath`-rejected path, minutes out of 1…1440, `maxRequests < 1`,
  `maxUsd ≤ 0`), unattended-requires-a-cap, catalog CRUD, path containment,
  a sentinel assertion that no secret reaches the catalog's temp dir, and
  the CLI command shapes.
- **`GrantTests.swift` additions** — bounded issuance (defaults from the
  profile, tightening honored), the refusal matrix with an empty
  `gate.reasons` after every refused attempt, the pinned profile-grant
  prompt string (full string, following the `GrantTests.swift:184` pattern)
  beside the byte-identical plain grant, profile-alone-mints-nothing (gate
  throws → no grant, no token), and profile-acts-only-at-issuance (edit and
  delete the profile after issuance; the grant keeps working within its
  recorded scope).
- **new `Tests/KeysreallysafeTests/ProfileGrantGatewayTests.swift`** — the
  mission's gateway asks, through the real `GatewayRig` loopback gateway,
  all for *profile-issued* grants: method denial (`grant_method_not_allowed`),
  path denial (`grant_path_not_allowed` with `allowed_paths`/
  `suggested_paths`, dot segments never match), key and host binding
  (`grant_key_mismatch`, `grant_target_changed`), expiry (`grant_expired`),
  caps (`grant_request_limit`, `grant_usd_limit`, `grant_usd_unpriced`
  fail-closed), screen lock (reason `screen_lock`, then `grant_revoked`),
  and restart (`grant_invalid` on a fresh service). Non-profile grants
  regress nowhere: the full suite stays green with unmodified expectations.
- **`ServerTests.swift` additions** — `/api/profiles` CRUD and the
  missing-`X-KSF-Token` 403, grant-with-profile through `makeHandler()`
  producing the same bounded result as the CLI path, `GET /api/grants`
  carrying `profile`/`unattended`, and the audit detail including the
  profile and never the token.
- **`AgentSetupTests.swift` additions** — `keys agent --profile` issues
  within profile bounds and keeps revoke-on-exit (normal exit, signal,
  failed launch); `--client` still mints a client token as today.
- **`scripts/tests/test_keys_dashboard_ui.cjs`** — browser cases for the
  picker prefill, the unattended badge, the profiles list and remove. UI
  mechanics only: the Node fixture is a mimic, never cited as proof of
  server enforcement.
- **`BackendContractUITests.swift`** — stays green; a profile case in the
  ordered scenario is optional and recorded either way.
- The full CI list from `.github/workflows/test.yml` runs before the
  mission completes and is recorded in the report, including the five
  expected environment-gated skips.

## Rejected alternatives

- **Auto-renewal / auto-reissue of expiring grants.** Silent creation: every
  grant must be individually presence-approved, and a renewal would mint
  capability while the user is away with no prompt. An expired unattended
  grant is *supposed* to be dead; the job re-runs by asking again. Rejected.
- **Profiles as request-time authority.** Having `GrantStore.authorize`
  consult the profile table would add a second authority surface: a catalog
  edit could widen or narrow live grants, and the request path would gain a
  dependency on the database. Grants stay self-contained; authorization
  stays token-only. Rejected.
- **Persistent grants** (surviving restart or screen lock under a profile).
  Breaks "Screen lock, revoke, gateway off or a restart kills it" and
  "Grants live only in the app's memory" outright. The outlive-lock answer
  is the client token and stays so. Rejected.
- **Silent clamping.** Clamping an over-bound request down to the profile
  and prompting anyway would be a dishonest prompt — the user approves one
  scope while the caller asked for another — and would let a caller probe a
  profile's bounds by asking wider. Refusal is honest in both directions.
  Rejected.
- **Multi-key grants.** A profile names several keys, but each issuance
  still picks exactly one: "bound to one key" is the load-bearing binding of
  the whole grant model, and the host binding rides on it. Rejected.
- **A per-grant ad-hoc `--unattended` flag.** Unattended without a saved
  policy means unbounded unattended use — the cap requirement is a property
  of the saved profile, validated at save and re-checked at issuance, not a
  one-off promise on a command line. Rejected.

## Conservative choices recorded

Choices made autonomously in this mission so far, with the reasoning, to be
collected into `docs/missions/grant-profiles.md`:

1. **Unattended requires a hard cap** (`maxRequests` or `maxUsd`): an
   unwatched grant must be pre-committed to a number the user read at
   approval.
2. **Unattended grants do not outlive a screen lock**; the client-token path
   remains the only outlive-lock answer, cross-referenced everywhere the
   badge appears. The README sentence is never amended.
3. **No auto-renewal, no auto-reissue.** A new grant is a new prompt.
4. **Profile CRUD prompts nothing.** A profile row holds no secret and no
   capability; like other catalog metadata it changes without presence, and
   the issuance prompt remains the only gate that mints anything. Recorded
   because it is new prompt-free surface.
5. **Hosts are not a profile field**; the host follows the key's provider
   and the `grant_target_changed` kill path keeps its exact meaning.
6. **Paths are stored as a JSON array** in the row: `GrantPath.normalize`
   allows characters a CSV would corrupt (commas), and grant behavior must
   not change to make storage easier.
7. **No cascade delete of profiles when a key is deleted.** Profiles
   reference names; issuance under one fails closed at the missing key.
   Removing a stale profile is the user's deliberate act.
8. **`unattended` never appears as a per-grant CLI flag**; it comes only
   from a profile.
9. **Nothing new goes to product analytics** — no profile counters, no new
   vocabulary.
10. **No `CHANGELOG.md` entry this cycle**, following the repo's convention
    for post-release feature commits; recorded in the mission report
    instead.
11. **Grant + gateway-on still folds into one prompt**, unchanged.
