# MVP acceptance on a second Mac

The list of checks that decide whether a prepared package is usable on a Mac
other than the build machine. Follow [mvp-quickstart.md](mvp-quickstart.md)
first; this file only records what to try and what the answer must be.

**Status: PENDING.** Nothing below has been run on a second Mac. No result here
may be reported as passed until someone runs it there and writes the date and
the outcome into the Result column. An empty Result means not attempted, which
is not the same as passed.

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
- Signed private preview, not a notarized public release. If macOS refuses to
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
| 0 | Archive digest and signature on the target: `shasum -a 256 -c`, `codesign --verify --strict bin/keys`, `file bin/keys` against `uname -m` and the supplied metadata | Digest matches the owner's, signature verifies, architectures agree | PENDING |
| 1 | `./bin/keys doctor` from the package directory | Prints sources, catalog, Keychain, gateway and autostart state; no `Web/ not found` | PENDING |
| 2 | `./bin/keys autostart`, then open `http://127.0.0.1:12766/` | Dashboard loads on loopback; menu bar item present | PENDING |
| 3 | First run with an empty vault | The Usage pane shows the getting-started guide; **?** shows the same guide afterwards | PENDING |
| 4 | Add a key, then **Reveal** and **cancel** the Touch ID prompt | The secret stays hidden, the button stays usable, and the page says the Mac authentication was cancelled | PENDING |
| 5 | **Reveal** again and **allow** Touch ID (or the password fallback macOS offers) | The value appears, counts down, and clears itself at expiry | PENDING |
| 6 | Issue a scoped grant (one key, one host, a method and path scope, an expiry) | The grant is listed with its scope and expiry; the dashboard never shows the key value | PENDING |
| 7 | With the owner's valid key and a matching grant, send one read-only request through the local gateway | The provider accepts the request; the Chart pane's API keys scope counts it | PENDING |
| 8 | Usage after that request | Tokens and requests by default, no dollar figure until USD is chosen; when USD is chosen, an unpriced call reads as unknown, never as $0 | PENDING |
| 9 | Revoke the grant, then repeat the request | The repeated request is refused; the grant reads as revoked | PENDING |
| 10 | Lock the screen with a grant active | The grant dies; it is not usable after unlock | PENDING |
| 11 | Upgrade: prepare a second package from a newer build, verify it, re-run `./bin/keys autostart` | The new binary serves the dashboard; existing keys still read after at most one **Always Allow** Keychain approval; the signing team and designated requirement are unchanged | PENDING |
| 12 | Uninstall: `./bin/keys autostart --remove` | Login item unloaded and deleted, loopback site gone, menu bar item gone | PENDING |
| 13 | Optional, experimental only: Optimizer pane with Node 18+ and `python3` present | The pane is labelled optional and experimental; every check above still passed without it | PENDING |

## Recording a result

Replace `PENDING` with the date and a one-line outcome, for example
`2026-09-21 pass` or `2026-09-21 fail: <what happened>`. Keep prompts, key
values and log excerpts containing either out of this file.
