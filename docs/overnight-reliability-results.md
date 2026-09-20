# Overnight dashboard reliability — results, 20 September 2026

Phase 2 of the authorized overnight run. Browser coverage for the Keys pane of
the dashboard, against the real `Web/index.html`, `Web/styles.css` and
`Web/app.js` loaded into Chromium, with every API answer coming from a synthetic
in-memory fixture. No running Keys app, no vault, no installed application and no
network destination was touched. Every secret in the suite is the invented
literal `sk-fixture-NEVER-REAL-0000000000`.

## Coverage before this phase

Three browser suites existed, all for other panes:

| Suite | Pane |
|---|---|
| `test_optimizer_workflow_ui.cjs` | Optimizer: form payloads, policy denials, candidates, session races |
| `test_optimizer_layout_ui.cjs` | Optimizer overview geometry at four widths |
| `test_analytics_ui.cjs` | Analytics opt-in |

Searching the suite directory for `reveal`, `copy` or `clipboard` returned
nothing. The Keys pane — the list, reveal, copy, add, edit, rotate, delete and
the chart filters — had **no browser coverage at all**, even though `app.js` is
2,169 lines and holds every Touch ID-backed action in the product.

## What was added

`scripts/tests/test_keys_dashboard_ui.cjs`: 29 cases plus screenshot capture,
following the existing convention (one `http.createServer` serving the real
assets, `playwright` resolved from `NODE_PATH`, `node:assert/strict`, a non-zero
exit on failure). The fixture keeps a mutable key list and two control maps, so a
case can make one endpoint fail, drop the connection, or answer late while the
rest keep working. Every case also asserts no page error was raised and that the
fixture saw no unexpected operation.

| Area | Cases |
|---|---|
| List | populated list with count; empty state hides the table |
| Reveal | secret shown, countdown ticks, auto-hide at expiry, secret cleared; early hide stops the timer; cancelled Touch ID; two keys in sequence never cross secrets |
| Copy | wipe deadline reported, row marked used, deferred refresh; failure restores the button; the copied row deleted before the deferred refresh |
| Add | local validation sends nothing; success carries the launch token and selects the row; duplicate keeps the dialog open; typed secret cleared on close |
| Edit | unchanged edit sends no request; refusal reported in the dialog and retryable; retry succeeds |
| Rotate | failure reported in its own dialog; success clears the secret field; cancel clears it too |
| Delete | confirmation first; refusal keeps the row and the dialog; success removes the row |
| Filtering | range and source chips drive query and URL; group chips are Claude-only and reset on leaving; key chip appears, filters and clears |
| Failures | unreachable engine (sticky) and its recovery; stale launch token; 503 on the chart and its recovery; a non-JSON error body |
| Races | a slow key list overtaken by a newer one; overlapping reveal timers |
| Overlapping loaders | a late key list over a still-failing chart; a chart recovery under a still-failing key list; one recovery uncovering the other's failure; an engine outage clearing over a surviving 503; a user message outliving a recovery |

Timing is driven by `page.clock`, so the 15 s reveal countdown, the 2.5 s deferred
refresh after a copy, the 4 s status timeout and the 15 s status poll are all
exercised deterministically rather than by sleeping.

## Defects found and fixed

All four were reproduced first as a failing case, then fixed in `Web/app.js`,
then re-run green. The file now stands at 48 insertions and 5 deletions against
`eb2bac2`; the fourth defect below was found by independent review after the
first three were fixed, and its correction rewrote the shared error module the
first fix introduced.

### 1. A stale key list could resurrect a deleted key and drop a new one

`loadKeys` had no sequence guard, unlike `loadSpend`, which has had `spendSeq`
all along. Refreshes overlap constantly: a copy defers one by 2.5 s, closing the
reveal dialog starts another, and every CRUD call ends with one. A reply computed
before a change and delivered after it therefore overwrote the newer render.

Reproduction, before the fix:

```
FAIL  a slow key list cannot overwrite a newer one
      a stale list must not restore a deleted key or drop a new one
      + actual - expected
        [ 'alpha', 'bravo', + 'charlie' - 'foxtrot' ]
```

`charlie` had been deleted and `foxtrot` added; the late reply put `charlie` back
and removed `foxtrot`. Fixed with the same `keysSeq` guard `loadSpend` uses.
User impact: a deleted key reappears in the list and a just-added key vanishes
until the next refresh — a correctness problem in the surface people use to
decide what is in the vault.

### 2. An outage banner outlived the outage

`setEngineDown(true)` posts a sticky notice, and a caller that catches the thrown
error posts a second one, `"Can't reach the local site…"`. Recovery only cleared
the first: `setEngineDown(false)` tested `startsWith("Engine is not")`. When the
engine came back through the background 15 s status poll, with no user action to
overwrite the line, the "can't reach" banner stayed on screen indefinitely.

Reproduction, before the fix: `the unreachable-engine banner clears when the
engine answers again` timed out waiting for the status line to empty.

### 3. A failed chart load stayed on screen after the chart loaded

The same shape, one layer up. `loadSpend` reported its error stickily and never
took it down, so `engine_busy` sat over a chart that had since loaded correctly.

Both were fixed together rather than patched twice: `sayError` records the exact
text it posts and `clearError` removes it only if that same text is still
displayed, so a newer message is never clobbered. `loadKeys`, `loadSpend` and
`setEngineDown` now use the pair. That fix was correct for a newer *transient*
message and wrong for a concurrent one — see defect 4.

### 4. One loader's success cleared the other loader's current failure

Found by the independent product review of this phase (`outputs/product-review.md`,
P2), reproduced here as a browser case, and corrected in this session.

`stickyError` was a single shared string, so the last failure to post owned the
line no matter who posted it, and the next success from *any* of the three
callers took it down. The text comparison in `clearError` did not help: the
message being compared was the other loader's, and it was still accurate.

This is reachable on an ordinary startup. `loadKeys({quiet: true})` is fired at
page load (`app.js:2188`) and the user opens the Chart pane while it is still in
flight. The spend request fails — HTTP 503 `engine_busy` — and puts
`engine_busy` on the line. The key list then arrives successfully, calls
`clearError`, and empties the line. The chart is blank, the engine is still
refusing it, and nothing says so. Pre-fix reproduction:

```
FAIL  a key list arriving late does not clear a chart that is still failing
      a key list must not report the chart recovered
      '' !== 'engine_busy'

FAIL  a chart recovering does not clear a key list that is still failing
      a chart recovery must not report the vault readable
      + '' - 'vault is locked'

FAIL  recovering one loader uncovers the other's unresolved failure
FAIL  the engine coming back leaves a chart failure that outlived the outage
      page.waitForFunction: Timeout 5000ms exceeded.
```

The fix files each sticky failure under its owner — `spend`, `keys` or `engine`
— in a `Map` keyed by owner and holding the exact text that owner posted. A
recovery clears only its own entry, and only takes the line down if its own text
is what is displayed; anything else, whether the other loader's live failure or a
"Copied bravo" the user is reading, is left alone. When a recovery does take the
visible message down and another owner is still failing, that failure goes back
on the line rather than leaving a broken pane looking healthy.

Reachability is the one cross-owner case. `api()` throws the same "Can't reach
the local site…" out of the same dead `fetch` that raises the engine banner, so
when the engine answers again `setEngineDown(false)` retires every outage
message regardless of who filed it — which is what defect 2 above required — but
it leaves an unrelated 503 alone. Both halves are pinned by cases.

User impact: the status line is the only place a failed background load is
reported. Clearing it on an unrelated success tells the user a pane recovered
when it did not; the reverse ordering hides a genuine vault failure behind a
chart refresh.

## Two suspected defects that were not defects

Reported here because the evidence, not a guess, settled them.

- **Blank mobile key list.** The first `keys-list-mobile.png` showed the header
  reading "3 keys" over an empty pane. Measuring the rendered boxes at 390 px
  showed the card layout intact (row 390×235, visible). The screenshot had caught
  the pane's 160 ms `fade` opacity animation mid-flight. Fixed in the harness with
  `animations: "disabled"`, plus an assertion that a key-list screenshot is never
  suspiciously small, so the evidence cannot silently go blank again.
- **Rotate leaving a secret in the DOM.** `dlg-add` clears its secret on close and
  it was worth checking whether `dlg-rotate` did the same. It does
  (`app.js:1504`). A case now pins both.

## Exact checks run

From `/Users/Shost2/keys-overnight-20260920`, every command prefixed `rtk`, with
`NODE_PATH=/Users/Shost2/keys-jev-savings/Plugins/jev-optimizer/node_modules` so
the source checkout's Playwright 1.62.1 and its pinned Chromium 151.0.7922.34 are
reused read-only.

```sh
node scripts/tests/test_keys_dashboard_ui.cjs
# Keys dashboard UI passed: 29 cases, screenshots in …/outputs/keys-dashboard-screenshots
# and, with the ownership fix reverted in place to prove the new cases bite:
# Keys dashboard UI: 4 of 29 failed: a key list arriving late…, a chart recovering…,
# recovering one loader…, the engine coming back…

node scripts/tests/test_optimizer_workflow_ui.cjs
# Optimizer workflow UI passed: real form payloads, policy denials, candidate
# metadata, hidden state, session cleanup races, and the offline session countdown.

node scripts/tests/test_optimizer_layout_ui.cjs
# Optimizer layout UI passed at 1280px, 820px, 390px, 320px

node scripts/tests/test_analytics_ui.cjs
# exit 0

node --check Web/app.js && node --check Web/optimizer.js && node --check Web/analytics.js
# all scripts parse

python3 -m unittest discover -s scripts/tests -p 'test_*.py'
# Ran 119 tests ... OK
```

No Swift source was changed, so no Swift test was run.

The defect-4 correction session re-ran the browser suites only, since it touched
nothing else: `test_keys_dashboard_ui.cjs` (29 passed, twice — once with the fix
reverted in place), `test_optimizer_workflow_ui.cjs` (passed),
`test_optimizer_layout_ui.cjs` (passed at all four widths),
`test_analytics_ui.cjs` (exit 0, silent on success), and `node --check` on
`Web/app.js` and the edited suite. The Python suite was not re-run: no Python
file was touched. `scripts/claude-usage-collect.py` was deliberately left alone —
its three accounting defects are the separate correction recorded in
`outputs/accounting-correction-handoff.md`.

The six `test_optimizer_benchmark.py` failures recorded in
`docs/overnight-usage-results.md` are **resolved**: they needed
`Plugins/jev-optimizer/dist`, which was absent at 00:37 and present at 00:43.
This session ran no build and no install; the directory is gitignored and carries
no repository change. The suite now passes 119 of 119.

## CI

`.github/workflows/test.yml` gains one line: `test_keys_dashboard_ui.cjs` runs
first in the existing browser step, which already installs the pinned Chromium
and sets `NODE_PATH`. No new action, dependency or job. The suite honours
`KEYS_UI_SCREENSHOT_DIR` exactly as the layout suite does and defaults to
`.build/keys-ui-screenshots`, which `.gitignore` already covers.

## Screenshots

Six, in `outputs/keys-dashboard-screenshots/` of the run directory, at 1440×900
and 390×844: populated list, reveal dialog, and empty state at each width. The
mobile shots confirm the card layout that replaces the table below 520 px.

## Residual limitations

- **Fixture, not the engine.** Every response is synthetic. The suite proves how
  the page behaves given a response shape; it does not prove the Swift HTTP
  server produces those shapes. The UI ↔ backend contract gap noted in the
  19 September review (P1-1) is still not closed by a browser test.
- **Touch ID is never exercised.** `/copy`, `/reveal` and `/rotate` are answered
  by the fixture. Cancellation and failure are covered as *responses*; the native
  prompt is not reachable from a test and was not invoked.
- **Uncovered Keys-pane surface.** Grants and long-lived clients, the gateway
  toggle and its host dialog, provider check, key history, CSV export, "copy
  totals" and ingest have no case here. The grant and client flows are the
  largest remaining gap and issue real credentials, so they deserve the same
  treatment next.
- **Keyboard and accessibility behaviour is only touched incidentally.** Roving
  tabindex, arrow-key navigation between rows and focus restoration after a
  dialog closes are implemented in `app.js` and asserted only where a case
  happened to need them.
- **One browser.** Chromium only, at two widths for screenshots. No WebKit run,
  which is what the product is actually used in on this Mac.
- **The status line still shows one message at a time.** Ownership decides who
  may clear it, not how two simultaneous failures are displayed: the newest
  failure covers the older one, and the older reappears only when the newer
  recovers. Showing both would need a real notice area, which is a design change
  and out of scope for a correction.
- **Ownership is by loader, not by request.** All key-list failures share one
  owner, so a `loadKeys` whose response is stale is not distinguished from a
  current one for status purposes. The `keysSeq` guard already drops stale
  responses before they reach the status line, so this is not reachable today.
- **The deferred-refresh timer after a copy is still uncancelled.** Stacking
  timers were not shown to cause an observable fault once the sequence guard was
  in place — a copy whose row disappears first now passes with no page error — so
  nothing was changed. It remains a latent tidiness issue rather than a defect.
