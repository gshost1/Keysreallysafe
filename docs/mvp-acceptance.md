# MVP acceptance on a second Mac

The list of checks that decide whether a prepared package is usable on a Mac
other than the build machine. Follow [mvp-quickstart.md](mvp-quickstart.md)
first; this file only records what to try and what the answer must be.

**Status: PARTIALLY VERIFIED on an Apple Silicon Mac running macOS 15.0.1.**
Results below were collected on 2026-09-21 local time (2026-09-22 UTC).
User-observed UI checks are distinguished from programmatic checks. Remaining
items are not claimed as passed. No secret values are recorded here.

## Preconditions

- macOS 14 or newer on the target Mac.
- The architecture from `uname -m` is included in `file bin/keys` and matches
  the owner's supplied architecture metadata.
- The owner ran `prepare-optimizer-release.py --verify-package` against the
  prepared directory on the build Mac and sent the archive, its SHA-256 and the
  signing and architecture metadata.
- On the target: `shasum -a 256 -c` matches the sent digest and
  `codesign --verify --strict bin/keys` passes. Neither needs a checkout.
- No Swift toolchain and no Python are needed on the target for the core app;
  the delivered `bin/keys` runs.
- Node 18+ and `python3` only if the optional, experimental Optimizer is tried.
- Verify the supplied package signing and notarization evidence. If macOS refuses to
  run the package, record that as the result and stop. Do not disable or work
  around Gatekeeper, and do not write such a workaround into this file.
- Use an invented, disposable value for vault and presence checks. A successful
  upstream request in checks 7–8 needs a valid key chosen by the owner on that
  Mac; prefer a provider-supported read-only endpoint. A refused request with
  an invented key is not proof that valid provider access works. No key value
  belongs in a result note.

## Checks

| # | Check | Expected | Result |
|---|---|---|---|
| 0 | Archive digest and signature on the target: `shasum -a 256 -c`, `codesign --verify --strict bin/keys`, `file bin/keys` against `uname -m` and the supplied metadata | Digest matches the owner's, signature verifies, architectures agree | 2026-09-21 pass: original DMG checksum, Developer ID signature, Gatekeeper and arm64 verified |
| 1 | `./bin/keys doctor` from the package directory | Prints sources, catalog, Keychain, gateway and autostart state; no `Web/ not found` | 2026-09-21 pass: doctor ran on target |
| 2 | `./bin/keys autostart`, then open `http://127.0.0.1:12766/` | Dashboard loads on loopback; menu bar item present | 2026-09-21 partial: dashboard HTTP 200 and user-visible; menu bar not separately confirmed |
| 3 | First run with an empty vault | The Usage pane shows the getting-started guide; **?** shows the same guide afterwards | PENDING: empty-vault onboarding not observed |
| 4 | Add a key, then **Reveal** and **cancel** the Touch ID prompt | The secret stays hidden, the button stays usable, and the page says the Mac authentication was cancelled | 2026-09-21 partial: user confirmed cancellation revealed nothing; cancellation message not separately confirmed |
| 5 | **Reveal** again and **allow** Touch ID (or the password fallback macOS offers) | The value appears, counts down, and clears itself at expiry | 2026-09-21 pass: user confirmed Touch ID reveal and auto-hide after 15 seconds |
| 6 | Issue a scoped grant (one key, one host, a method and path scope, an expiry) | The grant is listed with its scope and expiry; the dashboard never shows the key value | 2026-09-21 pass: scoped dummy and TypeSafe grants issued after presence |
| 7 | With the owner's valid key and a matching grant, send one read-only request through the local gateway | The provider accepts the request; the Chart pane's API keys scope counts it | 2026-09-21 partial: one authorized synthetic TypeSafe evaluation returned HTTP 200; ledger recorded it; chart visual check pending |
| 8 | Usage after that request | Tokens and requests by default, no dollar figure until USD is chosen; when USD is chosen, an unpriced call reads as unknown, never as $0 | 2026-09-21 partial: ledger recorded 288 input / 20 output tokens, model jev-1.13.0, cost unknown; UI defaults covered by synthetic browser tests |
| 9 | Revoke the grant, then repeat the request | The repeated request is refused; the grant reads as revoked | 2026-09-21 pass: revoked dummy grant request rejected HTTP 403 grant_revoked |
| 10 | Lock the screen with a grant active | The grant dies; it is not usable after unlock | 2026-09-21 partial: system audit recorded screen_lock revocation; post-lock request not exercised |
| 11 | Upgrade: prepare a second package from a newer build, verify it, re-run `./bin/keys autostart` | The new binary serves the dashboard; existing keys still read after at most one **Always Allow** Keychain approval; the signing team and designated requirement are unchanged | 2026-09-21 pass: new signed binary installed; metadata/settings/usage preserved; existing TypeSafe key accessible after Touch ID; signing requirement unchanged |
| 12 | Uninstall: `./bin/keys autostart --remove` | Login item unloaded and deleted, loopback site gone, menu bar item gone | 2026-09-21 pass: login item/runtime removed, both ports stopped; reinstalled with catalog metadata preserved |
| 13 | Optional, experimental only: Optimizer pane with Node 18+ and `python3` present | The pane is labelled optional and experimental; every check above still passed without it | PENDING: optional Optimizer not tested on target |

## Recording a result

Replace `PENDING` with the date and a one-line outcome, for example
`2026-09-21 pass` or `2026-09-21 fail: <what happened>`. Keep prompts, key
values and log excerpts containing either out of this file.
