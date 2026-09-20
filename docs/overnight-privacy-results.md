# Overnight privacy and regression audit — 20 September 2026

Phase 3 of the authorized overnight run. A bounded read-only source audit against
the commitments published in `README.md` ("Privacy boundaries", the grant and
client sections) and `docs/optimizer-library.md`, followed by synthetic
regression tests for the one confirmed gap.

No vault was opened, no secret value was read or printed, no provider was
contacted, no native authorization was requested, and the installed application
was not changed. The 19 September Fable 5.1 review and `docs/review-fixes-results.md`
were read first so that already-known findings are not re-reported as new.

## Summary

| # | Area | Verdict | Severity | State |
|---|---|---|---|---|
| 1 | Ledger deduplication across tasks | **Defect confirmed** | Medium | **Fixed**, with two regression tests |
| 2 | Grant scope and exact paths | Holds | — | Verified, no change |
| 3 | Revocation | Holds | — | Verified, no change |
| 4 | Request-body privacy | Holds | — | Verified, no change |
| 5 | Optimizer authorization | Holds | — | Verified, no change |
| 6 | Logging | Holds | — | Verified, no change |
| 7 | Duplicate `WWW-Authenticate` on gateway 401 | Cosmetic defect | Low | **Not fixed**, reported |

One defect was found and fixed. Nothing else in the audited surface contradicted
a published commitment. Areas the prior review already covered in depth are
recorded as re-verified rather than re-found.

---

## 1. Ledger deduplication ignored task identity — fixed

**Commitment.** `docs/optimizer-library.md:210`: *"Repeated request IDs are
deduplicated only within compatible task/model identities."*

**What the code did.** `OptimizerStore.eventRecord` has two deduplication layers.
The second, request-identity, matches the commitment exactly: project, task,
request id, kind and model (`OptimizerStore.swift:638-642`). The first, the
`event_id` idempotency key, matched on **project and event id only**:

```swift
if let exact = ledger.events.first(where: { $0.projectID == projectID && $0.eventID == eventID }) {
    return ["event": eventObject(exact), "deduplicated": true, "deduplication": "event_id"]
}
```

So the same `event_id` submitted under a *different task in the same project* was
silently folded into the first task's event. The second task's usage was never
written, and the caller received `deduplicated: true` together with an event
object whose `task_id` was not the one it had sent.

**Impact.** This is the accounting path the whole savings claim rests on. A paired
evaluation runs its baseline and treatment arms as two tasks in one project
(`docs/optimizer-paired-evaluation.md`). A client that derives `event_id`
deterministically — from a turn index, a replayed provider message id, or a hash
of the task — collides across arms. The treatment arm's tokens then vanish and
the baseline arm's numbers stand in for both, which manufactures a saving out of
a bookkeeping accident. It is silent: no error, no counter, and the only visible
signal is a `task_id` mismatch in a field callers have no reason to re-check.
Severity **medium** — no credential exposure, but silent corruption of the
measurement the product is built to make honest.

**Evidence it was real.** The test below was written first and failed against the
unfixed code:

```
testEventIdReusedUnderADifferentTaskIsRefusedNotSilentlyFolded
OptimizerStoreTests.swift:211: error: XCTAssertThrowsError failed: did not throw an error
```

**Fix** (`Sources/KeysCore/OptimizerStore.swift`, 6 lines): idempotency is scoped
to the task. A reused id under a different task is refused with the existing
`OptimizerStoreError.conflict`, which `HTTPServer.swift:497` already maps to
409 `optimizer_changed` and the MCP client already reports as a refusal.

Refusing was chosen over recording a second event. Recording would double count
whenever a client retried with a wrong `task_id`; refusing writes nothing, keeps
the first arm untouched, and tells the caller. It is the fail-closed option and
matches the neighbouring conflict at `OptimizerStore.swift:507`.

**Regression coverage** (`Tests/KeysreallysafeTests/OptimizerStoreTests.swift`):

- `testEventIdReusedUnderADifferentTaskIsRefusedNotSilentlyFolded` — cross-task
  reuse throws `.conflict`, the first arm's event is unchanged, nothing is written
  for the second, and a distinct id under the second task still records normally.
- `testEventIdRepeatedUnderTheSameTaskStaysIdempotent` — an ordinary retry is
  still deduplicated with `deduplication: "event_id"` and writes one row. This
  pins the behaviour the fix must not break.

The pre-existing `testRequestIdentityDedupAndParentProjectIsolation` and
`testMixedUsageAggregateSeparatesOptimizerClientAndCache` continue to pass, so the
request-identity layer is unchanged.

---

## 2. Grant scope and exact paths — holds

**Commitment.** README:216-221 — a grant is bound to one key and the host recorded
at issue; anything outside the scope fails closed with a named reason; reviewed
Jev grants use an exact path.

Verified by reading `Grants.swift:311-354`:

- Denials are ordered and every branch fails closed: revoked → hash mismatch →
  expired → key mismatch → host mismatch → method → path → request cap → USD cap.
  The token hash is compared in constant time (`constantTimeEqual`, line 327).
- Jev grants (`:336-341`) require the literal client route to equal the adapter's
  exact path, with the provider and the single-element path list both re-checked
  at use. Prefix-relative matching is deliberately bypassed so `/v1/systemone`
  cannot lose its `/v1`. `TypeSafeUsageTests/testReviewedGrantsUseExactPathsAndOrdinaryGrantsKeepPrefixes`
  covers this and passes.
- Ordinary grants match through `GrantPath.matches` (`:116-130`), which strips the
  provider prefix only when the request actually carries it, then requires an
  exact segment-boundary prefix match. `GrantPath.normalize` rejects `?`, `..` and
  spaces at issue time.
- Upstream path bytes are never decoded before matching (`Gateway.swift:331-353`):
  the same bytes are scope-checked and forwarded, so a percent-encoded traversal
  cannot mean one thing to the check and another to the upstream.

I traced the interaction between `GrantPath.matches` and `GatewayPath.join`,
including the "client-named API version wins" rule added in `9f92e66`, looking for
a case where the scope check strips a prefix that `join` then restores differently.
Every divergence I constructed fails closed at the scope check.

**Checked and cleared, not a finding.** A path list that normalizes away entirely
(`--paths ","`) yields an unrestricted grant. Both surfaces disclose the effective
scope rather than implying a restriction: the CLI prints `paths any`
(`CLI.swift:435`) and the dashboard shows `any path` in the issued-grant panel and
the active list (`Web/app.js:1604,1714`). Disclosed, so not a silent widening.

## 3. Revocation — holds

**Commitment.** README:220-227 — screen lock, `keys revoke`, gateway off, a
restart, and editing the provider or host all revoke; grants live only in memory.

Verified: `revokeGrants` is reached from screen lock (`KeysService.swift:353`),
gateway stop (`:476`), gateway off (`:245`), key deletion (`:765`), purge (`:815`),
the dashboard (`HTTPServer.swift:695`) and `target_changed`
(`:172,180,218,302,697` via `disableGatewayMemory`).

`disableGatewayMemory` returns early when the key has no in-memory gateway entry
(`:933`), which at first looks like a revocation that can be skipped. It cannot
leave a usable grant: `lookupGateway` (`:166-184`) is the only way a request
reaches a key, and it fails when the cache entry is absent, or when the catalog
row's provider, host or secret **version** differs from the cached target — in
which case it revokes on the spot. A grant without a cache entry is inert.

No grant token is persisted anywhere. `Grant` carries an id and no token
(`Grants.swift:9-31`), `jsonObject()` exposes none (`:43-58`), hashes live in a
separate in-memory map, and the audit detail records id, task, expiry, host,
methods, paths and caps only (`KeysService.swift:322-329`) — exactly the
"id, task and scope, never the token" commitment.

## 4. Request-body privacy — holds

**Commitment.** README:23-25 — the usage catalog stores only counters and
metadata; gateway request bodies never reach it.

The only field taken from a gateway **request** body is `model`
(`GatewayUsage.swift:91-96`); everything else is parsed from the response's usage
object or from headers. The upstream request id is capped at 128 characters
(`Gateway.swift:544-554`). The optimizer engine's stderr goes to
`FileHandle.nullDevice` (`OptimizerAPI.swift:594`), so a crash cannot echo the
payload into a log. On the plugin side, `parseJevResponse` throws
`Gateway request failed (status)` and never includes the upstream error body,
with the reason stated in the code (`request.ts:115-118`).

**Residual, reported not fixed.** `model` is copied from the request body with no
length or character bound before it reaches the catalog and the dashboard. A local
client holding a grant could put arbitrary text there. The data is the caller's
own, the surface is local, and nothing crosses a trust boundary, so I did not
change it — bounding it touches the ingest path shared with Claude, Codex and Grok
imports, which is more than this audit should move on a hunch. Worth a deliberate
cap later.

## 5. Optimizer authorization — holds

Re-verified, already covered by the 19 September review, reported here only as a
regression check. The provider/host/adapter compatibility is checked before
presence (`KeysService.swift:270`), immediately after presence (`:292`), at the
point of use (`:300-301`, `:381-382`), and again inside `OptimizerAPI`
(`:103`, `:135`). A configuration change between approval and use throws
`Jev provider configuration changed during approval` and disables the gateway
memory. No new finding.

## 6. Logging — holds

Every `stderr` write in `KeysCore` was read (`Spend.swift:252`,
`Gateway.swift:283`, `Menubar.swift:210`, `KeysService.swift:868,964`,
`Providers.swift:86`, `CLI.swift`). All carry a key name, an action or an error
description; none carries a secret, a grant token, a request body or a response
body. `keys env` prints which key goes to which command and where, never the
value (`KeysService.swift:960-966`).

## 7. Duplicate `WWW-Authenticate` on gateway 401 — reported, not fixed

`Gateway.writeJSON` appends a `WWW-Authenticate` header twice for a 401, with two
different realms:

```swift
if status == 401 { head += "WWW-Authenticate: Bearer realm=\"keysreallysafe-gateway\"\r\n" }
head += "Content-Type: application/json; charset=utf-8\r\n"
if status == 401 { head += "WWW-Authenticate: Bearer realm=\"keysreallysafe grant\"\r\n" }
```

(`Gateway.swift:387,389`.) Two conflicting challenges for one scheme; some clients
take the first, some the last. Severity **low**: no privacy or authorization
consequence, the denial still fails closed, and the JSON body carries the real
reason. Left alone because choosing which realm is correct is a product decision,
not an audit call, and no test pins either string today.

---

## Exact tests run

From `/Users/Shost2/keys-overnight-20260920`, each prefixed `rtk`.

```sh
CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home swift test
# Executed 282 tests, with 2 tests skipped and 0 failures
# (280 before this phase, plus the two new deduplication tests; the two skips are
#  the pre-existing testLiveKeychainUserPresenceGated and
#  testAppleSignedBuildPassesFreshAndUpgradeValidation, skipped by design)

CLAUDE_CONFIG_DIR=… swift test --filter 'OptimizerStoreTests'
# Executed 15 tests, 0 failures

python3 -m unittest discover -s scripts/tests -p 'test_*.py'      # 119 tests, OK
python3 -m unittest Analytics/test_collector.py Analytics/test_deployment.py   # 18 tests, OK
python3 scripts/optimizer-preflight.py --root . --strict
# blockers: [], live_auth_invoked: false, secrets_examined: false

NODE_PATH=…/keys-jev-savings/Plugins/jev-optimizer/node_modules \
  node scripts/tests/test_keys_dashboard_ui.cjs                   # 24 cases, passed

git diff --check                                                   # clean
```

## Limitations of this audit

- **Static, offline and bounded.** Findings come from reading the source and from
  synthetic tests. No live gateway request, provider call, Touch ID prompt or
  running instance was exercised.
- **Not exhaustive.** I audited the six areas named for this phase. `CatalogDB`
  (55 KB), `Spend`, `LiveStatus`, the ingest parsers, `ProductAnalytics` and the
  installer were not read in this pass; the 19 September review covered analytics
  and the packager and found them consistent.
- **The `model` bound in §4 is reported, not fixed**, and the duplicate 401
  challenge in §7 is reported, not fixed. Both are deliberate: neither is a
  privacy breach, and both touch code paths wider than the evidence justifies.
- **No conclusion about the Keychain or signing.** Out of scope by instruction and
  untouched.
- The `event_id` fix changes a response for one input shape that previously
  succeeded: a client deliberately reusing an id across tasks now gets a 409
  instead of a silent dedup. That is the point of the fix, but it is a behaviour
  change a client could notice. See the handoff.
