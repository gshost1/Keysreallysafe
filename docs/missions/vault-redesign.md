# Vault redesign — mission report

2026-10-27, branch `droid/vault-redesign`, worktree `.claude/worktrees/droid-vault`.
Scope: the dashboard's API-key vault screen and app shell (`Web/index.html`, `Web/app.js`,
`Web/styles.css`) plus the tests that pin them. No Swift, server API, CSP, providers.json or
Add Key dialog changes.

## What was built

- **App shell (61ff71f, 971eccf).** The top toolbar with its text brand and segmented tabs is
  gone. Every pane now sits beside a left rail: the original app icon (`Web/icon.png`, 48 px,
  40 px at ≤540 px, no tile, same image in both themes), icon+label tabs Usage, Chart, Keys in
  the old order with the old ids and ⌘1–⌘4, and Help (accessible name "Keyboard shortcuts") and
  Settings at the foot with a divider. The status line keeps `role=status`/`aria-live` in its own
  strip above the content, and the rail narrows 78 → 65 (≤780 px) → 53 px (≤540 px).
- **Vault list (2cc790a).** The Keys table is replaced by the design's flat list: eyebrow KEYSRS,
  "Your keys.", quiet Providers and primary "Add key" (`N`), the 42 px search box (`/`), "All
  keys" + count with sort, and rows built from a provider-initials tile (deterministic initials
  and tint from the existing theme colours, ≥4.5:1 contrast in both themes), the mono name, the
  provider, last used ("Never used" when null), a Copy button and, since the menu milestone, a
  ··· button. Real state only: "Gateway on" + URL when on, this month's gateway figure with the
  existing requests/≈USD/"unpriced" wording when calls exist (clickable into the Chart's API keys
  scope), host/last-check/notes as secondary lines. The grants box moved below the list, the
  empty/no-match/error states and the first-use guide are preserved, and a footer states the
  Keychain storage and the 20 s clipboard wipe. The Created/Kind columns, the stacked narrow
  table and the vault's own unit switch are dropped (the unit still follows Usage/Chart).
- **Search, provider filter, sort (bec54bf, 9161dcf, 239be4e).** A provider filter ("All
  providers" + the providers the vault actually uses, by display name) combines AND-wise with
  search (name, provider id and name, group, host, gateway host); the count reads honestly
  ("N of M keys" only when rows are hidden); the no-match message names the provider when the
  filter contributes; the filter is session-only and resets to All when its provider's last key
  disappears. Sort keeps the five real options with `ksf.keysort` persistence and name tiebreaks.
- **··· menu (e01048d, audited and test-extended in fe92bae).** One `#key-menu` (`role=menu`),
  right-aligned under the invoking button (226 px, mockup styling in both themes), items in the
  designed order (Reveal V, Edit E, Access & grants A, gateway toggle G with a state-aware label,
  Activity H, Check connection T, Rotate R, Delete in red), every item dispatching through the
  existing `ROW_ACT` handlers so requests, dialogs, Touch ID prompts and status texts are
  byte-identical. Disabled rules unchanged (grant+gateway for `gateway:false` providers, check
  for non-checkable keys) with `aria-disabled` no-ops. Full keyboard support, Escape/Tab/outside
  click dismissal with focus back to the ··· button, one menu at a time, safe close on background
  re-render, flip/clamp inside the viewport at 390 px.
- **Narrow-width fixes (2f7350c).** The Chart's Source chips take a full wrapping row at ≤540 px
  (the Cloud chip was clipped at 390 px), and the vault toolbar wraps onto two rows at ≤540 px so
  the provider filter and sort stay fully readable instead of being clipped mid-word.
- **Closeout (this commit).** Four new Playwright tests: both-theme geometry at 390/540/1280/
  1440/1920 px with a long name and host (no spill, Copy and ··· inside the viewport, menu inside
  the viewport at 390 and 1920 px, per-theme computed palette, rail/logo sizes); no secret in the
  DOM and no off-origin request across list/search/filter/sort/copy/menu; theme switch keeps the
  vault's filter, search and menu working and a reload keeps theme + sort (VAL-CROSS-004); and a
  static check that `Web/index.html` ships no inline `style=` attributes, `<style>` blocks or
  external resources. README's dashboard section now describes the rail and the flat list instead
  of the segmented control and the dense table. No Web/ changes were needed: the audit found no
  layout bugs.

## Decisions taken without the user (conservative)

From the mission plan (binding):

1. The sidebar replaces the top tab bar for every pane; tab order, ⌘1–4, the default pane, the
   `#nav-*` ids and tab accessibility semantics are kept; Help and Settings sit at the rail's
   foot; `#status` stays visible and live.
2. The logo is the existing `Web/icon.png` app icon (48 px, 40 px ≤540 px, no tile); no new file
   was needed, so `WEB_FILES` was untouched.
3. Provider tiles show generated initials with deterministic tints from the existing theme
   colours, not brand marks.
4. The list is flat; a session-only provider filter offers the providers the vault actually uses
   and combines with search; sort keeps the existing options and the remembered choice.
5. Rows show name, provider and last used plus real state only: "Gateway on" and this month's
   gateway figure with the existing wording, only when they exist.
6. The Created column, the stacked narrow table, the Kind column and the vault's unit switch are
   dropped; the unit shared with Usage still applies to the Keys figures.
7. The ··· menu holds every existing per-key action in the designed order on the existing
   handlers; Copy stays a row button (`C`/Enter).
8. Existing elements are kept and restyled: grants box, providers manager, first-use guide, empty
   and no-match states, the help dialog's shortcut list. No mock control ships.

Made during the work (from the per-feature handoffs):

- Row selection uses `aria-current="true"`, not `aria-selected` (invalid on a listitem; a listbox
  would have nested interactive Copy inside options). *(vault-list-rows)*
- At ≤780 px "last used" moves under the provider line instead of being hidden, and the sort and
  filter stay reachable (compact) at every width — the mockup hides them, but no functionality
  was removed. At ≤540 px the quiet selects truncate their visible label with ellipsis; the
  dropdown still shows the full text. *(vault-list-rows, vault-search-filter-sort)*
- The vault content is capped at 1010 px and centred inside the pane card, like the design's
  window, so Copy is not stranded on wide screens. *(vault-list-rows)*
- The count chip uses `--ink-2` instead of the mockup's `--ink-3` for contrast on `--bg-3`.
  *(vault-list-rows)*
- Host, last check, notes and the gateway URL remain as secondary lines when present; when the
  vault is empty the search and sort hide but the count ("0 keys") stays visible.
  *(vault-list-rows)*
- Settings joins the single tablist through `aria-owns`; the status line got its own strip at the
  top of the content column; the key-table stacking breakpoint moved 720 → 800 px because the
  rail takes width. *(shell-rail-logo)*
- The menu keeps the gateway item between Access & grants and Activity per the architecture,
  though the mockup omits it. *(vault-row-menu)*
- The ≤540 px provider-select max-width cap (84 px) was removed once the toolbar wrapped; the
  96 px sort cap stays. `/icon.svg` was added to the test fixture's asset map because index.html
  references it as the favicon (the file already existed in `Web/` and `WEB_FILES`).
  *(fix-chart-chips-390)*
- A latent double-toggle bug was fixed: `H` on a row toggled History twice because the redraw
  detached `e.target` and the document listener re-ran the letter; handled row keys now
  stopPropagation. *(vault-list-rows)*

## Full CI list (`.github/workflows/test.yml`), run locally

All with `CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home`, on this commit's tree:

| Step | Result |
| --- | --- |
| `swift test` | **Passed.** Executed 524 tests, 5 skipped, 0 failures (47.2 s). |
| `Relay: npm ci` | **Passed.** Install clean (npm's install-scripts warning is harmless). |
| `Relay: npm test` | **Passed.** 36/36 in workerd, offline. (workerd logs one `disconnected: reader canceled` stream notice inside the passing run — pre-existing noise.) |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | **Passed.** Ran 62 tests, OK. |
| `python3 -m unittest Analytics/test_collector.py` | **Passed.** Ran 19 tests, OK. |
| `node scripts/tests/test_keys_dashboard_ui.cjs` | **Passed: 119/119 on the gate rerun.** The first full run went 118/119 — see Known flakiness. |
| `node scripts/tests/test_analytics_ui.cjs` | **Passed** (exit 0; the suite prints nothing on success). |
| `cd scripts/tests && npm run test:e2e` | **Passed.** dashboard.e2e.ts 4/4, site.e2e.ts 1/1. |
| `KEYS_BACKEND_CONTRACT_UI=1 swift test --filter BackendContractUITests` | **Passed.** "Backend contract UI passed: 9 cases" (Executed 1 test, 0 failures). |
| Lint (services.yaml: JS syntax + no inline styles/external refs in `Web/index.html`) | **Passed.** |

Skipped: none of the test steps. The workflow's setup steps (`actions/checkout`,
`actions/setup-node`, `npm ci` for scripts/tests, `npx playwright install chromium`) are
environment provisioning, not tests; the equivalents here (dependencies already installed per
`npm ci` earlier in the mission, chromium-1243 present) were in place. Local Node is v26 while CI
pins 22 — no behavioural difference observed in any suite.

### Known flakiness (not a failure)

"The grants box sits below the list and its Revoke button revokes" flaked once on 2026-10-27
during this closeout's first full-suite run (Playwright: the Revoke button detached mid-click —
"element is not stable / element was detached from the DOM, retrying" — while the host was under
memory pressure from a concurrent `swift test` build). It passed when run alone (1/1) and in the
full-suite gate rerun (119/119). Commit 239be4e already settled the known grants redraw race; the
remaining flake is environmental. Recorded here, not counted as a failure.

## Notes

- `relTime` renders dates older than 7 days as absolute dates (e.g. "Sep 18"). That behaviour
  predates this mission and is unchanged; the row tests accept either form.
- The fixture servers cannot attach a host or a grant to a pristine key (no user-surface path
  exists), so host-search and populated-grants-box assertions are evidenced by the Playwright
  tests ("key search filters by name, provider and host…", "the grants box sits below the list…")
  rather than live browser flows.
- Manual verification for the closeout was done with agent-browser against the fixture on
  127.0.0.1:12781: theme switch (Settings → light → Keys) kept the provider filter (Anthropic),
  the sort (Newest), the honest count ("1 of 3 keys") and a working search and menu; a reload
  kept the light theme and the sort and reset the session-only filter; at 390 px in the light
  theme there was no spill (rail 53 px, logo 40 px, Copy x266–329 and ··· x334–358, menu
  132–358 × 406–682); the fixture secret never appeared in the DOM. Screenshots:
  `/tmp/vault-vault-themes-narrow-and-report/` (dark-1440-keys, light-1440-menu, light-390-keys,
  light-390-menu). Earlier per-feature evidence lives in `/tmp/vault-vault-list-rows/`,
  `/tmp/vault-vault-search-filter-sort/`, `/tmp/vault-fix-chart-chips-390/` and
  `/tmp/vault-vault-row-menu/`.

## README

`README.md` now describes the rail ("switched from the left rail or with ⌘1 through ⌘4"), the
flat Keys list with the ··· menu, the provider filter and the sort, the grants box below the
list, the footer, and "Help at the foot of the rail"; the "Keys table's gateway column" wording
became "the Keys list's gateway figures".
