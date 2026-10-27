# Simplify the Add Key flow — mission report

2026-10-27, branch `droid/add-dialog-advanced`, worktree `.claude/worktrees/droid-addkey`.
Scope: the dashboard's Add key dialog (`#dlg-add` in `Web/index.html`, its styles and
`openAdd` in `Web/app.js`) plus the tests that pin the whole Add flow. No `Sources/`
production code, server API, `Web/providers.json`, grant, Touch ID, CLI or Edit dialog
changes. Nothing was pushed, published or released.

## Read first

- **Branch name.** The mission was planned on `droid/add-key`. The mission runner renamed
  that branch to `droid/add-dialog-advanced` when the run started. It is one branch with one
  lineage (it continues from the vault redesign's `bff841f`); no worker created, switched,
  renamed or pushed a branch, and every commit below sits on it.
- **The Name `pattern` attribute was dead in Chromium, and is fixed (9e24077).** The Name
  input shipped `pattern="[a-z0-9][a-z0-9._-]*"`. Browsers now compile `pattern=` with the
  regex `v` flag, under which an unescaped `-` at the end of a character class is a syntax
  error. Chromium discarded the whole attribute, so `validity.valid` stayed true and names
  like `UPPER` or `spa ce` went to the server instead of being refused in the browser. The
  dash is now escaped (`[a-z0-9][a-z0-9._\-]*`), the same form the provider-id pattern
  already used, so the existing submit handler's validity check refuses them again. This is
  the one deliberate change to an "attributes verbatim" input: the plan froze the attribute
  as written, but the contract (VAL-INVAL-001) needs the pattern to actually reject.
- **No other latent pattern bug.** The dashboard has exactly two `pattern=` attributes, the
  Add dialog's Name (`Web/index.html:248`, `[a-z0-9][a-z0-9._\-]*`) and the Providers
  manager's Id (`Web/index.html:558`, `[a-z0-9][a-z0-9\-]*`). Both escape the dash and both
  compile under the `v` flag.
- **The real server's over-long-name message is `name too long`.** `KeyName.validate`
  checks the 128-character cap before the regex, so a 129-character lowercase name answers
  400 `name too long`; only pattern violations answer
  `invalid name <name> (expected [a-z0-9][a-z0-9._-]*)`. The mission plan and the first
  version of the fixture mirror assumed the `invalid name …` text for both cases. The
  contract suite pins the true string against the real backend, and since 11bccb9 the Node
  fixture mirrors the same order and string.

## What was built

- **Advanced section (3384fbe).** The dialog now reads Name, Provider, Secret and the
  "Stored in the macOS Keychain" hint up front; Kind and Notes moved unchanged (same `.row2`,
  same ids and field names) into a collapsed native
  `<details id="add-advanced" class="advanced"><summary>Advanced</summary>`, styled after
  the Agents dialog's `.agent` cards with existing tokens only (both themes, no animation,
  no inline styles). `form.reset()` does not touch a disclosure, so `openAdd` closes it in
  the `openKeyDialog` fill hook on every open. The contract suite's add case opens Advanced
  before typing notes (Playwright cannot fill a collapsed input). New tests pin the layout,
  the click/Enter/Space toggle, reset on open, the collapsed defaults in the POST body
  (kind `runtime`, notes `""`), the 390 px fit, and an Edit dialog with no disclosure.
- **Required fields and invalid input (9e24077).** The Name pattern fix above; focus
  assertions for the three required-field errors; pattern-violating names (`UPPER`,
  `spa ce`, `-lead`, `.dot`, `café`) and a whitespace-only provider refused locally with
  zero POSTs; a 129-character name refused by the server with the dialog kept open, the
  message shown verbatim, values preserved and submit re-enabled, both against the Node
  fixture (now mirroring `KeyName.validate`) and against the real `KeysService` in a new
  contract case; the Advanced happy path (kind `billing` plus notes) through the POST body,
  the new row and a reopened Edit dialog.
- **Provider picker (11bccb9).** A custom "Yours" provider is offered first and creates a
  key whose row shows its display name; a hand-typed unknown id shows
  `No match. "<id>" will be saved as typed.` and lands on the row as the raw id; the
  secret-prefix guess (`guessProvider`, previously untested anywhere) fills an empty
  provider for a unique prefix, clears again when the prefix stops matching, never
  overwrites a typed provider and never guesses a hidden one. The fixture's over-long-name
  branch now answers `name too long`.
- **Secret safety (6905d5e).** All with invented `NEVER-REAL` sentinels and negative
  assertions only: a full-document scan after save; the add response, the listing and
  `GET /api/keys/<name>/events` against both the fixture and the real backend; the wipe on
  Cancel, Escape (with and without the picker list open), backdrop click and close after a
  409 (the 409 keeps typed values while the dialog stays open); and a Swift test that scans
  the catalog DB files' raw bytes and the `key_events` rows after `service.add`. Analytics
  stays pinned to the bare `key_add` counter by the existing ProductAnalyticsTests.
- **Closeout (this commit).** This report, the full CI run below, and one README word.

Test counts over the mission: dashboard UI suite 119 → 136 cases, contract suite 9 → 10
cases, `swift test` 524 → 525 tests.

## Decisions taken without the user (conservative)

From the mission plan (binding):

1. Essential fields are the three required ones, Name, Provider and Secret; Advanced holds
   the two optional ones, Kind and Notes.
2. The disclosure is native `<details>/<summary>`, the only disclosure pattern already in
   the app, so keyboard support and expanded-state semantics come for free and nothing new
   runs under the CSP.
3. Advanced starts collapsed on every open, matching `form.reset()`'s fresh-form semantics.
4. The Edit dialog is unchanged (flat Provider/Kind/Notes); its known first-Escape quirk in
   the provider autocomplete stays out of scope.
5. No server changes: `POST /api/keys` and `KeysService.add`, `Web/providers.json`,
   grants, Touch ID and `keys add` are untouched.
6. Labels and copy stay as they were; the section header is exactly "Advanced".

Made during the work:

- The Name `pattern` was fixed rather than kept verbatim (see Read first). *(9e24077)*
- The real server's `name too long` string was treated as the truth over the mission docs,
  and the fixture mirror was corrected to match it rather than the docs. *(9e24077,
  11bccb9)*
- A new `addFocus(page, field)` test helper compares `document.activeElement` with the
  field node, because the add inputs have no `id` and the existing `focused()` helper
  returns `""` for them. *(9e24077)*
- README: "Local" was added to the picker's group list (see README below), the only edit.
  *(closeout)*

## Full CI list (`.github/workflows/test.yml`), run locally

All with `CLAUDE_CONFIG_DIR=Fixtures/claude-home GROK_HOME=Fixtures/grok-home
GROK_BOT_HOME=Fixtures/grok-bot-home KEYS_DROID_HOME=Fixtures/droid-home`, from the repo
root, on 6905d5e's tree (this commit adds only this file and one README word):

| Step | Result |
| --- | --- |
| `swift test` | **Passed.** Executed 525 tests, 5 skipped, 0 failures (46.1 s in XCTest, 49 s wall). |
| scripts/tests `npm ci` | **Provisioning verified, not reinstalled.** `npm ci --dry-run` exit 0 (lockfile in sync); Playwright already installed by the mission's earlier `npm ci`. |
| Relay `npm ci` | **Passed.** Added 80 packages, audited 81. |
| Relay `npm test` | **Passed.** 36/36 in workerd, offline (4.9 s). workerd logs one `disconnected: reader canceled` line inside the passing run, pre-existing noise. |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | **Passed.** Ran 62 tests, OK. |
| `python3 -m unittest Analytics/test_collector.py` | **Passed.** Ran 19 tests, OK. |
| `npx --no-install playwright install chromium` | **Passed.** Exit 0, nothing to download (chromium-1243 present). |
| `node scripts/tests/test_keys_dashboard_ui.cjs` | **Passed.** "Keys dashboard UI passed: 136 cases" (145 s), first run, no failures. |
| `node scripts/tests/test_analytics_ui.cjs` | **Passed.** Exit 0 in 5 s (the suite prints nothing on success). |
| `cd scripts/tests && npm run test:e2e` | **Passed.** dashboard.e2e.ts 4/4, site.e2e.ts 1/1 (10 s). |
| `KEYS_BACKEND_CONTRACT_UI=1 swift test --filter BackendContractUITests` | **Passed.** "Backend contract UI passed: 10 cases" (8 s). |
| Lint (`services.yaml`: `node --check` on `Web/app.js` and the UI suite, plus the no-inline-styles/external-refs static test) | **Passed.** Both checks clean; static test 1/1. |

Failed: none. Skipped: none of the test steps. `actions/checkout` and `actions/setup-node`
are CI provisioning with no local equivalent to run. Local Node is v26.7.0 while CI pins
22; no behavioural difference was seen in any suite. Swift 6.3.3.

### Known flakiness (not a failure)

The grants-box test ("…its Revoke button revokes") can fail with Playwright's "element was
detached from the DOM" when the host is under memory pressure from a concurrent Swift
build, as recorded in `docs/missions/vault-redesign.md`. It was seen once during this
mission's first feature's full run and passed on rerun. It did not occur in the closeout
run above, where every step ran one at a time.

## Evidence

- Closeout (agent-browser on the fixture at 127.0.0.1:12781, server and session stopped
  afterwards): `/tmp/addkey-add-key-closeout/` — `dark-1440-add-dialog-collapsed.png`
  (opened with `N`; Name, Provider, Secret and hint; Kind and Notes absent),
  `dark-1440-picker-groups.png` (the grouped picker; its group headers read Labs, Routers,
  Hosts, Clouds, Local, Non-chat, with Ollama and LM Studio under Local),
  `dark-1440-prefix-prefill.png` (an invented `sk-ant-` sentinel in Secret filled the empty
  Provider with `anthropic`; Advanced stayed collapsed, kind `runtime`, notes empty),
  `dark-1440-advanced-expanded.png`, `light-1440-add-dialog-collapsed.png`,
  `light-1440-advanced-expanded.png` and `light-390-advanced-expanded.png` (the Kind/Notes
  row and Cancel/Add key fit inside the dialog at 390 px). Escape then closed the dialog and
  the secret input read empty.
- Per-feature: `/tmp/addkey-add-dialog-advanced-section/` (dark/light at 1440 and 390 px,
  collapsed and expanded) and `/tmp/addkey-add-dialog-provider-tests/` (custom provider in
  the picker and on its row, the free-text message, the prefix pre-fill).
- Readiness: `/tmp/addkey-validation-readiness/` (baseline suite logs and screenshots).

## README

Checked every dashboard paragraph that touches the Add flow against the shipped dialog:

- Keys pane: "`N` adds a key" and "a pasted secret with a recognisable prefix pre-fills it"
  stay true (both confirmed in the browser above and now pinned by tests). "The provider
  picker is grouped into Labs, Routers, Hosts, Clouds and Non-chat" omitted the shipped
  Local group (Ollama, LM Studio), which the picker shows; the sentence now names Local.
  The omission predates this mission; it is the only README edit.
- "A built-in provider you do not want in the Add dialog is taken out with
  `keys provider hide <id>`" (provider section) stays true: hidden providers are still
  excluded from the picker.
- Nothing in the README described the dialog's field order or Kind/Notes placement, so the
  Advanced section needed no other wording change.

## Mission process notes

- The four implementation features each landed one commit with their tests; the closeout
  ran every CI step serially so no Swift build competed with a browser suite.
- Validator observation carried from the previous mission, still out of scope: the Edit
  dialog's provider autocomplete swallows the first Escape press.
